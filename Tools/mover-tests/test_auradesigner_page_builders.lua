local NS = ...

-- ============================================================
-- AURA DESIGNER PAGE BUILDERS
-- ------------------------------------------------------------
-- ⚠ 2026-09-26: the popout "rows" page (AuraDesigner/UI/Rows.lua) and the
-- designer shell were deleted; the designer only builds its split panel. The
-- checks that pinned the rows page went with them, and what is left here pins
-- the shared builders the split panel still uses. The history below is kept
-- for context.
--
-- The Aura Designer was a 50/50 split-panel ISLAND: a preview welded to the left
-- half, a three-tab settings column to the right, everything hand-anchored inside
-- one frame the page harness never saw -- which is why it forced the settings
-- window 210px wider than its own default. Phases 1 and 2 of the designer rework
-- put it on the standard harness and turn the Effects tab into a column of bands:
-- one collapsible section per placed effect, and inside it one popout row per
-- settings group.
--
-- ☠ THE ONE FAILURE THIS FILE EXISTS FOR. Every control on this page writes
-- through a metatable PROXY, never through DF.db -- `proxy` resolves an
-- instance value, then the Global tab's defaults, then the shipped ones. A
-- control that moved pane but lost that binding would read the fallback and look
-- completely correct while writing nowhere. So the census below asserts the DB
-- KEY each control binds, and section 5 sweeps every branch for a control bound
-- to anything other than the proxy.
--
-- ☠ AND THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, real settings groups, GUI.SelectedMode, DF.db -- so this file does
-- what test_visibility_page_builders / test_frame_page_builders do: it reads the
-- source and asserts the widget census against it.
--
-- What that buys, and what it does not:
--   ✓ the ROW LIST per effect type, in order, off the same branch the card built.
--   ✓ the widget census of every section built directly in Indicators.lua --
--     kind, L key and db key, in order.
--   ✓ that the four DELEGATING sections still hand the proxy to the shared
--     builder, which is the only binding they own.
--   ✓ that the collect seam re-points and RESTORES `parent`, so a section body
--     cannot leak widgets onto the previous host.
--   ✓ that the row page takes the shared machinery, at the band's width, and
--     wires each row's keys, tick and footer to the PROXY.
--   ✗ nothing about runtime behaviour -- the panels, the greying, the drag
--     targets and the canvas are read by eye and by the in-game checklist.
-- ============================================================

local IND   = options_file_source("AuraDesigner/UI/Indicators.lua")
local POOL  = options_file_source("AuraDesigner/UI/PoolStrip.lua")
local CARDS = options_file_source("AuraDesigner/UI/Cards.lua")
local AURAS = options_file_source("GUI/Pages/Auras.lua")
local EDIT  = options_file_source("AuraDesigner/UI/Editor.lua")
local GROUPS = options_file_source("AuraDesigner/UI/Groups.lua")
-- The Aura Designer UI's base file: _uiState, the shared vocabulary, and the priest gate
-- the helper's pool tab hangs on (see the pool block).
local OPTIONS_UI = options_file_source("AuraDesigner/UI/Options.lua")

-- ---- the census reader ----------------------------------------------
-- The Frame page's, with one addition: a designer control's db table is the
-- PROXY, not `db`, so the key is read off `proxy, "<key>"` -- or off `ec, "<key>"`
-- for the two per-event sound sub-tables, which are proxy sub-tables.
local KIND = {
    CreateCheckbox        = "checkbox",
    CreateSlider          = "slider",
    CreateDropdown        = "dropdown",
    CreateColorPicker     = "colorpicker",
    CreateFontDropdown    = "fontdropdown",
    CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox  = "shadowcheckbox",
    CreateTextureDropdown = "texturedropdown",
    CreateSoundDropdown   = "sounddropdown",
    CreateEditBox         = "editbox",
    CreateButton          = "button",
    CreateNote            = "note",
    CreateLink            = "link",
}

