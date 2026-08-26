-- ============================================================
-- COLOUR PICKER -- DandersFrames glue only.
-- ------------------------------------------------------------
-- The picker itself moved into the shared toolkit: the square/wheel editor,
-- the RGBA and hex readouts, the class/saved/recent palettes and the public
-- GUI:OpenColorPicker now live in Libs\DandersUI\ColorPicker.lua (canonical
-- source at <repo>/DandersUI/ColorPicker.lua), published as UI methods -- so
-- every existing GUI:OpenColorPicker(...) call site resolves through the host
-- metatable exactly as before. The two persisted palettes and the square/circle
-- preference reach our SavedVariables through the `pickerStore` hook wired in
-- GUI.lua, and the window title through `pickerTitle`.
--
-- What is left is everything that is about DandersFrames rather than about
-- picking a colour: the override that redirects Blizzard's ColorPickerFrame to
-- ours, the account-wide settings that decide when it does, the
-- DandersFrames-origin flag those settings are read against, and the
-- /dfcolorhook dev harness. All four read DF globals, DF's account DB or DF's
-- debug console, so none of them could travel with the widget.
--
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
-- ============================================================

local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L

-- Colour-picker tracing. This used to hang off a persisted db.party.colorPickerDebug
-- toggled by "/df debug colorhook debug" — the last boolean logging flag in the addon; it
-- survived the console consolidation only because it lived in the DB rather than on
-- DF, so the flag sweep did not see it. Now a console category (COLORPICKER, noisy:
-- the Blizzard sync below fires on every drag frame).
--
-- It stays on this side of the split: every one of its call sites is in the
-- Blizzard-override machinery below.
local cpDebug = DF:MakeDebugPrinter("COLORPICKER")

-- The pack's singleton picker frame, or nil before the first open.
local function PickerFrame()
    return GUI:GetColorPickerFrame()
end

-- ============================================================
-- BLIZZARD COLOR PICKER OVERRIDE SYSTEM
-- Hidden Blizzard + Visible Custom UI Approach
--
-- How it works:
-- 1. Let Blizzard's picker open normally (callbacks are set up internally)
-- 2. Hide Blizzard's picker visually
-- 3. Show our beautiful custom picker
-- 4. Sync color changes to hidden Blizzard picker (triggers callbacks automatically)
-- 5. OK/Cancel click Blizzard's buttons (proper callback execution)
-- ============================================================

local originalOpenColorPicker = nil
local originalSetupColorPickerAndShow = nil
local blizzardPickerHidden = false

-- Hide Blizzard's color picker visually while keeping it functional
local function HideBlizzardPicker()
    if not ColorPickerFrame then return end

    -- Prevent auto-close when clicking outside
    ColorPickerFrame:UnregisterEvent("GLOBAL_MOUSE_DOWN")

    -- Scale down to tiny size (minimizes any flicker before hide takes effect)
    ColorPickerFrame:SetScale(0.001)

    -- Hide visually but keep functional
    ColorPickerFrame:SetAlpha(0)
    ColorPickerFrame:EnableMouse(false)

    -- Move it way off screen so it doesn't interfere
    ColorPickerFrame:ClearAllPoints()
    ColorPickerFrame:SetPoint("CENTER", UIParent, "CENTER", 10000, 10000)

    blizzardPickerHidden = true
end


-- Sync color to Blizzard's hidden picker (this triggers addon callbacks automatically!)
local function SyncColorToBlizzard(r, g, b, a)
    if not ColorPickerFrame:IsShown() then return end

    cpDebug("Syncing to Blizzard:", r, g, b, a)


    -- Set color via the internal ColorPicker widget
    -- This triggers Blizzard's OnColorSelect which fires all addon callbacks naturally
    if ColorPickerFrame.Content and ColorPickerFrame.Content.ColorPicker then
        ColorPickerFrame.Content.ColorPicker:SetColorRGB(r, g, b)
        if ColorPickerFrame.hasOpacity and a and ColorPickerFrame.Content.ColorPicker.SetColorAlpha then
            ColorPickerFrame.Content.ColorPicker:SetColorAlpha(a)
        end
    end

    -- Also set directly on ColorPickerFrame for addons that read from there
    if ColorPickerFrame.SetColorRGB then
        ColorPickerFrame:SetColorRGB(r, g, b)
    end
    if ColorPickerFrame.hasOpacity and a and ColorPickerFrame.SetColorAlpha then
        ColorPickerFrame:SetColorAlpha(a)
    end
