-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's. Take the parent's table from the global it publishes. See the
-- same note at the head of GUI/Panel.lua and GUI/ModuleRegistry.lua.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L

local ipairs, pairs, type = ipairs, pairs, type
local CreateFrame = CreateFrame
local concat = table.concat

-- ============================================================
-- THE MODULE RAIL AND DECK 2'S LEFT SIDE
-- The settings window's top-level navigation: an icon rail down the window's
-- left edge (UI:CreateIconRail) listing the registered modules
-- (GUI/ModuleRegistry.lua), and on deck 2 the CURRENT module's own tabs --
-- Party / Raid for Group Frames -- or, for a module with none, its name.
--
-- ☠ ITS OWN FILE ON PURPOSE. DF:CreateGUI (GUI/Panel.lua) sits close to Lua's
-- 200-locals-per-function limit, so the shell is built here and CreateGUI only
-- calls GUI:BuildModuleShell with the frames it owns.
--
-- Everything a click DOES is GUI:SelectModule's; this file only draws the
-- state SelectModule leaves behind (GUI:RefreshModuleShell, run from the
-- panel's UpdateThemeColors on every switch, page select and window show).
-- ============================================================

-- The rail's width. Every left anchor in the window that used to sit at the
-- window's edge (the nav, Binds' panel, the changelog overlay, deck 2) is
-- offset by this.
GUI.RailWidth = 62

local C_PANEL, C_BORDER = GUI.Colors.panel, GUI.Colors.border

local railKey            -- the ids the rail was last given, joined
local deckCrumb          -- deck 2's module title (modules without tabs)
local underline          -- the one underline under the current module's tabs

local function Resolve(v)
    if type(v) == "function" then return v() end
    return v
end

local function InRail(def)
    return def.alwaysInRail or not def.isEnabled or def.isEnabled() and true or false
end

