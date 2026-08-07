-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames

-- ============================================================
-- DANDERSFRAMES SEARCH SYSTEM
-- Provides searchable settings with inline editable results
-- ============================================================

local Search = {}
DF.Search = Search

local L = DF.L

-- ============================================================
-- UI CONSTANTS (match GUI styling)
-- ============================================================
local C_BACKGROUND = {r = 0.11, g = 0.11, b = 0.11, a = 0.98}
local C_BORDER     = {r = 0, g = 0, b = 0, a = 1}
local C_ACCENT     = {r = 0.2, g = 0.6, b = 1.0, a = 1}
local C_RAID       = {r = 1.0, g = 0.4, b = 0.2, a = 1}

-- Result-card geometry. The control's own height is NOT here on purpose -- it
-- comes from the widget's preferredHeight (GUI.RowHeight owns that slot). These
-- are only the card's own chrome: the breadcrumb strip above the control, and
-- the padding around it.
local CARD_PAD_X     = 10
local CARD_CONTENT_Y = 28   -- top of the control, below the breadcrumb button
local CARD_CHROME    = 38   -- breadcrumb strip + top and bottom padding

-- ★ A RESULT CARD IS A SETTINGS BOX, so it is exactly as wide as one. 280 is what
-- GUI:CreateSettingsGroup builds (`group:SetSize(width or 280, 10)`, Sections.lua) and
-- CARD_PAD_X below is that group's own `padding or 10` -- so the control inside a card
-- lands on 280 - 2*10 = 260, which is precisely GUI:GroupInnerWidth. A search hit is
-- therefore the same size as the thing it takes you to, by construction rather than by a
-- second number that has to be kept in step.
--
-- The results panel spans the whole content area (about two of these side by side), and
-- letting a card have all of it was the problem: a slider stretched across the full width
-- reads as a different control from the same slider on its page.
local CARD_MAX_W = 280

-- Debounce before a keystroke turns into a rebuild. Every result is a real settings
-- widget, so an un-debounced OnTextChanged built the whole result set once PER LETTER --
-- typing "frame" meant five full builds of ~159 cards.
local SEARCH_DEBOUNCE = 0.25

-- The empty-results prompt. A function, not a constant: L is populated at load
-- and this file's locals are evaluated then too, so reading it lazily keeps the
-- string correct if the locale table is finished after this file runs.
local function EmptyMessage()
    return L["No settings found.\nTry different keywords."]
end

local function GetThemeColor()
    -- Follow the active mode theme (party purple / raid orange) so the whole
    -- search surface matches the rest of the GUI. Search used to pin its own blue
    -- on the sliders, dropdowns and breadcrumb while the header followed the
    -- theme; that half-and-half state read as a bug rather than as identity, so
    -- the controls now inherit the theme like every other page (Krathe,
    -- 2026-08-07). C_ACCENT survives only as the party-side fallback below, for a
    -- GUI too early in its bootstrap to answer.
    if DF.GUI and DF.GUI.GetThemeColor then return DF.GUI.GetThemeColor() end
    if DF.GUI and DF.GUI.SelectedMode == "raid" then return C_RAID else return C_ACCENT end
end

local function CreateBackdrop(frame, bgAlpha)
    -- Delegates to the shared GUI backdrop so search chrome follows the rest of
    -- the addon (and inherits pixel-grid snapping). Only the alpha is local.
    DF.GUI:CreateElementBackdrop(frame, {
        inset       = 1,
        bgColor     = { C_BACKGROUND.r, C_BACKGROUND.g, C_BACKGROUND.b,
                        bgAlpha or C_BACKGROUND.a },
        borderColor = { C_BORDER.r, C_BORDER.g, C_BORDER.b, C_BORDER.a },
    })
end

-- ============================================================
-- SEARCH REGISTRY
-- ============================================================
Search.Registry = {}
Search.CurrentTab = nil
Search.CurrentSection = nil
Search.RegistryBuilt = false

-- ============================================================
-- CONTEXT TRACKING
-- ============================================================
function Search:SetCurrentTab(tabName, tabLabel)
    self.CurrentTab = tabName
    self.CurrentTabLabel = tabLabel
    self.CurrentSection = nil
end

function Search:SetCurrentSection(sectionName)
    self.CurrentSection = sectionName
end

-- ============================================================
-- REGISTRATION FUNCTIONS
-- Now stores all metadata needed to recreate widgets
-- ============================================================
local registrationId = 0

function Search:Register(entry)
    if self.RegistryBuilt then
        return entry
    end
    
    -- Allow registration if we have either a string dbKey OR a searchKey for custom widgets
    local hasValidKey = (entry.dbKey and type(entry.dbKey) == "string") or 
                        (entry.searchKey and type(entry.searchKey) == "string")
    
    if not hasValidKey then
        return entry
    end
    
    -- Get current mode and check if this setting exists in that mode's defaults
    local currentMode = DF.GUI and DF.GUI.SelectedMode or "party"
    local defaults = (currentMode == "raid") and DF.RaidDefaults or DF.PartyDefaults
    
    -- If entry has a dbKey, check if it exists in the current mode's defaults
    -- Skip settings that don't exist for the current mode
    if entry.dbKey and type(entry.dbKey) == "string" and defaults then
        if defaults[entry.dbKey] == nil then
            -- This setting doesn't exist in the current mode's defaults, skip it
            return entry
        end
    end
    
    -- Specific exceptions: settings that should only appear in one mode
    -- Add dbKeys here that should be excluded from search in the opposite mode
    local partyOnlySettings = {
        -- Settings that should only appear in party mode
    }
    local raidOnlySettings = {
        -- Settings that should only appear in raid mode
        ["hideBlizzardRaidFrames"] = true,
    }
    
    if currentMode == "party" and entry.dbKey and raidOnlySettings[entry.dbKey] then
        return entry
    end
    if currentMode == "raid" and entry.dbKey and partyOnlySettings[entry.dbKey] then
        return entry
    end
    
    registrationId = registrationId + 1
    entry.id = registrationId
    entry.tab = self.CurrentTab
    entry.tabLabel = self.CurrentTabLabel
    entry.section = self.CurrentSection or "General"
    -- Store the current mode (party/raid) for filtering search results
    entry.mode = currentMode
    
    -- Auto-generate keywords from label
    if entry.label then
        entry.keywords = entry.keywords or {}
        for word in string.gmatch(entry.label:lower(), "%w+") do
            if #word > 2 then
                table.insert(entry.keywords, word)
            end
        end
    end
    
    if entry.section then
        for word in string.gmatch(entry.section:lower(), "%w+") do
            if #word > 2 then
                table.insert(entry.keywords, word)
            end
        end
    end
    
    if entry.tab then
        table.insert(entry.keywords, entry.tab:lower())
    end
    
    table.insert(self.Registry, entry)
    return entry
