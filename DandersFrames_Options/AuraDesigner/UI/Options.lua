-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames

-- ============================================================
-- AURA DESIGNER - OPTIONS GUI
-- Custom S.page layout: left content area + fixed 280px right panel
-- Called from Options/Options.lua via DF.BuildAuraDesignerPage()
-- ============================================================

local pairs, ipairs, type = pairs, ipairs, type
local format = string.format
local wipe = wipe
local tinsert = table.insert
local tremove = table.remove
local max, min, floor = math.max, math.min, math.floor
local strsplit = strsplit
local sort = table.sort
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local LOCALIZED_CLASS_NAMES_MALE = LOCALIZED_CLASS_NAMES_MALE
local L = DF.L

-- Mutable editor state.
-- These were file-scope locals. A `local` re-declared on the far side of a
-- file split becomes a SECOND variable, so the halves silently stop sharing
-- state -- no error, just a tab that will not switch or a preview that will
-- not refresh. One table keeps a split honest: each part reads the same
-- state via `local S = DF.AuraDesigner._uiState`.
-- GUI and Adapter are NOT here: both are load-time constants (DF.GUI and
-- DF.AuraDesigner.Adapter), so each part can simply re-declare them.
-- Shared private helpers.
-- A `local function` is invisible to any other file, so a helper called far
-- from its declaration pins this file together -- it cannot be split while a
-- later section still calls it. This editor is densely coupled: 75 helpers
-- reach across the chosen boundaries. Publishing them lets each part
-- re-declare `local X = P.X` -- the same function object, so no call site
-- changes and behaviour is identical.
-- Private by convention -- nothing outside AuraDesigner/ should touch this.
local P = {}
local S = {}
DF.AuraDesigner = DF.AuraDesigner or {}
DF.AuraDesigner._uiState = S
DF.AuraDesigner._priv    = P

-- Load-time constants. Both used to be assigned inside BuildAuraDesignerPage,
-- which made them mutable and so un-splittable. Neither ever actually varies:
-- every caller arrives as DF.GUI -> SetupGUIPages -> here, and Adapter was only
-- ever assigned DF.AuraDesigner.Adapter. Resolving them at load lets each split
-- part re-declare them as plain aliases -- which is why 412 of this file's
-- reference sites needed no change at all.
-- Both source files load earlier in the TOC, so these are populated here.
local GUI = DF.GUI
local Adapter = DF.AuraDesigner.Adapter
-- (S.page and S.db are set per build on the state table)

-- State
S.selectedSpec = nil         -- Current spec key being viewed

-- Reusable color constants: reference the shared GUI palette (same numeric
-- values, zero visual change) so they track any future palette change in
-- lockstep. GUI.lua loads before this file (see .toc), so DF.GUI.Colors is
-- populated at parse time.
local C_BACKGROUND = DF.GUI.Colors.background
-- (C_PANEL removed — unreferenced; reclaimed for the 200-locals ceiling.)
local C_ELEMENT    = DF.GUI.Colors.element
local C_BORDER     = DF.GUI.Colors.border
local C_HOVER      = DF.GUI.Colors.hover
local C_TEXT       = DF.GUI.Colors.text
local C_TEXT_DIM   = DF.GUI.Colors.textDim

-- Indicator type definitions
-- These option/label tables read L["..."]; at file scope that returns the enUS
-- baseline (the languageOverride overlay runs later, at ADDON_LOADED). Build
-- them in a registered refresh fn so Core rebuilds them after the overlay —
-- otherwise these dropdowns stay English. Value-keys (CENTER, RIGHT, …) and
-- the _order arrays are raw identifiers and must NOT be localized.
-- One namespace table instead of one local per option table (the main chunk
-- rides the Lua 5.1 200-locals ceiling; seven locals reclaimed to one).
local OPTS = {}
P.OPTS = OPTS

local function RefreshLocaleStrings()
    OPTS.INDICATOR_TYPES = {
        { key = "icon",       label = L["Icon"],             placed = true  },
        { key = "square",     label = L["Square"],           placed = true  },
        { key = "bar",        label = L["Bar"],              placed = true  },
        { key = "border",     label = L["Border"],           placed = false },
        { key = "healthbar",  label = L["Health Bar Color"], placed = false },
        { key = "background", label = L["Background Color"],  placed = false },
        { key = "nametext",   label = L["Name Text Color"],  placed = false },
        { key = "healthtext", label = L["Health Text Color"], placed = false },
        -- (framealpha removed 2026-07-25 — 12.1 casualty, see the Factory's CASUALTIES note.
        --  Whole-frame alpha needs frame:SetAlpha gated on SECRET aura presence, and it also
        --  fights the range / out-of-range alpha owners for the same property. It never had a
        --  render path on the container engine — only the editor canvas applied it — so the
        --  effect showed in the preview and did nothing in game.)
        { key = "sound",      label = L["Sound Alert"],      placed = false },
    }

    OPTS.ANCHOR_OPTIONS = {
        CENTER = L["Center"], TOP = L["Top"], BOTTOM = L["Bottom"], LEFT = L["Left"], RIGHT = L["Right"],
        TOPLEFT = L["Top Left"], TOPRIGHT = L["Top Right"], BOTTOMLEFT = L["Bottom Left"], BOTTOMRIGHT = L["Bottom Right"],
        _order = {"TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT"},
    }

    OPTS.GROWTH_OPTIONS = {
        RIGHT = L["Right"], LEFT = L["Left"], UP = L["Up"], DOWN = L["Down"],
        _order = {"RIGHT", "LEFT", "UP", "DOWN"},
    }

    OPTS.BORDER_STYLE_OPTIONS = {
        SOLID = L["Solid Border"], ANIMATED = L["Animated Border"], DASHED = L["Dashed Border"],
        GLOW = L["Glow"], CORNERS = L["Corners Only"],
        _order = {"SOLID", "ANIMATED", "DASHED", "GLOW", "CORNERS"},
    }

    OPTS.HEALTHBAR_MODE_OPTIONS = {
        Replace = L["Replace"], Tint = L["Tint"],
        _order = {"Replace", "Tint"},
    }

    OPTS.BAR_ORIENT_OPTIONS = {
        HORIZONTAL = L["Horizontal"], VERTICAL = L["Vertical"],
        _order = {"HORIZONTAL", "VERTICAL"},
    }

    -- Per-group Sort Order (Wave 2) — mirrors the aura rows' dropdown exactly.
    OPTS.SORT_OPTIONS = {
        DEFAULT = L["Default (Slot Order)"], TIME = L["Time Remaining"], NAME = L["Alphabetical"],
        APPLIED = L["Order Applied"],
        _order = {"DEFAULT", "TIME", "NAME", "APPLIED"},
    }
end

RefreshLocaleStrings()
DF:RegisterLocaleRefresh(RefreshLocaleStrings)


local function GetAuraDesignerDB()
    -- The editor is mode-tabbed: it edits the preset the active mode uses
    -- (party → its assigned preset, etc.). Because edited == used, live
    -- frames stay in sync with the editor automatically.
    -- Base variant: the editor edits your base raid preset, not the active runtime
    -- auto-layout's overlay (it edits the layout only while IN edit-auto-layout).
    local adDB
    if DF.GetModeBaseAuraDesigner then
        local mode = (GUI and GUI.SelectedMode) or "party"
        adDB = DF:GetModeBaseAuraDesigner(mode)
    end
    -- Pre-migration / very-early fallback to the legacy inline config.
    adDB = adDB or (S.db and S.db.auraDesigner)
    -- The migrations now live in AuraDesigner/Migrations.lua, which stays
    -- resident so saved data is migrated whether or not this editor is loaded.
    -- Same functions, reached by their published names instead of file locals.
    if adDB and (not adDB._specScopedV1 or not adDB._specScopedV2) then
        DF.MigrateAuraDesignerSpecScope(adDB)
    end
    DF.MigrateAuraDesignerInstancesLazy(adDB)
    DF.MigrateAuraDesignerBorderKeysLazy(adDB)
    DF.MigrateAuraDesignerPrioritiesLazy(adDB)
    -- MUST match the render-path list in Factory.lua exactly. If the editor resolves an adDB
    -- the render has not touched yet (a preset, or an auto-layout overlay not currently shown)
    -- and skips a migration, the editor shows UN-migrated values -- and anything saved from that
    -- state gets migrated a second time when the render finally runs.
    DF.MigrateAuraDesignerAbsoluteLevelsLazy(adDB)
    DF.MigrateAuraDesignerAbsoluteLevelsV2Lazy(adDB)
    DF.MigrateAuraDesignerDefaultRefreshLazy(adDB)
    return adDB
