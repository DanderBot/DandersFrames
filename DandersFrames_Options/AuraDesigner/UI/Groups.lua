-- Part 2 of the Aura Designer editor, split from Options.lua.
-- Aliases of objects the first part created; they add no state.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local L = DF.L
local GUI = DF.GUI
local Adapter = DF.AuraDesigner.Adapter
local S = DF.AuraDesigner._uiState
local P = DF.AuraDesigner._priv
local OPTS = P.OPTS
local GetAuraDesignerDB = P.GetAuraDesignerDB
local GetThemeColor = P.GetThemeColor
local ApplyBackdrop = P.ApplyBackdrop
local ResolveSpec = P.ResolveSpec
local GetSpecAuras = P.GetSpecAuras
local GetOtherAuras = P.GetOtherAuras
local NextGroupName = P.NextGroupName
local GetSpecLayoutGroups = P.GetSpecLayoutGroups
local IsOtherTab = P.IsOtherTab
local IsDebuffTab = P.IsDebuffTab
local EMPTY_POOL = P.EMPTY_POOL
local CurrentAuraPool = P.CurrentAuraPool
local PoolKeyPrefix = P.PoolKeyPrefix
local DebuffGroupsRead = P.DebuffGroupsRead
local GetOtherLayoutGroups = P.GetOtherLayoutGroups
local CurrentLayoutGroups = P.CurrentLayoutGroups
local OtherPoolDisplayName = P.OtherPoolDisplayName
local EnsureAuraConfig = P.EnsureAuraConfig
local EnsureTypeConfig = P.EnsureTypeConfig
local TYPE_DEFAULTS = P.TYPE_DEFAULTS

-- ============================================================
-- INSTANCE-BASED INDICATOR HELPERS
-- Placed indicators (icon/square/bar) are stored as instances
-- in auraCfg.indicators[] with stable IDs.
-- ============================================================

-- Create a new indicator instance for an aura, returns the instance table
local function CreateIndicatorInstance(auraName, typeKey)
    local auraCfg = EnsureAuraConfig(auraName)
    if not auraCfg.indicators then
        auraCfg.indicators = {}
    end
    if not auraCfg.nextIndicatorID then
        auraCfg.nextIndicatorID = 1
    end

    -- Only store id, type, and anchor — all other settings fall through
    -- to global defaults then TYPE_DEFAULTS via CreateInstanceProxy
    local defaults = TYPE_DEFAULTS[typeKey]

    -- Create minimal instance: just id + type + anchor placement
    local instance = {
        anchor = defaults and defaults.anchor or "TOPLEFT",
        offsetX = 0,
        offsetY = 0,
    }

    instance.id = auraCfg.nextIndicatorID
    instance.type = typeKey
    auraCfg.nextIndicatorID = auraCfg.nextIndicatorID + 1

    tinsert(auraCfg.indicators, instance)
    return instance
end
P.CreateIndicatorInstance = CreateIndicatorInstance

-- Find an indicator instance by its stable ID. `pool` (optional) pins the
-- pool; defaults to the active tab's pool.
local function GetIndicatorByID(auraName, indicatorID, pool)
    local auraCfg = (pool or CurrentAuraPool())[auraName]
    if not auraCfg or not auraCfg.indicators then return nil end
    for _, inst in ipairs(auraCfg.indicators) do
        if inst.id == indicatorID then
            return inst
        end
    end
    return nil
end

-- Remove an indicator instance by its stable ID
-- (S.CleanupAdHocAura declared on the state table)
local function RemoveIndicatorInstance(auraName, indicatorID)
    local auraCfg = CurrentAuraPool()[auraName]
    if not auraCfg or not auraCfg.indicators then return end
    for i, inst in ipairs(auraCfg.indicators) do
        if inst.id == indicatorID then
            table.remove(auraCfg.indicators, i)
            if S.CleanupAdHocAura then S.CleanupAdHocAura(auraName) end
            return
        end
    end
end
P.RemoveIndicatorInstance = RemoveIndicatorInstance

-- (ChangeInstanceType removed — uncalled since the tile-strip type switcher
-- left the v4 redesign; reclaimed for the 200-locals ceiling.)

