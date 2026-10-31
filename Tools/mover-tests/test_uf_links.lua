local NS = ...

-- ============================================================
-- UNIT FRAMES -- LINKED FRAMES
-- DandersFrames_UnitFrames/Links.lua (+ its wiring in Core / Defaults / Units /
-- Preview, and the settings side in DandersFrames_Options/UnitFrames/Pages.lua)
-- ------------------------------------------------------------
-- Runs over the REAL key inventory: DandersFrames' shipped party defaults
-- (Core/Config.lua), the real page prefixes (DF.SECTION_PREFIXES, cut out of
-- GUI/GUI.lua) and the real longest-prefix ownership rule (DF:SectionOwnsKey, cut
-- out of Core/Profile.lua), under the real companion Core / Links / Defaults.
-- ============================================================

local saved = {
    DandersFrames = DandersFrames, CreateFrame = CreateFrame, GetLocale = GetLocale,
    C_Timer = C_Timer,
}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- A top-level block cut out of a source file: from `marker` to the first line
-- that is exactly `closer` after it.
local function cut(src, marker, closer)
    src = src:gsub("\r\n", "\n")
    local s = src:find(marker, 1, true)
    assert(s, "marker not found: " .. marker)
    local e = src:find("\n" .. closer .. "\n", s, true)
    assert(e, "closer not found after: " .. marker)
    return src:sub(s, e + #closer)
end

-- ---- DandersFrames: real defaults, real prefixes, real ownership ------------
local DF = {}
CreateFrame = function() return FakeUIFrame() end
GetLocale = function() return "enUS" end
load_df_file_into("Core/Config.lua", DF)
DandersFrames = DF
DF.L = setmetatable({}, { __index = function(_, k) return k end })
function DF:Debug() end
function DF:DebugWarn() end
function DF:DebugError() end
function DF:DeepCopy(t) return deepcopy(t) end
function DF:RegisterProfileRootTable(key, spec) DF.rootSpec = spec; return true end
DF.RegisterCallback = function() end

local gui = df_file_source("GUI/GUI.lua")
assert(loadstring("local DF = ...\n" .. cut(gui, "DF.SECTION_PREFIXES = {", "}")))(DF)
DF.SectionRegistry = {}
for id, p in pairs(DF.SECTION_PREFIXES) do DF.SectionRegistry[id] = p end
local profile = df_file_source("Core/Profile.lua")
assert(loadstring("local DF = ...\n" .. cut(profile, "function DF:SectionOwnsKey(prefixes, key)", "end")))(DF)
check(type(DF.SECTION_PREFIXES.bars_health) == "table", "inventory: the real page prefixes")
check(type(DF.SectionOwnsKey) == "function", "inventory: the real ownership rule")

-- ---- the companion ----------------------------------------------------------
CreateFrame = nil        -- the companion's file-scope event wiring is skipped
local UF = {}
load_uf_file_into("Core.lua", UF)
load_uf_file_into("Links.lua", UF)
load_uf_file_into("Defaults.lua", UF)
local Links = UF.Links
check(type(Links) == "table", "Links.lua loads")

-- The settings pages' inventory (which unit has which page).
load_options_file_into("UnitFrames/PageData.lua", NS)
local PD = DF.UnitFramePageData

local function newProfile() return deepcopy(UF.ProfileDefaults) end

-- Every key a unit page owns: the inventory the classifier is tested against.
local inventory, invSeen = {}, {}
local function take(t)
    for k in pairs(t) do
        if not invSeen[k] and Links.OwnerOf(k) then invSeen[k] = true; inventory[#inventory + 1] = k end
    end
end
take(DF.PartyDefaults)
for _, t in pairs(UF.UnitDefaults) do take(t) end
table.sort(inventory)

local function keys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, ",")
end

-- ============================================================
-- 1. ELEMENTS AGAINST THE PAGE INVENTORY
-- ============================================================
print("-- Links: elements and pages")
do
    check(#inventory > 900, "inventory: the unit pages own the real key set (" .. #inventory .. " keys)")
    local kinds = {}
    for _, rec in ipairs(PD.pages) do
        kinds[rec.kind] = rec
        eq(Links.KIND_SOURCE[rec.kind], rec.source, "page " .. rec.kind .. ": the source the generated page data names")
        check(#Links.ElementsForKind(rec.kind) >= 1, "page " .. rec.kind .. ": has an element")
    end
    for _, e in ipairs(Links.ELEMENTS) do
        check(kinds[e.kind] ~= nil, "element " .. e.id .. ": its page exists")
    end
    -- Disjoint: every key has exactly one owner.
    local multi = {}
    for _, k in ipairs(inventory) do
        local n = 0
        for _, e in ipairs(Links.ELEMENTS) do if Links.ElementOwns(e, k) then n = n + 1 end end
        if n ~= 1 then multi[#multi + 1] = k end
    end
    eq(table.concat(multi, ","), "", "every owned key belongs to exactly one element")
    for k in pairs(Links.NEVER) do eq(Links.OwnerOf(k), nil, "never linked: " .. k) end
    eq(Links.OwnerOf("frameBorderSize"), "border", "the Frame page's border keys are the Border element")
    eq(Links.OwnerOf("frameShowBorder"), "border", "...the show-border switch too")
    eq(Links.OwnerOf("frameWidth"), "frame", "...and its size is the Frame element")
    eq(Links.OwnerOf("castbarSpellX"), "castbar", "a page new to unit frames owns its own prefix")
    eq(Links.OwnerOf("debuffFilterMine"), "debuffs", "the longest-prefix rule decides between pages")

    -- The layout flag says whether the element HAS a layout aspect.
    for _, e in ipairs(Links.ELEMENTS) do
        local layoutKeys = {}
        for _, k in ipairs(Links.StaticKeys(e.id)) do
            if Links.Aspect(k) == "layout" then layoutKeys[#layoutKeys + 1] = k end
        end
        if e.layoutByFlag then
            eq(#layoutKeys, 0, e.id .. ": layout comes from the frame flag, not keys")
        elseif e.layout then
            check(#layoutKeys > 0, e.id .. ": a layout aspect with keys in it")
        elseif e.id ~= "frame" then
            eq(table.concat(layoutKeys, ","), "", e.id .. ": no layout aspect, no layout keys")
        end
    end
    -- The Frame element's layout keys are the party group's anchor and mover:
    -- nothing a unit frame reads, so it has no layout aspect.
    for _, k in ipairs(Links.StaticKeys("frame")) do
        if Links.Aspect(k) == "layout" then
            check(k:find("^anchor") or k:find("^permanentMover"), "frame layout key is party-only: " .. k)
        end
    end
end

-- ============================================================
-- 2. THE CLASSIFIER, OVER EVERY KEY THE UNIT PAGES OWN
-- ============================================================
print("-- Links: layout or look, over the real inventory")
do
    local layout, look = {}, {}
    for _, k in ipairs(inventory) do
        local a = Links.Aspect(k)
        check(a == "layout" or a == "look", "classified: " .. k)
        if a == "layout" then layout[#layout + 1] = k else look[#look + 1] = k end
    end
    -- Invariants that must hold for every key, not just samples.
    local bad = {}
    for _, k in ipairs(inventory) do
        local a = Links.Aspect(k)
        local suffixLayout = k:find("Anchor$") or k:find("AnchorPos$") or k:find("Point$")
            or (k:find("Position$")) or k:find("Side$") or k:find("Growth$") or k:find("Orientation$")
        if suffixLayout and a ~= "layout" then bad[#bad + 1] = "anchor-like not layout: " .. k end
        if (k:find("Shadow") or k:find("Padding") or k:find("BorderOffset") or k:find("Gradient")
            or k:find("Color") or k:find("Texture") or k:find("Font") or k:find("Alpha")
            or k:find("Size") or k:find("Width") or k:find("Height") or k:find("Enabled")) and a ~= "look" then
            bad[#bad + 1] = "appearance not look: " .. k
        end
        if k:find("[%l%d]X$") and not (k:find("Shadow") or k:find("Padding") or k:find("BorderOffset")
            or k:find("BorderAnimation")) and a ~= "layout" then
            bad[#bad + 1] = "x position not layout: " .. k
        end
    end
    eq(table.concat(bad, "; "), "", "every key: anchors, sides, growth and x/y are layout; appearance is look")

    -- Samples of each rule, by name.
    for _, k in ipairs({ "buffAnchor", "buffGrowth", "buffOffsetX", "debuffOffsetY", "portraitSide",
                         "portraitX", "castbarSpellAnchor", "castbarIconSide", "castbarDetached",
                         "classPowerPosition", "dispelIconPosition", "debuffImportantBadgePoint",
                         "tooltipFrameAnchorPos", "healthOrientation", "bossGrowth", "pvpIconX" }) do
        eq(Links.Aspect(k), "layout", "layout: " .. k)
    end
    for _, k in ipairs({ "buffBorderShadowOffsetX", "frameBorderOffsetX", "defensiveIconBorderAnimationOffsetX",
                         "buffPaddingX", "buffBorderGradientDirection", "defensiveIconBorderAnimationSidesAxis",
                         "buffSize", "castbarHeight", "castbarGap", "buffWrap", "portrait3DRotation",
                         "portraitMirror", "textDesignerPreset", "healthColorMode", "visAlways" }) do
        eq(Links.Aspect(k), "look", "look: " .. k)
    end
    eq(#layout, 157, "the layout set is the size it was reviewed at (157 keys); a change here wants a look")
end

-- ============================================================
-- 3. THE MIRROR
-- ============================================================
print("-- Links: the mirror transform")
do
    local M = Links.Mirror
    eq(M("buffAnchor", "TOPLEFT"), "TOPRIGHT", "TOPLEFT -> TOPRIGHT")
    eq(M("buffAnchor", "BOTTOMRIGHT"), "BOTTOMLEFT", "BOTTOMRIGHT -> BOTTOMLEFT")
    eq(M("castbarIconSide", "LEFT"), "RIGHT", "LEFT -> RIGHT")
    eq(M("buffGrowth", "LEFT_UP"), "RIGHT_UP", "LEFT_UP -> RIGHT_UP")
    eq(M("portraitSide", "INSIDE_LEFT"), "INSIDE_RIGHT", "INSIDE_LEFT -> INSIDE_RIGHT")
    eq(M("defensiveBarGrowth", "CENTER_DOWN"), "CENTER_DOWN", "no side, no change")
    eq(M("castbarSide", "BOTTOM"), "BOTTOM", "a vertical side does not change")
    eq(M("buffOffsetX", -3), 3, "OffsetX negates")
    eq(M("castbarSpellX", 4), -4, "a bare x position negates")
    eq(M("buffOffsetY", 6), 6, "OffsetY never changes")
    eq(M("castbarSpellY", 2), 2, "a y position never changes")
    eq(tostring(M("portraitX", 0)), "0", "zero stays 0, never -0")
    eq(M("castbarDetached", true), true, "a boolean layout key copies unchanged")
    -- Exclusions.
    eq(M("buffBorderShadowOffsetX", 2), 2, "excluded: shadow offsets")
    eq(M("buffBorderGradientDirection", "LEFT"), "LEFT", "excluded: gradient directions")
    eq(M("defensiveIconBorderAnimationSidesAxis", "HORIZONTAL"), "HORIZONTAL", "excluded: border-animation axis")
    eq(M("defensiveIconBorderAnimationOffsetX", 3), 3, "excluded: border-animation offsets")
    eq(M("buffStackAnchor", "BOTTOMRIGHT"), "BOTTOMRIGHT", "excluded: the stack count inside an icon")
    eq(M("buffStackX", 3), 3, "...and its offset")
    eq(M("buffDurationAnchor", "LEFT"), "LEFT", "excluded: the duration inside an icon")
    eq(M("debuffImportantBadgePoint", "TOPRIGHT"), "TOPRIGHT", "excluded: the badge on an icon")
    eq(M("healthColorMode", "LEFT"), "LEFT", "a look key never changes")
    -- Self-inverse and look-safe over every key and every shipped default.
    local broken = {}
    local function probe(k, v)
        if v == nil then return end
        local twice = M(k, M(k, v))
        if not Links.DeepEqual(twice, v) then broken[#broken + 1] = k end
        if Links.Aspect(k) == "look" and not Links.DeepEqual(M(k, v), v) then broken[#broken + 1] = "look:" .. k end
    end
    for _, k in ipairs(inventory) do
        probe(k, DF.PartyDefaults[k])
        for _, t in pairs(UF.UnitDefaults) do probe(k, t[k]) end
        for _, v in ipairs({ "LEFT", "TOPRIGHT", "RIGHT_DOWN", 7, -2.5, 0 }) do probe(k, v) end
    end
    eq(table.concat(broken, ","), "", "self-inverse on every key and value; a look key never moves")
end

-- ============================================================
-- 4. PROPAGATION
-- ============================================================
print("-- Links: propagation")
do
    local root = newProfile()
    root.global.unitLinks = {}          -- seeded, empty: no default link
    Links:Ensure(root)
    eq(keys(root.global.unitLinks), "", "an explicit empty link table makes no default link")
    local U = root.units

    -- same / same
    Links:SetLink(root, "focus", "target", { health = { layout = "same", look = "same" } })
    eq(Links:Partner(root, "focus"), "target", "linked: the follower's partner")
    eq(Links:Partner(root, "target"), "focus", "...and the leader's")
    U.target.healthTexture = "Flat"
    U.target.healthColor = { r = 1, g = 0, b = 0, a = 1 }
    local n = Links:ApplyFrom(root, "target")
    eq(U.focus.healthTexture, "Flat", "same: a look value follows")
    check(U.focus.healthColor ~= U.target.healthColor and U.focus.healthColor.r == 1,
          "same: a table is copied, not shared")
    eq(n, 2, "the count of what changed on the partner")
    eq(Links:ApplyFrom(root, "target"), 0, "nothing differs: nothing written")
    U.target.healthTexture = nil
    Links:ApplyFrom(root, "target")
    eq(U.focus.healthTexture, nil, "equal to the partner's own default: dropped, not stored (sparse)")
    -- Two-way: the follower's edit reaches the leader.
    U.focus.healthTexture = "Glass"
    Links:ApplyFrom(root, "focus")
    eq(U.target.healthTexture, "Glass", "two-way: an edit on the follower flows to the leader")
    -- Own: an element not in the link never moves.
    U.target.frameWidth = 333
    Links:ApplyFrom(root, "target")
    eq(U.focus.frameWidth, nil, "own: an element outside the link stays put")

    -- mirror layout, own look
    Links:SetLink(root, "focus", "player", { portrait = { layout = "mirror", look = "own" } })
    eq(Links:Partner(root, "target"), nil, "re-linking: the follower's old link goes")
    U.player.portraitSide = "INSIDE_LEFT"
    U.player.portraitX = 5
    U.player.portraitY = 3
    U.player.portraitAlpha = 0.5
    Links:ApplyFrom(root, "player")
    eq(U.focus.portraitSide, "INSIDE_RIGHT", "mirror: a side swaps")
    eq(U.focus.portraitX, -5, "mirror: x negates")
    eq(U.focus.portraitY, 3, "mirror: y copies")
    eq(U.focus.portraitAlpha, nil, "look own: the look stays the unit's")
    U.focus.portraitX = 9
    Links:ApplyFrom(root, "focus")
    eq(U.player.portraitX, -9, "mirror, the other way: the follower's edit lands mirrored on the leader")

    -- NEVER keys and except keys
    Links:SetLink(root, "focus", "player", { castbar = { layout = "same", look = "same" } }, { castbarLatency = true })
    U.player.castbarPosition = { point = "CENTER", x = 1, y = 2 }
    U.player.castbarLatency = false
    U.player.castbarHeight = 30
    U.player.source = "Hidden"
    U.focus.castbarPosition = nil
    Links:ApplyFrom(root, "player")
    eq(U.focus.castbarHeight, 30, "a shared key moves...")
    eq(U.focus.castbarPosition, nil, "...a position record never does")
    eq(U.focus.source, nil, "...nor who draws the frame")
    eq(U.focus.castbarLatency, nil, "...nor a key the link keeps per unit (except)")

    -- Aspect edits, unlink.
    Links:SetElement(root, "focus", "castbar", "own", "own")
    eq(Links:ElementLinked(root, "focus", "castbar"), false, "an element set own/own leaves the link")
    eq(Links:Unlink(root, "player"), true, "unlink from the leader's side")
    eq(Links:Partner(root, "focus"), nil, "...both sides are free")
    check(type(root.global.unitLinks) == "table", "...and the link table stays (the seeded marker)")
    eq(Links:ApplyFrom(root, "player"), 0, "unlinked: nothing propagates")

    -- Normalising: a look can never be mirrored, an element with no layout has none.
    eq(select(2, Links.Normalise("health", { look = "mirror" })), "own", "look 'mirror' is not a thing")
    eq((Links.Normalise("border", { layout = "mirror" })), "own", "an element with no layout aspect has none")
end

-- ============================================================
-- 5. THE DEFAULT LINK
-- ============================================================
print("-- Links: the default link (Target follows Player)")
do
    -- Target's defaults are Player's mirrored, for the mirrored pieces' layout.
    local T, P = UF.UnitDefaults.target, UF.UnitDefaults.player
    eq(T.portraitSide, "RIGHT", "target default: portrait on the right")
    eq(T.buffGrowth, "RIGHT_UP", "target default: buffs grow the other way")
    eq(T.buffAnchor, "BOTTOMLEFT", "target default: buff anchor mirrored")
    eq(T.debuffGrowth, "LEFT_UP", "target default: debuffs too")
    eq(T.castbarSpellAnchor, "RIGHT", "target default: cast bar spell text on the right")
    eq(T.castbarTimerX, 4, "target default: cast bar timer offset mirrored")
    eq(T.castbarIconSide, "RIGHT", "target default: cast bar icon on the right")
    eq(T.buffStackAnchor, P.buffStackAnchor, "target default: an icon's stack count is not turned round")
    eq(T.castbarDetached, false, "target default: its own (deliberate) attached cast bar is kept")
    eq(T.healthColorMode, "CLASS_REACTION", "target default: its own health colour mode is kept")
    eq(UF.UnitDefaults.focus.portraitSide, "LEFT", "focus is not mirrored")

    for id in pairs(Links.DEFAULT.elements) do
        local e = Links.BY_ID[id]
        local rec
        for _, r in ipairs(PD.pages) do if r.kind == e.kind then rec = r end end
        check(rec and rec.units.player and rec.units.target, "default element " .. id .. ": both units have it")
    end

    local root = newProfile()
    Links:Ensure(root)
    local link = root.global.unitLinks.target
    check(link ~= nil, "a profile with no links gets one: Target")
    eq(link and link.to, "player", "...following Player")
    eq(keys(link.elements), "border,buffs,castbar,debuffs,health,portrait,resource,text", "...on the eight pieces")
    eq(link.elements.health.layout .. "/" .. link.elements.health.look, "mirror/same", "...layout mirrored, look shared")
    eq(link.elements.border.layout .. "/" .. link.elements.border.look, "own/same", "...the border has no layout")
    eq(keys(link.except), "castbarDetached,castbarLatency,debuffFilterBoss,debuffFilterCrowdControl,"
        .. "debuffFilterDispellable,debuffFilterMine,debuffFilterPriority,debuffFilterRole,directBuffOnlyMine,"
        .. "directBuffShowAll,directDebuffShowAll,healthColorMode,showBuffs",
        "...keeping Target's deliberate own defaults (enemy aura filters, colour mode, cast bar detach)")
    eq(keys(root.units.target), "", "a fresh profile: the initial apply stores nothing on Target")
    eq(keys(root.units.player), "", "...nor on Player")
    eq(Links:IsTextMirrored(root, "target"), true, "Target draws the shared text template mirrored")
    eq(Links:IsTextMirrored(root, "player"), false, "...Player draws it as written")
    eq(Links:IsTextMirrored(root, "focus"), false, "...an unlinked unit draws it as written")

    -- Ensure again: nothing changes.
    local before = link
    Links:Ensure(root)
    eq(root.global.unitLinks.target, before, "Ensure is idempotent")

    -- An existing profile with Player customised: the initial apply carries it.
    local old = newProfile()
    old.units.player.buffGrowth = "LEFT_DOWN"
    old.units.player.healthTexture = "Smooth"
    old.units.player.healthColorMode = "CUSTOM"
    old.units.player.castbarDetached = true
    Links:Ensure(old)
    eq(old.units.target.buffGrowth, "RIGHT_DOWN", "existing profile: Player's layout arrives mirrored")
    eq(old.units.target.healthTexture, "Smooth", "...its look arrives as is")
    eq(old.units.target.healthColorMode, nil, "...a kept key does not")

    -- Reset symmetry: Target's buff keys back to default -> Player's back to default.
    old.units.target.buffGrowth = nil
    Links:ApplyFrom(old, "target")
    eq(old.units.player.buffGrowth, nil, "a reset on Target lands Player on its own default (dropped, not stored)")

    -- Removing the link is remembered.
    Links:Unlink(root, "target")
    Links:Ensure(root)
    eq(keys(root.global.unitLinks), "", "after the user unlinks, the default is never made again")

    -- Units already linked elsewhere: no default over them.
    local busy = newProfile()
    busy.global.syncedPages = { health = { player = "pet", pet = "player" } }
    Links:Ensure(busy)
    eq(busy.global.unitLinks.target, nil, "Player already linked (migrated): no default link")

    -- The profile-root migrate hook runs it on every stored profile.
    local stored = newProfile()
    UF.MigrateProfileTable(stored)
    check(stored.global.unitLinks and stored.global.unitLinks.target, "the migrate hook makes the default link")
end

-- ============================================================
-- 6. MIGRATING THE PER-PAGE SYNC
-- ============================================================
print("-- Links: migrating the per-page sync")
do
    local root = newProfile()
    root.global.syncedPages = {
        health  = { target = "focus", focus = "target" },
        frame   = { focus = "target", target = "focus" },
        castbar = { player = "pet", pet = "player" },
        buffs   = { target = "boss", boss = "target" },     -- target's second partner: fewer pages, dropped
        bogus   = { player = "nobody" },
    }
    Links:Ensure(root)
    local L = root.global.unitLinks
    eq(root.global.syncedPages, nil, "syncedPages goes")
    eq(L.focus and L.focus.to, "target", "the pair synced on more pages wins: Focus follows Target")
    eq(keys(L.focus.elements), "border,frame,health", "...its synced pages' elements (Frame is two)")
    eq(L.focus.elements.health.layout .. "/" .. L.focus.elements.health.look, "same/same", "...same / same")
    eq(L.focus.elements.frame.layout .. "/" .. L.focus.elements.frame.look, "own/same", "...the Frame has no layout aspect")
    eq(L.pet and L.pet.to, "player", "Pet follows Player (earlier unit leads)")
    eq(keys(L.pet.elements), "castbar", "...on the cast bar")
    eq(L.boss, nil, "Target's other partner is dropped (a unit is in one link)")
    eq(L.target, nil, "...so no default link either (Target and Player are taken)")
    local snapshot = keys(L)
    Links:Ensure(root)
    eq(keys(root.global.unitLinks), snapshot, "migration is idempotent")
end

-- ============================================================
-- 7. WIRING (source shape)
-- ============================================================
print("-- Links: wiring")
do
    local toc = uf_file_source("DandersFrames_UnitFrames.toc"):gsub("\r\n", "\n")
    local c, l, d = toc:find("\nCore.lua\n", 1, true), toc:find("\nLinks.lua\n", 1, true), toc:find("\nDefaults.lua\n", 1, true)
    check(c and l and d and c < l and l < d, "TOC: Core, then Links, then Defaults")
    local core = uf_file_source("Core.lua")
    check(core:find("f.dfMirrorText = UF.IsTextMirrored and UF:IsTextMirrored(f.dfUFUnit) or false", 1, true),
          "Core: every refresh sets the frame's mirrored-text flag")
    check(core:find("if UF.Links then UF.Links:Ensure(Root()) end", 1, true), "Core: init and profile change ensure the links")
    check(uf_file_source("Units.lua"):find("f.dfMirrorText = UF.IsTextMirrored and UF:IsTextMirrored(unit) or false", 1, true),
          "Units: a new frame gets the flag")
    check(uf_file_source("Preview.lua"):find("f.dfMirrorText = UF.IsTextMirrored", 1, true),
          "Preview: a preview frame gets it too")
    check(uf_file_source("Defaults.lua"):find("if UF.Links and UF.Links.Ensure then UF.Links:Ensure(tbl) end", 1, true),
          "Defaults: the profile-root migrate hook ensures the links")

end

DandersFrames = saved.DandersFrames
CreateFrame, GetLocale, C_Timer = saved.CreateFrame, saved.GetLocale, saved.C_Timer
