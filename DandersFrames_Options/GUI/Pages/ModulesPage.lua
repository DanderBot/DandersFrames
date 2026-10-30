-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's. Take the parent's table from the global it publishes. See the
-- same note at the head of GUI/Panel.lua and GUI/ModuleRegistry.lua.
local DF = DandersFrames
local GUI = DF.GUI
local L = DF.L

local ipairs, pairs, type, tostring = ipairs, pairs, type, tostring
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
-- Drawn to the approved mockup (docs/superpowers/specs/2026-10-30-settings-
-- nav-options.html, modulesPage) at the live window's scale. Rounded pieces
-- are the kit's surfaces (radii 4 / 6 / 8); colours are GUI.Colors and the
-- module accents. No filter box: the page has no filtering to drive one.
-- ============================================================

local MAX_W = 900                 -- the content column, centred
local ROW_H, SUB_H = 40, 32       -- 30px icon box + 5px padding; a sub-row
local GAP = 9                     -- between blocks
local ROW_GAP = 4                 -- between the rows of a group
local ICON_BOX, ICON_GLYPH = 30, 18
local SUB_INDENT = 40             -- Party / Raid sit under Group Frames' name
local ICONS = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\"
local C = GUI.Colors

local view                -- GUI:CreateModuleView's frame, built on first show
local W = {}              -- the page's fixed pieces
local rows = {}           -- key -> row, reused across refreshes
local headers = {}        -- group name -> header

local function Tint(fs, c, a)
    fs:SetTextColor(c.r, c.g, c.b, a or 1)
end

local function RGBA(c, a)
    return { c.r, c.g, c.b, a or 1 }
end

