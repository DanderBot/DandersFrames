-- ============================================================
-- TEST MODE — SECTION LABELS
-- ============================================================
-- "Which bar is this, and which page changes it?" — the question every new user asks
-- of test mode, where every element renders at once. ONE opt-in setting
-- (db.testShowLabels) answers it two ways at once, because nobody wants half:
--
--   * the element under the cursor is HIGHLIGHTED (corner brackets + a faint tint)
--     and TAGGED with its name;
--   * its tooltip names the element and the settings page that owns it — appended to
--     the game's own tooltip where there is one, shown standalone where there is not.
--
-- ☠ ONLY ONE REGION IS EVER MARKED. Marking them all at once was tried and is
-- unreadable at real frame sizes: three tags, three bracket sets and three tints on a
-- 130px frame, with regions that legitimately overlap (an Aura Designer indicator sits
-- inside the buff row). Don't "improve" this by showing everything again.
--
-- ☠ EVERY WIDGET HERE IS DF-OWNED AND ANCHORED **OVER** ITS TARGET, NEVER PARENTED
-- UNDER IT. A frame created as a child of a native aura button inherits its forbidden
-- aspects and access restrictions and can never be styled or scripted again
-- (rules_12_1_engine_constraints). Everything below parents to the unit frame and
-- anchors to the target's rect, which is the standing anchor-proxy pattern.
--
-- ☠ NOTHING HERE MAY TAKE THE MOUSE. An overlay with EnableMouse swallows the aura
-- button's own tooltip — this feature shipped that bug once. Hover is detected by
-- comparing the cursor against cached rects instead.
--
-- Each element is labelled on whichever test frame actually renders it: the preview
-- spreads its samples deliberately (the defensive icon only on a tank/healer slot, the
-- missing-buff badge on another), so the marks spread with them.

local DF = DandersFrames
local L = DF.L
local TL = {}
DF.TestLabels = TL

-- Element identity colours. Deliberately NOT the addon's own semantic colours: these
-- must not be confused with the dispel ring or the important-debuff marker, which are
-- usually the things being judged when test mode is open.
local TARGETS = {
    { key = "buff",      color = { 0.37, 0.76, 0.48 } },
    { key = "debuff",    color = { 0.88, 0.37, 0.42 } },
    { key = "defensive", color = { 0.34, 0.65, 0.85 } },
    { key = "missing",   color = { 0.77, 0.44, 0.79 } },
    { key = "ad",        color = { 0.88, 0.66, 0.29 } },
}

-- Localised at call time, not at file scope: this file loads before the locale refresh
-- on some paths, and a cached English string would survive a locale change.
-- ⚠ The second return is the SETTINGS PAGE, and these strings must stay identical to
-- the CreateSubTab labels in GUI/Pages — a tooltip naming a page that does not exist
-- under that name is worse than no tooltip. (Note "Missing Buffs" is plural on the
-- page while the test toggle beside it is singular; the page wins here.)
local function labelFor(key)
    -- ☠ PLAIN ">" — the game's fonts have no glyph for "▸" (U+25B8) and rendered it as
    -- a filled diamond in game. Nothing else in the addon uses that character; the
    -- breadcrumbs elsewhere are plain ASCII for exactly this reason.
    local auras = L["Auras"] .. " > "
    if key == "buff"      then return L["Buff Bar"],       auras .. L["Buff Bar"] end
    if key == "debuff"    then return L["Debuff Bar"],     auras .. L["Debuff Bar"] end
    if key == "defensive" then return L["Defensive Icon"], auras .. L["Defensive Icon"] end
    if key == "missing"   then return L["Missing Buffs"],  auras .. L["Missing Buffs"] end
    if key == "ad"        then return L["Aura Designer"],  auras .. L["Aura Designer"] end
    return key, ""
end

