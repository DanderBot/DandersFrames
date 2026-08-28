local NS = ...

-- ============================================================
-- BORDER BUILDERS -- DandersFrames_Options/GUI/SettingsWidgets.lua
-- ------------------------------------------------------------
-- The Frame settings page builds its whole border block from ONE
-- GUI:CreateBorderControls call. Popout gate two splits that into two mounts
-- (Border, and Border Shadow beside it), and the split is only allowed if it
-- changes NOTHING: same widgets, same order, same db keys, same slot heights,
-- same seeded values, same greying.
--
-- So this file pins the single-call build as a GOLDEN INVENTORY and then drives
-- the SPLIT path over the same fixture and asserts the two are indistinguishable:
--
--   1. INVENTORY. 19 widgets, in order, each with its factory kind, label, db
--      key and slot height written out by hand below. A reordering or a renamed
--      key is a settings page that silently moved under the user.
--   2. DB SEED. Exactly two writes happen at BUILD time (the colour-source
--      default and the BorderColor table/alpha guard) and nothing else may be
--      touched -- a build that writes is a build that can dirty a profile just
--      by opening the panel.
--   3. GREY. Show Border off greys everything but its own checkbox; Border
--      Shadow off greys the four shadow sub-controls but not its toggle. Both
--      composed, both live.
--
-- ☠ THE HARNESS SHARES ONE LUA RUNTIME ACROSS EVERY TEST FILE, and this one
-- replaces the `DandersFrames` global to give SettingsWidgets.lua a host. It is
-- restored at the end.
--
-- ⚠ NO REAL WIDGETS ARE BUILT. Every factory is replaced with a recorder after
-- the file loads (CreateCheckbox / CreateColorPicker / CreateHeader are defined
-- IN SettingsWidgets.lua itself, so the stubs have to go on AFTERWARDS, not
-- before). What is under test is the BUILD ORDER and the predicates, not the
-- chrome -- the chrome has its own suites.
-- ============================================================

local savedDF = DandersFrames

-- ---- the host surface SettingsWidgets.lua reads at FILE SCOPE ------
-- All aliases, no behaviour: the file grabs these into locals on load and the
-- border factory touches none of them.
local function colour(v) return { r = v, g = v, b = v, a = 1 } end
local GUI = {
    _priv = {
        AddOverrideIndicators = function() end,
        CreateElementBackdrop = function(f) return f end,
        CreatePanelBackdrop   = function(f) return f end,
        ConfirmDeletePreset   = function() end,
        PromptPresetName      = function() end,
        OUTLINE_FLAG_ORDER    = {},
        LayoutPixelBorder     = function() end,
        pixelBordered         = function(f) return f end,
    },
    Colors = {
        panel = colour(0.12), element = colour(0.18), border = colour(0.25),
        hover = colour(0.22), text = colour(0.9), textDim = colour(0.5),
    },
    GetThemeColor = function() return 1, 1, 1, 1 end,
    SnapLen = function(_, n) return n end,
}
local DF = { GUI = GUI }
-- AceLocale's key fallback, in one line: every lookup answers with its key, so
-- an assertion below reads as the English label the panel shows.
DF.L = setmetatable({}, { __index = function(_, k) return k end })
-- Two entries is enough: the Texture dropdown only ever hands the list on, and
-- the Style callback (not fired here) wants `next(list)` to exist.
function DF:GetBorderList() return { SOLID = "Solid", Blizzard = "Blizzard Tooltip" } end
DandersFrames = DF

load_options_file_into("GUI/SettingsWidgets.lua", NS)

