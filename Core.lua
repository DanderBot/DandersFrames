local addonName, DF = ...

-- Local caching of frequently used globals for performance
local pairs, ipairs, type, tonumber, tostring = pairs, ipairs, type, tonumber, tostring
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local format, sub, len, byte = string.format, string.sub, string.len, string.byte

-- Expose addon table globally
_G[addonName] = DF

-- Version - read from TOC file
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
DF.VERSION = GetAddOnMetadata(addonName, "Version") or "Unknown"

-- Localization
DF.L = LibStub("AceLocale-3.0"):GetLocale("DandersFrames")
local L = DF.L

-- ============================================================
-- LOCALE REFRESH REGISTRY
-- Some modules build label/option tables at file scope, which reads
-- L["..."] before the languageOverride overlay is applied at
-- ADDON_LOADED (see the overlay in the ADDON_LOADED handler below).
-- Those file-scope reads would otherwise freeze on the enUS baseline.
-- A module registers a rebuild fn here; Core re-runs them all once,
-- right after the overlay, so the tables pick up the active locale.
-- ============================================================
DF._localeRefreshers = DF._localeRefreshers or {}
function DF:RegisterLocaleRefresh(fn)
    DF._localeRefreshers[#DF._localeRefreshers + 1] = fn
end
function DF:RunLocaleRefreshers()
    for i = 1, #DF._localeRefreshers do
        local ok, err = pcall(DF._localeRefreshers[i])
        if not ok and DF.DebugError then
            DF:DebugError("LocaleRefresh failed: " .. tostring(err))
        end
    end
end

-- Locale warnings: silent by default (see Locales/enUS.lua for rationale).
-- Call DF:SetLocaleWarnings(true) — or use /df localewarn — to enable
-- error-handler warnings on missing L["..."] keys for the current session.
DF.localeWarningsEnabled = false
function DF:SetLocaleWarnings(enabled)
    if enabled then
        setmetatable(DF.L, { __index = function(self, key)
            rawset(self, key, key)
            geterrorhandler()(("AceLocale-3.0: DandersFrames: Missing entry for '%s'"):format(tostring(key)))
            return key
        end })
    else
        setmetatable(DF.L, { __index = function(self, key)
            rawset(self, key, key)
            return key
        end })
    end
    DF.localeWarningsEnabled = enabled and true or false
end

-- Debug flags
DF.debugEnabled = false
DF.demoMode = false
DF.demoPercent = 1
DF.initialized = false  -- Set to true after frames are created and ready

-- Returns true if the current profile's partyEnabled/raidEnabled flags
-- differ from the state captured when the addon loaded. A reload is
-- required to actually create or destroy frame headers, so callers use
-- this to decide whether to prompt the user.
function DF:EnableFlagsDifferFromLoaded()
    if not DF.db then return false end
    local curParty = DF.db.partyEnabled ~= false
    local curRaid  = DF.db.raidEnabled  ~= false
    return curParty ~= (DF.loadedPartyEnabled ~= false)
        or curRaid  ~= (DF.loadedRaidEnabled  ~= false)
end

-- Show the standard "reload to apply enable changes" popup if the flags
-- have diverged from the loaded state. Safe to call from any context.
function DF:PromptReloadIfEnableFlagsChanged()
    if not DF:EnableFlagsDifferFromLoaded() then return end
    if not DF.ShowPopupAlert then return end
    local L = DF.L
    DF:ShowPopupAlert({
        title = L["Reload Required"],
        message = L["The new profile changes which frame modes are enabled. A UI reload is required to apply this.\n\nReload now?"],
        buttons = {
            { label = L["Reload Now"], onClick = function() ReloadUI() end },
            { label = L["Later"] },
        },
    })
end

-- Aura layout version: incremented when any layout-affecting setting changes.
-- Frames track the version they were last laid out with to avoid redundant work.
DF.auraLayoutVersion = 1

function DF:InvalidateAuraLayout()
    DF.auraLayoutVersion = (DF.auraLayoutVersion or 0) + 1
end

-- ============================================================
-- TARGETED SLIDER UPDATE SYSTEM
-- ============================================================
-- Optimizes slider dragging by only updating the specific property being changed.
-- During slider drag: only update the one property (e.g., just frame height)
-- On slider release: perform full frame update to ensure everything is in sync

-- Debug flag for slider updates (toggle with /df debugslider)
DF.debugSliderUpdates = false

-- Track active slider dragging state
DF.sliderDragging = false
DF.sliderLightweightFunc = nil  -- The lightweight update function to call during drag
DF.sliderLightweightName = nil  -- Name of the lightweight function for debug
DF.sliderUpdateCallCount = 0    -- Call counter for debugging

-- Preview mode constants
local SIZE_UPDATE_INTERVAL = 0.033  -- ~30 FPS update rate for smooth dragging
local lastSizeUpdate = 0

-- Called when a slider starts being dragged
-- lightweightFunc: optional function that only updates the specific property
-- funcName: optional name for debug output
-- usePreviewMode: if true, hide frame elements for better performance
function DF:OnSliderDragStart(lightweightFunc, funcName, usePreviewMode)
    DF.sliderDragging = true
    DF.sliderLightweightFunc = lightweightFunc
    DF.sliderLightweightName = funcName or "unknown"
    DF.sliderUpdateCallCount = 0  -- Reset counter
    
    if DF.debugSliderUpdates then
        local previewStr = usePreviewMode and " |cffff00ff(PREVIEW MODE)|r" or ""
        if lightweightFunc then
            print("|cff00ff00[DF Slider]|r Drag START - lightweight: |cff88ff88" .. DF.sliderLightweightName .. "|r" .. previewStr)
        else
            print("|cff00ff00[DF Slider]|r Drag START - |cffff8888no lightweight function|r (will skip until release)" .. previewStr)
        end
    end
end

-- Called when a slider stops being dragged (mouse up)
function DF:OnSliderDragStop()
    if DF.debugSliderUpdates then
        print("|cff00ff00[DF Slider]|r Drag STOP - " .. DF.sliderUpdateCallCount .. " lightweight calls, now |cffffff00FULL UpdateAll()|r")
    end
    
    DF.sliderDragging = false
    DF.sliderLightweightFunc = nil
    DF.sliderLightweightName = nil
    
    -- Perform full update now that dragging has stopped
    local isRaidMode = DF.GUI and DF.GUI.SelectedMode == "raid"
    
    if isRaidMode and DF.raidTestMode then
        if DF.UpdateRaidTestFrames then
            DF:UpdateRaidTestFrames()
        end
        if DF.UpdateAllRaidPetFrames then
            DF:UpdateAllRaidPetFrames()
        end
    else
        DF:UpdateAll()
        -- UpdateAll already calls UpdateAllPetFrames
    end
end

-- Called during slider value changes
-- If dragging with a lightweight function, call it directly (throttled)
-- If dragging without lightweight function, skip entirely until release
-- If not dragging, call UpdateAll directly (no throttle)
function DF:ThrottledUpdateAll()
    if DF.sliderDragging then
        if DF.sliderLightweightFunc then
            -- During drag with lightweight function, call it (has its own throttle)
            DF.sliderLightweightFunc()
        end
        -- If no lightweight func, just skip until release
        return
    end
    
    -- Not dragging - just call UpdateAll directly
    DF:UpdateAll()
end

-- ============================================================
-- LIGHTWEIGHT UPDATE FUNCTIONS
-- ============================================================
-- These update only specific properties during slider drag for performance

-- Helper to iterate frames in current mode via iterators
-- Automatically uses test frames when in test mode
local function IterateFramesInMode(mode, updateFunc)
    if mode == "raid" then
        -- Check for raid test mode first
        if DF.raidTestMode and DF.testRaidFrames then
            local raidDb = DF:GetRaidDB()
            local testFrameCount = raidDb and raidDb.raidTestFrameCount or 10
            for i = 1, testFrameCount do
                local frame = DF.testRaidFrames[i]
                if frame and frame:IsShown() then
                    if updateFunc(frame, i, "raid" .. i) then return end
                end
            end
        elseif DF.IterateRaidFrames then
            -- Live raid frames via iterator
            DF:IterateRaidFrames(updateFunc)
        end
    else
        -- Check for party test mode first
        if DF.testMode and DF.testPartyFrames then
            local db = DF:GetDB()
            local testFrameCount = db and db.testFrameCount or 5
            for i = 0, testFrameCount - 1 do
                local frame = DF.testPartyFrames[i]
                if frame and frame:IsShown() then
                    local unit = (i == 0) and "player" or ("party" .. i)
                    if updateFunc(frame, i, unit) then return end
                end
            end
        elseif DF.IteratePartyFrames then
            -- Live party frames via iterator
            DF:IteratePartyFrames(updateFunc)
        end
    end
end

-- Update frame sizes AND layout positions
function DF:LightweightUpdateFrameSize()
    -- Frame-skip throttle
    local now = GetTime()
    if now - lastSizeUpdate < SIZE_UPDATE_INTERVAL then
        return
    end
    lastSizeUpdate = now
    
    DF.sliderUpdateCallCount = DF.sliderUpdateCallCount + 1
    
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    
    if mode == "raid" then
        -- Check for raid test mode
        if DF.raidTestMode then
            -- Full layout refresh including borders, health bars, fonts etc.
            if DF.RefreshTestFramesWithLayout then
                DF:RefreshTestFramesWithLayout()
            end
        else
            -- Call real layout function for live frames
            if DF.UpdateRaidLayout then
                DF:UpdateRaidLayout()
            end
        end
    else
        -- Party frames - resize frame and update health bar with padding
        local db = DF.db[mode]
        if not db then return end

        -- Party test frames: do the full layout refresh (mirroring the raid
        -- branch above) so overlay bars (absorb, heal prediction, reduced-max)
        -- re-position too. The lightweight path below only re-anchors the health
        -- bar, leaving the overlays stale mid-drag until the slider is released.
        if DF.testMode and DF.RefreshTestFramesWithLayout then
            DF:RefreshTestFramesWithLayout()
            return
        end

        local frameWidth = db.frameWidth or 120
        local frameHeight = db.frameHeight or 50
        local padding = db.framePadding or 0
        
        local function UpdateFrame(frame)
            if not frame then return end
            frame:SetSize(frameWidth, frameHeight)
            if frame.healthBar then
                frame.healthBar:ClearAllPoints()
                frame.healthBar:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, -padding)
                frame.healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -padding, padding)
            end
            -- Update resource bar width to match new frame size
            if db.resourceBarMatchWidth and frame.dfPowerBar and DF.ApplyResourceBarLayout then
                DF:ApplyResourceBarLayout(frame)
            end
        end

        IterateFramesInMode(mode, UpdateFrame)

        -- Re-apply header settings so the container and header anchors
        -- update to match the new frame dimensions during slider drag
        if DF.headersInitialized and DF.ApplyHeaderSettings then
            DF:ApplyHeaderSettings()
        end

        -- Update positioning for test frames
        if DF.testMode and DF.LightweightPositionPartyTestFrames then
            local testFrameCount = db.testFrameCount or 5
            DF:LightweightPositionPartyTestFrames(testFrameCount)
        end
        
        -- Also update pet frames to re-center on new frame sizes
        if DF.UpdateAllPetFrames then
            DF:UpdateAllPetFrames(true)
        end
    end
end

-- Spacing/layout changes - needs to re-layout frames
function DF:LightweightUpdateFrameSpacing()
    -- Frame-skip throttle
    local now = GetTime()
    if now - lastSizeUpdate < SIZE_UPDATE_INTERVAL then
        return
    end
    lastSizeUpdate = now
    
    -- Update secure headers if active (only for live frames, not test mode)
    if not DF.testMode and not DF.raidTestMode then
        if DF.headersInitialized and DF.ApplyHeaderSettings then
            DF:ApplyHeaderSettings()
        end
    end
    
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    
    if mode == "raid" then
        -- Check for raid test mode
        if DF.raidTestMode then
            -- Full layout refresh including borders, health bars, fonts etc.
            if DF.RefreshTestFramesWithLayout then
                DF:RefreshTestFramesWithLayout()
            end
        else
            if DF.UpdateRaidLayout then
                DF:UpdateRaidLayout()
            end
        end
    else
        -- Party mode
        if DF.testMode then
            -- Update test frame positioning
            if DF.LightweightPositionPartyTestFrames then
                local db = DF:GetDB()
                local testFrameCount = db and db.testFrameCount or 5
                DF:LightweightPositionPartyTestFrames(testFrameCount)
            elseif DF.UpdateAllFrames then
                DF:UpdateAllFrames()
            end
        else
            -- Live frames - need to call UpdateAllFrames to recalculate positions
            if DF.UpdateAllFrames then
                DF:UpdateAllFrames()
            end
        end
        -- Also update pet frames
        if DF.UpdateAllPetFrames then
            DF:UpdateAllPetFrames()
        end
    end
end

function DF:LightweightUpdateRaidLayout()
    DF:LightweightUpdateFrameSize()
end

function DF:LightweightUpdateFrameScale()
    -- Frame-skip throttle
    local now = GetTime()
    if now - lastSizeUpdate < SIZE_UPDATE_INTERVAL then
        return
    end
    lastSizeUpdate = now

    local mode = DF.GUI and DF.GUI.SelectedMode or "party"

    if mode == "raid" then
        DF:UpdateRaidContainerPosition()
        if DF.raidTestMode then
            if DF.RefreshTestFramesWithLayout then
                DF:RefreshTestFramesWithLayout()
            end
        elseif DF.UpdateRaidLayout then
            DF:UpdateRaidLayout()
        end
    else
        DF:UpdateContainerPosition()
        if DF.testMode and DF.LightweightPositionPartyTestFrames then
            local db = DF:GetDB()
            local testFrameCount = db and db.testFrameCount or 5
            DF:LightweightPositionPartyTestFrames(testFrameCount)
        end
        if DF.UpdateAllPetFrames then
            DF:UpdateAllPetFrames(true)
        end
    end

    -- Update permanent mover anchors (they reference scaled containers)
    DF:UpdatePermanentMoverAnchor("party")
    DF:UpdatePermanentMoverAnchor("raid")
end

-- Update only frame alpha/opacity
function DF:LightweightUpdateAlpha()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local alpha = db.frameAlpha or 1
    local bgAlpha = db.backgroundAlpha or 0.8
    local bgTexture = db.backgroundTexture or "Solid"
    local isTexturedBg = bgTexture ~= "Solid" and bgTexture ~= ""
    
    local function UpdateFrameAlpha(frame)
        if not frame then return end
        frame:SetAlpha(alpha)
        if frame.background then
            local c = db.backgroundColor or {r = 0, g = 0, b = 0}
            if isTexturedBg then
                -- For textured backgrounds, ensure SetAlpha is 1.0 and control via vertex color only
                frame.background:SetAlpha(1.0)
                frame.background:SetVertexColor(c.r, c.g, c.b, bgAlpha)
            else
                frame.background:SetColorTexture(c.r, c.g, c.b, bgAlpha)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateFrameAlpha)
end

-- Update only background alpha
function DF:LightweightUpdateBackgroundAlpha()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local bgAlpha = db.backgroundAlpha or 0.8
    local c = db.backgroundColor or {r = 0, g = 0, b = 0}
    local bgTexture = db.backgroundTexture or "Solid"
    local isTexturedBg = bgTexture ~= "Solid" and bgTexture ~= ""
    
    local function UpdateBG(frame)
        if frame and frame.background then
            if isTexturedBg then
                -- For textured backgrounds, ensure SetAlpha is 1.0 and control via vertex color only
                frame.background:SetAlpha(1.0)
                frame.background:SetVertexColor(c.r, c.g, c.b, bgAlpha)
            else
                frame.background:SetColorTexture(c.r, c.g, c.b, bgAlpha)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateBG)
end

-- ============================================================
-- SAFE TEXTURE SETTERS — graceful missing-texture fallback
-- A configured texture can be missing when a profile imported from another user
-- references a 3rd-party/SharedMedia texture this client doesn't have (or the
-- providing addon was removed) — leaving a black/blank bar. C_UIFileAsset
-- (NEW in WoW 12.0.7) — IsKnownFile(asset) reports whether a path is known to
-- the client (shipped OR a known loose addon file); when it says the asset is
-- unknown we substitute a guaranteed-present stock texture. (Note: the API
-- doesn't verify a known loose file still exists on disk, but an uninstalled
-- addon's path is simply not "known", which is exactly the import case we want.)
--   The SetTexture/SetStatusBarTexture `success` bool does NOT work for this —
--   it returns true for any well-formed path even when the file is absent.
--   Feature-detected: on clients without C_UIFileAsset this is INERT (behaves
--   exactly as before), so it's safe to ship now and self-activates on 12.0.7.
-- ============================================================
-- DF's own bundled default bar texture — ships with the addon, so it's always
-- present when our code runs. This is the "fall back to our default" target.
DF.STOCK_BAR_TEXTURE = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist"
local _df_warnedMissingTexture = {}

-- false -> asset (texture path or fileID) is definitively NOT known to the client
-- true  -> known/present
-- nil   -> validation API unavailable (caller leaves the texture as-is)
local function textureKnown(asset)
    if asset == nil then return nil end
    local api = C_UIFileAsset
    if not (api and api.IsKnownFile) then return nil end
    local ok, known = pcall(api.IsKnownFile, asset)
    if not ok then return nil end
    return known and true or false
end

local function warnMissingTexture(path)
    if not path or _df_warnedMissingTexture[path] then return end
    _df_warnedMissingTexture[path] = true
    if DF.Debug then DF:Debug("TEXTURE", "Missing texture '%s' — using stock fallback", tostring(path)) end
    if not DF._warnedAnyMissingTexture then
        DF._warnedAnyMissingTexture = true
        print("|cff66ccffDandersFrames|r: a configured texture couldn't be loaded and was replaced with a stock texture. Check your texture settings (an imported profile may reference a texture you don't have).")
    end
end

-- StatusBar texture with stock fallback. Returns true if the requested texture
-- loaded, false if the stock fallback was substituted, nil if bar was missing.
function DF:SafeSetStatusBarTexture(bar, path, stock)
    if not bar then return end
    if textureKnown(path) == false then
        bar:SetStatusBarTexture(stock or DF.STOCK_BAR_TEXTURE)
        warnMissingTexture(path)
        return false
    end
    bar:SetStatusBarTexture(path)
    return true
end

-- Plain Texture region with stock fallback (same semantics).
function DF:SafeSetTexture(region, path, stock)
    if not region then return end
    if textureKnown(path) == false then
        region:SetTexture(stock or DF.STOCK_BAR_TEXTURE)
        warnMissingTexture(path)
        return false
    end
    region:SetTexture(path)
    return true
end

-- Update only health bar texture
function DF:LightweightUpdateHealthTexture()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local tex = db.healthTexture or "Interface\\TargetingFrame\\UI-StatusBar"
    
    local function UpdateTex(frame)
        if frame and frame.healthBar then
            DF:SafeSetStatusBarTexture(frame.healthBar, tex)
        end
    end
    
    IterateFramesInMode(mode, UpdateTex)
end

-- Update only font shadows on all text elements
function DF:LightweightUpdateFontShadows()
    -- 12.0.7: fontstring-level SetShadowOffset/SetShadowColor no longer render —
    -- a font's drop shadow now lives on its font-family per-alphabet font objects.
    -- The old per-frame fontstring poke was a silent no-op, so update the already
    -- built font families in place instead (live preview, no full font rebuild).
    if DF.RefreshFontFamilyShadows then DF:RefreshFontFamilyShadows() end
    -- A font-object shadow change doesn't repaint already-rendered fontstrings —
    -- only continuously-ticked test frames pick it up on their own. Re-apply fonts
    -- so live + pinned frames repaint too.
    -- Legacy name/health/status text (used when the Text Designer is off):
    if DF.RefreshAllFonts then DF:RefreshAllFonts() end
    -- The Text Designer renders the visible text on its own overlay, which the
    -- above doesn't touch; re-render it so its shadow repaints on live + pinned.
    if DF.TextDesigner and DF.TextDesigner.Preview and DF.TextDesigner.Preview.RefreshLiveFrames then
        DF.TextDesigner.Preview:RefreshLiveFrames()
    end
end

-- Update only aura icon sizes
function DF:LightweightUpdateAuraSize(auraType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local size
    local iconsKey
    if auraType == "buff" then
        size = db.buffSize or 20
        iconsKey = "buffIcons"
    else
        size = db.debuffSize or 20
        iconsKey = "debuffIcons"
    end
    
    local function UpdateIcons(frame)
        if not frame or not frame[iconsKey] then return end
        for _, icon in ipairs(frame[iconsKey]) do
            if icon then
                icon:SetSize(size, size)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateIcons)
end

-- Update only power/resource bar height
function DF:LightweightUpdatePowerBarSize()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local height = db.resourceBarHeight or 4
    local width = db.resourceBarWidth or 50
    
    local function UpdateBar(frame)
        if frame and frame.dfPowerBar then
            frame.dfPowerBar:SetHeight(height)
            if not db.resourceBarMatchWidth then
                frame.dfPowerBar:SetWidth(width)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateBar)
end

-- Update only border thickness
-- Re-apply the frame border (size, style, texture, colour, show/hide) to every
-- live frame in the current mode. The full update path only re-styles party
-- frames (UpdateAllFrames -> ApplyFrameLayout); the raid path (UpdateRaidLayout)
-- only repositions headers, so border changes wouldn't reach live raid frames
-- without a reload. This mirrors LightweightUpdateBorderColor but reconfigures
-- the whole border via ApplyFrameBorder, so it covers both party and raid.
function DF:LightweightUpdateBorder()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db or not DF.ApplyFrameBorder then return end

    local function UpdateBorder(frame)
        if not frame or not frame.border then return end
        DF:ApplyFrameBorder(frame, db)
    end

    IterateFramesInMode(mode, UpdateBorder)
end

-- Update only text font size
function DF:LightweightUpdateFontSize(textType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateFont(frame)
        if not frame then return end
        
        if textType == "name" and frame.nameText then
            local fontPath = db.nameFont or "Fonts\\FRIZQT__.TTF"
            local fontOutline = db.nameTextOutline or "OUTLINE"
            if fontOutline == "NONE" then fontOutline = "" end
            local size = db.nameFontSize or 12
            DF:SafeSetFont(frame.nameText, fontPath, size, fontOutline)
        elseif textType == "health" and frame.healthText then
            local fontPath = db.healthFont or "Fonts\\FRIZQT__.TTF"
            local fontOutline = db.healthTextOutline or "OUTLINE"
            if fontOutline == "NONE" then fontOutline = "" end
            local size = db.healthFontSize or 11
            DF:SafeSetFont(frame.healthText, fontPath, size, fontOutline)
        elseif textType == "status" and frame.statusText then
            local fontPath = db.statusTextFont or "Fonts\\FRIZQT__.TTF"
            local fontOutline = db.statusTextOutline or "OUTLINE"
            if fontOutline == "NONE" then fontOutline = "" end
            local size = db.statusTextFontSize or 10
            DF:SafeSetFont(frame.statusText, fontPath, size, fontOutline)
        end
    end
    
    IterateFramesInMode(mode, UpdateFont)
end

-- Update text position
function DF:LightweightUpdateTextPosition(textType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdatePos(frame)
        if not frame then return end
        
        if textType == "name" and frame.nameText then
            frame.nameText:ClearAllPoints()
            local anchor = db.nameTextAnchor or "TOP"
            frame.nameText:SetPoint(anchor, frame, anchor, db.nameTextX or 0, db.nameTextY or 0)
        elseif textType == "health" and frame.healthText then
            frame.healthText:ClearAllPoints()
            local anchor = db.healthTextAnchor or "CENTER"
            frame.healthText:SetPoint(anchor, frame, anchor, db.healthTextX or 0, db.healthTextY or 0)
        elseif textType == "status" and frame.statusText then
            frame.statusText:ClearAllPoints()
            local anchor = db.statusTextAnchor or "BOTTOM"
            frame.statusText:SetPoint(anchor, frame, anchor, db.statusTextX or 0, db.statusTextY or 0)
        end
    end
    
    IterateFramesInMode(mode, UpdatePos)
end

-- Update icon scale/position
function DF:LightweightUpdateIconPosition(iconType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateIcon(frame)
        if not frame then return end
        
        local icon, scale, x, y, anchor
        if iconType == "role" then
            icon = frame.roleIcon
            scale = db.roleIconScale or 1
            x = db.roleIconX or 0
            y = db.roleIconY or 0
            anchor = db.roleIconAnchor or "TOPLEFT"
        elseif iconType == "raidTarget" then
            icon = frame.raidTargetIcon
            scale = db.raidTargetIconScale or 1
            x = db.raidTargetIconX or 0
            y = db.raidTargetIconY or 0
            anchor = db.raidTargetIconAnchor or "CENTER"
        elseif iconType == "readyCheck" then
            icon = frame.readyCheckIcon
            scale = db.readyCheckIconScale or 1
            x = db.readyCheckIconX or 0
            y = db.readyCheckIconY or 0
            anchor = db.readyCheckIconAnchor or "CENTER"
        elseif iconType == "centerStatus" then
            icon = frame.centerStatusIcon
            scale = db.centerStatusIconScale or 1
            x = db.centerStatusIconX or 0
            y = db.centerStatusIconY or 0
            anchor = db.centerStatusIconAnchor or "CENTER"
        elseif iconType == "leader" then
            icon = frame.leaderIcon
            scale = db.leaderIconScale or 1
            x = db.leaderIconX or 0
            y = db.leaderIconY or 0
            anchor = db.leaderIconAnchor or "TOPLEFT"
        elseif iconType == "summon" then
            icon = frame.summonIcon
            scale = db.summonIconScale or 1
            x = db.summonIconX or 0
            y = db.summonIconY or 0
            anchor = db.summonIconAnchor or "CENTER"
        elseif iconType == "resurrection" then
            icon = frame.resurrectionIcon
            scale = db.resurrectionIconScale or 1
            x = db.resurrectionIconX or 0
            y = db.resurrectionIconY or 0
            anchor = db.resurrectionIconAnchor or "CENTER"
        elseif iconType == "phased" then
            icon = frame.phasedIcon
            scale = db.phasedIconScale or 1
            x = db.phasedIconX or 0
            y = db.phasedIconY or 0
            anchor = db.phasedIconAnchor or "TOPRIGHT"
        elseif iconType == "afk" then
            icon = frame.afkIcon
            scale = db.afkIconScale or 1
            x = db.afkIconX or 0
            y = db.afkIconY or 0
            anchor = db.afkIconAnchor or "CENTER"
        elseif iconType == "vehicle" then
            icon = frame.vehicleIcon
            scale = db.vehicleIconScale or 1
            x = db.vehicleIconX or 0
            y = db.vehicleIconY or 0
            anchor = db.vehicleIconAnchor or "BOTTOMRIGHT"
        elseif iconType == "raidRole" then
            icon = frame.raidRoleIcon
            scale = db.raidRoleIconScale or 1
            x = db.raidRoleIconX or 0
            y = db.raidRoleIconY or 0
            anchor = db.raidRoleIconAnchor or "BOTTOMLEFT"
        end
        
        if icon then
            icon:SetScale(scale)
            icon:ClearAllPoints()
            icon:SetPoint(anchor, frame, anchor, x, y)
            DF:SnapPointToPixelGrid(icon, db.pixelPerfect)
        end
    end

    IterateFramesInMode(mode, UpdateIcon)
end

-- Lightweight alpha update for icons (no full frame rebuild)
function DF:LightweightUpdateIconAlpha(iconType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateAlpha(frame)
        if not frame then return end
        
        local icon, alpha
        if iconType == "role" then
            icon = frame.roleIcon
            alpha = db.roleIconAlpha or 1
        elseif iconType == "raidTarget" then
            icon = frame.raidTargetIcon
            alpha = db.raidTargetIconAlpha or 1
        elseif iconType == "readyCheck" then
            icon = frame.readyCheckIcon
            alpha = db.readyCheckIconAlpha or 1
        elseif iconType == "leader" then
            icon = frame.leaderIcon
            alpha = db.leaderIconAlpha or 1
        elseif iconType == "summon" then
            icon = frame.summonIcon
            alpha = db.summonIconAlpha or 1
        elseif iconType == "resurrection" then
            icon = frame.resurrectionIcon
            alpha = db.resurrectionIconAlpha or 1
        elseif iconType == "phased" then
            icon = frame.phasedIcon
            alpha = db.phasedIconAlpha or 1
        elseif iconType == "afk" then
            icon = frame.afkIcon
            alpha = db.afkIconAlpha or 1
        elseif iconType == "vehicle" then
            icon = frame.vehicleIcon
            alpha = db.vehicleIconAlpha or 1
        elseif iconType == "raidRole" then
            icon = frame.raidRoleIcon
            alpha = db.raidRoleIconAlpha or 1
        end
        
        if icon then
            icon:SetAlpha(alpha)
        end
    end
    
    IterateFramesInMode(mode, UpdateAlpha)
end

-- Update aura position/size
function DF:LightweightUpdateAuraPosition(auraType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local iconsKey = auraType == "buff" and "buffIcons" or "debuffIcons"
    local size = auraType == "buff" and (db.buffSize or 20) or (db.debuffSize or 20)
    local scale = auraType == "buff" and (db.buffScale or 1) or (db.debuffScale or 1)
    local alpha = auraType == "buff" and (db.buffAlpha or 1) or (db.debuffAlpha or 1)
    local anchor = auraType == "buff" and (db.buffAnchor or "BOTTOMLEFT") or (db.debuffAnchor or "BOTTOMRIGHT")
    local offsetX = auraType == "buff" and (db.buffOffsetX or 0) or (db.debuffOffsetX or 0)
    local offsetY = auraType == "buff" and (db.buffOffsetY or 0) or (db.debuffOffsetY or 0)
    local paddingX = auraType == "buff" and (db.buffPaddingX or 1) or (db.debuffPaddingX or 1)
    local paddingY = auraType == "buff" and (db.buffPaddingY or 1) or (db.debuffPaddingY or 1)
    local wrap = auraType == "buff" and (db.buffWrap or 4) or (db.debuffWrap or 4)
    local growth = auraType == "buff" and (db.buffGrowth or "LEFT_UP") or (db.debuffGrowth or "RIGHT_UP")
    local borderThickness = auraType == "buff" and (db.buffBorderSize or 1) or (db.debuffBorderSize or 1)
    
    -- Apply pixel-perfect sizing to size and scale together, adjusting for border
    if db.pixelPerfect then
        size, scale, borderThickness = DF:PixelPerfectSizeAndScaleForBorder(size, scale, borderThickness)
    end
    
    -- Parse growth direction
    local primary, secondary = strsplit("_", growth)
    primary = primary or "LEFT"
    secondary = secondary or "UP"
    
    local function GetGrowthOffset(direction, iconSize, pad)
        if direction == "LEFT" then
            return -(iconSize + pad), 0
        elseif direction == "RIGHT" then
            return iconSize + pad, 0
        elseif direction == "UP" then
            return 0, iconSize + pad
        elseif direction == "DOWN" then
            return 0, -(iconSize + pad)
        end
        return 0, 0
    end
    
    -- Use scaled size for growth calculations (final rendered size)
    local scaledSize = size * scale
    local primaryX, primaryY = GetGrowthOffset(primary, scaledSize, paddingX)
    local secondaryX, secondaryY = GetGrowthOffset(secondary, scaledSize, paddingY)
    
    local function UpdateAuras(frame)
        if not frame or not frame[iconsKey] then return end
        for i, icon in ipairs(frame[iconsKey]) do
            if icon then
                local idx = i - 1
                local row = math.floor(idx / wrap)
                local col = idx % wrap
                
                local x = offsetX + (col * primaryX) + (row * secondaryX)
                local y = offsetY + (col * primaryY) + (row * secondaryY)
                
                icon:SetSize(size, size)
                icon:SetScale(scale)
                icon:SetAlpha(alpha)
                icon:ClearAllPoints()
                icon:SetPoint(anchor, frame, anchor, x, y)
                DF:SnapPointToPixelGrid(icon, db.pixelPerfect)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateAuras)
end

-- Update highlight thickness/inset
function DF:LightweightUpdateHighlight(highlightType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateHighlight(frame)
        if not frame then return end
        
        local highlight, thickness, inset, alpha, color
        if highlightType == "selection" then
            highlight = frame.selectionHighlight or frame.dfSelectionHighlight
            thickness = db.selectionHighlightThickness or 2
            inset = db.selectionHighlightInset or 0
            alpha = db.selectionHighlightAlpha or 1
            color = db.selectionHighlightColor or {r = 1, g = 1, b = 1}
        elseif highlightType == "hover" then
            highlight = frame.hoverHighlight or frame.dfHoverHighlight
            thickness = db.hoverHighlightThickness or 2
            inset = db.hoverHighlightInset or 0
            alpha = db.hoverHighlightAlpha or 0.8
            color = db.hoverHighlightColor or {r = 1, g = 1, b = 1}
        elseif highlightType == "aggro" then
            highlight = frame.aggroHighlight or frame.dfAggroHighlight
            thickness = db.aggroHighlightThickness or 2
            inset = db.aggroHighlightInset or 0
            alpha = db.aggroHighlightAlpha or 1
            -- Aggro color depends on threat status - use stored color or get current threat
            if frame.dfAggroColor then
                color = frame.dfAggroColor
            else
                -- Determine color from threat status (or use tanking color for test/default)
                local status = frame.unit and UnitThreatSituation(frame.unit) or 3
                if db.aggroUseCustomColors then
                    if status == 3 then
                        color = db.aggroColorTanking or {r = 1, g = 0, b = 0}
                    elseif status == 2 then
                        color = db.aggroColorHighestThreat or {r = 1, g = 0.5, b = 0}
                    elseif status == 1 then
                        color = db.aggroColorHighThreat or {r = 1, g = 1, b = 0}
                    else
                        color = db.aggroColorTanking or {r = 1, g = 0, b = 0}
                    end
                else
                    -- Default Blizzard colors
                    if status == 3 then
                        color = {r = 1, g = 0, b = 0}
                    elseif status == 2 then
                        color = {r = 1, g = 0.5, b = 0}
                    elseif status == 1 then
                        color = {r = 1, g = 1, b = 0}
                    else
                        color = {r = 1, g = 0, b = 0}
                    end
                end
            end
        end
        
        -- If highlight doesn't exist, call full UpdateHighlights to create it
        if not highlight then
            if DF.UpdateHighlights then
                DF:UpdateHighlights(frame)
            end
            -- Re-get the highlight after creation
            if highlightType == "selection" then
                highlight = frame.selectionHighlight or frame.dfSelectionHighlight
            elseif highlightType == "hover" then
                highlight = frame.hoverHighlight or frame.dfHoverHighlight
            elseif highlightType == "aggro" then
                highlight = frame.aggroHighlight or frame.dfAggroHighlight
            end
        end
        
        if highlight and highlight:IsShown() then
            highlight:SetAlpha(alpha)
            
            -- Update border textures - check both naming conventions
            local top = highlight.top or highlight.topLine
            local bottom = highlight.bottom or highlight.bottomLine
            local left = highlight.left or highlight.leftLine
            local right = highlight.right or highlight.rightLine
            
            if top then
                top:SetHeight(thickness)
                top:ClearAllPoints()
                top:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
                top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset)
                top:SetColorTexture(color.r, color.g, color.b, 1)
            end
            if bottom then
                bottom:SetHeight(thickness)
                bottom:ClearAllPoints()
                bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset)
                bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
                bottom:SetColorTexture(color.r, color.g, color.b, 1)
            end
            if left then
                left:SetWidth(thickness)
                left:ClearAllPoints()
                left:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
                left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset)
                left:SetColorTexture(color.r, color.g, color.b, 1)
            end
            if right then
                right:SetWidth(thickness)
                right:ClearAllPoints()
                right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -inset)
                right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
                right:SetColorTexture(color.r, color.g, color.b, 1)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateHighlight)
