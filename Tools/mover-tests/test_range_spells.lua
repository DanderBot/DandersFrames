-- ============================================================
-- RANGE SPELLS (DandersFrames/Features/Range.lua)
-- The friendly range check walks a list of known spells and the first one that
-- answers decides. Loaded REAL, once per class, into a fresh namespace: the file
-- reads the player's class and binds its API locals at load.
-- ============================================================

local S  -- per-test world: what the stubbed API answers

local function resetWorld(class)
    S = {
        class = class,
        specIndex = 1, specID = nil,
        known = {},          -- [spellID] = true
        inRange = {},        -- [spellID] = true / false / nil (nil = "can't check this unit")
        override = {},       -- [spellID] = the spell a hero talent replaced it with
        combat = false,
        interact = false,    -- CheckInteractDistance(unit, 4)
        unitInRange = true,  -- UnitInRange answer
        hostile = false,
        dead = false,
        now = 100,
        warns = {},
        debugOn = true,
    }
end

local saved = {}
local STUBS = {
    UnitClass = function() return S.class, S.class end,
    C_SpecializationInfo = {
        GetSpecialization = function() return S.specIndex end,
        GetSpecializationInfo = function() return S.specID end,
    },
    C_Spell = {
        IsSpellInRange = function(id) return S.inRange[id] end,
        GetSpellName = function(id) return "spell" .. id end,
        GetSpellInfo = function() return { maxRange = 30 } end,
        GetOverrideSpell = function(id) return S.override[id] or id end,
    },
    IsPlayerSpell = function(id) return S.known[id] == true end,
    InCombatLockdown = function() return S.combat end,
    CheckInteractDistance = function() return S.interact end,
    UnitInRange = function() return S.unitInRange, true end,
    UnitIsUnit = function(a, b) return a == b end,
    UnitExists = function() return true end,
    UnitPhaseReason = function() return nil end,
    UnitCanAttack = function() return S.hostile end,
    UnitIsDeadOrGhost = function() return S.dead end,
    UnitIsConnected = function() return true end,
    IsInGroup = function() return S.inGroup ~= false end,
    IsInRaid = function() return false end,
    GetTime = function() return S.now end,
    time = function() return 0 end,
    issecretvalue = function() return false end,
    C_Timer = { After = function() end },
    SlashCmdList = {},
    CreateFrame = function()
        local f = {}
        function f:RegisterEvent() end
        function f:SetScript() end
        function f:CreateAnimationGroup()
            local g = {}
            function g:CreateAnimation() return { SetDuration = function() end } end
            function g:SetLooping() end
            function g:SetScript(kind, fn) S.scripts = S.scripts or {}; S.scripts[kind] = fn end
            function g:Play() end
            return g
        end
        return f
    end,
}