end

-- Link a page's widget to the search entry it registered.
--
-- Tooltips are the reason this exists. A page sets `container.tooltip` AFTER the
-- factory returns, so it cannot be captured at registration time -- but a live
-- reference can be, and CreateResultWidget reads `.tooltip` off it when it builds
-- the row. That keeps one source of truth: the result shows exactly the tooltip
-- the real setting shows, with nothing duplicated into the registry.
--
-- Safe against a nil searchEntry: registration returns early for keyless entries
-- and for anything registered after the registry was built.
function Search:LinkSourceWidget(container)
    if container and container.searchEntry then
        container.searchEntry.sourceWidget = container
    end
end

function Search:InvalidateRegistry()
    self.RegistryBuilt = false
end

function Search:RefreshIfActive()
    -- If search results are currently shown and there's a search query, refresh the results
    if self.ResultsPanel and self.ResultsPanel:IsShown() and self.SearchBar then
        local query = self.SearchBar.editbox:GetText()
        if query and query ~= "" then
            -- Don't refresh during combat
            if not InCombatLockdown() then
                self:ShowResults(query)
            end
        end
    end
end

function Search:EnsureRegistry()
    local currentMode = DF.GUI and DF.GUI.SelectedMode or "party"
    -- Rebuild registry if it wasn't built yet, is empty, or was built for a different mode
    if not self.RegistryBuilt or #self.Registry == 0 or self.BuiltForMode ~= currentMode then
        self:BuildFullRegistry()
    end
end

function Search:BuildFullRegistry()
    self.Registry = {}
    registrationId = 0
    
    if not DF.GUI or not DF.GUI.Pages then 
        return 
    end
    
    local originalTab = DF.GUI.CurrentPageName
    
    -- Store the mode we're building for
    self.BuiltForMode = DF.GUI.SelectedMode
    
    for tabName, page in pairs(DF.GUI.Pages) do
        self:SetCurrentTab(tabName, page.tabLabel or tabName)
        self.CurrentSection = nil
        
        local wasShown = page:IsShown()
        
        if page.Refresh then
            page:Refresh()
        end
        
        if not wasShown then
            page:Hide()
        end
    end
    
    if originalTab and DF.GUI.Pages[originalTab] then
        DF.GUI.Pages[originalTab]:Show()
        if DF.GUI.Pages[originalTab].RefreshStates then
            DF.GUI.Pages[originalTab]:RefreshStates()
        end
    end
    
    self.RegistryBuilt = true
end

-- ============================================================
-- KEYWORD ALIASES
-- ============================================================
Search.KeywordAliases = {
    -- Transparency related
    ["transparency"] = {"alpha", "opacity", "fade"},
    ["alpha"] = {"transparency", "opacity", "fade"},
    ["opacity"] = {"alpha", "transparency", "fade"},
    ["fade"] = {"alpha", "transparency", "opacity"},
    
    -- Size related
    ["size"] = {"width", "height", "scale", "thickness"},
    ["big"] = {"scale", "size", "large"},
    ["small"] = {"scale", "size"},
    
    -- Position related
    ["position"] = {"anchor", "offset", "location"},
    ["move"] = {"position", "anchor", "offset"},
    ["location"] = {"position", "anchor"},
    
    -- Color related
    ["color"] = {"colour", "rgb", "tint"},
    ["colour"] = {"color", "rgb", "tint"},
    
    -- Text related
    ["text"] = {"font", "label"},
    ["font"] = {"text", "typeface"},
    
    -- Visibility related
    ["hide"] = {"show", "visible", "hidden", "display"},
    ["show"] = {"hide", "visible", "display"},
    ["visible"] = {"hide", "show", "hidden"},
    
    -- Bar related
    ["bar"] = {"health", "resource", "power", "absorb"},
    ["health"] = {"hp", "life"},
    
    -- Icon related (NOTE: buff and debuff are NOT aliases of each other)
    ["icon"] = {"aura", "role", "leader"},
    ["aura"] = {"icon"},
    
    -- Frame related
    ["frame"] = {"unit", "party", "raid", "layout"},
    ["unit"] = {"frame", "player", "target"},
    
    -- Group label related
    ["label"] = {"group", "text", "number"},
    ["group"] = {"raid", "label"},
}

-- ============================================================
-- WORD STEMMING
-- Strips common suffixes so "buff" matches "buffs" equally
-- ============================================================
function Search:StemWord(word)
    if not word or #word < 3 then return word end
    
    word = word:lower()
    
    -- Remove common plural/verb suffixes
    -- Order matters - check longer suffixes first
    if word:sub(-3) == "ies" and #word > 4 then
        return word:sub(1, -4) .. "y"  -- "entries" -> "entry"
    elseif word:sub(-2) == "es" and #word > 3 then
        local stem = word:sub(1, -3)
        -- Handle cases like "boxes" -> "box", "classes" -> "class"
        if word:sub(-3, -3):match("[sxz]") or word:sub(-4, -3) == "ch" or word:sub(-4, -3) == "sh" then
            return stem
        end
        return word:sub(1, -2)  -- Just remove 's' for other cases
    elseif word:sub(-1) == "s" and #word > 3 and not word:sub(-2, -2):match("[su]") then
        return word:sub(1, -2)  -- "buffs" -> "buff", but not "class" -> "clas"
    elseif word:sub(-3) == "ing" and #word > 5 then
        return word:sub(1, -4)  -- "scaling" -> "scal"
    elseif word:sub(-2) == "ed" and #word > 4 then
        return word:sub(1, -3)  -- "enabled" -> "enabl"
    end
    
    return word
