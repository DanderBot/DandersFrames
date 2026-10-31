local NS = ...

-- ============================================================
-- UNIT PAGES: A BARE HEADER OVER ONLY FILTERED CARDS GOES TOO
-- The party Frame page's "Content" header hides on GUI.SelectedMode ~= "raid";
-- under a unit page with Raid underneath it showed over nothing (its only card,
-- Group Visibility, is filtered for units). UFO.HideFilteredControls now hides a
-- bare header whose same-column widgets up to the next header are all filtered.
-- ============================================================

local function norm(s) return (s:gsub("\r\n", "\n")) end
local PAGES = norm(options_file_source("UnitFrames/Pages.lua"))
local a = PAGES:find("%-%- Controls whose search entry the build marked")
local b = PAGES:find("\nfunction UFO%.CardAllowed%(")
check(a ~= nil and b ~= nil, "lift: HideFilteredControls .. CardAllowed")
if not (a and b) then return end

local UFO = {}
local function Never() return true end
local f, err = loadstring(PAGES:sub(a, b), "=OrphanHeaders")
check(f ~= nil, "lift: parses (" .. tostring(err) .. ")")
if not f then return end
setfenv(f, setmetatable({ UFO = UFO, Never = Never }, { __index = _G }))
f()

local function header(col, hideOn) return { isSectionHeader = true, layoutCol = col, hideOn = hideOn } end
local function card(col, filtered) return { layoutCol = col, dfFilteredOut = filtered or nil } end
local function spacer(col) return { layoutCol = col, isSpacer = true } end
local function control(col, filtered)
    return { layoutCol = col, searchEntry = { dfFilteredOut = filtered or nil } }
end
local function raidOnly() return false end   -- "Raid underneath": the header's own rule says show

print("-- the Content case")
local content = header(1, raidOnly)
local list = {
    { layoutCol = "both" },                -- page tools
    content, card(1, true), card(1, true), spacer(1),
    header(1), card(1), card(1),           -- Layout: real cards
}
UFO.HideFilteredControls(list)
eq(content.hideOn, Never, "Content over only filtered cards: hidden")
check(list[7].hideOn == nil, "Layout over real cards: untouched")

print("-- headers that keep their place")
local mixed = header(1)
local l2 = { mixed, card(1, true), card(1) }
UFO.HideFilteredControls(l2)
check(mixed.hideOn == nil, "one real card left: header stays")

local otherCol = header(1)
local l3 = { otherCol, card(2), card(1, true) }
UFO.HideFilteredControls(l3)
eq(otherCol.hideOn, Never, "a column-2 card does not keep a column-1 header")

local empty = header(1)
local l4 = { empty, spacer(1) }
UFO.HideFilteredControls(l4)
check(empty.hideOn == nil, "a header with nothing filtered under it is left to its own rule")

local ctl = header(2)
local l5 = { ctl, control(2, true), control(2, true), header(2), control(2) }
UFO.HideFilteredControls(l5)
eq(ctl.hideOn, Never, "filtered single controls count as filtered")
eq(l5[2].hideOn, Never, "...and the controls themselves are hidden")
check(l5[4].hideOn == nil, "the next header, over a real control, stays")

print("-- the markers the rule reads are stamped at the source")
local CONTROLS = norm(options_file_source("GUI/Controls.lua"))
check(CONTROLS:find("if filtered then section.dfFilteredOut = true end", 1, true)
      and CONTROLS:find("if filtered then band.dfFilteredOut = true end", 1, true),
      "a filtered card's header bar and band are marked")
check(norm(options_file_source("GUI/Panel.lua")):find("spacer.isSpacer = true", 1, true),
      "AddSpace marks its spacers")
