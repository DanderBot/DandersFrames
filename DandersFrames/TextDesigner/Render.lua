local addonName, DF = ...

-- ============================================================
-- TEXT DESIGNER — RENDER LAYER
-- FontString lifecycle: create one per element per frame,
-- anchor + style per elem fields, call Resolver on refresh,
-- handle visibility (eye icon + master toggle).
-- ============================================================

DF.TextDesigner = DF.TextDesigner or {}
local Render = {}
DF.TextDesigner.Render = Render

local function getResolver() return DF.TextDesigner.Resolver end
local function getMS() return DF.TextDesigner.MidnightSafe end

local wipe, pcall = wipe, pcall

-- Enabled-element id set, rebuilt by UpdateFrame. Module-local and reused
-- (wipe, not {}) because UpdateFrame runs in the unit-event hot path.
local enabledScratch = {}
-- Second scratch for Render:UpdateFrame's delete-sweep. Same reason and same lifetime
-- as enabledScratch above -- it is filled and consumed inside one call and never
-- escapes -- but it holds ALL element ids where enabledScratch holds only the enabled
-- ones, so the two cannot share a table.
local liveIdScratch = {}

-- ============================================================
-- HINT CATEGORIES — which content types refresh on which hints
-- ============================================================

local CONTENT_HINTS = {
    -- name (identity)
    name              = "name",
    class             = "name",
    level             = "name",
    level_difficulty  = "name",
    classification    = "name",
    target_name       = "name",
    race              = "name",
    faction           = "name",
    race_level_faction= "name",  -- legacy combined type (kept for migration)
    group_number      = "name",
    custom_static     = "name",  -- static, refreshes only on settings change
    -- health
    hp_current        = "health",
    hp_max            = "health",
    hp_percent        = "health",
    hp_deficit        = "health",
    hp_max_reduction  = "health",
    status_text       = "health",  -- legacy combined type (kept for migration)
    status_afk        = "health",
    -- power
    power_current     = "power",
    power_percent     = "power",
    power_deficit     = "power",
    power_type_string = "power",
    -- absorbs / heals
    absorb_amount     = "absorb",
    heal_absorb_amount= "absorb",
    incoming_heal     = "heal",
    incoming_heal_mine= "heal",
    -- threat / range
    aggro_flag        = "threat",
    threat_percent    = "threat",
    range_text        = "range",
    -- group (refreshes on any hint since it can mix categories)
    group             = "all",
    -- a plain backing shape (no text): changes with settings only
    backdrop          = "name",
}

-- ============================================================
-- FONT/COLOR RESOLUTION (overrides + globalDefaults)
-- ============================================================

-- Shared read-only stand-ins for the absent-table cases. Both are ONLY ever indexed
-- (never written) in the body below, so one shared instance is safe and saves two
-- throwaway tables per call on elements that carry no overrides -- which is most of
-- them. Same for the white fallback, which callers only read fields from.
local EMPTY_APPEARANCE = {}
local DEFAULT_TEXT_COLOR = { r = 1, g = 1, b = 1, a = 1 }

-- ☠ SHARED SCRATCH — the returned table is the SAME table on every call.
-- resolveAppearance is #2 in every combat trace and ran once per element per
-- frame per tick, so this one table was most of what remained after ac55fb85
-- shared the three fallbacks.
--
-- SAFE ONLY WHILE AT MOST ONE RESOLVED APPEARANCE IS LIVE AT A TIME. That holds
-- by construction today, and all four parts are load-bearing:
--   1. applyAppearance is resolveAppearance's only caller, and updateOne is
--      applyAppearance's only caller (both verified, not assumed).
--   2. updateOne holds the result across applyPosition -> Resolve ->
--      mirrorElement. None of those re-enters: resolveAppearance is a FILE-LOCAL,
--      so nothing outside Render.lua can reach it at all.
--   3. Nothing RETAINS it. mirrorElement reads app.font/fontSize/outline at the
--      point of use and stores nothing; the result is dead when updateOne returns.
--   4. Every field is reassigned on every call, so no stale value can carry over.
--
-- ☠ WHAT WOULD BREAK IT: a second resolve while a first result is still in scope.
-- That exact shape existed until ac55fb85 -- the class-colour branch re-resolved
-- the same element just to read one alpha, while the outer result was still bound
-- for mirrorElement -- and a shared table then would have aliased the two
-- silently, which is why that commit declined to share this one. If you add a
-- caller, give it its own table or pass it the fields it needs.
local appearanceScratch = {}

local function resolveAppearance(elem, globalDefaults)
    globalDefaults = globalDefaults or EMPTY_APPEARANCE
    local overrides = elem.overrides or EMPTY_APPEARANCE
    -- useClassColor is the one boolean field, so the `(override and value) or
    -- global` pattern the others use would swallow an override of FALSE (it
    -- falls through to the global default). Branch on the override flag instead.
    local useClassColor
    if overrides.useClassColor then
        useClassColor = elem.useClassColor or false
    else
        useClassColor = globalDefaults.useClassColor or false
    end
    local app = appearanceScratch
    app.font          = (overrides.font          and elem.font)          or globalDefaults.font          or "DF Roboto SemiBold"
    app.fontSize      = (overrides.fontSize      and elem.fontSize)      or globalDefaults.fontSize      or 10
    app.color         = (overrides.color         and elem.color)         or globalDefaults.color         or DEFAULT_TEXT_COLOR
    app.outline       = (overrides.outline       and elem.outline)       or globalDefaults.outline       or "SHADOW;NONE"
    app.useClassColor = useClassColor
    return app
end

-- ============================================================
-- LSM FONT LOOKUP
-- ============================================================

local LSM_FALLBACK = "Fonts\\FRIZQT__.TTF"
local function fontPath(name)
    if not name then return LSM_FALLBACK end
    if name:sub(1, 1) == "\\" or name:find("^Fonts\\") then return name end
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local path = LSM:Fetch("font", name, true)
        if path then return path end
    end
    return LSM_FALLBACK
end

-- ============================================================
-- ANCHOR RESOLUTION
-- ============================================================

-- Returns the frame to anchor to. anchorTo == "FRAME" → parent frame.
-- anchorTo == <element id string> → that element's FontString on the same frame.
-- A disabled target counts as absent: its FontString is hidden with stale
-- geometry, so dependents re-anchor to the frame instead of hanging off it.
-- ============================================================
-- SPOT ANCHORS (2026-11-01, ring unit frames)
-- anchorTo may name a SPOT on the frame instead of the frame or an element:
--   RING_ABOVE / RING_BELOW   just above / below the frame's ring
--   RING_CENTER               the middle
--   RING_GAP_LEFT / _RIGHT    the outer ring's open side, or its edge when closed
-- The frame says where (frame.dfTDAnchorSpot(frame, key) -> x, y from its centre:
-- DandersFrames_UnitFrames/Rings.lua R.AnchorSpot answers from the ring layout);
-- a frame that does not answer (a Bars frame, party / raid, the mock) uses its own
-- edges (SPOT_FALLBACK). A spot is a 1px region, and an element pins the SAME point
-- of itself to it (SetPoint(point, spot, point)), so the element's anchor reads as
-- "which part of the text sits on the spot". Mirrored text swaps left and right.
-- ============================================================
local SPOT_FALLBACK = { RING_ABOVE = "TOP", RING_BELOW = "BOTTOM", RING_CENTER = "CENTER",
                        RING_GAP_LEFT = "LEFT", RING_GAP_RIGHT = "RIGHT" }