end


-- Click Blizzard's OK button with color sync (for external addon use)
local function ClickBlizzardOKWithColor(r, g, b, a)
    cpDebug("ClickBlizzardOKWithColor called:", r, g, b, a)


    if ColorPickerFrame and ColorPickerFrame.Footer and ColorPickerFrame.Footer.OkayButton then
        -- Mark as not hidden first (prevents cleanup hook from running)
        blizzardPickerHidden = false

        -- Restore properties so syncing works
        ColorPickerFrame:RegisterEvent("GLOBAL_MOUSE_DOWN")
        ColorPickerFrame:SetAlpha(1)
        ColorPickerFrame:EnableMouse(true)

        -- Sync final color directly before clicking OK
        if ColorPickerFrame.Content and ColorPickerFrame.Content.ColorPicker then
            ColorPickerFrame.Content.ColorPicker:SetColorRGB(r, g, b)
            cpDebug("Set Content.ColorPicker RGB:", r, g, b)
            if ColorPickerFrame.hasOpacity and a and ColorPickerFrame.Content.ColorPicker.SetColorAlpha then
                ColorPickerFrame.Content.ColorPicker:SetColorAlpha(a)
                cpDebug("Set Content.ColorPicker Alpha:", a)
            end
        end
        if ColorPickerFrame.SetColorRGB then
            ColorPickerFrame:SetColorRGB(r, g, b)
            cpDebug("Set ColorPickerFrame RGB:", r, g, b)
        end
        if ColorPickerFrame.hasOpacity and a and ColorPickerFrame.SetColorAlpha then
            ColorPickerFrame:SetColorAlpha(a)
            cpDebug("Set ColorPickerFrame Alpha:", a)
        end

        -- Verify what values will be read back. Guarded on DebugActive because the
        -- two getters are real API calls, not just arguments to format.
        if DF:DebugActive("COLORPICKER") then
            if ColorPickerFrame.GetColorRGB then
                cpDebug("Verify GetColorRGB:", ColorPickerFrame:GetColorRGB())
            end
            if ColorPickerFrame.GetColorAlpha then
                cpDebug("Verify GetColorAlpha:", ColorPickerFrame:GetColorAlpha())
            end
        end

        -- Click OK - Blizzard will hide the frame and call swatchFunc
        cpDebug("Clicking OK button")
        ColorPickerFrame.Footer.OkayButton:Click()

        -- Now restore scale for next time (frame is hidden now)
        ColorPickerFrame:SetScale(1)
        ColorPickerFrame:ClearAllPoints()
        ColorPickerFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

        cpDebug("Done")
    else
        -- A real failure, so it is reported unconditionally rather than hidden
        -- behind a flag that never existed.
        DF:DebugWarn("COLORPICKER", "ColorPickerFrame or OkayButton not found")
    end
end

-- Click Blizzard's Cancel button (handles all callback execution properly)
local function ClickBlizzardCancel()
    if ColorPickerFrame and ColorPickerFrame.Footer and ColorPickerFrame.Footer.CancelButton then
        -- Mark as not hidden first (prevents cleanup hook from running)
        blizzardPickerHidden = false

        -- Keep scale tiny during click to prevent flicker
        -- Restore other properties so callbacks work
        ColorPickerFrame:RegisterEvent("GLOBAL_MOUSE_DOWN")
        ColorPickerFrame:SetAlpha(1)
        ColorPickerFrame:EnableMouse(true)
        -- Scale stays tiny!

        -- Click Cancel - Blizzard will hide the frame
        ColorPickerFrame.Footer.CancelButton:Click()

        -- Now restore scale for next time (frame is hidden now)
        ColorPickerFrame:SetScale(1)
        ColorPickerFrame:ClearAllPoints()
        ColorPickerFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

-- ============================================================
-- BLIZZARD PICKER STATE RESTORATION
-- Ensure Blizzard's picker is restored when our picker closes
-- ============================================================

