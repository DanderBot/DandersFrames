-- Part 5 of the GUI toolkit, split from the original GUI.lua.
-- These re-declarations are aliases of the SAME objects the first part
-- created; they add no state. See docs/reorg-tools/splits.manifest.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L
local S = GUI._state
local C_PANEL, C_ELEMENT, C_BORDER, C_ACCENT, C_RAID, C_HOVER, C_TEXT, C_TEXT_DIM =
      GUI.Colors.panel, GUI.Colors.element, GUI.Colors.border, GUI.Colors.accent, GUI.Colors.raid, GUI.Colors.hover, GUI.Colors.text, GUI.Colors.textDim
local ResolveRowHeight = GUI.ResolveRowHeight
local GetThemeColor = GUI.GetThemeColor
local SnapLen = GUI.SnapLen
local SnapLenUp = GUI.SnapLenUp
local CreateElementBackdrop = GUI._priv.CreateElementBackdrop
local CreatePanelBackdrop = GUI._priv.CreatePanelBackdrop
local StyleScrollBar = GUI.StyleScrollBar
local RefreshAllOverrideIndicators = GUI.RefreshAllOverrideIndicators
-- ★ ONE PLACE THAT APPLIES THE GUI SCALE. It was open-coded at three sites (creation,
-- slider drag, slider release), each listing the surfaces it knew about — so a surface
-- added later was scaled by whichever of the three someone remembered. DFPopupFrame was
-- in none of them and rendered at 100% forever (Krathe, 2026-08-09).
-- ⚠ DFPopupFrame is created LAZILY, so it is resolved through _G each call rather than
-- captured: it usually does not exist yet when the scale is first applied. Popup.lua
-- seeds the saved scale at creation for exactly that gap.
--
-- ☠ AND THE HAND-WRITTEN LIST FAILED AGAIN. DFPopupFrame was the first surface it
-- missed; the Aura Designer's filter picker, its drag ghost and its buff popup were
-- the next three, all rendering at 100% beside a GUI at 70% (Krathe, 2026-08-10).
-- The list cannot work: it lives here, and the surfaces are created in five other
-- files by people who have no reason to come and edit this function.
--
-- So surfaces REGISTER THEMSELVES at creation, and this walks the registry. A new
-- UIParent-parented surface is scaled by the one line it adds to its own builder, in
-- the file where it is already looking.
--
-- ⚠ Anything parented INSIDE the GUI frame inherits the scale and must NOT register --
-- it would be scaled twice. This is only for surfaces that hang off UIParent.
--
-- ⚠ A full-screen click-catcher must NOT register either. Scaling a frame that is
-- SetAllPoints(UIParent) shrinks the area it actually covers, so the click-away stops
-- working near the screen edges. The filter picker's overlay is deliberately absent.
GUI._scaledSurfaces = GUI._scaledSurfaces or {}

