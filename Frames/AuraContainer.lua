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
-- GOTCHAS baked in (12.1.0 @ 68569 — the PTR-4 API; validated in-game via DF_AuraLab):
--   1. Addons NO LONGER create AuraButtons (AddAuraFrame/AddAuraFramesFromTemplate removed).
--      The container creates + anchors its own buttons; we register AuraGroups (row) /
--      AuraSlots (overlay) and Blizzard calls our initializeFrame per button to style it.
--   2. Order: SetUnit -> AddAuraGroup/AddAuraSlot(each, initializeFrame) -> SetEnabled LAST.
--      SetEnabled gates aura-event registration (IsVisible() and IsEnabled()).
--   3. container:UpdateAllAuras() is now an addon-callable dirty-mark (the real refresh).
--   4. In initializeFrame: build FRESH regions as children of the button. NEVER SetParent
--      an existing scripted widget onto a button (forbidden-aspect inheritance blocks it).
--   5. SetDurationText textColorCurve is NOT addon-reachable on 68569 (live-tested: Blizzard
--      forwards the curve without the required `property`, and DurationTextBinding is private).
--      Colour-by-time = discrete BUCKETS via the duration formatter (|c escapes) — P2.
--      Stacks formatters are FORBIDDEN outright (secret trap — see bindNative).
--   6. Animation on OUR child regions is fine (AnimationGroup:Play + OnUpdate run; the
--      button's onUpdateMode=disabled doesn't propagate). Only expiry-TRIGGERED anim is dead.
--   7. Cannot read IsShown / spellId / expirationTime / dispelName / presence — all secret.
--      Never branch on them. Filtering is Blizzard-side (filterString + candidateFilters).
--   8. Group topology is add-only: no RemoveAuraGroup/Slot; a filterString change = recreate
--      the container. candidateFilters / sortMethod / maxFrameCount / layout are live setters.
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
local warnedRestyle, warnedRefresh, warnedMouse = false, false, false
local warnedCreate = false

-- ============================================================
-- CAPABILITY DETECTION  (the version gate + PTR-4 feature gates)
-- Lazy + cached. IsSupported() is the primary gate every consumer checks; when it
-- is false, Create() returns nil and the feature keeps its existing (pre-12.1)
-- render path. This keeps the live 12.0.7 client completely unchanged.
-- The probe creates a live AuraContainer, which hard-errors in combat (uncatchable
-- by pcall) — so IsSupported() never probes in lockdown: on a cold
-- cache they return false WITHOUT caching, and a login warm (below) primes the cache
-- out of combat. A false/nil taken in that login-into-combat window is TRANSIENT;
-- consumers must re-check, never latch it.
-- ============================================================
local _supported            -- tri-state: nil = not yet probed

-- Definitive probe: the 12.1 widget types either exist or CreateFrame errors.
-- Gated first on the interface number so we don't even attempt the probe on old
-- clients. The probe frame is parented to UIParent and hidden immediately after.
-- PTR-4 (68569): addons no longer create AuraButtons (AddAuraFrame removed) — the
-- container creates + anchors its own buttons via AddAuraGroup / AddAuraSlot. So the
-- positive probe is simply "does the container expose AddAuraGroup".
local function probeSupported()
    local toc = select(4, GetBuildInfo())
    if type(toc) ~= "number" or toc < 120100 then return false end
    if not (AuraUtil and AuraUtil.IsValidFilterString) then return false end
    local ok, frame = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    if not ok or not frame then return false end
    local hasGroups = type(frame.AddAuraGroup) == "function"
    pcall(function() frame:Hide() end)
    return hasGroups
end

function AuraContainer.IsSupported()
    if _supported == nil then
        -- Never probe in combat: probeSupported creates a live AuraContainer, which fires
        -- WoW's hard error dialog in lockdown and pcall does NOT catch it. Answer false for
        -- THIS call but DON'T cache it, so a later out-of-combat call (or the login warm
        -- below) probes for real. Caching false here would permanently disable a supported
        -- client whose first check happened to land mid-combat.
        if InCombatLockdown() then return false end
        local ok, res = pcall(probeSupported)
        _supported = (ok and res) and true or false
        DF:Debug(DBG, "IsSupported probe -> %s (toc=%s)", tostring(_supported), tostring(select(4, GetBuildInfo())))
    end
    return _supported
end

-- PTR-4 (68569): the managed/custom split collapsed. CustomAuraContainer IS the addon
-- container (ManagedAuraContainer* is its abstract base) and carries AddAuraGroup /
-- AddAuraSlot + candidateFilters (spell-ID / dispel-type / maxDuration / stealable) +
-- sort directly. So the old "managed template not yet resolvable" probe and the WIRED
-- gate flags are gone — capability == IsSupported(). Per-seam wiring (candidateFilters,
-- sortMethod) lands in P2/P4; consumers passing those keys before then are simply not
-- yet honored (no warn — the seams are real config now, not a future-managed no-op).
function AuraContainer.HasSpellFilter() return AuraContainer.IsSupported() end
function AuraContainer.HasSort()        return AuraContainer.IsSupported() end

