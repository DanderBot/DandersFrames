-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's.
-- Take the parent's table from the global it publishes (see GUI/Panel.lua).
local DF = DandersFrames
local GUI = DF and DF.GUI
if not GUI then return end
local L = DF.L

local ipairs, pairs, type, tostring = ipairs, pairs, type, tostring
local format, tsort, concat = string.format, table.sort, table.concat
local CreateFrame = CreateFrame

-- ============================================================
-- UNIT FRAMES SETTINGS
-- The settings window's Unit Frames module (spec 2026-10-30 sections 1.2-1.4
-- and 3): deck-2 tabs Player / Target / ToT / Focus / Pet / Boss, a sidebar of
-- its own, and one set of pages PER UNIT, each page id uf_<unit>_<kind>, so
-- search can index and land on every unit's copy of every page.
--
-- ★ THE PAGES ARE DANDERSFRAMES' OWN. A page whose cards come from a party page
-- (UnitFramePageData, PageData.lua: `source`) runs that page's builder
-- (page.dfBuilder) against the unit's own settings table (UF:GetUnitDB), so the
-- unit page has the same cards, controls and keys as the party page:
--   * the cards the unit does not get are filtered off (page.sectionFilter --
--     GUI:CreatePopoutPageTools), and so are single controls (Search.EntryFilter
--     marks them; HideFilteredControls hides them after the build);
--   * the party page's Reset / Sync / Copy row is swapped for this module's
--     unit-to-unit Reset / Copy row under the page's link banner (keeping two
--     units in step is a link -- LINKED FRAMES), and its See Also links for
--     this unit's pages.
-- Text Designer and Aura Designer are small pages of their own (the DF pages
-- are full editors that edit the party template).
--
-- One retained build per page: page.buildKey / page.buildDb (GUI/ModuleRegistry.lua).
-- Nothing here runs unless the companion addon is LOADED (the page provider is
-- only added then). Installed but switched off, it only turns the Modules page's
-- placeholder row into a switch.
-- ============================================================

local UFO = {}
GUI.UnitFrameOptions = UFO

UFO.ADDON = "DandersFrames_UnitFrames"
UFO.MODULE = "units"
-- Every unit with pages of its own (its settings table).
UFO.UNITS = { "player", "target", "targettarget", "focus", "focustarget", "pet", "boss" }
-- The deck-2 tabs. Six at UFO.TAB_WIDTH: 12 + 6 x 58 + 5 x 4 = 380 px. Deck 2 is
-- the window minus the 62 px rail, and its Undo / Redo / Test / Unlock cluster
-- takes ~229 px from the right (English), so at the 580 px window minimum the row
-- and the cluster overlap. While this module shows, the window's minimum is raised
-- to what the row + cluster actually measure (GUI:ModuleDeckMinWidth, GUI/Rail.lua),
-- never below UFO.MIN_WINDOW_WIDTH (the default 700). A seventh tab would need
-- another ~62 px. A unit with no tab lives on another unit's tab, in a sidebar
-- category of its own (UFO.TAB_OF).
UFO.TABS = { "player", "target", "targettarget", "focus", "pet", "boss" }
-- unit -> the tab its pages sit on (absent: its own tab).
UFO.TAB_OF = { focustarget = "focus" }
UFO.TAB_WIDTH = 58           -- deck-2 tab width (fitText still grows a long label)
UFO.MIN_WINDOW_WIDTH = 700   -- floor on the measured minimum while Units shows
UFO.unit = "player"          -- the deck-2 tab showing
UFO.pageMeta = {}            -- page name -> { unit = u | nil (every tab), tab = t, kind = k }
UFO.pagesByUnit = {}         -- unit -> kind -> page name
UFO.pageByKind = {}          -- kind -> its UnitFramePageData record
UFO.prefixes = {}            -- kind -> key prefixes its Reset / Copy act on

local ICONS = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
local SEP = " \194\183 "

local function Never() return true end

-- ============================================================
-- LABELS (literal L keys, so the locale tooling sees every one)
-- ============================================================
function UFO.UnitLabel(unit)
    if unit == "player" then return L["Player"] end
    if unit == "target" then return L["Target"] end
    if unit == "targettarget" then return L["Target of Target"] end
    if unit == "focus" then return L["Focus"] end
    if unit == "focustarget" then return L["Focus Target"] end
    if unit == "pet" then return L["Pet"] end
    if unit == "boss" then return L["Boss"] end
    return tostring(unit)
end

function UFO.UnitShortLabel(unit)
    if unit == "targettarget" then return L["ToT"] end
    return UFO.UnitLabel(unit)
end

function UFO.UnitDeckLabel(unit)
    if unit == "player" then return L["PLAYER"] end
    if unit == "target" then return L["TARGET"] end
    if unit == "targettarget" then return L["TOT"] end
    if unit == "focus" then return L["FOCUS"] end
    if unit == "pet" then return L["PET"] end
    if unit == "boss" then return L["BOSS"] end
    return tostring(unit)
end

function UFO.IsUnit(unit)
    for _, u in ipairs(UFO.UNITS) do if u == unit then return true end end
    return false
end

function UFO.IsTab(id)
    for _, u in ipairs(UFO.TABS) do if u == id then return true end end
    return false
end

-- The deck-2 tab a unit's pages sit on.
function UFO.TabOf(unit) return UFO.TAB_OF[unit] or unit end

-- The page's tab (a page of the module page set: every tab).
local function MetaTab(m) return m and (m.tab or m.unit) or nil end

-- The unit being edited: the page on screen's, else the tab's.
function UFO.EditedUnit()
    local m = UFO.pageMeta[GUI.CurrentPageName or ""]
    return (m and m.unit) or UFO.unit
end

-- ============================================================
-- THE COMPANION ADDON: installed, loaded, switched on
-- ============================================================
local function AddOns() return C_AddOns or {} end

function UFO.IsInstalled()
    local A = AddOns()
    if A.DoesAddOnExist then return A.DoesAddOnExist(UFO.ADDON) and true or false end
    if A.GetAddOnInfo then
        local _, _, _, _, reason = A.GetAddOnInfo(UFO.ADDON)
        return reason ~= "MISSING"
    end
    return false
end

function UFO.IsLoaded()
    local A = AddOns()
    return A.IsAddOnLoaded and A.IsAddOnLoaded(UFO.ADDON) and true or false
end

-- Switched on for this character: what the next reload will run. (Loaded is what
-- runs now; the two differ between a switch and the reload.)
function UFO.IsEnabled()
    local A = AddOns()
    if A.GetAddOnEnableState then
        return (A.GetAddOnEnableState(UFO.ADDON, nil) or 0) > 0
    end
    return UFO.IsLoaded()
end

function UFO.PromptReload(message)
    if not DF.ShowPopupAlert then return end
    DF:ShowPopupAlert({
        title = L["Reload Required"],
        message = message,
        buttons = {
            { label = L["Reload Now"], onClick = function() ReloadUI() end },
            { label = L["Later"] },
        },
    })
end

-- The Modules page's switch (setEnabled(on, checkbox, onDone)) and the Settings
-- page's Enabled tick: the addon list's own switch, then the reload prompt when the
-- answer now differs from what is running.
function UFO.SetEnabled(on, _, onDone)
    local A = AddOns()
    if on then
        if A.EnableAddOn then A.EnableAddOn(UFO.ADDON) end
    else
        if A.DisableAddOn then A.DisableAddOn(UFO.ADDON) end
    end
    if onDone then onDone() end
    if (on and true or false) ~= UFO.IsLoaded() then
        UFO.PromptReload(L["Turning Unit Frames on or off requires a UI reload to take effect.\n\nReload now?"])
    end
end

