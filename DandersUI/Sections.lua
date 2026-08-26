local addonName, NS = ...
local UI = NS.__DandersUI
if not UI then return end

-- ============================================================
-- SECTIONS -- the page-composition half of the toolkit.
-- Collapsible settings groups, the info banner, the link/note text flows, the
-- section-jump helpers, and the game-data tooltip. Part of the load-on-demand
-- options manifest: a consumer only needs these once a settings panel opens.
--
-- ☠ SHADOW HAZARD -- ALWAYS CALL THE *Native FACTORY NAMES FROM THIS FILE.
-- A consumer may define POSITIONAL CreateSlider / CreateDropdown /
-- CreateAnchorGrid / CreateCheckbox / CreateEditBox / CreateButton / CreateLabel
-- on its own HOST table, which shadows the pack's native factories for that
-- consumer only. A bare `self:CreateLabel` call from library code would then
-- land on the consumer's positional shim, which reads argument 2 as a plain
-- string and argument 3 as a width -- so the opts table is silently mis-parsed
-- and the widget comes back wrong with no error. Every factory here therefore
-- goes through the *Native alias (self:CreateLabelNative(parent, {...})), which
-- nothing shadows.
--
-- Canonical source lives at <repo>/DandersUI; never edit the copies under
-- */Libs/.
-- ============================================================

local S = UI._state
local P = UI._priv
local C_BACKGROUND, C_TEXT, C_TEXT_DIM =
      UI.Colors.background, UI.Colors.text, UI.Colors.textDim
local ResolveRowHeight = UI.ResolveRowHeight
local SnapLen = UI.SnapLen
local CreateElementBackdrop = UI._priv.CreateElementBackdrop
-- Tooltip primitives and the tone palette are in the RESIDENT half: live frames
-- need them with this manifest unloaded. Aliases of those objects, not copies.
local INFO_BANNER_TONES = P.INFO_BANNER_TONES
local AddTooltipLines = P.AddTooltipLines
-- ShowGameTooltip below shares its cursor lift with the resident ShowTooltip.
local CURSOR_LIFT_X, CURSOR_LIFT_Y = P.CURSOR_LIFT_X, P.CURSOR_LIFT_Y
-- Media resolves inside whichever addon carries the BASE copy of the pack.
local ICON_PATH = UI.MEDIA .. "Icons\\"

local CreateFrame, GameTooltip, UIParent = CreateFrame, GameTooltip, UIParent
local C_Timer, Spell, _G = C_Timer, Spell, _G
local ipairs, type, pcall = ipairs, type, pcall
local format, strsplit, string = string.format, strsplit, string
local math, table = math, table

-- ============================================================
-- CONSUMER-SUPPLIED HOST METHODS
-- Two of the surfaces below still live on the consumer's host rather than in
-- the pack: GetCollapsedGroups (collapse state persists in the consumer's
-- SavedVariables, which the pack has none of) and RelayoutHost (the settings
-- PAGE layout engine has not moved yet). Both are reached off `self` and both
-- are guarded, so a host that supplies neither still gets working groups and
-- banners -- they just do not persist or bubble a re-flow.
-- ============================================================

