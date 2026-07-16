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
--   h:Rebuild(config)      -- structural rebuild (max / region toggles / frozen opts); a
--                             table REPLACES the config wholesale (callers pass complete configs)
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
--   6. Animation drivers do NOT run inside the button subtree: onUpdateMode=disabled
--      propagates, so an OnUpdate/AnimationGroup on a descendant is installed but never
--      ticks (verified in-game — SetScript/Play merely don't error). Host the driver
--      OUTSIDE the subtree (e.g. UIParent) and drive our own textures by reference — see
--      DF.Border ensureDriver (secretRect -> UIParent). Expiry-TRIGGERED anim is separately
--      dead (needs the sealed timer).
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

-- Lifetime counters read by the DF Profiler (rebuild-storm detection): a healthy
-- session builds containers at login/settings changes only, so a climbing build
-- count during combat profiling means a structural-signature bug. Always on —
-- three integer increments have no measurable cost.
AuraContainer.stats = AuraContainer.stats or { builds = 0, teardowns = 0, defers = 0 }

local DBG = "AURACONTAINER"

-- One-time-per-process warning latches so a guarded failure (curve bug, border
-- taint, native dispel reject) logs ONCE, not once per button.
local warnedCurve, warnedBorder, warnedNativeDispel = false, false, false
local warnedRestyle, warnedRefresh, warnedMouse = false, false, false
local warnedCreate = false

-- Animations SAFE to run on an OVERLAY-mode border (Aura Designer). These render
-- entirely on DF-owned child regions of the border (edge alpha ticks + DF_DASH's
-- own dash / sparkle / flipbook / overlay textures on our own frames), so they
-- never re-parent anything onto a Blizzard AuraButton and never taint.
-- Any type NOT in this set (a future/unknown type) is stripped. ROW mode always
-- strips (see below).
local SAFE_OVERLAY_ANIM = {
    DF_PULSATE     = true,
    DF_DASH        = true,
    CORNERS_ONLY   = true,
    BLINK          = true,
    DF_ORBIT       = true,
    DF_PROC        = true,
    DF_FLASH       = true,
    DF_PIXEL       = true,
}
-- Exposed so non-container consumers that apply a secretRect border directly
-- (the missing-buff badge) can restrict to the same taint-safe DF-owned set.
AuraContainer.SAFE_BORDER_ANIM = SAFE_OVERLAY_ANIM

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

-- TEST MODE (P5 hybrid, probe 33 live-proven). A real CustomAuraContainer reads real
-- unit auras — nothing renders on a fabricated test unit. Instead of faking the
-- CONTAINER we fake the DATA: the game's own sample provider
-- (C_UnitAuras.SwitchAuraDataProvider — what Edit Mode uses) drives PRESENCE, the
-- real container drives GEOMETRY, and the test initializeFrame paints DF's curated
-- test icons instead of binding the native setters (the sample auras wear random
-- spellbook icons — never shown). Rows preview with the user's true layout, borders,
-- fonts and cooldown regions.
--
-- ORDER MATTERS (born-deaf containers, probe 33): a container built AFTER a provider
-- switch never hears the event and stays on the previous source — so entry rebuilds
-- every handle FIRST, then bounces the provider (reset -> switch) so a fresh event
-- reaches the just-built rows. Exit resets the provider FIRST so the rebuilt live
-- rows parse real data immediately. _ownsProviderSwitch stays set for the whole
-- test-mode duration so the edit-mode guard (ensureProviderWatch) never hides our
-- own preview. The switch is GLOBAL — Blizzard's own aura displays show sample data
-- while DF test mode is open (restored on exit; accepted trade-off).
-- Coalesced provider bounce (reset -> switch). Only the EVENT flips a container
-- onto the sample source, and a container built AFTER a switch never heard it —
-- so EVERY native build during test mode queues a bounce (handles are created
-- lazily by the drives' first test pass, well after SetTestMode's own rebuild).
-- Next-frame + coalesced: one bounce covers a whole batch of builds.
function AuraContainer._queueTestBounce()
    if AuraContainer._bouncePending then return end
    AuraContainer._bouncePending = true
    C_Timer.After(0, function()
        AuraContainer._bouncePending = nil
        if not AuraContainer._testMode then return end   -- exited before the tick
        pcall(function()
            if C_UnitAuras.ResetAuraDataProvider then C_UnitAuras.ResetAuraDataProvider() end
        end)
        local ok = pcall(function() C_UnitAuras.SwitchAuraDataProvider() end)
        if not ok then pcall(function() C_UnitAuras.SwitchAuraDataProvider(false) end) end
        -- Test containers are built DISABLED (see NativeBackend:build) so they never
        -- parse real auras before the sample source is live — enable them all now,
        -- with a refresh kick so the parse runs this frame instead of next event.
        -- MISSING mode stays DISABLED for the whole test session: its groups then
        -- never fill, so every badge sits parked in its window — the "missing"
        -- preview. Enabling would fill the groups with sample HELPFUL auras
        -- (spell-ID filters are stripped in test) and push every badge out.
        for h in pairs(AuraContainer._handles or {}) do
            if not h._destroyed and h.backend and h.config and h.config.enabled ~= false
               and h.config.mode ~= "missing" then
                if h.backend.setEnabled then pcall(function() h.backend:setEnabled(true) end) end
                if h.backend.refresh then pcall(function() h.backend:refresh() end) end
            end
        end
    end)
end

function AuraContainer.SetTestMode(on)
    on = on and true or false
    if (AuraContainer._testMode or false) == on then return end
    AuraContainer._testMode = on
    DF:Debug(DBG, "SetTestMode -> %s", tostring(on))

    local function rebuildAll()
        if AuraContainer._handles then
            for h in pairs(AuraContainer._handles) do
                if not h._destroyed then pcall(function() h:OnTestModeChanged() end) end
            end
        end
    end

    if on then
        AuraContainer._ownsProviderSwitch = true
        rebuildAll()
        AuraContainer._queueTestBounce()
        AuraContainer._startTestTicker()
    else
        AuraContainer._stopTestTicker()
        pcall(function()
            if C_UnitAuras.ResetAuraDataProvider then C_UnitAuras.ResetAuraDataProvider()
            else C_UnitAuras.SwitchAuraDataProvider(true) end
        end)
        AuraContainer._ownsProviderSwitch = false
        rebuildAll()
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

-- Normalize config.filter into a clean list of RECORDS { f, key?, candidateFilters? }.
-- Accepted inputs: a filter string, a list of filter strings, or a list of records
-- ({ filter = "HARMFUL", key = "magic", candidateFilters = {...} }) for consumers whose
-- groups/slots differ per filter (the dispel overlay's per-type slots). A record's
-- candidateFilters REPLACES config.candidateFilters for that group/slot; its key
-- replaces the positional "df<i>" key (must be unique within the consumer).
local function normalizeFilters(filter)
    local out = {}
    if type(filter) == "string" then
        out[1] = { f = filter }
    elseif type(filter) == "table" then
        for _, f in ipairs(filter) do
            if type(f) == "string" then
                out[#out + 1] = { f = f }
            elseif type(f) == "table" and type(f.filter) == "string" then
                out[#out + 1] = { f = f.filter, key = f.key, candidateFilters = f.candidateFilters }
            end
        end
    end
    if #out == 0 then out[1] = { f = "HELPFUL" } end
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
        -- FILLED HEALTH MIRROR — a StatusBar child of the slot fed the unit's SECRET
        -- health percent render-side (DF.MirrorHealthValue in the Update loop), so it
        -- matches the real bar's fill / texture / smooth-motion WITHOUT the addon ever
        -- reading or branching a secret. Identity (texture/colour/alpha) is static config;
        -- recolour is SetStatusBarColor (render-side). Visibility rides the slot's secret
        -- show/hide (attach-and-inherit). onBar hands the bar back so the consumer can feed
        -- it. ADDITIVE: never touches the tintColor path or the #205 buff/debuff rows.
        local hm = ov and ov.healthMirror
        if hm then
            if not slot.dfHealthMirror then
                slot.dfHealthMirror = CreateFrame("StatusBar", nil, slot)
                slot.dfHealthMirror:SetAllPoints(slot)
                slot.dfHealthMirror:EnableMouse(false)
                slot.dfHealthMirror:SetMinMaxValues(0, 100)
            end
            local sb = slot.dfHealthMirror
            DF:SafeSetStatusBarTexture(sb, hm.texture)
            local cr, cg, cb = readColor(hm.color)
            sb:SetStatusBarColor(cr, cg, cb)
            sb:SetAlpha(hm.alpha or 1)
            if type(hm.onBar) == "function" then hm.onBar(sb) end
        end
        -- MIRROR HOST — a plain child frame of the slot handed back to the consumer
        -- (the Aura Designer name/health text colour-by-cover). The consumer parents
        -- Text-Designer mirror FontStrings to it: the host contributes ONLY the slot's
        -- secret visibility chain (aura present -> host visible -> covers render); the
        -- mirrors position themselves by anchoring to the real FontStrings. onHost fires
        -- every style pass (create + ApplyStyle + Blizzard re-init) so the consumer's
        -- EnableMirrors registration is always current. ADDITIVE: only the AD text
        -- consumer sets it; tintColor/healthMirror and the #205 rows are untouched.
        local mh = ov and ov.mirrorHost
        if mh then
            if not slot.dfMirrorHost then
                slot.dfMirrorHost = CreateFrame("Frame", nil, slot)
                slot.dfMirrorHost:SetAllPoints(slot)
                slot.dfMirrorHost:EnableMouse(false)
            end
            if type(mh.onHost) == "function" then mh.onHost(slot.dfMirrorHost) end
        end
    else
        -- ROW mode content is EITHER the aura's own ICON texture (native SetIcon fills
        -- it) OR a solid-colour SQUARE fill (DF-owned static colour — the Aura Designer
        -- "square" indicator, whose legacy render is a SetColorTexture box, not the spell
        -- art). A square NEVER binds SetIcon (no dfIcon created), so the icon path is
        -- skipped whenever a square fill is configured. Both are read-free; the slot's
        -- secret show/hide drives their visibility (attach-and-inherit).
        local squareSpec = style.square
        if squareSpec then
            if not slot.dfSquare then
                slot.dfSquare = slot:CreateTexture(nil, "BACKGROUND")
            end
            local inset = squareSpec.inset or 0
            slot.dfSquare:ClearAllPoints()
            slot.dfSquare:SetPoint("TOPLEFT", inset, -inset)
            slot.dfSquare:SetPoint("BOTTOMRIGHT", -inset, inset)
            slot.dfSquare:SetColorTexture(readColor(squareSpec.color))
        end
        local iconSpec = style.icon
        if not squareSpec and (iconSpec == nil or iconSpec.show ~= false) then
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
    -- secretRect: container buttons are anchored by Blizzard's flow layout with
    -- secret-wrapped offsets (and have NO anchors yet when initializeFrame runs), so
    -- TEXTURE-style borders must render via DF.Border's anchor-only piece path —
    -- BackdropTemplate's Lua tiling math scatters/breaks on secret or unresolved rects.
    local borderSpec = style.border
    if borderSpec and DF.Border then
        if not slot.dfBorder then
            local ok, w = pcall(function() return DF.Border:New(slot, { solidOnly = true, secretRect = true }) end)
            if ok then slot.dfBorder = w end
        end
        if slot.dfBorder then
            local ok, err = pcall(function()
                local spec = borderSpec.spec
                if not spec and borderSpec.db and borderSpec.prefix then
                    local iconMode = borderSpec.iconMode
                    if iconMode == nil then iconMode = (config.mode ~= "overlay") end
                    spec = DF.Border:BuildSpec(borderSpec.db, borderSpec.prefix, { unit = config.unit, frame = slot, iconMode = iconMode })
                    -- DF_DASH lays its dash count out from the frame's width/height, but a
                    -- row slot's rect is SECRET on 12.1 (reading GetWidth taints). Feed the
                    -- configured slot size so the dashes size from it, not the secret rect.
                    if spec then spec.knownWidth, spec.knownHeight = sx, sy end
                end
                -- ANIMATION FILTER (single chokepoint for every container border).
                -- 12.1 PTR-5 made AuraButtons blanket-forbidden while auras are secret
                -- (combat / M+ / encounters / PvP): once forbidden, ANY API call on the
                -- button OR its children errors from our tainted code — including the
                -- render setters our OnUpdate border driver uses (SetVertexColor / Hide /
                -- SetPoint). Every animated border here lives on a container-button child,
                -- so any animation spams a per-frame forbidden error in exactly the content
                -- these indicators are for. Animation is therefore stripped on ALL
                -- container borders unconditionally (the recovery that once let AD placed /
                -- overlay borders animate via config.adBorderAnim is gone). DF-owned frames
                -- OFF the container — unit-frame border, missing-buff badge, targeted-spell
                -- highlight — are not forbidden and keep animating through their own paths.
                if spec then
                    spec.animation = nil
                    DF.Border:Apply(slot.dfBorder, spec)
                end
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
        slot.dfCD:SetAllPoints(slot.dfIcon or slot.dfSquare or slot)
        if slot.dfCD.SetDrawEdge then slot.dfCD:SetDrawEdge(cdSpec == nil or cdSpec.edge ~= false) end
        -- Swipe on by default; cdSpec.swipe=false hides it (AD "Hide Cooldown Swipe").
        if slot.dfCD.SetDrawSwipe then slot.dfCD:SetDrawSwipe(cdSpec == nil or cdSpec.swipe ~= false) end
        if slot.dfCD.SetReverse then slot.dfCD:SetReverse(cdSpec ~= nil and cdSpec.reverse == true) end
        if slot.dfCD.SetHideCountdownNumbers then
            slot.dfCD:SetHideCountdownNumbers(not (cdSpec and cdSpec.numbers))
        end
    end

    -- DURATION text region (native SetDurationText bind is in bindNative). Styling is
    -- a shared DF.TextStyle spec (font/anchor/offsets/justify/colour — colour nil when
    -- a formatter/curve owns it, TextStyle never stomps in that case).
    local durSpec = style.duration
    if isRow and durSpec and durSpec.show then
        if not slot.dfDur then
            slot.dfDurHolder = makeHolder(slot, durSpec.level or 6)
            slot.dfDur = slot.dfDurHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        end
        DF.TextStyle:Apply(slot.dfDur, durSpec, slot.dfDurHolder)
    end

    -- STACK count region (native SetApplicationCount bind is in bindNative).
    local stackSpec = style.stacks
    if isRow and stackSpec and stackSpec.show then
        if not slot.dfStack then
            slot.dfStackHolder = makeHolder(slot, stackSpec.level or 7)
            slot.dfStack = slot.dfStackHolder:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        end
        DF.TextStyle:Apply(slot.dfStack, stackSpec, slot.dfStackHolder)
    end

    -- DURATION bar region (native SetDurationBar bind is in bindNative). Two shapes:
    --   * barSpec.fill (Aura Designer bar indicator, P4.4): the StatusBar IS the slot
    --     content, filling it edge-to-edge — no icon, no square, no swipe. Native
    --     SetDurationBar drives the value from the aura's Duration object (read-free).
    --     Texture / fill-colour / orientation / reverse-fill / background from config.
    --   * legacy strip (dormant #205 duration-bar option): a short bar hung below the icon.
    local barSpec = style.bar
    if isRow and barSpec and barSpec.show then
        if not slot.dfBar then
            slot.dfBar = CreateFrame("StatusBar", nil, slot)
            slot.dfBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
            slot.dfBar:SetMinMaxValues(0, 1)   -- native SetDurationBar drives SetValue in [0,1]
        end
        local sb = slot.dfBar
        if barSpec.fill then
            -- Re-anchor to fill the slot every pass (idempotent; safe on ApplyStyle).
            sb:ClearAllPoints()
            sb:SetAllPoints(slot)
            if barSpec.texture and DF.SafeSetStatusBarTexture then
                DF:SafeSetStatusBarTexture(sb, barSpec.texture)
            end
            if barSpec.orientation and sb.SetOrientation then sb:SetOrientation(barSpec.orientation) end
            if sb.SetReverseFill then sb:SetReverseFill(barSpec.reverseFill and true or false) end
            -- Background texture child (drawn under the fill). Create-once; recolour live.
            if barSpec.bgColor or barSpec.bgTexture then
                if not slot.dfBarBG then
                    slot.dfBarBG = sb:CreateTexture(nil, "BACKGROUND")
                    slot.dfBarBG:SetAllPoints(sb)
                end
                local cr, cg, cb, ca = readColor(barSpec.bgColor, 0.15, 0.15, 0.15, 0.8)
                if barSpec.bgTexture then
                    -- Textured background: tint the supplied texture via vertex colour.
                    slot.dfBarBG:SetTexture(barSpec.bgTexture)
                    slot.dfBarBG:SetVertexColor(cr, cg, cb, ca)
                else
                    -- Solid colour, no texture: paint it directly. SetVertexColor alone
                    -- tints NOTHING when the texture has no source, so a bgColor set
                    -- without a bgTexture never showed (this bug).
                    slot.dfBarBG:SetColorTexture(cr, cg, cb, ca)
                end
            elseif slot.dfBarBG then
                slot.dfBarBG:SetColorTexture(0, 0, 0, 0)   -- background cleared
            end
            sb:SetStatusBarColor(readColor(barSpec.color, 1, 1, 1, 1))
        else
            if sb:GetNumPoints() == 0 then
                sb:SetPoint("TOPLEFT", slot, "BOTTOMLEFT", 0, -2)
                sb:SetPoint("TOPRIGHT", slot, "BOTTOMRIGHT", 0, -2)
            end
            sb:SetStatusBarColor(readColor(barSpec.color, 0.2, 0.9, 0.3, 1))
            sb:SetHeight(barSpec.height or 4)
        end
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
            -- HOLDER at +12: DF.Border is a child FRAME at +10, so a slot-level texture
            -- would render UNDER the static border and the dispel colour would be
            -- invisible behind it. (Holder-hosted regions are registrar-legal — the
            -- duration text binds from a holder the same way.)
            slot.dfDispelHolder = makeHolder(slot, dispelSpec.level or 12)
            slot.dfAuraBorder = slot.dfDispelHolder:CreateTexture(nil, "OVERLAY")
            -- The native Color style only VERTEX-TINTS the region (SetAuraBorderColor →
            -- SetVertexColor; no file is ever assigned) — a blank texture renders
            -- nothing, so the ART is entirely ours. A flat square ring matching the
            -- icon's own DF border replaces the old rounded UI-Debuff-Overlays ring,
            -- which clashed with DF's square borders (Krathe 2026-07-10).
            slot.dfAuraBorder:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\DF_SquareRing")
        end
        if slot.dfAuraBorder then
            -- Inset re-applied every pass (NOT create-once) so the slider is live.
            -- DF.Border sign convention: positive = inward, negative = outward halo.
            local ins = dispelSpec.inset or -2
            slot.dfAuraBorder:ClearAllPoints()
            slot.dfAuraBorder:SetPoint("TOPLEFT", slot.dfDispelHolder, "TOPLEFT", ins, -ins)
            slot.dfAuraBorder:SetPoint("BOTTOMRIGHT", slot.dfDispelHolder, "BOTTOMRIGHT", -ins, ins)
            -- EXACT ring thickness via TexCoord crop: the art is a 128px square
            -- ring 32 texels (25%) thick with a transparent centre. Cropping the
            -- outer margin by fraction `a` leaves a ring of (32-128a) texels on a
            -- (128-256a) source, so at rendered size s the line is
            --   t = s*(32-128a)/(128-256a)  ->  a = (s-4t)/(4(s-2t)).
            -- s per axis comes from OUR layout config (never a rect read — the
            -- buttons' rects are secret/unresolved, §20c), expanded by the inset.
            -- Recomputed every pass so thickness/size/inset sliders apply live.
            local t = dispelSpec.thickness or 2
            local function ringCrop(sEff)
                if sEff <= 0 or 4 * t >= sEff then return 0 end   -- clamp: max line = size/4
                local a = (sEff - 4 * t) / (4 * (sEff - 2 * t))
                if a < 0 then a = 0 elseif a > 0.2495 then a = 0.2495 end
                return a
            end
            local aX = ringCrop(sx - 2 * ins)
            local aY = ringCrop(sy - 2 * ins)
            slot.dfAuraBorder:SetTexCoord(aX, 1 - aX, aY, 1 - aY)
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
-- Resolve config.layout into flow parameters: flow direction names, the corner the
-- flow fills from (flowAnchor), and how the container box pins to the user's anchor
-- point (pinPoint + pinX/pinY offsets).
--
-- CENTER growth ("Direction: Center" — legacy did this with a second positioning
-- pass, Icons.lua ApplyDefensiveBarCenterGrowth): the native flow has no centering
-- concept, but the container SELF-SIZES to content each layout pass (secret SetSize,
-- Blizzard_CustomAuraContainer.lua:738) — so fill the box from a fixed corner and
-- pin the box's centre-of-edge to the user's anchor point; the render then keeps
-- the row centred as icons come and go, in combat, with zero reads. pinX/pinY fold
-- in the icon-anchor offset the legacy pass produced (legacy anchored each ICON's
-- own `anchor` point at the target; the box pin is edge-based), so the common
-- single-row case lands where the legacy pass put it. Multi-row blocks fill from
-- the box corner (flow order) rather than centring each row individually —
-- accepted approximation, the flow owns button placement.
local function resolveGrowthLayout(L)
    local sx = (L.sizeX or L.size or 32)
    local sy = (L.sizeY or L.size or sx)
    local anchor = (type(L.anchor) == "string" and L.anchor) or "TOPLEFT"
    local growth = (type(L.growth) == "string" and L.growth) or "RIGHT_DOWN"
    local primary, secondary = growth:match("^(%a+)_?(%a*)$")
    primary = primary or "RIGHT"
    local out = {
        sx = sx, sy = sy,
        spX = (L.spacingX or L.spacing or 4),
        spY = (L.spacingY or L.spacing or 4),
        anchor = anchor, primary = primary, secondary = secondary,
        pinPoint = anchor, flowAnchor = anchor, pinX = 0, pinY = 0,
        center = (primary == "CENTER"),
        verticalPrimary = (primary == "UP" or primary == "DOWN"),
    }
    if out.center then
        -- Vertical/horizontal component of the user's anchor point within an icon
        -- (TOP edge = 0 .. BOTTOM edge = sy), for the legacy icon-anchor fold.
        local vC = (anchor:find("TOP") and 0) or (anchor:find("BOTTOM") and sy) or sy / 2
        local hC = (anchor:find("LEFT") and 0) or (anchor:find("RIGHT") and sx) or sx / 2
        if secondary == "LEFT" or secondary == "RIGHT" then
            -- Vertical stack centred on the anchor; renders as a single column
            -- (native-flow limitation, same as UP/DOWN primary growth).
            out.verticalPrimary = true
            out.vName, out.hName = "Down", FLOW_NAME[secondary] or "Right"
            out.flowAnchor = (secondary == "LEFT") and "TOPRIGHT" or "TOPLEFT"
            out.pinPoint = (secondary == "LEFT") and "RIGHT" or "LEFT"
            out.pinX = (secondary == "LEFT") and (sx - hC) or -hC
            out.pinY = sy / 2 - vC
        else
            -- Horizontal row centred on the anchor; extra rows toward `secondary`.
            out.hName, out.vName = "Right", FLOW_NAME[secondary] or "Down"
            out.flowAnchor = (secondary == "UP") and "BOTTOMLEFT" or "TOPLEFT"
            out.pinPoint = (secondary == "UP") and "BOTTOM" or "TOP"
            out.pinX = sx / 2 - hC
            out.pinY = (secondary == "UP") and (vC - sy) or vC
        end
    elseif out.verticalPrimary then
        out.vName = FLOW_NAME[primary] or "Down"
        out.hName = FLOW_NAME[secondary] or "Right"
    else
        out.hName = FLOW_NAME[primary] or "Right"
        out.vName = FLOW_NAME[secondary] or "Down"
    end
    return out
end

local function applyContainerLayout(c, handle)
    local config = handle.config
    local L = config.layout or {}
    local G = resolveGrowthLayout(L)
    local sx = G.sx
    local spX = G.spX
    local scale = tonumber(L.scale) or 1
    local wrap = tonumber(L.wrap) or 0

    -- Row cap: vertical-primary = one per row (column); wrap>0 = N per row; else unlimited.
    -- HEADROOM: the flow (AnchorUtil.ApplyFlowLayout) wraps when the running row width
    -- exceeds rowWidth, measuring the button's ACTUAL width — which lands a fraction over
    -- our `sx` (pixel rounding + border inset). A tight +0.5 slack let that fraction wrap
    -- one icon early. Half an icon of headroom absorbs the rounding yet stays well under
    -- the (sx + spX) a whole extra icon would need — so exactly `wrap` icons fit per row.
    local headroom = sx * 0.5
    local rowWidth
    if G.verticalPrimary then
        rowWidth = sx + headroom
    elseif wrap and wrap >= 1 then
        rowWidth = wrap * sx + (wrap - 1) * spX + headroom
    end   -- nil -> math.huge (no wrap) inside SetAuraLayoutRowWidth

    pcall(function()
        c:SetScale(scale)
        -- Pin the container to the frame's anchor point + offsets. Directional
        -- growth: the grow-corner pins to the frame's matching point (SetPoint
        -- offsets live in the container's scaled space, matching the legacy rows
        -- whose offsets rode the scaled buttons). CENTER growth: the box's
        -- centre-of-edge pins instead (see resolveGrowthLayout).
        c:ClearAllPoints()
        c:SetPoint(G.pinPoint, handle.frame, G.anchor,
            (L.offsetX or 0) + G.pinX, (L.offsetY or 0) + G.pinY)
        c:SetAuraLayoutAnchorPoint(G.flowAnchor)
        if AnchorUtil and AnchorUtil.FlowDirection then
            local h = resolveEnum(AnchorUtil.FlowDirection, G.hName)
            local v = resolveEnum(AnchorUtil.FlowDirection, G.vName)
            if h ~= nil and v ~= nil then c:SetAuraLayoutGrowthDirection(h, v) end
        end
        c:SetAuraLayoutRowWidth(rowWidth)
    end)
end

-- Per-group layout options (stride/spacing). gapX stays 0: the flow advances its
-- cursor by width + elementSpacingX after EVERY element — including a group's
-- last — and then adds gapX before the next group (AnchorUtil.ApplyFlowLayout),
-- so any non-zero gapX renders group boundaries at spacing + gapX. The original
-- gapX = spacing DOUBLED the gap between filter blocks on multi-filter rows
-- (and between every button of the per-slot test rows) — live-reported. With
-- gapX = 0 groups still continue on the same row, uniformly spaced.
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
        gapX            = 0,
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
-- Each backend owns its OWN plain container: insecure CreateFrame is combat-legal for the
-- aura pipeline (taint.log-proven; the earlier freeze was unrelated secret-value compares,
-- since fixed). One container per consumer = one flow layout per row (independent
-- positioning) and a trivial recreate-on-structural-change teardown. The container is
-- STANDING: built once from config, then Blizzard drives it — no per-UNIT_AURA touches.
-- ============================================================
-- MISSING mode: gap between the container's pinned right edge and the clip window,
-- and the badge's inset from the container's TOPLEFT — the two cancel so the empty
-- state parks the badge exactly on the window. Also the extra cell width beyond the
-- badge, so the pushed badge clears the window with margin.
local MISSING_PAD = 2

local NativeBackend = {}
NativeBackend.__index = NativeBackend

function NativeBackend.new(handle)
    return setmetatable({ handle = handle }, NativeBackend)
end

function NativeBackend:isNativeSlots() return true end

-- Build order (proven live in combat on 68569 — do not reorder):
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
    -- error pcall can't catch. Every caller already gates this
    -- (Create / _rebuild / the regen handler); a stray path defers instead of dying.
    if InCombatLockdown() then handle:_deferRebuild(); return end

    -- OUR OWN plain per-consumer container, parented to the handle's anchor frame. Insecure
    -- creation is fine — taint.log proved the old combat freeze was unrelated secret-value
    -- compares (Config.lua SafeSetFont / Auras.lua legacy scan), both fixed — and this exact
    -- plain-create pattern is confirmed to run live in combat.
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
    AuraContainer.stats.builds = AuraContainer.stats.builds + 1
    local isOverlay = config.mode == "overlay"
    local isMissing = config.mode == "missing"
    if isOverlay then
        c:SetAllPoints(handle.frame)          -- overlay covers the host region
    elseif isMissing then
        -- LAYOUT-PUSH INVERSION (probe 32, live-confirmed 2026-07-10): pin the container
        -- just outside the clip window's LEFT edge. The container self-sizes to content
        -- (secret SetSize each layout pass — Blizzard_CustomAuraContainer.lua:738), so an
        -- empty group leaves the badge (anchored to the container's TOPLEFT below) parked
        -- inside the window; one blank button's cell pushes it fully out. The button
        -- itself always renders LEFT of the window -> clipped, and the container is
        -- mouse-dead so nothing floats over the unit frame.
        c:ClearAllPoints()
        c:SetPoint("TOPRIGHT", handle.frame, "TOPLEFT", -MISSING_PAD, 0)
        pcall(function() c:SetAuraLayoutAnchorPoint("TOPLEFT") end)
        pcall(function() if c.SetMouseClickEnabled then c:SetMouseClickEnabled(false) end end)
        pcall(function() if c.SetMouseMotionEnabled then c:SetMouseMotionEnabled(false) end end)
    else
        applyContainerLayout(c, handle)       -- row: anchor/growth/wrap/offset/scale -> native flow layout
    end
    -- TEST MODE (P5): the sample provider feeds any requested token identically, but
    -- test frames carry fabricated units — parse "player" so presence is guaranteed.
    local testMode = AuraContainer._testMode
    local unit = testMode and "player" or config.unit
    if type(unit) == "string" then pcall(function() c:SetUnit(unit) end) end

    -- Container-level aura processing policy (config.processingPolicy = { policy =
    -- "ProcessAura", options? }): stamps AuraUtil.ProcessAura's classification on every
    -- candidate BEFORE candidate filters run — required by the processedAuraType
    -- candidate filter (the native "all dispellable" classification). Enum member is
    -- resolved by NAME against the securecopy'd global so API drift degrades to no
    -- policy (and processedAuraType-filtered groups then show nothing) rather than
    -- erroring the build. Skipped in test mode (sample data carries no classification).
    if not testMode and config.processingPolicy and type(config.processingPolicy.policy) == "string" then
        local pol = resolveEnum(_G.CustomAuraContainerAuraProcessingPolicy, config.processingPolicy.policy)
        if pol ~= nil then
            local okPol, errPol = pcall(function() c:SetAuraProcessingPolicy(pol, config.processingPolicy.options) end)
            if not okPol then DF:DebugWarn(DBG, "SetAuraProcessingPolicy failed: %s", tostring(errPol)) end
        end
    end

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
    local groupLayout
    if isMissing then
        -- The cell IS the push distance: >= badge width + 2*spill guarantees the badge AND
        -- its animation spill clear the window entirely when the tracked buff is present.
        local bw = (config.badge and config.badge.w) or 24
        local bh = (config.badge and config.badge.h) or 24
        local sp = (config.badge and config.badge.spill) or 0
        groupLayout = { elementWidth = bw + 2 * sp + MISSING_PAD, elementHeight = bh }
    elseif not isOverlay then
        groupLayout = buildGroupLayout(config)
    end
    -- Native candidate filters (spell-ID include/exclude maps, dispel types, maxDuration,
    -- booleans) — evaluated Blizzard-side per group/slot. ⚠ Spell-ID maps only apply on
    -- units the player can assist (helpful) / attack (harmful) — a harmful spell-ID map
    -- on a friendly-frame consumer is silently inert (the Meorawr gate). Structural:
    -- changing the set is a Rebuild (consumers put it in their row signature).
    local candidateFilters = config.candidateFilters
    -- Native sort (rows only): config.sort = { method = "ExpirationOnly", direction? } holds
    -- enum MEMBER NAMES; resolve here against the securecopy'd globals so a renamed member
    -- degrades to Blizzard's default order rather than erroring the build. Structural:
    -- declared at AddAuraGroup (consumers carry it in their row signature).
    local sortMethod, sortDirection
    if not testMode and config.sort and type(config.sort.method) == "string" and _G.AuraContainerSortMethod then
        sortMethod = _G.AuraContainerSortMethod[config.sort.method]
        if sortMethod ~= nil and _G.AuraContainerSortDirection then
            sortDirection = _G.AuraContainerSortDirection[config.sort.direction or "Normal"]
        end
    end
    self.groupKeys = {}
    self.slotButtons = isOverlay and {} or nil   -- overlay: key -> native slot button (consumer styling)
    if testMode and not isOverlay and not isMissing then
        -- PER-SLOT TEST GROUPS (P5). Two hard-won facts drive this shape:
        --  * The flow lays buttons out by the container's own aura ordering, NOT
        --    by button creation order — indexing the curated paint/hover zones by
        --    creation order landed them on the wrong buttons (live-diagnosed
        --    twice: Lightning Shield mid-row, mismatched tooltips).
        --  * Groups render in DECLARATION order, so one group per preview slot
        --    (maxFrameCount = 1) pins slot k to layout position k determinately.
        --    Groups don't dedupe against each other, so every group shows exactly
        --    one sample — the row length always equals the test count, even when
        --    the sample set is short. Plain category filter only: the sample
        --    provider's matching is a bare-token check and its auras carry no
        --    raid flags / spell IDs / durations (§23 gotcha c).
        local category = (filters[1] and filters[1].f:find("HARMFUL")) and "HARMFUL" or "HELPFUL"
        filters = {}   -- the normal declaration loop below is skipped
        for k = 1, maxCount do
            local key = "dfTest" .. k
            local okGroup, err = pcall(function()
                c:AddAuraGroup(key, category, {
                    maxFrameCount = 1,
                    initializeFrame = handle:_makeInitializeFrame(handle._gen, k),
                    layout = groupLayout,   -- gapX = 0 (buildGroupLayout) = uniform spacing
                })
            end)
            if okGroup then
                self.groupKeys[#self.groupKeys + 1] = key
            else
                DF:DebugWarn(DBG, "test group failed: %s", tostring(err))
            end
        end
    end
    for i, rec in ipairs(filters) do
        local f = rec.f
        local cf = (not testMode) and (rec.candidateFilters or candidateFilters) or nil
        if AuraUtil and AuraUtil.IsValidFilterString and not AuraUtil.IsValidFilterString(f) then
            DF:DebugWarn(DBG, "filter rejected by IsValidFilterString: %s (group skipped)", tostring(f))
        else
            local key = rec.key or ("df" .. i)
            if isOverlay then
                local okSlot, btn = pcall(function()
                    return c:AddAuraSlot(key, f, { initializeFrame = initFn, candidateFilters = cf,
                                                   sortMethod = sortMethod, sortDirection = sortDirection })
                end)
                if okSlot and btn then
                    pcall(function() btn:SetAllPoints(handle.frame) end)
                    self.slotButtons[key] = btn
                elseif not okSlot then DF:DebugWarn(DBG, "AddAuraSlot failed: %s", tostring(btn)) end
            else
                local okGroup, err = pcall(function()
                    c:AddAuraGroup(key, f, { maxFrameCount = maxCount, initializeFrame = initFn,
                                             layout = groupLayout, candidateFilters = cf,
                                             sortMethod = sortMethod, sortDirection = sortDirection })
                end)
                if okGroup then
                    self.groupKeys[#self.groupKeys + 1] = key
                else
                    DF:DebugWarn(DBG, "AddAuraGroup failed: %s", tostring(err))
                end
            end
        end
    end

    -- SetEnabled LAST — after the groups/slots + filters are declared. This is what arms
    -- the parse + UNIT_AURA registration.
    -- TEST MODE: stay DISABLED until the provider bounce lands (the bounce enables
    -- us) — an enabled container parses the player's REAL auras for a tick first,
    -- creating buttons whose creation order no longer matches the sample set's
    -- display order once it arrives; paints and hover zones then land on the
    -- wrong buttons (live-diagnosed: Lightning Shield at slot 4, PoM tooltips).
    pcall(function() c:SetEnabled(config.enabled ~= false and not testMode) end)

    -- TEST MODE: every native build while the sample provider should be active
    -- queues the coalesced bounce — this container was born deaf to the switch.
    if testMode then AuraContainer._queueTestBounce() end

    -- MISSING mode: arm the push geometry — hook the badge onto the live container's
    -- TOPLEFT (+pad puts it exactly on the window while the group is empty) and show it.
    -- The badge's rect now derives from the container's SECRET size: render-side only,
    -- never read its position in Lua (no pixel-snap, no GetLeft) — §20c rules.
    if isMissing and handle.badge then
        -- Centre the badge in the (badge + 2*spill) window: the -MISSING_PAD container pin
        -- and the +MISSING_PAD badge inset still cancel to park it on the window when empty;
        -- the +spill / -spill centres it inside the enlarged window.
        local sp = (handle.config.badge and handle.config.badge.spill) or 0
        handle.badge:ClearAllPoints()
        if testMode then
            -- P5 preview: the container stays DISABLED all test session (the
            -- bounce skips missing mode) and a never-laid-out container has NO
            -- resolvable rect (its secret SetSize only runs while enabled) — a
            -- badge anchored to it renders NOTHING (live-caught). Park the
            -- badge on the WINDOW instead: that IS the "missing" position.
            handle.badge:SetPoint("TOPLEFT", handle.frame, "TOPLEFT", sp, -sp)
        else
            handle.badge:SetPoint("TOPLEFT", c, "TOPLEFT", MISSING_PAD + sp, -sp)
        end
        handle.badge:Show()
    end

    DF:Debug(DBG, "built (native) unit=%s mode=%s groups=%d",
        tostring(config.unit), tostring(config.mode or "row"), #filters)
end

function NativeBackend:setUnit(unit)
    -- Test mode parses "player" regardless of the frame's (fabricated) unit; the
    -- handle's config still tracks the live token for the rebuild back.
    if AuraContainer._testMode then return end
    local c = self.container
    if c and type(unit) == "string" then
        pcall(function() c:SetUnit(unit) end)
        -- ★ PARTITION KICK (same mechanism as applyLayout/refresh, live-confirmed
        -- 2026-07-09): the inbound SetUnit writes the token + MarkDirty(FullAuraRebuild)
        -- but cannot ARM the private-side dirty processor, so the retarget sits
        -- unprocessed — the container keeps DISPLAYING the old unit's last parse on a
        -- frame that now shows someone else (roster churn: stale AD bars/tints on the
        -- wrong player; the native-bound fill empties when the old aura instance dies,
        -- leaving a stuck empty rectangle). The Hide/Show bounce runs the intrinsic
        -- OnShow SECURE-side -> UpdateEventRegistrations + UpdateAllAuras from inside
        -- the partition -> re-registers events for the NEW unit + arms + processes.
        -- OOC only (Handle:SetUnit defers to regen in combat, but guard anyway; in
        -- combat the marked flags flush on the next combat aura event).
        if not InCombatLockdown() then
            pcall(function() c:Hide(); c:Show() end)
        end
    end
end

-- Hot-apply layout (anchor/growth/wrap/size/spacing/offset/scale) to the LIVE container.
-- Every underlying setter is a live mutator (MarkDirty only), so a slider drag re-lays
-- out without a rebuild. Row mode only; the overlay's SetAllPoints never changes.
-- Callers combat-gate this (ApplyStyle defers to regen in lockdown).
function NativeBackend:applyLayout()
    local c = self.container
    -- Overlay: SetAllPoints never changes. Missing: the push anchor + cell layout are
    -- the MECHANISM (set at build; badge-size changes are structural -> Rebuild) — a
    -- hot re-apply here would overwrite them with row semantics.
    if not c or self.handle.config.mode == "overlay" or self.handle.config.mode == "missing" then return end
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

-- The container is OURS (per-consumer): teardown is disable, drop its buttons, hide, release
-- the ref. The next build creates a fresh container
-- (topology is add-only — no RemoveAuraGroup/Slot — so recreate IS the sanctioned removal).
-- Callers gate teardown out of combat (Destroy/_rebuild defer to regen in lockdown).
function NativeBackend:teardown()
    local c = self.container
    if c then
        AuraContainer.stats.teardowns = AuraContainer.stats.teardowns + 1
        pcall(function() c:SetEnabled(false) end)
        if type(c.RemoveAllAuraFrames) == "function" then
            pcall(function() c:RemoveAllAuraFrames() end)
        end
        pcall(function() c:Hide() end)
    end
    self.container = nil
    self.slotButtons = nil   -- buttons die with the container; consumers re-fetch per drive
end

local Handle = {}
Handle.__index = Handle

-- Backend contract (layout half): the backend calls these to hand produced slots in and
-- to lay them out. The handle owns positioning/styling/lifecycle; the backend owns the
-- source object + slot production.
function Handle:_getConfig() return self.config end
function Handle:_getAnchorFrame() return self.frame end
function Handle:_slotCount()
    local mode = self.config.mode
    if mode == "overlay" or mode == "missing" then return 1 end
    -- Test mode: the preview honours the test panel's count slider (config.testMax),
    -- still capped by the row's own max — mirrors the legacy painter's min() chain.
    if AuraContainer._testMode and self.config.testMax then
        return math.min(self.config.testMax, self.config.max or self.config.testMax)
    end
    return self.config.max or 1
end
function Handle:_acceptSlot(slot, index)
    self.buttons[index] = slot                 -- cache first (mirror of the pre-split order)
    styleButton_regions(slot, self.config)     -- source-agnostic region creation/styling
end
function Handle:_bindNativeSlot(slot)
    bindNative(slot, self.config)              -- native setters (native slots only)
end
-- Countdown text for the test preview. The row's OWN duration formatter renders
-- it whenever one is configured — the same object the live native binding uses —
-- so format (Number/Short/Full), the colour-by-time buckets (|cff escapes) and
-- the hide-above-threshold blank band all mirror live exactly. Plain fallback
-- ("14s"/"10m") only when the row runs Blizzard's default formatting.
local function formatTestDuration(handle, rem)
    local durSpec = handle.config.style and handle.config.style.duration
    local f = durSpec and durSpec.formatter
    if f then
        local ok, s
        if f.FormatNumber then ok, s = pcall(f.FormatNumber, f, rem)
        elseif f.Format then ok, s = pcall(f.Format, f, rem) end
        if ok and type(s) == "string" then return s end
    end
    if rem >= 60 then return math.floor(rem / 60 + 0.5) .. "m" end
    local s = math.ceil(rem)
    return s > 0 and (s .. "s") or ""
end

-- TEST MODE paint (P5 hybrid): push DF's curated preview data onto the regions
-- styleButton_regions just built — the SAME regions the native binds would drive
-- live, so the preview is styling-true (borders, fonts, insets, swipe). Harmful
-- rows page through the debuff pool (dispel-typed edges), everything else the
-- buff pool. Regions are unbound in test mode, so their Shown state is OURS here.
function Handle:_paintTestSlot(slot, index)
    local recs = normalizeFilters(self.config.filter)
    local harmful = recs[1] and recs[1].f:find("HARMFUL")
    local td = DF.TestData
    -- config.testEntries carries per-container curated entries (the Aura
    -- Designer's placed indicators preview their own configured spell);
    -- config.testPool names a curated TestData pool for rows whose category
    -- filter alone would mispreview (the defensive row is HELPFUL but must show
    -- defensives, not raid buffs). Falls back to the category pools.
    local pool = self.config.testEntries
        or (td and ((self.config.testPool and td[self.config.testPool])
        or (harmful and td.debuffs or td.buffs)))
    if not pool or #pool == 0 then return end
    local e = pool[((index - 1) % #pool) + 1]
    -- Belt-and-braces: native hover must NEVER win in test mode (it tooltips the
    -- hidden SAMPLE aura). Re-asserted every paint pass, not just at creation.
    if slot.SetMouseMotionEnabled then pcall(function() slot:SetMouseMotionEnabled(false) end) end

    -- Validate the entry's spell ID up front (FAIL-CLOSED: kept only when the
    -- game POSITIVELY confirms the name) — it drives BOTH the icon and the
    -- tooltip below, so they can never disagree. Stale ID? Try resolving by
    -- NAME (cached per entry; the name-equality gate rejects override results).
    local sid
    if e.spellID and C_Spell and C_Spell.GetSpellName then
        local ok, nm = pcall(C_Spell.GetSpellName, e.spellID)
        if ok and nm == e.name then sid = e.spellID end
    end
    if not sid and C_Spell and C_Spell.GetSpellInfo and e._resolvedID ~= false then
        if e._resolvedID then
            sid = e._resolvedID
        else
            local ok, info = pcall(C_Spell.GetSpellInfo, e.name)
            if ok and type(info) == "table" and info.spellID and info.name == e.name then
                e._resolvedID = info.spellID
                sid = info.spellID
            else
                e._resolvedID = false   -- don't retry every paint
            end
        end
    end

    -- Adopt the player's SPEC OVERRIDE wholesale (Krathe's call): the preview
    -- shows the spell as this spec knows it — icon, name and tooltip move
    -- TOGETHER (a 12.1 Holy priest previews Holy Fire, not Shadow Word: Pain).
    -- GetSpellTexture resolves overrides anyway; resolving explicitly here keeps
    -- all three surfaces on the same spell instead of a mixed identity.
    local dispName = e.name
    if sid and C_Spell.GetOverrideSpell then
        local ok, oid = pcall(C_Spell.GetOverrideSpell, sid)
        if ok and type(oid) == "number" and oid ~= 0 and oid ~= sid then
            local ok2, onm = pcall(C_Spell.GetSpellName, oid)
            if ok2 and type(onm) == "string" and onm ~= "" then
                sid, dispName = oid, onm
            end
        end
    end

    local iconSpec = self.config.style and self.config.style.icon
    if slot.dfIcon and not (iconSpec and iconSpec.staticSpellID) then
        -- The GAME's icon for the validated spell (hand-maintained icon paths
        -- drift from the real art); the entry's hardcoded icon is the fallback.
        local tex = sid and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
        if tex or e.icon then slot.dfIcon:SetTexture(tex or e.icon) end
    end
    do
        -- Live countdown: stagger per slot so the row doesn't tick in unison; the
        -- shared test ticker (SetTestMode) counts the text down and loops timer +
        -- swipe at zero. Permanent auras (duration 0) show no timer.
        local d = e.duration or 0
        if d > 0 then
            local offset = (index * 3) % math.max(d - 1, 1)
            slot._dfTestDur = d
            slot._dfTestExpiry = GetTime() + (d - offset)
            if slot.dfCD and slot.dfCD.SetCooldown then
                slot.dfCD:SetCooldown(GetTime() - offset, d)
            end
            if slot.dfDur then slot.dfDur:SetText(formatTestDuration(self, d - offset)) end
        else
            slot._dfTestDur = nil
            if slot.dfDur then slot.dfDur:SetText("") end
        end
    end
    if slot.dfStack then slot.dfStack:SetText((e.stacks or 0) > 1 and tostring(e.stacks) or "") end
    if slot.dfBar then slot.dfBar:SetMinMaxValues(0, 1); slot.dfBar:SetValue(0.65) end
    if slot.dfName then slot.dfName:SetText(dispName or "") end
    -- Dispel ring: no native SetAuraBorder bind in test mode -> tint + show it
    -- ourselves from the game palette (the ring art/thickness were already styled).
    if slot.dfAuraBorder then
        local shown = false
        if e.debuffType and AuraUtil and AuraUtil.GetAuraBorderColor then
            shown = pcall(function()
                local c = AuraUtil.GetAuraBorderColor(e.debuffType)
                slot.dfAuraBorder:SetVertexColor(c:GetRGB())
            end)
        end
        slot.dfAuraBorder:SetShown(shown and true or false)
    end

    -- Hover tooltip (parity with the legacy test icons), showing the curated
    -- aura's name — the native tooltip path would show the hidden SAMPLE aura's
    -- random data. The hover frames live in OUR subtree and are positioned from
    -- OUR layout settings — NEVER from the button: a child created inside a
    -- native button inherits its forbidden aspects (no scripts/hover), and
    -- anchoring an insecure frame TO the button throws (both live-disproved;
    -- the throw silently aborted this paint and took the ring tint with it).
    -- LAST in the paint so any residual error can't take other art down.
    -- Index-keyed + handle-owned: rebuilds reposition instead of leaking;
    -- _teardownContainer hides the lot. Clicks pass through.
    if self.config.tooltips == true then
        self._testTips = self._testTips or {}
        local tip = self._testTips[index]
        if not tip then
            tip = CreateFrame("Frame", nil, self.frame)
            self._testTips[index] = tip
            tip:EnableMouse(true)
            if tip.SetMouseClickEnabled then tip:SetMouseClickEnabled(false) end
            tip:SetScript("OnEnter", function(s)
                if not GameTooltip then return end
                GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                -- Real spell tooltip when the pool entry carries a live spell ID.
                -- dontOverride (arg 4) is LOAD-BEARING: without it the tooltip
                -- resolves the player's SPEC OVERRIDE and renders a different
                -- spell (live-caught on a 12.1 priest: SW:P drew Holy Fire, PW:S
                -- drew Prayer of Mending — documented override behaviour, not a
                -- bug; Krathe's catch). The rendered title is still ground-truth
                -- checked; any residual mismatch falls back to the name tag.
                local shown = false
                if s._spellID and GameTooltip.SetSpellByID then
                    shown = pcall(GameTooltip.SetSpellByID, GameTooltip, s._spellID, nil, nil, true)
                    if shown then
                        local title = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
                        if GameTooltip:NumLines() == 0 or title ~= s._name then shown = false end
                    end
                end
                if not shown and s._name then
                    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")   -- reset any wrong render
                    GameTooltip:SetText(s._name, 1, 1, 1)
                end
                GameTooltip:Show()
            end)
            tip:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        end
        self:_positionTestTip(tip, index)
        tip:SetFrameLevel(self.frame:GetFrameLevel() + 60)   -- above the buttons for hover
        tip._name = dispName            -- override-resolved, matches the icon
        tip._spellID = sid              -- validated + override-resolved up top
        tip:Show()
    elseif self._testTips and self._testTips[index] then
        self._testTips[index]:Hide()
    end
end

-- Shared 1s ticker driving the preview countdowns (test mode only; started and
-- stopped by SetTestMode). Loops each timer + swipe at zero so the preview
-- animates indefinitely. Buttons die with their containers, so stale state
-- can't outlive a rebuild (handle.buttons is wiped on teardown).
function AuraContainer._startTestTicker()
    if AuraContainer._testTicker then return end
    AuraContainer._testTicker = C_Timer.NewTicker(1, function()
        local now = GetTime()
        for h in pairs(AuraContainer._handles or {}) do
            if not h._destroyed and h.buttons then
                for _, b in ipairs(h.buttons) do
                    if b._dfTestDur and b.dfDur then
                        local rem = (b._dfTestExpiry or 0) - now
                        if rem <= 0 then
                            rem = b._dfTestDur
                            b._dfTestExpiry = now + rem
                            if b.dfCD and b.dfCD.SetCooldown then
                                pcall(function() b.dfCD:SetCooldown(now, b._dfTestDur) end)
                            end
                        end
                        b.dfDur:SetText(formatTestDuration(h, rem))
                    end
                end
            end
        end
    end)
end

function AuraContainer._stopTestTicker()
    if AuraContainer._testTicker then
        AuraContainer._testTicker:Cancel()
        AuraContainer._testTicker = nil
    end
end

-- Place a test hover tip over button `index` from the layout SETTINGS (the same
-- vocabulary applyContainerLayout translates onto the native flow, so the zones
-- land on the rendered buttons; layoutRow is the reference math). Settings-derived
-- by necessity — the buttons' own rects are off-limits to insecure anchors.
function Handle:_positionTestTip(tip, index)
    local L = self.config.layout or {}
    local G = resolveGrowthLayout(L)
    local sx, sy, spX, spY = G.sx, G.sy, G.spX, G.spY
    local scale = tonumber(L.scale) or 1
    local n = math.max(self:_slotCount(), 1)
    -- Vertical-primary growth renders as a single column on the native flow.
    local wrap = G.verticalPrimary and 1 or (tonumber(L.wrap) or 0)
    if wrap < 1 then wrap = n end
    local idx = index - 1
    tip:SetSize(sx * scale, sy * scale)
    tip:ClearAllPoints()
    if G.center then
        -- Mirror the centre-pinned box (resolveGrowthLayout): the box's
        -- centre-of-edge sits at the user's anchor + pin offsets and fills from
        -- its corner — anchor each tip by its CENTRE at the icon's rendered centre.
        local x, y
        if G.verticalPrimary then
            -- Single centred column.
            local colH = n * sy + (n - 1) * spY
            x = (L.offsetX or 0) + (G.pinX + ((G.secondary == "LEFT") and -sx / 2 or sx / 2)) * scale
            y = (L.offsetY or 0) + (G.pinY + colH / 2 - idx * (sy + spY) - sy / 2) * scale
        else
            local col = idx % wrap
            local row = math.floor(idx / wrap)
            local m = math.min(wrap, n)
            local rowW = m * sx + (m - 1) * spX
            local rowDir = (G.secondary == "UP") and 1 or -1
            x = (L.offsetX or 0) + (G.pinX + col * (sx + spX) - rowW / 2 + sx / 2) * scale
            y = (L.offsetY or 0) + (G.pinY + rowDir * (row * (sy + spY) + sy / 2)) * scale
        end
        tip:SetPoint("CENTER", self.frame, G.anchor, x, y)
        return
    end
    -- Directional growth: replicate the flow from the anchor corner. The container
    -- itself is scaled; in handle.frame space each step and the element size render
    -- multiplied by scale. User offsets are container-anchor offsets in parent
    -- space (unscaled).
    local pAxis = AXIS[G.primary] or AXIS.RIGHT
    local sAxis = AXIS[G.secondary] or AXIS.DOWN
    local col = idx % wrap
    local row = math.floor(idx / wrap)
    local x = (L.offsetX or 0) + (pAxis.x * col + sAxis.x * row) * (sx + spX) * scale
    local y = (L.offsetY or 0) + (pAxis.y * col + sAxis.y * row) * (sy + spY) * scale
    tip:SetPoint(G.anchor, self.frame, G.anchor, x, y)
end
function Handle:_layoutSlots()
    -- NATIVE row mode = the container's own flow layout anchors the buttons (wired via
    -- applyContainerLayout at build; hot-applied via NativeBackend:applyLayout) — never
    -- hand-anchor those (SetPoint would fight the secure flow layout). PLAIN slots
    -- (a future non-native "slots" mode) would hand-anchor via layoutRow.
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
function Handle:_makeInitializeFrame(gen, fixedIndex)
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
            -- Tooltips stay OFF in test mode regardless of the setting: hover would
            -- show the underlying SAMPLE aura's real tooltip (random spellbook data),
            -- not the curated preview icon it appears to be. Motion is the ONE addon
            -- lever over the native aura tooltip (the tooltip is a forbidden object
            -- with a hardcoded anchor); it can't be toggled per-combat because the
            -- button's mouse state is secret + write-locked in combat (live-verified).
            if button.SetMouseMotionEnabled then
                button:SetMouseMotionEnabled(handle.config.tooltips == true and not AuraContainer._testMode)
            end
            -- MISSING mode: the button must render NOTHING — its only job is to occupy
            -- a layout cell so the container's width pushes the badge out of the clip
            -- window (probe 32). No regions, no native binds.
            if handle.config.mode ~= "missing" then
                handle:_acceptSlot(button, i)      -- size + regions (source-agnostic)
                if AuraContainer._testMode then
                    -- P5 hybrid preview: the sample provider drives presence and the
                    -- real flow drives geometry, but the sample auras' own data is
                    -- never shown — no native binds; paint the curated pool instead.
                    -- fixedIndex = the per-slot test group's position (creation order
                    -- is NOT layout order; the group key is) — stamped on the button
                    -- so ApplyStyle repaints the same entry.
                    button._dfTestIndex = fixedIndex or i
                    handle:_paintTestSlot(button, button._dfTestIndex)
                else
                    handle:_bindNativeSlot(button)     -- native inbound setters
                end
            end
        end)
        if not ok and not warnedRestyle then
            warnedRestyle = true
            DF:DebugWarn(DBG, "initializeFrame styling failed: %s", tostring(err))
        end
    end
end

function Handle:GetFrame() return self.frame end
-- OVERLAY mode only: the live native slot buttons, keyed by the filter record's key
-- (positional "df<i>" when unkeyed). Consumers decorate these directly (build DF art
-- on them, register native SetAuraBorder regions). EMPTY until a native build lands
-- (combat-deferred builds, fake/test backend) and INVALIDATED by every rebuild — never
-- cache the buttons across drives; re-fetch and key per-button state on the button itself.
function Handle:GetOverlaySlots()
    local b = self.backend
    return (b and b.slotButtons) or nil
end
-- MISSING mode only: the always-styled badge frame (icon/border are the consumer's).
-- Its visibility is engine-driven (shown only while a live container backs the push
-- geometry); consumers gate the WINDOW (GetFrame) for dead/offline/range guards.
function Handle:GetBadgeFrame() return self.badge end
-- MISSING mode only: hot-apply a badge/window size change. NOT structural — the
-- window + badge are plain DF frames and the cell rides the live SetAuraGroupLayout
-- mutator, so a size slider drag must not recreate containers (per-tick churn).
-- Callers invoke this OOC (the drives' version-gated blocks are combat-gated); the
-- OOC Hide/Show bounce arms the private-side processor so the re-lay applies now,
-- not one aura event late (same partition kick as applyLayout).
function Handle:SetBadgeSize(w, h)
    if self.config.mode ~= "missing" or not self.badge then return end
    local badge = self.config.badge or {}
    self.config.badge = badge
    if badge.w == w and badge.h == h then return end
    badge.w, badge.h = w, h
    local sp = badge.spill or 0
    self.frame:SetSize(w + 2 * sp, h + 2 * sp)
    self.badge:SetSize(w, h)
    local backend = self.backend
    local c = backend and backend.container
    if c and backend.groupKeys and c.SetAuraGroupLayout then
        local cellLayout = { elementWidth = w + 2 * sp + MISSING_PAD, elementHeight = h }
        for _, key in ipairs(backend.groupKeys) do
            pcall(function() c:SetAuraGroupLayout(key, cellLayout) end)
        end
        if not InCombatLockdown() then
            pcall(function() c:Hide(); c:Show() end)
        end
    end
end

-- Live-update the animation SPILL margin (px of transparent room the clip window keeps
-- around the badge so a border animation can extend OUTSIDE the icon). Grows the window +
-- re-centres the badge + grows the layout-push so the badge AND its spill still clear the
-- window when the buff is present (no leak onto buffed units). No teardown -> the running
-- animation is NOT restarted; the caller re-offsets the strip cell by -spill so the badge's
-- on-screen position is unchanged. The push mutator applies on the next aura event, which is
-- fine: the push only matters once the buff is present (the badge is hidden then anyway).
function Handle:SetBadgeSpill(sp)
    if self.config.mode ~= "missing" or not self.badge then return end
    sp = math.max(0, math.floor(sp or 0))
    local badge = self.config.badge or {}
    self.config.badge = badge
    if (badge.spill or 0) == sp then return end
    badge.spill = sp
    local bw, bh = badge.w or 24, badge.h or 24
    self.frame:SetSize(bw + 2 * sp, bh + 2 * sp)
    self.badge:ClearAllPoints()
    local backend = self.backend
    local c = backend and backend.container
    if c then
        self.badge:SetPoint("TOPLEFT", c, "TOPLEFT", MISSING_PAD + sp, -sp)
        if backend.groupKeys and c.SetAuraGroupLayout then
            local cellLayout = { elementWidth = bw + 2 * sp + MISSING_PAD, elementHeight = bh }
            for _, key in ipairs(backend.groupKeys) do
                pcall(function() c:SetAuraGroupLayout(key, cellLayout) end)
            end
        end
    else
        self.badge:SetPoint("TOPLEFT", self.frame, "TOPLEFT", sp, -sp)
    end
end
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
    -- hot-apply through the live SetAuraLayout*/SetAuraGroupLayout mutators instead; a
    -- future non-native "slots" mode would hand-anchor via layoutRow. styleButton_regions below still
    -- re-applies per-button SIZE, which the flow layout reads.
    local native = self.backend and self.backend:isNativeSlots()
    if native then
        if self.backend.applyLayout then self.backend:applyLayout() end
    elseif self.config.mode ~= "overlay" then
        layoutRow(self)
    end
    for i, b in ipairs(self.buttons) do
        local ok, err = pcall(function()
            styleButton_regions(b, self.config)
            if native then
                if AuraContainer._testMode then
                    -- TEST MODE: re-PAINT, never bind. Binding here was the P5
                    -- preview killer: any settings refresh re-ran this loop and
                    -- registered the native setters on the preview buttons, so
                    -- Blizzard instantly overwrote the curated icons with the
                    -- sample auras' random art and zero durations (static swipes)
                    -- — until the next rebuild repainted them (Krathe 2026-07-10).
                    -- _dfTestIndex = the button's per-slot group position (creation
                    -- order ≠ layout order).
                    self:_paintTestSlot(b, b._dfTestIndex or i)
                else
                    bindNative(b, self.config)
                end
            end
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
-- Structural rebuild. `config` REPLACES the handle's config WHOLESALE when given —
-- both bridge callers (buff/defensive) pass a COMPLETE freshly-built config. The
-- previous pairs()-merge could never CLEAR a key that went nil: a disabled
-- max-duration filter / sort / blacklist stayed declared on every later rebuild
-- (the "toggle does nothing until /reload" bug — candidateFilters survived OFF).
-- A caller with a genuine partial delta must merge into handle.config itself.
function Handle:Rebuild(config)
    if type(config) == "table" then
        self.config = config
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
    -- Stop each slot border's animation BEFORE dropping the slot refs. Slot
    -- borders are secretRect widgets whose OnUpdate motion driver is hosted on
    -- UIParent (the aura-button subtree disables OnUpdate through descendants),
    -- so it does NOT auto-hide when the container hides -- an un-stopped driver
    -- would keep ticking against the torn-down slot's textures. StopAnimation
    -- clears the OnUpdate + hides the driver; idempotent on borders that had no
    -- animation running. This is the single teardown chokepoint for winner
    -- change / de-config / rebuild / destroy (all route through here).
    if DF.Border then
        for _, slot in pairs(self.buttons) do
            if slot and slot.dfBorder then DF.Border:StopAnimation(slot.dfBorder) end
        end
    end
    wipe(self.buttons)
    self._slotCounter = 0   -- restart the lazy-batch index for the next build
    -- Test-mode hover tips are handle-owned (anchored over the dying buttons):
    -- hide the lot; a test build re-anchors/re-shows the ones it needs.
    if self._testTips then
        for _, t in pairs(self._testTips) do t:Hide() end
    end
    -- MISSING mode: with no container the push geometry is gone — park the badge
    -- hidden on the window (never claim "missing" without a live container).
    if self.badge then
        if DF.Border and self.badge.dfBorder then DF.Border:StopAnimation(self.badge.dfBorder) end
        self.badge:Hide()
        self.badge:ClearAllPoints()
        self.badge:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0)
    end
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
    AuraContainer.stats.defers = AuraContainer.stats.defers + 1
    self:_queueOp("rebuild")
end

-- Build via the (only) backend. Test mode uses the SAME native containers — the
-- sample data provider feeds them and initializeFrame paints the curated preview
-- (see AuraContainer.SetTestMode). The backend owns the container + slot
-- production; the handle owns styling/layout/lifecycle.
function Handle:_build()
    self.backend = NativeBackend.new(self)
    self.backend:build()
    self:_updateDynRefresh()   -- auto-bounce on target/focus/mouseover change
end

-- Test mode toggled -> rebuild (the build reads AuraContainer._testMode: test
-- transforms the filters/unit and swaps native binds for the curated paint).
-- Combat-guarded via _rebuild. Called by AuraContainer.SetTestMode per handle.
function Handle:OnTestModeChanged()
    self:_rebuild()
end

-- TEST MODE row cap (the test panel's Buffs/Debuffs count sliders). Structural —
-- maxFrameCount is declared at AddAuraGroup — so a change while the preview is
-- live rebuilds; outside test mode it's just recorded for the next enter.
function Handle:SetTestMax(n)
    n = tonumber(n)
    if self.config.testMax == n then return end
    self.config.testMax = n
    if AuraContainer._testMode then self:_rebuild() end
end

-- ============================================================
-- EDIT-MODE GUARD (shared)
-- Blizzard Edit Mode swaps the ENTIRE aura data layer: AURA_DATA_PROVIDER_SWITCH
-- installs the edit-mode sample provider at the AuraUtil level (AuraUtil.lua:19,
-- AuraUtilDataProvider replaces C_UnitAuras wholesale), so every container in the
-- game re-parses to random-icon fake auras. Per-container opt-out is IMPOSSIBLE —
-- deafening a container to the event was live-disproved (DF_AuraLab probe 34's
-- deaf twin still flipped: the swap is below the container layer). So while a
-- FOREIGN switch is active we HIDE the factory rows (plain anchor frames — the
-- drives' shown-caches keep them from re-showing), and restore + refresh when the
-- real provider returns. DF's own test mode (P5) sets _ownsProviderSwitch around
-- its switches so its curated preview is exempt from the guard.
local function ensureProviderWatch()
    if AuraContainer._providerWatch then return end
    local f = CreateFrame("Frame")
    AuraContainer._providerWatch = f
    f._hidden = setmetatable({}, { __mode = "k" })
    f._fakeActive = false
    f:RegisterEvent("AURA_DATA_PROVIDER_SWITCH")
    f:SetScript("OnEvent", function(self, _, useRealDataProvider)
        if AuraContainer._ownsProviderSwitch then
            self._fakeActive = false   -- P5's own preview manages its rows itself
            return
        end
        if useRealDataProvider then
            self._fakeActive = false
            for h in pairs(self._hidden) do
                self._hidden[h] = nil
                if not h._destroyed then
                    h:GetFrame():Show()
                    h:Refresh()        -- re-parse real data (Edit Mode exit is OOC)
                end
            end
        else
            self._fakeActive = true
            for h in pairs(AuraContainer._handles or {}) do
                if not h._destroyed and h:GetFrame():IsShown() then
                    self._hidden[h] = true
                    h:GetFrame():Hide()
                end
            end
        end
    end)
end

-- ============================================================
-- PUBLIC CONSTRUCTOR
-- ============================================================
-- Create an aura container. Returns a handle, or nil when unsupported (the caller
-- then keeps its existing pre-12.1 render path). Structural build is combat-guarded.
--
-- config = {
--   unit     = "raid5",
--   mode     = "row" | "overlay" | "missing",  -- default "row"; "missing" = layout-push
--                                              -- show-when-ABSENT badge (probe 32): pass
--                                              -- badge = { w, h }, filter + candidateFilters
--                                              -- select the tracked spell(s); style the frame
--                                              -- from GetBadgeFrame(); position GetFrame().
--   filter   = "HELPFUL" | { "HARMFUL|RAID_PLAYER_DISPELLABLE", ... }   -- category (now)
--              | { { filter = "HARMFUL", key = "magic", candidateFilters = {...} }, ... },
--                                              -- record form: per-group/slot key + candidate
--                                              -- filters (overlay consumers fetch their slot
--                                              -- buttons by key via GetOverlaySlots()).
--   processingPolicy = { policy = "ProcessAura", options? },  -- container-level; stamps
--                                              -- ProcessAura classification for the
--                                              -- processedAuraType candidate filter.
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
--                                                -- NOTE: can't be toggled per-combat — the button's mouse
--                                                -- state is secret + write-locked in combat (live-verified).
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
    ensureProviderWatch()              -- edit-mode guard (see above); one shared frame
    -- h.frame is the plain anchor frame DF positions; the backend parents its OWN
    -- CustomAuraContainer to it (one container per consumer).
    h.frame = CreateFrame("Frame", nil, parent)
    if cfg.mode == "missing" then
        -- MISSING mode (probe 32, live-confirmed 2026-07-10): h.frame is a CLIP WINDOW
        -- exactly the badge's size — the caller positions it. The backend pins its
        -- container just outside the window's left edge; an empty spellID-filtered
        -- group parks the badge inside the window ("missing" visible), one blank
        -- button's cell width pushes it out ("present" renders NOTHING). Zero reads.
        local bw = (cfg.badge and cfg.badge.w) or 24
        local bh = (cfg.badge and cfg.badge.h) or 24
        -- spill = transparent margin the clip window keeps AROUND the badge so a border
        -- ANIMATION can extend OUTSIDE the icon (missing state) without the window clipping
        -- it. The badge sits CENTRED; the layout-push (below) grows by 2*spill so the badge
        -- AND its spill still clear the window when the buff is present (no leak onto buffed
        -- units). Derived from the animation config by the caller (0 when no animation, so
        -- the non-animated case is byte-identical to before). Live-updated by SetBadgeSpill.
        local sp = (cfg.badge and cfg.badge.spill) or 0
        h.frame:SetClipsChildren(true)
        h.frame:SetSize(bw + 2 * sp, bh + 2 * sp)
        -- The badge is handle-owned (survives container rebuilds). It starts HIDDEN and
        -- parked on the window: with no live container we must not claim "missing"
        -- (false-negative until regen beats a false-positive). The backend shows it and
        -- re-anchors it to the container when a build lands; teardown re-parks it.
        h.badge = CreateFrame("Frame", nil, h.frame)
        h.badge:SetSize(bw, bh)
        h.badge:SetPoint("TOPLEFT", h.frame, "TOPLEFT", sp, -sp)
        h.badge:Hide()
    else
        -- Row/overlay: h.frame occupies the unit-frame rect (row layout anchors are
        -- relative to it; overlay covers it). Reposition: h:ClearAllPoints() + h:SetPoint(...).
        h.frame:SetAllPoints(parent)
    end
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
    -- Born during a foreign fake-data period (e.g. roster change while the user
    -- sits in Edit Mode): start hidden like the rest, restored on the real switch.
    local watch = AuraContainer._providerWatch
    if watch and watch._fakeActive then
        watch._hidden[h] = true
        h.frame:Hide()
    end
    return h
end

-- ============================================================
-- PREVIEW SLOTS (GUI surfaces that can't host a real container)
-- A plain frame styled + painted by the same styler/curated paint the
-- container slots use — the AD editor canvas renders through these so
-- its preview IS the factory's own rendering. No container, no aura
-- data: styling + the curated entry only.
-- ============================================================

function AuraContainer.StylePreviewSlot(slot, config)
    styleButton_regions(slot, config)
end

function AuraContainer.PaintPreviewSlot(slot, config, index)
    -- Duck-typed handle: the paint core only reads .config (and the duration
    -- formatter inside it).
    Handle._paintTestSlot({ config = config }, slot, index or 1)
end