-- Home's tile and the Modules page: the units drawn ("Player · Target · ToT").
function UFO.Status()
    if not UFO.IsEnabled() then return L["Off"] end
    local UF = DF.UnitFrames
    if not (UFO.IsLoaded() and UF) then return L["Reload Required"] end
    local names = {}
    for _, unit in ipairs(UF.SPAWNED_UNITS or {}) do
        local db = UF:GetUnitDB(unit)
        if not db or db.source == nil or db.source == "DF" then
            names[#names + 1] = UFO.UnitShortLabel(unit)
        end
    end
    if #names == 0 then return L["Off"] end
    return concat(names, SEP)
end

-- Q9: DandersFrames' own "Hide Blizzard Player Frame" (Global > Settings) stands
-- aside while this module owns the player frame.
function UFO.PlayerFrameOwnerNote()
    if not UFO.IsLoaded() then return nil end
    local UF = DF.UnitFrames
    local db = UF and UF:GetUnitDB("player")
    if db and db.source ~= "Blizzard" then
        return L["Unit Frames handles the Blizzard player frame."]
    end
    return nil
end

-- ============================================================
-- PAGES BY UNIT
-- ============================================================
function UFO.PageName(unit, kind) return "uf_" .. unit .. "_" .. kind end

-- The page to land on when the tab moves to `unit`, given the page showing: the
-- module-wide Settings page stays put, a unit page goes to the same kind on the
-- new unit, else the unit's first page.
function UFO.PageForTab(unit, from)
    local m = from and UFO.pageMeta[from]
    if m and m.unit == nil then return from end
    local pages = UFO.pagesByUnit[unit]
    if not pages then return nil end
    if m and pages[m.kind] then return pages[m.kind] end
    return pages.frame or UFO.FirstPageOf(unit)
end

function UFO.FirstPageOf(unit)
    local pages = UFO.pagesByUnit[unit]
    if not pages then return nil end
    for _, rec in ipairs(UFO.data and UFO.data.pages or {}) do
        if pages[rec.kind] then return pages[rec.kind] end
    end
end

-- ============================================================
-- COPY / RESET BETWEEN UNITS
-- The party<->raid row (GUI/Pages/Options.lua CreateCopyButton) generalised to
-- unit<->unit, here rather than in DandersFrames. A unit's settings are sparse
-- (stored overrides over its own defaults, UF:GetUnitDB), so a copy writes the
-- SOURCE's effective value and drops it again where it equals the destination's
-- own default.
-- Keeping two units in step is a LINK (LINKED FRAMES, below; the engine is the
-- companion's Links.lua): per element, layout and look shared, mirrored or
-- each unit's own, re-applied after every settings write from the unit being
-- edited. A copy or a reset on a linked unit carries on to its partner.
-- ============================================================
local function DeepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not DeepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function Copy(v)
    if type(v) == "table" and DF.DeepCopy then return DF:DeepCopy(v) end
    return v
end

-- Keys a unit-level copy must never move (who draws it, where it is).
local NEVER_COPIED = { source = true, position = true,
                       castbarPosition = true, classPowerPositionRecord = true }

function UFO.Prefixes(kind)
    if UFO.prefixes[kind] then return UFO.prefixes[kind] end
    local rec = UFO.pageByKind[kind]
    local src = rec and rec.source
    if src then
        return (DF.SECTION_PREFIXES and DF.SECTION_PREFIXES[src])
            or (DF.SectionRegistry and DF.SectionRegistry[src]) or {}
    end
    if kind == "text" then return { "textDesignerPreset" } end
    if kind == "auradesigner" then return { "auraDesignerEnabled", "auraDesignerPreset" } end
    if kind == "visibility" then return { "vis" } end
    if kind == "castbar" then return { "castbar" } end
    if kind == "classpower" then return { "classPower" } end
    if kind == "portrait" then return { "portrait" } end
    if kind == "rings" then return { "frameStyle", "ringSize", "rings", "ringPortrait3D" } end
    if kind == "unitIcons" then return { "restingIcon", "pvpIcon", "classification", "classDragon", "classBorder" } end
    if kind == "bosslayout" then return { "boss" } end
    return {}
end

local function Owns(prefixes, key)
    if type(key) ~= "string" or NEVER_COPIED[key] then return false end
    if DF.SectionOwnsKey then return DF:SectionOwnsKey(prefixes, key) end
    for _, p in ipairs(prefixes) do
        if key:sub(1, #p) == p then return true end
    end
    return false
end

-- Every key either unit could hold for this page.
local function KeysFor(UF, prefixes, a, b)
    local seen, keys = {}, {}
    local function take(t)
        if type(t) ~= "table" then return end
        for k in pairs(t) do
            if not seen[k] and Owns(prefixes, k) then seen[k] = true; keys[#keys + 1] = k end
        end
    end
    take(DF.PartyDefaults)
    take(UF.UnitDefaults and UF.UnitDefaults[a])
    take(UF.UnitDefaults and UF.UnitDefaults[b])
    take(UF:GetStoredUnit(a))
    take(UF:GetStoredUnit(b))
    return keys
end

local function EffectiveValue(UF, unit, key)
    local stored = UF:GetStoredUnit(unit)
    local v = stored and stored[key]
    if v == nil then v = UF:GetUnitDefault(unit, key) end
    return v
end

-- Copy one page's settings from unit `src` to unit `dst`. Returns how many keys
-- the destination now differs from its own defaults in, or nil. A linked `dst`
-- passes what it took on to its partner.
function UFO.CopyPage(kind, src, dst)
    local UF = DF.UnitFrames
    if not UF or src == dst then return nil end
    local prefixes = UFO.Prefixes(kind)
    local dstStored = UF:GetStoredUnit(dst)
    if not dstStored or #prefixes == 0 then return nil end
    local n = 0
    for _, key in ipairs(KeysFor(UF, prefixes, src, dst)) do
        local v = EffectiveValue(UF, src, key)
        if v == nil or DeepEqual(v, UF:GetUnitDefault(dst, key)) then
            dstStored[key] = nil
        else
            dstStored[key] = Copy(v)
            n = n + 1
        end
    end
    UFO.PushLinks(dst)
    return n
end

-- Back to the unit's own defaults, for this page's keys. A linked page's shared
-- settings are reset on the partner too: the reset propagates like any edit.
function UFO.ResetPage(kind, unit)
    local UF = DF.UnitFrames
    local stored = UF and UF:GetStoredUnit(unit)
    if not stored then return 0 end
    local prefixes = UFO.Prefixes(kind)
    local keys = {}
    for k in pairs(stored) do
        if Owns(prefixes, k) then keys[#keys + 1] = k end
    end
    for _, k in ipairs(keys) do stored[k] = nil end
    UFO.PushLinks(unit)
    return #keys
end

-- ============================================================
-- COPY FROM PARTY / RAID
-- A unit page's keys that also exist in the group frames' settings
-- (DF:GetDB("party") / DF:GetDB("raid")) come across, so a health colour and its
-- gradient set up for party frames need not be set up again. Only how a piece
-- LOOKS moves: a group frame is a different size, in a different place, for a
-- different job. Skipped, in order (UFO.GroupCopySkip says which rule):
--   never     who draws the frame and where it is (NEVER_COPIED), and the group
--             mover (permanentMover*), which a unit frame does not have
--   layout    anchors, sides, growth, offsets: the Links engine's own layout /
--             look split (Links.Aspect), so a copy and a link agree on the line
--   size      how big a piece is, how many and how far apart (UFO.IsSizeKey).
--             The Links engine counts sizes as look -- a link SHARES them between
--             two units of one kind -- but a party frame's 18px buff is not a
--             220px target frame's; border, shadow, font and texture-tile sizes and
--             the in-icon text scales stay look (UFO.SIZE_LOOK)
--   hidden    a control or a whole card the unit's page does not show (the page
--             data's `hide` and `cardKeys`): nothing may change that the page
--             cannot change back
--   meaning   a key the unit frame keeps with another meaning (UFO.GROUP_MEANING):
--             aggro on a frame that usually shows an enemy (whose threat is not
--             yours), and the aura FILTERS on an enemy frame (a party filter picks
--             what to dispel off a friend; an enemy frame shows your debuffs)
-- A value equal to the unit's own default is dropped rather than stored, like
-- UFO.CopyPage.
-- ============================================================
UFO.GROUP_SOURCES = { party = true, raid = true }

-- Suffixes that make a key a SIZE (how big, how many, how far apart).
UFO.SIZE_SUFFIXES = { "Width", "Height", "Size", "Scale", "Spacing", "Padding",
                      "PaddingX", "PaddingY", "Gap", "Max", "Wrap", "MatchWidth" }
-- ...unless it ends in one of these: a size that is part of how a piece looks.
UFO.SIZE_LOOK = { "BorderSize", "ShadowSize", "TileSize", "FontSize", "BadgeSize", "GradientSize",
                  "CasterScale", "DurationScale", "StackScale", "SymbolScale", "ImportantScale",
                  "AnimationScale" }
UFO.GROUP_NEVER_PREFIXES = { "permanentMover" }

local HOSTILE = { target = true, targettarget = true, focus = true, focustarget = true, boss = true }
local ENEMY_AURAS = { target = true, focus = true, boss = true }
local AURA_FILTERS = { "debuffFilter", "debuffHide", "directDebuff", "directBuff",
                       "buffFilterSelection", "defensiveFilterSelection" }
-- key or key prefix -> the units it means something else on.
UFO.GROUP_MEANING = { aggroHighlightMode = HOSTILE }
for _, p in ipairs(AURA_FILTERS) do UFO.GROUP_MEANING[p] = ENEMY_AURAS end

local function EndsWithAny(key, list)
    for _, s in ipairs(list) do
        if #key >= #s and key:sub(-#s) == s then return true end
    end
    return false
end

local function StartsWith(key, p) return key:sub(1, #p) == p end

function UFO.IsSizeKey(key)
    if type(key) ~= "string" then return false end
    if EndsWithAny(key, UFO.SIZE_LOOK) then return false end
    return EndsWithAny(key, UFO.SIZE_SUFFIXES)
end

-- The keys of the cards on this page that `unit` does not see.
local function HiddenCardKeys(rec, unit)
    local out = {}
    for card, keys in pairs(rec.cardKeys or {}) do
        if not UFO.CardShown(rec, unit, card) then
            for _, k in ipairs(keys) do out[k] = true end
        end
    end
    return out
end

-- Why `key` is not copied from the group frames onto `unit`'s page, or nil.
function UFO.GroupCopySkip(rec, unit, key, hiddenCards)
    if type(key) ~= "string" or NEVER_COPIED[key] then return "never" end
    for _, p in ipairs(UFO.GROUP_NEVER_PREFIXES) do
        if StartsWith(key, p) then return "never" end
    end
    local Lk = UFO.Links()
    if Lk and Lk.Aspect and Lk.Aspect(key) == "layout" then return "layout" end
    if UFO.IsSizeKey(key) then return "size" end
    local h = rec and rec.hide and rec.hide[key]
    if h and h[unit] then return "hidden" end
    hiddenCards = hiddenCards or (rec and HiddenCardKeys(rec, unit)) or {}
    if hiddenCards[key] then return "hidden" end
    for p, units in pairs(UFO.GROUP_MEANING) do
        if units[unit] and StartsWith(key, p) then return "meaning" end
    end
    return nil
end

-- Group frames can be a copy source for a page drawn from a party page.
function UFO.CanCopyFromGroup(kind)
    local rec = UFO.pageByKind[kind]
    return (rec and rec.source) and true or false
end

-- The keys a copy from `mode`'s frames moves onto `unit`'s page, sorted.
function UFO.GroupCopyKeys(kind, unit, mode)
    local UF = DF.UnitFrames
    local rec = UFO.pageByKind[kind]
    if not (UF and rec and rec.source and UFO.GROUP_SOURCES[mode]) then return {} end
    local src = DF.GetDB and DF:GetDB(mode)
    if type(src) ~= "table" then return {} end
    local hiddenCards = HiddenCardKeys(rec, unit)
    local out = {}
    for _, key in ipairs(KeysFor(UF, UFO.Prefixes(kind), unit, unit)) do
        if src[key] ~= nil and not UFO.GroupCopySkip(rec, unit, key, hiddenCards) then
            out[#out + 1] = key
        end
    end
    tsort(out)
    return out
end

-- Copy one page's look from the party or raid frames onto `unit`. Returns how
-- many keys the unit now differs from its own defaults in, or nil. A linked unit
-- passes what it took on to its partner.
function UFO.CopyFromGroup(kind, mode, unit)
    local UF = DF.UnitFrames
    local stored = UF and UF:GetStoredUnit(unit)
    if not stored or not UFO.GROUP_SOURCES[mode] then return nil end
    local src = DF:GetDB(mode)
    local keys = UFO.GroupCopyKeys(kind, unit, mode)
    if #keys == 0 then return nil end
    local n = 0
    for _, key in ipairs(keys) do
        local v = src[key]
        if DeepEqual(v, UF:GetUnitDefault(unit, key)) then
            stored[key] = nil
        else
            stored[key] = Copy(v)
            n = n + 1
        end
    end
    UFO.PushLinks(unit)
    return n
end

-- ---- the undo step ----------------------------------------------------------
-- A copy is ONE step on the settings window's undo stack (DF.SettingsUndo): the
-- page's keys on the unit and on its linked partner, before and after. Restoring
-- them is the whole of it -- the values live in the stored tables, nothing else.
local function UnionKeys(UF, prefixes, units)
    local seen, out = {}, {}
    for _, u in ipairs(units) do
        for _, k in ipairs(KeysFor(UF, prefixes, u, u)) do
            if not seen[k] then seen[k] = true; out[#out + 1] = k end
        end
    end
    return out
end

local function Snapshot(stored, keys)
    local s = {}
    for _, k in ipairs(keys) do s[k] = Copy(stored[k]) end
    return s
end

local function Restore(stored, keys, snap)
    for _, k in ipairs(keys) do stored[k] = Copy(snap[k]) end
end

function UFO.UndoStack()
    local SU = DF.SettingsUndo
    return SU and SU.GetStack and SU:GetStack() or nil
end

function UFO.SourceLabel(from)
    if from == "party" then return L["Party Frames"] end
    if from == "raid" then return L["Raid Frames"] end
    return UFO.UnitLabel(from)
end

-- Copy page `kind` onto `unit` from `from` ("party", "raid" or another unit),
-- as one undo step. Returns the count the copy returned, or nil.
function UFO.CopyFrom(kind, from, unit)
    local UF = DF.UnitFrames
    local stored = UF and UF:GetStoredUnit(unit)
    if not stored or from == unit then return nil end
    local group = UFO.GROUP_SOURCES[from] and true or false
    if not group and not UFO.IsUnit(from) then return nil end
    local partner = UFO.Partner(unit)
    local pStored = partner and UF:GetStoredUnit(partner) or nil
    local keys = UnionKeys(UF, UFO.Prefixes(kind), { unit, partner or unit, group and unit or from })
    local before = Snapshot(stored, keys)
    local pBefore = pStored and Snapshot(pStored, keys)

    local n
    if group then n = UFO.CopyFromGroup(kind, from, unit) else n = UFO.CopyPage(kind, from, unit) end
    if n == nil then return nil end

    local after = Snapshot(stored, keys)
    local pAfter = pStored and Snapshot(pStored, keys)
    local stack = UFO.UndoStack()
    if stack then
        local function apply(s, ps)
            Restore(stored, keys, s)
            if pStored then Restore(pStored, keys, ps) end
            if partner then UFO.InvalidateUnitPages(partner) end
            UFO.AfterChange(unit)
        end
        stack:Push({
            label = format(L["Copied settings from %s to %s."], UFO.SourceLabel(from), UFO.UnitLabel(unit)),
            undo = function() apply(before, pBefore) end,
            redo = function() apply(after, pAfter) end,
        })
    end
    return n
end

-- ============================================================
-- LINKED FRAMES -- the settings side of the companion's Links.lua
-- (DandersFrames_UnitFrames). The data lives in the module table
-- (global.unitLinks); everything here reads and writes it through Links.
-- ============================================================
function UFO.Links()
    local UF = DF.UnitFrames
    return UF and UF.Links or nil
end

function UFO.Root()
    local Lk = UFO.Links()
    return Lk and Lk.LiveRoot() or nil
end

-- The unit `unit` is linked with, or nil.
function UFO.Partner(unit)
    local Lk, root = UFO.Links(), UFO.Root()
    if not (Lk and root and unit) then return nil end
    return Lk:Partner(root, unit)
end

-- The elements of page `kind` that are linked for `unit`, in page order:
-- { { elem = e, layout = "same"|"mirror"|"own", look = "same"|"own" }, ... }
function UFO.PageLinks(kind, unit)
    local out = {}
    local Lk, root = UFO.Links(), UFO.Root()
    if not (Lk and root and unit) then return out end
    for _, e in ipairs(Lk.ElementsForKind(kind)) do
        local layout, look = Lk:Aspects(root, unit, e.id)
        if layout ~= "own" or look ~= "own" then
            out[#out + 1] = { elem = e, layout = layout, look = look }
        end
    end
    return out
end

function UFO.PageLinked(kind, unit) return #UFO.PageLinks(kind, unit) > 0 end

-- `unit`'s link reaches its partner now. Returns how many of the partner's
-- settings changed, and the partner.
function UFO.PushLinks(unit)
    local Lk, root = UFO.Links(), UFO.Root()
    if not (Lk and root and unit) then return 0, nil end
    local n, partner = Lk:ApplyFrom(root, unit)
    n = n or 0
    if n > 0 and partner then UFO.InvalidateUnitPages(partner) end
    return n, partner
end

-- After a write: the unit being edited pushes its link to its partner.
function UFO.ApplyLinks()
    if GUI.ModuleView ~= UFO.MODULE then return 0 end
    return (UFO.PushLinks(UFO.EditedUnit()))
end

-- The link mark on the deck tabs and sidebar rows (GUI:SetLabelMark specs; the
-- tab may widen to fit it, a row never does).
UFO.LINK_ICON = ICONS .. "link.png"
UFO.TAB_MARK = { texture = UFO.LINK_ICON, size = 12, grow = true }
UFO.ROW_MARK = { texture = UFO.LINK_ICON, size = 12, grow = false }

function UFO.TabMark(unit)
    return UFO.Partner(unit) and UFO.TAB_MARK or nil
end

function UFO.PageMark(name)
    local m = UFO.pageMeta[name]
    -- The Linked Frames page carries the mark while any link exists.
    if m and m.kind == "links" then
        local root = UFO.Root()
        local t = root and root.global and root.global.unitLinks
        if type(t) == "table" then
            for u, link in pairs(t) do
                if type(link) == "table" and UFO.IsUnit(u) and UFO.IsUnit(link.to) then return UFO.ROW_MARK end
            end
        end
        return nil
    end
    if not (m and m.unit) then return nil end
    return UFO.PageLinked(m.kind, m.unit) and UFO.ROW_MARK or nil
end

function UFO.RefreshLinkMarks()
    if GUI.RefreshPageMarks then GUI:RefreshPageMarks() end
    if GUI.RefreshModuleShell then GUI:RefreshModuleShell(true) end
end

-- How an element is linked, as words: "position mirrored, size and style shared".
function UFO.AspectPhrase(layout, look)
    if layout == "mirror" and look == "same" then return L["position mirrored, size and style shared"] end
    if layout == "same" and look == "same" then return L["position, size and style shared"] end
    if layout == "mirror" then return L["position mirrored"] end
    if layout == "same" then return L["position shared"] end
    if look == "same" then return L["size and style shared"] end
    return nil
end

-- The linked page's banner text, or nil when nothing on the page is linked.
-- A page of one element names its aspects; the Frame page (two) names each.
function UFO.LinkBannerText(kind, unit)
    local partner = UFO.Partner(unit)
    local list = UFO.PageLinks(kind, unit)
    if not partner or #list == 0 then return nil end
    local how
    if #list == 1 and #(UFO.Links().ElementsForKind(kind)) == 1 then
        how = UFO.AspectPhrase(list[1].layout, list[1].look)
    else
        local parts = {}
        for _, x in ipairs(list) do
            parts[#parts + 1] = format("%s: %s", L[x.elem.title], UFO.AspectPhrase(x.layout, x.look))
        end
        how = concat(parts, "; ")
    end
    local who = UFO.UnitLabel(partner)
    return format(L["Linked to %s — %s. Linked settings changed here also change %s."], who, how, who)
end

-- A unit's pages are rebuilt on their next visit (a copy replaced tables under them).
function UFO.InvalidateUnitPages(unit)
    local pages = UFO.pagesByUnit[unit]
    if not pages then return end
    for _, name in pairs(pages) do
        local page = GUI.Pages and GUI.Pages[name]
        if page and page.Invalidate then page:Invalidate() end
    end
end

-- The frames, the page on screen and the link marks catch up after a copy, a
-- reset or a link change.
local function AfterChange(dst)
    if dst then UFO.InvalidateUnitPages(dst) end
    local UF = DF.UnitFrames
    if UF and UF.RequestRefresh then UF:RequestRefresh() end
    local name = GUI.CurrentPageName
    local page = name and GUI.Pages and GUI.Pages[name]
    if page and page.Refresh then page:Refresh() end
    UFO.RefreshLinkMarks()
end
UFO.AfterChange = AfterChange

-- ============================================================
-- THE PAGE'S ROW: Reset Page · Copy to...
-- Built from the shared helpers: StyleButton (danger) for Reset, an inline
-- CreateDropdown with a fixed caption (SetDisplayOverride) for the unit picker.
-- Right-aligned in column 2 exactly where the party row sits. Keeping two units
-- in step is a link (the banner above the row, and the Linked Frames card).
-- ============================================================
local function OtherUnitOptions(page, unit, extra)
    local opts = { _order = {} }
    for _, u in ipairs(UFO.UNITS) do
        local rec = UFO.pageByKind[page.kind]
        if u ~= unit and rec and rec.units[u] then
            opts[u] = UFO.UnitLabel(u)
            opts._order[#opts._order + 1] = u
        end
    end
    if extra then
        for _, e in ipairs(extra) do
            opts[e.key] = e.text
            opts._order[#opts._order + 1] = e.key
        end
    end
    return opts
end

function UFO.CreatePageRow(pg, rec, unit)
    local section = L[rec.title]
    local parent = pg.child

    local copy = GUI:CreateDropdown(parent, L["Copy to..."], OtherUnitOptions(rec, unit), nil, nil, nil,
        function() return nil end,
        function(dst)
            if not UFO.IsUnit(dst) then return end
            DF:ShowPopupAlert({
                title = format(L["Copy %s Settings"], section),
                message = format(L["Copy %s settings to %s?"], section, UFO.UnitLabel(dst)),
                buttons = {
                    { label = L["Copy"], onClick = function()
                        local n = UFO.CopyPage(rec.kind, unit, dst) or 0
                        if DF.Say then
                            DF:Say(format(L["Copied %d settings from %s to %s."], n,
                                UFO.UnitLabel(unit), UFO.UnitLabel(dst)))
                        end
                        AfterChange(dst)
                    end },
                    { label = L["Cancel"] },
                },
            })
        end,
        { inline = true })
    copy:SetSize(110, 26)
    copy.rightAlign = true
    if copy.SetDisplayOverride then copy:SetDisplayOverride(L["Copy to..."]) end

    -- Copy from...: the party / raid frames (a page drawn from a party page) and
    -- the other units. One undo step; without an undo stack, a confirmation first.
    -- Parented to the Copy to picker, like Reset, so the row shows and hides as one.
    local from
    local fromOpts = UFO.CopyFromOptions(rec, unit)
    if #fromOpts._order > 0 then
        from = GUI:CreateDropdown(copy, L["Copy from..."], fromOpts, nil, nil, nil,
            function() return nil end,
            function(src) UFO.RunCopyFrom(rec, unit, src, section) end,
            { inline = true })
        from:SetSize(120, 26)
        if from.SetDisplayOverride then from:SetDisplayOverride(L["Copy from..."]) end
        from:SetPoint("RIGHT", copy, "LEFT", GUI.SnapLen and GUI.SnapLen(from, -4) or -4, 0)
    end

    local reset = CreateFrame("Button", nil, copy, "BackdropTemplate")
    GUI:StyleButton(reset, {
        tone = "danger",
        icon = { texture = ICONS .. "refresh.png", size = 18 },
        text = L["Reset Page"],
    })
    reset:SetSize(115, 26)
    if reset.Text and GUI.SnapLenUp then
        reset:SetWidth(GUI.SnapLenUp(reset, math.ceil(reset.Text:GetStringWidth()) + 36))
    end
    reset:SetPoint("RIGHT", from or copy, "LEFT", GUI.SnapLen and GUI.SnapLen(reset, -4) or -4, 0)
    reset:HookScript("OnEnter", function(self)
        GUI:ShowTooltip(self, {
            title = format(L["Reset: %s"], section),
            lines = { format(L["Reset %s settings to defaults. This cannot be undone."], section) },
        })
    end)
    reset:HookScript("OnLeave", function() GUI:HideTooltip() end)
    reset:SetScript("OnClick", function()
        DF:ShowPopupAlert({
            title = format(L["Reset: %s"], section),
            message = UFO.ResetMessage(rec.kind, unit, section),
            buttons = {
                { label = L["Reset"], onClick = function()
                    UFO.ResetPage(rec.kind, unit)
                    AfterChange(UFO.Partner(unit))
                end },
                { label = L["Cancel"] },
            },
        })
    end)

    copy.dfUnitRow = { copy = copy, from = from, reset = reset }
    return copy
end

-- The Copy from... picker's sources: Party Frames and Raid Frames on a page drawn
-- from a party page, then every other unit that has this page.
function UFO.CopyFromOptions(rec, unit)
    local opts = { _order = {} }
    if UFO.CanCopyFromGroup(rec.kind) then
        for _, m in ipairs({ "party", "raid" }) do
            opts[m] = UFO.SourceLabel(m)
            opts._order[#opts._order + 1] = m
        end
    end
    local others = OtherUnitOptions(rec, unit)
    for _, u in ipairs(others._order) do
        opts[u] = others[u]
        opts._order[#opts._order + 1] = u
    end
    return opts
end

-- A pick in Copy from...: the copy, what it did in chat, the page catches up.
-- With the settings window's undo stack it runs at once (Ctrl-Z takes it back);
-- without one, a confirmation first, worded like Copy to's.
function UFO.RunCopyFrom(rec, unit, src, section)
    if not (UFO.GROUP_SOURCES[src] or UFO.IsUnit(src)) or src == unit then return end
    local function run()
        local n = UFO.CopyFrom(rec.kind, src, unit) or 0
        if DF.Say then
            DF:Say(format(L["Copied %d settings from %s to %s."], n, UFO.SourceLabel(src), UFO.UnitLabel(unit)))
            if UFO.GROUP_SOURCES[src] then DF:Say(L["Sizes and positions are not copied from group frames."]) end
        end
        AfterChange(unit)
    end
    if UFO.UndoStack() then return run() end
    DF:ShowPopupAlert({
        title = format(L["Copy %s Settings"], section),
        message = format(L["Copy %s settings from %s to %s?"], section, UFO.SourceLabel(src), UFO.UnitLabel(unit)),
        buttons = {
            { label = L["Copy"], onClick = run },
            { label = L["Cancel"] },
        },
    })
end

-- The reset confirmation. On a linked page it says the partner's linked
-- settings are reset too (the reset propagates like any other edit).
function UFO.ResetMessage(kind, unit, section)
    local partner = UFO.Partner(unit)
    if partner and UFO.PageLinked(kind, unit) then
        return format(L["Reset %s settings to defaults?\n\nThe linked settings on %s are reset too.\n\nThis cannot be undone."],
            section, UFO.UnitLabel(partner))
    end
    return format(L["Reset %s settings to defaults?\n\nThis cannot be undone."], section)
end

-- ============================================================
-- THE LINK BANNER at the top of a linked page: what it is linked to, how, and
-- a way to the Linked Frames card. A notice (live state, the tip modes do not
-- fold it); hidden while nothing on the page is linked, so it takes no room.
-- ============================================================
local function EditLinkMarkup()
    -- The banner re-tints a link with the accent; the colour here is a placeholder.
    return "|cffffffff|HufEditLink|h" .. L["Edit link"] .. "|h|r"
end

-- "Edit link" on a unit page: the Linked Frames page.
function UFO.OpenLinkCard(unit)
    if GUI.SelectTab then GUI.SelectTab(UFO.LINKS_PAGE or "uf_links") end
end

function UFO.CreateLinkBanner(pg, rec, unit)
    local banner = GUI:CreateInfoBanner(pg.child, { tone = "info", notice = true })
    if banner.SetIconTexture then banner:SetIconTexture(UFO.LINK_ICON) end
    local function onLink(data)
        if data == "ufEditLink" then UFO.OpenLinkCard(unit) end
    end
    banner.refreshContent = function(b)
        local text = UFO.LinkBannerText(rec.kind, unit)
        if text then b:SetHTML(text .. " " .. EditLinkMarkup(), onLink) end
    end
    banner.hideOn = function() return UFO.LinkBannerText(rec.kind, unit) == nil end
    banner.dfLinkBanner = true
    return banner
end

-- A unit page's head: the link banner across both columns, then the Reset /
-- Copy row in column 2 (where the party page's own row sits). Returns the row.
function UFO.AddPageHead(pg, rec, unit, Add, height, col)
    Add(UFO.CreateLinkBanner(pg, rec, unit), 32, "both")
    return Add(UFO.CreatePageRow(pg, rec, unit), height or 25, col or 2)
end

-- ============================================================
-- BUILDING A UNIT PAGE FROM A DANDERSFRAMES PAGE
-- ============================================================
local function Dispose(w)
    if w.Hide then w:Hide() end
    if w.ClearAllPoints then w:ClearAllPoints() end
    if GUI._trashFrame and w.SetParent then w:SetParent(GUI._trashFrame) end
end

-- See Also links pointed at this unit's own pages; links with no counterpart go.
local function MapLinks(links, unit)
    local out = {}
    local pages = UFO.pagesByUnit[unit] or {}
    for _, link in ipairs(links or {}) do
        for kind, name in pairs(pages) do
            local rec = UFO.pageByKind[kind]
            if rec and rec.source == link.pageId then
                out[#out + 1] = { pageId = name, label = link.label }
            end
        end
    end
    return out
end

-- A party builder's in-page link (GUI.PageLinkFor) on a unit page: to this unit's
-- own counterpart, false when the unit has none, nil for a page no unit has a copy
-- of (the link stays as it is). The Aura Designer page has no `source` (the unit
-- page is ours), so it is named here.
UFO.LINK_KIND = { auras_auradesigner = "auradesigner" }

function UFO.MapPageLink(unit, id)
    local kind = UFO.LINK_KIND[id]
    if not kind then
        for k, rec in pairs(UFO.pageByKind) do
            if rec.source == id then kind = k break end
        end
    end
    if not kind then return nil end
    local pages = UFO.pagesByUnit[unit]
    return (pages and pages[kind]) or false
end

-- Controls whose search entry the build marked (Search.EntryFilter) leave the page.
function UFO.HideFilteredControls(list)
    for _, w in ipairs(list or {}) do
        local entry = type(w) == "table" and rawget(w, "searchEntry")
        if type(entry) == "table" and entry.dfFilteredOut then
            w.hideOn = Never
            w.dfFilteredOut = true
        end
        local kids = type(w) == "table" and rawget(w, "groupChildren")
        if type(kids) == "table" then
            local ws = {}
            for i, e in ipairs(kids) do ws[i] = e.widget end
            UFO.HideFilteredControls(ws)
        end
    end
    UFO.HideOrphanHeaders(list)
end

-- A bare section header (GUI:CreateHeader) whose cards are ALL filtered off the
-- page goes with them. Its own hideOn cannot know: the party page's "Content"
-- header hides on GUI.SelectedMode ~= "raid", and under a unit page the mode can
-- be Raid while the card beneath it is filtered for units -- a header over nothing.
-- What counts as "its cards": the widgets after it in the same column, up to the
-- next bare header there; spacers and sync points are not content.
local function SameCol(a, b)
    return a == b or a == "both" or b == "both"
end
function UFO.HideOrphanHeaders(list)
    if type(list) ~= "table" then return end
    for i, h in ipairs(list) do
        if type(h) == "table" and rawget(h, "isSectionHeader") and not rawget(h, "dfFilteredOut") then
            local col = rawget(h, "layoutCol") or 1
            local filtered, content = 0, 0
            for j = i + 1, #list do
                local w = list[j]
                local wcol = type(w) == "table" and (rawget(w, "layoutCol") or 1)
                -- A full-width row (a See Also strip) closes every column's
                -- section: it is never one header's card. Counting it left the
                -- Highlights page's Threat header over nothing on Target of Target.
                if wcol == "both" and col ~= "both" and not (rawget(w, "isSpacer") or rawget(w, "isSyncPoint")) then
                    break
                end
                if type(w) == "table" and SameCol(wcol, col) then
                    if rawget(w, "isSectionHeader") then break end
                    if rawget(w, "dfFilteredOut") then
                        filtered = filtered + 1
                    elseif not (rawget(w, "isSpacer") or rawget(w, "isSyncPoint")) then
                        content = content + 1
                    end
                end
            end
            if filtered > 0 and content == 0 then
                h.hideOn = Never
                h.dfFilteredOut = true
            end
        end
    end
end

function UFO.CardAllowed(rec, unit, key)
    local u = rec.cards and rec.cards[key]
    return (u and u[unit]) and true or false
end

function UFO.ControlAllowed(rec, unit, dbKey)
    local h = dbKey and rec.hide and rec.hide[dbKey]
    return not (h and h[unit])
end

function UFO.BuildFromDF(self, db, Add, AddSpace, AddSyncPoint, rec, unit)
    local src = GUI.Pages and GUI.Pages[rec.source]
    local builder = src and src.dfBuilder
    if type(builder) ~= "function" then
        DF:DebugError("UF", "no builder for %s", tostring(rec.source))
        return
    end
    self.sectionFilter = function(key) return UFO.CardAllowed(rec, unit, key) end
    -- Unit-frame-only controls inside a DF card (Modules.lua reads it per card).
    if rec.kind == "icons" then self.dfIconCardExtras = UFO.IconCardExtras(self) end
    -- Whole cards of ours the party builder draws through its card door (UFO.ExtraCards).
    self.dfExtraCards = UFO.ExtraCards(self, rec, unit)

    local function PageAdd(widget, height, col)
        local row = type(widget) == "table" and rawget(widget, "dfCopyRow")
        if row then
            if type(row.prefixes) == "table" then UFO.prefixes[rec.kind] = row.prefixes end
            Dispose(widget)
            return UFO.AddPageHead(self, rec, unit, Add, height, col)
        end
        local links = type(widget) == "table" and rawget(widget, "dfLinks")
        if links then
            Dispose(widget)
            local mapped = MapLinks(links, unit)
            if #mapped == 0 then
                local empty = CreateFrame("Frame", nil, self.child)
                empty:SetSize(1, 1)
                return Add(empty, 0, col)
            end
            return Add(GUI:CreateSeeAlso(self.child, mapped), height, col)
        end
        return Add(widget, height, col)
    end

    local Search = DF.Search
    local heldFilter = Search and Search.EntryFilter
    local heldSuppress = Search and Search.SuppressRegistration
    if Search then
        Search.EntryFilter = function(entry) return UFO.ControlAllowed(rec, unit, entry.dbKey) end
    end
    -- The party page draws its PARTY variant: a builder that asks which mode it is
    -- building must never get "raid" here.
    local heldMode = GUI.SelectedMode
    GUI.SelectedMode = "party"
    local ok, err = pcall(builder, self, db, PageAdd, AddSpace, AddSyncPoint)
    GUI.SelectedMode = heldMode
    if Search then
        Search.EntryFilter = heldFilter
        Search.SuppressRegistration = heldSuppress
    end
    if not ok then error(err, 0) end
    UFO.HideFilteredControls(self.children)
end

-- ============================================================
-- GREYED CONTROLS SAY WHY (the kit's widget.disableReason)
-- A page's feature gate is made with UFO.Gate, which remembers what turns the
-- control back on; after a build, every widget whose disableOn is a gate gets
-- that reason for its hover (UFO.ApplyDisableReasons, from UFO.PageBuilder).
-- One place, so every gated control on these pages explains itself.
-- ============================================================
UFO.gateReasons = setmetatable({}, { __mode = "k" })

-- A gate: true when `test(d)` is, or when the `parent` gate is. Its reason
-- names the switch to flip -- the parent's first (the feature itself), then its
-- own `label`. verb "off": the switch has to be turned OFF (Always).
function UFO.Gate(label, test, parent, verb)
    local function gate(d)
        if parent and parent(d) then return true end
        return test(d) and true or false
    end
    UFO.gateReasons[gate] = function(d)
        if parent and parent(d) then
            local r = UFO.gateReasons[parent]
            return r and r(d) or nil
        end
        if not test(d) then return nil end
        if verb == "off" then return format(L["Turn off %s to change this"], label) end
        return format(L["Turn on %s to change this"], label)
    end
    return gate
end

-- A gate whose reason is not a switch: `reason(d)` says why.
function UFO.Explain(test, reason)
    local function gate(d) return test(d) and true or false end
    UFO.gateReasons[gate] = function(d) return gate(d) and reason(d) or nil end
    return gate
end

function UFO.ApplyDisableReasons(list)
    for _, w in ipairs(list or {}) do
        if type(w) == "table" then
            local on = rawget(w, "disableOn")
            local why = on and UFO.gateReasons[on]
            if why and rawget(w, "disableReason") == nil then w.disableReason = why end
            local kids = rawget(w, "groupChildren")
            if type(kids) == "table" then
                local ws = {}
                for i, e in ipairs(kids) do ws[i] = e.widget end
                UFO.ApplyDisableReasons(ws)
            end
        end
    end
end

-- ---- small card pages of this module's own ---------------------------------
-- Open(label, key, col, summary, kind[, toggle[, dimFn[, hideFn]]]):
--   toggle  the card's header tick ({ db, key, label, onChanged }, see
--           CreateCollapsibleSection opts.toggle); its body never repeats it
--   dimFn   greys the card's header (its feature is off)
local function Tools(self, Add)
    local tools = GUI:CreatePopoutPageTools(self)
    local function Open(label, key, col, summary, kind, toggle, dimFn, hideFn)
        return tools.OpenSection(Add, label, key, col, summary, dimFn, hideFn, nil, toggle,
            { twoTrack = true, quietLabels = true, kind = kind })
    end
    local function Close(band) tools.CloseSection(Add, band) end
    return Open, Close
end

local function RefreshFrames()
    local UF = DF.UnitFrames
    if UF and UF.RequestRefresh then UF:RequestRefresh() end
end

-- ---- cards of ours on a DandersFrames page ----------------------------------
-- A party builder draws the page. Where it leaves a door (page.dfExtraCards, read
-- with rawget, so a party / raid build never finds one) it calls ours with its OWN
-- OpenSection / CloseSection: the card shares the page's popout tools (a second
-- GUI:CreatePopoutPageTools would retire the first one's holders -- see NO CARD OF
-- OUR OWN below). The page's generated `cards` list still decides which units see
-- it (sectionFilter); Tools/uf_pages_lua.py HOOKED_CARDS names each card's key.
--   ctx = { OpenSection, CloseSection, db, offRow (the page gate), col }
function UFO.ExtraCards(page, rec, unit)
    local function changed() page:RefreshStates(); RefreshFrames() end
    local cards = {}
    if rec.kind == "resource" then
        cards.resource_detached = function(ctx) UFO.BuildResourceDetachedCard(page, ctx, changed) end
    elseif rec.kind == "buffs" then
        cards.buffs_purgeable = function(ctx) UFO.BuildPurgeableCard(page, ctx) end
    end
    return cards
end

-- Purgeable (the Buff Bar's Effects): an enemy's buffs the player can purge or
-- steal lead the row, ringed (Features/Auras.lua SplitBuffRowForPurge). The ring
-- is a DF.Border on the `buffPurgeable` keys, so it takes the shared border
-- controls; the switch is the header tick. Greys with Show Buffs.
function UFO.BuildPurgeableCard(page, ctx)
    local db = ctx.db
    local function changed()
        page:RefreshStates()
        -- The split is part of the row's structure: the aura layout moves on.
        if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
        RefreshFrames()
    end
    local band = ctx.OpenSection(L["Purgeable"], "buffs_purgeable", ctx.col or 1, function(d)
        if not (d and d.buffPurgeableEnabled) then return "" end
        return L["Border"]
    end, ctx.offRow, nil, nil, {
        db = db, key = "buffPurgeableEnabled", label = L["Enable"],
        disableOn = ctx.offRow, onChanged = changed,
    })
    local off = UFO.Gate(L["Purgeable"], function(d) return not (d and d.buffPurgeableEnabled) end,
        UFO.Gate(L["Show Buffs"], function(d) return ctx.offRow(d) end))
    local w = band:AddWidget(GUI:CreateLabel(page.child,
        L["Rings the buffs you can purge or steal from an enemy and shows them first."], 250), 44)
    w.disableOn = off
    GUI:CreateBorderControls(band, db, "buffPurgeable", {
        parent = page.child,
        noShowToggle = true,
        include = { inset = true },
        fullUpdate = changed,
        refreshStates = function() page:RefreshStates() end,
        disableWhen = off,
    })
    ctx.CloseSection(band)
end

-- Detach (the Resource Bar page): the bar's own size, outside the frame at a
-- point of its edge (Frames/Bars.lua, DETACHED RESOURCE BAR). Greys with the page
-- gate (Enable Resource Bar) and, inside, with its own header tick.
function UFO.BuildResourceDetachedCard(page, ctx, changed)
    local db = ctx.db
    local pageOff = UFO.Gate(L["Enable Resource Bar"], function(d) return ctx.offRow(d) end)
    local off = UFO.Gate(L["Detach"], function(d) return not (d and d.resourceBarDetached) end, pageOff)
    local band = ctx.OpenSection(L["Detach"], "resource_detached", ctx.col or 1, function(d)
        if not (d and d.resourceBarDetached) then return L["Off"] end
        return UFO.PointOptions()[d.resourceBarDetachedAnchor or "BOTTOM"] or ""
    end, ctx.offRow, nil, nil, {
        db = db, key = "resourceBarDetached", label = L["Detach"],
        disableOn = ctx.offRow, onChanged = changed,
    })
    local w = band:AddWidget(GUI:CreateCheckbox(page.child, L["Match Frame Width"], db,
        "resourceBarDetachedMatchWidth", changed), 30)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateSlider(page.child, L["Width"], 10, 600, 1, db, "resourceBarDetachedWidth", changed), 55)
    w.disableOn = UFO.Gate(L["Match Frame Width"], function(d) return d and d.resourceBarDetachedMatchWidth ~= false end,
        off, "off")
    w = band:AddWidget(GUI:CreateSlider(page.child, L["Height"], 1, 40, 1, db, "resourceBarDetachedHeight", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateDropdown(page.child, L["Anchor"], UFO.PointOptions(), db, "resourceBarDetachedAnchor", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateSlider(page.child, L["Offset X"], -200, 200, 1, db, "resourceBarDetachedX", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateSlider(page.child, L["Offset Y"], -200, 200, 1, db, "resourceBarDetachedY", changed), 55)
    w.disableOn = off
    ctx.CloseSection(band)
end

-- ---- Text Designer / Aura Designer (spec 2026-11-01-uf-per-unit-designers.md) ---
-- Each unit names its own template of each designer (textDesignerPreset /
-- auraDesignerPreset in its own table: Copy, Reset and Links cover them like any
-- key of the page). Phase 2: the designer itself sits on the unit's page and edits
-- the template the unit draws -- DandersFrames' own designer island, given the
-- unit as its EDIT TARGET (DF.BuildTextDesignerPage / DF.BuildAuraDesignerPage
-- opts.target): its template bar points the UNIT at a template, its preview takes
-- the unit's frame size, and the Aura Designer's enable is the unit's own.
-- The Aura Designer's unset value follows the Party frames' current template
-- (UF:AuraTemplateFor); the bar shows it as Same as Party Frames.
UFO.FOLLOW_PARTY = "@party"

-- After a template change: the aura layout version moves (the factory re-syncs
-- every frame against its template), then the frames re-stamp and repaint.
local function DesignerChanged(kind)
    if kind == "aura" and DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
    RefreshFrames()
end

function UFO.GetTemplate(db, kind)
    if kind == "aura" then return (db and db.auraDesignerPreset) or UFO.FOLLOW_PARTY end
    return db and db.textDesignerPreset
end

function UFO.SetTemplate(db, kind, name)
    if not db then return end
    if kind == "aura" then
        db.auraDesignerPreset = (name ~= UFO.FOLLOW_PARTY) and name or nil
    else
        db.textDesignerPreset = name
    end
end

-- Make Own Template: the unit's copy of its current template, picked at once.
function UFO.MakeOwnTemplate(unit, kind)
    local UF = DF.UnitFrames
    return UF and UF.MakeOwnTemplate and UF:MakeOwnTemplate(unit, kind) or nil
end

-- What the designer edits on a unit's page. `kind` is "text" or "aura".
--   * the template: the one the unit draws (UF:UnitTemplate -- for Aura, Party's
--     while it follows Party)
--   * the template bar: picks the UNIT's template; Aura lists Same as Party Frames
--     first; Make Own Template after the library; the sharing glyph names everyone
--     else drawing with it, the unit itself left out
--   * a change: the unit's link partner follows, the frames re-stamp and repaint.
--     It never refreshes the page itself -- the designer rebuilds its own island,
--     and a page rebuild underneath it would hand that rebuild a retired frame.
function UFO.DesignerTarget(unit, kind)
    local UF = DF.UnitFrames
    local db = UF and UF:GetUnitDB(unit)
    local function live() return UF and UF:GetUnitDB(unit) end
    local function name() return UF and UF:UnitTemplate(unit, kind) or nil end
    local bar = {
        registryKey = "unit:" .. tostring(unit) .. ":" .. kind,
        getRef = name,
        setRef = function(n) UFO.SetTemplate(live(), kind, n) end,
        tailItems = {
            { label = L["Make Own Template"], onClick = function() UFO.MakeOwnTemplate(unit, kind) end },
        },
        listUsers = function(n)
            local all = (DF.ListDesignerPresetUsers and DF:ListDesignerPresetUsers(kind, n)) or {}
            local me = UF and UF.CarrierLabel and UF:CarrierLabel(unit)
            local out = {}
            for _, label in ipairs(all) do
                if label ~= me then out[#out + 1] = label end
            end
            return out
        end,
    }
    if kind == "aura" then
        bar.getLabel = function()
            if UFO.GetTemplate(live(), "aura") == UFO.FOLLOW_PARTY then return L["Same as Party Frames"] end
            return nil
        end
        bar.leadItems = {
            { label = L["Same as Party Frames"], onClick = function() UFO.SetTemplate(live(), "aura", UFO.FOLLOW_PARTY) end },
        }
    end
    local target = {
        getName = name,
        db = db,
        sizeDB = db,
        bar = bar,
        onChange = function()
            if kind == "text" then UFO.ApplyTemplateRequests(unit) end
            UFO.PushLinks(unit)
            DesignerChanged(kind)
            UFO.RefreshLinkMarks()
        end,
    }
    if kind == "text" then UFO.AddTextPreviewFrame(target, unit) end
    return target
end

-- A Text Designer template may ask something of the unit that picks it: today
-- only dimPortraitOnHover ("Ring: Centre on Hover", DandersFrames_UnitFrames/Core.lua
-- RING PRESETS), which turns the unit's Dim on Hover on so its hover text reads
-- over the portrait. Only ever turned ON, never off.
function UFO.ApplyTemplateRequests(unit)
    local UF = DF.UnitFrames
    local db = UF and UF:GetUnitDB(unit)
    local lib = DF.GetTextDesignerPresets and DF:GetTextDesignerPresets()
    local name = db and db.textDesignerPreset
    local cfg = lib and name and lib[name]
    if type(cfg) == "table" and cfg.dimPortraitOnHover and not db.portraitDimHover then
        db.portraitDimHover = true
    end
end

-- The Text Designer's preview on a unit page is the unit's OWN frame, built and
-- painted by the unit frames' preview code exactly as test mode draws it
-- (DandersFrames_UnitFrames/Preview.lua P:BuildSample): rings, the round
-- portrait, a detached resource bar, auras -- the real look, not the party mock.
-- One per unit page, made on first need and handed back to every rebuild of the
-- designer's island. Its size is the frame view's (a Ring frame's ringSize).
function UFO.AddTextPreviewFrame(target, unit)
    local UF = DF.UnitFrames
    local P = UF and UF.Preview
    if not (P and P.BuildSample) then return end
    local sample
    -- The ring spots in its Anchor To lists, markers for them on the preview, and a
    -- Show Hover State switch (TextDesigner/UI/Options.lua).
    target.ringAnchors = true
    target.getSizeDB = function() return UF.FrameDB and UF:FrameDB(unit) or UF:GetUnitDB(unit) end
    target.previewFrame = function(parent)
        if not sample then sample = P:BuildSample(unit, parent) end
        return sample
    end
    target.refreshPreviewFrame = function(f)
        if f and P.PaintSample then P:PaintSample(f) end
    end
end

-- The designer's lowest height on a unit page; a taller window gives it the rest.
UFO.DESIGNER_MIN_H = 420

-- The designer in a full-width slot under the page's head (layoutFill: it takes
-- the viewport's height below the head, and the page itself does not scroll).
-- ☠ BUILT ON FIRST SHOW, NEVER BY THE PAGE BUILDER. Unit pages are built
-- headlessly for the search index, and the Aura Designer's island is ONE frame:
-- building it there would take it off the designer page that has it. Each show
-- after the first runs the island's own RefreshStates, which takes the island
-- back from another page and re-binds the Text Designer's preview.
function UFO.AddDesignerSlot(self, db, Add, unit, kind)
    local slot = CreateFrame("Frame", nil, self.child)
    slot.child = CreateFrame("Frame", nil, slot)
    slot.child:SetAllPoints()
    slot.layoutFill = true
    slot.dfDesignerSlot = kind
    local built = false
    local function Show()
        if not slot:IsVisible() then return end
        if built then
            if slot.RefreshStates then slot:RefreshStates() end
            return
        end
        built = true
        local opts = { target = UFO.DesignerTarget(unit, kind) }
        if kind == "aura" then
            if DF.BuildAuraDesignerPage then DF.BuildAuraDesignerPage(GUI, slot, db, nil, nil, opts) end
        elseif DF.BuildTextDesignerPage then
            DF.BuildTextDesignerPage(GUI, slot, db, nil, nil, opts)
        end
    end
    slot:SetScript("OnShow", Show)
    slot:SetScript("OnSizeChanged", function()
        if built and slot.RefreshStates and slot:IsVisible() then slot:RefreshStates() end
    end)
    slot.dfShowDesigner = Show
    Add(slot, UFO.DESIGNER_MIN_H, "both")
    if C_Timer and C_Timer.After then C_Timer.After(0, Show) end
    return slot
end

function UFO.BuildTextPage(self, db, Add, rec, unit)
    UFO.AddPageHead(self, rec, unit, Add)
    UFO.AddDesignerSlot(self, db, Add, unit, "text")
end

-- Its own enable (DF:IsAuraDesignerEnabled: a standalone frame answers from its
-- own table, before the template stamp) -- the designer's Enable box edits it.
function UFO.BuildAuraDesignerPage(self, db, Add, rec, unit)
    UFO.AddPageHead(self, rec, unit, Add)
    UFO.AddDesignerSlot(self, db, Add, unit, "aura")
end

-- The designers want the width their own pages force (GUI/Panel.lua WIDE_PAGES).
function UFO.DesignerPageMinWidth()
    return 850 + (GUI.RailWidth or 0)
end

-- ---- Visibility (a page new to unit frames) ---------------------------------
-- When the frame shows, as a secure state driver (DandersFrames_UnitFrames/Units.lua
-- Units:VisibilityMacro). Two inventory controls are not drawn: Health Below Full
-- (health is secret in combat, so no secure condition can test it) and In Player
-- Housing (no macro condition answers it).
UFO.VIS_SHOW = {
    { key = "visCombat",         label = function() return L["In Combat"] end },
    { key = "visNoCombat",       label = function() return L["Out of Combat"] end },
    { key = "visGroup",          label = function() return L["In a Group"] end },
    { key = "visSolo",           label = function() return L["Solo"] end },
    { key = "visInstance",       label = function() return L["In an Instance"] end },
    { key = "visHasTarget",      label = function() return L["Have a Target"] end },
    { key = "visHasEnemyTarget", label = function() return L["Have a Hostile Target"] end },
}
UFO.VIS_HIDE = {
    { key = "visHidePetBattle", label = function() return L["In a Pet Battle"] end },
    { key = "visHideVehicle",   label = function() return L["In a Vehicle"] end },
    { key = "visHideMounted",   label = function() return L["Mounted"] end },
    { key = "visHideSkyriding", label = function() return L["Skyriding"] end },
}

function UFO.VisControlShown(rec, unit, key)
    local hide = rec and rec.hide and rec.hide[key]
    return not (hide and hide[unit])
end

local function AlwaysOnTest(d) return d and d.visAlways ~= false end

function UFO.BuildVisibilityPage(self, db, Add, rec, unit)
    UFO.AddPageHead(self, rec, unit, Add)
    local Open, Close = Tools(self, Add)
    local function changed() self:RefreshStates(); RefreshFrames() end
    -- The conditions grey while Always is ticked; turning Always OFF frees them.
    local AlwaysOn = UFO.Gate(L["Always"], AlwaysOnTest, nil, "off")

    local band = Open(L["Show When"], "uf_vis_show", 1,
        function(d) return AlwaysOnTest(d) and L["Always"] or L["Custom"] end, "visibility")
    band:AddWidget(GUI:CreateCheckbox(self.child, L["Always"], db, "visAlways", changed), 30)
    for _, c in ipairs(UFO.VIS_SHOW) do
        if UFO.VisControlShown(rec, unit, c.key) then
            local w = GUI:CreateCheckbox(self.child, c.label(), db, c.key, changed)
            w.disableOn = AlwaysOn
            band:AddWidget(w, 30)
        end
    end
    band:AddWidget(GUI:CreateLabel(self.child,
        L["Untick Always to choose conditions. Any ticked condition shows the frame."], 250), 30)
    Close(band)

    band = Open(L["Hide When"], "uf_vis_hide", 1, nil, "visibility")
    for _, c in ipairs(UFO.VIS_HIDE) do
        if UFO.VisControlShown(rec, unit, c.key) then
            band:AddWidget(GUI:CreateCheckbox(self.child, c.label(), db, c.key, changed), 30)
        end
    end
    Close(band)
end

-- ============================================================
-- CAST BAR / CLASS POWER / PORTRAIT / UNIT ICONS (pages new to unit frames)
-- Built from the shared helpers over the companion's runtime
-- (DandersFrames_UnitFrames/CastBar.lua, ClassPower.lua, Portrait.lua,
-- Indicators.lua). A control relevant to some units only reads the page's
-- generated `hide` list (UFO.VisControlShown); a card reaching some units only
-- reads its `cards` list (UFO.CardShown).
--
-- Inventory controls deliberately NOT drawn (their runtime is not built):
--   Cast Bar      Show Kick-Ready Section, Kick Ready colour, Icon Zoom, Max
--                 Length, Spell Target's own font size and separator
--   Class Power   Vengeance Soul Fragments, Maelstrom Weapon Stacks, Show Rune
--                 Cooldown Text, Inside Top, Background
--   Portrait      Push Bars Aside, 2D Zoom
--   Unit Icons    PvP Show / Style / Players Only, Show in Instances
-- ============================================================
function UFO.CardShown(rec, unit, key)
    local c = rec and rec.cards and rec.cards[key]
    if not c then return true end
    return c[unit] and true or false
end

local function PointOptions()
    return { TOPLEFT = L["Top Left"], TOP = L["Top"], TOPRIGHT = L["Top Right"],
             LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"],
             BOTTOMLEFT = L["Bottom Left"], BOTTOM = L["Bottom"], BOTTOMRIGHT = L["Bottom Right"],
             _order = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT",
                        "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" } }
end
UFO.PointOptions = PointOptions

-- Edit a detached piece in the mover (its own element, `<unit>.<kind>`).
function UFO.EditChildInMover(unit, kind)
    local UF = DF.UnitFrames
    local M = UF and UF.Mover
    local key = unit .. "." .. kind
    if M and M.lib and M.children and M.children[key] then
        M.lib:Unlock({ addon = M.ADDON_KEY, keys = { key } })
        return true
    end
    if DF.Say then DF:Say(L["DandersMover is disabled"]) end
    return false
end

-- Follow the Frame (a detached piece anchored to its frame, or free where it
-- stands): DandersMover's SetAnchor / Detach through the companion.
function UFO.ChildFollowing(unit, kind)
    local M = DF.UnitFrames and DF.UnitFrames.Mover
    return M and M.IsChildFollowing and M:IsChildFollowing(unit, kind) or false
end

function UFO.SetChildFollowing(unit, kind, v)
    local M = DF.UnitFrames and DF.UnitFrames.Mover
    if M and M.SetChildFollowing then return M:SetChildFollowing(unit, kind, v) end
    return false
end

-- A border card's two controls (the piece's own keys, prefix .. "Border*");
-- the card's header tick is the third.
local function BorderControls(self, band, db, prefix, changed, featureOff)
    local off = UFO.Gate(L["Show Border"], function(d) return d and d[prefix .. "BorderEnabled"] == false end, featureOff)
    local w = band:AddWidget(GUI:CreateSlider(self.child, L["Border Thickness"], 1, 8, 1, db, prefix .. "BorderSize", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateColorPicker(self.child, L["Border Color"], db, prefix .. "BorderColor", true, changed), 30)
    w.disableOn = off
end

local function BorderToggle(db, prefix, changed)
    return { db = db, key = prefix .. "BorderEnabled", label = L["Show Border"], onChanged = changed }
end

local function OnOff(d, key) return (d and d[key]) and L["On"] or L["Off"] end

-- The Position card's detached half, shared by Cast Bar and Class Power.
local function DetachedControls(self, band, unit, kind, changed, off, attached)
    local w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Follow the Frame"], nil, nil, nil,
        function() return UFO.ChildFollowing(unit, kind) end,
        function(v) UFO.SetChildFollowing(unit, kind, v); changed() end), 30)
    w.disableOn, w.hideOn = off, attached
    w = band:AddWidget(GUI:CreateButtonRow(self.child, {
        { label = L["Edit in Mover"], width = 120, icon = "open_with",
          onClick = function() UFO.EditChildInMover(unit, kind) end },
    }, { width = 250 }), 30)
    w.disableOn, w.hideOn = off, attached
end

function UFO.BuildCastBarPage(self, db, Add, rec, unit)
    UFO.AddPageHead(self, rec, unit, Add)
    local Open, Close = Tools(self, Add)
    local function changed() self:RefreshStates(); RefreshFrames() end
    local function shown(key) return UFO.VisControlShown(rec, unit, key) end
    local off = UFO.Gate(L["Cast Bar"], function(d) return not (d and d.castbarEnabled) end)
    local function detached(d) return d and d.castbarDetached end
    local function attached(d) return not detached(d) end
    local w

    local band = Open(L["Settings"], "uf_cb_settings", 1, function(d) return OnOff(d, "castbarEnabled") end,
        "settings", { db = db, key = "castbarEnabled", label = L["Enable Cast Bar"], onChanged = changed })
    for _, c in ipairs({
        { "castbarHideIdle", L["Hide When Not Casting"] },
        { "castbarLatency", L["Show Latency"] },
        { "castbarEmpower", L["Show Empower Stages"] },
        { "castbarKickTick", L["Show Kick-Ready Mark"] },
        { "castbarPriorityHighlight", L["Glow Important Spells"] },
    }) do
        if shown(c[1]) then
            w = band:AddWidget(GUI:CreateCheckbox(self.child, c[2], db, c[1], changed), 30)
            w.disableOn = off
        end
    end
    Close(band)

    band = Open(L["Size"], "uf_cb_size", 1, function(d)
        local wtxt = (d and d.castbarMatchWidth ~= false) and L["Frame"] or tostring(d and d.castbarWidth or "")
        return format("%s x %s", wtxt, tostring(d and d.castbarHeight or ""))
    end, "size")
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Match Frame Width"], db, "castbarMatchWidth", changed), 30)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Width"], 40, 600, 1, db, "castbarWidth", changed), 55)
    w.disableOn = off
    w.hideOn = function(d) return d and d.castbarMatchWidth ~= false end
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Height"], 6, 60, 1, db, "castbarHeight", changed), 55)
    w.disableOn = off
    Close(band)

    band = Open(L["Position"], "uf_cb_position", 1,
        function(d) return detached(d) and L["Detached"] or L["Attached"] end, "position")
    -- Not on Boss: five boss cast bars share one record (CastBar.lua IsDetached).
    if shown("castbarDetached") then
        w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Detach"], db, "castbarDetached", changed), 30)
        w.disableOn = off
    end
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"],
        { BOTTOM = L["Bottom"], TOP = L["Top"], _order = { "BOTTOM", "TOP" } }, db, "castbarSide", changed), 55)
    w.disableOn, w.hideOn = off, detached
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Gap"], 0, 30, 1, db, "castbarGap", changed), 55)
    w.disableOn, w.hideOn = off, detached
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "castbarX", changed), 55)
    w.disableOn, w.hideOn = off, detached
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "castbarY", changed), 55)
    w.disableOn, w.hideOn = off, detached
    DetachedControls(self, band, unit, "castbar", changed, off, attached)
    Close(band)

    band = Open(L["Bar Style"], "uf_cb_style", 2, nil, "appearance")
    w = band:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "castbarTexture", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateTextureDropdown(self.child, L["Background Texture"], db, "castbarBgTexture", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateColorPicker(self.child, L["Background Color"], db, "castbarBgColor", true, changed), 30)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Reverse Fill"], db, "castbarReverse", changed), 30)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Show Spark"], db, "castbarSpark", changed), 30)
    w.disableOn = off
    Close(band)

    band = Open(L["Colors"], "uf_cb_colors", 2, nil, "colours")
    for _, c in ipairs({
        { "castbarColor", L["Interruptible"] },
        { "castbarNonInterruptibleColor", L["Not Interruptible"] },
        { "castbarChannelColor", L["Channel"] },
        { "castbarFailedColor", L["Interrupted / Failed"] },
        { "castbarKickNotReadyColor", L["Kick Not Ready"] },
        { "castbarPriorityHighlightColor", L["Important Glow"] },
    }) do
        if shown(c[1]) then
            w = band:AddWidget(GUI:CreateColorPicker(self.child, c[2], db, c[1], false, changed), 30)
            w.disableOn = off
        end
    end
    if shown("castbarClassColor") then
        w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Use Class Color"], db, "castbarClassColor", changed), 30)
        w.disableOn = off
    end
    Close(band)

    band = Open(L["Icon"], "uf_cb_icon", 2, nil, "appearance",
        { db = db, key = "castbarShowIcon", label = L["Show Icon"], onChanged = changed })
    local iconOff = UFO.Gate(L["Show Icon"], function(d) return d and d.castbarShowIcon == false end, off)
    if shown("castbarIconSide") then
        w = band:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"],
            { LEFT = L["Left"], RIGHT = L["Right"], _order = { "LEFT", "RIGHT" } }, db, "castbarIconSide", changed), 55)
        w.disableOn = iconOff
    end
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Size (0 = bar height)"], 0, 60, 1, db, "castbarIconSize", changed), 55)
    w.disableOn = iconOff
    Close(band)

    band = Open(L["Border"], "uf_cb_border", 2, nil, "border", BorderToggle(db, "castbar", changed))
    BorderControls(self, band, db, "castbar", changed, off)
    Close(band)

    band = Open(L["Spell Name"], "uf_cb_spell", 1, nil, "text",
        { db = db, key = "castbarShowSpell", label = L["Show Spell Name"], onChanged = changed })
    local spellOff = UFO.Gate(L["Show Spell Name"], function(d) return d and d.castbarShowSpell == false end, off)
    w = band:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "castbarSpellFont", changed), 55)
    w.disableOn = spellOff
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 32, 1, db, "castbarSpellFontSize", changed), 55)
    w.disableOn = spellOff
    w = band:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "castbarSpellOutline", changed), 55)
    w.disableOn = spellOff
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], PointOptions(), db, "castbarSpellAnchor", changed), 55)
    w.disableOn = spellOff
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "castbarSpellX", changed), 55)
    w.disableOn = spellOff
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "castbarSpellY", changed), 55)
    w.disableOn = spellOff
    w = band:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "castbarSpellColor", false, changed), 30)
    w.disableOn = spellOff
    if UFO.CardShown(rec, unit, "spell_target") then
        w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Show Spell Target"], db, "castbarShowTarget", changed), 30)
        w.disableOn = spellOff
    end
    Close(band)

    band = Open(L["Timer"], "uf_cb_timer", 1, nil, "timer",
        { db = db, key = "castbarShowTimer", label = L["Show Timer"], onChanged = changed })
    local timerOff = UFO.Gate(L["Show Timer"], function(d) return d and d.castbarShowTimer == false end, off)
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Format"], {
        REMAINING = L["Remaining"], REMAINING_TOTAL = L["Remaining / Total"], ELAPSED = L["Elapsed"],
        _order = { "REMAINING", "REMAINING_TOTAL", "ELAPSED" } }, db, "castbarTimerFormat", changed), 55)
    w.disableOn = timerOff
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Decimals"], 0, 2, 1, db, "castbarTimerDecimals", changed), 55)
    w.disableOn = timerOff
    w = band:AddWidget(GUI:CreateFontDropdown(self.child, L["Font"], db, "castbarTimerFont", changed), 55)
    w.disableOn = timerOff
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Font Size"], 6, 32, 1, db, "castbarTimerFontSize", changed), 55)
    w.disableOn = timerOff
    w = band:AddWidget(GUI:CreateOutlineDropdown(self.child, L["Outline"], db, "castbarTimerOutline", changed), 55)
    w.disableOn = timerOff
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], PointOptions(), db, "castbarTimerAnchor", changed), 55)
    w.disableOn = timerOff
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "castbarTimerX", changed), 55)
    w.disableOn = timerOff
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "castbarTimerY", changed), 55)
    w.disableOn = timerOff
    w = band:AddWidget(GUI:CreateColorPicker(self.child, L["Color"], db, "castbarTimerColor", false, changed), 30)
    w.disableOn = timerOff
    Close(band)
