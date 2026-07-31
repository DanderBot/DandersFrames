-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's,
-- so every DF.* read here would be nil. DandersFrames publishes its own table
-- as a global via ## AllowAddOnTableAccess -- take it from there.
local DF = DandersFrames

-- ============================================================
-- AURA EXPLORER  —  /df debug auraexp
-- ============================================================
-- Stack any number of filter rows ABOVE every party/raid frame. Each row is one
-- filter combination — a Blizzard filter string, optional candidateFilters, and
-- optionally one of DF's own FilterRegistry selections — rendered as a live icon
-- strip on every unit at once. Row 1 sits nearest the frames; each new row builds
-- upward. A gutter to the left of the leftmost frame names each row's combination.
--
-- WHY IT EXISTS: on 12.1 you cannot read a unit's auras to find out why a filter
-- did or did not match. The only way to see what a selector actually resolves to
-- is to hand it to the engine and look at what comes back. This is that, for
-- several selectors at once, across the real group.
--
-- ☠ ONE CONTAINER PER ROW PER UNIT. filterString is fixed at AddAuraGroup time
-- and per-group row anchoring inside a single container is not clean (the finding
-- DF_AuraLab_Matrix records and works around the same way). 4 rows x 5 party units
-- is 20 containers, and rows are user-addable — acceptable for a dev tool that is
-- off by default, but it is why this must never be left running.
--
-- Modelled on DF_AuraLab_Matrix.lua's makeStrip, which is the proven minimal
-- harness for "one selector, one live strip".
-- ============================================================

local AE = {}
DF.AuraExplorer = AE

local GUI = DF.GUI

local DEFAULT_ROWS = 4     -- seeded on first open; add/remove freely after that
local IGAP       = 2
local GUTTER_W   = 208

-- Live-adjustable from the panel. All three are STRUCTURAL — element size and
-- maxFrameCount are baked into the group's layout options at AddAuraGroup time,
-- and the font is set on the region at button init — so changing any of them
-- tears the strips down and rebuilds rather than hot-applying.
AE.iconSize = 22
AE.fontSize = 10
AE.maxIcons = 10   -- buttons per unit per row; also the strip's width budget

-- Text placement. The offsets are only a SetPoint on our own FontStrings, so they
-- are not structural in themselves — but the regions are positioned inside
-- initializeFrame, which the engine runs once per button at creation. There is no
-- handle on the live buttons to re-point afterwards, so these rebuild like the
-- rest. Timer is centred, stack sits bottom-right; the offsets shift from there.
AE.timerX, AE.timerY = 0, 0
AE.stackX, AE.stackY = -1, 1
AE.stackFontSize = 10

local function rowPitch() return AE.iconSize + 4 end

-- ============================================================
-- FILTER VOCABULARY
-- ============================================================
-- Source-grounded: the token list and candidateFilters below mirror
-- DF_AuraLab_Matrix.lua's selector inventory, which was itself checked against
-- Blizzard_AuraContainerUtil (DoesAuraPassCandidateFilters) and
-- Blizzard_CustomAuraContainer (ValidateCandidateFilters). Do not add a name here
-- that has not been seen to parse — AuraUtil.IsValidFilterString rejects unknown
-- tokens and the row then silently renders empty, which is exactly the failure
-- this tool exists to make visible.

-- (Removed) AE.CATEGORIES = { "HELPFUL", "HARMFUL" } — never read; the category
-- toggle names both strings inline.

-- Tokens that combine with a category. RAID is context-dependent (castable buffs
-- vs dispellable debuffs) and is the single most useful one to eyeball.
AE.TOKENS = {
    "RAID",
    "PLAYER",
    "!PLAYER",
    "CROWD_CONTROL",
    "RAID_IN_COMBAT",
    "RAID_PLAYER_DISPELLABLE",
    "INCLUDE_NAME_PLATE_ONLY",
    "CANCELABLE",
    "BIG_DEFENSIVE",
    "EXTERNAL_DEFENSIVE",
    "MAW",
}

-- Boolean candidateFilters. Evaluated AFTER the filter string.
AE.FLAGS = {
    "isBossAura",
    "isBossOrRoleAura",
    "isRoleAura",
    "isPriorityAura",
    "isStealable",
    "canApplyAura",
    "isFromPlayerOrPlayerPet",
    "nameplateShowAll",
    "nameplateShowPersonal",
}

AE.DISPEL_TYPES = { "Magic", "Curse", "Disease", "Poison" }

-- Row tint, by index. Matches the concept doc so the gutter and the builder card
-- read as the same row at a glance.
AE.ROW_COLORS = {
    { 0.25, 0.82, 0.45 },   -- 1 green
    { 1.00, 0.42, 0.37 },   -- 2 red
    { 1.00, 0.82, 0.00 },   -- 3 gold
    { 0.45, 0.45, 0.95 },   -- 4 violet
    { 0.40, 0.80, 1.00 },   -- 5 blue
}

-- ============================================================
-- STATE
-- ============================================================
-- rows[i] = {
--   enabled  = bool,
--   category = "HELPFUL" | "HARMFUL",
--   tokens   = { [token] = true },
--   flags    = { [flagName] = true },
--   maxDuration    = number | nil,
--   includeDispel  = { [type] = true } | nil,
--   excludeDispel  = { [type] = true } | nil,
--   dfPreset = categoryKey | nil,     -- one of FilterRegistry's 13
--   dfCustom = customFilterId | nil,
-- }
AE.rows = {}
AE.active = false