end

-- Update power bar position
function DF:LightweightUpdatePowerBarPosition()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local anchor = db.resourceBarAnchor or "BOTTOM"
    local x = db.resourceBarX or 0
    local y = db.resourceBarY or 0
    
    local function UpdateBar(frame)
        if frame and frame.dfPowerBar then
            frame.dfPowerBar:ClearAllPoints()
            frame.dfPowerBar:SetPoint(anchor, frame, anchor, x, y)
        end
    end
    
    IterateFramesInMode(mode, UpdateBar)
end

-- Update absorb bar size/position
function DF:LightweightUpdateAbsorbBar()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local width = db.absorbBarWidth or 50
    local height = db.absorbBarHeight or 6
    local anchor = db.absorbBarAnchor or "BOTTOM"
    local x = db.absorbBarX or 0
    local y = db.absorbBarY or 0
    
    local function UpdateBar(frame)
        if frame and frame.dfAbsorbBar then
            frame.dfAbsorbBar:SetSize(width, height)
            frame.dfAbsorbBar:ClearAllPoints()
            frame.dfAbsorbBar:SetPoint(anchor, frame, anchor, x, y)
        end
    end
    
    IterateFramesInMode(mode, UpdateBar)
end

-- Update heal absorb bar
function DF:LightweightUpdateHealAbsorbBar()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local width = db.healAbsorbBarWidth or 50
    local height = db.healAbsorbBarHeight or 6
    local anchor = db.healAbsorbBarAnchor or "BOTTOM"
    local x = db.healAbsorbBarX or 0
    local y = db.healAbsorbBarY or -10
    
    local function UpdateBar(frame)
        if frame and frame.dfHealAbsorbBar then
            frame.dfHealAbsorbBar:SetSize(width, height)
            frame.dfHealAbsorbBar:ClearAllPoints()
            frame.dfHealAbsorbBar:SetPoint(anchor, frame, anchor, x, y)
        end
    end
    
    IterateFramesInMode(mode, UpdateBar)
end

-- Update dispel overlay settings
function DF:LightweightUpdateDispelOverlay()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local borderSize = db.dispelBorderSize or 2
    local borderInset = db.dispelBorderInset or 0
    local borderAlpha = db.dispelBorderAlpha or 1
    local gradientAlpha = db.dispelGradientAlpha or 0.5
    local gradientIntensity = db.dispelGradientIntensity or 1.0
    local gradientStyle = db.dispelGradientStyle or "FULL"
    local gradientSize = db.dispelGradientSize or 0.3
    local blendMode = db.dispelGradientBlendMode or "ADD"
    local darkenAlpha = db.dispelGradientDarkenAlpha or 0.5
    local iconSize = db.dispelIconSize or 20
    local iconAlpha = db.dispelIconAlpha or 1
    local iconPosition = db.dispelIconPosition or "CENTER"
    local iconOffsetX = db.dispelIconOffsetX or 0
    local iconOffsetY = db.dispelIconOffsetY or 0
    
    local function UpdateDispel(frame)
        if not frame or not frame.dfDispelOverlay then return end
        
        local overlay = frame.dfDispelOverlay
        
        -- Get current color from overlay's stored dispel type
        local r, g, b = 1, 1, 1
        if overlay.currentDispelType then
            local dispelColors = {
                Magic = db.dispelMagicColor or {r = 0, g = 0.6, b = 1},
                Curse = db.dispelCurseColor or {r = 0.6, g = 0, b = 1},
                Poison = db.dispelPoisonColor or {r = 0, g = 0.6, b = 0},
                Disease = db.dispelDiseaseColor or {r = 0.6, g = 0.4, b = 0},
                Bleed = db.dispelBleedColor or {r = 1, g = 0, b = 0},
            }
            local color = dispelColors[overlay.currentDispelType]
            if color then
                r, g, b = color.r, color.g, color.b
            end
        end
        
        -- Calculate OOR alpha multiplier for test mode
        local oorMultiplier = 1.0
        if (DF.testMode or DF.raidTestMode) and frame.testData and frame.testData.outOfRange then
            oorMultiplier = db.oorDispelOverlayAlpha or 0.55
        end
        
        local effectiveBorderAlpha = borderAlpha * oorMultiplier
        local effectiveGradientAlpha = gradientAlpha * oorMultiplier
        
        -- Update border positions, sizes, and alpha
        if overlay.borderLeft then
            overlay.borderLeft:ClearAllPoints()
            overlay.borderLeft:SetPoint("TOPLEFT", overlay, "TOPLEFT", -borderInset, borderInset)
            overlay.borderLeft:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", -borderInset, -borderInset)
            overlay.borderLeft:SetWidth(borderSize)
            local tex = overlay.borderLeft:GetStatusBarTexture()
            if tex then tex:SetVertexColor(r, g, b, effectiveBorderAlpha) end
        end
        
        if overlay.borderRight then
            overlay.borderRight:ClearAllPoints()
            overlay.borderRight:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", borderInset, borderInset)
            overlay.borderRight:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", borderInset, -borderInset)
            overlay.borderRight:SetWidth(borderSize)
            local tex = overlay.borderRight:GetStatusBarTexture()
            if tex then tex:SetVertexColor(r, g, b, effectiveBorderAlpha) end
        end
        
        if overlay.borderTop then
            overlay.borderTop:ClearAllPoints()
            overlay.borderTop:SetPoint("TOPLEFT", overlay, "TOPLEFT", -borderInset + borderSize, borderInset)
            overlay.borderTop:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", borderInset - borderSize, borderInset)
            overlay.borderTop:SetHeight(borderSize)
            local tex = overlay.borderTop:GetStatusBarTexture()
            if tex then tex:SetVertexColor(r, g, b, effectiveBorderAlpha) end
        end
        
        if overlay.borderBottom then
            overlay.borderBottom:ClearAllPoints()
            overlay.borderBottom:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", -borderInset + borderSize, -borderInset)
            overlay.borderBottom:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", borderInset - borderSize, -borderInset)
            overlay.borderBottom:SetHeight(borderSize)
            local tex = overlay.borderBottom:GetStatusBarTexture()
            if tex then tex:SetVertexColor(r, g, b, effectiveBorderAlpha) end
        end
        
        -- Update gradient alpha and edge gradients
        if gradientStyle == "EDGE" then
            -- Update EDGE style gradient textures
            local ri, gi, bi = r * gradientIntensity, g * gradientIntensity, b * gradientIntensity
            local gradientParent = overlay.gradient and overlay.gradient:GetParent()
            local parentHeight = gradientParent and gradientParent:GetHeight() or 40
            local parentWidth = gradientParent and gradientParent:GetWidth() or 80
            local edgeSize = parentHeight * gradientSize
            local edgeWidth = parentWidth * gradientSize
            
            if overlay.gradientTop then
                overlay.gradientTop:SetVertexColor(ri, gi, bi, effectiveGradientAlpha)
                overlay.gradientTop:SetBlendMode(blendMode)
                overlay.gradientTop:ClearAllPoints()
                overlay.gradientTop:SetPoint("TOPLEFT", gradientParent, "TOPLEFT", 0, 0)
                overlay.gradientTop:SetPoint("TOPRIGHT", gradientParent, "TOPRIGHT", 0, 0)
                overlay.gradientTop:SetHeight(edgeSize)
            end
            if overlay.gradientBottom then
                overlay.gradientBottom:SetVertexColor(ri, gi, bi, effectiveGradientAlpha)
                overlay.gradientBottom:SetBlendMode(blendMode)
                overlay.gradientBottom:ClearAllPoints()
                overlay.gradientBottom:SetPoint("BOTTOMLEFT", gradientParent, "BOTTOMLEFT", 0, 0)
                overlay.gradientBottom:SetPoint("BOTTOMRIGHT", gradientParent, "BOTTOMRIGHT", 0, 0)
                overlay.gradientBottom:SetHeight(edgeSize)
            end
            if overlay.gradientLeft then
                overlay.gradientLeft:SetVertexColor(ri, gi, bi, effectiveGradientAlpha)
                overlay.gradientLeft:SetBlendMode(blendMode)
                overlay.gradientLeft:ClearAllPoints()
                overlay.gradientLeft:SetPoint("TOPLEFT", gradientParent, "TOPLEFT", 0, 0)
                overlay.gradientLeft:SetPoint("BOTTOMLEFT", gradientParent, "BOTTOMLEFT", 0, 0)
                overlay.gradientLeft:SetWidth(edgeWidth)
            end
            if overlay.gradientRight then
                overlay.gradientRight:SetVertexColor(ri, gi, bi, effectiveGradientAlpha)
                overlay.gradientRight:SetBlendMode(blendMode)
                overlay.gradientRight:ClearAllPoints()
                overlay.gradientRight:SetPoint("TOPRIGHT", gradientParent, "TOPRIGHT", 0, 0)
                overlay.gradientRight:SetPoint("BOTTOMRIGHT", gradientParent, "BOTTOMRIGHT", 0, 0)
                overlay.gradientRight:SetWidth(edgeWidth)
            end
        elseif overlay.gradient then
            -- Non-EDGE styles - update main gradient
            local tex = overlay.gradient:GetStatusBarTexture()
            if tex then
                -- Apply intensity boost via vertex color (matching ShowOverlayWithRGB logic)
                local intensityBoost = math.max(1.0, gradientIntensity)
                tex:SetVertexColor(r * intensityBoost, g * intensityBoost, b * intensityBoost, effectiveGradientAlpha)
            end
            -- Update darken alpha
            if overlay.gradientDarken and overlay.gradientDarken:IsShown() then
                overlay.gradientDarken:SetColorTexture(0, 0, 0, darkenAlpha * oorMultiplier)
            end
        end
        
        -- Update icons
        if overlay.icons then
            for _, icon in pairs(overlay.icons) do
                icon:ClearAllPoints()
                icon:SetPoint(iconPosition, overlay, iconPosition, iconOffsetX, iconOffsetY)
                icon:SetSize(iconSize, iconSize)
                icon:SetAlpha(iconAlpha)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateDispel)
end

-- Update defensive icon settings
function DF:LightweightUpdateDefensiveIcons()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    -- Test mode owns multi-defensive layout (including the CENTER-growth
    -- second pass), so re-anchoring the primary icon here without re-running
    -- that pass would un-centre it and visually overlap icon 2. Delegate to
    -- the full test render — it's what fires on slider drop anyway, just done
    -- per drag tick too.
    if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestDefensiveBar then
        DF:UpdateAllTestDefensiveBar()
        return
    end

    local size = db.defensiveIconSize or 24
    local scale = db.defensiveIconScale or 1
    local x = db.defensiveIconX or 0
    local y = db.defensiveIconY or 0
    local anchor = db.defensiveIconAnchor or "CENTER"
    local durScale = db.defensiveIconDurationScale or 1
    local durX = db.defensiveIconDurationX or 0
    local durY = db.defensiveIconDurationY or 0
    local borderSize = db.defensiveIconBorderSize or 2
    local durFont = db.defensiveIconDurationFont or "Fonts\\FRIZQT__.TTF"
    local durOutline = db.defensiveIconDurationOutline or "OUTLINE"
    if durOutline == "NONE" then durOutline = "" end
    
    -- Apply pixel perfect to border size 
    if db.pixelPerfect then
        borderSize = DF:PixelPerfect(borderSize)
    end
    
    -- Per-icon visual update: border + artwork inset + duration text. Anything
    -- that's the same for the primary icon AND every multi-defensive bar icon
    -- (sizes, fonts) lives here. Positioning and per-icon layout (which differs
    -- across multi-bar slots) stays with UpdateAllDefensiveBars.
    local showBorder = db.defensiveIconShowBorder ~= false
    local artInset = showBorder and borderSize or 0

    local function ApplyVisuals(icon)
        if not icon then return end
        if icon.border then
            local spec = DF.Border:BuildSpec(db, "defensiveIcon", { iconMode = true })
            spec.enabled = showBorder
            spec.size    = borderSize  -- already pixel-perfected above
            DF.Border:Apply(icon.border, spec)
        end
        if icon.texture then
            icon.texture:ClearAllPoints()
            icon.texture:SetPoint("TOPLEFT", artInset, -artInset)
            icon.texture:SetPoint("BOTTOMRIGHT", -artInset, artInset)
        end

        if not icon.nativeCooldownText and icon.cooldown then
            local regions = {icon.cooldown:GetRegions()}
            for _, region in ipairs(regions) do
                if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                    icon.nativeCooldownText = region
                    break
                end
            end
        end
        if icon.nativeCooldownText then
            local durationSize = 10 * durScale
            DF:SafeSetFont(icon.nativeCooldownText, durFont, durationSize, durOutline)
            icon.nativeCooldownText:ClearAllPoints()
            icon.nativeCooldownText:SetPoint("CENTER", icon, "CENTER", durX, durY)
        end
    end

    local function UpdateIcon(frame)
        if not frame or not frame.defensiveIcon then return end
        local icon = frame.defensiveIcon

        -- Size / scale / position belong to the primary icon only; multi-bar
        -- slots are laid out by UpdateAllDefensiveBars.
        icon:SetSize(size, size)
        icon:SetScale(scale)
        icon:ClearAllPoints()
        icon:SetPoint(anchor, frame, anchor, x, y)
        DF:SnapPointToPixelGrid(icon, db.pixelPerfect)

        ApplyVisuals(icon)

        -- Multi-defensive bar icons share the same border + artwork + duration
        -- styling as the primary. Without this loop the border slider only
        -- updated the leftmost icon mid-drag and the rest stayed at the old
        -- border size, which in test mode also caused a layout reflow that
        -- temporarily lost one icon.
        if frame.defensiveBarIcons then
            for _, extraIcon in pairs(frame.defensiveBarIcons) do
                ApplyVisuals(extraIcon)
            end
        end
    end

    IterateFramesInMode(mode, UpdateIcon)
end

-- Update missing buff icon
function DF:LightweightUpdateMissingBuff()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local size = db.missingBuffIconSize or 24
    local scale = db.missingBuffIconScale or 1
    local x = db.missingBuffIconX or 0
    local y = db.missingBuffIconY or 0
    local anchor = db.missingBuffIconAnchor or "CENTER"
    local borderSize = db.missingBuffIconBorderSize or 2
    local showBorder = db.missingBuffIconShowBorder ~= false
    
    -- Apply pixel perfect to border size 
    if db.pixelPerfect then
        borderSize = DF:PixelPerfect(borderSize)
    end
    
    local function UpdateIcon(frame)
        if frame and frame.missingBuffFrame then
            frame.missingBuffFrame:SetSize(size, size)
            frame.missingBuffFrame:SetScale(scale)
            frame.missingBuffFrame:ClearAllPoints()
            frame.missingBuffFrame:SetPoint(anchor, frame, anchor, x, y)
            DF:SnapPointToPixelGrid(frame.missingBuffFrame, db.pixelPerfect)
            
            -- Border via unified DF.Border backend (Stage 4.1). BuildSpec
            -- reads canonical missingBuffIcon* keys; we override size with
            -- the locally pixel-perfected value. Icon insets by visible
            -- border thickness so artwork doesn't overlap edges.
            if frame.missingBuffBorder then
                -- unit/frame let BuildSpec resolve Class/Role colour.
                local spec = DF.Border:BuildSpec(db, "missingBuffIcon", { unit = frame.unit, frame = frame, iconMode = true })
                spec.enabled = showBorder
                spec.size    = borderSize
                DF.Border:Apply(frame.missingBuffBorder, spec)
            end
            if frame.missingBuffIcon then
                local artInset = showBorder and borderSize or 0
                frame.missingBuffIcon:ClearAllPoints()
                frame.missingBuffIcon:SetPoint("TOPLEFT", artInset, -artInset)
                frame.missingBuffIcon:SetPoint("BOTTOMRIGHT", -artInset, artInset)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateIcon)
end

-- Update group label settings (lightweight version for slider dragging)
-- Calls the full UpdateRaidGroupLabels since we need to recalculate positions
function DF:LightweightUpdateGroupLabels()
    if not DF.raidGroupLabels then return end
    if not DF.raidContainer then return end
    
    -- Just call the full update - it handles all the position calculation
    DF:UpdateRaidGroupLabels()
end

-- Update aura stack text settings
function DF:LightweightUpdateAuraStackText(auraType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local iconsKey = auraType == "buff" and "buffIcons" or "debuffIcons"
    local scale = auraType == "buff" and (db.buffStackScale or 1) or (db.debuffStackScale or 1)
    local x = auraType == "buff" and (db.buffStackX or 0) or (db.debuffStackX or 0)
    local y = auraType == "buff" and (db.buffStackY or 0) or (db.debuffStackY or 0)
    local anchor = auraType == "buff" and (db.buffStackAnchor or "BOTTOMRIGHT") or (db.debuffStackAnchor or "BOTTOMRIGHT")
    local fontPath = auraType == "buff" and (db.buffStackFont or "Fonts\\FRIZQT__.TTF") or (db.debuffStackFont or "Fonts\\FRIZQT__.TTF")
    local outline = auraType == "buff" and (db.buffStackOutline or "OUTLINE") or (db.debuffStackOutline or "OUTLINE")
    if outline == "NONE" then outline = "" end
    
    local function UpdateStacks(frame)
        if not frame or not frame[iconsKey] then return end
        for _, icon in ipairs(frame[iconsKey]) do
            if icon and icon.count then
                local stackSize = 10 * scale
                DF:SafeSetFont(icon.count, fontPath, stackSize, outline)
                icon.count:ClearAllPoints()
                icon.count:SetPoint(anchor, icon, anchor, x, y)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateStacks)
end

