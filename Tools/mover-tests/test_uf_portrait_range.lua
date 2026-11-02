local NS = ...

-- ============================================================
-- UNIT FRAMES: THE PORTRAIT FADES OUT OF RANGE
-- Element range fade (oorEnabled) pins the frame at full alpha and each part fades
-- itself, and nothing faded the portrait. Pins the alpha sum (Portrait.lua
-- PO:ApplyAlpha) and the appearance step that drives it.
-- ============================================================

print("-- Unit frames: the portrait fades out of range")

local EA = df_file_source("Features/ElementAppearance.lua"):gsub("\r\n", "\n")
check(EA:find('"UpdateFrameOwnedAppearance",', 1, true) ~= nil, "the appearance pass has a step for frame-owned parts")

local PORTRAIT = uf_file_source("Portrait.lua"):gsub("\r\n", "\n")
check(PORTRAIT ~= nil, "Portrait.lua can be read")
if not PORTRAIT then return end

local s = PORTRAIT:find("function PO:ApplyAlpha(f, hovered)", 1, true)
local e = s and PORTRAIT:find("\nend\n", s, true)
check(s ~= nil and e ~= nil, "PO:ApplyAlpha can be cut out")
if not (s and e) then return end
check(PORTRAIT:find("f.dfOnElementAppearance = function(owner)", 1, true) ~= nil, "the portrait registers for the appearance pass")

local secretFlag = {}
local chunk = loadstring("local PO, K, issecretvalue = ...\n" .. PORTRAIT:sub(s, e + 4))
check(chunk ~= nil, "the cut parses")
if not chunk then return end
local PO, DB = { DIM = 0.5 }, {}
chunk(PO, { DB = function() return DB end }, function(v) return v == secretFlag end)

local function run(inRange, hovered, secretSetter)
    local p = { alpha = nil }
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

DB = { oorEnabled = false, portraitAlpha = 0.8, oorPortraitAlpha = 0.25 }
eq(run(false).alpha, 0.8, "frame mode: the frame's alpha does the fading, not the portrait")

check(PO:ApplyAlpha({}) == nil, "no portrait: nothing happens")
