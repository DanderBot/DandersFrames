-- Part 2 of the GUI toolkit, split from the original GUI.lua.
-- These re-declarations are aliases of the SAME objects the first part
-- created; they add no state. See docs/reorg-tools/splits.manifest.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's,
-- so every DF.* read here would be nil. DandersFrames publishes its own table
-- as a global via ## AllowAddOnTableAccess -- take it from there.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L
local S = GUI._state
local P = GUI._priv
local C_BACKGROUND, C_TEXT, C_TEXT_DIM =
      GUI.Colors.background, GUI.Colors.text, GUI.Colors.textDim
local ResolveRowHeight = GUI.ResolveRowHeight
local GetThemeColor = GUI.GetThemeColor
local SnapLen = GUI.SnapLen
local CreateElementBackdrop = GUI._priv.CreateElementBackdrop
-- Tooltip primitives and the tone palette are resident: live frames need them
-- with this addon unloaded. Aliases of those objects, not copies.
local INFO_BANNER_TONES = P.INFO_BANNER_TONES
local AddTooltipLines = P.AddTooltipLines


function GUI:CreateSettingsGroup(parent, width, opts)
    -- opts can be a boolean (legacy: collapsible) or a table { collapsible, showSummary, onCollapseChanged }
    if type(opts) == "boolean" then opts = { collapsible = opts } end
    opts = opts or {}

    local group = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    group.onCollapseChanged = opts.onCollapseChanged
    group:SetSize(width or 280, 10)  -- Height will be calculated dynamically
    group.groupChildren = {}
    group.isSettingsGroup = true
    group.collapsible = opts.collapsible or false
    group.showSummary = opts.showSummary or false
    -- Optional saved-state key override: lets several boxes share a standard
    -- display header (e.g. "Appearance") while persisting collapse state under a
    -- unique key (e.g. "afkIcon:Appearance"), so they don't toggle together.
    group.collapseKey = opts.collapseKey
    group.collapsed = false

    -- Visual styling - subtle background and border
    local padding = 10
    local margin = 10  -- Space between groups
    group.padding = padding
    group.margin = margin

    -- 8%, and worth knowing why it is not 16%: it was, for a while, because an
    -- 8% edge that split across two device rows left 4% on each and neither was
    -- visible. Doubling it made the surviving half readable at the cost of the
    -- whole border reading too heavy when it did NOT split. The border no longer
    -- has to survive being split, because it no longer splits -- so the alpha
    -- went back to the value that was right in the first place.
    CreateElementBackdrop(group, {
        bgColor     = { 1, 1, 1, 0.03 },   -- very subtle white background (3%)
        borderColor = { 1, 1, 1, 0.08 },   -- subtle white border (8%)
    })

    -- Bottom collapse bar (only for collapsible groups, shown when expanded)
    if group.collapsible then
        local collapseBar = CreateFrame("Button", nil, group)
        collapseBar:SetHeight(14)
        collapseBar:SetPoint("BOTTOMLEFT", group, "BOTTOMLEFT", 1, 1)
        collapseBar:SetPoint("BOTTOMRIGHT", group, "BOTTOMRIGHT", -1, 1)

        local barBg = collapseBar:CreateTexture(nil, "BACKGROUND")
        barBg:SetAllPoints()
        barBg:SetColorTexture(1, 1, 1, 0.03)

        local barIcon = collapseBar:CreateTexture(nil, "OVERLAY")
        barIcon:SetSize(12, 12)
        barIcon:SetPoint("CENTER", 0, 0)
        local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
        -- "expand_more" is a down chevron; rotate 180° so it points UP — this bar
        -- collapses the (expanded) section, so an up arrow reads correctly.
        barIcon:SetTexture(mediaPath .. "expand_more")
        barIcon:SetRotation(math.pi)
        barIcon:SetVertexColor(1, 1, 1, 0.5)

        collapseBar:SetScript("OnEnter", function()
            barBg:SetColorTexture(1, 1, 1, 0.06)
            barIcon:SetVertexColor(1, 1, 1, 0.85)
        end)
        collapseBar:SetScript("OnLeave", function()
            barBg:SetColorTexture(1, 1, 1, 0.03)
            barIcon:SetVertexColor(1, 1, 1, 0.5)
        end)
        collapseBar:SetScript("OnClick", function()
            group.collapsed = true
            local headerText = group.headerWidget and group.headerWidget.text and group.headerWidget.text:GetText()
            local stateKey = group.collapseKey or headerText
            if stateKey then
                local saved = GUI:GetCollapsedGroups()
                saved[stateKey] = true
            end
            if group.collapseArrow then
                group.collapseArrow:SetTexture(mediaPath .. "chevron_right")
            end
            if DF.AuraDesigner_RefreshPage then
                DF:AuraDesigner_RefreshPage()
            end
            local pageChild = group:GetParent()
            if pageChild and pageChild.RefreshStates then pageChild.RefreshStates() end
            if group.onCollapseChanged then group.onCollapseChanged(group) end
        end)

        collapseBar:Hide()
        group.collapseBar = collapseBar
    end

    -- Add a widget to this group
    group.AddWidget = function(self, widget, height)
        widget:SetParent(self)
        -- Record whether the CALL SITE pinned this slot's height. A self-measuring
        -- widget (CreateLabel) may only re-flow the group when it did not — an
        -- explicit number stays authoritative, so no existing layout can shift.
        widget._slotHeightExplicit = (height ~= nil) or nil
        table.insert(self.groupChildren, {
            widget = widget,
            height = ResolveRowHeight(widget, height),
        })
        -- Mark widget as belonging to this group
        widget.settingsGroup = self

        -- If collapsible and this is the first widget (header), set up collapse toggle
        if self.collapsible and #self.groupChildren == 1 and widget.text then
            self.headerWidget = widget

            -- Resolve collapsed state: default to expanded unless saved state says collapsed
            local headerText = widget.text:GetText()
            local stateKey = self.collapseKey or headerText
            local savedStates = GUI:GetCollapsedGroups()
            if stateKey and savedStates[stateKey] then
                self.collapsed = true
            else
                self.collapsed = false
            end

            -- Shift header text right to make room for the arrow icon
            widget.text:ClearAllPoints()
            widget.text:SetPoint("BOTTOMLEFT", widget, "BOTTOMLEFT", 14, 2)

            -- Add toggle arrow icon (texture from Media folder)
            local arrow = widget:CreateTexture(nil, "OVERLAY")
            arrow:SetSize(10, 10)
            arrow:SetPoint("RIGHT", widget.text, "LEFT", -2, 0)
            local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
            arrow:SetTexture(self.collapsed and (mediaPath .. "chevron_right") or (mediaPath .. "expand_more"))
            local c = GetThemeColor()
            arrow:SetVertexColor(c.r, c.g, c.b)
            self.collapseArrow = arrow

            -- Theme listener for arrow color
            arrow.UpdateTheme = function()
                local nc = GetThemeColor()
                arrow:SetVertexColor(nc.r, nc.g, nc.b)
            end
            if not parent.ThemeListeners then parent.ThemeListeners = {} end
            table.insert(parent.ThemeListeners, arrow)

            -- Make the header clickable
            widget:EnableMouse(true)
            widget:SetScript("OnMouseDown", function()
                self.collapsed = not self.collapsed
                -- Persist collapsed state to SavedVariables
                if stateKey then
                    local saved = GUI:GetCollapsedGroups()
                    saved[stateKey] = self.collapsed or nil  -- only store true, remove when expanded
                end
                arrow:SetTexture(self.collapsed and (mediaPath .. "chevron_right") or (mediaPath .. "expand_more"))
                -- Refresh the page to recalculate layout. The Aura Designer page
                -- has its own refresh; BuildPage pages (icons, frame settings…)
                -- expose RefreshStates on the group's parent (self.child).
                if DF.AuraDesigner_RefreshPage then
                    DF:AuraDesigner_RefreshPage()
                end
                local pageChild = self:GetParent()
                if pageChild and pageChild.RefreshStates then pageChild.RefreshStates() end
                if self.onCollapseChanged then self.onCollapseChanged(self) end
            end)

            -- Highlight arrow on hover to indicate clickable
            widget:SetScript("OnEnter", function()
                arrow:SetVertexColor(1, 1, 1)
            end)
            widget:SetScript("OnLeave", function()
                local nc = GetThemeColor()
                arrow:SetVertexColor(nc.r, nc.g, nc.b)
            end)
        end

        return widget
    end

    -- Calculate total height based on visible children and layout them
    group.LayoutChildren = function(self)
        -- Snapped padding: every child's left edge and first row start from it, so
        -- if it is a fractional number of device pixels the whole column inherits
        -- that offset. See SnapLen.
        local padding = SnapLen(self, self.padding)
        local y = -padding  -- Start with top padding
        local visibleCount = 0
        -- Width for child widgets. A group whose width is not resolved yet (created but
        -- not laid out, or anchors cleared) yields a non-positive innerWidth. Do NOT
        -- substitute a guessed width — a group can legitimately be far wider than its
        -- constructed size (RefreshStates stretches layoutCol "both" groups to the full
        -- content width), so guessing squeezes those children and truncates their text.
        -- Skip the sizing instead and let the next pass, with a real width, do it. That
        -- matches the old behaviour, where a negative SetWidth was silently a no-op.
        local innerWidth = SnapLen(self, (self:GetWidth() or 0) - (padding * 2))
        local canSize = innerWidth > 0

        -- Will this entry be laid out on this pass? Factored out of the loop below
        -- so the run look-ahead cannot drift from the loop's own visibility test:
        -- a hidden row must not break a run, or toggling one row's hideOn would
        -- silently change the spacing of the rows around it.
        local layoutDB = DF.db[GUI.SelectedMode]
        local function entryVisible(entry, index)
            if self.collapsed and index > 1 then return false end
            local w = entry and entry.widget
            if not w then return false end
            if w.hideOn and layoutDB and w.hideOn(layoutDB) then return false end
            return true
        end

        for i, entry in ipairs(self.groupChildren) do
            local widget = entry.widget
            local height = entry.height

            -- Close up a RUN of the same compact kind (see GUI.RowGapTight). The
            -- reduction is taken off THIS row's slot, so it only ever affects the
            -- gap to the row below -- and only when that row is the same compact
            -- kind, which is what keeps the boundary between different kinds at
            -- the full RowGap.
            local kind = widget.rowKind
            widget._rowTightened, widget._rowNextKind = false, nil
            if kind and GUI.RowCompact[kind] then
                for j = i + 1, #self.groupChildren do
                    if entryVisible(self.groupChildren[j], j) then
                        -- Recorded even when it does NOT match, so /df debug gapcheck can
                        -- say WHY a run did not close up: a row with no rowKind
                        -- sitting between two checkboxes breaks the run for the
                        -- layout while being invisible to the report (a widget
                        -- that draws nothing is skipped there), which would look
                        -- like the tightening was simply inert.
                        widget._rowNextKind = self.groupChildren[j].widget.rowKind or "<none>"
                        if self.groupChildren[j].widget.rowKind == kind then
                            height = height - (GUI.RowGap - GUI.RowGapTight)
                            widget._rowTightened = true
                        end
                        break   -- only the NEXT visible row decides
                    end
                end
            end

            -- If collapsed, only show the header (first widget)
            if self.collapsed and i > 1 then
                widget:Hide()
            else
                -- Check if widget should be visible
                local shouldShow = true
                if widget.hideOn then
                    local db = DF.db[GUI.SelectedMode]
                    if db and widget.hideOn(db) then
                        shouldShow = false
                    end
                end

                if shouldShow then
                    widget:ClearAllPoints()
                    -- Snap y at USE, not as it accumulates: rounding each row height
                    -- in turn would let the error compound down a long column.
                    widget:SetPoint("TOPLEFT", self, "TOPLEFT", padding, SnapLen(self, y))
                    -- Set width to fit within group padding (only once the group has one)
                    if canSize then widget:SetWidth(innerWidth) end
                    widget:Show()
                    y = y - height
                    visibleCount = visibleCount + 1
                else
                    widget:Hide()
                end
            end
        end

        -- Show/hide collapsed summary and bottom collapse bar
        if self.collapsible then
            if self.collapsed then
                if self.showSummary then
                    -- Build summary fontstring lazily on first use
                    if not self.collapseSummary then
                        self.collapseSummary = self:CreateFontString(nil, "OVERLAY")
                        DF:SafeSetFont(self.collapseSummary, nil, 9, "")
                        self.collapseSummary:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b, 0.5)
                        self.collapseSummary:SetJustifyH("LEFT")
                        self.collapseSummary:SetWordWrap(true)
                    end

                    -- Collect labels from child widgets (skip header at index 1)
                    local labels = {}
                    for i = 2, #self.groupChildren do
                        local w = self.groupChildren[i].widget
                        -- Scan the widget's regions for a FontString with text
                        for _, region in ipairs({w:GetRegions()}) do
                            if region.GetText and region:GetText() and region:GetText() ~= "" then
                                labels[#labels + 1] = region:GetText()
                                break
                            end
                        end
                    end

                    local summaryText = table.concat(labels, "  \194\183  ")  -- separated by  ·
                    self.collapseSummary:SetText(summaryText)
                    self.collapseSummary:ClearAllPoints()
                    self.collapseSummary:SetPoint("TOPLEFT", self, "TOPLEFT", padding, SnapLen(self, y))
                    self.collapseSummary:SetWidth(innerWidth)
                    self.collapseSummary:Show()
                    -- Measure actual wrapped height
                    local summaryHeight = self.collapseSummary:GetStringHeight() or 12
                    y = y - summaryHeight - 2
                else
                    if self.collapseSummary then self.collapseSummary:Hide() end
                end

                if self.collapseBar then self.collapseBar:Hide() end
            else
                if self.collapseSummary then self.collapseSummary:Hide() end
                if self.collapseBar then
                    self.collapseBar:Show()
                    y = y - self.collapseBar:GetHeight()
                end
            end
        end

        -- Update group height (add padding at bottom)
        -- The group's own height, snapped for the same reason its children's
        -- widths are: this is what puts its TOP border on the grid. Since the
        -- runtime geometry correction was removed, this IS the only thing that
        -- does -- there is no after-the-fact pass to fall back on.
        local totalHeight = SnapLen(self, math.abs(y) + padding)
        if totalHeight < 1 then totalHeight = 1 end
        self:SetHeight(totalHeight)
        -- Add margin to calculated height for spacing between groups
        self.calculatedHeight = totalHeight + self.margin

        return self.calculatedHeight
    end

    -- Process disableOn for children
    group.RefreshChildStates = function(self)
        local db = DF.db[GUI.SelectedMode]
        if not db then return end

        -- Group-level grey-out: set self.disableChildrenOn = function(db) ... end to
        -- grey EVERY child when it returns true, EXCEPT the header and any widget
        -- flagged widget.keepEnabled (the feature's own Enable toggle). Saves putting a
        -- disableOn on every control; composes with per-widget disableOn (a child is
        -- disabled if either says so). CreateCheckbox auto-calls RefreshStates on
        -- toggle, so the grey state updates live.
        local hasGroupGate = self.disableChildrenOn ~= nil
        local groupOff = hasGroupGate and self.disableChildrenOn(db) or false

        for i, entry in ipairs(self.groupChildren) do
            local widget = entry.widget
            if widget.SetEnabled and (widget.disableOn or hasGroupGate) then
                local shouldDisable = (widget.disableOn and widget.disableOn(db)) or false
                if groupOff and i > 1 and not widget.keepEnabled then
                    shouldDisable = true
                end
                widget:SetEnabled(not shouldDisable)
            end
            if widget.refreshContent and widget:IsShown() then
                widget:refreshContent(db)
            end
        end
    end

    return group
end

function GUI:CreateLabel(parent, text, width, color)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width or 380, 40)
    
    local lbl = frame:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    -- Anchor both top corners so the wrap width tracks the frame's width. The
    -- layout engine (settings-group LayoutChildren / page column sizing) resizes
    -- the frame to the available width, so the text now uses the full width and
    -- wraps when the window is narrow instead of overflowing/clipping at a fixed
    -- width. Standalone (un-laid-out) labels keep the frame's initial `width`.
    lbl:SetPoint("TOPLEFT", 0, -5)
    lbl:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -5)
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(true)
    lbl:SetText(text)
    
    if color then
        lbl:SetTextColor(color.r, color.g, color.b, color.a or 1)
    else
        lbl:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 1)
    end

    -- MEASURED slot height. A label is a variable-height widget, so ResolveRowHeight
    -- prefers the call-site number and falls back to preferredHeight — stamping a
    -- measured one here leaves every existing call site byte-identical while letting a
    -- NEW one omit the number entirely and get a slot that fits the text however it
    -- wraps. Hand-guessed numbers are exactly what let a 4-line blurb overlap the
    -- dropdown beneath it (Colours page, Color by Time).
    local function Remeasure()
        local h = lbl:GetStringHeight()
        if not h or h <= 0 then return false end
        local newH = math.ceil(h) + (GUI.RowHeight.labelPad or 10)
        if frame.preferredHeight == newH then return false end
        frame.preferredHeight = newH
        frame:SetHeight(newH)
        return true
    end
    -- Force the FontString to re-flow at its CURRENT width. A dual-anchored string
    -- resolves its wrap lazily, so one that was laid out before its frame reached
    -- final width keeps the old single-line layout and renders ellipsised
    -- ("Customize class colors used throughout DandersFra…") even though the frame
    -- measures a correct 260 — /df debug guiwidth reports zero suspect frames while the
    -- text is visibly truncated. Scrolling the settings window dirties it and the
    -- text snaps back, which is the tell that it is a stale layout, not a bad size.
    -- Clearing the text first matters: SetText with an unchanged string can early-out
    -- without marking the string dirty.
    local function Reflow()
        local t = lbl:GetText()
        if t and t ~= "" then
            lbl:SetText("")
            lbl:SetText(t)
        end
    end
    -- The layout engine resizes this frame to the column's available width (see the
    -- anchor note above), and GetStringHeight can return a stale single-line value until
    -- the FontString has rendered at that final width — so converge ONCE on the next
    -- frame, after LayoutChildren has run. Re-flow only when this label OWNS its slot:
    -- inside a SettingsGroup (nothing else tracks a stored height) and with no call-site
    -- number (_slotHeightExplicit, stamped by AddWidget) to override. Deliberately NOT an
    -- OnSizeChanged binding — that cascade is the Aura Designer indicator-card lockup
    -- documented on CreateInfoBanner; the cost is that a label added with no height does
    -- not re-measure if its width changes again later.
    local function Measure()
        Remeasure()
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if not frame:IsShown() then return end
                -- Re-flow FIRST, and for EVERY label — the height converge below is
                -- gated (it only runs for labels that own their slot), but a stale
                -- wrap can strand any label, and the ones with a call-site height are
                -- exactly the ones nothing else ever touches again.
                Reflow()
                if frame.settingsGroup and not frame._slotHeightExplicit and Remeasure() then
                    GUI:RelayoutHost(frame, frame.preferredHeight)
                end
            end)
        end
    end
    Measure()

    -- A rebuilt page hides then re-shows its widgets, and a label re-shown at a width
    -- it was not laid out at comes back with the stale single-line wrap. Re-flow on the
    -- frame AFTER the show settles. Safe against the OnSizeChanged cascade that locked
    -- up the AD indicator cards: Reflow re-applies the same string and never resizes,
    -- so it cannot feed itself.
    frame:SetScript("OnShow", function()
        if C_Timer and C_Timer.After then C_Timer.After(0, Reflow) end
    end)

    frame.SetText = function(self, newText) lbl:SetText(newText); Measure() end
    return frame
