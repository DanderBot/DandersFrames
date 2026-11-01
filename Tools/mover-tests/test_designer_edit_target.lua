local NS = ...

-- ============================================================
-- THE DESIGNERS' EDIT TARGET
-- ------------------------------------------------------------
-- The Aura and Text Designers edit the template the selected MODE uses -- unless
-- the page that builds them names an edit target (opts.target): a settings table
-- that names its own template, its own enable and its own frame size.
--   1. the template bar (GUI:CreateDesignerPresetBar) points a REFERENCE instead
--      of a mode when handed getRef / setRef, and a mode bar is unchanged
--   2. the Aura Designer's accessor (P.ResolveEditTarget / EditTarget /
--      EditTargetEnabled / SetEditTargetEnabled) and GetAuraDesignerDB, run
--   3. the Text Designer's TDEditTarget, run
--   4. SOURCE SHAPE: no Aura Designer UI file reads GUI.SelectedMode except the
--      accessor itself -- a direct read answers for the mode tab while the page
--      is editing something else
--   5. the neutral pieces it rides on: the page harness's fill widget, the shared
--      text preview's re-bind and its standalone-frame refresh, the engine's
--      standalone walk
-- ============================================================

local savedDF = DandersFrames
local saved = { CreateFrame = CreateFrame, PlaySound = PlaySound, SOUNDKIT = SOUNDKIT }

local function strip(src)
    src = src:gsub("\r\n", "\n")
    -- Long comments, then line comments (no string in these files holds "--").
    src = src:gsub("%-%-%[%[.-%]%]", "")
    src = src:gsub("%-%-[^\n]*", "")
    return src
end