Render.SPOTS = SPOT_FALLBACK
local SPOT_MIRROR = { RING_GAP_LEFT = "RING_GAP_RIGHT", RING_GAP_RIGHT = "RING_GAP_LEFT" }

local function spotRegion(frame, key)
    if frame.dfMirrorText == true and SPOT_MIRROR[key] then key = SPOT_MIRROR[key] end
    local spots = frame._tdSpots
    if not spots then
        spots = {}
        frame._tdSpots = spots
    end
    local spot = spots[key]
    if not spot then
        spot = CreateFrame("Frame", nil, frame)
        spot:SetSize(1, 1)
        spots[key] = spot
    end
    local fn = rawget(frame, "dfTDAnchorSpot")
    local x, y
    if fn then x, y = fn(frame, key) end
    local rel
    if x then rel = "CENTER" else rel, x, y = SPOT_FALLBACK[key], 0, 0 end
    -- Re-anchored only when it moved: this runs per element per update.
    if spot._tdRel ~= rel or spot._tdX ~= x or spot._tdY ~= y then
        spot:ClearAllPoints()
        spot:SetPoint("CENTER", frame, rel, x, y)
        spot._tdRel, spot._tdX, spot._tdY = rel, x, y
    end
    return spot
end
Render.SpotRegion = spotRegion

local function resolveAnchorTarget(elem, frame, fontStringsById, enabledById)
    local target = elem.anchorTo or "FRAME"
    if target == "FRAME" then return frame end
    if SPOT_FALLBACK[target] then return spotRegion(frame, target) end
    local targetId = tonumber(target)
    if targetId and (not enabledById or enabledById[targetId]) then
        if fontStringsById and fontStringsById[targetId] then return fontStringsById[targetId] end
        -- A background element is a region of its own, not a FontString.
        local bd = frame._tdBackdrops and frame._tdBackdrops[targetId]
        if bd then return bd end
    end
    return frame  -- fallback
end

-- ============================================================
-- FONTSTRING LIFECYCLE
-- ============================================================

-- Ensures (creating if needed) a high-level overlay Frame on the
-- target unit frame. TD FontStrings live on this overlay so they
-- render above health/power bars regardless of bar FrameLevels.
-- (Bars are separate Frames at higher FrameLevels than the unit
-- frame itself; anything drawn directly on the unit frame renders
-- behind them. The overlay sidesteps that.)
local function ensureTdOverlay(frame)
    if frame._tdOverlay then return frame._tdOverlay end
    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    -- Match contentOverlay (where the legacy name text lives): above the
    -- health/power bars but below the status/defensive/aura icons.
    overlay:SetFrameLevel((frame.contentOverlay and frame.contentOverlay:GetFrameLevel())
        or (frame:GetFrameLevel() + 25))
    frame._tdOverlay = overlay
    return overlay
end

-- Acquires (creating if needed) the FontString for a given element on a frame.
local function acquireFontString(frame, elem)
    frame._tdFontStrings = frame._tdFontStrings or {}
    local fs = frame._tdFontStrings[elem.id]
    if fs then return fs end
    local overlay = ensureTdOverlay(frame)
    fs = overlay:CreateFontString(nil, "OVERLAY")
    frame._tdFontStrings[elem.id] = fs
    return fs
end

-- Applies anchor / font / color to the FontString.
local function applyAppearance(fs, frame, elem, globalDefaults)
    local app = resolveAppearance(elem, globalDefaults)
    -- Font, only when it changed: this runs on every text update, and a full SafeSetFont
    -- re-resolves the font and forces a re-render each time. The family generation and
    -- the slug option are part of the key because both change the applied font without
    -- changing these settings; shadow edits reach shared families in place.
    local slug = DF.db and DF.db.fontSlug and true or false
    local gen = DF.fontFamilyGen
    if fs._tdFont ~= app.font or fs._tdFontSize ~= app.fontSize or fs._tdFontOutline ~= app.outline
        or fs._tdFontSlug ~= slug or fs._tdFontGen ~= gen then
        if DF:SafeSetFont(fs, fontPath(app.font), app.fontSize, app.outline) then
            fs._tdFont, fs._tdFontSize, fs._tdFontOutline = app.font, app.fontSize, app.outline
            fs._tdFontSlug, fs._tdFontGen = slug, gen
        else
            fs._tdFont = nil
        end
    end
    -- Color
    if app.useClassColor then
        -- For LiveSource we'd read source:GetClassToken() — but Render doesn't
        -- have the source. Defer class-color application to UpdateOne (which
        -- has the source) by storing a flag on the FontString.
        fs._useClassColor = true
        -- Initial color from globalDefaults until UpdateOne re-applies.
        fs:SetTextColor(app.color.r, app.color.g, app.color.b, app.color.a or 1)
    else
        fs._useClassColor = false
        fs:SetTextColor(app.color.r, app.color.g, app.color.b, app.color.a or 1)
    end
    return app   -- resolved appearance, reused by the AD mirror sync
end

-- ============================================================
-- MIRRORED TEXT (frame.dfMirrorText)
-- A frame can draw its text mirrored: every element's horizontal anchor is
-- flipped (LEFT <-> RIGHT, TOPLEFT <-> TOPRIGHT, ...) and its x offset negated,
-- at layout time, on that frame only. The template itself is never touched, so
-- two frames sharing one template can draw it as a pair of mirror images.
-- An element anchored to another element anchors at the SAME point on both
-- (SetPoint(point, target, point, ...)), so flipping both ends keeps the pair
-- together. The renderer sets no horizontal justify of its own (a FontString
-- held by one point sizes to its text), so there is no justify to flip.
-- ============================================================
local function mirrorPoint(point)
    if type(point) ~= "string" then return point end
    if point:find("LEFT", 1, true) then return (point:gsub("LEFT", "RIGHT")) end
    if point:find("RIGHT", 1, true) then return (point:gsub("RIGHT", "LEFT")) end
    return point
end

-- Where an element sits on a frame: point, x, y, mirrored when the frame says so.
-- A local (published below): applyPosition runs per element per health tick.
local function placement(frame, elem)
    local point, x, y = elem.anchor or "CENTER", elem.offsetX or 0, elem.offsetY or 0
    -- Show on Hover with a slide: the element starts `hoverSlide` px out and slides
    -- home as it fades in (Render:SetHover). Plain numbers only.
    local slide = elem.showOnHover and tonumber(elem.hoverSlide)
    if slide and slide ~= 0 and frame then
        x = x + slide * (1 - (frame._tdHoverT or 0))
    end
    if frame and frame.dfMirrorText == true then
        point = mirrorPoint(point)
        if x ~= 0 then x = -x end
    end
    return point, x, y
