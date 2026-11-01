-- ============================================================
-- PREVIEW FRAMES' AURA ROWS (Frames/AuraContainer.lua, Features/Auras.lua)
-- A preview frame (frame.dfPreview) only ever shows test data, so its aura handles
-- are in test shape with or without test mode (testShapeFor), and a frame can pick
-- its window of the sample pool with dfTestAuraSeed (testPoolOffset). Party, raid
-- and pinned frames carry neither, so for them both must answer exactly as before.
-- The REAL blocks are lifted out by their source text.
-- ============================================================

local src = df_file_source("Frames/AuraContainer.lua"):gsub("\r\n", "\n")
local auras = df_file_source("Features/Auras.lua"):gsub("\r\n", "\n")

local function lift(text, from, to)
    local s = text:find(from, 1, true)
    local e = s and text:find(to, s, true)
    check(s ~= nil and e ~= nil, "setup: found the block starting " .. from)
    return text:sub(s, e + #to - 1)
end

-- ---- testShapeFor ------------------------------------------------------------
print("-- Preview frames: test shape")
do
    local block = lift(src, "local function testShapeFor(h)", "AuraContainer._testShapeFor = testShapeFor")
    local AC = { _ownTestPreview = true }
    local testShapeFor = assert(loadstring(
        "local AuraContainer = ...\n" .. block .. "\nreturn testShapeFor", "@testShapeFor"))(AC)

    local live, pool, preview = {}, { _testFrame = true }, { _testFrame = true, _previewFrame = true }
    AC._testMode = nil
    eq(testShapeFor(live), false, "outside test mode: a live handle is live")
    eq(testShapeFor(pool), false, "outside test mode: a pooled test frame's handle is live (unchanged)")
    eq(testShapeFor(preview), true, "outside test mode: a preview frame's handle is test-shaped")
    eq(testShapeFor(nil), false, "no handle (the AD canvas's duck-typed paint) answers the global")
    eq(testShapeFor({ config = {} }), false, "...and so does a handle with no flags")
    AC._testMode = true
    eq(testShapeFor(live), true, "in test mode: every handle answers the global, as before")
    eq(testShapeFor(pool), true, "...pooled test frames too")
    eq(testShapeFor(preview), true, "...and preview frames")
    eq(testShapeFor(nil), true, "...and the duck-typed paint")
    AC._testMode = nil
    AC._ownTestPreview = nil
    eq(testShapeFor(preview), false, "engine route (own preview off): a preview frame waits for test mode")
end

-- ---- the handle-level questions all go through it ---------------------------
print("-- Preview frames: the handle-level reads")
do
    check(src:find("self.builtInTestMode = testShapeFor(handle)", 1, true) ~= nil,
        "build: the topology a container is built with is the handle's answer")
    check(src:find("local testMode = testShapeFor(handle)", 1, true) ~= nil,
        "build: the shape branches read the handle's answer")
    check(src:find("if testShapeFor(self) then\n        return testSlotCount(", 1, true) ~= nil,
        "_slotCount: a preview frame's row counts preview slots")
    check(src:find("if testShapeFor(self) then self:_rebuild() end", 1, true) ~= nil,
        "SetTestMax: a preview frame's row rebuilds for the count slider")
    check(src:find("if testShapeFor(self) then\n        self:_rebuild()\n        return", 1, true) ~= nil,
        "ApplyTuning: a preview frame's row rebuilds instead of tuning in place")
    check(src:find("if testShapeFor(self) then return false end", 1, true) ~= nil,
        "_readoptParked: a preview frame's row never re-adopts a parked live container")
    local _, n = src:gsub("not testShapeFor%(handle%)", "")
    eq(n, 2, "the preview timers (re-arm, pandemic window) keep running on a preview frame")
    check(src:find("if ancestor.dfPreview then h._previewFrame = true end", 1, true) ~= nil,
        "Create: a handle on a preview frame is marked once")
    check(src:find("local latched = (not self._previewFrame) and (self._deathLatched or handleVisDark(self))", 1, true) ~= nil,
        "_applyVisibility: a preview frame's rows ignore the live units' latches")
    -- The client-wide gates stay on the global flag: live frames are on screen outside
    -- test mode, and only the preview frame is not.
    check(src:find("C_Timer.NewTicker(SWEEP_INTERVAL, function()\n    syncFlowWatch()\n    samplePoolGrowth()\n    flushFlowLog()\n    if AuraContainer._testMode then return end", 1, true) ~= nil,
        "the safety sweep still keys off test mode")
    check(src:find("function AuraContainer.SetUnitDeathLatched(unit, on)\n    if type(unit) ~= \"string\" then return end\n    if AuraContainer._testMode then return end", 1, true) ~= nil,
        "the death latch registry still keys off test mode")
end

-- ---- testPoolOffset: the seed -----------------------------------------------
print("-- Preview frames: the sample window")
do
    local block = lift(src, "local function gcd(a, b)", "\nlocal Handle = {}")
    local testPoolOffset = assert(loadstring(block .. "\nreturn testPoolOffset", "@testPoolOffset"))()

    -- The rule as it stood before testSeed: the unit token's trailing number.
    local function before(unit, poolSize, count)
        local n = tonumber(unit:match("(%d+)$")) or 0
        local step = math.max(1, count or 1)
        if poolSize % step == 0 and (poolSize / step) >= 2 then
            local slots = poolSize / step
            return (((n * (slots - 1)) + math.floor(n / slots)) % slots) * step
        end
        local a, b = step, poolSize
        while b ~= 0 do a, b = b, a % b end
        if poolSize / a < 4 then step = 7 end
        return (n * step) % poolSize
    end
    local units = { "player", "party1", "party2", "party3", "party4" }
    for i = 1, 40 do units[#units + 1] = "raid" .. i end
    local same = true
    for _, u in ipairs(units) do
        for _, count in ipairs({ 1, 2, 3, 4, 5 }) do
            if testPoolOffset({ unit = u }, 10, count) ~= before(u, 10, count) then same = false end
            if testPoolOffset({ unit = u }, 5, count) ~= before(u, 5, count) then same = false end
        end
    end
    check(same, "party and raid windows are unchanged (no testSeed)")

    eq(testPoolOffset({ unit = "target" }, 10, 2), 0, "a token with no number draws the first window")
    eq(testPoolOffset({ unit = "target", testSeed = 2 }, 10, 2), before("x2", 10, 2),
        "testSeed stands in for the token's number")
    check(testPoolOffset({ unit = "target", testSeed = 1 }, 10, 2) ~= testPoolOffset({ unit = "target" }, 10, 2),
        "...so two frames on number-less tokens can draw different windows")
    eq(testPoolOffset({ unit = "boss3", testSeed = 1 }, 10, 2), before("x1", 10, 2), "the seed wins over the token")
    eq(testPoolOffset({ unit = "target", testSeed = 4, testEntries = {} }, 10, 2), 0,
        "an Aura Designer indicator's own spells never rotate, seed or not")
end

-- ---- the drives pass the frame's seed ----------------------------------------
print("-- Preview frames: the drives carry the seed")
do
    check(auras:find("testSeed = opts.testSeed,", 1, true) ~= nil, "BuildAuraRowConfig: the seed rides the row config")
    local _, n = auras:gsub("testSeed = frame%.dfTestAuraSeed,", "")
    eq(n, 4, "buff and debuff drives pass the frame's seed (create and rebuild)")
end

-- ---- a frame's own row placement (frame.dfAuraRowPlacement) ------------------
print("-- Aura rows: a frame's own row placement")
do
    local s0 = auras:find("local function rowPlacement(frame, db, prefix)", 1, true)
    check(s0 ~= nil, "setup: found rowPlacement")
    local block = auras:sub(s0)
    block = block:sub(1, block:find("\nend\n", 1, true) + 4)
    local rowPlacement = assert(loadstring(block .. "\nreturn rowPlacement", "@rowPlacement"))()

    local db = { buffAnchor = "TOPLEFT", buffGrowth = "RIGHT_UP" }
    eq(select("#", rowPlacement({}, db, "buff")), 3, "three answers")
    local x, y, p = rowPlacement({}, db, "buff")
    eq(x .. "," .. y .. "," .. tostring(p), "0,0,nil", "a frame with no hook (party, raid, pinned): 0, 0, nil")
    x, y, p = rowPlacement(nil, db, "buff")
    eq(x .. "," .. y .. "," .. tostring(p), "0,0,nil", "no frame: 0, 0, nil")
    local seen
    local f = { dfAuraRowPlacement = function(frame, d, prefix, anchor, growth)
        seen = { frame = frame, db = d, prefix = prefix, anchor = anchor, growth = growth }
        return 3, -21, "BOTTOMLEFT"
    end }
    x, y, p = rowPlacement(f, db, "buff")
    eq(x .. "," .. y .. "," .. p, "3,-21,BOTTOMLEFT", "a hook's answer")
    check(seen and seen.frame == f and seen.db == db and seen.prefix == "buff", "...asked with the frame, its table and the row")
    eq(seen.anchor .. " " .. seen.growth, "TOPLEFT RIGHT_UP", "...and the row's anchor and growth")
    rowPlacement(f, {}, "debuff")
    eq(seen.anchor .. " " .. seen.growth, "BOTTOMRIGHT LEFT_UP", "...the row's defaults when it has none")
    f.dfAuraRowPlacement = function() return 1, 2 end
    x, y, p = rowPlacement(f, db, "buff")
    eq(x .. "," .. y .. "," .. tostring(p), "1,2,nil", "a hook with no row corner: nil (the anchor)")
    f.dfAuraRowPlacement = function() error("boom") end
    x, y, p = rowPlacement(f, db, "buff")
    eq(x .. "," .. y .. "," .. tostring(p), "0,0,nil", "a hook that errors: the row is drawn as configured")
    f.dfAuraRowPlacement = function() return nil, "x", 7 end
    x, y, p = rowPlacement(f, db, "buff")
    eq(x .. "," .. y .. "," .. tostring(p), "0,0,nil", "a hook that answers nonsense: 0, 0, nil")

    check(auras:find('offsetX  = (g("OffsetX") or 0) + (tonumber(opts.extraOffsetX) or 0) / rowScale,', 1, true) ~= nil,
        "BuildAuraRowConfig: the extra offset is added, in the row's scaled space (x)")
    check(auras:find('offsetY  = (g("OffsetY") or 0) + (tonumber(opts.extraOffsetY) or 0) / rowScale,', 1, true) ~= nil,
        "...(y)")
    check(auras:find("rowPoint = opts.rowPoint,", 1, true) ~= nil, "...and the row corner rides the layout")
    check(auras:find("local rowScale = tonumber(g(\"Scale\")) or 1\n    if rowScale <= 0 then rowScale = 1 end", 1, true) ~= nil,
        "...a row scale of 0 or nothing counts as 1")
    local _, n = auras:gsub("extraOffsetX = extraX, extraOffsetY = extraY, rowPoint = rowPoint,", "")
    eq(n, 4, "buff and debuff drives pass the frame's placement (create and rebuild)")
    local _, m = auras:gsub("local extraMoved = frame%.dfAuraRowPlacement ~= nil", "")
    eq(m, 2, "...and re-apply a row whose placement moved, only on a frame with the hook")
    check(auras:find("if frame.dfBuffFactoryVersion ~= ver or extraMoved or purgeMoved then", 1, true) ~= nil, "buff drive: the re-apply gate")
    check(auras:find("if frame.dfDebuffFactoryVersion ~= ver or selfMoved or extraMoved then", 1, true) ~= nil, "debuff drive: the re-apply gate")
end

-- ---- layout.rowPoint: the row's own corner on the anchor -----------------------
print("-- Aura rows: a row's own corner (layout.rowPoint)")
do
    local s1 = src:find("local FLOW_NAME = {", 1, true)
    check(s1 ~= nil, "setup: found FLOW_NAME")
    local block = src:sub(s1)
    block = block:sub(1, block:find("\n-- STRIP RESERVATION", 1, true))
    local resolve = assert(loadstring("local DF = ...\n" .. block .. "\nreturn resolveGrowthLayout",
        "@resolveGrowthLayout"))({})
    local function G(anchor, growth, rowPoint)
        return resolve({ size = 22, spacingX = 1, spacingY = 1, anchor = anchor, growth = growth, rowPoint = rowPoint })
    end
    -- Default: unchanged -- the row's corner IS the anchor (every party/raid/AD row).
    for _, c in ipairs({ { "BOTTOMRIGHT", "LEFT_UP" }, { "BOTTOMLEFT", "RIGHT_UP" }, { "TOPLEFT", "RIGHT_DOWN" },
                         { "TOPRIGHT", "DOWN_LEFT" }, { "CENTER", "RIGHT_DOWN" } }) do
        local g = G(c[1], c[2])
        eq(g.pinPoint .. "/" .. g.flowAnchor .. "/" .. g.anchor, c[1] .. "/" .. c[1] .. "/" .. c[1],
            "no rowPoint (" .. c[1] .. " " .. c[2] .. "): pinned and flowing from the anchor")
    end
    -- Named: the row's corner and the flow corner follow it; the FRAME point stays the anchor.
    local g = G("BOTTOMLEFT", "RIGHT_DOWN", "TOPLEFT")
    eq(g.pinPoint .. "/" .. g.flowAnchor .. "/" .. g.anchor, "TOPLEFT/TOPLEFT/BOTTOMLEFT",
        "a row under the frame: its TOPLEFT on the frame's BOTTOMLEFT, flowing from its top")
    eq(g.hName .. "/" .. g.vName, "Right/Down", "...the growth is unchanged")
    g = G("TOPLEFT", "RIGHT_UP", "BOTTOMLEFT")
    eq(g.pinPoint .. "/" .. g.anchor, "BOTTOMLEFT/TOPLEFT", "a row above the frame: its BOTTOMLEFT on the frame's TOPLEFT")
    g = G("TOPLEFT", "LEFT_DOWN", "TOPRIGHT")
    eq(g.pinPoint .. "/" .. g.flowAnchor .. "/" .. g.anchor, "TOPRIGHT/TOPRIGHT/TOPLEFT",
        "a row left of the frame: its TOPRIGHT on the frame's TOPLEFT")
    -- Ignored where it cannot apply.
    g = G("BOTTOM", "RIGHT_DOWN", "TOP")
    eq(g.pinPoint, "BOTTOM", "an edge midpoint is not a row corner: ignored")
    g = G("BOTTOMLEFT", "RIGHT_DOWN", "NONSENSE")
    eq(g.pinPoint, "BOTTOMLEFT", "nonsense: ignored")
    g = G("BOTTOMLEFT", "CENTER_DOWN", "TOPLEFT")
    eq(g.pinPoint, "TOP", "a CENTER row keeps its centre-of-edge pin")
    -- The other two places a row is placed from its settings follow the same corner.
    check(src:find('local point = (ROW_POINTS[L.rowPoint] and growth:sub(1, 6) ~= "CENTER") and L.rowPoint or anchor', 1, true) ~= nil,
        "layoutRow (the fallback maths) pins each button by the same corner")
    check(src:find("b:SetPoint(point, parent, anchor, x, y)", 1, true) ~= nil, "...on the frame's anchor point")
    check(src:find("tip:SetPoint(G.pinPoint, self.frame, G.anchor, x, y)", 1, true) ~= nil,
        "the preview's hover zones too")
end
