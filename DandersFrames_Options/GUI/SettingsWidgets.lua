-- ============================================================
-- SETTINGS-PANEL WIDGETS
-- ============================================================
-- Widget factories used only by the settings panel, lifted out of the resident
-- GUI toolkit so they are neither parsed nor held in memory for players who
-- never open it. GUI.lua and Widgets.lua keep everything the live addon uses --
-- the movers, the search box, tooltips and the styling primitives.
--
-- ☠ Nothing the resident toolkit calls may live here, including calls from its
-- own file-local helpers -- that is subtler than it sounds and cost five
-- functions a pull-back when this file was built. lod_gate_check.py guards the
-- main addon; alias_check.py checks the aliases below still resolve.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L
local P = GUI._priv
-- Aliases of objects the toolkit created; they add no state.
local C_PANEL, C_ELEMENT, C_BORDER, C_HOVER, C_TEXT, C_TEXT_DIM =
      GUI.Colors.panel, GUI.Colors.element, GUI.Colors.border, GUI.Colors.hover, GUI.Colors.text, GUI.Colors.textDim
local GetThemeColor = GUI.GetThemeColor
local SnapLen = GUI.SnapLen
local AddOverrideIndicators = P.AddOverrideIndicators
local CreateElementBackdrop = P.CreateElementBackdrop
local CreatePanelBackdrop = P.CreatePanelBackdrop
local ConfirmDeletePreset = P.ConfirmDeletePreset
local PromptPresetName = P.PromptPresetName
local OUTLINE_FLAG_ORDER = P.OUTLINE_FLAG_ORDER
local LayoutPixelBorder = P.LayoutPixelBorder
local pixelBordered = P.pixelBordered

-- ---- from GUI.lua ----
-- Sync a widget's slot height into its host SettingsGroup and re-flow. Used by any
-- widget that only learns its true height AFTER construction (a measured label, an
-- info banner): update the group's stored entry, re-lay out the group, then bubble to
-- the page so sibling groups in the same column re-anchor to the group's new bottom.
-- Without the bubble a grown group's backdrop overshoots the next group's anchor and
-- renders as an empty rectangle of backdrop above it.
function GUI:RelayoutHost(widget, slotHeight)
    if not widget then return end
    local g = widget.settingsGroup
    -- RETIRED widgets must not re-flow anything. A measured label arms a next-frame
    -- converge; if the page rebuilds first (any Refresh — e.g. flipping the Colours
    -- page's Seconds/Percent tabs), that timer still fires against the PREVIOUS build.
    -- Its group is by then parented to the trash frame with its anchors cleared, so
    -- re-laying it out sizes children off a dead frame, and the parent walk below still
    -- reaches the LIVE page and makes it re-lay out mid-flight. IsShown() does not catch
    -- this — a frame keeps its own shown flag when an ancestor is hidden — so test the
    -- ancestry instead.
    local trash = GUI._trashFrame
    if trash then
        local p = (g or widget)
        while p do
            if p == trash then return end
            p = p:GetParent()
        end
    end
    if g and g.LayoutChildren then
        for _, entry in ipairs(g.groupChildren or {}) do
            if entry.widget == widget then
                entry.height = slotHeight
                break
            end
        end
        g:LayoutChildren()
    end
    local p = (g or widget):GetParent()
    while p do
        -- ☠ AD INDICATOR CARDS FIRST. A card stacks its groups by hand at fixed y offsets
        -- and has no RefreshStates seam, so the walk below used to run past it to the page
        -- (or off the top) and the card never re-anchored. The group's own LayoutChildren
        -- had already run, so the group KNEW its new height and its siblings still sat
        -- where the old one put them — seen as the Duration Bar header overlapping the
        -- Pandemic section's collapse bar, which cleared the moment anything toggled that
        -- section and forced a manual reflow.
        --
        -- This is the tail of the measured-label path: a wrapped note cannot know its
        -- height until it has been drawn, so it converges a frame after build and calls
        -- back here. Pages self-healed; cards did not. dfAD_ReflowWidgets re-anchors the
        -- whole stack reading each group's calculatedHeight, which is exactly what
        -- LayoutChildren above just refreshed.
        if type(p.dfAD_ReflowWidgets) == "function" then
            p.dfAD_ReflowWidgets()
            return
        end
        if type(p.RefreshStates) == "function" and p.children then
            p:RefreshStates()
            return
        end
        p = p:GetParent()
    end
end

-- Add a gold "New" badge to the right of a section header's text. Returns the
-- badge FontString, or nil if the section isn't registered in NewSections or
-- has already been marked seen. The badge clears (and is persisted as seen)
-- the next time the user navigates away from `tabName`.
function GUI:AddSectionNewBadge(widget, tabName, sectionId)
    -- Anchor to whichever label FontString the widget exposes:
    --   * CreateHeader containers use `.text`
    --   * CreateDropdown containers use `.label`
    local anchor = widget and (widget.text or widget.label)
    if not anchor or not tabName or not sectionId then return end
    local key = tabName .. "." .. sectionId
    if not GUI.NewSections[key] then return end

    local seen = DandersFramesDB_v2 and DandersFramesDB_v2.seenSections
                 and DandersFramesDB_v2.seenSections[key]
    if seen then return end

    local badge = widget:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    badge:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
    badge:SetText(L["New"])
    badge:SetTextColor(1, 0.82, 0)

    GUI.pendingSectionBadges[tabName] = GUI.pendingSectionBadges[tabName] or {}
    GUI.pendingSectionBadges[tabName][key] = badge
    return badge
end

-- Returns true if the given tab should be disabled for the currently
-- selected mode (i.e. the tab is mode-specific and that mode is off).
function GUI:IsTabDisabledForCurrentMode(tabName)
    if not tabName then return false end
    if GUI.AlwaysAccessiblePages[tabName] then return false end
    if GUI.SelectedMode == "party" and DF.db and DF.db.partyEnabled == false then return true end
    if GUI.SelectedMode == "raid"  and DF.db and DF.db.raidEnabled  == false then return true end
    return false
end

-- Walk all registered tabs and update their .disabled flag + visuals
-- based on the current mode and enable flags. Call after mode switches.
function GUI:UpdateTabAvailability()
    if not GUI.Tabs then return end
    for name, btn in pairs(GUI.Tabs) do
        local disabled = GUI:IsTabDisabledForCurrentMode(name)
        btn.disabled = disabled
        if btn.Text then
            if disabled then
                btn.Text:SetTextColor(0.45, 0.45, 0.45)
            else
                btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            end
        end
        if disabled and not btn.isActive then
            btn:SetBackdropColor(0, 0, 0, 0)
        end
    end

    -- Refresh the sidebar so party-only tabs (e.g. Visibility) hide/show for
    -- the current mode.
    if GUI.UpdateTabLayout then GUI:UpdateTabLayout() end

    -- If the active tab just became hidden (party-only while in raid), move to a
    -- safe always-present tab so the user isn't left on a hidden/empty page.
    if not GUI._redirectingTab and GUI.SelectedMode == "raid" and GUI.CurrentPageName then
        local cur = GUI.Tabs[GUI.CurrentPageName]
        if cur and cur.partyOnly and GUI.SelectTab then
            GUI._redirectingTab = true
            GUI.SelectTab("general_settings")
            GUI._redirectingTab = false
        end
    end
end

-- Re-derive thickness on a scale change. Rides the same sweep that already
-- re-derives backdrop edge widths, so there is no new per-frame work.
function GUI:RefreshPixelBorders()
    for frame in pairs(pixelBordered) do
        if frame:IsVisible() then LayoutPixelBorder(frame) end
    end
end

function GUI:CreateHeader(parent, text)
    -- Use a frame container so we can position text at bottom (padding above)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(200, 25)
    container:Show()
    container.rowKind = "header"
    -- Factory-owned slot, and fixed so ResolveRowHeight ignores whatever the call
    -- site passes. Headers were handed 25 in collapsible groups and 40 in plain
    -- ones -- the same widget, two rhythms, across ~200 sites. Owning it here
    -- unifies them without touching any of those call sites, which is exactly the
    -- rule the other factory rows already follow (see GUI.RowHeight).
    container.preferredHeight = GUI.RowHeight.sectionHeader
    container.fixedRowHeight = true

    local h = container:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    h:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 2)
    h:SetText(text)
    local c = GetThemeColor()
    h:SetTextColor(c.r, c.g, c.b)
    h:SetJustifyH("LEFT")
    h.UpdateTheme = function() local nc = GetThemeColor() h:SetTextColor(nc.r, nc.g, nc.b) end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, h)
    
    -- Store text reference
    container.text = h
    
    -- Forward IsShown to ensure layout works
    container.GetText = function() return h:GetText() end
    
    -- SEARCH: Track current section
    if DF.Search then
        DF.Search:SetCurrentSection(text)
    end
    
    return container
end

