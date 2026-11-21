local NS = ...

-- ============================================================
-- AURA DESIGNER: ONLY ON MY FRAME
-- DandersFrames/AuraDesigner/Factory.lua   Factory.ADGate, pickWinner, claimedGroupMembers
-- DandersFrames/Features/Auras.lua         driveFactoryRowsNow (the re-drive latch)
-- DandersFrames_Options/AuraDesigner/UI/Cards.lua  the card checkbox
-- ------------------------------------------------------------
-- An indicator / effect with `onlyMyFrame` renders on the player's own frame only (the
-- Inner Fire "missing" reminder that lit on every party frame). The real functions are
-- lifted by name and run on plain tables.
-- ============================================================

print("-- Aura Designer: Only on My Frame")

local fsrc = df_file_source("AuraDesigner/Factory.lua"):gsub("\r\n", "\n")

-- ---- Factory.lua still compiles under real Lua 5.1 -------------------------------------
-- Its main chunk sits AT the 200-active-locals ceiling, which is a PARSE error past the
-- limit. The suite-wide parse gate catches that too; this names the file and the rule.
do
    local f, err = loadstring(fsrc, "@Factory.lua")
    check(f ~= nil, "locals: Factory.lua compiles (200-local ceiling) " .. tostring(err or ""))
    check(not fsrc:find("\nlocal ADGate", 1, true),
          "locals: the gate is a field on Factory, not a new top-level local")
end

-- Cut a block from `header` to the first top-level "\nend\n" after it.
local function cut(src, header, from)
    local a = src:find(header, from or 1, true)
    if not a then return nil end
    local e = src:find("\nend\n", a, true)
    return src:sub(a, e + 4)
end

-- ---- lift Factory.ADGate --------------------------------------------------------------
local gateSrc
do
    local a = fsrc:find("Factory.ADGate = {}", 1, true)
    local shownEnd = a and fsrc:find("\nend\n", a, true)
    local isMe = a and cut(fsrc, "function Factory.ADGate.frameIsMe(frame)", a)
    check(a ~= nil and isMe ~= nil, "gate: Factory.ADGate and frameIsMe exist")
    if a and isMe then gateSrc = fsrc:sub(a, shownEnd + 4) .. "\n" .. isMe end
end
if not gateSrc then return end

local W = { same = nil, calls = 0 }
local Factory = {}
local DF = {
    UnitIsUnit = function(u1, u2)
        W.calls = W.calls + 1
        if type(W.same) == "table" then return W.same[u1] end
        return W.same
    end,
}
local genv = setmetatable({ Factory = Factory, DF = DF }, { __index = _G })
do
    local chunk = assert(loadstring(gateSrc, "@Factory.lua:ADGate"))
    setfenv(chunk, genv)
    chunk()
end
local G = Factory.ADGate
check(type(G.shown) == "function" and type(G.frameIsMe) == "function", "gate: both helpers published")

-- shown()
do
    check(G.shown({}, false) == true, "shown: flag off shows on someone else's frame")
    check(G.shown({}, true) == true, "shown: flag off shows on my frame")
    check(G.shown({ onlyMyFrame = false }, false) == true, "shown: an unticked flag (false) is off")
    check(G.shown({ onlyMyFrame = true }, true) == true, "shown: flag on shows on my frame")
    check(G.shown({ onlyMyFrame = true }, false) == false, "shown: flag on hides on someone else's frame")
    check(G.shown({ onlyMyFrame = true }, nil) == false, "shown: flag on hides when the answer is unknown")
    check(G.shown(nil, false) == true, "shown: no config is not gated")
end

-- frameIsMe(): live frames
do
    W.calls = 0
    check(G.frameIsMe({ unit = "player" }) == true, "isme: the player token is me")
    eq(W.calls, 0, "isme: ...without asking UnitIsUnit")
    check(G.frameIsMe({}) == false, "isme: no unit is not me")
    check(G.frameIsMe(nil) == false, "isme: no frame is not me")

    local f = { unit = "raid3" }
    W.same = true
    check(G.frameIsMe(f) == true, "isme: raidN that is me (definite)")
    W.same = nil   -- withheld (restricted content / combat)
    check(G.frameIsMe(f) == true, "isme: withheld keeps the last definite answer for the same token")
    W.same = false
    check(G.frameIsMe(f) == false, "isme: a definite false replaces it (roster moved you)")
    W.same = nil
    check(G.frameIsMe(f) == false, "isme: ...and withheld then keeps that false")
    W.same = true; G.frameIsMe(f)
    f.unit = "raid7"; W.same = nil
    check(G.frameIsMe(f) == false, "isme: withheld on a token never answered for is false (never everyone)")
    W.same = nil
    local fresh = { unit = "party2" }
    check(G.frameIsMe(fresh) == false, "isme: withheld on a fresh frame is false")
    check(fresh.dfADIsMeUnit == nil, "isme: a withheld read never writes the cache")
end

