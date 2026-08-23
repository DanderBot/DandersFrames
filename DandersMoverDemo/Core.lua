local addonName, NS = ...

-- ============================================================
-- DANDERSMOVER DEMO
-- A third-party-style consumer of DandersMover. It talks to the library
-- exclusively through the public API documented in DandersMover/README.md
-- (LibStub("DandersMover-1.0") plus Mover:Register* / Mover.ApplyPosition) and
-- never reaches into the library's addon table or internals.
--
-- With DandersMover absent the addon still loads: the frames are created and
-- positioned from the saved records directly, and nothing else happens.
-- ============================================================

local CreateFrame, UIParent, InCombatLockdown = CreateFrame, UIParent, InCombatLockdown
local UnitAffectingCombat, Minimap = UnitAffectingCombat, Minimap
local pairs, ipairs, type, print = pairs, ipairs, type, print
local format, wipe = string.format, wipe

local LOGO = "Interface\\AddOns\\DandersMoverDemo\\Media\\Logo"

-- Dev-only addon: plain print is deliberate here. There is no debug console to
-- route through and nothing user-facing to localise.
local function Print(msg)
    print("|cffffa500MoverDemo:|r " .. msg)
end

-- ============================================================
-- ELEMENT DEFINITIONS
-- Defaults are spread across the screen so every element lands somewhere
-- visible on a fresh install.
-- ============================================================
local ELEMENTS = {
    {
        key = "healthbar", title = "Health Bar", group = "Bars",
        w = 220, h = 28, color = { 0.20, 0.65, 0.32 },
        default = { point = "CENTER", x = -320, y = 120 },
    },
    {
        -- getRect is deliberately 10px tighter than the frame on every side, so
        -- the visible rect and the frame geometry disagree. Snap zones, the
        -- proxy and the drag maths should all follow the inset rect.
        key = "buffrow", title = "Buff Row (rect inset 10px)", group = "Bars",
        w = 260, h = 40, scale = 0.9, inset = 10, color = { 0.30, 0.45, 0.85 },
        default = { point = "CENTER", x = 0, y = 220 },
    },
    {
        key = "iconstrip", title = "Icon Strip", group = "Icons",
        w = 48, h = 200, color = { 0.85, 0.55, 0.15 },
        default = { point = "CENTER", x = 340, y = 60 },
    },
    {
        -- 20x20 is under the library's minimum proxy size, so its proxy has to
        -- grow past the frame it represents.
        key = "tinybadge", title = "Tiny Badge", group = "Icons",
        w = 20, h = 20, color = { 0.85, 0.25, 0.55 },
        default = { point = "CENTER", x = -140, y = -190 },
    },
    {
        -- Hidden out of combat. Exercises proxies for frames that are not on
        -- screen when the editor is unlocked.
        key = "combatonly", title = "Combat Only", group = "Misc",
        w = 150, h = 30, color = { 0.75, 0.20, 0.20 }, combatOnly = true,
        default = { point = "CENTER", x = 160, y = -190 },
    },
}

local SECURE = {
    key = "secure", title = "Secure Unit Button", group = "Misc",
    w = 120, h = 40, color = { 0.55, 0.35, 0.75 },
    default = { point = "CENTER", x = 0, y = -290 },
}

-- ============================================================
-- STATE
-- ============================================================
local Mover                 -- the library handle, or nil when not installed
local frames = {}           -- key -> frame
local defs = {}             -- key -> definition (ELEMENTS entries + SECURE)
local visible = true        -- /mdemo show|hide

-- ============================================================
-- FRAME CONSTRUCTION
-- ============================================================

