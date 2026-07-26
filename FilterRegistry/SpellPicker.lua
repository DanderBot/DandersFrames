local addonName, DF = ...

-- ============================================================
-- FILTER REGISTRY - SHARED SPELL DATABASE PICKER
-- One searchable, class/category-filterable overlay picker over
-- the spell database, shared by the Filter Designer's "Add from
-- Database" flow and every Aura Designer picking context (add
-- indicator, layout-group adds, triggers). Opened via
-- DF.FilterRegistry:OpenSpellPicker(opts); the class-order /
-- class-colour / async-tooltip helpers the picker and the Filter
-- Designer's spell list share are exported on DF.FilterRegistry.
-- ============================================================

local pairs, ipairs, type, next = pairs, ipairs, type, next
local tinsert = table.insert
local tsort = table.sort
local mmax = math.max
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local LOCALIZED_CLASS_NAMES_MALE = LOCALIZED_CLASS_NAMES_MALE

local L = DF.L
local R = DF.FilterRegistry

local FALLBACK_ICON = 134400 -- question mark
local SPELL_ROW_H = 26
local CLASS_HEADER_H = 22

local function Trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

-- ============================================================
-- SPELL TOOLTIP
-- The load-on-demand handling that used to live here is now
-- GUI:ShowGameTooltip, so the binding editor gets it too. What
-- stays local is the picker's own framing: the name to fall back
-- on, and the anchor.
--
-- isCurrent(row, spellID): is the (pooled, rebindable) row still
-- showing this spell? Guards the async re-render against rebinds
-- and hover moves.
-- ============================================================
local function ShowSpellTooltip(row, spellID, fallbackName, isCurrent)
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if type(name) ~= "string" or name == "" then name = fallbackName end
    DF.GUI:ShowGameTooltip(row, {
        spellID   = spellID,
        -- ANCHOR_CURSOR, not ANCHOR_RIGHT: the owner is a full-width list row, so
        -- anchoring to its right edge threw the tooltip out to the far side of the
        -- panel, nowhere near what you were pointing at. The owner stays the ROW so
        -- IsOwned / IsMouseOver / isCurrent keep working against row identity.
        anchor        = "ANCHOR_CURSOR",
        fallbackTitle = name,
        isCurrent     = isCurrent,
    })
end
R.ShowSpellTooltip = ShowSpellTooltip

-- Picker rows' "still showing this spell?" predicate (file-local so the
-- pooled OnEnter handlers don't allocate a closure per hover)
local function PickerRowStillShows(row, spellID)
    return row._rec ~= nil and row._rec.id == spellID
end

-- ============================================================
-- CLASS GROUPING HELPERS (shared with the Filter Designer lists)
-- ============================================================

-- Fixed grouping order for spell lists (token-alphabetical); records with
-- class == "ALL" (or no class) group last under L["All Classes"].
local CLASS_ORDER = {
    "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER", "MAGE",
    "MONK", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
}
R.PickerClassOrder = CLASS_ORDER

-- Localized class display names via Blizzard's global (codebase precedent:
-- TextDesigner/DataSource.lua). Covers Death Knight / Demon Hunter / Evoker.
local function ClassDisplayName(token)
    if token == "ALL" then return L["All Classes"] end
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
end
R.ClassDisplayName = ClassDisplayName

-- Class-coloured spell name. Disabled / already-added rows keep the TRUE class
-- colour and read as "faded" purely through the caller's name alpha — never a
-- hue shift or a scale toward black — so the Shaman blue (etc.) stays itself,
-- just dimmer and still legible. Only the ICON takes the hard 0.4 dim. Records
-- without a valid class token ("ALL", raw ids) use the neutral greys.
local function ApplyNameColor(fs, classToken, dim)
    local cc = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if cc then
        fs:SetTextColor(cc.r, cc.g, cc.b)
    elseif dim then
        fs:SetTextColor(0.62, 0.62, 0.62)
    else
        fs:SetTextColor(0.90, 0.90, 0.90)
    end
end
R.ApplyClassNameColor = ApplyNameColor

