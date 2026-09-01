-- Part 5 of the Aura Designer editor, split from Options.lua.
-- Aliases of objects the first part created; they add no state.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local L = DF.L
local GUI = DF.GUI
local Adapter = DF.AuraDesigner.Adapter
local S = DF.AuraDesigner._uiState
local P = DF.AuraDesigner._priv
local C_ELEMENT = GUI.Colors.element
local C_BORDER = GUI.Colors.border
local C_HOVER = GUI.Colors.hover
local C_TEXT = GUI.Colors.text
local C_TEXT_DIM = GUI.Colors.textDim
local OPTS = P.OPTS
local GetAuraDesignerDB = P.GetAuraDesignerDB
local GetThemeColor = P.GetThemeColor
local ApplyBackdrop = P.ApplyBackdrop
local CreateCardShell = P.CreateCardShell
local CreateCardStack = P.CreateCardStack
local ResolveSpec = P.ResolveSpec
local CreateDebuffGroup = P.CreateDebuffGroup
local IsOtherTab = P.IsOtherTab
local CurrentAuraPool = P.CurrentAuraPool
local PoolKeyPrefix = P.PoolKeyPrefix
local DebuffGroupsRead = P.DebuffGroupsRead
local CurrentLayoutGroups = P.CurrentLayoutGroups
local OtherPoolDisplayName = P.OtherPoolDisplayName
local RemoveIndicatorInstance = P.RemoveIndicatorInstance
local GetAuraIcon = P.GetAuraIcon
local expandedGroups = P.expandedGroups
local GroupExpandKey = P.GroupExpandKey
local CreateLayoutGroup = P.CreateLayoutGroup
local DeleteLayoutGroup = P.DeleteLayoutGroup
local DeleteDebuffGroup = P.DeleteDebuffGroup
local RemoveGroupMember = P.RemoveGroupMember
local SwapGroupMembers = P.SwapGroupMembers
local expandedCards = P.expandedCards
local tabButtons = P.tabButtons
local mainTabButtons = P.mainTabButtons
local effectCardPool = P.effectCardPool
local BADGE_COLORS = P.BADGE_COLORS
local placedIndicators = P.placedIndicators
local ClearPlacedIndicators = P.ClearPlacedIndicators
local RefreshPlacedIndicators = P.RefreshPlacedIndicators
local RefreshPreviewEffects = P.RefreshPreviewEffects
local CreateEnableBanner = P.CreateEnableBanner
local CreateSpecDropdown = P.CreateSpecDropdown
local CreateFramePreview = P.CreateFramePreview
local CreateFrameTile = P.CreateFrameTile
local CreateNumberedHeading = P.CreateNumberedHeading
local UpdateLayoutTabState = P.UpdateLayoutTabState
local UpdateSpecDropdownState = P.UpdateSpecDropdownState
local SetMainTab = P.SetMainTab
local OpenGroupSpellPicker = P.OpenGroupSpellPicker
local OpenFilterPicker = P.OpenFilterPicker
local AddGroupAppearanceSection = P.AddGroupAppearanceSection