-- Coloured background with a 1px border: the border texture fills the frame,
-- the fill sits 1px inside it.
local function build(def, secure)
    local name = "DandersMoverDemo" .. (secure and "Secure" or def.key)
    local f
    if secure then
        f = CreateFrame("Button", name, UIParent, "SecureUnitButtonTemplate")
        f:SetAttribute("unit", "player")
    else
        f = CreateFrame("Frame", name, UIParent)
    end
    f:SetSize(def.w, def.h)
    if def.scale then f:SetScale(def.scale) end

    local border = f:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0, 0, 0, 0.9)

    local fill = f:CreateTexture(nil, "BORDER")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", -1, 1)
    fill:SetColorTexture(def.color[1], def.color[2], def.color[3], 0.65)

    local logoSize = math.min(16, def.w - 4, def.h - 4)
    if logoSize > 0 then
        local logo = f:CreateTexture(nil, "ARTWORK")
        logo:SetTexture(LOGO)
        logo:SetSize(logoSize, logoSize)
        logo:SetPoint("TOPLEFT", 2, -2)
    end

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(def.title)

    return f
end

-- ============================================================
-- POSITION RECORDS
-- The consumer owns these outright; the library only reads and edits them.
-- ============================================================
local function copyDefault(default)
    return { point = default.point, x = default.x, y = default.y }
end

local function record(def)
    local db = DandersMoverDemoDB.positions
    if type(db[def.key]) ~= "table" then
        db[def.key] = copyDefault(def.default)
    end
    return db[def.key]
end

-- Fallback for when DandersMover is not installed: point/x/y are always valid
-- absolute coordinates, so applying them by hand is all that is needed.
local function applyPositionFallback(frame, pos)
    local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    frame:ClearAllPoints()
    frame:SetPoint(pos.point or "CENTER", UIParent, "CENTER",
        (pos.x or 0) / ratio, (pos.y or 0) / ratio)
end

local function applyPosition(frame, pos)
    if Mover then
        Mover.ApplyPosition(frame, pos)
    else
        applyPositionFallback(frame, pos)
    end
end

-- Visible rect in UIParent units measured from UIParent's centre, shrunk by
-- `inset` on every side. Same centre, smaller extent.
local function insetRect(frame, inset)
    local cx, cy = frame:GetCenter()
    if not cx then return nil end
    local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    return {
        x = cx * ratio - ux,
        y = cy * ratio - uy,
        w = frame:GetWidth() * ratio - inset * 2,
        h = frame:GetHeight() * ratio - inset * 2,
    }
end

-- ============================================================
-- COMBAT VISIBILITY
-- The "Combat Only" frame is shown in combat and hidden the rest of the time.
-- ============================================================
local function updateCombatFrame()
    local f = frames.combatonly
    if not f then return end
    if visible and UnitAffectingCombat("player") then f:Show() else f:Hide() end
end

