local NS = ...

-- ============================================================
-- ONE TEST-SCOPE PREDICATE: DF:FrameInTestScope(frame, scope)
-- Every per-frame "does test mode apply to this frame" decision asks the
-- predicate instead of reading DF.testMode / DF.raidTestMode inline. For party,
-- raid and pinned frames it must give exactly the old inline answer; a
-- standalone frame is out of scope unless it is a preview frame.
-- ============================================================

local function norm(s) return (s:gsub("\r\n", "\n")) end

-- ---- load the predicate on its own ----
local src = norm(df_file_source("Frames/Core.lua"))
local a = src:find("function DF:FrameInTestScope%(")
local b = a and src:find("\nend\n", a, true)
check(a ~= nil and b ~= nil, "FrameInTestScope is defined in Frames/Core.lua")
local DF = { raidFrameRegistry = setmetatable({}, { __mode = "k" }) }
function DF:IsRaidFrame(frame)
    if not frame then return false end
    return frame.isRaidFrame or self.raidFrameRegistry[frame] or false
end
if a and b then
    local f, err = loadstring(src:sub(a, b + 4), "=FrameInTestScope")
    check(f ~= nil, "FrameInTestScope parses (" .. tostring(err) .. ")")
    setfenv(f, setmetatable({ DF = DF }, { __index = _G }))
    f()
end

print("-- party/raid/pinned frames: the old inline answers, every mode combination")
local registryRaid = {}                 -- raid frame whose field the template wiped
DF.raidFrameRegistry[registryRaid] = true
local frames = {
    party = {},
    raid = { isRaidFrame = true },
    registryRaid = registryRaid,
    pinnedParty = { isPinnedFrame = true },
    pinnedRaid = { isPinnedFrame = true, isRaidFrame = true },
    pinnedBoss = { isPinnedFrame = true, isPinnedBossFrame = true },
}
local function truthy(v) return v and true or false end
local mismatches = 0
for _, tm in ipairs({ false, true }) do
    for _, rtm in ipairs({ false, true }) do
        DF.testMode, DF.raidTestMode = tm, rtm
        for name, fr in pairs(frames) do
            local isRaid = DF:IsRaidFrame(fr)
            local want = {
                any = truthy(DF.testMode or DF.raidTestMode),
                own = truthy((isRaid and DF.raidTestMode) or (not isRaid and DF.testMode)),
                field = truthy((fr.isRaidFrame and DF.raidTestMode) or (not fr.isRaidFrame and DF.testMode)),
            }
            local got = {
                any = DF:FrameInTestScope(fr, "any"),
                own = DF:FrameInTestScope(fr),
                field = DF:FrameInTestScope(fr, fr.isRaidFrame and "raid" or "party"),
            }
            for k, v in pairs(want) do
                if got[k] ~= v then
                    mismatches = mismatches + 1
                    print(string.format("  MISMATCH %s %s tm=%s rtm=%s want=%s got=%s",
                        name, k, tostring(tm), tostring(rtm), tostring(v), tostring(got[k])))
                end
            end
        end
    end
end
eq(mismatches, 0, "every party/raid/pinned answer matches the inline check")

print("-- no frame: the old inline answers too")
DF.testMode, DF.raidTestMode = true, false
eq(DF:FrameInTestScope(nil, "any"), true, "nil frame, any")
eq(DF:FrameInTestScope(nil), true, "nil frame, own mode = party")

print("-- standalone frames are out of scope unless they are preview frames")
for _, tm in ipairs({ false, true }) do
    for _, rtm in ipairs({ false, true }) do
        DF.testMode, DF.raidTestMode = tm, rtm
        local live = { dfStandalone = true }
        local preview = { dfStandalone = true, dfPreview = true }
        for _, scope in ipairs({ "any", "raid", "party", false }) do
            local s = scope or nil
            eq(DF:FrameInTestScope(live, s), false, "standalone live, " .. tostring(scope) .. " tm=" .. tostring(tm) .. " rtm=" .. tostring(rtm))
            eq(DF:FrameInTestScope(preview, s), true, "standalone preview, " .. tostring(scope) .. " tm=" .. tostring(tm) .. " rtm=" .. tostring(rtm))
        end
    end
end
DF.testMode, DF.raidTestMode = false, false

-- ---- the test-data branch rewrite in Frames/Bars.lua ----
-- old:  if testMode and ti then PARTY elseif raidTestMode and ti then RAID else LIVE
-- new:  scope = ti and InScope(any); if scope and (testMode or not raidTestMode) then PARTY
--       elseif scope then RAID else LIVE
print("-- Bars test-data branches pick the same pool for party/raid frames")
local function oldBranch(tm, rtm, ti)
    if tm and ti ~= nil then return "party" elseif rtm and ti ~= nil then return "raid" end
    return "live"