-- Keys to skip when copying appearance between indicators (identity + placement +
-- the eye toggle's hidden state — copying appearance must not hide the destination)
local COPY_SKIP_KEYS = { id = true, type = true, anchor = true, offsetX = true, offsetY = true, enabled = true }

-- Deep-copy a value (handles nested tables like color = {r,g,b,a})
local function DeepCopyValue(val)
    if type(val) == "table" then
        local copy = {}
        for k, v in pairs(val) do
            copy[k] = DeepCopyValue(v)
        end
        return copy
    end
    return val
end

-- Copy appearance settings from one placed indicator to another of the same type.
-- Copies all keys except identity (id, type) and placement (anchor, offsetX, offsetY).
-- Keys present on source are deep-copied; keys absent on source are removed from
-- destination so they fall through to defaults via the proxy chain.
local function CopyIndicatorAppearance(srcAuraName, srcIndicatorID, dstAuraName, dstIndicatorID)
    local src = GetIndicatorByID(srcAuraName, srcIndicatorID)
    local dst = GetIndicatorByID(dstAuraName, dstIndicatorID)
    if not src or not dst then return end
    if src.type ~= dst.type then return end

    -- Collect all non-skip keys from both source and destination
    local allKeys = {}
    for k in pairs(src) do
        if not COPY_SKIP_KEYS[k] then allKeys[k] = true end
    end
    for k in pairs(dst) do
        if not COPY_SKIP_KEYS[k] then allKeys[k] = true end
    end

    -- Sync: copy from src, clear from dst what src doesn't have
    for k in pairs(allKeys) do
        if src[k] ~= nil then
            dst[k] = DeepCopyValue(src[k])
        else
            dst[k] = nil
        end
    end
end
P.CopyIndicatorAppearance = CopyIndicatorAppearance

-- Forward declaration: lightweight preview refresh (defined after RefreshPreviewEffects)
-- Called from proxy __newindex so every setting change updates the preview in real-time
-- (S.RefreshPreviewLightweight declared on the state table)

-- Throttled live-frame refresh: re-syncs the factory containers on all
-- visible AD-enabled frames. Debounced so rapid slider drags only trigger one refresh.
S.pendingLiveRefresh = false
local function RefreshLiveFramesThrottled()
    if S.pendingLiveRefresh then return end
    S.pendingLiveRefresh = true
    C_Timer.After(0.1, function()
        S.pendingLiveRefresh = false
        local engine = DF.AuraDesigner and DF.AuraDesigner.Engine
        if engine and engine.ForceRefreshAllFrames then
            engine:ForceRefreshAllFrames()
        end
    end)
end
P.RefreshLiveFramesThrottled = RefreshLiveFramesThrottled

-- Global-default key mapping: which global default keys apply to placed types
local GLOBAL_DEFAULT_MAP = {
    icon   = {
        size = "iconSize", scale = "iconScale", showDuration = "showDuration", showStacks = "showStacks",
        durationFont = "durationFont", durationScale = "durationScale", durationOutline = "durationOutline",
        durationAnchor = "durationAnchor", durationX = "durationX", durationY = "durationY",
        durationColorByTime = "durationColorByTime", durationColor = "durationColor",
        stackFont = "stackFont", stackScale = "stackScale", stackOutline = "stackOutline",
        stackAnchor = "stackAnchor", stackX = "stackX", stackY = "stackY",
        stackColor = "stackColor",
        hideSwipe = "hideSwipe", hideIcon = "hideIcon",
        frameLevel = "indicatorFrameLevel", frameStrata = "indicatorFrameStrata",
    },
    square = {
        size = "iconSize", scale = "iconScale", showDuration = "showDuration", showStacks = "showStacks",
        durationFont = "durationFont", durationScale = "durationScale", durationOutline = "durationOutline",
        durationAnchor = "durationAnchor", durationX = "durationX", durationY = "durationY",
        durationColorByTime = "durationColorByTime", durationColor = "durationColor",
        stackFont = "stackFont", stackScale = "stackScale", stackOutline = "stackOutline",
        stackAnchor = "stackAnchor", stackX = "stackX", stackY = "stackY",
        stackColor = "stackColor",
        hideSwipe = "hideSwipe", hideIcon = "hideIcon",
        frameLevel = "indicatorFrameLevel", frameStrata = "indicatorFrameStrata",
    },
    bar    = {
        durationFont = "durationFont", durationScale = "durationScale", durationOutline = "durationOutline",
        durationAnchor = "durationAnchor", durationX = "durationX", durationY = "durationY",
        durationColorByTime = "durationColorByTime",
        frameLevel = "indicatorFrameLevel", frameStrata = "indicatorFrameStrata",
    },
}

-- "Expiration" section for the placed icon/square cards: the per-indicator EXPIRY ALERT
-- ELEMENT (text / glyph / border / tint shown only below the threshold, natively driven on an
-- invisible COMPANION SLOT over the indicator — see Factory.lua's EXPIRY ALERT COMPANION SLOT
-- section). Built by the shared GUI:CreateExpirationControls helper (engine-driven via
-- DF.Expiration) so the frame-level indicators can reuse the exact same panel. Controls that
-- don't apply to the current mode HIDE (rows collapse + the card reflows); ones that apply but
-- are inactive GREY. No animation control: a button-child region can't be animated while auras
-- are secret (PTR-5), and out-of-combat-only animation is worthless for an expiry warning.
-- `include` (optional) selects which reveal types + controls apply to this indicator's shape:
-- square indicators (icon/square) pass nil (Border + Tint + Match); a rectangular one (bar)
-- passes { border = false, tint = false, match = false } — Border distorts off-square, and the
-- |T tint is font-coupled so it collapses on a thin bar; a bar's expiry colour is its own fill
-- (Duration Bar Color Mode), leaving Text/Glyph as the bar's alert types.
local function AddExpiryAlertControls(g, parent, proxy, include)
    GUI:CreateExpirationControls(g, proxy, {
        parent        = parent,
        anchorOptions = OPTS.ANCHOR_OPTIONS,
        include       = include,
        -- Sub-table colour / alpha writes skip the proxy __newindex, so drive the refresh by
        -- hand (S.RefreshPreviewLightweight is assigned by editor open; mirrors the card's RPL).
        fullUpdate    = function()
            if S.RefreshPreviewLightweight then S.RefreshPreviewLightweight() end
            RefreshLiveFramesThrottled()
        end,
        -- A mode change collapses the now-irrelevant rows: LayoutChildren re-evaluates hideOn,
        -- RefreshChildStates re-applies the grey, and dfAD_ReflowWidgets slides the sibling
        -- groups (Duration Text / Stack Count) up or down to track the new height.
        refreshStates = function()
            g:LayoutChildren()
            g:RefreshChildStates()
            if parent.dfAD_ReflowWidgets then parent.dfAD_ReflowWidgets() end
        end,
    })
    g:RefreshChildStates()   -- initial grey (the initial hide rides AddGroup's LayoutChildren)
end
P.AddExpiryAlertControls = AddExpiryAlertControls

-- "Pandemic" section — the sibling of Expiration above, and deliberately its own section
-- rather than a mode inside it. Both answer "act on this aura soon", but from opposite
-- ends: Expiration fires at a threshold the USER picks and can walk a colour ramp;
-- Pandemic fires on the window the GAME defines and cannot. Folding pandemic into the
-- Expiration threshold block would leave a user who set 5s watching it fire at 9s with no
-- explanation — so it gets its own box, and the two are free to run together.
--
-- All four reveal types apply to EVERY indicator shape here, including the bar. Unlike the
-- expiry alert — whose Border/Tint are a |T escape inside a fontstring and so collapse on a
-- thin bar — a pandemic region is a real texture anchored to the button's own edges, so a
-- ring or wash fits a bar exactly as well as an icon. Hence no `include` parameter.
local function AddPandemicControls(g, parent, proxy)
    GUI:CreatePandemicControls(g, proxy, {
        parent          = parent,
        anchorOptions   = OPTS.ANCHOR_OPTIONS,
        -- Both systems key off the SAME per-indicator record here, so the collision notes
        -- can compare them directly. The buff/debuff rows have no expiry alert at all and
        -- pass nothing.
        expiryCollision = true,
        -- Sub-table colour writes skip the proxy __newindex — same reason as the expiry
        -- section above, same hand-driven refresh.
        fullUpdate    = function()
            if S.RefreshPreviewLightweight then S.RefreshPreviewLightweight() end
            RefreshLiveFramesThrottled()
        end,
        refreshStates = function()
            g:LayoutChildren()
            g:RefreshChildStates()
            if parent.dfAD_ReflowWidgets then parent.dfAD_ReflowWidgets() end
        end,
    })
    g:RefreshChildStates()   -- initial grey (the initial hide rides AddGroup's LayoutChildren)
end
P.AddPandemicControls = AddPandemicControls

-- Colours-S.page cross-link placed under an AD "Color by Time Remaining" TEXT control, matching
-- the aura pages' duration link (jump + whole-section flash). The duration text's By-Time colour
-- draws from the shared Colours-S.page breakpoints, so the link points there. Fixed-layout note, so
-- size it to the group's inner width up front (the group advances Y by the height we pass).
-- Built once in GUI:CreateColorsPageLink. NOT for the bar FILL colour (fixed ramp, immutable).
local function AddDurationColorsLink(g, parent)
    local innerW = GUI:GroupInnerWidth(g)
    local note = GUI:CreateColorsPageLink(parent, innerW)
    g:AddWidget(note, (note.layoutHeight or 16) + 2)
    return note
end
P.AddDurationColorsLink = AddDurationColorsLink

-- Create a proxy table that maps flat key access to an indicator instance
-- Fallback chain: instance value → global defaults → TYPE_DEFAULTS
local function CreateInstanceProxy(auraName, indicatorID)
    -- Pin the pool at creation (B2): proxies are minted per effect card, and
    -- the card's tab is the record's pool — a callback firing after a tab
    -- switch must keep reading/writing the ORIGINAL pool.
    local otherPool = IsOtherTab()
    local function pool() return otherPool and GetOtherAuras() or GetSpecAuras() end
    -- Resolve current type to expose TYPE_DEFAULTS to GUI:CreateColorPicker's
    -- Default button. Type changes rebuild the panel (RefreshPage) which makes
    -- a fresh proxy, so stashing at construction time is safe.
    local _inst = GetIndicatorByID(auraName, indicatorID, pool())
    local _typeDefaults = _inst and TYPE_DEFAULTS[_inst.type] or nil
    return setmetatable({ _skipOverrideIndicators = true, __dfDefaults = _typeDefaults }, {
        __index = function(_, k)
            local inst = GetIndicatorByID(auraName, indicatorID, pool())
            if inst then
                local val = inst[k]
                if val ~= nil then return val end
            end
            -- Fall back to global defaults for applicable keys
            local fallback
            if inst and inst.type then
                local gdMap = GLOBAL_DEFAULT_MAP[inst.type]
                if gdMap then
                    local gdKey = gdMap[k]
                    if gdKey then
                        local adDB = GetAuraDesignerDB()
                        local gd = adDB and adDB.defaults
                        if gd and gd[gdKey] ~= nil then fallback = gd[gdKey] end
                    end
                end
                -- Then fall back to TYPE_DEFAULTS
                if fallback == nil then
                    local defaults = TYPE_DEFAULTS[inst.type]
                    if defaults then fallback = defaults[k] end
                end
            end
            -- Copy-on-read: if fallback is a table, copy it into the instance
            -- so that sub-key mutations (e.g. proxy.color.r = 1) persist
            if type(fallback) == "table" and inst then
                local copy = {}
                for fk, fv in pairs(fallback) do copy[fk] = fv end
                inst[k] = copy
                return copy
            end
            return fallback
        end,
        __newindex = function(_, k, v)
            local inst = GetIndicatorByID(auraName, indicatorID, pool())
            if not inst then return end
            inst[k] = v
            if S.RefreshPreviewLightweight then S.RefreshPreviewLightweight() end
            RefreshLiveFramesThrottled()
        end,
    })
end
P.CreateInstanceProxy = CreateInstanceProxy

-- Create a proxy table that maps flat key access to nested aura config
local function CreateProxy(auraName, typeKey)
    local defaults = TYPE_DEFAULTS[typeKey]
    -- Pin the pool at creation (B2) — see CreateInstanceProxy.
    local otherPool = IsOtherTab()
    local function pool() return otherPool and GetOtherAuras() or GetSpecAuras() end
    -- Expose defaults to GUI:CreateColorPicker so its Default button can resolve
    -- AD-specific keys (color/expiringColor/etc.) that aren't in PartyDefaults.
    return setmetatable({ _skipOverrideIndicators = true, __dfDefaults = defaults }, {
        __index = function(_, k)
            local auraCfg = pool()[auraName]
            if auraCfg and auraCfg[typeKey] then
                local val = auraCfg[typeKey][k]
                if val ~= nil then return val end
            end
            -- Fall back to defaults for missing keys
            local fallback = defaults and defaults[k] or nil
            -- Copy-on-read: if fallback is a table, copy it into the config
            -- so that sub-key mutations (e.g. proxy.color.r = 1) persist
            if type(fallback) == "table" then
                local typeCfg = EnsureTypeConfig(auraName, typeKey, pool())
                local copy = {}
                for fk, fv in pairs(fallback) do copy[fk] = fv end
                typeCfg[k] = copy
                return copy
            end
            return fallback
        end,
        __newindex = function(_, k, v)
            local typeCfg = EnsureTypeConfig(auraName, typeKey, pool())
            typeCfg[k] = v
            if S.RefreshPreviewLightweight then S.RefreshPreviewLightweight() end
            RefreshLiveFramesThrottled()
        end,
    })
end
P.CreateProxy = CreateProxy

-- Create a proxy for the aura-level config (priority, expiring)
local function CreateAuraProxy(auraName)
    -- Pin the pool at creation (B2) — see CreateInstanceProxy.
    local otherPool = IsOtherTab()
    local function pool() return otherPool and GetOtherAuras() or GetSpecAuras() end
    return setmetatable({ _skipOverrideIndicators = true }, {
        __index = function(_, k)
            local auraCfg = pool()[auraName]
            if auraCfg then return auraCfg[k] end
            return nil
        end,
        __newindex = function(_, k, v)
            local auraCfg = EnsureAuraConfig(auraName, pool())
            auraCfg[k] = v
            if S.RefreshPreviewLightweight then S.RefreshPreviewLightweight() end
            RefreshLiveFramesThrottled()
        end,
    })
end
P.CreateAuraProxy = CreateAuraProxy

-- ============================================================
-- WARNING BADGE
-- Some auras have underlying API limitations that mean multiple
-- spells collapse into a single indicator. Entries in Config.lua
-- with a `warningKey` get a small yellow triangle overlay on their
-- spell icon and collapsible header, with a tooltip explaining why.
-- ============================================================

local WARNING_TEXTURE = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning.tga"

-- Resolve a warningKey to localized tooltip text. Keys are defined
-- here rather than Config.lua so they can go through L[] without
-- load-order concerns.
local function GetWarningText(warningKey)
    if not warningKey then return nil end
    local L = DF.L or setmetatable({}, { __index = function(_, k) return k end })
    if warningKey == "HolyArmamentsMerge" then
        return L["Holy Bulwark and Sacred Weapon share the same aura signature and cannot be tracked separately. Both buffs will trigger this single indicator."]
    end
    return nil
end

-- Look up the warningKey for a given aura name in the current spec.
local function GetAuraWarningKey(specKey, auraName)
    local specList = DF.AuraDesigner.TrackableAuras and DF.AuraDesigner.TrackableAuras[specKey]
    if not specList then return nil end
    for _, entry in ipairs(specList) do
        if entry.name == auraName then return entry.warningKey end
    end
    return nil
end
P.GetAuraWarningKey = GetAuraWarningKey

-- Attach (or refresh) a warning triangle badge on the given region.
-- host:     parent Frame the badge is attached to (must be a Frame).
-- warnKey:  config warning key; nil hides the badge.
-- opts:     optional table with:
--             point         -- default "TOPRIGHT"
--             relativeTo    -- default host
--             relativePoint -- default "TOPRIGHT"
--             offsetX/Y     -- default 3, 3
--             size          -- default 16
--             color         -- { r, g, b } default red { 1.0, 0.25, 0.25 }
local function AttachWarningBadge(host, warnKey, opts)
    if not host then return end
    local badge = host.dfWarningBadge
    if not warnKey then
        if badge then badge:Hide() end
        return
    end
    local tooltipText = GetWarningText(warnKey)
    if not tooltipText then
        if badge then badge:Hide() end
        return
    end

    if not badge then
        badge = CreateFrame("Frame", nil, host)
        badge:SetFrameLevel(host:GetFrameLevel() + 5)
        local tex = badge:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints(badge)
        tex:SetTexture(WARNING_TEXTURE)
        badge.texture = tex
        badge:SetScript("OnEnter", function(self)
            GUI:ShowTooltip(self, { title = self.tooltipText or "" })
        end)
        badge:SetScript("OnLeave", function() GUI:HideTooltip() end)
        host.dfWarningBadge = badge
    end

    opts = opts or {}
    local size = opts.size or 16
    local color = opts.color or { 1.0, 0.25, 0.25 }
    badge:SetSize(size, size)
    badge:ClearAllPoints()
    badge:SetPoint(
        opts.point or "TOPRIGHT",
        opts.relativeTo or host,
        opts.relativePoint or "TOPRIGHT",
        opts.offsetX or 3,
        opts.offsetY or 3
    )
    badge.texture:SetVertexColor(color[1], color[2], color[3])
    badge.tooltipText = tooltipText
    badge:Show()
end
P.AttachWarningBadge = AttachWarningBadge

-- Ad-hoc add-by-ID auras (picker "Add" with an ID the SpellDB doesn't know)
-- are stored under the key "#<spellID>" — the name IS the identity, so the
-- record needs no side table and survives reload/profile export for free.
-- Returns the embedded numeric spell ID, or nil for normal aura names.
local function AdHocSpellID(auraName)
    if type(auraName) ~= "string" then return nil end
    local id = auraName:match("^#(%d+)$")
    return id and tonumber(id) or nil
end

-- Configured ad-hoc "#<id>" auras are never in the trackable pool, so pool-driven
-- pickers (layout-group "Add aura", frame-effect "Add Trigger") can't offer them.
-- Returns a NEW list = the given trackable list plus one aura-info-shaped entry per
-- configured ad-hoc aura (live-resolved display name, pool-grey accent), sorted by
-- spell ID for a stable order. Never mutates `list` — GetTrackableAuras caches it.
local AD_HOC_COLOR = { 0.62, 0.62, 0.62 }
local function WithConfiguredAdHocAuras(list, spec)
    local out = {}
    for i, info in ipairs(list) do out[i] = info end
    local adHoc = {}
    -- Pool-routed: the Other tab's group picker offers the OTHER pool's
    -- configured ad-hoc auras (never creates it — read accessor).
    for auraName in pairs(CurrentAuraPool(spec)) do
        local id = AdHocSpellID(auraName)
        if id then tinsert(adHoc, { name = auraName, id = id }) end
    end
    sort(adHoc, function(a, b) return a.id < b.id end)
    for _, e in ipairs(adHoc) do
        local display = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(e.id)
        tinsert(out, {
            name = e.name,
            display = display or e.name,
            color = AD_HOC_COLOR,
            spellID = e.id,
            class = "ALL",  -- picker grid sections by class; ad-hoc ids aren't class spells
        })
    end
    return out
end
P.WithConfiguredAdHocAuras = WithConfiguredAdHocAuras

-- Get spell icon texture for an aura
-- Uses static texture IDs to avoid C_Spell.GetSpellTexture returning
-- the wrong icon when talent choice nodes replace a spell.
local function GetAuraIcon(specKey, auraName)
    -- Filter-owned records aren't one spell, so there is no spell icon to show —
    -- the shared filter glyph stands in (the card's other fallback is a colour swatch
    -- resolved from the spec's trackable list, which a filter is never in).
    if DF.ParseADFilterRef and DF:ParseADFilterRef(auraName) then
        -- ☠ ".png" is mandatory in the path -- a PNG does not resolve extensionless
        -- the way .tga does, and it fails silently when omitted.
        return "Interface\\AddOns\\DandersFrames\\Media\\Icons\\filter_list.png"
    end
    -- Static icon table — always returns the correct icon regardless of talents
    local icons = DF.AuraDesigner.IconTextures
    if icons and icons[auraName] then
        return icons[auraName]
    end
    -- Fallback to dynamic API for any aura not in the static table
    local spellIDs = DF.AuraDesigner.SpellIDs
    local specIDs = spellIDs and specKey and spellIDs[specKey]
    local spellID = specIDs and specIDs[auraName]
    if not spellID or spellID == 0 then
        -- Ad-hoc "#<id>" keys resolve directly to their embedded spell ID
        spellID = AdHocSpellID(auraName)
    end
    if not spellID or spellID == 0 then
        -- SpellDB fallback (all-spec support): auras with no curated Config
        -- entry resolve by name through the FilterRegistry SpellDB
        local R = DF.FilterRegistry
        local rec = R and R.GetSpellByName and R:GetSpellByName(auraName)
        spellID = rec and rec.id
    end
    if not spellID or spellID == 0 then return nil end
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID)
    elseif GetSpellTexture then
        return GetSpellTexture(spellID)
    end
    return nil
end
P.GetAuraIcon = GetAuraIcon

-- (CountActiveEffects removed — uncalled since the v4 flat-card redesign;
-- reclaimed for the file-scope 200-locals ceiling.)

-- ============================================================
-- MULTI-TRIGGER HELPERS
-- Functions for managing trigger auras on frame-level effects
-- ============================================================

-- Get triggers for a frame effect (returns owning aura name in a table if no explicit triggers)
local function GetFrameEffectTriggers(auraName, typeKey)
    local auraCfg = CurrentAuraPool()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    if typeCfg and typeCfg.triggers then
        return typeCfg.triggers
    end
    return { auraName }  -- Default: just the owning aura
end
P.GetFrameEffectTriggers = GetFrameEffectTriggers

-- Add a trigger aura to a frame effect. `pool` (optional) pins the target
-- pool — the floating trigger picker captures it at OPEN time so a dropdown
-- surviving a tab switch can't write the trigger into the wrong pool.
-- ============================================================
-- CONDITION GROUPS (editor side)
-- The render path reads typeCfg.conditions; the editor works through this normalised
-- view so the card never has to care which of the two storage shapes is in play:
--   * ONE group  -> stored as the legacy flat typeCfg.triggers (unchanged on disk, and
--                   the factory's plain union path renders it exactly as before)
--   * 2+ groups  -> promoted to typeCfg.conditions, and demoted back on the way down
-- Callers address groups by INDEX; group 1 is always the effect's original trigger list.
-- ============================================================
local AD_MAX_COND_GROUPS = 5

-- Array of { triggers = {...} }. Always at least one group, never nil.
local function GetEffectConditionGroups(auraName, typeKey)
    local auraCfg = CurrentAuraPool()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    local c = typeCfg and typeCfg.conditions
    if type(c) == "table" and type(c.groups) == "table" and #c.groups > 0 then
        return c.groups
    end
    return { { triggers = GetFrameEffectTriggers(auraName, typeKey) } }
end
P.GetEffectConditionGroups = GetEffectConditionGroups

-- "ALL" (groups are ORs, ANDed) or "ANY" (groups are ANDs, ORed). Default ALL.
local function GetEffectConditionMode(auraName, typeKey)
    local auraCfg = CurrentAuraPool()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    local c = typeCfg and typeCfg.conditions
    return (type(c) == "table" and c.mode) or "ALL"
end
P.GetEffectConditionMode = GetEffectConditionMode

local function SetEffectConditionMode(auraName, typeKey, mode, pool)
    local typeCfg = EnsureTypeConfig(auraName, typeKey, pool)
    if type(typeCfg.conditions) ~= "table" then return end
    typeCfg.conditions.mode = mode
end
P.SetEffectConditionMode = SetEffectConditionMode

-- Promote to the grouped shape and append an empty group. Returns the new group index,
-- or nil at the cap.
local function AddEffectConditionGroup(auraName, typeKey, pool)
    local typeCfg = EnsureTypeConfig(auraName, typeKey, pool)
    if type(typeCfg.conditions) ~= "table" then
        -- First promotion: the existing flat list becomes group 1 verbatim, so turning a
        -- simple effect into a conditional one never changes what it already matched.
        typeCfg.conditions = {
            mode = "ALL",
            groups = { { triggers = typeCfg.triggers or { auraName } } },
        }
    end
    local groups = typeCfg.conditions.groups
    if #groups >= AD_MAX_COND_GROUPS then return nil end
    tinsert(groups, { triggers = {} })
    return #groups
end
P.AddEffectConditionGroup = AddEffectConditionGroup

-- Remove a group; dropping back to one demotes to the flat list so the stored shape
-- matches what the render path will actually take.
local function RemoveEffectConditionGroup(auraName, typeKey, index)
    local auraCfg = CurrentAuraPool()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    local c = typeCfg and typeCfg.conditions
    if type(c) ~= "table" or type(c.groups) ~= "table" then return end
    if #c.groups <= 1 then return end
    tremove(c.groups, index)
    if #c.groups == 1 then
        typeCfg.triggers = c.groups[1].triggers
        typeCfg.conditions = nil
    end
end
P.RemoveEffectConditionGroup = RemoveEffectConditionGroup

-- Add/remove within one group. Group 1 of an ungrouped effect is the flat list, so these
-- fall through to the legacy helpers and the on-disk shape is untouched.
local function AddEffectTriggerToGroup(auraName, typeKey, index, triggerName, pool)
    local typeCfg = EnsureTypeConfig(auraName, typeKey, pool)
    local c = typeCfg.conditions
    if type(c) ~= "table" or type(c.groups) ~= "table" then
        return P.AddFrameEffectTrigger(auraName, typeKey, triggerName, pool)
    end
    local g = c.groups[index]
    if not g then return end
    g.triggers = g.triggers or {}
    for _, t in ipairs(g.triggers) do
        if t == triggerName then return end
    end
    tinsert(g.triggers, triggerName)
end
P.AddEffectTriggerToGroup = AddEffectTriggerToGroup

local function RemoveEffectTriggerFromGroup(auraName, typeKey, index, triggerName)
    local auraCfg = CurrentAuraPool()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    local c = typeCfg and typeCfg.conditions
    if type(c) ~= "table" or type(c.groups) ~= "table" then
        return P.RemoveFrameEffectTrigger(auraName, typeKey, triggerName)
    end
    local g = c.groups[index]
    if not g or type(g.triggers) ~= "table" then return end
    -- A group may empty out (unlike the flat list, which keeps a minimum of one): an
    -- empty group makes the whole expression unrenderable, which the card surfaces.
    for i, t in ipairs(g.triggers) do
        if t == triggerName then tremove(g.triggers, i); return end
    end
end
P.RemoveEffectTriggerFromGroup = RemoveEffectTriggerFromGroup

-- Would-be chain length, for the editor's over-cap warning. Mirrors the factory:
-- ALL = one link per group, ANY = the product of the group sizes.
local function EffectChainLinkCount(auraName, typeKey)
    local groups = GetEffectConditionGroups(auraName, typeKey)
    if #groups < 2 then return 1 end
    if GetEffectConditionMode(auraName, typeKey) == "ALL" then return #groups end
    local n = 1
    for _, g in ipairs(groups) do n = n * math.max(1, #(g.triggers or {})) end
    return n
end
P.EffectChainLinkCount = EffectChainLinkCount

local function AddFrameEffectTrigger(auraName, typeKey, triggerName, pool)
    local typeCfg = EnsureTypeConfig(auraName, typeKey, pool)
    if not typeCfg.triggers then
        typeCfg.triggers = { auraName }  -- Initialize with owner
    end
    -- Check not already present
    for _, t in ipairs(typeCfg.triggers) do
        if t == triggerName then return end
    end
    tinsert(typeCfg.triggers, triggerName)
end
P.AddFrameEffectTrigger = AddFrameEffectTrigger

-- Remove a trigger aura from a frame effect (minimum 1 trigger required)
local function RemoveFrameEffectTrigger(auraName, typeKey, triggerName)
    local auraCfg = CurrentAuraPool()[auraName]
    local typeCfg = auraCfg and auraCfg[typeKey]
    if not typeCfg or not typeCfg.triggers or #typeCfg.triggers <= 1 then return end
    for i, t in ipairs(typeCfg.triggers) do
        if t == triggerName then
            tremove(typeCfg.triggers, i)
            break
        end
    end
end
P.RemoveFrameEffectTrigger = RemoveFrameEffectTrigger

-- ============================================================
-- SHARED SPELL PICKER STATE
-- Every AD picking context (add indicator, layout-group adds,
-- triggers) opens the shared spell database picker
-- (FilterRegistry/SpellPicker.lua) over the right panel; the
-- open helpers live below the tab system (OpenADPicker).
-- ============================================================

-- (S.adPickerHandle declared on the state table)
S.adPickerDirty = false  -- an add landed while the picker stayed open
                             -- (the tab behind it is stale; rebuilt on close)

-- Close the shared picker if it's open. Called on sub-tab, main-tab and
-- spec switches: the picker's records/handlers capture the pool and effect
-- from open time, so a stale open picker must not linger.
local function CloseADPicker()
    if S.adPickerHandle and S.adPickerHandle:IsOpen() then
        S.adPickerHandle:Close()
    end
end
P.CloseADPicker = CloseADPicker

-- ============================================================
-- FILTER PICKER  (a small anchored dropdown of registry filters)
-- Presets in Categories order with live counts, then customs name-sorted. No
-- Uncategorised option by design — every consumer needs a resolvable include map.
--
-- Extracted from the filter group card's "+ Add Filter", which owned the only copy.
-- Two more consumers arrived (an effect's trigger list, and a filter OWNING an
-- effect) and forking a 120-line bespoke dropdown three ways was not on.
--
-- opts = {
--   anchor    — the button to hang under; clicking it again closes (toggle)
--   isLinked  — function(kind, key) -> true to leave the candidate out
--   onPick    — function(kind, key, label); the picker closes itself first
--   emptyText — optional override for the no-candidates line
-- }
-- ============================================================
local function OpenFilterPicker(opts)
    local R = DF.FilterRegistry
    if not R or not opts or not opts.anchor then return end
    local anchor = opts.anchor
    local isLinked = opts.isLinked or function() return false end

    local candidates = {}
    for _, cat in ipairs(R.Categories) do
        if not isLinked("preset", cat.key) then
            local enabled, total = R:PresetCounts(cat.key)
            tinsert(candidates, { kind = "preset", key = cat.key,
                label = format("%s |cff888888(%d/%d)|r", L[cat.name], enabled, total) })
        end
    end
    local freeCustoms = {}
    for cfId in pairs(R:ReadStore().customFilters) do
        if not isLinked("custom", cfId) then tinsert(freeCustoms, cfId) end
    end
    sort(freeCustoms, function(a, b)
        local fa, fb = R:GetCustomFilter(a), R:GetCustomFilter(b)
        local na, nb = (fa and fa.name or ""), (fb and fb.name or "")
        if na ~= nb then return na < nb end
        return a < b
    end)
    for _, cfId in ipairs(freeCustoms) do
        local cf = R:GetCustomFilter(cfId)
        tinsert(candidates, { kind = "custom", key = cfId,
            label = format("%s |c%s(%s)|r", (cf and cf.name) or cfId, GUI:ToneHex("info"), L["Custom"]) })
    end

    local dropName = "DFADFilterGroupPicker"
    local drop = _G[dropName]
    if not drop then
        drop = CreateFrame("Frame", dropName, UIParent, "BackdropTemplate")
        drop:SetFrameStrata("FULLSCREEN_DIALOG")
        drop:SetClampedToScreen(true)
        -- Parented to UIParent, so it does NOT inherit the GUI's scale -- register it
        -- or it draws at 100% beside a scaled panel. Not the overlay below: that one
        -- is SetAllPoints(UIParent) and scaling it would shrink what it can catch.
        if GUI.RegisterScaledSurface then GUI:RegisterScaledSurface(drop) end
        local overlay = CreateFrame("Button", nil, UIParent)
        overlay:SetAllPoints(UIParent)
        overlay:SetFrameStrata("FULLSCREEN")
        overlay:Hide()
        overlay:SetScript("OnClick", function()
            drop:Hide()
            overlay:Hide()
        end)
        drop._overlay = overlay
        -- SetPropagateKeyboardInput is protected in combat for insecure code: skip the
        -- calls there (keys propagate anyway — ESC just hides the dropdown), and don't
        -- trap keyboard input if built mid-combat.
        if not InCombatLockdown() then
            drop:EnableKeyboard(true)
            drop:SetPropagateKeyboardInput(true)
        end
        drop:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
                self:Hide()
            else
                if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
            end
        end)
        drop:SetScript("OnHide", function(self)
            self._ownerBtn = nil
            if self._overlay then self._overlay:Hide() end
        end)
    end
    if drop:IsShown() and drop._ownerBtn == anchor then
        drop:Hide()
        return
    end
    drop._ownerBtn = anchor

    local DROP_W = 240
    local MAX_H = 300
    drop:SetWidth(DROP_W)
    ApplyBackdrop(drop, GUI.Colors.background, GUI.Colors.border)

    if not drop._scrollFrame then
        local sf = CreateFrame("ScrollFrame", nil, drop)
        sf:SetPoint("TOPLEFT", 0, 0)
        sf:SetPoint("BOTTOMRIGHT", 0, 0)
        drop._scrollFrame = sf
        local sc = CreateFrame("Frame", nil, sf)
        sc:SetWidth(DROP_W)
        sf:SetScrollChild(sc)
        drop._scrollChild = sc
        sf:SetScript("OnMouseWheel", function(self2, delta2)
            local cur = self2:GetVerticalScroll()
            local maxS = max(0, self2:GetVerticalScrollRange())
            self2:SetVerticalScroll(max(0, min(maxS, cur - (delta2 * 24))))
        end)
    end
    local scrollChild = drop._scrollChild
    local scrollFrame = drop._scrollFrame
    scrollChild:SetWidth(DROP_W)
    for _, child in ipairs({scrollChild:GetChildren()}) do child:Hide(); child:SetParent(nil) end
    for _, rgn in ipairs({scrollChild:GetRegions()}) do
        if rgn:GetObjectType() == "FontString" or rgn:GetObjectType() == "Texture" then rgn:Hide() end
    end
    scrollFrame:Show()
    scrollChild:EnableMouseWheel(true)
    scrollChild:SetScript("OnMouseWheel", function(_, delta2)
        scrollFrame:GetScript("OnMouseWheel")(scrollFrame, delta2)
    end)

    local C_TEXT, C_TEXT_DIM = GUI.Colors.text, GUI.Colors.textDim
    local dy2 = -4
    if #candidates == 0 then
        local none = scrollChild:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(none, 9, "")
        none:SetPoint("TOPLEFT", 8, dy2 - 4)
        none:SetText(opts.emptyText or L["No filters available"])
        none:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.7)
        dy2 = dy2 - 24
    end
    for _, cand in ipairs(candidates) do
        local ROW_H = 24
        local row = CreateFrame("Button", nil, scrollChild)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 4, dy2)
        row:SetPoint("RIGHT", scrollChild, "RIGHT", -4, 0)

        local rName = row:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(rName, 9, "")
        rName:SetPoint("LEFT", 8, 0)
        rName:SetText(cand.label)
        rName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        local hl = row:CreateTexture(nil, "BACKGROUND")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0)
        row:SetScript("OnEnter", function() hl:SetColorTexture(1, 1, 1, 0.03) end)
        row:SetScript("OnLeave", function() hl:SetColorTexture(1, 1, 1, 0) end)

        local capturedCand = cand
        row:SetScript("OnClick", function()
            drop:Hide()
            if opts.onPick then opts.onPick(capturedCand.kind, capturedCand.key, capturedCand.label) end
        end)
        dy2 = dy2 - ROW_H
    end
    local totalH = -dy2 + 4
    scrollChild:SetHeight(totalH)
    drop:SetHeight(math.min(totalH, MAX_H))

    drop:ClearAllPoints()
    drop:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    drop:Show()
    if drop._overlay then drop._overlay:Show() end
end
P.OpenFilterPicker = OpenFilterPicker

-- ============================================================
-- LAYOUT GROUP HELPERS
-- Functions for managing layout groups
-- ============================================================

-- State for expanded layout group cards
local expandedGroups = {}
P.expandedGroups = expandedGroups

-- expandedGroups key for a layout group id on the ACTIVE tab: raw numeric id
-- on My Buffs (legacy keys, kept as-is), "othergroup:<id>" on Other Buffs.
-- The two id counters overlap, so the string prefix keeps expansion state
-- per-pool ("dgroup:<id>" is the Debuffs form in the same table).
local function GroupExpandKey(groupID)
    if IsOtherTab() then return "othergroup:" .. groupID end
    return groupID
end
P.GroupExpandKey = GroupExpandKey

-- Find which layout group (if any) an indicator belongs to — searched in the
-- ACTIVE tab's group store, so an other-pool indicator only matches other-pool
-- groups (a same-named spec-pool member with a matching indicatorID can never
-- false-match across pools).
local function GetIndicatorLayoutGroup(auraName, indicatorID)
    local groups = CurrentLayoutGroups()
    for _, group in ipairs(groups) do
        if group.members then
            for _, member in ipairs(group.members) do
                if member.auraName == auraName and member.indicatorID == indicatorID then
                    return group
                end
            end
        end
    end
    return nil
end
P.GetIndicatorLayoutGroup = GetIndicatorLayoutGroup

-- (GetUngroupedIndicators removed — uncalled since the group picker moved to
-- the full spell-picker "group" mode; reclaimed for the 200-locals ceiling.)

-- Create a new layout group. kind: nil/"members" = classic member arranger
-- (legacy records carry no kind); "filter" = a container-backed group linked to
-- registry filters (stable preset keys / custom ids in filterSelection) with
-- uniform per-group styling (iconSize / maxIcons on top of the shared layout).
local function CreateLayoutGroup(name, kind)
    local adDB = GetAuraDesignerDB()
    if not adDB then return nil end
    -- Pool-routed: the Other Buffs tab creates into the flat spec-independent
    -- store (born lazily HERE — the first add) with its own id counter.
    local groups, id
    if IsOtherTab() then
        groups = GetOtherLayoutGroups(true)  -- the first add creates the store
        if not adDB.nextOtherLayoutGroupID then adDB.nextOtherLayoutGroupID = 1 end
        id = adDB.nextOtherLayoutGroupID
        adDB.nextOtherLayoutGroupID = id + 1
    else
        groups = GetSpecLayoutGroups()
        if not adDB.nextLayoutGroupID then adDB.nextLayoutGroupID = 1 end
        id = adDB.nextLayoutGroupID
        adDB.nextLayoutGroupID = id + 1
    end
    local group = {
        id = id,
        name = name or NextGroupName(groups, (kind == "filter") and "Filter Group" or "Group"),
        anchor = "TOPLEFT",
        offsetX = 0,
        offsetY = 0,
        growDirection = "RIGHT_DOWN",
        iconsPerRow = 8,
        spacing = 2,
    }
    if kind == "filter" then
        group.kind = "filter"
        group.filterSelection = { presets = {}, customs = {} }
        group.iconSize = 24
        -- Filter groups start compact (4×4); member groups keep the shared 8.
        -- Creation-time values only — existing saved groups are untouched.
        group.iconsPerRow = 4
        group.maxIcons = 4
    else
        group.members = {}
    end
    tinsert(groups, group)
    return group
end
P.CreateLayoutGroup = CreateLayoutGroup

-- Delete a layout group by ID (from the ACTIVE tab's store; the member-
-- indicator cascade removes from the active pool via RemoveIndicatorInstance's
-- CurrentAuraPool routing — members always live in their group's pool)
local function DeleteLayoutGroup(groupID)
    local groups = CurrentLayoutGroups()
    for i, group in ipairs(groups) do
        if group.id == groupID then
            -- Delete all member indicators when deleting the group
            if group.members then
                for _, member in ipairs(group.members) do
                    RemoveIndicatorInstance(member.auraName, member.indicatorID)
                end
            end
            tremove(groups, i)
            break
        end
    end
    expandedGroups[GroupExpandKey(groupID)] = nil
end
P.DeleteLayoutGroup = DeleteLayoutGroup

-- Delete a debuff category group by ID (C2). No member indicators to cascade
-- (category groups own no placed indicators). The caller runs the FULL
-- structural chain afterwards — the group's claimed categories return to the
-- main debuff bar. Card keys are "dgroup:<id>" (see S.BuildDebuffGroupsTab).
local function DeleteDebuffGroup(groupID)
    local groups = DebuffGroupsRead()
    for i, group in ipairs(groups) do
        if group.id == groupID then
            tremove(groups, i)
            break
        end
    end
    expandedGroups["dgroup:" .. groupID] = nil
end
P.DeleteDebuffGroup = DeleteDebuffGroup

-- Find a layout group by ID (active tab's store)
local function GetLayoutGroupByID(groupID)
    local groups = CurrentLayoutGroups()
    for _, group in ipairs(groups) do
        if group.id == groupID then return group end
    end
    return nil
end
P.GetLayoutGroupByID = GetLayoutGroupByID

-- Add a member to a layout group
local function AddGroupMember(groupID, auraName, indicatorID)
    local group = GetLayoutGroupByID(groupID)
    if not group then return end
    if not group.members then group.members = {} end
    -- Check not already in this group
    for _, m in ipairs(group.members) do
        if m.auraName == auraName and m.indicatorID == indicatorID then return end
    end
    tinsert(group.members, { auraName = auraName, indicatorID = indicatorID })
end
P.AddGroupMember = AddGroupMember

-- Remove a member from a layout group
local function RemoveGroupMember(groupID, auraName, indicatorID)
    local group = GetLayoutGroupByID(groupID)
    if not group or not group.members then return end
    for i, m in ipairs(group.members) do
        if m.auraName == auraName and m.indicatorID == indicatorID then
            tremove(group.members, i)
            break
        end
    end
end
P.RemoveGroupMember = RemoveGroupMember

-- Swap two members in a layout group (for reordering)
local function SwapGroupMembers(groupID, idx1, idx2)
    local group = GetLayoutGroupByID(groupID)
    if not group or not group.members then return end
    if idx1 < 1 or idx1 > #group.members or idx2 < 1 or idx2 > #group.members then return end
    group.members[idx1], group.members[idx2] = group.members[idx2], group.members[idx1]
end
P.SwapGroupMembers = SwapGroupMembers

-- Anchor dot pool (populated during CreateFramePreview, used by drag system)
local anchorDots = {}
P.anchorDots = anchorDots

-- Anchor point positions relative to the mock frame
local ANCHOR_POSITIONS = {
    TOPLEFT     = { x = 0,   y = 0,    ax = "TOPLEFT",     ay = "TOPLEFT"     },
    TOP         = { x = 0.5, y = 0,    ax = "TOP",         ay = "TOP"         },
    TOPRIGHT    = { x = 1,   y = 0,    ax = "TOPRIGHT",    ay = "TOPRIGHT"    },
    LEFT        = { x = 0,   y = 0.5,  ax = "LEFT",        ay = "LEFT"        },
    CENTER      = { x = 0.5, y = 0.5,  ax = "CENTER",      ay = "CENTER"      },
    RIGHT       = { x = 1,   y = 0.5,  ax = "RIGHT",       ay = "RIGHT"       },
    BOTTOMLEFT  = { x = 0,   y = 1,    ax = "BOTTOMLEFT",  ay = "BOTTOMLEFT"  },
    BOTTOM      = { x = 0.5, y = 1,    ax = "BOTTOM",      ay = "BOTTOM"      },
    BOTTOMRIGHT = { x = 1,   y = 1,    ax = "BOTTOMRIGHT", ay = "BOTTOMRIGHT" },
}
P.ANCHOR_POSITIONS = ANCHOR_POSITIONS

-- ============================================================
-- FRAME REFERENCES (populated during build)
-- Declared early so drag/indicator/effects code can capture them
-- ============================================================
-- (S.mainFrame declared on the state table)
-- (S.leftPanel declared on the state table)
-- (S.rightPanel declared on the state table)
-- (S.enableBanner declared on the state table)
-- (S.framePreview declared on the state table)
-- (S.dragHintText declared on the state table)

-- Layout anchors — stored during build
-- (S.contentRightInset and S.origY_framePreview are gone: both were written once in
-- Editor.lua and read nowhere, leftovers of the pre-rework layout.)

-- (The DF_AURA_DESIGNER_RESET_GLOBAL popup was retired with the editing-banner
-- "Reset to Global" button — the preset dropdown's "Inherit (Global)" entry now
-- clears a layout's Aura Designer preset override.)

-- ============================================================
-- UI STATE (v4 redesign — tabbed right panel)
-- ============================================================
S.activeTab = "effects"       -- "effects" | "layout" | "global"
S.activeFilter = "all"        -- Filter chip state
local expandedCards = {}           -- { ["placed:AuraName#1"] = true, ["frame:border:AuraName"] = true }
P.expandedCards = expandedCards

-- Tab system frame references
-- (S.tabBar declared on the state table)
local tabButtons = {}       -- { effects = btn, layout = btn, global = btn }
P.tabButtons = tabButtons
local mainTabButtons = {}   -- { my = btn, other = btn } (B2 main pool tab strip)
P.mainTabButtons = mainTabButtons
-- (S.specDropdown declared on the state table)
-- (S.specDropdownUpdate declared on the state table)
-- (S.tabContentFrame declared on the state table)
-- (S.tabScrollFrame declared on the state table)
local effectCardPool = {}   -- Reusable card frames
P.effectCardPool = effectCardPool

-- ============================================================
-- EFFECTS LIST DATA COLLECTION
-- Gathers all effects across all auras into a flat list for
-- the new Effects tab. Replaces the old per-aura view.
-- ============================================================

local FRAME_LEVEL_TYPE_KEYS = { "border", "healthbar", "background", "nametext", "healthtext", "sound" }

-- Remove an ad-hoc "#<id>" aura's config entry once it holds no effects at
-- all (empty/absent indicators array AND no frame-level type keys). Ad-hoc
-- auras exist ONLY through their effects — they are never in the trackable
-- pool — so an emptied config would linger in the profile forever as a
-- phantom entry (group/trigger pickers, SavedVariables growth). Curated
-- auras deliberately keep today's linger behavior. Forward-declared above
-- RemoveIndicatorInstance, which calls it after every removal.
S.CleanupAdHocAura = function(auraName)
    -- Filter-owned records ("@preset:"/"@custom:") clean up on the same rule as ad-hoc
    -- ones: neither is a spell the user picked into the pool, so an entry left holding
    -- nothing but its default priority is pure cruft in the profile.
    local isSynthetic = AdHocSpellID(auraName)
        or (DF.ParseADFilterRef and DF:ParseADFilterRef(auraName) ~= nil)
    if not isSynthetic then return end
    local auras = CurrentAuraPool()
    local auraCfg = auras and auras[auraName]
    if type(auraCfg) ~= "table" then return end
    if auraCfg.indicators and #auraCfg.indicators > 0 then return end
    for _, typeKey in ipairs(FRAME_LEVEL_TYPE_KEYS) do
        if auraCfg[typeKey] ~= nil then return end
    end
    auras[auraName] = nil
end

-- Effect-type display labels. Same file-scope-vs-overlay timing issue as the
-- option tables near the top of this file: build them in a registered refresh
-- fn so they pick up the active locale.
S.FRAME_LEVEL_LABELS = {}
S.PLACED_TYPE_LABELS = {}

local function RefreshEffectLabels()
    S.FRAME_LEVEL_LABELS = {
        border     = L["Border"],
        healthbar  = L["Health Bar"],
        background  = L["Background"],
        nametext   = L["Name Text"],
        healthtext = L["Health Text"],
        sound      = L["Sound Alert"],
    }

    S.PLACED_TYPE_LABELS = {
        icon   = L["Icon"],
        square = L["Square"],
        bar    = L["Bar"],
    }
end

RefreshEffectLabels()
DF:RegisterLocaleRefresh(RefreshEffectLabels)

local BADGE_COLORS = {
    icon       = { r = 0.36, g = 0.72, b = 0.94 },  -- Blue
    square     = { r = 0.51, g = 0.86, b = 0.51 },  -- Green
    bar        = { r = 0.94, g = 0.71, b = 0.24 },  -- Orange
    border     = { r = 0.80, g = 0.50, b = 0.80 },  -- Purple
    healthbar  = { r = 0.94, g = 0.31, b = 0.31 },  -- Red
    background = { r = 0.40, g = 0.55, b = 0.65 },  -- Slate
    nametext   = { r = 0.72, g = 0.72, b = 0.94 },  -- Light blue
    healthtext = { r = 0.72, g = 0.72, b = 0.94 },  -- Light blue
    sound      = { r = 0.94, g = 0.76, b = 0.24 },  -- Gold/yellow
}
P.BADGE_COLORS = BADGE_COLORS

-- Collect all configured effects into a flat, sorted list
-- Returns: { { source="placed"|"frame", auraName, typeKey, ... }, ... }
local function CollectAllEffects()
    local effects = {}

    local spec = ResolveSpec()
    local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
    -- Build display name lookup (only auras belonging to current spec)
    local displayNames = {}
    if trackable then
        for _, info in ipairs(trackable) do
            displayNames[info.name] = info.display
        end
    end

    local isOther = IsOtherTab()
    for auraName, auraCfg in pairs(CurrentAuraPool(spec)) do
        -- My Buffs: only show effects for auras belonging to the current spec.
        -- Ad-hoc "#<id>" auras (picker add-by-ID) always belong — they are
        -- never in the trackable pool, so resolve their display name live.
        -- Other Buffs: the pool is spec-independent — every record shows
        -- (names are SpellDB names or ad-hoc keys; resolve display live).
        local adHocID = AdHocSpellID(auraName)
        local displayName
        -- Filter-owned effects ("@preset:<key>" / "@custom:<id>") are named from the
        -- registry, in BOTH pools — they are spec-independent by nature. Resolved
        -- FIRST: this gate drops any record it cannot name, so a filter-owned effect
        -- that fell through here would be invisible and undeletable.
        displayName = DF.ADFilterRefDisplayName and DF:ADFilterRefDisplayName(auraName)
        if displayName then
            -- named
        elseif isOther then
            displayName = OtherPoolDisplayName(auraName)
        else
            displayName = displayNames[auraName]
            if not displayName and adHocID then
                displayName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(adHocID) or auraName
            end
            -- ☠ LAST RESORT — NEVER LEAVE A RECORD UNNAMED. The gate below drops
            -- anything without a display name, so a key that falls through here
            -- is an effect that still RENDERS on the frame (the factory resolves
            -- identity separately) but has no card, no delete button and no way
            -- out short of a new profile. Add-by-ID used to mint exactly such
            -- keys. Name it from its own spell, then from the raw key, so it is
            -- always visible and always removable. Same doctrine as
            -- MigrateToSpecScoped's "NEVER drop it" parking.
            -- Safe against leaking another spec's auras: this pool is already
            -- spec-scoped storage (adDB.auras[spec]), not a flat table filtered
            -- by name — the nameability test never did the spec scoping.
            if not displayName then
                local ids = Adapter and Adapter.GetAuraSpellIDs
                    and Adapter:GetAuraSpellIDs(spec, auraName)
                local id = ids and ids[1]
                displayName = (id and C_Spell and C_Spell.GetSpellName
                    and C_Spell.GetSpellName(id)) or auraName
            end
        end
        if type(auraCfg) == "table" and displayName then
            -- Placed indicators
            if auraCfg.indicators then
                for _, indicator in ipairs(auraCfg.indicators) do
                    tinsert(effects, {
                        source      = "placed",
                        auraName    = auraName,
                        displayName = displayName,
                        indicatorID = indicator.id,
                        typeKey     = indicator.type,
                        config      = indicator,
                        anchor      = indicator.anchor or "CENTER",
                    })
                end
            end

            -- Frame-level effects (current per-aura model). Sound is NOT offered on a
            -- filter-owned record: the native sound path registers per spell ID, so a
            -- 600-spell filter would mean 600 registrations.
            local isFilterOwned = DF.ParseADFilterRef and DF:ParseADFilterRef(auraName) ~= nil
            for _, typeKey in ipairs(FRAME_LEVEL_TYPE_KEYS) do
                if auraCfg[typeKey] and not (isFilterOwned and typeKey == "sound") then
                    tinsert(effects, {
                        source      = "frame",
                        auraName    = auraName,
                        displayName = displayName,
                        typeKey     = typeKey,
                        config      = auraCfg[typeKey],
                    })
                end
            end
        end
    end

    -- Sort: newest first (reverse by insertion order — higher IDs first for placed)
    sort(effects, function(a, b)
        -- Placed before frame-level
        if a.source ~= b.source then
            return a.source == "placed"
        end
        -- Within placed: higher indicatorID first (newest)
        if a.source == "placed" and b.source == "placed" then
            return (a.indicatorID or 0) > (b.indicatorID or 0)
        end
        -- Within frame-level: alphabetical by type
        return a.typeKey < b.typeKey
    end)

    return effects
end
P.CollectAllEffects = CollectAllEffects

-- Check if a specific aura + type combo already has a placed indicator
local function IsAuraTypePlaced(auraName, typeKey)
    local auraCfg = CurrentAuraPool()[auraName]
    if not auraCfg or not auraCfg.indicators then return false end
    for _, indicator in ipairs(auraCfg.indicators) do
        if indicator.type == typeKey then return true end
    end
    return false
end
P.IsAuraTypePlaced = IsAuraTypePlaced

-- ============================================================
-- DRAG AND DROP SYSTEM
-- Modeled after DandersCDM's ghost-based drag pattern:
--   Ghost frame (TOOLTIP strata, EnableMouse false) follows cursor
--   Anchor dots act as drop targets via OnEnter/OnLeave
--   OnUpdate frame polls IsMouseButtonDown for drop detection
-- ============================================================

local dragState = {
    isDragging = false,
    auraName = nil,         -- Which aura is being dragged
    auraInfo = nil,         -- Full aura info table
    specKey = nil,          -- Spec key for icon lookup
    dropAnchor = nil,       -- Currently hovered anchor name
    moveIndicatorID = nil,  -- Set when re-dragging an existing placed indicator
    indicatorType = nil,    -- "icon" | "square" | "bar" — type to create on drop
}
P.dragState = dragState

S.dragGhost = nil
S.dragUpdateFrame = nil

local function CreateDragGhost()
    if S.dragGhost then return S.dragGhost end

    S.dragGhost = CreateFrame("Frame", "DFAuraDesignerDragGhost", UIParent, "BackdropTemplate")
    S.dragGhost:SetSize(36, 36)
    S.dragGhost:SetFrameStrata("TOOLTIP")
    S.dragGhost:SetFrameLevel(1000)
    S.dragGhost:EnableMouse(false)  -- KEY: mouse events pass through to drop targets
    -- UIParent-parented, so it needs the GUI scale explicitly. It matters more here
    -- than on a dialog: the ghost is dragged ACROSS scaled cards, so an unscaled one
    -- is visibly the wrong size against the slot it is being dropped into.
    if GUI.RegisterScaledSurface then GUI:RegisterScaledSurface(S.dragGhost) end
    S.dragGhost:Hide()

    if not S.dragGhost.SetBackdrop then Mixin(S.dragGhost, BackdropTemplateMixin) end
    DF.GUI:CreateElementBackdrop(S.dragGhost, {
        edgeSize = 2,
        bgColor     = { 0.05, 0.05, 0.05, 0.9 },
    })

    -- Spell icon
    local icon = S.dragGhost:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    S.dragGhost.icon = icon

    -- Name label under ghost
    local label = S.dragGhost:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    label:SetPoint("TOP", S.dragGhost, "BOTTOM", 0, -2)
    label:SetTextColor(1, 1, 1, 0.8)
    S.dragGhost.label = label

    return S.dragGhost
end

-- (S.EndDrag declared on the state table)

-- Start a move-drag for an existing placed indicator (the ghost +
-- cursor-following + anchor-dot system; new-placement drags died with the
-- old spell-picker cards -- indicators are placed via the shared picker now).
local function StartMoveDrag(auraName, indicatorID, specKey)
    if dragState.isDragging then return end

    dragState.isDragging = true
    dragState.auraName = auraName
    dragState.moveIndicatorID = indicatorID
    dragState.specKey = specKey
    dragState.dropAnchor = nil

    -- Build minimal auraInfo for hints
    local adDB = GetAuraDesignerDB()
    local displayName = auraName
    if IsOtherTab() then
        -- Other-pool keys are SpellDB names / ad-hoc ids — resolve display live
        displayName = OtherPoolDisplayName(auraName)
    else
        local auraList = Adapter and Adapter:GetTrackableAuras(ResolveSpec())
        if auraList then
            for _, info in ipairs(auraList) do
                if info.name == auraName then
                    dragState.auraInfo = info
                    displayName = info.display or auraName
                    break
                end
            end
        end
    end

    -- Setup ghost
    local ghost = CreateDragGhost()
    local tc = GetThemeColor()
    ghost:SetBackdropBorderColor(tc.r, tc.g, tc.b, 1)

    local iconTex = GetAuraIcon(specKey, auraName)
    if iconTex then
        ghost.icon:SetTexture(iconTex)
    else
        ghost.icon:SetColorTexture(0.3, 0.3, 0.3, 1)
    end
    ghost.label:SetText(displayName)
    ghost:Show()

    -- Show drag hint
    if S.dragHintText then
        S.dragHintText:SetText(format(L["Drop on an anchor point to move %s"], displayName))
        S.dragHintText:SetTextColor(tc.r, tc.g, tc.b, 0.9)
    end

    -- Show and enlarge all anchor dots
    local dc = GetThemeColor()
    for _, dotFrame in pairs(anchorDots) do
        dotFrame:Show()
        dotFrame.dot:SetSize(10, 10)
        dotFrame.dot:SetColorTexture(dc.r, dc.g, dc.b, 0.5)
    end

    -- Start cursor following
    if not S.dragUpdateFrame then
        S.dragUpdateFrame = CreateFrame("Frame")
    end
    S.dragUpdateFrame:SetScript("OnUpdate", function()
        if not dragState.isDragging then
            S.dragUpdateFrame:Hide()
            return
        end

        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        local cursorX, cursorY = x / scale, y / scale

        ghost:ClearAllPoints()
        ghost:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cursorX + 10, cursorY - 10)

        if not IsMouseButtonDown("LeftButton") then
            S.EndDrag()
        end
    end)
    S.dragUpdateFrame:Show()
end

S.EndDrag = function()
    if not dragState.isDragging then return end

    local auraName = dragState.auraName
    local dropAnchor = dragState.dropAnchor
    local moveID = dragState.moveIndicatorID
    local indicatorType = dragState.indicatorType or "icon"

    -- Clear state
    dragState.isDragging = false
    dragState.auraName = nil
    dragState.auraInfo = nil
    dragState.specKey = nil
    dragState.dropAnchor = nil
    dragState.moveIndicatorID = nil
    dragState.indicatorType = nil

    -- Hide ghost
    if S.dragGhost then S.dragGhost:Hide() end

    -- Stop cursor following
    if S.dragUpdateFrame then
        S.dragUpdateFrame:Hide()
        S.dragUpdateFrame:SetScript("OnUpdate", nil)
    end

    -- Clear drag hint
    if S.dragHintText then
        S.dragHintText:SetText("")
    end

    -- Hide anchor dots (only visible during drag)
    local dc = GetThemeColor()
    for _, dotFrame in pairs(anchorDots) do
        dotFrame:Hide()
        dotFrame.dot:SetSize(6, 6)
        dotFrame.dot:SetColorTexture(dc.r, dc.g, dc.b, 0.3)
    end

    -- Process the drop
    if auraName and dropAnchor then
        if moveID then
            -- Move existing indicator to the new anchor
            local inst = GetIndicatorByID(auraName, moveID)
            if inst then
                inst.anchor = dropAnchor
                inst.offsetX = 0
                inst.offsetY = 0
            end
        else
            -- Create a new indicator instance at the dropped anchor
            local inst = CreateIndicatorInstance(auraName, indicatorType)
            if inst then
                inst.anchor = dropAnchor
            end
        end

        -- Expand the new indicator card in the Effects tab (pool-prefixed key)
        local auraCfg = CurrentAuraPool()[auraName]
        local lastInst = auraCfg and auraCfg.indicators and auraCfg.indicators[#auraCfg.indicators]
        if lastInst then
            local cardKey = "placed:" .. PoolKeyPrefix() .. auraName .. "#" .. lastInst.id
            expandedCards[cardKey] = true
        end
    end

    -- Refresh everything
    DF:AuraDesigner_RefreshPage()
end

-- ============================================================
-- PLACED INDICATORS ON PREVIEW
-- Small icons/squares/bars rendered at anchor positions
-- ============================================================

local placedIndicators = {}
P.placedIndicators = placedIndicators

-- Set by ClearPlacedIndicators, consumed by the S.page's RefreshStates: tab
-- switching re-enters the S.page through GUI RefreshCached -> RefreshStates ONLY
-- (the builder is cache-skipped), and RefreshStates early-outs when the S.page
-- dimensions are unchanged — so a canvas cleared by the OnHide hook stayed
-- blank on every same-size revisit (the first revisit only worked because the
-- dims baseline was captured pre-layout). The flag lets the dimension guard
-- distinguish "nothing changed" from "cleared and awaiting repaint".
S.placedCleared = false

local function ClearPlacedIndicators()
    -- Preview border ANIMATIONS must be stopped explicitly on every frame this
    -- pass hides: the drivers are external (Border.lua's shared UIParent-hosted
    -- driver ticks secretRect borders EVEN WHILE HIDDEN), so hiding without
    -- StopAnimation leaves orphaned ticks — the same mandatory teardown the
    -- live container runs (_teardownContainer). Group placeholder slots carry
    -- their sample-frame children's borders too.
    local B = DF.Border
    local function stopAnims(f)
        if not B then return end
        if f.dfBorder then B:StopAnimation(f.dfBorder) end
        local samples = f.sampleFrames
        if samples then
            for i = 1, #samples do
                if samples[i].dfBorder then B:StopAnimation(samples[i].dfBorder) end
            end
        end
    end
    for _, ind in ipairs(placedIndicators) do
        stopAnims(ind)
        ind:Hide()
    end
    wipe(placedIndicators)

    -- Clean up AD indicator maps on the mockFrame
    if S.framePreview and S.framePreview.mockFrame then
        local mock = S.framePreview.mockFrame
        if mock.dfADPreviewSlots then
            for _, rec in pairs(mock.dfADPreviewSlots) do
                stopAnims(rec.slot)
                rec.slot:Hide()
                -- The alert slot carries no border (its style is duration-only), so it has
                -- no animation to stop — only the indicator's slot needs stopAnims.
                if rec.alertSlot then rec.alertSlot:Hide() end
            end
        end
        mock.dfAD = nil
    end
    S.placedCleared = true
end
P.ClearPlacedIndicators = ClearPlacedIndicators

-- ============================================================
-- NATIVE PREVIEW SLOTS (12.1)
-- Each placed indicator on the canvas is a PREVIEW SLOT: a plain frame
-- styled + painted by the container engine's own styler with the exact
-- config the live factory builds (Factory:BuildPreviewConfig) — the
-- preview IS the live rendering. Slots are pooled per instanceKey and
-- recreated when the structural sig changes (regions are create-only).
-- ============================================================

local function RenderPreviewIndicator(mockFrame, spec, auraName, info, indicator, effectiveConfig, instanceKey)
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    local AC = DF.AuraContainer
    if not (Factory and Factory.BuildPreviewConfig and AC and AC.StylePreviewSlot) then return nil end

    -- The aura's real spell ID lives in the spell-pool config (the trackable-
    -- aura info entries don't carry IDs) — this drives the previewed icon and
    -- identity, exactly like the live container's filter map.
    local specIDs = DF.AuraDesigner.SpellIDs and DF.AuraDesigner.SpellIDs[spec]
    local spellID = specIDs and specIDs[auraName]
    if type(spellID) == "table" then spellID = spellID[1] end
    if not spellID then
        -- Ad-hoc "#<id>" keys resolve directly — mirror BuildADIdentityFilters
        spellID = AdHocSpellID(auraName)
    end
    if not spellID then
        -- SpellDB fallback (all-spec support) — mirror BuildADIdentityFilters
        local R = DF.FilterRegistry
        local rec = R and R.GetSpellByName and R:GetSpellByName(auraName)
        spellID = rec and rec.id
    end
    -- Resolve the global defaults with the Factory's OWN resolver so the canvas preview and
    -- the live render can never disagree on the fallback chain. (Level/strata come along in
    -- the table but the preview ignores them: the canvas is standalone, not layered over a
    -- unit frame, so there is nothing for a z-order band to mean there.)
    local defs = Factory.ResolveDefaults and Factory.ResolveDefaults(GetAuraDesignerDB())
    local cfg, sig = Factory:BuildPreviewConfig(mockFrame, effectiveConfig, indicator.type or "icon", spellID, defs)
    if not (cfg.testEntries and cfg.testEntries[1]) then
        -- No resolvable spell ID: synthesize an entry from the configured art so
        -- the paint can never fall back to the generic curated pool.
        cfg.testEntries = { { name = (info and info.display) or auraName } }
    end
    do
        local e = cfg.testEntries[1]
        if not e.icon then e.icon = GetAuraIcon(spec, auraName) end
        e.duration = 15
        e.stacks = (indicator.type ~= "bar") and 3 or 0
    end

    local store = mockFrame.dfADPreviewSlots
    if not store then store = {}; mockFrame.dfADPreviewSlots = store end
    local rec = store[instanceKey]
    if rec and rec.sig ~= sig then
        -- Abandoned slot: stop its border animation — the external shared
        -- driver ticks secretRect borders even while hidden (Border.lua).
        if rec.slot.dfBorder and DF.Border then DF.Border:StopAnimation(rec.slot.dfBorder) end
        rec.slot:Hide()
        if rec.alertSlot then rec.alertSlot:Hide() end
        rec = nil
    end
    if not rec then
        rec = { slot = CreateFrame("Frame", nil, mockFrame), sig = sig }
        store[instanceKey] = rec
    end
    local slot = rec.slot
    AC.StylePreviewSlot(slot, cfg)

    local lay = cfg.layout or {}
    if lay.sizeX then
        slot:SetSize(lay.sizeX, lay.sizeY or lay.sizeX)
    else
        local s = lay.size or 24
        slot:SetSize(s, s)
    end
    slot:SetScale(lay.scale or 1)
    slot:ClearAllPoints()
    slot:SetPoint(lay.anchor or "TOPLEFT", mockFrame, lay.anchor or "TOPLEFT", lay.offsetX or 0, lay.offsetY or 0)
    slot:SetFrameStrata(mockFrame:GetFrameStrata())
    slot:SetFrameLevel(mockFrame:GetFrameLevel() + 8)
    -- ★ ALPHA. The canvas set size, scale, anchor, strata and level but never alpha, so an
    -- indicator dropped to 40% rendered full-strength here while the live frame faded it
    -- correctly — the preview disagreeing with the thing it previews.
    -- Alpha is not in cfg because it is not a style/layout field: live applies it separately
    -- through applyPlacedAlpha, which stashes _dfADBaseAlpha for the OOR fade and writes the
    -- slot's host. The canvas has neither a handle nor an OOR pass, so it reads the SAME
    -- source key with the SAME fallback instead — previews differ in DATA, never in rendering.
    slot:SetAlpha(tonumber(indicator.alpha) or 1)
    AC.PaintPreviewSlot(slot, cfg, 1)
    slot:Show()

    -- Expiry Alert sample: a SECOND PREVIEW SLOT laid over the indicator's, styled and
    -- painted by the same StylePreviewSlot/PaintPreviewSlot pipeline as the indicator
    -- itself and the group blocks. cfg.alertPreview is a whole slot config from
    -- Factory:BuildAlertPreviewConfig, carrying the SAME style table the live companion
    -- renders — so the FontString, its font, anchor, offsets, alpha and holder level are
    -- all container-engine output here, not decisions made in this file.
    --
    -- This used to hand-build a FontString and hand-set its layering. Two separate bugs
    -- came out of that in one day: the live companion moved and the canvas could not
    -- follow, because the canvas was never DERIVED from it, only numerically matched. The
    -- rule is the one that already covers test mode — a preview may differ in DATA, never
    -- in RENDERING.
    --
    -- nil (hidden) whenever the live companion would also be absent: alertSlotStyle is the
    -- single gate for both, so "off", "no formatter API" and "show-when-missing" can no
    -- longer mean different things on the canvas than they do live.
    local ap = cfg.alertPreview
    if ap then
        local ah = rec.alertSlot
        if not ah then
            ah = CreateFrame("Frame", nil, slot)
            rec.alertSlot = ah
        end
        -- Share the indicator's OWN entry, so both slots count down the same aura for the
        -- same 15s rather than two entries that happen to agree. cfg.testEntries is
        -- rewritten above when no spell ID resolved, hence taking it here and not at build.
        ap.testEntries = cfg.testEntries
        AC.StylePreviewSlot(ah, ap)
        -- SetAllPoints AFTER styling: styleButton_regions sizes the slot from the layout,
        -- and the alert must coincide with the indicator's rect exactly, the way the live
        -- companion's invisible button does.
        ah:ClearAllPoints()
        ah:SetAllPoints(slot)
        ah:SetFrameStrata(slot:GetFrameStrata())
        -- Mode-dependent, exactly like the live companion: a payload reveal clears the
        -- whole row, a TINT sits under the indicator's own timer. Factory.AlertLift is the
        -- shared source so the canvas cannot drift from live (see its note).
        ah:SetFrameLevel(slot:GetFrameLevel()
            + ((Factory.AlertLift and Factory.AlertLift(indicator)) or Factory.ALERT_ROW_LIFT or 13))
        -- Reuse the indicator slot's duration object (PaintPreviewSlot armed it just above)
        -- so the reveal reacts to the very timer it sits on, not a second one.
        AC.PaintPreviewSlot(ah, ap, 1, slot._dfTestDurObj)
        ah:Show()
    elseif rec.alertSlot then
        rec.alertSlot:Hide()
    end
    return slot
end

local function WirePreviewIndicator(slot, capturedAura, capturedID, spec)
    slot:EnableMouse(true)
    if slot.SetMouseClickEnabled then slot:SetMouseClickEnabled(true) end
    slot:SetScript("OnMouseUp", function(_, button)
        if dragState.isDragging then return end
        if button == "RightButton" then
            -- Don't delete grouped indicators (managed by layout group)
            if not GetIndicatorLayoutGroup(capturedAura, capturedID) then
                RemoveIndicatorInstance(capturedAura, capturedID)
                DF:AuraDesigner_RefreshPage()
                -- Structural change: same full refresh as the effect-card ✕ —
                -- the container must rebuild and the buff-row dedup union
                -- shrinks (deleted = no longer tracked).
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end
        elseif button == "LeftButton" then
            -- Collapse all cards and expand only the clicked one. The preview
            -- renders the ACTIVE tab's pool only, so PoolKeyPrefix() at click
            -- time matches the slot's pool (B1 key scheme).
            local cardKey = "placed:" .. PoolKeyPrefix() .. capturedAura .. "#" .. capturedID
            wipe(expandedCards)
            expandedCards[cardKey] = true
            S.activeTab = "effects"
            DF:AuraDesigner_RefreshPage()
        end
    end)
    slot:RegisterForDrag("LeftButton")
    slot:SetScript("OnDragStart", function()
        -- Don't drag grouped indicators (position managed by layout group)
        if GetIndicatorLayoutGroup(capturedAura, capturedID) then return end
        StartMoveDrag(capturedAura, capturedID, spec)
    end)
end

-- Representative preview icons per debuff category. Category membership is
-- Blizzard-secret at runtime, so the editor shows iconic stand-ins instead of
-- real members. Entry encoding: NEGATIVE numbers are spell IDs (icon resolved
-- live via C_Spell.GetSpellTexture — all evergreen player abilities, so they
-- stay valid across patches); positive numbers would be literal texture
-- FileDataIDs; strings are texture paths. Never shown as live auras — the
-- placeholder desaturates them (example affordance).
local DEBUFF_CATEGORY_SAMPLES = {
    boss         = { "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8", -348 },   -- skull marker, Immolate
    role         = { -6343, -113746 },        -- Thunder Clap, Mystic Touch
    priority     = { -980, -34914 },          -- Agony, Vampiric Touch
    crowdControl = { -118, -6770, -5782 },    -- Polymorph, Sap, Fear
    raid         = { -589, -1943 },           -- Shadow Word: Pain, Rupture
    dispellable  = { -339, -51514 },          -- Entangling Roots, Hex
    _order = { "boss", "role", "priority", "crowdControl", "raid", "dispellable" },
}

-- Example icons for a container-backed group's placeholder block, or nil when
-- the group has nothing to sample (caller falls back to the outline-only
-- style). maxDefault mirrors the DrawGroupPlaceholderSlot default so both
-- compute the same slot count.
-- * Filter groups: sample REAL spells from the linked filters — resolve the
--   selection (same R:ResolveSelection the factory uses; preview-path only,
--   so no cache needed) and take the first N canonical ids in sorted order
--   (deterministic — the preview is stable across refreshes). An empty or
--   dangling selection resolves to kind "all" / an empty map → nil.
-- * Debuff groups (records carry .selection): cycle the selected categories'
--   representative samples across all N slots in _order.
local function GroupSampleIcons(group, maxDefault)
    local n = max(1, tonumber(group.maxIcons) or maxDefault)
    local icons = {}
    if group.selection then
        -- Debuff category group: round-robin the selected categories
        local cats = {}
        for _, key in ipairs(DEBUFF_CATEGORY_SAMPLES._order) do
            if group.selection[key] then tinsert(cats, DEBUFF_CATEGORY_SAMPLES[key]) end
        end
        if #cats == 0 then return nil end
        for i = 1, n do
            local samples = cats[(i - 1) % #cats + 1]
            local entry = samples[(floor((i - 1) / #cats) % #samples) + 1]
            if type(entry) == "number" and entry < 0 then
                entry = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(-entry)) or 134400
            end
            icons[i] = entry
        end
        return icons
    end
    if group.kind ~= "filter" then return nil end
    local R = DF.FilterRegistry
    if not R then return nil end
    local res = R:ResolveSelection(group.filterSelection, false)
    if res.kind == "all" then return nil end -- empty/dangling selection
    -- Canonical ids: variant/alt ids collapse onto their record's id; raw ids
    -- from custom filters (no registry record) sample as themselves.
    local ids, seen = {}, {}
    if res.kind == "include" then
        for id in pairs(res.map) do
            local rec = R.ByID and R.ByID[id]
            local cid = rec and rec.id or id
            if not seen[cid] then seen[cid] = true; tinsert(ids, cid) end
        end
    else -- "exclude" (Uncategorised): complement of the known registry
        for _, rec in ipairs(R.Spells) do
            if not res.map[rec.id] then tinsert(ids, rec.id) end
        end
    end
    if #ids == 0 then return nil end
    sort(ids)
    for i = 1, min(n, #ids) do
        local rec = R.ByID and R.ByID[ids[i]]
        if rec then
            local _, icon = R:GetSpellDisplay(rec)
            icons[i] = icon
        else
            icons[i] = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(ids[i])) or 134400
        end
    end
    return icons
end

-- Shared labeled-outline placeholder for container-backed groups (filter
-- groups on My Buffs, debuff category groups on Debuffs): their contents are
-- Blizzard-filled at runtime (secret visibility, registry/category-driven),
-- so the editor canvas can't preview real member icons. Draw an outline block
-- at the group's anchor/offset sized to its footprint (iconSize ×
-- min(maxIcons, iconsPerRow) columns, wrapped rows), filled with EXAMPLE
-- icons (`icons` array from GroupSampleIcons; nil/empty = outline only) so
-- size/spacing/grow/per-row edits are visible. Pooled per group id in the
-- caller's pool table (separate pools — the two id counters can collide);
-- returns the slot for the placedIndicators list.
local function DrawGroupPlaceholderSlot(mockFrame, pool, group, wrapDefault, maxDefault, icons)
    local slot = pool[group.id]
    if not slot then
        slot = CreateFrame("Frame", nil, mockFrame, "BackdropTemplate")
        -- The group-name label rides its own high-level child so it stays
        -- legible above the sample FRAMES below (a parent's own regions
        -- would draw underneath child frames regardless of layer).
        slot.labelHost = CreateFrame("Frame", nil, slot)
        slot.labelHost:SetAllPoints(slot)
        slot.label = slot.labelHost:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(slot.label, 8, "OUTLINE")
        slot.label:SetPoint("CENTER", 0, 0)
        pool[group.id] = slot
    end
    local iconSize = max(8, tonumber(group.iconSize) or 24)
    local maxIcons = max(1, tonumber(group.maxIcons) or maxDefault)
    local wrap = max(1, tonumber(group.iconsPerRow) or wrapDefault)
    local spacing = tonumber(group.spacing) or 2
    local cols = min(maxIcons, wrap)
    local rows = floor((maxIcons - 1) / wrap) + 1
    slot:SetSize(max(cols * iconSize + (cols - 1) * spacing, 10),
                 max(rows * iconSize + (rows - 1) * spacing, 10))
    ApplyBackdrop(slot, {r = 0.91, g = 0.66, b = 0.25, a = 0.10},
        {r = 0.91, g = 0.66, b = 0.25, a = 0.8})
    slot.label:SetText(group.name)
    slot.label:SetTextColor(0.91, 0.66, 0.25)
    slot.label:SetWidth(slot:GetWidth() - 4)
    slot.label:SetMaxLines(2)
    -- Pin the block's grow-corner at the group's anchor point so it
    -- extends in the grow direction (mirror the container's flow origin).
    local p, s = strsplit("_", group.growDirection or "RIGHT_DOWN")
    local vert, horiz = "TOP", "LEFT"
    for _, d in ipairs({ p, s }) do
        if d == "UP" then vert = "BOTTOM"
        elseif d == "DOWN" then vert = "TOP"
        elseif d == "LEFT" then horiz = "RIGHT"
        elseif d == "RIGHT" then horiz = "LEFT"
        elseif d == "CENTER" then horiz = "" end
    end
    local selfPoint = (horiz == "") and vert or (vert .. horiz)
    slot:ClearAllPoints()
    slot:SetPoint(selfPoint, mockFrame, group.anchor or "TOPLEFT",
        group.offsetX or 0, group.offsetY or 0)
    slot:SetFrameStrata(mockFrame:GetFrameStrata())
    slot:SetFrameLevel(mockFrame:GetFrameLevel() + 8)
    -- Above the sample frames' text holders (slot+1 base + duration/stack
    -- holder offsets) and border art, so the group name always reads.
    slot.labelHost:SetFrameLevel(slot:GetFrameLevel() + 15)

    -- EXAMPLE ICONS inside the block geometry (nil icons = outline only).
    -- Each sample is a pooled child FRAME styled + painted by the factory's
    -- own preview pipeline (Factory:BuildGroupPreviewConfig from group.style →
    -- AuraContainer.StylePreviewSlot/PaintPreviewSlot — the exact path the
    -- placed indicators' canvas preview uses), so the group's Appearance
    -- settings (border incl. animation, cooldown swipe, duration text with
    -- colour-by-time/hide-above, stack count) render on the samples. Regions
    -- are create-only (the live Rebuild rule): when the structural sig moves
    -- (duration/stacks/border on-off, format key), drop the pool and
    -- re-create — same recreate-on-sig idiom as RenderPreviewIndicator.
    -- Fully rebound both directions: a group whose samples empty out
    -- (filters unlinked, categories deselected) returns to the bare outline
    -- (extras hidden), and vice versa. Icons fill the block's grid from its
    -- pinned grow-corner (centered rows when the primary direction is
    -- CENTER), so grow/wrap edits read directionally. Desaturation is the
    -- "example, not live" affordance; style-less groups render through the
    -- same pipeline with the default style (= today's live rendering).
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    local AC = DF.AuraContainer
    local cfg, sig
    if icons and Factory and Factory.BuildGroupPreviewConfig and AC and AC.StylePreviewSlot then
        cfg, sig = Factory:BuildGroupPreviewConfig(mockFrame, group)
    end
    local framePool = slot.sampleFrames
    if framePool and slot.sampleSig ~= sig then
        -- Structural style change: abandon the old frames (hidden — the
        -- RenderPreviewIndicator idiom; regions can't be removed in place).
        -- Stop their border animations first: the external shared driver
        -- ticks secretRect borders even while hidden (Border.lua), so an
        -- abandoned animated sample would tick forever.
        for i = 1, #framePool do
            local f = framePool[i]
            if f.dfBorder and DF.Border then DF.Border:StopAnimation(f.dfBorder) end
            f:Hide()
        end
        framePool = nil
        slot.sampleFrames = nil
    end
    slot.sampleSig = sig
    if not framePool then framePool = {}; slot.sampleFrames = framePool end
    local count = (cfg and icons) and min(#icons, maxIcons) or 0
    if count > 0 then
        -- Curated per-slot entries: the sample's art plus a static duration/
        -- stack sample (the paint staggers the countdown per index and runs
        -- it through the group's own formatter — colour-by-time buckets and
        -- the hide-above blank band mirror live).
        local entries = {}
        for i = 1, count do
            entries[i] = { icon = icons[i], duration = 15, stacks = 3 }
        end
        cfg.testEntries = entries
    end
    local step = iconSize + spacing
    local xSign = (horiz == "RIGHT") and -1 or 1
    local ySign = (vert == "TOP") and -1 or 1
    for i = 1, count do
        local f = framePool[i]
        if not f then
            f = CreateFrame("Frame", nil, slot)
            framePool[i] = f
        end
        AC.StylePreviewSlot(f, cfg)   -- sizes the frame from cfg.layout.size (= iconSize)
        f:ClearAllPoints()
        local col = (i - 1) % wrap
        local row = floor((i - 1) / wrap)
        if horiz == "" then
            -- CENTER primary: rows centered on the block's vert edge
            local lastRow = floor((count - 1) / wrap)
            local iconsInRow = (row == lastRow) and (((count - 1) % wrap) + 1) or wrap
            f:SetPoint(vert, slot, vert,
                (col - (iconsInRow - 1) / 2) * step, ySign * row * step)
        else
            local corner = vert .. horiz
            f:SetPoint(corner, slot, corner, xSign * col * step, ySign * row * step)
        end
        AC.PaintPreviewSlot(f, cfg, i)
        if f.dfIcon then f.dfIcon:SetDesaturated(true) end -- example affordance
        f:Show()
    end
    for i = count + 1, #framePool do
        local f = framePool[i]
        -- Same external-driver rule as above; a re-shown extra restyles via
        -- StylePreviewSlot → Border:Apply, which restarts its animation.
        if f.dfBorder and DF.Border then DF.Border:StopAnimation(f.dfBorder) end
        f:Hide()
    end

    slot:Show()
    return slot
end

local function RefreshPlacedIndicators()
    ClearPlacedIndicators()
    S.placedCleared = false   -- this pass IS the repaint (after Clear re-armed the flag)
    if not S.framePreview then return end

    local mockFrame = S.framePreview.mockFrame
    if not mockFrame then return end

    local adDB = GetAuraDesignerDB()
    local isOther = IsOtherTab()
    local isDebuffs = IsDebuffTab()
    local spec = ResolveSpec()
    -- Other Buffs and the Debuffs tab are spec-independent: render even with
    -- no resolvable spec.
    if not spec and not (isOther or isDebuffs) then return end

    local auraList = (not isOther and not isDebuffs) and spec and Adapter and Adapter:GetTrackableAuras(spec) or nil
    if not auraList and not (isOther or isDebuffs) then return end

    -- Build lookup
    local infoLookup = {}
    if auraList then
        for _, info in ipairs(auraList) do
            infoLookup[info.name] = info
        end
    end

    -- Build layout group position lookup for preview
    -- In preview all indicators are visible, so compute positions for all members.
    -- The preview renders the ACTIVE tab's pool, so the group pass reads the
    -- active tab's group store (spec-keyed on My Buffs, the flat other store on
    -- Other Buffs — read-only, never creates it); Debuffs has neither. Keys carry
    -- the B1 pool prefix so they line up with the instanceKeys built below.
    local keyPrefix = PoolKeyPrefix()
    local groupPositions = {}  -- "<prefix>auraName#indicatorID" → { anchor, offsetX, offsetY }
    local specGroups = isDebuffs and EMPTY_POOL or CurrentLayoutGroups()
    for _, group in ipairs(specGroups) do
        if group.members then
            for memberIdx, member in ipairs(group.members) do
                local key = keyPrefix .. member.auraName .. "#" .. member.indicatorID
                -- Compute position based on group settings
                local activeIdx = memberIdx - 1  -- 0-based
                -- Need to find the indicator's size to compute step (members
                -- live in the same pool as their group — the active pool)
                local memberCfg = CurrentAuraPool(spec)[member.auraName]
                    local indCfg = nil
                    if memberCfg and memberCfg.indicators then
                        for _, ind in ipairs(memberCfg.indicators) do
                            if ind.id == member.indicatorID then
                                indCfg = ind
                                break
                            end
                        end
                    end
                    local size = (indCfg and indCfg.size) or (adDB.defaults and adDB.defaults.iconSize) or 24
                    local scale = (indCfg and indCfg.scale) or (adDB.defaults and adDB.defaults.iconScale) or 1.0
                    local step = (size * scale) + (group.spacing or 2)

                    local growth = group.growDirection or "RIGHT"
                    local primary, secondary = strsplit("_", growth)
                    if not secondary then
                        secondary = (primary == "RIGHT" or primary == "LEFT") and "DOWN" or "RIGHT"
                    end
                    local wrap = group.iconsPerRow or 8
                    if wrap <= 0 then wrap = 1 end
                    local totalCount = #group.members
                    local col = activeIdx % wrap
                    local row = floor(activeIdx / wrap)
                    local function gOff(d, s)
                        if d == "LEFT" then return -s, 0 elseif d == "RIGHT" then return s, 0
                        elseif d == "UP" then return 0, s elseif d == "DOWN" then return 0, -s end
                        return 0, 0
                    end
                    local sX, sY = gOff(secondary, step)
                    local oX, oY
                    if primary == "CENTER" then
                        local iconsInRow = wrap
                        local lastRow = floor((totalCount - 1) / wrap)
                        if row == lastRow then
                            iconsInRow = ((totalCount - 1) % wrap) + 1
                        end
                        local centerOff = -((iconsInRow - 1) * step) / 2
                        if sX ~= 0 then
                            oX = (group.offsetX or 0) + (row * sX)
                            oY = (group.offsetY or 0) + centerOff + (col * step)
                        else
                            oX = (group.offsetX or 0) + centerOff + (col * step)
                            oY = (group.offsetY or 0) + (row * sY)
                        end
                    else
                        local pX, pY = gOff(primary, step)
                        oX = (group.offsetX or 0) + (col * pX) + (row * sX)
                        oY = (group.offsetY or 0) + (col * pY) + (row * sY)
                    end
                    groupPositions[key] = {
                        anchor = group.anchor or "TOPLEFT",
                        offsetX = oX,
                        offsetY = oY,
                    }
                end
            end
        end

    -- FILTER GROUP PLACEHOLDERS (My Buffs / Other Buffs): labeled outline
    -- blocks via the shared helper above. Pooled per group id — SEPARATE pool
    -- table per tab (the two id counters can collide, mirror the dgroup pool);
    -- eye-hidden groups draw nothing. Wrap/max defaults 8 match the classic
    -- member-group layout.
    do
        local fgPoolKey = isOther and "dfADOtherFilterGroupSlots" or "dfADFilterGroupSlots"
        local fgPool = mockFrame[fgPoolKey]
        if not fgPool then fgPool = {}; mockFrame[fgPoolKey] = fgPool end
        for _, group in ipairs(specGroups) do
            if group.kind == "filter" and group.enabled ~= false then
                tinsert(placedIndicators,
                    DrawGroupPlaceholderSlot(mockFrame, fgPool, group, 8, 8,
                        GroupSampleIcons(group, 8)))
            end
        end
    end

    -- DEBUFF GROUP PLACEHOLDERS (C2): Debuffs tab only — the preview renders
    -- the ACTIVE tab's surfaces, so these blocks never mix with the buff
    -- pools' indicators. Separate pool table (dgroup ids come from their own
    -- counter and could collide with filter-group ids). Wrap/max defaults 4
    -- mirror CreateDebuffGroup and the factory's buildFilterGroupLayout(_, 4).
    -- Read-only: visiting the tab must not create adDB.debuffGroups.
    if isDebuffs then
        local dgPool = mockFrame.dfADDebuffGroupSlots
        if not dgPool then dgPool = {}; mockFrame.dfADDebuffGroupSlots = dgPool end
        for _, group in ipairs(DebuffGroupsRead()) do
            if group.enabled ~= false then
                tinsert(placedIndicators,
                    DrawGroupPlaceholderSlot(mockFrame, dgPool, group, 4, 4,
                        GroupSampleIcons(group, 4)))
            end
        end
    end

    -- Iterate all configured auras, find placed indicator instances.
    -- Ad-hoc "#<id>" auras are never in the trackable pool — render them with
    -- info=nil (RenderPreviewIndicator resolves their id/icon by pattern).
    -- Other-pool records render with info=nil + nil identity spec (SpellDB /
    -- ad-hoc resolution, mirroring the factory). Slot keys carry the B1
    -- "other:" prefix so the two pools' slots can't collide in the store.
    -- Hidden indicators (eye toggle, enabled == false) don't render — same as live.
    -- (keyPrefix hoisted above the group-position pass — same value.)
    local idSpec = isOther and nil or spec
    for auraName, auraCfg in pairs(CurrentAuraPool(spec)) do
        local info = infoLookup[auraName]
        if type(auraCfg) == "table" and (isOther or info or AdHocSpellID(auraName)) and auraCfg.indicators then
            for _, indicator in ipairs(auraCfg.indicators) do
              if indicator.enabled ~= false then
                local instanceKey = keyPrefix .. auraName .. "#" .. indicator.id
                local capturedAura = auraName
                local capturedID = indicator.id

                -- Apply layout group position override if applicable
                local effectiveConfig = indicator
                local gPos = groupPositions[instanceKey]
                if gPos then
                    effectiveConfig = setmetatable({
                        anchor = gPos.anchor,
                        offsetX = gPos.offsetX,
                        offsetY = gPos.offsetY,
                    }, { __index = indicator })
                end

                local slot = RenderPreviewIndicator(mockFrame, idSpec, auraName, info, indicator, effectiveConfig, instanceKey)
                if slot then
                    WirePreviewIndicator(slot, capturedAura, capturedID, idSpec)
                    tinsert(placedIndicators, slot)
                end
              end
            end
        end
    end
end
P.RefreshPlacedIndicators = RefreshPlacedIndicators

-- ============================================================
-- PREVIEW EFFECTS
-- Apply frame-level effects (border, healthbar, text, alpha)
-- for the currently selected aura on the mock frame
-- ============================================================

local function GetOrCreatePreviewCustomBorder(mockFrame, key)
    if not mockFrame.dfPreviewCustomBorders then
        mockFrame.dfPreviewCustomBorders = {}
    end
    local pool = mockFrame.dfPreviewCustomBorders
    if pool[key] then return pool[key] end
    -- Stage 5.4: preview uses DF.Border (mirrors the runtime), below the
    -- shared preview border (+5).
    pool[key] = DF.Border:New(mockFrame, { frameLevelOffset = 4, layer = "OVERLAY" })
    return pool[key]
end

local function RefreshPreviewEffects()
    if not S.framePreview then return end
    local mockFrame = S.framePreview.mockFrame
    if not mockFrame then return end

    -- Reset shared border overlay (Stage 5.4: DF.Border — hide edges + anim)
    if S.framePreview.borderOverlay then
        DF.Border:Apply(S.framePreview.borderOverlay, { enabled = false })
    end
    -- Reset custom border overlays
    if mockFrame.dfPreviewCustomBorders then
        for _, ch in pairs(mockFrame.dfPreviewCustomBorders) do
            DF.Border:Apply(ch, { enabled = false })
        end
    end
    if S.framePreview.healthFill then
        S.framePreview.healthFill:SetVertexColor(0.18, 0.80, 0.44, 0.85)
    end
    if S.framePreview.nameText then
        S.framePreview.nameText:SetTextColor(0.18, 0.80, 0.44, 1)
    end
    if S.framePreview.hpText then
        S.framePreview.hpText:SetTextColor(0.87, 0.87, 0.87, 1)
    end
    mockFrame:SetAlpha(1)
    -- Reset the shared single-target elements to their defaults ONCE, before any
    -- aura's effects are applied. Previously the background's reset lived in an
    -- in-loop `elseif`, so a background-less aura could wipe an earlier aura's
    -- background depending on pairs() iteration order — the intermittent
    -- "doesn't show on preview" report for Background / Health Bar Color.
    if S.framePreview.healthBg then
        S.framePreview.healthBg:SetColorTexture(0, 0, 0, 0.4)
    end
    if S.framePreview.missingHealth then
        S.framePreview.missingHealth:SetColorTexture(0, 0, 0, 0.4)
    end

    -- Frame-level effects all draw onto the SAME single preview elements (one
    -- healthFill / healthBg / nameText / etc.), so when more than one aura
    -- configures the same type they conflict. The runtime resolves this by
    -- priority (higher number wins; first claim per type — see prioritySort and
    -- Indicators:Apply's `if state.X then return end`). Mirror that here so the
    -- preview is deterministic instead of pairs()-order-dependent: iterate auras
    -- in descending-priority order (tiebreak by name) and apply first-wins per type.
    local sortedAuras = {}
    for auraName, auraCfg in pairs(CurrentAuraPool()) do
        if type(auraCfg) == "table" then  -- skip corrupted entries
            sortedAuras[#sortedAuras + 1] = { name = auraName, cfg = auraCfg, priority = auraCfg.priority or 5 }
        end
    end
    sort(sortedAuras, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end  -- higher number = higher priority
        return a.name < b.name
    end)

    local claimed = {}
    for _, entry in ipairs(sortedAuras) do
    local auraName, auraCfg = entry.name, entry.cfg

    -- Border effect (Stage 5.4: rendered via DF.Border, mirroring the runtime).
    -- Priority-mode borders share a single overlay (first/highest-priority claim wins);
    -- Stacked-mode borders (stored as borderMode == "custom") get independent per-aura
    -- overlays so several show at once. sortedAuras is already in the same descending-
    -- priority, name-tiebreak order the factory's collectStackedBorders uses, so the
    -- stacking order here matches the live one.
    -- Every type skips hidden blocks (eye toggle, enabled == false) — same as pickWinner.
    if auraCfg.border and auraCfg.border.enabled ~= false and auraCfg.border.ShowBorder ~= false then
        local spec = DF.Border:BuildSpec(auraCfg.border, "")
        spec.animation = nil   -- AD border animation retired on 12.1; the preview must match the
                               -- live render (which strips it at the container chokepoint) so a
                               -- stuck-on BorderAnimationType from an old profile doesn't animate here.
        if not spec.color then spec.color = { r = 1, g = 1, b = 1, a = 1 } end
        spec.enabled = true
        if auraCfg.border.borderMode == "custom" then
            DF.Border:Apply(GetOrCreatePreviewCustomBorder(mockFrame, auraName), spec)
        elseif not claimed.border and S.framePreview.borderOverlay then
            claimed.border = true
            DF.Border:Apply(S.framePreview.borderOverlay, spec)
        end
    end

    -- Health bar color (first claim wins)
    if not claimed.healthbar and auraCfg.healthbar and auraCfg.healthbar.enabled ~= false and S.framePreview.healthFill then
        claimed.healthbar = true
        local clr = auraCfg.healthbar.color or {r = 1, g = 1, b = 1, a = 1}
        local blend = auraCfg.healthbar.blend or 0.5
        if auraCfg.healthbar.mode == "Replace" then
            S.framePreview.healthFill:SetVertexColor(clr.r, clr.g, clr.b, clr.a or 1)
        else
            -- Tint: blend original green with the configured color, scaled by alpha
            -- so dragging the colour picker's alpha visibly weakens the tint
            -- (matches ApplyHealthBar in Indicators.lua: overlay = blend × alpha).
            local effBlend = blend * (clr.a or 1)
            local r = 0.18 * (1 - effBlend) + clr.r * effBlend
            local g = 0.80 * (1 - effBlend) + clr.g * effBlend
            local b = 0.44 * (1 - effBlend) + clr.b * effBlend
            S.framePreview.healthFill:SetVertexColor(r, g, b, 1)
            -- Tint Entire Bar: paint the same tint hue over the (dark) missing-
            -- health region so the preview shows the colour spanning the full bar.
            if auraCfg.healthbar.tintWholeBar and S.framePreview.missingHealth then
                S.framePreview.missingHealth:SetColorTexture(clr.r * effBlend, clr.g * effBlend, clr.b * effBlend, 0.4 + 0.25 * effBlend)
            end
        end
    end

    -- Background color (first claim wins). Recolours the frame background — shows
    -- through the missing-health area, like the runtime overlay behind the bars.
    if not claimed.background and auraCfg.background and auraCfg.background.enabled ~= false and S.framePreview.healthBg then
        claimed.background = true
        local clr = auraCfg.background.color or {r = 1, g = 1, b = 1, a = 1}
        if auraCfg.background.mode == "Replace" then
            local a = clr.a or 1
            S.framePreview.healthBg:SetColorTexture(clr.r, clr.g, clr.b, 0.4 + 0.6 * a)
        else
            local blend = (auraCfg.background.blend or 0.5) * (clr.a or 1)
            -- Blend the configured colour over the dark default background.
            S.framePreview.healthBg:SetColorTexture(clr.r * blend, clr.g * blend, clr.b * blend, 0.4 + 0.4 * blend)
        end
    end

    -- Name text color (first claim wins)
    if not claimed.nametext and auraCfg.nametext and auraCfg.nametext.enabled ~= false and S.framePreview.nameText then
        claimed.nametext = true
        local clr = auraCfg.nametext.color or {r = 1, g = 1, b = 1, a = 1}
        S.framePreview.nameText:SetTextColor(clr.r, clr.g, clr.b, clr.a or 1)
    end

    -- Health text color (first claim wins)
    if not claimed.healthtext and auraCfg.healthtext and auraCfg.healthtext.enabled ~= false and S.framePreview.hpText then
        claimed.healthtext = true
        local clr = auraCfg.healthtext.color or {r = 1, g = 1, b = 1, a = 1}
        S.framePreview.hpText:SetTextColor(clr.r, clr.g, clr.b, clr.a or 1)
    end

    end  -- for _, entry in sortedAuras
end
P.RefreshPreviewEffects = RefreshPreviewEffects

-- ============================================================
-- LIGHTWEIGHT PREVIEW REFRESH
-- Re-applies indicator settings to existing preview frames without
-- destroying/recreating them. Called from proxy __newindex so every
-- slider drag tick, checkbox toggle, or dropdown change is live.
-- ============================================================

S.RefreshPreviewLightweight = function()
    if not S.framePreview or not S.framePreview.mockFrame then return end
    local mockFrame = S.framePreview.mockFrame

    local adDB = GetAuraDesignerDB()
    local isOther = IsOtherTab()
    local isDebuffs = IsDebuffTab()
    local spec = ResolveSpec()
    if not spec and not (isOther or isDebuffs) then return end

    -- Build layout group position lookup (same as RefreshPlacedIndicators:
    -- active tab's group store over the active pool, pool-prefixed keys;
    -- Debuffs has no member groups so the pass reads empty there)
    local keyPrefix = PoolKeyPrefix()
    local groupPositions = {}
    local specGroups2 = isDebuffs and EMPTY_POOL or CurrentLayoutGroups()
    for _, group in ipairs(specGroups2) do
        if group.members then
            for memberIdx, member in ipairs(group.members) do
                local key = keyPrefix .. member.auraName .. "#" .. member.indicatorID
                local activeIdx = memberIdx - 1
                local memberCfg = CurrentAuraPool(spec)[member.auraName]
                local indCfg = nil
                if memberCfg and memberCfg.indicators then
                    for _, ind in ipairs(memberCfg.indicators) do
                        if ind.id == member.indicatorID then indCfg = ind; break end
                    end
                end
                local size = (indCfg and indCfg.size) or (adDB.defaults and adDB.defaults.iconSize) or 24
                local scale = (indCfg and indCfg.scale) or (adDB.defaults and adDB.defaults.iconScale) or 1.0
                local step = (size * scale) + (group.spacing or 2)
                -- Grid-aware layout matching RefreshPlacedIndicators / ComputeGroupOffset
                local growth = group.growDirection or "RIGHT"
                local primary, secondary = strsplit("_", growth)
                if not secondary then
                    secondary = (primary == "RIGHT" or primary == "LEFT") and "DOWN" or "RIGHT"
                end
                local wrap = group.iconsPerRow or 8
                if wrap <= 0 then wrap = 1 end
                local totalCount = #group.members
                local col = activeIdx % wrap
                local row = floor(activeIdx / wrap)
                local function gOff(d, s)
                    if d == "LEFT" then return -s, 0 elseif d == "RIGHT" then return s, 0
                    elseif d == "UP" then return 0, s elseif d == "DOWN" then return 0, -s end
                    return 0, 0
                end
                local sX, sY = gOff(secondary, step)
                local oX, oY
                if primary == "CENTER" then
                    local iconsInRow = wrap
                    local lastRow = floor((totalCount - 1) / wrap)
                    if row == lastRow then
                        iconsInRow = ((totalCount - 1) % wrap) + 1
                    end
                    local centerOff = -((iconsInRow - 1) * step) / 2
                    if sX ~= 0 then
                        oX = (group.offsetX or 0) + (row * sX)
                        oY = (group.offsetY or 0) + centerOff + (col * step)
                    else
                        oX = (group.offsetX or 0) + centerOff + (col * step)
                        oY = (group.offsetY or 0) + (row * sY)
                    end
                else
                    local pX, pY = gOff(primary, step)
                    oX = (group.offsetX or 0) + (col * pX) + (row * sX)
                    oY = (group.offsetY or 0) + (col * pY) + (row * sY)
                end
                groupPositions[key] = { anchor = group.anchor or "TOPLEFT", offsetX = oX, offsetY = oY }
            end
        end
    end

    -- Re-apply placed indicator instances using current settings
    -- (hidden indicators skipped — RenderPreviewIndicator would resurrect their
    -- slot; keyPrefix hoisted above the group-position pass — same value)
    local idSpec = isOther and nil or spec
    for auraName, auraCfg in pairs(CurrentAuraPool(spec)) do
        if type(auraCfg) == "table" and auraCfg.indicators then
            for _, indicator in ipairs(auraCfg.indicators) do
              if indicator.enabled ~= false then
                local instanceKey = keyPrefix .. auraName .. "#" .. indicator.id

                -- Apply layout group position override if applicable
                local effectiveConfig = indicator
                local gPos = groupPositions[instanceKey]
                if gPos then
                    effectiveConfig = setmetatable({
                        anchor = gPos.anchor, offsetX = gPos.offsetX, offsetY = gPos.offsetY,
                    }, { __index = indicator })
                end

                -- Restyle/repaint through the shared preview slot (recreated only
                -- when the structural sig changes; cosmetic changes restyle in place).
                local infoLW = nil
                if not isOther and Adapter and Adapter.GetTrackableAuras then
                    for _, ti in ipairs(Adapter:GetTrackableAuras(spec)) do
                        if ti.name == auraName then infoLW = ti; break end
                    end
                end
                local slot = RenderPreviewIndicator(mockFrame, idSpec, auraName, infoLW, indicator, effectiveConfig, instanceKey)
                if slot then
                    WirePreviewIndicator(slot, auraName, indicator.id, idSpec)
                end
              end
            end
        end
    end

    -- Also refresh frame-level preview effects (border, healthbar color, text colors, alpha)
    RefreshPreviewEffects()
end