-- ============================================================
-- REGISTRATION
-- ============================================================
local function registerAll()
    if not Mover then return end

    Mover:RegisterAddon("DandersMoverDemo", { title = "Mover Demo", icon = LOGO })

    for _, def in ipairs(ELEMENTS) do
        local f = frames[def.key]
        local pos = record(def)
        local reg = {
            title     = def.title,
            frame     = f,
            group     = def.group,
            default   = def.default,
            getPos    = function() return pos end,
            onChanged = function(p) Mover.ApplyPosition(f, p) end,
        }
        if def.inset then
            reg.getRect = function() return insetRect(f, def.inset) end
        end
        if def.combatOnly then
            -- Declares "only meaningful while in combat". DandersMover 1.0 does
            -- not read isRelevant, so today this is documentation of intent
            -- rather than behaviour; it is harmless if the field stays ignored.
            reg.isRelevant = function() return UnitAffectingCombat("player") end
        end
        Mover:Register("DandersMoverDemo", def.key, reg)
    end

    local sf, spos = frames[SECURE.key], record(SECURE)
    Mover:Register("DandersMoverDemo", SECURE.key, {
        title   = SECURE.title,
        frame   = sf,
        group   = SECURE.group,
        default = SECURE.default,
        secure  = true,
        getPos  = function() return spos end,
        -- Moving a protected frame is forbidden in combat. The library defers
        -- the call for secure elements, and this guard makes the bail explicit.
        onChanged = function(p)
            if InCombatLockdown() then return end
            Mover.ApplyPosition(sf, p)
        end,
    })

    -- A Blizzard frame as an anchor target: not movable by us, but other
    -- elements (ours or another addon's) can anchor to it.
    if Minimap then
        Mover:RegisterAnchorTarget("DandersMoverDemo", "minimap", {
            title = "Minimap",
            frame = Minimap,
        })
    end
end

local function applyAll()
    for _, def in ipairs(ELEMENTS) do
        applyPosition(frames[def.key], record(def))
    end
    local sf = frames[SECURE.key]
    if not InCombatLockdown() then
        applyPosition(sf, record(SECURE))
    end
end

-- ============================================================
-- SLASH COMMAND
-- ============================================================
local function setVisible(show)
    visible = show
    for _, def in ipairs(ELEMENTS) do
        local f = frames[def.key]
        if def.combatOnly then
            updateCombatFrame()
        elseif show then
            f:Show()
        else
            f:Hide()
        end
    end
    local sf = frames[SECURE.key]
    -- Showing or hiding a protected frame is itself protected.
    if InCombatLockdown() then
        Print("secure frame left as-is (in combat).")
    elseif show then
        sf:Show()
    else
        sf:Hide()
    end
end

-- Reset in place rather than wiping the positions table: the getPos closures
-- handed to the library captured these exact tables, so replacing them would
-- leave the library reading orphaned records.
local function resetOne(def)
    local pos = record(def)
    wipe(pos)
    pos.point, pos.x, pos.y = def.default.point, def.default.x, def.default.y
end

local function resetPositions()
    for _, def in ipairs(ELEMENTS) do resetOne(def) end
    resetOne(SECURE)
    applyAll()
    if Mover then
        for _, def in ipairs(ELEMENTS) do
            Mover:Apply("DandersMoverDemo", def.key)
        end
        Mover:Apply("DandersMoverDemo", SECURE.key)
    end
    Print("positions reset to defaults.")
end

local function printStatus()
    Print(Mover and "DandersMover detected." or "DandersMover NOT installed (fallback positioning).")
    local all = {}
    for _, def in ipairs(ELEMENTS) do all[#all + 1] = def end
    all[#all + 1] = SECURE
    for _, def in ipairs(all) do
        local pos = record(def)
        local anchor = pos.anchor and pos.anchor.target or "none"
        Print(format("%s [%s]  point=%s  x=%.1f  y=%.1f  anchor=%s",
            def.title, def.key, tostring(pos.point or "CENTER"),
            pos.x or 0, pos.y or 0, anchor))
    end
end

SLASH_DANDERSMOVERDEMO1 = "/mdemo"
SlashCmdList.DANDERSMOVERDEMO = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")
    if cmd == "show" then
        setVisible(true)
    elseif cmd == "hide" then
        setVisible(false)
    elseif cmd == "reset" then
        resetPositions()
    elseif cmd == "unlock" then
        if Mover then
            Mover:Unlock("DandersMoverDemo")
        else
            Print("DandersMover is not installed.")
        end
    elseif cmd == "status" then
        printStatus()
    else
        Print("usage: /mdemo show | hide | reset | unlock | status")
    end
end

-- ============================================================
-- BOOTSTRAP
-- ============================================================
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        events:UnregisterEvent("ADDON_LOADED")

        DandersMoverDemoDB = DandersMoverDemoDB or {}
        DandersMoverDemoDB.positions = DandersMoverDemoDB.positions or {}

        for _, def in ipairs(ELEMENTS) do
            defs[def.key] = def
            frames[def.key] = build(def, false)
            record(def)
        end
        defs[SECURE.key] = SECURE
        frames[SECURE.key] = build(SECURE, true)
        record(SECURE)
        updateCombatFrame()

        -- LibStub only exists once DandersMover (which bundles it) has loaded.
        if LibStub then
            Mover = LibStub("DandersMover-1.0", true)
        end
        registerAll()
        applyAll()
    else
        updateCombatFrame()
    end
end)

-- Exposed for /run poking during manual testing only.
NS.frames = frames
NS.defs = defs
_G.DandersMoverDemo = NS
