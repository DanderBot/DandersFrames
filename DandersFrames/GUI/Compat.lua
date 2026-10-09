local addonName, DF = ...
local GUI = DF.GUI
local type = type
local select = select

-- ============================================================
-- POSITIONAL COMPATIBILITY SHIM
-- ------------------------------------------------------------
-- DandersUI's factories take (parent, opts). DandersFrames has ~130 call sites
-- on the older positional signatures, spread across the options companion's
-- pages. Rewriting them all in one commit would be a ~130-file diff with no
-- user-visible benefit and every regression hidden inside it.
--
-- So the positional forms live HERE, defined ON THE HOST -- which shadows the
-- pack's native ones for DandersFrames only. Pages migrate opportunistically;
-- when the last one has, this file is deleted and the shadow lifts.
--
-- ☠ Each shim builds get/set closures over db[key] (or the caller's
-- customGet/customSet) and passes dbRef = { db, key } so the settings hooks --
-- override indicators, runtime-write redirect, search registration -- see the
-- same (db, key) pair they saw before the split.
-- ============================================================

-- The modified-default dot sits against the top-left of the control's label,
-- just clear of the first letter, so it is in the same place whatever the
-- label says. The kit places it after the text; this re-anchors it after
-- every kit placement.
--
-- `label` is optional: the kit anchors the dot to the label it measured, so
-- that anchor is read back when the caller cannot reach the FontString (the
-- kit slider does not expose it). `container.dfDotTopLeftOf` names a different
-- FontString to sit against: a card header's tick hides its own caption and
-- the card title is the label.
-- Y is off the text box's top, and capitals start a pixel or two below it: -1
-- centres the dot about level with the top of the capitals. X -4 leaves the
-- 6px dot 1px clear of the text and, in a checkbox's 8px gap, of the box.
local DOT_TL_X, DOT_TL_Y, DOT_TL_HIT = -4, -1, 8
-- Published for the card header's own mark, which sits in the same place.
GUI.ModifiedDotTopLeft = { x = DOT_TL_X, y = DOT_TL_Y, hit = DOT_TL_HIT, size = 6 }

-- An override marker that says "an auto layout changes something here" (a nav
-- tab or category, the profile chip, the position lock) takes the colour the
-- control dot uses for an override: the raid accent, since layouts are raid
-- only. Painted on every show, because the accent can be re-themed.
function GUI:ShowLayoutOverrideMarker(marker, show)
    if show then
        local c = GUI.GetThemeColorFor and GUI.GetThemeColorFor(true)
        if c and marker.icon then marker.icon:SetVertexColor(c.r, c.g, c.b) end
    end
    marker:SetShown(show and true or false)
end

-- The card a control belongs to, if any: the header tick names it directly,
-- anything in a card's body reaches it through its settings group.
local function CardOf(control)
    local card = rawget(control, "dfCardSection")
    local g = rawget(control, "settingsGroup")
    while not card and g do
        card = rawget(g, "parentSection")
        g = rawget(g, "settingsGroup")
    end
    return card
end

function GUI:PinModifiedDotTopLeft(container, label)
    local kitUpdateDot = rawget(container, "UpdateModifiedDot")
    if not kitUpdateDot then return container end
    local ownLabel = label
    container.UpdateModifiedDot = function(self)
        local on, kind = kitUpdateDot(self)
        local dot, hit = rawget(self, "modifiedDot"), rawget(self, "modifiedDotHit")
        if on and dot then
            -- Read per update: a popout row repoints the kit at the name it
            -- draws (modifiedDotLabel) after the control is built.
            local named = rawget(self, "modifiedDotLabel")
            if not ownLabel and not named then ownLabel = select(2, dot:GetPoint(1)) end
            local target = rawget(self, "dfDotTopLeftOf") or named or ownLabel
            if target then
                dot:ClearAllPoints()
                dot:SetPoint("CENTER", target, "TOPLEFT", DOT_TL_X, DOT_TL_Y)
                if hit then
                    hit:SetSize(DOT_TL_HIT, DOT_TL_HIT)
                    hit:ClearAllPoints()
                    hit:SetPoint("CENTER", target, "TOPLEFT", DOT_TL_X, DOT_TL_Y)
                end
            end
        end
        -- The card's header mark counts this control; it re-asks on its own.
        local card = CardOf(self)
        if card and card.QueueModifiedMark then card:QueueModifiedMark() end
        return on, kind
    end
    -- A dot the kit already painted while building the control is re-placed
    -- now. The kit slider paints in its constructor and repaints from OnShow,
    -- which a slider born visible never gets.
    local dot = rawget(container, "modifiedDot")
    if dot and dot:IsShown() then container:UpdateModifiedDot() end
    return container
end

-- CreateSlider(parent, label, min, max, step, db, key, callback,
--              lightweightUpdate, usePreviewMode, customGet, customSet, accentColor)
function GUI:CreateSlider(parent, label, minVal, maxVal, step, dbTable, dbKey, callback,
                          lightweightUpdate, usePreviewMode, customGet, customSet, accentColor)
    local get = customGet
    local set = customSet
    if not get and dbTable then get = function() return dbTable[dbKey] end end
    if not set and dbTable then set = function(v) dbTable[dbKey] = v end end
    return GUI:PinModifiedDotTopLeft(GUI.CreateSliderNative(self, parent, {
        label       = label,
        min         = minVal,
        max         = maxVal,
        step        = step,
        get         = get,
        set         = set,
        onChanged   = callback,
        lightweight = lightweightUpdate,
        previewMode = usePreviewMode,
        accent      = accentColor,
        -- ⚠ dbRef only when there is a real top-level key. Consumers that pass
        -- customSet with dbKey = nil do so precisely so the override system does
        -- not track a key that does not exist at the top level of dbTable.
        dbRef       = (dbTable and type(dbKey) == "string") and { db = dbTable, key = dbKey } or nil,
    }))
end

-- CreateDropdown(parent, label, options, db, key, callback, customGet, customSet, opts)
function GUI:CreateDropdown(parent, label, options, dbTable, dbKey, callback, customGet, customSet, opts)
    opts = opts or {}
    local get = customGet
    local set = customSet
    if not get and dbTable then get = function() return dbTable[dbKey] end end
    if not set and dbTable then set = function(v) dbTable[dbKey] = v end end
    return GUI:PinModifiedDotTopLeft(GUI.CreateDropdownNative(self, parent, {
        label          = label,
        options        = options,
        get            = get,
        set            = set,
        onChanged      = callback,
        dbRef          = (dbTable and type(dbKey) == "string") and { db = dbTable, key = dbKey } or nil,
        -- display flags pass straight through
        accent         = opts.accent,
        inline         = opts.inline,
        optionsFunc    = opts.optionsFunc,
        searchable     = opts.searchable,
        menuAlign      = opts.menuAlign,
        onRuntimeWrite = opts.onRuntimeWrite,
    }))
end

-- CreateAnchorGrid(parent, label, db, keyH, keyV, callback, opts)
function GUI:CreateAnchorGrid(parent, label, dbTable, keyH, keyV, callback, opts)
    opts = opts or {}
    return GUI.CreateAnchorGridNative(self, parent, {
        label           = label,
        onChanged       = callback,
        dbRef           = { db = dbTable, keyH = keyH, keyV = keyV },
        transposedFn    = opts.transposedFn,
        verticalInertFn = opts.verticalInertFn,
        wrapMirroredFn  = opts.wrapMirroredFn,
    })
end
