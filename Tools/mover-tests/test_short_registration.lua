local NS = ...
local R = NS.Registry

-- ============================================================
-- SHORT REGISTRATION + AUTO-DETECTED PROTECTED FRAMES (DandersMover/Core.lua, Registry.lua)
-- ------------------------------------------------------------
-- db + dbKey stand in for getPos, onChanged may be left out, and def.secure can be
-- left for the frame to answer. All of it is expansion in front of the same
-- registry, so what is worth pinning is the record's life (seeded from a COPY, live,
-- re-created, reset in place) and that the long form still behaves as it did.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE, so the registry is
-- swapped for an empty one here and everything replaced is restored at the end. The
-- guarded load is for a filtered run of this file alone.
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
local W = NS.Watcher

local saved = {
    elements = R.elements, targets = R.targets, addons = R.addons, queue = R.queue, ready = R.ready,
    proxy = NS.Proxy, session = NS.Session, pending = NS.pending, combat = IN_COMBAT,
    loggedIn = W.loggedIn,
}
R.elements, R.targets, R.addons, R.queue, R.ready = {}, {}, {}, {}, true
NS.Proxy, NS.Session, NS.pending = nil, nil, {}
W.loggedIn = false      -- nothing here is about the watcher: test_watcher.lua owns that
IN_COMBAT = false

-- A frame whose centre follows the SetPoint it is given, the way a real one does.
local function GeoFrame(x, y, w, h, scale)
    local f = FakeFrame(960 + x, 540 + y, w, h, scale)
    f.setPoints = 0
    function f:ClearAllPoints() end
    function f:SetPoint(_, _, _, ox, oy)
        self.setPoints = self.setPoints + 1
        local ratio = self._scale
        self._cx, self._cy = (960 + ox * ratio) / ratio, (540 + oy * ratio) / ratio
    end
    return f
end

local function errorOf(fn)
    local ok, err = pcall(fn)
    return (not ok) and tostring(err) or nil
end

print("-- db + dbKey: the record is seeded from a copy and read live")
do
    local db = {}
    local default = { point = "TOP", x = 5, y = -6,
                      anchor = { target = "A:t", edge = "right", align = "center",
                                 fallback = { target = "A:u", edge = "left", align = "center" } } }
    local def = { title = "bar", frame = GeoFrame(0, 0, 20, 20), db = db, dbKey = "bar", default = default }
    local el = Lib:Register("SR", "bar", def)

    check(el ~= nil, "registers")
    check(def.getPos == nil and def.onChanged == nil and def.db == db, "the caller's def is not changed")
    check(type(db.bar) == "table", "the record is created at registration")
    check(db.bar ~= default, "...as a copy, not the default itself")
    eq(db.bar.point, "TOP", "...of the default's point"); eq(db.bar.x, 5, "...x"); eq(db.bar.y, -6, "...y")
    check(db.bar.anchor ~= default.anchor, "...and the anchor is copied too")
    check(db.bar.anchor.fallback ~= default.anchor.fallback, "...down to its backup")
    eq(db.bar.anchor.fallback.target, "A:u", "...with its backup's target")

    check(R:GetPos(el) == db.bar, "getPos answers the table in db")
    db.bar.x = 123
    eq(R:GetPos(el).x, 123, "...live")
    local swapped = { point = "CENTER", x = 7, y = 7 }
    db.bar = swapped
    check(R:GetPos(el) == swapped, "...even when the consumer replaces it (a profile change)")

    db.bar = nil
    local again = R:GetPos(el)
    check(type(again) == "table" and db.bar == again, "a cleared record is re-created")
    eq(again.x, 5, "...from the default")
    check(not el.recordBroken, "...and is not a broken record")
end

print("-- db + dbKey: keys, saved data and no default")
do
    local db = { [3] = { point = "LEFT", x = 1, y = 2 } }
    local keep = db[3]
    local el = Lib:Register("SR", "num", { frame = GeoFrame(0, 0, 20, 20), db = db, dbKey = 3,
                                           default = { point = "TOP", x = 9, y = 9 } })
    check(db[3] == keep and keep.point == "LEFT", "a saved record is left alone")
    check(R:GetPos(el) == keep, "a number key works")

    local db2 = {}
    local el2 = Lib:Register("SR", "nodefault", { frame = GeoFrame(0, 0, 20, 20), db = db2, dbKey = "k" })
    eq(db2.k.point, "CENTER", "no default: CENTER"); eq(db2.k.x, 0, "...x 0"); eq(db2.k.y, 0, "...y 0")
    db2.k = nil
    eq(R:GetPos(el2).point, "CENTER", "no default: re-created the same way")
