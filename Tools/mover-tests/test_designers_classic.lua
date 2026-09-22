local NS = ...

-- ============================================================
-- THE DESIGNERS BUILD CLASSIC IN BOTH LAYOUTS
-- ------------------------------------------------------------
-- Decided 2026-09-22: testers rated the classic designers the best part of the
-- settings panel, so the Aura, Text and Filter Designers build their classic
-- version in the Modern layout too. The rows builds stay in the files, unused,
-- behind one switch (DF:DesignersUseRows).
--
-- ☠ THE CLASSIC BUILD HAS TO REACH EVERYTHING THE ROWS BUILD DID. The rows
-- rework moved things out of the split panel rather than copying them -- the
-- Aura Designer's spec picker left the pool strip for a band of its own
-- (dff68754), and the strip was the classic panel's only copy. These checks pin
-- what the classic build must still offer, so a later move cannot strand it.
--
-- What is RUN here rather than read: the switch itself, the pool list (PoolDefs)
-- and the classic pool strip (S.BuildPoolStrip) against stub frames. The island
-- as a whole cannot be built headlessly; its wiring is read off the source.
-- ============================================================

local CFG   = df_file_source("Core/Config.lua")
local ROWS  = options_file_source("AuraDesigner/UI/Rows.lua")
local EDIT  = options_file_source("AuraDesigner/UI/Editor.lua")
local TD    = options_file_source("TextDesigner/UI/Options.lua")
local FD    = options_file_source("FilterRegistry/UI/Options.lua")

-- Cut `startPat ... \nend\n` out of a source, CRLF-tolerant.
local function cut(src, startPlain)
    src = src:gsub("\r\n", "\n")
    local s = src:find(startPlain, 1, true)
    if not s then return nil end
    local e = src:find("\nend\n", s, true)
    if not e then return nil end
    return src:sub(s, e + 4)
end

-- ============================================================
-- 1. THE SWITCH IS OFF, AND ALL THREE DESIGNERS ASK IT
-- ============================================================
print("-- Designers: the switch is off, so classic builds in both layouts")
do
    local body = cut(CFG, "function DF:DesignersUseRows()")
    check(body ~= nil, "switch: DF:DesignersUseRows is declared in Core/Config.lua")
    if body then
        local DFstub = {}
        local chunk = loadstring("local DF = ...\n" .. body)
        check(chunk ~= nil, "switch: its body parses")
        if chunk then
            chunk(DFstub)
            check(type(DFstub.DesignersUseRows) == "function", "switch: ...and defines the method")
            if DFstub.DesignersUseRows then
                eq(DFstub:DesignersUseRows(), false, "switch: it answers false -- the rows builds are off")
            end
        end
    end

    check(EDIT:find("if Add and P.BuildAuraDesignerRowsPage and DF:DesignersUseRows() and not DF:IsClassicSettingsLayout() then", 1, true) ~= nil,
          "switch: the Aura Designer's rows arm needs the switch")
    check(TD:find("if Add and P.BuildTextDesignerRowsPage and DF:DesignersUseRows() and not DF:IsClassicSettingsLayout() then", 1, true) ~= nil,
          "switch: the Text Designer's rows arm needs the switch")
    check(FD:find("local tools = (Add and GUI.CreatePopoutPageTools and DF:DesignersUseRows() and not DF:IsClassicSettingsLayout())", 1, true) ~= nil,
          "switch: the Filter Designer's band arm needs the switch")
    -- ☠ THE FD's LAYOUT-FLIP GUARD MUST AGREE WITH ITS ARM. It retires the old build
    -- when the arm it was built with differs from the arm wanted now; reading the
    -- layout alone would call a Modern-layout classic build "not classic" and rebuild
    -- it on every visit.
    check(FD:find("local classicNow = (DF:IsClassicSettingsLayout() or not DF:DesignersUseRows()) and true or false", 1, true) ~= nil,
          "switch: ...and the Filter Designer's flip guard reads the same switch")
end

