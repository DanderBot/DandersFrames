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

-- target availability: getRect owns the question when it is supplied
do
    local shown = FakeFrame(0, 0, 10, 10)
    local hidden = FakeFrame(0, 0, 10, 10); hidden._shown = false
    local t1 = R:RegisterAnchorTarget("A", "av_shown", { title = "t", frame = shown })
    local t2 = R:RegisterAnchorTarget("A", "av_hidden", { title = "t", frame = hidden })
    local t3 = R:RegisterAnchorTarget("A", "av_noframe", { title = "t", getFrame = function() return nil end })
    local t4 = R:RegisterAnchorTarget("A", "av_rect", { title = "t", frame = hidden,
        getRect = function() return { x = 0, y = 0, w = 10, h = 10 } end })
    local t5 = R:RegisterAnchorTarget("A", "av_norect", { title = "t", frame = shown,
        getRect = function() return nil end })
    check(R:IsTargetAvailable(t1), "shown frame is available")
    check(not R:IsTargetAvailable(t2), "hidden frame is not available")
    check(not R:IsTargetAvailable(t3), "nil frame is not available")
    check(R:IsTargetAvailable(t4), "getRect returning a rect wins over a hidden frame")
    check(not R:IsTargetAvailable(t5), "getRect returning nil wins over a shown frame")
    check(not R:IsTargetAvailable(nil), "nil entry is not available")
    for _, key in ipairs({ "av_shown", "av_hidden", "av_noframe", "av_rect", "av_norect" }) do
        R:Unregister("A", key)
    end
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