-- Collapsible section for grouping related settings.
-- Collapsed state is persisted in DandersFramesDB_v2.collapsedGroups keyed by
-- `text` (shared store with CreateSettingsGroup's collapsible header), so the
-- user's fold preference survives reloads.
function GUI:CreateCollapsibleSection(parent, text, defaultExpanded, width)
    local section = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    section:SetSize(width or 500, 28)  -- Header height
    -- Resolve initial expanded state: SavedVariables override the default.
    local savedStates = GUI:GetCollapsedGroups()
    if text and savedStates[text] ~= nil then
        section.expanded = not savedStates[text]
    else
        section.expanded = defaultExpanded ~= false
    end
    section.sectionTitleText = text
    section.sectionChildren = {}
    -- Same contract as CreateHeader's container.GetText: it is how a section is FOUND
    -- by title (Search:ScrollToSection, and every GUI:LinkToSetting{ section = ... }
    -- cross-link through it). Without it a collapsible section is invisible to those
    -- lookups, so a link to it silently does nothing — which is exactly what happened
    -- to the Colours page's "Color by Time" links when that box was promoted from a
    -- plain header to a collapsible section.
    section.GetText = function(self) return self.sectionTitleText end
    section.paddingAfter = 8  -- Padding space after header before first child
    
    -- Header bar with background. Same look as before, via the shared backdrop
    -- helper rather than a private copy of it, so it picks up the pixel border
    -- (and anything else that lands there) without its own wiring.
    GUI:CreateElementBackdrop(section, {
        bgColor     = { r = C_PANEL.r,  g = C_PANEL.g,  b = C_PANEL.b,  a = 0.8 },
        borderColor = { r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5 },
    })

    -- Click area
    local clickArea = CreateFrame("Button", nil, section)
    clickArea:SetAllPoints()
    clickArea:EnableMouse(true)
    
    -- Expand/collapse arrow icon
    section.arrow = section:CreateTexture(nil, "OVERLAY")
    section.arrow:SetPoint("LEFT", 8, 0)
    section.arrow:SetSize(12, 12)
    if section.expanded then
        section.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    else
        section.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
    end
    section.arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    
    -- Section title
    section.title = section:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    section.title:SetPoint("LEFT", 26, 0)
    section.title:SetText(text)
    local c = GetThemeColor()
    section.title:SetTextColor(c.r, c.g, c.b)
    section.title.UpdateTheme = function()
        if section.previewDimmed then
            section.title:SetTextColor(0.5, 0.5, 0.5)
        else
            local nc = GetThemeColor()
            section.title:SetTextColor(nc.r, nc.g, nc.b)
        end
    end
    -- Grey the header title when the section's feature is disabled (driven by
    -- the preview wiring). Routes through UpdateTheme so theme changes respect it.
    section.SetPreviewDimmed = function(self, dimmed)
        self.previewDimmed = dimmed and true or false
        self.title.UpdateTheme()
    end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, section.title)

    -- Optional inline tag — small yellow text placed after the title to
    -- stand out as a status summary (e.g. "[Normal Dispels]"). Call
    -- section:SetTag(text) at any time; pass nil or empty string to clear.
    section.tag = section:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    section.tag:SetPoint("LEFT", section.title, "RIGHT", 8, 0)
    section.tag:SetTextColor(1, 0.82, 0, 1)  -- WoW standard gold/yellow
    section.tag:SetText("")
    section.SetTag = function(self, text)
        if text and text ~= "" then
            self.tag:SetText(text)
            self.tag:Show()
        else
            self.tag:SetText("")
            self.tag:Hide()
        end
    end

    -- SEARCH: Track current section
    if DF.Search then
        DF.Search:SetCurrentSection(text)
    end
    
    -- Toggle function
    section.Toggle = function(self)
        self.expanded = not self.expanded
        if self.expanded then
            self.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
        else
            self.arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
        end
        -- Persist collapsed state to SavedVariables (only store true, remove when expanded)
        if self.sectionTitleText then
            local saved = GUI:GetCollapsedGroups()
            saved[self.sectionTitleText] = (not self.expanded) or nil
        end

        -- Trigger layout refresh (RefreshStates handles show/hide based on expanded state)
        if parent.RefreshStates then
            parent:RefreshStates()
        end
    end
    
    -- Register child widgets to this section
    section.RegisterChild = function(self, widget)
        table.insert(self.sectionChildren, widget)
        widget.parentSection = self
        
        -- Use a marker to check section state during RefreshStates
        widget.collapsibleSection = self
    end
    
    -- Optional header preview thumbnails — a right-aligned row of small icon
    -- swatches on the header bar, used to show the actual icon(s) a section
    -- controls (e.g. the Role Icon section previews the Tank/Healer/DPS icons in
    -- the currently selected style). Always visible on the header, so the page
    -- reads as a gallery whether sections are expanded or collapsed.
    --
    -- icons: array of entries, each EITHER an icon or a text label:
    --   { texture = "atlas-or-path", coords = {l,r,t,b}?, desaturate = bool? }
    --   { text = "MT", desaturate = bool? }
    -- Icon entries are fixed-width swatches; text entries are sized to the
    -- string. Entries flow right-to-left from the header's right edge so the
    -- first entry sits leftmost. nil/empty clears the preview.
    section.previewIcons = {}
    section.SetPreviewIcons = function(self, icons)
        local pool = self.previewIcons
        local n = icons and #icons or 0
        local SIZE, GAP, RIGHT_INSET = 18, 4, -10
        local x = RIGHT_INSET
        for i = n, 1, -1 do  -- right-to-left so entry 1 ends up leftmost
            local data = icons[i]
            local slot = pool[i]
            if not slot then
                slot = CreateFrame("Frame", nil, self)
                slot:SetHeight(SIZE)
                slot.tex = slot:CreateTexture(nil, "OVERLAY")
                slot.tex:SetAllPoints()
                slot.fs = slot:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                slot.fs:SetAllPoints()
                slot.fs:SetJustifyH("CENTER")
                pool[i] = slot
            end
            local dim = data.desaturate and true or false
            local w = SIZE
            if data.text and data.text ~= "" then
                slot.tex:Hide()
                slot.fs:SetText(data.text)
                if dim then
                    slot.fs:SetTextColor(0.5, 0.5, 0.5, 1)
                elseif data.color then
                    slot.fs:SetTextColor(data.color.r or 1, data.color.g or 1, data.color.b or 1, data.color.a or 1)
                else
                    slot.fs:SetTextColor(1, 0.82, 0, 1)
                end
                slot.fs:Show()
                w = math.max(SIZE, (slot.fs:GetStringWidth() or 0) + 4)
            else
                slot.fs:Hide()
                -- data.texture may be an atlas name or a texture path; the helper
                -- prefers the atlas and falls back to the path (+ optional coords).
                local co = data.coords
                DF:SetIconTextureOrAtlas(slot.tex, data.texture, co and co[1], co and co[2], co and co[3], co and co[4])
                slot.tex:SetDesaturated(dim)
                -- ☠ TINT THE SWATCH. data.color was honoured for TEXT entries only, so an
                -- icon whose frame appearance comes from a colour setting previewed at its
                -- RAW texture colour. For a white mask that means WHITE — the AFK clock
                -- renders gold on a frame but showed white here, and its baked-black
                -- interior then read as a heavy dark outline rather than as clock hands
                -- (Krathe, 2026-08-08: "still looks bad on the preview ... almost like it
                -- still has a black border around it"). The art was fine; the swatch lied.
                -- ⚠ Must come AFTER the texture call — SetTexture/SetAtlas reset vertex colour.
                if not dim and data.color then
                    slot.tex:SetVertexColor(data.color.r or 1, data.color.g or 1, data.color.b or 1, data.color.a or 1)
                else
                    slot.tex:SetVertexColor(1, 1, 1, 1)
                end
                -- Optional per-entry inset: textures that fill their cell edge-to-edge
                -- (e.g. raid-target markers) read bigger than the padded status-icon
                -- atlases. data.inset shrinks the swatch to match.
                local pad = data.inset or 0
                slot.tex:ClearAllPoints()
                slot.tex:SetPoint("TOPLEFT", slot, "TOPLEFT", pad, -pad)
                slot.tex:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -pad, pad)
                slot.tex:Show()
            end
            slot:SetWidth(w)
            slot:ClearAllPoints()
            slot:SetPoint("RIGHT", self, "RIGHT", x, 0)
            slot:Show()
            x = x - w - GAP
        end
        for i = n + 1, #pool do pool[i]:Hide() end
    end

    -- Hover effects
    clickArea:SetScript("OnEnter", function()
        section:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 0.8)
    end)
    clickArea:SetScript("OnLeave", function()
        section:SetBackdropColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.8)
    end)
    clickArea:SetScript("OnClick", function()
        section:Toggle()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    
    return section
end

-- Collapsed state persistence (stored in SavedVariables, survives logout)
-- Lazily initialized from DandersFramesDB_v2.collapsedGroups on first access
function GUI:GetCollapsedGroups()
    if not DandersFramesDB_v2 then return {} end
    if not DandersFramesDB_v2.collapsedGroups then
        DandersFramesDB_v2.collapsedGroups = {}
    end
    return DandersFramesDB_v2.collapsedGroups
end

-- ---- from Widgets.lua ----
function GUI:CreateButton(parent, text, width, height, func, iconName)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    local opts = { width = width or 120, height = height or 22, text = text }
    -- Optional leading icon by Media\Icons name (14px to suit the small buttons).
    if iconName then
        opts.icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. iconName, size = 14 }
    end
    GUI:StyleButton(btn, opts)
    btn:SetScript("OnClick", function(self)
        if func then func(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    return btn
end

-- Standard close/dismiss button: a small square danger-toned button showing a
-- "×" glyph. Replaces the many hand-rolled red close buttons on dialogs/panels.
-- opts = { size (20), onClick, tooltip, tone }.
--   tone = nil      → dim grey "×" at rest → white on hover (close/dismiss; default)
--   tone = "danger" → RED "×" at rest → brighter red on hover (inline destructive
--                     removes: list-item / tag removes). Both keep the red hover wash.
-- A horizontal row of buttons, chained left-to-right with one gap, sized as a
-- single layout slot. Pages were building this by hand every time -- a bare
-- CreateFrame, then SetPoint("LEFT", prev, "RIGHT", 6, 0) per button, plus the
-- HookScript/ShowTooltip pair on any button that needed a tooltip.
--
-- buttons = { { label, width, onClick, icon, tooltip, key }, ... }
--   tooltip is a ShowTooltip spec ({title, lines, tone}); a button IS its own
--   label, so it takes the whole-widget hover rather than AttachTooltip's
--   label-only hit area (AttachTooltip returns early without a label region).
--   key names the button on row.buttons for a caller that needs it later.
function GUI:CreateButtonRow(parent, buttons, opts)
    opts = opts or {}
    local gap, h = opts.gap or 6, opts.height or 24
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(opts.width or 540, opts.rowHeight or (h + 4))
    row.buttons = {}
    local prev
    for i, spec in ipairs(buttons) do
        local btn = GUI:CreateButton(row, spec.label, spec.width or 80, h, spec.onClick, spec.icon)
        if prev then
            btn:SetPoint("LEFT", prev, "RIGHT", gap, 0)
        else
            btn:SetPoint("LEFT", 0, 0)
        end
        if spec.tooltip then
            btn:HookScript("OnEnter", function(self) GUI:ShowTooltip(self, spec.tooltip) end)
            btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        end
        row.buttons[spec.key or i] = btn
        prev = btn
    end
    return row
end

function GUI:CreateDesignerPresetBar(parent, opts)
    opts = opts or {}
    local kind = opts.kind or "aura"
    local getMode = opts.getMode or function() return "party" end
    local onChange = opts.onChange or function() end

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(24)

    local label = bar:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    label:SetPoint("LEFT", 0, 0)
    label:SetText(L["Template:"])
    label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local function CurrentName()
        return DF:GetModeDesignerPresetName(kind, getMode())
    end

    -- True while editing a raid auto-layout (the only context with an "inherit
    -- the global preset" choice — normal party/raid modes ARE the base).
    -- Mode-gated: auto-layouts are RAID-only, but the GUI can be reopened on
    -- the party tab while editing (ToggleGUI re-derives SelectedMode) — the
    -- PARTY preset bar must not show layout state, and its "Inherit (Global)"
    -- click must never clear the RAID layout's override.
    local function IsEditingLayout()
        return getMode() == "raid"
            and DF.AutoProfilesUI and DF.AutoProfilesUI.IsEditing and DF.AutoProfilesUI:IsEditing()
    end

    -- The label to show on the dropdown button: "Inherit (Global)" when the
    -- edited layout has no override, otherwise the resolved preset name.
    local function CurrentLabel()
        if IsEditingLayout() and DF.IsLayoutDesignerInheriting and DF:IsLayoutDesignerInheriting(kind) then
            return L["Inherit (Global)"]
        end
        return CurrentName()
    end

    -- Dropdown button + menu (rebuilt on each open so it always reflects the lib)
    local ddBtn = CreateFrame("Button", nil, bar, "BackdropTemplate")
    ddBtn:SetSize(150, 22)
    ddBtn:SetPoint("LEFT", label, "RIGHT", 6, 0)
    CreateElementBackdrop(ddBtn)
    ddBtn.text = ddBtn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    ddBtn.text:SetPoint("LEFT", 6, 0)
    ddBtn.text:SetPoint("RIGHT", -16, 0)
    ddBtn.text:SetJustifyH("LEFT")
    ddBtn.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    local arrow = ddBtn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -4, 0)
    arrow:SetSize(10, 10)
    arrow:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local menu = CreateFrame("Frame", nil, ddBtn, "BackdropTemplate")
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    GUI:RegisterMenu(menu)
    menu:SetPoint("TOPLEFT", ddBtn, "BOTTOMLEFT", 0, -1)
    menu:SetWidth(150)
    CreatePanelBackdrop(menu)
    menu:Hide()

    -- Row pool: frames can't be garbage-collected in WoW, so recreating the
    -- items on every open (the old Hide+SetParent(nil) approach) leaked a row
    -- set per click. Reuse instead.
    local menuRows = {}
    local function BuildMenu()
        for _, row in ipairs(menuRows) do row:Hide() end
        local used = 0
        local y = -4
        local function AddItem(label, onClick)
            used = used + 1
            local item = menuRows[used]
            if not item then
                item = CreateFrame("Button", nil, menu)
                item:SetHeight(20)
                item.text = item:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
                item.text:SetPoint("LEFT", 4, 0)
                item:SetScript("OnEnter", function(s) s.text:SetTextColor(1, 1, 1) end)
                item:SetScript("OnLeave", function(s) s.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b) end)
                item:SetScript("OnClick", function(s)
                    s.onClick()
                    menu:Hide()
                    bar:Refresh()
                    onChange()
                end)
                menuRows[used] = item
            end
            item:ClearAllPoints()
            item:SetPoint("TOPLEFT", 4, y)
            item:SetPoint("TOPRIGHT", -4, y)
            item.text:SetText(label)
            item.text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            item.onClick = onClick
            item:Show()
            y = y - 20
        end
        -- "Inherit (Global)" — only while editing a raid auto-layout. Clears the
        -- layout's preset override so it follows your global preset.
        if IsEditingLayout() then
            AddItem(L["Inherit (Global)"], function()
                if DF.InheritLayoutDesignerPreset then DF:InheritLayoutDesignerPreset(kind) end
            end)
        end
        for _, name in ipairs(DF:ListDesignerPresets(kind)) do
            AddItem(name, function() DF:SetModeDesignerPreset(kind, getMode(), name) end)
        end
        menu:SetHeight(-y + 4)
    end
    ddBtn:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide() else BuildMenu(); menu:Show() end
    end)

    -- SHARING MARKER. A template can be pointed at by the other mode, a pinned
    -- set or an auto layout, and editing it then changes every one of them —
    -- which nothing on this bar used to say. The dropdown is a fixed 150px, so
    -- the FACT rides as a glyph and the NAMES go in the tooltip, which is free.
    --
    -- Deliberately NOT clickable. Splitting a shared template off for this mode
    -- is exactly what Duplicate does, two buttons to the right, and Duplicate
    -- also lets you name the copy.
    local shareIcon = ddBtn:CreateTexture(nil, "OVERLAY")
    shareIcon:SetSize(12, 12)
    shareIcon:SetPoint("RIGHT", arrow, "LEFT", -3, 0)
    shareIcon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\sync")
    shareIcon:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    shareIcon:Hide()

    -- Read off the REFS, not the party/raid sync flag: sharing by hand (picking
    -- the other mode's preset from this dropdown) counts exactly the same, and a
    -- ref can't fall out of step with itself.
    local function SharedWith()
        if IsEditingLayout() and DF.IsLayoutDesignerInheriting and DF:IsLayoutDesignerInheriting(kind) then
            return {}   -- inheriting: this bar isn't sitting on a preset of its own
        end
        return (DF.ListDesignerPresetUsers and DF:ListDesignerPresetUsers(kind, CurrentName(), getMode())) or {}
    end

    -- The consumers (Party/Raid, Auto Layouts, Pinned Frames) are spread across
    -- three other pages, so naming them is the one thing this tooltip has to do
    -- — the bar itself already shows what a template is. "can" holds for all
    -- four: Auto Layouts and Pinned Frames may inherit their mode's instead
    -- (a nil ref), and Party/Raid resolve to a default when nothing is set.
    -- Names match their page titles so they are findable.
    ddBtn:SetScript("OnEnter", function(self)
        local lines = {
            L["Templates can be used by Party, Raid, Auto Layouts and Pinned Frames."],
        }
        local shared = SharedWith()
        if #shared > 0 then
            lines[#lines + 1] = " "
            lines[#lines + 1] = { text = format(L["Also used by: %s"], table.concat(shared, ", ")), accent = true }
            -- "there" points back at the list above, so the consequence needs no
            -- nouns of its own. It has to be said: a shared template's edits
            -- reach a screen you are not looking at, and naming the users is
            -- only the fact, not the warning.
            lines[#lines + 1] = L["Edits apply there too."]
        end
        GUI:ShowTooltip(self, { title = L["Templates"], lines = lines })
    end)
    ddBtn:SetScript("OnLeave", function() GUI:HideTooltip() end)

    -- When editing a raid auto-layout, default the NEW preset name to the
    -- layout's name (e.g. editing "31-40" → prefill "31-40") so making a
    -- per-layout preset is one click + Enter. nil (blank) otherwise. (Duplicate
    -- names after its source preset, not the layout.)
    local function EditingLayoutName()
        if not IsEditingLayout() then return nil end  -- mode-gated (raid only)
        local apu = DF.AutoProfilesUI
        if apu and apu.editingProfile then
            return apu.editingProfile.name
        end
        return nil
    end

    -- Action buttons. opts.iconButtons = true swaps the labeled buttons for
    -- compact tooltipped icon-only buttons (22x22) — used where the bar shares
    -- a row with other controls (Aura Designer header). Default stays labeled
    -- (Text Designer) so existing callers are untouched.
    local function CreateAction(labelText, iconName, width, onClick)
        if opts.iconButtons then
            local b = CreateFrame("Button", nil, bar, "BackdropTemplate")
            GUI:StyleButton(b, {
                width = 22, height = 22,
                icon = {
                    texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. iconName,
                    size = 14, color = C_TEXT,
                },
            })
            b:SetScript("OnClick", function(self)
                onClick(self)
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            end)
            b:HookScript("OnEnter", function(self)
                GUI:ShowTooltip(self, { title = labelText})
            end)
            b:HookScript("OnLeave", function() GUI:HideTooltip() end)
            return b
        end
        return GUI:CreateButton(bar, labelText, width, 22, onClick)
    end

    local newBtn = CreateAction(L["New"], "add", 48, function()
        PromptPresetName(L["Name the new template:"], EditingLayoutName() or "", L["Create"], function(text)
            local n = DF:CreateDesignerPreset(kind, text)
            if n then
                DF:SetModeDesignerPreset(kind, getMode(), n)
                bar:Refresh(); onChange()
            end
        end)
    end)
    newBtn:SetPoint("LEFT", ddBtn, "RIGHT", 6, 0)

    local dupBtn = CreateAction(L["Duplicate"], "content_copy", 72, function()
        local cur = CurrentName()
        -- Duplicate defaults to "<source> copy" (New uses the layout name, but a
        -- duplicate is of a specific preset, so name it after the source).
        PromptPresetName(L["Name the duplicated template:"], cur .. " copy", L["Duplicate"], function(text)
            local n = DF:DuplicateDesignerPreset(kind, cur, text)
            if n then
                DF:SetModeDesignerPreset(kind, getMode(), n)
                bar:Refresh(); onChange()
            end
        end)
    end)
    dupBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)

    local renameBtn = CreateAction(L["Rename"], "edit", 62, function()
        local cur = CurrentName()
        if cur == DF.DEFAULT_PRESET then return end
        PromptPresetName(L["Rename template:"], cur, L["Rename"], function(text)
            DF:RenameDesignerPreset(kind, cur, text)
            bar:Refresh(); onChange()
        end)
    end)
    renameBtn:SetPoint("LEFT", dupBtn, "RIGHT", 4, 0)

    local delBtn = CreateAction(L["Delete"], "delete", 56, function()
        local cur = CurrentName()
        if cur == DF.DEFAULT_PRESET then return end
        ConfirmDeletePreset(kind, cur, function() bar:Refresh(); onChange() end)
    end)
    delBtn:SetPoint("LEFT", renameBtn, "RIGHT", 4, 0)

    local function SetActionEnabled(btn, on)
        if on then
            btn:Enable()
            if btn.Text then btn.Text:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b) end
            if btn.Icon then btn.Icon:SetVertexColor(C_TEXT.r, C_TEXT.g, C_TEXT.b) end
        else
            btn:Disable()
            -- greyed: Default can't be renamed/deleted
            if btn.Text then btn.Text:SetTextColor(0.4, 0.4, 0.4) end
            if btn.Icon then btn.Icon:SetVertexColor(0.4, 0.4, 0.4) end
        end
    end

    function bar:Refresh()
        ddBtn.text:SetText(CurrentLabel())
        -- Make room for the share glyph only while it's up, so an unshared
        -- preset keeps the full label width.
        local isShared = #SharedWith() > 0
        shareIcon:SetShown(isShared)
        ddBtn.text:ClearAllPoints()
        ddBtn.text:SetPoint("LEFT", 6, 0)
        ddBtn.text:SetPoint("RIGHT", isShared and -30 or -16, 0)
        -- Rename/Delete act on the resolved preset; disable for the non-editable
        -- Default and while a layout is inheriting (you're following the global,
        -- not sitting on a layout-specific preset).
        local inheriting = IsEditingLayout() and DF.IsLayoutDesignerInheriting
            and DF:IsLayoutDesignerInheriting(kind)
        local canModify = (CurrentName() ~= DF.DEFAULT_PRESET) and not inheriting
        SetActionEnabled(renameBtn, canModify)
        SetActionEnabled(delBtn, canModify)
    end

    bar:Refresh()
    -- The sharing glyph reflects OTHER refs (the other mode, a pinned set, an
    -- auto layout), which can change without changing THIS mode's — and both
    -- designer pages early-return their rebuild when their own preset is
    -- unchanged, so the glyph would sit stale. Register the live bar so the
    -- shared page refresh can reach it. One slot per kind: a rebuilt page
    -- overwrites its own entry, and a torn-down bar is hidden, so nothing
    -- accumulates.
    GUI._designerPresetBars = GUI._designerPresetBars or {}
    GUI._designerPresetBars[kind] = bar
    return bar
end

function GUI:RefreshDesignerPresetBars()
    for _, bar in pairs(GUI._designerPresetBars or {}) do
        if bar.Refresh and bar:IsShown() then bar:Refresh() end
    end
end

-- Creates a button with an icon and text
-- iconName is the name of the icon file (without path/extension)
-- iconSize is optional (defaults to 16)
-- align: "center" (default) or "left". Pass "left" for wide / full-width
-- list-style buttons where centred content floats (see GUI:StyleButton).
function GUI:CreateIconButton(parent, iconName, text, width, height, func, iconSize, align)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    GUI:StyleButton(btn, {
        width = width or 120, height = height or 22,
        text = text,
        align = align,
        icon = {
            texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\" .. iconName,
            size = iconSize or 18,
            color = C_TEXT,
        },
    })

    btn:SetScript("OnClick", function(self)
        if func then func(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    return btn
end

-- A hairline rule for use INSIDE a settings group: separates a sub-option from the
-- controls it belongs to, or a scope switch from the list it governs, without the
-- weight of a second header.
--
-- ⚠ It was hand-rolled inline on the Blizzard Frames group and copied from there
-- each time it was wanted again — five lines of texture plumbing per site, each free
-- to drift in alpha, height and inset. This is that same rule, once.
--
-- Returns a Frame ready for AddWidget; the CALLER supplies the slot height, because
-- the rule is 1px and everything else in the slot is deliberate air. 14 is the
-- established value and what every current caller passes.
--
-- opts.width   frame width (default 260, the settings-group content width)
-- opts.alpha   line alpha (default 0.08 — visible on the panel, invisible as a box)
-- opts.inset   pixels held back from each end, for a rule that should not run the
--              full width of its group
function GUI:CreateSeparator(parent, opts)
    opts = opts or {}
    local inset = opts.inset or 0
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(opts.width or 260, 1)
    local tex = f:CreateTexture(nil, "OVERLAY")
    tex:SetColorTexture(1, 1, 1, opts.alpha or 0.08)
    tex:SetPoint("LEFT", inset, 0)
    tex:SetPoint("RIGHT", -inset, 0)
    tex:SetHeight(1)
    f.Texture = tex   -- exposed so a caller can re-tint without rebuilding
    return f
-- ============================================================
-- CHOICE CARDS
-- ============================================================
-- A create action drawn as a small picture of what it produces, its name, and
-- one line saying where its contents come from.
--
-- A card REPLACES the compact "+ Add" button it stands in for rather than sitting
-- above it -- it is itself the create action, so running both would be two paths
-- to the same thing. Cards are pinned, not shown only while a list is empty; see
-- GUI:CreateChoiceCardGroup for the collapse that keeps a permanent block
-- affordable in a column this narrow.
--
-- The thumbnail is SYNTHETIC on purpose rather than a render of the player's own
-- config: an illustration that reads identically for everyone is what makes it
-- teachable, and it has to work before anything is configured. So it needs none
-- of the frame preview's rendering machinery.
--
--   opts.art      { kind = "iconRow", colors = { {r,g,b}, ... }, ghost = true }
--   opts.title    card heading (localised)
--   opts.desc     one short line -- roughly 30 characters before it wraps
--   opts.accent   border / hover tint, defaults to the mode theme
--   opts.onClick  fired on click
local CHOICE_CARD_H, CHOICE_THUMB_W, CHOICE_THUMB_H = 54, 62, 38

-- A unit frame in miniature. The name line and health bar are what make the
-- icons above them read as "on a frame" rather than as loose squares.
local function BuildChoiceThumb(parent, art)
    local thumb = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    thumb:SetSize(CHOICE_THUMB_W, CHOICE_THUMB_H)
    CreateElementBackdrop(thumb, {
        bgColor     = { 0.14, 0.14, 0.14, 1 },
        borderColor = { 0.23, 0.23, 0.23, 1 },
    })

    local name = thumb:CreateTexture(nil, "ARTWORK")
    name:SetColorTexture(0.43, 0.43, 0.43, 1)
    name:SetPoint("TOPLEFT", 4, -4)
    name:SetSize(20, 3)

    local hpBg = thumb:CreateTexture(nil, "ARTWORK")
    hpBg:SetColorTexture(0.17, 0.17, 0.17, 1)
    hpBg:SetPoint("BOTTOMLEFT", 4, 4)
    hpBg:SetPoint("BOTTOMRIGHT", -4, 4)
    hpBg:SetHeight(8)

    local hp = thumb:CreateTexture(nil, "OVERLAY")
    hp:SetColorTexture(0.25, 0.48, 0.29, 1)
    hp:SetPoint("TOPLEFT", hpBg, "TOPLEFT")
    hp:SetPoint("BOTTOMLEFT", hpBg, "BOTTOMLEFT")
    hp:SetWidth(36)

    local kind = art and art.kind
    local c = (art and art.color) or { 0.45, 0.45, 0.95 }

    if kind == "iconRow" then
        local x = 4
        for _, col in ipairs(art.colors or {}) do
            local ico = thumb:CreateTexture(nil, "OVERLAY")
            ico:SetColorTexture(col[1], col[2], col[3], 1)
            ico:SetPoint("TOPLEFT", x, -11)
            ico:SetSize(8, 8)
            x = x + 10
        end
        -- One unfilled slot. A layout group's row grows and shrinks with what is
        -- actually up, and an empty space says that faster than a sentence can.
        if art.ghost then
            local ghost = thumb:CreateTexture(nil, "OVERLAY")
            ghost:SetColorTexture(1, 1, 1, 0.07)
            ghost:SetPoint("TOPLEFT", x, -11)
            ghost:SetSize(8, 8)
        end

    elseif kind == "icon" or kind == "square" then
        -- Both sit ON the frame at a corner; the size difference IS the difference.
        local sz = (kind == "icon") and 13 or 7
        local box = thumb:CreateTexture(nil, "OVERLAY")
        box:SetColorTexture(c[1], c[2], c[3], 1)
        box:SetPoint("TOPLEFT", 5, -11)
        box:SetSize(sz, sz)

    elseif kind == "bar" then
        local bar = thumb:CreateTexture(nil, "OVERLAY")
        bar:SetColorTexture(c[1], c[2], c[3], 1)
        bar:SetPoint("TOPLEFT", 5, -13)
        bar:SetPoint("RIGHT", thumb, "RIGHT", -5, 0)
        bar:SetHeight(5)

    elseif kind == "border" then
        -- Drawn as four edges rather than a backdrop swap: the thumb's own border
        -- is the "no effect" state, and this has to read as sitting on top of it.
        for _, e in ipairs({ {"TOPLEFT","TOPRIGHT",0,0,nil,2}, {"BOTTOMLEFT","BOTTOMRIGHT",0,0,nil,2},
                             {"TOPLEFT","BOTTOMLEFT",0,0,2,nil}, {"TOPRIGHT","BOTTOMRIGHT",0,0,2,nil} }) do
            local t = thumb:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(c[1], c[2], c[3], 1)
            t:SetPoint(e[1], e[3], e[4])
            t:SetPoint(e[2], e[3], e[4])
            if e[5] then t:SetWidth(e[5]) end
            if e[6] then t:SetHeight(e[6]) end
        end

    elseif kind == "healthbar" then
        hp:SetColorTexture(c[1], c[2], c[3], 1)

    elseif kind == "background" then
        local bg = thumb:CreateTexture(nil, "BORDER")
        bg:SetColorTexture(c[1], c[2], c[3], 0.55)
        bg:SetPoint("TOPLEFT", 1, -1)
        bg:SetPoint("BOTTOMRIGHT", -1, 1)

    elseif kind == "nametext" then
        name:SetColorTexture(c[1], c[2], c[3], 1)

    elseif kind == "healthtext" then
        -- The health readout sits on the bar, so the swatch goes there to
        -- distinguish it from the name line above.
        local ht = thumb:CreateTexture(nil, "OVERLAY")
        ht:SetColorTexture(c[1], c[2], c[3], 1)
        ht:SetPoint("BOTTOMRIGHT", -6, 6)
        ht:SetSize(12, 3)
    end

    return thumb
end

-- A titled, collapsible block of choice cards.
--
-- Collapse state persists through GUI:GetCollapsedGroups() -- the same
-- account-wide store the settings pages' collapsible sections use -- keyed by
-- opts.title. Give every block a DISTINCT title or two of them share one state.
-- (Keying by display text means the state resets if the player changes language.
-- That is pre-existing behaviour for every collapsible section in the panel.)
--
-- ⚠ Toggling does not relayout by itself. The host is expected to rebuild from
-- opts.onToggle -- which suits the Aura Designer, where every edit already
-- rebuilds the tab. Without onToggle the state is saved but nothing moves.
local CHOICE_GROUP_HEADER_H, CHOICE_CARD_GAP = 22, 6

function GUI:CreateChoiceCardGroup(parent, opts)
    opts = opts or {}
    local accent = opts.accent or GetThemeColor()
    local key = opts.title
    local saved = GUI:GetCollapsedGroups()
    local expanded = not (key and saved[key])

    local group = CreateFrame("Frame", nil, parent)

    local header = CreateFrame("Button", nil, group)
    header:SetHeight(CHOICE_GROUP_HEADER_H)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")

    local arrow = header:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("LEFT", 0, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture(expanded
        and "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more"
        or  "Interface\\AddOns\\DandersFrames\\Media\\Icons\\chevron_right")
    arrow:SetVertexColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    local label = header:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(label, 9, "")
    label:SetPoint("LEFT", arrow, "RIGHT", 6, 0)
    label:SetText(opts.title or "")
    label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    header:SetScript("OnEnter", function()
        label:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    end)
    header:SetScript("OnLeave", function()
        label:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    end)
    header:SetScript("OnClick", function()
        if key then
            -- Store only the collapsed state, matching CreateCollapsibleSection:
            -- an expanded block leaves no key behind at all.
            GUI:GetCollapsedGroups()[key] = expanded or nil
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if opts.onToggle then opts.onToggle() end
    end)

    local h = CHOICE_GROUP_HEADER_H
    if expanded then
        local y = -h
        for _, def in ipairs(opts.cards or {}) do
            local card = GUI:CreateChoiceCard(group, {
                title = def.title, desc = def.desc, art = def.art,
                accent = accent, onClick = def.onClick,
            })
            card:SetPoint("TOPLEFT", 0, y)
            card:SetPoint("RIGHT", group, "RIGHT", 0, 0)
            y = y - (card.layoutHeight + CHOICE_CARD_GAP)
            h = h + card.layoutHeight + CHOICE_CARD_GAP
        end
    end

    group:SetHeight(h)
    group.layoutHeight = h
    group.expanded = expanded
    return group
end

function GUI:CreateChoiceCard(parent, opts)
    opts = opts or {}
    local accent = opts.accent or GetThemeColor()
    local idleBorder = { accent.r * 0.45, accent.g * 0.45, accent.b * 0.45, 0.8 }

    local card = CreateFrame("Button", nil, parent, "BackdropTemplate")
    card:SetHeight(CHOICE_CARD_H)
    CreateElementBackdrop(card, {
        bgColor     = { C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1 },
        borderColor = idleBorder,
    })

    local thumb = BuildChoiceThumb(card, opts.art)
    thumb:SetPoint("LEFT", 8, 0)

    local title = card:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    title:SetPoint("TOPLEFT", thumb, "TOPRIGHT", 9, -2)
    title:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    title:SetJustifyH("LEFT")
    title:SetText(opts.title or "")
    title:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    local desc = card:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(desc, 8, "")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    desc:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    desc:SetJustifyH("LEFT")
    desc:SetWordWrap(true)
    desc:SetText(opts.desc or "")
    desc:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)

    card:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
        self:SetBackdropBorderColor(accent.r, accent.g, accent.b, 1)
    end)
    card:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
        self:SetBackdropBorderColor(unpack(idleBorder))
    end)
    card:SetScript("OnClick", function(self)
        if opts.onClick then opts.onClick(self) end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    card.layoutHeight = CHOICE_CARD_H
    return card
end

-- Creates a \"See Also:\" section with clickable links to related pages
-- links = { {pageId = \"display_tooltips\", label = \"Tooltips\"}, ... }
function GUI:CreateSeeAlso(parent, links)
    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetHeight(32)
    -- The page's own footer: pinned to the bottom of the viewport on a SHORT
    -- page instead of floating wherever the content happened to end. See the
    -- footer block in the page layout.
    container.isPageFooter = true
    CreateElementBackdrop(container, {
        bgColor     = { 0.1, 0.1, 0.1, 0.5 },
        borderColor = { 0.3, 0.3, 0.3, 0.8 },
    })
    
    local label = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    label:SetPoint("TOPLEFT", 8, -10)
    label:SetText(L["See Also:"])
    label:SetTextColor(0.7, 0.7, 0.7)
    
    local linkButtons = {}
    local separators = {}
    
    for i, linkData in ipairs(links) do
        local link = CreateFrame("Button", nil, container)
        link:SetHeight(16)
        
        local linkText = link:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        linkText:SetPoint("TOPLEFT", 0, -1)
        linkText:SetText(linkData.label)
        local c = GetThemeColor()
        linkText:SetTextColor(c.r, c.g, c.b)
        link.text = linkText
        link.textWidth = linkText:GetStringWidth() + 4
        link:SetWidth(link.textWidth)
        
        link:SetScript("OnEnter", function(self)
            local h = GUI:LinkHoverColor(c)
            linkText:SetTextColor(h.r, h.g, h.b)
        end)
        link:SetScript("OnLeave", function(self)
            linkText:SetTextColor(c.r, c.g, c.b)
        end)
        link:SetScript("OnClick", function()
            if GUI.SelectTab then
                GUI.SelectTab(linkData.pageId)
            end
        end)
        
        table.insert(linkButtons, link)
        
        -- Create separator (hidden by default, shown as needed)
        if i < #links then
            local sep = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            sep:SetText("•")
            sep:SetTextColor(0.5, 0.5, 0.5)
            table.insert(separators, sep)
        end
    end
    
    -- Layout function that handles wrapping
    local function LayoutLinks()
        local containerWidth = container:GetWidth()
        if containerWidth < 50 then return end  -- Not sized yet
        
        local labelWidth = label:GetStringWidth() + 16
        local firstLinkX = labelWidth  -- Where first link starts
        local xOffset = labelWidth
        local yOffset = -9
        local lineHeight = 18
        local maxX = containerWidth - 10
        local rowCount = 1
        
        -- First pass: determine which links are on which row
        local linkRows = {}
        local tempX = labelWidth
        local currentRow = 1
        
        for i, link in ipairs(linkButtons) do
            local linkWidth = link.textWidth
            local sepWidth = (i < #linkButtons) and 14 or 0
            
            -- Check if we need to wrap
            if tempX + linkWidth > maxX and tempX > labelWidth then
                currentRow = currentRow + 1
                tempX = firstLinkX
            end
            
            linkRows[i] = currentRow
            tempX = tempX + linkWidth + sepWidth
        end
        
        rowCount = currentRow
        
        -- Second pass: position elements
        xOffset = labelWidth
        local lastRowForLink = 1
        
        for i, link in ipairs(linkButtons) do
            local linkWidth = link.textWidth
            
            -- Check if we need to wrap to new line
            if linkRows[i] > lastRowForLink then
                xOffset = firstLinkX
                yOffset = yOffset - lineHeight
                lastRowForLink = linkRows[i]
            end
            
            link:ClearAllPoints()
            link:SetPoint("TOPLEFT", container, "TOPLEFT", xOffset, yOffset)
            
            xOffset = xOffset + linkWidth + 2
            
            -- Position separator only if next link is on same row
            if separators[i] then
                if linkRows[i + 1] == linkRows[i] then
                    separators[i]:ClearAllPoints()
                    separators[i]:SetPoint("TOPLEFT", container, "TOPLEFT", xOffset, yOffset - 1)
                    separators[i]:Show()
                    xOffset = xOffset + 12
                else
                    separators[i]:Hide()
                end
            end
        end
        
        -- Adjust container height based on rows.
        --
        -- Snapped HERE, where the number is computed, because this widget
        -- MEASURES ITSELF: LayoutLinks runs from OnSizeChanged and from a
        -- C_Timer.After(0), i.e. a frame AFTER the page layout has run.
        -- Correcting the height after the fact cannot win -- whatever sets a
        -- grid-aligned height, this function overwrites it on the next frame,
        -- and the bar's bottom edge ends up split across two device rows.
        -- Measured: 28 units at 1.40625 px/unit is 39.375px, 0.375 off.
        local newHeight = SnapLen(container, 10 + (rowCount * lineHeight))
        container:SetHeight(newHeight)
        container.layoutHeight = newHeight + 5
    end
    
    container:SetScript("OnSizeChanged", LayoutLinks)
    
    -- Initial layout after a frame (to let width be set)
    C_Timer.After(0, LayoutLinks)
    
    return container
end

-- A bare checkbox sized for a LIST ROW — no label, no db binding, no settings-row
-- geometry. GUI:CreateCheckbox is a whole 30px settings row with its own label and
-- hit rect, which is the wrong shape entirely inside a 22px pooled list row that
-- already owns its own text, count and selection accent.
--
-- The caller drives it: :SetChecked(bool) to paint, opts.onClick to react. It does
-- NOT read or write the db itself, because a list row's meaning changes per bind
-- (a pooled row is a different filter every refresh) and a captured dbKey would go
-- stale the moment the pool rebinds.
--
-- ⚠ Clicks deliberately do NOT propagate. The override marker above lets them fall
-- through because it is a passive marker; this is a control, and on a clickable row
-- the two gestures must stay separate — tick the box to switch the filter on, click
-- anywhere else to select it. Nothing here calls SetPropagateMouseClicks, which is
-- PROTECTED on 12.1 anyway (see the note in CreateOverrideMarker).
--
-- ⚠ The BOX ITSELF is GUI:StyleCheckButton, the addon's one checkbox look — do not
-- hand-roll it again. This was hand-rolled once and drifted four ways: it drew the
-- Media\Icons\check GLYPH where every other checkbox in the addon draws a filled
-- WHITE8x8 square (a different SYMBOL, not a different style), it skipped PixelUtil
-- so it alone was unsnapped, it had no hover wash, and it recoloured its BORDER when
-- checked, which nothing else does. CreateDebugCategoryRow is the precedent for this
-- exact case — a list row with a checkbox — at the same size.
--
-- manualCheck because this is a plain Button, not a CheckButton: SetChecked below
-- drives the mark. A real CheckButton would draw its checked mark through the native
-- checked state, which has no disabled-checked texture here — so a greyed-but-ticked
-- row (every filter row while All Buffs is on) would lose its tick entirely.
--
-- opts: { size = 16, checkSize = 9, onClick = function(checked) end,
--         tooltip = title, tooltipDesc = line }
function GUI:CreateRowToggle(parent, opts)
    opts = opts or {}
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    GUI:StyleCheckButton(btn, {
        size        = opts.size or 16,
        checkSize   = opts.checkSize or 9,
        manualCheck = true,
    })

    btn.checked = false
    function btn:SetChecked(on)
        self.checked = on and true or false
        -- Re-tint on every paint. StyleCheckButton registers its theme listener on
        -- this button's PARENT, which for a pooled list row is a frame inside a
        -- scroll child that the page's theme walk never visits (same trap as
        -- StyleButton's wash). The list rebinds every row on refresh, and a refresh
        -- is what a mode switch produces, so painting the accent here is what
        -- actually carries party purple -> raid orange.
        self.ApplyThemeColor(GetThemeColor())
        self.Check:SetShown(self.checked)
    end

    btn:SetScript("OnClick", function(s)
        if s.onClick then s.onClick(not s.checked) end
    end)
    btn:SetScript("OnEnter", function(s)
        if s.tooltipText then
            GUI:ShowTooltip(s, { title = s.tooltipText, lines = s.tooltipDesc and { s.tooltipDesc } or nil })
        end
    end)
    btn:SetScript("OnLeave", function() GUI:HideTooltip() end)

    btn.onClick = opts.onClick
    btn.tooltipText = opts.tooltip
    btn.tooltipDesc = opts.tooltipDesc
    btn:SetChecked(false)
    return btn
end

function GUI:CreateCheckbox(parent, label, dbTable, dbKey, callback, customGet, customSet, overrideKey)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(220, 24)
    container.preferredHeight = GUI.RowHeight.checkbox   -- factory-owned slot height (see GUI.RowHeight)
    container.rowKind = "checkbox"       -- /df debug gapcheck groups the spacing report by this
    container.fixedRowHeight = true

    local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
    cb:SetPoint("LEFT", 0, 0)
    -- Box + themed check come from the shared styler (single source of truth).
    GUI:StyleCheckButton(cb, { themeRoot = parent })

    -- Label
    local txt = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    txt:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    txt:SetText(label)
    txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    container.label = txt  -- exposed so callers can re-font / anchor a subtitle

    -- Determine the key to use for override indicators
    local effectiveOverrideKey = overrideKey or dbKey
    
    -- Add override indicators if we have a key (either dbKey or overrideKey)
    if effectiveOverrideKey and type(effectiveOverrideKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(effectiveOverrideKey)
                -- Refresh to global value
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(effectiveOverrideKey)
                cb:SetChecked(globalVal)
                if dbTable and dbKey then
                    dbTable[dbKey] = globalVal
                elseif customSet then
                    customSet(globalVal)
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
                if callback then callback() end
            end
        end
        AddOverrideIndicators(container, txt, effectiveOverrideKey, onReset, nil, nil, dbTable)
    end
    
    local function UpdateState()
        local val = false
        if customGet then val = customGet() elseif dbTable and dbKey then val = dbTable[dbKey] end
        cb:SetChecked(val)
        -- Update override indicators
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(val)
        end
    end
    
    container:SetScript("OnShow", UpdateState)
    -- Re-read the source and repaint the box, for a caller that changed the value
    -- behind the widget's back (a "set all" button). Same contract as
    -- CreateSegmentToggle:Refresh(); before this, call sites reached for a
    -- Hide()/Show() bounce to fire the OnShow above.
    container.Refresh = UpdateState
    cb:SetScript("OnClick", function(self)
        local val = self:GetChecked()
        -- Was gated on DF.debugEnabled and printed straight to CHAT, bypassing the
        -- console entirely. GUI is the right category and it is already declared.
        DF:Debug("GUI", "checkbox OnClick: dbKey=%s overrideKey=%s value=%s",
            tostring(dbKey), tostring(overrideKey), tostring(val))

        -- Runtime override protection: redirect to baseline, skip refresh
        if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
           and DF.AutoProfilesUI:HandleRuntimeWrite(effectiveOverrideKey, val) then
            if container.UpdateOverrideIndicators then container:UpdateOverrideIndicators(val) end
            return
        end

        if customSet then customSet(val) elseif dbTable and dbKey then dbTable[dbKey] = val end

        -- If editing a profile, also set the override (use effectiveOverrideKey)
        if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and effectiveOverrideKey then
            DF.AutoProfilesUI:SetProfileSetting(effectiveOverrideKey, val)
        end
        
        -- Update override indicators
        if container.UpdateOverrideIndicators then
            container:UpdateOverrideIndicators(val)
        end
        
        if callback then 
            DF:Debug("GUI", "checkbox OnClick: calling callback")
            callback() 
        end
        if parent.RefreshStates then 
            DF:Debug("GUI", "checkbox OnClick: calling RefreshStates")
            parent:RefreshStates() 
        end
        DF:Debug("GUI", "checkbox OnClick: calling DF:UpdateAll")
        DF:UpdateAll()
    end)
    
    container.SetEnabled = function(self, enabled)
        -- Dim the whole widget (box + check fill + label) so a disabled CHECKED
        -- box greys too: native SetEnabled has no DisabledCheckedTexture, so the
        -- accent check would otherwise stay full-bright.
        self:SetAlpha(enabled and 1 or 0.4)
        cb:SetEnabled(enabled)
        if enabled then
            txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            txt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end

    -- Tooltip: shared attach on the LABEL only (see GUI:AttachTooltip). The
    -- earlier hit-rect arithmetic here is gone with it — the hit frame is anchored
    -- to the FontString, so a label overflowing the fixed 220 container is covered
    -- for free rather than by widening the container's hit rect to match.
    GUI:AttachTooltip(container, label, txt)

    UpdateState()
    
    -- SEARCH: Register this setting
    if DF.Search then
        local hasCustomGetSet = (customGet ~= nil or customSet ~= nil)
        if dbKey and type(dbKey) == "string" then
            container.searchEntry = DF.Search:RegisterCheckbox(label, dbKey, nil, false, callback)
        elseif hasCustomGetSet then
            container.searchEntry = DF.Search:RegisterCheckbox(label, nil, nil, true, callback)
        end
        -- Hand the entry a reference back, so the inline search result can read
        -- the tooltip this caller is about to set on us.
        DF.Search:LinkSourceWidget(container)
    end
    
    return container
end

function GUI:CreateSegmentToggle(parent, segments, dbTable, dbKey, callback, opts)
    opts = opts or {}
    local segW = opts.segmentWidth or 26
    local h = opts.height or 18
    local pad = 1   -- track lip around the buttons

    local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    container:SetSize(segW * #segments + pad * 2, h + pad * 2)
    CreateElementBackdrop(container)   -- the recessed track behind every segment

    -- One read/write pair for both pathways, so the click handler and Refresh
    -- can't drift apart. Explicit ifs, not `a and b or c` — a stored value of
    -- false/nil is legitimate.
    local function GetValue()
        if opts.customGet then return opts.customGet() end
        if dbTable and dbKey then return dbTable[dbKey] end
    end
    local function SetValue(v)
        if opts.customSet then opts.customSet(v) return true end
        if dbTable and dbKey then dbTable[dbKey] = v return true end
        return false
    end

    local buttons = {}
    for i, seg in ipairs(segments) do
        local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
        GUI:StyleButton(btn, { width = segW, height = h, text = seg.label })
        GUI:SetSettingsFont(btn.Text, 9, "")
        btn:SetPoint("TOPLEFT", container, "TOPLEFT", pad + (i - 1) * segW, -pad)
        btn.value = seg.value
        if seg.tooltip then
            btn:HookScript("OnEnter", function(self)
                GUI:ShowTooltip(self, { title = seg.tooltip, lines = opts.tooltipLines })
            end)
            btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        end
        btn:SetScript("OnClick", function(self)
            if GetValue() == self.value then return end
            if not SetValue(self.value) then return end
            container:Refresh()
            if callback then callback(self.value) end
        end)
        buttons[i] = btn
    end

    -- Selection: the shared accent border/fill via SetActive, plus a bright/dim
    -- label so the state still reads at a glance in a themed accent that is close
    -- to the resting border colour.
    function container:Refresh()
        local cur = GetValue()
        local matched = false
        for _, b in ipairs(buttons) do if b.value == cur then matched = true end end
        if not matched then cur = opts.fallbackValue end
        for _, b in ipairs(buttons) do
            local on = (b.value == cur)
            b:SetActive(on)
            if b.Text then
                local c = on and C_TEXT or C_TEXT_DIM
                b.Text:SetTextColor(c.r, c.g, c.b)
            end
        end
    end
    container.refreshContent = function(self) self:Refresh() end

    container.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
        for _, b in ipairs(buttons) do b:EnableMouse(enabled) end
    end

    container.UpdateTheme = function() container:Refresh() end
    if not parent.ThemeListeners then parent.ThemeListeners = {} end
    table.insert(parent.ThemeListeners, container)

    container:Refresh()
    return container
end

-- opts.noisy marks a firehose category: one user action can produce dozens of
-- lines, which evicts the trace the log was opened to capture. It renders as the
-- shared caution icon with its own tooltip rather than a "(noisy)" suffix baked
-- into the description string -- the suffix was untranslatable in place, and it
-- competed with the description for the same line of text.
function GUI:CreateDebugCategoryRow(parent, categoryKey, description, width, noisy)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(width or 520, 28)
    row:EnableMouse(true)

    -- Hover background
    row.hoverBg = row:CreateTexture(nil, "BACKGROUND")
    row.hoverBg:SetAllPoints()
    row.hoverBg:SetColorTexture(1, 1, 1, 0.05)
    row.hoverBg:Hide()

    -- Checkbox
    local cb = CreateFrame("CheckButton", nil, row, "BackdropTemplate")
    cb:SetPoint("LEFT", 4, 0)
    GUI:StyleCheckButton(cb, { size = 16, checkSize = 9, themeRoot = parent })
    cb:EnableMouse(false)  -- forward clicks to the row

    -- Category name (bold, full opacity)
    local nameTxt = row:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    nameTxt:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    nameTxt:SetWidth(86)
    nameTxt:SetJustifyH("LEFT")
    nameTxt:SetText(categoryKey)
    nameTxt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

    -- Caution icon for a firehose category. Its own hit area, so it can carry a
    -- different tooltip from the row without stealing the row's click: the frame
    -- only enables mouse, it has no OnMouseUp, so a click still falls through to
    -- the row underneath and toggles the category like anywhere else on it.
    local noisyIcon
    if noisy then
        noisyIcon = CreateFrame("Frame", nil, row)
        noisyIcon:SetSize(14, 14)
        noisyIcon:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        noisyIcon:EnableMouse(true)
        noisyIcon:SetFrameLevel(row:GetFrameLevel() + 2)
        local tex = noisyIcon:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning")
        -- The caution tone's ICON colour, read straight from the shared tone table
        -- so this stays in step with every banner and note that uses it.
        -- ☠ Read at CALL time, not through a file-scope alias. INFO_BANNER_TONES
        -- is defined in GUI/Sections.lua, which lives in the load-on-demand
        -- companion, while this file is resident -- an alias captured at load
        -- would be nil forever and never see the companion's later publish.
        -- This function is only ever called from a settings page, so the
        -- companion is loaded by the time it runs.
        local ic = GUI._priv.INFO_BANNER_TONES.caution.iconColor
        tex:SetVertexColor(ic[1], ic[2], ic[3])
        noisyIcon:SetScript("OnEnter", function(self)
            -- Keep the row's wash up: the pointer is still over the row, and
            -- letting it drop would read as the row losing focus.
            row.hoverBg:Show()
            GUI:ShowTooltip(self, {
                title = L["Noisy category"],
                lines = { L["This category can fill the log very quickly, burying the entries you are looking for."],
                          L["Turn it on only while reproducing the bug it relates to."] },
                tone = "caution",
            })
        end)
        noisyIcon:SetScript("OnLeave", function()
            row.hoverBg:Hide()
            GUI:HideTooltip()
        end)
        row.noisyIcon = noisyIcon
    end

    -- Description (dim, fills remaining space, wraps if too long)
    if description and description ~= "" then
        local descTxt = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        descTxt:SetPoint("LEFT", nameTxt, "RIGHT", 12, 0)
        -- Stop short of the icon rather than running under it.
        if noisyIcon then
            descTxt:SetPoint("RIGHT", noisyIcon, "LEFT", -6, 0)
        else
            descTxt:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        end
        descTxt:SetJustifyH("LEFT")
        descTxt:SetText(description)
        descTxt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        row.descTxt = descTxt
    end

    -- State helpers — read/write filters[categoryKey]
    -- Absent or true = logged, explicit false = not logged
    row.RefreshState = function()
        local filters = DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.filters
        local checked = (not filters) or filters[categoryKey] ~= false
        cb:SetChecked(checked)
    end

    local function ToggleState()
        local filters = DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.filters
        if not filters then return end
        -- Toggle: false -> true, anything else -> false
        if filters[categoryKey] == false then
            filters[categoryKey] = true
        else
            filters[categoryKey] = false
        end
        row.RefreshState()
        if DF.DebugConsole then DF.DebugConsole:RefreshDisplay() end
    end

    row:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then ToggleState() end
    end)

    row:SetScript("OnEnter", function(self)
        self.hoverBg:Show()
        if description and description ~= "" then
            GUI:ShowTooltip(self, { title = categoryKey, lines = { description } })
        end
    end)
    row:SetScript("OnLeave", function(self)
        self.hoverBg:Hide()
        GUI:HideTooltip()
    end)

    row:SetScript("OnShow", row.RefreshState)
    row.RefreshState()

    return row
end

function GUI:CreateInput(parent, label, width)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 180, 44)
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    local editbox = CreateFrame("EditBox", nil, frame)
    -- Two-corner anchored, so the offset and the height are the ONLY levers --
    -- Nothing corrects a frame's position at runtime, and controls are not
    -- position-corrected at all any more. Snap both and all four edges land.
    local ebY = SnapLen(editbox, -15) or -15
    editbox:SetPoint("TOPLEFT", 0, ebY)
    editbox:SetPoint("TOPRIGHT", 0, ebY)
    editbox:SetHeight(SnapLen(editbox, 24) or 24)
    GUI:StyleEditBox(editbox)   -- shared input chrome: fill, border, font, insets
    editbox:SetAutoFocus(false)
    editbox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editbox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- Grey-when-disabled parity with CreateEditBox (cheap insurance if ever placed
    -- in a gated group): dim the whole widget + block editing.
    frame.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
        editbox:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end

    frame.EditBox = editbox
    -- Tooltip: shared attach on the LABEL only. This factory carried no tooltip
    -- support at all, so a caller that set .tooltip on it got silence —
    -- Options.lua's custom range-spell input did exactly that, and its
    -- explanation never appeared. Keeping it off the edit box also means it can't
    -- cover what you are typing.
    GUI:AttachTooltip(frame, label, lbl)
    return frame
end

-- CreateEditBox: Text input with db binding (for settings like custom text)
function GUI:CreateEditBox(parent, label, dbTable, dbKey, callback, width, placeholder)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 180, 44)
    frame.preferredHeight = GUI.RowHeight.editbox   -- factory-owned slot height (see GUI.RowHeight)
    frame.rowKind = "editbox"
    frame.fixedRowHeight = true
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Add override indicators if dbKey is provided
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if dbTable and dbKey then
                    dbTable[dbKey] = globalVal
                end
                if frame.EditBox then
                    frame.EditBox:SetText(globalVal or "")
                end
                if frame.UpdateOverrideIndicators then
                    frame:UpdateOverrideIndicators(globalVal)
                end
                DF:UpdateAll()
                if callback then callback() end
            end
        end
        AddOverrideIndicators(frame, lbl, dbKey, onReset, 6, nil, dbTable)
    end
    
    local editbox = CreateFrame("EditBox", nil, frame)
    -- Two-corner anchored, so the offset and the height are the ONLY levers --
    -- Nothing corrects a frame's position at runtime, and controls are not
    -- position-corrected at all any more. Snap both and all four edges land.
    local ebY = SnapLen(editbox, -15) or -15
    editbox:SetPoint("TOPLEFT", 0, ebY)
    editbox:SetPoint("TOPRIGHT", 0, ebY)
    editbox:SetHeight(SnapLen(editbox, 24) or 24)
    GUI:StyleEditBox(editbox)   -- shared input chrome: fill, border, font, insets
    editbox:SetAutoFocus(false)

    -- Set initial value from db
    if dbTable and dbKey then
        editbox:SetText(dbTable[dbKey] or "")
    end
    
    -- Save on enter or focus lost
    local function SaveValue()
        if dbTable and dbKey then
            local val = editbox:GetText()
            -- Runtime override protection
            if GUI.SelectedMode == "raid" and DF.AutoProfilesUI
               and DF.AutoProfilesUI:HandleRuntimeWrite(dbKey, val) then
                if frame.UpdateOverrideIndicators then frame:UpdateOverrideIndicators(val) end
                return
            end
            dbTable[dbKey] = val
            -- Track override when editing a profile
            if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
                DF.AutoProfilesUI:SetProfileSetting(dbKey, val)
            end
            if frame.UpdateOverrideIndicators then
                frame:UpdateOverrideIndicators(val)
            end
            if callback then callback() end
        end
    end
    
    editbox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editbox:SetScript("OnEnterPressed", function(self)
        SaveValue()
        self:ClearFocus()
    end)
    editbox:SetScript("OnEditFocusLost", SaveValue)
    
    -- Optional placeholder: greyed example text shown while the box is empty
    -- and unfocused. Purely cosmetic — never written to the db.
    if placeholder and placeholder ~= "" then
        local ph = editbox:CreateFontString(nil, "ARTWORK", "DFFontHighlightSmall")
        ph:SetPoint("LEFT", 5, 0)
        ph:SetPoint("RIGHT", -5, 0)
        ph:SetJustifyH("LEFT")
        ph:SetText(placeholder)
        ph:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.55)
        local function UpdatePlaceholder()
            ph:SetShown(not editbox:HasFocus() and editbox:GetText() == "")
        end
        -- Exposed so a caller that puts something INSIDE the box (see
        -- GUI:AddEditBoxIcon) can move the placeholder clear of it.
        editbox.Placeholder = ph
        editbox.UpdatePlaceholder = UpdatePlaceholder
        editbox:HookScript("OnTextChanged", UpdatePlaceholder)
        editbox:HookScript("OnEditFocusGained", UpdatePlaceholder)
        editbox:HookScript("OnEditFocusLost", UpdatePlaceholder)
        UpdatePlaceholder()
    end

    -- Refresh override indicators on show
    frame:SetScript("OnShow", function()
        if dbTable and dbKey then
            editbox:SetText(dbTable[dbKey] or "")
        end
        if frame.UpdateOverrideIndicators then
            frame:UpdateOverrideIndicators(dbTable and dbTable[dbKey])
        end
        if editbox.UpdatePlaceholder then editbox.UpdatePlaceholder() end
    end)

    -- Grey-when-disabled: the grey loop (RefreshChildStates) calls widget:SetEnabled,
    -- but this frame had none, so a disabled group left the input full-bright AND
    -- editable. Dim the whole widget + block editing, matching the other helpers.
    frame.SetEnabled = function(self, enabled)
        self:SetAlpha(enabled and 1 or 0.4)
        editbox:SetEnabled(enabled)
        if enabled then
            lbl:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
        else
            lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        end
    end

    frame.EditBox = editbox
    return frame
end

function GUI:AddEditBoxIcon(editbox, texture, size)
    if not editbox or not texture then return end
    size = size or 14
    local icon = editbox:CreateTexture(nil, "OVERLAY")
    icon:SetSize(size, size)
    icon:SetPoint("LEFT", 6, 0)
    icon:SetTexture(texture)
    icon:SetVertexColor(0.72, 0.72, 0.72)
    editbox.Icon = icon

    local left = 6 + size + 5
    local _, right, top, bottom = editbox:GetTextInsets()
    editbox:SetTextInsets(left, right, top, bottom)
    if editbox.Placeholder then
        editbox.Placeholder:SetPoint("LEFT", left, 0)
    end
    return icon
end

-- Stamp the shared Frame Level explanation onto a slider. One helper rather than the same
-- two strings at 21 call sites, and it keeps the wording in ONE place -- the old per-page
-- label went stale the moment the scale changed (it still read "0=Auto" afterwards).
-- Takes the CONTAINER that CreateSlider returns, which is what every call site has.
function GUI:SetFrameLevelTooltip(container)
    if not container then return end
    container.tooltipText    = L["Frame Level"]
    container.tooltipSubText = L["Higher numbers draw on top of lower ones. Every Frame Level in DandersFrames uses the same scale, counted up from the unit frame, so you can compare them directly."]
    return container   -- chainable, so it wraps a CreateSlider call in place
end

-- Dual-handle range slider: two draggable handles select a [lo, hi] sub-range of
-- [minRange, maxRange]. Self-contained — the caller anchors the returned track
-- frame and reads values via the onChange callback. (:GetValues() also exists and
-- completes the SetValues pair, but no current consumer polls it.) Drag is
-- tracked on the track's own OnUpdate (no dependence on parent scripts), and a
-- mouse-button check releases the drag even if the cursor leaves the handle.
-- opts:
--   width(336), accent({r,g,b}=theme), minRange, maxRange, lo, hi,
--   scaleLabels({...} optional tick labels), scaleMin/scaleMax (label scale,
--   default minRange/maxRange — lets ticks stay on a fixed scale while the
--   handle range changes), display(FontString updated each change),
--   formatRange(fn(lo,hi)->str), formatOne(fn(v)->str),
--   onChange(fn(lo,hi) — fired on user-driven changes only, not SetValues).
-- Methods on the returned frame: :SetRange(min,max), :SetValues(lo,hi),
-- :GetValues()->lo,hi.
function GUI:CreateRangeSlider(parent, opts)
    opts = opts or {}
    local width = opts.width or 336
    local accent = opts.accent or GetThemeColor()

    local track = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    track:SetSize(width, 12)
    CreateElementBackdrop(track, {
        bgColor     = { 0.03, 0.03, 0.03, 1 },
        borderColor = { 0.2, 0.2, 0.2, 1 },
    })

    track.minRange = opts.minRange or 1
    track.maxRange = opts.maxRange or 40
    track.lo = opts.lo or track.minRange
    track.hi = opts.hi or track.maxRange

    local rangeFill = track:CreateTexture(nil, "ARTWORK")
    rangeFill:SetTexture("Interface\\Buttons\\WHITE8x8")
    rangeFill:SetVertexColor(accent.r, accent.g, accent.b, 0.5)
    rangeFill:SetHeight(10)
    rangeFill:SetPoint("TOP", 0, -1)

    local function MakeHandle()
        local h = CreateFrame("Button", nil, track)
        h:SetSize(8, 16)
        h:EnableMouse(true)
        local tex = h:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetTexture("Interface\\Buttons\\WHITE8x8")
        tex:SetVertexColor(accent.r, accent.g, accent.b, 1)
        return h
    end
    local minHandle, maxHandle = MakeHandle(), MakeHandle()
    track.minHandle, track.maxHandle = minHandle, maxHandle

    local function ValueToPos(value)
        local pct = (value - track.minRange) / (track.maxRange - track.minRange)
        return pct * (width - 4) + 2
    end
    local function PosToValue(pos)
        local pct = (pos - 2) / (width - 4)
        return math.floor(pct * (track.maxRange - track.minRange) + track.minRange + 0.5)
    end

    local function Redraw()
        local minPos, maxPos = ValueToPos(track.lo), ValueToPos(track.hi)
        minHandle:ClearAllPoints()
        minHandle:SetPoint("CENTER", track, "LEFT", minPos, 0)
        maxHandle:ClearAllPoints()
        maxHandle:SetPoint("CENTER", track, "LEFT", maxPos, 0)
        rangeFill:ClearAllPoints()
        rangeFill:SetPoint("LEFT", track, "LEFT", minPos, 0)
        rangeFill:SetWidth(math.max(maxPos - minPos, 2))
        if opts.display then
            if track.lo == track.hi then
                opts.display:SetText(opts.formatOne and opts.formatOne(track.lo) or tostring(track.lo))
            else
                opts.display:SetText(opts.formatRange and opts.formatRange(track.lo, track.hi)
                    or (track.lo .. " - " .. track.hi))
            end
        end
    end

    local dragging = nil
    local function ApplyCursor()
        local x = select(1, GUI:CursorPos(track))
        local trackLeft = track:GetLeft()
        if not trackLeft then return end
        local pos = math.max(2, math.min(x - trackLeft, width - 2))
        local value = math.max(track.minRange, math.min(PosToValue(pos), track.maxRange))
        if dragging == "min" then
            if value <= track.hi then track.lo = value end
        elseif dragging == "max" then
            if value >= track.lo then track.hi = value end
        end
        Redraw()
        if opts.onChange then opts.onChange(track.lo, track.hi) end
    end

    minHandle:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then dragging = "min" end end)
    maxHandle:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then dragging = "max" end end)
    track:SetScript("OnUpdate", function()
        if not dragging then return end
        if not IsMouseButtonDown("LeftButton") then dragging = nil; return end
        ApplyCursor()
    end)

    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function(_, b)
        if b ~= "LeftButton" then return end
        local x = select(1, GUI:CursorPos(track))
        local trackLeft = track:GetLeft()
        if not trackLeft then return end
        local value = PosToValue(x - trackLeft)
        if math.abs(value - track.lo) <= math.abs(value - track.hi) then
            if value <= track.hi then track.lo = math.max(track.minRange, value) end
        else
            if value >= track.lo then track.hi = math.min(track.maxRange, value) end
        end
        Redraw()
        if opts.onChange then opts.onChange(track.lo, track.hi) end
    end)

    if opts.scaleLabels then
        local sMin = opts.scaleMin or track.minRange
        local sMax = opts.scaleMax or track.maxRange
        for _, num in ipairs(opts.scaleLabels) do
            local pct = (num - sMin) / (sMax - sMin)
            local xPos = pct * (width - 4) + 2
            local lbl = track:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            lbl:SetText(num)
            lbl:SetTextColor(0.35, 0.35, 0.35)
            lbl:SetPoint("TOP", track, "BOTTOM", xPos - width / 2, -2)
        end
    end

    function track:SetRange(minR, maxR)
        self.minRange, self.maxRange = minR, maxR
        self.lo = math.max(minR, math.min(self.lo, maxR))
        self.hi = math.max(minR, math.min(self.hi, maxR))
        Redraw()
    end
    function track:SetValues(lo, hi)
        self.lo = math.max(self.minRange, math.min(lo, self.maxRange))
        self.hi = math.max(self.minRange, math.min(hi, self.maxRange))
        Redraw()
    end
    function track:GetValues() return self.lo, self.hi end

    Redraw()
    return track
end

function GUI:CreateColorPicker(parent, label, dbTable, dbKey, hasAlpha, callback, lightweightCallback, useLightweight)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 28)
    container.preferredHeight = GUI.RowHeight.colorpicker   -- factory-owned slot height (see GUI.RowHeight)
    container.rowKind = "colorpicker"
    container.fixedRowHeight = true
    
    -- Button - use relative anchoring so it resizes with container
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, 0)
    btn:SetPoint("TOPRIGHT", 0, 0)
    btn:SetHeight(SnapLen(btn, 24) or 24)
    CreateElementBackdrop(btn)

    -- Label
    local txt = btn:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    txt:SetPoint("LEFT", 8, 0)
    txt:SetText(label)
    txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
    
    -- Color swatch
    local swatch = btn:CreateTexture(nil, "OVERLAY")
    swatch:SetSize(40, 16)
    swatch:SetPoint("RIGHT", -6, 0)
    
    -- Add override indicators if dbKey is provided (for auto profiles)
    if dbKey and type(dbKey) == "string" then
        local function onReset()
            if DF.AutoProfilesUI then
                DF.AutoProfilesUI:ResetProfileSetting(dbKey)
                -- Refresh to global value
                local globalVal = DF.AutoProfilesUI:GetGlobalValue(dbKey)
                if globalVal then
                    dbTable[dbKey].r = globalVal.r
                    dbTable[dbKey].g = globalVal.g
                    dbTable[dbKey].b = globalVal.b
                    dbTable[dbKey].a = globalVal.a or 1
                end
                if container.UpdateSwatch then
                    container:UpdateSwatch()
                end
                if container.UpdateOverrideIndicators then
                    container:UpdateOverrideIndicators(dbTable[dbKey])
                end
                DF:UpdateAll()
            end
        end
        AddOverrideIndicators(container, txt, dbKey, onReset, nil, nil, dbTable)
    end
    
    local function UpdateSwatch()
        if dbTable and dbKey and dbTable[dbKey] then
            local c = dbTable[dbKey]
            swatch:SetColorTexture(c.r, c.g, c.b, c.a or 1)
            -- Update override indicators
            if container.UpdateOverrideIndicators then
                container:UpdateOverrideIndicators(c)
            end
        end
    end
    container.UpdateSwatch = UpdateSwatch  -- Expose for reset
    
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
    end)

    -- Tooltip: shared attach on the LABEL only. This factory carried none, across
    -- 87 colour pickers. The btn keeps its own hover scripts untouched — the hit
    -- frame is over the text, not the swatch.
    GUI:AttachTooltip(container, label, txt)

    btn:SetScript("OnClick", function()
        if not dbTable then return end
        local c = dbTable[dbKey]
        if not c then 
            c = {r = 1, g = 1, b = 1, a = 1}
            dbTable[dbKey] = c
        end
        
        -- Store original values for cancel
        local originalColor = {r = c.r, g = c.g, b = c.b, a = c.a or 1}

        -- Blizzard's SetupColorPickerAndShow fires swatchFunc once DURING
        -- setup (its SetColorRGB triggers OnColorSelect — the source comments
        -- it). That spurious fire re-writes the unchanged colour and runs the
        -- change callbacks on mere open: it commits per-element override flags
        -- (Text Designer) and triggers a pointless full refresh. Suppress
        -- callbacks until setup has returned.
        local settingUp = true
        
        local info = {
            swatchFunc = function()
                if settingUp then return end
                local r, g, b = ColorPickerFrame:GetColorRGB()
                local a = 1
                if hasAlpha and ColorPickerFrame.GetColorAlpha then
                    a = ColorPickerFrame:GetColorAlpha() or 1
                end
                dbTable[dbKey].r = r
                dbTable[dbKey].g = g
                dbTable[dbKey].b = b
                dbTable[dbKey].a = a
                
                -- If editing a profile, also set the override
                if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() and dbKey then
                    DF.AutoProfilesUI:SetProfileSetting(dbKey, {r = r, g = g, b = b, a = a})
                end
                
                UpdateSwatch()
                -- Use lightweight callback during dragging if available
                if useLightweight and lightweightCallback then
                    lightweightCallback()
                else
                    DF:ThrottledUpdateAll()
                    if callback then callback() end
                end
            end,
            hasOpacity = hasAlpha,
            opacityFunc = hasAlpha and function()
                if settingUp then return end
                if ColorPickerFrame.GetColorAlpha then
                    local a = ColorPickerFrame:GetColorAlpha()
                    if a then
                        dbTable[dbKey].a = a
                        UpdateSwatch()
                        -- Use lightweight callback during dragging if available
                        if useLightweight and lightweightCallback then
                            lightweightCallback()
                        else
                            DF:ThrottledUpdateAll()
                            if callback then callback() end
                        end
                    end
                end
            end or nil,
            cancelFunc = function(restore)
                -- Restore original color on cancel
                dbTable[dbKey].r = originalColor.r
                dbTable[dbKey].g = originalColor.g
                dbTable[dbKey].b = originalColor.b
                dbTable[dbKey].a = originalColor.a
                UpdateSwatch()
                DF:UpdateAll()
                if callback then callback() end
            end,
            r = c.r or 1, 
            g = c.g or 1, 
            b = c.b or 1, 
            opacity = hasAlpha and (c.a or 1) or nil,
        }
        
        -- Hook the OK button to run full update when confirmed
        if useLightweight and lightweightCallback then
            -- We need to run full update when picker is closed via OK
            -- Use a frame to detect when color picker closes
            if not container.colorPickerWatcher then
                container.colorPickerWatcher = CreateFrame("Frame")
            end
            container.colorPickerWatcher:SetScript("OnUpdate", function(self)
                if not ColorPickerFrame:IsShown() then
                    self:SetScript("OnUpdate", nil)
                    -- Only run if color changed (not cancelled)
                    local cur = dbTable[dbKey]
                    if cur.r ~= originalColor.r or cur.g ~= originalColor.g or 
                       cur.b ~= originalColor.b or cur.a ~= originalColor.a then
                        DF:UpdateAll()
                        if callback then callback() end
                    end
                end
            end)
        end
        
        -- Attach default colour so the picker can offer a Default button
        -- dbTable.__dfDefaults is set by callers (e.g. Aura Designer proxies) that
        -- store their defaults outside DF.PartyDefaults / DF.RaidDefaults. Read via
        -- rawget so proxies' __index doesn't see this lookup as a regular setting.
        local defaultVal = (dbTable and rawget(dbTable, "__dfDefaults") and dbTable.__dfDefaults[dbKey])
                        or (DF.PartyDefaults and DF.PartyDefaults[dbKey])
                        or (DF.RaidDefaults  and DF.RaidDefaults[dbKey])
        -- Fallback: power bar colours use WoW's PowerBarColor table as their default
        if not defaultVal and PowerBarColor and dbKey then
            defaultVal = PowerBarColor[dbKey]
        end
        if defaultVal and type(defaultVal) == "table" and defaultVal.r then
            info.dfDefaultColor = {r = defaultVal.r or 1, g = defaultVal.g or 1, b = defaultVal.b or 1, a = defaultVal.a or 1}
            -- Populate ElvUI's "Default" button (ColorPPDefault) so it enables and
            -- pastes the DF setting default when the native Blizzard picker is shown
            local elvDefault = _G["ColorPPDefault"]
            if elvDefault then
                elvDefault.colors = info.dfDefaultColor
            end
        end

        -- Mark this as a DandersFrames color picker call
        GUI:MarkColorPickerCall()
        ColorPickerFrame:SetupColorPickerAndShow(info)
        settingUp = false
    end)
    
    container.SetEnabled = function(self, enabled)
        -- Dim the whole widget so the colour swatch greys even when it's a dark
        -- colour (SetDesaturated alone is invisible on near-black swatches).
        self:SetAlpha(enabled and 1 or 0.4)
        btn:SetEnabled(enabled)
        if enabled then
            txt:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)
            swatch:SetDesaturated(false)
        else
            txt:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            swatch:SetDesaturated(true)
        end
    end
    
    btn:SetScript("OnShow", UpdateSwatch)
    UpdateSwatch()
    
    -- SEARCH: Register this setting
    if DF.Search and dbKey and type(dbKey) == "string" then
        container.searchEntry = DF.Search:RegisterColorPicker(label, dbKey, hasAlpha, nil, callback)
        DF.Search:LinkSourceWidget(container)
    end
    
    return container
