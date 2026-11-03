local addonName, UF = ...

-- ============================================================
-- DANDERSFRAMES UNIT FRAMES -- LINKED FRAMES
-- Two unit frames can be LINKED: per element (Health, Buffs, Cast Bar, ...)
-- each of its two aspects is shared, mirrored or the unit's own.
--
--   global.unitLinks[follower] = {
--       to       = leader,
--       elements = { [elementId] = { layout = "same"|"mirror"|"own",
--                                    look   = "same"|"own" } },
--       except   = { [key] = true },   -- optional: keys that stay per unit
--   }
--
-- * A unit is in at most ONE link (as follower or leader), so links are pairs.
-- * Propagation is two-way: an edit on either side flows to the other
--   (Links:ApplyFrom, run from the settings apply drain for the unit being
--   edited). Leader/follower only matter for the initial apply and for which
--   side draws its Text Designer text mirrored (the follower).
-- * An element absent from `elements` is "own" on both aspects.
-- * `unitLinks` PRESENT (even empty) means "seeded": the default link is made
--   once, on a profile with no unitLinks key at all, and never again after the
--   user removes it.
--
-- RESIDENT, not in the settings companion, because three things need it with
-- the settings window never opened: the default link on a new profile, the
-- migration of the old per-page sync, and the mirrored-text flag the frames
-- read at paint time.
--
-- Every function takes `root`: a DF.db.unitframes-shaped table ({ global,
-- units }), so the profile-root migrate hook can run it on any stored profile.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tsort = table.sort

local Links = {}
UF.Links = Links

-- ============================================================
-- KEYS NO LINK EVER MOVES (who draws it, where it is on screen)
-- ============================================================
Links.NEVER = { source = true, position = true,
                castbarPosition = true, classPowerPositionRecord = true }

