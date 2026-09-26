local addonName, DF = ...

-- ============================================================
-- FLAVOR CORRECTION
-- Profiles moving between retail and WoW Forever.
--
-- Aura Designer data is keyed by spell ids and retail spec kits, and neither carries
-- over: an AD setup made on one version draws nothing, or the wrong thing, on the other.
-- So when a profile arrives from the other version its AD data is PARKED — moved into
-- profile._parkedAD[<fromFlavor>] — and the live AD starts fresh. When the profile goes
-- back, its parked setup is restored. Nothing is deleted, because a user copying files
-- back and forth must get their retail setup back exactly as it was.
--
-- Two ways in:
--   * FILE COPY (SavedVariables moved between installs): FC.RunLoginPass at ADDON_LOADED.
--     Every profile carries _flavor; one made before this code existed has none and is
--     treated as retail's, because every profile predates Forever.
--   * STRING IMPORT: FC.AfterImport. An import is a COPY -- the string keeps everything --
--     so AD data from the other version is simply reset, not parked. The payload says
--     where it came from in `sourceFlavor` (older strings have none: retail).
--
-- Everything else spell-bearing needs no correction here: custom filters live in a
-- per-version store (FilterRegistry), and the other fields are validated at runtime.
-- ============================================================

local pairs, ipairs, type, next = pairs, ipairs, type, next

local FC = {}
DF.FlavorCorrection = FC

local MODES = { "party", "raid" }

local function ModeDefaults(mode)
    return mode == "raid" and DF.RaidDefaults or DF.PartyDefaults
end

-- A fresh copy of the mode's shipped `auraDesigner` default, or nil when there is none.
local function FreshModeAD(mode)
    local d = ModeDefaults(mode)
    local v = d and d.auraDesigner
    if type(v) == "table" then return DF:DeepCopy(v) end
    return v
end

-- Put the live Aura Designer data back to a fresh state. The preset library is lazily
-- recreated (with a fresh "Default") by DF:GetAuraDesignerPresets, and a mode pointing at
-- a preset name that no longer exists falls back to that Default.
local function ClearLiveAD(profile)
    profile.auraDesignerPresets = nil
    for _, mode in ipairs(MODES) do
        local m = profile[mode]
        if type(m) == "table" then
            m.auraDesigner = FreshModeAD(mode)
            m.auraDesignerPreset = nil
        end
    end
end

-- Move the live AD data into profile._parkedAD[flavor] and start fresh.
function FC.ParkAD(profile, flavor)
    if type(profile) ~= "table" or not flavor then return end
    local slot = { presets = profile.auraDesignerPresets, modes = {} }
    for _, mode in ipairs(MODES) do
        local m = profile[mode]
        if type(m) == "table" then
            slot.modes[mode] = { auraDesigner = m.auraDesigner, auraDesignerPreset = m.auraDesignerPreset }
        end
    end
    ClearLiveAD(profile)
    profile._parkedAD = profile._parkedAD or {}
    profile._parkedAD[flavor] = slot
end

-- Bring back what was parked for `flavor`. Returns true if there was a slot.
function FC.RestoreAD(profile, flavor)
    local parked = type(profile) == "table" and profile._parkedAD
    local slot = type(parked) == "table" and parked[flavor]
    if type(slot) ~= "table" then return false end
    profile.auraDesignerPresets = slot.presets
    for _, mode in ipairs(MODES) do
        local m = profile[mode]
        local s = type(slot.modes) == "table" and slot.modes[mode]
        if type(m) == "table" and type(s) == "table" then
            -- A mode that had no AD table when parked gets the shipped default rather
            -- than nil: the default-fill has already run by the time this can execute.
            m.auraDesigner = s.auraDesigner ~= nil and s.auraDesigner or FreshModeAD(mode)
            m.auraDesignerPreset = s.auraDesignerPreset
        end
    end
    parked[flavor] = nil
    if not next(parked) then profile._parkedAD = nil end
    return true
end

-- Bring one profile into `current` (defaults to this client). Returns true if it
-- arrived from the other version. Idempotent: a second call finds _flavor == current.
function FC.CrossProfile(profile, current)
    if type(profile) ~= "table" then return false end
    current = current or DF.CLIENT_FLAVOR
    local from = profile._flavor or "retail"
    if from == current then
        profile._flavor = current
        return false
    end
    FC.ParkAD(profile, from)
    FC.RestoreAD(profile, current)
    profile._flavor = current
    return true
end

-- ADDON_LOADED: every profile in the account DB. Returns how many crossed.
function FC.RunLoginPass(sv)
    sv = sv or DandersFramesDB_v2
    if type(sv) ~= "table" or type(sv.profiles) ~= "table" then return 0 end
    local crossed = 0
    for _, profile in pairs(sv.profiles) do
        if FC.CrossProfile(profile) then crossed = crossed + 1 end
    end
    FC.pendingCrossed = (FC.pendingCrossed or 0) + crossed
    return crossed
end

-- Profiles created during the session (new, copy, duplicate) are stamped at logout, so
-- the next login doesn't mistake a Forever-made profile for a retail one.
function FC.StampUnstamped(sv)
    sv = sv or DandersFramesDB_v2
    if type(sv) ~= "table" or type(sv.profiles) ~= "table" then return end
    for _, profile in pairs(sv.profiles) do
        if type(profile) == "table" and not profile._flavor then
            profile._flavor = DF.CLIENT_FLAVOR
        end
    end
end

-- After ApplyImportedProfile has landed. `profile` is the profile the import wrote into,
-- `adImported` whether the payload's AD libraries were applied. Returns true if the AD
-- data was reset.
function FC.AfterImport(profile, importData, adImported)
    if type(profile) ~= "table" then return false end
    local current = DF.CLIENT_FLAVOR
    local source = type(importData) == "table" and importData.sourceFlavor or "retail"
    profile._flavor = current
    if source == current or not adImported then return false end
    ClearLiveAD(profile)
    return true
end

-- ------------------------------------------------------------
-- LOGIN NOTICE + LOGOUT STAMP
-- ------------------------------------------------------------
-- The popup frame is a singleton: showing ours while another is up would replace it
-- (the changelog, a wizard). Wait for it to close, then show; give up after a minute.
local function ShowCrossedNotice(tries)
    if not (FC.pendingCrossed and FC.pendingCrossed > 0) then return end
    if not DF.ShowPopupAlert then return end
    if DF.IsPopupShown and DF:IsPopupShown() then
        if (tries or 0) < 30 then
            C_Timer.After(2, function() ShowCrossedNotice((tries or 0) + 1) end)
        end
        return
    end
    FC.pendingCrossed = 0
    local L = DF.L
    DF:ShowPopupAlert({
        title = L["Profiles From Another Game Version"],
        message = DF.IS_FOREVER
            and L["Some of your profiles came from retail. Their Aura Designer setup has been put aside because spell IDs differ on WoW Forever, and comes back if you use them on retail again.\n\nWoW Forever has no built-in spell list yet: create a custom filter in the Filter Designer and add spells by ID."]
            or L["Some of your profiles came from WoW Forever. Their Aura Designer setup has been put aside because spell IDs differ on retail, and comes back if you use them on WoW Forever again."],
        buttons = { { label = L["OK"], onClick = nil } },
    })
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(1, function() ShowCrossedNotice(0) end)
    elseif event == "PLAYER_LOGOUT" then
        FC.StampUnstamped()
    end
end)
