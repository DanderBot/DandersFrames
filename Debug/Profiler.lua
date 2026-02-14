local addonName, DF = ...

-- ============================================================
-- DANDERSFRAMES FUNCTION PROFILER
--
-- Zero overhead when disabled: uses function-swapping to wrap
-- DF:Method() calls with debugprofilestop() timing. When stopped,
-- original functions are fully restored — no runtime checks,
-- no wrappers, no cost.
--
-- Usage:
--   /df profiler             Toggle the profiler UI
--   /df profile [seconds]    Quick run for N seconds (default 10)
-- ============================================================

local debugprofilestop = debugprofilestop
local format = string.format
local sort = table.sort
local floor = math.floor
local max = math.max
local wipe = wipe
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local CreateFrame = CreateFrame

-- ============================================================
-- STATE
-- ============================================================

local Profiler = {
    active = false,
    startTime = 0,          -- debugprofilestop() ms when started
    stopTime = 0,           -- debugprofilestop() ms when stopped (for accurate elapsed)
    combatAuto = false,     -- auto start/stop on combat enter/leave
    splitByFrame = false,   -- show per-frame-type breakdown
    data = {},              -- [funcName|type] = { calls, total, max }
    originals = {},         -- [funcName] = original function ref
    sortColumn = "total",
    sortDesc = true,
}

DF.Profiler = Profiler

-- Forward declarations (referenced by combat handler before defined below)
local profilerFrame = nil
local dataRows = {}
local headerTexts = {}
local UpdateUI  -- assigned later when UI functions are defined

-- Combat auto-profile event frame (created once, persists)
local combatFrame = CreateFrame("Frame")
combatFrame:Hide()

combatFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat
        if not Profiler.active then
            Profiler:Start()
            if profilerFrame and profilerFrame:IsShown() and UpdateUI then
                UpdateUI()
            end
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat
        if Profiler.active then
            Profiler:Stop()
            Profiler:PrintResults()
            if profilerFrame and profilerFrame:IsShown() and UpdateUI then
                UpdateUI()
            end
        end
    end
end)

function Profiler:SetCombatAuto(enabled)
    self.combatAuto = enabled
    if enabled then
        combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        print("|cff00ff00DF Profiler:|r Combat auto-profile |cff00ff00ON|r — will start on combat, stop + print on combat end.")
    else
        combatFrame:UnregisterEvent("PLAYER_REGEN_DISABLED")
        combatFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        print("|cff00ff00DF Profiler:|r Combat auto-profile |cffff4444OFF|r")
    end
end

-- ============================================================
-- PROFILED FUNCTIONS
-- Only DF:Method() style. Non-existent entries are skipped.
-- ============================================================

local PROFILED_FUNCTIONS = {
    -- Core per-unit updates (called from event handlers)
    "UpdateUnitFrame",
    "UpdateHealthFast",        -- Lean UNIT_HEALTH hot path (subset of UpdateUnitFrame)
    "UpdateHealth",
    "UpdatePower",
    "UpdateName",
    "UpdateFrame",

    -- Aura pipeline
    "UpdateAuras",                  -- Entry point (alias for Enhanced)
    "CollectBuffs",
    "CollectDebuffs",
    "UpdateAuraIcons_Enhanced",
    "UpdateAuraIconsDirect",        -- New merged collect+display (Tier 3)
    "RepositionCenterGrowthIcons",

    -- Dispel
    "UpdateDispelOverlay",
    "UpdateDispelGradientHealth",
    "UpdateAllDispelOverlays",

    -- Absorb / Prediction
    "UpdateAbsorb",
    "UpdateHealAbsorb",
    "UpdateHealPrediction",

    -- Range
    "UpdateRange",
    "UpdatePetRange",

    -- Visual
    "UpdateHighlights",
    "UpdateAnimatedBorder",
    "ApplyDeadFade",

    -- Icons
    "UpdateMissingBuffIcon",
    "UpdateExternalDefIcon",
    "UpdateRaidTargetIcon",
    "UpdateReadyCheckIcon",

    -- Layout / Style
    "ApplyFrameLayout",
    "ApplyFrameStyle",
    "ApplyAuraLayout",

    -- Blizzard integration
    "CaptureAurasFromBlizzardFrame",
    "UpdateBlizzardFrameVisibility",
}

-- ============================================================
-- FORMAT HELPERS
-- ============================================================

