local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - SOUND ENGINE
-- Plays looping alert sounds when configured buffs are missing
-- from party/raid members. Runs an independent 1 Hz evaluation
-- ticker separate from the visual indicator pipeline.
--
-- State machine per aura: IDLE → DELAYED → PLAYING
-- Uses CVar-swap technique for per-indicator volume control.
-- ============================================================

local pairs = pairs
local GetCVar, SetCVar = GetCVar, SetCVar
local PlaySoundFile = PlaySoundFile
local StopSound = StopSound
local tonumber = tonumber

DF.AuraDesigner = DF.AuraDesigner or {}

local SoundEngine = {}
DF.AuraDesigner.SoundEngine = SoundEngine

-- States. ⚠ There was a third, STATE_DELAYED = 1, that nothing ever assigned or
-- compared — the delayed leg of this state machine was never wired, so a sound with
-- a configured delay goes straight IDLE -> PLAYING. Removed as dead, but worth
-- revisiting if per-sound delay is meant to work.
local STATE_IDLE    = 0
local STATE_PLAYING = 2

-- Per-aura state: { state, delayStart, ticker, lastHandle }
local soundStates = {}

-- ⚠ (Removed) `suppressUntil`, commented "Evaluation suppression (instance
-- transitions)", and `presenceData`, "Reusable presence table (wiped each
-- evaluation)". Both were declared and never read, so the suppression was never
-- implemented: nothing stops aura sounds evaluating across a loading screen or an
-- instance change. Flagged rather than quietly dropped — that is a MISSING feature,
-- not just unused storage.

-- ============================================================
-- SOUND PLAYBACK (CVar-swap for per-indicator volume)
-- ============================================================

-- Output channel for alert sounds. Default MASTER: alerts must be audible
-- even when the player mutes Sound Effects/Music to cut combat noise —
-- which is exactly when they rely on audio cues. The per-indicator volume
-- CVar-swap must target the SAME channel's volume CVar or it has no effect.
local SOUND_CHANNEL_CVARS = {
    Master   = "Sound_MasterVolume",
    SFX      = "Sound_SFXVolume",
    Music    = "Sound_MusicVolume",
    Ambience = "Sound_AmbienceVolume",
    Dialog   = "Sound_DialogVolume",
}

local function GetSoundChannel()
    local mode = DF.GetCurrentMode and DF:GetCurrentMode() or "party"
    local adCfg = (DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(mode))
        or (DF.GetDB and DF:GetDB(mode) and DF:GetDB(mode).auraDesigner)
    local channel = adCfg and adCfg.soundChannel
    if not channel or not SOUND_CHANNEL_CVARS[channel] then
        channel = "Master"
    end
    return channel, SOUND_CHANNEL_CVARS[channel]
end

function SoundEngine:PlayWithVolume(soundFile, volume)
    if not soundFile or volume <= 0 then return nil, nil end

    local channel, volCVar = GetSoundChannel()
    local originalVol = tonumber(GetCVar(volCVar)) or 1.0
    local targetVol = originalVol * volume
    if targetVol > 1.0 then targetVol = 1.0 end

    SetCVar(volCVar, targetVol)
    local willPlay, handle = PlaySoundFile(soundFile, channel)
    SetCVar(volCVar, originalVol)

    if not willPlay then
        DF:DebugWarn("AD", "SoundEngine: PlaySoundFile failed for: %s", tostring(soundFile))
        return nil, nil
    end

    return willPlay, handle
end

-- ============================================================
-- STATE MACHINE
-- ============================================================

local function StopTicker(state)
    if state.ticker then
        state.ticker:Cancel()
        state.ticker = nil
    end
end

local function StopLastSound(state)
    if state.lastHandle then
        StopSound(state.lastHandle)
        state.lastHandle = nil
    end
end

function SoundEngine:TransitionTo(auraName, newState)
    local s = soundStates[auraName]
    if not s then
        s = { state = STATE_IDLE }
        soundStates[auraName] = s
    end

    -- Cleanup previous state
    if s.state == STATE_PLAYING then
        StopTicker(s)
        StopLastSound(s)
    end

    s.state = newState
    if newState == STATE_IDLE then
        s.delayStart = nil
    end
end


-- ============================================================
-- CLEANUP
-- ============================================================

function SoundEngine:StopAll()
    for auraName, s in pairs(soundStates) do
        if s.state ~= STATE_IDLE then
            self:TransitionTo(auraName, STATE_IDLE)
        end
    end
end

function SoundEngine:StopAura(auraName)
    if soundStates[auraName] and soundStates[auraName].state ~= STATE_IDLE then
        self:TransitionTo(auraName, STATE_IDLE)
    end
    local expireKey = auraName .. "|expire"
    if soundStates[expireKey] and soundStates[expireKey].state ~= STATE_IDLE then
        self:TransitionTo(expireKey, STATE_IDLE)
    end
end