end

function GUI:CreateOutlineDropdown(parent, label, dbTable, dbKey, callback, inheritKey)
    local options = {
        NONE = L["None"],
        OUTLINE = L["Outline"],
        THICKOUTLINE = L["Thick Outline"],
        MONOCHROME = L["Monochrome"],
        ["MONOCHROME, OUTLINE"] = L["Monochrome Outline"],
        ["MONOCHROME, THICKOUTLINE"] = L["Monochrome Thick Outline"],
        _order = OUTLINE_FLAG_ORDER,
    }
    local get = function() return DF:OutlineFlag(dbTable[dbKey] or (inheritKey and dbTable[inheritKey])) end
    local set = function(flag) dbTable[dbKey] = DF:ComposeOutline(flag, DF:OutlineHasShadow(dbTable[dbKey] or (inheritKey and dbTable[inheritKey]))) end
    return GUI:CreateDropdown(parent, label or L["Outline"], options, dbTable, dbKey, callback, get, set)
end

-- ⚠ inheritKey mirrors CreateOutlineDropdown's 5th argument, and exists for the same
-- reason: an outline key may be deliberately UNSET so it falls through to a shared one
-- (afkIconTimerOutline -> statusIconFontOutline). Without it this widget reads
-- dbTable[dbKey] raw, so on an inheriting key it would:
--   * report UNCHECKED while the inherited outline actually carries a shadow, and
--   * on first tick, compose from OutlineFlag(nil) and PIN the outline to NONE --
--     silently discarding the inherited style rather than just adding a shadow.
-- Both halves must consult the fallback, exactly as the dropdown does.
function GUI:CreateShadowCheckbox(parent, label, dbTable, dbKey, callback, inheritKey)
    local function effective() return dbTable[dbKey] or (inheritKey and dbTable[inheritKey]) end
    local get = function() return DF:OutlineHasShadow(effective()) end
    local set = function(val) dbTable[dbKey] = DF:ComposeOutline(DF:OutlineFlag(effective()), val) end
    return GUI:CreateCheckbox(parent, label or L["Shadow"], dbTable, dbKey, callback, get, set)