-- Warm the support probe once, out of combat, at login — so no consumer's first
-- IsSupported() call ever lands the probe in combat (the probe creates a live
-- AuraContainer, uncatchable-fatal in lockdown). If we log in / reload while already
-- in combat (reconnect mid-fight), defer the warm to the next PLAYER_REGEN_ENABLED.
do
    local warm = CreateFrame("Frame")
    warm:RegisterEvent("PLAYER_LOGIN")
    warm:SetScript("OnEvent", function(self)
        if InCombatLockdown() then
            self:RegisterEvent("PLAYER_REGEN_ENABLED")   -- retry once combat drops
            return
        end
        AuraContainer.IsSupported()   -- probes + caches while safe
        self:UnregisterAllEvents()
    end)
end

-- TEST MODE. A real CustomAuraContainer reads REAL unit auras, so it shows nothing on a
-- fabricated test unit — DF's test mode must drive containers through the FakeBackend
-- (plain frames + pushed fake data) so users can preview aura settings. DF's test mode
-- calls SetTestMode(true/false) on toggle; every live handle rebuilds onto the right
-- backend. Global (all frames are test frames when test mode is on).
function AuraContainer.SetTestMode(on)
    on = on and true or false
    if (AuraContainer._testMode or false) == on then return end
    AuraContainer._testMode = on
    DF:Debug(DBG, "SetTestMode -> %s", tostring(on))
    if AuraContainer._handles then
        for h in pairs(AuraContainer._handles) do
            if not h._destroyed then pcall(function() h:OnTestModeChanged() end) end
        end
    end
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
            end
            -- Art inset: 1px default; pass icon.inset=0 for full-bleed art (matches the
            -- legacy Direct-row icons). Re-applied here (not create-once) so it's live.
            local inset = (iconSpec and iconSpec.inset) or 1
            slot.dfIcon:ClearAllPoints()
            slot.dfIcon:SetPoint("TOPLEFT", inset, -inset)
            slot.dfIcon:SetPoint("BOTTOMRIGHT", -inset, inset)
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
        if slot.dfCD.SetReverse then slot.dfCD:SetReverse(cdSpec ~= nil and cdSpec.reverse == true) end
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
-- INVARIANT: regions are create-once (styleButton_regions) and never recreated, so each
-- per-region _boundX flag stays valid for the life of the slot. If any code ever recreates
-- a region, it MUST also clear that region's _boundX or the new region silently never binds.
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
        local durSpec = style.duration or {}
        local opts = {}
        if durSpec.formatter then opts.formatter = durSpec.formatter end
        if durSpec.expiredText and durSpec.expiredText ~= "" then opts.expiredText = durSpec.expiredText end
        if durSpec.zeroText and durSpec.zeroText ~= "" then opts.zeroDurationText = durSpec.zeroText end
        local ok, err = pcall(function() slot:SetDurationText(slot.dfDur, opts) end)
        if not ok and not warnedCurve then
            warnedCurve = true
            DF:DebugWarn(DBG, "SetDurationText failed: %s", tostring(err))
        end
        -- Colour-by-time: the smooth textColorCurve path is DEAD on 68569 (live-tested
        -- 2026-07-09, port plan §2.8/§3): SetDurationText forwards SetTextColorCurve(curve)
        -- WITHOUT the required `property` arg (no-op), and `button.DurationTextBinding` is a
        -- PRIVATE field — NOT on the public object table initializeFrame receives — so the
        -- old direct-binding poke here could never fire, and poking Blizzard-owned binding
        -- state on a live button is exactly the class of touch the combat-proven DF_AuraLab
        -- initFrame avoids. durSpec.colorCurve is accepted-but-inert; colour-by-time ships
        -- via the discrete BUCKETS formatter (|cRRGGBB escapes in AddBreakpoint format
        -- strings, the NSRT/EnhanceQoL-proven path) in P2.
    end

    if slot.dfStack and slot.SetApplicationCount and not slot._boundStack then
        slot._boundStack = true
        -- ⚠ NEVER pass a formatter here (style.stacks.formatter is deliberately ignored).
        -- Blizzard's ApplyApplicationCount (Blizzard_CustomAuraButton.lua:260) calls
        -- formatter:FormatNumber(applications) in LUA with the stack count, which is
        -- SECRET in combat — and formatter userdata cannot hold secret values
        -- ("Attempt to set secret values on an object that prevents secret values").
        -- The throw lands INSIDE the container's ProcessDirtyFlags pass, tripping the
        -- dirty-flag latch (OnDirtyChanged only re-arms on clean→dirty) and bricking
        -- the container for the session — the alpha.2 in-combat freeze. Bind-time
        -- validation can't catch it: AssertValidFormatter test-drives with a NON-secret
        -- value. The no-formatter path renders secure-side via secretwrap (shows
        -- counts > 1) and is the only secret-safe option. (Duration formatters are
        -- DIFFERENT: they go to the C-side DurationTextBinding, which handles secrets.)
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

-- DF growth token -> AnchorUtil.FlowDirection member name.
local FLOW_NAME = { RIGHT = "Right", LEFT = "Left", UP = "Up", DOWN = "Down" }