-- ---- recorders ------------------------------------------------------
-- A widget is the row it produced: factory kind, label, the (db, key) pair it
-- was pointed at, which callback slots were filled, and the slot height its
-- group was told to reserve. SetEnabled exists because the composition loop
-- only touches widgets that have one.
local rec = {}
local function record(kind, label, dbTable, dbKey, extra)
    local e = { kind = kind, label = label, dbTable = dbTable or false, key = dbKey or "(none)" }
    if extra then for k, v in pairs(extra) do e[k] = v end end
    rec[#rec + 1] = e
    local widget = { _rec = e }
    function widget:SetEnabled() end
    return widget
end

function GUI:CreateCheckbox(parent, label, dbTable, dbKey, callback)
    return record("checkbox", label, dbTable, dbKey, { parent = parent, cb = callback ~= nil })
end
function GUI:CreateSlider(parent, label, minVal, maxVal, step, dbTable, dbKey, callback,
                          lightweight, previewMode, customGet, customSet)
    return record("slider", label, dbTable, dbKey, {
        parent = parent, min = minVal, max = maxVal, step = step,
        cb = callback ~= nil, light = lightweight ~= nil, preview = previewMode == true,
        get = customGet ~= nil, set = customSet ~= nil,
    })
end
function GUI:CreateDropdown(parent, label, options, dbTable, dbKey, callback)
    return record("dropdown", label, dbTable, dbKey, {
        parent = parent, cb = callback ~= nil, options = options,
    })
end
function GUI:CreateColorPicker(parent, label, dbTable, dbKey, hasAlpha, callback, lightCallback, useLight)
    return record("colorpicker", label, dbTable, dbKey, {
        parent = parent, hasAlpha = hasAlpha == true, cb = callback ~= nil,
        light = lightCallback ~= nil, useLight = useLight == true,
    })
end

-- The group is an order book. AddWidget stamps the reserved height onto the row
-- the factory already recorded, which is why the two never drift apart.
local function newGroup()
    local g = { count = 0 }
    function g:AddWidget(widget, height)
        self.count = self.count + 1
        widget._rec.height = height
        widget._rec.slot = self.count
        return widget
    end
    return g
end

-- ---- the fixture ----------------------------------------------------
-- The Frame page's own opts, to the letter (Options.lua, general_frame). The
-- callbacks are counters rather than no-ops so "was this slot filled" is
-- answerable, and so a build that FIRES one is caught.
local PARENT = { "the page's scroll child" }
local function newTools()
    local fired = { full = 0, light = 0, colors = 0, refresh = 0 }
    local t = {
        parent  = PARENT,
        fired   = fired,
        full    = function() fired.full = fired.full + 1 end,
        light   = function() fired.light = fired.light + 1 end,
        colors  = function() fired.colors = fired.colors + 1 end,
        refresh = function() fired.refresh = fired.refresh + 1 end,
    }
    return t
end

local function newDB(withColor)
    local db = {
        frameShowBorder          = true,
        frameBorderShadowEnabled = true,
        frameBorderStyle         = "SOLID",
        frameBorderSize          = 1,
        frameBorderTexture       = "SOLID",
    }
    if withColor then db.frameBorderColor = { r = 0, g = 0, b = 0, a = 0.8 } end
    return db
end

local function keySet(t)
    local s = {}
    for k in pairs(t) do s[k] = true end
    return s
end
local function newKeys(before, after)
    local out = {}
    for k in pairs(after) do if not before[k] then out[#out + 1] = k end end
    table.sort(out)
    return out
end

-- ---- the golden inventory -------------------------------------------
-- { factory kind, label (== L key), db key, slot height }
-- Derived by reading CreateBorderControls with the Frame page's include set:
-- inset + offset + blendMode + gradient + shadow + classColor + roleColor +
-- alpha, and NO animate. Order is the order the panel draws them top to bottom.
--
-- ⚠ "(none)" is the Border Alpha slider, and it is deliberate: that slider is a
-- handle on <prefix>BorderColor.a and is wired with a getter/setter pair rather
-- than a db key, so nothing tries to migrate or override a key that does not exist.
local GOLDEN = {
    { "checkbox",    "Show Border",           "frameShowBorder",                  30 },
    { "slider",      "Border Thickness",      "frameBorderSize",                  55 },
    { "dropdown",    "Border Style",          "frameBorderStyle",                 55 },
    { "dropdown",    "Border Texture",        "frameBorderTexture",               55 },
    { "colorpicker", "Gradient Start Color",  "frameBorderGradientStartColor",    35 },
    { "colorpicker", "Gradient End Color",    "frameBorderGradientEndColor",      35 },
    { "dropdown",    "Gradient Direction",    "frameBorderGradientDirection",     55 },
    { "dropdown",    "Border Color Source",   "frameBorderColorSource",           55 },
    { "colorpicker", "Border Color",          "frameBorderColor",                 35 },
    { "slider",      "Border Alpha",          "(none)",                           55 },
    { "slider",      "Border Inset",          "frameBorderInset",                 55 },
    { "slider",      "Border Offset X",       "frameBorderOffsetX",               55 },
    { "slider",      "Border Offset Y",       "frameBorderOffsetY",               55 },
    { "dropdown",    "Border Blend Mode",     "frameBorderBlendMode",             55 },
    { "checkbox",    "Border Shadow",         "frameBorderShadowEnabled",         30 },
    { "colorpicker", "Shadow Color",          "frameBorderShadowColor",           35 },
    { "slider",      "Shadow Size",           "frameBorderShadowSize",            55 },
    { "slider",      "Shadow Offset X",       "frameBorderShadowOffsetX",         55 },
    { "slider",      "Shadow Offset Y",       "frameBorderShadowOffsetY",         55 },
}

local function checkInventory(got, want, tag)
    eq(#got, #want, tag .. ": widget count")
    for i = 1, math.max(#got, #want) do
        local g, e = got[i], want[i]
        if not g then
            check(false, string.format("%s: row %d missing (wanted %s)", tag, i, e[2]))
        elseif not e then
            check(false, string.format("%s: row %d unexpected (%s %s)", tag, i, g.kind, tostring(g.label)))
        else
            eq(g.kind,   e[1], string.format("%s: row %d kind", tag, i))
            eq(g.label,  e[2], string.format("%s: row %d label", tag, i))
            eq(g.key,    e[3], string.format("%s: row %d db key", tag, i))
            eq(g.height, e[4], string.format("%s: row %d slot height", tag, i))
            eq(g.slot,   i,    string.format("%s: row %d reached the group in order", tag, i))
        end
    end
end

-- Every scalar a recorder captured, so the split can be compared field for
-- field rather than on the four columns the golden table spells out. (Options
-- tables are skipped: they are built fresh per call, so identity says nothing,
-- and the split takes the SAME code path for every dropdown.)
local COMPARED = { "kind", "label", "key", "height", "slot", "parent", "dbTable",
                   "cb", "light", "preview", "get", "set", "hasAlpha", "useLight",
                   "min", "max", "step" }

-- ---- the grey matrix ------------------------------------------------
-- Read at three states of the two booleans. Restores the db it was handed, so a
-- caller can go on using the same fixture.
local function greyMatrix(w, db)
    local function on(k)
        local widget = w[k]
        if not widget or not widget.disableOn then return "missing" end
        return widget.disableOn(nil) and true or false
    end
    local function row() return { show = on("show"), size = on("size"),
        shadowEnabled = on("shadowEnabled"), shadowColor = on("shadowColor") } end
    local out = {}
    db.frameShowBorder, db.frameBorderShadowEnabled = true, true
    out.bothOn = row()
    db.frameShowBorder = false
    out.borderOff = row()
    db.frameShowBorder, db.frameBorderShadowEnabled = true, false
    out.shadowOff = row()
    db.frameShowBorder, db.frameBorderShadowEnabled = true, true
    return out
end

-- ============================================================
-- 1. THE GOLDEN BUILD -- one CreateBorderControls call, as the page makes it
-- ============================================================
local goldenRec, goldenGrey
do
    rec = {}
    local tools, db = newTools(), newDB(true)
    local before = keySet(db)
    local group = newGroup()
    local w = GUI:CreateBorderControls(group, db, "frame", {
        parent  = tools.parent,
        include = {
            inset = true, offset = true, blendMode = true,
            gradient = true, shadow = true,
            classColor = true, roleColor = true,
            alpha = true,
        },
        fullUpdate    = tools.full,
        lightUpdate   = tools.light,
        lightColors   = tools.colors,
        refreshStates = tools.refresh,
        sizeMin = 1, sizeMax = 16, sizeStep = 1,
    })
    goldenRec = rec

    checkInventory(goldenRec, GOLDEN, "golden")

    -- The build is a build: it draws, it does not apply.
    eq(tools.fired.full, 0, "golden: building fired no full update")
    eq(tools.fired.light, 0, "golden: ...no lightweight")
    eq(tools.fired.colors, 0, "golden: ...no colour lightweight")
    eq(tools.fired.refresh, 0, "golden: ...and did not refresh the page")

    -- Every row went to the page's scroll child, and every keyed row to the
    -- page's db -- the Alpha slider excepted, which carries its own accessors.
    for i, e in ipairs(goldenRec) do
        eq(e.parent, PARENT, "golden: row " .. i .. " parented to the page child")
        if e.key == "(none)" then
            eq(e.dbTable, false, "golden: the Alpha slider takes no db table...")
            check(e.get and e.set, "golden: ...it is wired with a getter/setter pair instead")
        else
            eq(e.dbTable, db, "golden: row " .. i .. " points at the page db")
        end
    end

    -- The sliders' ranges, spot-checked where the page overrides the defaults
    -- (thickness) and where the factory owns them (the shadow four).
    local byLabel = {}
    for _, e in ipairs(goldenRec) do byLabel[e.label] = e end
    eq(byLabel["Border Thickness"].min, 1, "golden: thickness min is the page's, not the default 0")
    eq(byLabel["Border Thickness"].max, 16, "golden: ...and its max")
    eq(byLabel["Border Thickness"].step, 1, "golden: ...and its step")
    eq(byLabel["Border Inset"].min, -20, "golden: inset range is the factory's")
    eq(byLabel["Border Offset X"].min, -50, "golden: offset range is the factory's default")
    eq(byLabel["Border Offset X"].max, 50, "golden: ...both ends")
    eq(byLabel["Shadow Size"].min, 0, "golden: shadow size range")
    eq(byLabel["Shadow Size"].max, 10, "golden: ...both ends")
    eq(byLabel["Shadow Offset X"].min, -10, "golden: shadow offset range")
    eq(byLabel["Shadow Offset Y"].max, 10, "golden: ...both ends")
    eq(byLabel["Border Alpha"].min, 0, "golden: alpha runs 0..1")
    eq(byLabel["Border Alpha"].max, 1, "golden: ...both ends")
    eq(byLabel["Border Alpha"].step, 0.05, "golden: ...in twentieths")

    -- Which callback slots each shadow row was handed: the shadow block gets
    -- fullUpdate and lightUpdate and NO lightColors (its colour picker commits
    -- through fullUpdate alone), which is exactly what the split has to repeat.
    eq(byLabel["Shadow Color"].cb, true, "golden: the shadow colour picker commits")
    eq(byLabel["Shadow Color"].light, false, "golden: ...with no lightweight colour path")
    eq(byLabel["Shadow Color"].useLight, false, "golden: ...and no preview participation")
    eq(byLabel["Shadow Size"].light, true, "golden: the shadow sliders preview")
    eq(byLabel["Border Color"].light, true, "golden: the BORDER colour picker does have one")
    eq(byLabel["Border Color"].useLight, true, "golden: ...and takes part in drags")

    -- ---- db seed ----
    -- With a colour table already present, the ONE write is the colour source.
    local added = newKeys(before, db)
    eq(#added, 1, "seed: exactly one key was written at build time")
    eq(added[1], "frameBorderColorSource", "seed: ...the colour source")
    eq(db.frameBorderColorSource, "STATIC", "seed: defaulted to STATIC with no legacy booleans set")
    eq(db.frameShowBorder, true, "seed: nothing else moved")
    eq(db.frameBorderStyle, "SOLID", "seed: ...still")
    eq(db.frameBorderColor.a, 0.8, "seed: an existing alpha is left alone")

    goldenGrey = greyMatrix(w, db)
    eq(goldenGrey.bothOn.show, false, "grey: both on -- Show Border is live")
    eq(goldenGrey.bothOn.size, false, "grey: both on -- thickness is live")
    eq(goldenGrey.bothOn.shadowEnabled, false, "grey: both on -- the shadow toggle is live")
    eq(goldenGrey.bothOn.shadowColor, false, "grey: both on -- the shadow colour is live")
    eq(goldenGrey.borderOff.show, false, "grey: border off -- Show Border stays clickable")
    eq(goldenGrey.borderOff.size, true, "grey: border off -- thickness greys")
    eq(goldenGrey.borderOff.shadowEnabled, true, "grey: border off -- so does the shadow toggle")
    eq(goldenGrey.borderOff.shadowColor, true, "grey: border off -- and the shadow colour")
    eq(goldenGrey.shadowOff.show, false, "grey: shadow off -- Show Border untouched")
    eq(goldenGrey.shadowOff.size, false, "grey: shadow off -- the border controls untouched")
    eq(goldenGrey.shadowOff.shadowEnabled, false, "grey: shadow off -- its own toggle stays clickable")
    eq(goldenGrey.shadowOff.shadowColor, true, "grey: shadow off -- its sub-controls grey")

    -- Nothing HIDES on this page: the Frame border passes no hideWhen, so the
    -- shadow block is visible whatever the toggles say.
    for _, k in ipairs({ "shadowEnabled", "shadowColor", "shadowSize", "shadowOffsetX", "shadowOffsetY" }) do
        check(w[k] ~= nil, "golden: " .. k .. " was built")
        eq(w[k].hideOn(nil), false, "golden: " .. k .. " is never hidden on this page")
    end
end

-- A db with no colour table at all: the second of the two build-time writes.
do
    rec = {}
    local tools, db = newTools(), newDB(false)
    local before = keySet(db)
    GUI:CreateBorderControls(newGroup(), db, "frame", {
        parent  = tools.parent,
        include = { inset = true, offset = true, blendMode = true, gradient = true,
                    shadow = true, classColor = true, roleColor = true, alpha = true },
        fullUpdate = tools.full, lightUpdate = tools.light, lightColors = tools.colors,
        refreshStates = tools.refresh,
        sizeMin = 1, sizeMax = 16, sizeStep = 1,
    })
    local added = newKeys(before, db)
    eq(#added, 2, "seed: a db with no border colour gets exactly two writes")
    eq(added[1], "frameBorderColor", "seed: ...the colour table")
    eq(added[2], "frameBorderColorSource", "seed: ...and the source")
    eq(type(db.frameBorderColor), "table", "seed: the colour is a table")
    eq(db.frameBorderColor.r, 0, "seed: seeded black")
    eq(db.frameBorderColor.a, 1, "seed: ...fully opaque")
end

-- The legacy class/role booleans still decide the source when it is unset --
-- the one branch of the seed a fresh profile never takes.
do
    rec = {}
    local tools, db = newTools(), newDB(true)
    db.frameBorderUseClassColor = true
    GUI:CreateBorderControls(newGroup(), db, "frame", {
        parent = tools.parent,
        include = { classColor = true, roleColor = true },
        fullUpdate = tools.full,
    })
    eq(db.frameBorderColorSource, "CLASS", "seed: a legacy class-colour profile migrates to CLASS")
end

-- ============================================================
-- 2. THE SPLIT BUILD -- Border, then Border Shadow, as two mounts
-- The gate-two shape. Same group, same db, same order: the merged result has to
-- be indistinguishable from the single call above, field for field.
--
-- ⚠ THE GREY IS THE SUBTLE PART. In the single call the shadow rows grey with
-- Show Border because the end-of-function loop composes borderOff onto
-- everything. Split apart, the shadow builder is never inside that loop, so the
-- page has to hand it the same predicate as disableWhen -- which is what the
-- matrix below is checking.
-- ============================================================
if GUI.CreateBorderShadowControls then
    rec = {}
    local tools, db = newTools(), newDB(true)
    local before = keySet(db)
    local group = newGroup()
    local borderOff = function() return db.frameShowBorder == false end

    local w = GUI:CreateBorderControls(group, db, "frame", {
        parent  = tools.parent,
        include = {
            inset = true, offset = true, blendMode = true,
            gradient = true,
            classColor = true, roleColor = true,
            alpha = true,
        },
        fullUpdate    = tools.full,
        lightUpdate   = tools.light,
        lightColors   = tools.colors,
        refreshStates = tools.refresh,
        sizeMin = 1, sizeMax = 16, sizeStep = 1,
    })
    local sw = GUI:CreateBorderShadowControls(group, db, "frame", {
        parent        = tools.parent,
        fullUpdate    = tools.full,
        lightUpdate   = tools.light,
        refreshStates = tools.refresh,
        hideWhen      = nil,
        disableWhen   = borderOff,
    })
    for k, v in pairs(sw) do w[k] = v end

    -- (a) the same 19 rows, in the same order, with the same everything
    checkInventory(rec, GOLDEN, "split")
    for i = 1, math.min(#rec, #goldenRec) do
        for _, field in ipairs(COMPARED) do
            local a, b = rec[i][field], goldenRec[i][field]
            -- dbTable identity is per-fixture, so compare "is it THE db" instead.
            if field == "dbTable" then a, b = a ~= false, b ~= false end
            eq(tostring(a), tostring(b),
               string.format("split: row %d field %s matches the golden build", i, field))
        end
    end
    eq(tools.fired.full + tools.fired.light + tools.fired.colors + tools.fired.refresh, 0,
       "split: building fired no callbacks either")

    -- (b) the same two build-time writes, and only those
    local added = newKeys(before, db)
    eq(#added, 1, "split: the same single write")
    eq(added[1], "frameBorderColorSource", "split: ...the same key")
    eq(db.frameBorderColorSource, "STATIC", "split: ...with the same value")
    eq(db.frameBorderColor.a, 0.8, "split: the existing alpha is still left alone")

    -- (c) the same grey matrix, cell for cell
    local grey = greyMatrix(w, db)
    for _, state in ipairs({ "bothOn", "borderOff", "shadowOff" }) do
        for _, k in ipairs({ "show", "size", "shadowEnabled", "shadowColor" }) do
            eq(tostring(grey[state][k]), tostring(goldenGrey[state][k]),
               string.format("split: grey[%s].%s matches the golden build", state, k))
        end
    end

    -- ...and the same never-hidden shadow block
    for _, k in ipairs({ "shadowEnabled", "shadowColor", "shadowSize", "shadowOffsetX", "shadowOffsetY" }) do
        check(sw[k] ~= nil, "split: " .. k .. " was built by the shadow builder")
        eq(sw[k].hideOn(nil), false, "split: " .. k .. " is never hidden with no hideWhen")
    end

    -- ---- the standalone builder's own options ----
    -- hideWhen reaches EVERY row (a consumer whose whole feature is off).
    do
        rec = {}
        local t2, db2 = newTools(), newDB(true)
        local hidden = false
        local s = GUI:CreateBorderShadowControls(newGroup(), db2, "frame", {
            parent = t2.parent, fullUpdate = t2.full, lightUpdate = t2.light,
            hideWhen = function() return hidden end,
        })
        eq(#rec, 5, "standalone: five rows")
        eq(s.shadowEnabled.hideOn(nil), false, "standalone: visible while the gate is open")
        hidden = true
        eq(s.shadowEnabled.hideOn(nil), true, "standalone: hideWhen hides the toggle...")
        eq(s.shadowColor.hideOn(nil), true, "standalone: ...and the sub-controls")
    end

    -- noEnableToggle drops the checkbox and nothing else; the sub-controls keep
    -- greying on the key, which the external toggle is expected to write.
    do
        rec = {}
        local t3, db3 = newTools(), newDB(true)
        local s = GUI:CreateBorderShadowControls(newGroup(), db3, "frame", {
            parent = t3.parent, fullUpdate = t3.full, lightUpdate = t3.light,
            noEnableToggle = true,
        })
        eq(#rec, 4, "noEnableToggle: the checkbox is gone, the four sub-controls remain")
        eq(s.shadowEnabled, nil, "noEnableToggle: ...and no handle is published for it")
        eq(rec[1].label, "Shadow Color", "noEnableToggle: the block now opens on the colour")
        eq(s.shadowColor.disableOn(nil), false, "noEnableToggle: live while the key is on")
        db3.frameBorderShadowEnabled = false
        eq(s.shadowColor.disableOn(nil), true, "noEnableToggle: the key still greys the sub-controls")
    end

    -- disableWhen greys the toggle TOO -- that is the difference between it and
    -- the border's own borderOff, and it is what the Frame page relies on.
    do
        rec = {}
        local t4, db4 = newTools(), newDB(true)
        local off = false
        local s = GUI:CreateBorderShadowControls(newGroup(), db4, "frame", {
            parent = t4.parent, fullUpdate = t4.full, disableWhen = function() return off end,
        })
        eq(s.shadowEnabled.disableOn(nil), false, "disableWhen: open -- the toggle is live")
        off = true
        eq(s.shadowEnabled.disableOn(nil), true, "disableWhen: closed -- the toggle greys too")
        eq(s.shadowColor.disableOn(nil), true, "disableWhen: ...and so does everything under it")
    end
else
    -- The golden half stands on its own; the split half needs the builder to
    -- exist. Said out loud rather than silently skipped.
    check(false, "split: GUI:CreateBorderShadowControls is not defined yet")
end

-- ============================================================
-- 3. THE POPOUT SHAPE -- the same two builders with their toggles HOISTED
-- Gate two puts Border and Border Shadow behind two popout ROWS, and a row
-- carries the feature's on/off tick itself. So each builder is called with its
-- own checkbox suppressed (noShowToggle / noEnableToggle) and mounts into a
-- group of its own rather than into the page's Appearance box.
--
-- The claim is the same one section 2 makes, one step further: dropping the two
-- toggles must remove EXACTLY those two rows and change nothing else --
-- including the db seed, which is the headless half of the profile-export
-- byte-identity gate. A build that seeds different keys (or seeds them at a
-- different moment) can dirty a profile just by opening a panel.
-- ============================================================
if GUI.CreateBorderShadowControls then
    -- The two halves of GOLDEN the popouts actually mount: rows 2-14 (border,
    -- less "Show Border") and 16-19 (shadow, less "Border Shadow"). Written as
    -- slices of the golden table rather than retyped, so a change to the
    -- inventory reaches this test whether anyone remembered it or not.
    local function slice(t, from, to)
        local out = {}
        for i = from, to do out[#out + 1] = t[i] end
        return out
    end
    local BORDER_PANE, SHADOW_PANE = slice(GOLDEN, 2, 14), slice(GOLDEN, 16, 19)

    -- Field for field against the golden rows, minus `slot`: a popout group
    -- starts its own numbering at 1, and checkInventory has already asserted
    -- each row reached ITS group in order.
    local PANE_COMPARED = {}
    for _, f in ipairs(COMPARED) do
        if f ~= "slot" then PANE_COMPARED[#PANE_COMPARED + 1] = f end
    end
    local function compareToGolden(got, offset, tag)
        for i = 1, #got do
            for _, field in ipairs(PANE_COMPARED) do
                local a, b = got[i][field], goldenRec[i + offset][field]
                if field == "dbTable" then a, b = a ~= false, b ~= false end
                eq(tostring(a), tostring(b),
                   string.format("%s: row %d field %s matches the golden build", tag, i, field))
            end
        end
    end

    -- ---- the Border pane ----
    local borderRec, shadowRec
    local db = newDB(true)
    local before = keySet(db)
    local bw, sw
    do
        rec = {}
        local tools = newTools()
        bw = GUI:CreateBorderControls(newGroup(), db, "frame", {
            parent  = tools.parent,
            include = {
                inset = true, offset = true, blendMode = true,
                gradient = true,
                classColor = true, roleColor = true,
                alpha = true,
            },
            fullUpdate    = tools.full,
            lightUpdate   = tools.light,
            lightColors   = tools.colors,
            refreshStates = tools.refresh,
            sizeMin = 1, sizeMax = 16, sizeStep = 1,
            noShowToggle  = true,
        })
        borderRec = rec
        checkInventory(borderRec, BORDER_PANE, "border pane")
        compareToGolden(borderRec, 1, "border pane")
        eq(bw.show, nil, "border pane: the hoisted Show Border checkbox is gone")
        eq(tools.fired.full + tools.fired.light + tools.fired.colors + tools.fired.refresh, 0,
           "border pane: building fired no callbacks")
    end

    -- ---- the Border Shadow pane ----
    do
        rec = {}
        local tools = newTools()
        sw = GUI:CreateBorderShadowControls(newGroup(), db, "frame", {
            parent        = tools.parent,
            fullUpdate    = tools.full,
            lightUpdate   = tools.light,
            refreshStates = tools.refresh,
            -- The Frame page hands this over inside the popout too: with Show
            -- Border off the four sub-controls grey exactly as they do inline.
            disableWhen   = function() return db.frameShowBorder == false end,
            noEnableToggle = true,
        })
        shadowRec = rec
        checkInventory(shadowRec, SHADOW_PANE, "shadow pane")
        compareToGolden(shadowRec, 15, "shadow pane")
        eq(sw.shadowEnabled, nil, "shadow pane: the hoisted Border Shadow checkbox is gone")
        eq(tools.fired.full + tools.fired.light + tools.fired.colors + tools.fired.refresh, 0,
           "shadow pane: building fired no callbacks")
    end

    -- ---- the db seed, which is the point ----
    -- Two builders, two groups, one db: the writes have to be the golden path's
    -- and only those. This is the headless half of the export byte-identity gate.
    do
        local added = newKeys(before, db)
        eq(#added, 1, "popout seed: the same single write as the golden build")
        eq(added[1], "frameBorderColorSource", "popout seed: ...the same key")
        eq(db.frameBorderColorSource, "STATIC", "popout seed: ...with the same value")
        eq(db.frameBorderColor.a, 0.8, "popout seed: an existing alpha is still left alone")
    end

    -- ...and the colourless profile, the two-write branch.
    do
        rec = {}
        local t, db2 = newTools(), newDB(false)
        local was = keySet(db2)
        GUI:CreateBorderControls(newGroup(), db2, "frame", {
            parent  = t.parent,
            include = { inset = true, offset = true, blendMode = true, gradient = true,
                        classColor = true, roleColor = true, alpha = true },
            fullUpdate = t.full, lightUpdate = t.light, lightColors = t.colors,
            refreshStates = t.refresh,
            sizeMin = 1, sizeMax = 16, sizeStep = 1,
            noShowToggle = true,
        })
        GUI:CreateBorderShadowControls(newGroup(), db2, "frame", {
            parent = t.parent, fullUpdate = t.full, lightUpdate = t.light,
            noEnableToggle = true,
        })
        local added = newKeys(was, db2)
        eq(#added, 2, "popout seed: a db with no border colour still gets exactly two writes")
        eq(added[1], "frameBorderColor", "popout seed: ...the colour table")
        eq(added[2], "frameBorderColorSource", "popout seed: ...and the source")
        eq(db2.frameBorderColor.a, 1, "popout seed: seeded fully opaque, as before")
    end

    -- ---- the grey the split still owes ----
    -- Show Border no longer has a checkbox in either pane, but it still governs
    -- both: the border controls through CreateBorderControls' own loop, the
    -- shadow sub-controls through the disableWhen the page hands over.
    do
        db.frameShowBorder, db.frameBorderShadowEnabled = true, true
        eq(bw.size.disableOn(nil), false, "popout grey: border on -- thickness is live")
        eq(sw.shadowColor.disableOn(nil), false, "popout grey: ...and the shadow colour")
        db.frameShowBorder = false
        eq(bw.size.disableOn(nil), true, "popout grey: border off -- thickness greys")
        eq(sw.shadowColor.disableOn(nil), true, "popout grey: ...and so does the shadow colour")
        db.frameShowBorder = true
        db.frameBorderShadowEnabled = false
        eq(bw.size.disableOn(nil), false, "popout grey: shadow off -- the border controls are untouched")
        eq(sw.shadowColor.disableOn(nil), true, "popout grey: ...and the shadow sub-controls grey on their own key")
        db.frameBorderShadowEnabled = true
    end

    -- ---- and the numbers the ROWS declare ----
    -- Read out of the page's source rather than retyped here: the count badge is
    -- a CLAIM about how much is inside, the kit checks it against what a build
    -- actually mounted, and this checks it against what the builders produce
    -- before anyone gets in-game to see the mismatch reported.
    local pageSrc = options_file_source("GUI/Pages/Options.lua")
    local declaredBorder, declaredShadow =
        pageSrc:match("BORDER_COUNT,%s*SHADOW_COUNT%s*=%s*(%d+)%s*,%s*(%d+)")
    check(declaredBorder ~= nil, "counts: the Frame page declares both row counts in one place")
    eq(tonumber(declaredBorder), #borderRec, "counts: the Border row's count is what its pane mounts")
    eq(tonumber(declaredShadow), #shadowRec, "counts: the Border Shadow row's count is what its pane mounts")
    eq(#borderRec, 13, "counts: which is 13 -- the golden 14 less the hoisted Show Border")
    eq(#shadowRec, 4, "counts: and 4 -- the golden 5 less the hoisted Border Shadow")

    -- ---- and the two toggles the SEARCH registry would otherwise lose ----
    -- Dropping the checkboxes drops what registered them: the checkbox FACTORY
    -- is the only thing that ever put "Show Border" and "Border Shadow" into the
    -- settings search. The page registers them by hand instead, and this pins
    -- those calls to the golden rows they replace -- so renaming the label or
    -- the key in CreateBorderControls fails here rather than silently leaving
    -- the two layouts findable by different words.
    -- Source-read for the same reason the counts above are: the page file is far
    -- too tangled in the panel to build headlessly, but the call is still a
    -- claim that can be checked against the inventory.
    --
    -- ⚠ The trailing arg is the row's own commit, and it is matched loosely on
    -- purpose: the sweep hoists a toggle on other groups of this page too (each
    -- with its own callback), so this pins THE BORDER PAIR -- the golden label
    -- and key on each -- rather than being a census of every hoisted toggle on
    -- the page.
    --
    -- ☠ MATCHED BY THE ROW EACH ONE IS WIRED TO, NOT BY POSITION IN THE FILE.
    -- This used to take the FIRST TWO RegisterHoistedToggle calls in
    -- Pages/Options.lua, on the assumption the border pair were the earliest
    -- hoists in it. The DISPLAY sweep broke that assumption -- Display >
    -- Visibility hoists Solo Mode and its builder sits ABOVE the Frame page in
    -- the same file -- and the failure it produced said "entry 1 uses the golden
    -- label (got Solo Mode)", which is a true statement about a check asking the
    -- wrong question. Naming the two rows is what this was always about.
    do
        local got = {}
        for row, label, key in pageSrc:gmatch('RegisterHoistedToggle%((%w+),%s*L%["([^"]+)"%],%s*"([^"]+)"') do
            got[row] = { label, key }
        end
        check(got.borderRow ~= nil and got.shadowRow ~= nil,
              "hoisted search: the page registers the two hoisted border toggles")
        local want = { { "borderRow", GOLDEN[1] }, { "shadowRow", GOLDEN[15] } }
        for i = 1, 2 do
            local rowName, golden = want[i][1], want[i][2]
            local e = got[rowName]
            if e then
                eq(e[1], golden[2],
                   string.format("hoisted search: entry %d uses the golden label", i))
                eq(e[2], golden[3],
                   string.format("hoisted search: entry %d uses the golden db key", i))
            else
                check(false, string.format("hoisted search: entry %d missing (wanted %s)", i, golden[2]))
            end
        end
    end

    -- ---- and WHERE the two rows are mounted ----
    -- The rows are the whole of the Appearance section in the popout layout, so
    -- the container they go in is a layout decision, not a detail: a 280 box in
    -- column 2 leaves a row ending ~300px inside the window with its popout's
    -- beam crossing half the page. The band is that same container built at the
    -- PAGE's usable width, chromeless, and laid out across both columns.
    --
    -- Source-read for the same reason the counts and the hoisted toggles above
    -- are -- the page cannot be built headlessly -- and pinned as a pair, so a
    -- future edit cannot widen the container without also freeing it from a
    -- column, or vice versa.
    do
        -- ⚠ SCOPED TO THE FRAME PAGE'S BLOCK, not to the whole file. `sizeGroup`
        -- and `appearanceGroup` are the house names for those two boxes and other
        -- pages in this same file use both, so a whole-file count answers about
        -- the Pet page as readily as about this one.
        -- ⚠ AND THE SEARCH STARTS AT THE FRAME PAGE, not at the top of the file.
        -- `local classicLayout = DF:IsClassicSettingsLayout()` is the first line
        -- of every converted page's builder, and General > Settings -- converted
        -- in the same sweep -- sits ABOVE this one in Pages/Options.lua, so a
        -- search from byte 1 would open the slice on that page instead.
        local frameAt = pageSrc:find('Add(CreateCopyButton(self.child, {"frame", "permanentMover"', 1, true)
        check(frameAt ~= nil, "band: the Frame page is locatable by its copy button")
        local blockStart = pageSrc:find("local classicLayout = DF:IsClassicSettingsLayout()", frameAt or 1, true)
        local blockEnd   = pageSrc:find("if classicLayout then Add(appearanceGroup, nil, 2) end", 1, true)
        check(blockStart ~= nil, "band: the Frame page decides the layout mode by name")
        check(blockEnd ~= nil and blockStart and blockEnd > blockStart,
              "band: ...and closes the Appearance block with the classic-only Add")
        local pageSrc = pageSrc:sub(blockStart or 1, (blockEnd or 1) + 60)

        local function pageHas(needle, msg)
            check(pageSrc:find(needle, 1, true) ~= nil, "band: " .. msg)
        end
        pageHas("local classicLayout = DF:IsClassicSettingsLayout()",
                "the layout mode is decided ONCE, before the container is built")
        -- Classic: the box it has always been, in column 2, added in place.
        pageHas("appearanceGroup = GUI:CreateSettingsGroup(self.child, 280)",
                "classic still builds the 280 box")
        pageHas("if classicLayout then Add(appearanceGroup, nil, 2) end",
                "...and still adds it to column 2, where it has always been")
        -- Popout: the band. Width from the shared helper (never a literal) and no
        -- box chrome. WHERE it is added is not decided in this block any more --
        -- see the band-order block in test_frame_page_builders, which owns that
        -- claim now that the page has more than one band.
        --
        -- ⚠ tools.BandWidth(), NOT A PAGE LOCAL. The page took
        -- GUI:CreatePopoutPageTools, so the expression this used to read
        -- (GUI.PageUsableWidth(GUI.PageChildWidth(...))) lives in Controls.lua and
        -- is pinned by test_popout_page_tools. The claim here is unchanged: this
        -- band asks for the width the layout pass will stretch it to rather than
        -- naming a literal.
        pageHas("GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })",
                "the band is built at the width the layout pass will stretch it to, with no box chrome")
        check(pageSrc:find("GUI:CreateSettingsGroup(self.child, 280, { chromeless", 1, true) == nil,
              "band: ...and never at a literal")
        -- The band's padding is DEFAULT (the popout PANE is the zero-padding
        -- case, not this). That is what lands a row's right edge on the same
        -- corridor as a slider's value box -- see test_page_parking.
        check(pageSrc:find("tools.BandWidth(), { chromeless = true, padding", 1, true) == nil,
              "band: the band keeps the standard box padding, so its rows end at the corridor")
        -- Inside THIS block, the only Add is the classic box's: the popout one
        -- moved to the foot of the builder. Two unconditional Adds would lay the
        -- container out twice.
        local adds = 0
        for _ in pageSrc:gmatch("Add%(appearanceGroup,") do adds = adds + 1 end
        eq(adds, 1, "band: the Appearance block adds the classic box and nothing else")
    end
end

-- ============================================================
-- 4. THE PET FRAMES PAGE'S BORDER -- a DIFFERENT include set, ONE row
-- Display > Pet Frames mounts its whole border as a single popout row, not the
-- Frame page's two. The reason is size rather than taste: the pet border is
-- sixteen controls where the frame's is nineteen, and five of those sixteen are
-- the shadow -- a row for five sub-controls of another row's feature is a level
-- of nesting that page does not earn. Keeping include.shadow also keeps the
-- shadow block inside CreateBorderControls' own composition loop, which is what
-- puts Show Border's grey on top of it: no shadowDisableWhen has to be handed
-- over by hand, which is the one thing the split cost the Frame page.
--
-- What is pinned here is the same claim section 3 makes for the Frame page, for
-- the other include set: the pane's inventory, that dropping the hoisted Show
-- Border removes EXACTLY that row, the build-time db seed, and that the number
-- the page declares is the number a build produces.
--
-- ⚠ NO COLOUR SOURCE ROW, AND THEREFORE NO COLOUR-SOURCE SEED. Pets pass
-- neither classColor nor roleColor -- UnitClass("pet") answers the pet family,
-- not a class token -- so the dropdown is not built and the STATIC default is
-- never written. That makes the pet build's seed strictly smaller than the frame
-- build's, and it is the half of this that a profile export would notice.
if GUI.CreateBorderShadowControls then
    local PET_OPTS = { alpha = true, inset = true, blendMode = true,
                       gradient = true, shadow = true }

    local function newPetDB(withColor)
        local db = {
            petShowBorder          = true,
            petBorderShadowEnabled = true,
            petBorderStyle         = "SOLID",
            petBorderSize          = 1,
            petBorderTexture       = "SOLID",
        }
        if withColor then db.petBorderColor = { r = 0, g = 0, b = 0, a = 1 } end
        return db
    end

    -- The whole build, in the order the panel draws it. Sixteen: no offset pair
    -- (the page has its own Offset X / Y in the Position group) and no colour
    -- source, which is where the frame's nineteen go.
    local PET_GOLDEN = {
        { "checkbox",    "Show Border",          "petShowBorder",                 30 },
        { "slider",      "Border Thickness",     "petBorderSize",                 55 },
        { "dropdown",    "Border Style",         "petBorderStyle",                55 },
        { "dropdown",    "Border Texture",       "petBorderTexture",              55 },
        { "colorpicker", "Gradient Start Color", "petBorderGradientStartColor",   35 },
        { "colorpicker", "Gradient End Color",   "petBorderGradientEndColor",     35 },
        { "dropdown",    "Gradient Direction",   "petBorderGradientDirection",    55 },
        { "colorpicker", "Border Color",         "petBorderColor",                35 },
        { "slider",      "Border Alpha",         "(none)",                        55 },
        { "slider",      "Border Inset",         "petBorderInset",                55 },
        { "dropdown",    "Border Blend Mode",    "petBorderBlendMode",            55 },
        { "checkbox",    "Border Shadow",        "petBorderShadowEnabled",        30 },
        { "colorpicker", "Shadow Color",         "petBorderShadowColor",          35 },
        { "slider",      "Shadow Size",          "petBorderShadowSize",           55 },
        { "slider",      "Shadow Offset X",      "petBorderShadowOffsetX",        55 },
        { "slider",      "Shadow Offset Y",      "petBorderShadowOffsetY",        55 },
    }

    -- ---- the classic box: the whole sixteen ----
    local petClassicRec, petClassicW, petClassicDB
    do
        rec = {}
        local tools = newTools()
        petClassicDB = newPetDB(true)
        local before = keySet(petClassicDB)
        petClassicW = GUI:CreateBorderControls(newGroup(), petClassicDB, "pet", {
            parent  = tools.parent,
            include = PET_OPTS,
            fullUpdate    = tools.full,
            lightUpdate   = tools.light,
            lightColors   = tools.colors,
            refreshStates = tools.refresh,
            sizeMin = 1, sizeMax = 6, sizeStep = 1,
        })
        petClassicRec = rec
        checkInventory(petClassicRec, PET_GOLDEN, "pet classic")
        eq(tools.fired.full + tools.fired.light + tools.fired.colors + tools.fired.refresh, 0,
           "pet classic: building fired no callbacks")

        local byLabel = {}
        for _, e in ipairs(petClassicRec) do byLabel[e.label] = e end
        eq(byLabel["Border Thickness"].min, 1, "pet classic: thickness min is the page's")
        eq(byLabel["Border Thickness"].max, 6, "pet classic: ...and its max, which is not the frame's 16")

        -- With the colour table already present, a pet build writes NOTHING.
        local added = newKeys(before, petClassicDB)
        eq(#added, 0, "pet seed: a pet border build with a colour table writes nothing at all")
    end

    -- ...and the one write it does make on a profile with no colour table. Still
    -- one, not the frame build's two: there is no colour source to default.
    do
        rec = {}
        local t, db2 = newTools(), newPetDB(false)
        local was = keySet(db2)
        GUI:CreateBorderControls(newGroup(), db2, "pet", {
            parent = t.parent, include = PET_OPTS,
            fullUpdate = t.full, lightUpdate = t.light, lightColors = t.colors,
            refreshStates = t.refresh,
            sizeMin = 1, sizeMax = 6, sizeStep = 1,
        })
        local added = newKeys(was, db2)
        eq(#added, 1, "pet seed: a db with no border colour gets exactly one write")
        eq(added[1], "petBorderColor", "pet seed: ...the colour table")
        eq(db2.petBorderColor.a, 1, "pet seed: seeded fully opaque")
        eq(db2.petBorderColorSource, nil, "pet seed: ...and NO colour source, because there is no dropdown for one")
    end

    -- ---- the popout pane: the same sixteen less the hoisted Show Border ----
    local petPaneRec, petPaneW, petPaneDB
    do
        rec = {}
        local tools = newTools()
        petPaneDB = newPetDB(true)
        local before = keySet(petPaneDB)
        petPaneW = GUI:CreateBorderControls(newGroup(), petPaneDB, "pet", {
            parent  = tools.parent,
            include = PET_OPTS,
            fullUpdate    = tools.full,
            lightUpdate   = tools.light,
            lightColors   = tools.colors,
            refreshStates = tools.refresh,
            sizeMin = 1, sizeMax = 6, sizeStep = 1,
            noShowToggle  = true,
            -- The page's own gate, in through the consumer door: pet frames
            -- switched off greys the whole pane, which is what the classic box's
            -- disableChildrenOn does for it there.
            disableWhen   = function(d) return d.petEnabled == false end,
        })
        petPaneRec = rec

        -- Field for field against the classic rows, minus `slot`: a popout group
        -- starts its own numbering at 1.
        local PANE_COMPARED = {}
        for _, f in ipairs(COMPARED) do
            if f ~= "slot" then PANE_COMPARED[#PANE_COMPARED + 1] = f end
        end
        eq(#petPaneRec, #PET_GOLDEN - 1, "pet pane: exactly one row fewer than the classic box")
        eq(petPaneW.show, nil, "pet pane: ...and it is the hoisted Show Border checkbox")
        for i = 1, #petPaneRec do
            for _, field in ipairs(PANE_COMPARED) do
                local a, b = petPaneRec[i][field], petClassicRec[i + 1][field]
                if field == "dbTable" then a, b = a ~= false, b ~= false end
                eq(tostring(a), tostring(b),
                   string.format("pet pane: row %d field %s matches the classic build", i, field))
            end
        end
        eq(#newKeys(before, petPaneDB), 0, "pet pane seed: the hoist changed no build-time write")
    end

    -- ---- the greys the one call still owns ----
    -- Show Border has no checkbox in the pane and still governs all fifteen,
    -- INCLUDING the five shadow rows -- which is the whole reason this page keeps
    -- one call rather than splitting it. And the page gate reaches every row,
    -- first child included, which is what disableWhen is for here.
    do
        petPaneDB.petShowBorder, petPaneDB.petBorderShadowEnabled = true, true
        petPaneDB.petEnabled = true
        eq(petPaneW.size.disableOn(nil), false, "pet grey: border on -- thickness is live")
        eq(petPaneW.shadowColor.disableOn(nil), false, "pet grey: ...and the shadow colour")
        petPaneDB.petShowBorder = false
        eq(petPaneW.size.disableOn(nil), true, "pet grey: border off -- thickness greys")
        eq(petPaneW.shadowColor.disableOn(nil), true,
           "pet grey: ...and the shadow block with it, from the factory's own loop")
        petPaneDB.petShowBorder = true
        petPaneDB.petBorderShadowEnabled = false
        eq(petPaneW.size.disableOn(nil), false, "pet grey: shadow off -- the border controls are untouched")
        eq(petPaneW.shadowColor.disableOn(nil), true, "pet grey: ...and its sub-controls grey on their own key")
        petPaneDB.petBorderShadowEnabled = true
        -- The page gate, over the top of both.
        petPaneDB.petEnabled = false
        eq(petPaneW.size.disableOn(nil), true, "pet grey: pet frames off -- the whole pane greys")
        eq(petPaneW.shadowEnabled.disableOn(nil), true, "pet grey: ...the shadow toggle included")
        petPaneDB.petEnabled = true
    end

    -- ---- and the number the ROW declares ----
    -- Read out of the page's source rather than retyped: the count badge is a
    -- CLAIM about how much is inside, and the kit checks it against what a build
    -- actually mounted. This checks it against what the builder produces, before
    -- anyone gets in-game to see the mismatch reported.
    do
        local pageSrc = options_file_source("GUI/Pages/Options.lua")
        local declared = tonumber(pageSrc:match("local PET_BORDER_COUNT%s*=%s*(%d+)"))
        check(declared ~= nil, "pet counts: the Pet Frames page declares the Border row's count in one place")
        eq(declared, #petPaneRec, "pet counts: ...and it is what the pane mounts")
        eq(#petPaneRec, 15, "pet counts: which is 15 -- the sixteen less the hoisted Show Border")
    end
end

-- ---- restore the global --------------------------------------------
DandersFrames = savedDF