local function CommaNumber(n)
    local s = tostring(floor(n))
    return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function FormatMs(ms)
    if ms >= 1000 then
        return format("%.1fs", ms / 1000)
    elseif ms >= 0.1 then
        return format("%.1f", ms)
    else
        return format("%.2f", ms)
    end
end

local function FormatUs(ms)
    local us = ms * 1000
    if us >= 100 then return format("%.0f", us)
    elseif us >= 10 then return format("%.1f", us)
    else return format("%.2f", us) end
end

local function FormatElapsed(seconds)
    if seconds >= 60 then
        return format("%dm %ds", floor(seconds / 60), floor(seconds % 60))
    else
        return format("%.1fs", seconds)
    end
end

-- ============================================================
-- CORE PROFILING
-- ============================================================

function Profiler:Start()
    if self.active then
        print("|cff00ff00DF Profiler:|r Already recording.")
        return
    end

    self.active = true
    self.startTime = debugprofilestop()
    self.stopTime = 0
    wipe(self.data)
    wipe(self.originals)

    local wrapped = 0
    local typeCheck = type  -- cache as upvalue

    for _, name in ipairs(PROFILED_FUNCTIONS) do
        local original = DF[name]
        if original and type(original) == "function" then
            self.originals[name] = original

            -- Pre-allocate a bucket for each frame type (upvalues = zero hash lookup per call)
            -- P=Party, R=Raid, HP=Highlight Party, HR=Highlight Raid, ?=Other/no frame arg
            local dP  = { calls = 0, total = 0, max = 0 }
            local dR  = { calls = 0, total = 0, max = 0 }
            local dHP = { calls = 0, total = 0, max = 0 }
            local dHR = { calls = 0, total = 0, max = 0 }
            local dU  = { calls = 0, total = 0, max = 0 }

            self.data[name .. "|P"]  = dP
            self.data[name .. "|R"]  = dR
            self.data[name .. "|HP"] = dHP
            self.data[name .. "|HR"] = dHR
            self.data[name .. "|?"]  = dU

            local orig = original

            DF[name] = function(selfArg, a1, ...)
                local t = debugprofilestop()
                local r1, r2, r3, r4, r5 = orig(selfArg, a1, ...)
                local elapsed = debugprofilestop() - t

                -- Classify: 2-3 field lookups on the first argument
                local bucket
                if typeCheck(a1) == "table" and a1.unit then
                    if a1.isPinnedFrame then
                        bucket = a1.isRaidFrame and dHR or dHP
                    else
                        bucket = a1.isRaidFrame and dR or dP
                    end
                else
                    bucket = dU
                end
                bucket.calls = bucket.calls + 1
                bucket.total = bucket.total + elapsed
                if elapsed > bucket.max then bucket.max = elapsed end

                return r1, r2, r3, r4, r5
            end

            wrapped = wrapped + 1
        end
    end

    print(format("|cff00ff00DF Profiler:|r Recording. %d functions instrumented.", wrapped))
end

function Profiler:Stop()
    if not self.active then return end
    self.stopTime = debugprofilestop()
    self.active = false

    -- Restore all original functions immediately
    for name, original in pairs(self.originals) do
        DF[name] = original
    end

    print(format("|cff00ff00DF Profiler:|r Stopped after %s.", FormatElapsed(self:GetElapsedSeconds())))
end

function Profiler:Reset()
    for _, d in pairs(self.data) do
        d.calls = 0
        d.total = 0
        d.max = 0
    end
    if self.active then
        self.startTime = debugprofilestop()
    end
end

function Profiler:Toggle()
    if self.active then self:Stop() else self:Start() end
end

function Profiler:GetElapsedSeconds()
    if self.startTime == 0 then return 0 end
    local endTime = self.active and debugprofilestop() or self.stopTime
    return (endTime - self.startTime) / 1000
end

function Profiler:GetTotalCalls()
    local total = 0
    for _, d in pairs(self.data) do total = total + d.calls end
    return total
end

function Profiler:GetGrandTotalMs()
    local total = 0
    for _, d in pairs(self.data) do total = total + d.total end
    return total
end