end

function UFO.BuildClassPowerPage(self, db, Add, rec, unit)
    UFO.AddPageHead(self, rec, unit, Add)
    local Open, Close = Tools(self, Add)
    local function changed() self:RefreshStates(); RefreshFrames() end
    local off = UFO.Gate(L["Class Power"], function(d) return not (d and d.classPowerEnabled) end)
    local function detached(d) return d and d.classPowerDetached end
    local function attached(d) return not detached(d) end
    local w

    local band = Open(L["Settings"], "uf_cp_settings", 1, function(d) return OnOff(d, "classPowerEnabled") end,
        "settings", { db = db, key = "classPowerEnabled", label = L["Enable Class Power"], onChanged = changed })
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Display Mode"],
        { PIPS = L["Pips"], BAR = L["Single Bar"], _order = { "PIPS", "BAR" } }, db, "classPowerMode", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Hide When Empty"], db, "classPowerHideEmpty", changed), 30)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Out of Combat"], db, "classPowerHideOOC", changed), 30)
    w.disableOn = off
    Close(band)

    band = Open(L["Class Options"], "uf_cp_class", 1, nil, "settings")
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Death Knight Runes"], db, "classPowerRunes", changed), 30)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Brewmaster Stagger"], db, "classPowerStagger", changed), 30)
    w.disableOn = off
    Close(band)

    band = Open(L["Size"], "uf_cp_size", 1, nil, "size")
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Match Frame Width"], db, "classPowerMatchWidth", changed), 30)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Width"], 40, 600, 1, db, "classPowerWidth", changed), 55)
    w.disableOn = off
    w.hideOn = function(d) return d and d.classPowerMatchWidth ~= false end
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Height"], 2, 30, 1, db, "classPowerHeight", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Pip Gap"], 0, 10, 1, db, "classPowerGap", changed), 55)
    w.disableOn = off
    Close(band)

    band = Open(L["Position"], "uf_cp_position", 1,
        function(d) return detached(d) and L["Detached"] or L["Attached"] end, "position")
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Detach"], db, "classPowerDetached", changed), 30)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"],
        { TOP = L["Top"], BOTTOM = L["Bottom"], _order = { "TOP", "BOTTOM" } }, db, "classPowerPosition", changed), 55)
    w.disableOn, w.hideOn = off, detached
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "classPowerX", changed), 55)
    w.disableOn, w.hideOn = off, detached
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "classPowerY", changed), 55)
    w.disableOn, w.hideOn = off, detached
    DetachedControls(self, band, unit, "classpower", changed, off, attached)
    Close(band)

    band = Open(L["Bar Style"], "uf_cp_style", 2, nil, "appearance")
    w = band:AddWidget(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "classPowerTexture", changed), 55)
    w.disableOn = off
    Close(band)

    band = Open(L["Colors"], "uf_cp_colors", 2, nil, "colours")
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Color Mode"],
        { CLASS = L["Class"], POWER = L["Power Type"], CUSTOM = L["Custom"], _order = { "CLASS", "POWER", "CUSTOM" } },
        db, "classPowerColorMode", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateColorPicker(self.child, L["Custom Color"], db, "classPowerColor", false, changed), 30)
    w.disableOn = off
    w.hideOn = function(d) return not (d and d.classPowerColorMode == "CUSTOM") end
    w = band:AddWidget(GUI:CreateColorPicker(self.child, L["Empty Pip"], db, "classPowerEmptyColor", true, changed), 30)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateColorPicker(self.child, L["Charged Pip"], db, "classPowerChargedColor", false, changed), 30)
    w.disableOn = off
    Close(band)

    band = Open(L["Border"], "uf_cp_border", 2, nil, "border", BorderToggle(db, "classPower", changed))
    BorderControls(self, band, db, "classPower", changed, off)
    Close(band)