-- frameIsMe(): test frames carry fake units
do
    W.same = false
    check(G.frameIsMe({ dfIsTestFrame = true, isRaidFrame = false, index = 0, unit = "player" }) == true,
          "test: party test frame 0 is me")
    check(G.frameIsMe({ dfIsTestFrame = true, isRaidFrame = false, index = 2, unit = "party2" }) == false,
          "test: other party test frames are not")
    check(G.frameIsMe({ dfIsTestFrame = true, isRaidFrame = true, index = 1, unit = "raid1" }) == true,
          "test: raid test frame 1 is me (UnitIsUnit says no solo)")
    check(G.frameIsMe({ dfIsTestFrame = true, isRaidFrame = true, index = 2, unit = "raid2" }) == false,
          "test: other raid test frames are not")
    check(G.frameIsMe({ dfIsTestFrame = true, dfIsPinnedTestFrame = true, index = 1, unit = "player" }) == true,
          "test: pinned slot 1 (1-based) is me")
    check(G.frameIsMe({ dfIsTestFrame = true, dfIsPinnedTestFrame = true, index = 2, unit = "party1" }) == false,
          "test: other pinned slots are not")
    check(G.frameIsMe({ dfIsTestFrame = true, dfIsPinnedTestFrame = true, isPinnedBossFrame = true,
                        index = 1, unit = "boss1" }) == false,
          "test: a pinned boss set has no player in it")
    -- Unit-frame previews (DandersFrames_UnitFrames/Preview.lua): real unit token, the
    -- index is a sample-data slot and must not be read as a party/raid position.
    check(G.frameIsMe({ dfIsTestFrame = true, dfUFPreview = true, isRaidFrame = false,
                        index = 0, unit = "player" }) == true, "test: the Player unit-frame preview is me")
    check(G.frameIsMe({ dfIsTestFrame = true, dfUFPreview = true, isRaidFrame = false,
                        index = 0, unit = "pet" }) == false, "test: the Pet preview is not, whatever its index")
end

-- ---- pickWinner: a gated block is not a candidate ---------------------------------------
do
    local body = cut(fsrc, "local function pickWinner(")
    check(body ~= nil, "winner: pickWinner exists")
    if body then
        local env = setmetatable({
            Factory = Factory,
            OTHER_PREFIX = "other:",
            unionIdentity = function() return { [1] = true } end,
            warnOtherUnresolved = function() end,
        }, { __index = _G })
        local chunk = assert(loadstring(body .. "\nreturn pickWinner", "@Factory.lua:pickWinner"))
        setfenv(chunk, env)
        local pickWinner = chunk()
        local auras = {
            Mine = { priority = 9, border = { onlyMyFrame = true } },
            Anyone = { priority = 3, border = {} },
        }
        eq(pickWinner(nil, auras, nil, "border", nil, true), "Mine", "winner: on my frame the gated block wins")
        eq(pickWinner(nil, auras, nil, "border", nil, false), "Anyone",
           "winner: on someone else's the next block wins, nothing is left blank")
        auras.Anyone = nil
        eq(pickWinner(nil, auras, nil, "border", nil, false), nil, "winner: only a gated block -> no winner")
    end
end

-- ---- claimedGroupMembers / collectGroupMembers agree -------------------------------------
do
    local body = cut(fsrc, "local function claimedGroupMembers(")
    check(body ~= nil, "groups: claimedGroupMembers exists")
    if body then
        local env = setmetatable({
            Factory = Factory,
            memberRenderable = function(ind) return ind ~= nil and ind.enabled ~= false end,
            placedKey = function(prefix, name, ind) return prefix .. name .. "#" .. tostring(ind.id) end,
        }, { __index = _G })
        local chunk = assert(loadstring(body .. "\nreturn claimedGroupMembers", "@Factory.lua:claimed"))
        setfenv(chunk, env)
        local claimed = chunk()
        local auras = { IF = { indicators = { { id = 1, onlyMyFrame = true }, { id = 2 } } } }
        local groups = { { members = { { auraName = "IF", indicatorID = 1 }, { auraName = "IF", indicatorID = 2 } } } }
        local onMe = claimed(groups, auras, "", true)
        check(onMe and onMe["IF#1"] and onMe["IF#2"], "groups: on my frame both members are claimed")
        local onThem = claimed(groups, auras, "", false)
        check(onThem and not onThem["IF#1"] and onThem["IF#2"],
              "groups: on someone else's the gated member is not claimed")
    end
    -- The draw side must gate the same way, or a member draws twice / not at all.
    local coll = cut(fsrc, "local function collectGroupMembers(")
    check(coll and coll:find("memberRenderable(ind) and Factory.ADGate.shown(ind, frame.dfADSyncMe)", 1, true),
          "groups: collectGroupMembers gates with the same rule")
    -- memberRenderable stays frame-free (the editor canvas calls it with no frame).
    local mr = cut(fsrc, "local function memberRenderable(")
    check(mr and not mr:find("onlyMyFrame", 1, true) and not mr:find("ADGate", 1, true),
          "groups: memberRenderable itself is not gated")
