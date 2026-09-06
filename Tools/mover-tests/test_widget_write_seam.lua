local NS = ...

-- ============================================================
-- WHAT A HAND-ROLLED SETTINGS WIDGET OWES ITS PAGE
-- DandersFrames_Options/GUI/Controls.lua, GUI/SettingsWidgets.lua, DandersUI/Widgets.lua
-- ------------------------------------------------------------
-- Two faults with one shape, both reported against the popout layout and both
-- older than it.
--
-- ONE: a dropdown menu is a plain Frame that sets a high strata and takes no
-- mouse. Strata only ORDERS frames that take the mouse, so the menu was opaque
-- to the eye and invisible to the cursor: a click on its padding, its border
-- inset or the empty tail below the last item went straight through and wrote
-- whatever control was underneath. Roughly thirty settings were reachable that
-- way, which is every font, texture and mini dropdown in the addon.
--
-- TWO: a widget commits a write and nothing re-reads the page. `RefreshStates`
-- is stamped by the host on whatever a control was parented to -- a page's
-- scroll child, or the holder behind a popout pane -- and running it is what
-- re-runs every `disableOn` and re-reads every popout row summary. The checkbox
-- and the kit dropdown made that call; the font, texture and sound dropdowns,
-- the colour picker and the three drag-reorder lists never did, in EITHER
-- layout. Their rows sat stale until a tab change.
--
-- Source-level where the factory builds real frames and cannot run headlessly;
-- driven where it can (the border seed below, and the kit slider's own suite in
-- test_widgets_slider.lua, which counts the sweeps a drag does NOT do).
-- ============================================================

local CTRL = options_file_source("GUI/Controls.lua")
local SW   = options_file_source("GUI/SettingsWidgets.lua")
local KIT  = ui_file_source("Widgets.lua")

-- One factory's body, from its header to the next top-level `end` at column
-- zero -- so a body read this way cannot borrow its neighbour's call.
local function factoryBody(src, name)
    local a = src:find("function GUI:" .. name .. "(", 1, true)
    check(a ~= nil, "source: " .. name .. " is declared")
    if not a then return "" end
    local b = src:find("\nend\n", a, true)
    check(b ~= nil and b > a, "source: ..." .. name .. " closes at the file's own indent")
    return src:sub(a, b or a)
end

-- ============================================================
-- 1. EVERY DROPDOWN MENU TAKES THE MOUSE
-- ============================================================
print("-- Menus: every dropdown menu frame swallows the clicks that land on it")
do
    -- ⚠ Counted rather than listed, so a SIXTH menu added tomorrow fails here
    -- instead of quietly shipping the leak the other five were fixed for.
    local function menuSites(src)
        local total, unguarded, i = 0, 0, 1
        while true do
            local a = src:find('local menuFrame = CreateFrame("Frame"', i, true)
            if not a then break end
            total = total + 1
            -- The frame is configured in one uninterrupted run, and the mouse has
            -- to be on it before it is published to the open-menu registry.
            local window = src:sub(a, a + 1400)
            local em  = window:find("menuFrame:EnableMouse(true)", 1, true)
            local reg = window:find("RegisterMenu(menuFrame)", 1, true)
            if not (em and reg and em < reg) then unguarded = unguarded + 1 end
            i = a + 1
        end
        return total, unguarded
    end

    local n, bad = menuSites(CTRL)
    eq(n, 4, "menus: Controls.lua builds four of them -- mini, texture, font, sound")
    eq(bad, 0, "menus: ...and every one takes the mouse before it is registered")

    local kn, kbad = menuSites(KIT)
    eq(kn, 1, "menus: the kit's plain dropdown builds the fifth")
    eq(kbad, 0, "menus: ...and it takes the mouse too")

    -- The precedent this copies, so the two cannot drift into disagreeing about
    -- whether a floating surface is allowed to leak.
    local popout = ui_file_source("Popout.lua")
    check(popout:find("f:EnableMouse(true)", 1, true) ~= nil,
          "menus: the kit's popout panel already refused to leak clicks")
end

