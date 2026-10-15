local NS = ...

-- ============================================================
-- MOVER TOOLTIPS NEVER SIT UNDER THE CURSOR
-- ------------------------------------------------------------
-- Tester report (v5.4.0-alpha.12): the top strip's tooltips sat under the
-- cursor. The kit's default tooltip goes up and to the right of the CURSOR,
-- and along the top edge there is no room up there -- the client clamps it
-- back down onto the pointer. Three pieces fix it, each pinned here:
--
--   1. the kit (DandersUI/Widgets.lua): ShowTooltip asks the host's
--      tooltipAnchor hook where a tooltip goes when the caller names no anchor;
--      an explicit opts.anchor (+ offsets) still wins, and a host with no hook
--      keeps the cursor default;
--   2. the mover's placement rule (NS.TooltipAnchor, cut out of Core.lua):
--      upper half of the screen -> BELOW the control; lower half -> the cursor
--      default, or ABOVE the owner for a slab;
--   3. the wiring: the mover's host passes that rule as its hook, so every
--      strip button, panel verb and settings row takes it with no per-call
--      change -- and a top-strip button ends up with its tooltip below it.
--
-- A FRESH NAMESPACE for the real Widgets.lua (as test_widgets_slider does), so
-- the factories other suites built their fixtures from are left alone. Every
-- replaced global is restored at the end.
-- ============================================================

local prevCreateFrame, prevTooltip = CreateFrame, GameTooltip

-- ---- a GameTooltip that records how it was owned --------------------
local owned
GameTooltip = FakeUIFrame()
function GameTooltip:SetOwner(owner, anchor, x, y) owned = { owner = owner, anchor = anchor, x = x, y = y } end
function GameTooltip:SetText() end
function GameTooltip:AddLine() end
function GameTooltip:AddDoubleLine() end

-- ---- the library table this file owns (what Widgets.lua reads at file scope)
local ns = {}
local UI = {
    _state = {}, _priv = {}, MEDIA = "",
    Colors = {
        panel   = { r = 0.12, g = 0.12, b = 0.12, a = 1 },
        element = { r = 0.18, g = 0.18, b = 0.18, a = 1 },
        border  = { r = 0.25, g = 0.25, b = 0.25, a = 1 },
        hover   = { r = 0.22, g = 0.22, b = 0.22, a = 1 },
        accent  = { r = 0.45, g = 0.45, b = 0.95, a = 1 },
        text    = { r = 0.9,  g = 0.9,  b = 0.9 },
        textDim = { r = 0.5,  g = 0.5,  b = 0.5 },
        notice  = { r = 0.91, g = 0.66, b = 0.25, a = 1 },
    },
    RowHeight = { slider = 50, checkbox = 35 },
    RowGap = 14,
}
ns.__DandersUI = UI
function UI.SnapLen(_, n) return n end
function UI.SnapHeightEven(_, n) return n end
function UI.StyleScrollBar() end
function UI._priv.CreateElementBackdrop(frame) return frame end
function UI._priv.CreatePanelBackdrop(frame) return frame end
function UI:Hook(name)
    local h = rawget(self, "hooks")
    return h and h[name] or nil
end
CreateFrame = function() return FakeUIFrame() end
load_ui_file_into("Widgets.lua", ns)

local function host(hooks) return setmetatable({ hooks = hooks }, { __index = UI }) end

-- ============================================================
-- 1. THE KIT
-- ============================================================
print("-- Tooltips: the kit asks the host where a tooltip goes")
do
    local owner = FakeUIFrame()
    local plain = host({ L = {} })
    owned = nil
    plain:ShowTooltip(owner, { title = "T" })
    eq(owned and owned.anchor, "ANCHOR_CURSOR_RIGHT", "kit: a host with no hook keeps the cursor default")

    local asked
    local placed = host({ L = {}, tooltipAnchor = function(o) asked = o return "ANCHOR_BOTTOM", 0, -4 end })
    owned = nil
    placed:ShowTooltip(owner, { title = "T" })
    eq(asked, owner, "kit: the hook is asked about the owner")
    eq(owned and owned.anchor, "ANCHOR_BOTTOM", "kit: ...and its anchor is used")
    eq(owned and owned.y, -4, "kit: ...with its offsets")

    local declines = host({ L = {}, tooltipAnchor = function() return nil end })
    owned = nil
    declines:ShowTooltip(owner, { title = "T" })
    eq(owned and owned.anchor, "ANCHOR_CURSOR_RIGHT", "kit: a hook that returns nil falls back to the cursor")

    owned = nil
    placed:ShowTooltip(owner, { title = "T", anchor = "ANCHOR_LEFT", anchorX = -3, anchorY = 2 })
    eq(owned and owned.anchor, "ANCHOR_LEFT", "kit: an explicit anchor beats the hook")
    eq(owned and owned.x, -3, "kit: ...and carries its x offset")
    eq(owned and owned.y, 2, "kit: ...and its y offset")