-- ============================================================
-- 2. THE POOL LIST: FOUR POOLS, THE FOURTH ON A PRIEST ONLY
-- Run, not read: the list is a function of the locale and the class.
-- ============================================================
print("-- Aura Designer: the pool list, run")
local poolDefsSrc = cut(ROWS, "local function PoolDefs()")
check(poolDefsSrc ~= nil, "pool: PoolDefs can be cut out of Rows.lua")

local Lid = setmetatable({}, { __index = function(_, k) return k end })

local function RunPoolDefs(priest)
    if not poolDefsSrc then return {} end
    local chunk = loadstring("local L, DF = ...\n" .. poolDefsSrc .. "\nreturn PoolDefs()")
    if not chunk then return {} end
    return chunk(Lid, { IsPIHelperAvailable = function() return priest end })
end

do
    local keys = function(defs)
        local out = {}
        for i, d in ipairs(defs) do out[i] = d.key end
        return table.concat(out, ",")
    end
    eq(keys(RunPoolDefs(false)), "my,debuffs,other", "pool: a non-priest gets My Buffs / Debuffs / Any Buff")
    local priest = RunPoolDefs(true)
    eq(keys(priest), "my,debuffs,other,pihelper", "pool: a priest also gets the PI Helper, appended last")
    local pih = priest[4] or {}
    eq(pih.label, "PI Helper", "pool: the helper's tab says PI Helper")
    eq(pih.tooltipTitle, "Power Infusion Helper", "pool: ...and its tooltip gives the full name")
    eq(type(pih.tooltip) == "table" and pih.tooltip[1] or nil,
       "Who is worth casting Power Infusion on, and how that shows on the frame.",
       "pool: ...with the helper's own explanation")
end