end

-- Check if two words match (considering stemming)
function Search:WordsMatch(word1, word2)
    if not word1 or not word2 then return false end
    
    word1 = word1:lower()
    word2 = word2:lower()
    
    -- Direct match
    if word1 == word2 then return true end
    
    -- Stemmed match
    local stem1 = self:StemWord(word1)
    local stem2 = self:StemWord(word2)
    
    if stem1 == stem2 then return true end
    
    -- One contains the other's stem (for partial matching)
    if stem1:find(stem2, 1, true) or stem2:find(stem1, 1, true) then
        return true
    end
    
    return false
end

-- Check if a word appears in text (with stemming support)
-- Returns: found (bool), isWholeWord (bool), isPartOfAnotherWord (bool)
function Search:WordInText(word, text)
    if not word or not text then return false, false, false end
    
    word = word:lower()
    text = text:lower()
    local stemmedWord = self:StemWord(word)
    
    -- First, check each word in the text individually
    for textWord in text:gmatch("%w+") do
        local stemmedTextWord = self:StemWord(textWord)
        
        -- Exact match or stemmed match of a whole word
        if textWord == word or stemmedTextWord == stemmedWord then
            return true, true, false
        end
        
        -- Check if search word is contained WITHIN this text word (e.g., "buff" in "debuff")
        -- This is a partial match and should be penalized
        if #textWord > #word and textWord:find(word, 1, true) then
            -- It's a substring of a larger word - this is NOT a good match
            -- "buff" found in "debuff" should return found=true, isWholeWord=false, isPartOfAnotherWord=true
            return true, false, true
        end
    end
    
    return false, false, false
end

-- ============================================================
-- SEARCH FUNCTION
-- Improved scoring: exact matches >> partial matches >> aliases
-- Now with stemming support
-- ============================================================
function Search:Find(query)
    if not query or query == "" then return {} end
    
    self:EnsureRegistry()
    
    query = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if #query < 2 then return {} end
    
    local results = {}
    local queryWords = {}
    local queryWordsStemmed = {}
    local numQueryWords = 0
    
    -- Split query into individual words and their stems
    for word in string.gmatch(query, "%w+") do
        table.insert(queryWords, word)
        table.insert(queryWordsStemmed, self:StemWord(word))
        numQueryWords = numQueryWords + 1
    end
    
    -- Build expanded query with aliases (but track which are exact vs aliases)
    local exactWords = {}      -- Words the user actually typed (and stems)
    local aliasWords = {}      -- Words added via aliases (lower priority)
    
    for i, word in ipairs(queryWords) do
        exactWords[word] = true
        exactWords[queryWordsStemmed[i]] = true  -- Also add stemmed version
        
        if self.KeywordAliases[word] then
            for _, alias in ipairs(self.KeywordAliases[word]) do
                if not exactWords[alias] then
                    aliasWords[alias] = true
                end
            end
        end
        -- Check aliases for stemmed word too
        if self.KeywordAliases[queryWordsStemmed[i]] then
            for _, alias in ipairs(self.KeywordAliases[queryWordsStemmed[i]]) do
                if not exactWords[alias] then
                    aliasWords[alias] = true
                end
            end
        end
    end
    
    for _, entry in ipairs(self.Registry) do
        -- All entries in registry are for the current mode (registry is rebuilt when mode changes)
        local score = 0
        local exactWordsMatched = 0
        
        local labelLower = entry.label and entry.label:lower() or ""
        local sectionLower = entry.section and entry.section:lower() or ""
        local dbKeyLower = (entry.dbKey and type(entry.dbKey) == "string") and entry.dbKey:lower() or ""
        
        -- ===========================================
        -- HIGHEST PRIORITY: Full query match in label
        -- "buff scale" found exactly in "Buff Scale" = huge bonus
        -- ===========================================
        if labelLower:find(query, 1, true) then
            score = score + 1000
            exactWordsMatched = numQueryWords
        else
            -- ===========================================
            -- Check each query word against the label
            -- ===========================================
            for i, word in ipairs(queryWords) do
                local found, isWholeWord, isPartOfAnotherWord = self:WordInText(word, labelLower)
                
                if found then
                    if isPartOfAnotherWord then
                        -- "buff" found inside "debuff" - very low score, almost a non-match
                        score = score + 5
                    elseif isWholeWord or #word >= 4 then
                        score = score + 200
                        exactWordsMatched = exactWordsMatched + 1
                    else
                        score = score + 100
                        exactWordsMatched = exactWordsMatched + 1
                    end
                end
            end
            
            -- ===========================================
            -- Lower priority: Alias word matches in label
            -- ===========================================
            for word in pairs(aliasWords) do
                local found, isWholeWord, isPartOfAnotherWord = self:WordInText(word, labelLower)
                if found and not isPartOfAnotherWord then
                    score = score + 30
                end
            end
        end
        
        -- ===========================================
        -- BONUS: Multiple query words matched = more relevant
        -- ===========================================
        if numQueryWords > 1 and exactWordsMatched >= numQueryWords then
            score = score + 500
        elseif numQueryWords > 1 and exactWordsMatched > 1 then
            score = score + (exactWordsMatched * 100)
        end
        
        -- ===========================================
        -- MEDIUM PRIORITY: Section name matches
        -- ===========================================
        for _, word in ipairs(queryWords) do
            local found, isWholeWord, isPartOfAnotherWord = self:WordInText(word, sectionLower)
            if found and not isPartOfAnotherWord then
                score = score + 50
            elseif found and isPartOfAnotherWord then
                score = score + 5  -- Minimal score for partial match
            end
        end
        
        -- ===========================================
        -- LOWER PRIORITY: Keyword matches
        -- ===========================================
        if entry.keywords then
            for _, keyword in ipairs(entry.keywords) do
                for _, word in ipairs(queryWords) do
                    if self:WordsMatch(keyword, word) then
                        score = score + 40
                    elseif keyword:find(word, 1, true) and #keyword > #word then
                        -- Word is substring of keyword - low score
                        score = score + 5
                    end
                end
                for alias in pairs(aliasWords) do
                    if self:WordsMatch(keyword, alias) then
                        score = score + 10
                    end
                end
            end
        end
        
        -- ===========================================
        -- LOWEST PRIORITY: dbKey matches
        -- ===========================================
        if dbKeyLower ~= "" then
            for _, word in ipairs(queryWords) do
                if dbKeyLower:find(word, 1, true) then
                    score = score + 25
                end
            end
        end
        
        if score > 0 then
            table.insert(results, {entry = entry, score = score})
        end
    end
    
    table.sort(results, function(a, b) return a.score > b.score end)
    
    local finalResults = {}
    for _, result in ipairs(results) do
        table.insert(finalResults, result.entry)
    end
    
    return finalResults