-- ============================================================
-- SHARED PICKER COMPONENT
-- One overlay instance per host parent frame, built lazily on
-- first open and reused across opens (WoW frames are never GC'd —
-- same pooling rule as the rows inside it). Search and both filter
-- dropdowns reset on every open.
--
-- OpenSpellPicker(opts) — opts fields:
--   parent        (Frame, required) host the overlay covers.
--   points        (optional) array of { point, relativeTo,
--                 relativePoint, x, y } SetPoint specs; defaults to
--                 filling `parent`.
--   title         (optional) header text, default L["Add from Database"].
--   subtitle      (optional) string or function() -> string; dim text
--                 after the title, re-evaluated on every Refresh.
--   subtitleColor (optional) {r,g,b}; default dim grey.
--   records       (optional) function() -> array of records.
--                 DEFAULT: the full SpellDB (R.Spells). Deliberately a
--                 provider function: a future debuff-capable variant
--                 passes a different pool without touching this
--                 component. Record shape (SpellDB-compatible):
--                   id      canonical spell id (tooltip + handlers)
--                   n       shipped fallback name (SpellDB records)
--                   class   class token, or "ALL"/nil for the shared pool
--                   cats    optional set of category keys (category filter)
--                   display optional display-name override (skips C_Spell)
--                   icon    optional icon override (skips C_Spell)
--                   iconColor optional {r,g,b} array: rows whose icon
--                           doesn't resolve render a colour swatch with
--                           the name's first letter instead of the
--                           question mark
--                 plus any consumer fields — handlers get the record back.
--   classLock     (optional) class token: HIDES the class dropdown and
--                 shows only that class's records + class == "ALL".
--   emptyText     (optional) message shown when the provider returned NO
--                 records at all (e.g. unsupported spec); a search or
--                 filter matching nothing still shows L["No results found"].
--   rowActions    (required) array of actions. ONE action = the whole row
--                 is clickable (no visible button); TWO+ = small labelled
--                 buttons on each row. Each action:
--                   { label, color = {r,g,b} (optional),
--                     handler = function(rec, spellID, picker) }
--   isBlocked     (optional) function(rec) -> nil | true | text.
--                 true renders the row dimmed with a check mark
--                 ("already added"); a string renders it dimmed with that
--                 caption (e.g. which tab the spell already lives in).
--   isValid       (optional) function() -> boolean; checked on every
--                 Refresh — the picker closes itself when it fails
--                 (e.g. the target filter was deleted).
--   allowAddByID  (optional) show the ad-hoc "#id" row: a Spell ID box
--                 plus one button per rowAction (Enter = first action).
--   onAddByID     (with allowAddByID) function(id, action, picker,
--                 idText) -> clearBox. The CONSUMER owns what an ad-hoc
--                 add means; echo/refresh through the picker handle.
--                 idText is the normalized digit string — mint text keys
--                 from IT, never from the number. Return true to clear
--                 the ID box (i.e. the add landed).
--   onClose       (optional) function() called whenever the picker hides
--                 (close button, ESC, programmatic, ancestor hide — the
--                 picker latches itself hidden on ancestor hides, so it
--                 never reappears on its own).
--
-- Returned handle: :Close() :Refresh() :RefreshRecords() :Echo(msg)
-- :IsOpen(). Refresh re-renders (re-evaluates isBlocked); RefreshRecords
-- also re-runs the records provider (new ad-hoc entries etc.).
-- ============================================================

-- Sentinels: never collide with real class tokens or category keys.
local PICKER_ALL_CLASSES = "ALLCLASSES"
local PICKER_ALL_CATS = "ALLCATS"

local instances = {} -- [parentFrame] = instance

