local NS = ...

-- ============================================================
-- DESIGNER DEFAULTS -- the adapter hook, end to end
-- DandersFrames/Core/Defaults.lua  +  AuraDesigner/UI/Groups.lua  +  Cards.lua
-- ------------------------------------------------------------
-- The settings-defaults engine recognises DF.db.party / DF.db.raid / the real
-- raid table BY IDENTITY, and both designers bind their controls to a metatable
-- PROXY over one record instead. Handed a proxy the engine returned nil, and
-- every verb built on it died quietly: a modified tick that never lights, a
-- reset that writes nothing -- no error in any of them. The adapter hook is what lets a record answer for itself.
--
-- Four things are pinned here, and all four fail SILENTLY in game:
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
--   4. THE HOOK IS INERT FOR EVERYTHING THAT SHIPS. No settings table carries
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
-- The REAL engine and the REAL designer files. The one
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
    load_options_file_into("AuraDesigner/UI/Groups.lua", {})
    -- ☠ AND THE CARD FILE, for its three records. It is a 3,300-line page file,
    -- but nothing in it RUNS at load: it declares locals off the fake GUI table
    -- above and hangs functions on P. The three records tested below are minted by
    -- factories that touch no frame, which is why they were lifted out of the
    -- section builders around them.
    load_options_file_into("AuraDesigner/UI/Cards.lua", {})
    DandersFrames = savedDandersFrames
    CreateFrame, GetLocale = savedCreateFrame, savedGetLocale
end

local Defaults = DF.Defaults
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

-- A reset as the adapter contract describes one (Core/Defaults.lua): a record
-- that can UNSET a key (ClearKey) unsets it, anything else gets its shipped value
-- written back, and a key already at its default is left alone. Returns
-- { [key] = { old =, new = } } for the keys it changed.
local function reset(db, keys)
    local adapter = rawget(db, "__dfDefaultsAdapter")
    local changes = {}
    for _, key in ipairs(keys) do
        if Defaults:IsModified(db, key) then
            -- Through the adapter, never `db[key]`: the Aura Designer's proxies copy a
            -- default onto the record when a key is READ, so a read would undo the clear.
            local old = deepcopy(adapter and adapter.GetStored(key) or db[key])
            local def = Defaults:GetDefaultFor(db, key)
            if adapter and type(adapter.ClearKey) == "function" then
                adapter.ClearKey(key)
            else
                db[key] = deepcopy(def)
            end
            changes[key] = { old = old, new = def }
        end
    end
    return changes
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
    check(type(CreateInstanceProxy) == "function", "the Aura Designer's instance proxy is reachable")
    check(type(CreateProxy) == "function", "...and its per-type proxy")
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

    -- ...and a profile table has no adapter, so a reset WRITES the shipped value.
    local changes = reset(party, keys)
    eq(changes.absorbBarHeight.new, DF.PartyDefaults.absorbBarHeight, "reset put the shipped value back")
    eq(party.absorbBarHeight, DF.PartyDefaults.absorbBarHeight, "...into the table")
    check(rawget(party, "absorbBarHeight") ~= nil, "...as a WRITE; a profile key is never unset")
    eq(Defaults:Count(party, keys), 0, "...and nothing reports modified afterwards")

    -- A table the engine has never understood still answers "not modified",
    -- exactly as it did: no adapter, no identity match, no dot.
    local stranger = { frameWidth = 999 }
    eq(Defaults:Count(stranger, keys), 0, "an unknown table still answers zero")
    eq(Defaults:IsModified(stranger, "frameWidth"), false, "...and false")
    check(next(reset(stranger, keys)) == nil,
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

    local changes = reset(proxy, AD_KEYS)
    eq(changes.size.old, 30, "reset reports what was there")
    eq(changes.size.new, 24, "...and what it goes back to")
    check(rawget(inst, "size") == nil,
        "☠ reset UNSET the key rather than writing the default in -- the effect follows the Global tab again")
    eq(proxy.size, 24, "...and it reads as the default again")
    eq(Defaults:Count(proxy, AD_KEYS), 0, "...nothing modified afterwards")

    -- A key already at its default is not touched at all.
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

    local changes = reset(proxy, AD_KEYS)
    check(changes.durationColor ~= nil, "...and a reset picks it up")
    check(rawget(inst, "durationColor") == nil, "...clearing it")
    eq(proxy.durationColor.r, 1, "...so it resolves to the default again")
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
    reset(proxy, keys)
    check(rawget(pool[AURA].icon, "size") == nil, "...and a reset unsets it")
end

-- ============================================================
-- THE EFFECT PROXIES LEAK NOTHING INTO A SERIALISABLE TABLE
-- The hook is a table of FUNCTIONS. LibSerialize cannot carry one, and profile
-- export deep-copies the whole auraDesigner block.
-- ============================================================
do
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
    local inst, proxy = freshEffect()
    for i = 1, #AD_KEYS do local _ = proxy[AD_KEYS[i]] end
    sweep(pool)
    eq(#found, 0, "nothing function-valued reached the aura pool, after a full panel-open read")
end


-- ============================================================
-- 6. THE AURA DESIGNER'S OTHER TWO RECORDS
-- ------------------------------------------------------------
-- Beyond the two proxies an EFFECT's controls bind, the Global and Layout Groups
-- tabs bind two more, and both fail the same silent way without an adapter: a
-- modified tick that stays dark.
--
--   the Global tab's defaults proxy      over adDB.defaults
--   a group's style proxy                over group.style, WITH copy-on-read
-- ============================================================

local CreateGlobalDefaultsProxy = P.CreateGlobalDefaultsProxy
local CreateGroupStyleProxy     = P.CreateGroupStyleProxy

do
    check(type(CreateGlobalDefaultsProxy) == "function", "the Global tab's defaults record is reachable")
    check(type(CreateGroupStyleProxy) == "function", "...and a group's style record")
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

    local changes = reset(rec, KEYS)
    eq(changes.iconSize.old, 30, "Global: reset reports what was there")
    eq(changes.iconSize.new, 24, "Global: ...and what it goes back to")
    check(rawget(adDB.defaults, "iconSize") == nil,
        "☠ Global: reset UNSET the key -- the block follows the shipped value again")
    eq(rec.iconSize, 24, "Global: ...and it reads as the fallback again")
    eq(Defaults:Count(rec, KEYS), 0, "Global: nothing modified afterwards")

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
    local changes = reset(rec, KEYS)
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
-- 6f. NEITHER LEAKS A FUNCTION INTO A SERIALISABLE TABLE
-- ============================================================
do
    for k in pairs(adDB) do if k ~= "defaults" then adDB[k] = nil end end
    for k in pairs(adDB.defaults) do adDB.defaults[k] = nil end
    local group = { id = 1, kind = "filter", name = "G" }
    local grec = CreateGroupStyleProxy(group)
    for _, k in ipairs({ "shape", "durationColor", "stackColor", "BorderColor" }) do
        local _ = grec[k]
    end
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
    eq(#found, 0, "nothing function-valued reached the group or the Aura Designer block")
end

C_Timer       = savedTimer
tinsert       = savedTinsert
CreateFrame   = savedCreateFrame
GetLocale     = savedGetLocale
DandersFrames = savedDandersFrames