local function loadRange(class, setup)
    resetWorld(class)
    if setup then setup() end
    for k, v in pairs(STUBS) do saved[k] = _G[k]; _G[k] = v end
    local DF = {
        db = { party = {}, raid = {} },
        MakeDebugPrinter = function() return function() end end,
        RegisterRosterUnitEvent = function() end,
        RegisterDebugSlash = function() end,
        Debug = function() end,
        DebugWarn = function(_, cat, fmt, ...) S.warns[#S.warns + 1] = string.format(fmt, ...) end,
        DebugActive = function() return S.debugOn end,
        MemTestDisabled = function() return false end,
        FrameInTestScope = function() return false end,   -- no test mode
        UnitIsUnit = function(a, b) return a == b end,
    }
    load_df_file_into("Features/Range.lua", DF)
    return DF
end

local function unload()
    for k in pairs(STUBS) do _G[k] = saved[k]; saved[k] = nil end
end

-- Range answer for one fresh frame on party1.
local function rangeOf(DF)
    DF:ClearRangeCache()
    local frame = { unit = "party1" }
    DF:UpdateRange(frame)
    return frame.dfInRange
end

do  -- evoker: Living Flame is the spell named and checked first
    local DF = loadRange("EVOKER", function()
        S.specID = 1468
        S.known[361469], S.known[355913] = true, true
    end)
    DF:RefreshRangeSpell()
    eq(DF:GetCurrentRangeSpellInfo().spellID, 361469, "evoker auto range spell is Living Flame")

    -- the reported case: Blossom can't be checked, in combat; Living Flame says out of range
    S.combat, S.unitInRange = true, true
    S.inRange[361469], S.inRange[355913] = false, nil
    eq(rangeOf(DF), false, "Living Flame's answer wins over the ~40yd UnitInRange fallback")

    -- Living Flame can't be checked but Blossom can: the list moves on
    S.inRange[361469], S.inRange[355913] = nil, false
    eq(rangeOf(DF), false, "a nil from the first spell hands the unit to the next spell")
    S.inRange[355913] = true
    eq(rangeOf(DF), true, "the next spell's in-range answer stands")
    eq(#S.warns, 0, "no fallback line while a spell still answers")

    -- neither answers in combat: UnitInRange decides, and the log says so once
    S.inRange[361469], S.inRange[355913] = nil, nil
    eq(rangeOf(DF), true, "no spell answers -> UnitInRange decides in combat")
    eq(#S.warns, 1, "the fallback is logged")
    check(S.warns[1] and S.warns[1]:find("party1", 1, true) and S.warns[1]:find("361469", 1, true),
        "the fallback line names the unit and the spells tried")
    rangeOf(DF)
    eq(#S.warns, 1, "the fallback line is rate-limited per unit")
    S.now = S.now + 31
    rangeOf(DF)
    eq(#S.warns, 2, "and logs again after the window")
    S.debugOn = false
    S.now = S.now + 31
    rangeOf(DF)
    eq(#S.warns, 2, "nothing is logged while the RANGE category is off")

    -- out of combat with no spell answer: interact distance, as before
    S.combat, S.interact = false, false
    eq(rangeOf(DF), false, "out of combat a spell-less unit uses interact distance")
    unload()
end

do  -- a chosen spell goes first, the automatic list stays behind it
    local DF = loadRange("EVOKER", function()
        S.specID = 1468
        S.known[361469], S.known[355913] = true, true
    end)
    DF.db.party.rangeCheckSpellID = 355913
    DF:RefreshRangeSpell()
    eq(DF:GetCurrentRangeSpellInfo().spellID, 355913, "the chosen spell is the one named")
    eq(DF:GetCurrentRangeSpellInfo().isCustom, true, "and reported as custom")
    S.combat, S.unitInRange = true, true
    S.inRange[355913], S.inRange[361469] = false, true
    eq(rangeOf(DF), false, "the chosen spell's answer decides when it has one")
    S.inRange[355913] = nil
    S.inRange[361469] = false
    eq(rangeOf(DF), false, "a chosen spell that can't check the unit falls to the auto list, not 40yd")

    -- a chosen spell the character doesn't know: auto list only
    DF.db.party.rangeCheckSpellID = 12345
    DF:RefreshRangeSpell()
    eq(DF:GetCurrentRangeSpellInfo().spellID, 361469, "an unknown chosen spell leaves the auto list")
    unload()
end

do  -- the first spell is unchanged for the other healers
    local cases = {
        { "PRIEST", 256, { 17, 2061 }, 17, "Discipline keeps Power Word: Shield first" },
        { "PRIEST", 257, { 2061, 17 }, 2061, "Holy priest keeps Flash Heal first" },
        { "DRUID", 105, { 774, 8936 }, 774, "Restoration druid keeps Rejuvenation first" },
        { "PALADIN", 65, { 19750, 85673 }, 19750, "Holy paladin keeps Flash of Light first" },
        { "MONK", 270, { 116670, 115450 }, 116670, "Mistweaver keeps Vivify first" },
        { "SHAMAN", 264, { 8004 }, 8004, "Restoration shaman keeps Healing Surge first" },
    }
    for _, c in ipairs(cases) do
        local DF = loadRange(c[1], function()
            S.specID = c[2]
            for _, id in ipairs(c[3]) do S.known[id] = true end
        end)
        DF:RefreshRangeSpell()
        eq(DF:GetCurrentRangeSpellInfo().spellID, c[4], c[5])
        unload()
    end
end

do  -- Enhancement's own Healing Surge ID is enough for a friendly spell
    local DF = loadRange("SHAMAN", function()
        S.specID = 263
        S.known[188070] = true
    end)
    DF:RefreshRangeSpell()
    eq(DF:GetCurrentRangeSpellInfo().spellID, 188070, "Enhancement resolves Healing Surge 188070")
    unload()
end

do  -- unknown spec: the class list decides
    local DF = loadRange("EVOKER", function()
        S.specIndex, S.specID = nil, nil
        S.known[355913] = true
    end)
    DF:RefreshRangeSpell()
    eq(DF:GetCurrentRangeSpellInfo().spellID, 355913, "class list used when the spec is unknown")
    unload()
end

do  -- hostile units walk the hostile list too
    local DF = loadRange("EVOKER", function()
        S.specID = 1467
        S.known[361469] = true
    end)
    DF:RefreshRangeSpell()
    S.hostile = true
    S.inRange[361469] = false
    eq(rangeOf(DF), false, "hostile unit uses the hostile spell")
    S.inRange[361469] = nil
    eq(rangeOf(DF), true, "a hostile unit no spell can check stays in range")
    unload()
end

do  -- classes without a friendly spell still take UnitInRange in combat, silently
    local DF = loadRange("WARRIOR", function()
        S.specID = 71
        S.known[355] = true
    end)
    DF:RefreshRangeSpell()
    S.combat, S.unitInRange = true, false
    eq(rangeOf(DF), false, "warrior in combat uses UnitInRange")
    eq(#S.warns, 0, "no fallback line for a class that has no friendly spell")
    unload()
end

do  -- a hero-talent replacement answers when the base spell goes quiet
    local DF = loadRange("EVOKER", function()
        S.specID = 1468
        S.known[361469], S.known[355913] = true, true
    end)
    DF:RefreshRangeSpell()
    S.combat, S.unitInRange = true, true
    S.override[361469] = 431442
    S.inRange[361469], S.inRange[431442], S.inRange[355913] = nil, false, nil
    eq(rangeOf(DF), false, "Living Flame's nil is retried as Chrono Flame, ahead of the 40yd fallback")
    eq(#S.warns, 0, "no fallback line when the replacement answered")
    S.inRange[431442] = true
    eq(rangeOf(DF), true, "the replacement's in-range answer stands")
    unload()
end

do  -- Chrono Flame known by its own ID is in the evoker list
    local DF = loadRange("EVOKER", function()
        S.specID = 1468
        S.known[431442], S.known[355913] = true, true
    end)
    DF:RefreshRangeSpell()
    eq(DF:GetCurrentRangeSpellInfo().spellID, 431442, "Chrono Flame leads when Living Flame is not known")
    unload()
end

do  -- hostile backups
    local DF = loadRange("PRIEST", function()
        S.specID = 256
        S.known[17], S.known[585], S.known[589] = true, true, true
    end)
    DF:RefreshRangeSpell()
    S.hostile = true
    S.inRange[585], S.inRange[589] = nil, false
    eq(rangeOf(DF), false, "Smite's nil hands the enemy to Shadow Word: Pain")
    unload()

    DF = loadRange("DEATHKNIGHT", function()
        S.specID = 250
        S.known[49576] = true
    end)
    DF:RefreshRangeSpell()
    S.hostile = true
    S.inRange[49576] = false
    eq(rangeOf(DF), false, "a Blood DK without Death Coil checks enemies with Death Grip")
    unload()

    DF = loadRange("SHAMAN", function()
        S.specID = 262
        S.known[8004], S.known[188196], S.known[188389] = true, true, true
    end)
    DF:RefreshRangeSpell()
    S.hostile = true
    S.inRange[188196], S.inRange[188389] = nil, true
    eq(rangeOf(DF), true, "Lightning Bolt's nil hands the enemy to Flame Shock")
    unload()
end

do  -- paladin rez: Intercession behind Redemption
    local DF = loadRange("PALADIN", function()
        S.specID = 65
        S.known[19750], S.known[391054] = true, true
    end)
    DF:RefreshRangeSpell()
    S.dead, S.combat = true, true
    S.inRange[19750], S.inRange[391054] = nil, false
    eq(rangeOf(DF), false, "a dead unit is checked with Intercession when Redemption is not known")
    S.inRange[391054] = true
    eq(rangeOf(DF), true, "and its in-range answer stands")
    unload()
end

-- ============================================================
-- STANDALONE FRAMES AND THE RANGE REGISTRY
-- The solo shortcut (everyone in range when not grouped) is a group-frame rule; a
-- standalone frame is range-checked whatever the group. Frames registered with
-- DF:RegisterRangeFrame are polled on every tick, before the group-header gate;
-- with no registrations the tick is the group walk it always was.
-- ============================================================
do
    local DF = loadRange("PRIEST", function() S.specID = 256 end)
    DF:RefreshRangeSpell()
    S.inGroup, S.interact = false, false   -- solo, out of interact distance
    DF:ClearRangeCache()
    local party = { unit = "party1" }
    DF:UpdateRange(party)
    eq(party.dfInRange, true, "solo: a group frame takes the in-range shortcut")
    local standalone = { unit = "target", dfStandalone = true }
    DF:UpdateRange(standalone)
    eq(standalone.dfInRange, false, "solo: a standalone frame is really checked")

    local tick = S.scripts and S.scripts.OnLoop
    check(tick ~= nil, "the range tick is captured")
    local walked = 0
    DF.GroupHeadersReady = function() return false end
    DF.GetContentType = function() return nil end
    DF.IteratePartyFrames = function() walked = walked + 1 end
    if tick then
        tick()
        eq(walked, 0, "no registrations, headers not ready: the tick does nothing")
        local polled = { unit = "target", dfStandalone = true, IsShown = function() return true end }
        local hidden = { unit = "focus", dfStandalone = true, IsShown = function() return false end }
        DF:RegisterRangeFrame(polled)
        DF:RegisterRangeFrame(hidden)
        DF:ClearRangeCache()
        tick()
        eq(polled.dfInRange, false, "a registered frame is polled even before any group header is ready")
        eq(hidden.dfInRange, nil, "a hidden registered frame is skipped")
        eq(walked, 0, "and the group walk still waits for its headers")
        DF:UnregisterRangeFrame(polled)
        polled.dfInRange = nil
        tick()
        eq(polled.dfInRange, nil, "an unregistered frame is no longer polled")
        DF.GroupHeadersReady = function() return true end
        tick()
        eq(walked, 1, "headers ready: the party walk runs as before")
    end
    unload()
end

print("-- Highlights: the in-raid party-frame shortcut skips standalone frames")
do
    local hsrc = df_file_source("Features/Highlights.lua"):gsub("\r\n", "\n")
    check(hsrc:find("if not frame%.dfIsTestFrame and not frame%.dfStandalone and not frame%.isRaidFrame\n%s*and not frame%.isArenaFrame and IsInRaid%(%) then"),
        "UpdateHighlights: standalone frames are exempt from the in-raid hide")
end