end

-- CreateNote: a lightweight LEVELLED note (NO box — that is CreateInfoBanner's
-- job) for an inline caveat/tip attached to a field or section. It is the middle
-- tier between a plain CreateLabel and a full banner.
--   opts.tone    info | caution | danger | success — tints the note from the
--                SAME palette as the banners (via ToneHex), so notes and banners
--                speak one colour language. Omit for a neutral dim note.
--   opts.prefix  optional lead word ("Note", "Warning", "Recommendation") shown
--                in the tone colour, followed by ": " and the body in dim text.
--   opts.width   wrap width.
-- Returns a CreateLabel frame, so it is a drop-in anywhere a label goes.
function GUI:CreateNote(parent, text, opts)
    opts = opts or {}
    local str
    if opts.tone and opts.prefix then
        -- Route the prefix through L so "Note"/"Tip"/etc. are localizable (the
        -- locale metatable returns the key unchanged when a locale lacks it).
        local prefix = (L and L[opts.prefix]) or opts.prefix
        str = "|c" .. self:ToneHex(opts.tone) .. prefix .. ":|r " .. text
    elseif opts.tone then
        str = "|c" .. self:ToneHex(opts.tone) .. text .. "|r"
    else
        str = text
    end
    return self:CreateLabel(parent, str, opts.width)