-- ☠ Installed LAZILY, on the first open that could have hidden Blizzard's
-- picker, because the pack builds its frame on the first open and there is
-- nothing to hook before that. It used to ride a hooksecurefunc on
-- GUI.OpenColorPicker; that function now lives on the library and is only
-- reachable through the host's metatable, which is not a table hooksecurefunc
-- can be trusted to hook. Timing is unchanged: it still lands after the frame
-- exists and before the frame can hide, and it still appends AFTER the picker's
-- own OnHide (which fires the cancel callback).
local cleanupInitialized = false
local function EnsurePickerCleanup()
    if cleanupInitialized then return end
    local picker = PickerFrame()
    if not picker then return end
    cleanupInitialized = true
    picker:HookScript("OnHide", function()
        if blizzardPickerHidden then
            -- Try to use ClickBlizzardCancel for proper scale handling
            if ColorPickerFrame and ColorPickerFrame.Footer and ColorPickerFrame.Footer.CancelButton and ColorPickerFrame:IsShown() then
                ClickBlizzardCancel()
            else
                -- Fallback: just restore state directly
                if ColorPickerFrame then
                    ColorPickerFrame:SetScale(1)
                    ColorPickerFrame:SetAlpha(1)
                    ColorPickerFrame:EnableMouse(true)
                    ColorPickerFrame:RegisterEvent("GLOBAL_MOUSE_DOWN")
                    ColorPickerFrame:ClearAllPoints()
                    ColorPickerFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                end
                blizzardPickerHidden = false
            end
        end
    end)
end

-- Open our color picker alongside hidden Blizzard picker
local function OpenDFColorPickerWithBlizzard(info, useBlizzardAsBackend)
    cpDebug("Opening with Blizzard backend:", useBlizzardAsBackend,
        "r:", info.r, "g:", info.g, "b:", info.b,
        "hasOpacity:", info.hasOpacity, "opacity:", info.opacity)


    -- Get initial color
    local r, g, b = info.r or 1, info.g or 1, info.b or 1
    local a = info.opacity or info.a or 1
    local hasAlpha = info.hasOpacity

    if useBlizzardAsBackend then
        -- Using hidden Blizzard picker as backend
        -- Blizzard's picker is already open, just hide it visually
        C_Timer.After(0.01, function()
            HideBlizzardPicker()
        end)

        -- Open our picker with callbacks that interact with Blizzard's hidden picker
        GUI:OpenColorPicker(
            { r = r, g = g, b = b, a = a },
            hasAlpha,
            -- On Accept: sync color and click Blizzard's OK button
            function(newColor)
                -- Sync and click OK in one operation to ensure color is correct
                ClickBlizzardOKWithColor(newColor.r, newColor.g, newColor.b, newColor.a)
            end,
            -- On Cancel: click Blizzard's Cancel button
            function()
                ClickBlizzardCancel()
            end,
            -- On Change: sync to Blizzard (triggers live preview callbacks)
            function(newColor)
                SyncColorToBlizzard(newColor.r, newColor.g, newColor.b, newColor.a)
            end,
            -- Default colour (passed from DF setting defaults)
            info.dfDefaultColor
        )
    else
        -- Direct mode (DandersFrames internal, no Blizzard backend needed)
        -- Store callbacks for manual handling
        local callbacks = {
            swatchFunc = info.swatchFunc,
            cancelFunc = info.cancelFunc,
            opacityFunc = info.opacityFunc,
            hasOpacity = hasAlpha,
            originalR = r,
            originalG = g,
            originalB = b,
            originalA = a,
        }

        -- Set up previousValues for Blizzard UI compatibility
        ColorPickerFrame.previousValues = { r = r, g = g, b = b, a = a }

        -- ☠☠ TAKE OWNERSHIP OF THE BLIZZARD FRAME'S CALLBACKS, OR THE LAST ADDON TO USE
        -- IT KEEPS THEM. Direct mode never calls SetupColorPickerAndShow -- that is the
        -- point of it -- but ApplyColor below still writes into ColorPickerFrame so DF's
        -- own swatchFunc can read the values back from there. Blizzard's OnColorSelect
        -- fires on EVERY SetColorRGB, shown or not, and calls self.swatchFunc,
        -- self.opacityFunc and self.swatch:SetColorRGB (Blizzard_ColorPickerFrame /
        -- Mainline / ColorPickerFrame.lua, verified against live) -- and Setup is the ONLY
        -- writer of those fields, with nothing clearing them on Hide.
        --
        -- So after "Use DF Color Picker for All Addons" had routed another addon's picker
        -- through here, that addon's swatchFunc was still armed on the frame, and the next
        -- DF colour edit drove it too: picking a DF colour changed the other addon's colour
        -- as well. Reported by Aphoex (2026-08-17) against Chattynator, Platynator and
        -- WarpDeplete, with the two tells that name this exactly -- /reload fixed it (the
        -- fields go with the frame), and closing DF's window did not (nothing touches
        -- them); and it never happened between two NON-DF addons, because each of those
        -- opens runs Setup, which replaces the callbacks.
        --
        -- Cleared rather than swapped: direct mode invokes info's own swatch / opacity /
        -- cancel functions explicitly below, so the frame needs no callbacks of its own,
        -- and nil is precisely the state a fresh /reload leaves behind. The next foreign
        -- open re-arms them through Setup as usual.
        ColorPickerFrame.swatchFunc  = nil
        ColorPickerFrame.opacityFunc = nil
        ColorPickerFrame.cancelFunc  = nil
        ColorPickerFrame.swatch      = nil


        local function ApplyColor(newColor)
            -- Set values on ColorPickerFrame for addons that read from there
            if ColorPickerFrame.Content and ColorPickerFrame.Content.ColorPicker then
                ColorPickerFrame.Content.ColorPicker:SetColorRGB(newColor.r, newColor.g, newColor.b)
                if callbacks.hasOpacity and ColorPickerFrame.Content.ColorPicker.SetColorAlpha then
                    ColorPickerFrame.Content.ColorPicker:SetColorAlpha(newColor.a)
                end
            end
            if ColorPickerFrame.SetColorRGB then
                ColorPickerFrame:SetColorRGB(newColor.r, newColor.g, newColor.b)
            end
            if callbacks.hasOpacity and ColorPickerFrame.SetColorAlpha then
                ColorPickerFrame:SetColorAlpha(newColor.a)
            end

            -- Call callbacks
            if callbacks.swatchFunc then pcall(callbacks.swatchFunc) end
            if callbacks.opacityFunc and callbacks.hasOpacity then pcall(callbacks.opacityFunc) end
        end

        GUI:OpenColorPicker(
            { r = r, g = g, b = b, a = a },
            hasAlpha,
            -- On Accept
            function(newColor)
                ApplyColor(newColor)
            end,
            -- On Cancel
            function()
                -- Restore original
                if ColorPickerFrame.Content and ColorPickerFrame.Content.ColorPicker then
                    ColorPickerFrame.Content.ColorPicker:SetColorRGB(callbacks.originalR, callbacks.originalG, callbacks.originalB)
                    if callbacks.hasOpacity and ColorPickerFrame.Content.ColorPicker.SetColorAlpha then
                        ColorPickerFrame.Content.ColorPicker:SetColorAlpha(callbacks.originalA)
                    end
                end
                ColorPickerFrame.previousValues = { r = callbacks.originalR, g = callbacks.originalG, b = callbacks.originalB, a = callbacks.originalA }
                if callbacks.swatchFunc then pcall(callbacks.swatchFunc) end
                if callbacks.opacityFunc and callbacks.hasOpacity then pcall(callbacks.opacityFunc) end
                if callbacks.cancelFunc then pcall(callbacks.cancelFunc) end
            end,
            -- On Change
            function(newColor)
                ApplyColor(newColor)
            end,
            -- Default colour (passed from DF setting defaults)
            info.dfDefaultColor
        )
    end

    -- The picker frame exists now, so the restore hook can go on.
    EnsurePickerCleanup()
