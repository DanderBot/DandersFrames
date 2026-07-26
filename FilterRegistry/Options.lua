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
    local LEFT_W = 240
    local LEFT_ROW_H = 24

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
    local SECTION_H = 26 -- section-label slot (bumped for the larger DFFontNormal labels)
    local SPELL_ROW_H = 26
    local CLASS_HEADER_H = 22
    local HEADER_H = 92 -- right-column header panel (3 stacked rows)

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
    -- (opt-in — nothing shows until enabled), the blacklist is the inverse
    -- (opt-out — debuffs show until hidden). Naming that flip is what keeps the
    -- Hide/Show rows from reading like the Enable/Disable ones above. Both texts
    -- are ~2 lines, so the swap barely changes the banner height. RefreshRight
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
    local BUFF_BANNER = L["Opt-in buff filters — you choose which buffs show. Enable or disable spells in the built-in presets, or create custom filters, then turn them on from the"]
        .. " " .. fdBannerLink(L["Aura Filters"], "auras_filters") .. "."
    local BLACKLIST_BANNER = L["The reverse of the opt-in buff filters: instead of choosing what to show, you choose nuisance debuffs to hide from the debuff bar. Only debuffs Blizzard keeps non-secret can be hidden."]
    local banner = GUI:CreateInfoBanner(parent, {
        tone = "info",
        html = true,
        text = BUFF_BANNER,
        onLinkClick = fdBannerLinkClick,
    })
    banner:SetPoint("TOPLEFT", 10, -10)
    banner:SetPoint("RIGHT", -10, 0)

    -- ========== LEFT COLUMN: FILTER LIST ==========
    local leftPanel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    leftPanel:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -12)
    leftPanel:SetSize(LEFT_W, PANEL_H)
    GUI:CreatePanelBackdrop(leftPanel, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })

    local leftScroll = CreateFrame("ScrollFrame", nil, leftPanel, "ScrollFrameTemplate")
    leftScroll:SetPoint("TOPLEFT", 4, -4)
    leftScroll:SetPoint("BOTTOMRIGHT", -24, 34) -- bottom strip: 1 row of action buttons
    DF.GUI.StyleScrollBar(leftScroll)

    local leftContent = CreateFrame("Frame", nil, leftScroll)
    leftContent:SetSize(LEFT_W - 28, 1)
    leftScroll:SetScrollChild(leftContent)

    -- Section labels (created once, positioned during refresh). DFFontNormal to
    -- match the right-column header title (titleText) — same weight both sides.
    local function CreateSectionLabel(text)
        local fs = leftContent:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        return fs
    end
    local presetLabel = CreateSectionLabel(L["Buff Filter Presets"])
    local customLabel = CreateSectionLabel(L["Custom Buff Filters"])
    local debuffLabel = CreateSectionLabel(L["Debuffs"])

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

    -- Row 1: title + counts + reset, flowing left-to-right only.
    local titleText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    titleText:SetPoint("TOPLEFT", 10, -10)
    titleText:SetJustifyH("LEFT")

    local countText = headerPanel:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    countText:SetPoint("LEFT", titleText, "RIGHT", 10, 0)
    countText:SetTextColor(0.5, 0.5, 0.5)

    -- ========== RESET TO DEFAULT (header row 1) ==========
    -- Red danger tone (icon + label), matching the Reset Page button. Only
    -- shown while the selected preset has per-profile overrides. Flows after
    -- the counts, so it can't collide with the search box at narrow GUI widths
    -- (search lives on its own row below).
    local resetBtn = CreateFrame("Button", nil, headerPanel, "BackdropTemplate")
    resetBtn:SetSize(115, 20)
    GUI:StyleButton(resetBtn, {
        tone = "danger",
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\refresh", size = 14 },
        text = L["Reset to Default"],
    })
    resetBtn:SetWidth(math.ceil(resetBtn.Text:GetStringWidth()) + 32)
    resetBtn:SetPoint("LEFT", countText, "RIGHT", 12, 0)
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

    -- Row 2: the Add-from-Database picker button is right-anchored; the
    -- search box stretches between the panel's left edge and the button, so
    -- it shrinks instead of overlapping. Active for custom filters; greyed
    -- out while a preset is selected (same tooltip pattern as add-by-ID).
    local dbBtn = GUI:CreateButton(headerPanel, L["Add from Database"], 130, 22, function(self)
        if self.dfDisabled then return end
        if selKind ~= "custom" or not R:GetCustomFilter(selKey) then return end
        OpenPicker(selKey)
    end)
    dbBtn:SetPoint("TOPRIGHT", -10, -30)

    -- Search box (placeholder-only; not db-backed). CreateEditBox reserves
    -- 15px for its (empty) label, so the frame sits at -15 to land the
    -- editbox body at -30..-54, level with the picker button.
    local searchBox = GUI:CreateEditBox(headerPanel, "", nil, nil, nil, 170, L["Search..."])
    searchBox:SetPoint("TOPLEFT", 10, -15)
    searchBox:SetPoint("TOPRIGHT", dbBtn, "TOPLEFT", -8, 15)

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

    -- ========== ADD-BY-ID ROW (header row 3) ==========
    -- Active for custom filters; greyed out while a preset is selected
    -- (presets are curated — the Add button's tooltip explains).
    -- Frame at -43 lands the editbox body at -58..-82.
    local addBox = GUI:CreateEditBox(headerPanel, "", nil, nil, nil, 90, L["Spell ID"])
    addBox:SetPoint("TOPLEFT", 10, -43)

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

    echoText:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)
    -- Right edge pinned at the add-row's vertical center (-70 = editbox middle)
    echoText:SetPoint("RIGHT", headerPanel, "TOPRIGHT", -10, -70)

    -- ========== LEFT COLUMN ACTION BUTTONS ==========
    -- Created after the search box on purpose: SelectFilter clears the active
    -- search, so these handlers must close over the searchBox local.
    -- Three across one row: 6px margins, two 4px gaps. Was two rows of two, until
    -- New Filter moved into the list above and left these three — all of which act
    -- on the SELECTED filter, which is what the strip now uniformly means.
    local LEFT_BTN_W = (LEFT_W - 12 - 8) / 3

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

    local dupBtn = GUI:CreateButton(leftPanel, L["Duplicate"], LEFT_BTN_W, 22, function(self)
        if self.dfDisabled or not selKey then return end
        local src = selKey -- capture: selection may move before the prompt closes
        PromptFilterName(L["Name the duplicated filter:"], CurrentDisplayName() .. " copy", L["Duplicate"], function(text)
            text = Trim(text)
            if text == "" then return end
            SelectFilter("custom", R:DuplicateFilter(src, text))
        end)
    end)
    dupBtn:SetPoint("BOTTOMLEFT", 6, 6)

    local renameBtn = GUI:CreateButton(leftPanel, L["Rename"], LEFT_BTN_W, 22, function(self)
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
    renameBtn:SetPoint("BOTTOM", 0, 6)

    local delBtn = GUI:CreateButton(leftPanel, L["Delete"], LEFT_BTN_W, 22, function(self)
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
    delBtn:SetPoint("BOTTOMRIGHT", -6, 6)

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

        -- Selection accent bar (theme-colored)
        row.accent = row:CreateTexture(nil, "ARTWORK")
        row.accent:SetSize(3, LEFT_ROW_H - 7)
        row.accent:SetPoint("LEFT", 2, 0)

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

        row.name = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        row.name:SetPoint("LEFT", 10, 0)
        row.name:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")

        row:SetScript("OnClick", function(self)
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

    local function BindLeftRow(row, y, kind, key, nameStr, countStr, modified, selected)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row._kind, row._key, row._selected = kind, key, selected
        row.name:SetText(nameStr)
        row.count:SetText(countStr)
        row.dot:SetShown(modified)

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

        -- Preset view: Enable/Disable button (text rebound per state)
        row.action = GUI:CreateButton(row, L["Disable"], 64, 18, function()
            if row._onAction then row._onAction() end
        end)
        row.action:SetPoint("RIGHT", -6, 0)

        -- Custom view: inline destructive remove
        row.remove = GUI:CreateCloseButton(row, {
            size = 18,
            tone = "danger",
            onClick = function()
                if row._onRemove then row._onRemove() end
            end,
        })
        row.remove:SetPoint("RIGHT", -6, 0)

        -- 'i' info button: hovering lists the spell's canonical + variant IDs.
        -- Same Media\Icons "info" asset the info banners use (via CreateButton's
        -- iconName param); repositioned per bind next to the row's action.
        row.info = GUI:CreateButton(row, nil, 18, 18, nil, "info")
        row.info.Icon:SetVertexColor(0.6, 0.6, 0.6)
        row.info:HookScript("OnEnter", function(self)
            if row._infoTitle then
                GUI:ShowTooltip(self, {
                    title = row._infoTitle,
                    lines = { format(L["Spell IDs: %s"], row._infoIDs or "") },
                })
            end
        end)
        row.info:HookScript("OnLeave", function() GUI:HideTooltip() end)

        -- Right-aligned chip: "+N" extra spellIDs, or the unknown-ID caption.
        -- Anchored to the info button, so it follows per-bind repositioning.
        row.chip = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        row.chip:SetPoint("RIGHT", row.info, "LEFT", -6, 0)
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
        hot:SetScript("OnEnter", function()
            if row._spellID and not row._raw then
                ShowSpellTooltip(row, row._spellID, row._infoTitle, SpellRowStillShows)
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
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropColor(ROW_REST_R, ROW_REST_G, ROW_REST_B, ROW_REST_A)
            GUI:HideTooltip()
        end)

        spellRows[i] = row
        return row
    end

    local function BindSpellRow(row, y, item, isPreset)
        -- Blacklist rows render like preset rows (Enable/Disable action, dim
        -- when hidden) but carry their own toggle instead of R:SetSpellEnabled.
        local showAction = isPreset or item.isBlacklist
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)

        row.icon:SetTexture(item.icon or FALLBACK_ICON)
        row.name:SetText(item.name)
        row.chip:SetText(item.chip or "")
        -- Fit the tooltip hotspot to the icon plus the name's ACTUAL rendered text.
        -- Must be per bind: the fontstring is full-width, so only the string width
        -- tells us where the visible label ends. 32 = 6 left inset + 20 icon + 6 gap.
        row.hot:SetWidth(32 + (row.name:GetStringWidth() or 0) + 4)
        -- Info button hugs the row's action control: 64px Enable/Disable
        -- button in the preset view, 18px remove "x" in the custom view.
        -- The chip is anchored to the info button, so it follows.
        row.info:ClearAllPoints()
        row.info:SetPoint("RIGHT", showAction and -74 or -28, 0)
        row._spellID = item.tooltipID
        row._raw = item.raw
        row._rowToggles = showAction

        -- Info tooltip data: canonical + variant IDs for known spells, just
        -- the raw ID otherwise. Rebuilt on every bind like the rest.
        row._infoTitle = item.name
        local rec = item.rec
        if rec and rec.alts and #rec.alts > 0 then
            row._infoIDs = rec.id .. ", " .. table.concat(rec.alts, ", ")
        else
            row._infoIDs = tostring(rec and rec.id or item.id)
        end

        local dim = showAction and not item.enabled
        row.icon:SetAlpha(dim and 0.4 or 1)
        row.icon:SetDesaturated(dim)
        row.name:SetAlpha(dim and 0.5 or 1)
        ApplyNameColor(row.name, rec and rec.class, dim)

        if showAction then
            row.action:Show()
            row.remove:Hide()
            if item.isBlacklist then
                -- The blacklist is opt-out, so its rows read Hide/Show — the verb
                -- matches the outcome (dim = hidden stays the page-wide convention).
                -- Toggle the per-mode blacklist entry (true = hidden), reusing
                -- DirectFilterChangedProxy so the debuff row re-merges its
                -- excludeSpellIDs immediately.
                row.action.Text:SetText(item.enabled and L["Hide"] or L["Show"])
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
                row.action.Text:SetText(item.enabled and L["Disable"] or L["Enable"])
                local key, rec = selKey, item.rec
                row._onAction = function()
                    R:SetSpellEnabled(key, rec, not R:IsSpellEnabled(key, rec))
                    DirectFilterChangedProxy()
                    RefreshAll()
                end
            end
            row._onRemove = nil
        else
            row.action:Hide()
            row.remove:Show()
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

        local y = 4
        presetLabel:ClearAllPoints()
        presetLabel:SetPoint("TOPLEFT", 6, -(y + 4))
        y = y + SECTION_H

        local used = 0
        for _, cat in ipairs(R.Categories) do
            used = used + 1
            local row = AcquireLeftRow(used)
            local enabled, total = R:PresetCounts(cat.key)
            BindLeftRow(row, y, "preset", cat.key, L[cat.name],
                enabled .. "/" .. total,
                R:IsPresetModified(cat.key),
                selKind == "preset" and selKey == cat.key)
            y = y + LEFT_ROW_H
        end

        y = y + 8
        customLabel:ClearAllPoints()
        customLabel:SetPoint("TOPLEFT", 6, -(y + 4))
        y = y + SECTION_H

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
            BindLeftRow(row, y, "custom", cfId, f.name or cfId,
                tostring(CustomSpellCount(f)), false,
                selKind == "custom" and selKey == cfId)
            y = y + LEFT_ROW_H
        end

        -- Debuffs: a single "Blacklist" entry — the per-mode non-secret debuff
        -- hide list. Buffs above are whitelist-by-design; this is the one
        -- debuff-side control that belongs on the Filter Designer.
        y = y + 8
        debuffLabel:ClearAllPoints()
        debuffLabel:SetPoint("TOPLEFT", 6, -(y + 4))
        y = y + SECTION_H

        used = used + 1
        do
            local hidden, total = BlacklistCounts()
            BindLeftRow(AcquireLeftRow(used), y, "blacklist", "blacklist",
                L["Blacklist"], hidden .. "/" .. total, false,
                selKind == "blacklist")
            y = y + LEFT_ROW_H
        end

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

        -- Banner reflects the selection's polarity: caution/opt-out copy for the
        -- blacklist, the default whitelist copy for buff filters.
        if isBlacklist then
            banner:SetTone("caution")
            banner:SetHTML(BLACKLIST_BANNER, fdBannerLinkClick)
        else
            banner:SetTone("info")
            banner:SetHTML(BUFF_BANNER, fdBannerLinkClick)
        end

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
            titleText:SetText(L["Debuff Blacklist"])
            local hidden, total = BlacklistCounts()
            countText:SetText(format(L["%d of %d hidden"], hidden, total))
        else
            local f = R:GetCustomFilter(selKey)
            titleText:SetText(f and (f.name or selKey) or "")
            countText:SetText(format(L["%d spells"], f and CustomSpellCount(f) or 0))
        end

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
    pageRef._fdSelectBlacklist = function() SelectFilter("blacklist", "blacklist") end
    -- The buff-side "Customise" button: keep the user's last buff filter, but if
    -- they're parked on the (debuff) Blacklist, move to the first buff preset so
    -- "Customise" from the buff section never lands on a debuff view.
    pageRef._fdSelectBuffs = function()
        if selKind == "blacklist" then
            SelectFilter("preset", R.Categories[1] and R.Categories[1].key)
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
