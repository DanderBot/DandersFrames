local NS = ...

-- ============================================================
-- AUTO LAYOUTS OWN THE WHOLE RAID POSITION (X/Y + DandersMover anchor)
-- ------------------------------------------------------------
-- BEHAVIOURAL: the real DF:GetPositionRecord / DF:SetPositionRecord, cut out of
-- Frames/Position.lua, against a stub profile, overlay and active layout.
--   * no layout: the profile's record, as always;
--   * a layout storing only raidAnchorX/Y (every pre-record layout): its X/Y, NO anchor,
--     and nothing written to the layout or the profile by merely reading;
--   * a layout storing a record: that record, anchor included;
--   * a layout leaving position to the profile: a copy that looks identical;
--   * a DandersMover move/anchor while a layout is active lands in the layout, whole,
--     and never touches the profile's record.
-- ============================================================

local src = df_file_source("Frames/Position.lua"):gsub("\r\n", "\n")
local s = src:find("local RECORD_SPECS = {", 1, true)
local e = src:find("function DF:UpdateContainerPosition()", 1, true)
check(s and e, "layout position: the record funnel can be cut out of Position.lua")
if not (s and e) then return end

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = deepcopy(x) end
    return t
end

local function world(baseRec, layoutOverrides)
    local DF = {}
    local real = { position = baseRec, raidAnchorX = baseRec and baseRec.x or 0, raidAnchorY = baseRec and baseRec.y or 0 }
    DF._realRaidDB = real
    local proxy = setmetatable({}, {
        __index = function(_, k)
            local ov = DF.raidOverrides
            if ov and ov[k] ~= nil then return ov[k] end
            return real[k]
        end,
        __newindex = function(_, k, v) real[k] = v end,
    })
    local layout = layoutOverrides and { overrides = deepcopy(layoutOverrides) } or nil
    if layout then
        DF.raidOverrides = deepcopy(layout.overrides)   -- what ApplyRuntimeProfile builds
    end
    DF.GetRaidDB = function() return proxy end
    DF.GetDB = function() return {} end
    DF.AutoProfilesUI = {
        IsEditing = function() return false end,
        SetActiveLayoutRaidPosition = function(_, x, y)
            if not layout then return false end
            layout.overrides.raidAnchorX, layout.overrides.raidAnchorY = x, y
            DF.raidOverrides.raidAnchorX, DF.raidOverrides.raidAnchorY = x, y
            return true
        end,
        SetActiveLayoutRaidRecord = function(_, rec)
            if not layout then return false end
            layout.overrides.position = deepcopy(rec)
            return true
        end,
    }
    local env = setmetatable({ DF = DF }, { __index = _G })
    local fn = assert(loadstring(src:sub(s, e - 1), "=Position.lua(cut)"))
    setfenv(fn, env)
    fn()
    return DF, real, layout
end

local ANCHOR = { target = "SomeBar", mode = "attach", point = "TOP", relPoint = "BOTTOM", offsetX = 0, offsetY = -4 }

-- 1. No layout: the profile's own record.
do
    local base = { point = "CENTER", x = 10, y = 20, anchor = deepcopy(ANCHOR) }
    local DF, real = world(base, nil)
    local rec = DF:GetPositionRecord("raid")
    check(rec == real.position, "layout position: no layout -> the profile's own record")
    eq(rec.anchor and rec.anchor.target, "SomeBar", "layout position: ...with the profile's anchor")
end

-- 2. A pre-record layout (X/Y only) with an anchored profile: layout X/Y, no anchor, no writes.
do
    local base = { point = "CENTER", x = 10, y = 20, anchor = deepcopy(ANCHOR) }
    local DF, real, layout = world(base, { raidAnchorX = 300, raidAnchorY = -150 })
    local rec = DF:GetPositionRecord("raid")
    eq(rec.x, 300, "layout position: X/Y-only layout keeps its X")
    eq(rec.y, -150, "layout position: ...and its Y")
    check(rec.anchor == nil, "layout position: ...and is not pulled by the profile's anchor")
    check(rec ~= real.position, "layout position: ...on a layout-side record, not the profile's")
    eq(real.position.x, 10, "layout position: reading leaves the profile's record alone")
    check(real.position.anchor ~= nil, "layout position: ...anchor included")
    check(layout.overrides.position == nil, "layout position: reading writes nothing to the layout")
end

-- 3. A layout that stores a record: that record, anchor and all.
do
    local base = { point = "CENTER", x = 10, y = 20 }
    local stored = { point = "CENTER", x = 50, y = 60, anchor = deepcopy(ANCHOR) }
    local DF = world(base, { raidAnchorX = 50, raidAnchorY = 60, position = stored })
    local rec = DF:GetPositionRecord("raid")
    eq(rec.x, 50, "layout position: stored record -> its X")
    eq(rec.anchor and rec.anchor.target, "SomeBar", "layout position: stored record -> its anchor")
end

-- 4. A layout leaving position to the profile: an identical-looking copy.
do
    local base = { point = "CENTER", x = 10, y = 20, anchor = deepcopy(ANCHOR) }
    local DF, real = world(base, { frameWidth = 90 })
    local rec = DF:GetPositionRecord("raid")
    check(rec ~= real.position, "layout position: profile-following layout gets a copy, never the profile's record")
    eq(rec.x, 10, "layout position: ...at the profile's X")
    eq(rec.anchor and rec.anchor.target, "SomeBar", "layout position: ...with the profile's anchor")
end

-- 5. DandersMover moves + anchors in place while a pre-record layout is active.
do
    local base = { point = "CENTER", x = 10, y = 20 }
    local DF, real, layout = world(base, { raidAnchorX = 300, raidAnchorY = -150 })
    local rec = DF:GetPositionRecord("raid")           -- what the lib's getPos returns
    rec.x, rec.y = 320, -140
    rec.anchor = deepcopy(ANCHOR)
    DF:SetPositionRecord("raid", rec, "test")          -- the lib's onChanged
    eq(layout.overrides.raidAnchorX, 320, "layout position: a move lands in the layout's X")
    eq(layout.overrides.position and layout.overrides.position.anchor and layout.overrides.position.anchor.target,
       "SomeBar", "layout position: an anchor lands in the layout's stored record")
    eq(real.position.x, 10, "layout position: the profile's record is untouched by a layout move")
    check(real.position.anchor == nil, "layout position: ...and gains no anchor")
    eq(real.raidAnchorX, 10, "layout position: ...nor do the profile's scalars move")
end

-- 6. A move while a profile-following layout is active: the layout takes it over, the
--    profile's record (handed out as a copy) stays where it was.
do
    local base = { point = "CENTER", x = 10, y = 20, anchor = deepcopy(ANCHOR) }
    local DF, real, layout = world(base, { frameWidth = 90 })
    local rec = DF:GetPositionRecord("raid")
    rec.x, rec.y = 99, 88
    rec.anchor = nil                                   -- detach
    DF:SetPositionRecord("raid", rec, "test")
    eq(layout.overrides.raidAnchorX, 99, "layout position: profile-following layout takes over on a move")
    eq(real.position.x, 10, "layout position: the profile's record keeps its X")
    check(real.position.anchor ~= nil, "layout position: ...and its anchor (a layout detach is the layout's)")
end