end

function GUI:CreateAnimationControls(group, dbTable, animPrefix, opts)
    opts = opts or {}
    local parent       = opts.parent
    local fullUpdate   = opts.fullUpdate or function() end
    local lightUpdate  = opts.lightUpdate
    local lightColors  = opts.lightColors
    local typeLabel    = opts.typeLabel or L["Border Animation"]
    local excludeTypes = opts.excludeTypes   -- optional set of animation-type keys to omit from the dropdown
    local hideExtra    = opts.hideExtra
    local onTypeChange = opts.onTypeChange or function() end
    local showPerfBanner = opts.perfBanner ~= false

    local function aKey(suffix) return animPrefix .. suffix end
    local animTypeKey = aKey("Type")
    local function animType() return dbTable[animTypeKey] or "NONE" end
    local function extraOff() return (hideExtra and hideExtra()) or false end
    local function animOff()  return extraOff() or animType() == "NONE" end

    -- Sets of effect types each tunable applies to (truthiness on a
    -- string-keyed set). Mirrors the per-effect parameter map — keep in
    -- sync with StartAnimation's branches in Frames/Border.lua.
    -- DF_DASH: Frequency = march SPEED (0 = static dashed), Thickness = dash
    -- thickness, Inset = dash inset.
    local hasFrequency = { DF_PULSATE=1,
                           DF_DASH=1, BLINK=1, DF_ORBIT=1, DF_PROC=1, DF_FLASH=1, DF_PIXEL=1 }
    local hasParticles = { DF_ORBIT=1, DF_PIXEL=1 }
    -- CORNERS_ONLY is hidden from the type dropdown below, but keep its param
    -- entries so an indicator that still carries a saved CORNERS_ONLY value shows
    -- the right controls.
    local hasThickness = { CORNERS_ONLY=1, DF_DASH=1, BLINK=1, DF_PIXEL=1 }
    -- Inset / Offset apply to every non-NONE effect EXCEPT DF_PULSATE (which
    -- modulates the border's own edges and has no separate animRect).
    local hasPositioning = { CORNERS_ONLY=1, DF_DASH=1, BLINK=1, DF_ORBIT=1, DF_PROC=1, DF_FLASH=1, DF_PIXEL=1 }
    -- Scale slider = sparkle size (DF Chase).
    local hasScale     = { DF_ORBIT=1 }
    -- Length slider = bar length (DF Pixel's chasing bars).
    local hasLength    = { DF_PIXEL=1 }
    local cornersOnly  = { CORNERS_ONLY=1 }
    local function hideUnless(set)
        return function()
            if animOff() then return true end
            return not set[animType()]
        end
    end

    local w = {}

    -- All DF-owned border effects (no external glow library). The "DF " labels
    -- are kept from when they sat alongside the retired LCG glows.
    local animTypeOptions = {
        NONE = L["None"],
        DF_PULSATE = L["DF Pulsate"],
        DF_ORBIT = L["DF Chase"],
        DF_DASH = L["DF Dash"],
        DF_FLASH = L["DF Flash"],
        DF_PIXEL = L["DF Pixel"],
        DF_PROC = L["DF Proc"],
        BLINK = L["Blink"],
        -- None first (the "off" option), then alphabetical by label. CORNERS_ONLY
        -- is intentionally absent — it's kept in the engine (an existing saved
        -- value still renders) but no longer offered as a pickable animation.
        _order = { "NONE", "BLINK", "DF_ORBIT",
                   "DF_DASH", "DF_FLASH", "DF_PIXEL", "DF_PROC", "DF_PULSATE" },
    }
    -- Optional caller filter: drop any excluded type from both the value map and
    -- the display order (e.g. the Aura Designer border offers only the taint-safe,
    -- overlay-recoverable animations — no LCG glows).
    if excludeTypes then
        for k in pairs(excludeTypes) do animTypeOptions[k] = nil end
        local filteredOrder = {}
        for _, k in ipairs(animTypeOptions._order) do
            if not excludeTypes[k] then filteredOrder[#filteredOrder + 1] = k end
        end
        animTypeOptions._order = filteredOrder
    end
    w.animationType = group:AddWidget(GUI:CreateDropdown(parent, typeLabel,
        animTypeOptions,
        dbTable, animTypeKey, onTypeChange), 55)
    -- Type dropdown respects only the extra gate (e.g. Show Border). With no
    -- extra gate (Expiring override) it's always visible.
    w.animationType.hideOn = hideExtra or function() return false end

    -- Perf warning: animations run an OnUpdate (or LCG internal animation)
    -- per active border, which adds up in 20-30 player raids.
    if showPerfBanner then
        -- staticHeight ONLY where the host reflows widget WIDTHS on every layout
        -- pass — i.e. the Aura Designer indicator card (its parent carries
        -- dfAD_ReflowWidgets). There a self-sizing banner feeds a SetHeight ->
        -- OnSizeChanged -> relayout -> SetWidth loop that drops FPS, so we predict
        -- a fixed height instead. On normal settings pages the host lays out once,
        -- so the banner MUST self-size to its wrapped text: a fixed height
        -- overflows (text spills past the box) on narrow windows until a manual
        -- drag forces a relayout.
        local reflowingHost = parent and parent.dfAD_ReflowWidgets ~= nil
        local perfBanner = GUI:CreateInfoBanner(parent, {
            tone = "caution",
            text = L["Animations run per-border and may impact FPS in larger raids. Use sparingly on high-priority alerts."],
            staticHeight = reflowingHost or nil,
            minHeight    = 56,
        })
        w.animationPerfBanner = group:AddWidget(perfBanner, perfBanner.layoutHeight)
        w.animationPerfBanner.hideOn = animOff
    end

    -- Animation colour applies to every effect except DF_PULSATE (which
    -- modulates the border's own edge alpha — no separate colour). lightColors
    -- is threaded through so AD's proxy gets live preview while dragging.
    w.animationColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Animation Color"],
        dbTable, aKey("Color"), true, fullUpdate, lightColors, lightColors ~= nil), 35)
    w.animationColor.hideOn = function()
        return animOff() or animType() == "DF_PULSATE"
    end

    -- Min 0: DF_DASH reads Frequency as march speed, so 0 = static dashed.
    -- The LCG glows treat 0 as their default rate (clamped in StartAnimation),
    -- and the OnUpdate effects fall back to a sensible default period at 0.
    w.animationFrequency = group:AddWidget(GUI:CreateSlider(parent, L["Animation Frequency"],
        0, 4, 0.05, dbTable, aKey("Frequency"),
        fullUpdate, lightUpdate, true), 55)
    w.animationFrequency.hideOn = hideUnless(hasFrequency)
    -- ⚠ This slider genuinely means different things per effect (see the comment
    -- above), which is exactly why it needs saying out loud — nobody discovers
    -- "0 = hold still" by dragging.
    w.animationFrequency.tooltip = L["How fast the effect runs. On DF Dash this is how quickly the dashes march around the edge, and 0 holds them still. On the others it is the pulse rate, where 0 means the effect's own default speed."]

    w.animationParticles = group:AddWidget(GUI:CreateSlider(parent, L["Animation Particles"],
        1, 16, 1, dbTable, aKey("Particles"),
        fullUpdate, lightUpdate, true), 55)
    w.animationParticles.hideOn = hideUnless(hasParticles)
    w.animationParticles.tooltip = L["How many separate lights travel around the border. More reads as busier and costs a little more to draw."]

    w.animationLength = group:AddWidget(GUI:CreateSlider(parent, L["Animation Length"],
        1, 30, 1, dbTable, aKey("Length"),
        fullUpdate, lightUpdate, true), 55)
    w.animationLength.hideOn = hideUnless(hasLength)
    w.animationLength.tooltip = L["How long each moving segment is. Short values read as darting sparks, long ones as a sweeping tail."]

    w.animationThickness = group:AddWidget(GUI:CreateSlider(parent, L["Animation Thickness"],
        1, 12, 1, dbTable, aKey("Thickness"),
        fullUpdate, lightUpdate, true), 55)
    w.animationThickness.hideOn = hideUnless(hasThickness)
    w.animationThickness.tooltip = L["How heavy the moving effect is. Separate from Border Thickness — the animation draws on its own layer, so it can be thicker or thinner than the border underneath."]

    w.animationScale = group:AddWidget(GUI:CreateSlider(parent, L["Animation Scale"],
        0.5, 3, 0.05, dbTable, aKey("Scale"),
        fullUpdate, lightUpdate, true), 55)
    w.animationScale.hideOn = hideUnless(hasScale)

    w.animationInset = group:AddWidget(GUI:CreateSlider(parent, L["Animation Inset"],
        -50, 50, 1, dbTable, aKey("Inset"),
        fullUpdate, lightUpdate, true), 55)
    w.animationInset.hideOn = hideUnless(hasPositioning)
    w.animationInset.tooltip = L["Moves the effect in or out from the edge, independently of the border. Push it outward to make a glow spill past the frame."]

    w.animationOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Animation Offset X"],
        -50, 50, 1, dbTable, aKey("OffsetX"),
        fullUpdate, lightUpdate, true), 55)
    w.animationOffsetX.hideOn = hideUnless(hasPositioning)

    w.animationOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Animation Offset Y"],
        -50, 50, 1, dbTable, aKey("OffsetY"),
        fullUpdate, lightUpdate, true), 55)
    w.animationOffsetY.hideOn = hideUnless(hasPositioning)

    -- DF Flash / DF Proc: skip the one-shot intro burst (glow-only).
    w.animationHideIntro = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide Intro Flash"],
        dbTable, aKey("ProcStart"), fullUpdate), 30)
    w.animationHideIntro.hideOn = hideUnless({ DF_FLASH = 1, DF_PROC = 1 })
    w.animationHideIntro.tooltip = L["These effects open with a one-off burst before settling into their loop. Turn this on to skip the burst and go straight to the loop."]

    w.animationCornerLength = group:AddWidget(GUI:CreateSlider(parent, L["Corner Length"],
        2, 40, 1, dbTable, aKey("CornerLength"),
        fullUpdate, lightUpdate, true), 55)
    w.animationCornerLength.hideOn = hideUnless(cornersOnly)
    w.animationCornerLength.tooltip = L["How far the effect runs along each edge from the corner before stopping. Small values leave four short brackets instead of a full outline."]

    return w
