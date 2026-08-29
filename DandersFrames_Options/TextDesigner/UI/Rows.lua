-- Part 2 of the Text Designer editor: the POPOUT LAYOUT's page.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`).
local DF = DandersFrames
local L = DF.L
local GUI = DF.GUI
local P = DF.TextDesigner._priv

local ipairs, pairs, type = ipairs, pairs, type
local format = string.format
local max = math.max
local wipe = wipe

-- Aliases of what TextDesigner/UI/Options.lua built. Load-time constants: this
-- file is listed after that one in the companion's manifest.
local FindContentType        = P.FindContentType
local CATEGORY_COLORS        = P.CATEGORY_COLORS
local ElementDefaultsRecord  = P.ElementDefaultsRecord
local GlobalDefaultsRecord   = P.GlobalDefaultsRecord
local BuildContentSection    = P.BuildContentSection
local BuildGroupItemsSection = P.BuildGroupItemsSection
local BuildAppearanceSection = P.BuildAppearanceSection
local BuildPositionSection   = P.BuildPositionSection
local BuildGlobalTab         = P.BuildGlobalTab
local BuildTextsHeadArea     = P.BuildTextsHeadArea
local BuildGroupsHeadArea    = P.BuildGroupsHeadArea
local CreateEnableBanner     = P.CreateEnableBanner
local GetState               = P.GetState

-- ...and the ONE thing this page borrows from the other designer: its frame
-- canvas. Decision 4 of the designer rework -- the Text Designer had its own,
-- poorer copy of the same mock frame, and two mock frames is two places for the
-- real frame's anatomy to be described. Read at CALL time through a local
-- resolved at load, and the manifest loads the Aura Designer's card file first.
local AD = DF.AuraDesigner and DF.AuraDesigner._priv

-- The enable bar (44) plus the preset bar (24) and the gap between them.
local BANNER_H = 76
-- The canvas band's FLOOR. Its actual height is AD's CanvasWantedHeight, which
-- grows with the preview scale; this is what that returns at 1.0.
local CANVAS_H = 132

-- The width a pane's contents are built at, asked for rather than guessed -- the
-- same constant CreatePopoutPageTools mounts its groups at. Read at CALL time:
-- the kit publishes it at load, and a file-scope copy would freeze whatever was
-- there when this file parsed.
local function PopoutWidth() return GUI.PopoutContentWidth or 260 end

-- ============================================================
-- THE ROW REGISTRY, AND WHY A REBUILD RE-OPENS A PANEL
-- ------------------------------------------------------------
-- ☠ A STRUCTURAL CHANGE INSIDE A PANE HAS NO SMALLER REBUILD THAN THE PAGE'S.
-- Adding a group item, removing one, reordering, or pressing Customise on one
-- all change WHAT IS IN the Items pane -- not merely which of its widgets show
-- -- and the popout kit builds a pane's contents once. The only rebuild the
-- harness offers is the page's, and every route into a page builder closes every
-- open panel first (CreatePopoutPageTools says why), so the panel the click
-- landed in would shut under the user's hand.
--
-- So the open panel's NAME is remembered across the rebuild and re-opened on the
-- other side. Deliberately by title rather than by identity: the rebuild retires
-- every row and mints new ones, so there is no object to hold on to.
--
-- ⚠ The Aura Designer solves the same problem differently (ADStructuralRedraw
-- re-flows the pane) because its in-pane changes only REVEAL a sibling that was
-- already built. That answer does not reach this one.
-- ============================================================
local rowsByTitle = {}
local reopenTitle

P.RowsRedraw = function(page)
    reopenTitle = nil
    for title, row in pairs(rowsByTitle) do
        if row.popout then reopenTitle = title break end
    end
    -- Deferred: several call sites reach this from inside the click handler of a
    -- button the rebuild is about to retire.
    if page and page.Refresh and C_Timer and C_Timer.After then
        C_Timer.After(0, function() if page.Refresh then page:Refresh() end end)
    end