end

-- Shared link HOVER colour: the rest colour (the theme accent — blue in party, orange in
-- raid) LIGHTENED toward white. Keeps the hue, so a hovered link brightens instead of going
-- flat white and blending into white body text. One source of truth for every link's hover
-- (SetHTML links, the page/URL link buttons, and hand-rolled note links). `c` = the link's
-- rest colour (defaults to the live theme colour); returns {r,g,b}.
function GUI:LinkHoverColor(c)
    c = c or (GUI.GetThemeColor and GUI.GetThemeColor()) or { r = 1, g = 1, b = 1 }
    local t = 0.45   -- lift toward white; tune here to re-key every link at once
    return { r = c.r + (1 - c.r) * t, g = c.g + (1 - c.g) * t, b = c.b + (1 - c.b) * t }
end


-- Hex accent ("ffRRGGBB", for inline |c...|r escapes) matching a banner tone, so
-- inline caveat text (e.g. a warning word in a subtitle) reads as the SAME
-- info/caution/danger/success language as the banners instead of an ad-hoc colour.
-- Uses the tone's dedicated inline `accent` (NOT the banner iconColor, which is
-- tuned to sit on the banner's own bg and would make danger paler than caution).
-- The {r, g, b} behind a tone name, for callers that set a colour directly
-- rather than embedding inline markup. Same resolution order as ToneHex, so a
-- toned title and toned inline text always match.
function GUI:GetToneColor(toneName)
    local t = INFO_BANNER_TONES[toneName] or INFO_BANNER_TONES.caution
    return t.accent or t.iconColor or t.textColor or {1, 1, 1}
end

function GUI:ToneHex(toneName)
    local t = INFO_BANNER_TONES[toneName] or INFO_BANNER_TONES.caution
    local c = t.accent or t.iconColor or t.textColor or {1, 1, 1}
    return string.format("ff%02x%02x%02x",
        math.floor((c[1] or 1) * 255 + 0.5),
        math.floor((c[2] or 1) * 255 + 0.5),
        math.floor((c[3] or 1) * 255 + 0.5))
end

local INFO_BANNER_ICON_PATH = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"

