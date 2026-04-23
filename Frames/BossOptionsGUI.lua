local addonName, DF = ...

-- ============================================================
-- BOSS FRAMES — NATIVE GUI INTEGRATION
-- Plugs into the main DandersFrames options window as a proper
-- top-level category ("Boss Frames") with sub-pages.
--
-- Called from Options.lua via DF:SetupBossPages(GUI, CreateCategory,
-- CreateSubTab, BuildPage).
--
-- All controls edit DF:GetBossDB() — a shared block that is not
-- split by party/raid mode (boss settings are universal).
-- ============================================================

local GUI_ref
local pairs, ipairs = pairs, ipairs

local function refresh()
    if DF.RefreshBossFrames then DF:RefreshBossFrames() end
end

-- Helper: make boss pages always accessible regardless of party/raid disable
local function whitelistBossPages(GUI)
    GUI.AlwaysAccessiblePages = GUI.AlwaysAccessiblePages or {}
    GUI.AlwaysAccessiblePages["boss_layout"]   = true
    GUI.AlwaysAccessiblePages["boss_bars"]     = true
    GUI.AlwaysAccessiblePages["boss_text"]     = true
    GUI.AlwaysAccessiblePages["boss_castbar"]  = true
    GUI.AlwaysAccessiblePages["boss_auras"]    = true
end

-- 9-point anchor option map (value -> display text). Shared for all
-- text/position dropdowns (container, name, health text, raid target).
local function anchorOpts(L)
    return {
        TOPLEFT     = L["Top Left"]     or "Top left",
        TOP         = L["Top"],
        TOPRIGHT    = L["Top Right"]    or "Top right",
        LEFT        = L["Left"],
        CENTER      = L["Center"],
        RIGHT       = L["Right"],
        BOTTOMLEFT  = L["Bottom Left"]  or "Bottom left",
        BOTTOM      = L["Bottom"],
        BOTTOMRIGHT = L["Bottom Right"] or "Bottom right",
    }
end