-- Translate DF's layout vocabulary (anchor/growth/wrap/size/spacing/offset/scale) onto
-- the container's NATIVE flow layout. Every setter here is a LIVE mutator (each just
-- MarkDirty(AuraFrameLayout)-s), so this re-applies on a slider drag without a rebuild.
--
-- Geometry model (from Blizzard_CustomAuraContainer.lua + AnchorUtil flow layout):
--   * The container AUTO-RESIZES to its content (OnLayoutComplete -> SetSize) and its
--     buttons anchor from the container's layoutAnchorPoint corner. So we anchor the
--     CONTAINER by that same corner to the unit frame's matching corner + the user's
--     offsets — the row then grows away from the frame corner exactly like the legacy
--     hand-anchored rows (whose first icon sat at frame-anchor + offset).
--   * Wrap: the flow is row-primary; rowWidth caps a row. wrap N icons ->
--     rowWidth = N*sizeX + (N-1)*spacingX (container-local units).
--   * Vertical-primary growth (UP_*/DOWN_*): the flow can't run column-primary, so we
--     force one icon per row (rowWidth = sizeX) and the v-direction stacks the column.
--     A vertical wrap COUNT is not expressible — single column (legacy parity gap, GUI
--     note in P2 polish). CENTER growth is not expressible -> falls back to Right.
--   * Scale: applied to the container itself — buttons, fonts, borders and spacing all
--     render at row scale (the legacy defensive stride model; buff rows historically
--     didn't scale the spacing term — the flow can't express that split, and scaling
--     spacing uniformly is the more consistent behaviour anyway).
local function applyContainerLayout(c, handle)
    local config = handle.config
    local L = config.layout or {}
    local sx = (L.sizeX or L.size or 32)
    local spX = (L.spacingX or L.spacing or 4)
    local scale = tonumber(L.scale) or 1
    local anchor = (type(L.anchor) == "string" and L.anchor) or "TOPLEFT"
    local growth = (type(L.growth) == "string" and L.growth) or "RIGHT_DOWN"
    local wrap = tonumber(L.wrap) or 0

    local primary, secondary = growth:match("^(%a+)_?(%a*)$")
    primary = primary or "RIGHT"
    local verticalPrimary = (primary == "UP" or primary == "DOWN")

    local hName, vName
    if verticalPrimary then
        vName = FLOW_NAME[primary] or "Down"
        hName = FLOW_NAME[secondary] or "Right"
    else
        hName = FLOW_NAME[primary] or "Right"
        vName = FLOW_NAME[secondary] or "Down"
    end

    -- Row cap: vertical-primary = one per row (column); wrap>0 = N per row; else unlimited.
    local rowWidth
    if verticalPrimary then
        rowWidth = sx + 0.5
    elseif wrap and wrap >= 1 then
        rowWidth = wrap * sx + (wrap - 1) * spX + 0.5
    end   -- nil -> math.huge (no wrap) inside SetAuraLayoutRowWidth

    pcall(function()
        c:SetScale(scale)
        -- Anchor the container's grow-corner to the frame's matching corner + offsets.
        -- (SetPoint offsets live in the container's scaled space, matching the legacy
        -- rows whose offsets rode the scaled buttons.)
        c:ClearAllPoints()
        c:SetPoint(anchor, handle.frame, anchor, L.offsetX or 0, L.offsetY or 0)
        c:SetAuraLayoutAnchorPoint(anchor)
        if AnchorUtil and AnchorUtil.FlowDirection then
            local h = resolveEnum(AnchorUtil.FlowDirection, hName)
            local v = resolveEnum(AnchorUtil.FlowDirection, vName)
            if h ~= nil and v ~= nil then c:SetAuraLayoutGrowthDirection(h, v) end
        end
        c:SetAuraLayoutRowWidth(rowWidth)
    end)
end

-- Per-group layout options (stride/spacing; gapX keeps multi-group rows uniformly
-- spaced — groups continue on the same row with gapX between them).
local function buildGroupLayout(config)
    local L = config.layout or {}
    local sx = (L.sizeX or L.size or 32)
    local sy = (L.sizeY or L.size or sx)
    local spX = (L.spacingX or L.spacing or 4)
    local spY = (L.spacingY or L.spacing or 4)
    return {
        elementWidth    = sx,
        elementHeight   = sy,
        elementSpacingX = spX,
        elementSpacingY = spY,
        gapX            = spX,
    }
end

local function layoutRow(handle)
    local config = handle.config
    local L = config.layout or {}
    local sx = (L.sizeX or L.size or 32)
    local sy = (L.sizeY or L.size or sx)
    local spX = (L.spacingX or L.spacing or 4)
    local spY = (L.spacingY or L.spacing or 4)
    local scale = tonumber(L.scale) or 1
    local anchor = (type(L.anchor) == "string" and L.anchor) or "TOPLEFT"
    local growth = (type(L.growth) == "string" and L.growth) or "RIGHT_DOWN"
    local wrap = L.wrap or #handle.buttons
    if wrap < 1 then wrap = #handle.buttons end

    local primary, secondary = growth:match("^(%a+)_?(%a*)$")
    local pAxis = AXIS[primary] or AXIS.RIGHT
    local sAxis = AXIS[secondary] or AXIS.DOWN

    -- Step matches the legacy Direct-row math: the icon-size term is pre-scaled and each
    -- button is SetScale(scale)'d, so the icon, the step, and the button's children (fonts,
    -- border, cooldown) all render at `scale` — pixel-matching DF's buff rows. scale=1 is a no-op.
    -- preScaledStep=false (defensive row) uses the legacy DEFENSIVE stride: the icon-size term
    -- is UNSCALED, so — offsets living in the button's scaled space — the rendered stride is
    -- (size+spacing)*scale and the gap is spacing*scale (no double-scale of the size term).
    local stepX, stepY
    if L.preScaledStep == false then
        stepX = sx + spX
        stepY = sy + spY
    else
        stepX = sx * scale + spX
        stepY = sy * scale + spY
    end
    for i, b in ipairs(handle.buttons) do
        local idx = i - 1
        local col = idx % wrap
        local row = math.floor(idx / wrap)
        local x = (L.offsetX or 0) + (pAxis.x * col + sAxis.x * row) * stepX
        local y = (L.offsetY or 0) + (pAxis.y * col + sAxis.y * row) * stepY
        b:SetScale(scale)
        b:ClearAllPoints()
        b:SetPoint(anchor, handle.frame, anchor, x, y)
    end