end
P.GetAuraDesignerDB = GetAuraDesignerDB

local function GetThemeColor()
    return GUI.GetThemeColor()
end
P.GetThemeColor = GetThemeColor

local function ApplyBackdrop(frame, bgColor, borderColor)
    -- Build through the shared GUI backdrop once per frame, then push only
    -- vertex colours below. SetBackdrop is a full rebuild, so keeping it off the
    -- re-render path still matters when the AD effects list rebuilds.
    if not frame.dfAD_backdropApplied then
        DF.GUI:CreateElementBackdrop(frame)
        frame.dfAD_backdropApplied = true
    end

    if bgColor then
        local r, g, b = bgColor.r, bgColor.g, bgColor.b
        local a = bgColor.a or 1
        if frame.dfAD_bgR ~= r or frame.dfAD_bgG ~= g or frame.dfAD_bgB ~= b or frame.dfAD_bgA ~= a then
            frame:SetBackdropColor(r, g, b, a)
            frame.dfAD_bgR, frame.dfAD_bgG, frame.dfAD_bgB, frame.dfAD_bgA = r, g, b, a
        end
    end

    if borderColor then
        local r, g, b = borderColor.r, borderColor.g, borderColor.b
        local a = borderColor.a or 1
        if frame.dfAD_borderR ~= r or frame.dfAD_borderG ~= g or frame.dfAD_borderB ~= b or frame.dfAD_borderA ~= a then
            frame:SetBackdropBorderColor(r, g, b, a)
            frame.dfAD_borderR, frame.dfAD_borderG, frame.dfAD_borderB, frame.dfAD_borderA = r, g, b, a
        end
    end
end
P.ApplyBackdrop = ApplyBackdrop

-- ============================================================
-- COLLAPSIBLE CARD SHELL
-- The effects list, the groups list and the debuff-category list each build the
-- same thing: a card pinned to the parent's width, a 30px header button on top,
-- and a chevron at its left edge that flips with the expanded state. Past that
-- point the three diverge completely -- a spell icon and type badge, a group
-- name and link count, a list of categories -- so this owns only the shell and
-- hands back the chevron for the caller to anchor its own content to.
--
-- opts = { yPos, expanded, borderColor, chevronColor (default C_TEXT_DIM) }
-- Returns card, header, chevron.
-- ============================================================
local CARD_HEADER_HEIGHT = 30
local CHEVRON_EXPANDED = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more"
local CHEVRON_COLLAPSED = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right"

local function CreateCardShell(parent, opts)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetPoint("TOPLEFT", 8, opts.yPos)
    card:SetPoint("RIGHT", parent, "RIGHT", -8, 0)

    local header = CreateFrame("Button", nil, card, "BackdropTemplate")
    header:SetHeight(CARD_HEADER_HEIGHT)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    ApplyBackdrop(header, C_ELEMENT, opts.borderColor)

    local chevron = header:CreateTexture(nil, "OVERLAY")
    chevron:SetSize(12, 12)
    chevron:SetPoint("LEFT", 8, 0)
    chevron:SetTexture(opts.expanded and CHEVRON_EXPANDED or CHEVRON_COLLAPSED)
    local cc = opts.chevronColor or C_TEXT_DIM
    chevron:SetVertexColor(cc.r, cc.g, cc.b)

    return card, header, chevron
end
P.CreateCardShell = CreateCardShell

-- ============================================================
-- CARD STACK (in-place reflow of a card list)
-- The groups list and the debuff-category list both stack their cards by hand:
-- each card is pinned at a running y offset, sized once its body is built, and
-- the accumulator carries the next card's offset. That is fine at build time and
-- useless afterwards -- a card whose body changes height (a collapsible section
-- swapping its widget set) leaves every card BELOW it anchored where the old
-- height put them, which is why those edits used to rebuild the whole tab via
-- S.SwitchTab. This owns the re-anchor pass so they don't have to.
--
--   local stack = CreateCardStack(parent, yPos)   -- yPos = the FIRST card's offset
--   stack:Add(card)                               -- once per card, in visual order
--   stack:Reflow()                                -- after any card's height changes
--
-- Reflow reads each card's CURRENT height, so the caller only has to keep the
-- card itself correctly sized. Card gap (5) and the parent's bottom padding (20)
-- mirror the build-time loop exactly.
-- ============================================================
local CARD_GAP = 5

local function CreateCardStack(parent, topY)
    local stack = { cards = {} }

    function stack:Add(card)
        tinsert(self.cards, card)
    end

    function stack:Reflow()
        local y = topY
        for _, card in ipairs(self.cards) do
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
            card:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
            y = y - card:GetHeight() - CARD_GAP
        end
        parent:SetHeight(max(-y + 20, 200))
        -- Content that SHRANK leaves the scroll frame parked past its new end.
        -- Clamp it the same way S.SwitchTab does after a rebuild.
        if S.tabScrollFrame then
            local sf = S.tabScrollFrame
            sf:SetVerticalScroll(min(sf:GetVerticalScroll(), sf:GetVerticalScrollRange()))
        end
    end

    return stack
end
P.CreateCardStack = CreateCardStack

-- ============================================================
-- BUFF COEXISTENCE POPUP
-- Shown once when the user enables Aura Designer, asking whether
-- to keep standard buff icons or let AD fully replace them.
-- ============================================================

-- (S.buffCoexistPopup declared on the state table)

local function ShowBuffCoexistPopup(onConfirm, onCancel)
    if not S.buffCoexistPopup then
        local f = CreateFrame("Frame", "DFADBuffPopup", UIParent, "BackdropTemplate")
        f:SetSize(420, 130)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetFrameLevel(250)
        f:EnableMouse(true)
        local tc = GetThemeColor()
        ApplyBackdrop(f, {r = 0.10, g = 0.10, b = 0.10, a = 0.98}, {r = tc.r, g = tc.g, b = tc.b, a = 1})

        -- Thin accent stripe along the top
        local stripe = f:CreateTexture(nil, "OVERLAY")
        stripe:SetColorTexture(tc.r, tc.g, tc.b, 0.8)
        stripe:SetHeight(2)
        stripe:SetPoint("TOPLEFT", 1, -1)
        stripe:SetPoint("TOPRIGHT", -1, -1)
        f._stripe = stripe

        local title = f:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        title:SetPoint("TOP", 0, -12)
        title:SetText(L["Aura Designer"])
        title:SetTextColor(tc.r, tc.g, tc.b)

        local desc = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        desc:SetPoint("TOP", title, "BOTTOM", 0, -6)
        desc:SetWidth(390)
        desc:SetText(L["Would you like to keep standard buff icons alongside\nAura Designer, or let it fully replace them?"])
        desc:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        desc:SetJustifyH("CENTER")

        local function MakeButton(parent, text, xOff)
            local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
            btn:SetPoint("BOTTOM", parent, "BOTTOM", xOff, 14)
            DF.GUI:StyleButton(btn, { width = 170, height = 28, text = text })
            btn.text = btn.Text
            return btn
        end

        f.keepBtn = MakeButton(f, L["Keep Buffs"], -95)
        f.replaceBtn = MakeButton(f, L["Replace Buffs"], 95)

        -- Close on Escape. SetPropagateKeyboardInput is protected in combat
        -- for insecure code: skip it there (keys propagate anyway — ESC just
        -- hides the popup).
        f:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
                self:Hide()
                if self._onCancel then self._onCancel() end
            else
                if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
            end
        end)

        S.buffCoexistPopup = f
    end

    local f = S.buffCoexistPopup
    f._onCancel = onCancel

    f.keepBtn:SetScript("OnClick", function()
        f:Hide()
        if onConfirm then onConfirm(true) end
    end)
    f.replaceBtn:SetScript("OnClick", function()
        f:Hide()
        if onConfirm then onConfirm(false) end
    end)

    f:Show()