end

-- Portrait.lua SHAPES: the stored value is the key, never the label.
function UFO.PortraitShapes()
    return { SQUARE = L["Square"], CIRCLE = L["Circle"], ROUNDED = L["Rounded Corners"],
             _order = { "SQUARE", "CIRCLE", "ROUNDED" } }
end

function UFO.PortraitModes()
    return { ["3D"] = L["3D Model"], ["2D"] = L["2D Portrait"], CLASS = L["Class Icon"], SPEC = L["Spec Icon"],
             _order = { "3D", "2D", "CLASS", "SPEC" } }
end

function UFO.BuildPortraitPage(self, db, Add, rec, unit)
    UFO.AddPageHead(self, rec, unit, Add)
    local Open, Close = Tools(self, Add)
    local function changed() self:RefreshStates(); RefreshFrames() end
    local function shown(key) return UFO.VisControlShown(rec, unit, key) end
    local off = UFO.Gate(L["Portrait"], function(d) return not (d and d.portraitEnabled) end)
    local w

    local band = Open(L["Settings"], "uf_po_settings", 1, function(d)
        if not (d and d.portraitEnabled) then return L["Off"] end
        return UFO.PortraitModes()[d.portraitMode or "3D"] or ""
    end, "settings", { db = db, key = "portraitEnabled", label = L["Show Portrait"], onChanged = changed })
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Style"], UFO.PortraitModes(), db, "portraitMode", changed), 55)
    w.disableOn = off
    if shown("portraitNpcMode") then
        w = band:AddWidget(GUI:CreateDropdown(self.child, L["For NPCs Use"],
            { ["3D"] = L["3D Model"], ["2D"] = L["2D Portrait"], _order = { "3D", "2D" } }, db, "portraitNpcMode", changed), 55)
        w.disableOn = off
        w.hideOn = function(d) return not (d and (d.portraitMode == "CLASS" or d.portraitMode == "SPEC")) end
    end
    if shown("portraitDesatDead") then
        w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Desaturate When Dead"], db, "portraitDesatDead", changed), 30)
        w.disableOn = off
    end
    Close(band)

    band = Open(L["Size & Position"], "uf_po_position", 1, nil, "position")
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], {
        LEFT = L["Left"], RIGHT = L["Right"], INSIDE_LEFT = L["Inside Left"], INSIDE_RIGHT = L["Inside Right"],
        _order = { "LEFT", "RIGHT", "INSIDE_LEFT", "INSIDE_RIGHT" } }, db, "portraitSide", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Size (0 = frame height)"], -60, 100, 1, db, "portraitSize", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, "portraitX", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, "portraitY", changed), 55)
    w.disableOn = off
    Close(band)

    band = Open(L["Look"], "uf_po_look", 2, nil, "appearance")
    local function not3D(d) return not (d and (d.portraitMode or "3D") == "3D") end
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Shape"], UFO.PortraitShapes(), db, "portraitShape", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Alpha"], 0, 1, 0.05, db, "portraitAlpha", changed), 55)
    w.disableOn = off
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Dim on Hover"], db, "portraitDimHover", changed), 30)
    w.disableOn = off
    w.tooltip = L["Fade the portrait while the mouse is over the frame, so text shown on hover reads over it."]
    w = band:AddWidget(GUI:CreateSlider(self.child, L["3D Zoom"], 0.5, 1.5, 0.05, db, "portrait3DZoom", changed), 55)
    w.disableOn, w.hideOn = off, not3D
    w = band:AddWidget(GUI:CreateSlider(self.child, L["3D Rotation"], -180, 180, 1, db, "portrait3DRotation", changed), 55)
    w.disableOn, w.hideOn = off, not3D
    w = band:AddWidget(GUI:CreateColorPicker(self.child, L["Background Color"], db, "portraitBgColor", true, changed), 30)
    w.disableOn = off
    if shown("portraitMirror") then
        w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Mirror"], db, "portraitMirror", changed), 30)
        w.disableOn = off
    end
    Close(band)

    band = Open(L["Border"], "uf_po_border", 2, nil, "border", BorderToggle(db, "portrait", changed))
    BorderControls(self, band, db, "portrait", changed, off)
    Close(band)
