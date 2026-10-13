local addonName, DF = ...

-- ============================================================
-- UNHEALABLE FADE
-- Dims a frame while its unit carries an aura that makes it unhealable, so a healer
-- stops trying to heal (or target) it. Spirit of Redemption is the case that asked for
-- it: the priest looks alive and in range, but heals cannot land.
--
-- ☠ A COVER, NOT AN ALPHA. Aura presence is secret in combat, and nothing on the
-- presence path can change a frame's alpha (the Aura Designer's framealpha casualty,
-- see the foot of AuraDesigner/Factory.lua). What it CAN do is show a region: an
-- overlay slot's tint texture inherits the slot's engine-driven visibility, read-free.
-- So the "fade" is a flat cover over the whole frame, which on a dark frame reads as
-- the frame dimming.
--
-- Driven from DF:UpdateDispelOverlay's call sites (every per-frame refresh and unit
-- change, pinned frames included) and from DF:RefreshUnhealableFade on a settings edit.
-- ============================================================

-- Auras that make a friendly unit unhealable. Only spells confirmed in game belong here.
local UNHEALABLE_SPELLS = {
    [27827] = true,   -- Spirit of Redemption
}

-- Above every layer a frame draws: AD indicators sit at their Default Frame Level
-- (40 by default) and the Text Designer overlay near +25, so the cover has to clear both
-- or it would dim the frame and leave its icons bright.
local COVER_LEVEL_OFFSET = 60

local DEFAULT_COLOR = { r = 0.05, g = 0.05, b = 0.05 }

local function coverTint(db)
    local c = type(db.fadeUnhealableColor) == "table" and db.fadeUnhealableColor or DEFAULT_COLOR
    -- The slider is the frame's apparent opacity, like Frame Alpha (Out of Range), so the
    -- cover's own opacity is its complement.
    local alpha = tonumber(db.fadeUnhealableAlpha) or 0.4
    return c.r or 0, c.g or 0, c.b or 0, 1 - math.max(0, math.min(1, alpha))
end

local function coverConfig(unit, db)
    local r, g, b, a = coverTint(db)
    return {
        unit = unit,
        mode = "overlay",
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = UNHEALABLE_SPELLS },
        enabled = true,
        frameLevelOffset = COVER_LEVEL_OFFSET,
        style = { overlay = { tintColor = { r, g, b, a } } },
    }
end

local function dropCover(frame)
    local h = frame.dfUnhealableCover
    if h then
        h:Destroy()   -- self-defers to regen in lockdown
        frame.dfUnhealableCover = nil
        frame.dfUnhealableCoverSig = nil
        frame.dfUnhealableCoverVer, frame.dfUnhealableCoverDB = nil, nil
    end
end

local version = 0

function DF:DriveUnhealableFade(frame)
    if not frame then return end
    local db = DF:GetFrameDB(frame)
    local AC = DF.AuraContainer
    local on = db and db.fadeUnhealableEnabled
        and AC and AC.IsSupported()
        and not frame.dfIsTestFrame and not (DF.testMode or DF.raidTestMode)
    if not on then
        dropCover(frame)
        return
    end
    -- An empty header slot has no unit, and Create defaults a nil unit to "player".
    -- An existing cover is kept: SetUnit retargets it when the slot fills.
    if not frame.unit then return end

    -- Fast path: this runs on every UNIT_AURA. Settings can only move through
    -- RefreshUnhealableFade (the version) or a profile/mode swap (the db table).
    local h = frame.dfUnhealableCover
    if h and frame.dfUnhealableCoverVer == version and frame.dfUnhealableCoverDB == db then
        if h:GetUnit() ~= frame.unit then h:SetUnit(frame.unit) end
        return
    end
    frame.dfUnhealableCoverVer, frame.dfUnhealableCoverDB = version, db

    local r, g, b, a = coverTint(db)
    local sig = r .. "," .. g .. "," .. b .. "," .. a
    if not h then
        h = AC:Create(frame, coverConfig(frame.unit, db))
        frame.dfUnhealableCover = h
        frame.dfUnhealableCoverSig = h and sig or nil
        if not h then return end
    elseif frame.dfUnhealableCoverSig ~= sig then
        frame.dfUnhealableCoverSig = sig
        h:ApplyStyle({ overlay = { tintColor = { r, g, b, a } } })
    end
    if h:GetUnit() ~= frame.unit then h:SetUnit(frame.unit) end
end

-- Settings edits: re-drive every frame now rather than on its next refresh.
function DF:RefreshUnhealableFade()
    version = version + 1
    local function drive(frame) DF:DriveUnhealableFade(frame) end
    if DF.IterateAllFrames then DF:IterateAllFrames(drive) end
    if DF.IteratePinnedFrames then DF.IteratePinnedFrames(drive) end
end
