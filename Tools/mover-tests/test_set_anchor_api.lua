local NS = ...
local R = NS.Registry

-- ============================================================
-- SCRIPTED ANCHORS -- Lib:SetAnchor / Lib:Detach (Core.lua, Session:SetAnchor)
-- ------------------------------------------------------------
-- A consumer's own settings ("attach X to Y", "reset to attached") set or clear
-- an element's anchor without the editor. Outside a session the record is
-- written and onChanged fires with "anchor" / "detach"; inside a live session the
-- change is one undo step that Undo and Discard put back. A loop is refused by
-- the editor's own cycle check.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. Core.lua loads once
-- (test_registry_events owns that); the guarded load below is for a filtered run.
-- Everything replaced here is restored at the end.
-- ============================================================
local savedCreateFrame = CreateFrame
if not LibStub("DandersMover-1.0", true) then
    local function stubFrame()
        local f = { _scripts = {} }
        function f:SetScript(name, fn) self._scripts[name] = fn end
        function f:GetScript(name) return self._scripts[name] end
        return setmetatable(f, { __index = function() return function() end end })
    end
    CreateFrame = function() return stubFrame() end
    SlashCmdList = SlashCmdList or {}
    local uiLib = LibStub:NewLibrary("DandersUI-1.0", 1)
    if uiLib then uiLib.NewHost = function() return stubFrame() end end
    load_addon_file("Core.lua")
    CreateFrame = savedCreateFrame
end

local Lib = LibStub("DandersMover-1.0", true)
check(Lib ~= nil, "setup: the library object is available")
check(type(Lib.SetAnchor) == "function" and type(Lib.Detach) == "function", "setup: SetAnchor / Detach are public")
local src = mover_file_source("Core.lua"):gsub("\r\n", "\n")
check(src:find('local MAJOR, MINOR = "DandersMover%-1%.0", 7'), "the lib's MINOR is 7")

local wasReady = R.ready
R.ready = true
local prevDb = NS.db
NS.db = NS.db or { showHiddenMovers = true, snapToFrames = true, addons = {} }
-- Session.lua captures Proxy and Grid at load, so the stubs are in place for the
-- whole file and the real modules (if an earlier suite loaded them) come back after.
local prevProxy, prevGrid = NS.Proxy, NS.Grid
NS.Proxy = { dragZones = {}, RefreshAll = function() end, Highlight = function() end,
             Refresh = function() end, ShowToast = function() end, SyncMany = function() end,
             DismissAll = function() end }
NS.Grid = { Hide = function() end }
local prevSession = NS.Session
NS.Session = nil

