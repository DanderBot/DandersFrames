-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`).
-- No `local L` here, deliberately: every user-facing string on this page belongs
-- to the DESIGNER, not to the shell -- the labels arrive in opts.tabs, and a
-- shell that owned any of its own text would be a shell with an opinion about
-- which designer it was drawing.
local DF = DandersFrames
local GUI = DF.GUI

local max, floor = math.max, math.floor

-- ============================================================
-- THE DESIGNER SHELL
-- ------------------------------------------------------------
-- The Aura Designer and the Text Designer were the last two pages built as
-- 50/50 SPLIT PANELS: a frame preview welded to the left half, a three-tab
-- settings column welded to the right, the whole thing hand-anchored inside one
-- frame the page harness never sees. That is why they were islands -- they never
-- entered the column system, so BandWidth, the scroll flow, page parking and the
-- settings-search registry all passed them by -- and why both had to force the
-- window 210px wider than its own default.
--
-- This is the shape that replaces both: a single column of full-width bands,
-- top to bottom,
--
--     [ enable banner        ]
--     [ frame canvas         ]   ONE shared canvas, not one per row
--     [ strip(s)             ]   AD's pool tabs; the Text Designer has none
--     [ tab strip            ]
--     [ ...the active tab    ]   built by the caller, into the same column
--
-- each constructed at tools.BandWidth() and added "both", so the page has
-- exactly one left edge and one right edge -- the all-rows rule.
--
-- ☠ NOTHING IN HERE KNOWS WHAT AN AURA IS. The canvas, the strips and the tab
-- list all arrive as parameters, because the Text Designer is the second caller
-- and it has a different canvas, no strips and different tabs. A shell that
-- reached for DF.AuraDesigner would have to be forked for it, which is the thing
-- this file exists to prevent. The one AD-shaped assumption left is the ORDER of
-- the five bands, which is the design rather than an accident of the first
-- caller.
--
-- ⚠ NO COMBAT GUARD HERE, and that is a decision rather than an omission. The
-- addon's rule is that PROTECTED-frame work is deferred in combat; nothing this
-- file builds is protected, and the canvas it hosts sizes a mock frame of its own
-- (AuraDesigner/UI/Cards.lua's CreateFramePreview) and never touches a real one.
-- A guard here would blank the settings page in combat and protect nothing.
-- ============================================================

local BANNER_H = 68
local TABBAR_H = 28
local TAB_GAP  = 4

-- opts:
--   tools        REQUIRED  the page's GUI:CreatePopoutPageTools(page) table
--   Add          REQUIRED  BuildPage's own Add(widget, height, col)
--   AddSpace               BuildPage's AddSpace, for gaps between bands
--   banner       fn(parent, shell) -> widget[, height]   omit for no banner
--   canvas       fn(host, shell)   -> canvas frame       omit for no canvas
--   canvasHeight default 132 (the artifact's figure; see Cards.lua's `compact`)
--   strips       { { height = n, build = fn(host, shell) }, ... }
--   tabs         { { key=, label=, accent=, tooltip=, disabled=fn->bool }, ... }
--   activeTab    the key that is showing
--   onTab        fn(key)  -- what a tab click does; normally page:Refresh()
--   buildTab     fn(key, shell)  -- adds the active tab's own bands
--
-- Returns the shell: { page, tools, Add, AddSpace, Band, bandWidth, activeTab,
--                      banner, canvas, canvasHost, tabBar, tabButtons }
function GUI:BuildDesignerShell(page, opts)
    opts = opts or {}
    local tools, Add = opts.tools, opts.Add
    if not (page and tools and Add) then
        DF:DebugWarn("BuildDesignerShell: needs a page, the popout tools and Add")
        return nil
    end

    local bandW = tools.BandWidth()
    local shell = {
        page       = page,
        tools      = tools,
        Add        = Add,
        AddSpace   = opts.AddSpace,
        bandWidth  = bandW,
        activeTab  = opts.activeTab,
        tabButtons = {},
    }

    -- A band host: a plain frame at the band's width, which the layout pass then
    -- stretches to the page's usable width like any other "both" widget. Used for
    -- everything on this page that is NOT a settings group -- the canvas, the
    -- strips, the tab bar -- so all of them share the bands' two edges.
    local function Band(h)
        local f = CreateFrame("Frame", nil, page.child)
        f:SetSize(bandW, h)
        return f
    end
    shell.Band = Band

    -- ── 1. THE ENABLE BANNER ──
    if opts.banner then
        local w, h = opts.banner(page.child, shell)
        if w then
            shell.banner = w
            Add(w, h or BANNER_H, "both")
        end
    end

    -- ── 2. THE CANVAS ──
    -- ONE canvas for the whole page, at the top, rather than one per row: a row
    -- is a list entry and the canvas is a picture of the WHOLE frame, so twenty
    -- rows would be twenty copies of the same picture.
    if opts.canvas then
        local h = opts.canvasHeight or 132
        local host = Band(h)
        shell.canvasHost = host
        shell.canvas = opts.canvas(host, shell)
        Add(host, h, "both")
    end

    -- ── 3. THE STRIPS ──
    -- AD's pool tabs (My Buffs / Debuffs / Any Buff) are their own strip above
    -- the sub-tabs rather than chips among them: they pick WHICH SET is being
    -- edited, which is a prior question to which part of it you are looking at.
    for _, strip in ipairs(opts.strips or {}) do
        local h = strip.height or 30
        local host = Band(h)
        strip.build(host, shell)
        Add(host, h, "both")
    end

    -- ── 4. THE TAB STRIP ──
    if opts.tabs and #opts.tabs > 0 then
        local bar = Band(TABBAR_H)
        shell.tabBar = bar

        -- The baseline the active tab's underline sits on -- the same
        -- underline-tab language the Pinned Frames tabs use.
        local baseline = bar:CreateTexture(nil, "ARTWORK")
        baseline:SetTexture("Interface\\Buttons\\WHITE8x8")
        baseline:SetHeight(1)
        baseline:SetPoint("BOTTOMLEFT", 0, 0)
        baseline:SetPoint("BOTTOMRIGHT", 0, 0)
        local cb = GUI.Colors.border
        baseline:SetColorTexture(cb.r, cb.g, cb.b, 0.5)

        local n = #opts.tabs
        local prev
        for _, def in ipairs(opts.tabs) do
            local btn = CreateFrame("Button", nil, bar, "BackdropTemplate")
            btn:SetHeight(TABBAR_H)
            if prev then
                btn:SetPoint("TOPLEFT", prev, "TOPRIGHT", TAB_GAP, 0)
            else
                btn:SetPoint("TOPLEFT", 0, 0)
            end
            btn:SetWidth(max(60, floor((bandW - (n - 1) * TAB_GAP) / n)))
            GUI:StyleButton(btn, { tab = true, text = def.label, accent = def.accent,
                                   font = "DFFontHighlight" })
            btn.label  = btn.Text
            btn.tabKey = def.key
            btn:SetActive(shell.activeTab == def.key)
            if btn.SetDisabled then
                btn:SetDisabled(def.disabled and def.disabled() or false)
            end

            local capturedKey, tip = def.key, def.tooltip
            btn:SetScript("OnClick", function(self)
                if self.dfDisabled then return end
                if opts.onTab then opts.onTab(capturedKey) end
            end)
            -- HookScript, not SetScript: StyleButton owns OnEnter/OnLeave for the
            -- hover wash, and replacing them would leave the tab stuck lit.
            if tip then
                btn:HookScript("OnEnter", function(self)
                    if tip.onlyWhenDisabled and not self.dfDisabled then return end
                    GUI:ShowTooltip(self, { title = tip.title or def.label, lines = tip.lines })
                end)
                btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
            end

            shell.tabButtons[def.key] = btn
            prev = btn
        end

        -- Equal-width tabs on resize: the layout pass stretches the bar, and a
        -- row of tabs that kept its build-time width would leave a gap on the end.
        bar:SetScript("OnSizeChanged", function(self, w)
            if not w or w < 10 then return end
            local tabW = (w - (n - 1) * TAB_GAP) / n
            for _, def in ipairs(opts.tabs) do
                local b = shell.tabButtons[def.key]
                if b then b:SetWidth(tabW) end
            end
        end)

        Add(bar, TABBAR_H, "both")
    end

    -- ── 5. THE ACTIVE TAB ──
    -- The caller adds its own bands into the SAME column, so a row inside a tab
    -- and the canvas above it share the page's two edges.
    if opts.buildTab then opts.buildTab(shell.activeTab, shell) end

    return shell
end

-- ============================================================
-- A TAB THAT HAS NOT BEEN CONVERTED YET
-- ------------------------------------------------------------
-- The designer rework converts one tab at a time, and the page has to be fully
-- usable at every step -- so an unconverted tab keeps rendering EXACTLY what it
-- rendered inside the split panel, as one full-width object in the band column.
--
-- The builder writes into a host frame and sizes it (every one of them ends with
-- `parent:SetHeight(...)`), so the host is MEASURED after the call rather than
-- declared before it.
--
-- ⚠ THIS IS SCAFFOLDING, and it is meant to be read as such. A tab that still
-- needs it is a tab the conversion has not reached; when the last one converts,
-- so does this.
function GUI:AddDesignerLegacyTab(shell, build)
    local host = shell.Band(1)
    build(host, shell)
    local h = max(host:GetHeight() or 1, 1)
    host:SetHeight(h)
    shell.Add(host, h, "both")
    return host
end