-- ============================================================
-- TARGET RESOLUTION
-- ============================================================
-- Every row hands back the DF-owned window frame it renders into. A row that is
-- disabled, parked or not previewing has no rect worth labelling, so it drops out
-- here rather than producing a tag pointing at nothing.
-- ☠☠ THE ROW'S REAL RECT CANNOT BE MEASURED. Two dead ends, both learned the hard way:
--   * `handle.frame` is only SIZED in `missing` mode; for the buff / debuff / defensive
--     rows it is a bare anchor ORIGIN the container pins to, so it has no rect at all.
--   * the CustomAuraContainer's own rect is SECRET — `GetRight()` on it returns a secret
--     number and the first subtraction throws ("attempt to perform arithmetic on local
--     'r' (a secret number value)"). The no-rect-math rule covers the container, not
--     just its buttons.
--
-- ★ So the region is obtained the way every other preview surface obtains one: ask the
-- LIVE flow. AuraContainer.FlowSlots pins a box and lays plain DF frames into it with
-- the same AnchorUtil flow, growth, wrap headroom and strip reservation the real
-- container uses — and OUR frames are plain, so their rects are readable. This is the
-- shared entry point the AD canvas uses; its contract says a caller must never
-- substitute maths of its own, and this one does not: when the flow is unavailable the
-- element simply goes unlabelled.
-- ⚠ COST, stated because it scales with the raid preview: one probe box plus `count`
-- slot frames per labelled element per visible test frame — roughly 9 frames a frame,
-- so ~90 at the default 10-frame raid preview and ~360 at a 40-frame one. Pooled and
-- created once, never per pass, and only while the option is on; WoW never frees a
-- frame, so if that ceiling ever matters the fix is to probe fewer frames rather than
-- to rebuild them.
local function ensureProbe(frame, key, count)
    frame.dfTestLabelProbes = frame.dfTestLabelProbes or {}
    local p = frame.dfTestLabelProbes[key]
    if not p then
        local box = CreateFrame("Frame", nil, frame)
        box:SetSize(1, 1)
        p = { box = box, slots = {} }
        frame.dfTestLabelProbes[key] = p
    end
    for i = 1, count do
        local s = p.slots[i]
        if not s then
            s = CreateFrame("Frame", nil, p.box)
            -- Invisible and inert: this is a measuring stick, not art. It must never
            -- take the mouse (that was the tooltip-stealing bug) and never draw.
            s:EnableMouse(false)
            p.slots[i] = s
        end
        s:Show()
    end
    for i = count + 1, #p.slots do p.slots[i]:Hide() end
    return p
end

-- Union of the flowed probe slots = the region the row occupies.
local function flowedRect(frame, key, h)
    local cfg = h and h.config
    if type(cfg) ~= "table" then return nil end
    local FS = DF.AuraContainer and DF.AuraContainer.FlowSlots
    if not FS then return nil end

    -- How many icons the row is actually laying out. _slotCount is the live answer
    -- (it already folds in test mode's count slider and the preview pool cap), so the
    -- box matches what is on screen rather than the configured maximum.
    local okCount, count = pcall(function() return h:_slotCount() end)
    if not okCount then count = nil end
    count = tonumber(count) or tonumber(cfg.max) or 0
    if count < 1 then return nil end

    local p = ensureProbe(frame, key, count)
    p.box:Show()
    -- The slots must carry the row's cell size before flowing: the flow reads each
    -- element's size when the group declares none.
    local L = cfg.layout or {}
    local sx = tonumber(L.sizeX) or tonumber(L.size) or 16
    local sy = tonumber(L.sizeY) or sx

    -- ★ IMPORTANT DEBUFFS RENDER BIGGER, and the box has to contain them (field: the
    -- scaled icon poked out of the highlight). The preview's own choice of WHICH slots
    -- wear a record style is deterministic -- Handle._build's test branch: when every
    -- record carries a style, there is more than one, AND THE STYLES DIFFER, slot k wears
    -- style k; otherwise exactly ONE slot wears the first style -- so the probe mirrors
    -- that rather than guessing, and the measured cells match the rendered ones instead of
    -- being padded to a worst case.
    -- ☠ THE DISTINCTNESS TERM MUST MATCH Frames/AuraContainer.lua's TWO COPIES, where the
    -- long note lives. Without it, two debuff records sharing one importantStyle table read
    -- as a layout group and every slot measures enlarged — the mark would then be sized for
    -- a row that is not what renders, which is the one thing this probe may never do.
    local styles, allStyled, stylesDiffer = {}, true, false
    for _, rec in ipairs(type(cfg.filter) == "table" and cfg.filter or {}) do
        if type(rec) == "table" and rec.style then
            styles[#styles + 1] = rec.style
            if styles[1] ~= rec.style then stylesDiffer = true end
        else
            allStyled = false
        end
    end
    local perSlot = (allStyled and stylesDiffer and #styles > 1) and styles or nil
    local single  = (not perSlot) and styles[1] or nil

    for i = 1, count do
        local s = p.slots[i]
        local style = (perSlot and perSlot[i]) or (single and i == 1 and single) or nil
        -- Stamping the style is what makes the FLOW hand this element the scaled CELL
        -- (its GetElementSize checks dfImpRecStyle), so spacing comes out right...
        s.dfImpRecStyle = style
        -- ...and the element itself is sized the way applyRecordStyle sizes the real
        -- button, so the measured UNION covers the bigger icon rather than just the
        -- space reserved for it.
        local ex, ey = sx, sy
        if style then
            local sz = style.layout and style.layout.size
            if sz then ex, ey = sz, sz end
            local sc = tonumber(style.scale) or 1
            if sc ~= 1 then ex, ey = ex * sc, ey * sc end
        end
        s:SetSize(ex, ey)
    end

    local anchor = (h.GetFrame and h:GetFrame()) or h.frame
    if not anchor then return nil end
    local ok = FS(p.box, anchor, p.slots, count, cfg, h._pp)
    if not ok then return nil end

    local l, r, t, b
    for i = 1, count do
        local s = p.slots[i]
        local sl, sr, st, sb = s:GetLeft(), s:GetRight(), s:GetTop(), s:GetBottom()
        if sl and sr and st and sb then
            l = (l and math.min(l, sl)) or sl
            r = (r and math.max(r, sr)) or sr
            t = (t and math.max(t, st)) or st
            b = (b and math.min(b, sb)) or sb
        end
    end
    if not l or (r - l) < 1 or (t - b) < 1 then return nil end
    return l, r, t, b, anchor
end

-- `missing` mode is the one row whose window IS sized (it is a clip window exactly the
-- badge's size), so it needs no flow probe. Takes a handle OR a plain frame, because
-- the missing-buff STRIP is a bare frame with no handle wrapping it.
local function windowRect(h)
    local f
    if type(h) == "table" and h.GetLeft then
        f = h                                   -- already a frame
    else
        f = (h and h.GetFrame and h:GetFrame()) or (h and h.frame)
    end
    if type(f) ~= "table" or not f.GetLeft then return nil end
    local ok, l, r, t, b = pcall(function()
        if not f:IsShown() then return nil end
        return f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    end)
    if not ok or not l or not r or not t or not b then return nil end
    if (r - l) < 1 or (t - b) < 1 then return nil end
    return l, r, t, b, f
end

local function handleRect(frame, key, h)
    if not h then return nil end
    if (h.config and h.config.mode) == "missing" then return windowRect(h) end
    local l, r, t, b, anchor = flowedRect(frame, key, h)
    if l then return l, r, t, b, anchor end
    return windowRect(h)
end

-- The Aura Designer has no single window: each placed indicator is its own handle in
-- the factory's `placed` store. Label the UNION of their rects, so the tag names the
-- system once instead of once per indicator.
local function adUnionRect(frame)
    local store = frame.dfADFactory
    local placed = store and store.placed
    if type(placed) ~= "table" then return nil end
    local l, r, t, b
    local hosts = {}
    local i = 0
    for _, entry in pairs(placed) do
        i = i + 1
        -- Each placed indicator is its own single-slot handle; give each probe its own
        -- key so they do not share (and overwrite) one measuring box.
        local fl, fr, ft, fb, anchor = handleRect(frame, "ad" .. i, entry and entry.handle)
        if fl then
            l = (l and math.min(l, fl)) or fl
            r = (r and math.max(r, fr)) or fr
            t = (t and math.max(t, ft)) or ft
            b = (b and math.min(b, fb)) or fb
            if anchor then hosts[#hosts + 1] = anchor end
        end
    end
    if not l then return nil end
    return l, r, t, b, hosts
end

-- Returns the rect AND the frame to anchor against. ☠ ANCHOR TO THE TARGET, never to
-- UIParent with these numbers: GetLeft/GetBottom report in the frame's own effective
-- scale, so feeding them to a UIParent anchor misplaces every widget the moment the
-- frames are scaled — which is exactly why the first cut drew its tags in roughly the
-- right place and its outlines nowhere useful. The rect is still returned because the
-- tag-collision pass compares rects, and every rect it compares comes from this same
-- space.
-- Returns rect, the frame to ANCHOR the overlay against, and the list of frames whose
-- tooltips belong to this element. The two are not always the same: the AD union spans
-- several indicator frames, so it anchors to the shared unit frame — and ☠ the unit
-- frame must NEVER be registered as a tooltip host, or every aura on the frame would
-- claim to be an Aura Designer indicator (the parent walk reaches it from everything).
-- ☠ IS THIS ELEMENT ACTUALLY ON SCREEN RIGHT NOW? Two things needed this, and the
-- first cut only did the first:
--   * `flowedRect` measures a row from its CONFIG — it asks the live flow to lay out
--     `_slotCount()` cells — and a row that is switched off still has a perfectly good
--     config, so an unticked Buff Bar or a Defensives-at-0 row measured to a rect and
--     got a mark over empty space.
--   * ☠☠ AND THE ANSWER HAS TO BE RE-ASKED AT HOVER TIME, NOT ONLY AT SCAN TIME. The
--     region list is rebuilt by TL:Update, so a check made only there freezes whatever
--     was on when the list was last built: rows switched off after that kept their
--     marks and rows switched on never got one, which reads exactly as "it only checks
--     what was on when you opened test mode" (Krathe, 2026-08-17). The hover driver
--     therefore re-asks per tick — and that is also why this must be CHEAP.
-- ★ RENDERED STATE, NOT A SHOWN-CACHE and not a re-reading of the test toggles. The
-- first cut used `dfBuffFactoryShown` and friends: correct as far as it went, but it is
-- a description of what a drive last decided, and this asks the frame itself. One read
-- covers every reason a row can be absent — the test toggle, the feature's own setting,
-- the identity gate, the death and cinematic latches — because all of them actuate
-- through the same `SetShown` on the handle's plain anchor frame.
-- ⚠ Fail OPEN on a refused or secret read. A row that is genuinely rendering must never
-- lose its mark because a probe misfired; the failure this guards against is a mark
-- over EMPTY SPACE, which a false positive here cannot produce.
local function elementShown(frame, key)
    if key == "ad" then
        -- The AD has no row frame: Factory:ClearFrame empties `placed`, so an empty
        -- store IS the off state (and adUnionRect then finds no rect anyway).
        local store = frame.dfADFactory
        local placed = store and store.placed
        return type(placed) == "table" and next(placed) ~= nil
    end
    if key == "missing" then
        local s = frame.missingBuffStrip
        return (s and s.IsShown and s:IsShown()) and true or false
    end
    local h = (key == "buff" and frame.buffFactory)
           or (key == "debuff" and frame.debuffFactory)
           or (key == "defensive" and frame.defensiveFactory)
    if not (h and h.GetFrame) then return false end
    -- ☠ A PARENT-DRIVEN handle inherits its host slot's SECRET shown state, so testing
    -- it taints ("attempt to compare a secret boolean"). None of these three are ever
    -- parent-driven — that is for containers nested in another container's slot — so
    -- this is belt-and-braces rather than a live branch.
    if h.config and h.config.parentDrivenVisibility then return true end
    local f = h:GetFrame()
    if not (f and f.IsShown) then return false end
    local ok, shown = pcall(f.IsShown, f)
    if not ok then return true end
    if issecretvalue and issecretvalue(shown) then return true end
    return shown and true or false
end

local function targetOf(frame, key)
    if not elementShown(frame, key) then return nil end
    if key == "ad" then
        local l, r, t, b, hosts = adUnionRect(frame)
        if not l then return nil end
        return l, r, t, b, frame, hosts
    end
    -- ☠ MISSING BUFF IS NOT ONE HANDLE. `frame.missingFactory` is a MAP of spell key
    -- -> handle, one cell per tracked buff, so passing it where a handle is expected
    -- found nothing and the element never labelled at all (field-reported). Its cells
    -- are all parented to `frame.missingBuffStrip`, which IS a plain sized DF frame --
    -- so the strip is both the right region and the right tooltip host: the owner walk
    -- reaches it from any badge inside it.
    if key == "missing" then
        local l, r, t, b, anchor = windowRect(frame.missingBuffStrip)
        if not l then return nil end
        return l, r, t, b, anchor, { anchor }
    end
    local h = (key == "buff" and frame.buffFactory)
           or (key == "debuff" and frame.debuffFactory)
           or (key == "defensive" and frame.defensiveFactory)
    local l, r, t, b, anchor = handleRect(frame, key, h)
    if not l then return nil end
    return l, r, t, b, anchor, { anchor }
end

-- ============================================================
-- WIDGET POOL
-- ============================================================
-- Pooled per unit frame and per element key, so a re-place reuses widgets rather than
-- leaking frames — WoW never frees a frame, and this runs on every settings change.
local function ensureWidgets(frame, key)
    frame.dfTestLabels = frame.dfTestLabels or {}
    local w = frame.dfTestLabels[key]
    if w then return w end

    local host = CreateFrame("Frame", nil, frame)
    -- ☠ ONE STRATA ABOVE THE FRAME'S OWN, not a fixed "HIGH". The first cut pinned HIGH
    -- with a capped level and the outline landed BEHIND the very icons it was meant to
    -- bound — invisible, because it sits exactly on their edges. Strata beats level
    -- across unrelated frames, so derive it rather than guessing a number.
    local order = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
                    FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
    local names = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG",
                    "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
    local at = order[frame:GetFrameStrata() or "MEDIUM"] or 3
    -- Stop below TOOLTIP: that is the game tooltip's own layer, and an outline drawn
    -- over a tooltip is worse than one drawn under an icon.
    host:SetFrameStrata(names[math.min(at + 1, 7)])
    host:SetFrameLevel(20)

    -- ☠ A TEXTURE'S DRAW LAYER ONLY ORDERS IT WITHIN ITS OWN FRAME. Strata wins across
    -- frames, so the "BACKGROUND" tint that used to live on this host was drawing OVER
    -- the icons, not under them — the comment claiming otherwise was simply wrong, and
    -- raising its alpha would have washed out the very art being judged.
    --
    -- So the fill gets its OWN frame UNDER the row. Backing the region rather than
    -- washing it is what makes a section of tightly-packed icons read as one block:
    -- the colour shows in the inflation margin and between the icons while the icons
    -- themselves stay untouched, so it can carry real weight.
    -- ⚠ Its strata/level are DERIVED from the row it backs at place() time (one level
    -- below), never hardcoded — the row's own level moves with the frame's.
    local under = CreateFrame("Frame", nil, frame)
    local fill = under:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()

    -- A much fainter wash ON TOP, purely to tie the backing to the brackets over
    -- opaque icons. Kept low: this one does touch the art.
    local wash = host:CreateTexture(nil, "BACKGROUND")
    wash:SetAllPoints()

    -- ☠ CORNER BRACKETS, NOT A CONTINUOUS BOX. A full rectangle hugging an icon is
    -- exactly what the addon's OWN art looks like -- the dispel ring, the AD border,
    -- the important-debuff marker -- so a coloured box read as another aura state
    -- rather than as an annotation (field: "they blend into the actual borders").
    -- Four L-shaped brackets with open edges are a mark the addon never draws for
    -- content, so they cannot be mistaken for one; it is the crop-marks language,
    -- which is what this overlay actually is.
    -- 8 arms: two per corner (horizontal + vertical).
    local edges = {}
    for i = 1, 8 do edges[i] = host:CreateTexture(nil, "OVERLAY") end

    local tagBG = host:CreateTexture(nil, "OVERLAY", nil, 6)
    tagBG:SetColorTexture(0.05, 0.04, 0.07, 0.88)
    local tag = host:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")

    w = { host = host, under = under, fill = fill, wash = wash,
          edges = edges, tag = tag, tagBG = tagBG }
    frame.dfTestLabels[key] = w
    return w
end

-- The mark is TWO frames (backing under the row, brackets over it), so every
-- show/hide/alpha path has to drive both or the halves separate.
local function setMarkAlpha(w, a)
    if not w then return end
    w.host:SetAlpha(a)
    if w.under then w.under:SetAlpha(a) end
end

local function hideMark(w)
    if not w then return end
    w.host:Hide()
    if w.under then w.under:Hide() end
end

local function hideWidgets(frame)
    local set = frame.dfTestLabels
    if set then
        for _, w in pairs(set) do hideMark(w) end
    end
    -- The measuring probes are invisible either way, but a pooled frame handed back to
    -- live rendering should not keep a flowed box parented to it.
    local probes = frame.dfTestLabelProbes
    if probes then
        for _, p in pairs(probes) do
            for _, s in ipairs(p.slots) do s:Hide() end
            p.box:Hide()
        end
    end
end

-- ============================================================
-- TOOLTIPS — APPEND, NEVER REPLACE
-- ============================================================
-- ☠ NO INVISIBLE HIT FRAME OVER THE ICONS. The first cut laid a mouse-enabled frame
-- across each element to catch hover, which SWALLOWED the mouse before it reached the
-- aura button underneath — so the game's own spell tooltip never appeared and ours
-- showed in its place, anchored to a frame the user could not see. Wrong on both
-- counts: it replaced the information people actually want, and it broke hover on the
-- element it was describing.
--
-- Instead the game tooltip is left entirely alone and simply APPENDED to: when it
-- shows for anything living inside a labelled region, the element name and its
-- settings page are added underneath the spell's own text. Nothing is intercepted,
-- nothing is blocked, and an element that shows no tooltip of its own simply gets none
-- (the outline and tag already identify it).
local regionOf = setmetatable({}, { __mode = "k" })   -- targetFrame -> element key

-- Walk up from the tooltip's owner looking for a registered region. The owner is an
-- aura BUTTON, whose parent chain runs button -> container -> the row's window frame,
-- which is what gets registered. Bounded rather than while-true: a parent cycle would
-- otherwise hang the client, and nothing legitimate is deeper than a few links.
local function regionForOwner(owner)
    local node, depth = owner, 0
    while node and depth < 10 do
        local key = regionOf[node]
        if key then return key end
        local ok, parent = pcall(node.GetParent, node)
        if not ok then return nil end
        node = parent
        depth = depth + 1
    end
    return nil
end

-- Is either test pool asking for labels? One toggle now drives both halves, and the
-- tooltip hook fires from anywhere, so it has to ask both dbs rather than assume a mode.
local function labelsWanted()
    if not (DF.testMode or DF.raidTestMode) then return false end
    if DF.testMode then
        local db = DF.GetDB and DF:GetDB()
        if db and db.testShowLabels then return true end
    end
    if DF.raidTestMode then
        local db = DF.GetRaidDB and DF:GetRaidDB()
        if db and db.testShowLabels then return true end
    end
    return false
end

local hooked = false
local function ensureTooltipHook()
    if hooked then return end
    hooked = true
    GameTooltip:HookScript("OnShow", function(tt)
        if not labelsWanted() then return end
        local ok, owner = pcall(tt.GetOwner, tt)
        if not ok or not owner then return end
        local key = regionForOwner(owner)
        if not key then return end
        local name, page = labelFor(key)
        -- A blank spacer keeps DF's two lines visibly separate from the spell's own
        -- text rather than reading as part of it.
        tt:AddLine(" ")
        tt:AddLine(name, 0.58, 0.51, 0.79)
        if page ~= "" then tt:AddLine(page, 0.62, 0.6, 0.66) end
        tt:Show()   -- re-layout: added lines do not resize an already-shown tooltip
    end)
end

-- ============================================================
-- TAG PLACEMENT — the anti-clash pass
-- ============================================================
-- Each tag gets a preference order of corners derived from where its element sits on
-- the frame (an element hugging the bottom-left prefers to label below-left, and so
-- on), then takes the first candidate whose rect overlaps nothing already placed.
-- If every candidate collides, it takes the one that collides LEAST — a slightly
-- overlapping tag still reads, a hidden one does not.
local TAG_H, PAD, GAP = 12, 2, 3
-- How far the bracket sits OUTSIDE the region. 3px rather than 1: hugging the art is
-- what made the first cut read as another border on the icon. Standing clear of it is
-- half of why the brackets now read as annotation.
local PUSH = 3

-- Anchor origin of the frame an overlay is measured against. Zero when the rect is not
-- resolvable, which only happens mid-layout — the caller has already established the
-- target has a rect, so this is a guard rather than a path.
local function lOf(f) return (f and f.GetLeft and f:GetLeft()) or 0 end
local function bOf(f) return (f and f.GetBottom and f:GetBottom()) or 0 end

local function overlapArea(a, b)
    local dx = math.min(a.r, b.r) - math.max(a.l, b.l)
    local dy = math.min(a.t, b.t) - math.max(a.b, b.b)
    if dx <= 0 or dy <= 0 then return 0 end
    return dx * dy
end

-- Candidate tag rects for an element rect, in preference order. `above` and `left`
-- describe which half of the FRAME the element occupies, so tags radiate outward
-- rather than crossing the frame.
local function candidates(l, r, t, b, tw, above, left)
    local outT, outB = t + GAP, b - GAP - TAG_H
    local inL, inR = l, r - tw
    local c = {}
    local function add(x, y) c[#c + 1] = { l = x, r = x + tw, b = y, t = y + TAG_H } end
    if above then
        if left then add(inL, outT); add(inR, outT); add(inL, outB); add(inR, outB)
        else       add(inR, outT); add(inL, outT); add(inR, outB); add(inL, outB) end
    else
        if left then add(inL, outB); add(inR, outB); add(inL, outT); add(inR, outT)
        else       add(inR, outB); add(inL, outB); add(inR, outT); add(inL, outT) end
    end
    -- Clear of the element's sides entirely.
    add(l - tw - GAP, b + (t - b - TAG_H) / 2)
    add(r + GAP,      b + (t - b - TAG_H) / 2)
    -- ☠ FAR RANKS, so "the tag always shows" is actually true. A full spell tooltip is
    -- big enough to sit over every close candidate at once; without somewhere further
    -- out to go, the least-overlapping pick is still underneath it. One row further
    -- above and below, at both ends, gives the scorer a clear spot in every realistic
    -- case while staying close enough to read as this element's label.
    local farT, farB = outT + TAG_H + GAP, outB - TAG_H - GAP
    add(inL, farT); add(inR, farT); add(inL, farB); add(inR, farB)
    return c
end

local function place(frame, key, color, l, r, t, b, target, taken)
    local w = ensureWidgets(frame, key)
    local name = labelFor(key)
    w.tag:SetText(name)
    local tw = (w.tag:GetStringWidth() or 20) + PAD * 2

    -- Which half of the frame does this element live in? Decided from the element's
    -- CENTRE against the frame's, so an element that has been dragged elsewhere still
    -- labels outward rather than at a hardcoded corner.
    local fl, fr = frame:GetLeft(), frame:GetRight()
    local ft, fb = frame:GetTop(), frame:GetBottom()
    if not (fl and fr and ft and fb) then return end
    local above = ((t + b) / 2) >= ((ft + fb) / 2)
    local left  = ((l + r) / 2) <  ((fl + fr) / 2)

    local best, bestCost
    for _, cand in ipairs(candidates(l, r, t, b, tw, above, left)) do
        local cost = 0
        for _, used in ipairs(taken) do cost = cost + overlapArea(cand, used) end
        -- Off-screen is worse than any overlap: a tag drawn past the screen edge is
        -- simply gone, which reads as "that element has no label".
        if cand.l < 0 or cand.r > UIParent:GetWidth() then cost = cost + 1e6 end
        if cost == 0 then best, bestCost = cand, 0; break end
        if not bestCost or cost < bestCost then best, bestCost = cand, cost end
    end
    if not best then return end
    taken[#taken + 1] = best

    -- ☠ ANCHOR TO THE TARGET, NOT TO UIParent WITH THESE NUMBERS. Every coordinate
    -- here is in the target's effective scale; handing it to a UIParent anchor is only
    -- correct while the two scales happen to match. Offsets FROM the target are exact
    -- at any scale and track whatever the element's own anchors do afterwards.
    -- Inflated by PUSH so the brackets stand clear of the art rather than tracing it.
    local host = w.host
    local bw, bh = math.max(1, r - l) + PUSH * 2, math.max(1, t - b) + PUSH * 2
    local ox, oy = (l - lOf(target)) - PUSH, (b - bOf(target)) - PUSH
    host:ClearAllPoints()
    host:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", ox, oy)
    host:SetSize(bw, bh)

    -- Backing plate, same rect, but UNDER the row it marks. Strata and level are
    -- derived from the target every pass rather than set once: the row's own level
    -- moves with the frame, and a stale number would put the plate over the icons (or
    -- behind the health bar, where it is invisible).
    local under = w.under
    if under then
        under:ClearAllPoints()
        under:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", ox, oy)
        under:SetSize(bw, bh)
        local okS, tStrata = pcall(target.GetFrameStrata, target)
        local okL, tLevel = pcall(target.GetFrameLevel, target)
        if okS and tStrata then under:SetFrameStrata(tStrata) end
        if okL and tLevel then under:SetFrameLevel(math.max(0, tLevel - 1)) end
        under:Show()
    end

    local cr, cg, cb = color[1], color[2], color[3]
    -- The backing can be bold — it never touches the icon art, only the margin around
    -- it and the gaps between icons, which is exactly what makes a packed row read as
    -- one block. The wash over the top stays faint for the opposite reason: that one
    -- DOES tint the icons, so it may hint at the region but must never recolour what
    -- is being judged. Raise FILL, not WASH, if the effect wants more weight.
    w.fill:SetColorTexture(cr, cg, cb, 0.80)
    w.wash:SetColorTexture(cr, cg, cb, 0.12)
    -- Arm length scales with the region but stays short: a bracket that grows to meet
    -- its neighbour is a box again, which is the thing being avoided. Capped at a
    -- third of the shorter side so even a single-icon region keeps open edges.
    local bw, bh = math.max(1, r - l) + PUSH * 2, math.max(1, t - b) + PUSH * 2
    local arm = math.max(3, math.min(9, math.min(bw, bh) / 3))
    local e = w.edges
    for i = 1, 8 do e[i]:SetColorTexture(cr, cg, cb, 1); e[i]:ClearAllPoints() end
    -- Two arms per corner, anchored AT the corner and growing inward along each edge.
    local function bracket(hArm, vArm, point)
        hArm:SetPoint(point); hArm:SetSize(arm, 2)
        vArm:SetPoint(point); vArm:SetSize(2, arm)
    end
    bracket(e[1], e[2], "TOPLEFT")
    bracket(e[3], e[4], "TOPRIGHT")
    bracket(e[5], e[6], "BOTTOMLEFT")
    bracket(e[7], e[8], "BOTTOMRIGHT")

    -- ☠ THE TAG ALWAYS SHOWS. An earlier cut stood it down while a spell tooltip was
    -- naming the element, on the theory that the name was already on screen -- Krathe's
    -- call is that the tag is the thing tying the name to the region and it must never
    -- disappear. The tooltip is avoided by MOVING the tag (see the obstacle pass), not
    -- by hiding it.
    local tx, ty = best.l - lOf(target), best.b - bOf(target)
    w.tag:ClearAllPoints()
    w.tag:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", tx + PAD, ty + 1)
    w.tag:SetTextColor(cr, cg, cb)
    w.tagBG:ClearAllPoints()
    w.tagBG:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT", tx, ty)
    w.tagBG:SetSize(tw, TAG_H)
    w.tag:Show(); w.tagBG:Show()
    host:Show()
end

-- ============================================================
-- DRIVE
-- ============================================================
-- Called from the test-mode refresh, and from the two toggles. Cheap enough to run on
-- every refresh: a handful of rect reads over one frame.
-- Label ONE frame per active preview. Party test frames are keyed 0-4 and raid ones
-- 1-N, so the "first" differs per pool -- taking [1] for both would silently label
-- nothing in party mode.
-- ★★ ONE SECTION AT A TIME, UNDER THE CURSOR. Marking every element at once is what
-- the concept warned about and the field confirmed: three tags, three bracket sets and
-- three tints on a 130px frame is unreadable no matter how the marks are styled, and
-- overlapping regions (an Aura Designer indicator sitting inside the buff row) make it
-- worse. Highlighting only what the mouse is over removes the clutter completely and
-- answers the actual question -- "what is THIS?" -- at the moment it is asked.
--
-- Hover is detected by comparing the cursor against the cached region rects rather
-- than by a mouse-enabled frame: an overlay that takes the mouse swallows the aura
-- button's own tooltip, which is the bug this feature already shipped once.
local hoverRegions = {}   -- { frame, key, color, l, r, t, b, host, scale }

-- ★ EVERY ELEMENT ON EVERY VISIBLE TEST FRAME IS REGISTERED. An earlier cut let each
-- element claim the FIRST frame that rendered it, which was a holdover from marking
-- everything at once — with only the hovered region marked there is no clutter to
-- avoid, and pointing at unit 3's buffs should name them just as readily as unit 1's.
-- It also stops the preview lying by omission: the defensive icon previews on a
-- tank/healer slot and the missing-buff badge on another, so a single claimed frame
-- left whole elements unhoverable with nothing to say why.
local function scanFrame(frame)
    if not frame or not frame.GetLeft or not frame:GetLeft() or not frame:IsShown() then
        return
    end
    for _, target in ipairs(TARGETS) do
        local l, r, t, b, host, hosts = targetOf(frame, target.key)
        if l and host then
            for _, hf in ipairs(hosts or {}) do
                if hf ~= frame then regionOf[hf] = target.key end
            end
            local okScale, scale = pcall(host.GetEffectiveScale, host)
            hoverRegions[#hoverRegions + 1] = {
                frame = frame, key = target.key, color = target.color,
                l = l, r = r, t = t, b = b, host = host,
                scale = (okScale and scale) or 1,
            }
        end
    end
end

-- Smallest containing region wins, so an Aura Designer indicator sitting inside the
-- buff row identifies as the indicator rather than as the row around it.
local function regionUnderCursor()
    local cx, cy = GetCursorPosition()
    local best, bestArea
    for _, reg in ipairs(hoverRegions) do
        local s = reg.scale
        -- ☠ RE-ASKED HERE, not just when the list was built. See elementShown: a scan-time
        -- check freezes the answer until something rebuilds the list, which is what made
        -- the marks reflect only what was switched on when test mode opened. The rect can
        -- go stale the same way, but a rebuild follows every settings change that MOVES a
        -- row — where an on/off flip has to read true the moment it happens.
        if s and s > 0 and elementShown(reg.frame, reg.key) then
            local x, y = cx / s, cy / s
            if x >= reg.l and x <= reg.r and y >= reg.b and y <= reg.t then
                local area = (reg.r - reg.l) * (reg.t - reg.b)
                if not bestArea or area < bestArea then best, bestArea = reg, area end
            end
        end
    end
    return best
end

-- ★ OUR OWN TOOLTIP, shown only when the element has none of its own. Aura tooltips
-- are a setting people switch off, and icons outside the aura rows never had one, so
-- appending to the game tooltip alone left those elements silently unnamed. A separate
-- tooltip object rather than GameTooltip: nothing to fight over, and no chance of
-- clearing a tooltip the game owns.
local ownTip
local function ensureOwnTip()
    if ownTip then return ownTip end
    ownTip = CreateFrame("GameTooltip", "DFTestLabelTooltip", UIParent, "GameTooltipTemplate")
    return ownTip
end

-- Stands down when the GAME's tooltip is already naming this element (our hook has
-- appended to it) — two tooltips saying the same thing is worse than one. The on-frame
-- tag is never suppressed either way; it moves instead.
local function showOwnTip(reg)
    local tt = ensureOwnTip()
    if GameTooltip:IsShown() then
        local ok, owner = pcall(GameTooltip.GetOwner, GameTooltip)
        if ok and owner and regionForOwner(owner) then tt:Hide(); return end
    end
    local name, page = labelFor(reg.key)
    tt:SetOwner(reg.host, "ANCHOR_RIGHT")
    tt:ClearLines()
    tt:AddLine(name, 1, 1, 1)
    if page ~= "" then tt:AddLine(page, 0.58, 0.51, 0.79) end
    tt:Show()
end

-- ★ A VISIBLE TOOLTIP IS AN OBSTACLE, not a thing to work around by hand. The tag and
-- the tooltip both want the free space beside the element, so the tooltip covered the
-- tag whenever it opened on that side. Rather than picking a fixed opposite corner --
-- which just moves the collision somewhere else, since the tooltip's own side depends
-- on where the frame sits on screen — its rect is fed to the same candidate-scoring
-- pass the tags already use against each other, and the tag steps aside on its own.
-- ⚠ Converted into the REGION's coordinate space: a tooltip carries its own effective
-- scale, and comparing raw rects across scales silently misjudges the overlap.
local function tipObstacle(tt, scale)
    if not (tt and tt.IsShown and tt:IsShown()) then return nil end
    local ok, l, r, t, b, ts = pcall(function()
        return tt:GetLeft(), tt:GetRight(), tt:GetTop(), tt:GetBottom(), tt:GetEffectiveScale()
    end)
    if not ok or not l or not r or not t or not b then return nil end
    local k = (ts or 1) / ((scale and scale > 0) and scale or 1)
    return { l = l * k, r = r * k, t = t * k, b = b * k }
end

local hoverDriver, hoverShown
local clearFades   -- forward declaration: defined with the fade machinery below
local function stopHover()
    if hoverDriver then hoverDriver:Hide() end
    if ownTip then ownTip:Hide() end
    if clearFades then clearFades() end
    if hoverShown then
        local set = hoverShown.frame and hoverShown.frame.dfTestLabels
        local w = set and set[hoverShown.key]
        if w then setMarkAlpha(w, 1); hideMark(w) end
        hoverShown = nil
    end
end

-- ============================================================
-- FADE
-- ============================================================
-- Snapping a mark on and off as the cursor crosses a frame reads as aggressive, which
-- is the opposite of what an explanatory overlay should feel like. Three timings:
--   * FADE_IN   — quick enough to feel responsive to the point.
--   * LINGER    — a beat of hold after the cursor leaves EVERYTHING, so a mark that was
--                 glanced at does not vanish before it has been read.
--   * FADE_OUT  — the ease-off itself.
-- ☠ MOVING BETWEEN two regions does NOT linger: holding the old one while the new one
-- rises puts two marks on screen at once, which is the clutter this whole design was
-- rebuilt to avoid. Only leaving to empty space holds.
local FADE_IN, FADE_OUT, LINGER = 0.12, 0.28, 0.6

-- Marks that are on their way out. Small by construction (one per region crossed
-- during a fade), and entries are removed as they finish.
local fadingOut = {}

local function widgetFor(reg)
    local set = reg and reg.frame and reg.frame.dfTestLabels
    return set and set[reg.key]
end

local function beginFadeOut(reg, linger)
    local w = widgetFor(reg)
    if not w then return end
    -- Resurrect rather than duplicate if this region is already fading.
    for _, f in ipairs(fadingOut) do
        if f.reg == reg then f.wait = linger; f.state = "wait"; return end
    end
    fadingOut[#fadingOut + 1] = {
        reg = reg, alpha = w.host:GetAlpha() or 1, wait = linger, state = "wait",
    }
end

local function advanceFades(dt)
    for i = #fadingOut, 1, -1 do
        local f = fadingOut[i]
        local w = widgetFor(f.reg)
        if not w then
            table.remove(fadingOut, i)
        else
            if f.state == "wait" then
                f.wait = f.wait - dt
                if f.wait <= 0 then f.state = "out" end
            else
                f.alpha = f.alpha - dt / FADE_OUT
                if f.alpha <= 0 then
                    setMarkAlpha(w, 1)   -- restore for the next show
                    hideMark(w)
                    table.remove(fadingOut, i)
                else
                    setMarkAlpha(w, f.alpha)
                end
            end
        end
    end
end

-- Drop every in-flight fade immediately (settings changed, test mode ended): a mark
-- fading toward a rect that no longer exists is worse than one that simply vanishes.
-- Assigns the forward-declared local above — a `local function` here would shadow it
-- and leave stopHover calling nil.
function clearFades()
    for i = #fadingOut, 1, -1 do
        local w = widgetFor(fadingOut[i].reg)
        if w then setMarkAlpha(w, 1); hideMark(w) end
        fadingOut[i] = nil
    end
end

local function ensureHoverDriver()
    if hoverDriver then return hoverDriver end
    hoverDriver = CreateFrame("Frame")
    local elapsed, inAlpha = 0, 0
    hoverDriver:SetScript("OnUpdate", function(_, dt)
        -- ⚠ The FADES advance every frame; only the HIT TEST is throttled. Running the
        -- alpha maths at the poll rate made the fade visibly step.
        advanceFades(dt)

        elapsed = elapsed + dt
        if elapsed >= 0.05 then
            elapsed = 0
            -- Polled rather than event-driven: a mouse-enabled overlay would swallow
            -- the aura button's own tooltip. A handful of rect comparisons, only while
            -- the option is on and only in test mode.
            local reg = regionUnderCursor()
            if reg ~= hoverShown then
                if hoverShown then
                    -- Crossing to another region ends the old one promptly; leaving to
                    -- nothing gets the hold.
                    beginFadeOut(hoverShown, reg and 0 or LINGER)
                end
                if reg then
                    -- Pick up where a fade left off, so sweeping back onto a region
                    -- that is still visible does not restart it from transparent.
                    local w = widgetFor(reg)
                    inAlpha = (w and w.host:IsShown() and w.host:GetAlpha()) or 0
                    for i = #fadingOut, 1, -1 do
                        if fadingOut[i].reg == reg then table.remove(fadingOut, i) end
                    end
                end
                hoverShown = reg
                if not reg and ownTip then ownTip:Hide() end
            end
        end

        local reg = hoverShown
        if not reg then return end

        -- Re-evaluated every tick rather than only on entry: the game tooltip can
        -- appear or vanish while the cursor sits still (moving between two icons
        -- inside one region), and both the fallback tooltip and the tag's placement
        -- have to follow that.
        showOwnTip(reg)
        -- Re-placed WITH the live tooltip rects as obstacles, so the tag moves out from
        -- under a tooltip the moment one opens and returns when it closes.
        local taken = {}
        local o1 = tipObstacle(GameTooltip, reg.scale)
        if o1 then taken[#taken + 1] = o1 end
        local o2 = tipObstacle(ownTip, reg.scale)
        if o2 then taken[#taken + 1] = o2 end
        place(reg.frame, reg.key, reg.color, reg.l, reg.r, reg.t, reg.b, reg.host, taken)

        if inAlpha < 1 then
            inAlpha = math.min(1, inAlpha + dt / FADE_IN)
        end
        local w = widgetFor(reg)
        if w then setMarkAlpha(w, inAlpha) end
    end)
    return hoverDriver
end

local function eachTestFrame(fn)
    for i = 0, 4 do
        local f = DF.testPartyFrames and DF.testPartyFrames[i]
        if f then fn(f) end
    end
    for i = 1, 40 do
        local f = DF.testRaidFrames and DF.testRaidFrames[i]
        if f then fn(f) end
    end
end

-- One toggle drives both halves, asked per pool: party and raid keep separate test
-- settings, so each pool answers for itself.
local function poolWants(isRaid)
    if isRaid then
        if not (DF.raidTestMode and DF.testRaidFrames) then return false end
        local db = DF.GetRaidDB and DF:GetRaidDB()
        return (db and db.testShowLabels) and true or false
    end
    if not (DF.testMode and DF.testPartyFrames) then return false end
    local db = DF.GetDB and DF:GetDB()
    return (db and db.testShowLabels) and true or false
end

-- ☠ THE FIRST PASS AFTER A RELOAD MEASURES NOTHING, AND ONE TICK IS NOT ENOUGH.
-- Test-mode ENTRY already knows this about itself -- DF:ShowTestFrames repaints on
-- the next tick with the note "an anchor-derived rect is 0 for the whole creation
-- tick ... which is why only the first entry per reload was broken and any toggle
-- fixed it". The marks are a harder case of the same thing: a region is only
-- measurable once its aura container has been built AND laid out, so on a fresh
-- login the scan found no rects at all and left the registry empty. Nothing rebuilt
-- it until a settings change came along -- hence "they don't show until you toggle
-- Indicator Info off and on" (Krathe, 2026-08-17).
-- ★ RETRY ON AN EMPTY RESULT rather than guessing a longer fixed delay: it converges
-- as soon as the rects exist, whether that is the next frame or the tenth, and it
-- cannot outlive the budget. Bounded at ~1.5s total.
-- ⚠ A pool with every indicator switched off legitimately scans to zero, so it burns
-- the full budget of (cheap, self-cancelling) timers before going quiet. Accepted:
-- the alternative is distinguishing "nothing to show" from "not measurable yet",
-- which is the very question the scan cannot answer while the rects are zero.
local SETTLE_GAP, SETTLE_TRIES = 0.15, 10
local settleGen, settleLeft = 0, 0

local function scheduleSettle()
    local gen = settleGen
    C_Timer.After(SETTLE_GAP, function()
        -- Superseded by a newer full pass: that one owns the budget now.
        if gen ~= settleGen then return end
        if not (poolWants(false) or poolWants(true)) then return end
        TL:Update(true)
    end)
end

-- `settling` marks a retry from scheduleSettle: it keeps the current budget and
-- generation, where any other caller starts a fresh one.
function TL:Update(settling)
    ensureTooltipHook()
    if not settling then
        settleGen = settleGen + 1
        settleLeft = SETTLE_TRIES
    end
    -- Hide first, then label the one frame per pool: a frame count reduced since the
    -- last pass would otherwise strand its tags on a hidden frame.
    eachTestFrame(hideWidgets)
    -- Rebuilt every pass: the regions move whenever a setting does, and a stale rect
    -- would highlight where an element used to be.
    stopHover()
    for i = #hoverRegions, 1, -1 do hoverRegions[i] = nil end
    for k in pairs(regionOf) do regionOf[k] = nil end

    if poolWants(false) then
        for i = 0, 4 do scanFrame(DF.testPartyFrames[i]) end
    end
    if poolWants(true) then
        for i = 1, 40 do scanFrame(DF.testRaidFrames[i]) end
    end

    if #hoverRegions > 0 then
        settleLeft = 0
        ensureHoverDriver():Show()
    elseif settleLeft > 0 and (poolWants(false) or poolWants(true)) then
        settleLeft = settleLeft - 1
        scheduleSettle()
    end
end

-- Teardown on test-mode exit. The widgets are pooled on the frames, so they only need
-- hiding; the region registry is wiped too, or a pooled frame handed back to live
-- rendering would keep appending "Buff Bar" to real spell tooltips. (The hook itself
-- stays — it is a no-op outside test mode, and HookScript cannot be undone.)
function TL:Clear()
    -- Cancel any pending settle retry: test mode is going away, and a retry that
    -- landed after teardown would re-scan pooled frames handed back to live rendering.
    settleGen = settleGen + 1
    settleLeft = 0
    stopHover()
    for i = #hoverRegions, 1, -1 do hoverRegions[i] = nil end
    eachTestFrame(hideWidgets)
    for k in pairs(regionOf) do regionOf[k] = nil end
end

function DF:UpdateTestLabels() TL:Update() end
function DF:ClearTestLabels()  TL:Clear()  end
