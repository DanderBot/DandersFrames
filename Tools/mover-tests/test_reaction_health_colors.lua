local NS = ...

-- ============================================================
-- REACTION / TAPPED HEALTH COLOURS -- DandersFrames/Frames/Colors.lua
-- ------------------------------------------------------------
-- healthColorMode REACTION (every unit by reaction, tapped NPCs grey) and
-- CLASS_REACTION (players by class, the rest as REACTION), with the colours in
-- the profile-root reactionColors table. Every unit read is folded when SECRET
-- (never branched on): unknown reaction = neutral, secret player/class = treat
-- as an NPC, secret tapped = not tapped. Offered on standalone frames' pages
-- only: the party/raid dropdown is unchanged.
-- ============================================================

local SRC = df_file_source("Frames/Colors.lua"):gsub("\r\n", "\n")
local a = SRC:find("\nDF.StandaloneHealthColorModes = ", 1, true)
local s = SRC:find("\nfunction DF:ApplyHealthColors(frame)", 1, true)
local b = s and SRC:find("\nend\n", s, true)
check(a and s and b and a < s, "lift: found the reaction block and ApplyHealthColors")
if not (a and b) then return end

local SECRET = setmetatable({}, { __tostring = function() return "SECRET" end })
local units = {}
local registered
local DF = { db = {} }
function DF:GetClassColor(class) return { r = 0.1, g = 0.2, b = class == "MAGE" and 0.9 or 0.3 } end
function DF:RegisterProfileRootTable(key, spec) registered = { key = key, spec = spec }; return true end
local env = setmetatable({
    DF = DF,
    issecretvalue = function(v) return v == SECRET end,
    UnitIsPlayer = function(u) return units[u].player end,
    UnitClass = function(u) return "x", units[u].class end,
    UnitIsTapDenied = function(u) return units[u].tapped end,
    UnitReaction = function(u) return units[u].reaction end,
}, { __index = _G })
local f, err = loadstring(SRC:sub(a + 1, b + 4), "=reaction")
check(f ~= nil, "lift: parses (" .. tostring(err) .. ")")
if not f then return end
setfenv(f, env)
f()

local D = DF.ReactionColorDefaults
local function rgb(...) return table.concat({ ... }, ",") end
local function col(c) return rgb(c.r, c.g, c.b) end

print("-- The colour table is a registered profile-root table")
eq(registered and registered.key, "reactionColors", "registered as reactionColors")
eq(registered and registered.spec.defaults, D, "...with the defaults")
check(DF.StandaloneHealthColorModes.REACTION and DF.StandaloneHealthColorModes.CLASS_REACTION,
      "the two extra modes are named for pages that offer them")

print("-- REACTION")
units.hostileNpc = { player = false, reaction = 2 }
units.neutralNpc = { player = false, reaction = 4 }
units.friendlyNpc = { player = false, reaction = 6 }
units.tappedNpc = { player = false, reaction = 2, tapped = true }
units.enemyPlayer = { player = true, class = "MAGE", reaction = 1 }
eq(rgb(DF:GetReactionHealthColor("hostileNpc", "REACTION")), col(D.hostile), "hostile NPC: hostile")
eq(rgb(DF:GetReactionHealthColor("neutralNpc", "REACTION")), col(D.neutral), "neutral NPC: neutral")
eq(rgb(DF:GetReactionHealthColor("friendlyNpc", "REACTION")), col(D.friendly), "friendly NPC: friendly")
eq(rgb(DF:GetReactionHealthColor("tappedNpc", "REACTION")), col(D.tapped), "tapped NPC: grey")
eq(rgb(DF:GetReactionHealthColor("enemyPlayer", "REACTION")), col(D.hostile), "a player is reaction-coloured in REACTION")
eq(rgb(DF:GetReactionHealthColor(nil, "REACTION")), col(D.neutral), "no unit: neutral")