end

print("-- reset keeps the table and leaves the default alone")
do
    local db = {}
    local f = GeoFrame(0, 0, 20, 20)
    local default = { point = "CENTER", x = 40, y = 50 }
    Lib:Register("SRR", "bar", { frame = f, db = db, dbKey = "bar", default = default })
    local record = db.bar
    record.x, record.y = 999, 999
    eq(NS:ResetPositions("SRR"), 1, "one element reset")
    check(db.bar == record, "the same table is kept")
    eq(record.x, 40, "x back to the default"); eq(record.y, 50, "y back to the default")
    eq(default.x, 40, "the default is unharmed")
    record.x = 1
    eq(default.x, 40, "...and is not shared with the record")
    eq(f.setPoints, 1, "the default onChanged placed the frame")
end

print("-- refusals")
do
    local frame = GeoFrame(0, 0, 20, 20)
    local db = {}
    local function reg(def) return errorOf(function() Lib:Register("SRE", "x", def) end) end

    local err = reg({ frame = frame, db = db })
    check(err and err:find("DandersMover: db and dbKey must be given together", 1, true), "db without dbKey")
    err = reg({ frame = frame, dbKey = "a" })
    check(err and err:find("DandersMover: db and dbKey must be given together", 1, true), "dbKey without db")
    err = reg({ frame = frame, db = "nope", dbKey = "a" })
    check(err and err:find("DandersMover: db must be a table", 1, true), "db that is not a table")
    err = reg({ frame = frame, db = db, dbKey = {} })
    check(err and err:find("DandersMover: dbKey must be", 1, true), "dbKey that is neither string nor number")
    err = reg({ frame = frame, db = db, dbKey = "a", getPos = function() return {} end })
    check(err and err:find("DandersMover: give either getPos or db + dbKey", 1, true), "getPos together with db")
    err = reg({ db = db, dbKey = "a" })
    check(err and err:find("DandersMover: definition needs frame or getFrame", 1, true), "still needs a frame")
    check(db.a == nil, "a refused def leaves the consumer's db alone")
    check(R:Get("SRE:x") == nil, "nothing was registered")
    err = reg(nil)
    check(err and err:find("DandersMover: definition must be a table", 1, true), "a missing def still says so")
end

print("-- onChanged is optional, long form too")
do
    local pos = { point = "CENTER", x = 30, y = 40 }
    local f = GeoFrame(0, 0, 20, 20)
    Lib:Register("SRC", "framed", { frame = f, getPos = function() return pos end })
    Lib:Apply("SRC", "framed")
    eq(f.setPoints, 1, "with frame: placed")
    eq(f._cx, 990, "...at the record's x"); eq(f._cy, 580, "...and y")

    local scaled = GeoFrame(0, 0, 20, 20, 2)
    Lib:Register("SRC", "scaled", { frame = scaled, getPos = function() return pos end })
    Lib:Apply("SRC", "scaled")
    local rect = R:GetRect(R:GetTarget("SRC:scaled"))
    eq(rect.x, 30, "a scaled frame lands at the record's x in UIParent units")

    local later
    Lib:Register("SRC", "lazy", { getFrame = function() return later end, getPos = function() return pos end })
    local before = T.fail
    Lib:Apply("SRC", "lazy")
    eq(T.fail, before, "getFrame with no frame yet: does nothing")
    later = GeoFrame(0, 0, 20, 20)
    Lib:Apply("SRC", "lazy")
    eq(later.setPoints, 1, "getFrame: placed once there is a frame")

    local calls = 0
    local mine = function() calls = calls + 1 end
    local el = Lib:Register("SRC", "own", { frame = GeoFrame(0, 0, 20, 20), getPos = function() return pos end, onChanged = mine })
    check(el.onChanged == mine, "a given onChanged is used as given")
    Lib:Apply("SRC", "own")
    eq(calls, 1, "...and called")

    local full = { frame = GeoFrame(0, 0, 20, 20), getPos = function() return pos end, onChanged = mine }
    check(R:Register("SRC", "direct", full).onChanged == mine, "Registry takes a full def as it always did")
    local err = errorOf(function() R:Register("SRC", "direct2", { frame = f, getPos = function() return pos end }) end)
    check(err and err:find("element needs onChanged", 1, true), "Registry itself still requires onChanged")
    err = errorOf(function() R:Register("SRC", "direct3", { frame = f, db = {}, dbKey = "a", onChanged = mine }) end)
    check(err and err:find("element needs getPos", 1, true), "...and getPos: only Lib:Register expands")