-- Shared inline-markup parser: split "…|cCOLOR|HlinkData|hText|h|r…" (WoW hyperlink markup
-- plus \n line breaks) into a flat token list of { type = "word"/"link"/"newline", text, data,
-- color }. Used by the InfoBanner's SetHTML flow AND GUI:CreateLink, so both read links the
-- same way — one parser, no fork.
local function ParseHTMLSegments(s)
    local segs = {}
    local function addWords(chunk)
        local pos = 1
        while pos <= #chunk do
            local nl = chunk:find("\n", pos, true)
            local line = nl and chunk:sub(pos, nl - 1) or chunk:sub(pos)
            for _, w in ipairs({ strsplit(" ", line) }) do
                if #w > 0 then segs[#segs + 1] = { type = "word", text = w } end
            end
            if nl then
                segs[#segs + 1] = { type = "newline" }
                pos = nl + 1
            else
                break
            end
        end
    end
    local rem = s
    while #rem > 0 do
        local pre, color, data, lt, rest =
            rem:match("^(.-)|c(%x%x%x%x%x%x%x%x)|H([^|]*)|h([^|]*)|h|r(.*)")
        if pre ~= nil then
            addWords(pre)
            segs[#segs + 1] = { type = "link", text = lt, data = data, color = color }
            rem = rest or ""
        else
            addWords(rem)
            break
        end
    end
    return segs
end

-- FlowSpaceWidth — the font's OWN space advance, so a word-per-FontString flow
-- (CreateLink / InfoBanner) spaces exactly like a single wrapped FontString. A
-- fixed pixel gap reads too loose at small sizes; measuring "m m" minus "mm"
-- isolates one space advance. `sizePx` set → measure the user's settings font at
-- that px (matches a banner word, which is SetSettingsFont'd); nil → measure the
-- template's own font object (a CreateLink / template-fonted word). One reused
-- probe (no per-call FontString churn); measured fresh so a font-family change is
-- always reflected. Returns the EXACT fractional advance (no pixel rounding) so the
-- flow spaces identically to native wrapped text — see the return note below.
local function FlowSpaceWidth(tmpl, sizePx)
    tmpl = tmpl or "DFFontHighlightSmall"
    if not S._flowProbe then
        S._flowProbe = UIParent:CreateFontString(nil, "OVERLAY")
    end
    if sizePx and DF.SafeSetFont then
        local fontName = (DF.db and DF.db.settingsFont) or "DF Roboto SemiBold"
        DF:SafeSetFont(S._flowProbe, fontName, sizePx, "")
    else
        S._flowProbe:SetFontObject(_G[tmpl] or _G.GameFontHighlight)
    end
    -- Average over N spaces: each GetStringWidth is pixel-rounded, so a single-space
    -- "m m" - "mm" diff can inflate the space advance by ~1px (which read as too-loose
    -- word gaps next to the native-wrapped notes). Isolating N spaces and dividing
    -- shrinks that rounding error to ~1/N of a pixel, so the flow spaces like real text.
    local N = 12
    S._flowProbe:SetText("m" .. string.rep(" m", N)); local wA = S._flowProbe:GetStringWidth()
    S._flowProbe:SetText("m" .. string.rep("m", N));  local wB = S._flowProbe:GetStringWidth()
    S._flowProbe:SetText("")
    local sp = (wA - wB) / N
    if not sp or sp <= 0 then sp = 3 end
    -- Return the EXACT fractional advance, NOT math.floor(sp+0.5). Rounding a small
    -- space (Roboto ~2.7px at 11px) UP to a whole pixel added a fixed sliver to every
    -- word gap, so the flow read looser than a native wrapped FontString — which
    -- positions its own spaces at sub-pixel offsets. Fractional here = same gap as
    -- native. (Krathe: "look like normal text with links, no extra spacing.")
    return sp
end

-- ============================================================
-- DISABLED OVERLAY — the "this feature is switched off" scrim.
--
-- A dimming plate over the part of a page you cannot act on yet, carrying the
-- feature's name and a pointer at the toggle that turns it on. EnableMouse is
-- the working half: greying a control says "not now", but a page of buttons
-- that still FUNCTION while the feature is off reads as though it were on, and
-- the user builds a thing that silently does nothing.
--
-- The caller anchors it, because the extent is a per-page judgement — cover
-- what can be acted on, not necessarily everything below the toggle. Explaining
-- content (a "how it works" box) is worth leaving readable; a user staring at
-- the scrim is exactly the one who still needs it.
--
--   opts.label     the big line, e.g. L["Aura Designer is disabled"]
--   opts.sublabel  the small line (defaults to the shared "Enable the checkbox
--                  above to use")
--   opts.level     frame-level bump over the parent (default 50)
--
-- Returns the frame; drive it with :SetShown(not enabled) from wherever the
-- flag changes.
-- ============================================================
function GUI:CreateDisabledOverlay(parent, opts)
    opts = opts or {}
    local overlay = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    overlay:SetFrameLevel((parent:GetFrameLevel() or 0) + (opts.level or 50))
    overlay:EnableMouse(true)

    local bg = overlay:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b, 0.85)

    local label = overlay:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    label:SetPoint("CENTER", 0, 10)
    label:SetText(opts.label or "")
    label:SetTextColor(0.6, 0.6, 0.6, 1)
    overlay.Label = label

    local sub = overlay:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    sub:SetPoint("TOP", label, "BOTTOM", 0, -4)
    sub:SetText(opts.sublabel or L["Enable the checkbox above to use"])
    sub:SetTextColor(0.45, 0.45, 0.45, 1)
    overlay.SubLabel = sub

    return overlay
end

function GUI:CreateInfoBanner(parent, opts)
    opts = opts or {}

    local banner = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    -- SetTone overwrites both colours, and opts.tone is applied at the bottom of
    -- this function -- so these defaults only show on a tone-less banner, which
    -- previously drew an untinted (white) box because nothing coloured it.
    CreateElementBackdrop(banner)
    -- Give the banner a defined initial height so child frames have valid positions
    -- from the very first frame (before DoRecomputeHeight has run).
    banner:SetHeight(opts.minHeight or 34)

    -- Icon: top-left anchored so it stays put when content wraps to multiple lines.
    local icon = banner:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("TOPLEFT", 12, -10)
    icon:SetSize(22, 22)
    banner.icon = icon

    -- Plain-text body. Anchored top + right (no bottom) so the FontString
    -- auto-grows to its natural wrapped height; the banner then resizes
    -- to fit it via RecomputeHeight. SetWordWrap is on so long text wraps
    -- at the width defined by the LEFT/RIGHT anchors.
    local fontTemplate = opts.fontTemplate or "DFFontHighlight"
    local body = banner:CreateFontString(nil, "OVERLAY", fontTemplate)
    if not opts.fontTemplate then
        -- Default body a touch below DFFontHighlight (12px) — 11px reads cleaner
        -- in the banner while staying bigger than the old Small (10px). Icon stays 22.
        GUI:SetSettingsFont(body, 11, "")
    end
    -- Y offset centres the first line on the icon (body 11px, icon 22px). The
    -- text sits a few px below the icon's top so its centre lines up with the
    -- icon's centre.
    body:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -5)
    body:SetPoint("RIGHT", banner, "RIGHT", -12, 0)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetWordWrap(true)
    body:SetNonSpaceWrap(true)
    if body.SetMaxLines then body:SetMaxLines(0) end
    banner.body = body

    banner.layoutHeight = (opts.minHeight or 28) + 6

    local cachedH, recomputing = nil, false

    -- Sync the banner's measured slot height into its host group and re-flow (bubbling
    -- to the page so sibling groups re-anchor). Shared with the measured label — see
    -- GUI:RelayoutHost, which is this logic verbatim; the page bubble is what stops a
    -- grown group's backdrop overshooting the next group's anchor when an animation
    -- type is first selected in a border panel.
    local function TriggerHostRelayout()
        GUI:RelayoutHost(banner, banner.layoutHeight)
    end

    local function MeasureContent()
        if banner._isHTML then
            -- For HTML mode the flow layout positions all widgets and returns
            -- the total pixel height of all lines. Re-running it here keeps
            -- positions fresh and gives us an accurate height in one step.
            return math.max(18, banner._DoFlowLayout and banner._DoFlowLayout() or 18)
        end
        return math.max(18, body:GetStringHeight())
    end

    local pending = false
    -- Set whenever a RecomputeHeight() request was deferred because the
    -- banner was invisible.  Cleared once a real recompute runs after the
    -- banner becomes visible.  OnShow checks this flag to decide whether to
    -- trigger a fresh recompute when the widget surfaces.
    local deferredWhileHidden = false
    local function DoRecomputeHeight()
        pending = false
        if recomputing then return end
        -- Skip when the banner is hidden — GetStringHeight on a hidden
        -- FontString returns an unreliable value (width depends on the
        -- parent's layout having run, and LayoutChildren doesn't SetWidth
        -- on hidden widgets), and the resulting SetHeight + Trigger­Host­
        -- Relayout cascade costs real work proportional to the host
        -- SettingsGroup's widget count.  For consumers that mount banners
        -- behind hideOn predicates that default to true (animation perf
        -- warning at type=NONE) this used to fire one cascade per banner
        -- at every GUI open — N indicator cards × ~25-widget group ×
        -- proxy-backed dbTable in Aura Designer = sustained lockup.
        if not banner:IsVisible() then
            deferredWhileHidden = true
            return
        end
        local h = math.ceil(MeasureContent())
        -- Chrome: 13 px top (icon at -10, text nudged -3) + 9 px bottom = 22 px.
        -- Snapped to whole device pixels so the banner's TOP border lands on the
        -- grid. Done HERE rather than by opting into the generic size snapper,
        -- because this function owns the height and is the thing the cascade
        -- documented above runs through -- snapping the number before cachedH
        -- sees it keeps the existing "did it actually change?" guard authoritative
        -- instead of adding a second writer behind its back.
        local newH = SnapLen(banner, math.max(opts.minHeight or 28, h + 22))
        if cachedH ~= newH then
            cachedH = newH
            recomputing = true
            banner:SetHeight(newH)
            banner.layoutHeight = newH + 6
            TriggerHostRelayout()
            recomputing = false
        end
        -- Schedule one more measurement next frame: GetStringHeight can
        -- return a stale single-line value the first time it's read after
        -- a width change, before the FontString has finished re-rendering.
        -- A second pass converges to the true wrapped height.
        if not banner._secondPassDone then
            banner._secondPassDone = true
            if C_Timer and C_Timer.After then
                C_Timer.After(0, DoRecomputeHeight)
            end
        end
    end

    -- Defer measurement to next frame so FontString has rendered with its
    -- current width — GetStringHeight can return a stale single-line value
    -- if called immediately after a width change. Coalesce multiple calls
    -- per frame via the `pending` flag.
    local function RecomputeHeight()
        banner._secondPassDone = false  -- allow follow-up pass on every fresh trigger
        if pending then return end
        pending = true
        if C_Timer and C_Timer.After then
            C_Timer.After(0, DoRecomputeHeight)
        else
            DoRecomputeHeight()
        end
    end

    -- opts.staticHeight: skip ALL recompute machinery (no OnSizeChanged
    -- binding, no OnShow re-measure, no DoRecomputeHeight cascade).
    -- For consumers whose text never changes after construction AND who
    -- can predict a sensible fixed height up front (e.g. animation perf
    -- warning).  Avoids the SetHeight → OnSizeChanged → TriggerHostRelayout
    -- → g:LayoutChildren feedback loop that, in container layouts where
    -- LayoutChildren re-fires SetWidth on every pass (Aura Designer's
    -- indicator card body), drops FPS the moment the banner surfaces.
    if not opts.staticHeight then
        -- Only width changes affect the wrapped string height — height
        -- changes (which our own SetHeight inside DoRecomputeHeight triggers)
        -- don't.  Filtering on width breaks part of the feedback loop, but
        -- doesn't help when the host layout fires OnSizeChanged per frame
        -- with same-or-different widths (some scroll-frame containers do).
        local lastMeasuredWidth
        banner:SetScript("OnSizeChanged", function(self, w, _)
            if w == lastMeasuredWidth then return end
            lastMeasuredWidth = w
            RecomputeHeight()
        end)
        -- HookScript, not SetScript: CreateElementBackdrop already hooked OnShow,
        -- to re-derive this frame's border thickness if the UI scale changed
        -- while it was hidden, and a SetScript here would throw that hook away.
        -- Nothing else would re-derive it -- a banner that appears late is
        -- exactly the case that hook exists for.
        banner:HookScript("OnShow", function()
            if deferredWhileHidden then
                deferredWhileHidden = false
                cachedH = nil
                lastMeasuredWidth = nil
                RecomputeHeight()
            end
        end)
    end
    banner._RecomputeHeight = RecomputeHeight

    function banner:SetIconTexture(path)
        self.icon:SetTexture(path)
    end

    function banner:SetIconColor(r, g, b)
        self.icon:SetVertexColor(r or 1, g or 1, b or 1)
    end

    function banner:SetIcon(path, r, g, b)
        self:SetIconTexture(path)
        if r then self:SetIconColor(r, g, b) end
    end

    function banner:SetTone(toneName)
        local tone = INFO_BANNER_TONES[toneName]
        if not tone then return end
        self._tone = toneName
        if tone.bg then self:SetBackdropColor(tone.bg[1], tone.bg[2], tone.bg[3], tone.bg[4] or 1) end
        if tone.useThemeBorder then
            local tc = (GUI.GetThemeColor and GUI.GetThemeColor()) or {r = 1, g = 1, b = 1}
            self:SetBackdropBorderColor(tc.r, tc.g, tc.b, tone.borderAlpha or 1)
        elseif tone.border then
            self:SetBackdropBorderColor(tone.border[1], tone.border[2], tone.border[3], tone.border[4] or 1)
        end
        if tone.icon then
            self:SetIconTexture(INFO_BANNER_ICON_PATH .. tone.icon)
        end
        if tone.iconColor then
            self:SetIconColor(tone.iconColor[1], tone.iconColor[2], tone.iconColor[3])
        else
            self:SetIconColor(1, 1, 1)
        end
        if tone.textColor then
            self.body:SetTextColor(tone.textColor[1], tone.textColor[2], tone.textColor[3])
        end
    end

    function banner:SetText(text, color)
        text = text or ""
        -- Idempotent guard (same freeze class as SetHTML): when already showing this
        -- exact plain text, skip the cachedH reset + RecomputeHeight + host relayout
        -- so a refreshContent-driven SetText can't loop. Colour is cheap to re-apply
        -- without a recompute. (SetContent bakes its themed title into `text`, so a
        -- mode switch changes the string and correctly re-renders.)
        if not self._isHTML and self._plainText == text then
            if color then
                local r = color[1] or color.r
                local g = color[2] or color.g
                local b = color[3] or color.b
                if r then self.body:SetTextColor(r, g, b) end
            end
            return
        end
        self._plainText = text
        -- Hide any flow widgets from a previous SetHTML call.
        if self._flowWidgets then
            for _, w in ipairs(self._flowWidgets) do w:Hide() end
        end
        self._isHTML = false
        self.body:Show()
        self.body:SetText(text)
        if color then
            local r = color[1] or color.r
            local g = color[2] or color.g
            local b = color[3] or color.b
            if r then self.body:SetTextColor(r, g, b) end
        end
        cachedH = nil
        banner._secondPassDone = false
        RecomputeHeight()
    end

    -- Theme-coloured "Title: body" content with a live-updating title colour +
    -- theme border (folds in the old CreateInfoCallout). Registers the banner as
    -- a ThemeListener so the title/border re-colour on party/raid mode switch.
    function banner:SetContent(title, body)
        self._contentTitle, self._contentBody = title, body
        if title and title ~= "" then
            local tc = (GUI.GetThemeColor and GUI.GetThemeColor()) or { r = 1, g = 1, b = 1 }
            local hex = string.format("ff%02x%02x%02x",
                math.floor(tc.r * 255), math.floor(tc.g * 255), math.floor(tc.b * 255))
            self:SetText("|c" .. hex .. title .. ":|r " .. (body or ""))
        else
            self:SetText(body or "")
        end
        if not self._themeRegistered then
            self._themeRegistered = true
            local p = self:GetParent()
            if p then
                p.ThemeListeners = p.ThemeListeners or {}
                table.insert(p.ThemeListeners, self)
            end
        end
    end

    function banner:UpdateTheme()
        if self._tone then self:SetTone(self._tone) end
        if self._contentTitle ~= nil or self._contentBody ~= nil then
            self:SetContent(self._contentTitle, self._contentBody)
        end
    end

    -- SetHTML renders text + clickable links using real Button widgets in a
    -- flow layout. This mirrors the original per-link-button approach that
    -- reliably dispatches OnClick in WoW, unlike SimpleHTML whose
    -- OnHyperlinkClick failed to fire consistently.
    --
    -- Input text uses WoW hyperlink markup: |cCOLOR|HlinkData|hText|h|r
    -- and \n for explicit line breaks. Plain text is word-split so wrapping
    -- occurs at word boundaries when the banner is narrow.

    -- (Markup parsing is the file-level ParseHTMLSegments, shared with GUI:CreateLink.)

    -- Position all flow widgets left-to-right with wrapping; returns total
    -- content height. Punctuation tokens attach to the preceding element
    -- with no leading gap so "Foo," renders without extra space before the comma.
    local FLOW_LINE_H = 14
    -- Banner words are SetSettingsFont'd to 11px unless a custom template is given; measure the
    -- space advance at that same font so the flow spaces like native text (see FlowSpaceWidth).
    local flowSpaceW = FlowSpaceWidth(fontTemplate, (not opts.fontTemplate) and 11 or nil)
    local function DoFlowLayout()
        if not banner._flowSegs then return 0 end
        local availW = banner:GetWidth() - (12 + 18 + 8) - 12
        if availW < 20 then return FLOW_LINE_H end
        local x, lineY = 0, -3
        for _, seg in ipairs(banner._flowSegs) do
            if seg.type == "newline" then
                x = 0; lineY = lineY - FLOW_LINE_H - 2
            elseif seg._widget then
                local w = seg._w
                -- Only a token that is ENTIRELY trailing punctuation (a lone "." or "," after a
                -- link) hugs the preceding word. Connectors like & / - are whole words and keep
                -- normal spacing on both sides — else "Texture & Colors" renders as "Texture& …".
                local isPunct = seg.type == "word" and seg.text:match("^[%.%,%;%:%!%?%)%]%}]+$") and true or false
                local gap = (x > 0 and not isPunct) and flowSpaceW or 0
                if x > 0 and (x + gap + w) > availW then
                    x = 0; lineY = lineY - FLOW_LINE_H - 2; gap = 0
                end
                seg._widget:ClearAllPoints()
                seg._widget:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8 + x + gap, lineY)
                x = x + gap + w
            end
        end
        return math.abs(lineY - (-3)) + FLOW_LINE_H
    end
    banner._DoFlowLayout = DoFlowLayout

    function banner:SetHTML(text, onLinkClick)
        text = text or ""
        -- The link words are tinted with the theme colour at render time (below),
        -- NOT baked into `text`, so a party/raid mode switch must re-render even
        -- when the text is identical — fold the theme into the dedupe key.
        local _tc = GUI.GetThemeColor and GUI.GetThemeColor() or {r = 1, g = 0.82, b = 0}
        local themeKey = string.format("%.3f,%.3f,%.3f", _tc.r or 1, _tc.g or 1, _tc.b or 1)
        -- Idempotent guard (FREEZE FIX): tearing down + rebuilding the flow widgets
        -- resets cachedH and re-fires RecomputeHeight -> TriggerHostRelayout ->
        -- host:RefreshStates. This banner's SetHTML is driven from a refreshContent
        -- hook that RefreshStates calls on EVERY pass, so an unguarded rebuild loops
        -- forever (game freeze — seen on the Buffs page when the Aura Designer banner
        -- is shown). Skip the rebuild when neither the text nor the link-tint theme
        -- changed; just keep the click handler current.
        if self._isHTML and self._htmlText == text and self._htmlThemeKey == themeKey then
            self._onLinkClick = onLinkClick
            return
        end
        self._htmlThemeKey = themeKey
        self._htmlText = text
        self._onLinkClick = onLinkClick
        self._isHTML = true
        self.body:Hide()

        -- Tear down widgets from any previous call.
        if self._flowWidgets then
            for _, w in ipairs(self._flowWidgets) do w:Hide() end
        end
        self._flowWidgets = {}

        local tc = GUI.GetThemeColor and GUI.GetThemeColor() or {r = 1, g = 0.82, b = 0}
        local segs = ParseHTMLSegments(self._htmlText)
        self._flowSegs = segs

        for _, seg in ipairs(segs) do
            if seg.type == "word" then
                local fs = self:CreateFontString(nil, "OVERLAY", fontTemplate)
                if not opts.fontTemplate then GUI:SetSettingsFont(fs, 11, "") end  -- match the 11px plain body
                fs:SetText(seg.text)
                fs:SetTextColor(0.85, 0.85, 0.85)
                seg._w = fs:GetStringWidth()
                -- Give an explicit size matching the button height so TOPLEFT
                -- anchors place both text words and link buttons on the same baseline.
                fs:SetSize(seg._w, FLOW_LINE_H)
                seg._widget = fs
                self._flowWidgets[#self._flowWidgets + 1] = fs
            elseif seg.type == "link" then
                local btn = CreateFrame("Button", nil, self)
                local fs = btn:CreateFontString(nil, "OVERLAY", fontTemplate)
                if not opts.fontTemplate then GUI:SetSettingsFont(fs, 11, "") end  -- match the 11px plain body
                fs:SetAllPoints()
                fs:SetJustifyH("LEFT")   -- ink flush-left so the link spaces like a plain word
                fs:SetText(seg.text)
                fs:SetTextColor(tc.r, tc.g, tc.b)
                -- Box width ceil'd (anti last-glyph clip), but the flow ADVANCE uses the
                -- RAW width — else the ≤1px of empty box after every link became extra
                -- gap before the next word (looser than native). seg._w drives the gap.
                local rawW = fs:GetStringWidth()
                btn:SetSize(math.ceil(rawW), FLOW_LINE_H)
                btn:SetScript("OnEnter", function()
                    local h = GUI:LinkHoverColor((GUI.GetThemeColor and GUI.GetThemeColor()) or tc)
                    fs:SetTextColor(h.r, h.g, h.b)
                end)
                btn:SetScript("OnLeave", function()
                    local c = GUI.GetThemeColor and GUI.GetThemeColor() or tc
                    fs:SetTextColor(c.r, c.g, c.b)
                end)
                local segData = seg.data
                btn:SetScript("OnClick", function()
                    if self._onLinkClick then
                        local _, pageId = strsplit(":", segData)
                        self._onLinkClick(pageId or segData)
                    end
                end)
                seg._widget = btn
                seg._w = rawW
                self._flowWidgets[#self._flowWidgets + 1] = btn
            end
        end

        DoFlowLayout()
        cachedH = nil
        banner._secondPassDone = false
        RecomputeHeight()
    end

    -- Apply opts at creation
    if opts.tone then banner:SetTone(opts.tone) end
    if opts.iconTexture then banner:SetIconTexture(opts.iconTexture) end
    if opts.iconColor then banner:SetIconColor(opts.iconColor[1], opts.iconColor[2], opts.iconColor[3]) end
    if opts.html then
        banner:SetHTML(opts.text, opts.onLinkClick)
    elseif opts.text then
        banner:SetText(opts.text, opts.textColor)
    end

    return banner
end

-- ============================================================
-- GUI:CreateLink — lean inline text + clickable links in a NOTE style (no box), FIXED layout.
-- The link-capable counterpart to CreateNote: same |cCOLOR|Hdata|hText|h|r markup as the
-- InfoBanner (shared ParseHTMLSegments), rendered as flowing dim body text with a themed,
-- hover-lightening Button per link — but WITHOUT the banner's self-resize machinery, so it is
-- safe inside the Aura Designer's reflowing indicator cards (no OnSizeChanged -> relayout loop
-- that drops FPS there). Only the link words are clickable/hovered (fixes the old note's
-- whole-frame click). Named CreateLink (not CreateLinkText) so we can grow other link forms.
--
-- opts:
--   onLinkClick(data)  called with the link's raw data string on click.
--   width              wrap width; if given, flows immediately. Omit to flow once when the host
--                      first sizes the frame (then it stops — no re-flow loop).
--   fontTemplate       body font (default DFFontHighlightSmall — the note look).
--   lineHeight         per-line height (default 14).
--   padTop/padBottom   vertical breathing room baked into layoutHeight (default 2 / 8) so a note
--                      isn't glued to the controls above/below it — the measured height (and thus
--                      the slot a caller gives it) already includes it. More below than above so
--                      the note reads as annotating the control above while clearing the next one.
-- Returns the frame; frame.layoutHeight is the measured height after flow; frame:Reflow(w)
-- re-flows at a new width if a caller ever needs it.
-- ============================================================
function GUI:CreateLink(parent, text, opts)
    opts = opts or {}
    local onLinkClick = opts.onLinkClick
    local fontTemplate = opts.fontTemplate or "DFFontHighlightSmall"
    local LINE_H = opts.lineHeight or 14
    local PAD_TOP = opts.padTop or 2
    local PAD_BOTTOM = opts.padBottom or 8
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(LINE_H)

    local segs = ParseHTMLSegments(text or "")
    local tc = (GUI.GetThemeColor and GUI.GetThemeColor()) or { r = 1, g = 0.82, b = 0 }

    for _, seg in ipairs(segs) do
        if seg.type == "word" then
            local fs = frame:CreateFontString(nil, "OVERLAY", fontTemplate)
            fs:SetText(seg.text)
            fs:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)   -- dim body, like a note
            seg._w = fs:GetStringWidth()
            fs:SetSize(seg._w, LINE_H)
            seg._widget = fs
        elseif seg.type == "link" then
            local btn = CreateFrame("Button", nil, frame)
            local fs = btn:CreateFontString(nil, "OVERLAY", fontTemplate)
            fs:SetAllPoints()
            fs:SetJustifyH("LEFT")   -- ink flush-left so the link spaces like a plain word
            fs:SetText(seg.text)
            fs:SetTextColor(tc.r, tc.g, tc.b)
            -- Box ceil'd (anti last-glyph clip); flow ADVANCE uses the RAW width so the
            -- ≤1px of empty box after a link doesn't become extra word gap (see SetHTML).
            local rawW = fs:GetStringWidth()
            btn:SetSize(math.ceil(rawW), LINE_H)
            btn:SetScript("OnEnter", function()
                local h = GUI:LinkHoverColor((GUI.GetThemeColor and GUI.GetThemeColor()) or tc)
                fs:SetTextColor(h.r, h.g, h.b)
            end)
            btn:SetScript("OnLeave", function()
                local c = (GUI.GetThemeColor and GUI.GetThemeColor()) or tc
                fs:SetTextColor(c.r, c.g, c.b)
            end)
            local segData = seg.data
            btn:SetScript("OnClick", function() if onLinkClick then onLinkClick(segData) end end)
            seg._w = rawW
            seg._widget = btn
        end
    end

    -- Match native inter-word spacing: the flow gap is the font's own space advance, so a
    -- word-per-FontString line reads exactly like a single wrapped FontString (a fixed pixel
    -- gap looks too loose at small sizes). Words here use the raw template font (no
    -- SetSettingsFont resize), so measure the template object directly.
    local SPACE_W = FlowSpaceWidth(fontTemplate)

    -- Wrap the tokens left-to-right at `w`; punctuation hugs the preceding token. Sets the
    -- frame height to fit. Fixed layout — never re-flows on its own, so no host feedback loop.
    local function doFlow(w)
        w = w or frame:GetWidth() or 0
        if w < 20 then return LINE_H end
        local x, lineY = 0, -PAD_TOP   -- start below the top so the first line isn't glued up
        for _, seg in ipairs(segs) do
            if seg.type == "newline" then
                x = 0; lineY = lineY - LINE_H - 2
            elseif seg._widget then
                -- Only a token that is ENTIRELY trailing punctuation (a lone "." or "," after a
                -- link) hugs the preceding word. Connectors like & / - are whole words and keep
                -- normal spacing on both sides — else "Texture & Colors" renders as "Texture& …".
                local isPunct = seg.type == "word" and seg.text:match("^[%.%,%;%:%!%?%)%]%}]+$") and true or false
                local gap = (x > 0 and not isPunct) and SPACE_W or 0
                if x > 0 and (x + gap + seg._w) > w then
                    x = 0; lineY = lineY - LINE_H - 2; gap = 0
                end
                seg._widget:ClearAllPoints()
                seg._widget:SetPoint("TOPLEFT", frame, "TOPLEFT", x + gap, lineY)
                x = x + gap + seg._w
            end
        end
        local h = math.abs(lineY) + LINE_H + PAD_BOTTOM
        frame:SetHeight(h); frame.layoutHeight = h
        return h
    end
    frame.Reflow = function(_, w) return doFlow(w) end

    if opts.width then
        frame:SetWidth(opts.width)
        doFlow(opts.width)
    else
        frame:SetScript("OnSizeChanged", function(self, w)
            if w and w > 20 and not self._flowed then
                self._flowed = true
                self:SetScript("OnSizeChanged", nil)   -- flow once; never re-flow (no loop)
                doFlow(w)
            end
        end)
    end
    return frame
