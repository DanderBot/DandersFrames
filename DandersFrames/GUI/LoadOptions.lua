local addonName, DF = ...

-- ============================================================
-- OPTIONS LOADER — always loaded
-- ============================================================
-- The settings panel, both designers, the click-casting UI, test mode and the
-- debug tools live in DandersFrames_Options, a LoadOnDemand companion addon.
-- Nothing loads it automatically; this file is the single place that does.
--
-- While it stays unloaded DandersFrames uses 3,391 KB less (8,957 vs 12,348,
-- measured on the PTR build) and ~55,000 lines are never parsed at login.
--
-- ☠ The companion can be MISSING, DISABLED or STALE. A player can untick it in
-- the addon list, or install the zip incompletely. Every path below reports
-- that plainly rather than doing nothing: a settings panel that silently
-- refuses to open is the worst outcome, and is exactly the silent-skip failure
-- the migrations move was made to avoid.

local OPTIONS_ADDON = "DandersFrames_Options"

local LoadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
local GetAddOnEnableState = C_AddOns and C_AddOns.GetAddOnEnableState
local DoesAddOnExist = C_AddOns and C_AddOns.DoesAddOnExist

-- Human-readable reason the companion is not usable, or nil when it is fine.
local function UnavailableReason()
    if DoesAddOnExist and not DoesAddOnExist(OPTIONS_ADDON) then
        return "not installed"
    end
    if GetAddOnEnableState and GetAddOnEnableState(OPTIONS_ADDON, nil) == 0 then
        return "disabled in the AddOns list"
    end
    return nil
end

-- Load the companion, returning true once its files are in memory.
-- Safe to call repeatedly: LoadAddOn is a no-op once loaded.
function DF:EnsureOptionsLoaded()
    if DF._optionsAddonLoaded then return true end

    local why = UnavailableReason()
    if why then
        DF:Err(("Settings are unavailable: %s is %s."):format(OPTIONS_ADDON, why))
        return false
    end

    local loaded, reason = LoadAddOn(OPTIONS_ADDON)
    if not loaded then
        DF:Err(("Could not load %s (%s)."):format(OPTIONS_ADDON, tostring(reason)))
        return false
    end

    DF._optionsAddonLoaded = true
    return true
end

-- ☠ This stub is REPLACED by the real DF:ToggleGUI when the companion loads,
-- so the re-dispatch below reaches the real function rather than itself.
--
-- The identity check is the loop guard. If the companion ever loaded WITHOUT
-- defining ToggleGUI -- a renamed function, a file dropped from its .toc --
-- DF.ToggleGUI would still be this stub and a plain re-dispatch would recurse
-- until the stack blew. Comparing against the stub catches that and reports it.
local toggleStub
toggleStub = function()
    if not DF:EnsureOptionsLoaded() then return end
    if DF.ToggleGUI == toggleStub then
        DF:Err(("%s loaded but did not provide the settings panel -- its .toc may be incomplete."):format(OPTIONS_ADDON))
        return
    end
    return DF:ToggleGUI()
end
DF.ToggleGUI = toggleStub

-- ============================================================
-- COLOUR-PICKER GLOBAL OVERRIDE BOOTSTRAP
-- ============================================================
-- The setting promises DF's colour picker replaces Blizzard's EVERYWHERE --
-- including pickers opened by other addons and the stock UI. The hook that
-- delivers it installs at companion load, so for a user who enabled it the
-- feature silently reverted to the stock picker every session until they
-- opened /df once. If the setting is on, load the companion at login: only
-- users who opted into the override pay, and what they pay for is the
-- feature actually working.
local pickerBoot = CreateFrame("Frame")
pickerBoot:RegisterEvent("PLAYER_ENTERING_WORLD")
pickerBoot:SetScript("OnEvent", function(self, _, isInitialLogin, isReloadingUi)
    if not (isInitialLogin or isReloadingUi) then return end
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    local db = DF.db and DF.db.party
    if db and db.colorPickerGlobalOverride then
        DF:EnsureOptionsLoaded()
    end
end)