end

-- Flag to mark when DandersFrames is opening a color picker
local dfColorPickerFlag = false

-- Call this before opening color picker from DandersFrames
function GUI:MarkColorPickerCall()
    dfColorPickerFlag = true
    -- Auto-clear after a short delay in case something goes wrong
    C_Timer.After(0.1, function() dfColorPickerFlag = false end)
end

-- Check if the current call is from DandersFrames
local function IsFromDandersFrames()
    local result = dfColorPickerFlag
    dfColorPickerFlag = false  -- Clear immediately after checking
    return result
end

-- Hooked SetupColorPickerAndShow function (Midnight API)
local function HookedSetupColorPickerAndShow(self, info)
    -- Safety check
    if not originalSetupColorPickerAndShow then
        return
    end

    -- Account-wide settings, NOT db.party. These used to read the party table while
    -- the checkboxes rendered on BOTH mode tabs, so ticking on Raid wrote a value
    -- nothing ever read. GetGlobalDB seeds its own defaults, so no nil-fixup here.
    local dfGlobal = DandersFrames
    local db = dfGlobal and dfGlobal.GetGlobalDB and dfGlobal:GetGlobalDB()
    if not db then
        return originalSetupColorPickerAndShow(self, info)
    end

    local isFromDF = IsFromDandersFrames()

    -- Hide our picker if it's showing (to prevent overlap)
    local picker = PickerFrame()
    if picker and picker:IsShown() then
        picker.appliedColor = true
        picker:Hide()
    end

    if isFromDF and db.colorPickerOverride then
        -- DandersFrames internal call: use our picker directly (no Blizzard backend)
        OpenDFColorPickerWithBlizzard(info, false)
    elseif db.colorPickerGlobalOverride then
        -- Global override: let Blizzard open, then hide it and show ours
        -- Pre-scale to tiny size BEFORE Blizzard opens (minimizes flicker)
        if ColorPickerFrame then
            ColorPickerFrame:SetScale(0.001)
        end
        -- Let Blizzard set up (it opens but is tiny)
        originalSetupColorPickerAndShow(self, info)
        -- Now open our picker with Blizzard as hidden backend
        OpenDFColorPickerWithBlizzard(info, true)
    else
        -- No override: just use Blizzard normally
        originalSetupColorPickerAndShow(self, info)
    end
