local addonName, DF = ...

-- ============================================================
-- OUT OF RANGE ALPHA SYSTEM
-- Fades frames/elements when party members are out of range
--
-- RANGE CHECK STRATEGY:
-- 1. Player → always in range
-- 2. Phased units → always out of range (UnitPhaseReason)
-- 3. Hostile → IsSpellInRange(hostileSpell)
-- 4. Dead friendly → IsSpellInRange(rezSpell)
-- 5. Friendly with spells → IsSpellInRange over the known list, first answer wins
--    OR CheckInteractDistance out of combat
-- 6. No friendly spell → CheckInteractDistance out of combat,
--    UnitInRange() in combat, default in-range as last resort
--
-- IsSpellInRange returns normal booleans - NOT secret values.
-- We trust the result directly (== true).
-- UnitInRange() may return secret values so we still guard that.
--
-- DEBUG: /dfrange debug  - toggle debug output
--        /dfrange stats  - show cache statistics
--        /dfrange clear  - clear cache
--        /dfrange spell  - show current range spell
-- ============================================================

-- Upvalue frequently used globals
local pairs = pairs
local wipe = wipe
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit
local UnitCanAttack = UnitCanAttack
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local IsPlayerSpell = IsPlayerSpell
local GetSpecialization = C_SpecializationInfo.GetSpecialization
local GetSpecializationInfo = C_SpecializationInfo.GetSpecializationInfo
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local CheckInteractDistance = CheckInteractDistance
local C_Spell = C_Spell
local C_Spell_IsSpellInRange = C_Spell.IsSpellInRange
local C_Spell_GetSpellName = C_Spell.GetSpellName
local C_Spell_GetOverrideSpell = C_Spell.GetOverrideSpell
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsConnected = UnitIsConnected
local UnitInRange = UnitInRange
local GetTime = GetTime
local issecretvalue = issecretvalue  -- nil pre-Midnight, function in Midnight+
local UnitPhaseReason = UnitPhaseReason

-- Player info
local _, playerClass = UnitClass("player")

-- ============================================================
-- SPEC-BASED RANGE SPELLS
-- Indexed by specID - validated with IsPlayerSpell() before use
-- Format: { friendly = spellID or list, hostile = spellID or list, range = "description" }
-- ★ A friendly LIST is tried in order per unit and the first spell that answers decides.
-- IsSpellInRange answers nil whenever a spell cannot be checked against that unit, and a
-- nil on every spell drops a unit to the ~40yd UnitInRange answer in combat. So every
-- spell after the first must share its range, or a fallback would move the fade edge.
-- ============================================================

local specSpells = {
    -- ==================== DEATH KNIGHT ====================
    -- Death Coil (47541) can only heal undead minions, NOT friendly players.
    -- IsSpellInRange returns nil on player targets → no friendly spell available.
    -- Range falls back to CheckInteractDistance (OOC) or UnitInRange (combat).
    [250] = { -- Blood
        friendly = nil,
        hostile = { 47541, 49576 },  -- Death Coil, Death Grip
        range = "40yd"
    },
    [251] = { -- Frost
        friendly = nil,
        hostile = { 47541, 49576 },
        range = "40yd"
    },
    [252] = { -- Unholy
        friendly = nil,
        hostile = { 47541, 49576 },
        range = "40yd"
    },
    
    -- ==================== DEMON HUNTER ====================
    [577] = { -- Havoc
        friendly = nil,
        hostile = 185123,   -- Throw Glaive
        range = "30yd"
    },
    [581] = { -- Vengeance
        friendly = nil,
        hostile = 185123,
        range = "30yd"
    },
    [1480] = { -- Devourer
        friendly = nil,
        hostile = { 185123, 473728 },  -- Throw Glaive, Void Ray
        range = "30yd"
    },
    
    -- ==================== DRUID ====================
    [102] = { -- Balance
        friendly = { 8936, 774 },  -- Regrowth, Rejuvenation
        hostile = 8921,     -- Moonfire
        range = "40yd"
    },
    [103] = { -- Feral
        friendly = { 8936, 774 },
        hostile = 8921,
        range = "40yd"
    },
    [104] = { -- Guardian
        friendly = { 8936, 774 },
        hostile = 8921,
        range = "40yd"
    },
    [105] = { -- Restoration
        friendly = { 774, 8936, 88423 },  -- Rejuvenation, Regrowth, Nature's Cure
        hostile = 8921,
        range = "40yd"
    },
    
    -- ==================== EVOKER ====================
    -- ☠ Living Flame FIRST, not Emerald Blossom. Blossom lands at a location, and its
    -- IsSpellInRange on a raid member can come back nil, which in combat handed the unit
    -- to UnitInRange: frames faded at ~40yd while the setting read 30yd. Chrono Flame is
    -- Living Flame under the Chronowarden hero talent, listed in case the base ID goes quiet.
    [1467] = { -- Devastation
        friendly = { 361469, 431442, 355913 },  -- Living Flame, Chrono Flame, Emerald Blossom
        hostile = { 361469, 431442, 362969 },  -- Living Flame, Chrono Flame, Azure Strike
        range = "25yd"
    },
    [1468] = { -- Preservation
        friendly = { 361469, 431442, 355913 },
        hostile = { 361469, 431442, 362969 },
        range = "25yd"      -- Note: Evoker has shorter range!
    },
    [1473] = { -- Augmentation
        friendly = { 361469, 431442, 355913 },
        hostile = { 361469, 431442, 362969 },
        range = "25yd"
    },
    
    -- ==================== HUNTER ====================
    [253] = { -- Beast Mastery
        friendly = nil,
        hostile = { 193455, 75 },  -- Cobra Shot, Auto Shot
        range = "40yd"
    },
    [254] = { -- Marksmanship
        friendly = nil,
        hostile = { 19434, 75 },   -- Aimed Shot, Auto Shot
        range = "40yd"
    },
    [255] = { -- Survival
        friendly = nil,
        hostile = { 259491, 75 },  -- Kill Command (ranged version), Auto Shot
        range = "40yd"
    },
    
    -- ==================== MAGE ====================
    [62] = { -- Arcane
        friendly = { 1459, 475 },  -- Arcane Intellect, Remove Curse
        hostile = 30451,    -- Arcane Blast
        range = "40yd"
    },
    [63] = { -- Fire
        friendly = { 1459, 475 },
        hostile = 133,      -- Fireball
        range = "40yd"
    },
    [64] = { -- Frost
        friendly = { 1459, 475 },
        hostile = 116,      -- Frostbolt
        range = "40yd"
    },
    
    -- ==================== MONK ====================
    [268] = { -- Brewmaster
        friendly = { 116670, 218164 },  -- Vivify, Detox (Brewmaster/Windwalker)
        hostile = 115546,   -- Provoke
        range = "40yd"
    },
    [269] = { -- Windwalker
        friendly = { 116670, 218164 },
        hostile = 115546,
        range = "40yd"
    },
    [270] = { -- Mistweaver
        friendly = { 116670, 115450 },  -- Vivify, Detox (Mistweaver)
        hostile = 115546,
        range = "40yd"
    },
    
    -- ==================== PALADIN ====================
    [65] = { -- Holy
        friendly = { 19750, 85673, 4987 },  -- Flash of Light, Word of Glory, Cleanse
        hostile = 62124,    -- Hand of Reckoning
        range = "40yd"
    },
    [66] = { -- Protection
        friendly = { 19750, 85673, 213644 },  -- Flash of Light, Word of Glory, Cleanse Toxins
        hostile = 62124,
        range = "40yd"
    },
    [70] = { -- Retribution
        friendly = { 19750, 85673, 213644 },  -- Flash of Light, Word of Glory, Cleanse Toxins
        hostile = 62124,
        range = "40yd"
    },
    
    -- ==================== PRIEST ====================
    [256] = { -- Discipline
        friendly = { 17, 2061, 21562, 527 },  -- Power Word: Shield, Flash Heal, Fortitude, Purify
        hostile = { 585, 589 },    -- Smite, Shadow Word: Pain
        range = "40yd"
    },
    [257] = { -- Holy
        friendly = { 2061, 17, 21562, 527 },
        hostile = { 585, 589 },
        range = "40yd"
    },
    [258] = { -- Shadow
        friendly = { 17, 2061, 21562, 213634 },  -- Power Word: Shield, Flash Heal, Fortitude, Purify Disease
        hostile = { 585, 589 },
        range = "40yd"
    },
    
    -- ==================== ROGUE ====================
    [259] = { -- Assassination
        friendly = 36554,   -- Shadowstep (if talented)
        hostile = 36554,
        range = "25yd"
    },
    [260] = { -- Outlaw
        friendly = 36554,
        hostile = 185763,   -- Pistol Shot
        range = "20yd"
    },
    [261] = { -- Subtlety
        friendly = 36554,
        hostile = 36554,
        range = "25yd"
    },
    
    -- ==================== SHAMAN ====================
    [262] = { -- Elemental
        friendly = { 8004, 188070 },  -- Healing Surge (two IDs: Enhancement has its own)
        hostile = { 188196, 188389 },  -- Lightning Bolt, Flame Shock
        range = "40yd"
    },
    [263] = { -- Enhancement
        friendly = { 8004, 188070 },
        hostile = { 188196, 188389 },
        range = "40yd"
    },
    [264] = { -- Restoration
        friendly = { 8004, 188070 },
        hostile = { 188196, 188389 },
        range = "40yd"
    },
    
    -- ==================== WARLOCK ====================
    [265] = { -- Affliction
        friendly = 20707,   -- Soulstone
        hostile = 686,      -- Shadow Bolt
        range = "40yd"
    },
    [266] = { -- Demonology
        friendly = 20707,
        hostile = 686,
        range = "40yd"
    },
    [267] = { -- Destruction
        friendly = 20707,
        hostile = 29722,    -- Incinerate
        range = "40yd"
    },
    
    -- ==================== WARRIOR ====================
    [71] = { -- Arms
        friendly = nil,
        hostile = 355,      -- Taunt
        range = "30yd"
    },
    [72] = { -- Fury
        friendly = nil,
        hostile = 355,
        range = "30yd"
    },
    [73] = { -- Protection
        friendly = nil,
        hostile = 355,
        range = "30yd"
    },
}

