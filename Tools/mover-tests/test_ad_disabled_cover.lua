local NS = ...

-- ============================================================
-- A DISABLED AURA DESIGNER STAYS COVERED THROUGH A REBUILD
-- DandersFrames_Options/AuraDesigner/UI/Editor.lua
-- ------------------------------------------------------------
-- The "Aura Designer is disabled" cover hangs off S.mainFrame, and a full build
-- (every party/raid switch, a template switch) makes a new S.mainFrame. Only the
-- refresh used to raise the cover, and the page skips that refresh at an
-- unchanged size -- so after a switch a disabled designer was fully clickable
-- (Aphoex, reported repeatedly).
--
-- The real ApplyEnabledState is lifted out by name and run over fake frames; the
-- two places that must call it are checked in the source.
-- ============================================================

local src = options_file_source("AuraDesigner/UI/Editor.lua"):gsub("\r\n", "\n")

local function cut(header)
    local s = src:find(header, 1, true)
    if not s then return nil, nil end
    local e = src:find("\nend\n", s, true)
    return src:sub(s, e + 4), s
end

local body = cut("local function ApplyEnabledState()")
check(body ~= nil, "adcover: ApplyEnabledState exists")
if not body then do return end end

local W = { enabled = false, made = 0 }
local function frame()
    local f = { shown = true }
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:SetAllPoints() end
    return f
end
local S = {}
local env = setmetatable({
    S = S,
    L = setmetatable({}, { __index = function(_, k) return k end }),
    GUI = {
        SelectedMode = "party",
        CreateDisabledOverlay = function(_, parent)
            W.made = W.made + 1
            local o = frame(); o.parent = parent
            return o
        end,
    },
    DF = { IsAuraDesignerEnabledForMode = function() return W.enabled end },
}, { __index = _G })
local chunk = loadstring(body .. "\nreturn ApplyEnabledState", "@Editor.lua:ApplyEnabledState")
check(chunk ~= nil, "adcover: the lifted function compiles")
if not chunk then do return end end
setfenv(chunk, env)
local ApplyEnabledState = chunk()

-- One build of the island, as far as this cares: a main frame, its split
-- container, and the banner's checkbox.
local function build()
    S.mainFrame = frame()
    S.mainFrame.splitContainer = frame()
    S.enableBanner = { checkbox = { SetChecked = function(self, v) self.checked = v end } }
end

build()
ApplyEnabledState()
local cover = S.mainFrame.disabledOverlay
check(cover ~= nil and cover.shown, "adcover: disabled -- the cover is up")
check(cover and cover.parent == S.mainFrame.splitContainer, "adcover: ...over the split container")
check(not S.enableBanner.checkbox.checked, "adcover: ...and the Enable box is unticked")

-- The party/raid switch: a new main frame, no cover of its own yet.
build()
ApplyEnabledState()
check(S.mainFrame.disabledOverlay ~= nil and S.mainFrame.disabledOverlay.shown,
      "adcover: after a rebuild a disabled designer is covered again")
eq(W.made, 2, "adcover: (the rebuilt frame got a cover of its own)")

W.enabled = true
ApplyEnabledState()
check(not S.mainFrame.disabledOverlay.shown, "adcover: enabled -- the cover comes down")
check(S.enableBanner.checkbox.checked, "adcover: ...and the Enable box is ticked")
W.enabled = false
ApplyEnabledState()
check(S.mainFrame.disabledOverlay.shown, "adcover: disabled again -- the same cover goes back up")
eq(W.made, 2, "adcover: (no second cover on the same frame)")

-- ---- who calls it ----
-- The full build is everything in the island after the reuse path's return.
local island = cut("local function BuildAuraDesignerIsland(guiRef, pageRef, dbRef)") or ""
local full = island:match("\n        DF:AuraDesigner_RefreshPage%(%)\n        return\n    end\n(.*)$") or ""
check(full ~= "", "adcover: found the island's full-build path")
check(full:match("ApplyEnabledState%(%)%s*end%s*$") ~= nil,
      "adcover: the full build ends by applying the enable state")
local refresh = cut("function DF:AuraDesigner_RefreshPage()") or ""
check(refresh:find("ApplyEnabledState()", 1, true) ~= nil,
      "adcover: the refresh applies it too")
check(refresh:find("CreateDisabledOverlay", 1, true) == nil,
      "adcover: and the refresh no longer keeps its own copy of the cover")