-- WEAK KEYS: the key is a live unit frame, and DF pools/recycles those. A strong
-- table would keep a retired frame alive for as long as a stale entry sat here.
-- TeardownAll wipes on every Rebuild so the window is small, but "small" is not a
-- reason to hold a frame reference in a debug tool.
local strips = setmetatable({}, { __mode = "k" })  -- [frame] = { [rowIndex] = container }
local gutterRows = {} -- [rowIndex] = gutter frame
local gutterHost

-- ⚠ Declared HERE, not next to its SetScript at the bottom of the file: SetActive
-- registers and unregisters it, and SetActive is defined several hundred lines
-- above that block — referencing `ev` from there would resolve the name as a
-- GLOBAL and read nil at call time. The handler itself is still installed at the
-- bottom, once Rebuild exists.
local ev = CreateFrame("Frame")

local function defaultRow(i)
    return {
        enabled  = i == 1,
        category = i == 1 and "HARMFUL" or "HELPFUL",
        tokens   = {},
        flags    = {},
    }
end

-- Seeds DEFAULT_ROWS the FIRST time only. After that #self.rows is whatever the
-- user has built up to, so this must never top the list back up — that would
-- silently resurrect rows they deleted.
function AE:EnsureRows()
    if #self.rows > 0 then return end
    for i = 1, DEFAULT_ROWS do self.rows[i] = defaultRow(i) end
end

