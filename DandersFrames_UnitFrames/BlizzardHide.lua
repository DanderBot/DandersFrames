local addonName, UF = ...

-- ============================================================
-- BLIZZARD FRAME HIDING
-- Per unit, by its `source`:
--   "DF"       we draw it: Blizzard's frame is hidden
--   "Hidden"   nobody draws it: Blizzard's frame is hidden and ours is not spawned
--   "Blizzard" Blizzard draws it: left alone, ours is not spawned
-- Restoring a hidden Blizzard frame needs a reload (no live restore): once its
-- events are stripped and it is reparented it cannot be put back cleanly.
--
-- Method (spec §1.6), using DandersFrames' shared helpers (DF.BlizzardHide):
--   * claim the frame first (DF:ClaimBlizzardFrame), so DandersFrames' own
--     handling of it -- Hide Default Player Frame -- stands down;
--   * strip its events (and its bars'), reparent it to DF's hidden parent --
--     out of combat only, queued for PLAYER_REGEN_ENABLED otherwise;
--   * Edit Mode re-parents its system frames on every enter/exit, so a SetParent
--     hook re-hides the frame ONE FRAME LATER (C_Timer.After(0)). Doing it inside
--     the hook would run inside Blizzard's secure Edit Mode pass and taint secret
--     reads. While Edit Mode is open the re-hide waits for its EditMode.Exit callback;
--   * the class alt-power bars (stagger, Ebon Might, soul fragments, alternate
--     power) sit under PlayerFrame: their events are unregistered and they are
--     NEVER reparented themselves (Edit-Mode managed; reparenting them taints).
--
-- Boss (spec §1.6): ONLY the container (BossTargetFrameContainer) is reparented.
-- The individual boss frames (Boss1TargetFrame..) have their events stripped and
-- are hidden where they stand: reparenting them breaks the container's layout.
-- Every Blizzard boss frame is hidden, including any beyond our slot count.
--
-- Target of target rides inside TargetFrame: hiding the target hides it too. On
-- its own (target from Blizzard, target of target ours or hidden) only
-- TargetFrameToT is hidden. A "Blizzard" target of target under a hidden target
-- cannot show -- there is no TargetFrame for it to live in.
-- ============================================================

local DF = DandersFrames
if not DF then return end

local ipairs, pairs, type, pcall = ipairs, pairs, type, pcall
local InCombatLockdown = InCombatLockdown

local BH = {}
UF.BlizzardHide = BH

BH.OWNER = "DandersFrames_UnitFrames"

-- Blizzard frames (global names) each unit hides.
BH.FRAMES = {
    player = { "PlayerFrame" },
    target = { "TargetFrame" },
    targettarget = { "TargetFrameToT" },
    -- FocusFrame carries its own target-of-focus inside it, hidden with it. On its
    -- own (focus from Blizzard, focus target ours or hidden) only that is hidden.
    -- ⚠ The global name FocusFrameToT is unverified in game on 12.x.
    focus = { "FocusFrame" },
    focustarget = { "FocusFrameToT" },
    -- Hidden on its own, whatever the player's source (unverified in game whether
    -- 12.x still parents it to PlayerFrame; the claim + reparent works either way).
    pet = { "PetFrame" },
}

-- Blizzard's boss frames. ⚠ Names taken from the live 12.x client's FrameXML as
-- other addons use them (ElvUI hides the same two); not yet checked in game here.
BH.BOSS_CONTAINER = "BossTargetFrameContainer"
BH.BOSS_FRAME = "Boss%dTargetFrame"

-- How many Blizzard boss frames there are (MAX_BOSS_FRAMES; our count otherwise).
function BH:BossFrameCount()
    local n = tonumber(MAX_BOSS_FRAMES)
    if not n or n < (UF.BOSS_COUNT or 5) then n = UF.BOSS_COUNT or 5 end
    return n
end

