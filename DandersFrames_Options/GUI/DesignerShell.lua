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
--     [ canvas tabs          ]   what the canvas is SHOWING, joined to it
--     [ frame canvas         ]   ONE shared canvas, not one per row
--     [ strip(s)             ]   AD's scope row; the Text Designer has none
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
-- the six bands, which is the design rather than an accident of the first
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

-- ============================================================
-- THE BAND RHYTHM -- ONE NUMBER
-- ------------------------------------------------------------
-- The layout pass stacks bands FLUSH (y = y - h), so a page built from nothing
-- but bands has no vertical rhythm at all: the banner touches the tabs, the tabs
-- touch the canvas, the canvas touches the scope row. In game that read as
-- "everything looks so crampted together", and it is not any one band's fault --
-- it is the absence of a grid.
--
-- So the gap is the SHELL's, declared once and spent between band GROUPS, rather
-- than a spacer sprinkled at each site by whoever noticed. 10 is not a new
-- number: it is what the Filter Designer's own column already uses
-- (FilterRegistry/UI/Options.lua's BAND_GAP), so the three designer pages share
-- one rhythm instead of three near-misses. That file now READS this one.
--
-- ☠ NOT UNIFORM, AND THE EXCEPTION IS THE DESIGN. The preview is THREE bands --
-- the folder tabs, the fold header, the canvas -- drawn as one panel: the
-- selected tab drops its bottom edge so it runs continuous into the header below
-- it (GUI:StyleFolderTab). A gap anywhere inside that group would open the join
-- the tabs exist to make, so the group's internal gap is 0 and the rhythm goes
-- between groups. That is the "larger between groups, smaller within" shape, with
-- the within-group number pinned at 0 by a drawn continuity rather than by taste.
--
-- ⚠ A GAP IS ITS OWN BAND, NOT SLOT PADDING ON THE ONE ABOVE IT. The canvas band
-- is HIDDEN when the fold is shut and the layout pass skips hidden children
-- outright -- so a gap living in the canvas's slot would vanish with it and the
-- fold header would go back to touching the scope row. A band of its own is
-- always there, at both fold states, which is the only shape that holds.
local BAND_GAP = 10
GUI.DESIGNER_BAND_GAP = BAND_GAP

-- opts:
--   tools        REQUIRED  the page's GUI:CreatePopoutPageTools(page) table
--   Add          REQUIRED  BuildPage's own Add(widget, height, col)
--   AddSpace               BuildPage's AddSpace, for gaps between bands
--   banner       fn(parent, shell) -> widget[, height]   omit for no banner
--   canvasTabs   { height = n, build = fn(host, shell) }  a strip mounted
--                DIRECTLY ABOVE the canvas -- above its fold header too, so it
--                sits on the whole preview panel rather than inside it. See the
--                note on the band below for what does and does not belong here
--   canvas       fn(host, shell)   -> canvas frame       omit for no canvas
--   canvasHeight default 132 (the artifact's figure; see Cards.lua's `compact`)
--   canvasFold   { title =, collapseKey = }  make the canvas a FOLDABLE band
--                under a header of its own. The key is the caller's, and it is
--                REQUIRED: see the note on the band below
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

    -- The rhythm, as a verb. Emits one BAND_GAP band, and NOTHING before the
    -- first real band -- a page whose banner is omitted must not open with a gap
    -- where the banner would have been.
    local emitted = false
    local function Gap()
        if not emitted then return nil end
        local g = Band(BAND_GAP)
        Add(g, BAND_GAP, "both")
        return g
    end
    local function AddBand(widget, h, col)
        Add(widget, h, col or "both")
        emitted = true
        return widget
    end
    -- Published so a tab's own bands can keep the page's rhythm rather than
    -- inventing a second one. The number is read, never copied.
    shell.BandGap = BAND_GAP
    shell.Gap     = Gap

    -- ── 1. THE ENABLE BANNER ──
    if opts.banner then
        local w, h = opts.banner(page.child, shell)
        if w then
            shell.banner = w
            AddBand(w, h or BANNER_H)
        end
    end

    -- ── 2. THE CANVAS TABS ──
    -- ☠ THIS IS THE ONE PLACE A SECOND STRIP OF TABS BELONGS, and only because
    -- of where it is. AD's pool (My Buffs / Debuffs / Any Buff) used to sit
    -- directly on top of the sub-tab strip and the pair read as tabs inside tabs
    -- -- "so confusion to know that they are tabs within tabs". Hiding it in a
    -- picker solved that and cost the three per-tab tooltips. Putting it HERE
    -- solves it by DISTANCE instead: the whole preview panel stands between the
    -- two strips, and drawn as folder tabs joined to that panel (see
    -- GUI:StyleFolderTab) it reads as "these belong to this preview" rather than
    -- as a second row of the thing lower down.
    --
    -- ⚠ WHICH IS ALSO THE RULE FOR WHAT MAY GO HERE. A strip in this slot must
    -- choose what the CANVAS shows. A strip that switches the view of the page
    -- belongs in opts.tabs; a picker that answers "which set am I editing"
    -- belongs in opts.strips, below the canvas.
    --
    -- The bands abut -- the layout pass stacks them flush (y = y - h) -- so what
    -- is built here touches the top of the fold header, which is what lets a tab
    -- be drawn continuous with it.
    --
    -- ⚠ THE GAP GOES BEFORE THIS STRIP AND NOWHERE AFTER IT. The tabs, the fold
    -- header and the canvas are ONE group, joined edge to edge on purpose; the
    -- rhythm resumes below the whole preview. See the BAND_GAP note above.
    if (opts.canvasTabs and opts.canvasTabs.build) or opts.canvas then Gap() end
    if opts.canvasTabs and opts.canvasTabs.build then
        local h = opts.canvasTabs.height or 30
        local host = Band(h)
        shell.canvasTabHost = host
        opts.canvasTabs.build(host, shell)
        AddBand(host, h)
    end

    -- ── 3. THE CANVAS ──
    -- ONE canvas for the whole page, at the top, rather than one per row: a row
    -- is a list entry and the canvas is a picture of the WHOLE frame, so twenty
    -- rows would be twenty copies of the same picture.
    if opts.canvas then
        -- A FUNCTION when the canvas grows with its content. The band must be
        -- sized before the builder that fills it runs, so the height cannot be
        -- read off the canvas -- the caller supplies a verb that knows the
        -- answer from the db instead.
        local h = opts.canvasHeight
        if type(h) == "function" then h = h() end
        h = h or 132
        -- ☠ THE CANVAS FOLDS, AND ITS FOLD IS KEYED BY A LITERAL. At the preview
        -- scales people actually use it is the tallest thing on the page -- 160px
        -- at 1.5 -- and it is a picture, not a control: someone who has finished
        -- placing things wants the list, not the mock. So it gets a header of its
        -- own and remembers.
        --
        -- ☠ collapseKey IS NOT OPTIONAL HERE. CreateCollapsibleSection persists
        -- the fold under the section's TITLE TEXT unless told otherwise, and this
        -- title is a localised string -- so a German client would write a second
        -- profile key and a reworded heading would orphan the first. The caller
        -- names the slot; see GUI:CreateCollapsibleSection's own header, and
        -- section 14's correction 7 of the rework spec for what this trap already
        -- cost once.
        local fold = opts.canvasFold
        local section
        if fold and fold.collapseKey then
            section = GUI:CreateCollapsibleSection(page.child, fold.title, true, bandW,
                                                   { collapseKey = fold.collapseKey })
            shell.canvasSection = section
            AddBand(section, 28)
        end
        local host = Band(h)
        shell.canvasHost = host
        shell.canvas = opts.canvas(host, shell)
        AddBand(host, h)
        -- The band is the section's ONE child, so the page's own state pass hides
        -- it when the header is folded and the bands below close up over it.
        if section then section:RegisterChild(host) end
        -- Regrow in place: the layout pass reads widget.layoutHeight, so setting
        -- it and re-running the pass moves everything below without a rebuild --
        -- which matters because the caller is a slider drag.
        function shell.SetCanvasHeight(want)
            want = tonumber(want)
            if not want or not host or host.layoutHeight == want then return end
            -- A folded canvas has no height to regrow -- the slider that would ask
            -- lives behind the glyph ON it, so this cannot normally fire while it
            -- is shut, but a pinned panel outlives the fold.
            if section and not section.expanded then return end
            host.layoutHeight = want
            host:SetHeight(want)
            if page.RefreshStates then page:RefreshStates() end
        end
    end

    -- ── 4. THE STRIPS ──
    -- ☠ WHAT GOES HERE IS NOT A SECOND ROW OF TABS. AD's pool (My Buffs /
    -- Debuffs / Any Buff) used to be exactly that, stacked straight on top of the
    -- sub-tab strip, and the pair read as tabs inside tabs. It is a canvasTabs
    -- strip now -- above the preview, joined to it -- and the whole panel stands
    -- between the two strips. This slot is for the pickers that answer "which set
    -- am I editing" and have no picture of their own: AD's Spec. A caller that
    -- puts another strip of tabs here is rebuilding the confusion.
    for _, strip in ipairs(opts.strips or {}) do
        local h = strip.height or 30
        Gap()
        local host = Band(h)
        strip.build(host, shell)
        AddBand(host, h)
    end

    -- ── 5. THE TAB STRIP ──
    if opts.tabs and #opts.tabs > 0 then
        Gap()
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

        AddBand(bar, TABBAR_H)
    end

    -- ── 6. THE ACTIVE TAB ──
    -- The caller adds its own bands into the SAME column, so a row inside a tab
    -- and the canvas above it share the page's two edges.
    --
    -- ⚠ AND ONE GAP UNDER THE STRIP, from here rather than from the caller. The
    -- tab bar draws a 1px baseline on its own bottom edge; the first thing a tab
    -- builds would otherwise sit straight on that line. The caller's own bands
    -- keep the same rhythm through shell.Gap().
    if opts.buildTab then
        Gap()
        opts.buildTab(shell.activeTab, shell)
    end

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
    -- ☠ A HEIGHT MEASURED AT BUILD TIME IS A GUESS, AND THIS IS WHERE THE GUESS
    -- IS SPENT. Anything in here that FLOWS -- a wrapping chip row, a word-wrapped
    -- hint -- only learns how tall it is once the layout pass has given it its
    -- real width, which is after this. The builder reports a height anyway,
    -- everything below is anchored at that offset, and the later re-flow moves
    -- nothing: at 850px the chips fitted one row either way and it never showed;
    -- in a 640px window it does.
    --
    -- So the host carries the same verb the canvas band has (shell.SetCanvasHeight
    -- above): set widget.layoutHeight, set the height, re-run the page's layout
    -- pass. A flowing child calls it when its own flow changes, and the bands
    -- below move instead of staying at the stale offset.
    host.dfSetHeight = function(h)
        h = max(tonumber(h) or 1, 1)
        if host.layoutHeight == h then return end
        host.layoutHeight = h
        host:SetHeight(h)
        if shell.page and shell.page.RefreshStates then shell.page:RefreshStates() end
    end
    build(host, shell)
    local h = max(host:GetHeight() or 1, 1)
    host:SetHeight(h)
    -- Add stamps layoutHeight itself (ResolveRowHeight), so it is NOT set here:
    -- one writer, or dfSetHeight's "already this tall" early-out is comparing
    -- against a number the layout pass never agreed to.
    shell.Add(host, h, "both")
    return host
end