end

-- ============================================================
-- 2. THE MOVER'S RULE, cut out of Core.lua
-- ============================================================
local core = mover_file_source("Core.lua")
local s = core:find("local TIP_GAP", 1, true)
local e = s and core:find("\nend", core:find("function NS.TooltipAnchor", s, true), true)
check(s ~= nil and e ~= nil, "tooltips: NS.TooltipAnchor can be cut out of Core.lua")
local rule = {}
if s and e then
    assert(loadstring("local NS = ...\n" .. core:sub(s, e + 4), "@Core.lua:TooltipAnchor"))(rule)
end
local TooltipAnchor = rule.TooltipAnchor

print("-- Tooltips: the mover hangs top-of-screen tooltips below their control")
do
    check(type(TooltipAnchor) == "function", "rule: NS.TooltipAnchor exists")
    if TooltipAnchor then
        -- UIParent (shim) is 1920 x 1080, centred at (960, 540).
        -- The top strip's buttons: 10 units under the top edge.
        local stripBtn = FakeUIFrame(40, 18, 900, 1061)
        local a, x, y = TooltipAnchor(stripBtn)
        eq(a, "ANCHOR_BOTTOM", "rule: a strip button's tooltip hangs below it")
        check(type(y) == "number" and y < 0, "rule: ...with a gap under the button")
        eq(x, 0, "rule: ...centred on it")

        local low = FakeUIFrame(40, 18, 900, 200)
        eq(TooltipAnchor(low), nil, "rule: the lower half keeps the kit's cursor default")
        local la, _, ly = TooltipAnchor(low, true)
        eq(la, "ANCHOR_TOP", "rule: a slab in the lower half puts its tooltip above it")
        check(type(ly) == "number" and ly > 0, "rule: ...with a gap over the slab")

        local slabHigh = FakeUIFrame(200, 60, 1700, 1000)
        eq(TooltipAnchor(slabHigh, true), "ANCHOR_BOTTOM", "rule: a slab near the top puts its tooltip below it")

        -- GetCenter is in the owner's OWN units: a chrome-scaled strip (scale 2)
        -- centred at y=300 of its units is at y=600 of UIParent's -- upper half.
        local scaled = FakeUIFrame(40, 18, 450, 300)
        scaled:SetScale(2)
        eq(TooltipAnchor(scaled), "ANCHOR_BOTTOM", "rule: a scaled owner is judged in UIParent units")

        eq(TooltipAnchor(nil), nil, "rule: no owner, no opinion")
    end
end

-- ============================================================
-- 3. THE WIRING
-- The host hook is how every strip button, panel verb and settings row gets
-- the rule without naming an anchor. End to end: the real kit ShowTooltip,
-- the real rule as the hook, and a button where the strip puts it.
-- ============================================================
print("-- Tooltips: the mover's host routes every tooltip through the rule")
do
    check(core:find("tooltipAnchor%s*=%s*function%(owner%)%s*return NS%.TooltipAnchor%(owner%)") ~= nil,
          "wiring: Core.lua hands the rule to its kit host as tooltipAnchor")
    if TooltipAnchor then
        local mover = host({ L = {}, tooltipAnchor = function(o) return TooltipAnchor(o) end })
        for _, name in ipairs({ "Save & Exit", "Discard", "Undo", "Redo", "Settings", "Grid" }) do
            owned = nil
            mover:ShowTooltip(FakeUIFrame(60, 18, 960, 1061), { title = name })
            eq(owned and owned.anchor, "ANCHOR_BOTTOM", "wiring: '" .. name .. "' at the top edge shows its tooltip below the button")
        end
    end
    -- The strip's own specs must not pin an anchor, or they would skip the hook.
    local proxy = mover_file_source("Proxy.lua")
    local legend = proxy:sub(proxy:find("local function buildLegend", 1, true) or 1,
                             proxy:find("local function buildStripTab", 1, true) or #proxy)
    check(not legend:find("anchor%s*=%s*\"ANCHOR"), "wiring: no strip button pins its own tooltip anchor")
    -- The slab tooltip goes through the kit now, not raw GameTooltip.
    check(not proxy:find("GameTooltip:"), "wiring: Proxy.lua never drives GameTooltip directly")
end

CreateFrame, GameTooltip = prevCreateFrame, prevTooltip
