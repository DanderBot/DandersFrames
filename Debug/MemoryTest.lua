local addonName, DF = ...

-- ============================================================
-- MEMORY TEST PANEL
-- Switch major systems off one at a time to find what a frame is spending
-- its memory on. Usage: /df debug memtest
--
-- ☠ THE FLAGS ONLY BITE WHILE THIS PANEL IS OPEN.
-- Consumers must read them through DF:MemTestDisabled (Core.lua), which is
-- false unless DF.MemTestArmed is true — and that is only true between this
-- panel's OnShow and OnHide. Closing the panel restores every flag and pushes a
-- re-apply, so a forgotten tick can never outlive the window and no live frame
-- can be left in a disabled state. Never read DF.MemTest directly in a guard.
--
-- ☠ HOW THE FLAGS ARE MEANT TO WORK (read before adding one)
-- Every flag here is consumed by a guard in the system it names. On 12.1 a
-- guard that merely SKIPS the update is not enough: the aura rows are native
-- containers that Blizzard renders and self-updates from the sealed side, so
-- skipping our update stops our DECISIONS and leaves the auras on screen and
-- the memory allocated. Flags that own a container therefore fold into that
-- system's render gate (DF:UseFactoryForBuffs and friends) so the existing
-- "factory inactive -> hide it" path runs, or tear down explicitly on the
-- transition (Aura Designer, Text Designer). Unticking a box has to RELEASE
-- something, or the reading will not move and the box is lying to you.
-- ============================================================

-- Global flags that other systems check. All default to true (enabled).
-- Every key below has at least one reader — grep "MemTest" before adding one,
-- and wire the guard in the same change. A checkbox with no reader is worse
-- than no checkbox: it reads as evidence that the system is not the problem.
DF.MemTest = {
    -- Aura pipeline (12.1 native containers)
    enableAuras = true,                 -- Features/Auras.lua  UseFactoryForBuffs/Debuffs
    enableDispel = true,                -- Features/Dispel.lua  UpdateDispelOverlay
    enableDefensive = true,             -- Features/Auras.lua  UseFactoryForDefensive
    enableMissingBuff = true,           -- Features/Auras.lua  UseFactoryForMissingBuff
    enableAuraDesigner = true,          -- AuraDesigner/Factory.lua  Factory:SyncFrame
    -- Frame rendering
    enableTextDesigner = true,          -- TextDesigner/Render.lua  UpdateTextDesigner
    enableRange = true,                 -- Features/Range.lua
    enableHealthFade = true,            -- Features/HealthFade.lua
    enableHighlights = true,            -- Features/Highlights.lua
    enableHealPrediction = true,        -- Frames/Bars.lua
    enableAbsorbs = true,               -- Frames/Bars.lua
    -- Event-driven updates
    enableTargetedSpells = true,        -- Features/TargetedSpells.lua
    enableHealthUpdates = true,         -- Frames/Create.lua  OnEvent
    enablePowerBar = true,              -- Frames/Create.lua  OnEvent
    enableNameUpdates = true,           -- Frames/Create.lua  OnEvent
    enableRoleLeaderIcons = true,       -- Frames/Bars.lua  UpdateRoleIcon/UpdateLeaderIcon
    enableStatusIcons = true,           -- Frames/Create.lua  OnEvent
    enableConnectionStatus = true,      -- Frames/Create.lua  OnEvent
    enableAnimations = true,            -- Frames/Border.lua  shared anim driver
    enableClickCastApplyBindings = true,-- ClickCasting/Bindings.lua  CC:ApplyBindings
    enableAllEvents = true,             -- Frames/Create.lua  OnEvent (nuclear)
}

local GUI = DF.GUI

local frame = nil
local allCheckboxes = {}        -- { container, ... } — each carries .perfKey

-- ☠ "QUEUED" HAS TO MEAN QUEUED.
-- ApplyMemTestFlags cannot touch containers in combat, and the RESTORE path
-- (DisarmAndRestore, on panel close) runs through it. The teardown latches the
-- flags set — frame.dfADMemTestCleared / frame.dfTDMemTestCleared — only clear
-- when Factory:SyncFrame / UpdateTextDesigner is next CALLED, so without a real
-- retry, closing the panel mid-combat left those systems torn down until some
-- organic event happened to re-drive that frame. The old code printed "queued"
-- and dropped the work. The OnEvent handler is installed further down, after
-- ApplyMemTestFlags exists.
local pendingApply = false
local regenFrame = CreateFrame("Frame")

