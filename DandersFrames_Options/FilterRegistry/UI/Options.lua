-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames

-- ============================================================
-- FILTER REGISTRY - FILTER DESIGNER GUI
-- Two-column editor for the buff filter registry: built-in
-- preset categories (per-profile enable/disable overrides) and
-- account-wide custom filters. Called from Options/Options.lua
-- via DF.BuildFilterDesignerPage().
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local format = string.format
local tinsert = table.insert
local tsort = table.sort
local mmax = math.max
local mfloor = math.floor
-- Added for the chip row's wrap arithmetic; see LayoutChips.
local mceil = math.ceil
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetBuildInfo = GetBuildInfo
local RAID_CLASS_COLORS = RAID_CLASS_COLORS

local L = DF.L

local FALLBACK_ICON = 134400 -- question mark

local function Trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

-- The async load-on-demand spell tooltip (R.ShowSpellTooltip), the fixed
-- class grouping order (R.PickerClassOrder), the localized class names
-- (R.ClassDisplayName) and the class-coloured name styling
-- (R.ApplyClassNameColor) live in FilterRegistry/SpellPicker.lua — shared
-- with the spell database picker. That file loads AFTER this one, so bind
-- them at build time (inside BuildFilterDesignerPage), never at file scope.

-- Spell-list "still showing this spell?" predicate for the async tooltip
-- (file-local so the pooled OnEnter handlers don't allocate a closure per
-- hover)
local function SpellRowStillShows(row, spellID)
    return row._spellID == spellID and not row._raw
end

-- ============================================================
-- NAME PROMPT + DELETE CONFIRM
-- Both go through the addon's own popup: GUI:PromptName for the name, and a
-- plain alert for the confirm. This file used to carry its own copy of the
-- Blizzard StaticPopup idiom, duplicated from the Designer preset bar.
-- ============================================================

-- DF.GUI, not GUI: this file's `GUI` is a local inside BuildFilterDesignerPage,
-- so at this scope the bare name would be a nil global.
local function PromptFilterName(message, default, acceptLabel, callback)
    DF.GUI:PromptName({
        title       = L["Filter Name"],
        message     = message,
        default     = default,
        acceptLabel = acceptLabel,
        onAccept    = callback,
    })
end

local function ConfirmDeleteFilter(displayName, onAccept)
    DF:ShowPopupAlert({
        title   = L["Delete Filter"],
        message = format(L["Delete filter \"%s\"? It will also be removed from every profile that uses it."], displayName),
        buttons = {
            { label = L["Delete"], onClick = onAccept },
            { label = L["Cancel"] },
        },
    })
end

-- Error keys from R:DecodeFilterString / R:ExportFilter -> user-facing text.
-- A string carrying another DandersFrames prefix is a valid export of the WRONG
-- kind, and is called out as such: "that isn't a filter string" would send
-- someone hunting for corruption when they simply pasted into the wrong box.
local function FilterStringError(errKey)
    if errKey == "profile" then
        return L["That's a profile string. Import it from the Profiles page instead."]
    elseif errKey == "clickcasting" then
        return L["That's a click casting string. Import it from the Click Casting page instead."]
    elseif errKey == "wizard" then
        return L["That's a setup wizard string, not a filter."]
    elseif errKey == "newer" then
        return L["This filter was exported by a newer version of DandersFrames."]
    elseif errKey == "tooLarge" then
        return L["That filter string is too large."]
    elseif errKey == "corrupt" then
        return L["That filter string is corrupt or incomplete."]
    end
    -- "libs", "encode", "noSelection" and anything unrecognised: nothing the
    -- user can act on beyond retrying.
    return L["That doesn't look like a filter string."]
end

-- The popup frame is a SINGLETON, and an alert button's handler runs
-- btnConfig.onClick() and THEN f:Hide(). So opening a second popup from inside
-- the first one's callback reconfigures the shared frame and then has it hidden
-- out from under it — the new popup flashes and vanishes. Defer a frame so the
-- first one finishes closing before the next opens.
local function ChainPopup(fn)
    C_Timer.After(0, fn)
end

-- Import a decoded payload, asking for a name ONLY if that name is already in the
-- list. A clean import (nothing clashes) stays a single paste with no extra step;
-- a clashing one gets Duplicate's treatment -- you see the name, pre-filled with a
-- suggestion that does not collide, and can change it before anything is saved.
--
-- Without this, import was the one path that committed a name you never saw: two
-- rows reading the same thing, and no way to tell from the Buffs page which one you
-- had ticked. Worst through "Import as Copy", which promises a distinguishable copy
-- and produced a row identical in both name AND spells.
--
-- ⚠ The prompt is CHAINED. Popups are a singleton here, so opening one from inside
-- another's handler needs the next frame; the "Import as Copy" route reaches this
-- from a popup button.
-- ☠ THIS FUNCTION IS AT FILE SCOPE, so it can see NEITHER of the two things it needs.
-- `R` (local R = DF.FilterRegistry) and `SelectFilter` are both declared INSIDE
-- DF:BuildFilterDesignerPage, hundreds of lines below -- a local declared later, in an
-- inner block, is not an upvalue of a function defined earlier at file scope. Both
-- therefore compiled as nil globals and every route through single-filter import died on
-- "attempt to index a nil value (global 'R')": a clean import, and "Import as Copy".
--
-- The regression came from hoisting the body OUT of BuildFilterDesignerPage to chain the
-- rename prompt; the references came with it and the scope did not. This file already
-- warns about the identical hazard for `GUI` a hundred lines above -- same trap, second
-- name.
--
-- Fixed by resolving R at call time (DF.FilterRegistry is the main addon's, resident
-- before this companion file ever runs) and by promoting SelectFilter to a file-scope
-- forward declaration that BuildFilterDesignerPage assigns into.
local SelectFilter   -- forward declaration; assigned in DF:BuildFilterDesignerPage

local function ImportNamed(def)
    local R = DF.FilterRegistry
    if not R or not SelectFilter then return end
    if not R:IsCustomFilterNameTaken(def.name) then
        SelectFilter("custom", R:ImportFilterPayload(def))
        return
    end
    ChainPopup(function()
        PromptFilterName(
            L["You already have a filter with that name. Name the imported filter:"],
            R:SuggestUniqueFilterName(def.name),
            L["Import"],
            function(text)
                text = Trim(text or "")
                if text == "" then return end
                def.name = text     -- decoded payload is ours; safe to retitle
                SelectFilter("custom", R:ImportFilterPayload(def))
            end)
    end)
end

local function ShowFilterStringError(title, errKey)
    local message = FilterStringError(errKey)
    ChainPopup(function()
        DF:ShowPopupAlert({
            title   = title,
            tone    = "danger",
            message = message,
            buttons = { { label = L["OK"] } },
        })
    end)
end

-- Deleting a custom filter must also unhook it from every profile's
-- per-mode selections (both the buff and defensive rows) AND from every
-- Aura Designer filter group's filterSelection (A5 — the AD preset
-- libraries plus legacy inline auraDesigner tables), or stale ids linger
-- in SavedVariables forever. Nil-safe against profiles that predate the
-- selection tables, are missing a mode entirely, or carry the pre-V2
-- flat (non-spec-keyed) layoutGroups shape.
local function ScrubDeletedFilter(cfId)
    local sv = DandersFramesDB_v2
    local profiles = sv and sv.profiles
    if type(profiles) ~= "table" then return end

    -- ⚠ Guarded like every other call to it from this addon: the parser is RESIDENT and
    -- this file ships in the options companion, so the symbol is not guaranteed present.
    -- ☠ Reported rather than silently skipped -- without the parser the three string-form
    -- scrubs below cannot run, and a scrub that quietly does two thirds of its job is how
    -- a dangling reference survives a "fix".
    local ParseRef = DF.ParseADFilterRef
    if not ParseRef then
        DF:DebugWarn("FILTER", "ScrubDeletedFilter: DF:ParseADFilterRef unavailable -- @custom: references in AD effect keys, triggers and conditions were NOT scrubbed for '%s'", tostring(cfId))
    end

    -- One array of layout-group records: nil the deleted id from every
    -- filter group's customs selection. Member groups carry no selection.
    local function scrubGroupArray(groups)
        for _, g in ipairs(groups) do
            if type(g) == "table" then
                local sel = g.filterSelection
                if type(sel) == "table" and type(sel.customs) == "table" then
                    sel.customs[cfId] = nil
                end
            end
        end
    end
    -- layoutGroups is spec-keyed post-V2 ({ [specKey] = {groups} }) but may
    -- still be the legacy flat array on unmigrated configs — walk both shapes.
    local function scrubLayoutGroups(lg)
        if type(lg) ~= "table" then return end
        if lg[1] ~= nil then scrubGroupArray(lg) end
        for k, v in pairs(lg) do
            if type(k) == "string" and type(v) == "table" then
                scrubGroupArray(v)
            end
        end
    end
    -- ☠ A @custom:<id> LIVES IN FOUR PLACES, not one. Beyond a group's filterSelection
    -- this function used to scrub, the id appears as a plain STRING in three more:
    --   (a) the aura KEY of a filter-owned effect  -- cfg.auras[spec][key] / cfg.otherAuras
    --   (b) an effect's trigger list               -- auraCfg[typeKey].triggers[i]
    --   (c) a condition group's trigger list       -- .conditions.groups[j].triggers[k]
    -- Core/Profile.lua's export and import walks already handle (a) and (b) and say
    -- outright that "collectSel never sees them" -- so the shapes were known here and the
    -- scrub simply never caught up.
    --
    -- Leaving them dangling is not cosmetic: ResolveADFilterRef memoises `false`, the
    -- effect renders nothing with no warning, and -- because nextFilterID lives in the
    -- ACCOUNT-wide store -- a later filter can be issued the same cf id and the orphaned
    -- reference silently binds to it.
    local function scrubRefList(list)
        if not ParseRef or type(list) ~= "table" then return end
        for i = #list, 1, -1 do
            local kind, key = DF:ParseADFilterRef(list[i])
            if kind == "custom" and key == cfId then table.remove(list, i) end
        end
    end
    local function scrubAuraCfg(auraCfg)
        if type(auraCfg) ~= "table" then return end
        for _, typeCfg in pairs(auraCfg) do
            if type(typeCfg) == "table" then
                scrubRefList(typeCfg.triggers)
                local conds = typeCfg.conditions
                if type(conds) == "table" and type(conds.groups) == "table" then
                    for _, grp in pairs(conds.groups) do
                        if type(grp) == "table" then scrubRefList(grp.triggers) end
                    end
                end
            end
        end
    end
    local function scrubAuraStore(store)
        if not ParseRef or type(store) ~= "table" then return end
        for auraName, auraCfg in pairs(store) do
            scrubAuraCfg(auraCfg)
            -- The filter-owned record itself: its KEY is the reference, so the whole
            -- record goes. Nothing else can resolve it once the filter is gone.
            local kind, key = DF:ParseADFilterRef(auraName)
            if kind == "custom" and key == cfId then store[auraName] = nil end
        end
    end
    local function scrubADConfig(cfg)
        if type(cfg) == "table" then
            scrubLayoutGroups(cfg.layoutGroups)
            -- Other Buffs layout groups: a flat array only (new store, never
            -- spec-keyed — no dual-shape dispatch needed).
            if type(cfg.otherLayoutGroups) == "table" then
                scrubGroupArray(cfg.otherLayoutGroups)
            end
            -- ⚠ Dispatch on shape, like layoutGroups above: `auras` is spec-keyed only
            -- after the lazy spec-scope migration has touched this adDB.
            local auras = cfg.auras
            if type(auras) == "table" then
                local flat = false
                for _, v in pairs(auras) do
                    if type(v) == "table" and (v.priority ~= nil or v.indicators ~= nil or v.border ~= nil) then
                        flat = true
                    end
                    break
                end
                if flat then
                    scrubAuraStore(auras)
                else
                    for _, specAuras in pairs(auras) do scrubAuraStore(specAuras) end
                end
            end
            scrubAuraStore(cfg.otherAuras)
        end
    end
    -- Raid auto-layout overrides: a layout-edit session stores a whole-table
    -- copy of the mode selection tables — INCLUDING .customs — into each
    -- layout's overrides (AutoProfiles' ExitEditing diff scan), and
    -- ApplyRuntimeProfile re-injects that copy on every activation. Without
    -- this walk the deleted id resurrects with the layout, and a dangling
    -- customs key makes ResolveSelection return an empty include map (the
    -- row renders NOTHING while that layout is active).
    local function scrubSelection(sel)
        if type(sel) == "table" and type(sel.customs) == "table" then
            sel.customs[cfId] = nil
        end
    end
    local function scrubAutoLayouts(autoDb)
        if type(autoDb) ~= "table" then return end
        local function scrubLayout(layout)
            local ov = type(layout) == "table" and layout.overrides
            if type(ov) == "table" then
                scrubSelection(ov.buffFilterSelection)
                scrubSelection(ov.defensiveFilterSelection)
                -- ☠ AND THE AURA DESIGNER OVERRIDE. `auraDesigner` is a WHOLE-TABLE
                -- override key (Core/AutoProfiles.lua), so a layout edited while a filter
                -- was linked carries its own copy of the AD config -- filterSelection
                -- customs included. Scrubbing only the two selection keys above left the
                -- deleted id inside that copy, and ApplyRuntimeProfile re-injects it on
                -- every activation: exactly the resurrection this function's header
                -- describes. A dangling customs key makes ResolveSelection return an empty
                -- include map, and Factory's `next(res.map)` guard then drops the whole AD
                -- filter group with no log while that layout is active.
                scrubADConfig(ov.auraDesigner)
            end
        end
        for _, ct in pairs(autoDb) do
            if type(ct) == "table" then
                if type(ct.profiles) == "table" then
                    for _, layout in pairs(ct.profiles) do scrubLayout(layout) end
                end
                scrubLayout(ct.profile)   -- mythic carries a single layout
            end
        end
    end

    for _, profile in pairs(profiles) do
        if type(profile) == "table" then
            for i = 1, 2 do
                local mode = (i == 1) and profile.party or profile.raid
                if type(mode) == "table" then
                    scrubSelection(mode.buffFilterSelection)
                    scrubSelection(mode.defensiveFilterSelection)
                    -- Legacy inline AD config (pre-preset-library profiles)
                    scrubADConfig(mode.auraDesigner)
                end
            end
            -- AD preset library (post-migration home of every AD config)
            if type(profile.auraDesignerPresets) == "table" then
                for _, preset in pairs(profile.auraDesignerPresets) do
                    scrubADConfig(preset)
                end
            end
            scrubAutoLayouts(profile.raidAutoProfiles)
        end
    end

    -- Live runtime overlay: while an auto layout is ACTIVE its override copy
    -- is what the raid proxy actually reads (until the next re-apply) — clear
    -- the id there too so it can't drive the current session's rows.
    local live = DF.raidOverrides
    if type(live) == "table" then
        scrubSelection(live.buffFilterSelection)
        scrubSelection(live.defensiveFilterSelection)
    end
end

-- ============================================================
-- MAIN PAGE BUILD
-- ============================================================