-- The rail's items, rebuilt only when the set of modules shown changes.
local function SyncRailItems(rail)
    local ids, items = {}, {}
    for _, def in ipairs(GUI:GetModules()) do
        if InRail(def) then
            ids[#ids + 1] = def.id
            items[#items + 1] = {
                id = def.id,
                icon = def.icon,
                slot = def.slot,
                label = function() return Resolve(def.railLabel) or GUI:ModuleLabel(def) end,
                tooltip = function() return GUI:ModuleLabel(def) end,
                accent = def.accent,
                dividerAfter = def.dividerAfter,
            }
        end
    end
    local key = concat(ids, ",")
    if key ~= railKey then
        railKey = key
        rail:SetItems(items)
        for _, id in ipairs(ids) do rail:SetDisabled(id, GUI:IsModuleLocked(id)) end
    end
end

-- "New" on a rail item while a page it owns is in GUI.NewTabs and unseen.
-- Run on every shell refresh and from SelectTab once a page is marked seen.
function GUI:RefreshRailBadges()
    local rail = GUI.ModuleRail
    if not rail then return end
    local seen = DandersFramesDB_v2 and DandersFramesDB_v2.seenTabs
    local new = {}
    for name in pairs(GUI.NewTabs or {}) do
        if not (seen and seen[name]) and GUI.Tabs and GUI.Tabs[name] then
            local id = GUI:ModuleForPage(name)
            if id then new[id] = true end
        end
    end
    for _, id in ipairs(rail:GetItemIds()) do
        rail:SetBadge(id, new[id] and L["New"] or nil)
    end
end

-- ============================================================
-- BUILD
-- frame: the settings window. deck2: the 30px strip under the title bar,
-- already anchored right of the rail. saveWindowPos: the panel's drag-stop
-- handler, so the rail's gaps move the window like deck 2's do.
-- ============================================================
function GUI:BuildModuleShell(frame, deck2, saveWindowPos)
    local W = GUI.RailWidth
    -- x = 1 so the selection marker does not draw over the window's border.
    local rail = GUI:CreateIconRail(frame, {
        width = W - 1,
        onSelect = function(id)
            -- The changelog overlay covers deck 2 and the page but not the
            -- rail; picking a place from the rail is leaving the changelog.
            local overlay = GUI.changelogOverlay
            if overlay and overlay:IsShown() then overlay:Hide() end
            if id == GUI.CurrentModuleId() or GUI:IsModuleLocked(id) then return end
            GUI:SelectModule(id)
        end,
    })
    rail:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -30)
    rail:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 36)
    rail:SetFrameLevel(frame:GetFrameLevel() + 1)
    local bg = rail:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetAllPoints(rail)
    bg:SetVertexColor(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.35)
    local divider = rail:CreateTexture(nil, "BORDER")
    divider:SetTexture("Interface\\Buttons\\WHITE8x8")
    divider:SetPoint("TOPRIGHT", rail, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOMRIGHT", rail, "BOTTOMRIGHT", 0, 0)
    divider:SetWidth(1)
    divider:SetVertexColor(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.6)
    -- The gaps between items move the window, as deck 2's do.
    rail:EnableMouse(true)
    rail:RegisterForDrag("LeftButton")
    rail:SetScript("OnDragStart", function() frame:StartMoving() end)
    if saveWindowPos then rail:SetScript("OnDragStop", saveWindowPos) end
    GUI.ModuleRail = rail

    -- A whole-module lock (Auto Layout editing) greys the rail item.
    GUI.OnModuleLockChanged = function(id, locked) rail:SetDisabled(id, locked) end

    -- ---- deck 2: each module's own tabs ---------------------------------
    -- Shared underline-tab style, no stripe of their own: ONE underline glides
    -- between them (UI:CreateSelectionMarker), as the old mode tabs did.
    for _, def in ipairs(GUI:GetModules()) do
        if def.tabs then
            def._deckTabs = {}
            local prev
            for _, tab in ipairs(def.tabs) do
                local b = CreateFrame("Button", nil, deck2, "BackdropTemplate")
                -- The +1 lifts the 24px button off deck 2's centre onto the row
                -- the header has always used.
                if prev then
                    b:SetPoint("LEFT", prev, "RIGHT", GUI.SnapLen(b, 4), 0)
                else
                    b:SetPoint("LEFT", deck2, "LEFT", GUI.SnapLen(b, 12), 1)
                end
                GUI:StyleButton(b, {
                    tab = true, tabStripe = false,
                    text = Resolve(tab.deckLabel or tab.label),
                    accent = Resolve(tab.accent),
                    width = 70, height = 24, font = "DFFontHighlight",
                })
                local moduleId, tabId = def.id, tab.id
                b:SetScript("OnClick", function() GUI:SelectModule(moduleId, tabId) end)
                GUI:AttachModuleButton(moduleId, tabId, b)
                def._deckTabs[tabId] = b
                prev = b
            end
        end
    end
    local group = GUI:GetModule("group")
    if group and group._deckTabs then
        GUI.PartyButton = group._deckTabs.party
        GUI.RaidButton = group._deckTabs.raid
    end
    underline = GUI:CreateSelectionMarker(deck2, { axis = "x", thickness = 3 })
    GUI.ModeUnderline = underline

    -- A module with no tabs shows its name where the tabs would be.
    deckCrumb = deck2:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    deckCrumb:SetPoint("LEFT", deck2, "LEFT", 14, 1)
    deckCrumb:SetJustifyH("LEFT")
    deckCrumb:SetWordWrap(false)
    deckCrumb:Hide()
    GUI.ModuleCrumb = deckCrumb

    SyncRailItems(rail)
    return rail
end

-- ============================================================
-- REFRESH -- paint the rail and deck 2 for the module showing.
-- instant: no glide (the window is hidden).
-- ============================================================
function GUI:RefreshModuleShell(instant)
    local rail = GUI.ModuleRail
    if not rail then return end
    local cur = GUI.CurrentModuleId()
    SyncRailItems(rail)
    rail:Select(cur, instant)
    GUI:RefreshRailBadges()

    local curDef = GUI:GetModule(cur)
    local activeBtn, activeAccent
    for _, def in ipairs(GUI:GetModules()) do
        local tabs = def._deckTabs
        if tabs then
            local on = (def == curDef)
            local activeId = on and def.activeTab and def.activeTab() or nil
            for _, tab in ipairs(def.tabs) do
                local b = tabs[tab.id]
                if on then b:Show() else b:Hide() end
                local isActive = on and activeId == tab.id
                b:SetActive(isActive)
                if isActive then activeBtn, activeAccent = b, Resolve(tab.accent) end
            end
        end
    end
    if activeBtn then
        underline:SetTo(activeBtn, activeAccent, instant)
    else
        underline:Clear()
    end

    if curDef and not curDef._deckTabs then
        local c = Resolve(curDef.accent) or GUI:GetAccent()
        deckCrumb:SetText(GUI:ModuleLabel(curDef) or "")
        deckCrumb:SetTextColor(c.r, c.g, c.b)
        deckCrumb:Show()
    else
        deckCrumb:Hide()
    end
end

-- ============================================================
-- LAST PLACE
-- GUI:SyncSelectedModule (GUI/ModuleRegistry.lua) records the module showing
-- into the account window state; DF:ToggleGUI reads it BEFORE it repaints
-- (that repaint, once the window shows, records the auto-pick) and hands it
-- back here once the window is up.
--
-- ⚠ ONLY WHICH MODULE. Group Frames still opens on Party or Raid by group
-- type, exactly as before -- users rely on that.
-- ============================================================
function GUI:LastModuleOnOpen()
    local ws = DF.GetWindowState and DF:GetWindowState()
    return ws and ws.lastModule or nil
end

function GUI:RestoreModuleOnOpen(id)
    if id == "global" then
        if not GUI.GlobalView and not GUI:IsModuleLocked("global") then
            GUI:SelectModule("global")
        end
    elseif GUI:GetModule(id) and GUI:GetModule(id).placeholder then
        GUI:SelectModule(id)
    elseif id == "clicks" then
        -- Binds hides frames and drops test mode on the way in. A user who
        -- reopens with a preview up or a mover session running is looking at
        -- frames, so they land on Group Frames instead.
        if GUI:IsModuleLocked("clicks") or DF.testMode or DF.raidTestMode then return end
        local B = DF.MoverBridge
        if B and B.IsSessionActive and B:IsSessionActive() then return end
        if GUI.SelectedMode ~= "clicks" then GUI:SelectModule("clicks") end
    end
    -- "group" (or nothing saved): ToggleGUI's party/raid auto-pick already
    -- put the window there.
end

-- ============================================================
-- PLACEHOLDER PANEL -- what a rail item with no page yet shows (Home,
-- Modules, Profiles). Built once, over the same rect as the Binds panel;
-- GUI:ShowPlaceholderContent (GUI/Panel.lua) hides the sidebar and page.
-- ============================================================
function GUI:GetPlaceholderPanel()
    local panel = GUI.PlaceholderPanel
    if panel then return panel end
    local frame = DF.GUIFrame
    if not frame then return nil end
    panel = CreateFrame("Frame", nil, frame)
    panel:SetPoint("TOPLEFT", GUI.RailWidth + 12, -64)
    panel:SetPoint("BOTTOMRIGHT", -12, 36)
    panel:SetFrameLevel(frame:GetFrameLevel() + 2)

    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(48, 48)
    icon:SetPoint("CENTER", panel, "CENTER", 0, 40)
    local dim = GUI.Colors.textDim
    icon:SetVertexColor(dim.r, dim.g, dim.b)
    panel.Icon = icon

    local title = panel:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    title:SetPoint("TOP", icon, "BOTTOM", 0, -12)
    panel.Title = title

    local note = panel:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    note:SetPoint("TOP", title, "BOTTOM", 0, -6)
    note:SetTextColor(dim.r, dim.g, dim.b)
    note:SetText(L["Coming in a later update."])
    panel.Note = note

    panel:Hide()
    GUI.PlaceholderPanel = panel
    return panel
end

function GUI:PaintPlaceholderPanel(def)
    local panel = GUI:GetPlaceholderPanel()
    if not panel then return end
    panel.Icon:SetTexture(def.icon)
    panel.Title:SetText(GUI:ModuleLabel(def) or "")
    panel.Note:SetText(L["Coming in a later update."])
    panel:Show()
end