end

-- ============================================================
-- INLINE WIDGET FACTORIES
-- Create actual editable widgets in search results
-- ============================================================

function Search:CreateInlineCheckbox(parent, entry)
    -- A custom checkbox has no dbKey to bind, so there is nothing for the shared
    -- builder to drive -- show the label and point at the real page instead.
    if entry.isCustom or not entry.dbKey then
        local container = CreateFrame("Frame", nil, parent)
        container:SetSize(340, 30)
        container.preferredHeight = DF.GUI.RowHeight.checkbox

        local text = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        text:SetPoint("LEFT", 0, 0)
        text:SetText(entry.label)
        local ct = DF.GUI.Colors.text
        text:SetTextColor(ct.r, ct.g, ct.b)

        local note = container:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        note:SetPoint("LEFT", text, "RIGHT", 10, 0)
        note:SetText(L["(click header to edit)"])
        local cd = DF.GUI.Colors.textDim
        note:SetTextColor(cd.r, cd.g, cd.b)

        return container
    end

    -- Delegate to the shared checkbox builder, exactly as the slider and dropdown
    -- already do. It brings the themed box, the factory row height, the override
    -- indicators and the label-only tooltip -- all of which the hand-rolled copy
    -- here lacked. Re-registration is not a concern: Search:Register early-returns
    -- once RegistryBuilt is set, and Find() sets it before any result is built.
    local db = DF.db[DF.GUI.SelectedMode]
    return DF.GUI:CreateCheckbox(parent, entry.label, db, entry.dbKey, entry.callback)
end

function Search:CreateInlineSlider(parent, entry)
    -- Delegate to the shared slider builder so the inline search editor stays in
    -- sync with the canonical slider (drag/throttle/profile-override behaviour).
    -- db[dbKey] maps directly onto CreateSlider's dbTable/dbKey get/set, and
    -- entry.callback onto its callback.
    --
    -- accentColor is left nil ON PURPOSE: CreateSlider falls back to
    -- GetThemeColor(), so the thumb and fill track party purple / raid orange like
    -- every other slider. This used to pin Search's blue, which read as a bug
    -- rather than as identity once the results header started following the theme.
    local db = DF.db[DF.GUI.SelectedMode]
    local minVal = entry.minVal or 0
    local maxVal = entry.maxVal or 100
    local step = entry.step or 1

    -- Returns CreateSlider's container Frame (exposes .slider). The caller only
    -- repositions it via :SetPoint, so the Frame return shape is preserved.
    return DF.GUI:CreateSlider(parent, entry.label, minVal, maxVal, step,
        db, entry.dbKey, entry.callback)
end

function Search:CreateInlineColorPicker(parent, entry)
    -- Delegate to the shared colour picker. The copy that used to live here drove
    -- ColorPickerFrame itself, and had drifted from the canonical one in ways that
    -- mattered: it fired the change callbacks on the spurious swatchFunc Blizzard
    -- raises during setup (so merely OPENING the picker committed an override and
    -- ran a full refresh), and it rebuilt db[dbKey] as a fresh table on every
    -- change rather than mutating in place. The shared builder handles both, plus
    -- the themed swatch, the factory row height and the label-only tooltip.
    local db = DF.db[DF.GUI.SelectedMode]
    return DF.GUI:CreateColorPicker(parent, entry.label, db, entry.dbKey,
        entry.hasAlpha, entry.callback)
end

function Search:CreateInlineDropdown(parent, entry)
    -- Delegate to the shared dropdown builder so the inline search editor stays in
    -- sync with the canonical dropdown (menu/option-order/profile-override
    -- behaviour). db[dbKey] maps directly onto CreateDropdown's dbTable/dbKey
    -- get/set, and entry.callback onto its callback. entry.values is the same
    -- keyed value->display table (with optional _order) that was registered, so
    -- it passes straight through as the builder's options arg.
    local db = DF.db[DF.GUI.SelectedMode]
    local values = entry.values or {}

    -- Returns CreateDropdown's container Frame (exposes :UpdateText / :SetEnabled /
    -- :RebuildOptions). The caller only repositions it via :SetPoint, so the Frame
    -- return shape is preserved.
    -- NOT inline: inline mode hides the dropdown's own label, but this is a
    -- labeled setting in the search results, so keep the label (matches the
    -- slider/checkbox search widgets). No opts.accent -- the dropdown follows the
    -- mode theme like every other one (see CreateInlineSlider for the why).
    return DF.GUI:CreateDropdown(parent, entry.label, values,
        db, entry.dbKey, entry.callback)
end

