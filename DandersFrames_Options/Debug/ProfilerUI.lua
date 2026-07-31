-- ============================================================
-- PROFILER WINDOW  (split from Debug/Profiler.lua)
-- ============================================================
-- The hooks, recording engine and chat reports are resident; this window is
-- pure presentation and loads with the settings companion. CreateUI already
-- gated on DF:EnsureOptionsLoaded before the split, so every path that opens
-- the window loads this file first.
-- ☠ Companion addon: bind the parent table from the global, never `...`.
local DF = DandersFrames
local Profiler = DF.Profiler
local format = string.format
local max = math.max
local ipairs = ipairs
-- Formatters shared with the resident chat reports.
local CommaNumber   = Profiler.CommaNumber
local FormatMs      = Profiler.FormatMs
local FormatUs      = Profiler.FormatUs
local FormatBytes   = Profiler.FormatBytes
local FormatPeak    = Profiler.FormatPeak
local FormatElapsed = Profiler.FormatElapsed
-- Window state. The resident half reads these through Profiler.frame /
-- Profiler.UpdateUI (published below); nil until the window first opens.
local profilerFrame = nil
local dataRows = {}
local headerTexts = {}
local UpdateUI

-- ============================================================
-- UI
-- ============================================================

local ROW_HEIGHT = 18
local MAX_ROWS = 30
local FRAME_WIDTH = 786   -- +66 over the pre-Self-column width
local CONTENT_LEFT = 10
local CONTENT_RIGHT = -10
local HEADER_Y = -66
local DATA_START_Y = -86

