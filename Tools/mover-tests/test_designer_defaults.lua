local NS = ...

-- ============================================================
-- DESIGNER DEFAULTS -- the adapter hook, end to end
-- DandersFrames/Core/Defaults.lua  +  DandersFrames_Options/GUI/GroupActions.lua
-- +  AuraDesigner/UI/Groups.lua  +  TextDesigner/UI/Options.lua
-- ------------------------------------------------------------
-- The settings-defaults engine recognises DF.db.party / DF.db.raid / the real
-- raid table BY IDENTITY, and both designers bind their controls to a metatable
-- PROXY over one record instead. Handed a proxy the engine returned nil, and
-- every verb built on it died quietly: a modified tick that never lights, a
-- Reset Group that writes nothing, a Hold that previews nothing -- no error in
-- any of them. The adapter hook is what lets a record answer for itself.
--
-- Five things are pinned here, and all five fail SILENTLY in game:
--
--   1. ☠ COPY-ON-READ IS NOT AN EDIT. The Aura Designer's proxy COPIES a
--      table-valued default onto the instance the first time the key is READ
--      (Groups.lua, __index), so sub-key writes persist. Presence on the record
--      is therefore no evidence the user set anything -- and a modified check
--      keyed off presence would light every colour on a panel the moment the
--      panel opened. Value equality is what defuses it: the copy equals what it
--      was copied from. THIS IS THE ONE THIS FILE EXISTS FOR.
--   2. GetStored READS RAW. Through __index every key resolves to a fallback, so
--      an adapter reading back through its own proxy would find everything set.
--   3. A RESET UNSETS rather than writes. Writing the resolved default into the
--      record pins it there and it stops FOLLOWING the shared default it was
--      resolving through.
--   4. THE TEXT DESIGNER'S "IS SET" MARKER IS `overrides`, NOT PRESENCE. Its
--      editor seeds font / fontSize / outline / color / useClassColor onto every
--      element it builds a card for, without flagging them, and the renderer
--      ignores an unflagged field -- so a stale value that DIFFERS from the
--      global must still read as unmodified.
--   5. THE HOOK IS INERT FOR EVERYTHING THAT SHIPS. No settings table carries
--      __dfDefaultsAdapter, so every existing page must take the identical path.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE. Config.lua needs
-- CreateFrame / GetLocale and claims the global `DandersFrames`; the three
-- companion files read that global at LOAD time (their `...` is the companion's
-- own table, not the parent's). All of it is set deliberately across the loads
-- below and restored at the foot of the file.
-- ============================================================

local savedCreateFrame   = CreateFrame
local savedGetLocale     = GetLocale
local savedDandersFrames = DandersFrames
local savedTimer         = C_Timer
local savedTinsert       = tinsert

C_Timer = { After = function() end }        -- the throttled live refresh, parked
tinsert = tinsert or table.insert           -- CreateIndicatorInstance uses the WoW alias

-- ============================================================
-- THE FIXTURE
-- The REAL engine, the REAL GroupActions, and the REAL designer files. The one
-- thing faked is what the Aura Designer's own page would hand its proxies -- the
-- aura pool, the Global tab's block and the per-type defaults -- because those
-- live in a 10k-line page file that cannot be loaded headlessly. GLOBAL_DEFAULT_MAP
-- is NOT faked: it is a file-local of Groups.lua, so the type keys below ("icon",
-- `size`, `scale`, `showDuration`, `durationColor`) are routed through the real map.
-- ============================================================

-- The Aura Designer's private surface, populated BEFORE Groups.lua loads: that
-- file lifts every one of these into a file-scope local at load time, so a key
-- added afterwards would never be seen.
local S = {}
local P = { OPTS = { ANCHOR_OPTIONS = {} } }

local pool = {}                              -- auraName -> auraCfg
local adDB = { defaults = {} }               -- the Global tab's block

P.TYPE_DEFAULTS = {
    icon = {
        anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
        size = 24, scale = 1.0,
        showDuration = true,
        durationColor = { r = 1, g = 1, b = 1, a = 1 },
        -- Not in GLOBAL_DEFAULT_MAP: falls straight through to the type's value.
        BorderColor   = { r = 0, g = 0, b = 0, a = 0.8 },
    },
}
local TYPE_DEFAULTS = P.TYPE_DEFAULTS

P.GetAuraDesignerDB = function() return adDB end
-- The live-refresh verbs the card file's records call on every write. Parked:
-- nothing here renders, and a nil upvalue in a __newindex is an error, not a no-op.
P.RefreshPlacedIndicators   = function() end
P.RefreshPreviewEffects     = function() end
P.RefreshLiveFramesThrottled = function() end
P.GetSpecAuras      = function() return pool end
P.GetOtherAuras     = function() return pool end
P.CurrentAuraPool   = function() return pool end
P.IsOtherTab        = function() return false end
P.IsDebuffTab       = function() return false end
P.EnsureAuraConfig  = function(name, p)
    p = p or pool
    p[name] = p[name] or {}
    return p[name]
end
P.EnsureTypeConfig  = function(name, typeKey, p)
    local cfg = P.EnsureAuraConfig(name, p)
    cfg[typeKey] = cfg[typeKey] or {}
    return cfg[typeKey]
end

local DF = {}
do
    CreateFrame = function() return FakeUIFrame() end
    GetLocale = function() return "enUS" end
    load_df_file_into("Core/Config.lua", DF)
    DandersFrames = savedDandersFrames       -- Config.lua claims the global
    load_df_file_into("Core/Defaults.lua", DF)
    load_df_file_into("TextDesigner/TextDesigner.lua", DF)

    -- The surface the three companion files read off the parent at load time.
    local anyColor = { r = 0, g = 0, b = 0, a = 1 }
    DF.GUI = { Colors = setmetatable({}, { __index = function() return anyColor end }) }
    DF.L = setmetatable({}, { __index = function(_, k) return k end })
    DF.RegisterLocaleRefresh = function() end
    DF.AuraDesigner = { Adapter = {}, _uiState = S, _priv = P }

    DandersFrames = DF                       -- ...and THIS is the wiring
    load_options_file_into("GUI/GroupActions.lua", {})
    load_options_file_into("AuraDesigner/UI/Groups.lua", {})
    -- ☠ AND THE CARD FILE, for its three records. It is a 3,300-line page file,
    -- but nothing in it RUNS at load: it declares locals off the fake GUI table
    -- above and hangs functions on P. The three records tested below are minted by
    -- factories that touch no frame, which is why they were lifted out of the
    -- section builders around them.
    load_options_file_into("AuraDesigner/UI/Cards.lua", {})
    load_options_file_into("TextDesigner/UI/Options.lua", {})
    DandersFrames = savedDandersFrames
    CreateFrame, GetLocale = savedCreateFrame, savedGetLocale
end

local Defaults = DF.Defaults
local GA = DF.GroupActions
local CreateInstanceProxy  = P.CreateInstanceProxy
local CreateProxy          = P.CreateProxy
local CreateIndicatorInstance = P.CreateIndicatorInstance

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = deepcopy(x) end
    return t
end

local function deepsame(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepsame(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- The write bracket, as a recorder -- same shape test_group_actions.lua uses.
local function fakeHost(redirect)
    local h = { intercepted = {}, written = {} }
    h.hooks = {
        interceptWrite = function(db, key, value)
            h.intercepted[#h.intercepted + 1] = { db = db, key = key, value = value }
            return redirect and redirect[key] and true or false
        end,
        onSettingWritten = function(db, key, value)
            h.written[#h.written + 1] = { db = db, key = key, value = value }
        end,
    }
    function h:Call(name, ...)
        local fn = self.hooks[name]
        if not fn then return nil end
        return fn(...)
    end
    function h:Written(key)
        local found
        for _, w in ipairs(self.written) do if w.key == key then found = w end end
        return found
    end
    return h
end

-- A fresh placement, through the REAL constructor: an instance carrying nothing
-- but id / type / anchor / offsetX / offsetY, exactly as clicking "+ Add" leaves it.
local AURA = "Rejuvenation"
local function freshEffect()
    for k in pairs(pool) do pool[k] = nil end
    for k in pairs(adDB.defaults) do adDB.defaults[k] = nil end
    local inst = CreateIndicatorInstance(AURA, "icon")
    return inst, CreateInstanceProxy(AURA, inst.id)
end

-- Every key an effect panel would claim for its rows.
local AD_KEYS = { "anchor", "offsetX", "offsetY", "size", "scale",
                  "showDuration", "durationColor", "BorderColor" }

-- ============================================================
-- EVERYTHING LOADED
-- ============================================================
do
    check(type(Defaults) == "table", "the defaults engine loaded")
    check(type(GA) == "table", "GroupActions loaded")
    check(type(CreateInstanceProxy) == "function", "the Aura Designer's instance proxy is reachable")
    check(type(CreateProxy) == "function", "...and its per-type proxy")
    check(type(DF.TextDesigner.ElementDefaultsRecord) == "function",
        "the Text Designer publishes its element defaults record")
    check(type(DF.TextDesigner.GlobalDefaultsRecord) == "function",
        "...and its Global tab record")
end

-- ============================================================
-- 5. THE HOOK IS INERT FOR EVERY TABLE THAT SHIPS
-- Nothing in the profile carries __dfDefaultsAdapter, so a plain settings table
-- takes the identical path it took before the hook existed. This is the section
-- that says "no existing page changed".
-- ============================================================
do
    local party, raid = {}, {}
    for k, v in pairs(DF.PartyDefaults) do party[k] = deepcopy(v) end
    for k, v in pairs(DF.RaidDefaults)  do raid[k]  = deepcopy(v) end
    DF.db = { party = party, raid = raid }
    DF._realRaidDB = nil

    check(rawget(party, "__dfDefaultsAdapter") == nil, "a profile side carries no adapter")
    check(rawget(DF.PartyDefaults, "__dfDefaultsAdapter") == nil, "nor does the shipped defaults table")

    local keys = { "absorbBarHeight", "frameWidth", "fontShadowColor" }
    eq(Defaults:Count(party, keys), 0, "a fresh profile: nothing modified")
    eq(Defaults:IsModified(party, "absorbBarHeight"), false, "...and IsModified says so")
    check(next(Defaults:DiffKeys(party, keys)) == nil, "...and DiffKeys is empty")

    party.absorbBarHeight = DF.PartyDefaults.absorbBarHeight + 7
    eq(Defaults:Count(party, keys), 1, "one edit, one modified key")
    check(Defaults:IsModified(party, "absorbBarHeight"), "...the right one")
    local diff = Defaults:DiffKeys(party, keys)
    eq(diff.absorbBarHeight.current, DF.PartyDefaults.absorbBarHeight + 7, "...DiffKeys reports what is stored")
    eq(diff.absorbBarHeight.default, DF.PartyDefaults.absorbBarHeight, "...against what ships")

    -- ...and the write half is unchanged: still a plain bracketed write, not a clear.
    local host = fakeHost()
    local changes = GA:ResetKeys(host, party, keys, "party", "Absorbs")
    eq(changes.absorbBarHeight.new, DF.PartyDefaults.absorbBarHeight, "reset put the shipped value back")
    eq(party.absorbBarHeight, DF.PartyDefaults.absorbBarHeight, "...into the table")
    check(rawget(party, "absorbBarHeight") ~= nil, "...as a WRITE; a profile key is never unset")
    eq(Defaults:Count(party, keys), 0, "...and nothing reports modified afterwards")

    -- A table the engine has never understood still answers "not modified",
    -- exactly as it did: no adapter, no identity match, no dot.
    local stranger = { frameWidth = 999 }
    eq(Defaults:Count(stranger, keys), 0, "an unknown table still answers zero")
    eq(Defaults:IsModified(stranger, "frameWidth"), false, "...and false")
    check(next(GA:ResetKeys(fakeHost(), stranger, keys, "party")) == nil,
        "...and a reset on it still writes nothing")
    eq(stranger.frameWidth, 999, "...the stranger is untouched")
end

-- ============================================================
-- 1. COPY-ON-READ IS NOT AN EDIT  (the whole point of the phase)
-- ============================================================
do
    local inst, proxy = freshEffect()

    eq(Defaults:Count(proxy, AD_KEYS), 0, "AD: a freshly placed effect reports nothing modified")
    check(rawget(proxy, "__dfDefaultsAdapter") ~= nil, "...and it is the adapter answering, not an identity match")

    -- Now the trap: READ every key once, the way opening the panel does.
    for i = 1, #AD_KEYS do local _ = proxy[AD_KEYS[i]] end

    check(rawget(inst, "durationColor") ~= nil,
        "reading a table-valued key COPIED it onto the instance (copy-on-read still happens)")
    check(rawget(inst, "BorderColor") ~= nil, "...both of them")
    eq(Defaults:Count(proxy, AD_KEYS), 0,
        "☠ ...and the panel STILL reports zero modified keys after every key has been read")
    eq(Defaults:IsModified(proxy, "durationColor"), false, "...the copied colour is not modified")
    check(next(Defaults:DiffKeys(proxy, AD_KEYS)) == nil, "...and the ledger lists nothing")

    -- The copy is a different table with the same numbers -- which is exactly
    -- what `==` would have called a change and ValuesEqual does not.
    check(rawget(inst, "durationColor") ~= TYPE_DEFAULTS.icon.durationColor,
        "...the copy is a DIFFERENT table from the default it came from")
    check(deepsame(rawget(inst, "durationColor"), TYPE_DEFAULTS.icon.durationColor),
        "...with the same values, which is why it compares equal")
end

-- ============================================================
-- 2. GetStored READS RAW
-- ============================================================
do
    local inst, proxy = freshEffect()
    local adapter = rawget(proxy, "__dfDefaultsAdapter")

    check(proxy.size == 24, "a key the instance does not hold READS as the fallback through the proxy")
    check(rawget(inst, "size") == nil, "...while the instance itself holds nothing")
    check(adapter.GetStored("size") == nil, "...and GetStored answers nil, not the fallback")
    eq(adapter.GetDefault("size"), 24, "...GetDefault is the one that answers the fallback")

    -- The raw read must also not be what PUTS the key there.
    local before = deepcopy(inst)
    for i = 1, #AD_KEYS do
        adapter.GetStored(AD_KEYS[i])
        adapter.GetDefault(AD_KEYS[i])
    end
    check(deepsame(inst, before), "a full adapter pass writes nothing onto the instance")
end

-- ============================================================
-- THE FALLBACK CHAIN IS THE PROXY'S OWN
-- The Global tab's value wins over the type's, and the tick is measured against
-- whichever one the control beside it resolves.
-- ============================================================
do
    local inst, proxy = freshEffect()
    adDB.defaults.iconSize = 30                 -- GLOBAL_DEFAULT_MAP.icon.size = "iconSize"

    eq(proxy.size, 30, "the Global tab's value is what the control reads")
    local adapter = rawget(proxy, "__dfDefaultsAdapter")
    eq(adapter.GetDefault("size"), 30, "...and what the tick measures against")
    eq(Defaults:IsModified(proxy, "size"), false, "an untouched key is not modified")

    proxy.size = 24                              -- the TYPE default, but NOT the global one
    check(Defaults:IsModified(proxy, "size"),
        "pinning a key at the type's value IS modified while the Global tab says otherwise")

    -- A key the map does not mention falls straight to the type's defaults.
    eq(adapter.GetDefault("BorderColor"), TYPE_DEFAULTS.icon.BorderColor,
        "an unmapped key falls straight through to the type's default")
end

-- ============================================================
-- AN EDIT REPORTS MODIFIED, AND 3. A RESET UNSETS
-- ============================================================
do
    local inst, proxy = freshEffect()
    for i = 1, #AD_KEYS do local _ = proxy[AD_KEYS[i]] end     -- open the panel first
    proxy.size = 30

    eq(Defaults:Count(proxy, AD_KEYS), 1, "AD: one edit, one modified key")
    check(Defaults:IsModified(proxy, "size"), "...the edited one")
    local diff = Defaults:DiffKeys(proxy, AD_KEYS)
    eq(diff.size.current, 30, "...DiffKeys reports the stored value")
    eq(diff.size.default, 24, "...against the resolved default")

    local host = fakeHost()
    local changes = GA:ResetKeys(host, proxy, AD_KEYS, "party", "Appearance")
    eq(changes.size.old, 30, "reset reports what was there")
    eq(changes.size.new, 24, "...and what it goes back to")
    check(rawget(inst, "size") == nil,
        "☠ reset UNSET the key rather than writing the default in -- the effect follows the Global tab again")
    eq(proxy.size, 24, "...and it reads as the default again")
    eq(Defaults:Count(proxy, AD_KEYS), 0, "...nothing modified afterwards")

    -- The clear is still a bracketed change: the undo engine and the layout
    -- recorder both hang off these hooks.
    check(host:Written("size") ~= nil, "the clear went through the bracket")
    eq(host:Written("size").value, 24, "...and announced the value the key ends at, not nil")
    check(host:Written("durationColor") == nil,
        "rule 3 holds: a key already at its default is not announced at all")
    check(rawget(inst, "durationColor") ~= nil,
        "...and the copy-on-read colour was left exactly where it was")
end

-- ============================================================
-- A SUB-KEY EDIT TO A COPIED COLOUR *IS* AN EDIT
-- The other half of rule 1: copy-on-read exists so `proxy.color.r = 1` persists,
-- and the tick has to see that even though the key was already present.
-- ============================================================
do
    local inst, proxy = freshEffect()
    proxy.durationColor.r = 0.5                  -- copy-on-read, then mutate in place

    check(Defaults:IsModified(proxy, "durationColor"), "a sub-key edit to a copied colour reports modified")
    eq(Defaults:Count(proxy, AD_KEYS), 1, "...and counts once")

    local changes = GA:ResetKeys(fakeHost(), proxy, AD_KEYS, "party", "Appearance")
    check(changes.durationColor ~= nil, "...and a reset picks it up")
    check(rawget(inst, "durationColor") == nil, "...clearing it")
    eq(proxy.durationColor.r, 1, "...so it resolves to the default again")
end

-- ============================================================
-- HOLD: DEFAULTS PREVIEWS, AND PUTS BACK WHAT WAS THERE
-- ============================================================
do
    local inst, proxy = freshEffect()
    proxy.size = 30
    local host = fakeHost()

    local snapshot = GA:BeginHold(host, proxy, AD_KEYS, "party")
    eq(proxy.size, 24, "hold: the preview takes the edited key to its default")
    eq(snapshot.size, 30, "...and the snapshot kept what the user had")

    GA:EndHold(host, proxy, AD_KEYS, snapshot)
    eq(proxy.size, 30, "...and releasing puts it back")
    check(Defaults:IsModified(proxy, "size"), "...still modified, as it was before the hold")
end

-- ============================================================
-- THE PER-TYPE PROXY ANSWERS THE SAME WAY
-- CreateProxy binds the aura's shared per-type block rather than one placed
-- instance; its chain is shorter (TYPE_DEFAULTS only) and its copy-on-read is
-- the same trap.
-- ============================================================
do
    for k in pairs(pool) do pool[k] = nil end
    local proxy = CreateProxy(AURA, "icon")
    local keys = { "size", "durationColor" }

    eq(Defaults:Count(proxy, keys), 0, "per-type proxy: a fresh block reports nothing modified")
    local _ = proxy.durationColor                        -- copy-on-read
    check(rawget(pool[AURA].icon, "durationColor") ~= nil, "...the read copied the colour onto the block")
    eq(Defaults:Count(proxy, keys), 0, "...and it still reports nothing modified")

    proxy.size = 40
    check(Defaults:IsModified(proxy, "size"), "...an edit reports modified")
    GA:ResetKeys(fakeHost(), proxy, keys, "party", "Appearance")
    check(rawget(pool[AURA].icon, "size") == nil, "...and a reset unsets it")
end

-- ============================================================
-- 4. THE TEXT DESIGNER: `overrides` IS THE MARKER, NOT PRESENCE
-- ============================================================
local TD_KEYS = { "font", "fontSize", "color", "outline", "useClassColor" }

do
    local profile = {}
    local tdDB = DF.TextDesigner:EnsureDB(profile)
    -- An element exactly as BuildAppearanceSection leaves one on first open: the
    -- five appearance fields SEEDED, none of them flagged. Note `outline`: the
    -- editor seeds "SHADOW" while the shipped global is "SHADOW;NONE", so this
    -- element carries a present value that DIFFERS from the default and is still
    -- not in force.
    local elem = {
        id = 1, contentType = "name", anchor = "CENTER",
        font = "DF Roboto SemiBold", fontSize = 10, outline = "SHADOW",
        color = { r = 1, g = 1, b = 1, a = 1 }, useClassColor = false,
    }
    local rec = DF.TextDesigner.ElementDefaultsRecord(elem, tdDB)

    check(rec ~= nil, "TD: an element gets a defaults record")
    check(rec ~= elem, "☠ ...and it is a VIEW, not the element -- the element is SavedVariables")
    check(rawget(elem, "__dfDefaultsAdapter") == nil,
        "...so no function-valued key was put on a table that gets serialised")
    check(rawget(rec, "__dfDefaultsAdapter") ~= nil, "...the hook lives on the view")
    check(rec.font == elem.font, "...and the view reads through to the element")

    check(elem.outline ~= tdDB.globalDefaults.outline,
        "the seeded outline genuinely DIFFERS from the global default")
    eq(Defaults:Count(rec, TD_KEYS), 0,
        "☠ ...and the element still reports zero modified keys: no override flag, not in force")
    eq(Defaults:IsModified(rec, "outline"), false, "...IsModified says so for the differing one")

    -- Flag it, and the same value is suddenly the user's.
    elem.overrides = { outline = true }
    check(Defaults:IsModified(rec, "outline"), "flagged AND differing = modified")
    eq(Defaults:Count(rec, TD_KEYS), 1, "...one key")

    -- A flag on a value that MATCHES the global is still not a change.
    elem.overrides.fontSize = true
    eq(Defaults:IsModified(rec, "fontSize"), false, "flagged but equal to the global = not modified")

    -- Nothing outside the five has an override marker or a shared default.
    eq(Defaults:IsModified(rec, "contentType"), false,
        "a field with no override marker and no shared default is never modified")
    eq(Defaults:IsModified(rec, "anchor"), false, "...same for the placement fields")
end

-- ============================================================
-- 4b. TD RESET CLEARS THE OVERRIDE, IT DOES NOT PIN THE GLOBAL
-- ============================================================
do
    local profile = {}
    local tdDB = DF.TextDesigner:EnsureDB(profile)
    local elem = {
        id = 1, contentType = "name",
        font = "DF Roboto SemiBold", fontSize = 10, outline = "SHADOW",
        color = { r = 1, g = 1, b = 1, a = 1 }, useClassColor = false,
        overrides = { outline = true },
    }
    local rec = DF.TextDesigner.ElementDefaultsRecord(elem, tdDB)
    local host = fakeHost()

    local changes = GA:ResetKeys(host, rec, TD_KEYS, "party", "Appearance")
    eq(changes.outline.old, "SHADOW", "TD reset reports what was in force")
    eq(changes.outline.new, tdDB.globalDefaults.outline, "...and what it falls back to")
    check(elem.overrides.outline == nil, "☠ reset cleared the OVERRIDE")
    eq(elem.outline, "SHADOW",
        "...and did NOT pin the element at the global's current value -- its own value is simply not in force")
    eq(Defaults:Count(rec, TD_KEYS), 0, "...nothing modified afterwards")
    check(host:Written("outline") ~= nil, "...and the clear still went through the bracket")

    -- A write THROUGH the record marks the override, because a value stored
    -- without its flag is not in force -- the exact bug the editor's colour
    -- callback carries a comment about.
    rec.fontSize = 14
    check(elem.overrides.fontSize == true, "a write through the record flags the override")
    eq(elem.fontSize, 14, "...and lands on the element")
    check(Defaults:IsModified(rec, "fontSize"), "...and reports modified")

    -- The record is stable across card rebuilds: a row that holds one keeps it.
    check(DF.TextDesigner.ElementDefaultsRecord(elem, tdDB) == rec,
        "asking again for the same element gives the same record")
end

-- ============================================================
-- 4c. THE TD GLOBAL TAB, AGAINST WHAT THE ADDON SHIPS
-- No ClearKey here: the tab's widgets bind straight to globalDefaults, so an
-- unset key would hand them a nil to render. Reset writes the shipped value.
-- ============================================================
do
    local profile = {}
    local tdDB = DF.TextDesigner:EnsureDB(profile)
    local rec = DF.TextDesigner.GlobalDefaultsRecord(tdDB)

    check(rec ~= nil, "TD: the Global tab gets a record")
    check(rec ~= tdDB.globalDefaults, "...and it too is a view, not the stored block")
    eq(Defaults:Count(rec, TD_KEYS), 0, "a fresh globalDefaults block is at the shipped values")

    tdDB.globalDefaults.fontSize = 14
    check(Defaults:IsModified(rec, "fontSize"), "an edited global default reports modified")

    local changes = GA:ResetKeys(fakeHost(), rec, TD_KEYS, "party", "Global Defaults")
    eq(changes.fontSize.new, 10, "reset goes back to the shipped value")
    eq(tdDB.globalDefaults.fontSize, 10, "...WRITTEN into the block")
    check(rawget(tdDB.globalDefaults, "fontSize") ~= nil,
        "...never unset -- the tab's widgets read this table directly")
    eq(Defaults:Count(rec, TD_KEYS), 0, "...nothing modified afterwards")
end

-- ============================================================
-- NEITHER DESIGNER'S RECORD LEAKS INTO A SERIALISABLE TABLE
-- The hook is a table of FUNCTIONS. LibSerialize cannot carry one, and profile
-- export deep-copies the whole textDesigner / auraDesigner block.
-- ============================================================
do
    local profile = {}
    local tdDB = DF.TextDesigner:EnsureDB(profile)
    local elem = { id = 1, contentType = "name" }
    tdDB.elements[1] = elem
    DF.TextDesigner.ElementDefaultsRecord(elem, tdDB)
    DF.TextDesigner.GlobalDefaultsRecord(tdDB)

    local found = {}
    local function sweep(t, seen)
        seen = seen or {}
        if seen[t] then return end
        seen[t] = true
        for k, v in pairs(t) do
            if k == "__dfDefaultsAdapter" then found[#found + 1] = tostring(k) end
            if type(v) == "function" then found[#found + 1] = "function at " .. tostring(k) end
            if type(v) == "table" then sweep(v, seen) end
        end
    end
    sweep(profile)
    eq(#found, 0, "nothing function-valued reached the Text Designer's stored block")

    local inst, proxy = freshEffect()
    for i = 1, #AD_KEYS do local _ = proxy[AD_KEYS[i]] end
    found = {}
    sweep(pool)
    eq(#found, 0, "nor the Aura Designer's aura pool, after a full panel-open read")
end


-- ============================================================
-- 6. THE AURA DESIGNER'S OTHER THREE RECORDS  (phase 3)
-- ------------------------------------------------------------
-- Phase 0 attached adapters to the two proxies an EFFECT's controls bind. It
-- missed three more that the Layout Groups and Global tabs bind, and every one of
-- them fails the same silent way: a row handed a table the engine cannot resolve
-- has a permanently dark modified tick and a Reset Group that writes nothing
-- while saying it had.
--
--   the Global tab's defaults proxy      over adDB.defaults
--   the Global tab's sound record        over adDB itself (two custom-bound keys)
--   a group's style proxy                over group.style, WITH copy-on-read
--   a group record view                  over the group itself -- a VIEW, because
--                                        the group is SavedVariables
-- ============================================================

local CreateGlobalDefaultsProxy = P.CreateGlobalDefaultsProxy
local CreateSoundSettingsProxy  = P.CreateSoundSettingsProxy
local CreateGroupStyleProxy     = P.CreateGroupStyleProxy

do
    check(type(CreateGlobalDefaultsProxy) == "function", "the Global tab's defaults record is reachable")
    check(type(CreateSoundSettingsProxy) == "function", "...its sound record")
    check(type(CreateGroupStyleProxy) == "function", "...a group's style record")
    check(type(P.GroupRecordView) == "function", "...and a group's own record view")
end

-- ============================================================
-- 6a. THE GLOBAL TAB'S DEFAULTS RECORD
-- ============================================================
do
    for k in pairs(adDB) do if k ~= "defaults" then adDB[k] = nil end end
    for k in pairs(adDB.defaults) do adDB.defaults[k] = nil end
    local rec = CreateGlobalDefaultsProxy()
    local KEYS = { "iconSize", "iconScale", "indicatorFrameLevel",
                   "showDuration", "durationColor", "durationHideAboveThreshold" }

    check(rawget(rec, "__dfDefaultsAdapter") ~= nil, "Global: the record carries the adapter")
    eq(Defaults:Count(rec, KEYS), 0, "Global: an empty defaults block reports nothing modified")

    -- Every key resolves through the fallback, and the adapter says so.
    eq(rec.iconSize, 24, "Global: an unset key READS as the shipped fallback")
    eq(rec.indicatorFrameLevel, 40, "Global: ...including the frame level, whose no-op is 40")
    local adapter = rawget(rec, "__dfDefaultsAdapter")
    check(adapter.GetStored("iconSize") == nil, "Global: ...while GetStored answers nil, not the fallback")
    eq(adapter.GetDefault("iconSize"), 24, "Global: ...and GetDefault is the one that answers it")

    -- Open the panel: read every key once. This proxy does NOT copy on read, so
    -- the block stays empty -- which is the other half of why presence is never
    -- the test.
    for i = 1, #KEYS do local _ = rec[KEYS[i]] end
    check(rawget(adDB.defaults, "durationColor") == nil,
        "Global: reading a table-valued key does NOT copy it onto the block")
    eq(Defaults:Count(rec, KEYS), 0, "Global: ...and nothing reports modified after a full read")

    -- An edit, and a reset that UNSETS rather than pinning.
    rec.iconSize = 30
    eq(rawget(adDB.defaults, "iconSize"), 30, "Global: a write lands on the stored block")
    check(Defaults:IsModified(rec, "iconSize"), "Global: ...and reports modified")
    eq(Defaults:Count(rec, KEYS), 1, "Global: ...once")

    local host = fakeHost()
    local changes = GA:ResetKeys(host, rec, KEYS, "party", "General")
    eq(changes.iconSize.old, 30, "Global: reset reports what was there")
    eq(changes.iconSize.new, 24, "Global: ...and what it goes back to")
    check(rawget(adDB.defaults, "iconSize") == nil,
        "☠ Global: reset UNSET the key -- the block follows the shipped value again")
    eq(rec.iconSize, 24, "Global: ...and it reads as the fallback again")
    eq(Defaults:Count(rec, KEYS), 0, "Global: nothing modified afterwards")
    check(host:Written("iconSize") ~= nil, "Global: the clear went through the bracket")

    -- A value equal to the fallback is not a change, even when it is stored.
    adDB.defaults.iconScale = 1.0
    eq(Defaults:IsModified(rec, "iconScale"), false,
        "Global: a stored value equal to the shipped one is not modified")
end

-- ============================================================
-- 6b. THE FALLBACK TABLE AND THE SHIPPED PROFILE MUST AGREE
-- ☠ TWO TABLES, ONE ANSWER. Config.lua seeds a new profile's
-- auraDesigner.defaults; the editor's GLOBAL_DEFAULTS_FALLBACK is what the
-- controls resolve through AND what the modified tick now measures against. A
-- key where the two disagree is a control that reports modified the day the
-- profile is created, having never been touched.
-- ============================================================
do
    local shipped = DF.PartyDefaults and DF.PartyDefaults.auraDesigner
                    and DF.PartyDefaults.auraDesigner.defaults
    check(type(shipped) == "table", "the shipped profile has an auraDesigner defaults block")
    local FB = P.GLOBAL_DEFAULTS_FALLBACK
    check(type(FB) == "table", "...and the editor publishes its fallback table")
    local disagree = {}
    for k, v in pairs(FB or {}) do
        local s = shipped and shipped[k]
        if s ~= nil and not deepsame(s, v) then
            disagree[#disagree + 1] = k .. " (shipped " .. tostring(s) .. ", fallback " .. tostring(v) .. ")"
        end
    end
    eq(#disagree, 0, "every shared key agrees: " .. table.concat(disagree, ", "))
    -- The one this phase added, named explicitly so a silent removal fails here too.
    eq(FB.indicatorFrameLevel, shipped and shipped.indicatorFrameLevel,
        "the frame level's fallback is the shipped no-op, not the slider's minimum")
end

-- ============================================================
-- 6c. THE SOUND RECORD -- two keys the walk cannot see
-- Both controls bind through a custom get/set onto the Aura Designer block
-- itself, so the row names them through ClaimKeys' `extra` door and measures
-- them against this.
-- ============================================================
do
    for k in pairs(adDB) do if k ~= "defaults" then adDB[k] = nil end end
    local rec = CreateSoundSettingsProxy()
    local KEYS = { "soundEnabled", "soundChannel" }

    eq(Defaults:Count(rec, KEYS), 0, "Sound: an untouched block reports nothing modified")
    eq(rec.soundEnabled, true, "Sound: absent means enabled")
    eq(rec.soundChannel, "Master", "Sound: ...and Master")

    -- ☠ FALSE IS A VALUE, NOT AN ABSENCE. GetStored is a rawget for this reason:
    -- `soundEnabled = false` is the muted state and must not read as unset.
    adDB.soundEnabled = false
    check(Defaults:IsModified(rec, "soundEnabled"), "Sound: muting reports modified")
    adDB.soundEnabled = true
    eq(Defaults:IsModified(rec, "soundEnabled"), false,
        "Sound: ...and explicitly enabling it does not, because that IS the default")

    adDB.soundChannel = "SFX"
    check(Defaults:IsModified(rec, "soundChannel"), "Sound: a non-Master channel reports modified")
    GA:ResetKeys(fakeHost(), rec, KEYS, "party", "Sound Alerts")
    check(rawget(adDB, "soundChannel") == nil, "Sound: reset unsets the channel")
    eq(rec.soundChannel, "Master", "Sound: ...so it follows Master again")
end

-- ============================================================
-- 6d. A GROUP'S STYLE RECORD -- copy-on-read again
-- ☠ THE SAME TRAP AS THE EFFECT PROXY, in a different record. This one copies a
-- table-valued default onto group.style on the way past so a colour sub-key edit
-- persists, which means presence on the style block is no evidence of an edit.
-- ============================================================
do
    local group = { id = 1, kind = "filter", name = "G" }
    local rec = CreateGroupStyleProxy(group)
    local KEYS = { "shape", "hideSwipe", "showDuration", "durationColor",
                   "durationBarEnabled", "stackColor" }

    check(rawget(rec, "__dfDefaultsAdapter") ~= nil, "style: the record carries the adapter")
    eq(Defaults:Count(rec, KEYS), 0, "style: a style-less group reports nothing modified")

    -- ☠ GetStored READS THE STORED BLOCK AND ONLY THE STORED BLOCK. Asserted
    -- DIRECTLY, because the downstream answer cannot tell the two apart: an
    -- adapter that resolved its own fallback would return a value EQUAL to
    -- GetDefault, and ValuesEqual would still call it unmodified. What it would
    -- not survive is this proxy's copy-on-read -- the read that answered "is this
    -- modified" would itself write the key onto group.style.
    local styleAdapter = rawget(rec, "__dfDefaultsAdapter")
    check(styleAdapter.GetStored("durationColor") == nil,
        "style: GetStored answers nil for an unset key, not the fallback")
    eq(styleAdapter.GetDefault("shape"), "icon", "style: ...GetDefault is the one that answers it")
    for i = 1, #KEYS do
        styleAdapter.GetStored(KEYS[i])
        styleAdapter.GetDefault(KEYS[i])
    end
    check(next(group.style) == nil,
        "☠ style: a full adapter pass writes NOTHING onto group.style")

    for i = 1, #KEYS do local _ = rec[KEYS[i]] end
    check(rawget(group.style, "durationColor") ~= nil,
        "style: reading a table-valued key COPIED it onto group.style")
    check(rawget(group.style, "stackColor") ~= nil, "style: ...both of them")
    eq(Defaults:Count(rec, KEYS), 0,
        "☠ style: ...and the group STILL reports zero modified keys after every key has been read")

    -- The other half: a sub-key edit to a copied colour IS an edit.
    rec.durationColor.r = 0.5
    check(Defaults:IsModified(rec, "durationColor"), "style: a sub-key edit to a copied colour reports modified")

    rec.shape = "square"
    check(Defaults:IsModified(rec, "shape"), "style: an edited key reports modified")
    local changes = GA:ResetKeys(fakeHost(), rec, KEYS, "party", "Appearance")
    eq(changes.shape.new, "icon", "style: reset goes back to the shipped shape")
    check(rawget(group.style, "shape") == nil, "style: ...by UNSETTING it")
    check(rawget(group.style, "durationColor") == nil, "style: ...and the edited colour with it")
    eq(Defaults:Count(rec, KEYS), 0, "style: nothing modified afterwards")

    -- The Border seeds are lifted off the icon type's defaults, so an untouched
    -- group's border reads the same values a placed icon's does.
    eq(rec.BorderColor and rec.BorderColor.a, TYPE_DEFAULTS.icon.BorderColor.a,
        "style: the Border* seeds come from the icon type's defaults")
end

-- ============================================================
-- 6e. A GROUP RECORD VIEW -- and why it cannot be an adapter on the group
-- ☠ A LAYOUT GROUP IS SavedVariables. It goes through LibSerialize on profile
-- export, which cannot carry a function, so the hook lives on a VIEW and the
-- controls keep binding the group itself.
-- ⚠ AND THE VIEW HAS NO ClearKey. Every reader -- the factory, the controls --
-- reads these fields off the record directly, so an unset `anchor` is a nil where
-- a string is expected. Reset WRITES the shipped value, the Text Designer Global
-- tab's rule.
-- ============================================================
do
    local group = { id = 1, name = "G", anchor = "TOPLEFT", offsetX = 0, offsetY = 0,
                    growDirection = "RIGHT_DOWN", iconsPerRow = 8, spacing = 2,
                    members = {} }
    local rec = P.GroupRecordView(group)
    local KEYS = { "anchor", "offsetX", "offsetY", "growDirection", "iconsPerRow", "spacing" }

    check(rec ~= group, "☠ group: the record is a VIEW, not the group")
    check(rawget(group, "__dfDefaultsAdapter") == nil,
        "group: ...so no function-valued key was put on a table that gets serialised")
    check(rawget(rec, "__dfDefaultsAdapter") ~= nil, "group: the hook lives on the view")
    eq(rec.anchor, "TOPLEFT", "group: the view reads through to the group")
    local gAdapter = rawget(rec, "__dfDefaultsAdapter")
    check(gAdapter.GetStored("maxIcons") == nil,
        "group: GetStored answers nil for a key the group does not hold")
    eq(gAdapter.GetDefault("iconsPerRow"), 8,
        "group: ...and GetDefault answers the member group's shipped 8")

    eq(Defaults:Count(rec, KEYS), 0, "group: a freshly created member group reports nothing modified")
    rec.iconsPerRow = 5
    eq(group.iconsPerRow, 5, "group: a write through the view lands on the group")
    check(Defaults:IsModified(rec, "iconsPerRow"), "group: ...and reports modified")

    local host = fakeHost()
    local changes = GA:ResetKeys(host, rec, KEYS, "party", "Growth")
    eq(changes.iconsPerRow.new, 8, "group: reset goes back to the member group's shipped 8")
    eq(group.iconsPerRow, 8, "group: ...WRITTEN into the group")
    check(rawget(group, "iconsPerRow") ~= nil,
        "☠ group: ...never unset -- the factory reads this field directly")

    -- A FILTER group ships compact 4x4 with the styling pair, so the same key has
    -- a different default. Measuring one against the other's would report a brand
    -- new group as modified.
    local fg = { id = 2, kind = "filter", name = "F", iconsPerRow = 4, maxIcons = 4, iconSize = 24 }
    local frec = P.GroupRecordView(fg)
    eq(Defaults:IsModified(frec, "iconsPerRow"), false,
        "group: a filter group's shipped 4 is not modified")
    eq(Defaults:IsModified(rec, "iconsPerRow"), false, "group: ...and neither is a member group's 8")
    fg.iconsPerRow = 8
    check(Defaults:IsModified(frec, "iconsPerRow"), "group: ...but 8 on a FILTER group is")

    -- The optional sort fields: absent means the family default, and the two
    -- families disagree about what that is.
    local dg = { id = 3, name = "D", anchor = "TOPLEFT", iconsPerRow = 4, maxIcons = 4, iconSize = 24 }
    local drec = P.DebuffGroupRecordView(dg)
    eq(drec.sortOrder, "TIME", "group: a debuff group's family sort default is TIME")
    eq(frec.sortOrder, "DEFAULT", "group: ...and a filter group's is DEFAULT")
    eq(Defaults:IsModified(drec, "sortOrder"), false, "group: absent is never modified")
    dg.sortOrder = "DEFAULT"
    check(Defaults:IsModified(drec, "sortOrder"),
        "group: ...but pinning a debuff group at DEFAULT is a change")

    -- The selection block is its OWN record: the group's view answers for anchor
    -- and spacing and has never heard of `boss`.
    local sel = { boss = true, role = true, dispellableMode = "PLAYER",
                  hideLongMinutes = 5, keepImportant = true }
    local srec = P.DebuffSelectionView(sel)
    eq(Defaults:Count(srec, { "boss", "role", "priority", "dispellableMode",
                              "hideLong", "hideLongMinutes", "keepImportant" }), 0,
        "selection: a freshly created debuff group's categories report nothing modified")
    eq(Defaults:IsModified(drec, "boss"), false,
        "selection: ...and the GROUP's view cannot answer for a category at all")
    sel.boss = false
    check(Defaults:IsModified(srec, "boss"), "selection: turning Boss off reports modified")
    GA:ResetKeys(fakeHost(), srec, { "boss" }, "party", "Categories")
    eq(sel.boss, true, "selection: reset writes the shipped true back")
end

-- ============================================================
-- 6f. NONE OF THE THREE LEAKS A FUNCTION INTO A SERIALISABLE TABLE
-- ============================================================
do
    for k in pairs(adDB) do if k ~= "defaults" then adDB[k] = nil end end
    for k in pairs(adDB.defaults) do adDB.defaults[k] = nil end
    local group = { id = 1, kind = "filter", name = "G" }
    local grec = CreateGroupStyleProxy(group)
    for _, k in ipairs({ "shape", "durationColor", "stackColor", "BorderColor" }) do
        local _ = grec[k]
    end
    local gv = P.GroupRecordView(group)
    local _ = gv.anchor
    local sound = CreateSoundSettingsProxy()
    sound.soundChannel = "SFX"
    local gd = CreateGlobalDefaultsProxy()
    gd.iconSize = 26

    local found = {}
    local function sweep(t, seen)
        seen = seen or {}
        if seen[t] then return end
        seen[t] = true
        for k, v in pairs(t) do
            if k == "__dfDefaultsAdapter" then found[#found + 1] = tostring(k) end
            if type(v) == "function" then found[#found + 1] = "function at " .. tostring(k) end
            if type(v) == "table" then sweep(v, seen) end
        end
    end
    sweep(group)
    sweep(adDB)
    eq(#found, 0, "nothing function-valued reached the group record or the Aura Designer block")
end

C_Timer       = savedTimer
tinsert       = savedTinsert
CreateFrame   = savedCreateFrame
GetLocale     = savedGetLocale
DandersFrames = savedDandersFrames