-- Cut `from ... upto` (both plain) out of a source, CRLF-tolerant.
local function cutBetween(src, from, upto)
    src = src:gsub("\r\n", "\n")
    local a = src:find(from, 1, true)
    if not a then return nil end
    local b = src:find(upto, a, true)
    if not b then return nil end
    return src:sub(a, b + #upto - 1)
end

-- ============================================================
-- 1. THE TEMPLATE BAR
-- ============================================================
print("-- Designer edit target: the template bar points a reference")
do
    local function noop() end
    -- Methods answer with a no-op; Text / Icon are FIELDS a styled button may carry.
    local FrameMT = { __index = function(_, k)
        if k == "Text" or k == "Icon" then return nil end
        if type(k) == "string" and k:match("^%u") then return noop end
    end }
    local made = {}
    local function Frame(kind)
        local f = setmetatable({ kind = kind, scripts = {}, shown = true, enabled = true }, FrameMT)
        f.SetScript = function(self, k, fn) self.scripts[k] = fn end
        f.GetScript = function(self, k) return self.scripts[k] end
        f.HookScript = function(self, k, fn) self.scripts["hook:" .. k] = fn end
        f.Show = function(self) self.shown = true end
        f.Hide = function(self) self.shown = false end
        f.IsShown = function(self) return self.shown end
        f.Enable = function(self) self.enabled = true end
        f.Disable = function(self) self.enabled = false end
        f.IsEnabled = function(self) return self.enabled end
        f.CreateTexture = function() return setmetatable({}, FrameMT) end
        f.CreateFontString = function()
            local fs = setmetatable({}, FrameMT)
            fs.SetText = function(s, t) s.text = t end
            fs.GetText = function(s) return s.text end
            return fs
        end
        made[#made + 1] = f
        return f
    end
    CreateFrame = function(kind) return Frame(kind) end
    PlaySound = noop
    SOUNDKIT = {}

    local function colour(v) return { r = v, g = v, b = v, a = 1 } end
    local prompts = {}
    local GUI = {
        _priv = {
            AddOverrideIndicators = noop,
            CreateElementBackdrop = function(f) return f end,
            CreatePanelBackdrop   = function(f) return f end,
            ConfirmDeletePreset   = noop,
            -- Answers at once with the name it was offered (+ "!") -- a typed name.
            PromptPresetName      = function(_, default, _, cb) prompts[#prompts + 1] = default; cb(default .. "!") end,
            OUTLINE_FLAG_ORDER    = {},
            LayoutPixelBorder     = noop,
            pixelBordered         = function(f) return f end,
        },
        Colors = {
            panel = colour(0.12), element = colour(0.18), border = colour(0.25),
            hover = colour(0.22), text = colour(0.9), textDim = colour(0.5),
        },
        GetThemeColor = function() return 1, 1, 1, 1 end,
        SnapLen = function(_, n) return n end,
    }
    local modeWrites, created = {}, {}
    local DF = { GUI = GUI, DEFAULT_PRESET = "Default" }
    DF.L = setmetatable({}, { __index = function(_, k) return k end })
    function DF:GetBorderList() return {} end
    function DF:ListDesignerPresets() return { "Default", "Mine", "Party" } end
    function DF:GetModeDesignerPresetName(_, mode) return mode == "raid" and "Raid" or "Party" end
    function DF:SetModeDesignerPreset(kind, mode, name) modeWrites[#modeWrites + 1] = kind .. ":" .. mode .. "=" .. name end
    function DF:ListDesignerPresetUsers() return { "Raid" } end
    function DF:CreateDesignerPreset(_, name) created[#created + 1] = name; return name end
    function DF:DuplicateDesignerPreset(_, _, name) created[#created + 1] = name; return name end
    DandersFrames = DF
    load_options_file_into("GUI/SettingsWidgets.lua", NS)
    GUI.RegisterMenu = noop
    GUI.StyleButton = noop
    GUI.ShowTooltip = noop
    GUI.HideTooltip = noop

    -- The dropdown is the bar's first Button; its menu rows are made on open.
    local function Open(bar, from)
        local dd
        for i = from, #made do
            if made[i].kind == "Button" then dd = made[i] break end
        end
        dd.scripts.OnClick()
        -- Rows are pooled across opens: every shown one this bar made.
        local rows = {}
        for i = from, #made do
            local r = made[i]
            if r.kind == "Button" and r ~= dd and r.text and r.shown then rows[#rows + 1] = r end
        end
        return dd, rows
    end
    local function Texts(rows)
        local out = {}
        for i, r in ipairs(rows) do out[i] = r.text.text end
        return table.concat(out, ",")
    end
    local function Pick(rows, label)
        for _, r in ipairs(rows) do
            if r.text.text == label then r.scripts.OnClick(r) return true end
        end
        return false
    end

    -- A reference bar.
    local ref = { cur = nil }
    local changes, leads, tails = 0, 0, 0
    local from = #made + 1
    local bar = GUI:CreateDesignerPresetBar(Frame("Frame"), {
        kind = "aura",
        getRef = function() return ref.cur or "Party" end,
        setRef = function(n) ref.cur = n end,
        getLabel = function() if not ref.cur then return "Same as Party Frames" end end,
        leadItems = { { label = "Same as Party Frames", onClick = function() leads = leads + 1; ref.cur = nil end } },
        tailItems = { { label = "Make Own Template", onClick = function() tails = tails + 1 end } },
        listUsers = function(n) return { "Party", "Other (" .. n .. ")" } end,
        registryKey = "unit:player:aura",
        onChange = function() changes = changes + 1 end,
    })
    local dd, rows = Open(bar, from)
    eq(dd.text.text, "Same as Party Frames", "ref bar: the label it was given")
    eq(Texts(rows), "Same as Party Frames,Default,Mine,Party,Make Own Template",
       "ref bar: lead items, the library, tail items")
    check(Pick(rows, "Mine"), "ref bar: a library pick")
    eq(ref.cur, "Mine", "...goes through setRef")
    eq(#modeWrites, 0, "...and never writes a mode")
    eq(changes, 1, "...and reports the change")
    eq(dd.text.text, "Mine", "...and the bar shows the name")
    _, rows = Open(bar, from)
    Pick(rows, "Same as Party Frames")
    eq(leads, 1, "ref bar: a lead item runs its own action")
    eq(ref.cur, nil, "...here: back to following")
    _, rows = Open(bar, from)
    Pick(rows, "Make Own Template")
    eq(tails, 1, "ref bar: a tail item runs its own action")
    eq(changes, 3, "...and both report the change")
    eq(GUI._designerPresetBars["unit:player:aura"], bar, "ref bar: refreshed under its own key")
    eq(GUI._designerPresetBars.aura, nil, "...never the mode bar's")
    -- New points the reference at the new template. The four labelled actions
    -- are the bar's Buttons with no label region of their own; New is the first.
    ref.cur = "Mine"
    local fired = false
    for i = from, #made do
        local b = made[i]
        if not fired and b.kind == "Button" and b ~= dd and b.scripts.OnClick and not b.text then
            local n = #prompts
            b.scripts.OnClick(b)
            if #prompts > n then fired = prompts[#prompts] end
        end
    end
    eq(fired, "", "ref bar: New prompts for a name")
    eq(ref.cur, "!", "...and points the reference at the new template")
    eq(#modeWrites, 0, "...still without a mode write")

    -- A mode bar is unchanged.
    from = #made + 1
    local mbar = GUI:CreateDesignerPresetBar(Frame("Frame"), { kind = "text", getMode = function() return "raid" end })
    local mdd, mrows = Open(mbar, from)
    eq(mdd.text.text, "Raid", "mode bar: the mode's template")
    eq(Texts(mrows), "Default,Mine,Party", "mode bar: the library, nothing else")
    Pick(mrows, "Mine")
    eq(modeWrites[#modeWrites], "text:raid=Mine", "mode bar: a pick writes the mode")
    eq(GUI._designerPresetBars.text, mbar, "mode bar: refreshed under its kind")
end
CreateFrame, PlaySound, SOUNDKIT = saved.CreateFrame, saved.PlaySound, saved.SOUNDKIT
DandersFrames = savedDF

-- ============================================================
-- 2. THE AURA DESIGNER'S ACCESSOR, RUN
-- ============================================================
print("-- Designer edit target: the Aura Designer's accessor")
do
    local OPT = options_file_source("AuraDesigner/UI/Options.lua")
    local block = cutBetween(OPT, "function P.ResolveEditTarget(target, mode)", "P.GetAuraDesignerDB = GetAuraDesignerDB")
    check(block ~= nil, "accessor: can be cut out of Options.lua")
    local W = { partyOn = true, raidOn = false, writes = {} }
    local lib = { Default = { tag = "default" }, Party = { tag = "party" }, Raid = { tag = "raid" }, Player = { tag = "player" } }
    local party, raid = { frameWidth = 100 }, { frameWidth = 80 }
    local DF = { DEFAULT_PRESET = "Default", PartyDefaults = {} }
    function DF:GetDB(mode) return mode == "raid" and raid or party end
    function DF:GetModeDesignerPresetName(_, mode) return mode == "raid" and "Raid" or "Party" end
    function DF:GetModeBaseAuraDesigner(mode) return lib[mode == "raid" and "Raid" or "Party"] end
    function DF:GetAuraDesignerPresets() return lib end
    function DF:IsAuraDesignerEnabledForMode(mode)
        if mode == "raid" then return W.raidOn end
        return W.partyOn
    end
    function DF:SetAuraDesignerEnabledForMode(mode, on) W.writes[#W.writes + 1] = mode .. "=" .. tostring(on) end
    function DF:IsAuraDesignerEnabledForDB(d) return d.auraDesignerEnabled == true end
    for _, k in ipairs({ "MigrateAuraDesignerSpecScope", "MigrateAuraDesignerInstancesLazy",
        "MigrateAuraDesignerBorderKeysLazy", "MigrateAuraDesignerPrioritiesLazy",
        "MigrateAuraDesignerAbsoluteLevelsLazy", "MigrateAuraDesignerAbsoluteLevelsV2Lazy",
        "MigrateAuraDesignerDefaultRefreshLazy", "MigrateAuraDesignerOrphanAuraKeysLazy",
        "MigrateAuraDesignerIndicatorStrataLazy" }) do DF[k] = function() end end
    local S, P = {}, {}
    local GUI = { SelectedMode = "party" }
    local chunk = block and loadstring(block .. "\nreturn GetAuraDesignerDB", "@AD:EditTarget")
    check(chunk ~= nil, "accessor: compiles")
    if chunk then
        setfenv(chunk, setmetatable({ DF = DF, S = S, P = P, GUI = GUI }, { __index = _G }))
        local GetAuraDesignerDB = chunk()

        -- No target: the mode, exactly as before.
        local t = P.EditTarget()
        eq(t.mode, "party", "mode: the selected mode")
        eq(t.name, "Party", "mode: ...its template")
        eq(t.db, party, "mode: ...its table")
        eq(GetAuraDesignerDB(), lib.Party, "mode: the editor edits the mode's template")
        eq(P.EditTargetEnabled(), true, "mode: the mode's enable")
        GUI.SelectedMode = "raid"
        eq(P.EditTarget().mode, "raid", "mode: follows the tab")
        eq(GetAuraDesignerDB(), lib.Raid, "mode: ...and its template")
        eq(P.EditTargetEnabled(), false, "mode: ...and its enable")
        P.SetEditTargetEnabled(nil, true)
        eq(W.writes[#W.writes], "raid=true", "mode: the enable writes the mode")

        -- A target: its template, its table, its enable -- whatever the tab says.
        local unit = { frameWidth = 60, auraDesignerEnabled = false }
        local changed = 0
        S.editTarget = { getName = function() return "Player" end, db = unit,
                         onChange = function() changed = changed + 1 end }
        t = P.EditTarget()
        eq(t.mode, nil, "target: not a mode")
        eq(t.name, "Player", "target: its template")
        eq(t.db, unit, "target: its table (size, Buff Bar defaults)")
        eq(GetAuraDesignerDB(), lib.Player, "target: the editor edits the target's template")
        eq(P.EditTargetEnabled(), false, "target: its own enable")
        local nw = #W.writes
        P.SetEditTargetEnabled(nil, true)
        eq(unit.auraDesignerEnabled, true, "target: the enable writes the target's table")
        eq(#W.writes, nw, "...and no mode")
        eq(changed, 1, "...and reports the change")
        eq(P.EditTargetEnabled(), true, "target: reads back")
        S.editTarget.getName = function() return "Gone" end
        eq(GetAuraDesignerDB(), lib.Default, "target: a missing template edits Default, never a mode's")
        S.db = { auraDesigner = { tag = "inline" } }
        S.editTarget.getName = function() return nil end
        eq(GetAuraDesignerDB(), lib.Default, "target: no legacy inline fallback")
        S.editTarget, S.db = nil, nil
        GUI.SelectedMode = "party"
        eq(GetAuraDesignerDB(), lib.Party, "no target again: the mode again")
    end
end

-- ============================================================
-- 3. THE TEXT DESIGNER'S TARGET, RUN
-- ============================================================
print("-- Designer edit target: the Text Designer's")
do
    local TD = options_file_source("TextDesigner/UI/Options.lua")
    local block = cutBetween(TD, "local function TDEditTarget(GUI, db, target)", "DF.TextDesigner._EditTarget = TDEditTarget")
    check(block ~= nil, "td: TDEditTarget can be cut out")
    local lib = { Default = { tag = "default" }, Party = { tag = "party" }, Pet = { tag = "pet" } }
    local party = { frameWidth = 125 }
    local DF = { DEFAULT_PRESET = "Default", TextDesigner = {} }
    function DF:GetTextDesignerPresets() return lib end
    function DF:GetModeBaseTextDesigner() return lib.Party end
    function DF:GetModeDesignerPresetName() return "Party" end
    function DF:GetDB() return party end
    local chunk = block and loadstring(block .. "\nreturn TDEditTarget", "@TD:EditTarget")
    check(chunk ~= nil, "td: compiles")
    if chunk then
        setfenv(chunk, setmetatable({ DF = DF }, { __index = _G }))
        local TDEditTarget = chunk()
        local cfg, name, size = TDEditTarget({ SelectedMode = "party" }, nil, nil)
        eq(cfg, lib.Party, "td mode: the mode's template")
        eq(name, "Party", "td mode: ...by name")
        eq(size, party, "td mode: the mode's frame size")
        local pet = { frameWidth = 80 }
        cfg, name, size = TDEditTarget({ SelectedMode = "party" }, pet,
            { getName = function() return "Pet" end, sizeDB = pet })
        eq(cfg, lib.Pet, "td target: its template")
        eq(name, "Pet", "td target: ...by name")
        eq(size, pet, "td target: its frame size")
        cfg = TDEditTarget({}, pet, { getName = function() return "Gone" end })
        eq(cfg, lib.Default, "td target: a missing template edits Default")
    end
    -- Built through the target everywhere the mode used to be read.
    local island = cutBetween(TD, "local function BuildTextDesignerIsland(GUI, page, db, opts)", "\nend\n") or ""
    local code = strip(island)
    local _, reads = code:gsub("GUI%.SelectedMode", "")
    eq(reads, 1, "td: the island reads the mode tab once -- the bar's own default getMode")
    check(code:find("local tdDB, _tdTargetName, _tdSizeDB = TDEditTarget(GUI, db, target)", 1, true) ~= nil,
          "td: the island edits what TDEditTarget names")
    check(code:find("for k, v in pairs(target and target.bar or {}) do barOpts[k] = v end", 1, true) ~= nil,
          "td: a target's reference rides on the bar")
    check(code:find("DF.BuildTextDesignerPage(GUI, page, db, nil, nil, opts)", 1, true) ~= nil,
          "td: the bar's rebuild keeps the target")
    check(code:find("PV:Bind(state.mockFrame, tdDB)", 1, true) ~= nil,
          "td: a page coming back into view takes the shared preview back")
end

-- ============================================================
-- 4. SOURCE SHAPE: ONE MODE READ IN THE AURA DESIGNER'S UI
-- ============================================================
print("-- Designer edit target: no raw mode reads in the Aura Designer UI")
do
    local total, where = 0, {}
    for _, f in ipairs({ "Cards.lua", "Editor.lua", "Groups.lua", "Indicators.lua", "Options.lua", "PoolStrip.lua" }) do
        local code = strip(options_file_source("AuraDesigner/UI/" .. f))
        local _, n = code:gsub("GUI%.SelectedMode", "")
        if n > 0 then where[#where + 1] = f .. ":" .. n end
        total = total + n
    end
    eq(table.concat(where, ","), "Options.lua:1", "shape: GUI.SelectedMode is read only in Options.lua, once")
    local acc = strip(cutBetween(options_file_source("AuraDesigner/UI/Options.lua"),
        "function P.EditTarget()", "\nend\n") or "")
    check(acc:find("GUI.SelectedMode", 1, true) ~= nil, "shape: ...inside P.EditTarget")
    local EDIT = options_file_source("AuraDesigner/UI/Editor.lua")
    local editCode = strip(EDIT)
    check(editCode:find("if S.mainFrameOwner ~= self then", 1, true) ~= nil,
          "shape: a page coming back into view takes the island back")
    check(editCode:find("DF.BuildAuraDesignerPage(GUI, S.page, S.db, nil, nil, S.buildOpts)", 1, true) ~= nil,
          "shape: the bar's rebuild keeps the target")
    check(editCode:find("prevDB == dbRef and prevTarget == S.editTarget", 1, true) ~= nil,
          "shape: a different target is a different build")
    check(editCode:find("if not S.rebuilding then S.editTarget = nil end", 1, true) ~= nil,
          "shape: a target ends when its island goes out of view (not mid-rebuild)")
    check(editCode:find("if S.editTarget ~= want then", 1, true) ~= nil
          and editCode:find("self._lastRefreshStatesH = nil", 1, true) ~= nil,
          "shape: ...and its page puts it back on the way in, with a repaint")
    check(editCode:find("if not S.editTarget and DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then", 1, true) ~= nil,
          "shape: a target takes no auto-layout banner offset (its page already did)")
    local CARDS = strip(options_file_source("AuraDesigner/UI/Cards.lua"))
    check(CARDS:find("local copyBtn = currentMode and CreateFrame", 1, true) ~= nil,
          "shape: Copy Settings to the other mode only when editing a mode")
end

-- ============================================================
-- 5. THE NEUTRAL PIECES
-- ============================================================
print("-- Designer edit target: what it rides on")
do
    local PANEL = strip(options_file_source("GUI/Panel.lua"))
    check(PANEL:find("if widget.layoutFill then", 1, true) ~= nil, "panel: a full-width widget can fill the viewport")
    check(PANEL:find("if fillBottom and fillBottom >= maxY then contentH = fillBottom + FILL_PAD end", 1, true) ~= nil,
          "panel: ...and then ends the page")

    local ENG = strip(df_file_source("AuraDesigner/Engine.lua"))
    check(ENG:find("for f in pairs(DF.StandaloneFrames or {}) do", 1, true) ~= nil,
          "engine: an editor change reaches standalone frames")
    check(ENG:find("if not f.dfPreview and (f.dfADFactory or DF:IsAuraDesignerEnabled(f)) then TryUpdate(f) end", 1, true) ~= nil,
          "engine: ...never a preview, and one that never drew it is left alone")

    -- The shared text preview, run.
    local DF = { TextDesigner = {} }
    local inits, renders = 0, {}
    function DF:Debug() end
    function DF:UpdateTextDesigner(f) renders[#renders + 1] = f end
    load_df_file_into("TextDesigner/Preview.lua", DF)
    local PV = DF.TextDesigner.Preview
    local realInit = PV.Init
    PV.Init = function(self, m, t) inits = inits + 1; return realInit(self, m, t) end
    local m1, m2, t1 = {}, {}, {}
    PV:Bind(m1, t1)
    eq(inits, 1, "preview: Bind binds")
    PV:Bind(m1, t1)
    eq(inits, 1, "preview: ...and not again when already bound")
    PV:Bind(m2, t1)
    eq(inits, 2, "preview: another page's mock re-binds")
    local shown = { IsVisible = function() return true end }
    local hidden = { IsVisible = function() return false end }
    DF.StandaloneFrames = { [shown] = true, [hidden] = true }
    renders = {}
    PV:RefreshLiveFrames()
    eq(#renders, 1, "preview: a live refresh reaches the shown standalone frame")
    eq(renders[1], shown, "...only that one")
end