function DF:SetupBossPages(GUI, CreateCategory, CreateSubTab, BuildPage)
    GUI_ref = GUI
    local L = DF.L

    whitelistBossPages(GUI)

    -- Mark all boss tabs as "New" — the badge auto-clears per tab once
    -- the user visits it (persisted via DandersFramesDB_v2.seenTabs).
    GUI.NewTabs = GUI.NewTabs or {}
    GUI.NewTabs["boss_layout"]  = true
    GUI.NewTabs["boss_bars"]    = true
    GUI.NewTabs["boss_text"]    = true
    GUI.NewTabs["boss_castbar"] = true
    GUI.NewTabs["boss_auras"]   = true

    -- ========================================
    -- CATEGORY
    -- ========================================
    CreateCategory("boss", L["Boss Frames"] or "Boss Frames")

    -- ========================================
    -- Page: Layout (position, size, portrait, growth)
    -- ========================================
    local pageLayout = CreateSubTab("boss", "boss_layout", L["Layout"])
    BuildPage(pageLayout, function(self, _, Add, AddSpace, AddSyncPoint)
        local db = DF:GetBossDB()

        local g = GUI:CreateSettingsGroup(self.child, 560)
        g:AddWidget(GUI:CreateHeader(self.child, L["Boss Frames"] or "Boss Frames"), 40)
        g:AddWidget(GUI:CreateLabel(self.child,
            L["Configure the boss frames shown on engaged bosses (up to 5). These replace the default Blizzard boss frames."]
            or "Configure the boss frames shown on engaged bosses (up to 5). These replace the default Blizzard boss frames.",
            530), 40)
        Add(g, nil, "both")

        -- Buttons row
        local moverBtn = GUI:CreateButton(self.child, L["Unlock Mover"] or "Unlock / Lock Mover",
            180, 24, function() DF:ToggleBossMover() end)
        Add(moverBtn, 32, 1)
        local testBtn = GUI:CreateButton(self.child, L["Toggle Test Mode"] or "Toggle Test Mode",
            180, 24, function()
                local any
                for i = 1, 5 do if DF.BossFrames and DF.BossFrames[i] and DF.BossFrames[i]._testMode then any = true; break end end
                DF:SetBossTestMode(any and 0 or 3)
            end)
        Add(testBtn, 32, 2)

        AddSyncPoint()

        -- Copy settings from the other mode (Party <-> Raid)
        local curMode = (GUI and GUI.SelectedMode == "raid") and "raid" or "party"
        local otherMode = curMode == "raid" and "party" or "raid"
        local otherLabel = otherMode == "raid" and (L["Raid"] or "Raid") or (L["Party"] or "Party")
        local copyBtn = GUI:CreateButton(self.child,
            format(L["Copy from %s"] or "Copy from %s", otherLabel),
            220, 24,
            function()
                -- Confirm with a popup to avoid accidental overwrite
                if DF.ShowPopupAlert then
                    DF:ShowPopupAlert({
                        title = L["Copy Boss Settings"] or "Copy Boss Settings",
                        message = format(
                            L["This will overwrite all Boss Frame settings for the current mode (%s) with the settings from %s mode. Continue?"]
                            or "This will overwrite all Boss Frame settings for the current mode (%s) with the settings from %s mode. Continue?",
                            curMode, otherMode),
                        buttons = {
                            { label = L["Yes"] or "Yes", onClick = function()
                                DF:CopyBossSettings(otherMode, curMode)
                                if GUI.RefreshCurrentPage then GUI.RefreshCurrentPage() end
                            end },
                            { label = L["Cancel"] or "Cancel" },
                        },
                    })
                else
                    DF:CopyBossSettings(otherMode, curMode)
                    if GUI.RefreshCurrentPage then GUI.RefreshCurrentPage() end
                end
            end)
        Add(copyBtn, 32, "both")

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["General"]), 32, "both")

        Add(GUI:CreateCheckbox(self.child, L["Enable"] or "Enable", db, "enabled", refresh), 32, 1)
        Add(GUI:CreateCheckbox(self.child, L["Hide Blizzard"] or "Hide Blizzard", db, "hideBlizzard", refresh), 32, 2)

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Position"]), 32, "both")

        Add(GUI:CreateDropdown(self.child, L["Anchor"], anchorOpts(L), db, "anchor", refresh), 55, 1)
        Add(GUI:CreateDropdown(self.child, L["Grow Direction"] or "Grow direction", {
            DOWN = L["Down"],
            UP   = L["Up"],
        }, db, "growDirection", refresh), 55, 2)

        Add(GUI:CreateSlider(self.child, L["Offset X"], -1000, 1000, 1, db, "anchorX", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Offset Y"], -1000, 1000, 1, db, "anchorY", refresh), 55, 2)

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Size"]), 32, "both")

        Add(GUI:CreateSlider(self.child, L["Width"],   100, 400, 1,    db, "frameWidth",   refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Height"] or "Height",  20, 100, 1, db, "frameHeight", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Spacing"], 0, 40, 1,       db, "frameSpacing", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Scale"], 0.5, 2.0, 0.05,   db, "frameScale",   refresh), 55, 2)

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Portrait"] or "Portrait"), 32, "both")

        Add(GUI:CreateDropdown(self.child, L["Portrait Position"] or "Portrait position", {
            LEFT   = L["Left"],
            RIGHT  = L["Right"],
            HIDDEN = L["Hidden"] or "Hidden",
        }, db, "portraitPosition", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Portrait Size"] or "Portrait size", 20, 80, 1, db, "portraitSize", refresh), 55, 2)
        Add(GUI:CreateDropdown(self.child, L["Portrait Style"] or "Portrait style", {
            ["2D"] = L["2D (Blizzard-style face icon)"] or "2D (Blizzard-style face icon)",
            ["3D"] = L["3D (animated model)"]          or "3D (animated model)",
        }, db, "portraitStyle", refresh), 55, "both")
    end)

    -- ========================================
    -- Page: Bars (health + power)
    -- ========================================
    local pageBars = CreateSubTab("boss", "boss_bars", L["Bars"])
    BuildPage(pageBars, function(self, _, Add, AddSpace, AddSyncPoint)
        local db = DF:GetBossDB()

        Add(GUI:CreateHeader(self.child, L["Health"] or "Health"), 32, "both")
        Add(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "healthTexture", refresh), 55, 1)
        Add(GUI:CreateDropdown(self.child, L["Color"] or "Color", {
            REACTION       = L["Reaction (red/yellow/green by hostility — Blizzard)"] or "Reaction (Blizzard hostility colors)",
            CLASS_FALLBACK = L["Class Color"] or "Class color (red fallback)",
            STATIC         = L["Custom"]      or "Custom static",
        }, db, "healthColorMode", refresh), 55, 2)
        Add(GUI:CreateColorPicker(self.child, L["Static Color"] or "Static color", db, "healthStaticColor", true, refresh), 40, 1)
        Add(GUI:CreateSlider(self.child, L["Background Alpha"] or "Background alpha", 0, 1, 0.05, db, "healthBackgroundAlpha", refresh), 55, 2)

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Power"] or "Power"), 32, "both")
        Add(GUI:CreateCheckbox(self.child, L["Show Power Bar"] or "Show power bar", db, "showPowerBar", refresh), 32, 1)
        Add(GUI:CreateSlider(self.child, L["Power Bar Height"] or "Power bar height", 2, 20, 1, db, "powerBarHeight", refresh), 55, 2)
        Add(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "powerTexture", refresh), 55, "both")
        Add(GUI:CreateSlider(self.child, L["Background Alpha"] or "Background alpha", 0, 1, 0.05, db, "powerBackgroundAlpha", refresh), 55, "both")
    end)

    -- ========================================
    -- Page: Cast Bar
    -- ========================================
    local pageCast = CreateSubTab("boss", "boss_castbar", L["Cast Bar"] or "Cast Bar")
    BuildPage(pageCast, function(self, _, Add, AddSpace, AddSyncPoint)
        local db = DF:GetBossDB()

        Add(GUI:CreateHeader(self.child, L["Cast Bar"] or "Cast Bar"), 32, "both")
        Add(GUI:CreateCheckbox(self.child, L["Show Cast Bar"] or "Show cast bar", db, "showCastBar", refresh), 32, 1)
        Add(GUI:CreateCheckbox(self.child, L["Detached"] or "Detached (below frame)", db, "castBarDetached", refresh), 32, 2)

        Add(GUI:CreateSlider(self.child, L["Height"] or "Height", 8, 40, 1, db, "castBarHeight", refresh), 55, 1)
        Add(GUI:CreateDropdown(self.child, L["Icon Position"] or "Icon position", {
            LEFT  = L["Left"],
            RIGHT = L["Right"],
        }, db, "castBarIconPosition", refresh), 55, 2)
        Add(GUI:CreateTextureDropdown(self.child, L["Texture"], db, "castTexture", refresh), 55, "both")
        Add(GUI:CreateSlider(self.child, L["Background Alpha"] or "Background alpha", 0, 1, 0.05, db, "castBackgroundAlpha", refresh), 55, "both")

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Detached Position"] or "Detached position"), 32, "both")
        Add(GUI:CreateDropdown(self.child, L["Position"] or "Position", anchorOpts(L), db, "castBarDetachedAnchor", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Width"] .. " (0=auto)", 0, 400, 1, db, "castBarDetachedWidth", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Offset X"], -200, 200, 1, db, "castBarDetachedX", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Offset Y"], -200, 200, 1, db, "castBarDetachedY", refresh), 55, 2)
    end)

    -- ========================================
    -- Page: Text (name + health text)
    -- ========================================
    local pageText = CreateSubTab("boss", "boss_text", L["Text"])
    BuildPage(pageText, function(self, _, Add, AddSpace, AddSyncPoint)
        local db = DF:GetBossDB()

        local anchor9 = anchorOpts(L)

        Add(GUI:CreateHeader(self.child, L["Name"] or "Name"), 32, "both")
        Add(GUI:CreateCheckbox(self.child, L["Show Name"] or "Show name", db, "showName", refresh), 32, 1)
        Add(GUI:CreateDropdown(self.child, L["Position"] or "Position", anchor9, db, "nameAnchor", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Offset X"], -80, 80, 1, db, "nameX", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Offset Y"], -80, 80, 1, db, "nameY", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, (L["Max Length"] or "Max length") .. " (0=off)", 0, 40, 1, db, "nameMaxLength", refresh), 55, "both")

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Health Text"] or "Health Text"), 32, "both")
        Add(GUI:CreateCheckbox(self.child, L["Show Health Text"] or "Show health text", db, "showHealthText", refresh), 32, 1)
        Add(GUI:CreateDropdown(self.child, L["Position"] or "Position", anchor9, db, "healthTextAnchor", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Offset X"], -80, 80, 1, db, "healthTextX", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Offset Y"], -80, 80, 1, db, "healthTextY", refresh), 55, 2)
        Add(GUI:CreateDropdown(self.child, L["Format"] or "Format", {
            PERCENT         = L["Percent"]           or "Percent (50%)",
            CURRENT         = L["Current"]           or "Current (50M)",
            CURRENT_PERCENT = L["Current + Percent"] or "Current + % (50M 50%)",
            CURRENT_MAX     = L["Current / Max"]     or "Current / Max",
        }, db, "healthTextFormat", refresh), 55, "both")

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Power Text"] or "Power Text"), 32, "both")
        Add(GUI:CreateCheckbox(self.child, L["Show Power Text"] or "Show power text", db, "showPowerText", refresh), 32, 1)
        Add(GUI:CreateDropdown(self.child, L["Position"] or "Position", anchorOpts(L), db, "powerTextAnchor", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Offset X"], -80, 80, 1, db, "powerTextX", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Offset Y"], -80, 80, 1, db, "powerTextY", refresh), 55, 2)
        Add(GUI:CreateDropdown(self.child, L["Format"] or "Format", {
            PERCENT         = L["Percent"]           or "Percent (50%)",
            CURRENT         = L["Current"]           or "Current (50M)",
            CURRENT_PERCENT = L["Current + Percent"] or "Current + % (50M 50%)",
            CURRENT_MAX     = L["Current / Max"]     or "Current / Max",
        }, db, "powerTextFormat", refresh), 55, "both")

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Raid Target Icon"] or "Raid Target Icon"), 32, "both")
        Add(GUI:CreateCheckbox(self.child, L["Show Raid Target Icon"] or "Show raid target icon (skull/cross/...)", db, "showRaidTargetIcon", refresh), 32, "both")
        Add(GUI:CreateDropdown(self.child, L["Position"] or "Position", anchor9, db, "raidTargetAnchor", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Size"] or "Size", 10, 48, 1, db, "raidTargetSize", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Offset X"], -80, 80, 1, db, "raidTargetX", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Offset Y"], -80, 80, 1, db, "raidTargetY", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Alpha"], 0, 1, 0.05, db, "raidTargetAlpha", refresh), 55, "both")
    end)

    -- ========================================
    -- Page: Auras (buffs / debuffs)
    -- ========================================
    local pageAuras = CreateSubTab("boss", "boss_auras", L["Auras"])
    BuildPage(pageAuras, function(self, _, Add, AddSpace, AddSyncPoint)
        local db = DF:GetBossDB()

        Add(GUI:CreateHeader(self.child, L["Auras"]), 32, "both")
        Add(GUI:CreateLabel(self.child,
            L["Show buffs or debuffs on each boss frame. Like Blizzard's default boss frames but fully configurable."]
            or "Show buffs or debuffs on each boss frame. Like Blizzard's default boss frames but fully configurable.",
            530), 40, "both")

        Add(GUI:CreateCheckbox(self.child, L["Show Auras"] or "Show auras", db, "showAuras", refresh), 32, 1)
        Add(GUI:CreateDropdown(self.child, L["Filter"] or "Filter", {
            HARMFUL = L["Debuffs"] or "Debuffs (harmful)",
            HELPFUL = L["Buffs"]   or "Buffs (helpful)",
        }, db, "aurasFilter", refresh), 55, 2)
        Add(GUI:CreateDropdown(self.child, L["Source"] or "Source", {
            ALL       = L["All (Blizzard-like)"] or "All (Blizzard-like)",
            MINE      = L["Only mine"]           or "Only mine",
            NOT_MINE  = L["Hide mine"]           or "Hide mine",
            BOSS_ONLY = L["Boss-cast only"]      or "Boss-cast only",
        }, db, "aurasSource", refresh), 55, "both")

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Appearance"] or "Appearance"), 32, "both")
        Add(GUI:CreateSlider(self.child, L["Max Count"] or "Max count", 1, 8, 1, db, "aurasMaxCount", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Size"] or "Size", 12, 48, 1, db, "aurasSize", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Spacing"], 0, 10, 1, db, "aurasSpacing", refresh), 55, 1)

        Add(GUI:CreateCheckbox(self.child, L["Show Stacks"] or "Show stacks", db, "aurasShowStacks", refresh), 32, 1)
        Add(GUI:CreateCheckbox(self.child, L["Show Timer"] or "Show timer", db, "aurasShowTimer", refresh), 32, 2)

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Stack Text"] or "Stack text"), 32, "both")
        Add(GUI:CreateDropdown(self.child, L["Position"] or "Position", anchorOpts(L), db, "aurasStackAnchor", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Offset X"], -20, 20, 1, db, "aurasStackX", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Offset Y"], -20, 20, 1, db, "aurasStackY", refresh), 55, 1)

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Timer Text"] or "Timer text"), 32, "both")
        Add(GUI:CreateDropdown(self.child, L["Placement"] or "Placement", {
            INSIDE = L["Inside (centered)"] or "Inside (centered)",
            BELOW  = L["Below icon"]        or "Below icon",
            ABOVE  = L["Above icon"]        or "Above icon",
        }, db, "aurasTimerPlacement", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Offset X"], -20, 20, 1, db, "aurasTimerX", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Offset Y"], -20, 20, 1, db, "aurasTimerY", refresh), 55, 1)

        AddSyncPoint()

        Add(GUI:CreateHeader(self.child, L["Position"] or "Position"), 32, "both")
        Add(GUI:CreateDropdown(self.child, L["Position"] or "Position", anchorOpts(L), db, "aurasAnchor", refresh), 55, 1)
        Add(GUI:CreateDropdown(self.child, L["Grow X"] or "Grow X", {
            LEFT  = L["Left"],
            RIGHT = L["Right"],
        }, db, "aurasGrowX", refresh), 55, 2)
        Add(GUI:CreateSlider(self.child, L["Offset X"], -200, 200, 1, db, "aurasX", refresh), 55, 1)
        Add(GUI:CreateSlider(self.child, L["Offset Y"], -200, 200, 1, db, "aurasY", refresh), 55, 2)
    end)
end