-- Update aura duration text settings
function DF:LightweightUpdateAuraDurationText(auraType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local iconsKey = auraType == "buff" and "buffIcons" or "debuffIcons"
    local scale = auraType == "buff" and (db.buffDurationScale or 1) or (db.debuffDurationScale or 1)
    local anchor = auraType == "buff" and (db.buffDurationAnchor or "CENTER") or (db.debuffDurationAnchor or "CENTER")
    local x = auraType == "buff" and (db.buffDurationX or 0) or (db.debuffDurationX or 0)
    local y = auraType == "buff" and (db.buffDurationY or 0) or (db.debuffDurationY or 0)
    local fontPath = auraType == "buff" and (db.buffDurationFont or "Fonts\\FRIZQT__.TTF") or (db.debuffDurationFont or "Fonts\\FRIZQT__.TTF")
    local outline = auraType == "buff" and (db.buffDurationOutline or "OUTLINE") or (db.debuffDurationOutline or "OUTLINE")
    if outline == "NONE" then outline = "" end
    
    if DF.debugSliderUpdates then
        print("|cff00ff00[DF Lightweight]|r UpdateAuraDurationText(" .. auraType .. ") scale=" .. scale .. " x=" .. x .. " y=" .. y)
    end
    
    local function UpdateDuration(frame)
        if not frame or not frame[iconsKey] then return end
        local foundCount = 0
        for _, icon in ipairs(frame[iconsKey]) do
            if icon then
                -- Store offsets on icon for OnUpdate handler
                icon.durationAnchor = anchor
                icon.durationX = x
                icon.durationY = y
                
                -- Find nativeCooldownText if not already found
                if not icon.nativeCooldownText and icon.cooldown then
                    local regions = {icon.cooldown:GetRegions()}
                    for _, region in ipairs(regions) do
                        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                            icon.nativeCooldownText = region
                            break
                        end
                    end
                end
                
                -- Update native cooldown text if it exists
                if icon.nativeCooldownText then
                    foundCount = foundCount + 1
                    local durationSize = 10 * scale
                    DF:SafeSetFont(icon.nativeCooldownText, fontPath, durationSize, outline)
                    icon.nativeCooldownText:ClearAllPoints()
                    icon.nativeCooldownText:SetPoint(anchor, icon, anchor, x, y)
                end
                
                -- Also update custom duration text if it exists (fallback)
                if icon.duration then
                    local durationSize = 10 * scale
                    DF:SafeSetFont(icon.duration, fontPath, durationSize, outline)
                    icon.duration:ClearAllPoints()
                    icon.duration:SetPoint(anchor, icon, anchor, x, y)
                end
            end
        end
        if DF.debugSliderUpdates and foundCount > 0 then
            print("  - Updated " .. foundCount .. " duration texts on frame")
        end
    end
    
    IterateFramesInMode(mode, UpdateDuration)
end

-- Sync linked sections between party and raid modes
function DF:SyncLinkedSections()
    if not DF.GUI or not DF.db or not DF.db.linkedSections then return end
    if not next(DF.db.linkedSections) then return end
    -- Skip sync during auto layout editing — _realRaidDB contains preview
    -- overrides and syncing would contaminate the other mode's settings
    local apu = DF.AutoProfilesUI
    if apu and apu:IsEditing() then return end
    local mode = DF.GUI.SelectedMode
    if mode ~= "party" and mode ~= "raid" then return end

    for pageId, prefixes in pairs(DF.SectionRegistry or {}) do
        if DF.db.linkedSections[pageId] then
            DF:CopySectionSettingsRaw(prefixes, mode)
        end
    end
end

-- Update aura border settings (both regular and expiring borders)
function DF:LightweightUpdateAuraBorder(auraType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local iconsKey = auraType == "buff" and "buffIcons" or "debuffIcons"
    
    -- Regular border settings
    local thickness = auraType == "buff" and (db.buffBorderSize or 1) or (db.debuffBorderSize or 1)
    local inset = auraType == "buff" and (db.buffBorderInset or 0) or (db.debuffBorderInset or 0)
    
    -- Expiring border settings (buffs only)
    local expiringThickness = db.buffExpiringBorderThickness or 2
    local expiringInset = db.buffExpiringBorderInset or -1
    
    if DF.debugSliderUpdates then
        print("|cff00ff00[DF Lightweight]|r UpdateAuraBorder(" .. auraType .. ") expiringThickness=" .. expiringThickness .. " expiringInset=" .. expiringInset)
    end
    
    local function UpdateBorders(frame)
        if not frame or not frame[iconsKey] then return end
        for idx, icon in ipairs(frame[iconsKey]) do
            if icon then
                -- Update regular border (DF.Border geometry via shared helper).
                -- Gated on icon.border, so it only reconfigures an existing
                -- (enabled) border — pass enabled = true.
                if icon.border then
                    DF:ConfigureAuraIconBorder(icon, db, auraType, true)
                end
                
                -- Update expiring border (buffs only) — re-configure the unified
                -- DF.Border overlay (geometry/colour/style/animation) live.
                if auraType == "buff" then
                    DF:ConfigureExpiringBorder(icon, db, "buffExpiring")
                end
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateBorders)
end

-- Update frame levels for various elements
function DF:LightweightUpdateFrameLevel(elementType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    -- Status icons whose full-render frame level (ApplyIconSettings) is
    -- (parent-of-parent level + value); mirror that here so the Frame Level
    -- slider previews live, matching Scale/Alpha. Keyed elementType -> frame field.
    local SIMPLE_LEVEL_ICONS = {
        resurrection = "resurrectionIcon",
        phased       = "phasedIcon",
        afk          = "afkIcon",
        vehicle      = "vehicleIcon",
        raidRole     = "raidRoleIcon",
        summon       = "summonIcon",
    }

    local function UpdateLevel(frame)
        if not frame then return end
        
        local baseLevel = frame.contentOverlay and frame.contentOverlay:GetFrameLevel() or frame:GetFrameLevel()
        local frameBaseLevel = frame:GetFrameLevel()
        
        if elementType == "absorb" and frame.dfAbsorbBar then
            local level = db.absorbBarFrameLevel or 10
            frame.dfAbsorbBar:SetFrameLevel(level)
        elseif elementType == "missingBuff" and frame.missingBuffFrame then
            local level = db.missingBuffIconFrameLevel or 0
            if level > 0 then
                frame.missingBuffFrame:SetFrameLevel(frameBaseLevel + level)
            else
                frame.missingBuffFrame:SetFrameLevel(baseLevel + 10)
            end
        elseif elementType == "defensive" and frame.defensiveIcon then
            local level = db.defensiveIconFrameLevel or 0
            if level > 0 then
                frame.defensiveIcon:SetFrameLevel(frameBaseLevel + level)
            else
                -- +26 keeps the defensive icon above the buff/debuff auras AND
                -- their borders: an aura icon sits at contentOverlay+15 with its
                -- DF.Border +10 on top (= +25), so +26 clears the whole aura.
                -- The defensive is an important alert and shouldn't be obscured.
                frame.defensiveIcon:SetFrameLevel(baseLevel + 26)
            end
        elseif elementType == "role" and frame.roleIcon then
            local level = db.roleIconFrameLevel or 0
            if level > 0 then
                frame.roleIcon:SetFrameLevel(frameBaseLevel + level)
            else
                frame.roleIcon:SetFrameLevel(baseLevel + 5)
            end
        elseif elementType == "leader" and frame.leaderIcon then
            local level = db.leaderIconFrameLevel or 0
            if level > 0 then
                frame.leaderIcon:SetFrameLevel(frameBaseLevel + level)
            else
                frame.leaderIcon:SetFrameLevel(baseLevel + 5)
            end
        elseif elementType == "raidTarget" and frame.raidTargetIcon then
            local level = db.raidTargetIconFrameLevel or 0
            if level > 0 then
                frame.raidTargetIcon:SetFrameLevel(frameBaseLevel + level)
            else
                frame.raidTargetIcon:SetFrameLevel(baseLevel + 5)
            end
        elseif elementType == "readyCheck" and frame.readyCheckIcon then
            local level = db.readyCheckIconFrameLevel or 0
            if level > 0 then
                frame.readyCheckIcon:SetFrameLevel(frameBaseLevel + level)
            else
                frame.readyCheckIcon:SetFrameLevel(baseLevel + 5)
            end
        elseif elementType == "centerStatus" and frame.centerStatusIcon then
            local level = db.centerStatusIconFrameLevel or 0
            if level > 0 then
                frame.centerStatusIcon:SetFrameLevel(frameBaseLevel + level)
            else
                frame.centerStatusIcon:SetFrameLevel(baseLevel + 5)
            end
        else
            -- resurrection / phased / afk / vehicle / raidRole / summon icons
            local field = SIMPLE_LEVEL_ICONS[elementType]
            local icon = field and frame[field]
            if icon then
                local level = db[field .. "FrameLevel"] or 0
                if level > 0 then
                    icon:SetFrameLevel(icon:GetParent():GetParent():GetFrameLevel() + level)
                end
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateLevel)
end

-- ============================================================
-- CLASS COLOR OVERRIDE
-- Returns custom class color if set, otherwise falls back to
-- Blizzard's RAID_CLASS_COLORS. Used everywhere in the addon.
-- ============================================================

local DEFAULT_CLASS_COLOR = { r = 0.5, g = 0.5, b = 0.5 }

function DF:GetClassColor(class)
    if not class then return DEFAULT_CLASS_COLOR end
    -- Check for user override
    if DF.db and DF.db.classColors and DF.db.classColors[class] then
        return DF.db.classColors[class]
    end
    return RAID_CLASS_COLORS[class] or DEFAULT_CLASS_COLOR
end

-- Resolve the frame border colour: the static borderColor by default, or
-- (Stage 2.1+) the unit's class / role colour with its own alpha slider when
-- the canonical frameBorderColorSource picks one. Non-player / unknown-class
-- units fall back to the static colour. Handles test frames via fake class
-- and role data. Mirrors Border:BuildSpec so the lightweight live-update
-- path (LightweightUpdateBorderColor) renders identically to the full Apply
-- path on every drag tick of the colour picker / alpha slider.
function DF:GetFrameBorderColor(frame, db)
    local base = db.frameBorderColor or DEFAULT_CLASS_COLOR
    local br, bg, bb, ba = base.r or 0, base.g or 0, base.b or 0, base.a or 1

    -- Resolve source the same way Border:BuildSpec does, so the lightweight
    -- live-update path (LightweightUpdateBorderColor) renders identically to
    -- the full Apply path. ColorSource is the canonical Stage 2 key; the
    -- legacy booleans are honoured as fallback in case the migration shim
    -- hasn't run yet for some code path.
    local source = db.frameBorderColorSource
    if not source then
        if db.frameBorderUseClassColor     then source = "CLASS"
        elseif db.frameBorderUseRoleColor  then source = "ROLE"
        else                                    source = "STATIC" end
    end
    if source == "STATIC" or not frame then
        return br, bg, bb, ba
    end

    -- CLASS / ROLE: RGB from the resolver, alpha from the picker's own alpha
    -- component (frameBorderColor.a — same `ba` above). The unified Border
    -- Alpha slider (Stage 2.4) edits this same component, so picker and
    -- slider stay in sync automatically; no separate alpha key to read.
    local a = ba

    if source == "CLASS" then
        local class
        if frame.dfIsTestFrame then
            local testData = DF.GetTestUnitData and DF:GetTestUnitData(frame.index, frame.isRaidFrame)
            class = testData and testData.class
        elseif frame.unit and UnitExists(frame.unit) then
            -- No UnitIsPlayer gate: class-based NPC party members (e.g.
            -- follower dungeon companions) have a class token too. Units
            -- with no class token fall back to the static colour.
            class = select(2, UnitClass(frame.unit))
        end
        if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
            local c = DF:GetClassColor(class)
            return c.r, c.g, c.b, a
        end
        return br, bg, bb, a
    elseif source == "ROLE" then
        local rc = DF.db and DF.db.roleColors
        local role
        if frame.dfIsTestFrame then
            local testData = DF.GetTestUnitData and DF:GetTestUnitData(frame.index, frame.isRaidFrame)
            role = testData and testData.role
        elseif frame.unit and UnitExists(frame.unit) and UnitGroupRolesAssigned then
            role = UnitGroupRolesAssigned(frame.unit)
            -- UnitGroupRolesAssigned returns "NONE" outside instances where
            -- roles aren't assigned (solo, world content). For the player,
            -- fall back to spec role so role colour stays meaningful. Other
            -- units expose no public spec API; they stay on picker fallback.
            if (not role or role == "NONE") and UnitIsUnit and UnitIsUnit(frame.unit, "player")
               and GetSpecialization and GetSpecializationRole then
                local spec = GetSpecialization()
                if spec then role = GetSpecializationRole(spec) end
            end
        end
        local c = rc and role and role ~= "NONE" and (rc[role] or rc[string.lower(role)])
        if c then
            return c.r or br, c.g or bg, c.b or bb, a
        end
        return br, bg, bb, a
    end

    return br, bg, bb, ba
end

-- Returns custom power color if set, otherwise falls back to
-- Blizzard's PowerBarColor. Checks token first, then numeric type.
function DF:GetPowerColor(powerToken, powerType)
    -- Check for user override by token
    if powerToken and DF.db and DF.db.powerColors and DF.db.powerColors[powerToken] then
        return DF.db.powerColors[powerToken]
    end
    -- Fall back to Blizzard defaults
    if powerToken then
        local info = PowerBarColor[powerToken]
        if info then return info end
    end
    if powerType then
        local info = PowerBarColor[powerType]
        if info then return info end
    end
    return DEFAULT_CLASS_COLOR
end

-- Resolve the resource bar's fill colour for a unit per the configured colour
-- mode. Returns r, g, b (0-1).
--   POWER_TYPE → the power-type colour (user override or Blizzard default)
--   CLASS      → the unit's class colour
--   CUSTOM     → the user's resourceBarCustomColor
-- Honours the legacy resourceBarClassColor boolean when resourceBarColorMode
-- isn't set yet (pre-migration profiles). Uses the same UnitClass/UnitPowerType
-- calls the old inline logic did, so it carries no new secret-value risk.
function DF:GetResourceBarColor(unit, db)
    local mode = db.resourceBarColorMode
    if not mode then
        mode = db.resourceBarClassColor and "CLASS" or "POWER_TYPE"
    end

    if mode == "CUSTOM" then
        local c = db.resourceBarCustomColor or {r = 0, g = 0.5, b = 1, a = 1}
        return c.r or 0, c.g or 0.5, c.b or 1
    elseif mode == "CLASS" then
        local _, classToken = UnitClass(unit)
        local cc = classToken and DF:GetClassColor(classToken)
        if cc then return cc.r, cc.g, cc.b end
        -- No class colour available — fall through to the power-type colour.
    end

    -- POWER_TYPE (and the CLASS fallback above)
    local pType, pToken, altR, altG, altB = UnitPowerType(unit)
    local info = DF:GetPowerColor(pToken, pType)
    if info then return info.r, info.g, info.b end
    if altR then return altR, altG, altB end
    return 0, 0, 1
end

-- Migrate the legacy resourceBarClassColor boolean to the new
-- resourceBarColorMode tri-state. Idempotent; leaves the legacy key in place
-- (the render helper still honours it as a fallback) — same pattern as the
-- border-key migrations.
function DF:MigrateResourceBarColorMode(modeDb)
    if not modeDb then return end
    if modeDb.resourceBarColorMode == nil and modeDb.resourceBarClassColor ~= nil then
        modeDb.resourceBarColorMode = modeDb.resourceBarClassColor and "CLASS" or "POWER_TYPE"
    end
end

-- Pinned frames decouple (2026-06-07): pinned settings are no longer saved as
-- per-raid-layout overrides — only the per-set `enabled` flag is. Strip any
-- stale "pinned.N.<setting>" override keys (setting != enabled) left in saved
-- auto-layout profiles by the old behaviour. Idempotent: once clean, re-running
-- is a no-op, so it is safe to call on every load. Walks ALL DandersFrames
-- profiles (not just the active one), since each carries its own raidAutoProfiles.
function DF:MigratePinnedLayoutOverrides()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    local stripped = 0
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        local autoDb = profile.raidAutoProfiles
        if type(autoDb) == "table" then
            for _, ct in pairs(autoDb) do
                if type(ct) == "table" and type(ct.profiles) == "table" then
                    for _, layout in ipairs(ct.profiles) do
                        local ov = layout.overrides
                        if type(ov) == "table" then
                            for key in pairs(ov) do
                                local _, setting = key:match("^pinned%.(%d+)%.(.+)$")
                                if setting and setting ~= "enabled" then
                                    ov[key] = nil  -- safe: clearing current key during pairs is allowed
                                    stripped = stripped + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if stripped > 0 then
        DF:Debug("LAYOUT", "MigratePinnedLayoutOverrides: stripped %d stale pinned override(s)", stripped)
    end
end

-- Pinned frames "Match" baseline (2026-06-07): each pinned set inherits its
-- baseline look (size, later border/background) from a mode chosen by
-- set.matchMode ("party"/"raid"). It defaults to the set's OWN mode (a party set
-- mirrors party frames, a raid set mirrors raid frames); the other value lets a
-- set cross-match the opposite mode. nil already resolves to the own mode at
-- runtime, but seed it explicitly so the Match dropdown shows a value. Also
-- converts the short-lived "auto" value to the own mode.
--
-- Width/Height moved from a "Custom Size" toggle to per-key Match overrides:
-- set.customWidth/customHeight are now the override values (nil = inherit Match).
-- Drop the obsolete set.useCustomSize, and where it was off, clear any
-- customWidth/Height that were only seeded for the toggle so they don't read as
-- spurious overrides. Walks ALL profiles (party + raid pinnedFrames.sets).
-- Idempotent.
function DF:MigratePinnedMatchMode()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        for _, mode in ipairs({ "party", "raid" }) do
            local modeDb = profile[mode]
            local pf = modeDb and modeDb.pinnedFrames
            if pf and type(pf.sets) == "table" then
                for _, set in pairs(pf.sets) do
                    if type(set) == "table" then
                        if set.matchMode ~= "party" and set.matchMode ~= "raid" then
                            set.matchMode = mode  -- default / repair → the set's own mode
                        end
                        if set.useCustomSize ~= nil then
                            if set.useCustomSize ~= true then
                                set.customWidth = nil
                                set.customHeight = nil
                            end
                            set.useCustomSize = nil
                        end
                        -- Scale inherits from the Based-on mode unless overridden:
                        -- a value still at the old hard default (1.0) is treated as
                        -- "inherit" (cleared); a changed value is kept as override.
                        if set.scale == 1.0 then set.scale = nil end
                        -- Spacing inherits the Based-on mode's frameSpacing unless
                        -- overridden: the old hard default was 2, so a value still
                        -- at 2 is treated as "inherit" (cleared); a non-2 value is
                        -- kept as a deliberate override.
                        if set.horizontalSpacing == 2 then set.horizontalSpacing = nil end
                        if set.verticalSpacing == 2 then set.verticalSpacing = nil end
                        -- growDirection is a plain pinned-only setting; an earlier
                        -- build briefly cleared its HORIZONTAL default to nil, so
                        -- restore a concrete value for the dropdown.
                        if set.growDirection == nil then set.growDirection = "HORIZONTAL" end
                    end
                end
            end
        end
    end
end

-- ============================================================
-- STATE DRIVERS FOR TEST MODE COMBAT SAFETY
-- When test mode is active, state drivers are registered on all
-- secure frames so that if combat starts, the correct live
-- frames auto-show via the secure state system (no taint).
-- Also handles party<->raid transitions during combat.
-- ============================================================

-- Register state drivers that hide frames out of combat (test mode)
-- but auto-show the correct frames when combat starts.
-- Party frames: show in combat when NOT in a raid group
-- Raid frames: show in combat when in a raid group
function DF:SetTestModeStateDrivers()
    -- Party: hide normally; in combat show unless in a raid group
    -- Uses multi-clause pattern instead of [nogroup:raid] which isn't reliably supported
    local partyCondition = "[combat,group:raid] hide; [combat] show; hide"
    local raidCondition = "[combat,group:raid] show; hide"
    
    -- Party side
    if DF.partyContainer then
        RegisterStateDriver(DF.partyContainer, "visibility", partyCondition)
    end
    if DF.partyHeader then
        RegisterStateDriver(DF.partyHeader, "visibility", partyCondition)
    end
    
    -- Raid side - only register on the correct headers for current mode
    -- Registering on BOTH flat and separated headers causes both to become
    -- visible simultaneously, overlapping frames and corrupting positions
    local raidDb = DF:GetRaidDB()
    local useFlatMode = raidDb and not raidDb.raidUseGroups
    
    if DF.raidContainer then
        RegisterStateDriver(DF.raidContainer, "visibility", raidCondition)
    end
    if useFlatMode then
        -- Flat mode: only register on flat header
        if DF.FlatRaidFrames then
            if DF.FlatRaidFrames.header then
                RegisterStateDriver(DF.FlatRaidFrames.header, "visibility", raidCondition)
            end
            if DF.FlatRaidFrames.innerContainer then
                RegisterStateDriver(DF.FlatRaidFrames.innerContainer, "visibility", raidCondition)
            end
        end
    else
        -- Grouped mode: only register on separated headers
        if DF.raidSeparatedHeaders then
            for i = 1, 8 do
                if DF.raidSeparatedHeaders[i] then
                    RegisterStateDriver(DF.raidSeparatedHeaders[i], "visibility", raidCondition)
                end
            end
        end
    end
    
    DF.testModeStateDriversActive = true
end

-- Register group transition state drivers
-- Shows/hides party vs raid frames based on group type (regardless of combat state)
-- Used when party<->raid conversion happens during combat, and when
-- switching from test mode drivers after combat starts (flicker-free transition)
function DF:SetGroupTransitionStateDrivers()
    -- ARENA FIX: Don't register state drivers in arena.
    -- [group:raid] is true in arena (arena uses raid units), so the state driver
    -- would hide partyContainer (killing the arena header) and show raidContainer.
    if DF.IsInArena and DF:IsInArena() then
        -- If state drivers are already active, clear them
        if DF.testModeStateDriversActive then
            DF:ClearTestModeStateDrivers()
        end
        return
    end
    
    local partyCondition = "[group:raid] hide; show"
    local raidCondition = "[group:raid] show; hide"
    
    -- Party side
    if DF.partyContainer then
        RegisterStateDriver(DF.partyContainer, "visibility", partyCondition)
    end
    if DF.partyHeader then
        RegisterStateDriver(DF.partyHeader, "visibility", partyCondition)
    end
    
    -- Raid side - only register on the correct headers for current mode
    -- Registering on BOTH flat and separated headers causes both to become
    -- visible simultaneously, overlapping frames and corrupting positions
    local raidDb = DF:GetRaidDB()
    local useFlatMode = raidDb and not raidDb.raidUseGroups
    
    if DF.raidContainer then
        RegisterStateDriver(DF.raidContainer, "visibility", raidCondition)
    end
    if useFlatMode then
        -- Flat mode: only register on flat header
        if DF.FlatRaidFrames then
            if DF.FlatRaidFrames.header then
                RegisterStateDriver(DF.FlatRaidFrames.header, "visibility", raidCondition)
            end
            if DF.FlatRaidFrames.innerContainer then
                RegisterStateDriver(DF.FlatRaidFrames.innerContainer, "visibility", raidCondition)
            end
        end
    else
        -- Grouped mode: only register on separated headers
        if DF.raidSeparatedHeaders then
            for i = 1, 8 do
                if DF.raidSeparatedHeaders[i] then
                    RegisterStateDriver(DF.raidSeparatedHeaders[i], "visibility", raidCondition)
                end
            end
        end
    end
    
    DF.testModeStateDriversActive = true
end

-- Unregister all test mode state drivers and reset frame visibility
-- so UpdateHeaderVisibility can manage normally.
-- MUST only be called out of combat.
function DF:ClearTestModeStateDrivers()
    if not DF.testModeStateDriversActive then return end
    
    -- Party side
    if DF.partyContainer then
        UnregisterStateDriver(DF.partyContainer, "visibility")
    end
    if DF.partyHeader then
        UnregisterStateDriver(DF.partyHeader, "visibility")
    end
    
    -- Raid side
    if DF.raidContainer then
        UnregisterStateDriver(DF.raidContainer, "visibility")
    end
    if DF.raidSeparatedHeaders then
        for i = 1, 8 do
            if DF.raidSeparatedHeaders[i] then
                UnregisterStateDriver(DF.raidSeparatedHeaders[i], "visibility")
            end
        end
    end
    if DF.FlatRaidFrames then
        if DF.FlatRaidFrames.header then
            UnregisterStateDriver(DF.FlatRaidFrames.header, "visibility")
        end
        if DF.FlatRaidFrames.innerContainer then
            UnregisterStateDriver(DF.FlatRaidFrames.innerContainer, "visibility")
        end
    end
    
    DF.testModeStateDriversActive = false
end

-- Update class color alpha on health bars
function DF:LightweightUpdateClassColorAlpha()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    -- This just stores the setting; actual application happens during frame updates
    -- But we can trigger a refresh of existing frames
    if DF.RefreshTestFrames then
        DF:RefreshTestFrames()
    end
end

-- Update background class color alpha
function DF:LightweightUpdateBackgroundClassAlpha()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    if DF.RefreshTestFrames then
        DF:RefreshTestFrames()
    end
end

-- Lightweight color updates for various frame elements
function DF:LightweightUpdateHealthColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    -- Check if we're in the relevant test mode
    local inTestMode = (mode == "raid" and DF.raidTestMode) or (mode == "party" and DF.testMode)
    
    -- For gradient mode, we need to rebuild the color curve when colors change
    if db.healthColorMode == "PERCENT" then
        DF:UpdateColorCurve()
    end
    
    local function UpdateFrame(frame, index)
        if not frame or not frame.healthBar then return end
        -- Aura Designer replace mode owns the bar colour exclusively (single layer).
        -- Don't stomp it with the normal health colour while its indicator is active.
        if frame.dfAD and frame.dfAD.healthbar and frame.dfAD.healthbarMode == "replace" then return end

        if db.healthColorMode == "CUSTOM" and db.healthColor then
            local c = db.healthColor
            frame.healthBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        elseif db.healthColorMode == "PERCENT" and inTestMode then
            -- For gradient mode in test mode, get the test data health value
            local isRaid = frame.isRaidFrame
            local testData = DF:GetTestUnitData(index, isRaid)
            if testData then
                local health = testData.healthPercent or testData.health or 0.75
                local color = DF:GetHealthGradientColor(health, db, testData.class)
                if color then
                    frame.healthBar:SetStatusBarColor(color.r, color.g, color.b)
                end
            end
        elseif db.healthColorMode == "CLASS" and inTestMode then
            -- For class color mode in test mode
            local isRaid = frame.isRaidFrame
            local testData = DF:GetTestUnitData(index, isRaid)
            if testData and testData.class then
                local classColor = DF:GetClassColor(testData.class)
                if classColor then
                    frame.healthBar:SetStatusBarColor(classColor.r, classColor.g, classColor.b)
                end
            end
        end
    end
    
    IterateFramesInMode(mode, function(frame) UpdateFrame(frame, 0) end)
    
    -- For live frames with PERCENT or CLASS mode, trigger a full update
    -- since we can't directly set colors due to taint/secret value restrictions
    -- Skip during slider drag to avoid recursion (ThrottledUpdateAll calls back into us)
    if not inTestMode and not DF.sliderDragging and (db.healthColorMode == "PERCENT" or db.healthColorMode == "CLASS") then
        DF:ThrottledUpdateAll()
    end
end

function DF:LightweightUpdateBackgroundColor()
    -- Set flag to prevent UpdateBackgroundAppearance from overwriting during color adjustment
    DF.isAdjustingBackgroundColor = true
    
    -- Clear flag after a short delay (longer than the range update interval of 0.2s)
    if DF.bgColorAdjustTimer then
        DF.bgColorAdjustTimer:Cancel()
    end
    DF.bgColorAdjustTimer = C_Timer.NewTimer(0.3, function()
        DF.isAdjustingBackgroundColor = false
    end)
    
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local bgTexture = db.backgroundTexture or "Solid"
    local bgMode = db.backgroundColorMode or "CUSTOM"
    
    local function UpdateFrame(frame, testClass)
        if not frame or not frame.background then return end
        
        -- Clear the background key cache so the new settings will be applied
        frame.dfCurrentBgKey = nil
        
        -- Determine class color for CLASS mode
        local cr, cg, cb = 0, 0, 0
        if bgMode == "CLASS" then
            local cc
            if testClass then
                -- Test mode - use provided class
                cc = DF:GetClassColor(testClass)
            elseif frame.unit and UnitExists(frame.unit) then
                -- Live mode - get from unit
                local _, class = UnitClass(frame.unit)
                cc = class and DF:GetClassColor(class)
            end
            if cc then cr, cg, cb = cc.r, cc.g, cc.b end
        end
        
        if bgTexture == "Solid" or bgTexture == "" then
            -- Solid color mode - update cache and key
            frame.dfCurrentBgTexture = "Solid"
            if bgMode == "CUSTOM" and db.backgroundColor then
                local c = db.backgroundColor
                frame.background:SetColorTexture(c.r, c.g, c.b, c.a or 0.8)
                frame.dfCurrentBgKey = string.format("CUSTOM:%.2f:%.2f:%.2f:%.2f", c.r, c.g, c.b, c.a or 0.8)
            elseif bgMode == "CLASS" then
                local bgAlpha = db.backgroundClassAlpha or 0.3
                frame.background:SetColorTexture(cr, cg, cb, bgAlpha)
                frame.dfCurrentBgKey = string.format("CLASS:%.2f:%.2f:%.2f:%.2f", cr, cg, cb, bgAlpha)
            else
                -- Fallback - use default background
                local c = db.backgroundColor or {r = 0.1, g = 0.1, b = 0.1, a = 0.8}
                frame.background:SetColorTexture(c.r, c.g, c.b, c.a or 0.8)
                frame.dfCurrentBgKey = string.format("CUSTOM:%.2f:%.2f:%.2f:%.2f", c.r, c.g, c.b, c.a or 0.8)
            end
        else
            -- Textured background - always apply when called from settings (user is changing texture)
            -- Update cache so UpdateUnitFrame knows the current texture
            frame.background:SetTexture(bgTexture)
            frame.background:SetHorizTile(false)
            frame.background:SetVertTile(false)
            frame.dfCurrentBgTexture = bgTexture
            
            -- Ensure SetAlpha is 1.0 for textured backgrounds (alpha controlled via vertex color only)
            frame.background:SetAlpha(1.0)
            
            if bgMode == "CUSTOM" and db.backgroundColor then
                local c = db.backgroundColor
                frame.background:SetVertexColor(c.r, c.g, c.b, c.a or 0.8)
            elseif bgMode == "CLASS" then
                local bgAlpha = db.backgroundClassAlpha or 0.3
                frame.background:SetVertexColor(cr, cg, cb, bgAlpha)
            else
                -- Fallback - use default background
                local c = db.backgroundColor or {r = 0.1, g = 0.1, b = 0.1, a = 0.8}
                frame.background:SetVertexColor(c.r, c.g, c.b, c.a or 0.8)
            end
        end
    end
    
    IterateFramesInMode(mode, function(frame) UpdateFrame(frame, nil) end)
end

function DF:LightweightUpdateBorderColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    local function UpdateFrame(frame)
        if not frame or not frame.border then return end
        -- Route through SetBorderColor so it recolours whichever mode (solid
        -- edges or texture backdrop) is currently active. Resolved per-frame
        -- via GetFrameBorderColor so class / role colours pick up each
        -- unit's resolved colour, and the dedicated frameBorderAlpha slider
        -- is honoured on every drag tick.
        if frame.border.SetBorderColor then
            frame.border:SetBorderColor(DF:GetFrameBorderColor(frame, db))
        end
    end

    IterateFramesInMode(mode, UpdateFrame)
end

function DF:LightweightUpdateTextColor(textType)
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    -- Check if we're in test mode
    local inTestMode = (mode == "raid" and DF.raidTestMode) or (mode == "party" and DF.testMode)
    
    -- Map text type to correct color key and frame property
    local colorKey, textKey
    if textType == "name" then
        -- Skip if using class color for names
        if db.nameTextUseClassColor then return end
        colorKey = "nameTextColor"
        textKey = "nameText"
    elseif textType == "health" then
        -- Skip if using class color for health text
        if db.healthTextUseClassColor then return end
        colorKey = "healthTextColor"
        textKey = "healthText"
    elseif textType == "status" then
        colorKey = "statusTextColor"
        textKey = "statusText"
    else
        return
    end
    
    local function UpdateFrame(frame, index)
        if not frame or not frame[textKey] then return end
        if not db[colorKey] then return end
        
        local c = db[colorKey]
        local alpha = c.a or 1
        
        -- In test mode, respect OOR and dead fade alphas
        if inTestMode then
            local isRaid = frame.isRaidFrame
            local testData = DF:GetTestUnitData(index, isRaid)
            
            if testData then
                -- Check if OOR first (OOR takes priority over dead fade)
                if db.testShowOutOfRange and testData.outOfRange then
                    if textType == "name" then
                        if db.oorEnabled then
                            alpha = db.oorNameTextAlpha or 0.55
                        else
                            alpha = db.rangeFadeAlpha or 0.55
                        end
                    elseif textType == "health" then
                        if db.oorEnabled then
                            alpha = db.oorHealthTextAlpha or 0.55
                        else
                            alpha = db.rangeFadeAlpha or 0.55
                        end
                    end
                -- Dead fade only applies when in range
                elseif testData.status and db.fadeDeadFrames then
                    if textType == "name" then
                        alpha = db.fadeDeadName or 1.0
                    elseif textType == "status" then
                        alpha = db.fadeDeadStatusText or 1.0
                    end
                end
            end
        end
        
        frame[textKey]:SetTextColor(c.r, c.g, c.b, alpha)
    end
    
    IterateFramesInMode(mode, function(frame) UpdateFrame(frame, 0) end)
end

function DF:LightweightUpdatePowerBarColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateFrame(frame)
        if not frame or not frame.powerBar then return end
        if db.powerBarColor then
            local c = db.powerBarColor
            frame.powerBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        end
    end
    
    IterateFramesInMode(mode, UpdateFrame)
end

function DF:LightweightUpdateGradientPreview()
    -- Just update the gradient bar preview in options, not all frames
    if DF.GUI and DF.GUI.currentGradientBar and DF.GUI.currentGradientBar.UpdatePreview then
        DF.GUI.currentGradientBar.UpdatePreview()
    end
end

function DF:LightweightUpdateAbsorbBarColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateFrame(frame)
        if not frame then return end
        
        -- Update main absorb bar
        if frame.dfAbsorbBar and db.absorbBarColor then
            local c = db.absorbBarColor
            frame.dfAbsorbBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        end
        if frame.dfAbsorbBar and frame.dfAbsorbBar.bg and db.absorbBarBackgroundColor then
            local c = db.absorbBarBackgroundColor
            frame.dfAbsorbBar.bg:SetColorTexture(c.r, c.g, c.b, c.a or 1)
        end
        
        -- Update overflow bar (for ATTACHED_OVERFLOW mode)
        if frame.absorbOverflowBar and db.absorbBarColor then
            local c = db.absorbBarColor
            frame.absorbOverflowBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        end
    end
    
    IterateFramesInMode(mode, UpdateFrame)
end

function DF:LightweightUpdateReducedMaxHealthColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db or not db.reducedMaxHealthColor then return end
    local c = db.reducedMaxHealthColor

    local function UpdateFrame(frame)
        if frame and frame.dfReducedMaxHealthBar then
            frame.dfReducedMaxHealthBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        end
    end

    IterateFramesInMode(mode, UpdateFrame)
end

function DF:LightweightUpdateHealAbsorbBarColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateFrame(frame)
        if not frame or not frame.dfHealAbsorbBar then return end
        if db.healAbsorbBarColor then
            local c = db.healAbsorbBarColor
            frame.dfHealAbsorbBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
        end
        if frame.dfHealAbsorbBar.bg and db.healAbsorbBarBackgroundColor then
            local c = db.healAbsorbBarBackgroundColor
            frame.dfHealAbsorbBar.bg:SetColorTexture(c.r, c.g, c.b, c.a or 1)
        end
    end
    
    IterateFramesInMode(mode, UpdateFrame)
end

function DF:LightweightUpdateSelectionHighlightColor()
    -- Just call the generic highlight update for selection
    DF:LightweightUpdateHighlight("selection")
end

-- Update expiring border color on buff icons
function DF:LightweightUpdateExpiringBorderColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local function UpdateIcons(frame)
        if not frame or not frame.buffIcons then return end
        for _, icon in ipairs(frame.buffIcons) do
            -- Re-apply the unified expiring border so a live colour-picker change
            -- repaints the static colour (and keeps style/animation in sync).
            DF:ConfigureExpiringBorder(icon, db, "buffExpiring")
        end
    end

    IterateFramesInMode(mode, UpdateIcons)
end

-- Update expiring tint color on buff icons
function DF:LightweightUpdateExpiringTintColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local color = db.buffExpiringTintColor or {r = 1, g = 0.3, b = 0.3, a = 0.3}
    
    local function UpdateIcons(frame)
        if not frame or not frame.buffIcons then return end
        for _, icon in ipairs(frame.buffIcons) do
            if icon and icon.expiringTint then
                icon.expiringTint:SetColorTexture(color.r, color.g, color.b, color.a or 0.3)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateIcons)
end

-- Update missing buff icon border color
function DF:LightweightUpdateMissingBuffBorderColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    local function UpdateIcon(frame)
        if frame and frame.missingBuffBorder then
            -- Route through BuildSpec + Apply (Stage 4.1) so the colour
            -- pick respects ColorSource / gradient / etc. The full-render
            -- path in Frames/Icons.lua does the same thing — keeping the
            -- live drag-update consistent so dragging the picker on a
            -- gradient or class-coloured border updates correctly.
            DF.Border:Apply(frame.missingBuffBorder,
                DF.Border:BuildSpec(db, "missingBuffIcon", { unit = frame.unit, frame = frame, iconMode = true }))
        end
    end

    IterateFramesInMode(mode, UpdateIcon)
end

-- Update defensive icon colors (border and duration text)
function DF:LightweightUpdateDefensiveIconColors()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    -- Same test-mode delegation as LightweightUpdateDefensiveIcons: the test
    -- render owns multi-defensive layout; touching individual icons here can
    -- leave the primary anchored away from the centred-layout position.
    if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestDefensiveBar then
        DF:UpdateAllTestDefensiveBar()
        return
    end

    local borderColor = db.defensiveIconBorderColor or {r = 0, g = 0, b = 0, a = 1}
    local durationColor = db.defensiveIconDurationColor or {r = 1, g = 1, b = 1}
    
    local function ApplyColors(icon, unit)
        if not icon then return end
        if icon.border then
            -- ctx.unit lets the Class/Role resolvers fire on the live update
            -- path. ctx.frame additionally lets test frames preview
            -- Class/Role via GetTestUnitData (Stage 4.0). spec.color is NOT
            -- overridden — BuildSpec resolves it via the ColorSource per
            -- unit, so a static override here would clobber CLASS/ROLE.
            local spec = DF.Border:BuildSpec(db, "defensiveIcon", {
                unit  = unit,
                frame = icon.unitFrame,
                iconMode = true,
            })
            DF.Border:Apply(icon.border, spec)
        end
        -- Skip duration recolour when colorByTime is active — RenderDefensiveBarIcon owns it then.
        if not db.defensiveIconDurationColorByTime and icon.nativeCooldownText then
            icon.nativeCooldownText:SetTextColor(durationColor.r, durationColor.g, durationColor.b, 1)
        end
    end

    local function UpdateIcon(frame)
        if not frame or not frame.defensiveIcon then return end
        ApplyColors(frame.defensiveIcon, frame.unit)
        if frame.defensiveBarIcons then
            for _, extraIcon in pairs(frame.defensiveBarIcons) do
                ApplyColors(extraIcon, frame.unit)
            end
        end
    end

    IterateFramesInMode(mode, UpdateIcon)
end

-- Update group label color
function DF:LightweightUpdateGroupLabelColor()
    if not DF.raidGroupLabels then return end
    
    local db = DF:GetRaidDB()
    local color = db.groupLabelColor or {r = 1, g = 1, b = 1, a = 1}
    
    for _, label in pairs(DF.raidGroupLabels) do
        if label then
            label:SetTextColor(color.r, color.g, color.b, color.a or 1)
        end
    end
end

