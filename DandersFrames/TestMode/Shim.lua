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