end

-- GUI:FlashWidget — the "show me" pulse (revived from the pre-12.1 boss-debuffs jump): briefly
-- highlight a widget/section in the theme colour so the eye lands on it after a jump. One reused
-- overlay per target; the colour refreshes each call (party blue / raid orange).
-- opts (all opt-in / out):
--   fill    (default true)  — a soft theme-coloured WASH (peaks ~35% alpha, control stays legible).
--   border  (default false) — a theme-coloured OUTLINE. Mix per call: a whole section reads well
--                             as border-only; a single control as fill + border.
--   alpha       fill peak alpha (default 0.35).   borderSize  outline thickness px (default 2).
-- The overlay is a backdrop frame parented to the target's parent + anchored to the target, so
-- it works whether the target is a Frame or a raw FontString (section headers).
function GUI:FlashWidget(widget, opts)
    if not widget or not widget.GetParent then return end
    opts = opts or {}
    local doFill   = opts.fill ~= false
    local doBorder = opts.border and true or false
    if not doFill and not doBorder then doFill = true end   -- something has to show
    local hl = widget._dfFlashHL
    if not hl then
        local host = widget:GetParent() or widget
        hl = CreateFrame("Frame", nil, host, "BackdropTemplate")
        hl:SetPoint("TOPLEFT", widget, "TOPLEFT", -3, 3)
        hl:SetPoint("BOTTOMRIGHT", widget, "BOTTOMRIGHT", 3, -3)
        local wl = (widget.GetFrameLevel and widget:GetFrameLevel())
            or (host.GetFrameLevel and host:GetFrameLevel()) or 1
        hl:SetFrameLevel(wl + 4)   -- draw over the target
        widget._dfFlashHL = hl
    end
    local c = (GUI.GetThemeColor and GUI.GetThemeColor()) or { r = 1, g = 0.82, b = 0 }
    -- Re-issued per call so the pulse picks up the current theme colour.
    CreateElementBackdrop(hl, {
        fill        = doFill,
        outline     = doBorder,
        edgeSize    = opts.borderSize or 2,
        bgColor     = { c.r, c.g, c.b, opts.alpha or 0.35 },
        borderColor = { c.r, c.g, c.b, 1 },
    })

    -- Gentle alpha pulse (mirrors the live "show me" highlight): a few soft
    -- fade in/out cycles then a slow fade to nothing — a calm breathe rather
    -- than a hard flash. The group drives hl's frame alpha; the backdrop keeps
    -- its own tint alpha, so the two multiply into a subtle pulse.
    local pulse = hl._dfPulse
    if not pulse then
        pulse = hl:CreateAnimationGroup()
        local PULSES, HALF = 4, 0.4
        for i = 1, PULSES do
            local up = pulse:CreateAnimation("Alpha")
            up:SetFromAlpha(0.3); up:SetToAlpha(1)
            up:SetDuration(HALF); up:SetOrder(i * 2 - 1)
            local down = pulse:CreateAnimation("Alpha")
            down:SetFromAlpha(1); down:SetToAlpha(0.3)
            down:SetDuration(HALF); down:SetOrder(i * 2)
        end
        local out = pulse:CreateAnimation("Alpha")
        out:SetFromAlpha(0.3); out:SetToAlpha(0)
        out:SetDuration(0.6); out:SetOrder(PULSES * 2 + 1)
        pulse:SetScript("OnFinished", function() hl:SetAlpha(0); hl:Hide() end)
        hl._dfPulse = pulse
    end
    pulse:Stop()
    hl:SetAlpha(1)
    hl:Show()
    pulse:Play()
