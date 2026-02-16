local addonName, DF = ...

-- ============================================================
-- DEBUG CONSOLE
-- Persistent debug logging system with settings UI integration
-- Provides DF:Debug(), DF:DebugWarn(), DF:DebugError() API
-- Logs persist in SavedVariables across /rl
-- ============================================================

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local tinsert, tremove, wipe = table.insert, table.remove, wipe
local format = string.format
local date = date

local DebugConsole = {}
DF.DebugConsole = DebugConsole

-- ============================================================
-- CONSTANTS
-- ============================================================

local SEVERITY = {
    INFO  = { level = 1, label = "INFO",  color = "|cff88ccff" },  -- Light blue
    WARN  = { level = 2, label = "WARN",  color = "|cffffff66" },  -- Yellow
    ERROR = { level = 3, label = "ERROR", color = "|cffff6666" },  -- Red
}

local SEVERITY_ORDER = { "INFO", "WARN", "ERROR" }

local DEFAULTS = {
    enabled = false,
    logLevel = "INFO",
    maxLines = 500,
    chatEcho = false,
    filters = {},  -- absent category = visible; explicit false = hidden
}

-- ============================================================
-- RUNTIME STATE
-- ============================================================

local debugDb       -- reference to DandersFramesDB_v2.debug
local debugLog      -- reference to DandersFramesDB_v2.debugLog
local knownCategories = {}  -- set: { ["PET"] = true, ["FONT"] = true, ... }
local liveEditBox         -- EditBox reference when debug tab is visible
local needsRefresh = false  -- flag to batch refresh when tab is visible

-- ============================================================
-- INITIALIZATION
-- ============================================================

