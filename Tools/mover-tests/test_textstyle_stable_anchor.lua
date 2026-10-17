local NS = ...

-- ============================================================
-- COUNTDOWN TEXT FOLLOWS ITS ANCHOR (DandersFrames/Frames/TextStyle.lua)
-- ------------------------------------------------------------
-- stableCenter gives duration text a fixed box far wider than the icon. Centred inside
-- that box, a corner anchor drew the text half a box away from the corner (BOTTOMRIGHT
-- landed left of the icon, bug #1138). The box now aligns its text to the edge the
-- anchor names, and the shadow compensation only applies to a centred axis.
-- BEHAVIOURAL: the real TextStyle:Apply against a recording FontString.
-- ============================================================

print("-- TextStyle: stableCenter text aligns to the anchor's edge")

local ns = {}
function ns:GetDB() return { fontShadowOffsetX = 2, fontShadowOffsetY = -2 } end
load_df_file_into("Frames/TextStyle.lua", ns)
local TS = ns.TextStyle

local function fakeFS()
    local fs = { calls = {} }
    function fs:GetParent() return "parent" end
    function fs:ClearAllPoints() end
    function fs:SetPoint(p, rel, rp, x, y) self.point, self.x, self.y = p, x, y end
    function fs:SetSize(w, h) self.w, self.h = w, h end
    function fs:SetWordWrap() end
    function fs:SetJustifyH(v) self.jh = v end
    function fs:SetJustifyV(v) self.jv = v end
    function fs:SetTextColor() end
    function fs:SetAlpha() end
    return fs
end

local function apply(anchor, outline)
    local fs = fakeFS()
    TS:Apply(fs, { anchor = anchor, offsetX = 0, offsetY = 0, size = 10,
                   outline = outline or "NONE", stableCenter = true }, "icon")
    return fs
end

local cases = {
    { "CENTER", "CENTER", "MIDDLE" }, { "BOTTOMRIGHT", "RIGHT", "BOTTOM" },
    { "TOPLEFT", "LEFT", "TOP" }, { "BOTTOMLEFT", "LEFT", "BOTTOM" },
    { "TOPRIGHT", "RIGHT", "TOP" }, { "LEFT", "LEFT", "MIDDLE" },
    { "RIGHT", "RIGHT", "MIDDLE" }, { "TOP", "CENTER", "TOP" }, { "BOTTOM", "CENTER", "BOTTOM" },
}
for _, c in ipairs(cases) do
    local fs = apply(c[1])
    eq(fs.point, c[1], "stable anchor: " .. c[1] .. " anchors on " .. c[1])
    eq(fs.jh, c[2], "stable anchor: " .. c[1] .. " aligns horizontally " .. c[2])
    eq(fs.jv, c[3], "stable anchor: " .. c[1] .. " aligns vertically " .. c[3])
end

do  -- the shadow half-offset only lands on a centred axis
    local fs = apply("CENTER", "SHADOW")
    eq(fs.x, 1, "stable shadow: CENTER keeps the X compensation")
    eq(fs.y, -1, "stable shadow: ...and the Y compensation")
    fs = apply("BOTTOMRIGHT", "SHADOW")
    eq(fs.x, 0, "stable shadow: an edge-aligned X takes no compensation")
    eq(fs.y, 0, "stable shadow: ...nor an edge-aligned Y")
    fs = apply("TOP", "SHADOW")
    eq(fs.x, 1, "stable shadow: TOP is still centred on X")
    eq(fs.y, 0, "stable shadow: ...but not on Y")
end

do  -- a user-set Justify still wins over the anchor's edge
    local fs = fakeFS()
    TS:Apply(fs, { anchor = "BOTTOMRIGHT", size = 10, stableCenter = true, justifyH = "LEFT", boxW = 20 }, "icon")
    eq(fs.jh, "LEFT", "stable anchor: a user Justify overrides the anchor edge")
end