-- Column layout
local COLUMNS = {
    { key = "name",  label = "Function",  width = 210, align = "LEFT" },
    { key = "calls", label = "Calls",     width = 54,  align = "RIGHT" },
    { key = "total", label = "Total ms",  width = 60,  align = "RIGHT" },
    -- Self = Total minus the time spent inside OTHER profiled functions this
    -- one called. Sort by this to find where the work actually happens; sort
    -- by Total to find which entry point owns a whole subtree.
    { key = "selfMs", label = "Self ms",  width = 62,  align = "RIGHT" },
    { key = "avg",   label = "Avg us",    width = 52,  align = "RIGHT" },
    { key = "max",   label = "Max us",    width = 52,  align = "RIGHT" },
    { key = "peak",  label = "Peak/tk",   width = 52,  align = "RIGHT" },
    { key = "mem",   label = "Bytes",     width = 56,  align = "RIGHT" },
    { key = "pct",   label = "%",         width = 46,  align = "RIGHT" },
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
        local fs = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
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

            -- Self is the ranked figure, so it reads brighter than Total.
            row.cols.selfMs:SetText(FormatMs(r.selfMs or 0))
            row.cols.selfMs:SetTextColor(0.95, 0.95, 0.8)

            row.cols.avg:SetText(FormatUs(r.avg))
            row.cols.avg:SetTextColor(0.7, 0.7, 0.7)

            row.cols.max:SetText(FormatUs(r.max))
            row.cols.max:SetTextColor(0.7, 0.7, 0.7)

            row.cols.peak:SetText(FormatPeak(r.peak))
            -- Tint Peak/tick yellow when it's high (>=20 calls in one frame)
            -- — that's the cascade signal we're hunting.
            if r.peak >= 20 then
                row.cols.peak:SetTextColor(1, 0.85, 0.4)
            else
                row.cols.peak:SetTextColor(0.7, 0.7, 0.7)
            end

            row.cols.mem:SetText(FormatBytes(r.mem))
            -- Tint Mem yellow when bytes/call >= 256, red when >= 1024
            if r.mem >= 1024 then
                row.cols.mem:SetTextColor(1, 0.5, 0.5)
            elseif r.mem >= 256 then
                row.cols.mem:SetTextColor(1, 0.85, 0.4)
            else
                row.cols.mem:SetTextColor(0.7, 0.7, 0.7)
            end

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

    -- Keep view button text in sync
    if profilerFrame.viewBtn then
        if Profiler.viewMode == "events" then
            profilerFrame.viewBtn:SetText("|cff00ff00Events|r")
        elseif Profiler.viewMode == "updates" then
            profilerFrame.viewBtn:SetText("|cff00ff00OnUpdate|r")
        else
            profilerFrame.viewBtn:SetText("Functions")
        end
    end
end
Profiler.UpdateUI = UpdateUI   -- resident combat/timer handlers refresh through this


function Profiler:CreateUI()
    if profilerFrame then
        profilerFrame:Show()
        return
    end

    -- ☠ This window is built from settings-panel widgets -- CreateInfoBanner in
    -- particular, which parents the hook checkbox, so there is nothing sensible
    -- to fall back to if it is missing. The profiler is opened deliberately, so
    -- pulling the companion in here costs nothing anyone will notice and keeps
    -- the panel whole. Same call the settings panel itself uses.
    if DF.EnsureOptionsLoaded and not DF:EnsureOptionsLoaded() then
        return
    end

    -- Main frame
    local f = CreateFrame("Frame", "DFProfilerFrame", UIParent, "BackdropTemplate")
    -- Bottom slack has to clear TWO stacked things, not one:
    --   6  banner offset from the frame bottom
    --  34  the banner's minimum height
    --   6  gap
    --  24  the column legend that sits above it (TWO lines since Self landed)
    --  10  breathing room before the last data row
    -- The old value was 30, which did not even clear the 28px strip that used to
    -- live there — a full 30-row table clipped its last row behind it, and the
    -- legend was underneath the strip entirely.
    f:SetSize(FRAME_WIDTH, DATA_START_Y * -1 + MAX_ROWS * ROW_HEIGHT + 80)
    f:SetPoint("CENTER", 0, 50)
    -- Panel chrome, same as every other DF window. Was a bespoke plate from three
    -- hand-mixed literals, which is the other half of why this window read as
    -- foreign next to the settings frame.
    DF.GUI:CreatePanelBackdrop(f)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    profilerFrame = f
    Profiler.frame = f   -- resident hook excludes the window; combat handlers check it

    -- Title. The "DF" used to be hardcoded bright green, which matched nothing
    -- else in the addon; the theme accent is what every section header uses and
    -- it follows the party/raid pole like the rest of the GUI.
    local title = f:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Profiler")
    do
        local tc = DF.GUI.GetThemeColor and DF.GUI.GetThemeColor()
        if tc then title:SetTextColor(tc.r, tc.g, tc.b) end
    end

    -- Close button. Was Blizzard's raw UI-Panel-MinimizeButton textures, which is
    -- why this window's X had chrome no other DF surface has.
    local closeBtn = DF.GUI:CreateCloseButton(f, {
        onClick = function() f:Hide() end,
        tooltip = "Close",
    })
    closeBtn:SetPoint("TOPRIGHT", -6, -6)

    -- Status line
    f.statusText = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    f.statusText:SetPoint("TOPLEFT", 12, -32)
    f.statusText:SetJustifyH("LEFT")
    f.statusText:SetText("|cff888888Ready|r  Press Start to begin profiling")

    -- Buttons
    local btnY = -46
    local btnH = 20
    local btnW = 68

    f.toggleBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    DF.GUI:StyleButton(f.toggleBtn, { width = btnW, height = btnH, text = "Start" })
    f.toggleBtn:SetPoint("TOPLEFT", 10, btnY)
    f.toggleBtn:SetScript("OnClick", function()
        Profiler:Toggle()
        UpdateUI()
        UpdateColumnHeaders()
    end)

    local resetBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    DF.GUI:StyleButton(resetBtn, { width = btnW, height = btnH, text = "Reset" })
    resetBtn:SetPoint("LEFT", f.toggleBtn, "RIGHT", 4, 0)
    resetBtn:SetScript("OnClick", function()
        Profiler:Reset()
        UpdateUI()
    end)

    local printBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    DF.GUI:StyleButton(printBtn, { width = 88, height = btnH, text = "Print to Chat" })
    printBtn:SetPoint("LEFT", resetBtn, "RIGHT", 4, 0)
    printBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    printBtn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            Profiler:PrintSummary()
        else
            Profiler:PrintResults()
        end
    end)
    printBtn:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = "Print to Chat",
            lines = {
                "Left-click: dump the current view (functions/events/onupdate)",
                "Right-click: print Top 5 across all categories (summary)",
            },
        })
    end)
    printBtn:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)

    -- Custom duration input box
    local durationInput = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    durationInput:SetSize(36, btnH)
    durationInput:SetPoint("LEFT", printBtn, "RIGHT", 12, 0)
    DF.GUI:CreateElementBackdrop(durationInput, {
        bgColor     = { 0.1, 0.1, 0.1, 1 },
        borderColor = { 0.4, 0.4, 0.4, 1 },
    })
    durationInput:SetFontObject(DFFontHighlightSmall)
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

    -- "s Run" button (triggers timed profile with input value)
    local runBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    DF.GUI:StyleButton(runBtn, { width = 48, height = btnH, text = "s Run" })
    runBtn:SetPoint("LEFT", durationInput, "RIGHT", 2, 0)
    runBtn:SetScript("OnClick", function()
        durationInput:ClearFocus()
        local dur = tonumber(durationInput:GetText()) or 30
        if dur < 1 then dur = 1 end
        Profiler:QuickProfile(dur)
        UpdateUI()
        UpdateColumnHeaders()
    end)

    -- Combat Auto toggle button
    f.combatBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    -- text = "" so StyleButton creates AND registers its fontstring; the
    -- label itself is set by the Update*BtnText below, which needs it to exist.
    DF.GUI:StyleButton(f.combatBtn, { width = 78, height = btnH, text = "" })
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
        DF.GUI:ShowTooltip(self, {
            title = "Combat Auto-Profile",
            lines = { Profiler.combatAuto
                and { text = "ON: Profiling starts on combat, stops + prints on combat end.",
                      color = { 0, 1, 0 } }
                or  "OFF: Click to enable automatic combat profiling." },
        })
    end)
    f.combatBtn:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)
    UpdateCombatBtnText()

    -- View cycle button (Functions / Events / OnUpdate). Top-right, left of Split.
    f.viewBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    -- text = "" so StyleButton creates AND registers its fontstring; the
    -- label itself is set by the Update*BtnText below, which needs it to exist.
    DF.GUI:StyleButton(f.viewBtn, { width = 82, height = btnH, text = "" })
    f.viewBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -84, btnY)
    local VIEW_LABELS = {
        functions = "Functions",
        events    = "|cff00ff00Events|r",
        updates   = "|cff00ff00OnUpdate|r",
    }
    local VIEW_NEXT = {
        functions = "events",
        events    = "updates",
        updates   = "functions",
    }
    local function UpdateViewBtnText()
        f.viewBtn:SetText(VIEW_LABELS[Profiler.viewMode] or "Functions")
    end
    f.viewBtn:SetScript("OnClick", function()
        Profiler.viewMode = VIEW_NEXT[Profiler.viewMode] or "functions"
        UpdateViewBtnText()
        UpdateUI()
        UpdateColumnHeaders()
    end)
    f.viewBtn:SetScript("OnEnter", function(self)
        DF.GUI:ShowTooltip(self, {
            title = "View Mode",
            lines = {
                "Click to cycle: Functions → Events → OnUpdate.",
                "Functions: time per DF method",
                "Events: time per WoW event (UNIT_AURA, etc.)",
                "OnUpdate: time per OnUpdate handler (every-frame ticks)",
            },
        })
    end)
    f.viewBtn:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)
    UpdateViewBtnText()

    -- Split by Frame Type toggle button
    f.splitBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    -- text = "" so StyleButton creates AND registers its fontstring; the
    -- label itself is set by the Update*BtnText below, which needs it to exist.
    DF.GUI:StyleButton(f.splitBtn, { width = 50, height = btnH, text = "" })
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
        DF.GUI:ShowTooltip(self, {
            title = "Split by Frame Type",
            lines = { Profiler.splitByFrame
                and { text = "ON: Showing per-type breakdown (Party, Raid, HL-Party, HL-Raid).",
                      color = { 0, 1, 0 } }
                or  "OFF: Click to split results by frame type." },
        })
    end)
    f.splitBtn:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)
    UpdateSplitBtnText()

    -- ============================================================
    -- ONUPDATE TRACKING STRIP  (bottom of the window, above the rows)
    -- ============================================================
    -- What the toggle actually controls: a hooksecurefunc on the Frame
    -- metatable's SetScript (see the top of this file), which registers every
    -- OnUpdate handler a DF frame installs. That registry IS the OnUpdate tab —
    -- with the hook off, the tab has no data source and is simply empty.
    --
    -- ☠ It can only be installed at FILE-LOAD time: the hook has to be in place
    -- before frames install their handlers, or everything set up during login is
    -- invisible. Hence /rl, and hence the setting living in DandersFramesDB_v2
    -- (account SavedVariables) rather than a profile — it must be readable
    -- before profiles initialise.
    --
    -- ⚠ FORWARD-DECLARED. The checkbox's OnClick closure below calls this, and
    -- the closure is built BEFORE the definition. Without this line the name
    -- resolves as a global at closure-creation time, reads nil, and clicking the
    -- box back to its current state throws "attempt to call a nil value" — the
    -- same out-of-scope-local trap that left 8 dead branches in ColorPicker.
    local UpdateHookBanner

    -- The real banner system, not a lookalike. This was a hand-built frame with
    -- two hand-mixed colour literals approximating the "caution" tone; SetTone
    -- gives the exact palette plus the matching icon, and cannot drift from the
    -- banners on the settings pages.
    --
    -- CreateInfoBanner self-measures its height and calls GUI:RelayoutHost. That
    -- is a no-op here — RelayoutHost only does work for a widget inside a
    -- settingsGroup, and walks the parent chain looking for a RefreshStates host
    -- it will never find on a floating window — so the banner simply sizes
    -- itself against the two anchors below.
    local hookBanner = DF.GUI:CreateInfoBanner(f, { tone = "caution" })
    hookBanner:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 6)
    hookBanner:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 6)
    f.hookBanner = hookBanner

    local hookCheckbox = CreateFrame("CheckButton", nil, hookBanner, "BackdropTemplate")
    hookCheckbox:SetPoint("RIGHT", -6, 0)
    DF.GUI:StyleCheckButton(hookCheckbox)
    hookCheckbox:SetChecked(self.onUpdateHookEnabled)
    hookCheckbox:SetScript("OnClick", function(cb)
        if not DandersFramesDB_v2 then DandersFramesDB_v2 = {} end
        local newState = cb:GetChecked()
        DandersFramesDB_v2.profilerOnUpdateHook = newState
        if newState == self.onUpdateHookEnabled then
            -- Toggled back to what is already live — no reload needed.
            UpdateHookBanner()
        else
            hookBanner:SetTone("caution")
            hookBanner:SetText(newState
                and "OnUpdate tracking will be ON after /rl."
                or  "OnUpdate tracking will be OFF after /rl.")
        end
    end)
    hookCheckbox:SetScript("OnEnter", function(cb)
        DF.GUI:ShowTooltip(cb, {
            title = "Track OnUpdate handlers",
            lines = {
                "Hooks SetScript so the profiler can see every OnUpdate a DF frame installs. This is the data source for the OnUpdate tab — with it off, that tab is empty.",
                "Applies at load only, so a /rl is required either way.",
            },
        })
    end)
    hookCheckbox:SetScript("OnLeave", function() DF.GUI:HideTooltip() end)

    local hookLabel = hookBanner:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    hookLabel:SetPoint("RIGHT", hookCheckbox, "LEFT", -2, 0)
    hookLabel:SetText("Track OnUpdate")

    -- Keep the banner's body clear of the toggle. The factory anchors the body
    -- TOPLEFT-of-icon and RIGHT-of-banner; re-issue BOTH points rather than just
    -- the right one, so there is no question of a stale anchor surviving.
    hookBanner.body:ClearAllPoints()
    hookBanner.body:SetPoint("TOPLEFT", hookBanner.icon, "TOPRIGHT", 8, -5)
    hookBanner.body:SetPoint("RIGHT", hookLabel, "LEFT", -10, 0)

    -- ☠ The strip stays VISIBLE in both states. It used to Hide() itself once
    -- the hook was on — and the checkbox lives inside it, so the only way to
    -- turn tracking back off was the /df debug profiler hook command. A toggle
    -- you can reach in one direction only is not a toggle.
    function UpdateHookBanner()
        if self.onUpdateHookEnabled then
            hookBanner:SetTone("info")
            hookBanner:SetText("OnUpdate tracking is on.")
        else
            hookBanner:SetTone("caution")
            hookBanner:SetText("OnUpdate tracking is off — the OnUpdate tab will be empty.")
        end
        hookCheckbox:SetChecked(DandersFramesDB_v2 and DandersFramesDB_v2.profilerOnUpdateHook or false)
        hookBanner:Show()
    end
    UpdateHookBanner()

    -- Column headers
    local xOffset = CONTENT_LEFT + 2
    for _, col in ipairs(COLUMNS) do
        local hdr = CreateFrame("Button", nil, f)
        hdr:SetHeight(18)
        hdr:SetPoint("TOPLEFT", f, "TOPLEFT", xOffset, HEADER_Y)
        hdr:SetWidth(col.width)

        local text = hdr:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
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

    -- Column legend, stacked ABOVE the hook banner.
    -- ☠ It used to be anchored to the frame's own bottom at y=8 — which is inside
    -- the banner's rect. That was survivable only while the banner HID itself
    -- whenever tracking was on; now that the banner is always visible (so the
    -- toggle is reachable in both directions) the legend sat behind it
    -- permanently, bleeding through as ghost text. Anchor to the banner instead
    -- of to the frame, so it also tracks the banner if its text ever wraps.
    local infoLabel = f:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    infoLabel:SetPoint("BOTTOMLEFT", f.hookBanner, "TOPLEFT", 2, 6)
    infoLabel:SetTextColor(0.4, 0.4, 0.4)
    infoLabel:SetJustifyH("LEFT")
    -- Two lines. The first says what the numbers ARE, which matters because
    -- Total and Self answer different questions and only one of them adds up.
    infoLabel:SetText(
        "Total = inclusive (counts nested profiled calls)  |  Self = excludes them — this is what % ranks, and % sums to 100\n" ..
        "Peak/tk = max calls in one frame  |  Bytes = avg alloc per call  |  wrapper overhead subtracted; a row cheaper than it reads 0.00, not below zero")

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
