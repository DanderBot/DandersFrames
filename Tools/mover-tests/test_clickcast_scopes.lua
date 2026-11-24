-- ============================================================
-- CLICK-CASTING FRAME SCOPES
-- DandersFrames/ClickCasting/Constants.lua (FRAME_SCOPE_FAMILIES) and
-- Bindings.lua (BindingScopeOn, GetFrameScope, BuildUnifiedMacroMap(scope),
-- GetMacroMapForFrame, BindingScopesOverlap / FindKeyConflicts).
-- The real files are LOADED, not grepped: the reader, the classifier and the
-- per-scope map are the behaviour under test.
-- ============================================================

local savedDF, savedEnum, savedCSpell, savedCSpellBook, savedSlash = DandersFrames, Enum, C_Spell, C_SpellBook, SlashCmdList
SlashCmdList = SlashCmdList or {}

local CC = {}
local DF = { ClickCast = CC, IS_MODERN_ENGINE = true }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DebugActive() return false end
function DF:MemTestDisabled() return false end
function DF:RegisterDebugSlash() end
-- Defined in Profiles.lua (not loaded here); only the macro text reads it.
CC.GetCombatCondition = function() return nil end
DandersFrames = DF

-- Spells: every name is a known spell, so a spell binding builds a macro.
Enum = Enum or {}
Enum.SpellBookSpellBank = Enum.SpellBookSpellBank or { Player = 0, Pet = 1 }
C_Spell = {
    GetSpellInfo = function(name) return { spellID = 1, name = name } end,
    GetSpellName = function(id) return nil end,
}
C_SpellBook = { IsSpellInSpellBook = function() return true end }

load_df_file_into("ClickCasting/Constants.lua", DF)
load_df_file_into("ClickCasting/Bindings.lua", DF)
check(CC.BindingScopeOn and CC.GetFrameScope and CC.GetMacroMapForFrame and CC.FRAME_SCOPES,
      "api: the scope reader, classifier and per-scope maps are on CC")