function UI:CreateSettingsGroup(parent, width, opts)
    -- opts can be a boolean (legacy: collapsible) or a table
    -- { collapsible, showSummary, collapseKey, chromeless, padding }.
    -- chromeless and padding are opt-in and change nothing for a call site that
    -- passes neither -- see where each is read below.
    --
    -- ⚠ (Removed) onCollapseChanged. It was stored here and fired from both collapse
    -- paths, and NOTHING ever set it -- so neither guard could fire and the callback
    -- was an advertised extension point with no consumer. A page that needs to react
    -- to a collapse uses RefreshStates, which both paths already call one line earlier.
    if type(opts) == "boolean" then opts = { collapsible = opts } end
    opts = opts or {}

    -- ☠ CAPTURED, not read off `self` later. Every closure below is installed on a
    -- FRAME (group.AddWidget, group.LayoutChildren, the OnClick handlers), and those
    -- take the frame as their own `self` -- so the host has to be an upvalue.
    local host = self

    local group = CreateFrame("Frame", nil, parent, "BackdropTemplate")
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
    --
    -- opts.padding overrides the inset the column is laid out at. ONE number for
    -- both the field and the local: LayoutChildren reads self.padding, so the two
    -- must not be allowed to disagree. 0 is a legal value (a group mounted inside
    -- a surface that already pads, e.g. a popout pane), which is why this is a
    -- type test rather than an `or` -- `0 or 10` would happen to work in Lua, but
    -- the test says what is meant.
    local padding = (type(opts.padding) == "number") and opts.padding or 10
    local margin = 10  -- Space between groups
    group.padding = padding
    group.margin = margin

    -- 8%, and worth knowing why it is not 16%: it was, for a while, because an
    -- 8% edge that split across two device rows left 4% on each and neither was
    -- visible. Doubling it made the surviving half readable at the cost of the
    -- whole border reading too heavy when it did NOT split. The border no longer
    -- has to survive being split, because it no longer splits -- so the alpha
    -- went back to the value that was right in the first place.
    --
    -- opts.chromeless skips the box entirely -- no fill, no border. For a group
    -- that is not a box ON a page but the whole CONTENTS of another surface: a
    -- popout pane already draws its own panel, and a faint bordered rectangle
    -- inside it reads as a second, smaller panel rather than as the panel's
    -- contents.
    if not opts.chromeless then
        CreateElementBackdrop(group, {
            bgColor     = { 1, 1, 1, 0.03 },   -- very subtle white background (3%)
            borderColor = { 1, 1, 1, 0.08 },   -- subtle white border (8%)
        })
    end

    -- The consumer's persisted collapse map, or nil when it keeps none (the pack
    -- has no SavedVariables of its own). Every reader below guards for nil, which
    -- degrades to "sections always start expanded and do not remember".
    local function CollapsedGroups()
        if host.GetCollapsedGroups then return host:GetCollapsedGroups() end
    end

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
        -- "expand_more" is a down chevron; rotate 180° so it points UP — this bar
        -- collapses the (expanded) section, so an up arrow reads correctly.
        barIcon:SetTexture(ICON_PATH .. "expand_more")
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
                local saved = CollapsedGroups()
                if saved then saved[stateKey] = true end
            end
            if group.collapseArrow then
                group.collapseArrow:SetTexture(ICON_PATH .. "chevron_right")
            end
            -- A page that owns its own layout (rather than re-flowing itself off
            -- RefreshStates below) re-runs it from this hook.
            host:Call("onSectionToggled", stateKey, false)
            local pageChild = group:GetParent()
            if pageChild and pageChild.RefreshStates then pageChild.RefreshStates() end
        end)

        collapseBar:Hide()
        group.collapseBar = collapseBar
    end

    -- Add a widget to this group
    group.AddWidget = function(self, widget, height)
        widget:SetParent(self)
        -- Record whether the CALL SITE pinned this slot's height. A self-measuring
        -- widget (a measured label) may only re-flow the group when it did not — an
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
            local savedStates = CollapsedGroups()
            if stateKey and savedStates and savedStates[stateKey] then
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
            arrow:SetTexture(self.collapsed and (ICON_PATH .. "chevron_right") or (ICON_PATH .. "expand_more"))
            local c = host:GetAccent()
            arrow:SetVertexColor(c.r, c.g, c.b)
            self.collapseArrow = arrow

            -- Theme listener for arrow color
            -- Tint to an EXPLICIT colour: the kit-wide published name, so a
            -- surface owning a colour of its own (a popout cascading its accent
            -- into what a consumer mounted in it) has one entry point.
            arrow.ApplyThemeColor = function(c)
                if c then arrow:SetVertexColor(c.r, c.g, c.b) end
            end
            -- ⚠ No arguments -- see the slider's note in Widgets.lua: colon call
            -- sites would fill a parameter here with the widget itself.
            arrow.UpdateTheme = function()
                arrow.ApplyThemeColor(host:GetAccent())
            end
            if not parent.ThemeListeners then parent.ThemeListeners = {} end
            table.insert(parent.ThemeListeners, arrow)

            -- Make the header clickable
            widget:EnableMouse(true)
            widget:SetScript("OnMouseDown", function()
                self.collapsed = not self.collapsed
                -- Persist collapsed state to the consumer's saved state
                if stateKey then
                    local saved = CollapsedGroups()
                    -- only store true, remove when expanded
                    if saved then saved[stateKey] = self.collapsed or nil end
                end
                arrow:SetTexture(self.collapsed and (ICON_PATH .. "chevron_right") or (ICON_PATH .. "expand_more"))
                -- Refresh the page to recalculate layout. A page that owns its own
                -- layout re-runs it from the hook; pages built by the standard page
                -- builder expose RefreshStates on the group's parent.
                host:Call("onSectionToggled", stateKey, not self.collapsed)
                local pageChild = self:GetParent()
                if pageChild and pageChild.RefreshStates then pageChild.RefreshStates() end
            end)

            -- Highlight arrow on hover to indicate clickable
            widget:SetScript("OnEnter", function()
                arrow:SetVertexColor(1, 1, 1)
            end)
            widget:SetScript("OnLeave", function()
                local nc = host:GetAccent()
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
        local layoutDB = host:Call("getSettingsDB")
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

            -- Close up a RUN of the same compact kind (see UI.RowGapTight). The
            -- reduction is taken off THIS row's slot, so it only ever affects the
            -- gap to the row below -- and only when that row is the same compact
            -- kind, which is what keeps the boundary between different kinds at
            -- the full RowGap.
            local kind = widget.rowKind
            widget._rowTightened, widget._rowNextKind = false, nil
            if kind and UI.RowCompact[kind] then
                for j = i + 1, #self.groupChildren do
                    if entryVisible(self.groupChildren[j], j) then
                        -- Recorded even when it does NOT match, so a gap-check report can
                        -- say WHY a run did not close up: a row with no rowKind
                        -- sitting between two checkboxes breaks the run for the
                        -- layout while being invisible to the report (a widget
                        -- that draws nothing is skipped there), which would look
                        -- like the tightening was simply inert.
                        widget._rowNextKind = self.groupChildren[j].widget.rowKind or "<none>"
                        if self.groupChildren[j].widget.rowKind == kind then
                            height = height - (UI.RowGap - UI.RowGapTight)
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
                    local db = host:Call("getSettingsDB")
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
                        -- ☠ A NAMELESS font on purpose -- NOT host:SetSettingsFont. The
                        -- summary has always drawn in the consumer's FALLBACK face rather
                        -- than its chosen settings font, and routing it through the
                        -- settings-font path would silently restyle every collapsed
                        -- section. Passing nil for the name is what asks the consumer's
                        -- own setter for its fallback (mirrors Fonts.lua's SafeSet, which
                        -- is a file local there and cannot be reused).
                        local setFont = host:Hook("safeSetFont")
                        local handled = false
                        if setFont then
                            local ok, res = pcall(setFont, self.collapseSummary, nil, 9, "")
                            handled = ok and res ~= false
                        end
                        if not handled then
                            pcall(self.collapseSummary.SetFont, self.collapseSummary, "Fonts\\FRIZQT__.TTF", 9, "")
                        end
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
        local db = host:Call("getSettingsDB")
        if not db then return end

        -- Group-level grey-out: set self.disableChildrenOn = function(db) ... end to
        -- grey EVERY child when it returns true, EXCEPT the header and any widget
        -- flagged widget.keepEnabled (the feature's own Enable toggle). Saves putting a
        -- disableOn on every control; composes with per-widget disableOn (a child is
        -- disabled if either says so). The checkbox factory auto-calls RefreshStates on
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

-- The usable width INSIDE a settings group / card group — what a variable-width child
-- (label, note, link) must be told before AddWidget, because those honour a passed width and
-- measure their wrapped height from it.
--
-- Exists because this exact expression had been copy-pasted to five call sites across three
-- files, which is precisely the per-site fork the factory contract forbids. The 260 fallback
-- covers a group asked for its width before layout has run (cards build their contents
-- before the card is sized); the floor keeps a mid-relayout zero from producing a negative
-- wrap width, which renders as a single unwrapped line running off the panel.
function UI:GroupInnerWidth(group)
    if not group then return 260 end
    return math.max(40, (group:GetWidth() or 260) - 2 * (group.padding or 10))
end

-- Shared link HOVER colour: the rest colour (the host accent) LIGHTENED toward white. Keeps
-- the hue, so a hovered link brightens instead of going flat white and blending into white
-- body text. One source of truth for every link's hover (SetHTML links, the page/URL link
-- buttons, and hand-rolled note links). `c` = the link's rest colour (defaults to the live
-- accent); returns {r,g,b}.
function UI:LinkHoverColor(c)
    c = c or self:GetAccent() or { r = 1, g = 1, b = 1 }
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
function UI:GetToneColor(toneName)
    local t = INFO_BANNER_TONES[toneName] or INFO_BANNER_TONES.caution
    return t.accent or t.iconColor or t.textColor or {1, 1, 1}