-- ============================================================
-- ONE GROUP'S SETTINGS, ONCE, FOR BOTH LAYOUTS
-- ------------------------------------------------------------
-- A layout group's card and a layout group's rows differ in WHERE a widget goes
-- and in nothing else. Everything that decides WHICH control, on WHICH table,
-- under WHICH key lives in the collectors below and only there: a control that
-- changed layout and lost its binding would read the record and write nowhere,
-- looking completely correct while doing so, which is the one failure this
-- conversion cannot have.
--
-- A section is { header, caption, gap, build }. `header` is the popout row's
-- label, `caption` the card's own small-caps caption over the same block, `gap`
-- the blank the card leaves above it. `build` is handed an `env`:
--
--   env.place(widget, height, opts)  where the widget goes.
--       opts.indent   the card's x inset (default 5); ignored in a pane
--       opts.width    the card's width (default the body less twice the indent);
--                     `false` leaves whatever the widget set itself
--       opts.stretch  the card anchors BOTH edges instead of setting a width
--       opts.gap      blank the card leaves ABOVE the widget; a pane's own
--                     row spacing already provides it
--   env.host        the widget parent -- the card BODY, or a popout pane's holder
--   env.caption     the caption fontstring the loop just placed, or nil in a pane
--                   (where the ROW's own label is the caption)
--   env.captionY    the y that caption sits at, for the one control that shares
--                   its row
--   env.Rebuild()   THE LIST THIS SECTION DRAWS HAS CHANGED SHAPE. Both layouts
--                   redraw; in the row layout that closes the panel, which is
--                   honest -- the thing being edited is gone.
--   env.Redraw()    a value moved and the widgets around it must re-read their
--                   greying. The CARD can only answer that with a tab rebuild;
--                   a PANE re-flows itself, because a rebuild would retire the
--                   tick the user just clicked.
--   env.Header()    the group header's own summary text is stale. A no-op on the
--                   card, whose rebuild redraws it anyway.
-- ============================================================

-- The card's placer: the hand-run y cursor these bodies have always used, with
-- `state.by` carried between sections so the captions and gaps land where they
-- always did.
local function CardPlace(body, bodyWidth, state)
    return function(widget, height, opts)
        opts = opts or {}
        local indent = opts.indent or 5
        if opts.gap then state.by = state.by - opts.gap end
        widget:SetPoint("TOPLEFT", body, "TOPLEFT", indent, state.by)
        if opts.stretch then
            widget:SetPoint("RIGHT", body, "RIGHT", -indent, 0)
        elseif opts.width ~= false and widget.SetWidth then
            widget:SetWidth(opts.width or (bodyWidth - indent * 2))
        end
        state.by = state.by - height
    end
end

-- Run a collected section list down a card body, captions and gaps included.
-- Returns the cursor, so the caller carries on where the last section stopped.
local function RunCardSections(body, bodyWidth, by, sections)
    for _, sec in ipairs(sections) do
        by = by - (sec.gap or 0)
        local caption, captionY
        if sec.caption then
            captionY = by
            caption = body:CreateFontString(nil, "OVERLAY")
            GUI:SetSettingsFont(caption, 8, "")
            caption:SetPoint("TOPLEFT", 8, by)
            caption:SetText(sec.caption)
            caption:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
            by = by - 18
        end
        local state = { by = by }
        sec.build({
            place = CardPlace(body, bodyWidth, state),
            host = body, caption = caption, captionY = captionY,
            bodyWidth = bodyWidth,
            Rebuild = function() S.SwitchTab("layout") end,
            Redraw  = function() S.SwitchTab("layout") end,
            Header  = function() end,
        })
        by = state.by
    end
    return by
end

-- Display name lookup (My Buffs: the spec's trackable pool; Other Buffs:
-- ad-hoc/SpellDB resolution -- other-pool names aren't in a spec pool).
-- ⚠ RESOLVED PER MEMBER rather than through a map built once per tab: the row
-- layout has no single tab build to hang a map off, and a group's member list is
-- a handful of names.
local function MemberDisplayName(auraName)
    if IsOtherTab() then return OtherPoolDisplayName(auraName) end
    local spec = ResolveSpec()
    local trackable = spec and Adapter and Adapter:GetTrackableAuras(spec)
    if trackable then
        for _, info in ipairs(trackable) do
            if info.name == auraName then return info.display end
        end
    end
    return auraName
end

-- ── LINKED FILTERS (filter groups) ──
-- One collapsed chip per linked registry filter: localized preset name (or
-- custom filter name) + live spell count, remove ✕. Links are stable REFERENCES
-- (preset keys / custom ids) — never copies — so filter edits propagate live.
-- Link/unlink is structural (container rebuild + the buff-row dedup union
-- moves), so run the full refresh path.
local function BuildLinkedFiltersSection(env, group)
    local place, host = env.place, env.host
    local R = DF.FilterRegistry
    local fsel = group.filterSelection
    if not fsel then fsel = {}; group.filterSelection = fsel end
    fsel.presets = fsel.presets or {}
    fsel.customs = fsel.customs or {}

    local function StructuralFilterRefresh()
        env.Rebuild()
        RefreshPlacedIndicators()
        DF:InvalidateAuraLayout()
        DF:UpdateAllFrames()
        if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
            DF.AuraDesigner.Engine:ForceRefreshAllFrames()
        end
    end

    -- The route back. A filter group USES a filter and can link or unlink one,
    -- but it cannot change what is IN it -- that is the Aura Filters page, and
    -- nothing here said so or pointed at it. Same reverse link the Buff Bar page
    -- carries.
    --
    -- ☠ FIXED SIZE, not one measured from the label. It was
    -- SetWidth(GetStringWidth() + 2), which is a measurement taken the instant
    -- the fontstring is created: if the font object has not resolved yet
    -- GetStringWidth returns 0, the button collapses to its 10px floor, and the
    -- link renders perfectly while being almost impossible to click. A generous
    -- fixed box with the text right-aligned inside it cannot fail that way.
    --
    -- ⚠ "Manage Filters", not "Edit in Filter Designer". It cannot edit anything
    -- in particular -- it opens the library -- and each chip below carries a
    -- pencil that opens THAT filter.
    local LF_EDIT_W = 130
    local lfEdit = CreateFrame("Button", nil, host)
    lfEdit:SetSize(LF_EDIT_W, 16)
    local lfEditText = lfEdit:CreateFontString(nil, "OVERLAY")
    GUI:SetSettingsFont(lfEditText, 10, "")
    lfEditText:SetPoint("RIGHT", 0, 0)
    lfEditText:SetJustifyH("RIGHT")
    lfEditText:SetText(L["Manage Filters"])
    local lfTC = (GUI.GetThemeColor and GUI.GetThemeColor()) or { r = 1, g = 0.82, b = 0 }
    lfEditText:SetTextColor(lfTC.r, lfTC.g, lfTC.b)
    lfEdit:SetScript("OnEnter", function() lfEditText:SetTextColor(1, 1, 1) end)
    lfEdit:SetScript("OnLeave", function()
        -- Re-read the accent rather than restoring lfTC: a party/raid switch can
        -- repaint the card while the cursor is still on this.
        local c = (GUI.GetThemeColor and GUI.GetThemeColor()) or lfTC
        lfEditText:SetTextColor(c.r, c.g, c.b)
    end)
    lfEdit:SetScript("OnClick", function()
        if GUI.SelectTab then GUI.SelectTab("auras_filterdesigner") end
    end)
    -- ☠ ON THE CAPTION'S OWN ROW IN THE CARD, where `by` is a hand-run cursor and
    -- an extra row costs every measurement below it -- and a row of its own in a
    -- PANE, which has no caption to share (the popout row's label is the caption
    -- there). This is the cross-section coupling the rework keeps tripping over:
    -- a widget anchored to something the other layout does not build.
    if env.caption then
        lfEdit:SetPoint("TOPRIGHT", host, "TOPRIGHT", -8, env.captionY + 1)
    else
        place(lfEdit, 20, { stretch = true })
    end

    -- Custom-filter spell count (curated spells + raw IDs)
    local function CustomFilterCount(cf)
        local n = 0
        if cf then
            for _ in pairs(cf.spells or {}) do n = n + 1 end
            for _ in pairs(cf.rawIDs or {}) do n = n + 1 end
        end
        return n
    end

    -- Linked list: presets in R.Categories order, then customs name-sorted.
    local linked = {}
    for _, cat in ipairs(R.Categories) do
        if fsel.presets[cat.key] then
            local enabled, total = R:PresetCounts(cat.key)
            tinsert(linked, { kind = "preset", key = cat.key,
                label = format("%s |cff888888(%d/%d)|r", L[cat.name], enabled, total) })
        end
    end
    local linkedCustoms = {}
    for cfId in pairs(fsel.customs) do tinsert(linkedCustoms, cfId) end
    sort(linkedCustoms, function(a, b)
        local fa, fb = R:GetCustomFilter(a), R:GetCustomFilter(b)
        local na, nb = (fa and fa.name or ""), (fb and fb.name or "")
        if na ~= nb then return na < nb end
        return a < b
    end)
    for _, cfId in ipairs(linkedCustoms) do
        local cf = R:GetCustomFilter(cfId)
        tinsert(linked, { kind = "custom", key = cfId,
            label = format("%s |cff888888(%d)|r", (cf and cf.name) or cfId, CustomFilterCount(cf)) })
    end

    if #linked > 0 then
        for _, link in ipairs(linked) do
            local chipRow = CreateFrame("Frame", nil, host, "BackdropTemplate")
            chipRow:SetHeight(24)
            ApplyBackdrop(chipRow,
                {r = 0.11, g = 0.11, b = 0.11, a = 1},
                {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

            -- Remove ✕ (mirror the member-row remove idiom)
            local remBtn = DF.GUI:CreateGlyphButton(chipRow, {
                size = 18, iconSize = 12,
                texture    = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close",
                color      = { 0.55, 0.30, 0.30 },
                hoverColor = { 1, 0.40, 0.40 },
            })
            remBtn:SetPoint("RIGHT", -4, 0)
            local capturedLink = link
            remBtn:SetScript("OnClick", function()
                if capturedLink.kind == "preset" then
                    fsel.presets[capturedLink.key] = nil
                else
                    fsel.customs[capturedLink.key] = nil
                end
                StructuralFilterRefresh()
            end)

            -- Edit pencil, INSIDE the ✕ so the destructive control keeps the
            -- corner it already owns. Always drawn rather than shown on hover:
            -- the ✕ beside it is always drawn, so a hover-only sibling reads as
            -- the row having one action when it has two.
            -- ⚠ tooltip and onClick go in OPTS. CreateGlyphButton reads
            -- opts.tooltip inside the OnEnter it installs itself, so a
            -- btn.tooltip assigned afterwards is read by nothing.
            local editBtn = DF.GUI:CreateGlyphButton(chipRow, {
                size = 18, iconSize = 12,
                texture    = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\edit",
                color      = { C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b },
                hoverColor = { 1, 1, 1 },
                tooltip    = {
                    title = L["Edit this filter"],
                    lines = { L["Opens it in the Filter Designer, where you can change which auras it holds."] },
                },
                onClick    = function()
                    if GUI.OpenFilterInDesigner then
                        GUI:OpenFilterInDesigner(capturedLink.kind, capturedLink.key)
                    end
                end,
            })
            editBtn:SetPoint("RIGHT", remBtn, "LEFT", -2, 0)

            local chipText = chipRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            chipText:SetPoint("LEFT", 8, 0)
            chipText:SetPoint("RIGHT", editBtn, "LEFT", -4, 0)
            chipText:SetMaxLines(1)
            chipText:SetJustifyH("LEFT")
            chipText:SetText(link.label)
            chipText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            place(chipRow, 28, { indent = 8, stretch = true })
        end
    else
        local noLinks = CreateFrame("Frame", nil, host)
        noLinks:SetHeight(16)
        local noLinksText = noLinks:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        noLinksText:SetPoint("TOPLEFT", 4, 0)
        noLinksText:SetText(L["No filters linked yet"])
        noLinksText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
        place(noLinks, 20, { indent = 8, width = false })
    end

    -- "+ Add Filter" button → mini-picker of unlinked presets + customs
    local addFilterLinkBtn = CreateFrame("Button", nil, host, "BackdropTemplate")
    addFilterLinkBtn:SetHeight(22)
    GUI:StyleButton(addFilterLinkBtn, { height = 22, primary = true, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 11 }, text = L["Add Filter"] })
    GUI:SetSettingsFont(addFilterLinkBtn.Text, 9, "")
    addFilterLinkBtn:SetScript("OnClick", function()
        OpenFilterPicker({
            anchor = addFilterLinkBtn,
            isLinked = function(kind, key)
                if kind == "preset" then return fsel.presets[key] and true or false end
                return fsel.customs[key] and true or false
            end,
            onPick = function(kind, key)
                if kind == "preset" then fsel.presets[key] = true
                else fsel.customs[key] = true end
                StructuralFilterRefresh()
            end,
        })
    end)
    place(addFilterLinkBtn, 26, { indent = 8, stretch = true, gap = 6 })

    -- "Create Filter" → jump to the Filter Designer and pulse its New Filter
    -- button, for users who arrive here without a custom filter to link yet.
    local createFilterBtn = CreateFrame("Button", nil, host, "BackdropTemplate")
    createFilterBtn:SetHeight(22)
    GUI:StyleButton(createFilterBtn, { height = 22, text = L["Create Filter"] })
    GUI:SetSettingsFont(createFilterBtn.Text, 9, "")
    createFilterBtn:SetScript("OnClick", function()
        if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"] then
            GUI.SelectTab("auras_filterdesigner")
            -- Page content builds on first show (inside SelectTab), so the button
            -- reference exists by now. The add action is a row inside the Filter
            -- Designer's scrolling left list, so the page scrolls it into view and
            -- pulses it itself rather than handing back a bare widget.
            local fdPage = GUI.Pages["auras_filterdesigner"]
            if fdPage and fdPage._fdFocusNewFilter then
                fdPage._fdFocusNewFilter()
            end
        end
    end)
    place(createFilterBtn, 28, { indent = 8, stretch = true })
end

-- ── MEMBERS (spell groups) ──
local function BuildMembersSection(env, group)
    local place, host = env.place, env.host
    local capturedGroupID = group.id
    local isOtherGroups = IsOtherTab()

    if group.members and #group.members > 0 then
        for mi, member in ipairs(group.members) do
            local memberRow = CreateFrame("Frame", nil, host, "BackdropTemplate")
            memberRow:SetHeight(34)
            ApplyBackdrop(memberRow,
                {r = 0.11, g = 0.11, b = 0.11, a = 1},
                {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.3})

            -- Up/Down buttons for reordering (stacked vertically on left)
            local canMoveUp = mi > 1
            local canMoveDown = mi < #group.members
            local capturedMi = mi

            if canMoveUp then
                -- One arrow texture serves both directions via rotation.
                local upBtn = DF.GUI:CreateGlyphButton(memberRow, {
                    width = 20, height = 16, iconSize = 14,
                    texture  = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more",
                    rotation = math.rad(180),
                })
                upBtn:SetPoint("TOPLEFT", 2, -1)
                upBtn:SetScript("OnClick", function()
                    SwapGroupMembers(capturedGroupID, capturedMi, capturedMi - 1)
                    env.Rebuild()
                    RefreshPlacedIndicators()
                    -- Positions moved (member index feeds the grid) — re-arrange live frames.
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end)
            end
            if canMoveDown then
                local downBtn = DF.GUI:CreateGlyphButton(memberRow, {
                    width = 20, height = 16, iconSize = 14,
                    texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\expand_more",
                })
                downBtn:SetPoint("BOTTOMLEFT", 2, 1)
                downBtn:SetScript("OnClick", function()
                    SwapGroupMembers(capturedGroupID, capturedMi, capturedMi + 1)
                    env.Rebuild()
                    RefreshPlacedIndicators()
                    -- Positions moved (member index feeds the grid) — re-arrange live frames.
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end)
            end

            -- Spell icon (Other: nil spec — GetAuraIcon degrades to ad-hoc
            -- "#<id>" / SpellDB-by-name resolution)
            local memberSpec = not isOtherGroups and ResolveSpec() or nil
            local memberIconTex = GetAuraIcon(memberSpec, member.auraName)
            local mSpellIcon = memberRow:CreateTexture(nil, "ARTWORK")
            mSpellIcon:SetSize(22, 22)
            mSpellIcon:SetPoint("LEFT", 26, 0)
            if memberIconTex then
                mSpellIcon:SetTexture(memberIconTex)
                mSpellIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            else
                -- Color swatch fallback
                local auraInfo2 = nil
                local trackable2 = memberSpec and Adapter and Adapter:GetTrackableAuras(memberSpec)
                if trackable2 then
                    for _, ai in ipairs(trackable2) do
                        if ai.name == member.auraName then auraInfo2 = ai; break end
                    end
                end
                if auraInfo2 then
                    mSpellIcon:SetColorTexture(auraInfo2.color[1] * 0.5, auraInfo2.color[2] * 0.5, auraInfo2.color[3] * 0.5, 1)
                else
                    mSpellIcon:SetColorTexture(0.25, 0.25, 0.25, 1)
                end
            end

            -- Type badge (members live in the group's pool = the active tab's pool)
            local memberType = nil
            local memberAuraCfg = CurrentAuraPool()[member.auraName]
            if memberAuraCfg and memberAuraCfg.indicators then
                for _, ind in ipairs(memberAuraCfg.indicators) do
                    if ind.id == member.indicatorID then
                        memberType = ind.type
                        break
                    end
                end
            end
            local mBadgeColor = BADGE_COLORS[memberType or "icon"] or BADGE_COLORS.icon
            local mBadgeLabel = S.PLACED_TYPE_LABELS[memberType or "icon"] or "Icon"

            local mBadge = CreateFrame("Frame", nil, memberRow, "BackdropTemplate")
            mBadge:SetHeight(16)
            mBadge:SetPoint("LEFT", mSpellIcon, "RIGHT", 4, 0)
            ApplyBackdrop(mBadge,
                {r = mBadgeColor.r * 0.20, g = mBadgeColor.g * 0.20, b = mBadgeColor.b * 0.20, a = 1},
                {r = mBadgeColor.r * 0.45, g = mBadgeColor.g * 0.45, b = mBadgeColor.b * 0.45, a = 0.6})
            local mBadgeText = mBadge:CreateFontString(nil, "OVERLAY")
            GUI:SetSettingsFont(mBadgeText, 8, "OUTLINE")
            mBadgeText:SetPoint("CENTER", 0, 0)
            mBadgeText:SetText(mBadgeLabel)
            mBadgeText:SetTextColor(1, 1, 1)
            mBadge:SetWidth(max(mBadgeText:GetStringWidth() + 12, 32))

            -- Remove button (using close icon)
            -- Red at rest, brighter red on hover: an inline destructive remove.
            local remBtn = DF.GUI:CreateGlyphButton(memberRow, {
                size = 18, iconSize = 12,
                texture    = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close",
                color      = { 0.55, 0.30, 0.30 },
                hoverColor = { 1, 0.40, 0.40 },
            })
            remBtn:SetPoint("RIGHT", -4, 0)
            local capturedMember = member
            remBtn:SetScript("OnClick", function()
                RemoveGroupMember(capturedGroupID, capturedMember.auraName, capturedMember.indicatorID)
                -- Also delete the placed indicator itself
                RemoveIndicatorInstance(capturedMember.auraName, capturedMember.indicatorID)
                env.Rebuild()
                RefreshPlacedIndicators()
                RefreshPreviewEffects()
                -- Structural change: same full refresh as the effect-card ✕ /
                -- group delete (indicator removed).
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end)

            -- Customise button (navigates to Effects tab for this indicator)
            -- Accent-tinted action button: persistent accent fill + accent border
            -- + accent label at rest, accent-wash hover.
            local custBtn = CreateFrame("Button", nil, memberRow, "BackdropTemplate")
            custBtn:SetPoint("RIGHT", remBtn, "LEFT", -4, 0)
            GUI:StyleButton(custBtn, {
                width = 56, height = 18,
                text = L["Customise"],
                tinted = true,
                accent = GetThemeColor(),
            })
            local capturedAuraName = member.auraName
            local capturedIndID = member.indicatorID
            custBtn:SetScript("OnClick", function()
                -- Card keys embed the B1 pool prefix in the name segment
                -- ("placed:other:<name>#<id>" on Other)
                local cardKey = "placed:" .. PoolKeyPrefix() .. capturedAuraName .. "#" .. capturedIndID
                wipe(expandedCards)
                expandedCards[cardKey] = true
                S.activeTab = "effects"
                DF:AuraDesigner_RefreshPage()
            end)

            -- Aura name
            local mName = memberRow:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            mName:SetPoint("LEFT", mBadge, "RIGHT", 6, 0)
            mName:SetPoint("RIGHT", custBtn, "LEFT", -4, 0)
            mName:SetMaxLines(1)
            mName:SetText(MemberDisplayName(member.auraName))
            mName:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            place(memberRow, 38, { indent = 8, stretch = true })
        end
    else
        local noMem = CreateFrame("Frame", nil, host)
        noMem:SetHeight(16)
        local noMemText = noMem:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        noMemText:SetPoint("TOPLEFT", 4, 0)
        noMemText:SetText(L["No members yet"])
        noMemText:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.6)
        place(noMem, 20, { indent = 8, width = false })
    end

    -- "+ Add aura" button
    local addMemBtn = CreateFrame("Button", nil, host, "BackdropTemplate")
    addMemBtn:SetHeight(22)
    GUI:StyleButton(addMemBtn, { height = 22, primary = true, icon = { texture = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\add", size = 11 }, text = L["Add aura"] })
    GUI:SetSettingsFont(addMemBtn.Text, 9, "")
    addMemBtn:SetScript("OnClick", function()
        -- Shared spell picker, group context: searchable, class/category-filterable
        -- rows + add-by-ID, each row carrying Icon/Square buttons that create the
        -- indicator and enrol it in this group in one click.
        OpenGroupSpellPicker(capturedGroupID)
    end)
    place(addMemBtn, 28, { indent = 8, stretch = true, gap = 6 })
end

-- What a layout edit costs, per group kind. The two container-backed kinds are
-- NOT the same: a debuff group's categories feed a version-keyed record cache in
-- the factory, so every edit to one has to bump the layout version or the cache
-- answers from the shape the group used to have. A spell or filter group has no
-- such cache and does not pay for the bump.
local function GroupApply(kind)
    if kind == "debuff" then
        return function()
            RefreshPlacedIndicators()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end
        end
    end
    return function()
        RefreshPlacedIndicators()
        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
    end
end

-- ── PLACEMENT (every group kind) ──
-- ☠ THE CONTROLS BIND THE GROUP RECORD ITSELF, in both layouts. The popout row
-- above them takes a VIEW of the same record (P.GroupRecordView) so its modified
-- tick and its footer have something the defaults engine can answer for -- the
-- record is SavedVariables and cannot carry the adapter itself.
local function BuildGroupPlacement(env, group, kind)
    local place, host = env.place, env.host
    local apply = GroupApply(kind)
    place(GUI:CreateDropdown(host, L["Anchor"], OPTS.ANCHOR_OPTIONS, group, "anchor", apply), 54)
    place(GUI:CreateSlider(host, L["Offset X"], -150, 150, 1, group, "offsetX", apply, RefreshPlacedIndicators), 54)
    place(GUI:CreateSlider(host, L["Offset Y"], -150, 150, 1, group, "offsetY", apply, RefreshPlacedIndicators), 54)
end

-- ── GROWTH (every group kind) ──
-- `kind`: "members" | "filter" | "debuff". A member group stops after spacing;
-- the two container-backed kinds carry the uniform styling pair and the sort
-- block. `omitOthersOnly` is the row layout saying it draws that one itself, as
-- a control row -- one boolean does not need a panel, and a popout row's own
-- tick column already IS the checkbox.
local function BuildGroupGrowth(env, group, kind, omitOthersOnly)
    local place, host = env.place, env.host
    local apply = GroupApply(kind)

    -- Auto-migrate legacy single-direction values to new format
    local gd = group.growDirection or "RIGHT"
    if not gd:find("_") then
        local LEGACY_MAP = { RIGHT = "RIGHT_DOWN", LEFT = "LEFT_DOWN", UP = "UP_RIGHT", DOWN = "DOWN_RIGHT" }
        group.growDirection = LEGACY_MAP[gd] or "RIGHT_DOWN"
    end

    place(GUI:CreateGrowthControl(host, group, "growDirection", apply), 158)
    place(GUI:CreateSlider(host, L["Icons Per Row"], 1, 20, 1, group, "iconsPerRow", apply, RefreshPlacedIndicators), 54)
    place(GUI:CreateSlider(host, L["Spacing"], -5, 20, 1, group, "spacing", apply, RefreshPlacedIndicators), 54)
    if kind == "members" then return end

    -- Uniform per-group styling: one icon size + slot cap for every spell the
    -- group matches (no per-spell styling by design).
    place(GUI:CreateSlider(host, L["Icon Size"], 8, 64, 1, group, "iconSize", apply, RefreshPlacedIndicators), 54)
    -- Max Icons is STRUCTURAL (slot count is declared at container build) — the
    -- factory Rebuild path handles it (OOC-deferred).
    place(GUI:CreateSlider(host, L["Max Icons"], 1, 20, 1, group, "maxIcons", apply, RefreshPlacedIndicators), 54)

    -- ── SORT (Wave 2) ── per-group sort is TUNING: the factory re-applies it in
    -- place via ApplyTuning (OOC-immediate; self-defers in combat) — no rebuild.
    -- The fields are OPTIONAL on the group (othersOnly idiom): absent = the
    -- family default, read through a customGet so legacy groups display
    -- correctly without a write-on-open. Filter groups default to "DEFAULT"
    -- (Blizzard slot order, the pre-Wave-2 behaviour); debuff groups to "TIME"
    -- (soonest-to-expire first, the old hardcode).
    local famSort = (kind == "debuff") and "TIME" or "DEFAULT"
    local sortMineCb   -- forward capture: the dropdown greys it
    place(GUI:CreateDropdown(host, L["Sort Order"], OPTS.SORT_OPTIONS, nil, nil, function()
        apply()
        if sortMineCb then sortMineCb:SetEnabled(DF:SortOrderSupportsMineFirst(group.sortOrder or famSort)) end
    end, function() return group.sortOrder or famSort end,
       function(v) group.sortOrder = v end), 54)

    sortMineCb = GUI:CreateCheckbox(host, L["My Auras First"], group, "sortMineFirst", apply)
    sortMineCb.tooltip = L["Sort your own auras before other players'. Unavailable on Default (which already shows yours first) and on Order Applied (which keeps one fixed order)."]
    sortMineCb:SetEnabled(DF:SortOrderSupportsMineFirst(group.sortOrder or famSort))
    place(sortMineCb, 26, { indent = 8 })

    local sortRevCb = GUI:CreateCheckbox(host, L["Reverse Order"], group, "sortReverse", apply)
    sortRevCb.tooltip = L["Reverse the sort direction."]
    place(sortRevCb, 30, { indent = 8 })

    -- ── OTHERS ONLY (Other Buffs tab only — flat-store groups) ──
    -- Same idiom as the effect-card checkbox: the group's filter string
    -- ("HELPFUL|!PLAYER") binds at container build, so toggling is STRUCTURAL
    -- (folded into the fgroup struct sig → the factory Rebuilds), and the
    -- buff-row dedup union moves (an othersOnly group's spells keep their row icon).
    if kind == "filter" and IsOtherTab() and not omitOthersOnly then
        local ooCb = GUI:CreateCheckbox(host, L["Others Only"], group, "othersOnly", function()
            env.Rebuild()
            RefreshPlacedIndicators()
            DF:InvalidateAuraLayout()
            DF:UpdateAllFrames()
            if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                DF.AuraDesigner.Engine:ForceRefreshAllFrames()
            end
        end)
        ooCb.tooltip = L["Only show other players' casts of these buffs."]
        place(ooCb, 34, { indent = 8 })
    end
end

-- The ordered section list for one layout group. `omitOthersOnly` is the row
-- layout's flag -- see BuildGroupGrowth.
local function CollectLayoutGroupSections(group, omitOthersOnly)
    local isFilterGroup = (group.kind == "filter")
    local out = {}
    if isFilterGroup then
        out[#out + 1] = { header = L["Filters"], caption = L["LINKED FILTERS"],
                          build = function(env) BuildLinkedFiltersSection(env, group) end }
    else
        out[#out + 1] = { header = L["Members"], caption = L["MEMBERS"],
                          build = function(env) BuildMembersSection(env, group) end }
    end
    out[#out + 1] = { header = L["Placement"], caption = L["PLACEMENT"], gap = 10,
                      build = function(env) BuildGroupPlacement(env, group, isFilterGroup and "filter" or "members") end }
    out[#out + 1] = { header = L["Growth"], caption = L["GROWTH"], gap = 10,
                      build = function(env)
                          BuildGroupGrowth(env, group, isFilterGroup and "filter" or "members", omitOthersOnly)
                      end }
    return out
end
P.CollectLayoutGroupSections = CollectLayoutGroupSections

-- ============================================================
-- THE TWO KINDS OF LAYOUT GROUP -- ONE DECLARATION
-- ------------------------------------------------------------
-- Both thumbnails are a row of icons because both PRODUCE a row of icons; that
-- they differ only in what fills the row is the whole lesson. The colours carry
-- that difference -- a set picked by hand reads as mixed, one drawn from a single
-- filter reads as uniform.
--
-- ☠ A VERB, NOT A FILE-SCOPE TABLE. Every label is an L[...] lookup and a table
-- built at load freezes on whatever locale was live then -- the trap
-- DF:RegisterLocaleRefresh exists for, and the same reason Cards.lua's
-- AddFlowScopes is a function.
--
-- ⚠ ONE DECLARATION, TWO HOSTS: the split panel's choice-card BLOCK and the
-- popout layout's "+ Add Layout Group" PANEL. A second copy is how the three
-- duplicated FRAME_ITEMS lists in Cards.lua came about.
-- ============================================================
local function AddGroupOfKind(kind)
    local group = CreateLayoutGroup(nil, kind)
    if group then
        expandedGroups[GroupExpandKey(group.id)] = true
        S.SwitchTab("layout")
        RefreshPlacedIndicators()
    end
end

local function LayoutGroupCards()
    return {
        {
            title = L["Spell Group"],
            desc  = L["Spells you choose yourself"],
            art   = { kind = "iconRow", ghost = true,
                      colors = { {0.45,0.45,0.95}, {0.30,0.61,0.36}, {0.91,0.66,0.25} } },
            onClick = function() AddGroupOfKind(nil) end,
        },
        {
            title = L["Filter Group"],
            desc  = L["Follows one of your filters"],
            art   = { kind = "iconRow", ghost = true,
                      colors = { {0.30,0.61,0.36}, {0.30,0.61,0.36}, {0.30,0.61,0.36} } },
            onClick = function() AddGroupOfKind("filter") end,
            -- The filter card in this block, matching the Effects tab's "From a
            -- Filter". No filter argument: nothing is chosen until the group
            -- exists, so this opens the library rather than one filter. Once the
            -- group HAS links, each chip inside it carries its own pencil.
            action = {
                -- ☠ Extension included -- see the matching note on the Effects
                -- tab's card. A PNG path without ".png" fails silently.
                icon    = "filter_list.png",
                tooltip = {
                    title = L["Manage Filters"],
                    lines = { L["Build and edit your buff filters in the Filter Designer."] },
                },
                onClick = function()
                    if GUI.OpenFilterInDesigner then GUI:OpenFilterInDesigner() end
                end,
            },
        },
    }
end

-- ============================================================
-- THE ADD PANELS' PICTURES AND FOOTER
-- ------------------------------------------------------------
-- ☠ THE SAME TREATMENT THE ADD INDICATOR PANEL GOT (spec section 26 item 6).
-- Both kinds of group PRODUCE a row of icons on the frame, so both are drawn as
-- exactly that -- one of the player's own frames in miniature, with the row on
-- it -- rather than as a fat card with an abstract art blob beside two lines of
-- text. Two compact segments side by side where two 60px cards stood.
--
-- ⚠ ONE PICTURE, TWO FILLS. What separates the kinds is what fills the row: a
-- set picked by hand reads as mixed, one drawn from a single filter reads as
-- uniform. That was the choice cards' whole lesson and it survives the move.
-- ============================================================

-- The group defaults a fresh group is actually created with (Options.lua's
-- CreateLayoutGroup): TOPLEFT, four icons at 24px, 2px apart.
local GROUP_ICON_SIZE, GROUP_ICON_GAP, GROUP_ICON_MAX = 24, 2, 4

local function PaintIconRowOnThumb(pv, colors, ghost)
    local mock = pv and pv.mockFrame
    if not mock then return end
    local x = 0
    for i = 1, GROUP_ICON_MAX do
        local col = colors[i]
        if not col and not (ghost and i == #colors + 1) then break end
        local ring = mock:CreateTexture(nil, "OVERLAY", nil, 1)
        ring:SetColorTexture(0, 0, 0, 0.85)
        ring:SetSize(GROUP_ICON_SIZE + 2, GROUP_ICON_SIZE + 2)
        ring:SetPoint("TOPLEFT", mock, "TOPLEFT", x, 0)
        local sq = mock:CreateTexture(nil, "OVERLAY", nil, 2)
        sq:SetSize(GROUP_ICON_SIZE, GROUP_ICON_SIZE)
        sq:SetPoint("CENTER", ring, "CENTER", 0, 0)
        if col then
            sq:SetColorTexture(col[1], col[2], col[3], 1)
        else
            -- One unfilled slot: a group's row grows and shrinks with what is
            -- actually up, and an empty space says that faster than a sentence.
            sq:SetColorTexture(1, 1, 1, 0.10)
        end
        x = x + GROUP_ICON_SIZE + GROUP_ICON_GAP
    end
end

-- "Create Filter" -- jump to the Filter Designer and pulse its New Filter button.
-- ☠ ONE DEFINITION. The filter-links section inside a group card had the only
-- copy; the add panel's footer is the second consumer, and a second copy of a
-- 10-line navigation closure is how the three duplicated effect lists in
-- Cards.lua came about.
local function JumpToNewFilter()
    if not (GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"]) then return end
    GUI.SelectTab("auras_filterdesigner")
    -- Page content builds on first show (inside SelectTab), so the button
    -- reference exists by now. The add action is a row inside the Filter
    -- Designer's scrolling left list, so the page scrolls it into view and
    -- pulses it itself rather than handing back a bare widget.
    local fdPage = GUI.Pages["auras_filterdesigner"]
    if fdPage and fdPage._fdFocusNewFilter then fdPage._fdFocusNewFilter() end
end
P.JumpToNewFilter = JumpToNewFilter

-- The two filter verbs, as the panel's FOOTER rather than as a 24px glyph in one
-- card's corner. A button in a card corner is a button inside a button -- the
-- card's own note admits as much -- and it claimed a scope it did not have: it
-- sat on the Filter Group card while being about the filter library as a whole.
-- Down here it is about the panel, which is where it always belonged.
local function BuildFilterFooter(host, y, W)
    local sep = host:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.08)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 0, y)
    sep:SetPoint("TOPRIGHT", 0, y)
    y = y - 9

    local half = floor((W - 6) / 2)
    local createBtn = CreateFrame("Button", nil, host, "BackdropTemplate")
    createBtn:SetSize(half, 22)
    createBtn:SetPoint("TOPLEFT", 0, y)
    GUI:StyleButton(createBtn, { width = half, height = 22, text = L["Create Filter"] })
    createBtn:SetScript("OnClick", JumpToNewFilter)

    local manageBtn = CreateFrame("Button", nil, host, "BackdropTemplate")
    manageBtn:SetSize(W - half - 6, 22)
    manageBtn:SetPoint("TOPLEFT", half + 6, y)
    GUI:StyleButton(manageBtn, { width = W - half - 6, height = 22, text = L["Manage Filters"] })
    manageBtn:SetScript("OnClick", function()
        if GUI.OpenFilterInDesigner then GUI:OpenFilterInDesigner() end
    end)
    manageBtn:HookScript("OnEnter", function(self)
        GUI:ShowTooltip(self, {
            title = L["Manage Filters"],
            lines = { L["Build and edit your buff filters in the Filter Designer."] },
        })
    end)
    manageBtn:HookScript("OnLeave", function() GUI:HideTooltip() end)

    return y - 26
end

-- ============================================================
-- THE "+ ADD LAYOUT GROUP" PANEL
-- ------------------------------------------------------------
-- The popout layout's answer to the split panel's permanent card block, and the
-- same shape the Effects tab's "+ Add Indicator" row already has: one row on the
-- page, the choice behind it. The Effects tab got that in phase 5 and this tab
-- was simply missed.
--
-- ☠ NO CHOICE CARD *GROUP* IN HERE. GUI:CreateChoiceCardGroup wraps its cards in
-- a collapsible header keyed by its TITLE TEXT in the account-wide collapsed
-- store -- a second header inside a panel that already has one, and a profile key
-- for a fold nobody can usefully close.
--
-- ☠ AND NO FAT CARDS EITHER, since spec section 26 item 6: two SEGMENTS side by
-- side, each a picture of the row of icons the group produces, drawn on one of
-- the player's own frames. Two 60px cards stacked cost 122px of panel; two
-- segments cost 68.
--
-- ☠ AND THE HEIGHT IS REPORTED, NOT ASSUMED. The caller mounts this into a
-- popout pane whose slot is measured right after this returns, so a builder that
-- only sized itself would be handed whatever the pane happened to be -- which is
-- exactly how the Add Indicator panel shipped opening EMPTY (spec section 23).
-- Say the number; the caller remembers it.
--   host        the pane's container, already at the pane's width
--   opts.width  that width
--   opts.SetHeight(h)  report it
--   opts.Close()       shut the panel once something has been added
-- ============================================================
local GROUP_TILE_PIC_H, GROUP_TILE_GAP = 40, 6

S.BuildAddLayoutGroupPane = function(host, opts)
    opts = opts or {}
    local W = opts.width or 260
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab color

    local y = 0
    CreateNumberedHeading(host, 1, L["WHICH KIND OF GROUP?"], y, W)
    y = y - 20

    local defs = LayoutGroupCards()
    local tileW = floor((W - GROUP_TILE_GAP * (#defs - 1)) / #defs)
    local rowH = 0
    for i, def in ipairs(defs) do
        local onPick = def.onClick
        local colors, ghost = def.art.colors, def.art.ghost
        local tile = CreateFrameTile(host, {
            width = tileW, picHeight = GROUP_TILE_PIC_H,
            label = def.title, accent = gc,
            tooltip = { title = def.title, lines = { def.desc } },
            Paint = function(pv) PaintIconRowOnThumb(pv, colors, ghost) end,
            -- ⚠ CLOSED FIRST, THEN CREATED. Creating a group rebuilds the page,
            -- which retires the row this panel is docked to; shutting it on the
            -- way out is what the Add Indicator panel's own Finish() does, and for
            -- the same reason.
            --
            -- ⚠ AND ONE CLICK, NOT TWO. Section 26 says "two segments", and a
            -- segment IS the answer here: this panel asks ONE question, so a
            -- primary button under it would confirm a form that is already
            -- complete. The one primary button belongs to the panel with three
            -- sections.
            onClick = function()
                if opts.Close then opts.Close() end
                onPick()
            end,
        })
        tile:SetPoint("TOPLEFT", (i - 1) * (tileW + GROUP_TILE_GAP), y)
        rowH = max(rowH, tile.layoutHeight or 68)
    end
    y = y - (rowH + 10)

    -- The filter verbs, off the Filter Group card's corner and onto the panel.
    y = BuildFilterFooter(host, y, W)

    local h = max(-y + 2, 1)
    host:SetHeight(h)
    if opts.SetHeight then opts.SetHeight(h) end
    return h
end

-- ============================================================
-- THE LAYOUT GROUPS TAB'S HEAD AREA
-- ------------------------------------------------------------
-- The teaching sentence, the two choice cards and the "debuff rows live over
-- there" hint -- everything above the list. ONE definition, two hosts: the split
-- panel's own column and the row layout's band, exactly as S.BuildEffectsHeadArea
-- is for the Effects tab.
--
-- ⚠ opts.skipAddBlock: THE ROW LAYOUT HAS NO CARD BLOCK ON THE PAGE. Its two
-- cards live in the "+ Add Layout Group" row's panel above this area, exactly as
-- the Effects tab's three scope cards moved into "+ Add Indicator". The split
-- panel keeps the block: it is the one surface with the standing room for it.
-- ============================================================
S.BuildLayoutGroupsHeadArea = function(parent, yPos, opts)
    local skipAdd = opts and opts.skipAddBlock or false
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab color

    -- The column every object below is anchored 8px inside on both sides -- the
    -- host's own explicit width less those two insets. Derived rather than read
    -- off a child, for the reason S.BuildEffectsHeadArea spells out: a child's
    -- width is not resolved until the layout pass, and the choice cards need a
    -- number NOW to wrap their descriptions against.
    local hostW = parent:GetWidth() or 0
    local COL_W = (hostW > 40) and (hostW - 16) or nil

    -- ⚠ Read BEFORE any chrome is built. An EMPTY tab explains the two kinds
    -- with choice cards INSTEAD of the compact add buttons and the heading, so
    -- what gets created depends on the count. A card runs ~2.5x a button's
    -- height, which this ~260px column can only spare while there is no list
    -- underneath it -- hence cards or buttons, never both.
    local hasGroups = #CurrentLayoutGroups() > 0

    -- Teaching prose, first visit only. The CARDS below are pinned permanently --
    -- they are the create action, so they have to be -- but this sentence is read
    -- once and would otherwise cost column height on every visit afterwards.
    if not hasGroups then
        local intro = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        intro:SetPoint("TOPLEFT", 8, yPos)
        intro:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        intro:SetJustifyH("LEFT")
        intro:SetWordWrap(true)
        intro:SetText(L["A row of icons that arranges itself as auras come and go."])
        intro:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        yPos = yPos - 34
    end

    -- The two kinds, always. These REPLACE the old "+ Create Group" / "+ Filter
    -- Group" pair rather than sitting above it -- a card is itself the create
    -- action, and running both would be two paths to the same thing.
    if not skipAdd then
        local addBlock = GUI:CreateChoiceCardGroup(parent, {
            title    = L["ADD A LAYOUT GROUP"],
            accent   = gc,
            width    = COL_W,
            onToggle = function() S.SwitchTab("layout") end,
            cards    = LayoutGroupCards(),
        })
        addBlock:SetPoint("TOPLEFT", 8, yPos)
        addBlock:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        yPos = yPos - (addBlock.layoutHeight + 10)
    end

    if not hasGroups then
        -- No third card for debuff rows. They are a separate store reached from
        -- the Debuffs tab, so a card here could not create one -- pointing at
        -- where they live is the honest version.
        local hint = parent:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(hint, 8, "")
        hint:SetPoint("TOPLEFT", 8, yPos - 4)
        hint:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
        hint:SetText(L["Debuff rows are set up on the Debuffs tab."])
        hint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b, 0.8)
        yPos = yPos - 22
    end

    return yPos
end

-- The collapsed header's own line: what a group is, at a glance. ONE definition,
-- two hosts -- the card puts it in the header fontstring, the row layout splits
-- it across the section title and its tag.
S.LayoutGroupSummary = function(group)
    if group.kind == "filter" then
        local linkCount = 0
        local fsel = group.filterSelection
        if fsel then
            for _ in pairs(fsel.presets or {}) do linkCount = linkCount + 1 end
            for _ in pairs(fsel.customs or {}) do linkCount = linkCount + 1 end
        end
        local info = linkCount .. (linkCount ~= 1 and L[" filters"] or L[" filter"])
        -- Collapsed-state Others Only suffix — mirror the effect-card header
        if IsOtherTab() and group.othersOnly then
            info = info .. "  -  " .. L["Others Only"]
        end
        return info
    end
    local memberCount = group.members and #group.members or 0
    return memberCount .. (memberCount ~= 1 and L[" indicators"] or L[" indicator"])
end

S.BuildLayoutGroupsTab = function()
    if not S.tabContentFrame then return end
    local parent = S.tabContentFrame
    local yPos = S.BuildLayoutGroupsHeadArea(parent, -10)
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab color

    local groups = CurrentLayoutGroups()

    if #groups > 0 then
        -- ── LAYOUT GROUPS heading — mirrors the Effects tab's ACTIVE INDICATORS
        -- caption and the Text Designer's group caption so every list tab has
        -- one. Only with a list under it: a heading over nothing reads as a
        -- section that failed to load. ──
        local groupsHeader = parent:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(groupsHeader, 9, "")
        groupsHeader:SetPoint("TOPLEFT", 8, yPos)
        groupsHeader:SetText(L["LAYOUT GROUPS"])
        groupsHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        yPos = yPos - 16

        -- Card stack: the appearance sections in an expanded card can change
        -- height in place, which moves every card below. The stack owns the
        -- re-anchor pass so those edits don't have to rebuild the tab.
        local stack = CreateCardStack(parent, yPos)

        -- Render group cards (expansion keys are pool-scoped — raw id on My
        -- Buffs, "othergroup:<id>" on Other; the id counters overlap)
        for _, group in ipairs(groups) do
            local expandKey = GroupExpandKey(group.id)
            local isExpanded = expandedGroups[expandKey] or false

            -- ── CARD + HEADER ──
            local card, header, chevron = CreateCardShell(parent, {
                yPos          = yPos,
                expanded      = isExpanded,
                borderColor   = {r = gc.r * 0.35, g = gc.g * 0.35, b = gc.b * 0.35, a = 0.5},
                chevronColor  = gc,
            })
            stack:Add(card)

            -- Group name
            local nameText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            nameText:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
            nameText:SetPoint("RIGHT", header, "RIGHT", -60, 0)
            nameText:SetMaxLines(1)
            local isFilterGroup = (group.kind == "filter")
            nameText:SetText(group.name .. "  -  " .. S.LayoutGroupSummary(group))
            nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            -- Delete button
            local capturedGroupID = group.id
            local delBtn = GUI:CreateCloseButton(header, {
                size = 22,
                onClick = function()
                    DeleteLayoutGroup(capturedGroupID)
                    S.SwitchTab("layout")
                    RefreshPlacedIndicators()
                    -- Deleting a group deletes its member indicators — same
                    -- structural refresh as the effect-card delete / eye toggle.
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end
                end,
            })
            delBtn:SetPoint("RIGHT", -4, 0)
            delBtn:SetFrameLevel(header:GetFrameLevel() + 2)

            -- Eye icon (visibility toggle) — filter groups only; same asset + toggle
            -- idiom as the effect-card eye (A3). enabled == false is hidden; nil/true
            -- = shown. Toggling is STRUCTURAL: the factory tears down / stands up the
            -- group container and the buff-row dedup union changes.
            if isFilterGroup then
                local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
                local eyeBtn = DF.GUI:CreateGlyphButton(header, { size = 18 })
                eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
                local function shown() return group.enabled ~= false end
                -- SetGlyph makes the state colour the new REST colour, so OnLeave
                -- restores the state; hover is suppressed while hidden.
                local function updateEyeIcon()
                    if shown() then
                        eyeBtn:SetGlyph(mediaPath .. "visibility", { 0.95, 0.95, 0.95 })
                    else
                        eyeBtn:SetGlyph(mediaPath .. "visibility_off", { 0.45, 0.45, 0.45 })
                    end
                    eyeBtn:SetGlyphHover(shown())
                end
                updateEyeIcon()
                eyeBtn:RegisterForClicks("LeftButtonUp")
                eyeBtn:SetFrameLevel(header:GetFrameLevel() + 2)
                eyeBtn:SetScript("OnClick", function()
                    group.enabled = (group.enabled == false) and true or false
                    updateEyeIcon()
                    S.SwitchTab("layout")
                    RefreshPlacedIndicators()
                    DF:InvalidateAuraLayout()
                    DF:UpdateAllFrames()
                    if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                    end
                end)
                if not shown() then
                    nameText:SetAlpha(0.5)
                end
            end

            -- Header click → toggle expansion
            header:SetScript("OnClick", function()
                expandedGroups[expandKey] = not expandedGroups[expandKey]
                S.SwitchTab("layout")
            end)
            header:SetScript("OnEnter", function(self)
                self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
            end)
            header:SetScript("OnLeave", function(self)
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            end)

            local totalCardH = 30
            local cardHeaderH = totalCardH   -- captured before the body is folded in

            -- ── BODY (when expanded) ──
            if isExpanded then
                local body = CreateFrame("Frame", nil, card, "BackdropTemplate")
                body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
                body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
                ApplyBackdrop(body, {r = 0.09, g = 0.09, b = 0.09, a = 1},
                    {r = gc.r * 0.20, g = gc.g * 0.20, b = gc.b * 0.20, a = 0.3})

                local by = -10
                local bodyWidth = (S.tabContentFrame and S.tabContentFrame:GetWidth() or 260) - 24
                if bodyWidth < 100 then bodyWidth = 240 end

                -- Group Name (editable)
                local nameLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(nameLabel, 8, "")
                nameLabel:SetPoint("TOPLEFT", 8, by)
                nameLabel:SetText(L["GROUP NAME"])
                nameLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 16

                local nameEdit = CreateFrame("EditBox", nil, body, "BackdropTemplate")
                nameEdit:SetHeight(22)
                nameEdit:SetPoint("TOPLEFT", 8, by)
                nameEdit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                nameEdit:SetAutoFocus(false)
                nameEdit:SetText(group.name)
                nameEdit:SetMaxLetters(30)
                GUI:StyleEditBox(nameEdit, {})
                nameEdit:SetScript("OnEnterPressed", function(self)
                    local val = self:GetText()
                    if val and val ~= "" then
                        group.name = val
                    end
                    self:ClearFocus()
                    S.SwitchTab("layout")
                end)
                nameEdit:SetScript("OnEscapePressed", function(self)
                    self:SetText(group.name)
                    self:ClearFocus()
                end)
                by = by - 32

                -- Members / Linked Filters, then Placement, then Growth -- the
                -- SAME list the row layout mounts, run down the card's cursor.
                by = RunCardSections(body, bodyWidth, by, CollectLayoutGroupSections(group))

                if isFilterGroup then
                    -- ── APPEARANCE (collapsible — the effect-card section idiom) ──
                    by = by - 10
                    by = AddGroupAppearanceSection(body, group, bodyWidth, by, expandKey)

                    -- The appearance sections reflow in place; when they do, the
                    -- body and card must re-size and the cards below must slide.
                    -- `newBy` is the section stack's new tail, i.e. what
                    -- AddGroupAppearanceSection would have returned this time —
                    -- so the body height formula is the build-time one verbatim.
                    body.dfAD_ReflowCard = function(newBy)
                        local h = -newBy + 12
                        body:SetHeight(h)
                        card:SetHeight(cardHeaderH + h)
                        stack:Reflow()
                    end
                end

                local bodyH = -by + 12
                body:SetHeight(bodyH)
                totalCardH = totalCardH + bodyH
            end

            card:SetHeight(totalCardH)
            yPos = yPos - totalCardH - 5
        end
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ============================================================
-- DEBUFFS TAB — DEBUFF CATEGORY GROUPS (C2)
-- Each card owns a SELECTION of the native 12.1 debuff categories (checkbox
-- picker reusing the Aura Filters debuff column's controls) plus the shared
-- filter-group layout controls. Groups are spec-independent
-- (adDB.debuffGroups; lazily created on the first add — visiting the tab
-- writes nothing). Categories claimed by an enabled group are dropped from
-- the main debuff bar (C1 row-claim dedup), so EVERY selection / eye /
-- delete / add edit runs the FULL structural chain: InvalidateAuraLayout
-- bumps the version the row's claim fold AND the factory's dgroup record
-- cache re-resolve on; UpdateAllFrames + ForceRefreshAllFrames re-drive the
-- live frames and AD containers. Card keys are "dgroup:<id>" in
-- expandedGroups — layout-group cards key by raw numeric id, so the string
-- prefix can never collide with them (the two id counters overlap).
-- ============================================================

-- The category picker rows: the Aura Filters debuff column's exact L keys +
-- tooltips, mapped onto group.selection's keys. Built PER CALL rather than at
-- file scope so a runtime locale overlay is picked up (a file-scope L table
-- freezes enUS -- see DF:RegisterLocaleRefresh).
local function DebuffCategoryDefs()
    return {
        { key = "boss",         label = L["Boss Debuffs"],        tooltip = L["Debuffs applied by dungeon and raid bosses."] },
        { key = "role",         label = L["Role Debuffs"],        tooltip = L["Debuffs Blizzard flags as important for your role."] },
        { key = "priority",     label = L["Priority Debuffs"],    tooltip = L["Debuffs Blizzard flags as high priority."] },
        { key = "crowdControl", label = L["Crowd Control"],       tooltip = L["CC effects like stuns, roots, and incapacitates."] },
        { key = "raid",         label = L["Raid Debuffs"],        tooltip = L["Other debuffs Blizzard flags for raid frames."] },
        { key = "dispellable",  label = L["Dispellable Debuffs"], tooltip = L["Debuffs that can be dispelled. Use the dropdown below to choose which dispels count."] },
    }
end
P.DebuffCategoryDefs = DebuffCategoryDefs

-- Repair a missing selection table (hand-edited data). All categories start
-- FALSE so an unconfigured group renders — and claims — nothing until the user
-- picks; modifier defaults mirror CreateDebuffGroup.
local function EnsureDebuffSelection(group)
    local sel = group.selection
    if not sel then
        sel = { dispellableMode = "PLAYER", hideLongMinutes = 5, keepImportant = true }
        group.selection = sel
    end
    return sel
end
P.EnsureDebuffSelection = EnsureDebuffSelection

-- The collapsed header's own line: the selected category names (the A5 collapsed
-- treatment, categories instead of a link count).
S.DebuffGroupSummary = function(group)
    local selectedNames = {}
    local selRead = group.selection
    if selRead then
        for _, def in ipairs(DebuffCategoryDefs()) do
            if selRead[def.key] then tinsert(selectedNames, def.label) end
        end
    end
    if #selectedNames > 0 then return table.concat(selectedNames, ", ") end
    return L["No categories selected"]
end

-- ── CATEGORIES (debuff groups) ──
-- Checkbox list writing group.selection.* — every toggle is structural (records
-- move AND the claims union moves).
--
-- ☠ env.Redraw, NOT env.Rebuild. In the card this is the tab rebuild it always
-- was; in a PANE a rebuild would retire the tick the user just clicked, so the
-- panel re-flows itself and the group header is repainted by hand.
local function BuildDebuffCategories(env, group)
    local place, host = env.place, env.host
    local sel = EnsureDebuffSelection(group)

    local function StructuralDebuffGroupRefresh()
        env.Redraw()
        env.Header()
        RefreshPlacedIndicators()
        DF:InvalidateAuraLayout()
        DF:UpdateAllFrames()
        if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
            DF.AuraDesigner.Engine:ForceRefreshAllFrames()
        end
    end
    -- The same structural chain WITHOUT the redraw — slider/dropdown-safe (a
    -- rebuild from inside a slider callback destroys the widget mid-interaction).
    local function LayoutDebuffGroupRefresh()
        RefreshPlacedIndicators()
        DF:InvalidateAuraLayout()
        DF:UpdateAllFrames()
        if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
            DF.AuraDesigner.Engine:ForceRefreshAllFrames()
        end
    end

    for _, def in ipairs(DebuffCategoryDefs()) do
        local cb = GUI:CreateCheckbox(host, def.label, sel, def.key, StructuralDebuffGroupRefresh)
        cb.tooltip = def.tooltip
        place(cb, 26, { indent = 8, width = false })

        if def.key == "dispellable" then
            -- Mode dropdown, indented under Dispellable Debuffs (the Aura Filters
            -- column's control, group-scoped; back to TWO entries 2026-08-22 --
            -- the PTR-5-era third mode "Any Dispel Type" was collapsed into All
            -- Dispellable once both rode the DISPELLABLE token and became one
            -- query wearing two rows).
            --
            -- ★ Self-heal for a stored "ANY": AD groups have no startup migration
            -- walk, and a shared template can re-introduce the value at any time.
            -- This is the one surface where it would show (as a blank dropdown);
            -- the engine already treats ANY as ALL, so this write changes
            -- presentation only, never behaviour.
            if sel.dispellableMode == "ANY" then
                sel.dispellableMode = "ALL"
            end
            local modeDrop = GUI:CreateDropdown(host, L["Mode"], {
                PLAYER = L["Dispellable By Me"],
                ALL = L["All Dispellable"],
                _order = { "PLAYER", "ALL" },
            }, sel, "dispellableMode", StructuralDebuffGroupRefresh)
            modeDrop.tooltip = L["Dispellable By Me: only debuffs you can dispel. All Dispellable: any debuff that can be dispelled."]
            modeDrop.disableOn = function() return not sel.dispellable end
            modeDrop:SetEnabled(not not sel.dispellable)
            place(modeDrop, 54, { indent = 24, width = env.bodyWidth and (env.bodyWidth - 30) or nil })
        end
    end

    local hideLongCb = GUI:CreateCheckbox(host, L["Hide Long Debuffs"], sel, "hideLong", StructuralDebuffGroupRefresh)
    hideLongCb.tooltip = L["Hide debuffs whose total duration is longer than the threshold. Debuffs with no duration (permanent auras) are also hidden while this is on."]
    place(hideLongCb, 26, { indent = 8, width = false, gap = 4 })

    local minSlider = GUI:CreateSlider(host, L["Hide Longer Than (minutes)"], 1, 30, 1,
        sel, "hideLongMinutes", LayoutDebuffGroupRefresh)
    minSlider.disableOn = function() return not sel.hideLong end
    minSlider:SetEnabled(not not sel.hideLong)
    place(minSlider, 54, { indent = 8, width = env.bodyWidth and (env.bodyWidth - 10) or nil })

    -- Keep-important, indented under Hide Long (Aura Filters idiom)
    local keepCb = GUI:CreateCheckbox(host, L["Keep important debuffs"], sel, "keepImportant", StructuralDebuffGroupRefresh)
    keepCb.tooltip = L["Boss, Role, and Priority debuffs stay visible even when their duration is over the threshold."]
    keepCb.disableOn = function() return not sel.hideLong end
    keepCb:SetEnabled(not not sel.hideLong)
    place(keepCb, 30, { indent = 24, width = false })
end

-- The ordered section list for one debuff category group.
local function CollectDebuffGroupSections(group)
    local out = {}
    out[#out + 1] = { header = L["Categories"], caption = L["CATEGORIES"],
                      build = function(env) BuildDebuffCategories(env, group) end }
    out[#out + 1] = { header = L["Placement"], caption = L["PLACEMENT"], gap = 10,
                      build = function(env) BuildGroupPlacement(env, group) end }
    out[#out + 1] = { header = L["Growth"], caption = L["GROWTH"], gap = 10,
                      build = function(env) BuildGroupGrowth(env, group, "debuff") end }
    return out
end
P.CollectDebuffGroupSections = CollectDebuffGroupSections

-- ============================================================
-- THE ONE KIND OF DEBUFF GROUP -- ONE DECLARATION
-- ------------------------------------------------------------
-- Red icons because the row it builds is made of debuffs, and the mixed palette
-- next door means "spells you picked"; keeping the two distinguishable matters
-- more than either thumbnail looking good in isolation.
--
-- ⚠ ONE CARD, NOT TWO, AND THAT IS WHY THIS IS A SEPARATE LIST. The Debuffs pool
-- is served by a DIFFERENT builder from My Buffs / Any Buff (spec section 16),
-- and it makes exactly one kind of thing. A single list with a `kinds` flag would
-- be one list pretending to be two.
--
-- ☠ A VERB, NOT A FILE-SCOPE TABLE -- see LayoutGroupCards above.
-- ============================================================
local function AddDebuffGroup()
    local group = CreateDebuffGroup()
    if group then
        expandedGroups["dgroup:" .. group.id] = true
        -- A new group claims Boss + Role by default, so the main debuff bar drops
        -- them immediately: full structural chain, not just a tab rebuild.
        S.SwitchTab("layout")
        RefreshPlacedIndicators()
        DF:InvalidateAuraLayout()
        DF:UpdateAllFrames()
        if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
            DF.AuraDesigner.Engine:ForceRefreshAllFrames()
        end
    end
end

local function DebuffGroupCards()
    return {
        {
            title = L["Debuff Group"],
            desc  = L["Blizzard's debuff categories"],
            art   = { kind = "iconRow", ghost = true,
                      colors = { {0.66,0.27,0.25}, {0.66,0.27,0.25}, {0.66,0.27,0.25} } },
            onClick = AddDebuffGroup,
        },
    }
end

-- ============================================================
-- THE "+ ADD DEBUFF GROUP" PANEL
-- ------------------------------------------------------------
-- The Debuffs pool's half of section 23.2, built to the same shape as
-- S.BuildAddLayoutGroupPane and for the same reason -- the tab is ONE tab, and a
-- pool that opened a panel next to a pool that fired on click would be two
-- different controls wearing one label.
--
-- ⚠ ONE CARD BEHIND A PANEL IS STILL WORTH IT, and this is the one place to
-- argue with that. The card is not just a button: it carries the thumbnail and
-- "Blizzard's debuff categories", which is the only sentence in the addon that
-- says what this kind of group IS. A bare row would be one click cheaper and
-- would drop that sentence on the floor.
-- ============================================================
S.BuildAddDebuffGroupPane = function(host, opts)
    opts = opts or {}
    local W = opts.width or 260
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab accent

    local y = 0
    CreateNumberedHeading(host, 1, L["WHICH KIND OF GROUP?"], y, W)
    y = y - 20

    -- ⚠ NO FILTER FOOTER HERE. Debuff groups are Blizzard's categories, not the
    -- addon's filters, so a Create/Manage Filters pair would point at a library
    -- this panel cannot use.
    local defs = DebuffGroupCards()
    local tileW = floor((W - GROUP_TILE_GAP * (#defs - 1)) / #defs)
    local rowH = 0
    for i, def in ipairs(defs) do
        local onPick = def.onClick
        local colors, ghost = def.art.colors, def.art.ghost
        local tile = CreateFrameTile(host, {
            width = tileW, picHeight = GROUP_TILE_PIC_H,
            label = def.title, accent = gc,
            tooltip = { title = def.title, lines = { def.desc } },
            Paint = function(pv) PaintIconRowOnThumb(pv, colors, ghost) end,
            onClick = function()
                if opts.Close then opts.Close() end
                onPick()
            end,
        })
        tile:SetPoint("TOPLEFT", (i - 1) * (tileW + GROUP_TILE_GAP), y)
        rowH = max(rowH, tile.layoutHeight or 68)
    end
    y = y - (rowH + 2)

    local h = max(-y + 2, 1)
    host:SetHeight(h)
    if opts.SetHeight then opts.SetHeight(h) end
    return h
end

-- ============================================================
-- THE DEBUFFS TAB'S HEAD AREA
-- ------------------------------------------------------------
-- The teaching sentence, the one choice card and the dedup explainer --
-- everything above the list. ONE definition, two hosts, exactly as the Layout
-- Groups tab's is -- opts.skipAddBlock included, for the same reason.
-- ============================================================
S.BuildDebuffGroupsHeadArea = function(parent, yPos, opts)
    local skipAdd = opts and opts.skipAddBlock or false
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab accent

    -- The column every object below is anchored 8px inside on both sides -- the
    -- host's own explicit width less those two insets. Derived rather than read
    -- off a child, for the reason S.BuildEffectsHeadArea spells out: a child's
    -- width is not resolved until the layout pass, and the choice cards need a
    -- number NOW to wrap their descriptions against.
    local hostW = parent:GetWidth() or 0
    local COL_W = (hostW > 40) and (hostW - 16) or nil

    -- READ path: visiting the tab never creates adDB.debuffGroups.
    -- Read first for the same reason as the Layout Groups tab: an empty tab
    -- swaps the compact button, the dedup explainer and the heading for a
    -- single choice card.
    local hasGroups = #DebuffGroupsRead() > 0

    -- Teaching prose, first visit only -- see the Layout Groups tab.
    if not hasGroups then
        local intro = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        intro:SetPoint("TOPLEFT", 8, yPos)
        intro:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        intro:SetJustifyH("LEFT")
        intro:SetWordWrap(true)
        intro:SetText(L["A row of icons that arranges itself as auras come and go."])
        intro:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        yPos = yPos - 34
    end

    -- The one kind this tab makes, always -- replaces "+ Debuff Group" outright.
    -- The debuffGroups array is born lazily on the first add.
    if not skipAdd then
        local addBlock = GUI:CreateChoiceCardGroup(parent, {
            title    = L["ADD A DEBUFF GROUP"],
            accent   = gc,
            width    = COL_W,
            onToggle = function() S.SwitchTab("layout") end,
            cards    = DebuffGroupCards(),
        })
        addBlock:SetPoint("TOPLEFT", 8, yPos)
        addBlock:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        yPos = yPos - (addBlock.layoutHeight + 10)
    end

    if hasGroups then
        -- Dedup explainer (§11.1 mock): how the row-claim handoff behaves.
        -- Withheld while the list is empty -- with no groups nothing is being
        -- hidden yet, so it describes a behaviour the player cannot observe.
        local dedupHint = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        dedupHint:SetPoint("TOPLEFT", 8, yPos)
        dedupHint:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        dedupHint:SetJustifyH("LEFT")
        dedupHint:SetWordWrap(true)
        dedupHint:SetText(L["Categories shown here are hidden from the main debuff bar automatically."])
        dedupHint:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        yPos = yPos - 30

        -- ── CROSS-GROUP DEDUP TOGGLE (2026-08-29) ──
        -- Its OWN switch, deliberately independent of the row's Hide Duplicate
        -- Debuffs (Krathe: "you might want to dedupe one and not the other").
        -- Preset-level (adDB.debuffGroupDedup) because the groups it governs are;
        -- default ON — nil must READ as checked, hence customGet/customSet rather
        -- than a raw key bind (a raw bind renders an untouched profile unchecked
        -- while the factory treats nil as on). The factory's dgroup sync consumes
        -- it via `adDB.debuffGroupDedup ~= false`; a flip moves the claims fold,
        -- so it takes the full structural chain — checkbox-safe (no slider
        -- mid-interaction hazard, see LayoutDebuffGroupRefresh's note).
        --
        -- ☠ IT LIVES IN THE HEAD AREA, NOT IN BuildDebuffGroupsTab. The upstream
        -- patch put it in the card layout's tab builder, which the popout layout
        -- never calls (Rows.lua builds its own list and only borrows this head
        -- area) — the toggle would have existed in one of the two layouts. This
        -- function is the piece both hosts share, so one definition serves both,
        -- which is the whole reason it was lifted out.
        local adDBForDedup = GetAuraDesignerDB()
        if adDBForDedup then
            -- Same structural chain both layouts already spell for the eye and the
            -- delete; defined here because neither host's copy is in scope.
            local function StructuralDedupRefresh()
                S.SwitchTab("layout")
                RefreshPlacedIndicators()
                DF:InvalidateAuraLayout()
                DF:UpdateAllFrames()
                local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
            end
            local dgDedup = GUI:CreateCheckbox(parent, L["Hide Duplicates Between Groups"], nil, nil,
                StructuralDedupRefresh,
                function() return adDBForDedup.debuffGroupDedup ~= false end,
                function(v) adDBForDedup.debuffGroupDedup = v and true or false end)
            dgDedup.tooltip = L["A debuff matching several groups shows only in the first matching group in the list, so it never appears twice. Turn off to let every matching group show it."]
            dgDedup:SetPoint("TOPLEFT", 8, yPos)
            yPos = yPos - 28
        end
    end

    return yPos
end

S.BuildDebuffGroupsTab = function()
    if not S.tabContentFrame then return end
    local parent = S.tabContentFrame
    local yPos = S.BuildDebuffGroupsHeadArea(parent, -10)
    local gc = { r = 0.91, g = 0.66, b = 0.25 }  -- Layout Groups tab accent

    -- FULL structural refresh incl. tab rebuild — the eye, the delete and the
    -- add: the claims union moves AND the card summary / grey states must
    -- rebuild.
    local function StructuralDebuffGroupRefresh()
        S.SwitchTab("layout")
        RefreshPlacedIndicators()
        DF:InvalidateAuraLayout()
        DF:UpdateAllFrames()
        if DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
            DF.AuraDesigner.Engine:ForceRefreshAllFrames()
        end
    end

    local groups = DebuffGroupsRead()

    if #groups > 0 then
        -- ── DEBUFF GROUPS heading — mirrors the Layout Groups tab's caption. ──
        local groupsHeader = parent:CreateFontString(nil, "OVERLAY")
        GUI:SetSettingsFont(groupsHeader, 9, "")
        groupsHeader:SetPoint("TOPLEFT", 8, yPos)
        groupsHeader:SetText(L["DEBUFF GROUPS"])
        groupsHeader:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
        yPos = yPos - 16

        -- Card stack — same in-place reflow seam as the Layout Groups tab.
        local stack = CreateCardStack(parent, yPos)

        for _, group in ipairs(groups) do
            local cardKey = "dgroup:" .. group.id
            local isExpanded = expandedGroups[cardKey] or false
            local capturedGroupID = group.id

            -- ── CARD + HEADER ──
            local card, header, chevron = CreateCardShell(parent, {
                yPos          = yPos,
                expanded      = isExpanded,
                borderColor   = {r = gc.r * 0.35, g = gc.g * 0.35, b = gc.b * 0.35, a = 0.5},
                chevronColor  = gc,
            })
            stack:Add(card)

            -- Group name + collapsed summary
            local nameText = header:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            nameText:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
            nameText:SetPoint("RIGHT", header, "RIGHT", -60, 0)
            nameText:SetMaxLines(1)
            nameText:SetText(group.name .. "  -  " .. S.DebuffGroupSummary(group))
            nameText:SetTextColor(C_TEXT.r, C_TEXT.g, C_TEXT.b)

            -- Delete button — full structural chain: the group's claimed
            -- categories return to the main debuff bar.
            local delBtn = GUI:CreateCloseButton(header, {
                size = 22,
                onClick = function()
                    DeleteDebuffGroup(capturedGroupID)
                    StructuralDebuffGroupRefresh()
                end,
            })
            delBtn:SetPoint("RIGHT", -4, 0)
            delBtn:SetFrameLevel(header:GetFrameLevel() + 2)

            -- Eye icon (visibility toggle) — same asset + idiom as the filter
            -- group eye (A3/A5). Toggling is STRUCTURAL: the factory tears
            -- down / stands up the container and the claims union moves.
            local mediaPath = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
            local eyeBtn = DF.GUI:CreateGlyphButton(header, { size = 18 })
            eyeBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
            local function shown() return group.enabled ~= false end
            -- SetGlyph makes the state colour the new REST colour, so OnLeave
            -- restores the state; hover is suppressed while hidden.
            local function updateEyeIcon()
                if shown() then
                    eyeBtn:SetGlyph(mediaPath .. "visibility", { 0.95, 0.95, 0.95 })
                else
                    eyeBtn:SetGlyph(mediaPath .. "visibility_off", { 0.45, 0.45, 0.45 })
                end
                eyeBtn:SetGlyphHover(shown())
            end
            updateEyeIcon()
            eyeBtn:RegisterForClicks("LeftButtonUp")
            eyeBtn:SetFrameLevel(header:GetFrameLevel() + 2)
            eyeBtn:SetScript("OnClick", function()
                group.enabled = (group.enabled == false) and true or false
                updateEyeIcon()
                StructuralDebuffGroupRefresh()
            end)
            if not shown() then
                nameText:SetAlpha(0.5)
            end

            -- Header click → toggle expansion
            header:SetScript("OnClick", function()
                expandedGroups[cardKey] = not expandedGroups[cardKey]
                S.SwitchTab("layout")
            end)
            header:SetScript("OnEnter", function(self)
                self:SetBackdropColor(C_HOVER.r, C_HOVER.g, C_HOVER.b, 1)
            end)
            header:SetScript("OnLeave", function(self)
                self:SetBackdropColor(C_ELEMENT.r, C_ELEMENT.g, C_ELEMENT.b, 1)
            end)

            local totalCardH = 30
            local cardHeaderH = totalCardH   -- captured before the body is folded in

            -- ── BODY (when expanded) ──
            if isExpanded then
                local body = CreateFrame("Frame", nil, card, "BackdropTemplate")
                body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
                body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
                ApplyBackdrop(body, {r = 0.09, g = 0.09, b = 0.09, a = 1},
                    {r = gc.r * 0.20, g = gc.g * 0.20, b = gc.b * 0.20, a = 0.3})

                local by = -10
                local bodyWidth = (S.tabContentFrame and S.tabContentFrame:GetWidth() or 260) - 24
                if bodyWidth < 100 then bodyWidth = 240 end

                EnsureDebuffSelection(group)

                -- Group Name (editable)
                local nameLabel = body:CreateFontString(nil, "OVERLAY")
                GUI:SetSettingsFont(nameLabel, 8, "")
                nameLabel:SetPoint("TOPLEFT", 8, by)
                nameLabel:SetText(L["GROUP NAME"])
                nameLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
                by = by - 16

                local nameEdit = CreateFrame("EditBox", nil, body, "BackdropTemplate")
                nameEdit:SetHeight(22)
                nameEdit:SetPoint("TOPLEFT", 8, by)
                nameEdit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
                nameEdit:SetAutoFocus(false)
                nameEdit:SetText(group.name)
                nameEdit:SetMaxLetters(30)
                GUI:StyleEditBox(nameEdit, {})
                nameEdit:SetScript("OnEnterPressed", function(self)
                    local val = self:GetText()
                    if val and val ~= "" then
                        group.name = val
                    end
                    self:ClearFocus()
                    -- Name feeds no sig — cosmetic only (header + canvas label).
                    S.SwitchTab("layout")
                    RefreshPlacedIndicators()
                end)
                nameEdit:SetScript("OnEscapePressed", function(self)
                    self:SetText(group.name)
                    self:ClearFocus()
                end)
                by = by - 32

                -- Categories, then Placement, then Growth -- the SAME list the
                -- row layout mounts, run down the card's cursor.
                by = RunCardSections(body, bodyWidth, by, CollectDebuffGroupSections(group))

                -- ── APPEARANCE (collapsible — the effect-card section idiom) ──
                by = by - 10
                by = AddGroupAppearanceSection(body, group, bodyWidth, by, cardKey)

                -- In-place reflow hook — see the Layout Groups tab's copy.
                body.dfAD_ReflowCard = function(newBy)
                    local h = -newBy + 12
                    body:SetHeight(h)
                    card:SetHeight(cardHeaderH + h)
                    stack:Reflow()
                end

                local bodyH = -by + 12
                body:SetHeight(bodyH)
                totalCardH = totalCardH + bodyH
            end

            card:SetHeight(totalCardH)
            yPos = yPos - totalCardH - 5
        end
    end

    parent:SetHeight(max(-yPos + 20, 200))
end

-- ============================================================
-- MAIN PAGE BUILD
-- ============================================================

-- ============================================================
-- THE SPLIT-PANEL PAGE
-- ------------------------------------------------------------
-- The 50/50 layout: preview left, three-tab settings column right, everything
-- hand-anchored inside one S.mainFrame that the page harness never sees. It is
-- why this page had to force the window 210px wider than its own default, and it
-- is now the CLASSIC layout's arm only -- the popout layout takes
-- P.BuildAuraDesignerRowsPage (AuraDesigner/UI/Rows.lua), which emits bands into
-- the harness's own column.
--
-- ⚠ KEPT RATHER THAN DELETED, and not out of sentiment: classic is a live
-- layout, CreatePopoutPageTools returns nil in it, and every row, band and panel
-- the other arm builds needs that table. This is what classic still draws.
-- ============================================================
local function BuildAuraDesignerIsland(guiRef, pageRef, dbRef)
    local prevDB = S.db  -- capture before overwrite to detect mode switch
    S.page = pageRef
    S.db = dbRef

    local parent = S.page.child

    -- ========================================
    -- REUSE: If S.mainFrame already exists, S.db hasn't changed (same mode) AND the
    -- frame dimensions are unchanged, just re-parent, show, and refresh. A mode
    -- switch (Party↔Raid) changes S.db; an auto-layout switch keeps the SAME S.db
    -- reference but changes frameWidth/Height — both must force a full rebuild so
    -- the preview mock resizes to the active layout's frame size.
    -- ========================================
    local _adFDB = (DF.GetDB and DF:GetDB((GUI and GUI.SelectedMode) or "party")) or {}
    local _adW, _adH = _adFDB.frameWidth or 125, _adFDB.frameHeight or 64
    -- Auto-layout identity: two raid layouts share the SAME S.db proxy and may share
    -- frame dimensions, so neither check below distinguishes them — without this,
    -- switching between same-size raid layouts reuses the stale S.page.
    local _adLayout = (DF.AutoProfilesUI and (DF.AutoProfilesUI.editingProfile or DF.AutoProfilesUI.activeRuntimeProfile)) or nil
    -- Preset identity: switching the mode's preset keeps the same S.db/size/layout,
    -- so without this the stale S.page (bound to the old preset) would be reused.
    local _adPreset = DF.GetModeDesignerPresetName
        and DF:GetModeDesignerPresetName("aura", (GUI and GUI.SelectedMode) or "party")
    -- Editing identity: entering edit of the ACTIVE layout keeps the same table
    -- object (editingProfile == activeRuntimeProfile), so _adLayout alone
    -- misses the transition and the editing-banner offset is never applied.
    local _adEditing = (DF.AutoProfilesUI and DF.AutoProfilesUI.IsEditing and DF.AutoProfilesUI:IsEditing()) or false
    if S.mainFrame and prevDB == dbRef
       and S.mainFrame.dfBuiltFrameW == _adW and S.mainFrame.dfBuiltFrameH == _adH
       and S.mainFrame.dfBuiltLayout == _adLayout
       and S.mainFrame.dfBuiltPreset == _adPreset
       and S.mainFrame.dfBuiltEditing == _adEditing then
        S.mainFrame:SetParent(parent)
        S.mainFrame:SetAllPoints()
        S.mainFrame:Show()
        DF:AuraDesigner_RefreshPage()
        return
    end

    -- Full build (first time, or mode switch)
    if S.mainFrame then
        S.mainFrame:Hide()
        S.mainFrame:SetParent(nil)
    end
    wipe(placedIndicators)
    wipe(expandedCards)
    wipe(effectCardPool)

    S.activeTab = "effects"
    S.activeBuffTab = "my"
    S.activeFilter = "all"
    -- A shared picker left open on the OLD S.rightPanel dies with it (its
    -- close hook may already have run via the ancestor hide); drop the
    -- handle so CloseADPicker can't poke a stale overlay.
    S.adPickerDirty = false
    S.adPickerHandle = nil

    -- Layout constants
    local BANNER_H = 68
    local BUFFTAB_H = 30    -- main pool tab strip (My Buffs / Other Buffs)
    local SECTION_GAP = 8

    -- ========================================
    -- MAIN FRAME
    -- ========================================
    S.mainFrame = CreateFrame("Frame", nil, parent)
    S.mainFrame:SetAllPoints()
    -- Record the frame dims this build was made for, so the reuse-guard above can
    -- detect an auto-layout switch (same S.db, different frameWidth/Height) and rebuild.
    S.mainFrame.dfBuiltFrameW = _adW
    S.mainFrame.dfBuiltFrameH = _adH
    S.mainFrame.dfBuiltLayout = _adLayout
    S.mainFrame.dfBuiltPreset = _adPreset
    S.mainFrame.dfBuiltEditing = _adEditing
    -- Closing the settings window (or leaving this S.page) hides S.mainFrame with
    -- no refresh pass, which would leave the rendered preview pool's border
    -- animations ticking on the external driver (it ticks hidden secretRect
    -- borders — see ClearPlacedIndicators). OnHide fires on effective-visibility
    -- loss, so an ancestor hide (window close, S.page switch) reaches it too; the
    -- reuse path re-renders via AuraDesigner_RefreshPage → RefreshPlacedIndicators
    -- on return. S.mainFrame is created fresh per full build (the old one is hidden
    -- and unparented above), so this hook lands exactly once per frame.
    S.mainFrame:HookScript("OnHide", ClearPlacedIndicators)

    -- Override RefreshStates: Aura Designer uses its own layout system.
    --
    -- This hook gets called by anything that walks the GUI parent chain
    -- looking for a S.page with RefreshStates+children — including
    -- CreateInfoBanner's TriggerHostRelayout after every measure cycle.
    -- AuraDesigner_RefreshPage is a heavyweight rebuild (destroys +
    -- recreates every effect card on the active tab), so firing it
    -- from a banner's auto-resize cascade meant: each new banner from
    -- S.BuildEffectsTab triggered SetText → schedule DoRecomputeHeight →
    -- TriggerHostRelayout → S.page:RefreshStates → AuraDesigner_RefreshPage
    -- → S.SwitchTab → S.BuildEffectsTab → create more banners → repeat at
    -- ~9 Hz, locking up the GUI the moment the perf-warning banner
    -- surfaced (because picking an animation triggered the chain).
    --
    -- The fix: only call AuraDesigner_RefreshPage when the S.page
    -- dimensions actually changed.  GUI window resize cases (the real
    -- reason this hook exists) still rebuild; banner-cascade-as-noop
    -- cases stop the loop.
    S.page.RefreshStates = function(self)
        local pageH = self:GetHeight()
        self.child:SetHeight(pageH)
        -- GUI.PageChildWidth, not a fourth copy of the arithmetic: this page's
        -- child is a page child like any other, and the `- 30` it carried was one
        -- of the copies that had to be found by grep when the corridor moved.
        local newW = GUI.contentFrame and GUI.PageChildWidth(GUI.contentFrame:GetWidth()) or nil
        if self.child and newW then
            self.child:SetWidth(newW)
        end
        -- Keep parent scroll at 0 — only the right panel should scroll
        local parentScroll = self:GetParent()
        if parentScroll and parentScroll.SetVerticalScroll then
            parentScroll:SetVerticalScroll(0)
        end
        -- Skip the heavyweight rebuild when nothing actually changed —
        -- only fire it on genuine size transitions (window resize / tab
        -- switch / first show).
        if self._lastRefreshStatesH == pageH and self._lastRefreshStatesW == newW then
            -- Same-size revisit AFTER the OnHide hook cleared the canvas (tab
            -- away + back re-enters ONLY through RefreshCached -> here; the
            -- builder is cache-skipped). Repaint the pooled slots without the
            -- full S.page rebuild: slot restyling creates no banners, so the
            -- banner-cascade loop this early-out exists for cannot re-arm.
            if S.placedCleared then
                RefreshPlacedIndicators()
                RefreshPreviewEffects()
            end
            return
        end
        self._lastRefreshStatesH = pageH
        self._lastRefreshStatesW = newW
        DF:AuraDesigner_RefreshPage()
    end

    local yPos = -8  -- top gap; kept equal to the Text Designer's _tdTopY for a consistent header gap
    -- While editing a raid auto-layout, the AutoProfiles editing banner is a ~50px
    -- overlay anchored to the top of the content frame; this custom AD S.page lays
    -- its own content out from the top too, so push everything down to clear it
    -- (otherwise the editing banner sits on top of the enable banner / preset bar).
    if DF.AutoProfilesUI and DF.AutoProfilesUI.IsEditing and DF.AutoProfilesUI:IsEditing() then
        yPos = -56
    end

    -- ========================================
    -- ENABLE BANNER (full width)
    -- ========================================
    S.enableBanner = CreateEnableBanner(S.mainFrame)
    S.enableBanner:SetPoint("TOPLEFT", S.mainFrame, "TOPLEFT", 0, yPos)
    S.enableBanner:SetPoint("TOPRIGHT", S.mainFrame, "TOPRIGHT", 0, yPos)

    -- No Copy / Sync pair here (every other mode-specific S.page has one). The one
    -- key this S.page owns is the template NAME, and the template bar below sets
    -- it directly — so Copy was "pick that name in the other tab" and Sync was a
    -- link that could only ever hold one name in step. Sharing is now stated and
    -- undone on the bar itself; see GUI:CreateDesignerPresetBar.

    -- ========================================
    -- PRESET BAR (which named preset this mode uses + library management)
    -- Rides row 2 of the enable banner (left side; the spec dropdown holds the
    -- right side). Compact icon buttons keep the row within the S.page width.
    -- ========================================
    if GUI.CreateDesignerPresetBar then
        local presetBar = GUI:CreateDesignerPresetBar(S.enableBanner, {
            kind = "aura",
            iconButtons = true,
            getMode = function() return (GUI and GUI.SelectedMode) or "party" end,
            onChange = function()
                -- Re-invoke the build NEXT frame: the dfBuiltPreset guard then
                -- forces a full rebuild so the editor rebinds to the newly chosen
                -- preset. Deferred so we don't tear down the bar from inside its
                -- own click handler.
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, function()
                        if DF.BuildAuraDesignerPage then DF.BuildAuraDesignerPage(GUI, S.page, S.db) end
                        DF:InvalidateAuraLayout()
                        DF:UpdateAllFrames()
                        local E = DF.AuraDesigner and DF.AuraDesigner.Engine
                        if E and E.ForceRefreshAllFrames then E:ForceRefreshAllFrames() end
                    end)
                end
            end,
        })
        -- Row 2 reflows (B2): the spec dropdown moved onto the tab strip, so
        -- the preset bar takes the whole row.
        presetBar:SetPoint("LEFT", S.enableBanner, "LEFT", 10, -18)
        presetBar:SetPoint("RIGHT", S.enableBanner, "RIGHT", -10, -18)
        S.enableBanner.presetBar = presetBar
    end

    yPos = yPos - (BANNER_H + SECTION_GAP)

    -- ========================================
    -- MAIN POOL TAB STRIP (B2/C2): My Buffs / Debuffs / Other Buffs, between the header
    -- banner and the workspace. Visually distinct from the right panel's
    -- underline sub-tabs: filled StyleButton pills, slightly larger, with the
    -- relocated spec dropdown on the strip's right end (per the prototype —
    -- the spec only applies to My Buffs).
    -- ========================================
    local buffTabBar = CreateFrame("Frame", nil, S.mainFrame)
    buffTabBar:SetHeight(BUFFTAB_H)
    buffTabBar:SetPoint("TOPLEFT", S.mainFrame, "TOPLEFT", 0, yPos)
    buffTabBar:SetPoint("TOPRIGHT", S.mainFrame, "TOPRIGHT", 0, yPos)
    -- The strip itself is shared with the popout layout's row page, which mounts
    -- it as a band -- see S.BuildPoolStrip (AuraDesigner/UI/Rows.lua). Only the
    -- host differs: a slice of S.mainFrame here, a band there.
    S.BuildPoolStrip(buffTabBar)

    yPos = yPos - (BUFFTAB_H + SECTION_GAP)

    -- ========================================
    -- 50/50 SPLIT: LEFT PANEL + RIGHT PANEL
    -- ========================================
    local splitContainer = CreateFrame("Frame", nil, S.mainFrame)
    splitContainer:SetPoint("TOPLEFT", S.mainFrame, "TOPLEFT", 0, yPos)
    splitContainer:SetPoint("BOTTOMRIGHT", S.mainFrame, "BOTTOMRIGHT", 0, 0)
    S.mainFrame.splitContainer = splitContainer

    -- ── LEFT PANEL (frame preview) ──
    S.leftPanel = CreateFrame("Frame", nil, splitContainer, "BackdropTemplate")
    S.leftPanel:SetPoint("TOPLEFT", 0, 0)
    S.leftPanel:SetPoint("BOTTOMLEFT", 0, 0)
    S.leftPanel:SetPoint("RIGHT", splitContainer, "CENTER", -3, 0)
    -- NO border here — the inner preview container (CreateFramePreview) draws the
    -- visible dim border. A border on both stacked to a brighter doubled line.
    GUI:CreatePanelBackdrop(S.leftPanel, {border = false})

    -- Frame preview (reuses existing CreateFramePreview with adapted anchoring)
    -- (Removed) S.origY_framePreview and S.contentRightInset, both set to 0 here and
    -- read nowhere -- old-layout anchors that the current layout does not use. The
    -- second even carried "no right inset needed in new layout", i.e. a field whose
    -- own comment said it was not needed.
    S.framePreview = CreateFramePreview(S.leftPanel, 0, nil)

    -- ── RIGHT PANEL (tabbed settings) ──
    S.rightPanel = CreateFrame("Frame", nil, splitContainer, "BackdropTemplate")
    S.rightPanel:SetPoint("TOPRIGHT", 0, 0)
    S.rightPanel:SetPoint("BOTTOMRIGHT", 0, 0)
    S.rightPanel:SetPoint("LEFT", splitContainer, "CENTER", 3, 0)  -- 6px split gap (matches Text Designer)
    GUI:CreatePanelBackdrop(S.rightPanel, {borderColor = {r = C_BORDER.r, g = C_BORDER.g, b = C_BORDER.b, a = 0.5}})

    -- ── TAB BAR ── (shared underline-tab style, mirroring the Pinned Frames
    -- tabs: a transparent strip with a baseline; each tab is a StyleButton in
    -- `tab` mode — faint cell when inactive, accent fill + underline + accent
    -- label when active. Per-tab accent preserves each section's identity.)
    S.tabBar = CreateFrame("Frame", nil, S.rightPanel, "BackdropTemplate")
    S.tabBar:SetHeight(28)
    -- Inset just inside the panel's border so the tabs don't overlap/overrun it.
    S.tabBar:SetPoint("TOPLEFT", 4, -4)
    S.tabBar:SetPoint("TOPRIGHT", -4, -4)

    -- Baseline under the whole strip; the active tab's underline sits on it.
    local tabBaseline = S.tabBar:CreateTexture(nil, "ARTWORK")
    tabBaseline:SetTexture("Interface\\Buttons\\WHITE8x8")
    tabBaseline:SetHeight(1)
    tabBaseline:SetPoint("BOTTOMLEFT", 0, 0)
    tabBaseline:SetPoint("BOTTOMRIGHT", 0, 0)
    tabBaseline:SetColorTexture(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)

    local TAB_GAP = 4
    local TAB_DEFS = {
        { key = "effects", label = L["Effects"],       accent = nil },  -- theme-tracking
        { key = "layout",  label = L["Layout Groups"], accent = { r = 0.91, g = 0.66, b = 0.25 } },
        { key = "global",  label = L["Global"],        accent = { r = 0.51, g = 0.86, b = 0.51 } },
    }

    wipe(tabButtons)
    for i, def in ipairs(TAB_DEFS) do
        local btn = CreateFrame("Button", nil, S.tabBar, "BackdropTemplate")
        btn:SetHeight(28)
        if i == 1 then
            btn:SetPoint("TOPLEFT", 0, 0)
        else
            btn:SetPoint("TOPLEFT", tabButtons[TAB_DEFS[i-1].key], "TOPRIGHT", TAB_GAP, 0)
        end
        local provW = parent:GetWidth()
        if provW < 100 and GUI and GUI.contentFrame then provW = GUI.contentFrame:GetWidth() end
        if provW < 100 then provW = 600 end
        btn:SetWidth(max(60, floor(((provW / 2) - (#TAB_DEFS - 1) * TAB_GAP) / #TAB_DEFS)))

        -- Shared underline-tab styling; S.SwitchTab drives SetActive. label = btn.Text.
        GUI:StyleButton(btn, { tab = true, text = def.label, accent = def.accent, font = "DFFontHighlight" })
        btn.label = btn.Text

        btn.tabKey = def.key
        btn:SetScript("OnClick", function(self)
            if self.dfDisabled then return end  -- frosted (Effects on Debuffs)
            S.SwitchTab(self.tabKey)
        end)

        -- Effects is buff-pool-only (C2): frosted on the Debuffs tab —
        -- category groups have no per-spell placed indicators.
        if def.key == "effects" then
            btn:HookScript("OnEnter", function(self)
                if self.dfDisabled then
                    GUI:ShowTooltip(self, {
                        title = L["Effects"],
                        lines = { L["Not available for Debuffs. Use Layout Groups instead."] },
                    })
                end
            end)
            btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        end

        tabButtons[def.key] = btn
    end
    UpdateLayoutTabState()

    -- Equal-width tabs (accounting for the gaps) on parent resize.
    S.tabBar:SetScript("OnSizeChanged", function(self, w, h)
        local n = #TAB_DEFS
        local tabW = (w - (n - 1) * TAB_GAP) / n
        for _, def in ipairs(TAB_DEFS) do
            local btn = tabButtons[def.key]
            if btn then btn:SetWidth(tabW) end
        end
    end)

    -- ── TAB CONTENT (scrollable) ──
    S.tabScrollFrame = CreateFrame("ScrollFrame", nil, S.rightPanel, "ScrollFrameTemplate")
    S.tabScrollFrame:SetPoint("TOPLEFT", S.tabBar, "BOTTOMLEFT", 0, 0)
    S.tabScrollFrame:SetPoint("BOTTOMRIGHT", -22, 0)

    S.tabContentFrame = CreateFrame("Frame", nil, S.tabScrollFrame)
    -- Pre-compute initial width from parent geometry so S.SwitchTab() has
    -- accurate dimensions before the first layout pass fires OnSizeChanged.
    local earlyW = parent:GetWidth()
    if earlyW < 100 then
        earlyW = GUI.PageChildWidth(GUI.contentFrame and GUI.contentFrame:GetWidth() or 600)
    end
    S.tabContentFrame:SetWidth(max(1, (earlyW / 2) - 2 - 22))
    S.tabContentFrame:SetHeight(800)
    S.tabScrollFrame:SetScrollChild(S.tabContentFrame)
    DF.GUI.StyleScrollBar(S.tabScrollFrame)

    -- Match scroll child width to scroll frame
    S.tabScrollFrame:SetScript("OnSizeChanged", function(self, w, h)
        S.tabContentFrame:SetWidth(w)
    end)

    -- Smooth scroll
    local SCROLL_STEP = 30
    S.tabScrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = max(0, self:GetVerticalScrollRange())
        local newScroll = max(0, min(maxScroll, current - (delta * SCROLL_STEP)))
        self:SetVerticalScroll(newScroll)
    end)
    S.tabContentFrame:EnableMouseWheel(true)
    S.tabContentFrame:SetScript("OnMouseWheel", function(self, delta)
        local p = self:GetParent()
        if p and p:GetScript("OnMouseWheel") then
            p:GetScript("OnMouseWheel")(p, delta)
        end
    end)

    -- ========================================
    -- POPULATE (new UI)
    -- ========================================

    -- Force initial width sync: OnSizeChanged won't fire until the frame renders,
    -- but S.SwitchTab needs accurate widths now for slider/dropdown sizing.
    -- Compute initial scroll content width from parent geometry.
    -- S.rightPanel:GetWidth() returns 0 before the first layout pass, so we
    -- calculate from the parent which already has valid geometry on a mode
    -- switch (Party↔Raid).
    local parentW = parent:GetWidth()
    if parentW < 100 and GUI and GUI.contentFrame then parentW = GUI.contentFrame:GetWidth() end
    if parentW < 100 then parentW = UIParent:GetWidth() / 2 end
    local initW = (parentW / 2) - 2 - 22  -- half split minus gap minus scrollbar
    if initW > 50 then
        S.tabContentFrame:SetWidth(initW)
    end

    S.SwitchTab("effects")
    C_Timer.After(0, function()
        if S.tabBar and S.tabBar:IsVisible() and S.tabBar:GetWidth() > 10 then
            local tabW = (S.tabBar:GetWidth() - (#TAB_DEFS - 1) * TAB_GAP) / #TAB_DEFS
            for _, def in ipairs(TAB_DEFS) do
                if tabButtons[def.key] then
                    tabButtons[def.key]:SetWidth(tabW)
                end
            end
        end
    end)
    RefreshPlacedIndicators()
    RefreshPreviewEffects()
end

-- ============================================================
-- WHICH PAGE THIS IS
-- ------------------------------------------------------------
-- `Add` is the tell, and it is a better one than asking the layout: the popout
-- arm emits BANDS, and a band can only be emitted through the harness's own Add.
-- A caller that has one is on BuildPage's contract; a caller that does not (an
-- older call site, or the preset bar's own deferred re-invoke) can only be served
-- the island. The layout check is still made, because CreatePopoutPageTools
-- answers nil in classic and every row the other arm builds needs its table.
-- ============================================================
function DF.BuildAuraDesignerPage(guiRef, pageRef, dbRef, Add, AddSpace)
    if Add and P.BuildAuraDesignerRowsPage and not DF:IsClassicSettingsLayout() then
        -- A previous build's island is not in page.children -- it never went
        -- through Add -- so DoBuild's own retire loop cannot see it, and it would
        -- sit under the bands still showing the last mode's controls.
        if S.mainFrame then
            S.mainFrame:Hide()
            S.mainFrame:SetParent(nil)
            S.mainFrame = nil
        end
        return P.BuildAuraDesignerRowsPage(pageRef, dbRef, Add, AddSpace)
    end
    S.rowsMode = false
    return BuildAuraDesignerIsland(guiRef, pageRef, dbRef)
end

-- ============================================================
-- REFRESH
-- ============================================================

function DF:AuraDesigner_RefreshPage()
    -- ☠ IN THE POPOUT LAYOUT THERE IS NO S.mainFrame TO REFRESH. This verb means
    -- "the data moved, redraw the page", and the page harness's own rebuild is
    -- what that means there. Callers are unchanged: sixty-odd sites across the
    -- editor say this sentence, and it is true in both layouts.
    --
    -- ⚠ CONTROLS INSIDE AN OPEN PANE MUST NOT COME HERE -- a rebuild closes every
    -- open panel (CreatePopoutPageTools' first act), which for a tick the user
    -- just clicked reads as the panel falling shut. Those go through
    -- P.ADStructuralRedraw, which re-flows the pane instead.
    if S.rowsMode then
        if S.framePreview and S.framePreview.RefreshGeometry then
            S.framePreview.RefreshGeometry()
        end
        if S.page and S.page.Refresh then S.page:Refresh() end
        return
    end
    if not S.mainFrame then return end

    -- Frame size and Preview Scale are settings like any other; re-read them here so
    -- the preview follows a slider immediately instead of waiting for a window resize
    -- or a page revisit to rebuild it.
    if S.framePreview and S.framePreview.RefreshGeometry then
        S.framePreview.RefreshGeometry()
    end

    -- Account for editing banner offset (50px) when editing an auto layout
    local editingOffset = 0
    if DF.AutoProfilesUI and DF.AutoProfilesUI:IsEditing() then
        editingOffset = 50
    end
    S.mainFrame:ClearAllPoints()
    S.mainFrame:SetPoint("TOPLEFT", S.mainFrame:GetParent(), "TOPLEFT", 0, -editingOffset)
    S.mainFrame:SetPoint("BOTTOMRIGHT", S.mainFrame:GetParent(), "BOTTOMRIGHT", 0, 0)

    -- Check if spec changed
    local currentSpec = ResolveSpec()
    if currentSpec ~= S.selectedSpec then
        S.selectedSpec = currentSpec
    end

    -- Subtle class-color hint on the preview border, dimmed to 0.5 alpha so it
    -- stays as quiet as the Text Designer's neutral border (just tinted to the
    -- spec). Was previously full alpha = the harsh "white line" (white for Priest).
    if S.framePreview then
        local resolvedSpec = currentSpec or S.selectedSpec
        local specInfoEntry = resolvedSpec and DF.AuraDesigner.SpecInfo[resolvedSpec]
        local classToken = specInfoEntry and specInfoEntry.class
        local classColor = classToken and RAID_CLASS_COLORS[classToken]
        if classColor then
            S.framePreview:SetBackdropBorderColor(classColor.r, classColor.g, classColor.b, 0.5)
        else
            S.framePreview:SetBackdropBorderColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.5)
        end
    end

    -- Rebuild the current tab to reflect data changes
    if S.activeTab and S.SwitchTab then
        S.SwitchTab(S.activeTab)
    end

    -- Refresh frame preview
    RefreshPlacedIndicators()
    RefreshPreviewEffects()

    -- Update enable state.
    -- ☠ FROM THE MODE, NOT THE PRESET. These two reads are what broke the enable click
    -- when the switch moved to the mode db: the click writes the mode, then calls THIS
    -- refresh, and this re-synced the checkbox and the overlay from the preset field
    -- the click no longer writes -- so the box unticked itself and the disabled overlay
    -- stayed up until a page revisit ran the full build (whose reads were updated).
    -- "when I click enable the toggle does not stick and AD does not activate" (Krathe,
    -- 2026-08-22) was exactly these two lines. They read GetAuraDesignerDB().enabled
    -- INLINE, which is why the sweep that fixed every named `adDB.enabled` missed them.
    local adEnabled = DF.IsAuraDesignerEnabledForMode
        and DF:IsAuraDesignerEnabledForMode((GUI and GUI.SelectedMode) or "party")
    if S.enableBanner then
        S.enableBanner.checkbox:SetChecked(adEnabled)
    end
    -- Spec dropdown lives on the main tab strip (B2): refresh its text on
    -- My Buffs / keep the greyed "shared across specs" caption on Other Buffs.
    UpdateSpecDropdownState()

    -- Show/hide disabled overlay on the split container
    if S.mainFrame.splitContainer then
        if not adEnabled then
            if not S.mainFrame.disabledOverlay then
                -- Shared with the Text Designer and Raid Auto Layouts; this S.page
                -- only owns the extent (the whole split container) and the label.
                local overlay = GUI:CreateDisabledOverlay(S.mainFrame.splitContainer, {
                    label = L["Aura Designer is disabled"],
                })
                overlay:SetAllPoints()
                S.mainFrame.disabledOverlay = overlay
            end
            S.mainFrame.disabledOverlay:Show()
        else
            if S.mainFrame.disabledOverlay then
                S.mainFrame.disabledOverlay:Hide()
            end
        end
    end

    -- Refresh buffs tab banner state if visible
    local buffsPage = GUI and GUI.Pages and GUI.Pages["auras_buffs"]
    if buffsPage and buffsPage.RefreshStates then
        buffsPage:RefreshStates()
    end

    -- 12.1: the native factory buff row DERIVES its Aura-Designer dedup set from the AD
    -- config at build time. Indicator add/remove (and other config mutations) funnel
    -- through this refresh but do NOT otherwise re-drive live frames, so poke the buff
    -- row here — mirror the aura-blacklist S.page (InvalidateAuraLayout -> RefreshFactoryRows).
    -- DriveBuffFactory rebuilds only when the excluded set actually moved (sig-gated), so a
    -- navigation-only refresh is a cheap no-op. Factory-gated so the pre-12.1 path is untouched.
    if DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported()
        and DF.InvalidateAuraLayout then
        DF:InvalidateAuraLayout()
    end
end