end

print("-- registered before the registry is ready")
do
    R.ready = false
    local db = {}
    local el = Lib:Register("SRQ", "bar", { frame = GeoFrame(0, 0, 20, 20), db = db, dbKey = "bar",
                                            default = { point = "CENTER", x = 4, y = 4 } })
    check(el == nil, "queued")
    eq(db.bar and db.bar.x, 4, "the record is seeded straight away")
    R:Flush()
    check(R:GetPos(R:Get("SRQ:bar")) == db.bar, "after the flush it reads the same table")
end

print("-- secure stays as given")
do
    local pos = function() return { point = "CENTER", x = 0, y = 0 } end
    local function mk(key, secure, frame)
        return R:Register("SRS", key, { frame = frame or FakeFrame(960, 540, 10, 10), getPos = pos,
                                        onChanged = function() end, secure = secure })
    end
    check(mk("t", true).secure == true, "true is kept")
    check(mk("f", false).secure == false, "false is kept")
    check(mk("n", nil).secure == nil, "nil is kept, not coerced")
end

print("-- IsSecure: explicit wins, otherwise the frame answers")
do
    local pos = function() return { point = "CENTER", x = 0, y = 0 } end
    local protected = FakeFrame(960, 540, 10, 10)
    function protected:IsProtected() return true, false end
    local plain = FakeFrame(960, 540, 10, 10)
    local function mk(key, secure, frame, getFrame)
        return R:Register("SRP", key, { frame = frame, getFrame = getFrame, getPos = pos,
                                        onChanged = function() end, secure = secure })
    end
    eq(R:IsSecure(mk("a", nil, protected)), true, "left out, protected frame: secure")
    eq(R:IsSecure(mk("b", nil, plain)), false, "left out, plain frame: not secure")
    eq(R:IsSecure(mk("c", false, protected)), false, "explicit false beats a protected frame")
    eq(R:IsSecure(mk("d", true, plain)), true, "explicit true beats a plain frame")
    eq(R:IsSecure(mk("e", nil, nil, function() return nil end)), false, "no frame yet: not secure")
    eq(R:IsSecure(mk("f", nil, nil, function() error("boom") end)), false, "a getFrame that throws: not secure")
    eq(R:IsSecure(mk("g", nil, { GetCenter = function() end })), false, "no IsProtected method: not secure")
    eq(R:IsSecure(mk("h", nil, nil, function() return protected end)), true, "getFrame is followed")
end

print("-- a protected frame defers in combat without saying secure")
do
    local protected = GeoFrame(0, 0, 20, 20)
    function protected:IsProtected() return true end
    local plain = GeoFrame(0, 0, 20, 20)
    local pos = { point = "CENTER", x = 11, y = 12 }
    local posPlain = { point = "CENTER", x = 13, y = 14 }
    Lib:Register("SRD", "prot", { frame = protected, getPos = function() return pos end })
    Lib:Register("SRD", "plain", { frame = plain, getPos = function() return posPlain end })

    IN_COMBAT = true
    Lib:Apply("SRD", "prot")
    Lib:Apply("SRD", "plain")
    eq(protected.setPoints, 0, "protected frame: not touched in combat")
    eq(NS.pending["SRD:prot"], "reapply", "...and queued")
    eq(plain.setPoints, 1, "plain frame: moves in combat")
    check(NS.pending["SRD:plain"] == nil, "...and is not queued")

    IN_COMBAT = false
    NS:FlushPending()
    eq(protected.setPoints, 1, "applied when combat ends")
    check(NS.pending["SRD:prot"] == nil, "...and the queue is empty")
end

R.elements, R.targets, R.addons, R.queue, R.ready = saved.elements, saved.targets, saved.addons, saved.queue, saved.ready
NS.Proxy, NS.Session, NS.pending = saved.proxy, saved.session, saved.pending
W.loggedIn = saved.loggedIn
IN_COMBAT = saved.combat