-- ------------------------------------------------------------
print("-- Click-cast scopes: the scope list")
-- ------------------------------------------------------------
local want = { "party", "raid", "player", "target", "targettarget", "focus", "focustarget", "pet", "boss" }
eq(#CC.FRAME_SCOPES, #want, "scopes: nine DF scopes")
for i, k in ipairs(want) do eq(CC.FRAME_SCOPES[i], k, "scopes: order " .. i .. " is " .. k) end
-- The unit frame scopes are exactly the units the module spawns (a UF frame's
-- scope IS its dfUFUnit, so a drift here would be a frame with no scope row).
do
    local src = uf_file_source("Core.lua")
    local list = src:match('UF%.SPAWNED_UNITS = (%b{})')
    check(list ~= nil, "scopes: UF.SPAWNED_UNITS is declared")
    local units = {}
    for u in list:gmatch('"(%w+)"') do units[#units + 1] = u end
    local fam = CC.FRAME_SCOPE_FAMILIES[2]
    eq(fam.key, "unit", "scopes: the second family is Unit Frames")
    eq(#fam.members, #units, "scopes: one Unit Frames member per spawned unit")
    for i, u in ipairs(units) do eq(fam.members[i], u, "scopes: unit member " .. i .. " is " .. u) end
end

-- ------------------------------------------------------------
print("-- Click-cast scopes: the reader (lazy migration)")
-- ------------------------------------------------------------
local function allDF(b, v, label)
    for _, s in ipairs(CC.FRAME_SCOPES) do
        eq(CC:BindingScopeOn(b, s), v, label .. ": " .. s)
    end
end

local legacyDFOnly = { frames = { dandersFrames = true, otherFrames = false } }
allDF(legacyDFOnly, true, "legacy DF-only: every DF scope on")
eq(CC:BindingScopeOn(legacyDFOnly, "other"), false, "legacy DF-only: other off")

local legacyOtherOnly = { frames = { dandersFrames = false, otherFrames = true } }
allDF(legacyOtherOnly, false, "legacy other-only: every DF scope off")
eq(CC:BindingScopeOn(legacyOtherOnly, "other"), true, "legacy other-only: other on")

local noFrames = {}
allDF(noFrames, true, "no frames table: on everywhere")
eq(CC:BindingScopeOn(noFrames, "other"), true, "no frames table: other on")

local partial = { frames = { dandersFrames = true, otherFrames = false,
    scopes = { party = true, raid = false, target = false } } }
eq(CC:BindingScopeOn(partial, "party"), true, "partial: party on")
eq(CC:BindingScopeOn(partial, "raid"), false, "partial: raid off")
eq(CC:BindingScopeOn(partial, "target"), false, "partial: target off")
eq(CC:BindingScopeOn(partial, "focus"), true, "partial: a key it never saved falls back to dandersFrames")
eq(CC:BindingScopeOn(partial, "arena"), true, "partial: a future scope falls back to dandersFrames")

-- Untrusted import shapes never throw and fall back to legacy.
local junk1 = { frames = { dandersFrames = true, scopes = 5 } }
eq(CC:BindingScopeOn(junk1, "target"), true, "junk scopes (number): ignored, legacy answer")
local junk2 = { frames = { dandersFrames = false, scopes = { target = "yes" } } }
eq(CC:BindingScopeOn(junk2, "target"), false, "junk scope value (string): ignored, legacy answer")
local junk3 = { frames = "all" }
eq(CC:BindingScopeOn(junk3, "party"), true, "junk frames (string): treated as no frames table")

-- ------------------------------------------------------------
print("-- Click-cast scopes: normalise on save")
-- ------------------------------------------------------------
do
    local b = { frames = { dandersFrames = true, otherFrames = false } }
    CC:NormalizeBindingScopes(b)
    check(type(b.frames.scopes) == "table", "normalise legacy: writes scopes")
    allDF(b, true, "normalise legacy: unchanged behaviour")
    eq(b.frames.dandersFrames, true, "normalise legacy: summary flag kept")
    eq(b.frames.otherFrames, false, "normalise legacy: other kept")

    local c = { frames = { dandersFrames = true, otherFrames = true, scopes = {} } }
    for _, s in ipairs(CC.FRAME_SCOPES) do c.frames.scopes[s] = false end
    CC:NormalizeBindingScopes(c)
    eq(c.frames.dandersFrames, false, "normalise: all DF scopes off -> summary flag off (an old client skips DF frames)")
    c.frames.scopes.boss = true
    CC:NormalizeBindingScopes(c)
    eq(c.frames.dandersFrames, true, "normalise: one DF scope on -> summary flag on")
    eq(c.frames.scopes.boss, true, "normalise: keeps the member it had")
end

-- ------------------------------------------------------------
print("-- Click-cast scopes: which scope a frame is")
-- ------------------------------------------------------------
eq(CC:GetFrameScope({ dfIsDandersFrame = true, isRaidFrame = false }), "party", "classify: party header child")
eq(CC:GetFrameScope({ dfIsDandersFrame = true, isRaidFrame = true }), "raid", "classify: raid header child")
eq(CC:GetFrameScope({ dfIsDandersFrame = true, isArenaFrame = true, isRaidFrame = false }), "party", "classify: arena -> party")
eq(CC:GetFrameScope({ dfIsDandersFrame = true, isPinnedFrame = true, isRaidFrame = true }), "raid", "classify: pinned in raid")
eq(CC:GetFrameScope({ dfIsDandersFrame = true, isPinnedFrame = true, isPinnedBossFrame = true, isRaidFrame = false }),
   "party", "classify: pinned boss in party")
eq(CC:GetFrameScope({ dfIsDandersFrame = true, isPetFrame = true, isRaidFrame = true }), "raid", "classify: raid pet")
eq(CC:GetFrameScope({ dfIsDandersFrame = true, isPetFrame = true, isRaidFrame = false }), "party", "classify: party pet")
for _, u in ipairs({ "player", "target", "targettarget", "focus", "focustarget", "pet", "boss" }) do
    eq(CC:GetFrameScope({ dfIsDandersFrame = true, dfStandalone = true, dfUFUnit = u, isRaidFrame = false }), u,
       "classify: unit frame " .. u)
end
eq(CC:GetFrameScope({ dfIsBlizzardFrame = true }), "other", "classify: Blizzard frame")
eq(CC:GetFrameScope({}), "other", "classify: third-party frame")
-- Test frames never click-cast (Frames.lua clickCastFrameEligible), whatever they classify as.
check(df_file_source("ClickCasting/Frames.lua"):find("if frame.dfIsTestFrame then return false end", 1, true) ~= nil,
      "classify: test-mode frames are still refused registration")

-- ------------------------------------------------------------
print("-- Click-cast scopes: one map per scope")
-- ------------------------------------------------------------
local function only(scopes, other)
    local f = { dandersFrames = false, otherFrames = other or false, scopes = {} }
    for _, s in ipairs(CC.FRAME_SCOPES) do f.scopes[s] = false end
    for _, s in ipairs(scopes) do f.scopes[s] = true end
    CC:NormalizeBindingScopes({ frames = f })
    local any = false
    for _, s in ipairs(scopes) do any = true end
    f.dandersFrames = any
    return f
end

local targetLeft = { enabled = true, bindType = "mouse", button = "LeftButton", modifiers = "",
    actionType = "target", frames = only({ "target", "boss" }) }
local healLeft = { enabled = true, bindType = "mouse", button = "LeftButton", modifiers = "",
    actionType = "spell", spellName = "Flash Heal", spellId = 2061, frames = only({ "party", "player" }) }
local legacyRight = { enabled = true, bindType = "mouse", button = "RightButton", modifiers = "",
    actionType = "menu", frames = { dandersFrames = true, otherFrames = true } }
CC.db = { enabled = true, bindings = { targetLeft, healLeft, legacyRight } }
CC.profile = { options = {} }
CC.unifiedMacroMap = nil

local partyMap = CC:GetMacroMapForFrame({ dfIsDandersFrame = true, isRaidFrame = false })
local targetMap = CC:GetMacroMapForFrame({ dfIsDandersFrame = true, dfUFUnit = "target" })
local raidMap = CC:GetMacroMapForFrame({ dfIsDandersFrame = true, isRaidFrame = true })
local playerMap = CC:GetMacroMapForFrame({ dfIsDandersFrame = true, dfUFUnit = "player" })

check(partyMap.BUTTON1 and partyMap.BUTTON1.templateBinding == healLeft, "maps: Left on party is the heal")
check(targetMap.BUTTON1 and targetMap.BUTTON1.templateBinding == targetLeft, "maps: Left on the target frame is Target")
check(playerMap.BUTTON1 and playerMap.BUTTON1.templateBinding == healLeft, "maps: Left on the player frame is the heal")
check(raidMap.BUTTON1 == nil, "maps: Left on raid does nothing (neither binding is on there)")
for name, map in pairs({ party = partyMap, target = targetMap, raid = raidMap, player = playerMap }) do
    check(map.BUTTON2 and map.BUTTON2.templateBinding == legacyRight,
          "maps: the legacy Right = menu is on " .. name .. " (old profiles keep working everywhere)")
end
-- The union is what it always was: one entry per key.
check(CC.unifiedMacroMap.BUTTON1 ~= nil and CC.unifiedMacroMap.BUTTON2 ~= nil, "maps: the union map keeps every key")

-- A legacy profile: every scope map has exactly the union's keys.
do
    CC.db = { enabled = true, bindings = {
        { enabled = true, bindType = "mouse", button = "LeftButton", modifiers = "", actionType = "target",
          frames = { dandersFrames = true, otherFrames = true } },
        { enabled = true, bindType = "key", key = "F", modifiers = "SHIFT", actionType = "spell",
          spellName = "Renew", spellId = 139, frames = { dandersFrames = true, otherFrames = false } },
    } }
    CC.unifiedMacroMap = nil
    local union = CC:BuildUnifiedMacroMap()
    for _, s in ipairs(CC.FRAME_SCOPES) do
        CC.unifiedMacroMap = nil
        local m = CC:GetMacroMapForScope(s)
        for k in pairs(union) do check(m[k] ~= nil, "legacy profile: " .. s .. " map has " .. k) end
        for k in pairs(m) do check(union[k] ~= nil, "legacy profile: " .. s .. " map adds nothing (" .. k .. ")") end
    end
    CC.unifiedMacroMap = nil
    local other = CC:GetMacroMapForScope("other")
    check(other.BUTTON1 ~= nil and other["SHIFT-F"] == nil, "legacy profile: Other Frames gets only the bind ticked for it")
end

-- Rebuilding (or nil-ing) the union invalidates every scope map: the #976
-- repair and every ApplyBindings path assign self.unifiedMacroMap directly.
do
    CC.unifiedMacroMap = nil
    local a = CC:GetMacroMapForScope("party")
    check(CC:GetMacroMapForScope("party") == a, "cache: same union -> same scope map")
    CC.unifiedMacroMap = CC:BuildUnifiedMacroMap()
    check(CC:GetMacroMapForScope("party") ~= a, "cache: a rebuilt union rebuilds the scope maps")
end

-- ------------------------------------------------------------
print("-- Click-cast scopes: conflicts only where scopes overlap")
-- ------------------------------------------------------------
do
    CC.db = { enabled = true, bindings = { targetLeft, legacyRight } }
    local newHeal = { bindType = "mouse", button = "LeftButton", modifiers = "", actionType = "spell",
        spellName = "Flash Heal", frames = only({ "party", "player" }) }
    eq(#CC:FindKeyConflicts(newHeal), 0, "conflicts: Left heal on party vs Left target on the target frame -> none")
    local overlap = { bindType = "mouse", button = "LeftButton", modifiers = "", actionType = "spell",
        spellName = "Flash Heal", frames = only({ "boss" }) }
    eq(#CC:FindKeyConflicts(overlap), 1, "conflicts: both on Boss -> a conflict")
    local legacy = { bindType = "mouse", button = "LeftButton", modifiers = "", actionType = "spell",
        spellName = "Flash Heal", frames = { dandersFrames = true, otherFrames = true } }
    eq(#CC:FindKeyConflicts(legacy), 1, "conflicts: a legacy all-frames binding overlaps")
    local globalOnly = { bindType = "mouse", button = "LeftButton", modifiers = "", actionType = "spell",
        spellName = "Flash Heal", frames = only({}) }
    eq(#CC:FindKeyConflicts(globalOnly), 1, "conflicts: a binding on no frame (global key only) always overlaps")
    local dupTarget = { bindType = "mouse", button = "LeftButton", modifiers = "", actionType = "target",
        frames = only({ "party" }) }
    eq(CC:FindDuplicateBinding(dupTarget), nil, "duplicates: same action on a disjoint scope is not a duplicate")
    dupTarget.frames = only({ "target" })
    eq(CC:FindDuplicateBinding(dupTarget), 1, "duplicates: same action on an overlapping scope is")
end

-- ------------------------------------------------------------
print("-- Click-cast scopes: wiring")
-- ------------------------------------------------------------
do
    local frames = df_file_source("ClickCasting/Frames.lua")
    check(frames:find("pairs(self:GetMacroMapForFrame(frame))", 1, true) ~= nil,
          "wiring: hover snippets come from the frame's own scope map")
    check(frames:find("CC:ProfileHasKeyboardBindings(self)", 1, true) ~= nil,
          "wiring: the #976 empty-snippet check asks about THIS frame's scope")
    local bind = df_file_source("ClickCasting/Bindings.lua")
    check(bind:find("local frameMap = self:GetMacroMapForFrame(frame)", 1, true) ~= nil,
          "wiring: mouse attributes come from the frame's own scope map")
    check(bind:find("local useProxy = isDandersFrame or isBlizzardFrame or thirdPartyHasUnit", 1, true) ~= nil,
          "wiring: the 12.0.7 proxy choice is unchanged")
    check(not bind:find("frames.dandersFrames or frames.otherFrames", 1, true),
          "wiring: no macro builder reads the two legacy flags directly any more")
    local units = uf_file_source("Units.lua")
    check(units:find("DF.ClickCast:RefreshFrameScope(f)", 1, true) ~= nil,
          "wiring: a unit frame re-applies its binds once dfUFUnit is stamped")
    local editor = options_file_source("ClickCasting/UI/BindingEditor.lua")
    check(editor:find("self:NormalizeBindingScopes(binding)", 1, true) ~= nil,
          "wiring: the editor writes the explicit shape on save")
end

-- Locale: every new key the editor uses is in enUS.
do
    local enus = df_file_source("Locales/enUS.lua")
    for _, k in ipairs({
        "%s are turned off on the Modules page.",
        "%s is hidden by its Frame Source.",
        "%s uses Blizzard's frame, so Other Frames covers it.",
        "Blizzard's frames (player, target, focus, pet, boss, arena), other addons' unit frames, and nameplates.",
        "The DandersFrames unit frames: player, target, focus, pet, boss and the rest.",
        "Your party and raid frames, including pinned, arena and group pet frames.",
        "Group Frames", "Unit Frames", "Other Frames", "Target of Target", "Focus Target", "Party Frames", "Raid Frames",
    }) do
        check(enus:find('L["' .. k .. '"] = true', 1, true) ~= nil, "locale: enUS has " .. k)
    end
end

DandersFrames, Enum, C_Spell, C_SpellBook, SlashCmdList = savedDF, savedEnum, savedCSpell, savedCSpellBook, savedSlash
