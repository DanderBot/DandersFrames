local NS = ...

-- ============================================================
-- UNIT FRAMES: THEIR OWN PARTS FOLLOW THE RANGE FADE
-- Element range fade (oorEnabled) pins the frame at full alpha and each part fades
-- itself, and nothing faded the portrait, cast bar, power ring or elite art. Pins the
-- alpha sum (Elements.lua K.RangeAlpha, Portrait.lua PO:ApplyAlpha) and the appearance
-- step that drives them.
-- ============================================================

print("-- Unit frames: their own parts follow the range fade")

local EA = df_file_source("Features/ElementAppearance.lua"):gsub("\r\n", "\n")
check(EA:find('"UpdateFrameOwnedAppearance",', 1, true) ~= nil, "the appearance pass has a step for frame-owned parts")
check(uf_file_source("Units.lua"):find("f.dfOnElementAppearance = UF.OnElementAppearance", 1, true) ~= nil, "a live frame joins the appearance pass")
check(uf_file_source("Preview.lua"):find("f.dfOnElementAppearance = UF.OnElementAppearance", 1, true) ~= nil, "...and a preview")

local ELEMENTS = uf_file_source("Elements.lua"):gsub("\r\n", "\n")
check(ELEMENTS:find('E:Call("ApplyRange", f)', 1, true) ~= nil, "the pass reaches every element")
for _, file in ipairs({ "Portrait.lua", "CastBar.lua", "Indicators.lua", "Rings.lua" }) do
    check(uf_file_source(file):find(":ApplyRange(f)", 1, true) ~= nil, file .. " follows the range fade")
end

local function cut(src, start)
    local s = src:find(start, 1, true)
    local e = s and src:find("\nend\n", s, true)
    return s and e and src:sub(s, e + 4)
end
local PORTRAIT = uf_file_source("Portrait.lua"):gsub("\r\n", "\n")
local rangeFn, alphaFn = cut(ELEMENTS, "function K.RangeAlpha("), cut(PORTRAIT, "function PO:ApplyAlpha(f, hovered)")
check(rangeFn ~= nil and alphaFn ~= nil, "K.RangeAlpha and PO:ApplyAlpha can be cut out")
if not (rangeFn and alphaFn) then return end

local secretFlag = {}
local chunk, err = loadstring("local PO, K, issecretvalue = ...\n" .. rangeFn .. alphaFn)
check(chunk ~= nil, "the cut parses (" .. tostring(err) .. ")")
if not chunk then return end
local PO, DB = { DIM = 0.5 }, {}
chunk(PO, { DB = function() return DB end }, function(v) return v == secretFlag end)

local function run(inRange, hovered, secretSetter)
    local p = {}
    function p:SetAlpha(a) self.alpha = a end
    if secretSetter then
        function p:SetAlphaFromBoolean(flag, a, b) self.flag, self.alpha, self.oor = flag, a, b end
    end
    PO:ApplyAlpha({ dfUFPortrait = p, dfInRange = inRange }, hovered)
    return p
end

DB = { oorEnabled = true, portraitAlpha = 0.8, oorPortraitAlpha = 0.25, portraitDimHover = true }
eq(run(true).alpha, 0.8, "in range: the portrait's own alpha")
eq(run(nil).alpha, 0.8, "no range answer yet: in range")
eq(run(false).alpha, 0.2, "out of range: own alpha x Portrait Alpha")
eq(run(false, true).alpha, 0.1, "...and the hover dim composes with it")

local p = run(secretFlag, false, true)
check(p.flag == secretFlag, "a secret answer goes to the engine, unread")
eq(p.alpha, 0.8, "...with the in-range alpha")
eq(p.oor, 0.2, "...and the out-of-range alpha")
eq(run(secretFlag).alpha, 0.8, "a secret answer with no secret setter: held in range")

DB = { oorEnabled = false, portraitAlpha = 0.8, oorPortraitAlpha = 0.25 }
eq(run(false).alpha, 0.8, "frame mode: the frame's alpha does the fading, not the part")

check(PO:ApplyAlpha({}) == nil, "no portrait: nothing happens")