-- ============================================================
-- APPLYING A FLAG
-- ============================================================
-- Flipping a flag only changes what the NEXT update does, and the teardown
-- paths — which are what actually free memory — live INSIDE those updates. A
-- quiet frame may not tick again for a long time, so push one pass over every
-- frame right after a change instead of waiting for an organic event. Without
-- this the panel appears inert for seconds at a time and the memory reading
-- lags the checkbox that caused it.
local function ApplyMemTestFlags()
    if InCombatLockdown() then
        pendingApply = true
        regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        DF:Say("Memory test", "queued — applying when combat ends", "WARN")
        return
    end

    if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end

    -- Row/icon systems own their own "update all" entry points.
    if DF.UpdateAllAuras then DF:UpdateAllAuras() end
    if DF.UpdateAllDefensiveBars then DF:UpdateAllDefensiveBars() end
    if DF.UpdateAllMissingBuffIcons then DF:UpdateAllMissingBuffIcons() end
    if DF.UpdateAllRoleIcons then DF:UpdateAllRoleIcons() end

    -- The rest are per-frame calls with no "all" wrapper.
    local function perFrame(f)
        if not f or not f:IsShown() then return end
        if DF.UpdateDispelOverlay then DF:UpdateDispelOverlay(f) end
        if DF.UpdateTextDesigner then DF:UpdateTextDesigner(f) end
        if DF.UpdateLeaderIcon then DF:UpdateLeaderIcon(f) end
    end
    if DF.IteratePartyFrames then DF:IteratePartyFrames(perFrame) end
    if DF.IterateRaidFrames then DF:IterateRaidFrames(perFrame) end
end

-- ⚠ Installed HERE, below ApplyMemTestFlags, and not next to the CreateFrame
-- above: a handler written above the `local function` would resolve the name as
-- a GLOBAL and read nil when it fired. Unregister immediately so the frame is
-- fully idle whenever nothing is pending — this must cost nothing when the panel
-- has never been opened.
regenFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    if not pendingApply then return end
    pendingApply = false
    ApplyMemTestFlags()
end)

-- ============================================================
-- MEMORY READOUT
-- ============================================================
-- Deliberately plain FontStrings rather than GUI:CreateLabel: these update
-- twice a second, and CreateLabel's SetText re-measures and schedules a
-- C_Timer per call — correct for wrapping body text, wasteful for a counter.
local function CreateReadout(parent, tone)
    local fs = parent:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    local c = GUI:GetToneColor(tone)
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

local function CurrentMemory()
    UpdateAddOnMemoryUsage()
    return GetAddOnMemoryUsage(addonName)
end

-- Shared body of the timed tests. `seconds` is the window; the panel's own
-- monitor is paused for the duration so its allocations don't land in the
-- reading it is trying to take.
local function RunTimedTest(self, seconds, otherBtn)
    local wasPaused = frame.isPaused
    frame.isPaused = true
    frame.pauseBtn:SetText("Resume")
    frame.memText:SetText(("Memory: |c%sTESTING %ds...|r"):format(GUI:ToneHex("caution"), seconds))
    frame.deltaText:SetText("")

    self:Disable()
    if otherBtn then otherBtn:Disable() end
    DF:Say(("Starting %d second memory test"):format(seconds), "UI paused", "NEUTRAL")

    collectgarbage("collect")
    local startMem = CurrentMemory()
    local startTime = GetTime()

    C_Timer.After(seconds, function()
        collectgarbage("collect")
        local endMem = CurrentMemory()
        local elapsed = GetTime() - startTime
        local delta = endMem - startMem
        local perSec = elapsed > 0 and (delta / elapsed) or 0

        local o = DF:Out("Memory Test", ("%d second window"):format(seconds))
        o:Field("Start", ("%.2f KB"):format(startMem))
        o:Field("End (after GC)", ("%.2f KB"):format(endMem))
        o:Field("Delta", ("%.2f KB over %.1fs"):format(delta, elapsed))
        o:Field("Rate", ("%.3f KB/s"):format(perSec),
            perSec > 0.5 and "BAD" or perSec > 0.1 and "WARN" or "GOOD")

        self:Enable()
        if otherBtn then otherBtn:Enable() end
        if not wasPaused then
            frame.isPaused = false
            frame.pauseBtn:SetText("Pause Monitor")
            frame.lastMem = endMem
            frame.lastTime = GetTime()
        end
    end)