end

function UI:ToneHex(toneName)
    local t = INFO_BANNER_TONES[toneName] or INFO_BANNER_TONES.caution
    local c = t.accent or t.iconColor or t.textColor or {1, 1, 1}
    return string.format("ff%02x%02x%02x",
        math.floor((c[1] or 1) * 255 + 0.5),
        math.floor((c[2] or 1) * 255 + 0.5),
        math.floor((c[3] or 1) * 255 + 0.5))
end

-- Shared inline-markup parser: split "…|cCOLOR|HlinkData|hText|h|r…" (WoW hyperlink markup
-- plus \n line breaks) into a flat token list of { type = "word"/"link"/"newline", text, data,
-- color }. Used by the InfoBanner's SetHTML flow AND UI:CreateLink, so both read links the
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
-- isolates one space advance. `sizePx` set → measure the consumer's settings font at
-- that px (matches a banner word, which is SetSettingsFont'd); nil → measure the
-- template's own font object (a CreateLink / template-fonted word). One reused
-- probe (no per-call FontString churn); measured fresh so a font-family change is
-- always reflected. Returns the EXACT fractional advance (no pixel rounding) so the
-- flow spaces identically to native wrapped text — see the return note below.
local function FlowSpaceWidth(host, tmpl, sizePx)
    tmpl = tmpl or "DFFontHighlightSmall"
    if not S._flowProbe then
        S._flowProbe = UIParent:CreateFontString(nil, "OVERLAY")
    end
    if sizePx then
        host:SetSettingsFont(S._flowProbe, sizePx, "")
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
--
-- ⚠ label IS THE WHOLE CONTRACT. `sublabel` and `level` were documented here and read
-- below, and all three call sites pass only `label` -- so the small line is always the
-- shared "Enable the checkbox above to use" and the level bump is always 50. Both are
-- literals now rather than options nobody can reach.
--
-- Returns the frame; drive it with :SetShown(not enabled) from wherever the
-- flag changes.
-- ============================================================
function UI:CreateDisabledOverlay(parent, opts)
    opts = opts or {}
    local L = self.hooks.L
    local overlay = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    overlay:SetFrameLevel((parent:GetFrameLevel() or 0) + 50)
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
    sub:SetText(L["Enable the checkbox above to use"])
    sub:SetTextColor(0.45, 0.45, 0.45, 1)
    overlay.SubLabel = sub

    return overlay
end

function UI:CreateInfoBanner(parent, opts)
    opts = opts or {}
    local host = self

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
        host:SetSettingsFont(body, 11, "")
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
    -- RelayoutHost, which is this logic verbatim; the page bubble is what stops a
    -- grown group's backdrop overshooting the next group's anchor when an animation
    -- type is first selected in a border panel.
    local function TriggerHostRelayout()
        if host.RelayoutHost then host:RelayoutHost(banner, banner.layoutHeight) end
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
        -- proxy-backed dbTable in the Aura Designer = sustained lockup.
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
    -- LayoutChildren re-fires SetWidth on every pass (the Aura Designer's
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
            local tc = host:GetAccent() or {r = 1, g = 1, b = 1}
            self:SetBackdropBorderColor(tc.r, tc.g, tc.b, tone.borderAlpha or 1)
        elseif tone.border then
            self:SetBackdropBorderColor(tone.border[1], tone.border[2], tone.border[3], tone.border[4] or 1)
        end
        if tone.icon then
            self:SetIconTexture(ICON_PATH .. tone.icon)
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

    -- Accent-coloured "Title: body" content with a live-updating title colour +
    -- accent border (folds in the old CreateInfoCallout). Registers the banner as
    -- a ThemeListener so the title/border re-colour on accent change.
    function banner:SetContent(title, body)
        self._contentTitle, self._contentBody = title, body
        if title and title ~= "" then
            local tc = host:GetAccent() or { r = 1, g = 1, b = 1 }
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

    -- (Markup parsing is the file-level ParseHTMLSegments, shared with UI:CreateLink.)

    -- Position all flow widgets left-to-right with wrapping; returns total
    -- content height. Punctuation tokens attach to the preceding element
    -- with no leading gap so "Foo," renders without extra space before the comma.
    local FLOW_LINE_H = 14
    -- Banner words are SetSettingsFont'd to 11px unless a custom template is given; measure the
    -- space advance at that same font so the flow spaces like native text (see FlowSpaceWidth).
    local flowSpaceW = FlowSpaceWidth(host, fontTemplate, (not opts.fontTemplate) and 11 or nil)
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
        -- The link words are tinted with the accent at render time (below),
        -- NOT baked into `text`, so an accent change must re-render even
        -- when the text is identical — fold the accent into the dedupe key.
        local _tc = host:GetAccent() or {r = 1, g = 0.82, b = 0}
        local themeKey = string.format("%.3f,%.3f,%.3f", _tc.r or 1, _tc.g or 1, _tc.b or 1)
        -- Idempotent guard (FREEZE FIX): tearing down + rebuilding the flow widgets
        -- resets cachedH and re-fires RecomputeHeight -> TriggerHostRelayout ->
        -- host:RefreshStates. This banner's SetHTML is driven from a refreshContent
        -- hook that RefreshStates calls on EVERY pass, so an unguarded rebuild loops
        -- forever (game freeze — seen on the Buffs page when the Aura Designer banner
        -- is shown). Skip the rebuild when neither the text nor the link-tint accent
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

        local tc = host:GetAccent() or {r = 1, g = 0.82, b = 0}
        local segs = ParseHTMLSegments(self._htmlText)
        self._flowSegs = segs

        for _, seg in ipairs(segs) do
            if seg.type == "word" then
                local fs = self:CreateFontString(nil, "OVERLAY", fontTemplate)
                if not opts.fontTemplate then host:SetSettingsFont(fs, 11, "") end  -- match the 11px plain body
                fs:SetText(seg.text)
                fs:SetTextColor(0.85, 0.85, 0.85)
                seg._w = fs:GetStringWidth()
                -- HEIGHT ONLY -- deliberately no width. The height matches the link button so
                -- TOPLEFT anchors put words and links on the same baseline; the width is left
                -- unset so the fontstring auto-sizes to its own text.
                -- ☠ AN EXPLICIT WIDTH HERE IS A CLIP RECT, and with word wrap off a
                -- fontstring one sub-pixel too narrow renders as "...". Glyph advances snap to
                -- PHYSICAL pixels, so a box measured at one UI scale is wrong at another: these
                -- were sized from GetStringWidth at 100% and every word truncated at 95%.
                -- An unset width cannot truncate at any scale.
                -- Safe because DoFlowLayout positions from seg._w and never reads the widget's
                -- own width -- the box is invisible to spacing and to wrapping.
                fs:SetHeight(FLOW_LINE_H)
                seg._widget = fs
                self._flowWidgets[#self._flowWidgets + 1] = fs
            elseif seg.type == "link" then
                local btn = CreateFrame("Button", nil, self)
                local fs = btn:CreateFontString(nil, "OVERLAY", fontTemplate)
                if not opts.fontTemplate then host:SetSettingsFont(fs, 11, "") end  -- match the 11px plain body
                -- Anchored, NOT SetAllPoints: the button is the hit rect and gets a ceil'd
                -- width below, but pinning the fontstring to it makes that box a clip rect
                -- too, and the same scale-dependent metrics truncated links as well as words.
                -- Left-anchored with no width, the text auto-sizes; the button keeps an honest
                -- hit rect. LEFT justify kept so it still reads correctly if a width is ever set.
                fs:SetPoint("LEFT", btn, "LEFT", 0, 0)
                fs:SetJustifyH("LEFT")   -- ink flush-left so the link spaces like a plain word
                fs:SetText(seg.text)
                fs:SetTextColor(tc.r, tc.g, tc.b)
                -- Box width ceil'd (anti last-glyph clip), but the flow ADVANCE uses the
                -- RAW width — else the ≤1px of empty box after every link became extra
                -- gap before the next word (looser than native). seg._w drives the gap.
                local rawW = fs:GetStringWidth()
                btn:SetSize(math.ceil(rawW), FLOW_LINE_H)
                btn:SetScript("OnEnter", function()
                    local h = host:LinkHoverColor(host:GetAccent() or tc)
                    fs:SetTextColor(h.r, h.g, h.b)
                end)
                btn:SetScript("OnLeave", function()
                    local c = host:GetAccent() or tc
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
-- UI:CreateLink — lean inline text + clickable links in a NOTE style (no box), FIXED layout.
-- The link-capable counterpart to a plain note: same |cCOLOR|Hdata|hText|h|r markup as the
-- InfoBanner (shared ParseHTMLSegments), rendered as flowing dim body text with an accented,
-- hover-lightening Button per link — but WITHOUT the banner's self-resize machinery, so it is
-- safe inside reflowing card containers (no OnSizeChanged -> relayout loop that drops FPS
-- there). Only the link words are clickable/hovered (fixes the old note's whole-frame click).
-- Named CreateLink (not CreateLinkText) so we can grow other link forms.
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
function UI:CreateLink(parent, text, opts)
    opts = opts or {}
    local host = self
    local onLinkClick = opts.onLinkClick
    local fontTemplate = opts.fontTemplate or "DFFontHighlightSmall"
    local LINE_H = opts.lineHeight or 14
    local PAD_TOP = opts.padTop or 2
    local PAD_BOTTOM = opts.padBottom or 8
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(LINE_H)

    local segs = ParseHTMLSegments(text or "")
    local tc = host:GetAccent() or { r = 1, g = 0.82, b = 0 }

    for _, seg in ipairs(segs) do
        if seg.type == "word" then
            local fs = frame:CreateFontString(nil, "OVERLAY", fontTemplate)
            fs:SetText(seg.text)
            fs:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)   -- dim body, like a note
            seg._w = fs:GetStringWidth()
            -- Height only, no width -- see the matching note in SetHTML. An explicit width is
            -- a clip rect, and a box measured at one UI scale is a hair short at another, so
            -- every word rendered as "...". The flow reads seg._w, never the widget's width.
            fs:SetHeight(LINE_H)
            seg._widget = fs
        elseif seg.type == "link" then
            local btn = CreateFrame("Button", nil, frame)
            local fs = btn:CreateFontString(nil, "OVERLAY", fontTemplate)
            -- Anchored, not SetAllPoints, so the button's box stays a hit rect and never
            -- clips the text (see SetHTML).
            fs:SetPoint("LEFT", btn, "LEFT", 0, 0)
            fs:SetJustifyH("LEFT")   -- ink flush-left so the link spaces like a plain word
            fs:SetText(seg.text)
            fs:SetTextColor(tc.r, tc.g, tc.b)
            -- Box ceil'd (anti last-glyph clip); flow ADVANCE uses the RAW width so the
            -- ≤1px of empty box after a link doesn't become extra word gap (see SetHTML).
            local rawW = fs:GetStringWidth()
            btn:SetSize(math.ceil(rawW), LINE_H)
            btn:SetScript("OnEnter", function()
                local h = host:LinkHoverColor(host:GetAccent() or tc)
                fs:SetTextColor(h.r, h.g, h.b)
            end)
            btn:SetScript("OnLeave", function()
                local c = host:GetAccent() or tc
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
    local SPACE_W = FlowSpaceWidth(host, fontTemplate)

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

-- UI:FlashWidget — the "show me" pulse: briefly highlight a widget/section in the accent
-- colour so the eye lands on it after a jump. One reused overlay per target; the colour
-- refreshes each call.
-- opts (all opt-in / out):
--   fill    (default true)  — a soft accent-coloured WASH (peaks ~35% alpha, control stays legible).
--   border  (default false) — an accent-coloured OUTLINE. Mix per call: a whole section reads well
--                             as border-only; a single control as fill + border.
--   alpha       fill peak alpha (default 0.35).   borderSize  outline thickness px (default 2).
-- The overlay is a backdrop frame parented to the target's parent + anchored to the target, so
-- it works whether the target is a Frame or a raw FontString (section headers).
function UI:FlashWidget(widget, opts)
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
    local c = self:GetAccent() or { r = 1, g = 0.82, b = 0 }
    -- Re-issued per call so the pulse picks up the current accent colour.
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

-- UI:LinkToSetting — the click action for a settings-link: jump to a setting and flash it.
-- Unifies same-page and cross-page so every link behaves identically. target:
--   page      tab to switch to first (nil = stay on the current page).
--   section   section header text — scrolls to it (the scrollToSection hook) and flashes it.
--   widget    explicit widget to flash (overrides the section-header lookup).
--   scrollTo  optional function() that scrolls a CUSTOM container (e.g. a card)
--             to the target — used instead of the page section scroll.
--   flash     false = no pulse; a table = FlashWidget opts (fill / border / …) so a link picks
--             its own highlight style; nil or true = the default flash.
function UI:LinkToSetting(target)
    if type(target) ~= "table" then return end
    local host = self
    local scrollToSection = host:Hook("scrollToSection")
    local function go()
        local w = target.widget
        if target.scrollTo then
            target.scrollTo()
        elseif target.page and target.section and scrollToSection then
            w = scrollToSection(target.page, target.section) or w
        end
        if w and target.flash ~= false then
            local fopts = type(target.flash) == "table" and target.flash or nil
            C_Timer.After(0.05, function() host:FlashWidget(w, fopts) end)   -- after the scroll settles
        end
    end
    if target.page and host.SelectTab then
        host.SelectTab(target.page)
        C_Timer.After(0.12, go)   -- let the tab build + lay out before scroll/flash
    else
        go()
    end
end

-- ============================================================
-- SECTION-JUMP NOTES
-- Three shared "this setting lives over there" notes. Each is a fixed-layout
-- UI:CreateLink whose single link jumps to another page's section and flashes it.
--
-- ☠ They RETURN NIL when the consumer supplies no scrollToSection hook. Without
-- it the link could switch tabs but never land on the section, so the control
-- would promise a jump it cannot make -- better not to draw it at all.
-- ============================================================

-- The shared "Customize duration colors on the Colors page." note. Used by the aura
-- pages AND wherever a "Color by Time Remaining" control draws from those breakpoints —
-- one cross-link, defined once.
--   `width`  flows the fixed-layout note up front (see UI:CreateLink); the caller then
--            AddWidget's it at note.layoutHeight. The |cffffffff is a parser placeholder —
--            CreateLink re-tints the link itself.
function UI:CreateColorsPageLink(parent, width)
    if not self:Hook("scrollToSection") then return nil end
    local host, L = self, self.hooks.L
    local link = string.format("|cffffffff|HdfColors|h%s|h|r", L["Colors page"])
    local text = string.format(L["Customize duration colors on the %s."], link)
    return host:CreateLink(parent, text, {
        width = width,
        onLinkClick = function()
            host:LinkToSetting({
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
function UI:CreateDispelColorsPageLink(parent, width)
    if not self:Hook("scrollToSection") then return nil end
    local host, L = self, self.hooks.L
    local link = string.format("|cffffffff|HdfColors|h%s|h|r", L["Colors page"])
    local text = string.format(L["Set the per-dispel-type colours on the %s."], link)
    return host:CreateLink(parent, text, {
        width = width,
        onLinkClick = function()
            host:LinkToSetting({
                page    = "display_classcolors",
                section = L["Dispel Type Colors"],
                flash   = { border = true, fill = false },
            })
        end,
    })
end

-- Third of the same family: a text shadow's OFFSET and COLOUR are account-wide, so any
-- per-element "Shadow" checkbox can only decide WHETHER there is one. ⚠ That is not a
-- layering choice, it is forced — on 12.0.7 a fontstring's SetShadowColor/SetShadowOffset
-- is a silent no-op, so the shadow rides the shared font OBJECT and every consumer of that
-- font gets the same one. Jumps to Global Fonts and flashes its Shadow Settings section.
function UI:CreateGlobalFontsShadowLink(parent, width)
    if not self:Hook("scrollToSection") then return nil end
    local host, L = self, self.hooks.L
    local link = string.format("|cffffffff|HdfFonts|h%s|h|r", L["Global Fonts"])
    local text = string.format(L["Shadow offset and colour are set in %s."], link)
    return host:CreateLink(parent, text, {
        width = width,
        onLinkClick = function()
            host:LinkToSetting({
                page    = "general_fonts",
                section = L["Shadow Settings"],
                flash   = { border = true, fill = false },
            })
        end,
    })
end

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

function UI:ShowGameTooltip(owner, opts)
    if not owner or not opts then return end
    local host, L = self, self.hooks.L

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
        AddTooltipLines(host, opts.lines)
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