-- ============================================================
-- CREATE RESULT WIDGET WITH INLINE EDITOR
-- ============================================================
function Search:CreateResultWidget(parent, entry, index)
    local widget = CreateFrame("Frame", nil, parent)
    -- Capped at one settings-box width; the panel is wider than that, and a card that
    -- used all of it did not read as a settings box any more.
    local cardW = math.min((parent:GetWidth() or CARD_MAX_W) - 20, CARD_MAX_W)
    widget:SetSize(cardW, CARD_CHROME + DF.GUI.RowHeight.checkbox)

    -- Card chrome from the shared palette. These were three retyped literals
    -- (0.14 fill, 0.25 border) that matched nothing -- the panel token is the
    -- surface every other card sits on.
    local cP, cB = DF.GUI.Colors.panel, DF.GUI.Colors.border
    CreateBackdrop(widget)
    widget:SetBackdropColor(cP.r, cP.g, cP.b, 1)
    widget:SetBackdropBorderColor(cB.r, cB.g, cB.b, 1)

    -- Clickable Breadcrumb (Tab > Section)
    local tabDisplay = entry.tabLabel or entry.tab or "Unknown"
    local sectionDisplay = entry.section or ""

    -- Create breadcrumb as a styled clickable button (shared GUI chrome). No
    -- accent override -- StyleButton falls back to the mode theme, so the
    -- breadcrumb wash matches the controls below it.
    local breadcrumb = CreateFrame("Button", nil, widget, "BackdropTemplate")
    breadcrumb:SetPoint("TOPLEFT", 8, -5)

    local fullPath = tabDisplay .. (sectionDisplay ~= "" and ("  >  " .. sectionDisplay) or "")
    DF.GUI:StyleButton(breadcrumb, {
        height = 18,
        text = fullPath,
        align = "left",
        leftPad = 8,
    })
    local breadcrumbText = breadcrumb.Text

    -- Size the button to fit the text with padding
    local textWidth = breadcrumbText:GetStringWidth()
    breadcrumb:SetWidth(textWidth + 24)

    -- Tooltip on hover (the accent wash/border hover is handled by StyleButton).
    --
    -- ⚠ TITLE PLUS A LINE, which is the house shape -- see BindingEditor and the AD
    -- editor, and ResolveTooltipSpec, which builds { title = label, lines = { desc } }
    -- for every settings widget. This passed a bare title and so rendered as a lone
    -- floating string with no body, which is why it did not look like the rest of them.
    --
    -- "Show me" rather than "Go to <tab>": the button's own label already spells the
    -- destination out ("Frame > Frame Size"), so repeating it in the title said nothing
    -- twice. The verb is also the honest one now that the target pulses on arrival --
    -- FlashWidget's own comment describes itself as the "show me" highlight.
    breadcrumb:HookScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = L["Show me"],
            lines = { L["Open this setting's own page and highlight it."] },
        })
    end)
    breadcrumb:HookScript("OnLeave", function()
        DF.GUI:HideTooltip()
    end)

    -- Click to navigate
    breadcrumb:SetScript("OnClick", function()
        Search:NavigateToTab(entry.tab, entry.section)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)
    
    -- Create the actual editable widget based on type
    local inlineWidget

    if entry.widgetType == "checkbox" then
        inlineWidget = self:CreateInlineCheckbox(widget, entry)
    elseif entry.widgetType == "slider" then
        inlineWidget = self:CreateInlineSlider(widget, entry)
    elseif entry.widgetType == "colorpicker" then
        inlineWidget = self:CreateInlineColorPicker(widget, entry)
    elseif entry.widgetType == "dropdown" then
        inlineWidget = self:CreateInlineDropdown(widget, entry)
    end

    -- ☠ Take the slot height from the WIDGET, never from a number typed here.
    -- Every shared builder stamps container.preferredHeight from GUI.RowHeight,
    -- which owns the slot for its type (see GUI.RowHeight). The four literals
    -- that used to live here -- 30 checkbox, 50 slider, 30 colourpicker, 55
    -- dropdown -- disagreed with that table on all four counts (35/46/38/54),
    -- which is why the rows read as too tall and unevenly spaced against the
    -- real settings pages. Reading preferredHeight means a future change to
    -- GUI.RowHeight reaches the search results for free.
    local widgetHeight = (inlineWidget and inlineWidget.preferredHeight)
        or DF.GUI.RowHeight.checkbox
    
    if inlineWidget then
        inlineWidget:SetPoint("TOPLEFT", CARD_PAD_X, -CARD_CONTENT_Y)
        -- The shared builders anchor by two corners in a real page column; here the card
        -- IS the column. No separate cap needed: the card is already one settings box
        -- wide, so this lands on GroupInnerWidth (280 - 2*10 = 260) on its own.
        inlineWidget:SetWidth(widget:GetWidth() - CARD_PAD_X * 2)
        -- Tooltip text lives on the page's widget, not on the search entry --
        -- ResolveTooltipSpec reads .tooltip off the container it was attached to.
        -- Forward it so a result explains itself exactly as the real setting does.
        local src = entry.sourceWidget
        if src and src.tooltip ~= nil then
            inlineWidget.tooltip = src.tooltip
        end
    end

    local cardHeight = CARD_CHROME + widgetHeight
    widget:SetHeight(cardHeight)

    widget.entry = entry
    widget.inlineWidget = inlineWidget
    widget.calculatedHeight = cardHeight
    return widget
end