-- ── INDEX ──
-- Class-grouped index over the provider's records (names cached for the
-- sort + search; icons fetched fresh at bind). Keyed by class token;
-- records without a valid class token collapse into "ALL". Name-sorted
-- within each group. Rebuilt only when the provider returns a different
-- list (table identity) or the classLock changed — the default SpellDB
-- provider therefore builds once, like the original Filter Designer picker.
local function BuildIndex(inst)
    local opts = inst.opts
    local records = (opts.records and opts.records()) or R.Spells
    local classLock = opts.classLock
    if inst.indexSource == records and inst.indexClassLock == classLock and inst.index then
        return
    end
    inst.indexSource = records
    inst.indexClassLock = classLock

    local index = {}
    for _, rec in ipairs(records) do
        local token = rec.class or "ALL"
        if token ~= "ALL" and not (RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]) then
            token = "ALL"
        end
        if not classLock or token == "ALL" or token == classLock then
            local g = index[token]
            if not g then
                g = {}
                index[token] = g
            end
            local name = rec.display
            if not name then name = R:GetSpellDisplay(rec) end
            -- A provider record with no display, no db name and an id the
            -- client doesn't know yields nil — index it as "#id" rather than
            -- erroring the whole picker build.
            if not name then name = "#" .. tostring(rec.id or "?") end
            g[#g + 1] = { rec = rec, name = name, lower = name:lower() }
        end
    end
    for _, g in pairs(index) do
        tsort(g, function(a, b)
            if a.name ~= b.name then return a.name < b.name end
            return (a.rec.id or 0) < (b.rec.id or 0)
        end)
    end
    inst.index = index
    inst.hasRecords = next(index) ~= nil

    -- Class dropdown options: one entry per class token actually present,
    -- in the fixed class order; "ALL" (items/racials) lists last as
    -- L["General"] so it doesn't read like the no-filter option.
    local classOptions = inst.classOptions
    for k in pairs(classOptions) do classOptions[k] = nil end
    classOptions[PICKER_ALL_CLASSES] = L["All Classes"]
    classOptions._order = { PICKER_ALL_CLASSES }
    for _, token in ipairs(CLASS_ORDER) do
        if index[token] then
            classOptions[token] = {
                text = ClassDisplayName(token),
                color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token] or nil,
            }
            tinsert(classOptions._order, token)
        end
    end
    if index.ALL then
        classOptions.ALL = L["General"]
        tinsert(classOptions._order, "ALL")
    end
    if inst.classDrop.RebuildOptions then
        inst.classDrop:RebuildOptions(classOptions)
    end
end

-- ── ROW POOL ──
local function AcquireRow(inst, i)
    local row = inst.rows[i]
    if row then
        row:Show()
        return row
    end
    local GUI = DF.GUI
    row = CreateFrame("Button", nil, inst.content, "BackdropTemplate")
    row:SetHeight(SPELL_ROW_H - 2)
    DF.GUI:CreateElementBackdrop(row, {
        outline = false,
        bgColor     = { 0.08, 0.08, 0.08, 0.6 },
    })

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", 6, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Letter fallback over a colour swatch (records with iconColor whose
    -- icon texture doesn't resolve)
    row.letter = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    row.letter:SetPoint("CENTER", row.icon, "CENTER", 0, 0)

    -- "Already added" affordance: green check instead of clickability
    row.check = row:CreateTexture(nil, "OVERLAY")
    row.check:SetSize(14, 14)
    row.check:SetPoint("RIGHT", -8, 0)
    row.check:SetTexture("Interface\\AddOns\\DandersFrames\\Media\\Icons\\check")
    row.check:SetVertexColor(0.4, 0.85, 0.5)

    -- Blocked caption (consumer-provided text, e.g. which tab a spell
    -- already lives in)
    row.blockText = row:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    row.blockText:SetPoint("RIGHT", -8, 0)
    row.blockText:SetJustifyH("RIGHT")
    row.blockText:SetTextColor(0.55, 0.55, 0.55)

    row.name = row:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    row.name:SetJustifyH("LEFT")

    row.actionBtns = {}

    row:SetScript("OnClick", function(self)
        if self._blocked or not self._rec then return end
        local actions = inst.opts and inst.opts.rowActions
        if not actions or #actions ~= 1 then return end
        actions[1].handler(self._rec, self._rec.id, inst)
    end)
    row:SetScript("OnEnter", function(self)
        if not self._blocked then
            self:SetBackdropColor(0.12, 0.12, 0.12, 0.8)
        end
        if self._rec and self._rec.id and self._rec.id > 0 then
            ShowSpellTooltip(self, self._rec.id, self._name, PickerRowStillShows)
        end
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.08, 0.08, 0.08, 0.6)
        GUI:HideTooltip()
    end)

    inst.rows[i] = row
    return row