-- ============================================================
-- 3. THE CLASSIC POOL STRIP, BUILT AGAINST STUB FRAMES
-- ============================================================
print("-- Aura Designer: the classic pool strip builds every pool")
do
    local stripSrc = cut(ROWS, "S.BuildPoolStrip = function(buffTabBar)")
    check(stripSrc ~= nil, "strip: S.BuildPoolStrip can be cut out of Rows.lua")

    local function Stub()
        local f = { scripts = {}, hooks = {}, points = {} }
        function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function f:ClearAllPoints() self.points = {} end
        function f:SetWidth(w) self.w = w end
        function f:GetWidth() return self.w or 0 end
        function f:SetScript(k, fn) self.scripts[k] = fn end
        function f:HookScript(k, fn) self.hooks[k] = fn end
        function f:SetActive(v) self.active = v end
        return f
    end

    local function Build(priest, activeKey)
        if not (stripSrc and poolDefsSrc) then return nil end
        local S = { activeBuffTab = activeKey }
        local buttons, tips, clicked = {}, {}, {}
        local GUI = {
            StyleButton = function(_, btn, o) btn.Text = Stub(); btn.label = o.text end,
            ShowTooltip = function(_, _, t) tips[#tips + 1] = t end,
            HideTooltip = function() end,
        }
        local env = {
            L = Lid, S = S, GUI = GUI,
            DF = { IsPIHelperAvailable = function() return priest end },
            mainTabButtons = buttons,
            SetMainTab = function(k) clicked[#clicked + 1] = k end,
            CreateFrame = function() return Stub() end,
            wipe = function(t) for k in pairs(t) do t[k] = nil end end,
            BUFFTAB_H = 30,
        }
        setmetatable(env, { __index = _G })
        local chunk = loadstring(poolDefsSrc .. "\n" .. stripSrc)
        if not chunk then return nil end
        setfenv(chunk, env)
        chunk()
        local host = Stub()
        host.w = 400
        S.BuildPoolStrip(host)
        return { buttons = buttons, tips = tips, clicked = clicked, host = host }
    end

    local r = Build(false, "my")
    check(r ~= nil, "strip: builds headlessly")
    if r then
        check(r.buttons.my and r.buttons.debuffs and r.buttons.other and true or false,
              "strip: a non-priest gets all three pools as buttons")
        check(r.buttons.pihelper == nil, "strip: ...and no PI Helper tab")
        eq(r.buttons.my and r.buttons.my.active, true, "strip: the active pool reads as selected")
        eq(r.buttons.debuffs and r.buttons.debuffs.active, false, "strip: ...and the others do not")
        -- Equal widths off the host: (400 - 2*4) / 3.
        eq(r.buttons.other and r.buttons.other.w, (400 - 2 * 4) / 3, "strip: the tabs divide the strip equally")
    end

    local p = Build(true, "pihelper")
    check(p ~= nil, "strip: builds headlessly for a priest")
    if p then
        local b = p.buttons.pihelper
        check(b ~= nil, "strip: a priest gets the PI Helper tab")
        eq(b and b.label, "PI Helper", "strip: ...labelled PI Helper")
        eq(b and b.active, true, "strip: ...and lit when it is the active pool")
        eq(p.buttons.other and p.buttons.other.w, (400 - 3 * 4) / 4, "strip: four tabs divide the strip in quarters")
        -- Clicking a tab goes through SetMainTab, which owns every side effect.
        if p.buttons.debuffs and p.buttons.debuffs.scripts.OnClick then p.buttons.debuffs.scripts.OnClick() end
        eq(p.clicked[1], "debuffs", "strip: a click switches pool through SetMainTab")
        -- The hover names the full helper, not the abbreviation.
        if b and b.hooks.OnEnter then b.hooks.OnEnter(b) end
        local t = p.tips[#p.tips]
        eq(t and t.title, "Power Infusion Helper", "strip: the PI Helper tooltip is titled with the full name")
    end
end

-- ============================================================
-- 4. THE CLASSIC ISLAND MOUNTS THE STRIP AND THE SPEC PICKER
-- ============================================================
print("-- Aura Designer: the split panel mounts the pools and the spec picker")
do
    local island = cut(EDIT, "local function BuildAuraDesignerIsland(guiRef, pageRef, dbRef)")
    check(island ~= nil, "island: its body can be read")
    island = island or ""
    check(island:find("S.BuildPoolStrip(poolHost)", 1, true) ~= nil,
          "island: the pool tabs are built into the strip")
    -- ☠ THE REGRESSION THIS FILE WAS WRITTEN FOR: dff68754 took Spec out of the
    -- split panel's strip and gave it nowhere else to live.
    check(island:find("S.BuildSpecPicker(specHost)", 1, true) ~= nil,
          "island: the spec picker is back on the strip")
    local a = island:find("S.BuildPoolStrip(poolHost)", 1, true)
    local b = island:find([[poolHost:SetPoint("RIGHT", specHost, "LEFT", -SPEC_GAP, 0)]], 1, true)
    check(b ~= nil and a ~= nil and b < a,
          "island: ...and the pools divide what is left of the strip beside it")
    -- The shared builder it reuses is still the rows page's, not a copy.
    check(ROWS:find("S.BuildSpecPicker = function(host)", 1, true) ~= nil,
          "island: the spec picker it mounts is the one shared builder")
    check(EDIT:find("S.BuildSpecPicker = function", 1, true) == nil,
          "island: ...not a second copy in Editor.lua")
    -- The pool strip's tooltip title honours the helper's full name.
    check(ROWS:find("local tipTitle, tipLines = def.tooltipTitle or def.label, def.tooltip", 1, true) ~= nil,
          "island: the pool strip titles an abbreviated tab with its full name")
    -- Everything else the pools reach in the classic panel -- the helper's Triggers
    -- and Effects, its enable card and its add area -- hangs off shared builders
    -- the classic tab functions already call.
    local cards = options_file_source("AuraDesigner/UI/Cards.lua")
    check(cards:find("yPos = S.BuildPIHelperAddArea(parent, yPos, function() S.SwitchTab(\"effects\") end)", 1, true) ~= nil,
          "island: the helper's add area is on the classic Effects tab")
    check(cards:find("local yPos, open = S.BuildPIHelperCard(parent, { startY = -10, Refresh = Refresh })", 1, true) ~= nil,
          "island: the helper's enable card is on the classic Triggers tab")
    check(cards:find('{ key = "global",  label = L["Triggers"]', 1, true) ~= nil,
          "island: ...which the helper's pool labels Triggers")
end