-- Update resource/power bar background color
function DF:LightweightUpdateResourceBarBackgroundColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local bgColor = db.resourceBarBackgroundColor or {r = 0.1, g = 0.1, b = 0.1, a = 0.8}
    
    local function UpdateFrame(frame)
        if not frame or not frame.dfPowerBar or not frame.dfPowerBar.bg then return end
        frame.dfPowerBar.bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)
    end
    
    IterateFramesInMode(mode, UpdateFrame)
end

-- Update resource bar border visibility and color
function DF:LightweightUpdateResourceBarBorder()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    local function UpdateFrame(frame)
        if not frame or not frame.dfPowerBar or not frame.dfPowerBar.border then return end
        -- Route through BuildSpec + Apply (Stage 4.2) so the live drag-
        -- update path renders identically to ApplyResourceBarLayout.
        -- ctx.unit / ctx.frame let Class / Role resolvers fire.
        DF.Border:Apply(frame.dfPowerBar.border,
            DF.Border:BuildSpec(db, "resourceBar", {
                unit  = frame.unit,
                frame = frame,
            }))
    end

    IterateFramesInMode(mode, UpdateFrame)
end

-- Update resource bar border color only
function DF:LightweightUpdateResourceBarBorderColor()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end

    local function UpdateFrame(frame)
        if not frame or not frame.dfPowerBar or not frame.dfPowerBar.border then return end
        DF.Border:Apply(frame.dfPowerBar.border,
            DF.Border:BuildSpec(db, "resourceBar", {
                unit  = frame.unit,
                frame = frame,
            }))
    end

    IterateFramesInMode(mode, UpdateFrame)
end

-- Update resource bar frame level
function DF:LightweightUpdateResourceBarFrameLevel()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    local frameLevelOffset = db.resourceBarFrameLevel or 2
    
    local function UpdateFrame(frame)
        if not frame or not frame.dfPowerBar then return end
        local bar = frame.dfPowerBar
        local baseLevel = frame:GetFrameLevel()
        bar:SetFrameLevel(baseLevel + frameLevelOffset)
        -- Border needs to be above the bar
        if bar.border then
            bar.border:SetFrameLevel(bar:GetFrameLevel() + 1)
        end
    end
    
    IterateFramesInMode(mode, UpdateFrame)
end

-- Update dispel overlay colors directly (for test mode preview only)
-- IMPORTANT: Only updates test mode frames to preserve secret color handling on live frames
function DF:LightweightUpdateDispelColors()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    -- Only apply to test mode frames - live frames must use color curves for secret colors
    local inTestMode = (mode == "raid" and DF.raidTestMode) or (mode == "party" and DF.testMode)
    if not inTestMode then return end
    
    -- Get color mapping from db
    local colors = {
        Magic = db.dispelMagicColor or {r = 0.2, g = 0.6, b = 1.0},
        Curse = db.dispelCurseColor or {r = 0.6, g = 0.0, b = 1.0},
        Disease = db.dispelDiseaseColor or {r = 0.6, g = 0.4, b = 0.0},
        Poison = db.dispelPoisonColor or {r = 0.0, g = 0.6, b = 0.0},
        Bleed = db.dispelBleedColor or {r = 1.0, g = 0.0, b = 0.0},
        Enrage = db.dispelBleedColor or {r = 1.0, g = 0.0, b = 0.0},
    }
    
    local borderAlpha = db.dispelBorderAlpha or 0.8
    local gradientAlpha = db.dispelGradientAlpha or 0.5
    local gradientIntensity = db.dispelGradientIntensity or 1.0
    
    local function UpdateDispelColor(frame)
        if not frame or not frame.dfDispelOverlay then return end
        local overlay = frame.dfDispelOverlay
        
        -- Get the current dispel type stored on the overlay
        local dispelType = overlay.currentDispelType
        if not dispelType then return end
        
        local color = colors[dispelType]
        if not color then return end
        
        local r, g, b = color.r, color.g, color.b
        
        -- Update border colors
        if overlay.borderTop and overlay.borderTop:IsShown() then
            local tex = overlay.borderTop:GetStatusBarTexture()
            tex:SetVertexColor(r, g, b, borderAlpha)
        end
        if overlay.borderBottom and overlay.borderBottom:IsShown() then
            local tex = overlay.borderBottom:GetStatusBarTexture()
            tex:SetVertexColor(r, g, b, borderAlpha)
        end
        if overlay.borderLeft and overlay.borderLeft:IsShown() then
            local tex = overlay.borderLeft:GetStatusBarTexture()
            tex:SetVertexColor(r, g, b, borderAlpha)
        end
        if overlay.borderRight and overlay.borderRight:IsShown() then
            local tex = overlay.borderRight:GetStatusBarTexture()
            tex:SetVertexColor(r, g, b, borderAlpha)
        end
        
        -- Update gradient color
        local gradientStyle = db.dispelGradientStyle or "FULL"
        if gradientStyle == "EDGE" then
            -- Update EDGE style gradient textures
            local ri, gi, bi = r * gradientIntensity, g * gradientIntensity, b * gradientIntensity
            if overlay.gradientTop and overlay.gradientTop:IsShown() then
                overlay.gradientTop:SetVertexColor(ri, gi, bi, gradientAlpha)
            end
            if overlay.gradientBottom and overlay.gradientBottom:IsShown() then
                overlay.gradientBottom:SetVertexColor(ri, gi, bi, gradientAlpha)
            end
            if overlay.gradientLeft and overlay.gradientLeft:IsShown() then
                overlay.gradientLeft:SetVertexColor(ri, gi, bi, gradientAlpha)
            end
            if overlay.gradientRight and overlay.gradientRight:IsShown() then
                overlay.gradientRight:SetVertexColor(ri, gi, bi, gradientAlpha)
            end
        elseif overlay.gradient and overlay.gradient:IsShown() then
            local tex = overlay.gradient:GetStatusBarTexture()
            tex:SetVertexColor(r * gradientIntensity, g * gradientIntensity, b * gradientIntensity, gradientAlpha)
        end
    end
    
    IterateFramesInMode(mode, UpdateDispelColor)
end

-- Update debuff border colors directly (for test mode preview only)
-- Note: icon.debuffType is only set in test mode, so this only affects test frames
function DF:LightweightUpdateDebuffBorderColors()
    local mode = DF.GUI and DF.GUI.SelectedMode or "party"
    local db = DF.db[mode]
    if not db then return end
    
    -- Only apply to test mode frames
    local inTestMode = (mode == "raid" and DF.raidTestMode) or (mode == "party" and DF.testMode)
    if not inTestMode then return end
    
    -- Skip if borders not enabled or not using color by type
    if db.debuffShowBorder == false or db.debuffBorderColorByType == false then
        return
    end
    
    -- Get color mapping from db
    local colors = {
        Magic = db.debuffBorderColorMagic or {r = 0.2, g = 0.6, b = 1.0},
        Curse = db.debuffBorderColorCurse or {r = 0.6, g = 0.0, b = 1.0},
        Disease = db.debuffBorderColorDisease or {r = 0.6, g = 0.4, b = 0.0},
        Poison = db.debuffBorderColorPoison or {r = 0.0, g = 0.6, b = 0.0},
        Bleed = db.debuffBorderColorBleed or {r = 1.0, g = 0.0, b = 0.0},
        Enrage = db.debuffBorderColorBleed or {r = 1.0, g = 0.0, b = 0.0},
    }
    local defaultColor = db.debuffBorderColorNone or {r = 0.8, g = 0.0, b = 0.0}
    
    local function UpdateDebuffColors(frame)
        if not frame or not frame.debuffIcons then return end
        for _, icon in ipairs(frame.debuffIcons) do
            if icon and icon.border and icon:IsShown() then
                -- Get the debuff type stored on the icon (only set in test mode)
                local debuffType = icon.debuffType
                local color = colors[debuffType] or defaultColor
                icon.border:SetColor(color.r, color.g, color.b, 0.8)
            end
        end
    end
    
    IterateFramesInMode(mode, UpdateDebuffColors)
end

-- ============================================================
-- UTF-8 STRING HELPERS
-- ============================================================
-- Standard string.len and string.sub operate on bytes, not characters.
-- Cyrillic, Asian, and other non-ASCII characters are multi-byte in UTF-8.

-- Count actual UTF-8 characters (not bytes)
function DF:UTF8Len(str)
    if not str then return 0 end
    
    -- Check for secret values (WoW privacy system for arena opponents)
    if issecretvalue and issecretvalue(str) then return 0 end
    
    local len = 0
    local i = 1
    local strLen = #str
    while i <= strLen do
        local byte = string.byte(str, i)
        if not byte then break end  -- Safety check
        if byte < 128 then
            -- ASCII (0-127): 1 byte
            i = i + 1
        elseif byte < 224 then
            -- 2-byte sequence (128-2047)
            i = i + 2
        elseif byte < 240 then
            -- 3-byte sequence (2048-65535)
            i = i + 3
        else
            -- 4-byte sequence (65536+)
            i = i + 4
        end
        len = len + 1
    end
    return len
end

-- UTF-8 aware substring (by character count, not bytes)
function DF:UTF8Sub(str, startChar, endChar)
    if not str then return "" end
    
    -- Check for secret values (WoW privacy system for arena opponents)
    if issecretvalue and issecretvalue(str) then return "" end
    
    local strLen = #str
    local charCount = 0
    local startByte = 1
    local endByte = strLen
    
    local i = 1
    while i <= strLen do
        charCount = charCount + 1
        
        -- Find start byte
        if charCount == startChar then
            startByte = i
        end
        
        -- Determine byte length of current character
        local byte = string.byte(str, i)
        local charBytes
        if byte < 128 then
            charBytes = 1
        elseif byte < 224 then
            charBytes = 2
        elseif byte < 240 then
            charBytes = 3
        else
            charBytes = 4
        end
        
        -- Find end byte
        if charCount == endChar then
            endByte = i + charBytes - 1
            break
        end
        
        i = i + charBytes
    end
    
    return string.sub(str, startByte, endByte)
end

-- ============================================================
-- UNIT NAME API (hookable by external addons)
-- ============================================================
-- SECRET VALUE HANDLING (Midnight 12.0)
-- ============================================================

-- Check if a value can be accessed (not a secret value)
-- Secret values will throw errors when compared or used as table indices
function DF:CanAccessValue(value)
    if value == nil then return true end
    
    -- Try to compare the value - this will fail for secret values
    local success = pcall(function()
        local _ = (value == value)
    end)
    return success
end

function DF:IsSecretValue(value)
    return not DF:CanAccessValue(value)
end

-- ============================================================
-- AURA DEBUG
-- ============================================================

function DF:DebugAuraFilters(unit)
    if not UnitExists(unit) then
        print("|cffff0000DandersFrames:|r Unit '" .. unit .. "' does not exist.")
        return
    end
    
    local filters = {
        "HELPFUL",
        "HELPFUL|PLAYER",
        "HELPFUL|RAID",
        "HELPFUL|PLAYER|RAID",
        "HELPFUL|CANCELABLE",
    }
    
    print("|cff00ff00=== DandersFrames Aura Debug for " .. unit .. " ===|r")
    
    for _, filter in ipairs(filters) do
        print("|cffffcc00Filter: " .. filter .. "|r")
        local count = 0
        for i = 1, 40 do
            local auraData = nil
            if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
                auraData = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
            end
            if not auraData then break end
            
            local name = "?"
            local spellId = "?"
            pcall(function() name = auraData.name or "?" end)
            pcall(function() spellId = auraData.spellId or "?" end)
            
            print("  " .. i .. ": " .. tostring(name) .. " (ID: " .. tostring(spellId) .. ")")
            count = count + 1
        end
        if count == 0 then
            print("  (none)")
        end
        print("")
    end
    
    -- Check what Blizzard filter functions are available
    print("|cffffcc00Blizzard Filter Functions:|r")
    print("  CompactUnitFrame_UtilShouldDisplayBuff: " .. tostring(CompactUnitFrame_UtilShouldDisplayBuff ~= nil))
    print("  AuraUtil.ShouldDisplayBuff: " .. tostring(AuraUtil and AuraUtil.ShouldDisplayBuff ~= nil))
    print("  AuraUtil.ForEachAura: " .. tostring(AuraUtil and AuraUtil.ForEachAura ~= nil))
    print("")
    
    -- Try Blizzard's filter
    print("|cffffcc00Testing Blizzard Filters:|r")
    if AuraUtil and AuraUtil.ForEachAura then
        local blizzBuffs = {}
        AuraUtil.ForEachAura(unit, "HELPFUL", nil, function(auraData)
            local name = "?"
            local spellId = "?"
            local shouldDisplay1 = "N/A"
            local shouldDisplay2 = "N/A"
            
            pcall(function() name = auraData.name or "?" end)
            pcall(function() spellId = auraData.spellId or "?" end)
            
            -- Try CompactUnitFrame_UtilShouldDisplayBuff
            if CompactUnitFrame_UtilShouldDisplayBuff then
                local ok, result = pcall(function()
                    return CompactUnitFrame_UtilShouldDisplayBuff(unit, auraData.auraInstanceID, auraData)
                end)
                if ok then
                    shouldDisplay1 = tostring(result)
                else
                    shouldDisplay1 = "ERROR: " .. tostring(result)
                end
            end
            
            -- Try AuraUtil.ShouldDisplayBuff
            if AuraUtil.ShouldDisplayBuff then
                local ok, result = pcall(function()
                    return AuraUtil.ShouldDisplayBuff(auraData)
                end)
                if ok then
                    shouldDisplay2 = tostring(result)
                else
                    shouldDisplay2 = "ERROR: " .. tostring(result)
                end
            end
            
            table.insert(blizzBuffs, {
                name = name,
                spellId = spellId,
                compactFrame = shouldDisplay1,
                auraUtil = shouldDisplay2
            })
            return false  -- continue iteration
        end)
        
        for i, buff in ipairs(blizzBuffs) do
            print("  " .. buff.name .. " (ID: " .. buff.spellId .. ")")
            print("    CompactUnitFrame: " .. buff.compactFrame)
            print("    AuraUtil: " .. buff.auraUtil)
        end
    else
        print("  AuraUtil.ForEachAura not available")
    end
    
    print("|cff00ff00=== End Aura Debug ===|r")
end

-- ============================================================
-- DATABASE MANAGEMENT
-- ============================================================

function DF:GetDB(mode)
    if not DF.db then
        return mode == "raid" and DF.RaidDefaults or DF.PartyDefaults
    end
    return DF.db[mode or "party"]
end

function DF:GetRaidDB()
    return DF:GetDB("raid")
end

-- ============================================================
-- CONTENT TYPE DETECTION
-- Unified approach using IsInInstance() for all content detection
-- ============================================================

-- Cache for content type (updated on zone change)
DF.cachedContentType = nil
DF.cachedInstanceType = nil

-- Debug: Force arena mode for testing (toggle with /dfarena)
DF.forceArenaMode = false

-- Get the current content type for frame/profile switching
-- Returns: "arena", "battleground", "mythic", "instanced", "openWorld", or nil
function DF:GetContentType()
    -- DEBUG: Force arena mode for testing
    if DF.forceArenaMode then
        DF.cachedContentType = "arena"
        return "arena"
    end

    -- ARENA RELOAD FIX: snapshot the saved content-type hint ONCE, before any
    -- detection branch below can overwrite it. Early calls (e.g.
    -- FinalizeHeaderInit → UpdateHeaderVisibility at ADDON_LOADED on a reload)
    -- run while IsInInstance()/IsInRaid() may still be unreliable; without the
    -- snapshot, those calls wiped DandersFramesCharDB.lastContentType (or
    -- overwrote it with "openWorld") before the reload fallback could use it.
    if not DF._contentTypeHintCaptured and DandersFramesCharDB then
        DF._contentTypeHintCaptured = true
        DF._contentTypeHintAtLoad = DandersFramesCharDB.lastContentType
    end

    local inInstance, instanceType = IsInInstance()
    
    -- Cache instance type for other uses
    DF.cachedInstanceType = instanceType
    
    -- Arena - always uses party-style frames (but with raid unit IDs)
    if instanceType == "arena" then
        DF.cachedContentType = "arena"
        DF.useContentTypeFallback = nil  -- Clear fallback, real detection working
        if DandersFramesCharDB then DandersFramesCharDB.lastContentType = "arena" end
        return "arena"
    end
    
    -- Battleground (PvP instance)
    if instanceType == "pvp" then
        DF.cachedContentType = "battleground"
        DF.useContentTypeFallback = nil
        if DandersFramesCharDB then DandersFramesCharDB.lastContentType = "battleground" end
        return "battleground"
    end
    
    -- Not in a raid group - no raid content type applies
    if not IsInRaid() then
        -- ARENA RELOAD FIX: If IsInInstance() AND IsInRaid() both return false after a
        -- reload, WoW's APIs haven't recovered yet. Check the saved content type from
        -- before the reload. Only trust "arena" — other types recover fine on their own.
        if DF.useContentTypeFallback and not inInstance
           and (instanceType == "none" or instanceType == nil)
           and DF._contentTypeHintAtLoad == "arena" then
            DF.cachedContentType = "arena"
            return "arena"
        end
        
        DF.cachedContentType = nil
        DF.useContentTypeFallback = nil
        if DandersFramesCharDB then DandersFramesCharDB.lastContentType = nil end
        return nil
    end
    
    -- Raid instance
    if instanceType == "raid" then
        local difficultyID = select(3, GetInstanceInfo())
        if difficultyID == 16 then
            DF.cachedContentType = "mythic"
            DF.useContentTypeFallback = nil
            if DandersFramesCharDB then DandersFramesCharDB.lastContentType = "mythic" end
            return "mythic"
        end
        DF.cachedContentType = "instanced"
        DF.useContentTypeFallback = nil
        if DandersFramesCharDB then DandersFramesCharDB.lastContentType = "instanced" end
        return "instanced"
    end
    
    -- In a raid group but not in an instance = open world (world boss, etc.)
    if IsInRaid() then
        -- ARENA RELOAD FIX (part 2): IsInRaid() can recover before
        -- IsInInstance() after a reload in arena (arena groups ARE raid
        -- groups). Without this, the not-yet-recovered instanceType made us
        -- conclude "openWorld" — showing raid frames over the arena header
        -- and overwriting the saved arena hint.
        if DF.useContentTypeFallback and not inInstance
           and (instanceType == "none" or instanceType == nil)
           and DF._contentTypeHintAtLoad == "arena" then
            DF.cachedContentType = "arena"
            return "arena"
        end

        DF.cachedContentType = "openWorld"
        DF.useContentTypeFallback = nil
        if DandersFramesCharDB then DandersFramesCharDB.lastContentType = "openWorld" end
        return "openWorld"
    end
    
    DF.cachedContentType = nil
    DF.useContentTypeFallback = nil
    if DandersFramesCharDB then DandersFramesCharDB.lastContentType = nil end
    return nil
end

-- Check if we're in arena (convenience function)
function DF:IsInArena()
    local contentType = DF:GetContentType()
    return contentType == "arena"
end

-- Check if we're in a battleground (convenience function)
function DF:IsInBattleground()
    local contentType = DF:GetContentType()
    return contentType == "battleground"
end

-- Check if current content should use party frames (arena uses party-style but raid units)
function DF:ShouldUsePartyFrames()
    local contentType = DF:GetContentType()
    -- Arena uses arena header (party-style but raid units)
    -- All other raid content uses raid frames
    return contentType ~= "arena" and not IsInRaid()
end

-- ============================================================
-- DEBUG: Force Arena Mode
-- Usage: /dfarena - Toggle arena mode for testing
-- Requires being in a raid group to see frames
-- ============================================================
SLASH_DFARENA1 = "/dfarena"
SlashCmdList["DFARENA"] = function(msg)
    if InCombatLockdown() then
        print("|cffff8033DandersFrames:|r " .. L["Cannot toggle arena mode during combat"])
        return
    end
    
    DF.forceArenaMode = not DF.forceArenaMode
    
    if DF.forceArenaMode then
        print("|cffff8033DandersFrames:|r " .. format(L["Arena mode %sENABLED%s for testing"], "|cff00ff00", "|r"))
        print("  - " .. L["Join a raid group (2-5 players works best)"])
        print("  - " .. L["Arena header will show using raid1-5 unit IDs"])
        print("  - " .. L["Uses party frame settings/position"])
        print("  - " .. L["Type /dfarena again to disable"])
    else
        print("|cffff8033DandersFrames:|r " .. format(L["Arena mode %sDISABLED%s"], "|cffff0000", "|r"))
    end
    
    -- Apply full header settings (includes orientation, grow from center, etc.)
    if DF.ApplyHeaderSettings then
        DF:ApplyHeaderSettings()
    end
    
    -- Update frame visibility
    if DF.UpdateHeaderVisibility then
        DF:UpdateHeaderVisibility()
    end
    
    -- Trigger a roster update to refresh everything
    if DF.ProcessRosterUpdate then
        DF:ProcessRosterUpdate()
    end
    
    -- Refresh all live frames to apply party styling
    if DF.RefreshLiveFrames then
        C_Timer.After(0.1, function()
            DF:RefreshLiveFrames()
        end)
    end
end

function DF:GetSetting(key, mode)
    local db = self:GetDB(mode)
    local defaults = mode == "raid" and DF.RaidDefaults or DF.PartyDefaults
    if db and db[key] ~= nil then
        return db[key]
    end
    return defaults[key]
end

-- Get current mode based on group size
function DF:GetCurrentMode()
    if IsInRaid() then
        return "raid"
    end
    return "party"
end

-- Deep copy helper (also defined in Profile.lua, but needed here too)
-- Note: DeepCopy, ResetProfile and CopyProfile are defined in Profile.lua

-- ============================================================
-- CVAR SETTINGS (Blizzard frame settings we control)
-- ============================================================

-- Apply saved CVar settings on login/reload
-- These control Blizzard's debuff display filtering which we use for our frames
function DF:ApplySavedCVarSettings()
    if not DF.db then return end
    
    -- These settings are stored in the party profile (shared between modes)
    local db = DF.db.party
    if not db then return end
    
    -- Apply dispel indicator type (1=All Dispellable, 2=My Dispels, 3=None but we force minimum 1)
    local dispelIndicator = db._blizzDispelIndicator
    if dispelIndicator == nil or dispelIndicator == 0 then
        dispelIndicator = 1  -- Default to "All Dispellable"
        db._blizzDispelIndicator = 1
    end
    SetCVar("raidFramesDispelIndicatorType", dispelIndicator)
    
    if DF.debugEnabled then
        print("|cff00ff00DandersFrames:|r Applied CVar settings:")
        print("  raidFramesDispelIndicatorType =", dispelIndicator)
    end
end

-- Deep equality check for the proxy contamination guard.
-- Lua's == is reference equality for tables, so a new table with identical
-- contents would bypass the guard and leak override values into _realRaidDB.
local function DeepEquals(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not DeepEquals(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- ============================================================
-- DB OVERLAY PROXY
-- Wraps DF.db so auto-profile overrides are read-through without
-- mutating the real SavedVariables table.
-- ============================================================

function DF:WrapDB()
    -- Store references to the real (serializable) tables
    self._realProfile = self.db
    self._realRaidDB  = self._realProfile.raid

    -- Raid proxy: reads check raidOverrides first, writes go to real table
    local raidProxy = setmetatable({}, {
        __realTable = self._realRaidDB,
        __index = function(_, key)
            local overrides = DF.raidOverrides
            if overrides and overrides[key] ~= nil then
                return overrides[key]
            end
            return DF._realRaidDB[key]
        end,
        __newindex = function(_, key, value)
            -- Guard against override value contamination: if a runtime auto profile
            -- is active and the write value matches the override, it's a read-then-write
            -- loop (not an intentional user change) — block it to keep the global clean.
            local overrides = DF.raidOverrides
            if overrides and overrides[key] ~= nil then
                local apu = DF.AutoProfilesUI
                if apu and apu.activeRuntimeProfile and not apu:IsEditing() then
                    if DeepEquals(value, overrides[key]) then
                        return
                    end
                end
            end
            DF._realRaidDB[key] = value
        end,
    })
    self._raidProxy = raidProxy

    -- Profile proxy: intercepts .raid access, everything else falls through
    self.db = setmetatable({}, {
        __isDBProxy = true,
        __index = function(_, key)
            if key == "raid" then
                return raidProxy
            end
            return DF._realProfile[key]
        end,
        __newindex = function(_, key, value)
            if key == "raid" then
                -- Full raid table replacement (e.g. import)
                DF._realProfile.raid = value
                DF._realRaidDB = value
                -- Update the raid proxy's metatable reference
                local mt = getmetatable(raidProxy)
                mt.__realTable = value
            else
                DF._realProfile[key] = value
            end
        end,
    })
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ROLES_ASSIGNED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")  -- Fires when spec changes
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")  -- Fires when talents change
eventFrame:RegisterEvent("UNIT_PET")  -- Fires when a pet is summoned/dismissed
eventFrame:RegisterEvent("PLAYER_UPDATE_RESTING")  -- Fires when entering/leaving rested area

-- One-shot copy of legacy Frame Border saved-variable keys to the canonical
-- `frame*Border*` naming the unified DF.Border / CreateBorderControls helpers
-- expect. Called per-mode from ADDON_LOADED. Idempotent: if the new key
-- already exists in the profile we leave it (the user has saved with the new
-- key); otherwise we adopt the legacy value. Legacy keys are NOT deleted so
-- the migration can be safely re-run and old profiles stay readable by a
-- previous addon version if the user rolls back.
function DF:MigrateFrameBorderKeys(modeDb)
    if not modeDb then return end
    local function adopt(newKey, oldKey)
        if modeDb[newKey] == nil and modeDb[oldKey] ~= nil then
            modeDb[newKey] = modeDb[oldKey]
        end
    end
    adopt("frameShowBorder",         "showFrameBorder")
    adopt("frameBorderSize",         "borderSize")
    adopt("frameBorderColor",        "borderColor")
    adopt("frameBorderStyle",        "borderStyle")
    adopt("frameBorderTexture",      "borderTexture")
    adopt("frameBorderUseClassColor","borderClassColor")

    -- ColorSource (single segmented key) supersedes the independent
    -- UseClassColor / UseRoleColor booleans. Copy whichever was true into
    -- the new key; leave the booleans intact so an old client can still
    -- read them.
    if modeDb.frameBorderColorSource == nil then
        if modeDb.frameBorderUseClassColor     then modeDb.frameBorderColorSource = "CLASS"
        elseif modeDb.frameBorderUseRoleColor  then modeDb.frameBorderColorSource = "ROLE"
        end
    end

    -- Gradient was previously an independent boolean (`<prefix>BorderGradientEnabled`)
    -- that overlaid on top of Style; Stage 2.3 folded it into Style as a
    -- third option so the user can't get conflicting "Solid + Class Color +
    -- Gradient" combinations. Adopt: if the old boolean is true and the
    -- style isn't already explicitly set to TEXTURE (which would be a
    -- deliberate other-mode choice), promote to "GRADIENT". Old boolean is
    -- left in place for rollback safety.
    local function adoptGradientStyle(prefix)
        local styleKey   = prefix .. "BorderStyle"
        local enabledKey = prefix .. "BorderGradientEnabled"
        if modeDb[enabledKey] == true and modeDb[styleKey] ~= "TEXTURE"
                and modeDb[styleKey] ~= "GRADIENT" then
            modeDb[styleKey] = "GRADIENT"
        end
    end
    adoptGradientStyle("frame")
    adoptGradientStyle("defensiveIcon")
end

-- Move the role-border colour set from per-mode storage (Stage 2 default
-- placement) up to profile level under DF.db.roleColors so the global Colors
-- settings page can manage them alongside class colours. Idempotent: only
-- adopts a mode-level value into profile-level when profile-level doesn't
-- already have one set, and only seeds defaults when neither exists. Called
-- once per ADDON_LOADED after both modes have been migrated.
function DF:MigrateRoleBorderColors()
    if not DF.db then return end
    if not DF.db.roleColors then DF.db.roleColors = {} end
    local rc = DF.db.roleColors

    local DEFAULTS = {
        TANK    = {r = 0.20, g = 0.55, b = 0.95, a = 1},
        HEALER  = {r = 0.20, g = 0.80, b = 0.30, a = 1},
        DAMAGER = {r = 0.85, g = 0.20, b = 0.20, a = 1},
    }

    -- Adopt from whichever mode-level set was customised first.
    local sources = { DF.db.party, DF.db.raid }
    local function adopt(role, modeKey)
        if rc[role] then return end
        for _, m in ipairs(sources) do
            if m and m[modeKey] then rc[role] = m[modeKey]; return end
        end
        rc[role] = DEFAULTS[role]
    end
    adopt("TANK",    "roleBorderColorTank")
    adopt("HEALER",  "roleBorderColorHealer")
    adopt("DAMAGER", "roleBorderColorDamager")
end

-- Adopt the legacy `resourceBarBorderEnabled` boolean into the canonical
-- `resourceBarShowBorder` key the unified DF.Border helper expects. Same
-- pattern as MigrateFrameBorderKeys — idempotent, leaves the legacy key
-- in place for rollback safety. Stage 4.2.
function DF:MigrateResourceBarBorderKeys(modeDb)
    if not modeDb then return end
    if modeDb.resourceBarShowBorder == nil and modeDb.resourceBarBorderEnabled ~= nil then
        modeDb.resourceBarShowBorder = modeDb.resourceBarBorderEnabled
    end
end

-- Aura icon borders: rename the legacy buff/debuff keys to the canonical
-- ShowBorder / BorderSize so they plug into BuildSpec + CreateBorderControls
-- (Stage 5.5 Phase 2 — full border toolkit for buff/debuff). Same idempotent,
-- leaves-the-legacy-key pattern as MigrateFrameBorderKeys.
function DF:MigrateAuraBorderKeys(modeDb)
    if not modeDb then return end
    for _, p in ipairs({ "buff", "debuff" }) do
        if modeDb[p .. "ShowBorder"] == nil and modeDb[p .. "BorderEnabled"] ~= nil then
            modeDb[p .. "ShowBorder"] = modeDb[p .. "BorderEnabled"]
        end
        if modeDb[p .. "BorderSize"] == nil and modeDb[p .. "BorderThickness"] ~= nil then
            modeDb[p .. "BorderSize"] = modeDb[p .. "BorderThickness"]
        end
    end
    -- Expiring border: the legacy single Pulsate bool becomes the unified
    -- Expiring Animation type (true -> DF Pulsate, false -> None).  Only seed
    -- when an old key exists and the new one hasn't been set yet, so existing
    -- configs keep their pulse and new profiles use their own default.
    if modeDb.buffExpiringBorderAnimationType == nil and modeDb.buffExpiringBorderPulsate ~= nil then
        modeDb.buffExpiringBorderAnimationType = modeDb.buffExpiringBorderPulsate and "DF_PULSATE" or "NONE"
    end
end

-- ============================================================
-- BORDER INSET FOLD / ZERO  (appearance-preserving migration)
--
-- The unified-border rework changed two border families' inset semantics, so
-- older profiles render oddly under the new (correct) offset model. One-time,
-- per-profile guarded; rewrites the stored values to keep the pre-rework look.
--
-- 1) AURA DESIGNER icon/square (_borderInsetFoldV1): old visible band was
--    BorderSize + BorderInset (inset EXTENDED the band, straddling the edge);
--    new = BorderSize alone, inset a pure outward offset (spec.inset =
--    -BorderInset), so a stored inset now floats the band in a gap. Fold the
--    inset back into size (BorderSize += BorderInset, likewise
--    ExpiringBorderSize; BorderInset = 0), clamped to the slider cap. No-op at 0.
--
-- 2) BUFF/DEBUFF icons (_buffDebuffInsetZeroV1): changed the OPPOSITE way — old
--    band = 2*thickness - inset (inset REDUCED width, hugging the edge); new =
--    the same icon-mode model, so the stored inset floats it in a gap. Fix is to
--    ZERO the inset, written EXPLICITLY (the render falls back to the legacy
--    `or 1` when the key is absent, which would keep the gap), and stripped from
--    raid auto-layout overrides so each layout inherits the zeroed base.
--
-- Iterates the raw SavedVariables profiles directly (never the WrapDB proxy).
-- The preset-library walk is nil-guarded, so this is correct with or without
-- the Designer Presets feature present.
-- ============================================================
local AD_BORDER_SIZE_MAX = 5   -- AD border-size slider cap (AuraDesigner/Options.lua)