local notified = {}
local tgtFrame = FakeFrame(1160, 540, 100, 40)        -- centre (200, 0) in UIParent units
local posA = { point = "CENTER", x = 0, y = 0 }
local posB = { point = "CENTER", x = -300, y = 0 }
R:RegisterAddon("SA", { title = "SA" })
R:RegisterAnchorTarget("SA", "tgt", { title = "t", frame = tgtFrame })
-- a's rect follows its record, so what is anchored to a sees it move.
local elA = R:Register("SA", "a", { title = "a", frame = FakeFrame(960, 540, 60, 30),
    getSize = function() return 60, 30 end, getPos = function() return posA end,
    getRect = function() return { x = posA.x, y = posA.y, w = 60, h = 30 } end,
    onChanged = function(p, reason) notified[#notified + 1] = { key = "a", reason = reason } end })
local elB = R:Register("SA", "b", { title = "b", frame = FakeFrame(660, 540, 60, 30),
    getSize = function() return 60, 30 end, getPos = function() return posB end,
    onChanged = function(p, reason) notified[#notified + 1] = { key = "b", reason = reason } end })

print("-- outside a session: the record is written and the consumer told")
local spec = { target = "SA:tgt", edge = "right", align = "center" }
check(Lib:SetAnchor("SA", "a", spec) == true, "SetAnchor: true")
check(posA.anchor ~= nil and posA.anchor.target == "SA:tgt", "SetAnchor: the record carries the anchor")
check(posA.anchor ~= spec, "SetAnchor: the spec is copied, not kept")
eq(posA.anchor.offsetX, 0, "SetAnchor: missing offsets default to 0")
eq(posA.x, 200 + 50 + NS.Solver.SPACING + 30, "SetAnchor: solved against the target (right edge)")
eq(notified[#notified] and notified[#notified].reason, "anchor", "SetAnchor: onChanged(pos, \"anchor\")")

print("-- a chain re-solves its dependants")
wipe(notified)
check(Lib:SetAnchor("SA", "b", { target = "SA:a", edge = "right", align = "center" }), "b anchors to a")
check(Lib:SetAnchor("SA", "a", { target = "SA:tgt", edge = "left", align = "center" }), "a moves to the target's left")
local sawB = false
for _, n in ipairs(notified) do if n.key == "b" and n.reason == "parent" then sawB = true end end
check(sawB, "the element anchored to a re-solves with reason parent")

print("-- refusals change nothing")
local before = posA.anchor
eq(Lib:SetAnchor("SA", "a", { target = "SA:b" }), false, "a loop (a -> b -> a) is refused")
check(posA.anchor == before, "...and the record is untouched")
eq(Lib:SetAnchor("SA", "a", { target = "SA:tgt", fallback = { target = "SA:b" } }), false,
   "a loop through the backup is refused too")
eq(Lib:SetAnchor("SA", "a", { edge = "left" }), false, "no target: refused")
eq(Lib:SetAnchor("SA", "nope", spec), false, "an unregistered element: false")
eq(Lib:Detach("SA", "nope"), false, "Detach of an unregistered element: false")

print("-- Detach frees the element where it sits")
wipe(notified)
check(Lib:SetAnchor("SA", "b", nil) == true, "SetAnchor(nil) detaches")
check(posB.anchor == nil, "the anchor is gone")
eq(notified[1] and notified[1].reason, "detach", "onChanged(pos, \"detach\")")
local bx = posB.x
check(Lib:Detach("SA", "b") == true, "Detach of a free element is a quiet true")
eq(posB.x, bx, "...and moves nothing")

print("-- inside a live session: one undo step, and Discard puts it back")
local prevTimer = C_Timer
C_Timer = { After = function() end }
load_addon_file("Session.lua")
C_Timer = prevTimer
local Sess = NS.Session
Sess.undo = LibStub("DandersUndo-1.0"):New({ limit = 10 })
Sess.EnableKeyboard = function() end   -- the keyboard capture needs a real unlock frame
Sess.active, Sess.suspended, Sess.filter = true, false, nil
Sess.snapshots = { ["SA:a"] = NS.CopyPos(posA), ["SA:b"] = NS.CopyPos(posB) }
check(not Sess.undo:CanUndo(), "session: nothing to undo yet")
check(Lib:Detach("SA", "a") == true, "session: Detach")
check(posA.anchor == nil, "session: detached")
check(Sess.undo:CanUndo(), "session: ...as an undo step")
Sess:Undo()
check(posA.anchor ~= nil and posA.anchor.target == "SA:tgt", "session: Undo restores the anchor")
check(Lib:SetAnchor("SA", "b", { target = "SA:tgt", edge = "bottom", align = "center" }) == true, "session: SetAnchor")
check(posB.anchor ~= nil and posB.anchor.edge == "bottom", "session: anchored")
check(Sess.dirty, "session: the change makes the session dirty")
eq(Lib:SetAnchor("SA", "a", { target = "SA:a" }), false, "session: a loop (itself) is still refused")
Sess:Undo()
check(posB.anchor == nil, "session: Undo frees it again")
Sess:Redo()
check(posB.anchor ~= nil and posB.anchor.edge == "bottom", "session: Redo re-anchors")
Sess:Finish("discard")
check(posB.anchor == nil, "session: Discard puts the record back as it was at Unlock")
eq(posB.x, bx, "session: ...position included")

print("-- a suspended session (combat) takes the direct path")
Sess.active, Sess.suspended = true, true
Sess.undo = LibStub("DandersUndo-1.0"):New({ limit = 10 })
check(Lib:SetAnchor("SA", "b", { target = "SA:tgt", edge = "top", align = "center" }), "suspended: SetAnchor")
check(not Sess.undo:CanUndo(), "suspended: no undo step")
check(posB.anchor ~= nil and posB.anchor.edge == "top", "suspended: written directly")

Sess.active, Sess.suspended = false, false
Sess.undo = nil
NS.Session = prevSession
NS.Proxy, NS.Grid = prevProxy, prevGrid
R:UnregisterAddon("SA")
R.ready = wasReady
NS.db = prevDb
