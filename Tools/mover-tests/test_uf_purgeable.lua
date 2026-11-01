local NS = ...

-- ============================================================
-- UNIT FRAMES COMPANION -- PURGEABLE BUFFS
-- DandersFrames/Features/Auras.lua (SplitBuffRowForPurge, rowPurge, recStyleSig),
-- DandersFrames/Frames/AuraContainer.lua (the record highlight ring) and
-- DandersFrames_UnitFrames/Elements.lua (UF.BuffPurgeable, the frames' hook).
-- ------------------------------------------------------------
-- The ENGINE decides which buffs the player can purge: the buff row is split into
-- a RAID_PLAYER_DISPELLABLE group (first, ringed) and the rest with the token
-- negated. A friendly unit keeps the split but its purgeable group is held dark
-- (a tuning change, never a rebuild), so friendly buffs never glow. Nothing reads
-- an aura. The DF blocks are lifted out by their source text.
-- ============================================================

local G, G_NAMES = {}, { "DandersFrames", "UnitExists", "UnitCanAttack", "issecretvalue", "LibStub" }
for _, k in ipairs(G_NAMES) do G[k] = _G[k] end

local NL = string.char(10)
local auras = df_file_source("Features/Auras.lua"):gsub("\r\n", "\n")
local src = df_file_source("Frames/AuraContainer.lua"):gsub("\r\n", "\n")

local function lift(text, from, to)
    local s = text:find(from, 1, true)
    local e = s and text:find(to, s, true)
    check(s ~= nil and e ~= nil, "setup: found the block starting " .. from)
    if not (s and e) then return "" end
    return text:sub(s, e + #to - 1)
end

-- ---- SplitBuffRowForPurge ----------------------------------------------------
print("-- The row split: purgeable first, the rest with the token negated")
do
    local block = lift(auras, "local PURGE_DEAD_CF = { maxDuration = 0 }", "DF.SplitBuffRowForPurge = SplitBuffRowForPurge")
    local DFx = {}
    local split = assert(loadstring("local AuraFilters, DF = ...\n" .. block .. "\nreturn SplitBuffRowForPurge",
        "@SplitBuffRowForPurge"))({}, DFx)
    eq(DFx.SplitBuffRowForPurge, split, "exported for the drive and the tests")
    DF_SPLIT = split
    local db = {}

    local out = split({ "HELPFUL" }, true, db)
    eq(#out, 2, "one plain record: two groups")
    eq(out[1].filter, "HELPFUL|RAID_PLAYER_DISPELLABLE", "first: the purgeable buffs (the engine's own token)")
    eq(out[1].key, "row1_purge", "...keyed")
    eq(out[1].candidateFilters, nil, "...the row's own candidate filters (none of its own)")
    check(out[1].style and out[1].style.highlight and out[1].style.highlight.db == db
          and out[1].style.highlight.prefix == "buffPurgeable", "...ringed from the buffPurgeable border keys")
    eq(out[2].filter, "HELPFUL|!RAID_PLAYER_DISPELLABLE", "second: everything else")
    eq(out[2].key, "row1_rest", "...keyed")
    eq(out[2].style, nil, "...plain")

    local fr = split({ "HELPFUL" }, false, db)
    eq(fr[1].key .. "," .. fr[2].key, "row1_purge,row1_rest", "a friendly unit: the same two keys (a tuning change, no rebuild)")
    eq(fr[1].candidateFilters and fr[1].candidateFilters.maxDuration, 0, "...the purgeable group held dark")
    eq(fr[2].filter, "HELPFUL", "...every buff in the plain group")
    eq(fr[2].style, nil, "...which is not ringed")

    local mineCF, othersCF = { excludeSpellIDs = { [1] = true } }, { includeSpellIDs = { [2] = true } }
    local recs = split({
        { filter = "HELPFUL|PLAYER", key = "mine", candidateFilters = mineCF, noVisLatch = true },
        { filter = "HELPFUL|!PLAYER", key = "others", candidateFilters = othersCF, noVisLatch = true },
    }, true, db)
    local ks = {}
    for i, r in ipairs(recs) do ks[i] = r.key end
    eq(table.concat(ks, ","), "mine_purge,others_purge,mine_rest,others_rest", "the own-cast split: both purgeable groups first")
    eq(recs[1].candidateFilters, mineCF, "...each keeps its own candidate filters")
    eq(recs[4].candidateFilters, othersCF, "...on both halves")
    check(recs[1].noVisLatch and recs[3].noVisLatch, "...and its visibility-latch exemption")
    check(recs[1].style == recs[2].style, "...ONE style table for every purgeable group (the preview's single-style shape)")
    local dark = split({ { filter = "HELPFUL|PLAYER", key = "mine", candidateFilters = mineCF } }, false, db)
    eq(dark[1].candidateFilters.maxDuration, 0, "friendly: a record's own filters give way to the dead map")
    eq(dark[2].candidateFilters, mineCF, "...the plain group keeps them")

    local odd = { { nope = true } }
    eq(split(odd, true, db), odd, "an unknown shape comes back unchanged")
    eq(#split("HELPFUL", true, db), 2, "a bare string is one plain record")
    check(auras:find("filter = SplitBuffRowForPurge(filter, opts.purge, db)", 1, true) ~= nil,
          "BuildAuraRowConfig splits the buff row when the frame's hook answered")
    local _, n = auras:gsub("purge = purge,", "")
    eq(n, 2, "the buff drive passes the answer (create and rebuild)")
end

-- ---- keep the row's Max ------------------------------------------------------
print("-- The split keeps the row at Max in all")
do
    local split = DF_SPLIT
    local DFx = { DebugWarn = function() end }
    local block = lift(auras, "local function countRet(ok, _token, ...)", NL .. "    return caps" .. NL .. "end" .. NL)
    assert(loadstring("local DF, C_UnitAuras = ..." .. NL .. block, "@BuffPurgeCaps"))(DFx, nil)
    local function counts(map) return function(_, f) return map[f] end end
    local recs = split({ "HELPFUL" }, true, {})
    local caps = DFx:BuffPurgeCaps(recs, "target", 8, counts({ ["HELPFUL|RAID_PLAYER_DISPELLABLE"] = 3 }))
    eq(caps and (caps.row1_purge .. "/" .. caps.row1_rest), "8/5", "3 purgeable of Max 8: purgeable keeps 8, the rest gets 5")
    caps = DFx:BuffPurgeCaps(recs, "target", 8, counts({ ["HELPFUL|RAID_PLAYER_DISPELLABLE"] = 0 }))
    eq(caps.row1_rest, 8, "none purgeable: the rest gets all 8")
    caps = DFx:BuffPurgeCaps(recs, "target", 8, counts({ ["HELPFUL|RAID_PLAYER_DISPELLABLE"] = 12 }))
    eq(caps.row1_purge .. "/" .. caps.row1_rest, "8/0", "more purgeable than Max: 8 of them, nothing else")
    eq(DFx:BuffPurgeCaps(recs, "target", 8, counts({})), nil, "no count: no caps (every group back to Max, the old row)")
    eq(DFx:BuffPurgeCaps(nil, "target", 8, counts({})), nil, "no records: no caps")
    eq(DFx:BuffPurgeCaps(recs, "target", nil, counts({})), nil, "no Max: no caps")
    local own = split({
        { filter = "HELPFUL|PLAYER", key = "mine" },
        { filter = "HELPFUL|!PLAYER", key = "others" },
    }, true, {})
    caps = DFx:BuffPurgeCaps(own, "target", 8, counts({
        ["HELPFUL|PLAYER|RAID_PLAYER_DISPELLABLE"] = 2,
        ["HELPFUL|!PLAYER|RAID_PLAYER_DISPELLABLE"] = 7,
        ["HELPFUL|PLAYER|!RAID_PLAYER_DISPELLABLE"] = 1 }))
    eq(caps.mine_purge .. "," .. caps.others_purge .. "," .. caps.mine_rest .. "," .. caps.others_rest, "8,6,0,0",
       "own-cast split: one budget, purgeable groups first (2 + 6 = 8), the rest gets nothing")
    caps = DFx:BuffPurgeCaps(own, "target", 8, counts({
        ["HELPFUL|PLAYER|RAID_PLAYER_DISPELLABLE"] = 1,
        ["HELPFUL|!PLAYER|RAID_PLAYER_DISPELLABLE"] = 1,
        ["HELPFUL|PLAYER|!RAID_PLAYER_DISPELLABLE"] = 2 }))
    eq(caps.mine_purge .. "," .. caps.others_purge .. "," .. caps.mine_rest .. "," .. caps.others_rest, "8,7,6,4",
       "...1 + 1 purgeable, 2 of yours: the others' plain buffs get the last 4")

    -- The count: the number of slots, never a slot's contents.
    local secret = setmetatable({}, { __eq = function() error("compared a slot") end })
    local api = { GetAuraSlots = function(unit, filter, cap) return nil, secret, secret, secret end }
    assert(loadstring("local DF, C_UnitAuras = ..." .. NL .. block, "@BuffPurgeCaps"))(DFx, api)
    eq(DFx:CountAuraSlots("target", "HELPFUL|RAID_PLAYER_DISPELLABLE", 8), 3, "three slots back: 3 (only counted)")
    eq(DFx:CountAuraSlots("target", "HELPFUL", 2), 2, "...never above the cap asked for")
    api.GetAuraSlots = function() error("no access") end
    eq(DFx:CountAuraSlots("target", "HELPFUL", 8), nil, "an error: no count")
    assert(loadstring("local DF, C_UnitAuras = ..." .. NL .. block, "@BuffPurgeCaps"))(DFx, {})
    eq(DFx:CountAuraSlots("target", "HELPFUL", 8), nil, "no API: no count")
    eq(DFx:CountAuraSlots(nil, "HELPFUL", 8), nil, "no unit: no count")

    check(auras:find("caps = DF:BuffPurgeCaps(h.config and h.config.filter, frame.unit, h.config and h.config.max)", 1, true) ~= nil,
          "the buff drive counts a hostile split...")
    check(auras:find("if purge == true and not DF:FrameInTestScope(frame, \"any\") then", 1, true) ~= nil,
          "...only a live hostile one (friendly, off and previews: no caps)")
    check(auras:find("h:SetGroupMaxOverrides(caps)", 1, true) ~= nil, "...and hands the caps to the row")
end

print("-- The row's per-group caps (AuraContainer)")
do
    local block = lift(src, "function groupMaxFor(handle, key, maxCount)", NL .. "function Handle:ApplyTuning(tuning)")
    block = block:gsub(NL .. "function Handle:ApplyTuning%(tuning%)$", "")
    local Handle, testShape, bounced = {}, false, 0
    local env = assert(loadstring("local testShapeFor, bounceContainer, Handle = ..." .. NL .. "local groupMaxFor" .. NL .. block
        .. NL .. "return groupMaxFor", "@groupMaxFor"))
    local groupMaxFor = env(function() return testShape end, function() bounced = bounced + 1 end, Handle)
    eq(groupMaxFor({}, "a", 8), 8, "no override: the row's Max")
    eq(groupMaxFor({ _groupMax = { a = 3 } }, "a", 8), 3, "an override")
    eq(groupMaxFor({ _groupMax = { a = 30 } }, "a", 8), 8, "...never above the row's Max")
    eq(groupMaxFor({ _groupMax = { a = -2 } }, "a", 8), 0, "...never below 0")
    local pushed = {}
    local c = { SetAuraGroupMaxFrameCount = function(_, key, n) pushed[#pushed + 1] = key .. "=" .. n end }
    local h = setmetatable({ backend = { container = c, groupKeys = { "row1_purge", "row1_rest" } } }, { __index = Handle })
    function h:_slotCount() return 8 end
    eq(h:SetGroupMaxOverrides({ row1_purge = 8, row1_rest = 5 }), true, "caps applied")
    eq(table.concat(pushed, ","), "row1_purge=8,row1_rest=5", "...pushed in place, every group")
    eq(bounced, 1, "...and the container bounced so it lands now")
    pushed = {}
    eq(h:SetGroupMaxOverrides({ row1_purge = 8, row1_rest = 5 }), false, "the same caps again: nothing pushed")
    eq(#pushed, 0, "...nothing")
    h:SetGroupMaxOverrides(nil)
    eq(table.concat(pushed, ","), "row1_purge=8,row1_rest=8", "no caps: every group back to Max")
    testShape, pushed = true, {}
    h:SetGroupMaxOverrides({ row1_rest = 1 })
    eq(#pushed, 0, "a preview's test-shaped row is left alone")
    check(src:find("maxFrameCount = groupMaxFor(handle, key, maxCount)", 1, true) ~= nil, "a rebuild declares the caps")
    check(src:find("SetAuraGroupMaxFrameCount, c, key, groupMaxFor(self.handle, key, maxCount)", 1, true) ~= nil,
          "...and a tuning pass keeps them")
end

-- ---- rowPurge ----------------------------------------------------------------
print("-- A frame's hook (frame.dfBuffPurgeable)")
do
    local block = lift(auras, "local function rowPurge(frame, db)", "\nend\n")
    local rowPurge = assert(loadstring(block .. "\nreturn rowPurge", "@rowPurge"))()
    eq(rowPurge({}, {}), nil, "no hook (party, raid, pinned): the plain row")
    eq(rowPurge(nil, {}), nil, "no frame: the plain row")
    eq(rowPurge({ dfBuffPurgeable = function() return true end }, {}), true, "hostile")
    eq(rowPurge({ dfBuffPurgeable = function() return false end }, {}), false, "friendly: held dark")
    eq(rowPurge({ dfBuffPurgeable = function() return nil end }, {}), nil, "off: the plain row")
    eq(rowPurge({ dfBuffPurgeable = function() return 1 end }, {}), true, "a truthy answer is true")
    eq(rowPurge({ dfBuffPurgeable = function() error("boom") end }, {}), nil, "a hook that errors: the plain row")
    check(auras:find("local purgeMoved = frame.dfBuffPurgeable ~= nil and frame.dfBuffRowPurge ~= purge", 1, true) ~= nil,
          "a moved answer re-applies the row (hostile <-> friendly on a target change)")
end

-- ---- recStyleSig -------------------------------------------------------------
print("-- The ring is part of the record's structure")
do
    local block = lift(auras, "local function recStyleSig(s)", "\nend\n")
    local sig = assert(loadstring(block .. "\nreturn recStyleSig", "@recStyleSig"))()
    check(sig({ highlight = { prefix = "buffPurgeable" } }) ~= sig({}), "a ringed record signs differently from a plain styled one")
    eq(sig({ scale = 1.2 }), sig({ scale = 1.2, highlight = nil }), "...and nothing changes for records without one")
end

-- ---- the ring on a button (AuraContainer.lua) --------------------------------
print("-- The ring: a DF.Border in a holder on the button, from the db's keys")
do
    local block = lift(src, "local function applyRecordHighlight(button, handle, hl)", "\nend\n")
    local applied, built = {}, 0
    local Border = {}
    function Border:New(holder) built = built + 1; return { holder = holder } end
    function Border:BuildSpec(db, prefix, ctx)
        return { color = db[prefix .. "BorderColor"], size = db[prefix .. "BorderSize"], ctx = ctx,
                 animation = { type = "PROC" } }
    end
    function Border:Apply(w, spec) applied[#applied + 1] = spec end
    local DFx = { Border = Border }
    local function makeHolder(parent, level)
        local h = { parent = parent, level = level, shown = true }
        function h:SetShown(v) self.shown = v and true or false end
        return h
    end
    local LEVELS = { PANDEMIC_BORDER = 7 }
    local apply = assert(loadstring("local DF, makeHolder, LEVELS = ...\n" .. block .. "\nreturn applyRecordHighlight",
        "@applyRecordHighlight"))(DFx, makeHolder, LEVELS)
    local db = { buffPurgeableBorderColor = { r = 1 }, buffPurgeableBorderSize = 2 }
    local button = {}
    local handle = { config = { unit = "target", layout = { size = 22, scale = 1 } } }
    apply(button, handle, { db = db, prefix = "buffPurgeable" })
    check(button.dfRecHighlightHolder ~= nil and button.dfRecHighlightHolder.shown, "a holder, shown")
    eq(button.dfRecHighlightHolder.level, 7, "...on the pandemic ring's rung (the ladder gains no rung)")
    eq(#applied, 1, "...one DF.Border applied")
    eq(applied[1].size, 2, "...from the buffPurgeable keys")
    eq(applied[1].animation, nil, "...static (rows never animate a border)")
    eq(applied[1].knownWidth, 22, "...sized from the row's slot, never its secret rect")
    db.buffPurgeableBorderSize = 3
    apply(button, handle, { db = db, prefix = "buffPurgeable" })
    eq(built, 1, "a restyle reuses the ring")
    eq(applied[2].size, 3, "...and reads the db again (a colour or size change needs no rebuild)")
    apply(button, handle, nil)
    eq(button.dfRecHighlightHolder.shown, false, "a record without a ring: hidden")
    check(src:find("applyRecordHighlight(button, handle, recStyle.highlight)", 1, true) ~= nil,
          "applyRecordStyle draws it for a styled record")
    check(src:find("if button and button.dfRecHighlightHolder then button.dfRecHighlightHolder:SetShown(false) end", 1, true) ~= nil,
          "...and its plain path hides it (pooled preview slots)")
end

-- ---- the unit frames' hook ---------------------------------------------------
print("-- UF.BuffPurgeable: which frames ask, and when the answer is hostile")
do
    local function deepcopy(t)
        if type(t) ~= "table" then return t end
        local o = {}
        for k, v in pairs(t) do o[k] = deepcopy(v) end
        return o
    end
    local secrets = setmetatable({}, { __mode = "k" })
    local function Secret() local t = {}; secrets[t] = true; return t end
    issecretvalue = function(v) return type(v) == "table" and secrets[v] == true end
    local DF = { PartyDefaults = { frameWidth = 125, frameHeight = 40 }, registered = {} }
    function DF:Debug() end
    function DF:DebugWarn() end
    function DF:DebugError() end
    function DF:DeepCopy(t) return deepcopy(t) end
    function DF:RegisterProfileRootTable(key, spec) self.registered[key] = spec; return true end
    DandersFrames = DF
    LibStub = nil
    local UF = {}
    load_uf_file_into("Core.lua", UF)
    load_uf_file_into("Defaults.lua", UF)
    DF.db = { unitframes = deepcopy(DF.registered.unitframes.defaults) }
    load_uf_file_into("Elements.lua", UF)

    for _, u in ipairs({ "target", "focus", "boss" }) do
        eq(UF:GetUnitDB(u).buffPurgeableEnabled, true, u .. ": on by default (an enemy frame)")
    end
    for _, u in ipairs({ "player", "pet", "targettarget", "focustarget" }) do
        eq(UF:GetUnitDB(u).buffPurgeableEnabled, false, u .. ": off")
    end
    eq(UF:GetUnitDB("target").buffPurgeableBorderSize, 2, "the ring: 2px...")
    eq(UF:GetUnitDB("target").buffPurgeableBorderColor.g, 0.82, "...gold")

    local exists, attack = true, true
    UnitExists = function() return exists end
    UnitCanAttack = function() return attack end
    local function Frame(unit, extra)
        local f = { dfUFUnit = unit, unit = unit, dfDB = UF:GetUnitDB(unit) }
        for k, v in pairs(extra or {}) do f[k] = v end
        return f
    end
    local BP = UF.BuffPurgeable
    local T = Frame("target")
    eq(BP(T, T.dfDB), true, "target, attackable: purgeable buffs ringed")
    attack = false
    eq(BP(T, T.dfDB), false, "target, friendly: the split held dark")
    attack = Secret()
    eq(BP(T, T.dfDB), false, "a secret answer: nothing glows")
    attack, exists = true, false
    eq(BP(T, T.dfDB), false, "no target: held dark")
    exists = Secret()
    eq(BP(T, T.dfDB), false, "a secret exists: held dark")
    exists = true
    local P = Frame("player")
    P.dfDB = { buffPurgeableEnabled = true }
    eq(BP(P, P.dfDB), nil, "the player frame never asks, whatever its setting")
    local PET = Frame("pet")
    PET.dfDB = { buffPurgeableEnabled = true }
    eq(BP(PET, PET.dfDB), nil, "...nor the pet")
    T.dfDB.buffPurgeableEnabled = false
    eq(BP(T, T.dfDB), nil, "switched off: the plain row")
    T.dfDB.buffPurgeableEnabled = nil
    local B = Frame("boss")
    B.unit = "boss3"
    eq(BP(B, B.dfDB), true, "boss slot 3: asked with its own token")

    local PV = Frame("target", { dfPreview = true, dfTestData = { reaction = 2 } })
    eq(BP(PV, PV.dfDB), true, "preview: a hostile sample rings its first buff")
    PV.dfTestData.reaction = 4
    eq(BP(PV, PV.dfDB), true, "...a neutral one too")
    PV.dfTestData.reaction = 5
    eq(BP(PV, PV.dfDB), nil, "...a friendly sample: the plain row")
    check(uf_file_source("Units.lua"):find("f.dfBuffPurgeable = UF.BuffPurgeable", 1, true) ~= nil, "live frames carry the hook")
    check(uf_file_source("Preview.lua"):find("f.dfBuffPurgeable = UF.BuffPurgeable", 1, true) ~= nil, "...and preview frames")
end

DF_SPLIT = nil
for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