end

-- GUI:LinkToSetting — the click action for a settings-link: jump to a setting and flash it.
-- Unifies same-page and cross-page so every link behaves identically. target:
--   page      tab to switch to first (nil = stay on the current page).
--   section   section header text — scrolls to it (Search:ScrollToSection) and flashes it.
--   widget    explicit widget to flash (overrides the section-header lookup).
--   scrollTo  optional function() that scrolls a CUSTOM container (e.g. an Aura Designer card)
--             to the target — used instead of the page section scroll.
--   flash     false = no pulse; a table = FlashWidget opts (fill / border / …) so a link picks
--             its own highlight style; nil or true = the default flash.
function GUI:LinkToSetting(target)
    if type(target) ~= "table" then return end
    local function go()
        local w = target.widget
        if target.scrollTo then
            target.scrollTo()
        elseif target.page and target.section and DF.Search and DF.Search.ScrollToSection then
            w = DF.Search:ScrollToSection(target.page, target.section) or w
        end
        if w and target.flash ~= false then
            local fopts = type(target.flash) == "table" and target.flash or nil
            C_Timer.After(0.05, function() GUI:FlashWidget(w, fopts) end)   -- after the scroll settles
        end
    end
    if target.page and GUI.SelectTab then
        GUI.SelectTab(target.page)
        C_Timer.After(0.12, go)   -- let the tab build + lay out before scroll/flash
    else
        go()
    end