local function FoldIndicatorBorderInset(ind, seen)
    if type(ind) ~= "table" then return end
    if seen[ind] then return end       -- a materialised inline config and its
    seen[ind] = true                   -- library copy may share this table ref
    local t = ind.type
    if t ~= "icon" and t ~= "square" then return end
    local inset = ind.BorderInset or ind.borderInset
    if not inset or inset == 0 then
        -- Nothing to fold; drop any lingering legacy inset key so a render
        -- fallback can't later resurrect a stale value.
        ind.borderInset = nil
        return
    end
    local function foldSize(v)
        local folded = (v or 1) + inset
        if folded < 0 then folded = 0 end
        if folded > AD_BORDER_SIZE_MAX then folded = AD_BORDER_SIZE_MAX end
        return folded
    end
    ind.BorderSize = foldSize(ind.BorderSize or ind.borderThickness)
    if ind.ExpiringBorderSize then
        ind.ExpiringBorderSize = foldSize(ind.ExpiringBorderSize)
    end
    ind.BorderInset = 0
    -- Clear legacy duplicates so the render fallback can't reintroduce pre-fold
    -- geometry.
    ind.borderThickness = nil
    ind.borderInset = nil
end

local function FoldAuraDesignerConfig(cfg, seen)
    if type(cfg) ~= "table" or type(cfg.auras) ~= "table" then return end
    for _, entry in pairs(cfg.auras) do
        if type(entry) == "table" then
            if entry.indicators then
                -- Flat (V1) shape: auras[auraName] = auraCfg
                for _, ind in ipairs(entry.indicators) do
                    FoldIndicatorBorderInset(ind, seen)
                end
            else
                -- Per-spec shape: auras[spec][auraName] = auraCfg
                for _, auraCfg in pairs(entry) do
                    if type(auraCfg) == "table" and type(auraCfg.indicators) == "table" then
                        for _, ind in ipairs(auraCfg.indicators) do
                            FoldIndicatorBorderInset(ind, seen)
                        end
                    end
                end
            end
        end
    end
end