end

-- Per-row action buttons (multi-action mode only): created lazily on each
-- row, rebound per bind. actions[1] renders leftmost, the last rightmost.
-- Create ALL buttons before anchoring any: button i anchors to button i+1,
-- so a single create-and-anchor loop would hand SetPoint a nil relativeTo
-- on a fresh row's first bind (clipping the layout until the next refresh).
local function LayoutRowButtons(inst, row, actions)
    local GUI = DF.GUI
    for i = 1, #actions do
        local btn = row.actionBtns[i]
        if not btn then
            btn = GUI:CreateButton(row, "", 44, 18, function(self)
                local r = self:GetParent()
                if r._blocked or not r._rec or not self._action then return end
                self._action.handler(r._rec, r._rec.id, inst)
            end)
            row.actionBtns[i] = btn
        end
        local action = actions[i]
        btn._action = action
        btn.Text:SetText(action.label or "")
        if action.color then
            btn.Text:SetTextColor(action.color.r, action.color.g, action.color.b)
        end
        btn:Show()
    end
    for i = #actions, 1, -1 do
        local btn = row.actionBtns[i]
        btn:ClearAllPoints()
        if i == #actions then
            btn:SetPoint("RIGHT", -6, 0)
        else
            btn:SetPoint("RIGHT", row.actionBtns[i + 1], "LEFT", -4, 0)
        end
    end
    for j = #actions + 1, #row.actionBtns do
        row.actionBtns[j]:Hide()
    end
end

local function BindRow(inst, row, y, entry)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetPoint("TOPRIGHT", 0, -y)

    local rec = entry.rec
    -- Icon: the record's override, else the live C_Spell texture. When
    -- neither resolves, records carrying an iconColor render a colour
    -- swatch with the name's first letter (the old Aura Designer card
    -- fallback); everything else keeps the question mark.
    local icon = rec.icon
    if not icon and rec.id and rec.id > 0 then
        local ic = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(rec.id)
        if type(ic) == "number" then icon = ic end
    end
    if icon then
        row.icon:SetTexture(icon)
        row.letter:Hide()
    elseif type(rec.iconColor) == "table" then
        local c = rec.iconColor
        row.icon:SetColorTexture(c[1] * 0.4, c[2] * 0.4, c[3] * 0.4, 1)
        row.letter:SetText(entry.name:sub(1, 1))
        row.letter:SetTextColor(c[1], c[2], c[3])
        row.letter:Show()
    else
        row.icon:SetTexture(FALLBACK_ICON)
        row.letter:Hide()
    end
    row.name:SetText(entry.name)
    row._rec, row._name = rec, entry.name

    local blocked = inst.opts.isBlocked and inst.opts.isBlocked(rec) or nil
    row._blocked = blocked and true or false

    local actions = inst.opts.rowActions
    local multi = actions and #actions > 1

    row.check:SetShown(blocked == true)
    if type(blocked) == "string" then
        row.blockText:SetText(blocked)
        row.blockText:Show()
    else
        row.blockText:Hide()
    end
    if multi and not blocked then
        LayoutRowButtons(inst, row, actions)
    else
        for _, btn in ipairs(row.actionBtns) do btn:Hide() end
    end

    -- Right edge of the name clears whichever affordance this bind shows
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    if type(blocked) == "string" then
        row.name:SetPoint("RIGHT", row.blockText, "LEFT", -6, 0)
    elseif multi and not blocked then
        row.name:SetPoint("RIGHT", row.actionBtns[1], "LEFT", -6, 0)
    else
        row.name:SetPoint("RIGHT", row.check, "LEFT", -6, 0)
    end

    local dim = blocked and true or false
    row.icon:SetAlpha(dim and 0.4 or 1)
    row.icon:SetDesaturated(dim)
    row.letter:SetAlpha(dim and 0.4 or 1)
    row.name:SetAlpha(dim and 0.5 or 1)
    ApplyNameColor(row.name, rec.class, dim)
    row:SetBackdropColor(0.08, 0.08, 0.08, 0.6) -- clear any lingering hover
