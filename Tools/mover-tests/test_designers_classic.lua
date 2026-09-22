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
-- 5. THE CLASSIC ADD TILES (2026-09-22)
-- ------------------------------------------------------------
-- The split panel's three add areas -- the Effects tab's three scope cards
-- (Placed on the Frame / Frame-Level Effect / From a Filter) and the Layout
-- Groups / Debuffs choice-card blocks -- became PICTURE TILES on the page:
--   * Effects: Add from a Spell / Add from a Filter. A tile runs the Modern pane
--     INSIDE the tab, in place of the list, headed by "Back to Effects".
--   * Layout Groups / Debuffs: the Modern group panes mounted ON the page
--     (opts.onPage). A tile click ADDS the group -- no flow, no confirm step.
-- (ffd4031c hosted the panes in a popout beside the window; dd0c51a1 ran the
-- group panes as flows with an Add button. Both are gone.)
-- What is RUN: the tiles, the flow's start / end / re-sync, the pane hosting,
-- the page watchers, and the group panes' one-click add, against stub frames.
-- What is READ: which head area mounts which tiles, and the wiring around them.
-- ============================================================
print("-- Aura Designer: the classic add tiles")
do
    local CARDS = options_file_source("AuraDesigner/UI/Cards.lua"):gsub("\r\n", "\n")
    local EDITN = EDIT:gsub("\r\n", "\n")

    -- ---- read: the old three-option list and the card blocks are gone ----
    check(CARDS:find("local function AddFlowScopes()", 1, true) == nil,
          "classic add: the three-scope list is gone")
    check(CARDS:find('L["Placed on the Frame"]', 1, true) == nil,
          "classic add: ...no 'Placed on the Frame' option is drawn")
    check(CARDS:find('title    = L["ADD AN INDICATOR"]', 1, true) == nil,
          "classic add: ...nor the ADD AN INDICATOR card block")
    check(CARDS:find("effectsPicker", 1, true) == nil,
          "classic add: ...nor the picker column it took over")
    check(EDITN:find('L["ADD A LAYOUT GROUP"]', 1, true) == nil,
          "classic add: the Layout Groups card block is gone")
    check(EDITN:find('L["ADD A DEBUFF GROUP"]', 1, true) == nil,
          "classic add: ...and the Debuffs one")

    -- ---- read: no popout hosting, no buttons, no group flows ----
    check(CARDS:find('"df.adadd.', 1, true) == nil,
          "classic add: no keyed add popout is created any more")
    for _, name in ipairs({ "S.OpenClassicAddPopout", "S.SyncClassicAddPopouts",
                            "DockClassicAddPopout", "S.BuildClassicAddButton",
                            "S.ClassicAddButtonDefs", "BuildChosenGroupPane" }) do
        check(CARDS:find(name, 1, true) == nil and EDITN:find(name, 1, true) == nil,
              "classic add: " .. name .. " is gone")
    end
    for _, k in ipairs({ "layout", "debuff" }) do
        local call = 'S.BuildClassicAddFlow(parent, "' .. k .. '")'
        check(EDITN:find(call, 1, true) == nil,
              "classic add: the " .. k .. " tab no longer asks for a flow -- its tiles add on one click")
    end
    local en = df_file_source("Locales/enUS.lua")
    check(en:find('L["Back to Layout Groups"]', 1, true) == nil and en:find('L["Back to Debuff Groups"]', 1, true) == nil,
          "classic add: ...so their Back labels are gone from the source locale")

    -- ---- read: each classic head area mounts its tiles ----
    local head = CARDS:match("S%.BuildEffectsHeadArea = function%(parent, yPos, opts%)(.-)\nend\n") or ""
    check(head:find('yPos = S.BuildClassicAddTiles(parent, yPos, "indicator")', 1, true) ~= nil,
          "classic add: the Effects tab mounts its add tiles")
    local lg = EDITN:match("S%.BuildLayoutGroupsHeadArea = function%(parent, yPos, opts%)(.-)\nend\n") or ""
    local lgSkip = lg:find("if not skipAdd then", 1, true)
    local lgCall = lg:find('yPos = S.BuildClassicAddTiles(parent, yPos, "layout")', 1, true)
    check(lgSkip and lgCall and lgSkip < lgCall,
          "classic add: the Layout Groups tab mounts its tiles, unless the rows page asked it not to")
    local dg = EDITN:match("S%.BuildDebuffGroupsHeadArea = function%(parent, yPos, opts%)(.-)\nend\n") or ""
    local dgSkip = dg:find("if not skipAdd then", 1, true)
    local dgCall = dg:find('yPos = S.BuildClassicAddTiles(parent, yPos, "debuff")', 1, true)
    check(dgSkip and dgCall and dgSkip < dgCall,
          "classic add: the Debuffs pool's tab mounts its tile, likewise")

    -- ---- read: the PI Helper pool keeps its own add area, first ----
    local piAt  = head:find("if not skipAdd and IsPIHelperTab() and S.BuildPIHelperAddArea then", 1, true)
    local tileAt = head:find('yPos = S.BuildClassicAddTiles(parent, yPos, "indicator")', 1, true)
    check(piAt ~= nil and tileAt ~= nil and piAt < tileAt,
          "classic add: the PI Helper pool takes its own tiles, never the add tiles")
    check(CARDS:find("S.BuildPIHelperAddArea = function(parent, yPos, Refresh)", 1, true) ~= nil
          and CARDS:find("    yPos = pihBuildAddTiles(parent, yPos, Refresh)", 1, true) ~= nil,
          "classic add: ...and S.BuildPIHelperAddArea itself is untouched")

    -- ---- read: the refresh path and the Effects tab ask the flow first ----
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
        function f:GetVerticalScrollRange() return self.range or 1000 end
        function f:CreateFontString()
            local fs = { }
            function fs:SetPoint() end
            function fs:SetJustifyH() end
            function fs:SetWordWrap() end
            function fs:SetText(t) self.text = t end
            function fs:SetTextColor() end
            function fs:GetStringHeight() return 28 end
            self.fs[#self.fs + 1] = fs
            return fs
        end
        return f
    end

    -- A world: the island's state table, a content column of `width`, a stub
    -- S.SwitchTab that runs the classic arm's order -- sync, clear, then either the
    -- flow or the list (whose head area mounts the real tiles) -- stub panes that
    -- record how they were asked to build, and a stub picture tile.
    local function World(opts)
        opts = opts or {}
        local W = { enabled = opts.enabled ~= false, spec = 105, builds = {}, syncs = 0,
                    drew = {}, timers = {}, said = {}, painted = {} }
        if opts.noSpec then W.spec = nil end
        local S = { activeBuffTab = opts.pool or "my", activeTab = "effects" }
        W.S = S
        S.BuildAddIndicatorPane = function(host, o)
            W.builds[#W.builds + 1] = { kind = "indicator", opts = o, host = host }
            host:SetHeight(300)
            if o.SetHeight then o.SetHeight(300) end
            local snap = { tag = #W.builds }
            return { Sync = function() W.syncs = W.syncs + 1 end,
                     Snapshot = function() return snap end }
        end
        -- The group panes on the page: recorded, and "clicked" through the gate
        -- they are handed, exactly as their tiles do.
        local function GroupPane(kind)
            return function(host, o)
                W.builds[#W.builds + 1] = { kind = kind, opts = o, host = host }
                host:SetHeight(120)
                return 120
            end
        end
        S.BuildAddLayoutGroupPane = GroupPane("layout")
        S.BuildAddDebuffGroupPane = GroupPane("debuff")
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
        local P = {
            GroupTileMetrics = { picH = 40, gap = 6 },
            PaintGroupIconRow = function(_, colors, ghost)
                W.painted[#W.painted + 1] = { n = #colors, ghost = ghost }
            end,
        }
        local function CreateFrameTile(parent, o)
            local t = Stub(parent)
            t.tileOpts = o
            t.w = o.width
            t.layoutHeight = 68
            t.tileState = "normal"
            function t:SetTileState(s) self.tileState = s end
            if o.Paint then o.Paint({}) end
            t.Click = function(self)
                if self.tileState == "disabled" then return end
                if o.onClick then o.onClick(self) end
            end
            return t
        end
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
            -- Only the Effects tab asks for a flow now.
            if kind == "indicator" and S.BuildClassicAddFlow(c, kind) then
                W.drew[#W.drew + 1] = "flow:" .. kind
            else
                W.drew[#W.drew + 1] = "list:" .. kind
                if not (kind == "indicator" and S.activeBuffTab == "pihelper") then
                    W.tiles = {}
                    local n = #c.kids
                    S.BuildClassicAddTiles(c, -10, kind)
                    for i = n + 1, #c.kids do
                        for _, t in ipairs(c.kids[i].kids) do W.tiles[#W.tiles + 1] = t end
                    end
                    W.note = c.fs[#c.fs] and c.fs[#c.fs].text or nil
                end
            end
        end
        local env = {
            L = setmetatable({}, { __index = function(_, k) return k end }),
            S = S, GUI = GUI, P = P,
            DF = { IsAuraDesignerEnabledForMode = function() return W.enabled end,
                   Say = function(_, m) W.said[#W.said + 1] = m end },
            IsOtherTab = function() return S.activeBuffTab == "other" or S.activeBuffTab == "pihelper" end,
            IsDebuffTab = function() return S.activeBuffTab == "debuffs" end,
            IsPIHelperTab = function() return S.activeBuffTab == "pihelper" end,
            ResolveSpec = function() return W.spec end,
            GetThemeColor = function() return { r = 0.4, g = 0.5, b = 0.9 } end,
            CreateFrame = function(_, _, parent) return Stub(parent) end,
            CreateFrameTile = CreateFrameTile,
            C_Timer = { After = function(_, fn) W.timers[#W.timers + 1] = fn end },
            C_TEXT_DIM = { r = 0.5, g = 0.5, b = 0.5 },
            max = math.max, min = math.min, floor = math.floor,
        }
        setmetatable(env, { __index = _G })
        local chunk = loadstring(block)
        if chunk then setfenv(chunk, env); chunk() end
        W.ok = chunk ~= nil and S.BuildClassicAddTiles ~= nil and S.BuildClassicAddFlow ~= nil
            and S.StartClassicAddFlow ~= nil
        W.Visit = function(tab) if W.ok then S.SwitchTab(tab or S.activeTab) end end
        W.Click = function(i)
            local t = W.tiles and W.tiles[i]
            if t then t:Click() end
            return t
        end
        W.Last = function() return W.drew[#W.drew] end
        W.Back = function()
            for _, k in ipairs(S.tabContentFrame.kids) do
                if k.shown and k.styled and k.styled.ghost then return k end
            end
        end
        W.Heading = function()
            local fs = S.tabContentFrame.fs
            return fs[#fs] and fs[#fs].text
        end
        W.LastBuild = function() return W.builds[#W.builds] end
        return W
    end

    -- ---- the enabled gate ----
    local off = World({ enabled = false })
    check(off.ok, "classic add: the flow block loads headlessly")
    if off.ok then
        off.Visit("effects")
        eq(#(off.tiles or {}), 2, "classic add: the Effects tab has two add tiles")
        eq(off.tiles[1] and off.tiles[1].tileState, "disabled", "classic add: a disabled designer greys them")
        eq(off.tiles[2] and off.tiles[2].tileState, "disabled", "classic add: ...both of them")
        eq(off.S.StartClassicAddFlow("indicator", "spell"), false,
           "classic add: ...and the starter, asked directly, starts nothing")
        eq(#off.builds, 0, "classic add: ...so no pane is built")
        off.Visit("layout")
        local b = off.LastBuild()
        eq(b and b.opts.blocked, true, "classic add: a disabled designer greys the group tiles too")
        eq(b and b.opts.gate(), false, "classic add: ...and their gate refuses a click")
    end

    -- ---- indicators: two picture tiles, each entering the flow with its source ----
    local on = World({ width = 300 })
    if on.ok then
        on.Visit("effects")
        local t1, t2 = on.tiles[1], on.tiles[2]
        eq(t1 and t1.tileOpts.label, "Add from a Spell", "classic add: the first tile says Add from a Spell")
        eq(t2 and t2.tileOpts.label, "Add from a Filter", "classic add: ...the second Add from a Filter")
        eq(t1 and t1.tileState, "normal", "classic add: an enabled designer leaves them live")
        eq(t1 and t1.w, math.floor((284 - 6) / 2), "classic add: ...half the column each, the group tiles' size")
        eq(t1 and t1.tileOpts.picHeight, 40, "classic add: ...with the group tiles' 40px picture")
        eq(on.painted[1] and on.painted[1].n, 1, "classic add: a spell is drawn as ONE icon on the frame")
        eq(on.painted[2] and on.painted[2].n, 3, "classic add: ...a filter as a uniform row, the Filter Group's picture")
        check(type(t1.tileOpts.tooltip) == "table" and t1.tileOpts.tooltip.lines[1] ~= nil,
              "classic add: ...and each says what it is on hover")
        on.S.tabScrollFrame.scroll = 120
        on.Click(1)
        eq(on.Last(), "flow:indicator", "classic add: Add from a Spell replaces the Effects list with the flow")
        local bi = on.builds[1]
        eq(bi and bi.kind, "indicator", "classic add: ...built by S.BuildAddIndicatorPane")
        eq(bi and bi.opts.source, "spell", "classic add: ...with the spell route already chosen")
        eq(bi and bi.opts.fitWidth, true, "classic add: ...laid out for the tab's width")
        eq(bi and bi.opts.inline, true, "classic add: ...as the inline pane that says its states")
        eq(bi and bi.opts.width, 300 - 4, "classic add: ...which is the tab's column, less the pane's gutter")
        eq(on.S.tabScrollFrame.scroll, 0, "classic add: ...starting at the top")
        local back = on.Back()
        eq(back and back.styled.text, "Back to Effects", "classic add: the flow is headed by Back to Effects")
        eq(on.Heading(), "Add from a Spell", "classic add: ...and by the source that was chosen")

        -- The pane's height follows its sections, and the column follows it.
        local cf = on.S.tabContentFrame
        bi.opts.SetHeight(500)
        eq(cf.h, 10 + 30 + 24 + 500 + 20, "classic add: the pane reporting a new height re-sizes the tab's column")
        on.S.tabScrollFrame.scroll, on.S.tabScrollFrame.range = 400, 90
        bi.opts.SetHeight(200)
        eq(on.S.tabScrollFrame.scroll, 90, "classic add: ...and a scroll left past the new end is pulled back")
        on.S.tabScrollFrame.scroll = 0

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
        -- A pane gone stale says nothing: its height report after Back moves nothing.
        local hBefore = cf.h
        bi.opts.SetHeight(900)
        eq(cf.h, hBefore, "classic add: ...and an ended flow's pane no longer sizes the column")

        -- The filter tile.
        on.Click(2)
        local bf = on.builds[#on.builds]
        eq(bf and bf.opts.source, "filter", "classic add: Add from a Filter enters with the filter route chosen")
        eq(on.Heading(), "Add from a Filter", "classic add: ...headed by its own label")
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

    -- ---- layout groups: the pane ON the page, one click adds, no flow ----
    local lgw = World({ width = 300 })
    if lgw.ok then
        lgw.Visit("layout")
        eq(lgw.Last(), "list:layout", "classic add: the Layout Groups tab draws its list")
        local b = lgw.LastBuild()
        eq(b and b.kind, "layout", "classic add: ...with S.BuildAddLayoutGroupPane mounted on it")
        eq(b and b.opts.onPage, true, "classic add: ...on the page, not in a flow")
        eq(b and b.opts.width, 300 - 16, "classic add: ...at the tab's column")
        eq(b and b.opts.blocked, false, "classic add: ...live, with the designer on and a spec")
        eq(b and b.opts.Close, nil, "classic add: ...and no flow to close behind a click")
        eq(b and b.opts.gate(), true, "classic add: ...so a tile click goes straight through")
        eq(lgw.S.classicAddFlow, nil, "classic add: ...and nothing starts a flow")
        eq(lgw.S.StartClassicAddFlow("layout", "spell"), false,
           "classic add: a group flow cannot be started at all any more")
    end

    -- ---- debuff groups: the same, spec-independent ----
    local dgw = World({ width = 300, pool = "debuffs", noSpec = true })
    if dgw.ok then
        dgw.S.activeTab = "layout"
        dgw.Visit("layout")
        local b = dgw.LastBuild()
        eq(b and b.kind, "debuff", "classic add: the Debuffs pool mounts S.BuildAddDebuffGroupPane")
        eq(b and b.opts.onPage, true, "classic add: ...on the page")
        eq(b and b.opts.blocked, false, "classic add: ...live even with no spec -- debuff groups are shared")
        eq(b and b.opts.gate(), true, "classic add: ...and a click adds")
        eq(#dgw.said, 0, "classic add: ...without a word")
    end

    -- ---- My Buffs with no spec: every add tile greyed, and why ----
    local ns = World({ width = 300, noSpec = true })
    if ns.ok then
        ns.Visit("effects")
        eq(ns.tiles[1] and ns.tiles[1].tileState, "disabled", "classic add, no spec: the effect tiles are greyed")
        check(type(ns.note) == "string" and ns.note:find("No trackable spells found", 1, true) ~= nil,
              "classic add, no spec: ...with the reason under them")
        eq(ns.S.StartClassicAddFlow("indicator", "spell"), false, "classic add, no spec: ...and a flow is refused")
        eq(ns.said[#ns.said] and ns.said[#ns.said]:find("No trackable spells found", 1, true) ~= nil, true,
           "classic add, no spec: ...out loud")
        ns.Visit("layout")
        local b = ns.LastBuild()
        eq(b and b.opts.blocked, true, "classic add, no spec: the group tiles are greyed too")
        local n = #ns.said
        eq(b and b.opts.gate(), false, "classic add, no spec: ...and their gate refuses a click")
        eq(#ns.said, n + 1, "classic add, no spec: ...saying why")
        -- Any Buff is spec-independent: live.
        ns.S.activeBuffTab = "other"
        ns.Visit("layout")
        eq(ns.LastBuild().opts.blocked, false, "classic add, no spec: Any Buff's group tiles stay live")
    end

    -- ---- the PI Helper pool: no flow ----
    local pw = World({ pool = "pihelper" })
    if pw.ok then
        eq(pw.S.StartClassicAddFlow("indicator", "spell"), false,
           "classic add: the helper's pool refuses an indicator flow")
        eq(#pw.builds, 0, "classic add: ...and builds no pane")
    end

    -- ---- what ends a running flow ----
    local function Running(opts)
        local w = World(opts)
        if not w.ok then return w end
        w.Visit("effects")
        w.S.StartClassicAddFlow("indicator", (opts and opts.source) or "spell")
        return w
    end
    local t1 = Running({})
    if t1.ok then
        t1.S.SwitchTab("global")
        eq(t1.S.classicAddFlow, nil, "classic add: leaving the tab ends the flow")
        t1.S.SwitchTab("effects")
        eq(t1.Last(), "list:indicator", "classic add: ...and coming back draws the list")
    end
    local t2 = Running({})
    if t2.ok then
        t2.S.activeBuffTab = "other"
        t2.S.SwitchTab("effects")
        eq(t2.Last(), "list:indicator", "classic add: a pool switch ends it")
    end
    local t3 = Running({})
    if t3.ok then
        t3.spec = 262
        t3.S.SwitchTab("effects")
        eq(t3.Last(), "list:indicator", "classic add: a spec change on My Buffs ends it")
    end
    local t4 = Running({ pool = "other", source = "filter" })
    if t4.ok then
        t4.spec = 262
        t4.S.SwitchTab("effects")
        eq(t4.Last(), "flow:indicator", "classic add: ...but not on Any Buff, which is shared across specs")
    end
    local t6 = Running({})
    if t6.ok then
        t6.GUI.SelectedMode = "raid"
        t6.S.SwitchTab("effects")
        eq(t6.Last(), "list:indicator", "classic add: a party/raid switch ends it")
    end
    local t7 = Running({})
    if t7.ok then
        t7.enabled = false
        t7.S.SwitchTab("effects")
        eq(t7.Last(), "list:indicator", "classic add: switching the designer off ends it")
    end
    local t8 = Running({})
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

-- ============================================================
-- 6. THE GROUP PANES ON THE PAGE: ONE CLICK ADDS (2026-09-22)
-- ------------------------------------------------------------
-- The REAL S.BuildAddLayoutGroupPane / S.BuildAddDebuffGroupPane, and the real
-- add verbs behind their tiles, cut out of Editor.lua and run against stubs:
-- a click on a tile creates the group, expands it and rebuilds the tab -- no
-- intermediate step -- and a refused create (My Buffs, no spec) changes nothing.
-- ============================================================
print("-- Aura Designer: the group panes on the page add on one click")
do
    local EDITN = EDIT:gsub("\r\n", "\n")
    local pieces = {}
    for _, start in ipairs({ "local function AddGroupOfKind(kind)", "local function LayoutGroupCards()",
                             "local function BuildFilterFooter(host, y, W)",
                             "S.BuildAddLayoutGroupPane = function(host, opts)",
                             "local function AddDebuffGroup()", "local function DebuffGroupCards()",
                             "S.BuildAddDebuffGroupPane = function(host, opts)" }) do
        local body = cut(EDITN, start)
        check(body ~= nil, "group panes: " .. start .. " can be cut out of Editor.lua")
        pieces[#pieces + 1] = body or ""
    end
    local src = table.concat(pieces, "\n")

    local function Stub(parent)
        local f = { kids = {}, points = {}, h = 0, w = 0, parent = parent }
        if parent and parent.kids then parent.kids[#parent.kids + 1] = f end
        function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function f:SetSize(w, h) self.w, self.h = w, h end
        function f:SetHeight(h) self.h = h end
        function f:GetHeight() return self.h end
        function f:SetScript(k, fn) self[k] = fn end
        function f:HookScript() end
        function f:CreateTexture()
            local t = {}
            function t:SetColorTexture() end
            function t:SetHeight() end
            function t:SetPoint() end
            return t
        end
        return f
    end

    local function Run(opts)
        local R = { created = {}, switched = {}, headings = 0, tiles = {}, buttons = {} }
        if not opts.refuse then R.nextGroup = { id = 7 } end
        local S = { SwitchTab = function(k) R.switched[#R.switched + 1] = k end }
        local env = {
            L = setmetatable({}, { __index = function(_, k) return k end }),
            S = S, DF = { InvalidateAuraLayout = function() end, UpdateAllFrames = function() end,
                          AuraDesigner = {} },
            GUI = { StyleButton = function(_, btn, o) btn.label = o.text; R.buttons[#R.buttons + 1] = btn end },
            CreateFrame = function(_, _, parent) return Stub(parent) end,
            CreateFrameTile = function(parent, o)
                local t = Stub(parent)
                t.o, t.state = o, "normal"
                t.layoutHeight = 68
                function t:SetTileState(s) self.state = s end
                t.Click = function(self)
                    if self.state == "disabled" then return end
                    o.onClick(self)
                end
                R.tiles[#R.tiles + 1] = t
                return t
            end,
            CreateNumberedHeading = function() R.headings = R.headings + 1 end,
            PaintIconRowOnThumb = function() end,
            CreateLayoutGroup = function(_, kind)
                R.created[#R.created + 1] = kind or "spell"
                return R.nextGroup
            end,
            CreateDebuffGroup = function()
                R.created[#R.created + 1] = "debuff"
                return R.nextGroup
            end,
            expandedGroups = {},
            GroupExpandKey = function(id) return "group:" .. id end,
            RefreshPlacedIndicators = function() end,
            JumpToNewFilter = function() end,
            GROUP_TILE_PIC_H = 40, GROUP_TILE_GAP = 6,
            floor = math.floor, max = math.max, min = math.min,
        }
        R.env = env
        setmetatable(env, { __index = _G })
        local chunk = loadstring(src)
        if chunk then setfenv(chunk, env); chunk() end
        R.ok = chunk ~= nil and S.BuildAddLayoutGroupPane ~= nil and S.BuildAddDebuffGroupPane ~= nil
        if R.ok then
            local host = Stub()
            local Build = (opts.kind == "debuff") and S.BuildAddDebuffGroupPane or S.BuildAddLayoutGroupPane
            R.h = Build(host, { width = 284, onPage = opts.onPage, blocked = opts.blocked,
                                gate = opts.gate })
        end
        return R
    end

    local lg = Run({ onPage = true, gate = function() return true end })
    check(lg.ok, "group panes: they load headlessly")
    if lg.ok then
        eq(lg.headings, 0, "group panes, on the page: no numbered question over the tiles")
        eq(#lg.tiles, 2, "group panes, on the page: Spell Group and Filter Group")
        eq(lg.tiles[1] and lg.tiles[1].o.label, "Spell Group", "group panes, on the page: ...Spell Group first")
        local labels = {}
        for _, b in ipairs(lg.buttons) do labels[#labels + 1] = b.label end
        eq(table.concat(labels, ","), "Create Filter,Manage Filters",
           "group panes, on the page: ...with Create Filter / Manage Filters under them")
        lg.tiles[2]:Click()
        eq(lg.created[1], "filter", "group panes: ONE click on Filter Group creates a filter group")
        eq(lg.env.expandedGroups["group:7"], true, "group panes: ...expanded")
        eq(lg.switched[1], "layout", "group panes: ...and the tab rebuilt to show it")
        eq(#lg.buttons, 2, "group panes: ...with no Add button to press first")
    end

    local blocked = Run({ onPage = true, blocked = true, gate = function() return false end })
    if blocked.ok then
        eq(blocked.tiles[1] and blocked.tiles[1].state, "disabled", "group panes, blocked: the tiles are greyed")
        blocked.tiles[1].state = "normal"   -- even a stale live tile goes through the gate
        blocked.tiles[1]:Click()
        eq(#blocked.created, 0, "group panes, blocked: ...and the gate stops a click before anything is made")
    end

    local refused = Run({ onPage = true, refuse = true, gate = function() return true end })
    if refused.ok then
        refused.tiles[1]:Click()
        eq(refused.created[1], "spell", "group panes: a create the store refuses is still asked for")
        eq(#refused.switched, 0, "group panes: ...but nothing is expanded or rebuilt on a refusal")
    end

    local rows = Run({ gate = nil })
    if rows.ok then
        eq(rows.headings, 1, "group panes, rows page: the numbered question is still asked there")
        eq(rows.tiles[1] and rows.tiles[1].state, "normal", "group panes, rows page: ...and the tiles are live")
    end

    local dg = Run({ kind = "debuff", onPage = true, gate = function() return true end })
    if dg.ok then
        eq(#dg.tiles, 1, "debuff pane, on the page: one tile")
        eq(dg.tiles[1] and dg.tiles[1].o.width, math.floor((284 - 6) / 2),
           "debuff pane, on the page: ...half the column, the Layout Groups tiles' size")
        eq(dg.headings, 0, "debuff pane, on the page: ...no numbered question")
        dg.tiles[1]:Click()
        eq(dg.created[1], "debuff", "debuff pane: ONE click creates a debuff group")
        eq(dg.env.expandedGroups["dgroup:7"], true, "debuff pane: ...expanded")
        eq(dg.switched[1], "layout", "debuff pane: ...and the tab rebuilt to show it")
    end
end

-- ============================================================
-- 7. A MY BUFFS WRITE WITH NO SPEC IS REFUSED, OUT LOUD (2026-09-22)
-- ------------------------------------------------------------
-- With no spec resolved, GetSpecAuras / GetSpecLayoutGroups hand back a FRESH
-- EMPTY TABLE on every call. A read of it is right; a write into it was lost
-- without a word. Every path that CREATES on My Buffs now asks
-- P.RefuseNoSpecWrite first. The real functions are cut out of Options.lua,
-- Groups.lua and Cards.lua and run against a stub store: with no spec nothing
-- is written and the reason is said; with a spec, or on Any Buff, the write
-- lands exactly as before.
-- ============================================================
print("-- Aura Designer: a My Buffs write with no spec is refused, out loud")
do
    local OPT = options_file_source("AuraDesigner/UI/Options.lua")
    local GRP = options_file_source("AuraDesigner/UI/Groups.lua")
    local CRD = options_file_source("AuraDesigner/UI/Cards.lua")
    local pieces = {}
    for _, spec in ipairs({
        { OPT, "P.RefuseNoSpecWrite = function(quiet)" },
        { OPT, "local function CurrentAuraPoolWrite()" },
        { OPT, "local function EnsureAuraConfig(auraName, pool)" },
        { GRP, "local function CreateIndicatorInstance(auraName, typeKey)" },
        { GRP, "local function CreateLayoutGroup(name, kind)" },
        { GRP, "local function CreateProxy(auraName, typeKey)" },
        { GRP, "local function CreateAuraProxy(auraName)" },
        { CRD, "local function AddPickedSpell(auraName, typeKey, mode, anchor)" },
    }) do
        local body = cut(spec[1], spec[2])
        check(body ~= nil, "no spec: " .. spec[2] .. " can be cut out")
        -- The cut functions become globals of one chunk, so each finds the others.
        -- Only the head line: a nested `local function` stays local.
        pieces[#pieces + 1] = (body or ""):gsub("^local function ", "function ")
    end
    local src = table.concat(pieces, "\n")
    src = src .. "\nreturn { CurrentAuraPoolWrite = CurrentAuraPoolWrite, EnsureAuraConfig = EnsureAuraConfig,"
              .. " CreateIndicatorInstance = CreateIndicatorInstance, CreateLayoutGroup = CreateLayoutGroup,"
              .. " CreateProxy = CreateProxy, CreateAuraProxy = CreateAuraProxy, AddPickedSpell = AddPickedSpell }"

    local function World(tab, spec)
        local W = { said = {}, warned = 0, fresh = 0, tab = tab, spec = spec,
                    adDB = { auras = {}, layoutGroups = {}, otherAuras = {}, otherLayoutGroups = {} } }
        local S = { activeBuffTab = tab }
        local P = {}
        local function GetSpecAuras()
            if not W.spec then W.fresh = W.fresh + 1 return {} end
            W.adDB.auras[W.spec] = W.adDB.auras[W.spec] or {}
            return W.adDB.auras[W.spec]
        end
        local function GetSpecLayoutGroups()
            if not W.spec then W.fresh = W.fresh + 1 return {} end
            W.adDB.layoutGroups[W.spec] = W.adDB.layoutGroups[W.spec] or {}
            return W.adDB.layoutGroups[W.spec]
        end
        local env = {
            L = setmetatable({}, { __index = function(_, k) return k end }),
            S = S, P = P,
            DF = { Say = function(_, m) W.said[#W.said + 1] = m end,
                   DebugWarn = function() W.warned = W.warned + 1 end,
                   InvalidateAuraLayout = function() end, UpdateAllFrames = function() end,
                   AuraDesigner = {} },
            GetTime = function() W.now = (W.now or 0) + 1 return W.now end,
            IsOtherTab = function() return S.activeBuffTab == "other" or S.activeBuffTab == "pihelper" end,
            ResolveSpec = function() return W.spec end,
            GetAuraDesignerDB = function() return W.adDB end,
            GetSpecAuras = GetSpecAuras,
            GetOtherAuras = function() return W.adDB.otherAuras end,
            GetSpecLayoutGroups = GetSpecLayoutGroups,
            GetOtherLayoutGroups = function() return W.adDB.otherLayoutGroups end,
            NewLayoutGroupRecord = function(id, name, kind) return { id = id, name = name, kind = kind } end,
            NextGroupName = function(_, prefix) return prefix .. " 1" end,
            -- A stub over the REAL EnsureAuraConfig (cut above).
            EnsureTypeConfig = function(auraName, typeKey, pool)
                local cfg = W.fns.EnsureAuraConfig(auraName, pool)
                cfg[typeKey] = cfg[typeKey] or {}
                return cfg[typeKey]
            end,
            TYPE_DEFAULTS = { icon = { anchor = "TOPLEFT", color = { r = 1 } }, border = { color = { r = 1 } } },
            ANCHOR_POSITIONS = { TOPLEFT = true, CENTER = true },
            expandedCards = {},
            PoolKeyPrefix = function() return (S.activeBuffTab == "other") and "other:" or "" end,
            RefreshLiveFramesThrottled = function() end,
            tinsert = table.insert,
        }
        setmetatable(env, { __index = _G })
        local chunk = loadstring(src)
        if not chunk then return nil end
        setfenv(chunk, env)
        W.fns, W.P, W.env = chunk(), P, env
        return W
    end
    local function SaidNoSpec(W)
        local m = W.said[#W.said]
        return (m and m:find("No trackable spells found for this spec.", 1, true)) and true or false
    end

    -- ---- My Buffs, no spec: every creator refuses and says why ----
    local W = World("my", nil)
    check(W ~= nil, "no spec: the cut functions load together")
    if W then
        local f = W.fns
        eq(W.P.RefuseNoSpecWrite(), true, "no spec: My Buffs with no spec refuses a write")
        check(SaidNoSpec(W), "no spec: ...and says the no-trackable-spells line")
        local n = #W.said
        eq(W.P.RefuseNoSpecWrite(true), true, "no spec: the quiet form refuses too")
        eq(#W.said, n, "no spec: ...without a chat line, for a caller that says it its own way")

        W.said = {}
        eq(f.CreateIndicatorInstance("Rejuvenation", "icon"), nil, "no spec: CreateIndicatorInstance makes nothing")
        check(SaidNoSpec(W), "no spec: ...and says so")
        eq(W.fresh, 0, "no spec: ...without ever reaching the throwaway table")

        W.said = {}
        eq(f.CreateLayoutGroup(nil, "filter"), nil, "no spec: CreateLayoutGroup makes nothing")
        eq(W.adDB.nextLayoutGroupID, nil, "no spec: ...and does not move the id counter")
        check(SaidNoSpec(W), "no spec: ...and says so")

        W.said = {}
        eq(f.AddPickedSpell("Rejuvenation", "border", "frame"), false,
           "no spec: AddPickedSpell answers false, so the add pane stays open")
        check(SaidNoSpec(W), "no spec: ...and says why")
        eq(next(W.env.expandedCards), nil, "no spec: ...expanding no card for an effect that was never made")

        W.said = {}
        local rec = f.EnsureAuraConfig("Rejuvenation")
        check(type(rec) == "table", "no spec: the backstop still hands back a table, never a Lua error")
        check(SaidNoSpec(W), "no spec: ...but the write it would have been is said, not silent")

        W.said = {}
        local proxy = f.CreateProxy("Rejuvenation", "border")
        proxy.alpha = 0.5
        check(SaidNoSpec(W), "no spec: a type proxy's write is refused out loud")
        eq(W.fresh, 0, "no spec: ...before it touches the throwaway table")
        local c = proxy.color
        eq(c and c.r, 1, "no spec: a proxy READ still answers the default")
        eq(W.fresh, 1, "no spec: ...(reads are unchanged: the store is read as before)")
        local aura = f.CreateAuraProxy("Rejuvenation")
        W.said = {}
        aura.priority = 3
        check(SaidNoSpec(W), "no spec: an aura proxy's write is refused out loud")
    end

    -- ---- My Buffs with a spec: every write lands, and nothing is said ----
    local Y = World("my", 105)
    if Y then
        local f = Y.fns
        eq(Y.P.RefuseNoSpecWrite(), false, "with a spec: nothing is refused")
        local inst = f.CreateIndicatorInstance("Rejuvenation", "icon")
        check(inst ~= nil and Y.adDB.auras[105].Rejuvenation.indicators[1] == inst,
              "with a spec: CreateIndicatorInstance writes into the spec's own store")
        local g = f.CreateLayoutGroup(nil, "filter")
        check(g ~= nil and Y.adDB.layoutGroups[105][1] == g, "with a spec: CreateLayoutGroup does too")
        eq(f.AddPickedSpell("Lifebloom", "border", "frame"), true, "with a spec: AddPickedSpell answers true")
        check(Y.adDB.auras[105].Lifebloom and Y.adDB.auras[105].Lifebloom.border ~= nil,
              "with a spec: ...and the effect is in the store")
        local proxy = f.CreateProxy("Lifebloom", "border")
        proxy.alpha = 0.5
        eq(Y.adDB.auras[105].Lifebloom.border.alpha, 0.5, "with a spec: a proxy write lands")
        eq(#Y.said, 0, "with a spec: ...and nothing is said")
    end

    -- ---- Any Buff with no spec: spec-independent, never refused ----
    local O = World("other", nil)
    if O then
        local f = O.fns
        eq(O.P.RefuseNoSpecWrite(), false, "Any Buff: no spec is no reason to refuse")
        local inst = f.CreateIndicatorInstance("Rejuvenation", "icon")
        check(inst ~= nil and O.adDB.otherAuras.Rejuvenation ~= nil, "Any Buff: the write lands in the shared pool")
        check(f.CreateLayoutGroup(nil, "filter") ~= nil, "Any Buff: ...and so does a layout group")
        eq(#O.said, 0, "Any Buff: ...without a word")
    end

    -- ---- read: add-by-ID echoes the refusal where the user is looking ----
    local byID = cut(CRD, "local function ADAddByID(idNum, idText, picker, mode, typeKey, groupID)") or ""
    local gAt = byID:find("if P.RefuseNoSpecWrite and P.RefuseNoSpecWrite(true) then", 1, true)
    local eAt = byID:find('picker:Echo(L["No trackable spells found for this spec.', 1, true)
    local addAt = byID:find("AddPickedSpell(auraName, typeKey, mode)", 1, true)
    check(gAt and eAt and addAt and gAt < eAt and eAt < addAt,
          "no spec: add-by-ID refuses in the picker's echo, before anything is minted")
    -- ...and the add pane does not close on an add the store refused.
    check(CRD:find("if ok == false then return false end", 1, true) ~= nil,
          "no spec: the add pane keeps itself open when the add is refused")
end
