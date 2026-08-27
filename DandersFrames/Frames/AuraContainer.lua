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
-- PUBLIC API:  († = provided, no internal consumer yet -- see the note below)
--   DF.AuraContainer.IsSupported()       -- 12.1+ widget types exist (version gate)
--   DF.AuraContainer.HasSpellFilter() †  -- PTR-4: per-Spell-ID filter available
--   DF.AuraContainer.HasSort()        †  -- PTR-4: sort rule/direction available
--   local h = DF.AuraContainer:Create(parent, config)  -- nil if unsupported
--   h:SetUnit(unit) / h:SetShown(b) / h:Enable() / h:Disable()
--   h:ApplyStyle(style) -- in-place cosmetic restyle (no teardown)
--   h:ApplyTuning(tuning) -- in-place max/sort/candidateFilters mutate (no teardown;
--                            OOC-only, defers to regen in combat). REPLACES all three keys.
--   h:SetFilter(filter) † -- structural (rebuild)
--   h:Rebuild(config)      -- structural rebuild (max / region toggles / frozen opts); a
--                             table REPLACES the config wholesale (callers pass complete configs)
--   h:Refresh() -- force a re-scan (Hide/Show bounce; for dynamic-unit consumers)
--   h:GetFrame() -- the plain positioning frame DF anchors (SetPoint/SetSize on it)
--   h:Destroy()
--
-- † HasSpellFilter / HasSort / SetFilter have no internal caller. An earlier review
--   deferred the question to container Wave 1; W1 has since shipped, and it used
--   SetSort / _getConfig / _getAnchorFrame / _layoutSlots but not these three. They
--   stay as published API — capability probes are the natural shape for a later wave
--   to gate on, and they are one-liners over IsSupported(). Recorded here so the next
--   dead-code sweep gets the answer instead of re-raising the question.
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

-- ★ OWN-FRAME TEST PREVIEW, default ON. Test mode paints our own pooled frames
-- rather than declaring AuraGroups fed by the GLOBAL sample provider — see
-- Handle:_buildOwnPreview for why the engine route cannot be scoped to us.
-- Runtime A/B: /df debug ownpreview (AuraContainer.ToggleOwnPreview).
AuraContainer._ownTestPreview = true

-- One-time-per-process warning latches so a guarded failure (curve bug, border
-- taint, native dispel reject) logs ONCE, not once per button.
local warnedCurve, warnedBorder = false, false
-- ☠ ONE LATCH PER FAILURE, NOT PER SUBSYSTEM. warnedNativeDispel was shared between the
-- dispel BORDER bind and the dispel TEXT bind -- two different calls with two different
-- causes -- so whichever failed first silenced the other for the rest of the session.
-- Same defect as the warnedRestyle/warnedInitFrame split below; found by audit, not by a
-- report, because that is the nature of it: the second failure never spoke.
local warnedDispelBorder, warnedDispelText = false, false
-- (warnedMouse was a third latch here with no warning behind it — removed.)
local warnedRestyle, warnedRefresh = false, false
local warnedCreate = false
-- Slot subtrees the client turned FORBIDDEN under us -- see placeButton and the
-- StopAnimation loop in _teardownContainer.
local warnedLayout, warnedTeardownAnim = false, false
-- Slot BIRTH. Deliberately not warnedRestyle: sharing that latch let whichever of the
-- two failed first permanently silence the other. The consumer hook gets a third latch
-- for the same reason -- it is a separate call now, and a fault in one must not hide the
-- other.
local warnedInitFrame, warnedInitHook = false, false
-- Filter-string tuning rejected for a key the container does not have. Latched
-- because applyGroupTuning runs per frame per settings change; one line is enough
-- to name the offending consumer.
local warnedFilterString = false
-- ☠ THREE SITES, THREE LATCHES. One `warnedPandemic` covered the border apply, the
-- region add and the cover add -- so a single early failure in any one of them hid the
-- other two for the session. Same split, same reasoning, as the dispel pair above.
local warnedPandemicBorder, warnedPandemicRegion, warnedPandemicCover = false, false, false

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

-- PANDEMIC (refresh-window regions) landed in PTR 8 / build 69111, LATER than the rest
-- of the container surface — so unlike the two above it is NOT implied by IsSupported()
-- and needs its own probe.
--
-- ☠ It does NOT probe CustomAuraButtonSharedMixin.AddPandemicRegion, which is the obvious
-- check and is WRONG: Blizzard_AuraContainer declares `## UseSecureEnvironment: 1` and
-- loads its Lua into the secure environment, so that mixin table is not a global we can
-- read. The method exists on the button INSTANCE (it is explicitly addon-callable) but
-- there is no cheap instance here, and creating a container to find out is exactly the
-- combat-fatal probe IsSupported already has to tiptoe around.
--
-- So probe the pair of C APIs the window is computed from instead
-- (Blizzard_CustomAuraButton.lua:612 — UpdatePandemicWindow calls both). They are plain
-- C_UnitAuras entries, always readable, `SecretArguments = "AllowedWhenTainted"`, and
-- they shipped in the same build as the registrar. Their absence is the same "older than
-- PTR 8" answer with none of the caveats.
--
-- Consumers must gate the GUI on this, not just the render path. A region built on a
-- client without the registrar is created, never bound, and therefore never shown — the
-- feature would be silently absent with every control still live, which is precisely the
-- silent-capability-skip antipattern.
function AuraContainer.HasPandemic()
    return AuraContainer.IsSupported()
        and C_UnitAuras ~= nil
        and type(C_UnitAuras.GetRefreshExtendedDuration) == "function"
        and type(C_UnitAuras.GetAuraBaseDuration) == "function"
end

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

-- ============================================================
-- EDIT-MODE DEAFENING — the per-container opt-out
-- ============================================================
-- 12.1 build 68569 folded CustomAuraContainer onto the (new in that build)
-- ManagedAuraContainer, and with it our containers inherited Edit Mode's sample
-- data. On 68412 CustomAuraContainerPrivateMixin:ParseAllAuras called
-- C_UnitAuras.GetUnitAuras HARD-CODED, so custom containers were immune by
-- construction; now parsing runs through GetAuraSources(), which returns
-- AuraContainerAuraSourceLists.EditMode whenever the container's own flag is set.
-- Exactly ONE thing sets that flag — the container's own handler:
--
--     ManagedAuraContainerPrivateMixin:OnAuraDataProviderSwitch(useRealDataProvider)
--         self:SetUseEditModeSource(not useRealDataProvider)
--
-- The normal source reads C_UnitAuras DIRECTLY — it does NOT go through the
-- swapped AuraUtil provider — so a container that never HEARS the switch keeps
-- rendering live auras with Edit Mode open. Probe 33 already proved this from the
-- other side ("born-deaf containers": one built after a switch stays on the
-- previous source); the old "the swap is below the container layer" reading was
-- wrong for this build.
--
-- ☠ WHY IT GOES IN THE BUILD PATH: AURA_DATA_PROVIDER_SWITCH is a STATIC event —
-- registered once in AuraContainerPrivateMixin:OnLoad_Intrinsic, and
-- UpdateEventRegistrations only ever churns the DYNAMIC lists — so an unregister
-- sticks for the life of that frame. But only THAT frame: every structural
-- rebuild creates a brand new container, which registers it afresh. A one-shot
-- deafening expires silently, which is the likeliest reason probe 34 read as a
-- false negative. So it is re-applied on every build, at the creation site.
--
-- DF's own test mode RIDES this event (the provider bounce is how the curated
-- preview gets its data), so this is a TOGGLE, not a permanent unregister:
-- containers are born deaf, and are born hearing while _testMode is on.
local PROVIDER_EVENT = "AURA_DATA_PROVIDER_SWITCH"

-- AuraContainer._providerDeafOK: nil = not yet probed, true/false = the live
-- client's answer. The container is a forbidden-table object; base widget methods
-- ARE reachable (we already call SetScale / SetPoint / SetMouseClickEnabled on
-- it), but the event methods have to be proven at runtime rather than assumed.
-- The dangerous case is a SILENT refusal — the unregister does not error but the
-- event stays registered — which would leave every row showing sample icons, so
-- it is tested for explicitly. Anything short of a proven success keeps the old
-- hide-the-rows guard (see EDIT-MODE GUARD below) as the fallback.
local function setContainerProviderDeaf(c, deaf)
    if not c then return end

    -- ☠ ANSWERED IN GAME (68914): this is refused, and it is refused BY DESIGN.
    --   Frame:UnregisterEvent(): Function call not permitted on forbidden aspect
    --   'EventRegistrations' (execution tainted by 'DandersFrames')
    -- Enum.ForbiddenAspect.EventRegistrations is documented as "Restricts querying
    -- or modifying registered script events for this object", every Register* method
    -- ADDS it, and UnregisterEvent / UnregisterAllEvents / IsEventRegistered CHECK
    -- it. Blizzard's own OnLoad_Intrinsic registers AURA_DATA_PROVIDER_SWITCH from
    -- secure code, so the container carries the aspect from birth — there is no
    -- window before it, and no ordering trick. The REBIRTH FALLBACK below is the
    -- real mechanism; keep this only as a one-shot capability probe so a future
    -- build that relaxes the rule is noticed rather than assumed away.
    if AuraContainer._providerDeafOK ~= nil then return end   -- answered once, never retried

    if not deaf then
        -- Test mode wants the container to hear the bounce. Nothing to do: a fresh
        -- container is already registered by OnLoad, and re-registering would hit
        -- the same forbidden aspect anyway.
        return
    end

    -- ⚠ Written as an explicit branch, not `deaf and c.UnregisterEvent or
    -- c.RegisterEvent`: that idiom falls through to RegisterEvent when
    -- UnregisterEvent is nil, i.e. it would REGISTER the event while reporting
    -- that it had deafened the container. Exactly backwards.
    local why
    if not c.UnregisterEvent then
        AuraContainer._providerDeafOK, AuraContainer._providerDeafWhy =
            false, "UnregisterEvent missing on the container"
        return
    end
    local ok, err = pcall(c.UnregisterEvent, c, PROVIDER_EVENT)
    if not ok then
        AuraContainer._providerDeafOK = false
        AuraContainer._providerDeafWhy = "UnregisterEvent errored: " .. tostring(err)
        DF:DebugWarn(DBG, "provider deafening refused: %s", tostring(err))
        return
    end

    -- "It did not error" is NOT proof it took — a silent refusal is the case that
    -- error" is NOT proof it took — a silent refusal is the case that matters.
    local okQ, stillRegistered = pcall(c.IsEventRegistered, c, PROVIDER_EVENT)
    if not okQ then
        AuraContainer._providerDeafOK, why = true, "accepted; IsEventRegistered unavailable (UNVERIFIED)"
    elseif stillRegistered then
        AuraContainer._providerDeafOK, why = false, "silently refused — still registered after UnregisterEvent"
    else
        AuraContainer._providerDeafOK, why = true, "confirmed deaf"
    end
    AuraContainer._providerDeafWhy = why
    DF:Debug(DBG, "provider deafening: %s", why)
end

-- ============================================================
-- PER-CONTAINER SAMPLE SOURCE — capability probe
-- ============================================================
-- ☠ PROBE ONLY. It records what the live client allows and changes NO behaviour.
-- Do not wire anything to the result until it has come back true in game.
--
-- The prize, if it works: SetUseEditModeSource is the ONE thing that decides
-- whether a container reads Edit Mode's sample auras --
--
--     ManagedAuraContainerPrivateMixin:OnAuraDataProviderSwitch(useRealDataProvider)
--         self:SetUseEditModeSource(not useRealDataProvider)
--
-- -- and it is per CONTAINER. Today test mode reaches it the only way we know
-- works: C_UnitAuras.SwitchAuraDataProvider, which is GLOBAL, so it drags every
-- other aura container in the client onto sample data with us. That is what makes
-- Blizzard's buff and debuff frames misbehave under Unlock Mode, and in the other
-- direction what costs Blizzard's Edit Mode preview its sample auras when we reset
-- the provider to rescue our own rows. Calling the setter ourselves would remove the
-- cause of both instead of living with them.
--
-- ⚠ Hiding Blizzard's frames for the duration was tried and REVERTED: they come back
-- on sample data for another 5-10s after test mode exits, so the churn was only moved
-- to a worse moment, and the cost was a real risk of stranding them hidden.
--
-- Why it is probed rather than assumed, either way:
--   * It is a PRIVATE-mixin method, not a base widget method. Base methods are
--     reachable on these forbidden-table objects (we already call SetScale,
--     SetPoint, SetMouseClickEnabled); private ones are usually not exposed to
--     addon code at all, so the field may simply be nil.
--   * The container carries a forbidden aspect from birth, and we have already been
--     refused on this exact object: UnregisterEvent gives "Function call not
--     permitted on forbidden aspect 'EventRegistrations'" (proven in game, 68914).
--     A setter that swings the container's data source is at least as likely gated.
--
-- ⚠ Only ever called while test mode is ON, and only with `true`. That is the value
-- the global switch is about to force on this container anyway, so a SUCCESS is a
-- no-op rather than a behaviour change we did not intend — and a refusal is the
-- answer we came for. Never probe with `false`: on a container that had legitimately
-- heard the switch that WOULD change what renders.
function AuraContainer._probeEditModeSource(c)
    if AuraContainer._editSourceOK ~= nil then return end   -- answered once, never retried
    if not c or not AuraContainer._testMode then return end

    if not c.SetUseEditModeSource then
        AuraContainer._editSourceOK = false
        AuraContainer._editSourceWhy = "SetUseEditModeSource not exposed on the container (private mixin)"
        DF:Debug(DBG, "per-container sample source: %s", AuraContainer._editSourceWhy)
        return
    end

    local ok, err = pcall(c.SetUseEditModeSource, c, true)
    if not ok then
        AuraContainer._editSourceOK = false
        AuraContainer._editSourceWhy = "refused: " .. tostring(err)
        DF:DebugWarn(DBG, "per-container sample source refused: %s", tostring(err))
        return
    end

    -- Accepted without erroring. ⚠ NOT the same as "it took" — the forbidden-aspect
    -- refusals we have seen are loud, but a silent no-op is the case that would
    -- mislead us into ripping out a working workaround. There is no public getter to
    -- confirm with, so this is recorded as promising-but-unconfirmed and wants a
    -- visual check (do our rows fill with sample icons WITHOUT the global bounce?)
    -- before anything depends on it.
    AuraContainer._editSourceOK = true
    AuraContainer._editSourceWhy = "accepted (UNCONFIRMED — no getter; verify rows fill without the global switch)"
    DF:Debug(DBG, "per-container sample source: %s", AuraContainer._editSourceWhy)
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
        -- TEST HANDLES ONLY, matching rebuildAll. "Built DISABLED" above is the
        -- other half of this pair, and only a container built while _testMode was
        -- on is disabled (build()'s SetEnabled folds in `not testMode`). Once
        -- rebuildAll stopped rebuilding live handles they were no longer disabled
        -- either, so an unscoped loop issued a pointless setEnabled+refresh on
        -- every live container at test entry — refresh() is a Hide/Show bounce
        -- that re-arms a full aura parse, so it was not free.
        for h in pairs(AuraContainer._handles or {}) do
            if not h._destroyed and h._testFrame and h.backend and h.config
               and h.config.enabled ~= false and h.config.mode ~= "missing" then
                if h.backend.setEnabled then pcall(function() h.backend:setEnabled(true) end) end
                if h.backend.refresh then pcall(function() h.backend:refresh() end) end
            end
        end
    end)
end

-- ☠ Parent-driven handles are rebuilt BY THEIR PARENT, never directly. A gate link's
-- rebuild makes a fresh slot host and re-fires onHost, which recreates everything below
-- it; driving the inner link here as well would race that and strand a duplicate.
-- ☠ FILE SCOPE, not inside SetTestMode. The regen flush (Handle:_registerRegen) consults
-- this too, and when it was a SetTestMode-local that reference silently resolved to a nil
-- GLOBAL — the surrounding pcall ate the call error and the whole deferred rebuild op
-- became a no-op for every handle.
local function skipNested(h)
    return h and h.config and h.config.parentDrivenVisibility
end

function AuraContainer.SetTestMode(on)
    on = on and true or false
    if (AuraContainer._testMode or false) == on then return end
    AuraContainer._testMode = on
    DF:Debug(DBG, "SetTestMode -> %s", tostring(on))

    -- TEST HANDLES ONLY. A container has to be REBUILT across a test transition
    -- because the two shapes declare different groups and groups can never be
    -- removed: test mode skips the real filter loop entirely (build(),
    -- `filters = {}`) and declares per-slot dfTest<k> groups (engine route) or
    -- nothing at all (own-frame preview), so neither shape can be reached from
    -- the other in place.
    --
    -- But that only ever applied to the handles that RENDER the preview. Live
    -- frames are hidden for the whole session by SetTestModeStateDrivers, so
    -- rebuilding them into test shape and back rendered nothing either way.
    --
    -- ☠ DO NOT re-justify this with "live containers are built deaf". They are
    -- NOT. setContainerProviderDeaf (top of this file) is a one-shot CAPABILITY
    -- PROBE that no-ops after its first call -- UnregisterEvent on the container
    -- is refused by design (ForbiddenAspect.EventRegistrations, answered in game
    -- on 68914). Every container hears AURA_DATA_PROVIDER_SWITCH, so a live
    -- handle left standing does follow the bounce onto the sample provider.
    -- It is HIDDEN, so that is invisible -- with one pre-existing exception:
    -- the [combat] state driver reveals live frames the instant combat starts
    -- (see TestMode.lua's note), and those rows then show sample auras. That
    -- edge was already wrong before this change (it showed curated TEST paint on
    -- live frames instead), so this neither introduces nor fixes it. Unverified
    -- in game; if it matters, the fix is to re-point live handles on reveal, not
    -- to rebuild every one of them on both transitions.
    --
    -- ⚠ It is NOT true that the entry pass can be dropped altogether -- that was
    -- the first read of the trace and it is wrong. The test frame pool is created
    -- once (testFramePoolInitialized) and its frames are only HIDDEN on exit, so
    -- from the SECOND entry onward the test handles already exist here and do
    -- need the rebuild. On the very first entry this loop legitimately does
    -- nothing: the pool is built after SetTestMode returns and those handles are
    -- born in test shape (build() reads _testMode itself).
    -- ☠ LOAD-BEARING INVARIANT, and it is not local to this function: build() picks
    -- its SHAPE from the GLOBAL AuraContainer._testMode (the `local testMode` read,
    -- and SetEnabled's `not testMode`), while the rebuild below is keyed on the
    -- PER-HANDLE flag. They must agree. A handle built while _testMode is on but
    -- whose _testFrame is false would be born test-shaped and never rebuilt out of
    -- it — groups can never be removed, so that container is stuck showing curated
    -- paint on a live frame forever. What guarantees they agree is that NO live
    -- handle is ever built during test mode, enforced by the UseFactoryFor* gates
    -- in Features/Auras.lua, Frames/Icons.lua and AuraDesigner (each excludes
    -- DF.testMode/raidTestMode). Before this became conditional the unconditional
    -- rebuild made the invariant unnecessary. The asymmetry is what makes it worth
    -- naming: a false NEGATIVE silently corrupts what is on screen, a false
    -- POSITIVE only costs one extra rebuild.
    -- (Parent-driven handles are skipped here too — see skipNested at file scope.)
    local function rebuildAll()
        if AuraContainer._handles then
            for h in pairs(AuraContainer._handles) do
                if not h._destroyed and h._testFrame and not skipNested(h) then
                    pcall(function() h:OnTestModeChanged() end)
                end
            end
        end
    end

    if on then
        AuraContainer._ownsProviderSwitch = true
        rebuildAll()
        -- ★ Own-frame preview never switches the global provider (see
        -- Handle:_buildOwnPreview), so there is nothing to bounce and no other
        -- addon's containers are touched. The builds above painted themselves.
        if not AuraContainer._ownTestPreview then
            AuraContainer._queueTestBounce()
        end
        -- No ticker start here: countdowns arm natively per slot (armTestDuration),
        -- and only a slot that FAILS to arm starts the fallback ticker.
    else
        AuraContainer._stopTestTicker()
        -- ☠ The reset runs REGARDLESS of the current toggle state. Own-preview may
        -- have been switched on mid-session while the engine route already held the
        -- provider, and leaving it on the sample source strands every container in
        -- the client on fake auras. _ownsProviderSwitch records that we took it;
        -- resetting when we did not is harmless (it is the real provider either way).
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
-- ★ CANONICAL FILTER STRINGS — a free parse win, and the reason is engine-side.
-- ManagedAuraContainerPrivateMixin:RebuildAuraParseFilters groups every group and slot by
-- filter string and queries each DISTINCT string once, and Blizzard's own comment is
-- explicit that the match is textual, not semantic: "We don't go to the lengths of
-- supporting equivalent strings with different token ordering." So "HELPFUL|PLAYER" and
-- "PLAYER|HELPFUL" are two full scans of the same data.
--
-- Emitting one canonical spelling everywhere makes equivalent filters share a batch. This
-- is the one saving that cannot be had per consumer -- it needs GLOBAL string discipline,
-- so it goes at the chokepoint every record passes through rather than in each builder.
--
-- Sort is by BARE token, with a token's negation immediately after it, so "!X" can never
-- drift away from "X". Duplicate tokens collapse. Memoised on the input string: the same
-- handful of strings recur on every rebuild across every frame.
-- ⚠ Order-independence is Blizzard's model (AuraUtil tokenises on "|" and space into a
-- set). If a filter ever behaves differently after this, suspect order-sensitivity here
-- first.
local filterCanonCache = {}
local function canonicalFilter(s)
    if type(s) ~= "string" or s == "" then return s end
    local hit = filterCanonCache[s]
    if hit ~= nil then return hit end
    local toks, seen = {}, {}
    for tok in s:gmatch("[^|%s]+") do
        if not seen[tok] then seen[tok] = true; toks[#toks + 1] = tok end
    end
    table.sort(toks, function(a, b)
        local an, bn = a:byte(1) == 33, b:byte(1) == 33          -- 33 = "!"
        local ab = an and a:sub(2) or a
        local bb = bn and b:sub(2) or b
        if ab ~= bb then return ab < bb end
        return (not an) and bn                                    -- bare before its negation
    end)
    local out = table.concat(toks, "|")
    filterCanonCache[s] = out
    return out
end

local function normalizeFilters(filter)
    local out = {}
    if type(filter) == "string" then
        out[1] = { f = canonicalFilter(filter) }
    elseif type(filter) == "table" then
        for _, f in ipairs(filter) do
            if type(f) == "string" then
                out[#out + 1] = { f = canonicalFilter(f) }
            elseif type(f) == "table" and type(f.filter) == "string" then
                -- onInit: a consumer secure-init hook (overlay dispel carriers) run
                -- INSIDE initializeFrame so its regions are created in secure context
                -- (SetAuraBorder rejects textures created in the tainted style pass —
                -- children of the secret aura button are access-constrained, cab.lua:15).
                -- style: per-record button overrides (scale / badge). See applyRecordStyle
                -- — a group whose membership IS the predicate can be styled unconditionally.
                out[#out + 1] = { f = canonicalFilter(f.filter), key = f.key, candidateFilters = f.candidateFilters,
                                  onInit = f.onInit, style = f.style }
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

-- Shared TUNING derivation — build() declares these at AddAuraGroup/AddAuraSlot;
-- applyGroupTuning() re-pushes them through the live SetAuraGroup* mutators. ONE
-- derivation so the config -> native mapping can't fork between the two paths
-- (max is likewise shared via Handle:_slotCount).
-- config.sort = { method = "ExpirationOnly", direction? } holds enum MEMBER NAMES;
-- resolve against the securecopy'd globals so a renamed member degrades to
-- Blizzard's default order rather than erroring.
local function deriveSort(config)
    local sortMethod, sortDirection
    if config.sort and type(config.sort.method) == "string" and _G.AuraContainerSortMethod then
        sortMethod = _G.AuraContainerSortMethod[config.sort.method]
        if sortMethod ~= nil and _G.AuraContainerSortDirection then
            sortDirection = _G.AuraContainerSortDirection[config.sort.direction or "Normal"]
        end
    end
    return sortMethod, sortDirection
end

-- ============================================================
-- HELPER GATE (Power Infusion helper) -- THE PUSH CHOKEPOINT
-- ============================================================
-- ☠ WHY THE GATE LIVES HERE AND NOWHERE ELSE.
-- Every engine write of candidate filters funnels through ONE of TWO lanes:
--   * group/overlay/row containers: recordCandidateFilters below, reached from `_build`
--     (declaring groups) and `applyGroupTuning` (pushing the cfByKey map).
--   * SLOT handles (placed icons/squares/bars): SlotHandle:_cf(), the slot lane's twin,
--     which every slot-path push reads instead of the raw `_lastCandidateFilters` stash.
-- Nothing reaches the engine except through one of the two. (The `cfOf` closure and the
-- diagnostic dump are debug-only readers and never reach the engine.) The slot lane exists
-- because AcquireSlot bypasses this funnel entirely -- without it the same placed indicator
-- was gated when built out of combat (the Create fallback) and ungated when built in it.
--
-- Gating HERE rather than in stored config is the whole design:
--   * Stored config always carries the LIVE map, so no signature ever lies and the Factory
--     needs no knowledge of gate state.
--   * A rebuild produces a fresh config that is EXACTLY AS GATED as the old one, because
--     gating happens after config, on the way out.
--   * There is therefore nothing to clobber and no race to keep winning. The first design
--     (swap the live map, re-assert after every rebuild) was a race against every rebuild
--     path anyone might add later; this removes the thing being clobbered instead.
--
-- ☠ AND IT DISSOLVES THE INTENT-VS-REALITY SPLIT. There is no second copy of the truth: the
-- engine value is DERIVED from this switch by every pusher, on every push. Edge detection
-- becomes an optimisation of WHEN to broadcast, never a record of what containers hold, so a
-- spent edge cannot strand reality -- the next flush of any kind re-derives from the switch.
--
-- The dead map is a populated set matching nothing, never an empty table: an empty include
-- set reads as "no selection", which the engine is free to treat as "everything passes".
local HELPER_GATE_DEAD_CF = { includeSpellIDs = { [1] = true } }
local helperGateDark = false

-- ☠ OWNERSHIP: `config.dfGate`. The gate must only ever darken our own effects. The first cut
-- asked "does this container watch the spell we care about", which also caught a USER'S
-- effect on the same spell -- darkened by a feature they never enabled, for a reason nothing
-- on screen explains. Harmless while the helper watched one throwaway buff; unacceptable once
-- it watches sixty real cooldowns.
--
-- The mark is a plain flag on the container config, stamped by whoever built it. It says
-- nothing about content, so it cannot be confused with a spell, and a user's effect cannot
-- acquire it by accident.
--
-- ⛔ AN EARLIER CUT PUT A SYNTHETIC SPELL ID IN THE HELPER'S OWN FILTER DATA AND READ THAT.
-- It worked, and it was wrong for three reasons that only surfaced once it was written down:
--   * A fake id in real data TRAVELS. Profiles are exported, imported and decoded, and nobody
--     reading one a year from now could explain what 1999000060 was.
--   * It could not mark everything. buildDebuffGroupConfig carries no config-wide candidate
--     filters at all, so a debuff group was unmarkable; and a filter group's resolved map is
--     CACHED AND SHARED between every consumer of the same filter, so stamping an id into one
--     would have leaked the mark into unrelated effects.
--   * It rode into the sound path as if it were a spell, so helperSoundMapFor had to filter it
--     back out -- a fake registration that could never fire, inflating the count while nothing
--     real was listening.
-- Danders ruled the field name and we chose the route (each caller stamps the returned config,
-- rather than six builders taking a new parameter). See Factory.lua's `stampGate`.
--
-- ⚠ NO "ARMED" FLAG. There was one, and it only ever caused a bug: ownership is a property of
-- the CONFIG, not of whether anything has flipped a switch yet. Gating is decided below by
-- (gate shut OR role excluded), so with neither true nothing darkens regardless -- which is
-- what the flag was for. Its only real effect was that role exclusion silently did nothing
-- until an unrelated gate command happened to arm it first.

-- ═══ ROLE EXCLUSION ═══
-- Never mark someone you would not infuse. The cooldown gate is ONE switch for everyone; this
-- is PER UNIT, and it works at the same chokepoint because the container config carries
-- `unit` (buildBorderConfig et al, Factory.lua:1028).
--
-- ⚠ FAILS OPEN, DELIBERATELY. DF:GetUnitRole answers nil or "NONE" when a group has no
-- assigned roles -- common in hand-made groups, never in queued content. Everyone then reads
-- as "no role" and nothing is excluded. Marking a tank you did not want is a much smaller
-- failure than silently hiding the signal on the damage dealers you did.
--
-- ⚠ AND IT CAN BE STALE. UnitGroupRolesAssigned is the ASSIGNED role, not the spec's role:
-- switching spec mid-dungeon does not update it until the group re-forms (watched 2026-08-23).
-- Unfixable for other players -- their spec is secret in 12.1.
local helperExcludedRoles = nil   -- e.g. { TANK = true, HEALER = true }

-- ⭐ THE PLAYER'S OWN ROLE COMES FROM THEIR SPEC, EVERYONE ELSE'S FROM THE GROUP.
-- `UnitGroupRolesAssigned` reports the role the group was FORMED with, so it goes stale after a
-- mid-run respec until the group re-forms -- a healer who switched to damage still reads HEALER
-- and the helper would keep skipping them.
--
-- ☠ FIXED HERE, NOT IN DF:GetUnitRole. Danders' ruling, 2026-08-23: that function serves every
-- consumer in the addon, and reordering its preference would change behaviour everywhere to fix
-- a case that only bites the local player after a respec without a regroup. Wide blast radius,
-- narrow win, and not this feature's change to make. So the helper prefers the better answer for
-- the one unit it can get it for, and leaves the shared function alone. If the flip is ever
-- right addon-wide it should be its own change with its own testing, not a passenger on ours.
local function helperUnitRole(unit)
    if UnitIsUnit and UnitIsUnit(unit, "player") and GetSpecialization and GetSpecializationRole then
        local spec = GetSpecialization()
        local role = spec and GetSpecializationRole(spec)
        if role and role ~= "NONE" then return role end
    end
    return DF.GetUnitRole and DF:GetUnitRole(unit)
end

local function helperRoleExcluded(unit)
    if not (helperExcludedRoles and unit) then return false end
    local role = helperUnitRole(unit)
    if not role or role == "NONE" then return false end   -- fail open
    return helperExcludedRoles[role] == true
end

-- Shared with the SOUND path (Factory): sound registers per unit and never passes the
-- container funnel, so role exclusion must be answerable from outside it -- or a cue plays
-- for a unit nothing marks.
function AuraContainer.IsHelperRoleExcluded(unit) return helperRoleExcluded(unit) end

-- A record's candidateFilters REPLACES the config-wide set for that group/slot
-- (the dispel overlay's per-type slots) — see normalizeFilters.
local function recordCandidateFilters(rec, config)
    local cf = rec.candidateFilters or config.candidateFilters
    -- Two independent reasons to go dark: the cooldown switch (everyone at once) and this
    -- unit's role (this frame only). Both resolve to the same dead map.
    -- Ownership is read off the CONFIG, never off the map -- see `config.dfGate` above. That is
    -- why a record carrying its own candidateFilters is still gated correctly: the mark and the
    -- content are separate things now.
    if config.dfGate and (helperGateDark or helperRoleExcluded(config.unit)) then
        return HELPER_GATE_DEAD_CF
    end
    return cf
end

-- IDENTITY-GATE EXPOSURE (12.1, live-confirmed 2026-07-17, widened 2026-07-18).
-- include/excludeSpellIDs are only evaluated inside
-- CanApplyIdentityCandidateFilters, which for HELPFUL auras requires
-- UnitCanAssist("player", unit) — and a FAILED gate SKIPS the checks entirely
-- (fail-open: every helpful aura passes). UnitCanAssist flips FALSE for a
-- CROSS-FACTION group member outside instanced content — and for a duel
-- partner — so an "only these spells" pool silently degrades to "every buff"
-- (food buffs flooding the defensive row; caught live via a cross-faction
-- party + duel, DF_AuraLab probe 38). A pool whose SELECTION rides identity
-- filtering renders garbage under a failed gate, so the handle hides itself
-- until the gate holds again (see Handle:_applyIdentityGate). Vulnerable =
-- HELPFUL pool with ANY of:
--   * includeSpellIDs — REGARDLESS of tokens. "HELPFUL|PLAYER" is NOT immune
--     (field-caught 2026-07-18): the PLAYER token still narrows the pool at
--     the query level, but the spell-ID whitelist is skipped — so a My Buffs
--     slot degrades to "anything I cast", and buffs persisting from instanced
--     content (Fortitude on a cross-faction ally) render in it. The earlier
--     "PLAYER pools are immune" note was a probe artifact (no other
--     player-cast aura on the test target, so the failed-open pool was empty).
--   * excludeSpellIDs — "everything except X" degrades to "everything",
--     re-showing buffs the user chose to hide; gated for a uniform blackout
--     on non-assistable units (Krathe's call, 2026-07-18).
--   * a spell-CATEGORY token (BIG_DEFENSIVE / EXTERNAL_DEFENSIVE, negated or
--     not — the defensive row's empty-selection fallback): the category is
--     spell-identity-derived, same fail-open family.
-- NOT gated: genuinely unfiltered pools (plain HELPFUL, no selection) — their
-- data is CORRECT on a non-assistable unit (probe: the ALL row showed the real
-- buffs), so hiding them would hide truth, not garbage. HARMFUL pools are out
-- of scope (their gate is UnitCanAttack — owned by the debuff-filtering work).
local GATED_CATEGORY_TOKENS = { BIG_DEFENSIVE = true, EXTERNAL_DEFENSIVE = true }

-- ★ THE NeverSecret EXEMPTION, and why it is EXCLUDE-ONLY. The engine's identity gate has
-- a per-AURA escape hatch (Blizzard_AuraContainerUtil, checked FIRST and it wins outright):
-- a spell whose C_Secrets.GetSpellAuraSecrecy is NeverSecret stays filterable on any unit —
-- that is how Blizzard itself drops Exhaustion/Sated from friendly frames.
--   * An excludeSpellIDs pool whose ENTIRE set is NeverSecret can never change behaviour
--     on lost trust: the excluded auras keep hitting the exclude test (their exemption
--     holds the gate open for THEM), and every other aura was never excluded anyway. Same
--     output in both trust states ⇒ genuinely not vulnerable ⇒ parking it would hide
--     correct data for nothing. This also honours the 2026-07-18 uniform-blackout call
--     better than the blackout did: the buffs the user chose to hide STAY hidden.
--   * ☠ An includeSpellIDs pool can NEVER take this exemption, whatever its map holds.
--     The leak is not the mapped spells — it is every OTHER secret helpful aura on the
--     unit skipping the include test and pouring in. The exemption is a property of the
--     AURA being tested, not of our map. Do not "symmetrise" this.
-- Secrecy is a static DB2 property, so one session cache; pcall + guards because the
-- C_Secrets surface is 12.x-only and a probe failure must degrade to "vulnerable"
-- (park too much, never leak).
local auraSecrecyCache
local function excludeSetAllNeverSecret(map)
    local CS = C_Secrets
    if not (CS and CS.GetSpellAuraSecrecy and Enum and Enum.SecrecyLevel) then return false end
    local never = Enum.SecrecyLevel.NeverSecret
    auraSecrecyCache = auraSecrecyCache or {}
    for id in pairs(map) do
        local v = auraSecrecyCache[id]
        if v == nil then
            local ok, s = pcall(CS.GetSpellAuraSecrecy, id)
            v = (ok and s == never) or false
            auraSecrecyCache[id] = v
        end
        if not v then return false end
    end
    return true
end

local function filterVulnerableToIdentityGate(filterString, cf)
    if type(filterString) ~= "string" or not filterString:find("HELPFUL") then return false end
    if cf and cf.includeSpellIDs then return true end
    if cf and cf.excludeSpellIDs and not excludeSetAllNeverSecret(cf.excludeSpellIDs) then
        return true
    end
    for token in filterString:gmatch("[^|%s]+") do
        if GATED_CATEGORY_TOKENS[(token:gsub("^!", ""))] then return true end
    end
    return false
end

-- SOURCE-RELATIVE pools are the ones that can FAIL OPEN on who cast an aura: the
-- PLAYER token ("HELPFUL|PLAYER" = only-my-buffs). For a unit that isn't in your
-- visible world (a same-faction party member in a DIFFERENT instance) the engine
-- can't attribute a caster, so "mine" passes every caster's aura. Spell-ID
-- sub-filters are source-INDEPENDENT and keep working, so only-my-buffs breaks in
-- isolation while UnitCanAssist stays TRUE — which is why the assist gate never
-- catches it. Gated on UnitIsVisible (see _applyIdentityGate): the instance-scoped
-- signal, true for a same-instance member far outside 40yd range, false only across
-- instances/phases (field-verified 3-case probe 2026-07-23).
--
-- ☠ isFromPlayerOrPlayerPet USED TO COUNT HERE AND MUST NOT. It was added on the
-- reading that the field meant "cast by ME", which made it look like a second flavour
-- of only-my-buffs. It does not — it means "the caster is A PLAYER", Blizzard's own
-- consumer names the parameter `casterIsAPlayer`, and the correction is written up in
-- the friendly-debuff-filtering notes.
-- ★ On the corrected reading it CANNOT fail open. Blizzard_AuraContainerUtil applies
-- it as an equality test — `auraData.isFromPlayerOrPlayerPet ~= cf.isFromPlayerOrPlayerPet
-- → reject` — and that test sits OUTSIDE the CanApplyIdentityCandidateFilters block,
-- which wraps only includeSpellIDs/excludeSpellIDs. So it keeps being applied on units
-- where spell-ID filtering is dead, and if the caster is unattributable the aura's own
-- field cannot equal the requested value, so the aura is REJECTED. It fails CLOSED: it
-- can hide too much, never leak.
-- ⇒ Gating it hid a row that was filtering perfectly well — a false trigger, and on the
-- Non-Player Debuffs category it would have blanked the row on any phased or
-- out-of-instance unit for no reason. The gate should fire where something actually
-- fails open (Krathe, 2026-08-13).
-- ⚠ Reasoned from Blizzard's shipped source, not measured. If a source-only pool is ever
-- seen leaking on a non-visible unit, this is the line to revisit first.
-- `_cf` is accepted and ignored ON PURPOSE — callers still hand over the
-- candidateFilters, and the underscore is there so the next reader sees the omission
-- as a decision rather than an oversight to fix.
-- ═══ RETIRED 2026-08-15: the four-boolean debuff park (RecordIdentityGated) ═══
--
-- It parked records asserting isBossAura / isBossOrRoleAura / isRoleAura / isPriorityAura
-- whenever unit trust was lost. Removed because the engine never skips those filters, so
-- there was no failure for it to prevent — only rows it could empty by mistake, which is
-- what it did (dispel overlay lit with no debuff icon under it, two testers on 5.1.3).
--
-- The three findings that settled it, all from the shipped client
-- (Blizzard_AuraContainer/Blizzard_AuraContainerUtil.lua):
--   1. In DoesAuraPassCandidateFilters, ONLY `includeSpellIDs` and `excludeSpellIDs` sit
--      inside the `if CanApplyIdentityCandidateFilters(...)` block. All four booleans —
--      and isFromPlayerOrPlayerPet — are evaluated after it, unconditionally.
--   2. The categorisation cannot be poisoned by lost identity: the ENGINE evaluates
--      AuraUtil.IsRoleAura (which reads auraData.isTank/isHealer/isDPSRoleAura, not
--      spellId) and IsPriorityDebuff (a securecallfunction with the real ID). It is our
--      Lua that cannot read spellId, not Blizzard's.
--   3. Even under the one assumption source cannot settle — that those auraData fields
--      might be unpopulated for an untrusted unit — each is applied as an EQUALITY test,
--      so `nil ~= true` rejects and `nil ~= false` rejects. Both directions fail CLOSED.
--      There is no direction in which they leak, therefore none in which parking helps.
--
-- ⚠ We inherited the belief from a peer, which marks the identical four "identity-gated".
-- Another 12.1 raid-frame implementation, arrived at independently, parks the opposite
-- side: HELPFUL records carrying spell-ID filters, and never gates harmful at all. That is
-- the keying the API supports, and it is what gatedGroupKeys carries now.
-- ☠ HARMFUL must never take a TRANSIENT park: for a harmful aura the engine skips spell-ID
-- filters when you CAN assist, so on a friendly they are permanently dead, not
-- intermittently — parking on that would park forever.
--
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- ⚠ HISTORY, kept because it is the reason to distrust a "one-character fix". The park
-- first tested `~= nil` rather than `== true`, and `false ~= nil` is true — so the dedup
-- subtractions BuildDirectDebuffFilters stamps onto every token record (isBossOrRoleAura
-- = false etc.) counted as gated, and losing trust emptied the ENTIRE debuff row. That was
-- corrected to `== true` on 2026-08-14 and the row stopped blanking, which read as a fix
-- and was really a mitigation: the predicate was still wrong, just less often. Both
-- Danders and I wrote that one-liner independently the same day and neither of us went on
-- to ask whether the four keys belonged there at all. A change that makes the symptom go
-- away is the easiest place to stop looking.

local function filterSourceRelative(filterString, _cf)
    if type(filterString) == "string" then
        for token in filterString:gmatch("[^|%s]+") do
            if (token:gsub("^!", "")) == "PLAYER" then return true end
        end
    end
    return false
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

-- ★★★ THE PER-BUTTON LEVEL LADDER — ONE TABLE, because it used to be TWO PLACES and
-- they drifted the moment one of them was renumbered.
--
-- Every value is an offset from the BUTTON. Nothing outside the button competes with
-- these; they only have to be ordered among themselves and to clear the border.
--
--     0  icon art (on the button itself)
--     1  cooldown swipe (dfCD — parented to the button, not a holder)
--     2  PANDEMIC_TINT    a wash over the icon: must sit UNDER the information
--     3  BORDER           DF.Border, passed EXPLICITLY (see below)
--     4  DISPEL_RING      the dispel-type ring traces the icon edge, over the border
--     5  DURATION         duration text / spell name / DISPEL_SYMBOL
--     6  STACK            top-most text
--     7  PANDEMIC_BORDER  a ring tracing the edge, so it must clear everything
--
-- ⚠ DISPEL_SYMBOL DELIBERATELY SHARES RUNG 5 with the duration text rather than taking
-- its own. The ladder is depth-limited (see the budget below) and the two are the only
-- pair with no ordering requirement between them. Where they overlap — a centred
-- duration text under a centred glyph — draw order falls to creation order, and the
-- symbol holder is created after the duration holder in this same pass, so the glyph
-- still lands on top exactly as it did when it had its own rung.
--
-- ☠☠ HOW THIS BROKE, so it is not repeated. The 2026-08-07 z-order squash collapsed
-- this ladder from 12/13/13/14/15 to 1/2/3/4/5 and dropped the icon border to
-- DF.Border's shared default of +2 — but `Features/Pandemic.lua` computed its own
-- absolute levels (9 for TINT, 15 for BORDER) against the OLD numbers and was not
-- touched. Two consequences, both shipped:
--   * the dispel ring sat at +1 UNDER a +2 border and was invisible (Krathe, 2026-08-08);
--   * the pandemic TINT at +9 rose ABOVE the whole 1-5 ladder, washing over the timer
--     and stack count again — the exact regression 2026-08-05 had already fixed.
-- ⇒ **Pandemic.lua now reads THIS table.** Do not reintroduce a second set of numbers.
--
-- ☠ BORDER IS PASSED EXPLICITLY, never left to DF.Border's default. The default is +2
-- and is documented as wrong for any parent that stacks things over its own rect —
-- which is exactly what these holders do. Leaving it default is what buried the ring,
-- and it also leaves no room BELOW the border for the tint.
--
-- ☠☠ THE BUDGET, AND WHY THIS LADDER CANNOT SIMPLY GROW. Measured from the CONTAINER:
-- container +0, button +2, so the holders occupy container +4..+9 and a row is **9
-- levels thick**. `AuraDesigner/Factory.ALERT_ROW_LIFT` lifts an alert clear of a whole
-- row, so it must exceed that — and an indicator PLUS its alert has to stay inside one
-- user-facing band, which are 20 apart. 10 + 9 = 19 fits, with one level of slack.
-- ⇒ **Adding a rung here costs two levels of that budget and breaks it at 21.** If a new
-- region needs a level, share an existing rung (as DISPEL_SYMBOL does) or re-derive
-- ALERT_ROW_LIFT and the band spacing together. Confirm with `/df debug zorder`.
DF.AuraButtonLevels = {
    PANDEMIC_TINT   = 2,
    BORDER          = 3,
    DISPEL_RING     = 4,
    DURATION        = 5,
    DISPEL_SYMBOL   = 5,   -- shares DURATION; see the note above
    STACK           = 6,
    PANDEMIC_BORDER = 7,
}
local LEVELS = DF.AuraButtonLevels

-- Shared duration-bar STYLING, applied to BOTH bar shapes (fill and strip): fill
-- texture, orientation (fill-only — a strip is horizontal by definition, so the
-- gate lives here to keep the fill path's call order byte-identical), reverse-fill,
-- background colour/texture child, fill colour. GEOMETRY stays per-shape at the
-- call sites (fill = SetAllPoints, strip = relative edge anchors). dr/dg/db2/da are
-- the caller's colour fallback (fill's legacy white vs the strip's legacy green).
local function styleBarShared(slot, sb, barSpec, dr, dg, db2, da)
    if barSpec.texture and DF.SafeSetStatusBarTexture then
        DF:SafeSetStatusBarTexture(sb, barSpec.texture)
    end
    if barSpec.fill and barSpec.orientation and sb.SetOrientation then
        sb:SetOrientation(barSpec.orientation)
        -- Rotate the fill texture with a VERTICAL bar (the DF health-bar convention —
        -- SetRotatesTexture(isVertical)) so a DIRECTIONAL fill like the DF/Classic colour
        -- ramp runs ALONG the drain, not sideways across the width. Set explicitly both ways
        -- so a bar flipped back to horizontal clears it.
        DF:ApplyBarFillOrientation(sb, barSpec.orientation == "VERTICAL")
    end
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
    -- Curve colour modes: the ramp IMAGE carries the colour, so the fill must stay
    -- untinted — SetStatusBarColor multiplies the texture, and anything but white
    -- would muddy the ramp. (BuildDurationBarSpec sets .curve when it swapped the
    -- texture for a ramp; the configured .color is left alone so switching back to
    -- Static restores it without a round trip through the GUI.)
    if barSpec.curve then
        sb:SetStatusBarColor(1, 1, 1, 1)
    else
        sb:SetStatusBarColor(readColor(barSpec.color, dr, dg, db2, da))
    end
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
    -- ★ THE REGION HOST — everything this function creates hangs off `host`, never `slot`.
    --
    -- For a CONTAINER button there is no host and this resolves to the button itself, so
    -- every line below is byte-identical to what it always did. For a collapsed SLOT
    -- (AcquireSlot) it is the DF-owned frame stood up pre-seal by makeSlotLevelHost, and
    -- that indirection is what gives a slot per-indicator ALPHA back:
    --
    --   * The aura button carries DenyTaintedAccessWhenAurasAreSecret, applied by
    --     ApplyAccessRestrictions to the auraFrame ALONE (a single AddAccessRestrictions
    --     call — unlike forbidden aspects, which the source says propagate through the
    --     parent chain). So a DF-created child frame is NOT restricted and a tainted
    --     SetAlpha on it is legal, which the button itself refuses.
    --   * Blizzard's inbound setters accept it. ValidateInboundScriptObject requires only
    --     that a registered region be "a direct child or indirect descendent of owner"
    --     (RegionUtil.IsDescendantOf) — one level deeper still passes. Already proven in
    --     the field by dfAuraBorder (on dfDispelHolder) and dfDur (on dfDurHolder).
    --
    -- ⚠ CREATION-TIME ONLY. InitializeInboundScriptObject stamps ForbiddenAspect
    -- ChangeParent on every region it registers, so a region CANNOT be reparented after
    -- its native bind. The parent has to be right the first time — which is why this is a
    -- host at creation rather than a reparent pass.
    local host = slot.dfLevelHost or slot
    -- Overlay = a presence box (tint + border + native dispel only); the icon and all
    -- icon-content regions (cooldown/duration/stacks/bar/spellName) are ROW-only.
    local isRow = config.mode ~= "overlay"
    local sx = config.layout and (config.layout.sizeX or config.layout.size) or 32
    local sy = config.layout and (config.layout.sizeY or config.layout.size) or sx
    if isRow then slot:SetSize(sx, sy) end   -- overlay is SetAllPoints(frame) in _build

    -- Native tooltip placement + combat-hide (68914+): plain AuraButtonSharedMixin
    -- state, read at hover time (SetOwner anchor; the ShouldShowTooltip combat gate)
    -- — NOT creation-frozen and NOT a bind, so this cosmetic pass keeps it current
    -- on init and on every restyle. Guarded: only native container buttons carry
    -- the mixin (test/fake slots and overlay carriers don't). The spec's point is
    -- always one of the mixin's valid names (SetTooltipAnchorPoint asserts).
    local tt = style.tooltip
    if tt and slot.SetTooltipAnchorPoint and slot.SetHideTooltipInCombat then
        slot:SetTooltipAnchorPoint(tt.point, tt.x, tt.y)
        slot:SetHideTooltipInCombat(tt.hideInCombat == true)
    end

    -- OVERLAY tint / ROW icon. Static icon (known spell) is set here (source-agnostic —
    -- it's also the fake backend's icon mechanism); the native SetIcon bind is in bindNative.
    if config.mode == "overlay" then
        local ov = style.overlay
        -- ORDER KEY for stacked frame tints (AD multi-tint). Several tint containers
        -- cover the SAME region at the SAME frame level — the cover band is one level
        -- wide, with the attached absorb directly above it (#1027), so there is no room
        -- for a frame-level ladder. Frames at equal level have no guaranteed draw order,
        -- so creation order cannot arbitrate: field-reported as the lower-priority colour
        -- staying on top while both buffs were up. The draw-layer SUBLEVEL is the ordering
        -- key that does not need headroom — higher priority gets a higher sublevel.
        -- Re-applied on every style pass, so a priority edit reorders without a rebuild.
        local subLvl = ov and ov.sublevel
        if ov and ov.tintColor then
            if not slot.dfTint then
                slot.dfTint = host:CreateTexture(nil, "OVERLAY")
                slot.dfTint:SetAllPoints(host)
            end
            if subLvl then slot.dfTint:SetDrawLayer("OVERLAY", subLvl) end
            slot.dfTint:SetColorTexture(readColor(ov.tintColor))
        end
        -- ★ PANDEMIC COVER — the SECOND colour, on the SAME BUTTON as the base above.
        --
        -- ☠ SAME BUTTON IS THE WHOLE POINT. The first build made this a second CONTAINER
        -- drawing over the first, which cost a frame level; the background and border bands
        -- have none spare, so the feature could not reach them. Two regions under ONE button
        -- need no level at all: they are siblings of one parent, so the draw-layer sublevel
        -- orders them reliably (sublevel orders WITHIN a frame — it was useless across
        -- frames, which is what the earlier attempt got wrong).
        --
        -- The two gates stay independent and both stay engine-owned: the slot's own secret
        -- show/hide gates the BASE (buff present), and AddPandemicRegion in bindNative gates
        -- THIS ONE (inside the refresh window). Nothing in Lua combines them.
        --
        -- ☠ CREATE-ONCE, so the pandemic colour's ON/OFF must stay STRUCTURAL: a region can
        -- only be created inside initializeFrame (secure), never from a tainted ApplyStyle,
        -- so enabling it has to hand over a fresh button. The COLOUR itself restyles live.
        if ov and ov.tintPandemicColor then
            if not slot.dfTintPandemic then
                slot.dfTintPandemic = host:CreateTexture(nil, "OVERLAY")
                slot.dfTintPandemic:SetAllPoints(host)
            end
            slot.dfTintPandemic:SetDrawLayer("OVERLAY", math.min((subLvl or 0) + 1, 7))
            -- ☠ THE BLEND COMES FROM THE BASE TINT, NOT FROM THE PICKER. tintColor's
            -- fourth component IS the mode-derived blend (Factory hands over
            -- { r, g, b, blend }), while tintPandemicColor is the raw picker colour whose
            -- alpha defaults to 1. Passing that straight through made the pandemic window
            -- render FULLY OPAQUE over a base washing at, say, 20% -- the second colour
            -- ignored the Blend slider entirely. The healthFill twin below already reuses
            -- its base's alpha; this is the same rule, and taking it from the base rather
            -- than re-deriving it is what stops the two drifting. (Review, PR #236 B6.)
            local pr, pg, pb = readColor(ov.tintPandemicColor)
            local _, _, _, blend = readColor(ov.tintColor)
            slot.dfTintPandemic:SetColorTexture(pr, pg, pb)
            slot.dfTintPandemic:SetAlpha(blend or 1)
        end
        -- (Removed 2026-08-04) FILLED HEALTH MIRROR. It was a StatusBar parented under
        -- the slot, fed the secret health percent per health tick. Aura frames carry
        -- Enum.ScriptObjectAccessRestriction.DenyTaintedAccessWhenAurasAreSecret, so
        -- every one of those writes was refused in game -- the bar never moved and
        -- covered the health bar. Superseded by HEALTH FILL COVER below, which needs
        -- no writes at all.

        -- HEALTH FILL COVER — the working replacement for the StatusBar mirror above.
        --
        -- ☠ The mirror could never work. Aura frames carry
        -- Enum.ScriptObjectAccessRestriction.DenyTaintedAccessWhenAurasAreSecret
        -- (Blizzard_AuraContainerShared.lua:102), applied to every frame the provider
        -- creates. That denies ALL tainted writes while auras are secret -- so a
        -- StatusBar parented under the slot cannot be driven from our update path at
        -- any point, by any route. Field-confirmed: "health mirror bar forbidden" for
        -- every unit, and the bar rendered at its default, covering the health bar.
        --
        -- This needs no writes at all. A plain texture anchored to the REAL bar's fill
        -- texture inherits that texture's rect, and the fill rect is already driven by
        -- the bar's value -- so it tracks health exactly, with no per-tick work, no
        -- feed, and nothing read. Visibility still rides the slot's secret show/hide,
        -- because the texture is a child of the slot. Anchor-derived geometry is the
        -- one geometry route that stays legal here (button rects are secret; anchors
        -- are not).
        --
        -- Re-anchored on EVERY style pass, not just creation: the frame's health
        -- texture can be swapped from the settings panel, which replaces the fill
        -- region and would stale a create-once anchor.
        local hf = ov and ov.healthFill
        if hf and hf.clampTo then
            if not slot.dfHealthFill then
                slot.dfHealthFill = host:CreateTexture(nil, "OVERLAY")
            end
            local t = slot.dfHealthFill
            if subLvl then t:SetDrawLayer("OVERLAY", subLvl) end
            t:ClearAllPoints()
            t:SetAllPoints(hf.clampTo)
            local fr, fg, fb = readColor(hf.color)
            if hf.texture then
                DF:SafeSetTexture(t, hf.texture)
                t:SetVertexColor(fr, fg, fb)
            else
                t:SetColorTexture(fr, fg, fb)
            end
            t:SetAlpha(hf.alpha or 1)
            -- The pandemic twin of the fill cover: same anchor, same texture, second
            -- colour, one sublevel up. See the PANDEMIC COVER note above the tint.
            if hf.pandemicColor then
                if not slot.dfHealthFillPandemic then
                    slot.dfHealthFillPandemic = host:CreateTexture(nil, "OVERLAY")
                end
                local pt = slot.dfHealthFillPandemic
                pt:SetDrawLayer("OVERLAY", math.min((subLvl or 0) + 1, 7))
                pt:ClearAllPoints()
                pt:SetAllPoints(hf.clampTo)
                local pr, pg, pb = readColor(hf.pandemicColor)
                if hf.texture then
                    DF:SafeSetTexture(pt, hf.texture)
                    pt:SetVertexColor(pr, pg, pb)
                else
                    pt:SetColorTexture(pr, pg, pb)
                end
                pt:SetAlpha(hf.alpha or 1)
            end
        end
        -- MIRROR HOST — a plain child frame of the slot handed back to the consumer
        -- (the Aura Designer name/health text colour-by-cover). The consumer parents
        -- Text-Designer mirror FontStrings to it: the host contributes ONLY the slot's
        -- secret visibility chain (aura present -> host visible -> covers render); the
        -- mirrors position themselves by anchoring to the real FontStrings. onHost fires
        -- every style pass (create + ApplyStyle + Blizzard re-init) so the consumer's
        -- EnableMirrors registration is always current. ADDITIVE: only the AD text
        -- consumer sets it; tintColor/healthFill and the #205 rows are untouched.
        local mh = ov and ov.mirrorHost
        if mh then
            if not slot.dfMirrorHost then
                slot.dfMirrorHost = CreateFrame("Frame", nil, host)
                slot.dfMirrorHost:SetAllPoints(host)
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
        -- ⚠ squareSpec's PRESENCE means "this slot is a square"; squareSpec.show says
        -- whether its fill is painted. The two are deliberately separate: a text-only
        -- square (AD "Hide Icon") must still suppress the icon path below, or it renders
        -- as the spell icon instead. Keep the icon guard on presence, not on show.
        local squareSpec = style.square
        if squareSpec then
            if squareSpec.show == false then
                -- Text-only square: no fill, but the slot stays a square. Hide rather than
                -- paint transparent so a slot recycled from a visible square clears.
                if slot.dfSquare then slot.dfSquare:Hide() end
            else
                if not slot.dfSquare then
                    slot.dfSquare = host:CreateTexture(nil, "BACKGROUND")
                end
                local inset = squareSpec.inset or 0
                slot.dfSquare:ClearAllPoints()
                slot.dfSquare:SetPoint("TOPLEFT", inset, -inset)
                slot.dfSquare:SetPoint("BOTTOMRIGHT", -inset, inset)
                slot.dfSquare:SetColorTexture(readColor(squareSpec.color))
                slot.dfSquare:Show()
            end
        end
        local iconSpec = style.icon
        if not squareSpec and (iconSpec == nil or iconSpec.show ~= false) then
            if not slot.dfIcon then
                slot.dfIcon = host:CreateTexture(nil, "BACKGROUND")
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
            -- ☠ frameLevelOffset is EXPLICIT. DF.Border's default (+2) is documented as
            -- wrong for a parent that stacks frames over its own rect, and that is what
            -- the holder ladder does — the default buried the dispel ring and left no
            -- room beneath the border for the pandemic tint. See DF.AuraButtonLevels.
            local ok, w = pcall(function()
                return DF.Border:New(host, {
                    solidOnly = true,
                    secretRect = true,
                    frameLevelOffset = LEVELS.BORDER,
                })
            end)
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
                    -- pp: the border renders inside the container's SetScale(scale)
                    -- subtree — Apply must snap thickness in that space, not
                    -- UIParent's (spec.renderScale, Border:SnapThickness). Factory
                    -- pre-built specs already carry it (their art insets must
                    -- agree); the db-path specs built just above get it here.
                    if spec.renderScale == nil then
                        spec.renderScale = tonumber(config.layout and config.layout.scale) or 1
                    end
                    DF.Border:Apply(slot.dfBorder, spec)
                end
            end)
            -- ★ PANDEMIC BORDER TWIN — the ring in its second colour, on THIS button.
            -- Same shape as the pandemic covers above: a sibling under one parent, so we
            -- own both levels and the order is ours. It sits in the PANDEMIC_BORDER band
            -- (7), above the base ring at BORDER (3) — deliberately NOT BORDER+1, which is
            -- DISPEL_RING (4). See DF.AuraButtonLevels.
            --
            -- ☠ REGISTER THE HOLDER, NEVER DF.Border'S PIECES. applyTexPieces calls Show()
            -- on every edge piece on every Apply, so registering pieces would hand their
            -- Shown aspect to the engine and turn DF.Border's routine writes into forbidden
            -- writes on a button child. DF.Border never shows/hides its own frame, which is
            -- what makes a holder around it safe.
            -- ☠ Hidden ONCE at creation, strictly before the bind — after that the engine
            -- owns Shown and we must never touch it.
            -- ☠ STAMP WANTED-NESS, because the HOLDER OUTLIVES THE SETTING. The holder is
            -- create-once and merely hidden when the cue is switched off, so its existence
            -- says nothing about whether the user still wants it -- and armTestPandemicWindow
            -- runs from a timer that fires long after this pass. Without this stamp the
            -- pending re-arm re-Show()s a holder this pass just hid, once per fake cycle,
            -- forever: "pandemic still loops in the frame even if it's disabled, only a
            -- reload fixes it" (Aphoex, 5.2.0-alpha.1). Guard the EFFECT, not the shape.
            slot._dfBorderPandemicWanted = (borderSpec.pandemicSpec and DF.Border) and true or false
            if borderSpec.pandemicSpec and DF.Border then
                if not slot.dfBorderPandemicHolder then
                    slot.dfBorderPandemicHolder = makeHolder(host, LEVELS.PANDEMIC_BORDER)
                    slot.dfBorderPandemicHolder:Hide()
                    local okP, wP = pcall(function()
                        return DF.Border:New(slot.dfBorderPandemicHolder, {
                            solidOnly = true, secretRect = true, frameLevelOffset = 0,
                        })
                    end)
                    if okP then slot.dfBorderPandemic = wP end
                end
                if slot.dfBorderPandemic then
                    local okA, errA = pcall(function()
                        local pspec = borderSpec.pandemicSpec
                        pspec.animation = nil   -- same blanket strip as the base ring
                        if pspec.renderScale == nil then
                            pspec.renderScale = tonumber(config.layout and config.layout.scale) or 1
                        end
                        pspec.knownWidth, pspec.knownHeight = sx, sy
                        DF.Border:Apply(slot.dfBorderPandemic, pspec)
                    end)
                    if not okA and not warnedBorder then
                        warnedBorder = true
                        DF:DebugWarn(DBG, "pandemic border apply failed: %s", tostring(errA))
                    end
                    -- AURA DESIGNER CANVAS ONLY — the same branch, the same guard and the
                    -- same reasoning as the icon cue's holder further down. A plain frame
                    -- has no AddPandemicRegion, so nothing will ever drive this holder's
                    -- visibility there, and the canvas is where the user styles the cue.
                    -- On a real container button this stays false and the engine owns
                    -- Shown, so the never-Show-a-bound-region rule is untouched.
                    -- ☠ This was missing entirely: the holder was hidden once at creation
                    -- and never shown again, so a Border effect's pandemic colour previewed
                    -- as nothing at all while the icon cue previewed fine. It reads as the
                    -- feature being broken rather than as a preview gap.
                    -- ⚠ And in-game TEST slots are handled where the icon cue is handled —
                    -- armTestPandemicWindow, which now drives this holder too, so the cue
                    -- opens and closes with the fake duration instead of sitting on. Do not
                    -- add a Show() here for them; that is the exact mistake 07804854 made.
                    if not slot.AddPandemicRegion then slot.dfBorderPandemicHolder:Show() end
                end
            end
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
            slot.dfCD = CreateFrame("Cooldown", nil, host, "CooldownFrameTemplate")
        end
        slot.dfCD:SetAllPoints(slot.dfIcon or slot.dfSquare or host)
        -- Swipe on by default; cdSpec.swipe=false hides it (AD "Hide Cooldown Swipe").
        local wantSwipe = (cdSpec == nil or cdSpec.swipe ~= false)

        -- EDGE and BLING are ornaments OF the swipe: the edge is the bright leading line
        -- that sweeps round with it, bling the flash when it completes. They must follow
        -- the swipe by default, or "Hide Cooldown Swipe" removes the dark fill and leaves
        -- a yellow line still sweeping the icon — which is exactly how this was reported.
        -- Edge used to default to ON regardless (`cdSpec.edge ~= false` with no producer
        -- ever emitting `edge`), and bling was never set at all, so it sat at whatever
        -- CooldownFrameTemplate ships with. An explicit cdSpec.edge / cdSpec.bling still wins.
        --
        -- ⚠ Written as if/else on purpose. The `x == nil and a or b` idiom is WRONG here:
        -- when the key is nil and the fallback is false it yields b, silently re-enabling
        -- the thing we are trying to turn off.
        local cdEdge, cdBling = cdSpec and cdSpec.edge, cdSpec and cdSpec.bling
        local wantEdge, wantBling
        if cdEdge == nil then wantEdge = wantSwipe else wantEdge = (cdEdge ~= false) end
        if cdBling == nil then wantBling = wantSwipe else wantBling = (cdBling ~= false) end

        if slot.dfCD.SetDrawSwipe then slot.dfCD:SetDrawSwipe(wantSwipe) end
        if slot.dfCD.SetDrawEdge then slot.dfCD:SetDrawEdge(wantEdge) end
        if slot.dfCD.SetDrawBling then slot.dfCD:SetDrawBling(wantBling) end
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
            -- Rung DURATION. The ladder itself lives at DF.AuraButtonLevels, next to
            -- makeHolder — including why it must not be duplicated anywhere else.
            slot.dfDurHolder = makeHolder(host, durSpec.level or LEVELS.DURATION)
            slot.dfDur = slot.dfDurHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        end
        DF.TextStyle:Apply(slot.dfDur, durSpec, slot.dfDurHolder)
    end

    -- STACK count region (native SetApplicationCount bind is in bindNative).
    local stackSpec = style.stacks
    if isRow and stackSpec and stackSpec.show then
        if not slot.dfStack then
            -- Rung STACK: the top-most TEXT, above the ring, duration and symbol. It
            -- rendered UNDER the icon border once before (Krathe 2026-07-15) — every rung
            -- in the ladder now clears BORDER by construction, which is the point of
            -- keeping them in one table.
            slot.dfStackHolder = makeHolder(host, stackSpec.level or LEVELS.STACK)
            slot.dfStack = slot.dfStackHolder:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        end
        DF.TextStyle:Apply(slot.dfStack, stackSpec, slot.dfStackHolder)
    end

    -- DURATION bar region (native SetDurationBar bind is in bindNative). Two shapes:
    --   * barSpec.fill (Aura Designer bar indicator, P4.4): the StatusBar IS the slot
    --     content, filling it edge-to-edge — no icon, no square, no swipe. Native
    --     SetDurationBar drives the value from the aura's Duration object (read-free).
    --   * strip (#205 duration-bar option, Wave 3): a short horizontal bar hung off the
    --     slot's bottom (or top) edge — barSpec.position "BOTTOM"/"TOP", barSpec.gap
    --     (icon-edge → strip distance), barSpec.height.
    -- Styling (texture / orientation / reverse-fill / background / colour) is SHARED
    -- via styleBarShared; geometry is per-shape below. Both shapes style the SAME
    -- slot.dfBar region, so the single SetDurationBar bind (bindNative, bind-once)
    -- serves whichever shape the config picked — never both, never a double bind.
    local barSpec = style.bar
    if isRow and barSpec and barSpec.show then
        if not slot.dfBar then
            slot.dfBar = CreateFrame("StatusBar", nil, host)
            slot.dfBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
            slot.dfBar:SetMinMaxValues(0, 1)   -- native SetDurationBar drives SetValue in [0,1]
        end
        local sb = slot.dfBar
        if barSpec.fill then
            -- FILL geometry: re-anchor to fill the slot every pass (idempotent; safe on ApplyStyle).
            sb:ClearAllPoints()
            sb:SetAllPoints(host)
        else
            -- STRIP geometry: width follows the button via left+right edge anchors;
            -- gap/height are CONFIG values (relative SetPoint only — the slot rect is
            -- secret, never measured, §20c). Re-anchored every pass so position/gap/
            -- height edits apply live via ApplyStyle.
            local gap = tonumber(barSpec.gap) or 2
            sb:ClearAllPoints()
            if barSpec.position == "TOP" then
                sb:SetPoint("BOTTOMLEFT", host, "TOPLEFT", 0, gap)
                sb:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", 0, gap)
            else   -- default BOTTOM: hang below the icon
                sb:SetPoint("TOPLEFT", host, "BOTTOMLEFT", 0, -gap)
                sb:SetPoint("TOPRIGHT", host, "BOTTOMRIGHT", 0, -gap)
            end
            sb:SetHeight(barSpec.height or 4)
        end
        -- Shared styling; colour fallback per shape (fill white / strip legacy green).
        if barSpec.fill then
            styleBarShared(slot, sb, barSpec, 1, 1, 1, 1)
        else
            styleBarShared(slot, sb, barSpec, 0.2, 0.9, 0.3, 1)
        end
    end

    -- SPELL name region (native SetSpellName bind is in bindNative).
    local nameSpec = style.spellName
    if isRow and nameSpec and nameSpec.show then
        if not slot.dfName then
            -- Level with the duration text: both are content text and never occupy the
            -- same corner.
            slot.dfNameHolder = makeHolder(host, LEVELS.DURATION)
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
            -- ☠ HOLDER, NOT A SLOT-LEVEL TEXTURE, and it must out-rank BORDER: DF.Border
            -- is a child FRAME, so a texture on the button renders under it and the
            -- dispel colour is simply invisible. That is exactly what happened when this
            -- was left at rung 1 against a +2 border. (Holder-hosted regions are
            -- registrar-legal — the duration text binds from a holder the same way.)
            slot.dfDispelHolder = makeHolder(host, dispelSpec.level or LEVELS.DISPEL_RING)
            -- ☠ BORN DARK, revealed by bindNative only once the dispel bind has
            -- succeeded. This is OUR texture with the ENGINE'S colour: between creation
            -- and a completed AddDispelTypeTexture nothing colours it, so a shown holder
            -- renders it at the default vertex colour -- a WHITE square ring on every
            -- visible debuff icon. Same failure family as the overlay carriers in
            -- Features/Dispel.lua, closed the same way: the alpha lives on the holder,
            -- a DF-owned frame that is never restricted, so it stays ours to write on a
            -- slot the client has locked.
            slot.dfDispelHolder:SetAlpha(0)
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
            -- Above the dispel RING it belongs to, so the glyph sits on the ring rather
            -- than under it.
            slot.dfSymbolHolder = makeHolder(host, LEVELS.DISPEL_SYMBOL)
            slot.dfSymbol = slot.dfSymbolHolder:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            slot.dfSymbol:SetPoint("CENTER")
        end
        if slot.dfSymbol and dispelSpec.symbol and DF.TextStyle then
            -- Symbol styling (Wave 5b): the FontString is OURS — the engine only writes
            -- its TEXT — so the shared TextStyle spec re-applies every pass and the
            -- font/scale/outline/colour/anchor/offset controls are live via ApplyStyle.
            -- (If the engine also colours the glyph per type, its write simply lands
            -- after ours on each aura update — probe P-SYMBOL settles which wins.)
            DF.TextStyle:Apply(slot.dfSymbol, dispelSpec.symbol, slot.dfSymbolHolder)
        end
    end

    -- PANDEMIC region (PTR 8 / 69111; the AddPandemicRegion bind is in bindNative).
    -- The refresh-window cue: DF builds the art, AddPandemicRegion stamps
    -- Enum.SecretAspect.Shown on it and the engine drives SetShown from its own window
    -- maths. Attach-and-inherit, same shape as SetIcon — nothing here reads an aura.
    --
    -- ☠ NEVER Show()/Hide() this region once it is bound. Blizzard owns its Shown aspect
    -- from AddPandemicRegion onward (the standing rule at the top of this section), and
    -- the bind's own UpdateAuraDisplay() sets the correct initial state. That is also why
    -- the widget is created only when the feature is ON: turning it off is a Rebuild
    -- (DF.Pandemic:StructSig), not a hide.
    --
    -- ☠ WHAT IS REGISTERED DEPENDS ON WHAT ELSE DRIVES Shown, and the rule is the reason,
    -- not the shape. AddPandemicRegion hands the region's Shown aspect to the engine, so
    -- whatever is registered must be something NOTHING ELSE ever shows or hides.
    --   * BORDER registers a HOLDER FRAME, and that is load-bearing: DF.Border's
    --     applyTexPieces calls Show() on every edge piece on every Apply, so registering
    --     the PIECES would hand their Shown to the engine and turn DF.Border's routine
    --     writes into forbidden writes on a button child. The holder leaves DF.Border in
    --     full control of everything inside it. (Verified in game 2026-08-05 that
    --     Frame:IsObjectType("Region") is true, so AddPandemicRegion accepts a frame.)
    --   * TINT and the health-fill cover register the TEXTURE directly. They are plain
    --     regions with no other writer, so there is nothing for a holder to protect, and
    --     the extra frame would buy only symmetry.
    -- ⚠ This note used to say "the HOLDER FRAME, for both types", which described neither
    -- the code nor the constraint — the border reasoning is border-specific and does not
    -- generalise. Whichever way a future region goes, decide it by asking who else writes
    -- Shown, and record THAT.
    --
    -- Create-once: the holder, its contents, the bind, and the flash animation. That is
    -- exactly what DF.Pandemic:StructSig covers. Colours / thickness / inset / offsets all
    -- re-apply below on every style pass, so they are live through ApplyStyle.
    local pdSpec = style.pandemic
    -- ☠ STALE-HOLDER SWEEP, preview slots only. Every other create-once region in this
    -- function relies on "off = never created", which holds because turning a feature off
    -- moves the struct sig and a Rebuild hands over a FRESH button. The AD canvas breaks
    -- that assumption: it reuses one preview slot and only recreates it when its own sig
    -- moves, so a cue created on a previous pass survives being switched off and stays
    -- visible — reported as a permanent green wash over a bar indicator (Krathe,
    -- 2026-08-05). The canvas sig now carries the pandemic key too, which is the real fix;
    -- this is the backstop, because a silently-stuck overlay is a bad failure mode to have
    -- one guard against.
    -- Gated on the registrar being ABSENT: that is what makes the slot a preview and the
    -- Shown aspect ours. On a native button Blizzard owns it and we must never touch it.
    if isRow and not pdSpec and slot.dfPandemicHolder and not slot.AddPandemicRegion then
        slot.dfPandemicHolder:Hide()
    end
    -- ☠ Companion to the hide above, and the half that survives a TIMER. Hiding here only
    -- wins until armTestPandemicWindow's pending C_Timer fires and shows it again, which
    -- is why switching the cue off in test mode looked like it did nothing until a reload.
    -- See the matching stamp on the border twin.
    slot._dfPandemicWanted = pdSpec and true or false
    -- ☠ THE SAME SWEEP, GENERALIZED — every other create-once region. The pandemic
    -- note above predicted this class ("every OTHER create-once region relies on
    -- 'off = never created'"), and the 5.1.1 self-contained test mode made it real:
    -- its preview POOL reuses slots across passes, so a disabled duration bar /
    -- border / dispel text / stack count survived its own off-toggle on the preview
    -- until reload (field report, day one of 5.1.1). Same gate as above — registrar
    -- ABSENT means the slot is a preview and the Shown aspect is ours; a native
    -- button gets a fresh frame per Rebuild and Blizzard owns its visibility.
    -- SetShown both ways: these pooled slots also need the re-SHOW half, because
    -- no native bind ever runs to bring a region back.
    if isRow and not slot.AddPandemicRegion then
        if slot.dfCD then
            slot.dfCD:SetShown(style.cooldown == nil or style.cooldown.show ~= false)
        end
        if slot.dfDurHolder then
            slot.dfDurHolder:SetShown((style.duration and style.duration.show) and true or false)
        end
        if slot.dfStackHolder then
            slot.dfStackHolder:SetShown((style.stacks and style.stacks.show) and true or false)
        end
        if slot.dfBar then
            slot.dfBar:SetShown((style.bar and style.bar.show) and true or false)
        end
        if slot.dfNameHolder then
            slot.dfNameHolder:SetShown((style.spellName and style.spellName.show) and true or false)
        end
        if slot.dfDispelHolder then
            slot.dfDispelHolder:SetShown((style.dispel and style.dispel.nativeBorder) and true or false)
        end
        if slot.dfSymbolHolder then
            slot.dfSymbolHolder:SetShown((style.dispel and style.dispel.nativeSymbol) and true or false)
        end
        if slot.dfBorder and not style.border and DF.Border then
            -- The border widget hides through its own Apply (edges + backdrop +
            -- texture pieces + glow teardown); a re-enable re-applies through the
            -- normal border block above.
            pcall(function()
                DF.Border:StopAnimation(slot.dfBorder)
                DF.Border:Apply(slot.dfBorder, { enabled = false })
            end)
        end
    end
    if isRow and pdSpec then
        if not slot.dfPandemicHolder then
            -- ⚠ The level comes from the SPEC, because the two pandemic modes want
            -- opposite z-order: a BORDER tops the ladder, a TINT sits under the
            -- information. Both values come from DF.AuraButtonLevels — see Pandemic.lua.
            slot.dfPandemicHolder = makeHolder(host, pdSpec.level or LEVELS.PANDEMIC_BORDER)
            -- Created hidden so a slot never flashes its cue between creation and the
            -- bind. This is the ONLY legal visibility write on the holder: it happens
            -- strictly before AddPandemicRegion, while the Shown aspect is still ours.
            slot.dfPandemicHolder:Hide()

            -- ANIMATION: built and started HERE — inside the secure init pass — and never
            -- touched again. Driving one from the tainted style pass would be a write to a
            -- forbidden button child.
            -- ★ NOT the OnUpdate border animator that is stripped from every container
            -- border above. That one calls back into tainted Lua every frame to redraw the
            -- border's pieces, which the lockdown forbids on a button child. These are
            -- declarative AnimationGroups: started once, run entirely C-side, zero Lua per
            -- frame. That difference is the whole reason DF.Border's effect set cannot come
            -- here and these can.
            -- Animates the HOLDER, so one implementation covers whatever the mode drew.
            -- ☠ ALPHA ONLY. A Scale-based pulse was built and tried in game (2026-08-05)
            -- and did nothing — the holder carries SecretAspect.Shown plus the forbidden
            -- aspects AddPandemicRegion stamps on it, and a scale transform evidently does
            -- not survive that where an alpha one does. Left at the one effect that
            -- demonstrably works rather than shipping a dropdown of dead options.
            if pdSpec.flash then
                local ag = slot.dfPandemicHolder:CreateAnimationGroup()
                ag:SetLooping("REPEAT")
                local half = pdSpec.flash / 2
                local out = ag:CreateAnimation("Alpha")
                out:SetFromAlpha(1); out:SetToAlpha(0.25)
                out:SetDuration(half); out:SetOrder(1)
                local back = ag:CreateAnimation("Alpha")
                back:SetFromAlpha(0.25); back:SetToAlpha(1)
                back:SetDuration(half); back:SetOrder(2)
                -- No handle kept: the group is owned by the holder and outlives this
                -- scope on its own, and there is no legal path that would ever stop it
                -- (touching it later is a tainted write to a button child).
                ag:Play()
            end
        end
        local holder = slot.dfPandemicHolder

        if pdSpec.mode == "TINT" then
            if not slot.dfPandemicTint then
                slot.dfPandemicTint = holder:CreateTexture(nil, "OVERLAY")
            end
            local t = slot.dfPandemicTint
            -- Anchored to the holder's edges rather than sized: the button's rect is
            -- SECRET on 12.1, and anchor-derived geometry is the one route that stays
            -- legal. Inset follows the DF.Border sign convention (+ inward, − outward).
            local ins = tonumber(pdSpec.tintInset) or 0
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", holder, "TOPLEFT", ins, -ins)
            t:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -ins, ins)
            local r, g, b = readColor(pdSpec.tintColor)
            t:SetColorTexture(r, g, b, tonumber(pdSpec.tintAlpha) or 0.4)
        elseif pdSpec.border then
            -- The full house border, inside the holder. secretRect routes it through
            -- DF.Border's anchor-only piece path — a container button has no anchors yet
            -- when initializeFrame runs and its rect is secret, so the BackdropTemplate
            -- path would scatter (the same reason style.border above passes it).
            if not slot.dfPandemicBorder then
                local ok, w = pcall(function()
                    -- ☠ frameLevelOffset = 0, NOT the default 10. The holder is already
                    -- host + (pdSpec.level or 15); another +10 put this border at host + 25,
                    -- which on an aura button lands inside the DEFENSIVE ICON's band
                    -- (defensiveIconFrameLevel 65) — the cue drew over an icon two bands
                    -- above it, reported as an Aura Designer indicator bleeding onto the
                    -- defensive icon. A border does not need the bump: it is a CHILD of the
                    -- holder, so at the holder's own level it already draws above every
                    -- region on it. The offset only buys anything when a border has to clear
                    -- a SIBLING frame (a bar fill, a swipe), which this one does not — the
                    -- same reason the AD badge borders and the missing-buff badge all pass 0.
                    -- (Audit follow-up, 2026-08-07.)
                    return DF.Border:New(holder, { solidOnly = true, secretRect = true,
                                                   frameLevelOffset = 0 })
                end)
                if ok then slot.dfPandemicBorder = w end
            end
            if slot.dfPandemicBorder then
                local ok, err = pcall(function()
                    local bs = pdSpec.border
                    bs.knownWidth, bs.knownHeight = sx, sy   -- DF_DASH sizes from these, never a rect read
                    if bs.renderScale == nil then
                        bs.renderScale = tonumber(config.layout and config.layout.scale) or 1
                    end
                    DF.Border:Apply(slot.dfPandemicBorder, bs)
                end)
                if not ok and not warnedPandemicBorder then
                    warnedPandemicBorder = true
                    DF:DebugWarn(DBG, "pandemic border apply failed: %s", tostring(err))
                end
            end
        end

        -- AURA DESIGNER CANVAS ONLY. A plain frame has no AddPandemicRegion, so nothing
        -- will ever drive the holder's visibility there — and the canvas is where the
        -- user styles the cue, so it has to be visible. On a real container button this
        -- stays false and the engine drives visibility, so the "never Show() a bound
        -- region" rule above is not weakened.
        --
        -- ☠ DO NOT EXTEND THIS TO IN-GAME TEST SLOTS. That was tried (07804854, on the
        -- true observation that the buff row's cue was previewable nowhere) and it is
        -- what put a permanent Pandemic border on every previewed icon: a test slot
        -- paints instead of binding, so nothing ever HIDES the holder again and the cue
        -- sat on forever. Reported as an Aura Designer indicator drawing a border it
        -- does not have live, bleeding over the defensive icon — the border is
        -- DF.Border:New(holder, ...), which sits at holder + 10.
        --
        -- Pandemic is DURATION-DRIVEN: "always on" is not a preview of it, it is a
        -- different picture that happens to be visible. In-game test slots get the cue
        -- from armTestPandemicWindow instead, driven off the same fake duration as the
        -- bar, swipe and text — it opens near the end of each cycle and closes when the
        -- cycle re-arms, so it previews as a window rather than a decoration.
        -- (Audit follow-up, 2026-08-07.)
        if not slot.AddPandemicRegion then holder:Show() end
    end
end

-- How a duration spec's FORMATTER goes onto a binding. Shared by the live template
-- below and the test-mode binding (armTestDuration) — they must configure a binding
-- identically or the preview lies about the live look.
--   textFormat  a formatter sampled against a NON-default duration property (the expiry
--               reveal on its percent scale). SetTextFormat substitutes each "{}" with
--               its component, and a component names both the property and the
--               formatter — the only way to judge bands against RemainingPercent
--               instead of remaining seconds. MUST be tried first: a percent-unit
--               reveal also carries `formatter`, so falling through to SetFormatter
--               silently samples its percent bands against SECONDS. A 12s test aura
--               then sits under the lowest band for its whole life and the reveal is
--               stuck on that colour (red) instead of walking the ramp.
--   formatter   plain formatter, sampled against the default remaining-seconds.
--   neither     a fresh binding is UNCONFIGURED, so default-format rows would render
--               no text at all — mirror the native default.
local function applyDurationFormatter(b, durSpec)
    if durSpec.textFormat and b.SetTextFormat then
        b:SetTextFormat(durSpec.textFormat.formatString, durSpec.textFormat.components)
    elseif durSpec.formatter then
        b:SetFormatter(durSpec.formatter)
    else
        local def = AuraContainerInbound and AuraContainerInbound.GetDefaultAuraDurationFormatter
              and AuraContainerInbound.GetDefaultAuraDurationFormatter()
        if def then b:SetFormatter(def) end
    end
end

-- Does this client's SetDurationText read the NEW options shape
-- ({ binding | textFormat | textFormatter | textColor }) rather than the flat
-- formatter/expiredText/zeroDurationText/updateInterval keys?
-- ★ The marker must be something 68914 ADDED. The obvious-looking
-- AuraContainerInbound.GetDefaultAuraDurationFormatter is NOT it: that function exists
-- on 68824 too, where SetDurationText still reads the flat keys and silently IGNORES
-- options.binding — so gating on it sent 68824 down the binding path, dropping every
-- custom duration format (SHORT/FULL, hide-above blanking, zero-text-on-permanents)
-- back to defaults while the flat-options branch below became unreachable.
-- C_AuraContainerUtil.ProcessCustomAuraButtonDurationTextOptions is the honest probe:
-- 68914's SetDurationText runs the options through it (Blizzard_CustomAuraButton.lua),
-- so its presence IS the new options shape.
local function supportsDurationTextBinding()
    return C_AuraContainerUtil ~= nil
        and type(C_AuraContainerUtil.ProcessCustomAuraButtonDurationTextOptions) == "function"
end

-- Build (or reuse) the configured TEMPLATE DurationTextBinding for this config's
-- duration spec. 68914's SetDurationText only reads { binding | textFormat |
-- textFormatter | textColor } (CustomAuraButtonDurationTextOptions) and
-- Assign()-copies a supplied binding into the button's own — so ONE template
-- serves every slot in the row. Cached by spec identity: a structural Rebuild
-- delivers a fresh style table, which naturally invalidates the cache.
local function durationTemplateBinding(config, durSpec)
    if config._dfDurBind and config._dfDurBindSpec == durSpec then return config._dfDurBind end
    if not (C_DurationUtil and C_DurationUtil.CreateDurationTextBinding) then return nil end
    local b = C_DurationUtil.CreateDurationTextBinding()
    -- A fresh binding is UNCONFIGURED (the SetToDefaults contract: no font string,
    -- duration, format, formatter or fallback text) and Assign replaces the button
    -- binding WHOLESALE — so the template must carry the default formatter itself
    -- or default-format rows render no text at all.
    applyDurationFormatter(b, durSpec)
    -- Guards mirror the legacy flat-option block exactly: expiredText ~= "",
    -- zeroText nil-vs-set ("" MEANINGFULLY renders no text on permanents).
    if durSpec.expiredText and durSpec.expiredText ~= "" then b:SetExpiredText(durSpec.expiredText) end
    if durSpec.zeroText ~= nil then b:SetZeroDurationText(durSpec.zeroText) end
    if durSpec.updateInterval then b:SetUpdateInterval(durSpec.updateInterval) end
    b:SetEnabled(true)   -- Assign copies state wholesale; never hand over a disabled template
    config._dfDurBindSpec, config._dfDurBind = durSpec, b
    return b
end

-- Register each region with its Blizzard inbound setter. NATIVE slots only (a plain
-- fake/legacy slot lacks these methods, so each bind is skipped and its backend pushes
-- data to the regions instead). Bind-once per region so ApplyStyle re-runs don't re-register.
-- INVARIANT: regions are create-once (styleButton_regions) and never recreated, so each
-- per-region _boundX flag stays valid for the life of the slot. If any code ever recreates
-- a region, it MUST also clear that region's _boundX or the new region silently never binds.
-- Stable stand-in for "this config has no duration spec", so the absent case has a
-- constant identity too. A fresh {} per call would look like a spec change every pass and
-- re-bind forever.
local EMPTY_DUR_SPEC = {}

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

    -- ☠ NOT BIND-ONCE ANY MORE, and the old claim was factually wrong against Blizzard.
    -- CustomAuraButtonSharedMixin:SetDurationText is reset-then-apply: it fetches the
    -- RETAINED binding, does binding:Assign(options.binding) or SetToDefaults() +
    -- SetFormatter(default), then re-applies fontstring / duration / textFormat /
    -- textColor and calls UpdateAuraDisplay(). Idempotent on re-call, not additive, and
    -- OnLoad_Intrinsic states the intent outright: "Retain the duration text binding
    -- across reconfiguration." The freeze was ours, not the API's.
    --
    -- That freeze is why durationFmtKey sits in FOUR structural signatures, and why one
    -- account-wide setting (GetAuraDurationUpdateInterval) re-keys every container on
    -- every frame. Re-binding on a spec change lets those become live.
    --
    -- Keyed on spec IDENTITY, which is sound for exactly the reason the colour cache
    -- below already depends on: a duration spec is never mutated in place -- every
    -- writer fills a fresh table. Worst case if a builder hands us a fresh-but-equal
    -- table is one extra SetDurationText per button per restyle, which is still orders
    -- of magnitude cheaper than the container rebuild this replaces.
    local durSpecKey = style.duration or EMPTY_DUR_SPEC
    if slot.dfDur and slot.SetDurationText and slot._dfDurSpec ~= durSpecKey then
        -- _dfDurSpec is stamped AFTER the pcall below, not here: a failed bind must be
        -- retried rather than latching permanently and leaving the text blank for the
        -- life of the slot (warnedCurve is one-shot per session, so the second distinct
        -- failure was silent too).
        local durSpec = durSpecKey
        -- 68914 RESHAPED the options: SetDurationText now only reads { binding |
        -- textFormat | textFormatter | textColor }; the flat formatter/expiredText/
        -- zeroDurationText/updateInterval keys are silently IGNORED (the
        -- field-reported "duration text lost its format" break). Route the spec
        -- through a template binding on those builds (durationTemplateBinding above);
        -- older builds keep the flat table. See supportsDurationTextBinding for why
        -- the probe is the options PROCESSOR and not the default-formatter getter.
        local opts = {}
        if supportsDurationTextBinding() then
            if durSpec.textFormat or durSpec.formatter or (durSpec.expiredText and durSpec.expiredText ~= "")
               or durSpec.zeroText ~= nil or durSpec.updateInterval then
                opts.binding = durationTemplateBinding(config, durSpec)
            end
            -- else: nothing to carry — Blizzard's no-options path (SetToDefaults +
            -- default formatter) already renders exactly what the template would.
        else
            if durSpec.formatter then opts.formatter = durSpec.formatter end
            if durSpec.expiredText and durSpec.expiredText ~= "" then opts.expiredText = durSpec.expiredText end
            -- zeroText: "" is MEANINGFUL — SetZeroDurationText("") renders NO text on
            -- zero-duration/unconfigured (= permanent) auras, while nil keeps Blizzard's
            -- default zero-duration rendering (the mixin forwards options.zeroDurationText
            -- unconditionally and the API arg is nilable). So the guard is nil-vs-set,
            -- never ~= "".
            if durSpec.zeroText ~= nil then opts.zeroDurationText = durSpec.zeroText end
            -- updateInterval (Wave 5a): minimum seconds between automatic text
            -- refreshes. Absent = the binding's own default cadence — the NORMAL
            -- setting deliberately emits nothing (the C-side default is
            -- undocumented, so absent-key is the only behavior-neutral shape).
            if durSpec.updateInterval then opts.updateInterval = durSpec.updateInterval end
        end
        -- Colour-by-time (68914+): options.textColor = { curve, property } is forwarded
        -- to binding:SetTextColorCurve WITH the property arg the 68569 wrapper dropped —
        -- the reason the curve was dead. The C side evaluates it against the SECRET
        -- remaining time and writes the fontstring's vertex colour, so the whole ramp
        -- costs zero Lua per frame. The spec supplies BOTH members or neither
        -- (Features/Auras.lua builds them together); a partial table would assert.
        -- MUTUALLY EXCLUSIVE with the legacy bucket formatter: |c escapes inside the
        -- text beat vertex colour, so a spec never carries both (the row builders send
        -- a curve OR a coloured formatter, never each).
        if durSpec.colorCurve and durSpec.colorProperty ~= nil then
            -- Cached on the config by spec identity, exactly like _dfDurBind above.
            -- This runs once per BUTTON, so a fresh table here cost one allocation
            -- per slot per rebuild across every row on every frame.
            -- ☠ The key is sufficient because a duration spec is never mutated in
            -- place -- every writer of colorCurve/colorProperty fills a table that
            -- is still a local (Auras.lua's TextStyle:BuildSpec result, Factory's
            -- constructor literal), and a curve rebuild copies BY VALUE into a
            -- brand-new dur table. Do NOT restate this as "a structural Rebuild
            -- hands over a fresh style table": SetFilter, the test-mode ApplyTuning
            -- and the deferred regen rebuild all call _rebuild() on the SAME config
            -- and style, so the cache demonstrably survives a rebuild. It is the
            -- no-in-place-mutation property that makes it safe, nothing else.
            if config._dfDurColorSpec ~= durSpec then
                config._dfDurColorSpec = durSpec
                config._dfDurColor = { curve = durSpec.colorCurve, property = durSpec.colorProperty }
            end
            opts.textColor = config._dfDurColor
        end
        -- pcall(fn, self, args...) rather than pcall(function() ... end): no wrapper
        -- closure per button (same reason as the AddAuraGroup call in build()).
        -- Protection is unchanged.
        local ok, err = pcall(slot.SetDurationText, slot, slot.dfDur, opts)
        if ok then
            slot._dfDurSpec = durSpecKey
        elseif not warnedCurve then
            warnedCurve = true
            DF:DebugWarn(DBG, "SetDurationText failed: %s", tostring(err))
        end
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

    -- PANDEMIC (PTR 8 / 69111). The registrar is a LIST, not a single slot
    -- (AddPandemicRegion returns an index; RemovePandemicRegion / ClearPandemicRegions
    -- take one back) — but DF binds exactly one region per button and treats removal as
    -- a Rebuild, because re-registering would need secure context again and an
    -- asymmetric add-live/remove-live pair is how the border/dispel binds have gone
    -- wrong before.
    --
    -- The stamp lands AFTER the pcall, not before: a bind-once flag set up front latches
    -- a FAILED bind permanently, and the warn latch is one-shot per session, so the
    -- second failure would be silent too. (Same fix the duration-text and dispel binds
    -- already carry.) ★ The latch is now warnedPandemicRegion, one of three -- this
    -- comment said `warnedPandemic`, a single flag shared with the border and cover
    -- sites, which meant the "second failure is silent" it warns about was ALSO true
    -- across the three of them. Split; the reasoning here was right and under-applied. A client older than PTR 8 has no AddPandemicRegion, so the gate
    -- simply never matches and the feature is absent rather than erroring — the region
    -- is never created either, since the factory/rows only emit a spec when it exists.
    if slot.dfPandemicHolder and slot.AddPandemicRegion and not slot._boundPandemic then
        local ok, err = pcall(slot.AddPandemicRegion, slot, slot.dfPandemicHolder)
        if ok then
            slot._boundPandemic = true
        elseif not warnedPandemicRegion then
            warnedPandemicRegion = true
            DF:DebugWarn(DBG, "AddPandemicRegion failed (build still ok): %s", tostring(err))
        end
    end

    -- PANDEMIC COVER (AD frame tints). Same registrar as the icon cue above, pointed at
    -- the SECOND overlay cover on this button — the one carrying the pandemic colour.
    -- The base cover beneath it is left alone and keeps rendering on the slot's own
    -- presence gate, so the pair reads as "colour A while the buff is up, colour B inside
    -- the refresh window". Both gates are the engine's; no Lua combines them.
    --
    -- ☠ REGISTER THE PANDEMIC COVER, NEVER THE BASE. Registering the base (the first
    -- build did, when the variant was a separate container) hands the engine the wash
    -- that is supposed to show for the buff's whole life.
    --
    -- ☠ THE REGION IS REGISTERED DIRECTLY, no holder — deliberately the opposite of the
    -- icon cue's rule, for the reason that rule exists. There the holder protects
    -- DF.Border, whose Apply calls Show() on every edge piece, so registering pieces
    -- would turn routine writes into forbidden writes. Nothing ever calls Show/Hide on
    -- these covers (the pooled-slot re-show sweep in styleButton_regions is isRow-gated),
    -- so there is no write to protect. A holder would also add a frame to the level
    -- chain, and the cover sits exactly ONE level under the attached absorb bar — a +1
    -- shift would put the wash over the shield (bug #1027 territory).
    -- ☠ SO: never add a Show/Hide of dfHealthFill / dfTint. That is now load-bearing.
    --
    -- Only Shown is stamped (unlike AddDispelTypeTexture, which also takes Alpha and
    -- VertexColor), so the per-style-pass colour/alpha/anchor writes below stay legal.
    -- On a PREVIEW slot there is no registrar, so the cover renders ungated — the same
    -- behaviour the icon cue has on the AD canvas, and the reason test mode cannot show
    -- this gate (a preview aura has no auraInstanceID, so no window ever opens).
    -- No flag to read: the pandemic cover only EXISTS when a pandemic colour is
    -- configured, and its creation is structural, so its presence is the condition.
    if slot.AddPandemicRegion and not slot._boundPandemicCover then
        -- One of the three, by effect type: health-bar fill cover, background/whole-bar
        -- tint, or the border ring's holder. An AD effect is one type per container, so
        -- exactly one of these ever exists on a given button.
        local cover = slot.dfHealthFillPandemic or slot.dfTintPandemic or slot.dfBorderPandemicHolder
        if cover then
            local ok, err = pcall(slot.AddPandemicRegion, slot, cover)
            if ok then
                slot._boundPandemicCover = true
            elseif not warnedPandemicCover then
                warnedPandemicCover = true
                DF:DebugWarn(DBG, "AddPandemicRegion (cover) failed: %s", tostring(err))
            end
        end
    end

    local dispelSpec = style.dispel
    if dispelSpec then
        if slot.dfAuraBorder and (slot.AddDispelTypeTexture or slot.SetAuraBorder)
            and (not slot._boundAuraBorder or slot._dfDispelCurveGen ~= DF.dispelCurveGen) then
            -- Both stamps land AFTER the pcall below. Setting them up front meant a
            -- failed bind marked the slot as bound AND as carrying the current
            -- palette generation, so the ring stayed blank until an unrelated
            -- rebuild -- the curve-gen bump that is supposed to force a re-bind had
            -- already been consumed by the failure.
            -- Style resolution is SHARED with the dispel overlay (DF:ResolveDispelTextureStyle
            -- in Frames/Border.lua) — it carries the 68914 enum rename/renumber and the
            -- correct last-resort literals. Never resolve the enum locally.
            local styleName = dispelSpec.style or "Atlas"
            local styleEnum = DF:ResolveDispelTextureStyle(styleName)
            -- Custom dispel colours: Color-style rings recolour from the shared
            -- account palette via customDispelColorMap — keyed by dispel NAME,
            -- indexed private-side against auraData.dispelName (nil → game palette).
            -- ☠ The map is NOT secret-safe on its own: it is a raw table index against
            -- auraData.dispelName private-side, and a SECRET name matches no key (the
            -- dispel-overlay white-wash report, 2026-08-19 — see Features/Dispel.lua's
            -- BindDispelCarriers). The curve resolves C-side by auraInstanceID and wins
            -- when present; the map stays as the pre-curve fallback.
            local map, curve
            if styleName == "Color" then
                if DF.GetDispelColorMap then map = DF:GetDispelColorMap() end
                if DF.GetDispelColorCurve then curve = DF:GetDispelColorCurve() end
            end
            -- ⚠ THE CURVE IS RESOLVED ABOVE, AND ONLY FOR "Color". A second,
            -- unconditional `local curve` briefly lived here; it shadowed the one above
            -- and handed the user's palette to EVERY style. That is not a widening of a
            -- missing field -- the engine applies the curve unconditionally and lets it
            -- override the map with no test on the result, so passing it outside "Color"
            -- overrides the game's own dispel colours on styles that are meant to show
            -- them. If this lane ever should carry the curve elsewhere, it is a
            -- deliberate behaviour change, not a fix.
            local ok, err = pcall(function()
                local opts = {
                    style = styleEnum,
                    customDispelColorMap = map,
                    customDispelColorCurve = curve,
                    showWhenHarmful = dispelSpec.showWhenHarmful ~= false,
                    showWhenHelpful = dispelSpec.showWhenHelpful == true,
                    showIcon = false,
                }
                -- 68914: SetAuraBorder is the deprecated clearing alias ("removed after
                -- 12.1"); AddDispelTypeTexture is the real API and APPENDS. This bind
                -- re-runs on a palette-generation bump, so clear first to REPLACE rather
                -- than stack a second ring on the same icon.
                if slot.AddDispelTypeTexture then
                    if slot.ClearDispelTypeTextures then slot:ClearDispelTypeTextures() end
                    slot:AddDispelTypeTexture(slot.dfAuraBorder, opts)
                else
                    slot:SetAuraBorder(slot.dfAuraBorder, opts)
                end
            end)
            if ok then
                slot._boundAuraBorder = true
                slot._dfDispelCurveGen = DF.dispelCurveGen
                -- ★ REVEAL ONLY NOW -- the holder was born at alpha 0 (styleButton_regions).
                -- ClearDispelTypeTextures ran inside the pcall above, so on the FAILURE
                -- branch the ring may be cleared-but-unbound: hide it again rather than
                -- leave a white ring standing until the retry on the next restyle.
                if slot.dfDispelHolder then slot.dfDispelHolder:SetAlpha(1) end
            else
                if slot.dfDispelHolder then slot.dfDispelHolder:SetAlpha(0) end
                if not warnedDispelBorder then
                    warnedDispelBorder = true
                    DF:DebugWarn(DBG, "SetAuraBorder failed (build still ok): %s", tostring(err))
                end
            end
        end
        if slot.dfSymbol and (slot.SetDispelTypeText or slot.SetAuraSymbol) and not slot._boundSymbol then
            slot._boundSymbol = true
            local ok, err = pcall(function()
                local opts = {
                    showWhenHarmful = dispelSpec.showWhenHarmful ~= false,
                    showWhenHelpful = dispelSpec.showWhenHelpful == true,
                    -- Supplying the letters ourselves takes ApplyDispelTypeText's
                    -- customText branch, which SetText()+Show()s directly instead of
                    -- calling AuraUtil.SetAuraSymbol — the only place the
                    -- `colorblindMode` CVar is read. Same letters the game would use
                    -- (they come from its own globals), minus the CVar dependency.
                    -- See DF:GetGameDispelTextMap in Frames/Border.lua.
                    customDispelTextMap = DF.GetGameDispelTextMap and DF:GetGameDispelTextMap() or nil,
                }
                -- 68914: SetAuraSymbol sits in the same "removed after 12.1" deprecation
                -- block as SetAuraBorder, but unlike that one it is a PLAIN ALIAS —
                -- `SetAuraSymbol = SetDispelTypeText`, same (fontString, options)
                -- signature, no clear-then-add semantics to mirror. So this is a straight
                -- rename: prefer the real name, keep the alias only for older builds.
                -- Without the fallback the gate above would simply stop matching when the
                -- aliases go, and the dispel symbol would vanish SILENTLY.
                if slot.SetDispelTypeText then
                    slot:SetDispelTypeText(slot.dfSymbol, opts)
                else
                    slot:SetAuraSymbol(slot.dfSymbol, opts)
                end
            end)
            if not ok and not warnedDispelText then
                warnedDispelText = true
                DF:DebugWarn(DBG, "SetDispelTypeText failed (build still ok): %s", tostring(err))
            end
        end
    end
end


-- ============================================================
-- LAYOUT  (row mode)
-- Baseline grid layout: linear growth in a primary axis, wrapping to a secondary
-- axis after `wrap` icons. Compound growth strings ("RIGHT_DOWN", "LEFT_UP", ...).
-- NOTE (step 1): reconcile with DF's legacy center-growth / pixel-perfect handling so
-- buff/debuff rows lay out pixel-identically to today. This baseline covers the common
-- cases. (The note named Features/Auras.lua RepositionCenterGrowthIcons as the thing
-- to reconcile against; no such function exists any more, in either addon, so the
-- comparison has to be made against rendered output rather than against that source.)
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
--     note in P2 polish).
--   * CENTER growth IS expressible and IS implemented — see the `if out.center` branch
--     in resolveGrowthLayout below, which computes flowAnchor/pinPoint/pinX/pinY for
--     both the vertical and horizontal centred stacks, and the paragraph above it that
--     explains the box-pin approach. (This line used to say CENTER "falls back to
--     Right": written before that branch existed, and left behind when it landed.)
--   * Scale: applied to the container itself — buttons, fonts, borders and spacing all
--     render at row scale (the legacy defensive stride model; buff rows historically
--     didn't scale the spacing term — the flow can't express that split, and scaling
--     spacing uniformly is the more consistent behaviour anyway).
-- Resolve config.layout into flow parameters: flow direction names, the corner the
-- flow fills from (flowAnchor), and how the container box pins to the user's anchor
-- point (pinPoint + pinX/pinY offsets).
--
-- CENTER growth ("Direction: Center" — legacy did this with a second positioning pass
-- in Icons.lua; that helper no longer exists, so this is the only implementation):
-- the native flow has no centering
-- concept, but the container SELF-SIZES to content each layout pass (secret SetSize,
-- Blizzard_CustomAuraContainer.lua:738) — so fill the box from a fixed corner and
-- pin the box's centre-of-edge to the user's anchor point; the render then keeps
-- the row centred as icons come and go, in combat, with zero reads. pinX/pinY fold
-- in the icon-anchor offset the legacy pass produced (legacy anchored each ICON's
-- own `anchor` point at the target; the box pin is edge-based), so the common
-- single-row case lands where the legacy pass put it. Multi-row blocks fill from
-- the box corner (flow order) rather than centring each row individually —
-- accepted approximation, the flow owns button placement.
-- ★ THE ONE PLACE THE LAYOUT STRIDE IS DEFINED. Published on DF because the Aura
-- Designer's editor preview needs the identical answer: it used to compute its own, in
-- TWO different ways (one of which dropped `scale` outright), so a group with any scale
-- other than 1.0 previewed at a stride the live frame never used. Reported as "preview
-- is not staying true to the actual frame", and the reporter isolated it themselves:
-- "setting icon scale to 1.0 seems to fix the spacing" (2026-08-13).
-- ☠ Offsets computed from this live in the BUTTON'S SCALED SPACE -- callers must
-- SetScale(scale) the positioned frame, or the stride renders at the wrong size. That
-- coupling is why this returns the step rather than a finished position: the caller still
-- owns the scale it applies, and the two have to agree.
--   preScaledStep ~= false : stepX = size*scale + spacing  (buff/debuff/AD rows)
--   preScaledStep == false : stepX = size + spacing        (legacy defensive stride)
function DF:ResolveAuraLayoutStep(sizeX, sizeY, spacingX, spacingY, scale, preScaledStep)
    scale = tonumber(scale) or 1
    if preScaledStep == false then
        return sizeX + spacingX, sizeY + spacingY
    end
    return sizeX * scale + spacingX, sizeY * scale + spacingY
end


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

-- STRIP RESERVATION (Wave 3.2). A strip-shape duration bar renders OUTSIDE the
-- button rect (3.1): `height + gap` px beyond the slot edge on the side
-- barSpec.position names. Nothing in the flow layout knows about it, so wrapped
-- rows collide with the strips. The reservation is derived from CONFIG only —
-- never measured (button rects are secret, §20c): returns the px to reserve
-- (0 = fill / no bar / hidden) plus whether the strip sits on TOP of the icon.
-- Consumed in two places, both reached from build AND from the live applyLayout:
--   * buildGroupLayout folds it into elementHeight — the flow's GetElementSize
--     OVERRIDES the measured button height with elementHeight, so the row stride
--     AND the container's self-size grow by the reservation. The extra space
--     lands on the side AWAY from the flow's start corner, which covers every
--     between-row gap (clearance = reservation + spacingY exactly) and the
--     far-side boundary row.
--   * applyContainerLayout insets the START side via the layout padding when the
--     strip FACES it (TOP strip on downward growth / BOTTOM strip on upward) —
--     otherwise the first row's strips poke past the container's start edge at
--     the user's anchor.
local function stripReservation(config)
    local bar = config.style and config.style.bar
    if not (bar and bar.show and not bar.fill) then return 0, false end
    return (tonumber(bar.height) or 4) + (tonumber(bar.gap) or 2), bar.position == "TOP"
end

-- ============================================================
-- PIXEL PERFECT (container edition). The legacy aura icons kept three PP
-- invariants the container port initially lost:
--   1. border thickness snapped in the RENDER space (legacy ran scale=1.0 and
--      folded scale into size; containers use real SetScale, so snapping must
--      fold the scale — DF.Border spec.renderScale / Border:SnapThickness);
--   2. icon size / spacing quantized to whole physical pixels (fractional
--      strides accumulate across a row — adjacent icons rendered visibly
--      different borders);
--   3. the render origin nudged onto the physical pixel grid (legacy:
--      SnapPointToPixelGrid per icon placement).
-- Buttons here are anchored by Blizzard's secure flow layout (secret offsets,
-- §20c) so a per-button snap is impossible — instead the CONTAINER'S pin offset
-- is adjusted arithmetically from the anchor frame's rect (a plain DF frame,
-- readable; the container's own rect is secret-derived and never read). With the
-- pin corner on-grid and every stride whole-pixel, each button lands on-grid.
-- CENTER growth stays best-effort: its pin is a centre-of-edge, so an odd total
-- row width still straddles by half a pixel.
-- ============================================================

-- pp resolution: config.pixelPerfect wins when set; else the HOST frame's db —
-- handle.frame's parent is the unit frame the consumer attached to. Non-DF hosts
-- (GUI preview panels, healthbar sub-frames for overlays) resolve nil -> off.
local function resolvePixelPerfect(handle)
    local cfgPP = handle.config and handle.config.pixelPerfect
    if cfgPP ~= nil then return cfgPP and true or false end
    local ok, pp = pcall(function()
        local host = handle.frame and handle.frame:GetParent()
        local db = host and DF.GetFrameDB and DF:GetFrameDB(host)
        return db and db.pixelPerfect
    end)
    return (ok and pp) and true or false
end

-- Snap a layout length to whole physical pixels in the container's SCALED space
-- (layout numbers live in the container's own units; rendered px = value x
-- scale). 0 stays 0 (a zero spacing/offset is exact already).
local function ppSnapScaled(v, scale)
    if not v or v == 0 or not DF.PixelPerfect then return v end
    local s = tonumber(scale) or 1
    if s > 0 and s ~= 1 then return DF:PixelPerfect(v * s) / s end
    return DF:PixelPerfect(v)
end

-- Quantize the geometry fields of a layout table into a SHALLOW COPY (the
-- caller's table is shared by reference and must not be mutated — see Create).
-- Sizes and spacings only: the pin/user offsets need the anchor frame's live
-- rect, so they snap later in applyContainerLayout. Read-site fallback defaults
-- (the `or 32` / `or 4` in the consumers) stay raw — every real config sets
-- these fields explicitly. Idempotent via the _ppQuantized flag, so repeated
-- adoption passes (ApplyStyle then a rebuild) are safe.
local PP_QUANT_FIELDS = { "size", "sizeX", "sizeY", "spacing", "spacingX", "spacingY" }
local function quantizeLayout(L)
    if type(L) ~= "table" then return L end
    local q = {}
    for k, v in pairs(L) do q[k] = v end
    local scale = tonumber(L.scale) or 1
    for _, k in ipairs(PP_QUANT_FIELDS) do
        if type(q[k]) == "number" then q[k] = ppSnapScaled(q[k], scale) end
    end
    q._ppQuantized = true
    return q
end

-- Nudge the container pin offsets (<= half a pixel per axis) so the pin point
-- lands on the physical pixel grid. Computed from the ANCHOR frame's rect only —
-- never the container's own (secret-derived). Offsets live in the container's
-- scaled space: rendered px = offset x scale x (anchor-frame px-per-unit).
-- Third return = whether a real rect was used: false means the anchor frame
-- isn't laid out yet (login/reload build order — containers build BEFORE the
-- unit frames get their first layout) and the raw offsets came back untouched.
-- The CALLER must retry once the rect exists (see the re-pin hooks in
-- applyContainerLayout / Create) — a silently unsnapped pin was live-caught as
-- "one AD icon's border uneven at login, perfect after any settings toggle,
-- broken again on reload".
local function snapPinOffsets(anchorFrame, anchor, px, py, scale)
    local ok, nx, ny = pcall(function()
        local l, b = anchorFrame:GetLeft(), anchorFrame:GetBottom()
        local w, h = anchorFrame:GetWidth(), anchorFrame:GetHeight()
        local eff = anchorFrame:GetEffectiveScale()
        local _, physH = GetPhysicalScreenSize()
        if not (l and b and w and h and eff and eff > 0 and physH and physH > 0) then return end
        local s = tonumber(scale) or 1
        if s <= 0 then s = 1 end
        local ppu = eff * physH / 768   -- physical px per anchor-frame unit
        local ax = anchor:find("LEFT") and 0 or (anchor:find("RIGHT") and w) or w / 2
        local ay = anchor:find("BOTTOM") and 0 or (anchor:find("TOP") and h) or h / 2
        local rx = (l + ax + px * s) * ppu
        local ry = (b + ay + py * s) * ppu
        return px + (math.floor(rx + 0.5) - rx) / (s * ppu),
               py + (math.floor(ry + 0.5) - ry) / (s * ppu)
    end)
    if ok and nx and ny then return nx, ny, true end
    return px, py, false
end

-- ★ THE ONE PLACE A LAYOUT BOX IS PINNED TO ITS FRAME.
-- Three surfaces render aura frames — the live container, the container's own test
-- preview, and the Aura Designer's editor canvas — and all three must land the box on
-- the same physical pixel. They used to pin it in three places; the canvas's copy was
-- the shortest (anchor-to-anchor, user offsets, nothing else) and so it silently
-- dropped BOTH corrections this returns:
--   * the CENTER-growth fold (G.pinX/pinY): centred rows pin the box's centre-of-edge,
--     not its corner, so a corner pin sits up to half an icon out.
--   * the pixel-perfect nudge (snapPinOffsets), which is computed from the anchor
--     frame's EFFECTIVE SCALE — so the error changed with the UI scale, and at some
--     scales the unsnapped value happened to land on-grid and looked correct. Reported
--     as "the AD preview does not match live frames... UI scale might be partly to
--     blame" (2026-08-13); the reporter was reading a real symptom of this.
-- ☠ Returns the pin rather than applying it: applyContainerLayout must wrap its own
-- SetPoint in a pcall and stamp _ppDbg, so the CALLER still owns the write.
local function resolveLayoutPin(L, anchorFrame, pp)
    local G = resolveGrowthLayout(L)
    local scale = tonumber(L.scale) or 1
    local px = (L.offsetX or 0) + G.pinX
    local py = (L.offsetY or 0) + G.pinY
    local resolved = true
    if pp then
        px, py, resolved = snapPinOffsets(anchorFrame, G.anchor, px, py, scale)
    end
    return G, px, py, scale, resolved
end

-- ☠ THE LINE CAP MUST ALLOW FOR RECORD-STYLED CELLS, WHICH ARE BIGGER THAN `sx`.
-- The flow wraps when the running row width exceeds the cap, and it measures each button's
-- ACTUAL width — but the cap was built from the plain cell size alone. An important debuff
-- renders at `debuffImportantScale` (default 1.25), so a row containing one overruns its cap
-- by (scale-1)*sx against only half an icon of rounding slack, and the flow wraps a whole
-- icon early: "Icons Per Row" set to 3 lays out 2+1. Reported as the debuff preview
-- mis-flowing (Aphoex 7); it is equally wrong on live frames, the preview is just where you
-- see it. Returns the slack to add to the cap: rounding headroom plus the widest styled
-- cell's overhang.
-- ☠☠ CLAMPED, AND THE CLAMP IS THE WHOLE SAFETY ARGUMENT. Slack must stay strictly under
-- one full extra cell (`sx + spX`), or a row of PLAIN icons — the case where the styled aura
-- simply is not up right now — would fit one more icon than the user asked for. Widening a
-- cap can only ever cause that failure, so the bound is what makes this safe rather than a
-- trade of one bug for another.
local function flowLineSlack(sx, spX, records)
    local styleExtra = 0
    if type(records) == "table" then
        for _, r in ipairs(records) do
            local st = type(r) == "table" and r.style
            local s = st and tonumber(st.scale)
            if s and s > 1 then
                local e = (s - 1) * sx
                if e > styleExtra then styleExtra = e end
            end
        end
    end
    -- Half an icon absorbs pixel rounding and the border inset; see the note this replaces.
    return math.min(sx * 0.5 + styleExtra, sx + spX - 0.5)
end

local function applyContainerLayout(c, handle)
    local config = handle.config
    local L = config.layout or {}
    local G, px, py, scale, pinResolved = resolveLayoutPin(L, handle.frame, handle._pp)
    local sx = G.sx
    local spX = G.spX
    local wrap = tonumber(L.wrap) or 0

    -- Row cap: vertical-primary = one per row (column); wrap>0 = N per row; else unlimited.
    -- HEADROOM: the flow (AnchorUtil.ApplyFlowLayout) wraps when the running row width
    -- exceeds rowWidth, measuring the button's ACTUAL width — which lands a fraction over
    -- our `sx` (pixel rounding + border inset). A tight +0.5 slack let that fraction wrap
    -- one icon early. Half an icon of headroom absorbs the rounding yet stays well under
    -- the (sx + spX) a whole extra icon would need — so exactly `wrap` icons fit per row.
    -- ★ Slack now also covers a record-styled cell's overhang — see flowLineSlack.
    local headroom = flowLineSlack(sx, spX, config.filter)
    local rowWidth
    if G.verticalPrimary then
        rowWidth = sx + headroom
    elseif wrap and wrap >= 1 then
        rowWidth = wrap * sx + (wrap - 1) * spX + headroom
    end   -- nil -> math.huge (no wrap) inside SetFlowLayoutMaximumLineSize (né SetAuraLayoutRowWidth)

    -- Strip reservation, start-side inset (see stripReservation): only when the strip
    -- faces the flow's vertical start. Padding is config-derived, live (MarkDirty
    -- AuraFrameLayout) and counted into the container's self-size, so CENTER-growth
    -- edge pinning stays centred over the reserved box. The call is SKIPPED unless
    -- padding is (or ever was) non-zero on this container — no-bar/fill containers
    -- keep the exact pre-strip native call sequence; _dfPadApplied clears a stale
    -- inset if a live restyle flips the strip to the far side (or to fill).
    local resv, topStrip = stripReservation(config)
    if resv > 0 and handle._pp then resv = ppSnapScaled(resv, scale) end
    local padTop, padBottom = 0, 0
    if resv > 0 then
        if G.vName == "Up" then
            if not topStrip then padBottom = resv end
        elseif topStrip then
            padTop = resv
        end
    end

    -- Pin offsets (user offset + growth fold + pp nudge) come from resolveLayoutPin
    -- above, hoisted to the top of this function so the preview surfaces can ask the
    -- same question without a handle.
    -- /df debug ppdump ground truth: the last pin decision this handle rendered with.
    handle._ppDbg = { px = px, py = py, resolved = pinResolved, anchor = G.anchor, pin = G.pinPoint, scale = scale }

    pcall(function()
        c:SetScale(scale)
        -- Pin the container to the frame's anchor point + offsets. Directional
        -- growth: the grow-corner pins to the frame's matching point (SetPoint
        -- offsets live in the container's scaled space, matching the legacy rows
        -- whose offsets rode the scaled buttons). CENTER growth: the box's
        -- centre-of-edge pins instead (see resolveGrowthLayout).
        c:ClearAllPoints()
        c:SetPoint(G.pinPoint, handle.frame, G.anchor, px, py)
    end)

    -- Flow-layout family: 68914 renamed SetAuraLayout* -> SetFlowLayout* (RowWidth
    -- -> MaximumLineSize, same nil = no-wrap contract; padding is growth-relative,
    -- which matches the padTop/padBottom branches above — the named side IS the
    -- flow's vertical start in both used cases). The pre-68914 SetAuraLayout* names
    -- are GONE from the engine (zero hits in the 69111 source), so the dual-detect
    -- fallbacks that used to sit here were dead and have been removed.
    -- Each call stays protected SEPARATELY: pre-68914 this rode the pin pcall above,
    -- so the rename made the first layout call throw and silently dropped
    -- growth/wrap/padding for the whole row.
    -- Stashed for the SINGLE-SLOT row path: the flow does not lay slots out, so
    -- build() pins its one button at the corner the flow would have placed
    -- element 1 at. Kept here so there is ONE derivation of the corner.
    handle._flowAnchor = G.flowAnchor
    -- ...and the STRIP RESERVATION with it. The reservation reaches a group button
    -- as flow-layout PADDING (setFlowPadding below), which the flow applies to
    -- element 1 — a hand-pinned slot button never sees it, so it has to be folded
    -- into the pin offset instead. Only one of the two can be non-zero (the branch
    -- above is exclusive), and the anchor corner always matches the growth
    -- direction, so the difference carries the right sign in WoW's y-up space:
    -- top strip on downward growth pushes the icon DOWN (-padTop), bottom strip on
    -- upward growth pushes it UP (+padBottom).
    handle._flowPadY = padBottom - padTop
    local setFlowAnchor  = c.SetFlowLayoutAnchorPoint
    local setFlowGrowth  = c.SetFlowLayoutGrowthDirection
    local setFlowMaxLine = c.SetFlowLayoutMaximumLineSize
    local setFlowPadding = c.SetFlowLayoutPadding
    if setFlowAnchor then pcall(setFlowAnchor, c, G.flowAnchor) end
    if setFlowGrowth and AnchorUtil and AnchorUtil.FlowDirection then
        local h = resolveEnum(AnchorUtil.FlowDirection, G.hName)
        local v = resolveEnum(AnchorUtil.FlowDirection, G.vName)
        if h ~= nil and v ~= nil then pcall(setFlowGrowth, c, h, v) end
    end
    if setFlowMaxLine then pcall(setFlowMaxLine, c, rowWidth) end
    if setFlowPadding and (padTop > 0 or padBottom > 0 or c._dfPadApplied) then
        c._dfPadApplied = (padTop > 0 or padBottom > 0) or nil
        pcall(setFlowPadding, c, 0, 0, padTop, padBottom)
    end

    -- PIN RETRY (live-caught): at login/reload the containers build BEFORE the
    -- unit frames' first layout — the anchor rect is nil, the pin snap above
    -- no-ops, and that one container renders off-grid until any settings pass
    -- happens to re-run the layout. Poll (self-terminating, one per anchor
    -- frame, hidden frames don't tick) until the rect resolves, then re-run
    -- this whole layout so the snap lands. Guarded against a torn-down /
    -- rebuilt container so a stale closure can't relayout a dead one.
    if handle._pp and not pinResolved then
        local f = handle.frame
        local tries = 0
        f:SetScript("OnUpdate", function(fr)
            tries = tries + 1
            local live = handle.backend and handle.backend.container == c
            -- GetLeft on our plain window is expected non-secret; guard anyway —
            -- truthiness on a secret number is the 12.1 taint trap.
            -- ☠ The SECRET CHECK MUST COME FIRST. This read `gl and issecretvalue(gl)`,
            -- which truthiness-tests gl before establishing it is safe to touch — the exact
            -- trap the line above warns about, one line under the warning. issecretvalue(nil)
            -- is safe (Blizzard's own RestrictedInfrastructure does `pos = tonumber(pos)`
            -- then `issecretvalue(pos)` with no nil guard), so the leading test bought
            -- nothing. The `issecretvalue and` short-circuit stays for older clients.
            local gl = fr:GetLeft()
            if issecretvalue and issecretvalue(gl) then gl = nil end
            if not live or gl or tries > 600 then
                fr:SetScript("OnUpdate", nil)
                if live and gl then applyContainerLayout(c, handle) end
            end
        end)
    end
end

-- Per-group layout options (stride/spacing). groupSpacing stays 0: the flow
-- advances its cursor by width + elementSpacing after EVERY element — including
-- a group's last — and then adds groupSpacing ON TOP before the next group
-- (AnchorUtil.ApplyFlowLayout), so any non-zero value renders group boundaries
-- at spacing + groupSpacing. The original gap = spacing DOUBLED the gap between
-- filter blocks on multi-filter rows (and between every button of the per-slot
-- test rows) — live-reported. With 0, groups still continue on the same row,
-- uniformly spaced. (68914 rewrote the flow but kept these additive semantics.)
--
-- 68914 also RENAMED the keys: elementSpacingX/elementSpacingY/gapX ->
-- elementSpacing (primary axis) / lineSpacing (cross axis, applied on wrap) /
-- groupSpacing. Unknown keys are silently dropped, never rejected
-- (CopyAndValidateInboundTable merges over defaults and validates known keys
-- only), so we carry BOTH families and each build reads its own.
-- A per-record style that scales its buttons needs the GROUP's layout cell scaled to
-- match, or the bigger icon overlaps its neighbour: the button size and the flow's
-- reserved cell are separate things. Returns the base table unchanged when there is
-- nothing to scale, so callers can pass the result straight through.
-- The flow-layout cell for ONE record: the container's shared cell plus whatever
-- that record overrides. Three things can move it:
--
--   * scale — the important-debuff step. A bigger BUTTON does not widen its cell, so
--     without this the scaled icon overlaps its neighbour.
--   * size — a member carrying its own icon size (Aura Designer group members each do).
--   * layoutIndex — ☠ WHERE MEMBER ORDER COMES FROM. Blizzard sorts the flow groups by
--     layoutIndex and falls back to registration order only as a tiebreak
--     (SortFlowLayoutDescriptions / GetEffectiveFlowLayoutIndex in
--     Blizzard_CustomAuraContainer.lua). Setting it explicitly is what makes an AD group
--     render in the order the user arranged it, instead of in whatever order we happened
--     to register the members — and it keeps that order as members come and go, because
--     an empty group contributes no elements and no spacing.
local function recordGroupLayout(base, style)
    if not base or not style then return base end
    local sc, sz = style.scale, style.layout and style.layout.size
    if (not sc or sc == 1) and not sz and style.layoutIndex == nil then return base end
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    if sz then out.elementWidth, out.elementHeight = sz, sz end
    if sc and sc ~= 1 then
        if out.elementWidth then out.elementWidth = out.elementWidth * sc end
        if out.elementHeight then out.elementHeight = out.elementHeight * sc end
    end
    if style.layoutIndex ~= nil then out.layoutIndex = style.layoutIndex end
    return out
end

local function buildGroupLayout(config)
    local L = config.layout or {}
    local sx = (L.sizeX or L.size or 32)
    local sy = (L.sizeY or L.size or sx)
    local spX = (L.spacingX or L.spacing or 4)
    local spY = (L.spacingY or L.spacing or 4)
    -- pp (quantized layout): the reservation joins elementHeight, so it must be
    -- whole-pixel too or every row stride goes fractional again. _ppQuantized is
    -- the adoption-time pp marker (no handle in scope here).
    local resv = stripReservation(config)
    if resv > 0 and L._ppQuantized then resv = ppSnapScaled(resv, tonumber(L.scale) or 1) end
    return {
        elementWidth    = sx,
        -- + strip reservation: elementHeight overrides the measured button height in
        -- the flow (GetElementSize), so the row stride and the container self-size
        -- both grow by the strip's out-of-rect space (0 for fill / no bar). The
        -- start-side inset half of the reservation lives in applyContainerLayout.
        elementHeight   = sy + resv,
        elementSpacing  = spX,   -- 68914+
        lineSpacing     = spY,   -- 68914+
        groupSpacing    = 0,     -- 68914+ (see header comment)
        elementSpacingX = spX,   -- pre-68914 twin
        elementSpacingY = spY,   -- pre-68914 twin
        gapX            = 0,     -- pre-68914 twin
    }
end

-- One button's placement, guarded by the caller.
--
-- ☠ ENGINE-OWNED BUTTONS CAN TURN FORBIDDEN UNDER US. Addons stopped creating AuraButtons
-- at PTR-4 (see the header at the top of this file), so every entry in handle.buttons
-- belongs to the client, and it can reclaim or re-initialise a slot's subtree at any point
-- -- after which SetScale/SetPoint on that button throw "Attempt to access forbidden object
-- from code tainted by an AddOn". Dispel.lua's ProbeSlotArt and TextDesigner/Render.lua's
-- mirrorWrite already carry this guard for their own art; this is it for the row layout.
--
-- ★ THE COST OF NOT GUARDING WAS THE WHOLE ROW, NOT ONE ICON. The throw unwound out of the
-- MIDDLE of layoutRow's loop, so every button after the forbidden one was left unpositioned.
-- Reported in game as "no debuffs showing" after switching the debuff filter to All Debuffs
-- inside a key (Krathe, 2026-08-20). Guarding per button costs one icon instead.
--
-- Declared once rather than inlined as a closure so the pcall stays allocation-free on this
-- per-button-per-pass path -- same reasoning as ProbeSlotArt.
local function placeButton(b, scale, anchor, parent, x, y)
    b:SetScale(scale)
    b:ClearAllPoints()
    b:SetPoint(anchor, parent, anchor, x, y)
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
    local stepX, stepY = DF:ResolveAuraLayoutStep(sx, sy, spX, spY, scale, L.preScaledStep)
    for i, b in ipairs(handle.buttons) do
        local idx = i - 1
        local col = idx % wrap
        local row = math.floor(idx / wrap)
        local x = (L.offsetX or 0) + (pAxis.x * col + sAxis.x * row) * stepX
        local y = (L.offsetY or 0) + (pAxis.y * col + sAxis.y * row) * stepY
        -- pp: whole-pixel offsets relative to the (grid-snapped) anchor frame.
        -- Offsets here live in the BUTTON's scaled space (b:SetScale below).
        if handle._pp then
            x = ppSnapScaled(x, scale)
            y = ppSnapScaled(y, scale)
        end
        if not pcall(placeButton, b, scale, anchor, handle.frame, x, y) and not warnedLayout then
            warnedLayout = true
            DF:DebugWarn(DBG, "layoutRow: slot %d refused placement (forbidden subtree?)", i)
        end
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
-- container's flow layout (applyContainerLayout translates onto SetFlowLayout*); overlay slots are
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
-- An EMPTY container is NOT zero-sized: AnchorUtil.ApplyFlowLayout reports
-- math.max(layoutWidth, 1) to OnLayoutComplete, and the secure SetSize floors
-- every empty container at 1x1 units (Blizzard_SharedXMLBase/AnchorUtil.lua,
-- 12.1; padding defaults are all 0 so the floor always wins when empty). The
-- parked missing badge rides the container's TOPLEFT = pin - selfWidth, so that
-- 1 unit re-entered the badge position as a FRACTIONAL-pixel drift (1 unit is
-- rarely a whole physical pixel) — field-caught as the missing badge's border
-- rendering thicker on one side under pixel perfect, surviving every other
-- quantization fix. Compensate it EXACTLY in the badge offset; the push's
-- evacuation margin becomes MISSING_PAD - MISSING_EMPTY_W (= 1 unit, still
-- clear of the window even with the animation spill, which cancels out).
local MISSING_EMPTY_W = 1

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
    -- Which topology this container was BUILT with. Parking keys off this rather than
    -- the current _testMode flag: entering the preview rebuilds while _testMode is
    -- already true, and the container being retired at that moment is the LIVE one --
    -- exactly the one worth parking, since leaving the preview asks for it straight back.
    self.builtInTestMode = AuraContainer._testMode and true or false
    -- ☠ The structural key THIS container was built with, captured here and never read
    -- from the handle at park time. Handle:Rebuild writes the INCOMING key to
    -- _structKey before _rebuild runs, so a park that keyed off the handle would file
    -- the outgoing container under the new key -- and the next rebuild to that key would
    -- re-adopt a container built for a different structure. Silent and total.
    self.structKey = handle._structKey
    AuraContainer.stats.builds = AuraContainer.stats.builds + 1
    -- Deafen to Blizzard's Edit Mode provider switch FIRST, before anything else can
    -- fire (see EDIT-MODE DEAFENING). Every build gets its own fresh container, so
    -- this has to be re-applied here rather than once. Inverted while OUR test mode
    -- is on: that preview needs to hear the bounce.
    setContainerProviderDeaf(c, not AuraContainer._testMode)
    -- Capability probe only; records the client's answer, changes nothing.
    AuraContainer._probeEditModeSource(c)
    local isOverlay = config.mode == "overlay"
    local isMissing = config.mode == "missing"
    -- SINGLE-SLOT ROW. A row that can only ever show ONE icon declares an AuraSlot
    -- instead of an AuraGroup: AddAuraGroup hardcodes batchSize =
    -- CustomAuraContainerConstants.FrameCreationBatchSize and calls CreateFrameBatch()
    -- BEFORE maxFrameCount is applied, so a max=1 group created a full batch of
    -- buttons to display one icon. AddAuraSlot calls CreateAuraSlotFrame once.
    -- Selection is NOT degraded: RegisterAuraSlot builds an auraComparator from
    -- sortMethod/sortDirection, so the slot shows the same best-ranked match.
    --
    -- ☠ OPT-IN ONLY, never inferred from max == 1. AD filter groups derive their max
    -- from group.maxIcons, which is USER-TUNABLE in place via ApplyTuning — a group
    -- that happened to sit at 1 would become slot-backed and a later 1 -> 4 edit
    -- would silently fail, because a slot cannot grow and the tuning path has no
    -- group to re-max. Keying off an explicit flag keeps container TOPOLOGY
    -- independent of any tuning value.
    local isSingleSlot = config.singleSlot and not isOverlay and not isMissing
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
        local setFlowAnchor = c.SetFlowLayoutAnchorPoint
        if setFlowAnchor then pcall(setFlowAnchor, c, "TOPLEFT") end
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
    -- ☠ _genCounter is MONOTONIC and never reused; _gen is merely "which generation is
    -- live right now". They are separate because container parking RESTORES an older
    -- _gen when it re-adopts (Handle:_readoptParked): the parked container's groups
    -- permanently hold initializeFrame closures that captured the gen they were declared
    -- with, and buttons are created in lazy batches LONG after build, so a re-adopted
    -- container whose gen was not restored would silently no-op every later button.
    -- Reusing a raw counter would let a re-adopted gen collide with a newer container's;
    -- monotonic issue makes every generation token globally distinct for this handle.
    handle._genCounter = (handle._genCounter or 0) + 1
    handle._gen = handle._genCounter
    local initFn = handle:_makeInitializeFrame(handle._gen)

    -- Declare one AuraGroup per filter (row) / one AuraSlot per filter (overlay). The
    -- container is exclusively ours, so keys need no cross-consumer namespacing. Group
    -- keys are remembered so ApplyStyle can hot-apply per-group layout and ApplyTuning
    -- can hot-apply max/sort/candidateFilters (all live mutators).
    local filters = normalizeFilters(config.filter)
    -- ☠ SINGLE-SLOT means exactly ONE slot. The declaration loop below runs per
    -- filter record, and every slot it declares pins to the same corner -- so a
    -- multi-record config would stack its buttons on top of each other where the
    -- group path would have flowed them side by side. No current consumer can hit
    -- this (poolFilter returns one string, which normalizeFilters turns into one
    -- record), but the flag's name promises something the loop does not enforce.
    -- Fall back to groups rather than render wrong: correct output, no saving.
    if isSingleSlot and #filters ~= 1 then
        DF:DebugWarn(DBG, "singleSlot config has %d filter records; using groups", #filters)
        isSingleSlot = false
    end
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
    -- booleans) — evaluated Blizzard-side per group/slot, derived per record via
    -- recordCandidateFilters (shared with applyGroupTuning). ⚠ Spell-ID maps only apply
    -- on units the player can assist (helpful) / attack (harmful) — a harmful spell-ID
    -- map on a friendly-frame consumer is silently inert (the Meorawr gate). Changing
    -- the config-wide set is live-tunable (ApplyTuning). A record's OWN cf is also
    -- live-tunable via the consumer pre-swap pattern (see ApplyTuning's header):
    -- the caller replaces config.filter with a GROUP-IDENTICAL list (record strings +
    -- keys pinned by its structural sig, only cf differs), then applyGroupTuning
    -- re-derives per-record cf from it. Changing the filter SET itself (strings/keys/
    -- record count) is structural -> Rebuild.
    -- Native sort (rows only): declared at AddAuraGroup here, re-tunable live via
    -- applyGroupTuning — one shared derivation (deriveSort).
    -- ★ NO testMode FORK. Row order is RENDERING, and a preview must render through the
    -- live pathway -- it may differ in DATA only. With the sort skipped, live rows came
    -- out in the container's sort order and preview rows in declaration order, so the Sort
    -- setting could not be judged from the preview at all.
    --
    -- Safe to run for test containers: deriveSort is pure config -- it reads config.sort
    -- and the two AuraContainerSort* enum tables and touches no unit or aura data. Unlike
    -- the other test forks in this file (per-slot groups, the window-parked missing badge,
    -- disabled containers) this one carried no stated engine reason, which is what marked
    -- it out as an oversight rather than a constraint.
    local sortMethod, sortDirection = deriveSort(config)
    self.groupKeys = {}
    self.gatedGroupKeys = nil   -- rebuilt below, per group (identity park set)
    -- key -> the record style that group was built with. applyLayout re-pushes group
    -- layouts on every restyle and would otherwise reset a scaled group's cell back to
    -- the shared size, so it needs to know which groups are scaled.
    self.groupStyles = {}
    -- key -> native slot button (consumer styling). Overlay AND single-slot rows:
    -- both declare AuraSlots, and both need the button reachable by key afterwards.
    self.slotButtons = (isOverlay or isSingleSlot) and {} or nil
    handle._idGateVulnerable = nil   -- re-derived from this build's records (see the record loop)
    handle._idGateSourceRelative = nil   -- PLAYER-token / isFromPlayerOrPlayerPet pools (visibility gate)
    -- ★ OWN-FRAME PREVIEW (see Handle:_buildOwnPreview). When on, test mode declares
    -- NOTHING to the engine and paints our own frames instead, so the global sample
    -- provider is never switched and no other addon's containers are disturbed.
    -- The per-slot-group shape below is the engine route, kept behind the toggle so
    -- the two can be compared side by side in game (/df debug ownpreview).
    if testMode and AuraContainer._ownTestPreview and not isOverlay and not isMissing then
        -- RECORD STYLES (important-debuff highlight / layout-group members) die with
        -- the real records, so lift them BEFORE the wipe — the same capture as the
        -- engine route below, same two shapes: all records styled = a layout group
        -- (slot k wears member k's style), else the single-styled-slot A/B against
        -- plain neighbours. Dropping this capture was the own-preview regression:
        -- the important-debuff highlight vanished from test mode entirely (field
        -- report 2026-08-14). _buildOwnPreview resolves slot k's style from this.
        -- ☠ THE DISTINCTNESS TERM — see the long note on the engine route below. Two records
        -- sharing ONE importantStyle table satisfied "all styled" and enlarged every slot.
        local testStyles, allStyled, stylesDiffer = {}, true, false
        for _, r in ipairs(filters) do
            if r.style then
                testStyles[#testStyles + 1] = r.style
                if testStyles[1] ~= r.style then stylesDiffer = true end
            else
                allStyled = false
            end
        end
        local perSlotStyles = (allStyled and stylesDiffer and #testStyles > 1) and testStyles or nil
        -- Assigned UNCONDITIONALLY (nil when no styles): the pooled preview slots
        -- persist across rebuilds, so a rebuild with the highlight switched off must
        -- clear the previous build's styles or they would re-stamp forever.
        handle._ownPreviewStyles = (perSlotStyles or testStyles[1]) and {
            perSlot = perSlotStyles,
            single  = (not perSlotStyles) and testStyles[1] or nil,
        } or nil
        filters = {}   -- declare nothing; the loop below is skipped
    elseif testMode and not isOverlay and not isMissing then
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
        -- IMPORTANT-DEBUFF PREVIEW. Test mode replaces the real records with one group
        -- per slot, so a record's style would be thrown away with them and the
        -- highlight would be invisible in the preview — which is the one place you can
        -- actually sit still and position the badge. Capture it before the wipe and
        -- hand it to the first slots, so the preview shows both treatments side by side
        -- (styled slot 1-2, plain slot 3+) exactly as a live row would.
        -- ☠ TWO SHAPES OF STYLED ROW, and they want opposite previews.
        --
        -- Important Debuffs styles ONE record among plain ones, so a single styled icon
        -- against plain neighbours is both a direct A/B for positioning and an honest
        -- picture of a live row, where importants are the minority. Styling several made
        -- the preview look like the whole row was highlighted.
        --
        -- A LAYOUT GROUP is the mirror image: every record is styled and each one
        -- differently, because each is a member with its own indicator look. Picking
        -- "the first styled record" there would paint member 1's style on one icon and
        -- leave the rest plain — a preview that differs from live in RENDERING rather
        -- than in data, which is the one thing a preview may never do.
        --
        -- So: all records styled, more than one, AND THE STYLES ACTUALLY DIFFER => per-slot,
        -- slot k wears member k's style. Otherwise the original single-styled-slot
        -- behaviour, unchanged.
        --
        -- ☠☠ THE DISTINCTNESS TERM IS LOAD-BEARING AND WAS MISSING. "Every record styled"
        -- was meant to identify a LAYOUT GROUP, where each member carries its OWN look. The
        -- debuff row can satisfy it by accident: `bossrole` and `priority` are the only two
        -- records that take a style and they take THE SAME `importantStyle` TABLE, so
        -- ticking Boss and/or Role together with Priority — and nothing else — made
        -- `allStyled` true with two entries and put the enlarged, badged important treatment
        -- on BOTH preview slots instead of one styled against a plain neighbour. At the test
        -- Debuffs count of 2 that is the whole row. Reported as the debuff preview "bugging
        -- out" on particular checkbox combinations (Aphoex 7); the enormous icons in the
        -- screenshots are this, and the mis-wrap beside it is the flow cap below.
        -- ⚠ Identity, not deep-compare: two members with coincidentally equal looks are
        -- still two members and must stay per-slot.
        -- ☠ MIRRORED IN THREE PLACES — the own-preview route above, this engine route, and
        -- the Indicator Info probe in DandersFrames_Options/TestMode/Labels.lua, which
        -- measures the region and must agree with what renders. Change one, change all three.
        local testStyles, allStyled, stylesDiffer = {}, true, false
        for _, r in ipairs(filters) do
            if r.style then
                testStyles[#testStyles + 1] = r.style
                if testStyles[1] ~= r.style then stylesDiffer = true end
            else
                allStyled = false
            end
        end
        local perSlotStyles = (allStyled and stylesDiffer and #testStyles > 1) and testStyles or nil
        local testStyle = testStyles[1]
        local testStyleSlots = (not perSlotStyles) and (testStyle and math.min(1, maxCount) or 0) or 0
        local testStyleLayout = recordGroupLayout(groupLayout, testStyle)
        filters = {}   -- the normal declaration loop below is skipped
        -- ☠ ONE GROUP PER PREVIEW SLOT, maxFrameCount = 1, fixedIndex = k. RESTORED
        -- 2026-08-06 after the two-group split broke the preview outright.
        --
        -- This is the ONLY shape that makes position and content agree. Groups render
        -- in DECLARATION order, so group k occupies layout position k, and its single
        -- button paints curated entry k. Icon, stack count, duration and hover zone all
        -- derive from the same k, so they cannot drift apart.
        --
        -- ☠ DO NOT COLLAPSE THESE INTO A SHARED GROUP TO SAVE FRAMES. That was
        -- b69239ac, and it shipped in alpha-15 as a preview showing the wrong icon
        -- under every tooltip. Inside a shared group the flow assigns auras to buttons
        -- in the CONTAINER's order, which is NOT creation order, while the curated
        -- entry is chosen by a counter incremented at button-CREATION time -- so entry
        -- k lands wherever the flow happened to put that button. The comment this
        -- replaces described that exact failure ("landed them on the wrong buttons --
        -- live-diagnosed twice: Lightning Shield mid-row, mismatched tooltips") and
        -- then judged the tooltip half "moot now that tooltips are forced off in test
        -- mode". The NATIVE tooltips are off; DF's own hover zones are not, and they
        -- are keyed by the curated index. Confirmed in game by reverting to the build
        -- before that commit and comparing side by side.
        --
        -- ⚠ THE COST IS REAL AND ACCEPTED. Every AddAuraGroup eagerly creates
        -- FrameCreationBatchSize (10) buttons before maxFrameCount is applied, so this
        -- is maxCount x 10 frames per container -- the allocation b69239ac set out to
        -- remove (~530 MB across four toggles at 40 test frames, ~1 s per toggle).
        -- Krathe's call: "we need our test mode icons and tooltips correct, or they are
        -- pointless." A cheaper shape has to keep position-to-entry determinism or it
        -- is not a preview, it is a lie. The pool cap in _slotCount claws some of it
        -- back by not declaring slots the curated pool cannot fill (the defensive row
        -- drops from ten groups to four).
        if isSingleSlot then
            -- SINGLE-SLOT ROW preview. The two-group split above exists to pin a
            -- styled icon AHEAD of plain ones in a multi-icon row; this row has
            -- exactly one icon, so it declares the same single AuraSlot the live
            -- path does and paints curated entry 1 into it. fixedIndex = 1 (not
            -- the handle-wide counter) because there is only ever one button and
            -- its paint must be deterministic across rebuilds.
            local okSlot, btn = pcall(c.AddAuraSlot, c, "dfTestSlot", category,
                { initializeFrame = handle:_makeInitializeFrame(handle._gen, 1, nil, testStyle) })
            if okSlot and btn then
                -- Same strip-reservation fold as the live pin below: the preview
                -- must sit where the live icon sits, and _positionTestTip already
                -- applies this inset to the hover zone — without it the zone and
                -- the icon would disagree by the reservation in test mode.
                local fa = handle._flowAnchor or "TOPLEFT"
                pcall(btn.ClearAllPoints, btn)
                pcall(btn.SetPoint, btn, fa, c, fa, 0, handle._flowPadY or 0)
                self.slotButtons["dfTestSlot"] = btn
            elseif not okSlot then
                DF:DebugWarn(DBG, "test slot failed: %s", tostring(btn))
            end
        else
            for k = 1, maxCount do
                local key = "dfTest" .. k
                -- Per-slot style when the row is a layout group (member k's own look),
                -- else the single-styled-slot A/B. Nil for a plain slot either way.
                local slotStyle = perSlotStyles and perSlotStyles[k]
                    or ((k <= testStyleSlots) and testStyle or nil)
                local slotLayout = perSlotStyles and recordGroupLayout(groupLayout, slotStyle)
                    or ((k <= testStyleSlots) and testStyleLayout or groupLayout)
                -- pcall(fn, args...) rather than pcall(function() ... end): no wrapper
                -- closure per group. Protection is unchanged — AddAuraGroup asserts.
                local okGroup, err = pcall(c.AddAuraGroup, c, key, category, {
                    maxFrameCount = 1,
                    initializeFrame = handle:_makeInitializeFrame(handle._gen, k, nil, slotStyle),
                    layout = slotLayout,   -- groupSpacing = 0 (buildGroupLayout) = uniform spacing
                })
                if okGroup then
                    self.groupKeys[#self.groupKeys + 1] = key
                    self.groupStyles[key] = slotStyle
                else
                    DF:DebugWarn(DBG, "test group failed: %s", tostring(err))
                end
            end
        end
    end
    for i, rec in ipairs(filters) do
        local f = rec.f
        local cf = (not testMode) and recordCandidateFilters(rec, config) or nil
        -- NOT gated on `cf`: filterVulnerableToIdentityGate's OTHER branch is the
        -- spell-CATEGORY token case (BIG_DEFENSIVE / EXTERNAL_DEFENSIVE), which is
        -- precisely the defensive row's empty-selection fallback -- and that config
        -- carries NO candidateFilters. Requiring cf here made that branch dead, so a
        -- cleared defensive selection went ungated and filled with ordinary buffs on
        -- a cross-faction unit. The function is nil-safe on cf.
        if filterVulnerableToIdentityGate(f, cf) then
            handle._idGateVulnerable = true
        end
        if filterSourceRelative(f, cf) then
            handle._idGateSourceRelative = true
        end
        if AuraUtil and AuraUtil.IsValidFilterString and not AuraUtil.IsValidFilterString(f) then
            DF:DebugWarn(DBG, "filter rejected by IsValidFilterString: %s (group skipped)", tostring(f))
        else
            local key = rec.key or ("df" .. i)
            if isOverlay then
                -- Per-slot init when the consumer supplied an onInit hook (overlay
                -- dispel carriers) so it can create+bind SetAuraBorder in secure
                -- context; else the shared initFn.
                local slotInit = rec.onInit and handle:_makeInitializeFrame(handle._gen, nil, rec.onInit) or initFn
                local okSlot, btn = pcall(c.AddAuraSlot, c, key, f,
                    { initializeFrame = slotInit, candidateFilters = cf,
                      sortMethod = sortMethod, sortDirection = sortDirection })
                if okSlot and btn then
                    pcall(btn.SetAllPoints, btn, handle.frame)
                    self.slotButtons[key] = btn
                    -- ☠ PARK KEYS AT BIRTH, mirroring the group branch. The tuning path
                    -- rebuilds this set, but tuning only runs after something changes — a
                    -- slot-backed handle built while trusted would meet its FIRST trust
                    -- loss with no gated keys, and the hide fallback (gated on
                    -- _hasGatedGroups()==false) would blank the whole handle on exactly
                    -- the transition the park exists to narrow.
                    if filterVulnerableToIdentityGate(f, cf) then
                        self.gatedGroupKeys = self.gatedGroupKeys or {}
                        self.gatedGroupKeys[key] = true
                    end
                elseif not okSlot then DF:DebugWarn(DBG, "AddAuraSlot failed: %s", tostring(btn)) end
            elseif isSingleSlot then
                -- Same declaration as the overlay branch, different GEOMETRY: an
                -- overlay button covers the whole host, a row button is icon-sized
                -- and sits where the flow would have put element 1.
                local slotInit = (rec.style or rec.onInit)
                    and handle:_makeInitializeFrame(handle._gen, nil, rec.onInit, rec.style)
                    or initFn
                local okSlot, btn = pcall(c.AddAuraSlot, c, key, f,
                    { initializeFrame = slotInit, candidateFilters = cf,
                      sortMethod = sortMethod, sortDirection = sortDirection })
                if okSlot and btn then
                    -- Size is NOT set here: styleButton_regions sizes every button
                    -- from the shared config, group-backed or not, so the icon comes
                    -- out identical. Only the position the flow would have supplied
                    -- has to be replaced.
                    local fa = handle._flowAnchor or "TOPLEFT"
                    pcall(btn.ClearAllPoints, btn)
                    pcall(btn.SetPoint, btn, fa, c, fa, 0, handle._flowPadY or 0)
                    self.slotButtons[key] = btn
                    -- Park keys at birth — see the overlay branch above for why.
                    if filterVulnerableToIdentityGate(f, cf) then
                        self.gatedGroupKeys = self.gatedGroupKeys or {}
                        self.gatedGroupKeys[key] = true
                    end
                elseif not okSlot then
                    DF:DebugWarn(DBG, "AddAuraSlot (single-slot row) failed: %s", tostring(btn))
                end
            else
                -- A record carrying its own style (or an onInit) needs its OWN init
                -- closure — initFn is shared across every group and would apply the
                -- override to all of them. Its layout cell is widened to match the
                -- scaled button, or the bigger icon overlaps the next group along.
                local groupInit, recLayout = initFn, groupLayout
                if rec.style or rec.onInit then
                    groupInit = handle:_makeInitializeFrame(handle._gen, nil, rec.onInit, rec.style)
                    recLayout = recordGroupLayout(groupLayout, rec.style)
                end
                local okGroup, err = pcall(c.AddAuraGroup, c, key, f,
                    { maxFrameCount = maxCount, initializeFrame = groupInit,
                      layout = recLayout, candidateFilters = cf,
                      sortMethod = sortMethod, sortDirection = sortDirection })
                if okGroup then
                    self.groupKeys[#self.groupKeys + 1] = key
                    self.groupStyles[key] = rec.style
                    -- Remember which groups the identity park applies to. Per KEY, so
                    -- token records stay live while the identity-dependent ones park.
                    -- ☠ THE PREDICATE IS `filterVulnerableToIdentityGate`, i.e. exactly the
                    -- records whose filters the ENGINE can skip: HELPFUL pools carrying
                    -- include/excludeSpellIDs. It used to be RecordIdentityGated -- four
                    -- category booleans on the DEBUFF row -- which the engine applies
                    -- unconditionally (Blizzard_AuraContainerUtil: only the two spell-ID
                    -- keys sit inside CanApplyIdentityCandidateFilters). Those booleans
                    -- also fail CLOSED in both directions -- the test is an equality, so an
                    -- unpopulated field rejects rather than passes -- so there was never a
                    -- leak for that park to prevent, only rows it could empty by mistake.
                    self.gatedGroupKeys = self.gatedGroupKeys or {}
                    self.gatedGroupKeys[key] = filterVulnerableToIdentityGate(f, cf) or nil
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
    -- ★ Own-frame preview needs neither: it declares nothing to the engine, so there
    -- is no container to feed and no reason to touch the global provider.
    -- ☠ THE GUARD IS ON THE BOUNCE, NOT ON THE ROW SHAPE. First cut wrote this as
    -- "own-preview AND a row" / "elseif testMode", which still bounced for OVERLAY
    -- and MISSING containers -- and one bounce is a GLOBAL switch, so a single dispel
    -- overlay building during test mode re-filled every other addon's containers and
    -- the leak looked untouched. Neither of those two needs the sample source anyway:
    -- MISSING deliberately stays disabled for the whole test session so its groups
    -- never fill, and the dispel overlay takes its preview type from our own pool
    -- (DF:GetTestDebuffDispelType), not from engine auras.
    if testMode and AuraContainer._ownTestPreview then
        if not isOverlay and not isMissing then
            handle:_buildOwnPreview()
        end
    elseif testMode then
        AuraContainer._queueTestBounce()
    end

    -- MISSING mode: arm the push geometry — hook the badge onto the live container's
    -- TOPLEFT (+pad puts it exactly on the window while the group is empty) and show it.
    -- The badge's rect now derives from the container's SECRET size: render-side only,
    -- never read its position in Lua (no pixel-snap, no GetLeft) — §20c rules.
    if isMissing and handle.badge then
        -- Centre the badge in the (badge + 2*spill) window: the -MISSING_PAD container pin
        -- and the +MISSING_PAD badge inset still cancel to park it on the window when empty;
        -- the +spill / -spill centres it inside the enlarged window.
        -- _badgeParkDebug (/df debug ppbadge): force the WINDOW anchor live — the parked badge
        -- position then can't inherit the empty container's SECRET (and field-measured
        -- fractional) self-width. DIAGNOSTIC ONLY: the layout-push cannot move a
        -- window-anchored badge, so presence no longer hides it while the flag is on.
        local sp = (handle.config.badge and handle.config.badge.spill) or 0
        handle.badge:ClearAllPoints()
        if testMode or AuraContainer._badgeParkDebug then
            -- P5 preview: the container stays DISABLED all test session (the
            -- bounce skips missing mode) and a never-laid-out container has NO
            -- resolvable rect (its secret SetSize only runs while enabled) — a
            -- badge anchored to it renders NOTHING (live-caught). Park the
            -- badge on the WINDOW instead: that IS the "missing" position.
            handle.badge:SetPoint("TOPLEFT", handle.frame, "TOPLEFT", sp, -sp)
        else
            -- +MISSING_EMPTY_W: cancel the empty container's 1-unit size floor so the
            -- parked badge lands EXACTLY at window TOPLEFT + spill (see the constant).
            handle.badge:SetPoint("TOPLEFT", c, "TOPLEFT", MISSING_PAD + sp + MISSING_EMPTY_W, -sp)
        end
        handle.badge:Show()
    end

    DF:Debug(DBG, "built (native) unit=%s mode=%s groups=%d",
        tostring(config.unit), tostring(config.mode or "row"), #filters)

    -- ★ WHAT DID EACH GROUP ACTUALLY BUILD WITH? The line above reports only the
    -- group COUNT, which cannot tell a correctly filtered row from one that fell
    -- through FilterRegistry:ResolveSelection's "nothing selected -> show
    -- everything" fallback -- that path sets NO includeSpellIDs at all and renders
    -- every helpful aura. It is the shape of the v4->v5 first-login reports ("all
    -- buffs until I toggle something"), and it is invisible in a log that says
    -- groups=1 either way. include=none vs include=<n> is the whole diagnosis.
    --   ⚠ Behind DebugActive, not DF:Debug alone: counting the maps is O(entries)
    -- and a caller's arguments are evaluated BEFORE Debug can short-circuit, so an
    -- unguarded count would cost on every build with logging off.
    --
    -- ⚠ NOISE BUDGET. Containers are per FRAME, so a 40-man rebuild would emit
    -- several hundred of these and push everything else out of a 10k-line log --
    -- and AURACONTAINER is not a `noisy` category, so it is ON for anyone who turns
    -- debug on for an unrelated bug. The detail is therefore limited to the cases
    -- that are actually diagnostic:
    --   * the PLAYER's own frame — always small, always the one being asked about;
    --   * ANY unit whose row looks WRONG — a HELPFUL pool with no include map is the
    --     fail-open signature this exists to catch, so it must never be suppressed.
    -- Everything else keeps the one-line summary above.
    --   ☠ The DebugActive gate comes FIRST, before the anomaly scan — that scan is
    -- cheap but it is still work, and running it on every build with logging off is
    -- exactly the cost this whole block is guarded to avoid.
    if DF.DebugActive and DF:DebugActive(DBG) then
        -- ☠ MIRROR THE ENGINE'S RESOLUTION ORDER wherever this reads a group's
        -- filters: `rec.candidateFilters or config.candidateFilters`. Reading the
        -- record alone was a real blind spot — the BUFF row passes a plain filter
        -- STRING plus CONFIG-LEVEL filters, so it logged "no-cf" and looked exactly
        -- like the unfiltered bug being hunted, on the row that matters most. The
        -- DEBUFF row builds per-record filters, so that half read correctly and
        -- disguised the gap.
        local function cfOf(rec) return rec.candidateFilters or config.candidateFilters end

        -- Is this build worth the full breakdown? (See the noise budget above.)
        local detail = (config.unit == "player")
        if not detail then
            for _, rec in ipairs(filters) do
                local cf = cfOf(rec)
                if type(rec.f) == "string" and rec.f:find("HELPFUL", 1, true)
                    and not (cf and cf.includeSpellIDs) then
                    detail = true   -- the fail-open signature; never suppress it
                    break
                end
            end
        end

        if detail then
            local function countOf(m)
                if type(m) ~= "table" then return "none" end
                local c = 0
                for _ in pairs(m) do c = c + 1 end
                return tostring(c)
            end
            for gi, rec in ipairs(filters) do
                local cf  = cfOf(rec)
                -- `cf=` names which source won: rec / cfg / - (neither).
                local src = rec.candidateFilters and "rec"
                    or (config.candidateFilters and "cfg" or "-")
                DF:Debug(DBG, "  group %d key=%s filter=%s cf=%s include=%s exclude=%s",
                    gi, tostring(rec.key), tostring(rec.f), src,
                    cf and countOf(cf.includeSpellIDs) or "no-cf",
                    cf and countOf(cf.excludeSpellIDs) or "no-cf")
            end
        end
    end

    -- Initial identity-gate state for this build's unit (see _applyIdentityGate);
    -- the module watcher re-evaluates on faction/phase/roster/world changes.
    handle:_applyIdentityGate()
    -- ☠ AND THE DEATH LATCH, which the gate above does NOT cover. The latch is edge-driven
    -- from Frames/Update.lua's dead/alive transitions, so a container built after the death
    -- edge has passed comes up unlatched and nothing re-latches it -- the next
    -- SetUnitDeathLatched(unit, true) fires only on a NEW death, and the unit is already
    -- dead. Reload beside a ghost and every row came back. See AuraContainer._deathLatchedUnits.
    local dlu = handle.config and handle.config.unit
    if dlu and AuraContainer._deathLatchedUnits[dlu]
        and not (handle.config and handle.config.parentDrivenVisibility) then
        pcall(function() handle:_setDeathLatch(true) end)
    end
    -- Same reasoning for the cinematic latch: CineLatchAll only reaches what exists at
    -- CINEMATIC_START, so a build during one must latch itself. Vulnerable-only, matching
    -- CineLatchAll's own scope; the STOP sweep and its fallback timer clear it.
    if AuraContainer._cineActive and handle._idGateVulnerable
        and not (handle.config and handle.config.parentDrivenVisibility) then
        pcall(function() handle:_setCineLatch(true) end)
    end
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
    -- SINGLE-SLOT ROW: the flow does not move slot buttons, so the pin build()
    -- made has to be re-made here or a growth/anchor change would leave the icon
    -- at the old corner while the container moved under it. applyContainerLayout
    -- has just refreshed handle._flowAnchor, so this reads the new corner. Size is
    -- still styleButton_regions' job (ApplyStyle re-runs it right after this).
    if self.slotButtons and self.handle.config.singleSlot then
        local fa = self.handle._flowAnchor or "TOPLEFT"
        local py = self.handle._flowPadY or 0
        for _, btn in pairs(self.slotButtons) do
            pcall(btn.ClearAllPoints, btn)
            pcall(btn.SetPoint, btn, fa, c, fa, 0, py)
        end
    end
    if self.groupKeys and c.SetAuraGroupLayout then
        local groupLayout = buildGroupLayout(self.handle.config)
        for _, key in ipairs(self.groupKeys) do
            -- Per-group, NOT one shared table: a group whose record scales its buttons
            -- needs its layout CELL scaled to match. Pushing the shared layout to every
            -- key reset the scaled group's cell to the base width, so on a restyle the
            -- bigger icon overlapped its neighbour — while a full rebuild looked right,
            -- because AddAuraGroup got the scaled layout there. Button size and reserved
            -- cell are separate things and both have to be re-pushed.
            local gl = recordGroupLayout(groupLayout, self.groupStyles and self.groupStyles[key])
            pcall(c.SetAuraGroupLayout, c, key, gl)
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

-- Hot-apply TUNING (maxFrameCount / sort / candidateFilters) to the LIVE container's
-- groups — the in-place path that replaces teardown+recreate on a tuning-only delta
-- (each recreate = visible flicker + a stranded button set; WoW never GCs frames).
-- All three natives are live mutators (68569 source: SetAuraGroupMaxFrameCount /
-- SetAuraGroupSortMethod MarkDirty(AuraFrameAssignments); SetAuraGroupCandidateFilters
-- runs UpdateAllAuras). Row mode only — overlay/missing guard mirrors applyLayout;
-- slot-mode tuning (SetAuraSlot* setters) is a deferred follow-up. Callers combat-gate
-- this (ApplyTuning defers to regen in lockdown): no native tuning setter ever runs
-- in combat.
function NativeBackend:applyGroupTuning()
    local c = self.container
    if not c then return end
    local mode = self.handle.config.mode
    -- ☠ MISSING mode stays on the Rebuild path. Its layout-push inversion is
    -- load-bearing and hard-won (the badge only clears the clip window because ONE
    -- blank button's layout CELL pushes it out), and a live candidateFilters swap
    -- changes exactly which buttons exist. Nothing has exercised that combination, so
    -- it is left alone rather than enabled blind.
    if mode == "missing" then return end
    -- Test mode declares its own groups with curated paint stamped per button at create
    -- (a styled group pinned first, then one shared plain group) — tuning them in place
    -- would not re-stamp that paint. Handle:ApplyTuning rebuilds the preview instead, so
    -- this path is never reached in test mode; guard anyway.
    if AuraContainer._testMode then return end
    -- OVERLAY declares AuraSLOTs, not groups, so groupKeys is empty and the group
    -- setters have nothing to act on — it needs the slot-side setters instead. The
    -- cfByKey derivation below is shared: build() keys slots and groups identically
    -- (rec.key or positional "df<i>"), so the same map serves both.
    -- SINGLE-SLOT ROWS declare AuraSlots too, so they take the slot-side setters for
    -- exactly the same reason: groupKeys is empty and the group setters have nothing
    -- to act on. ☠ Without this a spell-map edit on a placed indicator would silently
    -- no-op — include/excludeSpellIDs ride the TUNING signature, not the struct one,
    -- so they never re-enter build(), and the indicator would keep the old spell list
    -- until some unrelated change happened to rebuild it.
    local usesSlots = mode == "overlay" or self.handle.config.singleSlot
    if usesSlots then
        if not (self.slotButtons and c.SetAuraSlotCandidateFilters) then return end
    elseif not (self.groupKeys and c.SetAuraGroupMaxFrameCount) then
        return
    end
    local config = self.handle.config
    local maxCount = self.handle:_slotCount()
    -- SetAuraGroupSortMethod validates BOTH args as enum members (nil asserts), so an
    -- unset/unresolved sort maps back to the AddAuraGroup inbound defaults
    -- (Default/Normal) — clearing a previously-set sort actually clears.
    local sortMethod, sortDirection = deriveSort(config)
    if sortMethod == nil and _G.AuraContainerSortMethod then
        sortMethod = _G.AuraContainerSortMethod.Default
    end
    if sortDirection == nil and _G.AuraContainerSortDirection then
        sortDirection = _G.AuraContainerSortDirection.Normal
    end
    -- Per-group candidateFilters: re-derive the SAME records build declared. The
    -- KEY SET is structural and unchanged on this path, so keys line up with
    -- self.groupKeys (rec.key or positional "df<i>").
    local cfByKey = {}
    -- ★ FILTER STRINGS ride here too (2026-08-04). They used to be creation-frozen,
    -- which put them in every consumer's STRUCT signature and made "Only Mine",
    -- AD "Others Only" and the dispel All/By-Me swap cost a whole teardown+recreate
    -- for a string change. SetAuraGroup/SlotFilterString are live mutators
    -- (Blizzard_CustomAuraContainer.lua:355 / :423) and destroy nothing.
    -- ☠ WHAT IS STILL STRUCTURAL: the KEY SET. AddAuraGroup/AddAuraSlot are add-only
    -- with no remove, so a record appearing or disappearing (the debuff category
    -- toggles) still needs a Rebuild — only a same-key STRING move is tunable.
    -- Consumers must keep record keys in their struct sig; the mismatch warn below
    -- catches one that does not.
    -- Verified in game 2026-08-04 (DF_AuraLab /alfilter): 10 swaps cost 0 frames on
    -- the tuned path vs 100 stranded on the rebuild control, button identity and the
    -- native duration bindings both survive, and a swap does NOT re-fire
    -- initializeFrame — so nothing needing a re-style may move here.
    local fsByKey = {}
    -- ★ RE-DERIVE THE IDENTITY-GATE VERDICT. include/excludeSpellIDs live in the
    -- TUNING signature, not the struct one, so every setting that flips a pool's
    -- gate exposure -- Show All Buffs, a filter-category selection, missing-buff
    -- hide-from-bar, defensive dedupe -- lands HERE and never re-enters build().
    -- The flag used to be written only in build(), and IdentityGateSweep only
    -- visits handles already flagged, so a handle that BECAME vulnerable was never
    -- reconsidered: on a cross-faction unit (UnitCanAssist false) the gate fails
    -- open and an "only these spells" row renders every buff. Recompute from the
    -- records this call is about to push, then re-apply.
    local wasVulnerable = self.handle._idGateVulnerable
    local wasSourceRel  = self.handle._idGateSourceRelative
    self.handle._idGateVulnerable = nil
    self.handle._idGateSourceRelative = nil
    -- ☠ REBUILT HERE TOO, or a string-only delta leaves the park set describing the
    -- PREVIOUS filters. Same reason the vulnerability flag is recomputed on this path:
    -- filter strings can now change without a rebuild, and the park keys off the string.
    self.gatedGroupKeys = nil
    for i, rec in ipairs(normalizeFilters(config.filter)) do
        local key = rec.key or ("df" .. i)
        local cf = recordCandidateFilters(rec, config)
        cfByKey[key] = cf
        fsByKey[key] = rec.f
        -- The gate verdict reads the filter STRING as well as the candidate filters,
        -- so a string-only delta has to land here — which is exactly what moving
        -- filter strings onto this path makes possible. (Before, a string change
        -- always rebuilt, and build() recomputed the flag.)
        if filterVulnerableToIdentityGate(rec.f, cf) then
            self.handle._idGateVulnerable = true
            -- ★ THE PARK SET IS THE SAME VERDICT, PER KEY. One record being vulnerable
            -- used to mark the whole HANDLE and hide every row it owned; now only the
            -- records the engine can actually skip go dark, and their token siblings
            -- keep rendering.
            self.gatedGroupKeys = self.gatedGroupKeys or {}
            self.gatedGroupKeys[key] = true
        end
        if filterSourceRelative(rec.f, cf) then
            self.handle._idGateSourceRelative = true
        end
    end
    -- pcall(fn, args...) not pcall(function() ... end): the closure form allocated THREE
    -- closures per group key per tuning pass. Protection is unchanged.
    --
    -- Ordering note (Blizzard source): SetAuraGroupMaxFrameCount and
    -- SetAuraGroupSortMethod only MarkDirty, and dirty flags coalesce into one
    -- ProcessDirtyFlags on the next OnUpdate — so those are near-free however many
    -- groups there are. SetAuraGroupCandidateFilters runs an immediate UpdateAllAuras
    -- per call and has no equality guard of its own, so a container with N groups pays
    -- N full updates here. There is no batch setter; the only real lever is declaring
    -- fewer groups.
    --
    -- ☠ FILTER-STRING ORDERING: push the string BEFORE candidateFilters. Both setters
    -- end in UpdateAllAuras, but the string one also runs RebuildAuraParseFilters, so
    -- doing it first means the candidate pass runs against the CURRENT parse filters
    -- rather than one generation behind. Unlike the candidateFilters setter it carries
    -- its own equality guard (source :357 / :427), so pushing an unchanged string every
    -- pass is genuinely free — no need to diff it consumer-side.
    -- A key the container does not have makes GetRequiredAuraGroup/Slot assert; that
    -- means a consumer let a KEY-SET change reach the tuning path, which is a bug in
    -- that consumer's struct sig. pcall keeps it from taking the frame down, and the
    -- mismatch warn below names it instead of failing silently.
    local fsMissing
    if usesSlots then
        -- A slot is a single button: no maxFrameCount and no layout to push, so only
        -- the filter string, candidate filters and the sort (which decides WHICH aura
        -- wins the one slot) are tunable. Same nil-CLEARS semantics as the group setter.
        for key in pairs(self.slotButtons) do
            if fsByKey[key] and c.SetAuraSlotFilterString then
                -- ★ IDENTITY PARK, slot flavour. A slot has no maxFrameCount, so the park
                -- is an EMPTY filter string — the same lever SlotHandle:_pushFilter uses,
                -- and the one other 12.1 implementations use for it. Without this the park
                -- reached group-backed rows only, and a slot-backed row kept falling back
                -- to the whole-handle hide it is meant to replace.
                -- ⚠ Same park string as SlotHandle:_pushFilter, and it must stay the same.
                -- Two writers pushing different "parked" values means whichever ran last
                -- decides, and one of them would be the string the engine no longer treats
                -- as a park. See SLOT_PARK_FILTER for why "" was retired.
                local parked = self.handle._idGateParked
                    and self.gatedGroupKeys and self.gatedGroupKeys[key]
                if not pcall(c.SetAuraSlotFilterString, c, key,
                    parked and AuraContainer.SLOT_PARK_FILTER or fsByKey[key]) then
                    fsMissing = fsMissing or key
                end
            end
            pcall(c.SetAuraSlotCandidateFilters, c, key, cfByKey[key])
            if sortMethod ~= nil and sortDirection ~= nil and c.SetAuraSlotSortMethod then
                pcall(c.SetAuraSlotSortMethod, c, key, sortMethod, sortDirection)
            end
        end
    else
        for _, key in ipairs(self.groupKeys) do
            if fsByKey[key] and c.SetAuraGroupFilterString then
                if not pcall(c.SetAuraGroupFilterString, c, key, fsByKey[key]) then
                    fsMissing = fsMissing or key
                end
            end
            -- ★ IDENTITY PARK, per group. maxFrameCount 0 empties one group and leaves
            -- its siblings rendering -- the surgical alternative to hiding the whole row,
            -- which is what makes this safe on the DEBUFF row where only some records
            -- depend on identity data.
            local parked = self.handle._idGateParked
                and self.gatedGroupKeys and self.gatedGroupKeys[key]
            pcall(c.SetAuraGroupMaxFrameCount, c, key, parked and 0 or maxCount)
            -- nil CLEARS: the inbound copy runs over an EMPTY defaults table, so a
            -- toggled-off filter set doesn't survive (the old Rebuild-merge lesson).
            pcall(c.SetAuraGroupCandidateFilters, c, key, cfByKey[key])
            if sortMethod ~= nil and sortDirection ~= nil then
                pcall(c.SetAuraGroupSortMethod, c, key, sortMethod, sortDirection)
            end
        end
    end
    if fsMissing and not warnedFilterString then
        warnedFilterString = true
        DF:DebugWarn(DBG, "filter-string tune rejected for key '%s' (mode=%s) — a consumer let a KEY-SET change onto the tuning path; that must stay structural.",
            tostring(fsMissing), tostring(mode))
    end
    -- ★ PARTITION KICK (same mechanism as applyLayout): the inbound mutators mark
    -- dirty but cannot ARM the private-side processor — without the bounce the change
    -- lands one aura event late. OOC-only path, but guard anyway (Show re-arms the
    -- parse, same op class as enable).
    if not InCombatLockdown() then
        pcall(function() c:Hide(); c:Show() end)
    end
    -- Re-apply the gate whenever this call CHANGED the verdict. Cheap and
    -- combat-safe (plain frame visibility), but skipped when nothing moved so a
    -- routine tuning pass does not churn handle visibility.
    if self.handle._idGateVulnerable ~= wasVulnerable
        or self.handle._idGateSourceRelative ~= wasSourceRel then
        pcall(function() self.handle:_applyIdentityGate() end)
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
-- ★ RETURNS WHETHER A REAL RE-PARSE HAPPENED, and the distinction is the whole point.
-- Only the Hide/Show bounce makes the engine re-read candidateFilters; UpdateAllAuras
-- repaints from the candidate set it ALREADY has, which is exactly the set that is wrong
-- when a pool has fallen open. Callers that only want "nudge the display" can keep
-- ignoring the result; the identity gate's recovery must not (see _noteGateRecovery).
function NativeBackend:refresh()
    local c = self.container
    if not c then return false end
    if not InCombatLockdown() then
        return pcall(function() c:Hide(); c:Show() end)
    elseif type(c.UpdateAllAuras) == "function" then
        pcall(function() c:UpdateAllAuras() end)
    end
    return false
end

-- The container is OURS (per-consumer): teardown is disable, drop its buttons, hide, release
-- the ref. The next build creates a fresh container
-- (topology is add-only — no RemoveAuraGroup/Slot — so recreate IS the sanctioned removal).
-- Callers gate teardown out of combat (Destroy/_rebuild defer to regen in lockdown).
-- park = true: PARKING teardown (see Handle:_parkContainer). The container is quiesced
-- exactly as a real teardown quiesces it -- disabled so it stops registering for aura
-- events, hidden so it draws nothing -- but its frames are NOT released and the backend
-- keeps its container/slotButtons references, because a matching rebuild is going to
-- re-adopt this exact object. Releasing here would throw away the button set, which is
-- the entire saving.
function NativeBackend:teardown(park)
    local c = self.container
    if c then
        AuraContainer.stats.teardowns = AuraContainer.stats.teardowns + 1
        pcall(function() c:SetEnabled(false) end)
        -- ☠ There is NO public way to release a container's buttons. RemoveAllAuraFrames
        -- was guarded for here and never existed -- zero hits across the whole 69111
        -- Interface source -- so that branch never once ran. The provider's ReleaseFrame
        -- is real but lives on AuraContainerCustomFrameProviderMixin, which is private
        -- and unreachable from the inbound surface. Disable + hide is therefore the
        -- WHOLE of teardown, and a discarded container keeps every button it ever
        -- created for the session. That is precisely why parking exists.
        pcall(function() c:Hide() end)
    end
    if not park then
        self.container = nil
        self.slotButtons = nil   -- buttons die with the container; consumers re-fetch per drive
    end
end

-- The curated preview pool for a container config. Shared so the SLOT COUNT and the
-- PAINT agree on one answer: they used to resolve it independently, and the count could
-- ask for more icons than the pool has entries.
--
-- ☠ A PLAIN FUNCTION OF CONFIG, NOT A Handle METHOD, AND THAT IS LOAD-BEARING.
-- AuraContainer.PaintPreviewSlot drives the paint core with a DUCK-TYPED handle --
-- literally `{ config = config }`, no metatable -- because the AD editor canvas paints
-- slots it owns outright, with no container behind them. Anything the paint path reaches
-- for via `self:` is therefore nil there. This was first written as `Handle:_testPool`
-- and broke opening the Aura Designer instantly ("attempt to call a nil value").
-- Keep every shared preview helper a function OF CONFIG for the same reason.
local function testPoolFor(config)
    local recs = normalizeFilters(config.filter)
    local harmful = recs[1] and recs[1].f:find("HARMFUL")
    local td = DF.TestData
    -- config.testEntries carries per-container curated entries (the Aura Designer's
    -- placed indicators preview their own configured spell); config.testPool names a
    -- curated TestData pool for rows whose category filter alone would mispreview (the
    -- defensive row is HELPFUL but must show defensives, not raid buffs). Falls back to
    -- the category pools.
    return config.testEntries
        or (td and ((config.testPool and td[config.testPool])
        or (harmful and td.debuffs or td.buffs)))
end

-- How many sample icons this preview draws. A function OF CONFIG for the same reason
-- testPoolFor is (PaintPreviewSlot's duck-typed handle has no methods) — and shared so
-- the slot count and the rotation step can never disagree about the window size.
local function testSlotCount(config, pool)
    local n = config.testMax
        and math.min(config.testMax, config.max or config.testMax)
        or (config.max or 1)
    if pool and #pool > 0 then n = math.min(n, #pool) end
    return math.max(1, n)
end

-- ★ PER-FRAME POOL ROTATION — why every frame used to show the same two icons.
--
-- The pools hold ten entries but a preview only draws as many as the count slider
-- allows, and every container asked for indices 1..N, so all five party frames drew
-- entries 1 and 2 and the other eight were never seen by anyone. Rotating the START
-- per frame shows the whole pool at once across a group.
--
-- ☠ DETERMINISTIC, NOT RANDOM. `math.random` here would re-roll on every repaint, and
-- the preview repaints on any restyle — icons would churn while you drag a slider,
-- which reads as a rendering bug. The unit token is stable for a frame's whole life
-- (TestFramePool stamps "raid7"/"party2"/"player"), so it is the seed.
--
-- ☠ THE STEP IS THE ICON COUNT, NOT 1 AND NOT A FIXED PRIME. Stepping by 1 makes
-- neighbours overlap almost entirely (frames showing 1-2, 2-3, 3-4…). Stepping by the
-- COUNT tiles the pool instead: at 2 icons, five party frames take 1-2, 3-4, 5-6, 7-8,
-- 9-10 — the whole pool on screen at once, nothing repeated. A fixed prime was tried
-- first and measured worse (8 of 10 entries, 2 repeats), because coprime-ness spreads
-- the STARTS without stopping the windows overlapping.
--
-- The fallback matters though: stepping by the count degenerates when the count divides
-- the pool too evenly — at 5 icons over 10 entries the offsets are 0,5,0,5,0 and every
-- other frame is identical, which is the exact complaint this is fixing. distinct starts
-- = poolSize / gcd(step, poolSize), so when that drops below 4 fall back to 7, which is
-- coprime with both live pool sizes (10 rows, 4 defensives) and therefore always spreads.
--
-- ⚠ NEVER rotates config.testEntries. Those are the Aura Designer's OWN configured
-- spells for that indicator, not a sample pool — rotating them would preview a spell
-- the user did not choose.
local function gcd(a, b)
    while b ~= 0 do a, b = b, a % b end
    return a
end

local function testPoolOffset(config, poolSize, count)
    if config.testEntries or not poolSize or poolSize < 2 then return 0 end
    local u = config.unit
    if type(u) ~= "string" then return 0 end
    local n = tonumber(u:match("(%d+)$")) or 0   -- "player" has none -> 0
    local step = math.max(1, count or 1)
    -- ☠ SCRAMBLE THE SLOT, DO NOT WALK IT. When the count divides the pool the windows
    -- tile into `slots` disjoint runs, and handing them out as (n * step) makes the offset
    -- PERIODIC IN n with period `slots`. Raid frames lay out 5 across, so with 5 slots
    -- every unit in a column drew the identical window — Krathe: "there is still entire
    -- columns that carry each type". The same periodicity lit two ADJACENT party frames
    -- instead of three spread out.
    -- Walking the slots by (slots - 1) is coprime with `slots` at any size, so it still
    -- visits every slot exactly once; the floor(n / slots) term shifts each row so the
    -- sequence stops aligning with the grid. Offsets stay on the same disjoint runs, so
    -- the dispel density that rides on that tiling is unchanged.
    if poolSize % step == 0 and (poolSize / step) >= 2 then
        local slots = poolSize / step
        return (((n * (slots - 1)) + math.floor(n / slots)) % slots) * step
    end
    if poolSize / gcd(step, poolSize) < 4 then step = 7 end
    return (n * step) % poolSize
end

local Handle = {}
Handle.__index = Handle

function Handle:_slotCount()
    local mode = self.config.mode
    if mode == "overlay" or mode == "missing" then return 1 end
    -- Test mode: the preview honours the test panel's count slider (config.testMax),
    -- still capped by the row's own max — mirrors the legacy painter's min() chain.
    --
    -- ☠ AND BY THE CURATED POOL. The preview paints one distinct sample per slot, so
    -- asking for more slots than the pool holds cannot produce more distinct icons —
    -- it can only repeat, and repeats read as a rendering bug rather than as "we ran
    -- out of samples". The defensive pool holds FOUR entries against a row that
    -- happily previews eight or more; the debuff pool holds ten against an eleven-icon
    -- row, whose last slot landed back on entry 1 and duplicated the styled slot.
    -- Confirmed from the debug log 2026-08-06: idx=11 over a 10-entry debuff pool, and
    -- the defensive pool cycling 1-4 across ten indices.
    --
    -- Capping HERE rather than clamping only in the painter is what actually fixes it:
    -- the count decides how many buttons the flow lays out, so an uncapped count draws
    -- duplicate icons no matter what the painter does with the index.
    if AuraContainer._testMode then
        return testSlotCount(self.config, testPoolFor(self.config))
    end
    return self.config.max or 1
end
-- Forward-declared: both are defined further down (next to the initializeFrame
-- factory they were written for) but _acceptSlot below must call them.
-- Without this declaration the names inside _acceptSlot would resolve to GLOBALS,
-- read nil at runtime and the call would error — legal Lua that parses clean.
local applyRecordStyle
local styleConfigFor

function Handle:_acceptSlot(slot, index, recStyle)
    self.buttons[index] = slot                 -- cache first (mirror of the pre-split order)
    -- Remember the per-record style ON the button. initializeFrame passes it once at
    -- create; every later restyle (ApplyStyle, a settings drag, hiding and re-showing
    -- auras) re-enters here WITHOUT it, and styleButton_regions unconditionally resets
    -- the button to the shared config size. Re-applying from the stash is what makes the
    -- override survive — before this, toggling auras off/on or dragging the Size Step
    -- slider silently reverted the important icons to normal size until a full rebuild.
    if recStyle ~= nil then slot.dfImpRecStyle = recStyle end
    -- Member records style from their OWN config view; everything else from the
    -- container's. One pass either way — see styleConfigFor.
    styleButton_regions(slot, styleConfigFor(self, slot))   -- source-agnostic region creation/styling
    applyRecordStyle(slot, self, slot.dfImpRecStyle)
end
function Handle:_bindNativeSlot(slot)
    -- ☠ THE RECORD'S CONFIG HERE TOO, not the container's. The duration FORMATTER is
    -- bound natively, so colour-by-time, the format choice and the hide-above band all
    -- arrive through this call — bind from the shared config and a member's icons
    -- silently inherit the GROUP's duration spec while their regions correctly carry
    -- their own. Styling and binding are two halves of one button and must read the
    -- same config, or the button is half-dressed by each.
    bindNative(slot, styleConfigFor(self, slot))   -- native setters (native slots only)
end
-- Countdown text for the test preview. The row's OWN duration formatter renders
-- it whenever one is configured — the same object the live native binding uses —
-- so format (Number/Short/Full), the colour-by-time buckets (|cff escapes) and
-- the hide-above-threshold blank band all mirror live exactly. Plain fallback
-- ("14s"/"10m") only when the row runs Blizzard's default formatting.
-- `button` is optional but should always be passed where one exists: the preview
-- countdown must use THAT button's duration spec, not the container's. Colour by
-- time lives in the formatter, so reading the shared spec here showed a layout
-- group's members counting down in the group's colours instead of their own — the
-- test-mode twin of the native-binding split, one layer along, because the preview
-- PAINTS its text where live BINDS it.
local function formatTestDuration(handle, rem, button)
    local cfg = (button and styleConfigFor(handle, button)) or handle.config
    local durSpec = cfg.style and cfg.style.duration
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

-- NATIVE test countdown. Test mode has no aura to bind, so it used to FAKE the
-- countdown on a shared ticker. It doesn't have to: C_DurationUtil.CreateDuration
-- and CreateDurationTextBinding are addon-callable, and every consumer setter is
-- AllowedWhenUntainted — which our DF-owned test widgets are. So we build a real
-- duration object and hand it to the SAME three consumers the live path uses:
--   bar   -> StatusBar:SetTimerDuration        (live: SetDurationBar -> ApplyDurationBar)
--   swipe -> Cooldown:SetCooldownFromDurationObject
--   text  -> our own DurationTextBinding, options mirrored 1:1 from bindNative
-- The C side then drives all three per-frame with ZERO Lua per frame; the only Lua
-- left is one re-arm per aura cycle (scheduleTestRearm). Live-verified on 68824 via
-- /al nativetimer: bars sweep, text honours the binding's own updateInterval, the
-- loop survives a MUTATE-ONLY re-arm (the native side holds a reference, so
-- SetTimeFromStart alone restarts everything), and a colour curve applies smoothly.
-- Returns true when the slot is natively driven; false = caller keeps the ticker.
-- Drive a PREVIEW FontString from a duration spec exactly as a live row is driven: one
-- DurationTextBinding, the shared formatter selection, the shared Duration object. Live
-- rows reach the same configuration through SetDurationText's binding template; anywhere
-- we own the fontstring (test-mode slots, the editor canvas) comes through here instead
-- of hand-rolling it.
--   fs        the FontString to drive
--   durSpec   the SAME spec the live path builds (never a preview-only variant)
--   dur       a C_DurationUtil Duration; pass a slot's own object to keep a companion
--             reveal in lockstep with its icon's countdown, as they are live
--   store/key where the binding is cached, so repeated paints reuse one binding
-- Returns true when the binding is live, false when C_DurationUtil is unavailable.
function AuraContainer.BindDurationTextPreview(fs, durSpec, dur, store, key)
    if not (fs and durSpec and dur) then return false end
    if not (C_DurationUtil and C_DurationUtil.CreateDurationTextBinding) then return false end
    local b = store and store[key]
    if not b then
        b = C_DurationUtil.CreateDurationTextBinding()
        if store then store[key] = b end
        b:SetFontString(fs)
    end
    b:SetDuration(dur)
    -- Options mirrored from bindNative's live SetDurationText block so the preview
    -- formats identically (same formatter object, same texts, same cadence). Guards
    -- match live exactly: expiredText ~= "", zeroText nil-vs-set.
    applyDurationFormatter(b, durSpec)
    if durSpec.expiredText and durSpec.expiredText ~= "" then b:SetExpiredText(durSpec.expiredText) end
    if durSpec.zeroText ~= nil then b:SetZeroDurationText(durSpec.zeroText) end
    if durSpec.updateInterval then b:SetUpdateInterval(durSpec.updateInterval) end
    -- Colour-by-time parity: the live path sends the curve through SetDurationText's
    -- textColor; here we own the binding, so set it directly. Without this the preview
    -- would render the countdown in the fontstring's plain colour while live rows ramp.
    if durSpec.colorCurve and durSpec.colorProperty ~= nil then
        b:SetTextColorCurve(durSpec.colorCurve, durSpec.colorProperty)
    end
    b:SetEnabled(true)
    return true
end

local function armTestDuration(handle, slot, d, offset)
    if not (C_DurationUtil and C_DurationUtil.CreateDuration) then return false end
    -- ☠ THE SLOT'S OWN CONFIG. This is what actually renders the test countdown —
    -- formatTestDuration below is only the fallback for a slot that fails to arm — so
    -- reading the container's shared style here is what left layout-group members
    -- counting down in white: the colour curve is part of the member's duration spec
    -- and never reached the binding.
    local cfg = styleConfigFor(handle, slot)
    local durSpec = (cfg.style and cfg.style.duration) or {}
    local barSpec = (cfg.style and cfg.style.bar) or {}
    local ok, err = pcall(function()
        local dur = slot._dfTestDurObj
        if not dur then
            dur = C_DurationUtil.CreateDuration()
            slot._dfTestDurObj = dur
        end
        -- Start in the PAST by `offset` so the preview keeps its per-slot stagger.
        dur:SetTimeFromStart(GetTime() - offset, d)

        if slot.dfBar and slot.dfBar.SetTimerDuration then
            local interp = resolveEnum(Enum and Enum.StatusBarInterpolation, barSpec.interpolation)
            local dir = resolveEnum(Enum and Enum.StatusBarTimerDirection, barSpec.direction)
            if interp == nil then interp = Enum.StatusBarInterpolation.Immediate end
            if dir == nil then dir = Enum.StatusBarTimerDirection.RemainingTime end
            slot.dfBar:SetTimerDuration(dur, interp, dir)
        end
        -- SetCooldownFromDurationObject rides the same object; the plain SetCooldown
        -- fallback keeps older builds rendering a swipe.
        if slot.dfCD then
            if slot.dfCD.SetCooldownFromDurationObject then
                slot.dfCD:SetCooldownFromDurationObject(dur)
            elseif slot.dfCD.SetCooldown then
                slot.dfCD:SetCooldown(GetTime() - offset, d)
            end
        end
        if slot.dfDur then
            AuraContainer.BindDurationTextPreview(slot.dfDur, durSpec, dur, slot, "_dfTestBinding")
        end
    end)
    if not ok then
        DF:DebugWarn(DBG, "armTestDuration failed (falling back to ticker): %s", tostring(err))
    end
    return ok
end

-- ★ PANDEMIC PREVIEW. Live, AddPandemicRegion binds the holder and the ENGINE shows it
-- inside the refresh window. A test slot paints instead of binding, so nothing drives
-- it — and simply showing it (07804854) is not a preview of a duration cue, it is a
-- permanent border on every previewed icon, which is what it turned out to be.
--
-- So drive it from the SAME fake duration everything else in the preview runs on: open
-- the window near the end of the cycle, close it when the cycle re-arms. The cue then
-- blinks in and out where a real refresh window sits, and a user can see and style it.
--
-- ⚠ THE FRACTION IS A PREVIEW CONVENTION, NOT THE GAME'S RULE. Live's window is
-- "a refresh would clip nothing", computed engine-side from the aura's own base
-- duration — DF never sees it and must never pretend to. 0.7 is chosen only because
-- the classic pandemic window is the last 30% of a buff, so the preview lands where a
-- user expects to see it. Do not wire a setting to this: it is not a threshold the
-- user owns. (Audit follow-up, 2026-08-07.)
local PANDEMIC_PREVIEW_OPEN_AT = 0.7

-- `elapsed` is how far into the cycle we already are (armTestDuration starts the
-- duration in the past by the per-slot stagger), so the first window lands in phase
-- with the bar and swipe instead of a full cycle late.
-- ☠ BOTH HOLDERS, ON ONE WINDOW. There are two pandemic cues on a slot — the icon cue
-- (dfPandemicHolder) and the BORDER twin an Aura Designer Border effect builds
-- (dfBorderPandemicHolder) — and this drove only the first. The border twin was hidden
-- once at creation with nothing to show it, so in test mode a Border effect's second
-- colour previewed as nothing while the icon cue previewed correctly. They are one
-- feature on one duration and must open and close together, or the preview says the two
-- behave differently when live drives them from the same engine window.
local function armTestPandemicWindow(handle, slot, d, gen, elapsed)
    -- ☠ WANTED, not merely PRESENT. Both holders are create-once and only hidden when the
    -- cue is switched off, so testing for the object asked "was this ever configured?"
    -- when the question is "is it configured NOW". The style pass hid the holder and this
    -- timer showed it straight back, once per fake cycle, until a reload.
    local h1 = slot._dfPandemicWanted and slot.dfPandemicHolder or nil
    local h2 = slot._dfBorderPandemicWanted and slot.dfBorderPandemicHolder or nil
    -- Anything switched off since the last pass is hidden here rather than left wherever
    -- the previous cycle happened to leave it.
    if slot.dfPandemicHolder and not h1 then slot.dfPandemicHolder:Hide() end
    if slot.dfBorderPandemicHolder and not h2 then slot.dfBorderPandemicHolder:Hide() end
    if not (h1 or h2) then return end
    local function setShown(shown)
        if h1 then h1:SetShown(shown) end
        if h2 then h2:SetShown(shown) end
    end
    setShown(false)
    if not (d and d > 0) then return end
    local openIn = d * PANDEMIC_PREVIEW_OPEN_AT - (elapsed or 0)
    if openIn <= 0 then setShown(true) return end
    C_Timer.After(openIn, function()
        -- Same gen guard as the re-arm: a repaint or teardown must not leave a stale
        -- closure showing the cue on a slot that has moved on.
        if handle._destroyed or slot._dfTestGen ~= gen then return end
        if not AuraContainer._testMode then return end
        setShown(true)
    end)
end

-- One re-arm per aura cycle, scheduled exactly at expiry — no polling. `gen` invalidates
-- pending re-arms across a repaint/teardown: every paint bumps slot._dfTestGen, and a
-- stale closure returns.
--
-- ☠ THE DURATION OBJECT DOES NOT CARRY THE SWIPE. This used to claim that mutating the
-- shared duration "restarts bar, swipe and text together (proven in the lab)". The bar and
-- text, yes -- they are bound to _dfTestDurObj. The swipe is NOT: slot.dfCD is a
-- DF-created CooldownFrame driven by SetCooldown, and nothing here re-drove it, so it ran
-- its first cycle and then sat empty while the bar kept looping ("cooldown swipe only
-- shows once, doesn't loop" -- Aphoex, 5.2.0-alpha.1). The fallback lane had always called
-- SetCooldown; only the native lane assumed the duration object covered it.
-- ⚠ Whoever verified that claim watched the bar and read the swipe's first cycle as proof.
local function scheduleTestRearm(handle, slot, d, gen, delay)
    C_Timer.After(delay, function()
        if handle._destroyed or slot._dfTestGen ~= gen then return end
        if not AuraContainer._testMode or not slot._dfTestDurObj then return end
        local ok = pcall(function() slot._dfTestDurObj:SetTimeFromStart(GetTime(), d) end)
        if ok then
            -- Re-drive the swipe on the same edge as the duration, or it loops out of step
            -- with the bar it is supposed to be showing the same countdown as.
            if slot.dfCD and slot.dfCD.SetCooldown then
                pcall(slot.dfCD.SetCooldown, slot.dfCD, GetTime(), d)
            end
            -- The cycle restarted, so the refresh window closed with it.
            armTestPandemicWindow(handle, slot, d, gen, 0)
            scheduleTestRearm(handle, slot, d, gen, d)
        end
    end)
end

-- TEST MODE paint (P5 hybrid): push DF's curated preview data onto the regions
-- styleButton_regions just built — the SAME regions the native binds would drive
-- live, so the preview is styling-true (borders, fonts, insets, swipe). Harmful
-- rows page through the debuff pool (dispel-typed edges), everything else the
-- buff pool. Regions are unbound in test mode, so their Shown state is OURS here.
function Handle:_paintTestSlot(slot, index)
    local pool = testPoolFor(self.config)
    if not pool or #pool == 0 then return end
    -- ☠ CLAMP, DO NOT WRAP. This was `((index - 1) % #pool) + 1`, which silently
    -- recycled the pool once the preview asked for more icons than it holds — the
    -- defensive pool has FOUR entries against a row that previews eight or more, so
    -- every icon past the fourth was a repeat, and an 11-icon debuff row wrapped its
    -- last slot back onto entry 1, duplicating whatever the styled slot was already
    -- showing. _slotCount caps the preview to the pool now, so an out-of-range index
    -- should be unreachable; clamping rather than wrapping means that if one ever does
    -- arrive it repeats the LAST entry visibly instead of impersonating the first.
    -- Clamp FIRST, then rotate: the clamp is the out-of-range defence above, and the
    -- rotation only moves where the pool starts for this frame. Composing them this way
    -- keeps entries distinct within a container (guaranteed while _slotCount caps the
    -- count to #pool) while differing between containers.
    local idx = math.max(1, math.min(index, #pool))
    local off = testPoolOffset(self.config, #pool, testSlotCount(self.config, pool))
    local e = pool[((off + idx - 1) % #pool) + 1]
    -- Belt-and-braces: native hover must NEVER win in test mode (it tooltips the
    -- hidden SAMPLE aura). Re-asserted every paint pass, not just at creation.
    if slot.SetMouseMotionEnabled then pcall(function() slot:SetMouseMotionEnabled(false) end) end

    -- Resolve the entry to a spell ID up front — it drives BOTH the icon and the
    -- tooltip below, so they can never disagree. THREE TIERS, in order:
    --   1. the ID whose name matches the table's English `name` (exact, enUS);
    --   2. failing that, resolve by that English name, so a STALE ID self-heals
    --      (cached per entry; the name-equality check rejects override results);
    --   3. failing that, the ID itself if the client still knows it — see below.
    -- Only a spell the client knows NOTHING about now reaches `e.icon`.
    local sid, clientName
    if e.spellID and C_Spell and C_Spell.GetSpellName then
        local ok, nm = pcall(C_Spell.GetSpellName, e.spellID)
        if ok and type(nm) == "string" and nm ~= "" then
            clientName = nm                       -- the spell AS THIS CLIENT NAMES IT
            if nm == e.name then sid = e.spellID end
        end
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

    -- ☠ THIRD TIER, AND IT IS THE ONLY REASON THIS WORKS OUTSIDE enUS. `e.name` is
    -- ENGLISH, so tier 1 (name equality) can NEVER match on a localised client and
    -- tier 2 has no localised name to look up — every entry fell through to the
    -- hardcoded `e.icon`, and 19 of those 25 paths are mangled by Lua's escape
    -- handling, so the whole preview rendered as blank squares. Shipped in v5.0.0
    -- (the 12.1 rework replaced an ID-only painter with this gate); reported on
    -- 5.1.3. If the client still knows the ID it IS the spell the curator named,
    -- so trust it and carry the client's own name with it — icon, name and tooltip
    -- move TOGETHER, the same rule the spec override below follows.
    -- ⚠ ORDERED LAST ON PURPOSE: enUS still takes tiers 1/2 exactly as before, so a
    -- stale ID there self-heals by name rather than being adopted here.
    if not sid and clientName then sid = e.spellID end

    -- Adopt the player's SPEC OVERRIDE wholesale (Krathe's call): the preview
    -- shows the spell as this spec knows it — icon, name and tooltip move
    -- TOGETHER (a 12.1 Holy priest previews Holy Fire, not Shadow Word: Pain).
    -- GetSpellTexture resolves overrides anyway; resolving explicitly here keeps
    -- all three surfaces on the same spell instead of a mixed identity.
    -- Localised when tier 3 adopted the ID (clientName is that client's own wording);
    -- e.name otherwise, which covers tier 1 (identical by definition) and tier 2
    -- (resolved BY e.name, so it is the right label).
    local dispName = (sid == e.spellID and clientName) or e.name
    if sid and C_Spell.GetOverrideSpell then
        local ok, oid = pcall(C_Spell.GetOverrideSpell, sid)
        if ok and type(oid) == "number" and oid ~= 0 and oid ~= sid then
            local ok2, onm = pcall(C_Spell.GetSpellName, oid)
            if ok2 and type(onm) == "string" and onm ~= "" then
                sid, dispName = oid, onm
            end
        end
    end

    -- Per-slot too: staticSpellID is a per-indicator icon override, so a member that
    -- pins its own art must be read from its own style, not the group's.
    local iconCfg = styleConfigFor(self, slot)
    local iconSpec = iconCfg.style and iconCfg.style.icon
    if slot.dfIcon and not (iconSpec and iconSpec.staticSpellID) then
        -- The GAME's icon for the validated spell (hand-maintained icon paths
        -- drift from the real art); the entry's hardcoded icon is the fallback.
        local tex = sid and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
        if tex or e.icon then slot.dfIcon:SetTexture(tex or e.icon) end
    end
    local barFill = 1       -- permanent aura (duration 0): full bar, never drains
    local nativeBar = false -- true = the C timer owns dfBar; SetValue must not fight it
    do
        -- Live countdown: stagger per slot AND per unit (digits of the unit token —
        -- party2's row must not mirror party1's; same per-unit-variation idea as
        -- TestMode's per-index health values) so the preview doesn't tick in unison.
        -- The stagger is applied by starting the duration `offset` seconds in the
        -- past; armTestDuration then hands it to the native bar/swipe/text drivers
        -- and scheduleTestRearm loops it. Permanent auras (duration 0) show no timer.
        local d = e.duration or 0
        if d > 0 then
            local u = self.config.unit
            local useed = (type(u) == "string" and tonumber(u:match("%d+"))) or 0
            -- ⚠ The whole-second term staggers the VALUE but NOT the phase. Every slot
            -- paints in the same frame, so with d and the offset both integral every
            -- expiry carries the same fractional part and all countdowns flip their
            -- digit on the same tick — a raid of auras ticking in lockstep, which is
            -- the one thing real auras never do. The sub-second term breaks that;
            -- scheduleTestRearm then loops on (d - offset) so they stay out of phase.
            -- 17 is coprime with the row/unit counts, so the phases don't collapse
            -- back into groups. Bounded below d: the integer part is at most d-2
            -- (d >= 2) or 0 (d == 1), and frac < 1.
            local frac = ((index * 7 + useed * 13) % 17) / 17
            local offset = (index * 3 + useed * 5) % math.max(d - 1, 1) + frac
            barFill = (d - offset) / d
            -- Invalidate any re-arm still pending from the previous paint.
            slot._dfTestGen = (slot._dfTestGen or 0) + 1
            if armTestDuration(self, slot, d, offset) then
                -- Natively driven: the C side owns bar, swipe and text from here.
                -- Nothing left for the ticker, so clear its per-slot state.
                slot._dfTestDur, slot._dfTestExpiry = nil, nil
                slot._dfTestText, slot._dfTestTextAt = nil, nil
                slot._dfTestTimed = true
                nativeBar = slot.dfBar and true or false
                -- (No swipe seed here: armTestDuration already binds slot.dfCD to the
                -- shared duration object via SetCooldownFromDurationObject, with a
                -- static SetCooldown as its own fallback. A second static SetCooldown
                -- at this point only downgraded that binding. The re-drive in
                -- scheduleTestRearm is the half that was genuinely missing.)
                armTestPandemicWindow(self, slot, d, slot._dfTestGen, offset)
                scheduleTestRearm(self, slot, d, slot._dfTestGen, d - offset)
            else
                -- FALLBACK (no C_DurationUtil / a setter threw): the faked ticker path.
                slot._dfTestDur = d
                slot._dfTestExpiry = GetTime() + (d - offset)
                -- The pandemic window is pure timing, so it works on this path too --
                -- it never touched the duration object. Only the first cycle, though:
                -- this lane has no re-arm hook, so the cue opens once and stays. Better
                -- than never showing it, and the native lane above is the real path.
                armTestPandemicWindow(self, slot, d, slot._dfTestGen, offset)
                if slot.dfCD and slot.dfCD.SetCooldown then
                    slot.dfCD:SetCooldown(GetTime() - offset, d)
                end
                -- Seed the ticker's text cache with what we just rendered, so its
                -- change-detection compares against the live string (a recycled
                -- button would otherwise carry a stale one across the rebuild).
                if slot.dfDur then
                    local s = formatTestDuration(self, d - offset, slot)
                    slot.dfDur:SetText(s)
                    slot._dfTestText, slot._dfTestTextAt = s, GetTime()
                end
                AuraContainer._startTestTicker()
            end
        else
            slot._dfTestDur = nil
            slot._dfTestText, slot._dfTestTextAt = nil, nil
            slot._dfTestGen = (slot._dfTestGen or 0) + 1   -- kill any pending re-arm
            -- Permanent aura on a slot that was previously TIMED: the bar is still
            -- under SetTimerDuration and there is no "clear timer" API, so a plain
            -- SetValue would be fighting the C timer. Re-arm its own duration with a
            -- span long enough that the fill stays pinned at full (~1% per 15 min)
            -- rather than guessing at which write wins.
            if slot._dfTestTimed and slot._dfTestDurObj and slot.dfBar then
                pcall(function() slot._dfTestDurObj:SetTimeFromStart(GetTime(), 86400) end)
                nativeBar = true
            end
            -- The binding would keep writing a countdown over the zero text below.
            if slot._dfTestBinding then
                pcall(function() slot._dfTestBinding:SetEnabled(false) end)
            end
            if slot.dfDur then
                -- Hide-on-permanent (Wave 4): mirror the native zeroDurationText
                -- route. zeroText set (the "" default) = that text verbatim; unset
                -- (user opted out) = the formatter's zero output, "0" fallback —
                -- best-effort mimic of Blizzard's default zero-duration rendering.
                local zCfg = styleConfigFor(self, slot)
                local durSpec = zCfg.style and zCfg.style.duration
                if durSpec and durSpec.zeroText ~= nil then
                    slot.dfDur:SetText(durSpec.zeroText)
                else
                    local zt = formatTestDuration(self, 0, slot)
                    slot.dfDur:SetText(zt ~= "" and zt or "0")
                end
            end
        end
    end
    if slot.dfStack then slot.dfStack:SetText((e.stacks or 0) > 1 and tostring(e.stacks) or "") end
    -- Duration bar: native SetDurationBar never runs in test mode, so the fill is
    -- OURS to fake (house rule: every native-driven region must render in test, or
    -- the preview lies). Same DF-owned StatusBar for both shapes (fill + strip);
    -- the value mirrors the staggered countdown above so bar, timer text and swipe
    -- agree, and the test ticker drains it in step. SetReverseFill is styling and
    -- was already applied by styleBarShared — value only here.
    -- nativeBar = the C timer owns the fill (SetTimerDuration); writing SetValue over
    -- it would fight the sweep. min/max is irrelevant either way on a timer bar
    -- (lab-verified: an untouched bar sweeps identically), so it stays for the
    -- fallback path only.
    if slot.dfBar and not nativeBar then
        slot.dfBar:SetMinMaxValues(0, 1); slot.dfBar:SetValue(barFill)
    end
    if slot.dfName then slot.dfName:SetText(dispName or "") end
    -- Dispel ring: no native SetAuraBorder bind in test mode -> tint + show it
    -- ourselves. Custom palette first (the preview mirrors live, where the shared
    -- account dispel colours drive Color-style rings), game palette fallback.
    if slot.dfAuraBorder then
        local shown = false
        if e.debuffType then
            local key = (e.debuffType == "Enrage") and "Bleed" or e.debuffType
            local c = DF.db and DF.db.dispelColors and DF.db.dispelColors[key]
            if type(c) == "table" and c.r then
                slot.dfAuraBorder:SetVertexColor(c.r, c.g, c.b)
                shown = true
            elseif AuraUtil and AuraUtil.GetAuraBorderColor then
                shown = pcall(function()
                    local gc = AuraUtil.GetAuraBorderColor(e.debuffType)
                    slot.dfAuraBorder:SetVertexColor(gc:GetRGB())
                end)
            end
        end
        slot.dfAuraBorder:SetShown(shown and true or false)
        -- The holder is born at alpha 0 and normally revealed by the bind (bindNative);
        -- the preview never binds, it paints the colour itself just above, so it is the
        -- reveal here. Only when it actually coloured the ring -- an unpainted one is
        -- exactly the white ring the dark birth exists to prevent.
        if slot.dfDispelHolder then slot.dfDispelHolder:SetAlpha(shown and 1 or 0) end
    end
    -- Dispel symbol: no native SetAuraSymbol bind in test mode -> fake the colourblind
    -- letter ourselves (house rule: every native-driven region renders in test, or the
    -- preview lies) — there is no native bind to drive it on a fake aura.
    -- ★ Reads the SAME map the live bind hands to customDispelTextMap
    -- (DF:GetGameDispelTextMap), so preview and live show identical letters rather
    -- than merely similar ones. Its predecessor derived them independently
    -- (`debuffType:sub(1, 2)`), which agreed with live only by coincidence and only
    -- in English. Live no longer depends on the colorblindMode CVar either, so the
    -- two paths now genuinely match instead of the preview over-promising.
    if slot.dfSymbol then
        local sym
        if e.debuffType then
            local map = DF.GetGameDispelTextMap and DF:GetGameDispelTextMap()
            sym = map and map[e.debuffType]
        end
        slot.dfSymbol:SetText(sym or "")
        slot.dfSymbol:SetShown(sym and true or false)
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
    -- ☠ CONTAINER-ONLY BLOCK, AND THE GUARD IS self.frame, NOT the tooltips flag.
    -- Everything below needs a REAL handle: self.frame to parent and level the hover
    -- frame against, and self:_positionTestTip (which in turn calls self:_slotCount).
    -- The duck-typed preview handle from PaintPreviewSlot has none of them — see
    -- testPoolFor. Today's preview configs never set `tooltips`, so this is unreachable
    -- from that path; the guard is here so ADDING the key is a no-op rather than three
    -- nil-value errors, which is exactly how the `_testPool` extraction broke opening
    -- the Aura Designer. The canvas does its own hover handling, so skipping is right.
    if self.config.tooltips == true and self.frame then
        self._testTips = self._testTips or {}
        local tip = self._testTips[index]
        if not tip then
            tip = CreateFrame("Frame", nil, self.frame)
            self._testTips[index] = tip
            tip:EnableMouse(true)
            if tip.SetMouseClickEnabled then tip:SetMouseClickEnabled(false) end
            local handle = self
            tip:SetScript("OnEnter", function(s)
                if not GameTooltip then return end
                -- LIVE-PATHWAY parity: mirror the row's configured tooltip placement
                -- + combat-hide exactly as the native hover applies them (the same
                -- style.tooltip spec styleButton_regions stamps on live buttons).
                -- Resolved at hover time so a settings change needs no tip recreate.
                local tt = handle.config.style and handle.config.style.tooltip
                if tt and tt.hideInCombat and UnitAffectingCombat("player") then return end
                local point, ox, oy = "ANCHOR_RIGHT", 0, 0
                if tt then point, ox, oy = tt.point, tt.x or 0, tt.y or 0 end
                GameTooltip:SetOwner(s, point, ox, oy)
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
                    GameTooltip:SetOwner(s, point, ox, oy)   -- reset any wrong render
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

-- ============================================================
-- OWN-FRAME PREVIEW — test mode without the global sample provider
-- ============================================================
-- ☠ WHY THIS EXISTS. The engine has no per-container sample source: the only lever
-- is C_UnitAuras.SwitchAuraDataProvider, which fires the client-wide
-- AURA_DATA_PROVIDER_SWITCH that EVERY aura container registers for intrinsically
-- (Blizzard_AuraContainer.lua). Flipping it for our preview therefore fills every
-- OTHER addon's containers with sample icons too — nameplates, unit frames, the lot.
-- The per-container flag exists (useEditModeSource) but its setter is on the private
-- mixin, and none of the 19 public container methods touches the data source, so it
-- can be neither set for us nor suppressed for anyone else.
--
-- ★ AND THE ENGINE'S SAMPLE DATA WAS NEVER THE POINT. Its auras carry no spell IDs,
-- durations or raid flags (see the per-slot-group header), so every icon, name,
-- count and timer in the preview was ALREADY painted by _paintTestSlot from our own
-- TestData. The switch bought exactly one thing: presence — engine-created buttons
-- to paint onto. Supplying those ourselves costs nothing and drops the global blast
-- radius entirely.
--
-- ★ THE SEAMS ARE ALL PRE-EXISTING, which is what keeps this honest:
--   * _acceptSlot   — registers into self.buttons and runs the SAME styleButton_regions
--                     the engine path runs, so styling cannot diverge.
--   * _paintTestSlot— the SAME painter, untouched. The AD editor canvas has painted
--                     plain CreateFrame("Frame") slots this way since it shipped.
--   * layoutRow     — the SAME positioner live uses off config.layout, including the
--                     pixel-perfect snap. No second layout implementation exists to
--                     drift, which is the failure mode this whole design is avoiding.
-- Everything downstream (ApplyStyle, the test ticker, teardown) already iterates
-- self.buttons and does not care where a button came from.
--
-- ⚠ Frames are pooled per handle and REUSED across rebuilds — creating fresh ones per
-- rebuild is what made the engine route allocate ~530 MB over four test toggles.
-- ☠ PLACEMENT MUST COME FROM THE ENGINE'S FLOW, NOT layoutRow.
-- First cut positioned the preview with layoutRow and the commit claimed that was
-- "the same positioner live uses". It is not: NATIVE rows are placed by the
-- container's own AnchorUtil flow (see applyContainerLayout), and layoutRow is the
-- legacy fallback's maths. Two implementations off one config is exactly the
-- preview/live divergence this whole design exists to avoid, and it would have
-- shown up first on the awkward cases (CENTER growth, wrapping, UP/LEFT growth,
-- the duration-strip reservation that shifts row stride).
--
-- So the preview drives AnchorUtil.CreateFlowLayout() -- the SAME public flow the
-- container uses -- configured from the SAME resolveGrowthLayout / buildGroupLayout
-- / stripReservation derivations applyContainerLayout feeds it. The box frame stands
-- in for the container: pinned with the identical pin point, offsets, pp snap and
-- scale, so the flow lays out in the same space.
--
-- Returns false on any doubt (no AnchorUtil, an enum that will not resolve, Apply
-- throwing) and the caller falls back to layoutRow — a slightly-off preview beats no
-- preview, and this must never be the thing that breaks test mode.
-- ★ THE ONE PLACE PREVIEW SLOTS ARE PLACED. Shared by the container's own test preview
-- (Handle:_flowPreviewLayout, below) and by the Aura Designer's editor canvas, which
-- reaches it through AuraContainer.FlowSlots. Both hand it plain CreateFrame("Frame")
-- slots; neither computes a position of its own. A surface that wants a preview supplies
-- FRAMES AND DATA — never a stride, a growth vector, a corner or a snap.
-- ☠ If something live does is not reachable through here, that is a finding to report,
-- not a gap to close by making a copy imitate live more closely. A second implementation
-- off one config is exactly the divergence this exists to prevent.
local function flowSlotsIntoBox(box, anchorFrame, slots, count, config, pp)
    local AU = AnchorUtil
    if not (AU and AU.CreateFlowLayout and AU.FlowDirection) then return false end
    if not (box and anchorFrame) then return false end

    local L = config.layout or {}
    local G, px, py, scale = resolveLayoutPin(L, anchorFrame, pp)
    local wrap = tonumber(L.wrap) or 0

    -- Strip reservation -> flow padding. Same exclusive branch as applyContainerLayout.
    local resv, topStrip = stripReservation(config)
    if resv > 0 and pp then resv = ppSnapScaled(resv, scale) end
    local padTop, padBottom = 0, 0
    if resv > 0 then
        if G.vName == "Up" then
            if not topStrip then padBottom = resv end
        elseif topStrip then
            padTop = resv
        end
    end

    -- Pin the box exactly where the container pins itself.
    local okPin = pcall(function()
        box:SetScale(scale)
        box:ClearAllPoints()
        box:SetPoint(G.pinPoint, anchorFrame, G.anchor, px, py)
    end)
    if not okPin then return false end

    -- Row cap, including the slack that stops the flow wrapping one icon early on the
    -- measured button width — and, since it shares flowLineSlack with the live path, the
    -- overhang of a record-styled cell too. ☠ This is the entry point the AD canvas and the
    -- Indicator Info probe measure through, so a cap that disagreed with the live one would
    -- make every one of them flow differently from what renders.
    local headroom = flowLineSlack(G.sx, G.spX, config and config.filter)
    local rowWidth
    if G.verticalPrimary then
        rowWidth = G.sx + headroom
    elseif wrap >= 1 then
        rowWidth = wrap * G.sx + (wrap - 1) * G.spX + headroom
    end

    local h = resolveEnum(AU.FlowDirection, G.hName)
    local v = resolveEnum(AU.FlowDirection, G.vName)
    if h == nil or v == nil then return false end

    local gl = buildGroupLayout(config)
    local elements = {}
    for i = 1, count do elements[i] = slots[i] end

    return pcall(function()
        local layout = AU.CreateFlowLayout()
        -- Mirror CustomAuraContainerFlowLayoutMixin: the GROUP's declared cell wins
        -- over the measured button, which is what folds the strip reservation into
        -- the row stride.
        layout.GetElementSize = function(_, _, element, group)
            -- Styled preview slot (important-debuff highlight / layout-group member):
            -- its cell is the record-scaled cell, exactly what the engine route
            -- declares per group via recordGroupLayout — the button alone growing
            -- would overlap its neighbour (button size and layout cell are separate
            -- things, re-learned the hard way on the live containers).
            local rs = element.dfImpRecStyle
            if rs then
                local cell = recordGroupLayout(gl, rs)
                return cell.elementWidth, cell.elementHeight
            end
            local w, hgt = element:GetSize()
            return group.elementWidth or w, group.elementHeight or hgt
        end
        layout:SetAnchorPoint(G.flowAnchor)
        layout:SetGrowthDirection(h, v)
        layout:SetMaximumLineSize(rowWidth or math.huge)
        layout:SetPadding(0, 0, padTop, padBottom)
        layout:Apply(box, { {
            elements       = elements,
            elementSpacing = gl.elementSpacing,
            lineSpacing    = gl.lineSpacing,
            elementWidth   = gl.elementWidth,
            elementHeight  = gl.elementHeight,
        } })
    end)
end

function Handle:_flowPreviewLayout(slots, count)
    return flowSlotsIntoBox(self._ownPreviewBox, self.frame, slots, count, self.config, self._pp)
end

function Handle:_buildOwnPreview()
    local config = self.config
    local pool = testPoolFor(config)
    local want = testSlotCount(config, pool)
    self._ownPreviewSlots = self._ownPreviewSlots or {}
    local slots = self._ownPreviewSlots

    -- The box stands in for the container: the flow lays out INSIDE it and sizes it
    -- on completion, and it carries the layout scale, so slots parent to it rather
    -- than to the frame (parenting to the frame would leave the scale unapplied).
    local box = self._ownPreviewBox
    if not box then
        box = CreateFrame("Frame", nil, self.frame)
        self._ownPreviewBox = box
    end
    pcall(function()
        box:SetFrameStrata(self.frame:GetFrameStrata())
        box:SetFrameLevel(self.frame:GetFrameLevel() + 5)
    end)
    box:Show()

    -- ONE source for "how many slots does the preview currently have", so a later
    -- re-flow (Handle:ApplyStyle) cannot ask the box to lay out a slot that was never
    -- created. Stamped before the loop that creates 1..want.
    self._ownPreviewCount = want

    local ps = self._ownPreviewStyles
    for i = 1, want do
        local slot = slots[i]
        if not slot then
            slot = CreateFrame("Frame", nil, box)
            slots[i] = slot
        end
        slot:Show()
        -- Per-slot record style, the same rule as the engine route's per-slot groups:
        -- a layout group styles slot k as member k; Important Debuffs styles slot 1
        -- against plain neighbours (the positioning A/B). Stamped DIRECTLY rather than
        -- through _acceptSlot's recStyle arg: pooled slots persist across rebuilds and
        -- _acceptSlot deliberately leaves a nil recStyle untouched, so a stale stamp
        -- from the previous build must be CLEARED here (applyRecordStyle's nil path
        -- then hides a leftover badge).
        slot.dfImpRecStyle = ps and (ps.perSlot and ps.perSlot[i]
            or (i == 1 and ps.single) or nil) or nil
        -- Same styling seam as a native button. _acceptSlot fills self.buttons[i],
        -- so ApplyStyle / teardown pick these up unchanged.
        self:_acceptSlot(slot, i)
        self:_paintTestSlot(slot, i)
    end

    -- A shorter preview than last time (pool cap, Max Icons dropped): park the
    -- surplus and drop it from self.buttons so no cell is reserved for a frame
    -- nobody can see.
    for i = want + 1, #slots do
        slots[i]:Hide()
        self.buttons[i] = nil
    end

    if want > 0 then
        if not self:_flowPreviewLayout(slots, want) then
            -- Fallback only: positions from DF's own maths rather than the engine
            -- flow, so it can differ from live on the awkward growth cases.
            DF:DebugWarn(DBG, "own preview: flow layout unavailable, falling back to layoutRow")
            layoutRow(self)
        end
    elseif box then
        box:Hide()
    end
end

-- Shared ticker driving the preview countdowns (test mode only; started and
-- stopped by SetTestMode). Loops each timer + swipe at zero and drains the
-- duration bar in step so the preview animates indefinitely. Buttons die with
-- their containers, so stale state can't outlive a rebuild (handle.buttons is
-- wiped on teardown).
--
-- FALLBACK ONLY as of the native-duration path (armTestDuration): started on demand
-- by the first slot that fails to arm natively, never by SetTestMode. On a build with
-- C_DurationUtil it never runs at all — the C side drives every preview countdown.
-- 10Hz, not the original 1s: the faked bar fill stepped in visible jumps at 1s while
-- the cooldown swipe beside it swept smoothly. 0.1 is the same cadence the SMOOTH
-- duration-update-rate option asks of the live binding.
local TEST_TICK = 0.1
function AuraContainer._startTestTicker()
    if AuraContainer._testTicker then return end
    AuraContainer._testTicker = C_Timer.NewTicker(TEST_TICK, function()
        local now = GetTime()
        -- Duration TEXT keeps the live cadence: the account-wide update rate is
        -- forwarded to the native binding live (GetAuraDurationUpdateInterval),
        -- so PERFORMANCE's 1s text throttle must show up in the preview too or
        -- the preview lies. NORMAL (native default, cadence undocumented) has no
        -- number to honour -> reformat every tick and push only when the rendered
        -- string actually changed, which is what a whole-second format does
        -- anyway. The bar is unthrottled either way: it's DF-drawn, not bound.
        local textIv = DF.GetAuraDurationUpdateInterval and DF:GetAuraDurationUpdateInterval()
        for h in pairs(AuraContainer._handles or {}) do
            if not h._destroyed and h.buttons then
                for _, b in ipairs(h.buttons) do
                    -- dfDur OR dfBar: a bar-only row (duration text off) still drains.
                    if b._dfTestDur and (b.dfDur or b.dfBar) then
                        local rem = (b._dfTestExpiry or 0) - now
                        if rem <= 0 then
                            rem = b._dfTestDur
                            b._dfTestExpiry = now + rem
                            if b.dfCD and b.dfCD.SetCooldown then
                                pcall(function() b.dfCD:SetCooldown(now, b._dfTestDur) end)
                            end
                        end
                        if b.dfDur and (not textIv or not b._dfTestTextAt
                            or (now - b._dfTestTextAt) >= textIv) then
                            local s = formatTestDuration(h, rem, b)
                            if s ~= b._dfTestText then
                                b.dfDur:SetText(s)
                                b._dfTestText = s
                            end
                            b._dfTestTextAt = now
                        end
                        if b.dfBar then b.dfBar:SetValue(rem / b._dfTestDur) end
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
-- ☠ A RECORD-STYLED SLOT IS BIGGER, AND THE HOVER GRID HAS TO KNOW. The zones were a
-- uniform grid of BASE-size cells, so an important debuff (which renders at
-- `debuffImportantScale`) got a zone the wrong size AND displaced every zone after it in
-- its row by the width the real flow had already consumed. Symptom: the aura tooltip does
-- not follow "Size Step" (Aphoex 7.1). Returns slot k's scale; the caller also sums the
-- overhang of the slots BEFORE k in the same row.
-- ⚠ Resolved from `_ownPreviewStyles`, the same table _buildOwnPreview paints from, so the
-- zone and the icon cannot disagree about which slots are styled.
local function testSlotScale(handle, slotIndex)
    local ps = handle._ownPreviewStyles
    if not ps then return 1 end
    local st = (ps.perSlot and ps.perSlot[slotIndex])
        or (ps.single and slotIndex == 1 and ps.single)
        or nil
    return (st and tonumber(st.scale)) or 1
end

function Handle:_positionTestTip(tip, index)
    local L = self.config.layout or {}
    local G = resolveGrowthLayout(L)
    local sx, sy, spX, spY = G.sx, G.sy, G.spX, G.spY
    local scale = tonumber(L.scale) or 1
    -- This slot's own scale, and the overhang the styled slots before it in the SAME row
    -- have already pushed along the primary axis.
    local mine = testSlotScale(self, index)
    local n = math.max(self:_slotCount(), 1)
    -- Vertical-primary growth renders as a single column on the native flow.
    local wrap = G.verticalPrimary and 1 or (tonumber(L.wrap) or 0)
    if wrap < 1 then wrap = n end
    local idx = index - 1
    -- Strip reservation (Wave 3.2/3.3): rendered rows stride by elementHeight
    -- (sy + reservation) + spacing, and a strip FACING the flow's vertical start
    -- insets the first row by the reservation (SetFlowLayoutPadding). Mirror
    -- both here or the hover zones drift by `resv` per row once a bar is on.
    local resv, topStrip = stripReservation(self.config)
    local inset = 0
    if resv > 0 then
        if G.vName == "Up" then
            inset = (not topStrip) and resv or 0
        else
            inset = topStrip and resv or 0
        end
    end
    local strideY = sy + resv + spY
    -- Overhang accumulated by the styled slots earlier in this row (0 when nothing is
    -- styled, which is every row that has no important debuff up).
    local rowFirst = math.floor(idx / wrap) * wrap
    local leadExtra = 0
    for j = rowFirst, idx - 1 do
        leadExtra = leadExtra + (testSlotScale(self, j + 1) - 1) * sx
    end
    tip:SetSize(sx * scale * mine, sy * scale * mine)
    tip:ClearAllPoints()
    if G.center then
        -- Mirror the centre-pinned box (resolveGrowthLayout): the box's
        -- centre-of-edge sits at the user's anchor + pin offsets and fills from
        -- its corner — anchor each tip by its CENTRE at the icon's rendered centre.
        local x, y
        if G.verticalPrimary then
            -- Single centred column. Box height = start inset + n cells of
            -- (sy + resv) + the between gaps (the flow's self-size); the icon
            -- sits at its cell's flow corner (extra height lands away from start).
            local colH = inset + n * (sy + resv) + (n - 1) * spY
            x = (L.offsetX or 0) + (G.pinX + ((G.secondary == "LEFT") and -sx / 2 or sx / 2)) * scale
            y = (L.offsetY or 0) + (G.pinY + colH / 2 - inset - idx * strideY - sy / 2) * scale
        else
            local col = idx % wrap
            local row = math.floor(idx / wrap)
            local m = math.min(wrap, n)
            -- Row width includes every styled slot's overhang, or a centred row would sit
            -- off to one side by half of it.
            local rowExtra = 0
            for j = rowFirst, rowFirst + m - 1 do
                rowExtra = rowExtra + (testSlotScale(self, j + 1) - 1) * sx
            end
            local rowW = m * sx + (m - 1) * spX + rowExtra
            local rowDir = (G.secondary == "UP") and 1 or -1
            x = (L.offsetX or 0)
                + (G.pinX + col * (sx + spX) + leadExtra - rowW / 2 + sx * mine / 2) * scale
            y = (L.offsetY or 0) + (G.pinY + rowDir * (inset + row * strideY + sy / 2)) * scale
        end
        tip:SetPoint("CENTER", self.frame, G.anchor, x, y)
        return
    end
    -- Directional growth: replicate the flow from the anchor corner. The container
    -- itself is scaled; in handle.frame space each step and the element size render
    -- multiplied by scale. User offsets are container-anchor offsets in parent
    -- space (unscaled). The start inset shifts every row along the flow's vertical
    -- direction (down for Down-flow, up for Up-flow).
    local pAxis = AXIS[G.primary] or AXIS.RIGHT
    local sAxis = AXIS[G.secondary] or AXIS.DOWN
    local vSign = (G.vName == "Up") and 1 or -1
    local col = idx % wrap
    local row = math.floor(idx / wrap)
    local x = (L.offsetX or 0)
        + ((pAxis.x * col + sAxis.x * row) * (sx + spX) + pAxis.x * leadExtra) * scale
    local y = (L.offsetY or 0)
        + ((pAxis.y * col + sAxis.y * row) * strideY + pAxis.y * leadExtra + vSign * inset) * scale
    tip:SetPoint(G.anchor, self.frame, G.anchor, x, y)
end

-- Build the per-button styling callback Blizzard invokes (securecallfunction) for each
-- container-created button, in lazy batches of 10 as auras appear -- so this can fire long
-- after build, including mid-combat. Whole body is pcall-wrapped (an unguarded fault would
-- abort Blizzard's batch creation); the gen token drops a callback from a torn-down or
-- rebuilt container; a running counter mirrors the old per-index slot id (batches append,
-- so indices stay contiguous -- ipairs(self.buttons) in ApplyStyle/layoutRow still holds).
-- PER-RECORD STYLE (important-debuff highlight). A row's buttons are all styled from
-- the container-wide config, which is right for everything except a group that exists
-- BECAUSE its auras are a distinct class. Records can carry `style` and every button in
-- that group gets it — unconditionally, because membership already IS the predicate.
-- Nothing here reads aura data; we never learn which aura a button holds.
--
-- ⚠ Runs AFTER _acceptSlot, which sized the button from the shared layout — the scale
-- below deliberately overrides that. The group's own layout cell is widened to match at
-- AddAuraGroup (see the record loop), or the bigger button would overlap its neighbour.
--
-- Regions are created ONCE and updated in place: initializeFrame re-runs on restyle, and
-- ApplyStyle re-runs it without teardown. Never Show/Hide a region a native setter owns;
-- these are DF-owned textures on the button, so plain SetShown is fine.
-- NOTE: assigns the local forward-declared above _acceptSlot (which calls this on every
-- restyle). Deliberately NOT `local function` — that would shadow the forward local and
-- leave _acceptSlot calling a nil global.
-- ============================================================
-- PER-RECORD CONFIG VIEW  — full per-member styling in ONE container
-- ============================================================
-- A record that carries `button` (a complete style table) is styled by the SHARED
-- styler against a config view of its own, rather than by a bespoke override list.
-- That is what makes per-member styling total instead of partial: everything
-- styleButton_regions can express, a member can express, automatically and forever
-- — including anything added to it later.
--
-- ⚠ Complete by construction, not by hopeful copying. styleButton_regions reads
-- exactly five config fields: style, layout, mode, unit, adBorderAnim. The first
-- two are what a member overrides; the rest are container-wide. So an __index
-- proxy over the real config, with those two swapped, is the whole substitution —
-- a hand-built partial copy would silently drift the moment the styler reads
-- something new.
--
-- Memoised on the record: these are rebuilt on every restyle of every button, and
-- allocating a table per button per pass would churn the hot path.
local function recordConfigView(handle, recStyle)
    local view = recStyle._cfgView
    if view and view._src == handle.config then return view end
    -- ⚠ layout only when the record OWNS one. Materialising the container's
    -- layout here would freeze it into the memo: ApplyStyle swaps config.layout
    -- in place (same config table, so the _src identity check never fires), and
    -- the view would keep styling from the old geometry. Leaving the key nil
    -- lets __index read the live value on every access.
    view = setmetatable({
        _src   = handle.config,
        style  = recStyle.button,
        layout = recStyle.layout,
    }, { __index = handle.config })
    recStyle._cfgView = view
    return view
end

-- The config a button should be styled FROM: its record's view when the record
-- carries a full style, else the container's own.
--
-- ☠ Used INSTEAD of config.style, never after it. Styling once with the shared
-- config and then re-styling with the member's would leave regions the container
-- wanted and the member did not — a duration fontstring on a member that shows no
-- duration, for instance. One pass, correct config.
function styleConfigFor(handle, button)   -- assigns the forward-declared local
    local rs = button and button.dfImpRecStyle
    if rs and rs.button then return recordConfigView(handle, rs) end
    return handle.config
end

function applyRecordStyle(button, handle, recStyle)
    if not recStyle then
        -- Styled -> plain TRANSITION (own-preview pool only): a native button belongs
        -- to one group for life, so it can never lose its record style — but the test
        -- pool's slots persist across rebuilds, and toggling the highlight off leaves
        -- a stamped badge shown unless the off-path runs here. Size needs no revert:
        -- _acceptSlot has just re-sized the button from the shared layout.
        if button and button.dfImpBadgeHost then button.dfImpBadgeHost:SetShown(false) end
        return
    end

    if recStyle.scale and recStyle.scale ~= 1 then
        local lay = handle.config and handle.config.layout
        local sx = lay and (lay.sizeX or lay.size) or 32
        local sy = lay and (lay.sizeY or lay.size) or sx
        button:SetSize(sx * recStyle.scale, sy * recStyle.scale)
    end

    local bs = recStyle.badge
    if bs then
        local sz = bs.size or 12   -- mirrors debuffImportantBadgeSize's Config default
        -- HOST FRAME, not bare textures on the button. The badge deliberately overhangs
        -- the button's corner, which puts it in the NEXT button's space — and sibling
        -- buttons draw in their own order, so a plain OVERLAY texture ends up BEHIND the
        -- neighbouring icon (seen in game). A child frame with a raised frame level wins
        -- against siblings regardless of their order. +13 clears DF.Border's +10 and the
        -- dispel ring's +12, the same clearance the duration-text holder uses.
        -- Frames don't clip children unless asked, so the overhang still renders.
        if not button.dfImpBadgeHost then
            button.dfImpBadgeHost = CreateFrame("Frame", nil, button)
            button.dfImpBadge = button.dfImpBadgeHost:CreateTexture(nil, "OVERLAY", nil, 6)
            button.dfImpMark = button.dfImpBadgeHost:CreateTexture(nil, "OVERLAY", nil, 7)
        end
        local host = button.dfImpBadgeHost
        host:SetAllPoints(button)
        host:SetFrameLevel(button:GetFrameLevel() + 13)
        local b, m = button.dfImpBadge, button.dfImpMark
        b:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\DF_AlertBadge")
        m:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\DF_AlertMark")
        -- Anchored CENTER-on-corner so the offsets read the same whichever corner is
        -- picked, then nudged INWARD by a quarter of the badge's own size. The badge
        -- overlaps the corner but leans into the icon, which is what reads as "a marker
        -- on this icon" — the first cut pushed it OUTWARD instead and sat it half off
        -- the art, so every user had to dial in negative offsets just to get back to a
        -- sane resting place. User offsets are ADDED to the inset, so 0,0 is the good
        -- position and the sliders are for taste.
        local inset = sz / 4
        local ux = tonumber(bs.offsetX) or 0
        local uy = tonumber(bs.offsetY) or 0
        local pt = bs.point or "TOPRIGHT"
        -- "Inward" is a different direction per corner. Both operands are non-false
        -- numbers, so the and/or is safe here (unlike the nil-fallback trap elsewhere).
        local dx = (pt == "TOPLEFT" or pt == "BOTTOMLEFT") and inset or -inset
        local dy = (pt == "BOTTOMLEFT" or pt == "BOTTOMRIGHT") and inset or -inset
        for _, t in ipairs({ b, m }) do
            t:ClearAllPoints()
            t:SetSize(sz, sz)
            t:SetPoint("CENTER", button, pt, ux + dx, uy + dy)
        end
        b:SetVertexColor(readColor(bs.color))
        m:SetVertexColor(readColor(bs.markColor))
        -- Re-show the HOST too: the off-path hides it, and a button recycled from a
        -- pass with the badge disabled would otherwise keep shown textures inside a
        -- hidden frame — visible nowhere, with nothing obviously wrong in the config.
        host:SetShown(true)
        b:SetShown(true)
        m:SetShown(true)
    elseif button.dfImpBadgeHost then
        -- Hide the HOST, not the two textures: one call, and nothing inside it can
        -- render even if a future region is added. These are DF-owned widgets, so
        -- SetShown is safe — the no-Show/Hide rule is only for regions handed to a
        -- native setter, whose Shown aspect Blizzard owns.
        button.dfImpBadgeHost:SetShown(false)
    end
end

-- seqStart: when set, this group numbers its OWN buttons sequentially from that base
-- rather than taking a fixed index or the handle-wide creation counter. That is what
-- lets a SINGLE test group paint a distinct curated entry per button. The handle-wide
-- counter cannot do it: Blizzard eagerly creates FrameCreationBatchSize frames per
-- group, so the shared counter runs far past the preview's slot range. Overshoot is
-- harmless either way — _paintTestSlot wraps the index modulo the pool size, and any
-- button past maxFrameCount is never displayed.
function Handle:_makeInitializeFrame(gen, fixedIndex, onInit, recStyle, seqStart)
    local handle = self
    local seq = seqStart
    -- ☠ THE CONTAINER'S BUILD-TIME SHAPE, CAPTURED HERE — never the live global.
    --
    -- build() picks its SHAPE from AuraContainer._testMode: a test container skips the
    -- real filter loop and declares per-slot dfTest<k> groups (or, own-preview,
    -- nothing), and groups can never be removed, so that shape is fixed for the
    -- container's whole life. This closure used
    -- to decide paint-vs-bind by reading the GLOBAL again -- but buttons are created in
    -- LAZY BATCHES long after build (AddAuraGroup allocates FrameCreationBatchSize at a
    -- time, and more arrive on later aura events). Any test transition between build and
    -- a batch firing flipped the branch underneath a container that cannot change shape.
    --
    -- The failure would be one-directional and silent: a test-shaped container whose
    -- later batches land while the global reads false would run _bindNativeSlot, and
    -- Blizzard's SetIcon would repaint the curated art with the hidden SAMPLE aura's.
    --
    -- ⚠ THEORETICAL, and honestly so. This was written as the fix for the 2026-08-06
    -- repeated-icon report and it was NOT the cause: the debug log for that session has
    -- 195 creates with shape=true global=true and 225 with shape=false global=false --
    -- they agreed every single time. The real cause was the preview asking for more
    -- slots than the curated pool holds (see Handle:_slotCount). Kept because reading a
    -- mutable global to decide something the container fixed at build time is wrong
    -- regardless, but do not cite it as a fixed bug.
    --
    -- Captured, not read through handle.backend at call time: a re-adopted park swaps
    -- the backend out from under closures that belong to a different container.
    local testShape = self.backend and self.backend.builtInTestMode
    if testShape == nil then testShape = AuraContainer._testMode end
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
            -- not the curated preview icon it appears to be. Motion is the on/off
            -- lever; it can't be toggled per-combat because the button's mouse state
            -- is secret + write-locked in combat (live-verified). Placement and
            -- combat-hide are NOT limited like that on 68914+: SetTooltipAnchorPoint/
            -- SetHideTooltipInCombat are plain shared-mixin state, stamped from
            -- style.tooltip in styleButton_regions (via _acceptSlot below).
            if button.SetMouseMotionEnabled then
                button:SetMouseMotionEnabled(handle.config.tooltips == true and not AuraContainer._testMode)
            end
            -- MISSING mode: the button must render NOTHING — its only job is to occupy
            -- a layout cell so the container's width pushes the badge out of the clip
            -- window (probe 32). No regions, no native binds.
            if handle.config.mode ~= "missing" then
                -- recStyle is stashed on the button by _acceptSlot and re-applied by it
                -- on every later restyle, so the override is not lost the moment
                -- anything else re-styles the row.
                -- (Removed) a button._dfTestSlot stamp read by styleButton_regions to
                -- force the Pandemic cue visible on preview slots. Its one consumer is
                -- gone — see the Pandemic block in styleButton_regions for why a
                -- permanently-shown duration cue is not a preview of one. Re-add it if
                -- that cue is ever driven properly from armTestDuration; nothing else
                -- wanted it.
                handle:_acceptSlot(button, i, recStyle)   -- size + regions + per-group overrides
                if testShape then
                    -- P5 hybrid preview: the sample provider drives presence and the
                    -- real flow drives geometry, but the sample auras' own data is
                    -- never shown — no native binds; paint the curated pool instead.
                    -- fixedIndex = the per-slot test group's position (creation order
                    -- is NOT layout order; the group key is) — stamped on the button
                    -- so ApplyStyle repaints the same entry.
                    local testIndex
                    if seq then
                        testIndex = seq
                        seq = seq + 1
                    else
                        testIndex = fixedIndex or i
                    end
                    button._dfTestIndex = testIndex
                    handle:_paintTestSlot(button, testIndex)
                else
                    handle:_bindNativeSlot(button)     -- native inbound setters
                    -- ☠ The consumer's onInit USED TO BE CALLED HERE, last inside this
                    -- pcall. It now runs below, on its own. See the block after the pcall.
                end
            end
        end)
        -- ☠ ITS OWN LATCH, AND ITS OWN WORDING. This shared `warnedRestyle` with
        -- ApplyStyle's restyle loop, which is a one-shot for the session -- so whichever
        -- of the two failed first permanently silenced the other. Slot birth and restyle
        -- are unrelated failures on unrelated paths; one latch between them meant the
        -- second was guaranteed to be invisible.
        -- The wording said "styling failed", but everything from _acceptSlot to the
        -- consumer's onInit hook lands here, and a message that names the wrong stage
        -- sends the next reader to the wrong file. It names the button's group instead
        -- and leaves the stage to the error text.
        if not ok and not warnedInitFrame then
            warnedInitFrame = true
            DF:DebugWarn(DBG, "initializeFrame failed (slot art may be incomplete): %s",
                tostring(err))
        end
        -- ☠☠ THE CONSUMER HOOK GETS ITS OWN CALL, BECAUSE IT WAS LAST IN A SHARED PCALL.
        -- It used to sit at the END of the pass above, after the mouse setters,
        -- _acceptSlot and _bindNativeSlot. Any throw in ANY of those skipped straight past
        -- it, so the button came out with its own regions built and bound and the
        -- consumer's carriers never created at all.
        --
        -- ★ THAT ASYMMETRY IS THE FIELD SIGNATURE. Every reported white dispel overlay had
        -- a correctly coloured debuff-icon ring on the same frame at the same moment: the
        -- ring is built and bound by _acceptSlot / _bindNativeSlot EARLIER in this pass, so
        -- it always completed, while the overlay's init was the only thing an earlier fault
        -- could silently cost. It was never a difference between the two lanes' colour
        -- handling -- it was their position in this function.
        --
        -- Still inside the same securecallfunction pass, which is what the hook needs: the
        -- engine applies its access restrictions only after this whole callback RETURNS, so
        -- a texture created here is still made in secure context. A pcall boundary is error
        -- handling, not a context change -- moving the call out of the inner one does not
        -- move it out of the window.
        --
        -- Conditions replicated from where the call used to sit: not destroyed, same
        -- generation, real button, not `missing` mode (which builds no regions at all), and
        -- not a test-shaped container (which paints curated art instead of binding).
        if onInit and button and not handle._destroyed and handle._gen == gen
            and handle.config.mode ~= "missing" and not testShape then
            local okHook, errHook = pcall(onInit, button)
            if not okHook and not warnedInitHook then
                warnedInitHook = true
                DF:DebugWarn(DBG, "initializeFrame consumer hook failed (slot carriers "
                    .. "will be missing until the out-of-combat rebuild): %s", tostring(errHook))
            end
        end
    end
end

function Handle:GetFrame() return self.frame end
-- The legal target for a tainted alpha write. For a per-indicator container that is its
-- own plain anchor frame, which DF created and owns. See SlotHandle:GetAlphaHost for why
-- this is asked for separately from GetFrame rather than being assumed the same object.
function Handle:GetAlphaHost() return self.frame end
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
    -- Do NOT floor: the caller pixel-quantizes the spill (whole PHYSICAL px =
    -- fractional UNITS) and uses the SAME value to shift the strip cell by
    -- -spill — flooring here desynced the two by the fractional part, so the
    -- window-grows/cell-shifts cancellation broke and the badge visibly
    -- wiggled/shifted while dragging the animation inset/offset sliders
    -- (live-caught). The value must survive this round trip bit-exact.
    sp = math.max(0, tonumber(sp) or 0)
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
        -- +MISSING_EMPTY_W: same empty-size-floor compensation as the build anchor.
        self.badge:SetPoint("TOPLEFT", c, "TOPLEFT", MISSING_PAD + sp + MISSING_EMPTY_W, -sp)
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
    self._intendedShown = shown          -- consumer INTENT; the identity gate composes on top
    self:_applyVisibility()
    self:_applyEnabled(shown)
end
-- Visibility INTENT only — records the consumer's wish and applies it, with NO
-- enable op. Two reasons this exists instead of SetShown:
--   * ☠ SetShown's _applyEnabled queues an "enable" op in combat, and a queued
--     enable upgrades a queued retarget into a full rebuild — a frame leak (see
--     DriveDefensiveFactory's header in Features/Auras.lua). The drives hide/show
--     per aura event, so they must never queue backend ops.
--   * A raw GetFrame():Hide() leaves _intendedShown reading "wants shown", and
--     the identity-gate sweep's _applyVisibility then RESURRECTS the row on the
--     next roster/faction/phase/target event — disabled buff bars and defensive
--     icons popping back with live auras (reported on 5.0.0). Intent recorded
--     here survives every sweep.
function Handle:SetIntentShown(shown)
    self._intendedShown = shown and true or false
    self:_applyVisibility()
end

-- Single writer for the window's shown state (consumer intent composed with the
-- identity gate). NEVER flip visibility while the cursor is inside the window:
-- hiding/showing it runs the hovered native button's tooltip intrinsics
-- (Blizzard_AuraButton OnEnter/OnLeave -> Show/HideTooltip) synchronously INSIDE
-- our tainted execution, and those index secret aura data. That error class is
-- REPORTED to the user even when caught by pcall, so hover avoidance is the
-- defence and pcall only a backstop. While hovered (or after a failed write)
-- park a short retry; the flip lands as soon as the cursor moves off. Verified
-- against IsShown, so an aborted write can never strand the gate out of sync
-- (the original stranded-fail-open field bug).
function Handle:_applyVisibility()
    if self._destroyed then return end
    -- ☠ PARENT-DRIVEN handles never manage their own visibility. A container nested
    -- inside another container's aura slot inherits that slot's SECRET shown state, so
    -- frame:IsShown() below returns a secret boolean and comparing it taints ("attempt
    -- to compare a secret boolean value"). It is also pointless: the parent slot already
    -- shows and hides the whole subtree, which is the entire reason for nesting.
    if self.config and self.config.parentDrivenVisibility then return end
    local want = (self._intendedShown ~= false) and not self._idGateHidden
        and not self._cineLatched and not self._deathLatched
    -- Respect the fake-data park (Edit Mode etc.): while parked, this handle is
    -- hidden regardless of intent/gate — otherwise a hover-deferred retry could
    -- ping-pong against the park's own deferred hide.
    local watch = AuraContainer._providerWatch
    if watch and watch._fakeActive and watch._hidden[self] then want = false end
    if self.frame:IsShown() == want then self._visRetry = nil; return end
    local okOver, over = pcall(self.frame.IsMouseOver, self.frame)
    local blocked = (okOver and over)
        or not pcall(self.frame.SetShown, self.frame, want)
        or self.frame:IsShown() ~= want
    if not blocked then
        self._visRetry = nil
    elseif not self._visRetry then
        self._visRetry = true
        C_Timer.After(0.25, function()
            self._visRetry = nil
            self:_applyVisibility()
        end)
    end
end

-- Hover-safe Hide for windows leaving the handle bookkeeping (destroy / the
-- fake-data park): same hazard + deferral as _applyVisibility, minus the intent
-- composition. `stillWanted` (optional) is re-checked on each retry so a
-- deferred hide can't clobber a window someone legitimately re-showed meanwhile.
local function safeHideWindow(frame, stillWanted)
    if not frame or not frame:IsShown() then return end
    if stillWanted and not stillWanted() then return end
    local okOver, over = pcall(frame.IsMouseOver, frame)
    if (okOver and over) or not pcall(frame.Hide, frame) or frame:IsShown() then
        C_Timer.After(0.25, function() safeHideWindow(frame, stillWanted) end)
    end
end

-- Hide this handle while the 12.1 identity gate would fail open on its unit (see
-- filterVulnerableToIdentityGate — HELPFUL includeSpellIDs pools render every
-- buff for a unit failing UnitCanAssist, e.g. a cross-faction group member
-- outside instanced content or a duel partner). RENDER-SIDE ONLY: hides the
-- plain anchor frame (combat-safe), never touches the secure enabled state —
-- that stays owned by SetShown/_applyEnabled. Composes with consumer intent:
-- a consumer-hidden handle stays hidden when the gate lifts. Fail-safe on any
-- doubt (secret value, pcall failure, missing unit): SHOW — a wrongly-hidden
-- row is worse than one garbage frame. Always recomputes (no vulnerable
-- early-out) so a handle rebuilt onto a non-vulnerable filter clears a stale
-- hidden flag instead of staying hidden forever.
-- ☠ THE GATE FAILS OPEN AND THE ENGINE DOES NOT RE-PARSE ON ITS OWN.
-- A non-assistable unit renders EVERY helpful aura (includeSpellIDs is skipped
-- wholesale — see filterVulnerableToIdentityGate). The engine only re-parses when
-- an aura CHANGES, so once assistability comes back the unfiltered pool just STAYS.
-- That is precisely why the only workarounds users ever found (toggling test mode,
-- toggling any filter) were pure REBUILDS.
--
-- Live repro, 100%, Krathe 2026-08-12: watch an in-game cinematic. It flips
-- UNIT_FACTION so you stop being assistable, every filtered buff pool opens up, and
-- it persists after the cinematic ends. 12.1 forces one on first login — which is
-- what produced the "unfiltered buffs after upgrading" reports that were chased as a
-- v4→v5 migration bug for two days. It is not a migration bug and it hits clean v5
-- profiles too. Corroborated on the addon dev Discord (plusmouse): "UNIT_FACTION
-- seems to change, so the unit ceases to be assistable".
--
-- ☠ We ALREADY registered UNIT_FACTION (see idGateWatch) — the event was never the
-- gap. The sweep just recomputed a hide flag and never re-parsed.
--
-- Bounce on the false→true EDGE only. A bounce every sweep would re-parse every
-- vulnerable handle on every roster/name/phase event. nil (first computation) is not
-- an edge — but a container built DURING a cinematic records false, so the exit edge
-- still fires, which is the first-login case.
-- Re-entrancy: the flag is stored BEFORE Refresh(), so a re-entrant gate pass sees
-- true and cannot bounce again.
-- CINEMATIC LATCH (see the cineWatch block at the bottom of the file). While set,
-- the handle stays hidden through _applyVisibility's existing composition -- the
-- same combat-safe render-side lever the identity gate uses. The latch exists so
-- the fail-open parse a cinematic leaves behind is never SEEN: the frames come
-- back only after the recovery re-parse below has run.
-- ☠☠ CLEARING THIS LATCH MUST RE-PARSE — the death latch below has always done so and
-- this one never did, which is the whole difference between "stale icons on your own
-- frame until /reload" and not.
--
-- A cinematic flips UNIT_FACTION, the ENGINE fails open and re-parses the pool
-- unfiltered; that is why this latch exists. The only re-parse used to come from
-- _noteGateRecovery, which fires on a false->true ASSIST edge — and CINEMATIC_STOP
-- deliberately un-latches every handle whose assist "never dropped", on the reasoning
-- that it was therefore never fail-open. ☠ THAT REASONING IS WRONG: the fail-open is
-- caused by the engine's UNIT_FACTION flip, not by whether one of our coalesced sweeps
-- happened to land inside the window and observe UnitCanAssist dipping. Lose that race —
-- easy, the dip is brief, and briefest of all on the PLAYER'S OWN unit — and the handle
-- un-latches with the fail-open parse still standing, showing auras that no longer exist
-- until something else forces a rebuild (Krathe's own defensive + debuff rows,
-- 2026-08-19).
--
-- ⚠ REFRESH BEFORE THE FLAG CLEARS, so the rows reappear ALREADY re-parsed rather than
-- one frame early — the same ordering _noteGateRecovery documents for its own bounce.
-- ⚠ skipReparse is for that caller only: it has just Refreshed and would otherwise pay
-- for a second bounce on the same edge.
function Handle:_setCineLatch(on, skipReparse)
    on = on or nil
    if self._cineLatched == on then return end
    if not on and not skipReparse then
        self:Refresh()
    end
    self._cineLatched = on
    self:_applyVisibility()
end

-- DEATH LATCH (#1043) — same lever, different trigger. Death strips a unit's
-- auras WITHOUT firing UNIT_AURA (documented in Frames/Update.lua), and the
-- engine only re-parses on aura events — so every aura row froze its pre-death
-- icon set on a corpse, durations counting into the negative, until res or
-- release finally produced an event. While dead the rows latch hidden; the
-- alive edge clears the latch and BOUNCES, so the rows come back re-parsed
-- rather than stale. Deliberate tradeoff (Danders, 2026-08-13): auras that
-- legitimately persist through death are hidden while dead too.
function Handle:_setDeathLatch(on)
    on = on or nil
    if self._deathLatched == on then return end
    self._deathLatched = on
    self:_applyVisibility()
    if not on then
        -- Re-parse on revival: the death window produced no aura events, so the
        -- standing parse predates the death. Refresh() is combat-aware (falls
        -- back to a mark-dirty that the next aura event flushes).
        self:Refresh()
    end
end

-- ============================================================
-- GATE EVENT LOG — the IDGATE debug category, transitions only
-- ============================================================
-- Every gate flip (park/hide/recovery, slot twins, death and cinematic latches)
-- logs under its OWN console category, IDGATE, so a tester chasing "auras
-- vanished" can enable just the verdict trail without the rest of the
-- AURACONTAINER firehose. Opt-in like every other category — nothing is written
-- unless the user turns it on. Each verdict line carries the probe that broke
-- trust (see IdentityUnavailable and the `why` locals). One shared helper so
-- every writer lands in the same lane; DF:Debug already sanitises secret args.
local function GateLog(fmt, ...)
    DF:Debug("IDGATE", fmt, ...)
end

-- ☠☠☠ THE RECOVERY EDGE IS THE ONLY THING THAT RE-PARSES A FAIL-OPEN POOL, AND IT FIRES
-- EXACTLY ONCE. `_idGateAssist` used to be stamped BEFORE the re-parse was attempted and
-- unconditionally, so a recovery that could not actually re-parse still burned the edge:
-- `was == false` was never true again, and the pool stayed fail-open for the rest of the
-- session. That is the "AD effects just stop working, reload fixes it" class -- five
-- separate reports, 2026-08-19/21 (Ruben x2, Beans, Immozaan, hEaLtReEPhD, and Krathe's
-- own "icons got stuck and AD effects stopped working").
--
-- ★ THE TRIGGER IS SUSTAINED COMBAT, NOT ANY PARTICULAR CONTENT. Only the Hide/Show
-- bounce re-reads candidateFilters, and NativeBackend:refresh cannot bounce a container
-- in combat -- it falls back to UpdateAllAuras, which repaints from the candidate set it
-- already has, i.e. precisely the stale set. So the edge is lost whenever trust recovers
-- BEFORE the pull ends, and every one of the triggers can do that: a death and a rez, a
-- cinematic, a vehicle, phasing, a disconnect.
-- ⚠ Do NOT narrow this to keys. Raid is at least as good a repro and arguably better --
-- a battle rez is a false->true assist edge landing squarely mid-fight, boss cinematics
-- and platform phases fire without dropping combat, and encounters run far longer than a
-- dungeon pull, so there is more time for a flip to happen inside one. (First written as
-- "an M+ bug"; corrected after Krathe reported it in raid, 2026-08-21. The mechanism
-- never had a dungeon term in it -- only the example did.) What it is NOT is a
-- world/overworld bug: out there you are usually out of combat when trust returns, the
-- bounce runs, and nobody ever sees this.
-- A backend that does not exist yet -- a container whose build was deferred to combat end
-- -- burned the edge the same way, in any content.
--
-- ★ Now the edge is consumed only when a real re-parse lands. Otherwise the verdict stays
-- false, so the NEXT gate pass sees the same false->true transition and tries again, and a
-- combat-end retry is queued so it does not have to wait for one. Both halves matter: the
-- retry guarantees the recovery, the un-consumed verdict makes it idempotent.
function Handle:_noteGateRecovery(can)
    local was = self._idGateAssist
    local now = can and true or false
    if was == false and now then
        GateLog("recovered unit=%s - re-parsing (pool was fail-open)",
            tostring(self.config and self.config.unit))
        if not self:Refresh() then
            -- Deliberately NOT stamping _idGateAssist, and not clearing the cinematic
            -- latch: neither may advance past a re-parse that did not happen.
            self._pendingGateReparse = true
            self:_registerRegen()
            GateLog("recovery unit=%s could not re-parse (combat/no backend) - "
                .. "edge held, retry queued for combat end",
                tostring(self.config and self.config.unit))
            return
        end
        -- AFTER the bounce, deliberately: the whole point of the cinematic latch
        -- is that the frames reappear already re-parsed, not one frame before.
        -- skipReparse: the Refresh above IS that bounce; the latch clear would
        -- otherwise run a second one on the same edge.
        self:_setCineLatch(nil, true)
        -- A pass can recover BEFORE the combat-end drain gets its turn. Clear the
        -- retry debt too, or the drain would run a spurious bounce next regen on a
        -- pool this pass just re-parsed.
        self._pendingGateReparse = nil
    end
    self._idGateAssist = now
end

-- ★ THE BOARDING WINDOW. `UnitCanAssist` does not flip the instant you take control of
-- an NPC -- it flips once the seated state lands, and the gap is a visible flash of
-- unfiltered icons on your own frame (Krathe, on 851917eb, which fixed the steady state
-- and left this).
--
-- `UnitUsingVehicle` is true through the BOARDING and EXITING transitions as well as the
-- seated state, so it closes that gap. This is a better SIGNAL, not another event to
-- catch -- the same correction as measuring a level from the frame rather than from
-- whatever it happens to be parented to.
--
-- ⚠ Self only, deliberately. Another player in a vehicle is still assistable and their
-- pool is still filtered; it is the OCCUPANT whose own identity data goes away.
-- ☠ `UnitIsUnit`, not `unit == "player"` -- in raid frames your own token is `raidN`, so
-- a string compare misses your own frame entirely. (The existing `isOwn` below still uses
-- the string compare; it only feeds branch (2), where the test is belt-and-braces,
-- but it is the same latent bug and worth a look.)
-- Fail-open on a refused or secret read, matching every other probe in this gate: any
-- doubt SHOWS.
-- ★ DISCONNECTED and DEAD/GHOST — two more states with no identity to filter on.
--
-- ☠ THESE WERE EXCLUDED EARLIER THE SAME DAY AND THE REASONING WAS WRONG. It ran:
-- "an offline or dead unit has no aura data streaming, so there is no pool to fail open."
-- Ghost auras stream. A user reported unfiltered debuffs on players who had died and were
-- carrying the ghost aura (Discord, 2026-08-13) — which is exactly the evidence that
-- exclusion named as the condition for reversing it, so it is reversed here rather than
-- argued with. ★ Worth keeping as the shape of the mistake: the claim was about the
-- ENGINE's behaviour and was reasoned out rather than measured, in a file where that has
-- now cost a full day.
--
-- ⚠ NON-SELF ONLY, matching the assist probe's own shape. Your own frame while dead is
-- still yours to read, and blanking it is the failure the original isOwn exemption was
-- written to prevent.
-- ⚠ Accepted cost, Krathe's call with the tradeoff stated: filtered rows go EMPTY for
-- every corpse in a wipe. They currently render unfiltered, so empty is the better
-- failure — but it is a visible change, not a silent one.
-- Fail-open on a refused or secret read, like every other probe in this gate.
-- Returns the REASON string when identity data is unavailable, nil otherwise —
-- truthy exactly when the old boolean was true, and the string feeds GateLog so
-- a field log says WHICH probe broke trust, not just that one did.
local function IdentityUnavailable(unit)
    local okC, connected = pcall(UnitIsConnected, unit)
    if okC and not (issecretvalue and issecretvalue(connected)) and connected == false then
        -- ☠☠ PLAYERS ONLY — AN NPC HAS NO CONNECTION, SO UnitIsConnected READS FALSE
        -- FOR IT. This probe is the SEVENTH consumer of that API in the addon and was
        -- the only one without the guard; the other six all carry it, added by #989 /
        -- #1042, and one of them names the very unit class that broke here:
        -- Frames/Update.lua:520 "a pinned NPC (Lura's healable crystals) rendered as an
        -- offline player ... Only a player can be offline." (Also Update.lua's fast
        -- path, ElementAppearance.lua twice, Frames/Core.lua and the missing-buff gate
        -- in Features/Auras.lua.) This one arrived later, when dead/disconnected were
        -- folded into the assist verdict, and the sibling sweep never reached it.
        --
        -- The consequence was total on a friendly NPC frame: "offline" makes the caller
        -- set can = false, which marks the handle untrusted, which parks every gated
        -- group at maxFrameCount 0 — and _noteGateRecovery only re-parses on a
        -- false->true ASSIST edge, which an NPC never produces. So the row was dark from
        -- the moment it was built and stayed dark for the container's whole life. Field
        -- report: pinned boss frames on friendly NPCs showing no auras at all with Hide
        -- Auras unchecked (Ruben, 2026-08-16, on "Dusk Crystal" — the same NPC family).
        -- ⚠ Only the CONNECTED half is scoped. UnitIsDeadOrGhost below is meaningful for
        -- an NPC and stays as it is.
        -- ★ Fails OPEN on a refused or secret UnitIsPlayer, like every other probe in
        -- this gate: if we cannot confirm the unit is a player we cannot conclude
        -- "offline" means anything, and any doubt SHOWS.
        local okP, isPlayer = pcall(UnitIsPlayer, unit)
        if okP and not (issecretvalue and issecretvalue(isPlayer)) and isPlayer then
            return "offline"
        end
    end
    local okD, dead = pcall(UnitIsDeadOrGhost, unit)
    if okD and not (issecretvalue and issecretvalue(dead)) and dead == true then
        return "dead/ghost"
    end
    return nil
end
-- ☠☠ PROBE THE POOL SWAP, NOT THE PASSENGER FLAG. This asked UnitUsingVehicle, which is
-- true for ANY vehicle association -- including riding an encounter's transport or
-- platform entity, where your action bars, your unit token and YOUR AURA POOL all stay
-- yours. Field-caught 2026-08-21 (Krathe, raid): the player was flagged self-vehicle for
-- 5m38s of a fight (14:49:18 park -> 14:54:56 recover) while healing normally -- casting
-- the whole time, so the bars were provably never swapped -- and every gated pool on the
-- OWN frame parked for the duration: "my PoM was not showing on myself but was showing
-- on other players". The backstop ticker re-probed every 5s throughout and UsingVehicle
-- kept answering true, so this was the verdict being wrong, not an edge being missed.
--
-- ★ The signal the gate actually cares about is "does this frame's pool belong to the
-- vehicle right now", and the client's own compact frames answer that with
-- UnitHasVehicleUI (BlizzardInterfaceCode: CompactUnitFrame's shouldTargetVehicle) --
-- the frame retargets to the vehicle unit exactly and only when that is true. No swap,
-- no mismatch, nothing to distrust.
--
-- ⚠ THE TRADE, taken knowingly: the pre-seat boarding window this probe was added for
-- (UsingVehicle true before HasVehicleUI lands) is now covered by the on-the-spot
-- UNIT_ENTERING/ENTERED_VEHICLE sweeps instead of by the probe itself -- worst case is
-- one dispatch of a real vehicle's swapped pool rendering before the ENTERED sweep
-- parks it. The gate's stated fail-safe direction is SHOW; five minutes of your own
-- tracked buffs hidden in a raid fight is the wrong side of that rule, one garbage
-- frame on a genuine vehicle boarding is the right side.
local function SelfIsUsingVehicle(unit)
    if not unit then return false end
    local okSame, same = pcall(UnitIsUnit, unit, "player")
    if not okSame or not same then return false end
    -- Fallbacks kept for a client without the primary (belt-and-braces; all three are
    -- ancient APIs) -- but never "UsingVehicle wins over HasVehicleUI": when the
    -- precise signal exists it is the only one consulted.
    local probe = UnitHasVehicleUI or UnitUsingVehicle or UnitInVehicle
    if not probe then return false end
    local ok, v = pcall(probe, "player")
    if not ok then return false end
    if issecretvalue and issecretvalue(v) then return false end
    return v and true or false
end

function Handle:_hasGatedGroups()
    local b = self.backend
    local g = b and b.gatedGroupKeys
    if not g then return false end
    return next(g) ~= nil
end

function Handle:_applyIdentityGate()
    local hide = false
    local why   -- the FIRST probe that broke trust this pass, for the gate log
    -- ★ `_hasGatedGroups` widens the probe to rows that are not HIDE-vulnerable but do
    -- carry identity-dependent GROUPS -- i.e. the debuff row. Without it the assist probe
    -- never ran for those handles and the park verdict could never flip.
    -- ☠☠ EVERY HANDLE IS PROBED NOW, and the three-way test this replaced is why a unit in
    -- another instance rendered a full debuff row.
    --
    -- filterVulnerableToIdentityGate returns false for ANY filter without "HELPFUL" on its
    -- first line, and a HARMFUL row carrying only excludeSpellIDs registers no gated keys.
    -- So the debuff row and the dispel overlay failed all three tests -- not vulnerable,
    -- not source-relative, no gated groups -- and the gate never ran for them at all. No
    -- probe, no verdict, nothing to actuate: /df debug idgate showed them vis=false why=-
    -- shown=true while the pools beside them were correctly hidden (Krathe, 2026-08-18).
    --
    -- The inner branches keep their own conditions, so this widens only WHICH handles reach
    -- the visibility probe. The assist/park logic below is untouched.
    if not AuraContainer._testMode then
        local unit = self.config and self.config.unit
        -- ☠ `unit ~= "player"` USED TO SIT ON THIS LINE, so your own frame was never
        -- probed at all — nothing ever NOTICED your own pool falling open, so it never
        -- got re-parsed. Probing always is what fixed that.
        --
        -- ☠☠ IT THEN SURVIVED ON THE ASSIST HIDE BRANCH BELOW, AND THAT WAS WRONG.
        -- The reasoning was "a frame you cannot see during a cinematic needs no hiding" —
        -- true when written, and made obsolete by the cinematic latch that landed after
        -- it. CineLatchAll (bottom of this file) latches EVERY vulnerable handle with no
        -- isOwn check, and _noteGateRecovery unlatches only AFTER the recovery Refresh,
        -- so own frames are already hidden through a cinematic and come back re-parsed.
        -- The exemption was therefore contributing nothing to the case it was written
        -- for, and its only live effect was the case with no cinematic and no latch:
        -- ★ a VEHICLE. Take control of an NPC and UnitCanAssist goes false for minutes
        -- while you look straight at the frame -- /df debug idgate showed every party1
        -- handle hidden and every player handle open (field-caught, Krathe 2026-08-13).
        -- Removing it costs a comparison and needs no timer, event or new state.
        -- ⚠ Branch (2) keeps isOwn: you are always UnitIsVisible to yourself, so it is
        -- belt-and-braces there rather than a behaviour decision.
        if type(unit) == "string" and UnitExists(unit) then
            -- ☠ UnitIsUnit, not a string compare: in raid layouts your own token is
            -- `raidN`, so `unit == "player"` never matched your own frame there and the
            -- exemption below silently did not apply to you. A no-op in practice today
            -- (you are always visible and same-phase to yourself, so neither probe trips)
            -- — but the compare is wrong, and the next probe added here may not be as kind.
            local okOwn, ownSame = pcall(UnitIsUnit, unit, "player")
            local isOwn = (okOwn and ownSame) and true or false
            -- (1) Cross-faction / non-assistable: includeSpellIDs / category tokens
            --     fail open. Signal: UnitCanAssist.
            -- ☠ Runs for a hide-vulnerable pool OR any row with gated groups. `hide`
            -- still requires vulnerability; the PARK needs only the trust verdict, which
            -- is the same answer put to a different use.
            if self._idGateVulnerable or self:_hasGatedGroups() then
                local ok, can = pcall(UnitCanAssist, "player", unit)
                if ok then
                    if issecretvalue and issecretvalue(can) then can = true end
                    -- ★ Overrides a still-true assist during the boarding window, before
                    -- the seated state lands — see SelfIsUsingVehicle. Folded into `can`
                    -- rather than straight into `hide` on purpose: _noteGateRecovery then
                    -- records the false, so leaving the vehicle is a real false→true edge
                    -- and re-parses. Setting `hide` alone would hide correctly and never
                    -- rebuild the pool.
                    if can and SelfIsUsingVehicle(unit) then can = false; why = "self-vehicle" end
                    -- ★ Disconnected / dead / ghost — see IdentityUnavailable. Folded
                    -- into `can` like the vehicle probe, so a rez or a reconnect is a
                    -- real false→true edge and re-parses the pool rather than just
                    -- un-hiding a stale one.
                    if can and not isOwn then
                        local unavail = IdentityUnavailable(unit)
                        if unavail then can = false; why = unavail end
                    end
                    if not can and not why then why = "cannot-assist" end
                    -- Trust verdict for the PARK path (see the park block below).
                    self._idGateUntrusted = (can == false) or nil
                    self:_noteGateRecovery(can)
                    -- ☠ NOT `and not isOwn` — see the block above. Cinematics are the
                    -- latch's job; this branch is what covers a vehicle.
                    --
                    -- ★★ HIDE IS NOW THE FALLBACK, NOT THE RESPONSE. The park below empties
                    -- exactly the records the engine can skip and leaves their siblings
                    -- rendering; hiding empties the handle. Since ONE vulnerable record
                    -- marks the whole handle (see the build loop), the old behaviour blanked
                    -- a buff row's token groups because an unrelated spell-ID group sat
                    -- beside them — over-hiding, and the opposite of what the gate is for.
                    -- So hide only when the park cannot express it: no gated keys were
                    -- registered at all, which means a build shape the park does not cover.
                    -- ⚠ Deliberately NOT removed outright. If AddAuraGroup failed, or a
                    -- consumer produced a handle with no keys, the vulnerable pool would
                    -- otherwise render fully open with nothing suppressing it — the leak
                    -- this whole mechanism exists to stop. Fallback, not dead code.
                    if not can and self._idGateVulnerable and not self:_hasGatedGroups() then
                        hide = true
                    end
                end
            end
            -- (2) Not in your visible world (different instance/phase): the
            --     source-relative "mine" filter (PLAYER token / isFromPlayerOrPlayerPet)
            --     fails open — the engine can't attribute a caster. Signal: UnitIsVisible.
            --     Fail-safe (matches the assist gate): only hide on a definite,
            --     non-secret false; any doubt (pcall fail / secret) SHOWS.
            -- ☠ NO LONGER GATED ON _idGateSourceRelative. It was from the day it landed
            -- (ad0985c9), because it was written for one narrow failure: the PLAYER-token
            -- "mine" filter passing every caster's aura when the engine cannot attribute a
            -- caster. Sound reasoning, far too narrow for what the probe actually tells you.
            --
            -- UnitIsVisible is INSTANCE-SCOPED, not range-scoped -- true for a same-instance
            -- member far outside 40yd, false only across instances and phases
            -- (field-verified 3-case probe, see filterVulnerableToIdentityGate's header).
            -- A unit reading false is not in your world at all, so EVERY pool it renders is
            -- stale, not just the source-relative ones. Restricting the response to "mine"
            -- filters left a cross-instance unit rendering a full debuff row and dispel
            -- overlay while its buff bar was correctly blanked (Krathe, 2026-08-18).
            --
            -- ⚠ Widening is safe BECAUSE the signal is instance-scoped. Were it range-based
            -- this would blank half a raid's debuffs -- the exact failure class
            -- UNIT_CONNECTION / UNIT_FLAGS were registered for. Do not widen a range-based
            -- probe by analogy with this one.
            -- ⚠ isOwn still stands: you are always visible to yourself, so it stays
            -- belt-and-braces rather than a behaviour decision.
            if not hide and not isOwn then
                local okv, vis = pcall(UnitIsVisible, unit)
                if okv and not (issecretvalue and issecretvalue(vis)) and not vis then
                    hide = true; why = why or "not-visible"
                end
                -- ☠ THE "/phase" HALF OF THE COMMENT ABOVE WAS NEVER IMPLEMENTED. A unit
                -- in another phase, layer or Chromie time can be UnitIsVisible TRUE and
                -- still be unattributable, so the source-relative filter fails open with
                -- the visibility probe perfectly happy. UnitPhaseReason returns nil for
                -- same-phase and a reason otherwise (Features/Range.lua reads it the same
                -- way).
                -- ⚠ Only reliable within ~250yd (Frames/StatusIcons.lua). Past that it
                -- returns nil, which reads as "same phase", which SHOWS — the
                -- unreliability fails in the safe direction, so no distance guard.
                if not hide and UnitPhaseReason then
                    local okp, reason = pcall(UnitPhaseReason, unit)
                    if okp and not (issecretvalue and issecretvalue(reason)) and reason then
                        hide = true; why = why or "phased"
                    end
                end
            end
        end
    end
    -- Stash for /df debug idgate: the reason column answers "why is this row
    -- parked/hidden RIGHT NOW" without waiting for the next transition line.
    self._idGateWhy = (hide or self._idGateUntrusted) and why or nil
    -- Transition only. "My cross-realm friend's auras vanished" produced no log at
    -- all before this: the gate is two pcall'ed probes with deliberate fail-open /
    -- fail-safe asymmetry, and which one tripped is the whole answer. Fires on a
    -- CHANGE, so a stable gate costs one comparison.
    -- ★ THE PARK VERDICT, separate from the hide verdict below and computed from the
    -- SAME probe. `hide` empties the whole handle and is right for a HELPFUL pool, which
    -- fails open as a unit. A DEBUFF row is a set of records where only SOME depend on
    -- identity data, so it parks per group instead: the boss/role/priority and
    -- spell-ID-carrying records go to maxFrameCount 0 while the token records
    -- (CROWD_CONTROL / RAID / dispel) keep rendering. Emptying the row wholesale would be
    -- a far worse failure than the leak it is meant to stop.
    -- ☠ Blizzard's harmful rule is the MIRROR of the helpful one -- spell-ID filters are
    -- skipped when you CAN assist, not when you cannot -- so this is not the same
    -- condition in a different hat. It is driven by "is identity data trustworthy right
    -- now", which is what BOTH directions actually turn on.
    -- Collected across both blocks and emitted once at the end; see the note in the park
    -- block for why these were two lines and why one is better.
    local parkFlip, hideFlip
    local newParked = (hide or self._idGateUntrusted) and true or nil
    if self._idGateParked ~= newParked then
        local prevParked = self._idGateParked
        -- ☠ THE FLAG IS AN INPUT, NOT A RECORD. ApplyTuning READS _idGateParked to decide
        -- each gated group's maxFrameCount, so it has to be set before the call — which is
        -- why this cannot simply latch on success.
        self._idGateParked = newParked
        -- ☠ LOG DEFERRED TO THE JOINT LINE BELOW. park and hide are computed from the
        -- SAME probe and flip together on a HELPFUL pool, so this emitted two lines per
        -- unit per transition carrying the same unit and the same why. The sweep walks
        -- every handle and every slot handle, and its triggers are global -- one
        -- PLAYER_ENTERING_WORLD re-sweeps at 0s, 2s and 6s -- so a 40-unit raid produced
        -- hundreds of lines from a single zone-in, in a category that defaults ON. One
        -- line per transition says strictly more, because it shows both halves together.
        parkFlip = newParked and "ON" or "OFF"
        -- ApplyTuning is the LIVE setter path and reads _idGateParked, so this is one
        -- call rather than a rebuild.
        local ok = true
        if self.ApplyTuning then ok = pcall(function() self:ApplyTuning() end) end
        if not ok then
            -- ☠ REVERT ON FAILURE, OR THE REPAIR IS SUPPRESSED FOREVER. This same flag is
            -- the change detection two lines up, so leaving it on the INTENDED value after
            -- a failed apply records a state the container is not in — and the next sweep
            -- then sees flag == verdict and skips, permanently. The bad direction is the
            -- restore: trust comes back, ApplyTuning throws, and the gated records sit at
            -- maxFrameCount 0 with debuffs simply missing until some unrelated tuning pass
            -- happens by. The pcall is what makes that silent, and the pcall is here
            -- because we do not yet believe every setter in this family is combat-legal
            -- (SetUnit is queued for exactly that reason).
            -- Reverting costs one retried call per sweep while the failure persists; the
            -- sweep recomputes the verdict from live conditions each time, so it converges
            -- on whatever is true then rather than on what was true when it broke.
            self._idGateParked = prevParked
            -- Cleared so the joint line cannot claim a flip that was just undone.
            parkFlip = nil
            -- ⚠ WARN, not the INFO GateLog path: this is a hard failure that re-fires
            -- every sweep until it clears, and at INFO it was invisible to anyone with
            -- the log level raised -- i.e. to anyone filtering out the chatter it is
            -- buried in.
            DF:DebugWarn("IDGATE", "PARK APPLY FAILED unit=%s (combat=%s) - reverted, retries on next sweep",
                tostring(self.config and self.config.unit),
                tostring(InCombatLockdown and InCombatLockdown() or false))
        end
    end

    local newHidden = hide or nil
    if self._idGateHidden ~= newHidden then
        hideFlip = newHidden and "ON" or "OFF"
        self._idGateHidden = newHidden
        -- ⚠ TRANSITION ONLY. The sweep runs on every target change / roster event /
        -- loading screen; applying visibility unconditionally made every pass a
        -- frame-op on every vulnerable handle — and worse, it was the resurrection
        -- path for rows a consumer had hidden raw (before SetIntentShown existed).
        -- A stable verdict now touches nothing. The rebuilt-onto-non-vulnerable
        -- case still clears its stale flag: that IS a transition.
        self:_applyVisibility()
    end

    -- ★ ONE LINE PER GATE TRANSITION, carrying both halves. Reads
    --   gate unit=party2 why=- park=OFF hide=OFF (vuln=true srcRel=true)
    -- where a dash in a slot means that half did not flip on this pass -- which is itself
    -- worth seeing, because park and hide flipping apart is the interesting case and used
    -- to be indistinguishable from two ordinary lines that happened to arrive together.
    if parkFlip or hideFlip then
        GateLog("gate unit=%s why=%s park=%s hide=%s (vuln=%s srcRel=%s)",
            tostring(self.config and self.config.unit), tostring(why or "-"),
            parkFlip or "-", hideFlip or "-",
            tostring(self._idGateVulnerable or false),
            tostring(self._idGateSourceRelative or false))
    end
end

-- Enable/disable the container's parse+bind. ★ 68914 re-verified: SetEnabled is NOT
-- combat-locked — it's plain mixin state (AuraContainerSharedMixin:SetEnabled = a field
-- write + UpdateEventRegistrations/UpdateAllAuras, no protected calls; /al combatops
-- ran it clean mid-combat). The deferral is KEPT for DISPLAY correctness, not legality:
-- an addon-context enable sets the dirty flags but cannot ARM the private-side
-- processor (see NativeBackend:refresh), so a combat enable wouldn't render until the
-- next aura event anyway — flushing at regen is the deliberate, deterministic choice.
function Handle:_applyEnabled(on)
    on = on and true or false
    self.config.enabled = on
    if InCombatLockdown() then self:_queueOp("enable"); return end
    if self.backend then self.backend:setEnabled(on) end
end

-- Retarget the container's unit. ★ 68914 re-verified: SetUnit is NOT combat-locked
-- (plain mixin state; Blizzard's own TargetFrame.lua:65 retargets its container on
-- every target change, i.e. constantly in combat; /al combatops ran it clean). The
-- deferral is KEPT for DISPLAY correctness: the partition kick that makes a retarget
-- actually render (the Hide/Show bounce in NativeBackend:setUnit) is OOC-only, so a
-- combat retarget would keep DISPLAYING the old unit's parse until the next aura
-- event — the drives hide the row till regen instead, which beats showing the wrong
-- player's auras. (If show-with-brief-staleness is ever preferred over hide-till-regen,
-- this deferral + the drives' hidden-flag logic is the seam to change — Krathe's call.)
function Handle:SetUnit(unit)
    self.config.unit = unit
    self:_updateDynRefresh()   -- re-evaluate dynamic-unit auto-refresh for the new token
    -- A retarget is a new identity: a death latch taken for the OLD unit is
    -- meaningless now (and would stick until the NEW unit died and revived).
    -- ☠ RE-SEED, don't just clear. The latch is UNIT state: dropping the old unit's is
    -- half the retarget — the NEW unit may already be dead, and the next death edge for
    -- an already-dead unit never comes, so a clear-only retarget onto a ghost rendered
    -- the corpse's auras until an unrelated edge swept (2026-08-18 audit).
    self:_setDeathLatch(AuraContainer._deathLatchedUnits[unit] or nil)
    self:_applyIdentityGate()  -- the last gate verdict was for the OLD unit (plain frame; combat-safe)
    -- In combat, defer JUST the retarget (a full rebuild would leak a container + N
    -- buttons every combat on roster churn); "retarget" re-runs SetUnit at regen.
    if InCombatLockdown() then self:_queueOp("retarget"); return end
    if self.backend then self.backend:setUnit(unit) end
end

-- In-place cosmetic RESTYLE (colours / sizes / fonts / offsets / layout). NOTE: this
-- REPLACES config.style (it is not a merge) and only re-applies always-updated props —
-- it does NOT create/remove regions or change creation-frozen opts (duration
-- expiredText/zeroText/updateInterval/colorCurve, bar interpolation/direction, dispel show flags). To toggle a
-- region on/off or change a frozen opt, use Rebuild(). pcall-guarded so a restyle fault
-- can't escape into a GUI callback.
-- Resolve + cache the pixel-perfect flag and (when on) swap config.layout for a
-- pixel-quantized copy (see the PIXEL PERFECT block above applyContainerLayout).
-- Runs at every config/layout adoption: _build (covers Create + Rebuild) and
-- ApplyStyle. Pure table math + a db read — combat-safe.
function Handle:_ppPrepare()
    self._pp = resolvePixelPerfect(self)
    -- /df debug ppdump discriminator: the pixel-scale CACHE value this handle's layout
    -- was quantized with. UIParent's scale can settle AFTER login builds — a
    -- stale cache here bakes every snapped size subtly wrong until a restyle.
    self._ppCacheAt = (DF.GetPixelScale and DF:GetPixelScale()) or nil
    local L = self.config and self.config.layout
    if self._pp and type(L) == "table" and not L._ppQuantized then
        self.config.layout = quantizeLayout(L)
    end
end

function Handle:ApplyStyle(style, layout)
    if type(style) == "table" then
        self.config.style = style
    end
    if type(layout) == "table" then
        self.config.layout = layout   -- optional geometry swap (size/scale/spacing/growth/offsets)
    end
    self:_ppPrepare()
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
    -- hot-apply through the live SetFlowLayout*/SetAuraGroupLayout mutators instead; a
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
            -- Member buttons restyle from their own record view here too, or an
            -- ApplyStyle would repaint them with the container's shared style and
            -- silently undo per-member styling — the same revert that used to eat the
            -- important-debuff size step, one path along.
            styleButton_regions(b, styleConfigFor(self, b))
            -- Per-record overrides, re-applied from the button's stash. This path calls
            -- styleButton_regions DIRECTLY rather than going through _acceptSlot, so it
            -- does not inherit the re-apply there — and styleButton_regions always resets
            -- the button to the SHARED config size. Without this line the important-debuff
            -- size step survived a rebuild but was silently reverted by every ApplyStyle,
            -- which is why a test frame snapped back to normal while a pinned frame (which
            -- rebuilds instead of restyling) looked correct. Traced 2026-07-30: the button
            -- measured the SCALED size immediately after applyRecordStyle, so the revert
            -- was always downstream, never in the style itself.
            applyRecordStyle(b, self, b.dfImpRecStyle)
            if native then
                -- ☠ BUILD-TIME SHAPE, not the live global — same reason as
                -- _makeInitializeFrame. A test-shaped container restyled while the global
                -- reads false would bind the native setters onto preview buttons, and
                -- Blizzard's SetIcon then repaints the curated art with the hidden sample
                -- aura's. A container cannot change shape (groups are add-only), so the
                -- shape it was BUILT with is the only correct answer here.
                if (self.backend and self.backend.builtInTestMode) then
                    -- TEST MODE: re-PAINT, never bind. Binding here was the P5
                    -- preview killer: any settings refresh re-ran this loop and
                    -- registered the native setters on the preview buttons, so
                    -- Blizzard instantly overwrote the curated icons with the
                    -- sample auras' random art and zero durations (static swipes)
                    -- — until the next rebuild repainted them (Krathe 2026-07-10).
                    -- _dfTestIndex = the curated entry this button was stamped with at
                    -- create (fixed for the styled group, sequential within the shared
                    -- plain group). Repaint the SAME entry — creation order is not
                    -- layout order, so recomputing it here would reshuffle the preview.
                    self:_paintTestSlot(b, b._dfTestIndex or i)
                else
                    -- Record view here as well: an ApplyStyle re-binds the native
                    -- setters, so binding from the shared config would undo a member's
                    -- duration spec on the next restyle even though the build got it
                    -- right. Same pairing as _bindNativeSlot.
                    bindNative(b, styleConfigFor(self, b))
                end
            end
        end)
        if not ok and not warnedRestyle then
            warnedRestyle = true
            DF:DebugWarn(DBG, "ApplyStyle restyle failed: %s", tostring(err))
        end
    end

    -- ★ OWN-FRAME PREVIEW: RE-PIN THE BOX, or a layout change never previews.
    -- The loop above restyles the BUTTONS, which is why style edits (text toggles,
    -- colours, fonts) always previewed correctly and made this look fine. But the
    -- preview's slots hang off `_ownPreviewBox`, NOT off the native container — so
    -- backend:applyLayout re-pinning the container moves nothing here, and
    -- `_flowPreviewLayout` was reachable ONLY from _buildOwnPreview. Anchor, offsets,
    -- growth, spacing and wrap therefore sat unapplied until the next REBUILD, i.e.
    -- until test mode was switched off and on again — exactly how it was reported
    -- ("have to do this over and over until desired position", defensive row, 5.1.3).
    -- ⇒ Previews differ in DATA, never in RENDERING: live re-pins on a layout change,
    -- so the preview re-pins too, through the same shared flow.
    -- ☠ LAST, AND THAT IS LOAD-BEARING: the flow measures each button, and the restyle
    -- loop above has only just re-applied their size. Flowing first lays the box out
    -- against the PREVIOUS icon size.
    if self._ownPreviewBox and self._ownPreviewSlots then
        local count = math.min(self._ownPreviewCount or 0, #self._ownPreviewSlots)
        if count > 0 then self:_flowPreviewLayout(self._ownPreviewSlots, count) end
    end
end

-- Structural filter change -> full rebuild (can't mutate a live filter set safely).
-- ☠ PARKING-UNSAFE BY CONSTRUCTION, so it opts out. This changes the filter set
-- WITHOUT going through a consumer's structural signature, so _structKey no longer
-- describes this handle's structure: parking the outgoing container would file it under
-- a key that has just stopped being true, and a later Rebuild presenting that key would
-- re-adopt a container built for a different filter set. Dropping the key disables both
-- halves (no park, no re-adopt) and releasing any existing park stops a stale one being
-- matched later. Zero callers today -- this is a guard for the next one.
function Handle:SetFilter(filter)
    self.config.filter = filter
    self._structKey = nil
    self:_releaseParked()
    self:_rebuild()
end

-- Public structural rebuild — for changes ApplyStyle can't do live: max, toggling a
-- region on/off, or a creation-frozen opt (bar direction, duration expiredText/zeroText/
-- updateInterval, dispel flags). Optionally merge a partial config first. Combat-guarded (defers to regen).
-- Structural rebuild. `config` REPLACES the handle's config WHOLESALE when given —
-- both bridge callers (buff/defensive) pass a COMPLETE freshly-built config. The
-- previous pairs()-merge could never CLEAR a key that went nil: a disabled
-- max-duration filter / sort / blacklist stayed declared on every later rebuild
-- (the "toggle does nothing until /reload" bug — candidateFilters survived OFF).
-- A caller with a genuine partial delta must merge into handle.config itself.
-- structKey (optional): the CONSUMER's structural signature for this config -- the exact
-- string whose change is what made this a Rebuild rather than an ApplyTuning/ApplyStyle.
-- Supplying it enables container parking (see Handle:_parkContainer): the outgoing
-- container is kept quiesced and re-adopted if a later rebuild presents the same key,
-- instead of being stranded for the session. Omit it and behaviour is exactly as before.
function Handle:Rebuild(config, structKey)
    if type(config) == "table" then
        self.config = config
    end
    if structKey ~= nil then self._structKey = structKey end
    self:_rebuild()
end

-- In-place TUNING mutate — max / sort / candidateFilters, the three live-tunable group
-- keys — WITHOUT the teardown+recreate a Rebuild costs (flicker + a stranded frame set;
-- WoW never GCs frames). `tuning` REPLACES all three keys wholesale (same lesson as
-- Rebuild: a merge could never CLEAR a toggled-off key) — callers pass the complete trio
-- { max, sort, candidateFilters }; an omitted key is CLEARED, not kept. Per-record
-- candidateFilters still ride config.filter records; ApplyTuning does NOT read a
-- filter list from `tuning`, but the flush re-derives per-record cf from config.filter
-- — so the SANCTIONED way to tune them (the Wave-1 row drivers do this; replicate it)
-- is the consumer PRE-SWAP: assign handle.config.filter a fresh GROUP-IDENTICAL list
-- first, then call ApplyTuning. Legal ONLY when the caller's structural sig pins every
-- record's filter string + key (record identity unchanged, only candidateFilters
-- differ) — group keys must line up with the declared groups. Changing the filter SET
-- itself (strings/keys/record count) — or anything else — is structural: use
-- Rebuild/SetFilter.
-- Combat: no native tuning setter ever runs in lockdown (matches oUF/MSUF — neither
-- applies user tuning mid-combat). Defers exactly like ApplyStyle: mark pending, flush
-- via applyGroupTuning at regen — the deferred flush costs no flicker/leak either.
function Handle:ApplyTuning(tuning)
    if type(tuning) == "table" then
        self.config.max = tuning.max
        self.config.sort = tuning.sort
        self.config.candidateFilters = tuning.candidateFilters
        -- ★ FILTER STRINGS (2026-08-04). applyGroupTuning re-derives records from
        -- config.filter, so the fresh strings have to land here or the push is a
        -- no-op. This SUPERSEDES the manual pre-swap the debuff-group consumer
        -- does (Factory.lua) — that assignment is now redundant, not wrong.
        -- ☠ nil does NOT clear, unlike the three above. normalizeFilters falls back
        -- to a bare "HELPFUL" record when config.filter is nil, so a caller passing
        -- a partial tuning table would silently turn a debuff row into a buff row.
        -- Only assign what was actually supplied.
        if tuning.filter ~= nil then self.config.filter = tuning.filter end
    end
    -- Test mode: the preview's per-slot pin groups can't be tuned in place
    -- (maxFrameCount = 1 by design) — rebuild so the preview honours the new cap.
    -- _rebuild carries its own combat gate.
    if AuraContainer._testMode then
        self:_rebuild()
        return
    end
    if InCombatLockdown() then
        self._pendingTuning = true
        self:_registerRegen()
        return
    end
    if self.backend and self.backend.applyGroupTuning then
        self.backend:applyGroupTuning()
    end
end

-- ═══ HELPER GATE: BROADCAST AND BACKSTOP ═══
-- Does this handle carry one of ours? Checked against STORED config, never the gated result,
-- so it answers the same either side of an edge.
-- One field, and no walk over the records: the mark lives on the config itself, so a group
-- whose records carry their own candidate filters is recognised the same as any other.
local function helperGateHandleIsOurs(h)
    local cfg = h and h.config
    return (cfg and cfg.dfGate) and true or false
end

-- Flip the switch and broadcast. Returns how many containers were re-pushed.
-- ☠ The broadcast is an ALREADY-CLEARED in-combat operation: applyGroupTuning is what the
-- consumers already call, and the probe cleared it. Only the table it carries changes. Note
-- it pushes filter strings and max/sort alongside candidate filters, so a gate edge
-- early-flushes any _pendingTuning a container queued mid-combat.
--
-- ☠ ONLY OUR CONTAINERS. applyGroupTuning runs an immediate UpdateAllAuras per group key and
-- has no equality guard of its own, so broadcasting to every handle in the addon would cost a
-- full aura re-parse on each one for a gate flip that concerns a handful.
function AuraContainer.SetHelperGate(dark)
    helperGateDark = dark and true or false
    local n = 0
    for h in pairs(AuraContainer._handles or {}) do
        local b = h and h.backend
        if b and b.applyGroupTuning and not h._destroyed and helperGateHandleIsOurs(h) then
            -- ⚠ pcall(fn, self) not pcall(function() ... end) -- this file's own rule, recorded
            -- at applyGroupTuning's tail: the closure form allocates one per call for no gain,
            -- and protection is identical. A gate edge walks every owned handle twice a Power
            -- Infusion cycle, in combat, so this is exactly the path that rule was written for.
            local ok = pcall(b.applyGroupTuning, b)
            if ok then n = n + 1 end
        end
    end
    -- ☠ SLOTS TOO, NARROWED TO OURS. SetAuraSlotCandidateFilters has no engine-side
    -- equality guard -- every call clears and re-parses -- so an unnarrowed walk would
    -- re-parse every placed indicator in the addon per gate flip. Read off the module table,
    -- not a local: the registry is declared thousands of lines below this function, and a
    -- later-declared local here would silently read as a nil global (this file has been
    -- bitten by exactly that; see the note above GateAppliesTo).
    for h in pairs(AuraContainer._slotHandles or {}) do
        if h.config and h.config.dfGate and h._applyHelperGate then
            local ok, applied = pcall(h._applyHelperGate, h)
            if ok and applied then n = n + 1 end
        end
    end
    return n
end

function AuraContainer.GetHelperGate() return helperGateDark end

function AuraContainer.SetHelperExcludedRoles(roles)
    helperExcludedRoles = roles
    return AuraContainer.SetHelperGate(helperGateDark)   -- re-push so it takes effect now
end

function AuraContainer.GetHelperExcludedRoles() return helperExcludedRoles end

-- Backstop for pushes swallowed during lockdown by the pcall'd native setters. Idempotent,
-- out of combat, and the same shape the identity gate already uses for its combat-exit
-- re-verify.
--
-- ☠ ROLES ARE READ AT PUSH TIME, so a role that changes after the last push is not seen: set
-- the exclusions, swap spec, and the container keeps the answer from before the swap. Re-push
-- on anything that can move a role. (This makes us notice promptly when the game's answer
-- CHANGES. It cannot make the game's answer FRESH -- see the staleness note above.)
local helperGateRegen = CreateFrame("Frame")
helperGateRegen:RegisterEvent("PLAYER_REGEN_ENABLED")
helperGateRegen:RegisterEvent("PLAYER_ROLES_ASSIGNED")
helperGateRegen:RegisterEvent("GROUP_ROSTER_UPDATE")
helperGateRegen:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
helperGateRegen:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
helperGateRegen:SetScript("OnEvent", function()
    AuraContainer.SetHelperGate(helperGateDark)
end)

-- Force a re-scan of the container. 68569: UpdateAllAuras() is an addon-callable
-- dirty-mark (processed on the next OnUpdate while visible) — the real refresh. Use on
-- a dynamic-unit consumer (target/focus/mouseover) when the underlying unit changes but
-- the token does not. Falls back to an out-of-combat Hide/Show bounce if absent.
-- Returns true only when the backend performed a genuine re-parse. A missing backend
-- (build deferred to combat end) and the in-combat repaint both answer false.
function Handle:Refresh()
    if not self.backend then return false end
    local ok, res = pcall(function() return self.backend:refresh() end)
    if not ok then
        if not warnedRefresh then
            warnedRefresh = true
            DF:DebugWarn(DBG, "Refresh bounce failed: %s", tostring(res))
        end
        return false
    end
    return res and true or false
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
-- park = true: quiesce for re-adoption rather than discard (Handle:_parkContainer).
-- Everything that must stop regardless still stops -- the border animation drivers and
-- the test duration bindings both tick from OUTSIDE the container subtree, so a parked
-- container that skipped them would keep them running against hidden textures, which is
-- the exact bug the driver-stop chokepoint below exists to prevent. What park skips is
-- only the DISCARD half: the button cache and the slot counter survive, because the
-- re-adopted container still owns those very buttons and the counter still indexes the
-- lazily-created batches correctly.
function Handle:_teardownContainer(park)
    if self.backend then
        self.backend:teardown(park)
        if not park then self.backend = nil end
    end
    -- Stop each slot border's animation BEFORE dropping the slot refs. Slot
    -- borders are secretRect widgets whose OnUpdate motion driver is hosted on
    -- UIParent (the aura-button subtree disables OnUpdate through descendants),
    -- so it does NOT auto-hide when the container hides -- an un-stopped driver
    -- would keep ticking against the torn-down slot's textures. StopAnimation
    -- clears the OnUpdate + hides the driver; idempotent on borders that had no
    -- animation running. This is the single teardown chokepoint for winner
    -- change / de-config / rebuild / destroy (all route through here).
    -- ☠ These buttons are RESTRICTED by the time we get here (auras secret ->
    -- DenyTaintedAccessWhenAurasAreSecret, and from 12.1.0.69382 that covers their
    -- descendants, i.e. these very borders). Container borders never animate (the
    -- ANIMATION FILTER strips it), so StopAnimation must -- and does -- return
    -- before touching a region on a never-animated border; the old unconditional
    -- edge-alpha reset threw here on entering an instance and aborted the whole
    -- refresh (bug #1079). Do not add any other write to slot subtrees in here.
    if DF.Border then
        for _, slot in pairs(self.buttons) do
            -- Guarded for the same reason as the binding loop just below, and as
            -- layoutRow: the border's edge textures are children of the aura button, so
            -- they go forbidden with it, and StopAnimation's resetEdgeAlphas then throws
            -- on SetAlpha. Unguarded, that unwound out of THIS loop and the remaining
            -- slots never got stopped at all -- their UIParent-hosted OnUpdate drivers
            -- kept ticking against torn-down textures, which is the exact leak this
            -- chokepoint exists to prevent (Krathe, 2026-08-20).
            -- ⚠ unregisterAnimTick runs FIRST inside StopAnimation, so the driver for a
            -- refused border is still stopped; what is lost is only its cosmetic alpha
            -- reset, which cannot be applied to a forbidden object anyway.
            if slot and slot.dfBorder then
                if not pcall(DF.Border.StopAnimation, DF.Border, slot.dfBorder) and not warnedTeardownAnim then
                    warnedTeardownAnim = true
                    DF:DebugWarn(DBG, "_teardownContainer: StopAnimation refused (forbidden subtree?)")
                end
            end
        end
    end
    -- Test-mode native countdowns: a DurationTextBinding holds a reference to the
    -- slot's fontstring and keeps writing to it C-side, so it must be switched off
    -- before the slot goes — same reasoning as the border animation driver above.
    -- Bumping the generation also retires any re-arm still pending on a timer.
    for _, slot in pairs(self.buttons) do
        if slot and slot._dfTestBinding then
            pcall(function() slot._dfTestBinding:SetEnabled(false) end)
        end
        if slot then slot._dfTestGen = (slot._dfTestGen or 0) + 1 end
    end
    if not park then
        wipe(self.buttons)
        self._slotCounter = 0   -- restart the lazy-batch index for the next build
    end
    -- Own-frame preview slots are OURS, not the container's, so nothing above
    -- reaches them: the wipe drops self.buttons' references but the frames stay
    -- parented and visible. Park them here. Kept for reuse rather than destroyed —
    -- they are pooled per handle precisely so a rebuild does not re-allocate.
    if self._ownPreviewSlots then
        for _, slot in pairs(self._ownPreviewSlots) do
            if slot then
                if DF.Border and slot.dfBorder then DF.Border:StopAnimation(slot.dfBorder) end
                slot:Hide()
            end
        end
    end
    if self._ownPreviewBox then self._ownPreviewBox:Hide() end
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
    -- Plain frame; safe in combat, hides the container child too. Hover-safe:
    -- hiding while a native button is under the cursor runs its tooltip
    -- intrinsic under our taint (see _applyVisibility).
    -- Parent-driven handles must not be hidden here either: safeHideWindow reads
    -- frame:IsShown(), which is secret for a nested container. The parent slot's own
    -- teardown takes the subtree with it.
    if self.frame and not (self.config and self.config.parentDrivenVisibility) then
        safeHideWindow(self.frame)
    end
    if InCombatLockdown() then
        -- Can't tear down secure container state in lockdown; defer to regen.
        self:_queueOp("destroy")
        return
    end
    self._pendingOp = nil
    self._pendingRestyle = nil
    self._pendingTuning = nil
    self:_teardownContainer()
    self:_releaseParked()
end

-- Discard the parked container for real. A park is only ever reachable through its
-- handle, so any path that retires the handle must call this or the park becomes the
-- very leak parking exists to stop. Both destroy routes use it: Handle:Destroy out of
-- combat, and the regen handler's deferred "destroy" op.
function Handle:_releaseParked()
    local p = self._parked
    if not p then return end
    self._parked = nil
    if p.backend then pcall(function() p.backend:teardown(false) end) end
end

-- ============================================================
-- CONTAINER PARKING
-- ============================================================
-- WoW never frees a frame. Every structural rebuild used to strand its whole container
-- -- and, since the release call below is unverified, potentially every button it ever
-- created (AddAuraGroup allocates in batches of FrameCreationBatchSize) -- permanently,
-- for the session. That is invisible in a set-and-forget profile and unbounded for
-- anyone whose config churns: AutoProfiles flipping on zone/combat transitions, preset
-- toggling in the Designer, profile switching.
--
-- Parking keeps ONE quiesced container per handle, keyed by the consumer's own
-- structural signature. A rebuild whose key matches re-adopts it instead of building
-- fresh, so A -> B -> A costs one container total rather than three.
--
-- ☠ WHY THE CONSUMER'S KEY AND NOT ONE DERIVED HERE. The engine could hash its own
-- config, but "everything :build() reads" is a moving target and a key that misses a
-- field re-adopts a subtly WRONG container -- silent, and exactly the bug class this
-- file has shipped before. The consumers already maintain exact structural sigs
-- (rowStructSig, placedStructSig, ...) whose entire definition is "changing this needs
-- a new container". That is the parking key, by construction. No key supplied = no
-- parking, so an unwired call site keeps today's behaviour exactly.
--
-- ⚠ NEVER parks in test mode: the preview declares a completely different group
-- topology (per-slot groups, fabricated unit), so a live container and a preview
-- container can share a structural key while being structurally unrelated.
function Handle:_parkContainer()
    local be = self.backend
    if not (be and be.container) then return false end
    -- ☠ The key the OUTGOING container was BUILT with (backend.structKey), never
    -- self._structKey -- Rebuild has already overwritten that with the incoming key.
    local key = be.structKey
    if type(key) ~= "string" or key == "" then return false end
    -- Never park a PREVIEW container: its group topology (one group per slot, fabricated
    -- unit) is unrelated to a live container that could share the same structural key.
    -- A live container retired by the enter-preview rebuild is still parked, because
    -- builtInTestMode records how THAT container was built, not where we are now.
    if be.builtInTestMode then return false end

    -- Only one park per handle. An existing park with a different key is discarded for
    -- real -- it was already stranded before this feature existed, so nothing regresses.
    local old = self._parked
    if old and old.backend and old.backend ~= be then
        pcall(function() old.backend:teardown(false) end)
    end

    local buttons = {}
    for i, slot in pairs(self.buttons) do buttons[i] = slot end
    self._parked = {
        key         = key,
        backend     = be,
        buttons     = buttons,
        gen         = self._gen,
        slotCounter = self._slotCounter,
        flowAnchor  = self._flowAnchor,
        flowPadY    = self._flowPadY,
    }
    self:_teardownContainer(true)
    self.backend = nil          -- detached; the park holds the only reference now
    wipe(self.buttons)
    return true
end

-- Re-adopt a parked container whose structural key matches this build. Returns true if
-- the caller should SKIP the normal build entirely.
--
-- Re-arm order mirrors :build()'s proven order exactly -- deafen, anchor, SetUnit,
-- Show, SetEnabled LAST -- because the same reasoning applies: SetEnabled gates aura
-- event registration on IsVisible() and IsEnabled(), so enabling before the container
-- is shown and pointed at a unit leaves the row rendered once and permanently stale.
function Handle:_readoptParked()
    local p = self._parked
    if not p then return false end
    if AuraContainer._testMode then return false end
    if InCombatLockdown() then return false end
    if type(self._structKey) ~= "string" or self._structKey == "" then return false end
    if p.key ~= self._structKey then return false end
    local be = p.backend
    local c  = be and be.container
    if not c then self._parked = nil; return false end

    self._parked = nil
    self.backend      = be
    self._gen         = p.gen           -- ☠ RESTORE, never bump: see _genCounter in :build()
    self._slotCounter = p.slotCounter or 0
    self._flowAnchor  = p.flowAnchor
    self._flowPadY    = p.flowPadY
    wipe(self.buttons)
    for i, slot in pairs(p.buttons) do self.buttons[i] = slot end

    local config = self.config
    -- Re-applied per adoption for the same reason :build() re-applies it per build --
    -- the deafening lives on the container object and a park does not preserve intent.
    setContainerProviderDeaf(c, not AuraContainer._testMode)
    -- Capability probe only; records the client's answer, changes nothing.
    AuraContainer._probeEditModeSource(c)

    if config.mode == "overlay" then
        pcall(function() c:SetAllPoints(self.frame) end)
    elseif config.mode == "missing" then
        pcall(function()
            c:ClearAllPoints()
            c:SetPoint("TOPRIGHT", self.frame, "TOPLEFT", -MISSING_PAD, 0)
        end)
    else
        applyContainerLayout(c, self)
    end

    local unit = config.unit
    if type(unit) == "string" then pcall(function() c:SetUnit(unit) end) end
    -- ☠ The parked container's last identity-gate verdict was computed for whatever
    -- unit it held when it was parked. :build ends with this for the same reason, and
    -- Handle:SetUnit re-runs it with the note "the last gate verdict was for the OLD
    -- unit". Re-adoption writes the unit directly (not via SetUnit), so without this a
    -- re-adopted container carries a stale verdict until the next idGateWatch sweep --
    -- i.e. it can fail open on a unit whose auras should be gated.
    self:_applyIdentityGate()
    pcall(function() c:Show() end)
    pcall(function() c:SetEnabled(config.enabled ~= false) end)

    AuraContainer.stats.readopts = (AuraContainer.stats.readopts or 0) + 1

    -- The key pins only what is STRUCTURAL. Everything else -- max, sort,
    -- candidateFilters, filter strings, and every cosmetic -- may differ from when this
    -- container was parked, so both live-apply passes run now. Tuning before style:
    -- population first, cosmetics second (same order as the regen flush).
    if be.applyGroupTuning then pcall(function() be:applyGroupTuning() end) end
    self:ApplyStyle()
    return true
end

-- Rebuild the container from scratch (structural changes). Combat-guarded.
function Handle:_rebuild()
    if self._destroyed then return end
    if InCombatLockdown() then self:_deferRebuild(); return end
    if not self:_parkContainer() then self:_teardownContainer() end
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
                local tune = h._pendingTuning
                h._pendingTuning = nil
                -- pcall each handle's op so one failure can't strand the rest.
                if op == "destroy" then
                    pcall(function() h:_teardownContainer() end)
                    pcall(function() h:_releaseParked() end)
                elseif not h._destroyed then
                    -- ☠☠ DID A REBUILD ACTUALLY HAPPEN? The tune/restyle flushes below used
                    -- to ask `op ~= "rebuild"`, i.e. whether one was REQUESTED. The two
                    -- differ on exactly one path and that path dropped everything:
                    --
                    -- A parent-driven link skips its own rebuild (see the note below). Its
                    -- flags were still consumed at the top of this loop, so `op == "rebuild"`
                    -- suppressed the tuning and the restyle as well -- and since the rebuild
                    -- was skipped, NOTHING re-declared the unit or the enabled state that the
                    -- rebuild was standing in for either. Four deferred actions, all silently
                    -- discarded, with nothing left to re-queue them.
                    --
                    -- ☠ AND "rebuild" IS NOT A RARE OP FOR A NESTED LINK. _queueOp upgrades
                    -- ANY two different lesser ops to it, so an ordinary combat in which a
                    -- link is both retargeted (roster churn) and re-enabled arrives here as
                    -- "rebuild" -- the container then keeps driving the PREVIOUS unit for the
                    -- rest of the session, which is what an effect stuck on the wrong people,
                    -- frozen, with its duration no longer counting, looks like from the
                    -- outside. A reload is the only thing that rebuilds it.
                    local rebuilt = false
                    if op then
                        pcall(function()
                            if op == "rebuild" then
                                -- ☠ A NEVER-BUILT NESTED LINK MUST STILL BUILD HERE. skipNested
                                -- exists because a parent link's rebuild re-fires onHost, which
                                -- recreates the child — driving the child here AS WELL races
                                -- that and strands a duplicate (d80f319). But a link whose
                                -- Create happened IN COMBAT has _deferRebuild queueing its ONLY
                                -- build path: the parent is not rebuilding, onHost will not
                                -- re-fire (host.dfChainLink is already stamped), and chainSig
                                -- matches so no sync heals it. With no backend there is nothing
                                -- a duplicate could be stranded FROM, so the escape cannot
                                -- reintroduce the race — do not re-tighten it.
                                if not skipNested(h) or not h.backend then
                                    h:_rebuild()
                                    rebuilt = true
                                elseif h.backend then
                                    -- Skipped: the parent owns the recreate. Apply IN PLACE the
                                    -- two things a rebuild would have re-declared from config,
                                    -- because the upgrade folded them in and there is no longer
                                    -- any record of which of them was queued. Both are
                                    -- idempotent, so applying both is safe and cheaper than
                                    -- tracking the pair through the upgrade.
                                    h.backend:setUnit(h.config.unit)
                                    h.backend:setEnabled(h.config.enabled ~= false)
                                end
                            elseif op == "retarget" then
                                if h.backend then h.backend:setUnit(h.config.unit) end
                            elseif op == "enable" then
                                if h.backend then h.backend:setEnabled(h.config.enabled ~= false) end
                            end
                        end)
                    end
                    -- Combat-deferred in-place tuning (ApplyTuning hit in lockdown):
                    -- flush via the in-place mutate, NOT a recreate — the deferred
                    -- change costs no flicker/leak either. A rebuild redeclares the
                    -- groups from the already-swapped config, so only a rebuild that
                    -- REALLY RAN makes this redundant. Tuning runs BEFORE restyle
                    -- (population first, cosmetics second).
                    if tune and not rebuilt and h.backend and h.backend.applyGroupTuning then
                        pcall(function() h.backend:applyGroupTuning() end)
                    end
                    -- Combat-deferred cosmetic restyle (ApplyStyle hit in lockdown). A
                    -- rebuild that ran already styles fresh buttons from the updated
                    -- config; one that was skipped styled nothing.
                    if restyle and not rebuilt then
                        pcall(function() h:ApplyStyle() end)
                    end
                    -- ☠ THE GATE RECOVERY THAT COULD NOT RUN IN COMBAT. Out of lockdown the
                    -- bounce is available again, so this is the first moment the pool can
                    -- actually be re-parsed. LAST, after any rebuild/tuning/restyle above:
                    -- a rebuild parses fresh and clears the debt by itself, and re-parsing
                    -- before a restyle would only be undone by it.
                    -- The flag is cleared only on success, so a bounce that still fails
                    -- leaves the verdict un-consumed and the next gate pass retries.
                    -- ☠ THE DRAIN PAYS THE RE-PARSE DEBT BUT NEVER STAMPS THE VERDICT.
                    -- It used to set _idGateAssist = true here, and that reintroduced the
                    -- spent-edge bug on one corner (2026-08-21 review): if trust dropped
                    -- AGAIN during the same combat, this bounce re-parsed an untrusted
                    -- unit -- a fail-open parse, invisible only because the hide
                    -- actuation covers it -- and the stamped true meant the REAL
                    -- recovery, when trust returned, saw no false->true edge and never
                    -- re-parsed. The anchor then un-hid an unfiltered pool.
                    -- Leaving the verdict false costs one redundant bounce: the next
                    -- gate pass (the 5s backstop at worst) sees the same edge out of
                    -- combat, bounces instantly, and stamps through the normal flow --
                    -- which re-asks the probes first, so a still-untrusted unit stays
                    -- parked instead of being declared recovered by a timer.
                    if h._pendingGateReparse then
                        if rebuilt then
                            h._pendingGateReparse = nil
                        else
                            local done = false
                            pcall(function() done = h:Refresh() end)
                            if done then
                                h._pendingGateReparse = nil
                                pcall(function() h:_setCineLatch(nil, true) end)
                            end
                        end
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
    -- ☠ The UPGRADE is the interesting event, not the queueing. Two different
    -- pending ops (classically enable + retarget) collapse to a full rebuild, and
    -- that path is the documented frame-leak case — it was previously silent, so a
    -- leak left no trace at all. Only an actual change of pending op logs.
    if cur and cur ~= self._pendingOp then
        DF:DebugWarn("AURACONTAINER", "combat op upgrade: %s + %s -> %s (unit=%s)",
            tostring(cur), tostring(op), tostring(self._pendingOp),
            tostring(self.config and self.config.unit))
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

-- Z-ORDER — frame level + frame strata, from self.config. Level: legacy renders host aura
-- icons ABOVE contentOverlay (parent+25, name/health text). Raising self.frame raises the
-- whole subtree — the native container + AuraButtons + their holders are all descendants with
-- relative levels (Blizzard sets no fixed levels). Default +40 = legacy buff-icon level; the
-- defensive row passes +51 (= contentOverlay+26). Strata picks the BAND; the level offset only
-- orders WITHIN a band.
--
-- ★ Called from Create AND from every _build. It MUST run on rebuild: Rebuild() swaps
-- self.config and calls _build WITHOUT recreating self.frame, so a config whose z-order keys
-- changed would otherwise keep whatever Create stamped — which is why a struct-sig change to
-- Frame Level did not take effect until a reload. Recomputing is a couple of setter calls, so
-- an unconditional call per build costs nothing.
--
-- Strata is deliberately OPT-IN. Calling SetFrameStrata PINS a frame: it stops tracking the
-- parent's band. Containers that never set frameStrata are therefore left untouched and keep
-- inheriting, exactly as before. Only once an explicit strata has been applied do we re-assert
-- the parent's band on the way back to Inherit (there is no "unset" to write) — tracked by
-- _strataPinned so the restore happens once and never on a container that never opted in.
-- Public form: pass the INCOMING config to apply a z-order that self.config does not carry yet.
-- The buff/debuff/defensive row drivers need this. They keep frameLevelOffset out of their sigs
-- on purpose (a level change is not structural and must not force a Rebuild), so a level-only
-- change never reaches _build — the driver applies it directly against the new cfg instead.
function Handle:ApplyZOrder(cfg)
    local f = self.frame
    cfg = cfg or self.config
    if not f or not cfg then return end
    local parent = f:GetParent()
    if not parent then return end
    f:SetFrameLevel(math.max(0, parent:GetFrameLevel() + (cfg.frameLevelOffset or 40)))
    if cfg.frameStrata then
        f:SetFrameStrata(cfg.frameStrata)
        self._strataPinned = true
    elseif self._strataPinned then
        f:SetFrameStrata(parent:GetFrameStrata())
        self._strataPinned = nil
    end
end

function Handle:_applyZOrder()
    self:ApplyZOrder(self.config)
end

function Handle:_build()
    self:_applyZOrder()        -- level/strata track config changes across Rebuild
    self:_ppPrepare()          -- pp flag + quantized layout BEFORE any geometry runs
    -- A structurally identical container may already be parked from an earlier rebuild
    -- (profile swap, preset toggle, AutoProfiles transition). Re-adopting it skips the
    -- CreateFrame, every AddAuraGroup and the whole lazy button batch.
    if not self:_readoptParked() then
        self.backend = NativeBackend.new(self)
        self.backend:build()
    end
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
-- ============================================================
-- Blizzard Edit Mode flips every aura container onto its sample-data source. We
-- cannot stop OUR containers hearing that switch -- the container carries the
-- EventRegistrations forbidden aspect from birth, so UnregisterEvent is refused
-- (see EDIT-MODE DEAFENING near the top of this file). But we do not need to.
--
-- ★ PRIMARY: hand the real provider straight back. C_UnitAuras.ResetAuraDataProvider
-- is public and unrestricted (no HasRestrictions in the generated docs; test mode
-- already drives it), and it re-fires the switch with useRealDataProvider = true, so
-- every container -- ours and Blizzard's -- returns to the real source. No rebuild,
-- no teardown, no button pools recreated. The restore is just the real-switch branch.
--
-- THE TRADE: this is GLOBAL. Blizzard's own Edit Mode preview loses its sample
-- auras, so their buff frame and cooldown manager show your REAL auras while you
-- position them. That is the same class of trade DF test mode already makes in the
-- other direction, and the alternative is our own rows flashing.
--
-- ORDER, and why each step is where it is:
--   1. PARK synchronously, inside this dispatch. AURA_DATA_PROVIDER_SWITCH is a
--      SYNCHRONOUS event, so nothing is drawn between the containers' handler and
--      ours whichever order they run in -- parking here means the sample icons are
--      never painted at all.
--   2. RESET one frame later, never inline. An inline reset would nest a dispatch
--      inside this one, and any container the OUTER fake dispatch had not yet
--      visited would receive fake AFTER our reset and be stranded on the sample
--      source. A frame later the outer dispatch has finished and they all flip
--      together.
--   3. Only if the reset is unavailable or fails, fall back to REBIRTH: a container
--      built after a switch never receives it and useEditModeSource initialises
--      false, so a fresh container is on the real source by construction (probe 33's
--      born-deaf finding, which test mode's ordering already depends on).
--
-- DF's own test mode (P5) sets _ownsProviderSwitch around its switches so its
-- curated preview is exempt from all of this.
local function ensureProviderWatch()
    if AuraContainer._providerWatch then return end
    local f = CreateFrame("Frame")
    AuraContainer._providerWatch = f
    f._hidden = setmetatable({}, { __mode = "k" })
    f._fakeActive = false

    -- Hide every currently-shown row and remember which ones we hid.
    local function parkAll(watch)
        watch._fakeActive = true
        for h in pairs(AuraContainer._handles or {}) do
            if not h._destroyed and not (h.config and h.config.parentDrivenVisibility)
            and h:GetFrame():IsShown() then
                watch._hidden[h] = true
                safeHideWindow(h:GetFrame(), function() return watch._hidden[h] end)
            end
        end
    end

    -- Clear the park BEFORE any restore: _applyVisibility forces a handle hidden
    -- while _fakeActive and _hidden[h] both hold, so restoring first strands them.
    local function unpark(watch)
        watch._fakeActive = false
        for h in pairs(watch._hidden) do watch._hidden[h] = nil end
    end

    -- ★ STRANDING SWEEP — the belt to the inline reset's braces.
    --
    -- The inline reset leaves one hole, and it is the only way Edit Mode's sample icons
    -- can still reach a LIVE frame: if the outer fake dispatch had not yet visited some
    -- container when our reset ran, that container takes fake AFTER the reset and sits
    -- on the sample source until Edit Mode closes. Measured as not happening on 68914,
    -- but that rests on an undocumented dispatch order, and this ships to configurations
    -- we will never test.
    --
    -- The sweep removes the need to reason about order at all: bounce the provider
    -- fake→real BACK TO BACK in one frame. Every container hears both, in that order,
    -- whatever order it is visited in, and ends on the real source. Nothing paints
    -- between two consecutive Lua statements.
    --
    -- It is near-free: UpdateAllAuras is MarkDirty(FullAuraRebuild), a bit-set, and
    -- ProcessDirtyFlags runs once on the next OnUpdate — so two marks in one frame
    -- produce ONE reparse, the same one the reset already scheduled.
    --
    -- ☠ THE DANGEROUS HALF: if Switch succeeds and Reset does not, the whole GAME is
    -- left on the fake provider — every aura display, ours and Blizzard's, showing
    -- sample icons. So Reset is retried hard, and as a last resort re-armed on a timer.
    -- Reset is known to work by the time we get here (the inline reset used it moments
    -- ago), which is why the bounce is safe to attempt at all.
    local function sweepStranded()
        -- Only NESTED dispatch can strand: QUEUED means our reset landed after the
        -- outer dispatch finished, so every container had already taken fake first.
        if AuraContainer._inlineDispatch ~= "NESTED" then return end
        if AuraContainer._ownsProviderSwitch then return end
        local switch = C_UnitAuras and C_UnitAuras.SwitchAuraDataProvider
        local reset  = C_UnitAuras and C_UnitAuras.ResetAuraDataProvider
        if not (switch and reset) then return end

        -- Our own handler must ignore both halves; reuse the flag it already honours.
        AuraContainer._ownsProviderSwitch = true
        local okS = pcall(switch)
        local okR = pcall(reset)
        if okS and not okR then
            for _ = 1, 3 do
                if pcall(reset) then okR = true; break end
            end
        end
        AuraContainer._ownsProviderSwitch = false

        if okS and not okR then
            -- Worst case: the world is on fake data and we could not undo it. Keep
            -- trying rather than leaving it; a stuck retry is recoverable, a stuck
            -- fake provider is not.
            DF:DebugWarn(DBG, "stranding sweep left the fake provider installed — retrying")
            local function retry(n)
                if pcall(reset) or n <= 0 then return end
                C_Timer.After(0.25, function() retry(n - 1) end)
            end
            retry(20)
        elseif not okS then
            -- Switch refused, so nothing was changed and nothing needs undoing.
            DF:DebugWarn(DBG, "stranding sweep skipped: SwitchAuraDataProvider refused")
        end
    end

    -- LAST RESORT (see step 3 above). Two passes: a raid's worth of teardown +
    -- CreateFrame + AddAuraGroup in one frame is itself a visible stall, so rebuild
    -- what is ON SCREEN now and drain the rest 25 per tick. Offscreen handles stay
    -- flipped for those few frames, which costs nothing because nothing draws them.
    local function rebirthAll(watch)
        unpark(watch)
        local function rebirth(h)
            if h._destroyed then return end
            pcall(function() h:_rebuild() end)          -- reborn on the real source
            pcall(function() h:_applyVisibility() end)  -- and back on screen
        end
        local later, n = {}, 0
        for h in pairs(AuraContainer._handles or {}) do
            if not h._destroyed then
                if not (h.config and h.config.parentDrivenVisibility)
                    and h:GetFrame():IsShown() then
                    rebirth(h)
                else
                    n = n + 1
                    later[n] = h
                end
            end
        end
        if n == 0 then return end
        local i = 1
        local function drain()
            if AuraContainer._ownsProviderSwitch then return end
            local stop = math.min(i + 24, n)
            while i <= stop do rebirth(later[i]); i = i + 1 end
            if i <= n then C_Timer.After(0, drain) end
        end
        C_Timer.After(0, drain)
    end

    f:RegisterEvent(PROVIDER_EVENT)
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
                    -- Restore through the visibility channel: hover-safe, and composes
                    -- intent + identity gate (a bare Show() re-opened gate-hidden
                    -- windows on Edit Mode exit).
                    --
                    -- ⚠ NO Refresh() here. It used to bounce every container
                    -- (NativeBackend:refresh = Hide+Show), and that bounce was most of
                    -- the remaining visible delay: N containers each re-registering and
                    -- re-laying-out. It is redundant twice over —
                    --   * the real switch already ran SetUseEditModeSource(false) on
                    --     every container, and that calls UpdateAllAuras itself; and
                    --   * showing the parent fires the container's OnShow_Intrinsic,
                    --     which does UpdateEventRegistrations + UpdateAllAuras anyway.
                    -- The second also closes the only gap worth worrying about: while
                    -- parked the frame is hidden, so the container drops its UNIT_AURA
                    -- registration (ShouldRegisterForDynamicEvents = IsVisible and
                    -- IsEnabled) and would otherwise miss changes made during the park.
                    h:_applyVisibility()
                end
            end
            return
        end

        if AuraContainer._providerDeafOK then
            -- A future build that permits the unregister: our containers never heard
            -- this switch and are still on the real source. Nothing to do.
            self._fakeActive = false
            return
        end

        parkAll(self)

        -- ⚗ EXPERIMENT (INLINE_PROVIDER_RESET): reset from INSIDE this dispatch rather
        -- than a frame later. Parking and restoring then both happen before anything is
        -- drawn, so the remaining sub-50ms blip disappears entirely.
        --
        -- ✅ VERIFIED IN GAME on 68914: NESTED, and NOTHING stranded. Confirmed from the
        -- saved debug log, which also shows neither fallback firing — no reset failure,
        -- no rebirth. One dispatch, no visible artifact.
        --
        -- ⚠ But note WHY that is luck rather than design. The stranding hazard depends on
        -- where our watch frame sits in the dispatch order, and the obvious prediction was
        -- wrong: the watch registers before any container exists (ensureProviderWatch runs
        -- ahead of the first _build), so registration order would have put it FIRST and
        -- stranded everything. It stranded nothing, so dispatch order is NOT registration
        -- order — and the real rule is undocumented. Treat this as empirical, not sound.
        -- If it ever regresses the symptom is rows of random spellbook icons during Edit
        -- Mode, cleared on exit (Edit Mode's own reset flips every container back), so it
        -- is self-limiting: no error, no data loss, one toggle to clear.
        --
        -- Whether that is safe depends on undocumented dispatch semantics, and the
        -- outcome is self-reporting — the debug line below says which the client does:
        --   * QUEUED  — pcall returns with _fakeActive still set, the real switch lands
        --               later. Identical to the deferred path; safe, no gain.
        --   * NESTED  — the real switch is dispatched re-entrantly, our restore has
        --               already run, _fakeActive is clear. Zero blip — BUT any container
        --               the OUTER fake dispatch had not yet visited receives fake AFTER
        --               our reset and is stranded on the sample source until Edit Mode
        --               is toggled again. Visible as rows of random spellbook icons.
        -- If you see stranded rows, flip this to false; the deferred path below is
        -- unchanged and known good.
        local INLINE_PROVIDER_RESET = true
        local resetNow = C_UnitAuras and C_UnitAuras.ResetAuraDataProvider
        if INLINE_PROVIDER_RESET and resetNow and pcall(resetNow) then
            -- Recorded, not just logged: which of the two it is decides whether the
            -- inline reset is worth keeping, and it is not inferable from "it looked
            -- fine" — one imperceptible frame and zero frames look identical.
            AuraContainer._inlineDispatch = self._fakeActive and "QUEUED" or "NESTED"
            DF:Debug(DBG, "inline provider reset: dispatch was %s",
                     self._fakeActive and "QUEUED (no gain, safe)" or "NESTED (zero blip; watch for stranded rows)")
            -- Deliberately NOT returning here. If the dispatch was NESTED the restore has
            -- already run and the backstop below sees _fakeActive clear and no-ops. If it
            -- was QUEUED the real switch is still in flight — and if it somehow never
            -- arrives, the backstop is the only thing standing between us and rows parked
            -- forever. It costs one no-op timer.
        end

        C_Timer.After(0, function()
            if AuraContainer._ownsProviderSwitch then return end
            if not self._fakeActive then
                -- Resolved inline. Sweep anyway: that path is the one that can leave a
                -- container stranded on the sample source, and this is where we stop
                -- depending on dispatch order to have been kind to us.
                sweepStranded()
                return
            end
            local reset = C_UnitAuras and C_UnitAuras.ResetAuraDataProvider
            if reset and pcall(reset) then return end      -- the real-switch branch restores
            DF:DebugWarn(DBG, "ResetAuraDataProvider unavailable/failed; rebuilding instead")
            -- Containers cannot be stood up in lockdown; stay parked until the real
            -- switch arrives (Edit Mode cannot be opened in combat anyway -- this only
            -- covers another addon switching the provider mid-fight).
            if InCombatLockdown() then return end
            rebirthAll(self)
        end)
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
--                duration, stacks, bar, spellName, dispel, overlay,
--                tooltip{point,x,y,hideInCombat} },   -- native tooltip placement (68914+): point =
--                                                     -- a SetTooltipAnchorPoint name; live mixin
--                                                     -- state, restyles in place (no Rebuild).
-- }
-- ============================================================
-- SLOT OWNER — one shared container per unit frame  (collapse S1)
-- ============================================================
-- ☠ ADDITIVE AND UNUSED. Nothing calls this yet; S2 moves the Aura Designer's placed
-- indicators onto it. Landing it alone keeps the diff reviewable and testable.
--
-- WHY. Every AD indicator sets singleSlot, so today each one gets a WHOLE AuraContainer
-- holding exactly ONE AddAuraSlot = one button. Measured across the 18 Create call sites
-- that is ~130 containers per unit frame worst case, ~5,200 in a 40-man, uncapped -- an
-- order of magnitude above what a fixed, enumerated set of slots would cost. WoW never
-- frees a frame and teardown cannot release buttons (RemoveAllAuraFrames does not exist
-- -- zero hits at 69111), so every structural edit strands the lot for the session.
--
-- One container per unit frame, one slot per indicator, instead.
--
-- ☠ WHY A NEW SLOT PER STRUCTURE, NOT A MUTATED ONE. A slot's regions are built in its
-- initializeFrame, which is frozen at AddAuraSlot and only ever runs at button creation.
-- So a structural change cannot mutate a slot -- it declares a NEW one (keyed by the
-- consumer's struct sig) and PARKS the old. That costs ONE button where today it costs a
-- container plus a button, and revisiting an earlier structure re-adopts the parked slot
-- by key. Declare-a-new-variant-and-park-the-old is the standard shape for this under an
-- add-only topology; there is no other correct one.
--
-- ☠ PARKING IS THE WHOLE MECHANISM, and it is why this could not be built before now.
-- AddAuraSlot is add-only -- Blizzard's ClearAuraGroups is "intentionally not exposed via
-- the inbound interface" because pooled frames would become irrecoverable -- and slots
-- have no maxFrameCount, so an unwanted slot must be made to match nothing.
--
-- ☠☠ THE EMPTY STRING IS RETIRED -- see SLOT_PARK_FILTER. That
-- SetAuraSlotFilterString(key, "") empties a slot was never determinable from the Lua
-- source (AuraUtil.IsValidFilterString("") returns true because every component is
-- skipped, but what the engine does with an empty predicate is invisible), and was proved
-- in game with /alpark on 2026-08-05 -- on THAT build. It stopped holding: an AD indicator
-- kept rendering with the gate hidden, the empty string pushed and the engine accepting it
-- (Krathe, 2026-08-18). The park is now a self-contradicting filter, which cannot match
-- under any reading of the predicate. A bare re-Set still restores live.
--
-- ★ Z-ORDER: the dfLevelHost. Sharing a container means sharing its frame level, but AD
-- indicators need independent layering. Writing the level on the slot BUTTON is legal
-- only inside initializeFrame (pre-seal), which would freeze it permanently. So each slot
-- gets a DF-owned child frame between the button and our regions:
--     slot button (sealed, never re-levelled)  ->  dfLevelHost (ours, levelled LIVE)
-- Regions must stay DESCENDANTS of the button (ValidateInboundScriptObject errors
-- otherwise) and an interposed child frame satisfies that while staying levellable.
--
-- ⚠ Not handled in S1, by design: the identity gate (per-owner now, not per-handle),
-- test-mode frames (refused outright -- the preview declares its own topology), and
-- consumer styling, which stays with the caller via GetButton/GetLevelHost.

local SlotHandle = {}
SlotHandle.__index = SlotHandle

-- Every slot's regions hang off this, so the consumer can re-level live without ever
-- touching the sealed button. Created inside initializeFrame -- the only window in which
-- a tainted write to an aura button is legal.
-- ☠ POSITION IS THE CONSUMER'S, NOT THE FLOW'S. Slots take no part in dynamic layout
-- ("they do not take part in dynamic layout and must be manually anchored"), and with a
-- SHARED container there is no longer a per-indicator container whose own anchoring did
-- this job. Without it every slot lands on the shared container's corner, stacked on top
-- of one another -- which reads as "an indicator stopped rendering" when it is really
-- underneath its neighbour.
--
-- Applied at creation AND on every restyle: anchor/offset/scale are cosmetic (a drag
-- updates them live today), so freezing them at creation would be a regression.
-- ⚠ pcall'd: this is a tainted write to a button that carries
-- DenyTaintedAccessWhenAurasAreSecret, so a live re-anchor can be refused while auras are
-- secret. It re-applies on the next unrestricted restyle, which is the same contract
-- Handle:ApplyStyle already lives under.
local function layoutSlotButton(button, config, ownerAnchor)
    local L = config and config.layout
    if not (button and L and ownerAnchor) then return end
    local point = (type(L.anchor) == "string" and L.anchor) or "TOPLEFT"
    pcall(button.ClearAllPoints, button)
    pcall(button.SetPoint, button, point, ownerAnchor, point, L.offsetX or 0, L.offsetY or 0)
    if L.scale then pcall(button.SetScale, button, L.scale) end
end

-- ★ LEVEL host AND ALPHA host. styleButton_regions parents every region it creates onto
-- this frame (see the `host` local at its top), which is what lets a slot take a tainted
-- SetAlpha: the button refuses one, a DF-owned child frame does not.
--
-- ☠ THE EXPLICIT SetFrameLevel IS NOT COSMETIC — WITHOUT IT EVERY SLOT SHIFTS A LEVEL.
-- A new child frame defaults to its parent's level + 1. Interposing this host would
-- therefore push all of a slot's content up one level relative to everything else on the
-- frame, and AD levels are ABSOLUTE (a row is 9 levels thick — derive it from
-- DF.AuraButtonLevels, never from a number copied into prose like this one was)
-- — a uniform +1 walks a slot's content into the next band. Pinning the host to the
-- BUTTON's own level keeps every offset below it arithmetically identical to when the
-- regions hung off the button directly: makeHolder(host, n) resolves to the same level
-- makeHolder(button, n) did, and dfCD lands at button+1 exactly as before. Nothing is
-- left on the button to compete for draw order, so relative ordering is preserved whole.
-- ⚠ CALL AFTER ANY SetFrameLevel ON THE BUTTON. The host tracks the button's level, so
-- pinning it while the button is still at its default and only then applying
-- config.frameLevelOffset would strand the host — and every region on it — a band below
-- where the consumer asked the slot to sit. Idempotent, so calling it twice is free.
local function syncSlotHostLevel(button, host)
    if not host then return end
    local okLvl, lvl = pcall(button.GetFrameLevel, button)
    if okLvl and type(lvl) == "number" then pcall(host.SetFrameLevel, host, lvl) end
end

local function makeSlotLevelHost(button)
    local ok, host = pcall(CreateFrame, "Frame", nil, button)
    if not ok or not host then return nil end
    pcall(host.SetAllPoints, host, button)
    syncSlotHostLevel(button, host)
    return host
end

-- Slots per frame at which the add-only growth stops looking like normal use. A busy
-- Aura Designer profile lands well under this; a slider drag blows straight through it.
local SLOT_OWNER_WARN_AT = 48

local function ownerOf(frame)
    return frame and frame.dfSlotOwner or nil
end

-- ★ THE LEGAL FADE TARGET FOR EVERY SLOT-BACKED INDICATOR ON THIS FRAME.
-- SlotHandle:GetAlphaHost answers with button.dfLevelHost, which is INSIDE the aura button
-- and therefore forbidden to tainted code on 12.1 — proven in the field, where even a bare
-- GetDebugName() on it is refused, not just the alpha setters. So per-indicator alpha on a
-- shared slot cannot be written at all.
--
-- ensureOwner already interposes a plain DF-created Frame between the unit frame and the
-- container (`anchor`), purely so the container has something to SetAllPoints to. That frame
-- is ours, lives above the whole aura hierarchy, and alpha multiplies down through the
-- container to every button and region inside it — so fading it fades every slot-backed
-- indicator on the frame with ONE legal write.
--
-- ⚠ Deliberately frame-wide, not per-indicator. Out-of-range is a property of the UNIT, so
-- every indicator on it fades together anyway; there is nothing to lose by sharing the write.
-- What this canNOT do is per-indicator BASE alpha (the AD Alpha slider) — that needs the
-- per-button host, which is unwritable. That capability is already gone for slot-backed
-- indicators regardless of this; fading here neither restores nor worsens it.
local function ownerAlphaHost(frame)
    local owner = frame and frame.dfSlotOwner
    return owner and owner.anchor or nil
end

function AuraContainer:GetSlotOwnerAlphaHost(frame)
    return ownerAlphaHost(frame)
end

-- Lazily stand up the per-frame owner. Build order mirrors NativeBackend:build exactly --
-- create -> anchor -> SetUnit -> (slots) -> SetEnabled -- because the same rules bite:
-- SetEnabled gates event registration on IsVisible() and IsEnabled(), and anchoring must
-- precede the first Add* since that stamps UntrustedLayoutScriptExecution on the
-- container, which propagates to anything anchored to it and cannot be conferred later.
local function ensureOwner(frame, unit)
    local owner = ownerOf(frame)
    if owner then return owner end
    if not AuraContainer.IsSupported() then return nil end
    -- Container creation is combat-gated everywhere else in this file; do not diverge.
    if InCombatLockdown() then return nil end

    local anchor = CreateFrame("Frame", nil, frame)
    anchor:SetAllPoints(frame)

    local ok, c = pcall(CreateFrame, "AuraContainer", nil, anchor, "CustomAuraContainerTemplate")
    if not ok or not c then
        DF:DebugWarn(DBG, "SlotOwner: CreateFrame(AuraContainer) failed: %s", tostring(c))
        return nil
    end
    setContainerProviderDeaf(c, not AuraContainer._testMode)
    -- Capability probe only; records the client's answer, changes nothing.
    AuraContainer._probeEditModeSource(c)
    pcall(c.SetAllPoints, c, anchor)
    if type(unit) == "string" then pcall(c.SetUnit, c, unit) end

    owner = { frame = frame, anchor = anchor, container = c, unit = unit, slots = {}, seq = 0 }
    frame.dfSlotOwner = owner
    AuraContainer.stats.slotOwners = (AuraContainer.stats.slotOwners or 0) + 1
    return owner
end

-- Acquire (or re-adopt) the slot for `slotKey` on `frame`'s shared owner.
--
-- slotKey MUST encode the consumer's structural signature -- "indicatorKey:structSig" --
-- because a slot's regions are frozen at creation. Same key = same structure = safe to
-- re-adopt; different structure = different key = a new slot and the old one parked.
--
-- spec: { unit, filter, candidateFilters, sortMethod, sortDirection, onInit, config }
--   config -- a normal container config ({ mode, layout, style, tooltips,
--     frameLevelOffset, frameStrata, ... }). When given, the slot reuses the ENGINE's own
--     region pipeline: styleButton_regions + bindNative at create, styleButton_regions
--     again on ApplyStyle. ☠ This is the seam that makes the collapse possible at all --
--     consumers like the Aura Designer hand the engine a config and own no rendering
--     code of their own, so a slot path that could not run that pipeline would have to
--     reimplement every region, and would drift.
--   onInit(button, levelHost) runs inside initializeFrame after the pipeline, for
--     anything the consumer wants to add itself.
--
-- ☠ FRAME LEVEL IS SET ON THE BUTTON, INSIDE initializeFrame, and that is correct rather
-- than a compromise. Buttons on a shared container all sit at container level + 1, so
-- per-slot layering has to come from somewhere; writing it on the button is legal only
-- pre-seal, which freezes it. That costs nothing here because level is ALREADY structural
-- for every consumer of this path (placedStructSig carries `fl=`/`fs=`), so a level change
-- already produces a new struct sig -> a new slot key -> a new button -> the new level.
-- Behaviour is identical to today. (dfLevelHost stays available for a future consumer
-- that wants level to become live, which would need regions reparented onto it.)
--
-- Returns a SlotHandle, or nil if unsupported / test frame / in combat with no owner yet
-- / in combat needing a NEW slot (re-adoption of an existing key still works in combat;
-- its mutators defer and replay at regen).
function AuraContainer:AcquireSlot(frame, slotKey, spec)
    if type(slotKey) ~= "string" or slotKey == "" or type(spec) ~= "table" then return nil end
    if not frame then return nil end
    -- The preview declares a wholly different topology (per-slot groups, fabricated
    -- unit); a shared owner has no business serving it. Test frames keep the old path.
    if frame.dfIsTestFrame or AuraContainer._testMode then return nil end

    local owner = ensureOwner(frame, spec.unit)
    if not owner then return nil end

    local existing = owner.slots[slotKey]
    if existing then
        -- ☠ RE-ADOPTION MUST TAKE THE FRESH SPEC, not just un-park. The key pins only
        -- what is STRUCTURAL; everything else — filter, candidateFilters, and every
        -- cosmetic in the config — may have changed while this slot sat parked
        -- (disable an indicator, recolour it in the editor, re-enable: same key, new
        -- config). Restore() alone would render the pre-park state, and the Factory
        -- stamps its tuning/cosmetic sigs with the NEW values on this very pass, so
        -- the catch-up branches would never fire — stale until the next structural
        -- edit. Same contract as Handle:_readoptParked, same order: tuning before
        -- style (population first, cosmetics second). The redundant filter re-set
        -- after Restore is free — the engine's string setter has an equality guard.
        existing:Restore()
        if spec.config then existing.config = spec.config end
        existing:ApplyTuning(spec.filter, spec.candidateFilters,
            spec.sortMethod, spec.sortDirection)
        if spec.config then
            existing:ApplyStyle(spec.config.style, spec.config.layout)
        end
        return existing
    end

    -- ☠ NO NEW SLOT IN COMBAT. AddAuraSlot on the secure container is exactly the class
    -- of call ensureOwner refuses above ("container creation is combat-gated everywhere
    -- else in this file"), and this path used to make it anyway whenever the owner
    -- already existed. Re-adoption above is fine -- every mutator it uses now defers and
    -- replays -- but a NEW slot has no deferral story (AddAuraSlot is add-only, one-shot,
    -- and its initializeFrame window is pre-seal). Returning nil sends the caller down
    -- its documented fallback: placedAcquire creates a per-indicator CONTAINER, which
    -- defers its build to regen properly.
    if InCombatLockdown() then return nil end

    -- ☠ THE PARK TABLE IS UNBOUNDED AND CANNOT BE FREED. AddAuraSlot is add-only -- the
    -- engine exposes no remove -- so every distinct slotKey ever seen on this frame is a
    -- permanent button. That is tolerable while keys are stable, and it is NOT stable
    -- today: placedStructSig carries `fl=`, the Frame Level slider, so dragging that
    -- slider across its range mints one button per intermediate value, per frame, times
    -- the raid. The collapse relocated the old per-indicator container leak; it did not
    -- cap it, which is the claim this warning exists to keep honest.
    --
    -- ⚠ MITIGATION, NOT A CURE. We cannot evict, so all this does is make the growth
    -- visible once instead of silent forever. The real fix is to stop level being
    -- STRUCTURAL: dfLevelHost is DF-owned and already interposed under every region, so
    -- levelling the host instead of the sealed button would make `fl=` cosmetic and the
    -- key stable. That is a behavioural change to the seal path and wants an in-game
    -- pass, so it is deliberately not being done blind here.
    local slotCount = 0
    for _ in pairs(owner.slots) do slotCount = slotCount + 1 end
    if slotCount >= SLOT_OWNER_WARN_AT and not owner._warnedSlotGrowth then
        owner._warnedSlotGrowth = true
        DF:DebugWarn(DBG,
            "SlotOwner: %d slots on one frame (unit=%s). Slots are add-only and never "
            .. "freed -- if this climbs with a slider drag, the Frame Level struct key "
            .. "is minting them.", slotCount, tostring(owner.unit))
    end

    local filter = spec.filter or "HELPFUL"
    local config = spec.config
    local handle = setmetatable({
        owner = owner, key = slotKey, liveFilter = filter, parked = false, config = config,
    }, SlotHandle)

    -- Stashed BEFORE the declare so the declare can read through _cf(): a helper-owned
    -- slot born while the gate is dark must be born gated, not corrected one push later.
    handle._lastCandidateFilters = spec.candidateFilters

    local okS, btn = pcall(owner.container.AddAuraSlot, owner.container, slotKey, filter, {
        candidateFilters = handle:_cf(),
        sortMethod       = spec.sortMethod,
        sortDirection    = spec.sortDirection,
        initializeFrame  = function(b)
            -- Pre-seal window. Region creation, the level host, and any button-level
            -- write must all happen here; after this returns the engine applies
            -- DenyTaintedAccessWhenAurasAreSecret and later writes are refused exactly
            -- when auras are secret.
            local host = makeSlotLevelHost(b)
            b.dfLevelHost = host
            -- ☠ THE MOUSE GATE, same as _makeInitializeFrame's (the group path). This
            -- initializer never applied it, and Blizzard aura buttons default to mouse
            -- ENABLED — so every placed indicator on the shared-slot path showed
            -- tooltips (and swallowed clicks) REGARDLESS of the tooltip settings,
            -- while the same indicator built through the per-container fallback
            -- honoured them. Field report #1044: profile with every tooltip key false
            -- in both modes, tooltips only on AD-placed icons. Pre-seal window, so
            -- the writes are legal; the AD tooltip toggle reaches existing slots via
            -- the struct sig (a flip declares a new slot with the new gate value).
            if b.SetMouseClickEnabled then pcall(b.SetMouseClickEnabled, b, false) end
            if b.SetMouseMotionEnabled then
                pcall(b.SetMouseMotionEnabled, b,
                    (config and config.tooltips) == true and not AuraContainer._testMode)
            end
            if config then
                -- Per-slot layering, pre-seal (see the header above AcquireSlot).
                if config.frameStrata then pcall(b.SetFrameStrata, b, config.frameStrata) end
                if config.frameLevelOffset then
                    local base = owner.container and owner.container:GetFrameLevel() or 0
                    pcall(b.SetFrameLevel, b, base + config.frameLevelOffset)
                    -- The host tracks the button's level and the line above just moved it.
                    syncSlotHostLevel(b, host)
                end
                -- ★ The engine's OWN pipeline, unchanged: regions created and styled,
                -- then the native setters bound. Identical to what Handle:_acceptSlot /
                -- _bindNativeSlot do for a per-indicator container, so a migrated
                -- consumer renders byte-identically without owning any render code.
                local okR, errR = pcall(styleButton_regions, b, config)
                if not okR then DF:DebugWarn(DBG, "SlotOwner styleButton_regions: %s", tostring(errR)) end
                local okB, errB = pcall(bindNative, b, config)
                if not okB then DF:DebugWarn(DBG, "SlotOwner bindNative: %s", tostring(errB)) end
                -- After sizing (styleButton_regions owns SetSize), before the seal.
                layoutSlotButton(b, config, owner.anchor)
            end
            -- ☠ RE-ASSERT THE CONSUMER'S BASE ALPHA. Buttons are created in LAZY BATCHES
            -- long after AcquireSlot returns, so applyPlacedAlpha has very often already
            -- run against a handle whose GetAlphaHost was still nil -- it stashed the
            -- value on the handle and had nowhere to put it. Without this the Alpha
            -- slider would appear to work only when it happened to be moved AFTER the
            -- button materialised, which is the kind of intermittent that reads as a
            -- different bug entirely. The OOR fade recovers on its own (it runs on every
            -- range update); a base alpha set once does not.
            if host and handle._dfADBaseAlpha then
                pcall(host.SetAlpha, host, handle._dfADBaseAlpha)
            end
            if spec.onInit then
                local okI, err = pcall(spec.onInit, b, host)
                if not okI then DF:DebugWarn(DBG, "SlotOwner onInit failed: %s", tostring(err)) end
            end
        end,
    })
    if not okS or not btn then
        DF:DebugWarn(DBG, "SlotOwner: AddAuraSlot(%s) failed: %s", slotKey, tostring(btn))
        return nil
    end

    handle.button = btn
    owner.slots[slotKey] = handle
    owner.seq = owner.seq + 1

    -- ☠ REGISTER FOR THE IDENTITY-GATE SWEEP. A slot is NOT in AuraContainer._handles
    -- (that registry is Handle-shaped -- the sweep and the debug dump both read
    -- h.config.unit and call Handle methods), so it needs its own weak-keyed list or the
    -- gate only ever runs at tuning time and never re-evaluates when the roster, phase or
    -- target changes. Weak keys so a dropped slot GCs with its owner.
    AuraContainer._slotHandles = AuraContainer._slotHandles
        or setmetatable({}, { __mode = "k" })
    AuraContainer._slotHandles[handle] = true

    -- Seed the gate's inputs from the spec this slot was built with, then evaluate once.
    -- Without this a slot is ungated until its first ApplyTuning, and the AD path can
    -- reach a first paint before then.
    handle._idGateVulnerable    = filterVulnerableToIdentityGate(filter, spec.candidateFilters)
    handle._idGateSourceRelative = filterSourceRelative(filter, spec.candidateFilters)
    handle:_applyIdentityGate()
    -- ☠ SEED THE LATCHES TOO — both are edge-driven, and a slot born AFTER the edge hears
    -- nothing. SetUnitDeathLatched / CineLatchAll loop the registries at the transition;
    -- a slot created later (indicator re-enabled beside a ghost, options touched during a
    -- cinematic) starts unlatched and renders until the NEXT edge, which for an
    -- already-dead unit never comes. The Handle build has the same seed; re-adopted slots
    -- do not need it — they sat in _slotHandles the whole time, so the edges reached them.
    if AuraContainer._deathLatchedUnits[spec.unit] then
        pcall(function() handle:_setDeathLatch(true) end)
    end
    if AuraContainer._cineActive and handle._idGateVulnerable then
        pcall(function() handle:_setCineLatch(true) end)
    end

    -- Enabled defaults true on the template, but assert it once the container actually
    -- has a slot: registration needs HasAnyAuraSlots, which only became true just now.
    pcall(owner.container.SetEnabled, owner.container, true)
    return handle
end

function SlotHandle:GetButton()    return self.button end
function SlotHandle:GetLevelHost() return self.button and self.button.dfLevelHost or nil end
function SlotHandle:IsParked()     return self.parked == true end

-- ★ DROP-IN COMPATIBILITY with the two places that already treat an AD handle
-- generically, so migrating a consumer needs no change to either:
--
--   * AuraDesigner/Factory.lua's teardownExcept calls `entry.handle:Destroy()`.
--
-- ☠ THE OOR FADE IS *NOT* ONE OF THEM, AND CLAIMING IT WAS SHIPPED A BUG. This comment
-- used to say returning the button "keeps the OOR fade working untouched -- the button is
-- where a slot's alpha lives now, exactly as the per-indicator container's frame was
-- before". Both halves were wrong. The container's frame is DF-OWNED (a plain anchor
-- CreateFrame'd by AuraContainer:Create); the button is Blizzard's and carries
-- DenyTaintedAccessWhenAurasAreSecret, so it is not equivalent and not writable from the
-- fade's tainted path. It threw 43 times in one session. The fade asks GetAlphaHost now.
--
-- ⚠ Destroy CANNOT destroy: AddAuraSlot is add-only and there is no remove. It parks,
-- and the key is deliberately retained so a later AcquireSlot with the same structure
-- re-adopts this button instead of adding a second one.
function SlotHandle:GetFrame()     return self.button end
function SlotHandle:Destroy()      return self:Park() end

-- ☠ ALPHA HOST — NEVER THE BUTTON. RETURNING THE BUTTON IS A LIVE ERROR.
--
-- A per-indicator CONTAINER handle answers this with its own plain anchor frame
-- (Handle.frame, created by AuraContainer:Create), which is DF-owned and therefore a
-- legal write target from tainted code. A collapsed slot answers with dfLevelHost, the
-- DF-owned frame interposed between the button and every region styleButton_regions
-- creates. Fading it fades the whole slot, because nothing renders outside it.
--
-- The button itself is NOT a substitute. It carries DenyTaintedAccessWhenAurasAreSecret,
-- so any method call on it from a tainted path is refused the moment auras go secret --
-- field-confirmed as 43 errors from the out-of-range fade:
--     calling 'SetAlphaFromBoolean' on bad self (Attempt to access forbidden object
--     from code tainted by an AddOn)
-- SlotHandle:GetFrame returns the button on purpose (identity, and the OOR fade's old
-- `h:GetFrame()` probe), so consumers MUST ask for the alpha host separately rather than
-- assuming the two are the same object.
--
-- ★ WHY A CHILD FRAME IS WRITABLE WHERE THE BUTTON IS NOT, from the 12.1 source:
-- the restriction is applied by ApplyAccessRestrictions(auraFrame, ...) as a single
-- AddAccessRestrictions call on the BUTTON ALONE. Unlike forbidden aspects -- which
-- ValidateInboundScriptObject's own comment says "propagate through parent/child
-- hierarchies" -- access restrictions do not descend. Blizzard's setters still accept
-- our regions from one level deeper because IsDescendantOf allows "a direct child or
-- indirect descendent of owner".
--
-- ⚠ Still nil if host creation failed (pcall'd, pre-seal): consumers skip rather than
-- reach for the button, which is the behaviour that stopped the error storm.
function SlotHandle:GetAlphaHost() return self.button and self.button.dfLevelHost or nil end

-- ☠ THE SLOT-SIDE REGEN DRAIN, shared by every SlotHandle deferral (_pendingTuning from
-- ApplyTuning / Park / Restore, _pendingRestyle from ApplyStyle). One frame, one pending
-- set — a second parallel mechanism would order tuning and restyle by accident of which
-- event handler ran first. Drain order is tuning BEFORE restyle (population first,
-- cosmetics second), matching both the container-side regen drain and _readoptParked.
local function registerSlotRegen(handle)
    local reg = AuraContainer._slotRegen
    if not reg then
        reg = CreateFrame("Frame")
        -- Weak keys: a slot torn down before regen must not be kept alive by this.
        reg._pending = setmetatable({}, { __mode = "k" })
        reg:RegisterEvent("PLAYER_REGEN_ENABLED")
        reg:SetScript("OnEvent", function(selfFrame)
            for h in pairs(selfFrame._pending) do
                selfFrame._pending[h] = nil
                -- pcall per slot so one failure cannot strand the rest, matching the
                -- container-side regen drain.
                if h._pendingTuning then
                    h._pendingTuning = nil
                    pcall(h._replayTuning, h)
                end
                if h._pendingRestyle then
                    h._pendingRestyle = nil
                    pcall(h.ApplyStyle, h)
                end
            end
        end)
        AuraContainer._slotRegen = reg
    end
    reg._pending[handle] = true
end

-- Stop this slot displaying, WITHOUT destroying anything. Proven in game 2026-08-05:
-- an empty filter string matches nothing (it does NOT fall back to a default).
-- ⚠ Display only -- the slot keeps its key and its button.
-- ☠ TWO INDEPENDENT REASONS A SLOT CAN BE DARK, and they must not clobber each other:
-- `parked` is the CONSUMER's decision (indicator disabled, structural swap) and
-- `_gateHidden` is the IDENTITY GATE's. Before this there was only `parked`, so whichever
-- wrote last won -- a consumer Restore would have un-hidden a gated slot and leaked the
-- auras the gate exists to suppress. One writer, one resolution.
-- ☠ THE SLOT PARK STRING. Was "" and is no longer, because an empty filter parking a slot
-- is a CONVENTION the engine is free to change, not a guarantee.
--
-- It was proven in game on the 2026-08-05 build (`/alpark`, two side-by-side slots: the
-- emptied plate went blank, the control kept its icon) and the note written at the time
-- named this exact fallback for the day it stopped holding: a filter that matches nothing
-- BY CONSTRUCTION rather than by convention. That day arrived -- an AD indicator kept
-- rendering with gate=true, pushed=[] and pushOK=true, i.e. the gate decided correctly,
-- the empty string was pushed, the engine accepted it, and the artwork stayed on screen
-- (Krathe, 2026-08-18).
--
-- "HELPFUL|!HELPFUL" cannot match: the same token is required and forbidden in one
-- predicate. No engine reading of it produces an aura, so this does not depend on how an
-- empty predicate is interpreted. It is valid to IsValidFilterString either way.
-- ⚠ Deliberately not HARMFUL-flavoured for harmful slots. The contradiction is what parks
-- it, not the polarity, so one constant serves every slot and there is no branch to get
-- wrong.
local SLOT_PARK_FILTER = "HELPFUL|!HELPFUL"
-- ⚠ Also on the module table: NativeBackend:ApplyTuning pushes the park string for
-- slot-backed rows and sits EARLIER in this file, where the local is not yet in scope. The
-- field resolves at call time, so both writers park with the identical string -- which they
-- must, or whichever runs last decides and one of them is the retired convention.
AuraContainer.SLOT_PARK_FILTER = SLOT_PARK_FILTER

function SlotHandle:_pushFilter()
    local c = self.owner and self.owner.container
    if not c then return false end
    -- ☠☠ THE FILTER PUSH CANNOT HIDE A SLOT ON A UNIT THE GATE DISTRUSTS, and that is not
    -- a defect in the park string -- it is the fail-open mechanism itself. For a unit whose
    -- identity data is unavailable (not visible / cross-instance / cinematic) the engine
    -- fails open and NOTHING RE-PARSES (proven for cinematics in the UNIT_FACTION
    -- investigation; reproduced here in game: gate=true, pushed=[], pushOK=true, artwork
    -- still on screen, and a freshly placed indicator INSTANTLY bound the unit's top aura
    -- because the initial parse skipped its candidate filters too -- Krathe, 2026-08-18).
    -- Any filter we push -- empty, contradictory, anything -- lands in the engine and sits
    -- there unconsulted until identity recovers. The stale bound aura keeps rendering.
    --
    -- The Handles never had this failure because they hide a DF-OWNED FRAME. The slot
    -- equivalent is the owner ANCHOR: ensureOwner's plain frame between the unit frame and
    -- the shared container, already the OOR fade's alpha host, ours to write in or out of
    -- combat. Hiding it hides every slot button under it.
    --
    -- ⚠ UNIT-LEVEL VERDICTS ONLY. gate/cine/death are properties of the UNIT, so every
    -- slot on this owner computes the same answer and the shared anchor is the right
    -- grain. `parked` is per-slot consumer state (one disabled indicator) and must NOT
    -- hide the owner -- it stays filter-only.
    local unitHidden = (self._gateHidden or self._cineLatched or self._deathLatched)
        and true or false
    local anchor = self.owner.anchor
    if anchor then pcall(anchor.SetShown, anchor, not unitHidden) end
    local want = (self.parked or unitHidden)
        and SLOT_PARK_FILTER or self.liveFilter
    local ok = pcall(c.SetAuraSlotFilterString, c, self.key, want)
    -- ☠ RECORD WHAT WAS ACTUALLY PUSHED, AND WHETHER IT TOOK. /df debug idgate used to
    -- print liveFilter under a comment calling it "the pushed string" -- it is not, it is
    -- the STORED filter, which never changes when the gate hides a slot. So a slot could
    -- read gateHidden=true filter=HELPFUL|PLAYER and that told you nothing about whether
    -- the empty string ever reached the engine. Diagnosing an indicator that renders while
    -- the gate believes it hidden needs the pushed value, not the intended one.
    self._pushedFilter = want
    self._pushOK = ok and true or false
    return ok
end

-- ☠ A REFUSED PUSH MUST NOT BE LATCHED AND FORGOTTEN. `parked` records the consumer's
-- DECISION and is correct to latch immediately (the early-returns key off it), but the
-- filter push that actuates it can be refused in lockdown — and before this, the latch
-- plus the early-return meant a refused push was never retried, so the old visual kept
-- rendering forever. On failure, queue the regen replay: _replayTuning re-runs
-- _pushFilter, which re-derives from parked/_gateHidden/liveFilter at drain time, so
-- whatever the state is BY THEN is what gets pushed (a Park then Restore in the same
-- fight collapses to one correct push).
function SlotHandle:Park()
    if self.parked then return true end
    self.parked = true
    local ok = self:_pushFilter()
    -- ⚠ Queue on lockdown even when pcall reported success: whether a secure setter
    -- refuses loudly (error) or quietly (no-op) is the engine's business, and the replay
    -- is idempotent either way.
    if not ok or InCombatLockdown() then
        self._pendingTuning = true
        registerSlotRegen(self)
    end
    return ok
end

-- Same failure contract as Park — the re-adopt path (AcquireSlot on an existing key)
-- calls this in combat, and a refused un-park left the slot dark forever.
function SlotHandle:Restore()
    if not self.parked then return true end
    self.parked = false
    local ok = self:_pushFilter()
    if not ok or InCombatLockdown() then
        self._pendingTuning = true
        registerSlotRegen(self)
    end
    return ok
end

-- ☠ THE IDENTITY GATE, WHICH THIS PATH HAD NONE OF. Every Aura Designer placed config
-- carries candidateFilters.includeSpellIDs, which is precisely what makes a filter
-- vulnerable -- so on a cross-faction arena opponent, or a party member in a different
-- instance or phase, includeSpellIDs FAILS OPEN engine-side and every AD indicator lights
-- for every aura on the target. That is the same class as the bugs the Handle gate was
-- written to fix, and migrating the consumers onto slots quietly bypassed it: SlotHandle
-- had no gate, no vulnerability flags, and was not in AuraContainer._handles, so
-- IdentityGateSweep never visited it.
--
-- Verdict logic is deliberately identical to Handle:_applyIdentityGate -- fail-open on
-- UnitCanAssist (hide only on a definite false), fail-safe on UnitIsVisible -- because
-- two gates that disagree are worse than one. What differs is the ACTUATION: a Handle
-- hides its frame, a slot has no frame of its own, so it parks. Parking is already the
-- right primitive (an empty filter string matches nothing, proven in game).
-- Slot-side twin of Handle:_noteGateRecovery — same edge, same reason (read that
-- header for the cinematic/UNIT_FACTION mechanism). The ACTUATION differs, as it does
-- for the gate itself: a slot has no backend to bounce.
--
-- ☠ AND IT IS THE CANDIDATES THAT MUST BE RE-PUSHED, NOT THE FILTER STRING.
-- `includeSpellIDs` is a CANDIDATE filter, not part of the filter string — so the
-- narrowing the fail-open skipped does not live in what _pushFilter sends, and
-- re-pushing an unchanged string need not reparse at all. First cut of this fix did
-- exactly that and one placed AD indicator kept rendering open (Krathe, in game);
-- the buff bars were fixed because the Handle path bounces the whole backend.
-- SetAuraSlotCandidateFilters has NO engine-side equality check — every call clears
-- the slot's candidates and reparses — which is precisely the bounce wanted here.
--
-- For a slot the gate DID hide, the transition below already re-pushes the string, so
-- this edge is what covers the case the gate never hides at all: your own frame.
-- CINEMATIC LATCH, slot half (see cineWatch at the bottom of the file). A slot has
-- no frame of its own, so the latch actuates the way the slot gate does: through
-- _pushFilter, where an empty string matches nothing (proven in game). Same failure
-- contract as Park/Restore -- a refused CLEAR would otherwise leave the slot dark
-- forever, so failure or lockdown queues the regen replay, which re-derives from
-- whatever the latch state is by drain time.
-- ☠☠ AND THE CLEAR RE-PARSES, for the reason written on Handle:_setCineLatch: the
-- cinematic window is fail-open BY DEFINITION, so "assist never dropped" is not evidence
-- the slot's parse is clean. Re-pushing candidateFilters is the slot's re-parse (the same
-- lever _noteGateRecovery uses), and it is what stops a stale fail-open selection
-- surviving the cinematic.
-- ⚠ Deferred in lockdown to the SAME replay the actuation already queues below — no
-- native tuning setter runs in combat, and the replay re-pushes candidates, verdict and
-- filter together on the way out.
-- ⚠ skipReparse is for _noteGateRecovery, which has just re-pushed candidates itself.
function SlotHandle:_setCineLatch(on, skipReparse)
    on = on or nil
    if self._cineLatched == on then return end
    self._cineLatched = on
    local ok = self:_pushFilter()
    local wantReparse = (not on) and not skipReparse
        and self._lastCandidateFilters ~= nil
    if not ok or InCombatLockdown() then
        self._pendingTuning = true
        registerSlotRegen(self)
    elseif wantReparse then
        local c = self.owner and self.owner.container
        if c then
            pcall(c.SetAuraSlotCandidateFilters, c, self.key, self:_cf())
        end
    end
end

-- DEATH LATCH, slot half (#1043) — see Handle:_setDeathLatch for the mechanism
-- and the tradeoff. Same actuation and failure contract as the cine latch; the
-- CLEAR also re-pushes candidates (the standard replay covers it in lockdown),
-- because the death window produced no aura events and the standing parse
-- predates the death.
function SlotHandle:_setDeathLatch(on)
    on = on or nil
    if self._deathLatched == on then return end
    self._deathLatched = on
    local ok = self:_pushFilter()
    if not ok or InCombatLockdown() then
        self._pendingTuning = true
        registerSlotRegen(self)
        return
    end
    if not on and self._lastCandidateFilters ~= nil then
        local c = self.owner and self.owner.container
        if c then pcall(c.SetAuraSlotCandidateFilters, c, self.key, self:_cf()) end
    end
end

function SlotHandle:_noteGateRecovery(can)
    local was = self._idGateAssist
    self._idGateAssist = can and true or false
    if was ~= false or not self._idGateAssist then
        return
    end
    local c = self.owner and self.owner.container
    -- ☠ NO CONTAINER = NO REPLAY QUEUED, so the edge must NOT be spent. Unlike the two
    -- branches below, this one leaves nothing behind that will finish the job: the
    -- verdict would read recovered while the candidate filters were never re-pushed, and
    -- the false->true transition never comes again. Hold it and the next gate pass
    -- retries. (The no-filters case below is safe to consume -- a slot that has never had
    -- a gated selection pushed has nothing stale to re-parse.)
    -- Same failure the Handle twin shipped; see Handle:_noteGateRecovery for the full
    -- account of why one spent edge is permanent.
    if not c then
        self._idGateAssist = was
        return
    end
    if self._lastCandidateFilters == nil then return end
    GateLog("slot recovered key=%s unit=%s - re-parsing (pool was fail-open)",
        tostring(self.key), tostring(self.owner and self.owner.unit))
    -- ☠ No native tuning setter runs in lockdown (see ApplyTuning). Queue the standard
    -- replay, which re-pushes candidates, verdict and filter together on the way out.
    -- The latch flag clears NOW in both branches -- the replay's _pushFilter derives
    -- from the flag at drain time, so leaving it set would re-park the slot the
    -- moment combat dropped.
    if InCombatLockdown() then
        self._cineLatched = nil
        self._pendingTuning = true
        registerSlotRegen(self)
        return
    end
    pcall(c.SetAuraSlotCandidateFilters, c, self.key, self:_cf())
    -- After the bounce, matching the Handle: the slot un-parks already re-parsed.
    -- skipReparse: the candidate re-push above IS that bounce.
    self:_setCineLatch(nil, true)
end

function SlotHandle:_applyIdentityGate()
    local hide = false
    local why   -- the FIRST probe that broke trust this pass, for the gate log
    -- ☠ Widened with the Handle's entry test, for the reason stated there: an AD indicator
    -- on a unit in another instance is as stale as any row, whatever its filter carries.
    -- The verdict logic is deliberately identical to Handle:_applyIdentityGate, so the two
    -- entry conditions must stay identical too -- two gates that disagree are worse than one.
    if not AuraContainer._testMode then
        local unit = self.owner and self.owner.unit
        -- ☠ See Handle:_applyIdentityGate — the `unit ~= "player"` exemption moved off
        -- this line onto the hide branches so the player's own slot is PROBED, and has
        -- now been dropped from the ASSIST branch as well: the cinematic latch already
        -- hides own handles (CineLatchAll takes no isOwn), so the exemption only ever
        -- applied to the un-latched case — a vehicle — where it left the player's own
        -- slots rendering an unfiltered pool.
        if type(unit) == "string" and UnitExists(unit) then
            -- ☠ UnitIsUnit, not a string compare: in raid layouts your own token is
            -- `raidN`, so `unit == "player"` never matched your own frame there and the
            -- exemption below silently did not apply to you. A no-op in practice today
            -- (you are always visible and same-phase to yourself, so neither probe trips)
            -- — but the compare is wrong, and the next probe added here may not be as kind.
            local okOwn, ownSame = pcall(UnitIsUnit, unit, "player")
            local isOwn = (okOwn and ownSame) and true or false
            if self._idGateVulnerable then
                local ok, can = pcall(UnitCanAssist, "player", unit)
                if ok then
                    if issecretvalue and issecretvalue(can) then can = true end
                    -- ★ Boarding window — see SelfIsUsingVehicle and the Handle twin.
                    if can and SelfIsUsingVehicle(unit) then can = false; why = "self-vehicle" end
                    -- ★ Disconnected / dead / ghost — see IdentityUnavailable. Folded
                    -- into `can` like the vehicle probe, so a rez or a reconnect is a
                    -- real false→true edge and re-parses the pool rather than just
                    -- un-hiding a stale one.
                    if can and not isOwn then
                        local unavail = IdentityUnavailable(unit)
                        if unavail then can = false; why = unavail end
                    end
                    if not can and not why then why = "cannot-assist" end
                    self:_noteGateRecovery(can)
                    if not can then hide = true end
                end
            end
            -- ☠ NO LONGER GATED ON _idGateSourceRelative. It was from the day it landed
            -- (ad0985c9), because it was written for one narrow failure: the PLAYER-token
            -- "mine" filter passing every caster's aura when the engine cannot attribute a
            -- caster. Sound reasoning, far too narrow for what the probe actually tells you.
            --
            -- UnitIsVisible is INSTANCE-SCOPED, not range-scoped -- true for a same-instance
            -- member far outside 40yd, false only across instances and phases
            -- (field-verified 3-case probe, see filterVulnerableToIdentityGate's header).
            -- A unit reading false is not in your world at all, so EVERY pool it renders is
            -- stale, not just the source-relative ones. Restricting the response to "mine"
            -- filters left a cross-instance unit rendering a full debuff row and dispel
            -- overlay while its buff bar was correctly blanked (Krathe, 2026-08-18).
            --
            -- ⚠ Widening is safe BECAUSE the signal is instance-scoped. Were it range-based
            -- this would blank half a raid's debuffs -- the exact failure class
            -- UNIT_CONNECTION / UNIT_FLAGS were registered for. Do not widen a range-based
            -- probe by analogy with this one.
            -- ⚠ isOwn still stands: you are always visible to yourself, so it stays
            -- belt-and-braces rather than a behaviour decision.
            if not hide and not isOwn then
                local okv, vis = pcall(UnitIsVisible, unit)
                if okv and not (issecretvalue and issecretvalue(vis)) and not vis then
                    hide = true; why = why or "not-visible"
                end
                -- ☠ THE "/phase" HALF OF THE COMMENT ABOVE WAS NEVER IMPLEMENTED. A unit
                -- in another phase, layer or Chromie time can be UnitIsVisible TRUE and
                -- still be unattributable, so the source-relative filter fails open with
                -- the visibility probe perfectly happy. UnitPhaseReason returns nil for
                -- same-phase and a reason otherwise (Features/Range.lua reads it the same
                -- way).
                -- ⚠ Only reliable within ~250yd (Frames/StatusIcons.lua). Past that it
                -- returns nil, which reads as "same phase", which SHOWS — the
                -- unreliability fails in the safe direction, so no distance guard.
                if not hide and UnitPhaseReason then
                    local okp, reason = pcall(UnitPhaseReason, unit)
                    if okp and not (issecretvalue and issecretvalue(reason)) and reason then
                        hide = true; why = why or "phased"
                    end
                end
            end
        end
    end
    -- Stash for /df debug idgate, mirroring the Handle.
    self._idGateWhy = hide and why or nil
    local newHidden = hide or nil
    if self._gateHidden ~= newHidden then
        self._gateHidden = newHidden
        GateLog("slot %s key=%s unit=%s why=%s",
            newHidden and "hide ON" or "hide OFF", tostring(self.key),
            tostring(self.owner and self.owner.unit), tostring(why or "-"))
        self:_pushFilter()
    end
end

-- Live tuning. All three are real live mutators on the slot; none needs a rebuild.
-- ⚠ SetAuraSlotCandidateFilters has NO equality check engine-side -- every call clears the
-- slot's candidates and reparses -- so callers should compare before calling.
--
-- ☠ STORE BEFORE THE COMBAT CHECK, exactly as Handle:ApplyTuning does. The Factory stamps
-- entry.tuningSig BEFORE calling this, so a dropped pass is never retried by SyncFrame --
-- the stored state below plus the regen replay is the ONLY thing standing between an
-- in-combat selection edit and it being silently lost (bug #1024). The engine's own rule
-- (see applyGroupTuning's header) is that no native tuning setter runs in lockdown; this
-- path used to break that rule, pcall-swallow the refusals, and return true anyway.
function SlotHandle:ApplyTuning(filter, candidateFilters, sortMethod, sortDirection)
    local c = self.owner and self.owner.container
    if not c then return false end
    local filterChanged = false
    if filter ~= nil and filter ~= self.liveFilter then
        self.liveFilter = filter
        filterChanged = true
    end
    local candidatesChanged = candidateFilters ~= nil
    if candidatesChanged then
        self._lastCandidateFilters = candidateFilters
    end
    -- Kept for the replay: sort is not otherwise stored on the handle (AddAuraSlot took
    -- it as an option), so a deferred sort edit would have nothing to replay from.
    if sortMethod ~= nil then
        self._lastSortMethod    = sortMethod
        self._lastSortDirection = sortDirection or 0
    end
    -- Recompute the gate's INPUTS whenever either half of the filter moves -- the verdict
    -- depends on the filter string AND the candidateFilters together, so recomputing on
    -- only one of them leaves a slot flagged from its previous configuration. Pure stored
    -- state, so it is correct to do even in lockdown -- only the secure pushes defer.
    if filterChanged or candidatesChanged then
        local cf = self._lastCandidateFilters   -- RAW on purpose -- see _cf()'s header
        self._idGateVulnerable    = filterVulnerableToIdentityGate(self.liveFilter, cf)
        self._idGateSourceRelative = filterSourceRelative(self.liveFilter, cf)
    end
    -- Defer and replay, mirroring ApplyStyle below. The gate VERDICT is deliberately not
    -- re-evaluated here in combat: _applyIdentityGate actuates via a secure push, and the
    -- replay runs it first thing out of lockdown, before any filter reaches the engine.
    if InCombatLockdown() then
        self._pendingTuning = true
        registerSlotRegen(self)
        return false
    end
    if candidatesChanged then
        -- Through _cf(): the argument is the LIVE map by definition, and a tuning pass on a
        -- gated-dark slot must not un-gate it -- the same clobber the container lane's
        -- chokepoint design exists to prevent.
        pcall(c.SetAuraSlotCandidateFilters, c, self.key, self:_cf())
    end
    -- Re-evaluate before pushing, so a slot that just became vulnerable is dark on the
    -- very first pass rather than showing one frame of the wrong player's auras.
    self:_applyIdentityGate()
    -- ☠ UNCONDITIONAL. This used to be `if filterChanged then`, which re-asserted the
    -- slot's filter only when the FILTER moved -- but what must reach the engine is the
    -- gate's verdict, and _applyIdentityGate pushes only on a VERDICT TRANSITION. A pass
    -- where neither moved therefore pushed nothing, so anything that cleared the slot
    -- engine-side since the last push stayed cleared: notably SetAuraSlotCandidateFilters
    -- immediately above, which has no equality guard and reparses the slot on every call.
    -- The gate stayed convinced the slot was hidden and never said so again -- an AD
    -- indicator rendering with gateHidden=true (Krathe, 2026-08-18).
    --
    -- Free to do every pass: SetAuraSlotFilterString carries its own equality guard
    -- engine-side, which is why the group path already pushes unconditionally.
    self:_pushFilter()
    if sortMethod ~= nil then
        pcall(c.SetAuraSlotSortMethod, c, self.key, sortMethod, sortDirection or 0)
    end
    return true
end

-- The regen half of ApplyTuning's defer-and-replay. Coarse on purpose: it re-pushes the
-- whole stored trio rather than tracking which of them the deferred call(s) touched --
-- delta tracking would be a second bookkeeping mechanism to keep honest, and this runs
-- once per combat-edited slot per regen. The candidateFilters re-push (no engine-side
-- equality check) is the only real cost, and it is out of combat by definition here.
-- ⚠ _pushFilter runs UNCONDITIONALLY: it re-derives from parked/_gateHidden/liveFilter,
-- so this drain also heals a Park/Restore/gate push that was refused mid-combat.
function SlotHandle:_replayTuning()
    local c = self.owner and self.owner.container
    if not c then return end
    if self._lastCandidateFilters ~= nil then
        -- Through _cf(), not the raw stash: this replay is the combat-exit drain for every
        -- deferred push, including the helper gate's own -- raw here meant a gated slot
        -- came out of combat un-gated.
        pcall(c.SetAuraSlotCandidateFilters, c, self.key, self:_cf())
    end
    -- Verdict first (population order matches ApplyTuning): a slot that became
    -- vulnerable during combat must come out of it dark, not flash one frame open.
    self:_applyIdentityGate()
    self:_pushFilter()
    if self._lastSortMethod ~= nil then
        pcall(c.SetAuraSlotSortMethod, c, self.key, self._lastSortMethod,
            self._lastSortDirection or 0)
    end
end

-- ═══ HELPER GATE: THE SLOT LANE ═══
-- The slot-path twin of recordCandidateFilters: same test, same dead map, derived at READ
-- time. The stash itself is never overwritten -- destroying the live map is the failure the
-- container lane's design already rejected, and here it would also strand the recovery
-- edge, which treats "no filter list" as "nothing to repair" and fires exactly once.
--
-- ⚠ NIL-FAITHFUL BY CONSTRUCTION: returns nil exactly when the stash is nil, never
-- otherwise. Every nil test at the read sites keeps its meaning, and the recovery edge can
-- never be burned by a gated slot that has a real selection.
--
-- ⚠ THE ONE READ THAT STAYS RAW is ApplyTuning's vulnerability recompute:
-- _idGateVulnerable is a property of the user's REAL selection, and deriving it from the
-- dead map would drop a gated-dark slot out of the cinematic-latch population -- it would
-- come back from a cutscene fail-open.
--
-- ☠ CANDIDATE LANE ONLY. The identity gate's verdicts actuate through the shared
-- owner anchor because gate/cine/death are UNIT-level facts (see _pushFilter). Ours is
-- per-EFFECT -- one helper icon beside a user's own indicator on the same unit -- so it
-- must never touch the anchor or the filter string.
function SlotHandle:_cf()
    local cf = self._lastCandidateFilters
    if cf ~= nil and self.config and self.config.dfGate
        and (helperGateDark or helperRoleExcluded(self.owner and self.owner.unit)) then
        return HELPER_GATE_DEAD_CF
    end
    return cf
end

-- One gate edge, one slot: re-push the (now re-derived) candidates. The lockdown branch is
-- the recovery path's own shape -- no native tuning setter runs in combat, and
-- _replayTuning drains the deferral on the way out, itself reading through _cf().
function SlotHandle:_applyHelperGate()
    if self._lastCandidateFilters == nil then return false end
    local c = self.owner and self.owner.container
    if not c then return false end
    if InCombatLockdown() then
        self._pendingTuning = true
        registerSlotRegen(self)
        return true
    end
    pcall(c.SetAuraSlotCandidateFilters, c, self.key, self:_cf())
    return true
end

-- In-place cosmetic restyle, mirroring Handle:ApplyStyle. Re-runs the engine's region
-- pipeline against the updated config -- the same call the per-indicator path makes, so a
-- migrated consumer keeps every live cosmetic it has today (colours, sizes, fonts,
-- offsets, bar geometry, tooltip placement).
--
-- ⚠ Combat: Handle:ApplyStyle defers to regen because restyling live buttons mid-combat
-- diverges from the build-once-leave-it pattern. Same rule here -- the caller re-drives
-- on its own version gate, so dropping the pass is correct rather than lossy.
function SlotHandle:ApplyStyle(style, layout)
    local cfg, btn = self.config, self.button
    if not (cfg and btn) then return false end
    if type(style) == "table" then cfg.style = style end
    if type(layout) == "table" then cfg.layout = layout end
    -- ☠ DEFER AND REPLAY -- returning false alone LOSES the edit.
    -- The new style/layout are already stored on cfg above, so the config is right; only
    -- the paint is skipped. But AuraDesigner/Factory.lua stamps entry.coSig BEFORE calling
    -- this, so the next SyncFrame pass sees no delta and never retries, and nothing else
    -- re-drives AD at combat end. Net: a cosmetic edit made in combat -- a border colour,
    -- an alpha drag, a group offset -- was saved to the profile and never appeared until
    -- the user touched some unrelated setting or reloaded. This is the DEFAULT path, since
    -- every placed indicator goes through the shared slot.
    --
    -- Handle:ApplyStyle already does exactly this (_pendingRestyle + _registerRegen); the
    -- slot side never got an equivalent. Replaying with NO arguments is correct: the
    -- `type(...) == "table"` guards above mean a bare call re-paints from stored cfg.
    if InCombatLockdown() then
        self._pendingRestyle = true
        registerSlotRegen(self)
        return false
    end
    -- ☠ REFUSE TO STYLE A SLOT WHOSE LEVEL HOST DOES NOT EXIST YET, and the damage is
    -- PERMANENT if we don't. styleButton_regions resolves `local host = slot.dfLevelHost
    -- or slot` -- a fallback that is right for a CONTAINER button (which never has a
    -- host) and catastrophic for a slot: it would create dfIcon, dfBorder and every
    -- holder parented to the Blizzard aura button instead of our own frame. Blizzard's
    -- InitializeInboundScriptObject stamps ForbiddenAspect.ChangeParent on that button,
    -- so those regions can never be reparented afterwards -- the slot is stuck with an
    -- empty alpha host for its whole life, and GetAlphaHost then returns nothing, which
    -- silently kills the per-indicator Alpha slider and the out-of-range fade for that
    -- indicator alone. Intermittent by batch timing, which is the worst way to find it.
    --
    -- Dropping the pass is safe: the caller re-drives on its own version gate, and the
    -- config we just stored above is what initializeFrame will style from when it runs.
    if not btn.dfLevelHost then
        DF:Debug(DBG, "SlotHandle:ApplyStyle deferred -- no dfLevelHost yet (key=%s)",
            tostring(self.key))
        return false
    end
    local ok, err = pcall(styleButton_regions, btn, cfg)
    if not ok then DF:DebugWarn(DBG, "SlotHandle:ApplyStyle: %s", tostring(err)) end
    -- ☠ bindNative too, exactly as Handle:ApplyStyle does. Its binds are keyed on spec
    -- identity, not bind-once, so this is how a duration-format / zeroText /
    -- updateInterval / dispel-palette change reaches a LIVE slot. Without it those would
    -- silently keep the spec they were created with and the signature entries below could
    -- not be reduced.
    local okB, errB = pcall(bindNative, btn, cfg)
    if not okB then DF:DebugWarn(DBG, "SlotHandle:ApplyStyle bindNative: %s", tostring(errB)) end
    -- Re-anchor after restyle: anchor/offset/scale are live cosmetics (dragging an
    -- indicator moves it now, not on the next reload), and styleButton_regions has just
    -- re-run SetSize, so the pin has to follow it.
    layoutSlotButton(btn, cfg, self.owner and self.owner.anchor)
    return ok
end

-- Per-indicator alpha, on the alpha host.
-- ☠ THIS USED TO WRITE THE BUTTON, AND THE pcall HID THAT IT COULDN'T. Its comment
-- claimed the button "is where the per-indicator container's frame carried it before" —
-- it is not: that frame was DF's own, the button is Blizzard's and carries
-- DenyTaintedAccessWhenAurasAreSecret. The identical mistake in applyPlacedAlpha was
-- equally silent, and only surfaced because the out-of-range fade makes the same call
-- WITHOUT a pcall (43 errors in one session). Route through GetAlphaHost like everything
-- else, and report failure instead of swallowing it.
-- ⚠ Never drive this to 0 as a way of hiding a slot -- park it instead. A button's shown
-- state is secret-backed and descendant effects inherit it, so alpha 0 silences those too
-- rather than just hiding the icon.
function SlotHandle:SetAlpha(alpha)
    if type(alpha) ~= "number" then return false end
    local f = self:GetAlphaHost()
    if not f then return false end
    return pcall(f.SetAlpha, f, alpha)
end

-- Live z-order, on OUR frame — never on the sealed button. Available for a consumer whose
-- level is NOT already structural; the AD path sets level on the button at create instead
-- (see the header above AcquireSlot) and does not need this.
function SlotHandle:SetZOrder(level, strata)
    local host = self:GetLevelHost()
    if not host then return false end
    if strata then pcall(host.SetFrameStrata, host, strata) end
    if level then pcall(host.SetFrameLevel, host, level) end
    return true
end

-- There is no way to remove a slot, so release == park. The key is retained precisely so
-- a later AcquireSlot with the same structure re-adopts this button instead of adding a
-- second one.
function SlotHandle:Release() return self:Park() end

-- ☠ GetUnit/SetUnit ARE THE RETARGET CONTRACT, and their absence was a live bug.
-- Factory:SyncFrame walks every stored handle with
--     if h and h.GetUnit and h:GetUnit() ~= u and h.SetUnit then h:SetUnit(u) end
-- which is nil-guarded, so a handle missing these two methods is SILENTLY SKIPPED --
-- no error, no warning, just a container still pointed at whoever used to occupy that
-- frame. Handle has both (that is why the pre-collapse code worked); SlotHandle was
-- migrated into the same stores without them, so after any roster change -- someone
-- leaves, a sort reorders, party->raid, arena entry -- every Aura Designer placed
-- icon, bar and alert rendered ANOTHER PLAYER'S auras until /reload.
--
-- All slots on a frame share one owner and therefore one unit, so the loop's repeated
-- calls collapse: the first retargets, the rest hit the equality guard below.
function SlotHandle:GetUnit()
    return self.owner and self.owner.unit or nil
end

function SlotHandle:SetUnit(unit)
    if not (self.owner and self.owner.frame) then return false end
    return AuraContainer:SetSlotOwnerUnit(self.owner.frame, unit)
end

-- Owners whose retarget was blocked by combat. Weak-keyed, like the handle list: if the
-- frame and its owner go away, the entry goes with them rather than pinning them alive.
local function registerOwnerRegen(owner)
    if not AuraContainer._ownerRegen then
        AuraContainer._ownerRegen = CreateFrame("Frame")
        AuraContainer._ownerRegen._owners = setmetatable({}, { __mode = "k" })
        AuraContainer._ownerRegen:RegisterEvent("PLAYER_REGEN_ENABLED")
        AuraContainer._ownerRegen:SetScript("OnEvent", function(self)
            for o in pairs(self._owners) do
                self._owners[o] = nil
                local u = o.pendingUnit
                o.pendingUnit = nil
                -- Re-check: the owner may have been retargeted again, or torn down,
                -- between the defer and now.
                if u and o.container and o.unit ~= u then
                    o.unit = u
                    pcall(o.container.SetUnit, o.container, u)
                end
            end
        end)
    end
    AuraContainer._ownerRegen._owners[owner] = true
end

-- Retarget the whole owner. One container, one unit — cheaper than the per-indicator
-- containers it replaces, which each carried their own.
function AuraContainer:SetSlotOwnerUnit(frame, unit)
    local owner = ownerOf(frame)
    if not (owner and owner.container and type(unit) == "string") then return false end
    if owner.unit == unit then return true end
    -- ⚠ Defer in combat, same as Handle:SetUnit's "retarget" op. owner.unit is left on
    -- the OLD token deliberately, so GetUnit stays truthful about what is on screen and
    -- a repeat call simply re-queues rather than reporting a retarget that has not
    -- happened. The regen drain applies it.
    if InCombatLockdown() then
        owner.pendingUnit = unit
        registerOwnerRegen(owner)
        return false
    end
    owner.unit = unit
    local ok = pcall(owner.container.SetUnit, owner.container, unit)
    -- ⚠ The stored gate verdict was computed for the OLD unit. Re-run it for EVERY slot
    -- on this owner, exactly as Handle:SetUnit re-runs its own gate on retarget.
    -- ☠ EVERY slot, not just vulnerable/source-relative ones — this loop kept the gate's
    -- old three-way entry test after the 2026-08-18 widening, and it is the loop that
    -- decides the owner ANCHOR: had no slot here passed the filter, an anchor hidden for
    -- a not-visible old unit stayed hidden over the NEW unit's frame — a fail-to-unhide
    -- on plain roster churn. The death latch is unit state too, so it re-seeds from the
    -- registry the same way Handle:SetUnit does: the new unit may already be dead, and
    -- that edge will never fire again.
    local latched = AuraContainer._deathLatchedUnits[unit] or nil
    for _, h in pairs(owner.slots) do
        pcall(function() h:_setDeathLatch(latched) end)
        pcall(function() h:_applyIdentityGate() end)
    end
    return ok
end

-- Census hook for the S4 before/after. Returns live slot count, parked count, total.
function AuraContainer:GetSlotOwnerStats(frame)
    local owner = ownerOf(frame)
    if not owner then return 0, 0, 0 end
    local live, parked = 0, 0
    for _, h in pairs(owner.slots) do
        if h.parked then parked = parked + 1 else live = live + 1 end
    end
    return live, parked, live + parked
end

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
    -- TEST-FRAME PROVENANCE, resolved ONCE here rather than per toggle. Only a
    -- handle that will actually render the preview needs SetTestMode's rebuild;
    -- see rebuildAll for why the live ones never do. Resolving at Create is safe
    -- because every test frame carries dfIsTestFrame from its OWN creation --
    -- TestFramePool.lua stamps it on the pool frames and CreatePlayerTestFrame on
    -- the pinned ones, both long before any consumer drives a row onto them.
    -- Bounded walk: the anchor's parent is usually the unit frame, but AD hangs
    -- containers off the healthBar / background anchor / aura-bar strip instead.
    local ancestor = parent
    for _ = 1, 6 do
        if not ancestor then break end
        if ancestor.dfIsTestFrame then h._testFrame = true break end
        ancestor = ancestor.GetParent and ancestor:GetParent() or nil
    end
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
        --
        -- ★ 68914: AddAuraGroup stamps ForbiddenAspect.UntrustedLayoutScriptExecution
        -- on the container (Blizzard_CustomAuraContainer.lua:321), and SetPoint REFUSES
        -- a dependent that doesn't already carry the aspect ("Anchoring disallowed as
        -- dependent object would inherit forbidden aspects" — field-hit in a dungeon).
        -- Aspects are NEVER granted implicitly via SetParent/SetPoint, and tainted
        -- AddForbiddenAspects is disallowed — the sanctioned opt-in is inheriting
        -- DisableUntrustedLayoutScriptsTemplate at creation (ForbiddenAspectTemplates.xml,
        -- named in Blizzard's own comment above the stamp). Cost: the badge (and its
        -- children — border overlays, consumer art) may never run LAYOUT scripts
        -- (OnSizeChanged); nothing in the badge subtree uses them. Template-probe so
        -- pre-68914 builds (no such template) keep the plain frame they never needed.
        local aspectTmpl = C_XMLUtil and C_XMLUtil.GetTemplateInfo
            and C_XMLUtil.GetTemplateInfo("DisableUntrustedLayoutScriptsTemplate")
            and "DisableUntrustedLayoutScriptsTemplate" or nil
        h.badge = CreateFrame("Frame", nil, h.frame, aspectTmpl)
        h.badge:SetSize(bw, bh)
        h.badge:SetPoint("TOPLEFT", h.frame, "TOPLEFT", sp, -sp)
        h.badge:Hide()
    else
        -- Row/overlay: h.frame occupies the unit-frame rect (row layout anchors are
        -- relative to it; overlay covers it). Reposition: h:ClearAllPoints() + h:SetPoint(...).
        h.frame:SetAllPoints(parent)
        -- pp: the pin snap depends on this rect (position AND width/height — centre
        -- and right-side anchors reference them), so a resize invalidates it. This
        -- also fires on the frame's FIRST layout (size resolving 0 -> WxH), making
        -- it the primary late-login re-pin path; the OnUpdate poll in
        -- applyContainerLayout is the belt-and-braces fallback. No-op for non-pp
        -- users and for overlay mode (no pin — the container covers the host).
        if cfg.mode ~= "overlay" then
            h.frame:SetScript("OnSizeChanged", function()
                local c = h._pp and h.backend and h.backend.container
                if c then pcall(applyContainerLayout, c, h) end
            end)
        end
    end
    h:_applyZOrder()   -- level + strata; also re-runs on every _build (see the method)

    if InCombatLockdown() then
        -- Can't safely stand up secure container state in combat; build on regen.
        h:_deferRebuild()
    else
        h:_build()
    end
    -- FALLBACK PATH ONLY (_fakeActive never latches once deafening is confirmed):
    -- born during a foreign fake-data period (e.g. roster change while the user
    -- sits in Edit Mode), start hidden like the rest, restored on the real switch.
    local watch = AuraContainer._providerWatch
    -- Parent-driven handles are skipped: their shown state is secret (safeHideWindow
    -- would taint on it) and the park is redundant — hiding the outermost link of a
    -- chain already takes the whole subtree with it.
    if watch and watch._fakeActive and not cfg.parentDrivenVisibility then
        watch._hidden[h] = true
        -- Hover-safe + self-cancelling: if the fake period ends before a deferred
        -- hide lands, the retry sees _hidden cleared and stands down.
        safeHideWindow(h.frame, function() return watch._hidden[h] end)
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

-- IDENTITY-GATE WATCHER: re-evaluate the gate for every vulnerable handle when
-- assistability can flip — faction changes (cross-faction membership + duels),
-- phasing, roster/member-data changes, zoning, and retargets (dynamic-unit
-- handles on target/focus frames). The per-handle check is a couple of API
-- calls and the vulnerable set is small; sweeps coalesce onto a short timer so
-- event bursts (name/roster spam on joins) run once.
-- Field lesson (cross-faction party + /reload): UnitCanAssist can still report
-- the pre-load answer while the world streams in, and in the steady state no
-- watched event fires after it settles — the wrong verdict stuck until a real
-- invite. So member-data events are watched too, and PLAYER_ENTERING_WORLD
-- additionally parks two delayed sweeps to catch the settled value.
local idGateWatch = CreateFrame("Frame")
idGateWatch:RegisterEvent("UNIT_FACTION")
idGateWatch:RegisterEvent("UNIT_PHASE")
idGateWatch:RegisterEvent("UNIT_NAME_UPDATE")      -- member data streaming in post-load
idGateWatch:RegisterEvent("PARTY_MEMBER_ENABLE")   -- member connect/instance-state settle
idGateWatch:RegisterEvent("PARTY_MEMBER_DISABLE")
idGateWatch:RegisterEvent("GROUP_ROSTER_UPDATE")
idGateWatch:RegisterEvent("PLAYER_ENTERING_WORLD")
idGateWatch:RegisterEvent("PLAYER_TARGET_CHANGED")
idGateWatch:RegisterEvent("PLAYER_FOCUS_CHANGED")
-- ★ Vehicle occupancy flips your own assistability. Confirmed by /etrace on a live
-- boarding: none of the events above fire at the moment control is TAKEN — the ones that
-- do (PARTY_MEMBER_ENABLE / UNIT_PHASE / UNIT_FACTION) arrive ~350ms later, at the end of
-- the transition, which is the flash.
idGateWatch:RegisterEvent("UNIT_ENTERING_VEHICLE")
idGateWatch:RegisterEvent("UNIT_ENTERED_VEHICLE")
idGateWatch:RegisterEvent("UNIT_EXITED_VEHICLE")
-- ☠☠ THE GATE READS DEAD AND DISCONNECTED, SO IT MUST HEAR THEM. IdentityUnavailable
-- folds UnitIsDeadOrGhost and UnitIsConnected into the assist verdict, and until these two
-- lines the watcher had no event for either. The consequence was one-way: a unit that died
-- or dropped took the false on whatever unrelated event happened to sweep, and coming back
-- produced NO sweep at all, so _noteGateRecovery never saw the false->true edge and a
-- filtered helpful row stayed empty. Healers reported HoTs missing on some members with the
-- auras verifiably still applied (5.1.3).
-- ☠ PARTY_MEMBER_ENABLE / DISABLE above do NOT cover this. They are party-scoped and do not
-- fire for raid members, which is why the clearest field report was a 40-player raid ("cannot
-- see my riptides on group 5/6/7/8") -- past party size there was no connection signal at all.
-- UNIT_CONNECTION is the group-wide equivalent and UNIT_FLAGS carries the death edge;
-- Blizzard's own CompactUnitFrame registers exactly this pair per unit, and DF already
-- relies on both for pet death detection (Frames/Pets.lua).
idGateWatch:RegisterEvent("UNIT_FLAGS")
idGateWatch:RegisterEvent("UNIT_CONNECTION")
-- ★ Combat exit re-verifies the gate. A park/restore whose ApplyTuning failed IN combat
-- reverts its flag and retries on the next sweep (see _applyIdentityGate) — but that
-- retry needs a sweep to ride, and a post-fight lull can go minutes without one. Regen
-- is the natural edge: it is exactly when every deferred container op flushes, and in
-- a battleground (where trust flips constantly — deaths, releases, rezzes) combat
-- drops often enough to make this the reliable repair lane.
idGateWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
local gateSweepQueued

-- ☠ THIS FILTER MUST MATCH _applyIdentityGate's OWN CONDITION, TERM FOR TERM. It did not:
-- the gate widened to `or self:_hasGatedGroups()` so the debuff row's park verdict could
-- flip, and the sweep that DRIVES the gate was left on the old two-term test. A row that
-- carries gated groups without being hide-vulnerable was therefore never swept, so its
-- park could be set at build and never re-evaluated by any watcher event -- the same
-- "fixed the class in one place, not its sibling" shape the park bug itself had.
-- ⚠ Declared HERE, above SetUnitDeathLatched, because that is its first caller. Below it
-- this reads as a nil GLOBAL: it parses clean, and every call site is inside a pcall, so
-- the failure would have been completely silent. Caught by diffing _ENV reads, not by luac.
-- ☠ NOW TRUE FOR EVERY HANDLE, and it has to be, or the widened gate only ever runs once.
-- This is the SWEEP filter: idGateWatch's events, the death latch and IdentityGateSweep all
-- consult it before calling _applyIdentityGate. While it mirrored the gate's old three-way
-- entry test, a handle that was neither vulnerable nor source-relative nor gated was
-- invisible to every sweep -- so widening the gate itself would have given the debuff row a
-- verdict at build and then never revisited it on a phase change, a zone-in or a rez.
--
-- Cost is a comparison per handle per sweep: _applyIdentityGate is transition-only, so a
-- stable verdict allocates nothing and touches no frame.
local function GateAppliesTo(h)
    return h ~= nil
end

-- ============================================================
-- DEATH LATCH — unit-keyed sweep (#1043)
-- ============================================================
-- Driven from the dead/alive edges in Frames/Update.lua (the dfLastKnownDead
-- transitions). Unit-keyed so every display of that unit latches together —
-- a party frame and a pinned frame for the same unit both show the corpse.
-- Skipped wholesale in test mode: preview units fabricate "dead" status and
-- latching them would blank the preview rows.
-- ☠ WHICH UNITS ARE CURRENTLY LATCHED. The latch used to be pure edge state living only
-- on the handles, and a container built AFTER the death edge had passed came up unlatched
-- with nothing to ever re-latch it: the next SetUnitDeathLatched(unit, true) only fires on
-- a NEW death transition, and the unit is already dead, so that edge never comes again.
--
-- Field shape: reload while a party member is a ghost and their auras all come back --
-- every row, because the latch is the ONLY cover for the ones the identity gate does not
-- reach (a HARMFUL row with no includeSpellIDs reports zero gated groups, so it is neither
-- vulnerable nor gated and never enters the assist branch at all).
--
-- Keyed by unit token, matching the latch's own unit-keyed design, so every display of
-- that unit -- party frame, pinned frame, whatever is built later -- reads the same answer.
AuraContainer._deathLatchedUnits = AuraContainer._deathLatchedUnits or {}

function AuraContainer.SetUnitDeathLatched(unit, on)
    if type(unit) ~= "string" then return end
    if AuraContainer._testMode then return end
    -- Recorded BEFORE the loops so a build racing this call still reads the new answer.
    -- Test mode returns above, so preview units never enter the registry and the build-time
    -- restore stays a no-op there -- same exemption the loops below already have.
    AuraContainer._deathLatchedUnits[unit] = on and true or nil
    -- Transition-driven (dfLastKnownDead edges in Frames/Update.lua), so one line
    -- per real death/rez — the gate log's densest writer in a battleground, and
    -- exactly the edge the missing-HoTs class turned on.
    GateLog("death latch %s unit=%s", on and "ON" or "OFF", unit)
    for h in pairs(AuraContainer._handles or {}) do
        if not h._destroyed and h.config and h.config.unit == unit
            and not h.config.parentDrivenVisibility then
            pcall(function() h:_setDeathLatch(on) end)
        end
    end
    for s in pairs(AuraContainer._slotHandles or {}) do
        if s.owner and s.owner.unit == unit then
            pcall(function() s:_setDeathLatch(on) end)
        end
    end
    -- ☠☠ DEATH IS AN IDENTITY EDGE TOO, AND NOTHING ELSE DELIVERS IT. IdentityUnavailable
    -- folds UnitIsDeadOrGhost / UnitIsConnected into the assist verdict, so a dead unit
    -- makes _applyIdentityGate decide `can = false` -- which PARKS its gated groups and,
    -- for a hide-vulnerable HELPFUL pool, hides the row outright. But idGateWatch registers
    -- only faction / phase / name / roster / target / focus / vehicle events: there is no
    -- death or resurrection event anywhere in that list.
    --
    -- So the gate could take the false while a unit was dead (any roster event during the
    -- death is enough, and in a raid those never stop), and then never re-run on the alive
    -- edge -- _noteGateRecovery never saw the false->true transition, so no re-parse and no
    -- un-hide. The HoTs stayed gone until some unrelated watcher event happened to sweep.
    -- Field shape: "sometimes my hots don't appear on some of my teammates", healer able to
    -- target the player and confirm the HoTs are really there (targeting fires
    -- PLAYER_TARGET_CHANGED, which sweeps -- so the act of checking could fix it and hide
    -- the cause). Reported by several healers on 5.1.3.
    --
    -- The death latch is already driven off the real dead/alive transitions in
    -- Frames/Update.lua and is unit-keyed, so it is exactly the edge the gate was missing.
    -- Re-running the gate for this unit's handles is cheap: two pcall'ed unit probes each,
    -- and only for handles the gate applies to at all.
    for h in pairs(AuraContainer._handles or {}) do
        if not h._destroyed and h.config and h.config.unit == unit and GateAppliesTo(h) then
            pcall(function() h:_applyIdentityGate() end)
        end
    end
    for s in pairs(AuraContainer._slotHandles or {}) do
        if s.owner and s.owner.unit == unit and GateAppliesTo(s) then
            pcall(function() s:_applyIdentityGate() end)
        end
    end
end

local function IdentityGateSweep()
    gateSweepQueued = nil
    for h in pairs(AuraContainer._handles or {}) do
        if GateAppliesTo(h) then
            pcall(function() h:_applyIdentityGate() end)
        end
    end
    -- ⚠ Slots sweep too. They live in their own registry (see AcquireSlot) because this
    -- one is Handle-shaped; forgetting them is exactly how the collapsed AD path ended up
    -- with no gate at all despite every placed config being vulnerable.
    for h in pairs(AuraContainer._slotHandles or {}) do
        if GateAppliesTo(h) then
            pcall(function() h:_applyIdentityGate() end)
        end
    end
end
idGateWatch:SetScript("OnEvent", function(_, event)
    -- ★ TWO LANES. The 0.05s debounce exists for the noisy events — roster, name and
    -- phase updates arrive in bursts and a sweep per event would re-probe every
    -- vulnerable handle each time. Vehicle edges are the opposite: rare, so there is no
    -- storm to coalesce, and the deferral is precisely what reads on screen as a flash of
    -- unfiltered icons on your own frame. So they sweep on the spot.
    -- ⚠ Cinematics deliberately stay OUT of this lane. They are the latch's job
    -- (cineWatch, below) and that path is confirmed working — an immediate sweep here
    -- would be redundant work at best and a second writer racing the latch at worst.
    if event == "UNIT_ENTERING_VEHICLE" or event == "UNIT_ENTERED_VEHICLE"
        or event == "UNIT_EXITED_VEHICLE" then
        IdentityGateSweep()
        return
    end
    if not gateSweepQueued then
        gateSweepQueued = true
        C_Timer.After(0.05, IdentityGateSweep)
    end
    if event == "PLAYER_ENTERING_WORLD" then
        -- One-time scrub: a same-day reverted design (90fc296f) briefly wrote an
        -- always-on gateLog ring into the SV before gate logging moved to the
        -- IDGATE console category. Remove once shipped builds can't have it.
        local sv = _G.DandersFramesDB_v2
        if type(sv) == "table" and sv.gateLog ~= nil then sv.gateLog = nil end
        C_Timer.After(2, IdentityGateSweep)
        C_Timer.After(6, IdentityGateSweep)
    end
end)

-- ★★ THE SAFETY-NET SWEEP — the "never fail to hide, never fail to unhide" backstop
-- (Krathe, 2026-08-18). Every gate bug to date has been a missed EDGE, never a wrong
-- verdict at sweep time: the NPC-offline verdict aside, the pattern is a condition
-- changing with no watched event firing (party-scoped events in a raid, death folded in
-- with no UNIT_FLAGS, a unit crossing an instance boundary). At least one other 12.1
-- implementation reached the same conclusion independently and polls, on the reasoning
-- that neither assist nor visibility has an event of its own. The event list above stays
-- primary — it reacts in one frame —
-- but this ticker guarantees that any edge it misses costs seconds, not a stuck frame
-- until reload.
--
-- Cheap by construction: the sweep is transition-only end to end (verdicts are two
-- pcall'd probes per handle; a stable verdict compares and returns, no frame ops, no
-- allocation), so a quiet tick is ~2 probes x handle count. Combat-safe: hides are plain
-- DF-frame ops, parks that fail in lockdown revert and retry on the regen sweep.
-- ⚠ Do NOT shorten the period to make the gate "snappier" — events are the fast path;
-- this exists only to bound the damage of the next missing one.
C_Timer.NewTicker(5, function()
    if AuraContainer._testMode then return end
    IdentityGateSweep()
end)


-- ============================================================
-- CINEMATIC LATCH — no flash of the fail-open parse
-- ============================================================
-- A cinematic flips UNIT_FACTION, the identity gate fails open, and the engine
-- keeps rendering that unfiltered parse until the recovery bounce re-parses it
-- (see Handle:_noteGateRecovery). The bounce is event-driven, so there was a
-- visible half-second of every-buff icons between the UI coming back and
-- UNIT_FACTION reaching us. The delay is upstream — Blizzard's own event timing
-- plus one parse tick; other addons report the identical residue — so the only
-- lever left is not SHOWING the frames until the re-parse has happened.
--
-- Shape: START latches every vulnerable handle/slot hidden (both events are
-- SynchronousEvent, so the latch lands before the first cinematic frame — and the
-- UI is hidden during playback anyway, so latching costs nothing visible). The
-- recovery edge clears each latch AFTER its bounce, so frames reappear already
-- re-parsed. STOP runs the gate sweep immediately (catching an assist restore
-- that raced ahead of our 50ms coalesce), then clears any handle whose assist
-- never dropped — its parse was never fail-open, nothing to wait for.
--
-- ☠ The fallback timer is NOT optional. Fail-safe direction here is SHOW (a
-- wrongly-hidden row is worse than one garbage frame — the gate's own rule), so
-- whatever is still latched 3s after STOP shows regardless, which degrades to
-- exactly the pre-latch behaviour and never below it. This is also what bounds
-- the mid-combat case, where the slot pushes defer to the regen replay.
--
-- ⚠ Accepted gap: a handle CREATED during a cinematic misses the START arm and
-- can still flash. Rebuilding mid-cinematic is rare enough that wiring
-- InCinematic() into the build path is not worth the coupling.
local cineWatch = CreateFrame("Frame")
cineWatch:RegisterEvent("CINEMATIC_START")
cineWatch:RegisterEvent("CINEMATIC_STOP")
cineWatch:RegisterEvent("PLAY_MOVIE")
cineWatch:RegisterEvent("STOP_MOVIE")
local cineGen = 0
local function CineLatchAll(on)
    for h in pairs(AuraContainer._handles or {}) do
        if not on then
            pcall(function() h:_setCineLatch(nil) end)
        elseif h._idGateVulnerable then
            pcall(function() h:_setCineLatch(true) end)
        end
    end
    -- ⚠ Slots live in their own registry — the gate sweep above records why
    -- forgetting them is how the AD path once had no gate at all.
    for h in pairs(AuraContainer._slotHandles or {}) do
        if not on then
            pcall(function() h:_setCineLatch(nil) end)
        elseif h._idGateVulnerable then
            pcall(function() h:_setCineLatch(true) end)
        end
    end
end
cineWatch:SetScript("OnEvent", function(_, event)
    cineGen = cineGen + 1
    if event == "CINEMATIC_START" or event == "PLAY_MOVIE" then
        -- Test mode shows fake data — nothing to protect, don't touch it.
        -- ☠ The guard sits HERE and not on the whole handler: STOP must always
        -- run, because test mode entered mid-cinematic would otherwise skip both
        -- the clear and the fallback timer while the gate guard suppresses the
        -- recovery edge — a latch stuck until reload.
        if AuraContainer._testMode then return end
        GateLog("cinematic start (%s): latching vulnerable pools", event)
        -- ★ The flag the BUILD paths consult. CineLatchAll only reaches what already
        -- exists; a handle or slot born mid-cinematic must seed its own latch, and this
        -- is how it knows to (see the build/AcquireSlot seeds).
        AuraContainer._cineActive = true
        CineLatchAll(true)
        return
    end
    AuraContainer._cineActive = nil
    -- STOP: fire any pending recovery NOW rather than waiting out the coalesce —
    -- if the engine restored assist before this event, the sweep bounces and
    -- clears those latches in one pass.
    IdentityGateSweep()
    -- A handle whose assist never dropped was never fail-open; show it.
    for h in pairs(AuraContainer._handles or {}) do
        if h._cineLatched and h._idGateAssist ~= false then
            pcall(function() h:_setCineLatch(nil) end)
        end
    end
    for h in pairs(AuraContainer._slotHandles or {}) do
        if h._cineLatched and h._idGateAssist ~= false then
            pcall(function() h:_setCineLatch(nil) end)
        end
    end
    -- Whatever is still latched is waiting on a restore that has not reached us.
    -- Hold — that is the whole point — but never past the fail-safe window.
    local gen = cineGen
    C_Timer.After(3, function()
        if gen == cineGen then
            GateLog("cinematic latch fallback: showing whatever is still held")
            CineLatchAll(false)
        end
    end)
end)

-- /df debug idgate — identity-gate ground truth: EVERY handle (not just the
-- vulnerable ones — an under-flagged handle is exactly the failure this dump
-- must expose), with its unit, vulnerability flag, the LIVE UnitCanAssist
-- answer, the stored gate verdict, and the window's actual visibility
-- (+ whether a hover-deferred flip is parked). Developer diagnostic: plain
-- print by project convention.
-- ☠ EVERY INTERPOLATED VALUE IN THIS DUMP GOES THROUGH THIS. Slot keys and filter
-- strings are built with "|" as their own field separator ("HELPFUL|PLAYER",
-- "PowerInfusion#1ic|||du|bd|fl=40|fs=MEDIUM||pd=BORDER:Fnil|tt="), and "|" is WoW's
-- text-escape character. Printed raw, "|T" opens a texture escape and "|t" closes one,
-- while "|d"/"|b"/"|f" are not escapes at all -- so chat rendered mojibake AND any
-- EditBox handed the line (the usual way anyone gets this text OUT of the game) came up
-- blank, because SetText fails on a malformed escape. The dump was unusable for the one
-- job it exists to do: being pasted into a bug report.
--
-- "||" is the literal-pipe escape, so the text renders and copies as written. Control
-- bytes go to "?" for the same reason -- one stray byte blanks the whole box.
--
-- ⚠ Values ONLY, never the format strings: those carry deliberate |cff.../|r colour
-- codes and escaping them would print the codes instead of colouring the line.
-- ⚠ The parens are load-bearing. gsub returns (string, count); without them the count
-- becomes an extra argument to format and shifts every following field along one.
local function safeTxt(v)
    local s = tostring(v)
    return (s:gsub("|", "||"):gsub("[%z\1-\31]", "?"))
end

function AuraContainer.DebugDumpIdentityGate()
    local o = DF:Out("Identity Gate")
    local CAP = 30
    local n, vuln = 0, 0
    for h in pairs(AuraContainer._handles or {}) do
        n = n + 1
        if h._idGateVulnerable then vuln = vuln + 1 end
        if n <= CAP then
            local cfg = h.config or {}
            local unit = cfg.unit
            local canTxt = "-"
            if type(unit) == "string" and UnitExists(unit) then
                local ok, can = pcall(UnitCanAssist, "player", unit)
                if not ok then canTxt = "ERR"
                elseif issecretvalue and issecretvalue(can) then canTxt = "SECRET"
                else canTxt = tostring(can) end
            end
            -- UnitIsVisible: the source-relative (PLAYER-token) gate's signal.
            local visTxt = "-"
            if type(unit) == "string" and UnitExists(unit) then
                local okv, vis = pcall(UnitIsVisible, unit)
                if not okv then visTxt = "ERR"
                elseif issecretvalue and issecretvalue(vis) then visTxt = "SECRET"
                else visTxt = tostring(vis) end
            end
            -- Filter + cf summary: distinct record filter strings, and whether ANY
            -- record carries an include/exclude spell map — the fields the
            -- vulnerability classification is derived from.
            local fParts, seenF, inc, exc = {}, {}, false, false
            for _, rec in ipairs(normalizeFilters(cfg.filter)) do
                if not seenF[rec.f] then
                    seenF[rec.f] = true
                    fParts[#fParts + 1] = rec.f
                end
                local cf = recordCandidateFilters(rec, cfg)
                if cf and cf.includeSpellIDs then inc = true end
                if cf and cf.excludeSpellIDs then exc = true end
            end
            -- ☠ PARK, LATCHES AND THE RECOVERY EDGE BELONG HERE TOO. This line reported the
            -- HIDE path only, and hide is one of FOUR writers that can blank a row --
            -- _applyVisibility composes gateHidden with the cinematic and death latches, and
            -- the debuff row does not hide at all, it PARKS its gated groups to
            -- maxFrameCount 0. So the "dispel overlay lit with no debuff icon under it" bug
            -- was invisible in the dump built to see exactly that class of fault: the row was
            -- parked, and there was no column for parked. `assist` is the recovery-edge
            -- tracker _noteGateRecovery compares against — it answers the question every one
            -- of these reports turns on, "will this ever un-hide on its own".
            local parkedTxt = tostring(h._idGateParked or false)
            if h._idGateUntrusted then parkedTxt = parkedTxt .. "(untrusted)" end
            local gatedN = 0
            for _ in pairs((h.backend and h.backend.gatedGroupKeys) or {}) do gatedN = gatedN + 1 end
            print(("    " .. DF.OUT.SECTION .. "%d|r mode=%s unit=%s filter=%s inc=%s exc=%s vuln=%s srcRel=%s exists=%s canAssist=%s vis=%s gateHidden=%s parked=%s why=%s gatedGroups=%d cine=%s death=%s assist=%s intent=%s shown=%s retry=%s"):format(
                n, safeTxt(cfg.mode or "row"), safeTxt(unit),
                safeTxt(table.concat(fParts, "&")), tostring(inc), tostring(exc),
                tostring(h._idGateVulnerable or false),
                tostring(h._idGateSourceRelative or false),
                tostring(type(unit) == "string" and UnitExists(unit) or false), canTxt, visTxt,
                tostring(h._idGateHidden or false),
                parkedTxt, tostring(h._idGateWhy or "-"), gatedN,
                tostring(h._cineLatched or false),
                tostring(h._deathLatched or false),
                tostring(h._idGateAssist),
                tostring(h._intendedShown ~= false),
                tostring(h.config and h.config.parentDrivenVisibility and "(nested)"
                    or (h.frame and h.frame:IsShown()) or false),
                tostring(h._visRetry or false)))
        end
    end
    if n > CAP then
        o:Line(("… capped at %d lines"):format(CAP), "NEUTRAL")
    end
    -- ☠ SLOTS SWEEP TOO, AND THIS DUMP DID NOT WALK THEM. They live in their own
    -- registry (see AcquireSlot) because the loop above is Handle-shaped -- the exact
    -- omission that left the collapsed AD path with no gate at all, repeated here in the
    -- tool meant to catch it. Every Aura Designer PLACED indicator is a SlotHandle with
    -- its own _applyIdentityGate and its own _gateHidden, so a dump that reports only
    -- Handles is blind to the half the AD uses -- and the AD is where the stuck-indicator
    -- reports came from.
    local sn, svuln = 0, 0
    for s in pairs(AuraContainer._slotHandles or {}) do
        sn = sn + 1
        if s._idGateVulnerable then svuln = svuln + 1 end
        if sn <= CAP then
            local unit = s.owner and s.owner.unit
            local canTxt = "-"
            if type(unit) == "string" and UnitExists(unit) then
                local ok, can = pcall(UnitCanAssist, "player", unit)
                if not ok then canTxt = "ERR"
                elseif issecretvalue and issecretvalue(can) then canTxt = "SECRET"
                else canTxt = tostring(can) end
            end
            print(("    " .. DF.OUT.SECTION .. "S%d|r key=%s unit=%s vuln=%s srcRel=%s canAssist=%s gateHidden=%s parked=%s why=%s cine=%s death=%s assist=%s live=%s pushed=[%s] pushOK=%s"):format(
                sn, safeTxt(s.key), safeTxt(unit),
                tostring(s._idGateVulnerable or false),
                tostring(s._idGateSourceRelative or false),
                canTxt,
                tostring(s._gateHidden or false),
                tostring(s.parked or false),
                tostring(s._idGateWhy or "-"),
                tostring(s._cineLatched or false),
                tostring(s._deathLatched or false),
                tostring(s._idGateAssist),
                -- ⚠ live= is the INTENDED filter and never changes when the gate hides a
                -- slot. pushed= is the actuation: "" means one of the four writers in
                -- _pushFilter won. pushOK= is whether the setter was refused (lockdown).
                -- A slot reading gateHidden=true with a non-empty pushed= is an actuation
                -- failure; nil pushed= means _pushFilter has not run since load.
                safeTxt(s.liveFilter), safeTxt(s._pushedFilter), tostring(s._pushOK)))
        end
    end
    if sn > CAP then
        o:Line(("… slots capped at %d lines"):format(CAP), "NEUTRAL")
    end
    o:Section("Summary")
    o:Field("handles", n, n > 0 and "GOOD" or "NEUTRAL")
    -- A vulnerable handle is the whole point of this dump, so it is the one
    -- number that must not sit uncoloured in a wall of numbers.
    o:Field("gate-vulnerable", vuln, vuln > 0 and "WARN" or "GOOD")
    o:Field("slots", sn, sn > 0 and "GOOD" or "NEUTRAL")
    o:Field("slots gate-vulnerable", svuln, svuln > 0 and "WARN" or "GOOD")
    -- ★ Global aura secrecy, printed because it frames every line above: it does NOT
    -- switch the identity gate off (CanApplyIdentityCandidateFilters has no such bypass),
    -- but it is the first thing you want to know when a filter behaves unexpectedly.
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local okS, secret = pcall(C_Secrets.ShouldAurasBeSecret)
        o:Field("auras secret", okS and tostring(secret) or "ERR", "NEUTRAL")
    end
    o:Field("test mode", AuraContainer._testMode or false, "NEUTRAL")
    -- ★ The IDGATE trail's tail, pulled from the console log — the dump above is
    -- NOW, the tail is WHAT LED HERE. Only populated while the IDGATE debug
    -- category is enabled (opt-in like every category), so say so when empty
    -- rather than reading as "no transitions happened".
    local dlog = type(_G.DandersFramesDB_v2) == "table" and _G.DandersFramesDB_v2.debugLog
    local tail = {}
    if type(dlog) == "table" then
        for i = #dlog, 1, -1 do
            local e = dlog[i]
            if type(e) == "table" and e[3] == "IDGATE" then
                tail[#tail + 1] = tostring(e[1]) .. "  " .. tostring(e[4])
                if #tail >= 15 then break end
            end
        end
    end
    if #tail > 0 then
        o:Section(("Gate log — last %d IDGATE lines"):format(#tail))
        for i = #tail, 1, -1 do print("    " .. tail[i]) end
    else
        o:Section("Gate log — empty (enable the IDGATE debug category to record transitions)")
    end
    o:Siblings("idgate")
end

-- /df debug ppbadge — diagnostic toggle: park missing badges on the WINDOW instead of
-- the container (see _badgeParkDebug at the build). Border renders perfect =>
-- the empty container's secret fractional self-width is confirmed as the last
-- off-grid source. Rebuilds every missing handle on toggle. NOT a fix: the
-- layout-push can't hide a window-anchored badge, so present buffs still show
-- their badge while this is on.
-- ★ OWN-FRAME PREVIEW toggle (/df debug ownpreview) — the A/B for the new test-mode
-- route. ON (the default): test mode paints our own pooled frames and never touches
-- C_UnitAuras.SwitchAuraDataProvider, so no other addon's containers are disturbed.
-- OFF: the previous engine route, per-slot AuraGroups fed by the global sample
-- provider, kept so the two can be compared side by side on the same settings.
-- Flip it with test mode ON: every test container rebuilds on the spot.
function AuraContainer.ToggleOwnPreview()
    AuraContainer._ownTestPreview = not AuraContainer._ownTestPreview or nil
    local n = 0
    for h in pairs(AuraContainer._handles or {}) do
        if h.builtInTestMode or AuraContainer._testMode then
            n = n + 1
            pcall(function() h:_rebuild() end)
        end
    end
    DF:Say(("Own-frame preview %s — %d test container(s) rebuilt. %s"):format(
        AuraContainer._ownTestPreview and "ON" or "OFF", n,
        AuraContainer._ownTestPreview
            and "Our own frames; the global sample provider is never switched."
            or "Engine route: per-slot groups + the GLOBAL provider switch (other addons will show sample icons)."))
end

function AuraContainer.ToggleBadgeParkDebug()
    AuraContainer._badgeParkDebug = not AuraContainer._badgeParkDebug or nil
    local n = 0
    for h in pairs(AuraContainer._handles or {}) do
        if h.config and h.config.mode == "missing" then
            n = n + 1
            pcall(function() h:_rebuild() end)
        end
    end
    DF:Say(("Badge park %s — %d missing container(s) rebuilt, push is %s while on"):format(
        AuraContainer._badgeParkDebug and "ON" or "OFF", n,
        AuraContainer._badgeParkDebug and "DISABLED (badge stays visible even when the buff is present)" or "restored"))
end

-- /df debug ppdump — pixel-perfect geometry ground truth (the resource-bar lesson:
-- field numbers beat source-theorising for pixel bugs). For each visible row /
-- missing handle: the anchor chain's rects in PHYSICAL pixels with the signed
-- distance to the nearest pixel grid line ("frac", 0.000 = on-grid), effective
-- scales, and the pin snap's last inputs/outcome. Every rect read is pcall'd —
-- SECRET rects print as such instead of erroring.
function AuraContainer.DebugDumpPP()
    local _, physH = GetPhysicalScreenSize()
    local uiEff = UIParent:GetEffectiveScale()
    local o = DF:Out("Pixel Push")
    o:Section("Screen")
    o:Field("physical height", physH, "NEUTRAL")
    o:Field("UIParent scale", ("%.4f"):format(uiEff), "NEUTRAL")
    o:Field("1px", ("%.4f UIParent units"):format((768 / physH) / uiEff), "NEUTRAL")
    local function frac(v, ppu)
        local p = v * ppu
        return p - math.floor(p + 0.5)
    end
    local function row(label, fr)
        if not fr then print("      " .. label .. ": nil") return end
        local ok, l, b, w, h, eff = pcall(function()
            return fr:GetLeft(), fr:GetBottom(), fr:GetWidth(), fr:GetHeight(), fr:GetEffectiveScale()
        end)
        if not ok then print("      " .. label .. ": forbidden (getter threw)") return end
        -- 12.1: rect getters can RETURN secret numbers rather than throw (the
        -- container self-size is secret-derived even in town) — arithmetic or
        -- truthiness on them taints, so detect and report per component instead.
        if issecretvalue then
            local sec = {}
            if issecretvalue(l) then sec[#sec + 1] = "L" end
            if issecretvalue(b) then sec[#sec + 1] = "B" end
            if issecretvalue(w) then sec[#sec + 1] = "W" end
            if issecretvalue(h) then sec[#sec + 1] = "H" end
            if issecretvalue(eff) then sec[#sec + 1] = "eff" end
            if #sec > 0 then
                print(("      %s: SECRET rect components (%s)"):format(label, table.concat(sec, ",")))
                return
            end
        end
        if not (l and b and w and h and eff) then print("      " .. label .. ": no rect (unlaid)") return end
        local ppu = eff * physH / 768
        print(("      %s: eff=%.4f  physW=%.2f physH=%.2f | frac L=%+.3f B=%+.3f R=%+.3f T=%+.3f"):format(
            label, eff, w * ppu, h * ppu,
            frac(l, ppu), frac(b, ppu), frac(l + w, ppu), frac(b + h, ppu)))
    end
    local n = 0
    for h in pairs(AuraContainer._handles or {}) do
        local cfg = h.config
        if cfg and cfg.mode ~= "overlay" and not cfg.parentDrivenVisibility
            and h.frame and h.frame.IsVisible and h.frame:IsVisible() then
            n = n + 1
            if n > 12 then print("  " .. DF.OUT.NEUTRAL .. "… capped at 12 handles|r") break end
            local L = cfg.layout or {}
            print(("  " .. DF.OUT.SECTION .. "%d|r mode=%s unit=%s pp=%s layoutScale=%s anchor=%s quantized=%s"):format(
                n, tostring(cfg.mode), tostring(cfg.unit), tostring(h._pp),
                tostring(L.scale), tostring(L.anchor), tostring(L._ppQuantized)))
            local d = h._ppDbg
            if d then
                print(("      pin: %s -> frame %s  px=%.3f py=%.3f snapResolved=%s"):format(
                    tostring(d.pin), tostring(d.anchor), d.px or 0, d.py or 0, tostring(d.resolved)))
            end
            -- Baked style numbers + the pixel-scale cache they were computed under.
            -- cacheAt != now after a reload = the login builds baked with a stale
            -- cache (UIParent scale settled later) — the "wrong until any toggle"
            -- signature. Values are container-local units, raw as baked.
            local st = cfg.style or {}
            local bs = st.border and st.border.spec
            print(("      baked: cacheAt=%s now=%s | iconInset=%s borderSize=%s qSize=%s"):format(
                tostring(h._ppCacheAt), tostring((DF.GetPixelScale and DF:GetPixelScale()) or "?"),
                tostring(st.icon and st.icon.inset),
                tostring(bs and bs.size or (st.border and "db-path" or "none")),
                tostring(L.size or L.sizeX)))
            if cfg.mode == "missing" and cfg.badge then
                -- spill enters the badge anchor offsets; badge position otherwise
                -- rides the container's SECRET self-size (the layout-push design)
                print(("      missing: badge=%sx%s spill=%s"):format(
                    tostring(cfg.badge.w), tostring(cfg.badge.h), tostring(cfg.badge.spill or 0)))
            end
            row("host  ", h.frame:GetParent())
            row("window", h.frame)
            row("contnr", h.backend and h.backend.container)
            local b1 = (cfg.mode == "missing") and h.badge or (h.buttons and h.buttons[1])
            row((cfg.mode == "missing") and "badge " or "button", b1)
            local bw = b1 and (b1.dfBorder or b1.dfADBorder)
            if bw then
                row("border", bw)
                if bw.top then row("b.top ", bw.top) end
                if bw.left then row("b.left", bw.left) end
            end
        end
    end
    if n == 0 then print("  " .. DF.OUT.NEUTRAL .. "no visible row or missing containers found|r") end
end

function AuraContainer.StylePreviewSlot(slot, config)
    styleButton_regions(slot, config)
end

-- ★ PLACEMENT, PUBLISHED. The Aura Designer's editor canvas renders aura frames on a
-- surface that has no unit and no handle, so it cannot Create a container — but it must
-- still land every frame where the live container would. These two are the whole of the
-- placement contract, and between them they are the ONLY way the canvas is allowed to
-- position anything: it supplies frames and a layout table, and gets live's answer.
--
-- ☠ Defined here, BELOW resolveLayoutPin and flowSlotsIntoBox. A DF:* wrapper written
-- above a `local function` it calls compiles as a nil GLOBAL lookup and dies at runtime
-- with "attempt to call a nil value" — luac -p cannot see it, and it has bitten this
-- file before. If either local moves, these move with it.

-- Pin ONE box (a single-slot indicator, or a group's box) to `anchorFrame` exactly as
-- applyContainerLayout pins a live container: growth-resolved pin point, the CENTER
-- fold, the pixel-perfect nudge, and the layout scale. Returns false only if the write
-- itself threw. `pp` is the host's pixelPerfect setting — callers pass what
-- DF:GetFrameDB(host) says, so the preview obeys the same setting live obeys.
function AuraContainer.PinLayoutBox(box, anchorFrame, layout, pp)
    if not (box and anchorFrame and type(layout) == "table") then return false end
    local pinPoint, anchor, px, py, scale = AuraContainer.ResolveLayoutPin(anchorFrame, layout, pp)
    if not pinPoint then return false end
    return (pcall(function()
        box:SetScale(scale)
        box:ClearAllPoints()
        box:SetPoint(pinPoint, anchorFrame, anchor, px, py)
    end))
end

-- The same answer WITHOUT applying it. Exists so a check can ask "where would live put
-- this?" and compare it against where a frame actually sits — see /df debug adpin, which
-- is what turns a reintroduced copy into a visible failure instead of a user report six
-- weeks later. Read-only by construction: one resolver, two uses, no second maths.
function AuraContainer.ResolveLayoutPin(anchorFrame, layout, pp)
    if not (anchorFrame and type(layout) == "table") then return nil end
    local G, px, py, scale = resolveLayoutPin(layout, anchorFrame, pp)
    return G.pinPoint, G.anchor, px, py, scale
end

-- Flow `count` slot frames inside `box`, pinned to `anchorFrame`, exactly as the live
-- container flows its buttons — same AnchorUtil flow, same growth, same wrap headroom,
-- same strip reservation. Returns false when the flow is unavailable; the caller decides
-- what to do, and MUST NOT substitute maths of its own.
function AuraContainer.FlowSlots(box, anchorFrame, slots, count, config, pp)
    if type(config) ~= "table" then return false end
    return flowSlotsIntoBox(box, anchorFrame, slots, count, config, pp)
end

function AuraContainer.PaintPreviewSlot(slot, config, index, sharedDur)
    -- sharedDur: adopt ANOTHER preview slot's duration object instead of arming a fresh
    -- one, so two slots previewing the same aura count down as a single timer rather than
    -- two that merely started close together. Used by the AD canvas, where the expiry-alert
    -- slot overlays its indicator's slot and has to react to that indicator's countdown —
    -- a reveal that crossed its threshold a frame off from the number beneath it would be
    -- a preview artifact, not something live can do. armTestDuration only creates when the
    -- field is empty, so seeding it here is enough.
    if sharedDur then slot._dfTestDurObj = sharedDur end
    -- Duck-typed handle: the paint core only reads .config (and the duration
    -- formatter inside it).
    Handle._paintTestSlot({ config = config }, slot, index or 1)
end

-- ============================================================
-- TEST MODE: the dispel type a frame's debuff window actually contains
-- ============================================================
-- ☠ THE OVERLAY MUST NAME A DEBUFF THAT IS ON THE FRAME. The frame overlay used to take
-- its type from a hardcoded frame-index pattern in the test data ("i % 5 == 1 -> Magic")
-- while the debuff ICONS came from the curated pool — two sources that were never linked.
-- They agreed by accident while every frame drew pool entries 1-2 (always Magic + Poison),
-- and the per-frame rotation broke the coincidence: a unit showed a Poison overlay with
-- three debuffs, none of them Poison (Krathe, 2026-08-06).
--
-- Reuses testPoolOffset — the SAME function the painter uses to choose entries — rather
-- than recomputing the window here, so the two cannot drift apart. That is the whole
-- point of this living in this file instead of in TestMode.lua.
--
-- Returns the first dispellable type in the unit's window, or nil when the window holds
-- none (which is how the pool's untyped entries set how often an overlay appears at all).
-- ⚠ DISPEL COLOURS THAT VANISH INTO A CLASS COLOUR. The overlay tints the whole frame,
-- so a type whose colour matches the unit's class bar reads as one flat wash — Krathe on
-- Magic (blue) landing on a MAGE (blue): "the blue overlay and class and icon clash."
-- Preview-only cosmetics: the pairing is legal and happens constantly in live play, it
-- just makes a poor demonstration of the feature. Extend when another pair reads badly.
local TEST_DISPEL_CLASH = {
    MAGE    = "Magic",    -- both blue
    WARLOCK = "Curse",    -- both purple
}

function DF:GetTestDebuffDispelType(unitToken, count, class)
    local pool = DF.TestData and DF.TestData.debuffs
    if not (pool and #pool > 0) then return nil end
    local cfg = { unit = unitToken }
    local n = math.max(1, math.min(tonumber(count) or 1, #pool))
    local off = testPoolOffset(cfg, #pool, n)
    -- Collect EVERY dispellable type in the window, not just the first.
    local types
    for i = 1, n do
        local e = pool[((off + i - 1) % #pool) + 1]
        if e and e.debuffType then types = types or {}; types[#types + 1] = e.debuffType end
    end
    if not types then return nil end
    -- ☠ TAKING types[1] HIDES HALF THE PALETTE. At a preview count of 2 the windows are
    -- (1,2) (3,4) (7,8), so a type sitting in an EVEN pool slot is never first and can
    -- never be chosen — Krathe saw only Magic and Curse, because Disease (slot 2) and
    -- Poison (slot 4) were always the second entry of their pair.
    -- Any entry in the window is on the frame, so any of them is a valid answer; pick by
    -- unit so the choice varies frame to frame. Measured at count 2 over party + a full
    -- raid this reaches all five types (Curse 8, Magic 5, Poison 6, Disease 4, Bleed 4);
    -- the Curse skew is the pool's own — it is the one type appearing twice (slots 3
    -- and 8), every other type appears once.
    -- ⚠ ONLY THE COUNT-2 SPREAD IS TUNED. At count 5 the pool splits into just two
    -- windows (1-5 and 6-10), so the reachable palette collapses to Bleed/Curse/Magic and
    -- every frame lights. Same trade-off as the density note on the pool itself: the
    -- overlay is bound to the icons it must agree with, so it inherits the window's shape.
    local u = tostring(unitToken or "")
    local seed = tonumber(u:match("(%d+)$")) or 0
    -- Drop a type that would disappear into this unit's class colour, but only while the
    -- window still offers an alternative: falling through to nil instead would quietly
    -- thin the overlay density that the pool's untyped slots are tuned to produce.
    local clash = class and TEST_DISPEL_CLASH[class]
    if clash and #types > 1 then
        local keep
        for i = 1, #types do
            if types[i] ~= clash then keep = keep or {}; keep[#keep + 1] = types[i] end
        end
        if keep then types = keep end
    end
    return types[(math.floor((seed * 3 + off) / 2) % #types) + 1]
end