end

-- GUI:CreateColorsPageLink — the shared "Customize duration colors on the Colors page."
-- note (GUI:CreateLink, note style — not a banner). Its only link jumps to the shared,
-- account-wide Color-by-Time editor on the Colors page and border-flashes that whole
-- section so the eye lands on it. Used by the aura pages (buffs/debuffs/defensives) AND
-- the Aura Designer wherever a "Color by Time Remaining" control (text, or the expiry
-- Border/Tint modes) draws from those breakpoints — one cross-link, defined once.
--   `width`  flows the fixed-layout note up front (see GUI:CreateLink); the caller then
--            AddWidget's it at note.layoutHeight. The |cffffffff is a parser placeholder —
--            CreateLink re-tints the link itself.
function GUI:CreateColorsPageLink(parent, width)
    local link = string.format("|cffffffff|HdfColors|h%s|h|r", L["Colors page"])
    local text = string.format(L["Customize duration colors on the %s."], link)
    return GUI:CreateLink(parent, text, {
        width = width,
        onLinkClick = function()
            GUI:LinkToSetting({
                page    = "display_classcolors",
                section = L["Color by Time"],
                flash   = { border = true, fill = false },   -- whole section → outline only
            })
        end,
    })
end

-- Sibling of CreateColorsPageLink for the shared per-dispel-type palette: jumps to
-- the Colors page and flashes its "Dispel Type Colors" section. Used by the debuff
-- Border page and the Dispel Overlay page — both of which draw their dispel colours
-- from that one account-wide set.
function GUI:CreateDispelColorsPageLink(parent, width)
    local link = string.format("|cffffffff|HdfColors|h%s|h|r", L["Colors page"])
    local text = string.format(L["Set the per-dispel-type colours on the %s."], link)
    return GUI:CreateLink(parent, text, {
        width = width,
        onLinkClick = function()
            GUI:LinkToSetting({
                page    = "display_classcolors",
                section = L["Dispel Type Colors"],
                flash   = { border = true, fill = false },
            })
        end,
    })
