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

for _, k in ipairs(G_NAMES) do _G[k] = G[k] end
