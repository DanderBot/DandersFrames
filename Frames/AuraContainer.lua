local addonName, DF = ...

-- ============================================================
-- AURA CONTAINER FACTORY (DF.AuraContainer)
--
-- One shared factory for WoW 12.1's Blizzard-driven AuraContainer / AuraButton
-- widgets. Every aura-displaying feature (buff/debuff rows, defensives, dispel,
-- Aura Designer, ...) routes through this module instead of talking to the
-- container API directly, so the weekly 12.1 PTR churn — and the PTR-4
-- CustomAuraContainer -> ManagedAuraContainer swap (auto-buttons + Spell-ID /
-- dispel / stealable / max-duration filters + sort) — is ONE internal rewrite
-- behind a stable interface, not four. Mirrors the DF.Border precedent.
--
-- THE MODEL (12.1): reading aura data in Lua is sealed; DISPLAY is not. The addon
-- CREATES + STYLES the buttons; Blizzard's secure code FILLS + DRIVES them. This
-- module owns the MECHANISM (the addon-owned-button construction dance, the
-- secret-safe inbound setters, the two shapes: "row" and "overlay"); each feature
-- owns the POLICY (which filter, layout, config keys). The factory never reads
-- aura data, never loops-and-draws — it configures and hands off.
--
-- PUBLIC API:
--   DF.AuraContainer.IsSupported()       -- 12.1+ widget types exist (version gate)
--   DF.AuraContainer.HasSpellFilter()    -- PTR-4: per-Spell-ID filter available
--   DF.AuraContainer.HasSort()           -- PTR-4: sort rule/direction available
--   local h = DF.AuraContainer:Create(parent, config)  -- nil if unsupported
--   h:SetUnit(unit) / h:SetShown(b) / h:Enable() / h:Disable()
--   h:ApplyStyle(style) -- in-place cosmetic restyle (no teardown)
--   h:SetFilter(filter) / h:SetSort(sort) -- structural (rebuild) / PTR-4 no-op now
--   h:Rebuild(configDelta) -- structural rebuild (max / region toggles / frozen opts)
--   h:Refresh() -- force a re-scan (Hide/Show bounce; for dynamic-unit consumers)
--   h:GetFrame() -- the plain positioning frame DF anchors (SetPoint/SetSize on it)
--   h:Destroy()
--
-- GOTCHAS baked in (from Krathe's R&D, build-stamped 12.1.0 @ b8f90f2a):
--   1. Buttons are addon-created (CreateFrame("AuraButton",...)) + container:AddAuraFrame(b).
--      NEVER AddAuraFramesFromTemplate (that yields a forbidden object we can't style).
--   2. Order: SetUnit -> AddAuraFilter -> build/style/AddAuraFrame -> SetEnabled LAST.
--   3. Never call container:UpdateAllAuras() (indexes the secret table -> taints).
--   4. Regions passed to a Set* setter MUST be children of that button.
--   5. SetDurationText{textColorCurve} is bugged on this build (forwards the curve
--      without the required `property` -> errors + text vanishes) -> guarded.
--   6. Static DF.Border on buttons is fine; animated glow / OnUpdate on buttons is
--      forbidden (<ForbiddenAspects> + onUpdateMode="disabled"). Static only.
--   7. Cannot read IsShown / spellId / expirationTime / dispelName / presence — all
--      secret. Never branch on them. pcall catches the error but not the taint.
-- ============================================================

local CreateFrame = CreateFrame
local pcall, ipairs, pairs, type = pcall, ipairs, pairs, type
local wipe = wipe
local select, GetBuildInfo = select, GetBuildInfo
local InCombatLockdown = InCombatLockdown
local C_Spell = C_Spell
-- Midnight-safe: never compare/branch on a value that could be secret.
local issecretvalue = issecretvalue or function() return false end

DF.AuraContainer = DF.AuraContainer or {}
local AuraContainer = DF.AuraContainer

local DBG = "AURACONTAINER"

-- One-time-per-process warning latches so a guarded failure (curve bug, border
-- taint, native dispel reject) logs ONCE, not once per button.
local warnedCurve, warnedBorder, warnedNativeDispel = false, false, false
local warnedRestyle, warnedRefresh = false, false

-- ============================================================
-- CAPABILITY DETECTION  (the version gate + PTR-4 feature gates)
-- Lazy + cached. IsSupported() is the primary gate every consumer checks; when it
-- is false, Create() returns nil and the feature keeps its existing (pre-12.1)
-- render path. This keeps the live 12.0.7 client completely unchanged.
-- ============================================================
local _supported            -- tri-state: nil = not yet probed

-- Definitive probe: the 12.1 widget types either exist or CreateFrame errors.
-- Gated first on the interface number so we don't even attempt the probe on old
-- clients. The probe frame is parented to a hidden holder and never shown.
local function probeSupported()
    local toc = select(4, GetBuildInfo())
    if type(toc) ~= "number" or toc < 120100 then return false end
    if not (AuraUtil and AuraUtil.IsValidFilterString) then return false end
    local ok, frame = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    if not ok or not frame then return false end
    -- Confirm the button intrinsic + its template resolve too (a container with no
    -- styleable button is useless to us).
    local okB, button = pcall(CreateFrame, "AuraButton", nil, frame, "CustomAuraButtonTemplate")
    if okB and button then pcall(function() frame:RemoveAllAuraFrames() end) end
    pcall(function() frame:Hide() end)
    return okB and button ~= nil
end

function AuraContainer.IsSupported()
    if _supported == nil then
        local ok, res = pcall(probeSupported)
        _supported = (ok and res) and true or false
        DF:Debug(DBG, "IsSupported probe -> %s (toc=%s)", tostring(_supported), tostring(select(4, GetBuildInfo())))
    end
    return _supported
end

-- PTR-4 gates. The managed AuraContainer (auto-created buttons + Spell-ID / dispel /
-- stealable / max-duration filters + sort) is secure-only on b8f90f2a, so its template
-- does NOT resolve for addons yet — a clean NEGATIVE feature-probe (per Krathe): the day
-- CreateFrame("AuraContainer", …, "ManagedAuraContainerTemplate") starts succeeding, the
-- managed path is live. We probe capability, never a build number.
local _managed
local function managedAvailable()
    if _managed == nil then
        if not (AuraUtil and AuraUtil.IsValidFilterString) then
            _managed = false
        else
            local ok, frame = pcall(CreateFrame, "AuraContainer", nil, UIParent, "ManagedAuraContainerTemplate")
            if ok and frame then pcall(function() frame:Hide() end) end
            _managed = (ok and frame ~= nil) and true or false
        end
        DF:Debug(DBG, "managedAvailable probe -> %s", tostring(_managed))
    end
    return _managed
end

-- ★ These stay FALSE until the factory actually WIRES the managed path — NOT merely when
-- Blizzard's managed template resolves. Otherwise, the day PTR-4 lands, a consumer gating
-- per-spell logic on "true" would get a container that still builds the Custom path and
-- ignores config.spellIDs/sort → silently shows ALL auras instead of one spell.
-- managedAvailable() is the capability probe; flip the WIRED flag when the PTR-4 managed
-- filter/sort is implemented here (Krathe posts the exact symbol from the source sweep).
local SPELL_FILTER_WIRED = false
local SORT_WIRED = false

-- Per-Spell-ID filter (the Aura Designer's core). Consumers may pass config.spellIDs
-- today; it is accepted and no-ops until this returns true.
function AuraContainer.HasSpellFilter()
    return SPELL_FILTER_WIRED and managedAvailable()
end

-- Sort (rule + direction).
function AuraContainer.HasSort()
    return SORT_WIRED and managedAvailable()
end

-- Forward-seam guard. PTR-4 adds filtering by dispel type / stealable / max duration
-- (plus the Spell-ID filter + sort above). Consumers may pass these config seams TODAY;
-- they are accepted and no-op until the managed path wires each one. This warns ONCE per
-- seam when a consumer sets one the factory can't honor yet — so nothing silently shows
-- everything. Each lights up when its capability is wired.
local warnedSeam = {}
local function warnUnwiredSeam(name, note)
    if not warnedSeam[name] then
        warnedSeam[name] = true
        DF:DebugWarn(DBG, "config.%s is set but not wired yet — ignored (%s)", name, note)
    end
end
local function checkUnwiredSeams(config)
    if config.spellIDs and not AuraContainer.HasSpellFilter() then
        warnUnwiredSeam("spellIDs", "per-Spell-ID filter arrives at PTR-4")
    end
    if config.sort and not AuraContainer.HasSort() then
        warnUnwiredSeam("sort", "sort rule/direction arrives at PTR-4")
    end
    if config.dispelTypes then warnUnwiredSeam("dispelTypes", "dispel-type filter arrives at PTR-4") end
    if config.maxDuration then warnUnwiredSeam("maxDuration", "max-duration filter arrives at PTR-4") end
    if config.stealable then warnUnwiredSeam("stealable", "stealable filter arrives at PTR-4") end
end

-- ============================================================
-- HELPERS
-- ============================================================

-- A style/config value that could be a secret is never fed to a Lua compare; the
-- only setters we call (SetColorTexture / SetVertexColor / SetText etc.) accept
-- secret values, and Blizzard drives the secret data itself. These helpers only
-- ever handle OUR OWN (non-secret) config values.
local function readColor(c, dr, dg, db, da)
    if type(c) ~= "table" then return dr or 1, dg or 1, db or 1, da or 1 end
    return c[1] or c.r or dr or 1, c[2] or c.g or dg or 1, c[3] or c.b or db or 1, c[4] or c.a or da or 1
end

-- Normalize config.filter into a clean list of validated filter strings.
local function normalizeFilters(filter)
    local out = {}
    if type(filter) == "string" then
        out[1] = filter
    elseif type(filter) == "table" then
        for _, f in ipairs(filter) do if type(f) == "string" then out[#out + 1] = f end end
    end
    if #out == 0 then out[1] = "HELPFUL" end
    return out
end

-- Resolve an Enum member by NAME string ("" / invalid -> nil -> Blizzard default).
local function resolveEnum(enumTable, name)
    if enumTable and type(name) == "string" and name ~= "" and enumTable[name] ~= nil then
        return enumTable[name]
    end
    return nil
end

-- Dynamic-unit tokens whose underlying unit changes WITHOUT the token changing, so
-- OnUnitChanged never fires -> they need a Refresh() bounce on the matching event.
-- Prefix-match so "targettarget"/"focustarget" are covered by their base event too.
local DYN_EVENT = {
    target    = "PLAYER_TARGET_CHANGED",
    focus     = "PLAYER_FOCUS_CHANGED",
    mouseover = "UPDATE_MOUSEOVER_UNIT",
}
local function dynPrefixOf(unit)
    if type(unit) ~= "string" then return nil end
    for prefix in pairs(DYN_EVENT) do
        if unit:sub(1, #prefix) == prefix then return prefix end
    end
    return nil
end

-- Child holder frame at a raised frame level, so a text region drawn on it sits
-- ABOVE the cooldown swipe (cross-frame draw order is by frame level, so a font
-- string parented directly to the button would render UNDER the swipe). The holder
-- is a child of the button and the font string a child of the holder, so the font
-- string inherits the button's forbidden aspects TRANSITIVELY through the parent
-- chain — Blizzard's native setters accept it (confirmed LIVE on b8f90f2a: stack
-- count + duration text render via this exact holder-hosted pattern, and DF's own
-- aura icons use the same textOverlay-frame convention). Re-verify if a future
-- build tightens the forbidden-object check to direct-child-only.
local function makeHolder(button, levelOffset)
    local h = CreateFrame("Frame", nil, button)
    h:SetAllPoints(button)
    h:SetFrameLevel(math.max(0, button:GetFrameLevel() + (levelOffset or 0)))
    return h
end

-- ============================================================
-- BUTTON STYLING — split into two source-agnostic halves (F1 two-halves design):
--   styleButton_regions(slot, config) — creates/positions/fonts/colours EVERY region.
--     No native setters here — only DF-owned region work (incl. the STATIC icon texture
--     and DF.Border), so it runs IDENTICALLY on a native AuraButton or a plain Frame
--     (the fake/legacy backends style plain frames and push their own data).
--   bindNative(slot, config) — registers each region with its Blizzard inbound setter
--     (SetIcon/SetDurationCooldown/SetDurationText/…). NATIVE slots only; a plain slot
--     lacks these methods so each bind is skipped. Bind-once per region.
--   styleButton(slot, config) — the Custom-path wrapper: regions then native bind,
--     preserving the original behaviour. _build and ApplyStyle call this; increment 2
--     will call the two halves separately per backend.
--
-- RE-RUNNABLE: regions are created-once + updated in place (ApplyStyle re-runs it on a
-- slider drag without teardown). NEVER Show()/Hide() a region handed to a native setter
-- (Blizzard owns its 'Shown' aspect -> taint); an OFF feature is simply never created.
-- ============================================================
local function styleButton_regions(slot, config)
    local style = config.style or {}
    -- Overlay = a presence box (tint + border + native dispel only); the icon and all
    -- icon-content regions (cooldown/duration/stacks/bar/spellName) are ROW-only.
    local isRow = config.mode ~= "overlay"
    local sx = config.layout and (config.layout.sizeX or config.layout.size) or 32
    local sy = config.layout and (config.layout.sizeY or config.layout.size) or sx
    if isRow then slot:SetSize(sx, sy) end   -- overlay is SetAllPoints(frame) in _build

    -- OVERLAY tint / ROW icon. Static icon (known spell) is set here (source-agnostic —
    -- it's also the fake backend's icon mechanism); the native SetIcon bind is in bindNative.
    if config.mode == "overlay" then
        local ov = style.overlay
        if ov and ov.tintColor then
            if not slot.dfTint then
                slot.dfTint = slot:CreateTexture(nil, "OVERLAY")
                slot.dfTint:SetAllPoints(slot)
            end
            slot.dfTint:SetColorTexture(readColor(ov.tintColor))
        end
    else
        local iconSpec = style.icon
        if iconSpec == nil or iconSpec.show ~= false then
            if not slot.dfIcon then
                slot.dfIcon = slot:CreateTexture(nil, "BACKGROUND")
                slot.dfIcon:SetPoint("TOPLEFT", 1, -1)
                slot.dfIcon:SetPoint("BOTTOMRIGHT", -1, 1)
            end
            local staticID = iconSpec and iconSpec.staticSpellID
            if staticID and C_Spell and C_Spell.GetSpellTexture then
                local tex = C_Spell.GetSpellTexture(staticID)
                if tex then slot.dfIcon:SetTexture(tex) end
            end
            local zoom = not (iconSpec and iconSpec.zoom == false)
            slot.dfIcon:SetTexCoord(zoom and 0.08 or 0, zoom and 0.92 or 1, zoom and 0.08 or 0, zoom and 0.92 or 1)
        end
    end

    -- BORDER via DF.Border (STATIC only — animated forbidden on buttons). DF-owned, so
    -- source-agnostic (works on native + plain slots). pcall-guarded + warn-once.
    local borderSpec = style.border
    if borderSpec and DF.Border then
        if not slot.dfBorder then
            local ok, w = pcall(function() return DF.Border:New(slot, { solidOnly = true }) end)
            if ok then slot.dfBorder = w end
        end
        if slot.dfBorder then
            local ok, err = pcall(function()
                local spec = borderSpec.spec
                if not spec and borderSpec.db and borderSpec.prefix then
                    local iconMode = borderSpec.iconMode
                    if iconMode == nil then iconMode = (config.mode ~= "overlay") end
                    spec = DF.Border:BuildSpec(borderSpec.db, borderSpec.prefix, { unit = config.unit, frame = slot, iconMode = iconMode })
                end
                if spec then DF.Border:Apply(slot.dfBorder, spec) end
            end)
            if not ok and not warnedBorder then
                warnedBorder = true
                DF:DebugWarn(DBG, "DF.Border on aura button failed (taint?): %s", tostring(err))
            end
        end
    end

    -- COOLDOWN swipe region (native SetDurationCooldown bind is in bindNative).
    local cdSpec = style.cooldown
    if isRow and (cdSpec == nil or cdSpec.show ~= false) then
        if not slot.dfCD then
            slot.dfCD = CreateFrame("Cooldown", nil, slot, "CooldownFrameTemplate")
        end
        slot.dfCD:SetAllPoints(slot.dfIcon or slot)
        if slot.dfCD.SetDrawEdge then slot.dfCD:SetDrawEdge(cdSpec == nil or cdSpec.edge ~= false) end
        if slot.dfCD.SetHideCountdownNumbers then
            slot.dfCD:SetHideCountdownNumbers(not (cdSpec and cdSpec.numbers))
        end
    end

    -- DURATION text region (native SetDurationText bind is in bindNative).
    local durSpec = style.duration
    if isRow and durSpec and durSpec.show then
        if not slot.dfDur then
            slot.dfDurHolder = makeHolder(slot, durSpec.level or 6)
            slot.dfDur = slot.dfDurHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        end
        slot.dfDur:ClearAllPoints()
        slot.dfDur:SetPoint(durSpec.anchor or "CENTER", slot.dfDurHolder, durSpec.anchor or "CENTER", durSpec.offsetX or 0, durSpec.offsetY or 0)
        slot.dfDur:SetTextColor(readColor(durSpec.color, 1, 1, 1, 1))
        if DF.SafeSetFont then DF:SafeSetFont(slot.dfDur, durSpec.font, durSpec.size or 12, durSpec.outline or "NONE") end
    end

    -- STACK count region (native SetApplicationCount bind is in bindNative).
    local stackSpec = style.stacks
    if isRow and stackSpec and stackSpec.show then
        if not slot.dfStack then
            slot.dfStackHolder = makeHolder(slot, stackSpec.level or 7)
            slot.dfStack = slot.dfStackHolder:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        end
        slot.dfStack:ClearAllPoints()
        slot.dfStack:SetPoint(stackSpec.anchor or "BOTTOMRIGHT", slot.dfStackHolder, stackSpec.anchor or "BOTTOMRIGHT", stackSpec.offsetX or -2, stackSpec.offsetY or 2)
        if DF.SafeSetFont then DF:SafeSetFont(slot.dfStack, stackSpec.font, stackSpec.size or 14, stackSpec.outline or "OUTLINE") end
    end

    -- DURATION bar region (native SetDurationBar bind is in bindNative).
    local barSpec = style.bar
    if isRow and barSpec and barSpec.show then
        if not slot.dfBar then
            slot.dfBar = CreateFrame("StatusBar", nil, slot)
            slot.dfBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
            slot.dfBar:SetPoint("TOPLEFT", slot, "BOTTOMLEFT", 0, -2)
            slot.dfBar:SetPoint("TOPRIGHT", slot, "BOTTOMRIGHT", 0, -2)
        end
        slot.dfBar:SetStatusBarColor(readColor(barSpec.color, 0.2, 0.9, 0.3, 1))
        slot.dfBar:SetHeight(barSpec.height or 4)
    end

    -- SPELL name region (native SetSpellName bind is in bindNative).
    local nameSpec = style.spellName
    if isRow and nameSpec and nameSpec.show then
        if not slot.dfName then
            slot.dfNameHolder = makeHolder(slot, 5)
            slot.dfName = slot.dfNameHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        end
        slot.dfName:ClearAllPoints()
        slot.dfName:SetPoint(nameSpec.anchor or "TOP", slot.dfNameHolder, nameSpec.anchor or "TOP", nameSpec.offsetX or 0, nameSpec.offsetY or 16)
        if DF.SafeSetFont then DF:SafeSetFont(slot.dfName, nameSpec.font, nameSpec.size or 10, nameSpec.outline or "NONE") end
    end

    -- NATIVE dispel border / symbol REGIONS (the SetAuraBorder/SetAuraSymbol bind is in bindNative).
    local dispelSpec = style.dispel
    if dispelSpec then
        if dispelSpec.nativeBorder and not slot.dfAuraBorder then
            slot.dfAuraBorder = slot:CreateTexture(nil, "OVERLAY")
            slot.dfAuraBorder:SetPoint("TOPLEFT", -2, 2)
            slot.dfAuraBorder:SetPoint("BOTTOMRIGHT", 2, -2)
        end
        if dispelSpec.nativeSymbol and not slot.dfSymbol then
            slot.dfSymbolHolder = makeHolder(slot, 7)
            slot.dfSymbol = slot.dfSymbolHolder:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            slot.dfSymbol:SetPoint("CENTER")
        end
    end
end

-- Register each region with its Blizzard inbound setter. NATIVE slots only (a plain
-- fake/legacy slot lacks these methods, so each bind is skipped and its backend pushes
-- data to the regions instead). Bind-once per region so ApplyStyle re-runs don't re-register.
local function bindNative(slot, config)
    local style = config.style or {}

    if slot.dfIcon and slot.SetIcon and not slot._boundIcon then
        slot._boundIcon = true
        slot:SetIcon(slot.dfIcon)
    end

    if slot.dfCD and slot.SetDurationCooldown and not slot._boundCD then
        slot._boundCD = true
        slot:SetDurationCooldown(slot.dfCD)
    end

    if slot.dfDur and slot.SetDurationText and not slot._boundDur then
        slot._boundDur = true
        -- SetDurationText's textColorCurve is bugged on this build — try WITH it
        -- (self-heals if Blizzard fixes it), fall back WITHOUT it so text still renders.
        local durSpec = style.duration or {}
        local opts = {}
        if durSpec.colorCurve then opts.textColorCurve = durSpec.colorCurve end
        if durSpec.expiredText and durSpec.expiredText ~= "" then opts.expiredText = durSpec.expiredText end
        if durSpec.zeroText and durSpec.zeroText ~= "" then opts.zeroDurationText = durSpec.zeroText end
        local ok, err = pcall(function() slot:SetDurationText(slot.dfDur, opts) end)
        if not ok then
            opts.textColorCurve = nil
            pcall(function() slot:SetDurationText(slot.dfDur, opts) end)
            if not warnedCurve then
                warnedCurve = true
                DF:DebugWarn(DBG, "SetDurationText textColorCurve bugged (Blizzard, missing property) — text falls back to static colour: %s", tostring(err))
            end
        end
    end

    if slot.dfStack and slot.SetApplicationCount and not slot._boundStack then
        slot._boundStack = true
        slot:SetApplicationCount(slot.dfStack, {})
    end

    if slot.dfBar and slot.SetDurationBar and not slot._boundBar then
        slot._boundBar = true
        local barSpec = style.bar or {}
        local o = {}
        local interp = resolveEnum(Enum and Enum.StatusBarInterpolation, barSpec.interpolation)
        local dir = resolveEnum(Enum and Enum.StatusBarTimerDirection, barSpec.direction)
        if interp ~= nil then o.interpolation = interp end
        if dir ~= nil then o.direction = dir end
        slot:SetDurationBar(slot.dfBar, o)
    end

    if slot.dfName and slot.SetSpellName and not slot._boundName then
        slot._boundName = true
        slot:SetSpellName(slot.dfName)
    end

    local dispelSpec = style.dispel
    if dispelSpec then
        if slot.dfAuraBorder and slot.SetAuraBorder and not slot._boundAuraBorder then
            slot._boundAuraBorder = true
            local ok, err = pcall(function()
                slot:SetAuraBorder(slot.dfAuraBorder, {
                    style = (AuraButtonBorderStyle and AuraButtonBorderStyle[dispelSpec.style or "Atlas"]) or 0,
                    showWhenHarmful = dispelSpec.showWhenHarmful ~= false,
                    showWhenHelpful = dispelSpec.showWhenHelpful == true,
                    showIcon = false,
                })
            end)
            if not ok and not warnedNativeDispel then
                warnedNativeDispel = true
                DF:DebugWarn(DBG, "SetAuraBorder failed (build still ok): %s", tostring(err))
            end
        end
        if slot.dfSymbol and slot.SetAuraSymbol and not slot._boundSymbol then
            slot._boundSymbol = true
            local ok, err = pcall(function()
                slot:SetAuraSymbol(slot.dfSymbol, {
                    showWhenHarmful = dispelSpec.showWhenHarmful ~= false,
                    showWhenHelpful = dispelSpec.showWhenHelpful == true,
                })
            end)
            if not ok and not warnedNativeDispel then
                warnedNativeDispel = true
                DF:DebugWarn(DBG, "SetAuraSymbol failed (build still ok): %s", tostring(err))
            end
        end
    end
end

-- Custom-path wrapper: regions then native bind, preserving the original order + behaviour.
-- (_build and ApplyStyle call this. Increment 2 calls the two halves separately per backend.)
local function styleButton(slot, config)
    styleButton_regions(slot, config)
    bindNative(slot, config)
end

-- ============================================================
-- LAYOUT  (row mode)
-- Baseline grid layout: linear growth in a primary axis, wrapping to a secondary
-- axis after `wrap` icons. Compound growth strings ("RIGHT_DOWN", "LEFT_UP", ...).
-- NOTE (step 1): reconcile with DF's exact center-growth / pixel-perfect helper
-- (Features/Auras.lua RepositionCenterGrowthIcons, Frames/Icons.lua) so buff/debuff
-- rows lay out pixel-identically to today. This baseline covers the common cases.
-- ============================================================
local AXIS = {
    RIGHT = { x = 1, y = 0 }, LEFT = { x = -1, y = 0 },
    UP    = { x = 0, y = 1 }, DOWN = { x = 0, y = -1 },
}

local function layoutRow(handle)
    local config = handle.config
    local L = config.layout or {}
    local sx = (L.sizeX or L.size or 32)
    local sy = (L.sizeY or L.size or sx)
    local spX = (L.spacingX or L.spacing or 4)
    local spY = (L.spacingY or L.spacing or 4)
    local anchor = (type(L.anchor) == "string" and L.anchor) or "TOPLEFT"
    local growth = (type(L.growth) == "string" and L.growth) or "RIGHT_DOWN"
    local wrap = L.wrap or #handle.buttons
    if wrap < 1 then wrap = #handle.buttons end

    local primary, secondary = growth:match("^(%a+)_?(%a*)$")
    local pAxis = AXIS[primary] or AXIS.RIGHT
    local sAxis = AXIS[secondary] or AXIS.DOWN

    for i, b in ipairs(handle.buttons) do
        local idx = i - 1
        local col = idx % wrap
        local row = math.floor(idx / wrap)
        -- Any horizontal movement steps by (sx+spX); any vertical by (sy+spY),
        -- so non-square icons / asymmetric spacing still lay out correctly.
        local x = (L.offsetX or 0) + (pAxis.x * col + sAxis.x * row) * (sx + spX)
        local y = (L.offsetY or 0) + (pAxis.y * col + sAxis.y * row) * (sy + spY)
        b:ClearAllPoints()
        b:SetPoint(anchor, handle.frame, anchor, x, y)
    end
end

-- ============================================================
-- HANDLE
-- The object DF holds + positions. Public methods form the stable seam; the
-- container/button internals swap under them at PTR-4 without callers changing.
-- ============================================================
local Handle = {}
Handle.__index = Handle

function Handle:GetFrame() return self.frame end

-- Proxy positioning to the plain (non-secure) anchor frame. NOTE: Create SetAllPoints
-- the frame to its parent, so to reposition call h:ClearAllPoints() first; and h:SetSize
-- is a no-op while the all-points anchor is live (size follows the parent until cleared).
function Handle:SetPoint(...) self.frame:SetPoint(...) end
function Handle:ClearAllPoints() self.frame:ClearAllPoints() end
function Handle:SetSize(w, h) self.frame:SetSize(w, h) end

function Handle:Enable() self:_applyEnabled(true) end
function Handle:Disable() self:_applyEnabled(false) end
function Handle:SetShown(shown)
    shown = shown and true or false
    self.frame:SetShown(shown)          -- plain anchor frame; safe in combat
    self:_applyEnabled(shown)
end

-- Enable/disable the (secure) container's parse+bind. COMBAT-GUARDED: SetEnabled
-- touches secure container state, so in lockdown we persist the desired state and
-- defer the call to PLAYER_REGEN_ENABLED (never downgrading a pending rebuild).
function Handle:_applyEnabled(on)
    on = on and true or false
    self.config.enabled = on
    if InCombatLockdown() then self:_queueOp("enable"); return end
    if self.container then self.container:SetEnabled(on) end
end

-- Retarget the container's unit. Guarded: retargeting touches secure container
-- state, so defer if we're in combat.
function Handle:SetUnit(unit)
    self.config.unit = unit
    self:_updateDynRefresh()   -- re-evaluate dynamic-unit auto-refresh for the new token
    -- In combat, defer JUST the retarget (a full rebuild would leak a container + N
    -- buttons every combat on roster churn); "retarget" re-runs SetUnit at regen.
    if InCombatLockdown() then self:_queueOp("retarget"); return end
    if self.container then self.container:SetUnit(unit) end
end

-- In-place cosmetic RESTYLE (colours / sizes / fonts / offsets / layout). NOTE: this
-- REPLACES config.style (it is not a merge) and only re-applies always-updated props —
-- it does NOT create/remove regions or change creation-frozen opts (duration
-- expiredText/colorCurve, bar interpolation/direction, dispel show flags). To toggle a
-- region on/off or change a frozen opt, use Rebuild(). pcall-guarded so a restyle fault
-- can't escape into a GUI callback.
function Handle:ApplyStyle(style)
    if type(style) == "table" then
        self.config.style = style
    end
    if self.config.mode ~= "overlay" then layoutRow(self) end
    for _, b in ipairs(self.buttons) do
        local ok, err = pcall(styleButton, b, self.config)
        if not ok and not warnedRestyle then
            warnedRestyle = true
            DF:DebugWarn(DBG, "ApplyStyle restyle failed: %s", tostring(err))
        end
    end
end

-- Structural filter change -> full rebuild (can't mutate a live filter set safely).
function Handle:SetFilter(filter)
    self.config.filter = filter
    self:_rebuild()
end

-- Public structural rebuild — for changes ApplyStyle can't do live: max, toggling a
-- region on/off, or a creation-frozen opt (bar direction, duration expiredText, dispel
-- flags). Optionally merge a partial config first. Combat-guarded (defers to regen).
function Handle:Rebuild(configDelta)
    if type(configDelta) == "table" then
        for k, v in pairs(configDelta) do self.config[k] = v end
    end
    self:_rebuild()
end

-- PTR-4 sort. No-op until HasSort() flips true, at which point this wires the
-- managed inbound sort setter. Accepting it now keeps callers unchanged at PTR-4.
function Handle:SetSort(sort)
    self.config.sort = sort
    if not AuraContainer.HasSort() then return end
    -- TODO(PTR-4): self.container:SetSortRule(...) / SetSortDirection(...)
end

-- Force a re-scan of the container. There is NO addon-callable Refresh() on b8f90f2a:
-- container:UpdateAllAuras() is an empty stub on the inbound handle (the real refresh
-- lives on the private mixin, reached only via OnShow/OnHide/OnEnabledChanged/
-- OnUnitChanged), so the sanctioned trigger is a Hide();Show() bounce -> OnShow -> the
-- secure refresh, with no filter rebuild or invalid-unit blip [Krathe, source-confirmed
-- b8f90f2a]. Use on a dynamic-unit consumer (target/focus/mouseover) when the underlying
-- unit changes but the token does not. (In-combat bounce safety is on the PTR audit
-- list; a real Refresh() / wired UpdateAllAuras is a PTR-4 candidate.)
function Handle:Refresh()
    if not self.container then return end
    local ok, err = pcall(function()
        self.container:Hide()
        self.container:Show()
    end)
    if not ok and not warnedRefresh then
        warnedRefresh = true
        DF:DebugWarn(DBG, "Refresh bounce failed: %s", tostring(err))
    end
end

-- AUTO-REFRESH for dynamic-unit containers. Since there's no callable Refresh(), a
-- target/focus/mouseover container would go silently stale on a unit swap unless the
-- consumer remembers to bounce it (Krathe). The factory registers ONE shared event
-- frame and bounces the matching handles itself. Default on for a dynamic token; opt
-- out with config.autoRefresh = false. No-op for stable party/raid tokens. Refresh()
-- is combat-safe (source-confirmed), so this works mid-combat on a target swap.
function Handle:_updateDynRefresh()
    local prefix = (self.config.autoRefresh ~= false) and dynPrefixOf(self.config.unit) or nil
    self._dynPrefix = prefix
    if prefix then
        if not AuraContainer._dyn then
            AuraContainer._dyn = CreateFrame("Frame")
            AuraContainer._dyn._handles = {}
            AuraContainer._dyn:RegisterEvent("PLAYER_TARGET_CHANGED")
            AuraContainer._dyn:RegisterEvent("PLAYER_FOCUS_CHANGED")
            AuraContainer._dyn:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
            AuraContainer._dyn:SetScript("OnEvent", function(self, event)
                for h in pairs(self._handles) do
                    if h._destroyed then
                        self._handles[h] = nil
                    elseif h._dynPrefix and DYN_EVENT[h._dynPrefix] == event then
                        h:Refresh()
                    end
                end
            end)
        end
        AuraContainer._dyn._handles[self] = true
    elseif AuraContainer._dyn then
        AuraContainer._dyn._handles[self] = nil
    end
end

-- Tear down the (secure) container + buttons. Combat-unsafe on its own, so callers
-- gate it (Destroy defers this to regen in combat).
function Handle:_teardownContainer()
    if self.container then
        pcall(function() self.container:RemoveAllAuraFrames() end)
        self.container:Hide()
        self.container = nil
    end
    wipe(self.buttons)
end

function Handle:Destroy()
    if AuraContainer._dyn then AuraContainer._dyn._handles[self] = nil end
    self._destroyed = true
    if self.frame then self.frame:Hide() end   -- plain frame; safe in combat, hides the container child too
    if InCombatLockdown() then
        -- Can't tear down secure container state in lockdown; defer to regen.
        self:_queueOp("destroy")
        return
    end
    self._pendingOp = nil
    self:_teardownContainer()
end

-- Rebuild the container from scratch (structural changes). Combat-guarded.
function Handle:_rebuild()
    if self._destroyed then return end
    if InCombatLockdown() then self:_deferRebuild(); return end
    if self.container then
        pcall(function() self.container:RemoveAllAuraFrames() end)
        self.container:Hide()
        self.container = nil
    end
    wipe(self.buttons)
    self:_build()
end

-- Register this handle for a one-shot action the moment combat ends. Ops (precedence
-- destroy > rebuild > retarget/enable): "destroy" tears down; "rebuild" full _rebuild;
-- "retarget" re-runs container:SetUnit; "enable" re-applies container:SetEnabled.
function Handle:_registerRegen()
    if not AuraContainer._regen then
        AuraContainer._regen = CreateFrame("Frame")
        AuraContainer._regen._handles = {}
        AuraContainer._regen:RegisterEvent("PLAYER_REGEN_ENABLED")
        AuraContainer._regen:SetScript("OnEvent", function(self)
            for h in pairs(self._handles) do
                self._handles[h] = nil
                local op = h._pendingOp
                h._pendingOp = nil
                -- pcall each handle's op so one failure can't strand the rest.
                if op == "destroy" then
                    pcall(function() h:_teardownContainer() end)
                elseif not h._destroyed and op then
                    pcall(function()
                        if op == "rebuild" then
                            h:_rebuild()
                        elseif op == "retarget" then
                            if h.container then h.container:SetUnit(h.config.unit) end
                        elseif op == "enable" then
                            if h.container then h.container:SetEnabled(h.config.enabled ~= false) end
                        end
                    end)
                end
            end
        end)
    end
    AuraContainer._regen._handles[self] = true
end

-- Queue a one-shot combat-end op with precedence: destroy wins outright; rebuild wins
-- over retarget/enable; two DIFFERENT lesser ops upgrade to rebuild (it re-applies unit
-- + enabled, covering both).
function Handle:_queueOp(op)
    local cur = self._pendingOp
    if cur == "destroy" then
        -- already terminal; nothing supersedes
    elseif op == "destroy" then
        self._pendingOp = "destroy"
    elseif op == "rebuild" or cur == "rebuild" then
        self._pendingOp = "rebuild"
    elseif cur and cur ~= op then
        self._pendingOp = "rebuild"
    else
        self._pendingOp = op
    end
    self:_registerRegen()
end

-- One-shot deferral of a full rebuild to combat-end.
function Handle:_deferRebuild()
    self:_queueOp("rebuild")
end

-- The construction dance (the one place that knows the CustomAuraContainer API).
-- ORDER MATTERS: SetUnit -> AddAuraFilter -> create+style+AddAuraFrame -> SetEnabled LAST.
function Handle:_build()
    local config = self.config
    checkUnwiredSeams(config)
    local c = CreateFrame("AuraContainer", nil, self.frame, "CustomAuraContainerTemplate")
    c:SetAllPoints(self.frame)
    self.container = c

    c:SetUnit(config.unit)

    local filters = normalizeFilters(config.filter)
    local maxCount = (config.mode == "overlay") and 1 or (config.max or 1)
    for _, f in ipairs(filters) do
        if AuraUtil and AuraUtil.IsValidFilterString and not AuraUtil.IsValidFilterString(f) then
            DF:DebugWarn(DBG, "filter rejected by IsValidFilterString: %s (container will be empty)", tostring(f))
        else
            c:AddAuraFilter(f, { maxFrameCount = maxCount })
        end
    end

    local n = (config.mode == "overlay") and 1 or (config.max or 1)
    for i = 1, n do
        local b = CreateFrame("AuraButton", nil, c, "CustomAuraButtonTemplate")
        self.buttons[i] = b
        if config.mode == "overlay" then b:SetAllPoints(self.frame) end
        -- Backstop: a native-setter fault on one region must never abort the build
        -- loop (which would leave the container un-Enabled and later buttons unbuilt).
        -- A styling fault degrades to "that region missing" and is logged once.
        local ok, err = pcall(styleButton, b, config)   -- register regions BEFORE handing over
        if not ok then DF:DebugWarn(DBG, "styleButton failed on button %d: %s", i, tostring(err)) end
        c:AddAuraFrame(b)               -- container adopts it (forbidden view) + binds
    end
    if config.mode ~= "overlay" then layoutRow(self) end

    c:SetEnabled(config.enabled ~= false)   -- LAST -> parses + binds with filter + frames in place

    -- Diagnostic only — our own frame count (NEVER read aura data here; iterating
    -- GetUnitAuras would taint us and break the next forbidden-object access).
    pcall(function()
        DF:Debug(DBG, "built unit=%s mode=%s filters=%d frames=%d",
            tostring(config.unit), tostring(config.mode or "row"), #filters, c:GetAuraFrameCount())
    end)

    self:_updateDynRefresh()   -- auto-bounce on target/focus/mouseover change
end

-- ============================================================
-- PUBLIC CONSTRUCTOR
-- ============================================================
-- Create an aura container. Returns a handle, or nil when unsupported (the caller
-- then keeps its existing pre-12.1 render path). Structural build is combat-guarded.
--
-- config = {
--   unit     = "raid5",
--   mode     = "row" | "overlay",              -- default "row"
--   filter   = "HELPFUL" | { "HARMFUL|RAID_PLAYER_DISPELLABLE", ... },  -- category (now)
--   spellIDs = { 774, ... },                    -- PTR-4 only; accepted + no-op now (warns if set)
--   dispelTypes = { "Magic", "Curse" },         -- PTR-4 only; accepted + no-op now (warns if set)
--   maxDuration = 30,                            -- PTR-4 only; accepted + no-op now (warns if set)
--   stealable   = true,                          -- PTR-4 only; accepted + no-op now (warns if set)
--   max      = 5,
--   enabled  = true,
--   autoRefresh = true,                          -- default on for target/focus/mouseover units
--   sort     = { rule, direction },             -- PTR-4 only; accepted + no-op now (warns if set)
--   layout   = { anchor, growth, wrap, size|sizeX|sizeY, spacing|spacingX|spacingY, offsetX, offsetY },
--   style    = { icon, border, cooldown, duration, stacks, bar, spellName, dispel, overlay },
-- }
function AuraContainer:Create(parent, config)
    if not AuraContainer.IsSupported() then return nil end
    if not parent or type(config) ~= "table" then
        DF:DebugWarn(DBG, "Create called with bad args (parent/config)")
        return nil
    end
    -- Shallow-copy so the factory OWNS its config and never mutates the caller's table
    -- (SetShown writes config.enabled, etc. — a caller's db subtable must stay untouched).
    -- Nested style/layout are shared by reference (read-only here; ApplyStyle swaps the
    -- whole style ref rather than mutating the caller's nested tables).
    local cfg = {}
    for k, v in pairs(config) do cfg[k] = v end
    cfg.unit = cfg.unit or "player"
    cfg.mode = cfg.mode or "row"

    local h = setmetatable({ config = cfg, buttons = {} }, Handle)
    h.frame = CreateFrame("Frame", nil, parent)
    -- Both modes: h.frame occupies the unit-frame rect (row layout anchors are relative
    -- to it; overlay covers it). To reposition: h:ClearAllPoints() then h:SetPoint(...).
    h.frame:SetAllPoints(parent)

    if InCombatLockdown() then
        -- Can't safely stand up secure container state in combat; build on regen.
        h:_deferRebuild()
    else
        h:_build()
    end
    return h
end