end

-- ── REFRESH (render pass) ──
local function RefreshInstance(inst)
    local opts = inst.opts
    if opts.isValid and not opts.isValid() then
        inst.frame:Hide()
        return
    end
    local GUI = DF.GUI
    local tc = GUI.GetThemeColor()
    inst.title:SetTextColor(tc.r, tc.g, tc.b)
    local sub = opts.subtitle
    if type(sub) == "function" then sub = sub() end
    inst.subtitle:SetText(sub or "")

    -- Render groups in class order, ALL last. Headers are placed lazily on
    -- a group's first matching row, so a group with zero matches (search or
    -- filters) never shows its header.
    local index = inst.index
    local y = 4
    local usedHeaders, usedRows = 0, 0
    local function RenderGroup(token)
        if inst.classFilter ~= PICKER_ALL_CLASSES and token ~= inst.classFilter then return end
        local g = index and index[token]
        if not g then return end
        local headerPlaced = false
        for _, entry in ipairs(g) do
            if (inst.search == "" or entry.lower:find(inst.search, 1, true))
                and (inst.catFilter == PICKER_ALL_CATS
                    or (entry.rec.cats and entry.rec.cats[inst.catFilter])) then
                if not headerPlaced then
                    headerPlaced = true
                    usedHeaders = usedHeaders + 1
                    local hdr = inst.headers[usedHeaders]
                    if not hdr then
                        hdr = inst.content:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
                        hdr:SetJustifyH("LEFT")
                        inst.headers[usedHeaders] = hdr
                    end
                    hdr:Show()
                    hdr:ClearAllPoints()
                    hdr:SetPoint("TOPLEFT", 6, -(y + 6))
                    hdr:SetText(ClassDisplayName(token))
                    local cc = token ~= "ALL" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
                    if cc then
                        hdr:SetTextColor(cc.r, cc.g, cc.b)
                    else
                        hdr:SetTextColor(0.65, 0.65, 0.65)
                    end
                    y = y + CLASS_HEADER_H
                end
                usedRows = usedRows + 1
                BindRow(inst, AcquireRow(inst, usedRows), y, entry)
                y = y + SPELL_ROW_H
            end
        end
        if headerPlaced then y = y + 4 end
    end
    for _, token in ipairs(CLASS_ORDER) do
        RenderGroup(token)
    end
    RenderGroup("ALL")

    -- Hide pooled widgets beyond this refresh's needs
    for j = usedHeaders + 1, #inst.headers do
        inst.headers[j]:Hide()
    end
    for j = usedRows + 1, #inst.rows do
        inst.rows[j]:Hide()
    end
    -- Provider returned nothing at all (e.g. unsupported spec) vs. a
    -- search/filter combination matching nothing
    inst.empty:SetText((not inst.hasRecords and opts.emptyText) or L["No results found"])
    inst.empty:SetShown(usedRows == 0)
    inst.content:SetHeight(mmax(1, y + 4))
end

-- ── ADD-BY-ID ──
-- Shared validation (integers only; strip leading zeros so "#007" and "#7"
-- are the same key; reject oversized digit strings — real spell IDs are
-- well under 10 digits, and past ~15 tonumber() loses integer precision).
-- The consumer's onAddByID owns what the add MEANS; truthy return = the
-- add landed, so the box clears. The normalized digit STRING rides along
-- as the fourth argument for consumers that mint text keys from it —
-- number formatting must never leak into config keys.
local function SubmitAddByID(inst, action)
    local opts = inst.opts
    if not (opts and opts.allowAddByID and opts.onAddByID) then return end
    local text = Trim(inst.addBox.EditBox:GetText())
    if text == "" then return end
    if not text:match("^%d+$") then
        inst:Echo(L["Enter a valid spell ID."])
        return
    end
    text = text:match("^0*(%d+)$") or text
    if #text > 10 then
        inst:Echo(L["Enter a valid spell ID."])
        return
    end
    if opts.onAddByID(tonumber(text), action, inst, text) then
        inst.addBox.EditBox:SetText("")
    end