end

-- ============================================================
-- PANEL
-- ============================================================

-- Column contents. `tip` becomes the label hover tooltip (GUI:AttachTooltip
-- reads widget.tooltip at hover time), so each box can say what it actually
-- switches off — the old panel gave no clue which code path a name meant.
local COL_LEFT = {
    { key = "enableAuras",         label = "Auras (Buffs/Debuffs)",
      tip = "The buff and debuff rows. On 12.1 these are native aura containers — unticking hides the container, which is what frees the memory." },
    { key = "enableDispel",        label = "Dispel Overlay",
      tip = "The dispel-type tint driven by the container's overlay slots." },
    { key = "enableDefensive",     label = "Defensive Icon",
      tip = "The defensive cooldown row (its own container)." },
    { key = "enableMissingBuff",   label = "Missing Buff Icon",
      tip = "The missing raid-buff strip (layout-push widget)." },
    { key = "enableAuraDesigner",  label = "Aura Designer",
      tip = "Every AD indicator, group and frame effect. Tears the AD containers down rather than freezing them." },
    { key = "enableTextDesigner",  label = "Text Designer",
      tip = "TD re-renders every element on every frame on every health tick — usually the largest single per-frame cost. Worth testing on its own." },
    { key = "enableRange",         label = "Range Checking" },
    { key = "enableHealthFade",    label = "Health Threshold Fade" },
    { key = "enableHighlights",    label = "Highlights (Target/Mouse)" },
    { key = "enableHealPrediction",label = "Heal Prediction" },
    { key = "enableAbsorbs",       label = "Absorb Shields" },
}

local COL_RIGHT = {
    { key = "enableHealthUpdates",  label = "Health Updates" },
    { key = "enablePowerBar",       label = "Power Bar" },
    { key = "enableNameUpdates",    label = "Name Updates" },
    { key = "enableTargetedSpells", label = "Targeted Spells" },
    { key = "enableRoleLeaderIcons",label = "Role/Leader Icons" },
    { key = "enableStatusIcons",    label = "Status Icons" },
    { key = "enableConnectionStatus", label = "Connection Status" },
    { key = "enableAnimations",     label = "Border Animations",
      tip = "Every animated border in the game rides one shared OnUpdate driver; this stops that driver. Borders resume mid-phase when re-ticked." },
    { key = "enableClickCastApplyBindings", label = "Click-Cast Bindings",
      tip = "Stops binding REBUILDS (~500 SetAttribute calls per frame, up to 80 frames). Bindings already applied stay live." },
}