end
Render.Placement = placement
Render.MirrorPoint = mirrorPoint

-- Applies position to the FontString (separate from appearance so we can
-- update position when anchorTo's target moves).
local function applyPosition(fs, frame, elem, fontStringsById, enabledById)
    local target = resolveAnchorTarget(elem, frame, fontStringsById, enabledById)
    local point, x, y = placement(frame, elem)
    -- Re-anchoring makes the client lay the text out again, and this runs on every update
    -- (each health tick per unit); the anchor only moves when one of these four does.
    -- A torn-down frame gets fresh FontStrings (Render:Teardown), so the stamp resets.
    if fs._tdPosTarget == target and fs._tdPosPoint == point
        and fs._tdPosX == x and fs._tdPosY == y then
        return
    end
    fs:ClearAllPoints()
    fs:SetPoint(point, target, point, x, y)
    fs._tdPosTarget, fs._tdPosPoint, fs._tdPosX, fs._tdPosY = target, point, x, y
end

-- ============================================================
-- AURA DESIGNER MIRRORS (12.1 name/health text colour-by-cover)
-- A mirror is a DUPLICATE FontString parented to a region the Aura Designer
-- owns (an aura-slot child whose visibility Blizzard drives from the tracked
-- aura's secret presence). Aura present -> the slot shows -> the coloured
-- cover renders over the real text; absent -> the cover hides and the real
-- text shows. Recolour-by-cover: the REAL FontString is never touched, so
-- nothing is gated on a secret.
-- SYNC-AT-SOURCE: the mirror is fed inside updateOne from the SAME resolved
-- inputs as the real FontString — DF:SafeSetFont with the same font/size/
-- outline (so pixel-perfect adjustments match, glyph-identical cover) and
-- SetText with the same SafeText value (secrets pass through unread; never
-- compare/measure/string-op mirror text). Position tracks via SetAllPoints
-- on the real FontString (render-side, secret rects fine). Colour is the one
-- property never copied — the mirror keeps the AD override colour.
-- KNOWN LIMIT: inline |c colour codes embedded by group items keep their
-- embedded colour under the cover (SetTextColor can't override them, and
-- stripping possibly-secret text is forbidden).
-- ============================================================

-- Does this element belong to a mirror category? Single elements match via
-- CONTENT_HINTS; a "group" element matches when ANY of its items does (the
-- category set a group renders is its items' union).
local function mirrorCategoryMatches(elem, category)
    if CONTENT_HINTS[elem.contentType] == category then return true end
    if elem.contentType == "group" and type(elem.groupItems) == "table" then
        for _, raw in ipairs(elem.groupItems) do
            local ct = type(raw) == "table" and (raw.contentType or raw.type) or raw
            if CONTENT_HINTS[ct] == category then return true end
        end
    end
    return false
end

-- ============================================================
-- MIRROR WRITE GUARDS (bug #1026)
-- ☠ MIRROR WRITES CAN BE DENIED IN COMBAT. The mirror parent is an aura-slot
-- child (slot.dfMirrorHost) whose write-legality rests on the shape documented
-- in AuraContainer's styleButton_regions: the access restriction is applied to
-- the aura frame ALONE, but FORBIDDEN aspects propagate down the parent chain.
-- With condition CHAINS (>= 2 groups) the host ends up nested inside ANOTHER
-- slot's secret-visibility subtree, and every write to the mirror — SetFont,
-- SetText, SetShown, even Hide() — is refused the moment auras go secret at
-- combat entry. These are DENIED WRITES, not taint we caused: the identical
-- writes succeed out of combat, and no execution path changes at combat start
-- (the ordinary tdDriver flush is what walks into the denial).
--
-- So every mirror touch degrades instead of erroring, two layers deep:
--   1. IsForbidden() early-out where cheap — a clean, no-error skip. ⚠ It is
--      UNVERIFIED whether 12.1's access-restriction system reports through
--      IsForbidden(), so this layer alone is never trusted.
--   2. pcall backstop with a SUSPEND LATCH — the first failed write flips
--      reg.suspended, every later mirror write for that registry is skipped,
--      and the drain below clears the latch and forces one category render to
--      resync once auras stop being secret (AuraContainer's _registerRegen
--      idiom). Secrecy, not combat: it can outlast combat (M+ between pulls)
--      and lift with no combat edge (leaving a key or a PvP zone).
--
-- ☠ NEVER Hide() as a failure fallback — Hide is itself a denied write on the
-- same object. Skipping entirely is the only safe response to a denial.
-- NB: a denied write may still log a taint.log incident even under pcall (the
-- secret-compare precedent in SafeSetFont's text-refresh block shows blocked
-- COMPARES do; writes are unconfirmed) — but it cannot error and cannot spam:
-- the latch stops the writes after the first denial.
--
-- Visual result while suspended: the coloured cover freezes mid-combat, but
-- its VISIBILITY still tracks the aura through parent-driven inheritance (the
-- point of the attach-and-inherit design), and the real FontString underneath
-- stays correct throughout.
-- ============================================================

-- Lazily-created drain for suspended registries. Weak
-- keys, like AuraContainer._regen._handles: a frame released while suspended
-- must not be pinned alive by the drain set.
local function registerMirrorRegen(frame)
    local drain = Render._mirrorRegen
    if not drain then
        drain = CreateFrame("Frame")
        drain._frames = setmetatable({}, { __mode = "k" })
        drain:RegisterEvent("PLAYER_REGEN_ENABLED")
        drain:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
        drain:SetScript("OnEvent", function(self)
            -- Still secret: a resync now would only be refused and re-latch.
            local AC = DF.AuraContainer
            if AC and AC.AurasRestricted and AC.AurasRestricted() then return end
            -- Removing the CURRENT key during pairs is legal; nothing here can
            -- ADD one mid-loop — UpdateTextDesigner only marks the coalescing
            -- buffer, so no write (hence no re-suspend) runs before next frame.
            for fr in pairs(self._frames) do
                self._frames[fr] = nil
                local regs = fr._tdMirrors
                if regs then
                    for category, reg in pairs(regs) do
                        if reg.suspended then
                            reg.suspended = nil
                            -- One forced category render resyncs font/text/shown
                            -- on everything the freeze skipped (coalesced, so
                            -- several categories still cost one render).
                            if DF.UpdateTextDesigner then
                                DF:UpdateTextDesigner(fr, category)
                            end
                        end
                    end
                end
            end
        end)
        Render._mirrorRegen = drain
    end
    drain._frames[frame] = true
end

-- Latch a registry off after a denied write. At most once per registry per
-- combat (the early return), so the tostring()s below are not hot-path cost.
-- DebugWarn is once per session — the developer-visible breadcrumb; the Debug
-- line carries the per-suspension detail when the TD category is enabled.
local function suspendMirrors(frame, reg, why)
    if reg.suspended then return end
    reg.suspended = true
    registerMirrorRegen(frame)
    if not Render._mirrorSuspendWarned then
        Render._mirrorSuspendWarned = true
        DF:DebugWarn("TD", "mirror write denied — AD text colour covers frozen until combat ends")
    end
    DF:Debug("TD", "mirror write denied (%s) — '%s' covers suspended until combat ends (unit=%s)",
        tostring(why), tostring(reg.category), tostring(frame.unit))
end

-- One guarded mirror write. `m` is the region the write targets (the
-- IsForbidden probe); `fn` is pcall'ed with the args that follow, so both
-- method-style writes (m.SetText, m, ...) and DF:SafeSetFont
-- (DF.SafeSetFont, DF, m, ...) take the same allocation-free form.
local function mirrorWrite(frame, reg, m, fn, ...)
    if reg.suspended then return false end
    if m.IsForbidden and m:IsForbidden() then
        suspendMirrors(frame, reg, "IsForbidden")
        return false
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        suspendMirrors(frame, reg, err)
        return false
    end
    return true
end

-- Best-effort hide for a mirror whose REGISTRY is being discarded (parent
-- swap / DisableMirrors / Teardown). No latch: the registry will never be
-- written again, so there is nothing to suspend — and a denied Hide just
-- means the parent chain takes the cover down with the slot instead.
local function retireMirror(m)
    if m.IsForbidden and m:IsForbidden() then return end
    pcall(m.Hide, m)
    pcall(m.ClearAllPoints, m)
end

-- Feed one rendered element to every matching mirror (called from updateOne
-- with the element's resolved appearance + the exact safe text just set on
-- the real FontString). A registered-but-no-longer-matching mirror (the user
-- re-typed a group's items) is hidden so it can't linger as a stale cover.
-- Every touch of a mirror in here is a guarded write (see MIRROR WRITE GUARDS
-- above): once a mirror has materialized this runs on EVERY render whether or
-- not the aura is up, so in-combat denial is the chained shape's NORMAL case,
-- not an edge.
local function mirrorElement(frame, elem, fs, app, safeText)
    for _, reg in pairs(frame._tdMirrors) do
        if reg.suspended then
            -- Latched: no writes of any kind until the regen drain clears it.
        elseif mirrorCategoryMatches(elem, reg.category) then
            local m = reg.byId[elem.id]
            if not m then
                -- Guard the CREATE as a write too: the parent is the aura-slot
                -- child, and materializing a child on a denied subtree is as
                -- refusable as any setter. A mirror that fails any of its
                -- creation-time writes is NOT stored — byId entries skip
                -- SetAllPoints/SetTextColor on later passes, so storing a
                -- half-built one would strand it unanchored/uncoloured for
                -- good. The orphan FontString (no anchors, no text) renders
                -- nothing and is at most one per registry per combat — the
                -- latch stops repeats.
                local parent = reg.parent
                if parent.IsForbidden and parent:IsForbidden() then
                    suspendMirrors(frame, reg, "parent forbidden")
                else
                    local ok, created = pcall(parent.CreateFontString, parent, nil, "OVERLAY")
                    if not ok then
                        suspendMirrors(frame, reg, created)
                    else
                        local c = reg.color
                        -- anchors track the real text render-side
                        if mirrorWrite(frame, reg, created, created.SetAllPoints, created, fs)
                            and mirrorWrite(frame, reg, created, created.SetTextColor, created,
                                c.r, c.g, c.b, c.a or 1) then
                            reg.byId[elem.id] = created
                            m = created
                        end
                    end
                end
            end
            if m then
                -- Same setter, same resolved inputs -> identical rendering.
                mirrorWrite(frame, reg, m, DF.SafeSetFont, DF, m, fontPath(app.font), app.fontSize, app.outline)
                -- Same SafeText value the real FontString just received (secret
                -- passthrough). SetShown only after SetText lands — never show
                -- a cover whose text write was refused, and (☠) never Hide()
                -- on failure either: the latch skip IS the failure path.
                if mirrorWrite(frame, reg, m, m.SetText, m, safeText) then
                    mirrorWrite(frame, reg, m, m.SetShown, m, fs:IsShown())
                end
            end
        else
            local m = reg.byId[elem.id]
            if m then mirrorWrite(frame, reg, m, m.Hide, m) end
        end
    end
end

-- Post-render visibility pass: mirrors follow their real FontStrings' shown
-- state (covers disabled/deleted elements and the master-off path — every
-- hide funnels through here). Content/appearance are owned by mirrorElement.
-- Guarded writes: a suspended registry is skipped whole, and the first denial
-- inside the loop latches and stops the rest of that registry's writes.
local function syncMirrors(frame)
    local regs = frame._tdMirrors
    if not regs then return end
    local fss = frame._tdFontStrings
    for _, reg in pairs(regs) do
        if not reg.suspended then
            for id, m in pairs(reg.byId) do
                local fs = fss and fss[id]
                if fs then
                    mirrorWrite(frame, reg, m, m.SetShown, m, fs:IsShown())
                else
                    mirrorWrite(frame, reg, m, m.Hide, m)
                end
                if reg.suspended then break end
            end
        end
    end
end

-- ============================================================
-- BACKGROUND ELEMENTS (contentType "backdrop", 2026-11-01)
-- A plain backing shape with no text -- a rounded box or a pill -- that text
-- elements can anchor to (resolveAnchorTarget finds it in frame._tdBackdrops).
--   width / height     its size
--   shape              "BOX" (small corners) | "PILL" (round ends at the kit's
--                      largest corner art: a true pill up to 16px tall)
--   color              { r, g, b, a } its fill (default black, 0.6)
--   borderColor        optional { r, g, b, a }: a 1px ring
--   layer              "FRONT" (under the text, over the frame's bars) | "BEHIND"
--                      (under the frame's bars and rings, e.g. tucked behind a ring)
-- Drawn with the kit's rounded surface (DandersUI Round.lua) on the TEXT overlay's
-- background layer (FRONT) or on an underlay frame just above the frame itself
-- (BEHIND); the region it is laid out on is an empty child frame, so the shape's
-- textures stay on the layer that orders them. Each background on a frame takes
-- its own surface slot (sublevel), so several can share a layer.
-- Not secure, not secret: plain sizes and colours, safe in combat.
-- ============================================================
local function ensureUnderlay(frame)
    local u = frame._tdUnderlay
    if u then return u end
    u = CreateFrame("Frame", nil, frame)
    u:SetAllPoints(frame)
    u:SetFrameLevel(frame:GetFrameLevel() + 1)
    frame._tdUnderlay = u
    return u
end

local BACKDROP_SLOTS = 14     -- fill sublevels -8 .. 5 (a ring lands 2 higher)
local function acquireBackdrop(frame, elem)
    frame._tdBackdrops = frame._tdBackdrops or {}
    local bd = frame._tdBackdrops[elem.id]
    if bd then return bd end
    bd = CreateFrame("Frame", nil, ensureTdOverlay(frame))
    frame._tdBackdropSlot = (frame._tdBackdropSlot or 0) + 1
    bd._tdSlot = -8 + ((frame._tdBackdropSlot - 1) % BACKDROP_SLOTS)
    frame._tdBackdrops[elem.id] = bd
    return bd
end

local function backdropTextures(bd)
    local s = bd._tdSurface
    if s then return s.textures or {} end
    return bd._tdPlain and { bd._tdPlain } or {}
end

local function hideBackdrop(bd)
    if bd._tdSurface and bd._tdSurface.Hide then bd._tdSurface:Hide() end
    if bd._tdPlain then bd._tdPlain:Hide() end
    bd:Hide()
end

local function paintBackdrop(frame, elem, bd, fontStringsById, enabledById)
    local w = tonumber(elem.width) or 60
    local h = tonumber(elem.height) or 18
    bd:SetSize(w > 1 and w or 1, h > 1 and h or 1)
    applyPosition(bd, frame, elem, fontStringsById, enabledById)
    local host = (elem.layer == "BEHIND") and ensureUnderlay(frame) or ensureTdOverlay(frame)
    -- A layer change moves the shape to the other host's textures.
    if bd._tdHost ~= host then
        if bd._tdSurface and bd._tdSurface.Hide then bd._tdSurface:Hide() end
        if bd._tdPlain then bd._tdPlain:Hide() end
        bd._tdSurface, bd._tdPlain, bd._tdHost = nil, nil, host
    end
    local c = elem.color or {}
    local r, g, b, a = c.r or 0, c.g or 0, c.b or 0, c.a or 0.6
    local border = type(elem.borderColor) == "table" and elem.borderColor or false
    local radius = (elem.shape == "PILL") and 8 or 4
    local UI = DF.GUI
    if UI and UI.CreateRoundedSurface then
        bd._tdSurface = UI:CreateRoundedSurface(host, {
            radius = radius, fill = { r, g, b, a }, border = border, borderWidth = 1,
            sublevel = bd._tdSlot, anchorTo = bd,
        })
        if bd._tdSurface and bd._tdSurface.Show then bd._tdSurface:Show() end
    else
        -- No kit (a stripped client): a square fill.
        local t = bd._tdPlain
        if not t then
            t = host:CreateTexture(nil, "BACKGROUND", nil, bd._tdSlot)
            bd._tdPlain = t
        end
        t:SetAllPoints(bd)
        t:SetColorTexture(r, g, b, a)
        t:Show()
    end
    bd:Show()
end

-- ============================================================
-- SHOW ON HOVER (elem.showOnHover, 2026-11-01)
-- TD has no condition engine of its own: an element's visibility is its enable,
-- the master / test toggles, the resolver's own blanks (Hide When 0, dead /
-- offline) and the overlay's out-of-range fade. Hover joins the element-level
-- rules here: an element marked Show on Hover renders like any other (text,
-- colour, position) and only its ALPHA follows the frame's hover state
-- (frame._tdHoverT, 0 .. 1), with an optional slide (placement above).
-- Render:SetHover is driven by the frame's own OnEnter / OnLeave (DF:OnFrameHoverChanged,
-- called from the same hover handlers that set dfIsHovered for the highlights), so
-- click-casting and the hover highlight are untouched. Alpha and anchors of the
-- overlay's own FontStrings only: never a secure frame, so it runs in combat.
-- ============================================================
Render.HOVER_FADE = 0.15

local function hoverRegion(frame, id)
    return (frame._tdFontStrings and frame._tdFontStrings[id]) or (frame._tdBackdrops and frame._tdBackdrops[id])
end

local function setRegionAlpha(region, a)
    if not region then return end
    if region._tdSlot then
        for _, t in ipairs(backdropTextures(region)) do t:SetAlpha(a) end
    else
        region:SetAlpha(a)
    end
end

-- Track whether `elem` is a hover element on this frame and give its region the
-- alpha it should have now.
local function applyHover(frame, elem, region)
    local els = frame._tdHoverEls
    if elem.showOnHover then
        if not els then
            els = {}
            frame._tdHoverEls = els
        end
        els[elem.id] = elem
        setRegionAlpha(region, frame._tdHoverT or 0)
    else
        if els and els[elem.id] then els[elem.id] = nil end
        if region._tdHoverA ~= 1 then
            setRegionAlpha(region, 1)
        end
    end
    region._tdHoverA = elem.showOnHover and (frame._tdHoverT or 0) or 1
end

local function hoverStep(frame)
    local t = frame._tdHoverT or 0
    local els = frame._tdHoverEls
    if not els then return end
    for id, elem in pairs(els) do
        local region = hoverRegion(frame, id)
        if region then
            setRegionAlpha(region, t)
            region._tdHoverA = t
            if elem.hoverSlide and elem.hoverSlide ~= 0 then
                applyPosition(region, frame, elem, frame._tdFontStrings, nil)
            end
        end
    end
end

-- The frame's hover went on or off: fade its hover elements in / out (and slide
-- them). frame._tdForceHover (the designer's "Show Hover State") holds it on.
function Render:SetHover(frame, on)
    if not frame then return end
    on = (on or frame._tdForceHover) and true or false
    frame._tdHoverOn = on
    local goal = on and 1 or 0
    local els = frame._tdHoverEls
    if not (els and next(els)) or not frame._tdOverlay then
        frame._tdHoverT = goal
        return
    end
    if (frame._tdHoverT or 0) == goal then
        hoverStep(frame)
        return
    end
    local ov = frame._tdOverlay
    ov:SetScript("OnUpdate", function(self, elapsed)
        local t = frame._tdHoverT or 0
        local step = (elapsed or 0) / Render.HOVER_FADE
        if frame._tdHoverOn then t = t + step else t = t - step end
        if t >= 1 then t = 1 elseif t <= 0 then t = 0 end
        frame._tdHoverT = t
        hoverStep(frame)
        if t == (frame._tdHoverOn and 1 or 0) then self:SetScript("OnUpdate", nil) end
    end)
end

-- Every frame's hover handler (Frames/Create.lua, Frames/Headers.lua, the unit
-- frames' preview) calls this. The Text Designer's hover elements, then whatever
-- the frame itself asked to hear (frame.dfHoverHook(frame, on): unit frames dim
-- their portrait).
function DF:OnFrameHoverChanged(frame, on)
    if not frame then return end
    Render:SetHover(frame, on)
    local hook = rawget(frame, "dfHoverHook")
    if hook then hook(frame, on and true or false) end
end

-- ============================================================
-- RENDER ONE ELEMENT
-- ============================================================

-- Renders a single elem on a frame. Called per-element from UpdateFrame.
-- source is a DataSource (Live or Mock).
local function updateOne(frame, elem, source, globalDefaults, enabledById)
    -- ☠ (Removed) a per-ELEMENT entry trace logging id/type/enabled. It was the largest
    -- single source of log volume in the addon and reported nothing the element's own
    -- config does not already say -- an entry marker, never an outcome.
    --
    -- Measured before removal: renders are driven from DF:UpdateHealthFast, so per unit
    -- per health tick, and one render emitted 2 + E lines for E elements. A 20-frame raid
    -- at three elements each is 100 lines per render and thousands per second sustained --
    -- the 10,000-line buffer overwrote itself in under two seconds, so enabling TD
    -- destroyed the trace it was enabled to capture.
    --
    -- The guard was right and is not the lesson; the line was. Render:UpdateFrame already
    -- reports the unit and element COUNT once per frame, and the outcome detail lives
    -- further down this function where it earns its cost.
    if not elem.enabled then
        local existing = frame._tdFontStrings and frame._tdFontStrings[elem.id]
        if existing then existing:Hide() end
        local bd = frame._tdBackdrops and frame._tdBackdrops[elem.id]
        if bd then hideBackdrop(bd) end
        if frame._tdHoverEls then frame._tdHoverEls[elem.id] = nil end
        return
    end
    if elem.contentType == "backdrop" then
        local bd = acquireBackdrop(frame, elem)
        paintBackdrop(frame, elem, bd, frame._tdFontStrings, enabledById)
        applyHover(frame, elem, bd)
        return
    end
    local fs = acquireFontString(frame, elem)
    local app = applyAppearance(fs, frame, elem, globalDefaults)
    applyPosition(fs, frame, elem, frame._tdFontStrings, enabledById)
    -- Apply class color if requested
    if fs._useClassColor then
        local token = source:GetClassToken()
        local color = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        if color then
            -- Reuse the appearance applyAppearance already resolved above: same elem,
            -- same globalDefaults, same deterministic function. Do not re-resolve it just
            -- to read one alpha -- resolveAppearance is #2 in every combat trace.
            fs:SetTextColor(color.r, color.g, color.b, (app.color and app.color.a) or 1)
        end
    end
    -- Aura Designer "Name Text"/"Health Text" colour override wins over the
    -- resolved/class colour while an aura is active. Stamp the category so
    -- SetAuraColorOverride can find this FontString; honour any standing
    -- override so it survives this re-render.
    local cat = CONTENT_HINTS[elem.contentType]
    fs._tdCategory = cat
    local ov = cat and frame._tdAuraColor and frame._tdAuraColor[cat]
    if ov then
        fs:SetTextColor(ov.r, ov.g, ov.b, ov.a or 1)
    end
    local text = getResolver():Resolve(elem, source)
    local safeText = getMS().SafeText(text)
    fs:SetText(safeText)
    fs:Show()
    applyHover(frame, elem, fs)
    -- AD mirrors: feed the coloured cover the SAME resolved appearance + text.
    if frame._tdMirrors then
        mirrorElement(frame, elem, fs, app, safeText)
    end
end

-- ============================================================
-- PUBLIC ENTRY POINTS
-- ============================================================

-- Renders all (or hint-filtered) elements on a frame.
-- frame is any frame (preview mock frame or real unit frame).
-- tdDB is the textDesigner db table (DF.db.party.textDesigner or .raid).
-- source is the DataSource.
-- hint is one of "all" / "name" / "health" / "power" / "absorb" / "heal" / "range" / "threat".
-- isPreview: if true, ignore tdDB.enabled (master toggle) so the preview always
-- renders. Live frames pass nil/false so the master toggle still hides them.
function Render:UpdateFrame(frame, tdDB, source, hint, isPreview)
    if not frame or not tdDB then
        DF:Debug("TD", "Render:UpdateFrame: nil frame or tdDB (isPreview=%s)", tostring(isPreview))
        return
    end
    -- ☠ GUARDED — and note the `or {}` in the length: unguarded, that allocated a
    -- THROWAWAY TABLE on every call, purely to take a count for a line that was
    -- then dropped. Per frame, per render, with TD logging off. The four tostring()
    -- calls were the cheaper half of the problem.
    if DF:DebugActive("TD") then
        DF:Debug("TD", "Render:UpdateFrame: unit=%s hint=%s isPreview=%s enabled=%s elements=%d",
            tostring(frame.unit), tostring(hint), tostring(isPreview),
            tostring(tdDB.enabled), #(tdDB.elements or {}))
    end
    if not isPreview and not tdDB.enabled then
        DF:Debug("TD", "Render:UpdateFrame: master toggle OFF, hiding all fontstrings")
        -- Master toggle off (live mode only) — hide all FontStrings
        if frame._tdFontStrings then
            for _, fs in pairs(frame._tdFontStrings) do fs:Hide() end
        end
        for _, bd in pairs(frame._tdBackdrops or {}) do hideBackdrop(bd) end
        syncMirrors(frame)   -- mirrors follow their (now hidden) real FontStrings
        return
    end
    hint = hint or "all"
    local globalDefaults = tdDB.globalDefaults
    -- Pre-create the FontString for every enabled element before any element is
    -- positioned, so one anchored to a later-listed element finds its target on
    -- the very first pass. The same sweep records which ids are enabled for
    -- resolveAnchorTarget's disabled check.
    wipe(enabledScratch)
    for _, elem in ipairs(tdDB.elements or {}) do
        if elem.enabled then
            enabledScratch[elem.id] = true
            if elem.contentType == "backdrop" then
                acquireBackdrop(frame, elem)
            else
                acquireFontString(frame, elem)
            end
        end
    end
    -- `hint` is either a single category string, "all", or -- from the coalescing
    -- wrapper -- a SET of categories accumulated over one frame. The table branch is
    -- last so the single-string callers (Preview, and any direct
    -- RenderTextDesignerNow) keep the exact comparison they always had.
    local hintIsSet = type(hint) == "table"
    for _, elem in ipairs(tdDB.elements or {}) do
        local elemHint = CONTENT_HINTS[elem.contentType]
        if hint == "all" or elemHint == "all" or elemHint == hint
            or (hintIsSet and hint[elemHint]) then
            updateOne(frame, elem, source, globalDefaults, enabledScratch)
        end
    end

    -- Sweep: hide FontStrings for elements that no longer exist in tdDB.
    -- Cached entries are intentionally left in place so a subsequent add reusing
    -- the id recovers the same FontString instead of leaking another one.
    if frame._tdFontStrings then
        wipe(liveIdScratch)
        for _, elem in ipairs(tdDB.elements or {}) do
            liveIdScratch[elem.id] = true
        end
        for id, fs in pairs(frame._tdFontStrings) do
            if not liveIdScratch[id] then
                fs:Hide()
            end
        end
        for id, bd in pairs(frame._tdBackdrops or {}) do
            if not liveIdScratch[id] then hideBackdrop(bd) end
        end
        if frame._tdHoverEls then
            for id in pairs(frame._tdHoverEls) do
                if not liveIdScratch[id] then frame._tdHoverEls[id] = nil end
            end
        end
    end

    -- Out-of-range fade (element-specific OOR mode). TD now owns the unit's
    -- text, so the unified OOR "Text Alpha" dims the whole TD overlay — every
    -- element at once — while the unit is out of range. SetAlphaFromBoolean is
    -- secret-safe (dfInRange may be a secret boolean on non-healer specs in
    -- Midnight). When oorEnabled is off, the frame-level OOR fade cascades to
    -- the overlay as a child, so leave it at full alpha here. Test frames are
    -- included (dfIsTestFrame): TestMode sets frame.dfInRange from the test OOR
    -- state, so the preview shows the same fade. The Options mock preview
    -- (isPreview but not a test frame) is skipped — it has no range state.
    if (not isPreview or frame.dfIsTestFrame) and frame.unit and frame._tdOverlay then
        local fdb = DF:GetFrameDB(frame)
        local ov = frame._tdOverlay
        if fdb and fdb.oorEnabled then
            local inRange = frame.dfInRange
            if not (issecretvalue and issecretvalue(inRange)) and inRange == nil then
                inRange = true
            end
            local oorAlpha = fdb.oorTextAlpha or 0.55
            if ov.SetAlphaFromBoolean then
                ov:SetAlphaFromBoolean(inRange, 1, oorAlpha)
            else
                ov:SetAlpha(inRange and 1 or oorAlpha)
            end
        else
            ov:SetAlpha(1)
        end
    end

    -- Aura Designer mirrors: replay this render onto every registered mirror
    -- (all hides in the pass have landed by now, so visibility copies clean).
    syncMirrors(frame)
end

-- ============================================================
-- AURA DESIGNER MIRROR API
-- ============================================================

-- Enable colour-by-cover mirrors for a category ("name"/"health"). parent is
-- the AD-owned region (an aura-slot child — its secret visibility gates the
-- cover); color is the AD override colour. Re-calling with a new colour
-- restamps live mirrors; a new parent (container rebuilt) drops the old
-- mirrors and materializes fresh ones on the next sync.
function Render:EnableMirrors(frame, category, parent, color)
    if not (frame and category and parent and color) then return end
    frame._tdMirrors = frame._tdMirrors or {}
    local reg = frame._tdMirrors[category]
    if reg and reg.parent ~= parent then
        -- Old mirrors sit on the outgoing slot subtree, which may already be
        -- denied — retire best-effort, never trust the writes.
        for _, m in pairs(reg.byId) do retireMirror(m) end
        reg = nil
    end
    if not reg then
        reg = { category = category, parent = parent, color = color, byId = {} }
        frame._tdMirrors[category] = reg
    else
        reg.color = color
        for _, m in pairs(reg.byId) do
            mirrorWrite(frame, reg, m, m.SetTextColor, m, color.r, color.g, color.b, color.a or 1)
            if reg.suspended then break end
        end
    end
    syncMirrors(frame)
    -- MATERIALIZE: mirrors are only created when their element RENDERS
    -- (mirrorElement inside updateOne) — but some categories rarely re-render
    -- on their own (a name element only re-renders on roster/edit, unlike
    -- health, which ticks constantly). If this registry has no mirrors yet,
    -- force one category-hinted render so the covers exist immediately
    -- instead of waiting for an organic re-render that may never come.
    if next(reg.byId) == nil and DF.UpdateTextDesigner then
        DF:UpdateTextDesigner(frame, category)
    end
end

function Render:DisableMirrors(frame, category)
    local regs = frame and frame._tdMirrors
    local reg = regs and regs[category]
    if not reg then return end
    for _, m in pairs(reg.byId) do retireMirror(m) end
    regs[category] = nil
end

-- Tears down all FontStrings on a frame (mode switch, profile change).
function Render:Teardown(frame)
    if frame._tdFontStrings then
        for _, fs in pairs(frame._tdFontStrings) do
            fs:Hide()
            fs:ClearAllPoints()
            -- NB: FontStrings are not frames — they have no OnUpdate script, so
            -- never call SetScript/GetScript("OnUpdate") on them (it errors).
        end
        wipe(frame._tdFontStrings)
    end
    if frame._tdMirrors then
        for _, reg in pairs(frame._tdMirrors) do
            for _, m in pairs(reg.byId) do retireMirror(m) end
        end
        frame._tdMirrors = nil
    end
    if frame._tdBackdrops then
        for _, bd in pairs(frame._tdBackdrops) do
            hideBackdrop(bd)
            bd:ClearAllPoints()
        end
        frame._tdBackdrops = nil
    end
    frame._tdHoverEls = nil
    if frame._tdOverlay then
        frame._tdOverlay:SetScript("OnUpdate", nil)
        frame._tdOverlay:Hide()
        frame._tdOverlay:ClearAllPoints()
        frame._tdOverlay = nil
    end
end

-- For Phase C: called from existing update functions to refresh TD elements
-- on a unit frame. Phase B leaves this stubbed — Phase C will populate it.
-- SYNCHRONOUS render. This is the original UpdateTextDesigner body; the name it used
-- to have is now the COALESCING wrapper below, which is what callers should use.
-- Call this directly only when the FontStrings must be correct before the next line
-- of Lua runs -- nothing in DF needs that today.
function DF:RenderTextDesignerNow(frame, hint)
    if not frame then
        DF:Debug("TD", "UpdateTextDesigner: no frame")
        return
    end
    if not frame.unit then
        DF:Debug("TD", "UpdateTextDesigner: frame has no .unit")
        return
    end
    -- Pet frames are not part of the Text Designer; they render their own legacy
    -- name/health text with pet-specific settings. Pets inherit their owner mode's
    -- TD preset, so without this guard an enabled TD would stamp party/raid-styled
    -- text onto pet frames. Keep TD off them entirely.
    if frame.isPetFrame then
        DF:Debug("TD", "UpdateTextDesigner: skipping pet frame %s", tostring(frame.unit))
        return
    end
    -- MEMORY TEST (enableTextDesigner): TD re-renders every element on every frame
    -- on every health tick, so it is the one system worth isolating on its own.
    -- Tear the FontStrings/mirrors down once on the transition rather than just
    -- skipping, so the memory reading actually moves.
    if DF:MemTestDisabled("enableTextDesigner") then
        if not frame.dfTDMemTestCleared then
            frame.dfTDMemTestCleared = true
            if DF.TextDesigner and DF.TextDesigner.Render then
                DF.TextDesigner.Render:Teardown(frame)
            end
        end
        return
    end
    frame.dfTDMemTestCleared = nil
    local db = DF:GetFrameDB(frame)
    if not db then
        DF:Debug("TD", "UpdateTextDesigner: no db for frame.unit=%s", tostring(frame.unit))
        return
    end
    local tdDB = DF:ResolveTextDesigner(frame)
    if not tdDB then
        DF:Debug("TD", "UpdateTextDesigner: no resolved textDesigner preset for unit=%s", tostring(frame.unit))
        return
    end
    -- Guarded: this runs per unit per health tick in combat, and the argument list
    -- walks the element array for its length plus three tostrings. DF:Debug drops
    -- the line when TD is filtered off, but the CALLER builds the args first.
    if DF:DebugActive("TD") then
        DF:Debug("TD", "UpdateTextDesigner: unit=%s hint=%s enabled=%s elements=%d",
            tostring(frame.unit), tostring(hint),
            tostring(tdDB.enabled),
            tdDB.elements and #tdDB.elements or -1)
    end

    -- Test frames: use the per-unit Test data source, and hide the text when
    -- EITHER the master toggle or the test-mode toggle (db.testShowTextDesigner)
    -- is off. Test frames preview what the live frames will show, and a disabled
    -- Text Designer shows nothing live; the designer page has its own preview
    -- for building a layout with it switched off.
    if frame.dfIsTestFrame then
        if db.testShowTextDesigner == false or not tdDB.enabled then
            if frame._tdFontStrings then
                for _, fs in pairs(frame._tdFontStrings) do fs:Hide() end
            end
            syncMirrors(frame)
            return
        end
        local source = DF.TextDesigner.DataSource.Test(frame)
        Render:UpdateFrame(frame, tdDB, source, hint, true)  -- isPreview=true
        return
    end

    local source = DF.TextDesigner.DataSource.Live(frame)
    Render:UpdateFrame(frame, tdDB, source, hint)
end

-- ============================================================
-- RENDER COALESCING
-- ============================================================
-- Per-element hint filtering exists (the CONTENT_HINTS gate in Render:UpdateFrame) and
-- the per-resolve cost is at the floor: resolveAppearance is pooled,
-- ApplyHighlightStyle early-outs, and RESOLVERS.hp_current is IRREDUCIBLE because
-- UnitHealth boxes a secret per call. What remains is rendering too OFTEN -- health,
-- power, range and threat can each fire for the same unit inside one frame. So: mark
-- dirty, render ONCE per frame with the union of the hints asked for; a hint union still
-- resolves fewer elements than "all".
-- The cost is that text lands up to one frame (~16 ms) later. Nothing in DF reads a
-- FontString's contents back after asking for an update.
local tdBufA, tdBufB = {}, {}
local tdPending = tdBufA        -- frame -> "all" | { [hint] = true }
local tdSetPool = {}            -- recycled hint sets; steady state allocates nothing
local tdDriver

local function tdFlush()
    -- ☠ DOUBLE BUFFER, not "iterate and clear". A render can mark another frame
    -- dirty re-entrantly (the AD colour-override path calls back into
    -- UpdateTextDesigner), and ADDING a key to the table being iterated is
    -- undefined in Lua. New marks land in the other buffer and flush next frame.
    local batch = tdPending
    tdPending = (batch == tdBufA) and tdBufB or tdBufA
    for frame, hint in pairs(batch) do
        DF:RenderTextDesignerNow(frame, hint)
        if type(hint) == "table" then
            wipe(hint)
            tdSetPool[#tdSetPool + 1] = hint
        end
    end
    wipe(batch)
end

local function ensureTDDriver()
    if not tdDriver then
        tdDriver = CreateFrame("Frame")
        tdDriver:Hide()
        -- Hide FIRST: one flush per shown-frame, and tdFlush may re-Show us via a
        -- re-entrant mark, which must schedule the NEXT frame rather than be undone.
        tdDriver:SetScript("OnUpdate", function(self)
            self:Hide()
            tdFlush()
        end)
    end
    tdDriver:Show()
end

-- Request a Text Designer render. Coalesced: several calls for one frame within the
-- same frame collapse into a single render carrying the UNION of their hints.
function DF:UpdateTextDesigner(frame, hint)
    if not frame then
        -- ☠ Named for THIS function. Both this and RenderTextDesignerNow emitted the
        -- identical string, so the log could not say which of the two was called with no
        -- frame -- the coalescing wrapper or the render itself, which are reached from
        -- different callers and mean different things.
        DF:Debug("TD", "UpdateTextDesigner (coalescing entry): no frame")
        return
    end
    hint = hint or "all"
    local cur = tdPending[frame]
    if cur == "all" then return end          -- already maximal; nothing to widen
    if hint == "all" then
        if type(cur) == "table" then
            wipe(cur)
            tdSetPool[#tdSetPool + 1] = cur
        end
        tdPending[frame] = "all"
    else
        if cur == nil then
            local n = #tdSetPool
            if n > 0 then
                cur, tdSetPool[n] = tdSetPool[n], nil
            else
                cur = {}
            end
            tdPending[frame] = cur
        end
        cur[hint] = true
    end
    ensureTDDriver()
end

-- ============================================================
-- AURA DESIGNER COLOUR OVERRIDE
-- AD's "Name Text" / "Health Text" indicators recolour the unit's text on aura
-- presence. The legacy frame.nameText/healthText are retired (IsLegacyTextHidden
-- == true), so AD drives the colour of the TD-owned FontStrings instead, per
-- category ("name" / "health"). The override is stored on the frame and honoured
-- by updateOne, so it survives TD's own re-renders; SetAuraColorOverride also
-- recolours the live FontStrings immediately (and on each expiring-ticker tick).
-- ============================================================



-- ============================================================
-- DIAGNOSTICS — /df debug tdmirror
-- Developer probe for the mirror engine ahead of the AD factory wiring:
-- toggles ALWAYS-VISIBLE mirrors (magenta name / cyan health) on the
-- player's frame. Validates the two things the feature stands on: the
-- GetText->SetText secret passthrough (health text keeps ticking in combat
-- with no error) and cover fidelity (the coloured copy sits glyph-perfect
-- over the real text). Developer output: raw prints by design.
-- ============================================================
function DF:DebugTDMirror()
    local target
    local function findPlayer(frame)
        if not target and frame and frame.unit == "player" then target = frame end
    end
    if DF.IteratePartyFrames then DF:IteratePartyFrames(findPlayer) end
    if not target and DF.IterateRaidFrames then DF:IterateRaidFrames(findPlayer) end
    if not target then
        DF:Say("no player unit frame found")
        return
    end
    if target._tdMirrorProbeOn then
        target._tdMirrorProbeOn = nil
        Render:DisableMirrors(target, "name")
        Render:DisableMirrors(target, "health")
        if target._tdMirrorProbeHolder then target._tdMirrorProbeHolder:Hide() end
        DF:Say("probe OFF")
        return
    end
    local holder = target._tdMirrorProbeHolder
    if not holder then
        holder = CreateFrame("Frame", nil, target._tdOverlay or target)
        holder:SetAllPoints(target)
        holder:SetFrameLevel(((target._tdOverlay and target._tdOverlay:GetFrameLevel())
            or (target:GetFrameLevel() + 25)) + 5)
        target._tdMirrorProbeHolder = holder
    end
    holder:Show()
    target._tdMirrorProbeOn = true
    Render:EnableMirrors(target, "name",   holder, { r = 1, g = 0, b = 1, a = 1 })
    Render:EnableMirrors(target, "health", holder, { r = 0, g = 1, b = 1, a = 1 })
    if DF.UpdateTextDesigner then DF:UpdateTextDesigner(target, "all") end
    local o = DF:Out("Text Designer", "mirror probe on")
    o:Line("Name should read MAGENTA, health CYAN, glyph-perfect over the real text,", "NEUTRAL")
    o:Line("and health should still tick in combat.", "NEUTRAL")
    o:Line("Needs Text Designer enabled with name and health elements.", "NEUTRAL")
    -- NOT o:Hints("/df debug tdmirror"): a "More:" footer naming the command you just
    -- ran reads as a bug. Toggles say so in words instead.
    o:Line("Run /df debug tdmirror again to turn this off.", "NEUTRAL")
end
