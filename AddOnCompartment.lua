local addonName, DF = ...                                               -- Get the add on name and DF environment
local raw, properName, note, _ = C_AddOns.GetAddOnInfo(addonName)       -- Get the properly formatted name and title note
local db = DF:GetDB()                                                   -- Get the DB Settings
DF.L = LibStub("AceLocale-3.0"):GetLocale("DandersFrames")              -- Get the localization
local L = DF.L                                                          -- Set the localization

if (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE) then                        -- If on Retail (this is only supported on 10.x and up
    -- if [settings check here] then                                    -- Optional check against a setting to enable this
        AddonCompartmentFrame:RegisterAddon({                           -- start adding to the addon compartment
            text = properName,                                          -- text in addon compartment
            icon = "Interface/AddOns/DandersFrames/Media/DF_Icon.tga",  -- icon in addon compartment
            notCheckable = true,
            func = function(button, menuInputData, menu)
                if menuInputData.buttonName == "LeftButton" then        -- if a left click
                    DF:ToggleGUI()                                      -- toggle GUI vibility
                elseif menuInputData.buttonName == "RightButton" then   -- if a right click
					-- add solo mode here
                end
            end,
            funcOnEnter = function(button)
                MenuUtil.ShowTooltip(button, function(tooltip)
                    tooltip:SetText(properName .. "\n" .. note)         -- Set mouse scroll over text
                end)
            end,
            funcOnLeave = function(button)
                MenuUtil.HideTooltip(button)
            end,
        })
    -- end
end