-- Class fallbacks (used if spec not detected or not in table)
local classFallbacks = {
    DEATHKNIGHT = { friendly = nil, hostile = { 47541, 49576 } },
    DEMONHUNTER = { friendly = nil, hostile = 185123 },
    DRUID       = { friendly = { 8936, 774, 88423, 2782 }, hostile = 8921 },
    EVOKER      = { friendly = { 361469, 431442, 355913 }, hostile = { 361469, 431442, 362969 } },
    HUNTER      = { friendly = nil, hostile = 75 },  -- Auto Shot
    MAGE        = { friendly = { 1459, 475 }, hostile = 116 },
    MONK        = { friendly = { 116670, 115450, 218164 }, hostile = 115546 },
    PALADIN     = { friendly = { 19750, 85673, 4987, 213644 }, hostile = 62124 },
    PRIEST      = { friendly = { 2061, 17, 21562, 527, 213634 }, hostile = { 585, 589 } },
    ROGUE       = { friendly = nil, hostile = 36554 },
    SHAMAN      = { friendly = { 8004, 188070 }, hostile = { 188196, 188389 } },
    WARLOCK     = { friendly = 20707, hostile = 686 },
    WARRIOR     = { friendly = nil, hostile = 355 },
}

-- WoW Forever (vanilla-era spells): retail's fallbacks above are learned late or don't
-- exist there (Hand of Reckoning, Flame Shock's retail ID), which left low-level healers
-- on interact distance. Lists are tried in order, first known spell wins. Its single
-- generic spec per class never hits specSpells, so these always decide.
if DF.IS_FOREVER then
    classFallbacks = {
        DRUID   = { friendly = { 5185, 774, 8936 }, hostile = { 5176, 8921 } },  -- Healing Touch, Rejuvenation, Regrowth / Wrath, Moonfire
        HUNTER  = { friendly = nil, hostile = { 75 } },                          -- Auto Shot
        MAGE    = { friendly = { 1459 }, hostile = { 133, 116 } },               -- Arcane Intellect / Fireball, Frostbolt
        PALADIN = { friendly = { 635, 19750 }, hostile = { 879 } },              -- Holy Light, Flash of Light / Exorcism
        PRIEST  = { friendly = { 2050, 2061 }, hostile = { 585 } },              -- Lesser Heal, Flash Heal / Smite
        ROGUE   = { friendly = nil, hostile = { 2764, 36554 } },                 -- Throw, Shadowstep
        SHAMAN  = { friendly = { 331, 8004 }, hostile = { 403 } },               -- Healing Wave, Lesser Healing Wave / Lightning Bolt
        WARLOCK = { friendly = { 20707, 5697 }, hostile = { 686 } },             -- Soulstone, Unending Breath / Shadow Bolt
        WARRIOR = { friendly = nil, hostile = { 355, 100 } },                    -- Taunt, Charge
    }
end

-- A table entry is one spell ID or a list of them; returns the first the player knows.
local function FirstKnownSpell(entry)
    if type(entry) == "table" then
        for _, id in ipairs(entry) do
            if IsPlayerSpell(id) then return id end
        end
        return nil
    end
    return entry and IsPlayerSpell(entry) and entry or nil
end

-- Appends each spell in `entry` (one ID or a list) that the player knows, skipping repeats.
local function AddKnownSpells(list, entry)
    if type(entry) ~= "table" then entry = { entry } end
    for _, id in ipairs(entry) do
        if id and IsPlayerSpell(id) then
            local seen = false
            for i = 1, #list do
                if list[i] == id then seen = true break end
            end
            if not seen then list[#list + 1] = id end
        end
    end
end

-- ============================================================
-- REZ SPELL TABLE
-- Used for accurate range checking on dead targets.
-- When a friendly target is dead, IsSpellInRange with the healing
-- spell returns nil. We try the class rez spell to give healers
-- accurate rez-range feedback on corpses.
-- Classes without a rez spell (DH, Hunter, Mage, Rogue, Warrior)
-- will fall through to CheckInteractDistance or show as OOR.
-- ============================================================
local rezSpellByClass = {
    DRUID       = 20484,   -- Rebirth (combat rez - IsSpellInRange works regardless of cooldown)
    PRIEST      = 2006,    -- Resurrection
    PALADIN     = { 7328, 391054 },  -- Redemption, Intercession
    SHAMAN      = 2008,    -- Ancestral Spirit
    MONK        = 115178,  -- Resuscitate
    DEATHKNIGHT = 61999,   -- Raise Ally
    WARLOCK     = 20707,   -- Soulstone
    EVOKER      = 361227,  -- Return
}

-- Resolved once at load time / spec change
local rezSpells = {}
local currentRezSpell = nil

-- Known range spells, in the order a unit is checked against them (rebuilt on spec,
-- talent and setting changes). currentFriendlySpell/currentHostileSpell are the first
-- of each: the spell the options page names.
local friendlySpells = {}
local hostileSpells = {}
local currentFriendlySpell = nil
local currentHostileSpell = nil
local currentSpecID = nil

-- "361469 (30yd), 355913 (30yd)" -- the live range, so a log line shows whether a
-- fallback spell shares the first one's edge.
local function DescribeSpells(list)
    if #list == 0 then return "none" end
    local parts = {}
    for i, id in ipairs(list) do
        local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        local range = info and info.maxRange
        parts[i] = id .. " (" .. (range and range > 0 and (math.floor(range) .. "yd") or "?yd") .. ")"
    end
    return table.concat(parts, ", ")
end

-- ============================================================
-- SPELL DETECTION & UPDATES
-- ============================================================

local function UpdateRangeSpell()
    local specIndex = GetSpecialization()
    local specID = specIndex and GetSpecializationInfo(specIndex) or nil
    currentSpecID = specID
    wipe(friendlySpells)
    wipe(hostileSpells)

    -- Check for user override in DB (check party first, then raid)
    local userSpellID = nil
    if DF.db then
        local partyDB = DF.db.party
        local raidDB = DF.db.raid
        -- Use party setting as the primary (both should be the same usually)
        if partyDB and partyDB.rangeCheckSpellID and partyDB.rangeCheckSpellID > 0 then
            userSpellID = partyDB.rangeCheckSpellID
        elseif raidDB and raidDB.rangeCheckSpellID and raidDB.rangeCheckSpellID > 0 then
            userSpellID = raidDB.rangeCheckSpellID
        end
    end

    -- A chosen spell goes first; the automatic list stays behind it, so a unit that spell
    -- cannot be checked against gets a spell answer rather than the ~40yd fallback.
    local source = "auto"
    if userSpellID and userSpellID > 0 then
        if IsPlayerSpell(userSpellID) then
            AddKnownSpells(friendlySpells, userSpellID)
            AddKnownSpells(hostileSpells, userSpellID)
            source = "user override"
        else
            -- Worth a WARN: the user picked this deliberately and it is silently not being
            -- used, which reads to them as the setting being ignored.
            DF:DebugWarn("RANGE", "user range spell %d is not known to this character - auto-detect will run instead", userSpellID)
        end
    end

    local autoFriendly, autoHostile = {}, {}
    local spells = specID and specSpells[specID]
    if spells then
        AddKnownSpells(autoFriendly, spells.friendly)
        AddKnownSpells(autoHostile, spells.hostile)
    end
    -- The class list covers an unknown spec and a spec whose spells are not learned yet.
    if #autoFriendly == 0 and #autoHostile == 0 and classFallbacks[playerClass] then
        spells = classFallbacks[playerClass]
        AddKnownSpells(autoFriendly, spells.friendly)
        AddKnownSpells(autoHostile, spells.hostile)
    end
    AddKnownSpells(friendlySpells, autoFriendly)
    AddKnownSpells(hostileSpells, autoHostile)
    currentFriendlySpell = friendlySpells[1]
    currentHostileSpell = hostileSpells[1]
    wipe(rezSpells)
    AddKnownSpells(rezSpells, rezSpellByClass[playerClass])
    currentRezSpell = rezSpells[1]

    if currentFriendlySpell or currentHostileSpell then
        DF:Debug("RANGE", "range spells (%s, spec %s): friendly=%s hostile=%s", source,
            tostring(specID), DescribeSpells(friendlySpells), DescribeSpells(hostileSpells))
        return
    end

    -- ☠ THE SILENT DEGRADE. With no spell on either side, range checking drops to
    -- CheckInteractDistance / always-in-range for the rest of the session: fading either
    -- stops working or sticks on. RANGE otherwise logs only transitions, so an empty log
    -- would read the same as a healthy session with nobody moving.
    DF:DebugWarn("RANGE", "no range spell for class %s (spec %s) - falling back to interact distance",
        tostring(playerClass), tostring(specID))
end

-- ============================================================
-- DEBUG SYSTEM
-- ============================================================

-- (verbose range tracing now lives in the debug console's RANGE category)
local debugStats = {
    checks = 0,
    cacheHits = 0,
    cacheMisses = 0,
    lastReset = time(),
}

-- Routed to the debug console's RANGE category.
local DebugPrint = DF:MakeDebugPrinter("RANGE")

local function ResetStats()
    debugStats.checks = 0
    debugStats.cacheHits = 0
    debugStats.cacheMisses = 0
    debugStats.lastReset = time()
end

-- ============================================================
-- CHANGE DETECTION CACHE
-- ============================================================

local rangeCache = {}


local function ClearRangeCache()
    wipe(rangeCache)
end

-- ============================================================
-- RANGE CHECK FUNCTION
-- Returns: inRange (boolean or secret boolean)
--   Spell-based checks return normal booleans (cacheable, fast).
--   UnitInRange fallback may return secret booleans (Midnight+)
--   which propagate through SetAlphaFromBoolean downstream.
--   Falls back to CheckInteractDistance when spells return nil.
-- ============================================================

-- ★ A HERO TALENT CAN REPLACE A RANGE SPELL (Living Flame -> Chrono Flame, Lightning Bolt
-- -> Tempest), and the base ID can then answer nil while the replacement answers. So a nil
-- is retried once as the spell's live override before the list moves on. Only on nil:
-- a spell that answers costs nothing extra.
local function SpellRangeAnswer(id, unit)
    local inRange = C_Spell_IsSpellInRange(id, unit)
    if inRange == nil and C_Spell_GetOverrideSpell then
        local override = C_Spell_GetOverrideSpell(id)
        if override and override ~= id then
            inRange = C_Spell_IsSpellInRange(override, unit)
        end
    end
    return inRange
end

-- ☠ THE "RANGE WENT TO 40 YARDS" LINE. Every known friendly spell answered nil on this
-- living unit, so UnitInRange (~40yd) is about to decide its fade instead of the spell.
-- Logged rather than surfaced: it is the detector for that report. One line per unit per 30s.
local lastFallbackNote = {}
local function NoteSpellFallback(unit)
    if not (DF.DebugActive and DF:DebugActive("RANGE")) then return end
    if UnitIsDeadOrGhost(unit) or not UnitIsConnected(unit) then return end
    local now = GetTime()
    if (lastFallbackNote[unit] or 0) + 30 > now then return end
    lastFallbackNote[unit] = now
    DF:DebugWarn("RANGE", "%s: no range spell answered (%s) - in combat the ~40yd UnitInRange fallback decides",
        unit, DescribeSpells(friendlySpells))
end

local function CheckUnitRange(unit)
    if UnitIsUnit(unit, "player") then
        return true
    end

    if not UnitExists(unit) then
        return true
    end

    -- Phased units are always out of range
    -- UnitPhaseReason returns nil for same-phase, a number if phased
    if UnitPhaseReason and UnitPhaseReason(unit) then
        return false
    end

    -- Branch on UnitCanAttack (not UnitCanAssist) to handle cross-faction party members.
    -- In the open world, cross-faction group members may have UnitCanAssist=false
    -- but UnitCanAttack is also false (they're in your group). Using UnitCanAttack
    -- ensures they fall through to the friendly path.
    if UnitCanAttack("player", unit) then
        -- HOSTILE UNITS: IsSpellInRange returns clean booleans, trust directly
        for i = 1, #hostileSpells do
            local inRange = SpellRangeAnswer(hostileSpells[i], unit)
            if inRange ~= nil then
                return inRange
            end
        end
        -- No hostile spell or none answered - assume in range
        return true
    end

    -- FRIENDLY UNITS (party/raid members)
    -- IsSpellInRange returns clean booleans - NOT secret values.
    -- We trust the result directly (== true/false).
    -- First spell that answers decides; nil means that spell can't be checked against
    -- this unit (dead, offline, a location-placed spell), so the next one gets a turn.
    local nFriendly = #friendlySpells
    for i = 1, nFriendly do
        local inRange = SpellRangeAnswer(friendlySpells[i], unit)
        if inRange == true then
            return true
        elseif inRange == false then
            -- Spell says OOR; OR with CheckInteractDistance out of combat
            -- for leniency (avoids false OOR from spec/talent edge cases).
            -- Gated behind !InCombat, as LibRangeCheck does.
            if not InCombatLockdown() and CheckInteractDistance(unit, 4) then
                return true
            end
            return false
        end
    end

    -- Dead target: try rez spell for accurate range on corpses
    if UnitIsDeadOrGhost(unit) then
        for i = 1, #rezSpells do
            local inRange = SpellRangeAnswer(rezSpells[i], unit)
            if inRange ~= nil then
                return inRange
            end
        end
    end

    -- No spell result available.
    -- Out of combat: CheckInteractDistance (~28yd follow distance)
    -- CheckInteractDistance is avoided in combat (as LibRangeCheck does).
    if not InCombatLockdown() then
        return CheckInteractDistance(unit, 4) and true or false
    end

    -- IN COMBAT FALLBACKS:
    if nFriendly > 0 then
        NoteSpellFallback(unit)
    end

    -- UnitInRange as primary combat fallback (returns secret booleans in Midnight+)
    -- Secret booleans propagate through the pipeline:
    --   dfInRange → GetInRange → SetAlphaFromBoolean → SetAlpha
    -- This gives DK/DH/Hunter/Warrior actual range fading in combat,
    -- AND acts as a safety net when IsSpellInRange returns nil transiently.
    if UnitInRange then
        local inRange = UnitInRange(unit)
        if issecretvalue and issecretvalue(inRange) then
            return inRange  -- Secret boolean, handled by SetAlphaFromBoolean downstream
        end
        if inRange ~= nil then
            return inRange  -- Normal boolean
        end
    end

    -- If UnitInRange also failed (non-grouped unit, or API unavailable),
    -- and we had a friendly spell that returned nil on a living connected
    -- target, they're likely extremely far away — treat as out of range.
    if nFriendly > 0 and UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit) then
        DebugPrint("OOR-NIL", unit, "spell AND UnitInRange both failed on alive/connected target in combat")
        return false
    end

    -- No method available or inconclusive — assume in range.
    -- For classes without friendly spells, in combat this is effectively
    -- "return InCombat or CheckInteractDistance(unit, 4)", which is always true.
    return true
end

-- ============================================================
-- APPLY RANGE ALPHA TO A FRAME
-- ============================================================

function DF:UpdateRange(frame)
    if not frame or not frame.unit then return end
    
    if DF:MemTestDisabled("enableRange") then return end
    if DF.testMode or DF.raidTestMode then return end
    
    local unit = frame.unit

    -- Player is always in range — skip all checks and cache logic.
    -- dfInRange may hold a secret boolean from a previous UnitInRange
    -- fallback (Midnight+), so check issecretvalue before boolean-testing
    -- it — `not <secret>` raises "execution tainted" and spams errors.
    if UnitIsUnit(unit, "player") then
        local dfSecret = issecretvalue and issecretvalue(frame.dfInRange)
        if dfSecret or frame.dfInRange ~= true then
            frame.dfInRange = true
            if DF.UpdateRangeAppearance then
                DF:UpdateRangeAppearance(frame)
            end
        end
        return
    end

    if not IsInGroup() and not IsInRaid() then
        local dfSecret = issecretvalue and issecretvalue(frame.dfInRange)
        if dfSecret or frame.dfInRange ~= true then
            frame.dfInRange = true
            if DF.UpdateRangeAppearance then
                DF:UpdateRangeAppearance(frame)
            end
        end
        return
    end

    local inRange = CheckUnitRange(unit)
    
    debugStats.checks = debugStats.checks + 1
    
    -- Cache comparison: secret values (from UnitInRange fallback) can't be
    -- compared with == so we always update when secrets are involved.
    -- Spell-based results are normal booleans and cache efficiently.
    local cached = rangeCache[unit]
    local isSecret = issecretvalue and (issecretvalue(inRange) or issecretvalue(cached))
    if not isSecret and cached == inRange then
        debugStats.cacheHits = debugStats.cacheHits + 1
        -- (Removed) a "SKIP <unit> cached:<v>" line here. It fired on the cache-HIT
        -- branch, i.e. it logged that NOTHING changed, once per unit per
        -- UNIT_IN_RANGE_UPDATE — hundreds of lines a second in a moving raid, every
        -- one of them uninteresting, and they evicted the real trace under maxLines.
        -- The cache-MISS branch below already logs the transition, which is the event
        -- anyone reading RANGE actually wants. debugStats.cacheHits still counts them
        -- for /df debug range.
        -- Still need to update THIS frame if it hasn't been initialized
        -- (multiple frames can share the same unit, e.g. pinned frames)
        local dfSecret = issecretvalue and issecretvalue(frame.dfInRange)
        if dfSecret or frame.dfInRange ~= inRange then
            frame.dfInRange = inRange
            if DF.UpdateRangeAppearance then
                DF:UpdateRangeAppearance(frame)
            end
        end
        return
    end

    debugStats.cacheMisses = debugStats.cacheMisses + 1
    rangeCache[unit] = inRange
    DebugPrint("UPDATE", unit, "was:", tostring(cached), "now:", tostring(inRange))

    -- ☠ AURA SNAPSHOT AT THE RANGE EDGE — the one moment that answers "did the aura
    -- really persist, or did Only Mine stop filtering?", and the one moment nobody can
    -- type a command in. Lives on the cache-MISS branch so it fires once per real
    -- crossing, not once per range check. Self-gated on the RANGE debug channel
    -- (costs nothing while off) and pcall'd, because a diagnostic must never be able to
    -- break the range pass it rides on. See AuraContainer.NoteRangeTransition for how
    -- to read the pair of lines it produces.
    if DF.AuraContainer and DF.AuraContainer.NoteRangeTransition then
        pcall(DF.AuraContainer.NoteRangeTransition, unit, inRange)
    end

    -- ★★ COMING BACK INTO RANGE CLEARS A STALE VISIBILITY LATCH. The reconcile otherwise runs
    -- only on PLAYER_REGEN_ENABLED and PLAYER_ENTERING_WORLD, and a party member walking out
    -- of visible range and back produces neither, so out of combat the latch would never
    -- clear and their Aura Designer indicators would stay dark until a reload.
    -- ⚠ THIS PATH IS THE RIGHT ONE because it is the only place that knows a unit came BACK.
    -- Range-in is strictly stronger than visible (spell range is inside the render radius),
    -- and the verb re-asks UnitIsVisible anyway rather than trusting the implication.
    -- ⚠ Costs one table lookup when the unit is not latched: ReconcileUnitLatch reads the
    -- registry before it touches the API. pcall'd so a heal can never break the range pass.
    -- ☠☠ issecretvalue FIRST, AS ITS OWN STATEMENT: `inRange` comes from the UnitInRange
    -- fallback and CAN be secret, and a bare `if inRange then` would throw and take the range
    -- pass with it. The local `isSecret` above is not the right test -- it folds in the
    -- CACHED value, so it reads true beside a clean inRange and would skip a possible heal.
    -- ⚠ A secret read simply does not heal here; the 3s tick is the net under it.
    local rangeSecret = issecretvalue and issecretvalue(inRange) or false
    if not rangeSecret and inRange
        and DF.AuraContainer and DF.AuraContainer.ReconcileUnitLatch then
        pcall(DF.AuraContainer.ReconcileUnitLatch, unit)
    end

    frame.dfInRange = inRange

    if DF.UpdateRangeAppearance then
        DF:UpdateRangeAppearance(frame)
    end

end

-- ============================================================
-- PET FRAME RANGE UPDATES
-- ============================================================

function DF:UpdatePetRange(frame)
    if not frame or not frame.unit then return end
    if not UnitExists(frame.unit) then return end
    
    local db = DF:GetFrameDB(frame)
    if not db then return end
    
    local ownerUnit = frame.ownerUnit
    if not ownerUnit then return end
    
    local inRange = true
    if UnitExists(ownerUnit) and not UnitIsUnit(ownerUnit, "player") then
        if IsInGroup() or IsInRaid() then
            inRange = CheckUnitRange(ownerUnit)
        end
    end
    
    local cacheKey = "pet_" .. frame.unit
    local cached = rangeCache[cacheKey]
    local isSecret = issecretvalue and (issecretvalue(inRange) or issecretvalue(cached))
    if not isSecret and cached == inRange then
        return
    end
    rangeCache[cacheKey] = inRange

    frame.dfInRange = inRange

    -- ⚠ 0.4, matching every other consumer and the Config default. This read 0.55, a
    -- value that appears nowhere else: ElementAppearance and HealthFade both use
    -- `db.rangeFadeAlpha or 0.4` and Core/Config seeds 0.4. Invisible while the key is
    -- present, wrong on an old import or a hand-edited SavedVariables.
    local outOfRangeAlpha = db.rangeFadeAlpha or 0.4

    -- ☠ FRAME ONLY -- NOT the health bar as well.
    -- The pet health bar is a plain child (CreateFrame("StatusBar", nil, frame),
    -- SetAllPoints) with no SetIgnoreParentAlpha, so setting BOTH multiplied the fades
    -- together: 0.4 x 0.4 = 0.16 on the bar and the name/health text parented to it, while
    -- the frame itself sat at 0.4. HealthFade.lua's own header states the rule this broke --
    -- "only set frame:SetAlpha (cascades to children). Do NOT also set healthBar:SetAlpha
    -- or the alpha double-stacks."
    --
    -- SetAlphaFromBoolean handles the secret boolean UnitInRange returns for non-healer
    -- specs on Midnight+; the plain branch is the pre-12.1 fallback.
    -- Frame Fade base (ElementAppearance) multiplied in, so a pet recedes with its owner.
    local base = DF.GetFrameBaseAlpha and DF:GetFrameBaseAlpha(db, frame) or 1
    if frame.SetAlphaFromBoolean then
        frame:SetAlphaFromBoolean(inRange, base, outOfRangeAlpha * base)
    else
        frame:SetAlpha(inRange and base or outOfRangeAlpha * base)
    end
end

-- ============================================================
-- PET RANGE HELPER
-- UNIT_IN_RANGE_UPDATE doesn't fire for pet units. When the
-- owner's range event fires we piggyback a pet range update.
-- ============================================================

local function UpdatePetForOwner(ownerUnit)
    if ownerUnit == "player" then
        -- Player's own pet
        if DF.petFrames and DF.petFrames.player then
            local petFrame = DF.petFrames.player
            if not petFrame.dfPetHidden then
                DF:UpdatePetRange(petFrame)
            end
        end
    else
        -- Party/raid pet — parse the index from the owner unit token
        local prefix, index = ownerUnit:match("^(%a+)(%d+)$")
        if not index then return end
        index = tonumber(index)

        if prefix == "party" and DF.partyPetFrames then
            local petFrame = DF.partyPetFrames[index]
            if petFrame and not petFrame.dfPetHidden then
                DF:UpdatePetRange(petFrame)
            end
        elseif prefix == "raid" and DF.raidPetFrames then
            local petFrame = DF.raidPetFrames[index]
            if petFrame and not petFrame.dfPetHidden then
                DF:UpdatePetRange(petFrame)
            end
        end
    end
end

-- ============================================================
-- RANGE UPDATE TIMER
-- Safety-net polling that runs alongside UNIT_IN_RANGE_UPDATE.
-- The event gives instant response for Blizzard's ~38yd range,
-- but doesn't cover spell-based ranges or all edge cases.
-- Event plus polling, both kept for reliability.
-- ============================================================

local rangeAnimFrame = CreateFrame("Frame")
local rangeAnimGroup = rangeAnimFrame:CreateAnimationGroup()
local rangeAnim = rangeAnimGroup:CreateAnimation()
rangeAnim:SetDuration(0.5)  -- Default 0.5s. Configurable via options.
rangeAnimGroup:SetLooping("REPEAT")

-- Hoisted callback - avoids creating a new closure every tick
local function RangeCheckFrame(frame)
    if frame and frame:IsShown() then
        DF:UpdateRange(frame)
        if DF.UpdateHealthFade then
            DF:UpdateHealthFade(frame)
        end
    end
end

rangeAnimGroup:SetScript("OnLoop", function()
    if DF:MemTestDisabled("enableRange") then return end
    -- Any group header, not DF.partyHeader: party frames can be disabled.
    if not (DF.GroupHeadersReady and DF:GroupHeadersReady()) then return end

    local contentType = DF:GetContentType()

    if contentType == "arena" then
        -- Arena: arena frames + the ARENA pet track. (Highlights are still excluded.)
        if DF.IterateArenaFrames then
            DF:IterateArenaFrames(RangeCheckFrame)
        end
        -- ☠ ARENA PETS WERE OMITTED ENTIRELY. DF.arenaPetFrames appeared nowhere in this
        -- file: the branch above said "no pets" and the event helper maps a raidN owner
        -- straight to DF.raidPetFrames -- the HIDDEN track in arena, not the arena one. So
        -- in a 3v3 every arena unit frame faded and the pet frames under them stayed at
        -- full brightness for the whole match.
        --
        -- SetPetFrameVisible explicitly hands alpha ownership to the range system ("Set to 1
        -- so range system can take over"), and in arena nothing ever took over. Same
        -- omission class the pets file already fixed once for Anchor / Offset X / Offset Y.
        -- 1..5 rather than #arenaPetFrames: the table is sparse (a slot exists only once
        -- that arena pet has been created), so the length operator is unreliable. Every
        -- other consumer in Pets.lua walks it the same way.
        if DF.arenaPetFrames then
            for i = 1, 5 do
                local frame = DF.arenaPetFrames[i]
                if frame and not frame.dfPetHidden then
                    DF:UpdatePetRange(frame)
                    if DF.UpdatePetHealthFade then
                        DF:UpdatePetHealthFade(frame)
                    end
                end
            end
        end
    elseif contentType then
        -- Raid content (battleground/mythic/instanced/openWorld): raid frames + raid pets
        DF:IterateRaidFrames(RangeCheckFrame)

        -- Raid pinned frames (only if initialized for raid mode and header is shown/enabled)
        if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.currentMode == "raid" then
            for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
                local header = DF.PinnedFrames.headers[setIndex]
                if header and header:IsShown() then
                    for i = 1, 40 do
                        local child = header:GetAttribute("child" .. i)
                        if child then
                            RangeCheckFrame(child)
                        end
                    end
                end
            end
        end

        if DF.raidPetFrames then
            for i = 1, 40 do
                local frame = DF.raidPetFrames[i]
                if frame and not frame.dfPetHidden then
                    DF:UpdatePetRange(frame)
                    if DF.UpdatePetHealthFade then
                        DF:UpdatePetHealthFade(frame)
                    end
                end
            end
        end
    else
        -- Party/solo: party frames + player pet + party pets
        DF:IteratePartyFrames(RangeCheckFrame)

        -- Party pinned frames (only if initialized for party mode and header is shown/enabled)
        if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.currentMode == "party" then
            for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
                local header = DF.PinnedFrames.headers[setIndex]
                if header and header:IsShown() then
                    for i = 1, 5 do
                        local child = header:GetAttribute("child" .. i)
                        if child then
                            RangeCheckFrame(child)
                        end
                    end
                end
            end
        end

        if DF.petFrames and DF.petFrames.player then
            local petFrame = DF.petFrames.player
            if not petFrame.dfPetHidden then
                DF:UpdatePetRange(petFrame)
                if DF.UpdatePetHealthFade then
                    DF:UpdatePetHealthFade(petFrame)
                end
            end
        end

        if DF.partyPetFrames then
            for i = 1, 4 do
                local frame = DF.partyPetFrames[i]
                if frame and not frame.dfPetHidden then
                    DF:UpdatePetRange(frame)
                    if DF.UpdatePetHealthFade then
                        DF:UpdatePetHealthFade(frame)
                    end
                end
            end
        end
    end

    -- Pinned boss frames (work in both raid and party content — independent of group type).
    -- Boss units don't fire UNIT_IN_RANGE_UPDATE, so polling is the only way to detect range.
    if contentType and contentType ~= "arena" and DF.PinnedFrames and DF.PinnedFrames.bossFrames then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local frames = DF.PinnedFrames.bossFrames[setIndex]
            if frames then
                for i = 1, 8 do
                    local f = frames[i]
                    if f and f:IsShown() then
                        RangeCheckFrame(f)
                    end
                end
            end
        end
    end
end)

-- ============================================================
-- EVENT HANDLERS
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

-- Lazy-cached reference to unitFrameMap (populated by Headers.lua after load)
local unitFrameMap

-- UNIT_IN_RANGE_UPDATE is routed through the roster unit event dispatcher
-- (RosterEvents.lua) so it only fires for player/partyN/raidN — never for
-- nameplates, target, focus, mouseover, or any other unit token: the per-unit
-- cost adds up enough during movement to justify the C++-level filter.
local rangeSubscriber = {}
function rangeSubscriber:OnUnitInRange(event, unit)
    if not unit then return end
    -- Player frame doesn't need range updates (always in range of itself).
    if unit == "player" then return end

    -- Lazy-init the unitFrameMap reference
    if not unitFrameMap then
        unitFrameMap = DF.unitFrameMap
        if not unitFrameMap then return end
    end

    -- Main frame: O(1) lookup
    local frame = unitFrameMap[unit]
    if frame and frame:IsShown() then
        DF:UpdateRange(frame)
    end

    -- Pinned frames: may show the same unit on a second frame
    if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local header = DF.PinnedFrames.headers[setIndex]
            if header and header:IsShown() then
                local maxChildren = DF.PinnedFrames.currentMode == "raid" and 40 or 5
                for i = 1, maxChildren do
                    -- Precomputed attribute name: per UNIT_IN_RANGE_UPDATE.
                    local child = header:GetAttribute(DF.CHILD_ATTR[i])
                    if child and child:IsShown() and child.unit == unit then
                        DF:UpdateRange(child)
                    end
                end
            end
        end
    end

    -- Pinned boss frames: UNIT_IN_RANGE_UPDATE doesn't fire for boss units in
    -- practice, but register here as fallback coverage if Blizzard changes behavior.
    if DF.PinnedFrames and DF.PinnedFrames.bossFrames then
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            local frames = DF.PinnedFrames.bossFrames[setIndex]
            if frames then
                for i = 1, 8 do
                    local f = frames[i]
                    if f and f:IsShown() and f.unit == unit then
                        DF:UpdateRange(f)
                    end
                end
            end
        end
    end

    -- Pet frames: UNIT_IN_RANGE_UPDATE doesn't fire for pets,
    -- but pet range is derived from the owner — update it here.
    UpdatePetForOwner(unit)
end
DF:RegisterRosterUnitEvent(rangeSubscriber, "UNIT_IN_RANGE_UPDATE", "OnUnitInRange")

-- ★ RE-SEED ON THE EDGES UNIT_IN_RANGE_UPDATE DOES NOT COVER. Phasing and connection
-- changes move a unit's range answer (CheckUnitRange reads UnitPhaseReason; an offline
-- unit re-connecting comes back with whatever it last had) without firing the range
-- event, and the appearance chain only re-runs when the cached answer CHANGES -- so
-- until the poll happened to disagree with the cache, the frame kept the old alpha.
-- Forget the unit's cache and the frame's stamp, then re-evaluate: UpdateRange sees a
-- change no matter what the answer is and re-drives the whole element chain. Same
-- shape as the roster re-assignment reset in Frames/Headers.lua. Rare events, so the full sweep of a
-- unit's frames (main + pinned) is affordable.
function rangeSubscriber:OnUnitRangeReseed(event, unit)
    if not unit or unit == "player" then return end
    DF:ClearRangeCacheForUnit(unit)
    if not unitFrameMap then
        unitFrameMap = DF.unitFrameMap
        if not unitFrameMap then return end
    end
    local frame = unitFrameMap[unit]
    if frame and frame:IsShown() then
        frame.dfInRange = nil
        DF:UpdateRange(frame)
    end
    -- Pinned frames (both pools) through the shared walker: a pinned set may show the
    -- same unit on a second frame, and a party-mode set can hold more than five.
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(function(child)
            if child.unit == unit then
                child.dfInRange = nil
                DF:UpdateRange(child)
            end
        end)
    end
    UpdatePetForOwner(unit)
end
DF:RegisterRosterUnitEvent(rangeSubscriber, "UNIT_PHASE", "OnUnitRangeReseed")
DF:RegisterRosterUnitEvent(rangeSubscriber, "UNIT_CONNECTION", "OnUnitRangeReseed")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
        local unit = ...
        -- PLAYER_TALENT_UPDATE fires without a unit arg, so always update
        if event == "PLAYER_TALENT_UPDATE" or unit == "player" then
            UpdateRangeSpell()
            ClearRangeCache()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Initialize range spell on login/reload
        UpdateRangeSpell()
        ClearRangeCache()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        -- Clear cache on combat transitions so stale values from a different
        -- combat state don't persist (e.g. CheckInteractDistance results from
        -- out-of-combat shouldn't carry into combat where that API is unavailable)
        ClearRangeCache()
    end
end)

-- ============================================================
-- START TIMER & INITIALIZE
-- ============================================================

-- Also initialize immediately in case we loaded late
UpdateRangeSpell()

C_Timer.After(1, function()
    -- Re-check after 1 second to ensure spec info is available
    UpdateRangeSpell()
    -- Apply configured interval from DB (default 0.5s)
    if DF.db then
        local db = DF:GetDB()
        local interval = db and db.rangeUpdateInterval or 0.5
        rangeAnim:SetDuration(interval)
    end
    rangeAnimGroup:Play()
end)

-- Called by Options panel when user changes the range update interval slider
function DF:SetRangeUpdateInterval(interval)
    interval = interval or 0.5
    rangeAnim:SetDuration(interval)
end

-- ============================================================
-- API FOR OPTIONS UI
-- ============================================================

-- Get list of available spells for dropdown
function DF:GetRangeSpellOptions()
    local options = {
        { value = 0, label = "Auto (Spec Default)" }
    }
    
    -- Helper to get actual spell range from spell data (accounts for talents)
    local function GetSpellRange(spellID, fallback)
        if spellID and C_Spell.GetSpellInfo then
            local spellInfo = C_Spell.GetSpellInfo(spellID)
            if spellInfo and spellInfo.maxRange and spellInfo.maxRange > 0 then
                return math.floor(spellInfo.maxRange) .. "yd"
            end
        end
        return fallback or "?yd"
    end
    
    -- Add spec default info
    if currentSpecID and specSpells[currentSpecID] then
        local spells = specSpells[currentSpecID]
        if spells.friendly then
            local autoID = FirstKnownSpell(spells.friendly)
                or (type(spells.friendly) == "table" and spells.friendly[1] or spells.friendly)
            local name = C_Spell_GetSpellName(autoID)
            if name then
                options[1].label = "Auto: " .. name .. " (" .. GetSpellRange(autoID, spells.range) .. ")"
            end
        else
            -- Classes without friendly spells (DK, DH, Hunter, Warrior)
            -- use UnitInRange/CheckInteractDistance as fallback
            options[1].label = "Auto: UnitInRange (~40yd)"
        end
    end
    
    -- Common healing spells for manual selection
    local commonSpells = {
        -- Healer spells
        { id = 774,    name = "Rejuvenation",       class = "DRUID" },
        { id = 8936,   name = "Regrowth",            class = "DRUID" },
        { id = 2061,   name = "Flash Heal",          class = "PRIEST" },
        { id = 17,     name = "Power Word: Shield",  class = "PRIEST" },
        { id = 8004,   name = "Healing Surge",       class = "SHAMAN" },
        { id = 19750,  name = "Flash of Light",      class = "PALADIN" },
        { id = 116670, name = "Vivify",              class = "MONK" },
        { id = 361469, name = "Living Flame",        class = "EVOKER" },
        { id = 355913, name = "Emerald Blossom",     class = "EVOKER" },
        -- Utility spells
        { id = 1459,   name = "Arcane Intellect",    class = "MAGE" },
        { id = 20707,  name = "Soulstone",           class = "WARLOCK" },
    }
    
    -- Filter to show only spells the player knows or all if they want
    for _, spell in ipairs(commonSpells) do
        if IsPlayerSpell(spell.id) or spell.class == playerClass then
            local name = C_Spell_GetSpellName(spell.id) or spell.name
            table.insert(options, {
                value = spell.id,
                label = name .. " (" .. GetSpellRange(spell.id) .. ")"
            })
        end
    end
    
    return options
end

-- Called when user changes the range spell setting
function DF:SetRangeCheckSpell(spellID)
    -- Note: The Options dropdown already sets the value in the mode-specific db
    -- This function just triggers the update
    UpdateRangeSpell()
    ClearRangeCache()
end

-- Get current range spell info for display
function DF:GetCurrentRangeSpellInfo()
    local spellID = currentFriendlySpell or currentHostileSpell
    local spellName, range

    if currentFriendlySpell then
        -- Has a friendly spell - show it with actual range
        spellName = C_Spell_GetSpellName(currentFriendlySpell) or "Unknown"
        if C_Spell.GetSpellInfo then
            local spellInfo = C_Spell.GetSpellInfo(currentFriendlySpell)
            if spellInfo and spellInfo.maxRange and spellInfo.maxRange > 0 then
                range = math.floor(spellInfo.maxRange) .. "yd"
            end
        end
    else
        -- No friendly spell (DK, DH, Hunter, Warrior) - show fallback method
        spellName = "UnitInRange"
        range = "~40yd"
    end

    -- Fallback to hardcoded range if nothing found yet
    if not range and currentSpecID and specSpells[currentSpecID] then
        range = specSpells[currentSpecID].range or "40yd"
    end
    range = range or "Unknown"
    
    -- Check if using custom override or auto
    local isCustom = false
    local userSpellID = nil
    if DF.db then
        local partyDB = DF.db.party
        local raidDB = DF.db.raid
        if partyDB and partyDB.rangeCheckSpellID and partyDB.rangeCheckSpellID > 0 then
            userSpellID = partyDB.rangeCheckSpellID
        elseif raidDB and raidDB.rangeCheckSpellID and raidDB.rangeCheckSpellID > 0 then
            userSpellID = raidDB.rangeCheckSpellID
        end
    end
    
    if userSpellID and userSpellID > 0 then
        isCustom = true
    end
    
    return {
        spellID = spellID,
        spellName = spellName or "None",
        range = range,
        specID = currentSpecID,
        isCustom = isCustom,
    }
end

-- Force update (for options panel)
function DF:RefreshRangeSpell()
    UpdateRangeSpell()
    ClearRangeCache()
end

-- ============================================================
-- SLASH COMMANDS
-- ============================================================

DF:RegisterDebugSlash("DFRANGE", "Range fading diagnostics", false, "/dfrange")
SlashCmdList["DFRANGE"] = function(msg)
    local cmd = msg:lower():trim()
    
    if cmd == "debug" then
        DF:Say("Range tracing is in the debug console", "enable the RANGE category", "NEUTRAL")

    elseif cmd == "stats" then
        local elapsed = time() - debugStats.lastReset
        local total = debugStats.cacheHits + debugStats.cacheMisses
        local hitRate = total > 0 and math.floor((debugStats.cacheHits / total) * 100) or 0

        local o = DF:Out("Range", "last " .. elapsed .. "s")
        o:Section("Cache")
        o:Field("checks", debugStats.checks, "NEUTRAL")
        o:Field("hits", debugStats.cacheHits, "GOOD")
        -- A miss is normal traffic, not a fault, so it stays neutral; the HIT RATE
        -- is the number worth colouring, and only WARN once it is actually poor.
        o:Field("misses", debugStats.cacheMisses, "NEUTRAL")
        o:Field("hit rate", hitRate .. "%", hitRate >= 70 and "GOOD" or "WARN")
        o:Siblings("range")

    elseif cmd == "clear" then
        ClearRangeCache()
        ResetStats()
        DF:Say("Range cache cleared")

    elseif cmd == "spell" then
        local info = DF:GetCurrentRangeSpellInfo()
        local specIndex = GetSpecialization()
        local specID = specIndex and GetSpecializationInfo(specIndex) or nil
        local o = DF:Out("Range", "current spell")
        local function spellLine(id)
            if not id then return "none", "WARN" end
            return id .. " (" .. (C_Spell_GetSpellName(id) or "?") .. ")", "GOOD"
        end

        o:Section("Spec")
        o:Field("class", tostring(playerClass), "NEUTRAL")
        o:Field("spec", tostring(specID) .. " (index " .. tostring(specIndex) .. ")", "NEUTRAL")
        -- A cached spec ID that has drifted from the live one means the range spell
        -- was resolved for the wrong spec, which is a real fault worth flagging.
        o:Field("cached spec", tostring(currentSpecID), currentSpecID == specID and "GOOD" or "BAD")

        o:Section("Resolved spells")
        o:Field("friendly", spellLine(currentFriendlySpell))
        if #friendlySpells > 1 then
            o:Field("then tried", DescribeSpells({ select(2, unpack(friendlySpells)) }), "NEUTRAL")
        end
        o:Field("hostile", spellLine(currentHostileSpell))
        o:Field("rez", spellLine(currentRezSpell))

        o:Section("Display")
        o:Field("showing", (info.spellName or "none") .. " (" .. (info.range or "?") .. ")",
            info.spellName and "GOOD" or "WARN")
        o:Field("custom override", info.isCustom, info.isCustom and "WARN" or "NEUTRAL")
        o:Field("timer interval", tostring(rangeAnim:GetDuration()) .. "s", "NEUTRAL")
        if DF.db then
            o:Field("saved spell ID", "party " .. tostring(DF.db.party and DF.db.party.rangeCheckSpellID or "none")
                .. ", raid " .. tostring(DF.db.raid and DF.db.raid.rangeCheckSpellID or "none"), "NEUTRAL")
        end
        if UnitExists("party1") then
            for _, id in ipairs(friendlySpells) do
                local testResult = SpellRangeAnswer(id, "party1")
                o:Field("live test on party1: " .. id, tostring(testResult), testResult ~= nil and "GOOD" or "BAD")
            end
        end
        o:Siblings("range")

    elseif cmd == "dump" then
        local entries = {}
        for unit, inRange in pairs(rangeCache) do
            entries[#entries + 1] = unit .. " = " .. DF.OUT[inRange and "GOOD" or "NEUTRAL"]
                .. tostring(inRange) .. "|r"
        end
        table.sort(entries)
        local o = DF:Out("Range", "cache")
        o:Section("Entries", #entries)
        o:More(entries, 12, "/df debug range stats")
        o:Siblings("range")

    else
        local o = DF:Out("Range")
        o:Section("Commands")
        o:Item("stats", "cache hit/miss counters")
        o:Item("spell", "which range spell resolved, and why")
        o:Item("dump", "cache contents")
        o:Item("clear", "clear the cache and reset counters")
        o:Line("Ongoing tracing is in the debug console — enable the RANGE category.", "NEUTRAL")
        o:Hints("/df debug range spell", "/df console")
    end
end

-- ============================================================
-- LEGACY API
-- ============================================================

function DF:ClearRangeCache()
    ClearRangeCache()
end

-- Clear range cache for a single unit (used when unit assignment changes on a frame)
function DF:ClearRangeCacheForUnit(unit)
    if unit then
        rangeCache[unit] = nil
        rangeCache["pet_" .. unit] = nil  -- Also clear pet cache for this unit
    end
end