local function Label(parent, size, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlight")
    GUI:SetSettingsFont(fs, size)
    fs:SetJustifyH("LEFT")
    Tint(fs, color or C.text)
    return fs
end

local function ModAccent(def)
    local a = def and def.accent
    if type(a) == "function" then a = a() end
    return a or GUI:GetAccent()
end

-- Gold (the mockup's --gold): the kit's caution tone, the one gold it has.
local function Gold()
    local g = GUI.GetToneColor and GUI:GetToneColor("caution") or nil
    if g then return { r = g[1] or g.r, g = g[2] or g.g, b = g[3] or g.b } end
    return C.notice
end

local function RefreshAll()
    if GUI.RefreshModulesView then GUI:RefreshModulesView() end
    if GUI.RefreshModuleShell then GUI:RefreshModuleShell() end
    local CC = DF.ClickCast
    if CC and CC.headerEnableCb and CC.headerEnableCb.Refresh then CC.headerEnableCb:Refresh() end
end

-- A list row. Bespoke on purpose (an icon box, two lines and two controls in
-- a pooled list row); its pieces are the shared ones: the kit's rounded
-- surface, GUI:CreateCheckRow for the switch (the kit has no pill switch, so
-- the shared checkbox stands in, tinted in the module's accent), StyleButton
-- for Open.
local function MakeRow(sub)
    local row = CreateFrame("Frame", nil, view.body)
    row:SetHeight(sub and SUB_H or ROW_H)
    row.plate = GUI:CreateRoundedSurface(row, { radius = 6, fill = RGBA(C.panel, 1), border = RGBA(C.border, 0.7) })

    local x = 12
    if not sub then
        local box = CreateFrame("Frame", nil, row)
        box:SetSize(ICON_BOX, ICON_BOX)
        box:SetPoint("LEFT", row, "LEFT", 10, 0)
        box.surface = GUI:CreateRoundedSurface(box, { radius = 6, border = false, fill = RGBA(C.text, 0.05) })
        local icon = box:CreateTexture(nil, "ARTWORK")
        icon:SetSize(ICON_GLYPH, ICON_GLYPH)
        icon:SetPoint("CENTER", box, "CENTER", 0, 0)
        row.Box, row.Icon = box, icon
        x = 10 + ICON_BOX + 12
    end

    local open = CreateFrame("Button", nil, row, "BackdropTemplate")
    GUI:StyleButton(open, { text = L["Open"], width = 62, height = 24 })
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
    switch:SetPoint("RIGHT", open, "LEFT", -12, 0)
    row.Switch = switch

    -- Coming soon: a gold tag where the switch would be.
    local soon = Label(row, 10, Gold())
    soon:SetPoint("RIGHT", open, "LEFT", -12, 0)
    soon:Hide()
    row.Soon = soon

    local status = Label(row, 11, C.textDim)
    status:SetPoint("RIGHT", switch, "LEFT", -12, 0)
    status:SetJustifyH("RIGHT")
    status:SetWordWrap(false)
    row.Status = status

    local name = Label(row, sub and 12 or 13, C.text)
    name:SetWordWrap(false)
    row.Name = name
    if sub then
        name:SetPoint("LEFT", row, "LEFT", x, 0)
        name:SetPoint("RIGHT", status, "LEFT", -10, 0)
    else
        name:SetPoint("BOTTOMLEFT", row, "LEFT", x, 1)
        name:SetPoint("RIGHT", status, "LEFT", -10, 0)
        local desc = Label(row, 11, C.textDim)
        desc:SetPoint("TOPLEFT", row, "LEFT", x, -2)
        desc:SetPoint("RIGHT", status, "LEFT", -10, 0)
        desc:SetWordWrap(false)
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

-- "ON  3": 11px uppercase caption, the count dim beside it.
local function GetHeader(key)
    local h = headers[key]
    if not h then
        h = Label(view.body, 11, C.textCaption or C.textDim)
        h.Count = Label(view.body, 11, C.textDim)
        h.Count:SetPoint("BOTTOMLEFT", h, "BOTTOMRIGHT", 6, 0)
        headers[key] = h
    end
    return h
end

-- An off row has no fill (the plate's ring only) and a greyed icon box.
local function PaintPlate(row, on)
    row.plate:SetFillShown(on and true or false)
    local b = C.border
    row.plate:SetBorderColor(b.r, b.g, b.b, 0.7)
end

-- Paint one module row. on: switched on. soon: coming soon (no switch).
local function PaintModuleRow(row, def, on, soon)
    local a = ModAccent(def)
    PaintPlate(row, on)
    row.Icon:SetTexture(def.icon)
    if on then
        row.Box.surface:SetFillColor(a.r, a.g, a.b, 0.18)
        row.Icon:SetVertexColor(a.r, a.g, a.b)
        row.Icon:SetAlpha(1)
    else
        row.Box.surface:SetFillColor(C.text.r, C.text.g, C.text.b, 0.05)
        row.Icon:SetVertexColor(C.textDim.r, C.textDim.g, C.textDim.b)
        row.Icon:SetAlpha(0.6)
    end
    row.Name:SetText(GUI:ModuleLabel(def) or "")
    row.Name:SetAlpha(on and 1 or 0.7)
    row.Desc:SetText(GUI:ModuleText(def, "description") or "")
    -- The status only where it says something: an off row's switch already
    -- says Off, and a coming-soon row has its tag.
    row.Status:SetText((on and not soon) and GUI:ModuleStatus(def) or "")
    local sw = not soon and SwitchFor(def)
    if sw then
        row.Switch:Show()
        row.Switch:SetChecked(on)
        if row.Switch.ApplyThemeColor then row.Switch.ApplyThemeColor(a) end
        row.onSwitch = function(want, checkbox) sw(want, checkbox, RefreshAll) end
    else
        row.Switch:Hide()
        row.onSwitch = nil
    end
    row.Soon:SetShown(soon and true or false)
    if soon then row.Soon:SetText(string.upper(L["Coming soon"])) end
    -- Open only on a module that is on (the mockup hides it on the rest).
    row.Open.target, row.Open.targetTab = def.id, nil
    row.Open:SetShown(on and not soon)
    row.Open:SetEnabled(on and not GUI:IsModulePickLocked(def.id))
end

-- Party Frames / Raid Frames under the master, each in its own accent.
local function PaintSubRow(row, mode)
    local on = (mode == "raid") and GF.RaidOn() or GF.PartyOn()
    local a = GUI.GetThemeColorFor and GUI.GetThemeColorFor(mode == "raid") or GUI:GetAccent()
    PaintPlate(row, on)
    row.Name:SetText(mode == "raid" and L["Raid Frames"] or L["Party Frames"])
    row.Name:SetAlpha(on and 1 or 0.7)
    row.Status:SetText("")
    row.Soon:Hide()
    row.Switch:Show()
    row.Switch:SetChecked(on)
    if row.Switch.ApplyThemeColor then row.Switch.ApplyThemeColor(a) end
    row.onSwitch = function(want) GF.SetMode(mode, want); RefreshAll() end
    row.Open.target, row.Open.targetTab = "group", mode
    row.Open:SetShown(on)
    row.Open:SetEnabled(on and not GUI:IsModulePickLocked("group", mode))
end

function GUI:RefreshModulesView()
    if not (view and view:IsShown()) then return end
    local w = view.scroll:GetWidth() or 0
    if w < 50 then return end
    local body = view.body
    body:SetWidth(w)
    local cw = math.min(w, MAX_W)
    local x0 = math.floor((w - cw) / 2)

    for _, row in pairs(rows) do row:Hide() end
    for _, h in pairs(headers) do h:Hide(); h.Count:Hide() end

    local y = 0
    W.title:ClearAllPoints()
    W.title:SetPoint("TOPLEFT", body, "TOPLEFT", x0, -y)
    y = y + 22 + 3
    W.lead:ClearAllPoints()
    W.lead:SetPoint("TOPLEFT", body, "TOPLEFT", x0, -y)
    W.lead:SetWidth(cw)
    y = y + (W.lead:GetStringHeight() or 14) + GAP + 6

    local on, off, soon = GUI:ModulesPageModel()
    local groups = {
        { key = "on",   label = L["On"],          list = on },
        { key = "off",  label = L["Off"],         list = off },
        { key = "soon", label = L["Coming soon"], list = soon },
    }
    for _, g in ipairs(groups) do
        if #g.list > 0 then
            local h = GetHeader(g.key)
            h:SetText(string.upper(g.label))
            h.Count:SetText(tostring(#g.list))
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", body, "TOPLEFT", x0, -y)
            h:Show()
            h.Count:Show()
            y = y + 14 + ROW_GAP
            for _, def in ipairs(g.list) do
                local isOn = g.key == "on"
                local row = GetRow(def.id, false)
                PaintModuleRow(row, def, isOn, g.key == "soon")
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", body, "TOPLEFT", x0, -y)
                row:SetWidth(cw)
                row:Show()
                y = y + ROW_H + ROW_GAP
                -- Group Frames: Party and Raid, each with its own switch.
                -- Shown off with the master off, and still clickable.
                if def.id == "group" then
                    for _, mode in ipairs({ "party", "raid" }) do
                        local sr = GetRow("group:" .. mode, true)
                        PaintSubRow(sr, mode)
                        sr:ClearAllPoints()
                        sr:SetPoint("TOPLEFT", body, "TOPLEFT", x0 + SUB_INDENT, -y)
                        sr:SetWidth(cw - SUB_INDENT)
                        sr:Show()
                        y = y + SUB_H + ROW_GAP
                    end
                end
            end
            y = y - ROW_GAP + GAP
        end
    end

    -- The note: a gold-tinted rounded box with the refresh glyph.
    local note = W.note
    note:ClearAllPoints()
    note:SetPoint("TOPLEFT", body, "TOPLEFT", x0, -y)
    note:SetWidth(cw)
    note.Text:SetWidth(cw - 12 - 18 - 8 - 12)
    local nh = math.max((note.Text:GetStringHeight() or 14), 18) + 16
    note:SetHeight(nh)
    y = y + nh + 8
    body:SetHeight(y)
end

local function Build()
    view = GUI:CreateModuleView(0)
    if not view then return nil end
    local body = view.body

    local title = Label(body, 17, C.text)
    title:SetText(L["Modules"])
    W.title = title

    local lead = Label(body, 12, C.textDim)
    lead:SetText(L["Turn off what you don't use. A module that is off is not set up, and its icon leaves the rail."])
    W.lead = lead

    local gold = Gold()
    local note = CreateFrame("Frame", nil, body)
    note.surface = GUI:CreateRoundedSurface(note, { radius = 6, fill = RGBA(gold, 0.08), border = RGBA(gold, 0.25) })
    local icon = note:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", note, "LEFT", 12, 0)
    icon:SetTexture(ICONS .. "refresh.png")
    icon:SetVertexColor(gold.r, gold.g, gold.b)
    local text = Label(note, 11, C.textCaption or C.textDim)
    text:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    text:SetText(L["Turning a module on or off takes effect after a reload. Its settings are kept either way."])
    note.Text = text
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