end

-- ============================================================
-- FRAME STYLE (DandersFrames_UnitFrames/Rings.lua)
-- Style: Bars or Ring, and the ring's size. Rings: the ring list, innermost
-- first -- one block per ring (move in / out, remove, thickness, gap) with its
-- sections editable in place (bar, coverage, position, reverse, feather; add /
-- remove). Built from the kit's row list (DandersUI RowList), which gained button
-- rows for this. Everything greys unless Frame Style is Ring.
-- The ring list is ONE value (`rings`, a table copied into the unit's own table
-- on first read): edited in place, then the unit's link is pushed (an in-place
-- edit no write hook sees) and the frames repaint. A change to the list's shape
-- rebuilds the rows; a slider or switch only repaints.
-- ============================================================
function UFO.FrameStyleOptions()
    return { BARS = L["Bars"], RING = L["Ring"], _order = { "BARS", "RING" } }
end

function UFO.RingPortrait3DOptions()
    return { FIT = L["Fit Inside"], COVER = L["Fill and Cover Corners"], ["2D"] = L["2D Portrait"],
             _order = { "FIT", "COVER", "2D" } }
end

function UFO.RingBarOptions()
    return { HEALTH = L["Health"], POWER = L["Power"], CLASSPOWER = L["Class Power"],
             _order = { "HEALTH", "POWER", "CLASSPOWER" } }
