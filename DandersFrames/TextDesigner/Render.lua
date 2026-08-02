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

local wipe = wipe

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
local function resolveAnchorTarget(elem, frame, fontStringsById, enabledById)
    local target = elem.anchorTo or "FRAME"
    if target == "FRAME" then return frame end
    local targetId = tonumber(target)
    if targetId and fontStringsById and fontStringsById[targetId]
        and (not enabledById or enabledById[targetId]) then
        return fontStringsById[targetId]
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
    -- health/power bars but below the status/defensive/aura icons. The old +100
    -- overshot and drew TD text on top of the icon layer.
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
    -- Font
    DF:SafeSetFont(fs, fontPath(app.font), app.fontSize, app.outline)
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

-- Applies position to the FontString (separate from appearance so we can
-- update position when anchorTo's target moves).
local function applyPosition(fs, frame, elem, fontStringsById, enabledById)
    fs:ClearAllPoints()
    local target = resolveAnchorTarget(elem, frame, fontStringsById, enabledById)
    fs:SetPoint(elem.anchor or "CENTER", target, elem.anchor or "CENTER",
        elem.offsetX or 0, elem.offsetY or 0)
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

-- Feed one rendered element to every matching mirror (called from updateOne
-- with the element's resolved appearance + the exact safe text just set on
-- the real FontString). A registered-but-no-longer-matching mirror (the user
-- re-typed a group's items) is hidden so it can't linger as a stale cover.
local function mirrorElement(frame, elem, fs, app, safeText)
    for _, reg in pairs(frame._tdMirrors) do
        local m = reg.byId[elem.id]
        if mirrorCategoryMatches(elem, reg.category) then
            if not m then
                m = reg.parent:CreateFontString(nil, "OVERLAY")
                m:SetAllPoints(fs)   -- anchors track the real text render-side
                local c = reg.color
                m:SetTextColor(c.r, c.g, c.b, c.a or 1)
                reg.byId[elem.id] = m
            end
            -- Same setter, same resolved inputs -> identical rendering.
            DF:SafeSetFont(m, fontPath(app.font), app.fontSize, app.outline)
            -- Same SafeText value the real FontString just received (secret
            -- passthrough; pcall + warn-once purely as a degrade path).
            local ok = pcall(m.SetText, m, safeText)
            if ok then
                m:SetShown(fs:IsShown())
            else
                m:Hide()
                if not Render._mirrorWarned then
                    Render._mirrorWarned = true
                    DF:DebugWarn("TD", "mirror SetText failed — AD text colour degraded off")
                end
            end
        elseif m then
            m:Hide()
        end
    end
end

-- Post-render visibility pass: mirrors follow their real FontStrings' shown
-- state (covers disabled/deleted elements and the master-off path — every
-- hide funnels through here). Content/appearance are owned by mirrorElement.
local function syncMirrors(frame)
    local regs = frame._tdMirrors
    if not regs then return end
    local fss = frame._tdFontStrings
    for _, reg in pairs(regs) do
        for id, m in pairs(reg.byId) do
            local fs = fss and fss[id]
            if fs then m:SetShown(fs:IsShown()) else m:Hide() end
        end
    end
end

-- ============================================================
-- RENDER ONE ELEMENT
-- ============================================================

-- Renders a single elem on a frame. Called per-element from UpdateFrame.
-- source is a DataSource (Live or Mock).
local function updateOne(frame, elem, source, globalDefaults, enabledById)
    -- ☠ GUARDED, and this is the most load-bearing guard in the file. This is the
    -- per-ELEMENT entry point, and TD renders are driven from DF:UpdateHealth —
    -- per unit per health tick in combat. Unguarded, the three tostring() calls
    -- allocated on every element of every frame on every tick. DF:Debug drops the
    -- line, but the CALLER builds the arguments before it can, and `TD` is a
    -- `noisy` category so it ships DISABLED — i.e. this was pure waste for
    -- essentially every user. Same idiom as the guard in UpdateTextDesigner below.
    if DF:DebugActive("TD") then
        DF:Debug("TD", "updateOne: id=%s type=%s enabled=%s",
            tostring(elem.id), tostring(elem.contentType), tostring(elem.enabled))
    end
    if not elem.enabled then
        local existing = frame._tdFontStrings and frame._tdFontStrings[elem.id]
        if existing then existing:Hide() end
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
            -- same globalDefaults, same deterministic function. This used to re-resolve
            -- the whole thing just to read one alpha, which is a wasted table (up to
            -- four) per class-coloured element per tick -- resolveAppearance is #2 in
            -- every combat trace.
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
        syncMirrors(frame)   -- mirrors follow their (now hidden) real FontStrings
        return
    end
    hint = hint or "all"
    local globalDefaults = tdDB.globalDefaults
    -- Pre-create the FontString for every enabled element before any element is
    -- positioned, so one anchored to a later-listed element finds its target on
    -- the very first pass (it previously fell back to frame-anchoring for one
    -- update, making anchored layouts jump just after a reload). The same sweep
    -- records which ids are enabled for resolveAnchorTarget's disabled check.
    wipe(enabledScratch)
    for _, elem in ipairs(tdDB.elements or {}) do
        if elem.enabled then
            enabledScratch[elem.id] = true
            acquireFontString(frame, elem)
        end
    end
    for _, elem in ipairs(tdDB.elements or {}) do
        local elemHint = CONTENT_HINTS[elem.contentType]
        if hint == "all" or elemHint == "all" or elemHint == hint then
            updateOne(frame, elem, source, globalDefaults, enabledScratch)
        end
    end

    -- Sweep: hide FontStrings for elements that no longer exist in tdDB.
    -- This handles the delete case (an element was removed; its FontString
    -- is still cached on the frame but should not display). Cached entries
    -- are intentionally left in place so a subsequent add reusing the id
    -- recovers the same FontString instead of leaking another one.
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
        for _, m in pairs(reg.byId) do m:Hide(); m:ClearAllPoints() end
        reg = nil
    end
    if not reg then
        reg = { category = category, parent = parent, color = color, byId = {} }
        frame._tdMirrors[category] = reg
    else
        reg.color = color
        for _, m in pairs(reg.byId) do
            m:SetTextColor(color.r, color.g, color.b, color.a or 1)
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
    for _, m in pairs(reg.byId) do m:Hide(); m:ClearAllPoints() end
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
            for _, m in pairs(reg.byId) do m:Hide(); m:ClearAllPoints() end
        end
        frame._tdMirrors = nil
    end
    if frame._tdOverlay then
        frame._tdOverlay:Hide()
        frame._tdOverlay:ClearAllPoints()
        frame._tdOverlay = nil
    end
end

-- For Phase C: called from existing update functions to refresh TD elements
-- on a unit frame. Phase B leaves this stubbed — Phase C will populate it.
function DF:UpdateTextDesigner(frame, hint)
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

    -- Test frames: use the per-unit Test data source and gate on the test-mode
    -- toggle (db.testShowTextDesigner) rather than the live master toggle. Like
    -- the preview, ignore the master toggle so designers can see their layout
    -- while building. When the test toggle is off, hide any TD text on the frame.
    if frame.dfIsTestFrame then
        if db.testShowTextDesigner == false then
            if frame._tdFontStrings then
                for _, fs in pairs(frame._tdFontStrings) do fs:Hide() end
            end
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