local function census(body)
    local flat = body:gsub("%s+", " ")
    local starts = {}
    local i = 1
    while true do
        local s, e, kind = flat:find("GUI:(Create%a+)%(", i)
        if not s then break end
        if KIND[kind] then starts[#starts + 1] = { s = s, kind = KIND[kind] } end
        i = e
    end
    local out = {}
    for n, at in ipairs(starts) do
        local stop = starts[n + 1] and (starts[n + 1].s - 1) or #flat
        local chunk = flat:sub(at.s, stop)
        local label = chunk:match('GUI:Create%a+%(%s*[%w_%.]+%s*,%s*L%["([^"]+)"%]') or "(none)"
        local key   = chunk:match('%f[%w]proxy,%s*"([%w_]+)"')
                   or chunk:match('%f[%w]ec,%s*"([%w_]+)"') or "(none)"
        out[#out + 1] = { kind = at.kind, label = label, key = key }
    end
    return out
end

local function checkCensus(got, want, tag)
    eq(#got, #want, tag .. ": control count")
    for i = 1, math.max(#got, #want) do
        local g, e = got[i], want[i]
        if not g then
            check(false, string.format("%s: row %d missing (wanted %s)", tag, i, e[2]))
        elseif not e then
            check(false, string.format("%s: row %d unexpected (%s %s %s)", tag, i, g.kind, g.label, g.key))
        else
            eq(g.kind,  e[1], string.format("%s: row %d kind", tag, i))
            eq(g.label, e[2], string.format("%s: row %d label", tag, i))
            eq(g.key,   e[3], string.format("%s: row %d db key", tag, i))
        end
    end
end

-- One `typeKey == "<x>"` branch of BuildTypeContent, by its own two ends.
local function typeBranch(key, nextKey)
    local a = IND:find('if typeKey == "' .. key .. '" then', 1, true)
    check(a ~= nil, "source: BuildTypeContent has a branch for " .. key)
    if not a then return "" end
    local b = nextKey and IND:find('elseif typeKey == "' .. nextKey .. '" then', a, true)
                       or IND:find("-- What the effect settings above deliberately do NOT offer", a, true)
    check(b ~= nil and b > a, "source: ...and it closes before " .. tostring(nextKey))
    return IND:sub(a, b or a)
end

-- ONE AddGroup body, by name, inside a branch. `%b()` so a nested call's parens
-- cannot cut the body in half.
local function groupBody(src, header)
    local a = src:find('AddGroup(L["' .. header .. '"]', 1, true)
    check(a ~= nil, 'source: a section is declared for "' .. header .. '"')
    if not a then return "" end
    local call = src:match("AddGroup%b()", a)
    return call or ""
end

-- The sections a branch declares, in source order.
-- ⚠ THREE SHAPES, not one. Most sections are a bare AddGroup(L["..."], ...);
-- Duration Bar is a shared wrapper called with no arguments (the icon and the
-- square both want the identical strip); and the two per-event sound groups go
-- through AddEventSoundGroup(L["..."], ...), which names its header the same way.
-- A reader that only knew the first shape would silently report the sound card as
-- having one section.
local function sectionOrder(src)
    local out = {}
    local i = 1
    while true do
        local s, e = src:find("Add%a-Group%(L%[\"", i)
        local s2, e2 = src:find("AddDurationBarGroup%(%)", i)
        if s and (not s2 or s < s2) then
            out[#out + 1] = src:match('Add%a-Group%(L%["([^"]+)"%]', s)
            i = e
        elseif s2 then
            out[#out + 1] = "Duration Bar"
            i = e2
        else
            break
        end
    end
    return out
end

local function eqList(got, want, tag)
    eq(#got, #want, tag .. ": section count")
    for i = 1, math.max(#got, #want) do
        eq(got[i] or "(missing)", want[i] or "(unexpected " .. tostring(got[i]) .. ")",
           string.format("%s: section %d", tag, i))
    end
end

-- ============================================================
-- 1. THE PAGE IS ON THE STANDARD HARNESS, AND TAKES THE SHARED MACHINERY
-- The whole point of phase 1: the designer stops being an island. It cannot get
-- a band, a row, a modified tick or a search entry without these.
-- ============================================================
print("-- Aura Designer: the page joins the column system")
do
    -- BuildPage's Add reaches the builder, which is the only way a band can get
    -- into the page's column -- and is also how the builder tells which arm it is.
    check(AURAS:find("DF.BuildAuraDesignerPage(GUI, self, db, Add, AddSpace)", 1, true) ~= nil,
          "harness: the page registration passes Add and AddSpace through")
    check(EDIT:find("function DF.BuildAuraDesignerPage(guiRef, pageRef, dbRef, Add, AddSpace)", 1, true) ~= nil,
          "harness: ...and the entry point takes them")
    -- 2026-09-26: the rows arm is gone; the designer builds its split panel.
    check(EDIT:find("BuildAuraDesignerRowsPage", 1, true) == nil,
          "harness: the designer has no rows arm")
    check(EDIT:find("local function BuildAuraDesignerIsland(guiRef, pageRef, dbRef)", 1, true) ~= nil,
          "harness: ...and the split panel is its build")
end

-- ============================================================
-- 3. BuildTypeContent BUILDS THE CARD, AND ONLY THE CARD
-- Its COLLECT mode -- walk the branches and hand the section bodies back unrun
-- for the rows page to mount one per pane -- went with that page (2026-09-26).
-- ============================================================
print("-- Aura Designer: BuildTypeContent builds the card")
do
    check(IND:find("local function BuildTypeContent(parent, typeKey, auraName, width, optProxy, yOffset, layoutGroup, indicatorID)", 1, true) ~= nil,
          "collect: BuildTypeContent takes no collect table")
    check(IND:find("curGroup", 1, true) == nil,
          "collect: ...and no pane group redirects a loose widget")
    check(IND:find("dfAD_ReflowInPane", 1, true) == nil,
          "collect: ...and nothing tells a pane from a card any more")
    -- The card's own reflow is always stamped.
    check(IND:find("\n    parent.dfAD_ReflowWidgets = function()", 1, true) ~= nil,
          "collect: the card's reflow hook is stamped on every build")

    -- One redraw verb for the fifteen controls that reveal a sibling.
    check(IND:find("local function ADStructuralRedraw(host)", 1, true) ~= nil,
          "collect: the file has one structural redraw verb")
    local direct = 0
    for _ in IND:gmatch("DF:AuraDesigner_RefreshPage%(%)") do direct = direct + 1 end
    eq(direct, 1, "collect: ...and only ADStructuralRedraw calls the page rebuild")
    local routed = 0
    for _ in IND:gmatch("ADStructuralRedraw%(parent%)") do routed = routed + 1 end
    eq(routed, 15, "collect: ...every reveal-a-sibling control goes through it")

    -- Text-only mode drops the Border section at build time.
    check(IND:find("if not proxy.hideIcon then", 1, true) ~= nil,
          "collect: text-only mode drops the Border section")
end

-- ============================================================
-- 4. THE ROWS, PER EFFECT TYPE
-- The order is the card's own reading order and is NOT re-declared by the row
-- page: it is whatever the collect pass returns, so the two layouts cannot
-- disagree about which sections an effect has.
-- ============================================================
print("-- Aura Designer: the row list per effect type")
do
    -- Shared prologue, built before any branch: the copy action, then the
    -- per-placement id narrowing (only where an aura resolves to several ids).
    local PRO = IND:sub(IND:find("-- ── COPY FROM", 1, true),
                        IND:find("-- Shared Duration Bar section", 1, true))
    check(PRO:find('        BuildCopyFrom()', 1, true) ~= nil,
          "rows: Copy Appearance is the card's own first block")
    check(PRO:find('AddGroup(L["Tracked IDs"], function(g)', 1, true) ~= nil,
          "rows: ...and Tracked IDs is the section it always was")

    -- ⚠ POWER INFUSION HELPER LEADS THE ICON BRANCH. The helper's own section is
    -- declared ahead of the generic ones so its Triggers/Effects tabs sit at the top of
    -- the card; everything below it keeps the order it always had.
    eqList(sectionOrder(typeBranch("icon", "square")), {
        "Power Infusion Helper",
        "Show When Missing", "Position", "Appearance", "Border",
        "Duration Text", "Stack Count", "Duration Bar", "Expiration", "Pandemic",
    }, "icon")

    -- Square: the same, minus Desaturate (asserted in the census below) and with
    -- Colour inside Appearance.
    eqList(sectionOrder(typeBranch("square", "bar")), {
        "Show When Missing", "Position", "Appearance", "Border",
        "Duration Text", "Stack Count", "Duration Bar", "Expiration", "Pandemic",
    }, "square")

    -- Bar: no Show When Missing, no Stack Count, no Duration Bar; gains Size &
    -- Orientation between Position and Appearance.
    eqList(sectionOrder(typeBranch("bar", "border")), {
        "Position", "Size & Orientation", "Appearance", "Border",
        "Duration Text", "Expiration", "Pandemic",
    }, "bar")

    eqList(sectionOrder(typeBranch("border", "healthbar")),     { "Appearance" }, "border")
    eqList(sectionOrder(typeBranch("healthbar", "background")), { "Appearance" }, "healthbar")
    eqList(sectionOrder(typeBranch("nametext", "healthtext")),  { "Appearance" }, "nametext")
    eqList(sectionOrder(typeBranch("sound", nil)),
           { "Sound Alert", "Buff Dropped", "Stack Gained" }, "sound")
end

-- ============================================================
-- 5. THE CENSUS -- WHAT EACH ROW HOLDS, AND WHAT IT BINDS
-- The db key, not merely the presence of a control: a control that moved pane
-- but lost its proxy binding reads the fallback and looks correct.
-- ============================================================
print("-- Aura Designer: the icon effect's rows, control by control")
do
    local ICON = typeBranch("icon", "square")

    checkCensus(census(groupBody(ICON, "Show When Missing")), {
        { "checkbox", "Show When Missing",       "showWhenMissing"  },
        { "checkbox", "Desaturate When Missing", "missingDesaturate" },
    }, "icon/Show When Missing")

    checkCensus(census(groupBody(ICON, "Position")), {
        { "dropdown", "Anchor",   "anchor"  },
        { "slider",   "Offset X", "offsetX" },
        { "slider",   "Offset Y", "offsetY" },
    }, "icon/Position")

    checkCensus(census(groupBody(ICON, "Appearance")), {
        { "slider",   "Size",                  "size"       },
        { "slider",   "Scale",                 "scale"      },
        { "slider",   "Alpha",                 "alpha"      },
        { "slider",   "Frame Level",           "frameLevel" },
        { "checkbox", "Hide Cooldown Swipe",   "hideSwipe"  },
        { "checkbox", "Hide Icon (Text Only)", "hideIcon"   },
    }, "icon/Appearance")

    checkCensus(census(groupBody(ICON, "Duration Text")), {
        { "checkbox",        "Show Duration",                    "showDuration"               },
        { "fontdropdown",    "Duration Font",                    "durationFont"               },
        { "slider",          "Duration Scale",                   "durationScale"              },
        { "outlinedropdown", "Outline",                          "durationOutline"            },
        { "shadowcheckbox",  "Shadow",                           "durationOutline"            },
        { "dropdown",        "Duration Anchor",                  "durationAnchor"             },
        { "slider",          "Offset X",                         "durationX"                  },
        { "slider",          "Offset Y",                         "durationY"                  },
        { "checkbox",        "Color by Time Remaining",          "durationColorByTime"        },
        { "colorpicker",     "Duration Text Color",              "durationColor"              },
        { "checkbox",        "Hide Duration Above Threshold",    "durationHideAboveEnabled"   },
        { "slider",          "Hide Above (seconds)",             "durationHideAboveThreshold" },
        { "checkbox",        "Hide Duration on Permanent Auras", "durationHideOnPermanent"    },
    }, "icon/Duration Text")
    -- ⚠ TWO CONTROLS IN THAT PANE ARE NOT IN THE CENSUS, and both are shared
    -- builders whose own widgets live in another file: the format dropdown
    -- (CreateDurationFormatControls) and the Duration Colours cross-link. They are
    -- asserted as delegations rather than counted twice.
    check(groupBody(ICON, "Duration Text"):find('proxy, "durationFormat"', 1, true) ~= nil,
          "icon/Duration Text: the format control binds durationFormat on the proxy")
    check(groupBody(ICON, "Duration Text"):find("AddDurationColorsLink(g, parent)", 1, true) ~= nil,
          "icon/Duration Text: ...and the colours cross-link is the shared one")

    checkCensus(census(groupBody(ICON, "Stack Count")), {
        { "checkbox",        "Show Stacks",       "showStacks"   },
        { "fontdropdown",    "Stack Font",        "stackFont"    },
        { "slider",          "Stack Scale",       "stackScale"   },
        { "outlinedropdown", "Stack Outline",     "stackOutline" },
        { "shadowcheckbox",  "Shadow",            "stackOutline" },
        { "dropdown",        "Stack Anchor",      "stackAnchor"  },
        { "slider",          "Offset X",          "stackX"       },
        { "slider",          "Offset Y",          "stackY"       },
        { "colorpicker",     "Stack Text Color",  "stackColor"   },
    }, "icon/Stack Count")
end

print("-- Aura Designer: the shared Duration Bar row")
do
    local DBAR = IND:sub(IND:find("local function AddDurationBarGroup()", 1, true),
                         IND:find('    if typeKey == "icon" then', 1, true))
    checkCensus(census(DBAR), {
        { "checkbox",        "Enable Duration Bar", "durationBarEnabled"     },
        { "dropdown",        "Position",            "durationBarPosition"    },
        { "slider",          "Height",              "durationBarHeight"      },
        { "slider",          "Gap",                 "durationBarGap"         },
        { "dropdown",        "Color Mode",          "durationBarColorMode"   },
        { "texturedropdown", "Bar Texture",         "durationBarTexture"     },
        { "colorpicker",     "Bar Color",           "durationBarColor"       },
        { "colorpicker",     "Background Color",    "durationBarBGColor"     },
        { "checkbox",        "Reverse Fill",        "durationBarReverseFill" },
    }, "Duration Bar")
end

print("-- Aura Designer: where square and bar differ from icon")
do
    local SQ = typeBranch("square", "bar")
    -- ⚠ ONE CONTROL, NOT TWO. Desaturate is icon-art only, so the square
    -- deliberately has no companion checkbox.
    checkCensus(census(groupBody(SQ, "Show When Missing")), {
        { "checkbox", "Show When Missing", "showWhenMissing" },
    }, "square/Show When Missing")
    -- ...and Colour joins Appearance, which the icon takes from the spell's art.
    checkCensus(census(groupBody(SQ, "Appearance")), {
        { "slider",      "Size",                  "size"       },
        { "slider",      "Scale",                 "scale"      },
        { "colorpicker", "Color",                 "color"      },
        { "slider",      "Alpha",                 "alpha"      },
        { "slider",      "Frame Level",           "frameLevel" },
        { "checkbox",    "Hide Cooldown Swipe",   "hideSwipe"  },
        { "checkbox",    "Hide Icon (Text Only)", "hideIcon"   },
    }, "square/Appearance")

    local BAR = typeBranch("bar", "border")
    checkCensus(census(groupBody(BAR, "Size & Orientation")), {
        { "dropdown", "Orientation",        "orientation"      },
        { "slider",   "Width",              "width"            },
        { "slider",   "Height",             "height"           },
        { "checkbox", "Match Frame Width",  "matchFrameWidth"  },
        { "checkbox", "Match Frame Height", "matchFrameHeight" },
        { "slider",   "Inset",              "matchInset"       },
    }, "bar/Size & Orientation")
    checkCensus(census(groupBody(BAR, "Appearance")), {
        { "dropdown",        "Color Mode",       "barColorMode" },
        { "texturedropdown", "Bar Texture",      "texture"      },
        { "colorpicker",     "Fill Color",       "fillColor"    },
        { "colorpicker",     "Background Color", "bgColor"      },
        { "slider",          "Alpha",            "alpha"        },
        { "slider",          "Frame Level",      "frameLevel"   },
    }, "bar/Appearance")
end

print("-- Aura Designer: the delegating rows still hand over the proxy")
do
    -- Four sections build nothing of their own -- they hand a shared builder the
    -- group and the proxy. That handover IS their binding, so it is what is
    -- asserted; the builders' own censuses belong to their own suites.
    local ICON = typeBranch("icon", "square")
    local BAR  = typeBranch("bar", "border")
    check(groupBody(ICON, "Border"):find('GUI:CreateBorderControls(g, proxy, ""', 1, true) ~= nil,
          "icon/Border: the border toolkit is handed the proxy")
    check(groupBody(BAR,  "Border"):find('GUI:CreateBorderControls(g, proxy, ""', 1, true) ~= nil,
          "bar/Border: the border toolkit is handed the proxy")
    check(groupBody(ICON, "Expiration"):find("AddExpiryAlertControls(g, parent, proxy)", 1, true) ~= nil,
          "icon/Expiration: the expiry controls are handed the proxy")
    check(groupBody(ICON, "Pandemic"):find("AddPandemicControls(g, parent, proxy)", 1, true) ~= nil,
          "icon/Pandemic: the pandemic controls are handed the proxy")
end

print("-- Aura Designer: no control anywhere binds to anything but the proxy")
do
    -- ☠ THE SWEEP. The census above covers the sections it names; this covers the
    -- ones it does not, and every one added later. A designer control's table is
    -- ALWAYS the proxy (or one of its sub-tables) -- reaching for `db` here would
    -- write a per-indicator setting into the mode's own profile.
    local flat = IND:gsub("%s+", " ")
    local bad = 0
    for kind in flat:gmatch("GUI:(Create%a+)%(%s*parent%s*,[^)]-%f[%w]db,%s*\"") do
        if KIND[kind] then bad = bad + 1 end
    end
    eq(bad, 0, "binding: no designer control is bound to the page db")
    -- ...and the proxy is minted once, at the top, from the caller's or the
    -- aura's own record -- never re-derived per section.
    check(IND:find("local proxy = optProxy or CreateProxy(auraName, typeKey)", 1, true) ~= nil,
          "binding: the proxy is minted once for the whole effect")
end

-- ============================================================
-- 6. THE CARD'S SHARED BLOCKS
-- ============================================================
print("-- Aura Designer: the card's shared blocks")
do
    check(CARDS:find("S.BuildEffectTriggersBlock = function(body, effect, bodyWidth, baseH)", 1, true) ~= nil,
          "wiring: the Triggered By block is declared once, in the card file")
    check(CARDS:find("triggersH = S.BuildEffectTriggersBlock(body, effect, bodyWidth, 0)", 1, true) ~= nil,
          "wiring: ...and mounted by the card")
    check(CARDS:find("S.EffectOthersOnlyChanged = function(redraw)", 1, true) ~= nil,
          "wiring: Others Only's write is declared once")
end

-- ============================================================
-- 8. THE HEAD AREAS ARE THE CARD LAYOUT'S OWN
-- Every tab's furniture above the list -- the add block, the chips, the choice
-- cards, the teaching prose -- is declared ONCE and mounted by both layouts. Two
-- copies would be two edits every time the add flow moves, which is phase 5.
-- ============================================================
print("-- Aura Designer: one head area per tab")
do
    check(CARDS:find("S.BuildEffectsHeadArea = function(parent, yPos)", 1, true) ~= nil,
          "head: declared once, in the card file")
    -- The rows page's opt-outs (skipAddBlock / skipChips / filterGlyph) went with it.
    check(CARDS:find("opts.skipAddBlock", 1, true) == nil
          and CARDS:find("opts.skipChips", 1, true) == nil
          and CARDS:find("opts.filterGlyph", 1, true) == nil,
          "head: ...with none of the rows page's opt-outs left")
    -- ☠ CODE LINES ONLY. This counted raw file text, so a comment that merely NAMES
    -- the builder read as another mount -- three such mentions took the count to 5 while
    -- the declaration and the single mount were both exactly where they should be. The
    -- invariant is about call sites, so comment text is stripped before counting.
    local heads = 0
    for line in (CARDS .. "\n"):gmatch("([^\n]*)\n") do
        local code = line:match("^(.-)%-%-") or line
        if code:find("S%.BuildEffectsHeadArea") then heads = heads + 1 end
    end
    eq(heads, 2, "head: ...declared once and mounted once by the card")

    -- Phase 3's two: the Layout Groups and Debuffs choice-card blocks, lifted out
    -- of the tab builders they used to be welded into.
    for _, name in ipairs({ "BuildLayoutGroupsHeadArea", "BuildDebuffGroupsHeadArea" }) do
        check(EDIT:find("S." .. name .. " = function(parent, yPos)", 1, true) ~= nil,
              "head: " .. name .. " is declared once")
        local n = 0
        for _ in EDIT:gmatch("S%." .. name) do n = n + 1 end
        eq(n, 2, "head: ...declared once and mounted once by the card (" .. name .. ")")
    end
end

-- ============================================================
-- 8a. LAYOUT GROUPS GETS ITS ADD PANEL
-- Phase 5 turned the Effects tab's 230px choice-card block into a single
-- "+ Add Indicator" row with the cards inside its panel. Layout Groups was
-- missed and kept the block standing permanently above its list -- on BOTH its
-- arms, which are two different builders (spec section 16).
-- ============================================================
print("-- Aura Designer: Layout Groups gets its own add panel")
do
    -- ── THE TWO PANES ──
    for _, pane in ipairs({ { fn = "S.BuildAddLayoutGroupPane", cards = "LayoutGroupCards" },
                            { fn = "S.BuildAddDebuffGroupPane", cards = "DebuffGroupCards"  } }) do
        local SRC = EDIT:match(pane.fn:gsub("%.", "%%.") .. " = function%(host, opts%)(.-)\nend")
        check(SRC ~= nil, "addgroup: " .. pane.fn .. " can be read")
        SRC = SRC or ""
        -- ONE declaration of the cards, two hosts: the split panel's block and
        -- this panel. A second copy is how Cards.lua ended up with three
        -- duplicated FRAME_ITEMS lists.
        check(SRC:find("local defs = " .. pane.cards .. "()", 1, true) ~= nil,
              "addgroup: ...and builds from the shared card list")
        check(EDIT:find("local function " .. pane.cards .. "()", 1, true) ~= nil,
              "addgroup: ...which is a verb, so its labels cannot freeze on enUS")
        check(EDIT:find("local " .. pane.cards .. " = {", 1, true) == nil,
              "addgroup: ...rather than a table built at load")
        -- ☠ SEGMENTS, NOT CARDS -- the identical treatment the Add Indicator
        -- panel got (spec section 26 item 6). Each is a PICTURE of the row of
        -- icons the group produces, drawn on one of the player's own frames, and
        -- the two sit side by side where two 60px cards used to stack.
        check(SRC:find("CreateFrameTile(host, {", 1, true) ~= nil,
              "addgroup: ...as picture tiles")
        check(SRC:find("Paint = function(pv) PaintIconRowOnThumb(pv, colors, ghost) end,",
                       1, true) ~= nil,
              "addgroup: ...whose picture is that row of icons, on a real frame")
        check(SRC:find('tile:SetPoint("TOPLEFT", (i - 1) * (tileW + GROUP_TILE_GAP), y)',
                       1, true) ~= nil,
              "addgroup: ...laid out side by side, not stacked")
        check(SRC:find("GUI:CreateChoiceCard(host, {", 1, true) == nil,
              "addgroup: ...and no fat card survives in the panel")
        check(SRC:find("CreateChoiceCardGroup", 1, true) == nil,
              "addgroup: ...with no second collapsible header inside the panel")
        -- ...and it REPORTS its height rather than only sizing itself, which is the
        -- half the caller's wantH is waiting for.
        check(SRC:find("if opts.SetHeight then opts.SetHeight(h) end", 1, true) ~= nil,
              "addgroup: ...and reports its height instead of assuming one")
        -- ⚠ CLOSED FIRST, THEN CREATED. Creating a group rebuilds the page, which
        -- retires the row this panel is docked to.
        local closeAt = SRC:find("if opts.Close then opts.Close() end", 1, true)
        local pickAt  = SRC:find("onPick()", 1, true)
        check(closeAt and pickAt and closeAt < pickAt,
              "addgroup: ...and shuts itself before the rebuild that retires its row")
    end

    -- ☠ THE SPLIT PANEL'S CARD BLOCKS ARE GONE (2026-09-22). It mounts these same
    -- two panes ON its tabs now (opts.onPage), and a tile click adds -- see
    -- test_designers_classic.lua for the mount, run.
    check(EDIT:find([[title    = L["ADD A LAYOUT GROUP"],]], 1, true) == nil,
          "addgroup: the split panel no longer draws its Layout Groups card block")
    check(EDIT:find([[title    = L["ADD A DEBUFF GROUP"],]], 1, true) == nil,
          "addgroup: ...nor the Debuffs one")
    local EDITN = EDIT:gsub("\r\n", "\n")
    -- ☠ NO CONFIRM STEP. The first pass drew the chosen kind with an Add button
    -- under it; one click on the tile is the add now.
    check(EDITN:find("BuildChosenGroupPane", 1, true) == nil,
          "addgroup: the chosen-kind pane with its Add button is gone")
    check(EDITN:find("opts.kind", 1, true) == nil,
          "addgroup: ...and nothing asks for it by opts.kind")
    for _, fn in ipairs({ "S.BuildAddLayoutGroupPane", "S.BuildAddDebuffGroupPane" }) do
        local b = EDITN:match(fn:gsub("%.", "%%.") .. " = function%(host, opts%)(.-)\nend\n") or ""
        -- opts.onPage drops the numbered question; the rows page still gets it.
        check(b:find("    if not opts.onPage then\n        CreateNumberedHeading(host, 1, L[\"WHICH KIND OF GROUP?\"], y, W)", 1, true) ~= nil,
              "addgroup: " .. fn .. " asks its question only off the page")
        -- The classic gate is asked on the click, before the pane closes or adds.
        local gAt = b:find("if opts.gate and not opts.gate() then return end", 1, true)
        local cAt = b:find("if opts.Close then opts.Close() end", 1, true)
        check(gAt and cAt and gAt < cAt,
              "addgroup: " .. fn .. " asks the classic gate before anything happens")
        check(b:find('if opts.blocked then tile:SetTileState("disabled") end', 1, true) ~= nil,
              "addgroup: " .. fn .. " greys its tiles when the add is blocked")
    end
end

-- ============================================================
-- 8b. A GROUP CARD RUNS ITS COLLECTOR'S SECTION LIST
-- ============================================================
print("-- Aura Designer: a layout group card runs the collector's list")
do
    -- ⚠ STILL THE COLLECTOR'S LIST, just bound to a local first so section 1 can be
    -- substituted for the helper's group before the cursor runs down it.
    check(EDIT:find("local sections = CollectLayoutGroupSections(group)", 1, true) ~= nil
          and EDIT:find("by = RunCardSections(body, bodyWidth, by, sections, refreshTab)", 1, true) ~= nil,
          "group: the card runs the collector's list")
    check(EDIT:find("by = RunCardSections(body, bodyWidth, by, CollectDebuffGroupSections(group))", 1, true) ~= nil,
          "group: ...on the Debuffs tab too")
end

-- ============================================================
-- 8c. THE SECTION LIST, PER GROUP KIND
-- Which blocks a group has is decided in ONE place for both layouts.
-- ============================================================
print("-- Aura Designer: the section list per group kind")
do
    -- The collectors' bodies, by their own two ends.
    local function collector(name, tail)
        local a = EDIT:find("local function " .. name .. "(", 1, true)
        check(a ~= nil, "sections: " .. name .. " exists")
        if not a then return "" end
        local b = EDIT:find(tail, a, true)
        check(b ~= nil and b > a, "sections: ...and it closes")
        return EDIT:sub(a, b or a)
    end
    local LG = collector("CollectLayoutGroupSections", "P.CollectLayoutGroupSections =")
    local DG = collector("CollectDebuffGroupSections", "P.CollectDebuffGroupSections =")

    local function headers(src)
        local out = {}
        for h in src:gmatch('header = L%["([^"]+)"%]') do out[#out + 1] = h end
        return out
    end
    -- A spell group lists Members; a filter group lists Filters instead. Both then
    -- take the shared layout pair.
    eqList(headers(LG), { "Filters", "Members", "Placement", "Growth" },
           "sections: a layout group")
    eqList(headers(DG), { "Categories", "Placement", "Growth" },
           "sections: a debuff group")
    -- The branch that chooses between the first two.
    check(LG:find("if isFilterGroup then", 1, true) ~= nil,
          "sections: ...and the first is chosen by the group's kind")

    -- The card's small-caps caption over each block, so the two layouts name the
    -- same thing.
    local function captions(src)
        local out = {}
        for c in src:gmatch('caption = L%["([^"]+)"%]') do out[#out + 1] = c end
        return out
    end
    eqList(captions(LG), { "LINKED FILTERS", "MEMBERS", "PLACEMENT", "GROWTH" },
           "sections: the card's captions, layout group")
    eqList(captions(DG), { "CATEGORIES", "PLACEMENT", "GROWTH" },
           "sections: ...and debuff group")
end

-- ============================================================
-- 8d. WHAT EACH SECTION BINDS
-- ☠ THE FAILURE THIS WHOLE FILE EXISTS FOR, on the phase-3 half. A layout
-- group's controls bind the GROUP RECORD; a debuff group's category controls
-- bind its SELECTION block. A control that changed layout and lost that binding
-- would read the record and write nowhere, looking completely correct.
-- ============================================================
print("-- Aura Designer: the layout-group controls and their db keys")
do
    -- The census reader, for a body whose db table is named rather than `proxy`.
    -- Three shapes, and the third is not decoration: the sort dropdown binds
    -- through a custom get/set, so its key appears only as an assignment.
    local function bodyCensus(src, tbl)
        local flat = src:gsub("%s+", " ")
        local starts = {}
        local i = 1
        while true do
            local s, e, kind = flat:find("GUI:(Create%a+)%(", i)
            if not s then break end
            if KIND[kind] or kind == "CreateGrowthControl" then
                starts[#starts + 1] = { s = s, kind = KIND[kind] or "growth" }
            end
            i = e
        end
        local out = {}
        for n, at in ipairs(starts) do
            local stop = starts[n + 1] and (starts[n + 1].s - 1) or #flat
            local chunk = flat:sub(at.s, stop)
            local label = chunk:match('GUI:Create%a+%(%s*[%w_%.]+%s*,%s*L%["([^"]+)"%]') or "(none)"
            local key = chunk:match('%f[%w]' .. tbl .. ',%s*"([%w_]+)"')
                     or chunk:match('%f[%w]' .. tbl .. ',%s*([%w_]+%.[%w_]+)%s*,')
                     or chunk:match('%f[%w]' .. tbl .. '%.([%w_]+)%s*=')
                     or "(none)"
            out[#out + 1] = { kind = at.kind, label = label, key = key }
        end
        return out
    end

    local function fnBody(src, name, tail)
        local a = src:find("local function " .. name .. "(", 1, true)
        check(a ~= nil, "binding: " .. name .. " exists")
        if not a then return "" end
        local b = src:find(tail, a, true)
        check(b ~= nil and b > a, "binding: ...and " .. name .. " closes")
        return src:sub(a, b or a)
    end

    checkCensus(bodyCensus(fnBody(EDIT, "BuildGroupPlacement", "-- ── GROWTH"), "group"), {
        { "dropdown", "Anchor",   "anchor"  },
        { "slider",   "Offset X", "offsetX" },
        { "slider",   "Offset Y", "offsetY" },
    }, "layout/Placement")

    checkCensus(bodyCensus(fnBody(EDIT, "BuildGroupGrowth", "-- The ordered section list for one layout group"), "group"), {
        { "growth",   "(none)",        "growDirection" },
        { "slider",   "Icons Per Row", "iconsPerRow"   },
        { "slider",   "Spacing",       "spacing"       },
        { "slider",   "Icon Size",     "iconSize"      },
        { "slider",   "Max Icons",     "maxIcons"      },
        { "dropdown", "Sort Order",    "sortOrder"     },
        { "checkbox", "My Auras First","sortMineFirst" },
        { "checkbox", "Reverse Order", "sortReverse"   },
        { "checkbox", "Others Only",   "othersOnly"    },
    }, "layout/Growth")

    -- ⚠ THE SIX CATEGORY CHECKBOXES ARE ONE LOOP, so the census sees one entry
    -- bound to `sel, def.key`. Which six they are is asserted off the defs table
    -- below, which is the only place that decides.
    checkCensus(bodyCensus(fnBody(EDIT, "BuildDebuffCategories", "-- The ordered section list for one debuff"), "sel"), {
        { "checkbox", "(none)",                      "def.key"         },
        { "dropdown", "Mode",                        "dispellableMode" },
        { "checkbox", "Hide Long Debuffs",           "hideLong"        },
        { "slider",   "Hide Longer Than (minutes)",  "hideLongMinutes" },
        { "checkbox", "Keep important debuffs",      "keepImportant"   },
    }, "debuff/Categories")

    local defs = fnBody(EDIT, "DebuffCategoryDefs", "P.DebuffCategoryDefs =")
    local catKeys = {}
    for k in defs:gmatch('key = "([%w_]+)"') do catKeys[#catKeys + 1] = k end
    eqList(catKeys, { "boss", "role", "priority", "crowdControl", "raid", "dispellable" },
           "debuff/Categories: the six category keys")

    -- ☠ THE SWEEP. Nothing in the shared section bodies reaches for the page db.
    local shared = EDIT:sub(EDIT:find("-- ── LINKED FILTERS (filter groups) ──", 1, true),
                            EDIT:find("S.BuildLayoutGroupsHeadArea = function", 1, true))
    local flat = shared:gsub("%s+", " ")
    local bad = 0
    for kind in flat:gmatch("GUI:(Create%a+)%(%s*host%s*,[^)]-%f[%w]db,%s*\"") do
        if KIND[kind] then bad = bad + 1 end
    end
    eq(bad, 0, "binding: no layout-group control is bound to the page db")

    -- The greying that used to be imperative-only has to survive a pane's own
    -- re-flow, which re-runs disableOn and knows nothing about a SetEnabled call
    -- made once at build.
    local dis = 0
    for _ in EDIT:gmatch("%.disableOn = function%(%) return not sel%.") do dis = dis + 1 end
    eq(dis, 3, "binding: the three gated debuff controls carry a disableOn, not just a build-time grey")

    -- sortOrder is OPTIONAL on a group record, so the dropdown reads it through a
    -- customGet with a family fallback. The families genuinely differ: a filter
    -- group's behaviour was Blizzard slot order, a debuff group's soonest-to-expire.
    check(EDIT:find('local famSort = (kind == "debuff") and "TIME" or "DEFAULT"', 1, true) ~= nil,
          "binding: the sort dropdown's family fallback names both families")
end

-- ============================================================
-- 8e. THE GLOBAL TAB'S ROWS
-- Seven blocks, four of which hold settings. The three that hold ACTIONS take no
-- modified tick and no Reset Group -- a footer that reset nothing would be a
-- footer that lied, which is the failure this phase was blocked on.
-- ============================================================
print("-- Aura Designer: the Global tab's rows")
do
    local GV = CARDS:sub(CARDS:find("local function BuildGlobalView(parent)", 1, true),
                         CARDS:find("P.BuildGlobalView = BuildGlobalView", 1, true))
    check(#GV > 100, "global: BuildGlobalView's body was found")

    -- The collect seam and the rows page's per-block record/extra-keys went
    -- with that page (2026-09-26).
    check(GV:find("collect", 1, true) == nil,
          "global: BuildGlobalView carries no collect seam")

    -- The blocks, in order.
    local order = {}
    for header in GV:gmatch('AddGroup%(L%["([^"]+)"%]') do order[#order + 1] = header end
    eqList(order, { "General", "Sound Alerts", "Duration Text", "Stack Text",
                    "Import from Buffs Tab", "Standard Buffs", "Actions" },
           "global: the blocks, in the order the split panel draws them")

    -- The census of each settings block. The Global tab's table is the defaults
    -- PROXY (`defaults`), and the two sound controls bind through a custom get/set
    -- onto the Aura Designer block itself -- which the third pattern reads.
    local function globalCensus(src)
        local flat = src:gsub("%s+", " ")
        local starts = {}
        local i = 1
        while true do
            local s, e, kind = flat:find("GUI:(Create%a+)%(", i)
            if not s then break end
            if KIND[kind] then starts[#starts + 1] = { s = s, kind = KIND[kind] } end
            i = e
        end
        local out = {}
        for n, at in ipairs(starts) do
            local stop = starts[n + 1] and (starts[n + 1].s - 1) or #flat
            local chunk = flat:sub(at.s, stop)
            local label = chunk:match('GUI:Create%a+%(%s*[%w_%.]+%s*,%s*L%["([^"]+)"%]') or "(none)"
            local key = chunk:match('%f[%w]defaults,%s*"([%w_]+)"')
                     or chunk:match('%f[%w]adDB%.([%w_]+)%s*=')
                     or chunk:match('GetAuraDesignerDB%(%)%.([%w_]+)%s*=')
                     or "(none)"
            out[#out + 1] = { kind = at.kind, label = label, key = key }
        end
        return out
    end
    local function globalBody(header)
        local a = GV:find('AddGroup(L["' .. header .. '"]', 1, true)
        check(a ~= nil, 'global: a block is declared for "' .. header .. '"')
        if not a then return "" end
        return GV:match("AddGroup%b()", a) or ""
    end

    checkCensus(globalCensus(globalBody("General")), {
        { "slider",   "Default Icon Size",     "iconSize"            },
        { "slider",   "Default Scale",         "iconScale"           },
        { "slider",   "Default Frame Level",   "indicatorFrameLevel" },
        { "checkbox", "Show Duration",         "showDuration"        },
        { "checkbox", "Show Stacks",           "showStacks"          },
        { "checkbox", "Hide Cooldown Swipe",   "hideSwipe"           },
        { "checkbox", "Hide Icon (Text Only)", "hideIcon"            },
    }, "global/General")

    checkCensus(globalCensus(globalBody("Sound Alerts")), {
        { "checkbox", "Enabled", "soundEnabled" },
        { "dropdown", "Channel", "soundChannel" },
    }, "global/Sound Alerts")

    checkCensus(globalCensus(globalBody("Duration Text")), {
        { "fontdropdown",    "Font",                           "durationFont"               },
        { "slider",          "Scale",                          "durationScale"              },
        { "outlinedropdown", "Outline",                        "durationOutline"            },
        { "shadowcheckbox",  "Shadow",                         "durationOutline"            },
        { "dropdown",        "Anchor",                         "durationAnchor"             },
        { "slider",          "Offset X",                       "durationX"                  },
        { "slider",          "Offset Y",                       "durationY"                  },
        { "checkbox",        "Color by Time Remaining",        "durationColorByTime"        },
        { "colorpicker",     "Duration Text Color",            "durationColor"              },
        { "checkbox",        "Hide Duration Above Threshold",  "durationHideAboveEnabled"   },
        { "slider",          "Hide Above (seconds)",           "durationHideAboveThreshold" },
    }, "global/Duration Text")
    -- ⚠ THE COLOURS LINK IS NOT A GUI:Create CALL, so the census cannot see it.
    -- It is the one cross-page link on this block and it goes to the Colours page,
    -- not to a sibling widget -- so unlike the bar's Expiration note it survives
    -- the move to a pane untouched.
    check(globalBody("Duration Text"):find("AddDurationColorsLink(g, parent)", 1, true) ~= nil,
          "global/Duration Text: ...and the Color by Time link rides with it")

    checkCensus(globalCensus(globalBody("Stack Text")), {
        { "fontdropdown",    "Font",             "stackFont"    },
        { "slider",          "Scale",            "stackScale"   },
        { "outlinedropdown", "Outline",          "stackOutline" },
        { "shadowcheckbox",  "Shadow",           "stackOutline" },
        { "dropdown",        "Anchor",           "stackAnchor"  },
        { "slider",          "Offset X",         "stackX"       },
        { "slider",          "Offset Y",         "stackY"       },
        { "colorpicker",     "Stack Text Color", "stackColor"   },
    }, "global/Stack Text")
end

-- ============================================================
-- 8f. THE GLOBAL TAB'S AND A GROUP'S STYLE PROXIES CARRY THE DEFAULTS ADAPTER
-- The defaults engine only answers "is this modified" for a designer record that
-- carries an adapter, so these two proxies' controls would otherwise have a
-- permanently dark modified tick -- silently, with no error either way.
-- ============================================================
print("-- Aura Designer: the Global and group-style proxies carry the defaults adapter")
do
    check(CARDS:find("local function CreateGlobalDefaultsProxy()", 1, true) ~= nil,
          "record: CreateGlobalDefaultsProxy exists")
    check(CARDS:find("P.CreateGlobalDefaultsProxy = CreateGlobalDefaultsProxy", 1, true) ~= nil,
          "record: ...and is published")

    -- ☠ GetStored IS A rawget. Through these proxies __index answers with the
    -- fallback for an unset key, so an adapter reading back through its own proxy
    -- would find every key set and light the whole tab up.
    local rawgets = 0
    for _ in CARDS:gmatch("GetStored%s*=%s*function") do rawgets = rawgets + 1 end
    eq(rawgets, 2, "record: the card file mints two adapters")
    check(CARDS:find("return rawget(t, k)", 1, true) ~= nil,
          "record: the Global tab's GetStored reads the stored block RAW")
    check(CARDS:find("GetStored  = function(k) return rawget(s, k) end", 1, true) ~= nil,
          "record: ...and the group style's, which is the one with copy-on-read")

    -- The General block binds a slider to indicatorFrameLevel, so the fallback
    -- table has to name its default or the tick cannot answer for it.
    check(CARDS:find("indicatorFrameLevel = 40,", 1, true) ~= nil,
          "record: the Global tab's frame-level default is named -- and it is 40, the render's no-op")
end

-- ============================================================
-- 9. THE CANVAS
-- Lifted as-is: the same anatomy, the same nine anchor dots, the same
-- RefreshGeometry. Only its own standing furniture changes, and only in the band.
-- ============================================================
print("-- Aura Designer: the canvas")
do
    check(CARDS:find("local function CreateFramePreview(parent, yOffset, rightPanelRef, opts)", 1, true) ~= nil,
          "canvas: ...through one added option, so the split panel is untouched")
    check(CARDS:find("local compact = opts and opts.compact or false", 1, true) ~= nil,
          "canvas: ...which defaults to the split panel's own behaviour")
    -- ⚠ 132px DOES NOT FIT THE CANVAS'S OWN FURNITURE. Label strip 28 + scale
    -- slider 30 + three instruction rows 59 leaves 15px for a 64px-tall frame, so
    -- the mock would be drawn straight over the instructions. They become the
    -- canvas's tooltip.
    check(CARDS:find("instrRows = {}", 1, true) ~= nil,
          "canvas: the instruction rows move to the tooltip")

    -- ☠ THE BAND GROWS TO THE FRAME; IT DOES NOT SHRINK THE FRAME TO THE BAND.
    -- Clamping the mock's scale down to fit a fixed 132px band made the slider
    -- LIE -- it read 1.6 while the mock stayed at whatever fitted. So the compact
    -- fit clamps on WIDTH ONLY (horizontal space is the page's and cannot be
    -- negotiated) and the host regrows instead.
    check(CARDS:find("local fit = compact and ((cw - 16) / w)", 1, true) ~= nil,
          "canvas: the compact fit clamps on width only")
    check(CARDS:find("or math.min((cw - 16) / w, (ch - 28) / h)", 1, true) ~= nil,
          "canvas: ...while the split panel, whose half is fixed, still clamps both")
    -- The second parameter arrived with the Text Designer (phase 4): the canvas
    -- and the height verb must read the SAME preview-scale table, and the two
    -- designers keep that key in different places.
    check(CARDS:find("function P.CanvasWantedHeight(compact, scaleDB)", 1, true) ~= nil,
          "canvas: the wanted height is a verb the host can call BEFORE the canvas exists")

    -- ☠ AND WHAT STILL DOES NOT FIT IS MASKED, NEVER DRAWN OVER THE PAGE. A
    -- placed indicator anchored outside the frame (a TOP icon) overhangs at every
    -- scale, and below this band sit the pool strip and the tabs.
    check(CARDS:find("container:SetClipsChildren(true)", 1, true) ~= nil,
          "canvas: the canvas masks its own contents")

    -- ☠ THE MOCK'S CENTRE OFFSET IS IN THE MOCK'S OWN UNITS, SO IT SCALES.
    -- At 2.5 the intended 20px nudge became 50 on screen, dropping the frame 30px
    -- further than the band height allowed for and cutting it off along the bottom
    -- ("at max scale it doesnt quite fit the whole frame"). Dividing by the scale
    -- is what makes the height arithmetic below true.
    check(CARDS:find("mockFrame:SetPoint(\"CENTER\", container, \"CENTER\", 0, -CANVAS_DY / scale)", 1, true) ~= nil,
          "canvas: the centre nudge is compensated for scale, so it stays screen pixels")

    -- ☠ BOTH EXITS OF RefreshGeometry SET BOTH THE SCALE AND THE ANCHOR. The
    -- early exit -- taken whenever the container has no size yet, which is what a
    -- RELOAD does -- used to set the scale and leave the anchor at its
    -- construction value, so the preview came back 20*(scale-1) pixels too low and
    -- stayed there until the slider was touched. Reported in-game as "on reload
    -- the preview frame isnt in the correct spot".
    check(CARDS:find("local function place(scale)", 1, true) ~= nil,
          "canvas: the scale and the anchor are set together, by one verb")
    check(CARDS:find("            place(want)", 1, true) ~= nil,
          "canvas: ...so the early exit anchors too, not just scales")
    check(CARDS:find("place(math.max(0.2, math.min(want, fit)))", 1, true) ~= nil,
          "canvas: ...and so does the measured path")
    -- The bare call is what the early exit used to make. `place` is now the only
    -- way the scale is set, so the bare form must not appear at all.
    check(CARDS:find("mockFrame:SetScale(want)", 1, true) == nil,
          "canvas: nothing sets the scale WITHOUT the anchor any more")
    -- The only hook that fires BECAUSE the size arrived, rather than on an event
    -- that can precede it.
    check(CARDS:find("container:SetScript(\"OnSizeChanged\", function() container.RefreshGeometry() end)", 1, true) ~= nil,
          "canvas: the geometry re-runs when the band is finally sized")
    check(CARDS:find("local CANVAS_FURNITURE, CANVAS_PAD, CANVAS_DY", 1, true) ~= nil,
          "canvas: the geometry is named ONCE -- the height verb and the canvas are one sum")

    -- The arithmetic itself, over the slider's whole range and every frame height
    -- the addon allows. The constants are READ OUT OF THE SOURCE rather than
    -- restated here, so this fails if one of them is changed to a bad value --
    -- restating them would only test that this file agrees with itself.
    do
        local F, P_, DY = CARDS:match("local CANVAS_FURNITURE, CANVAS_PAD, CANVAS_DY = (%d+), (%d+), (%d+)")
        check(F ~= nil, "canvas: the geometry constants can be read from the source")
        F, P_, DY = tonumber(F), tonumber(P_), tonumber(DY)

        local worstTop, worstBottom = math.huge, math.huge
        for _, fh in ipairs({ 40, 64, 80, 100, 120, 160 }) do
            local scale = 0.75
            while scale <= 2.5001 do
                local h = math.max(132, math.ceil(math.max(
                    2 * F  - 2 * DY + fh * scale,
                    2 * P_ + 2 * DY + fh * scale)))
                -- Where the mock's edges land, given a nudge that no longer scales.
                local top    = h / 2 + DY - (fh * scale) / 2
                local bottom = h / 2 - DY - (fh * scale) / 2
                worstTop    = math.min(worstTop, top - F)
                worstBottom = math.min(worstBottom, bottom - P_)
                scale = scale + 0.05
            end
        end
        check(worstTop >= -0.001,
              "canvas: the frame clears the label and slider at every scale and frame height")
        check(worstBottom >= -0.001,
              "canvas: ...and is never cut off along the bottom, which is the reported bug")
    end

end

-- ============================================================
-- 11. THE POOL STRIP
-- My Buffs / Debuffs / Any Buff (and PI Helper on a priest) as tabs on the
-- split panel's strip, each explaining itself on hover.
-- ============================================================
print("-- Aura Designer: the pool strip")
do
    check(POOL:find("S.BuildPoolStrip = function(buffTabBar)", 1, true) ~= nil,
          "pool: the split panel's pool strip is declared once")
    -- (poolHost: the strip's left part -- the spec picker holds its right end,
    -- see test_designers_classic.lua.)
    check(EDIT:find("S.BuildPoolStrip(poolHost)", 1, true) ~= nil,
          "pool: ...and the split panel mounts it into its own slice")
    -- ⚠ ONE DESCRIPTION OF THE POOLS, and it is a FUNCTION: a file-scope
    -- table of L[...] lookups freezes on whatever locale was live at load.
    check(POOL:find("local function PoolDefs()", 1, true) ~= nil,
          "pool: the pools are described once")
    check(POOL:find("local MAIN_TAB_DEFS = PoolDefs()", 1, true) ~= nil,
          "pool: ...which the split panel's strip reads")
    -- ☠☠ THE PRIEST GATE MUST BE DEFINED SOMEWHERE, and this test exists because it once
    -- was not. Every caller reads `DF.IsPIHelperAvailable and DF.IsPIHelperAvailable()` --
    -- a nil-guard that is correct across the load-on-demand split and, precisely because it
    -- is correct, makes a MISSING definition indistinguishable from "not a priest". The
    -- definition lived in a page file that was deleted when the helper's nav row went; no
    -- error, no failing test, the gate simply answered false forever and the pool tab
    -- vanished for everyone (2026-09-17: "no tab in AD, no tab anywhere").
    -- ⚠ Asserted across the whole AD UI rather than in one named file, so the definition can
    -- be moved without this becoming a test about where it lives.
    do
        local defined = false
        for _, src in ipairs({ OPTIONS_UI, POOL, CARDS, EDIT, GROUPS, IND, AURAS }) do
            if src:find("function DF.IsPIHelperAvailable()", 1, true) then defined = true end
        end
        check(defined, "pool: the priest gate the helper tab hangs on is defined somewhere")
    end
    local setMain = CARDS:match("local function SetMainTab%(tabKey%)(.-)\nend\nP%.SetMainTab")
    check(setMain ~= nil, "pool: SetMainTab's body can be read")
    -- ⚠ EXTRACTED, NOT DROPPED. The per-button paint moved into SyncPoolTabs so the
    -- split panel can repaint the same strip without going through a pool switch.
    check((setMain or ""):find("SyncPoolTabs()", 1, true) ~= nil,
          "pool: SetMainTab paints the map the strip fills")
    check((setMain or ""):find("UpdateSpecDropdownState()", 1, true) ~= nil,
          "pool: a pool change greys Spec on the spot")
    check(POOL:find("UpdateSpecDropdownState()", 1, true) ~= nil,
          "pool: ...and the rebuild it triggers greys the NEW dropdown too")
end

-- ============================================================
-- 11b. THE ACTIVE INDICATORS FILTER CHIPS
-- ------------------------------------------------------------
-- A wrapping row of eight chips under the ACTIVE INDICATORS caption. (The rows
-- page reached the same chips through a glyph and a pooled popout; both went
-- with it on 2026-09-26.)
-- ============================================================
print("-- Aura Designer: the filter chips")
do
    check(CARDS:find("S.BuildFilterChips = function(host, width)", 1, true) ~= nil,
          "showing: the chips are declared once")
    check(CARDS:find("local function FilterChips()", 1, true) ~= nil,
          "showing: ...from one list of the eight filters")
    -- ⚠ A FUNCTION, not a file-scope table: a table of L[...] lookups built at
    -- load freezes on whatever locale was live then.
    check(CARDS:find("local FILTER_CHIPS = {", 1, true) == nil,
          "showing: ...which is a verb, so it cannot freeze on the load-time locale")
    -- The glyph, its pooled panel and its label helper are gone.
    check(CARDS:find("OpenFilterPopout", 1, true) == nil
          and CARDS:find("ActiveFilterLabel", 1, true) == nil
          and CARDS:find("FILTER_ICON", 1, true) == nil,
          "showing: the rows page's glyph and panel went with it")

    -- No schema change: the chips write the same in-memory field they always did.
    local chips = CARDS:match("S%.BuildFilterChips = function%(host, width%)(.-)\nend\n")
    check(chips ~= nil, "showing: the chip builder's body can be read")
    chips = chips or ""
    check(chips:find("S.activeFilter = capturedKey", 1, true) ~= nil,
          "showing: a chip writes S.activeFilter -- no new key, no db write")
    check(chips:find([[S.SwitchTab("effects")]], 1, true) ~= nil,
          "showing: ...and redraws the page, because WHICH effects are listed changed")
    check(chips:find("width or 260", 1, true) ~= nil,
          "showing: the flow falls back only when it was told nothing at all")
    check(chips:find("return LayoutChips", 1, true) ~= nil,
          "showing: ...and hands back its re-flow verb")
end
-- ============================================================
-- 12. THE FULL-WIDTH PAGES OPEN WIDE
-- The designers fit 640 but are drawn full width, and at 640 they read as a
-- sliver of a tool; every full-width page shares the 850 floor.
-- ============================================================
print("-- Aura Designer: the full-width pages open wide")
do
    local PANEL = options_file_source("GUI/Panel.lua")
    -- ⚠ THE TABLE'S BODY, NOT THE FILE. Both page ids also appear in the
    -- slash-command alias map (Panel.lua:977, :998), so a file-wide find answers
    -- "is this string anywhere" and never "is this page still a wide page".
    local WIDE = PANEL:match("local WIDE_PAGES = {(.-)}")
    check(WIDE ~= nil, "wide: the WIDE_PAGES table can be found")
    check(WIDE:find("auras_auradesigner", 1, true) ~= nil,
          "wide: the Aura Designer widens the window to 850")
    check(WIDE:find("text_designer", 1, true) ~= nil,
          "wide: ...as does the Text Designer")
    check(WIDE:find("auras_filterdesigner", 1, true) ~= nil,
          "wide: ...and the Filter Designer")
    check(WIDE:find("general_pinnedframes", 1, true) ~= nil,
          "wide: ...as does Pinned Frames")
    check(WIDE:find("general_nicknames", 1, true) ~= nil,
          "wide: ...and Nicknames")
end

-- ============================================================
-- 13. THE NARROW WINDOW -- WHAT 850px WAS HIDING
-- ------------------------------------------------------------
-- Without section 12's floor this page renders in the 640px default window: a
-- band of roughly 410px, and as little as
-- ~280 at the window's own minimum. Everything on this page was written when 850
-- was guaranteed, and two whole classes of layout bug were invisible at that
-- width.
--
-- CLASS ONE -- A HEIGHT MEASURED BEFORE LAYOUT, THEN SPENT. A wrapping or
-- flowing element only knows how tall it is once something has given it a real
-- width, which is after the builder has run; the builder measured it anyway and
-- everything below was anchored at that number. The re-flow that followed moved
-- nothing. The repair has two halves and both are asserted here: flow against a
-- width DERIVED from the host (so the first pass is the final one), and re-report
-- the height when it changes anyway (so a window resize is not a stale page).
--
-- CLASS TWO -- A ROW OF FIXED-WIDTH CHILDREN THAT ONLY EVER FITTED 850. Written
-- as a left-to-right chain of literals, they simply ran off the end of a band.
-- The repair is anchoring, not smaller literals: a row whose elastic member
-- absorbs the slack is right at every width.
--
-- CLASS THREE -- TWO THINGS GROWING TOWARD EACH OTHER FROM OPPOSITE EDGES. A
-- section header's title runs rightward from the arrow with no edge of its own,
-- while the eye, the delete, the warning badge and the preview swatch run
-- leftward from the other end. There was 850px of slack between them.
--
-- (S) Asserted against the SOURCE, like the rest of this file: neither designer
-- can be built headlessly. What that buys is that the SHAPE is derived rather
-- than hardcoded; that the pixels land is still an in-game check.
-- ============================================================
print("-- Aura Designer: the narrow window")
do
    local SW = options_file_source("GUI/SettingsWidgets.lua")

    -- ---- class one: the effects head area, and the chips leaving it -----
    -- ☠ THE CLASS-1 HAZARD IS RETIRED HERE, NOT RELOCATED. The chip row was the
    -- flow element whose height was measured before the layout pass and then
    -- spent to position everything below. In a popout pane the width is the
    -- popout's own content width and there is nothing below it on the page to
    -- displace, so the compensation is DELETED rather than carried across.
    local HEAD = CARDS:match("S%.BuildEffectsHeadArea = function.-\n    return yPos, false\nend")
    check(HEAD ~= nil, "narrow: the effects head area can be read")
    HEAD = HEAD or ""
    -- The column is the HOST's explicit width less its two insets, not a child's
    -- unresolved one. Still true for the split panel, which still flows chips.
    check(HEAD:find("local hostW = parent:GetWidth()", 1, true) ~= nil,
          "narrow: the head area derives its column from the host it was sized to")
    check(HEAD:find("local COL_W = (hostW > 40) and (hostW - 16) or nil", 1, true) ~= nil,
          "narrow: ...as the host's width less the 8px inset on each side")
    check(HEAD:find("S.BuildFilterChips(chipsFrame, COL_W)", 1, true) ~= nil,
          "narrow: ...and hands that column to the chips rather than letting them guess")
    check(CARDS:find("if maxW < 20 then maxW = width or 260 end", 1, true) ~= nil,
          "narrow: the chips wrap to the width they are TOLD, not to one they measure")

    -- (X) THE ABSENCE IS THE ASSERTION, twice over.
    check(HEAD:find("dfSetHeight", 1, true) == nil,
          "narrow: the head area no longer re-reports a band height it cannot change")
    check(CARDS:find("parent.dfSetHeight", 1, true) == nil,
          "narrow: ...and the dead re-report is gone from the file, not left to rot")

    -- The split panel still re-flows on resize; what it no longer does is try to
    -- move bands it does not have.
    local reflow = HEAD:match('chipsFrame:SetScript%("OnSizeChanged", function%(_, w%)(.-)end%)')
    check(reflow ~= nil, "narrow: the chip row still re-flows on resize")
    check((reflow or ""):find("Relayout(w)", 1, true) ~= nil,
          "narrow: ...at the width the resize reports")
    check(HEAD:find([[obHint:SetPoint("TOPLEFT", chipsFrame, "BOTTOMLEFT"]], 1, true) ~= nil,
          "narrow: what follows the chips is anchored TO them, so a re-wrap carries it")

    -- ---- the choice cards are gone ---------------------------------------
    -- The split panel's add blocks are one button each, opening the Modern panes in
    -- a popout; the choice-card factory itself was deleted with its last caller.
    check(HEAD:find("CreateChoiceCard", 1, true) == nil,
          "narrow: the Effects head area builds no choice cards any more")
    check(EDIT:find("GUI:CreateChoiceCardGroup(parent", 1, true) == nil,
          "narrow: ...and neither do the two Layout Groups head areas")

    -- ---- class two: the preset bar --------------------------------------
    -- Caption + a fixed 150px dropdown + four action buttons, chained left to
    -- right. 317px in the icon form and 467 in the labelled one, against a band
    -- that is ~410 at the default window and ~280 at its minimum.
    check(SW:find("ddBtn:SetSize(150, 22)", 1, true) == nil,
          "narrow: the template dropdown is no longer a fixed 150px")
    check(SW:find('delBtn:SetPoint("RIGHT", bar, "RIGHT", 0, 0)', 1, true) ~= nil,
          "narrow: the preset bar's actions chain from the bar's own right edge")
    check(SW:find('ddBtn:SetPoint("RIGHT", newBtn, "LEFT", -6, 0)', 1, true) ~= nil,
          "narrow: ...and the dropdown spans what is left between caption and actions")
    check(SW:find('menu:SetPoint("TOPRIGHT", ddBtn, "BOTTOMRIGHT", 0, -1)', 1, true) ~= nil,
          "narrow: ...with the menu following the button it drops from")
    check(SW:find("menu:SetWidth(150)", 1, true) == nil,
          "narrow: ...rather than keeping the button's old constant")

    -- ---- class three: the section header ---------------------------------
    check(SW:find("section.SetHeaderRightInset = function", 1, true) ~= nil,
          "narrow: a section header can be told what its right-hand furniture cost")
    local inset = SW:match("section%.SetHeaderRightInset = function%(self, inset%)(.-)\n    end\n")
    check(inset ~= nil, "narrow: ...and that verb's body can be read")
    inset = inset or ""
    check(inset:find("local w = self:GetWidth()", 1, true) ~= nil,
          "narrow: ...taking the title's share from the LIVE width")
    check(inset:find('self:HookScript("OnSizeChanged", apply)', 1, true) ~= nil,
          "narrow: ...and re-taking it whenever the band changes width")
    check(SW:find("local x = RIGHT_INSET - (self.headerRightInset or 0)", 1, true) ~= nil,
          "narrow: the header's preview swatches start inside that same furniture")
    -- ---- class two: the trigger block's button pair ----------------------
    -- 150 + 4 + 110 is 264px of row inside a popout pane's 244.
    check(CARDS:find("local trigColW = max((bodyWidth or 260) - 16, 60)", 1, true) ~= nil,
          "narrow: the trigger block names the column its buttons must share")
    check(CARDS:find("if tagX > 0 and (tagX + 110) > trigColW then", 1, true) ~= nil,
          "narrow: ...and Add Condition wraps rather than overhanging the mode button")
    check(CARDS:find("warn:SetWidth(trigColW)", 1, true) ~= nil,
          "narrow: the empty-group warning wraps at a width it was TOLD, so it can be measured")
    check(CARDS:find("tagY = tagY - (max(warn:GetStringHeight() or 0, 14) + 12)", 1, true) ~= nil,
          "narrow: ...and the cursor advances by what it measured, not a one-line 26")
end

-- ============================================================
-- 14. THE CHROME DIET  (phase 5 + the four moves, spec section 18)
-- ------------------------------------------------------------
-- Measured at a 600px window, 542px of chrome stood between the top of this page
-- and the first indicator: enable banner 68, canvas 160, pool strip 30, spec
-- strip 26, tab strip 28, add block ~230. Four moves, approved together:
--
--   1. the add block becomes ONE row that opens a panel (phase 5)
--   2. Preview Scale becomes a glyph in the canvas's top-right
--   3. Template and Spec share a row, paid for by an overflow menu
--   4. the canvas folds, under a LITERAL key
--
-- Each section below says what one move IS; the numbers are pinned at the end.
-- ============================================================
print("-- Aura Designer: the add flow is a panel, not standing furniture")
do
    -- ---- move 1: the add block is one row ------------------------------
    check(CARDS:find("S.BuildAddIndicatorPane = function(host, opts)", 1, true) ~= nil,
          "add: the whole add flow is one builder")
    -- ☠ NO WIZARD. Three numbered sections stand on ONE surface -- which
    -- aura, what it should look like, where -- and the scope step that stood
    -- between them is gone, which is exactly what spec section 26's approved
    -- drawing removes. Any step machinery reappearing here is the regression.
    local pane = CARDS:match("S%.BuildAddIndicatorPane = function%(host, opts%)(.-)\nend\n")
    check(pane ~= nil, "add: the panel builder's body can be read")
    pane = pane or ""
    check(pane:find("NewPane", 1, true) == nil,
          "add: the panel builds no steps")
    check(pane:find("Crumb(", 1, true) == nil,
          "add: ...so there is no back-crumb to a step it never left")
    check(pane:find('Show("', 1, true) == nil,
          "add: ...and nothing shows one step by hiding the others")
    local s1 = pane:find('CreateNumberedHeading(host, 1, L["WHICH AURA?"]', 1, true)
    local s2 = pane:find('CreateNumberedHeading(host, 2, L["HOW SHOULD IT SHOW?"]', 1, true)
    local s3 = pane:find('CreateNumberedHeading(host, 3, L["WHERE?"]', 1, true)
    check(s1 and s2 and s3 and s1 < s2 and s2 < s3,
          "add: the three sections are numbered and in order on one surface")

    -- ⚠ THE FILTER ROUTE IS A SECOND ANSWER TO SECTION 1, NOT A SCOPE. Its
    -- effect hangs off a whole filter rather than one aura -- a real reason it
    -- cannot be spell-first, and NOT a reason to put the taxonomy back. Section 1
    -- asks "which aura?", and a filter is a saved answer to that question.
    --
    -- ☠ AND IT IS DRAWN AS A PEER, NOT A GHOST LINE UNDER THE SPELL BUTTON
    -- (spec section 27.2). Both routes take `primary`, both take the same
    -- height, and the filter one no longer takes `ghost` -- which is the whole
    -- of what "it almost looks like an afterthought" was describing.
    check(pane:find('text = L["Select a filter"],', 1, true) ~= nil,
          "add: the filter route is offered beside the spell search, in section 1")
    check(pane:find("ghost = true", 1, true) == nil,
          "add: ...at the same weight as it, not as a ghost line beneath it")
    check(pane:find("onPick = function(kind, key) PickFilter(kind, key) end,", 1, true) ~= nil,
          "add: ...and answers the same section rather than opening a branch of its own")
    -- ☠ AND IT OPENS THE FULL OVERLAY, THE WAY THE SPELL DATABASE DOES. The
    -- anchored dropdown is the thing it stopped being: that one hangs off a
    -- button and takes `anchor`, and both of those must be gone from this panel.
    check(pane:find("OpenADFilterPicker({", 1, true) ~= nil,
          "add: ...through the shared overlay opener")
    check(pane:find("OpenFilterPicker({", 1, true) == nil,
          "add: ...and not through the anchored dropdown it replaced")
    check(pane:find("anchor = self", 1, true) == nil,
          "add: ...so nothing in the panel is hung off a button any more")
    -- ...and it DIMS the effects a filter cannot drive rather than hiding them
    -- behind a list of its own, which is what a scope step was.
    check(pane:find('if source.kind ~= "filter" then return true end', 1, true) ~= nil,
          "add: only a filter source narrows what section 2 offers")
    check(pane:find("return (eff and eff.filterable) or false", 1, true) ~= nil,
          "add: ...to the effects the list itself declares filterable")

    -- ☠ THE TILES ARE BUILT ONCE AND RE-STATED, NEVER REBUILT. A pane's
    -- contents are constructed on EVERY page build and frames cannot be
    -- garbage-collected in this client, so a section that re-drew itself on a
    -- click would leak nine miniature frames per click.
    check(pane:find("tile:SetTileState(state)", 1, true) ~= nil,
          "add: a click changes each tile's STATE")
    -- (Onto the host, or onto the one block opts.inline dims as a whole.)
    check(pane:find("CreateFrameTile(tileParent, {", 1, true) ~= nil,
          "add: ...on tiles built once, in the builder")
    check(pane:find("if opts.SetHeight then opts.SetHeight(paneH) end", 1, true) ~= nil,
          "add: ...and the pane reports its height instead of assuming one")

    -- ☠ AND A POOLED PANEL CANNOT READ LIVE STATE IN ITS BUILDER. Everything
    -- the panel says about the world -- which effects the chosen aura already has,
    -- the pool, the spec -- is re-derived by a verb the OPENER calls. Both of the
    -- designer bugs in spec section 23 were the other shape.
    check(pane:find("Sync = Sync,", 1, true) ~= nil,
          "add: the panel hands back a Sync verb")
    -- ☠ SECTION 3 WRITES THE ANCHOR THE PANEL ASKED FOR. Every placed instance
    -- already carries `anchor`, so this is one extra argument on the shared add
    -- verb and no new shape in the store.
    check(CARDS:find("local function AddPickedSpell(auraName, typeKey, mode, anchor)", 1, true) ~= nil,
          "add: the shared add verb takes the anchor section 3 chose")
    check(CARDS:find("if anchor and ANCHOR_POSITIONS[anchor] then instance.anchor = anchor end",
                     1, true) ~= nil,
          "add: ...and writes it onto the instance it just minted")
    check(pane:find('(eff.mode == "placed") and anchor or nil)', 1, true) ~= nil,
          "add: ...only for a placed effect, which is the only kind with a position")
    -- ☠ ONE LIST, ONE READER. The split panel asked the scope question until
    -- 2026-09-22; it opens this panel now, so the scope lists went with the block.
    check(CARDS:find("AddFlowScopes", 1, true) == nil,
          "add: the three scope lists are gone with the split panel's block")
    check(CARDS:find("local function AddFlowEffects()", 1, true) ~= nil,
          "add: the panel's own list is flat and declared once")
    check(CARDS:find("local EFFECTS = AddFlowEffects()", 1, true) ~= nil,
          "add: ...and is read as a verb too")
    -- ☠ NINE, AND EVERY ONE THE THREE SCOPES HELD. The design sketch wrote six
    -- because it said "Recolour" once for FOUR distinct records; collapsing them
    -- would drop three effects or ask a second question, which is the step this
    -- panel exists to remove.
    local effects = CARDS:match("local function AddFlowEffects%(%)(.-)\nend\n") or ""
    local nEff = 0
    for _ in effects:gmatch('type = "') do nEff = nEff + 1 end
    eq(nEff, 9, "add: ...listing every effect the three scopes held between them")
    for _, t in ipairs({ "icon", "square", "bar", "border", "healthbar",
                         "background", "nametext", "healthtext", "sound" }) do
        check(effects:find('type = "' .. t .. '"', 1, true) ~= nil,
              "add: ...including " .. t)
    end
    -- Sound is not filterable: the native sound path registers per spell ID, so a
    -- 600-spell filter would mean 600 registrations.
    local soundAt = effects:find('type = "sound"', 1, true)
    check(soundAt ~= nil and effects:find("filterable = false", soundAt, true) ~= nil,
          "add: ...and sound is not offered for a filter source")

    -- The add-by-ID path survives the reordering: the half of ADAddByID that
    -- NAMES a spell had to come out, because the flow has no type yet.
    check(CARDS:find("local function ADResolveByID(idNum, idText)", 1, true) ~= nil,
          "add: the naming half of add-by-ID is a verb of its own")
    check(CARDS:find("local auraName, display, isAdHoc, blocked = ADResolveByID(idNum, idText)", 1, true) ~= nil,
          "add: ...and ADAddByID is what is left of it")
    check(pane:find("ADResolveByID(idNum, idText)", 1, true) ~= nil,
          "add: ...so typing a spell ID still works on the spell step")

    -- ⚠ SPELL-FIRST CREATES A STATE THE OLD ORDER COULD NOT REACH: a spell that
    -- already has THIS type of effect. The old picker greyed those rows because it
    -- knew the type; this one cannot, so the type card says so instead of
    -- silently doing nothing.
    check(pane:find('DF:Say(L["Already added."])', 1, true) ~= nil,
          "add: a duplicate is refused out loud on the type card")

    -- ...and the split panel's picker column is gone.
    check(CARDS:find("effectsPicker", 1, true) == nil,
          "add: the split panel's picker column is gone")
    local headBody = CARDS:match("S%.BuildEffectsHeadArea = function%(parent, yPos%)(.-)\nend\n")
    check(headBody ~= nil, "add: the head area's body can be read")
    headBody = headBody or ""
    check(headBody:find('yPos = S.BuildClassicAddTiles(parent, yPos, "indicator")', 1, true) ~= nil,
          "add: ...and it mounts the classic add tiles")

    -- ☠ THE CLASSIC DESIGNER RUNS THIS PANE INSIDE ITS TAB (2026-09-22), never in a
    -- popout: two picture tiles, Add from a Spell / Add from a Filter, each handing
    -- the pane the route it chose. The flow is run in test_designers_classic.lua;
    -- here the wiring is read.
    local defsBody = CARDS:match("S%.ClassicAddSourceDefs = function%(%)(.-)\nend\n") or ""
    check(defsBody:find('{ source = "spell",  label = L["Add from a Spell"]', 1, true) ~= nil,
          "add: the classic Effects tab has an Add from a Spell tile")
    check(defsBody:find('{ source = "filter", label = L["Add from a Filter"]', 1, true) ~= nil,
          "add: ...and an Add from a Filter tile")
    check(defsBody:find('L["Add Indicator"]', 1, true) == nil,
          "add: ...instead of one Add Indicator button")
    local flowBody = CARDS:match("S%.BuildClassicAddFlow = function%(parent, kind%)(.-)\nend\n") or ""
    check(flowBody:find("source = flow.source, fitWidth = true, restore = restore,", 1, true) ~= nil,
          "add: ...each entering the pane with its route chosen, laid out for the tab")
    check(flowBody:find("inline = true,", 1, true) ~= nil,
          "add: ...as the inline pane, which says its states and follows its own height")
    check(flowBody:find('L["Back to Effects"]', 1, true) ~= nil,
          "add: ...headed by Back to Effects")
    check(flowBody:find("back:SetScript(\"OnClick\", function() S.EndClassicAddFlow(true, kind) end)", 1, true) ~= nil,
          "add: ...which ends the flow and rebuilds the list")
    check(CARDS:find('"df.adadd.', 1, true) == nil and CARDS:find("S.OpenClassicAddPopout", 1, true) == nil,
          "add: ...and no popout hosts it any more")
    -- The pane's opt-ins, each behind its own opts field.
    check(pane:find('local srcOnly = (opts.source == "spell" or opts.source == "filter") and opts.source or nil', 1, true) ~= nil,
          "add: the pane takes a chosen route only when handed one")
    check(pane:find("if srcOnly ~= \"filter\" then\n        spellBtn = CreateFrame", 1, true) ~= nil
          and pane:find("if srcOnly ~= \"spell\" then\n        filterBtn = CreateFrame", 1, true) ~= nil,
          "add: ...and then builds that route's button only")
    check(pane:find("if opts.fitWidth then", 1, true) ~= nil,
          "add: the tile columns widen only for a host that asks")
    check(pane:find("Snapshot = function()", 1, true) ~= nil,
          "add: the pane hands out its answers for a rebuild")
end

print("-- Aura Designer: Preview Scale is a glyph, not a row across the canvas")
do
    -- ---- move 2: the slider moves behind a glyph -----------------------
    check(CARDS:find("local scaleBtn = GUI:CreateGlyphButton(container, {", 1, true) ~= nil,
          "scale: the compact canvas carries a glyph, not a slider")
    check(CARDS:find('scaleBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", -6, -2)', 1, true) ~= nil,
          "scale: ...in the top-right of its own label strip")
    -- ☠ EXACTLY ONE INLINE SLIDER IN THE FILE, and it is the split panel's.
    -- If a second appears the 30px CANVAS_FURNITURE gave back is being drawn over.
    local inline = 0
    for _ in CARDS:gmatch("GUI:CreateSlider%(container,") do inline = inline + 1 end
    eq(inline, 1, "scale: the canvas builds one inline slider, in the non-compact arm")
    local compactArm = CARDS:match("local scaleBtn = GUI:CreateGlyphButton%(container,(.-)local scaleSlider = GUI:CreateSlider%(container,")
    check(compactArm ~= nil, "scale: ...and the arm before it can be read")
    compactArm = compactArm or ""
    check(compactArm:find("\n    elseif not thumb then\n", 1, true) ~= nil,
          "scale: ...reached only when the form is neither the glyph nor a thumbnail")

    -- ☠ THE PANEL IS POOLED BY KEY, so its build runs once and keeps whatever
    -- table it captured. The preview-scale table is the current PRESET's, which a
    -- template or mode switch replaces -- so the slider binds to an indirection.
    check(CARDS:find("local function ScaleProxy(key)", 1, true) ~= nil,
          "scale: the panel's slider binds to a stable indirection")
    check(CARDS:find("scaleHosts[popKey] = { db = scaleDB, apply = ApplyPreviewScale }", 1, true) ~= nil,
          "scale: ...and whichever canvas is live registers itself behind it")
    check(CARDS:find("ScaleProxy(popKey), \"previewScale\",", 1, true) ~= nil,
          "scale: ...so the slider never writes the template it was built against")
    check(CARDS:find("if pop.dfScaleSlider and pop.dfScaleSlider.RefreshValue then", 1, true) ~= nil,
          "scale: ...and re-reads its value on every open, because opens are adopts")
    -- Two designers, two keys: a shared key would hand the Text Designer the panel
    -- already bound to the Aura Designer's preview scale.
    check(CARDS:find('local popKey = (opts and opts.scaleKey) or "df.previewscale.aura"', 1, true) ~= nil,
          "scale: the panel key is the caller's, defaulting to this designer's")
    check(CARDS:find('if pop and not pop.closed then pop:Close("source") end', 1, true) ~= nil,
          "scale: the panel goes when its canvas does -- a fold, a rebuild, a close")
end

print("-- Aura Designer: a fold persists under a literal key")
do
    -- ☠ THE HAZARD. CreateCollapsibleSection persists a fold under the section's
    -- TITLE TEXT unless told otherwise -- so a localised title writes a second
    -- profile key and a reworded one orphans the first.
    local SW = options_file_source("GUI/SettingsWidgets.lua")
    check(SW:find("local stateKey = section.collapseKey or text", 1, true) ~= nil,
          "fold: the section reads its state from the caller's key when it has one")
    check(SW:find("local persistKey = self.collapseKey or self.sectionTitleText", 1, true) ~= nil,
          "fold: ...and writes it back to the same slot, not to the title")
    check(SW:find("saved[persistKey] = (not self.expanded) or nil", 1, true) ~= nil,
          "fold: ...which is the only place the fold is stored")
end

print("-- Aura Designer: the spell picker retargets every open panel's tether")
do
    -- ☠ IN GAME: opening the picker left the Add Indicator panel's outline drawn
    -- around two unrelated rows of the spell list. The picker fills opts.parent
    -- edge to edge, so the surface every open panel was tethered to is under it.
    --
    -- ⚠ SCOPED TO THE TWO FUNCTION BODIES, AND WITH COMMENTS STRIPPED. A file-wide
    -- find answers "is this string anywhere in Cards.lua", which the comment
    -- explaining the fix satisfies on its own -- so the assertion would pass with
    -- both calls deleted.
    local function body(src, head, tail)
        local a = src:find(head, 1, true)
        check(a ~= nil, "adpicker: " .. head .. " exists")
        if not a then return "" end
        local b = src:find(tail, a + #head, true)
        check(b ~= nil, "adpicker: ...and it closes")
        return (src:sub(a, b or a):gsub("%-%-[^\n]*", ""))
    end

    local open = body(CARDS, "local function OpenADPicker(opts)", "\nend")
    local iOpen = open:find("DF.FilterRegistry:OpenSpellPicker(opts)", 1, true)
    local iSet  = open:find("GUI:SetPopoutTetherOverride(opts.parent)", 1, true)
    check(iSet ~= nil,
          "adpicker: the open prelude points every panel at the surface the picker covers")
    check(iOpen ~= nil and iSet ~= nil and iOpen < iSet,
          "adpicker: ...AFTER the open, so a picker that failed to open leaves nothing to restore")

    local closed = body(CARDS, "local function ADPickerClosed()", "\nend")
    local iClear = closed:find("GUI:ClearPopoutTetherOverride()", 1, true)
    local iTab   = closed:find("S.SwitchTab(", 1, true)
    check(iClear ~= nil,
          "adpicker: the restore hook puts every panel's own target back")
    check(iClear ~= nil and iTab ~= nil and iClear < iTab,
          "adpicker: ...before the tab rebuild, which can close panels out from under it")

    -- The kit half, which is where the exactness lives: the consumer never names
    -- what it is restoring, so it cannot get a function target wrong. The verb
    -- takes a bare region and has no idea what kind of thing is covering.
    local PO = ui_file_source("Popout.lua")
    check(PO:find("function Popout:SetTetherOverride(region)", 1, true) ~= nil,
          "adpicker: the kit verb is general -- a region, and nothing about a picker")
    check(PO:find("function UI:SetPopoutTetherOverride(region)", 1, true) ~= nil,
          "adpicker: ...and the host sweep is the same verb over the open set")
end