-- ============================================================
-- PAGES -> KEY PREFIXES
-- A party page's keys are the prefixes DandersFrames registers for it
-- (DF.SECTION_PREFIXES, resolved by DF:SectionOwnsKey's longest-match rule).
-- KIND_SOURCE mirrors the settings pages' `source` (PageData.lua, generated);
-- a test pins the two together.
-- ============================================================
Links.KIND_SOURCE = {
    frame = "general_frame", tooltips = "display_tooltips", fading = "display_fading",
    health = "bars_health", resource = "bars_resource", absorbs = "bars_absorb",
    healpred = "bars_healpred", buffs = "auras_buffs", debuffs = "auras_debuffs",
    defensive = "auras_defensiveicon", dispel = "auras_dispel",
    icons = "indicators_icons", highlights = "indicators_highlights",
}
-- Pages new to unit frames own these prefixes (UFO.Prefixes says the same).
Links.KIND_PREFIXES = {
    text = { "textDesignerPreset", "ringTextDesignerPreset" }, auradesigner = { "auraDesignerEnabled", "auraDesignerPreset" },
    visibility = { "vis" }, castbar = { "castbar" }, classpower = { "classPower" },
    portrait = { "portrait" },
    rings = { "frameStyle", "ringSize", "rings", "ringPortrait3D", "ringShow" },
    unitIcons = { "restingIcon", "pvpIcon", "classification", "classDragon", "classBorder" },
    bosslayout = { "boss" },
}

function Links.PagePrefixes(kind)
    local src = Links.KIND_SOURCE[kind]
    if src then
        return (DF.SECTION_PREFIXES and DF.SECTION_PREFIXES[src])
            or (DF.SectionRegistry and DF.SectionRegistry[src]) or {}
    end
    return Links.KIND_PREFIXES[kind] or {}
end

-- ============================================================
-- ELEMENTS -- what a link is made of
-- One per settings page, except the Frame page, which is two: its border and
-- everything else. `layout = false`: the element has no layout aspect a link
-- moves (its position keys are the party group's anchor and mover, which mean
-- nothing to a unit frame). `mirror = false`: its layout can be shared but never
-- mirrored -- Absorbs and Heal Prediction sit where the health bar's fill ends,
-- which a mirror does not turn round, and a tooltip's anchor is relative to the
-- screen edge it opens towards. A stored "mirror" for one reads as "same"
-- (Links.Normalise). `title` is an L key.
-- Order = the settings sidebar's.
-- ============================================================
local BORDER_PREFIXES = { "frameBorder", "frameShowBorder" }
-- The Frame page's own prefix ("frame") would take frameStyle; it is Rings'.
local FRAME_WITHOUT = { "frameBorder", "frameShowBorder", "frameStyle" }

Links.ELEMENTS = {
    { id = "frame",        kind = "frame",        title = "Frame",           layout = false, without = FRAME_WITHOUT },
    { id = "border",       kind = "frame",        title = "Border",          layout = false, only = BORDER_PREFIXES },
    -- Frame Style and the ring list (Rings.lua). The ring list is the layout aspect:
    -- one value, moved whole, and a mirror turns its sections round (Links.MirrorRings).
    { id = "rings",        kind = "rings",        title = "Frame Style",     layout = true },
    { id = "visibility",   kind = "visibility",   title = "Visibility",      layout = false },
    { id = "tooltips",     kind = "tooltips",     title = "Tooltips",        layout = true, mirror = false },
    { id = "fading",       kind = "fading",       title = "Fading",          layout = false },
    { id = "portrait",     kind = "portrait",     title = "Portrait",        layout = true },
    { id = "health",       kind = "health",       title = "Health Bar",      layout = true },
    { id = "resource",     kind = "resource",     title = "Resource Bar",    layout = true },
    { id = "absorbs",      kind = "absorbs",      title = "Absorbs",         layout = true, mirror = false },
    { id = "healpred",     kind = "healpred",     title = "Heal Prediction", layout = true, mirror = false },
    { id = "castbar",      kind = "castbar",      title = "Cast Bar",        layout = true },
    { id = "classpower",   kind = "classpower",   title = "Class Power",     layout = true },
    -- Text's layout is the shared Text Designer template's: a mirrored Text link
    -- draws the follower's text mirrored (Links:IsTextMirrored) rather than moving
    -- keys, so its layout aspect has no keys of its own.
    { id = "text",         kind = "text",         title = "Text",            layout = true, layoutByFlag = true },
    { id = "buffs",        kind = "buffs",        title = "Buff Bar",        layout = true },
    { id = "debuffs",      kind = "debuffs",      title = "Debuff Bar",      layout = true },
    { id = "defensive",    kind = "defensive",    title = "Defensive Icon",  layout = true },
    { id = "dispel",       kind = "dispel",       title = "Dispel Overlay",  layout = true },
    { id = "auradesigner", kind = "auradesigner", title = "Aura Designer",   layout = false },
    { id = "icons",        kind = "icons",        title = "Icons",           layout = true },
    { id = "unitIcons",    kind = "unitIcons",    title = "Unit Icons",      layout = true },
    { id = "highlights",   kind = "highlights",   title = "Highlights",      layout = false },
    { id = "bosslayout",   kind = "bosslayout",   title = "Boss Layout",     layout = true },
}
Links.BY_ID = {}
Links.BY_KIND = {}         -- page kind -> { element, ... }
for _, e in ipairs(Links.ELEMENTS) do
    Links.BY_ID[e.id] = e
    Links.BY_KIND[e.kind] = Links.BY_KIND[e.kind] or {}
    local list = Links.BY_KIND[e.kind]
    list[#list + 1] = e
end

-- The elements a page shows (the Frame page: two).
function Links.ElementsForKind(kind) return Links.BY_KIND[kind] or {} end

local function StartsWithAny(key, prefixes)
    for _, p in ipairs(prefixes) do
        if key:sub(1, #p) == p then return true end
    end
    return false
end

-- The cheap prefix test first: DF:SectionOwnsKey walks the whole registry, and
-- the key inventory is ~1,400 keys against 22 elements.
local function PageOwns(kind, key)
    local prefixes = Links.PagePrefixes(kind)
    if #prefixes == 0 or not StartsWithAny(key, prefixes) then return false end
    if DF.SectionOwnsKey then return DF:SectionOwnsKey(prefixes, key) end
    return true
end

-- Does this element own `key`? (Elements are disjoint: pages by longest
-- prefix, the Frame page's two halves by the border prefixes.)
function Links.ElementOwns(elem, key)
    if type(key) ~= "string" or Links.NEVER[key] then return false end
    if not PageOwns(elem.kind, key) then return false end
    if elem.only and not StartsWithAny(key, elem.only) then return false end
    if elem.without and StartsWithAny(key, elem.without) then return false end
    return true
end

-- key -> element id (false: none). Static once the registry is complete, so
-- memoised; Links.ResetCaches() drops it (tests, a registry that grew).
local ownerCache, keyCache = {}, {}
function Links.ResetCaches()
    ownerCache, keyCache = {}, {}
end

function Links.OwnerOf(key)
    local hit = ownerCache[key]
    if hit ~= nil then return hit or nil end
    for _, e in ipairs(Links.ELEMENTS) do
        if Links.ElementOwns(e, key) then
            ownerCache[key] = e.id
            return e.id
        end
    end
    ownerCache[key] = false
    return nil
end

-- Every key an element could hold, from the defaults chain (party defaults and
-- every unit's own). Stored keys are added per call (Links:Keys).
function Links.StaticKeys(elemId)
    local list = keyCache[elemId]
    if list then return list end
    list = {}
    local seen = {}
    local function take(t)
        if type(t) ~= "table" then return end
        for k in pairs(t) do
            if not seen[k] and Links.OwnerOf(k) == elemId then
                seen[k] = true
                list[#list + 1] = k
            end
        end
    end
    take(DF.PartyDefaults)
    for _, t in pairs(UF.UnitDefaults or {}) do take(t) end
    tsort(list)
    keyCache[elemId] = list
    return list
end

-- ============================================================
-- LAYOUT OR LOOK
-- Layout: where a piece sits and which way it runs -- anchor / point / side /
-- growth / orientation / justify / attached or detached, and its offset or x/y
-- position within the frame. Look: everything else, sizes included.
-- ============================================================
local LAYOUT_SUFFIXES = {
    "Anchor", "AnchorPos", "Point", "Position", "Side", "Growth", "Orientation",
    "Justify", "JustifyH", "Detached", "AttachTo", "OffsetX", "OffsetY",
}
-- Keys that match a layout pattern but describe how a thing LOOKS. Checked
-- first. Each is a suffix.
Links.LOOK_EXCEPTIONS = {
    "ShadowOffsetX", "ShadowOffsetY",       -- a drop shadow's offset
    "BorderOffsetX", "BorderOffsetY",       -- a border's inset geometry
    "BorderAnimationOffsetX", "BorderAnimationOffsetY",
    "PaddingX", "PaddingY",                 -- the gap between icons (a size)
}

local function EndsWith(key, suffix)
    return #key >= #suffix and key:sub(-#suffix) == suffix
end

-- Layout whatever the name says: the ring list, which says where each bar sits.
Links.LAYOUT_KEYS = { rings = true }

local function Classify(key)
    if Links.LAYOUT_KEYS[key] then return "layout" end
    for _, s in ipairs(Links.LOOK_EXCEPTIONS) do
        if EndsWith(key, s) then return "look" end
    end
    for _, s in ipairs(LAYOUT_SUFFIXES) do
        if EndsWith(key, s) then return "layout" end
    end
    -- A bare X / Y after a lower-case letter or digit: castbarX, portraitY,
    -- buffCasterX -- a position within the frame.
    if key:find("[%l%d][XY]$") then return "layout" end
    return "look"
end

-- Memoised: the apply drain asks it for every linked key on every write.
local aspectCache = {}
function Links.Aspect(key)
    if type(key) ~= "string" then return "look" end
    local a = aspectCache[key]
    if not a then
        a = Classify(key)
        aspectCache[key] = a
    end
    return a
end

-- ============================================================
-- THE MIRROR (pure, self-inverse)
-- A mirrored copy swaps LEFT and RIGHT inside a layout string (TOPLEFT <->
-- TOPRIGHT, LEFT_UP <-> RIGHT_UP, INSIDE_LEFT <-> INSIDE_RIGHT) and negates a
-- horizontal number (OffsetX, a bare ...X). Vertical values never change.
-- NEVER flipped, though some would match: anything a look key (shadow offsets,
-- gradient directions, border-animation axes -- Aspect says look), anything
-- vertical, and the inside-an-icon placements below.
-- ============================================================
-- A piece's INNER arrangement stays put: mirroring the frame moves the aura
-- icons, it does not turn each icon round (the stack count stays bottom-right).
Links.MIRROR_KEEP = { "Stack", "Duration", "Caster", "DispelSymbol", "ImportantBadge", "IconTimer" }
-- Belt and braces: never flipped whatever Aspect says.
Links.NEVER_FLIP = { "ShadowOffset", "GradientDirection", "BorderAnimation" }

local function Contains(key, parts)
    for _, p in ipairs(parts) do
        if key:find(p, 1, true) then return true end
    end
    return false
end

-- A placeholder no setting value contains, built rather than written as an
-- escape (an escape is one layer of quoting away from being something else).
local SWAP_MARK = string.char(1)
local function SwapLR(s)
    if not (s:find("LEFT", 1, true) or s:find("RIGHT", 1, true)) then return s end
    return (s:gsub("LEFT", SWAP_MARK):gsub("RIGHT", "LEFT"):gsub(SWAP_MARK, "RIGHT"))
end
Links.SwapLR = SwapLR

-- Can a mirror change this key at all? A layout key that is not vertical (a Y
-- offset or position never changes), not excluded, not inside an icon.
function Links.MirrorFlips(key)
    if type(key) ~= "string" or Links.Aspect(key) ~= "layout" then return false end
    if EndsWith(key, "Y") then return false end
    if Contains(key, Links.NEVER_FLIP) or Contains(key, Links.MIRROR_KEEP) then return false end
    return true
end

-- The ring list's mirror image: each section on the other side, filling the other
-- way round, so both bars still rise from the same end of the ring.
function Links.MirrorRings(list)
    local out = {}
    for i, ring in ipairs(list) do
        local r = {}
        for k, v in pairs(ring) do r[k] = v end
        r.sections = {}
        for j, sec in ipairs(type(ring.sections) == "table" and ring.sections or {}) do
            local s = {}
            for k, v in pairs(sec) do s[k] = v end
            if type(s.position) == "string" then s.position = SwapLR(s.position) end
            s.reverse = (not s.reverse) or nil
            r.sections[j] = s
        end
        out[i] = r
    end
    return out
end

function Links.Mirror(key, v)
    if not Links.MirrorFlips(key) then return v end
    if key == "rings" and type(v) == "table" then return Links.MirrorRings(v) end
    if type(v) == "string" then return SwapLR(v) end
    if type(v) == "number" and EndsWith(key, "X") then
        if v == 0 then return 0 end
        return -v
    end
    return v
end

-- ============================================================
-- CLASS POWER RINGS STAY WITH PLAYER
-- Only Player can draw class power (ClassPower.lua CP.UNITS): on any other unit a
-- class power ring is an empty band that squeezes the rest. So a ring list crossing a
-- link leaves its class power behind, and Player keeps the ones it has. `own` is the
-- ring list `to` has now.
-- ============================================================
Links.CLASSPOWER_UNIT = "player"

local function HasClassPower(ring)
    for _, s in ipairs(type(ring) == "table" and type(ring.sections) == "table" and ring.sections or {}) do
        if type(s) == "table" and s.bar == "CLASSPOWER" then return true end
    end
    return false
end

function Links.RingsFor(list, to, own)
    if type(list) ~= "table" then return list end
    local out, any = {}, false
    if to == Links.CLASSPOWER_UNIT then
        for i, ring in ipairs(list) do
            out[i] = ring
            any = any or HasClassPower(ring)
        end
        if not any and type(own) == "table" then
            for _, ring in ipairs(own) do
                if HasClassPower(ring) then out[#out + 1] = ring end
            end
        end
        return out
    end
    for _, ring in ipairs(list) do
        if HasClassPower(ring) then
            local r, secs = {}, {}
            for k, v in pairs(ring) do r[k] = v end
            for _, s in ipairs(ring.sections) do
                if s.bar ~= "CLASSPOWER" then secs[#secs + 1] = s end
            end
            r.sections = secs
            if #secs > 0 then out[#out + 1] = r end
        else
            out[#out + 1] = ring
        end
    end
    return out
end

-- ============================================================
-- SMALL HELPERS
-- ============================================================
local function DeepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not DeepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
Links.DeepEqual = DeepEqual

local function Copy(v)
    if type(v) == "table" and DF.DeepCopy then return DF:DeepCopy(v) end
    return v
end

function Links.IsUnit(u)
    for _, x in ipairs(UF.UNITS or {}) do if x == u then return true end end
    return false
end

local function UnitRank(u)
    for i, x in ipairs(UF.UNITS or {}) do if x == u then return i end end
    return 999
end

local function Global(root)
    if type(root.global) ~= "table" then root.global = {} end
    return root.global
end

local function Stored(root, unit)
    if type(root.units) ~= "table" then root.units = {} end
    local t = root.units[unit]
    if type(t) ~= "table" then
        t = {}
        root.units[unit] = t
    end
    return t
end

local function Default(unit, key) return UF:GetUnitDefault(unit, key) end

-- rawget: the stored table is plain, but a value must never come from a proxy.
local function Effective(root, unit, key)
    local v = rawget(Stored(root, unit), key)
    if v == nil then v = Default(unit, key) end
    return v
end

-- The live profile's table, or nil before the profile exists.
function Links.LiveRoot()
    local db = DF.db
    local t = db and db.unitframes
    return type(t) == "table" and t or nil
end

-- ============================================================
-- THE LINK TABLE
-- ============================================================
local function LinkTable(root, create)
    local g = Global(root)
    if type(g.unitLinks) ~= "table" then
        if not create then return nil end
        g.unitLinks = {}
    end
    return g.unitLinks
end

-- link, follower, leader for the link `unit` is in (either side), or nil.
function Links:LinkOf(root, unit)
    local t = root and LinkTable(root, false)
    if not (t and unit) then return nil end
    local own = t[unit]
    if type(own) == "table" and Links.IsUnit(own.to) and own.to ~= unit then
        return own, unit, own.to
    end
    for follower, link in pairs(t) do
        if type(link) == "table" and link.to == unit and Links.IsUnit(follower) and follower ~= unit then
            return link, follower, unit
        end
    end
    return nil
end

function Links:Partner(root, unit)
    local link, follower, leader = self:LinkOf(root, unit)
    if not link then return nil end
    return (follower == unit) and leader or follower
end

-- An element's two aspects in a link, normalised: absent / unknown = "own";
-- an element with no layout aspect is "own" on layout; one that cannot mirror
-- (mirror = false) is "same" where "mirror" was asked; look is never "mirror".
function Links.Normalise(elemId, aspects)
    local e = Links.BY_ID[elemId]
    local layout, look = "own", "own"
    if e and type(aspects) == "table" then
        if e.layout and (aspects.layout == "same" or aspects.layout == "mirror") then layout = aspects.layout end
        if layout == "mirror" and e.mirror == false then layout = "same" end
        if aspects.look == "same" then look = "same" end
    end
    return layout, look
end

-- Can this element's layout be mirrored at all?
function Links.CanMirror(elemId)
    local e = Links.BY_ID[elemId]
    return (e and e.layout and e.mirror ~= false) and true or false
end

-- Is this element in the default link's set (the "linked by default" group)?
function Links.IsDefaultElement(elemId)
    return Links.DEFAULT.elements[elemId] ~= nil
end

function Links:Aspects(root, unit, elemId)
    local link = self:LinkOf(root, unit)
    if not link or type(link.elements) ~= "table" then return "own", "own" end
    return Links.Normalise(elemId, link.elements[elemId])
end

-- Is anything of this element linked for `unit`?
function Links:ElementLinked(root, unit, elemId)
    local layout, look = self:Aspects(root, unit, elemId)
    return layout ~= "own" or look ~= "own"
end

-- ============================================================
-- PROPAGATION
-- From `from` to its partner, for every key of every linked element in a
-- shared aspect: the (mirrored, when the layout is) effective value is written
-- where it differs, and dropped from the partner's stored table where it equals
-- the partner's own default -- the stored tables stay sparse, as CopyPage keeps
-- them. NEVER keys and the link's `except` keys never move.
-- Returns how many of the partner's keys changed, and the partner.
-- ============================================================
-- Write `from`'s value for `key` onto `to`'s table `dst`: dropped where it equals `to`'s
-- default, so the tables stay sparse. True when that changed anything.
function Links.WriteKey(root, from, to, dst, key, mode)
    local v = Effective(root, from, key)
    if mode == "mirror" then v = Links.Mirror(key, v) end
    if key == "rings" then v = Links.RingsFor(v, to, Effective(root, to, key)) end
    local cur = rawget(dst, key)
    if v == nil or DeepEqual(v, Default(to, key)) then
        if cur ~= nil then
            dst[key] = nil
            return true
        end
        return false
    end
    if DeepEqual(v, cur) then return false end
    dst[key] = Copy(v)
    return true
end

function Links:ApplyFrom(root, from)
    if type(root) ~= "table" then return 0 end
    local link, follower, leader = self:LinkOf(root, from)
    if not link then return 0 end
    local to = (follower == from) and leader or follower
    local elements = type(link.elements) == "table" and link.elements or {}
    local except = type(link.except) == "table" and link.except or nil

    -- Which elements move, and how.
    local modes, any = {}, false
    for id in pairs(elements) do
        local layout, look = Links.Normalise(id, elements[id])
        if layout ~= "own" or look ~= "own" then
            modes[id] = { layout = layout, look = look }
            any = true
        end
    end
    if not any then return 0, to end

    local src, dst = Stored(root, from), Stored(root, to)
    local keys = {}
    for id in pairs(modes) do
        for _, k in ipairs(Links.StaticKeys(id)) do keys[k] = id end
    end
    for _, t in ipairs({ src, dst }) do
        for k in pairs(t) do
            local id = type(k) == "string" and Links.OwnerOf(k)
            if id and modes[id] then keys[k] = id end
        end
    end

    local changed = 0
    for key, id in pairs(keys) do
        if not (Links.NEVER[key] or (except and except[key])) then
            local m = modes[id]
            local mode = (Links.Aspect(key) == "layout") and m.layout or m.look
            if mode ~= "own" and Links.WriteKey(root, from, to, dst, key, mode) then
                changed = changed + 1
            end
        end
    end
    return changed, to
end

-- One key across, as ApplyFrom moves it. A settings drag (UF:LiveApply): returns the
-- partner when its value changed.
function Links:PushKey(root, from, key)
    if type(root) ~= "table" or Links.NEVER[key] then return nil end
    local link, follower, leader = self:LinkOf(root, from)
    if not link then return nil end
    if type(link.except) == "table" and link.except[key] then return nil end
    local id = Links.OwnerOf(key)
    if not (id and type(link.elements) == "table") then return nil end
    local layout, look = Links.Normalise(id, link.elements[id])
    local mode = (Links.Aspect(key) == "layout") and layout or look
    if mode == "own" then return nil end
    local to = (follower == from) and leader or follower
    if Links.WriteKey(root, from, to, Stored(root, to), key, mode) then return to end
    return nil
end

-- ============================================================
-- MAKING, EDITING AND REMOVING LINKS
-- ============================================================
local function CleanElements(elements)
    local out = {}
    for id, aspects in pairs(type(elements) == "table" and elements or {}) do
        if Links.BY_ID[id] then
            local layout, look = Links.Normalise(id, aspects)
            if layout ~= "own" or look ~= "own" then out[id] = { layout = layout, look = look } end
        end
    end
    return out
end

-- Remove the link `unit` is in (either side). The table stays (seeded marker).
function Links:Unlink(root, unit)
    local t = root and LinkTable(root, false)
    if not t then return false end
    local link, follower = self:LinkOf(root, unit)
    if not link then return false end
    t[follower] = nil
    return true
end

-- Link `follower` to `leader` (each leaves any link it was in), then one full
-- apply leader -> follower. Returns how many of the follower's keys changed.
function Links:SetLink(root, follower, leader, elements, except)
    if follower == leader or not (Links.IsUnit(follower) and Links.IsUnit(leader)) then return nil end
    local t = LinkTable(root, true)
    self:Unlink(root, follower)
    self:Unlink(root, leader)
    t[follower] = { to = leader, elements = CleanElements(elements) }
    if type(except) == "table" and next(except) then t[follower].except = except end
    return (self:ApplyFrom(root, leader))
end

-- Set every listed element's aspects at once (Mirror All / Copy All / Separate
-- All), each normalised (an element with no layout keeps "own"; one that cannot
-- mirror gets "same"), then one full apply leader -> follower.
function Links:SetAll(root, unit, ids, layout, look)
    local link, _, leader = self:LinkOf(root, unit)
    if not link then return nil end
    if type(link.elements) ~= "table" then link.elements = {} end
    for _, id in ipairs(ids or {}) do
        if Links.BY_ID[id] then
            local l, k = Links.Normalise(id, { layout = layout, look = look })
            link.elements[id] = (l ~= "own" or k ~= "own") and { layout = l, look = k } or nil
        end
    end
    return (self:ApplyFrom(root, leader))
end

-- Set one element's aspects in the link `unit` is in, then one full apply
-- leader -> follower.
function Links:SetElement(root, unit, elemId, layout, look)
    local link, _, leader = self:LinkOf(root, unit)
    if not (link and Links.BY_ID[elemId]) then return nil end
    if type(link.elements) ~= "table" then link.elements = {} end
    local l, k = Links.Normalise(elemId, { layout = layout, look = look })
    if l == "own" and k == "own" then
        link.elements[elemId] = nil
    else
        link.elements[elemId] = { layout = l, look = k }
    end
    return (self:ApplyFrom(root, leader))
end

-- ============================================================
-- TEXT: the follower of a mirrored Text link draws its text mirrored
-- (DandersFrames' Text Designer renderer reads frame.dfMirrorText). Both units
-- usually draw ONE template, so the leader draws it as written and the follower
-- as its mirror image.
-- ============================================================
function Links:IsTextMirrored(root, unit)
    local link, follower = self:LinkOf(root, unit)
    if not link or follower ~= unit then return false end
    local layout = Links.Normalise("text", type(link.elements) == "table" and link.elements.text or nil)
    return layout == "mirror"
end

-- ============================================================
-- THE DEFAULT LINK: Target follows Player
-- Layout mirrored, look shared, for the pieces a target frame is the mirror of
-- the player's in: health, power, the ring list, portrait, buffs, debuffs, cast bar,
-- text and border. Frame Style's look (Bars or Ring, ring size) is each frame's own.
-- Everything else -- status icons, unit icons, highlights, fading,
-- tooltips, visibility, the frame's size and fade, absorbs and heal prediction
-- (their anchors follow the health bar's fill, which a mirror does not turn
-- round) -- is each frame's own.
-- Class Power, Defensive Icon, Dispel Overlay and Aura Designer are the
-- player's alone, so they are not in it at all.
-- ============================================================
Links.DEFAULT = {
    follower = "target", leader = "player",
    elements = {
        health   = { layout = "mirror", look = "same" },
        resource = { layout = "mirror", look = "same" },
        rings    = { layout = "mirror", look = "own" },
        portrait = { layout = "mirror", look = "same" },
        buffs    = { layout = "mirror", look = "same" },
        debuffs  = { layout = "mirror", look = "same" },
        castbar  = { layout = "mirror", look = "same" },
        text     = { layout = "mirror", look = "same" },
        border   = { layout = "own",    look = "same" },   -- no layout aspect
    },
}

-- The keys of a link's shared aspects whose two DEFAULTS deliberately differ
-- (after the mirror, for a mirrored layout): the follower keeps its own. For
-- Player/Target that is health colour mode, the enemy aura filters, showing
-- buffs at all, and the cast bar's detach and latency.
function Links.DeliberateDifferences(follower, leader, elements)
    local out = {}
    for id, aspects in pairs(elements) do
        local layout, look = Links.Normalise(id, aspects)
        for _, key in ipairs(Links.StaticKeys(id)) do
            local mode = (Links.Aspect(key) == "layout") and layout or look
            if mode ~= "own" then
                local want = Default(leader, key)
                if mode == "mirror" then want = Links.Mirror(key, want) end
                if key == "rings" then want = Links.RingsFor(want, follower, Default(follower, key)) end
                if not DeepEqual(want, Default(follower, key)) then out[key] = true end
            end
        end
    end
    return out
end

-- A new link's starting point, for any pair: the default link's pieces linked
-- and the rest separate. Player and Target (either way round) start exactly as
-- the default link does -- mirrored, each keeping its deliberate own defaults
-- (except); any other pair shares the same pieces unmirrored and keeps nothing
-- apart. Returns elements, except.
function Links.StartingElements(follower, leader)
    local d = Links.DEFAULT
    local pair = (follower == d.follower and leader == d.leader) or (follower == d.leader and leader == d.follower)
    if pair then
        return d.elements, Links.DeliberateDifferences(follower, leader, d.elements)
    end
    local els = {}
    for id, aspects in pairs(d.elements) do
        local e = Links.BY_ID[id]
        els[id] = { layout = (e and e.layout and aspects.layout ~= "own") and "same" or "own", look = aspects.look }
    end
    return els, nil
end

function Links:CreateDefault(root)
    local d = Links.DEFAULT
    if self:LinkOf(root, d.follower) or self:LinkOf(root, d.leader) then return false end
    local except = Links.DeliberateDifferences(d.follower, d.leader, d.elements)
    self:SetLink(root, d.follower, d.leader, d.elements, except)
    return true
end

-- The follower's defaults, mirrored from the leader's for the layout keys the
-- mirror moves (Defaults.lua, at load), so a fresh profile's default link has
-- nothing to store and a Reset on either side lands the other on its default.
-- `explicit`: keys the follower sets on purpose, left alone.
function Links.MirrorDefaults(leaderDefaults, followerDefaults, explicit, elements)
    local n = 0
    for id, aspects in pairs(elements) do
        local layout = Links.Normalise(id, aspects)
        if layout == "mirror" then
            for _, key in ipairs(Links.StaticKeys(id)) do
                -- Not the ring list: class power stays with Player, so Defaults.lua sets
                -- Target's own.
                if Links.Aspect(key) == "layout" and not Links.LAYOUT_KEYS[key]
                    and not (explicit and explicit[key] ~= nil) then
                    local v = leaderDefaults[key]
                    if v == nil and DF.PartyDefaults then v = DF.PartyDefaults[key] end
                    local m = Links.Mirror(key, v)
                    if v ~= nil and not DeepEqual(m, v) then
                        followerDefaults[key] = m
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

-- ============================================================
-- MIGRATION: the per-page sync (global.syncedPages[kind][unit] = partner, both
-- ways) becomes unit links -- the synced pages' elements same / same, the rest
-- own -- and syncedPages goes. A unit synced with two others keeps the pair with
-- more pages (ties: the earlier pair in unit order). Idempotent.
-- ============================================================
function Links:Migrate(root)
    local g = Global(root)
    local sp = g.syncedPages
    if sp == nil then return 0 end
    g.syncedPages = nil
    if type(sp) ~= "table" then return 0 end
    local byPair, order = {}, {}
    for kind, map in pairs(sp) do
        if type(map) == "table" then
            for u, p in pairs(map) do
                if Links.IsUnit(u) and Links.IsUnit(p) and u ~= p and map[p] == u then
                    local a, b = u, p
                    if UnitRank(b) < UnitRank(a) then a, b = b, a end
                    local key = a .. "|" .. b
                    local rec = byPair[key]
                    if not rec then
                        rec = { leader = a, follower = b, kinds = {}, n = 0, key = key }
                        byPair[key] = rec
                        order[#order + 1] = rec
                    end
                    if not rec.kinds[kind] then rec.kinds[kind] = true; rec.n = rec.n + 1 end
                end
            end
        end
    end
    tsort(order, function(x, y)
        if x.n ~= y.n then return x.n > y.n end
        return x.key < y.key
    end)
    local t = LinkTable(root, true)
    local made = 0
    for _, rec in ipairs(order) do
        if not (self:LinkOf(root, rec.leader) or self:LinkOf(root, rec.follower)) then
            local elements = {}
            for kind in pairs(rec.kinds) do
                for _, e in ipairs(Links.ElementsForKind(kind)) do
                    elements[e.id] = { layout = e.layout and "same" or "own", look = "same" }
                end
            end
            -- No apply: synced pages already hold the same values.
            t[rec.follower] = { to = rec.leader, elements = CleanElements(elements) }
            made = made + 1
        end
    end
    return made
end

-- ============================================================
-- ONE-TIME REPAIR (unitLinksVersion 2): the first build's Linked Frames card
-- made the frame being edited the FOLLOWER, so linking Target from Player's side
-- stored "Player follows Target" -- the default pair the wrong way round, with
-- Player drawing the mirrored text and the page reading "Player is a mirror
-- image of Target". Turned round once, keeping its parts and kept keys; the two
-- frames are already in step, so nothing is copied. After this a Player-follows-
-- Target link is the user's own choice and is left alone.
-- ⚠ EACH ONE-TIME STEP CHECKS ITS OWN VERSION, never Links.VERSION: bumping the
-- current version for a later step must not run an earlier one a second time (this
-- one would turn a Player-follows-Target link the user made since round again).
-- ============================================================
Links.VERSION = 5
function Links:RepairOrientation(root)
    local g = Global(root)
    if (tonumber(g.unitLinksVersion) or 1) >= 2 then return false end
    g.unitLinksVersion = 2
    local t = g.unitLinks
    local d = Links.DEFAULT
    local link = type(t) == "table" and t[d.leader]
    if type(link) == "table" and link.to == d.follower and t[d.follower] == nil then
        t[d.follower] = { to = d.leader, elements = link.elements, except = link.except }
        t[d.leader] = nil
        return true
    end
    return false
end

-- ============================================================
-- ONE-TIME CLEAN-UP (unitLinksVersion 4). Version 3 kept the aura rows' vertical
-- offsets apart on a Player/Target link, for a layout that stacked the rows in a
-- different order on each frame. The rows are now buffs above and debuffs below on
-- both frames, with the same offsets, so the two keys are shared again: they come
-- back out of the link's kept keys once -- only where they really are no longer a
-- deliberate difference, so a link that keeps them for some other reason keeps
-- them. Nothing is copied. A profile that never reached version 3 has nothing to
-- take out. (Version 3's own step is gone; its number stays spent.)
-- ============================================================
Links.RETIRED_KEPT_V4 = { "buffOffsetY", "debuffOffsetY" }
function Links:DropRetiredKept(root)
    local g = Global(root)
    if (tonumber(g.unitLinksVersion) or 1) >= 4 then return 0 end
    g.unitLinksVersion = 4
    local d = Links.DEFAULT
    local link, follower, leader = self:LinkOf(root, d.follower)
    local pair = link and ((follower == d.follower and leader == d.leader)
        or (follower == d.leader and leader == d.follower))
    if not pair or type(link.except) ~= "table" then return 0 end
    local differ = type(link.elements) == "table"
        and Links.DeliberateDifferences(follower, leader, link.elements) or {}
    local dropped = 0
    for _, key in ipairs(Links.RETIRED_KEPT_V4) do
        if link.except[key] and not differ[key] then
            link.except[key] = nil
            dropped = dropped + 1
        end
    end
    -- A link keeps no `except` table when it keeps nothing (SetLink's shape).
    if next(link.except) == nil then link.except = nil end
    return dropped
end

-- ============================================================
-- ONE-TIME STEP (unitLinksVersion 5). The ring list joined the default link, mirrored.
-- A Player/Target link made before that gets it once, and the follower takes the
-- leader's rings mirrored. A pair that isn't Player/Target is the user's own.
-- ============================================================
function Links:AddRingsToDefault(root)
    local g = Global(root)
    if (tonumber(g.unitLinksVersion) or 1) >= 5 then return false end
    g.unitLinksVersion = 5
    local d = Links.DEFAULT
    local link, follower, leader = self:LinkOf(root, d.follower)
    local pair = link and ((follower == d.follower and leader == d.leader)
        or (follower == d.leader and leader == d.follower))
    if not pair then return false end
    if type(link.elements) ~= "table" then link.elements = {} end
    local cur = link.elements.rings
    link.elements.rings = { layout = "mirror", look = (type(cur) == "table" and cur.look == "same") and "same" or "own" }
    local v = Links.RingsFor(Links.Mirror("rings", Effective(root, leader, "rings")), follower,
        Effective(root, follower, "rings"))
    local dst = Stored(root, follower)
    if DeepEqual(v, Default(follower, "rings")) then dst.rings = nil else dst.rings = Copy(v) end
    return true
end

-- ============================================================
-- ENSURE: migrate, then the default link on a profile that never had links.
-- Safe to run any number of times, on any stored profile's table.
-- ============================================================
function Links:Ensure(root)
    if type(root) ~= "table" then return end
    local g = Global(root)
    local first = (g.unitLinks == nil)
    if type(g.unitLinks) ~= "table" then g.unitLinks = {} end
    self:Migrate(root)
    self:RepairOrientation(root)
    self:DropRetiredKept(root)
    self:AddRingsToDefault(root)
    if first then self:CreateDefault(root) end
end

-- ============================================================
-- THE FRAMES' FLAG
-- ============================================================
function UF:IsTextMirrored(unit)
    local root = Links.LiveRoot()
    return root and Links:IsTextMirrored(root, unit) or false
end
