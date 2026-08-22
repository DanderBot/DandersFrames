local NS = ...
local R = NS.Registry
NS.db = nil

local function elDef(frame, pos, extra)
    local d = { title = "x", frame = frame, getPos = function() return pos end, onChanged = function() end }
    if extra then for k, v in pairs(extra) do d[k] = v end end
    return d
end

-- queue before ready, flush after
do
    R:RegisterAddon("A", { title = "Addon A" })
    local pos = { point = "CENTER", x = 0, y = 0 }
    R:Register("A", "one", elDef(FakeFrame(960, 540, 100, 40), pos))
    check(R:Get("A:one") == nil, "queued until Flush")
    R:Flush()
    check(R:Get("A:one") ~= nil, "available after Flush")
    check(R:GetTarget("A:one") and R:GetTarget("A:one").element == R:Get("A:one"), "element is also a target")
    R:Register("A", "two", elDef(FakeFrame(0, 0, 10, 10), { point = "CENTER", x = 0, y = 0 }))
    check(R:Get("A:two") ~= nil, "registers immediately once ready")
end

-- validation
do
    local ok = pcall(R.Register, R, "A", "bad", { title = "no callbacks" })
    check(not ok, "missing getPos/onChanged rejected")
    local ok2 = pcall(R.Register, R, "A", "bad2", { getPos = function() end, onChanged = function() end })
    check(not ok2, "missing frame/getFrame rejected")
end

-- rect in UIParent-center units, scale corrected
do
    local el = R:Get("A:one")
    local rect = R:GetRect(el)
    eq(rect.x, 0, "centre frame x=0"); eq(rect.y, 0, "centre frame y=0")
    eq(rect.w, 100, "w"); eq(rect.h, 40, "h")
    local scaled = R:Register("A", "scaled", elDef(FakeFrame(1000, 500, 50, 20, 0.5), { point = "CENTER", x = 0, y = 0 }))
    local r2 = R:GetRect(scaled)
    eq(r2.x, 500 - 960, "scaled centre x converted"); eq(r2.w, 25, "scaled width converted")
    local sw, sh = R:GetSize(scaled)
    eq(sw, 25, "GetSize is scaled too"); eq(sh, 10, "GetSize height scaled")
    local sized = R:Register("A", "sized", elDef(FakeFrame(960, 540, 1, 1), { point = "CENTER", x = 0, y = 0 }, { getSize = function() return 200, 80 end }))
    local r3 = R:GetRect(sized)
    eq(r3.w, 200, "getSize overrides frame size")
    local dyn = R:RegisterAnchorTarget("A", "dyn", { title = "dyn", getFrame = function() return nil end })
    check(R:GetRect(dyn) == nil, "nil frame -> nil rect")
end

-- getRect override: the visible rect wins over the frame's own geometry
do
    local visible = R:Register("A", "visible", elDef(FakeFrame(0, 0, 10, 10), { point = "CENTER", x = 0, y = 0 },
        { getRect = function() return { x = 10, y = 20, w = 300, h = 50 } end }))
    local rect = R:GetRect(visible)
    eq(rect.x, 10, "getRect x"); eq(rect.y, 20, "getRect y")
    eq(rect.w, 300, "getRect w"); eq(rect.h, 50, "getRect h")
    local w, h = R:GetSize(visible)
    eq(w, 300, "GetSize from getRect w"); eq(h, 50, "GetSize from getRect h")
    local blank = R:RegisterAnchorTarget("A", "blank", { title = "blank", frame = FakeFrame(0, 0, 10, 10),
        getRect = function() return nil end })
    check(R:GetRect(blank) == nil, "getRect nil -> nil rect")
    local ok = pcall(R.Register, R, "A", "badrect", elDef(FakeFrame(0, 0, 10, 10), { point = "CENTER", x = 0, y = 0 },
        { getRect = "not a function" }))
    check(not ok, "non-function getRect rejected")
end

-- graph
do
    local posB = { point = "CENTER", x = 0, y = 0, anchor = { target = "A:one", edge = "right", align = "start" } }
    local posC = { point = "CENTER", x = 0, y = 0, anchor = { target = "A:b", edge = "bottom", align = "center" } }
    R:Register("A", "b", elDef(FakeFrame(0, 0, 10, 10), posB))
    R:Register("A", "c", elDef(FakeFrame(0, 0, 10, 10), posC))
    eq(R:ParentId("A:b"), "A:one", "parent id")
    eq(#R:Children("A:one"), 1, "one direct child")
    eq(#R:Descendants("A:one"), 2, "two descendants")
    check(R:IsOccupied("A:one", "right", "start"), "zone occupied by b")
    check(not R:IsOccupied("A:one", "right", "start", "A:b"), "exclude self")
    check(not R:IsOccupied("A:one", "left", "start"), "other zone free")
end

-- enabled flags
do
    check(R:IsEnabled("A", "one"), "enabled with no db")
    NS.db = { addons = { A = { enabled = true, elements = { one = false } } } }
    check(not R:IsEnabled("A", "one"), "element toggle off")
    check(R:IsEnabled("A", "two"), "sibling still on")
    NS.db.addons.A.enabled = false
    check(not R:IsEnabled("A", "two"), "addon toggle off")
    NS.db = nil
end

-- unregister
do
    R:Unregister("A", "c")
    check(R:Get("A:c") == nil and R:GetTarget("A:c") == nil, "element and target removed")
    R:UnregisterAddon("A")
    check(R:Get("A:one") == nil and R:GetAddon("A") == nil, "addon fully removed")
    eq(#R:SortedElements(), 0, "no elements left")
end