end
local function newBranch(fr, tm, rtm, ti)
    DF.testMode, DF.raidTestMode = tm, rtm
    local testScope = ti ~= nil and DF:FrameInTestScope(fr, "any")
    if testScope and (DF.testMode or not DF.raidTestMode) then return "party"
    elseif testScope then return "raid" end
    return "live"
end
local branchMismatch = 0
for _, tm in ipairs({ false, true }) do
    for _, rtm in ipairs({ false, true }) do
        for _, ti in ipairs({ false, 1 }) do
            local tiv = ti or nil
            for _, fr in pairs(frames) do
                if oldBranch(tm, rtm, tiv) ~= newBranch(fr, tm, rtm, tiv) then branchMismatch = branchMismatch + 1 end
            end
        end
    end
end
eq(branchMismatch, 0, "branch choice identical for every party/raid/pinned case")
eq(newBranch({ dfStandalone = true, dfPreview = true }, false, false, {}), "party",
   "a preview frame with its own data table takes the data branch with no group mode on")
eq(newBranch({ dfStandalone = true }, true, false, 1), "live", "a live standalone frame stays live")
DF.testMode, DF.raidTestMode = false, false

-- ============================================================
-- SOURCE WALK: every converted site asks the predicate, and no per-frame raw
-- check of the same shape is left in those files.
-- ============================================================
print("-- every converted site asks the predicate")
local function count(s, pat) local _, n = s:gsub(pat, "") return n end
local sites = {
    -- file, predicate calls expected, raw per-frame patterns that must be gone
    { "Features/ElementAppearance.lua", 21, { "%(DF%.testMode or DF%.raidTestMode%) and not frame%.dfIsTestFrame" } },
    { "Features/HealthFade.lua", 2, { "%(DF%.testMode or DF%.raidTestMode%) and not frame%.dfIsTestFrame" } },
    { "Frames/Update.lua", 3, { "%(DF%.testMode or DF%.raidTestMode%) and frame%.dfIsTestFrame",
                                "isRaid and DF%.raidTestMode", "isRaidHF and DF%.raidTestMode" } },
    { "Frames/Bars.lua", 9, { "DF%.testMode and testIndex", "DF%.raidTestMode and testIndex",
                               "and not DF%.testMode and not DF%.raidTestMode",
                               "%(DF%.testMode or DF%.raidTestMode%) and testIndex" } },
    { "Frames/Create.lua", 4, { "if not DF%.testMode and not DF%.raidTestMode then",
                                "self%.isRaidFrame and DF%.raidTestMode" } },
    { "Features/Highlights.lua", 1, { "local inTestMode = DF%.testMode or DF%.raidTestMode" } },
    { "Features/Range.lua", 1, { "DF%.testMode or DF%.raidTestMode" } },
    { "Features/Dispel.lua", 2, { "and not %(DF%.testMode or DF%.raidTestMode%)",
                                  "isRaidFrame and DF%.raidTestMode%) or" } },
    { "Features/Auras.lua", 5, { "and not %(DF%.testMode or DF%.raidTestMode%)" } },  -- +1: the purgeable caps skip previews
    { "Features/UnhealableFade.lua", 1, { "DF%.testMode or DF%.raidTestMode" } },
    { "AuraDesigner/Factory.lua", 2, { "not %(DF%.testMode or DF%.raidTestMode%)" } },
    { "Features/PingMirror.lua", 1, { "DF%.testMode or DF%.raidTestMode" } },
    { "Frames/Pets.lua", 1, { "frame%.isRaidFrame and DF%.raidTestMode" } },
}
local total = 0
for _, s in ipairs(sites) do
    local text = norm(df_file_source(s[1]))
    local n = count(text, "DF:FrameInTestScope%(")
    total = total + n
    eq(n, s[2], s[1] .. ": predicate calls")
    for _, pat in ipairs(s[3]) do
        eq(count(text, pat), 0, s[1] .. ": no raw `" .. pat .. "` left")
    end
end
eq(total, 53, "53 per-frame decisions ask the predicate")

print("-- the one site that must not read the predicate keeps standalone frames out")
local dsrc = norm(df_file_source("Features/Dispel.lua"))
check(dsrc:find("if not frame%.dfStandalone and %(%(DF%.raidTestMode and not isRaidFrame%) or %(DF%.testMode and isRaidFrame%)%) then"),
      "Dispel: the other-mode hide skips standalone frames")
