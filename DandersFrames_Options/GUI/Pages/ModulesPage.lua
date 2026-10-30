-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's. Take the parent's table from the global it publishes. See the
-- same note at the head of GUI/Panel.lua and GUI/ModuleRegistry.lua.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L

local ipairs, pairs, type = ipairs, pairs, type
local format = string.format
local CreateFrame = CreateFrame

-- ============================================================
-- THE MODULES PAGE
-- The `modules` rail item (GUI/ModuleRegistry.lua): every module that can be
-- switched on or off, grouped On / Off / Coming soon, each row with its
-- status, a switch and an Open button. Group Frames carries a MASTER switch
-- with Party Frames and Raid Frames as indented sub-rows.
--
-- A switch writes the EXISTING setting -- DF.db.partyEnabled / raidEnabled,
-- the click-casting enable -- through the existing reload prompt. No new
-- enable flag: about 50 places read the two group flags.
--
-- ☠ ITS OWN FILE ON PURPOSE: DF:CreateGUI (GUI/Panel.lua) sits near Lua's
-- 200-locals-per-function limit.
-- ============================================================

-- ============================================================
-- GROUP FRAMES MASTER SWITCH (spec Q6)
-- The master is DERIVED: on = Party or Raid on. It only ever writes the two
-- existing flags, plus a stash of the pair it turned off.
--   master off: stash the pair in DF.db._groupFramesRestore, both false.
--   master on:  restore the stash -- or both true when there is none, or it
--               held two offs -- and clear it.
--   one sub-switch on while the master is off: just that one; the stash goes.
-- Every change runs the existing "reload to apply" prompt.
-- ⚠ `~= false` for these two keys: ABSENT MEANS ENABLED.
-- ⚠ The stash is `_`-prefixed and sits at the profile root, which no export
-- copies (DF:ExportProfile's root keys are an explicit list) -- pinned by
-- test_group_master_switch.lua.
-- ============================================================

local GF = {}
GUI.GroupFrames = GF

function GF.PartyOn()
    local db = DF.db
    return not db or db.partyEnabled ~= false
end

function GF.RaidOn()
    local db = DF.db
    return not db or db.raidEnabled ~= false
end

function GF.MasterOn()
    return GF.PartyOn() or GF.RaidOn()
end

local function PromptReload()
    if DF.PromptReloadIfEnableFlagsChanged then
        DF:PromptReloadIfEnableFlagsChanged(
            L["Enabling or disabling a frame mode requires a UI reload to take effect.\n\nReload now?"])
    end
end

function GF.SetMaster(on)
    local db = DF.db
    if not db then return end
    if on then
        if GF.MasterOn() then return end
        local stash = db._groupFramesRestore
        local party, raid = true, true
        if type(stash) == "table" and (stash.party or stash.raid) then
            party, raid = stash.party and true or false, stash.raid and true or false
        end
        db.partyEnabled, db.raidEnabled = party, raid
        db._groupFramesRestore = nil
    else
        if not GF.MasterOn() then return end
        db._groupFramesRestore = { party = GF.PartyOn(), raid = GF.RaidOn() }
        db.partyEnabled, db.raidEnabled = false, false
    end
    PromptReload()
end

-- mode: "party" | "raid".
function GF.SetMode(mode, on)
    local db = DF.db
    if not db then return end
    db[(mode == "raid") and "raidEnabled" or "partyEnabled"] = on and true or false
    if on then db._groupFramesRestore = nil end
    PromptReload()
end

-- The old Frame Modes ticks (Global > Settings) write the flags directly. Once
-- either is on again the stash describes nothing, so it goes -- the same rule
-- as a sub-switch turned on here.
function GF.Settle()
    local db = DF.db
    if db and GF.MasterOn() then db._groupFramesRestore = nil end
end

-- ============================================================
-- SWITCHES BY MODULE
-- A module may bring its own `setEnabled(on, checkbox, onDone)`; the two that
-- exist today are wired here, next to the code they drive. `onDone` runs once
-- the write has happened -- for click-casting that can be a popup later, and
-- until then the switch stays as the user left it (the popup's cancel path
-- unticks it).
-- ============================================================

local function ClickCastOn()
    local CC = DF.ClickCast
    return CC and CC.db and CC.db.enabled and true or false
end

local SWITCHES = {
    group = function(on, _, onDone)
        GF.SetMaster(on)
        if onDone then onDone() end
    end,
    -- The Binds header's own path: conflicts and the Blizzard warning are
    -- popups, and the write lands in their confirm (CC:RequestEnabled).
    clicks = function(on, checkbox, onDone)
        local CC = DF.ClickCast
        if CC and CC.RequestEnabled then
            CC:RequestEnabled(on, checkbox, onDone)
        end
    end,
}

local function SwitchFor(def)
    return def.setEnabled or SWITCHES[def.id]
end

-- The modules this page lists, in rail order, sorted into its three groups.
-- Listed: anything with a switch, and anything coming soon. Global has
-- neither (it cannot be turned off).
function GUI:ModulesPageModel()
    local on, off, soon = {}, {}, {}
    for _, def in ipairs(GUI:GetModules()) do
        if def.comingSoon then
            soon[#soon + 1] = def
        elseif SwitchFor(def) then
            if GUI:IsModuleOn(def) then on[#on + 1] = def else off[#off + 1] = def end
        end
    end
    return on, off, soon
end

-- ============================================================
-- THE VIEW
-- ============================================================

local ROW_H, SUB_H, GAP, SUB_INDENT = 46, 30, 6, 34
local C = GUI.Colors

local view                -- GUI:CreateModuleView's frame, built on first show
local W = {}              -- the page's fixed pieces
local rows = {}           -- key -> row, reused across refreshes
local headers = {}        -- group name -> header

local function Dim(fs)
    local d = C.textDim
    fs:SetTextColor(d.r, d.g, d.b)
end

local function RefreshAll()
    if GUI.RefreshModulesView then GUI:RefreshModulesView() end
    if GUI.RefreshModuleShell then GUI:RefreshModuleShell() end
    local CC = DF.ClickCast
    if CC and CC.headerEnableCb and CC.headerEnableCb.Refresh then CC.headerEnableCb:Refresh() end
end

-- A list row. Bespoke on purpose (an icon, two lines and two controls in a
-- pooled list row); its pieces are the shared ones: the element backdrop,
-- GUI:CreateCheckRow for the switch, StyleButton for Open.
local function MakeRow(sub)
    local row = CreateFrame("Frame", nil, view.body, "BackdropTemplate")
    GUI:CreateElementBackdrop(row)
    row:SetHeight(sub and SUB_H or ROW_H)

    local x = 12
    if not sub then
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(22, 22)
        icon:SetPoint("LEFT", row, "LEFT", 12, 0)
        row.Icon = icon
        x = 46
    end

    local open = CreateFrame("Button", nil, row, "BackdropTemplate")
    GUI:StyleButton(open, { text = L["Open"], width = 64, height = 22 })
    open:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    open:SetScript("OnClick", function(self)
        -- A locked module (Auto Layout editing) is refused, as on the rail.
        if self.target and not GUI:IsModulePickLocked(self.target, self.targetTab) then
            GUI:SelectModule(self.target, self.targetTab)
        end
    end)
    row.Open = open

    local switch = GUI:CreateCheckRow(row, {
        label = "",
        onClick = function(want) if row.onSwitch then row.onSwitch(want, row.Switch) end end,
    })
    switch:SetPoint("RIGHT", open, "LEFT", -14, 0)
    row.Switch = switch

    local status = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    status:SetPoint("RIGHT", switch, "LEFT", -10, 0)
    status:SetJustifyH("RIGHT")
    status:SetWordWrap(false)
    Dim(status)
    row.Status = status

    local name = row:CreateFontString(nil, "OVERLAY", sub and "DFFontHighlightSmall" or "DFFontHighlight")
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row.Name = name
    if sub then
        name:SetPoint("LEFT", row, "LEFT", x, 0)
        name:SetPoint("RIGHT", status, "LEFT", -10, 0)
    else
        name:SetPoint("TOPLEFT", row, "TOPLEFT", x, -8)
        name:SetPoint("RIGHT", status, "LEFT", -10, 0)
        local desc = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        desc:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -3)
        desc:SetPoint("RIGHT", status, "LEFT", -10, 0)
        desc:SetJustifyH("LEFT")
        desc:SetWordWrap(false)
        Dim(desc)
        row.Desc = desc
    end
    return row
end

local function GetRow(key, sub)
    local row = rows[key]
    if not row then
        row = MakeRow(sub)
        rows[key] = row
    end
    return row
end

local function GetHeader(key)
    local h = headers[key]
    if not h then
        h = view.body:CreateFontString(nil, "OVERLAY", "DFFontNormal")
        h:SetJustifyH("LEFT")
        local cc = C.textCaption or C.textDim
        h:SetTextColor(cc.r, cc.g, cc.b)
        headers[key] = h
    end
    return h
end

-- Paint one module row. on: switched on. soon: coming soon (no switch).
local function PaintModuleRow(row, def, on, soon)
    row.Icon:SetTexture(def.icon)
    row.Icon:SetAlpha(on and 1 or 0.45)
    row.Name:SetText(GUI:ModuleLabel(def) or "")
    row.Name:SetAlpha(on and 1 or 0.7)
    row.Desc:SetText(GUI:ModuleText(def, "description") or "")
    row.Status:SetText(soon and L["Coming soon"] or (on and GUI:ModuleStatus(def) or L["Off"]))
    local sw = not soon and SwitchFor(def)
    if sw then
        row.Switch:Show()
        row.Switch:SetChecked(on)
        row.onSwitch = function(want, checkbox) sw(want, checkbox, RefreshAll) end
    else
        row.Switch:Hide()
        row.onSwitch = nil
    end
    if soon then
        row.Open:Hide()
    else
        row.Open:Show()
        row.Open.target, row.Open.targetTab = def.id, nil
        row.Open:SetEnabled(on and not GUI:IsModulePickLocked(def.id))
    end
end

-- Party Frames / Raid Frames under the master.
local function PaintSubRow(row, mode)
    local on = (mode == "raid") and GF.RaidOn() or GF.PartyOn()
    row.Name:SetText(mode == "raid" and L["Raid Frames"] or L["Party Frames"])
    row.Name:SetAlpha(on and 1 or 0.7)
    row.Status:SetText(on and L["On"] or L["Off"])
    row.Switch:Show()
    row.Switch:SetChecked(on)
    row.onSwitch = function(want) GF.SetMode(mode, want); RefreshAll() end
    row.Open:Show()
    row.Open.target, row.Open.targetTab = "group", mode
    row.Open:SetEnabled(on and not GUI:IsModulePickLocked("group", mode))
end

function GUI:RefreshModulesView()
    if not (view and view:IsShown()) then return end
    local w = view.scroll:GetWidth() or 0
    if w < 50 then return end
    local body = view.body
    body:SetWidth(w)

    for _, row in pairs(rows) do row:Hide() end
    for _, h in pairs(headers) do h:Hide() end

    local y = 0
    W.title:ClearAllPoints()
    W.title:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    y = y + 24
    W.lead:ClearAllPoints()
    W.lead:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    W.lead:SetWidth(w)
    y = y + (W.lead:GetStringHeight() or 14) + 14

    local on, off, soon = GUI:ModulesPageModel()
    local groups = {
        { key = "on",   label = L["On"],          list = on },
        { key = "off",  label = L["Off"],         list = off },
        { key = "soon", label = L["Coming soon"], list = soon },
    }
    for _, g in ipairs(groups) do
        if #g.list > 0 then
            local h = GetHeader(g.key)
            h:SetText(format("%s  (%d)", g.label, #g.list))
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
            h:Show()
            y = y + 20
            for _, def in ipairs(g.list) do
                local isOn = g.key == "on"
                local row = GetRow(def.id, false)
                PaintModuleRow(row, def, isOn, g.key == "soon")
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
                row:SetWidth(w)
                row:Show()
                y = y + ROW_H + GAP
                -- Group Frames: Party and Raid, each with its own switch.
                -- Shown off with the master off, and still clickable.
                if def.id == "group" then
                    for _, mode in ipairs({ "party", "raid" }) do
                        local sr = GetRow("group:" .. mode, true)
                        PaintSubRow(sr, mode)
                        sr:ClearAllPoints()
                        sr:SetPoint("TOPLEFT", body, "TOPLEFT", SUB_INDENT, -y)
                        sr:SetWidth(w - SUB_INDENT)
                        sr:Show()
                        y = y + SUB_H + 4
                    end
                    y = y + GAP - 4
                end
            end
            y = y + 8
        end
    end

    W.note:ClearAllPoints()
    W.note:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    W.note:SetWidth(w)
    y = y + (W.note:GetStringHeight() or 14) + 8
    body:SetHeight(y)
end

local function Build()
    view = GUI:CreateModuleView(0)
    if not view then return nil end
    local body = view.body

    local title = body:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    title:SetJustifyH("LEFT")
    title:SetText(L["Modules"])
    local t = C.text
    title:SetTextColor(t.r, t.g, t.b)
    W.title = title

    local lead = body:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    lead:SetJustifyH("LEFT")
    lead:SetText(L["Turn off what you don't use. A module that is off is not set up, and its icon leaves the rail."])
    Dim(lead)
    W.lead = lead

    local note = body:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    note:SetJustifyH("LEFT")
    note:SetText(L["Turning a module on or off takes effect after a reload. Its settings are kept either way."])
    Dim(note)
    W.note = note

    -- A resize changes every width; the page is small, so re-run it whole.
    view:SetScript("OnSizeChanged", function() GUI:RefreshModulesView() end)
    return view
end

function GUI:ShowModulesView()
    if not view and not Build() then return end
    -- The old Frame Modes ticks may have turned a mode back on since.
    GF.Settle()
    view:Show()
    GUI:RefreshModulesView()
end

function GUI:HideModulesView()
    if view then view:Hide() end
end