function GUI:RegisterScaledSurface(f)
    if not f then return end
    for _, existing in ipairs(GUI._scaledSurfaces) do
        if existing == f then return end
    end
    GUI._scaledSurfaces[#GUI._scaledSurfaces + 1] = f
    -- Seed immediately. These frames are built lazily, on first use, so one first
    -- opened after the slider moved would otherwise never be told the scale at all --
    -- which is the gap DFPopupFrame needed a hand-written seed of its own to cover.
    local ws = DF.GetWindowState and DF:GetWindowState()
    f:SetScale((ws and ws.scale) or 1)
end

local function ApplyGUIScale(frame, value)
    if frame then frame:SetScale(value) end
    if DF.TestPanel then DF.TestPanel:SetScale(value) end
    local popup = _G and _G.DFPopupFrame
    if popup then popup:SetScale(value) end
    for _, f in ipairs(GUI._scaledSurfaces) do
        f:SetScale(value)
    end
end

-- ============================================================
-- PAGE STATE REFRESH
-- ------------------------------------------------------------
-- The hideOn / disableOn / refreshContent sweep plus the two-column reflow,
-- run for every widget on the open page. It is the settings window's half of
-- the apply path: one write from a control drives this over the whole page.
--
-- ☠ ONE SHARED FUNCTION, not a closure built per page. It used to be defined
-- inside BuildPage, which made it unreachable from DF and therefore
-- unmeasurable -- the profiler resolves its targets as paths against DF, so a
-- per-page local can never be one. Published as GUI.PageRefreshStates below,
-- and pages DISPATCH through that name rather than capturing this value (see
-- the assignment in BuildPage for why).
--
-- The parameter is named `self` because it IS the page and the body is the
-- former closure verbatim: renaming it would have put 250 lines of noise in a
-- diff whose whole point is that nothing changed.
local function PageRefreshStates(self)
    if not self.children then return end
    local db = DF.db[GUI.SelectedMode]
    if not db then return end
    
    -- First pass: handle SettingsGroups - layout their children and calculate heights
    for _, widget in ipairs(self.children) do
        if widget.isSettingsGroup then
            -- Layout children within the group (handles hideOn internally)
            widget:LayoutChildren()
            -- Process disableOn for group children
            widget:RefreshChildStates()
        end
    end
    
    -- Second pass: handle regular widgets and group visibility
    for _, widget in ipairs(self.children) do
        -- Keep any blocked-overlay (top-level widget or group) in sync.
        -- Skip SettingsGroup children - they're handled by their parent group
        if widget.settingsGroup then
            -- Already handled by group's LayoutChildren
        elseif widget.isSettingsGroup then
            -- For groups, check collapsible section state AND group-level hideOn
            local shouldHide = false
            
            -- Check if parent collapsible section is collapsed
            if widget.collapsibleSection and not widget.collapsibleSection.expanded then
                shouldHide = true
            end
            
            -- Check group's own hideOn
            if not shouldHide and widget.hideOn then
                shouldHide = widget.hideOn(db)
            end
            
            if shouldHide then
                widget:Hide()
            else
                widget:Show()
            end
        else
            -- Regular widget processing
            if widget.disableOn then
                local shouldDisable = widget.disableOn(db)
                if widget.SetEnabled then
                    widget:SetEnabled(not shouldDisable)
                end
            end
            
            -- Check if widget should be hidden
            local shouldHide = false
            
            -- First check if parent collapsible section is collapsed
            if widget.collapsibleSection and not widget.collapsibleSection.expanded then
                shouldHide = true
            end
            
            -- Then check widget's own hideOn
            if not shouldHide and widget.hideOn then
                shouldHide = widget.hideOn(db)
            end
            
            if shouldHide then
                widget:Hide()
            else
                widget:Show()
                -- Call refreshContent hook for dynamic content updates
                if widget.refreshContent then
                    widget:refreshContent(db)
                end
            end
        end
    end
    
    -- Determine column layout based on content area width.
    -- Two-column settings groups are 280px wide and placed at x=5 (right
    -- edge 285), while column 2 starts at contentWidth/2 — so they begin to
    -- overlap once contentWidth drops below ~570. minColumnWidth must exceed
    -- the 280 group width (was a stale 270) so the layout collapses to one
    -- column BEFORE the columns touch, leaving a ~10px gutter at the cutover
    -- instead of overlapping for the last ~10px.
    local contentWidth = GUI.contentFrame and GUI.contentFrame:GetWidth() or 540
    local minColumnWidth = 285  -- ≥ the 280 group width + a small gutter
    local usesTwoColumns = contentWidth >= (minColumnWidth * 2 + 20)
    
    -- Account for scrollbar and padding when calculating usable width
    local usableWidth = contentWidth - 40  -- Extra padding for scrollbar
    
    -- Check if editing banner is active (adds 50px at top)
    local bannerOffset = 0
    if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
        bannerOffset = 50
    end
    
    -- Layout - adjust column positions based on available width
    local x1, maxY = 5, 0
    local col2X = usesTwoColumns and math.floor(contentWidth / 2) or x1
    local y1, y2 = -5 - bannerOffset, -5 - bannerOffset
    
    -- First, position any right-aligned elements (like Copy buttons) at absolute top-right
    for _, widget in ipairs(self.children) do
        if widget.rightAlign and widget:IsShown() then
            widget:ClearAllPoints()
            -- Both offsets snapped: this widget is the HEAD of the
            -- Reset/Sync/Copy chain, so a fraction here is inherited by
            -- every button to its left, and the buttons are no longer
            -- nudged back onto the grid individually.
            widget:SetPoint("TOPRIGHT", self.child, "TOPRIGHT",
                SnapLen(self.child, -10), SnapLen(self.child, -5 - bannerOffset))
        end
    end
    
    -- Reserve space below the right-aligned row (Reset Page / Sync / Copy).
    --
    -- This used to subtract a flat 40 with the comment "button height ~26 +
    -- 14 padding" -- a GUESS, not a measurement. Any page whose row is not
    -- exactly 26 tall got a different gap under it, so the first box sat at
    -- a different height on every page and the row appeared to shift.
    -- Measure the row instead and add a fixed pad, so the gap below the
    -- buttons is identical everywhere by construction.
    --
    -- The scan is ALSO gated on IsShown() now, matching the positioning loop
    -- above. It was not, so a page carrying a HIDDEN right-aligned widget
    -- still reserved the 40 and opened with an empty band above its first
    -- box -- the pages Krathe saw "starting further down" with nothing there.
    local RIGHT_ROW_PAD = 14
    local rightRowH = 0
    for _, widget in ipairs(self.children) do
        if widget.rightAlign and widget:IsShown() then
            rightRowH = math.max(rightRowH, widget:GetHeight() or 0)
        end
    end
    if rightRowH > 0 then
        -- Snapped for the same reason every other layout number is: an
        -- unsnapped offset puts everything below it off the pixel grid.
        local reserve = SnapLen(self.child, rightRowH + RIGHT_ROW_PAD)
        y1 = y1 - reserve
        y2 = y2 - reserve
    end
    
    for _, widget in ipairs(self.children) do
        -- Skip widgets that belong to a SettingsGroup (they're positioned by the group)
        if widget.settingsGroup then
            -- Do nothing - parent group handles positioning
        elseif widget.rightAlign then
            -- Already positioned above, skip
        elseif widget.isSyncPoint then
            -- Sync point: align both columns to the lowest Y position
            local syncY = math.min(y1, y2)
            y1 = syncY
            y2 = syncY
        elseif widget:IsShown() then
            -- For SettingsGroups, use calculated height
            local h = widget.layoutHeight or 0
            if widget.isSettingsGroup and widget.calculatedHeight then
                h = widget.calculatedHeight
            end
            
            widget:ClearAllPoints()

            -- Set height for frame-based widgets (like header containers)
            if widget.text and widget.SetHeight and h > 0 then
                widget:SetHeight(h)
            end
            
            -- Apply indent offset if specified (for child/sub-options)
            -- Supports: true (20px), or a number for multiple levels (e.g. 2 = 40px)
            local indentOffset = 0
            if widget.indent then
                if type(widget.indent) == "number" then
                    indentOffset = widget.indent * 20
                else
                    indentOffset = 20
                end
            end
            
            -- Snap the offsets and widths this loop hands out, for the same
            -- reason CreateSettingsGroup:LayoutChildren does: a widget placed
            -- straight onto the page (a banner, a full-width note, a
            -- collapsible section) never passes through a group, so this is
            -- the only place its geometry can be put on the grid. See SnapLen.
            local snapX = SnapLen(widget, x1 + indentOffset)

            if widget.layoutCol == "both" then
                local startY = math.min(y1, y2)
                widget:SetPoint("TOPLEFT", snapX, SnapLen(widget, startY))
                -- Set width to span both columns (with scrollbar padding)
                widget:SetWidth(SnapLen(widget, usableWidth - indentOffset))
                y1 = startY - h
                y2 = startY - h
            elseif widget.layoutCol == 2 and usesTwoColumns then
                widget:SetPoint("TOPLEFT", SnapLen(widget, col2X + indentOffset),
                                SnapLen(widget, y2))
                -- Reduce width for indented widgets to maintain alignment
                if indentOffset > 0 and widget.SetWidth then
                    local defaultColWidth = math.floor((usableWidth - 20) / 2)
                    widget:SetWidth(SnapLen(widget, defaultColWidth - indentOffset))
                end
                y2 = y2 - h
            else
                -- Column 1, or column 2 when in single-column mode
                widget:SetPoint("TOPLEFT", snapX, SnapLen(widget, y1))
                -- Reduce width for indented widgets to maintain alignment
                if indentOffset > 0 and widget.SetWidth then
                    local defaultColWidth = math.floor((usableWidth - 20) / 2)
                    widget:SetWidth(SnapLen(widget, defaultColWidth - indentOffset))
                end
                y1 = y1 - h
            end
            
            local currentBottom = math.min(y1, y2)
            if math.abs(currentBottom) > maxY then maxY = math.abs(currentBottom) end
        end
    end
    local contentH = maxY + 40 + bannerOffset

    -- FOOTER: the See-Also bar is designed as one, so on a page whose
    -- content does not fill the viewport it should sit at the BOTTOM
    -- rather than floating halfway down with dead space under it. On a
    -- page that does fill (or overflow) the viewport it already lands at
    -- the end of the flow, which reads correctly -- so this only moves it
    -- when there is spare room, and the long-page case is untouched.
    --
    -- Done by stretching the scroll child to the viewport height and
    -- anchoring the footer to the child's BOTTOM: the child is what the
    -- flow is measured against, so this keeps the footer inside the
    -- scrolled content (it still scrolls with a long page) instead of
    -- floating over it.
    local footer
    for _, w in ipairs(self.children) do
        if w.isPageFooter and w:IsShown() then footer = w break end
    end
    if footer then
        local viewH = self:GetHeight() or 0
        if viewH > contentH then
            contentH = viewH
            footer:ClearAllPoints()
            footer:SetPoint("BOTTOMLEFT", self.child, "BOTTOMLEFT",
                SnapLen(self.child, x1), SnapLen(self.child, GUI.Space.footer))
            footer:SetWidth(SnapLen(footer, usableWidth))
        end
    end

    self.child:SetHeight(contentH)

    -- Update scroll child width to match content area
    if self.child and GUI.contentFrame then
        self.child:SetWidth(GUI.contentFrame:GetWidth() - 30)
    end
end
GUI.PageRefreshStates = PageRefreshStates

function DF:CreateGUI()
    if DF.GUIFrame then return end
    
    -- Default and saved sizes
    local defaultWidth, defaultHeight = 760, 520
    local minWidth, minHeight = 520, 400
    local maxWidth, maxHeight = 1200, 900
    
    -- Load saved position and size. Account-wide, NOT per-profile: see
    -- DF:GetWindowState in Core/Profile.lua for why it must not follow profiles.
    local guiDb = DF:GetWindowState()
    local savedScale = guiDb.scale or 1.0
    local savedWidth = guiDb.width or defaultWidth
    local savedHeight = guiDb.height or defaultHeight
    
    -- Main frame (matching old addon approach - no BackdropTemplate in CreateFrame)
    local frame = CreateFrame("Frame", "DandersFramesGUI", UIParent)
    frame:SetSize(savedWidth, savedHeight)
    -- Restore saved position, or default to center
    if guiDb.point and guiDb.x then
        frame:SetPoint(guiDb.point, UIParent, guiDb.relPoint or "CENTER", guiDb.x, guiDb.y)
    else
        frame:SetPoint("CENTER")
    end
    frame:SetFrameStrata("DIALOG")  -- Match old addon
    frame:SetToplevel(true)         -- Match old addon
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(minWidth, minHeight, maxWidth, maxHeight)
    frame:EnableMouse(true)
    ApplyGUIScale(frame, savedScale)
    -- Note: Dragging is handled by titleBar, not main frame
    CreatePanelBackdrop(frame)
    frame:Hide()
    DF.GUIFrame = frame

    -- Entrance fade (DandersUI UI.Fx, reached through the GUI host). OnShow
    -- covers EVERY path that shows the window -- DF:ToggleGUI, the test-mode
    -- reopen (TestMode.lua) and Core.lua's debug path. The matching fade-OUT
    -- lives on the close button below and on the DF:ToggleGUI wrapper at the
    -- foot of this file; Esc (UISpecialFrames) hides directly and stays
    -- instant, as does the mover bridge's close-on-unlock.
    --
    -- ★ AND IT IS WHERE THE CURRENT PAGE COMES BACK OUT OF THE PAGE DOCK. The
    -- OnHide below parks it; this adopts it. Hooked on the FRAME rather than
    -- bolted onto DF:ToggleGUI because several paths show this window directly
    -- without going through a SelectTab afterwards (Core.lua's debug open, the
    -- mover bridge, the test-mode reopen), and a window that came back blank on
    -- any one of them would be a far worse bug than the one being fixed.
    -- AdoptPage no-ops when the page is not parked, so this is free on the paths
    -- that never parked it.
    frame:HookScript("OnShow", function(f)
        if GUI.AdoptPage and GUI.Pages and GUI.CurrentPageName then
            GUI:AdoptPage(GUI.Pages[GUI.CurrentPageName])
        end
        GUI.Fx.FadeIn(f, 0.3)
    end)
    
    -- Allow closing with Escape key
    tinsert(UISpecialFrames, "DandersFramesGUI")
    
    -- Exit profile editing when GUI is closed
    frame:SetScript("OnHide", function()
        local AutoProfilesUI = DF.AutoProfilesUI
        if AutoProfilesUI and AutoProfilesUI:IsEditing() then
            AutoProfilesUI:ExitEditing(true)  -- Skip UI updates since GUI is closing
        end
        -- Popout rows stand OUTSIDE this frame, so hiding the window does not
        -- hide them -- they would be left floating over the game with nothing to
        -- dock against. CloseAll, not CloseUnpinned: a pinned panel is pinned
        -- loose from the ROW, not from the window, and the window going away
        -- takes it too. Every path that hides the panel lands here -- the cross,
        -- Escape, /df, and the combat auto-close -- so this is the one place it
        -- needs saying. Guarded for an older embedded copy of the pack.
        if GUI.CloseAllPopoutRows then GUI:CloseAllPopoutRows("windowClosed") end

        -- Park the page that was on screen (see THE PAGE DOCK). With the window
        -- closed nothing needs it in the tree, and leaving it there is one more
        -- subtree the next Show has to walk. It is NOT hidden -- its own shown
        -- flag stays set, so the OnShow hook above brings it straight back
        -- visible with a single SetParent and needs no state of its own.
        if GUI.ParkPage and GUI.Pages and GUI.CurrentPageName then
            GUI:ParkPage(GUI.Pages[GUI.CurrentPageName])
        end
    end)
    
    -- Title bar (handles dragging like old addon)
    -- Uses FULLSCREEN_DIALOG strata so it stays above dropdown menus and popups,
    -- allowing the window to be dragged even when settings panels are open.
    local titleBar = CreateFrame("Frame", nil, frame)
    titleBar:SetHeight(30)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", -30, 0)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        -- Save position so it persists across sessions
        local point, _, relPoint, x, y = frame:GetPoint()
        local ws = DF:GetWindowState()
        ws.point, ws.relPoint, ws.x, ws.y = point, relPoint, x, y
    end)
    titleBar:SetFrameStrata("FULLSCREEN_DIALOG")
    titleBar:SetFrameLevel(200)
    
    local title = titleBar:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    title:SetPoint("LEFT", 12, 0)
    local versionStr = DF.VERSION or "Unknown"
    local channelTags = { alpha = " |cffff8800alpha|r", beta = " |cffff8800beta|r" }
    local channelTag = channelTags[DF.RELEASE_CHANNEL] or ""
    title:SetText("DandersFrames " .. versionStr .. channelTag)
    local c = GetThemeColor()
    title:SetTextColor(c.r, c.g, c.b)
    title.UpdateTheme = function()
        local nc = GetThemeColor()
        title:SetTextColor(nc.r, nc.g, nc.b)
    end
    
    -- Close button with icon
    local closeBtn = GUI:CreateCloseButton(frame, { size = 20, onClick = function()
        -- Fade, then hide. FadeOut's cancel semantics make this safe against a
        -- re-Show mid-fade (the deferred Hide is skipped).
        GUI.Fx.FadeOut(frame, 0.25, function() frame:Hide() end)
    end })
    closeBtn:SetPoint("TOPRIGHT", -8, -5)
    closeBtn:SetFrameStrata("FULLSCREEN_DIALOG")
    closeBtn:SetFrameLevel(210)

    -- Info button (changelog)
    local infoBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    infoBtn:SetPoint("TOPRIGHT", -32, -5)
    infoBtn:SetFrameStrata("FULLSCREEN_DIALOG")
    infoBtn:SetFrameLevel(210)
    -- Icon-only changelog button via the shared styler (backdrop + hover); the hook
    -- brightens the icon to the theme colour on hover.
    GUI:StyleButton(infoBtn, {
        width = 20, height = 20,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\notes", size = 16, color = C_TEXT_DIM },
    })
    infoBtn:HookScript("OnEnter", function(self)
        local tc = GetThemeColor()
        self.Icon:SetVertexColor(tc.r, tc.g, tc.b)
    end)
    infoBtn:HookScript("OnLeave", function(self)
        self.Icon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end)

    -- Changelog overlay (covers full content area below title bar)
    local changelogOverlay = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    changelogOverlay:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -30)
    changelogOverlay:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    changelogOverlay:SetFrameStrata("FULLSCREEN_DIALOG")
    changelogOverlay:SetFrameLevel(300)
    CreatePanelBackdrop(changelogOverlay)
    changelogOverlay:Hide()
    GUI.changelogOverlay = changelogOverlay

    -- Header bar within the overlay
    local changelogHeader = CreateFrame("Frame", nil, changelogOverlay)
    changelogHeader:SetPoint("TOPLEFT", 8, -8)
    changelogHeader:SetPoint("TOPRIGHT", -8, -8)
    changelogHeader:SetHeight(24)

    local changelogTitle = changelogHeader:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    changelogTitle:SetPoint("LEFT", 4, 0)
    changelogTitle:SetText(L["Changelog"] .. " — " .. versionStr)
    changelogTitle:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local backBtn = CreateFrame("Button", nil, changelogHeader, "BackdropTemplate")
    backBtn:SetPoint("RIGHT", 0, 0)
    GUI:StyleButton(backBtn, { width = 60, height = 22, text = L["Close"] })
    backBtn:SetScript("OnClick", function() changelogOverlay:Hide() end)

    -- =========================================================================
    -- CHANGELOG — RENDERED, NOT DUMPED
    -- =========================================================================
    -- ★ This used to be one EditBox holding the whole markdown as colour-coded
    -- text: every release, every section, every entry at the same size and
    -- weight — a wall. It now renders the same CHANGELOG.md structure as typed
    -- pieces (the shape EllesmereUI's patch-notes page uses, reached from the
    -- same complaint): a version title with a hairline underline, caps section
    -- labels, feature CARDS (category as the accent-coloured title, wrapping
    -- body, faint panel behind, 2px accent line on top) and compact fix ROWS
    -- (accent bullet, category chip, wrapping dim body). Hierarchy comes from
    -- size and alpha, and from actual space between things.
    --
    -- The data pipeline is untouched: DF.CHANGELOG_TEXT is still the generated
    -- markdown, parsed here into version → section → entry. Only the newest
    -- releases render up front (frames cost more than a text box); "Show older
    -- releases" appends the next batch. All pieces are pooled so reopening or
    -- resizing rebuilds without leaking frames.
    -- =========================================================================
    local CL_INITIAL_VERSIONS = 5
    local CL_BATCH_VERSIONS   = 5

    -- Parse the markdown into { {version, sections = { {name, entries = { {category, text, author} } } } } }.
    local function ParseChangelog(text)
        local versions = {}
        if not text or text == "" then return versions end
        local cur, sec
        for line in text:gmatch("[^\n]*") do
            local v = line:match("^##%s+%[?([^%]]+)%]?%s*$")
            if v then
                cur = { version = v, sections = {} }
                versions[#versions + 1] = cur
                sec = nil
            elseif cur then
                local h = line:match("^###%s+(.-)%s*$")
                if h then
                    sec = { name = h, entries = {} }
                    cur.sections[#cur.sections + 1] = sec
                else
                    local body = line:match("^[%*%-]%s+(.-)%s*$")
                    if body and body ~= "" then
                        if not sec then
                            sec = { name = "", entries = {} }
                            cur.sections[#cur.sections + 1] = sec
                        end
                        local category, rest = body:match("^%(([^%)]+)%)%s*(.*)$")
                        if not category then category, rest = nil, body end
                        -- ⚠ gsub returns (string, COUNT): capture the author from the
                        -- match, and let the count fall into a throwaway — an earlier
                        -- cut assigned the count to `author` and every row ended in "1".
                        local author = rest:match("%(by%s+([^%)]+)%)%s*$")
                        rest = rest:gsub("%s*%(by%s+[^%)]+%)%s*$", "")
                        sec.entries[#sec.entries + 1] = { category = category, text = rest, author = author }
                    end
                end
            end
        end
        return versions
    end

    -- ★ DEEP LINKS. A feature card whose category names a settings page is a
    -- button: click closes the changelog and lands on that page (EUI's rule —
    -- no target, no click, mouse off so nothing invites a dead click). Keys are
    -- the changelog's own "(Category)" tags, normalised to lowercase alnum, so
    -- "Click-Casting" / "Click Casting" / "click casting" all resolve. Targets
    -- are either a sub-tab id (party/raid mode) or the "clicks" mode.
    -- ⚠ Not every category has a page (Test Mode is a toolbar button; Debug
    -- has a console tab): those cards stay static, on purpose.
    local CL_NAV = {
        auradesigner = "auras_auradesigner",
        auras = "auras_buffs", buffs = "auras_buffs", buffbar = "auras_buffs",
        buffsdebuffs = "auras_buffs", buffsanddebuffs = "auras_buffs",
        debuffs = "auras_debuffs", debuffbar = "auras_debuffs",
        defensiveicons = "auras_defensiveicon", defensiveicon = "auras_defensiveicon",
        dispelhighlight = "auras_dispel", dispel = "auras_dispel",
        filterdesigner = "auras_filterdesigner", filters = "auras_filterdesigner",
        missingbuffs = "auras_missingbuffs",
        bars = "bars_health", healthbar = "bars_health", healthbars = "bars_health",
        absorbs = "bars_absorb", absorb = "bars_absorb",
        healprediction = "bars_healpred", resourcebar = "bars_resource", powerbar = "bars_resource",
        pinnedframes = "general_pinnedframes", friendlybossnpcframes = "general_pinnedframes",
        petframes = "display_pets", pets = "display_pets",
        fonts = "general_fonts", globalfonts = "general_fonts",
        nicknames = "general_nicknames", sorting = "general_sorting",
        frames = "general_frame", layout = "general_frame", raidframes = "general_frame",
        partyframes = "general_frame", frameborder = "general_frame",
        settings = "general_settings", general = "general_settings",
        integrations = "general_integrations",
        indicators = "indicators_icons", icons = "indicators_icons", statusicons = "indicators_icons",
        highlights = "indicators_highlights", targetedspells = "indicators_personal_targeted",
        textdesigner = "text_designer", text = "text_designer",
        range = "display_fading", fading = "display_fading", classcolors = "display_classcolors",
        tooltips = "display_tooltips", visibility = "display_visibility",
        profiles = "profiles_manage", importexport = "profiles_importexport",
        debug = "debug_console", wizards = "wizards",
        clickcasting = "clicks",
    }
    local function navTargetFor(category)
        if type(category) ~= "string" then return nil end
        return CL_NAV[(category:lower():gsub("[^%w]", ""))]
    end
    local function navigateTo(target)
        if not target then return end
        changelogOverlay:Hide()
        if target == "clicks" then
            if GUI.ClicksButton then GUI.ClicksButton:Click() end
            return
        end
        -- Sub-tabs live under the party/raid modes; from Clicks, step back to
        -- Party first (the toolbar button owns that transition and its cleanup).
        if GUI.SelectedMode == "clicks" and GUI.PartyButton then GUI.PartyButton:Click() end
        C_Timer.After(0, function()
            if GUI.LinkToSetting then GUI:LinkToSetting({ page = target, flash = false }) end
        end)
    end

    -- Scroll surface. ScrollFrameTemplate + the themed pill, like every list.
    local clScroll = CreateFrame("ScrollFrame", nil, changelogOverlay, "ScrollFrameTemplate")
    clScroll:SetPoint("TOPLEFT", 8, -38)
    clScroll:SetPoint("BOTTOMRIGHT", -26, 8)
    StyleScrollBar(clScroll)
    local clChild = CreateFrame("Frame", nil, clScroll)
    clChild:SetWidth(100)
    clScroll:SetScrollChild(clChild)

    -- Pools. Kinds: "fs" (FontString), "tex" (Texture), "card" (backdrop frame),
    -- "sep" (separator frame). Everything is parented to clChild.
    local clPool, clUsed = {}, {}
    local function acquire(kind)
        local p = clPool[kind]; if not p then p = {}; clPool[kind] = p end
        local u = clUsed[kind] or 0; u = u + 1; clUsed[kind] = u
        local obj = p[u]
        if not obj then
            if kind == "fs" then
                obj = clChild:CreateFontString(nil, "OVERLAY")
            elseif kind == "tex" then
                obj = clChild:CreateTexture(nil, "ARTWORK")
            elseif kind == "card" then
                -- ★ A FEATURE CALLOUT, not a card. No box, no fill, no grid: DF's own
                -- note/banner idiom — a left accent RAIL with a STAR at its head (the
                -- changelog's "new feature" glyph; fixes get a dot), title line, wrapping
                -- body, and a CHEVRON at the title's right edge only when the feature
                -- links to a settings page (the "go here" affordance the panel already
                -- uses). Rail colour says clickable: theme when linked, dim when not.
                -- A Button so a linked callout is one click; static ones mouse off.
                obj = CreateFrame("Button", nil, clChild)
                -- Faint fill so the callout reads as a surface you can press — no
                -- border and no top accent (the rail is the accent). Hover lifts it.
                obj.fill = obj:CreateTexture(nil, "BACKGROUND")
                obj.fill:SetAllPoints()
                obj.fill:SetColorTexture(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.35)
                obj.rail = obj:CreateTexture(nil, "ARTWORK")
                obj.rail:SetPoint("TOPLEFT", 0, 0)
                obj.rail:SetPoint("BOTTOMLEFT", 0, 0)
                obj.rail:SetWidth(3)
                obj.star = obj:CreateTexture(nil, "OVERLAY")
                obj.star:SetSize(14, 14)
                obj.star:SetPoint("TOPLEFT", 10, -9)
                obj.star:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\star")
                obj.chev = obj:CreateTexture(nil, "OVERLAY")
                obj.chev:SetSize(14, 14)
                obj.chev:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
                obj.title = obj:CreateFontString(nil, "OVERLAY")
                obj.body  = obj:CreateFontString(nil, "OVERLAY")
                obj.by    = obj:CreateFontString(nil, "OVERLAY")
                obj:SetScript("OnEnter", function(self)
                    if not self.navTarget then return end
                    local c = self.railColor
                    self.fill:SetColorTexture(C_HOVER.r, C_HOVER.g, C_HOVER.b, 0.55)
                    self.rail:SetColorTexture(c.r, c.g, c.b, 1)
                    self.chev:SetVertexColor(c.r, c.g, c.b, 1)
                    self.title:SetTextColor(c.r, c.g, c.b, 1)
                end)
                obj:SetScript("OnLeave", function(self)
                    if not self.navTarget then return end
                    local c = self.railColor
                    self.fill:SetColorTexture(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.35)
                    self.rail:SetColorTexture(c.r, c.g, c.b, 0.7)
                    self.chev:SetVertexColor(c.r, c.g, c.b, 0.6)
                    self.title:SetTextColor(c.r, c.g, c.b, 0.9)
                end)
                obj:SetScript("OnClick", function(self) navigateTo(self.navTarget) end)
            elseif kind == "sep" then
                obj = GUI:CreateSeparator(clChild, { width = 100, alpha = 0.10 })
            elseif kind == "band" then
                -- Version band: a full-width theme-tinted strip with a 2px theme line
                -- under it. THE patch divider — a hairline under a title was not
                -- enough once sections got real headings of their own.
                obj = CreateFrame("Frame", nil, clChild)
                obj.fill = obj:CreateTexture(nil, "BACKGROUND")
                obj.fill:SetAllPoints()
                obj.line = obj:CreateTexture(nil, "ARTWORK")
                obj.line:SetPoint("BOTTOMLEFT", 0, 0)
                obj.line:SetPoint("BOTTOMRIGHT", 0, 0)
                obj.line:SetHeight(2)
                obj.text = obj:CreateFontString(nil, "OVERLAY")
                obj.text:SetPoint("LEFT", 12, 1)
                obj.text:SetJustifyH("LEFT")
            end
            p[u] = obj
        end
        obj:ClearAllPoints()
        -- A pooled FontString carries its last role's width and leading; reset
        -- so a title reused from a row does not inherit a wrap width or spacing.
        if kind == "fs" then obj:SetWidth(0); obj:SetHeight(0); obj:SetSpacing(0) end
        obj:Show()
        return obj
    end
    local function releaseAll()
        for kind, p in pairs(clPool) do
            for i = 1, #p do p[i]:Hide(); p[i]:ClearAllPoints() end
            clUsed[kind] = 0
        end
    end

    -- Section names come from CHANGELOG.md headings; translate when a key exists.
    local function sectionLabel(name)
        local key = name and L[name]
        return (type(key) == "string" and key ~= name and key) or name or ""
    end

    local clParsed, clShown, clBuiltWidth = nil, CL_INITIAL_VERSIONS, nil
    local clMoreBtn

    local function BuildChangelog()
        clParsed = clParsed or ParseChangelog(DF.CHANGELOG_TEXT)
        releaseAll()
        local tc = GetThemeColor()
        local W = math.floor(clScroll:GetWidth())
        if W < 100 then W = 400 end
        clChild:SetWidth(W)
        clBuiltWidth = W
        local PAD = 6
        local innerW = W - PAD * 2
        local y = -4

        if #clParsed == 0 then
            local fs = acquire("fs")
            GUI:SetSettingsFont(fs, 11, "")
            fs:SetPoint("TOPLEFT", PAD, y)
            fs:SetText(L["No changelog available."])
            fs:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            clChild:SetHeight(40)
            if clMoreBtn then clMoreBtn:Hide() end
            return
        end

        for vi = 1, math.min(#clParsed, clShown) do
            local ver = clParsed[vi]
            -- Version band: the patch divider. Extra air above every band but the first
            -- so a release starts with an unmistakable break, not a title in the flow.
            if vi > 1 then y = y - 18 end
            local band = acquire("band")
            local bandH = vi == 1 and 34 or 30
            band:SetPoint("TOPLEFT", PAD, y)
            band:SetSize(innerW, bandH)
            band.fill:SetColorTexture(tc.r, tc.g, tc.b, 0.12)
            band.line:SetColorTexture(tc.r, tc.g, tc.b, 0.85)
            GUI:SetSettingsFont(band.text, vi == 1 and 17 or 15, "")
            band.text:SetText(ver.version)
            band.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b, 1)
            y = y - bandH - 14

            for _, sec in ipairs(ver.sections) do
                if #sec.entries > 0 then
                    -- Section title: a real heading (13px, full text colour) with its own
                    -- hairline underneath, so New Features / Bug Fixes / Improvements read
                    -- as three blocks rather than one grey caption in a wall of rows.
                    if sec.name ~= "" then
                        local lab = acquire("fs")
                        GUI:SetSettingsFont(lab, 13, "")
                        lab:SetPoint("TOPLEFT", PAD, y)
                        lab:SetText(sectionLabel(sec.name):upper())
                        lab:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.95)
                        y = y - 20
                        local ssep = acquire("sep")
                        ssep:SetWidth(innerW)
                        ssep:SetPoint("TOPLEFT", PAD, y)
                        y = y - 12
                    end
                    local isFeatures = sec.name:lower():find("feature", 1, true) ~= nil
                    if isFeatures then
                        -- FEATURE CALLOUTS, one per row, full width. See the pool
                        -- constructor for the shape; this only lays out and measures.
                        local RAIL_X = 32   -- text starts right of rail + star, inside the fill
                        local TOP_PAD, BOT_PAD = 9, 9
                        local dimRail = { r = C_TEXT_DIM.r, g = C_TEXT_DIM.g, b = C_TEXT_DIM.b }
                        for _, e in ipairs(sec.entries) do
                            local co = acquire("card")
                            co:SetPoint("TOPLEFT", PAD, y)
                            co:SetWidth(innerW)
                            local target = navTargetFor(e.category)
                            co.navTarget = target
                            co:EnableMouse(target ~= nil)
                            local rc = target and tc or dimRail
                            co.railColor = rc
                            co.fill:SetColorTexture(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.35)
                            co.rail:SetColorTexture(rc.r, rc.g, rc.b, target and 0.7 or 0.45)
                            co.star:SetVertexColor(tc.r, tc.g, tc.b, 0.95)
                            -- Title line: category in small caps; chevron only when linked.
                            GUI:SetSettingsFont(co.title, 11, "")
                            co.title:ClearAllPoints()
                            co.title:SetPoint("TOPLEFT", RAIL_X, -TOP_PAD)
                            co.title:SetWidth(innerW - RAIL_X - 30)
                            co.title:SetJustifyH("LEFT")
                            co.title:SetWordWrap(false)
                            co.title:SetText((e.category or L["New Feature"]):upper())
                            co.title:SetTextColor(rc.r, rc.g, rc.b, target and 0.9 or 0.85)
                            co.chev:ClearAllPoints()
                            co.chev:SetPoint("TOPRIGHT", -8, -TOP_PAD + 1)
                            co.chev:SetVertexColor(rc.r, rc.g, rc.b, 0.6)
                            co.chev:SetShown(target ~= nil)
                            -- ☠ EXPLICIT WIDTH, NOT AN ANCHOR-DERIVED ONE. Wrapped height is
                            -- only measurable once the FontString knows its width, and a
                            -- two-anchor width is not guaranteed resolved in the frame that
                            -- set it — measured that way the rows came back one line tall
                            -- and every entry overlapped the next. A set width wraps
                            -- deterministically, so the callout always grows to fit.
                            GUI:SetSettingsFont(co.body, 11, "")
                            co.body:ClearAllPoints()
                            co.body:SetPoint("TOPLEFT", co.title, "BOTTOMLEFT", 0, -5)
                            co.body:SetWidth(innerW - RAIL_X - 14)
                            co.body:SetJustifyH("LEFT")
                            co.body:SetJustifyV("TOP")
                            co.body:SetWordWrap(true)
                            co.body:SetNonSpaceWrap(false)
                            co.body:SetSpacing(2)
                            local by = e.author and format("  |cff%02x%02x%02x%s|r",
                                C_TEXT_DIM.r * 255, C_TEXT_DIM.g * 255, C_TEXT_DIM.b * 255, e.author) or ""
                            co.body:SetText(e.text .. by)
                            co.body:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.82)
                            co.by:Hide()   -- byline rides the body's tail now
                            local bh = math.ceil(co.body:GetStringHeight() or 14)
                            local h = TOP_PAD + 14 + 5 + bh + BOT_PAD
                            co:SetHeight(h)
                            y = y - h - 10
                        end
                        y = y - 4
                    else
                        -- ROWS, GROUPED BY CATEGORY. The tag used to sit inline at the
                        -- start of every sentence, so "Bars" appeared six times in a row
                        -- and each line began with a coloured word the eye had to parse
                        -- past. Now: a stable sort by category (authored order kept within
                        -- one), ONE small caps sub-heading per category, and plain
                        -- wrapping bullets under it with a little leading. Same scan-
                        -- ability a category column would give, without spending a fixed
                        -- column's width on every row.
                        local ordered = {}
                        for i, e in ipairs(sec.entries) do ordered[i] = { e = e, i = i } end
                        table.sort(ordered, function(a, b)
                            local ac, bc = a.e.category or "\255", b.e.category or "\255"
                            if ac ~= bc then return ac < bc end
                            return a.i < b.i
                        end)
                        local dimHex = format("%02x%02x%02x",
                            C_TEXT_DIM.r * 255, C_TEXT_DIM.g * 255, C_TEXT_DIM.b * 255)
                        local lastCat = false
                        for _, o in ipairs(ordered) do
                            local e = o.e
                            local cat = e.category
                            if cat ~= lastCat then
                                if lastCat ~= false then y = y - 6 end   -- gap between groups
                                lastCat = cat
                                if cat then
                                    local sub = acquire("fs")
                                    GUI:SetSettingsFont(sub, 10, "")
                                    sub:SetPoint("TOPLEFT", PAD + 2, y)
                                    sub:SetWidth(innerW - 2)
                                    sub:SetJustifyH("LEFT")
                                    sub:SetWordWrap(false)
                                    sub:SetText(cat:upper())
                                    sub:SetTextColor(tc.r, tc.g, tc.b, 0.9)
                                    y = y - 17
                                end
                            end
                            local dot = acquire("tex")
                            dot:SetColorTexture(tc.r, tc.g, tc.b, 0.55)
                            dot:SetSize(4, 4)
                            dot:SetPoint("TOPLEFT", PAD + 8, y - 6)
                            local fs = acquire("fs")
                            GUI:SetSettingsFont(fs, 11, "")
                            fs:SetPoint("TOPLEFT", PAD + 20, y)
                            fs:SetWidth(innerW - 20)   -- explicit: see the card body note
                            fs:SetJustifyH("LEFT")
                            fs:SetJustifyV("TOP")
                            fs:SetWordWrap(true)
                            fs:SetNonSpaceWrap(false)
                            fs:SetSpacing(2)           -- leading: a wrapped entry is a paragraph, not a block
                            local by = e.author and format("  |cff%s%s|r", dimHex, e.author) or ""
                            fs:SetText(e.text .. by)
                            fs:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.75)
                            local h = math.ceil(fs:GetStringHeight() or 14)
                            y = y - h - 9
                        end
                        y = y - 8
                    end
                end
            end
            y = y - 14
        end

        -- "Show older releases" — appends the next batch; hidden once everything is out.
        if #clParsed > clShown then
            if not clMoreBtn then
                clMoreBtn = CreateFrame("Button", nil, clChild, "BackdropTemplate")
                GUI:StyleButton(clMoreBtn, { width = 160, height = 22, text = L["Show older releases"] })
                clMoreBtn:SetScript("OnClick", function()
                    clShown = clShown + CL_BATCH_VERSIONS
                    BuildChangelog()
                end)
            end
            clMoreBtn:ClearAllPoints()
            clMoreBtn:SetPoint("TOP", clChild, "TOP", 0, y)
            clMoreBtn:Show()
            y = y - 30
        elseif clMoreBtn then
            clMoreBtn:Hide()
        end

        clChild:SetHeight(-y + 8)
        clScroll:SetVerticalScroll(0)
    end

    -- ONE opener for both the info button and the first-open-after-update path.
    function GUI:ShowChangelog()
        clShown = CL_INITIAL_VERSIONS
        -- Show FIRST, then build: the scroll frame's width is what every wrap
        -- measures against, and it is only trustworthy once the overlay is laid out.
        changelogOverlay:Show()
        BuildChangelog()
    end
    -- A resize while the overlay is open changes every wrap; rebuild at the new width.
    changelogOverlay:SetScript("OnSizeChanged", function()
        if changelogOverlay:IsShown() and clBuiltWidth
            and math.abs(math.floor(clScroll:GetWidth()) - clBuiltWidth) >= 2 then
            BuildChangelog()
        end
    end)

    infoBtn:SetScript("OnClick", function()
        if changelogOverlay:IsShown() then
            changelogOverlay:Hide()
        else
            GUI:ShowChangelog()
        end
    end)

    -- =========================================================================
    -- RESIZE HANDLE (bottom-right corner)
    -- =========================================================================
    local resizeHandle = CreateFrame("Button", nil, frame)
    resizeHandle:SetSize(16, 16)
    resizeHandle:SetPoint("BOTTOMRIGHT", -2, 2)
    resizeHandle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeHandle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeHandle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeHandle:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeHandle:SetScript("OnMouseUp", function(self, button)
        frame:StopMovingOrSizing()
        -- Save new size
        local ws = DF:GetWindowState()
        ws.width, ws.height = frame:GetWidth(), frame:GetHeight()
        -- Update content layout
        if GUI.SelectedMode == "clicks" then
            -- Refresh click casting UI on resize (skip scroll reset)
            if DF.ClickCast and DF.ClickCast.RefreshSpellGrid then
                DF.ClickCast:RefreshSpellGrid(true)
            end
        elseif GUI.RefreshCurrentPage then
            GUI:RefreshCurrentPage()
        end
    end)
    
    -- Party/Raid mode toggle buttons
    local btnParty = CreateFrame("Button", nil, frame, "BackdropTemplate")
    -- Head of the toolbar chain (Party <- Raid <- Clicks <- Test <- Unlock), so
    -- this offset is what every button along it inherits.
    btnParty:SetPoint("TOPLEFT", SnapLen(frame, 12), SnapLen(frame, -32))
    -- Shared underline-tab style; SetActive (in UpdateThemeColors) drives it.
    GUI:StyleButton(btnParty, { tab = true, text = L["PARTY"], accent = C_ACCENT, width = 70, height = 24, font = "DFFontHighlight" })
    GUI.PartyButton = btnParty  -- Store for external access
    
    local btnRaid = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnRaid:SetPoint("LEFT", btnParty, "RIGHT", SnapLen(btnRaid, 4), 0)
    GUI:StyleButton(btnRaid, { tab = true, text = L["RAID"], accent = C_RAID, width = 70, height = 24, font = "DFFontHighlight" })
    GUI.RaidButton = btnRaid  -- Store for external access
    
    -- Click Casting tab button
    local btnClicks = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnClicks:SetPoint("LEFT", btnRaid, "RIGHT", SnapLen(btnClicks, 4), 0)
    GUI:StyleButton(btnClicks, { tab = true, text = L["BINDS"], accent = { r = 0.2, g = 0.8, b = 0.4 }, width = 70, height = 24, font = "DFFontHighlight" })
    GUI.ClicksButton = btnClicks

    -- =========================================================================
    -- TEST MODE BUTTON (next to CLICKS tab)
    -- =========================================================================
    local btnTest = CreateFrame("Button", nil, frame, "BackdropTemplate")
    -- Snapped gap + snapped width below: the toolbar is a CHAIN (Clicks <- Test
    -- <- Unlock <- override marker) and controls are not position-corrected after
    -- the fact, so every offset and width in the chain has to be a whole number
    -- of device pixels or the fraction accumulates rightwards.
    btnTest:SetPoint("LEFT", btnClicks, "RIGHT", SnapLen(btnTest, 12), 0)
    GUI:StyleButton(btnTest, {
        width = 75, height = 24,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\preview_off", size = 18, color = C_TEXT_DIM },
        text = L["Test"],
    })
    GUI:SetSettingsFont(btnTest.Text, 11, "")  -- 11px (between Small 10 and Highlight 12)
    btnTest.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    -- Content-fit width (less dead space)
    btnTest:SetWidth(SnapLenUp(btnTest, math.ceil(btnTest.Text:GetStringWidth()) + 38))
    GUI.TestButton = btnTest
    
    -- =========================================================================
    -- LOCK/UNLOCK BUTTON (next to Test button)
    -- =========================================================================
    local btnLock = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnLock:SetPoint("LEFT", btnTest, "RIGHT", SnapLen(btnLock, 4), 0)
    GUI:StyleButton(btnLock, {
        width = 80, height = 24,
        icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\lock", size = 18, color = C_TEXT_DIM },
        text = L["Unlock"],
    })
    GUI:SetSettingsFont(btnLock.Text, 11, "")  -- 11px (between Small 10 and Highlight 12)
    btnLock.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    -- Size to the wider "Unlock" label so toggling Lock/Unlock doesn't resize the
    -- button (real label set in UpdateLockButtonState).
    btnLock:SetWidth(SnapLenUp(btnLock, math.ceil(btnLock.Text:GetStringWidth()) + 38))
    GUI.LockButton = btnLock
    
    -- Position override marker (shown next to the lock button when the frame
    -- position is overridden in the layout being edited). Shared marker helper →
    -- dot + hover tooltip, one colour with every other override marker.
    local positionOverrideStar = GUI:CreateOverrideMarker(frame, 14)
    positionOverrideStar:SetPoint("LEFT", btnLock, "RIGHT", SnapLen(positionOverrideStar, 4), 0)
    positionOverrideStar.tooltipText = L["Override active"]
    positionOverrideStar.tooltipSubText = L["The frame position is overridden in this layout."]
    GUI.PositionOverrideStar = positionOverrideStar
    
    -- Function to update position override indicator
    local function UpdatePositionOverrideIndicator()
        -- Debug mode shows indicator
        if S.overrideDebugMode then
            positionOverrideStar:Show()
            return
        end
        
        if GUI.SelectedMode ~= "raid" then
            positionOverrideStar:Hide()
            return
        end
        
        local AutoProfilesUI = DF.AutoProfilesUI
        if not AutoProfilesUI or not AutoProfilesUI:IsEditing() then
            positionOverrideStar:Hide()
            return
        end
        
        -- Check if position is overridden (either X or Y)
        local xOverridden = AutoProfilesUI:IsSettingOverridden("raidAnchorX")
        local yOverridden = AutoProfilesUI:IsSettingOverridden("raidAnchorY")
        
        if xOverridden or yOverridden then
            positionOverrideStar:Show()
        else
            positionOverrideStar:Hide()
        end
    end
    GUI.UpdatePositionOverrideIndicator = UpdatePositionOverrideIndicator
    
    -- Forward declaration (defined after UpdateThemeColors)
    local UpdateTestButtonState
    
    local function UpdateLockButtonState()
        local db = DF.db[GUI.SelectedMode]
        -- Raid mode uses raidLocked, party mode uses locked. Use an explicit
        -- branch (NOT `a and b or c`) so an unlocked raid (raidLocked=false)
        -- doesn't fall through to the party `locked` value and read as locked.
        local isLocked
        if db then
            if GUI.SelectedMode == "raid" then isLocked = db.raidLocked else isLocked = db.locked end
        end

        -- While an auto layout drives the raid frames, dragging the base position by
        -- accident is the bug we're preventing: disable the toolbar Unlock and steer
        -- users to the active layout's own Unlock button (Auto Layouts page). Only the
        -- UNLOCK action is blocked (isLocked) — locking from here still works to finish
        -- a session.
        local layoutActive = (GUI.SelectedMode == "raid") and DF.AutoProfilesUI
            and DF.AutoProfilesUI.IsLayoutActive and DF.AutoProfilesUI:IsLayoutActive()
        if layoutActive and isLocked then
            btnLock.dfDisabled = true
            btnLock.Text:SetText(L["Unlock"])
            btnLock.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\lock")
            btnLock:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 0.5)
            btnLock:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
            btnLock.Text:SetTextColor(0.4, 0.4, 0.4)
            btnLock.Icon:SetVertexColor(0.4, 0.4, 0.4)
            UpdatePositionOverrideIndicator()
            return
        end
        btnLock.dfDisabled = false

        btnLock.Text:SetText(isLocked and L["Unlock"] or L["Lock"])
        btnLock.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. (isLocked and "lock" or "lock_open"))
        
        if not isLocked then
            -- Unlocked - active/selected toggle look (white text/icon like the others)
            btnLock:SetActive(true)
            btnLock.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btnLock.Icon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            -- Locked - normal rest (white text/icon; state shown by the border/fill)
            btnLock:SetActive(false)
            btnLock.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            btnLock.Icon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        end
        
        -- Update position override indicator
        UpdatePositionOverrideIndicator()
    end
    GUI.UpdateLockButtonState = UpdateLockButtonState
    
    -- HookScript (not SetScript) so the disabled tooltip composes with the
    -- StyleButton hover instead of clobbering it.
    btnLock:HookScript("OnEnter", function(self)
        if self.dfDisabled then
            local name = DF.AutoProfilesUI and DF.AutoProfilesUI.GetActiveLayoutName
                and DF.AutoProfilesUI:GetActiveLayoutName()
            GUI:ShowTooltip(self, {
                title = L["Locked by Auto Layout"],
                tone = "warning",
                lines = { format(L["Auto layout \"%s\" is active. Unlock it from the Auto Layouts page to move its frames."], name or "?") },
            })
        end
    end)
    btnLock:HookScript("OnLeave", function() GUI:HideTooltip() end)

    btnLock:SetScript("OnClick", function()
        if btnLock.dfDisabled then
            local name = DF.AutoProfilesUI and DF.AutoProfilesUI.GetActiveLayoutName
                and DF.AutoProfilesUI:GetActiveLayoutName()
            DF:Say(format(L["Auto layout \"%s\" is active. Unlock it from the Auto Layouts page to move its frames."], name or "?"))
            return
        end

        local db = DF.db[GUI.SelectedMode]
        if not db then return end

        -- Check current lock state using the correct key per mode (explicit
        -- branch — `a and b or c` would misread an unlocked raid as locked).
        local isLocked
        if GUI.SelectedMode == "raid" then isLocked = db.raidLocked else isLocked = db.locked end
        
        if GUI.SelectedMode == "raid" then
            if isLocked then
                DF:UnlockRaidFrames()
            else
                DF:LockRaidFrames()
            end
        else
            if isLocked then
                DF:UnlockFrames()
            else
                DF:LockFrames()
            end
        end
        
        -- Lock/Unlock functions now call UpdateLockButtonState themselves,
        -- but call it here too as a safety net
        UpdateLockButtonState()
        UpdateTestButtonState()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    
    -- =========================================================================
    -- UI SCALE SLIDER (top right, always visible with larger min frame size)
    -- =========================================================================
    local scaleContainer = CreateFrame("Frame", nil, frame)
    scaleContainer:SetSize(155, 24)
    scaleContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -32)
    
    -- ★ ANCHORED FROM THE RIGHT, so a longer label grows LEFTWARD into empty title-bar
    -- space instead of pushing the slider and the percentage out of a fixed-width box.
    --
    -- The container is 155px and pinned TOPRIGHT, and this row used to flow the other way
    -- -- label at the container's LEFT, slider anchored to the label's right, percentage
    -- to the slider's right. In English "UI Scale:" fits and the row lands inside the box;
    -- German "UI Skalierung:" is far wider, so everything after it was shoved past the
    -- right edge of the window. Reversing the chain (percentage pinned RIGHT, slider left
    -- of it, label left of that) makes the row's right edge fixed and its left edge free,
    -- which is the direction there is room in.
    local scaleLabel = scaleContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    scaleLabel:SetText(L["UI Scale:"])
    scaleLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    local scaleSlider = CreateFrame("Slider", nil, scaleContainer, "BackdropTemplate")
    scaleSlider:SetSize(65, 14)
    scaleSlider:SetOrientation("HORIZONTAL")
    scaleSlider:SetMinMaxValues(0.6, 1.4)
    scaleSlider:SetValueStep(0.05)
    scaleSlider:SetObeyStepOnDrag(true)
    scaleSlider:SetValue(savedScale)
    CreateElementBackdrop(scaleSlider)
    
    -- Thumb texture
    local thumb = scaleSlider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 14)
    thumb:SetColorTexture(0.5, 0.5, 0.5, 1)
    scaleSlider:SetThumbTexture(thumb)
    
    -- The RIGHT-hand end of the reversed chain: percentage pinned to the container's right
    -- edge, slider to its left, label to the slider's left. Declared here rather than at
    -- each widget's creation so the whole chain reads in one place.
    local scaleValue = scaleContainer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    -- ⚠ FIXED WIDTH, because the slider hangs off this string's LEFT edge. Unsized,
    -- the string narrows when "100%" drops to "95%" and the whole chain -- slider
    -- included -- shifts under the cursor MID-DRAG, the exact drift the comment on
    -- OnValueChanged below exists to prevent. Wide enough for "100%".
    scaleValue:SetWidth(34)
    scaleValue:SetJustifyH("RIGHT")
    scaleValue:SetPoint("RIGHT", scaleContainer, "RIGHT", 0, 0)
    scaleSlider:SetPoint("RIGHT", scaleValue, "LEFT", -4, 0)
    scaleLabel:SetPoint("RIGHT", scaleSlider, "LEFT", -6, 0)
    scaleValue:SetText(string.format("%.0f%%", savedScale * 100))
    scaleValue:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Only update text while dragging (not main frame scale - that causes cursor drift)
    -- But DO update popup panels live
    scaleSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value * 20 + 0.5) / 20  -- Round to 0.05
        scaleValue:SetText(string.format("%.0f%%", value * 100))
        -- Update popup panels live (they don't cause cursor drift)
        ApplyGUIScale(nil, value)   -- panels only; the main frame waits for mouse-up
    end)
    
    -- Apply scale only on mouse release to avoid cursor drift issues
    scaleSlider:SetScript("OnMouseUp", function(self)
        local value = math.floor(self:GetValue() * 20 + 0.5) / 20
        ApplyGUIScale(frame, value)
        DF:GetWindowState().scale = value
        -- A new scale changes how many device pixels a UI unit covers, so
        -- every border on screen has to be re-derived at the new thickness.
        -- This is the ONLY action that does: nothing else in the GUI writes
        -- windowState.scale, and moving or resizing the window leaves it alone.
        GUI:RefreshPixelBorders()
    end)

    GUI.ScaleSlider = scaleSlider
    GUI.ScaleContainer = scaleContainer
    -- =========================================================================
    -- END TOP BAR CONTROLS
    -- =========================================================================
    
    local function UpdateThemeColors()
        -- Mode buttons use the shared underline-tab style; SetActive drives the
        -- underline + accent label (each button's per-mode accent set at creation).
        btnParty:SetActive(GUI.SelectedMode == "party")
        btnRaid:SetActive(GUI.SelectedMode == "raid")
        btnClicks:SetActive(GUI.SelectedMode == "clicks")

        -- Test button look via the shared toggle styling (matches how the Lock
        -- button is refreshed below). The old inline version painted a stray
        -- theme-coloured border even at rest.
        if UpdateTestButtonState then UpdateTestButtonState() end

        -- Refresh the toolbar buttons' hover wash to the current mode accent.
        -- They live on the main frame (not a page child), so the page
        -- ThemeListeners loop below never reaches them — without this their hover
        -- stays the party colour after switching to raid. (UpdateTestButtonState/
        -- SetActive only fix the resting backdrop, not the HIGHLIGHT wash.)
        if btnTest.UpdateTheme then btnTest.UpdateTheme() end
        if btnLock.UpdateTheme then btnLock.UpdateTheme() end
        -- infoBtn (changelog) also lives on the main frame, not a page child, so
        -- the ThemeListeners loop below never reaches it either — refresh its hover
        -- wash to the current mode accent here alongside Test/Lock.
        if infoBtn and infoBtn.UpdateTheme then infoBtn.UpdateTheme() end
        
        -- Show/hide Test and Lock buttons based on mode
        if GUI.SelectedMode == "clicks" then
            btnTest:Hide()
            btnLock:Hide()
        else
            btnTest:Show()
            btnLock:Show()
        end
        
        title.UpdateTheme()
        
        -- Update active tab
        local nc = GetThemeColor()
        for name, btn in pairs(GUI.Tabs) do
            if btn.isActive and not btn.disabled then
                btn.accent:SetColorTexture(nc.r, nc.g, nc.b, 1)
                btn.Text:SetTextColor(nc.r, nc.g, nc.b)
                btn.Text:SetAlpha(1)
            elseif btn.disabled then
                btn.Text:SetTextColor(0.4, 0.4, 0.4)
                btn.Text:SetAlpha(1)
                if btn.accent then btn.accent:Hide() end
            end
        end
        
        -- Update theme listeners
        if GUI.CurrentPageName and GUI.Pages[GUI.CurrentPageName] then
            local page = GUI.Pages[GUI.CurrentPageName]
            if page.child and page.child.ThemeListeners then
                for _, widget in ipairs(page.child.ThemeListeners) do
                    if widget.UpdateTheme then widget:UpdateTheme() end
                end
            end
        end
        
        -- Update test panel if open (but don't trigger circular updates)
        if DF.TestPanel and DF.TestPanel:IsShown() then
            DF.TestPanel:UpdateStateNoCallback()
        end
        
        -- Update lock button state
        UpdateLockButtonState()
    end
    GUI.UpdateThemeColors = UpdateThemeColors

    -- ☠ RE-THEME EVERY TIME THE WINDOW SHOWS, not only when a mode tab is clicked.
    -- Field report (Neosaro, v5.1.3; still reported current 2026-08-22): the title
    -- text keeps "the color of the tab it was first enabled at the start of the
    -- session or after a reload". Every mode-tab handler and DF:ToggleGUI call
    -- UpdateThemeColors, so the ordinary paths are covered -- but any path that
    -- shows the frame WITHOUT going through them presents the chrome in whatever
    -- colour the last pass painted (/df resetgui's direct GUIFrame:Show() is one
    -- such path in-repo, and nothing stops another appearing). Hooking OnShow makes
    -- the invariant structural: a visible window is a re-themed window, whoever
    -- showed it. Idempotent and cheap (a handful of SetTextColor/SetActive calls),
    -- and HookScript so an existing or future OnShow handler is composed with, not
    -- replaced.
    frame:HookScript("OnShow", function() UpdateThemeColors() end)

    -- Function to update test button state (called externally)
    UpdateTestButtonState = function()
        -- Both cues read the USER's claim -- the same thing the panel's toggle shows
        -- -- so the two controls the user thinks of as one can never disagree.
        --
        -- ⚠ Deliberately NOT "is a preview on screen". Unlocking puts frames up under
        -- its OWN claim, and driving the glyph off that made a plain unlock look like
        -- the user had switched test mode on. Frames being visible during an unlock is
        -- unlock's business; the chat line explains it.
        local panelOpen = DF.TestPanel and DF.TestPanel:IsShown()
        local scope = (GUI.SelectedMode == "raid") and "raid" or "party"
        local userWants = DF.IsTestModeOwnedBy and DF:IsTestModeOwnedBy(scope, "user")
        btnTest:SetActive(panelOpen)
        btnTest.Icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
            .. (userWants and "preview" or "preview_off"))
        -- White text/icon in both states (state shown by the toggle border/fill).
        btnTest.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        btnTest.Icon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    end
    GUI.UpdateTestButtonState = UpdateTestButtonState
    
    -- Test button scripts
    btnTest:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btnTest:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            -- Quick toggle test mode
            DF:ToggleTestMode()
            UpdateThemeColors()
        else
            -- Open/close test panel
            DF:ToggleTestPanel()
            UpdateTestButtonState()
        end
    end)
    
    -- Hover is handled by StyleButton (resets to grey on leave). The old manual
    -- OnEnter/OnLeave left a stuck theme-coloured border because its OnLeave reset
    -- to themeColor@0.5 rather than the neutral border.

    btnParty:SetScript("OnClick", function()
        DF:SyncLinkedSections()

        -- Carry test mode across the mode switch (raid test -> party test)
        local carryTest = false
        -- Before switching tabs, clean up current mode's test mode and unlock state
        if GUI.SelectedMode == "raid" then
            -- Lock raid frames if unlocked. LockRaidFrames owns the WHOLE transition:
            -- the db flag, the container, the mover, grid, panel and pinned chrome.
            -- ⚠ This block used to stamp raidLocked = true and poke the container
            -- ITSELF before calling -- so when LockRaidFrames' combat guard refused,
            -- the db said locked while every mover stayed on screen for the rest of
            -- the fight, and the Lock button then offered Unlock. In combat the state
            -- now stays consistently UNLOCKED (the guard says so in chat) and the
            -- user locks after regen; the direct SetMovable poke also fought
            -- UpdatePermanentMoverVisibility, which owns container movability.
            local raidDb = DF:GetRaidDB()
            if not raidDb.raidLocked then
                if DF.LockRaidFrames then DF:LockRaidFrames() end
            end
            -- Disable raid test mode if active
            if DF.raidTestMode then
                carryTest = true
                -- Hand-over: stay in container/pinned test mode across the swap rather
                -- than tearing every aura container down for live data we never show
                -- and rebuilding it a moment later. Cleared below.
                DF._testModeHandover = true
                DF:HideRaidTestFrames(true)  -- silent
                -- Hides directly rather than through the owners, so drop raid's
                -- claims to match. carryTest re-claims in the scope we land in.
                if DF.ClearTestModeOwners then DF:ClearTestModeOwners("raid") end
            end
        end

        GUI.SelectedMode = "party"
        GUI:SetAccent(GUI.GetThemeColorFor(false))
        if DF.Search then
            DF.Search:InvalidateRegistry()
            DF.Search:RefreshIfActive()
        end
        UpdateThemeColors()
        GUI:ShowNormalContent()
        GUI:UpdateTabAvailability()
        GUI:RefreshCurrentPage()

        -- Keep test mode active when switching modes (just switch which mode it runs in).
        -- Carried as the USER's claim: they had a preview up and are still asking for
        -- one, just in the other scope.
        if carryTest and DF.SetTestModeOwner then
            DF:SetTestModeOwner("party", "user", true, true)   -- silent: the mode swap is the visible event
            -- ShowTestFrames (unlike ShowRaidTestFrames) doesn't refresh the GUI,
            -- so the test panel's toggle label would stay on "Enable Test Mode".
            -- Refresh it now that party test mode is active.
            if DF.TestPanel and DF.TestPanel:IsShown() then
                DF.TestPanel:UpdateStateNoCallback()
            end
        end
        if carryTest then
            -- End the hand-over and settle: ShowTestFrames can bail (combat, party
            -- frames disabled), which would otherwise leave the engines parked in
            -- test mode with nothing testing. Teardown re-reads the real flags, so
            -- it is a no-op when the incoming mode did start.
            DF._testModeHandover = nil
            if DF.TeardownTestModeEngines then DF:TeardownTestModeEngines() end
        end
    end)
    btnRaid:SetScript("OnClick", function()
        DF:SyncLinkedSections()

        -- Carry test mode across the mode switch (party test -> raid test)
        local carryTest = false
        -- Before switching tabs, clean up current mode's test mode and unlock state
        if GUI.SelectedMode == "party" then
            -- Lock party frames if unlocked
            local partyDb = DF:GetDB()
            if not partyDb.locked then
                partyDb.locked = true
                if DF.partyContainer then
                    DF.partyContainer:EnableMouse(false)
                    DF.partyContainer:SetMovable(false)
                end
                if DF.LockFrames then DF:LockFrames() end
            end
            -- Disable party test mode if active
            if DF.testMode then
                carryTest = true
                -- Hand-over: see the raid->party handler above.
                DF._testModeHandover = true
                DF:HideTestFrames(true)  -- silent
                -- Hides directly rather than through the owners, so drop party's
                -- claims to match. carryTest re-claims in the scope we land in.
                if DF.ClearTestModeOwners then DF:ClearTestModeOwners("party") end
            end
        end

        GUI.SelectedMode = "raid"
        GUI:SetAccent(GUI.GetThemeColorFor(true))
        if DF.Search then
            DF.Search:InvalidateRegistry()
            DF.Search:RefreshIfActive()
        end
        UpdateThemeColors()
        GUI:ShowNormalContent()
        GUI:UpdateTabAvailability()
        GUI:RefreshCurrentPage()

        -- Keep test mode active when switching modes (just switch which mode it runs in).
        -- Carried as the USER's claim: they had a preview up and are still asking for
        -- one, just in the other scope.
        if carryTest and DF.SetTestModeOwner then
            DF:SetTestModeOwner("raid", "user", true, true)    -- silent: the mode swap is the visible event
        elseif carryTest and DF.ShowRaidTestFrames then
            DF:ShowRaidTestFrames()
        end
        if carryTest then
            -- End the hand-over and settle; see the raid->party handler above.
            DF._testModeHandover = nil
            if DF.TeardownTestModeEngines then DF:TeardownTestModeEngines() end
        end
    end)
    
    -- Click Casting tab click handler
    btnClicks:SetScript("OnClick", function()
        -- Clean up any test/unlock state from previous mode
        if GUI.SelectedMode == "party" then
            local partyDb = DF:GetDB()
            if partyDb and not partyDb.locked then
                partyDb.locked = true
                if DF.LockFrames then DF:LockFrames() end
            end
            if DF.testMode then DF:HideTestFrames(true) end
            -- Leaving for a tab with no frames: nobody is asking for a preview
            -- any more, so drop the claims rather than let them outlive it.
            if DF.ClearTestModeOwners then DF:ClearTestModeOwners("party") end
        elseif GUI.SelectedMode == "raid" then
            local raidDb = DF:GetRaidDB()
            if raidDb and not raidDb.raidLocked then
                raidDb.raidLocked = true
                if DF.LockRaidFrames then DF:LockRaidFrames() end
            end
            if DF.raidTestMode then DF:HideRaidTestFrames(true) end
            -- As above: no preview is wanted on a tab that has no frames.
            if DF.ClearTestModeOwners then DF:ClearTestModeOwners("raid") end
        end

        GUI.SelectedMode = "clicks"
        GUI:SetAccent(GUI.GetThemeColorFor(false))
        if DF.Search then 
            DF.Search:HideResults()
        end
        UpdateThemeColors()
        GUI:ShowClickCastingContent()
    end)
    
    -- Tab container (left side) - with scrolling
    -- ★ Every offset in the nav chain is SNAPPED, for the same structural reason
    -- the page viewport is: these frames are anchored by two corners, nothing
    -- nudges them afterwards, and the numbers going in are the only
    -- lever. Unsnapped, the whole list inherits the fraction -- /df debug navprobe
    -- measured every one of 42 rows at top+0.38, which is the 4-unit inset below
    -- (5.625 device px at 1.4062 px/unit) propagated down the chain. A row that
    -- starts on a fractional device row draws its hover plate's top and bottom
    -- edges across two rows each at partial intensity, and its label on a
    -- fractional baseline -- which is what is left of the nav ghost now that the
    -- dead band between rows is gone.
    local tabFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    tabFrame:SetPoint("TOPLEFT", SnapLen(frame, 12), SnapLen(frame, -64))
    tabFrame:SetPoint("BOTTOMLEFT", SnapLen(frame, 12), SnapLen(frame, 36))
    tabFrame:SetWidth(SnapLen(frame, 155))
    CreateElementBackdrop(tabFrame)
    tabFrame:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.5)
    
    -- =========================================================================
    -- SEARCH BAR
    -- =========================================================================
    local searchBar = nil
    local navPad = SnapLen(tabFrame, 4) or 4
    local navRight = SnapLen(tabFrame, -14) or -14
    local tabScrollStartY = -navPad
    if DF.Search then
        searchBar = DF.Search:CreateSearchBar(tabFrame)
        searchBar:SetPoint("TOPLEFT", navPad, -navPad)
        searchBar:SetPoint("TOPRIGHT", navRight, -navPad)
        tabScrollStartY = SnapLen(tabFrame, -36) or -36
    end

    local tabScroll = CreateFrame("ScrollFrame", nil, tabFrame, "ScrollFrameTemplate")
    tabScroll:SetPoint("TOPLEFT", navPad, tabScrollStartY)
    tabScroll:SetPoint("BOTTOMRIGHT", navRight, navPad)

    StyleScrollBar(tabScroll)
    -- Custom positioning for tab scrollbar
    if tabScroll.ScrollBar then
        tabScroll.ScrollBar:ClearAllPoints()
        tabScroll.ScrollBar:SetPoint("TOPRIGHT", tabFrame, "TOPRIGHT", -navPad, tabScrollStartY)
        tabScroll.ScrollBar:SetPoint("BOTTOMRIGHT", tabFrame, "BOTTOMRIGHT", -navPad, navPad)
    end

    local tabContainer = CreateFrame("Frame", nil, tabScroll)
    tabContainer:SetWidth(SnapLen(tabScroll, 130) or 130)
    tabContainer:SetHeight(600) -- Will be updated dynamically
    tabScroll:SetScrollChild(tabContainer)
    GUI.tabContainer = tabContainer
    GUI.tabScroll = tabScroll

    -- ONE hover plate for the whole nav, MOVED to the row under the cursor --
    -- rather than 42 plates that each switch themselves off and on.
    --
    -- Why, after the geometry was already proven clean: navprobe showed no dead
    -- band, no overlap, no stale plate, no focus thrash, and every row at
    -- top-0.00. Two facts then rule out layout entirely -- the ghost is on LIVE
    -- too, which shares none of this branch's GUI work, and its severity varies
    -- across identical crossings. Geometry is deterministic; the same path would
    -- give the same result every time. Something that varies run to run is
    -- timing: the frame in which one row's colour change lands relative to the
    -- next row's, which Lua cannot observe and cannot control.
    --
    -- So stop relying on the two changes landing in the same frame. With a single
    -- plate there is no pair to synchronise: the texture is already on screen and
    -- only its anchors move, so no frame can ever show two plates or none.
    local navHover = CreateFrame("Frame", nil, tabContainer, "BackdropTemplate")
    navHover:EnableMouse(false)   -- must never take focus from the row beneath it
    -- Container level, i.e. strictly below the rows (children default to +1), so
    -- the plate stays behind every label and accent bar.
    navHover:SetFrameLevel(math.max(0, tabContainer:GetFrameLevel() or 1))
    CreateElementBackdrop(navHover, { outline = false, bgColor = { 0, 0, 0, 0 } })
    navHover:Hide()
    GUI.navHover = navHover

    local function NavHoverShow(row, alpha)
        navHover.owner = row
        navHover:ClearAllPoints()
        navHover:SetAllPoints(row)
        navHover:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, alpha)
        navHover:Show()
    end

    -- Deferred by one frame ON PURPOSE. The rows tile, so leaving one and
    -- entering the next happens in the same frame and WoW does not guarantee
    -- which handler runs first. Hiding immediately would put back exactly the
    -- dark frame this exists to remove; instead the hide only lands if no row
    -- claimed the plate in the meantime.
    local function NavHoverHide(row)
        if navHover.owner ~= row then return end
        C_Timer.After(0, function()
            if navHover.owner == row then
                navHover:Hide()
                navHover.owner = nil
            end
        end)
    end
    GUI.HideNavHover = function()
        navHover:Hide()
        navHover.owner = nil
    end


    -- Content area (right side) - no BackdropTemplate in CreateFrame
    -- ★ THE content panel, and therefore the ancestor of every page viewport --
    -- so its edges are the surface every page is clipped against. Snapped for
    -- the same structural reason the nav chain is: it is anchored by two corners,
    -- Nothing nudges it afterwards, and the offsets going in are the only
    -- lever.
    --
    -- The BOTTOM one is what mattered. A raw 36 is 50.625 device px at 1.4062
    -- px/unit, i.e. 0.625 above a grid line -- and /df debug pixelcheck reported
    -- exactly that on every page it was ever run on: "viewport top+0.00
    -- bot-0.375". The page's own inset was already snapped, but a snapped inset
    -- off a fractional PARENT edge is still fractional, so the viewport's bottom
    -- clip boundary sat between two device rows. Anything resting against it --
    -- now the See-Also bar, since it was made a footer -- loses part of its
    -- border to the cut.
    --
    -- Same shape as the original bug at the TOP of the page: the box measures
    -- perfect and the surface it is clipped against is what is wrong. Krathe
    -- spotted the symmetry before the numbers did.
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", tabFrame, "TOPRIGHT", SnapLen(frame, 8), 0)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT",
        SnapLen(frame, -12), SnapLen(frame, 36))
    CreateElementBackdrop(content)
    content:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.3)
    GUI.contentFrame = content
    GUI.tabFrame = tabFrame

    -- =========================================================================
    -- THE PAGE DOCK
    -- -------------------------------------------------------------------------
    -- ☠ EVERY BUILT PAGE USED TO STAY PARENTED TO `content`, SHOWN OR NOT, and
    -- that is what made opening the settings window take EIGHT SECONDS. Settings
    -- search indexes by BUILDING every page (Search:BuildFullRegistry), so one
    -- search leaves all 34 of them fully populated -- 700+ widgets, plus the
    -- Aura/Text Designer machinery -- hanging hidden off this one frame. From
    -- then on GUIFrame:Show() measured 7774ms and Hide() about 2000ms, with only
    -- ~52 of our own OnShow handlers firing in the whole 7.7s: the cost is the
    -- ENGINE walking that hidden subtree for visibility, not Lua we run.
    -- Reparenting the non-current pages away dropped the same Show to 90ms.
    --
    -- So a page that is not the one on screen lives HERE instead: a detached,
    -- permanently hidden frame with no parent at all, outside the window's tree
    -- entirely. Deliberately NOT GUI._trashFrame -- trash means dead and never
    -- coming back (that is where a rebuild retires a page's old children); the
    -- dock means alive and parked, and every page in it is expected back.
    --
    -- ⚠ A parked page KEEPS ITS ANCHORS to `content` -- which is why the
    -- SetPoint in CreateSubTab names `content` explicitly instead of leaning on
    -- the omitted-relativeTo default. A parked page therefore still measures at
    -- its real size and can be BUILT in place, which is exactly what search's
    -- index pass does to all 34 of them.
    GUI._pageDock = CreateFrame("Frame")
    GUI._pageDock:Hide()

    -- Move a page out of the window's frame tree. Idempotent and cheap; the page
    -- is expected to be hidden already (every caller hides first).
    function GUI:ParkPage(page)
        if not page or page._parked then return end
        page:SetParent(GUI._pageDock)
        page._parked = true
    end

    -- ...and bring it back, re-asserting the anchors rather than trusting them to
    -- have survived the round trip.
    --
    -- ⚠ Scale comes back WITH the parent. The dock sits at 1.0 while the window
    -- is scaled, and a page must never register as a scaled surface (it is INSIDE
    -- the window, so it would be scaled twice -- see RegisterScaledSurface), so
    -- re-parenting is the whole of it: the page re-inherits the window's scale
    -- chain and nothing caches an effective scale while it is parked.
    --
    -- Early-out when the page is not parked, so callers on hot paths
    -- (RefreshCurrentPage, the window's OnShow) can call it unconditionally.
    function GUI:AdoptPage(page)
        if not page or not page._parked then return end
        page:SetParent(content)
        page._parked = nil
        local inset = page._contentInset or 8
        page:ClearAllPoints()
        page:SetPoint("TOPLEFT", content, "TOPLEFT", inset, -inset)
        page:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -inset, inset)
    end

    -- =========================================================================
    -- CLICK CASTING PANEL (full width, replaces normal content when active)
    -- =========================================================================
    local clickCastPanel = CreateFrame("Frame", nil, frame)
    clickCastPanel:SetPoint("TOPLEFT", 12, -64)
    clickCastPanel:SetPoint("BOTTOMRIGHT", -12, 36)
    CreateElementBackdrop(clickCastPanel)
    clickCastPanel:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.3)
    clickCastPanel:Hide()
    GUI.clickCastPanel = clickCastPanel

    -- =========================================================================
    -- FOOTER BAR (Discord & Donation links + bottom drag handle)
    -- =========================================================================

    -- Bottom drag bar (mirrors titleBar for dragging from the bottom)
    local bottomBar = CreateFrame("Frame", nil, frame)
    bottomBar:SetHeight(30)
    bottomBar:SetPoint("BOTTOMLEFT", 0, 0)
    bottomBar:SetPoint("BOTTOMRIGHT", -16, 0)  -- Leave space for resize handle
    bottomBar:EnableMouse(true)
    bottomBar:RegisterForDrag("LeftButton")
    bottomBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    bottomBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint()
        local ws = DF:GetWindowState()
        ws.point, ws.relPoint, ws.x, ws.y = point, relPoint, x, y
    end)

    local footer = CreateFrame("Frame", nil, bottomBar)
    footer:SetPoint("BOTTOMLEFT", 12, 8)
    footer:SetPoint("BOTTOMRIGHT", -12, 8)
    footer:SetHeight(22)
    
    -- URL copy popup helper
    local function ShowURLPopup(url, label)
        local popup = GUI.urlPopup
        if not popup then
            popup = CreateFrame("Frame", "DFURLPopup", UIParent, "BackdropTemplate")
            -- In the same file as ApplyGUIScale and still missed by it, which is the
            -- clearest argument for the registry over a hand-written list.
            GUI:RegisterScaledSurface(popup)
            popup:SetSize(380, 80)
            popup:SetPoint("CENTER")
            GUI:CreatePanelBackdrop(popup, { bgAlpha = 0.98, borderColor = C_ACCENT })
            popup:SetFrameStrata("FULLSCREEN_DIALOG")
            popup:SetFrameLevel(250)
            popup:EnableMouse(true)
            
            local popupTitle = popup:CreateFontString(nil, "OVERLAY", "DFFontNormal")
            popupTitle:SetPoint("TOP", 0, -10)
            popupTitle:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            popup.title = popupTitle
            
            local editBox = CreateFrame("EditBox", nil, popup, "BackdropTemplate")
            editBox:SetPoint("TOPLEFT", 12, -30)
            editBox:SetPoint("TOPRIGHT", -12, -30)
            editBox:SetHeight(22)
            GUI:StyleEditBox(editBox)
            editBox:SetAutoFocus(true)
            editBox:SetScript("OnEscapePressed", function() popup:Hide() end)
            editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
            popup.editBox = editBox
            
            local hint = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            hint:SetPoint("BOTTOM", 0, 8)
            hint:SetText(L["Press Ctrl+C to copy, then Escape to close"])
            hint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            
            GUI.urlPopup = popup
        end
        
        popup.title:SetText(label)
        popup.editBox:SetText(url)
        popup:Show()
        popup.editBox:SetFocus()
        popup.editBox:HighlightText()
    end
    GUI.ShowURLPopup = ShowURLPopup

    -- Create a footer link button
    local function CreateFooterLink(parent, text, color, url, popupLabel)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetHeight(22)
        
        local label = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        label:SetPoint("CENTER")
        label:SetText(text)
        label:SetTextColor(color.r, color.g, color.b)
        btn:SetWidth(label:GetStringWidth() + 10)
        btn.label = label
        
        btn:SetScript("OnEnter", function()
            local h = GUI:LinkHoverColor(color)
            label:SetTextColor(h.r, h.g, h.b)
        end)
        btn:SetScript("OnLeave", function()
            label:SetTextColor(color.r, color.g, color.b)
        end)
        btn:SetScript("OnClick", function()
            ShowURLPopup(url, popupLabel)
        end)
        
        return btn
    end
    
    -- Discord link
    local discordColor = { r = 0.45, g = 0.53, b = 0.85 }
    local discordBtn = CreateFooterLink(footer, L["Need support? Join our Discord"], discordColor,
        "https://discord.gg/SDWtduCqnT", L["Join the DandersFrames Discord"])
    discordBtn:SetPoint("LEFT", footer, "LEFT", 2, 0)
    
    -- Separator
    local sep = footer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    sep:SetPoint("LEFT", discordBtn, "RIGHT", 8, 0)
    sep:SetText("|")
    sep:SetTextColor(C_BORDER.r, C_BORDER.g, C_BORDER.b)
    
    -- PayPal link
    local paypalColor = { r = 0.35, g = 0.65, b = 0.45 }
    local donateBtn = CreateFooterLink(footer, L["Support with PayPal"], paypalColor,
        "https://paypal.me/dandersframesaddon", L["Support DandersFrames Development"])
    donateBtn:SetPoint("LEFT", sep, "RIGHT", 8, 0)

    -- Separator 2
    local sep2 = footer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    sep2:SetPoint("LEFT", donateBtn, "RIGHT", 8, 0)
    sep2:SetText("|")
    sep2:SetTextColor(C_BORDER.r, C_BORDER.g, C_BORDER.b)

    -- Patreon link
    local patreonColor = { r = 0.90, g = 0.35, b = 0.30 }
    local patreonBtn = CreateFooterLink(footer, L["Support with Patreon"], patreonColor,
        "https://www.patreon.com/DandersFrames", L["Support DandersFrames on Patreon"])
    patreonBtn:SetPoint("LEFT", sep2, "RIGHT", 8, 0)

    -- Version on the right
    local versionText = footer:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    versionText:SetPoint("RIGHT", footer, "RIGHT", -2, 0)
    versionText:SetText(versionStr .. channelTag)
    versionText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.5)
    
    -- Create the click casting UI content
    if DF.ClickCast then
        DF.ClickCast:CreateClickCastUI(clickCastPanel)
    end
    
    -- Store min width references for tab switching
    local normalMinWidth = minWidth  -- 520
    -- Shared minimum width for the "wide" pages (Binds/Click Casting, Aura
    -- Designer, Text Designer, Pinned Frames) — their two-panel / tab-strip
    -- layouts squash below this.
    local wideMinWidth = 850

    -- Pages whose two-panel / tab-strip layouts squash below wideMinWidth.
    -- ☠ Hoisted to panel scope on purpose. This lived INSIDE SelectTab, which meant
    -- (a) it was rebuilt on every tab click, and (b) ShowNormalContent could not see it --
    -- so returning from BINDS to PARTY/RAID reset the minimum to 520 while a wide page was
    -- still the visible one, and it could then be dragged narrow. Any new consumer of the
    -- wide-page rule reads THIS table; do not re-declare a local copy.
    local WIDE_PAGES = {
        auras_auradesigner   = true,  -- two-panel preview + controls
        auras_filterdesigner = true,  -- Aura Filters: two-column preset list + spell list
        text_designer        = true,  -- two-panel preview + controls
        general_pinnedframes = true,  -- tab strip + active-set meter
        general_nicknames    = true,  -- wide add-row (Match+Char+Nick+Add) + list columns
    }

    -- Apply the right minimum for a page id, expanding if we are currently under it.
    local function ApplyPageWidthBounds(name)
        local wanted = WIDE_PAGES[name] and wideMinWidth or normalMinWidth
        frame:SetResizeBounds(wanted, minHeight, maxWidth, maxHeight)
        if frame:GetWidth() < wanted then
            frame:SetWidth(wanted)
        end
        return WIDE_PAGES[name]
    end

    -- Function to show normal Party/Raid content
    function GUI:ShowNormalContent()
        if clickCastPanel then clickCastPanel:Hide() end
        if tabFrame then tabFrame:Show() end
        if content then content:Show() end

        -- Restore the minimum width FOR THE PAGE WE ARE RETURNING TO -- not a blanket
        -- normalMinWidth. This used to reset to 520 unconditionally, so coming back from
        -- BINDS onto a wide page (Aura Filters, AD/TD, Pinned) left that page draggable
        -- down to 520 and squashed.
        ApplyPageWidthBounds(GUI.CurrentPageName)

        -- Update tab availability for current mode (greys out tabs for disabled modes)
        GUI:UpdateTabAvailability()
    end
    
    -- Function to show Click Casting content
    function GUI:ShowClickCastingContent()
        if tabFrame then tabFrame:Hide() end
        if content then content:Hide() end
        
        -- Set larger minimum width for clicks tab
        frame:SetResizeBounds(wideMinWidth, minHeight, maxWidth, maxHeight)
        
        -- If current width is less than clicks min, expand it
        local currentWidth = frame:GetWidth()
        if currentWidth < wideMinWidth then
            frame:SetWidth(wideMinWidth)
        end
        
        if clickCastPanel then 
            clickCastPanel:Show()
            -- Refresh the spell grid
            if DF.ClickCast and DF.ClickCast.RefreshSpellGrid then
                DF.ClickCast:RefreshSpellGrid()
            end
        end
    end
    
    -- =========================================================================
    -- SEARCH RESULTS PANEL (inside content area)
    -- =========================================================================
    if DF.Search then
        DF.Search:CreateResultsPanel(content)
    end
    
    GUI.Tabs = {}
    GUI.Pages = {}
    
    local function SelectTab(name)
        -- ☠ CLOSE OPEN MENUS FIRST. A dropdown menu is parented to its own button, so a
        -- tab change hides it by ANCESTOR — which fires its OnHide (clearing the
        -- single-slot tracker) while leaving the menu's own shown flag set. Come back to
        -- that tab and it reappears, untracked: it floats over the page, overlaps the next
        -- dropdown you open, and only closes if you click its own button
        -- (Krathe, 2026-08-09). Hiding them here is what stops them being stranded.
        -- ⚠ Before HideResults and the page swap, so nothing is mid-teardown when it runs.
        if GUI.CloseAllMenus then GUI:CloseAllMenus() end

        -- Hide search results when navigating to a tab
        if DF.Search then
            DF.Search:HideResults()
        end

        -- Clear any "New" section-header badges on the tab we're leaving.
        -- The user has had their chance to see the badges; mark them seen
        -- persistently so they don't reappear on the next visit.
        local leavingTab = GUI.CurrentPageName
        if leavingTab and leavingTab ~= name and GUI.pendingSectionBadges[leavingTab] then
            for key, badge in pairs(GUI.pendingSectionBadges[leavingTab]) do
                if badge and badge.Hide then badge:Hide() end
                if DandersFramesDB_v2 then
                    DandersFramesDB_v2.seenSections = DandersFramesDB_v2.seenSections or {}
                    DandersFramesDB_v2.seenSections[key] = true
                end
            end
            GUI.pendingSectionBadges[leavingTab] = nil
        end

        -- Popout rows: leaving the page invalidates the rows the open panel is
        -- ABOUT -- the row it is tethered to is about to be hidden, and the
        -- controls inside it belong to a page nobody is looking at. UNPINNED
        -- only: a panel the user deliberately pinned loose is theirs to keep
        -- across a page change, which is the whole difference between the two
        -- verbs. Guarded for an older embedded copy of the pack.
        if GUI.CloseUnpinnedPopoutRows then GUI:CloseUnpinnedPopoutRows("pageSwitch") end

        -- Hide every page, and PARK the ones we are not about to show. Hiding
        -- alone is what the eight-second window open was made of: a hidden page
        -- still parented under the window is a subtree the engine walks on every
        -- Show and Hide of it. See THE PAGE DOCK.
        for k, page in pairs(GUI.Pages) do
            page:Hide()
            if k ~= name then GUI:ParkPage(page) end
        end
        for k, btn in pairs(GUI.Tabs) do
            if btn.accent then btn.accent:Hide() end
            -- Check if tab is disabled (e.g., during Auto Profile editing)
            if btn.disabled then
                btn.Text:SetTextColor(0.4, 0.4, 0.4)
                btn.Text:SetAlpha(1)
            else
                btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
                btn.Text:SetAlpha(1)
            end
            btn.isActive = false
            btn:SetBackdropColor(0, 0, 0, 0)  -- Reset background when deselected
        end
        
        -- Auto-expand parent category so the selected tab is visible
        local tab = GUI.Tabs[name]
        if tab and tab.categoryName then
            local cat = GUI.Categories[tab.categoryName]
            if cat and not cat.expanded then
                cat.expanded = true
                cat.arrow:SetText("-")
                -- Persist state
                if DF.db and DF.db.party then
                    if not DF.db.party.guiExpandedCategories then
                        DF.db.party.guiExpandedCategories = {}
                    end
                    DF.db.party.guiExpandedCategories[cat.name] = true
                end
                GUI:UpdateTabLayout()
            end
        end
        
        -- Wide pages need extra width; set the resize bounds + expand BEFORE building the
        -- page so its content lays out at the final width instead of building narrow and
        -- staying squashed until a resize. (WIDE_PAGES + ApplyPageWidthBounds live at panel
        -- scope so ShowNormalContent shares them -- see the note there.)
        if ApplyPageWidthBounds(name) then
            -- Belt-and-braces: re-assert the width next frame so size-dependent
            -- layout settles without a manual resize. A page can build at a
            -- pre-layout width (tabs overflow the panel / cards squashed); nudging
            -- the width fires the same OnSizeChanged re-flows a resize would.
            C_Timer.After(0, function()
                if GUI.CurrentPageName ~= name or not frame:IsShown() then return end
                local w = frame:GetWidth()
                frame:SetWidth(w + 1)
                frame:SetWidth(w)
            end)
        end

        if GUI.Pages[name] then
            -- Set current tab for Search registration
            if DF.Search then
                local page = GUI.Pages[name]
                DF.Search:SetCurrentTab(page.tabName, page.tabLabel)
                DF.Search.CurrentSection = nil
            end
            
            -- Out of the dock and back under the content frame BEFORE the Show,
            -- so it is never shown while detached (and so RefreshCached below
            -- builds against the real geometry).
            GUI:AdoptPage(GUI.Pages[name])
            GUI.Pages[name]:Show()
            -- Tab switching uses the cache-aware path so revisiting a tab is cheap.
            GUI.Pages[name]:RefreshCached()
            if GUI.Pages[name].RefreshStates then GUI.Pages[name]:RefreshStates() end
        end
        local nc = GetThemeColor()
        if GUI.Tabs[name] then
            if GUI.Tabs[name].accent then
                GUI.Tabs[name].accent:Show()
                GUI.Tabs[name].accent:SetColorTexture(nc.r, nc.g, nc.b, 1)
            end
            GUI.Tabs[name].Text:SetTextColor(nc.r, nc.g, nc.b)
            GUI.Tabs[name].isActive = true
            -- Mark "New" badge as seen
            if GUI.Tabs[name].newBadge and GUI.Tabs[name].newBadge:IsShown() then
                GUI.Tabs[name].newBadge:Hide()
                if DandersFramesDB_v2 then
                    DandersFramesDB_v2.seenTabs = DandersFramesDB_v2.seenTabs or {}
                    DandersFramesDB_v2.seenTabs[name] = true
                end
                -- Hide parent category badge if no remaining children have new badges
                local catName = GUI.Tabs[name].categoryName
                local cat = catName and GUI.Categories[catName]
                if cat and cat.newBadge and cat.newBadge:IsShown() then
                    local anyNew = false
                    for _, child in ipairs(cat.children) do
                        if child.newBadge and child.newBadge:IsShown() then
                            anyNew = true
                            break
                        end
                    end
                    if not anyNew then cat.newBadge:Hide() end
                end
            end
        end
        GUI.CurrentPageName = name
        UpdateThemeColors()
    end
    GUI.SelectTab = SelectTab
    
    GUI.RefreshCurrentPage = function()
        -- ☠ THE SEARCH RESULTS RE-FLOW HERE TOO, and this is the only place they can.
        -- The results panel is not a page, so the page loop below never reaches it — yet
        -- it lays out in the same two columns and needs the same recompute when the
        -- window is resized (this function is what the resize handle's OnMouseUp calls).
        -- Without this the search grid kept whatever column geometry it had when the
        -- query ran, and its gutter did not track the window like every page does.
        -- It re-lays out only; it does not re-run the query.
        if DF.Search and DF.Search.LayoutResults
            and DF.Search.ResultsPanel and DF.Search.ResultsPanel:IsShown() then
            DF.Search:LayoutResults()
        end

        -- Don't refresh regular pages when in clicks mode (they use DF.db which doesn't have "clicks")
        if GUI.SelectedMode == "clicks" then
            return
        end
        if GUI.CurrentPageName and GUI.Pages[GUI.CurrentPageName] then
            -- Belt and braces for the reopen path: DF:ToggleGUI shows the window
            -- and then calls this, and the window's OnShow has already adopted
            -- the page by the time we get here -- but refreshing a page that is
            -- still in the dock would lay out against nothing, so make sure.
            -- No-ops when it is not parked.
            GUI:AdoptPage(GUI.Pages[GUI.CurrentPageName])
            GUI.Pages[GUI.CurrentPageName]:Refresh()
            if GUI.Pages[GUI.CurrentPageName].RefreshStates then
                GUI.Pages[GUI.CurrentPageName]:RefreshStates()
            end
            UpdateThemeColors()
        end
        -- Refresh override indicators
        RefreshAllOverrideIndicators()
        -- A designer preset bar can need re-reading even when its page skipped
        -- the rebuild (the sharing glyph tracks the OTHER mode's preset).
        if GUI.RefreshDesignerPresetBars then GUI:RefreshDesignerPresetBars() end
    end

    -- Invalidate EVERY page's build cache so the next time each tab is shown it
    -- rebuilds from scratch (via RefreshCached -> DoBuild). The page cache is
    -- keyed on mode (party/raid) only, NOT on the active auto-layout/profile, so
    -- switching between raid auto-layouts leaves cacheValid=true and tabs re-show
    -- stale geometry — most visibly the Aura Designer / Text Designer frame
    -- previews, which size their mock frame to the layout's frameWidth/Height at
    -- build time and so stay stuck at the first-edited layout's size. Call this
    -- whenever the active layout changes (enter/exit auto-profile editing).
    -- ☠ GUI.InvalidateAllPages was DEFINED TWICE, both inside DF:CreateGUI, so both ran on
    -- every panel build and the later one silently won. The copy that used to sit here had
    -- the `if not GUI.Pages` guard; the survivor did not, so the version actually in force
    -- was the less defensive of the pair. There is now one definition, further down, with
    -- the guard folded into it. Do not reintroduce a second.

    -- Category system
    GUI.Categories = {}
    local categoryY = -8
    
    local function CreateCategory(name, label)
        local cat = CreateFrame("Button", nil, tabContainer, "BackdropTemplate")
        cat:SetPoint("TOPLEFT", 4, categoryY)
        cat:SetPoint("TOPRIGHT", -4, categoryY)
        -- Placeholder only: UpdateTabLayout owns the real height and sets it to
        -- the row STRIDE so the rows tile with no dead band between them (see the
        -- comment there -- that band was the hover flash). Matched here so the
        -- row is never briefly the wrong size before the first layout pass.
        cat:SetHeight(SnapLen(cat, 30) or 30)
        -- Hover plate only: transparent at rest, tinted by OnEnter/OnLeave.
        CreateElementBackdrop(cat, { outline = false, bgColor = { 0, 0, 0, 0 } })
        cat.name = name
        cat.children = {}
        
        -- Restore saved state (default collapsed)
        local savedStates = DF.db and DF.db.party and DF.db.party.guiExpandedCategories
        cat.expanded = savedStates and savedStates[name] or false
        
        -- Expand/collapse indicator (simple minus/plus)
        cat.arrow = cat:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        cat.arrow:SetPoint("LEFT", 6, 0)
        cat.arrow:SetText(cat.expanded and "-" or "+")
        cat.arrow:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        
        cat.Text = cat:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        cat.Text:SetPoint("LEFT", 20, 0)
        cat.Text:SetText(label)
        cat.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        -- "New" badge for categories — shown when any child tab has a new badge
        local catNewBadge = cat:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        catNewBadge:SetPoint("RIGHT", cat, "RIGHT", -8, 0)
        catNewBadge:SetText(L["New"])
        catNewBadge:SetTextColor(1, 0.82, 0)
        catNewBadge:Hide()
        cat.newBadge = catNewBadge

        -- Hover is the SHARED moving plate, not this row's own backdrop -- see
        -- navHover. The row's backdrop stays permanently transparent (SelectTab
        -- still resets it, harmlessly).
        cat:SetScript("OnEnter", function(self) NavHoverShow(self, 0.3) end)
        cat:SetScript("OnLeave", function(self) NavHoverHide(self) end)
        cat:SetScript("OnClick", function(self)
            self.expanded = not self.expanded
            self.arrow:SetText(self.expanded and "-" or "+")
            -- Persist state
            if DF.db and DF.db.party then
                if not DF.db.party.guiExpandedCategories then
                    DF.db.party.guiExpandedCategories = {}
                end
                DF.db.party.guiExpandedCategories[self.name] = self.expanded or nil
            end
            GUI:UpdateTabLayout()
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        
        GUI.Categories[name] = cat
        -- Only add to CategoryOrder if not already in the explicit list (Options.lua sets it)
        local found = false
        for _, v in ipairs(GUI.CategoryOrder) do
            if v == name then found = true break end
        end
        if not found then
            tinsert(GUI.CategoryOrder, name)
        end
        categoryY = categoryY - 30
        return cat
    end
    
    -- `hidden`: build and register the page exactly as normal, but keep its row
    -- OUT of the sidebar. For a page that is DEPRECATED but not yet deleted --
    -- the code stays whole and greppable, GUI.Pages/GUI.Tabs still resolve so
    -- nothing that walks them has to special-case it, and deleting one word at
    -- the call site puts the page back. See DEPRECATED-TARGETED-SPELLS.
    local function CreateSubTab(categoryName, name, label, hidden)
        local cat = GUI.Categories[categoryName]
        if not cat then return end
        
        local btn = CreateFrame("Button", nil, tabContainer, "BackdropTemplate")
        btn:SetHeight(SnapLen(btn, 28) or 28)   -- placeholder; see CreateCategory
        -- Hover/selected plate only: the accent bar carries the selected state.
        CreateElementBackdrop(btn, { outline = false, bgColor = { 0, 0, 0, 0 } })
        btn.isTab = true
        btn.tabName = name
        btn.categoryName = categoryName
        
        -- Left accent bar
        btn.accent = btn:CreateTexture(nil, "OVERLAY")
        btn.accent:SetPoint("TOPLEFT", 0, 0)
        btn.accent:SetPoint("BOTTOMLEFT", 0, 0)
        btn.accent:SetWidth(3)
        btn.accent:Hide()
        
        btn.Text = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        btn.Text:SetPoint("LEFT", 24, 0)
        btn.Text:SetText(label)
        btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

        -- "New" badge — shown for tabs in GUI.NewTabs until the user opens them
        local newBadge = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        newBadge:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
        newBadge:SetText(L["New"])
        newBadge:SetTextColor(1, 0.82, 0)
        newBadge:Hide()
        btn.newBadge = newBadge
        if GUI.NewTabs[name]
           and not (DandersFramesDB_v2 and DandersFramesDB_v2.seenTabs
                    and DandersFramesDB_v2.seenTabs[name]) then
            newBadge:Show()
            -- Also show "New" on the parent category
            if cat and cat.newBadge then
                cat.newBadge:Show()
            end
        end

        -- Shared moving plate (see navHover). The active tab still shows no hover
        -- tint -- its accent bar and label colour are its state -- so crossing it
        -- parks the plate rather than moving it.
        btn:SetScript("OnEnter", function(self)
            if not self.isActive then NavHoverShow(self, 0.5) end
        end)
        btn:SetScript("OnLeave", function(self) NavHoverHide(self) end)
        btn:SetScript("OnClick", function(self)
            if self.disabled then return end
            SelectTab(name)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
        
        -- Create the page
        local page = CreateFrame("ScrollFrame", nil, content, "ScrollFrameTemplate")
        -- ★ The insets are SNAPPED, and this is the frame the whole pixel grid
        -- was hanging off. A ScrollFrame clips to its own rect, so its top edge is
        -- the boundary every box near the top of a page is cut against -- and a
        -- raw 8-unit inset is 11.25 DEVICE PIXELS at 0.75 scale, i.e. a quarter
        -- pixel off the grid. /df debug pixelcheck measured exactly that: viewport
        -- top-0.25, scroll child top-0.25 (it inherits the phase), while every
        -- box inside reported a flawless top+0.00. The boxes were never the
        -- problem; the surface they are clipped against was.
        --
        -- Nothing corrects it afterwards -- this frame is anchored by TWO
        -- corners, so even the geometry correction that used to exist skipped it
        -- (nudging a two-corner frame resizes it rather than moving it). The one
        -- surface every page is measured against was the one it could not touch.
        -- Snapping the OFFSETS is the fix that works for a two-corner frame:
        -- correct the numbers going in, since the box itself can't be nudged.
        --
        -- ⚠ `content` IS NAMED EXPLICITLY, and the inset is kept on the page.
        -- A page is reparented to the page dock whenever it is not the one on
        -- screen (see THE PAGE DOCK), and these two points have to keep pointing
        -- at the content frame across that trip -- a parked page that measured
        -- zero could not be built, and search builds all of them. GUI:AdoptPage
        -- re-asserts exactly these two lines from page._contentInset.
        local inset = SnapLen(content, 8) or 8
        page._contentInset = inset
        page:SetPoint("TOPLEFT", content, "TOPLEFT", inset, -inset)
        page:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -inset, inset)

        StyleScrollBar(page)

        local child = CreateFrame("Frame", nil, page)
        -- Snapped for the same reason: content is positioned against this child,
        -- so a fractional width put every right edge inside it off-grid too
        -- (pixelcheck reported w-0.16).
        child:SetSize(SnapLen(page, (content:GetWidth() or 0) - 30) or 1, 1)
        page:SetScrollChild(child)
        page.child = child
        page.tabName = name
        page.tabLabel = label
        page:Hide()
        page.Refresh = function() end
        
        GUI.Tabs[name] = btn
        GUI.Pages[name] = page
        if hidden then
            -- Staying out of cat.children is what actually hides it: UpdateTabLayout
            -- only ever anchors and sizes that list, so this row is never given a
            -- position. Hidden explicitly too, so nothing rests on that detail.
            btn:Hide()
        else
            table.insert(cat.children, btn)
        end

        return page
    end
    
    -- Declared PRESENTATION order for a category, plus the caption rows that break
    -- it into groups. Entries are page ids, or { caption = "..." }.
    --
    -- ⚠ Separate from creation order on purpose. A category's pages are created
    -- across several files in a chain (the Auras rows come from three), so the order
    -- they land in cat.children is a build detail -- reshuffling THAT to change the
    -- sidebar would mean moving page builders between files and rethreading the
    -- arguments they are handed. This declares what the reader sees and leaves the
    -- build alone.
    --
    -- Resolved lazily in UpdateTabLayout rather than here, so it does not matter
    -- whether the pages this names exist yet when it is called.
    function GUI:SetNavOrder(categoryName, spec)
        local cat = self.Categories[categoryName]
        if cat then cat.navSpec = spec end
    end

    -- Update tab positions based on expanded/collapsed state
    function GUI:UpdateTabLayout()
        -- Every number here is snapped, and the running `y` is built ONLY out of
        -- snapped steps, so each row lands on the pixel grid rather than each one
        -- picking up a different sub-pixel phase down the list. The nav rows are
        -- two-corner anchored, so nothing downstream could correct
        -- them (and would not anyway -- they are not structural boxes): the
        -- offsets going in are the only lever, same as the page viewport.
        --
        -- The rows TILE: each one's height IS the stride to the next, so there is
        -- no strip between them where the cursor is over nothing.
        --
        -- They used to be 28 tall on a 30 stride (and 26 on 28), leaving a 2-unit
        -- dead band -- about 3 device pixels -- between every pair. /df debug navprobe
        -- caught what that costs: crossing the band puts mouse focus on the plain
        -- container Frame behind the list for a single frame, with NO row lit, so
        -- the hover plate blinks off and back on mid-sweep. That one dark frame is
        -- the "ghost" -- and because whether you land in the band depends on how
        -- fast you are moving, the same crossing sometimes flashed and sometimes
        -- did not, which is why it looked like a render hitch rather than layout.
        --
        -- Tiling costs nothing visually: only one row is ever lit, so the plates
        -- have no neighbour to sit flush against. The height is taken FROM the
        -- stride rather than snapped separately, so they cannot disagree by a
        -- pixel and reopen a hairline gap.
        -- Park the shared hover plate: expanding or collapsing can hide the row it
        -- is anchored to, and a plate anchored to a hidden frame is a stray.
        if GUI.HideNavHover then GUI.HideNavHover() end

        local container = GUI.tabContainer
        local y = SnapLen(container, -8) or -8
        local catStride = SnapLen(container, 30) or 30
        local tabStride = SnapLen(container, 28) or 28
        -- Captions get a shorter stride than a tab: they are a label, not a target,
        -- and giving them a full row makes the group they head look detached from it.
        local capStride = SnapLen(container, 20) or 20

        -- The rows to lay out for a category, in reading order. Without a navSpec
        -- that is just cat.children (creation order, as before).
        --
        -- ⚠ Only rows that are ALREADY in cat.children may be placed. A hidden page
        -- stays out of that list -- that absence is the entire hiding mechanism (see
        -- CreateSubTab) -- while remaining present in GUI.Tabs, so resolving the spec
        -- through GUI.Tabs alone would put hidden pages back on screen.
        local function NavRows(cat)
            if not cat.navSpec then return cat.children end
            local placeable, rows, taken = {}, {}, {}
            for _, btn in ipairs(cat.children) do placeable[btn] = true end
            cat.navCaptions = cat.navCaptions or {}
            for i, entry in ipairs(cat.navSpec) do
                if type(entry) == "table" and entry.caption then
                    -- Materialised on first layout and reused by spec INDEX, so a
                    -- relayout does not leak a frame per pass.
                    local f = cat.navCaptions[i]
                    if not f then
                        f = CreateFrame("Frame", nil, container)
                        f.isNavCaption = true
                        f.Text = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                        -- 9px: a step under Small (10) and well under the page rows
                        -- it heads, so it reads as a divider rather than as another
                        -- entry in the list. The caption text is written UPPERCASE in
                        -- the locale, not upper-cased here -- see the note on
                        -- L["FILTERS"].
                        GUI:SetSettingsFont(f.Text, 9, "")
                        f.Text:SetPoint("BOTTOMLEFT", 14, 3)
                        f.Text:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                        cat.navCaptions[i] = f
                    end
                    f.Text:SetText(entry.caption)
                    rows[#rows + 1] = f
                else
                    local btn = GUI.Tabs[entry]
                    if btn and placeable[btn] then
                        taken[btn] = true
                        rows[#rows + 1] = btn
                    end
                end
            end
            -- Anything the spec does not name still gets placed, at the end. A page
            -- added later must appear in the sidebar even if nobody updated the spec;
            -- silently dropping it would be a page you cannot reach.
            for _, btn in ipairs(cat.children) do
                if not taken[btn] then rows[#rows + 1] = btn end
            end
            return rows
        end

        for _, catName in ipairs(GUI.CategoryOrder) do
            local cat = GUI.Categories[catName]
            if cat then
                cat:ClearAllPoints()
                cat:SetPoint("TOPLEFT", 0, y)
                cat:SetPoint("TOPRIGHT", 0, y)
                cat:SetHeight(catStride)
                y = y - catStride

                local rows = NavRows(cat)
                if cat.expanded then
                    for _, btn in ipairs(rows) do
                        -- Party-only tabs are hidden entirely in raid mode.
                        if btn.partyOnly and GUI.SelectedMode == "raid" then
                            btn:Hide()
                        else
                            local stride = btn.isNavCaption and capStride or tabStride
                            btn:Show()
                            btn:ClearAllPoints()
                            btn:SetPoint("TOPLEFT", 0, y)
                            btn:SetPoint("TOPRIGHT", 0, y)
                            btn:SetHeight(stride)
                            y = y - stride
                        end
                    end
                else
                    for _, btn in ipairs(rows) do
                        btn:Hide()
                    end
                end
            end
        end
        
        -- Update scroll child height
        local totalHeight = math.abs(y) + 20
        GUI.tabContainer:SetHeight(totalHeight)
    end

    -- Re-sync each category's expanded state from the current profile's saved
    -- state and relayout the sidebar. Categories read their state once at
    -- creation, so a profile switch needs this to reflect the new profile's
    -- expanded/collapsed tabs without a /reload.
    function GUI:RefreshCategoryStates()
        local saved = DF.db and DF.db.party and DF.db.party.guiExpandedCategories
        for name, cat in pairs(self.Categories) do
            cat.expanded = (saved and saved[name]) or false
            if cat.arrow then cat.arrow:SetText(cat.expanded and "-" or "+") end
        end
        self:UpdateTabLayout()
    end

    -- Store category order
    GUI.CategoryOrder = {}
    
    -- (Removed) CreateTab — "legacy single tab support", a thin wrapper over
    -- CreateSubTab("tools", ...). Every page registers through CreateSubTab directly
    -- now, so it had no callers.

    local function BuildPage(page, builderFunc)
        -- Internal: construct all widget frames for the current mode.
        -- Called on first visit and whenever the cache is invalidated.
        -- Always finishes by calling RefreshStates() so callers don't need to.
        local function DoBuild(self)
            local db = DF.db[GUI.SelectedMode]
            if not db then return end

            -- Retire old children: hide, detach anchors, and reparent to the
            -- trash frame so they leave the GUI frame hierarchy entirely.
            -- WoW cannot GC frames, but a detached subtree is not traversed
            -- during drag layout recalculation.
            if self.children then
                local trash = GUI._trashFrame
                for _, child in ipairs(self.children) do
                    child:Hide()
                    child:ClearAllPoints()
                    if trash then child:SetParent(trash) end
                end
            end
            self.children = {}
            self.child.ThemeListeners = {}
            -- Propagate RefreshStates to child so widgets can call it
            self.child.RefreshStates = function() self:RefreshStates() end
            local parent = self.child

            -- col = 1, 2, or "both". THE PAGE LAYOUT STANDARD lives here, because
            -- this is the call that decides it and the only thing every page has
            -- in common:
            --
            --   column 1 -- structure and geometry, in this order:
            --               Settings -> [Layout] -> [Size] -> Position
            --   column 2 -- styling, in this order:
            --               Appearance -> Border -> element extras (text, bars)
            --   "both"   -- ONLY on a page that genuinely needs the width
            --               (Pinned Frames, Nicknames). It is also a sync point:
            --               it takes the lower of the two columns and drops both
            --               to it, whether or not you wanted that.
            --
            -- Columns rather than a flat order, because a page is read as two
            -- columns and not as a sequence -- putting Appearance third and
            -- Border fifth still separates them on screen if they land on
            -- opposite sides. Grouping by column keeps the two natural pairs
            -- (Layout+Position, Appearance+Border) together where the eye is.
            --
            -- ⚠ The split only MEANS anything where both categories are present.
            -- A surface holding nothing but geometry (an aura page's Layout
            -- section) or nothing but styling (its Appearance section) has no
            -- left/right distinction to preserve, so its boxes fill both columns
            -- for balance and reading order instead. Forcing the rule there
            -- empties one column, which is worse than the inconsistency it was
            -- meant to fix.
            --
            -- Sections (GUI:CreateCollapsibleSection) hold a page's boxes when
            -- the page needs a second level -- either PARALLEL SUB-FEATURES
            -- (Icons, Highlights, Health Bar) or broad CATEGORIES whose box
            -- names only make sense inside them (the aura pages, where Layout
            -- and Duration Bar each contain their own "Settings" box). The rule
            -- above then applies within each section rather than across the
            -- page. A page that needs neither stays as plain boxes.
            local function Add(widget, height, col)
                table.insert(self.children, widget)
                widget:SetParent(parent)
                widget.layoutHeight = ResolveRowHeight(widget, height)
                widget.layoutCol = col or 1
                return widget
            end

            -- Disabled-mode handling: when the current mode is off in General
            -- settings, replace the page content with a single banner instead
            -- of rendering any controls. Whitelisted pages (General, Profiles,
            -- Debug, Targeted List, Personal Targeted) always render normally.
            if GUI:IsTabDisabledForCurrentMode(self.tabName) then
                local banner = GUI:CreateInfoBanner(parent, { tone = "info" })
                banner:SetText(GUI.SelectedMode == "raid"
                    and (L["Raid frames are currently disabled. Changes here will apply after re-enabling Raid in the General tab and reloading."])
                    or  (L["Party frames are currently disabled. Changes here will apply after re-enabling Party in the General tab and reloading."]))
                table.insert(self.children, banner)
                banner.layoutCol = "both"
                self.builtForMode = GUI.SelectedMode
                self.builtForDisabled = true
                self.cacheValid = true
                self:RefreshStates()
                return
            end

            local function AddSpace(h, col)
                local spacer = CreateFrame("Frame", nil, parent)
                spacer:SetSize(1, h)
                spacer.layoutHeight = h
                spacer.layoutCol = col or "both"
                table.insert(self.children, spacer)
                return spacer
            end

            -- Sync point: forces both columns to align to the same Y position
            local function AddSyncPoint()
                local sync = CreateFrame("Frame", nil, parent)
                sync:SetSize(1, 1)
                sync.isSyncPoint = true
                sync.layoutHeight = 0
                sync.layoutCol = "both"
                table.insert(self.children, sync)
            end

            builderFunc(self, db, Add, AddSpace, AddSyncPoint)
            self.builtForMode = GUI.SelectedMode
            self.builtForDisabled = false
            self.cacheValid = true
            self:RefreshStates()
        end

        -- Invalidate this page's cache so the next RefreshCached() rebuilds.
        page.Invalidate = function(self)
            self.cacheValid = false
            self.builtForMode = nil
        end

        -- Cache-aware refresh — used ONLY by tab switching. If the cached build
        -- is still valid for the current mode and enabled/disabled state, run the
        -- cheap visibility/layout pass; otherwise rebuild. This is the perf path
        -- that makes revisiting a tab cheap.
        page.RefreshCached = function(self)
            local db = DF.db[GUI.SelectedMode]
            -- Guard against nil db (e.g., when "clicks" mode is selected)
            if not db then return end

            local isDisabled = GUI:IsTabDisabledForCurrentMode(self.tabName)
            if self.cacheValid
               and self.builtForMode == GUI.SelectedMode
               and self.builtForDisabled == isDisabled then
                self:RefreshStates()
                return
            end

            -- Cache miss: build fresh for this mode.
            -- DoBuild sets cacheValid and calls RefreshStates() before returning.
            DoBuild(self)
        end

        -- Refresh() ALWAYS rebuilds. This is its historical contract: callers
        -- invoke it after mutating data (adding/removing list items, reset/copy/
        -- sync, profile changes, etc.) and rely on the page being reconstructed.
        -- Only tab switching uses the cache, via RefreshCached().
        page.Refresh = function(self)
            local db = DF.db[GUI.SelectedMode]
            -- Guard against nil db (e.g., when "clicks" mode is selected)
            if not db then return end
            DoBuild(self)
        end

        -- ☠ DISPATCHED BY NAME, not captured. The profiler instruments a target
        -- by REPLACING DF.GUI.PageRefreshStates, and every page is built the
        -- first time the window opens -- long before a profiling run starts --
        -- so a page holding the function VALUE would keep calling the unwrapped
        -- original and the target would read zero calls forever.
        page.RefreshStates = function(self) return GUI.PageRefreshStates(self) end
    end
    
    -- Trash frame: detached from the GUI hierarchy. Old page children are
    -- reparented here on rebuild so they don't contribute to the frame
    -- traversal cost during window drag layout recalculation.
    GUI._trashFrame = CreateFrame("Frame")
    GUI._trashFrame:Hide()

    -- Invalidate all page caches (call before profile/mode switches so each
    -- page rebuilds with a fresh db reference on its next visit).
    -- ☠ THE ONLY DEFINITION. A second one used to exist earlier in this same function and
    -- was shadowed by this one at every panel build; the guard below came from that copy.
    -- Callers guard the FUNCTION but not the TABLE, so the guard has to live here.
    function GUI:InvalidateAllPages()
        if not self.Pages then return end
        for _, page in pairs(self.Pages) do
            if page.Invalidate then page:Invalidate() end
        end
    end

    -- Invalidate a single page by name.
    function GUI:InvalidatePage(name)
        local page = self.Pages[name]
        if page and page.Invalidate then page:Invalidate() end
    end

    -- Load pages from Options file
    if DF.SetupGUIPages then
        DF:SetupGUIPages(GUI, CreateCategory, CreateSubTab, BuildPage)
    end
    
    -- Setup Auto Profiles editing banner
    if DF.AutoProfilesUI and DF.AutoProfilesUI.SetupEditingBanner then
        DF.AutoProfilesUI:SetupEditingBanner()
    end
    
    -- Update tab layout after all tabs created
    GUI:UpdateTabLayout()

    UpdateThemeColors()

    -- Apply tab availability for current mode (greys out disabled-mode tabs)
    GUI:UpdateTabAvailability()

    -- Select first subtab
    if GUI.CategoryOrder[1] then
        local firstCat = GUI.Categories[GUI.CategoryOrder[1]]
        if firstCat and firstCat.children[1] then
            SelectTab(firstCat.children[1].tabName)
        end
    end
end

-- ============================================================
-- FADED CLOSE FOR /df
-- DF:ToggleGUI (GUI/Controls.lua:3616) hides an open window instantly on the
-- close half of its toggle. Wrap it here -- this file loads after Controls.lua
-- (companion TOC order) -- so `/df` on an open window fades it out (0.25s,
-- DandersUI UI.Fx) before hiding, matching the close button above.
-- Guards:
--  * `/df` again while the fade-out runs REOPENS (cancels the fade and fades
--    back in) instead of stacking a second close -- a double-toggle can never
--    strand the window mid-fade.
--  * Esc (UISpecialFrames) and any direct :Hide() stay instant; hiding
--    mid-fade stops the animation and FadeOut skips its deferred Hide.
--  * The open half is untouched -- it delegates to the original, so mode
--    detection, accent, changelog-on-update all behave exactly as before.
-- ============================================================
local origToggleGUI = DF.ToggleGUI
function DF:ToggleGUI(...)
    local f = DF.GUIFrame
    if f and f:IsShown() then
        if f.fxOut and f.fxOut:IsPlaying() then
            GUI.Fx.FadeIn(f, 0.3)
            return
        end
        GUI.Fx.FadeOut(f, 0.25, function() f:Hide() end)
        return
    end
    return origToggleGUI(self, ...)
end