print("-- CLASS_REACTION")
eq(rgb(DF:GetReactionHealthColor("enemyPlayer", "CLASS_REACTION")), "0.1,0.2,0.9", "a player: class colour")
eq(rgb(DF:GetReactionHealthColor("hostileNpc", "CLASS_REACTION")), col(D.hostile), "an NPC: reaction")
eq(rgb(DF:GetReactionHealthColor("tappedNpc", "CLASS_REACTION")), col(D.tapped), "a tapped NPC: grey")

print("-- Secret values fold to the neutral answer")
units.secretReaction = { player = false, reaction = SECRET }
units.secretTapped = { player = false, reaction = 2, tapped = SECRET }
units.secretPlayer = { player = SECRET, class = "MAGE", reaction = 6 }
units.secretClass = { player = true, class = SECRET, reaction = 6 }
eq(rgb(DF:GetReactionHealthColor("secretReaction", "REACTION")), col(D.neutral), "secret reaction: neutral")
eq(rgb(DF:GetReactionHealthColor("secretTapped", "REACTION")), col(D.hostile), "secret tapped: treated as not tapped")
eq(rgb(DF:GetReactionHealthColor("secretPlayer", "CLASS_REACTION")), col(D.friendly), "secret is-player: treated as an NPC")
eq(rgb(DF:GetReactionHealthColor("secretClass", "CLASS_REACTION")), col(D.friendly), "secret class: falls back to reaction")

print("-- The profile's colours win; a broken entry falls back")
DF.db.reactionColors = { hostile = { r = 1, g = 0, b = 0 }, neutral = "broken" }
eq(rgb(DF:GetReactionHealthColor("hostileNpc", "REACTION")), "1,0,0", "user's hostile colour")
eq(rgb(DF:GetReactionHealthColor("neutralNpc", "REACTION")), col(D.neutral), "a broken entry: the default")
DF.db.reactionColors = nil

print("-- ApplyHealthColors paints it on both channels")
function DF:GetFrameDB(fr) return fr.db end
local painted = {}
local tex = { SetVertexColor = function(_, r, g, b) painted.vertex = rgb(r, g, b) end,
              SetAlpha = function(_, al) painted.alpha = al end }
local frame = { unit = "hostileNpc", db = { healthColorMode = "REACTION", classColorAlpha = 0.7 },
                healthBar = { SetStatusBarColor = function(_, r, g, b) painted.bar = rgb(r, g, b) end,
                              GetStatusBarTexture = function() return tex end } }
DF:ApplyHealthColors(frame)
eq(painted.bar, col(D.hostile), "status bar colour")
eq(painted.vertex, col(D.hostile), "texture vertex colour")
eq(painted.alpha, 0.7, "the health bar alpha applies, as in CLASS")

print("-- Nowhere else changed")
local EA = df_file_source("Features/ElementAppearance.lua")
check(EA:find('colorMode == "REACTION" or colorMode == "CLASS_REACTION"', 1, true),
      "ElementAppearance's health applier knows the two modes (no green fallback fight)")
local page = options_file_source("GUI/Pages/Auras.lua")
local modes = page:match("local colorModes = (%b{})")
check(modes ~= nil, "found the party/raid Health Bar mode list")
check(modes and not modes:find("REACTION", 1, true), "the party/raid dropdown does not offer the new modes")

print("-- The secret check comes BEFORE any truth test of the same value")
-- A boolean test on a secret value errors in game; `x and not IsSecret(x)` tests
-- x first. The mock above cannot catch that (a table is just truthy), so the
-- order is checked on the source.
local fs = SRC:find("\nfunction DF:GetReactionHealthColor(", 1, true)
local fe = fs and SRC:find("\nend\n", fs, true)
local body = fs and fe and SRC:sub(fs, fe) or ""
check(body ~= "", "found GetReactionHealthColor's body")
local late = {}
for v in body:gmatch("IsSecret%((%w+)%)") do
    if body:find("if " .. v .. " and[^\n]*IsSecret%(" .. v .. "%)")
        or body:find("if " .. v .. " then[^\n]*\n[^\n]*IsSecret%(" .. v .. "%)") then
        late[#late + 1] = v
    end
end
eq(table.concat(late, ","), "", "no value is truth-tested before its secret check")
