-- Part 5 of the Aura Designer editor: the pool strip and the spec picker the
-- split panel (Editor.lua's BuildAuraDesignerIsland) mounts above its tabs.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`).
local DF = DandersFrames
local L = DF.L
local GUI = DF.GUI
local S = DF.AuraDesigner._uiState
local P = DF.AuraDesigner._priv

local ipairs = ipairs
local wipe = wipe

local C_TEXT_DIM = GUI.Colors.textDim

-- Aliases of things the earlier parts built. Load-time constants, exactly as the
-- other parts take them.
local CreateSpecDropdown       = P.CreateSpecDropdown
local SetMainTab               = P.SetMainTab
local UpdateSpecDropdownState  = P.UpdateSpecDropdownState
local mainTabButtons           = P.mainTabButtons

-- The pool tab strip's height.
local BUFFTAB_H = 30
-- Between a caption and the opener it names.
local LABEL_GAP  = 8

-- ============================================================
-- THE POOL STRIP
-- ------------------------------------------------------------
-- My Buffs / Debuffs / Any Buff as three tab buttons, in a slice of S.mainFrame
-- (Editor.lua). The three pools differ on two axes the labels can't carry, so
-- each tab explains itself on hover.
-- ============================================================
-- ⚠ A FUNCTION, NOT A FILE-SCOPE TABLE. Every label and every tooltip line is an
-- L[...] lookup, and a table built at load freezes whatever locale was live then
-- -- the trap DF:RegisterLocaleRefresh exists for.
-- ⚠ A VERB, NOT A TABLE, and the fourth entry is why that matters twice over: every label is
-- an L[...] lookup that must resolve at the live locale, AND the helper's tab is class-gated,
-- so the list genuinely differs between characters. Built at load, it would freeze both.
local function PoolDefs()
    local defs = {
        { key = "my",      label = L["My Buffs"], tooltip = {
            L["Buffs from your own class, and only when you cast them."],
            L["Set up separately for each specialization."],
        } },
        { key = "debuffs", label = L["Debuffs"], tooltip = {
            L["Groups of debuffs picked by category — boss, crowd control, dispellable and so on — rather than one spell at a time."],
            L["Shared across all your specializations."],
        } },
        { key = "other",   label = L["Any Buff"], tooltip = {
            L["Any buff in the spell database, from any caster — including your own."],
            L["Turn on Others Only for an effect to ignore your own casts."],
            L["Shared across all your specializations."],
        } },
    }
    -- ⚠ PRIEST ONLY, AND APPENDED RATHER THAN DECLARED ABOVE. Power Infusion is a priest
    -- ability, so on anyone else this tab would be a fourth of the strip's width spent on a
    -- pool that can never hold anything. Appending keeps the other three in their existing
    -- order and positions -- the strip divides its width by #defs, so a conditional entry
    -- anywhere but the end would move tabs people already know the position of.
    if DF.IsPIHelperAvailable and DF.IsPIHelperAvailable() then
        -- ⚠ SHORT LABEL, FULL NAME IN THE TOOLTIP. The strip divides its width EQUALLY
        -- between the tabs (see S.BuildPoolStrip), so a fourth tab takes every tab from a
        -- third of the band to a quarter -- and the note there already says the original
        -- three do not fit at the 640px default any other way. "Power Infusion Helper" is
        -- 22 characters against "My Buffs" and "Any Buff" at 8; "PI Helper" sits with its
        -- neighbours and needs no truncation machinery to get there.
        defs[#defs + 1] = { key = "pihelper", label = L["PI Helper"],
            tooltipTitle = L["Power Infusion Helper"], tooltip = {
            L["Who is worth casting Power Infusion on, and how that shows on the frame."],
            L["Set up its Triggers, then add effects the same way as any other pool."],
            L["Shared across all your specializations."],
        } }
    end
    return defs
end

S.BuildPoolStrip = function(buffTabBar)
    local MAIN_TAB_DEFS = PoolDefs()
    wipe(mainTabButtons)
    local prevMainBtn
    for _, def in ipairs(MAIN_TAB_DEFS) do
        local btn = CreateFrame("Button", nil, buffTabBar, "BackdropTemplate")
        GUI:StyleButton(btn, { height = BUFFTAB_H - 4, text = def.label, font = "DFFontHighlight" })
        btn.Text:ClearAllPoints()
        btn.Text:SetPoint("CENTER", 0, 0)
        -- Width comes from the strip, not from the label -- see the OnSizeChanged
        -- below. A build-time width of max(text+28, 96) needed 296px for three
        -- tabs, which the 850px island always had and a 640px window does not.
        if prevMainBtn then
            btn:SetPoint("LEFT", prevMainBtn, "RIGHT", 4, 0)
        else
            btn:SetPoint("LEFT", buffTabBar, "LEFT", 0, 0)
        end
        local capturedKey = def.key
        btn:SetScript("OnClick", function() SetMainTab(capturedKey) end)
        -- HookScript, not SetScript: StyleButton owns OnEnter/OnLeave for the
        -- hover wash, and replacing them would leave the tab stuck lit.
        -- ⚠ tooltipTitle OVERRIDES label, as on the folder tabs: the PI Helper's tab
        -- is an abbreviation and its tooltip carries the full name.
        local tipTitle, tipLines = def.tooltipTitle or def.label, def.tooltip
        btn:HookScript("OnEnter", function(self)
            GUI:ShowTooltip(self, { title = tipTitle, lines = tipLines })
        end)
        btn:HookScript("OnLeave", function() GUI:HideTooltip() end)
        btn:SetActive(S.activeBuffTab == def.key)
        mainTabButtons[def.key] = btn
        prevMainBtn = btn
    end

    -- ☠ EQUAL WIDTH, DIVIDED FROM THE STRIP, exactly as the sub-tab strip below
    -- does it (P.ApplySubTabStrip). The three tabs are one control -- a
    -- three-way switch -- so they should read as three equal halves of the band
    -- rather than three labels of whatever width their words happen to be, and
    -- at the 640px default their words do not fit any other way.
    local nTabs = #MAIN_TAB_DEFS
    buffTabBar:SetScript("OnSizeChanged", function(self, w)
        if not w or w < 10 then return end
        local tabW = (w - (nTabs - 1) * 4) / nTabs
        for i = 1, nTabs do
            local b = mainTabButtons[MAIN_TAB_DEFS[i].key]
            if b then b:SetWidth(tabW) end
        end
    end)
    local w0 = buffTabBar:GetWidth()
    if w0 and w0 > 10 then
        local tabW = (w0 - (nTabs - 1) * 4) / nTabs
        for i = 1, nTabs do
            local b = mainTabButtons[MAIN_TAB_DEFS[i].key]
            if b then b:SetWidth(tabW) end
        end
    end
end

-- ============================================================
-- THE SPEC PICKER
-- ============================================================
-- ⚠ SPEC STAYS VISIBLE and greys on the pools that have no spec (Debuffs and Any
-- Buff are shared across specs), rather than hiding -- that is the addon's
-- grey-when-disabled convention, and hiding it would change the row's shape on
-- every pool switch. UpdateSpecDropdownState owns the greying, and a pool change
-- reaches it twice: SetMainTab calls it directly, then the page rebuild it
-- triggers runs this builder again on the new dropdown.
S.BuildSpecPicker = function(host)
    local specLabel = host:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    specLabel:SetText(L["Spec:"])
    specLabel:SetTextColor(C_TEXT_DIM.r, C_TEXT_DIM.g, C_TEXT_DIM.b)
    specLabel:SetPoint("LEFT", host, "LEFT", 2, 0)

    S.specDropdown, S.specDropdownUpdate = CreateSpecDropdown(host)
    S.specDropdown:SetHeight(22)
    -- Anchored to BOTH edges rather than given a width: the band is whatever the
    -- window is, and a 165px dropdown floating in the middle of it reads as a
    -- stray control instead of a row. Spec names are the long ones
    -- ("Auto (Restoration Shaman)"), so every pixel of the band goes to it.
    S.specDropdown:SetPoint("LEFT", specLabel, "RIGHT", LABEL_GAP, 0)
    S.specDropdown:SetPoint("RIGHT", host, "RIGHT", -2, 0)
    UpdateSpecDropdownState()
end
