local NS = ...

-- ============================================================
-- DEBUFF BAR: THE HIDE COLUMN, SECONDS AND HIDE PERMANENT
-- DandersFrames/Features/Auras.lua  BuildDirectDebuffFilters
-- ------------------------------------------------------------
-- The Show side picks categories (any of); the Hide side removes debuffs whatever
-- was picked (none of). Every Hide maps to a filter Blizzard applies on every
-- unit, so the records must carry it on each group, and a record that asserts the
-- very thing hidden must go rather than become a filter that matches nothing.
-- The real builder is lifted by name and run on plain tables.
-- ============================================================

print("-- Debuff Bar: Hide column, seconds threshold, Hide Permanent")

local src = df_file_source("Features/Auras.lua"):gsub("\r\n", "\n")
local a = src:find("local PERMANENT_DEBUFF_CAP = ", 1, true)
local b = src:find("-- Public facade over BuildDirectDebuffFilters", 1, true)
check(a ~= nil and b ~= nil and a < b, "hide: the helpers sit just above the builder")
if not (a and b) then return end

local prelude = [[
local AuraFilters = { CrowdControl = "CROWD_CONTROL", Dispellable = "DISPELLABLE", Raid = "RAID",
    Important = "IMPORTANT", RaidInCombat = "RAID_IN_COMBAT", RaidPlayerDispellable = "RAID_PLAYER_DISPELLABLE",
    Player = "PLAYER" }
local DISPEL_TYPES = { Magic = true, Curse = true, Disease = true, Poison = true, Bleed = true }
CANT_CLEANSE = { Disease = true }
local DF = { GetEngineDispelFlagGaps = function(_, selfOnly) return selfOnly and { Bleed = true } or nil end,
             GetDispelTypesToExclude = function() return CANT_CLEANSE end }
]]
local build = assert(loadstring(prelude .. src:sub(a, b - 1) .. "\nreturn BuildDirectDebuffFilters"))()

local function db(t)
    local d = { directDebuffDispellableMode = "PLAYER", debuffMaxDurationMinutes = 5,
                debuffMaxDurationSeconds = 5, debuffMaxDurationUnit = "MINUTES" }
    for k, v in pairs(t) do d[k] = v end
    return d
end
local function count(s, pat)
    local n = 0
    for _ in s:gmatch(pat) do n = n + 1 end
    return n
end

-- ---- untouched defaults are untouched --------------------------------------
check(build(db({ directDebuffShowAll = true })) == nil,
      "defaults: All Debuffs with nothing hidden is still show-all (nil)")