end

-- ============================================================
-- ONE ELEMENT'S ROWS
-- ------------------------------------------------------------
-- ☠ THE ELEMENT ITSELF IS EXPAND-ONLY. It is a way in to three or four groups,
-- not a group, so a panel on it would be a panel that had to contain more -- and
-- the popout system is deliberately ONE level deep. The element is a collapsible
-- SECTION whose header carries the identity (the name, the anchor summary, the
-- eye and the delete), and the rows in the band under it each own one panel.
--
-- ☠ AND A COLLAPSED ELEMENT BUILDS NO ROWS AT ALL. A popout row's pane is built
-- EAGERLY, at page-build time, so "a row is cheap because its pane is lazy" is
-- false -- what is cheap is not adding the rows.
-- ============================================================

-- What a write behind any of this element's rows costs. Handed to every row's
-- footer, so Reset Group and Hold: Defaults drive exactly what the controls' own
-- callbacks drive.
local function ApplyElementGroup()
    if DF.TextDesigner.Preview then DF.TextDesigner.Preview:RefreshAll() end
end

-- The element's display name, the same one the card header shows.
local function ElementTitle(elem, ct)
    if type(elem.label) == "string" and elem.label ~= "" then return elem.label end
    if elem.contentType == "group" then return L["Text Group"] end
    return (ct and ct.label) or tostring(elem.contentType)
end

-- The one-line status the section header carries beside its title -- the card's
-- own meta line: "CENTER · 0,0 · → Name".
local function MetaText(elem, tdDB)
    if elem.contentType == "group" then
        local n = #(elem.groupItems or {})
        return format("(%d %s)", n, (n == 1) and L["item"] or L["items"])
    end
    local s = (elem.anchor or "CENTER") .. " \194\183 " .. (elem.offsetX or 0) .. "," .. (elem.offsetY or 0)
    if elem.anchorTo and elem.anchorTo ~= "FRAME" then
        local targetID = tonumber(elem.anchorTo)
        if targetID and tdDB and tdDB.elements then
            for _, e in ipairs(tdDB.elements) do
                if e.id == targetID then
                    s = s .. " \194\183 \226\134\146 " .. ElementTitle(e, FindContentType(e.contentType))
                    break
                end
            end
        end
    end
    return s
end