function BH:BossFrameNames()
    local list = {}
    for i = 1, BH:BossFrameCount() do list[#list + 1] = string.format(BH.BOSS_FRAME, i) end
    return list
end

-- Class bars Blizzard parents under PlayerFrame, keyed by the class that gets
-- them ("ANY" = encounter alternate power). A missing global is skipped.
BH.PLAYER_CLASS_BARS = {
    DemonHunterSoulFragmentsBar = "DEMONHUNTER",
    EvokerEbonMightBar = "EVOKER",
    MonkStaggerBar = "MONK",
    AlternatePowerBar = "ANY",
}

-- Blizzard's player cast bar (spec §1.6, Q7). global.hideBlizzardCastbar:
--   true / false   the user's own choice
--   nil (default)  FOLLOWS our player cast bar: hidden while unit frames draw the
--                  player and its cast bar is on, shown otherwise -- one cast bar,
--                  never two (DandersUF's double-cast-bar bug) and never none.
-- Like the frames above, showing it again needs a reload.
BH.CASTBAR = "PlayerCastingBarFrame"

-- Child bars that keep their own event registrations after the frame's are gone.
local CHILD_KEYS = { "healthbar", "manabar", "spellbar", "powerBarAlt", "totFrame" }

BH.hidden = {}      -- frame -> the hidden parent it was given
BH.watched = {}     -- frame -> true once its SetParent hook is in
BH.strays = {}      -- frames moved off their hidden parent, put back on the next sweep

-- Our own hidden parent, used only when DF's helpers are missing.
local fallbackParent

function BH:ShouldHide(unit)
    local src = UF:GetUnitDB(unit).source
    return src == nil or src == "DF" or src == "Hidden"
end

local function Unregister(obj)
    if type(obj) == "table" and obj.UnregisterAllEvents then pcall(obj.UnregisterAllEvents, obj) end
end

function BH:StripFrame(frame)
    local helpers = DF.BlizzardHide
    if helpers and helpers.StripEvents and frame.unit then
        helpers.StripEvents(frame, true)
    else
        Unregister(frame)
    end
    for _, key in ipairs(CHILD_KEYS) do
        Unregister(frame[key])
    end
end

local function Reparent(frame)
    local helpers = DF.BlizzardHide
    if helpers and helpers.Reparent then
        helpers.Reparent(frame)
    else
        if not fallbackParent then
            fallbackParent = CreateFrame("Frame")
            fallbackParent:Hide()
        end
        frame:SetParent(fallbackParent)
        frame:Hide()
    end
    BH.hidden[frame] = frame:GetParent()
end

local sweepQueued, editModeWatched = false, false

local function EditModeOpen()
    return EditModeManagerFrame and EditModeManagerFrame:IsShown() and true or false
end

-- Put every stray back on its hidden parent. While Edit Mode is open nothing
-- moves: its "EditMode.Exit" callback (and the re-parent pass Edit Mode does on
-- close, which trips the hook again) runs the sweep once it shuts.
function BH:SweepStrays()
    sweepQueued = false
    if EditModeOpen() then return end
    for frame in pairs(BH.strays) do
        BH.strays[frame] = nil
        if frame:GetParent() ~= BH.hidden[frame] then
            UF:RunOutOfCombat("rehide:" .. tostring(frame:GetName()), function() Reparent(frame) end)
        end
    end
end

-- Next frame, never inside the hook: that runs in Blizzard's secure Edit Mode
-- pass, and reparenting there taints secret reads.
local function QueueSweep()
    if sweepQueued then return end
    sweepQueued = true
    C_Timer.After(0, function() BH:SweepStrays() end)
end

local function Watch(frame)
    if BH.watched[frame] then return end
    BH.watched[frame] = true
    hooksecurefunc(frame, "SetParent", function(self, parent)
        if parent == BH.hidden[self] then return end
        BH.strays[self] = true
        QueueSweep()
    end)
    if not editModeWatched and EventRegistry and EventRegistry.RegisterCallback then
        editModeWatched = true
        EventRegistry:RegisterCallback("EditMode.Exit", QueueSweep, BH)
    end
end

-- Hide one Blizzard frame now. Out of combat only (the caller queues).
function BH:HideFrame(name)
    local frame = _G[name]
    if type(frame) ~= "table" then return false end
    if InCombatLockdown() then return false end
    BH:StripFrame(frame)
    Reparent(frame)
    Watch(frame)
    UF.Debug("hid Blizzard %s", name)
    return true
end

-- Boss: strip + hide each boss frame in place, reparent only the container.
-- Out of combat only (the caller queues).
function BH:HideBoss()
    if InCombatLockdown() then return false end
    for _, name in ipairs(BH:BossFrameNames()) do
        local frame = _G[name]
        if type(frame) == "table" then
            BH:StripFrame(frame)
            if frame.Hide then pcall(frame.Hide, frame) end
        end
    end
    local c = _G[BH.BOSS_CONTAINER]
    if type(c) == "table" then
        Reparent(c)
        Watch(c)
    end
    UF.Debug("hid Blizzard boss frames")
    return true
end

-- Events only, combat-legal; never reparented.
function BH:SilencePlayerClassBars()
    for name in pairs(BH.PLAYER_CLASS_BARS) do
        Unregister(_G[name])
    end
end

-- Claim, then hide (now or after combat).
function BH:HideUnit(unit)
    if unit == "boss" then
        if DF.ClaimBlizzardFrame then
            DF:ClaimBlizzardFrame(BH.BOSS_CONTAINER, BH.OWNER)
            for _, name in ipairs(BH:BossFrameNames()) do DF:ClaimBlizzardFrame(name, BH.OWNER) end
        end
        UF:RunOutOfCombat("hide:boss", function() BH:HideBoss() end)
        return
    end
    local names = BH.FRAMES[unit]
    if not names then return end
    for _, name in ipairs(names) do
        if DF.ClaimBlizzardFrame then DF:ClaimBlizzardFrame(name, BH.OWNER) end
        UF:RunOutOfCombat("hide:" .. name, function() BH:HideFrame(name) end)
    end
    if unit == "player" then BH:SilencePlayerClassBars() end
end

-- Our own player cast bar is drawn (the default the setting follows).
function BH:OwnPlayerCastBar()
    local db = UF:GetUnitDB("player")
    local src = db.source
    return (src == nil or src == "DF") and db.castbarEnabled and true or false
end

function BH:ShouldHideCastBar()
    local g = UF:GetGlobalDB()
    local v = g and g.hideBlizzardCastbar
    if v == true or v == false then return v end
    return BH:OwnPlayerCastBar()
end

function BH:ApplyAll()
    for _, unit in ipairs(UF.SPAWNED_UNITS) do
        if BH:ShouldHide(unit) then BH:HideUnit(unit) end
    end
    if BH:ShouldHideCastBar() then
        UF:RunOutOfCombat("hide:" .. BH.CASTBAR, function() BH:HideFrame(BH.CASTBAR) end)
    end
end
