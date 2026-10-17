local NS = ...

-- ============================================================
-- AUTO LAYOUTS OWN THE PERSONAL TARGETED BLOCK'S POSITION TOO
-- ------------------------------------------------------------
-- BEHAVIOURAL: the real DF:GetPositionRecord / DF:SetPositionRecord, cut out of
-- Frames/Position.lua, for the "personal" record. In a raid its db() is the raid overlay,
-- so an active layout owns it exactly as it owns the raid frames' record:
--   * a layout storing only personalTargetedSpellX/Y: its X/Y, NO anchor;
--   * a DandersMover move/anchor while a layout is active lands in the layout, whole,
--     and never touches the profile's record;
--   * a lib re-solve on a layout that leaves the position to the profile stamps nothing;
--   * out of a raid the profile's own record, as always.
-- Plus the permanent mover's raw drag: it takes the main-group shift off on the drop.
-- ============================================================

local src = df_file_source("Frames/Position.lua"):gsub("\r\n", "\n")
local s = src:find("local RECORD_SPECS = {", 1, true)
local e = src:find("function DF:UpdateContainerPosition()", 1, true)
check(s and e, "personal layout: the record funnel can be cut out of Position.lua")
if not (s and e) then return end

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = deepcopy(x) end
    return t
end

local function world(baseRec, layoutOverrides, inRaid)
    local DF = {}
    local real = {
        personalTargetedPosition = baseRec,
        personalTargetedSpellX = baseRec and baseRec.x or 0,
        personalTargetedSpellY = baseRec and baseRec.y or -150,
    }
    local party = { personalTargetedPosition = { point = "CENTER", x = 1, y = 2 },
                    personalTargetedSpellX = 1, personalTargetedSpellY = 2 }
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
    if layout then DF.raidOverrides = deepcopy(layout.overrides) end
    DF.GetRaidDB = function() return proxy end
    DF.GetDB = function() return party end
    DF.GetPersonalTargetedDB = function() return inRaid and proxy or party end
    DF.AutoProfilesUI = {
        IsEditing = function() return false end,
        SetActiveLayoutRaidPair = function(_, xKey, yKey, x, y)
            if not layout then return false end
            layout.overrides[xKey], layout.overrides[yKey] = x, y
            DF.raidOverrides[xKey], DF.raidOverrides[yKey] = x, y
            return true
        end,
        SetActiveLayoutRaidRecord = function(_, rec, key)
            if not layout then return false end
            layout.overrides[key or "position"] = deepcopy(rec)
            return true
        end,
    }
    local env = setmetatable({ DF = DF }, { __index = _G })
    local fn = assert(loadstring(src:sub(s, e - 1), "=Position.lua(cut)"))
    setfenv(fn, env)
    fn()
    return DF, real, layout, party
end

local ANCHOR = { target = "SomeBar", mode = "attach", point = "TOP", relPoint = "BOTTOM", offsetX = 0, offsetY = -4 }

-- 1. A layout storing only X/Y, with an anchored profile block: layout X/Y, no anchor.
do
    local base = { point = "CENTER", x = 10, y = 20, anchor = deepcopy(ANCHOR) }
    local DF, real, layout = world(base, { personalTargetedSpellX = 300, personalTargetedSpellY = -150 }, true)
    local rec = DF:GetPositionRecord("personal")
    eq(rec.x, 300, "personal layout: X/Y-only layout keeps its X")
    eq(rec.y, -150, "personal layout: ...and its Y")
    check(rec.anchor == nil, "personal layout: ...and is not pulled by the profile's anchor")
    check(rec ~= real.personalTargetedPosition, "personal layout: ...on a layout-side record")
    check(real.personalTargetedPosition.anchor ~= nil, "personal layout: reading leaves the profile's anchor alone")
    check(layout.overrides.personalTargetedPosition == nil, "personal layout: reading writes nothing to the layout")
end

-- 2. A DandersMover move + anchor while a layout is active lands in the layout, whole.
do
    local base = { point = "CENTER", x = 10, y = 20 }
    local DF, real, layout = world(base, { personalTargetedSpellX = 300, personalTargetedSpellY = -150 }, true)
    local rec = DF:GetPositionRecord("personal")
    rec.x, rec.y = 320, -140
    rec.anchor = deepcopy(ANCHOR)
    DF:SetPositionRecord("personal", rec, "DandersMover", "anchor")
    eq(layout.overrides.personalTargetedSpellX, 320, "personal layout: a move lands in the layout's X")
    local stored = layout.overrides.personalTargetedPosition
    eq(stored and stored.anchor and stored.anchor.target, "SomeBar", "personal layout: an anchor lands in the layout's record")
    check(real.personalTargetedPosition.anchor == nil, "personal layout: the profile's record gains no anchor")
    eq(real.personalTargetedSpellX, 10, "personal layout: ...nor do the profile's scalars move")
