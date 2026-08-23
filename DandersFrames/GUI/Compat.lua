local addonName, DF = ...
local GUI = DF.GUI
local type = type

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

-- CreateSlider(parent, label, min, max, step, db, key, callback,
--              lightweightUpdate, usePreviewMode, customGet, customSet, accentColor)
function GUI:CreateSlider(parent, label, minVal, maxVal, step, dbTable, dbKey, callback,
                          lightweightUpdate, usePreviewMode, customGet, customSet, accentColor)
    local get = customGet
    local set = customSet
    if not get and dbTable then get = function() return dbTable[dbKey] end end
    if not set and dbTable then set = function(v) dbTable[dbKey] = v end end
    return GUI.CreateSliderNative(self, parent, {
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
    })
end

-- CreateDropdown(parent, label, options, db, key, callback, customGet, customSet, opts)
function GUI:CreateDropdown(parent, label, options, dbTable, dbKey, callback, customGet, customSet, opts)
    opts = opts or {}
    local get = customGet
    local set = customSet
    if not get and dbTable then get = function() return dbTable[dbKey] end end
    if not set and dbTable then set = function(v) dbTable[dbKey] = v end end
    return GUI.CreateDropdownNative(self, parent, {
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
    })
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