end

-- Legacy hooked OpenColorPicker function (pre-Midnight)
local function HookedOpenColorPicker(info)
    if not originalOpenColorPicker then
        return
    end

    -- Account-wide settings, NOT db.party -- see HookedSetupColorPickerAndShow.
    local dfGlobal = DandersFrames
    local db = dfGlobal and dfGlobal.GetGlobalDB and dfGlobal:GetGlobalDB()
    if not db then
        return originalOpenColorPicker(info)
    end

    local isFromDF = IsFromDandersFrames()

    -- Hide our picker if it's showing (to prevent overlap)
    local picker = PickerFrame()
    if picker and picker:IsShown() then
        picker.appliedColor = true
        picker:Hide()
    end

    if isFromDF and db.colorPickerOverride then
        -- DandersFrames internal call: use our picker directly (no Blizzard backend)
        OpenDFColorPickerWithBlizzard(info, false)
    elseif db.colorPickerGlobalOverride then
        -- Global override: let Blizzard open, then hide it and show ours
        -- Pre-scale to tiny size BEFORE Blizzard opens (minimizes flicker)
        if ColorPickerFrame then
            ColorPickerFrame:SetScale(0.001)
        end
        -- Let Blizzard set up (it opens but is tiny)
        originalOpenColorPicker(info)
        -- Now open our picker with Blizzard as hidden backend
        OpenDFColorPickerWithBlizzard(info, true)
    else
        -- No override: just use Blizzard normally
        originalOpenColorPicker(info)
    end
end

-- Install/uninstall hooks
function GUI:InstallColorPickerHook()
    local installed = false

    -- Try Midnight API first (SetupColorPickerAndShow)
    if ColorPickerFrame and type(ColorPickerFrame.SetupColorPickerAndShow) == "function" then
        if ColorPickerFrame.SetupColorPickerAndShow ~= HookedSetupColorPickerAndShow then
            originalSetupColorPickerAndShow = ColorPickerFrame.SetupColorPickerAndShow
            ColorPickerFrame.SetupColorPickerAndShow = HookedSetupColorPickerAndShow
            installed = true
        end
    end

    -- Also try legacy API (OpenColorPicker) for compatibility
    if type(OpenColorPicker) == "function" then
        if OpenColorPicker ~= HookedOpenColorPicker then
            originalOpenColorPicker = OpenColorPicker
            OpenColorPicker = HookedOpenColorPicker
            installed = true
        end
    end

    return installed
end

function GUI:UninstallColorPickerHook()
    -- Restore Midnight API
    if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow == HookedSetupColorPickerAndShow and originalSetupColorPickerAndShow then
        ColorPickerFrame.SetupColorPickerAndShow = originalSetupColorPickerAndShow
        originalSetupColorPickerAndShow = nil
    end

    -- Restore legacy API
    if OpenColorPicker == HookedOpenColorPicker and originalOpenColorPicker then
        OpenColorPicker = originalOpenColorPicker
        originalOpenColorPicker = nil
    end
end

-- Check if hook is installed
function GUI:IsColorPickerHookInstalled()
    local midnightHooked = ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow == HookedSetupColorPickerAndShow
    local legacyHooked = type(OpenColorPicker) == "function" and OpenColorPicker == HookedOpenColorPicker
    return midnightHooked or legacyHooked
end