-- Display name suffixes for frame types
local TYPE_LABELS = {
    ["|P"]  = "  [Party]",
    ["|R"]  = "  [Raid]",
    ["|HP"] = "  [HL-P]",
    ["|HR"] = "  [HL-R]",
    ["|?"]  = "",  -- no suffix for "other" (functions that don't take a frame)
}

function Profiler:GetSortedResults()
    local results = {}
    local grandTotal = 0

    if self.splitByFrame then
        -- Split mode: one row per function+type combination (only those with calls)
        for key, d in pairs(self.data) do
            if d.calls > 0 then
                grandTotal = grandTotal + d.total
                -- Parse "funcName|type" into base name + suffix
                local baseName, suffix = key:match("^(.+)(|.+)$")
                if not baseName then
                    baseName = key
                    suffix = ""
                end
                local displayName = baseName .. (TYPE_LABELS[suffix] or suffix)
                results[#results + 1] = {
                    name = displayName,
                    calls = d.calls,
                    total = d.total,
                    avg = d.total / d.calls,
                    max = d.max,
                }
            end
        end
    else
        -- Aggregate mode: combine all frame types into one row per function
        local aggregated = {}
        local aggOrder = {}  -- preserve insertion order for deterministic iteration
        for key, d in pairs(self.data) do
            if d.calls > 0 then
                local baseName = key:match("^(.+)|") or key
                if not aggregated[baseName] then
                    aggregated[baseName] = { calls = 0, total = 0, max = 0 }
                    aggOrder[#aggOrder + 1] = baseName
                end
                local agg = aggregated[baseName]
                agg.calls = agg.calls + d.calls
                agg.total = agg.total + d.total
                if d.max > agg.max then agg.max = d.max end
            end
        end

        for _, baseName in ipairs(aggOrder) do
            local agg = aggregated[baseName]
            grandTotal = grandTotal + agg.total
            results[#results + 1] = {
                name = baseName,
                calls = agg.calls,
                total = agg.total,
                avg = agg.total / agg.calls,
                max = agg.max,
            }
        end
    end

    for _, r in ipairs(results) do
        r.pct = grandTotal > 0 and (r.total / grandTotal * 100) or 0
    end

    local col = self.sortColumn
    local desc = self.sortDesc
    sort(results, function(a, b)
        if col == "name" then
            if desc then return a.name > b.name else return a.name < b.name end
        end
        if desc then return a[col] > b[col] else return a[col] < b[col] end
    end)

    return results, grandTotal
end

-- ============================================================
-- QUICK PROFILE (timed auto-run, prints to chat)
-- ============================================================

function Profiler:QuickProfile(duration)
    duration = duration or 10
    if self.active then self:Stop() end

    self:Start()
    print(format("|cff00ff00DF Profiler:|r Auto-stopping in %ds...", duration))

    C_Timer.After(duration, function()
        if self.active then
            self:Stop()
            self:PrintResults()
            if profilerFrame and profilerFrame:IsShown() then
                UpdateUI()
            end
        end
    end)
end

-- ============================================================
-- PRINT TO CHAT
-- ============================================================

function Profiler:PrintResults()
    local results, grandTotal = self:GetSortedResults()
    local elapsed = self:GetElapsedSeconds()
    local totalCalls = self:GetTotalCalls()

    if #results == 0 then
        print("|cff00ff00DF Profiler:|r No data collected.")
        return
    end

    print(" ")
    print(format("|cff00ff00DF Profiler:|r %s | %s calls | %sms profiled CPU",
        FormatElapsed(elapsed), CommaNumber(totalCalls), FormatMs(grandTotal)))
    print("|cffaaaaaa------------------------------------------------------------|r")

    for i, r in ipairs(results) do
        local color
        if r.pct >= 25 then color = "|cffff6666"
        elseif r.pct >= 10 then color = "|cffffff88"
        else color = "|cff88ff88" end

        print(format("  %s%2d. %-36s|r  %s calls  %sms  %sus avg  %sus max  %s%5.1f%%|r",
            color, i, r.name,
            CommaNumber(r.calls),
            FormatMs(r.total),
            FormatUs(r.avg),
            FormatUs(r.max),
            color, r.pct
        ))
    end

    print("|cffaaaaaa------------------------------------------------------------|r")
    print(" ")
end

-- ============================================================
-- UI
-- ============================================================

local ROW_HEIGHT = 18
local MAX_ROWS = 30
local FRAME_WIDTH = 600
local CONTENT_LEFT = 10
local CONTENT_RIGHT = -10
local HEADER_Y = -66
local DATA_START_Y = -86

-- Column layout
local COLUMNS = {
    { key = "name",  label = "Function",  width = 220, align = "LEFT" },
    { key = "calls", label = "Calls",     width = 56,  align = "RIGHT" },
    { key = "total", label = "Total ms", width = 62,  align = "RIGHT" },
    { key = "avg",   label = "Avg us",    width = 56,  align = "RIGHT" },
    { key = "max",   label = "Max us",    width = 56,  align = "RIGHT" },
    { key = "pct",   label = "%",         width = 48,  align = "RIGHT" },
}

local CONTENT_WIDTH = 0
for _, col in ipairs(COLUMNS) do
    CONTENT_WIDTH = CONTENT_WIDTH + col.width + 4
end

local function UpdateColumnHeaders()
    for _, col in ipairs(COLUMNS) do
        local label = col.label
        if Profiler.sortColumn == col.key then
            label = label .. (Profiler.sortDesc and " v" or " ^")
        end
        if headerTexts[col.key] then
            headerTexts[col.key]:SetText(label)
        end
    end
end

local function CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT", parent, "LEFT", CONTENT_LEFT, 0)
    row:SetPoint("RIGHT", parent, "RIGHT", CONTENT_RIGHT, 0)

    -- Alternating background
    row.bg = row:CreateTexture(nil, "BACKGROUND", nil, 0)
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(index % 2 == 0 and 0.13 or 0.08, index % 2 == 0 and 0.13 or 0.08, index % 2 == 0 and 0.13 or 0.08, 1)

    -- Percentage bar (visual indicator behind text)
    row.pctBar = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.pctBar:SetPoint("LEFT")
    row.pctBar:SetHeight(ROW_HEIGHT)
    row.pctBar:SetWidth(1)
    row.pctBar:Hide()

    -- Column font strings
    row.cols = {}
    local xOffset = 2
    for _, col in ipairs(COLUMNS) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH(col.align)
        fs:SetPoint("LEFT", row, "LEFT", xOffset, 0)
        fs:SetWidth(col.width)
        row.cols[col.key] = fs
        xOffset = xOffset + col.width + 4
    end

    row:Hide()
    return row
end

-- Assign to the forward-declared upvalue so the combat handler can call it
UpdateUI = function()
    if not profilerFrame or not profilerFrame:IsShown() then return end

    local elapsed = Profiler:GetElapsedSeconds()
    local totalCalls = Profiler:GetTotalCalls()
    local grandTotal = Profiler:GetGrandTotalMs()

    -- Status line
    if Profiler.active then
        profilerFrame.statusText:SetText(format(
            "|cff00ff00Recording|r  %s  |  %s calls  |  %sms CPU",
            FormatElapsed(elapsed), CommaNumber(totalCalls), FormatMs(grandTotal)
        ))
        profilerFrame.toggleBtn:SetText("Stop")
    else
        if totalCalls > 0 then
            local combatTag = Profiler.combatAuto and "  |  |cff00ff00Combat Armed|r" or ""
            profilerFrame.statusText:SetText(format(
                "|cffff4444Stopped|r  %s  |  %s calls  |  %sms CPU%s",
                FormatElapsed(elapsed), CommaNumber(totalCalls), FormatMs(grandTotal), combatTag
            ))
        else
            local combatTag = Profiler.combatAuto and "|cff00ff00Combat Armed|r  Waiting for combat..." or "|cff888888Ready|r  Press Start to begin profiling"
            profilerFrame.statusText:SetText(combatTag)
        end
        profilerFrame.toggleBtn:SetText("Start")
    end

    -- Data rows
    local results = Profiler:GetSortedResults()

    for i = 1, MAX_ROWS do
        local row = dataRows[i]
        if not row then break end

        local r = results[i]
        if r then
            -- Color based on cost share
            local cr, cg, cb
            local barR, barG, barB
            if r.pct >= 25 then
                cr, cg, cb = 1, 0.5, 0.5
                barR, barG, barB = 0.5, 0.15, 0.15
            elseif r.pct >= 10 then
                cr, cg, cb = 1, 1, 0.6
                barR, barG, barB = 0.4, 0.4, 0.1
            else
                cr, cg, cb = 0.7, 0.9, 0.7
                barR, barG, barB = 0.15, 0.35, 0.15
            end

            -- Percentage bar width
            local barWidth = max(1, (CONTENT_WIDTH - 4) * (r.pct / 100))
            row.pctBar:SetWidth(barWidth)
            row.pctBar:SetColorTexture(barR, barG, barB, 0.35)
            row.pctBar:Show()

            row.cols.name:SetText(r.name)
            row.cols.name:SetTextColor(cr, cg, cb)

            row.cols.calls:SetText(CommaNumber(r.calls))
            row.cols.calls:SetTextColor(0.8, 0.8, 0.8)

            row.cols.total:SetText(FormatMs(r.total))
            row.cols.total:SetTextColor(0.8, 0.8, 0.8)

            row.cols.avg:SetText(FormatUs(r.avg))
            row.cols.avg:SetTextColor(0.7, 0.7, 0.7)

            row.cols.max:SetText(FormatUs(r.max))
            row.cols.max:SetTextColor(0.7, 0.7, 0.7)

            row.cols.pct:SetText(format("%.1f%%", r.pct))
            row.cols.pct:SetTextColor(cr, cg, cb)

            row:Show()
        else
            row:Hide()
        end
    end

    -- Keep combat button text in sync
    if profilerFrame.combatBtn then
        if Profiler.combatAuto then
            profilerFrame.combatBtn:SetText("|cff00ff00Combat|r")
        else
            profilerFrame.combatBtn:SetText("Combat")
        end
    end

    -- Keep split button text in sync
    if profilerFrame.splitBtn then
        if Profiler.splitByFrame then
            profilerFrame.splitBtn:SetText("|cff00ff00Split|r")
        else
            profilerFrame.splitBtn:SetText("Split")
        end
    end
end

function Profiler:CreateUI()
    if profilerFrame then
        profilerFrame:Show()
        return
    end

    -- Main frame
    local f = CreateFrame("Frame", "DFProfilerFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, DATA_START_Y * -1 + MAX_ROWS * ROW_HEIGHT + 30)
    f:SetPoint("CENTER", 0, 50)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    f:SetBackdropColor(0.06, 0.06, 0.06, 0.98)
    f:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    profilerFrame = f

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff00ff00DF|r Profiler")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetSize(18, 18)
    closeBtn:SetPoint("TOPRIGHT", -6, -6)
    closeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Status line
    f.statusText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.statusText:SetPoint("TOPLEFT", 12, -32)
    f.statusText:SetJustifyH("LEFT")
    f.statusText:SetText("|cff888888Ready|r  Press Start to begin profiling")

    -- Buttons
    local btnY = -46
    local btnH = 20
    local btnW = 68

    f.toggleBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.toggleBtn:SetSize(btnW, btnH)
    f.toggleBtn:SetPoint("TOPLEFT", 10, btnY)
    f.toggleBtn:SetText("Start")
    f.toggleBtn:SetScript("OnClick", function()
        Profiler:Toggle()
        UpdateUI()
        UpdateColumnHeaders()
    end)

    local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    resetBtn:SetSize(btnW, btnH)
    resetBtn:SetPoint("LEFT", f.toggleBtn, "RIGHT", 4, 0)
    resetBtn:SetText("Reset")
    resetBtn:SetScript("OnClick", function()
        Profiler:Reset()
        UpdateUI()
    end)

    local printBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    printBtn:SetSize(88, btnH)
    printBtn:SetPoint("LEFT", resetBtn, "RIGHT", 4, 0)
    printBtn:SetText("Print to Chat")
    printBtn:SetScript("OnClick", function()
        Profiler:PrintResults()
    end)

    -- Custom duration input box
    local durationInput = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    durationInput:SetSize(36, btnH)
    durationInput:SetPoint("LEFT", printBtn, "RIGHT", 12, 0)
    durationInput:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    durationInput:SetBackdropColor(0.1, 0.1, 0.1, 1)
    durationInput:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    durationInput:SetFontObject(GameFontHighlightSmall)
    durationInput:SetJustifyH("CENTER")
    durationInput:SetAutoFocus(false)
    durationInput:SetNumeric(true)
    durationInput:SetMaxLetters(4)
    durationInput:SetText("30")
    -- Allow clicking away to clear focus
    durationInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    durationInput:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local dur = tonumber(self:GetText()) or 30
        if dur < 1 then dur = 1 end
        Profiler:QuickProfile(dur)
        UpdateUI()
        UpdateColumnHeaders()
    end)
    f.durationInput = durationInput

    -- "s Run" button (triggers timed profile with input value)
    local runBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    runBtn:SetSize(48, btnH)
    runBtn:SetPoint("LEFT", durationInput, "RIGHT", 2, 0)
    runBtn:SetText("s Run")
    runBtn:SetScript("OnClick", function()
        durationInput:ClearFocus()
        local dur = tonumber(durationInput:GetText()) or 30
        if dur < 1 then dur = 1 end
        Profiler:QuickProfile(dur)
        UpdateUI()
        UpdateColumnHeaders()
    end)

    -- Combat Auto toggle button
    f.combatBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.combatBtn:SetSize(78, btnH)
    f.combatBtn:SetPoint("LEFT", runBtn, "RIGHT", 8, 0)
    local function UpdateCombatBtnText()
        if Profiler.combatAuto then
            f.combatBtn:SetText("|cff00ff00Combat|r")
        else
            f.combatBtn:SetText("Combat")
        end
    end
    f.combatBtn:SetScript("OnClick", function()
        Profiler:SetCombatAuto(not Profiler.combatAuto)
        UpdateCombatBtnText()
        UpdateUI()
    end)
    f.combatBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Combat Auto-Profile", 1, 1, 1)
        if Profiler.combatAuto then
            GameTooltip:AddLine("ON: Profiling starts on combat, stops + prints on combat end.", 0, 1, 0, true)
        else
            GameTooltip:AddLine("OFF: Click to enable automatic combat profiling.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
    end)
    f.combatBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UpdateCombatBtnText()

    -- Split by Frame Type toggle button
    f.splitBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.splitBtn:SetSize(50, btnH)
    f.splitBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, btnY)
    local function UpdateSplitBtnText()
        if Profiler.splitByFrame then
            f.splitBtn:SetText("|cff00ff00Split|r")
        else
            f.splitBtn:SetText("Split")
        end
    end
    f.splitBtn:SetScript("OnClick", function()
        Profiler.splitByFrame = not Profiler.splitByFrame
        UpdateSplitBtnText()
        UpdateUI()
    end)
    f.splitBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Split by Frame Type", 1, 1, 1)
        if Profiler.splitByFrame then
            GameTooltip:AddLine("ON: Showing per-type breakdown (Party, Raid, HL-Party, HL-Raid).", 0, 1, 0, true)
        else
            GameTooltip:AddLine("OFF: Click to split results by frame type.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
    end)
    f.splitBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UpdateSplitBtnText()

    -- Column headers
    local xOffset = CONTENT_LEFT + 2
    for _, col in ipairs(COLUMNS) do
        local hdr = CreateFrame("Button", nil, f)
        hdr:SetHeight(18)
        hdr:SetPoint("TOPLEFT", f, "TOPLEFT", xOffset, HEADER_Y)
        hdr:SetWidth(col.width)

        local text = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetAllPoints()
        text:SetJustifyH(col.align)
        text:SetTextColor(0.5, 0.75, 1.0)

        local label = col.label
        if Profiler.sortColumn == col.key then
            label = label .. (Profiler.sortDesc and " v" or " ^")
        end
        text:SetText(label)
        headerTexts[col.key] = text

        -- Click to sort
        local colKey = col.key
        hdr:SetScript("OnClick", function()
            if Profiler.sortColumn == colKey then
                Profiler.sortDesc = not Profiler.sortDesc
            else
                Profiler.sortColumn = colKey
                Profiler.sortDesc = true
            end
            UpdateColumnHeaders()
            UpdateUI()
        end)
        hdr:SetScript("OnEnter", function() text:SetTextColor(0.8, 1.0, 1.0) end)
        hdr:SetScript("OnLeave", function() text:SetTextColor(0.5, 0.75, 1.0) end)

        xOffset = xOffset + col.width + 4
    end

    -- Header divider
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.3, 0.3, 0.3, 0.6)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", CONTENT_LEFT, HEADER_Y - 18)
    divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", CONTENT_RIGHT, HEADER_Y - 18)

    -- Data rows
    for i = 1, MAX_ROWS do
        local row = CreateRow(f, i)
        row:SetPoint("TOP", f, "TOP", 0, DATA_START_Y - (i - 1) * ROW_HEIGHT)
        dataRows[i] = row
    end

    -- Info label at bottom
    local infoLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    infoLabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 8)
    infoLabel:SetTextColor(0.4, 0.4, 0.4)
    infoLabel:SetText("Times inclusive (include sub-calls)  |  1ms = 1000us")

    -- Live refresh via OnUpdate
    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed < 0.5 then return end
        self.elapsed = 0
        UpdateUI()
    end)

    UpdateUI()
end

function Profiler:ToggleUI()
    if profilerFrame and profilerFrame:IsShown() then
        profilerFrame:Hide()
    else
        self:CreateUI()
    end
end
