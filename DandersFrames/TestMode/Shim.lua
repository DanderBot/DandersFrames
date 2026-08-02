local addonName, DF = ...

-- ============================================================
-- TEST MODE SHIM — always loaded
-- ============================================================
-- Test mode is a settings-panel feature, so it belongs in the load-on-demand
-- payload. It cannot simply leave, though: live rendering calls into it. A
-- sweep of resident code (docs/reorg-tools/lod_gate_check.py) found 31 call
-- sites across Frames/Bars, Create, Init, StatusIcons and Core -- 16 of them
-- DF:GetTestUnitData, sitting inline in the live render path.
--
-- Nearly all of those are unreachable while test mode is off, so in practice
-- they would never fire. "In practice" is not good enough for a nil call: the
-- two crashes after the file splits were both a call into something that had
-- not loaded, and both were invisible to every static check. This file removes
-- the class of failure rather than relying on control flow to avoid it.
--
-- Each stub is the honest inactive answer, not a fake:
--   GetTestUnitData -> nil, meaning "no test data for this unit". Every caller
--     already handles that (`if testData then`), because it is the same answer
--     the real function gives for an index with no test unit.
--   everything else -> a no-op. All are void; their returns are early exits.
--
-- ☠ ORDERING: this file must load BEFORE the real TestMode.lua, which then
-- overwrites every stub. The `if not` guards make that safe rather than
-- assumed -- if the order were ever inverted, a plain assignment would clobber
-- the real implementations with no-ops and test mode would silently do
-- nothing, which is exactly the kind of quiet failure this file exists to stop.

-- Written out one by one rather than looped over a name list. A loop is
-- shorter, but it makes the stubbed surface invisible to grep and to tooling:
-- lod_gate_check.py could not see `DF[name] = noop` and went on reporting nine
-- of these as unguarded. An API surface should be readable without running
-- anything.

local function noop() end

-- Returns the test unit's data table, or nil when there is none. Every caller
-- already handles nil -- it is the same answer the real function gives for an
-- index with no test unit behind it.
if not DF.GetTestUnitData        then DF.GetTestUnitData        = function() return nil end end

if not DF.ShowTestFrames         then DF.ShowTestFrames         = noop end
if not DF.ShowRaidTestFrames     then DF.ShowRaidTestFrames     = noop end
if not DF.HideTestFrames         then DF.HideTestFrames         = noop end
if not DF.RefreshTestFrames      then DF.RefreshTestFrames      = noop end
if not DF.UpdateTestFrame        then DF.UpdateTestFrame        = noop end
if not DF.UpdateTestStatusIcons  then DF.UpdateTestStatusIcons  = noop end
if not DF.UpdateRaidTestFrames   then DF.UpdateRaidTestFrames   = noop end
if not DF.HideRaidTestFrames     then DF.HideRaidTestFrames     = noop end
if not DF.StopTestAnimation      then DF.StopTestAnimation      = noop end
if not DF.TeardownTestModeEngines then DF.TeardownTestModeEngines = noop end

-- ============================================================
-- TEST MODE OWNERSHIP — who is asking for the preview
-- ============================================================
-- TWO independent things want test frames on screen: the USER (the test panel,
-- /df test, the toolbar) and UNLOCK (which needs frames to have something to
-- drag). A single boolean cannot tell them apart, and that was the whole bug:
--
--   * Unlock SNAPSHOTTED DF.testMode and lock trusted the snapshot
--     (partyTestModeBeforeUnlock / raidTestModeBeforeUnlock). Anything that
--     changed test mode DURING the unlock session left it stale, and it failed
--     in both directions -- field-reported, both orders:
--       stale TRUE  -> lock keeps a preview the user had turned off (stuck on)
--       stale FALSE -> lock kills a preview the user had turned on
--   * The "Cannot disable test mode while frames are unlocked" error existed
--     only to stop the snapshot going stale. It papered over the model, and it
--     did not even cover the toolbar button, which closes the PANEL without
--     going through ToggleTestMode at all -- that was the reported repro.
--
-- Ownership says it directly: frames show while ANY owner wants them. Lock
-- releases the unlock claim; if the user still wants a preview, it stays.
--
-- ☠ Show*/Hide*TestFrames stay the ONLY mechanism that moves frames -- these
-- helpers just decide WHEN to call them. Everything downstream that follows
-- test mode (PinnedFrames' testModeActive and its mover chrome, the aura
-- containers, the animation driver) hangs off those two, so it keeps working
-- without knowing ownership exists.
DF._testOwners = DF._testOwners or { party = {}, raid = {} }