-- Write 0 EXPLICITLY (don't just leave absent): the render falls back to the
-- legacy `or 1` when the key is missing (Update.lua), which would keep the gap.
local function ZeroBuffDebuffBorderInset(profile)
    for _, modeKey in ipairs({ "party", "raid" }) do
        local mode = profile[modeKey]
        if type(mode) == "table" then
            mode.buffBorderInset = 0
            mode.debuffBorderInset = 0
        end
    end
    -- Raid auto-layout overrides: strip the inset keys so each layout inherits
    -- the now-zeroed base (mirrors CleanupLegacyTextLayoutOverrides' traversal).
    -- Pinned sets don't override buff/debuff keys, so they inherit the base.
    local autoDb = profile.raidAutoProfiles
    if type(autoDb) == "table" then
        local function stripLayout(layout)
            local ov = layout and layout.overrides
            if type(ov) ~= "table" then return end
            ov.buffBorderInset = nil
            ov.debuffBorderInset = nil
        end
        for _, ctKey in ipairs({ "instanced", "openWorld" }) do
            local ct = autoDb[ctKey]
            if type(ct) == "table" and type(ct.profiles) == "table" then
                for _, layout in pairs(ct.profiles) do stripLayout(layout) end
            end
        end
        if type(autoDb.mythic) == "table" then stripLayout(autoDb.mythic.profile) end
    end
end

-- Fold the legacy per-element OOR name-text alpha into the unified oorTextAlpha.
-- The Text Designer now renders all unit text, so a single OOR "Text Alpha" dims
-- every TD element out of range. Carry the user's old name-text value only when
-- they changed it from the prior default (1); default-config users get the new
-- oorTextAlpha default instead. Per-profile guarded so later oorTextAlpha edits stick.
function DF:MigrateOORTextAlpha()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        if type(profile) == "table" and not profile._oorTextAlphaV1 then
            for _, modeKey in ipairs({ "party", "raid" }) do
                local m = profile[modeKey]
                if type(m) == "table" and m.oorNameTextAlpha ~= nil and m.oorNameTextAlpha ~= 1 then
                    m.oorTextAlpha = m.oorNameTextAlpha
                end
            end
            profile._oorTextAlphaV1 = true
        end
    end
end
-- One-shot per-profile, two independently-guarded steps so a profile already
-- through step 1 still receives step 2. Both steps are value-idempotent.
function DF:MigrateBorderInsetFold()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        if type(profile) == "table" then
            -- Step 1: AD icon/square fold (preset libraries + inline configs).
            if not profile._borderInsetFoldV1 then
                local seen = {}
                -- Canonical store when Designer Presets exist (nil-guarded so this
                -- stays correct where they don't).
                local lib = profile.auraDesignerPresets
                if type(lib) == "table" then
                    for _, presetCfg in pairs(lib) do
                        FoldAuraDesignerConfig(presetCfg, seen)
                    end
                end
                if type(profile.party) == "table" then
                    FoldAuraDesignerConfig(profile.party.auraDesigner, seen)
                end
                if type(profile.raid) == "table" then
                    FoldAuraDesignerConfig(profile.raid.auraDesigner, seen)
                end
                profile._borderInsetFoldV1 = true
            end
            -- Step 2: zero buff/debuff border inset (mode-level + raid overrides).
            if not profile._buffDebuffInsetZeroV1 then
                ZeroBuffDebuffBorderInset(profile)
                profile._buffDebuffInsetZeroV1 = true
            end
        end
    end
end

-- One-time cleanup: the legacy raidGroupOrder ("NORMAL"/"REVERSE") toggle is
-- deprecated -- group order now comes solely from the Group Display Order /
-- My Group First feature (raidGroupDisplayOrder), which every positioner honours.
-- The live header path never applied raidGroupOrder, but the test/legacy Lua
-- positioner did, so a stale "REVERSE" made test/legacy disagree with live. The
-- reverse code is gone; NORMAL-ize any lingering value so it can't mislead
-- exports/debug. Per-profile guarded; idempotent. (Re-reverse via Group Display Order.)
function DF:MigrateDeprecateRaidGroupOrder()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        if type(profile) == "table" and not profile._raidGroupOrderRetiredV1 then
            if type(profile.party) == "table" and profile.party.raidGroupOrder == "REVERSE" then
                profile.party.raidGroupOrder = "NORMAL"
            end
            if type(profile.raid) == "table" and profile.raid.raidGroupOrder == "REVERSE" then
                profile.raid.raidGroupOrder = "NORMAL"
            end
            profile._raidGroupOrderRetiredV1 = true
        end
    end
end

-- One-time: carry the old bespoke important-spell highlight settings
-- (targetedSpellHighlightStyle/Color/Size/Inset) into the new Important Spell
-- Border key set (targetedSpellImportantBorder*), which is a second DF.Border
-- gated by the Highlight-Important toggle. Defaults already match the old
-- defaults, so untouched profiles need nothing; this only preserves customised
-- highlights. Per-profile guarded. Style maps onto a DF.Border animation type.
function DF:MigrateTargetedSpellImportantBorder()
    if not DandersFramesDB_v2 or not DandersFramesDB_v2.profiles then return end
    local styleToAnim = { glow = "PROC", marchingAnts = "DF_DASH", pulse = "DF_PULSATE",
                          solidBorder = "NONE", none = "NONE" }
    -- Copy a feature's old <prefix>Highlight* keys into its new
    -- <prefix>ImportantBorder* set. Gated ONLY by the per-profile _…V1 flag in the
    -- caller (so it runs exactly once); do NOT also guard on the new key being nil —
    -- the ADDON_LOADED default-merge fills the new …ImportantBorder* keys before this
    -- runs, so a nil-guard would never fire and the old highlight settings would be
    -- lost. At first run the user can't have set the new keys yet, so overwriting the
    -- just-merged defaults with their old highlight values is exactly the intent.
    -- Mirrors MigrateBorderInsetFold. Shared by the group (targetedSpell) and personal
    -- (personalTargetedSpell) sets.
    local function mapHighlight(m, p)
        if m[p.."HighlightColor"] ~= nil then
            -- Copy into independent tables: the color picker mutates color
            -- tables in place, so sharing one reference would link the static
            -- and animation colors (editing one would change the other).
            local c = m[p.."HighlightColor"]
            m[p.."ImportantBorderColor"] = { r = c.r, g = c.g, b = c.b, a = c.a }
            m[p.."ImportantBorderAnimationColor"] = { r = c.r, g = c.g, b = c.b, a = c.a }
        end
        if m[p.."HighlightSize"] ~= nil then
            m[p.."ImportantBorderSize"] = m[p.."HighlightSize"]
        end
        if m[p.."HighlightInset"] ~= nil then
            m[p.."ImportantBorderInset"] = m[p.."HighlightInset"]
        end
        if m[p.."HighlightStyle"] ~= nil then
            m[p.."ImportantBorderAnimationType"] = styleToAnim[m[p.."HighlightStyle"]] or "PROC"
        end
    end
    for _, profile in pairs(DandersFramesDB_v2.profiles) do
        if type(profile) == "table" then
            -- Group/party Targeted Spells. Guarded independently from personal so a
            -- profile already through this step still receives the personal one.
            if not profile._tsImportantBorderV1 then
                for _, modeKey in ipairs({ "party", "raid" }) do
                    local m = profile[modeKey]
                    if type(m) == "table" then mapHighlight(m, "targetedSpell") end
                end
                profile._tsImportantBorderV1 = true
            end
            -- Personal Targeted Spell.
            if not profile._personalTsImportantBorderV1 then
                for _, modeKey in ipairs({ "party", "raid" }) do
                    local m = profile[modeKey]
                    if type(m) == "table" then mapHighlight(m, "personalTargetedSpell") end
                end
                profile._personalTsImportantBorderV1 = true
            end
        end
    end
end

-- The handler body is stored on DF as _MainEventDispatcher so the profiler
-- can swap it for an instrumented version at runtime. The frame's actual
-- script is a thin trampoline that calls through DF — re-binding takes
-- effect immediately without re-running SetScript.
DF._MainEventDispatcher = function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        -- Initialize saved variables with profile support
        if not DandersFramesDB_v2 then
            DandersFramesDB_v2 = {
                currentProfile = "Default",
                profiles = {
                    ["Default"] = {
                        party = DF:DeepCopy(DF.PartyDefaults),
                        raid = DF:DeepCopy(DF.RaidDefaults),
                    }
                },
                wizardConfigs = {},
                seenAuraSetupWizard = true,  -- New users don't need the wizard
            }
        end
        
        -- Initialize per-character saved variables
        if not DandersFramesCharDB then
            DandersFramesCharDB = {
                enableSpecSwitch = false,
                specProfiles = {},
                currentProfile = nil,  -- seeded from account-wide on first login
            }
        end
        
        -- Migrate from old DandersFramesDB_v2.char to per-character DB (one-time migration)
        if DandersFramesDB_v2.char then
            -- Only migrate if this character hasn't been set up yet
            if not DandersFramesCharDB.enableSpecSwitch and DandersFramesDB_v2.char.enableSpecSwitch then
                DandersFramesCharDB.enableSpecSwitch = DandersFramesDB_v2.char.enableSpecSwitch
            end
            -- Note: We don't migrate specProfiles because the old data was shared
            -- and likely incorrect for this character anyway
        end
        
        -- Ensure structure exists in per-character DB
        if DandersFramesCharDB.specProfiles == nil then DandersFramesCharDB.specProfiles = {} end

        -- ARENA RELOAD FIX: snapshot the saved content-type hint before any
        -- GetContentType call can overwrite it (GetContentType also
        -- self-captures; this pins the earliest possible point), and arm the
        -- fallback NOW on a /reload — the player only already exists at
        -- ADDON_LOADED on a reload (same detection Headers.lua uses for the
        -- combat-safe finalize). PLAYER_ENTERING_WORLD also arms it
        -- (isReloadingUi), but that's too late for the FinalizeHeaderInit →
        -- UpdateHeaderVisibility call that runs inside the ADDON_LOADED
        -- combat-safe window on a combat reload in arena.
        -- Fresh logins must NOT arm it: a stale "arena" hint from a previous
        -- session would misclassify the login zone (the fallback only clears
        -- once real detection returns a definite answer).
        if not DF._contentTypeHintCaptured then
            DF._contentTypeHintCaptured = true
            DF._contentTypeHintAtLoad = DandersFramesCharDB.lastContentType
        end
        if UnitExists("player") then
            DF.useContentTypeFallback = true
        end

        -- Language override lives per-character because the locale files
        -- need to read it at file-load time, before any profile resolution
        -- happens. SavedVariablesPerCharacter is available at that stage.
        if DandersFramesCharDB.languageOverride == nil then
            -- Migrate from the earlier per-profile slot if any profile had it set
            local migrated = "AUTO"
            if DandersFramesDB_v2.profiles then
                for _, profile in pairs(DandersFramesDB_v2.profiles) do
                    if profile.languageOverride and profile.languageOverride ~= "AUTO" then
                        migrated = profile.languageOverride
                        break
                    end
                end
            end
            DandersFramesCharDB.languageOverride = migrated
        end
        -- Clean up legacy per-profile key (no longer read anywhere)
        if DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                profile.languageOverride = nil
            end
        end

        -- Apply language override: the locale files populated
        -- DF_AllLocales[locale] at file-scope; we now overlay the chosen
        -- locale's strings onto AceLocale's app table. Non-enUS client
        -- locales also flow through here (they populate only the side
        -- table, not AceLocale directly, so the app otherwise has just
        -- the enUS baseline).
        if DF_AllLocales then
            local override = DandersFramesCharDB.languageOverride
            local active = (override and override ~= "AUTO") and override or GetLocale()
            if active ~= "enUS" and DF_AllLocales[active] then
                local aceL = DF.L
                for k, v in pairs(DF_AllLocales[active]) do
                    -- AceLocale stores L["key"] = true as L["key"] = "key"
                    -- (the key string); we preserve that convention for
                    -- any `true` values in DF_AllLocales, though real
                    -- translations are already strings.
                    rawset(aceL, k, v == true and k or v)
                end
            end
            -- Free the side-table now that the overlay is applied. Changing
            -- languageOverride requires a /reload (enforced by the dropdown
            -- popup), which re-populates DF_AllLocales on the next load, so
            -- we don't need to keep it around for subsequent lookups.
            DF_AllLocales = nil
        end

        -- Rebuild any file-scope label tables now that the locale
        -- overlay has been applied (see DF:RegisterLocaleRefresh above).
        DF:RunLocaleRefreshers()

        -- Seed per-character profile from account-wide on first login for this character
        if not DandersFramesCharDB.currentProfile then
            DandersFramesCharDB.currentProfile = DandersFramesDB_v2.currentProfile
        end

        -- Migrate from old format (profile.party/raid) to new format (profiles)
        if DandersFramesDB_v2.profile and not DandersFramesDB_v2.profiles then
            DandersFramesDB_v2.profiles = {
                ["Default"] = DandersFramesDB_v2.profile
            }
            DandersFramesDB_v2.currentProfile = "Default"
            DandersFramesDB_v2.profile = nil  -- Remove old format
        end
        
        -- Ensure structure exists
        if not DandersFramesDB_v2.profiles then DandersFramesDB_v2.profiles = {} end
        if not DandersFramesDB_v2.currentProfile then DandersFramesDB_v2.currentProfile = "Default" end
        if not DandersFramesDB_v2.wizardConfigs then DandersFramesDB_v2.wizardConfigs = {} end
        if not DandersFramesDB_v2.global then DandersFramesDB_v2.global = {} end

        -- Track last seen version for auto-showing changelog on update
        if not DandersFramesDB_v2.lastSeenVersion then
            DandersFramesDB_v2.lastSeenVersion = DF.VERSION
        end
        if not DandersFramesDB_v2.profiles["Default"] then
            DandersFramesDB_v2.profiles["Default"] = {
                party = DF:DeepCopy(DF.PartyDefaults),
                raid = DF:DeepCopy(DF.RaidDefaults),
                raidAutoProfiles = DF:DeepCopy(DF.RaidAutoProfilesDefaults),
                classColors = {},
                powerColors = {},
                linkedSections = {},
                partyEnabled = true,
                raidEnabled = true,
                settingsFont = "Friz Quadrata TT",
                settingsFontOutline = "NONE",
            }
        end
        
        -- Set current profile (per-character takes priority over account-wide)
        local currentProfile = DandersFramesCharDB.currentProfile or DandersFramesDB_v2.currentProfile
        if not DandersFramesDB_v2.profiles[currentProfile] then
            currentProfile = "Default"
        end
        -- Keep both in sync
        DandersFramesCharDB.currentProfile = currentProfile
        DandersFramesDB_v2.currentProfile = currentProfile

        DF.db = DandersFramesDB_v2.profiles[currentProfile]
        
        -- Ensure both modes exist in current profile
        if not DF.db.party then DF.db.party = DF:DeepCopy(DF.PartyDefaults) end
        if not DF.db.raid then DF.db.raid = DF:DeepCopy(DF.RaidDefaults) end
        
        -- Ensure raidAutoProfiles exists in current profile
        if not DF.db.raidAutoProfiles then
            DF.db.raidAutoProfiles = DF:DeepCopy(DF.RaidAutoProfilesDefaults)
        end

        -- Migrate legacy Frame Border keys (borderSize / showFrameBorder /
        -- borderColor / borderStyle / borderTexture / borderClassColor /
        -- frameBorderUseClassColor / frameBorderUseRoleColor) to the canonical
        -- `frame*Border*` naming + new frameBorderColorSource segmented key.
        -- One-shot copy per mode: if a new key already exists we leave it
        -- (user has already saved with the new key); otherwise we adopt the
        -- old value.
        if DF.MigrateFrameBorderKeys then
            DF:MigrateFrameBorderKeys(DF.db.party)
            DF:MigrateFrameBorderKeys(DF.db.raid)
        end
        -- Resource Bar: resourceBarBorderEnabled → resourceBarShowBorder
        -- (Stage 4.2 wire-up to the unified DF.Border helper).
        if DF.MigrateResourceBarBorderKeys then
            DF:MigrateResourceBarBorderKeys(DF.db.party)
            DF:MigrateResourceBarBorderKeys(DF.db.raid)
        end
        -- Resource Bar: resourceBarClassColor (bool) → resourceBarColorMode (tri-state).
        if DF.MigrateResourceBarColorMode then
            DF:MigrateResourceBarColorMode(DF.db.party)
            DF:MigrateResourceBarColorMode(DF.db.raid)
        end
        -- Pinned frames decouple: strip stale pinned.N.<setting> auto-layout
        -- overrides (everything except the per-set `enabled` flag).
        if DF.MigratePinnedLayoutOverrides then
            DF:MigratePinnedLayoutOverrides()
        end
        -- Pinned frames: seed matchMode (each set's own mode) on existing sets so
        -- the Match baseline dropdown shows a value (nil already resolves to it).
        if DF.MigratePinnedMatchMode then
            DF:MigratePinnedMatchMode()
        end
        -- Aura icons: buff/debuffBorderEnabled → ShowBorder, BorderThickness →
        -- BorderSize (Stage 5.5 Phase 2 — full toolkit for buff/debuff borders).
        if DF.MigrateAuraBorderKeys then
            DF:MigrateAuraBorderKeys(DF.db.party)
            DF:MigrateAuraBorderKeys(DF.db.raid)
        end
        -- Promote role border colours from per-mode storage to profile-level
        -- DF.db.roleColors so the global Colors settings page manages them.
        if DF.MigrateRoleBorderColors then
            DF:MigrateRoleBorderColors()
        end
        
        -- Ensure classColors table exists (shared across party/raid)
        if not DF.db.classColors then
            DF.db.classColors = {}
        end
        
        -- Ensure powerColors table exists (shared across party/raid)
        if not DF.db.powerColors then
            DF.db.powerColors = {}
        end

        -- Ensure linkedSections table exists (shared across party/raid)
        if not DF.db.linkedSections then
            DF.db.linkedSections = {}
        end

        -- Ensure mode-enable flags exist (default true for backward compatibility)
        if DF.db.partyEnabled == nil then DF.db.partyEnabled = true end
        if DF.db.raidEnabled == nil then DF.db.raidEnabled = true end

        -- Ensure settings-panel font defaults exist
        if DF.db.settingsFont        == nil then DF.db.settingsFont        = "Friz Quadrata TT" end
        -- Outline "None" is stored canonically as "NONE" everywhere; normalise the
        -- legacy empty-string the old hand-rolled settings dropdown wrote.
        if DF.db.settingsFontOutline == nil or DF.db.settingsFontOutline == "" then DF.db.settingsFontOutline = "NONE" end

        -- Ensure top-level font preferences exist (SDF rendering toggle from PR #115)
        if DF.db.fontSlug == nil then DF.db.fontSlug = false end

        -- Snapshot the enable-flag state at load time. After profile switches
        -- or imports, we compare against this to decide whether to prompt for
        -- a UI reload. The actual headers are created based on this state and
        -- can only be (un)created on /reload.
        DF.loadedPartyEnabled = DF.db.partyEnabled ~= false
        DF.loadedRaidEnabled  = DF.db.raidEnabled  ~= false

        -- Apply user's Settings Panel font (safe no-op if GUI/DFFonts.lua hasn't loaded yet;
        -- SetupGUIPages also calls this again after the GUI frame exists)
        if DF.GUI and DF.GUI.ApplySettingsFont then
            DF.GUI:ApplySettingsFont()
        end

        -- Ensure auraBlacklist table exists (profile-level, shared across party/raid)
        if not DF.db.auraBlacklist then
            DF.db.auraBlacklist = { buffs = {}, debuffs = {} }
        end
        if not DF.db.auraBlacklist.buffs then DF.db.auraBlacklist.buffs = {} end
        if not DF.db.auraBlacklist.debuffs then DF.db.auraBlacklist.debuffs = {} end

        -- Migrate legacy blacklist entries: true → { combat = true, ooc = true }
        for _, key in ipairs({"buffs", "debuffs"}) do
            for spellId, val in pairs(DF.db.auraBlacklist[key]) do
                if val == true then
                    DF.db.auraBlacklist[key][spellId] = { combat = true, ooc = true }
                end
            end
        end

        -- Migrate any missing settings from defaults (all profiles)
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                if profile.party then
                    for key, value in pairs(DF.PartyDefaults) do
                        if profile.party[key] == nil then
                            profile.party[key] = DF:DeepCopy(value)
                        end
                    end
                end
                if profile.raid then
                    for key, value in pairs(DF.RaidDefaults) do
                        if profile.raid[key] == nil then
                            profile.raid[key] = DF:DeepCopy(value)
                        end
                    end
                end
                -- Ensure mode-enable flags exist on every profile
                if profile.partyEnabled == nil then profile.partyEnabled = true end
                if profile.raidEnabled == nil then profile.raidEnabled = true end

                -- Ensure settings-panel font defaults exist on every profile
                if profile.settingsFont        == nil then profile.settingsFont        = "Friz Quadrata TT" end
                if profile.settingsFontOutline == nil or profile.settingsFontOutline == "" then profile.settingsFontOutline = "NONE" end

                -- Backfill missing auraDesigner.defaults keys.
                -- The top-level migration (pairs(PartyDefaults) above) skips auraDesigner
                -- when the subtable already exists, leaving new nested keys un-migrated.
                for _, mode in ipairs({ "party", "raid" }) do
                    local ad = profile[mode] and profile[mode].auraDesigner
                    if ad then
                        if not ad.defaults then ad.defaults = {} end
                        if ad.defaults.indicatorFrameStrata == nil then
                            ad.defaults.indicatorFrameStrata = "INHERIT"
                        end
                        if ad.defaults.indicatorFrameLevel == nil then
                            ad.defaults.indicatorFrameLevel = 30
                        end
                    end
                end
            end
        end

        -- Force-disable deprecated My Buff Indicator for all profiles
        DF.db.party.myBuffIndicatorEnabled = false
        DF.db.raid.myBuffIndicatorEnabled = false
        
        -- Migrate any missing settings for raidAutoProfiles
        for key, value in pairs(DF.RaidAutoProfilesDefaults) do
            if DF.db.raidAutoProfiles[key] == nil then
                DF.db.raidAutoProfiles[key] = DF:DeepCopy(value)
            end
        end
        
        -- Migrate external defensive icon settings to new defensive icon
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb.externalDefEnabled and not modeDb._defensiveIconMigrated then
                -- Enable the new defensive icon if the old external def was enabled
                modeDb.defensiveIconEnabled = true
                -- Migrate old settings to new ones
                if modeDb.externalDefScale then modeDb.defensiveIconScale = modeDb.externalDefScale end
                if modeDb.externalDefAnchor then modeDb.defensiveIconAnchor = modeDb.externalDefAnchor end
                if modeDb.externalDefX then modeDb.defensiveIconX = modeDb.externalDefX end
                if modeDb.externalDefY then modeDb.defensiveIconY = modeDb.externalDefY end
                if modeDb.externalDefBorderColor then modeDb.defensiveIconBorderColor = modeDb.externalDefBorderColor end
                if modeDb.externalDefBorderSize then modeDb.defensiveIconBorderSize = modeDb.externalDefBorderSize end
                if modeDb.externalDefShowDuration ~= nil then modeDb.defensiveIconShowDuration = modeDb.externalDefShowDuration end
                if modeDb.externalDefFrameLevel then modeDb.defensiveIconFrameLevel = modeDb.externalDefFrameLevel end
                modeDb._defensiveIconMigrated = true
            end
        end
        
        -- Force Direct mode filter defaults (v4.0.9):
        -- Debuffs: All Debuffs enabled (show everything)
        -- Buffs: All Buffs disabled, My Buffs + Raid In Combat checked
        -- One-time forced reset using a migration flag
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb and not modeDb._directFilterDefaultsV409 then
                modeDb.directDebuffShowAll = true
                modeDb.directBuffShowAll = false
                modeDb.directBuffFilterPlayer = true
                modeDb.directBuffFilterRaidInCombat = true
                modeDb._directFilterDefaultsV409 = true
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] and not profile[mode]._directFilterDefaultsV409 then
                        profile[mode].directDebuffShowAll = true
                        profile[mode].directBuffShowAll = false
                        profile[mode].directBuffFilterPlayer = true
                        profile[mode].directBuffFilterRaidInCombat = true
                        profile[mode]._directFilterDefaultsV409 = true
                    end
                end
            end
        end

        -- Migrate the single border dropdown to the Style + Texture split.
        -- Previously borderTexture held either "SOLID" (the built-in border) or an
        -- LSM key. A non-SOLID key means the user had a texture selected, so flip
        -- borderStyle to TEXTURE. One-time so picking Solid later isn't reverted.
        local function migrateBorderStyle(modeDb)
            if modeDb and not modeDb._borderStyleMigrated then
                local tex = modeDb.borderTexture
                if tex and tex ~= "SOLID" and tex ~= "" then
                    modeDb.borderStyle = "TEXTURE"
                end
                modeDb._borderStyleMigrated = true
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            migrateBorderStyle(DF.db[mode])
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    migrateBorderStyle(profile[mode])
                end
            end
        end

        -- Recolour the Reduced Max Health bar off solid black.
        -- The old shipped default was opaque black {0,0,0,1}, which reads as empty
        -- space on a dark bar. Flip any profile still on one of our prior defaults
        -- — that black, OR the short-lived in-development grey #757575CB — to the
        -- new #808080CD (50% grey @ ~80% alpha). One-time per mode (flag) so a
        -- later deliberate colour choice isn't reverted; non-matching (customised)
        -- colours are left alone. (The #757575CB branch only matters to in-dev
        -- testers; no released build ever shipped that value.)
        local function recolorReducedMaxHealth(modeDb)
            if modeDb and not modeDb._reducedMaxHealthRecolorV2 then
                local c = modeDb.reducedMaxHealthColor
                local isOldBlack = c and c.r == 0 and c.g == 0 and c.b == 0 and c.a == 1
                local isDevGrey  = c and c.r == 0.4588 and c.g == 0.4588 and c.b == 0.4588 and c.a == 0.7961
                if isOldBlack or isDevGrey then
                    modeDb.reducedMaxHealthColor = { r = 0.502, g = 0.502, b = 0.502, a = 0.8039 }
                end
                modeDb._reducedMaxHealthRecolorV2 = true
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            recolorReducedMaxHealth(DF.db[mode])
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    recolorReducedMaxHealth(profile[mode])
                end
            end
        end

        -- The split test-mode toggles "Status / Ready" (testShowStatusIcons) and
        -- "Role / Leader" (testShowIcons) merged into one "Icons" toggle keyed on
        -- testShowStatusIcons (now default on). Flip existing profiles that were on
        -- the old default (status off) to on once, so role/leader icons don't vanish
        -- in test mode. One-time per mode (flag); a later deliberate off isn't reverted.
        local function mergeIconsToggle(modeDb)
            if modeDb and not modeDb._iconsToggleMergeV1 then
                if modeDb.testShowStatusIcons == false then
                    modeDb.testShowStatusIcons = true
                end
                modeDb._iconsToggleMergeV1 = true
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            mergeIconsToggle(DF.db[mode])
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    mergeIconsToggle(profile[mode])
                end
            end
        end

        -- Migrate the legacy `groupLabelShadow` (duplicate-fontstring shadow) into
        -- the new composite outline encoding from PR #115. If the user previously
        -- had the legacy shadow on, prepend "SHADOW;" to groupLabelOutline so they
        -- keep a shadow (now via SetShadowOffset on the primary fontstring).
        local function migrateGroupLabelShadow(modeDb)
            if modeDb and modeDb.groupLabelShadow ~= nil then
                if modeDb.groupLabelShadow == true then
                    local outline = modeDb.groupLabelOutline or ""
                    if not outline:find("^SHADOW") then
                        modeDb.groupLabelOutline = "SHADOW;" .. outline
                    end
                end
                modeDb.groupLabelShadow = nil
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            migrateGroupLabelShadow(DF.db[mode])
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    migrateGroupLabelShadow(profile[mode])
                end
            end
        end

        -- Force updated Direct mode filter defaults (v4.0.9b):
        -- Buffs: Raid In Combat + Big Defensive + External Defensive (no Player)
        -- Debuffs: Show All off, Raid + Crowd Control on
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb and not modeDb._directFilterDefaultsV2 then
                modeDb.directBuffShowAll = false
                modeDb.directBuffFilterPlayer = false
                modeDb.directBuffFilterRaidInCombat = true
                modeDb.directBuffFilterBigDefensive = true
                modeDb.directBuffFilterExternalDefensive = true
                modeDb.directDebuffShowAll = false
                modeDb.directDebuffFilterRaid = true
                modeDb.directDebuffFilterCrowdControl = true
                modeDb._directFilterDefaultsV2 = true
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] and not profile[mode]._directFilterDefaultsV2 then
                        profile[mode].directBuffShowAll = false
                        profile[mode].directBuffFilterPlayer = false
                        profile[mode].directBuffFilterRaidInCombat = true
                        profile[mode].directBuffFilterBigDefensive = true
                        profile[mode].directBuffFilterExternalDefensive = true
                        profile[mode].directDebuffShowAll = false
                        profile[mode].directDebuffFilterRaid = true
                        profile[mode].directDebuffFilterCrowdControl = true
                        profile[mode]._directFilterDefaultsV2 = true
                    end
                end
            end
        end

        -- Migrate texture paths from old format to new Media folder format (v3.2.0)
        local function MigrateTexturePath(path)
            if type(path) ~= "string" then return path end
            -- Check if it's an old DandersFrames texture path without Media
            if path:find("AddOns\\DandersFrames\\DF_") or path:find("AddOns/DandersFrames/DF_") then
                -- Insert Media folder into the path
                path = path:gsub("DandersFrames\\DF_", "DandersFrames\\Media\\DF_")
                path = path:gsub("DandersFrames/DF_", "DandersFrames/Media/DF_")
            end
            return path
        end
        
        -- List of texture settings that need migration
        local textureSettings = {
            "healthBarTexture", "healthTexture", "backgroundTexture", 
            "absorbBarTexture", "healAbsorbBarTexture", "healPredictionTexture", 
            "powerBarTexture", "powerBarBackgroundTexture", "petTexture"
        }
        
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb then
                for _, setting in ipairs(textureSettings) do
                    if modeDb[setting] then
                        modeDb[setting] = MigrateTexturePath(modeDb[setting])
                    end
                end
            end
        end
        
        -- Also migrate any profile that might have old paths
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    local modeDb = profile[mode]
                    if modeDb then
                        for _, setting in ipairs(textureSettings) do
                            if modeDb[setting] then
                                modeDb[setting] = MigrateTexturePath(modeDb[setting])
                            end
                        end
                    end
                end
            end
        end
        
        -- Note: Texture validation removed - SharedMedia textures are validated by LSM
        -- If a texture doesn't exist, WoW will display a fallback texture automatically
        
        -- Migrate BLIZZARD background color mode to CUSTOM with black color (v3.2.x)
        -- The "Black" option has been removed - we now just use CUSTOM with black as default
        local function MigrateBlizzardBackground(modeDb)
            if modeDb and modeDb.backgroundColorMode == "BLIZZARD" then
                modeDb.backgroundColorMode = "CUSTOM"
                modeDb.backgroundColor = {r = 0, g = 0, b = 0, a = 1}
            end
        end
        
        -- Migrate current profile
        MigrateBlizzardBackground(DF.db.party)
        MigrateBlizzardBackground(DF.db.raid)
        
        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateBlizzardBackground(profile.party)
                MigrateBlizzardBackground(profile.raid)
            end
        end
        
        -- Migrate raidReverseGroupOrder (boolean) to raidGroupOrder (dropdown) (v3.2.x)
        local function MigrateGroupOrder(modeDb)
            if modeDb and modeDb.raidReverseGroupOrder ~= nil then
                modeDb.raidGroupOrder = modeDb.raidReverseGroupOrder and "REVERSE" or "NORMAL"
                modeDb.raidReverseGroupOrder = nil
            end
        end
        
        -- Migrate current profile
        MigrateGroupOrder(DF.db.raid)
        
        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateGroupOrder(profile.raid)
            end
        end
        
        -- Migrate old groupLabelAnchor/groupLabelRelativeAnchor to new groupLabelPosition (v3.2.x)
        local function MigrateGroupLabelPosition(modeDb)
            if modeDb and (modeDb.groupLabelAnchor ~= nil or modeDb.groupLabelRelativeAnchor ~= nil) then
                -- Convert old anchor system to new position system
                -- Old system had separate label anchor and relative anchor
                -- New system uses START/CENTER/END based on layout direction
                -- Default to START for migration (most common use case was label above/left of group)
                if not modeDb.groupLabelPosition then
                    modeDb.groupLabelPosition = "START"
                end
                -- Clean up old settings
                modeDb.groupLabelAnchor = nil
                modeDb.groupLabelRelativeAnchor = nil
            end
        end
        
        -- Migrate current profile
        MigrateGroupLabelPosition(DF.db.raid)
        
        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateGroupLabelPosition(profile.raid)
            end
        end
        
        -- Migrate sortAlphabetical from boolean to dropdown value (v3.3.x)
        -- Old format: true/false (boolean)
        -- New format: false (off), "AZ" (A→Z), "ZA" (Z→A)
        -- Users with old boolean true get reset to false since we can't know their preference
        local function MigrateSortAlphabetical(modeDb)
            if modeDb and type(modeDb.sortAlphabetical) == "boolean" then
                modeDb.sortAlphabetical = false
            end
        end
        
        -- Migrate current profile
        MigrateSortAlphabetical(DF.db.party)
        MigrateSortAlphabetical(DF.db.raid)
        
        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateSortAlphabetical(profile.party)
                MigrateSortAlphabetical(profile.raid)
            end
        end
        
        -- Migrate resourceBarHealerOnly to per-role settings (v4.1.x)
        -- Old format: resourceBarHealerOnly = true/false
        -- New format: resourceBarShowHealer, resourceBarShowTank, resourceBarShowDPS
        local function MigrateResourceBarRoleFilter(modeDb)
            if modeDb and modeDb.resourceBarHealerOnly ~= nil then
                if modeDb.resourceBarHealerOnly then
                    modeDb.resourceBarShowHealer = true
                    modeDb.resourceBarShowTank = false
                    modeDb.resourceBarShowDPS = false
                else
                    modeDb.resourceBarShowHealer = true
                    modeDb.resourceBarShowTank = true
                    modeDb.resourceBarShowDPS = true
                end
                modeDb.resourceBarHealerOnly = nil
            end
        end

        -- Migrate current profile
        MigrateResourceBarRoleFilter(DF.db.party)
        MigrateResourceBarRoleFilter(DF.db.raid)

        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateResourceBarRoleFilter(profile.party)
                MigrateResourceBarRoleFilter(profile.raid)
            end
        end

        -- Migrate Aura Designer from type-keyed to instance-based format (v4.1.x)
        -- Old format: auraCfg.icon = { anchor = ..., size = ... }
        -- New format: auraCfg.indicators = { { id = 1, type = "icon", anchor = ..., size = ... } }
        local AD_PLACED_TYPE_KEYS = { "icon", "square", "bar" }

        -- Inner migration: converts a flat auras table from type-keyed to instance-based
        local function MigrateAuraConfigs(aurasTable)
            for auraName, auraCfg in pairs(aurasTable) do
                if type(auraCfg) == "table" and not auraCfg.indicators then
                    -- Only migrate if it has old-style placed type keys
                    local hasOldKeys = false
                    for _, typeKey in ipairs(AD_PLACED_TYPE_KEYS) do
                        if auraCfg[typeKey] then hasOldKeys = true; break end
                    end
                    if hasOldKeys then
                        local indicators = {}
                        local nextID = 1
                        for _, typeKey in ipairs(AD_PLACED_TYPE_KEYS) do
                            if auraCfg[typeKey] then
                                local instance = DF:DeepCopy(auraCfg[typeKey])
                                instance.id = nextID
                                instance.type = typeKey
                                indicators[#indicators + 1] = instance
                                nextID = nextID + 1
                                auraCfg[typeKey] = nil
                            end
                        end
                        if #indicators > 0 then
                            auraCfg.indicators = indicators
                        end
                        auraCfg.nextIndicatorID = nextID
                    end
                end
            end
        end

        local function MigrateAuraDesignerToInstances(modeDb)
            local adDB = modeDb and modeDb.auraDesigner
            if not adDB or not adDB.auras then return end

            -- Detect format: check first entry to see if it's flat aura configs or spec-scoped
            for key, val in pairs(adDB.auras) do
                if type(val) == "table" then
                    if val.priority ~= nil or val.indicators ~= nil or val.border ~= nil then
                        -- Flat format (pre-spec-scoping): migrate directly
                        MigrateAuraConfigs(adDB.auras)
                    else
                        -- Spec-scoped format: iterate each spec's auras
                        for specKey, specAuras in pairs(adDB.auras) do
                            if type(specAuras) == "table" then
                                MigrateAuraConfigs(specAuras)
                            end
                        end
                    end
                end
                break  -- Only check first entry
            end
        end

        -- Expose for use after profile imports
        DF.MigrateAuraDesignerToInstances = MigrateAuraDesignerToInstances

        -- Migrate current profile
        MigrateAuraDesignerToInstances(DF.db.party)
        MigrateAuraDesignerToInstances(DF.db.raid)

        -- Migrate all profiles
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                MigrateAuraDesignerToInstances(profile.party)
                MigrateAuraDesignerToInstances(profile.raid)
            end
        end

        -- Stage 5.1b: rename per-aura icon border keys to canonical
        -- ShowBorder / BorderSize / BorderInset.  Idempotent; safe to
        -- run on already-migrated configs.  Defined in
        -- AuraDesigner/Options.lua; load order guarantees that file
        -- has registered DF.MigrateAuraDesignerIconBorderKeys by here.
        if DF.MigrateAuraDesignerIconBorderKeys then
            DF.MigrateAuraDesignerIconBorderKeys(DF.db.party)
            DF.MigrateAuraDesignerIconBorderKeys(DF.db.raid)
            -- Designer Presets relocated AD configs onto the profile root; walk
            -- those too (the mode-DB calls above miss preset-nested border blocks,
            -- which left imported legacy borders rendering via the old `style` path).
            if DF.MigrateAuraDesignerPresetBorderKeys then
                DF.MigrateAuraDesignerPresetBorderKeys(DF.db)
            end
            if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
                for _, profile in pairs(DandersFramesDB_v2.profiles) do
                    DF.MigrateAuraDesignerIconBorderKeys(profile.party)
                    DF.MigrateAuraDesignerIconBorderKeys(profile.raid)
                    if DF.MigrateAuraDesignerPresetBorderKeys then
                        DF.MigrateAuraDesignerPresetBorderKeys(profile)
                    end
                end
            end
        end

        -- Force auraSourceMode to DIRECT for all existing profiles (v4.2.x)
        -- One-time migration: sets flag so the popup only shows once.
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] and not profile[mode]._auraSourceModeDirectForced then
                        profile[mode].auraSourceMode = "DIRECT"
                        profile[mode]._auraSourceModeDirectForced = true
                    end
                end
            end
        end

        -- Unconditional safety net: force DIRECT on every login for all
        -- profiles. Catches edge cases where BLIZZARD mode slips back in
        -- via profile import, saved variable edits, or unknown code paths.
        -- Runs after the flagged migration above so the popup still fires
        -- on first encounter.
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] and profile[mode].auraSourceMode ~= "DIRECT" then
                        profile[mode].auraSourceMode = "DIRECT"
                    end
                end
            end
        end

        -- Reset seenTabs so "New" badges show for 4.3.0 features (one-time)
        if DandersFramesDB_v2 and not DandersFramesDB_v2._seenTabsReset_430 then
            DandersFramesDB_v2.seenTabs = nil
            DandersFramesDB_v2._seenTabsReset_430 = true
        end

        -- Migrate dispellable filter from two booleans to single mode string (v4.3.x)
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for profileName, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    local modeDb = profile[mode]
                    if modeDb and modeDb.directDebuffDispellableMode == nil then
                        if modeDb.directDebuffFilterAllDispellable == true then
                            modeDb.directDebuffDispellableMode = "ALL"
                        else
                            modeDb.directDebuffDispellableMode = "PLAYER"
                        end
                        modeDb.directDebuffFilterRaidPlayerDispellable = nil
                        modeDb.directDebuffFilterAllDispellable = nil
                    end
                end
            end
        end

        -- Recover from crash/disconnect during auto layout editing.
        -- If the recovery flag exists, the previous session was editing an auto layout
        -- when it crashed — _realRaidDB may still contain override values baked in.
        -- Compare each key against the profile's overrides and reset contaminated ones.
        if DF.db.raidAutoEditingRecovery then
            local recovery = DF.db.raidAutoEditingRecovery
            local autoDb = DF.db.raidAutoProfiles
            local profile
            if recovery.contentType == "mythic" then
                profile = autoDb and autoDb.mythic and autoDb.mythic.profile
            else
                local ct = autoDb and autoDb[recovery.contentType]
                profile = ct and ct.profiles and ct.profiles[recovery.profileIndex]
            end
            if profile and profile.overrides and recovery.snapshotKeys then
                local recovered = 0
                for _, key in ipairs(recovery.snapshotKeys) do
                    local overrideVal = profile.overrides[key]
                    if overrideVal ~= nil and DeepEquals(DF.db.raid[key], overrideVal) then
                        -- This value matches the override — reset to default
                        local default = DF.RaidDefaults[key]
                        if default ~= nil then
                            if type(default) == "table" then
                                DF.db.raid[key] = DF:DeepCopy(default)
                            else
                                DF.db.raid[key] = default
                            end
                            recovered = recovered + 1
                        end
                    end
                end
                if recovered > 0 then
                    print("|cff00ff00DandersFrames:|r " .. format(L["Recovered %d raid settings from interrupted auto layout editing session."], recovered))
                end
            end
            DF.db.raidAutoEditingRecovery = nil
        end

        -- Clean up Aura Designer entries for spells removed in the HARF→native transition.
        -- These spells remain secret and can no longer be tracked without HARF.
        local removedAuras = {
            "TimeDilation", "Rewind", "VerdantEmbrace",
            "IronBark", "PainSuppression", "PowerInfusion", "GuardianSpirit",
            "LifeCocoon", "StrengthOfTheBlackOx",
            "BlessingOfProtection", "HolyBulwark", "SacredWeapon",
            "BlessingOfSacrifice",
        }
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    local ad = profile[mode] and profile[mode].auraDesigner
                    if ad and ad.auras then
                        for _, auraName in ipairs(removedAuras) do
                            ad.auras[auraName] = nil
                        end
                    end
                end
            end
        end

        -- One-time: force hideBlizzardRaidFrames = true for existing users
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb and not modeDb._hideBlizzRaidV407 then
                modeDb.hideBlizzardRaidFrames = true
                modeDb._hideBlizzRaidV407 = true
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] and not profile[mode]._hideBlizzRaidV407 then
                        profile[mode].hideBlizzardRaidFrames = true
                        profile[mode]._hideBlizzRaidV407 = true
                    end
                end
            end
        end

        -- v4.3.4: Dispel Overlay Source migration
        -- Collapses the two legacy toggles (dispelOverlayEnabled +
        -- bossDebuffsContainerOverlayEnabled) into a single dispelOverlaySource
        -- selector with values "off" / "dandersframes" / "blizzard" / "both".
        -- Also unifies the dispel-type dropdown — _blizzDispelIndicator (party-only,
        -- 1=All, 2=ByMe) and bossDebuffsContainerOverlayDispelMode (per-mode,
        -- 1=ByMe, 2=All) are replaced by dispelOverlayDispelType (per-mode,
        -- Blizzard convention: 1=ByMe, 2=All).
        local function ComputeDispelSource(modeDb)
            -- Fresh installs have no legacy keys (removed from defaults in
            -- v4.3.4). If both are nil there's no legacy state to migrate —
            -- return nil so the default ("both") is preserved.
            if modeDb.dispelOverlayEnabled == nil and modeDb.bossDebuffsContainerOverlayEnabled == nil then
                return nil
            end
            local dfOn = modeDb.dispelOverlayEnabled and true or false
            local blizOn = modeDb.bossDebuffsContainerOverlayEnabled and true or false
            if dfOn and blizOn then return "both"
            elseif dfOn then return "dandersframes"
            elseif blizOn then return "blizzard"
            else return "off" end
        end
        local function MigrateDispelSource(modeDb, partyDb)
            if modeDb._dispelSourceMigratedV434 then return end
            local src = ComputeDispelSource(modeDb)
            if src then modeDb.dispelOverlaySource = src end
            -- Translate legacy _blizzDispelIndicator (1=All, 2=ByMe) to the new
            -- Blizzard convention (1=ByMe, 2=All). Reads from party DB since the
            -- legacy key was party-only. If unset, leave the default untouched.
            local legacyInd = partyDb and partyDb._blizzDispelIndicator
            if legacyInd ~= nil then
                modeDb.dispelOverlayDispelType = (legacyInd == 2) and 1 or 2
            end
            modeDb._dispelSourceMigratedV434 = true
        end
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb then
                MigrateDispelSource(modeDb, DF.db.party)
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                local partyDb = profile.party
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] then
                        MigrateDispelSource(profile[mode], partyDb)
                    end
                end
            end
        end

        -- AFK text colour: the AFK text was previously hardcoded orange and
        -- afkIconTextColor (its colour picker) was ignored. The picker is now
        -- live; convert profiles still on the old peachy default to the orange
        -- the text actually showed, so there's no visible change.
        local function MigrateAFKTextColor(modeDb)
            local c = modeDb and modeDb.afkIconTextColor
            if type(c) == "table"
               and math.abs((c.g or 0) - 0.7725490927696228) < 0.0001
               and math.abs((c.b or 0) - 0.5411764979362488) < 0.0001 then
                modeDb.afkIconTextColor = { r = 1, g = 0.5, b = 0, a = 1 }
            end
        end
        for _, mode in ipairs({"party", "raid"}) do
            MigrateAFKTextColor(DF.db[mode])
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    MigrateAFKTextColor(profile[mode])
                end
            end
        end

        -- AFK timer font: an earlier build force-stamped the monospace timer font
        -- onto every profile to stop the countdown wobble. The wobble is actually
        -- fixed by LEFT-justifying the timer (see ApplyTimerTextSettings) — the
        -- mono font is no longer needed or defaulted. Clear that stamp ONCE so the
        -- timer goes back to inheriting the global font; guard with a flag so a
        -- deliberate mono choice made later is not wiped on the next reload.
        if DandersFramesDB_v2 and not DandersFramesDB_v2.afkTimerMonoUnstamped then
            local function UnstampAFKTimerFont(modeDb)
                if modeDb and modeDb.afkIconTimerFont == "DF Roboto Mono SemiBold" then
                    modeDb.afkIconTimerFont = nil
                end
            end
            for _, mode in ipairs({"party", "raid"}) do
                UnstampAFKTimerFont(DF.db[mode])
            end
            if DandersFramesDB_v2.profiles then
                for _, profile in pairs(DandersFramesDB_v2.profiles) do
                    for _, mode in ipairs({"party", "raid"}) do
                        UnstampAFKTimerFont(profile[mode])
                    end
                end
            end
            DandersFramesDB_v2.afkTimerMonoUnstamped = true
        end

        -- v4.3.4: One-time forced upgrade of "dandersframes" mode users to
        -- "both" (Hybrid). Hybrid covers boss debuffs via Blizzard's
        -- container overlay, which DandersFrames-only mode misses entirely.
        -- Runs once per profile/mode; users can switch back afterwards.
        local function MigrateDandersToHybrid(modeDb)
            if modeDb._dandersToHybridV434 then return end
            if modeDb.dispelOverlaySource == "dandersframes" then
                modeDb.dispelOverlaySource = "both"
            end
            modeDb._dandersToHybridV434 = true
        end
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb then
                MigrateDandersToHybrid(modeDb)
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] then
                        MigrateDandersToHybrid(profile[mode])
                    end
                end
            end
        end

        -- Collapse separate bossDebuffsIconWidth + bossDebuffsIconHeight into
        -- a single bossDebuffsIconSize. The icon was already always rendered
        -- as a square at max(width, height) since the iconInfo refactor, so
        -- migrating to max() is the value-preserving choice. Old W/H keys
        -- are dropped from the saved profile to keep it tidy.
        local function MigrateIconSize(modeDb)
            if modeDb._paIconSizeMigrated then return end
            if modeDb.bossDebuffsIconWidth or modeDb.bossDebuffsIconHeight then
                local w = modeDb.bossDebuffsIconWidth or 20
                local h = modeDb.bossDebuffsIconHeight or 20
                modeDb.bossDebuffsIconSize = math.max(w, h)
                modeDb.bossDebuffsIconWidth = nil
                modeDb.bossDebuffsIconHeight = nil
            end
            modeDb._paIconSizeMigrated = true
        end
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb then
                MigrateIconSize(modeDb)
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] then
                        MigrateIconSize(profile[mode])
                    end
                end
            end
        end

        -- v4.3.4: Force private aura icon strata to HIGH across all profiles.
        -- The 12.0.5 Blizzard refactor calls SetFrameLevel(0) on its private
        -- aura pool frame; bumping our iconFrame strata pushes that level-0
        -- child render frame above DF's MEDIUM-strata content regardless of
        -- frame level. Container overlay strata stays at MEDIUM (it has its
        -- own working frame-level path). Runs once per profile/mode.
        local function MigratePAStrataToHigh(modeDb)
            if modeDb._paStrataHighV434 then return end
            modeDb.bossDebuffsStrata = "HIGH"
            modeDb._paStrataHighV434 = true
        end
        for _, mode in ipairs({"party", "raid"}) do
            local modeDb = DF.db[mode]
            if modeDb then
                MigratePAStrataToHigh(modeDb)
            end
        end
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                for _, mode in ipairs({"party", "raid"}) do
                    if profile[mode] then
                        MigratePAStrataToHigh(profile[mode])
                    end
                end
            end
        end

        -- Migrate personal targeted spells container centre to icon-block midpoint (bug 880).
        -- Previously the saved (x, y) was the position of icon 1 (container centre).
        -- Now (x, y) is the visual centre of the icon block; the container is offset so
        -- the block is centred there.  Shift existing positions by halfBlock in the growth
        -- direction so icon 1 stays at its old screen location for existing users.
        local function MigratePersonalContainerPosition(partyDb)
            if not partyDb or partyDb._personalContainerCenterMigrated then return end
            local iconSize = partyDb.personalTargetedSpellSize or 40
            local scale = partyDb.personalTargetedSpellScale or 1.0
            local maxIcons = partyDb.personalTargetedSpellMaxIcons or 5
            local spacing = partyDb.personalTargetedSpellSpacing or 4
            local growthDirection = partyDb.personalTargetedSpellGrowth or "RIGHT"
            local x = partyDb.personalTargetedSpellX or 0
            local y = partyDb.personalTargetedSpellY or -150

            local scaledSize = iconSize * scale
            local scaledSpacing = spacing * scale
            local halfBlock = (maxIcons - 1) / 2 * (scaledSize + scaledSpacing)

            if growthDirection == "RIGHT" then
                partyDb.personalTargetedSpellX = x + halfBlock
            elseif growthDirection == "LEFT" then
                partyDb.personalTargetedSpellX = x - halfBlock
            elseif growthDirection == "UP" then
                partyDb.personalTargetedSpellY = y + halfBlock
            elseif growthDirection == "DOWN" then
                partyDb.personalTargetedSpellY = y - halfBlock
            -- CENTER_H / CENTER_V: no shift needed
            end
            partyDb._personalContainerCenterMigrated = true
        end
        MigratePersonalContainerPosition(DF.db.party)
        if DandersFramesDB_v2 and DandersFramesDB_v2.profiles then
            for _, profile in pairs(DandersFramesDB_v2.profiles) do
                MigratePersonalContainerPosition(profile.party)
            end
        end

        -- Wrap DF.db with overlay proxy (must happen AFTER all migrations,
        -- BEFORE anything that reads through the proxy)
        DF:WrapDB()

        -- Initialize Debug Console (must happen after SavedVariables are ready)
        if DF.DebugConsole then
            DF.DebugConsole:Init()
        end

        print("|cff00ff00DandersFrames|r " .. format(L["v%s loaded. Type %s/df%s for settings, %s/df resetgui%s if window is offscreen."], (DF.VERSION:gsub("^[vV]", "")), "|cffeda55f", "|r", "|cffeda55f", "|r"))

        -- ============================================================
        -- CRITICAL: Initialize frames HERE at ADDON_LOADED
        -- ============================================================
        -- This is essential for combat reload support. At ADDON_LOADED:
        -- 1. Saved variables ARE available
        -- 2. InCombatLockdown() returns FALSE even during a combat /reload
        -- This special window lets us create all frames before the game
        -- starts blocking protected operations.
        -- ============================================================
        if DF.InitializeFrames then
            DF:InitializeFrames()
        end

        -- Apply aura click-through settings immediately at ADDON_LOADED.
        -- SetPropagateMouseMotion() is a protected operation — it must run
        -- here (not in a delayed PLAYER_LOGIN callback) so it works during
        -- combat reload when InCombatLockdown() is temporarily false.
        if DF.UpdateAuraClickThrough then
            DF:UpdateAuraClickThrough()
        end

        -- Initialize Masque support if available
        local Masque = LibStub and LibStub("Masque", true)
        if Masque then
            DF.Masque = Masque
            DF.MasqueGroup_Buffs = Masque:Group("DandersFrames", "Buffs")
            DF.MasqueGroup_Debuffs = Masque:Group("DandersFrames", "Debuffs")
            
            -- Callback when Masque skin changes (using newer API)
            local function MasqueCallback(event, Group, SkinID, Backdrop, Shadow, Gloss, Colors, Disabled)
                -- Reskin happens automatically, but we may need to refresh
                if DF.UpdateAllFrames then
                    C_Timer.After(0.1, function()
                        DF:UpdateAllFrames()
                    end)
                end
            end
            
            -- Use newer RegisterCallback API if available, fallback to SetCallback
            if DF.MasqueGroup_Buffs.RegisterCallback then
                DF.MasqueGroup_Buffs:RegisterCallback("Group_ReSkin", MasqueCallback)
                DF.MasqueGroup_Debuffs:RegisterCallback("Group_ReSkin", MasqueCallback)
            elseif DF.MasqueGroup_Buffs.SetCallback then
                -- Fallback for older Masque versions
                DF.MasqueGroup_Buffs:SetCallback(MasqueCallback)
                DF.MasqueGroup_Debuffs:SetCallback(MasqueCallback)
            end
        end
        
    elseif event == "PLAYER_LOGIN" then
        -- Check for NephUI
        -- NOTE: NephUI previously contained stolen DandersFrames code. A compatibility
        -- popup was added to warn users. The copyright-infringing code has since been
        -- removed from NephUI, so the popup is disabled and compatibility is restored.
        -- Keeping this code in case it's needed again in the future.
        local nephUIPopupEnabled = false
        local nephUILoaded = false
        if C_AddOns and C_AddOns.IsAddOnLoaded then
            nephUILoaded = C_AddOns.IsAddOnLoaded("NephUI")
        elseif IsAddOnLoaded then
            nephUILoaded = IsAddOnLoaded("NephUI")
        end
        
        if nephUILoaded and nephUIPopupEnabled then
            -- Theme color for popup
            local themeColor = { r = 0.2, g = 0.8, b = 0.2 }
            
            -- Helper function to create styled buttons (routed through GUI:StyleButton)
            local function CreatePopupButton(parent, text, yOffset, isPrimary)
                local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
                if isPrimary then
                    DF.GUI:StyleButton(btn, { width = 220, height = 32, text = text, primary = true })
                else
                    DF.GUI:StyleButton(btn, { width = 220, height = 32, text = text })
                end
                btn:SetPoint("TOP", parent.warning, "BOTTOM", 0, yOffset)
                btn.label = btn.Text

                return btn
            end
            
            -- Create the popup frame
            local popup = CreateFrame("Frame", "DFNephUIPopup", UIParent, "BackdropTemplate")
            popup:SetSize(420, 240)
            popup:SetPoint("CENTER")
            popup:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 2,
            })
            popup:SetBackdropColor(0.1, 0.1, 0.1, 0.98)
            popup:SetBackdropBorderColor(themeColor.r, themeColor.g, themeColor.b, 1)
            popup:SetFrameStrata("FULLSCREEN_DIALOG")
            popup:SetFrameLevel(200)
            popup:EnableMouse(true)
            popup:SetMovable(true)
            popup:RegisterForDrag("LeftButton")
            popup:SetScript("OnDragStart", popup.StartMoving)
            popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
            
            -- Title
            local title = popup:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
            title:SetPoint("TOP", 0, -15)
            title:SetText("Addon Conflict Detected")
            title:SetTextColor(1, 0.3, 0.3)
            popup.title = title
            
            -- Warning icons on either side of title
            local leftWarning = popup:CreateTexture(nil, "OVERLAY")
            leftWarning:SetSize(20, 20)
            leftWarning:SetPoint("RIGHT", title, "LEFT", -8, 0)
            leftWarning:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning")
            leftWarning:SetVertexColor(1, 0.3, 0.3)
            popup.leftWarning = leftWarning
            
            local rightWarning = popup:CreateTexture(nil, "OVERLAY")
            rightWarning:SetSize(20, 20)
            rightWarning:SetPoint("LEFT", title, "RIGHT", 8, 0)
            rightWarning:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\warning")
            rightWarning:SetVertexColor(1, 0.3, 0.3)
            popup.rightWarning = rightWarning
            
            -- Message
            local msg = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
            msg:SetPoint("TOP", title, "BOTTOM", 0, -15)
            msg:SetPoint("LEFT", 25, 0)
            msg:SetPoint("RIGHT", -25, 0)
            msg:SetJustifyH("CENTER")
            msg:SetText("Both |cff00ff00DandersFrames|r and |cffff6666NephUI|r are loaded.\n\nWhich addon would you like to use?")
            msg:SetTextColor(1, 1, 1)
            popup.msg = msg
            
            -- Warning text
            local warning = popup:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
            warning:SetPoint("TOP", msg, "BOTTOM", 0, -10)
            warning:SetPoint("LEFT", 25, 0)
            warning:SetPoint("RIGHT", -25, 0)
            warning:SetJustifyH("CENTER")
            warning:SetText("Selecting an option will disable the other addon\nand reload your UI.")
            warning:SetTextColor(0.7, 0.7, 0.7)
            popup.warning = warning
            
            -- DandersFrames button (primary)
            local dfBtn = CreatePopupButton(popup, "Use DandersFrames", -20, true)
            dfBtn:SetScript("OnClick", function()
                if C_AddOns and C_AddOns.DisableAddOn then
                    C_AddOns.DisableAddOn("NephUI")
                elseif DisableAddOn then
                    DisableAddOn("NephUI")
                end
                ReloadUI()
            end)
            popup.dfBtn = dfBtn
            
            -- NephUI button (secondary - triggers wrong choice)
            local nephBtn = CreatePopupButton(popup, "Use NephUI", -57, false)
            nephBtn:SetScript("OnClick", function()
                -- Switch to "wrong choice" state
                title:SetText("That's the wrong choice!")
                title:SetTextColor(1, 0.4, 0.2)
                
                -- Hide warning icons for this screen
                leftWarning:Hide()
                rightWarning:Hide()
                
                msg:SetText("|cffff6666NephUI|r has stolen and copied |cff00ff00DandersFrames|r.\n\nThere is only one correct option here.")
                
                warning:SetText("")
                
                -- Hide the NephUI button
                nephBtn:Hide()
                
                -- Update DandersFrames button
                dfBtn.label:SetText("Use DandersFrames (The Original)")
                dfBtn:SetSize(260, 32)
                dfBtn:ClearAllPoints()
                dfBtn:SetPoint("TOP", msg, "BOTTOM", 0, -25)
            end)
            popup.nephBtn = nephBtn
            
            -- Store reference
            DF.nephUIPopup = popup
            
            -- Don't initialize DandersFrames if NephUI is loaded
            return
        end
        
        -- Enable raid buff filtering now that we're past ADDON_LOADED
        -- (avoids "secret value" errors during combat reload initialization)
        DF.raidBuffFilteringReady = true
        
        -- Setup slash command
        SLASH_DANDERSFRAMES1 = "/df"
        SLASH_DANDERSFRAMES2 = "/dandersframes"
        SlashCmdList["DANDERSFRAMES"] = function(msg)
            local rawMsg = msg or ""
            msg = msg and msg:lower() or ""

            -- "/df clearoverride <key|prefix|all>" — remove a stuck auto-layout
            -- override from the target layout. Parsed from the raw message so the
            -- key keeps its original case (override keys are mixed-case).
            local firstWord, restRaw = rawMsg:match("^%s*(%S+)%s*(.-)%s*$")
            if firstWord and (firstWord:lower() == "clearoverride" or firstWord:lower() == "clearoverrides") then
                if DF.AutoProfilesUI and DF.AutoProfilesUI.ClearOverrideCommand then
                    DF.AutoProfilesUI:ClearOverrideCommand(restRaw ~= "" and restRaw or nil)
                else
                    print("|cff00ff00DandersFrames:|r Auto profiles module not loaded.")
                end
                return
            end

            if msg == "unlock" then
                if DF.UnlockFrames then DF:UnlockFrames() end
            elseif msg == "lock" then
                if DF.LockFrames then DF:LockFrames() end
            elseif msg == "raidunlock" or msg == "unlockraid" then
                -- While an auto layout is active, base-position unlock is blocked
                -- (matches the disabled toolbar button) — point users to the active
                -- layout's own Unlock button so they don't move the base by accident.
                if DF.AutoProfilesUI and DF.AutoProfilesUI.IsLayoutActive and DF.AutoProfilesUI:IsLayoutActive() then
                    local name = DF.AutoProfilesUI.GetActiveLayoutName and DF.AutoProfilesUI:GetActiveLayoutName()
                    print("|cffff9900DandersFrames:|r " .. string.format(L["Auto layout \"%s\" is active. Unlock it from the Auto Layouts page to move its frames."], name or "?"))
                elseif DF.UnlockRaidFrames then
                    DF:UnlockRaidFrames()
                end
            elseif msg == "raidlock" or msg == "lockraid" then
                if DF.LockRaidFrames then DF:LockRaidFrames() end
            elseif msg == "reset" then
                DF:ResetProfile("party")
                DF:ResetProfile("raid")
            elseif msg == "resetgui" then
                -- Reset GUI scale, size, and position to defaults
                if DF.db and DF.db.party then
                    DF.db.party.guiScale = 1.0
                    DF.db.party.guiWidth = 760
                    DF.db.party.guiHeight = 520
                    DF.db.party.guiPoint = nil
                    DF.db.party.guiRelPoint = nil
                    DF.db.party.guiX = nil
                    DF.db.party.guiY = nil
                end
                if DF.GUIFrame then
                    DF.GUIFrame:ClearAllPoints()
                    DF.GUIFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                    DF.GUIFrame:SetSize(760, 520)
                    DF.GUIFrame:SetScale(1.0)
                    if DF.GUI and DF.GUI.ScaleSlider then
                        DF.GUI.ScaleSlider:SetValue(1.0)
                    end
                    DF.GUIFrame:Show()
                end
                print("|cff00ff00DandersFrames:|r " .. L["GUI reset to default size, scale, and position."])
            elseif msg == "overrides" then
                if DF.AutoProfilesUI and DF.AutoProfilesUI.PrintOverrides then
                    DF.AutoProfilesUI:PrintOverrides()
                else
                    print("|cff00ff00DandersFrames:|r Auto profiles module not loaded.")
                end
            elseif msg == "test" then
                if DF.ToggleTestPanel then DF:ToggleTestPanel() end
            elseif msg == "hide" then
                if DF.HideTestFrames then DF:HideTestFrames() end
            elseif msg == "debug" then
                if DF.DebugConsole then
                    local newState = not DF.DebugConsole:IsEnabled()
                    DF.DebugConsole:SetEnabled(newState)
                    print("|cff00ff00DandersFrames:|r " .. format(L["Debug logging %s"], newState and L["enabled"] or L["disabled"]))
                else
                    DF.debugEnabled = not DF.debugEnabled
                    print("|cff00ff00DandersFrames:|r " .. format(L["Debug mode %s"], DF.debugEnabled and L["enabled"] or L["disabled"]))
                end
            elseif msg == "users" then
                if DF.VersionCheck then DF.VersionCheck:PrintUsers() end
            elseif msg == "console" then
                -- Open settings directly to Debug Console tab
                if not DF.GUIFrame then
                    DF:ToggleGUI()
                elseif not DF.GUIFrame:IsShown() then
                    DF:ToggleGUI()
                end
                if DF.GUI and DF.GUI.SelectTab then
                    DF.GUI.SelectTab("debug_console")
                end
            elseif msg == "debugrole" then
                DF.debugRoleIcons = not DF.debugRoleIcons
                print("|cff00ff00DandersFrames:|r " .. format("Role icon debug %s", DF.debugRoleIcons and L["enabled"] or L["disabled"]))
                print("  Enter/leave combat to see role icon update logs")
            elseif msg == "debugslider" then
                DF.debugSliderUpdates = not DF.debugSliderUpdates
                print("|cff00ff00DandersFrames:|r " .. format("Slider update debug %s", DF.debugSliderUpdates and L["enabled"] or L["disabled"]))
                if DF.debugSliderUpdates then
                    print("  Drag any slider to see update function calls")
                    print("  " .. format("%sGreen%s = lightweight update, %sYellow%s = full update", "|cff88ff88", "|r", "|cffffff00", "|r"))
                end
            elseif msg == "debugrested" then
                if DF.DebugRestedIndicator then
                    DF:DebugRestedIndicator()
                end
            elseif msg == "debugraidbuffs" then
                -- Debug raid buff icon filtering
                print("|cff00ff00DandersFrames:|r Raid Buff Icon Debug")
                local icons = DF:GetRaidBuffIcons()
                print("  Cached raid buff icons:")
                for icon, _ in pairs(icons) do
                    print("    " .. tostring(icon) .. " (type: " .. type(icon) .. ")")
                end
                -- Also show current buffs on player for comparison
                print("  Current buffs on player:")
                for i = 1, 10 do
                    local auraData = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
                    if auraData then
                        local iconVal = nil
                        pcall(function() iconVal = auraData.icon end)
                        local nameVal = nil
                        pcall(function() nameVal = auraData.name end)
                        print("    " .. (nameVal or "?") .. " - icon: " .. tostring(iconVal) .. " (type: " .. type(iconVal) .. ")")
                        if iconVal and icons[iconVal] then
                            print("      ^ MATCHES raid buff!")
                        end
                    end
                end
            elseif msg == "auras" or msg == "debugauras" then
                -- Debug command to compare aura filters
                DF:DebugAuraFilters("player")
            elseif msg == "debugfonts" then
                -- Debug command to show font info
                print("|cff00ff00DandersFrames:|r Font Debug")
                local LSM = DF.GetLSM and DF.GetLSM()
                if LSM then
                    local total = #LSM:List("font")
                    local available = 0
                    for _ in pairs(DF:GetFontList()) do available = available + 1 end
                    print("  Total in SharedMedia: " .. total)
                    print("  Available in DandersFrames: " .. available)
                end
            elseif msg:match("^auras ") then
                local unit = msg:match("^auras (.+)")
                DF:DebugAuraFilters(unit)
            elseif msg == "clickcast" then
                -- Debug click-cast registration
                print("|cff00ff00DandersFrames:|r Click-Cast Debug")
                if ClickCastFrames then
                    print("  ClickCastFrames table exists")
                    local count = 0
                    local idx = 0
                    if DF.IteratePartyFrames then
                        DF:IteratePartyFrames(function(frame)
                            idx = idx + 1
                            local status = ClickCastFrames[frame]
                            print("  Party[" .. idx .. "] frame:", status == true and "registered" or (status == false and "unregistered" or "not in table"))
                            if status then count = count + 1 end
                        end)
                    end
                    print("  Total registered:", count)
                else
                    print("  ClickCastFrames table does NOT exist")
                    print("  (Clicked/Clique addon may not be loaded)")
                end
            elseif msg == "dispel" or msg:match("^dispel ") then
                -- Debug dispel detection
                local unit = msg:match("^dispel (.+)") or "player"
                if DF.DebugDispel then
                    DF:DebugDispel(unit)
                else
                    print("|cffff0000DandersFrames:|r Dispel debug not loaded")
                end
            elseif msg == "resetconflict" then
                -- Reset the click-casting conflict warning ignore setting
                if DandersFramesClickCastingDB then
                    DandersFramesClickCastingDB.ignoreConflictWarning = nil
                    print("|cff00ff00DandersFrames:|r Click-casting conflict warning has been re-enabled.")
                    print("|cff00ff00DandersFrames:|r The warning will appear on next reload if conflicts are detected.")
                else
                    print("|cffff9900DandersFrames:|r Click-casting database not loaded.")
                end
            elseif msg == "casthistory" or msg == "history" then
                -- Show cast history (TEST feature for secret values)
                if DF.ShowCastHistory then
                    DF:ShowCastHistory()
                else
                    print("|cffff0000DandersFrames:|r Cast history not available")
                end
            elseif msg == "clearhistory" then
                -- Clear cast history
                if DF.ClearCastHistory then
                    DF:ClearCastHistory()
                else
                    print("|cffff0000DandersFrames:|r Cast history not available")
                end
            elseif msg == "headers" or msg == "hdump" then
                -- Dump header debug info
                if DF.DumpHeaderInfo then
                    DF:DumpHeaderInfo()
                else
                    print("|cffff0000DandersFrames:|r Header info not available")
                end
            elseif msg == "attached" or msg == "attachments" then
                -- List other addons anchored/parented to DF unit frames
                if DF.ScanFrameAttachments then
                    DF:ScanFrameAttachments()
                else
                    print("|cffff0000DandersFrames:|r Attachment scan not available")
                end
            elseif msg == "debugheaders" then
                -- Toggle header debug mode
                DF.debugHeaders = not DF.debugHeaders
                print("|cff00ff00DandersFrames:|r " .. format("Header debug %s", DF.debugHeaders and L["enabled"] or L["disabled"]))
            elseif msg == "raidbg" then
                -- Toggle raid group debug backgrounds
                if DF.ToggleRaidDebugBackgrounds then
                    DF:ToggleRaidDebugBackgrounds()
                else
                    print("|cffff0000DandersFrames:|r Raid debug not available")
                end
            elseif msg == "auratimer" then
                -- Show aura timer stats
                if DF.PrintAuraTimerStats then
                    DF:PrintAuraTimerStats()
                else
                    print("|cffff0000DandersFrames:|r Aura timer not available")
                end
            elseif msg == "auratimer reset" or msg == "auratreset" then
                -- Reset aura timer stats
                if DF.ResetAuraTimerStats then
                    DF:ResetAuraTimerStats()
                else
                    print("|cffff0000DandersFrames:|r Aura timer not available")
                end
            elseif msg == "testwizard" then
                if DF.TestPopupWizard then
                    DF:TestPopupWizard()
                else
                    print("|cffff0000DandersFrames:|r Popup module not loaded")
                end
            elseif msg == "testhighlight" then
                -- Debug: open settings to Frame tab and highlight width/height
                if not DF.GUIFrame or not DF.GUIFrame:IsShown() then
                    DF:ToggleGUI()
                end
                if DF.GUI and DF.GUI.Tabs and DF.GUI.Tabs["general_frame"] then
                    DF.GUI.Tabs["general_frame"]:Click()
                end
                C_Timer.After(0.3, function()
                    -- Debug: dump page children info
                    local page = DF.GUI and DF.GUI.Pages and DF.GUI.Pages["general_frame"]
                    if page then
                        print("|cff00ff00DandersFrames:|r Page found, children: " .. (page.children and #page.children or "nil"))
                        if page.children then
                            local found = 0
                            for i, w in ipairs(page.children) do
                                -- Check direct children
                                if w.searchEntry and (w.searchEntry.dbKey == "frameWidth" or w.searchEntry.dbKey == "frameHeight") then
                                    found = found + 1
                                    print("  [" .. i .. "] dbKey=" .. w.searchEntry.dbKey)
                                end
                                -- Check settings group children
                                if w.isSettingsGroup and w.groupChildren then
                                    for j, entry in ipairs(w.groupChildren) do
                                        if entry.widget and entry.widget.searchEntry then
                                            local dk = entry.widget.searchEntry.dbKey
                                            if dk == "frameWidth" or dk == "frameHeight" then
                                                found = found + 1
                                                print("  [" .. i .. "].group[" .. j .. "] dbKey=" .. dk .. " visible=" .. tostring(entry.widget:IsVisible()))
                                            end
                                        end
                                    end
                                end
                            end
                            print("  Found " .. found .. " matching widgets")
                        end
                    else
                        print("|cffff0000DandersFrames:|r Page 'general_frame' not found")
                        if DF.GUI and DF.GUI.Pages then
                            print("  Available pages:")
                            for k, _ in pairs(DF.GUI.Pages) do
                                print("  - " .. tostring(k))
                            end
                        end
                    end
                    DF:HighlightSettings("general_frame", {"frameWidth", "frameHeight"})
                end)
            elseif msg == "testalert" then
                if DF.TestPopupAlert then
                    DF:TestPopupAlert()
                else
                    print("|cffff0000DandersFrames:|r Popup module not loaded")
                end
            elseif msg:match("^importwizard ") then
                local str = msg:match("^importwizard (.+)$")
                if str and DF.WizardBuilder then
                    DF.WizardBuilder:HandleImportCommand(str)
                else
                    print("|cffff0000DandersFrames:|r Usage: /df importwizard <string>")
                end
            elseif msg == "aurasetup" then
                -- Launch the Aura Filter Setup wizard
                if DF.WizardBuilder then
                    local builtins = DF.WizardBuilder:GetBuiltinWizards()
                    for _, entry in ipairs(builtins) do
                        if entry.name == "Aura Filter Setup" and entry.build then
                            local config = entry.build()
                            if config then DF:ShowPopupWizard(config) end
                            break
                        end
                    end
                else
                    print("|cffff0000DandersFrames:|r WizardBuilder not loaded")
                end
            elseif msg == "testbuilder" then
                -- Test the wizard builder popup
                if DF.ShowWizardBuilder then
                    DF:ShowWizardBuilder("Test Builder Wizard", function(name)
                        DF:Debug("Builder saved wizard: " .. tostring(name))
                        print("|cff00ff00DandersFrames:|r " .. format(L["Wizard '%s' saved!"], tostring(name)))
                    end)
                else
                    print("|cffff0000DandersFrames:|r WizardBuilder not loaded")
                end
            elseif msg == "testpicker" then
                -- Test the settings picker mode
                if DF.EnterSettingsPickerMode then
                    DF:EnterSettingsPickerMode(function(tabName, dbKey, controlType)
                        DF:Debug("Picker selected: tab=" .. tostring(tabName) .. " key=" .. tostring(dbKey) .. " type=" .. tostring(controlType))
                        print("|cff00ff00DandersFrames:|r " .. format(L["Picked setting: %s%s%s from tab %s%s%s"], "|cffffffff", tostring(dbKey), "|r", "|cffffffff", tostring(tabName), "|r"))
                    end)
                else
                    print("|cffff0000DandersFrames:|r Popup module not loaded")
                end
            elseif msg == "localewarn" or msg == "localewarnings" then
                -- Toggle AceLocale missing-key warnings for this session
                DF:SetLocaleWarnings(not DF.localeWarningsEnabled)
                print("|cff00ff00DandersFrames:|r Locale warnings " .. (DF.localeWarningsEnabled and "|cff00ff00ENABLED|r" or "|cffff9900DISABLED|r") .. " for this session")
            elseif msg == "profiler" then
                -- Toggle the function profiler UI
                if DF.Profiler then
                    DF.Profiler:ToggleUI()
                else
                    print("|cffff0000DandersFrames:|r Profiler not loaded")
                end
            elseif msg == "profiler hook" then
                -- Toggle the OnUpdate hook (requires /rl)
                if not DandersFramesDB_v2 then DandersFramesDB_v2 = {} end
                local newState = not DandersFramesDB_v2.profilerOnUpdateHook
                DandersFramesDB_v2.profilerOnUpdateHook = newState
                if newState then
                    print("|cff00ff00DandersFrames:|r Profiler OnUpdate hook |cff00ff00ENABLED|r. Type |cffeda55f/rl|r to apply.")
                else
                    print("|cff00ff00DandersFrames:|r Profiler OnUpdate hook |cffff9900DISABLED|r. Type |cffeda55f/rl|r to apply.")
                end
            elseif msg == "profile" or msg:match("^profile %d") then
                -- Quick profile run: /df profile [seconds]
                if DF.Profiler then
                    local duration = tonumber(msg:match("(%d+)")) or 10
                    DF.Profiler:QuickProfile(duration)
                else
                    print("|cffff0000DandersFrames:|r Profiler not loaded")
                end
            else
                if DF.ToggleGUI then
                    DF:ToggleGUI()
                else
                    print("|cffff0000DandersFrames:|r GUI not loaded yet.")
                end
            end
        end
        
        -- Add convenient /rl reload command
        SLASH_DFRL1 = "/rl"
        SlashCmdList["DFRL"] = function()
            ReloadUI()
        end

        if DF.VersionCheck then DF.VersionCheck:Init() end
        if DF.Nicknames then DF.Nicknames:Init() end

        -- Post-initialization updates (frames already created at ADDON_LOADED)
        -- These need a delay to let Blizzard addons settle and world to be ready
        C_Timer.After(0.5, function()
            -- One-time migration of legacy name/health/status text settings into
            -- Text Designer elements. Naturally idempotent (per-mode guard +
            -- migratedFromLegacy flag), so re-running on every login is a no-op
            -- once it has run. The function-exists guard is belt-and-suspenders;
            -- the Text Designer files now load in every build.
            -- Designer Presets: move every inline auraDesigner / textDesigner
            -- config (party/raid + each raid auto-layout override) into the
            -- named preset library. Runs BEFORE the TD-legacy migration below so
            -- that migration builds its elements straight into the "Party"/"Raid"
            -- presets (its guard flag then persists on the preset). Idempotent.
            if DF.MigrateDesignerPresets then
                DF:MigrateDesignerPresets()
            end

            -- Carry old important-spell highlight settings into the new
            -- Important Spell Border key set (per-profile guarded, no-op once run).
            if DF.MigrateTargetedSpellImportantBorder then
                DF:MigrateTargetedSpellImportantBorder()
            end

            if DF.MigrateTextDesignerFromLegacy then
                DF:MigrateTextDesignerFromLegacy()
            end
            -- One-time cleanup of stray health text the pre-fix migration injected
            -- onto profiles that had health text off (idempotent, self-guarded).
            if DF.CorrectStrayMigratedHealthText then
                DF:CorrectStrayMigratedHealthText()
            end

            -- Strip orphaned legacy text overrides from raid auto-layouts now that
            -- TD owns the built-in text (gated on migratedFromLegacy inside).
            if DF.CleanupLegacyTextLayoutOverrides then
                DF:CleanupLegacyTextLayoutOverrides()
            end

            -- Appearance-preserving border migration: fold AD icon/square inset
            -- into BorderSize and zero buff/debuff inset so the unified-border
            -- rework keeps the pre-rework look. Per-profile guarded (no-op once
            -- run); independent of Designer Presets (preset walk is nil-guarded).
            if DF.MigrateBorderInsetFold then
                DF:MigrateBorderInsetFold()
            end

            -- Fold the legacy OOR name-text alpha into the unified oorTextAlpha
            -- (Text Designer now renders all text). Per-profile guarded.
            if DF.MigrateOORTextAlpha then
                DF:MigrateOORTextAlpha()
            end

            -- Retire the deprecated raidGroupOrder reverse toggle (NORMAL-ize any
            -- stale "REVERSE"); group order now comes from Group Display Order.
            if DF.MigrateDeprecateRaidGroupOrder then
                DF:MigrateDeprecateRaidGroupOrder()
            end

            -- CRITICAL: Update power bars now that unit data is available
            -- At ADDON_LOADED, UnitPower() etc may return 0 before player is loaded
            -- Power bar updates don't require combat protection
            if DF.UpdatePower then
                -- Party frames via iterator
                if DF.IteratePartyFrames then
                    DF:IteratePartyFrames(function(frame)
                        DF:UpdatePower(frame)
                    end)
                end
                -- Raid frames via iterator
                if DF.IterateRaidFrames then
                    DF:IterateRaidFrames(function(frame)
                        DF:UpdatePower(frame)
                    end)
                end
            end
            
            -- Full frame update if not in combat
            if not InCombatLockdown() then
                if IsInRaid() and not DF:IsInArena() then
                    if DF.UpdateLiveRaidFrames then
                        DF:UpdateLiveRaidFrames()
                    end
                else
                    if DF.UpdateAllFrames then
                        DF:UpdateAllFrames()
                    end
                end
            end
            
            -- Register click casting now that frames are ready
            if DF.RegisterClickCastFrames then
                DF:RegisterClickCastFrames()
            end
            if DF.RegisterRaidClickCastFrames then
                DF:RegisterRaidClickCastFrames()
            end
            
            -- Apply saved CVar settings after world is ready
            DF:ApplySavedCVarSettings()
            -- NOTE: UpdateAuraClickThrough is called at ADDON_LOADED (not here)
            -- because SetPropagateMouseMotion() is protected and must run before
            -- combat lockdown activates on combat reload.
            -- Update rested indicator
            if DF.UpdateRestedIndicator then
                DF:UpdateRestedIndicator()
            end
            -- Update default player frame visibility
            if DF.UpdateDefaultPlayerFrame then
                DF:UpdateDefaultPlayerFrame()
            end
            
            -- Refresh fonts (may not have been fully available during ADDON_LOADED combat reload)
            if DF.RefreshAllFonts then
                if InCombatLockdown() then
                    -- Queue font refresh for after combat
                    DF.pendingFontRefresh = true
                else
                    DF:RefreshAllFonts()
                end
            end
            
            -- Flat layout refresh to ensure correct positioning on load
            local raidDb = DF:GetRaidDB()
            if IsInRaid() and not raidDb.raidUseGroups and not InCombatLockdown() then
                if DF.headersInitialized then
                    DF:ApplyHeaderSettings()
                end
                if DF.UpdateRaidLayout then
                    DF:UpdateRaidLayout()
                end
            end
            
            -- Update raid group labels (needs headers to be positioned first)
            if DF.UpdateRaidGroupLabels then
                DF:UpdateRaidGroupLabels()
            end
        end)

        -- Show Aura Filter Setup wizard for existing users on first login after update.
        -- Skip entirely when Blizzard's aura pipeline has been removed (12.0.5+):
        -- the wizard walks users through migrating from Blizzard → Direct API
        -- filtering, which is meaningless when Blizzard source no longer exists.
        -- The API-block popup already tells users what happened and points them
        -- at the Aura Filters tab.
        local blizzardAuraSourceGone =
            DandersFramesDB_v2 and DandersFramesDB_v2.apiBlocked
            and DandersFramesDB_v2.apiBlocked.blizzardAuraSource
        if DandersFramesDB_v2 and not DandersFramesDB_v2.seenAuraSetupWizard
           and not blizzardAuraSourceGone then
            DandersFramesDB_v2.seenAuraSetupWizard = true
            C_Timer.After(3, function()
                if DF.WizardBuilder and not InCombatLockdown() then
                    local builtins = DF.WizardBuilder:GetBuiltinWizards()
                    for _, entry in ipairs(builtins) do
                        if entry.name == "Aura Filter Setup" and entry.build then
                            local config = entry.build()
                            if config then DF:ShowPopupWizard(config) end
                            break
                        end
                    end
                end
            end)
        elseif blizzardAuraSourceGone and DandersFramesDB_v2 then
            -- Mark as "seen" so that if/when Blizzard reverses the change and
            -- this block stops catching, we don't suddenly pop the wizard on a
            -- user who's been running for months without it.
            DandersFramesDB_v2.seenAuraSetupWizard = true
        end

        -- Show the Targeted Spells opt-in setup wizard once per account.
        -- The feature defaults OFF; this wizard explains what it does, its
        -- limitations, and that it relies on unsupported Blizzard behaviour
        -- before letting the user turn it on. Mark seen at schedule time so a
        -- close/cancel still counts (no re-nag on the next login).
        if DandersFramesDB_v2 and not DandersFramesDB_v2.targetedSpellWizardSeen then
            DandersFramesDB_v2.targetedSpellWizardSeen = true
            if DF.ShowTargetedSpellSetupWizard then
                -- Delay so it doesn't fight the loading screen. Longer than the
                -- Aura Setup wizard's 3s so the two don't collide on a brand-new
                -- account that qualifies for both; if a popup is already showing
                -- when we fire, wait a bit and retry once rather than stomp it.
                local function ShowTSWizard(attempt)
                    if DF.IsPopupShown and DF:IsPopupShown() then
                        if attempt < 3 then
                            C_Timer.After(5, function() ShowTSWizard(attempt + 1) end)
                        end
                        return
                    end
                    DF:ShowTargetedSpellSetupWizard()
                end
                C_Timer.After(5, function() ShowTSWizard(1) end)
            end
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        if DF.RosterDebugEvent then DF:RosterDebugEvent("Core.lua:GROUP_ROSTER_UPDATE") end

        -- Headers.lua handles roster updates via ProcessRosterUpdate (container
        -- visibility, sorting). Frame updates happen via OnAttributeChanged (unit
        -- changes) and PLAYER_ROLES_ASSIGNED (role changes).
        --
        -- Missing buff icons are not cleared by OnAttributeChanged when a slot
        -- empties (unit → nil skips the refresh), and UNIT_AURA stops firing for
        -- units that left the group. Frames that remain visible (player frame,
        -- remaining group members) can be left with stale indicators. Sweep after
        -- the roster settles. The 0.1s throttle inside UpdateAllMissingBuffIcons
        -- prevents spam from rapid GRU bursts on group transitions.
        if DF.UpdateAllMissingBuffIcons then
            C_Timer.After(0.3, function()
                if not InCombatLockdown() then
                    DF:UpdateAllMissingBuffIcons()
                end
            end)
        end
        return
        
    elseif event == "PLAYER_ROLES_ASSIGNED" then
        -- Skip completely - headerChildEventFrame in Headers.lua handles this centrally
        -- No need to call UpdateAllRoleIcons which iterates all frames
        return
        
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
        -- These fire in bursts (often 8+ times) on zone-in, login, and group
        -- join as the client syncs talent/spec data. Doing a full UpdateAllFrames
        -- + Aura Designer refresh on every fire caused a noticeable hitch when
        -- joining a large raid. Coalesce the burst into a single deferred refresh.
        if not DF._specTalentRefreshScheduled then
            DF._specTalentRefreshScheduled = true
            C_Timer.After(0.15, function()
                DF._specTalentRefreshScheduled = false
                -- Spec or talents changed - check for profile auto-switch
                if DF.CheckProfileAutoSwitch then
                    DF:CheckProfileAutoSwitch()
                end
                -- Update all frames (resource bar colors may change)
                if DF.UpdateAllFrames then
                    DF:UpdateAllFrames()
                end
                -- Re-anchor raid container — spec switch can change layout dimensions
                -- Must be outside combat: SetScale on the container is protected
                if DF.UpdateRaidContainerPosition and not InCombatLockdown() then
                    DF:UpdateRaidContainerPosition()
                end
                -- Refresh Aura Designer (per-spec aura lists may differ)
                -- Invalidate the adapter's per-spec spellId cache first — otherwise
                -- stale entries prevent the new spec's spell IDs (e.g., Earth Shield
                -- for Resto Shaman) from being recognized after a spec swap.
                if DF.AuraDesigner and DF.AuraDesigner.Adapter and DF.AuraDesigner.Adapter.InvalidateSpecCache then
                    DF.AuraDesigner.Adapter:InvalidateSpecCache()
                end
                if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
                    DF.AuraDesigner.Engine:ForceRefreshAllFrames()
                end
            end)
        end

    elseif event == "UNIT_PET" then
        -- Pet summoned or dismissed - update pet frames
        if DF.HandleUnitPetEvent then
            DF:HandleUnitPetEvent(arg1)
        end
        
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Track combat state
        DF.playerInCombat = false
        
        -- Clean up after test mode was interrupted by combat
        if DF.testModeInterruptedByCombat then
            DF.testModeInterruptedByCombat = false
            -- Unregister state drivers so UpdateHeaderVisibility manages normally
            DF:ClearTestModeStateDrivers()
            -- Restore proper fine-grained header visibility
            if DF.UpdateHeaderVisibility then
                DF:UpdateHeaderVisibility()
            end
            -- Refresh live frame data
            if DF.UpdateAllDispelOverlays then
                C_Timer.After(0.2, function()
                    DF:UpdateAllDispelOverlays()
                end)
            end
            if DF.UpdateAllMissingBuffIcons then
                C_Timer.After(0.1, function()
                    if not InCombatLockdown() then
                        DF:UpdateAllMissingBuffIcons()
                    end
                end)
            end
            if DF.UpdateAllPetFrames then
                C_Timer.After(0.1, function()
                    DF:UpdateAllPetFrames()
                end)
            end
            if DF.UpdateAllRaidPetFrames then
                C_Timer.After(0.1, function()
                    DF:UpdateAllRaidPetFrames()
                end)
            end
        end
        
        -- Debug (use /df debugrole to enable)
        if DF.debugRoleIcons then
            print("|cff00ffffDF ROLE:|r PLAYER_REGEN_ENABLED (leaving combat)")
        end
        
        -- Process any pending unit watch registrations
        if DF.ProcessPendingUnitWatch then
            DF:ProcessPendingUnitWatch()
        end
        
        -- Apply queued updates after combat
        if DF.needsUpdate then
            DF.needsUpdate = false
            DF:UpdateAll()
        end
        
        -- Process pending font refresh (queued during combat reload)
        if DF.pendingFontRefresh then
            DF.pendingFontRefresh = false
            if DF.RefreshAllFonts then
                DF:RefreshAllFonts()
            end
        end
        
        -- Clear pre-combat aura snapshot now that live data is readable again
        if DF.ClearPreCombatSnapshot then
            DF:ClearPreCombatSnapshot()
        end
        -- Update missing buff icons now that we're out of combat
        if DF.UpdateAllMissingBuffIcons then
            DF:UpdateAllMissingBuffIcons()
        end
        -- Refresh auras now that we're out of combat
        if DF.UpdateAllAuras then
            DF:UpdateAllAuras()
        end
        -- Re-configure any AD indicators that were created during combat
        -- (SetPropagateMouseMotion/Clicks are protected and can't be called in combat)
        if DF.AuraDesigner and DF.AuraDesigner.Engine then
            DF.adConfigVersion = (DF.adConfigVersion or 0) + 1
            local adEngine = DF.AuraDesigner.Engine
            local function preWarmFrame(frame)
                if frame and DF:IsAuraDesignerEnabled(frame) then
                    adEngine:PreWarmIndicators(frame)
                end
            end
            if DF.IteratePartyFrames then DF:IteratePartyFrames(preWarmFrame) end
            if DF.IterateRaidFrames then DF:IterateRaidFrames(preWarmFrame) end
        end
        -- Re-apply mouse settings on aura icons created during combat
        if DF.auraIconsNeedMouseFix then
            DF.auraIconsNeedMouseFix = false
            local function fixIconMouse(frame)
                if not frame or not frame:IsShown() then return end
                -- Fix buff, debuff, and defensive bar icons
                for _, icons in ipairs({ frame.buffIcons, frame.debuffIcons, frame.defensiveBarIcons }) do
                    if icons then
                        for _, icon in ipairs(icons) do
                            icon:EnableMouse(true)
                            if icon.SetPropagateMouseMotion then
                                icon:SetPropagateMouseMotion(true)
                            end
                            if icon.SetPropagateMouseClicks then
                                icon:SetPropagateMouseClicks(true)
                            end
                            if icon.SetMouseClickEnabled then
                                icon:SetMouseClickEnabled(false)
                            end
                        end
                    end
                end
                -- Fix single defensive icon
                if frame.defensiveIcon then
                    frame.defensiveIcon:EnableMouse(true)
                    if frame.defensiveIcon.SetPropagateMouseMotion then
                        frame.defensiveIcon:SetPropagateMouseMotion(true)
                    end
                    if frame.defensiveIcon.SetPropagateMouseClicks then
                        frame.defensiveIcon:SetPropagateMouseClicks(true)
                    end
                    if frame.defensiveIcon.SetMouseClickEnabled then
                        frame.defensiveIcon:SetMouseClickEnabled(false)
                    end
                end
            end
            if DF.IteratePartyFrames then DF:IteratePartyFrames(fixIconMouse) end
            if DF.IterateRaidFrames then DF:IterateRaidFrames(fixIconMouse) end
        end
        -- Update role icons (in case hideInCombat is enabled)
        if DF.UpdateAllRoleIcons then
            DF:UpdateAllRoleIcons()
        end
        -- Update aura click-through state (for click-through in combat setting)
        if DF.UpdateAuraClickThrough then
            DF:UpdateAuraClickThrough()
        end
        -- Update permanent mover combat state (color/visibility) — delayed to run
        -- after any deferred frame refreshes that might reset backdrop colors
        if DF.UpdatePermanentMoverCombatState then
            C_Timer.After(0.05, function() DF:UpdatePermanentMoverCombatState() end)
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Track combat state
        DF.playerInCombat = true
        
        -- Auto-exit test mode when combat starts
        -- State drivers (registered when test mode started) will auto-show
        -- the correct live frames now that [combat] condition is true
        if DF.testMode or DF.raidTestMode then
            DF.testModeInterruptedByCombat = true
            
            -- Hide party test frames (non-secure, safe in combat)
            if DF.testMode then
                DF.testMode = false
                DF:StopTestAnimation()
                for i = 0, 4 do
                    local frame = DF.testPartyFrames and DF.testPartyFrames[i]
                    if frame then
                        frame:Hide()
                        if frame.absorbAttachedTexture then frame.absorbAttachedTexture:Hide() end
                        if frame.healAbsorbAttachedTexture then frame.healAbsorbAttachedTexture:Hide() end
                        if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
                        if frame.defensiveIcon then frame.defensiveIcon:Hide() end
                        DF:HideTestBossDebuffs(frame)
                        if DF.HideAllTargetedSpells then
                            DF:HideAllTargetedSpells(frame)
                        end
                    end
                end
                if DF.testPartyContainer then
                    DF.testPartyContainer:Hide()
                end
                if DF.HideTestPersonalTargetedSpells then
                    DF:HideTestPersonalTargetedSpells()
                end
            end
            
            -- Hide raid test frames (non-secure, safe in combat)
            if DF.raidTestMode then
                DF.raidTestMode = false
                DF:StopTestAnimation()
                for i = 1, 40 do
                    local frame = DF.testRaidFrames and DF.testRaidFrames[i]
                    if frame then
                        frame:Hide()
                        if frame.absorbAttachedTexture then frame.absorbAttachedTexture:Hide() end
                        if frame.healAbsorbAttachedTexture then frame.healAbsorbAttachedTexture:Hide() end
                        if frame.absorbOverflowBar then frame.absorbOverflowBar:Hide() end
                        if frame.defensiveIcon then frame.defensiveIcon:Hide() end
                        DF:HideTestBossDebuffs(frame)
                        if DF.HideAllTargetedSpells then
                            DF:HideAllTargetedSpells(frame)
                        end
                    end
                end
                if DF.testRaidContainer then
                    DF.testRaidContainer:Hide()
                end
                if DF.HideTestPersonalTargetedSpells then
                    DF:HideTestPersonalTargetedSpells()
                end
                -- Hide group labels
                if DF.raidGroupLabels then
                    for g = 1, 8 do
                        if DF.raidGroupLabels[g] then
                            DF.raidGroupLabels[g]:Hide()
                            if DF.raidGroupLabels[g].shadow then
                                DF.raidGroupLabels[g].shadow:Hide()
                            end
                        end
                    end
                end
            end
            
            print("|cffff9900DandersFrames:|r " .. L["Test mode ended — entering combat."])
            
            -- Switch from test mode state drivers ([combat] conditions) to group
            -- transition drivers ([group:raid] conditions) so frames stay visible
            -- when combat ends (avoids flicker before UpdateHeaderVisibility runs)
            DF:SetGroupTransitionStateDrivers()
            
            -- Update GUI buttons to reflect test mode is no longer active
            if DF.GUI then
                if DF.GUI.UpdateTestButtonState then DF.GUI.UpdateTestButtonState() end
                if DF.GUI.UpdateLockButtonState then DF.GUI.UpdateLockButtonState() end
            end
        end
        
        -- Debug (use /df debugrole to enable)
        if DF.debugRoleIcons then
            print("|cff00ffffDF ROLE:|r PLAYER_REGEN_DISABLED (entering combat)")
        end
        -- Update role icons (in case hideInCombat is enabled)
        if DF.UpdateAllRoleIcons then
            DF:UpdateAllRoleIcons()
        end
        -- Update aura click-through state (for click-through in combat setting)
        if DF.UpdateAuraClickThrough then
            DF:UpdateAuraClickThrough()
        end
        -- Snapshot raid buff auras before combat lockdown hides spell IDs
        if DF.SnapshotRaidBuffAuras then
            DF:SnapshotRaidBuffAuras()
        end
        -- Refresh auras so combat-aware blacklist filters apply immediately
        if DF.RefreshAllVisibleFrames then
            DF:RefreshAllVisibleFrames()
        end
        -- Update permanent mover combat state (color/visibility) — delayed to run
        -- after any deferred frame refreshes that might reset backdrop colors
        if DF.UpdatePermanentMoverCombatState then
            C_Timer.After(0.05, function() DF:UpdatePermanentMoverCombatState() end)
        end

    elseif event == "PLAYER_UPDATE_RESTING" then
        -- Update rested indicator on player frame
        if DF.UpdateRestedIndicator then
            DF:UpdateRestedIndicator()
        end
    end
end

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    return DF._MainEventDispatcher(self, event, arg1)
end)

-- ============================================================
-- UPDATE ALL
-- ============================================================

function DF:UpdateAll()
    if InCombatLockdown() then
        DF.needsUpdate = true
        return
    end
    
    DF:SyncLinkedSections()

    -- Invalidate aura layout so all frames re-apply layout on next aura update
    DF:InvalidateAuraLayout()
    
    if DF.debugSliderUpdates then
        print("|cffffff00[DF Slider]|r >>> UpdateAll() <<<")
    end
    
    -- Update color curves for gradient mode
    if DF.UpdateColorCurve then
        DF:UpdateColorCurve()
    end
    
    -- Clear expiring curve cache (colors may have changed)
    DF.expiringCurves = nil
    
    -- Check which mode we're editing in the GUI
    local editingRaid = DF.GUI and DF.GUI.SelectedMode == "raid"
    
    -- Update frames based on what's active
    if DF.raidTestMode then
        -- In raid test mode, update raid frames
        if DF.UpdateRaidTestFrames then
            DF:UpdateRaidTestFrames()
        end
        -- Update targeted spell test icons
        if DF.UpdateAllTestTargetedSpell then
            DF:UpdateAllTestTargetedSpell()
        end
    elseif DF.testMode then
        -- In party test mode, update party frames
        if DF.UpdateAllFrames then
            DF:UpdateAllFrames()
        end
        if DF.RefreshTestFrames then
            DF:RefreshTestFrames()
        end
        -- Update targeted spell test icons
        if DF.UpdateAllTestTargetedSpell then
            DF:UpdateAllTestTargetedSpell()
        end
    elseif editingRaid then
        -- Editing raid settings (not in test mode), update raid layout
        if DF.UpdateRaidLayout then
            DF:UpdateRaidLayout()
        end
    elseif IsInRaid() and not (DF.IsInArena and DF:IsInArena()) then
        -- In a live raid: update raid layout AND header visibility
        -- (UpdateHeaderVisibility may also fire from Headers.lua's REGEN handler
        -- via pendingVisibilityUpdate — that's harmless, the call is idempotent)
        if DF.UpdateRaidLayout then
            DF:UpdateRaidLayout()
        end
        if DF.UpdateHeaderVisibility then
            DF:UpdateHeaderVisibility()
        end
    else
        -- Default: update party frames
        if DF.UpdateAllFrames then
            DF:UpdateAllFrames()
        end
        -- Update rested indicator
        if DF.UpdateRestedIndicator then
            DF:UpdateRestedIndicator()
        end
    end
    
    -- FIX 2025-01-20: Refresh private aura anchors (boss debuffs) when settings change
    -- This is needed for profile switches where overlay size may have changed
    if DF.RefreshAllPrivateAuraAnchors then
        DF:RefreshAllPrivateAuraAnchors()
    end
end

-- ============================================================
-- FULL PROFILE REFRESH
-- Called when profiles are created, imported, reset, or switched
-- Updates BOTH party and raid frames regardless of current mode
-- ============================================================

function DF:FullProfileRefresh()
    if InCombatLockdown() then
        DF.needsUpdate = true
        return
    end
    
    -- Get both databases
    local partyDB = DF.db and DF.db.party or DF:GetDB()
    local raidDB = DF.db and DF.db.raid or DF:GetRaidDB()

    -- === MIGRATE IMPORTED/SWITCHED PROFILE SETTINGS ===
    -- Handle old resourceBarHealerOnly for imported profiles
    if partyDB and partyDB.resourceBarHealerOnly ~= nil then
        if partyDB.resourceBarHealerOnly then
            partyDB.resourceBarShowHealer = true
            partyDB.resourceBarShowTank = false
            partyDB.resourceBarShowDPS = false
        else
            partyDB.resourceBarShowHealer = true
            partyDB.resourceBarShowTank = true
            partyDB.resourceBarShowDPS = true
        end
        partyDB.resourceBarHealerOnly = nil
    end
    if raidDB and raidDB.resourceBarHealerOnly ~= nil then
        if raidDB.resourceBarHealerOnly then
            raidDB.resourceBarShowHealer = true
            raidDB.resourceBarShowTank = false
            raidDB.resourceBarShowDPS = false
        else
            raidDB.resourceBarShowHealer = true
            raidDB.resourceBarShowTank = true
            raidDB.resourceBarShowDPS = true
        end
        raidDB.resourceBarHealerOnly = nil
    end

    -- === CLEAR CACHES ===
    -- Invalidate aura layout (settings may have changed)
    DF:InvalidateAuraLayout()

    -- Rebuild aura filter strings from the new profile's settings
    if DF.RebuildDirectFilterStrings then
        DF:RebuildDirectFilterStrings()
    end

    -- Re-initialize aura source mode for the new profile
    -- Uses SetAuraSourceMode which forces a full teardown + reinit, clearing
    -- stale caches and restoring Blizzard frame events when switching modes.
    if DF.SetAuraSourceMode then
        local partyMode = DF.db.party and DF.db.party.auraSourceMode
        local raidMode = DF.db.raid and DF.db.raid.auraSourceMode
        local needsDirect = (partyMode == "DIRECT") or (raidMode == "DIRECT")
        DF:SetAuraSourceMode(needsDirect and "DIRECT" or "BLIZZARD")
    end

    -- Clear color curves (colors may have changed)
    if DF.UpdateColorCurve then
        DF:UpdateColorCurve()
    end
    DF.expiringCurves = nil

    -- Clear category lookup cache (for export/import)
    DF._categoryLookup = nil
    
    -- === UPDATE PARTY CONTAINER POSITION AND SIZE ===
    if DF.container then
        local scale = partyDB.frameScale or 1.0
        DF.container:SetScale(scale)
        DF.container:ClearAllPoints()
        DF.container:SetPoint("CENTER", UIParent, "CENTER", (partyDB.anchorX or 0) / scale, (partyDB.anchorY or 0) / scale)

        -- Recalculate container size for new profile's frame dimensions/orientation
        -- (mirrors SetPartyOrientation in Headers.lua)
        local fw = partyDB.frameWidth or 120
        local fh = partyDB.frameHeight or 50
        local sp = partyDB.frameSpacing or 2
        local maxCount = 5
        if partyDB.growDirection == "HORIZONTAL" then
            DF.container:SetSize(maxCount * (fw + sp) - sp, fh)
        else
            DF.container:SetSize(fw, maxCount * (fh + sp) - sp)
        end
    end

    -- === UPDATE RAID CONTAINER POSITION ===
    -- Use UpdateRaidContainerPosition so raidMoverFrame and testRaidContainer
    -- are synced in the same call (and CENTER-anchor compensation is applied).
    -- Falls back to direct SetPoint if the function isn't loaded yet.
    if DF.raidContainer then
        local scale = raidDB.frameScale or 1.0
        DF:Debug("RAIDPOS", "FullProfileRefresh: applying raid container pos (%.1f,%.1f) scale=%.3f autoActive=%s",
            raidDB.raidAnchorX or 0, raidDB.raidAnchorY or 0, scale,
            tostring(DF.AutoProfilesUI and DF.AutoProfilesUI.activeRuntimeProfile and DF.AutoProfilesUI.activeRuntimeProfile.name or "none"))
        if DF.UpdateRaidContainerPosition and not InCombatLockdown() then
            DF:UpdateRaidContainerPosition()
        else
            -- Combat fallback: move only the secure container (mover/test container
            -- can't be modified in combat anyway)
            DF.raidContainer:SetScale(scale)
            DF.raidContainer:ClearAllPoints()
            DF.raidContainer:SetPoint("CENTER", UIParent, "CENTER", (raidDB.raidAnchorX or 0) / scale, (raidDB.raidAnchorY or 0) / scale)
        end
    end
    
    -- === FORCE UPDATE INDIVIDUAL FRAMES VIA ITERATORS ===
    if DF.ApplyFrameStyle then
        -- Party frames via iterator
        if DF.IteratePartyFrames then
            DF:IteratePartyFrames(function(frame)
                DF:ApplyFrameStyle(frame)
            end)
        end
        
        -- Raid frames via iterator
        if DF.IterateRaidFrames then
            DF:IterateRaidFrames(function(frame)
                DF:ApplyFrameStyle(frame)
            end)
        end
        
        -- Pinned frames
        if DF.PinnedFrames and DF.PinnedFrames.initialized and DF.PinnedFrames.headers then
            for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
                local header = DF.PinnedFrames.headers[setIndex]
                if header then
                    for i = 1, 40 do
                        local child = header:GetAttribute("child" .. i)
                        if child then
                            DF:ApplyFrameStyle(child)
                        end
                    end
                end
            end
        end
    end
    
    -- === RECONFIGURE HEADER ORIENTATION ===
    -- Must be called before layout updates so headers use the new profile's
    -- growDirection, growthAnchor, and selfPosition settings
    if DF.ApplyHeaderSettings then
        DF:ApplyHeaderSettings()
    end

    -- === UPDATE LAYOUTS ===
    -- Update party layout (this handles positioning, visibility, etc.)
    if DF.UpdateAllFrames then
        DF:UpdateAllFrames()
    end
    
    -- Update raid layout
    if DF.UpdateRaidLayout then
        DF:UpdateRaidLayout()
    end

    -- Re-apply Aura Designer indicators from the new profile.  AD indicators are
    -- built from the live config and version-gated, so on a profile swap they
    -- keep the previous profile's look until /reload.  ForceRefreshAllFrames
    -- bumps adConfigVersion (forces every indicator to reconfigure) and
    -- pre-warms all frames' indicators.  Safe here — FullProfileRefresh already
    -- bailed out above if in combat.
    if DF.AuraDesigner and DF.AuraDesigner.Engine and DF.AuraDesigner.Engine.ForceRefreshAllFrames then
        DF.AuraDesigner.Engine:ForceRefreshAllFrames()
    end

    -- === REFRESH FLATRAIDFRAMES IF ACTIVE ===
    if DF.FlatRaidFrames then
        if DF.FlatRaidFrames.initialized then
            local raidDb = DF:GetRaidDB()
            if not raidDb.raidUseGroups then
                DF.FlatRaidFrames:ApplyLayoutSettings()
                DF.FlatRaidFrames:ResizeInnerContainer()
            end
        end
    end
    
    -- === REFRESH PINNED FRAMES IF ACTIVE ===
    if DF.PinnedFrames and DF.PinnedFrames.initialized then
        -- Sync each set's visibility to the NEW profile FIRST — hide sets it
        -- disables, show/create sets it enables — so a set shown under the
        -- previous profile doesn't linger in a stale state after the switch.
        if DF.PinnedFrames.RefreshEnabledState then
            DF.PinnedFrames:RefreshEnabledState()
        end
        for setIndex = 1, (DF.PinnedFrames.MAX_SETS or 4) do
            if DF.PinnedFrames.headers[setIndex] then
                DF.PinnedFrames:ApplyLayoutSettings(setIndex)
                DF.PinnedFrames:ResizeContainer(setIndex)
                DF.PinnedFrames:UpdateLabel(setIndex)
            end
        end
    end
    
    -- === SYNC HEADER VISIBILITY ===
    -- Replaces the previous UpdateLiveRaidFrames call. Auto profiles may change
    -- raidUseGroups, which requires toggling between flat and grouped headers.
    -- UpdateHeaderVisibility handles the full party/raid/arena visibility matrix
    -- and calls UpdateRaidHeaderVisibility internally.
    if DF.UpdateHeaderVisibility then
        DF:UpdateHeaderVisibility()
    end

    -- === POST-SWITCH LAYOUT SETTLE ===
    -- After a profile switch the headers are shown/hidden correctly, but their
    -- sorting attributes (groupFilter, nameList, sortMethod) may reflect the old
    -- profile. ApplyRaidGroupSorting rebuilds them from the new profile's settings.
    -- The deferred TriggerRaidPosition fires after SecureGroupHeaderTemplate has
    -- finished processing all attribute changes, giving a clean final reposition.
    local raidDbSettle = DF:GetRaidDB()
    if IsInRaid() or DF.raidTestMode then
        if raidDbSettle and raidDbSettle.raidUseGroups then
            if DF.ApplyRaidGroupSorting then
                DF:ApplyRaidGroupSorting()
            end
            C_Timer.After(0, function()
                if not InCombatLockdown() and DF.TriggerRaidPosition then
                    DF:TriggerRaidPosition()
                end
            end)
        elseif DF.FlatRaidFrames and DF.FlatRaidFrames.initialized then
            C_Timer.After(0, function()
                if not InCombatLockdown() then
                    DF.FlatRaidFrames:UpdateNameList()
                end
            end)
        end
    end

    -- === UPDATE TEST FRAMES IF ACTIVE ===
    -- Use full layout refresh so test frames re-read all settings through the
    -- proxy — picks up runtime auto-layout overrides or restored base values.
    if (DF.testMode or DF.raidTestMode) and DF.RefreshTestFramesWithLayout then
        DF:RefreshTestFramesWithLayout()
    elseif DF.testMode and DF.RefreshTestFrames then
        DF:RefreshTestFrames()
    elseif DF.raidTestMode and DF.UpdateRaidTestFrames then
        DF:UpdateRaidTestFrames()
    end
    
    -- === UPDATE PET FRAMES ===
    if DF.UpdateAllPetFrames then
        DF:UpdateAllPetFrames(true)  -- force: profile refresh
    end
    if DF.UpdateAllRaidPetFrames then
        DF:UpdateAllRaidPetFrames(true)  -- force: profile refresh
    end
    
    -- === REFRESH ELEMENT APPEARANCES (colors, alpha, etc.) ===
    if DF.UpdateAllFrameAppearances then
        DF:UpdateAllFrameAppearances()
    end
    
    -- Bump AD config version so indicators reconfigure with new profile settings
    DF.adConfigVersion = (DF.adConfigVersion or 0) + 1

    -- === REFRESH AURAS ===
    if DF.UpdateAllAuras then
        DF:UpdateAllAuras()
    end
    
    -- === REFRESH PRIVATE AURAS ===
    if DF.RefreshAllPrivateAuraAnchors then
        DF:RefreshAllPrivateAuraAnchors()
    end
    
    -- === UPDATE RESTED INDICATOR ===
    if DF.UpdateRestedIndicator then
        DF:UpdateRestedIndicator()
    end
    
    -- === REFRESH NAME TRUNCATION ===
    -- UpdateAllFrames only pushes attribute changes; name truncation requires
    -- a full visible-frame pass to recalculate text widths.
    if DF.RefreshAllVisibleFrames then
        DF:RefreshAllVisibleFrames()
    end

    -- === UPDATE MINIMAP BUTTON ===
    if DF.UpdateMinimapButton then
        DF:UpdateMinimapButton()
    end

    -- === CLEAR GLOBAL FONT TEMP ===
    -- Force the Global Fonts page to re-read current DB values on next visit,
    -- so its dropdowns reflect any settings reset since the last page build.
    DF.GlobalFontTemp = nil

    -- === REFRESH GUI IF OPEN ===
    -- Invalidate all page caches first so each page rebuilds with the new
    -- profile's db reference rather than reusing stale captured closures.
    if DF.GUI and DF.GUI.InvalidateAllPages then
        DF.GUI:InvalidateAllPages()
    end
    if DF.GUIFrame and DF.GUIFrame:IsShown() then
        -- Re-sync sidebar category expand/collapse state to the new profile
        -- (categories read their state only at creation, so this is needed to
        -- reflect the switch without a /reload).
        if DF.GUI and DF.GUI.RefreshCategoryStates then
            DF.GUI:RefreshCategoryStates()
        end
        if DF.GUI and DF.GUI.RefreshCurrentPage then
            DF.GUI:RefreshCurrentPage()
        end
    end
end

-- ============================================================
-- WIZARD SETTINGS APPLICATION
-- Used by the popup wizard system to apply data-driven settings
-- maps from user-created wizards (WizardBuilder)
-- ============================================================

local strsplit = strsplit

-- Set a DB value using dot-notation path (e.g., "party.frameWidth")
function DF:SetDBKeyByPath(path, value)
    local mode, key = path:match("^(%w+)%.(.+)$")
    if mode and key and DF.db and DF.db[mode] then
        DF.db[mode][key] = value
    end
end

-- Get a DB value using dot-notation path
function DF:GetDBKeyByPath(path)
    local mode, key = path:match("^(%w+)%.(.+)$")
    if mode and key and DF.db and DF.db[mode] then
        return DF.db[mode][key]
    end
    return nil
end

-- Apply a wizard's settingsMap based on collected answers
-- settingsMap format: { stepId = { answerValue = { ["mode.dbKey"] = newValue, ... } } }
function DF:ApplyWizardSettingsMap(settingsMap, answers)
    if not settingsMap or not answers then return end

    for stepId, answerValue in pairs(answers) do
        local stepMap = settingsMap[stepId]
        if stepMap then
            if type(answerValue) == "table" then
                -- Multi-select: apply settings for each selected value
                for _, val in ipairs(answerValue) do
                    local changes = stepMap[val]
                    if changes then
                        for dbKeyPath, newValue in pairs(changes) do
                            DF:SetDBKeyByPath(dbKeyPath, newValue)
                        end
                    end
                end
            else
                -- Single-select: apply settings for the selected value
                local changes = stepMap[answerValue]
                if changes then
                    for dbKeyPath, newValue in pairs(changes) do
                        DF:SetDBKeyByPath(dbKeyPath, newValue)
                    end
                end
            end
        end
    end

    -- Refresh everything after applying settings
    DF:UpdateAll("WizardApply")
end

-- ============================================================
-- MINIMAP BUTTON (using LibDBIcon)
-- ============================================================

local LibDBIcon = LibStub("LibDBIcon-1.0", true)
local minimapButtonRegistered = false

-- LibDataBroker data object for the minimap button
local LDB = LibStub("LibDataBroker-1.1"):NewDataObject("DandersFrames", {
    type = "launcher",
    text = "DandersFrames",
    icon = "Interface\\AddOns\\DandersFrames\\Media\\DF_Icon",
    OnClick = function(self, button)
        if button == "LeftButton" then
            DF:ToggleGUI()
        elseif button == "RightButton" then
            -- Quick toggle solo mode
            local db = DF:GetDB()
            if db.soloMode ~= nil then
                db.soloMode = not db.soloMode
                DF:UpdateAllFrames()
                print("|cff00ff00DandersFrames:|r " .. format(L["Solo mode %s"], db.soloMode and L["enabled"] or L["disabled"]))
            end
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("DandersFrames")
        tooltip:AddLine("|cffffffffLeft-Click:|r Open settings", 0.8, 0.8, 0.8)
        tooltip:AddLine("|cffffffffRight-Click:|r Toggle solo mode", 0.8, 0.8, 0.8)
    end,
})

-- ============================================================
-- ADDON COMPARTMENT
-- Registers DandersFrames in Blizzard's addon compartment button
-- ============================================================

local addonCompartmentRegistered = false

function DF:CreateAddonCompartment()
    if addonCompartmentRegistered then return end
    if not AddonCompartmentFrame then return end

    AddonCompartmentFrame:RegisterAddon({
        text = "DandersFrames",
        icon = "Interface\\AddOns\\DandersFrames\\Media\\DF_Icon",
        registerForAnyClick = true,
        notCheckable = true,
        func = function(button, menuInputData, menu)
            if menuInputData.buttonName == "LeftButton" then
                DF:ToggleGUI()
            elseif menuInputData.buttonName == "RightButton" then
                local db = DF:GetDB()
                if db.soloMode ~= nil then
                    db.soloMode = not db.soloMode
                    DF:UpdateAllFrames()
                    print("|cff00ff00DandersFrames:|r " .. format(L["Solo mode %s"], db.soloMode and L["enabled"] or L["disabled"]))
                end
            end
        end,
        funcOnEnter = function(button)
            -- 12.0.7 deprecates MenuUtil.ShowTooltip/HideTooltip in favour of
            -- the *Ex variants taking an explicit tooltip (the old ones only
            -- survive behind the loadDeprecationFallbacks CVar). Feature-detect
            -- so both 12.0.5 and 12.0.7 work.
            local fill = function(tooltip)
                tooltip:AddLine("DandersFrames")
                tooltip:AddLine("|cffffffffLeft-Click:|r Open settings", 0.8, 0.8, 0.8)
                tooltip:AddLine("|cffffffffRight-Click:|r Toggle solo mode", 0.8, 0.8, 0.8)
            end
            if MenuUtil.ShowTooltipEx then
                MenuUtil.ShowTooltipEx(button, GetAppropriateTooltip(), fill)
            else
                MenuUtil.ShowTooltip(button, fill)
            end
        end,
        funcOnLeave = function(button)
            if MenuUtil.HideTooltipEx then
                MenuUtil.HideTooltipEx(button, GetAppropriateTooltip())
            else
                MenuUtil.HideTooltip(button)
            end
        end,
    })

    addonCompartmentRegistered = true
end

function DF:CreateMinimapButton()
    if minimapButtonRegistered then return end
    if not LibDBIcon then return end
    
    local db = DF:GetDB()
    
    -- Initialize minimap button saved variables if needed
    if not db.minimapIcon then
        db.minimapIcon = {
            hide = false,
            minimapPos = 220,
        }
    end
    
    LibDBIcon:Register("DandersFrames", LDB, db.minimapIcon)
    minimapButtonRegistered = true
end

function DF:UpdateMinimapButton()
    local db = DF:GetDB()
    
    if not LibDBIcon then return end
    
    -- Ensure minimap button is created
    if not minimapButtonRegistered then
        DF:CreateMinimapButton()
    end
    
    if db.showMinimapButton then
        if db.minimapIcon then
            db.minimapIcon.hide = false
        end
        LibDBIcon:Show("DandersFrames")
    else
        if db.minimapIcon then
            db.minimapIcon.hide = true
        end
        LibDBIcon:Hide("DandersFrames")
    end
end

-- ========================================
-- Hide/Show Default Player Frame
-- ========================================
function DF:UpdateDefaultPlayerFrame()
    local db = DF:GetDB()
    if not db then return end
    
    -- Hide default player frame when the option is checked (independent of solo mode)
    local shouldHide = db.hideDefaultPlayerFrame
    
    if shouldHide then
        -- Hide the default player frame using the standard method
        if PlayerFrame and not InCombatLockdown() then
            PlayerFrame:Hide()
            DF.playerFrameHiddenByUs = true  -- Track that WE hid it
            -- Use a hook to keep it hidden
            if not DF.playerFrameHooked then
                hooksecurefunc(PlayerFrame, "Show", function(self)
                    local db = DF:GetDB()
                    if db and db.hideDefaultPlayerFrame then
                        if not InCombatLockdown() then
                            self:Hide()
                        end
                    end
                end)
                DF.playerFrameHooked = true
            end
        end
    else
        -- Only show the player frame if WE previously hid it
        -- Avoids unnecessarily triggering Blizzard's PetFrame update code
        -- which has bugs with secret values during MC scenarios
        if DF.playerFrameHiddenByUs and PlayerFrame and not InCombatLockdown() then
            PlayerFrame:Show()
            DF.playerFrameHiddenByUs = false
        end
    end
end

-- Initialize minimap button and addon compartment after PLAYER_LOGIN
C_Timer.After(1, function()
    local db = DF:GetDB()
    if db and db.showMinimapButton then
        DF:CreateMinimapButton()
    end
    DF:CreateAddonCompartment()
end)

-- ============================================================
-- PUBLIC API FOR OTHER ADDONS
-- ============================================================

DandersFrames.Api = DandersFrames.Api or {}

-- Get the frame currently displaying a specific unit
-- unit: e.g. "player", "party1", "party2", "raid1", "raid15", etc.
-- kind: "party" or "raid"
-- Note: "player" in kind == "party" refers to the player in the party frame, not a separate player frame
-- Returns the frame object or nil if not found
function DandersFrames.Api.GetFrameForUnit(unit, kind)
    if not unit then return nil end
    
    local foundFrame = nil
    
    if kind == "party" then
        -- Search party frames (player + party1-4) via iterator
        if DF.IteratePartyFrames then
            DF:IteratePartyFrames(function(frame)
                if frame.unit == unit then
                    foundFrame = frame
                end
            end)
        end
    elseif kind == "raid" then
        -- Search raid frames via iterator
        if DF.IterateRaidFrames then
            DF:IterateRaidFrames(function(frame)
                if frame.unit == unit then
                    foundFrame = frame
                end
            end)
        end
    end
    
    return foundFrame
end