-- ctx carries what BuildPage handed the builder plus the shared popout
-- machinery: { page, db, Add, AddSpace, tools, tdDB, state, tdEnabled }.
local function MountElement(ctx, elem)
    local page, tools, Add = ctx.page, ctx.tools, ctx.Add
    local tdDB, state = ctx.tdDB, ctx.state
    local bandW = tools.BandWidth()
    local isGroup = elem.contentType == "group"
    local ct = FindContentType(elem.contentType)
    local catColor = isGroup and CATEGORY_COLORS.group or (ct and CATEGORY_COLORS[ct.category])
    local title = ElementTitle(elem, ct)

    local section = GUI:CreateCollapsibleSection(page.child, title, false, bandW)

    -- ⚠ THE FOLD STATE IS THE CARD LAYOUT'S OWN KEY, NOT THE TITLE. The section
    -- factory reads and writes the shared per-title store, and these titles are
    -- USER-EDITABLE LABELS -- one permanent profile key per element per rename,
    -- accumulating forever, which is a schema change smuggled in under a pure
    -- re-presentation. The card already persists this fold under a stable
    -- "td_elem_<id>" / "td_group_<id>" key; that is the key this uses, so the
    -- two layouts agree about what is open and no new key is added. Toggle is
    -- REPLACED rather than hooked so the factory's own title write never runs.
    local foldKey = (isGroup and "td_group_" or "td_elem_") .. tostring(elem.id)
    local saved = GUI:GetCollapsedGroups()
    section.expanded = not saved[foldKey]
    section.arrow:SetTexture(section.expanded
        and "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more"
        or  "Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
    section.Toggle = function(self)
        saved[foldKey] = self.expanded and true or nil
        -- A rebuild, not a state pass: the rows under a collapsed element are not
        -- BUILT, so there is nothing for RefreshStates to reveal.
        if page.Refresh then page:Refresh() end
    end

    -- The card's category tint on the header title. Routed through UpdateTheme
    -- rather than set once, because that is what SetPreviewDimmed and the theme
    -- listener both drive -- a plain SetTextColor here would be repainted by the
    -- next theme change.
    if catColor then
        section.title.UpdateTheme = function()
            if section.previewDimmed then
                section.title:SetTextColor(0.5, 0.5, 0.5)
            else
                section.title:SetTextColor(catColor.r, catColor.g, catColor.b, catColor.a)
            end
        end
        section.title.UpdateTheme()
    end
    section:SetTag(MetaText(elem, tdDB))
    -- The header greys with the feature, exactly as the section headers on every
    -- other converted page do.
    if not ctx.tdEnabled and section.SetPreviewDimmed then section:SetPreviewDimmed(true) end

    -- ── THE HEADER'S TWO ACTIONS ──
    local delBtn = GUI:CreateCloseButton(section, {
        size = 22,
        onClick = function()
            for i, e in ipairs(tdDB.elements) do
                if e.id == elem.id then
                    table.remove(tdDB.elements, i)
                    break
                end
            end
            saved[foldKey] = nil
            DF:Debug("TD", "Deleted element id=%d (remaining=%d)", elem.id, #tdDB.elements)
            if P.FullRebuildCards then P.FullRebuildCards(GUI, page, tdDB, state) end
        end,
    })
    delBtn:SetPoint("RIGHT", -6, 0)
    delBtn:SetFrameLevel(section:GetFrameLevel() + 2)

    -- The eye: shown / hidden, on the raw element table.
    do
        local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
        local eyeBtn = GUI:CreateGlyphButton(section, { size = 18 })
        eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
        eyeBtn:SetFrameLevel(section:GetFrameLevel() + 2)
        local function updateEyeIcon()
            if elem.enabled then
                eyeBtn:SetGlyph(mediaPath .. "visibility", { 0.95, 0.95, 0.95 })
            else
                eyeBtn:SetGlyph(mediaPath .. "visibility_off", { 0.45, 0.45, 0.45 })
            end
            eyeBtn:SetGlyphHover(elem.enabled)
        end
        updateEyeIcon()
        eyeBtn:RegisterForClicks("LeftButtonUp")
        eyeBtn:SetScript("OnClick", function()
            elem.enabled = not elem.enabled
            updateEyeIcon()
            DF:Debug("TD", "Element %d enabled=%s", elem.id, tostring(elem.enabled))
            if DF.TextDesigner.Preview then DF.TextDesigner.Preview:RefreshAll() end
        end)
    end

    -- ☠ AND NOW SAY WHAT THE RIGHT END COST. The title and the meta tag run
    -- rightward from the arrow with no edge of their own, and the eye and the
    -- delete run leftward from the other side; on the 850px island the two never
    -- met, and on the ~410px band a 640px window gives this page they do -- and
    -- an element's title is a label the user typed. 56 = the delete (22 at -6)
    -- plus the eye (18, 4 to its left).
    if section.SetHeaderRightInset then section:SetHeaderRightInset(56) end

    Add(section, 36, "both")

    if not section.expanded then return end

    -- ── THE BAND OF ROWS ──
    -- Headerless: the section's own header is this element's name, which is the
    -- Modules page's rule for a band inside a section.
    local band = GUI:CreateSettingsGroup(page.child, tools.BandWidth(), { chromeless = true })
    section:RegisterChild(band)

    -- ☠ THE ROW'S db IS THE DEFAULTS RECORD, NOT `elem` AND NOT DF.db[mode]. The
    -- diff engine understands three tables and a text element is none of them, so
    -- handed `elem` every row's amber tick would be permanently dark and Reset
    -- Group would write nothing while saying it had -- silently, no error either
    -- way. The record is the view that carries the phase-0 adapter
    -- (__dfDefaultsAdapter, TextDesigner/UI/Options.lua), which answers "is this
    -- key modified" for an element by comparing against the Global tab's value
    -- for the five overridable fields and against the shipped literal for the
    -- rest.
    --
    -- ☠ AND ONLY THE ROW'S. Every CONTROL still binds to `elem`, exactly as it
    -- does in the split panel, because a write THROUGH the record marks the
    -- override flag (see its __newindex) -- so binding the appearance controls to
    -- it would pin all five fields the moment a panel was built and stop the
    -- element following the Global tab at all. The record is the diff engine's
    -- view of the element; it is not the widgets' table.
    local record = ElementDefaultsRecord(elem, tdDB)
    local RowRecord = function() return record end

    -- ☠ THE FEATURE SWITCH GREYS THE ROWS, NOT ONE SHEET OVER THE PAGE. The split
    -- panel drew a disabled overlay across its whole lower half; a column of bands
    -- has no such surface, and the page's own state pass greys widgets that answer
    -- to disableOn -- which a popout row does and a plain band host does not. A
    -- dimmed row still OPENS, so the settings stay readable while switched off.
    local function AlwaysOff() return true end

    -- The card shim. The three section builders talk to a `card` for two things
    -- only: repainting the title after a Label edit, and refreshing the meta line
    -- after an anchor or offset change. Here the section header IS both.
    local card = {
        title         = section.title,
        titleCatColor = catColor,
    }
    card.UpdateMeta = function() section:SetTag(MetaText(elem, tdDB)) end

    local function AddRow(label, build)
        local rowTitle = format("%s \226\128\148 %s", title, label)
        local mount, content = tools.PopoutContent(function(group, holder, reflow)
            build(group, holder, reflow)
        end)
        local row = band:AddWidget(GUI:CreatePopoutRow(page.child, {
            label   = label,
            title   = rowTitle,
            db      = RowRecord,
            -- Derived, never declared: the pane is built eagerly a line above, so
            -- the badge's number is the number of controls actually in it, which
            -- varies by content type.
            count   = content and content.groupChildren and #content.groupChildren or nil,
            window  = DF.GUIFrame,
            clipTo  = page,
            build   = mount,
        }))
        if not ctx.tdEnabled then row.disableOn = AlwaysOff end
        tools.ClaimKeys(row, content)
        tools.WireModifiedTick(row)
        tools.WireFooter(row, ApplyElementGroup, RowRecord)
        rowsByTitle[rowTitle] = row
        return row
    end

    -- ── CONTENT: the label, and whatever this content type's own fields are ──
    AddRow(L["Content"], function(group, holder)
        holder:SetWidth(PopoutWidth())
        BuildContentSection(GUI, holder, elem, tdDB, state, page, card, 0, false, group)
    end)

    -- ── ITEMS: a text group's members, and nothing else has them ──
    if isGroup then
        AddRow(L["Items"], function(group, holder)
            holder:SetWidth(PopoutWidth())
            BuildGroupItemsSection(GUI, holder, elem, tdDB, state, page, card, 0, group)
        end)
    end

    -- ── APPEARANCE: the five overridable fields, plus the shadow tick ──
    AddRow(L["Appearance"], function(group, holder)
        holder:SetWidth(PopoutWidth())
        BuildAppearanceSection(GUI, holder, elem, card, 0, group)
    end)

    -- ── POSITION: the anchor grid, the two offsets and the anchor target ──
    AddRow(L["Position"], function(group, holder)
        holder:SetWidth(PopoutWidth())
        BuildPositionSection(GUI, holder, elem, tdDB, card, 0, group)
    end)

    Add(band, nil, "both")
end

-- ============================================================
-- THE THREE TABS
-- ============================================================

-- Texts and Text Groups are the same shape over a different filter: the tab's own
-- head area (the add CTA, the caption, and on Texts the category chips) as one
-- full-width object, then one section per element.
local function BuildElementListTab(ctx, shell, wantGroups)
    local page, tools, Add = ctx.page, ctx.tools, ctx.Add
    local tdDB, state = ctx.tdDB, ctx.state

    -- ⚠ STILL THE SPLIT PANEL'S OWN FURNITURE, mounted as one full-width object.
    -- The add flow is a later phase of the rework; when it lands it lands for both
    -- layouts at once, because there is one copy of it.
    GUI:AddDesignerLegacyTab(shell, function(host)
        host:SetWidth(tools.BandWidth())
        local h
        if wantGroups then
            h = BuildGroupsHeadArea(GUI, host, state, tdDB, page, 0)
        else
            h = BuildTextsHeadArea(GUI, host, state, tdDB, page, 0)
        end
        host:SetHeight(max(h or 1, 1))
    end)

    local shown = {}
    for _, elem in ipairs(tdDB.elements or {}) do
        local isGroup = elem.contentType == "group"
        if isGroup == wantGroups then
            -- The Texts tab honours the category filter chip; the Groups tab has
            -- no chips of its own.
            local pass = true
            if not wantGroups then
                local filter = state.activeFilter
                if filter and filter ~= "_all" then
                    local ct = FindContentType(elem.contentType)
                    pass = (ct and ct.category) == filter
                end
            end
            if pass then shown[#shown + 1] = elem end
        end
    end

    if #shown == 0 then
        -- ⚠ THE EMPTY STATE IS A BANNER, NOT A CENTRED FONTSTRING. A column of
        -- bands has no half-panel to centre anything in, and CreateInfoBanner is
        -- the shared shape for "nothing here yet, and here is why".
        local banner = GUI:CreateInfoBanner(page.child, { tone = "info" })
        banner:SetWidth(tools.BandWidth())
        banner:SetText(wantGroups
            and L["No groups yet. Click '+ Add Group' to create one."]
            or  L["No text elements yet. Click '+ Add Text Element' to create one."])
        Add(banner, nil, "both")
        return
    end

    for _, elem in ipairs(shown) do
        MountElement(ctx, elem)
    end
end

-- The Global tab is ONE group of settings, so it is one row -- the six defaults
-- every element falls back to, plus the import action that seeds the list from
-- the built-in text settings.
local function BuildGlobalTabRows(ctx)
    local page, tools, Add = ctx.page, ctx.tools, ctx.Add
    local tdDB, state = ctx.tdDB, ctx.state

    local record = GlobalDefaultsRecord(tdDB)
    if not record then return end
    -- Same rule as an element's rows: the ROW takes the record so the tick and
    -- the footer can answer, while the controls bind to globalDefaults itself.
    local RowRecord = function() return record end

    local band = GUI:CreateSettingsGroup(page.child, tools.BandWidth(), { chromeless = true })
    local mount, content = tools.PopoutContent(function(group, holder)
        holder:SetWidth(PopoutWidth())
        BuildGlobalTab(GUI, holder, state, tdDB, page, group)
    end)
    local rowTitle = L["Global Defaults"]
    local row = band:AddWidget(GUI:CreatePopoutRow(page.child, {
        label   = rowTitle,
        title   = rowTitle,
        db      = RowRecord,
        count   = content and content.groupChildren and #content.groupChildren or nil,
        window  = DF.GUIFrame,
        clipTo  = page,
        build   = mount,
    }))
    if not ctx.tdEnabled then row.disableOn = function() return true end end
    tools.ClaimKeys(row, content)
    tools.WireModifiedTick(row)
    tools.WireFooter(row, ApplyElementGroup, RowRecord)
    rowsByTitle[rowTitle] = row

    Add(band, nil, "both")
end

-- ============================================================
-- DF.BuildTextDesignerPage's POPOUT ARM
-- ------------------------------------------------------------
-- The whole page, as bands in the harness's own column: banner, canvas, tab
-- strip, then the active tab. Every object is built at tools.BandWidth() and
-- added "both", so the page has one left edge and one right edge and needs no
-- minimum window width of its own.
-- ============================================================
P.BuildTextDesignerRowsPage = function(page, db, Add, AddSpace)
    local state = GetState(page)
    state.rowsMode = true

    -- ☠ THE SPLIT PANEL'S OWN SURFACES ARE GONE -- the entry point retired them --
    -- so drop every handle to one. Left pointing at a dead frame they would be
    -- shown, hidden and written into by RenderCardList, FullRebuildCards and the
    -- mode-swap teardown, none of which would notice.
    state.listContainer, state.listChild, state.emptyMsg = nil, nil, nil
    state.groupListContainer, state.groupListChild, state.groupEmptyMsg = nil, nil, nil
    state.groupAddBtn, state.addBtn, state.chipRow = nil, nil, nil
    state.tabStrip, state.tabContents, state.SelectTab = nil, nil, nil
    state.UpdateTabCounts, state.scaleSlider = nil, nil
    state.previewPanel, state.mockFrame = nil, nil
    state.activeTab = state.activeTab or "texts"
    state.activeFilter = state.activeFilter or "_all"
    wipe(rowsByTitle)

    local tools = GUI:CreatePopoutPageTools(page)
    if not tools then return end   -- classic; the caller took the island arm

    -- The preset this mode edits. Base variant: the editor edits your base raid
    -- preset, not the active runtime auto-layout's overlay.
    local mode = (GUI and GUI.SelectedMode) or "party"
    local tdDB = (DF.GetModeBaseTextDesigner and DF:GetModeBaseTextDesigner(mode))
        or (DF.TextDesigner:EnsureDB(db))
    DF.TextDesigner:EnsureDB({ textDesigner = tdDB })

    local ctx = {
        page = page, db = db, Add = Add, AddSpace = AddSpace, tools = tools,
        tdDB = tdDB, state = state,
        tdEnabled = tdDB.enabled and true or false,
    }

    GUI:BuildDesignerShell(page, {
        tools    = tools,
        Add      = Add,
        AddSpace = AddSpace,

        banner = function(parent)
            -- A container rather than the bar itself: the enable switch is 44px
            -- and the preset bar rides underneath it, which is the Aura
            -- Designer's own header shape.
            local host = CreateFrame("Frame", nil, parent)
            host:SetSize(tools.BandWidth(), BANNER_H)
            local bar = CreateEnableBanner(GUI, host, tdDB, function()
                -- The whole page's greying answers to this, and greying is a
                -- STATE pass -- a rebuild here would retire the tick just clicked.
                ctx.tdEnabled = tdDB.enabled and true or false
                if page.Refresh then page:Refresh() end
            end)
            bar:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
            bar:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
            state.controlsBar = bar
            state.enableCheck = bar.enableCheck

            if GUI.CreateDesignerPresetBar then
                local presetBar = GUI:CreateDesignerPresetBar(host, {
                    kind = "text",
                    -- ☠ ICON BUTTONS, as the Aura Designer's band already uses. The
                    -- labelled four are New + Duplicate + Rename + Delete = 250px of
                    -- fixed row; with the caption and the template dropdown that is
                    -- 467, and the band a 640px window gives this page is ~410. The
                    -- split panel below still passes labels -- it has the 850px the
                    -- labels were chosen for.
                    iconButtons = true,
                    getMode = function() return (GUI and GUI.SelectedMode) or "party" end,
                    onChange = function()
                        -- Deferred so the bar is not torn down from inside its own
                        -- click handler.
                        if C_Timer and C_Timer.After then
                            C_Timer.After(0, function()
                                if page.Refresh then page:Refresh() end
                                if DF.TextDesigner.Preview then DF.TextDesigner.Preview:RefreshAll() end
                                if DF.UpdateAllFrames then DF:UpdateAllFrames() end
                            end)
                        end
                    end,
                })
                presetBar:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -8)
                presetBar:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -8)
                state.presetBar = presetBar
            end
            return host, BANNER_H
        end,

        canvas = function(host, shell)
            -- ☠ THE AURA DESIGNER'S CANVAS, NOT A SECOND COPY OF ONE. Decision 4:
            -- the Text Designer's own mock frame described the same anatomy less
            -- well, and two descriptions of one frame is one of them going stale.
            -- The three opts are what make that canvas host-agnostic:
            --   scaleDB    the Text Designer keeps previewScale on its OWN preset;
            --              without this the slider would write the Aura Designer's
            --   placement  the nine anchor dots and the drag hint are AD's shared
            --              module state, and a second canvas building them
            --              re-points AD's own drop targets at this page's mock
            --   unitText   the mock's built-in name and health strings, which
            --              would be drawn on top of the text elements this page
            --              exists to configure
            if not (AD and AD.CreateFramePreview) then return nil end
            local canvas = AD.CreateFramePreview(host, 0, nil, {
                compact   = true,
                scaleDB   = tdDB,
                placement = false,
                unitText  = false,
            })
            state.previewPanel = canvas
            state.mockFrame = canvas.mockFrame
            if DF.TextDesigner.Preview then
                DF.TextDesigner.Preview:Init(canvas.mockFrame, tdDB)
            end
            -- What the island's rebuild guard used to do, at the right scope: the
            -- page harness caches a valid build across revisits, so nothing would
            -- re-read the frame size or the preview scale -- and the only thing
            -- that needs to is the canvas, which has a verb for exactly that.
            host:HookScript("OnShow", function()
                if canvas.RefreshGeometry then canvas.RefreshGeometry() end
                if DF.TextDesigner.Preview then DF.TextDesigner.Preview:RefreshPreview() end
            end)
            -- The scale slider's other half: the canvas reports what it now needs
            -- and the shell moves the bands below, so scaling the mock up pushes
            -- the page down instead of painting over the tabs.
            canvas.onWantHeight = function(want)
                if shell and shell.SetCanvasHeight then shell.SetCanvasHeight(want) end
            end
            return canvas
        end,
        canvasHeight = function()
            if AD and AD.CanvasWantedHeight then return AD.CanvasWantedHeight(true, tdDB) end
            return CANVAS_H
        end,

        tabs = {
            { key = "texts",  label = L["Texts"],       accent = nil },
            { key = "groups", label = L["Text Groups"], accent = { r = 0.91, g = 0.66, b = 0.25 } },
            { key = "global", label = L["Global"],      accent = { r = 0.51, g = 0.86, b = 0.51 } },
        },
        activeTab = state.activeTab,
        onTab     = function(key)
            state.activeTab = key
            if page.Refresh then page:Refresh() end
        end,

        buildTab = function(key, shell)
            if key == "groups" then
                BuildElementListTab(ctx, shell, true)
            elseif key == "global" then
                BuildGlobalTabRows(ctx)
            else
                BuildElementListTab(ctx, shell, false)
            end
        end,
    })

    -- The other half of the reopen contract at the top of this file: whichever
    -- panel was open when a structural change forced this rebuild comes back.
    -- Next frame, because the row it belongs to has only just been laid out.
    if reopenTitle then
        local want = reopenTitle
        reopenTitle = nil
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                local row = rowsByTitle[want]
                if row and row.OpenPopout then row:OpenPopout() end
            end)
        end
    end

    if DF.TextDesigner.Preview then DF.TextDesigner.Preview:RefreshPreview() end
end