end

function UFO.RingCoverageOptions()
    return { FULL = L["Full"], HALF = L["Half"], QUARTER = L["Quarter"], _order = { "FULL", "HALF", "QUARTER" } }
end

-- A half sits on a side; a quarter also on a corner.
function UFO.RingPositionOptions(coverage)
    local o = { TOP = L["Top"], BOTTOM = L["Bottom"], LEFT = L["Left"], RIGHT = L["Right"],
                _order = { "TOP", "BOTTOM", "LEFT", "RIGHT" } }
    if coverage == "QUARTER" then
        o.TOPLEFT, o.TOPRIGHT, o.BOTTOMLEFT, o.BOTTOMRIGHT = L["Top Left"], L["Top Right"], L["Bottom Left"], L["Bottom Right"]
        o._order = { "TOP", "BOTTOM", "LEFT", "RIGHT", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }
    end
    return o
end

-- The unit's ring list, as stored (the read copies the default in on first use).
function UFO.RingList(db)
    local t = db and db.rings
    if type(t) ~= "table" then
        t = {}
        if db then db.rings = t end
    end
    return t
end

UFO.RING_MAX = 4
UFO.RING_SECTION_MAX = 4

-- Pure list edits (tested): each returns true when it changed the list.
function UFO.RingMove(list, i, dir)
    local j = i + dir
    if not (list[i] and list[j]) then return false end
    list[i], list[j] = list[j], list[i]
    return true
end

function UFO.RingAdd(list)
    if #list >= UFO.RING_MAX then return false end
    list[#list + 1] = { thickness = 4, gap = 2, sections = { { bar = "POWER", coverage = "FULL", position = "TOP" } } }
    return true
end

function UFO.RingRemove(list, i)
    if #list <= 1 or not list[i] then return false end
    table.remove(list, i)
    return true
end

function UFO.RingSectionAdd(ring)
    if type(ring.sections) ~= "table" then ring.sections = {} end
    if #ring.sections >= UFO.RING_SECTION_MAX then return false end
    ring.sections[#ring.sections + 1] = { bar = "HEALTH", coverage = "HALF", position = "LEFT" }
    return true
end

function UFO.RingSectionRemove(ring, j)
    if type(ring.sections) ~= "table" or not ring.sections[j] then return false end
    table.remove(ring.sections, j)
    return true
end

function UFO.BuildRingsPage(self, db, Add, rec, unit)
    UFO.AddPageHead(self, rec, unit, Add)
    local Open, Close = Tools(self, Add)
    local function isRing(d) return d and d.frameStyle == "RING" end
    local off = UFO.Explain(function(d) return not isRing(d) end,
        function() return L["Set Frame Style to Ring to change this."] end)
    local list
    local function changed()
        self:RefreshStates()
        UFO.PushLinks(unit)
        RefreshFrames()
        if list then list:Refresh() end
    end
    local w

    local band = Open(L["Style"], "uf_rings_style", 1, function(d)
        return UFO.FrameStyleOptions()[(d and d.frameStyle) or "BARS"] or ""
    end, "framemodes")
    band:AddWidget(GUI:CreateDropdown(self.child, L["Frame Style"], UFO.FrameStyleOptions(), db, "frameStyle", changed), 55)
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Ring Size"], 24, 256, 1, db, "ringSize", changed), 55)
    w.disableOn = off
    -- A 3D portrait in the middle (Portrait.lua RING 3D): only when the portrait is
    -- a 3D model; Fill and Cover Corners needs ring 1 flush against the portrait.
    local function not3D(d)
        return not (d and d.portraitEnabled and (d.portraitMode or "3D") == "3D")
    end
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["3D Portrait"], UFO.RingPortrait3DOptions(), db,
        "ringPortrait3D", changed), 55)
    w.disableOn, w.hideOn = off, not3D
    w.tooltip = L["How a 3D portrait sits in the round middle: fitted inside the circle, filling it with its corners covered, or drawn as the 2D portrait."]
    w = band:AddWidget(GUI:CreateLabel(self.child,
        L["Fill and Cover Corners needs the innermost ring's Gap at 0. Until then the model is fitted inside."], 250), 44)
    w.hideOn = function(d)
        local R = DF.UnitFrames and DF.UnitFrames.Rings
        return not3D(d) or not (d and d.ringPortrait3D == "COVER") or (R and R.CoverAllowed(d))
    end
    band:AddWidget(GUI:CreateLabel(self.child,
        L["Ring draws health and power as rings round a round portrait, and the frame becomes a square of Ring Size. The cast bar stays a bar; absorbs and heal prediction are not drawn on rings."], 250), 70)
    Close(band)

    band = Open(L["Rings"], "uf_rings_list", 2, function(d)
        return format(L["Rings: %d"], #UFO.RingList(d))
    end, "layout")
    local function rowOff()
        if isRing(db) then return false end
        return true, L["Frame Style"], { L["Set Frame Style to Ring to change this."] }
    end
    local Build
    local function wrote(rebuild)
        UFO.PushLinks(unit)
        RefreshFrames()
        self:RefreshStates()
        if rebuild then Build() end
    end
    list = GUI:CreateRowList(self.child, { width = 250, store = function() return {} end })
    Build = function()
        list:Clear()
        local rings = UFO.RingList(db)
        for i, ring in ipairs(rings) do
            if type(ring.sections) ~= "table" then ring.sections = {} end
            list:AddHeading({ label = (i == 1) and format(L["Ring %d (innermost)"], i) or format(L["Ring %d"], i) })
            list:AddButtons({ label = "", disabled = rowOff, buttons = {
                { text = L["Up"], tooltip = L["Move this ring one step in."],
                  disabled = function() return i == 1 end,
                  onClick = function() if UFO.RingMove(rings, i, -1) then wrote(true) end end },
                { text = L["Down"], tooltip = L["Move this ring one step out."],
                  disabled = function() return i == #rings end,
                  onClick = function() if UFO.RingMove(rings, i, 1) then wrote(true) end end },
                { text = L["Remove"], tooltip = L["Remove this ring."],
                  disabled = function() return #rings <= 1 end,
                  onClick = function() if UFO.RingRemove(rings, i) then wrote(true) end end },
            } })
            list:AddSlider({ label = L["Thickness"], min = 1, max = 40, step = 1, disabled = rowOff,
                get = function() return ring.thickness or 6 end,
                set = function(v) ring.thickness = v end, onChanged = function() wrote(false) end })
            list:AddSlider({ label = L["Gap"], min = 0, max = 20, step = 1, disabled = rowOff,
                tooltip = L["Space inside this ring, between it and the ring or portrait within."],
                get = function() return ring.gap or 2 end,
                set = function(v) ring.gap = v end, onChanged = function() wrote(false) end })
            for j, sec in ipairs(ring.sections) do
                list:AddButtons({ label = format(L["Section %d"], j), disabled = rowOff, buttons = {
                    { text = L["Remove"], tooltip = L["Remove this section."],
                      onClick = function() if UFO.RingSectionRemove(ring, j) then wrote(true) end end },
                } })
                list:AddDropdown({ label = L["Bar"], options = UFO.RingBarOptions(), disabled = rowOff,
                    get = function() return sec.bar or "HEALTH" end,
                    set = function(v) sec.bar = v end, onChanged = function() wrote(false) end })
                list:AddDropdown({ label = L["Coverage"], options = UFO.RingCoverageOptions(), disabled = rowOff,
                    get = function() return sec.coverage or "FULL" end,
                    set = function(v)
                        sec.coverage = v
                        -- A corner is a quarter's only: a half on one moves to the top.
                        if not UFO.RingPositionOptions(v)[sec.position or "TOP"] then sec.position = "TOP" end
                    end, onChanged = function() wrote(true) end })
                list:AddDropdown({ label = L["Position"], options = UFO.RingPositionOptions(sec.coverage),
                    disabled = rowOff,
                    hidden = function() return (sec.coverage or "FULL") == "FULL" end,
                    get = function() return sec.position or "TOP" end,
                    set = function(v) sec.position = v end, onChanged = function() wrote(false) end })
                list:AddSwitch({ label = L["Reverse Fill"], disabled = rowOff,
                    tooltip = L["Fill counter-clockwise."],
                    get = function() return sec.reverse and true or false end,
                    set = function(v) sec.reverse = v and true or nil end, onChanged = function() wrote(false) end })
                list:AddSlider({ label = L["Feather"], min = 0, max = 1, step = 0.05, disabled = rowOff,
                    tooltip = L["Softens the end of the fill."],
                    format = function(v) return format("%.2f", v) end,
                    get = function() return sec.feather or 0 end,
                    set = function(v) sec.feather = (v > 0) and v or nil end, onChanged = function() wrote(false) end })
            end
            list:AddButtons({ label = "", disabled = rowOff, buttons = {
                { text = L["Add Section"], width = 96,
                  disabled = function() return #ring.sections >= UFO.RING_SECTION_MAX end,
                  onClick = function() if UFO.RingSectionAdd(ring) then wrote(true) end end },
            } })
        end
        list:AddButtons({ label = "", disabled = rowOff, buttons = {
            { text = L["Add Ring"], width = 96,
              disabled = function() return #rings >= UFO.RING_MAX end,
              onClick = function() if UFO.RingAdd(rings) then wrote(true) end end },
        } })
        list:Refresh()
        if GUI.RelayoutHost and rawget(list, "settingsGroup") then
            GUI:RelayoutHost(list, list:GetHeight() + 4)
        end
    end
    Build()
    band:AddWidget(list, list:GetHeight() + 4)
    -- Frame Style greys / un-greys the rows: the page's state pass reaches them here.
    list.refreshContent = function() list:Refresh() end
    Close(band)
end

-- Resting / PvP / Elite & Rare: one card each, for the units that have it.
UFO.UNIT_ICON_CARDS = {
    { card = "resting_icon", prefix = "restingIcon", key = "uf_icon_resting", label = function() return L["Resting Icon"] end },
    { card = "pvp_icon", prefix = "pvpIcon", key = "uf_icon_pvp", label = function() return L["PvP Icon"] end },
    { card = "elite_rare", prefix = "classification", key = "uf_icon_classification", label = function() return L["Elite / Rare"] end },
}

function UFO.BuildUnitIconsPage(self, db, Add, rec, unit)
    UFO.AddPageHead(self, rec, unit, Add)
    local Open, Close = Tools(self, Add)
    local function changed() self:RefreshStates(); RefreshFrames() end
    local col = 0
    for _, c in ipairs(UFO.UNIT_ICON_CARDS) do
        if UFO.CardShown(rec, unit, c.card) then
            local pre = c.prefix
            local off = UFO.Gate(c.label(), function(d) return not (d and d[pre .. "Enabled"]) end)
            col = (col % 2) + 1
            local band = Open(c.label(), c.key, col, function(d) return OnOff(d, pre .. "Enabled") end, "icons",
                { db = db, key = pre .. "Enabled", label = L["Show"], onChanged = changed })
            local w
            if pre == "classification" then
                w = band:AddWidget(GUI:CreateDropdown(self.child, L["Style"],
                    { ICON = L["Icon"], TEXT = L["Text"], _order = { "ICON", "TEXT" } }, db, "classificationStyle", changed), 55)
                w.disableOn = off
            end
            w = band:AddWidget(GUI:CreateSlider(self.child, L["Size"], 8, 48, 1, db, pre .. "Size", changed), 55)
            w.disableOn = off
            w = band:AddWidget(GUI:CreateDropdown(self.child, L["Anchor"], PointOptions(), db, pre .. "Anchor", changed), 55)
            w.disableOn = off
            w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -100, 100, 1, db, pre .. "X", changed), 55)
            w.disableOn = off
            w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -100, 100, 1, db, pre .. "Y", changed), 55)
            w.disableOn = off
            if pre == "restingIcon" then
                w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Animate"], db, "restingIconAnimate", changed), 30)
                w.disableOn = off
                w.tooltip = L["Fade the Zs in and out. Off shows them still."]
                w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Glow"], db, "restingIconGlow", changed), 30)
                w.disableOn = off
                w.tooltip = L["Show a soft gold glow around the outside of the frame."]
                -- Include Portrait: greys while Resting or Glow is off.
                local glowOff = UFO.Gate(L["Glow"], function(d) return not (d and d.restingIconGlow) end, off)
                w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Include Portrait"], db,
                    "restingIconGlowPortrait", changed), 30)
                w.disableOn = glowOff
                w.tooltip = L["Draw the glow around the portrait too when it sits beside the frame."]
            end
            Close(band)
        end
    end
    -- The dragon and the class border: every unit with a classification, Boss
    -- included (Boss has no Elite / Rare icon card, only these).
    if UFO.CardShown(rec, unit, "class_decorations") then
        UFO.BuildClassDecorationCards(self, db, Open, Close, changed, col)
    end
end