end

-- ============================================================
-- HANDLE
-- The object DF holds + positions. Public methods form the stable seam; the
-- container/button internals swap under them at PTR-4 without callers changing.
-- ============================================================
-- ============================================================
-- BACKENDS
-- A backend PRODUCES slots (from a data source) and hands each to the layout half via
-- handle:_acceptSlot; the handle owns positioning/styling/lifecycle and routes
-- SetUnit/Enable/Refresh/teardown to the active backend. The public API is unchanged.
--
-- NativeBackend — the 68569 CustomAuraContainer path. The CONTAINER creates + anchors its
-- OWN buttons (AddAuraFrame is removed): we register one AuraGroup per filter (row mode)
-- or one AuraSlot per filter (overlay mode), and Blizzard invokes our initializeFrame
-- per button (in lazy batches of 10) to style it. isNativeSlots = true. Row layout is the
-- container's flow layout (SetAuraLayout* translation lands in P1); overlay slots are
-- addon-anchored via the button AddAuraSlot returns.
--
-- Each backend owns its OWN plain container (Krathe's proven ContainerOverlay pattern —
-- reference ContainerOverlay.lua buildOverlay): insecure CreateFrame is combat-legal for the
-- aura pipeline (taint.log-proven; the earlier freeze was unrelated secret-value compares,
-- since fixed). One container per consumer = one flow layout per row (independent
-- positioning) and a trivial recreate-on-structural-change teardown. The container is
-- STANDING: built once from config, then Blizzard drives it — no per-UNIT_AURA touches.
-- ============================================================
local NativeBackend = {}
NativeBackend.__index = NativeBackend

function NativeBackend.new(handle)
    return setmetatable({ handle = handle }, NativeBackend)
end

function NativeBackend:isNativeSlots() return true end