end

-- 3. A lib re-solve while the layout leaves the block to the profile stamps nothing.
do
    local base = { point = "CENTER", x = 10, y = 20, anchor = deepcopy(ANCHOR) }
    local DF, real, layout = world(base, { frameWidth = 90 }, true)
    local rec = DF:GetPositionRecord("personal")
    check(rec ~= real.personalTargetedPosition, "personal layout: profile-following layout gets a copy")
    rec.x, rec.y = 12, 22
    DF:SetPositionRecord("personal", rec, "DandersMover", "parent")
    check(layout.overrides.personalTargetedSpellX == nil, "personal layout: a lib re-solve does not stamp the layout's X/Y")
    check(layout.overrides.personalTargetedPosition == nil, "personal layout: ...nor a record")
    eq(real.personalTargetedPosition.x, 12, "personal layout: ...it updates the profile's record instead")
    eq(real.personalTargetedSpellX, 12, "personal layout: ...and the profile's scalars")
end

-- 4. Out of a raid the block reads the party db: the profile's own record.
do
    local DF, _, _, party = world({ point = "CENTER", x = 10, y = 20 }, { personalTargetedSpellX = 300 }, false)
    local rec = DF:GetPositionRecord("personal")
    check(rec == party.personalTargetedPosition, "personal layout: out of a raid -> the party profile's own record")
end

-- 5. NormalizeLayoutPositionRecord with the personal keys drops a redundant record.
do
    local asrc = df_file_source("Core/AutoProfiles.lua"):gsub("\r\n", "\n")
    local h = "local function NormalizeLayoutPositionRecord(overrides, base, key, xKey, yKey)"
    local s2 = asrc:find(h, 1, true)
    local e2 = s2 and asrc:find("\nend\n", s2)
    check(s2 and e2, "personal normalize: can be cut out of AutoProfiles.lua")
    if s2 and e2 then
        local norm = assert(loadstring(asrc:sub(s2, e2 + 4) .. "\nreturn NormalizeLayoutPositionRecord",
            "@AutoProfiles.lua(normalize)"))()
        local K, X, Y = "personalTargetedPosition", "personalTargetedSpellX", "personalTargetedSpellY"
        local o = { [Y] = -200, [K] = { point = "CENTER", x = 0, y = -200 } }
        norm(o, { [X] = 0, [Y] = -150 }, K, X, Y)
        check(o[K] == nil, "personal normalize: a record that adds nothing is dropped")
        o = { [Y] = -200, [K] = { point = "CENTER", x = 0, y = -200, anchor = { target = "X" } } }
        norm(o, { [X] = 0, [Y] = -150 }, K, X, Y)
        check(o[K] ~= nil, "personal normalize: a record carrying an anchor is kept")
        o = { raidAnchorY = 20, position = { point = "CENTER", x = -6.67, y = 20 }, [Y] = -200 }
        norm(o, { raidAnchorX = -6.67 }, K, X, Y)
        check(o.position ~= nil, "personal normalize: the raid record is not touched by a personal pass")
    end
    check(asrc:find('{ key = "personalTargetedPosition", xKey = "personalTargetedSpellX", yKey = "personalTargetedSpellY" }', 1, true) ~= nil,
          "personal layout: the personal record is one a layout can own")
    check(not asrc:find("personalTargetedPosition = true,", 1, true),
          "personal layout: ...and is no longer blocked as a non-overridable key")
end

-- 6. Discard restores the personal record a session gave the layout.
do
    local bsrc = df_file_source("Features/MoverBridge.lua")
    check(bsrc:find('"personalTargetedSpellX", "personalTargetedSpellY", "personalTargetedPosition",', 1, true) ~= nil,
          "personal layout: Discard snapshots the personal record with the layout's other position keys")
end

-- 7. The permanent mover's raw drag starts at the container's real spot and drops back
--    onto the record: the main-group shift goes on at the start and comes off at the drop.
--    Source shape -- the drag needs a cursor and a live container.
do
    check(src:find("if isRaid then offX, offY = DF:GetRaidContainerOffset() end", 1, true) ~= nil,
          "handle drag: the start reads the raid container's offset")
    check(src:find("local frameCX = sw / 2 + anchorX + offX", 1, true) ~= nil,
          "handle drag: ...and starts from the container's real centre")
    check(src:find("- screenWidth / 2 - (self._offX or 0)", 1, true) ~= nil,
          "handle drag: the drop takes the offset back off X")
    check(src:find("- screenHeight / 2 - (self._offY or 0)", 1, true) ~= nil,
          "handle drag: ...and Y")
    local upd = src:find("function DF:UpdateRaidContainerPosition()", 1, true)
    check(upd and src:find("local dx, dy = DF:GetRaidContainerOffset()", upd, true) ~= nil,
          "handle drag: the container placement uses the same offset")
end
