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
load_uf_file_into("Elements.lua", UF)
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
    eq(Links.OwnerOf("restingIconAnimate"), "unitIcons", "the resting ZZZ's Animate rides the Unit Icons link")
    eq(Links.OwnerOf("restingIconGlow"), "unitIcons", "...and its Glow")
    eq(Links.OwnerOf("restingIconGlowPortrait"), "unitIcons", "...and the glow's Include Portrait")
    eq(Links.Mirror("restingIconGlowPortrait", true), true, "...a boolean a mirror never touches")
    eq(Links.Aspect("restingIconAnimate"), "look", "...both look, not layout")
    eq(Links.Aspect("restingIconGlow"), "look", "...")
    eq(Links.Mirror("restingIconGlow", true), true, "a mirror never touches a boolean")
    eq(Links.Mirror("restingIconAnimate", false), false, "...either way")
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
    -- 162 = 157 + the classification dragon's side, x, y and tail x (reviewed: all
    -- four move with the frame's end) + its Anchor To (portrait / frame: where it sits).
    -- 167 = 166 + the ring list (which side each ring bar sits on).
    -- 166 = 162 + the detached resource bar's switch, anchor, x and y (where it sits;
    -- its size and Match Frame Width are look).
    eq(#layout, 167, "the layout set is the size it was reviewed at (167 keys); a change here wants a look")
    for _, k in ipairs({ "resourceBarDetached", "resourceBarDetachedAnchor", "resourceBarDetachedX",
                         "resourceBarDetachedY" }) do
        eq(Links.Aspect(k), "layout", "layout: " .. k)
        eq(Links.OwnerOf(k), "resource", "Resource Bar owns " .. k)
    end
    for _, k in ipairs({ "resourceBarDetachedMatchWidth", "resourceBarDetachedWidth", "resourceBarDetachedHeight" }) do
        eq(Links.Aspect(k), "look", "look: " .. k)
    end
    eq(Links.Mirror("resourceBarDetachedAnchor", "BOTTOMLEFT"), "BOTTOMRIGHT", "mirror: a detached bar's anchor swaps sides")
    eq(Links.Mirror("resourceBarDetachedX", 12), -12, "mirror: ...and its x")

    -- The classification dragon / border: the Unit Icons element, layout = where it sits.
    for _, k in ipairs({ "classDragonEnabled", "classDragonSize", "classDragonSide", "classDragonX",
                         "classDragonY", "classDragonTailX", "classDragonElite", "classDragonBossColor",
                         "classBorderEnabled", "classBorderSize" }) do
        eq(Links.OwnerOf(k), "unitIcons", "Unit Icons owns " .. k)
    end
    eq(Links.OwnerOf("classDragonAnchor"), "unitIcons", "Unit Icons owns classDragonAnchor")
    for _, k in ipairs({ "classDragonAnchor", "classDragonSide", "classDragonX", "classDragonY", "classDragonTailX" }) do
        eq(Links.Aspect(k), "layout", "layout: " .. k)
    end
    for _, k in ipairs({ "classDragonEnabled", "classDragonSize", "classDragonRareElite",
                         "classDragonEliteColor", "classBorderEnabled", "classBorderSize" }) do
        eq(Links.Aspect(k), "look", "look: " .. k)
    end
    eq(Links.OwnerOf("combatIconBorderSize"), "icons", "the combat icon's border: the Icons element (DF's page)")
    eq(Links.Aspect("combatIconBorderColor"), "look", "...a look key")
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
    eq(M("classDragonSide", "RIGHT"), "LEFT", "the dragon: right end -> left end")
    eq(M("classDragonSide", "LEFT"), "RIGHT", "...left -> right")
    eq(M("classDragonSide", "BOTH"), "BOTH", "...both stays both")
    eq(M("classDragonSide", "OUTER"), "OUTER", "...outer stays outer (already relative to the portrait)")
    eq(M("classDragonAnchor", "PORTRAIT"), "PORTRAIT", "...the anchor copies unchanged")
    eq(M("classDragonX", 5), -5, "the dragon's x negates")
    eq(M("classDragonTailX", -2), 2, "...and the tail's")
    eq(M("classDragonY", 3), 3, "...its y never changes")
    eq(M("classDragonEliteColor", { r = 1 }).r, 1, "...its colours are look")
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
    check(Links.NEVER.castbarEnabled == true, "a cast bar's on/off stays per frame")
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
-- 4b. PARTS THAT CANNOT MIRROR, AND SETTING EVERY PART AT ONCE
-- ============================================================
print("-- Links: no mirror for Absorbs, Heal Prediction and Tooltips; Mirror / Copy / Separate All")
do
    for _, id in ipairs({ "absorbs", "healpred", "tooltips" }) do
        eq(Links.BY_ID[id].mirror, false, id .. ": flagged mirror = false")
        eq(Links.CanMirror(id), false, id .. ": cannot mirror")
        eq((Links.Normalise(id, { layout = "mirror", look = "own" })), "same", id .. ": a mirror asked for reads as same")
    end
    eq(Links.CanMirror("health"), true, "health can mirror")
    eq(Links.CanMirror("text"), true, "text can mirror (drawn mirrored)")
    eq(Links.CanMirror("border"), false, "border has no layout to mirror")
    local cannot = {}
    for _, e in ipairs(Links.ELEMENTS) do
        if e.layout and not Links.CanMirror(e.id) then cannot[#cannot + 1] = e.id end
    end
    table.sort(cannot)
    eq(table.concat(cannot, ","), "absorbs,healpred,tooltips", "exactly those three have a layout that cannot mirror")

    local root = newProfile()
    root.global.unitLinks = {}
    local U = root.units
    Links:SetLink(root, "focus", "target", { absorbs = { layout = "mirror", look = "own" } })
    eq(root.global.unitLinks.focus.elements.absorbs.layout, "same", "SetLink stores a mirror asked for as same")
    U.target.absorbBarAnchor = "TOPLEFT"
    U.target.absorbBarX = 7
    Links:ApplyFrom(root, "target")
    eq(U.focus.absorbBarAnchor, "TOPLEFT", "...and copies its anchor unflipped")
    eq(U.focus.absorbBarX, 7, "...and its x unnegated")
    -- A "mirror" already stored (an older build, an import) acts as same.
    root.global.unitLinks.focus.elements.tooltips = { layout = "mirror", look = "own" }
    U.target.tooltipFrameAnchorPos = "TOPLEFT"
    Links:ApplyFrom(root, "target")
    eq(U.focus.tooltipFrameAnchorPos, "TOPLEFT", "a stored mirror on Tooltips copies as same")
    Links:SetElement(root, "focus", "healpred", "mirror", "same")
    eq(root.global.unitLinks.focus.elements.healpred.layout, "same", "SetElement: mirror becomes same too")

    -- Mirror All / Copy All / Separate All.
    local ids = { "health", "absorbs", "border", "tooltips", "text" }
    Links:SetAll(root, "focus", ids, "mirror", "same")
    local el = root.global.unitLinks.focus.elements
    eq(el.health.layout .. "/" .. el.health.look, "mirror/same", "Mirror All: health mirrored, shared")
    eq(el.absorbs.layout, "same", "Mirror All: absorbs' position is same, never mirrored")
    eq(el.tooltips.layout, "same", "Mirror All: tooltips' position is same")
    eq(el.border.layout .. "/" .. el.border.look, "own/same", "Mirror All: border shares its look (no layout)")
    eq(Links:IsTextMirrored(root, "focus"), true, "Mirror All: the follower's text draws mirrored")
    Links:SetAll(root, "focus", ids, "same", "same")
    eq(root.global.unitLinks.focus.elements.health.layout, "same", "Copy All: nothing flipped")
    eq(Links:IsTextMirrored(root, "focus"), false, "Copy All: text drawn as written")
    Links:SetAll(root, "focus", ids, "own", "own")
    eq(keys(root.global.unitLinks.focus.elements), "healpred", "Separate All: the listed parts leave the link")
    check(Links:LinkOf(root, "focus") ~= nil, "...and the link itself stays")
    eq(Links:SetAll(root, "player", ids, "same", "same"), nil, "SetAll on an unlinked unit: nothing")

    -- A new link's starting point.
    local els, except = Links.StartingElements("target", "player")
    eq(els, Links.DEFAULT.elements, "Player + Target: the default link's shape")
    check(except and except.healthColorMode, "...keeping Target's deliberate own defaults")
    els, except = Links.StartingElements("player", "target")
    eq(els, Links.DEFAULT.elements, "...either way round")
    els, except = Links.StartingElements("focus", "target")
    eq(keys(els), keys(Links.DEFAULT.elements), "any other pair: the same pieces linked by default")
    eq(els.health.layout .. "/" .. els.health.look, "same/same", "...shared, not mirrored")
    eq(els.border.layout .. "/" .. els.border.look, "own/same", "...the border's look only")
    eq(except, nil, "...and nothing kept apart")
    eq(Links.IsDefaultElement("health"), true, "health is linked by default")
    eq(Links.IsDefaultElement("absorbs"), false, "absorbs is separate by default")
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
    eq(T.buffAnchor, "TOPLEFT", "target default: buff anchor mirrored")
    eq(T.debuffGrowth, "RIGHT_DOWN", "target default: debuffs too")
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
    eq(keys(link.elements), "border,buffs,castbar,debuffs,health,portrait,resource,rings,text", "...on the nine pieces")
    eq(link.elements.health.layout .. "/" .. link.elements.health.look, "mirror/same", "...layout mirrored, look shared")
    eq(link.elements.border.layout .. "/" .. link.elements.border.look, "own/same", "...the border has no layout")
    -- buffPurgeableEnabled: on for the enemy frames only (Target's default; Player never glows).
    eq(keys(link.except), "buffPurgeableEnabled,castbarDetached,castbarLatency,debuffFilterBoss,debuffFilterCrowdControl,"
        .. "debuffFilterDispellable,debuffFilterMine,debuffFilterPriority,debuffFilterRole,"
        .. "directBuffOnlyMine,directBuffShowAll,healthColorMode,showBuffs",
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
-- 5b. THE ONE-TIME ORIENTATION REPAIR
-- ============================================================
print("-- Links: a Player-follows-Target link from the first card is turned round once")
do
    local fresh = newProfile()
    Links:Ensure(fresh)
    eq(fresh.global.unitLinksVersion, Links.VERSION, "a new profile is stamped at the current version")
    eq(fresh.global.unitLinks.target.to, "player", "...with Target following Player")

    -- An older profile: the first card stored the pair backwards.
    local old = newProfile()
    local els = { health = { layout = "mirror", look = "same" }, text = { layout = "mirror", look = "same" } }
    old.global.unitLinks = { player = { to = "target", elements = els, except = { healthColorMode = true } } }
    old.units.player.healthTexture = "Kept"
    Links:Ensure(old)
    local t = old.global.unitLinks
    eq(t.player, nil, "the backwards link is gone")
    eq(t.target and t.target.to, "player", "...Target follows Player now")
    eq(t.target and t.target.elements, els, "...with its own parts")
    check(t.target and t.target.except and t.target.except.healthColorMode, "...and its kept keys")
    eq(old.units.target.healthTexture, nil, "...and nothing copied (the frames were already in step)")
    eq(Links:IsTextMirrored(old, "target"), true, "Target draws the mirrored text again")
    eq(Links:IsTextMirrored(old, "player"), false, "...Player as written")

    -- After the repair, a Player-follows-Target link is the user's choice.
    Links:Unlink(old, "target")
    Links:SetLink(old, "player", "target", els)
    Links:Ensure(old)
    eq(old.global.unitLinks.player and old.global.unitLinks.player.to, "target", "a later Player-follows-Target is left alone")

    -- A backwards pair whose Target already follows someone else is not touched.
    local busy = newProfile()
    busy.global.unitLinks = { player = { to = "target", elements = {} }, focus = { to = "pet", elements = {} } }
    Links:Ensure(busy)
    eq(busy.global.unitLinks.target and busy.global.unitLinks.target.to, "player", "the repair ignores unrelated links")
    eq(busy.global.unitLinks.focus.to, "pet", "...which stay as they are")

    -- A profile already at version 2 with a Player-follows-Target link the user made:
    -- the later top-up step must not run the orientation repair a second time.
    local v2 = newProfile()
    v2.global.unitLinksVersion = 2
    v2.global.unitLinks = { player = { to = "target", elements = { health = { layout = "same", look = "same" } } } }
    Links:Ensure(v2)
    eq(v2.global.unitLinks.player and v2.global.unitLinks.player.to, "target",
        "a version-2 profile's own Player-follows-Target link is left alone")
    eq(v2.global.unitLinksVersion, Links.VERSION, "...and the profile is stamped at the current version")
end

-- ============================================================
-- 5c. AURA ROW DEFAULTS
-- Effective values through the unit's settings chain (stored -> unit defaults ->
-- party defaults), after Links.MirrorDefaults made Target's from Player's. The rows'
-- rects come from the legacy row maths (AuraContainer layoutRow: icon i's ROW corner --
-- the frames' derived rowPoint, else the anchor -- sits on the frame's anchor point,
-- offset + i steps along the growth), which the engine's flow is meant to match -- a
-- model, so the game is the final word.
-- The cast bar reserve under a frame is added at run time (test_uf_castbar.lua).
-- ============================================================
print("-- Unit frames: aura row defaults")
do
    local AXIS = { RIGHT = { 1, 0 }, LEFT = { -1, 0 }, UP = { 0, 1 }, DOWN = { 0, -1 } }
    -- Rects of the first n icons of `prefix`'s row on a w x h frame: { l, r, b, t }
    -- with the frame's bottom-left at 0,0 and y growing up.
    local K = UF.Elements.Kit
    -- `big`: { [i] = size } for icons drawn bigger than the row's (an important debuff).
    local function rowRects(db, prefix, w, h, n, big)
        local s = db[prefix .. "Size"]
        local step = s + db[prefix .. "PaddingX"]
        local stepY = s + db[prefix .. "PaddingY"]
        local anchor = db[prefix .. "Anchor"]
        local growth = db[prefix .. "Growth"]
        local point = K.RowPoint(anchor, growth) or anchor
        local p, q = growth:match("^(%a+)_(%a+)$")
        local wrap = db[prefix .. "Wrap"]
        local ax = anchor:find("LEFT") and 0 or (anchor:find("RIGHT") and w or w / 2)
        local ay = anchor:find("BOTTOM") and 0 or (anchor:find("TOP") and h or h / 2)
        local out = {}
        for i = 1, n do
            local si = (big and big[i]) or s
            local col, row = (i - 1) % wrap, math.floor((i - 1) / wrap)
            local px = ax + db[prefix .. "OffsetX"] + (AXIS[p][1] * col + AXIS[q][1] * row) * step
            local py = ay + db[prefix .. "OffsetY"] + (AXIS[p][2] * col + AXIS[q][2] * row) * stepY
            local l = point:find("LEFT") and px or (point:find("RIGHT") and px - si or px - si / 2)
            local b = point:find("BOTTOM") and py or (point:find("TOP") and py - si or py - si / 2)
            out[i] = { l = l, r = l + si, b = b, t = b + si }
        end
        return out
    end
    local function span(rects)
        local l, r, b, t = math.huge, -math.huge, math.huge, -math.huge
        for _, x in ipairs(rects) do
            l, r, b, t = math.min(l, x.l), math.max(r, x.r), math.min(b, x.b), math.max(t, x.t)
        end
        return l, r, b, t
    end

    local P, T, F = UF:GetUnitDB("player"), UF:GetUnitDB("target"), UF:GetUnitDB("focus")
    local Pet, B = UF:GetUnitDB("pet"), UF:GetUnitDB("boss")

    -- Target: buffs above the frame, debuffs below, both from the left edge.
    eq(T.showBuffs, true, "target: buffs on")
    eq(T.showDebuffs, true, "target: debuffs on")
    eq(T.buffAnchor .. " " .. T.buffGrowth, "TOPLEFT RIGHT_UP", "target: buffs from the top-left, growing right then up")
    eq(T.debuffAnchor .. " " .. T.debuffGrowth, "BOTTOMLEFT RIGHT_DOWN", "target: debuffs from the bottom-left, growing right then down")
    eq(T.buffOffsetX .. "," .. T.buffOffsetY, "0,1", "target: buff row 1px (the gap) above the frame")
    eq(T.debuffOffsetX .. "," .. T.debuffOffsetY, "0,-1", "target: debuff row 1px below")
    eq(K.RowPoint(T.buffAnchor, T.buffGrowth), "BOTTOMLEFT", "target: the buff row hangs by its bottom-left corner")
    eq(K.RowPoint(T.debuffAnchor, T.debuffGrowth), "TOPLEFT", "target: the debuff row by its top-left corner")
    eq(T.buffSize .. "/" .. T.buffPaddingX .. "/" .. T.buffPaddingY .. "/" .. T.buffMax .. "/" .. T.buffWrap,
        "22/1/1/8/8", "target: 22px buffs, spacing 1, 8 to a row")
    eq(T.debuffSize .. "/" .. T.debuffPaddingX .. "/" .. T.debuffPaddingY .. "/" .. T.debuffMax .. "/" .. T.debuffWrap,
        "22/1/1/5/5", "target: 22px debuffs, spacing 1, 5 to a row")
    local tw, th = T.frameWidth, T.frameHeight
    local bl, br, bb = span(rowRects(T, "buff", tw, th, T.buffMax))
    eq(bl, 0, "target: the buff row starts at the frame's left edge")
    check(br <= tw, "target: a full buff row stays inside the frame's width (" .. br .. " <= " .. tw .. ")")
    eq(bb, th + 1, "target: the buff row's bottom is 1px above the frame")
    local dl, dr, _, dt = span(rowRects(T, "debuff", tw, th, T.debuffMax))
    eq(dl, 0, "target: the debuff row starts at the left edge too")
    eq(dt, -1, "target: the debuff row's top is 1px below the frame (before any cast bar reserve)")
    check(dr <= tw, "target: a full debuff row stays inside the frame's width")
    -- More than a row wraps AWAY from the frame: up for buffs, down for debuffs.
    local wide = setmetatable({ buffWrap = 4, debuffWrap = 2 }, { __index = T })
    local _, _, wb2 = span(rowRects(wide, "buff", tw, th, 8))
    eq(wb2, th + 1, "target: a second buff row goes up, never into the frame")
    local _, _, _, wt2 = span(rowRects(wide, "debuff", tw, th, 5))
    eq(wt2, -1, "target: a second debuff row goes down, never into the frame")

    -- Player: Target's mirror. Debuffs below from the RIGHT edge growing left; buffs
    -- (off) above, also from the right.
    eq(P.showBuffs, false, "player: buffs off")
    eq(P.showDebuffs, true, "player: debuffs on")
    eq(P.debuffAnchor .. " " .. P.debuffGrowth, "BOTTOMRIGHT LEFT_DOWN", "player: debuffs from the bottom-right, growing left then down")
    eq(P.buffAnchor .. " " .. P.buffGrowth, "TOPRIGHT LEFT_UP", "player: buffs (when on) from the top-right, growing left then up")
    eq(P.debuffOffsetX .. "," .. P.debuffOffsetY, "0,-1", "player: debuff row 1px below")
    eq(P.buffOffsetX .. "," .. P.buffOffsetY, "0,1", "player: buff row 1px above")
    eq(K.RowPoint(P.debuffAnchor, P.debuffGrowth), "TOPRIGHT", "player: the debuff row hangs by its top-right corner")
    eq(K.RowPoint(P.buffAnchor, P.buffGrowth), "BOTTOMRIGHT", "player: the buff row by its bottom-right corner")
    local pw, ph = P.frameWidth, P.frameHeight
    local pl, pr, _, pt = span(rowRects(P, "debuff", pw, ph, P.debuffMax))
    eq(pr, pw, "player: the debuff row ends at the frame's right edge")
    eq(pt, -1, "player: the debuff row's top is 1px below the frame")
    -- ⚠ The pet frame sits under Player's left half (left edges aligned): a full row of
    -- five 22px debuffs reaches 4px into its column. Pinned so a change is seen.
    eq(pl, 106, "player: a full debuff row's left edge (the pet frame's right edge is at 110)")
    local _, _, pbb = span(rowRects(P, "buff", pw, ph, P.buffMax))
    eq(pbb, ph + 1, "player: buffs (when on) sit 1px above the frame")

    -- The default link: Target's layout IS Player's mirrored, for every row key the
    -- mirror moves; everything else about the rows is shared.
    for _, k in ipairs({ "buffAnchor", "buffGrowth", "buffOffsetX", "buffOffsetY",
                         "debuffAnchor", "debuffGrowth", "debuffOffsetX", "debuffOffsetY" }) do
        eq(T[k], Links.Mirror(k, P[k]), "link: target's " .. k .. " is player's mirrored")
    end
    for _, k in ipairs({ "buffSize", "buffMax", "buffWrap", "buffPaddingX", "buffPaddingY",
                         "debuffSize", "debuffMax", "debuffWrap", "debuffPaddingX", "debuffPaddingY" }) do
        eq(T[k], P[k], "link: " .. k .. " is shared (a look key)")
    end
    local diff = Links.DeliberateDifferences("target", "player", Links.DEFAULT.elements)
    for _, k in ipairs({ "buffAnchor", "buffGrowth", "buffOffsetX", "buffOffsetY", "debuffAnchor", "debuffGrowth",
                         "debuffOffsetX", "debuffOffsetY", "buffSize", "debuffSize", "buffMax", "debuffMax",
                         "buffWrap", "debuffWrap", "buffPaddingX", "debuffPaddingX", "directDebuffShowAll" }) do
        check(not diff[k], "link: " .. k .. " is not kept apart")
    end
    -- Through a real profile: a fresh default link stores nothing, and a Player row
    -- moved arrives on Target (mirrored on the sides, as is up and down).
    local root = newProfile()
    Links:Ensure(root)
    eq(keys(root.units.target) .. "|" .. keys(root.units.player), "|", "link: a fresh profile stores no aura keys")
    root.units.player.debuffOffsetY = -30
    root.units.player.buffOffsetX = -4
    Links:ApplyFrom(root, "player")
    eq(root.units.target.debuffOffsetY, -30, "link: Player's debuff row moved down moves Target's")
    eq(root.units.target.buffOffsetX, 4, "link: Player's buff row nudged left nudges Target's right")

    -- Focus: Target's rows, its own (not linked), 7 buffs to a row. Buffs stay off.
    eq(F.showBuffs, false, "focus: buffs off (unchanged)")
    eq(F.showDebuffs, true, "focus: debuffs on")
    for _, k in ipairs({ "buffAnchor", "buffGrowth", "buffOffsetX", "buffOffsetY", "buffSize", "buffMax",
                         "debuffAnchor", "debuffGrowth", "debuffOffsetX", "debuffOffsetY", "debuffSize", "debuffMax", "debuffWrap" }) do
        eq(F[k], T[k], "focus: " .. k .. " as Target's")
    end
    eq(F.buffWrap, 7, "focus: 7 buffs to a row")
    local _, fr = span(rowRects(F, "buff", F.frameWidth, F.frameHeight, F.buffWrap))
    check(fr <= F.frameWidth, "focus: a full buff row stays inside its narrower frame (" .. fr .. " <= " .. F.frameWidth .. ")")
    local _, fdr = span(rowRects(F, "debuff", F.frameWidth, F.frameHeight, F.debuffMax))
    check(fdr <= F.frameWidth, "focus: and a full debuff row")

    -- Pet: a few debuffs under the frame; no buffs.
    eq(Pet.showBuffs, false, "pet: buffs off")
    eq(Pet.showDebuffs, true, "pet: debuffs on")
    eq(Pet.debuffAnchor .. " " .. Pet.debuffGrowth, "BOTTOMLEFT RIGHT_DOWN", "pet: from the bottom-left, growing right")
    eq(Pet.debuffSize .. "/" .. Pet.debuffPaddingX .. "/" .. Pet.debuffMax .. "/" .. Pet.debuffWrap, "22/1/4/4",
        "pet: four 22px debuffs in one row")
    local ql, qr, _, qt = span(rowRects(Pet, "debuff", Pet.frameWidth, Pet.frameHeight, Pet.debuffMax))
    check(ql == 0 and qr <= Pet.frameWidth, "pet: the row fits under the frame")
    eq(qt, -1, "pet: 1px under the frame")

    -- Target of target and focus target have no aura pages: nothing shows.
    for _, u in ipairs({ "targettarget", "focustarget" }) do
        local d = UF:GetUnitDB(u)
        eq(tostring(d.showBuffs) .. "/" .. tostring(d.showDebuffs), "false/false", u .. ": no auras")
        for _, rec in ipairs(PD.pages) do
            if rec.kind == "buffs" or rec.kind == "debuffs" then
                check(not rec.units[u], u .. ": no " .. rec.kind .. " page to turn them on from")
            end
        end
    end

    -- Boss: debuffs LEFT of the frame, growing left, as tall as the frame; buffs off,
    -- and on the right if turned on.
    eq(B.showBuffs, false, "boss: buffs off")
    eq(B.showDebuffs, true, "boss: debuffs on")
    eq(B.debuffAnchor .. " " .. B.debuffGrowth, "TOPLEFT LEFT_DOWN", "boss: debuffs from the top-left, growing left")
    eq(B.debuffSize, B.frameHeight, "boss: debuff icons as tall as the frame")
    eq(B.debuffPaddingX, 1, "boss: spacing 1")
    local xl, xr, xb, xt = span(rowRects(B, "debuff", B.frameWidth, B.frameHeight, B.debuffMax))
    eq(xr, -1, "boss: the debuff row ends 1px left of the frame")
    eq(xb .. "," .. xt, "0," .. B.frameHeight, "boss: ...and spans the frame's height")
    check(xl < xr, "boss: ...growing left")
    eq(B.buffSize .. "/" .. B.buffPaddingX, "22/1", "boss: buffs (when on) 22px, spacing 1")
    local yl, _, _, yt = span(rowRects(B, "buff", B.frameWidth, B.frameHeight, B.buffMax))
    eq(yl, B.frameWidth + 1, "boss: buffs (when on) start 1px right of the frame")
    eq(yt, B.frameHeight, "boss: ...level with its top")

    -- ALIGNMENT: a row hanging outside an edge is pinned by its corner nearest the
    -- frame (K.RowPoint), so its icons line up on that edge and a bigger icon (an
    -- important debuff, 1.25x) grows AWAY from the frame, never back into it.
    local RP = K.RowPoint
    for _, c in ipairs({
        { "BOTTOMLEFT", "RIGHT_DOWN", "TOPLEFT", "under the frame from the left" },
        { "BOTTOMRIGHT", "LEFT_DOWN", "TOPRIGHT", "under the frame from the right" },
        { "BOTTOMLEFT", "DOWN_RIGHT", "TOPLEFT", "under the frame, a column" },
        { "TOPLEFT", "RIGHT_UP", "BOTTOMLEFT", "above the frame from the left" },
        { "TOPRIGHT", "LEFT_UP", "BOTTOMRIGHT", "above the frame from the right" },
        { "TOPLEFT", "LEFT_DOWN", "TOPRIGHT", "left of the frame (top-aligned)" },
        { "TOPRIGHT", "RIGHT_DOWN", "TOPLEFT", "right of the frame (top-aligned)" },
        { "BOTTOMLEFT", "LEFT_UP", "BOTTOMRIGHT", "left of the frame, bottom-up" },
    }) do
        eq(RP(c[1], c[2]), c[3], "row point, " .. c[4] .. ": " .. c[3])
    end
    for _, c in ipairs({
        { "BOTTOMRIGHT", "LEFT_UP", "inside, bottom-right growing up (the party default)" },
        { "BOTTOMLEFT", "RIGHT_UP", "inside, bottom-left growing up" },
        { "TOPLEFT", "RIGHT_DOWN", "inside, top-left growing down" },
        { "BOTTOM", "RIGHT_DOWN", "an edge midpoint (not a corner)" },
        { "CENTER", "RIGHT_DOWN", "the centre" },
        { "BOTTOMLEFT", "CENTER_DOWN", "centred growth" },
    }) do
        eq(RP(c[1], c[2]), nil, "row point, " .. c[3] .. ": the anchor (as DF always did)")
    end
    eq(RP(nil, "RIGHT_DOWN"), nil, "row point: no anchor, nothing")
    local x0, y0, rp = UF.AuraRowPlacement({}, T, "debuff", T.debuffAnchor, T.debuffGrowth)
    eq(tostring(rp), "TOPLEFT", "the frames' row placement answers the row point")
    eq(x0 .. "," .. y0, "0,0", "...and no reserve without a cast bar module")
    -- Rects with an important icon (1.25x) in the first slot.
    local bigD = { [1] = T.debuffSize * 1.25 }
    local dR = rowRects(T, "debuff", tw, th, 3, bigD)
    eq(dR[1].t .. "," .. dR[2].t, "-1,-1", "target debuffs: a big icon's top lines up with the rest (1px under the frame)")
    check(dR[1].b < dR[2].b, "...and it grows DOWN, away from the frame")
    local bR = rowRects(T, "buff", tw, th, 3, { [1] = T.buffSize * 1.25 })
    eq(bR[1].b .. "," .. bR[2].b, (th + 1) .. "," .. (th + 1), "target buffs: a big icon's bottom lines up (1px above)")
    check(bR[1].t > bR[2].t, "...and it grows UP, away from the frame")
    local pR = rowRects(P, "debuff", pw, ph, 2, { [1] = P.debuffSize * 1.25 })
    eq(pR[1].r .. "," .. pR[1].t, pw .. ",-1", "player debuffs: a big icon at the right edge, top lined up")
    local xR = rowRects(B, "debuff", B.frameWidth, B.frameHeight, 2, { [1] = B.debuffSize * 1.25 })
    eq(xR[1].r .. "," .. xR[1].t, "-1," .. B.frameHeight, "boss debuffs: a big icon stays left of the frame, top lined up")
    check(xR[1].l < xR[2].l + B.debuffSize, "...growing left and down, away from it")

    -- PET: free, a bit bigger, below-left of the player and clear of its debuff row.
    eq(Pet.frameWidth .. "x" .. Pet.frameHeight, "140x30", "pet: 140 x 30")
    local pos = Pet.position
    eq(pos.anchor, nil, "pet: free (not anchored to the player)")
    eq(pos.point .. " " .. pos.x .. "," .. pos.y, "CENTER -365,-242", "pet: its default seat")
    local PP = P.position
    local pLeft, pBottom = PP.x - pw / 2, PP.y - ph / 2
    local petL, petR = pos.x - Pet.frameWidth / 2, pos.x + Pet.frameWidth / 2
    local petT = pos.y + Pet.frameHeight / 2
    local dl2 = span(rowRects(P, "debuff", pw, ph, P.debuffMax))
    local _, _, rowBottom = span(rowRects(P, "debuff", pw, ph, P.debuffMax))
    check(petR <= pLeft + dl2 - 8, "pet: 8px or more left of Player's full debuff row (" .. petR .. " vs " .. (pLeft + dl2) .. ")")
    check(petT < pBottom, "pet: below the player frame (" .. petT .. " < " .. pBottom .. ")")
    check(petT < pBottom - 1, "...and below the player's portrait border")
    check(petL < pLeft, "pet: reaching left of the player (below-left)")
    check(pBottom + rowBottom < petT, "pet: its top is level with the player's debuff row, beside it")
    local cbr = Pet.castbarPosition
    eq(cbr.anchor and cbr.anchor.target, "DandersFrames_UnitFrames:pet", "pet cast bar record: follows the pet")
    eq(cbr.anchor and cbr.anchor.edge, "bottom", "...under it")
    eq(cbr.x .. "," .. cbr.y, pos.x .. "," .. (pos.y - Pet.frameHeight / 2 - 2 - Pet.castbarHeight / 2),
        "...its x/y the solve gives under the new seat")

    -- TARGET OF TARGET clears Target's portrait (on the right, outside).
    eq(T.portraitSide, "RIGHT", "target's portrait: on the right (Player's mirrored)")
    local TTd = UF:GetUnitDB("targettarget")
    local reachT = 2 + T.frameHeight + 1        -- gap + size (= frame height) + border
    local fb = TTd.position.anchor.fallback
    eq(fb.offsetX, reachT, "target of target: the fallback anchor clears the default portrait")
    local tRight = T.position.x + tw / 2
    local totLeft = TTd.position.x - TTd.frameWidth / 2
    eq(totLeft - (tRight + reachT), 2, "target of target: 2px right of the portrait at the default seat")
    eq(TTd.position.y + TTd.frameHeight / 2, T.position.y + th / 2, "...level with the target's top")
    -- Focus target: Focus's portrait is on its left, so its right edge is free.
    local FTd = UF:GetUnitDB("focustarget")
    eq(F.portraitSide or "LEFT", "LEFT", "focus's portrait: on the left")
    eq(FTd.position.anchor.fallback.offsetX, 0, "focus target: nothing to clear by default")
    check(FTd.position.x - FTd.frameWidth / 2 > F.position.x + F.frameWidth / 2,
        "focus target: right of the focus frame")

    -- Filters: Target every caster's debuffs, Focus and Boss yours; buffs all.
    eq(T.directDebuffShowAll, true, "filters: target shows every caster's debuffs")
    for _, u in ipairs({ "focus", "boss" }) do
        local d = UF:GetUnitDB(u)
        eq(tostring(d.directDebuffShowAll) .. "/" .. tostring(d.debuffFilterMine), "false/true",
            "filters: " .. u .. " shows your debuffs only")
    end
    for _, u in ipairs({ "target", "focus", "boss" }) do
        local d = UF:GetUnitDB(u)
        eq(tostring(d.directBuffShowAll) .. "/" .. tostring(d.directBuffOnlyMine), "true/false",
            "filters: " .. u .. " shows every buff")
    end
    -- DandersFrames' default debuff blacklist (Sated, Exhaustion, Temporal Displacement,
    -- Fatigued, deserters, ...) reaches every unit with a debuff row through the chain.
    for _, u in ipairs({ "player", "target", "focus", "pet", "boss" }) do
        local bl = UF:GetUnitDB(u).debuffBlacklist
        check(type(bl) == "table" and bl[57724] and bl[57723] and bl[80354] and bl[160455],
            "filters: " .. u .. " hides Sated / Exhaustion / Temporal Displacement / Fatigued by default")
    end
    check(DF.PartyDefaults.debuffBlacklist[57724] and DF.PartyDefaults.debuffBlacklist[57723],
        "filters: ...the same list party frames use")
end

-- ============================================================
-- 5d. THE ONE-TIME CLEAN-UP OF RETIRED KEPT KEYS (unitLinksVersion 4)
-- ============================================================
print("-- Links: a Player/Target link drops the aura rows' retired kept keys once")
do
    eq(Links.VERSION, 5, "the current link version")
    -- A version-3 profile: its default link kept the rows' vertical offsets apart.
    local old = newProfile()
    Links:Ensure(old)
    local link = old.global.unitLinks.target
    link.except.buffOffsetY, link.except.debuffOffsetY = true, true
    old.global.unitLinksVersion = 3
    Links:Ensure(old)
    eq(link.except.buffOffsetY, nil, "the buff row offset is shared again")
    eq(link.except.debuffOffsetY, nil, "...and the debuff row's")
    check(link.except.healthColorMode and link.except.showBuffs, "...its other kept keys stay")
    eq(old.global.unitLinksVersion, Links.VERSION, "...and the profile is at the current version")
    eq(keys(old.units.target), "", "...nothing copied")
    Links:Ensure(old)
    eq(keys(link.except):find("OffsetY", 1, true), nil, "Ensure again: nothing changes")

    -- Still a deliberate difference (no shipped default makes one, so fake the
    -- default): the key stays kept.
    local keep = newProfile()
    Links:Ensure(keep)
    local kl = keep.global.unitLinks.target
    kl.except.debuffOffsetY = true
    keep.global.unitLinksVersion = 3
    local saveT = UF.UnitDefaults.target.debuffOffsetY
    UF.UnitDefaults.target.debuffOffsetY = -40
    Links:Ensure(keep)
    UF.UnitDefaults.target.debuffOffsetY = saveT
    eq(kl.except.debuffOffsetY, true, "a key that is still a deliberate difference stays kept")

    -- A link that keeps nothing else ends with no except table (SetLink's shape).
    local bare = newProfile()
    bare.global.unitLinks = { target = { to = "player", elements = { buffs = { layout = "mirror", look = "same" } },
                                         except = { buffOffsetY = true } } }
    bare.global.unitLinksVersion = 3
    eq(Links:DropRetiredKept(bare), 1, "one key dropped")
    eq(bare.global.unitLinks.target.except, nil, "...and the empty except table goes")
    eq(Links:DropRetiredKept(bare), 0, "the clean-up runs once")

    -- Unrelated links are not touched.
    local other = newProfile()
    other.global.unitLinks = { focus = { to = "target", elements = { buffs = { layout = "same", look = "same" } },
                                         except = { buffOffsetY = true } } }
    other.global.unitLinksVersion = 3
    eq(Links:DropRetiredKept(other), 0, "a link that is not Player/Target loses nothing")
    eq(other.global.unitLinks.focus.except.buffOffsetY, true, "...and stays as it was")

    -- A version-2 profile skips straight to the current version with nothing to drop.
    local v2 = newProfile()
    Links:Ensure(v2)
    v2.global.unitLinksVersion = 2
    Links:Ensure(v2)
    eq(v2.global.unitLinksVersion, Links.VERSION, "a version-2 profile is stamped at the current version")
end

-- ============================================================
-- 5e. THE RING LIST ACROSS A LINK
-- ============================================================
print("-- Links: a mirrored link puts each ring bar on the other side")
do
    local ring = function(a, b) return { thickness = 16, gap = 0, sections = { a, b } } end
    local HEALTH_L = { bar = "HEALTH", coverage = "HALF", position = "LEFT" }
    local POWER_R = { bar = "POWER", coverage = "HALF", position = "RIGHT", reverse = true }
    local CP_RING = { thickness = 5, gap = 0, sections = { { bar = "CLASSPOWER", coverage = "FULL", position = "TOP" } } }

    eq(Links.Aspect("rings"), "layout", "the ring list is layout")
    eq(Links.Aspect("frameStyle"), "look", "...Bars or Ring is look")
    check(Links.CanMirror("rings"), "the ring list can be mirrored")

    local m = Links.Mirror("rings", { ring(HEALTH_L, POWER_R) })[1].sections
    eq(m[1].position, "RIGHT", "health moves to the right")
    eq(m[1].reverse, true, "...filling the other way round")
    eq(m[2].position, "LEFT", "power moves to the left")
    eq(m[2].reverse, nil, "...filling the other way round")
    eq(HEALTH_L.position, "LEFT", "the source is not touched")
    check(Links.DeepEqual(Links.Mirror("rings", Links.Mirror("rings", { ring(HEALTH_L, POWER_R) })),
        { ring(HEALTH_L, POWER_R) }), "mirroring twice is where it started")
    eq(Links.Mirror("rings", { ring({ bar = "HEALTH", position = "TOPLEFT" }) })[1].sections[1].position, "TOPRIGHT",
        "a corner swaps too")

    -- Class power stays with Player.
    local toTarget = Links.RingsFor({ ring(HEALTH_L, POWER_R), CP_RING }, "target", nil)
    eq(#toTarget, 1, "class power does not cross to Target")
    local mixed = Links.RingsFor({ ring(HEALTH_L, { bar = "CLASSPOWER" }) }, "target", nil)
    eq(#mixed[1].sections, 1, "...a shared ring keeps its other section")
    local toPlayer = Links.RingsFor({ ring(HEALTH_L, POWER_R) }, "player", { ring(HEALTH_L, POWER_R), CP_RING })
    eq(#toPlayer, 2, "Player keeps its class power ring when Target's rings come over")
    eq(toPlayer[2], CP_RING, "...its own one")
    eq(#Links.RingsFor({ CP_RING }, "player", { CP_RING }), 1, "...and never gets two")

    -- The shipped defaults: Target is exactly Player's mirror, so nothing is kept apart.
    local d = Links.DEFAULT
    check(Links.DeliberateDifferences(d.follower, d.leader, d.elements).rings == nil,
        "the default link keeps no ring difference")
    local fresh = newProfile()
    Links:Ensure(fresh)
    eq(rawget(fresh.units.target, "rings"), nil, "a fresh Target stores no rings")
    local tr = UF:GetUnitDefault("target", "rings")
    eq(tr[1].sections[1].position, "RIGHT", "Target's default health is on the right")
    eq(tr[1].sections[2].position, "LEFT", "...its power on the left")
    eq(#tr, 1, "...with no class power ring")

    -- A change on Player reaches Target, mirrored.
    fresh.units.player.rings = { { thickness = 9, gap = 1, sections = {
        { bar = "HEALTH", coverage = "HALF", position = "TOP" } } }, CP_RING }
    Links:ApplyFrom(fresh, "player")
    eq(#fresh.units.target.rings, 1, "Player's edit reaches Target without its class power")
    eq(fresh.units.target.rings[1].thickness, 9, "...thickness and all")
    eq(fresh.units.target.rings[1].sections[1].reverse, true, "...mirrored")
    -- ...and one on Target leaves Player's class power alone.
    fresh.units.target.rings[1].thickness = 12
    Links:ApplyFrom(fresh, "target")
    eq(fresh.units.player.rings[1].thickness, 12, "Target's edit reaches Player")
    eq(#fresh.units.player.rings, 2, "...and Player keeps its class power ring")

    -- A profile from before the step: the link gains the ring list, Target's rings flip.
    local old = newProfile()
    Links:Ensure(old)
    local link = old.global.unitLinks.target
    link.elements.rings = nil
    old.global.unitLinksVersion = 4
    old.units.target.rings = { ring(HEALTH_L, POWER_R), CP_RING }
    old.units.player.rings = { ring(HEALTH_L, POWER_R), CP_RING }
    old.units.player.rings[1].thickness = 14
    Links:Ensure(old)
    eq(old.global.unitLinksVersion, 5, "the step stamps version 5")
    eq(link.elements.rings.layout, "mirror", "the ring list joins the link, mirrored")
    eq(link.elements.rings.look, "own", "...Bars or Ring stays each frame's own")
    eq(old.units.target.rings[1].sections[1].position, "RIGHT", "Target's health flips")
    eq(#old.units.target.rings, 1, "...and its empty class power band goes")
    old.units.target.rings[1].thickness = 3
    Links:Ensure(old)
    eq(old.units.target.rings[1].thickness, 3, "the step runs once")

    -- Exactly Player's default: Target's stored copy goes (sparse), and it reads its own.
    local same = newProfile()
    Links:Ensure(same)
    same.global.unitLinks.target.elements.rings = nil
    same.global.unitLinksVersion = 4
    same.units.target.rings = { ring(HEALTH_L, POWER_R) }
    Links:Ensure(same)
    eq(rawget(same.units.target, "rings"), nil, "a Target that lands on its default stores nothing")

    -- One key across, mid-drag.
    local pk = newProfile()
    Links:Ensure(pk)
    pk.units.player.rings = { ring(HEALTH_L, POWER_R), CP_RING }
    pk.units.player.rings[1].thickness = 11
    eq(Links:PushKey(pk, "player", "rings"), "target", "PushKey: a linked key moves, and names the partner")
    eq(pk.units.target.rings[1].thickness, 11, "...its value")
    eq(pk.units.target.rings[1].sections[1].position, "RIGHT", "...mirrored")
    eq(Links:PushKey(pk, "player", "rings"), nil, "...and nothing to do the second time")
    eq(Links:PushKey(pk, "focus", "rings"), nil, "a unit with no link: nothing")
    eq(Links:PushKey(pk, "player", "unknownKey"), nil, "a key no part owns: nothing")
    pk.global.unitLinks.target.except = { rings = true }
    pk.units.player.rings[1].thickness = 12
    eq(Links:PushKey(pk, "player", "rings"), nil, "a kept key stays apart")

    -- Unlinked, or another pair: left alone.
    local other = newProfile()
    other.global.unitLinks = { focus = { to = "target", elements = {} } }
    other.global.unitLinksVersion = 4
    eq(Links:AddRingsToDefault(other), false, "a pair that is not Player/Target is left alone")
    eq(other.global.unitLinks.focus.elements.rings, nil, "...with no ring list added")
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
    check(uf_file_source("Units.lua"):find("f.dfAuraRowPlacement = UF.AuraRowPlacement", 1, true),
          "Units: every live unit frame places its aura rows (row corner + cast bar reserve)")
    check(uf_file_source("Preview.lua"):find("f.dfAuraRowPlacement = UF.AuraRowPlacement", 1, true),
          "Preview: every preview frame too")

end

DandersFrames = saved.DandersFrames
CreateFrame, GetLocale, C_Timer = saved.CreateFrame, saved.GetLocale, saved.C_Timer