-- Order (Krathe's ContainerOverlay.lua buildOverlay, proven live in combat on 68569):
-- CreateFrame("AuraContainer", nil, ours, "CustomAuraContainerTemplate") -> SetAllPoints ->
-- SetUnit -> AddAuraGroup/AddAuraSlot(each filter, initializeFrame) -> SetEnabled LAST.
-- SetEnabled gates aura-event registration (IsVisible() and IsEnabled()); without the LAST
-- enable the row renders once then goes permanently stale. After build the container is
-- STANDING — Blizzard drives it; DF touches it again only on a structural rebuild, a unit
-- retarget, or teardown.
function NativeBackend:build()
    local handle = self.handle
    local config = handle.config

    -- Never stand up a container in combat: in-lockdown create/enable is a hard client
    -- error pcall can't catch (ContainerOverlay gotcha 1). Every caller already gates this
    -- (Create / _rebuild / the regen handler); a stray path defers instead of dying.
    if InCombatLockdown() then handle:_deferRebuild(); return end

    -- OUR OWN plain per-consumer container, parented to the handle's anchor frame. Insecure
    -- creation is fine — taint.log proved the old combat freeze was unrelated secret-value
    -- compares (Config.lua SafeSetFont / Auras.lua legacy scan), both fixed — and this exact
    -- plain-create pattern runs live in combat in the AD ContainerOverlay PoC.
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, handle.frame, "CustomAuraContainerTemplate")
    if not ok or not c then
        if not warnedCreate then
            warnedCreate = true
            DF:DebugWarn(DBG, "CreateFrame(AuraContainer) failed: %s", tostring(c))
        end
        self.container = nil
        return
    end
    self.container = c
    local isOverlay = config.mode == "overlay"
    if isOverlay then
        c:SetAllPoints(handle.frame)          -- overlay covers the host region
    else
        applyContainerLayout(c, handle)       -- row: anchor/growth/wrap/offset/scale -> native flow layout
    end
    if type(config.unit) == "string" then pcall(function() c:SetUnit(config.unit) end) end

    -- Fresh generation: buttons are created in lazy batches (of 10) as needed, so a slot's
    -- initializeFrame can fire long after build (incl. mid-combat on pool exhaustion). The
    -- gen token makes a late callback from a torn-down/rebuilt container no-op.
    handle._slotCounter = 0
    handle._gen = (handle._gen or 0) + 1
    local initFn = handle:_makeInitializeFrame(handle._gen)

    -- Declare one AuraGroup per filter (row) / one AuraSlot per filter (overlay). The
    -- container is exclusively ours, so keys need no cross-consumer namespacing. Group
    -- keys are remembered so ApplyStyle can hot-apply per-group layout (live mutator).
    local filters = normalizeFilters(config.filter)
    local maxCount = handle:_slotCount()
    local groupLayout = (not isOverlay) and buildGroupLayout(config) or nil
    -- Native candidate filters (spell-ID include/exclude maps, dispel types, maxDuration,
    -- booleans) — evaluated Blizzard-side per group/slot. ⚠ Spell-ID maps only apply on
    -- units the player can assist (helpful) / attack (harmful) — a harmful spell-ID map
    -- on a friendly-frame consumer is silently inert (the Meorawr gate). Structural:
    -- changing the set is a Rebuild (consumers put it in their row signature).
    local candidateFilters = config.candidateFilters
    self.groupKeys = {}
    for i, f in ipairs(filters) do
        if AuraUtil and AuraUtil.IsValidFilterString and not AuraUtil.IsValidFilterString(f) then
            DF:DebugWarn(DBG, "filter rejected by IsValidFilterString: %s (group skipped)", tostring(f))
        else
            local key = "df" .. i
            if isOverlay then
                local okSlot, btn = pcall(function()
                    return c:AddAuraSlot(key, f, { initializeFrame = initFn, candidateFilters = candidateFilters })
                end)
                if okSlot and btn then pcall(function() btn:SetAllPoints(handle.frame) end)
                elseif not okSlot then DF:DebugWarn(DBG, "AddAuraSlot failed: %s", tostring(btn)) end
            else
                local okGroup, err = pcall(function()
                    c:AddAuraGroup(key, f, { maxFrameCount = maxCount, initializeFrame = initFn,
                                             layout = groupLayout, candidateFilters = candidateFilters })
                end)
                if okGroup then
                    self.groupKeys[#self.groupKeys + 1] = key
                else
                    DF:DebugWarn(DBG, "AddAuraGroup failed: %s", tostring(err))
                end
            end
        end
    end

    -- SetEnabled LAST — after the groups/slots + filters are declared (ContainerOverlay.lua
    -- gotcha 2). This is what arms the parse + UNIT_AURA registration.
    pcall(function() c:SetEnabled(config.enabled ~= false) end)

    DF:Debug(DBG, "built (native) unit=%s mode=%s groups=%d",
        tostring(config.unit), tostring(config.mode or "row"), #filters)
end

function NativeBackend:setUnit(unit)
    if self.container and type(unit) == "string" then pcall(function() self.container:SetUnit(unit) end) end
end

-- Hot-apply layout (anchor/growth/wrap/size/spacing/offset/scale) to the LIVE container.
-- Every underlying setter is a live mutator (MarkDirty only), so a slider drag re-lays
-- out without a rebuild. Row mode only; the overlay's SetAllPoints never changes.
-- Callers combat-gate this (ApplyStyle defers to regen in lockdown).
function NativeBackend:applyLayout()
    local c = self.container
    if not c or self.handle.config.mode == "overlay" then return end
    applyContainerLayout(c, self.handle)
    if self.groupKeys and c.SetAuraGroupLayout then
        local groupLayout = buildGroupLayout(self.handle.config)
        for _, key in ipairs(self.groupKeys) do
            pcall(function() c:SetAuraGroupLayout(key, groupLayout) end)
        end
    end
    -- ★ PARTITION KICK (live-confirmed 2026-07-09): inbound mutators set the dirty
    -- flags but cannot ARM the private-side processor — OnDirtyChanged/SetOnUpdateMode
    -- run across the partition — so the change would sit unprocessed until the next
    -- UNIT_AURA event ("one event late" slider lag). The intrinsic OnShow runs
    -- SECURE-side and calls UpdateAllAuras from inside the partition -> arms +
    -- processes next frame. OOC-only (this whole path is combat-gated by ApplyStyle,
    -- but guard anyway — Show re-arms the parse, same op class as enable).
    if not InCombatLockdown() then
        pcall(function() c:Hide(); c:Show() end)
    end
end

-- Callers combat-gate this (Handle:_applyEnabled defers to regen in lockdown) — enabling
-- a container in combat is forbidden, same class of op as creating one.
function NativeBackend:setEnabled(on)
    local c = self.container
    if c then pcall(function() c:SetEnabled(on and true or false) end) end
end

-- ★ PARTITION-AWARE REFRESH (live-confirmed 2026-07-09): UpdateAllAuras() from ADDON
-- context sets the dirty flags but cannot ARM the private-side processor, so on its own
-- it waits for the next UNIT_AURA event. The Hide/Show bounce crosses the partition
-- (intrinsic OnShow runs secure-side -> UpdateAllAuras from inside -> arms + processes
-- next frame) = the immediate refresh, OOC only (Show re-arms the parse, same op class
-- as enable). In combat: mark-only best-effort — combat aura events are frequent, so the
-- flags get picked up on the next one.
function NativeBackend:refresh()
    local c = self.container
    if not c then return end
    if not InCombatLockdown() then
        pcall(function() c:Hide(); c:Show() end)
    elseif type(c.UpdateAllAuras) == "function" then
        pcall(function() c:UpdateAllAuras() end)
    end
end

-- The container is OURS (per-consumer): teardown mirrors ContainerOverlay's teardownEntry —
-- disable, drop its buttons, hide, release the ref. The next build creates a fresh container
-- (topology is add-only — no RemoveAuraGroup/Slot — so recreate IS the sanctioned removal).
-- Callers gate teardown out of combat (Destroy/_rebuild defer to regen in lockdown).
function NativeBackend:teardown()
    local c = self.container
    if c then
        pcall(function() c:SetEnabled(false) end)
        if type(c.RemoveAllAuraFrames) == "function" then
            pcall(function() c:RemoveAllAuraFrames() end)
        end
        pcall(function() c:Hide() end)
    end
    self.container = nil
end

-- FakeBackend — test-mode / preview. Produces PLAIN Frame slots (not AuraButtons) so
-- styleButton_regions renders them identically to live, and PUSHES fake data (a plain
-- frame has no native setters). isNativeSlots = false. Used when test mode is active,
-- because a real CustomAuraContainer reads REAL unit auras and shows nothing on a
-- fabricated test unit. (PTR-4's EditMode data-provider is the eventual pixel-accurate
-- replacement; until then this is the preview bridge.)
local FAKE_HELPFUL = { 774, 139, 17, 1459, 21562, 33763 }
local FAKE_HARMFUL = { 589, 980, 348, 172, 30108, 27243 }

local FakeBackend = {}
FakeBackend.__index = FakeBackend

function FakeBackend.new(handle)
    return setmetatable({ handle = handle, slots = {} }, FakeBackend)
end

function FakeBackend:isNativeSlots() return false end

function FakeBackend:build()
    local handle = self.handle
    local config = handle.config
    self.slots = {}
    local n = handle:_slotCount()
    for i = 1, n do
        local slot = CreateFrame("Frame", nil, handle.frame)
        if config.mode == "overlay" then slot:SetAllPoints(handle.frame) end
        local ok, err = pcall(function() handle:_acceptSlot(slot, i) end)  -- regions only; NO native bind
        if not ok then DF:DebugWarn(DBG, "fake slot %d failed: %s", i, tostring(err)) end
        self.slots[i] = slot
    end
    handle:_layoutSlots()
    self:_fill()
    self:setEnabled(config.enabled ~= false)   -- honour disabled state (mirror Custom's SetEnabled)
    DF:Debug(DBG, "built (fake) unit=%s mode=%s slots=%d", tostring(config.unit), tostring(config.mode or "row"), n)
end

-- Push representative fake data so styling previews as it will live. The cooldown swipe
-- animates itself off SetCooldown; other regions get static preview values.
function FakeBackend:_fill()
    local config = self.handle.config
    if config.mode == "overlay" then return end   -- overlay shows tint/border via regions; no icon data
    local harmful = false
    for _, f in ipairs(normalizeFilters(config.filter)) do
        if f:find("HARMFUL") then harmful = true; break end
    end
    local pool = harmful and FAKE_HARMFUL or FAKE_HELPFUL
    local staticID = config.style and config.style.icon and config.style.icon.staticSpellID
    for i, slot in ipairs(self.slots) do
        if slot.dfIcon and not staticID and C_Spell and C_Spell.GetSpellTexture then
            local tex = C_Spell.GetSpellTexture(pool[((i - 1) % #pool) + 1])
            if tex then slot.dfIcon:SetTexture(tex) end
        end
        if slot.dfCD and slot.dfCD.SetCooldown then
            slot.dfCD:SetCooldown(GetTime() - ((i * 3) % 18), 18)   -- self-animating fake swipe
        end
        if slot.dfStack then slot.dfStack:SetText(i > 1 and tostring(i) or "") end
        if slot.dfDur then slot.dfDur:SetText("12") end
        if slot.dfBar then slot.dfBar:SetMinMaxValues(0, 1); slot.dfBar:SetValue(0.65) end
    end
end

function FakeBackend:setUnit(unit) end   -- fake data is unit-independent
function FakeBackend:setEnabled(on)
    on = on and true or false
    for _, slot in ipairs(self.slots) do slot:SetShown(on) end
end
function FakeBackend:refresh() self:_fill() end
function FakeBackend:teardown()
    for _, slot in ipairs(self.slots) do slot:Hide() end
    self.slots = {}
end

local Handle = {}
Handle.__index = Handle

-- Backend contract (layout half): the backend calls these to hand produced slots in and
-- to lay them out. The handle owns positioning/styling/lifecycle; the backend owns the
-- source object + slot production.
function Handle:_getConfig() return self.config end
function Handle:_getAnchorFrame() return self.frame end
function Handle:_slotCount()
    return (self.config.mode == "overlay") and 1 or (self.config.max or 1)
end
function Handle:_acceptSlot(slot, index)
    self.buttons[index] = slot                 -- cache first (mirror of the pre-split order)
    styleButton_regions(slot, self.config)     -- source-agnostic region creation/styling
end
function Handle:_bindNativeSlot(slot)
    bindNative(slot, self.config)              -- native setters (native slots only)
end
function Handle:_layoutSlots()
    -- NATIVE row mode = the container's own flow layout anchors the buttons (wired via
    -- applyContainerLayout at build; hot-applied via NativeBackend:applyLayout) — never
    -- hand-anchor those (SetPoint would fight the secure flow layout). PLAIN slots (the
    -- FakeBackend's test-mode rows, the future "slots" mode) hand-anchor via layoutRow.
    if self.config.mode == "overlay" then return end
    if self.backend and self.backend:isNativeSlots() then return end
    layoutRow(self)
end

-- Build the per-button styling callback Blizzard invokes (securecallfunction) for each
-- container-created button, in lazy batches of 10 as auras appear -- so this can fire long
-- after build, including mid-combat. Whole body is pcall-wrapped (an unguarded fault would
-- abort Blizzard's batch creation); the gen token drops a callback from a torn-down or
-- rebuilt container; a running counter mirrors the old per-index slot id (batches append,
-- so indices stay contiguous -- ipairs(self.buttons) in ApplyStyle/layoutRow still holds).
function Handle:_makeInitializeFrame(gen)
    local handle = self
    return function(button)
        local ok, err = pcall(function()
            if handle._destroyed or handle._gen ~= gen or not button then return end
            local i = (handle._slotCounter or 0) + 1
            handle._slotCounter = i
            -- Click-through + tooltip opt-in: click-off removes the button from hit-testing so
            -- targeting/click-casting reaches the unit frame beneath; tooltips default off (raid
            -- mouseover-healing). No SetCancelAuraButtons -- default is already no-cancel, and it
            -- takes a click-token string (a table errors).
            if button.SetMouseClickEnabled then button:SetMouseClickEnabled(false) end
            if button.SetMouseMotionEnabled then button:SetMouseMotionEnabled(handle.config.tooltips == true) end
            handle:_acceptSlot(button, i)      -- size + regions (source-agnostic)
            handle:_bindNativeSlot(button)     -- native inbound setters
        end)
        if not ok and not warnedRestyle then
            warnedRestyle = true
            DF:DebugWarn(DBG, "initializeFrame styling failed: %s", tostring(err))
        end
    end
end

function Handle:GetFrame() return self.frame end
-- Returns the DESIRED unit; while in combat the backend retarget may still be deferred to regen.
function Handle:GetUnit()  return self.config.unit end

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
    if self.backend then self.backend:setEnabled(on) end
end

-- Retarget the container's unit. Guarded: retargeting touches secure container
-- state, so defer if we're in combat.
function Handle:SetUnit(unit)
    self.config.unit = unit
    self:_updateDynRefresh()   -- re-evaluate dynamic-unit auto-refresh for the new token
    -- In combat, defer JUST the retarget (a full rebuild would leak a container + N
    -- buttons every combat on roster churn); "retarget" re-runs SetUnit at regen.
    if InCombatLockdown() then self:_queueOp("retarget"); return end
    if self.backend then self.backend:setUnit(unit) end
end

-- In-place cosmetic RESTYLE (colours / sizes / fonts / offsets / layout). NOTE: this
-- REPLACES config.style (it is not a merge) and only re-applies always-updated props —
-- it does NOT create/remove regions or change creation-frozen opts (duration
-- expiredText/colorCurve, bar interpolation/direction, dispel show flags). To toggle a
-- region on/off or change a frozen opt, use Rebuild(). pcall-guarded so a restyle fault
-- can't escape into a GUI callback.
function Handle:ApplyStyle(style, layout)
    if type(style) == "table" then
        self.config.style = style
    end
    if type(layout) == "table" then
        self.config.layout = layout   -- optional geometry swap (size/scale/spacing/growth/offsets)
    end
    -- BUILD-ONCE-LEAVE-IT (combat parity with the proven DF_AuraLab pattern): a live
    -- native container's buttons are NEVER re-touched in combat. The lab builds once,
    -- lets Blizzard drive, and only restyles on explicit OOC user action; restyling
    -- live buttons mid-combat (SetSize/SetPoint/SetTexCoord/SafeSetFont on regions the
    -- native driver owns) is a divergence from the combat-proven pattern. Config is
    -- already captured above; the restyle replays at regen.
    if InCombatLockdown() then
        self._pendingRestyle = true
        self:_registerRegen()
        return
    end
    -- Row-mode buttons are anchored by the CONTAINER's secure flow layout -- SetPoint-ing
    -- them here would fight it (and touches secretwrapped anchor points). Geometry changes
    -- hot-apply through the live SetAuraLayout*/SetAuraGroupLayout mutators instead; plain
    -- (fake/slots) rows hand-anchor via layoutRow. styleButton_regions below still
    -- re-applies per-button SIZE, which the flow layout reads.
    local native = self.backend and self.backend:isNativeSlots()
    if native then
        if self.backend.applyLayout then self.backend:applyLayout() end
    elseif self.config.mode ~= "overlay" then
        layoutRow(self)
    end
    for _, b in ipairs(self.buttons) do
        local ok, err = pcall(function()
            styleButton_regions(b, self.config)
            if native then bindNative(b, self.config) end
        end)
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
    -- TODO(PTR-4): route to the managed backend's sort setter (rule + direction).
end

-- Force a re-scan of the container. 68569: UpdateAllAuras() is an addon-callable
-- dirty-mark (processed on the next OnUpdate while visible) — the real refresh. Use on
-- a dynamic-unit consumer (target/focus/mouseover) when the underlying unit changes but
-- the token does not. Falls back to an out-of-combat Hide/Show bounce if absent.
function Handle:Refresh()
    if not self.backend then return end
    local ok, err = pcall(function() self.backend:refresh() end)
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
            AuraContainer._dyn._handles = setmetatable({}, { __mode = "k" })
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
    if self.backend then self.backend:teardown(); self.backend = nil end
    wipe(self.buttons)
    self._slotCounter = 0   -- restart the lazy-batch index for the next build
end

function Handle:Destroy()
    if AuraContainer._dyn then AuraContainer._dyn._handles[self] = nil end
    if AuraContainer._handles then AuraContainer._handles[self] = nil end
    self._destroyed = true
    if self.frame then self.frame:Hide() end   -- plain frame; safe in combat, hides the container child too
    if InCombatLockdown() then
        -- Can't tear down secure container state in lockdown; defer to regen.
        self:_queueOp("destroy")
        return
    end
    self._pendingOp = nil
    self._pendingRestyle = nil
    self:_teardownContainer()
end

-- Rebuild the container from scratch (structural changes). Combat-guarded.
function Handle:_rebuild()
    if self._destroyed then return end
    if InCombatLockdown() then self:_deferRebuild(); return end
    self:_teardownContainer()
    self:_build()
end

-- Register this handle for a one-shot action the moment combat ends. Ops (precedence
-- destroy > rebuild > retarget/enable): "destroy" tears down; "rebuild" full _rebuild;
-- "retarget" re-runs container:SetUnit; "enable" re-applies container:SetEnabled.
function Handle:_registerRegen()
    if not AuraContainer._regen then
        AuraContainer._regen = CreateFrame("Frame")
        AuraContainer._regen._handles = setmetatable({}, { __mode = "k" })
        AuraContainer._regen:RegisterEvent("PLAYER_REGEN_ENABLED")
        AuraContainer._regen:SetScript("OnEvent", function(self)
            for h in pairs(self._handles) do
                self._handles[h] = nil
                local op = h._pendingOp
                h._pendingOp = nil
                local restyle = h._pendingRestyle
                h._pendingRestyle = nil
                -- pcall each handle's op so one failure can't strand the rest.
                if op == "destroy" then
                    pcall(function() h:_teardownContainer() end)
                elseif not h._destroyed then
                    if op then
                        pcall(function()
                            if op == "rebuild" then
                                h:_rebuild()
                            elseif op == "retarget" then
                                if h.backend then h.backend:setUnit(h.config.unit) end
                            elseif op == "enable" then
                                if h.backend then h.backend:setEnabled(h.config.enabled ~= false) end
                            end
                        end)
                    end
                    -- Combat-deferred cosmetic restyle (ApplyStyle hit in lockdown). A
                    -- rebuild already styles fresh buttons from the updated config, so
                    -- only non-rebuild paths need the explicit OOC re-apply.
                    if restyle and op ~= "rebuild" then
                        pcall(function() h:ApplyStyle() end)
                    end
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

-- Build via the active backend. Only NativeBackend today (the 68569 container path). Test
-- mode goes native at P5.5 via SwitchAuraDataProvider (Blizzard's edit-mode fake data feeds
-- our real containers), which retires the old FakeBackend. The backend owns the container +
-- slot production; the handle owns styling/layout/lifecycle.
function Handle:_build()
    self.backend = NativeBackend.new(self)
    self.backend:build()
    self:_updateDynRefresh()   -- auto-bounce on target/focus/mouseover change
end

-- Test mode toggled -> rebuild onto the other backend (fake <-> custom). Combat-guarded
-- via _rebuild. Called by AuraContainer.SetTestMode for every live handle.
function Handle:OnTestModeChanged()
    self:_rebuild()
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
--   tooltips = false,                            -- boolean ONLY; hover = native aura tooltip. Default off
--                                                -- (raid mouseover-healing). Change needs Rebuild(); in
--                                                -- overlay mode the button covers the whole unit frame.
--   sort     = { rule, direction },             -- PTR-4 only; accepted + no-op now (warns if set)
--   layout   = { anchor, growth, wrap, scale, size|sizeX|sizeY, spacing|spacingX|spacingY, offsetX, offsetY },
--   style    = { icon{show,zoom,inset,staticSpellID}, border, cooldown{show,edge,reverse,numbers},
--                duration, stacks, bar, spellName, dispel, overlay },
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
    AuraContainer._handles = AuraContainer._handles or setmetatable({}, { __mode = "k" })
    AuraContainer._handles[h] = true   -- weak-keyed registry so a dropped handle GCs (else rebuild-forever on test toggle)
    -- h.frame is the plain anchor frame DF positions; the backend parents its OWN
    -- CustomAuraContainer to it (per-consumer container — Krathe's ContainerOverlay pattern).
    h.frame = CreateFrame("Frame", nil, parent)
    -- Both modes: h.frame occupies the unit-frame rect (row layout anchors are relative
    -- to it; overlay covers it). To reposition: h:ClearAllPoints() then h:SetPoint(...).
    h.frame:SetAllPoints(parent)
    -- Z-order: legacy renders host aura icons ABOVE contentOverlay (parent+25, name/health
    -- text). Raising h.frame raises the whole subtree — the native container + AuraButtons +
    -- their holders are all descendants with relative levels (Blizzard sets no fixed levels).
    -- Default +40 = legacy buff-icon level; the defensive row passes +51 (= contentOverlay+26).
    h.frame:SetFrameLevel(math.max(0, parent:GetFrameLevel() + (cfg.frameLevelOffset or 40)))

    if InCombatLockdown() then
        -- Can't safely stand up secure container state in combat; build on regen.
        h:_deferRebuild()
    else
        h:_build()
    end
    return h
end
