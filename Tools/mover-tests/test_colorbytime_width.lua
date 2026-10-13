local NS = ...

-- ============================================================
-- COLOR BY TIME FILLS ITS CARD
-- DandersFrames_Options/GUI/Pages/Auras.lua
-- ------------------------------------------------------------
-- The Seconds / Percent tabs and the editor's colour band were built at the
-- classic box's width (two 128 tabs, bands placed across 256) and stayed that
-- size in a wider Modern card. The tabs now anchor to their halves of the row,
-- and the band re-places its segments from its live width. BuildStrip is lifted
-- out and run over fake frames.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Auras.lua"):gsub("\r\n", "\n")

print("-- Color by Time: the tabs and the band fill the card")
check(SRC:find('tabBtn:SetPoint("BOTTOMRIGHT", tabRow, "BOTTOM", -2, 0)', 1, true) ~= nil
  and SRC:find('tabBtn:SetPoint("TOPLEFT", tabRow, "TOP", 2, 0)', 1, true) ~= nil,
      "tabs: each tab anchors to its half of the row, not to a fixed width")

local s = SRC:find("        local previewW, stripH = 256, 18\n", 1, true)
local e = s and SRC:find("\n            return f\n        end\n", s, true)
check(s ~= nil and e ~= nil, "band: BuildStrip is found")
if not (s and e) then do return end end
local block = SRC:sub(s, e + #"\n            return f\n        end\n") .. "\nreturn BuildStrip"

local function frame()
    local f = { scripts = {}, w = 0 }
    function f:SetSize(w) self.w = w end
    function f:SetScript(n, fn) self.scripts[n] = fn end
    function f:CreateTexture()
        local t = {}
        function t:SetColorTexture() end
        function t:ClearAllPoints() self.x = nil end
        function t:SetPoint(_, _, _, x) self.x = x end
        function t:SetSize(w) self.w = w end
        return t
    end
    return f
end
local stops = { { threshold = 0 }, { threshold = 3 }, { threshold = 6 }, { threshold = 9 } }
local env = setmetatable({
    self = { child = {} },
    CreateFrame = function() return frame() end,
    cbtGlobalDB = { bp = stops },
    CBT_RAMPS = { SECONDS = { bpKey = "bp" } },
    CBT_UNITS = { SECONDS = { maxT = 12 } },
    cbtT = function(x) return math.max(0, tonumber(x and x.threshold) or 0) end,
}, { __index = _G })
local chunk = loadstring(block, "@Auras.lua:BuildStrip")
check(chunk ~= nil, "band: ...and compiles on its own")
if not chunk then do return end end
setfenv(chunk, env)
local BuildStrip = chunk()
local strip = BuildStrip(256, 18, false, "SECONDS")
local last = strip.segs[#strip.segs]
eq(#strip.segs, 4, "band: one segment per stop")
eq(last.tex.x + last.tex.w, 256, "band: built at 256, the bands end at 256")
check(strip.scripts.OnSizeChanged ~= nil, "band: it follows its size")
strip.scripts.OnSizeChanged(strip, 400)
eq(last.tex.x + last.tex.w, 400, "band: stretched to a 400 card, the bands end at 400")
eq(strip.segs[2].tex.x, 100, "band: ...each one at its share of the width (3s of 12 -> 100)")