end

function GUI:CreateBorderControls(group, dbTable, prefix, opts)
    opts = opts or {}
    local parent       = opts.parent
    local include      = opts.include or {}
    local fullUpdate   = opts.fullUpdate or function() end
    local lightUpdate  = opts.lightUpdate
    local lightColors  = opts.lightColors
    local refreshStates = opts.refreshStates
    local hideWhen     = opts.hideWhen
    local disableWhen  = opts.disableWhen

    local sizeMin, sizeMax, sizeStep = opts.sizeMin or 0, opts.sizeMax or 8, opts.sizeStep or 1
    local offMin, offMax, offStep    = opts.offsetMin or -50, opts.offsetMax or 50, opts.offsetStep or 1

    local function key(suffix) return prefix .. suffix end
    local showKey = key("ShowBorder")
    -- The Show toggle only respects the parent-level hideWhen. Everything
    -- else respects hideWhen OR the Show toggle being off.
    --
    -- hideOn predicates IGNORE the table arg LayoutChildren passes (which is
    -- always `DF.db[GUI.SelectedMode]`) and read from the captured `dbTable`
    -- instead.  For consumers whose dbTable == DF.db[mode] (Frame Border,
    -- Defensive Icon, etc.) the two are identical so behaviour is unchanged.
    -- For consumers with a different dbTable — notably Aura Designer's
    -- per-aura proxy — this is the only way the visibility predicates see
    -- the actual border state (e.g. proxy.BorderStyle, not the unrelated
    -- DF.db.party.BorderStyle which doesn't exist).
    local function hideShow() return hideWhen and hideWhen(dbTable) or false end
    -- Show Border OFF no longer HIDES the border controls — they stay visible and
    -- GREY OUT (disableOn = borderOff, applied by the loop at the end of this
    -- function) so the panel previews them. `hideOff` now means "hidden by the
    -- parent/variant gate only" (whatever the consumer passes via hideWhen); the
    -- name is kept so the existing `.hideOn = hideOff` references read unchanged.
    local function hideOff()  return hideShow() end
    local function borderOff() return dbTable[showKey] == false end

    local w = {}

    -- opts.noShowToggle: suppress the built-in "Show Border" checkbox for
    -- consumers that gate the whole border on an external toggle (e.g. the
    -- Targeted Spells "Highlight Important Spells" master). With the checkbox
    -- gone, showKey stays nil so hideOff() reduces to hideShow() — the toolkit
    -- shows/hides purely on the external hideWhen.
    if not opts.noShowToggle then
        w.show = group:AddWidget(GUI:CreateCheckbox(parent, L["Show Border"], dbTable, showKey, function()
            if refreshStates then refreshStates() end
            fullUpdate()
        end), 30)
        w.show.hideOn = hideShow
    end

    -- Slider label reads "Border Thickness" (more meaningful than "Size") but
    -- the underlying db key stays `<prefix>BorderSize` and spec.size in the
    -- backend stays the same — purely a user-facing rename, no migration.
    w.size = group:AddWidget(GUI:CreateSlider(parent, L["Border Thickness"], sizeMin, sizeMax, sizeStep,
        dbTable, key("BorderSize"), fullUpdate, lightUpdate, true), 55)
    w.size.hideOn = hideOff

    -- Gradient is a STYLE, not a separate toggle. When the consumer opts into
    -- gradient via include.gradient, we expose GRADIENT as a third dropdown
    -- option. Otherwise the dropdown is the original SOLID / TEXTURE pair.
    local styleOptions = { SOLID = L["Solid"], TEXTURE = L["Texture"],
        _order = { "SOLID", "TEXTURE" } }
    if include.gradient then
        styleOptions.GRADIENT = L["Gradient"]
        -- Insert GRADIENT between SOLID and TEXTURE so the order reads
        -- "simple colour → two colours → custom texture" in the dropdown.
        styleOptions._order = { "SOLID", "GRADIENT", "TEXTURE" }
    end
    w.style = group:AddWidget(GUI:CreateDropdown(parent, L["Border Style"],
        styleOptions, dbTable, key("BorderStyle"), function()
            -- Match the frame border: pick the first LSM border when switching
            -- to Texture without one configured.
            if dbTable[key("BorderStyle")] == "TEXTURE" then
                local list = DF.GetBorderList and DF:GetBorderList() or nil
                local t = dbTable[key("BorderTexture")]
                if list and (not t or t == "" or t == "SOLID") then
                    dbTable[key("BorderTexture")] = next(list)
                end
            end
            if refreshStates then refreshStates() end
            fullUpdate()
        end), 55)
    w.style.hideOn = hideOff

    -- isGradient is declared up here so the Style-dependent widget cluster
    -- (Texture under TEXTURE style, gradient pickers under GRADIENT style)
    -- can sit immediately below the Style dropdown — the consequence of the
    -- user's style choice reads top-to-bottom without scrolling past
    -- unrelated inset / offset / blend controls first.
    local function isGradient() return dbTable[key("BorderStyle")] == "GRADIENT" end

    w.texture = group:AddWidget(GUI:CreateDropdown(parent, L["Border Texture"],
        DF:GetBorderList(), dbTable, key("BorderTexture"), fullUpdate), 55)
    w.texture.hideOn = function()
        return hideOff() or dbTable[key("BorderStyle")] ~= "TEXTURE"
    end

    -- Gradient pickers — only visible under Style = GRADIENT.  Grouped here
    -- (between Texture and the Colour Source dropdown) so all style-dependent
    -- widgets sit directly under the Style dropdown that controls them.
    -- The standalone "Border Gradient" checkbox was removed when Style
    -- absorbed it; Style is now the single source of truth so it's not
    -- possible to pick "Solid + Class Color" then have a Gradient checkbox
    -- stomp the class colour (the previous UX bug).  Legacy
    -- `<prefix>BorderGradientEnabled = true` profiles are migrated to
    -- `<prefix>BorderStyle = "GRADIENT"` on db load.
    if include.gradient then
        local function gradHide() return hideOff() or not isGradient() end

        w.gradientStart = group:AddWidget(GUI:CreateColorPicker(parent, L["Gradient Start Color"],
            dbTable, key("BorderGradientStartColor"), true, fullUpdate), 35)
        w.gradientStart.hideOn = gradHide
        w.gradientEnd = group:AddWidget(GUI:CreateColorPicker(parent, L["Gradient End Color"],
            dbTable, key("BorderGradientEndColor"), true, fullUpdate), 35)
        w.gradientEnd.hideOn = gradHide
        w.gradientDirection = group:AddWidget(GUI:CreateDropdown(parent, L["Gradient Direction"],
            { HORIZONTAL = L["Horizontal"], VERTICAL = L["Vertical"] },
            dbTable, key("BorderGradientDirection"), fullUpdate), 55)
        w.gradientDirection.hideOn = gradHide
    end

    -- Colour Source dropdown sits ABOVE the colour picker so the relationship
    -- "source → resulting colour" reads top-to-bottom in the panel. The
    -- options table is built dynamically: Static is always present; Class
    -- and Role are added if the consumer opted in via the matching include.
    -- Hidden in GRADIENT style — gradient owns its own colours, no resolver
    -- chain applies (see Border:BuildSpec).
    local sourceKey = key("BorderColorSource")
    local hasSourceDropdown = include.classColor or include.roleColor
    if hasSourceDropdown then
        local sourceOptions = { STATIC = L["Static"], _order = { "STATIC" } }
        if include.classColor then
            sourceOptions.CLASS = L["Class"]
            sourceOptions._order[#sourceOptions._order + 1] = "CLASS"
        end
        if include.roleColor then
            sourceOptions.ROLE = L["Role"]
            sourceOptions._order[#sourceOptions._order + 1] = "ROLE"
        end
        -- Default the source from the legacy boolean keys when first opened.
        if dbTable[sourceKey] == nil then
            if dbTable[key("BorderUseClassColor")]     then dbTable[sourceKey] = "CLASS"
            elseif dbTable[key("BorderUseRoleColor")]  then dbTable[sourceKey] = "ROLE"
            else                                            dbTable[sourceKey] = "STATIC" end
        end
        w.colorSource = group:AddWidget(GUI:CreateDropdown(parent, L["Border Color Source"],
            sourceOptions, dbTable, sourceKey, function()
                if refreshStates then refreshStates() end
                fullUpdate()
            end), 55)
        w.colorSource.hideOn = function() return hideOff() or isGradient() end
        w.colorSource.tooltip = L["Where the border colour comes from. Static uses the colour below; Class and Role read it from the unit, so the border tells you who you are looking at without reading the name."]
    end

    -- Static colour picker — only visible when source is STATIC (or when the
    -- consumer didn't enable any resolver at all, so source doesn't exist).
    -- Hidden in GRADIENT style (gradient uses its own start/end pickers).
    w.color = group:AddWidget(GUI:CreateColorPicker(parent, L["Border Color"], dbTable, key("BorderColor"),
        true, fullUpdate, lightColors, lightColors ~= nil), 35)
    w.color.hideOn = function()
        if hideOff() or isGradient() then return true end
        if hasSourceDropdown then
            local src = dbTable[sourceKey] or "STATIC"
            return src ~= "STATIC"
        end
        return false
    end

    -- Unified Border Alpha slider — opt-in via include.alpha. Reads / writes
    -- the SAME alpha component the colour picker exposes
    -- (<prefix>BorderColor.a), so the slider is just a convenient handle for
    -- the picker's alpha bar — no separate alpha key to migrate or keep in
    -- sync. Visible in STATIC / CLASS / ROLE; hidden in GRADIENT (where the
    -- two gradient pickers each carry their own alpha, and a single slider
    -- has no obvious meaning).
    if include.alpha then
        -- Ensure the underlying colour table has an alpha component so the
        -- slider doesn't read nil on first open. The picker also seeds .a but
        -- we don't depend on widget-creation order.
        local c = dbTable[key("BorderColor")]
        if type(c) ~= "table" then
            c = { r = 0, g = 0, b = 0, a = 1 }
            dbTable[key("BorderColor")] = c
        end
        if c.a == nil then c.a = 1 end

        -- Read-time nil-guard: these closures fire on the slider's OnShow at
        -- arbitrary later times (tab/page re-show, mode switch), NOT just at
        -- creation. The seed above only guarantees the table exists NOW — a proxy
        -- dbTable can resolve BorderColor to nil later (e.g. re-showing the AD page
        -- for a mode whose config doesn't surface the key), so re-read and guard
        -- each call instead of assuming the table is still there.
        w.alpha = group:AddWidget(GUI:CreateSlider(parent, L["Border Alpha"], 0, 1, 0.05,
            nil, nil, fullUpdate, lightColors or lightUpdate, true,
            function()
                local bc = dbTable[key("BorderColor")]
                return (bc and bc.a) or 1
            end,
            function(v)
                local bc = dbTable[key("BorderColor")]
                if bc then bc.a = v end
            end), 55)
        w.alpha.hideOn = function() return hideOff() or isGradient() end
    end

    if include.inset then
        w.inset = group:AddWidget(GUI:CreateSlider(parent, L["Border Inset"], -20, 20, 1,
            dbTable, key("BorderInset"), fullUpdate, lightUpdate, true), 55)
        w.inset.hideOn = hideOff
        -- Thickness / Inset / Offset are three similar-sounding sliders that do
        -- different things; the tooltip lives here because Inset is the one
        -- nobody guesses.
        w.inset.tooltip = L["Pulls the border inward (positive) or pushes it outward (negative) from the edge. Thickness is how heavy the line is, Inset is how far in it sits, Offset slides the whole border sideways."]
    end

    if include.offset then
        w.offsetX = group:AddWidget(GUI:CreateSlider(parent, L["Border Offset X"], offMin, offMax, offStep,
            dbTable, key("BorderOffsetX"), fullUpdate, lightUpdate, true), 55)
        w.offsetX.hideOn = hideOff
        w.offsetY = group:AddWidget(GUI:CreateSlider(parent, L["Border Offset Y"], offMin, offMax, offStep,
            dbTable, key("BorderOffsetY"), fullUpdate, lightUpdate, true), 55)
        w.offsetY.hideOn = hideOff
        -- No tooltip on Offset X/Y, deliberately, and the same goes for every
        -- other Offset slider in the addon (~60 of them): an offset is a well
        -- understood control and a tooltip restating it is noise. Inset is the
        -- one that needs explaining, so the Thickness / Inset / Offset
        -- distinction is spelled out THERE, once. Krathe's call, 2026-07-27 —
        -- these two briefly had tooltips and Border Shadow's offsets did not,
        -- which is the inconsistency that prompted it.
    end

    if include.blendMode then
        w.blendMode = group:AddWidget(GUI:CreateDropdown(parent, L["Border Blend Mode"],
            { BLEND = L["Blend"], ADD = L["Add"], MOD = L["Modulate"], DISABLE = L["Disable"] },
            dbTable, key("BorderBlendMode"), fullUpdate), 55)
        w.blendMode.hideOn = hideOff
        w.blendMode.tooltip = L["How the border colour mixes with whatever is behind it. Blend is normal. Add brightens and is what makes a colour glow. Modulate darkens. Disable ignores opacity entirely and draws the colour flat."]
    end

    if include.shadow then
        local shadowOnKey = key("BorderShadowEnabled")
        w.shadowEnabled = group:AddWidget(GUI:CreateCheckbox(parent, L["Border Shadow"], dbTable, shadowOnKey, function()
            if refreshStates then refreshStates() end
            fullUpdate()
        end), 30)
        w.shadowEnabled.hideOn = hideOff
        -- Border Shadow OFF greys (not hides) its sub-controls — a nested boolean
        -- toggle, same grey-everything rule. The end-of-function loop OR-composes
        -- borderOff, so these also grey when Show Border is off.
        local function shadowOff() return dbTable[shadowOnKey] == false end

        w.shadowColor = group:AddWidget(GUI:CreateColorPicker(parent, L["Shadow Color"],
            dbTable, key("BorderShadowColor"), true, fullUpdate), 35)
        w.shadowColor.hideOn = hideOff
        w.shadowColor.disableOn = shadowOff
        w.shadowSize = group:AddWidget(GUI:CreateSlider(parent, L["Shadow Size"], 0, 10, 1,
            dbTable, key("BorderShadowSize"), fullUpdate, lightUpdate, true), 55)
        w.shadowSize.hideOn = hideOff
        w.shadowSize.disableOn = shadowOff
        w.shadowOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Shadow Offset X"], -10, 10, 1,
            dbTable, key("BorderShadowOffsetX"), fullUpdate, lightUpdate, true), 55)
        w.shadowOffsetX.hideOn = hideOff
        w.shadowOffsetX.disableOn = shadowOff
        w.shadowOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Shadow Offset Y"], -10, 10, 1,
            dbTable, key("BorderShadowOffsetY"), fullUpdate, lightUpdate, true), 55)
        w.shadowOffsetY.hideOn = hideOff
        w.shadowOffsetY.disableOn = shadowOff
    end

    -- ===== Animation (Stage 3) =====
    -- include.animate drops the full Border Animation control set (Type
    -- dropdown + per-effect tunables, each with a hideOn keyed to the effect
    -- it applies to). Built from the shared GUI:CreateAnimationControls so the
    -- base panel and AD's Expiring override never drift. The whole block folds
    -- under Show Border via hideExtra = hideOff. Widget handles are merged back
    -- onto `w` so existing references (w.animationType, …) are preserved.
    if include.animate then
        local aw = GUI:CreateAnimationControls(group, dbTable, key("BorderAnimation"), {
            parent       = parent,
            fullUpdate   = fullUpdate,
            lightUpdate  = lightUpdate,
            lightColors  = lightColors,
            typeLabel    = L["Border Animation"],
            -- Optional caller filter, forwarded from the CreateBorderControls call
            -- site (e.g. the Aura Designer border restricts to overlay-recoverable
            -- animation types). nil for every other caller → full type list.
            excludeTypes = opts.animExcludeTypes,
            hideExtra    = hideOff,
            onTypeChange = function()
                if refreshStates then refreshStates() end
                fullUpdate()
            end,
        })
        for k, v in pairs(aw) do w[k] = v end
    end

    -- ===== Colour resolver toggles (Stage 2) =====
    -- These flip BorderColor's source from the static picker to a per-unit /
    -- per-aura / per-tick computation. BuildSpec applies them in priority
    -- order (type > time > class > role > static) when the consumer passes
    -- ctx to BuildSpec. The static colour picker still controls the fallback
    -- (when ctx is missing or the resolver yields nil).

    -- (Colour Source dropdown + Static colour picker + Alpha slider are wired
    -- earlier, above the inset/offset/blendMode/gradient/shadow block, so the
    -- relationship "source → colour" reads top-to-bottom in the panel.)

    if include.colorByTime then
        w.colorByTime = group:AddWidget(GUI:CreateCheckbox(parent, L["Color by Time Remaining"], dbTable, key("BorderColorByTime"), fullUpdate), 30)
        w.colorByTime.hideOn = hideOff
        -- The actual colour curve picker is consumer-specific (e.g. AD's
        -- existing expiring colour curve) and is added by the consumer
        -- alongside this checkbox.
    end

    if include.colorByType then
        w.colorByType = group:AddWidget(GUI:CreateCheckbox(parent, L["Color by Aura Type"], dbTable, key("BorderColorByType"), fullUpdate), 30)
        w.colorByType.hideOn = hideOff
    end

    -- Two independent greys, both composed on top of whatever disableOn a control
    -- already carries (e.g. the shadow sub-controls), and both leaving the
    -- variant hideOn untouched:
    --   disableWhen — the CONSUMER's gate: the feature this border belongs to is
    --     switched off. Applies to EVERY widget including the Show Border
    --     checkbox, since with the feature off there is nothing for it to show.
    --   borderOff   — Show Border itself is off. Applies to everything EXCEPT the
    --     Show Border checkbox, which has to stay clickable to turn it back on.
    -- RefreshChildStates applies disableOn to group children, and CreateCheckbox
    -- auto-refreshes on toggle, so both greys update live.
    for k, widget in pairs(w) do
        if type(widget) == "table" and widget.SetEnabled then
            local prev = widget.disableOn
            local isShow = (k == "show")
            widget.disableOn = function(d)
                if disableWhen and disableWhen(dbTable) then return true end
                if not isShow and borderOff() then return true end
                return (prev and prev(d)) or false
            end
        end
    end

    return w