end

-- Apply the standard button look to an existing Button frame — the single
-- source of truth for button styling, shared by GUI:CreateButton AND by
-- hand-rolled buttons that need the same look (the button analogue of
-- GUI:StyleCheckButton). opts:
--   width/height  resize the button
--   text          create/set a centered DFFontHighlightSmall label (btn.Text)
--   accent        {r,g,b} — fixes the accent colour (e.g. ClickCasting green).
--                 Omit to use the mode accent (party purple / raid orange),
--                 tracking the theme.
--   primary       true → a prominent CTA: a persistent accent-tinted fill +
--                 accent border at rest (the hover wash just brightens it). Use
--                 for the main/confirming action; normal buttons are grey at rest.
--   fadeActiveText true → on SetActive(true) dim btn.Text/btn.Icon to ~0.7 alpha
--                 (back to full when inactive). For an "almost always on" status
--                 toggle like Sync, where the active (synced) state is the resting
--                 norm so the label can recede. Leave OFF for momentary toggles
--                 (Test/Unlock) and selection toggles (chips/segmented), whose
--                 active text should stay bright/white.
-- Hover respects the isTab/isActive convention used by the tab bar. Hover uses
-- SetScript (matching the original CreateButton); buttons that also need a
-- tooltip should HookScript their OnEnter so it composes with the hover.
-- ============================================================
-- GUI TOOLTIP  (settings-UI tooltips only — NOT unit-frame/aura tooltips)
-- Single source for our own widget tooltips. Call from OnEnter — use HookScript
-- on StyleButton'd widgets so it composes with the hover wash; SetScript on
-- plain frames. Pair with OnLeave -> GUI:HideTooltip().
--   opts.title  (string)   white by default, or tone-coloured
--   opts.tone   nil | "warning" (gold) | "danger" (red)
--   opts.anchor  default: at the CURSOR, lifted clear of it (see CURSOR_LIFT).
--               Krathe's call, 2026-07-27: a settings tooltip should appear where
--               you are pointing, not pinned to a widget edge whose size you are
--               not thinking about — but sitting ON the cursor buried the control
--               you were reading about, so it is offset upward.
--               ⚠ Do NOT pass one per call site. The whole point of the default
--               living here is that every tooltip in the settings UI behaves the
--               same; a page that sets its own is the disjointedness we just
--               removed. ANCHOR_TOP in particular clamps over the owner near the
--               top of the frame — it was in use 14 times and is now gone.
--   opts.lines  array; each element is one of:
--       "text"                     -> body grey (0.7), wrapped
--       " "                        -> blank spacer
--       { text = , hint = true }   -> dim grey (0.55) action hint, wrapped
--       { text = , accent = true } -> mode/context accent colour, wrapped
--       { text = , color = {r,g,b} } -> explicit colour, wrapped
-- ============================================================

-- ============================================================
-- GAME-DATA TOOLTIP  (a spell / item / equipped item / aura, plus our own lines)
-- The shape ShowTooltip cannot express: the game writes the header, we append
-- underneath. Six settings-UI surfaces hand-rolled it — the whole binding editor
-- plus the spell picker — and only the picker handled the case that actually
-- bites: GameTooltip:SetSpellByID renders NOTHING when the client has not loaded
-- that spell's data yet, so a bare call leaves an empty tooltip. Everywhere else
-- silently showed nothing on a cold cache.
--
-- opts (pick ONE source):
--   spellID                    a spell — gets the load-on-demand retry below
--   itemID                     an item by id
--   inventorySlot [+ unit]     an equipped item ("player" unless unit is given)
--   unit + auraInstanceID      a live aura
-- plus:
--   fallbackTitle   shown when the game has no data at all, so a hover is never
--                   blank (for a spell, the id is added under it)
--   isCurrent(owner, spellID)  is this owner STILL showing this spell? Guards the
--                   async re-render on pooled / rebindable rows. Omit for a row
--                   that only ever shows one thing.
--   anchor, lines   exactly as ShowTooltip
-- ============================================================

-- Fill from the game. Returns whether it actually produced content.
local function SeedGameTooltip(opts)
    local ok
    if opts.spellID then
        -- pcall: SetSpellByID errors outright on ids the client considers
        -- invalid (possible for stale DB entries) — treat that as "no data".
        ok = pcall(GameTooltip.SetSpellByID, GameTooltip, opts.spellID)
    elseif opts.itemID then
        ok = pcall(GameTooltip.SetItemByID, GameTooltip, opts.itemID)
    elseif opts.inventorySlot then
        ok = pcall(GameTooltip.SetInventoryItem, GameTooltip, opts.unit or "player", opts.inventorySlot)
    elseif opts.unit and opts.auraInstanceID then
        ok = pcall(GameTooltip.SetUnitAura, GameTooltip, opts.unit, opts.auraInstanceID)
    else
        return false
    end
    return ok and GameTooltip:NumLines() > 0
end

function GUI:ShowGameTooltip(owner, opts)
    if not owner or not opts then return end

    -- Render the whole thing: game data (or the fallback), then our lines. Used
    -- for the first paint AND the re-paint after a late spell load, so the
    -- appended lines survive the reload instead of vanishing with it.
    local function Fill()
        local seeded = SeedGameTooltip(opts)
        if not seeded then
            if opts.fallbackTitle and opts.fallbackTitle ~= "" then
                GameTooltip:AddLine(opts.fallbackTitle, 1, 1, 1)
            end
            if opts.spellID then
                GameTooltip:AddLine(format(L["Spell IDs: %s"], tostring(opts.spellID)), 0.5, 0.5, 0.5)
            end
        end
        AddTooltipLines(opts.lines)
        GameTooltip:Show()
        return seeded
    end

    -- Same cursor default as ShowTooltip — a spell tooltip on a settings row has
    -- to behave like every other tooltip in the window, and this one was still on
    -- the old ANCHOR_RIGHT.
    if opts.anchor then
        GameTooltip:SetOwner(owner, opts.anchor)
    else
        GameTooltip:SetOwner(owner, "ANCHOR_CURSOR_RIGHT", CURSOR_LIFT_X, CURSOR_LIFT_Y)
    end
    if Fill() or not opts.spellID then return end

    -- Nothing rendered. If the data exists server-side but is not loaded yet,
    -- this both requests the load and re-renders when it arrives. A cached spell
    -- never reaches here (SetSpellByID already had its chance), so the callback
    -- cannot double-add the fallback.
    local spell = Spell and Spell.CreateFromSpellID and Spell:CreateFromSpellID(opts.spellID)
    if not spell or spell:IsSpellEmpty() or spell:IsSpellDataCached() then return end
    local spellID, isCurrent = opts.spellID, opts.isCurrent
    spell:ContinueOnSpellLoad(function()
        if GameTooltip:IsShown() and GameTooltip:IsOwned(owner) and owner:IsMouseOver()
            and (not isCurrent or isCurrent(owner, spellID)) then
            GameTooltip:ClearLines()
            Fill()
        end
    end)
end