-- ---- the Coiled Altar combo --------------------------------------------------
do
    local r = build(db({ directDebuffShowAll = true, debuffHidePlayer = true, debuffHideBoss = true,
                         debuffMaxDurationEnabled = true, debuffMaxDurationUnit = "SECONDS",
                         debuffMaxDurationSeconds = 5 }))
    check(r and #r == 1, "combo: one record")
    local rec = r and r[1]
    local cf = rec and rec.candidateFilters or {}
    check(rec and rec.filter == "HARMFUL", "combo: plain HARMFUL")
    check(cf.isFromPlayerOrPlayerPet == false, "combo: player-cast debuffs hidden")
    check(cf.isBossAura == false, "combo: boss debuffs hidden")
    check(cf.maxDuration == 5, "combo: capped at five seconds")
end

-- ---- seconds only while enabled --------------------------------------------------
do
    local r = build(db({ directDebuffShowAll = true, debuffMaxDurationUnit = "SECONDS" }))
    check(r == nil, "seconds: the unit alone caps nothing while Hide Long Debuffs is off")
end

-- ---- who cast it -------------------------------------------------------------------------
do
    local function keyed(r)
        local by = {}
        for _, rec in ipairs(r or {}) do by[rec.key] = rec end
        return by
    end
    local by = keyed(build(db({ debuffFilterNonPlayer = true, debuffFilterMagic = true })))
    check(by.nonplayer and by.nonplayer.candidateFilters.isFromPlayerOrPlayerPet == false,
          "who: Non-Player shows what no player cast")
    by = keyed(build(db({ debuffFilterPlayer = true, debuffFilterMagic = true })))
    check(by.anyplayer and by.anyplayer.candidateFilters.isFromPlayerOrPlayerPet == true,
          "who: From Any Player shows what a player cast")
    check(by.anyplayer and by.anyplayer.candidateFilters.excludeDispelTypes
          and by.anyplayer.candidateFilters.excludeDispelTypes.Magic,
          "who: ...leaving a picked dispel type to its own record")

    -- Both shown is every debuff: built as All Debuffs, one record under one cap.
    local everything = { debuffFilterBoss = true, debuffFilterRole = true, debuffFilterPriority = true,
        debuffFilterCrowdControl = true, debuffFilterDispellable = true, debuffFilterNonPlayer = true,
        debuffFilterPlayer = true, debuffFilterMagic = true, debuffFilterCurse = true,
        debuffFilterPoison = true, debuffFilterDisease = true, debuffFilterBleed = true }
    check(build(db(everything)) == nil, "who: both shown with every other tick is plain All Debuffs")
    local adGroup = build(db({ debuffEmptyShowsNothing = true, debuffFilterNonPlayer = true, debuffFilterPlayer = true }))
    check(adGroup and #adGroup == 1 and adGroup[1].filter == "HARMFUL",
          "who: an Aura Designer group gets the record spelled out (nil there means nothing)")
    local t = {}
    for k, v in pairs(everything) do t[k] = v end
    t.debuffHideBoss = true
    t.debuffFilterBoss = nil
    local r = build(db(t))
    check(r and #r == 1 and r[1].key == "all" and r[1].candidateFilters.isBossAura == false,
          "who: ...a Hide still applies, in the one record")
    t = {}
    for k, v in pairs(everything) do t[k] = v end
    t.debuffImportantHighlight = true
    r = build(db(t))
    check(r and #r == 3 and r[1].key == "allboss" and r[1].style ~= nil,
          "who: ...and the highlight splits it the way All Debuffs does")
    t = {}
    for k, v in pairs(everything) do t[k] = v end
    t.debuffMaxDurationEnabled, t.debuffMaxDurationKeepImportant = true, true
    by = keyed(build(db(t)))
    check(by.bossrole and by.nonplayer and by.anyplayer,
          "who: Keep Important on shown important debuffs keeps the categories (All cannot exempt them)")
    r = build(db({ debuffFilterMine = true, debuffFilterCrowdControl = true }))
    by = {}
    for _, rec in ipairs(r or {}) do by[rec.key] = rec end
    check(by.mine and by.mine.filter == "HARMFUL|PLAYER|!CROWD_CONTROL", "who: Cast By You rides the PLAYER token")
    r = build(db({ directDebuffShowAll = true, debuffHideMine = true }))
    check(r and r[1] and r[1].filter == "HARMFUL|!PLAYER", "who: Hide Cast By You negates it")
end

-- ---- the uncleansable band (engine flags a dispel the character has not talented) -------
do
    local r = build(db({ debuffFilterDispellable = true, debuffFilterNonPlayer = true }))
    local by = {}
    for _, rec in ipairs(r or {}) do by[rec.key] = rec end
    check(by["nonplayer+u"] and by["nonplayer+u"].filter == "HARMFUL|RAID"
          and by["nonplayer+u"].candidateFilters.includeDispelTypes.Disease,
          "uncleansable: a mob disease the player cannot cure still shows under Non-Player")
    -- The Raid row is By Me, talent-corrected: on its own it builds the By Me record.
    r = build(db({ debuffFilterRaid = true }))
    by = {}
    for _, rec in ipairs(r or {}) do by[rec.key] = rec end
    check(by.dispel and by.dispel.filter == "HARMFUL|RAID" and by.dispel.candidateFilters.excludeDispelTypes.Disease,
          "raid: the Raid row is Dispellable By Me, without the dispels the character has not talented")
    r = build(db({ debuffFilterRaid = true, debuffFilterDispellable = true, directDebuffDispellableMode = "ALL" }))
    check(r and #r == 1 and r[1].filter == "HARMFUL|DISPELLABLE", "raid: ...and adds nothing beside All Dispellable")
    r = build(db({ directDebuffShowAll = true, debuffHideRaid = true }))
    by = {}
    for _, rec in ipairs(r or {}) do by[rec.key] = rec end
    check(by.all and by.all.filter == "HARMFUL|!RAID" and by["all+u"]
          and by["all+u"].candidateFilters.includeDispelTypes.Disease,
          "raid: Hide Raid hides what By Me hides, keeping the dispels the character cannot do")
end

-- ---- a Dwarf's own frame: Stoneform bleeds count as By Me there and nowhere else ----------
do
    local function keys(r)
        local by = {}
        for _, rec in ipairs(r or {}) do by[rec.key] = rec end
        return by
    end
    local mine = keys(build(db({ debuffFilterDispellable = true }), nil, true))
    check(mine.dispelgap and mine.dispelgap.candidateFilters.includeDispelTypes.Bleed,
          "dwarf: own frame shows bleeds under Dispellable By Me")
    local others = keys(build(db({ debuffFilterDispellable = true })))
    check(others.dispelgap == nil, "dwarf: ...but not on anyone else's frame")
    local r = build(db({ directDebuffShowAll = true, debuffHideDispellable = true }), nil, true)
    check(r and r[1] and r[1].candidateFilters and r[1].candidateFilters.excludeDispelTypes
          and r[1].candidateFilters.excludeDispelTypes.Bleed,
          "dwarf: Hide By Me also hides own bleeds")
    local drive = src:sub(src:find("function DF:DriveDebuffFactory", 1, true) or 1)
    check(drive:find("(frame.dfDebuffFactoryVersion ~= ver or selfMoved)", 1, true) ~= nil,
          "dwarf: a frame reassigned to or from the player re-plans without a layout bump")
    local fac = df_file_source("AuraDesigner/Factory.lua"):gsub("\r\n", "\n")
    check(fac:find("resolveDebuffGroup(group, dedupOn and claimedSoFar or nil, racialSelf)", 1, true) ~= nil
          and fac:find('local slot = selfOnly and "self" or "other"', 1, true) ~= nil,
          "dwarf: Aura Designer groups resolve per self-ness, cached in separate slots")
end

-- ---- the retired Raid row migrates onto Dispellable By Me --------------------------------
do
    local a2 = src:find("function DF:MigrateRaidDebuffRow", 1, true)
    local b2 = a2 and src:find("\nend\n", a2, true)
    local mig = a2 and b2 and assert(loadstring("local DF = {}\n" .. src:sub(a2, b2 + 4)
        .. "\nreturn function(t, sel) DF:MigrateRaidDebuffRow(t, sel) end"))()
    check(mig ~= nil, "raid migration: lifted")
    if mig then
        local t = { debuffFilterRaid = true, directDebuffDispellableMode = "ALL" }
        mig(t)
        check(t.debuffFilterDispellable == true and t.directDebuffDispellableMode == "PLAYER" and t.debuffFilterRaid == false,
              "raid migration: Raid alone becomes Dispellable By Me")
        t = { debuffFilterRaid = true, debuffFilterDispellable = true, directDebuffDispellableMode = "ALL" }
        mig(t)
        check(t.directDebuffDispellableMode == "ALL" and t.debuffFilterRaid == false,
              "raid migration: beside a shown Dispellable (either mode) it is only cleared")
        t = { debuffHideRaid = true, directDebuffDispellableMode = "ALL" }
        mig(t)
        check(t.debuffHideDispellable == true and t.directDebuffDispellableMode == "PLAYER" and t.debuffHideRaid == false,
              "raid migration: Hide Raid becomes Hide Dispellable By Me")
        t = { debuffFilterBoss = true, directDebuffDispellableMode = "ALL" }
        mig(t)
        check(t.debuffFilterDispellable == nil and t.directDebuffDispellableMode == "ALL",
              "raid migration: a profile that never ticked Raid is untouched")
        local s = { raid = true, dispellableMode = "ALL" }
        mig(s, true)
        check(s.dispellable == true and s.dispellableMode == "PLAYER" and s.raid == nil,
              "raid migration: an Aura Designer group's selection moves the same way")
        t = { debuffFilterRaid = true, debuffHideRaid = true, directDebuffDispellableMode = "ALL" }
        mig(t)
        check(t.debuffHideDispellable == true and not t.debuffFilterDispellable
              and t.directDebuffDispellableMode == "PLAYER",
              "raid migration: Show and Hide both ticked was Hide, and stays Hide")
    end
end

-- ---- raid auto-layout overrides keep what they meant -------------------------------------
do
    local a2 = src:find("function DF:MigrateRaidDebuffRow", 1, true)
    local a3 = src:find("function DF:MigrateRaidDebuffOverrides", 1, true)
    local b3 = a3 and src:find("\nend\n", a3, true)
    local migOv = a2 and b3 and assert(loadstring("local DF = {}\n" .. src:sub(a2, b3 + 4)
        .. "\nreturn function(base, auto) DF:MigrateRaidDebuffOverrides(base, auto); DF:MigrateRaidDebuffRow(base) end"))()
    check(migOv ~= nil, "raid override migration: lifted")
    if migOv then
        local function layout(ov) return { profiles = { { overrides = ov } } } end
        -- Base had Raid on, the layout switched it off: the layout must not inherit By Me.
        local base = { debuffFilterRaid = true, debuffFilterDispellable = false, debuffHideRaid = false,
                       debuffHideDispellable = false, directDebuffDispellableMode = "ALL" }
        local ov = { debuffFilterRaid = false }
        migOv(base, { instanced = layout(ov) })
        check(base.debuffFilterDispellable == true and base.directDebuffDispellableMode == "PLAYER",
              "raid override migration: the base moves to By Me")
        check(ov.debuffFilterDispellable == false and ov.debuffFilterRaid == nil,
              "raid override migration: a layout that had Raid off keeps Dispellable off")
        -- Base without Raid, the layout ticked it: the layout gets By Me, the base nothing.
        base = { debuffFilterRaid = false, debuffFilterDispellable = false, debuffHideRaid = false,
                 debuffHideDispellable = false, directDebuffDispellableMode = "ALL" }
        ov = { debuffFilterRaid = true }
        migOv(base, { openWorld = layout(ov) })
        check(base.debuffFilterDispellable == false and base.directDebuffDispellableMode == "ALL",
              "raid override migration: an untouched base stays untouched")
        check(ov.debuffFilterDispellable == true and ov.directDebuffDispellableMode == "PLAYER"
              and ov.debuffFilterRaid == nil,
              "raid override migration: a layout's own Raid tick becomes its own By Me")
        -- Nothing Raid anywhere: the override table is left exactly as it was.
        base = { debuffFilterRaid = false, debuffHideRaid = false, directDebuffDispellableMode = "ALL" }
        ov = { debuffFilterBoss = true }
        migOv(base, { mythic = { profile = { overrides = ov } } })
        local n = 0
        for _ in pairs(ov) do n = n + 1 end
        check(n == 1 and ov.debuffFilterBoss == true, "raid override migration: no Raid, no change")
    end
end

-- ---- the Max Debuffs ceiling counts the records a claim adds -----------------------------
do
    local a4 = src:find("local GROUP_COUNT_CLAIMS", 1, true)
    local b4 = a4 and src:find("\nend\n", a4, true)
    local groupCount = a4 and b4 and assert(loadstring("local DF = {}\nlocal BuildDirectDebuffFilters = ...\n"
        .. src:sub(a4, b4 + 4) .. "\nreturn function(d) return DF:GetDebuffRowGroupCount(d) end"))(build)
    check(groupCount ~= nil, "group count: lifted")
    if groupCount then
        local d = db({ directDebuffShowAll = true })
        local most = 1
        for _, c in ipairs({ false, { dispellable = true } }) do
            for _, so in ipairs({ false, true }) do
                local r = build(d, c or nil, so)
                if r and #r > most then most = #r end
            end
        end
        local plain = build(d, nil) or {}
        check(groupCount(d) == most, "group count: the ceiling is the largest build, claims included")
        check(groupCount(d) >= #plain, "group count: never below the unclaimed build")
    end
end

-- ---- Match All (Aura Designer groups) ----------------------------------------------------
do
    local r = build(db({ debuffEmptyShowsNothing = true, debuffMatchAll = true,
                         debuffFilterBoss = true, debuffFilterMagic = true }))
    check(r and #r == 1 and r[1].filter == "HARMFUL" and r[1].candidateFilters.isBossAura == true
          and r[1].candidateFilters.includeDispelTypes.Magic,
          "match all: Boss and Magic is one record, magic boss debuffs only")
    r = build(db({ debuffEmptyShowsNothing = true, debuffMatchAll = true,
                   debuffFilterNonPlayer = true, debuffFilterPlayer = true }))
    check(r and #r == 0, "match all: Non-Player and From Any Player together match nothing")
    r = build(db({ debuffEmptyShowsNothing = true, debuffMatchAll = true,
                   debuffFilterCrowdControl = true, debuffFilterImportant = true }))
    check(r and r[1] and r[1].filter == "HARMFUL|CROWD_CONTROL|IMPORTANT", "match all: tokens AND in one string")
end

-- ---- the highlight marks important debuffs the important rows do not show -----------------
do
    local r = build(db({ debuffImportantHighlight = true, debuffFilterNonPlayer = true }))
    local styled, plain = 0, 0
    for _, rec in ipairs(r or {}) do
        if rec.style then styled = styled + 1 else plain = plain + 1 end
    end
    check(styled == 2 and plain == 1 and r[1].style and r[2].style,
          "highlight: a boss/role and a priority copy of Non-Player lead, styled, before the rest")
end

-- ---- a retired mode value reads as By Me --------------------------------------------------
do
    local r = build(db({ debuffFilterDispellable = true, directDebuffDispellableMode = "GROUP" }))
    local by = {}
    for _, rec in ipairs(r or {}) do by[rec.key] = rec end
    check(by.dispel and by.dispel.filter == "HARMFUL|RAID", "mode: an unknown stored mode shows by-me dispels")
    r = build(db({ directDebuffShowAll = true, debuffHideDispellable = true, directDebuffDispellableMode = "GROUP" }))
    check(r and r[1] and r[1].filter == "HARMFUL|!RAID", "mode: ...and Hide follows it")
end
do
    local w = options_file_source("GUI/SettingsWidgets.lua"):gsub("\r\n", "\n")
    check(w:find("if on and otherKey and dbTable[otherKey] then", 1, true) ~= nil,
          "rows: ticking Show or Hide clears the other box")
end

-- ---- Show and Hide both set (an old profile): Hide wins -----------------------------
do
    local r = build(db({ debuffFilterBoss = true, debuffHideBoss = true }))
    check(r and #r == 0, "both: Show Boss + Hide Boss renders nothing (empty list parks the row)")
    r = build(db({ debuffFilterRaid = true, debuffHideMagic = true }))
    local ex = r and r[1] and r[1].candidateFilters and r[1].candidateFilters.excludeDispelTypes or {}
    check(ex.Magic, "both: Show Raid + Hide Magic keeps raid debuffs except magic ones")
end
do
    -- With the highlight on, All Debuffs splits into boss-or-role / priority / rest.
    local r = build(db({ directDebuffShowAll = true, debuffImportantHighlight = true, debuffHideBoss = true }))
    check(r and #r == 3, "split: all three All Debuffs records survive Hide Boss")
    for _, rec in ipairs(r or {}) do
        check(rec.candidateFilters and rec.candidateFilters.isBossAura == false,
              "split: " .. tostring(rec.key) .. " carries isBossAura = false")
    end
end

-- ---- tokens negate once, and a positive token drops its record ---------------------
do
    local r = build(db({ directDebuffShowAll = true, debuffHideRaid = true, debuffHideDispellable = true }))
    check(r and r[1] and r[1].filter == "HARMFUL|!RAID" and count(r[1].filter, "!RAID") == 1,
          "raid: Hide Raid and Hide Dispellable (by me) share one token and negate it once")
end
do
    local r = build(db({ directDebuffShowAll = true, debuffHideCrowdControl = true }))
    check(r and r[1] and r[1].filter == "HARMFUL|!CROWD_CONTROL", "cc: All Debuffs minus crowd control")
end
do
    local r = build(db({ directDebuffShowAll = true, debuffHideDispellable = true,
                         directDebuffDispellableMode = "ALL" }))
    check(r and r[1] and r[1].filter == "HARMFUL|!DISPELLABLE", "dispel: All mode hides the whole DISPELLABLE set")
    r = build(db({ directDebuffShowAll = true, debuffHideDispellable = true }))
    check(r and r[1] and r[1].filter == "HARMFUL|!RAID", "dispel: By Me mode hides what you can dispel")
end

-- ---- contradictions ---------------------------------------------------------------
do
    local r = build(db({ directDebuffShowAll = true, debuffHidePlayer = true, debuffHideNonPlayer = true }))
    check(r and #r == 0, "both: hiding player and non-player debuffs renders nothing")
end

-- ---- nothing picked: the show-all fallback, still minus what is hidden ---------------
do
    local r = build(db({ debuffHideBoss = true }))
    check(r and #r == 1 and r[1].filter == "HARMFUL" and r[1].candidateFilters.isBossAura == false,
          "empty: no categories = show all, minus what is hidden")
end

-- ---- Hide Permanent -----------------------------------------------------------------
do
    local r = build(db({ directDebuffShowAll = true, debuffHidePermanent = true }))
    check(r and r[1] and r[1].candidateFilters and r[1].candidateFilters.maxDuration == 2147483647,
          "permanent: All Debuffs gets an unreachable cap")
    r = build(db({ debuffFilterBoss = true, debuffHidePermanent = true, debuffMaxDurationEnabled = true,
                   debuffMaxDurationKeepImportant = true }))
    local cf = r and r[1] and r[1].candidateFilters or {}
    check(cf.maxDuration == nil,
          "permanent: under a length cap Hide Permanent is inert (greyed), so Keep Important keeps permanent boss debuffs")
    r = build(db({ debuffFilterBoss = true, debuffHidePermanent = true, debuffMaxDurationKeepImportant = true }))
    cf = r and r[1] and r[1].candidateFilters or {}
    check(cf.maxDuration == 2147483647, "permanent: without a length cap it hides permanent boss debuffs too")
end

-- ---- the later categories tile ------------------------------------------------------
do
    local r = build(db({ debuffFilterCrowdControl = true, debuffFilterImportant = true,
                         debuffFilterRaidInCombat = true }))
    local by = {}
    for _, rec in ipairs(r or {}) do by[rec.key] = rec end
    check(by.important and by.important.filter == "HARMFUL|IMPORTANT|!CROWD_CONTROL",
          "later: Important negates the crowd control record above it")
    check(by.raidcombat and by.raidcombat.filter == "HARMFUL|RAID_IN_COMBAT|!CROWD_CONTROL|!IMPORTANT",
          "later: Raid In Combat negates both records above it")
end

-- ---- per-type picks ------------------------------------------------------------------
do
    local r = build(db({ debuffFilterMagic = true, debuffFilterPoison = true }))
    local rec = r and r[1]
    local inc = rec and rec.candidateFilters and rec.candidateFilters.includeDispelTypes or {}
    check(rec and rec.key == "types" and inc.Magic and inc.Poison and not inc.Curse,
          "types: one record including exactly the picked types")
    r = build(db({ debuffFilterMagic = true, debuffFilterPoison = true }), { magic = true })
    inc = r and r[1] and r[1].candidateFilters.includeDispelTypes or {}
    check(inc.Poison and not inc.Magic, "types: a type claimed by an Aura Designer group leaves the record")
    r = build(db({ debuffFilterMagic = true }), { magic = true })
    check(r and #r == 0, "types: claiming every picked type empties the row")
    r = build(db({ directDebuffShowAll = true, debuffHideBleed = true }))
    local ex = r and r[1] and r[1].candidateFilters.excludeDispelTypes or {}
    check(ex.Bleed and not ex.Magic, "types: All Debuffs minus bleeds")
end

-- ---- merging never writes into a shared table ------------------------------------------
do
    local r = build(db({ debuffFilterDispellable = true }), { bleed = true })
    local ex = r and r[1] and r[1].candidateFilters.excludeDispelTypes or {}
    check(ex.Disease and ex.Bleed, "merge: the dispel record keeps its own exclude and gains the claimed type")
    check(CANT_CLEANSE.Bleed == nil, "merge: the shared exclude table is untouched")
end

-- ---- Aura Designer claims on the new categories -----------------------------------------
do
    local r = build(db({ directDebuffShowAll = true }), { important = true, magic = true })
    local rec = r and r[1]
    check(rec and rec.filter == "HARMFUL|!IMPORTANT", "claims: a claimed Important comes off the row")
    check(rec and rec.candidateFilters and rec.candidateFilters.excludeDispelTypes
          and rec.candidateFilters.excludeDispelTypes.Magic, "claims: a claimed type comes off the row")
    r = build(db({ debuffFilterImportant = true, debuffFilterRaid = true }), { important = true })
    for _, x in ipairs(r or {}) do
        check(x.key ~= "important", "claims: the claimed category's own record is dropped")
    end
end

-- ---- an Aura Designer group with nothing picked stays empty ---------------------------
do
    check(build(db({ debuffEmptyShowsNothing = true, debuffHideBoss = true, debuffHidePermanent = true })) == nil,
          "group: hides alone never turn an empty group into show-all")
end

-- ---- the Aura Designer facade maps every new key ------------------------------------------
do
    local fac = df_file_source("AuraDesigner/Factory.lua"):gsub("\r\n", "\n")
    local a2 = fac:find("local DGROUP_FLAG_KEYS = {", 1, true)
    local b2 = a2 and fac:find("\n}\n", a2, true)
    local block = (a2 and b2) and fac:sub(a2, b2) or ""
    for _, k in ipairs({ "Important", "RaidInCombat", "Magic", "Curse", "Poison", "Disease", "Bleed" }) do
        check(block:find('"debuffFilter' .. k .. '"', 1, true), "facade: maps debuffFilter" .. k)
        check(block:find('"debuffHide' .. k .. '"', 1, true), "facade: maps debuffHide" .. k)
    end
    for _, k in ipairs({ "Boss", "Role", "Priority", "CrowdControl", "Raid", "Dispellable", "NonPlayer", "Player", "Mine", "Permanent" }) do
        check(block:find('"debuffHide' .. k .. '"', 1, true), "facade: maps debuffHide" .. k)
    end
    for _, k in ipairs({ "NonPlayer", "Player", "Mine" }) do
        check(block:find('"debuffFilter' .. k .. '"', 1, true), "facade: maps the Who Cast It show debuffFilter" .. k)
    end
    local folds = 0
    for _ in fac:gmatch("= foldGroupClaims%(group%.selection, ") do folds = folds + 1 end
    check(folds == 2, "claims: the bar and the group-over-group dedup share one fold")
    check(fac:find("if sel[k] and groupShowsAllOf(sel, k) then", 1, true) ~= nil,
          "claims: a group claims a category only when it shows all of it")
end

-- ---- out of the box: every new key ships off -----------------------------------------------
do
    local cfg = df_file_source("Core/Config.lua")
    for _, k in ipairs({ "Important", "RaidInCombat", "Magic", "Curse", "Poison", "Disease", "Bleed" }) do
        check(cfg:find("debuffFilter" .. k .. " = false", 1, true), "defaults: debuffFilter" .. k .. " ships off")
        check(cfg:find("debuffHide" .. k .. " = false", 1, true), "defaults: debuffHide" .. k .. " ships off")
    end
    check(cfg:find('debuffMaxDurationUnit = "MINUTES"', 1, true), "defaults: the threshold unit ships as Minutes")
end
