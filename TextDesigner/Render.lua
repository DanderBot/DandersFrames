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

local function resolveAppearance(elem, globalDefaults)
    globalDefaults = globalDefaults or {}
    local overrides = elem.overrides or {}
    -- useClassColor is the one boolean field, so the `(override and value) or
    -- global` pattern the others use would swallow an override of FALSE (it
    -- falls through to the global default). Branch on the override flag instead.
    local useClassColor
    if overrides.useClassColor then
        useClassColor = elem.useClassColor or false
    else
        useClassColor = globalDefaults.useClassColor or false
    end
    return {
        font          = (overrides.font          and elem.font)          or globalDefaults.font          or "DF Roboto SemiBold",
        fontSize      = (overrides.fontSize      and elem.fontSize)      or globalDefaults.fontSize      or 10,
        color         = (overrides.color         and elem.color)         or globalDefaults.color         or {r=1, g=1, b=1, a=1},
        outline       = (overrides.outline       and elem.outline)       or globalDefaults.outline       or "SHADOW;NONE",
        useClassColor = useClassColor,
    }
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
-- RENDER ONE ELEMENT
-- ============================================================

-- Renders a single elem on a frame. Called per-element from UpdateFrame.
-- source is a DataSource (Live or Mock).
local function updateOne(frame, elem, source, globalDefaults, enabledById)
    DF:Debug("TD", "updateOne: id=%s type=%s enabled=%s",
        tostring(elem.id), tostring(elem.contentType), tostring(elem.enabled))
    if not elem.enabled then
        local existing = frame._tdFontStrings and frame._tdFontStrings[elem.id]
        if existing then existing:Hide() end
        return
    end
    local fs = acquireFontString(frame, elem)
    applyAppearance(fs, frame, elem, globalDefaults)
    applyPosition(fs, frame, elem, frame._tdFontStrings, enabledById)
    -- Apply class color if requested
    if fs._useClassColor then
        local token = source:GetClassToken()
        local color = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        if color then
            local app = resolveAppearance(elem, globalDefaults)
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
    fs:SetText(getMS().SafeText(text))
    fs:Show()
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
    DF:Debug("TD", "Render:UpdateFrame: unit=%s hint=%s isPreview=%s enabled=%s elements=%d",
        tostring(frame.unit), tostring(hint), tostring(isPreview),
        tostring(tdDB.enabled), #(tdDB.elements or {}))
    if not isPreview and not tdDB.enabled then
        DF:Debug("TD", "Render:UpdateFrame: master toggle OFF, hiding all fontstrings")
        -- Master toggle off (live mode only) — hide all FontStrings
        if frame._tdFontStrings then
            for _, fs in pairs(frame._tdFontStrings) do fs:Hide() end
        end
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
        local liveIds = {}
        for _, elem in ipairs(tdDB.elements or {}) do
            liveIds[elem.id] = true
        end
        for id, fs in pairs(frame._tdFontStrings) do
            if not liveIds[id] then
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
    DF:Debug("TD", "UpdateTextDesigner: unit=%s hint=%s enabled=%s elements=%d",
        tostring(frame.unit), tostring(hint),
        tostring(tdDB.enabled),
        tdDB.elements and #tdDB.elements or -1)

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

function Render:SetAuraColorOverride(frame, category, color)
    if not frame or not category or not color then return end
    frame._tdAuraColor = frame._tdAuraColor or {}
    frame._tdAuraColor[category] = color
    if frame._tdFontStrings then
        for _, fs in pairs(frame._tdFontStrings) do
            if fs._tdCategory == category then
                fs:SetTextColor(color.r, color.g, color.b, color.a or 1)
            end
        end
    end
end

function Render:ClearAuraColorOverride(frame, category)
    if not frame or not category then return end
    if not (frame._tdAuraColor and frame._tdAuraColor[category] ~= nil) then return end
    frame._tdAuraColor[category] = nil
    -- Re-render this category so TD reapplies its normal / class colour.
    DF:UpdateTextDesigner(frame, category)
end
