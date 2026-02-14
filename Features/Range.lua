local addonName, DF = ...

-- ============================================================
-- OUT OF RANGE ALPHA SYSTEM
-- Fades frames/elements when party members are out of range
--
-- RANGE CHECK STRATEGY:
-- 1. IsSpellInRange() - Primary check using spec-specific spells.
--    Validated with IsPlayerSpell() to handle talent/spec changes.
--    Returns normal booleans that are fully cacheable.
--    Cache avoids redundant appearance updates for performance.
--    Guarded with issecretvalue() in case Midnight+ taints these returns.
-- 2. CheckInteractDistance() - Fallback when out of combat and
--    IsSpellInRange returns nil (no spell, target dead/offline/phased).
-- 3. NIL-ON-ALIVE: If a friendly spell returned nil on an alive, connected
--    target during combat, treat as OUT OF RANGE. IsSpellInRange returns nil
--    (not false) for extremely distant targets outside the game's position-
--    awareness range, and the old fallback chain defaulted to "in range".
-- 4. UnitInRange() - In-combat fallback for classes with no friendly
--    spell (Warrior, DH, Hunter). Returns secret values in Midnight+
--    so we check with issecretvalue() before using the result.
--    If non-secret and says OOR, we trust it. If secret, assume in range.
-- 5. If no method available → in range (better than fading entire raid).
--
-- NOTE: UnitInRange() is only used as a last-resort fallback for classes
-- with no friendly spell (Warrior, DH, Hunter) during combat. In Midnight
-- it can return "secret" values, so we guard with issecretvalue() and only
-- use clean boolean results. The primary spell-based approach avoids secrets.
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
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local CheckInteractDistance = CheckInteractDistance
local C_Spell = C_Spell
local C_Spell_IsSpellInRange = C_Spell.IsSpellInRange
local C_Spell_GetSpellName = C_Spell.GetSpellName
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsConnected = UnitIsConnected
local UnitInRange = UnitInRange
local issecretvalue = issecretvalue  -- nil pre-Midnight, function in Midnight+

-- Player info
local _, playerClass = UnitClass("player")

-- ============================================================
-- SPEC-BASED RANGE SPELLS
-- Indexed by specID - validated with IsPlayerSpell() before use
-- Format: { friendly = spellID, hostile = spellID, range = "description" }
-- ============================================================