-- ☠ CARDS ARE CACHED AND REUSED. Building one is expensive -- it is a REAL settings
-- widget, so a single card is a frame, a breadcrumb button, the control's own container,
-- its check button / slider / swatch, its override indicators and a tooltip hit frame:
-- roughly six to ten frames. The old code built every result fresh on every call and then
-- did `SetParent(nil)` on the previous set, which does not free anything -- a WoW frame,
-- once created, is never really reclaimed. Combined with an un-debounced OnTextChanged
-- that meant typing one five-letter word over ~159 results stranded several thousand live
-- frames, each still carrying scripts. That is the "everything is sluggish until I
-- reload" -- it was not the search being slow, it was the whole UI carrying the wreckage.
--
-- The key is (mode, widgetType, dbKey) rather than the registry's entry.id, on purpose:
--   * ids are reassigned whenever the registry rebuilds, so they are not stable;
--   * the shared builders bind dbTable/dbKey in CLOSURES at creation, so a card can never
--     be re-pointed at a different setting -- the cache has to be per setting, not a
--     generic pool;
--   * including the mode is what keeps that safe. `db` is captured as
--     DF.db[SelectedMode] at build time, so a party card must never be handed back for
--     raid. Different mode, different key, different card.
-- Total cards built is therefore bounded by the number of DISTINCT settings the user has
-- ever seen results for, once each, instead of growing without limit.
local function cardCacheKey(entry)
    local mode = (DF.GUI and DF.GUI.SelectedMode) or "party"
    return mode .. "\0" .. tostring(entry.widgetType) .. "\0" .. tostring(entry.dbKey or entry.label)
end