end
P.ShowBuffCoexistPopup = ShowBuffCoexistPopup

-- Get or resolve the active spec key from settings
local function ResolveSpec()
    local adDB = GetAuraDesignerDB()
    if adDB.spec == "auto" then
        return Adapter:GetPlayerSpec()
    end
    return adDB.spec
end
P.ResolveSpec = ResolveSpec

-- Track which spec aura tables have already been sanitized this session
local sanitizedSpecAuras = {}

-- Returns the spec-scoped auras sub-table, creating it if needed
-- Also sanitizes corrupted entries (non-table values like stray nextIndicatorID)
local function GetSpecAuras(spec)
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    if not adDB.auras then adDB.auras = {} end
    spec = spec or ResolveSpec()
    if not spec then return {} end
    if not adDB.auras[spec] then adDB.auras[spec] = {} end
    local specAuras = adDB.auras[spec]
    -- One-time cleanup: remove non-table entries that ended up at the wrong level
    if not sanitizedSpecAuras[specAuras] then
        local toRemove
        for k, v in pairs(specAuras) do
            if type(v) ~= "table" then
                if not toRemove then toRemove = {} end
                toRemove[#toRemove + 1] = k
            end
        end
        if toRemove then
            for _, k in ipairs(toRemove) do
                specAuras[k] = nil
            end
            DF:DebugWarn("AD", "Cleaned %d corrupted entries from spec auras table", #toRemove)
        end
        sanitizedSpecAuras[specAuras] = true
    end
    return specAuras
end
P.GetSpecAuras = GetSpecAuras

-- Returns the spec-INDEPENDENT "Other Buffs" pool (B1): a flat map auraName -> auraCfg
-- with the EXACT record shape of adDB.auras[spec] entries (indicators array, frame-level
-- sub-tables, sound, priority, nextIndicatorID), created + sanitized like GetSpecAuras.
-- Deliberately a SIBLING key of adDB.auras (never a pseudo-spec inside it) so every
-- adDB.auras consumer stays spec-scoped; a future per-spec expansion of this pool would
-- land under its own sibling key, so this flat map never needs a migration. Aura names
-- here must be SpellDB names (rec.n / localized) or ad-hoc "#<id>" keys — identity
-- resolves spec-independently via DF:BuildADIdentityFilters(nil, name).
-- (B2 wires the Other Buffs tab/editor to this accessor; the factory reads
-- adDB.otherAuras directly, mirroring how it reads adDB.auras[spec].)
local function GetOtherAuras()
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    if not adDB.otherAuras then adDB.otherAuras = {} end
    local otherAuras = adDB.otherAuras
    -- One-time cleanup, same as GetSpecAuras (registry is keyed by table identity, so
    -- profile/preset switches re-sanitize the new table naturally).
    if not sanitizedSpecAuras[otherAuras] then
        local toRemove
        for k, v in pairs(otherAuras) do
            if type(v) ~= "table" then
                if not toRemove then toRemove = {} end
                toRemove[#toRemove + 1] = k
            end
        end
        if toRemove then
            for _, k in ipairs(toRemove) do
                otherAuras[k] = nil
            end
            DF:DebugWarn("AD", "Cleaned %d corrupted entries from other auras table", #toRemove)
        end
        sanitizedSpecAuras[otherAuras] = true
    end
    return otherAuras
end
P.GetOtherAuras = GetOtherAuras

-- Returns the preset's DEBUFF CATEGORY GROUPS array (C1): a flat, spec-INDEPENDENT
-- array of group records (mirror of the otherAuras siblings-not-pseudo-spec rule —
-- a future per-spec expansion would land under its own key, so this array never
-- needs a migration). Lazily created on first WRITE access only — merely opening
-- the editor must not create adDB.debuffGroups (mirror GetOtherAuras). Each record:
-- { id, name, enabled, anchor, offsetX, offsetY, growDirection, iconsPerRow,
--   spacing, iconSize, maxIcons, selection = { boss, role, priority, crowdControl,
--   raid, dispellable, dispellableMode, hideLong, hideLongMinutes, keepImportant } }.
-- The factory reads adDB.debuffGroups directly (as it reads otherAuras); the
-- C2 group editor reaches it via CreateDebuffGroup / DebuffGroupsRead.
local function GetDebuffGroups()
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    if not adDB.debuffGroups then adDB.debuffGroups = {} end
    local groups = adDB.debuffGroups
    -- One-time cleanup, same table-identity registry as GetSpecAuras/GetOtherAuras
    -- (profile/preset switches swap the table and re-sanitize naturally).
    if not sanitizedSpecAuras[groups] then
        for i = #groups, 1, -1 do
            if type(groups[i]) ~= "table" then
                tremove(groups, i)
                DF:DebugWarn("AD", "Removed corrupted debuff group entry at index %d", i)
            end
        end
        sanitizedSpecAuras[groups] = true
    end
    return groups
end

-- Default DISPLAY NAME for a new group: one above the HIGHEST number currently in
-- use for this prefix.
--
-- The id counters (nextLayoutGroupID / nextOtherLayoutGroupID / nextDebuffGroupID)
-- stay strictly monotonic on purpose — ids are stable references (indicator ->
-- group links), so reusing one would rebind stale links to the wrong group. The
-- visible LABEL has no such constraint, and deriving it from the raw id made it
-- climb forever ("Group 7" on an empty designer after six create/deletes).
--
-- Why highest+1 and NOT the lowest free number: the list renders in CREATION order
-- (every site iterates ipairs(groups); nothing sorts them) and new groups are
-- tinsert-APPENDED. Filling a gap would therefore drop a low number at the BOTTOM
-- of the list — "Group 2" above "Group 1" — which reads worse than a gap. A gap is
-- also honest: it says something was deleted. Because this scans the CURRENT set
-- rather than a persisted counter, an emptied designer still restarts at 1.
--
-- Prefixes are distinct and anchored, so "Group" won't match "Filter Group 3" (or
-- vice versa); none contain Lua pattern magic characters. A user-renamed group drops
-- out of the numbering pool.
local function NextGroupName(groups, prefix)
    local highest = 0
    for _, g in ipairs(groups or {}) do
        local n = tonumber(tostring((g and g.name) or ""):match("^" .. prefix .. " (%d+)$"))
        if n and n > highest then highest = n end
    end
    return prefix .. " " .. (highest + 1)
end
P.NextGroupName = NextGroupName

-- Create a new debuff category group (C1 data model; C2 wires the UI). Defaults:
-- Boss + Role selected (the classic "important debuffs" baseline), everything
-- else off, Hide Long staged at 5 minutes with Keep Important on. Layout mirrors
-- the filter-group creation defaults (compact 4x4).
local function CreateDebuffGroup(name)
    local adDB = GetAuraDesignerDB()
    if not adDB then return nil end
    local groups = GetDebuffGroups()
    if not adDB.nextDebuffGroupID then adDB.nextDebuffGroupID = 1 end
    local id = adDB.nextDebuffGroupID
    adDB.nextDebuffGroupID = id + 1
    local group = {
        id = id,
        name = name or NextGroupName(groups, "Debuff Group"),
        anchor = "TOPLEFT",
        offsetX = 0,
        offsetY = 0,
        growDirection = "RIGHT_DOWN",
        iconsPerRow = 4,
        spacing = 2,
        iconSize = 24,
        maxIcons = 4,
        selection = {
            boss = true, role = true, priority = false, crowdControl = false,
            raid = false, dispellable = false, dispellableMode = "PLAYER",
            hideLong = false, hideLongMinutes = 5, keepImportant = true,
        },
    }
    tinsert(groups, group)
    return group
end
P.CreateDebuffGroup = CreateDebuffGroup

-- Returns the spec-scoped layout groups array, creating it if needed
local function GetSpecLayoutGroups(spec)
    local adDB = GetAuraDesignerDB()
    if not adDB then return {} end
    if not adDB.layoutGroups then adDB.layoutGroups = {} end
    spec = spec or ResolveSpec()
    if not spec then return {} end
    if not adDB.layoutGroups[spec] then adDB.layoutGroups[spec] = {} end
    return adDB.layoutGroups[spec]
end
P.GetSpecLayoutGroups = GetSpecLayoutGroups

-- ============================================================
-- MAIN POOL TABS (B2) — My Buffs / Other Buffs
-- The tab strip above the workspace decides which aura pool the ENTIRE
-- editor operates on: "my" = the spec-scoped adDB.auras[spec] pool,
-- "other" = the spec-INDEPENDENT adDB.otherAuras pool (B1). Every editor
-- read routes through CurrentAuraPool(); spec-only surfaces (layout
-- groups, migrations, the spec dropdown itself) deliberately do not.
-- ============================================================

S.activeBuffTab = "my"   -- "my" | "debuffs" | "other"

local function IsOtherTab()
    return S.activeBuffTab == "other"
end
P.IsOtherTab = IsOtherTab

-- C2: the Debuffs tab hosts debuff CATEGORY groups (spec-independent, no
-- spell pool, no placed indicators). Its Effects sub-tab frosts, the spec
-- dropdown greys, and CurrentAuraPool reads empty.
local function IsDebuffTab()
    return S.activeBuffTab == "debuffs"
end
P.IsDebuffTab = IsDebuffTab

-- Read-only placeholder returned while the other pool doesn't exist yet.
-- Merely VISITING the Other Buffs tab must not create adDB.otherAuras —
-- only the first ADD does (via CurrentAuraPoolWrite). Never written.
local EMPTY_POOL = {}
P.EMPTY_POOL = EMPTY_POOL

-- READ access to the active tab's pool. Never creates adDB.otherAuras.
-- `spec` is forwarded to GetSpecAuras on the My Buffs tab only.
local function CurrentAuraPool(spec)
    if S.activeBuffTab == "other" then
        local adDB = GetAuraDesignerDB()
        if adDB and adDB.otherAuras then return GetOtherAuras() end
        return EMPTY_POOL
    end
    -- The Debuffs tab has no aura pool: no placed indicators and no
    -- frame-level effects, so every pool-routed surface (preview passes,
    -- effect list) reads empty. Category groups live in adDB.debuffGroups.
    if S.activeBuffTab == "debuffs" then return EMPTY_POOL end
    return GetSpecAuras(spec)
end
P.CurrentAuraPool = CurrentAuraPool

-- WRITE access: creates the pool table (the other pool is born lazily on
-- the first add — drag-drop, picker click, or add-by-ID).
local function CurrentAuraPoolWrite()
    if S.activeBuffTab == "other" then return GetOtherAuras() end
    return GetSpecAuras()
end

-- B1 key-prefix contract: wherever an editor key embeds an aura's name,
-- the other-pool record embeds "other:" .. auraName in the name segment
-- (expandedCards "placed:other:<name>#<id>" / "frame:<type>:other:<name>",
-- preview slot keys). The auraName itself never carries the prefix.
local function PoolKeyPrefix()
    return (S.activeBuffTab == "other") and "other:" or ""
end
P.PoolKeyPrefix = PoolKeyPrefix

-- READ access to the debuff category groups array (C2). Never creates
-- adDB.debuffGroups — merely visiting the Debuffs tab must not write
-- (the EMPTY_POOL rule above); the first "+ Debuff Group" add creates it
-- via CreateDebuffGroup → GetDebuffGroups.
local function DebuffGroupsRead()
    local adDB = GetAuraDesignerDB()
    if adDB and adDB.debuffGroups then return GetDebuffGroups() end
    return EMPTY_POOL
end
P.DebuffGroupsRead = DebuffGroupsRead

-- Other Buffs LAYOUT GROUPS: a flat, spec-INDEPENDENT array of group records
-- over the other pool (sibling of otherAuras/debuffGroups — never a pseudo-spec
-- inside adDB.layoutGroups, so no migration can ever touch it). Records are
-- shape-identical to the spec-keyed layoutGroups entries (member kind with
-- {auraName, indicatorID} members referencing OTHER-pool placed indicators,
-- and filter kind with filterSelection). Own id counter
-- (adDB.nextOtherLayoutGroupID — ids can collide with the spec counter's, so
-- every derived key carries a pool marker). One accessor for both access
-- modes (the file-scope 200-locals ceiling forbids the two-function
-- GetDebuffGroups/DebuffGroupsRead split): `create` follows the lazy-write
-- rule — read access returns EMPTY_POOL while the store doesn't exist
-- (visiting the tab must never create it; the first "+ Create/Filter Group"
-- add passes create=true).
local function GetOtherLayoutGroups(create)
    local adDB = GetAuraDesignerDB()
    if not adDB then return EMPTY_POOL end
    if not adDB.otherLayoutGroups then
        if not create then return EMPTY_POOL end
        adDB.otherLayoutGroups = {}
    end
    local groups = adDB.otherLayoutGroups
    -- One-time cleanup, same table-identity registry as GetDebuffGroups.
    if not sanitizedSpecAuras[groups] then
        for i = #groups, 1, -1 do
            if type(groups[i]) ~= "table" then
                tremove(groups, i)
                DF:DebugWarn("AD", "Removed corrupted other layout group entry at index %d", i)
            end
        end
        sanitizedSpecAuras[groups] = true
    end
    return groups
end
P.GetOtherLayoutGroups = GetOtherLayoutGroups

-- Active tab's layout groups (READ — never creates the other store): the
-- flat other store on Other Buffs, the spec-keyed array on My Buffs.
-- (Debuffs never reaches these — its Layout Groups tab builds debuff
-- category groups instead.)
local function CurrentLayoutGroups()
    if S.activeBuffTab == "other" then return GetOtherLayoutGroups(false) end
    return GetSpecLayoutGroups()
end
P.CurrentLayoutGroups = CurrentLayoutGroups

-- Display name for an OTHER-pool aura key: ad-hoc "#<id>" resolves live,
-- SpellDB names resolve through GetSpellDisplay (localized), else the raw key.
local function OtherPoolDisplayName(auraName)
    local id = type(auraName) == "string" and auraName:match("^#(%d+)$")
    if id then
        local live = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(tonumber(id))
        return live or auraName
    end
    local R = DF.FilterRegistry
    local rec = R and R.GetSpellByName and R:GetSpellByName(auraName)
    if rec then
        local display = R:GetSpellDisplay(rec)
        if display then return display end
    end
    return auraName
end
P.OtherPoolDisplayName = OtherPoolDisplayName

-- Union of every spell ID tracked by one pool of an adDB (cross-tab
-- used-affordance). which = "my" walks ALL spec pools (the preset object is
-- one: a spell tracked for ANY spec would double-render for that spec when
-- also in the shared other pool); "other" walks the flat other pool with
-- nil-spec identity. Pure (no editor state) — exposed for the SDD harness.
local function PoolTrackedIDs(adDB, which)
    local out = {}
    if type(adDB) ~= "table" then return out end
    local function addIDs(spec, auraName)
        local f = DF:BuildADIdentityFilters(spec, auraName)
        local map = f and f.includeSpellIDs
        if map then
            for id in pairs(map) do out[id] = true end
        end
    end
    if which == "my" then
        if type(adDB.auras) == "table" then
            for specKey, specAuras in pairs(adDB.auras) do
                if type(specAuras) == "table" then
                    for auraName, cfg in pairs(specAuras) do
                        if type(cfg) == "table" then addIDs(specKey, auraName) end
                    end
                end
            end
        end
    else -- "other"
        if type(adDB.otherAuras) == "table" then
            for auraName, cfg in pairs(adDB.otherAuras) do
                if type(cfg) == "table" then addIDs(nil, auraName) end
            end
        end
    end
    return out
end
DF.ADEditor_PoolTrackedIDs = PoolTrackedIDs

-- IDs tracked by the OPPOSITE pool of the active tab (drives the picker's
-- cross-tab blocked rows and the add-by-ID gate).
local function CrossPoolTrackedIDs()
    return PoolTrackedIDs(GetAuraDesignerDB(), IsOtherTab() and "my" or "other")
end
P.CrossPoolTrackedIDs = CrossPoolTrackedIDs

-- Ensure an aura config table exists, creating it with defaults if needed.
-- `pool` (optional) pins the target pool — proxies capture their pool at
-- creation so a stale color-picker callback can't write across tabs.
local function EnsureAuraConfig(auraName, pool)
    local auras = pool or CurrentAuraPoolWrite()
    if not auras[auraName] then
        auras[auraName] = {
            priority = 5,
        }
    end
    return auras[auraName]
end
P.EnsureAuraConfig = EnsureAuraConfig

-- Ensure a type sub-table exists within an aura config
local function EnsureTypeConfig(auraName, typeKey, pool)
    local auraCfg = EnsureAuraConfig(auraName, pool)
    if not auraCfg[typeKey] then
        -- Read global defaults so new configs inherit user-configured values
        local adDB = GetAuraDesignerDB()
        local gd = adDB and adDB.defaults or {}

        -- Create default config for each type
        if typeKey == "icon" then
            auraCfg[typeKey] = {
                -- Placement
                anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
                -- Size & appearance (from global defaults)
                size = gd.iconSize or 24, scale = gd.iconScale or 1.0, alpha = 1.0,
                -- Border
                -- Canonical border keys (Stage 5.1b/c). Legacy names were
                -- borderEnabled / borderThickness / borderInset; migrated
                -- via DF:MigrateAuraDesignerIconBorderKeys on ADDON_LOADED.
                -- ShowBorder/BorderSize/BorderInset are stored on the
                -- aura's icon sub-config; everything else (style, colour,
                -- gradient, shadow, offset, blend) reads from TYPE_DEFAULTS
                -- via proxy fall-through until the user overrides it.
                -- Seed Show/Size from the global icon-border defaults so the
                -- "Import Buffs Tab Defaults" border toggle actually carries over.
                ShowBorder = (gd.iconBorderEnabled ~= false), BorderSize = gd.iconBorderThickness or 1, BorderInset = 0,
                hideSwipe = false,
                -- Duration text
                showDuration = gd.showDuration ~= false,
                durationFont = gd.durationFont or "DF Roboto SemiBold",
                durationScale = gd.durationScale or 1.0,
                durationOutline = gd.durationOutline or "SHADOW;OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,   -- DELIBERATE hardcode (v4 parity): new placements always start coloured, even in profiles whose global default is OFF — Krathe's call. Already-placed indicators are never touched.
                -- Stack count
                showStacks = gd.showStacks ~= false,
                stackFont = gd.stackFont or "DF Roboto SemiBold",
                stackScale = gd.stackScale or 1.0,
                stackOutline = gd.stackOutline or "SHADOW;OUTLINE",
                stackAnchor = "BOTTOMRIGHT",
                stackX = 2, stackY = -2,
                }
        elseif typeKey == "square" then
            auraCfg[typeKey] = {
                -- Placement
                anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
                -- Appearance (from global defaults)
                size = gd.iconSize or 24, scale = gd.iconScale or 1.0, alpha = 1.0,
                color = {r = 1, g = 1, b = 1, a = 1},
                -- Border (canonical keys, Stage 5.2; legacy migrated on load)
                ShowBorder = true, BorderSize = 1, BorderInset = 0,
                hideSwipe = false,
                -- Duration text
                showDuration = gd.showDuration ~= false,
                durationFont = gd.durationFont or "DF Roboto SemiBold",
                durationScale = gd.durationScale or 1.0,
                durationOutline = gd.durationOutline or "SHADOW;OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,   -- DELIBERATE hardcode (v4 parity): new placements always start coloured, even in profiles whose global default is OFF — Krathe's call. Already-placed indicators are never touched.
                -- Stack count
                showStacks = gd.showStacks ~= false,
                stackFont = gd.stackFont or "DF Roboto SemiBold",
                stackScale = gd.stackScale or 1.0,
                stackOutline = gd.stackOutline or "SHADOW;OUTLINE",
                stackAnchor = "BOTTOMRIGHT",
                stackX = 2, stackY = -2,
                }
        elseif typeKey == "bar" then
            auraCfg[typeKey] = {
                -- Placement
                anchor = "BOTTOM", offsetX = 0, offsetY = 0,
                -- Size & orientation
                orientation = "HORIZONTAL", width = 60, height = 6,
                matchFrameWidth = true, matchFrameHeight = false,
                matchInset = 0,   -- extra per-side trim on the matched axes (see resolveBarSize)
                -- Texture & colors
                texture = "Interface\\TargetingFrame\\UI-StatusBar",
                fillColor = {r = 1, g = 1, b = 1, a = 1},
                bgColor = {r = 0, g = 0, b = 0, a = 0.5},
                -- Border (canonical keys, Stage 5.3; legacy migrated on load)
                ShowBorder = true, BorderSize = 1, BorderInset = 0,
                BorderColor = {r = 0, g = 0, b = 0, a = 1},
                -- Alpha
                alpha = 1.0,
                -- Bar color by time
                barColorByTime = false,
                -- Duration text
                showDuration = true,
                durationFont = gd.durationFont or "DF Roboto SemiBold",
                durationScale = gd.durationScale or 1.0,
                durationOutline = gd.durationOutline or "SHADOW;OUTLINE",
                durationAnchor = "CENTER", durationX = 0, durationY = 0,
                durationColorByTime = true,   -- DELIBERATE hardcode (v4 parity): new placements always start coloured, even in profiles whose global default is OFF — Krathe's call. Already-placed indicators are never touched.
            }
        elseif typeKey == "border" then
            auraCfg[typeKey] = {
                -- Border (canonical keys, Stage 5.4; legacy style/thickness/
                -- inset/color migrated on load)
                ShowBorder = true, BorderStyle = "SOLID", BorderSize = 2, BorderInset = 0,
                BorderColor = {r = 1, g = 1, b = 1, a = 1},
                drawAboveFrameBorder = true,
                showWhenMissing = false,
            }
        elseif typeKey == "healthbar" then
            auraCfg[typeKey] = {
                mode = "Replace", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
                tintWholeBar = false,
                showWhenMissing = false,
            }
        elseif typeKey == "background" then
            auraCfg[typeKey] = {
                mode = "Tint", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
                showWhenMissing = false,
            }
        elseif typeKey == "nametext" then
            auraCfg[typeKey] = {
                color = {r = 1, g = 1, b = 1, a = 1},
                showWhenMissing = false,
            }
        elseif typeKey == "healthtext" then
            auraCfg[typeKey] = {
                color = {r = 1, g = 1, b = 1, a = 1},
                showWhenMissing = false,
            }
        elseif typeKey == "sound" then
            auraCfg[typeKey] = {
                enabled = false,
                soundFile = nil,
                soundLSMKey = nil,
                volume = 0.8,
                -- Per-event native sounds (12.1 AddAuraSound triggers). The flat sound
                -- above is the APPLIED sound (Added trigger). dropped = Removed (buff
                -- fell off), stackGained = ApplicationsIncreased (stack gained). There is
                -- no stacks-lost (no ApplicationsDecreased trigger). Distinct from the
                -- blocked Missing/Expire alerts, which need sealed presence/remaining-time.
                appliedEnabled = true,
                dropped     = { enabled = false, soundLSMKey = nil, soundFile = nil },
                stackGained = { enabled = false, soundLSMKey = nil, soundFile = nil },
            }
        end
    end
    return auraCfg[typeKey]
end
P.EnsureTypeConfig = EnsureTypeConfig

-- Default values per type key, used as fallback when a saved config is missing new keys
local TYPE_DEFAULTS = {
    icon = {
        anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
        size = 24, scale = 1.0, alpha = 1.0,
        -- Canonical border keys (Stage 5.1b/c).  Legacy borderEnabled /
        -- borderThickness / borderInset migrated on ADDON_LOADED via
        -- DF:MigrateAuraDesignerIconBorderKeys.  BorderColor defaults to
        -- the pre-migration hardcoded translucent black so existing users
        -- see no visual change.  Style / Gradient* / Shadow* defaults seed
        -- CreateBorderControls' dropdowns and pickers so they read sensible
        -- values on first open.
        ShowBorder = true, BorderSize = 1, BorderInset = 0,
        BorderColor             = {r = 0, g = 0, b = 0, a = 0.8},
        BorderStyle             = "SOLID",
        BorderBlendMode         = "BLEND",
        BorderOffsetX           = 0,
        BorderOffsetY           = 0,
        BorderGradientStartColor = {r = 0,    g = 0,    b = 0,    a = 1},
        BorderGradientEndColor   = {r = 0.5,  g = 0.5,  b = 0.5,  a = 1},
        BorderGradientDirection  = "HORIZONTAL",
        BorderShadowEnabled      = false,
        BorderShadowColor        = {r = 0, g = 0, b = 0, a = 0.8},
        BorderShadowSize         = 1,
        BorderShadowOffsetX      = 1,
        BorderShadowOffsetY      = -1,
        -- Animation defaults match Frame Border's Stage 3 defaults so the
        -- behaviour of "pick PULSATE" reads the same across the addon.
        -- BorderAnimationType = "NONE" means no continuous animation; the
        -- spec.animation block is omitted by BuildSpec so Apply doesn't
        -- start anything.  Picking a non-NONE type surfaces the relevant
        -- tunables (helper handles hide/show per effect).
        BorderAnimationType         = "NONE",
        BorderAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        -- 1 Hz default ≈ 1-second cycle, matching the legacy AD Pulsate
        -- Border pulse rate.  Frame Border / Defensive Icon use 0.25 which
        -- reads as a slow gentle pulse at full-frame scale; at icon scale
        -- (24px) the same rate looks like a static dim border because the
        -- transitions are too gradual to perceive.
        BorderAnimationFrequency    = 1,
        BorderAnimationParticles    = 8,
        BorderAnimationLength       = 8,
        BorderAnimationThickness    = 3,
        BorderAnimationScale        = 1,
        BorderAnimationInset        = 0,
        BorderAnimationOffsetX      = 0,
        BorderAnimationOffsetY      = 0,
        BorderAnimationMask         = false,
        BorderAnimationSidesAxis    = "HORIZONTAL",
        BorderAnimationCornerLength = 10,
        hideSwipe = false, hideIcon = false,
        showDuration = true, durationFormat = "NUMBER", durationFont = "DF Roboto SemiBold",
        durationScale = 1.2, durationOutline = "SHADOW;OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = true,
        durationColor = {r = 1, g = 1, b = 1, a = 1},
        durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
        durationHideOnPermanent = true,   -- Wave 4: no timer text on permanent auras
        expiryAlertEnabled = false, expiryAlertMode = "BORDER", expiryAlertThreshold = 5, expiryAlertThresholdPercent = 30, expiryAlertThresholdUnit = "SECONDS",
        expiryAlertText = "", expiryAlertGlyph = "WARNING",
        expiryAlertAnchor = "TOP", expiryAlertOffsetX = 0, expiryAlertOffsetY = 0,
        expiryAlertSize = 14,
        -- Expiry Alert BORDER mode (secret-safe expiring frame): colour + auto-match + inset.
        expiryAlertBorderMatchIcon = true, expiryAlertBorderInset = 0,
        expiryAlertBorderColorMode = "STATIC", expiryAlertBorderThickness = "MEDIUM",
        expiryAlertBorderAlpha = 1,
        expiryAlertBorderColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        -- Pandemic (12.1 PTR 8): the GAME's refresh window — no threshold of any kind, by
        -- design (Features/Pandemic.lua). Green by default so it never reads as the same
        -- signal as the red expiry alert above; the two are meant to run together.
        pandemicEnabled = false, pandemicMode = "BORDER",
        pandemicFlash = false, pandemicFlashSpeed = 1,
        pandemicTintColor = {r = 0.2, g = 1, b = 0.2, a = 1},
        pandemicTintAlpha = 0.4, pandemicTintInset = 0,
        -- BORDER: a real DF.Border under the engine's own key prefix, so
        -- CreateBorderControls and Border:BuildSpec both drive it unmodified.
        pandemicShowBorder = true, pandemicBorderStyle = "SOLID",
        pandemicBorderSize = 2, pandemicBorderInset = 0,
        pandemicBorderOffsetX = 0, pandemicBorderOffsetY = 0,
        pandemicBorderColor = {r = 0.2, g = 1, b = 0.2, a = 1},
        pandemicBorderBlendMode = "BLEND",
        pandemicBorderTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
        pandemicBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
        pandemicBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
        pandemicBorderGradientDirection = "HORIZONTAL",
        pandemicBorderShadowEnabled = false,
        pandemicBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
        pandemicBorderShadowSize = 1,
        pandemicBorderShadowOffsetX = 1,
        pandemicBorderShadowOffsetY = -1,
        showStacks = true,
        stackFont = "DF Roboto SemiBold", stackScale = 1.0,
        stackOutline = "SHADOW;OUTLINE", stackAnchor = "BOTTOMRIGHT",
        stackX = 2, stackY = -2,
        stackColor = {r = 1, g = 1, b = 1, a = 1},
        -- Expiring Tint overlay (secret-safe).  Default OFF, red — also feeds the
        -- colour picker's Default button via the proxy's __dfDefaults = TYPE_DEFAULTS.
        -- #FF3333 @ 50% (matches expiring border red)
        -- legacy; migrated to ExpiringAnimationType
        -- Master enable for the whole Expiring feature.  Default true so
        -- existing configs are unaffected; turning it OFF disables every
        -- expiring override (colour / thickness / alpha / animation / pulse /
        -- bounce) regardless of their individual settings, and hides the rest
        -- of the Expiring panel.
        -- Stage 5.1d.2 + parity: full Border Animation effect set as the value
        -- the expiring callback swaps into spec.animation when remaining <
        -- threshold.  NONE = no animation override.  The expiring animation
        -- carries its OWN complete tunable set (colour, particles, thickness,
        -- offset, …) independent of the base Border Animation — mirrors the
        -- base defaults so the two panels read identically.
        -- Stage 5.1d.3: per-state thickness + alpha overrides.  Default to
        -- 1 / 1 — same thickness as the base (1) and slightly more opaque
        -- than the base alpha (0.8), so out of the box a user enabling
        -- Expiring Color Override sees the border tick to fully opaque red
        -- below threshold (subtle "more solid" feel).  Move the sliders
        -- higher / lower for stronger emphasis.  Only take effect when the
        -- expiring ticker is running (i.e. user has at least one expiring
        -- feature on — colour override, animation, alpha pulse, or bounce).
        -- Duration bar strip (mirrors the buff/debuff rows + filter-group cards):
        -- a native SetDurationBar-driven strip under/over the icon. OFF by default;
        -- render fallbacks live in DF:BuildDurationBarSpec — these seed the editor.
        durationBarEnabled = false, durationBarPosition = "BOTTOM",
        durationBarHeight = 4, durationBarGap = 1, durationBarColorMode = "STATIC",
        durationBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
        durationBarColor = {r = 0.2, g = 0.9, b = 0.3, a = 1},
        durationBarBGColor = {r = 0, g = 0, b = 0, a = 0.8},
        durationBarReverseFill = false,
        frameLevel = 40, frameStrata = "INHERIT",
        showWhenMissing = false, missingDesaturate = false,
    },
    square = {
        anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
        size = 24, scale = 1.0, alpha = 1.0,
        color = {r = 1, g = 1, b = 1, a = 1},
        -- Canonical border keys (Stage 5.2).  Legacy showBorder /
        -- borderThickness / borderInset migrated on ADDON_LOADED.  BorderColor
        -- defaults to opaque black, matching the square's pre-migration
        -- hardcoded border so existing users see no change.  The rest seed
        -- CreateBorderControls' dropdowns / pickers on first open.
        ShowBorder = true, BorderSize = 1, BorderInset = 0,
        BorderColor             = {r = 0, g = 0, b = 0, a = 1},
        BorderStyle             = "SOLID",
        BorderBlendMode         = "BLEND",
        BorderOffsetX           = 0,
        BorderOffsetY           = 0,
        BorderGradientStartColor = {r = 0,    g = 0,    b = 0,    a = 1},
        BorderGradientEndColor   = {r = 0.5,  g = 0.5,  b = 0.5,  a = 1},
        BorderGradientDirection  = "HORIZONTAL",
        BorderShadowEnabled      = false,
        BorderShadowColor        = {r = 0, g = 0, b = 0, a = 0.8},
        BorderShadowSize         = 1,
        BorderShadowOffsetX      = 1,
        BorderShadowOffsetY      = -1,
        BorderAnimationType         = "NONE",
        BorderAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        BorderAnimationFrequency    = 1,
        BorderAnimationParticles    = 8,
        BorderAnimationLength       = 8,
        BorderAnimationThickness    = 3,
        BorderAnimationScale        = 1,
        BorderAnimationInset        = 0,
        BorderAnimationOffsetX      = 0,
        BorderAnimationOffsetY      = 0,
        BorderAnimationMask         = false,
        BorderAnimationSidesAxis    = "HORIZONTAL",
        BorderAnimationCornerLength = 10,
        hideSwipe = false, hideIcon = false,
        showDuration = true, durationFormat = "NUMBER", durationFont = "DF Roboto SemiBold",
        durationScale = 1.2, durationOutline = "SHADOW;OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = true,
        durationColor = {r = 1, g = 1, b = 1, a = 1},
        durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
        durationHideOnPermanent = true,   -- Wave 4: no timer text on permanent auras
        expiryAlertEnabled = false, expiryAlertMode = "BORDER", expiryAlertThreshold = 5, expiryAlertThresholdPercent = 30, expiryAlertThresholdUnit = "SECONDS",
        expiryAlertText = "", expiryAlertGlyph = "WARNING",
        expiryAlertAnchor = "TOP", expiryAlertOffsetX = 0, expiryAlertOffsetY = 0,
        expiryAlertSize = 14,
        -- Expiry Alert BORDER mode (secret-safe expiring frame): colour + auto-match + inset.
        expiryAlertBorderMatchIcon = true, expiryAlertBorderInset = 0,
        expiryAlertBorderColorMode = "STATIC", expiryAlertBorderThickness = "MEDIUM",
        expiryAlertBorderAlpha = 1,
        expiryAlertBorderColor = {r = 1, g = 0.2, b = 0.2, a = 1},
        -- Pandemic (12.1 PTR 8): the GAME's refresh window — no threshold of any kind, by
        -- design (Features/Pandemic.lua). Green by default so it never reads as the same
        -- signal as the red expiry alert above; the two are meant to run together.
        pandemicEnabled = false, pandemicMode = "BORDER",
        pandemicFlash = false, pandemicFlashSpeed = 1,
        pandemicTintColor = {r = 0.2, g = 1, b = 0.2, a = 1},
        pandemicTintAlpha = 0.4, pandemicTintInset = 0,
        -- BORDER: a real DF.Border under the engine's own key prefix, so
        -- CreateBorderControls and Border:BuildSpec both drive it unmodified.
        pandemicShowBorder = true, pandemicBorderStyle = "SOLID",
        pandemicBorderSize = 2, pandemicBorderInset = 0,
        pandemicBorderOffsetX = 0, pandemicBorderOffsetY = 0,
        pandemicBorderColor = {r = 0.2, g = 1, b = 0.2, a = 1},
        pandemicBorderBlendMode = "BLEND",
        pandemicBorderTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
        pandemicBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
        pandemicBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
        pandemicBorderGradientDirection = "HORIZONTAL",
        pandemicBorderShadowEnabled = false,
        pandemicBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
        pandemicBorderShadowSize = 1,
        pandemicBorderShadowOffsetX = 1,
        pandemicBorderShadowOffsetY = -1,
        showStacks = true,
        stackFont = "DF Roboto SemiBold", stackScale = 1.0,
        stackOutline = "SHADOW;OUTLINE", stackAnchor = "BOTTOMRIGHT",
        stackX = 2, stackY = -2,
        stackColor = {r = 1, g = 1, b = 1, a = 1},
        -- Master enable for the whole Expiring feature (Stage 5.2 — mirrors
        -- the icon).  Default true so existing configs are unaffected.
        -- #FF3333 @ 50% (matches expiring border red)
        -- Stage 5.2 expiring-border overrides (shared backend with the icon).
        -- ExpiringBorderColor is SEPARATE from the fill's expiringColor — the
        -- fill and border each get their own expiring tint.  Defaults to the
        -- same red so out of the box both "turn red", but they're independent.
        -- Duration bar strip (mirrors the icon card): a native SetDurationBar-driven
        -- strip under/over the square. OFF by default; render fallbacks live in
        -- DF:BuildDurationBarSpec — these seed the editor.
        durationBarEnabled = false, durationBarPosition = "BOTTOM",
        durationBarHeight = 4, durationBarGap = 1, durationBarColorMode = "STATIC",
        durationBarTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
        durationBarColor = {r = 0.2, g = 0.9, b = 0.3, a = 1},
        durationBarBGColor = {r = 0, g = 0, b = 0, a = 0.8},
        durationBarReverseFill = false,
        frameLevel = 40, frameStrata = "INHERIT",
        showWhenMissing = false,
    },
    bar = {
        anchor = "BOTTOM", offsetX = 0, offsetY = 0,
        orientation = "HORIZONTAL", width = 60, height = 6,
        matchFrameWidth = true, matchFrameHeight = false,
        matchInset = 0,   -- extra per-side trim on the matched axes (see resolveBarSize)
        barColorMode = "STATIC",   -- STATIC / DF / DFSTOPS / CLASSIC (curve = green->red ramp as it drains)
        texture = "Interface\\TargetingFrame\\UI-StatusBar",
        fillColor = {r = 1, g = 1, b = 1, a = 1},
        bgColor = {r = 0, g = 0, b = 0, a = 0.5},
        -- Canonical border keys (Stage 5.3).  Legacy showBorder /
        -- borderThickness / borderColor migrated on ADDON_LOADED.  BorderInset
        -- defaults to 0 so the ring sits FLUSH outside the bar as before.
        -- BorderColor defaults to opaque black (the bar's pre-migration look).
        ShowBorder = true, BorderSize = 1, BorderInset = 0,
        BorderColor             = {r = 0, g = 0, b = 0, a = 1},
        BorderStyle             = "SOLID",
        BorderBlendMode         = "BLEND",
        BorderGradientStartColor = {r = 0,    g = 0,    b = 0,    a = 1},
        BorderGradientEndColor   = {r = 0.5,  g = 0.5,  b = 0.5,  a = 1},
        BorderGradientDirection  = "HORIZONTAL",
        BorderShadowEnabled      = false,
        BorderShadowColor        = {r = 0, g = 0, b = 0, a = 0.8},
        BorderShadowSize         = 1,
        BorderShadowOffsetX      = 1,
        BorderShadowOffsetY      = -1,
        BorderAnimationType         = "NONE",
        BorderAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        BorderAnimationFrequency    = 1,
        BorderAnimationParticles    = 8,
        BorderAnimationLength       = 8,
        BorderAnimationThickness    = 3,
        BorderAnimationScale        = 1,
        BorderAnimationInset        = 0,
        BorderAnimationOffsetX      = 0,
        BorderAnimationOffsetY      = 0,
        BorderAnimationMask         = false,
        BorderAnimationSidesAxis    = "HORIZONTAL",
        BorderAnimationCornerLength = 10,
        alpha = 1.0,
        barColorByTime = false,
        -- #FF3333 @ 50% (matches expiring border red)
        -- FALSE to match the factory's bar render default (buildDurationTextSpec is
        -- called with defaultShow = false for bars — no text out of the box). It was
        -- `true` here, so a never-toggled bar showed a TICKED checkbox while rendering
        -- no text — and durationFmtKey's early-return ("") meant Duration Format
        -- changes never moved the struct sig, reading as "stale until I toggle
        -- Show Duration" (Krathe, 2026-07-24). Instances are created SPARSE
        -- (CreateIndicatorInstance), so this fallback IS the checkbox for new bars.
        showDuration = false, durationFormat = "NUMBER", durationFont = "DF Roboto SemiBold",
        durationScale = 1.2, durationOutline = "SHADOW;OUTLINE",
        durationAnchor = "CENTER", durationX = 0, durationY = 0,
        durationColorByTime = true,
        durationHideAboveEnabled = false, durationHideAboveThreshold = 10,
        durationHideOnPermanent = true,   -- Wave 4: no timer text on permanent auras
        -- A bar's expiry COLOUR is its own fill (the Duration Bar Color Mode reddens as it
        -- drains); the |T reveal only offers Text / Glyph here, so default to a warning Glyph.
        expiryAlertEnabled = false, expiryAlertMode = "GLYPH", expiryAlertThreshold = 5, expiryAlertThresholdPercent = 30, expiryAlertThresholdUnit = "SECONDS",
        expiryAlertText = "", expiryAlertGlyph = "WARNING",
        expiryAlertAnchor = "TOP", expiryAlertOffsetX = 0, expiryAlertOffsetY = 0,
        expiryAlertSize = 14,
        -- Pandemic — see the icon block above. A bar DOES get Border/Tint (a real texture
        -- anchored to the bar's edges, not a |T escape), so the default type is the same
        -- BORDER the other shapes use rather than the bar's Glyph-only expiry fallback.
        pandemicEnabled = false, pandemicMode = "BORDER",
        pandemicFlash = false, pandemicFlashSpeed = 1,
        pandemicTintColor = {r = 0.2, g = 1, b = 0.2, a = 1},
        pandemicTintAlpha = 0.4, pandemicTintInset = 0,
        -- BORDER: a real DF.Border under the engine's own key prefix, so
        -- CreateBorderControls and Border:BuildSpec both drive it unmodified.
        pandemicShowBorder = true, pandemicBorderStyle = "SOLID",
        pandemicBorderSize = 2, pandemicBorderInset = 0,
        pandemicBorderOffsetX = 0, pandemicBorderOffsetY = 0,
        pandemicBorderColor = {r = 0.2, g = 1, b = 0.2, a = 1},
        pandemicBorderBlendMode = "BLEND",
        pandemicBorderTexture = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist",
        pandemicBorderGradientStartColor = {r = 0, g = 0, b = 0, a = 1},
        pandemicBorderGradientEndColor = {r = 0.5, g = 0.5, b = 0.5, a = 1},
        pandemicBorderGradientDirection = "HORIZONTAL",
        pandemicBorderShadowEnabled = false,
        pandemicBorderShadowColor = {r = 0, g = 0, b = 0, a = 0.8},
        pandemicBorderShadowSize = 1,
        pandemicBorderShadowOffsetX = 1,
        pandemicBorderShadowOffsetY = -1,
        frameLevel = 40, frameStrata = "INHERIT",
    },
    -- Frame-level types: mirror the inline literals in EnsureTypeConfig so the
    -- colour-picker Default button (and any other consumer of __dfDefaults) can
    -- resolve a default value for keys like "color" and "expiringColor".
    -- Border-type (Stage 5.4): full canonical DF.Border defaults so
    -- CreateBorderControls' dropdowns / pickers read sensible values.  The
    -- legacy style/thickness/inset/color are migrated on load.
    border = {
        ShowBorder = true, BorderSize = 2, BorderInset = 0,
        BorderColor             = {r = 1, g = 1, b = 1, a = 1},
        BorderStyle             = "SOLID",
        BorderBlendMode         = "BLEND",
        BorderOffsetX           = 0,
        BorderOffsetY           = 0,
        BorderGradientStartColor = {r = 0,    g = 0,    b = 0,    a = 1},
        BorderGradientEndColor   = {r = 0.5,  g = 0.5,  b = 0.5,  a = 1},
        BorderGradientDirection  = "HORIZONTAL",
        BorderShadowEnabled      = false,
        BorderShadowColor        = {r = 0, g = 0, b = 0, a = 0.8},
        BorderShadowSize         = 1,
        BorderShadowOffsetX      = 1,
        BorderShadowOffsetY      = -1,
        BorderAnimationType         = "NONE",
        BorderAnimationColor        = {r = 0.95, g = 0.95, b = 0.32, a = 1},
        BorderAnimationFrequency    = 1,
        BorderAnimationParticles    = 8,
        BorderAnimationLength       = 8,
        BorderAnimationThickness    = 3,
        BorderAnimationScale        = 1,
        BorderAnimationInset        = 0,
        BorderAnimationOffsetX      = 0,
        BorderAnimationOffsetY      = 0,
        BorderAnimationMask         = false,
        BorderAnimationSidesAxis    = "HORIZONTAL",
        BorderAnimationCornerLength = 10,
        -- Draw above the frame's class border (parent+10) / aggro (parent+9).
        drawAboveFrameBorder = true,
        -- Expiring-border overrides (Stage 5.4 parity with icon/square).
        showWhenMissing = false,
    },
    healthbar = {
        mode = "Replace", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
        tintWholeBar = false,
        showWhenMissing = false,
    },
    background = {
        mode = "Tint", color = {r = 1, g = 1, b = 1, a = 1}, blend = 0.5,
        showWhenMissing = false,
    },
    nametext = {
        color = {r = 1, g = 1, b = 1, a = 1},
        showWhenMissing = false,
    },
    healthtext = {
        color = {r = 1, g = 1, b = 1, a = 1},
        showWhenMissing = false,
    },
}

-- ☠ Published HERE, in the part that DEFINES it. A publish must never be
-- separated from its definition by a split boundary: this one originally
-- landed in the next part, which then aliased P.TYPE_DEFAULTS before anything
-- had published it -- nil, and a crash on the first effect card.
P.TYPE_DEFAULTS = TYPE_DEFAULTS
