local addonName, DF = ...

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
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetBuildInfo = GetBuildInfo
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local LOCALIZED_CLASS_NAMES_MALE = LOCALIZED_CLASS_NAMES_MALE

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
    local function scrubADConfig(cfg)
        if type(cfg) == "table" then
            scrubLayoutGroups(cfg.layoutGroups)
            -- Other Buffs layout groups: a flat array only (new store, never
            -- spec-keyed — no dual-shape dispatch needed).
            if type(cfg.otherLayoutGroups) == "table" then
                scrubGroupArray(cfg.otherLayoutGroups)
            end
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

function DF.BuildFilterDesignerPage(guiRef, pageRef, dbRef)
    -- Build frames once; subsequent calls just refresh widget data.
    -- DoBuild wipes child.ThemeListeners and retires Add()ed children on every
    -- rebuild, so the guard path re-adopts the height spacer and re-registers
    -- the theme listener before refreshing.
    if pageRef._filterDesignerBuilt then
        local p = pageRef.child
        p.ThemeListeners = p.ThemeListeners or {}
        table.insert(p.ThemeListeners, pageRef._fdThemeListener)
        if pageRef._fdSpacer and pageRef.children then
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
    local PANEL_CHROME_H = 66
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
    -- One dial for the status line's vertical cost. HEADER_H and the two rows below
    -- the title all derive from it, so they cannot drift apart again.
    -- Vertical room for the Copy/Sync/Reset row the page host Add()s above this
    -- content. 25 for the button row + the standard gap.
    local TOP_INSET = 25 + 10
    local STATUS_ROW_H = 18
    local HEADER_H = 92 + STATUS_ROW_H -- right-column header panel (3 stacked rows + status)

    -- ========== STATE ==========
    local selKind = "preset" -- "preset" | "custom" | "blacklist"
    local selKey = R.Categories[1] and R.Categories[1].key
    local searchText = "" -- lowercased query

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

    -- ========== DEBUFF BLACKLIST (folded into this page) ==========
    -- The debuff blacklist is PER-MODE (party/raid), stored on the mode db
    -- alongside the other debuff-row filters (debuffFilterRole etc.) — NOT
    -- account-wide like the buff registry. Resolve it LIVE on each access
    -- (DF.db[GUI.SelectedMode], the same handle BuildPage's DoBuild uses): the
    -- page builds once and its guard path never re-captures a db, so a stale
    -- capture would edit the wrong mode after a party/raid switch. Toggling a
    -- debuff reuses DirectFilterChangedProxy (RebuildDirectFilterStrings +
    -- InvalidateAuraLayout) — the exact refresh the debuff row's excludeSpellIDs
    -- merge reacts to (Features/Auras.lua applyDebuffBlacklist).
    local function BlacklistSet()
        local mdb = DF.db and DF.db[GUI.SelectedMode or "party"]
        if not mdb then return nil end
        mdb.debuffBlacklist = mdb.debuffBlacklist or {}
        return mdb.debuffBlacklist
    end
    local function BlacklistDebuffs()
        return (DF.AuraBlacklist and DF.AuraBlacklist.DebuffSpells) or {}
    end
    local function BlacklistCounts()
        local set = BlacklistSet()
        local total, hidden = 0, 0
        for _, e in ipairs(BlacklistDebuffs()) do
            total = total + 1
            if set and set[e.spellId] then hidden = hidden + 1 end
        end
        return hidden, total
    end
    -- Canonical per-mode default set (DF.PartyDefaults/RaidDefaults are the same
    -- source new profiles + the missing-key backfill deep-copy from, so it's safe
    -- to read here without aliasing the live db). Drives the reset button.
    local function BlacklistDefault()
        local mode = GUI.SelectedMode or "party"
        local defaults = (mode == "raid") and DF.RaidDefaults or DF.PartyDefaults
        return defaults and defaults.debuffBlacklist or nil
    end
    local function BlacklistModified()
        local set = BlacklistSet()
        if not set then return false end
        local def = BlacklistDefault() or {}
        for id, on in pairs(set) do
            if on and not def[id] then return true end
        end
        for id, on in pairs(def) do
            if on and not set[id] then return true end
        end
        return false
    end
    local function ResetBlacklist()
        local mdb = DF.db and DF.db[GUI.SelectedMode or "party"]
        if not mdb then return end
        -- Replace with a FRESH copy of the default (never wipe-in-place, never
        -- assign the default table by reference).
        local def, fresh = BlacklistDefault(), {}
        if def then
            for id, on in pairs(def) do if on then fresh[id] = true end end
        end
        mdb.debuffBlacklist = fresh
    end

    -- Row kinds that own an editable spell list, and so can become the right-hand
    -- pane's selection. Everything else in the left list is a tick and a tooltip.
    local SELECTABLE_KIND = { preset = true, custom = true, blacklist = true }

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

    local function IsPresetOn(key)
        local sel = BuffSelection()
        return (sel and sel.presets[key]) and true or false
    end
    local function SetPresetOn(key, on)
        local sel = BuffSelection()
        if not sel then return end
        sel.presets[key] = on or nil
        DirectFilterChangedProxy()
    end
    local function IsCustomOn(cfId)
        local sel = BuffSelection()
        return (sel and sel.customs[cfId]) and true or false
    end
    local function SetCustomOn(cfId, on)
        local sel = BuffSelection()
        if not sel then return end
        sel.customs[cfId] = on or nil
        DirectFilterChangedProxy()
    end
    local function IsUncategorisedOn()
        local sel = BuffSelection()
        return (sel and sel.uncategorised) and true or false
    end
    local function SetUncategorisedOn(on)
        local sel = BuffSelection()
        if not sel then return end
        sel.uncategorised = on and true or false
        DirectFilterChangedProxy()
    end

    -- Flat per-mode booleans (scope switches and the Blizzard debuff categories).
    local function GetFlag(key)
        local mdb = ModeDB()
        return (mdb and mdb[key]) and true or false
    end
    local function SetFlag(key, on)
        local mdb = ModeDB()
        if not mdb then return end
        mdb[key] = on and true or false
        DirectFilterChangedProxy()
    end

    -- Blizzard's fixed debuff categories. Membership is Blizzard-defined, which is
    -- exactly why these rows have no spell list on the right -- and why the right
    -- pane says so rather than showing an empty table.
    local DEBUFF_CATEGORIES = {
        { key = "debuffFilterBoss",         name = "Boss Debuffs",        desc = "Debuffs applied by dungeon and raid bosses." },
        { key = "debuffFilterRole",         name = "Role Debuffs",        desc = "Debuffs Blizzard flags as important for your role." },
        { key = "debuffFilterPriority",     name = "Priority Debuffs",    desc = "Debuffs Blizzard flags as high priority." },
        { key = "debuffFilterCrowdControl", name = "Crowd Control",       desc = "CC effects like stuns, roots, and incapacitates." },
        { key = "debuffFilterRaid",         name = "Raid Debuffs",        desc = "Other debuffs Blizzard flags for raid frames." },
        { key = "debuffFilterDispellable",  name = "Dispellable Debuffs", desc = "Debuffs that can be dispelled. Which dispels count is set on the Debuffs page." },
    }

    -- ========== CUSTOM FILTER HELPERS ==========
    -- Stable name-sorted id list (the store is id-keyed)
    local function SortedCustomIDs()
        local ids = {}
        for cfId in pairs(R:GetStore().customFilters) do
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

    local function CustomSpellCount(f)
        local n = 0
        for _ in pairs(f.spells) do n = n + 1 end
        for _ in pairs(f.rawIDs) do n = n + 1 end
        return n
    end

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
    local function fdBannerLinkClick(pageId)
        if GUI.SelectTab then GUI.SelectTab(pageId) end
    end
    -- Says the ONE thing nothing else on the page says: a filter's spell list is
    -- shared, so editing it here edits it everywhere it is used. That is the
    -- genuinely surprising, genuinely destructive fact in this system, and it goes
    -- first.
    --
    -- ⚠ Do not put "switching one on here shows it on the bar" back in. It was the
    -- banner's opening clause and it duplicated the section hint six inches below,
    -- where it belongs -- the hint sits with the ticks it describes and cannot
    -- scroll out of view, and the status line then says it again for the SELECTED
    -- filter. Three statements of one rule and none of the shared-library warning.
    --
    -- One sentence, deliberately. The predecessor of this banner ran to two
    -- paragraphs and six links, and a page needing that much prose to explain itself
    -- is the thing this whole merge was fixing. The old copy also only ever
    -- mentioned buffs, and pointed at a separate Aura Filters page that no longer
    -- exists -- this page IS that page now.
    -- Leads with what this tab lets you DO. The buff half is the one place on the page
    -- where everything is yours to change, which is worth saying outright -- it is the
    -- exact opposite of the Debuffs banner below, whose job is to say that almost
    -- nothing there is.
    --
    -- It no longer opens with "editing a filter changes it everywhere it is used".
    -- That warning has not been dropped so much as moved to where it is accurate: the
    -- STATUS LINE under each filter's name lists that filter's actual consumers, live,
    -- which a fixed sentence cannot do -- whether the Aura Designer uses a given
    -- filter depends on whether you have built a filter group and linked it.
    --
    -- ⚠ "Aura Designer FILTER GROUPS", not "the Aura Designer". A normal AD group
    -- holds `members` -- spells you placed yourself -- and never touches this
    -- registry; only a Filter Group (kind == "filter") carries a filterSelection. An
    -- earlier version named the Aura Designer as a peer of the Defensive Icon, which
    -- is untrue of most of what the Aura Designer does.
    local BUFF_BANNER = format(
        L["You have full control over buff filters. Edit the built-in ones or create your own — and use them on the %s and in %s filter groups too."],
        fdBannerLink(L["Defensive Icon"], "auras_defensiveicon"),
        fdBannerLink(L["Aura Designer"], "auras_auradesigner"))
    -- TWO banners on this page, one per tab. Not three, and not four:
    --
    -- ⚠ The Debuffs tab has exactly ONE selectable row. SELECTABLE_KIND covers
    -- preset/custom/blacklist only -- the six categories and All Debuffs are
    -- switches, not selections, and BuildTab pins selKind to "blacklist" when you
    -- land on the tab. So "debuffs tab, something other than the blacklist selected"
    -- is not a state that exists, and a branch for it is dead code. This banner
    -- therefore has to carry BOTH halves: what the debuff filters are (Blizzard's,
    -- fixed), and how the one editable thing on the tab works.
    local DEBUFF_BANNER = L["Debuff filters are Blizzard's: the categories are fixed and can't be changed. Optional Debuffs are the few you can turn off — unselect one to hide it."]
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
    local DEBUFF_CATEGORY_CAUTION = L["Only All Debuffs shows every debuff: all the categories combined still miss some debuffs."]
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

    -- ========== LEFT COLUMN: FILTER LIST ==========
    local leftPanel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    leftPanel:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -12)
    leftPanel:SetSize(LEFT_W, PANEL_H)
    GUI:CreatePanelBackdrop(leftPanel, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })

    local leftScroll = CreateFrame("ScrollFrame", nil, leftPanel, "ScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", 4, -32) -- clears the Buffs/Debuffs tab strip (4 + TAB_H + 4)
    -- Clears the action strip at the foot of the panel: two 20px rows, a 4px gutter,
    -- a 6px margin under them and the rule + gap above (6 + 20 + 4 + 20 + 6 = 56, +6
    -- of air). It briefly went to 6 while those buttons lived on the right-hand
    -- header; they came back down here because that header row could not fit them
    -- and a variable-width filter name at every window width.
    leftScroll:SetPoint("BOTTOMRIGHT", -24, 62)
    DF.GUI.StyleScrollBar(leftScroll)

    local leftContent = CreateFrame("Frame", nil, leftScroll)
    leftContent:SetSize(LEFT_W - 28, 1)
    leftScroll:SetScrollChild(leftContent)

    -- Section labels (created once, positioned during refresh). DFFontNormal to
    -- match the right-column header title (titleText) — same weight both sides.
    -- `withHint` gives the label a SECOND FontString beneath it for the "what does
    -- ticking do" line. It has to be its own fontstring: the hint first lived inside
    -- the label's own text with a |cff..| colour code, which recolours but does NOT
    -- resize -- so it rendered at full DFFontNormal weight and ran off the end of a
    -- 240px panel. Colour codes style text; they cannot restyle it.
    local function CreateSectionLabel(text, withHint)
        local fs = leftContent:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        if withHint then
            local hint = leftContent:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
            hint:SetJustifyH("LEFT")
            hint:SetTextColor(0.54, 0.54, 0.54)
            hint:SetWidth(LEFT_W - 40)
            fs.hint = hint
        end
        return fs
    end
    local presetLabel = CreateSectionLabel(L["Filters"], true)
    local customLabel = CreateSectionLabel(L["Custom Buff Filters"])
    local debuffLabel = CreateSectionLabel(L["Filters"], true)

    -- The completeness warning, as a real banner sitting IN the list directly under
    -- All Debuffs -- not up in the page banner, which is where it used to live. It is
    -- about that one switch: it applies only while All Debuffs is off, and the thing
    -- it tells you to do is turn All Debuffs back on. At the top of the page it was
    -- four inches from the control it is about, and it displaced the Debuffs tab's own
    -- banner while it showed.
    --
    -- ⚠ Its text is set ONCE, here, and never re-set. A banner whose SetHTML/SetText
    -- is called from a refresh can drive the refreshContent loop that froze the GUI
    -- once before; this one only ever gets Show/Hide and a position.
    local catCaution = GUI:CreateInfoBanner(leftContent, {
        tone = "caution",
        text = DEBUFF_CATEGORY_CAUTION,
        minHeight = 30,
    })
    catCaution:Hide()
    -- The banner measures its own wrapped height a frame late (CreateInfoBanner defers
    -- DoRecomputeHeight), so the rows below it would sit at a stale offset for that
    -- frame. One re-layout when it settles fixes it; the text never changes after
    -- that, so this fires once per session and then stays quiet. The guard is for the
    -- pathological case only -- RefreshLeft only ever moves this frame, never resizes
    -- it, so it cannot feed itself.
    local relayoutingCaution = false
    catCaution:SetScript("OnSizeChanged", function()
        if relayoutingCaution or not catCaution:IsShown() then return end
        relayoutingCaution = true
        if RefreshLeft then RefreshLeft() end
        relayoutingCaution = false
    end)

    -- ========== BUFFS / DEBUFFS TABS ==========
    -- The two halves were one scrolling list: sixteen buff rows and then the debuff
    -- section. At default window height that left the debuff header, its hint and
    -- All Debuffs at the very bottom with everything after them off-panel -- six
    -- Blizzard categories and the Blacklist unreachable without scrolling. The page
    -- read as buffs-only, which is the exact misconception this merge exists to
    -- remove, while the banner directly above promises "the buff AND debuff bars".
    --
    -- Tabs make them peers: one click each, neither a footnote, and each list is
    -- short enough to need no scrolling in the common case.
    local leftTab = "buffs" -- "buffs" | "debuffs"
    local TAB_H, TAB_GAP = 24, 4
    local tabStrip = CreateFrame("Frame", nil, leftPanel)
    tabStrip:SetPoint("TOPLEFT", 4, -4)
    tabStrip:SetPoint("TOPRIGHT", -4, -4)
    tabStrip:SetHeight(TAB_H)

    local tabButtons = {}
    local function BuildTab(key, label)
        -- Shared underline-tab styling (StyleButton opts.tab) -- the same control as
        -- the Colors page's Seconds/Percent pair, the Aura Designer's tab bar and the
        -- PARTY/RAID/BINDS strip. This was hand-rolled at first (a bare FontString
        -- over a 2px texture), which read as two labels with a line under one rather
        -- than as tabs, and skipped the inactive-cell fill that makes each tab's
        -- bounds visible. No explicit accent, so the stripe and the active label
        -- track the MODE colour the way every other tab in the addon does.
        local b = CreateFrame("Button", nil, tabStrip, "BackdropTemplate")
        GUI:StyleButton(b, {
            tab    = true,
            width  = (LEFT_W - 8 - TAB_GAP) / 2,
            height = TAB_H,
            text   = label,
            font   = "DFFontHighlight",
        })
        b:SetScript("OnClick", function()
            if leftTab == key then return end
            leftTab = key
            -- Selection follows the tab. Leaving a buff preset selected while the
            -- Debuffs tab shows would leave the right pane describing a filter you
            -- can no longer see, with a status line naming a bar this tab is not about.
            if key == "debuffs" then
                selKind, selKey = "blacklist", "blacklist"
            else
                selKind = "preset"
                selKey = R.Categories[1] and R.Categories[1].key
            end
            RefreshAll()
        end)
        tabButtons[key] = b
        return b
    end
    local tabBuffs   = BuildTab("buffs",   L["Buffs"])
    local tabDebuffs = BuildTab("debuffs", L["Debuffs"])
    tabBuffs:SetPoint("TOPLEFT", 0, 0)
    tabDebuffs:SetPoint("TOPLEFT", tabBuffs, "TOPRIGHT", TAB_GAP, 0)

    -- SetActive owns the whole look of a tab (stripe, fill, label colour) and reads
    -- the live accent each time, so this also carries a mode switch -- no separate
    -- theme pass needed here.
    local function RefreshTabs()
        for key, b in pairs(tabButtons) do
            b:SetActive(leftTab == key)
        end
    end

    -- Rule between the scope rows and the filter list. One texture: only one tab
    -- renders per pass, so a second would never be visible at the same time.
    local divider = leftContent:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetColorTexture(0.22, 0.22, 0.22, 1)
    divider:Hide()

    local function PlaceDivider(y)
        divider:ClearAllPoints()
        divider:SetPoint("TOPLEFT", 8, -y)
        divider:SetPoint("TOPRIGHT", -8, -y)
        divider:Show()
        return y + 7
    end

    -- Places a section label and, when it has one, its hint line beneath -- and
    -- returns the new y so the caller cannot forget to account for the extra row.
    local HINT_H = 15
    local function PlaceSectionLabel(fs, y)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", 6, -(y + 4))
        fs:Show()
        y = y + SECTION_H
        if fs.hint then
            fs.hint:ClearAllPoints()
            fs.hint:SetPoint("TOPLEFT", 6, -y)
            fs.hint:Show()
            y = y + HINT_H
        end
        return y
    end

    -- ⚠ Labels, hints and the divider are STANDING regions, not pooled rows -- the
    -- pool sweep at the end of RefreshLeft does not touch them. Without this reset
    -- the inactive tab's headers stay drawn wherever the last pass left them, on top
    -- of the tab that IS showing. Hide everything first; PlaceSectionLabel and
    -- PlaceDivider re-show only what this pass actually lays out.
    local function HideStandingRegions()
        divider:Hide()
        catCaution:Hide()
        for _, fs in ipairs({ presetLabel, customLabel, debuffLabel }) do
            fs:Hide()
            if fs.hint then fs.hint:Hide() end
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
    local titleText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    titleText:SetPoint("TOPLEFT", 10, -10)
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

    -- Does any filter GROUP in one Aura Designer config select this filter? Groups
    -- carry the same {presets, customs} selection shape the bars do, but they live in
    -- two stores under a config:
    --   .layoutGroups      -- spec-keyed post-V2 ({ [specKey] = {groups} }), still a
    --                         flat array on unmigrated data, so BOTH shapes are walked
    --   .otherLayoutGroups -- Other Buffs, a flat array only (newer store)
    -- Same dual-shape dispatch as ScrubDeletedFilter at the top of this file and the
    -- export collector in Profile.lua; a walk that handled only one shape would
    -- silently under-report, which is the failure mode that matters here.
    local function ADConfigUses(cfg, kind, key)
        if type(cfg) ~= "table" then return false end
        local function groupsUse(groups)
            for _, g in ipairs(groups) do
                local sel = type(g) == "table" and g.filterSelection
                if type(sel) == "table" then
                    local t = (kind == "preset") and sel.presets or sel.customs
                    if type(t) == "table" and t[key] then return true end
                end
            end
            return false
        end
        local lg = cfg.layoutGroups
        if type(lg) == "table" then
            if lg[1] ~= nil and groupsUse(lg) then return true end   -- legacy flat array
            for k, v in pairs(lg) do
                if type(k) == "string" and type(v) == "table" and groupsUse(v) then
                    return true
                end
            end
        end
        if type(cfg.otherLayoutGroups) == "table" and groupsUse(cfg.otherLayoutGroups) then
            return true
        end
        return false
    end

    -- Who ELSE consumes the selected filter. Derived from the live db, never
    -- hardcoded: editing a filter here changes it everywhere it is used, and that
    -- is exactly what someone about to edit a shared filter needs to know.
    --
    -- Scoped to THIS MODE, like every other part of the status line. For the Aura
    -- Designer that means the config the mode actually resolves to right now
    -- (GetModeAuraDesigner reads through the merged proxy, so a live raid
    -- auto-layout overlay is included) plus any pinned set that overrides the
    -- mode's preset with its own. An AD preset sitting in the library unused by
    -- this mode is not reported -- it is not in use, and saying so would make the
    -- line meaningless for anyone who keeps spare presets around.
    local function FilterConsumers(kind, key)
        local out = {}
        local mdb = ModeDB()
        if not mdb then return out end

        local defSel = mdb.defensiveFilterSelection
        if defSel then
            local on = (kind == "preset" and defSel.presets and defSel.presets[key])
                    or (kind == "custom" and defSel.customs and defSel.customs[key])
            if on then out[#out + 1] = L["Defensive Icon"] end
        end

        -- The blacklist is a debuff-hiding list, not something a group can select.
        if kind == "preset" or kind == "custom" then
            local mode = GUI.SelectedMode or "party"
            local lib = DF.GetAuraDesignerPresets and DF:GetAuraDesignerPresets()
            local used = ADConfigUses(DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(mode),
                                      kind, key)
            -- Pinned sets may each point at a different preset (nil = inherit the
            -- mode's, already covered above).
            local pf = not used and mdb.pinnedFrames
            if pf and type(pf.sets) == "table" and lib then
                for _, set in pairs(pf.sets) do
                    local name = type(set) == "table" and set.auraDesignerPreset
                    if name and ADConfigUses(lib[name], kind, key) then
                        used = true
                        break
                    end
                end
            end
            if used then out[#out + 1] = L["Aura Designer"] end
        end
        return out
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
    resetBtn:HookScript("OnEnter", function(self)
        GUI:ShowTooltip(self, { title = L["Reset to Default"] })
    end)
    resetBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)
    resetBtn:Hide()
    resetBtn:SetScript("OnClick", function()
        if selKind == "blacklist" then
            ResetBlacklist()
            DirectFilterChangedProxy()
            RefreshAll()
            return
        end
        if selKind ~= "preset" or not selKey then return end
        R:ResetPreset(selKey)
        DirectFilterChangedProxy()
        RefreshAll()
    end)

    -- ⚠ Rows 2 and 3 are offset from the PANEL top, not chained to row 1, so when the
    -- status line was inserted under the title they had to move down by exactly the
    -- STATUS_ROW_H added to HEADER_H. They did not, and the status line rendered over
    -- the search box. Both offsets carry it now; if another row is ever added up
    -- there, these are what move.
    local ROW2_Y = 15 + STATUS_ROW_H
    local ROW3_Y = 43 + STATUS_ROW_H
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
    dbBtn:SetPoint("TOPRIGHT", -10, -(ROW3_Y + BTN_ON_EB))

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
            GUI:ShowTooltip(self, { title = L["Presets are curated"], lines = { L["You can enable or disable the spells shown, but not add new ones. Create a custom filter to add your own."] } })
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
    echoText:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)
    echoText:SetPoint("RIGHT", dbBtn, "LEFT", -8, 0)

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

    local function SelectFilter(kind, key)
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
    pageRef._fdFocusNewFilter = function()
        local range = leftScroll:GetVerticalScrollRange() or 0
        leftScroll:SetVerticalScroll(math.max(0, math.min(addRowY - 8, range)))
        if DF.HighlightWidget then DF:HighlightWidget(addRow) end
    end

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
    -- Anchored only now that all four exist. Each takes its own corner of the panel
    -- rather than chaining off a neighbour, so Reset hiding (it only shows for a
    -- modified preset or the blacklist) leaves the other three exactly where they
    -- were:
    --
    --     [ Duplicate ] [ Rename ]
    --     [ Reset     ] [ Delete ]
    --
    -- The two that destroy something share the right-hand column, away from the two
    -- that don't.
    resetBtn:SetSize(ACT_BTN_W, 20)
    dupBtn:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMLEFT", 6, 30)
    renameBtn:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", -6, 30)
    resetBtn:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMLEFT", 6, 6)
    delBtn:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", -6, 6)

    -- Rule above the strip: without it the buttons read as two more rows of the list
    -- they sit under, rather than as a toolbar acting on that list's selection.
    local actRule = leftPanel:CreateTexture(nil, "ARTWORK")
    actRule:SetHeight(1)
    actRule:SetColorTexture(0.22, 0.22, 0.22, 1)
    actRule:SetPoint("BOTTOMLEFT", leftPanel, "BOTTOMLEFT", 6, 56)
    actRule:SetPoint("BOTTOMRIGHT", leftPanel, "BOTTOMRIGHT", -6, 56)

    -- ========== DATABASE FRESHNESS NOTE ==========
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
    HookDisabledTooltip(renameBtn, L["Presets are curated"], L["Built-in presets can't be renamed or deleted."])
    HookDisabledTooltip(delBtn, L["Presets are curated"], L["Built-in presets can't be renamed or deleted."])
    HookDisabledTooltip(dbBtn, L["Presets are curated"], L["You can enable or disable the spells shown, but not add new ones. Create a custom filter to add your own."])

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
        local isBlacklist = selKind == "blacklist"
        dupBtn:SetDisabled(selKey == nil or isBlacklist)
        renameBtn:SetDisabled(not isCustom)
        delBtn:SetDisabled(not isCustom)
        addBox:SetEnabled(isCustom)
        addBtn:SetDisabled(not isCustom)
        dbBtn:SetDisabled(not isCustom)
        -- The blacklist is a fixed list — hide the search + add-spell controls
        -- entirely (they only exist for editable filters). The preset/custom
        -- views keep them shown (disabled-with-tooltip for presets).
        searchBox:SetShown(not isBlacklist)
        dbBtn:SetShown(not isBlacklist)
        addBox:SetShown(not isBlacklist)
        addBtn:SetShown(not isBlacklist)
        if isBlacklist then HideEcho() end
        -- Reset (header row 1, red danger tone): shown when the selection differs
        -- from its defaults — presets via the registry, the blacklist via its
        -- per-mode default set.
        if isBlacklist then
            resetBtn:SetShown(BlacklistModified())
        else
            resetBtn:SetShown((selKind == "preset" and selKey ~= nil and R:IsPresetModified(selKey)) or false)
        end
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
        row.dot.tooltipSubText = L["This preset has been changed from its defaults."]

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
    local function BindLeftRow(row, y, kind, key, nameStr, countStr, modified, selected, toggle)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row._kind, row._key, row._selected = kind, key, selected
        row.name:SetText(nameStr)
        row.count:SetText(countStr)
        row.dot:SetShown(modified)

        row._onToggle = toggle and toggle.onToggle or nil
        row.name:ClearAllPoints()
        row.name:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
        if toggle then
            row.toggle:Show()
            row.toggle:SetChecked(toggle.checked)
            row.toggle:SetAlpha(toggle.greyed and 0.4 or 1)
            row.toggle:SetEnabled(not toggle.greyed)
            row.toggle.tooltipText = toggle.tooltip
            row.toggle.tooltipDesc = toggle.tooltipDesc
            row.name:SetPoint("LEFT", row.toggle, "RIGHT", 4, 0)
        else
            row.toggle:Hide()
            row.name:SetPoint("LEFT", 10, 0)
        end

        local tc = GUI.GetThemeColor()
        row.accent:SetColorTexture(tc.r, tc.g, tc.b, 1)
        row.accent:SetShown(selected)
        local dim = toggle and toggle.greyed
        if selected then
            row:SetBackdropColor(tc.r * 0.30, tc.g * 0.30, tc.b * 0.30, 0.9)
            row.name:SetTextColor(0.95, 0.95, 0.95)
        else
            row:SetBackdropColor(ROW_REST_R, ROW_REST_G, ROW_REST_B, ROW_REST_A)
            row.name:SetTextColor(0.70, 0.70, 0.70)
        end
        if dim then row.name:SetTextColor(0.42, 0.42, 0.42) end
        row.count:SetTextColor(dim and 0.32 or 0.5, dim and 0.32 or 0.5, dim and 0.32 or 0.5)
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
    local function AcquireSpellRow(i)
        local row = spellRows[i]
        if row then
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
        if hot.SetPropagateMouseMotion then hot:SetPropagateMouseMotion(true) end
        if hot.SetPropagateMouseClicks and not InCombatLockdown() then
            hot:SetPropagateMouseClicks(true)
        end
        -- The ID line rides along with the game tooltip now that the 'i' button is
        -- gone. Raw rows (an id typed into a custom filter that the database does not
        -- know) have no game tooltip to hang it on, and used to have NO hover at all
        -- -- the 'i' was the only way to see what you had added -- so they get our
        -- own tooltip instead. That is the one place this change adds a hover rather
        -- than removing a button.
        hot:SetScript("OnEnter", function()
            local ids = row._infoIDs and format(L["Spell IDs: %s"], row._infoIDs)
            if row._spellID and not row._raw then
                ShowSpellTooltip(row, row._spellID, row._infoTitle, SpellRowStillShows,
                                 ids and { ids } or nil)
            elseif row._infoTitle then
                GUI:ShowTooltip(row, { title = row._infoTitle, lines = ids and { ids } or nil })
            end
        end)
        hot:SetScript("OnLeave", function() GUI:HideTooltip() end)
        row.hot = hot

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
        local showCheck = isPreset or item.isBlacklist
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
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

        row._spellID = item.tooltipID
        row._raw = item.raw
        row._rowToggles = showCheck

        -- Info tooltip data: canonical + variant IDs for known spells, just
        -- the raw ID otherwise. Rebuilt on every bind like the rest.
        row._infoTitle = item.name
        local rec = item.rec
        if rec and rec.alts and #rec.alts > 0 then
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
            if item.isBlacklist then
                -- Writes the per-mode blacklist set (true = hidden) rather than
                -- R:SetSpellEnabled, so the stored value is the INVERSE of the box --
                -- unselecting is what adds the id. DirectFilterChangedProxy re-merges
                -- the debuff row's excludeSpellIDs immediately.
                local id = item.id
                row._onAction = function()
                    local set = BlacklistSet()
                    if set then
                        set[id] = (not set[id]) and true or nil
                        DirectFilterChangedProxy()
                        RefreshAll()
                    end
                end
            else
                local key, rec = selKey, item.rec
                row._onAction = function()
                    R:SetSpellEnabled(key, rec, not R:IsSpellEnabled(key, rec))
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
        debuffLabel:SetTextColor(tc.r, tc.g, tc.b)
        -- Re-theme the add row here too. StyleButton registers its own theme
        -- listener on the button's PARENT, which for this row is the scroll child —
        -- and the page's theme walk only visits pageRef.child, so that registration
        -- is never reached and the row stayed party-blue in raid mode. This refresh
        -- already owns "make the left list match the theme"; the row joins it.
        if addRow.UpdateTheme then addRow.UpdateTheme() end

        -- Each section says WHAT ITS CHECKBOXES DO, dimmed after the name.
        --
        -- ⚠ "Selected", page-wide. Both lists draw the same checkbox, so both read the
        -- same way: a filter is selected, a spell inside it is selected, and the
        -- debuff banner says "unselect one to hide it". Never "ticked" -- the box is
        -- a filled square, so that word names a mark that is not on screen.
        --
        -- This overrides an earlier call that banned "selected" here, on the grounds
        -- that clicking a row ALSO selects that filter for editing in the right pane.
        -- The collision is real and was judged harmless: the sentence sits above a
        -- column of checkboxes and is plainly about them, and one word across the
        -- whole page beats a vocabulary that has to be learned twice.
        --
        -- This page has two jobs and the checkbox only belongs to one: it is a LIBRARY
        -- of filters that everything shares, and it is the bar's SWITCHBOARD. A bare
        -- switch reads as "this filter is on" when it means "the bar uses this filter"
        -- -- other pages pick from the same library themselves. Saying so on the
        -- header puts the answer where the misreading happens, and unlike the banner
        -- it cannot scroll out of view.
        --
        -- No mode suffix: the tabs, the theme colour (party purple vs raid orange)
        -- and the switches already carry that, and it was noise on every header. The
        -- status line still names the mode, because that claim IS mode-specific.
        presetLabel:SetText(L["Filters"])
        presetLabel.hint:SetText(L["Selected filters show on the buffs bar"])
        debuffLabel:SetText(L["Filters"])
        debuffLabel.hint:SetText(L["Selected filters show on the debuffs bar"])
        RefreshTabs()
        HideStandingRegions()

        local buffAll = GetFlag("directBuffShowAll")
        local y, used = 4, 0

        -- ---------- BUFFS TAB ----------
        if leftTab == "buffs" then

        -- Scope rows sit ABOVE the section header, not inside the list. They are not
        -- filters: All Buffs overrides the whole list, Only My Buffs modifies all of
        -- it. Sharing the list's tick, indent and row height made them read as two
        -- more filters, so a rule and the "Filters" header below separate the kinds.
        used = used + 1
        BindLeftRow(AcquireLeftRow(used), y, "scope", "directBuffShowAll",
            L["All Buffs"], "", false, false,
            { checked = buffAll,
              tooltip = L["All Buffs"],
              tooltipDesc = L["Show every buff with no filtering."],
              onToggle = function(on)
                SetFlag("directBuffShowAll", on)
                RefreshAll()
            end })
        y = y + LEFT_ROW_H

        used = used + 1
        BindLeftRow(AcquireLeftRow(used), y, "scope", "directBuffOnlyMine",
            L["Only My Buffs"], "", false, false,
            { checked = GetFlag("directBuffOnlyMine"),
              tooltip = L["Only My Buffs"],
              tooltipDesc = L["Only show buffs that you cast. Applies to all buff filters."],
              onToggle = function(on)
                SetFlag("directBuffOnlyMine", on)
                RefreshAll()
            end })
        y = y + LEFT_ROW_H + 6

        y = PlaceDivider(y)
        y = PlaceSectionLabel(presetLabel, y)

        for _, cat in ipairs(R.Categories) do
            used = used + 1
            local row = AcquireLeftRow(used)
            local enabled, total = R:PresetCounts(cat.key)
            local key = cat.key
            BindLeftRow(row, y, "preset", key, L[cat.name],
                enabled .. "/" .. total,
                R:IsPresetModified(key),
                selKind == "preset" and selKey == key,
                { checked = IsPresetOn(key), greyed = buffAll, onToggle = function(on)
                    SetPresetOn(key, on)
                    RefreshAll()
                end })
            y = y + LEFT_ROW_H
        end

        -- The complement bucket: buffs in no category at all.
        used = used + 1
        BindLeftRow(AcquireLeftRow(used), y, "uncategorised", "uncategorised",
            L["Uncategorised Buffs"], "", false, false,
            { checked = IsUncategorisedOn(), greyed = buffAll,
              tooltip = L["Uncategorised Buffs"],
              tooltipDesc = L["Buffs that belong to none of the filters above."],
              onToggle = function(on)
                SetUncategorisedOn(on)
                RefreshAll()
            end })
        y = y + LEFT_ROW_H

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

        for _, cfId in ipairs(SortedCustomIDs()) do
            local f = R:GetCustomFilter(cfId)
            used = used + 1
            local row = AcquireLeftRow(used)
            local id = cfId
            BindLeftRow(row, y, "custom", id, f.name or id,
                tostring(CustomSpellCount(f)), false,
                selKind == "custom" and selKey == id,
                { checked = IsCustomOn(id), greyed = buffAll, onToggle = function(on)
                    SetCustomOn(id, on)
                    RefreshAll()
                end })
            y = y + LEFT_ROW_H
        end

        -- ---------- DEBUFFS TAB ----------
        -- Six Blizzard-defined categories plus the Blacklist. The debuff half is NOT
        -- "All Debuffs and a blacklist" -- that is only how it looks while All
        -- Debuffs is ticked and the categories are out of sight.
        --
        -- The categories have no spell list of their own (membership is Blizzard's),
        -- so they are tick-only rows; the right pane keeps whatever IS editable.
        else

        local debuffAll = GetFlag("directDebuffShowAll")

        used = used + 1
        BindLeftRow(AcquireLeftRow(used), y, "scope", "directDebuffShowAll",
            L["All Debuffs"], "", false, false,
            { checked = debuffAll,
              tooltip = L["All Debuffs"],
              tooltipDesc = L["Show every debuff with no filtering."],
              onToggle = function(on)
                SetFlag("directDebuffShowAll", on)
                RefreshAll()
            end })
        y = y + LEFT_ROW_H + 6

        -- The warning belongs to the switch above it, so it lives here and only while
        -- that switch is off. Measured height, not a constant: the copy wraps to two
        -- or three lines depending on the panel width and the locale.
        if not debuffAll then
            catCaution:ClearAllPoints()
            catCaution:SetPoint("TOPLEFT", 4, -y)
            catCaution:SetPoint("TOPRIGHT", -4, -y)
            catCaution:Show()
            y = y + mmax(catCaution:GetHeight() or 0, catCaution.layoutHeight or 34) + 8
        end

        y = PlaceDivider(y)
        y = PlaceSectionLabel(debuffLabel, y)

        for _, cat in ipairs(DEBUFF_CATEGORIES) do
            used = used + 1
            local key = cat.key
            BindLeftRow(AcquireLeftRow(used), y, "debuffcat", key, L[cat.name], "", false,
                false,
                { checked = GetFlag(key), greyed = debuffAll,
                  tooltip = L[cat.name], tooltipDesc = L[cat.desc],
                  onToggle = function(on)
                    SetFlag(key, on)
                    RefreshAll()
                end })
            y = y + LEFT_ROW_H
        end

        used = used + 1
        do
            local hidden, total = BlacklistCounts()
            -- No toggle: this list is always in force, so an unselected box would be
            -- a lie. It carries its own count instead.
            --
            -- ⚠ Counts what is SHOWN, not what is hidden, so the number matches the
            -- filter rows above it (which count selected) and matches the ticked boxes
            -- inside. It read "hidden/total" while the list was called the Blacklist,
            -- which put an inverted number in a column of upright ones.
            BindLeftRow(AcquireLeftRow(used), y, "blacklist", "blacklist",
                L["Optional Debuffs"], (total - hidden) .. "/" .. total, false,
                selKind == "blacklist")
            y = y + LEFT_ROW_H
        end

        end -- leftTab

        -- The custom-filter add row belongs to the Buffs tab only. Pooled ROWS get
        -- hidden by the sweep below, but this one is a standing frame -- it would
        -- otherwise float over the debuff list at whatever y the last buff refresh
        -- left it at.
        addRow:SetShown(leftTab == "buffs")

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
        local isBlacklist = selKind == "blacklist"

        -- ONE banner per tab, both info. Driven off the TAB, not the selection: the
        -- Debuffs tab has a single selectable row (see DEBUFF_BANNER), so keying this
        -- off isBlacklist would look like it handled a case that cannot occur.
        --
        -- ⚠ The page banner is never a warning any more. It carried the debuff
        -- completeness caution for a while, which meant flipping All Debuffs off
        -- turned the top of the page gold AND displaced the tab's own explanation --
        -- a warning about one switch, four inches from that switch, evicting the copy
        -- that says what the whole tab is. That caution is now a banner of its own
        -- directly under All Debuffs (see catCaution), beside the control it is about,
        -- and nothing has to give up its slot for it.
        --
        -- The rule that leaves behind: this banner says "here is how this tab works"
        -- and is always info; anything that says "this will silently miss things"
        -- belongs next to the control that caused it.
        banner:SetTone("info")
        banner:SetHTML(leftTab == "debuffs" and DEBUFF_BANNER or BUFF_BANNER,
                       fdBannerLinkClick)

        -- Hide any lingering add-by-ID echo once the selection changes
        local selIdent = selKind .. "|" .. tostring(selKey)
        if selIdent ~= lastEchoSel then
            lastEchoSel = selIdent
            HideEcho()
        end

        local tc = GUI.GetThemeColor()
        titleText:SetTextColor(tc.r, tc.g, tc.b)

        -- Header: filter name + tracked/spell count
        if isPreset then
            local catName
            for _, cat in ipairs(R.Categories) do
                if cat.key == selKey then
                    catName = L[cat.name]
                    break
                end
            end
            titleText:SetText(catName or selKey or "")
            local enabled, total = R:PresetCounts(selKey)
            countText:SetText(format(L["%d of %d tracked"], enabled, total))
        elseif isBlacklist then
            titleText:SetText(L["Optional Debuffs"])
            local hidden, total = BlacklistCounts()
            countText:SetText(format(L["%d of %d shown"], total - hidden, total))
        else
            local f = R:GetCustomFilter(selKey)
            titleText:SetText(f and (f.name or selKey) or "")
            countText:SetText(format(L["%d spells"], f and CustomSpellCount(f) or 0))
        end
        -- Both texts are now set, so the name can be capped against what the count
        -- actually takes up on this pass.
        ClampTitle()

        -- Status line: SHORT, because the header panel is not wide enough for the
        -- whole story and a truncated sentence ending in "the..." is worse than no
        -- sentence. The state goes on the line; the scoping rules -- which are three
        -- levels deep and genuinely surprising -- go in the hover tooltip.
        if isBlacklist then
            -- No switch of its own, so no state dot -- an unlit one would read as
            -- "off", which the blacklist never is.
            statusDot:Hide()
            statusText:SetText("|cff888888" .. L["Always in force"] .. "|r")
        else
            local on = isPreset and IsPresetOn(selKey) or (not isPreset and IsCustomOn(selKey))
            local modeName = (GUI.SelectedMode == "raid") and L["Raid"] or L["Party"]
            statusDot:Show()

            -- ONE question, ONE polarity: where does this filter apply?
            --
            -- The previous phrasing was "Off · Party buff bar · also Defensive Icon",
            -- which put a negative and a positive in the same sentence at the same
            -- weight -- it read as though the filter were off in BOTH places. So the
            -- consumers are now the CONTENT of "On" rather than a contradictory
            -- afterthought, and "Off" means off everywhere, full stop.
            local places = {}
            if on then places[#places + 1] = format(L["Buff bar (%s)"], modeName) end
            for _, c in ipairs(FilterConsumers(selKind, selKey)) do
                places[#places + 1] = c
            end

            -- The dot follows IN USE ANYWHERE, not the switch in the list. So a
            -- filter the Defensive Icon still picks reads green while switched off
            -- here -- which is correct and worth saying: editing it still changes
            -- something. The absence of "Buff bar" from the list IS the signal that
            -- the switch is off, and the tooltip says so outright.
            if #places > 0 then
                -- StyleButton's "success" tone, so green means the same thing here
                -- as it does on a button.
                statusDot:SetVertexColor(0.3, 0.8, 0.45)
                statusText:SetText(format(L["On · %s"], table.concat(places, ", ")))
            else
                -- GUI.Colors.warning, NOT the C_WARNING upvalue -- that is a
                -- file-local in GUI.lua, so naming it here would be a nil GLOBAL
                -- read: legal Lua, parses clean, errors only when this line runs.
                local w = GUI.Colors.warning
                statusDot:SetVertexColor(w.r, w.g, w.b)
                statusText:SetText(L["Off · not in use"])
            end
        end

        -- The three scopes, verified against where each actually lives rather than
        -- assumed -- they are NOT the same, and the difference is what makes people
        -- think filters are broken:
        --   ticks   -> DF.db[mode].buffFilterSelection      per MODE
        --   presets -> DF.db.filterPresetOverrides           per PROFILE (both modes)
        --   customs -> DF:GetGlobalDB().auraFilters          per ACCOUNT (all profiles)
        statusHit.tooltipText = L["Where this applies"]
        statusHit.tooltipLines = isBlacklist
            and { L["Optional Debuffs are per mode: what you hide here applies to this mode only."] }
            or  {
                -- The checkbox controls the buffs bar and nothing else, which is why
                -- the dot can be green while it is clear -- said outright, because it
                -- is the one reading of this line that looks like a bug.
                L["Selecting a filter in the list adds it to the buffs bar. Other pages, like the Defensive Icon, choose filters for themselves — so a filter can still be in use while it is unselected here."],
                isPreset
                    and L["Which filters are selected is per mode, so Party and Raid keep separate choices — use Copy or Sync above to share them. What a filter CONTAINS is not per mode: editing its spells changes both."]
                    or  L["Which filters are selected is per mode, so Party and Raid keep separate choices — use Copy or Sync above to share them. A custom filter's spells are shared by every profile on the account."],
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
            local nm = name or format("#%d", id)
            if matches(nm) then
                put("ALL", {
                    id = id, name = nm, icon = icon or FALLBACK_ICON,
                    chip = name and L["not in database"] or L["unknown ID"],
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
                        chip = (rec.alts and #rec.alts > 0) and format("+%d", #rec.alts) or nil,
                        enabled = R:IsSpellEnabled(selKey, rec),
                        tooltipID = rec.id,
                    })
                end
            end
        elseif isBlacklist then
            -- The fixed non-secret debuff list. "Enabled" = shown; disabling a
            -- row blacklists the spell (excludeSpellIDs) so it drops off the
            -- debuff bar. Resolve the live client name so it localizes like the
            -- rest of the list; fall back to the entry's English display.
            local set = BlacklistSet()
            for _, e in ipairs(BlacklistDebuffs()) do
                local name
                if C_Spell and C_Spell.GetSpellName then
                    local ok, v = pcall(C_Spell.GetSpellName, e.spellId)
                    if ok and type(v) == "string" and v ~= "" then name = v end
                end
                name = name or e.display
                -- Icon: use the entry's baked fileID, else resolve it live — lets new
                -- catalog entries omit a hardcoded icon and still show the real one.
                local icon = e.icon
                if not icon and C_Spell and C_Spell.GetSpellTexture then
                    local okI, t = pcall(C_Spell.GetSpellTexture, e.spellId)
                    if okI and t then icon = t end
                end
                if matches(name) then
                    put("ALL", {
                        id = e.spellId, name = name, icon = icon or FALLBACK_ICON,
                        tooltipID = e.spellId,
                        enabled = not (set and set[e.spellId]),
                        isBlacklist = true,
                    })
                end
            end
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
                                chip = (rec.alts and #rec.alts > 0) and format("+%d", #rec.alts) or nil,
                                tooltipID = rec.id,
                            })
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
        for _, g in pairs(groups) do
            tsort(g, function(a, b)
                if (a.raw or false) ~= (b.raw or false) then return not a.raw end
                -- Raw rows sort by resolved name too; unresolved "#id" names
                -- cluster first ("#" < letters), ordered by id via the tiebreak.
                if a.name ~= b.name then return a.name < b.name end
                return a.id < b.id
            end)
        end

        -- Render groups in class order, ALL last
        local y = 4
        local usedHeaders, usedRows, shown = 0, 0, 0
        local function RenderGroup(token)
            local g = groups[token]
            if not g or #g == 0 then return end
            -- The blacklist is a single flat list; the "All Classes" class
            -- header adds nothing there, so skip it in that view.
            if not isBlacklist then
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
            end

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
    pageRef._fdSelectBlacklist = function()
        leftTab = "debuffs"
        SelectFilter("blacklist", "blacklist")
    end
    -- The buff-side "Customise" button: keep the user's last buff filter, but if
    -- they're parked on the (debuff) Blacklist, move to the first buff preset so
    -- "Customise" from the buff section never lands on a debuff view.
    pageRef._fdSelectBuffs = function()
        leftTab = "buffs"
        if selKind == "blacklist" then
            SelectFilter("preset", R.Categories[1] and R.Categories[1].key)
        else
            RefreshAll()
        end
    end

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

    -- ========== PAGE HEIGHT SPACER ==========
    -- The page's scroll height comes from RefreshStates summing Add()ed
    -- children; this page anchors its frames directly, so an invisible spacer
    -- carries the total height through the standard layout pass.
    local spacer = CreateFrame("Frame", nil, parent)
    spacer:SetSize(1, 1)
    spacer.layoutCol = "both"
    pageRef._fdSpacer = spacer
    if pageRef.children then
        tinsert(pageRef.children, spacer)
    end

    -- Size the two panels to whatever the window currently offers, and keep the
    -- spacer (which is what tells the page layout how tall this page is) in step.
    -- Called on build, on every refresh, and when the window is resized.
    local function ResolvePanelHeight()
        local bannerH = (banner:GetHeight() > 0) and banner:GetHeight()
                        or (banner.layoutHeight or 34)
        local viewport = GUI.contentFrame and GUI.contentFrame:GetHeight() or 0
        local h = PANEL_H_MIN
        if viewport > 0 then
            local available = viewport - PANEL_CHROME_H - bannerH
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
        spacer.layoutHeight = PANEL_CHROME_H + bannerH + PANEL_H
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
end