-- Always install the hook - the hook itself checks settings when invoked.
-- This used to wait a second past the login PLAYER_ENTERING_WORLD so that
-- ColorPickerFrame was ready. In the companion neither is needed: nothing loads
-- this file until the player opens the settings panel, by which point the login
-- events are long past and ColorPickerFrame exists. Waiting for the next zoning
-- would leave the hook uninstalled for the first swatch clicked.
--
-- ⚠ A user with "Use DF Color Picker for All Addons" on never opens the panel to
-- get here -- DandersFrames/GUI/LoadOptions.lua loads this companion at login for
-- exactly that case, so the line below still runs on their first
-- PLAYER_ENTERING_WORLD.
GUI:InstallColorPickerHook()

-- Debug command to check hook status
DF:RegisterDebugSlash("DFCOLORHOOK", "Color picker hook status / toggle", true, "/dfcolorhook")
SlashCmdList["DFCOLORHOOK"] = function(arg)
    if arg == "on" then
        if GUI:InstallColorPickerHook() then
            DF:Say(L["Color picker hook installed"])
        else
            DF:Err(L["Failed to install hook (already hooked or API not available)"])
        end
    elseif arg == "off" then
        GUI:UninstallColorPickerHook()
        DF:Say(L["Color picker hook removed"])
    elseif arg == "api" then
        local o = DF:Out("Colour Picker", "API surface")
        -- A missing function is a real fault here: the hook cannot install without
        -- one of the two entry points, so absence is BAD rather than merely off.
        local function api(label, v)
            o:Field(label, type(v), type(v) == "function" and "good" or "bad")
        end
        o:Section("Globals")
        api("OpenColorPicker", OpenColorPicker)
        o:Field("ColorPickerFrame", type(ColorPickerFrame),
            ColorPickerFrame and "good" or "bad")
        if ColorPickerFrame then
            o:Section("ColorPickerFrame")
            api("SetupColorPickerAndShow", ColorPickerFrame.SetupColorPickerAndShow)
            api("Show", ColorPickerFrame.Show)
            api("SetColorRGB", ColorPickerFrame.SetColorRGB)
            api("GetColorRGB", ColorPickerFrame.GetColorRGB)
            api("SetColorAlpha", ColorPickerFrame.SetColorAlpha)
            api("GetColorAlpha", ColorPickerFrame.GetColorAlpha)
            local cp = ColorPickerFrame.Content and ColorPickerFrame.Content.ColorPicker
            if cp then
                o:Section("Content.ColorPicker")
                api("SetColorRGB", cp.SetColorRGB)
                api("GetColorRGB", cp.GetColorRGB)
                api("SetColorAlpha", cp.SetColorAlpha)
                api("GetColorAlpha", cp.GetColorAlpha)
            end
        end
        o:Siblings("colorhook")
    else
        local isInstalled = GUI:IsColorPickerHookInstalled()
        local dfGlobal = DandersFrames
        -- Same source the hooks read (account-wide), so this dump can't disagree
        -- with what actually decides which picker opens.
        local db = dfGlobal and dfGlobal.GetGlobalDB and dfGlobal:GetGlobalDB()
        local o = DF:Out("Colour Picker", "hook status")
        o:Field("Hook installed", isInstalled and "yes" or "no", isInstalled and "good" or "neutral")
        o:Field("Midnight API (SetupColorPickerAndShow)",
            ColorPickerFrame and type(ColorPickerFrame.SetupColorPickerAndShow) or "n/a")
        o:Field("Legacy API (OpenColorPicker)", type(OpenColorPicker))
        o:Section("Captured originals")
        -- Only a fault while the hook IS installed - uninstalled, nil is correct.
        local capStatus = isInstalled and "bad" or "neutral"
        o:Field("SetupColorPickerAndShow", originalSetupColorPickerAndShow and "captured" or "nil",
            originalSetupColorPickerAndShow and "good" or capStatus)
        o:Field("OpenColorPicker", originalOpenColorPicker and "captured" or "nil",
            originalOpenColorPicker and "good" or capStatus)
        o:Section("Settings")
        o:Field("DB available", db and "yes" or "no", db and "good" or "bad")
        if db then
            o:Field("colorPickerOverride", db.colorPickerOverride and "on" or "off",
                db.colorPickerOverride and "good" or "neutral")
            o:Field("colorPickerGlobalOverride", db.colorPickerGlobalOverride and "on" or "off",
                db.colorPickerGlobalOverride and "good" or "neutral")
        end
        o:Hints(L["Tracing is in the debug console - enable the COLORPICKER category."])
        o:Siblings("colorhook")
    end
end