-- ============================================================
-- 2. ONE COMMIT-SIDE STATE SEAM, ONE COPY OF IT PER ADDON
-- ============================================================
print("-- Write seam: the commit-side refresh helper, declared once and reachable")
do
    check(SW:find("local function RefreshOwnerStates(parent)", 1, true) ~= nil,
          "seam: SettingsWidgets declares the helper")
    -- ☠ rawget, not `if parent.RefreshStates`. Headless, a fake frame answers any
    -- unset field with a truthy no-op FUNCTION, so a plain truthiness test passes
    -- on a parent that never carried the stamp and no test can see it go missing.
    check(SW:find('rawget(parent, "RefreshStates")', 1, true) ~= nil,
          "seam: ...reading the stamp raw, so an absent one reads as absent")
    check(SW:find("P.RefreshOwnerStates = RefreshOwnerStates", 1, true) ~= nil,
          "seam: ...and publishing it for the rest of the toolkit")

    check(CTRL:find("local RefreshOwnerStates = GUI._priv.RefreshOwnerStates", 1, true) ~= nil,
          "seam: Controls.lua aliases that one")
    check(CTRL:find("local function RefreshOwnerStates", 1, true) == nil,
          "seam: ...and keeps no second copy to drift from it")

    -- ☠ AND THE ORDER IS LOAD-BEARING. The alias is taken at FILE SCOPE, so a TOC
    -- that loads Controls.lua first would bind nil and every call site below
    -- would die on the first pick.
    local toc = options_file_source("DandersFrames_Options.toc")
    local swAt = toc:find("GUI\\SettingsWidgets.lua", 1, true)
    local ctAt = toc:find("GUI\\Controls.lua", 1, true)
    check(swAt ~= nil and ctAt ~= nil, "seam: both files are in the companion's TOC")
    check(swAt and ctAt and swAt < ctAt,
          "seam: ...with SettingsWidgets first, or the alias binds nil")

    -- The kit cannot reach the addon's toolkit, so it carries its own -- same
    -- rule, same rawget, no shared table between an addon and an embedded lib.
    check(KIT:find("local function RefreshOwnerStates(parent)", 1, true) ~= nil,
          "seam: the kit declares its own, because it may not read the host's private table")
    check(KIT:find('rawget(parent, "RefreshStates")', 1, true) ~= nil,
          "seam: ...guarded the same way")
end

print("-- Write seam: every hand-rolled widget pokes it when it commits")
for _, name in ipairs({ "CreateTextureDropdown", "CreateFontDropdown", "CreateSoundDropdown",
                        "CreateRoleOrderList", "CreateClassOrderList", "CreateGroupOrderList" }) do
    local body = factoryBody(CTRL, name)
    check(body:find("RefreshOwnerStates(parent)", 1, true) ~= nil,
          name .. ": its commit re-reads the page and the row summary above it")
end

print("-- Write seam: the colour picker pokes it once, on the close")
do
    local body = factoryBody(SW, "CreateColorPicker")

    local n = 0
    for _ in body:gmatch("RefreshOwnerStates%(parent%)") do n = n + 1 end
    -- ☠ EXACTLY ONE, AND NOT IN swatchFunc. That handler runs once per mouse-move
    -- frame of a wheel drag; a page-wide sweep on each would be the storm the
    -- addon's preview/commit split exists to prevent.
    eq(n, 1, "picker: exactly one sweep per picking session")

    local swatchAt  = body:find("swatchFunc = function()", 1, true)
    local watcherAt = body:find('container.colorPickerWatcher:SetScript("OnUpdate"', 1, true)
    local seamAt    = body:find("RefreshOwnerStates(parent)", 1, true)
    check(swatchAt and watcherAt and seamAt and seamAt > watcherAt,
          "picker: ...and it is the close watcher that runs it, never a swatch tick")

    -- ☠ THE WATCHER IS ARMED FOR EVERY PICK NOW. It used to exist only for a
    -- lightweight picker, which is the only kind that had no commit of its own --
    -- but the close is the only moment EITHER kind has a commit to hang this on.
    -- The full update and the callback stay behind the gate they were always
    -- behind; only the state sweep is new, and it is outside it.
    check(body:find("if useLightweight and lightweightCallback then\n            -- We need to run full update", 1, true) == nil,
          "picker: the close watcher is no longer gated on the lightweight path")
    check(body:find("\n        if not container.colorPickerWatcher then", 1, true) ~= nil,
          "picker: ...it is armed at the handler's own indent, for every pick")
end