local function AddCheckbox(parent, spec, x, y)
    local cb = GUI:CreateCheckbox(parent, spec.label, nil, nil,
        function() ApplyMemTestFlags() end,
        function() return DF.MemTest[spec.key] end,
        function(val) DF.MemTest[spec.key] = val end)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb.perfKey = spec.key
    if spec.tip then cb.tooltip = spec.tip end
    allCheckboxes[#allCheckboxes + 1] = cb
    return cb
end

local function SetAllFlags(value)
    for key in pairs(DF.MemTest) do
        DF.MemTest[key] = value
    end
    for _, cb in ipairs(allCheckboxes) do
        if cb.Refresh then cb:Refresh() end
    end
    ApplyMemTestFlags()
end

-- Closing the panel DISARMS the whole system and restores every flag, so live
-- frames can never be left switched off by a window the user walked away from.
-- Order matters: restore the values first, then drop the arm flag, then push
-- the re-apply — so the pass that follows sees everything enabled.
local function DisarmAndRestore()
    for key in pairs(DF.MemTest) do
        DF.MemTest[key] = true
    end
    DF.MemTestArmed = false
    for _, cb in ipairs(allCheckboxes) do
        if cb.Refresh then cb:Refresh() end
    end
    ApplyMemTestFlags()
end

local PAD      = 16
local COL_W    = 262
local ROW_STEP = GUI.RowHeight.checkbox   -- factory-owned; do not hand-pick a number

local function CreateMemTestFrame()
    if frame then
        frame:Show()
        return frame
    end

    wipe(allCheckboxes)

    -- ☠ The checkbox factory auto-registers custom-get/set widgets with the
    -- options SEARCH index. These are debug flags on a floating window, not
    -- settings on a page — indexing them would put "Auras (Buffs/Debuffs)" in
    -- the options search pointing at a surface search cannot open. Suppress for
    -- the build and restore after. (Usually already a no-op: Register bails
    -- once RegistryBuilt is set, which it is as soon as the options window has
    -- been opened once. This covers the case where it has not.)
    local searchWasBuilt = DF.Search and DF.Search.RegistryBuilt
    if DF.Search then DF.Search.RegistryBuilt = true end

    frame = CreateFrame("Frame", "DFMemTestFrame", UIParent, "BackdropTemplate")
    frame:SetSize(PAD * 2 + COL_W * 2, 660)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    GUI:CreatePanelBackdrop(frame)

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
    title:SetText("Memory Test")

    local closeBtn = GUI:CreateCloseButton(frame, {
        onClick = function() frame:Hide() end,
        tooltip = "Close",
    })
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -PAD)

    local subtitle = GUI:CreateNote(frame,
        "Untick a system to switch it off, then watch the memory rate. Changes apply immediately (out of combat).",
        { width = COL_W * 2 - 30 })
    subtitle:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(PAD + 24))

    -- Memory readouts
    frame.memText = CreateReadout(frame, "caution")
    frame.memText:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(PAD + 66))
    frame.memText:SetText("Memory: --")

    frame.deltaText = CreateReadout(frame, "info")
    frame.deltaText:SetPoint("LEFT", frame.memText, "RIGHT", 20, 0)
    frame.deltaText:SetText("Delta: --")

    frame.gcMemText = CreateReadout(frame, "success")
    frame.gcMemText:SetPoint("LEFT", frame.deltaText, "RIGHT", 20, 0)
    frame.gcMemText:SetText("After GC: --")

    -- Column headers + checkboxes
    local headerY = -(PAD + 90)
    local rowY    = headerY - GUI.RowHeight.sectionHeader

    local leftHeader = GUI:CreateHeader(frame, "Frame Systems")
    leftHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, headerY)
    local rightHeader = GUI:CreateHeader(frame, "Additional Systems")
    rightHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + COL_W, headerY)

    for i, spec in ipairs(COL_LEFT) do
        AddCheckbox(frame, spec, PAD, rowY - (i - 1) * ROW_STEP)
    end
    for i, spec in ipairs(COL_RIGHT) do
        AddCheckbox(frame, spec, PAD + COL_W, rowY - (i - 1) * ROW_STEP)
    end

    -- Nuclear option, below both columns
    local nuclearY = rowY - #COL_LEFT * ROW_STEP - 8
    local nuclear = AddCheckbox(frame, {
        key = "enableAllEvents",
        label = ("|c%sALL EVENTS|r  (disables the entire OnEvent handler)"):format(GUI:ToneHex("danger")),
        tip = "The nuclear option: the unit-frame event handler stops entirely. If memory still climbs with this off, the cost is not in DandersFrames' event path.",
    }, PAD, nuclearY)
    nuclear:SetWidth(COL_W * 2 - PAD)

    -- Button rows
    local actionRow = GUI:CreateButtonRow(frame, {
        { label = "Pause Monitor", width = 110, key = "pause",
          tooltip = { title = "Pause Monitor", lines = { "Stops this panel's own 2 Hz memory poll, so the panel is not measuring itself." } },
          onClick = function(self)
              frame.isPaused = not frame.isPaused
              if frame.isPaused then
                  self:SetText("Resume")
                  frame.memText:SetText(("Memory: |c%s-- PAUSED --|r"):format(GUI:ToneHex("info")))
                  frame.deltaText:SetText("")
              else
                  self:SetText("Pause Monitor")
                  frame.lastMem = 0
                  frame.lastTime = GetTime()
              end
          end },
        { label = "Run 10s Test", width = 105, key = "test10",
          onClick = function(self) RunTimedTest(self, 10, frame.test30Btn) end },
        { label = "Run 30s Test", width = 105, key = "test30",
          onClick = function(self) RunTimedTest(self, 30, frame.test10Btn) end },
    }, { width = COL_W * 2 - PAD })
    actionRow:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD + 32)
    frame.pauseBtn  = actionRow.buttons.pause
    frame.test10Btn = actionRow.buttons.test10
    frame.test30Btn = actionRow.buttons.test30

    local utilRow = GUI:CreateButtonRow(frame, {
        { label = "Force GC", width = 90,
          onClick = function()
              collectgarbage("collect")
              local mem = CurrentMemory()
              frame.gcMemText:SetText(("After GC: %.2f KB"):format(mem))
              DF:Say("Garbage collection done", ("%.2f KB"):format(mem), "NEUTRAL")
          end },
        { label = "Snapshot", width = 90,
          tooltip = { title = "Snapshot", lines = { "Takes a post-GC baseline. The third readout then tracks drift against it." } },
          onClick = function()
              collectgarbage("collect")
              frame.snapshotMem = CurrentMemory()
              DF:Say("Snapshot taken", ("%.2f KB"):format(frame.snapshotMem), "NEUTRAL")
          end },
        { label = "Disable All", width = 90,
          onClick = function()
              SetAllFlags(false)
              DF:Say("All systems", "DISABLED", "BAD")
          end },
        { label = "Enable All", width = 90,
          onClick = function()
              SetAllFlags(true)
              DF:Say("All systems", "ENABLED", "GOOD")
          end },
    }, { width = COL_W * 2 - PAD })
    utilRow:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)

    -- Live memory poll
    frame.lastMem = 0
    frame.lastTime = GetTime()
    frame.snapshotMem = nil
    frame:SetScript("OnUpdate", function(self, elapsed)
        if self.isPaused then return end

        self.elapsed = (self.elapsed or 0) + elapsed
        if self.elapsed < 0.5 then return end
        self.elapsed = 0

        local mem = CurrentMemory()
        local now = GetTime()
        local timeDelta = now - self.lastTime

        self.memText:SetText(("Memory: %.2f KB"):format(mem))

        if self.lastMem > 0 and timeDelta > 0 then
            local delta = (mem - self.lastMem) / timeDelta
            local tone = delta > 2 and "danger" or delta > 0.5 and "caution" or "success"
            self.deltaText:SetText(("Delta: |c%s%+.2f KB/s|r"):format(GUI:ToneHex(tone), delta))
        end

        if self.snapshotMem then
            local diff = mem - self.snapshotMem
            local tone = diff > 10 and "danger" or diff > 1 and "caution" or "success"
            self.gcMemText:SetText(("vs Snapshot: |c%s%+.2f KB|r"):format(GUI:ToneHex(tone), diff))
        end

        self.lastMem = mem
        self.lastTime = now
    end)

    -- ARM / DISARM. These two scripts are the entire safety story — every guard
    -- in the addon is inert unless DF.MemTestArmed is true.
    frame:SetScript("OnShow", function()
        DF.MemTestArmed = true
        for _, cb in ipairs(allCheckboxes) do
            if cb.Refresh then cb:Refresh() end
        end
    end)
    frame:SetScript("OnHide", DisarmAndRestore)

    if DF.Search then DF.Search.RegistryBuilt = searchWasBuilt end

    -- ⚠ Arm explicitly, do NOT rely on the OnShow above firing here: CreateFrame
    -- returns a frame that is already shown, and Show() on an already-shown
    -- frame fires nothing. Without this the panel would open DISARMED the very
    -- first time and every checkbox would appear to do nothing.
    DF.MemTestArmed = true
    frame:Show()
    return frame
end

local function ToggleMemTestFrame()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        CreateMemTestFrame()
    end
end

-- Slash command. The "/dfmemtest" alias is what makes "/df debug memtest" route:
-- RegisterDebugSlash strips the "/df" prefix off every /df-prefixed alias and
-- keys DF.DebugSlashBySub by the remainder.
DF:RegisterDebugSlash("DFMEMTEST", "Memory test suite", true, "/dfmemtest")
SlashCmdList["DFMEMTEST"] = ToggleMemTestFrame

-- (Removed) A delayed monkey-patch of SlashCmdList["DANDERSFRAMES"] used to make
-- "/df perftest" and "/df perf" work (this panel's former name). It wrapped the
-- dispatcher, so it answered BEFORE any routing rule inside it could apply —
-- which is how "/df perf" kept working through three rounds of removing exactly
-- that. The command is a normal RegisterDebugSlash entry and reachable as
-- "/df debug memtest"; nothing else was needed.
-- ☠ Never wrap the dispatcher: register the command instead.