function Search:AcquireResultWidget(parent, entry, index)
    local panel = self.ResultsPanel
    panel.cardCache = panel.cardCache or {}
    local key = cardCacheKey(entry)

    -- ☠ THE TABLE IDENTITY IS PART OF THE CONTRACT, not just the mode name. DF.db is
    -- REASSIGNED on a profile switch (Core/Profile.lua), and the shared builders captured
    -- the OLD table in their closures -- so a card cached before the switch would happily
    -- write the previous profile's settings while the user looks at the new one. The mode
    -- in the key cannot catch that, because the mode name has not changed. Compare the
    -- actual table and rebuild if it moved.
    local liveDB = DF.db and DF.db[(DF.GUI and DF.GUI.SelectedMode) or "party"]

    local widget = panel.cardCache[key]
    if widget and widget.dfBoundDB ~= liveDB then
        -- Profile switched under us. Drop it; nothing here can be re-pointed, because the
        -- binding lives in closures. (The old frame cannot be freed -- WoW frames never
        -- are -- but a profile switch is a rare, deliberate act, unlike a keystroke.)
        widget:Hide()
        panel.cardCache[key] = nil
        widget = nil
    end

    if widget then
        -- Refresh what can legitimately have moved since it was built. The displayed
        -- VALUE needs no help -- every shared builder re-reads its db on OnShow (see
        -- CreateCheckbox's container:SetScript("OnShow", UpdateState)) -- but the entry
        -- object itself is new after a registry rebuild, so re-point the tooltip source.
        widget.entry = entry
        local inline, src = widget.inlineWidget, entry.sourceWidget
        if inline and src and src.tooltip ~= nil then
            inline.tooltip = src.tooltip
        end
        return widget
    end

    widget = self:CreateResultWidget(parent, entry, index)
    widget.dfBoundDB = liveDB
    panel.cardCache[key] = widget
    return widget
end

-- ============================================================
-- NAVIGATION
-- ============================================================
function Search:NavigateToTab(tabName, sectionName)
    if not tabName then return end

    -- Clear search. SelectTab hides the results itself, but the box keeps its text
    -- otherwise, and a stale query sitting in a hidden panel reads as still-searching.
    if self.SearchBar and self.SearchBar.editbox then
        self.SearchBar.editbox:SetText("")
        self.SearchBar.editbox:ClearFocus()
    end
    self:HideResults()

    -- ☠ DELEGATE TO THE SHARED LINK ACTION, do not hand-roll the jump. This used to do
    -- its own Tabs[name]:Click() plus a timed ScrollToSection -- which scrolled correctly
    -- and then never flashed, so a search result landed you on the right page with no
    -- indication of WHICH setting you had come for, while every other cross-link in the
    -- GUI pulses its target. GUI:LinkToSetting is that behaviour, and it already calls
    -- this file's own ScrollToSection to do the scrolling half; it also owns the two
    -- timings (0.12 for the tab to build, 0.05 for the scroll to settle) that the
    -- hand-rolled copy had guessed at differently.
    --
    -- ⚠ Guard the function, not the table: LinkToSetting lives in GUI/Sections.lua and a
    -- load-order slip would otherwise be a silent dead breadcrumb. Warn rather than fall
    -- back to a worse copy of the same thing.
    if DF.GUI and DF.GUI.LinkToSetting then
        DF.GUI:LinkToSetting({
            page    = tabName,
            section = (sectionName ~= "" and sectionName) or nil,
            -- ⚠ BORDER ONLY -- both flags are required. FlashWidget's fill is opt-OUT
            -- (`opts.fill ~= false`), so passing border alone would outline AND wash it.
            -- A search lands you on a whole section, which is a large target; the filled
            -- pulse over that much area is heavy, and the outline reads better at that
            -- size (Krathe, 2026-08-07).
            flash   = { fill = false, border = true },
        })
    else
        DF:DebugWarn("SEARCH", "LinkToSetting unavailable — breadcrumb cannot navigate")
    end
end

function Search:ScrollToSection(tabName, sectionName)
    if not DF.GUI or not DF.GUI.Pages then return end

    local page = DF.GUI.Pages[tabName]
    if not page or not page.children then return end

    -- Find the header matching the section name — either a top-level page child OR one
    -- nested inside a settings group. Grouped pages (e.g. Colors) keep their headers in
    -- group.groupChildren, not directly in page.children, so scan both. When the header
    -- is nested, the whole group IS the section, so return the group to flash (the group
    -- frame is sized to its content in LayoutChildren) — a top-level header returns itself.
    local function matches(widget)
        return widget and widget.GetText and widget:GetText() == sectionName
    end
    local scrollTo, flashTarget
    for _, widget in ipairs(page.children) do
        if matches(widget) then
            scrollTo, flashTarget = widget, widget
            -- A COLLAPSIBLE section is only its header bar; the content sits in
            -- separate page children registered against it (RegisterChild). Two
            -- things follow: expand it if the user had it closed, since scrolling to
            -- hidden content reads as a dead link; and flash that CONTENT rather than
            -- the ~28px bar, because the content is what the link points at.
            if widget.sectionChildren then
                if not widget.expanded and widget.Toggle then widget:Toggle() end
                flashTarget = widget.sectionChildren[1] or widget
            end
        elseif widget.isSettingsGroup and widget.groupChildren then
            for _, entry in ipairs(widget.groupChildren) do
                if matches(entry.widget) then
                    scrollTo, flashTarget = entry.widget, widget   -- flash the whole group/section
                    break
                end
            end
        end
        if flashTarget then break end
    end
    if not flashTarget then return end

    -- Try to scroll the section header into view.
    local widgetTop = scrollTo:GetTop()
    local pageTop = page:GetTop()
    if widgetTop and pageTop then
        local offset = pageTop - widgetTop - 20
        if offset > 0 and page.SetVerticalScroll then
            local maxScroll = page.child:GetHeight() - page:GetHeight()
            page:SetVerticalScroll(math.min(offset, math.max(0, maxScroll)))
        end
    end
    return flashTarget   -- the section (group or header), so GUI:LinkToSetting can flash it
end

-- ============================================================
-- SEARCH BAR
-- ============================================================
function Search:CreateSearchBar(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(150, 28)
    
    CreateBackdrop(frame)
    frame:SetBackdropColor(0, 0, 0, 0.7)
    frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    
    local icon = frame:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("LEFT", 6, 0)
    icon:SetSize(15, 15)
    icon:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\search")
    icon:SetVertexColor(0.72, 0.72, 0.72)

    local editbox = CreateFrame("EditBox", nil, frame)
    editbox:SetPoint("LEFT", 26, 0)
    editbox:SetPoint("RIGHT", -24, 0)
    editbox:SetHeight(20)
    editbox:SetFontObject(DFFontHighlightSmall)
    editbox:SetAutoFocus(false)
    editbox:SetTextInsets(2, 2, 0, 0)
    
    local placeholder = frame:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
    placeholder:SetPoint("LEFT", 26, 0)
    placeholder:SetText(L["Search..."])
    placeholder:SetTextColor(0.5, 0.5, 0.5)
    
    -- Clearing is destructive, so this one overrides the shared white hover with
    -- the soft red every other destructive glyph in the GUI uses.
    local clearBtn = DF.GUI:CreateGlyphButton(frame, {
        texture    = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\close",
        size       = 16,
        color      = { 0.5, 0.5, 0.5 },
        hoverColor = { 1, 0.3, 0.3 },
        onClick    = function()
            editbox:SetText("")
            editbox:ClearFocus()
            Search:HideResults()
        end,
    })
    clearBtn:SetPoint("RIGHT", -4, 0)
    clearBtn:Hide()
    
    editbox:SetScript("OnEditFocusGained", function()
        frame:SetBackdropBorderColor(GetThemeColor().r, GetThemeColor().g, GetThemeColor().b, 1)
        placeholder:Hide()
    end)
    
    editbox:SetScript("OnEditFocusLost", function()
        frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        if editbox:GetText() == "" then
            placeholder:Show()
        end
    end)
    
    editbox:SetScript("OnTextChanged", function(self, userInput)
        local text = self:GetText()
        if text and text ~= "" then
            placeholder:Hide()
            clearBtn:Show()
            if userInput then
                -- Don't search during combat - building registry creates UI elements
                if InCombatLockdown() then
                    Search:CancelQueuedSearch()
                    Search:ShowCombatMessage()
                else
                    -- Debounced: one rebuild after the typing stops, not one per letter.
                    Search:QueueSearch(text)
                end
            end
        else
            if not self:HasFocus() then
                placeholder:Show()
            end
            clearBtn:Hide()
            Search:HideResults()
        end
    end)
    
    editbox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        Search:HideResults()
    end)
    
    editbox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    
    frame.editbox = editbox
    frame.placeholder = placeholder
    frame.clearBtn = clearBtn
    
    self.SearchBar = frame
    return frame
end

-- ============================================================
-- RESULTS PANEL
-- ============================================================
function Search:CreateResultsPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    
    CreateBackdrop(panel)
    -- ⚠ These two calls are not redundant with CreateBackdrop's own colours:
    -- SetBackdrop resets a frame's piece vertex colours, so the fill and border
    -- have to be (re)stated after it. Tokens, not the literals that were here.
    local pB, pBorder = DF.GUI.Colors.background, DF.GUI.Colors.border
    panel:SetBackdropColor(pB.r, pB.g, pB.b, 1)
    panel:SetBackdropBorderColor(pBorder.r, pBorder.g, pBorder.b, 1)
    panel:Hide()
    
    local header = panel:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    header:SetPoint("TOPLEFT", 15, -15)
    header:SetText(L["Search Results"])
    local c = GetThemeColor()
    header:SetTextColor(c.r, c.g, c.b)
    panel.header = header
    
    local countText = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    countText:SetPoint("LEFT", header, "RIGHT", 10, 0)
    countText:SetTextColor(0.6, 0.6, 0.6)
    panel.countText = countText
    
    local noResults = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    noResults:SetPoint("CENTER", panel, "CENTER", 0, 0)
    noResults:SetText(EmptyMessage())
    local cd = DF.GUI.Colors.textDim
    noResults:SetTextColor(cd.r, cd.g, cd.b)
    noResults:Hide()
    panel.noResults = noResults
    
    local scroll = CreateFrame("ScrollFrame", nil, panel, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -45)
    scroll:SetPoint("BOTTOMRIGHT", -30, 10)
    DF.GUI.StyleScrollBar(scroll)

    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(scroll:GetWidth(), 1)
    scroll:SetScrollChild(scrollChild)
    
    panel.scroll = scroll
    panel.scrollChild = scrollChild
    panel.resultWidgets = {}
    
    self.ResultsPanel = panel
    return panel
end

-- ============================================================
-- SHOW/HIDE RESULTS
-- ============================================================
-- Coalesce keystrokes into one rebuild. OnTextChanged fires per character, and each
-- rebuild lays out every result, so without this "frame" cost five full passes over ~159
-- cards -- the visible symptom being the panel lurching as it re-laid itself under the
-- scrollbar while you were still typing or scrolling.
--
-- ⚠ Always store the LATEST query and let the timer read it when it fires, rather than
-- capturing the text in the closure: the timer must render what the box says when it
-- expires, not what it said when the first key was pressed.
function Search:QueueSearch(text)
    self._pendingQuery = text
    if self._searchTimer then return end
    self._searchTimer = C_Timer.NewTimer(SEARCH_DEBOUNCE, function()
        self._searchTimer = nil
        local q = self._pendingQuery
        self._pendingQuery = nil
        -- Re-check combat: the debounce window is long enough to have entered it, and
        -- building results creates frames.
        if q and q ~= "" and not InCombatLockdown() then
            self:ShowResults(q)
        end
    end)
end

function Search:CancelQueuedSearch()
    if self._searchTimer then
        self._searchTimer:Cancel()
        self._searchTimer = nil
    end
    self._pendingQuery = nil
end

function Search:ShowResults(query)
    if not self.ResultsPanel then return end
    
    local results = self:Find(query)
    local panel = self.ResultsPanel
    local scrollChild = panel.scrollChild
    
    -- ⚠ HIDE, never SetParent(nil). These cards are cached and will be shown again; the
    -- old teardown orphaned them instead, which freed nothing and lost the reuse.
    for _, widget in ipairs(panel.resultWidgets) do
        widget:Hide()
    end
    panel.resultWidgets = {}

    local c = GetThemeColor()
    panel.header:SetTextColor(c.r, c.g, c.b)

    if #results == 0 then
        panel.noResults:Show()
        panel.countText:SetText("")
        panel.scroll:Hide()
    else
        panel.noResults:Hide()
        panel.countText:SetText(string.format(L["(%d found)"], #results))
        panel.scroll:Show()

        local yOffset = 0
        for i, entry in ipairs(results) do
            local widget = self:AcquireResultWidget(scrollChild, entry, i)
            -- ClearAllPoints first: a reused card still carries the anchor from wherever
            -- it sat in the previous result set.
            widget:ClearAllPoints()
            widget:SetPoint("TOPLEFT", 5, -yOffset)
            widget:Show()
            table.insert(panel.resultWidgets, widget)
            yOffset = yOffset + (widget.calculatedHeight or 75) + 5
        end

        scrollChild:SetHeight(yOffset + 20)
    end
    
    panel:Show()
    
    if DF.GUI and DF.GUI.Pages then
        for _, page in pairs(DF.GUI.Pages) do
            page:Hide()
        end
    end
end

function Search:HideResults()
    -- ⚠ Kill any debounced rebuild first. Clearing the box or closing the panel must not
    -- be followed a quarter of a second later by a build for a query that is now gone --
    -- that would re-show the results panel over whatever page the user just went back to.
    self:CancelQueuedSearch()
    if self.ResultsPanel then
        self.ResultsPanel:Hide()
        -- Reset the no-results text in case it was changed to the combat message.
        -- ☠ Must restore the SAME string the panel was built with. This used to
        -- put back a different, terser one, and it runs on every hide rather than
        -- only after a combat message -- so the helpful two-line prompt was only
        -- ever seen until the first time search was closed, then gone for the
        -- session. EmptyMessage() is the single source for both.
        if self.ResultsPanel.noResults then
            self.ResultsPanel.noResults:SetText(EmptyMessage())
        end
    end
    
    if DF.GUI and DF.GUI.CurrentPageName and DF.GUI.Pages then
        local currentPage = DF.GUI.Pages[DF.GUI.CurrentPageName]
        if currentPage then
            currentPage:Show()
        end
    end
end

function Search:ShowCombatMessage()
    if not self.ResultsPanel then return end
    
    local panel = self.ResultsPanel
    
    -- Clear existing results.
    -- ⚠ Hide only. SetParent(nil) here would orphan cards that are still in cardCache,
    -- so the next search would hand back a parentless frame that never draws.
    for _, widget in ipairs(panel.resultWidgets) do
        widget:Hide()
    end
    panel.resultWidgets = {}

    -- Show combat message instead of "No results"
    panel.noResults:SetText(L["Search unavailable during combat"])
    panel.noResults:Show()
    panel.countText:SetText("")
    panel.scroll:Hide()
    
    -- Hide current page and show results panel
    if DF.GUI and DF.GUI.CurrentPageName and DF.GUI.Pages then
        local currentPage = DF.GUI.Pages[DF.GUI.CurrentPageName]
        if currentPage then
            currentPage:Hide()
        end
    end
    panel:Show()
end

-- ============================================================
-- REGISTRATION HELPERS
-- Now store all widget metadata
-- ============================================================
function Search:RegisterCheckbox(label, dbKey, keywords, customGetSet, callback)
    return self:Register({
        label = label,
        dbKey = dbKey,
        searchKey = customGetSet and ("custom_" .. label:gsub("%s+", "_"):lower()) or nil,
        widgetType = "checkbox",
        keywords = keywords,
        isCustom = customGetSet or false,
        callback = callback,
    })
end

function Search:RegisterSlider(label, dbKey, minVal, maxVal, step, keywords, callback)
    return self:Register({
        label = label,
        dbKey = dbKey,
        widgetType = "slider",
        minVal = minVal,
        maxVal = maxVal,
        step = step,
        keywords = keywords,
        callback = callback,
    })
end

function Search:RegisterDropdown(label, dbKey, values, keywords, callback)
    return self:Register({
        label = label,
        dbKey = dbKey,
        widgetType = "dropdown",
        values = values,
        keywords = keywords,
        callback = callback,
    })
end

function Search:RegisterColorPicker(label, dbKey, hasAlpha, keywords, callback)
    return self:Register({
        label = label,
        dbKey = dbKey,
        widgetType = "colorpicker",
        hasAlpha = hasAlpha,
        keywords = keywords,
        callback = callback,
    })
end