-- Colours cycle once past the palette, so row 6 reuses row 1's tint rather than
-- indexing off the end and erroring.
function AE:RowColor(i)
    return AE.ROW_COLORS[((i - 1) % #AE.ROW_COLORS) + 1]
end

function AE:AddRow()
    self.rows[#self.rows + 1] = defaultRow(#self.rows + 1)
    self:Rebuild()
end

function AE:RemoveRow(i)
    if not self.rows[i] then return end
    table.remove(self.rows, i)
    -- Editor is index-keyed; a removal re-numbers everything below it, so an open
    -- editor would be pointing at a different row than its title claims.
    if self._editor then self._editor:Hide() end
    self:Rebuild()
end

-- ============================================================
-- RESOLVING A ROW INTO WHAT THE ENGINE WANTS
-- ============================================================

-- "HARMFUL|RAID|!PLAYER" — category first, then tokens in AE.TOKENS order so the
-- string is STABLE for a given selection (it is also the row's identity, used as
-- the AddAuraGroup key and to decide whether a rebuild is needed).
function AE:FilterString(row)
    local s = row.category or "HELPFUL"
    for _, tok in ipairs(AE.TOKENS) do
        if row.tokens and row.tokens[tok] then s = s .. "|" .. tok end
    end
    return s
end

-- The candidateFilters table, or nil when the row sets none.
-- ☠ DF's own filters are NOT a separate mechanism: FilterRegistry:ResolveSelection
-- turns a selection into spell-ID sets, which land here as includeSpellIDs. That
-- means they inherit the identity gate — see AE:RowGated.
function AE:CandidateFilters(row)
    local cf, any = {}, false

    for _, flag in ipairs(AE.FLAGS) do
        if row.flags and row.flags[flag] then cf[flag] = true; any = true end
    end
    if row.maxDuration then cf.maxDuration = row.maxDuration; any = true end
    if row.includeDispel and next(row.includeDispel) then
        cf.includeDispelTypes = row.includeDispel; any = true
    end
    if row.excludeDispel and next(row.excludeDispel) then
        cf.excludeDispelTypes = row.excludeDispel; any = true
    end

    -- DF filter -> spell-ID map, through the SHIPPED resolver so what you see here
    -- is what the addon's own rows would see.
    local sel = self:DFSelection(row)
    if sel and DF.FilterRegistry then
        local res = DF.FilterRegistry:ResolveSelection(sel, false)
        if res and res.kind == "include" and res.map and next(res.map) then
            cf.includeSpellIDs = res.map; any = true
        elseif res and res.kind == "exclude" and res.map and next(res.map) then
            cf.excludeSpellIDs = res.map; any = true
        end
    end

    return any and cf or nil
end

-- The FilterRegistry selection this row asks for, or nil.
function AE:DFSelection(row)
    if row.dfPreset then return { presets = { [row.dfPreset] = true } } end
    if row.dfCustom then return { customs = { [row.dfCustom] = true } } end
    return nil
end

-- Does this row lean on a spell-ID candidate filter that the identity gate will
-- skip? Only HARMFUL is affected in practice: friendly buffs are readable, hostile
-- debuff identity is sealed, so the include/exclude map matches nothing and the
-- row reads empty with no error.
function AE:RowGated(row)
    if row.category ~= "HARMFUL" then return false end
    return self:DFSelection(row) ~= nil
end

-- One-line human summary for the gutter and the builder card.
function AE:RowSummary(row)
    local bits = {}
    for _, flag in ipairs(AE.FLAGS) do
        if row.flags and row.flags[flag] then bits[#bits + 1] = flag end
    end
    if row.maxDuration then bits[#bits + 1] = "maxDuration " .. row.maxDuration end
    if row.includeDispel and next(row.includeDispel) then
        local t = {}
        for k in pairs(row.includeDispel) do t[#t + 1] = k end
        table.sort(t)
        bits[#bits + 1] = "+dispel " .. table.concat(t, ",")
    end
    if row.excludeDispel and next(row.excludeDispel) then
        local t = {}
        for k in pairs(row.excludeDispel) do t[#t + 1] = k end
        table.sort(t)
        bits[#bits + 1] = "-dispel " .. table.concat(t, ",")
    end
    if row.dfPreset then
        bits[#bits + 1] = "DF: " .. (AE:PresetName(row.dfPreset) or row.dfPreset)
    elseif row.dfCustom and DF.FilterRegistry then
        local f = DF.FilterRegistry:GetCustomFilter(row.dfCustom)
        bits[#bits + 1] = "DF: " .. ((f and f.name) or "custom")
    end
    if #bits == 0 then return "no candidate filters" end
    return table.concat(bits, " · ")
end

function AE:PresetName(key)
    local R = DF.FilterRegistry
    if not (R and R.Categories) then return nil end
    for _, cat in ipairs(R.Categories) do
        if cat.key == key then return cat.name end
    end
    return nil
end

-- Identity of a row's STRUCTURE. A change here means the container must be
-- recreated (filterString is immutable once the group exists); anything else can
-- ride a live setter. Kept deliberately coarse — this is a dev tool and a full
-- rebuild on any edit is honest and cheap enough at 25 containers.
-- (Removed) AE:RowSig. It decided whether a row change needed a rebuild, but
-- AE:Rebuild calls TeardownAll() unconditionally now, so the caller it was written
-- for is gone. CandidateFilters / FilterString keep their other callers.

-- ============================================================
-- THE STRIPS
-- ============================================================

-- ☠ THE BUTTON MUST BE GIVEN REGIONS TO FILL, OR IT RENDERS NOTHING.
-- A container button is not self-painting: you hand it a texture via SetIcon and
-- the ENGINE fills it from the (secret) aura, which is what keeps this read-free.
-- Skip that and the buttons still exist and still lay out — the row occupies its
-- space and reports the right count — but every icon is invisible, which reads
-- exactly like "the filter matched nothing". First version of this function only
-- called SetSize, and that is precisely what it looked like.
--
-- Mirrors DF_AuraLab_Matrix.StyleMatrixButton; every binding here is a setter the
-- engine drives, never a value we read.
local function styleButton(button)
    local sz = AE.iconSize
    button:SetSize(sz, sz)
    pcall(function()
        button:SetMouseClickEnabled(false)   -- click-through: never eat targeting
        button:SetMouseMotionEnabled(true)   -- native aura tooltip on hover
    end)

    if not button.dfaeBack then
        button.dfaeBack = button:CreateTexture(nil, "BACKGROUND", nil, -8)
        button.dfaeBack:SetAllPoints(button)
        button.dfaeBack:SetColorTexture(0, 0, 0, 0.9)
    end
    if not button.dfaeIcon then
        button.dfaeIcon = button:CreateTexture(nil, "BACKGROUND", nil, 0)
        button.dfaeIcon:SetPoint("TOPLEFT", 1, -1)
        button.dfaeIcon:SetPoint("BOTTOMRIGHT", -1, 1)
        button.dfaeIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        -- THE line that makes the row visible.
        if button.SetIcon then pcall(function() button:SetIcon(button.dfaeIcon) end) end
    end
    if button.SetDurationCooldown and not button.dfaeCD then
        button.dfaeCD = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        pcall(function() button:SetDurationCooldown(button.dfaeCD) end)
        button.dfaeCD:SetAllPoints(button.dfaeIcon or button)
        button.dfaeCD:SetDrawEdge(false)
        -- ☠ HIDE the cooldown's own countdown numbers. That is what was drawing the
        -- huge unstyled "37m" across the strip: CooldownFrameTemplate paints its own
        -- text at its own font size, ignoring anything we set. The real timer is the
        -- SetDurationText region below, which IS ours to format and size.
        if button.dfaeCD.SetHideCountdownNumbers then
            button.dfaeCD:SetHideCountdownNumbers(true)
        end
    end

    -- ☠ TEXT MUST LIVE ON A RAISED FRAME, NOT ON THE BUTTON.
    -- The cooldown is a FRAME child of the button, and a frame draws above ALL of
    -- its parent's own regions no matter what draw layer they claim — so an
    -- OVERLAY FontString created on the button still ends up beneath the swipe.
    -- One holder above the cooldown carries both text regions. (The stack count
    -- already worked for exactly this reason; the duration text did not, and read
    -- as "text under the swipe".)
    if not button.dfaeTextHolder then
        button.dfaeTextHolder = CreateFrame("Frame", nil, button)
        button.dfaeTextHolder:SetAllPoints(button)
        button.dfaeTextHolder:SetFrameLevel(math.max(0, button:GetFrameLevel() + 4))
    end

    -- Duration text. Numeric format via the addon's OWN formatter resolver, so the
    -- explorer reads the same as the live rows rather than inventing a format.
    if button.SetDurationText and not button.dfaeDur then
        button.dfaeDur = button.dfaeTextHolder:CreateFontString(nil, "OVERLAY")
        button.dfaeDur:SetJustifyH("CENTER")
    end
    if button.dfaeDur then
        button.dfaeDur:ClearAllPoints()
        button.dfaeDur:SetPoint("CENTER", button, "CENTER", AE.timerX, AE.timerY)
        DF:SafeSetFont(button.dfaeDur, STANDARD_TEXT_FONT, AE.fontSize, "OUTLINE")
        if not button._dfaeBoundDur then
            -- Mirrors AuraContainer.bindNative's dual path: 68914 reshaped
            -- SetDurationText to read { binding | textFormat | textFormatter |
            -- textColor } and silently IGNORE the flat keys, so try the binding
            -- first and fall back for older builds. ⚠ Deliberate duplication —
            -- AuraContainer's version is config-driven and file-local; this tool
            -- builds its own buttons and cannot reach it.
            local formatter = DF.GetDurationFormatFields
                and DF:GetDurationFormatFields("NUMBER", nil, nil)
            local bound = false
            if C_AuraContainerUtil
                and type(C_AuraContainerUtil.ProcessCustomAuraButtonDurationTextOptions) == "function"
                and C_DurationUtil and C_DurationUtil.CreateDurationTextBinding then
                bound = pcall(function()
                    local b = C_DurationUtil.CreateDurationTextBinding()
                    if formatter then b:SetFormatter(formatter) end
                    b:SetEnabled(true)
                    button:SetDurationText(button.dfaeDur, { binding = b })
                end)
            end
            if not bound then
                bound = pcall(function()
                    button:SetDurationText(button.dfaeDur, { formatter = formatter })
                end)
            end
            -- Stamp AFTER the attempt, never before: latching a FAILED bind would
            -- leave the timer blank for the life of the button with no retry.
            button._dfaeBoundDur = bound or nil
        end
    end
    if button.SetApplicationCount and not button.dfaeStack then
        button.dfaeStack = button.dfaeTextHolder:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        pcall(function() button:SetApplicationCount(button.dfaeStack, {}) end)
    end
    if button.dfaeStack then
        button.dfaeStack:ClearAllPoints()
        button.dfaeStack:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", AE.stackX, AE.stackY)
        -- Overrides the NumberFontNormalSmall template it was created with, so the
        -- stack count is sizeable independently of the timer.
        DF:SafeSetFont(button.dfaeStack, STANDARD_TEXT_FONT, AE.stackFontSize, "OUTLINE")
    end
end

-- One live icon strip for one row on one unit. Mirrors DF_AuraLab_Matrix.makeStrip:
-- own container, single AddAuraGroup, SetEnabled LAST so the parse binds with the
-- frames already in place.
local function makeStrip(parent, unit, row, rowIndex, yOffset)
    local ok, c = pcall(CreateFrame, "AuraContainer", nil, parent, "CustomAuraContainerTemplate")
    if not ok or not c or type(c.AddAuraGroup) ~= "function" then return nil end

    c:ClearAllPoints()
    c:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", 0, yOffset)
    c:SetSize(AE.maxIcons * (AE.iconSize + IGAP), AE.iconSize)
    pcall(function() c:SetUnit(unit) end)

    pcall(function() c:SetFlowLayoutAnchorPoint("TOPLEFT") end)
    pcall(function()
        if AnchorUtil and AnchorUtil.FlowDirection then
            c:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection.Right or 0,
                                           AnchorUtil.FlowDirection.Down or 1)
        end
    end)

    local filter = AE:FilterString(row)
    local opts = {
        maxFrameCount   = AE.maxIcons,
        initializeFrame = function(button) pcall(styleButton, button) end,
        layout = {
            elementWidth   = AE.iconSize,
            elementHeight  = AE.iconSize,
            elementSpacing = IGAP,
            lineSpacing    = IGAP,
        },
    }
    local cf = AE:CandidateFilters(row)
    if cf then opts.candidateFilters = cf end

    -- A rejected filter string renders an EMPTY row that looks exactly like "nothing
    -- matched". Say so instead of leaving it ambiguous.
    if AuraUtil and AuraUtil.IsValidFilterString and not AuraUtil.IsValidFilterString(filter) then
        DF:DebugWarn("AURAROW", "AuraExplorer row %d: filter string REJECTED: %s", rowIndex, filter)
    end

    local built, err = pcall(function()
        c:AddAuraGroup("dfae_" .. rowIndex, filter, opts)
    end)
    if not built then
        DF:DebugWarn("AURAROW", "AuraExplorer row %d: AddAuraGroup failed: %s", rowIndex, tostring(err))
        return nil
    end
    pcall(function() c:SetEnabled(true) end)
    return c
end

local function teardownFrame(frame)
    local set = strips[frame]
    if not set then return end
    for i, c in pairs(set) do
        pcall(function() c:SetEnabled(false) end)
        c:Hide()
        c:ClearAllPoints()
        c:SetParent(nil)
        set[i] = nil
    end
    strips[frame] = nil
end

function AE:TeardownAll()
    for frame in pairs(strips) do teardownFrame(frame) end
    wipe(strips)
    if gutterHost then gutterHost:Hide() end
end

-- ============================================================
-- THE GUTTER
-- ============================================================
-- Anchored to the LEFT of the leftmost visible frame, one label per active row at
-- that row's height. ⚠ Assumes a broadly horizontal layout — with frames stacked
-- vertically the gutter still tracks the leftmost one and simply overlaps less
-- usefully. Acceptable for a dev tool; noted rather than silently odd.

-- Pooled, not pre-sized: the row count is now user-driven, so labels are created
-- on first use and reused thereafter.
local function ensureGutterRow(i)
    if not gutterHost then
        gutterHost = CreateFrame("Frame", "DFAuraExplorerGutter", UIParent)
        gutterHost:SetSize(GUTTER_W, 10)
        gutterHost:SetFrameStrata("HIGH")
    end
    local g = gutterRows[i]
    if g then return g end

    g = CreateFrame("Frame", nil, gutterHost, "BackdropTemplate")
    g:SetSize(GUTTER_W, AE.iconSize)

    local idx = g:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    idx:SetPoint("LEFT", 6, 0)
    g.idx = idx

    local head = g:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    head:SetPoint("LEFT", idx, "RIGHT", 6, 5)
    head:SetJustifyH("LEFT")
    g.head = head

    local sub = g:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    sub:SetPoint("LEFT", idx, "RIGHT", 6, -5)
    sub:SetJustifyH("LEFT")
    sub:SetTextColor(0.55, 0.55, 0.66)
    g.sub = sub

    gutterRows[i] = g
    g:Hide()
    return g
end

-- Tint is applied per layout pass, not at creation: removing a row re-numbers
-- everything below it, so a pooled label can serve a different index than the one
-- it was created for.
local function paintGutterRow(g, i)
    local col = AE:RowColor(i)
    GUI:CreateElementBackdrop(g, {
        bgColor     = { 0.04, 0.04, 0.06, 0.86 },
        borderColor = { col[1], col[2], col[3], 0.9 },
    })
    g.idx:SetText(tostring(i))
    g.idx:SetTextColor(col[1], col[2], col[3])
end

local function layoutGutter(anchorFrame)
    if not anchorFrame then
        if gutterHost then gutterHost:Hide() end
        return
    end
    ensureGutterRow(1)
    gutterHost:ClearAllPoints()
    gutterHost:SetPoint("BOTTOMRIGHT", anchorFrame, "TOPLEFT", -6, 0)
    gutterHost:Show()

    local shown = 0
    for i = 1, #AE.rows do
        local row = AE.rows[i]
        local g = ensureGutterRow(i)
        if row and row.enabled then
            shown = shown + 1
            paintGutterRow(g, i)
            g:ClearAllPoints()
            g:SetPoint("BOTTOMLEFT", gutterHost, "BOTTOMLEFT", 0, (shown - 1) * rowPitch())
            local gated = AE:RowGated(row) and "  |cffffd100(gated)|r" or ""
            g.head:SetText(AE:FilterString(row) .. gated)
            g.head:SetTextColor(1, 1, 1)
            g.sub:SetText(AE:RowSummary(row))
            g:Show()
        else
            g:Hide()
        end
    end
    -- Pooled labels beyond the current row count must not linger.
    for i = #AE.rows + 1, #gutterRows do
        if gutterRows[i] then gutterRows[i]:Hide() end
    end
end

-- ============================================================
-- BUILD / REFRESH
-- ============================================================

local function eachFrame(fn)
    if DF.IteratePartyFrames then DF:IteratePartyFrames(fn) end
    if DF.IterateRaidFrames then DF:IterateRaidFrames(fn) end
end

function AE:Rebuild()
    self:TeardownAll()
    -- Panel first, and BEFORE the active check: adding or removing a row while the
    -- rows are switched off still has to redraw the cards and the container count.
    if self.panel and self.panel:IsShown() then self.panel:Rebuild() end
    if not self.active then return end
    if not (DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported()) then
        DF:Err("Aura Explorer needs the 12.1 container API.")
        return
    end
    if InCombatLockdown() then
        DF:Say("Aura Explorer", "deferred — container work is out-of-combat only", "WARN")
        return
    end
    self:EnsureRows()

    local leftmost, leftX
    eachFrame(function(frame)
        if not frame or not frame.unit or not frame:IsShown() then return end
        local set = {}
        local shown = 0
        for i = 1, #self.rows do
            local row = self.rows[i]
            if row and row.enabled then
                shown = shown + 1
                local y = (shown - 1) * rowPitch() + 4
                local c = makeStrip(frame, frame.unit, row, i, y)
                if c then set[i] = c end
            end
        end
        if next(set) then strips[frame] = set end

        local x = frame:GetLeft()
        if x and (not leftX or x < leftX) then leftX, leftmost = x, frame end
    end)

    layoutGutter(leftmost)
end

function AE:SetActive(on)
    self.active = on and true or false
    if self.active then
        -- Registered only while the tool is ON. GROUP_ROSTER_UPDATE fires on every
        -- roster change for EVERY user, and this is a dev-only tool almost nobody
        -- opens — an always-registered handler is a cost everyone pays for nobody.
        ev:RegisterEvent("GROUP_ROSTER_UPDATE")
        ev:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:Rebuild()
        DF:Say("Aura Explorer", "ON", "GOOD")
    else
        ev:UnregisterAllEvents()
        self:TeardownAll()
        DF:Say("Aura Explorer", "OFF", "NEUTRAL")
    end
end

-- ============================================================
-- BUILDER PANEL  (concept variant A — one card per row)
-- ============================================================

-- Sized to seat three 260-wide sliders on one line with even gutters:
-- 14 + 260 + 16 + 260 + 16 + 260 + 14. Row cards track it (PANEL_W - 28).
local PANEL_W = 840

local function toneHex(t) return GUI:ToneHex(t) end

local function buildRowCard(parent, i, y)
    local row = AE.rows[i]
    local col = AE:RowColor(i)

    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetSize(PANEL_W - 28, 34)
    card:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
    GUI:CreateElementBackdrop(card, {
        bgColor     = { 0.10, 0.10, 0.13, 0.9 },
        borderColor = { col[1], col[2], col[3], row.enabled and 0.9 or 0.25 },
    })

    -- enable toggle doubles as the row index badge
    local cb = CreateFrame("CheckButton", nil, card, "BackdropTemplate")
    cb:SetPoint("LEFT", 8, 0)
    GUI:StyleCheckButton(cb)
    cb:SetChecked(row.enabled)
    cb:SetScript("OnClick", function(self)
        row.enabled = self:GetChecked() and true or false
        AE:Rebuild()
    end)

    local idx = card:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    idx:SetPoint("LEFT", cb, "RIGHT", 6, 0)
    idx:SetText(tostring(i))
    idx:SetTextColor(col[1], col[2], col[3])

    -- category
    local cat = GUI:CreateButton(card, row.category or "HELPFUL", 78, 20, function(self)
        row.category = (row.category == "HARMFUL") and "HELPFUL" or "HARMFUL"
        self:SetText(row.category)
        AE:Rebuild()
    end)
    cat:SetPoint("LEFT", idx, "RIGHT", 8, 0)

    -- the resolved string + summary, which is the thing you are actually reading
    local spec = card:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    spec:SetPoint("LEFT", cat, "RIGHT", 10, 6)
    spec:SetJustifyH("LEFT")
    spec:SetText(AE:FilterString(row))
    spec:SetTextColor(0.6, 0.8, 1)

    local summ = card:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
    summ:SetPoint("LEFT", cat, "RIGHT", 10, -6)
    summ:SetJustifyH("LEFT")
    summ:SetText(AE:RowSummary(row))
    summ:SetTextColor(0.5, 0.5, 0.6)

    -- remove this row entirely (distinct from unticking it, which keeps the spec)
    local del = GUI:CreateCloseButton(card, {
        size    = 18,
        tone    = "danger",
        tooltip = "Remove row " .. i,
        onClick = function() AE:RemoveRow(i) end,
    })
    del:SetPoint("RIGHT", card, "RIGHT", -8, 0)

    -- edit opens the per-row picker
    local edit = GUI:CreateButton(card, "Edit…", 60, 20, function()
        AE:ShowRowEditor(i)
    end)
    edit:SetPoint("RIGHT", del, "LEFT", -6, 0)

    if AE:RowGated(row) then
        local warn = card:CreateFontString(nil, "OVERLAY", "DFFontNormalSmall")
        warn:SetPoint("RIGHT", edit, "LEFT", -10, 0)
        warn:SetText("|c" .. toneHex("caution") .. "gated|r")
    end

    return card
end

-- (Removed) AE:RefreshPanel — a one-line wrapper with no callers; the real callers
-- all use self.panel:Rebuild() directly.

function AE:CreatePanel()
    if self.panel then return self.panel end
    self:EnsureRows()

    local f = CreateFrame("Frame", "DFAuraExplorerPanel", UIParent, "BackdropTemplate")
    f:SetSize(PANEL_W, 100)
    f:SetPoint("CENTER", 0, 200)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    GUI:CreatePanelBackdrop(f)

    local title = f:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Aura Explorer")
    do
        local tc = GUI.GetThemeColor and GUI.GetThemeColor()
        if tc then title:SetTextColor(tc.r, tc.g, tc.b) end
    end

    local close = GUI:CreateCloseButton(f, { onClick = function() f:Hide() end, tooltip = "Close" })
    close:SetPoint("TOPRIGHT", -8, -8)

    local onBtn = GUI:CreateButton(f, AE.active and "Rows ON" or "Rows OFF", 90, 22, function(self)
        AE:SetActive(not AE.active)
        self:SetText(AE.active and "Rows ON" or "Rows OFF")
    end)
    -- ⚠ On the TITLE line, left of the close button — NOT below it. Below put it at
    -- the same y as the first slider line, where it sat on top of the third
    -- column's label and value box.
    onBtn:SetPoint("RIGHT", close, "LEFT", -8, 0)
    f.onBtn = onBtn

    -- ===== appearance sliders =====================================================
    -- Every one of these rebuilds. elementWidth/Height and maxFrameCount are baked
    -- into the group's layout at AddAuraGroup time; the font and text anchors are
    -- applied inside initializeFrame, which the engine runs once per button at
    -- creation and gives us no handle to revisit. Nothing here can be hot-applied,
    -- so the callback is honest about tearing down instead of pretending.
    --
    -- ⚠ Arg positions matter. CreateSlider is
    -- (parent, label, min, max, step, dbTable, dbKey, callback, lightweightUpdate,
    --  usePreviewMode, customGet, customSet, accentColor) — customGet/customSet are
    -- 11th and 12th, and 9th is a BOOLEAN. A table in slot 9 reads truthy and
    -- silently changes how the slider commits.
    -- Grouped under headers, three to a line: the two strip-geometry knobs, then
    -- one line each for the timer and the stack. Grouping matters more than
    -- compactness here — "Stack X" next to "Timer Y" invites setting the wrong one.
    -- ⚠ These are packed deliberately tight, and NOT off GUI.RowHeight.slider (46).
    -- That number is the layout engine's SLOT — 32px of content plus a 14px RowGap
    -- it inserts between stacked page rows. Placed by hand, that gap gets paid
    -- twice and the block turns into mostly air, crowding out the row cards which
    -- are what the panel is actually for.
    --
    -- Measured extents, so the numbers below are floors rather than taste:
    --   slider content = 32  (label 0..-12, track -18..-26, input -12..-32)
    --   header         = 25-tall box, text pinned to the BOTTOM — the ~11px above
    --                    the text IS the inter-group gap, already paid for.
    -- ☠ HEADER_H below ~24 puts the next slider's label on top of the header text.
    local SLIDER_W, SLIDER_H, PER_LINE = 260, 34, 3   -- 34 = 32 content + 2 breath
    local HEADER_H = 24
    local CARD_GAP = 6
    local y, col = -30, 0                              -- title ends ~-28

    local function group(title)
        if col ~= 0 then y = y - SLIDER_H; col = 0 end   -- close a part-full line
        local h = GUI:CreateHeader(f, title)
        h:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y)
        y = y - HEADER_H
    end
    local function addSlider(label, minV, maxV, get, set)
        local s = GUI:CreateSlider(f, label, minV, maxV, 1, nil, nil,
            function() AE:Rebuild() end, nil, nil, get, set)
        s:SetPoint("TOPLEFT", f, "TOPLEFT", 14 + col * (SLIDER_W + 16), y)
        col = col + 1
        if col >= PER_LINE then col = 0; y = y - SLIDER_H end
        return s
    end

    group("Strip")
    addSlider("Icon Size", 10, 48,
        function() return AE.iconSize end,
        function(v) AE.iconSize = math.floor(tonumber(v) or 22) end)
    -- Caps buttons per unit AND the strip's width, so this is also the knob for
    -- "my rows overlap the next unit's frame". A row with more matches than this
    -- stops drawing the overflow; it does not wrap — the strip is one line by design.
    addSlider("Buttons per Unit", 1, 24,
        function() return AE.maxIcons end,
        function(v) AE.maxIcons = math.floor(tonumber(v) or 10) end)

    group("Timer text")
    addSlider("Font Size", 6, 24,
        function() return AE.fontSize end,
        function(v) AE.fontSize = math.floor(tonumber(v) or 10) end)
    addSlider("X Offset", -24, 24,
        function() return AE.timerX end,
        function(v) AE.timerX = math.floor(tonumber(v) or 0) end)
    addSlider("Y Offset", -24, 24,
        function() return AE.timerY end,
        function(v) AE.timerY = math.floor(tonumber(v) or 0) end)

    group("Stack text")
    addSlider("Font Size", 6, 24,
        function() return AE.stackFontSize end,
        function(v) AE.stackFontSize = math.floor(tonumber(v) or 10) end)
    addSlider("X Offset", -24, 24,
        function() return AE.stackX end,
        function(v) AE.stackX = math.floor(tonumber(v) or -1) end)
    addSlider("Y Offset", -24, 24,
        function() return AE.stackY end,
        function(v) AE.stackY = math.floor(tonumber(v) or 1) end)

    -- Where the row cards start, derived rather than hardcoded: adding a slider or
    -- a group must not silently overlap the first card. `col ~= 0` means the last
    -- line is part-full and still occupies a row's height.
    f.cardTop = y - (col ~= 0 and SLIDER_H or 0) - CARD_GAP

    local cards = {}
    local addBtn
    function f:Rebuild()
        for _, c in ipairs(cards) do c:Hide(); c:SetParent(nil) end
        wipe(cards)
        AE:EnsureRows()
        local y = f.cardTop or -100   -- derived from the slider block; see CreatePanel
        for i = 1, #AE.rows do
            cards[#cards + 1] = buildRowCard(f, i, y)
            y = y - 38
        end

        -- "+ Add row" lives at the BOTTOM of the stack, where the next row will
        -- appear — so the button is where the thing it creates shows up.
        if addBtn then addBtn:Hide(); addBtn:SetParent(nil) end
        addBtn = GUI:CreateButton(f, "+ Add row", 100, 22, function() AE:AddRow() end)
        addBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 14, y - 2)
        y = y - 30

        f:SetHeight(-y + 14)
        if f.onBtn then f.onBtn:SetText(AE.active and "Rows ON" or "Rows OFF") end
    end

    self.panel = f
    f:Rebuild()
    -- ☠ CONTRACT: CreatePanel returns a HIDDEN panel; the caller decides to show it.
    -- CreateFrame hands back a frame that is already SHOWN, so the toggle in the
    -- slash handler ("if shown then hide else show") saw a freshly built panel as
    -- already-open and hid it — the first command appeared to do nothing and it
    -- took a second press to see anything. Same trap as the memory-test panel's
    -- arm-on-create: a new frame is shown, and Show() on it fires no OnShow.
    f:Hide()
    return f
end

-- ============================================================
-- ROW EDITOR
-- ============================================================
-- Deliberately a plain scrolling checklist rather than a nest of dropdowns: the
-- question being answered is "what happens if I add this one token", and that
-- wants every option visible at once.

function AE:ShowRowEditor(index)
    self:EnsureRows()
    local row = self.rows[index]
    if not row then return end

    local ed = self._editor
    if not ed then
        ed = CreateFrame("Frame", "DFAuraExplorerRowEditor", UIParent, "BackdropTemplate")
        ed:SetSize(608, 560)
        ed:SetFrameStrata("FULLSCREEN_DIALOG")
        ed:SetMovable(true)
        ed:EnableMouse(true)
        ed:RegisterForDrag("LeftButton")
        ed:SetScript("OnDragStart", ed.StartMoving)
        ed:SetScript("OnDragStop", ed.StopMovingOrSizing)
        ed:SetClampedToScreen(true)
        GUI:CreatePanelBackdrop(ed)

        ed.title = ed:CreateFontString(nil, "OVERLAY", "DFFontNormalLarge")
        ed.title:SetPoint("TOPLEFT", 14, -12)

        local c = GUI:CreateCloseButton(ed, { onClick = function() ed:Hide() end, tooltip = "Close" })
        c:SetPoint("TOPRIGHT", -8, -8)

        ed.widgets = {}
        self._editor = ed
    end

    ed:ClearAllPoints()
    ed:SetPoint("CENTER", 260, 0)
    ed.title:SetText("Row " .. index)
    local col = AE:RowColor(index)
    ed.title:SetTextColor(col[1], col[2], col[3])

    for _, w in ipairs(ed.widgets) do w:Hide(); w:SetParent(nil) end
    wipe(ed.widgets)

    -- TWO COLUMNS. Single-column, the full vocabulary (11 tokens + 9 flags + 4
    -- dispel types + 13 DF categories) is ~950px tall — off the bottom of a lot of
    -- screens. Two columns keeps every option visible at once, which is the whole
    -- point of a checklist over nested dropdowns.
    local COL_X = { 14, 310 }
    local colY  = { -46, -46 }
    local col   = 1
    local function useColumn(n) col = n end
    local function header(text)
        local h = GUI:CreateHeader(ed, text)
        h:SetPoint("TOPLEFT", COL_X[col], colY[col])
        ed.widgets[#ed.widgets + 1] = h
        colY[col] = colY[col] - 24
    end
    local function check(label, get, set)
        local cb = GUI:CreateCheckbox(ed, label, nil, nil,
            function() AE:Rebuild() end, get, set)
        cb:SetPoint("TOPLEFT", COL_X[col], colY[col])
        ed.widgets[#ed.widgets + 1] = cb
        colY[col] = colY[col] - 22
    end

    header("Tokens")
    for _, tok in ipairs(AE.TOKENS) do
        check(tok,
            function() return row.tokens and row.tokens[tok] end,
            function(v) row.tokens = row.tokens or {}; row.tokens[tok] = v or nil end)
    end

    header("Candidate filters")
    for _, flag in ipairs(AE.FLAGS) do
        check(flag,
            function() return row.flags and row.flags[flag] end,
            function(v) row.flags = row.flags or {}; row.flags[flag] = v or nil end)
    end

    useColumn(2)
    header("Dispel types")
    for _, dt in ipairs(AE.DISPEL_TYPES) do
        check("include " .. dt,
            function() return row.includeDispel and row.includeDispel[dt] end,
            function(v) row.includeDispel = row.includeDispel or {}; row.includeDispel[dt] = v or nil end)
    end

    -- ☠ ONE AT A TIME, on purpose. Two DF selections would have to be unioned into
    -- a single includeSpellIDs map, and the row would then no longer answer "what
    -- does THIS filter match" — which is the only question the tool is for. Picking
    -- one clears the other, and custom filters and presets are mutually exclusive
    -- for the same reason.
    header("DF filter  (one per row)")
    local R = DF.FilterRegistry
    if R and R.Categories then
        for _, cat in ipairs(R.Categories) do
            local key = cat.key
            check(cat.name,
                function() return row.dfPreset == key end,
                function(v)
                    row.dfPreset = v and key or nil
                    if v then row.dfCustom = nil end
                end)
        end
        local store = R.GetStore and R:GetStore()
        local customs = store and store.customFilters
        if customs and next(customs) then
            header("DF custom filters")
            for id, f in pairs(customs) do
                local cid = id
                check(f.name or ("custom " .. tostring(id)),
                    function() return row.dfCustom == cid end,
                    function(v)
                        row.dfCustom = v and cid or nil
                        if v then row.dfPreset = nil end
                    end)
            end
        end
    end

    ed:SetHeight(math.max(-colY[1], -colY[2]) + 30)
    ed:Show()
end

-- (Removed) DF FILTER PICKER — AE:SetRowDFPreset and AE:SetRowDFCustom. Neither had
-- a caller: the row editor sets row.dfPreset / row.dfCustom inline and calls
-- Rebuild itself. This section banner headed nothing else.

-- ============================================================
-- EVENTS
-- ============================================================
-- Frames come and go with the roster, and containers can only be stood up out of
-- combat. Rebuild on the two events that invalidate the strip set.
--
-- The frame is declared at the top of the file (see the note there) and its events
-- are registered/unregistered by SetActive, so it is fully idle until the tool is
-- switched on. The `AE.active` test below is kept as belt-and-braces for an event
-- already in flight when the tool is turned off.
ev:SetScript("OnEvent", function()
    if AE.active and not InCombatLockdown() then AE:Rebuild() end
end)

-- ============================================================
-- COMMAND
-- ============================================================

DF:RegisterDebugSlash("DFAURAEXP", "Aura filter row explorer", true, "/dfauraexp")
SlashCmdList["DFAURAEXP"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "off" then
        AE:SetActive(false)
        return
    elseif msg == "on" then
        AE:SetActive(true)
        return
    elseif msg == "rebuild" then
        AE:Rebuild()
        DF:Say("Aura Explorer", "rebuilt", "NEUTRAL")
        return
    end
    local p = AE:CreatePanel()
    if p:IsShown() then p:Hide() else p:Rebuild(); p:Show() end
end
