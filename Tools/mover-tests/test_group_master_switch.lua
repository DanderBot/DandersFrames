local NS = ...

-- ============================================================
-- THE GROUP FRAMES MASTER SWITCH
-- DandersFrames_Options/GUI/Pages/ModulesPage.lua (GUI.GroupFrames)
-- ------------------------------------------------------------
-- The master is derived (Party or Raid on) and only ever writes the two
-- existing flags, plus a stash of the pair it turned off. Every path in the
-- spec ("Group Frames master switch", Q6), every change through the reload
-- prompt, and the stash never leaving the machine in a profile export.
-- ============================================================

local savedDF = DandersFrames

local prompts = {}
local GUI = {
    Colors = {
        text = { r = 1, g = 1, b = 1 }, textDim = { r = 0.6, g = 0.6, b = 0.6 },
        textCaption = { r = 0.7, g = 0.7, b = 0.7 },
    },
}
local DF = { GUI = GUI }
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:PromptReloadIfEnableFlagsChanged(msg) prompts[#prompts + 1] = msg or "(default)" end
DandersFrames = DF

load_options_file_into("GUI/Pages/ModulesPage.lua", NS)
local GF = GUI.GroupFrames
check(GF and GF.SetMaster and GF.SetMode and GF.MasterOn and GF.Settle, "api: GUI.GroupFrames is published")

local FRAME_MODE_MSG = "Enabling or disabling a frame mode requires a UI reload to take effect.\n\nReload now?"

print("-- Master switch: derived, never stored")
DF.db = {}
check(GF.MasterOn() and GF.PartyOn() and GF.RaidOn(), "derived: absent flags mean enabled")
DF.db = { partyEnabled = false }
check(GF.MasterOn(), "derived: Raid alone keeps the master on")
DF.db = { partyEnabled = false, raidEnabled = false }
check(not GF.MasterOn(), "derived: both off is master off")
eq(DF.db.groupFramesEnabled, nil, "derived: no new enable flag is ever written")

print("-- Master switch: off stashes the pair, on restores it")
DF.db = { partyEnabled = true, raidEnabled = true }
prompts = {}
GF.SetMaster(false)
check(DF.db.partyEnabled == false and DF.db.raidEnabled == false, "off: both flags false")
check(type(DF.db._groupFramesRestore) == "table" and DF.db._groupFramesRestore.party == true
      and DF.db._groupFramesRestore.raid == true, "off: the pair it turned off is stashed")
eq(#prompts, 1, "off: through the reload prompt")
eq(prompts[1], FRAME_MODE_MSG, "off: ...with the frame-mode wording, not the new-profile one")
GF.SetMaster(true)
check(DF.db.partyEnabled == true and DF.db.raidEnabled == true, "on: the stash is restored")
eq(DF.db._groupFramesRestore, nil, "on: ...and cleared")
eq(#prompts, 2, "on: through the reload prompt")

DF.db = { raidEnabled = false }          -- party absent = on
GF.SetMaster(false)
check(DF.db._groupFramesRestore.party == true and DF.db._groupFramesRestore.raid == false,
      "off: Party only is stashed as Party only (absent read as on)")
GF.SetMaster(true)
check(DF.db.partyEnabled == true and DF.db.raidEnabled == false, "on: ...and comes back as Party only")
eq(DF.db._groupFramesRestore, nil, "on: stash cleared")

print("-- Master switch: on with nothing to restore")
DF.db = { partyEnabled = false, raidEnabled = false }
GF.SetMaster(true)
check(DF.db.partyEnabled == true and DF.db.raidEnabled == true, "on: no stash turns both on")
DF.db = { partyEnabled = false, raidEnabled = false, _groupFramesRestore = { party = false, raid = false } }
GF.SetMaster(true)
check(DF.db.partyEnabled == true and DF.db.raidEnabled == true, "on: a stash of two offs turns both on")
eq(DF.db._groupFramesRestore, nil, "on: ...and is cleared")
DF.db = { partyEnabled = false, raidEnabled = false, _groupFramesRestore = "junk" }
GF.SetMaster(true)
check(DF.db.partyEnabled == true and DF.db.raidEnabled == true and DF.db._groupFramesRestore == nil,
      "on: a malformed stash is treated as none")

print("-- Master switch: no-ops")
DF.db = { partyEnabled = true, raidEnabled = false }
prompts = {}
GF.SetMaster(true)
check(DF.db.partyEnabled == true and DF.db.raidEnabled == false and #prompts == 0,
      "no-op: master on while already on changes nothing and prompts nothing")
DF.db = { partyEnabled = false, raidEnabled = false, _groupFramesRestore = { party = true, raid = false } }
GF.SetMaster(false)
check(DF.db._groupFramesRestore.party == true and #prompts == 0,
      "no-op: master off while already off keeps the stash it has")

print("-- Sub-switches")
DF.db = { partyEnabled = false, raidEnabled = false, _groupFramesRestore = { party = true, raid = true } }
prompts = {}
GF.SetMode("raid", true)
check(DF.db.raidEnabled == true and DF.db.partyEnabled == false,
      "sub: Raid on while the master is off turns only Raid on")
eq(DF.db._groupFramesRestore, nil, "sub: ...and the stash goes")
check(GF.MasterOn(), "sub: ...so the master reads on")
eq(#prompts, 1, "sub: through the reload prompt")
GF.SetMode("raid", false)
check(DF.db.raidEnabled == false and not GF.MasterOn(), "sub: turning the last one off turns the master off")
GF.SetMaster(true)
check(DF.db.partyEnabled == true and DF.db.raidEnabled == true,
      "sub: ...with no stash, the master then brings both back")
GF.SetMode("party", false)
check(DF.db.partyEnabled == false and DF.db.raidEnabled == true and DF.db._groupFramesRestore == nil,
      "sub: one off with the master on just turns that one off")

print("-- Settle: the old Frame Modes ticks")
DF.db = { partyEnabled = true, raidEnabled = false, _groupFramesRestore = { party = false, raid = true } }
GF.Settle()
eq(DF.db._groupFramesRestore, nil, "settle: a mode on means the stash describes nothing")
DF.db = { partyEnabled = false, raidEnabled = false, _groupFramesRestore = { party = false, raid = true } }
GF.Settle()
check(DF.db._groupFramesRestore ~= nil, "settle: ...but with the master off it is kept")
local OPTIONS = options_file_source("GUI/Pages/Options.lua"):gsub("\r\n", "\n")
local promptAt = OPTIONS:find("local function PromptReloadAfterModeToggle(mode)", 1, true)
local settleAt = OPTIONS:find("if GUI.GroupFrames and GUI.GroupFrames.Settle then GUI.GroupFrames.Settle() end", 1, true)
check(promptAt and settleAt and settleAt > promptAt and settleAt - promptAt < 400,
      "settle: the Frame Modes ticks' reload prompt settles the stash first")

DF.db = nil
local ok = pcall(function() GF.SetMaster(false); GF.SetMaster(true); GF.SetMode("party", true); GF.Settle() end)
check(ok, "nil db: nothing errors before the profile exists")

print("-- Modules page: the model")
do
    local defs = {
        { id = "home", noTile = true },
        { id = "group", on = true },
        { id = "units", comingSoon = true },
        { id = "clicks", on = false },
        { id = "modules", noTile = true },
        { id = "global", on = true },
    }
    function GUI:GetModules() return defs end
    function GUI:IsModuleOn(def) return def.on == true end
    local on, off, soon = GUI:ModulesPageModel()
    local function ids(t) local o = {} for i, d in ipairs(t) do o[i] = d.id end return table.concat(o, ",") end
    eq(ids(on), "group", "model: On lists what is switched on")
    eq(ids(off), "clicks", "model: Off lists what is switched off")
    eq(ids(soon), "units", "model: Coming soon lists Unit Frames")
    defs[#defs + 1] = { id = "zz_custom", on = true, setEnabled = function() end }
    on = GUI:ModulesPageModel()
    eq(ids(on), "group,zz_custom", "model: a module bringing its own setEnabled is listed; Global (no switch) is not")
end

DandersFrames = savedDF

-- ============================================================
-- THE STASH NEVER LEAVES IN AN EXPORT
-- DF:ExportProfile (DandersFrames/Core/Profile.lua) run for real, its locals
-- lifted with it, over a stub serializer that keeps what it was handed.
-- ============================================================
print("-- Master switch: the stash is not exported")
do
    local SRC = df_file_source("Core/Profile.lua"):gsub("\r\n", "\n")
    local a = SRC:find("\nlocal PROFILE_ROOT_SCALARS = {", 1, true)
    local fnAt = SRC:find("\nfunction DF:ExportProfile(", 1, true)
    local b = fnAt and SRC:find("\nend\n", fnAt, true)
    check(a and fnAt and b and a < fnAt, "export: found the root-scalar list and DF:ExportProfile")
    if a and b then
        local chunk, err = loadstring(SRC:sub(a + 1, b + 4), "=export")
        check(chunk ~= nil, "export: the lifted code parses (" .. tostring(err) .. ")")
        local captured
        local XDF = { L = setmetatable({}, { __index = function(_, k) return k end }), VERSION = "5.7.0",
                      CLIENT_FLAVOR = "retail", ExportCategories = {},
                      -- The profile-root table registry, empty: nothing registered.
                      ProfileRootTables = {}, ProfileRootTableOrder = {} }
        function XDF:DeepCopy(t)
            if type(t) ~= "table" then return t end
            local c = {}
            for k, v in pairs(t) do c[k] = self:DeepCopy(v) end
            return c
        end
        function XDF:Err() end
        function XDF:ExtractCategorySettings(t) return self:DeepCopy(t) end
        local env = setmetatable({
            DF = XDF,
            LibStub = function(name)
                if name == "LibSerialize" then
                    return { Serialize = function(_, t) captured = t; return "S" end }
                end
                return { CompressDeflate = function(_, s) return s end, EncodeForPrint = function(_, s) return s end }
            end,
            StripInternalKeys = function(t) return t end,
            EmbedCustomFilterData = function() end,
            HasProfileRootTable = function() return false end,
            RootTableTravels = function() return false end,
        }, { __index = _G })
        if chunk then
            setfenv(chunk, env)
            chunk()
            local savedSV = DandersFramesDB_v2
            DandersFramesDB_v2 = { currentProfile = "Mine" }
            XDF.db = {
                party = { frameWidth = 1 }, raid = { frameWidth = 2 },
                partyEnabled = false, raidEnabled = false,
                _groupFramesRestore = { party = true, raid = true },
                linkedSections = { bars = true },
            }
            local function holdsStash(t, seen)
                if type(t) ~= "table" then return false end
                seen = seen or {}
                if seen[t] then return false end
                seen[t] = true
                for k, v in pairs(t) do
                    if k == "_groupFramesRestore" or holdsStash(v, seen) then return true end
                end
                return false
            end
            local s = XDF:ExportProfile()
            check(s ~= nil and captured ~= nil, "export: a full export ran")
            check(captured and captured.partyEnabled == false and captured.raidEnabled == false,
                  "export: the two enable flags travel (sanity: the root scalars are copied)")
            check(captured and not holdsStash(captured), "export: a full export carries no stash")
            captured = nil
            XDF:ExportProfile({ "other" })
            check(captured ~= nil and not holdsStash(captured),
                  "export: nor does a selective export with Other (the category that carries the root flags)")
            DandersFramesDB_v2 = savedSV
        end
    end
    local CATS = options_file_source("Core/ExportCategories.lua")
    check(CATS:find('not DF.ExportLocalOnly[k] and k:sub(1, 1) ~= "_"', 1, true) ~= nil,
          "export: the export audit leaves `_` keys out by rule, so the stash needs no ExportLocalOnly entry")
end