-- ============================================================
-- 3. THE BORDER TEXTURE SEED -- DRIVEN
-- The reported symptom: switching a Pandemic border from Solid to Texture showed
-- the raw file path where the texture's name belongs. GetBorderList is keyed by
-- LibSharedMedia NAME, so a stored PATH is not a key in it -- the dropdown had no
-- label for it and printed the value, and Fetch could not resolve it either, so
-- the border drew nothing. The seed skipped it because a path is none of the
-- three empty values it looked for.
-- ============================================================
print("-- Border seed: any value the list cannot answer for is replaced")
do
    local a = SW:find("function GUI:SeedBorderTexture(dbTable, prefix)", 1, true)
    check(a ~= nil, "seed: SettingsWidgets declares the seed")
    local b = a and SW:find("\nend\n", a, true)
    check(b ~= nil, "seed: ...and it closes at the file's own indent")

    local LIST
    local GUIstub = {}
    local DFstub  = { GetBorderList = function() return LIST end }
    local env = setmetatable({ GUI = GUIstub, DF = DFstub }, { __index = _G })
    local fn = (a and b) and (loadstring or load)(SW:sub(a, b + 4), "@SeedBorderTexture") or nil
    check(fn ~= nil, "seed: ...and its source compiles on its own")
    if fn then setfenv(fn, env) fn() end
    check(GUIstub.SeedBorderTexture ~= nil, "seed: ...installing itself on GUI")

    if GUIstub.SeedBorderTexture then
        local PATH = "Interface\\AddOns\\DandersFrames\\Media\\DF_Minimalist"

        LIST = { ["DF Glow"] = "DF Glow" }
        local t = { xBorderStyle = "TEXTURE", xBorderTexture = PATH }
        GUIstub:SeedBorderTexture(t, "x")
        eq(t.xBorderTexture, "DF Glow",
           "seed: a stored PATH is no key in a name-keyed list, so it is replaced")

        t = { xBorderStyle = "TEXTURE", xBorderTexture = "SOLID" }
        GUIstub:SeedBorderTexture(t, "x")
        eq(t.xBorderTexture, "DF Glow", "seed: the SOLID sentinel still seeds, as before")

        t = { xBorderStyle = "TEXTURE" }
        GUIstub:SeedBorderTexture(t, "x")
        eq(t.xBorderTexture, "DF Glow", "seed: and so does nothing stored at all")

        LIST = { ["DF Glow"] = "DF Glow", ["DF Bevel"] = "DF Bevel" }
        t = { xBorderStyle = "TEXTURE", xBorderTexture = "DF Bevel" }
        GUIstub:SeedBorderTexture(t, "x")
        eq(t.xBorderTexture, "DF Bevel", "seed: a name the list DOES answer for is left alone")

        -- ☠ AN EMPTY LIST IS TRUTHY. With LibSharedMedia absent GetBorderList
        -- returns {}, and the old guard wrote next({}) -- nil -- straight over
        -- whatever was stored. Nothing to seed FROM is nothing to seed.
        LIST = {}
        t = { xBorderStyle = "TEXTURE", xBorderTexture = "DF Bevel" }
        GUIstub:SeedBorderTexture(t, "x")
        eq(t.xBorderTexture, "DF Bevel", "seed: no border media loaded means nothing is wiped")

        LIST = { ["DF Glow"] = "DF Glow" }
        t = { xBorderStyle = "SOLID", xBorderTexture = PATH }
        GUIstub:SeedBorderTexture(t, "x")
        eq(t.xBorderTexture, PATH, "seed: a Solid border's texture key is never touched")
    end
end

print("-- Border seed: and no shipped default is a raw texture path any more")
do
    local cfg = df_file_source("Core/Config.lua")
    check(cfg:find('buffPandemicBorderTexture = "SOLID",', 1, true) ~= nil,
          "defaults: the pandemic border ships the same sentinel as its eleven siblings")
    local bad = {}
    for key in cfg:gmatch('([%w]*BorderTexture) = "Interface') do bad[#bad + 1] = key end
    eq(#bad, 0, "defaults: ...and no <prefix>BorderTexture default is a raw path")

    -- The art IS registered as border media, under NAMES -- which is why a path
    -- could never be a key even though the file it points at exists.
    check(cfg:find("LSM.MediaType.BORDER, \"DF Glow\"", 1, true) ~= nil,
          "defaults: the shipped border art is registered by name")
end