local function testScope(scope)
    return (scope == "raid") and "raid" or "party"
end

-- Is a preview actually on screen right now?
function DF:IsTestModeActive(scope)
    if testScope(scope) == "raid" then return DF.raidTestMode and true or false end
    return DF.testMode and true or false
end

-- Does anyone still want one?
function DF:IsTestModeWanted(scope)
    for _, wanted in pairs(DF._testOwners[testScope(scope)]) do
        if wanted then return true end
    end
    return false
end

-- Does one specific owner hold a claim? The test panel's toggle asks this about
-- "user": it is the USER's switch, so it must show the user's own claim rather
-- than whether a preview happens to be on screen. Those differ while unlocked --
-- unlock holds its own claim -- and showing the preview state there made clicking
-- the toggle look like it did nothing.
function DF:IsTestModeOwnedBy(scope, owner)
    return DF._testOwners[testScope(scope)][owner] and true or false
end

-- Claim or release `owner` ("user" | "unlock"), then settle.
-- `silent` suppresses the "Test mode enabled/disabled" chat line: pass it when the
-- change is a SIDE EFFECT of something the user already sees (unlock/lock announce
-- themselves), and omit it when the user asked for test mode directly.
function DF:SetTestModeOwner(scope, owner, wanted, silent)
    scope = testScope(scope)
    local had = DF._testOwners[scope][owner]
    DF._testOwners[scope][owner] = wanted and true or nil
    DF:ReconcileTestMode(scope, silent)

    -- ☠ Explain the one outcome that otherwise reads as a broken click: the user
    -- turned the preview off and the frames stayed, because unlock still needs
    -- them. It lives HERE rather than in ToggleTestMode so every route says it --
    -- the panel's toggle, the toolbar button (which releases via the panel's
    -- OnHide and never touches ToggleTestMode), /df test and the mover action. It
    -- was in ToggleTestMode first and the toolbar route silently skipped it.
    if owner == "user" and had and not wanted and not silent
       and DF:IsTestModeActive(scope) and DF.Say and DF.L then
        DF:Say(DF.L["Test frames stay visible while frames are unlocked - they will hide when you lock."])
    end
end

-- Bring the screen in line with what the owners want. Idempotent, so it is safe
-- to call from anywhere; a no-op when they already agree.
function DF:ReconcileTestMode(scope, silent)
    scope = testScope(scope)
    local wanted, active = DF:IsTestModeWanted(scope), DF:IsTestModeActive(scope)
    if wanted == active then return end
    if scope == "raid" then
        if wanted then DF:ShowRaidTestFrames(silent) else DF:HideRaidTestFrames(silent) end
    else
        if wanted then DF:ShowTestFrames(silent) else DF:HideTestFrames(silent) end
    end
    -- Show* refuses in combat, so `active` may still disagree afterwards; the
    -- next reconcile picks that up rather than us pretending it succeeded.
    if DF.GUI and DF.GUI.UpdateTestButtonState then DF.GUI.UpdateTestButtonState() end
end

-- For paths that hide test frames DIRECTLY (mode switches, the Click Casting
-- tab): drop every claim, so no owner can outlive the frames it asked for.
function DF:ClearTestModeOwners(scope)
    wipe(DF._testOwners[testScope(scope)])
end