local specSpells = {
    -- ==================== DEATH KNIGHT ====================
    [250] = { -- Blood
        friendly = 47541,   -- Death Coil (can heal undead allies, works on DK)
        hostile = 47541,    -- Death Coil
        range = "40yd"
    },
    [251] = { -- Frost
        friendly = 47541,
        hostile = 47541,
        range = "40yd"
    },
    [252] = { -- Unholy
        friendly = 47541,
        hostile = 47541,
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
    -- Devourer (new Midnight spec - ranged DPS, 25yd, Intellect-based)
    -- specID TBD - using placeholder, will need update when known
    [1456] = { -- Devourer (specID placeholder - update when known)
        friendly = nil,
        hostile = 452416,   -- Consume (25yd Void spell) - spellID may need update
        range = "25yd"
    },
    
    -- ==================== DRUID ====================
    [102] = { -- Balance
        friendly = 8936,    -- Regrowth (all druids have it in class tree)
        hostile = 8921,     -- Moonfire
        range = "40yd"
    },
    [103] = { -- Feral
        friendly = 8936,    -- Regrowth
        hostile = 8921,
        range = "40yd"
    },
    [104] = { -- Guardian
        friendly = 8936,    -- Regrowth
        hostile = 8921,
        range = "40yd"
    },
    [105] = { -- Restoration
        friendly = 774,     -- Rejuvenation (instant cast, better for healers)
        hostile = 8921,
        range = "40yd"
    },
    
    -- ==================== EVOKER ====================
    [1467] = { -- Devastation
        friendly = 360995,  -- Emerald Blossom (all evokers)
        hostile = 361469,   -- Living Flame
        range = "25yd"
    },
    [1468] = { -- Preservation
        friendly = 355913,  -- Emerald Blossom (rank 2)
        hostile = 361469,
        range = "25yd"      -- Note: Evoker has shorter range!
    },
    [1473] = { -- Augmentation
        friendly = 360995,
        hostile = 361469,
        range = "25yd"
    },
    
    -- ==================== HUNTER ====================
    [253] = { -- Beast Mastery
        friendly = nil,
        hostile = 193455,   -- Cobra Shot
        range = "40yd"
    },
    [254] = { -- Marksmanship
        friendly = nil,
        hostile = 19434,    -- Aimed Shot
        range = "40yd"
    },
    [255] = { -- Survival
        friendly = nil,
        hostile = 259491,   -- Kill Command (ranged version)
        range = "40yd"
    },
    
    -- ==================== MAGE ====================
    [62] = { -- Arcane
        friendly = 1459,    -- Arcane Intellect
        hostile = 30451,    -- Arcane Blast
        range = "40yd"
    },
    [63] = { -- Fire
        friendly = 1459,
        hostile = 133,      -- Fireball
        range = "40yd"
    },
    [64] = { -- Frost
        friendly = 1459,
        hostile = 116,      -- Frostbolt
        range = "40yd"
    },
    
    -- ==================== MONK ====================
    [268] = { -- Brewmaster
        friendly = 116670,  -- Vivify (all monks)
        hostile = 115546,   -- Provoke
        range = "40yd"
    },
    [269] = { -- Windwalker
        friendly = 116670,
        hostile = 115546,
        range = "40yd"
    },
    [270] = { -- Mistweaver
        friendly = 116670,  -- Vivify
        hostile = 115546,
        range = "40yd"
    },
    
    -- ==================== PALADIN ====================
    [65] = { -- Holy
        friendly = 19750,   -- Flash of Light
        hostile = 62124,    -- Hand of Reckoning
        range = "40yd"
    },
    [66] = { -- Protection
        friendly = 19750,
        hostile = 62124,
        range = "40yd"
    },
    [70] = { -- Retribution
        friendly = 19750,
        hostile = 62124,
        range = "40yd"
    },
    
    -- ==================== PRIEST ====================
    [256] = { -- Discipline
        friendly = 17,      -- Power Word: Shield
        hostile = 585,      -- Smite
        range = "40yd"
    },
    [257] = { -- Holy
        friendly = 2061,    -- Flash Heal
        hostile = 585,
        range = "40yd"
    },
    [258] = { -- Shadow
        friendly = 17,      -- Power Word: Shield
        hostile = 585,
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
        friendly = 8004,    -- Healing Surge (all shaman)
        hostile = 188196,   -- Lightning Bolt
        range = "40yd"
    },
    [263] = { -- Enhancement
        friendly = 8004,
        hostile = 188196,
        range = "40yd"
    },
    [264] = { -- Restoration
        friendly = 8004,    -- Healing Surge
        hostile = 188196,
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
    DEATHKNIGHT = { friendly = 47541, hostile = 47541 },
    DEMONHUNTER = { friendly = nil, hostile = 185123 },
    DRUID       = { friendly = 8936, hostile = 8921 },  -- Regrowth (all druids have it)
    EVOKER      = { friendly = 360995, hostile = 361469 },
    HUNTER      = { friendly = nil, hostile = 75 },  -- Auto Shot
    MAGE        = { friendly = 1459, hostile = 116 },
    MONK        = { friendly = 116670, hostile = 115546 },
    PALADIN     = { friendly = 19750, hostile = 62124 },
    PRIEST      = { friendly = 2061, hostile = 585 },
    ROGUE       = { friendly = nil, hostile = 36554 },
    SHAMAN      = { friendly = 8004, hostile = 188196 },
    WARLOCK     = { friendly = 20707, hostile = 686 },
    WARRIOR     = { friendly = nil, hostile = 355 },
}

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
    PALADIN     = 7328,    -- Redemption
    SHAMAN      = 2008,    -- Ancestral Spirit
    MONK        = 115178,  -- Resuscitate
    DEATHKNIGHT = 61999,   -- Raise Ally
    WARLOCK     = 20707,   -- Soulstone
    EVOKER      = 361227,  -- Return
}

-- Resolved once at load time / spec change
local currentRezSpell = rezSpellByClass[playerClass] or nil

-- Current active spell (updated on spec change)
local currentFriendlySpell = nil
local currentHostileSpell = nil
local currentSpecID = nil

-- ============================================================
-- SPELL DETECTION & UPDATES
-- ============================================================

local function UpdateRangeSpell()
    local specIndex = GetSpecialization()
    local specID = specIndex and GetSpecializationInfo(specIndex) or nil
    currentSpecID = specID
    
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
    
    if userSpellID and userSpellID > 0 then
        -- User has set a custom spell - validate it with IsPlayerSpell
        if IsPlayerSpell(userSpellID) then
            currentFriendlySpell = userSpellID
            currentHostileSpell = userSpellID
        else
            -- User spell not known (maybe changed spec/talents) - clear so auto-detect runs next call
            currentFriendlySpell = nil
            currentHostileSpell = nil
        end
        return
    end
    
    -- Try spec-specific spells (validated with IsPlayerSpell)
    if specID and specSpells[specID] then
        local spells = specSpells[specID]
        currentFriendlySpell = spells.friendly and IsPlayerSpell(spells.friendly) and spells.friendly or nil
        currentHostileSpell = spells.hostile and IsPlayerSpell(spells.hostile) and spells.hostile or nil
        if currentFriendlySpell or currentHostileSpell then
            return
        end
    end
    
    -- Fallback to class defaults (validated with IsPlayerSpell)
    if classFallbacks[playerClass] then
        local spells = classFallbacks[playerClass]
        currentFriendlySpell = spells.friendly and IsPlayerSpell(spells.friendly) and spells.friendly or nil
        currentHostileSpell = spells.hostile and IsPlayerSpell(spells.hostile) and spells.hostile or nil
        return
    end
    
    -- Ultimate fallback
    currentFriendlySpell = nil
    currentHostileSpell = nil
end

-- ============================================================
-- DEBUG SYSTEM
-- ============================================================

local debugEnabled = false
local debugStats = {
    checks = 0,
    cacheHits = 0,
    cacheMisses = 0,
    lastReset = time(),
}

local function DebugPrint(...)
    if debugEnabled then
        print("|cFF00FF00[DFRange]|r", ...)
    end
end

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
-- Returns: inRange (boolean)
--   Always returns a normal boolean - safe to cache, compare, and test.
--   Falls back to CheckInteractDistance when spells return nil.
-- ============================================================

local function CheckUnitRange(unit)
    if UnitIsUnit(unit, "player") then
        return true
    end
    
    if not UnitExists(unit) then
        return true
    end
    
    -- Branch on UnitCanAttack (not UnitCanAssist) to handle cross-faction party members.
    -- In the open world, cross-faction group members may have UnitCanAssist=false
    -- but UnitCanAttack is also false (they're in your group). Using UnitCanAttack
    -- ensures they fall through to the friendly path.
    if UnitCanAttack("player", unit) then
        -- For hostile units
        if currentHostileSpell then
            local inRange = C_Spell_IsSpellInRange(currentHostileSpell, unit)
            -- Guard against secret/tainted values (Midnight+)
            if issecretvalue and issecretvalue(inRange) then
                -- Fall through to fallback
            elseif inRange ~= nil then
                return inRange
            end
        end
        
        -- No hostile spell or returned nil - assume in range
        return true
    else
        -- For friendly units (party/raid members)
        local spellReturnedNil = false
        
        if currentFriendlySpell then
            local inRange = C_Spell_IsSpellInRange(currentFriendlySpell, unit)
            -- Guard against secret/tainted values (Midnight+)
            if issecretvalue and issecretvalue(inRange) then
                -- Secret value - can't trust, fall through to fallbacks
                spellReturnedNil = true
            elseif inRange ~= nil then
                return inRange
            else
                spellReturnedNil = true
            end
        end
        
        -- Friendly spell returned nil (target is dead, offline, phased, etc.)
        -- If target is dead and we have a rez spell, try that for accurate range
        if currentRezSpell and UnitIsDeadOrGhost(unit) then
            local inRange = C_Spell_IsSpellInRange(currentRezSpell, unit)
            if issecretvalue and issecretvalue(inRange) then
                -- Fall through
            elseif inRange ~= nil then
                return inRange
            end
        end
        
        -- All spell checks returned nil or no friendly spell available
        -- Out of combat: use interact distance (~28 yards) for accurate check
        if not InCombatLockdown() then
            return CheckInteractDistance(unit, 4)
        end
        
        -- IN COMBAT FALLBACKS:
        -- If we HAD a friendly spell and it returned nil on a target that is
        -- alive and connected, the target is likely very far away (outside the
        -- game's position-awareness range). Treat as out of range.
        -- This fixes the bug where IsSpellInRange returns nil (not false) for
        -- extremely distant targets, and the fallback chain defaults to "in range".
        if spellReturnedNil and UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit) then
            DebugPrint("OOR-NIL", unit, "spell returned nil on alive/connected target in combat")
            return false
        end
        
        -- In combat with no spell data: try UnitInRange as last resort
        -- UnitInRange may return secret/tainted values in Midnight+ so we
        -- check with issecretvalue before using the result
        if UnitInRange then
            local inRange, checked = UnitInRange(unit)
            if issecretvalue and (issecretvalue(inRange) or issecretvalue(checked)) then
                -- Secret value - can't cache or compare, assume in range
                return true
            end
            -- Clean boolean - safe to use
            if checked and not inRange then
                return false
            end
        end
        
        -- No method available or UnitInRange inconclusive - assume in range
        -- (Better than fading out entire raid for Warrior/DH/Hunter)
        return true
    end
end

-- ============================================================
-- APPLY RANGE ALPHA TO A FRAME
-- ============================================================

function DF:UpdateRange(frame)
    if not frame or not frame.unit then return end
    
    if DF.PerfTest and not DF.PerfTest.enableRange then return end
    if DF.testMode or DF.raidTestMode then return end
    
    local unit = frame.unit
    
    if not IsInGroup() and not IsInRaid() then
        frame.dfInRange = true
        return
    end
    
    local inRange = CheckUnitRange(unit)
    
    debugStats.checks = debugStats.checks + 1
    
    -- All range results are normal booleans - safe to cache and compare
    local cached = rangeCache[unit]
    if cached == inRange then
        debugStats.cacheHits = debugStats.cacheHits + 1
        DebugPrint("SKIP", unit, "cached:", tostring(cached))
        -- Still need to update THIS frame if it hasn't been initialized
        -- (multiple frames can share the same unit, e.g. pinned frames)
        if frame.dfInRange ~= inRange then
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
    
    local db = frame.isRaidFrame and DF:GetRaidDB() or DF:GetDB()
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
    if cached == inRange then
        return
    end
    rangeCache[cacheKey] = inRange
    
    frame.dfInRange = inRange
    
    local outOfRangeAlpha = db.rangeFadeAlpha or 0.55
    local targetAlpha = inRange and 1.0 or outOfRangeAlpha
    
    frame:SetAlpha(targetAlpha)
    if frame.healthBar then
        frame.healthBar:SetAlpha(targetAlpha)
    end
end

-- ============================================================
-- RANGE UPDATE TIMER
-- ============================================================

local rangeAnimFrame = CreateFrame("Frame")
local rangeAnimGroup = rangeAnimFrame:CreateAnimationGroup()
local rangeAnim = rangeAnimGroup:CreateAnimation()
rangeAnim:SetDuration(0.5)  -- Default 0.5s. Configurable via options.
rangeAnimGroup:SetLooping("REPEAT")

-- Hoisted callback - avoids creating a new closure every 0.5s tick
local function RangeCheckFrame(frame)
    if frame and frame:IsShown() then
        DF:UpdateRange(frame)
        if DF.UpdateHealthFade then
            DF:UpdateHealthFade(frame)
        end
    end
end

rangeAnimGroup:SetScript("OnLoop", function()
    if DF.PerfTest and not DF.PerfTest.enableRange then return end
    if not DF.partyHeader then return end
    
    local contentType = DF:GetContentType()
    
    if contentType == "arena" then
        -- Arena: only arena frames, no pets, no highlights
        if DF.IterateArenaFrames then
            DF:IterateArenaFrames(RangeCheckFrame)
        end
    elseif contentType then
        -- Raid content (battleground/mythic/instanced/openWorld): raid frames + raid pets + raid highlights
        DF:IterateRaidFrames(RangeCheckFrame)
        
        -- Raid pinned frames (only if initialized for raid mode and header is shown/enabled)
        if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.currentMode == "raid" then
            for setIndex = 1, 2 do
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
        -- Party/solo: party frames + player pet + party pets + party highlights
        DF:IteratePartyFrames(RangeCheckFrame)
        
        -- Party pinned frames (only if initialized for party mode and header is shown/enabled)
        if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.currentMode == "party" then
            for setIndex = 1, 2 do
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
end)

-- ============================================================
-- EVENT HANDLERS
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        local unit = ...
        if unit == "player" then
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
    DF.RangeTimer = rangeAnimGroup
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
            local name = C_Spell_GetSpellName(spells.friendly)
            if name then
                options[1].label = "Auto: " .. name .. " (" .. GetSpellRange(spells.friendly, spells.range) .. ")"
            end
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
    local spellName = spellID and C_Spell_GetSpellName(spellID) or "None"
    local range = "Unknown"
    
    -- Get actual range from spell data (accounts for talents that extend range)
    if spellID and C_Spell.GetSpellInfo then
        local spellInfo = C_Spell.GetSpellInfo(spellID)
        if spellInfo and spellInfo.maxRange and spellInfo.maxRange > 0 then
            range = math.floor(spellInfo.maxRange) .. "yd"
        end
    end
    
    -- Fallback to hardcoded range if API didn't return anything
    if range == "Unknown" and currentSpecID and specSpells[currentSpecID] then
        range = specSpells[currentSpecID].range or "40yd"
    end
    
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

SLASH_DFRANGE1 = "/dfrange"
SlashCmdList["DFRANGE"] = function(msg)
    local cmd = msg:lower():trim()
    
    if cmd == "debug" then
        debugEnabled = not debugEnabled
        print("|cFF00FF00[DFRange]|r Debug:", debugEnabled and "ON" or "OFF")
        
    elseif cmd == "stats" then
        local elapsed = time() - debugStats.lastReset
        local total = debugStats.cacheHits + debugStats.cacheMisses
        local hitRate = total > 0 and math.floor((debugStats.cacheHits / total) * 100) or 0
        
        print("|cFF00FF00[DFRange]|r Stats (last " .. elapsed .. "s):")
        print("  Checks: " .. debugStats.checks)
        print("  Cache hits: |cFF00FF00" .. debugStats.cacheHits .. "|r")
        print("  Cache misses: |cFFFFFF00" .. debugStats.cacheMisses .. "|r")
        print("  Hit rate: |cFF00FFFF" .. hitRate .. "%|r")
        
    elseif cmd == "clear" then
        ClearRangeCache()
        ResetStats()
        print("|cFF00FF00[DFRange]|r Cache cleared")
        
    elseif cmd == "spell" then
        local info = DF:GetCurrentRangeSpellInfo()
        local specIndex = GetSpecialization()
        local specID = specIndex and GetSpecializationInfo(specIndex) or nil
        print("|cFF00FF00[DFRange]|r Current Range Spell:")
        print("  Class: " .. tostring(playerClass))
        print("  Spec Index: " .. tostring(specIndex))
        print("  Spec ID: " .. tostring(specID) .. " (cached: " .. tostring(currentSpecID) .. ")")
        print("  Friendly Spell: " .. tostring(currentFriendlySpell) .. " (" .. (currentFriendlySpell and C_Spell_GetSpellName(currentFriendlySpell) or "none") .. ")")
        print("  Hostile Spell: " .. tostring(currentHostileSpell) .. " (" .. (currentHostileSpell and C_Spell_GetSpellName(currentHostileSpell) or "none") .. ")")
        print("  Rez Spell: " .. tostring(currentRezSpell) .. " (" .. (currentRezSpell and C_Spell_GetSpellName(currentRezSpell) or "none") .. ")")
        print("  Timer Interval: " .. tostring(rangeAnim:GetDuration()) .. "s")
        print("  Display: " .. (info.spellName or "None") .. " (" .. (info.range or "?") .. ")")
        print("  Custom Override: " .. tostring(info.isCustom))
        -- Show DB values
        if DF.db then
            local partyVal = DF.db.party and DF.db.party.rangeCheckSpellID or "nil"
            local raidVal = DF.db.raid and DF.db.raid.rangeCheckSpellID or "nil"
            print("  DB Party: " .. tostring(partyVal) .. ", DB Raid: " .. tostring(raidVal))
        end
        -- Test if the friendly spell works on party1
        if UnitExists("party1") then
            local testResult = currentFriendlySpell and C_Spell_IsSpellInRange(currentFriendlySpell, "party1")
            print("  Test on party1: " .. tostring(testResult))
        end
        
    elseif cmd == "dump" then
        print("|cFF00FF00[DFRange]|r Cache contents:")
        local count = 0
        for unit, inRange in pairs(rangeCache) do
            print("  " .. unit .. " = " .. tostring(inRange))
            count = count + 1
        end
        print("  Total: " .. count)
        
    else
        print("|cFF00FF00[DFRange]|r Commands:")
        print("  /dfrange debug - Toggle debug")
        print("  /dfrange stats - Show statistics")
        print("  /dfrange clear - Clear cache")
        print("  /dfrange spell - Show current spell")
        print("  /dfrange dump  - Dump cache")
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

function DF:GetRangeCheckerInfo()
    local info = DF:GetCurrentRangeSpellInfo()
    return "IsSpellInRange", info.spellID, info.spellName
end