end

-- ---- every render gate site consults the gate ----------------------------------------------
do
    local sites = {
        { "local function auraHasTrackedIndicator(", "dedup: auraHasTrackedIndicator" },
        { "local function unionTrackedIdentity(", "dedup: unionTrackedIdentity" },
        { "local function collectDesiredSounds(", "sound: collectDesiredSounds" },
        { "local function syncPlacedPool(", "placed: syncPlacedPool" },
        { "local function collectStackedBorders(", "border: collectStackedBorders" },
        { "local function collectFrameTints(", "tint: collectFrameTints" },
    }
    for _, s in ipairs(sites) do
        local b = cut(fsrc, s[1])
        check(b and b:find("shown(", 1, true) ~= nil, "sites: " .. s[2] .. " gates on Only on My Frame")
    end
    local sync = cut(fsrc, "function Factory:SyncFrame(frame)")
    check(sync and sync:find("frame.dfADSyncMe = Factory.ADGate.frameIsMe(frame)", 1, true),
          "sites: SyncFrame resolves the answer once per pass")
    local _, n = (sync or ""):gsub("frame%.dfADSyncMe%)", "")
    check(n >= 5, "sites: SyncFrame passes it to the tint x2, border x2 and text winners (" .. n .. ")")
    local tracked = cut(fsrc, "function DF:GetADTrackedSpellIDs(")
    check(tracked and tracked:find("Factory.ADGate.frameIsMe(frame)", 1, true),
          "sites: the buff-bar dedup asks the same question")
end

-- ---- the re-drive latch keys on the "is me" answer ------------------------------------------
do
    local asrc = df_file_source("Features/Auras.lua"):gsub("\r\n", "\n")
    local body = cut(asrc, "local function driveFactoryRowsNow(frame)")
    check(body ~= nil, "latch: driveFactoryRowsNow exists")
    if body then
        local syncs = 0
        local LDF = {
            auraLayoutVersion = 7,
            GetFrameDB = function() return {} end,
            IsAuraDesignerEnabled = function() return true end,
            UseFactoryForAD = function() return true end,
            AuraDesigner = { Factory = { ADGate = G } },
        }
        function LDF.AuraDesigner.Factory:SyncFrame(frame)
            syncs = syncs + 1
            frame.dfADSyncVer, frame.dfADSyncUnit = LDF.auraLayoutVersion, frame.unit
            frame.dfADSyncMe = G.frameIsMe(frame)
        end
        local chunk = assert(loadstring(body .. "\nreturn driveFactoryRowsNow", "@Auras.lua:drive"))
        setfenv(chunk, setmetatable({ DF = LDF }, { __index = _G }))
        local drive = chunk()

        local f = { unit = "raid3" }
        W.same = false
        drive(f); eq(syncs, 1, "latch: first drive syncs")
        drive(f); eq(syncs, 1, "latch: same version, unit and answer -> skipped")
        W.same = true   -- roster reshuffle: raid3 is now YOU, token unchanged
        drive(f); eq(syncs, 2, "latch: same token now pointing at me forces one sync")
        drive(f); eq(syncs, 2, "latch: ...and only one")
        W.same = nil    -- withheld afterwards: keeps the definite answer, no flapping
        drive(f); eq(syncs, 2, "latch: a withheld read does not re-sync")
        W.same = false
        drive(f); eq(syncs, 3, "latch: moving off the token forces a sync again")
        LDF.auraLayoutVersion = 8
        drive(f); eq(syncs, 4, "latch: a version bump still syncs")
    end
end

-- ---- the editor offers it ---------------------------------------------------------------------
do
    local csrc = options_file_source("AuraDesigner/UI/Cards.lua"):gsub("\r\n", "\n")
    local a = csrc:find('GUI:CreateCheckbox(body, L["Only on My Frame"], proxy, "onlyMyFrame"', 1, true)
    check(a ~= nil, "gui: the effect card builds the checkbox bound to onlyMyFrame")
    if a then
        local guard = csrc:sub(math.max(1, a - 400), a)
        check(guard:find("if not P.IsPIHelperTab() then", 1, true) ~= nil,
              "gui: hidden on the Power Infusion helper's pool")
        check(not guard:find("if ShowsOthersOnly()", 1, true), "gui: not limited to the Any Buff pool")
    end
    check(csrc:find('addFact(L["Only on My Frame"])', 1, true) ~= nil,
          "gui: the collapsed header reuses the same label")
    local en = df_file_source("Locales/enUS.lua")
    check(en:find('L["Only on My Frame"] = true', 1, true) ~= nil, "gui: label string in enUS.lua")
    check(en:find('L["Only show this effect on your own frame. Use it for self-buffs such as Inner Fire."] = true', 1, true) ~= nil,
          "gui: tooltip string in enUS.lua")
end

W.same = nil