function DebugConsole:Init()
    -- Ensure debug settings table exists
    if not DandersFramesDB_v2.debug then
        DandersFramesDB_v2.debug = {}
    end

    -- Apply missing defaults (migration-safe)
    for key, value in pairs(DEFAULTS) do
        if DandersFramesDB_v2.debug[key] == nil then
            if type(value) == "table" then
                DandersFramesDB_v2.debug[key] = {}
            else
                DandersFramesDB_v2.debug[key] = value
            end
        end
    end

    -- Ensure log array exists
    if not DandersFramesDB_v2.debugLog then
        DandersFramesDB_v2.debugLog = {}
    end

    -- Set live references
    debugDb = DandersFramesDB_v2.debug
    debugLog = DandersFramesDB_v2.debugLog

    -- Sync the ephemeral flag with persistent setting
    DF.debugEnabled = debugDb.enabled

    -- Rebuild known categories from existing log entries
    wipe(knownCategories)
    for _, entry in ipairs(debugLog) do
        local cat = entry[3]
        if cat and cat ~= "" then
            knownCategories[cat] = true
        end
    end

    -- Add reload separator if log has prior entries
    if #debugLog > 0 then
        tinsert(debugLog, {
            date("%H:%M:%S"),
            "INFO",
            "SYSTEM",
            "--- UI Reload ---"
        })
        knownCategories["SYSTEM"] = true
        self:PruneLog()
    end

    -- Log initialization status (confirms debug system is working)
    if debugDb.enabled then
        self:Log("INFO", "SYSTEM", "Debug Console initialized (enabled=%s, logLevel=%s, entries=%d)",
            tostring(debugDb.enabled), tostring(debugDb.logLevel), #debugLog)
    end
end

-- ============================================================
-- PUBLIC API
-- ============================================================

function DF:Debug(category, fmt, ...)
    if not debugDb or not debugDb.enabled then return end
    DebugConsole:Log("INFO", category, fmt, ...)
end

function DF:DebugWarn(category, fmt, ...)
    if not debugDb or not debugDb.enabled then return end
    DebugConsole:Log("WARN", category, fmt, ...)
end

function DF:DebugError(category, fmt, ...)
    if not debugDb or not debugDb.enabled then return end
    DebugConsole:Log("ERROR", category, fmt, ...)
end

-- ============================================================
-- INTERNAL LOGGING
-- ============================================================

function DebugConsole:Log(level, category, fmt, ...)
    -- Format the message
    local msg
    if select("#", ...) > 0 then
        local ok, result = pcall(format, fmt, ...)
        msg = ok and result or (tostring(fmt) .. " [format error]")
    else
        msg = tostring(fmt)
    end

    -- Create entry: {timestamp, level, category, message}
    local entry = {
        date("%H:%M:%S"),
        level,
        category or "GENERAL",
        msg,
    }

    tinsert(debugLog, entry)

    -- Track new categories
    local cat = entry[3]
    if not knownCategories[cat] then
        knownCategories[cat] = true
        -- New category discovered — if filters table doesn't have it, it defaults to visible
    end

    -- Prune if over limit
    self:PruneLog()

    -- Echo to chat if enabled
    if debugDb.chatEcho then
        local sev = SEVERITY[level] or SEVERITY.INFO
        print(format("%s[DF %s]|r [%s] %s", sev.color, sev.label, cat, msg))
    end

    -- Flag refresh for live display
    if liveEditBox then
        needsRefresh = true
        -- Defer refresh to avoid spam during rapid logging
        if not self.refreshTimer then
            self.refreshTimer = C_Timer.NewTimer(0.05, function()
                self.refreshTimer = nil
                if needsRefresh and liveEditBox then
                    self:RefreshDisplay()
                end
            end)
        end
    end
end

-- ============================================================
-- LOG MANAGEMENT
-- ============================================================

function DebugConsole:PruneLog()
    if not debugLog or not debugDb then return end
    local maxLines = debugDb.maxLines or 500
    while #debugLog > maxLines do
        tremove(debugLog, 1)
    end
end

function DebugConsole:ClearLog()
    if debugLog then
        wipe(debugLog)
    end
    wipe(knownCategories)
    if liveEditBox then
        self:RefreshDisplay()
    end
end

function DebugConsole:SetEnabled(enabled)
    if debugDb then
        debugDb.enabled = enabled
    end
    DF.debugEnabled = enabled
end

function DebugConsole:IsEnabled()
    return debugDb and debugDb.enabled or false
end

-- ============================================================
-- DISPLAY RENDERING
-- ============================================================

function DebugConsole:RefreshDisplay()
    needsRefresh = false
    if not liveEditBox or not debugLog then return end

    local minLevel = SEVERITY[debugDb.logLevel or "INFO"]
    if not minLevel then minLevel = SEVERITY.INFO end
    local minLevelNum = minLevel.level

    local filters = debugDb.filters or {}
    local lines = {}

    for _, entry in ipairs(debugLog) do
        local timestamp = entry[1]
        local level     = entry[2]
        local category  = entry[3]
        local message   = entry[4]

        -- Check severity filter
        local sev = SEVERITY[level]
        if sev and sev.level >= minLevelNum then
            -- Check category filter (absent = visible, explicit false = hidden)
            if filters[category] ~= false then
                local colorCode = sev.color or "|cffffffff"
                tinsert(lines, format("%s %s[%s]|r [%s] %s",
                    timestamp, colorCode, sev.label, category, message))
            end
        end
    end

    local text = #lines > 0 and table.concat(lines, "\n") or "|cff666666No log entries match current filters.|r"
    liveEditBox:SetText(text)

    -- Auto-scroll to bottom
    local scrollFrame = liveEditBox:GetParent()
    if scrollFrame and scrollFrame.SetVerticalScroll then
        C_Timer.After(0.01, function()
            if scrollFrame and scrollFrame.GetVerticalScrollRange then
                scrollFrame:SetVerticalScroll(scrollFrame:GetVerticalScrollRange())
            end
        end)
    end
end

function DebugConsole:SetLiveEditBox(editBox)
    liveEditBox = editBox
    if editBox then
        self:RefreshDisplay()
    end
end

-- ============================================================
-- CATEGORY ACCESS
-- ============================================================

function DebugConsole:GetKnownCategories()
    return knownCategories
end

function DebugConsole:GetLogEntryCount()
    return debugLog and #debugLog or 0
end

-- ============================================================
-- EXPORT
-- ============================================================

function DebugConsole:GetExportText()
    if not debugLog then return "No debug log available." end

    local lines = {}
    tinsert(lines, "DandersFrames Debug Log")
    tinsert(lines, "Version: " .. (DF.ADDON_VERSION or DF.VERSION or "unknown"))
    tinsert(lines, "Exported: " .. date("%Y-%m-%d %H:%M:%S"))
    tinsert(lines, "Entries: " .. #debugLog)
    tinsert(lines, "========================================")
    tinsert(lines, "")

    for _, entry in ipairs(debugLog) do
        tinsert(lines, format("%s [%s] [%s] %s",
            entry[1], entry[2], entry[3], entry[4]))
    end

    return table.concat(lines, "\n")
end
