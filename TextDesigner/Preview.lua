local addonName, DF = ...

-- ============================================================
-- TEXT DESIGNER — PREVIEW
-- Renders TD text elements as FontStrings onto the existing
-- static demo mock frame in Options.lua's preview panel.
-- The mock frame itself is owned by Options.lua (not this module).
-- ============================================================

DF.TextDesigner = DF.TextDesigner or {}
local Preview = {}
DF.TextDesigner.Preview = Preview

local activeMockFrame = nil
local activeTdDB = nil

-- Called from TextDesigner/Options.lua's BuildTextDesignerPage to
-- bind this module to the current mock frame + tdDB. Mode switching
-- calls this again with a new mock frame; we tear down the old
-- FontStrings before re-binding.
function Preview:Init(mockFrame, tdDB)
    if activeMockFrame and activeMockFrame ~= mockFrame then
        if DF.TextDesigner.Render then
            DF.TextDesigner.Render:Teardown(activeMockFrame)
        end
    end
    activeMockFrame = mockFrame
    activeTdDB = tdDB
    self:RefreshAll()
end

-- Refreshes all TD FontStrings on the bound mock frame using
-- synthetic mock data. Called on settings changes (FullRebuildCards,
-- eye-icon toggle, master toggle).
-- Cheap refresh: ONLY the preview mock frame, no live frames. Use this as the
-- lightweight callback during continuous edits (e.g. dragging the colour
-- picker) so we don't hammer every party/raid frame with a full refresh each
-- tick — that's what made colour changes lag. The full RefreshAll runs once on
-- release.
function Preview:RefreshPreview()
    if not activeMockFrame or not activeTdDB then return end
    local Render = DF.TextDesigner.Render
    local DataSource = DF.TextDesigner.DataSource
    if not Render or not DataSource then return end
    Render:UpdateFrame(activeMockFrame, activeTdDB, DataSource.Mock(), "all", true)
end

-- Refreshes every live unit frame + pinned boss frame's TD text. Separated out
-- so RefreshAll and the throttled drag path can share it.
function Preview:RefreshLiveFrames()
    if DF.UpdateTextDesigner and DF.unitFrameMap then
        for _, frame in pairs(DF.unitFrameMap) do
            DF:UpdateTextDesigner(frame, "all")
        end
    end
    -- Test-mode frames live in a SEPARATE pool (DF.testPartyFrames / testRaidFrames,
    -- marked dfIsTestFrame) — NOT in unitFrameMap — so the loop above skips them.
    -- Without this, Text Designer edits never show on the test frames the designer
    -- is actually looking at. UpdateTextDesigner self-sources mock data via
    -- DataSource.Test on a test frame, so a light TD-only refresh is enough.
    if DF.UpdateTextDesigner and (DF.testMode or DF.raidTestMode) then
        if DF.testMode and DF.testPartyFrames then
            for _, f in pairs(DF.testPartyFrames) do
                if f and f:IsShown() then DF:UpdateTextDesigner(f, "all") end
            end
        end
        if DF.raidTestMode and DF.testRaidFrames then
            for _, f in pairs(DF.testRaidFrames) do
                if f and f:IsShown() then DF:UpdateTextDesigner(f, "all") end
            end
        end
    end
    -- Pinned frames come in two kinds — boss-type sets (bossFrames) and
    -- player-type sets (secure-header children). RefreshTextDesigner walks both;
    -- the old inline loop here only reached boss sets, so player pinned groups
    -- never picked up TD element edits until a full rebuild (e.g. test-mode toggle).
    if DF.PinnedFrames and DF.PinnedFrames.RefreshTextDesigner then
        DF.PinnedFrames:RefreshTextDesigner()
    end
end

function Preview:RefreshAll()
    DF:Debug("TD", "Preview:RefreshAll called, mockFrame=%s tdDB=%s",
        tostring(activeMockFrame), tostring(activeTdDB))
    self:RefreshPreview()
    self:RefreshLiveFrames()
end

-- Throttled refresh for continuous edits (colour-picker drag). The preview mock
-- frame updates every call (one frame, cheap); live frames update at most every
-- ~0.03s so dragging stays live without a full all-frames refresh every tick
-- (that was the lag). The full RefreshAll still runs once on release.
local lastThrottledLive = 0
function Preview:RefreshThrottled()
    self:RefreshPreview()
    local now = GetTime and GetTime() or 0
    if now > 0 and (now - lastThrottledLive) < 0.03 then return end
    lastThrottledLive = now
    self:RefreshLiveFrames()
end
