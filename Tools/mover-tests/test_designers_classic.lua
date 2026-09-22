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
-- 5. THE CLASSIC ADD FLOWS ARE THE MODERN ONES (2026-09-22)
-- ------------------------------------------------------------
-- The split panel's three add areas -- the Effects tab's three scope cards
-- (Placed on the Frame / Frame-Level Effect / From a Filter) and the Layout
-- Groups / Debuffs choice-card blocks -- became one button per tab, each opening
-- the Modern pane in a popout beside the window. What is RUN: the button, the
-- popout opener, its enabled gate, its re-sync on open and its closes, against
-- stub frames. What is READ: which head area mounts which button.
-- ============================================================
print("-- Aura Designer: the classic add buttons open the Modern panes")
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

    -- ---- read: each classic head area mounts its button ----
    local head = CARDS:match("S%.BuildEffectsHeadArea = function%(parent, yPos, opts%)(.-)\nend\n") or ""
    check(head:find('yPos = S.BuildClassicAddButton(parent, yPos, "indicator")', 1, true) ~= nil,
          "classic add: the Effects tab mounts the Add Indicator button")
    local lg = EDITN:match("S%.BuildLayoutGroupsHeadArea = function%(parent, yPos, opts%)(.-)\nend\n") or ""
    check(lg:find('    if not skipAdd then\n        yPos = S.BuildClassicAddButton(parent, yPos, "layout")', 1, true) ~= nil,
          "classic add: the Layout Groups tab mounts Add Layout Group, unless the rows page asked it not to")
    local dg = EDITN:match("S%.BuildDebuffGroupsHeadArea = function%(parent, yPos, opts%)(.-)\nend\n") or ""
    check(dg:find('    if not skipAdd then\n        yPos = S.BuildClassicAddButton(parent, yPos, "debuff")', 1, true) ~= nil,
          "classic add: the Debuffs pool's tab mounts Add Debuff Group, likewise")

    -- ---- read: the PI Helper pool keeps its own add area, first ----
    local piAt  = head:find("if not skipAdd and IsPIHelperTab() and S.BuildPIHelperAddArea then", 1, true)
    local btnAt = head:find('    elseif not skipAdd then\n        yPos = S.BuildClassicAddButton(parent, yPos, "indicator")', 1, true)
    check(piAt ~= nil and btnAt ~= nil and piAt < btnAt,
          "classic add: the PI Helper pool takes its own tiles, never the Add Indicator button")
    check(CARDS:find("S.BuildPIHelperAddArea = function(parent, yPos, Refresh)\n    yPos = pihBuildAddTiles(parent, yPos, Refresh)\n    return pihBuildSoundBox(parent, yPos, Refresh)\nend", 1, true) ~= nil,
          "classic add: ...and S.BuildPIHelperAddArea itself is untouched")

    -- ---- read: the island's refresh path re-checks open panels ----
    local sw = CARDS:match("S%.SwitchTab = function%(tabKey%)(.-)\nend\n") or ""
    check(sw:find("if S.SyncClassicAddPopouts then S.SyncClassicAddPopouts() end", 1, true) ~= nil,
          "classic add: S.SwitchTab re-checks every open add panel")

    -- ---- run: the block itself, against stubs ----
    local s0 = CARDS:find("local CLASSIC_ADD_ICON = ", 1, true)
    local s1 = CARDS:find("-- ☠ EXTRACTED, NOT COPIED. The popout layout's row page", s0 or 1, true)
    check(s0 ~= nil and s1 ~= nil, "classic add: the add-button block can be cut out of Cards.lua")
    local block = (s0 and s1) and CARDS:sub(s0, s1 - 1) or ""

    local function Stub()
        local f = { scripts = {}, hooks = {}, points = {}, shown = true, h = 0 }
        function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function f:SetWidth(w) self.w = w end
        function f:SetHeight(h) self.h = h end
        function f:GetHeight() return self.h end
        function f:SetScript(k, fn) self.scripts[k] = fn end
        function f:HookScript(k, fn) self.hooks[k] = fn end
        function f:SetDisabled(v) self.dfDisabled = v end
        function f:IsVisible() return self.shown end
        function f:IsShown() return self.shown end
        return f
    end

    local function World(enabled)
        local W = { enabled = enabled, built = {}, popouts = {}, syncs = 0, spec = 105, frames = {} }
        local S = { activeBuffTab = "my" }
        W.S = S
        local function NewPopout(opts)
            local po = { opts = opts, closed = false, shown = false, content = Stub() }
            function po:Follow(region) self.source = region; self.shown = true; W.followed = region end
            function po:IsShown() return self.shown end
            function po:Close(reason) self.closed = true; self.shown = false; self.closeReason = reason end
            return po
        end
        local GUI = {
            SelectedMode = "party",
            PopoutContentWidth = 260,
            StyleButton = function(_, btn, o) btn.styled = o end,
            -- The kit's pool: an unpinned instance is handed back, build untouched.
            CreatePopout = function(_, opts)
                local po = W.popouts[opts.key]
                if po and not po.pinned then po.closed = false; return po end
                po = NewPopout(opts)
                W.popouts[opts.key] = po
                opts.build(po, po.content)
                return po
            end,
        }
        S.BuildAddIndicatorPane = function(host, o)
            W.built[#W.built + 1] = "indicator"
            W.paneOpts = o
            host:SetHeight(480); if o.SetHeight then o.SetHeight(480) end
            return { Sync = function() W.syncs = W.syncs + 1 end }
        end
        S.BuildAddLayoutGroupPane = function(host, o)
            W.built[#W.built + 1] = "layout"
            host:SetHeight(120); if o.SetHeight then o.SetHeight(120) end
        end
        S.BuildAddDebuffGroupPane = function(host, o)
            W.built[#W.built + 1] = "debuff"
            host:SetHeight(90); if o.SetHeight then o.SetHeight(90) end
        end
        local env = {
            L = setmetatable({}, { __index = function(_, k) return k end }),
            S = S, GUI = GUI,
            DF = {
                GUIFrame = Stub(),
                IsAuraDesignerEnabledForMode = function() return W.enabled end,
            },
            IsOtherTab = function() return S.activeBuffTab == "other" end,
            IsDebuffTab = function() return S.activeBuffTab == "debuffs" end,
            ResolveSpec = function() return W.spec end,
            CreateFrame = function() local f = Stub(); W.frames[#W.frames + 1] = f; return f end,
            C_Timer = { After = function(_, fn) W.deferred = fn end },
            max = math.max,
        }
        setmetatable(env, { __index = _G })
        local chunk = loadstring(block)
        if chunk then setfenv(chunk, env); chunk() end
        W.ok = chunk ~= nil and S.BuildClassicAddButton ~= nil and S.OpenClassicAddPopout ~= nil
        -- One tab's button, built through the real builder; returns it.
        W.Button = function(kind)
            S.rightPanel = S.rightPanel or Stub()
            S.tabScrollFrame = S.tabScrollFrame or Stub()
            local n = #W.frames
            local y = S.BuildClassicAddButton(Stub(), -10, kind)
            return W.frames[n + 1], y
        end
        return W
    end

    -- ---- the enabled gate ----
    local off = World(false)
    check(off.ok, "classic add: the block loads headlessly")
    if off.ok then
        local btn, y = off.Button("indicator")
        check(type(y) == "number" and y < -10, "classic add: the button reports the y below it")
        eq(btn and btn.dfDisabled, true, "classic add: a disabled designer greys the button")
        if btn and btn.scripts.OnClick then btn.scripts.OnClick(btn) end
        eq(#off.built, 0, "classic add: ...and a click on it opens nothing")
        off.S.OpenClassicAddPopout("indicator", Stub())
        eq(#off.built, 0, "classic add: ...nor does the opener, asked directly")
    end

    -- ---- each kind hosts its own Modern pane, once, and re-syncs ----
    local on = World(true)
    if on.ok then
        local btn = on.Button("indicator")
        eq(btn and btn.dfDisabled, nil, "classic add: an enabled designer leaves the button live")
        if btn and btn.scripts.OnClick then btn.scripts.OnClick(btn) end
        eq(on.built[1], "indicator", "classic add: Add Indicator hosts S.BuildAddIndicatorPane")
        eq(on.followed, btn, "classic add: ...docked beside its button")
        eq(on.syncs, 1, "classic add: ...and Synced on open")
        eq(on.paneOpts and on.paneOpts.width, 260, "classic add: ...at the popout's content width")
        local po = on.popouts["df.adadd.indicator"]
        eq(po and po.content.h, 480, "classic add: ...and the panel takes the height the pane reported")
        btn.scripts.OnClick(btn)
        eq(po and po.closed, true, "classic add: a second click shuts it")
        btn.scripts.OnClick(btn)
        eq(#on.built, 1, "classic add: reopening reuses the pooled pane")
        eq(on.syncs, 2, "classic add: ...and re-syncs it, because a pooled pane is stale")
        if on.paneOpts and on.paneOpts.Close then on.paneOpts.Close() end
        eq(po and po.closed, true, "classic add: the pane's Close shuts the panel")

        local lb = on.Button("layout")
        eq(lb and lb.styled and lb.styled.text, "Add Layout Group", "classic add: the layout button says Add Layout Group")
        lb.scripts.OnClick(lb)
        eq(on.built[2], "layout", "classic add: ...and hosts S.BuildAddLayoutGroupPane")
        local db = on.Button("debuff")
        eq(db and db.styled and db.styled.text, "Add Debuff Group", "classic add: the debuff button says Add Debuff Group")
        db.scripts.OnClick(db)
        eq(on.built[3], "debuff", "classic add: ...and hosts S.BuildAddDebuffGroupPane")
    end

    -- ---- a tab rebuild re-docks an open panel onto the new button ----
    local rb = World(true)
    if rb.ok then
        local b1 = rb.Button("indicator")
        b1.scripts.OnClick(b1)
        local before = rb.syncs
        local b2 = rb.Button("indicator")
        local po = rb.popouts["df.adadd.indicator"]
        check(po and not po.closed and po.source == b2, "classic add: a tab rebuild re-docks the open panel")
        eq(rb.syncs, before + 1, "classic add: ...and re-syncs it")
        -- ...so the OLD button's hide, judged a frame later, leaves it alone.
        b1.shown = false
        if b1.hooks.OnHide then b1.hooks.OnHide(b1) end
        if rb.deferred then rb.deferred() end
        eq(po.closed, false, "classic add: ...and the retired button's hide does not close it")
    end

    -- ---- the button's hide ----
    local hd = World(true)
    if hd.ok then
        local b = hd.Button("indicator")
        b.scripts.OnClick(b)
        local po = hd.popouts["df.adadd.indicator"]
        -- The spell / filter overlay hides the tab's scroll frame: keep the panel.
        hd.S.tabScrollFrame.shown = false
        b.shown = false
        b.hooks.OnHide(b); hd.deferred()
        eq(po.closed, false, "classic add: the spell overlay covering the tab keeps the panel")
        -- A tab switch (scroll frame up, button gone): an unpinned panel goes.
        hd.S.tabScrollFrame.shown = true
        b.hooks.OnHide(b); hd.deferred()
        eq(po.closed, true, "classic add: a tab switch closes an unpinned panel")
        -- ...a pinned one stays.
        local b2 = hd.Button("indicator")
        b2.scripts.OnClick(b2)
        local po2 = hd.popouts["df.adadd.indicator"]
        po2.pinned = true
        b2.shown = false
        b2.hooks.OnHide(b2); hd.deferred()
        eq(po2.closed, false, "classic add: ...a pinned one survives the tab switch")
        -- The designer page going away takes every add panel, pinned or not.
        local rpHide = hd.S.rightPanel.hooks.OnHide
        check(rpHide ~= nil, "classic add: the right panel's hide is watched")
        if rpHide then rpHide() end
        eq(po2.closed, true, "classic add: ...and the page going away closes it, pinned or not")
    end

    -- ---- stale context: pool, spec, the designer switched off ----
    local st = World(true)
    if st.ok then
        local b = st.Button("indicator"); b.scripts.OnClick(b)
        local po = st.popouts["df.adadd.indicator"]
        po.pinned = true
        st.S.SyncClassicAddPopouts()
        eq(po.closed, false, "classic add: a matching context keeps the panel")
        st.S.activeBuffTab = "other"
        st.S.SyncClassicAddPopouts()
        eq(po.closed, true, "classic add: a pool switch closes it, even pinned")
    end
    local st2 = World(true)
    if st2.ok then
        local b = st2.Button("layout"); b.scripts.OnClick(b)
        local po = st2.popouts["df.adadd.layout"]
        st2.enabled = false
        st2.S.SyncClassicAddPopouts()
        eq(po.closed, true, "classic add: switching the designer off closes it")
    end
    local st3 = World(true)
    if st3.ok then
        local b = st3.Button("indicator"); b.scripts.OnClick(b)
        local po = st3.popouts["df.adadd.indicator"]
        st3.spec = 262
        st3.S.SyncClassicAddPopouts()
        eq(po.closed, true, "classic add: a spec change on My Buffs closes it")
    end
    local st4 = World(true)
    if st4.ok then
        st4.S.activeBuffTab = "other"
        local b = st4.Button("indicator"); b.scripts.OnClick(b)
        local po = st4.popouts["df.adadd.indicator"]
        st4.spec = 262
        st4.S.SyncClassicAddPopouts()
        eq(po.closed, false, "classic add: ...but not on Any Buff, which is shared across specs")
    end
    local st5 = World(true)
    if st5.ok then
        st5.S.activeBuffTab = "debuffs"
        local b = st5.Button("debuff"); b.scripts.OnClick(b)
        local po = st5.popouts["df.adadd.debuff"]
        st5.spec = 262
        st5.S.SyncClassicAddPopouts()
        eq(po.closed, false, "classic add: ...nor on Debuffs")
    end
end