end

-- ── INSTANCE CONSTRUCTION (lazy, one per host parent) ──
local function BuildInstance(parent)
    local GUI = DF.GUI
    local inst = {
        rows = {},
        headers = {},
        addBtns = {},
        search = "",
        classFilter = PICKER_ALL_CLASSES,
        catFilter = PICKER_ALL_CATS,
        echoGen = 0,
        classOptions = {},
    }

    local picker = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    GUI:CreatePanelBackdrop(picker, { bgAlpha = 0.98, borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })
    picker:EnableMouse(true) -- swallow clicks aimed at the page underneath
    picker:Hide()
    inst.frame = picker

    -- Close on Escape (same idiom as the Aura Designer popups).
    -- SetPropagateKeyboardInput is protected in combat for insecure code:
    -- skip the calls there (keys propagate anyway — ESC just hides the
    -- panel), and don't trap keyboard input if built mid-combat.
    if not InCombatLockdown() then
        picker:EnableKeyboard(true)
        picker:SetPropagateKeyboardInput(true)
    end
    picker:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
            self:Hide()
        else
            if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
        end
    end)

    -- Consumer close hook: fires on ANY effective hide (close button, ESC,
    -- programmatic, ancestor hide). An ANCESTOR hide (GUI page nav) does
    -- not clear this frame's own shown flag — without the self:Hide()
    -- latch the picker would silently REAPPEAR when the page returns,
    -- after onClose already tore the consumer's open-state down (e.g. the
    -- Aura Designer's cross-tab block set), leaving it half-closed with
    -- its guards disarmed. Latching makes every close a real close: the
    -- picker never comes back on its own, and reopening runs the full
    -- open path (fresh state). Hide() inside OnHide is safe — effective
    -- visibility is already lost, so it can't re-fire the handler.
    picker:SetScript("OnHide", function(self)
        self:Hide()
        if inst.opts and inst.opts.onClose then inst.opts.onClose() end
    end)

    inst.title = picker:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    inst.title:SetPoint("TOPLEFT", 10, -11)

    inst.subtitle = picker:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    inst.subtitle:SetPoint("LEFT", inst.title, "RIGHT", 10, 0)
    inst.subtitle:SetTextColor(0.5, 0.5, 0.5)

    local closeBtn = GUI:CreateCloseButton(picker, {
        size = 20,
        onClick = function() picker:Hide() end,
    })
    closeBtn:SetPoint("TOPRIGHT", -8, -8)

    -- Search box, stretched to clear the close button (body at -33..-57)
    local searchBox = GUI:CreateEditBox(picker, "", nil, nil, nil, 170, L["Search..."])
    searchBox:SetPoint("TOPLEFT", 10, -18)
    searchBox:SetPoint("TOPRIGHT", -36, -18)
    inst.searchBox = searchBox

    -- HookScript (not SetScript): CreateEditBox already hooks OnTextChanged
    -- for its placeholder handling.
    searchBox.EditBox:HookScript("OnTextChanged", function(eb)
        local q = (eb:GetText() or ""):lower()
        if q == inst.search then return end
        inst.search = q
        if picker:IsShown() then RefreshInstance(inst) end
    end)

    -- Filter row under the search box: Class + Category dropdowns, side by
    -- side. They combine with the search text (row shows only if it matches
    -- all three). Inline dropdowns with customGet/customSet closing over the
    -- transient instance state — deliberately not db-backed; reset per open.
    inst.classDrop = GUI:CreateDropdown(picker, "", inst.classOptions, nil, nil, nil,
        function() return inst.classFilter end,
        function(v)
            inst.classFilter = v or PICKER_ALL_CLASSES
            if picker:IsShown() then RefreshInstance(inst) end
        end,
        { inline = true })
    inst.classDrop:SetSize(160, 22)
    inst.classDrop:SetPoint("TOPLEFT", 10, -62)

    local catOptions = { [PICKER_ALL_CATS] = L["All Categories"], _order = { PICKER_ALL_CATS } }
    for _, cat in ipairs(R.Categories) do
        catOptions[cat.key] = L[cat.name]
        tinsert(catOptions._order, cat.key)
    end
    inst.catDrop = GUI:CreateDropdown(picker, "", catOptions, nil, nil, nil,
        function() return inst.catFilter end,
        function(v)
            inst.catFilter = v or PICKER_ALL_CATS
            if picker:IsShown() then RefreshInstance(inst) end
        end,
        { inline = true })
    inst.catDrop:SetSize(160, 22)

    -- Ad-hoc "#id" row (shown per open when opts.allowAddByID): Spell ID
    -- box + one button per rowAction + transient echo line.
    local addBox = GUI:CreateEditBox(picker, "", nil, nil, nil, 90, L["Spell ID"])
    addBox:SetPoint("TOPLEFT", 10, -75)
    addBox:Hide()
    inst.addBox = addBox
    -- Enter in the box adds too (the helper's own OnEnterPressed only saves
    -- db-backed values — this box has no db binding). Defaults to the FIRST
    -- action (matches the old group toolbar's Enter-adds-an-Icon).
    addBox.EditBox:HookScript("OnEnterPressed", function()
        local actions = inst.opts and inst.opts.rowActions
        SubmitAddByID(inst, actions and actions[1] or nil)
    end)

    -- Echo line: transient add-by-ID feedback, auto-hides after ~4s.
    -- Generation counter so a re-add while a message is visible restarts
    -- the 4s window instead of the old timer hiding the new message early.
    local echoText = picker:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    echoText:SetJustifyH("LEFT")
    echoText:SetWordWrap(false)
    echoText:SetTextColor(0.6, 0.6, 0.6)
    echoText:Hide()
    inst.echoText = echoText

    -- List background: top offset set per open (the add-by-ID row is only
    -- there when the consumer asks for it)
    local listBg = CreateFrame("Frame", nil, picker, "BackdropTemplate")
    GUI:CreatePanelBackdrop(listBg, { borderColor = { r = 0.20, g = 0.20, b = 0.20, a = 1 } })
    inst.listBg = listBg

    local scroll = CreateFrame("ScrollFrame", nil, listBg, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -24, 4)
    DF.GUI.StyleScrollBar(scroll)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(400, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then content:SetWidth(w) end
    end)
    inst.content = content

    inst.empty = listBg:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
    inst.empty:SetPoint("CENTER", listBg, "CENTER", 0, 0)
    inst.empty:SetJustifyH("CENTER") -- opts.emptyText messages can be multi-line
    inst.empty:SetText(L["No results found"])
    inst.empty:Hide()

    -- ── HANDLE METHODS ──
    function inst:Close()
        self.frame:Hide()
    end
    function inst:IsOpen()
        return self.frame:IsShown()
    end
    function inst:Refresh()
        if self.frame:IsShown() then RefreshInstance(self) end
    end
    function inst:RefreshRecords()
        if self.frame:IsShown() then
            self.indexSource = nil -- force the provider re-run
            BuildIndex(self)
            RefreshInstance(self)
        end
    end
    function inst:Echo(msg)
        self.echoGen = self.echoGen + 1
        local gen = self.echoGen
        self.echoText:SetText(msg)
        self.echoText:Show()
        C_Timer.After(4, function()
            if self.echoGen == gen then self.echoText:Hide() end
        end)
    end

    return inst
end

-- ── OPEN ──
function R:OpenSpellPicker(opts)
    local parent = opts.parent
    local inst = instances[parent]
    if not inst then
        inst = BuildInstance(parent)
        instances[parent] = inst
    end
    inst.opts = opts
    local picker = inst.frame

    -- Instances are cached per parent, so one BUILT mid-combat skipped its
    -- keyboard setup and would never get ESC-close. Retry at every open:
    -- EnableKeyboard is not the protected call (only
    -- SetPropagateKeyboardInput is, and the OnKeyDown handler already
    -- combat-guards those).
    if not picker:IsKeyboardEnabled() and not InCombatLockdown() then
        picker:EnableKeyboard(true)
        picker:SetPropagateKeyboardInput(true)
    end

    picker:ClearAllPoints()
    if opts.points then
        for _, p in ipairs(opts.points) do
            picker:SetPoint(p[1], p[2], p[3], p[4], p[5])
        end
    else
        picker:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        picker:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    end
    picker:SetFrameLevel(parent:GetFrameLevel() + 30)

    inst.title:SetText(opts.title or L["Add from Database"])
    local sc = opts.subtitleColor
    inst.subtitle:SetTextColor(sc and sc.r or 0.5, sc and sc.g or 0.5, sc and sc.b or 0.5)

    -- Fresh transient state per open: clear the search (state BEFORE
    -- SetText so the OnTextChanged guard skips a redundant refresh) and
    -- reset both filters — every open starts unfiltered.
    inst.search = ""
    if inst.searchBox.EditBox:GetText() ~= "" then
        inst.searchBox.EditBox:SetText("")
    end
    if inst.classFilter ~= PICKER_ALL_CLASSES or inst.catFilter ~= PICKER_ALL_CATS then
        inst.classFilter = PICKER_ALL_CLASSES
        inst.catFilter = PICKER_ALL_CATS
        inst.classDrop:UpdateText()
        inst.catDrop:UpdateText()
    end

    -- classLock hides the class dropdown; the category dropdown slides
    -- into its slot so the filter row never shows a gap.
    inst.catDrop:ClearAllPoints()
    if opts.classLock then
        inst.classDrop:Hide()
        inst.catDrop:SetPoint("TOPLEFT", 10, -62)
    else
        inst.classDrop:Show()
        inst.catDrop:SetPoint("TOPLEFT", inst.classDrop, "TOPRIGHT", 8, 0)
    end

    -- Ad-hoc "#id" row: one button per rowAction (single action = one
    -- button carrying its label, e.g. Add; two = Icon / Square).
    inst.echoGen = inst.echoGen + 1
    inst.echoText:Hide()
    local listTop = -92
    if opts.allowAddByID then
        listTop = -120
        inst.addBox:Show()
        inst.addBox.EditBox:SetText("")
        local actions = opts.rowActions or {}
        local lastBtn
        for i, action in ipairs(actions) do
            local btn = inst.addBtns[i]
            if not btn then
                btn = DF.GUI:CreateButton(picker, "", 50, 22, function(self)
                    SubmitAddByID(inst, self._action)
                end)
                inst.addBtns[i] = btn
            end
            btn._action = action
            btn.Text:SetText(action.label or L["Add"])
            if action.color then
                btn.Text:SetTextColor(action.color.r, action.color.g, action.color.b)
            else
                btn.Text:SetTextColor(0.9, 0.9, 0.9)
            end
            btn:ClearAllPoints()
            if i == 1 then
                btn:SetPoint("LEFT", inst.addBox.EditBox, "RIGHT", 6, 0)
            else
                btn:SetPoint("LEFT", inst.addBtns[i - 1], "RIGHT", 4, 0)
            end
            btn:Show()
            lastBtn = btn
        end
        for j = #actions + 1, #inst.addBtns do
            inst.addBtns[j]:Hide()
        end
        inst.echoText:ClearAllPoints()
        if lastBtn then
            inst.echoText:SetPoint("LEFT", lastBtn, "RIGHT", 10, 0)
        else
            inst.echoText:SetPoint("LEFT", inst.addBox.EditBox, "RIGHT", 10, 0)
        end
        inst.echoText:SetPoint("RIGHT", picker, "TOPRIGHT", -10, -102)
    else
        inst.addBox:Hide()
        for _, btn in ipairs(inst.addBtns) do btn:Hide() end
    end
    inst.listBg:ClearAllPoints()
    inst.listBg:SetPoint("TOPLEFT", 10, listTop)
    inst.listBg:SetPoint("BOTTOMRIGHT", -10, 10)

    BuildIndex(inst)
    picker:Show()
    RefreshInstance(inst)
    return inst
end