-- alias targets (getFrame pointing at a registered element's frame)
do
    local oneFrame = R:GetFrame(R:Get("A:one"))
    R:RegisterAnchorTarget("A", "alias", { title = "alias", getFrame = function() return oneFrame end })
    eq(R:CanonicalId("A:alias"), "A:one", "alias resolves to owning element")
    eq(R:CanonicalId("A:one"), "A:one", "element id is its own canonical")
    check(R:WouldCreateCycle("A:one", "A:alias"), "anchoring one to its own alias is a cycle")
    check(R:WouldCreateCycle("A:b", "A:alias") == false, "b -> alias(one) is fine (one is b's parent already)")
    check(R:WouldCreateCycle("A:one", "A:c"), "one -> c is a cycle through b")
    eq(#R:Children("A:alias"), 1, "children of alias = children of one")
    local posD = { point = "CENTER", x = 0, y = 0, anchor = { target = "A:alias", edge = "left", align = "end" } }
    R:Register("A", "d", elDef(FakeFrame(0, 0, 10, 10), posD))
    eq(R:ParentId("A:d"), "A:one", "parent through alias is canonical")
    eq(#R:Children("A:one"), 2, "d counts as a child of one")
    check(R:IsOccupied("A:one", "left", "end"), "occupancy sees through alias")
    check(R:IsOccupied("A:alias", "right", "start"), "occupancy via alias sees direct children")
    R:Unregister("A", "d"); R:Unregister("A", "alias")
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

-- getRect nil falls through to getSize / frame size
do
    R:RegisterAddon("G", { title = "G" })
    local hidden = R:Register("G", "h1", elDef(FakeFrame(0, 0, 40, 20), { point = "CENTER", x = 0, y = 0 },
        { getRect = function() return nil end, getSize = function() return 77, 33 end }))
    local w, h = R:GetSize(hidden)
    eq(w, 77, "getSize used when getRect is nil"); eq(h, 33, "getSize height")
    check(R:GetRect(hidden) == nil, "rect still nil (not visible)")
    check(not R:IsTargetAvailable(hidden), "not available as a target")
    local hidden2 = R:Register("G", "h2", elDef(FakeFrame(0, 0, 40, 20), { point = "CENTER", x = 0, y = 0 },
        { getRect = function() return nil end }))
    local w2 = R:GetSize(hidden2)
    eq(w2, 40, "frame size used when getRect nil and no getSize")
    R:UnregisterAddon("G")
end

-- user toggles: SetEnabled writes what IsEnabled reads, both ways round
do
    NS.db = { addons = {} }
    check(R:IsEnabled("T", "a"), "unknown addon defaults to enabled")
    R:SetEnabled("T", "a", false)
    check(not R:IsEnabled("T", "a"), "element off after SetEnabled(false)")
    check(NS.db.addons.T.elements.a == false, "stored as explicit false")
    check(R:IsEnabled("T", "b"), "sibling element unaffected")
    check(R:IsEnabled("T"), "addon itself still enabled")
    R:SetEnabled("T", "a", true)
    check(R:IsEnabled("T", "a"), "element back on after SetEnabled(true)")
    check(NS.db.addons.T.elements.a == nil, "on is stored as absent")
    R:SetEnabled("T", nil, false)
    check(not R:IsEnabled("T"), "addon off")
    check(not R:IsEnabled("T", "b"), "addon off disables every element")
    R:SetEnabled("T", nil, true)
    check(R:IsEnabled("T", "b"), "addon back on")
    NS.db = nil
end

-- relevance: absent = relevant; false beats a rect; errors fail open; forced wins;
-- non-function rejected
do
    local wasReady = R.ready
    R.ready = true
    NS.db = nil
    R:RegisterAddon("V", { title = "V" })
    local rect = function() return { x = 0, y = 0, w = 10, h = 10 } end
    local plain = R:RegisterAnchorTarget("V", "plain", { title = "t", frame = FakeFrame(0, 0, 10, 10), getRect = rect })
    local no = R:RegisterAnchorTarget("V", "no", { title = "t", frame = FakeFrame(0, 0, 10, 10), getRect = rect,
        isRelevant = function() return false end })
    local boom = R:RegisterAnchorTarget("V", "boom", { title = "t", frame = FakeFrame(0, 0, 10, 10), getRect = rect,
        isRelevant = function() error("relevance boom") end })
    check(R:IsRelevant(plain), "absent isRelevant = relevant")
    check(R:IsTargetAvailable(plain), "relevant target with a rect is available")
    check(not R:IsRelevant(no), "isRelevant false")
    check(not R:IsTargetAvailable(no), "irrelevant target is unavailable even with a rect")
    check(R:GetRect(no) ~= nil, "GetRect is untouched by relevance")
    local handled = 0
    local old = geterrorhandler
    geterrorhandler = function() return function() handled = handled + 1 end end
    check(R:IsRelevant(boom), "erroring isRelevant fails open")
    geterrorhandler = old
    eq(handled, 1, "error handler called once")
    NS.forcedRelevant[no.id] = true
    check(R:IsRelevant(no) and R:IsTargetAvailable(no), "forcedRelevant overrides false")
    NS.forcedRelevant[no.id] = nil
    check(not R:IsRelevant(no), "cleared forcing restores false")
    local ok = pcall(R.RegisterAnchorTarget, R, "V", "bad", { title = "t", frame = FakeFrame(0, 0, 10, 10), isRelevant = "nope" })
    check(not ok, "non-function isRelevant rejected")
    local el = R:Register("V", "el", elDef(FakeFrame(0, 0, 10, 10), { point = "CENTER", x = 0, y = 0 },
        { isRelevant = function() return false end, pointLocked = true }))
    check(el.pointLocked == true, "pointLocked stored")
    check(R:GetTarget("V:el").isRelevant == el.isRelevant, "element's target entry carries isRelevant")
    check(not R:IsTargetAvailable(R:GetTarget("V:el")), "irrelevant element is not an available target")
    R:UnregisterAddon("V")
    R.ready = wasReady
end

-- grouped elements: ungrouped bucket first, groups in first-appearance order,
-- titles sorted within a group
do
    local wasReady = R.ready
    R.ready = true
    NS.db = nil
    R:RegisterAddon("GR", { title = "GR" })
    local function reg(addon, key, title, group)
        R:Register(addon, key, elDef(FakeFrame(0, 0, 10, 10), { point = "CENTER", x = 0, y = 0 },
            { title = title, group = group }))
    end
    -- Registered out of order on purpose: SortedElements walks ids (a, b, c, ...),
    -- so "Raid" is met before "Party" and must stay ahead of it.
    reg("GR", "c", "Raid Frames", "Raid")
    reg("GR", "a", "Loose Two")
    reg("GR", "e", "Party Frames", "Party")
    reg("GR", "d", "Raid Pinned 1", "Raid")
    reg("GR", "b", "Loose One")
    local groups = R:GroupedElements("GR")
    eq(#groups, 3, "three buckets")
    check(groups[1].group == nil, "ungrouped bucket first")
    eq(#groups[1].elements, 2, "two ungrouped elements")
    eq(groups[1].elements[1].title, "Loose One", "ungrouped sorted by title")
    eq(groups[1].elements[2].title, "Loose Two", "ungrouped second")
    eq(groups[2].group, "Raid", "first group met comes first")
    eq(groups[3].group, "Party", "second group met comes second")
    eq(#groups[2].elements, 2, "two raid elements")
    eq(groups[2].elements[1].title, "Raid Frames", "raid sorted by title")
    eq(groups[2].elements[2].title, "Raid Pinned 1", "raid second")
    eq(groups[3].elements[1].title, "Party Frames", "party element")
    eq(#R:GroupedElements("NoSuchAddon"), 0, "unknown addon -> no buckets")
    -- another addon's elements never leak into this one's buckets
    R:RegisterAddon("GR2", { title = "GR2" })
    reg("GR2", "x", "Other", "Raid")
    local only = R:GroupedElements("GR")
    eq(#only, 3, "other addon does not add a bucket")
    for _, bucket in ipairs(only) do
        for _, el in ipairs(bucket.elements) do check(el.addon == "GR", "bucket holds only this addon's elements") end
    end
    R:UnregisterAddon("GR"); R:UnregisterAddon("GR2")
    R.ready = wasReady
end