-- Elite Dragon / Classification Border / Classification Colors (Indicators.lua,
-- CLASSIFICATION DRAGON and CLASSIFICATION BORDER). One set of per-type toggles
-- and colours drives both.
UFO.CLASS_TYPES = {
    { suffix = "Elite", label = function() return L["Elite"] end, color = function() return L["Elite Color"] end },
    { suffix = "Rare", label = function() return L["Rare"] end, color = function() return L["Rare Color"] end },
    { suffix = "RareElite", label = function() return L["Rare Elite"] end, color = function() return L["Rare Elite Color"] end },
    { suffix = "Boss", label = function() return L["Boss"] end, color = function() return L["Boss Color"] end },
}

function UFO.DragonSideOptions()
    return { OUTER = L["Outer"], RIGHT = L["Right"], LEFT = L["Left"], BOTH = L["Both"],
             _order = { "OUTER", "RIGHT", "LEFT", "BOTH" } }
end

function UFO.DragonAnchorOptions()
    return { PORTRAIT = L["Portrait"], FRAME = L["Frame"], _order = { "PORTRAIT", "FRAME" } }
end

function UFO.BuildClassDecorationCards(self, db, Open, Close, changed, col)
    local w
    -- The dragon.
    local dragonOff = UFO.Gate(L["Elite Dragon"], function(d) return not (d and d.classDragonEnabled) end)
    col = (col % 2) + 1
    local band = Open(L["Elite Dragon"], "uf_icon_dragon", col, function(d) return OnOff(d, "classDragonEnabled") end,
        "icons", { db = db, key = "classDragonEnabled", label = L["Show"], onChanged = changed,
                   tooltip = L["Draw a dragon gripping the end of the frame on elite, rare and boss units."] })
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Anchor To"], UFO.DragonAnchorOptions(), db,
        "classDragonAnchor", changed), 55)
    w.disableOn = dragonOff
    w.tooltip = L["Portrait: on the portrait's top and bottom edges, clear of auras and cast bars. Uses the frame when the portrait is off or sits inside the frame."]
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Size"], 50, 200, 5, db, "classDragonSize", changed), 55)
    w.disableOn = dragonOff
    w = band:AddWidget(GUI:CreateDropdown(self.child, L["Side"], UFO.DragonSideOptions(), db, "classDragonSide", changed), 55)
    w.disableOn = dragonOff
    w.tooltip = L["Outer: the portrait's side, on the edge away from the frame."]
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset X"], -50, 50, 1, db, "classDragonX", changed), 55)
    w.disableOn = dragonOff
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Offset Y"], -50, 50, 1, db, "classDragonY", changed), 55)
    w.disableOn = dragonOff
    w = band:AddWidget(GUI:CreateCheckbox(self.child, L["Show Tail"], db, "classDragonShowTail", changed), 30)
    w.disableOn = dragonOff
    w.tooltip = L["The lower piece, under the frame. Off on Boss frames, where each boss's cast bar sits under it."]
    local tailOff = UFO.Gate(L["Show Tail"], function(d) return d and d.classDragonShowTail == false end, dragonOff)
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Tail Offset X"], -50, 50, 1, db, "classDragonTailX", changed), 55)
    w.disableOn = tailOff
    w.tooltip = L["Moves the lower piece (the tail) left or right on its own."]
    Close(band)

    -- The border.
    local borderOff = UFO.Gate(L["Classification Border"], function(d) return not (d and d.classBorderEnabled) end)
    col = (col % 2) + 1
    band = Open(L["Classification Border"], "uf_icon_classborder", col, function(d) return OnOff(d, "classBorderEnabled") end,
        "border", { db = db, key = "classBorderEnabled", label = L["Show"], onChanged = changed,
                    tooltip = L["Color the frame's border by the unit's classification, using the Classification Colors."] })
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Border Thickness"], 1, 8, 1, db, "classBorderSize", changed), 55)
    w.disableOn = borderOff
    Close(band)

    -- The colours both use, and which classifications get them.
    local neither = UFO.Explain(function(d) return not (d and (d.classDragonEnabled or d.classBorderEnabled)) end,
        function() return format(L["Turn on %s to change this"], L["Elite Dragon"]) end)
    col = (col % 2) + 1
    band = Open(L["Classification Colors"], "uf_icon_classcolors", col, nil, "colours")
    for _, t in ipairs(UFO.CLASS_TYPES) do
        local key = "classDragon" .. t.suffix
        w = band:AddWidget(GUI:CreateCheckbox(self.child, t.label(), db, key, changed), 30)
        w.disableOn = neither
        w.tooltip = L["Show the dragon and the border on this classification."]
        local typeOff = UFO.Gate(t.label(), function(d) return d and d[key] == false end, neither)
        w = band:AddWidget(GUI:CreateColorPicker(self.child, t.color(), db, key .. "Color", false, changed), 30)
        w.disableOn = typeOff
    end
    Close(band)
end

-- The combat icon card on DandersFrames' Icons page gets the unit frames' border
-- controls (Modules.lua's combatIcon `after` hook reads page.dfIconCardExtras;
-- only unit frame pages set it, so the party / raid page is unchanged).
function UFO.IconCardExtras(page)
    local function changed() page:RefreshStates(); RefreshFrames() end
    return {
        combatIcon = function(group, parent, db)
            local off = UFO.Gate(L["Show Border"], function(d) return not (d and d.combatIconBorderEnabled) end)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Show Border"], db, "combatIconBorderEnabled", changed), 30)
            local w = group:AddWidget(GUI:CreateSlider(parent, L["Border Thickness"], 1, 8, 1, db, "combatIconBorderSize", changed), 55)
            w.disableOn = off
            w = group:AddWidget(GUI:CreateColorPicker(parent, L["Border Color"], db, "combatIconBorderColor", true, changed), 30)
            w.disableOn = off
        end,
    }
end

-- ---- Boss Layout (a page new to unit frames; Boss only) ----------------------
-- How the boss slots are laid out in their container (DandersFrames_UnitFrames/
-- Boss.lua): growth direction, spacing, wrapping, and the sample bosses the
-- preview shows. The sliders stop at the slot count this build draws.
-- Inventory controls deliberately NOT drawn: Fade Out of Range and Out of Range
-- Alpha (the generated `hide` list drops them for Boss -- the Fading page's Out of
-- Range card is what fades a boss frame).
function UFO.BossGrowthOptions()
    return { DOWN = L["Down"], UP = L["Up"], LEFT = L["Left"], RIGHT = L["Right"],
             _order = { "DOWN", "UP", "LEFT", "RIGHT" } }
end

function UFO.BossCount()
    local UF = DF.UnitFrames
    return (UF and UF.BOSS_COUNT) or 5
end

function UFO.BuildBossLayoutPage(self, db, Add, rec, unit)
    UFO.AddPageHead(self, rec, unit, Add)
    local Open, Close = Tools(self, Add)
    local function changed() self:RefreshStates(); RefreshFrames() end
    local count = UFO.BossCount()
    local growth = UFO.BossGrowthOptions()
    local w

    local band = Open(L["Arrangement"], "uf_boss_arrangement", 1, function(d)
        local g = d and growth[d.bossGrowth] or growth.DOWN
        return format("%s%s%s", g, SEP, tostring(d and d.bossSpacing or ""))
    end, "layout")
    band:AddWidget(GUI:CreateDropdown(self.child, L["Growth Direction"], growth, db, "bossGrowth", changed), 55)
    band:AddWidget(GUI:CreateSlider(self.child, L["Frame Spacing"], 0, 150, 1, db, "bossSpacing", changed), 55)
    band:AddWidget(GUI:CreateSlider(self.child, L["Units Per Row"], 1, count, 1, db, "bossUnitsPerRow", changed), 55)
    w = band:AddWidget(GUI:CreateSlider(self.child, L["Row Spacing"], -5, 50, 1, db, "bossRowSpacing", changed), 55)
    -- Only matters once a row wraps.
    w.disableOn = UFO.Explain(function(d) return not (d and tonumber(d.bossUnitsPerRow) and d.bossUnitsPerRow < count) end,
        function() return L["Only used when the frames wrap into more than one row"] end)
    band:AddWidget(GUI:CreateButtonRow(self.child, {
        { label = L["Edit in Mover"], width = 120, icon = "open_with",
          onClick = function() UFO.EditInMover("boss") end },
    }, { width = 250 }), 30)
    Close(band)

    band = Open(L["Behaviour"], "uf_boss_behaviour", 2, function(d)
        return (d and d.bossPreviewCount == false) and L["Off"] or tostring(d and d.bossPreviewNum or "")
    end, "settings")
    band:AddWidget(GUI:CreateCheckbox(self.child, L["Show Placeholder Frames in Test Mode"], db, "bossPreviewCount", changed), 30)
    band:AddWidget(GUI:CreateSlider(self.child, L["Preview Frames"], 1, count, 1, db, "bossPreviewNum", changed), 55)
    Close(band)
end

-- ---- moving a frame ----------------------------------------------------------
function UFO.EditInMover(unit)
    local UF = DF.UnitFrames
    local M = UF and UF.Mover
    if M and M.lib and M.registered and M.registered[unit] then
        M.lib:Unlock({ addon = M.ADDON_KEY, keys = { unit } })
        return true
    end
    if DF.Say then DF:Say(L["DandersMover is disabled"]) end
    return false
end

function UFO.ResetPosition(unit)
    local UF = DF.UnitFrames
    local stored = UF and UF:GetStoredUnit(unit)
    if not stored then return end
    stored.position = nil
    -- Boss: the record is the container's (Boss.lua).
    if unit == "boss" and UF.Boss and UF.Boss.ApplyPosition then
        UF:RunOutOfCombat("position:boss", function() UF.Boss:ApplyPosition() end)
        if UF.Boss.PreviewApplyPosition then UF.Boss:PreviewApplyPosition() end
    end
    local f = UF.frames and UF.frames[unit]
    if f and UF.Units and UF.Units.ApplyPosition then
        UF:RunOutOfCombat("position:" .. unit, function() UF.Units:ApplyPosition(f) end)
    end
    if UF.Mover and UF.Mover.ApplyAll then UF.Mover:ApplyAll() end
end

-- ---- the units test mode (UF.Preview's "test" owner) ------------------------------
-- Its own mode, apart from the party / raid test mode: the two never mix
-- (Preview.lua). Its controls are the test popup's Units mode (TestMode.lua).
function UFO.IsTestModeOn()
    local UF = DF.UnitFrames
    local P = UF and UF.Preview
    return P and P.IsTestMode and P:IsTestMode() or false
end

function UFO.SetTestMode(on)
    local UF = DF.UnitFrames
    local P = UF and UF.Preview
    if P and P.SetTestMode then return P:SetTestMode(on) end
    return false
end

function UFO.ToggleTestMode()
    return UFO.SetTestMode(not UFO.IsTestModeOn())
end

-- ⚠ NO CARD OF OUR OWN IS ADDED TO A PAGE A PARTY BUILDER DRAWS: a second
-- GUI:CreatePopoutPageTools in the same build retires the first one's popout
-- holders, taking the party cards' pins with it. Moving frames lives on the
-- module Settings page instead (Position card), one row per unit.
-- ============================================================
-- LIVE SLIDERS (drag previews)
-- The settings kit runs a slider's `lightweight` callback once per rendered
-- frame while it is dragged, and its own callback only on release; a slider
-- with no lightweight previews nothing until then. Every slider built for a
-- unit page -- ours and the party builders' alike -- gets the unit's own live
-- path (UF:LiveApply: the one element, on that unit's frames) in place of
-- whatever it brought: a party builder's lightweight re-lays out PARTY frames,
-- never these. Done by standing in for GUI:CreateSlider for the length of the
-- build, so no builder needs to know about it.
-- ============================================================
function UFO.LiveSlider(unit, key, kind)
    return function()
        local UF = DF.UnitFrames
        if UF and UF.LiveApply then UF:LiveApply(unit, key, kind) end
    end
end

function UFO.WithLiveSliders(rec, unit, build, ...)
    local orig = GUI.CreateSlider
    GUI.CreateSlider = function(g, parent, label, lo, hi, step, dbTable, dbKey, callback, _, ...)
        local key = (type(dbKey) == "string") and dbKey or nil
        return orig(g, parent, label, lo, hi, step, dbTable, dbKey, callback,
            UFO.LiveSlider(unit, key, rec.kind), ...)
    end
    local ok, err = pcall(build, ...)
    GUI.CreateSlider = orig
    if not ok then error(err, 0) end
end

function UFO.PageBuilder(rec, unit)
    return function(self, db, Add, AddSpace, AddSyncPoint)
        UFO.WithLiveSliders(rec, unit, UFO.BuildPageBody, self, db, Add, AddSpace, AddSyncPoint, rec, unit)
        -- Every gated control says why it is grey (GREYED CONTROLS SAY WHY).
        UFO.ApplyDisableReasons(self.children)
    end
end

function UFO.BuildPageBody(self, db, Add, AddSpace, AddSyncPoint, rec, unit)
    if rec.source then
        UFO.BuildFromDF(self, db, Add, AddSpace, AddSyncPoint, rec, unit)
    elseif rec.kind == "text" then
        UFO.BuildTextPage(self, db, Add, rec, unit)
    elseif rec.kind == "auradesigner" then
        UFO.BuildAuraDesignerPage(self, db, Add, rec, unit)
    elseif rec.kind == "visibility" then
        UFO.BuildVisibilityPage(self, db, Add, rec, unit)
    elseif rec.kind == "castbar" then
        UFO.BuildCastBarPage(self, db, Add, rec, unit)
    elseif rec.kind == "classpower" then
        UFO.BuildClassPowerPage(self, db, Add, rec, unit)
    elseif rec.kind == "portrait" then
        UFO.BuildPortraitPage(self, db, Add, rec, unit)
    elseif rec.kind == "rings" then
        UFO.BuildRingsPage(self, db, Add, rec, unit)
    elseif rec.kind == "unitIcons" then
        UFO.BuildUnitIconsPage(self, db, Add, rec, unit)
    elseif rec.kind == "bosslayout" then
        UFO.BuildBossLayoutPage(self, db, Add, rec, unit)
    end
end

-- ============================================================
-- THE MODULE-WIDE SETTINGS PAGE (uf_settings, on every tab)
-- Unit Frames on/off, who draws each frame, Blizzard's cast bar, and a way into
-- the mover per frame. Its table is the module's own (DF.db.unitframes.global).
-- ============================================================
UFO.SOURCES = { "DF", "Blizzard", "Hidden" }
-- A unit whose Blizzard frame lives inside another's: it can be Blizzard's only
-- while that one is.
UFO.INSIDE = { targettarget = "target", focustarget = "focus" }

function UFO.SourceOptions(unit)
    local opts = { DF = "DandersFrames", Blizzard = L["Blizzard"], Hidden = L["Hidden"],
                   _order = { "DF", "Blizzard", "Hidden" } }
    -- Blizzard's target of target lives inside its target frame (and the focus's
    -- target inside the focus frame).
    local inside = UFO.INSIDE[unit]
    if inside and UFO.GetSource(inside) ~= "Blizzard" then
        opts.Blizzard = nil
        opts._order = { "DF", "Hidden" }
    end
    return opts
end

function UFO.GetSource(unit)
    local UF = DF.UnitFrames
    local db = UF and UF:GetUnitDB(unit)
    return (db and db.source) or "DF"
end

-- Returns true when the value was taken. Needs a reload either way it moves.
function UFO.SetSource(unit, value)
    local UF = DF.UnitFrames
    local stored = UF and UF:GetStoredUnit(unit)
    if not stored then return false end
    if value ~= "DF" and value ~= "Blizzard" and value ~= "Hidden" then return false end
    local inside = UFO.INSIDE[unit]
    if inside and value == "Blizzard" and UFO.GetSource(inside) ~= "Blizzard" then
        return false
    end
    local before = UFO.GetSource(unit)
    stored.source = value
    -- Target (focus) off Blizzard takes a Blizzard target of target (focus target)
    -- with it.
    if value ~= "Blizzard" then
        for child, parent in pairs(UFO.INSIDE) do
            if parent == unit and UFO.GetSource(child) == "Blizzard" then
                UF:GetStoredUnit(child).source = "DF"
            end
        end
    end
    if before ~= value then
        UFO.PromptReload(L["Changing who draws a unit frame requires a UI reload to take effect.\n\nReload now?"])
    end
    return true
end

-- Blizzard's player cast bar is hidden (the user's choice, or following ours).
function UFO.HidesBlizzardCastBar()
    local UF = DF.UnitFrames
    local BH = UF and UF.BlizzardHide
    if BH and BH.ShouldHideCastBar then return BH:ShouldHideCastBar() and true or false end
    local g = UF and UF:GetGlobalDB()
    return (g and g.hideBlizzardCastbar) and true or false