end

function GUI:CreateTextControls(group, dbTable, prefix, opts)
    opts = opts or {}
    local parent   = opts.parent
    local include  = opts.include or {}
    local onChange = opts.onChange
    local onDrag   = opts.onDrag or onChange
    local L = DF.L

    local scaleMin, scaleMax, scaleStep = opts.scaleMin or 0.5, opts.scaleMax or 2.0, opts.scaleStep or 0.05
    local offMin, offMax = opts.offsetMin or -150, opts.offsetMax or 150

    local function key(suffix) return prefix .. suffix end
    local widgets = {}

    -- Apply the shared page gates to a widget, composing with any the widget factory set.
    local function gate(w)
        if opts.disableOn then
            local prev = w.disableOn
            w.disableOn = function(d) return (opts.disableOn(d) or (prev and prev(d))) and true or false end
        end
        if opts.hideOn then w.hideOn = opts.hideOn end
        return w
    end

    widgets.font = gate(group:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], dbTable, key("Font"), onChange), 55))
    widgets.scale = gate(group:AddWidget(GUI:CreateSlider(parent, L["Scale"], scaleMin, scaleMax, scaleStep, dbTable, key("Scale"), nil, onDrag, true), 55))
    widgets.outline = gate(group:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], dbTable, key("Outline"), onChange), 55))
    widgets.shadow = gate(group:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], dbTable, key("Outline"), onChange), 30))

    if include.color then
        widgets.color = gate(group:AddWidget(GUI:CreateColorPicker(parent, opts.colorLabel or L["Text Color"], dbTable, key("Color"), false, onChange, onDrag, true), 35))
        if opts.colorDisableOn then
            local prev = widgets.color.disableOn
            widgets.color.disableOn = function(d) return (opts.colorDisableOn(d) or (prev and prev(d))) and true or false end
        end
    end

    if include.anchor ~= false then
        local anchorOptions = {
            CENTER = L["Center"], TOP = L["Top"], BOTTOM = L["Bottom"], LEFT = L["Left"], RIGHT = L["Right"],
            TOPLEFT = L["Top Left"], TOPRIGHT = L["Top Right"], BOTTOMLEFT = L["Bottom Left"], BOTTOMRIGHT = L["Bottom Right"],
        }
        widgets.anchor = gate(group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, dbTable, key("Anchor"), onChange), 55))
        -- Anchor vs Justify is the pair people get wrong: one places the text,
        -- the other arranges it within its own box. Both say so, from their side.
        widgets.anchor.tooltip = L["Which part of the element the text is pinned to. Offset X and Y then nudge it from there."]
    end

    if include.offsets ~= false then
        widgets.offsetX = gate(group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], offMin, offMax, 1, dbTable, key("X"), nil, onDrag, true), 55))
        widgets.offsetY = gate(group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], offMin, offMax, 1, dbTable, key("Y"), nil, onDrag, true), 55))
    end

    -- Justify is OPT-IN (include.justify = true). It's redundant with Anchor for short
    -- single-token text on a small icon (duration/stacks) and boxing to justify TRUNCATES
    -- wide text like "59m" — so the aura pages don't expose it. The DF.TextStyle engine
    -- still honors JustifyH/JustifyV keys for a future wide/fixed-region consumer.
    if include.justify then
        local justifyHOptions = { [""] = L["Default"], LEFT = L["Left"], CENTER = L["Center"], RIGHT = L["Right"] }
        local justifyVOptions = { [""] = L["Default"], TOP = L["Top"], MIDDLE = L["Middle"], BOTTOM = L["Bottom"] }
        widgets.justifyH = gate(group:AddWidget(GUI:CreateDropdown(parent, L["Justify H"], justifyHOptions, dbTable, key("JustifyH"), onChange), 55))
        widgets.justifyH.tooltip = L["How the text sits inside its own box, once Anchor has decided where that box goes. Only visible on text wide enough to have slack — Anchor is what moves it around the element."]
        widgets.justifyV = gate(group:AddWidget(GUI:CreateDropdown(parent, L["Justify V"], justifyVOptions, dbTable, key("JustifyV"), onChange), 55))
        widgets.justifyV.tooltip = L["How the text sits inside its own box, once Anchor has decided where that box goes. Only visible on text wide enough to have slack — Anchor is what moves it around the element."]
    end

    return widgets
end

