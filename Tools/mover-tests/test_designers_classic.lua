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

-- ============================================================
-- 5. THE CLASSIC ADD FLOWS ARE THE MODERN ONES, RUN INSIDE THE TAB (2026-09-22)
-- ------------------------------------------------------------
-- The split panel's three add areas -- the Effects tab's three scope cards
-- (Placed on the Frame / Frame-Level Effect / From a Filter) and the Layout
-- Groups / Debuffs choice-card blocks -- became one button PER SOURCE, and a
-- button runs the Modern pane INSIDE its tab, in place of the list, headed by a
-- "Back to ..." control. (ffd4031c hosted the panes in a popout beside the
-- window; the author does not want a popout, and it is gone.)
-- What is RUN: the buttons, the flow's start / end / re-sync, the pane hosting
-- and the page watchers, against stub frames and a stub S.SwitchTab that does
-- what the classic arm does. What is READ: which head area mounts which buttons,
-- and that the tab builders and S.SwitchTab ask the flow first.
-- ============================================================
print("-- Aura Designer: the classic add buttons run the Modern flows inside the tab")
do
    local CARDS = options_file_source("AuraDesigner/UI/Cards.lua"):gsub("\r\n", "\n")
    local EDITN = EDIT:gsub("\r\n", "\n")

    -- ---- read: the old three-option list and the card blocks are gone ----
    check(CARDS:find("local function AddFlowScopes()", 1, true) == nil,
          "classic add: the three-scope list is gone")
    check(CARDS:find('L["Placed on the Frame"]', 1, true) == nil,
          "classic add: ...no 'Placed on the Frame' option is drawn")
    -- (The PI Helper's own tiles keep an ADD AN INDICATOR caption; that is theirs.)
    check(CARDS:find('title    = L["ADD AN INDICATOR"]', 1, true) == nil,
          "classic add: ...nor the ADD AN INDICATOR card block")
    check(CARDS:find("effectsPicker", 1, true) == nil,
          "classic add: ...nor the picker column it took over")
    check(CARDS:find("local function OpenIndicatorPicker(", 1, true) == nil,
          "classic add: ...nor the per-type spell picker only that column opened")
    check(EDITN:find('L["ADD A LAYOUT GROUP"]', 1, true) == nil,
          "classic add: the Layout Groups card block is gone")
    check(EDITN:find('L["ADD A DEBUFF GROUP"]', 1, true) == nil,
          "classic add: ...and the Debuffs one")

    -- ---- read: no popout hosting is left ----
    check(CARDS:find('"df.adadd.', 1, true) == nil,
          "classic add: no keyed add popout is created any more")
    for _, name in ipairs({ "S.OpenClassicAddPopout", "S.SyncClassicAddPopouts",
                            "DockClassicAddPopout", "CLASSIC_ADD_ICON",
                            "S.classicAddLive", "S.classicAddOpen", "S.BuildClassicAddButton(" }) do
        check(CARDS:find(name, 1, true) == nil and EDITN:find(name, 1, true) == nil,
              "classic add: the popout host's " .. name .. " is gone")
    end

    -- ---- read: each classic head area mounts its buttons ----
    local head = CARDS:match("S%.BuildEffectsHeadArea = function%(parent, yPos, opts%)(.-)\nend\n") or ""
    check(head:find('yPos = S.BuildClassicAddButtons(parent, yPos, "indicator")', 1, true) ~= nil,
          "classic add: the Effects tab mounts its add buttons")
    local lg = EDITN:match("S%.BuildLayoutGroupsHeadArea = function%(parent, yPos, opts%)(.-)\nend\n") or ""
    check(lg:find('    if not skipAdd then\n        yPos = S.BuildClassicAddButtons(parent, yPos, "layout")', 1, true) ~= nil,
          "classic add: the Layout Groups tab mounts its add buttons, unless the rows page asked it not to")
    local dg = EDITN:match("S%.BuildDebuffGroupsHeadArea = function%(parent, yPos, opts%)(.-)\nend\n") or ""
    check(dg:find('    if not skipAdd then\n        yPos = S.BuildClassicAddButtons(parent, yPos, "debuff")', 1, true) ~= nil,
          "classic add: the Debuffs pool's tab mounts its add button, likewise")

    -- ---- read: the PI Helper pool keeps its own add area, first ----
    local piAt  = head:find("if not skipAdd and IsPIHelperTab() and S.BuildPIHelperAddArea then", 1, true)
    local btnAt = head:find('    elseif not skipAdd then\n        yPos = S.BuildClassicAddButtons(parent, yPos, "indicator")', 1, true)
    check(piAt ~= nil and btnAt ~= nil and piAt < btnAt,
          "classic add: the PI Helper pool takes its own tiles, never the add buttons")
    check(CARDS:find("S.BuildPIHelperAddArea = function(parent, yPos, Refresh)\n    yPos = pihBuildAddTiles(parent, yPos, Refresh)\n    return pihBuildSoundBox(parent, yPos, Refresh)\nend", 1, true) ~= nil,
          "classic add: ...and S.BuildPIHelperAddArea itself is untouched")

    -- ---- read: the refresh path and the three tab builders ask the flow first ----
    local sw = CARDS:match("S%.SwitchTab = function%(tabKey%)(.-)\nend\n") or ""
    check(sw:find("if S.SyncClassicAddFlow then S.SyncClassicAddFlow(tabKey) end", 1, true) ~= nil,
          "classic add: S.SwitchTab re-checks a running flow before it rebuilds")
    local syncAt = sw:find("S.SyncClassicAddFlow(tabKey)", 1, true)
    local clearAt = sw:find("ClearTabContent()", 1, true)
    check(syncAt and clearAt and syncAt < clearAt, "classic add: ...before the tab is cleared and rebuilt")
    local et = CARDS:match("S%.BuildEffectsTab = function%(%)(.-)\nend\n") or ""
    local flowAt = et:find('if S.BuildClassicAddFlow and S.BuildClassicAddFlow(parent, "indicator") then return end', 1, true)
    local headAt = et:find("S.BuildEffectsHeadArea(parent, -10)", 1, true)
    check(flowAt and headAt and flowAt < headAt,
          "classic add: the Effects tab draws a running flow in place of its list")
    local lt = EDITN:match("S%.BuildLayoutGroupsTab = function%(%)(.-)\nend\n") or ""
    check(lt:find('if S.BuildClassicAddFlow and S.BuildClassicAddFlow(parent, "layout") then return end', 1, true) ~= nil,
          "classic add: ...and so does the Layout Groups tab")
    local dt = EDITN:match("S%.BuildDebuffGroupsTab = function%(%)(.-)\nend\n") or ""
    check(dt:find('if S.BuildClassicAddFlow and S.BuildClassicAddFlow(parent, "debuff") then return end', 1, true) ~= nil,
          "classic add: ...and the Debuffs pool's tab")

    -- ---- read: the group panes' chosen-kind opt-in, and the rows page untouched ----
    check(EDITN:find("return BuildChosenGroupPane(host, opts, LayoutGroupCards(), gc, L[\"Add Layout Group\"])", 1, true) ~= nil,
          "classic add: the Layout Group pane draws the chosen kind when told it")
    check(EDITN:find("return BuildChosenGroupPane(host, opts, DebuffGroupCards(), gc, L[\"Add Debuff Group\"])", 1, true) ~= nil,
          "classic add: ...and so does the Debuff Group pane")
    check(ROWS:find("local BuildAddPane = isDebuffs and S.BuildAddDebuffGroupPane or S.BuildAddLayoutGroupPane", 1, true) ~= nil,
          "classic add: the rows page still mounts the same two panes, unchanged")

    -- ---- run: the block itself, against stubs ----
    local s0 = CARDS:find("S.ClassicAddContext = function()", 1, true)
    local s1 = CARDS:find("-- ☠ EXTRACTED, NOT COPIED. The popout layout's row page", s0 or 1, true)
    check(s0 ~= nil and s1 ~= nil, "classic add: the flow block can be cut out of Cards.lua")
    local block = (s0 and s1) and CARDS:sub(s0, s1 - 1) or ""

    local function Stub(parent)
        local f = { scripts = {}, hooks = {}, points = {}, shown = true, h = 0, w = 0,
                    kids = {}, fs = {}, parent = parent }
        if parent and parent.kids then parent.kids[#parent.kids + 1] = f end
        function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function f:ClearAllPoints() self.points = {} end
        function f:SetWidth(w) self.w = w end
        function f:GetWidth() return self.w end
        function f:SetHeight(h) self.h = h end
        function f:GetHeight() return self.h end
        function f:SetScript(k, fn) self.scripts[k] = fn end
        function f:HookScript(k, fn)
            self.hooks[k] = self.hooks[k] or {}
            table.insert(self.hooks[k], fn)
        end
        function f:Fire(k, ...) for _, fn in ipairs(self.hooks[k] or {}) do fn(self, ...) end end
        function f:SetDisabled(v) self.dfDisabled = v end
        function f:Show() self.shown = true end
        function f:Hide() self.shown = false end
        function f:IsShown() return self.shown end
        function f:IsVisible() return self.shown end
        function f:GetParent() return self.parent end
        function f:SetVerticalScroll(v) self.scroll = v end
        function f:GetVerticalScroll() return self.scroll or 0 end
        function f:CreateFontString()
            local fs = { }
            function fs:SetPoint() end
            function fs:SetJustifyH() end
            function fs:SetWordWrap() end
            function fs:SetText(t) self.text = t end
            function fs:SetTextColor() end
            self.fs[#self.fs + 1] = fs
            return fs
        end
        return f
    end

    -- A world: the island's state table, a content column of `width`, a stub
    -- S.SwitchTab that runs the classic arm's order -- sync, clear, then either the
    -- flow or the list (whose head area mounts the real buttons) -- and stub panes
    -- that record how they were asked to build.
    local function World(opts)
        opts = opts or {}
        local W = { enabled = opts.enabled ~= false, spec = 105, builds = {}, syncs = 0,
                    drew = {}, timers = {} }
        local S = { activeBuffTab = opts.pool or "my", activeTab = "effects" }
        W.S = S
        local function Pane(kind)
            return function(host, o)
                W.builds[#W.builds + 1] = { kind = kind, opts = o, host = host }
                host:SetHeight(300)
                if o.SetHeight then o.SetHeight(300) end
                if kind == "indicator" then
                    local snap = { tag = #W.builds }
                    return { Sync = function() W.syncs = W.syncs + 1 end,
                             Snapshot = function() return snap end }
                end
                return 300
            end
        end
        S.BuildAddIndicatorPane   = Pane("indicator")
        S.BuildAddLayoutGroupPane = Pane("layout")
        S.BuildAddDebuffGroupPane = Pane("debuff")
        S.rightPanel = Stub()
        S.tabScrollFrame = Stub()
        S.tabContentFrame = Stub()
        S.tabContentFrame.w = opts.width or 300
        local GUI = {
            SelectedMode = "party",
            PopoutContentWidth = 260,
            StyleButton = function(_, btn, o)
                btn.styled = o
                if o.width then btn.w = o.width end
                if o.height then btn.h = o.height end
            end,
        }
        W.GUI = GUI
        local function ListKind()
            if S.activeTab == "effects" then return "indicator" end
            return (S.activeBuffTab == "debuffs") and "debuff" or "layout"
        end
        S.SwitchTab = function(tabKey)
            S.activeTab = tabKey
            if S.SyncClassicAddFlow then S.SyncClassicAddFlow(tabKey) end
            local c = S.tabContentFrame
            for _, k in ipairs(c.kids) do k:Hide(); k:ClearAllPoints() end
            local kind = ListKind()
            if S.BuildClassicAddFlow(c, kind) then
                W.drew[#W.drew + 1] = "flow:" .. kind
            else
                W.drew[#W.drew + 1] = "list:" .. kind
                if not (kind == "indicator" and S.activeBuffTab == "pihelper") then
                    W.buttons = {}
                    local n = #c.kids
                    S.BuildClassicAddButtons(c, -10, kind)
                    for i = n + 1, #c.kids do W.buttons[#W.buttons + 1] = c.kids[i] end
                end
            end
        end
        local env = {
            L = setmetatable({}, { __index = function(_, k) return k end }),
            S = S, GUI = GUI,
            DF = { IsAuraDesignerEnabledForMode = function() return W.enabled end },
            IsOtherTab = function() return S.activeBuffTab == "other" or S.activeBuffTab == "pihelper" end,
            IsDebuffTab = function() return S.activeBuffTab == "debuffs" end,
            IsPIHelperTab = function() return S.activeBuffTab == "pihelper" end,
            ResolveSpec = function() return W.spec end,
            GetThemeColor = function() return { r = 0.4, g = 0.5, b = 0.9 } end,
            CreateFrame = function(_, _, parent) return Stub(parent) end,
            C_Timer = { After = function(_, fn) W.timers[#W.timers + 1] = fn end },
            max = math.max, floor = math.floor,
        }
        setmetatable(env, { __index = _G })
        local chunk = loadstring(block)
        if chunk then setfenv(chunk, env); chunk() end
        W.ok = chunk ~= nil and S.BuildClassicAddButtons ~= nil and S.BuildClassicAddFlow ~= nil
            and S.StartClassicAddFlow ~= nil
        -- Draw the list for the current tab, as a visit would.
        W.Visit = function(tab) if W.ok then S.SwitchTab(tab or S.activeTab) end end
        W.Click = function(i)
            local b = W.buttons and W.buttons[i]
            if b and b.scripts.OnClick then b.scripts.OnClick(b) end
            return b
        end
        W.Last = function() return W.drew[#W.drew] end
        -- The flow's own Back button and heading, off the content column.
        W.Back = function()
            for _, k in ipairs(S.tabContentFrame.kids) do
                if k.shown and k.styled and k.styled.ghost then return k end
            end
        end
        W.Heading = function()
            local fs = S.tabContentFrame.fs
            return fs[#fs] and fs[#fs].text
        end
        return W
    end

    -- ---- the enabled gate ----
    local off = World({ enabled = false })
    check(off.ok, "classic add: the flow block loads headlessly")
    if off.ok then
        off.Visit("effects")
        eq(#(off.buttons or {}), 2, "classic add: the Effects tab has two add buttons")
        eq(off.buttons[1] and off.buttons[1].dfDisabled, true, "classic add: a disabled designer greys them")
        eq(off.buttons[2] and off.buttons[2].dfDisabled, true, "classic add: ...both of them")
        off.Click(1)
        eq(off.S.classicAddFlow, nil, "classic add: ...and a click on one starts nothing")
        eq(off.S.StartClassicAddFlow("indicator", "spell"), false,
           "classic add: ...nor does the starter, asked directly")
        eq(#off.builds, 0, "classic add: ...so no pane is built")
    end

    -- ---- indicators: two buttons, each entering the flow with its source ----
    local on = World({ width = 300 })
    if on.ok then
        on.Visit("effects")
        local b1, b2 = on.buttons[1], on.buttons[2]
        eq(b1 and b1.styled.text, "Add from a Spell", "classic add: the first button says Add from a Spell")
        eq(b2 and b2.styled.text, "Add from a Filter", "classic add: ...the second Add from a Filter")
        eq(b1 and b1.dfDisabled, nil, "classic add: an enabled designer leaves them live")
        eq(b1 and b1.styled.fitText, false, "classic add: ...side by side, neither growing into the other")
        eq(b1 and b1.w, b2 and b2.w, "classic add: ...at equal widths")
        on.S.tabScrollFrame.scroll = 120
        on.Click(1)
        eq(on.Last(), "flow:indicator", "classic add: Add from a Spell replaces the Effects list with the flow")
        local bi = on.builds[1]
        eq(bi and bi.kind, "indicator", "classic add: ...built by S.BuildAddIndicatorPane")
        eq(bi and bi.opts.source, "spell", "classic add: ...with the spell route already chosen")
        eq(bi and bi.opts.fitWidth, true, "classic add: ...laid out for the tab's width")
        eq(bi and bi.opts.width, 300 - 4, "classic add: ...which is the tab's column, less the pane's gutter")
        eq(on.S.tabScrollFrame.scroll, 0, "classic add: ...starting at the top")
        local back = on.Back()
        eq(back and back.styled.text, "Back to Effects", "classic add: the flow is headed by Back to Effects")
        eq(on.Heading(), "Add from a Spell", "classic add: ...and by the source that was chosen")

        -- A rebuild of the same tab keeps the pane, re-synced.
        local syncs = on.syncs
        on.S.SwitchTab("effects")
        eq(on.Last(), "flow:indicator", "classic add: a rebuild of the tab keeps the flow")
        eq(#on.builds, 1, "classic add: ...and the same pane, not a new one")
        eq(on.syncs, syncs + 1, "classic add: ...re-synced, because a kept pane is stale")
        eq(bi.host.shown, true, "classic add: ...and shown again after the clear")

        -- Back returns to the list, at the scroll the list was left at.
        on.Back().scripts.OnClick(on.Back())
        eq(on.S.classicAddFlow, nil, "classic add: Back ends the flow")
        eq(on.Last(), "list:indicator", "classic add: ...and the tab draws the effect list again")
        eq(on.S.tabScrollFrame.scroll, 120, "classic add: ...where the list was left")

        -- The filter button.
        on.Click(2)
        local bf = on.builds[#on.builds]
        eq(bf and bf.opts.source, "filter", "classic add: Add from a Filter enters with the filter route chosen")
        eq(on.Heading(), "Add from a Filter", "classic add: ...headed by its own label")
        -- The pane finishing: its Close ends the flow, its add verb rebuilds the tab.
        bf.opts.Close()
        eq(on.S.classicAddFlow, nil, "classic add: the pane's Close ends the flow")
        on.S.SwitchTab("effects")
        eq(on.Last(), "list:indicator", "classic add: ...so the rebuild after an add lands on the list")
    end

    -- ---- a new width builds the pane again, from its answers ----
    local rs = World({ width = 300 })
    if rs.ok then
        rs.Visit("effects")
        rs.Click(1)
        local cf = rs.S.tabContentFrame
        cf.w = 520
        cf:Fire("OnSizeChanged", 520)
        eq(#rs.timers, 1, "classic add: a resize under a flow schedules one re-lay")
        cf:Fire("OnSizeChanged", 530)
        eq(#rs.timers, 1, "classic add: ...coalesced while one is pending")
        cf.w = 530
        rs.timers[1]()
        eq(#rs.builds, 2, "classic add: ...which builds the pane again")
        local b2 = rs.builds[2]
        eq(b2 and b2.opts.width, 530 - 4, "classic add: ...at the new width")
        eq(b2 and b2.opts.restore and b2.opts.restore.tag, 1,
           "classic add: ...from the first pane's own answers")
        eq(b2 and b2.opts.source, "spell", "classic add: ...still on the chosen route")
    end

    -- ---- layout groups: one button per kind ----
    local lgw = World({ width = 300 })
    if lgw.ok then
        lgw.Visit("layout")
        eq(#(lgw.buttons or {}), 2, "classic add: the Layout Groups tab has two add buttons")
        eq(lgw.buttons[1] and lgw.buttons[1].styled.text, "Spell Group", "classic add: ...Spell Group")
        eq(lgw.buttons[2] and lgw.buttons[2].styled.text, "Filter Group", "classic add: ...and Filter Group")
        lgw.Click(2)
        eq(lgw.Last(), "flow:layout", "classic add: Filter Group replaces the list with the flow")
        local b = lgw.builds[1]
        eq(b and b.kind, "layout", "classic add: ...built by S.BuildAddLayoutGroupPane")
        eq(b and b.opts.kind, "filter", "classic add: ...with the kind already chosen")
        eq(b and b.opts.width, 300 - 16, "classic add: ...at the tab's column")
        eq(lgw.Back() and lgw.Back().styled.text, "Back to Layout Groups",
           "classic add: ...headed by Back to Layout Groups")
        eq(lgw.Heading(), "Filter Group", "classic add: ...and the kind")
        lgw.Back().scripts.OnClick(lgw.Back())
        eq(lgw.Last(), "list:layout", "classic add: Back returns to the Layout Groups list")
        lgw.Click(1)
        eq(lgw.builds[2] and lgw.builds[2].opts.kind, "spell", "classic add: Spell Group enters with its own kind")
        -- A create that refused: the pane closed the flow, and nothing switched the
        -- tab. Back must still reach the list.
        lgw.builds[2].opts.Close()
        local n = #lgw.drew
        lgw.Back().scripts.OnClick(lgw.Back())
        eq(#lgw.drew, n + 1, "classic add: Back still rebuilds after the flow already ended")
        eq(lgw.Last(), "list:layout", "classic add: ...onto the list")
    end

    -- ---- debuff groups: one kind, one button ----
    local dgw = World({ width = 300, pool = "debuffs" })
    if dgw.ok then
        dgw.S.activeTab = "layout"
        dgw.Visit("layout")
        eq(#(dgw.buttons or {}), 1, "classic add: the Debuffs pool has one add button")
        eq(dgw.buttons[1] and dgw.buttons[1].styled.text, "Add Debuff Group", "classic add: ...Add Debuff Group")
        dgw.Click(1)
        eq(dgw.Last(), "flow:debuff", "classic add: ...which replaces the list with the flow")
        local b = dgw.builds[1]
        eq(b and b.kind, "debuff", "classic add: ...built by S.BuildAddDebuffGroupPane")
        eq(b and b.opts.kind, "debuff", "classic add: ...with its one kind chosen")
        eq(dgw.Back() and dgw.Back().styled.text, "Back to Debuff Groups",
           "classic add: ...headed by Back to Debuff Groups")
    end

    -- ---- the PI Helper pool: no flow ----
    local pw = World({ pool = "pihelper" })
    if pw.ok then
        eq(pw.S.StartClassicAddFlow("indicator", "spell"), false,
           "classic add: the helper's pool refuses an indicator flow")
        eq(#pw.builds, 0, "classic add: ...and builds no pane")
    end

    -- ---- what ends a running flow ----
    local function Running(opts, kind, source)
        local w = World(opts)
        if not w.ok then return w end
        w.Visit(kind == "indicator" and "effects" or "layout")
        w.S.StartClassicAddFlow(kind, source)
        return w
    end
    local t1 = Running({}, "indicator", "spell")
    if t1.ok then
        t1.S.SwitchTab("global")
        eq(t1.S.classicAddFlow, nil, "classic add: leaving the tab ends the flow")
        t1.S.SwitchTab("effects")
        eq(t1.Last(), "list:indicator", "classic add: ...and coming back draws the list")
    end
    local t2 = Running({}, "indicator", "spell")
    if t2.ok then
        t2.S.activeBuffTab = "other"
        t2.S.SwitchTab("effects")
        eq(t2.Last(), "list:indicator", "classic add: a pool switch ends it")
    end
    local t3 = Running({}, "indicator", "spell")
    if t3.ok then
        t3.spec = 262
        t3.S.SwitchTab("effects")
        eq(t3.Last(), "list:indicator", "classic add: a spec change on My Buffs ends it")
    end
    local t4 = Running({ pool = "other" }, "indicator", "filter")
    if t4.ok then
        t4.spec = 262
        t4.S.SwitchTab("effects")
        eq(t4.Last(), "flow:indicator", "classic add: ...but not on Any Buff, which is shared across specs")
    end
    local t5 = Running({ pool = "debuffs" }, "debuff", "debuff")
    if t5.ok then
        t5.spec = 262
        t5.S.SwitchTab("layout")
        eq(t5.Last(), "flow:debuff", "classic add: ...nor on Debuffs")
    end
    local t6 = Running({}, "layout", "spell")
    if t6.ok then
        t6.GUI.SelectedMode = "raid"
        t6.S.SwitchTab("layout")
        eq(t6.Last(), "list:layout", "classic add: a party/raid switch ends it")
    end
    local t7 = Running({}, "indicator", "spell")
    if t7.ok then
        t7.enabled = false
        t7.S.SwitchTab("effects")
        eq(t7.Last(), "list:indicator", "classic add: switching the designer off ends it")
    end
    local t8 = Running({}, "indicator", "spell")
    if t8.ok then
        local rp = t8.S.rightPanel
        rp:Fire("OnHide")
        eq(t8.S.classicAddFlow, nil, "classic add: the page going away ends it")
        local n = #t8.drew
        rp:Fire("OnShow")
        eq(#t8.drew, n + 1, "classic add: ...and the next showing redraws the tab")
        eq(t8.Last(), "list:indicator", "classic add: ...as the list")
        rp:Fire("OnShow")
        eq(#t8.drew, n + 1, "classic add: ...once, not on every showing after")
    end
end