end

function UFO.BuildSettingsPage(self, db, Add)
    local UF = DF.UnitFrames
    local Open, Close = Tools(self, Add)

    local band = Open(L["Unit Frames"], "uf_module", 1,
        function() return UFO.IsEnabled() and L["On"] or L["Off"] end, "settings")
    band:AddWidget(GUI:CreateCheckbox(self.child, L["Enabled"], nil, nil, nil,
        function() return UFO.IsEnabled() end,
        function(v) UFO.SetEnabled(v) end), 30)
    Close(band)

    -- (The units test mode has no switch here: the window's Test button, on any
    -- Unit Frames page, opens its panel -- TestPanel.lua.)

    -- One row per frame this build draws: its name, Edit in Mover, Reset Position.
    band = Open(L["Position"], "uf_movers", 1, nil, "position")
    for _, unit in ipairs(UF and UF.SPAWNED_UNITS or {}) do
        local u = unit
        band:AddWidget(GUI:CreateLabel(self.child, UFO.UnitLabel(u), 250), 18)
        band:AddWidget(GUI:CreateButtonRow(self.child, {
            { label = L["Edit in Mover"], width = 120, icon = "open_with",
              onClick = function() UFO.EditInMover(u) end },
            { label = L["Reset Position"], width = 120,
              onClick = function() UFO.ResetPosition(u) end },
        }, { width = 250 }), 30)
    end
    Close(band)

    band = Open(L["Frame Source"], "uf_source", 2, function()
        local parts = {}
        for _, unit in ipairs(UF and UF.SPAWNED_UNITS or {}) do
            local src = UFO.GetSource(unit)
            local word = (src == "Blizzard" and L["Blizzard"]) or (src == "Hidden" and L["Hidden"]) or "DandersFrames"
            parts[#parts + 1] = format("%s %s", UFO.UnitShortLabel(unit), word)
        end
        return concat(parts, SEP)
    end, "framemodes")
    for _, unit in ipairs(UF and UF.SPAWNED_UNITS or {}) do
        local u = unit
        band:AddWidget(GUI:CreateDropdown(self.child, UFO.UnitLabel(u), UFO.SourceOptions(u), nil, nil,
            function() self:RefreshStates() end,
            function() return UFO.GetSource(u) end,
            function(v) UFO.SetSource(u, v) end,
            { optionsFunc = function() return UFO.SourceOptions(u) end }), 55)
    end
    band:AddWidget(GUI:CreateLabel(self.child, L["Target of Target can only be Blizzard when Target is."], 250), 30)
    band:AddWidget(GUI:CreateLabel(self.child, L["Focus Target can only be Blizzard when Focus is."], 250), 30)
    Close(band)

    -- Q7: unset, the tick FOLLOWS the player cast bar (ticked while ours is on);
    -- a click stores the user's own choice (BlizzardHide.lua ShouldHideCastBar).
    band = Open(L["Blizzard Frames"], "uf_blizzard", 2,
        function() return UFO.HidesBlizzardCastBar() and format(L["%s hidden"], L["Cast Bar"]) or L["Shown"] end,
        "visibility")
    band:AddWidget(GUI:CreateCheckbox(self.child, L["Hide Blizzard Player Cast Bar"], db, "hideBlizzardCastbar",
        function()
            UFO.PromptReload(L["Changing who draws a unit frame requires a UI reload to take effect.\n\nReload now?"])
        end,
        function() return UFO.HidesBlizzardCastBar() end,
        function(v) if db then db.hideBlizzardCastbar = v and true or false end end), 30)
    Close(band)
end

-- ============================================================
-- WHICH PARTS TWO UNITS SHARE (the Linked Frames page lists these;
-- DandersFrames_Options/UnitFrames/LinksPage.lua)
-- ============================================================
-- Does `unit` have this element's page?
function UFO.UnitHasElement(unit, elem)
    local rec = elem and UFO.pageByKind[elem.kind]
    return (rec and not rec.later and rec.units and rec.units[unit]) and true or false
end

-- The elements both units have, in sidebar order.
function UFO.SharedElements(a, b)
    local out = {}
    local Lk = UFO.Links()
    if not (Lk and a and b) then return out end
    for _, e in ipairs(Lk.ELEMENTS) do
        if UFO.UnitHasElement(a, e) and UFO.UnitHasElement(b, e) then out[#out + 1] = e end
    end
    return out
end

-- ============================================================
-- REGISTRATION (the page provider)
-- ============================================================
function UFO.UnitTabs()
    local tabs = {}
    for _, unit in ipairs(UFO.TABS) do
        local u = unit
        tabs[#tabs + 1] = {
            id = u,
            label = function() return UFO.UnitLabel(u) end,
            deckLabel = function() return UFO.UnitDeckLabel(u) end,
            accent = function() return GUI.UnitsAccent end,
            -- The link mark: this tab's unit is linked to another.
            mark = function() return UFO.TabMark(u) end,
        }
    end
    return tabs
end

-- ============================================================
-- RESET (the Modules page's Reset on Unit Frames; MODULE RESET in
-- GUI/ModuleRegistry.lua). The data and the frames are UF:ResetProfile's
-- (DandersFrames_UnitFrames/Core.lua); this side refreshes the settings pages and,
-- when the reset changed who draws a unit, asks for the reload that change needs.
-- Only while the module is loaded: switched off, it has no button.
-- ============================================================
UFO.Reset = {
    available = function()
        local UF = DF.UnitFrames
        return UFO.IsLoaded() and UF and UF.ResetProfile and true or false
    end,
    -- A few grouped lines: the warning has to fit one popup (MODULE RESET).
    covers = function()
        return {
            L["All unit frame settings and positions, including the Unit Frames Settings page"],
            L["Linked frames, back to just the default Player and Target link"],
            L["The Unit Frames and Unit Frames (Small) text templates are rebuilt, so edits to them are lost"],
        }
    end,
    keeps = function()
        return { L["whether Unit Frames is on, and text templates under other names"] }
    end,
    run = function()
        local UF = DF.UnitFrames
        if not (UF and UF.ResetProfile) then return false end
        local ok, needsReload = UF:ResetProfile()
        if not ok then return false end
        -- Every unit page was built against a table that is gone.
        if GUI.InvalidateAllPages then GUI:InvalidateAllPages() end
        if GUI.RefreshPageMarks then GUI:RefreshPageMarks() end
        if needsReload then
            -- Deferred: this can run inside another popup's button (a mover
            -- session's Save / Discard), which hides the frame after it returns.
            C_Timer.After(0, function()
                UFO.PromptReload(L["Changing who draws a unit frame requires a UI reload to take effect.\n\nReload now?"])
            end)
        end
        return true
    end,
}

function UFO.RegisterModule()
    return GUI:SidebarModule({
        id = UFO.MODULE,
        label = function() return L["Unit Frames"] end,
        railLabel = function() return L["Units"] end,
        icon = ICONS .. "person.png",
        order = 15,
        slot = "top",
        accent = function() return GUI.UnitsAccent end,
        tabs = UFO.UnitTabs(),
        -- The link mark on a sidebar row: something on that page is linked.
        pageMark = function(name) return UFO.PageMark(name) end,
        tabWidth = UFO.TAB_WIDTH,
        minWindowWidth = UFO.MIN_WINDOW_WIDTH,
        activeTab = function() return UFO.unit end,
        defaultTab = function() return UFO.unit end,
        onTab = function(tabId) if UFO.IsTab(tabId) then UFO.unit = tabId end end,
        pageInView = function(name)
            local m = UFO.pageMeta[name]
            return not m or m.unit == nil or MetaTab(m) == UFO.unit
        end,
        tabForPage = function(name)
            return MetaTab(UFO.pageMeta[name])
        end,
        pageForTab = function(tabId, from) return UFO.PageForTab(tabId, from) end,
        isEnabled = UFO.IsEnabled,
        setEnabled = UFO.SetEnabled,
        status = UFO.Status,
        description = function() return L["Player, target, target of target, focus, pet and boss frames."] end,
        reset = UFO.Reset,
        -- The window's Test button speaks for this module's own test mode while
        -- it shows: the shared popup's Units mode (TestMode.lua), never the
        -- party / raid one.
        testModeId = "units",
    })
end

function UFO.BuildPages(CreateCategory, CreateSubTab, BuildPage)
    local data = DF.UnitFramePageData
    UFO.data = data
    if not data then return end
    local UF = DF.UnitFrames

    -- The module-wide page first, above every unit's.
    CreateCategory("uf_module", L["Unit Frames"])
    local settings = CreateSubTab("uf_module", "uf_settings", L["Settings"])
    if settings then
        settings.buildKey = function() return "uf:module" end
        settings.buildDb = function() return UF and UF:GetGlobalDB() end
        settings.searchTabLabel = format("%s%s%s", L["Unit Frames"], SEP, L["Settings"])
        GUI:SetPageModule("uf_settings", UFO.MODULE)
        UFO.pageMeta.uf_settings = { kind = "settings" }
        BuildPage(settings, function(self, db, Add) UFO.BuildSettingsPage(self, db, Add) end)
    end
    -- Linked Frames, right below it (LinksPage.lua).
    if UFO.RegisterLinksPage then UFO.RegisterLinksPage(CreateSubTab, BuildPage) end

    for _, cat in ipairs(data.categories) do
        CreateCategory("uf_" .. cat.id, L[cat.label])
    end
    -- A unit without a tab of its own: one category of its own on its host tab,
    -- after that tab's own categories (the focus target's pages on Focus).
    for _, unit in ipairs(UFO.UNITS) do
        if UFO.TAB_OF[unit] then CreateCategory("uf_" .. unit, UFO.UnitLabel(unit)) end
    end
    for _, rec in ipairs(data.pages) do
        UFO.pageByKind[rec.kind] = rec
        if not rec.later then
            for _, unit in ipairs(UFO.UNITS) do
                if rec.units[unit] then
                    local u = unit
                    local name = UFO.PageName(u, rec.kind)
                    local cat = UFO.TAB_OF[u] and ("uf_" .. u) or ("uf_" .. rec.category)
                    local pg = CreateSubTab(cat, name, L[rec.title])
                    if pg then
                        pg.buildKey = function() return "uf:" .. u end
                        pg.buildDb = function() return UF and UF:GetUnitDB(u) end
                        pg.searchTabLabel = format("%s%s%s", UFO.UnitLabel(u), SEP, L[rec.title])
                        pg.ufUnit, pg.ufKind = u, rec.kind
                        pg.mapPageLink = function(id) return UFO.MapPageLink(u, id) end
                        -- ~90 unit pages, each a full party page builder: they join
                        -- the search index only once a search is typed or the
                        -- Unit Frames ledger is asked for (Search DEFERRED PAGES).
                        pg.deferIndex = true
                        -- The designers' pages: the designer's own width (UFO.AddDesignerSlot).
                        if rec.kind == "text" or rec.kind == "auradesigner" then
                            GUI.PageMinWidths = GUI.PageMinWidths or {}
                            GUI.PageMinWidths[name] = UFO.DesignerPageMinWidth
                        end
                        if rec.kind == "health" then
                            pg.extraHealthColorModes = { REACTION = L["Reaction"], CLASS_REACTION = L["Class / Reaction"] }
                        end
                        GUI:SetPageModule(name, UFO.MODULE)
                        UFO.pageMeta[name] = { unit = u, tab = UFO.TabOf(u), kind = rec.kind }
                        UFO.pagesByUnit[u] = UFO.pagesByUnit[u] or {}
                        UFO.pagesByUnit[u][rec.kind] = name
                        BuildPage(pg, UFO.PageBuilder(rec, u))
                    end
                end
            end
        end
    end
end

function UFO.Provider(G, CreateCategory, CreateSubTab, BuildPage)
    UFO.BuildPages(CreateCategory, CreateSubTab, BuildPage)
    UFO.RegisterModule()
end

-- Installed but not loaded (switched off, or switched on and waiting for the
-- reload): the placeholder row gets the switch and the status; the rail leaves it
-- out while it is off (GUI/Rail.lua InRail). Not installed: it stays Coming soon.
function UFO.ApplyInstallState()
    local def = GUI.GetModule and GUI:GetModule(UFO.MODULE)
    if not def or not UFO.IsInstalled() then return false end
    def.comingSoon = nil
    def.isEnabled = UFO.IsEnabled
    def.setEnabled = UFO.SetEnabled
    def.status = UFO.Status
    -- Switched on but not loaded yet: its rail item says so, with the reload.
    def.placeholderNote = UFO.PlaceholderNote
    def.placeholderAction = UFO.PlaceholderAction
    GUI:RegisterModule(def)
    return true
end

function UFO.WaitingForReload()
    return UFO.IsEnabled() and not UFO.IsLoaded()
end

function UFO.PlaceholderNote()
    if UFO.WaitingForReload() then return L["Reload to finish turning on Unit Frames."] end
    return nil
end

function UFO.PlaceholderAction()
    if not UFO.WaitingForReload() then return nil end
    return { label = L["Reload Now"], onClick = function() ReloadUI() end }
end

-- ============================================================
-- THE LINKS ON EVERY WRITE: after every settings write (DF's apply drain), the
-- unit being edited pushes its link to its partner (Links:ApplyFrom). On the
-- drain, comparing values, rather than on the table's writes: a colour picker
-- edits its colour table IN PLACE, which no write hook would ever see.
-- ============================================================
function UFO.OnApplyDrain()
    if UFO.ApplyLinks() > 0 then RefreshFrames() end
end

-- ============================================================
-- CHANGED SETTINGS: a Unit Frames scope (Profiles > Changed Settings)
-- Every unit page against its unit's own table (UF:GetUnitDB, which answers
-- DF.Defaults through its adapter -- Core.lua), the module page against the
-- module table. Grouped by page, in unit order: all of Player's pages, then
-- Target's, ... One row per unit and key.
-- ============================================================
function UFO.ChangedPageOrder()
    local order = { "uf_settings" }
    for _, unit in ipairs(UFO.UNITS) do
        local pages = UFO.pagesByUnit[unit]
        if pages then
            for _, rec in ipairs(UFO.data and UFO.data.pages or {}) do
                if pages[rec.kind] then order[#order + 1] = pages[rec.kind] end
            end
        end
    end
    return order
end

function UFO.ChangedScope()
    return {
        label = function() return L["Unit Frames"] end,
        owns = function(tab) return UFO.pageMeta[tab] ~= nil end,
        dbFor = function(tab)
            local UF = DF.UnitFrames
            local m = UFO.pageMeta[tab]
            if not (UF and m) then return nil end
            if m.unit then return UF:GetUnitDB(m.unit) end
            return UF:GetGlobalDB()
        end,
        pageOrder = UFO.ChangedPageOrder,
        rowKey = function(e)
            local m = UFO.pageMeta[e.tab]
            return tostring(m and m.unit or "module") .. ":" .. tostring(e.dbKey)
        end,
        prepare = function()
            if DF.Search and DF.Search.IncludeDeferredPages then DF.Search:IncludeDeferredPages() end
        end,
        available = UFO.IsLoaded,
    }
end

function UFO.Init()
    UFO.ApplyInstallState()
    if not UFO.IsLoaded() then return false end
    local CS = DF.ChangedSettings
    if CS and CS.RegisterScope then CS:RegisterScope(UFO.MODULE, UFO.ChangedScope()) end
    DF.GUIPageProviders = DF.GUIPageProviders or {}
    DF.GUIPageProviders[#DF.GUIPageProviders + 1] = UFO.Provider
    GUI.PlayerFrameOwnerNote = UFO.PlayerFrameOwnerNote
    if DF.Apply and DF.Apply.AddPostDrain then DF.Apply:AddPostDrain(UFO.OnApplyDrain) end
    return true
end

UFO.Init()
