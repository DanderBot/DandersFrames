local addonName, DF = ...

-- ============================================================
-- AURA BLACKLIST - OPTIONS GUI
-- Single-list UI for blacklisting buffs and debuffs.
-- Called from Options/Options.lua via DF.BuildAuraBlacklistPage()
-- ============================================================

local pairs, ipairs = pairs, ipairs
local format = string.format
local tinsert = table.insert
local wipe = wipe
local CreateFrame = CreateFrame

local L = DF.L

-- ============================================================
-- MAIN PAGE BUILD
-- ============================================================

function DF.BuildAuraBlacklistPage(guiRef, pageRef, dbRef)
    -- Build frames once; subsequent calls just refresh widget data
    if pageRef._auraBlacklistBuilt then
        if pageRef._buffWidget then pageRef._buffWidget:Refresh() end
        if pageRef._debuffWidget then pageRef._debuffWidget:Refresh() end
        if pageRef._updateDropdownText then pageRef._updateDropdownText() end
        return
    end
    pageRef._auraBlacklistBuilt = true

    local GUI = guiRef
    local page = pageRef
    local parent = page.child

    -- ========== STATE ==========
    local selectedClass = "AUTO"

    -- Reusable frame pools
    local buffItemPool = {}
    local debuffItemPool = {}

    -- ========== BLACKLIST ACCESS ==========
    local function GetBlacklist()
        return DF.db and DF.db.auraBlacklist or { buffs = {}, debuffs = {} }
    end

    -- ========== DETECT PLAYER CLASS ==========
    local function GetPlayerClass()
        local _, classToken = UnitClass("player")
        return classToken
    end

    -- ========== RESOLVE SELECTED CLASS ==========
    local function ResolveClass()
        if selectedClass == "AUTO" then
            return GetPlayerClass()
        end
        return selectedClass
    end

    -- ========== GET ALL BUFFS FOR CLASS ==========
    local function GetAllBuffs()
        local class = ResolveClass()
        local spells = DF.AuraBlacklist and DF.AuraBlacklist.BuffSpells and DF.AuraBlacklist.BuffSpells[class]
        if not spells then return {} end
        return spells
    end

    -- ========== GET ALL DEBUFFS ==========
    local function GetAllDebuffs()
        local spells = DF.AuraBlacklist and DF.AuraBlacklist.DebuffSpells
        if not spells then return {} end
        return spells
    end

    -- ========== NOTIFY AURA SYSTEM ==========
    local function NotifyBlacklistChanged()
        -- Refresh all visible frames to re-filter auras
        if DF.RefreshAllVisibleFrames then
            DF:RefreshAllVisibleFrames()
        end
        -- 12.1 factory rows: the buff blacklist rides candidateFilters.excludeSpellIDs
        -- (structural — the exclude set is part of the row signature), so an edit here
        -- must bump + re-drive for the container to rebuild with the new set.
        if DF.InvalidateAuraLayout then
            DF:InvalidateAuraLayout()
        end
    end

    -- ========== MINI CHECKBOX HELPER ==========
    local function CreateMiniCheckbox(parentFrame, label, checked, onChange)
        local cb = CreateFrame("Button", nil, parentFrame, "BackdropTemplate")
        local fill = GUI:StyleCheckButton(cb, { size = 12, checkSize = 8, manualCheck = true, themeRoot = parentFrame })
        fill:SetShown(checked)

        -- Label text (optional — column headers carry the meaning when omitted)
        local text
        if label and label ~= "" then
            text = cb:CreateFontString(nil, "OVERLAY")
            GUI:SetSettingsFont(text, 8, "")
            text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
            text:SetText(label)
            text:SetTextColor(0.55, 0.55, 0.55)
        end

        cb:SetScript("OnClick", function()
            local newState = not fill:IsShown()
            fill:SetShown(newState)
            onChange(newState)
        end)
        cb:SetScript("OnEnter", function()
            if text then text:SetTextColor(0.80, 0.80, 0.80) end
        end)
        cb:SetScript("OnLeave", function()
            if text then text:SetTextColor(0.55, 0.55, 0.55) end
        end)

        cb._check = fill
        return cb
    end

    -- ========== SPELL ROW (unified list item) ==========
    local function CreateSpellRow(scrollContent, spell, index, rowHeight, blacklistKey, refreshFn)
        local tc = GUI.GetThemeColor()
        local bl = GetBlacklist()
        local entry = bl[blacklistKey] and bl[blacklistKey][spell.spellId]
        local isBlacklisted = entry ~= nil

        local row = CreateFrame("Button", nil, scrollContent, "BackdropTemplate")
        row:SetHeight(rowHeight - 1)
        row:SetPoint("TOPLEFT", 0, -((index - 1) * rowHeight))
        row:SetPoint("TOPRIGHT", 0, -((index - 1) * rowHeight))
        row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        row:EnableMouse(true)

        -- Background color based on state
        if isBlacklisted then
            row:SetBackdropColor(0.14, 0.14, 0.14, 0.95)
        else
            row:SetBackdropColor(0.08, 0.08, 0.08, 0.6)
        end

        -- Left accent bar (theme-colored, only for blacklisted)
        local accent = row:CreateTexture(nil, "ARTWORK")
        accent:SetSize(3, rowHeight - 5)
        accent:SetPoint("LEFT", 2, 0)
        accent:SetColorTexture(tc.r, tc.g, tc.b, 1)
        accent:SetShown(isBlacklisted)

        -- Spell icon
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 18)
        icon:SetPoint("LEFT", 10, 0)
        icon:SetTexture(spell.icon or 134400)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if not isBlacklisted then
            icon:SetAlpha(0.5)
        end

        -- Spell name
        local nameText = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        nameText:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        nameText:SetPoint("RIGHT", -160, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetText(spell.display)
        if isBlacklisted then
            nameText:SetTextColor(0.90, 0.90, 0.90)
        else
            nameText:SetTextColor(0.55, 0.55, 0.55)
        end

        -- Warning icon for spells with known limitations
        if spell.spellId == 474754 then  -- Symbiotic Relationship
            local warnIcon = CreateFrame("Button", nil, row)
            warnIcon:SetSize(18, 18)
            warnIcon:SetPoint("LEFT", nameText, "RIGHT", 4, 0)
            local warnTex = warnIcon:CreateTexture(nil, "OVERLAY")
            warnTex:SetAllPoints()
            warnTex:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning")
            warnIcon:SetScript("OnEnter", function(self)
                GUI:ShowTooltip(self, {
                    title = L["Symbiotic Relationship"],
                    tone = "warning",
                    lines = {
                        { text = L["Only the aura on the caster can be blacklisted. The aura on the target cannot be blacklisted due to Blizzard limitations."], color = { r = 1, g = 1, b = 1 } },
                    },
                })
            end)
            warnIcon:SetScript("OnLeave", function()
                GUI:HideTooltip()
            end)
        end

        -- Checkboxes (always visible — checked state reflects blacklist)
        local combatChecked = isBlacklisted and type(entry) == "table" and entry.combat or false
        local oocChecked = isBlacklisted and type(entry) == "table" and entry.ooc or false

        local combatCB = CreateMiniCheckbox(row, nil, combatChecked, function(newState)
            local blNow = GetBlacklist()
            local e = blNow[blacklistKey] and blNow[blacklistKey][spell.spellId]
            if newState and not e then
                -- Checking combat on a non-blacklisted spell — add it
                blNow[blacklistKey][spell.spellId] = { combat = true, ooc = false }
                NotifyBlacklistChanged()
                refreshFn()
                return
            end
            if type(e) == "table" then
                e.combat = newState
                if not e.combat and not e.ooc then
                    blNow[blacklistKey][spell.spellId] = nil
                end
            end
            NotifyBlacklistChanged()
            refreshFn()
        end)
        combatCB:SetPoint("RIGHT", row, "RIGHT", -120, 0)

        local oocCB = CreateMiniCheckbox(row, nil, oocChecked, function(newState)
            local blNow = GetBlacklist()
            local e = blNow[blacklistKey] and blNow[blacklistKey][spell.spellId]
            if newState and not e then
                -- Checking OOC on a non-blacklisted spell — add it
                blNow[blacklistKey][spell.spellId] = { combat = false, ooc = true }
                NotifyBlacklistChanged()
                refreshFn()
                return
            end
            if type(e) == "table" then
                e.ooc = newState
                if not e.combat and not e.ooc then
                    blNow[blacklistKey][spell.spellId] = nil
                end
            end
            NotifyBlacklistChanged()
            refreshFn()
        end)
        oocCB:SetPoint("RIGHT", row, "RIGHT", -40, 0)

        -- Click row to toggle blacklist (toggle both on/off)
        row:SetScript("OnClick", function()
            local blNow = GetBlacklist()
            if blNow[blacklistKey][spell.spellId] then
                blNow[blacklistKey][spell.spellId] = nil
            else
                blNow[blacklistKey][spell.spellId] = { combat = true, ooc = true }
            end
            NotifyBlacklistChanged()
            refreshFn()
        end)

        -- Hover effect + tooltip
        row:SetScript("OnEnter", function(self)
            if isBlacklisted then
                self:SetBackdropColor(0.18, 0.18, 0.18, 0.95)
            else
                self:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
            end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(spell.spellId)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            if isBlacklisted then
                self:SetBackdropColor(0.14, 0.14, 0.14, 0.95)
            else
                self:SetBackdropColor(0.08, 0.08, 0.08, 0.6)
            end
            GUI:HideTooltip()
        end)

        return row
    end

    -- ========== SPELL LIST WIDGET ==========
    local function CreateSpellListWidget(yAnchorFrame, yOffset, headerText, getSpellsFn, blacklistKey, itemPool)
        local ROW_HEIGHT = 28
        local LIST_WIDTH = 480
        local LIST_HEIGHT = 220

        local container = CreateFrame("Frame", nil, parent)
        container:SetSize(LIST_WIDTH, LIST_HEIGHT + 30)
        container:SetPoint("TOPLEFT", yAnchorFrame, "BOTTOMLEFT", 0, yOffset)

        -- Header. Matches GUI:CreateHeader's theme behavior: color via the
        -- theme color and register an UpdateTheme listener so it recolors when
        -- the party/raid theme changes.
        local tc = GUI.GetThemeColor()
        local header = container:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        header:SetPoint("TOPLEFT", 0, 0)
        header:SetText(headerText)
        header:SetTextColor(tc.r, tc.g, tc.b)
        header.UpdateTheme = function()
            local nc = GUI.GetThemeColor()
            header:SetTextColor(nc.r, nc.g, nc.b)
        end
        if not parent.ThemeListeners then parent.ThemeListeners = {} end
        table.insert(parent.ThemeListeners, header)

        -- Blacklisted count (right-aligned next to header)
        local countText = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        countText:SetPoint("LEFT", header, "RIGHT", 10, 0)
        countText:SetTextColor(0.5, 0.5, 0.5)

        -- Column headers for the per-row toggles. Centered over the checkbox
        -- columns (rows sit ~24px inside the list's right edge to clear the
        -- scrollbar, so the offsets account for that). Full words here mean the
        -- rows themselves can stay label-free and uncluttered.
        local combatHeader = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        combatHeader:SetPoint("TOP", container, "TOPRIGHT", -150, -1)
        combatHeader:SetText(L["Combat"])
        combatHeader:SetTextColor(0.55, 0.55, 0.55)

        local oocHeader = container:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        oocHeader:SetPoint("TOP", container, "TOPRIGHT", -70, -1)
        oocHeader:SetText(L["Out of Combat"])
        oocHeader:SetTextColor(0.55, 0.55, 0.55)

        -- List background
        local listBg = CreateFrame("Frame", nil, container, "BackdropTemplate")
        listBg:SetPoint("TOPLEFT", 0, -18)
        listBg:SetSize(LIST_WIDTH, LIST_HEIGHT)
        GUI:CreatePanelBackdrop(listBg, {borderColor = {r = 0.20, g = 0.20, b = 0.20, a = 1}})

        -- Scroll frame
        local scrollFrame = CreateFrame("ScrollFrame", nil, listBg, "ScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 4, -4)
        scrollFrame:SetPoint("BOTTOMRIGHT", -24, 4)
        DF.GUI.StyleScrollBar(scrollFrame)

        local scrollContent = CreateFrame("Frame", nil, scrollFrame)
        scrollContent:SetSize(LIST_WIDTH - 28, 1)
        scrollFrame:SetScrollChild(scrollContent)

        -- Empty hint
        local emptyText = listBg:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
        emptyText:SetPoint("CENTER", listBg, "CENTER", 0, 0)
        emptyText:SetText(L["No spells available for this class"])

        -- Refresh
        local function Refresh()
            -- Clear old items
            for _, item in ipairs(itemPool) do
                item:ClearAllPoints()
                item:Hide()
            end
            wipe(itemPool)

            local spells = getSpellsFn()
            emptyText:SetShown(#spells == 0)

            -- Count blacklisted
            local bl = GetBlacklist()
            local blCount = 0
            for _, spell in ipairs(spells) do
                if bl[blacklistKey][spell.spellId] then
                    blCount = blCount + 1
                end
            end
            if blCount > 0 then
                countText:SetText(format(L["%d blacklisted"], blCount))
            else
                countText:SetText("")
            end

            scrollContent:SetHeight(math.max(1, #spells * ROW_HEIGHT))

            for i, spell in ipairs(spells) do
                local row = CreateSpellRow(scrollContent, spell, i, ROW_HEIGHT, blacklistKey, Refresh)
                tinsert(itemPool, row)
            end
        end

        container.Refresh = Refresh
        Refresh()

        return container
    end

    -- ========== RESET PAGE BUTTON (top right) ==========
    if GUI.CreateResetOnlyButton then
        local resetBtn = GUI.CreateResetOnlyButton(parent, L["Aura Blacklist"], function()
            if DF.db then
                DF.db.auraBlacklist = { buffs = {}, debuffs = {} }
                if pageRef._buffWidget and pageRef._buffWidget.Refresh then pageRef._buffWidget:Refresh() end
                if pageRef._debuffWidget and pageRef._debuffWidget.Refresh then pageRef._debuffWidget:Refresh() end
                if DF.RefreshAllVisibleFrames then DF:RefreshAllVisibleFrames() end
                print("|cff00ff00DandersFrames:|r " .. L["Aura Blacklist reset to defaults."])
            end
        end, L["This will clear all of your custom blacklist toggles."])
        resetBtn:SetPoint("TOPRIGHT", -10, -10)
    end

    -- ========== CURATED LIST NOTICE ==========
    local noticeBanner = GUI:CreateInfoBanner(parent, {
        tone = "info",
        text = L["This is a curated list selected by Blizzard. Additional spells cannot be added as these are the only spells Blizzard has allowed. If more are permitted in the future, they will be added to this list."],
    })
    noticeBanner:SetPoint("TOPLEFT", 10, -10)
    noticeBanner:SetPoint("RIGHT", -135, 0)

    -- ========== DESCRIPTION ==========
    local desc = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    desc:SetPoint("TOPLEFT", noticeBanner, "BOTTOMLEFT", 0, -8)
    desc:SetPoint("RIGHT", -10, 0)
    desc:SetJustifyH("LEFT")
    desc:SetText(L["Hide specific buffs and debuffs from your frames. Click a spell to toggle blacklisting. Blacklisted auras will not appear on buff bars or Aura Designer indicators."])
    desc:SetTextColor(0.6, 0.6, 0.6)

    -- ========== CLASS DROPDOWN ==========
    -- Anchored to desc's BOTTOMLEFT (which itself trails noticeBanner) so this
    -- block shifts down when the banner wraps to multiple lines.
    --
    -- The AUTO entry's display text reflects the player's detected class, so the
    -- options table is rebuilt fresh each time the menu opens (opts.optionsFunc)
    -- and whenever the page refreshes (page._updateDropdownText), keeping the
    -- "Auto (CLASS)" label current. selectedClass is read/written via
    -- customGet/customSet so the same upvalue + buff-widget refresh is preserved.
    local function BuildClassOptions()
        local opts = {
            ["AUTO"] = { text = nil },  -- text filled below (dynamic)
            _order = { "AUTO" },
        }
        local playerClass = GetPlayerClass()
        local playerClassName = DF.AuraBlacklist and DF.AuraBlacklist.ClassNames
            and DF.AuraBlacklist.ClassNames[playerClass] or playerClass
        opts["AUTO"].text = format(L["Auto (%s)"], playerClassName or L["Unknown"])

        if DF.AuraBlacklist and DF.AuraBlacklist.ClassOrder then
            for _, classToken in ipairs(DF.AuraBlacklist.ClassOrder) do
                local className = DF.AuraBlacklist.ClassNames
                    and DF.AuraBlacklist.ClassNames[classToken] or classToken
                opts[classToken] = { text = className }
                tinsert(opts._order, classToken)
            end
        end
        return opts
    end

    local dropdownContainer = GUI:CreateDropdown(
        parent,
        L["Class"],
        BuildClassOptions(),
        nil, nil,
        nil,  -- callback (handled in customSet)
        function() return selectedClass end,
        function(value)
            selectedClass = value
            if page._buffWidget then page._buffWidget:Refresh() end
        end,
        { optionsFunc = BuildClassOptions }
    )
    dropdownContainer:SetSize(280, 55)
    dropdownContainer:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)

    -- External refresh hook: rebuild options (so AUTO shows the current class)
    -- and resync the opener text. Matches the old _updateDropdownText contract.
    page._updateDropdownText = function()
        dropdownContainer:RebuildOptions(BuildClassOptions())
    end
    page._updateDropdownText()

    -- ========== BUFF BLACKLIST WIDGET ==========
    local buffWidget = CreateSpellListWidget(
        dropdownContainer, -10, L["BUFF BLACKLIST"],
        GetAllBuffs, "buffs", buffItemPool
    )
    page._buffWidget = buffWidget

    -- ========== DEBUFF BLACKLIST WIDGET ==========
    local debuffWidget = CreateSpellListWidget(
        buffWidget, -20, L["DEBUFF BLACKLIST"],
        GetAllDebuffs, "debuffs", debuffItemPool
    )
    page._debuffWidget = debuffWidget
end