function DF.BuildFilterDesignerPage(guiRef, pageRef, dbRef, Add, AddSpace)
    -- Build frames once; subsequent calls just refresh widget data.
    -- DoBuild wipes child.ThemeListeners and retires Add()ed children on every
    -- rebuild, so the guard path re-adopts the height spacer and re-registers
    -- the theme listener before refreshing.
    if pageRef._filterDesignerBuilt then
        local p = pageRef.child
        p.ThemeListeners = p.ThemeListeners or {}
        table.insert(p.ThemeListeners, pageRef._fdThemeListener)
        -- ☠ THE BANDS ARE RE-ADOPTED EXACTLY AS THE SPACER IS, and for the same
        -- reason: DoBuild retires every Add()ed child on a rebuild -- hides it,
        -- clears its points, reparents it to the trash -- so a page that builds its
        -- frames ONCE has to hand its roots back afterwards. Add() is the call that
        -- re-parents and re-inserts them, and it arrives fresh on every invocation,
        -- which is why the adopt pass takes it as an argument rather than closing
        -- over the first one it ever saw.
        if pageRef._fdAdoptBands and Add then
            pageRef._fdAdoptBands(Add)
        elseif pageRef._fdSpacer and pageRef.children then
            pageRef._fdSpacer:SetParent(p)
            table.insert(pageRef.children, pageRef._fdSpacer)
        end
        -- Re-fit to the window before refreshing: the spacer the guard just
        -- re-adopted carries a height from the LAST build, and the window may have
        -- been resized since. Without this the page's scroll range is stale.
        if pageRef._fdResolvePanelHeight then pageRef._fdResolvePanelHeight() end
        if pageRef._fdRefreshAll then pageRef._fdRefreshAll() end
        return
    end
    pageRef._filterDesignerBuilt = true

    local GUI = guiRef
    local parent = pageRef.child
    local R = DF.FilterRegistry

    -- ============================================================
    -- WHICH LAYOUT THIS IS
    -- ------------------------------------------------------------
    -- `Add` is the tell, and it is the same tell the Aura Designer uses
    -- (Editor.lua's DF.BuildAuraDesignerPage): a caller holding BuildPage's own Add
    -- can be served BANDS; one that does not -- an older call site, or classic --
    -- can only have the island.
    --
    -- ☠ THIS PAGE IS NOT A DESIGNER SHELL, WHICH IS WHY IT DOES NOT BUILD ONE.
    -- GUI:BuildDesignerShell is a preview-plus-tabs shape -- a canvas, a strip
    -- saying what the canvas is showing, a view switcher, then the caller's bands.
    -- The Filter Designer has none of those three: it is a MASTER/DETAIL, a list of
    -- filters and the spells inside the one you picked. Handed the shell it would
    -- use one of its six slots. So what this borrows from the rework is the COLUMN,
    -- not the shell: the master collapses into a popout row -- the all-rows rule,
    -- which is exactly "more than one option goes in a panel" -- and the detail
    -- becomes the page.
    --
    -- ☠ NOTHING BELOW THIS POINT IS BRANCHED ON IT. The island builds exactly as it
    -- always did, anchored off `parent`, and the band arm RE-HOMES its five roots
    -- at the end (AdoptBands, at the foot of this function). Threading a layout
    -- test through 2,700 lines of one closure would fork every site it touched;
    -- re-anchoring five frames forks none of them, and the two layouts cannot
    -- drift apart because there is only one build.
    local tools = (Add and GUI.CreatePopoutPageTools and not DF:IsClassicSettingsLayout())
                  and GUI:CreatePopoutPageTools(pageRef) or nil
    local rowsMode = (Add ~= nil) and (tools ~= nil)
    -- (FILTERROW_H is gone. It named DandersUI's plate-plus-gap so the page-height
    -- arithmetic could reserve two popout rows above the detail; the band arm has
    -- neither a fixed number of rows nor a detail band to reserve for, and its one
    -- band of rows reports its own height through the group it lives in. A constant
    -- nothing spends is a number waiting to disagree with the kit.)
    -- The gap the island puts between its stacked pieces, kept so the band arm has
    -- the same rhythm rather than a second set of numbers.
    --
    -- ☠ AND IT IS NOW THE DESIGNER SHELL'S NUMBER, NOT A SECOND COPY OF IT. The
    -- shell gained the same rhythm for the Aura and Text Designers (the bands used
    -- to stack flush and read as "crampted together"), and it took THIS value
    -- because this page had already chosen it. Read rather than re-typed, so the
    -- three designer pages cannot drift into three near-identical gaps. Read here,
    -- inside the builder, rather than at file scope: this file loads before nothing
    -- in particular, and a page builds long after every file has.
    local BAND_GAP = GUI.DESIGNER_BAND_GAP or 10

    -- Shared helpers from FilterRegistry/SpellPicker.lua (loads after this
    -- file — safe here because pages build long after load time)
    local CLASS_ORDER = R.PickerClassOrder
    local ClassDisplayName = R.ClassDisplayName
    local ApplyNameColor = R.ApplyClassNameColor
    local ShowSpellTooltip = R.ShowSpellTooltip

    -- ========== LAYOUT CONSTANTS ==========
    -- Panel height tracks the window instead of being pinned at 490. The page has
    -- two independently scrolling lists, so any height the window can give them is
    -- height they can use — a fixed value left a dead band under both panels on
    -- anything but a short window.
    --
    -- Measured from GUI.contentFrame, which is anchored to the window's edges and
    -- is therefore the real viewport. CHROME is everything this page stacks above
    -- and below the panels: top pad + banner + gap, and below, the spell-database
    -- freshness label and the bottom pad. It matches the spacer's own arithmetic
    -- further down; both read this constant so they cannot drift apart.
    --
    -- CHIP_ROW_H is the consumer chip row between the banner and the panels, plus
    -- the gap above it. It is folded into CHROME rather than added at each site so
    -- the panel sizer and the page-height spacer cannot disagree about whether the
    -- row exists -- they read one number.
    local CHIP_H = 22
    local CHIP_ROW_H = CHIP_H + 10

    -- ☠ TOP_INSET IS NOW 0, and it must stay in the arithmetic rather than being
    -- deleted. It reserved vertical room for the Copy/Sync/Reset row the page host
    -- Add()s above this content -- 25 for the buttons plus the standard gap. This
    -- page owns no per-mode keys since filter selection moved to the consumers, so
    -- CreateCopyButton returns a zero-height placeholder and there is no row to
    -- clear: the reservation was pure empty space at the top of the page.
    --
    -- ⚠ It is declared HERE, beside PANEL_CHROME_H, and CHROME is written in terms
    -- of it. Those two numbers have to move together -- the inset positions the
    -- banner, CHROME tells the panel sizer and the page-height spacer how much room
    -- the banner and everything around it take -- and this file has already been
    -- bitten twice by exactly that class of paired constant drifting apart (see the
    -- ROW2_Y / HEADER_H note in the right-hand header). Written as a sum, a change
    -- to the inset cannot silently leave the sizer behind.
    --
    -- ☠ ABOVE THE PANELS ONLY -- BELOW_PANELS_H is the other end. This was ONE
    -- number (66) covering both, and splitting it is fine; what was NOT fine was
    -- the first attempt at the bottom half, which measured dbFreshLabel:GetHeight()
    -- and called that "measured, not guessed". It was neither: GUI:CreateLabel
    -- opens at a placeholder SetSize(w, 40) and only converges to the real wrapped
    -- height in a deferred pass that is gated on `frame.settingsGroup` -- and this
    -- label is anchored straight to leftPanel, so it is in no group, the converge
    -- never runs, and GetHeight() returns the placeholder 40 for the life of the
    -- page. A hard-coded 40 wearing a measurement's clothes.
    --
    -- 44 is HEAD's own allowance, arrived at before this session and correct: the
    -- 2px gap under the panel, the note, and a little air. Restored rather than
    -- re-derived.
    --
    -- 22 = 10 top pad + 12 banner-to-panel gap. The banner's own height is added by
    -- the caller, since it re-wraps independently of the viewport.
    local TOP_INSET = 0
    local BELOW_PANELS_H = 44
    local PANEL_CHROME_H = 22 + TOP_INSET + CHIP_ROW_H
    local PANEL_H_MIN = 320
    -- Take 90% of what's left rather than all of it. Filling the viewport exactly
    -- still tips the page's own scroll frame over its range — RefreshStates adds
    -- its own bottom padding to the content height — and the main window grows a
    -- scrollbar for a few pixels of overflow. The slack absorbs that without
    -- needing to know the layout's padding, which is not this page's business.
    local PANEL_H_FRACTION = 0.90
    local PANEL_H = 490   -- replaced by ResolvePanelHeight() before first layout
    -- 240 until the right-hand header stopped needing so much room: the search box
    -- and the Add-from-Database button used to share one row and fight for width, so
    -- the right column was sized around the worst case. They are on separate rows
    -- now, and the 30px goes to the filter list, where long custom names and the
    -- longer preset names were the things actually running out of space.
    local LEFT_W = 270
    local LEFT_ROW_H = 24
    -- Left-list selection accent bar. Declared here because the row's on/off box is
    -- positioned FROM it -- see the note at row.toggle.
    local ACCENT_X, ACCENT_W = 2, 3

    -- Row shading, shared by BOTH lists (filters on the left, spells on the right).
    -- Pulled from the shared palette rather than re-typed, so a retheme moves them.
    --
    -- ⚠ Both panels take CreatePanelBackdrop's DEFAULT, which is C_PANEL (0.12) —
    -- not the darker C_BACKGROUND. Getting that backwards once already cost a round
    -- trip, so it is written down here:
    --   rest  = the BACKGROUND tone at 0.6, which lands UNDER the panel it sits on,
    --           so each row reads as a recessed well. That well is what makes the
    --           list look like a set of things you can click rather than lines of
    --           text — it was never the problem and must not be flattened.
    --   hover = C_HOVER, the value the main nav uses, well clear of the panel.
    -- The old hover was 0.12, exactly the panel's own value, so hovering dissolved a
    -- row INTO the background instead of lighting it up. That was the whole bug.
    local C = GUI.Colors
    local ROW_REST_R,  ROW_REST_G,  ROW_REST_B  = C.background.r, C.background.g, C.background.b
    local ROW_HOVER_R, ROW_HOVER_G, ROW_HOVER_B = C.hover.r, C.hover.g, C.hover.b
    local ROW_REST_A, ROW_HOVER_A = 0.6, 1

    -- ⚠ SPELL ROWS ONLY (right panel). A hovered row climbs to C_HOVER (0.22) —
    -- which is where its own controls live. Their fill is C_ELEMENT (0.18) and
    -- their rest border is C_BORDER at HALF alpha, which over a hovered row
    -- composites to ~0.235: a 0.015 difference, so a button dissolves into the
    -- highlight it is sitting on. At rest the row is ~0.10 and the same button
    -- is 0.084 clear, which is why they only merge on hover.
    --
    -- Only row.remove needs it now: the row's click does not fire that button, so it
    -- just gets its border brightened enough to stay legible. Priming a destructive
    -- "x" the row will NOT trigger would be worse than the merge.
    --
    -- row.check is deliberately not wired in: its checked mark is accent-coloured, so
    -- it separates from the wash by HUE rather than by a few percent of grey, and it
    -- takes no mouse of its own. (The membership BUTTON that used to live here did
    -- need the full SetHovered treatment -- it is gone, and so is that branch.)
    --
    -- This does not move the row's own colour, which the main nav shares. The
    -- button's own OnEnter/OnLeave still owns its look while the mouse is on it;
    -- leaving a child re-enters the row, so the row's OnEnter re-applies after.
    --
    -- Left-hand filter rows carry no chromed controls (a label, a count and the
    -- override dot), so they are deliberately not wired to this.
    -- Derived, not picked by eye: at rest the border reads ~0.235 on a ~0.096 row,
    -- a separation of ~0.14. Holding that same separation above a 0.22 hovered row
    -- wants ~0.36 at full alpha. 0.40 gives a little margin without making the
    -- button louder under the row's hover than under its own. One constant to
    -- nudge if it wants more or less in game.
    local ROW_CTRL_BORDER = 0.40
    -- No table + ipairs: these run on every hover and this file keeps the pooled
    -- row handlers allocation-free on purpose (see the file-local note up top).
    local function ShadeControl(btn, r, g, b, a)
        -- A disabled control must stay dim — SetDisabled parks its own faint
        -- border and expects nothing to light it up.
        if btn and not btn.dfDisabled then btn:SetBackdropBorderColor(r, g, b, a) end
    end
    local function ShadeRowControls(row, hovered)
        local r, g, b, a
        if hovered then
            r, g, b, a = ROW_CTRL_BORDER, ROW_CTRL_BORDER, ROW_CTRL_BORDER, 1
        else
            r, g, b, a = C.border.r, C.border.g, C.border.b, 0.5   -- StyleButton's rest
        end
        ShadeControl(row.remove, r, g, b, a)
    end
    local SECTION_H = 26 -- section-label slot (bumped for the larger DFFontNormal labels)
    local SPELL_ROW_H = 26
    local CLASS_HEADER_H = 22
    -- (TOP_INSET moved up beside PANEL_CHROME_H — the two are one sum now.)
    -- One dial for the status line's vertical cost. HEADER_H and the two rows below
    -- the title all derive from it, so they cannot drift apart again.
    local STATUS_ROW_H = 18
    -- Slot for the caption above the filter name. It is PERMANENT even when the
    -- caption is blank (the Debuffs tab's one row is a Blizzard list, not a filter):
    -- a header that changes height on a tab switch makes the whole right column jump.
    local EYEBROW_H = 13
    local HEADER_H = 92 + STATUS_ROW_H + EYEBROW_H -- right column header (caption + 3 rows + status)

    -- ========== STATE ==========
    -- ⚠ Page state lives here, at the top, because a local declared further down the
    -- file reads as a nil GLOBAL from a closure created earlier. (This note used to
    -- explain the placement of `leftTab` specifically -- there is no such local any
    -- more; the tab strip it belonged to is gone. The rule it states still applies to
    -- everything below.)
    local selKind = "preset" -- "preset" | "custom"
    local selKey = R.Categories[1] and R.Categories[1].key
    local searchText = "" -- lowercased query
    -- Records whose spell-ID children are showing. VIEW state only, never saved:
    -- an expander is where you are looking, not what you configured. Keyed by
    -- rec.id, so a record expanded under one filter stays expanded when the same
    -- spell appears under another -- which is the point, since the mute it edits
    -- is filter-independent too.
    local expandedRecords = {}

    local RefreshLeft, RefreshRight, RefreshAll, UpdateActionStates, OpenPicker -- forward declarations

    -- ========== CHANGE PROPAGATION ==========
    -- The aura pipeline's reaction to a filter-definition change. Mirrors the
    -- local DirectFilterChanged on the Aura Filters page (not visible here).
    local function DirectFilterChangedProxy()
        if DF.RebuildDirectFilterStrings then
            DF:RebuildDirectFilterStrings()
        end
        if DF.InvalidateAuraLayout then
            DF:InvalidateAuraLayout()
        end
    end

    -- ☠ NOTHING DEBUFF LIVES ON THIS PAGE. The Optional Debuffs list, Blizzard's
    -- debuff categories and the which-dispels-count dropdown all moved to the Debuff
    -- Bar page (GUI/Pages/Indicators.lua) when selection moved out to the consumers.
    -- Their storage is unchanged -- the same per-mode `debuffBlacklist` and
    -- `debuffFilter*` keys -- only the UI moved.
    --
    -- Do not fold any of it back in. Debuffs are not filters: membership is
    -- Blizzard's and cannot be edited, so pairing them with an editable buff library
    -- under one tab strip taught every reader that the two worked the same way.

    -- Row kinds that own an editable spell list, and so can become the right-hand
    -- pane's selection. Both remaining kinds qualify, so this is always true for
    -- anything in the list -- kept because the row handler is written against KINDS,
    -- and a page that later grows a non-editable row would otherwise silently open a
    -- blank editor for it.
    local SELECTABLE_KIND = { preset = true, custom = true }

    -- ========== FILTER SELECTION (which filters are ON for this mode) ==========
    -- Moved here from the old Aura Filters page. Same live-resolution rule as the
    -- blacklist above and for the same reason: this page builds ONCE and its guard
    -- path never re-captures a db, so a capture taken at build time would write to
    -- whichever mode happened to be selected then -- ticking a filter in Raid would
    -- silently edit Party.
    --
    -- ⚠ THE ASYMMETRY, because it surprises everyone including us: which filters are
    -- ON is PER-MODE (mode db), but which spells are IN a filter is ACCOUNT-WIDE (the
    -- registry). Editing Healing in Party also edits it in Raid; switching Healing on
    -- does not. The status bar says so out loud.
    local function ModeDB()
        return DF.db and DF.db[GUI.SelectedMode or "party"]
    end

    -- ⚠ Create-if-missing only. NEVER reassign an existing inner table: the aura
    -- pipeline holds references to these and a fresh table strands them.
    local function BuffSelection()
        local mdb = ModeDB()
        if not mdb then return nil end
        mdb.buffFilterSelection = mdb.buffFilterSelection or {}
        local sel = mdb.buffFilterSelection
        sel.presets = sel.presets or {}
        sel.customs = sel.customs or {}
        return sel
    end

    -- READ-ONLY from here on. Every setter went to the page that owns the control it
    -- drove; what stays is what the status line and the consumer chips need in order
    -- to REPORT which filters each consumer is using.
    -- (IsPresetOn / IsCustomOn are gone. They answered "is this filter on for the
    -- CURRENT mode", which is a question this page can no longer sensibly ask -- it
    -- has no mode. FilterConsumers walks both modes and reads the selection tables
    -- itself.)
    local function GetFlag(key)
        local mdb = ModeDB()
        return (mdb and mdb[key]) and true or false
    end

    -- ========== CUSTOM FILTER HELPERS ==========
    -- Stable name-sorted id list (the store is id-keyed)
    local function SortedCustomIDs()
        local ids = {}
        for cfId in pairs(R:ReadStore().customFilters) do
            ids[#ids + 1] = cfId
        end
        tsort(ids, function(a, b)
            local fa, fb = R:GetCustomFilter(a), R:GetCustomFilter(b)
            local na, nb = (fa and fa.name or ""), (fb and fb.name or "")
            if na ~= nb then return na < nb end
            return a < b
        end)
        return ids
    end

-- ★ ONE COUNT STRING FOR A CUSTOM FILTER, so the pane header and the slot corner can
-- never disagree (the note at the corner site says exactly that). Mirrors the left-hand
-- list's rule at BindLeftRow: a curated list reads "34 of 39 spells" once something is
-- ticked off, a hand-built one can have nothing off, answers enabled == total, and keeps
-- the single number it has always shown.
-- ⚠ THIS REPLACED A LOCAL `CustomSpellCount`, which moved to the registry as
-- R:CustomFilterCounts. Two call sites for it arrived on main AFTER this branch forked
-- (the Filter Designer list rework) and merged in CLEANLY, leaving calls to a function
-- this branch had deleted -- a nil-call with no conflict to warn anyone. Keep both
-- readers pointed here.
local function CustomCountText(cfId)
    local R = DF.FilterRegistry
    if not (R and R.CustomFilterCounts and cfId) then return format(L["%d spells"], 0) end
    local onN, totalN = R:CustomFilterCounts(cfId)
    onN, totalN = onN or 0, totalN or 0
    if onN == totalN then return format(L["%d spells"], totalN) end
    return format(L["%d of %d spells"], onN, totalN)
end

    -- ⚠ CustomSpellCount WENT TO THE REGISTRY as R:CustomFilterCounts, because it was one
    -- of THREE places counting the same thing and none of them honoured a curated list's
    -- per-spell ticks. One counter, three consumers -- this file's left list and header,
    -- and R:ListFilters, which the Buff Bar's picker reads.

    -- Display name of the current selection (duplicate-prompt prefill)
    local function CurrentDisplayName()
        if selKind == "preset" then
            for _, cat in ipairs(R.Categories) do
                if cat.key == selKey then return L[cat.name] end
            end
            return selKey and tostring(selKey) or ""
        end
        local f = R:GetCustomFilter(selKey)
        return f and (f.name or tostring(selKey)) or ""
    end

    -- ========== INFO BANNER ==========
    -- The banner text + tone swap by selection: the buff filters are a whitelist
    -- (opt-in — nothing shows until a filter carrying it is on), the blacklist is
    -- the inverse (opt-out — you name what to hide rather than what to show).
    -- Naming that flip is what keeps the Hide/Show rows from reading like the
    -- Enable/Disable ones above.
    --
    -- ⚠ The blacklist copy must NOT say debuffs "all show" — the Aura Filters page
    -- carries a debuffFilter selection that already restricts them, so opt-out
    -- describes the MECHANISM here, not the starting state.
    --
    -- Each text also has to carry what you can DO, because the two halves differ:
    -- buff filters are editable and you can add your own, while the blacklist is a
    -- fixed catalog (BlacklistDebuffs) with search, add-by-ID, add-from-database
    -- and Duplicate all hidden or disabled. "This list is fixed" is what answers
    -- the missing add button.
    --
    -- Both texts are ~2 lines, so the swap barely changes the banner height. RefreshRight
    -- drives the swap; SetHTML is idempotent so it only recomputes on a real
    -- buff<->blacklist transition. HTML mode so the buff copy links back to the
    -- Aura Filters page (which links here) — SetHTML re-tints the link per theme.
    local function fdBannerLink(text, pageId)
        local tc = (GUI.GetThemeColor and GUI.GetThemeColor()) or { r = 1, g = 0.82, b = 0 }
        local col = string.format("|cFF%02X%02X%02X",
            math.floor((tc.r or 1) * 255), math.floor((tc.g or 1) * 255), math.floor((tc.b or 1) * 255))
        return col .. "|HdfPage:" .. pageId .. "|h" .. text .. "|h|r"
    end
    -- Where each banner link lands. A bare page id only switches tabs; an entry here
    -- also scrolls to that page's section and pulses it, through the shared
    -- settings-link path every other cross-page link in the GUI uses.
    --
    -- ☠ GUI:LinkToSetting, not a hand-rolled SelectTab + timer. It owns both timings
    -- (0.12 for the tab to build, 0.05 for the scroll to settle) and it calls
    -- Search:ScrollToSection itself. The search breadcrumb learned this the hard way
    -- -- see the note at Features/Search.lua:898.
    --
    -- ⚠ BORDER ONLY, and both flags are required: FlashWidget's fill is opt-OUT
    -- (`opts.fill ~= false`), so passing border alone outlines AND washes the target.
    -- "Defensive Filters" resolves to a whole settings group, which is a large area
    -- for a filled pulse (same call as the search breadcrumb, Krathe 2026-08-07).
    --
    -- ⚠ Only the Defensive Icon has an entry. The Aura Designer's filter selection is
    -- not a page section at all -- it lives per filter GROUP, inside a card the user
    -- may never have created -- so there is nothing stable to scroll to, and a section
    -- that does not resolve lands you on the page with no flash, which reads as a dead
    -- link. Same for the Buffs page, where the bar is the whole page rather than a
    -- section of it.
    -- Every consumer now has a named section to land on, because every consumer now
    -- picks its own filters. Before the move only the Defensive Icon did, which is
    -- why it was the only entry here.
    --
    -- ⚠ The Aura Designer has no entry ON PURPOSE. Its filter selection is not a page
    -- section -- it lives per filter GROUP, inside a card the user may never have
    -- created -- so there is nothing stable to scroll to, and a section that does not
    -- resolve lands you on the page with no flash, which reads as a dead link.
    local BANNER_LINK_SECTION = {
        auras_buffs         = L["Buff Filters"],
        auras_debuffs       = L["Debuff Filters"],
        auras_defensiveicon = L["Defensive Filters"],
    }
    local function fdBannerLinkClick(pageId)
        -- ⚠ A banner link that lands on a page id nothing registered is a SILENT
        -- no-op: the word is styled and hover-lit like every other link, the click
        -- runs, and nothing happens. That is indistinguishable from a dead link and
        -- it is what a page-id typo looks like from the outside, so say so.
        if not (GUI.Pages and GUI.Pages[pageId]) then
            DF:DebugWarn("GUI", "Filter Designer banner link points at unregistered page '%s'", tostring(pageId))
            return
        end
        local section = BANNER_LINK_SECTION[pageId]
        if section and GUI.LinkToSetting then
            GUI:LinkToSetting({
                page    = pageId,
                section = section,
                flash   = { fill = false, border = true },
            })
        elseif GUI.SelectTab then
            GUI.SelectTab(pageId)
        end
    end
    -- Krathe's copy, 2026-08-09, adopted verbatim bar three fixes (a "bellow"
    -- typo, "are a list" -> "are lists" for the plural subject, and "Buff Bar" ->
    -- "Buff Bar" to agree with the page of that name and the status line's
    -- L["Buff Bar (%s)"] a few inches right of here).
    --
    -- Three beats, in the order a newcomer needs them: what a filter IS, what you may
    -- do to one, and what selecting it does. The first predecessor opened on the
    -- freedom ("You have full control over buff filters"), which answers a question the
    -- reader has not reached -- they do not yet know what the thing is.
    --
    -- ⚠ This comment described beat one for a while before the copy actually had it:
    -- a draft opened "This page designs BUFF filters", which is what the PAGE does,
    -- not what a filter IS. Naming the activity still assumes the reader knows the
    -- noun. Fixed 2026-08-10 -- beat one is the em-dash appositive ("lists of the
    -- buffs you want to see"), and it is a definition or this comment is lying again.
    --
    -- ⚠ This banner now carries the ENTIRE model, because the section headers no
    -- longer help: they read "Built-In Filters" / "Custom Buff Filters", which name
    -- the groups but say nothing about the checkbox. "Selecting them below" is
    -- therefore the ONLY statement of what a tick does, and "below" is a real
    -- reference to the list underneath -- do not reorder the page so that stops being
    -- true, and do not trim that clause as redundant. It is not redundant any more.
    --
    -- ⚠ It also supersedes the old "one sentence, deliberately" rule. That rule was a
    -- reaction to a predecessor running to two paragraphs and six links; three short
    -- sentences and two links is not that, and the page had been under-explaining
    -- itself -- which is the complaint this rewrite answers.
    --
    -- It does NOT say "editing a filter changes it everywhere it is used". That
    -- warning is not dropped, it is placed where it can be accurate: the STATUS LINE
    -- under each filter's name lists that filter's actual consumers, live, which a
    -- fixed sentence cannot do -- whether the Aura Designer uses a given filter
    -- depends on whether you have built a filter group and linked it.
    --
    -- ⚠ SIX %s, and they are NOT all the same kind. In reading order:
    --   1  Buff Filters      -- coloured emphasis (green)
    --   2  Buff Bar          -- page link
    --   3  Defensive Icon    -- page link
    --   4  Aura Designer     -- page link
    --   5  Debuff Filters    -- coloured emphasis (red)
    --   6  Debuff Bar        -- page link
    -- The four links must stay bare destination names -- an article glued on in
    -- translation lands inside the underline.
    --
    -- ⚠ #2 reads "Buff Bar" because that is now the PAGE's name -- the Buffs page was
    -- renamed to Buff Bar in the same change, precisely so that the thing this sentence
    -- names and the thing the link lands on are the same words. One string,
    -- L["Buff Bar"], shared by the nav row, every See Also and this link.
    --
    -- ⚠ #1 and #5 reuse L["Buff Filters"] / L["Debuff Filters"] -- the SAME strings
    -- BANNER_LINK_SECTION above scrolls to and pulses. So the coloured phrase here is
    -- literally the name of the group the reader lands on, not a paraphrase of it.
    -- That is why they are Title Case mid-sentence; do not "fix" the capitals.
    --
    -- ⚠ Colour, not caps, and not bold. The draft this replaced shouted BUFF to say
    -- buffs-only; Krathe's call 2026-08-10 was to emphasise instead. Bold is not
    -- available -- a FontString has no weight axis, "bold" in WoW means either a
    -- different font FILE (we ship Roboto-Bold, but SetSettingsFont resolves the
    -- USER's chosen settings font, so hard-coding one face makes the emphasised words
    -- the only text on the page ignoring that setting) or the OUTLINE flag, which at
    -- 11px reads as smeared rather than heavy. Colour has neither problem and is what
    -- WoW itself uses for inline emphasis.
    --
    -- ⚠ Deliberately NOT GUI:ToneHex("success"/"danger"), which is the sanctioned
    -- helper for inline emphasis and is WRONG here: those hexes carry the banner tone
    -- vocabulary, so a red drawn from it would say this debuff sentence is a warning.
    -- It is not -- it is a neutral statement of who authors those filters. These two
    -- are category colours (which kind of aura), muted to sit inside an info banner.
    --
    -- The words differ too ("Buff Filters" vs "Debuff Filters"), so the colour is
    -- redundant reinforcement rather than the only thing distinguishing them -- which
    -- is what keeps a red/green pair legible to a red-green colourblind reader.
    -- ⚠ The red's blue channel sits BELOW its green (47 < 62) and that is the whole
    -- point of the value. The first pass used ffe07a7a, which has G and B identical --
    -- equal G/B is what makes a red read as rose, and it did: "almost pink" (Krathe,
    -- 2026-08-10). Brightening it does not help, it just turns the pink up. Tipping
    -- blue under green is what makes it read as red at this lightness, so if these
    -- are ever retuned, keep B < G rather than raising luminance.
    local EMPH_BUFF   = "ff7be08c"
    local EMPH_DEBUFF = "ffff6247"
    -- ☠ PER WORD, not once around the phrase. The banner renders through SetHTML,
    -- which splits plain text on SPACES and gives every word its own FontString -- so
    -- a |c…|r spanning two words dies at the split: the opener lands on "Buff", the
    -- |r lands on "Filters", and word two falls back to the body grey. That is not a
    -- theory, it is what shipped for one revision (Krathe, 2026-08-10): the banner
    -- drew a green "Buff" beside a grey "Filters" while the popup -- ONE FontString,
    -- no splitting -- drew the whole phrase green off the identical string.
    --
    -- Wrapping each word is correct in both renderers, because the gaps between the
    -- tokens are spaces and a space has no ink to colour. Anything that formats text
    -- for the banner must do this; a phrase helper that wraps once is only ever right
    -- by accident, when the phrase happens to be a single word.
    local function fdEmph(text, hex)
        return (text:gsub("%S+", function(w) return "|c" .. hex .. w .. "|r" end))
    end
    local BUFF_BANNER = format(
        L["This page designs %s — lists of the buffs you want to see. Change what is in our built-in ones, or build your own. Then pick the ones you want on the %s, the %s, or in %s. %s are Blizzard's — they can't be edited, and you pick those on the %s page."],
        fdEmph(L["Buff Filters"], EMPH_BUFF),
        fdBannerLink(L["Buff Bar"], "auras_buffs"),
        fdBannerLink(L["Defensive Icon"], "auras_defensiveicon"),
        fdBannerLink(L["Aura Designer"], "auras_auradesigner"),
        fdEmph(L["Debuff Filters"], EMPH_DEBUFF),
        fdBannerLink(L["Debuff Bar"], "auras_debuffs"))
    -- ⚠ ONE banner on this page, not two. This paragraph described a two-tab world:
    -- a Debuffs tab with its own banner, a SELECTABLE_KIND that included "blacklist",
    -- and a BuildTab that pinned selKind when you landed there. None of those exist
    -- now -- SELECTABLE_KIND is { preset, custom }, there is no BuildTab and no tab
    -- strip, and the Debuffs banner moved to the Debuff Bar page as that group's
    -- subtitle. BUFF_BANNER below is the only banner constant left; the DEBUFF_BANNER
    -- that other comments in this file pointed at is gone.
    -- (The Debuffs-tab banner went to the Debuff Bar page as that group's subtitle.)
    -- The "unselect one to hide it" clause above is the part nobody can guess: the box
    -- means what it means everywhere else on the page -- this debuff shows -- so
    -- hiding one is an UNselect, on a list called Blacklist. "Unselect", not "untick":
    -- the box draws a filled square, not a tick glyph, and select/unselect is now the
    -- page's one vocabulary for a checkbox at either level.
    --
    -- The only real warning on the page, and the reason it is worded around the
    -- COMBINATION: any single category obviously misses things, so saying that adds
    -- nothing. What is surprising is that switching on every category still is not
    -- All Debuffs, because Blizzard tagged some debuffs with none of them and we
    -- cannot widen the categories. Shown only while the categories are in play.
    -- (The all-categories completeness caution went with them.)
    local banner = GUI:CreateInfoBanner(parent, {
        tone = "info",
        html = true,
        text = BUFF_BANNER,
        onLinkClick = fdBannerLinkClick,
    })
    -- Below the Copy/Sync/Reset row the page host adds above us. That row is laid out
    -- by BuildPage's own flow while everything here is positioned absolutely from the
    -- page child, so the two only stay clear of each other because of this inset.
    banner:SetPoint("TOPLEFT", 10, -(10 + TOP_INSET))
    banner:SetPoint("RIGHT", -10, 0)

    -- Which registry filters does one Aura Designer config reference? Groups carry
    -- the same {presets, customs} selection shape the bars do, but they live in two
    -- stores under a config:
    --   .layoutGroups      -- spec-keyed post-V2 ({ [specKey] = {groups} }), still a
    --                         flat array on unmigrated data, so BOTH shapes are walked
    --   .otherLayoutGroups -- Other Buffs, a flat array only (newer store)
    -- Same dual-shape dispatch as ScrubDeletedFilter at the top of this file and the
    -- export collector in Profile.lua; a walk that handled only one shape would
    -- silently under-report, which is the failure mode that matters here.
    --
    -- ⚠ GROUPS ARE NO LONGER THE ONLY WAY. As of 12.1 alpha 18 an Aura Designer
    -- EFFECT can reference a filter too, as a plain string rather than a selection
    -- table -- either filed under the "@preset:<key>" / "@custom:<id>" aura key (a
    -- filter-owned effect) or listed as one of an effect's TRIGGERS. A walk that
    -- only visits filterSelection reports a filter driving nothing but an effect as
    -- unused, which is the same silent under-report warned about above, one store
    -- further along.
    --
    -- Written as COLLECT-then-ask rather than a per-filter search so there is one
    -- walk to keep correct instead of two: the chip row below asks for the whole
    -- set, the status line asks about a single filter through ADConfigUses, and both
    -- come through here.
    --
    -- ⚠ Defined HERE, above the chips, and not next to ADConfigUses where it reads
    -- more naturally. The chip refresh calls it, and a local declared later in this
    -- file is a nil GLOBAL at this point -- which parses clean and only errors when
    -- the page refreshes.
    --
    -- Keys are "kind\0key". The \0 is deliberate: a custom filter id is free text
    -- and a printable separator could collide with one.
    local function CollectADFilters(cfg, out)
        if type(cfg) ~= "table" then return out end
        local function fromGroups(groups)
            for _, g in ipairs(groups) do
                local sel = type(g) == "table" and g.filterSelection
                if type(sel) == "table" then
                    for k in pairs(sel.presets or {}) do out["preset\0" .. tostring(k)] = true end
                    for k in pairs(sel.customs or {}) do out["custom\0" .. tostring(k)] = true end
                end
            end
        end
        local lg = cfg.layoutGroups
        if type(lg) == "table" then
            if lg[1] ~= nil then fromGroups(lg) end   -- legacy flat array
            for k, v in pairs(lg) do
                if type(k) == "string" and type(v) == "table" then fromGroups(v) end
            end
        end
        if type(cfg.otherLayoutGroups) == "table" then fromGroups(cfg.otherLayoutGroups) end

        -- Effect references. Guarded on the PARSER rather than assuming it is there:
        -- this file ships in the options companion and DF:ParseADFilterRef in the
        -- base addon, so a version skew between the two has to degrade to the old
        -- group-only answer instead of erroring on every refresh.
        if DF.ParseADFilterRef then
            local function fromRef(name)
                if type(name) ~= "string" then return end
                local k, key = DF:ParseADFilterRef(name)
                if k and key then out[k .. "\0" .. tostring(key)] = true end
            end
            local function fromAuraStore(store)
                if type(store) ~= "table" then return end
                for auraName, auraCfg in pairs(store) do
                    fromRef(auraName)
                    if type(auraCfg) == "table" then
                        for _, typeCfg in pairs(auraCfg) do
                            if type(typeCfg) == "table" and type(typeCfg.triggers) == "table" then
                                for _, t in ipairs(typeCfg.triggers) do fromRef(t) end
                            end
                        end
                    end
                end
            end
            -- auras is spec-keyed ({ [specKey] = { [name] = cfg } }); otherAuras is flat.
            if type(cfg.auras) == "table" then
                for _, specAuras in pairs(cfg.auras) do fromAuraStore(specAuras) end
            end
            fromAuraStore(cfg.otherAuras)
        end
        return out
    end

    -- ========== CONSUMER CHIPS ==========
    -- What is drawing on this library, right now, at the TOP of the page.
    --
    -- The information already existed: a See Also footer at the FOOT of the page
    -- listed the same consumer pages. It was doing nothing. This page anchors two
    -- full-height panels, so its footer sits below them and is off-screen on any
    -- normal window -- and it was a static link bar rather than a readout. Same
    -- destinations, moved to where they are seen, and made live.
    --
    -- ⚠ The "not in use" state is the point, not a fallback. A user with no filter
    -- groups reads "Aura Designer -- not in use" and learns that a subsystem the
    -- banner names is not currently involved in anything on their screen. That is
    -- the "what can I safely ignore" answer, and a static link bar can never give
    -- it: a link looks equally important whether or not it leads anywhere.
    --
    -- The chips also carry, by having different counts from different places, the
    -- fact that each consumer chooses its filters somewhere different.
    --
    -- ☠ THEY SWAP WITH THE TAB, and the set is a different SIZE on each side. The
    -- chips claim to say what is drawing on what this page controls, so while the
    -- Debuffs tab is showing they have to answer for DEBUFFS -- a buff-filter count
    -- sitting above a list of Blizzard categories is not merely unhelpful, it is the
    -- page telling you the two are the same system when the whole point is that they
    -- are not.
    --
    -- The Defensive Icon has no debuff chip because it has no debuff side: its
    -- selection is buff filters only. That absence is correct and is itself part of
    -- the answer -- do not add a greyed one "for symmetry".
    local CHIP_DEFS_BUFF = {
        { key = "buff",      pageId = "auras_buffs",         label = L["Buff Bar"],
          tip = L["The Buff Bar picks its own filters, on its own page."] },
        { key = "defensive", pageId = "auras_defensiveicon", label = L["Defensive Icon"],
          tip = L["The Defensive Icon picks its own filters, on its own page."] },
        { key = "designer",  pageId = "auras_auradesigner",  label = L["Aura Designer"],
          tip = L["Aura Designer filter groups and effects can use any of these filters."] },
    }
    -- ⚠ NO DEBUFF CHIP SET. There was one while this page had a Debuffs tab; it went
    -- with the tab. The debuff bar does not draw on this library at all, so a debuff
    -- chip here would claim a relationship that does not exist.
    local CHIP_POOL_N = #CHIP_DEFS_BUFF
    local chipRow = CreateFrame("Frame", nil, parent)
    chipRow:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -10)
    chipRow:SetPoint("RIGHT", banner, "RIGHT", 0, 0)
    chipRow:SetHeight(CHIP_H)

    -- ⚠ The chips are SIZED FROM THE ROW, not given a fixed width. They were fixed
    -- at 170 and it was wrong twice over: the help button is pinned to the row's
    -- right edge, so on a narrower window the third chip ran underneath it, and a
    -- label like "Defensive Icon  2 filters" overflows 170px and spills into its
    -- neighbour, which is what made the chips look merged. Both are the same bug --
    -- a constant standing in for a measurement.
    local CHIP_GAP  = 6
    -- Square: the help control is the "?" glyph alone. It was a 128px labelled
    -- button, which spent most of a chip's worth of the row saying something the
    -- icon already says -- and the chips are the part of this row that has to fit
    -- three variable-length labels.
    local CHIP_HELP_W = CHIP_H
    local CHIP_MIN_W  = 92

    -- A POOL, bound per refresh, not one button per definition: the two tab sets are
    -- different lengths, so a per-definition build would have to create and destroy
    -- frames on a tab switch. Every handler reads self.chipDef, which RefreshChips
    -- rebinds -- nothing closes over a definition.
    --
    -- ⚠ StyleButton only creates btn.Text when opts.text is a NON-EMPTY string, so
    -- the placeholder is a space rather than "". With "" there is no fontstring and
    -- the first refresh errors on b.Text.
    local chipButtons = {}
    -- ...and the BAND ARM's own standing buttons, which live on the ACTION BAND
    -- above the filter list rather than on this row. Declared here so the theme
    -- pass below can reach them: the band itself is built ~2,000 lines down,
    -- inside the `rowsMode` arm.
    local bandButtons = {}
    -- ☠ THE BAND ARM'S "USED BY", AND IT IS ONE TABLE RATHER THAN FOUR LOCALS --
    -- see PANE's note on this builder's local budget. Holds the band frame, its
    -- height, its three rows and its refresh verb.
    --
    -- ⚠ IT CAME BACK. An earlier pass removed it, reasoning that "used by" is
    -- per-FILTER and so has no single answer on a page that lists many filters.
    -- That is true of the per-filter line -- which is why that one lives in each
    -- panel's header -- and it is NOT true of these three: ChipDetail answers
    -- "how many filters does the Buff Bar use", which is a fact about the
    -- CONSUMER and does not vary by selection at all. Two different questions
    -- that happened to share a name.
    local USEDBY = {}
    -- Assigned in that same arm. Forward-declared so RefreshAll -- which is
    -- written before it -- can call it without capturing a nil upvalue.
    local RefreshFilterRows
    for i = 1, CHIP_POOL_N do
        local b = CreateFrame("Button", nil, chipRow, "BackdropTemplate")
        GUI:StyleButton(b, { width = CHIP_MIN_W, height = CHIP_H, text = " " })
        -- Non-wrapping with a width, set in LayoutChips: a label too long for its
        -- chip then ellipsises inside it instead of drawing past its own edge.
        if b.Text then b.Text:SetWordWrap(false) end
        -- Anchored by LayoutChips, which owns the wrap; see its header. A build-time
        -- chain LEFT-of-the-previous cannot express a second row.
        b:SetPoint("TOPLEFT", chipRow, "TOPLEFT", 0, 0)
        -- Same dispatcher as the banner links, so the Defensive Icon chip scrolls to
        -- and pulses that page's filter section exactly as the banner's link does.
        b:SetScript("OnClick", function(self)
            if self.chipDef then fdBannerLinkClick(self.chipDef.pageId) end
        end)
        b:HookScript("OnEnter", function(self)
            if self.chipDef then
                GUI:ShowTooltip(self, { title = self.chipDef.label, lines = { self.chipDef.tip } })
            end
        end)
        b:HookScript("OnLeave", function() GUI:HideTooltip() end)
        b:Hide()   -- RefreshChips shows the ones this tab uses
        chipButtons[i] = b
    end

    -- 0 reads as a STATE, not a quantity: "0 filters" invites you to wonder what
    -- went wrong, where "Not in use" is simply an answer.
    --
    -- Three counters rather than one with a noun argument, because the plural rule
    -- is the translator's to make and a "%d %s" sentence takes it away from them.
    local function FilterCountText(n)
        if n <= 0 then return L["Not in use"] end
        if n == 1 then return L["1 filter"] end
        return format(L["%d filters"], n)
    end
    -- (The category and group counters went with the debuff chips.)

    -- Every Aura Designer config this MODE actually resolves to: its own, plus any
    -- pinned set that overrides it with a different preset. Same scope as the status
    -- line's consumer list -- a preset sitting unused in the library is not "in use",
    -- and counting it would make the chip meaningless for anyone who keeps spares.
    --
    -- Deduped by table identity: a pinned set naming the mode's own preset resolves
    -- to the very same table, and counting it twice doubles the debuff-group count.
    local function ADConfigsInScope()
        local out, seen = {}, {}
        local function take(c)
            if type(c) == "table" and not seen[c] then
                seen[c] = true
                out[#out + 1] = c
            end
        end
        take(DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(GUI.SelectedMode or "party"))
        local mdb = ModeDB()
        local lib = DF.GetAuraDesignerPresets and DF:GetAuraDesignerPresets()
        local pf = mdb and mdb.pinnedFrames
        if lib and pf and type(pf.sets) == "table" then
            for _, s in pairs(pf.sets) do
                local name = type(s) == "table" and s.auraDesignerPreset
                if name then take(lib[name]) end
            end
        end
        return out
    end

    -- Counts FILTERS, not auras -- the tab strip above already carries the aura
    -- total, and repeating it here would make two numbers on one screen that look
    -- comparable and are not.
    local function ChipDetail(key)
        if key == "buff" then
            -- All Buffs overrides the selection entirely, so a filter count would be
            -- true and misleading at the same time.
            if GetFlag("directBuffShowAll") then return L["All buffs"] end
            local sel = BuffSelection()
            local n = 0
            if sel then
                for _ in pairs(sel.presets or {}) do n = n + 1 end
                for _ in pairs(sel.customs or {}) do n = n + 1 end
            end
            return FilterCountText(n)
        elseif key == "defensive" then
            local mdb = ModeDB()
            local sel = mdb and mdb.defensiveFilterSelection
            local n = 0
            if type(sel) == "table" then
                for _ in pairs(sel.presets or {}) do n = n + 1 end
                for _ in pairs(sel.customs or {}) do n = n + 1 end
            end
            return FilterCountText(n)

        end

        -- "designer": which registry filters the Aura Designer references at all.
        local set = {}
        for _, cfg in ipairs(ADConfigsInScope()) do CollectADFilters(cfg, set) end
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        return FilterCountText(n)
    end

    -- Which consumers are actually drawing on the library, as one line. This is the
    -- BAND ARM's row summary: the chips answer "how many filters each" and a row
    -- summary has space for neither three labels nor three counts, so it answers
    -- the shorter question -- WHO -- and the panel behind it carries the numbers.
    --
    -- ⚠ Reuses L["Not in use"], the chips' own zero state, rather than adding a
    -- second way to say nothing is using this.
    local function ConsumerSummary()
        local names = {}
        for _, def in ipairs(CHIP_DEFS_BUFF) do
            if ChipDetail(def.key) ~= L["Not in use"] then
                names[#names + 1] = def.label
            end
        end
        if #names == 0 then return L["Not in use"] end
        return table.concat(names, ", ")
    end

    -- Share the row between the chips and the help button pinned to its right edge.
    -- Runs on every resize AND after every text change, because the widths are what
    -- keep the labels from colliding.
    -- ⚠ Divides by the SHOWN count, not the pool size. The Debuffs tab uses two of
    -- the three, and sizing for three there would leave a chip's width of dead space
    -- before the help button.
    -- ☠ AND THEY WRAP, BECAUSE ONE ROW HAS A FLOOR THIS PAGE CAN NO LONGER PAY.
    -- The help glyph is pinned to the row's right edge and CHIP_MIN_W is the point
    -- past which a label like "Defensive Icon  2 filters" stops being readable, so
    -- three chips need 3*92 + 2*6 + 6 + 22 = 316px. That fitted only because this
    -- page forced the window to 850; at the 520px minimum the band is ~280 and the
    -- third chip ran underneath the help button. Below the floor they take as many
    -- rows as they need instead of overlapping.
    --
    -- ⚠ THE CHIPS ARE ANCHORED HERE, NOT AT BUILD. They used to chain LEFT off each
    -- other, which cannot express a second row; this owns both axes so the wrap has
    -- one writer.
    local function LayoutChips()
        local rowW = chipRow:GetWidth() or 0
        if rowW < 60 then return end   -- not laid out yet; OnSizeChanged re-runs us
        local shown = {}
        for _, b in ipairs(chipButtons) do
            if b:IsShown() then shown[#shown + 1] = b end
        end
        local n = #shown
        if n == 0 then return end
        -- What the chips have, once the help glyph and its gutter are taken out.
        local avail = rowW - CHIP_HELP_W - CHIP_GAP
        -- How many fit at the floor. mmax(1, ...) rather than a guard: one chip per
        -- row is the honest answer at a width that cannot hold two, and a zero here
        -- would divide by nothing below.
        local perRow = mmax(1, mfloor((avail + CHIP_GAP) / (CHIP_MIN_W + CHIP_GAP)))
        if perRow > n then perRow = n end
        local rows = mceil(n / perRow)
        -- ⚠ Divides by what is on THIS row, not by the shown count: the last row of
        -- a wrap holds fewer, and sizing every chip to the short row's share would
        -- leave the full rows with a chip's worth of dead space on the end.
        local w = mmax(CHIP_MIN_W, mfloor((avail - CHIP_GAP * (perRow - 1)) / perRow))
        for i, b in ipairs(shown) do
            local col   = (i - 1) % perRow
            local rowIx = mfloor((i - 1) / perRow)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", chipRow, "TOPLEFT",
                       col * (w + CHIP_GAP), -(rowIx * (CHIP_H + CHIP_GAP)))
            b:SetWidth(w)
            if b.Text then b.Text:SetWidth(w - 10) end
        end
        local h = rows * CHIP_H + (rows - 1) * CHIP_GAP
        -- ⚠ AND THE BAND IS TOLD. A height measured before layout and then SPENT is
        -- the Class-1 trap this rework has already paid for twice; this runs from
        -- OnSizeChanged, which is when the real width finally arrives, and re-reports
        -- through layoutHeight + RefreshStates rather than leaving every band below
        -- it sitting at a stale offset.
        --
        -- ☠ ONE WRITER, EITHER WAY. In the band arm the frame IS the band, so
        -- dfSetHeight owns its height and the gap to the next band rides in the
        -- SLOT -- the chips are top-anchored, so the extra is air at the bottom.
        -- Setting the height here as WELL would have this fighting dfSetHeight
        -- across an OnSizeChanged that each of them fires.
        if chipRow.dfSetHeight then
            chipRow.dfSetHeight(h + BAND_GAP, h)
        else
            chipRow:SetHeight(h)
        end
    end
    chipRow:SetScript("OnSizeChanged", LayoutChips)

    local function RefreshChips()
        local defs = CHIP_DEFS_BUFF
        for i, b in ipairs(chipButtons) do
            local def = defs[i]
            b.chipDef = def
            if def then
                b.Text:SetText(format("%s  |cff8a8f9f%s|r", def.label, ChipDetail(def.key)))
                b:Show()
            else
                -- Hidden, not left showing stale text: the pool is longer than the
                -- debuff set, and an unbound chip would keep whatever the buff tab
                -- last wrote into it.
                b:Hide()
            end
        end
        -- After the text and the show/hide, not before: both the shown count and the
        -- label length feed the widths.
        LayoutChips()
    end

    -- ========== "HOW THIS WORKS" ==========
    -- The one thing banner copy cannot carry: the SHAPE. A sentence can define what
    -- a filter is. It cannot show that three different displays each pick their
    -- filters in a different place, or that the Debuffs tab is a separate system
    -- wearing the same controls -- and those two facts are what the page is actually
    -- confusing about.
    --
    -- A labelled LIST rather than drawn art, on purpose: it wraps at any locale
    -- length, needs no textures or layout maths, and carries the same claim. The
    -- addon's singleton alert takes one message string, so the newlines are the
    -- layout.
    --
    -- ⚠ The three destination names are format slots filled from the PAGES' own
    -- L[] strings, not written into the sentence. Rename a page and this follows;
    -- spell one out here and it silently disagrees with the chip next to it.
    --
    -- No buttons table: ShowPopupAlert supplies a single OK when none is given, and
    -- this dialog asks nothing of the reader.
    -- ☠ ".png" IS PART OF THE PATH. Unlike .tga and .blp, whose extension the client
    -- infers, a PNG does not resolve without it -- drop it and this silently renders
    -- nothing. Icons/question.png is the first PNG icon in the addon, shipped
    -- unconverted on purpose to find out how PNG icons behave.
    --
    -- Untinted: the source glyph is #E3E3E3, near enough to the label's own colour
    -- that a SetVertexColor would only be guessing. If it reads dim next to the .tga
    -- icons, the fix is to normalise the ART to white -- a tint multiplies, so it can
    -- darken this glyph but never brighten it.
    --
    -- ⚠ ICON ONLY, so it MUST carry a tooltip: a glyph with no label and no hover
    -- text is a control the reader has to click to identify. StyleButton omits the
    -- label fontstring entirely when no text is passed, and centres the icon.
    -- ☠ A VERB, NOT A HANDLER BODY. Two surfaces open this popup now -- the
    -- island's "?" glyph and the band arm's full-width button inside the
    -- consumers panel -- and a second copy of a five-slot format() is a second
    -- place for the argument order to rot.
    local function ShowFilterHelp()
        -- TWO colour languages in this one popup, and they mean different things:
        --   hl (gold)          -- a DESTINATION, i.e. a page you can go to. Three of
        --                         them, listed. Not a link -- a popup cannot dispatch
        --                         one -- so gold is all that marks them.
        --   EMPH_BUFF/DEBUFF   -- which KIND of aura. The same two colours, on the
        --                         same two strings, as the info banner behind this
        --                         popup, so the reader meets one green/red pair on
        --                         this page rather than two unrelated ones.
        -- ⚠ Do not fold them together. Gold on "Debuff Filters" would promise a page
        -- that the popup has no way to open.
        local hl = "|cffffd200%s|r"
        DF:ShowPopupAlert({
            title   = L["How the Filter Designer works"],
            message = format(
                L["%s are lists of auras. You build them on this page; each display then picks the ones it wants, on its own page:\n\n%s\n%s\n%s — inside a filter group\n\n%s work differently: those categories are Blizzard's, they are fixed, and you pick them on the Debuff Bar page. Aura Designer debuff groups use the same categories.\n\nEditing a filter changes it everywhere it is used."],
                fdEmph(L["Buff Filters"], EMPH_BUFF),
                format(hl, L["Buff Bar"]),
                format(hl, L["Defensive Icon"]),
                format(hl, L["Aura Designer"]),
                fdEmph(L["Debuff Filters"], EMPH_DEBUFF)),
        })
    end

    local helpBtn = CreateFrame("Button", nil, chipRow, "BackdropTemplate")
    GUI:StyleButton(helpBtn, {
        width  = CHIP_HELP_W,
        height = CHIP_H,
        icon   = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\question.png", size = 13 },
    })
    -- ⚠ TOPRIGHT, not RIGHT. The row GROWS DOWNWARD when the chips wrap, and a
    -- centre anchor would slide the glyph down with it, away from the first row of
    -- chips it belongs beside.
    helpBtn:SetPoint("TOPRIGHT", 0, 0)
    helpBtn:HookScript("OnEnter", function(self)
        GUI:ShowTooltip(self, {
            title = L["How this works"],
            lines = { L["A short guide to filters and the displays that use them."] },
        })
    end)
    helpBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)
    helpBtn:SetScript("OnClick", ShowFilterHelp)

    -- ========== LEFT COLUMN: FILTER LIST ==========
    local leftPanel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    leftPanel:SetPoint("TOPLEFT", chipRow, "BOTTOMLEFT", 0, -12)
    leftPanel:SetSize(LEFT_W, PANEL_H)
    GUI:CreatePanelBackdrop(leftPanel, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })

    local leftScroll = CreateFrame("ScrollFrame", nil, leftPanel, "ScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", 4, -6) -- was -32, clearing a tab strip that no longer exists
    -- Clears the action strip at the foot of the panel: three 20px rows, 4px gutters,
    -- a 6px margin under them and the rule + gap above (6 + 20 + 4 + 20 + 4 + 20 + 6
    -- = 80, +6 of air). It briefly went to 6 while those buttons lived on the
    -- right-hand header; they came back down here because that header row could not
    -- fit them and a variable-width filter name at every window width.
    leftScroll:SetPoint("BOTTOMRIGHT", -24, 86)
    DF.GUI.StyleScrollBar(leftScroll)

    local leftContent = CreateFrame("Frame", nil, leftScroll)
    leftContent:SetSize(LEFT_W - 28, 1)
    leftScroll:SetScrollChild(leftContent)

    -- Section labels (created once, positioned during refresh; only their COLOUR is
    -- touched by RefreshLeft). DFFontNormal to match the right-column header title
    -- (titleText) — same weight both sides.
    --
    -- The filter headers used to carry a second, smaller fontstring beneath them
    -- ("Selected filters show on the buffs bar") explaining the column of checkboxes.
    -- That sentence IS the header now, so the hint is gone -- a 10px grey footnote
    -- under a header reading "Filters" put the meaning in the quietest text on the
    -- panel and the noise in the loudest.
    local function CreateSectionLabel(text)
        local fs = leftContent:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        return fs
    end
    -- Built-In / Custom: the two headers name WHERE A FILTER CAME FROM, which is the
    -- one distinction the list actually draws. The bare "Filters" they replaced was
    -- the header on BOTH tabs and repeated the tab strip four rows above it.
    --
    -- ⚠ The header no longer says what selecting a row does. That statement lives in
    -- the page banner ("Selecting them below will add them to the Buff bar") and
    -- nowhere else, so the banner is load-bearing now -- see the note on BUFF_BANNER.
    -- An intermediate version of this change put the sentence in the header instead
    -- ("Shown on the buff bar"); Krathe took it back out, because a header should name
    -- a group.
    --
    -- ⚠ Sentence case, and no letter-spacing -- the design mock showed a letter-spaced
    -- uppercase header and neither survives the port: WoW FontStrings have no
    -- letter-spacing, and upper-casing a localised header is a translator's decision.
    --
    -- Two sections, both buff: what we ship, and what you made. There is no third --
    -- the debuff header went to the Debuff Bar page with the categories it labelled.
    local presetLabel = CreateSectionLabel(L["Built-In Filters"])
    local customLabel = CreateSectionLabel(L["Custom Buff Filters"])

    -- ☠ GONE WITH THE DEBUFF HALF, all to the Debuff Bar page: the all-categories
    -- completeness caution, the which-dispels-count dropdown, and the standing-frame
    -- machinery both needed in order to live inside a scrolling list -- a deferred
    -- re-layout for when the caution finally measured its own wrapped height, and an
    -- explicit Hide because the pooled-row sweep could never reach them.
    --
    -- On a settings page they are ordinary widgets in a group, so none of that came
    -- with them. That machinery existing at all was a sign these controls were in the
    -- wrong kind of container.

    -- ☠ NO TAB STRIP. There was a Buffs/Debuffs pair here, and removing it is the
    -- point of this whole change: two unrelated systems -- an editable buff library
    -- and Blizzard's fixed debuff categories -- wearing identical controls under one
    -- strip, which taught every reader they worked the same way. The debuff half is
    -- now the Debuff Bar page's own settings rather than a second kind of filter.
    --
    -- The per-tab aura COUNT went with it. It was this page's one feedback loop while
    -- the page owned selection; the consumer chips above now do that job, and do it
    -- for all three consumers instead of one.

    -- (The rule that separated the scope switches from the filter list went with the
    -- switches. Both its texture and its placer had no callers left -- the only two
    -- were the buff scope block and the debuff branch.)

    -- Places a section label and returns the new y, so the caller cannot forget to
    -- account for the row it took.
    local function PlaceSectionLabel(fs, y)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", 6, -(y + 4))
        fs:Show()
        return y + SECTION_H
    end

    -- ⚠ The section labels are STANDING regions, not pooled rows -- the pool sweep at
    -- the end of RefreshLeft does not touch them. Hide them first; PlaceSectionLabel
    -- re-shows the ones this pass actually lays out.
    local function HideStandingRegions()
        for _, fs in ipairs({ presetLabel, customLabel }) do
            fs:Hide()
        end
    end

    -- ========== RIGHT COLUMN: HEADER PANEL + SPELL LIST ==========
    local rightArea = CreateFrame("Frame", nil, parent)
    rightArea:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 12, 0)
    rightArea:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    rightArea:SetHeight(PANEL_H)

    -- Header container: title/counts/reset (row 1), search (row 2) and
    -- add-by-ID (row 3) share one backdrop panel whose TOP aligns with the
    -- left panel's TOP, so both columns start at the same height. Each row
    -- flows in a single direction, so no header control can overlap another
    -- at any GUI width.
    local headerPanel = CreateFrame("Frame", nil, rightArea, "BackdropTemplate")
    headerPanel:SetPoint("TOPLEFT", 0, 0)
    headerPanel:SetPoint("TOPRIGHT", 0, 0)
    headerPanel:SetHeight(HEADER_H)
    GUI:CreatePanelBackdrop(headerPanel, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })

    -- Row 1: the filter's name and its counts, and nothing else. The actions on that
    -- filter (Reset/Duplicate/Rename/Delete) used to share this row, pinned right --
    -- see the strip at the foot of the LEFT panel for why they no longer do.
    -- The mode caption. Clicking a row in the left list silently switches this pane
    -- from a list you are choosing FROM to a filter you are editing, with no
    -- affordance announcing it and nothing afterwards saying you are in it -- so the
    -- two levels of this page had to be inferred from the fact that the contents
    -- changed. This is the label that says which one you are looking at.
    local eyebrowText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    eyebrowText:SetPoint("TOPLEFT", 10, -8)
    eyebrowText:SetJustifyH("LEFT")
    eyebrowText:SetTextColor(0.48, 0.48, 0.52)

    local titleText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    titleText:SetPoint("TOPLEFT", 10, -(8 + EYEBROW_H))
    titleText:SetJustifyH("LEFT")
    titleText:SetWordWrap(false)

    local countText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    countText:SetPoint("LEFT", titleText, "RIGHT", 10, 0)
    countText:SetTextColor(0.5, 0.5, 0.5)

    -- Custom filter names are free text, so the name still needs a stop -- now just
    -- the panel's own right edge rather than a button strip. Non-wrapping + a width
    -- cap gives an ellipsis instead of a name running out past the backdrop, and it
    -- is recomputed on resize because the panel is not fixed-width.
    local function ClampTitle()
        local panelW = headerPanel:GetWidth() or 0
        if panelW < 100 then return end   -- not laid out yet; OnSizeChanged re-runs us
        -- ⚠ Width 0 = auto-size. It has to go back to auto before measuring, and has
        -- to STAY auto whenever the name fits: countText anchors to this string's
        -- RIGHT edge, and a permanently-set width would park the count out at the
        -- cap no matter how short the name is.
        titleText:SetWidth(0)
        local avail = panelW - 20 - math.ceil(countText:GetStringWidth())
        if titleText:GetStringWidth() > avail then
            titleText:SetWidth(math.max(40, avail))
        end
    end
    headerPanel:SetScript("OnSizeChanged", ClampTitle)

    -- ========== STATUS LINE ==========
    -- Answers, before you touch anything, the question this page could not answer
    -- at all while the switch lived on another page: is this filter actually ON,
    -- and who else is affected by editing it.
    --
    -- It also carries the asymmetry, which is the genuinely surprising bit: the
    -- SWITCH is per-mode, the CONTENTS are account-wide. Edit Healing in Party and
    -- you edited it in Raid too; switch Healing on in Party and Raid is untouched.
    -- State dot, then the text. Same shared `dot` asset the override marker uses,
    -- so on/off here reads in the same visual language as every other state marker
    -- in the addon -- only the tint differs (green on / red off, vs the marker's
    -- amber). Carrying the state in the dot lets the text stay plain and legible
    -- instead of being colour-coded green or red across its whole length.
    local statusDot = headerPanel:CreateTexture(nil, "OVERLAY")
    statusDot:SetSize(8, 8)
    statusDot:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 1, -8)
    statusDot:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\dot")

    local statusText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    -- Anchored to the DOT, not the title: hiding the dot (the blacklist, which has
    -- no switch of its own) then leaves the text where it was rather than sliding it.
    statusText:SetPoint("LEFT", statusDot, "RIGHT", 6, 0)
    statusText:SetPoint("RIGHT", headerPanel, "RIGHT", -10, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(false)
    -- ⚠ Set the colour explicitly. DFFontNormalSmall inherits WoW's GOLD font
    -- object, so while this line carried its own |cff..| codes it looked fine --
    -- the moment the dot took over the state colour and the codes came off, the
    -- whole line fell back to gold. A FontString with no SetTextColor is not
    -- neutral, it is whatever the font object says.
    statusText:SetTextColor(GUI.Colors.text.r, GUI.Colors.text.g, GUI.Colors.text.b)

    -- A FontString cannot take mouse input, so the tooltip needs a frame over its
    -- rect (same reason GUI:AttachTooltip builds one for every control label).
    local statusHit = CreateFrame("Frame", nil, headerPanel)
    statusHit:SetPoint("TOPLEFT", statusText, "TOPLEFT", 0, 2)
    statusHit:SetPoint("BOTTOMRIGHT", statusText, "BOTTOMRIGHT", 0, -2)
    statusHit:EnableMouse(true)
    statusHit:SetScript("OnEnter", function(s)
        if s.tooltipText then
            GUI:ShowTooltip(s, { title = s.tooltipText, lines = s.tooltipLines })
        end
    end)
    statusHit:SetScript("OnLeave", function() GUI:HideTooltip() end)

    -- Does one Aura Designer config reference this filter? The walk itself is
    -- CollectADFilters, defined above the chip row because the chips call it and a
    -- local declared further down this file would resolve as a nil GLOBAL there --
    -- legal Lua, parses clean, errors only when the page refreshes.
    local function ADConfigUses(cfg, kind, key)
        if type(cfg) ~= "table" then return false end
        return CollectADFilters(cfg, {})[kind .. "\0" .. tostring(key)] and true or false
    end

    -- Who consumes the selected filter. Derived from the live db, never hardcoded:
    -- editing a filter here changes it everywhere it is used, and that is exactly
    -- what someone about to edit a shared filter needs to know.
    --
    -- ☠ BOTH MODES, ALWAYS. This used to answer for GUI.SelectedMode only, which was
    -- right when the page owned the switches and was therefore itself a party-or-raid
    -- page. It is neither now: preset overrides are per PROFILE and custom filters
    -- are per ACCOUNT, so nothing on this page belongs to a mode. Reporting one mode
    -- meant a filter switched on in BOTH read as "Buff Bar (Party)" in party and
    -- "Buff Bar (Raid)" in raid -- each answer quietly denying the other half
    -- (Krathe, 2026-08-10).
    --
    -- Returns { { label, modes = { "party", "raid" } }, ... } in a FIXED consumer
    -- order, so the line does not reshuffle as usage changes.
    --
    -- For the Aura Designer a mode means the config that mode actually resolves to
    -- (GetModeAuraDesigner reads through the merged proxy, so a live raid auto-layout
    -- overlay is included) plus any pinned set overriding it. An AD preset sitting
    -- unused in the library is not reported -- saying otherwise would make the line
    -- meaningless for anyone who keeps spares.
    local USAGE_MODES = { "party", "raid" }

    local function UsedByBuffBar(mdb, kind, key)
        local sel = mdb and mdb.buffFilterSelection
        if type(sel) ~= "table" then return false end
        local t = (kind == "preset") and sel.presets or sel.customs
        return type(t) == "table" and t[key] and true or false
    end

    local function UsedByDefensive(mdb, kind, key)
        local sel = mdb and mdb.defensiveFilterSelection
        if type(sel) ~= "table" then return false end
        local t = (kind == "preset") and sel.presets or sel.customs
        return type(t) == "table" and t[key] and true or false
    end

    local function UsedByDesigner(mdb, mode, kind, key)
        if ADConfigUses(DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(mode), kind, key) then
            return true
        end
        local lib = DF.GetAuraDesignerPresets and DF:GetAuraDesignerPresets()
        local pf = mdb and mdb.pinnedFrames
        if lib and pf and type(pf.sets) == "table" then
            for _, set in pairs(pf.sets) do
                local name = type(set) == "table" and set.auraDesignerPreset
                if name and ADConfigUses(lib[name], kind, key) then return true end
            end
        end
        return false
    end

    local function FilterConsumers(kind, key)
        local consumers = {
            { label = L["Buff Bar"],       modes = {}, test = UsedByBuffBar },
            { label = L["Defensive Icon"], modes = {}, test = UsedByDefensive },
            { label = L["Aura Designer"],  modes = {}, test = nil },
        }
        for _, mode in ipairs(USAGE_MODES) do
            local mdb = DF.db and DF.db[mode]
            if mdb then
                if UsedByBuffBar(mdb, kind, key) then
                    tinsert(consumers[1].modes, mode)
                end
                if UsedByDefensive(mdb, kind, key) then
                    tinsert(consumers[2].modes, mode)
                end
                if UsedByDesigner(mdb, mode, kind, key) then
                    tinsert(consumers[3].modes, mode)
                end
            end
        end
        local out = {}
        for _, c in ipairs(consumers) do
            if #c.modes > 0 then out[#out + 1] = c end
        end
        return out
    end

    -- One consumer, rendered. Both modes -> the bare name; one mode -> the name plus
    -- which. Saying "(Party, Raid)" on the common case would put the noisiest text on
    -- the least surprising fact, and this line has no room to spare; naming a mode
    -- ONLY when the two disagree makes the mode text mean "watch out, these differ".
    local function UsageLabel(c)
        if #c.modes >= #USAGE_MODES then return c.label end
        local m = (c.modes[1] == "raid") and L["Raid"] or L["Party"]
        return format(L["%s (%s only)"], c.label, m)
    end

    -- ========== RESET ==========
    -- Red danger tone (icon + label), matching the Reset Page button. Only shown
    -- while the selection differs from its defaults. Fourth member of the action
    -- strip at the foot of the left panel, anchored down there with the other three.
    -- Label is the short "Reset" -- the strip is two 112px columns wide and "Reset to
    -- Default" plus its icon all but fills that, so the full wording is the tooltip.
    local resetBtn = CreateFrame("Button", nil, leftPanel, "BackdropTemplate")
    GUI:StyleButton(resetBtn, {
        tone = "danger",
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh", size = 14 },
        text = L["Reset"],
    })
    -- Title + one scope line, matching every other Reset on the addon (see the
    -- Reset Page button in Options.lua). The title names WHAT is being reset —
    -- this button is per-selection, not per-page — and the line says what it
    -- leaves alone. The button only ever shows for a modified preset or for
    -- Optional Debuffs, so those are the only two cases to word.
    resetBtn:HookScript("OnEnter", function(self)
        GUI:ShowTooltip(self, {
            title = format(L["Reset: %s"], CurrentDisplayName()),
            lines = {
                L["Restore this filter's spell list to its defaults. Other filters are not affected."],
            },
        })
    end)
    resetBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)
    resetBtn:Hide()
    -- Presets, and CURATED CUSTOM LISTS -- the ones we seeded, which have a default to go
    -- back to (R:IsCuratedFilter). It used to branch for the Optional Debuffs list; that
    -- list and its reset moved to the Debuff Bar page together.
    -- ⚠ THE TWO RESETS DIFFER IN WHAT THEY UNDO, and both match what the button says.
    -- A preset's is an overrides layer, so clearing it restores every tick. A curated
    -- list's ALSO restores any seeded spell that went missing -- but never prunes what
    -- the user added to it themselves, which is theirs (R:ResetCuratedFilter).
    resetBtn:SetScript("OnClick", function()
        if not selKey then return end
        if selKind == "preset" then
            R:ResetPreset(selKey)
        elseif selKind == "custom" and R.ResetCuratedFilter then
            if not R:ResetCuratedFilter(selKey) then return end
        else
            return
        end
        DirectFilterChangedProxy()
        RefreshAll()
    end)

    -- ☠ Rows 2 and 3 are offset from the PANEL top, not chained to row 1, so ANY row
    -- added above them has to be added to BOTH of these offsets as well as to
    -- HEADER_H. Miss it and the status line renders straight over the search box.
    --
    -- This has now happened twice, to two different people, for the same reason: the
    -- status line went in and only HEADER_H was updated, and then the "Editing
    -- filter" caption went in and only HEADER_H was updated again -- with this very
    -- comment sitting here saying not to. The lesson is not "remember": it is that
    -- these offsets must be written as the SUM of every row above them, so a new row
    -- is one term added in three places that are all named after it.
    --
    -- 15 and 43 are the two base offsets from the panel top with nothing above them.
    local ROW2_Y = 15 + STATUS_ROW_H + EYEBROW_H
    local ROW3_Y = 43 + STATUS_ROW_H + EYEBROW_H
    -- CreateEditBox drops its editbox 15px to clear a label slot this page leaves
    -- empty, and a 22px button centred on that 24px body starts 1px lower again.
    -- Anything on row 3 that is NOT an edit box aligns through this.
    local BTN_ON_EB = 16

    -- Row 2: search, the full width of the panel. It used to share this row with the
    -- Add-from-Database button and shrink to fit it; the two have nothing to do with
    -- each other, and the button belongs with the other way of putting a spell into a
    -- filter, which is row 3.
    local searchBox = GUI:CreateEditBox(headerPanel, "", nil, nil, nil, 170, L["Search..."])
    searchBox:SetPoint("TOPLEFT", 10, -ROW2_Y)
    searchBox:SetPoint("TOPRIGHT", -10, -ROW2_Y)
    -- Same glyph, same grey as the main addon search bar, via the shared helper --
    -- a search field that does not look like the addon's other search field is the
    -- kind of small inconsistency this page has been collecting.
    GUI:AddEditBoxIcon(searchBox.EditBox, "Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")

    -- Row 3, right end: the Add-from-Database picker. Both ways of adding a spell to
    -- a custom filter now sit on one row -- type an ID on the left, browse the
    -- database on the right. Active for custom filters; greyed while a preset is
    -- selected (same tooltip pattern as add-by-ID).
    local dbBtn = GUI:CreateButton(headerPanel, L["Add from Database"], 130, 22, function(self)
        if self.dfDisabled then return end
        if selKind ~= "custom" or not R:GetCustomFilter(selKey) then return end
        OpenPicker(selKey)
    end)
    -- Anchored by LayoutHeaderRows below, which owns whether this shares row 3 or
    -- takes a row of its own.

    -- List background sits below the header panel
    local listBg = CreateFrame("Frame", nil, rightArea, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", headerPanel, "BOTTOMLEFT", 0, -8)
    listBg:SetPoint("BOTTOMRIGHT", 0, 0)
    GUI:CreatePanelBackdrop(listBg, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })

    local scrollFrame = CreateFrame("ScrollFrame", nil, listBg, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 4, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", -24, 4)
    DF.GUI.StyleScrollBar(scrollFrame)

    local scrollContent = CreateFrame("Frame", nil, scrollFrame)
    scrollContent:SetSize(400, 1)
    scrollFrame:SetScrollChild(scrollContent)
    -- The right column's width is anchor-driven; keep the row container synced
    scrollFrame:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then scrollContent:SetWidth(w) end
    end)

    local emptyText = listBg:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
    emptyText:SetPoint("CENTER", listBg, "CENTER", 0, 0)

    -- ========== ADD ROW (header row 3) ==========
    -- Type an ID here, or browse the database with the button at this row's right
    -- end. Active for custom filters; greyed out while a preset is selected
    -- (presets are curated — the Add button's tooltip explains).
    local addBox = GUI:CreateEditBox(headerPanel, "", nil, nil, nil, 90, L["Spell ID"])
    addBox:SetPoint("TOPLEFT", 10, -ROW3_Y)

    -- Echo line: transient add-by-ID feedback, auto-hides after ~4s
    local echoText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    echoText:SetJustifyH("LEFT")
    echoText:SetWordWrap(false)
    echoText:SetTextColor(0.6, 0.6, 0.6)
    echoText:Hide()

    -- Generation counter so a re-add while a message is visible restarts the
    -- 4s window instead of the old timer hiding the new message early.
    local echoGen = 0
    local lastEchoSel
    local function HideEcho()
        echoGen = echoGen + 1
        echoText:Hide()
    end
    local function Echo(msg)
        echoGen = echoGen + 1
        local gen = echoGen
        echoText:SetText(msg)
        echoText:Show()
        C_Timer.After(4, function()
            if echoGen == gen then echoText:Hide() end
        end)
    end

    local function DoAddSpell()
        if selKind ~= "custom" or not R:GetCustomFilter(selKey) then return end
        local text = Trim(addBox.EditBox:GetText())
        if text == "" then return end
        -- Integers only: tonumber() also accepts floats/hex, which are never
        -- valid spell ids
        if not text:match("^%d+$") then
            Echo(L["Enter a valid spell ID."])
            return
        end
        -- Length cap after zero-strip (same rule as the shared picker):
        -- past ~15 digits tonumber loses integer precision, and the float
        -- would persist as a junk key in the account-wide store.
        text = text:match("^0*(%d+)$") or text
        if #text > 10 then
            Echo(L["Enter a valid spell ID."])
            return
        end
        local idNum = tonumber(text)
        -- ☠ CAP ON VALUE, NOT DIGIT COUNT -- the length check above is not the guard it
        -- looks like. 2147483647 is itself ten digits, so everything from 2147483648 to
        -- 9999999999 got through and then threw "integer overflow attempting to store
        -- <n>" the moment the list tried to draw it, because string.format("%d", n)
        -- cannot represent it. #1111111111 was accepted silently for the same reason:
        -- ten digits, but under the ceiling. Reported by Aphoex on alpha 15.
        if not idNum or idNum < 1 or idNum > R.MAX_SPELL_ID then
            Echo(L["Enter a valid spell ID."])
            return
        end
        local result = R:AddSpellToCustom(selKey, idNum)
        if result == "spell" then
            local rec = R.ByID[idNum]
            Echo(format(L["Added %s."], (R:GetSpellDisplay(rec))))
        elseif result == "raw" then
            Echo(format(L["Added #%d as an unknown spell ID — name and icon will show if the ID is valid."], idNum))
        elseif result == "exists" then
            Echo(L["Already in this filter."])
            return
        else
            return
        end
        addBox.EditBox:SetText("")
        DirectFilterChangedProxy()
        RefreshAll()
    end

    local addBtn = GUI:CreateButton(headerPanel, L["Add"], 50, 22, function(self)
        if self.dfDisabled then return end
        DoAddSpell()
    end)
    addBtn:SetPoint("LEFT", addBox.EditBox, "RIGHT", 6, 0)
    -- HookScript (not SetScript): StyleButton owns OnEnter for the hover wash
    addBtn:HookScript("OnEnter", function(self)
        if self.dfDisabled then
            GUI:ShowTooltip(self, { title = L["Built-in filters are curated"], lines = { L["You can enable or disable the spells shown, but not add new ones. Create a custom filter to add your own."] } })
        end
    end)
    addBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)

    -- Enter in the box adds too (the helper's own OnEnterPressed only saves
    -- db-backed values — this box has no db binding)
    addBox.EditBox:HookScript("OnEnterPressed", DoAddSpell)

    -- The echo takes what is left of row 3 between the Add button and the picker.
    -- Anchored to dbBtn rather than the panel edge, which is what it used to use --
    -- with the picker on this row now, a panel-edge anchor would run the message
    -- straight under it.
    -- ☠ ROW 3 IS A ROW OF FIXED-WIDTH CHILDREN, AND ITS SUM IS WIDER THAN THE
    -- NARROWEST BAND. The Spell ID box (90), the Add button (50) and the
    -- Add-from-Database button (130) are all fixed, so even with the echo squeezed
    -- to nothing the row costs 10 + 90 + 6 + 50 + 8 + 130 + 10 = 304px. At the
    -- window's 520px minimum the band is ~280 and the picker drew straight over the
    -- Add button -- the same Class-2 failure the designer preset bar had, a row that
    -- only ever fitted because the page forced the window to 850.
    --
    -- ☠ SO THE PICKER DROPS TO A ROW OF ITS OWN, and the header grows by that row.
    -- Shrinking the three instead was the alternative and it is worse: the echo is
    -- the ONLY feedback an add-by-ID gives, and taking it to zero width fails
    -- silently -- you type an id, nothing happens, and nothing says why.
    --
    -- ⚠ RE-TAKEN ON RESIZE, not decided once. The band is whatever the window is,
    -- and the threshold is DERIVED from the parts above rather than being a second
    -- magic number: 10 + 90 + 6 + 50 + 8 + 130 + 10.
    local ROW3_ONE_LINE_W = 10 + 90 + 6 + 50 + 8 + 130 + 10
    local ROW4_H = 26
    local function LayoutHeaderRows()
        local w = headerPanel:GetWidth() or 0
        if w < 10 then return end
        local oneLine = w >= ROW3_ONE_LINE_W
        dbBtn:ClearAllPoints()
        echoText:ClearAllPoints()
        echoText:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)
        if oneLine then
            dbBtn:SetPoint("TOPRIGHT", -10, -(ROW3_Y + BTN_ON_EB))
            echoText:SetPoint("RIGHT", dbBtn, "LEFT", -8, 0)
        else
            dbBtn:SetPoint("TOPLEFT", 10, -(ROW3_Y + BTN_ON_EB + ROW4_H))
            -- With the picker gone from this row the echo takes what is left of it,
            -- which is the whole point of moving the button rather than shrinking it.
            echoText:SetPoint("RIGHT", headerPanel, "RIGHT", -10, 0)
        end
        -- ⚠ ONLY WHEN IT MOVED. This is called FROM OnSizeChanged, and a height
        -- written back unconditionally is a size change answering a size change.
        local wantH = HEADER_H + (oneLine and 0 or ROW4_H)
        if (headerPanel:GetHeight() or 0) ~= wantH then headerPanel:SetHeight(wantH) end
    end
    headerPanel:SetScript("OnSizeChanged", LayoutHeaderRows)
    LayoutHeaderRows()

    -- ========== LEFT COLUMN ACTION BUTTONS ==========
    -- Created after the search box on purpose: SelectFilter clears the active
    -- search, so these handlers must close over the searchBox local.
    --
    -- All four act on the SELECTED filter, which is what this strip uniformly means,
    -- and they sit at the foot of the list that holds that selection. They spent one
    -- build up on the right-hand header beside the filter NAME, which reads well but
    -- does not fit: that row also carries the name and its spell counts, both of
    -- which grow rightward, so at a long name or a narrower window the counts ran
    -- under the buttons. Capping the name only moved the collision to the counts --
    -- a four-button strip and a variable-width label cannot share one row at every
    -- width the GUI can be dragged to. Down here the strip has a fixed 240px panel
    -- to itself and nothing to collide with.
    --
    -- Two columns of two, 6px margins and a 4px gutter. The old objection to a
    -- bottom strip -- that "Rename" appeared directly beneath the Debuffs section
    -- header -- died with the tabs: the list is one tab's worth of filters now, not
    -- two stacked sections, and the divider above the strip marks it as chrome
    -- rather than another list row.
    local ACT_BTN_W = (LEFT_W - 12 - 4) / 2

    -- NOT `local function` -- assigns the file-scope forward declaration above, so
    -- ImportNamed (hoisted out of this function to chain the rename prompt) can reach it.
    -- Still an upvalue of this closure, so selKind/selKey/searchBox bind exactly as before.
    function SelectFilter(kind, key)
        selKind, selKey = kind, key
        -- Clear the search when switching filters (SetText fires
        -- OnTextChanged, which syncs searchText and refreshes the list)
        if searchBox.EditBox:GetText() ~= "" then
            searchBox.EditBox:SetText("")
        end
        RefreshAll()
    end

    -- The add action lives INSIDE the Custom buff filters section, not in the
    -- bottom strip. Down there it sat directly beneath the Debuffs header AND was
    -- the only never-disabled button in the strip, so it read as "add a debuff
    -- filter" — which is not a thing that exists. A row in the section it creates
    -- into cannot be misread. Parented to the scroll content and positioned by
    -- RefreshLeft along with the rest of the list.
    local addRow = CreateFrame("Button", nil, leftContent, "BackdropTemplate")
    addRow:SetHeight(LEFT_ROW_H - 2)
    -- `tinted`, not `ghost`: ghost draws NO border at all (it is meant to sit in a
    -- tab strip), which left this looking like an oddly-coloured label rather than
    -- something you can act on. Tinted gives it a faint accent fill and an accent
    -- edge at rest — a visible affordance that still reads quieter than a preset
    -- row, and it marks the row as the odd one out in a list of plain rows.
    GUI:StyleButton(addRow, {
        tinted  = true,
        text    = L["+ New Buff Filter"],
        align   = "left",
        leftPad = 10,
        font    = "DFFontHighlightSmall",
    })
    addRow:SetScript("OnClick", function()
        PromptFilterName(L["Name the new filter:"], "", L["Create"], function(text)
            text = Trim(text)
            if text == "" then return end
            SelectFilter("custom", R:CreateCustomFilter(text))
        end)
    end)
    -- Cross-page affordance: the Aura Designer's "Create Filter" button navigates
    -- here and pulses this row. Exposed as a FUNCTION rather than the raw widget
    -- (which is what it used to be, back when the button was pinned to the bottom
    -- strip and therefore always on screen): the row now lives in a scroll frame,
    -- so scrolling it into view is part of the cue. A pulse below the fold is no
    -- cue at all, and it would fail silently.
    local addRowY = 0   -- set by RefreshLeft, which owns the list's geometry
    -- ☠ IN THE BAND LAYOUT THERE IS NO SINGLE FILTER LIST TO OPEN -- the PAGE is
    -- the list, one row per filter -- so this means "put the filter band where the
    -- eye is". The row-level cue is the other half, and it belongs to the two entry
    -- points below because only they know WHICH filter is wanted.
    --
    -- ⚠ READS pageRef AT CALL TIME. The band is built at the foot of this function,
    -- long after this closure is created; an upvalue captured here would freeze nil.
    -- A no-op in the island, which has no band.
    local function OpenFilterList()
        local scrollTo = pageRef._fdScrollToFilters
        if scrollTo then scrollTo() end
    end
    pageRef._fdFocusNewFilter = function()
        OpenFilterList()
        -- ☠ THE BAND ARM CREATES THE FILTER, IT DOES NOT POINT AT THE BUTTON. With
        -- a row per filter there is a panel to land in, so "Create Filter" can finish
        -- the job it was asked for: name it, make it, open it. The island has no such
        -- landing -- its add row is one line in a scrolling list -- so it keeps the
        -- scroll-and-pulse below.
        local newFilter = pageRef._fdNewFilter
        if newFilter then
            newFilter()
            return
        end
        local range = leftScroll:GetVerticalScrollRange() or 0
        leftScroll:SetVerticalScroll(math.max(0, math.min(addRowY - 8, range)))
        if DF.HighlightWidget then DF:HighlightWidget(addRow) end
    end

    -- Import sits next to New rather than in the action strip below, for the same
    -- reason New does: it CREATES a filter, where every button in that strip acts
    -- on the current selection. Down there it would read as "import into the
    -- selected filter", which is not what it does.
    local importRow = CreateFrame("Button", nil, leftContent, "BackdropTemplate")
    importRow:SetHeight(LEFT_ROW_H - 2)
    GUI:StyleButton(importRow, {
        tinted  = true,
        text    = L["+ Import Filter"],
        align   = "left",
        leftPad = 10,
        font    = "DFFontHighlightSmall",
    })
    importRow:SetScript("OnClick", function()
        DF:ShowPopupInput({
            title       = L["Import Filter"],
            message     = L["Paste a filter string to import:"],
            multiline   = true,
            acceptLabel = L["Import"],
            onAccept    = function(text)
                if not text or Trim(text) == "" then return end
                local def, err = R:DecodeFilterString(text)
                if not def then
                    ShowFilterStringError(L["Import Filter"], err)
                    return
                end
                -- A newly imported filter is not in any selection yet
                -- (IsCustomOn defaults false), so nothing on screen changes
                -- until the user ticks it — no DirectFilterChangedProxy here,
                -- matching the New and Duplicate paths.
                local match = R:FindContentMatch(def)
                if not match then
                    -- No content match, but the NAME can still collide -- that is the
                    -- case nothing checked: two rows reading the same thing with
                    -- different spells behind them. ImportNamed asks only if it does.
                    ImportNamed(def)
                    return
                end
                -- Content-equal filter already present. Profile import silently
                -- reuses it, which is right there; here it would mean pasting a
                -- string and watching nothing happen. Ask instead.
                local existing = R:GetCustomFilter(match)
                local message = format(
                    L["You already have a filter with these spells: \"%s\". Import a separate copy anyway?"],
                    (existing and existing.name) or match)
                ChainPopup(function()
                    DF:ShowPopupAlert({
                        title   = L["Import Filter"],
                        message = message,
                        buttons = {
                            { label = L["Import as Copy"], onClick = function()
                                ImportNamed(def)
                            end },
                            { label = L["Use Existing"], onClick = function()
                                SelectFilter("custom", match)
                            end },
                            { label = L["Cancel"] },
                        },
                    })
                end)
            end,
        })
    end)

    local dupBtn = GUI:CreateButton(leftPanel, L["Duplicate"], ACT_BTN_W, 20, function(self)
        if self.dfDisabled or not selKey then return end
        local src = selKey -- capture: selection may move before the prompt closes
        PromptFilterName(L["Name the duplicated filter:"], CurrentDisplayName() .. " copy", L["Duplicate"], function(text)
            text = Trim(text)
            if text == "" then return end
            SelectFilter("custom", R:DuplicateFilter(src, text))
        end)
    end)

    local renameBtn = GUI:CreateButton(leftPanel, L["Rename"], ACT_BTN_W, 20, function(self)
        if self.dfDisabled then return end
        local id = selKey
        local f = R:GetCustomFilter(id)
        if not f then return end
        PromptFilterName(L["Rename filter:"], f.name or "", L["Rename"], function(text)
            text = Trim(text)
            if text == "" then return end
            R:RenameCustomFilter(id, text)
            RefreshAll()
        end)
    end)

    local delBtn = GUI:CreateButton(leftPanel, L["Delete"], ACT_BTN_W, 20, function(self)
        if self.dfDisabled then return end
        local id = selKey
        local f = R:GetCustomFilter(id)
        if not f then return end
        ConfirmDeleteFilter(f.name or tostring(id), function()
            R:DeleteCustomFilter(id)
            ScrubDeletedFilter(id)
            if selKind == "custom" and selKey == id then
                -- Move selection off the deleted filter (RefreshRight's guard
                -- would also catch this, but be explicit)
                selKind = "preset"
                selKey = R.Categories[1] and R.Categories[1].key
            end
            DirectFilterChangedProxy()
            RefreshAll()
        end)
    end)
    -- Export flattens a preset to its currently-enabled spells (ResolveFilterContent),
    -- so it works on presets as well as customs — unlike Rename/Delete, which need a
    -- store entry. The blacklist is the exception: it is a per-mode db set, not a
    -- registry filter, so there is nothing to resolve.
    local exportBtn = GUI:CreateButton(leftPanel, L["Export"], ACT_BTN_W, 20, function(self)
        -- (No selKind == "blacklist" test: SELECTABLE_KIND is { preset, custom } and
        -- every SelectFilter call site passes one of those two, so selKind can never
        -- hold "blacklist" -- the tab it guarded against is gone.)
        if self.dfDisabled or not selKey then return end
        local str, err = R:ExportFilter(selKey, CurrentDisplayName())
        if not str then
            ShowFilterStringError(L["Export Failed"], err)
            return
        end
        -- readOnly: the string is there to be selected and copied, not edited. It
        -- opens fully selected, so Ctrl+C alone is enough.
        DF:ShowPopupInput({
            title       = L["Export Filter"],
            -- Presets land on the other end as a custom filter carrying a snapshot
            -- of what was enabled at export time. Say so rather than let it surprise.
            message     = (selKind == "preset")
                and L["Copy this string to share this filter. It will import as a custom filter."]
                or L["Copy this string to share this filter:"],
            text        = str,
            multiline   = true,
            readOnly    = true,
            cancelLabel = L["Done"],
        })
    end)

    -- Anchored only now that all five exist. Each takes its own corner of the panel
    -- rather than chaining off a neighbour, so Reset hiding (it only shows for a
    -- modified preset or the blacklist) leaves the others exactly where they were:
    --
    --     [ Duplicate ] [ Rename ]
    --     [ Export    ] [ Delete ]
    --     [ Reset     ]
    --
    -- The two that destroy something share the right-hand column, away from the ones
    -- that don't. Reset keeps the bottom-left corner it already had, so its show/hide
    -- still moves nothing.
    resetBtn:SetSize(ACT_BTN_W, 20)
    dupBtn:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMLEFT", 6, 54)
    renameBtn:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", -6, 54)
    exportBtn:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMLEFT", 6, 30)
    delBtn:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", -6, 30)
    resetBtn:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMLEFT", 6, 6)

    -- ☠ AND THEIR WIDTH IS THE PANEL'S, NOT A NUMBER DERIVED FROM LEFT_W. Two
    -- 127px buttons plus the 6px margins and the 4px gutter need 266px, which is
    -- exactly what the island's 270px panel has and 6px MORE than the 260 a popout
    -- pane gives. Anchored from opposite corners at a fixed width they do not
    -- shrink -- they overlap in the middle -- which is the same Class-2 failure the
    -- designer preset bar had, a row of fixed-width children sized against the one
    -- width the page used to be guaranteed.
    --
    -- ⚠ Re-taken on resize rather than computed once, for the reason every other
    -- repair in this pass is: the panel is whatever its host is.
    local function LayoutActionStrip()
        local w = leftPanel:GetWidth() or 0
        if w < 40 then return end
        local bw = mfloor((w - 12 - 4) / 2)
        dupBtn:SetWidth(bw)
        renameBtn:SetWidth(bw)
        exportBtn:SetWidth(bw)
        delBtn:SetWidth(bw)
        resetBtn:SetWidth(bw)
    end
    leftPanel:SetScript("OnSizeChanged", LayoutActionStrip)
    LayoutActionStrip()

    -- ☠ ...AND THE LIST'S ROWS FOLLOW THE VIEWPORT, WHICH THEY NEVER DID. Every
    -- filter row spans leftContent corner to corner, and leftContent was fixed at
    -- LEFT_W - 28 -- a number that only matched the scroll frame while the panel was
    -- exactly 270 wide. Narrower, the rows overhang the viewport and each row's
    -- spell COUNT, which sits at its right edge, is clipped away. The right-hand
    -- spell list has had this sync since it was built; the left one was simply
    -- never asked to be any width but one.
    leftScroll:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then leftContent:SetWidth(w) end
    end)

    -- Rule above the strip: without it the buttons read as more rows of the list
    -- they sit under, rather than as a toolbar acting on that list's selection.
    local actRule = leftPanel:CreateTexture(nil, "ARTWORK")
    actRule:SetHeight(1)
    actRule:SetColorTexture(0.22, 0.22, 0.22, 1)
    actRule:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMLEFT", 6, 80)
    actRule:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", -6, 80)

    -- ========== DATABASE FRESHNESS NOTE ==========
    -- Declared out here so the page-height arithmetic can reach it; assigned below,
    -- and left nil when the registry carries no build stamp.
    local dbFreshLabel
    -- Static by design: the stamp and the client build can't change
    -- mid-session, so the text is computed once at page build (no refresh
    -- wiring). Parented to leftPanel so it survives DoBuild's rebuild pass
    -- like the rest of the panel; it hangs just below the panel's frame.
    do
        local stamp = R.DBStamp
        if stamp then
            local freshText = format(L["Spell database: %s (build %d)"], stamp.harvest, stamp.gameBuild)
            local clientBuild = tonumber((select(2, GetBuildInfo())))
            if clientBuild and clientBuild > stamp.gameBuild then
                freshText = freshText .. "  |c" .. GUI:ToneHex("caution")
                    .. L["Spell database may be outdated."] .. "|r"
            end
            local freshLabel = GUI:CreateLabel(leftPanel, freshText, LEFT_W)
            freshLabel:SetPoint("TOPLEFT", leftPanel, "BOTTOMLEFT", 0, -2)
            -- ⚠ Published so ResolvePanelHeight can MEASURE it. This label hangs
            -- below the panel, outside everything the page's own height arithmetic
            -- knew about -- which is how the See Also footer ended up drawn over it.
            dbFreshLabel = freshLabel
        end
    end

    -- Grey-when-disabled: SetDisabled keeps the button natively enabled so
    -- this tooltip can explain WHY (the OnClick handlers early-out instead)
    local function HookDisabledTooltip(btn, title, desc)
        btn:HookScript("OnEnter", function(self)
            if self.dfDisabled then
                GUI:ShowTooltip(self, { title = title, lines = desc and { desc } or nil })
            end
        end)
        btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
    end
    HookDisabledTooltip(renameBtn, L["Built-in filters are curated"], L["Built-in filters can't be renamed or deleted."])
    HookDisabledTooltip(delBtn, L["Built-in filters are curated"], L["Built-in filters can't be renamed or deleted."])
    HookDisabledTooltip(dbBtn, L["Built-in filters are curated"], L["You can enable or disable the spells shown, but not add new ones. Create a custom filter to add your own."])

    -- ========== ADD-FROM-DATABASE PICKER ==========
    -- The shared spell database picker (FilterRegistry/SpellPicker.lua):
    -- in-page overlay covering both columns (the spell DB is far too large
    -- for a StaticPopup), search box + class/category filters + pooled list
    -- of every DB spell, class-grouped like the main spell list. Clicking a
    -- row adds the spell to the target custom filter; rows already in the
    -- filter render dimmed with a check instead of being clickable. Esc or
    -- the close button dismisses; search + filters reset on every open.
    local pickerTarget -- custom filter id the picker adds into
    local pickerHandle -- shared-picker handle (nil until the first open)

    OpenPicker = function(cfId)
        pickerTarget = cfId
        pickerHandle = R:OpenSpellPicker({
            parent = parent,
            points = {
                { "TOPLEFT", leftPanel, "TOPLEFT", 0, 0 },
                { "BOTTOMRIGHT", rightArea, "BOTTOMRIGHT", 0, 0 },
            },
            title = L["Add from Database"],
            -- Re-evaluated per refresh, so a rename while the picker is up
            -- keeps the header current
            subtitle = function()
                local f = R:GetCustomFilter(pickerTarget)
                return f and (f.name or tostring(pickerTarget)) or ""
            end,
            -- Target filter deleted while open -> the picker closes itself
            isValid = function()
                return R:GetCustomFilter(pickerTarget) ~= nil
            end,
            -- "Already in this filter" renders as the dimmed check row
            isBlocked = function(rec)
                local f = R:GetCustomFilter(pickerTarget)
                return (f and f.spells[rec.id] ~= nil) and true or nil
            end,
            rowActions = {
                {
                    handler = function(rec)
                        if R:AddSpellToCustom(pickerTarget, rec.id) then
                            DirectFilterChangedProxy()
                            RefreshAll() -- re-renders the picker too, so the row shows its check
                        end
                    end,
                },
            },
        })
    end

    UpdateActionStates = function()
        local isCustom = selKind == "custom" and R:GetCustomFilter(selKey) ~= nil
        dupBtn:SetDisabled(selKey == nil)
        renameBtn:SetDisabled(not isCustom)
        delBtn:SetDisabled(not isCustom)
        -- Same gate as Duplicate: both resolve a ref to content.
        exportBtn:SetDisabled(selKey == nil)
        addBox:SetEnabled(isCustom)
        addBtn:SetDisabled(not isCustom)
        dbBtn:SetDisabled(not isCustom)
        -- ⚠ These four used to be HIDDEN outright for the Optional Debuffs list,
        -- because that list was fixed and they could not act on it. Every remaining
        -- selection is an editable filter, so they are simply always shown --
        -- disabled-with-tooltip for a preset, live for a custom.
        searchBox:Show()
        dbBtn:Show()
        addBox:Show()
        addBtn:Show()
        -- Reset (header row 1, red danger tone): shown when a preset differs from its
        -- shipped defaults.
        -- ⚠ SHOWN ONLY WHEN THERE IS SOMETHING TO UNDO, for both kinds. A curated list
        -- counts as modified once anything is ticked off -- `disabled` is exactly the
        -- overrides table's role, so the two tests are the same question.
        local curatedModified = false
        if selKind == "custom" and selKey and R.IsCuratedFilter and R:IsCuratedFilter(selKey) then
            local cf = R:GetCustomFilter(selKey)
            curatedModified = (cf and cf.disabled and next(cf.disabled)) and true or false
        end
        resetBtn:SetShown((selKind == "preset" and selKey ~= nil and R:IsPresetModified(selKey))
            or curatedModified or false)
    end

    -- ========== LEFT ROW POOL ==========
    local leftRows = {}
    local function AcquireLeftRow(i)
        local row = leftRows[i]
        if row then
            row:Show()
            return row
        end
        row = CreateFrame("Button", nil, leftContent, "BackdropTemplate")
        row:SetHeight(LEFT_ROW_H - 2)
        DF.GUI:CreateElementBackdrop(row, {
            outline = false,
        })

        -- Selection accent bar (theme-colored). Its geometry is shared with the
        -- toggle below, which has to clear it.
        row.accent = row:CreateTexture(nil, "ARTWORK")
        row.accent:SetSize(ACCENT_W, LEFT_ROW_H - 7)
        row.accent:SetPoint("LEFT", ACCENT_X, 0)

        row.count = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        row.count:SetPoint("RIGHT", -8, 0)
        row.count:SetJustifyH("RIGHT")
        row.count:SetTextColor(0.5, 0.5, 0.5)

        -- "Modified" override marker (preset has per-profile enable/disable
        -- overrides). Shared filled-dot marker used for overrides addon-wide;
        -- it propagates clicks so it doesn't swallow the row's select handler.
        row.dot = GUI:CreateOverrideMarker(row, 8)
        row.dot:SetPoint("RIGHT", row.count, "LEFT", -3, 0)
        row.dot.tooltipText = L["Override active"]
        row.dot.tooltipSubText = L["This built-in filter has been changed from its defaults."]

        -- The filter's own on/off switch. This is the control that used to live a
        -- page away on Aura Filters, which is what let you carefully edit the spells
        -- inside a filter that was never switched on. Its click does NOT reach the
        -- row (see GUI:CreateRowToggle): switch it on to feed the bar, click
        -- anywhere else on the row to select it and edit its contents.
        --
        -- ⚠ Offset derived from the selection accent, not picked by eye. That bar is
        -- 3px wide at x=2, so its right edge is x=5, and the box has to clear it by
        -- enough to read as a separate object -- they are both small, hard-edged and
        -- theme-coloured when active, so at a 1px gap the checked box and the
        -- selection bar merge into one blob. The box also used to be inset inside a
        -- larger hit frame, which hid this; it is now the shared checkbox, whose
        -- frame IS its box.
        row.toggle = GUI:CreateRowToggle(row, {
            onClick = function(checked)
                if row._onToggle then row._onToggle(checked) end
            end,
        })
        row.toggle:SetPoint("LEFT", ACCENT_X + ACCENT_W + 6, 0)

        row.name = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        row.name:SetPoint("LEFT", row.toggle, "RIGHT", 4, 0)
        row.name:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")

        row:SetScript("OnClick", function(self)
            -- Only rows that HAVE a spell list become the selection. Scope
            -- switches (All Buffs / All Debuffs / Only My Buffs), Blizzard's debuff
            -- categories and the uncategorised bucket own no editable membership --
            -- their tick IS the whole control, and selecting one would blank the
            -- right-hand pane for no reason. They carry a hover tooltip instead,
            -- which is where "you can't edit these, Blizzard defines them" is said.
            if not SELECTABLE_KIND[self._kind] then return end
            selKind, selKey = self._kind, self._key
            -- Clear the search when switching filters (SetText fires
            -- OnTextChanged, which syncs searchText and refreshes the list)
            if searchBox.EditBox:GetText() ~= "" then
                searchBox.EditBox:SetText("")
            end
            RefreshAll()
        end)
        row:SetScript("OnEnter", function(self)
            if not self._selected then
                self:SetBackdropColor(ROW_HOVER_R, ROW_HOVER_G, ROW_HOVER_B, ROW_HOVER_A)
            end
        end)
        row:SetScript("OnLeave", function(self)
            if not self._selected then
                self:SetBackdropColor(ROW_REST_R, ROW_REST_G, ROW_REST_B, ROW_REST_A)
            end
        end)

        leftRows[i] = row
        return row
    end

    -- `toggle` is optional: { checked = bool, greyed = bool, onToggle = fn(checked) }.
    -- Omitted means this row has no on/off of its own (the Blacklist, which is always
    -- in force) -- the box is hidden and the name takes its place, so the row does not
    -- read as an unselected filter.
    --
    -- `greyed` is the All Buffs / All Debuffs case: the specific filters below a scope
    -- switch stay VISIBLE and dim rather than disappearing. The old page hid them,
    -- which is the same convention breach we fixed on six other pages -- you could not
    -- see what you would be turning back on.
    local function BindLeftRow(row, y, kind, key, nameStr, countStr, modified, selected)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        -- _y is the row's own offset down the scroll content, kept because
        -- _fdFocusFilter has to scroll a row into view and the anchor above is the
        -- only place that number exists.
        row._kind, row._key, row._selected, row._y = kind, key, selected, y
        row.name:SetText(nameStr)
        row.count:SetText(countStr)
        row.dot:SetShown(modified)

        -- ☠ NO TOGGLE ARM. The `toggle` parameter was never passed -- both call sites
        -- stop at `selected` -- so row._onToggle was always nil, the
        -- Show/SetChecked/greyed branch could not run, CreateRowToggle's onClick could
        -- never fire, and `dim` was always nil, which made both dimmed-text paths
        -- dead too. The page's own note already said this outright: every row is
        -- passed a nil toggle, because this list no longer selects anything for a bar.
        --
        -- ⚠ row.toggle itself is KEPT deliberately. It is hidden here on every bind
        -- and never shown, but row.name's CREATION-time anchor is expressed against
        -- it in the pool setup, so deleting the widget means rewriting that anchor
        -- chain -- a layout change, not a dead-code removal.
        row.name:ClearAllPoints()
        row.name:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
        row.toggle:Hide()
        row.name:SetPoint("LEFT", 10, 0)

        local tc = GUI.GetThemeColor()
        row.accent:SetColorTexture(tc.r, tc.g, tc.b, 1)
        row.accent:SetShown(selected)
        if selected then
            row:SetBackdropColor(tc.r * 0.30, tc.g * 0.30, tc.b * 0.30, 0.9)
            row.name:SetTextColor(0.95, 0.95, 0.95)
        else
            row:SetBackdropColor(ROW_REST_R, ROW_REST_G, ROW_REST_B, ROW_REST_A)
            row.name:SetTextColor(0.70, 0.70, 0.70)
        end
        row.count:SetTextColor(0.5, 0.5, 0.5)
    end

    -- Open ONE named filter: select it, scroll its row into view, pulse it. The
    -- Aura Designer calls this from every place it names a filter -- a linked-filter
    -- chip, a filter trigger tag -- so those links land on the filter rather than on
    -- the page, which is the whole difference between this and a bare SelectTab.
    --
    -- Sibling of _fdFocusNewFilter above; same three beats, same reason the scroll is
    -- part of it (a pulse below the fold is no cue at all). The two differ only in
    -- that this one has to find its row first.
    --
    -- ⚠ DECLARED HERE, not beside _fdFocusNewFilter, because `leftRows` is declared
    -- ~270 lines below that point -- a closure created up there would read it as a
    -- nil GLOBAL, parse clean, and fail at runtime. That trap has already cost this
    -- file two bugs this cycle (CollectADFilters, leftTab).
    --
    -- ⚠ SelectFilter FIRST: it runs RefreshAll, which re-binds the pooled rows. Read
    -- the pool before that and you get the row a different filter used to occupy.
    pageRef._fdFocusFilter = function(kind, key)
        if not (kind and key) then return end
        OpenFilterList()
        SelectFilter(kind, key)
        -- ☠ THE BAND ARM HAS NO LIST ROW TO PULSE -- it has a POPOUT ROW per filter,
        -- and the cue is opening that filter's own panel. Asked AFTER SelectFilter for
        -- exactly the reason the island reads its pool after it: RefreshAll re-binds
        -- row i, so a row read before that belongs to a different filter.
        local openPanel = pageRef._fdOpenFilterPanel
        if openPanel and openPanel(kind, key) then return end
        for _, row in ipairs(leftRows) do
            if row:IsShown() and row._kind == kind and row._key == key then
                local range = leftScroll:GetVerticalScrollRange() or 0
                leftScroll:SetVerticalScroll(math.max(0, math.min((row._y or 0) - 8, range)))
                if DF.HighlightWidget then DF:HighlightWidget(row) end
                return
            end
        end
        -- A filter that is selected but has no row is a deleted one whose reference
        -- outlived it. Selecting it still opens the right-hand pane's empty state,
        -- which is a truthful landing; say so rather than pulsing nothing.
        DF:DebugWarn("GUI", "Filter Designer: no row for %s filter '%s'", tostring(kind), tostring(key))
    end

    -- ========== SPELL LIST POOLS ==========
    -- Class header rows (plain fontstrings)
    local classHeaders = {}
    local function AcquireClassHeader(i)
        local fs = classHeaders[i]
        if fs then
            fs:Show()
            return fs
        end
        fs = scrollContent:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        fs:SetJustifyH("LEFT")
        classHeaders[i] = fs
        return fs
    end

    -- Spell rows
    local spellRows = {}
    -- ☠ MOUSE PROPAGATION IS COMBAT-PROTECTED on 12.1 — SetPropagateMouseMotion
    -- fires ADDON_ACTION_BLOCKED in lockdown (field report #1029: opening the
    -- designer mid-combat spammed it per row). It's an event, not an error, so
    -- pcall can't hush it — the only correct move is to not make the call, and
    -- to HEAL later: rows are created once and pooled, so a row born in combat
    -- would otherwise keep broken hover/click propagation for the session. This
    -- runs at creation AND on every reuse; the first out-of-combat page open
    -- applies whatever combat skipped.
    local function ApplyRowPropagation(row)
        if row._propagationApplied or InCombatLockdown() then return end
        local hot, chipHot = row.hot, row.chipHot
        if hot then
            if hot.SetPropagateMouseMotion then hot:SetPropagateMouseMotion(true) end
            if hot.SetPropagateMouseClicks then hot:SetPropagateMouseClicks(true) end
        end
        if chipHot and chipHot.SetPropagateMouseMotion then
            chipHot:SetPropagateMouseMotion(true)
        end
        row._propagationApplied = true
    end
    local function AcquireSpellRow(i)
        local row = spellRows[i]
        if row then
            ApplyRowPropagation(row)
            row:Show()
            return row
        end
        row = CreateFrame("Button", nil, scrollContent, "BackdropTemplate")
        row:SetHeight(SPELL_ROW_H - 2)
        DF.GUI:CreateElementBackdrop(row, {
            outline = false,
            bgColor     = { ROW_REST_R, ROW_REST_G, ROW_REST_B, ROW_REST_A },
        })

        -- Spell icon
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", 6, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        -- Membership checkbox, in the row's RIGHT-hand control slot -- the same slot
        -- the custom view's remove "x" occupies, so every list shape puts its control
        -- in one rail and the left edge is always icon-then-name.
        --
        -- ☑ MEANS ONE THING ON EVERY LIST ON THIS PAGE: this spell appears on your
        -- frames. Buff filter -- checked = in the filter, so it shows. Blacklist --
        -- checked = not blacklisted, so it shows; UNTICK to hide. That is the reading
        -- the data already had (`enabled` is "shows" in both item builders) and the
        -- one the dimming already followed, so an unchecked row is a dim row
        -- everywhere. The alternative -- checked = "blacklisted" -- would have put a
        -- checked box on every dimmed row, which just looks broken.
        --
        -- Four rounds to get here, and the position mattered as much as the control:
        --
        --   * NOT Enable/Disable, NOT Included/Excluded, NOT Tracked/Untracked. Each
        --     was accurate and each was a WORD on sixty rows; the last needed an 80px
        --     button, which stacks into a wall down a long filter.
        --   * NOT Show/Hide as a button either -- same problem, and it is now the
        --     BOX that carries show-vs-hide on the blacklist.
        --   * NOT On/Off -- that is the FILTER switch's vocabulary, in the left list
        --     and the status line.
        --   * NOT a box on the LEFT. Built and reverted: beside the spell icons it
        --     piled every heavy element onto one side of the row.
        --
        -- "tracked" survives once, as a noun, in the header count.
        --
        -- EnableMouse(false): this is a state indicator, not a control. The ROW owns
        -- the click (same pattern as CreateDebugCategoryRow), so there is one hit
        -- area and no dead pixel beside the box.
        row.check = GUI:CreateRowToggle(row)
        row.check:EnableMouse(false)
        row.check:SetPoint("RIGHT", -6, 0)

        -- Custom view: inline destructive remove
        row.remove = GUI:CreateCloseButton(row, {
            size = 18,
            tone = "danger",
            onClick = function()
                if row._onRemove then row._onRemove() end
            end,
        })
        row.remove:SetPoint("RIGHT", -6, 0)

        -- Right-aligned chip: "+N" extra spellIDs, or the unknown-ID caption.
        -- Anchored per bind to whatever control that row ends up showing.
        --
        -- There used to be an 'i' button here too, on all sixty rows, whose entire
        -- job was one line: the spell's canonical + variant IDs -- an expansion of
        -- the "+2" chip sitting immediately beside it. The row already raises a spell
        -- tooltip when you hover its icon or name, so the IDs are appended to THAT
        -- (ShowGameTooltip takes `lines` and re-appends them after a late spell load,
        -- so they survive the repaint). One hover, one tooltip, sixty fewer buttons.
        row.chip = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        row.chip:SetJustifyH("RIGHT")
        row.chip:SetTextColor(0.5, 0.5, 0.5)

        -- Spell name
        row.name = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row.chip, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")

        -- Tooltip hotspot: the icon and name only. The whole row used to raise the
        -- spell tooltip, so it fired while you were reaching for Enable/Disable or
        -- the info button, and it anchored off the row's full width. Three anchor
        -- points give it the row's full height but stop at the name's right edge.
        --   motion propagates -> the ROW still gets OnEnter/OnLeave for its shading
        --   clicks propagate  -> the row's toggle still fires over the name
        -- SetPropagateMouseClicks is protected on 12.1, hence the combat guard —
        -- same pattern as CreateOverrideMarker and the resurrection icon.
        -- ⚠ Width is set per BIND, from the name's STRING width — not from row.name
        -- itself. That fontstring is anchored left AND right, so it spans the whole
        -- row whatever the spell is called; anchoring to its right edge made the
        -- hotspot the full bar again, which is the thing this exists to avoid.
        local hot = CreateFrame("Frame", nil, row)
        hot:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        hot:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        hot:EnableMouse(true)
        -- Propagation applied by ApplyRowPropagation below (combat-deferred).
        -- The ID line rides along with the game tooltip now that the 'i' button is
        -- gone. Raw rows (an id typed into a custom filter that the database does not
        -- know) have no game tooltip to hang it on, and used to have NO hover at all
        -- -- the 'i' was the only way to see what you had added -- so they get our
        -- own tooltip instead. That is the one place this change adds a hover rather
        -- than removing a button.
        hot:SetScript("OnEnter", function()
            local lines
            local ids = row._infoIDs and format(L["Spell IDs: %s"], row._infoIDs)
            if ids then lines = { ids } end
            -- _infoNote carries a per-row explanation the list can't show inline —
            -- currently the "you can't untick the last ID" rule, so the refusal has
            -- somewhere to be read BEFORE it is hit.
            if row._infoNote then
                lines = lines or {}
                lines[#lines + 1] = row._infoNote
            end
            if row._spellID and not row._raw then
                ShowSpellTooltip(row, row._spellID, row._infoTitle, SpellRowStillShows, lines)
            elseif row._infoTitle then
                GUI:ShowTooltip(row, { title = row._infoTitle, lines = lines })
            end
        end)
        hot:SetScript("OnLeave", function() GUI:HideTooltip() end)
        row.hot = hot

        -- The "+N" chip is a CONTROL on multi-ID records: it opens the record into one
        -- row per spell ID so a single ID can be untracked. It sat here as inert text
        -- announcing "this row is 2 spell IDs" and offering nothing to do about it.
        --
        -- ⚠ MOTION propagates, CLICKS do not — the opposite split to row.hot above, and
        -- both halves matter. Without motion propagation this frame swallows the row's
        -- OnEnter/OnLeave and the hover wash drops out from under the cursor whenever it
        -- crosses the chip. Without click ISOLATION the row's own click fires too, so
        -- opening the record would also toggle the whole spell out of the preset.
        -- (No SetPropagateMouseClicks call at all — not propagating is the default,
        -- which also sidesteps the 12.1 protection row.hot needs its combat guard for.)
        -- Width is set per BIND from the chip's rendered string, same reason row.hot's
        -- is: the chip's text changes with state ("+1" / "1 of 2 IDs").
        local chipHot = CreateFrame("Button", nil, row)
        chipHot:SetPoint("TOP", row, "TOP", 0, 0)
        chipHot:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
        chipHot:EnableMouse(true)
        -- Propagation applied by ApplyRowPropagation below (combat-deferred).
        chipHot:SetScript("OnClick", function()
            if row._onChip then row._onChip() end
        end)
        chipHot:SetScript("OnEnter", function(self)
            if not row._chipTip then return end
            GUI:ShowTooltip(self, { title = row._infoTitle, lines = { row._chipTip } })
        end)
        chipHot:SetScript("OnLeave", function() GUI:HideTooltip() end)
        row.chipHot = chipHot
        ApplyRowPropagation(row)   -- no-op in combat; healed on the next OOC acquire

        -- Row click mirrors the action button in the preset view
        row:SetScript("OnClick", function(self)
            if self._rowToggles and self._onAction then self._onAction() end
        end)
        row:SetScript("OnEnter", function(self)
            self:SetBackdropColor(ROW_HOVER_R, ROW_HOVER_G, ROW_HOVER_B, ROW_HOVER_A)
            ShadeRowControls(self, true)
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropColor(ROW_REST_R, ROW_REST_G, ROW_REST_B, ROW_REST_A)
            ShadeRowControls(self, false)
            GUI:HideTooltip()
        end)

        spellRows[i] = row
        return row
    end

    local function BindSpellRow(row, y, item, isPreset)
        -- Two row shapes, both with their control in the same right-hand slot:
        --   preset / blacklist   icon name chip [x]   checked = this shows
        --   custom               icon name chip [✕]   everything listed is in it
        --                                             already, so the only action is
        --                                             to take it out
        -- The blacklist's toggle writes a different store (its own per-mode set, not
        -- R:SetSpellEnabled) but means the same thing to the reader, which is why it
        -- can share the control.
        -- Child rows are one spell ID of a multi-ID record, opened from the parent's
        -- chip. They always carry a checkbox whichever list they are in: it means "this
        -- ID is tracked", which is a statement about the SPELL and reads the same under
        -- a preset and a custom filter. Indented from the left so the nesting is
        -- structural rather than a colour cue.
        local isChild = item.child and true or false
        -- ★ ...AND A CURATED CUSTOM LIST TICKS TOO. A filter WE seeded has a default to
        -- go back to (R:IsCuratedFilter), so unticking a spell is reversible and the
        -- destructive ✕ is the wrong verb for it. A list the USER built keeps the ✕ --
        -- there, membership IS the truth and removing what they added is exactly right.
        local isCurated = (not isPreset) and selKind == "custom" and selKey
            and R.IsCuratedFilter and R:IsCuratedFilter(selKey) or false
        -- ☠☠ ...ONLY FOR THE ROWS WE ACTUALLY SEEDED. `IsCuratedFilter` is a property of the
        -- FILTER, not of the row, so testing it alone gave the tick to every row in the list --
        -- including a spell the USER typed into the Add field afterwards. That row has no
        -- default to go back to: ResetCuratedFilter restores our seed and, by its own
        -- statement, deliberately does NOT prune their additions. So the tick is reversible in
        -- name only and the ✕ it replaced was the sole way to take the spell out again --
        -- add one by mistake and it is in that list forever, on every frame it feeds.
        -- ⇒ A row is curated when its id is in the seed. Anything else keeps the ✕, which is
        -- the same rule a hand-built list follows, applied per row instead of per filter.
        -- ⚠ dfDefaults is keyed by NUMERIC spell id (SetCuratedDefaults tonumber()s them), so
        -- the lookup coerces rather than trusting the row's field to already be a number.
        if isCurated and not isChild then
            local cf = R.GetCustomFilter and R:GetCustomFilter(selKey)
            local seeded = cf and cf.dfDefaults
            local sid = tonumber(item.id)
            if not (type(seeded) == "table" and sid and seeded[sid]) then isCurated = false end
        end
        local showCheck = isPreset or isChild or isCurated
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", isChild and 18 or 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)

        -- Release any proxied hover left over from the spell this pool slot was
        -- showing. A locked highlight has no OnLeave to release it, and the list
        -- rebinds under a stationary mouse on every toggle. Skipped while the
        -- cursor is still somewhere on this row — the row's own OnLeave owns that
        -- case, and resetting here would drop the border mid-hover.
        if not row:IsMouseOver() then ShadeRowControls(row, false) end

        row.icon:SetTexture(item.icon or FALLBACK_ICON)
        row.name:SetText(item.name)
        row.chip:SetText(item.chip or "")

        -- Chip hugs whichever control the row is showing.
        --
        -- ⚠ Anchored to that control's LEFT EDGE, never to the row's right with a
        -- magic offset. It WAS a magic offset once (-74, sized for a 64px button) and
        -- widening the button pushed its left edge underneath the neighbour, so
        -- hovering the row painted a hover wash under something else and it read as a
        -- bleeding highlight. Deriving it from the neighbour cannot drift again.
        row.check:SetShown(showCheck)
        row.chip:ClearAllPoints()
        row.chip:SetPoint("RIGHT", showCheck and row.check or row.remove, "LEFT", -6, 0)

        -- Fit the tooltip hotspot to the icon plus the name's ACTUAL rendered text.
        -- Must be per bind: the fontstring is full-width, so only the string width
        -- tells us where the visible label ends. 32 = 6 left inset + 20 icon + 6 gap.
        row.hot:SetWidth(32 + (row.name:GetStringWidth() or 0) + 4)

        -- Chip hotspot: live only on a parent row that HAS a chip to click. A child's
        -- chip is its own spell ID — a label, not a control — and the raw rows' chip is
        -- a caption, so both leave it hidden rather than offering a dead click target.
        local chipIsControl = (not isChild) and item.rec
            and item.rec.alts and #item.rec.alts > 0
        -- A control has to LOOK unlike inert text, or it stays undiscovered — which is
        -- how this shipped: the chip announced "2 spell IDs" in the same grey as the
        -- captions and offered nothing. Narrowed records take the theme colour so a
        -- record that no longer tracks everything reads at a glance.
        if chipIsControl then
            if R:IsRecordNarrowed(item.rec) then
                local tc = (GUI.GetThemeColor and GUI.GetThemeColor()) or { r = 1, g = 0.82, b = 0 }
                row.chip:SetTextColor(tc.r, tc.g, tc.b)
            else
                row.chip:SetTextColor(0.68, 0.68, 0.68)
            end
        else
            row.chip:SetTextColor(0.5, 0.5, 0.5)
        end

        row.chipHot:SetShown(chipIsControl and true or false)
        if chipIsControl then
            row.chipHot:ClearAllPoints()
            row.chipHot:SetPoint("TOP", row, "TOP", 0, 0)
            row.chipHot:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
            row.chipHot:SetPoint("RIGHT", showCheck and row.check or row.remove, "LEFT", -2, 0)
            row.chipHot:SetWidth((row.chip:GetStringWidth() or 0) + 8)
            local chipRec = item.rec
            row._onChip = function()
                expandedRecords[chipRec.id] = (not expandedRecords[chipRec.id]) or nil
                RefreshRight()
            end
            row._chipTip = format(L["This spell has %d spell IDs. Click to choose which ones to track."],
                R:RecordIDCount(chipRec))
        else
            row._onChip = nil
            row._chipTip = nil
        end

        row._spellID = item.tooltipID
        row._raw = item.raw
        row._rowToggles = showCheck

        -- Info tooltip data: canonical + variant IDs for known spells, just
        -- the raw ID otherwise. Rebuilt on every bind like the rest.
        row._infoTitle = item.name
        local rec = item.rec
        row._infoNote = item.lastLive
            and L["At least one spell ID must stay ticked. Untick the spell itself to stop tracking it."]
            or nil
        if isChild then
            -- A child row IS one spell ID; listing its siblings here would repeat the
            -- parent's line and read as though this row covered them.
            row._infoIDs = R:FormatSpellID(item.id)
        elseif rec and rec.alts and #rec.alts > 0 then
            row._infoIDs = rec.id .. ", " .. table.concat(rec.alts, ", ")
        else
            row._infoIDs = tostring(rec and rec.id or item.id)
        end

        -- `enabled` is "this spell appears on your frames" in BOTH item builders --
        -- for a preset it means the spell is in the filter, for the blacklist it
        -- means the spell is NOT blacklisted. So one expression dims both lists, and
        -- an unchecked row is a dim row everywhere on this page.
        local dim = showCheck and not item.enabled
        row.icon:SetAlpha(dim and 0.4 or 1)
        row.icon:SetDesaturated(dim)
        row.name:SetAlpha(dim and 0.5 or 1)
        ApplyNameColor(row.name, rec and rec.class, dim)

        row.remove:SetShown(not showCheck)

        if showCheck then
            row.check:SetChecked(item.enabled and true or false)
            if isChild then
                -- Tracks / untracks ONE spell ID of the record. Filter-independent by
                -- design (see the registry's muted-ID section), so this same tick
                -- governs the spell wherever it is pulled in — which is why the parent
                -- chip reports "1 of 2 IDs" in every list rather than only this one.
                local childRec, sid, tracked = item.rec, item.id, item.enabled
                row._onAction = function()
                    -- Refused on the last tracked ID (SetSpellIDMuted's guard): a record
                    -- with every ID muted still reads as tracked and matches nothing.
                    -- The row's own tooltip already carries the reason, so a refusal is
                    -- a no-op rather than a tick that bounces back unexplained.
                    if not R:SetSpellIDMuted(childRec, sid, tracked) then return end
                    DirectFilterChangedProxy()
                    RefreshAll()
                end
            elseif isCurated then
                -- Our own seeded list: the tick writes the filter's own disabled set,
                -- which ResolveSelection honours. Reset to Default clears it wholesale.
                local cfKey, sid = selKey, item.id
                row._onAction = function()
                    R:SetCustomSpellEnabled(cfKey, sid,
                        not R:IsCustomSpellEnabled(cfKey, sid))
                    DirectFilterChangedProxy()
                    RefreshAll()
                end
            else
                -- One toggle shape left: a preset's spell in or out of that preset. The
                -- inverse-polarity branch belonged to the Optional Debuffs list, which
                -- wrote a hidden-set rather than the registry; it went to the Debuff Bar
                -- page along with the list.
                local key, prec = selKey, item.rec
                row._onAction = function()
                    R:SetSpellEnabled(key, prec, not R:IsSpellEnabled(key, prec))
                    DirectFilterChangedProxy()
                    RefreshAll()
                end
            end
            row._onRemove = nil
        else
            local key, id = selKey, item.id
            row._onAction = nil
            row._onRemove = function()
                R:RemoveSpellFromCustom(key, id)
                DirectFilterChangedProxy()
                RefreshAll()
            end
        end
    end

    -- ========== REFRESH: LEFT LIST ==========
    RefreshLeft = function()
        local tc = GUI.GetThemeColor()
        presetLabel:SetTextColor(tc.r, tc.g, tc.b)
        customLabel:SetTextColor(tc.r, tc.g, tc.b)
        -- ☠ Re-theme EVERY standing button in the left list here. StyleButton
        -- registers its own theme listener on the button's PARENT, which for these is
        -- leftContent (the scroll child) — and the page's theme walk only visits
        -- pageRef.child, so that registration is never reached and the button keeps
        -- whatever accent it was built with: party blue, forever, including in raid.
        --
        -- ⚠ THIS LIST MUST HOLD EVERY SUCH BUTTON. It said "the add row" and held only
        -- addRow, so Import Filter — built the same way, two lines below it, with the
        -- same parent — stayed blue in raid (Krathe, 2026-08-10). A singular comment
        -- describing a general rule is how the second one got missed.
        --
        -- The rule: any button in this file whose PARENT is not the page child needs
        -- re-theming here. That is leftContent (addRow, importRow), leftPanel
        -- (resetBtn) and chipRow (the consumer chips and the help button) — every
        -- container on this page is anchored absolutely rather than Add()ed, so none
        -- of them is on the walk. UpdateTheme is guarded, so listing a button that
        -- does not need it costs nothing; omitting one costs a wrong colour nobody
        -- notices until they switch modes.
        for _, b in ipairs({ addRow, importRow, resetBtn, helpBtn }) do
            if b and b.UpdateTheme then b.UpdateTheme() end
        end
        for _, b in ipairs(chipButtons) do
            if b.UpdateTheme then b.UpdateTheme() end
        end
        -- ...and the band arm's, whose parent is the ACTION BAND rather than the page
        -- child. Same rule, same list, stated rather than assumed. (A filter pane's
        -- own buttons are re-themed by that pane's repaint instead, so only the panes
        -- the user can actually see are ever walked.)
        for _, b in ipairs(bandButtons) do
            if b.UpdateTheme then b.UpdateTheme() end
        end

        -- ⚠ The label TEXT is set once, at creation, and no longer here -- it is
        -- static, and the pair of SetText calls that used to live at this spot only
        -- existed to feed the hint fontstrings that no longer exist. Only the colour
        -- is per-refresh, because the theme is.
        --
        -- ⚠ The headers name their GROUP (Built-In / Custom) and deliberately do NOT
        -- say what a checkbox does. This page has two jobs and the checkbox belongs to
        -- only one -- it is a LIBRARY of filters that everything shares, and it is the
        -- buff bar's SWITCHBOARD -- so a bare switch reads as "this filter is on" when
        -- it means "the buff bar uses this filter". The page banner is what resolves
        -- that, and it is the ONLY thing that does. Do not answer it here as well.
        --
        -- ⚠ The page's checkbox verb is "select" / "unselect" wherever it is spoken
        -- (the banner, the Debuffs banner, the tooltips), and never "ticked" -- the
        -- box draws a filled square, so that word names a mark that is not on screen.
        --
        -- No mode suffix: the tabs, the theme colour (party purple vs raid orange)
        -- and the switches already carry that, and it was noise on every header. The
        -- status line still names the mode, because that claim IS mode-specific.
        HideStandingRegions()

        -- ☠ THIS LIST NO LONGER SELECTS ANYTHING FOR A BAR. Every row is passed a nil
        -- toggle, which hides the switch and moves the name into its place -- the
        -- shape the Optional Debuffs row used to have. The page is a LIBRARY: you
        -- come here to build and edit filters, and each consumer picks the ones it
        -- wants on its own page.
        --
        -- Gone from here, so nobody restores half of it:
        --   * the Buffs/Debuffs tab strip -- there is nothing debuff on this page
        --   * All Buffs / Only My Buffs      -> Buff Bar page
        --   * the per-filter on/off switch   -> Buff Bar page
        --   * Uncategorised Buffs            -> Buff Bar page (a selection, not a
        --                                       filter: it has no editable members)
        --   * Blizzard's debuff categories, the dispel-mode dropdown and Optional
        --     Debuffs                        -> Debuff Bar page
        --
        -- Rows still SELECT FOR EDITING, which is a different verb: clicking one
        -- opens it in the right-hand pane. That is now a row's only action, which is
        -- why the switch could go without leaving the row inert.
        local y, used = 4, 0

        y = PlaceSectionLabel(presetLabel, y)

        for _, cat in ipairs(R.Categories) do
            used = used + 1
            local row = AcquireLeftRow(used)
            local enabled, total = R:PresetCounts(cat.key)
            local key = cat.key
            BindLeftRow(row, y, "preset", key, L[cat.name],
                enabled .. "/" .. total,
                R:IsPresetModified(key),
                selKind == "preset" and selKey == key)
            y = y + LEFT_ROW_H
        end

        y = y + 8
        y = PlaceSectionLabel(customLabel, y)

        -- Add row FIRST, directly under its header, rather than after the filters:
        -- with none created yet the section would otherwise be a labelled void, and
        -- this is the one position where the action cannot be read as belonging to
        -- the Debuffs section below.
        addRow:ClearAllPoints()
        addRow:SetPoint("TOPLEFT", 0, -y)
        addRow:SetPoint("TOPRIGHT", 0, -y)
        addRowY = y
        y = y + LEFT_ROW_H

        -- Import directly under New: the two create-a-filter actions read as a
        -- pair, and both stay above the list they create into.
        importRow:ClearAllPoints()
        importRow:SetPoint("TOPLEFT", 0, -y)
        importRow:SetPoint("TOPRIGHT", 0, -y)
        y = y + LEFT_ROW_H

        for _, cfId in ipairs(SortedCustomIDs()) do
            local f = R:GetCustomFilter(cfId)
            used = used + 1
            local row = AcquireLeftRow(used)
            local id = cfId
            -- ★ A CURATED LIST READS LIKE A PRESET: "34/39" once something is ticked off,
            -- and the modified dot beside it. A hand-built one answers enabled == total
            -- (nothing can be off), so it keeps the single number it always had -- no
            -- branch on the kind, just the shared counter.
            local onN, totalN = R:CustomFilterCounts(id)
            BindLeftRow(row, y, "custom", id, f.name or id,
                (onN == totalN) and tostring(totalN) or (onN .. "/" .. totalN),
                R.IsCuratedFilterModified and R:IsCuratedFilterModified(id) or false,
                selKind == "custom" and selKey == id)
            y = y + LEFT_ROW_H
        end

        -- Standing frames, now always shown. They were SetShown(leftTab == "buffs")
        -- while there was a Debuffs tab they had to disappear for; there is no other
        -- tab left to hide from.
        addRow:Show()
        importRow:Show()

        -- Hide pooled rows beyond this refresh's needs
        for j = used + 1, #leftRows do
            leftRows[j]:Hide()
        end

        leftContent:SetHeight(mmax(1, y + 4))
    end

    -- ========== REFRESH: RIGHT LIST ==========
    local rawResolveRepaint -- one pending repaint while direct-ID spell data streams in
    local rawResolveTried = {} -- ids already given their one load-request + repaint
    RefreshRight = function()
        -- Guard: selected custom filter no longer exists (deleted elsewhere)
        if selKind == "custom" and not R:GetCustomFilter(selKey) then
            selKind = "preset"
            selKey = R.Categories[1] and R.Categories[1].key
        end
        local isPreset = selKind == "preset"

        -- ONE banner, info. Not keyed off the selection: an isBlacklist branch would
        -- look like it handled a case that cannot occur, since selKind only ever
        -- holds "preset" or "custom".
        --
        -- ⚠ The page banner is never a warning any more. It carried the debuff
        -- completeness caution for a while, which meant flipping All Debuffs off
        -- turned the top of the page gold AND displaced the tab's own explanation --
        -- a warning about one switch, four inches from that switch, evicting the copy
        -- that says what the whole tab is. That caution is now a banner of its own
        -- directly under All Debuffs, beside the control it is about, and nothing has
        -- to give up its slot for it.
        -- ⚠ It lives on the DEBUFF BAR page, not here: GUI/Pages/Indicators.lua,
        -- pageDebuffs, still named `catCaution`. This pointer used to say "see
        -- catCaution" meaning the local a few hundred lines up, and cf70ac00 -- the
        -- commit that moved the debuff half off this page -- deleted that local and
        -- left the reference behind. The banner went with it: it came back as a
        -- permanent grey caption on the new page, losing both its condition and its
        -- tone, and stayed that way until 2026-08-21.
        --
        -- The rule that leaves behind: this banner says "here is how this tab works"
        -- and is always info; anything that says "this will silently miss things"
        -- belongs next to the control that caused it.
        banner:SetTone("info")
        -- ONE banner now, not one per tab: there is no debuff half to swap to.
        banner:SetHTML(BUFF_BANNER, fdBannerLinkClick)

        -- Hide any lingering add-by-ID echo once the selection changes
        local selIdent = selKind .. "|" .. tostring(selKey)
        if selIdent ~= lastEchoSel then
            lastEchoSel = selIdent
            HideEcho()
        end

        local tc = GUI.GetThemeColor()
        titleText:SetTextColor(tc.r, tc.g, tc.b)

        -- Header: the mode caption, then the filter name + tracked/spell count.
        --
        -- ⚠ The caption names the KIND of thing selected, not just "editing", because
        -- built-in and custom differ in what you may do to them (a preset can be
        -- modified and reset; a custom can be renamed and deleted) and in scope --
        -- preset overrides are per PROFILE, custom filters are per ACCOUNT. The
        -- left-hand headers now say the same two words, so the caption is what ties
        -- a selected row back to the group it came from.
        --
        -- Blank, never hidden, on the blacklist: Optional Debuffs is Blizzard's list
        -- rather than one of ours, so there is no filter kind to name -- and the slot
        -- has to keep its height regardless (EYEBROW_H).
        if isPreset then
            local catName
            for _, cat in ipairs(R.Categories) do
                if cat.key == selKey then
                    catName = L[cat.name]
                    break
                end
            end
            eyebrowText:SetText(L["Editing built-in filter"])
            titleText:SetText(catName or selKey or "")
            local enabled, total = R:PresetCounts(selKey)
            countText:SetText(format(L["%d of %d tracked"], enabled, total))
        else
            eyebrowText:SetText(L["Editing custom filter"])
            local f = R:GetCustomFilter(selKey)
            titleText:SetText(f and (f.name or selKey) or "")
            -- Same shape as the left row: the fraction only appears once something is
            -- actually off, so an ordinary custom filter's header is unchanged.
            local onN, totalN = R:CustomFilterCounts(selKey)
            countText:SetText((onN == totalN) and format(L["%d spells"], totalN)
                or format(L["%d of %d spells"], onN, totalN))
        end
        -- Both texts are now set, so the name can be capped against what the count
        -- actually takes up on this pass.
        ClampTitle()

        -- Status line: SHORT, because the header panel is not wide enough for the
        -- whole story and a truncated sentence ending in "the..." is worse than no
        -- sentence. The state goes on the line; the scoping rules -- which are three
        -- levels deep and genuinely surprising -- go in the hover tooltip.
        -- ☠ THIS IS A USED-BY READOUT, NOT A SWITCH READOUT. It used to open with the
        -- filter's own on/off state, because the switch was on this page; the switch
        -- is now on each consumer's page, so there is no single "on" to report and
        -- the honest question is which consumers are currently using this filter.
        --
        -- All three are equals in the list. The buff bar is no longer special-cased
        -- as the state, with the others trailing behind as "also" -- that phrasing is
        -- what made the old line read as self-contradictory, and it stopped being
        -- true the moment the buff bar became one consumer among three.
        statusDot:Show()
        -- ⚠ The buff bar is inside FilterConsumers now, not bolted on here. It used
        -- to be read separately and labelled with the CURRENT mode, which is what
        -- made this line deny half the truth on a page that has no mode.
        local places = {}
        for _, c in ipairs(FilterConsumers(selKind, selKey)) do
            places[#places + 1] = UsageLabel(c)
        end

        if #places > 0 then
            -- StyleButton's "success" tone, so green means here what it means on a
            -- button: this is doing something.
            statusDot:SetVertexColor(0.3, 0.8, 0.45)
            statusText:SetText(format(L["Used by: %s"], table.concat(places, ", ")))
        else
            -- ⚠ GUI.Colors.warning, NOT the C_WARNING upvalue -- that is a file-local
            -- in GUI.lua, so naming it here would be a nil GLOBAL read: legal Lua,
            -- parses clean, errors only when this line runs.
            --
            -- "Not used yet" rather than "off": nothing on THIS page turned it off,
            -- so an off-state would be describing a switch the reader cannot see.
            local w = GUI.Colors.warning
            statusDot:SetVertexColor(w.r, w.g, w.b)
            statusText:SetText(L["Not used yet — pick it on a page that shows auras"])
        end

        -- The three scopes, verified against where each actually lives rather than
        -- assumed -- they are NOT the same, and the difference is what makes people
        -- think filters are broken:
        --   selection -> DF.db[mode].buffFilterSelection etc.  per MODE, per CONSUMER
        --   presets   -> DF.db.filterPresetOverrides           per PROFILE (both modes)
        --   customs   -> DF:GetGlobalDB().auraFilters          per ACCOUNT (all profiles)
        statusHit.tooltipText = L["Where this applies"]
        statusHit.tooltipLines = {
            L["Each display picks its own filters on its own page — the Buff Bar, the Defensive Icon, and Aura Designer groups. This line lists the ones using it now, across both Party and Raid."],
            isPreset
                and L["Which filters a display uses is per mode, so Party and Raid keep separate choices. What a filter CONTAINS is not per mode: editing its spells changes both."]
                or  L["Which filters a display uses is per mode, so Party and Raid keep separate choices. A custom filter's spells are shared by every profile on the account."],
        }

        -- Gather visible items grouped by class token
        local groups = {}
        local function put(token, item)
            token = token or "ALL"
            if not RAID_CLASS_COLORS or not RAID_CLASS_COLORS[token] then
                if token ~= "ALL" then token = "ALL" end
            end
            local g = groups[token]
            if not g then
                g = {}
                groups[token] = g
            end
            g[#g + 1] = item
        end
        -- The chip on a multi-ID record: "+1" while whole, "1 of 2" once narrowed, so
        -- a record that no longer tracks everything says so in EVERY list it appears
        -- in rather than hiding the state behind the expander.
        local function RecordChip(rec)
            if not (rec and rec.alts and #rec.alts > 0) then return nil end
            if R:IsRecordNarrowed(rec) then
                return format(L["%d of %d IDs"], #R:LiveRecordIDs(rec), R:RecordIDCount(rec))
            end
            return format("+%d", #rec.alts)
        end

        -- One child row per spell ID the record carries, emitted straight into the
        -- class bucket so they ride the same pooled rows, layout and scroll as
        -- everything else -- there is no nested widget here, just indented items.
        -- Icon and name resolve LIVE per ID: the database keeps one name per RECORD,
        -- and telling Holy Bulwark's buff from its absorb shield is exactly what the
        -- user is here to do, so the per-id art is the only thing that distinguishes
        -- them.
        local function putRecordChildren(token, rec, parentName)
            if not (expandedRecords[rec.id] and rec.alts and #rec.alts > 0) then return end
            local ids = { rec.id }
            for _, alt in ipairs(rec.alts) do ids[#ids + 1] = alt end
            local live = #R:LiveRecordIDs(rec)
            for idx, sid in ipairs(ids) do
                local nm, icon
                if C_Spell then
                    if C_Spell.GetSpellName then
                        local ok, v = pcall(C_Spell.GetSpellName, sid)
                        if ok and type(v) == "string" and v ~= "" then nm = v end
                    end
                    if C_Spell.GetSpellTexture then
                        local ok, t = pcall(C_Spell.GetSpellTexture, sid)
                        if ok and type(t) == "number" then icon = t end
                    end
                end
                local tracked = not R:IsSpellIDMuted(sid)
                put(token, {
                    child = true, rec = rec, id = sid,
                    name = nm or rec.n,
                    icon = icon or FALLBACK_ICON,
                    chip = R:FormatSpellID(sid),
                    enabled = tracked,
                    -- Sort with the parent, in record-id order beneath it.
                    sortName = parentName, sortID = rec.id, childIndex = idx,
                    -- The last tracked id can't be unticked (SetSpellIDMuted refuses):
                    -- a record with nothing live reads as tracked and matches nothing.
                    lastLive = tracked and live <= 1,
                    tooltipID = sid,
                })
            end
        end

        local function matches(name)
            if searchText == "" then return true end
            return name:lower():find(searchText, 1, true) ~= nil
        end
        local function putRaw(id)
            -- Not in the shipped database: resolve name/icon LIVE from the
            -- client so a valid direct ID reads like a real spell — the row
            -- keeps a "not in database" chip to mark it. The first resolve can
            -- miss while spell data streams in, so request the load and repaint
            -- once shortly after; only a genuinely unknown ID keeps the
            -- "#id" + question-mark presentation.
            local name, icon
            if C_Spell and C_Spell.GetSpellName then
                local ok, v = pcall(C_Spell.GetSpellName, id)
                if ok and type(v) == "string" and v ~= "" then name = v end
                local okT, t = pcall(C_Spell.GetSpellTexture, id)
                if okT and type(t) == "number" then icon = t end
                if not name and C_Spell.RequestLoadSpellData and not rawResolveTried[id] then
                    -- One load-request + one repaint per id, ever: a genuinely
                    -- invalid id never resolves, and re-requesting from the
                    -- repaint's own RefreshRight would loop the 0.8s timer
                    -- forever (even with the page closed).
                    rawResolveTried[id] = true
                    pcall(C_Spell.RequestLoadSpellData, id)
                    if not rawResolveRepaint then
                        rawResolveRepaint = true
                        C_Timer.After(0.8, function()
                            rawResolveRepaint = nil
                            RefreshRight()
                        end)
                    end
                end
            end
            -- ☠ NOT format("#%d", id). This renders whatever is STORED, and the input
            -- cap cannot reach an id that arrived in an imported filter string or was
            -- saved before that cap existed -- those still have to draw rather than
            -- take the page down. R:FormatSpellID is overflow-safe. This exact line was
            -- the traceback in the #2222222222 report.
            local nm = name or ("#" .. R:FormatSpellID(id))
            if matches(nm) then
                put("ALL", {
                    id = id, name = nm, icon = icon or FALLBACK_ICON,
                    chip = name and L["not in database"] or L["unknown ID"],
                    -- Curated lists tick their raw ids too; see the spells arm.
                    enabled = (selKind == "custom" and selKey)
                        and R:IsCustomSpellEnabled(selKey, id) or nil,
                    raw = true, tooltipID = id,
                })
            end
        end

        if isPreset then
            for _, rec in ipairs(R.ByCategory[selKey] or {}) do
                local name, icon = R:GetSpellDisplay(rec)
                if matches(name) then
                    put(rec.class, {
                        rec = rec, id = rec.id, name = name, icon = icon,
                        chip = RecordChip(rec),
                        enabled = R:IsSpellEnabled(selKey, rec),
                        tooltipID = rec.id,
                    })
                    putRecordChildren(rec.class, rec, name)
                end
            end
        -- (The fixed non-secret debuff list built a third item shape here. It went to
        -- the Debuff Bar page, where it is a plain group of checkboxes rather than a
        -- pooled list with its own inverted polarity.)
        else
            local f = R:GetCustomFilter(selKey)
            if f then
                for sid in pairs(f.spells) do
                    local rec = R.ByID[sid]
                    if rec then
                        local name, icon = R:GetSpellDisplay(rec)
                        if matches(name) then
                            put(rec.class, {
                                rec = rec, id = sid, name = name, icon = icon,
                                chip = RecordChip(rec),
                                -- On a curated list the row shows a tick, so it needs
                                -- the state to draw. Absent on a hand-built filter,
                                -- whose rows show the ✕ and never read this.
                                enabled = R:IsCustomSpellEnabled(selKey, sid),
                                tooltipID = rec.id,
                            })
                            putRecordChildren(rec.class, rec, name)
                        end
                    else
                        -- Known id orphaned by a spell DB update: render as raw
                        putRaw(sid)
                    end
                end
                for rid in pairs(f.rawIDs) do
                    putRaw(rid)
                end
            end
        end

        -- Sort within each group: named spells alphabetically, raw ids last
        --
        -- ☠ CHILD ROWS SORT ON THEIR PARENT'S KEY, NEVER THEIR OWN. They are part of
        -- that row, not entries in their own right, and sorting them on their own name
        -- and id scatters them: Holy Bulwark's absorb component resolves to the same
        -- NAME as its parent and a LOWER id (432496 vs 432607), so it landed above the
        -- record it belongs to while every record whose alts happen to be numerically
        -- higher expanded downwards. sortName/sortID carry the parent's key and
        -- childIndex orders the block beneath it, canonical id first.
        for _, g in pairs(groups) do
            tsort(g, function(a, b)
                if (a.raw or false) ~= (b.raw or false) then return not a.raw end
                -- Raw rows sort by resolved name too; unresolved "#id" names
                -- cluster first ("#" < letters), ordered by id via the tiebreak.
                local an, bn = a.sortName or a.name, b.sortName or b.name
                if an ~= bn then return an < bn end
                local ai, bi = a.sortID or a.id, b.sortID or b.id
                if ai ~= bi then return ai < bi end
                return (a.childIndex or 0) < (b.childIndex or 0)
            end)
        end

        -- Render groups in class order, ALL last
        local y = 4
        local usedHeaders, usedRows, shown = 0, 0, 0
        local function RenderGroup(token)
            local g = groups[token]
            if not g or #g == 0 then return end
            -- Always a class header now. It was skipped for the flat Optional Debuffs
            -- list, where "All Classes" added nothing; every remaining view is a
            -- class-grouped filter.
            usedHeaders = usedHeaders + 1
            local hdr = AcquireClassHeader(usedHeaders)
            hdr:ClearAllPoints()
            hdr:SetPoint("TOPLEFT", 6, -(y + 6))
            hdr:SetText(ClassDisplayName(token))
            local cc = token ~= "ALL" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
            if cc then
                hdr:SetTextColor(cc.r, cc.g, cc.b)
            else
                hdr:SetTextColor(0.65, 0.65, 0.65)
            end
            y = y + CLASS_HEADER_H

            for _, item in ipairs(g) do
                usedRows = usedRows + 1
                shown = shown + 1
                local row = AcquireSpellRow(usedRows)
                BindSpellRow(row, y, item, isPreset)
                y = y + SPELL_ROW_H
            end
            y = y + 4
        end
        for _, token in ipairs(CLASS_ORDER) do
            RenderGroup(token)
        end
        RenderGroup("ALL")

        -- Hide pooled widgets beyond this refresh's needs
        for j = usedHeaders + 1, #classHeaders do
            classHeaders[j]:Hide()
        end
        for j = usedRows + 1, #spellRows do
            spellRows[j]:Hide()
        end

        emptyText:SetShown(shown == 0)
        emptyText:SetText(searchText ~= "" and L["No results found"] or L["This filter is empty."])

        scrollContent:SetHeight(mmax(1, y + 4))
    end

    RefreshAll = function()
        RefreshLeft()
        RefreshRight()
        -- The chips read the buff selection, the Defensive Icon's selection and the
        -- whole Aura Designer config, so they are stale after ANY of those change --
        -- including from another page, which is why this rides RefreshAll rather
        -- than the tick handlers.
        RefreshChips()
        -- ...and the band arm's list of filter rows: it re-binds row i to filter i
        -- after a create, a rename or a delete, and repaints every panel the user
        -- currently has open. Guarded: it is only assigned in that arm.
        if RefreshFilterRows then RefreshFilterRows() end
        -- ...and the three consumer rows, whose counts come from the buff
        -- selection, the Defensive Icon's selection and the whole Aura Designer
        -- config -- every one of them edited on another page, which is why this
        -- rides the page's own refresh rather than a callback from any of them.
        if USEDBY.Refresh then USEDBY.Refresh() end
        UpdateActionStates()
        -- Keep the picker coherent: hide it when the selection moved off its
        -- target custom filter (or the filter was deleted); otherwise
        -- re-render so newly-added rows pick up their check/dim state.
        if pickerHandle and pickerHandle:IsOpen() then
            if selKind == "custom" and selKey == pickerTarget and R:GetCustomFilter(pickerTarget) then
                pickerHandle:Refresh()
            else
                pickerHandle:Close()
            end
        end
    end
    pageRef._fdRefreshAll = RefreshAll
    -- Cross-page entry: the Aura Filters "Edit Debuff Blacklist" button navigates
    -- here (SelectTab builds synchronously) then calls this to land directly on
    -- the Blacklist entry instead of the default buff preset.
    -- ⚠ Both entry points must move the TAB as well as the selection. Selecting the
    -- Blacklist while the Buffs tab is showing would select a row that is not on
    -- screen -- the right pane would fill with blacklist spells while the left list
    -- still showed buff filters, and nothing would say why.
    -- ☠ _fdSelectBlacklist IS GONE, not stubbed. It landed this page on the Optional
    -- Debuffs entry, and there is no such entry here -- that list is on the Debuff
    -- Bar page. Anything wanting it should SelectTab("auras_debuffs"). A stub that
    -- navigated somewhere plausible-but-wrong would be worse than the nil call.
    -- (The `pageRef._fdSelectBlacklist = nil` statement that used to sit here went
    -- too: assigning nil to a field nothing sets or reads is a no-op, and the
    -- paragraph above is what actually carries the decision.)
    --
    -- ☠ _fdSelectBuffs went with it. It was the buff-side "Customise" entry point,
    -- and its whole job was to move you off the Blacklist if you were parked there --
    -- a view this page no longer has. Nothing in either addon called it; contrast
    -- _fdFocusFilter and _fdFocusNewFilter just above, which the Aura Designer does
    -- call and which stay.

    -- ========== SEARCH WIRING ==========
    -- HookScript (not SetScript): CreateEditBox already hooks OnTextChanged
    -- for its placeholder handling.
    searchBox.EditBox:HookScript("OnTextChanged", function(eb)
        local q = (eb:GetText() or ""):lower()
        if q == searchText then return end
        searchText = q
        RefreshRight()
    end)

    -- ========== THEME LISTENER ==========
    -- Recolor selection highlights, section labels, and the title on theme change
    local themeListener = { UpdateTheme = function() RefreshAll() end }
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    tinsert(parent.ThemeListeners, themeListener)
    pageRef._fdThemeListener = themeListener

    -- ============================================================
    -- THE BAND ARM -- THE PAGE IS THE LIST OF FILTERS
    -- ------------------------------------------------------------
    -- Everything above built the island: a two-column master/detail chained off
    -- `parent`. The band arm no longer re-homes any of it. It builds a COLUMN OF
    -- FILTERS instead -- one popout row per filter -- and each row's panel carries
    -- that filter's OWN header and its OWN spell list.
    --
    --     [ info banner                          ]
    --     [ Filters   [+ New] [+ Import]  [?]    ]   the action band
    --     [ Healing                            > ]   one row per filter
    --     [ Defensives                         > ]
    --     [ ...                                 > ]
    --     [ spell database: ...                 ]
    --
    -- ☠ THE MASTER ROW IS GONE, AND SO IS THE DETAIL BAND. e879d644 put the filter
    -- list behind ONE row to fix a WIDTH problem, and it fixed it -- but it left
    -- the page answering the wrong question: you could not see the list of filters
    -- and a filter's contents at the same time, and you could never see two filters
    -- at once. A row each answers both, because DF popouts dock OUTSIDE the window
    -- and two of them can stand side by side.
    --
    -- ☠ THE PAGE BUILDS ITS FRAMES ONCE (_filterDesignerBuilt) AND FILTERS ARE
    -- CREATED AT RUNTIME. Those two facts are what make this hard, and the way
    -- through is a property of this page that is easy to miss: CreatePopoutPageTools
    -- is called BELOW the guard's early return, so it runs exactly once here and the
    -- `mounted` list and holder registry it closes over live for the session. A row
    -- created on the fortieth filter, an hour after the page was built, joins the
    -- same registry as the first -- there is no build pass to be outside of. So rows
    -- are ACQUIRED on demand (AcquireFilterRow) exactly as the island's list rows
    -- are, and never destroyed.
    --
    -- ⚠ REJECTED: clearing _filterDesignerBuilt to force a rebuild when a filter is
    -- added. Frames cannot be garbage-collected in this client, so every rebuild
    -- would leak the whole page; and CreatePopoutPageTools closes every open panel
    -- on every build, so the panel the user is working in would snap shut each time.
    --
    -- ☠ NOTHING ABOVE THIS POINT IS BRANCHED ON IT. The island builds exactly as it
    -- always did; the band arm takes its three roots DOWN (the chip row, the master
    -- panel, the detail) and builds its own column beside them.
    if rowsMode then
        local paneW = GUI.PopoutContentWidth or 260

        -- ---- THE PANE'S OWN ARITHMETIC ----
        -- ☠ FIXED, AND DECIDED AT BUILD RATHER THAN FROM THE VIEWPORT. DandersUI
        -- caps a pane at 60% of the screen and WRAPS anything taller in a scroll
        -- frame of its own (PopoutRow's capHeight, read at build time) -- and this
        -- pane already carries one, round its spell list. A viewport-sized pane
        -- would therefore be a list scrolling inside a list, which is the same
        -- refusal the master's own fixed height used to state. UIParent is 768 tall
        -- at every UI scale the client allows below the default, so the ceiling to
        -- stay under is ~460 and the sum below is 414.
        -- ☠ ONE TABLE, NOT TWENTY LOCALS, AND THAT IS A HARD LIMIT RATHER THAN A
        -- preference. Lua 5.1 allows a function 200 ACTIVE locals and this builder is
        -- one 3,000-line closure that was already at 171 before this arm existed --
        -- a constant per header row compiles to "function at line 370 has more than
        -- 200 local variables", which is a PARSE error, so the whole file fails to
        -- load. Fields cost nothing; names cost a slot each.
        local PANE = {}
        PANE.gap, PANE.titleH, PANE.ebH, PANE.btnH, PANE.echoH = 6, 18, 24, 22, 13
        -- CreateEditBox drops its editbox 15px to clear a label slot this page leaves
        -- empty, so a box whose VISIBLE top is wanted at y is anchored 15 higher.
        PANE.ebDrop = 15
        PANE.actionLabelH, PANE.actionBtnH = 20, 22
        -- ☠ WRITTEN AS THE SUM OF THE SIX HEADER PARTS, IN READING ORDER, for the
        -- reason the island's ROW2_Y / ROW3_Y are written as sums: this file has
        -- twice shipped a header row whose neighbours were not told it had arrived.
        -- A part added here must be a term added here.
        PANE.yEyebrow = 0                                              -- (1) kind
        PANE.yTitle   = PANE.yEyebrow + EYEBROW_H                      -- (2) name + count
        PANE.yStatus  = PANE.yTitle + PANE.titleH                      -- (3) used by
        PANE.ySearch  = PANE.yStatus + STATUS_ROW_H + PANE.gap         -- (4) search
        PANE.yAdd     = PANE.ySearch + PANE.ebH + PANE.gap             -- (5) spell id + Add
        PANE.yDB      = PANE.yAdd + PANE.ebH + PANE.gap                -- (6) add from database
        PANE.yEcho    = PANE.yDB + PANE.btnH + 2
        PANE.headH    = PANE.yEcho + PANE.echoH
        -- Three 20px rows, two 4px gutters, and the rule that marks them as chrome
        -- rather than more list. The island's own strip, one column narrower.
        PANE.actH     = 80
        -- ☠ THE LIST TAKES WHAT THE SCREEN WILL GIVE IT, rather than a literal.
        -- 170 showed six spells at a time on a page whose whole job is picking
        -- spells ("can we have the popout a bit taller so the scroll box shows
        -- more at once"), and it was a literal because the header above it is one.
        --
        -- ⚠ 0.6 OF THE SCREEN IS A CLIFF, NOT A GUIDELINE. Past it the kit wraps
        -- the whole pane in its OWN scroll frame (PopoutRow's capHeight) and the
        -- user gets a list scrolling inside a list -- the exact fault that pinned
        -- the old master panel at 320. So the budget is measured, the chrome is
        -- subtracted, and a margin is left under the cliff rather than touching it.
        --
        -- The floor keeps the old behaviour on a short screen; the ceiling stops a
        -- very tall monitor handing back a panel taller than anything in it.
        --
        -- ☠ AND IT COMES AFTER EVERY TERM IT SPENDS. This block is a straight run
        -- of assignments with no function around it, so a term read before its own
        -- line is simply nil and the arithmetic throws -- at BUILD time, which
        -- takes the whole page down with it. It shipped that way once, reading
        -- PANE.actH from above the line that sets it.
        local capH = ((UIParent and UIParent.GetHeight and UIParent:GetHeight()) or 768) * 0.6
        PANE.listH    = math.max(170, math.min(560,
                            math.floor(capH - 24 - PANE.headH - PANE.gap * 2 - PANE.actH)))
        PANE.paneH    = PANE.headH + PANE.gap + PANE.listH + PANE.gap + PANE.actH

        -- Assigned below, once the row pool exists. Forward-declared because the
        -- pane builder -- written first, because the rows are built from it -- ends
        -- several of its verbs by opening the panel of a filter it has just made.
        local FocusFilterPanel
        local NewFilterFlow

        -- ============================================================
        -- WHAT IS IN ONE FILTER, AS A LIST OF ITEMS
        -- ------------------------------------------------------------
        -- ONE collector for every pane rather than one per pane: the answer depends
        -- on (kind, key, query) and on nothing a pane owns, so a copy per pane would
        -- be seventeen places for the sort rule to drift.
        -- ============================================================
        local function PaneItems(pane, kind, key, query)
            local isPreset = (kind == "preset")
            local groups = {}
            local function put(token, item)
                token = token or "ALL"
                if not RAID_CLASS_COLORS or not RAID_CLASS_COLORS[token] then
                    if token ~= "ALL" then token = "ALL" end
                end
                local g = groups[token]
                if not g then
                    g = {}
                    groups[token] = g
                end
                g[#g + 1] = item
            end
            -- "+1" while whole, "1 of 2" once narrowed, so a record that no longer
            -- tracks everything says so in every list it appears in.
            local function RecordChip(rec)
                if not (rec and rec.alts and #rec.alts > 0) then return nil end
                if R:IsRecordNarrowed(rec) then
                    return format(L["%d of %d IDs"], #R:LiveRecordIDs(rec), R:RecordIDCount(rec))
                end
                return format("+%d", #rec.alts)
            end
            -- One child row per spell ID the record carries, emitted straight into
            -- the class bucket so they ride the same pooled rows as everything else.
            local function putRecordChildren(token, rec, parentName)
                if not (expandedRecords[rec.id] and rec.alts and #rec.alts > 0) then return end
                local ids = { rec.id }
                for _, alt in ipairs(rec.alts) do ids[#ids + 1] = alt end
                local live = #R:LiveRecordIDs(rec)
                for idx, sid in ipairs(ids) do
                    local nm, icon
                    if C_Spell then
                        if C_Spell.GetSpellName then
                            local ok, v = pcall(C_Spell.GetSpellName, sid)
                            if ok and type(v) == "string" and v ~= "" then nm = v end
                        end
                        if C_Spell.GetSpellTexture then
                            local ok, t = pcall(C_Spell.GetSpellTexture, sid)
                            if ok and type(t) == "number" then icon = t end
                        end
                    end
                    local tracked = not R:IsSpellIDMuted(sid)
                    put(token, {
                        child = true, rec = rec, id = sid,
                        name = nm or rec.n,
                        icon = icon or FALLBACK_ICON,
                        chip = R:FormatSpellID(sid),
                        enabled = tracked,
                        sortName = parentName, sortID = rec.id, childIndex = idx,
                        lastLive = tracked and live <= 1,
                        tooltipID = sid,
                    })
                end
            end
            local function matches(name)
                if query == "" then return true end
                return name:lower():find(query, 1, true) ~= nil
            end
            -- Not in the shipped database: resolve name/icon LIVE from the client so
            -- a valid direct ID reads like a real spell. One load-request and one
            -- repaint per id, ever -- a genuinely invalid id never resolves, and
            -- re-requesting from the repaint would loop the timer forever.
            local function putRaw(id)
                local name, icon
                if C_Spell and C_Spell.GetSpellName then
                    local ok, v = pcall(C_Spell.GetSpellName, id)
                    if ok and type(v) == "string" and v ~= "" then name = v end
                    local okT, t = pcall(C_Spell.GetSpellTexture, id)
                    if okT and type(t) == "number" then icon = t end
                    if not name and C_Spell.RequestLoadSpellData and not pane.rawTried[id] then
                        pane.rawTried[id] = true
                        pcall(C_Spell.RequestLoadSpellData, id)
                        if not pane.rawPending then
                            pane.rawPending = true
                            C_Timer.After(0.8, function()
                                pane.rawPending = nil
                                -- ⚠ ONLY IF IT IS STILL ON SCREEN. A closed pane
                                -- sits in a hidden holder and repainting one costs a
                                -- full re-gather for something nobody is looking at.
                                if pane.container:IsVisible() then pane.Paint() end
                            end)
                        end
                    end
                end
                -- ☠ NOT format("#%d", id). R:FormatSpellID is overflow-safe, and an
                -- id past 2^31 can still arrive in an imported filter string.
                local nm = name or ("#" .. R:FormatSpellID(id))
                if matches(nm) then
                    put("ALL", {
                        id = id, name = nm, icon = icon or FALLBACK_ICON,
                        chip = name and L["not in database"] or L["unknown ID"],
                        raw = true, tooltipID = id,
                    })
                end
            end

            if isPreset then
                for _, rec in ipairs(R.ByCategory[key] or {}) do
                    local name, icon = R:GetSpellDisplay(rec)
                    if matches(name) then
                        put(rec.class, {
                            rec = rec, id = rec.id, name = name, icon = icon,
                            chip = RecordChip(rec),
                            enabled = R:IsSpellEnabled(key, rec),
                            tooltipID = rec.id,
                        })
                        putRecordChildren(rec.class, rec, name)
                    end
                end
            else
                local f = R:GetCustomFilter(key)
                if f then
                    for sid in pairs(f.spells) do
                        local rec = R.ByID[sid]
                        if rec then
                            local name, icon = R:GetSpellDisplay(rec)
                            if matches(name) then
                                put(rec.class, {
                                    rec = rec, id = sid, name = name, icon = icon,
                                    chip = RecordChip(rec),
                                    tooltipID = rec.id,
                                })
                                putRecordChildren(rec.class, rec, name)
                            end
                        else
                            -- Known id orphaned by a spell DB update: render as raw
                            putRaw(sid)
                        end
                    end
                    for rid in pairs(f.rawIDs) do
                        putRaw(rid)
                    end
                end
            end

            -- ☠ CHILD ROWS SORT ON THEIR PARENT'S KEY, NEVER THEIR OWN -- they are
            -- part of that row, not entries in their own right, and sorting them on
            -- their own name and id scatters them across the group.
            for _, g in pairs(groups) do
                tsort(g, function(a, b)
                    if (a.raw or false) ~= (b.raw or false) then return not a.raw end
                    local an, bn = a.sortName or a.name, b.sortName or b.name
                    if an ~= bn then return an < bn end
                    local ai, bi = a.sortID or a.id, b.sortID or b.id
                    if ai ~= bi then return ai < bi end
                    return (a.childIndex or 0) < (b.childIndex or 0)
                end)
            end
            return groups
        end

        -- ============================================================
        -- ONE PANE'S SPELL ROWS
        -- ------------------------------------------------------------
        -- ☠ CREATED ON THE PANE'S FIRST PAINT, NEVER IN ITS BUILDER. PopoutContent
        -- runs a row's builder EAGERLY, at page build, for EVERY row -- seventeen
        -- filters' worth of spell rows up front is a cost the old page never paid,
        -- because it only ever had one list. The builder puts up an EMPTY scroll
        -- frame; these arrive when somebody actually opens the panel.
        -- ============================================================
        local function AcquirePaneClassHeader(pane, i)
            local fs = pane.classHeaders[i]
            if fs then
                fs:Show()
                return fs
            end
            fs = pane.content:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            fs:SetJustifyH("LEFT")
            pane.classHeaders[i] = fs
            return fs
        end

        local function AcquirePaneSpellRow(pane, i)
            local row = pane.spellRows[i]
            if row then
                ApplyRowPropagation(row)
                row:Show()
                return row
            end
            row = CreateFrame("Button", nil, pane.content, "BackdropTemplate")
            row:SetHeight(SPELL_ROW_H - 2)
            DF.GUI:CreateElementBackdrop(row, {
                outline = false,
                bgColor = { ROW_REST_R, ROW_REST_G, ROW_REST_B, ROW_REST_A },
            })

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(20, 20)
            row.icon:SetPoint("LEFT", 6, 0)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            -- ☑ MEANS ONE THING ON EVERY LIST ON THIS PAGE: this spell appears on
            -- your frames. EnableMouse(false) -- the ROW owns the click, so there is
            -- one hit area and no dead pixel beside the box.
            row.check = GUI:CreateRowToggle(row)
            row.check:EnableMouse(false)
            row.check:SetPoint("RIGHT", -6, 0)

            row.remove = GUI:CreateCloseButton(row, {
                size = 18,
                tone = "danger",
                onClick = function()
                    if row._onRemove then row._onRemove() end
                end,
            })
            row.remove:SetPoint("RIGHT", -6, 0)

            row.chip = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            row.chip:SetJustifyH("RIGHT")
            row.chip:SetTextColor(0.5, 0.5, 0.5)

            row.name = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.name:SetPoint("RIGHT", row.chip, "LEFT", -6, 0)
            row.name:SetJustifyH("LEFT")

            -- Tooltip hotspot: the icon and the name only, so the spell tooltip does
            -- not fire while you are reaching for the control at the row's far end.
            -- Its WIDTH is set per bind, from the name's STRING width.
            local hot = CreateFrame("Frame", nil, row)
            hot:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            hot:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
            hot:EnableMouse(true)
            hot:SetScript("OnEnter", function()
                local lines
                local ids = row._infoIDs and format(L["Spell IDs: %s"], row._infoIDs)
                if ids then lines = { ids } end
                if row._infoNote then
                    lines = lines or {}
                    lines[#lines + 1] = row._infoNote
                end
                if row._spellID and not row._raw then
                    ShowSpellTooltip(row, row._spellID, row._infoTitle, SpellRowStillShows, lines)
                elseif row._infoTitle then
                    GUI:ShowTooltip(row, { title = row._infoTitle, lines = lines })
                end
            end)
            hot:SetScript("OnLeave", function() GUI:HideTooltip() end)
            row.hot = hot

            -- ⚠ MOTION propagates, CLICKS do not -- the opposite split to row.hot,
            -- and both halves matter: without motion the row's hover wash drops out
            -- under the cursor, without click isolation opening the record would also
            -- toggle the whole spell. Propagation itself is applied by
            -- ApplyRowPropagation, which is combat-deferred on 12.1.
            local chipHot = CreateFrame("Button", nil, row)
            chipHot:SetPoint("TOP", row, "TOP", 0, 0)
            chipHot:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
            chipHot:EnableMouse(true)
            chipHot:SetScript("OnClick", function()
                if row._onChip then row._onChip() end
            end)
            chipHot:SetScript("OnEnter", function(self)
                if not row._chipTip then return end
                GUI:ShowTooltip(self, { title = row._infoTitle, lines = { row._chipTip } })
            end)
            chipHot:SetScript("OnLeave", function() GUI:HideTooltip() end)
            row.chipHot = chipHot
            ApplyRowPropagation(row)   -- no-op in combat; healed on the next OOC acquire

            row:SetScript("OnClick", function(self)
                if self._rowToggles and self._onAction then self._onAction() end
            end)
            row:SetScript("OnEnter", function(self)
                self:SetBackdropColor(ROW_HOVER_R, ROW_HOVER_G, ROW_HOVER_B, ROW_HOVER_A)
                ShadeRowControls(self, true)
            end)
            row:SetScript("OnLeave", function(self)
                self:SetBackdropColor(ROW_REST_R, ROW_REST_G, ROW_REST_B, ROW_REST_A)
                ShadeRowControls(self, false)
                GUI:HideTooltip()
            end)

            pane.spellRows[i] = row
            return row
        end

        -- `key` is passed rather than read off the pane: a bind is the one moment
        -- the filter this row belongs to is settled, and the handlers it installs
        -- outlive the paint that made them.
        local function BindPaneSpellRow(pane, row, y, item, isPreset, key)
            local isChild = item.child and true or false
            local showCheck = isPreset or isChild
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", isChild and 18 or 0, -y)
            row:SetPoint("TOPRIGHT", 0, -y)

            -- Release any proxied hover left over from the spell this pool slot was
            -- showing; skipped while the cursor is still on this row, whose own
            -- OnLeave owns that case.
            if not row:IsMouseOver() then ShadeRowControls(row, false) end

            row.icon:SetTexture(item.icon or FALLBACK_ICON)
            row.name:SetText(item.name)
            row.chip:SetText(item.chip or "")

            -- Chip hugs whichever control the row is showing -- anchored to that
            -- control's LEFT EDGE, never to the row's right with a magic offset.
            row.check:SetShown(showCheck)
            row.chip:ClearAllPoints()
            row.chip:SetPoint("RIGHT", showCheck and row.check or row.remove, "LEFT", -6, 0)

            -- 32 = 6 left inset + 20 icon + 6 gap.
            row.hot:SetWidth(32 + (row.name:GetStringWidth() or 0) + 4)

            local chipIsControl = (not isChild) and item.rec
                and item.rec.alts and #item.rec.alts > 0
            if chipIsControl then
                if R:IsRecordNarrowed(item.rec) then
                    local tc = (GUI.GetThemeColor and GUI.GetThemeColor()) or { r = 1, g = 0.82, b = 0 }
                    row.chip:SetTextColor(tc.r, tc.g, tc.b)
                else
                    row.chip:SetTextColor(0.68, 0.68, 0.68)
                end
            else
                row.chip:SetTextColor(0.5, 0.5, 0.5)
            end

            row.chipHot:SetShown(chipIsControl and true or false)
            if chipIsControl then
                row.chipHot:ClearAllPoints()
                row.chipHot:SetPoint("TOP", row, "TOP", 0, 0)
                row.chipHot:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
                row.chipHot:SetPoint("RIGHT", showCheck and row.check or row.remove, "LEFT", -2, 0)
                row.chipHot:SetWidth((row.chip:GetStringWidth() or 0) + 8)
                local chipRec = item.rec
                row._onChip = function()
                    -- ☠ RefreshAll, NOT THIS PANE. expandedRecords is keyed by record
                    -- and is deliberately filter-independent, so opening one here
                    -- opens it in every other filter that carries the same spell --
                    -- and a second filter's panel may be pinned open beside this one.
                    expandedRecords[chipRec.id] = (not expandedRecords[chipRec.id]) or nil
                    RefreshAll()
                end
                row._chipTip = format(L["This spell has %d spell IDs. Click to choose which ones to track."],
                    R:RecordIDCount(chipRec))
            else
                row._onChip = nil
                row._chipTip = nil
            end

            row._spellID = item.tooltipID
            row._raw = item.raw
            row._rowToggles = showCheck

            row._infoTitle = item.name
            local rec = item.rec
            row._infoNote = item.lastLive
                and L["At least one spell ID must stay ticked. Untick the spell itself to stop tracking it."]
                or nil
            if isChild then
                row._infoIDs = R:FormatSpellID(item.id)
            elseif rec and rec.alts and #rec.alts > 0 then
                row._infoIDs = rec.id .. ", " .. table.concat(rec.alts, ", ")
            else
                row._infoIDs = tostring(rec and rec.id or item.id)
            end

            local dim = showCheck and not item.enabled
            row.icon:SetAlpha(dim and 0.4 or 1)
            row.icon:SetDesaturated(dim)
            row.name:SetAlpha(dim and 0.5 or 1)
            ApplyNameColor(row.name, rec and rec.class, dim)

            row.remove:SetShown(not showCheck)

            if showCheck then
                row.check:SetChecked(item.enabled and true or false)
                if isChild then
                    local childRec, sid, tracked = item.rec, item.id, item.enabled
                    row._onAction = function()
                        -- Refused on the last tracked ID; the row's own tooltip
                        -- already carries the reason, so a refusal is a no-op.
                        if not R:SetSpellIDMuted(childRec, sid, tracked) then return end
                        DirectFilterChangedProxy()
                        RefreshAll()
                    end
                else
                    local prec = item.rec
                    row._onAction = function()
                        R:SetSpellEnabled(key, prec, not R:IsSpellEnabled(key, prec))
                        DirectFilterChangedProxy()
                        RefreshAll()
                    end
                end
                row._onRemove = nil
            else
                local id = item.id
                row._onAction = nil
                row._onRemove = function()
                    R:RemoveSpellFromCustom(key, id)
                    DirectFilterChangedProxy()
                    RefreshAll()
                end
            end
        end

        -- ============================================================
        -- ONE FILTER'S PANEL
        -- ------------------------------------------------------------
        -- ☠ ONE CONTAINER FRAME, AND EVERYTHING GOES INSIDE IT. PopoutContent builds
        -- into a HIDDEN holder and moves FRAMES into the group -- a REGION made on
        -- that holder (a FontString) stays behind and is never drawn, in silence.
        -- Six of the parts below are FontStrings, which is exactly the trap this
        -- rework has already paid for on five captions elsewhere.
        --
        -- ☠ AND NOTHING THAT VARIES BY FILTER IS CAPTURED HERE. A pane is built ONCE
        -- per (instance, row) and never rebuilt, while the ROW is re-bound to a
        -- different filter whenever one is created or deleted -- so every fact about
        -- a filter is read by Paint(), through the SLOT, at paint time. The slot is
        -- what the row and its panes share; capturing the row itself is impossible
        -- anyway, since this builder runs inside CreatePopoutRow's own arguments.
        --
        -- ☠ ALL SIX HEADER PARTS, IN EVERY PANEL. (5) and (6) are DISABLED on a
        -- built-in filter rather than absent -- you cannot add or remove a spell from
        -- a preset, only tick what is in it, and a header that changes SHAPE between
        -- the two kinds makes the reader re-learn it on every row.
        -- ============================================================
        local function BuildFilterPane(group, holder, slot)
            local pane = {
                slot = slot, query = "", boundIdent = nil,
                spellRows = {}, classHeaders = {}, rawTried = {},
            }

            local c = CreateFrame("Frame", nil, holder)
            c:SetSize(paneW, PANE.paneH)
            pane.container = c

            -- (1) WHICH KIND OF FILTER THIS IS. Built-in and custom differ in what
            -- you may do to them and in SCOPE -- preset overrides are per PROFILE,
            -- custom filters are per ACCOUNT -- so the caption is not decoration.
            local eyebrow = c:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            eyebrow:SetPoint("TOPLEFT", 0, -PANE.yEyebrow)
            eyebrow:SetJustifyH("LEFT")
            eyebrow:SetTextColor(0.48, 0.48, 0.52)

            -- (2) THE NAME, AND WHAT IT TRACKS.
            local title = c:CreateFontString(nil, "OVERLAY", "DFFontNormal")
            title:SetPoint("TOPLEFT", 0, -PANE.yTitle)
            title:SetJustifyH("LEFT")
            title:SetWordWrap(false)

            local countText = c:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            countText:SetPoint("TOPRIGHT", 0, -(PANE.yTitle + 3))
            countText:SetJustifyH("RIGHT")
            countText:SetWordWrap(false)
            countText:SetTextColor(0.5, 0.5, 0.5)

            -- Custom filter names are free text, so the name needs a stop: the count
            -- sits at the pane's right edge and a long name would run straight under
            -- it. Re-taken per paint, because the count's own width changes with the
            -- filter. Width 0 = auto-size, and it has to go back to auto before
            -- measuring or a short name would keep the cap's width.
            local function ClampPaneTitle()
                title:SetWidth(0)
                local avail = paneW - 6 - mceil(countText:GetStringWidth())
                if title:GetStringWidth() > avail then
                    title:SetWidth(mmax(40, avail))
                end
            end

            -- (3) WHO IS USING IT. The dot carries the state so the text can stay
            -- plain, exactly as the island's status line does.
            -- ⚠ BOTH POINTS AT THE SAME y. The island anchors its status text LEFT
            -- off the dot and RIGHT off a SHORT panel, which is only harmless because
            -- that panel is a header's height; this container is 414 tall, so a RIGHT
            -- anchor taken from its vertical middle would drop the line 180px.
            local usedDot = c:CreateTexture(nil, "OVERLAY")
            usedDot:SetSize(8, 8)
            usedDot:SetPoint("TOPLEFT", 1, -(PANE.yStatus + 4))
            usedDot:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\dot")

            local usedText = c:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            usedText:SetPoint("TOPLEFT", 15, -PANE.yStatus)
            usedText:SetPoint("TOPRIGHT", 0, -PANE.yStatus)
            usedText:SetJustifyH("LEFT")
            usedText:SetWordWrap(false)
            -- ⚠ Set the colour explicitly: DFFontNormalSmall inherits WoW's GOLD font
            -- object, so a line with no SetTextColor is not neutral.
            usedText:SetTextColor(GUI.Colors.text.r, GUI.Colors.text.g, GUI.Colors.text.b)

            -- A FontString takes no mouse input, so the tooltip needs a frame over
            -- its rect -- the same reason GUI:AttachTooltip builds one per label.
            local usedHit = CreateFrame("Frame", nil, c)
            usedHit:SetPoint("TOPLEFT", usedText, "TOPLEFT", 0, 2)
            usedHit:SetPoint("BOTTOMRIGHT", usedText, "BOTTOMRIGHT", 0, -2)
            usedHit:EnableMouse(true)
            usedHit:SetScript("OnEnter", function(s)
                if s.tooltipText then
                    GUI:ShowTooltip(s, { title = s.tooltipText, lines = s.tooltipLines })
                end
            end)
            usedHit:SetScript("OnLeave", function() GUI:HideTooltip() end)

            -- (4) SEARCH, per filter. Cleared when the row starts showing a
            -- different one -- see Paint.
            local searchBoxP = GUI:CreateEditBox(c, "", nil, nil, nil, paneW, L["Search..."])
            searchBoxP:SetPoint("TOPLEFT", 0, -(PANE.ySearch - PANE.ebDrop))
            searchBoxP:SetPoint("TOPRIGHT", 0, -(PANE.ySearch - PANE.ebDrop))
            GUI:AddEditBoxIcon(searchBoxP.EditBox, "Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")

            -- The add-by-ID echo. It is the ONLY feedback typing an id gives, which
            -- is why it takes a line of its own rather than sharing row (5) and being
            -- squeezed to nothing at this width.
            local echoText = c:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            echoText:SetPoint("TOPLEFT", 0, -PANE.yEcho)
            echoText:SetPoint("TOPRIGHT", 0, -PANE.yEcho)
            echoText:SetJustifyH("LEFT")
            echoText:SetWordWrap(false)
            echoText:SetTextColor(0.6, 0.6, 0.6)
            echoText:Hide()

            -- Generation counter so a re-add while a message is visible restarts the
            -- 4s window instead of the old timer hiding the new message early.
            local echoGen = 0
            local function HidePaneEcho()
                echoGen = echoGen + 1
                echoText:Hide()
            end
            local function PaneEcho(msg)
                echoGen = echoGen + 1
                local gen = echoGen
                echoText:SetText(msg)
                echoText:Show()
                C_Timer.After(4, function()
                    if echoGen == gen then echoText:Hide() end
                end)
            end

            -- (5) ADD BY SPELL ID.
            local addBoxP = GUI:CreateEditBox(c, "", nil, nil, nil, 90, L["Spell ID"])
            addBoxP:SetPoint("TOPLEFT", 0, -(PANE.yAdd - PANE.ebDrop))

            local function DoPaneAdd()
                local kind, key = slot.kind, slot.key
                if kind ~= "custom" or not R:GetCustomFilter(key) then return end
                local text = Trim(addBoxP.EditBox:GetText())
                if text == "" then return end
                -- Integers only: tonumber() also accepts floats/hex, which are never
                -- valid spell ids.
                if not text:match("^%d+$") then
                    PaneEcho(L["Enter a valid spell ID."])
                    return
                end
                text = text:match("^0*(%d+)$") or text
                if #text > 10 then
                    PaneEcho(L["Enter a valid spell ID."])
                    return
                end
                local idNum = tonumber(text)
                -- ☠ CAP ON VALUE, NOT DIGIT COUNT -- 2147483647 is itself ten digits,
                -- so the length check above is not the guard it looks like.
                if not idNum or idNum < 1 or idNum > R.MAX_SPELL_ID then
                    PaneEcho(L["Enter a valid spell ID."])
                    return
                end
                local result = R:AddSpellToCustom(key, idNum)
                if result == "spell" then
                    local rec = R.ByID[idNum]
                    PaneEcho(format(L["Added %s."], (R:GetSpellDisplay(rec))))
                elseif result == "raw" then
                    PaneEcho(format(L["Added #%d as an unknown spell ID — name and icon will show if the ID is valid."], idNum))
                elseif result == "exists" then
                    PaneEcho(L["Already in this filter."])
                    return
                else
                    return
                end
                addBoxP.EditBox:SetText("")
                DirectFilterChangedProxy()
                RefreshAll()
            end

            local addBtnP = GUI:CreateButton(c, L["Add"], 50, 22, function(self)
                if self.dfDisabled then return end
                DoPaneAdd()
            end)
            addBtnP:SetPoint("LEFT", addBoxP.EditBox, "RIGHT", 6, 0)
            -- Enter in the box adds too (the helper's own OnEnterPressed only saves
            -- db-backed values -- this box has no db binding).
            addBoxP.EditBox:HookScript("OnEnterPressed", DoPaneAdd)

            -- (6) ADD FROM THE DATABASE. A row of its own at this width -- the three
            -- fixed children of a single add row need 304px against a 260px pane.
            local dbBtnP = GUI:CreateButton(c, L["Add from Database"], paneW, 22, function(self)
                if self.dfDisabled then return end
                if slot.kind ~= "custom" or not R:GetCustomFilter(slot.key) then return end
                OpenPicker(slot.key)
            end)
            -- One anchor and the width it was built with, the way the consumer
            -- panel sized its own full-width buttons: StyleButton lays a button
            -- out from the size it was GIVEN, so a second anchor would be a
            -- width written twice and only one of them re-read.
            dbBtnP:SetPoint("TOPLEFT", 0, -PANE.yDB)

            HookDisabledTooltip(addBtnP, L["Built-in filters are curated"], L["You can enable or disable the spells shown, but not add new ones. Create a custom filter to add your own."])
            HookDisabledTooltip(dbBtnP, L["Built-in filters are curated"], L["You can enable or disable the spells shown, but not add new ones. Create a custom filter to add your own."])

            -- ---- THE SPELL LIST ----
            local listBg = CreateFrame("Frame", nil, c, "BackdropTemplate")
            listBg:SetPoint("TOPLEFT", 0, -(PANE.headH + PANE.gap))
            listBg:SetPoint("TOPRIGHT", 0, -(PANE.headH + PANE.gap))
            listBg:SetHeight(PANE.listH)
            GUI:CreatePanelBackdrop(listBg, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })

            local listScroll = CreateFrame("ScrollFrame", nil, listBg, "ScrollFrameTemplate")
            listScroll:SetPoint("TOPLEFT", 4, -4)
            listScroll:SetPoint("BOTTOMRIGHT", -24, 4)
            DF.GUI.StyleScrollBar(listScroll)

            local listContent = CreateFrame("Frame", nil, listScroll)
            listContent:SetSize(paneW - 28, 1)
            listScroll:SetScrollChild(listContent)
            listScroll:SetScript("OnSizeChanged", function(_, w)
                if w and w > 0 then listContent:SetWidth(w) end
            end)
            pane.content = listContent
            pane.scroll = listScroll

            local emptyTextP = listBg:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
            emptyTextP:SetPoint("CENTER", listBg, "CENTER", 0, 0)

            -- ---- THE PER-FILTER ACTIONS ----
            -- ☠ PER FILTER, NOT PER SELECTION. The island's strip acts on "the
            -- selection"; with a row per filter there is no selection, so Duplicate /
            -- Rename / Export / Delete and Reset belong to the filter whose panel
            -- they are in. Each takes its own corner rather than chaining off a
            -- neighbour, so Reset hiding leaves the other four exactly where they are.
            local actRuleP = c:CreateTexture(nil, "ARTWORK")
            actRuleP:SetHeight(1)
            actRuleP:SetColorTexture(0.22, 0.22, 0.22, 1)
            actRuleP:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, PANE.actH)
            actRuleP:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, PANE.actH)

            local actW = mfloor((paneW - 4) / 2)

            -- The display name of whatever this pane is currently showing. A preset's
            -- `name` is a LOCALE KEY and a custom's is user text, which is the one
            -- difference every caller of this has to get right.
            local function PaneDisplayName()
                if slot.kind == "preset" then
                    for _, cat in ipairs(R.Categories) do
                        if cat.key == slot.key then return L[cat.name] end
                    end
                    return tostring(slot.key or "")
                end
                local f = R:GetCustomFilter(slot.key)
                return f and (f.name or tostring(slot.key)) or ""
            end

            local dupBtnP = GUI:CreateButton(c, L["Duplicate"], actW, 20, function(self)
                if self.dfDisabled or not slot.key then return end
                local src = slot.key   -- capture: the list may re-bind before the prompt closes
                PromptFilterName(L["Name the duplicated filter:"], PaneDisplayName() .. " copy", L["Duplicate"], function(text)
                    text = Trim(text)
                    if text == "" then return end
                    local newId = R:DuplicateFilter(src, text)
                    SelectFilter("custom", newId)
                    if FocusFilterPanel then FocusFilterPanel("custom", newId) end
                end)
            end)

            local renameBtnP = GUI:CreateButton(c, L["Rename"], actW, 20, function(self)
                if self.dfDisabled then return end
                local id = slot.key
                local f = R:GetCustomFilter(id)
                if not f then return end
                PromptFilterName(L["Rename filter:"], f.name or "", L["Rename"], function(text)
                    text = Trim(text)
                    if text == "" then return end
                    R:RenameCustomFilter(id, text)
                    RefreshAll()
                end)
            end)

            -- Export flattens a preset to its currently-enabled spells, so it works on
            -- presets as well as customs -- unlike Rename and Delete, which need a
            -- store entry.
            local exportBtnP = GUI:CreateButton(c, L["Export"], actW, 20, function(self)
                if self.dfDisabled or not slot.key then return end
                local str, err = R:ExportFilter(slot.key, PaneDisplayName())
                if not str then
                    ShowFilterStringError(L["Export Failed"], err)
                    return
                end
                DF:ShowPopupInput({
                    title       = L["Export Filter"],
                    message     = (slot.kind == "preset")
                        and L["Copy this string to share this filter. It will import as a custom filter."]
                        or L["Copy this string to share this filter:"],
                    text        = str,
                    multiline   = true,
                    readOnly    = true,
                    cancelLabel = L["Done"],
                })
            end)

            local delBtnP = GUI:CreateButton(c, L["Delete"], actW, 20, function(self)
                if self.dfDisabled then return end
                local id = slot.key
                local f = R:GetCustomFilter(id)
                if not f then return end
                ConfirmDeleteFilter(f.name or tostring(id), function()
                    -- ☠ THE PANEL GOES WITH THE FILTER. Rows are POOLED and re-bound
                    -- on every list change, so a panel left standing over a deleted
                    -- filter silently becomes the NEXT filter's -- you delete one
                    -- thing and are left editing another, wearing the same panel.
                    local r = slot.row
                    if r and r.ClosePopout then r:ClosePopout("deleted") end
                    R:DeleteCustomFilter(id)
                    ScrubDeletedFilter(id)
                    if selKind == "custom" and selKey == id then
                        selKind = "preset"
                        selKey = R.Categories[1] and R.Categories[1].key
                    end
                    DirectFilterChangedProxy()
                    RefreshAll()
                end)
            end)

            -- Red danger tone, matching the Reset Page button. Only shown while the
            -- preset differs from its shipped defaults.
            local resetBtnP = CreateFrame("Button", nil, c, "BackdropTemplate")
            GUI:StyleButton(resetBtnP, {
                tone = "danger",
                icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh", size = 14 },
                text = L["Reset"],
            })
            resetBtnP:SetSize(actW, 20)
            resetBtnP:SetScript("OnClick", function()
                if slot.kind ~= "preset" or not slot.key then return end
                R:ResetPreset(slot.key)
                DirectFilterChangedProxy()
                RefreshAll()
            end)
            resetBtnP:HookScript("OnEnter", function(self)
                GUI:ShowTooltip(self, {
                    title = format(L["Reset: %s"], PaneDisplayName()),
                    lines = {
                        L["Restore this filter's spell list to its defaults. Other filters are not affected."],
                    },
                })
            end)
            resetBtnP:HookScript("OnLeave", function() GUI:HideTooltip() end)
            resetBtnP:Hide()

            HookDisabledTooltip(renameBtnP, L["Built-in filters are curated"], L["Built-in filters can't be renamed or deleted."])
            HookDisabledTooltip(delBtnP, L["Built-in filters are curated"], L["Built-in filters can't be renamed or deleted."])

            dupBtnP:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 48)
            renameBtnP:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 48)
            exportBtnP:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 24)
            delBtnP:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 24)
            resetBtnP:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 0)

            -- ☠ RE-THEMED BY THE PANE, NOT BY THE PAGE. StyleButton registers its
            -- theme listener on the button's PARENT, and the page's theme walk only
            -- visits pageRef.child -- a pane's parent is a popout holder, which is on
            -- no walk at all. Painted here, so a theme change (which runs RefreshAll,
            -- which repaints every pane the user can see) reaches them.
            local paneButtons = { addBtnP, dbBtnP, dupBtnP, renameBtnP, exportBtnP, delBtnP, resetBtnP }

            -- ☠ THE REPAINT VERB. A pane is built once and the row it belongs to is
            -- re-bound whenever the filter list changes, so everything below is read
            -- HERE rather than captured above. This is the `refreshContent` pattern
            -- the consumer chips already used, one container larger.
            local function Paint()
                local kind, key = slot.kind, slot.key
                if not (kind and key) then
                    c:Hide()
                    return
                end
                c:Show()

                -- (4) is per filter and clears when a different one arrives in this
                -- slot -- a search typed against Healing has no meaning over Defensives.
                local ident = kind .. "|" .. tostring(key)
                if pane.boundIdent ~= ident then
                    pane.boundIdent = ident
                    pane.query = ""
                    if searchBoxP.EditBox:GetText() ~= "" then
                        searchBoxP.EditBox:SetText("")
                    end
                    HidePaneEcho()
                end

                local isPreset = (kind == "preset")
                local tc = GUI.GetThemeColor()
                title:SetTextColor(tc.r, tc.g, tc.b)

                if isPreset then
                    local catName
                    for _, cat in ipairs(R.Categories) do
                        if cat.key == key then
                            catName = L[cat.name]
                            break
                        end
                    end
                    eyebrow:SetText(L["Editing built-in filter"])
                    title:SetText(catName or tostring(key))
                    local enabled, total = R:PresetCounts(key)
                    countText:SetText(format(L["%d of %d tracked"], enabled, total))
                else
                    local f = R:GetCustomFilter(key)
                    eyebrow:SetText(L["Editing custom filter"])
                    title:SetText(f and (f.name or tostring(key)) or "")
                    countText:SetText(f and CustomCountText(key) or format(L["%d spells"], 0))
                end
                ClampPaneTitle()

                -- (3) WHO IS USING IT, live from the db. Editing a filter changes it
                -- everywhere it is used, and that is exactly what someone about to
                -- edit a shared filter needs to know before they touch anything.
                local places = {}
                for _, consumer in ipairs(FilterConsumers(kind, key)) do
                    places[#places + 1] = UsageLabel(consumer)
                end
                if #places > 0 then
                    usedDot:SetVertexColor(0.3, 0.8, 0.45)
                    usedText:SetText(format(L["Used by: %s"], table.concat(places, ", ")))
                else
                    -- "Not used yet" rather than "off": nothing on THIS page turned it
                    -- off, so an off-state would describe a switch the reader cannot see.
                    local w = GUI.Colors.warning
                    usedDot:SetVertexColor(w.r, w.g, w.b)
                    usedText:SetText(L["Not used yet — pick it on a page that shows auras"])
                end
                usedHit.tooltipText = L["Where this applies"]
                usedHit.tooltipLines = {
                    L["Each display picks its own filters on its own page — the Buff Bar, the Defensive Icon, and Aura Designer groups. This line lists the ones using it now, across both Party and Raid."],
                    isPreset
                        and L["Which filters a display uses is per mode, so Party and Raid keep separate choices. What a filter CONTAINS is not per mode: editing its spells changes both."]
                        or  L["Which filters a display uses is per mode, so Party and Raid keep separate choices. A custom filter's spells are shared by every profile on the account."],
                }

                -- (5) and (6) GREYED, NEVER ABSENT, on a built-in filter.
                local isCustom = (not isPreset) and R:GetCustomFilter(key) ~= nil
                addBoxP:SetEnabled(isCustom)
                addBtnP:SetDisabled(not isCustom)
                dbBtnP:SetDisabled(not isCustom)

                dupBtnP:SetDisabled(false)
                exportBtnP:SetDisabled(false)
                renameBtnP:SetDisabled(not isCustom)
                delBtnP:SetDisabled(not isCustom)
                resetBtnP:SetShown((isPreset and R:IsPresetModified(key)) or false)

                -- ---- the list ----
                local groups = PaneItems(pane, kind, key, pane.query)
                local y = 4
                local usedHeaders, usedRows, shown = 0, 0, 0
                local function RenderGroup(token)
                    local g = groups[token]
                    if not g or #g == 0 then return end
                    usedHeaders = usedHeaders + 1
                    local hdr = AcquirePaneClassHeader(pane, usedHeaders)
                    hdr:ClearAllPoints()
                    hdr:SetPoint("TOPLEFT", 6, -(y + 6))
                    hdr:SetText(ClassDisplayName(token))
                    local cc = token ~= "ALL" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
                    if cc then
                        hdr:SetTextColor(cc.r, cc.g, cc.b)
                    else
                        hdr:SetTextColor(0.65, 0.65, 0.65)
                    end
                    y = y + CLASS_HEADER_H
                    for _, item in ipairs(g) do
                        usedRows = usedRows + 1
                        shown = shown + 1
                        local srow = AcquirePaneSpellRow(pane, usedRows)
                        BindPaneSpellRow(pane, srow, y, item, isPreset, key)
                        y = y + SPELL_ROW_H
                    end
                    y = y + 4
                end
                for _, token in ipairs(CLASS_ORDER) do
                    RenderGroup(token)
                end
                RenderGroup("ALL")

                for j = usedHeaders + 1, #pane.classHeaders do
                    pane.classHeaders[j]:Hide()
                end
                for j = usedRows + 1, #pane.spellRows do
                    pane.spellRows[j]:Hide()
                end

                emptyTextP:SetShown(shown == 0)
                emptyTextP:SetText(pane.query ~= "" and L["No results found"] or L["This filter is empty."])
                listContent:SetHeight(mmax(1, y + 4))

                for _, b in ipairs(paneButtons) do
                    if b and b.UpdateTheme then b.UpdateTheme() end
                end
            end
            pane.Paint = Paint

            searchBoxP.EditBox:HookScript("OnTextChanged", function(eb)
                local q = (eb:GetText() or ""):lower()
                if q == pane.query then return end
                pane.query = q
                Paint()
            end)

            -- ☠ THE GROUP RE-ASKS THIS ON EVERY RE-FLOW, which is what paints the
            -- pane the first time its panel opens -- the mount ends in ReflowPane,
            -- and RefreshChildStates calls `refreshContent` on every child it holds.
            -- The spell rows for this pane are created by that first call.
            c.refreshContent = function() Paint() end

            group:AddWidget(c, PANE.paneH)
            return pane
        end

        -- ============================================================
        -- THE ROW POOL
        -- ------------------------------------------------------------
        -- ☠ CREATED ON DEMAND AND NEVER DESTROYED, exactly as the island's list rows
        -- are: WoW frees no frame, and a filter can be created at any point in the
        -- session. Row i is a SLOT, not a filter -- the list re-sorts when a custom
        -- filter is added or renamed, so slot 4 is a different filter afterwards and
        -- everything behind it has to read its binding rather than remember one.
        -- ============================================================
        local filterRows = {}
        local filterBand = GUI:CreateSettingsGroup(parent, tools.BandWidth(), { chromeless = true })

        local function AcquireFilterRow(i)
            local row = filterRows[i]
            if row then return row end

            -- ⚠ THE SLOT EXISTS BEFORE THE ROW DOES, and it has to. PopoutContent
            -- runs its builder EAGERLY, inside this very call, so at the moment the
            -- pane is built there is no row to hand it -- CreatePopoutRow has not
            -- been called yet. The slot is the shared cell both ends read.
            local slot = {}
            local panes = {}
            local mount = tools.PopoutContent(function(group, holder)
                panes[#panes + 1] = BuildFilterPane(group, holder, slot)
            end)

            row = GUI:CreatePopoutRow(parent, {
                label   = "",
                db      = tools.RowDB,
                -- ☠ AND IT IS PAINTED, WHICH TOOK A KIT OPT-IN. A strip row's corner
                -- is blanked while the row is on, because on every other page that
                -- corner held a VALUE READOUT the controls beneath already said
                -- better. This page is a LIST, and the corner is the only thing that
                -- makes the list readable without opening all seventeen rows -- so
                -- `keepSummary` below asks for the exception rather than the rule.
                --
                -- Count first, then who uses it: the count is the one fact that
                -- differs between two rows with the same consumers, and it is what
                -- the eye is scanning a list of filters FOR.
                summary = function()
                    if not (slot.kind and slot.key) then return "" end
                    local places = {}
                    for _, consumer in ipairs(FilterConsumers(slot.kind, slot.key)) do
                        places[#places + 1] = UsageLabel(consumer)
                    end
                    local used = (#places == 0) and L["Not in use"]
                                 or table.concat(places, ", ")
                    -- The two kinds count differently and always have: a preset
                    -- tracks a SUBSET of a shipped catalogue, a custom filter holds
                    -- exactly what was put in it. Both verbs and both strings are the
                    -- ones the panel header uses, so the corner and the header can
                    -- never disagree about the same filter.
                    local counted
                    if slot.kind == "preset" then
                        local enabled, total = R:PresetCounts(slot.key)
                        counted = format(L["%d of %d tracked"], enabled or 0, total or 0)
                    else
                        local f = R:GetCustomFilter(slot.key)
                        counted = f and CustomCountText(slot.key) or format(L["%d spells"], 0)
                    end
                    return format("%s \226\128\148 %s", counted, used)
                end,
                window  = DF.GUIFrame,
                clipTo  = pageRef,
                build   = mount,
                -- ☠ COMPACT, NOT A STRIP ROW. Seventeen filters at the strip row's
                -- 48+10 is 986px of scrolling for a list whose every row is one line
                -- of text -- "miles long of scrolling to get through the filters".
                -- A compact row is that one line, and the whole row opens it: the
                -- strip exists because a plate carrying sliders cannot be clicked
                -- anywhere, and this plate carries nothing.
                compact = true,
            })
            -- ⚠ NO ClaimKeys, NO WireModifiedTick AND NO WireFooter. This page owns
            -- no per-mode db keys at all -- CreateCopyButton is called with an empty
            -- list for exactly that reason -- and what a pane edits is a per-ACCOUNT
            -- custom-filter store and a per-PROFILE override diff. There is no key
            -- for a modified tick to test and nothing a Reset Group could write.
            slot.row = row
            row.dfSlot = slot

            -- Every pane this row has ever been given content for, not just the
            -- eager one: pinning a panel and clicking the row again asks the factory
            -- for a SECOND instance, and both are bound to this same slot.
            -- ⚠ ONLY THE ONES ON SCREEN. A closed pane lives in a hidden holder, and
            -- repainting seventeen of those on every write would be the cost the
            -- lazy build exists to avoid; it paints on the way in instead, through
            -- refreshContent.
            row.dfRepaintPanes = function()
                for _, p in ipairs(panes) do
                    if p.container:IsVisible() then p.Paint() end
                end
            end

            filterRows[i] = row
            filterBand:AddWidget(row)
            return row
        end

        -- Find the row now showing (kind, key) and open its panel.
        -- ⚠ READ AFTER THE LIST HAS BEEN RE-BOUND, never before: the rows are
        -- POOLED, so the row holding a filter moves the moment one is created,
        -- renamed or deleted.
        FocusFilterPanel = function(kind, key)
            if not (kind and key) then return false end
            for _, row in ipairs(filterRows) do
                local slot = row.dfSlot
                if slot and not row.dfSurplus and slot.kind == kind and slot.key == key then
                    if row.OpenPopout then row:OpenPopout() end
                    if DF.HighlightWidget then DF:HighlightWidget(row) end
                    return true
                end
            end
            -- A filter that is referenced but has no row is a deleted one whose
            -- reference outlived it. Say so rather than pulsing nothing.
            DF:DebugWarn("GUI", "Filter Designer: no row for %s filter '%s'", tostring(kind), tostring(key))
            return false
        end

        -- ☠ NO Add() HERE, AND THAT IS THE WHOLE REASON THE BAND IS A GROUP. Add
        -- only ever arrives inside a build; this runs from RefreshAll, which has
        -- none. A settings group re-lays its own children on every RefreshStates and
        -- reports calculatedHeight, so a row acquired on the fortieth filter is
        -- picked up by the page's ordinary layout pass.
        RefreshFilterRows = function()
            local list = R:ListFilters()
            -- ☠ TWO SEGMENTS, NOT ONE RUN. The band holds a header, the built-in
            -- rows, a second header and then the custom rows -- and the headers are
            -- children at FIXED positions, so a row's index decides which side of
            -- the second header it is drawn on. Binding straight down `list` would
            -- work only for as long as it hands back every preset every time; the
            -- day it hands back fewer, a custom would take a low index and appear
            -- above the "Custom" header describing it.
            --
            -- So presets fill 1..nPreset in the order they arrive and customs start
            -- at nPreset + 1 regardless, which is true by construction rather than
            -- by trusting the order of somebody else's list.
            local nPreset = #R.Categories
            local pi, ci = 0, 0
            for _, entry in ipairs(list) do
                local i
                if entry.custom then
                    ci = ci + 1
                    i = nPreset + ci
                else
                    pi = pi + 1
                    i = pi
                end
                local row = AcquireFilterRow(i)
                local slot = row.dfSlot
                slot.kind, slot.key = entry.kind, entry.key
                -- ☠ A PRESET'S `name` IS A LOCALE KEY AND A CUSTOM'S IS USER TEXT.
                -- R:ListFilters hands both back in the same field and marks which is
                -- which; running a user-typed name through L[] returns it unchanged
                -- today and would start answering a translator's string the day one
                -- collides.
                local name = entry.custom and entry.name or L[entry.name]
                -- ☠ AND A CUSTOM FILTER SAYS SO ON ITS ROW. Fifteen built-ins and
                -- your own sit in one list with nothing telling them apart -- the
                -- kind is in the PANEL's eyebrow, which is behind a click, and the
                -- count pill that could have carried a marker is gone from a compact
                -- row by design. The name is the only thing on the plate that is
                -- ours to write, so the tag goes after it.
                --
                -- The accent, not the dim grey this file uses for a count: these are
                -- the filters the user MADE, and in a list that is otherwise
                -- shipped-with-the-addon that is the one distinction worth seeing
                -- from across the page. Built from GUI.Colors so it follows the
                -- theme rather than pinning a second copy of the accent.
                --
                -- ⚠ THE TAG IS ON THE LABEL ONLY, never on `_title`. The title is
                -- what the open panel puts at its head, and a colour escape in it
                -- would be read as text by anything that measures or compares it.
                local display = name
                if entry.custom then
                    local a = GUI.Colors.accent
                    display = format("%s  |cff%02x%02x%02x%s|r", name,
                                     a.r * 255, a.g * 255, a.b * 255, L["Custom"])
                end
                row._label = display
                row._title = name
                -- The kit writes the plate's label once, at build, from row._label --
                -- so a row that changes which filter it is showing has to repaint it.
                if row.label then row.label:SetText(display) end
                row.dfSurplus = nil
                filterBand:SetChildHidden(row, false)
                if row.Refresh then row.Refresh() end
                row.dfRepaintPanes()
            end
            -- Surplus rows are HIDDEN through the group rather than by hand: the
            -- group's own layout pass is what announces the hide, and a popout row
            -- answers that announcement by closing any loose panel docked to it.
            -- ⚠ AND THE GAP BETWEEN THE SEGMENTS IS SURPLUS TOO. With two segments
            -- the unused rows are not one tail: they are whatever is left of the
            -- preset block plus whatever is left of the custom block.
            for i = pi + 1, nPreset do
                local row = filterRows[i]
                if row then
                    row.dfSurplus = true
                    filterBand:SetChildHidden(row, true)
                end
            end
            for i = nPreset + ci + 1, #filterRows do
                local row = filterRows[i]
                if row then
                    row.dfSurplus = true
                    filterBand:SetChildHidden(row, true)
                end
            end
            -- A heading over nothing is worse than no heading: with no custom
            -- filters yet, the word "Custom" sitting alone at the foot of the list
            -- reads as something failing to load.
            if filterBand.dfCustomHeader then
                filterBand:SetChildHidden(filterBand.dfCustomHeader, ci == 0)
            end
            if pageRef.RefreshStates then pageRef:RefreshStates() end
        end

        -- ============================================================
        -- THE TWO HEADINGS
        -- ------------------------------------------------------------
        -- ☠ THE SPLIT IS STRUCTURAL, NOT PER-ROW. Every filter carries a tag saying
        -- which kind it is, and seventeen tags down a list is seventeen things to
        -- read. The user's own filters already sort to the bottom, so a heading over
        -- each block says the same thing once.
        --
        -- ⚠ BUILT HERE, IN ORDER, AND THE PRESET ROWS WITH THEM. A settings group
        -- lays its children out in the order they were ADDED, and AcquireFilterRow
        -- appends on first use -- so the second heading only lands between the two
        -- blocks if every preset row already exists when it is added. They are a
        -- fixed set (R.Categories), so this is a loop and not a guess, and it costs
        -- nothing extra: all of them are bound on the first refresh anyway.
        --
        -- The two labels are the island's own, so the two layouts name the same
        -- thing the same way and no new string reaches a translator.
        do
            -- ⚠ 40, STATED, because CreateHeader declares no height of its own --
            -- ResolveRowHeight would fall back to its 55 and the two headings would
            -- tower over a list of 30px rows. Every other page in the addon passes
            -- this same 40.
            local HEADER_H = 40
            filterBand:AddWidget(GUI:CreateHeader(parent, L["Built-In Filters"]), HEADER_H)
            for i = 1, #R.Categories do AcquireFilterRow(i) end
            filterBand.dfCustomHeader = GUI:CreateHeader(parent, L["Custom Buff Filters"])
            filterBand:AddWidget(filterBand.dfCustomHeader, HEADER_H)
        end

        -- ============================================================
        -- THE ACTION BAND
        -- ------------------------------------------------------------
        -- ☠ NEW AND IMPORT HAVE NO FILTER TO BELONG TO. Every other verb on this
        -- page acts on ONE filter and now lives in that filter's own panel; these two
        -- CREATE one, so they sit above the list they create into -- the same
        -- argument that kept them out of the island's bottom strip, where they would
        -- have read as "import into the selected filter".
        --
        -- ⚠ AND "HOW THIS WORKS" COMES WITH THEM. In the island it is a glyph on the
        -- chip row, and the chip row is taken down at the foot of this arm -- without
        -- a home here the band layout would simply lose the popup.
        -- ============================================================
        -- ============================================================
        -- USED BY -- THREE CONSUMERS, ON THE PAGE
        -- ------------------------------------------------------------
        -- ☠ ROWS, NOT CHIPS, AND THAT IS THE WHOLE REASON IT CAN BE ON THE PAGE.
        -- The island puts these three side by side, and at 640 each chip gets
        -- ~123px against a label like "Defensive Icon  2 filters" that needs half
        -- as much again -- so they ellipsise at every width this window can be.
        -- That truncation is what sent them into a popout in the first place; it
        -- is a fact about three things sharing one line, not about the page. One
        -- full-width row each, at band width, has room for the longest of them
        -- and costs the same vertical space the wrapped chips did.
        do
            local ROW_H, ROW_GAP = 22, 4
            USEDBY.h = PANE.actionLabelH + CHIP_POOL_N * ROW_H
                       + (CHIP_POOL_N - 1) * ROW_GAP
            USEDBY.band = CreateFrame("Frame", nil, parent)
            USEDBY.band:SetSize(tools.BandWidth(), USEDBY.h)

            local caption = USEDBY.band:CreateFontString(nil, "OVERLAY", "DFFontNormal")
            caption:SetPoint("TOPLEFT", 0, 0)
            caption:SetJustifyH("LEFT")
            caption:SetText(L["Used By"])

            USEDBY.rows = {}
            for i, def in ipairs(CHIP_DEFS_BUFF) do
                local b = CreateFrame("Button", nil, USEDBY.band, "BackdropTemplate")
                GUI:StyleButton(b, { height = ROW_H, text = " " })
                b:SetPoint("TOPLEFT", 0, -(PANE.actionLabelH + (i - 1) * (ROW_H + ROW_GAP)))
                b:SetPoint("TOPRIGHT", 0, -(PANE.actionLabelH + (i - 1) * (ROW_H + ROW_GAP)))
                b:SetHeight(ROW_H)
                -- ⚠ The styler's own label is centred, which is the one thing a row
                -- must not be: the name reads from the left and the count from the
                -- right, or three rows of different lengths look like three
                -- different columns. Blanked above and replaced with two.
                if b.text then b.text:Hide() end
                b.dfName = b:CreateFontString(nil, "OVERLAY", "DFFontNormal")
                b.dfName:SetPoint("LEFT", 8, 0)
                b.dfName:SetJustifyH("LEFT")
                b.dfName:SetText(def.label)
                b.dfDetail = b:CreateFontString(nil, "OVERLAY", "DFFontNormal")
                b.dfDetail:SetPoint("RIGHT", -8, 0)
                b.dfDetail:SetJustifyH("RIGHT")
                b.tooltip = { title = def.label, lines = { def.tip } }
                -- The chips' own destination, read from the same def table, so the
                -- two layouts cannot send the same button to two different pages.
                b:SetScript("OnClick", function() fdBannerLinkClick(def.pageId) end)
                bandButtons[#bandButtons + 1] = b
                USEDBY.rows[i] = b
            end

            function USEDBY.Refresh()
                for i, def in ipairs(CHIP_DEFS_BUFF) do
                    local b = USEDBY.rows[i]
                    if b then
                        local detail = ChipDetail(def.key)
                        b.dfDetail:SetText(detail)
                        -- Dimmed when it draws on nothing: on a page whose point is
                        -- "who is using this library", the answer "nobody" should
                        -- not read as loud as a real count.
                        local dim = (detail == L["Not in use"])
                        -- ☠ .r/.g/.b, NEVER unpack(). GUI.Colors entries are KEYED
                        -- tables, so unpack() on one returns NOTHING and SetTextColor()
                        -- is called with no arguments -- which throws, inside a build,
                        -- which is how the island and the bands ended up drawing over
                        -- each other with the previous page still behind them. The
                        -- builder died before the take-down at its foot ever ran.
                        local c = dim and GUI.Colors.textDim or GUI.Colors.text
                        b.dfName:SetTextColor(c.r, c.g, c.b)
                        b.dfDetail:SetTextColor(c.r, c.g, c.b)
                    end
                end
            end
            USEDBY.Refresh()
        end

        local ACTION_BAND_H = PANE.actionLabelH + PANE.actionBtnH
        local actionBand = CreateFrame("Frame", nil, parent)
        actionBand:SetSize(tools.BandWidth(), ACTION_BAND_H)

        -- In a do-block for the local-slot reason PANE gives: the label is set once
        -- and never read again, so the name it would hold is the name something else
        -- cannot have.
        do
            local filtersLabel = actionBand:CreateFontString(nil, "OVERLAY", "DFFontNormal")
            filtersLabel:SetPoint("TOPLEFT", 0, 0)
            filtersLabel:SetJustifyH("LEFT")
            filtersLabel:SetText(L["Filters"])
        end

        -- ☠ ONE VERB, TWO CALLERS, AND IT ENDS BY OPENING THE PANEL. The band's own
        -- button and the Aura Designer's "Create Filter" entry point both land here,
        -- and a filter created and then left shut is a page that did half of what was
        -- asked -- which is what the island's pulse-the-add-row cue was working
        -- around when the master was a list rather than a row each.
        NewFilterFlow = function()
            PromptFilterName(L["Name the new filter:"], "", L["Create"], function(text)
                text = Trim(text)
                if text == "" then return end
                local id = R:CreateCustomFilter(text)
                -- SelectFilter runs RefreshAll, which re-binds the rows -- so the row
                -- for this filter only exists after it.
                SelectFilter("custom", id)
                if FocusFilterPanel then FocusFilterPanel("custom", id) end
            end)
        end

        local newBtn = GUI:CreateButton(actionBand, L["+ New Buff Filter"], 140, PANE.actionBtnH, function()
            NewFilterFlow()
        end)
        newBtn:SetPoint("TOPLEFT", 0, -PANE.actionLabelH)

        -- ☠ THE ISLAND'S IMPORT ROW OWNS THIS FLOW, AND THIS DRIVES IT RATHER THAN
        -- CARRYING A SECOND COPY. Import is a five-branch popup chain -- decode,
        -- name-clash, content-match, import-as-copy, use-existing -- and two copies of
        -- it is two places for the clash rules to drift apart. The island's row is
        -- built and wired whatever the layout; only its ANCHOR is the island's.
        local importBtn = GUI:CreateButton(actionBand, L["+ Import Filter"], 140, PANE.actionBtnH, function()
            local fn = importRow:GetScript("OnClick")
            if fn then fn(importRow) end
        end)

        local helpBandBtn = CreateFrame("Button", nil, actionBand, "BackdropTemplate")
        -- ☠ ".png" IS PART OF THE PATH -- see the island's glyph for why.
        GUI:StyleButton(helpBandBtn, {
            width  = CHIP_H,
            height = PANE.actionBtnH,
            icon   = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\question.png", size = 13 },
        })
        helpBandBtn:SetPoint("TOPRIGHT", 0, -PANE.actionLabelH)
        helpBandBtn:SetScript("OnClick", ShowFilterHelp)
        helpBandBtn:HookScript("OnEnter", function(self)
            GUI:ShowTooltip(self, {
                title = L["How this works"],
                lines = { L["A short guide to filters and the displays that use them."] },
            })
        end)
        helpBandBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        importBtn:SetPoint("TOPRIGHT", helpBandBtn, "TOPLEFT", -6, 0)

        -- ⚠ SIZED FROM THE BAND, NOT GIVEN A NUMBER. Two fixed-width buttons anchored
        -- from opposite ends do not shrink, they overlap -- the Class-2 failure this
        -- page has already paid for twice (the action strip, header row 3).
        local function LayoutActionBand()
            local w = actionBand:GetWidth() or 0
            if w < 60 then return end
            local avail = w - CHIP_H - 6 - 6
            local bw = mmax(80, mfloor(avail / 2))
            newBtn:SetWidth(bw)
            importBtn:SetWidth(bw)
        end
        actionBand:SetScript("OnSizeChanged", LayoutActionBand)
        LayoutActionBand()

        -- Their parent is the action band rather than the page child, so the page's
        -- theme walk never reaches them -- the same rule the island states for its own
        -- standing buttons, which is why RefreshLeft re-themes this list.
        wipe(bandButtons)
        bandButtons[#bandButtons + 1] = newBtn
        bandButtons[#bandButtons + 1] = importBtn
        bandButtons[#bandButtons + 1] = helpBandBtn

        -- ============================================================
        -- THE PICKER HAS NOWHERE TO ANCHOR ANY MORE
        -- ------------------------------------------------------------
        -- ☠ The island points the spell-database overlay at the two panels' corners
        -- and both of them are taken down here. It covers the VIEWPORT instead --
        -- OpenSpellPicker spans its parent's whole rect when given no points, so
        -- naming contentFrame as the parent is the entire change. Instances are keyed
        -- by parent inside the picker, so this is a second one rather than the
        -- island's re-anchored.
        --
        -- ⚠ AND THE SELECTION MOVES WITH IT. RefreshAll closes the picker whenever the
        -- page's selection is not its target (see the guard there), and nothing in the
        -- band arm moves that selection -- so without this the picker shut itself the
        -- moment the first spell was added through it.
        -- ============================================================
        OpenPicker = function(cfId)
            pickerTarget = cfId
            selKind, selKey = "custom", cfId
            local pickerParent = GUI.contentFrame or parent
            pickerHandle = R:OpenSpellPicker({
                parent = pickerParent,
                -- Fires on ANY close (back/ESC/programmatic/ancestor hide): every open
                -- panel goes back to outlining its own row, restoring whatever the kit
                -- stashed on the way in. Same hook the Aura Designer's picker uses.
                onClose = function() GUI:ClearPopoutTetherOverride() end,
                title = L["Add from Database"],
                -- Re-evaluated per refresh, so a rename while the picker is up keeps
                -- the header current.
                subtitle = function()
                    local f = R:GetCustomFilter(pickerTarget)
                    return f and (f.name or tostring(pickerTarget)) or ""
                end,
                isValid = function()
                    return R:GetCustomFilter(pickerTarget) ~= nil
                end,
                isBlocked = function(rec)
                    local f = R:GetCustomFilter(pickerTarget)
                    return (f and f.spells[rec.id] ~= nil) and true or nil
                end,
                rowActions = {
                    {
                        handler = function(rec)
                            if R:AddSpellToCustom(pickerTarget, rec.id) then
                                DirectFilterChangedProxy()
                                RefreshAll()
                            end
                        end,
                    },
                },
            })
            -- ☠ THE PICKER COVERS THE SURFACE THE OPEN PANEL IS TETHERED TO. The
            -- "Add from Database" button lives in the custom filter's own panel, so
            -- that panel is open and outlining its row -- and the outline is drawn in
            -- the panel's strata, ABOVE the window, so it lands on whichever spell
            -- row sits in that slot and reads as "this spell is selected". Point every
            -- open panel at the covered surface instead, exactly as the Aura
            -- Designer's picker does. AFTER the open, so a picker that failed to open
            -- leaves nothing to restore. Undone by onClose above.
            GUI:SetPopoutTetherOverride(pickerParent)
        end

        -- The freshness note needs a host of its own: it is a FontString, and the
        -- layout pass hands out SetPoint and SetWidth to FRAMES.
        local freshHost
        if dbFreshLabel then
            freshHost = CreateFrame("Frame", nil, parent)
            freshHost:SetSize(tools.BandWidth(), BELOW_PANELS_H)
            dbFreshLabel:SetParent(freshHost)
            dbFreshLabel:ClearAllPoints()
            dbFreshLabel:SetPoint("TOPLEFT", freshHost, "TOPLEFT", 0, 0)
            dbFreshLabel:SetPoint("TOPRIGHT", freshHost, "TOPRIGHT", 0, 0)
            -- ⚠ AND ITS BAND IS MEASURED. BELOW_PANELS_H is the island's allowance
            -- for one line of this note under a fixed 270px panel; on a wider band the
            -- same sentence runs to three.
            -- ☠ THE FONTSTRING, NOT THE FRAME. GUI:CreateLabel returns a frame
            -- WRAPPING a string, so GetStringHeight on it is nil -- which is what
            -- opening this page threw. The frame's own height is no use either: it
            -- converges only inside a settings group and this label is anchored to
            -- leftPanel. The STRING wraps correctly at any width; measure that.
            freshHost:SetScript("OnSizeChanged", function(self)
                local fs = dbFreshLabel.fontString
                local h = mmax(((fs and fs:GetStringHeight()) or 0) + 6, BELOW_PANELS_H)
                -- Guarded: dfSetHeight re-runs the page's layout pass, which resizes
                -- this host, which re-enters here. Bailing when the number has not
                -- moved is what makes that terminate.
                if self.dfSetHeight and self._dfLastH ~= h then
                    self._dfLastH = h
                    self.dfSetHeight(h)
                end
            end)
        end

        -- Re-report a band's height in place: set layoutHeight, set the height,
        -- re-run the page's layout pass.
        --
        -- ☠ TWO NUMBERS, NOT ONE, AND THE SECOND IS WHY. The SLOT carries the gap to
        -- the next band; the FRAME is only as tall as what it draws. Collapsing them
        -- makes AdoptBands' `GetHeight() + BAND_GAP` read a height that already
        -- contains a gap, so every rebuild adds another one.
        local function BandHeight(host)
            return function(slotH, frameH)
                slotH  = mmax(tonumber(slotH) or 1, 1)
                frameH = mmax(tonumber(frameH) or slotH, 1)
                if host.layoutHeight == slotH and (host:GetHeight() or 0) == frameH then
                    return
                end
                host.layoutHeight = slotH
                host:SetHeight(frameH)
                if pageRef.RefreshStates then pageRef:RefreshStates() end
            end
        end
        -- ⚠ NO dfSetHeight ON THE CHIP ROW OR THE DETAIL. Neither is a band in this
        -- arm, and a re-report verb on a frame the layout pass never places would call
        -- the page's whole state pass for a height nothing reads.
        if freshHost then freshHost.dfSetHeight = BandHeight(freshHost) end

        -- ☠ THE ONE FLUSH SEAM IN THIS COLUMN, AND IT NEEDS A BAND OF ITS OWN. The
        -- other seams breathe because each band carries BAND_GAP in its SLOT, but the
        -- banner's slot is `banner.layoutHeight`, and that number is written by
        -- CreateInfoBanner's own deferred re-measure (RelayoutHost). Anything added to
        -- it there is discarded on the next re-wrap, so the gap goes in a band the
        -- banner does not own.
        --
        -- ⚠ BUILT ONCE, OUTSIDE AdoptBands. That function runs on EVERY build --
        -- DoBuild retires every Add()ed child and the rebuild guard calls it again --
        -- and frames cannot be garbage-collected in this client, so a frame created in
        -- there is one frame leaked per rebuild.
        local bannerGap = CreateFrame("Frame", nil, parent)
        bannerGap:SetSize(tools.BandWidth(), BAND_GAP)

        -- ☠ RUN ON EVERY BUILD, NOT ONCE. DoBuild retires every Add()ed child -- it
        -- hides them, clears their points and reparents them to the trash -- so the
        -- rebuild guard at the top of this function calls this again with the fresh
        -- Add it was handed. Add() is what puts them back.
        local function AdoptBands(addFn)
            addFn(banner, banner.layoutHeight, "both")
            addFn(bannerGap, BAND_GAP, "both")
            addFn(USEDBY.band, USEDBY.h + BAND_GAP, "both")
            addFn(actionBand, ACTION_BAND_H + BAND_GAP, "both")
            -- nil: a settings group carries its OWN height (calculatedHeight), which
            -- is the whole reason this list can grow and shrink without a rebuild --
            -- the layout pass re-reads it on every RefreshStates.
            addFn(filterBand, nil, "both")
            if freshHost then addFn(freshHost, BELOW_PANELS_H, "both") end
        end
        pageRef._fdAdoptBands = AdoptBands
        AdoptBands(Add)

        -- ============================================================
        -- THE ISLAND'S ROOTS COME DOWN
        -- ------------------------------------------------------------
        -- ☠ TAKEN DOWN, NOT MERELY UN-ANCHORED, AND ALL THREE OF THEM. The chip row is
        -- anchored to the banner, the master panel to the chip row and the detail to
        -- the master -- and the banner IS a band here, so a chain left standing would
        -- redraw the whole island over the column that replaced it. An anchor is
        -- geometry, not visibility: hiding a frame does not stop its neighbours being
        -- positioned from it.
        --
        -- ⚠ POINTS ONLY CLEARED ON THE BANNER, NEVER RE-SET. The layout pass
        -- ClearAllPoints()es every child it places and issues its own TOPLEFT and
        -- SetWidth, so a point written here is discarded on the next RefreshStates.
        -- ============================================================
        banner:ClearAllPoints()
        chipRow:ClearAllPoints()
        chipRow:Hide()
        leftPanel:ClearAllPoints()
        leftPanel:Hide()
        rightArea:ClearAllPoints()
        rightArea:Hide()

        -- ---- THE CROSS-PAGE ENTRY POINTS ----
        -- Published rather than captured, and read at CALL time by the three verbs
        -- ~1,400 lines above: they are created long before this arm runs, so an
        -- upvalue taken up there would freeze nil.
        pageRef._fdOpenFilterPanel = FocusFilterPanel
        pageRef._fdNewFilter = NewFilterFlow
        -- "Scroll to the filter band" is what OpenFilterList means here. The band is
        -- the third thing on the page, so what it actually needs is the cue rather
        -- than the scroll.
        pageRef._fdScrollToFilters = function()
            if DF.HighlightWidget then DF:HighlightWidget(actionBand) end
        end
    end

    -- ========== PAGE HEIGHT SPACER ==========
    -- The page's scroll height comes from RefreshStates summing Add()ed
    -- children; the ISLAND anchors its frames directly, so an invisible spacer
    -- carries the total height through the standard layout pass. The band arm
    -- above has no use for one: every band is an Add()ed child that carries its
    -- own height, which is the whole difference between the two layouts.
    local spacer
    if not rowsMode then
        spacer = CreateFrame("Frame", nil, parent)
        spacer:SetSize(1, 1)
        spacer.layoutCol = "both"
        pageRef._fdSpacer = spacer
        if pageRef.children then
            tinsert(pageRef.children, spacer)
        end
    end

    -- Size the two panels to whatever the window currently offers, and keep the
    -- spacer (which is what tells the page layout how tall this page is) in step.
    -- Called on build, on every refresh, and when the window is resized.
    local function ResolvePanelHeight()
        -- ☠ THE BAND ARM HAS NOTHING FOR THIS TO SIZE, and that is a consequence of
        -- the rework rather than an omission. Everything it draws carries its own
        -- height: the banner re-measures itself into the layout it is in, the action
        -- band is a fixed two rows, the filter band reports the settings group's
        -- calculatedHeight, the freshness note measures its own string -- and every
        -- filter's pane is a FIXED height under DandersUI's 60%-of-screen ceiling
        -- (see PANE.paneH for why a viewport-sized pane would be a list scrolling
        -- inside a list). The island's two panels are the only things on this page
        -- that ever grew with the window.
        --
        -- ⚠ STILL CALLED IN BOTH ARMS, by the resize hook and the deferred pass
        -- below. What those want in the band layout is the RefreshStates that follows
        -- this call, not this call.
        if rowsMode then return end

        local bannerH = (banner:GetHeight() > 0) and banner:GetHeight()
                        or (banner.layoutHeight or 34)
        local viewport = GUI.contentFrame and GUI.contentFrame:GetHeight() or 0
        -- Everything BELOW the panels: the freshness note, its 2px gap and some air.
        -- A CONSTANT, deliberately -- see BELOW_PANELS_H for why asking the label
        -- for its height returns a placeholder rather than a measurement.
        local belowH = dbFreshLabel and BELOW_PANELS_H or 0

        local h = PANEL_H_MIN
        if viewport > 0 then
            local available = viewport - PANEL_CHROME_H - belowH - bannerH
            h = mmax(PANEL_H_MIN, mfloor(available * PANEL_H_FRACTION))
        end
        if h ~= PANEL_H then
            PANEL_H = h
            leftPanel:SetHeight(PANEL_H)
            rightArea:SetHeight(PANEL_H)
        end
        -- Always re-assert: the banner can change height independently of the
        -- viewport (it re-wraps when the window narrows), and the page's scroll
        -- range is wrong until this matches what the panels actually occupy.
        --
        -- ⚠ belowH is part of the total. Leaving it out is what let the See Also
        -- footer -- which flows AFTER this spacer -- draw on top of the freshness
        -- note: the page claimed to end where the panels end.
        spacer.layoutHeight = PANEL_CHROME_H + bannerH + PANEL_H + belowH
    end
    pageRef._fdResolvePanelHeight = ResolvePanelHeight

    -- Re-fit when the window is resized. HookScript so we don't displace anything
    -- else listening; guarded so repeated builds don't stack hooks.
    if GUI.contentFrame and not GUI.contentFrame._fdHeightHooked then
        GUI.contentFrame._fdHeightHooked = true
        GUI.contentFrame:HookScript("OnSizeChanged", function()
            local p = GUI.Pages and GUI.Pages["auras_filterdesigner"]
            if p and p._fdResolvePanelHeight then
                p._fdResolvePanelHeight()
                if p.RefreshStates then p:RefreshStates() end
            end
        end)
    end

    ResolvePanelHeight()
    RefreshAll()

    -- ☠ ONE MORE PASS, NEXT FRAME, and this is the whole "it only lines up after you
    -- resize the window" bug.
    --
    -- ResolvePanelHeight reads banner:GetHeight(). At build the banner is still at
    -- CreateInfoBanner's placeholder SetHeight(opts.minHeight or 34) -- it cannot know
    -- its real height yet, because a FontString's wrap is not resolved until it has
    -- rendered at its final width, so the banner defers its OWN measurement to
    -- C_Timer.After(0, DoRecomputeHeight). This banner runs to four wrapped lines,
    -- so it settles ~50px taller than the placeholder we sized the page against.
    --
    -- Nothing told the page. The spacer kept the build-time total, the page reported
    -- itself ~50px shorter than it drew, and the See Also -- which flows after the
    -- spacer -- landed back on top of the freshness note. Resizing the window was the
    -- ONLY thing that re-ran the arithmetic (the contentFrame OnSizeChanged hook
    -- above), which is exactly why a resize appeared to fix it.
    --
    -- ⚠ The banner's own RecomputeHeight does not help: it ends in RelayoutHost,
    -- which re-flows Add()ed children, and this banner is anchored ABSOLUTELY to the
    -- page child. It is invisible to the layout pass, so its growth reaches nothing.
    --
    -- ⚠ Not a wait-for-it loop and not an OnSizeChanged binding on the banner: that
    -- cascade is the Aura Designer indicator-card lockup documented on
    -- CreateInfoBanner. One deferred pass, matching the banner's own single converge.
    -- Safe to call RefreshStates from here -- SetHTML is idempotent, which is what
    -- stops the refresh -> rebuild -> refresh freeze it guards against.
    --
    -- ⚠ STILL RUN IN THE BAND LAYOUT, and not because the banner needs it there.
    -- An Add()ed banner re-measures into the layout it is in, which is the half this
    -- pass existed for; what the bands still need is the CHIP ROW's wrap and the
    -- freshness note's, both of which are resolved from OnSizeChanged and so are
    -- also a frame late. One deferred pass answers all three.
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if pageRef._fdResolvePanelHeight then
                pageRef._fdResolvePanelHeight()
                if pageRef.RefreshStates then pageRef:RefreshStates() end
            end
        end)
    end
end
