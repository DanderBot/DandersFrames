local NS = ...

-- ============================================================
-- AURA DESIGNER PAGE BUILDERS -- the popout layout's rows
-- ------------------------------------------------------------
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
local ROWS  = options_file_source("AuraDesigner/UI/Rows.lua")
local SHELL = options_file_source("GUI/DesignerShell.lua")
local CARDS = options_file_source("AuraDesigner/UI/Cards.lua")
local AURAS = options_file_source("GUI/Pages/Auras.lua")
local EDIT  = options_file_source("AuraDesigner/UI/Editor.lua")
local GROUPS = options_file_source("AuraDesigner/UI/Groups.lua")

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
                       or IND:find("-- 12.1 AURA-SYSTEM STATUS OVERLAYS", a, true)
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
    check(EDIT:find("if Add and P.BuildAuraDesignerRowsPage and not DF:IsClassicSettingsLayout() then", 1, true) ~= nil,
          "harness: the popout arm needs Add AND a non-classic layout")
    check(EDIT:find("local function BuildAuraDesignerIsland(guiRef, pageRef, dbRef)", 1, true) ~= nil,
          "harness: ...and the split panel survives as classic's arm")

    -- ☠ THE ISLAND IS NOT IN page.children -- it never went through Add -- so
    -- DoBuild's own retire loop cannot see it. The popout arm has to drop it by
    -- hand or it sits under the bands showing the last build's controls.
    check(EDIT:find("S.mainFrame:SetParent(nil)", 1, true) ~= nil,
          "harness: the popout arm retires any island left over")

    check(ROWS:find("local tools = GUI:CreatePopoutPageTools(page)", 1, true) ~= nil,
          "tools: the row page takes the shared machinery")
    check(ROWS:find("if not tools then return end", 1, true) ~= nil,
          "tools: ...and bails where it answers nil, which is classic")
    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "ClaimKeys",
                         "WireModifiedTick", "WireFooter", "RegisterHoistedToggle",
                         "RefreshAfterGroupWrite", "HoldReason", "BandWidth" }) do
        check(ROWS:find("local function " .. v .. "(", 1, true) == nil,
              "tools: the row page does not re-declare " .. v)
    end
    check(ROWS:find("_popoutHolders", 1, true) == nil,
          "tools: the row page never manages the popout holders itself")
    check(ROWS:find("_popoutRowForKey", 1, true) == nil,
          "tools: ...nor the search row map")

    -- The all-rows rule, for this page: nothing is built at a column's 280, and
    -- the one band it builds is chromeless at the band's width.
    check(ROWS:find("GUI:CreateSettingsGroup(page.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "band: the effect's band is chromeless, at the width the layout pass gives it")
    check(ROWS:find("GUI:CreateSettingsGroup(page.child, 280", 1, true) == nil,
          "band: ...and nothing on the page is mounted at a column width")
    local addBoth = 0
    for _ in ROWS:gmatch('Add%([%w_%.]+,%s*[%w_%.]*,?%s*"both"%)') do addBoth = addBoth + 1 end
    check(addBoth >= 3, "band: every object the page adds is added \"both\" (" .. addBoth .. ")")

    -- A control row is a row: into a band, never straight into a column.
    local crows, crowsInBand = 0, 0
    for _ in ROWS:gmatch("GUI:CreateControlRow%(") do crows = crows + 1 end
    for _ in ROWS:gmatch("[%w_]+:AddWidget%(GUI:CreateControlRow%(") do crowsInBand = crowsInBand + 1 end
    eq(crows, crowsInBand, "band: every control row is mounted into a band")
end

-- ============================================================
-- 2. THE SHELL IS SHARED, AND KNOWS NOTHING ABOUT AURAS
-- Phase 4 puts the Text Designer on this same shell. A shell that reached for
-- DF.AuraDesigner would have to be forked for it, which is the thing it exists
-- to prevent.
-- ============================================================
print("-- Aura Designer: the shell is generic")
do
    check(SHELL:find("function GUI:BuildDesignerShell(page, opts)", 1, true) ~= nil,
          "shell: the shared shell is a GUI verb")
    -- Comments stripped: this file's own prose names the Aura Designer, because it
    -- is the first caller and the essay there says why. The CODE must not.
    local SHELL_CODE = SHELL:gsub("%-%-[^\r\n]*", "")
    check(SHELL_CODE:find("DF.AuraDesigner", 1, true) == nil,
          "shell: the shell never reaches for the Aura Designer")
    check(SHELL_CODE:find("auraName", 1, true) == nil,
          "shell: ...and knows nothing about auras")
    -- Everything AD-shaped arrives as a parameter.
    for _, opt in ipairs({ "opts.banner", "opts.canvas", "opts.strips", "opts.tabs",
                           "opts.buildTab", "opts.onTab" }) do
        check(SHELL:find(opt, 1, true) ~= nil, "shell: " .. opt .. " is a parameter")
    end
    -- The band order IS the design: banner, canvas, strips, tabs, then the tab.
    local order = {}
    for _, marker in ipairs({ "1. THE ENABLE BANNER", "2. THE CANVAS", "3. THE STRIPS",
                              "4. THE TAB STRIP", "5. THE ACTIVE TAB" }) do
        order[#order + 1] = SHELL:find(marker, 1, true)
        check(order[#order] ~= nil, "shell: the band order names " .. marker)
    end
    for i = 2, #order do
        check((order[i] or 0) > (order[i - 1] or 0), "shell: ...and band " .. i .. " follows band " .. (i - 1))
    end
    -- Every band is built at the band's width, through one helper.
    check(SHELL:find("f:SetSize(bandW, h)", 1, true) ~= nil,
          "shell: every band host is built at tools.BandWidth()")
    check(SHELL:find("local bandW = tools.BandWidth()", 1, true) ~= nil,
          "shell: ...asked for, never a literal")
end

-- ============================================================
-- 3. THE COLLECT SEAM
-- BuildTypeContent decides what an icon has and a bar does not, in ONE place,
-- for both layouts. Collect mode walks the same branches and hands the section
-- BODIES back unrun; the row page mounts each into a pane.
-- ============================================================
print("-- Aura Designer: BuildTypeContent's collect seam")
do
    check(IND:find("local function BuildTypeContent(parent, typeKey, auraName, width, optProxy, yOffset, layoutGroup, indicatorID, collect)", 1, true) ~= nil,
          "collect: BuildTypeContent takes a collect table")

    -- ☠ RE-POINTED AND RESTORED. `parent` is the function's own local, so
    -- re-pointing it re-points every widget a body creates -- and NOT restoring it
    -- would leave the next body building onto the previous pane's holder.
    check(IND:find("local savedParent, savedGroup = parent, curGroup", 1, true) ~= nil,
          "collect: the seam saves the host before it re-points it")
    check(IND:find("parent, curGroup = paneParent, g", 1, true) ~= nil,
          "collect: ...points them at the pane")
    check(IND:find("parent, curGroup = savedParent, savedGroup", 1, true) ~= nil,
          "collect: ...and restores them after the body runs")

    -- A loose widget (Copy Appearance) belongs to the pane whose body is running.
    check(IND:find("if curGroup then\n            curGroup:AddWidget(widget, height or 30)", 1, true) ~= nil,
          "collect: the top-level AddWidget redirects into the running pane")

    -- The pane answers for its own re-flow, which is what the border toolkit's
    -- refreshStates and ADStructuralRedraw both reach for.
    check(IND:find("paneParent.dfAD_ReflowWidgets = reflow", 1, true) ~= nil,
          "collect: the pane carries the border toolkit's reflow hook")
    check(IND:find("paneParent.dfAD_ReflowInPane = reflow", 1, true) ~= nil,
          "collect: ...and the flag that tells a pane from a card")

    -- Nothing is built and nothing is sized in collect mode.
    check(IND:find("if collect then return collect end", 1, true) ~= nil,
          "collect: the tail returns the section list and sizes no host")
    check(IND:find("if not collect then\n    parent.dfAD_ReflowWidgets = function()", 1, true) ~= nil,
          "collect: ...and stamps no card reflow onto the collector's host")

    -- ☠ A CONTROL INSIDE A PANE MUST NOT REBUILD THE PAGE. Every route into a page
    -- builder closes every open panel first, so a tick that rebuilt would shut the
    -- panel it was clicked in. Fifteen controls in this file reveal a sibling.
    check(IND:find("local function ADStructuralRedraw(host)", 1, true) ~= nil,
          "collect: the file has one redraw verb that knows a pane from a card")
    local direct = 0
    for _ in IND:gmatch("DF:AuraDesigner_RefreshPage%(%)") do direct = direct + 1 end
    eq(direct, 1, "collect: ...and only ADStructuralRedraw's own fallback calls the page rebuild")
    local routed = 0
    for _ in IND:gmatch("ADStructuralRedraw%(parent%)") do routed = routed + 1 end
    eq(routed, 15, "collect: ...every reveal-a-sibling control goes through it")

    -- The one conditional section, and why it cannot stay conditional in a pane.
    check(IND:find("if collect or not proxy.hideIcon then", 1, true) ~= nil,
          "collect: text-only mode keeps the Border section and hides the ROW")
    check(IND:find('end, nil, function() return proxy.hideIcon and true or false end)', 1, true) ~= nil,
          "collect: ...by handing AddGroup the condition the row will carry")
    check(ROWS:find("if opts.hideOn then row.hideOn = opts.hideOn end", 1, true) ~= nil,
          "collect: ...which the row page puts on the row")
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
    check(PRO:find('if collect then AddGroup(L["Copy Appearance"], BuildCopyFrom) else BuildCopyFrom() end', 1, true) ~= nil,
          "rows: Copy Appearance is a row of its own in the popout layout")
    check(PRO:find('AddGroup(L["Tracked IDs"], function(g)', 1, true) ~= nil,
          "rows: ...and Tracked IDs is the section it always was")

    eqList(sectionOrder(typeBranch("icon", "square")), {
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
-- 6. THE ROWS ARE WIRED TO THE PROXY, NOT TO THE PAGE DB
-- Phase 0 gave the defaults engine an adapter so it can answer for a designer
-- record. It only ever sees one if the ROW hands it the proxy.
-- ============================================================
print("-- Aura Designer: each row's tick, keys and footer")
do
    check(ROWS:find("local RowProxy = function() return proxy end", 1, true) ~= nil,
          "wiring: the row page resolves its db to the effect's proxy")
    check(ROWS:find("db      = RowProxy,", 1, true) ~= nil,
          "wiring: ...and every row takes it")
    check(ROWS:find("tools.ClaimKeys(row, content)", 1, true) ~= nil,
          "wiring: every row claims the keys its pane registered")
    check(ROWS:find("tools.WireModifiedTick(row)", 1, true) ~= nil,
          "wiring: ...gets the amber modified tick")
    check(ROWS:find("tools.WireFooter(row, ApplyEffectGroup, RowProxy)", 1, true) ~= nil,
          "wiring: ...and a footer whose verbs write through the proxy, not the page db")
    check(ROWS:find("tools.RowDB", 1, true) == nil,
          "wiring: no designer row is wired to DF.db[mode]")

    -- ⚠ THE COUNT BADGE IS DERIVED, NEVER DECLARED. What a pane holds varies with
    -- client capability (the border toolkit's include set, the pandemic gate), so
    -- a literal would be a second source of truth that is wrong on some clients.
    check(ROWS:find("count   = content and content.groupChildren and #content.groupChildren or nil", 1, true) ~= nil,
          "wiring: the count badge is read off the pane that was actually built")

    -- The two blocks that are not sections of BuildTypeContent, and the one
    -- setting that is a control row rather than a way in to a group.
    check(ROWS:find('AddRow(L["Triggered By"], function(group, holder)', 1, true) ~= nil,
          "wiring: a frame-level effect gets a Triggered By row")
    check(ROWS:find('AddRow(L["Priority"], function(group, holder)', 1, true) ~= nil,
          "wiring: ...and a Priority row")
    check(ROWS:find("S.BuildEffectTriggersBlock(host, effect", 1, true) ~= nil,
          "wiring: both mount the SAME builder the card mounts")
    check(CARDS:find("S.BuildEffectTriggersBlock = function(body, effect, bodyWidth, baseH)", 1, true) ~= nil,
          "wiring: ...which is declared once, in the card file")
    check(CARDS:find("triggersH = S.BuildEffectTriggersBlock(body, effect, bodyWidth, 0)", 1, true) ~= nil,
          "wiring: ...and mounted by the card too")
    check(ROWS:find('label     = L["Others Only"]', 1, true) ~= nil,
          "wiring: Others Only is a control row, not a panel holding one tick")
    check(ROWS:find("S.EffectOthersOnlyChanged(function() page:RefreshStates() end)", 1, true) ~= nil,
          "wiring: ...whose write is the card's, with a state pass instead of a rebuild")
    check(CARDS:find("S.EffectOthersOnlyChanged = function(redraw)", 1, true) ~= nil,
          "wiring: ...declared once")
end

-- ============================================================
-- 7. THE EFFECT ROW EXPANDS; IT DOES NOT OPEN A PANEL
-- Decision 3 of the rework: one level of popout, ever. The effect is a way in to
-- ten groups, so a panel on it would be a panel that had to contain ten more.
-- ============================================================
print("-- Aura Designer: the effect is a section, its groups are the rows")
do
    check(ROWS:find("local section = GUI:CreateCollapsibleSection(page.child, title, false, bandW)", 1, true) ~= nil,
          "expand: an effect is a collapsible section at the band's width")
    check(ROWS:find("section:RegisterChild(band)", 1, true) ~= nil,
          "expand: ...and its band is a section child, so the fold collapses the rows with it")
    check(ROWS:find("if not section.expanded then return end", 1, true) ~= nil,
          "expand: a collapsed effect builds no rows at all")

    -- ☠ NO NEW DB KEYS. CreateCollapsibleSection persists its fold under the
    -- section TITLE, and these titles carry spell names -- one entry per placed
    -- effect per pool, forever. The rework is a pure re-presentation, so the fold
    -- state stays in the in-memory table the card layout used.
    check(ROWS:find("section.expanded = expandedCards[cardKey] and true or false", 1, true) ~= nil,
          "expand: the fold state is read from the card layout's own table")
    check(ROWS:find("section.Toggle = function(self)", 1, true) ~= nil,
          "expand: ...and Toggle is REPLACED, so the factory's own write never runs")
    check(ROWS:find("GUI:GetCollapsedGroups", 1, true) == nil,
          "expand: ...no spell name reaches the persisted collapsed-groups store")

    -- The row page never opens a panel on the effect itself.
    check(ROWS:find("GUI:CreatePopoutRow(page.child, {\n            label   = label,", 1, true) ~= nil,
          "expand: the rows in the band are the only popout rows on the page")
end

-- ============================================================
-- 8. THE HEAD AREAS ARE THE CARD LAYOUT'S OWN
-- Every tab's furniture above the list -- the add block, the chips, the choice
-- cards, the teaching prose -- is declared ONCE and mounted by both layouts. Two
-- copies would be two edits every time the add flow moves, which is phase 5.
-- ============================================================
print("-- Aura Designer: one head area per tab, two hosts")
do
    check(SHELL:find("function GUI:AddDesignerLegacyTab(shell, build)", 1, true) ~= nil,
          "head: the shell has a door for a hand-anchored block")
    check(SHELL:find("shell.Add(host, h, \"both\")", 1, true) ~= nil,
          "head: ...which lands in the band column at the band's edges")

    -- ☠ ...AND THE ROW LAYOUT ASKS FOR LESS OF IT WITH EVERY PHASE. The add block
    -- became a panel in phase 5 and the filter chips became one in section 20, so
    -- what is left here is the ACTIVE INDICATORS caption, the Any Buff hint, and
    -- the filter glyph that rides the caption -- one function, one call site per
    -- layout, and the difference between them is an argument rather than a second
    -- copy.
    check(ROWS:find("{ skipAddBlock = true, skipChips = true,", 1, true) ~= nil,
          "head: the Effects caption is all the row layout still takes from it")
    check(ROWS:find("filterGlyph = true,", 1, true) ~= nil,
          "head: ...plus the glyph on it, which the split panel does not ask for")
    check(CARDS:find("S.BuildEffectsHeadArea = function(parent, yPos, opts)", 1, true) ~= nil,
          "head: ...declared once, in the card file")
    check(CARDS:find("local skipAdd = opts and opts.skipAddBlock or false", 1, true) ~= nil,
          "head: ...and the add block is what the first argument turns off")
    check(CARDS:find("local skipChips = opts and opts.skipChips or false", 1, true) ~= nil,
          "head: ...the chips what the second one does")
    local heads = 0
    for _ in CARDS:gmatch("S%.BuildEffectsHeadArea") do heads = heads + 1 end
    eq(heads, 2, "head: ...declared once and mounted once by the card")

    -- Phase 3's two: the Layout Groups and Debuffs choice-card blocks, lifted out
    -- of the tab builders they used to be welded into.
    for _, name in ipairs({ "BuildLayoutGroupsHeadArea", "BuildDebuffGroupsHeadArea" }) do
        check(EDIT:find("S." .. name .. " = function(parent, yPos)", 1, true) ~= nil,
              "head: " .. name .. " is declared once")
        check(ROWS:find("S." .. name .. "(host, -4)", 1, true) ~= nil,
              "head: ...and the row page mounts it as a band")
        local n = 0
        for _ in EDIT:gmatch("S%." .. name) do n = n + 1 end
        eq(n, 2, "head: ...declared once and mounted once by the card (" .. name .. ")")
    end

    -- ☠ AND THE LEGACY DOOR IS SHUT ON THESE TWO TABS. Phase 2 rendered them by
    -- calling the split panel's own builders into a stand-in scroll child; that is
    -- what this phase replaces, and leaving either call behind would render the
    -- tab twice.
    check(ROWS:find("S.BuildLayoutGroupsTab()", 1, true) == nil,
          "head: the row page no longer renders the split panel's Layout Groups tab")
    check(ROWS:find("S.BuildDebuffGroupsTab()", 1, true) == nil,
          "head: ...nor its Debuffs tab")
    check(ROWS:find("S.BuildGlobalTab()", 1, true) == nil,
          "head: ...nor its Global tab")
    check(ROWS:find("S.tabContentFrame = host", 1, true) == nil,
          "head: ...and nothing stands in for the split panel's scroll child any more")
    check(ROWS:find("BuildLayoutTabRows(ctx, shell)", 1, true) ~= nil,
          "head: Layout Groups is built as rows")
    check(ROWS:find("BuildGlobalTabRows(ctx, shell)", 1, true) ~= nil,
          "head: ...and so is Global")
end

-- ============================================================
-- 8b. A GROUP IS A SECTION; ITS BLOCKS ARE THE ROWS
-- The placed effect's shape, applied to a layout group. Decision 3: one level of
-- popout, ever -- a group is a way in to five or ten blocks, so a panel on it
-- would be a panel that had to contain five more.
-- ============================================================
print("-- Aura Designer: a layout group is a section, its blocks are the rows")
do
    check(ROWS:find("local section = GUI:CreateCollapsibleSection(page.child, group.name, false, bandW)", 1, true) ~= nil,
          "group: a group is a collapsible section at the band's width")
    check(ROWS:find("section:RegisterChild(band)", 1, true) ~= nil,
          "group: ...and its band is a section child, so the fold collapses the rows with it")
    check(ROWS:find("if not section.expanded then return end", 1, true) ~= nil,
          "group: a collapsed group builds no rows at all")

    -- ☠ NO NEW DB KEYS. CreateCollapsibleSection persists its fold under the
    -- section TITLE, and a group's title is a name the USER TYPED -- one permanent
    -- profile key per group, forever, which is a schema change smuggled in under
    -- "pure re-presentation". Same trap the effect rows document.
    check(ROWS:find("section.expanded = expandedGroups[cardKey] and true or false", 1, true) ~= nil,
          "group: the fold state is read from the card layout's own in-memory table")
    check(ROWS:find("expandedGroups[cardKey] = not self.expanded or nil", 1, true) ~= nil,
          "group: ...and Toggle is REPLACED, so the factory's own write never runs")
    check(ROWS:find("GUI:GetCollapsedGroups", 1, true) == nil,
          "group: ...no user-typed group name reaches the persisted collapsed-groups store")
    -- ☠ REPLACED, NOT HOOKED, AND THE DIFFERENCE IS INVISIBLE FROM THE OUTSIDE.
    -- A Toggle that captured the factory's own and called it would still keep the
    -- in-memory state -- and would ALSO run the factory's write into
    -- DandersFramesDB_v2.collapsedGroups, adding one permanent profile key per
    -- group per pool. The page would look and behave identically. So the check is
    -- that the original is never captured at all, on EITHER of this file's two
    -- collapsible sections.
    check(ROWS:find("= section.Toggle", 1, true) == nil,
          "group: ...and the factory's own Toggle is never captured and re-called")
    check(ROWS:find("section:HookScript", 1, true) == nil,
          "group: ...nor hooked")

    -- The two single-setting rows: one control, one plate, no panel.
    check(ROWS:find('label      = L["Name"],', 1, true) ~= nil,
          "group: the group's name is a control row")
    check(ROWS:find('kind       = "editbox",', 1, true) ~= nil,
          "group: ...an edit box")
    check(ROWS:find('tools.RegisterControlRow(nameRow, "editbox", "name", true)', 1, true) ~= nil,
          "group: ...registered with search as a CUSTOM binding, not a profile key")
    check(ROWS:find('tools.RegisterControlRow(ooRow, "checkbox", "othersOnly", true, OnOthersOnly)', 1, true) ~= nil,
          "group: Others Only is a control row too")
    -- ...and because the row layout draws it, the shared Growth block must not.
    check(ROWS:find("sections   = P.CollectLayoutGroupSections(group, true),", 1, true) ~= nil,
          "group: ...so the collector is told to leave it out of Growth")
    check(EDIT:find("if kind == \"filter\" and IsOtherTab() and not omitOthersOnly then", 1, true) ~= nil,
          "group: ...which is the flag Growth reads")

    -- The row list is NOT declared by the row page: it is whatever the collector
    -- returns, which is the same list the card runs down its own cursor.
    check(ROWS:find("for _, sec in ipairs(spec.sections) do", 1, true) ~= nil,
          "group: the rows come from the collector, never from a literal list")
    check(EDIT:find("by = RunCardSections(body, bodyWidth, by, CollectLayoutGroupSections(group))", 1, true) ~= nil,
          "group: ...and the card runs the SAME list")
    check(EDIT:find("by = RunCardSections(body, bodyWidth, by, CollectDebuffGroupSections(group))", 1, true) ~= nil,
          "group: ...on the Debuffs tab too")

    -- ⚠ FIVE SIBLING ROWS, NOT A NESTED SECTION. RegisterChild carries exactly one
    -- section per widget, so a collapsible inside a collapsible would hide the
    -- inner header and leave its band on the page.
    check(ROWS:find("local styleSections = AddGroupAppearanceSection(page.child, group, PopoutWidth(), 0,", 1, true) ~= nil,
          "group: the appearance sections are collected, not re-declared")
    check(ROWS:find("for _, sec in ipairs(styleSections) do", 1, true) ~= nil,
          "group: ...and mounted as sibling rows in the same band")
    check(CARDS:find("collect.proxy = proxy", 1, true) ~= nil,
          "group: ...carrying the style proxy those rows have to be measured against")
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

    -- ☠ TWO HALVES OF ONE NUMBER. sortOrder is OPTIONAL on a group record, so the
    -- dropdown reads it through a customGet with a family fallback -- and the row's
    -- modified tick measures the same key against the record view's default. If
    -- those two disagree the control displays one answer and the tick reports the
    -- other, with nothing on screen to say which is right. The families genuinely
    -- differ: a filter group's pre-Wave-2 behaviour was Blizzard slot order, a
    -- debuff group's was soonest-to-expire.
    check(EDIT:find('local famSort = (kind == "debuff") and "TIME" or "DEFAULT"', 1, true) ~= nil,
          "binding: the sort dropdown's family fallback names both families")
    check(GROUPS:find('sortOrder = "TIME", sortMineFirst = false, sortReverse = false,', 1, true) ~= nil,
          "binding: ...and the debuff record's default is the same TIME")
    check(GROUPS:find('sortOrder = "DEFAULT", sortMineFirst = false, sortReverse = false,', 1, true) ~= nil,
          "binding: ...and the filter record's is the same DEFAULT")
end

-- ============================================================
-- 8e. THE GLOBAL TAB'S ROWS
-- Seven blocks, four of which hold settings. The three that hold ACTIONS take no
-- modified tick and no Reset Group -- a footer that reset nothing would be a
-- footer that lied, which is the failure this phase was blocked on.
-- ============================================================
print("-- Aura Designer: the Global tab's rows")
do
    local GV = CARDS:sub(CARDS:find("local function BuildGlobalView(parent, collect)", 1, true),
                         CARDS:find("P.BuildGlobalView = BuildGlobalView", 1, true))
    check(#GV > 100, "global: BuildGlobalView's body was found")

    check(GV:find("if collect then", 1, true) ~= nil,
          "global: AddGroup carries the collect seam")
    check(GV:find("local savedParent = parent", 1, true) ~= nil,
          "global: ...which saves the host before it re-points it")
    check(GV:find("parent = savedParent", 1, true) ~= nil,
          "global: ...and restores it after the body runs")
    check(GV:find("if collect then return collect end", 1, true) ~= nil,
          "global: ...and the tail sizes no host")

    -- The blocks, in order, and which of them is a settings group.
    local order, dbs = {}, {}
    for header in GV:gmatch('AddGroup%(L%["([^"]+)"%]') do order[#order + 1] = header end
    eqList(order, { "General", "Sound Alerts", "Duration Text", "Stack Text",
                    "Import from Buffs Tab", "Standard Buffs", "Actions" },
           "global: the blocks, in the order the split panel drew them")

    -- The action groups close with `end, false)`, which is the "no tick, no
    -- footer" flag. Read from the whole block -- start of its AddGroup to the
    -- start of the next one -- because the flag sits OUTSIDE the body's own
    -- closing paren and a %b() match stops short of it.
    local function blockText(name)
        local at = GV:find("AddGroup(L[\"" .. name .. "\"]", 1, true)
        check(at ~= nil, 'global: a block is declared for "' .. name .. '"')
        if not at then return "" end
        local nxt = GV:find("AddGroup(L[\"", at + 12, true) or #GV
        return GV:sub(at, nxt)
    end
    for _, name in ipairs({ "Import from Buffs Tab", "Standard Buffs", "Actions" }) do
        check(blockText(name):find("end, false)", 1, true) ~= nil,
              "global: " .. name .. " is an action group -- no tick, no footer")
        dbs[#dbs + 1] = name
    end
    eq(#dbs, 3, "global: three action groups")
    -- ...and the four that DO hold settings take the default record.
    for _, name in ipairs({ "General", "Duration Text", "Stack Text" }) do
        check(blockText(name):find("end, false)", 1, true) == nil,
              "global: " .. name .. " is a settings group -- it keeps both verbs")
    end

    -- ...and the one settings group whose keys the walk cannot see.
    check(GV:find('end, CreateSoundSettingsProxy(), { "soundEnabled", "soundChannel" })', 1, true) ~= nil,
          "global: Sound Alerts names its two custom-bound keys through ClaimKeys' extra door")
    check(ROWS:find("tools.ClaimKeys(row, content, sec.extra)", 1, true) ~= nil,
          "global: ...and the row passes them")

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
-- 8f. EVERY PHASE-3 ROW ANSWERS THROUGH A RECORD THAT CARRIES AN ADAPTER
-- Phase 0 gave the defaults engine an adapter hook so a designer record can
-- answer "is this modified" for itself. It only ever sees one if the ROW hands it
-- a table that has one -- and until this phase the Global tab's proxy, the group
-- style proxy and the group records had none, so every row on these two tabs
-- would have had a permanently dark tick and a Reset Group that wrote nothing.
-- Silently, with no error either way.
-- ============================================================
print("-- Aura Designer: the phase-3 records carry the defaults adapter")
do
    for _, name in ipairs({ "CreateGlobalDefaultsProxy", "CreateSoundSettingsProxy" }) do
        check(CARDS:find("local function " .. name .. "()", 1, true) ~= nil,
              "record: " .. name .. " exists")
        check(CARDS:find("P." .. name .. " = " .. name, 1, true) ~= nil,
              "record: ...and is published")
    end
    check(GROUPS:find("local function CreateRecordView(target, defaults)", 1, true) ~= nil,
          "record: the group records get a VIEW, not an adapter of their own")
    -- ☠ AND IT HAS TO BE A VIEW. A layout group IS SavedVariables and goes through
    -- LibSerialize on profile export, which cannot carry a function -- the same
    -- wall the Text Designer's elements hit in phase 0.
    check(GROUPS:find("__dfDefaultsAdapter = adapter,", 1, true) ~= nil,
          "record: ...whose view carries the hook")
    for _, name in ipairs({ "GroupRecordView", "DebuffGroupRecordView", "DebuffSelectionView" }) do
        check(GROUPS:find("P." .. name .. " = " .. name, 1, true) ~= nil,
              "record: " .. name .. " is published")
    end

    -- ☠ GetStored IS A rawget EVERYWHERE. Through any of these proxies __index
    -- answers with the fallback for an unset key, so an adapter reading back
    -- through its own proxy would find every key set and light the whole tab up.
    local rawgets = 0
    for _ in CARDS:gmatch("GetStored%s*=%s*function") do rawgets = rawgets + 1 end
    eq(rawgets, 3, "record: the card file mints three adapters")
    check(CARDS:find("return rawget(t, k)", 1, true) ~= nil,
          "record: the Global tab's GetStored reads the stored block RAW")
    check(CARDS:find("return rawget(adDB, k)", 1, true) ~= nil,
          "record: ...the sound block's too")
    check(CARDS:find("GetStored  = function(k) return rawget(s, k) end", 1, true) ~= nil,
          "record: ...and the group style's, which is the one with copy-on-read")
    check(GROUPS:find("GetStored  = function(k) return rawget(target, k) end", 1, true) ~= nil,
          "record: ...and the group record view's")

    -- ⚠ AND THE FRAME LEVEL FINALLY HAS A DEFAULT. The General block has bound a
    -- slider to indicatorFrameLevel since it was wired, with no entry in the
    -- fallback table -- so the diff engine read "no default" as "not a setting
    -- here" and the row's tick could not have answered for it.
    check(CARDS:find("indicatorFrameLevel = 40,", 1, true) ~= nil,
          "record: the Global tab's frame-level default is named -- and it is 40, the render's no-op")

    -- The rows themselves: the record, never DF.db[mode].
    check(ROWS:find("local function RowRecord() return record end", 1, true) ~= nil,
          "record: a group's rows resolve their db to the group's own view")
    check(ROWS:find("db      = rowDB or RowRecord,", 1, true) ~= nil,
          "record: ...and every row takes it")
    check(ROWS:find("tools.WireFooter(row, spec.Apply, rowDB or RowRecord)", 1, true) ~= nil,
          "record: ...including the footer, whose verbs write through it")
    check(ROWS:find("tools.WireFooter(row, ApplyGlobalGroup, function() return sec.db end)", 1, true) ~= nil,
          "record: the Global tab's rows write through the record their block declared")
    check(ROWS:find("tools.RowDB", 1, true) == nil,
          "record: no designer row anywhere is wired to DF.db[mode]")

    -- The Categories row measures itself against the SELECTION block, which is a
    -- record of its own -- the group's own view answers for anchor and spacing and
    -- has never heard of `boss`.
    check(ROWS:find("local selView = DebuffSelectionView(group.selection)", 1, true) ~= nil,
          "record: the Categories row takes the selection block's own view")
    check(ROWS:find("sections[1].rowDB = function() return selView end", 1, true) ~= nil,
          "record: ...as its row db")

    -- ...and a row with nothing to reset gets neither verb.
    check(ROWS:find("if rowDB ~= false then", 1, true) ~= nil,
          "record: an action-only row takes no tick and no footer")
    check(ROWS:find("if sec.db then", 1, true) ~= nil,
          "record: ...and neither does an action-only Global block")
end

-- ============================================================
-- 9. THE CANVAS
-- Lifted as-is: the same anatomy, the same nine anchor dots, the same
-- RefreshGeometry. Only its own standing furniture changes, and only in the band.
-- ============================================================
print("-- Aura Designer: the canvas")
do
    check(ROWS:find("S.framePreview = CreateFramePreview(host, 0, nil, { compact = true, hideLabel = true })", 1, true) ~= nil,
          "canvas: the row page mounts the SAME canvas the split panel built")
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
    check(ROWS:find("canvasHeight = function() return P.CanvasWantedHeight(true) end", 1, true) ~= nil,
          "canvas: ...and the band asks it rather than naming a constant")
    check(SHELL:find("if type(h) == \"function\" then h = h() end", 1, true) ~= nil,
          "canvas: the shell accepts a verb for a band whose height is not fixed")
    check(SHELL:find("function shell.SetCanvasHeight(want)", 1, true) ~= nil,
          "canvas: ...and can regrow it in place, because the caller is a slider drag")
    check(SHELL:find("host.layoutHeight = want", 1, true) ~= nil,
          "canvas: ...through layoutHeight, which is what the layout pass reads")

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
    check(ROWS:find("local CANVAS_H  = 132", 1, true) ~= nil,
          "canvas: ...and it is the artifact's 132")

    -- ☠ WHAT THE ISLAND'S REUSE GUARD DID, AT THE RIGHT SCOPE. The harness caches
    -- a valid build across revisits, so nothing would re-read the frame size or
    -- the preview scale; the canvas has a verb for exactly that.
    check(ROWS:find('host:HookScript("OnShow", function()', 1, true) ~= nil,
          "canvas: the canvas re-reads its geometry when the page shows")
    check(ROWS:find('host:HookScript("OnHide", P.ClearPlacedIndicators)', 1, true) ~= nil,
          "canvas: ...and stops the preview pool's border animations when it hides")
end

-- ============================================================
-- 10. THE SWITCH-TAB VERB WORKS IN BOTH LAYOUTS
-- Sixty-odd call sites across the editor say "the data moved, redraw the tab".
-- That sentence is true in both layouts; only the machinery differs, so the
-- branch is at the verb rather than at the call sites.
-- ============================================================
print("-- Aura Designer: one redraw verb, two layouts")
do
    check(CARDS:find("if S.rowsMode then", 1, true) ~= nil,
          "switch: S.SwitchTab knows which layout it is in")
    check(CARDS:find("if S.page and S.page.Refresh then S.page:Refresh() end", 1, true) ~= nil,
          "switch: ...and the popout layout's redraw is the harness's own rebuild")
    check(EDIT:find("if S.rowsMode then", 1, true) ~= nil,
          "switch: AuraDesigner_RefreshPage does the same")
    check(ROWS:find("S.rowsMode = true", 1, true) ~= nil,
          "switch: the row page sets the flag")
    check(EDIT:find("S.rowsMode = false", 1, true) ~= nil,
          "switch: ...and the island clears it")
end

-- ============================================================
-- 11. TWO STRIPS, AND THE PREVIEW BETWEEN THEM -- THE POOL IS TABS AGAIN
-- ------------------------------------------------------------
-- My Buffs / Debuffs / Any Buff sat directly above Effects / Layout Groups /
-- Global and the pair read as tabs inside tabs -- "so confusion to know that they
-- are tabs within tabs". Hiding the pool in a dropdown solved that and cost the
-- three per-tab tooltips, which were the only place the two axes the pools differ
-- on were written down. So the tabs come back and MOVE instead: above the frame
-- preview, which then stands between the two strips. The nesting goes by distance
-- rather than by hiding, and the tooltips return.
-- ============================================================
print("-- Aura Designer: the pool tabs above the preview")
do
    -- The split panel's own strip survives, untouched, for its ONE host.
    check(ROWS:find("S.BuildPoolStrip = function(buffTabBar)", 1, true) ~= nil,
          "pool: the split panel's pool strip is declared once")
    check(EDIT:find("S.BuildPoolStrip(buffTabBar)", 1, true) ~= nil,
          "pool: ...and the split panel mounts it into its own slice")
    -- ☠ THE ABSENCE IS THE ASSERTION: the band layout has its own strip and must
    -- not also mount the split panel's, which is anchored inside S.mainFrame.
    check(ROWS:find("build = function(host) S.BuildPoolStrip(host) end", 1, true) == nil,
          "pool: ...but the band layout never mounts THAT one")

    check(ROWS:find("S.BuildPoolTabs = function(host)", 1, true) ~= nil,
          "pool: the band layout's pool tabs are declared once")
    check(ROWS:find("canvasTabs = { height = POOLTABS_H,", 1, true) ~= nil
          and ROWS:find("build = function(host) S.BuildPoolTabs(host) end", 1, true) ~= nil,
          "pool: ...and mounted, into the shell slot that sits on the canvas")
    -- ⚠ ONE DESCRIPTION OF THE THREE POOLS, and it is a FUNCTION: a file-scope
    -- table of L[...] lookups freezes on whatever locale was live at load.
    check(ROWS:find("local function PoolDefs()", 1, true) ~= nil,
          "pool: the three pools are described once")
    check(ROWS:find("local MAIN_TAB_DEFS = PoolDefs()", 1, true) ~= nil,
          "pool: ...which the split panel's strip reads")

    local tabs = ROWS:match("S%.BuildPoolTabs = function%(host%)(.-)\nend\n")
    check(tabs ~= nil, "pool: the pool tabs' body can be read")
    tabs = tabs or ""
    check(tabs:find("local defs = PoolDefs()", 1, true) ~= nil,
          "pool: ...and reads the same list, not a second copy")
    -- ☠ THE FOLDER-TAB LANGUAGE, AND IT IS THE KIT'S. A tab that sits ON the
    -- preview panel and says what it is showing is not the underline tab the
    -- sub-tab strip wears; drawing it as one is what made the two read as a block.
    check(tabs:find("GUI:StyleFolderTab(btn, {", 1, true) ~= nil,
          "pool: they are folder tabs, from the shared factory")
    check(tabs:find("tab = true", 1, true) == nil,
          "pool: ...not the underline tabs the sub-tab strip below them wears")
    -- THE TOOLTIPS ARE BACK, one per tab, which is the whole reason for the move.
    check(tabs:find("tooltip  = { title = def.label, lines = def.tooltip }", 1, true) ~= nil,
          "pool: each tab explains itself on hover again")
    -- No new state: the tabs read and write exactly what the strip did.
    check(tabs:find("btn:SetActive(S.activeBuffTab == def.key)", 1, true) ~= nil,
          "pool: a tab reads S.activeBuffTab -- no new key, no schema change")
    check(tabs:find("onClick  = function() SetMainTab(capturedKey) end", 1, true) ~= nil,
          "pool: ...and writes through SetMainTab, which owns every side effect")
    -- SetMainTab paints THESE buttons, so this layout must fill the map it walks --
    -- and must clear whatever a visit to the split panel left in it first.
    check(tabs:find("wipe(mainTabButtons)", 1, true) ~= nil,
          "pool: ...after clearing the map a visit to the split panel left behind")
    check(tabs:find("mainTabButtons[def.key] = btn", 1, true) ~= nil,
          "pool: ...and filling it with the buttons SetMainTab now paints")
    -- ⚠ SCOPED TO SetMainTab'S BODY. UpdateSpecDropdownState is DECLARED in
    -- Rows.lua too, so a file-wide find answers "is this name anywhere" and passes
    -- with the call deleted -- which is exactly how it first passed.
    local setMain = CARDS:match("local function SetMainTab%(tabKey%)(.-)\nend\nP%.SetMainTab")
    check(setMain ~= nil, "pool: SetMainTab's body can be read")
    check((setMain or ""):find("btn:SetActive(key == tabKey)", 1, true) ~= nil,
          "pool: SetMainTab paints the map these tabs fill")
    check((setMain or ""):find("UpdateSpecDropdownState()", 1, true) ~= nil,
          "pool: a pool change greys Spec on the spot")
    check(ROWS:find("UpdateSpecDropdownState()", 1, true) ~= nil,
          "pool: ...and the rebuild it triggers greys the NEW dropdown too")

    -- ☠ EQUAL WIDTH, DIVIDED FROM THE BAND, and re-taken on resize -- the three
    -- tabs are one three-way switch, and at the 640px default their words do not
    -- fit any other way.
    check(tabs:find("local tabW = (w - (n - 1) * POOLTAB_GAP) / n", 1, true) ~= nil,
          "pool: the tabs split the band between them")
    check(tabs:find([[host:SetScript("OnSizeChanged", function(_, w) SizeTabs(w) end)]], 1, true) ~= nil,
          "pool: ...re-taken whenever the band changes width")
    check(tabs:find("b:SetFolderX((i - 1) * (tabW + POOLTAB_GAP))", 1, true) ~= nil,
          "pool: ...and each tab is TOLD its x, because it re-anchors itself")

    -- ☠ ABOVE THE CANVAS, WHICH IS THE ENTIRE POINT. Below it they would be back
    -- against the sub-tab strip with nothing between them.
    local poolAt   = ROWS:find("canvasTabs = { height = POOLTABS_H,", 1, true)
    local canvasAt = ROWS:find("canvas = function(host, shell)", 1, true)
    local stripAt  = ROWS:find("strips = {", 1, true)
    local tabsAt   = ROWS:find("tabs = {", 1, true)
    check(poolAt and canvasAt and poolAt < canvasAt,
          "pool: the pool tabs are declared above the canvas")
    check(canvasAt and stripAt and canvasAt < stripAt,
          "pool: ...the canvas above the scope row")
    check(stripAt and tabsAt and stripAt < tabsAt,
          "pool: ...and the scope row above the one tab strip")

    -- The shell mounts them in that order too, not merely declares them.
    local shellPool   = SHELL:find("if opts.canvasTabs and opts.canvasTabs.build then", 1, true)
    local shellCanvas = SHELL:find("if opts.canvas then", 1, true)
    check(shellPool and shellCanvas and shellPool < shellCanvas,
          "pool: the shell adds the canvas-tab band before the canvas band")
    -- Bands stack flush (y = y - h), so what is built there touches the panel
    -- below it -- which is what lets the selected tab be drawn continuous with it.
    check(SHELL:find("shell.canvasTabHost = host", 1, true) ~= nil,
          "pool: ...and publishes the host, like every other band")

    -- ...and there is still exactly ONE strip of the OTHER kind on the page.
    check(select(2, ROWS:gsub("strips = {", "")) == 1,
          "pool: the page declares one strip band")
    check(select(2, ROWS:gsub("tabs = {", "")) == 1,
          "pool: ...and one sub-tab strip")
end

-- ============================================================
-- 11a. THE FOLDER TAB -- A TAB THAT BELONGS TO THE PANEL UNDER IT
-- ------------------------------------------------------------
-- Two languages, deliberately different: an UNDERLINE tab switches which view of
-- a page you are looking at; a FOLDER tab sits on a panel and says what that
-- panel is showing. The pool and the sub-tabs can then stand on one page without
-- reading as one block. It lives in the kit because nothing about it is an aura.
-- ============================================================
print("-- DandersUI: the folder tab")
do
    local W = ui_file_source("Widgets.lua")
    check(W:find("function UI:StyleFolderTab(btn, opts)", 1, true) ~= nil,
          "folder: the folder tab is a kit factory")
    local body = W:match("function UI:StyleFolderTab%(btn, opts%)(.-)\n    btn:SetActive%(btn%.dfActive%)")
    check(body ~= nil, "folder: ...whose body can be read")
    body = body or ""
    -- ☠ IT KNOWS NOTHING ABOUT A DESIGNER. A kit factory that named one would
    -- have to be forked for the second caller. ⚠ Scoped to the FOLDER TAB'S OWN
    -- BODY, not the file: Widgets.lua already cites an AuraDesigner page in an
    -- unrelated comment, so a file-wide find answers "is this name anywhere" and
    -- fails on a factory that is perfectly host-agnostic.
    check(body:find("AuraDesigner", 1, true) == nil,
          "folder: the factory names no consumer")
    check(body:find("DandersFrames", 1, true) == nil,
          "folder: ...and no host either")

    -- ☠ THE SELECTED TAB HAS NO RING, AND THAT IS THE WHOLE OF "JOINED". The
    -- baked `top` shape rounds the two upper corners but still strokes all four
    -- sides, so a ring on the selected tab draws a line along exactly the edge
    -- that is supposed to have disappeared into the panel.
    -- ⚠ SCOPED TO paint()'S OWN BODY. The hover arm repaints through the same
    -- three lines, so a body-wide find answers "is this anywhere in the factory"
    -- and stays green with the RESTING paint gutted -- which is the state a tab
    -- spends almost all of its life in.
    local paint = body:match("local function paint%(self%)(.-)\n    end")
    check(paint ~= nil, "folder: the resting paint can be read on its own")
    paint = paint or ""
    check(paint:find("border  = (not on) and edge or false", 1, true) ~= nil,
          "folder: the selected tab drops its ring, so it joins the panel below")
    check(paint:find("corners = { tl = true, tr = true }", 1, true) ~= nil,
          "folder: ...and rounds only its top corners, which is the baked shape")
    -- ☠ ApplyRoundedChrome, NOT CreateRoundedSurface: a rounded fill sits at a
    -- negative BACKGROUND sublevel, UNDER a backdrop's bgFile, so a frame that
    -- keeps its square backdrop renders the square in front of a surface that is
    -- drawing perfectly. Both paints, because either one leaving it out is a tab
    -- that goes square the moment the mouse crosses it.
    check(paint:find("host:ApplyRoundedChrome(self, {", 1, true) ~= nil,
          "folder: the square backdrop comes down through the one call that does it")
    check(select(2, body:gsub("host:ApplyRoundedChrome", "")) == 2,
          "folder: ...on the hover repaint too, not only at rest")
    -- The selected fill is the PANEL's, so it composites to what the band below
    -- composites to rather than to something close to it.
    check(body:find("local activeFill   = opts.activeFill   or { C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.8 }", 1, true) ~= nil,
          "folder: the selected tab wears the panel's own fill")
    -- Set back: shorter and bottom-anchored, so its top edge sits below the
    -- selected one's -- the sheets-behind-the-front-one read.
    check(body:find([[self:SetPoint("TOPLEFT", p, "TOPLEFT", x, self.dfActive and 0 or -setBack)]], 1, true) ~= nil,
          "folder: an unselected tab is set back by its own top edge")
    check(body:find([[self:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", x, 0)]], 1, true) ~= nil,
          "folder: ...while the selected one reaches the band's bottom edge")

    -- ⚠ NO HIGHLIGHT TEXTURE. The native HIGHLIGHT layer is a rectangle and
    -- would paint square corners back over the two arcs on every mouseover.
    check(body:find("HIGHLIGHT", 1, true) == nil,
          "folder: hover follows the shape rather than a square highlight layer")
    -- SetActive is the same verb StyleButton's tabs take, so a strip can be
    -- swapped between the two languages without rewiring.
    check(body:find("function btn:SetActive(active)", 1, true) ~= nil,
          "folder: it is driven by SetActive, like every other tab in the kit")
    -- OnLeave does not fire for a button hidden under the cursor, and a tab strip
    -- is rebuilt under a stationary mouse on every page refresh.
    check(body:find([[btn:HookScript("OnHide", leave)]], 1, true) ~= nil,
          "folder: a tab hidden under the cursor does not come back stuck lit")

    -- ============================================================
    -- THE THREE FILLS, AND WHY THE SELECTED ONE NEEDS THE ACCENT
    -- ------------------------------------------------------------
    -- "The three tabs at the top kinda blend in to the background now." The
    -- diagnosis that came with it -- that the unselected tabs are drawn DARKER
    -- than the panel -- is the opposite of what the palette actually says, and
    -- these numbers are read out of Theme.lua so nobody has to take that on
    -- trust or re-derive it by eye.
    -- ============================================================
    local TH = ui_file_source("Theme.lua")
    local function themeGrey(name)
        return tonumber(TH:match("local " .. name .. "%s*=%s*{r = ([%d%.]+)"))
    end
    local bg, panel, element = themeGrey("C_BACKGROUND"), themeGrey("C_PANEL"), themeGrey("C_ELEMENT")
    check(bg and panel and element, "folder: the three theme greys can be read out of Theme.lua")
    bg, panel, element = bg or 0, panel or 0, element or 0
    -- C_ELEMENT is LIGHTER than C_PANEL. That single fact is what makes "set the
    -- unselected tab back by darkening it" impossible here: the tab already sits
    -- above the panel, and putting it below would put it under the page ground.
    check(element > panel, "folder: the element grey is LIGHTER than the panel grey...")
    check(panel > bg, "folder: ...and the panel grey lighter than the page background")
    -- The ground the strip stands on: a consumer's content panel, C_PANEL at 0.3
    -- over C_BACKGROUND at 0.95.
    local ground     = 0.3 * panel + 0.7 * (0.95 * bg)
    local selected   = 0.8 * panel + 0.2 * ground
    local unselected = 0.85 * element + 0.15 * ground
    check(ground < selected, "folder: the selected tab composites above the page ground")
    check(selected < unselected, "folder: ...and the unselected one above the selected/panel")
    -- THE WINDOW BETWEEN THE GROUND AND THE PANEL IS 0.025 WIDE, which is the
    -- whole argument for marking the selected tab with an accent instead of with
    -- a third fill. If the palette ever opens that gap up, this fails and the
    -- design decision is worth taking again.
    check(selected - ground < 0.03,
          "folder: there is no legible third step between the ground and the panel")

    -- The accent, on the selected tab only, on the edge FURTHEST from the join.
    check(body:find([[accentBar = btn:CreateTexture(nil, "ARTWORK")]], 1, true) ~= nil,
          "folder: the selected tab carries an accent bar")
    check(body:find([[accentBar:SetPoint("TOPLEFT", btn, "TOPLEFT", radius, 0)]], 1, true) ~= nil,
          "folder: ...on its TOP edge, which is the one the join does not use")
    -- INSET BY THE RADIUS. Run corner to corner it would put two square ends back
    -- over the two arcs -- the same trap that keeps a native hover layer off this
    -- factory.
    check(body:find([[accentBar:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -radius, 0)]], 1, true) ~= nil,
          "folder: ...inset by the radius, so it never reaches the two arcs")
    -- SCOPED TO paint()'S OWN BODY, not the factory's. `accentBar` is declared,
    -- anchored and coloured elsewhere in the same body, so a body-wide find
    -- answers "is this name anywhere" and stays green with the show/hide gutted --
    -- which would leave the bar painted on all three tabs at once.
    check(paint:find("accentBar:SetShown(on)", 1, true) ~= nil,
          "folder: ...and the resting paint is what turns it on and off")

    -- The accent is per host and changes on a mode switch, so the bar follows it
    -- rather than freezing on whatever was live when the strip was built.
    check(body:find("host:RegisterAccentListener(btn._folderAccentListener, btn)", 1, true) ~= nil,
          "folder: the bar follows the host accent...")
    -- OWNED BY THE BUTTON, AND REGISTERED ONCE. A bare closure is something
    -- nothing can take back off the list, and a tab strip is rebuilt on every page
    -- refresh; the guard also stops a re-style of the same button stacking a
    -- second entry on it.
    check(body:find("if not opts.accent and not btn._folderAccentListener then", 1, true) ~= nil,
          "folder: ...registered once, and owned by the button so it can be dropped")

    -- THE UNSELECTED EDGE IS DERIVED FROM THE FILL IT SITS ON. A ring composites
    -- over its OWN fill: C_BORDER at 0.5 reads as a 0.068 step off the panel and
    -- only 0.042 off this tab's lighter one, so the outline that says "sheet
    -- behind the front one" was most of the way to gone.
    check(body:find("local EDGE_ALPHA   = 0.8", 1, true) ~= nil,
          "folder: the unselected tab's edge alpha is raised to match the panel's")
    check(body:find("local edge         = opts.border       or { C_BORDER.r, C_BORDER.g, C_BORDER.b, EDGE_ALPHA }", 1, true) ~= nil,
          "folder: ...and the edge is built from it")
    check(body:find("C_BORDER.b, 0.5 }", 1, true) == nil,
          "folder: ...not from the 0.5 that was too low for this fill")
    -- The derivation itself, so the number cannot drift back without the reason
    -- going with it: C_BORDER at EDGE_ALPHA over the unselected fill must land a
    -- panel's-worth of step (0.068) above that fill.
    local border = themeGrey("C_BORDER") or 0
    check(math.abs((0.8 * border + 0.2 * unselected) - (unselected + 0.068)) < 0.01,
          "folder: 0.8 is the alpha that puts the tab's edge a panel's-step off its fill")
end
-- ============================================================
-- 11b. THE ACTIVE INDICATORS FILTER IS A GLYPH ON THE CAPTION
-- ------------------------------------------------------------
-- Eight chips loose on the page broke the all-rows rule they predate, and were
-- also the one flowing element left in the band column (section 17, Class 1). A
-- `Showing` popout row fixed both and cost 50px -- a 44px plate plus its 6px gap,
-- MORE than the 22px chip row it replaced, which is where the honest chrome total
-- went up rather than down. A glyph on a caption the page already pays for costs
-- nothing and opens the same panel.
-- ============================================================
print("-- Aura Designer: the filter glyph")
do
    -- ONE definition of the chips, two hosts -- the split panel's wrapping row
    -- and the pane. A second copy is how the three duplicated FRAME_ITEMS lists
    -- in this same file came about.
    check(CARDS:find("S.BuildFilterChips = function(host, width)", 1, true) ~= nil,
          "showing: the chips are declared once")
    check(CARDS:find("local function FilterChips()", 1, true) ~= nil,
          "showing: ...from one list of the eight filters")
    -- ⚠ A FUNCTION, not a file-scope table: a table of L[...] lookups built at
    -- load freezes on whatever locale was live then.
    check(CARDS:find("local FILTER_CHIPS = {", 1, true) == nil,
          "showing: ...which is a verb, so it cannot freeze on the load-time locale")
    check(CARDS:find("local function ActiveFilterLabel()", 1, true) ~= nil,
          "showing: the active filter's name is read off that same list")
    check(CARDS:match("local function ActiveFilterLabel%(%)(.-)\nend"):find("FilterChips()", 1, true) ~= nil,
          "showing: ...not off a second copy of the labels")

    -- ☠ THE ROW IS GONE, AND THE ABSENCE IS THE ASSERTION -- 50px of page for
    -- one filter is what section 21.3 exists to take back.
    check(ROWS:find("local showBand", 1, true) == nil,
          "showing: the band layout no longer spends a popout row on the filter")
    check(ROWS:find([==[label   = L["Showing"]]==], 1, true) == nil,
          "showing: ...nor a row caption")

    -- The panel it opens instead. Built the way the canvas's Preview Scale glyph
    -- builds its own: a POOLED CreatePopout, Follow'd to the button.
    local POP = CARDS:match("local function OpenFilterPopout%(btn%)(.-)\nend\nP%.OpenFilterPopout")
    check(POP ~= nil, "showing: the filter panel's opener can be read")
    POP = POP or ""
    check(POP:find("GUI:CreatePopout({", 1, true) ~= nil,
          "showing: it is a popout, built from the shared factory")
    check(POP:find("key   = FILTER_POPOUT_KEY", 1, true) ~= nil,
          "showing: ...keyed once, so the panel is pooled rather than rebuilt")
    check(POP:find("S.BuildFilterChips(pane, width)", 1, true) ~= nil,
          "showing: ...and it holds the same eight chips, at the popout's own width")
    check(POP:find([[pop:Follow(btn, { outsideOf = DF.GUIFrame })]], 1, true) ~= nil,
          "showing: ...docked outside the settings window, like every other panel")
    -- A second click on the glyph shuts it, like any toggle.
    check(POP:find([[open:Close("api")]], 1, true) ~= nil,
          "showing: a second click on the glyph closes it")

    -- The glyph itself, on the caption, in the head area both layouts share.
    local HEADSRC = CARDS:match("if filterGlyph then(.-)\n    end\n    yPos = yPos %- 16")
    check(HEADSRC ~= nil, "showing: the glyph's arm can be read")
    HEADSRC = HEADSRC or ""
    check(HEADSRC:find("GUI:CreateGlyphButton(parent, {", 1, true) ~= nil,
          "showing: the way in is a glyph, from the shared factory")
    check(HEADSRC:find("onClick = OpenFilterPopout", 1, true) ~= nil,
          "showing: ...which opens that panel")
    check(HEADSRC:find([[glyph:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, yPos + 4)]], 1, true) ~= nil,
          "showing: ...right-aligned on the ACTIVE INDICATORS caption")
    -- ☠ filter_list, NOT filter_alt. The funnel is a different icon and the one
    -- asked for is the three tapering lines.
    check(CARDS:find([[local FILTER_ICON = "Interface\\AddOns\\DandersFrames\\Media\\Icons\\filter_list"]], 1, true) ~= nil,
          "showing: the icon is filter_list, double-backslashed")
    check(CARDS:find("Icons\\\\filter_alt", 1, true) == nil,
          "showing: ...not the funnel")

    -- ☠ A FILTER THAT LOOKS THE SAME ON AND OFF IS HOW PEOPLE LOSE THEIR WORK.
    -- Showing only Borders hides seven kinds of indicator, so the active state is
    -- said TWICE -- accent tint AND the filter's own name beside the glyph.
    check(HEADSRC:find([[local active = (S.activeFilter or "all") ~= "all"]], 1, true) ~= nil,
          "showing: the glyph knows whether a filter is in force")
    check(HEADSRC:find("color   = active and tc or C_TEXT_DIM", 1, true) ~= nil,
          "showing: ...accents itself when it is")
    check(HEADSRC:find("name:SetText(ActiveFilterLabel())", 1, true) ~= nil,
          "showing: ...and writes the filter's name beside itself, which a glance can read")
    check(HEADSRC:find([[name:SetPoint("RIGHT", glyph, "LEFT", -4, 0)]], 1, true) ~= nil,
          "showing: ...on the same line, chained off the glyph")

    -- ☠ THE PANEL IS DOCKED TO A BUTTON THE NEXT REBUILD RETIRES. Picking a chip
    -- rewrites the list, which rebuilds the page; a panel left up would be
    -- following a frame that is no longer on screen.
    check(HEADSRC:find([[glyph:HookScript("OnHide", function()]], 1, true) ~= nil,
          "showing: the panel goes when the glyph it is docked to does")
    check(HEADSRC:find([[pop:Close("source")]], 1, true) ~= nil,
          "showing: ...closed as a source close, not as a user one")

    -- Opt-in, so the split panel keeps its chips and gets no glyph.
    check(CARDS:find("local filterGlyph = opts and opts.filterGlyph or false", 1, true) ~= nil,
          "showing: the glyph is opt-in")
    check(EDIT:find("filterGlyph", 1, true) == nil,
          "showing: ...and the split panel does not ask for it")

    -- ⚠ AND IT GREYS WITH THE REST OF THE PAGE. The row it replaces carried a
    -- disableOn; a glyph that stayed lit would be the one live control on a page
    -- of dead ones. SetGlyphEnabled is the kit's all-three-halves call.
    check(ROWS:find("filterGlyphEnabled = ctx.adEnabled", 1, true) ~= nil,
          "showing: the page tells the glyph whether the designer is on")
    check(HEADSRC:find("if opts and opts.filterGlyphEnabled == false then", 1, true) ~= nil,
          "showing: ...and the glyph reads it")
    check(HEADSRC:find("glyph:SetGlyphEnabled(false)", 1, true) ~= nil,
          "showing: ...greying through the kit's own verb, not a bare SetAlpha")
    check(HEADSRC:find("if name then name:SetAlpha(0.4) end", 1, true) ~= nil,
          "showing: ...and the filter's name beside it goes with it")

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

    -- The order the approved sketch draws: add, then the list under its caption.
    local addAt  = ROWS:find("local addBand = GUI:CreateSettingsGroup", 1, true)
    local headAt = ROWS:find("GUI:AddDesignerLegacyTab(shell, function(host)", 1, true)
    check(addAt and headAt and addAt < headAt,
          "showing: + Add Indicator, then ACTIVE INDICATORS and its filter")

    local EN = df_file_source("Locales/enUS.lua")
    check(EN:find("L[\"Showing\"] = true", 1, true) ~= nil,
          "showing: the panel's title is in the source locale")
    check(EN:find("L[\"Showing: %s\"] = true", 1, true) ~= nil,
          "showing: ...and so is what the glyph's tooltip reports")
    check(EN:find("L[\"Which kinds of indicator are listed below.\"] = true", 1, true) ~= nil,
          "showing: ...and what an icon-only button has to say for itself")
end
-- ============================================================
-- 12. THE WIDE-PAGE FLOOR IS GONE -- THE ACCEPTANCE TEST FOR THE WHOLE REWORK
-- Both designers were 50/50 split panels that forced a 640-wide window to 850 and
-- would not let it back down. That floor is what the conversion was FOR, so its
-- removal is the one assertion that says the rework achieved its purpose rather
-- than merely rearranging itself.
-- ============================================================
print("-- Aura Designer: the wide-page floor is gone")
do
    local PANEL = options_file_source("GUI/Panel.lua")
    -- ⚠ THE TABLE'S BODY, NOT THE FILE. Both page ids also appear in the
    -- slash-command alias map (Panel.lua:977, :998), so a file-wide find answers
    -- "is this string anywhere" and never "is this page still a wide page".
    local WIDE = PANEL:match("local WIDE_PAGES = {(.-)}")
    check(WIDE ~= nil, "wide: the WIDE_PAGES table can be found")
    check(WIDE:find("auras_auradesigner", 1, true) == nil,
          "wide: the Aura Designer no longer forces the window to 850")
    check(WIDE:find("text_designer", 1, true) == nil,
          "wide: ...and neither does the Text Designer")
    -- ⚠ The ones that are still islands must NOT have been swept out with them.
    check(WIDE:find("auras_filterdesigner", 1, true) ~= nil,
          "wide: the Filter Designer keeps its floor -- it is still a two-column list")
    check(WIDE:find("general_pinnedframes", 1, true) ~= nil,
          "wide: ...as does Pinned Frames")
    check(WIDE:find("general_nicknames", 1, true) ~= nil,
          "wide: ...and Nicknames")
end

-- ============================================================
-- 13. THE NARROW WINDOW -- WHAT 850px WAS HIDING
-- ------------------------------------------------------------
-- Section 12 removed the floor, so this page now renders in the 640px default
-- window it always claimed it could: a band of roughly 410px, and as little as
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

    -- ---- class one: the shell's re-report verb -------------------------
    -- The idiom is the canvas band's own (shell.SetCanvasHeight): set
    -- layoutHeight, set the height, re-run the page's layout pass.
    check(SHELL:find("host.dfSetHeight = function", 1, true) ~= nil,
          "narrow: a legacy tab's band host carries a re-report verb")
    local verb = SHELL:match("host%.dfSetHeight = function%(h%)(.-)\n    end")
    check(verb ~= nil, "narrow: ...and its body can be read")
    verb = verb or ""
    check(verb:find("host.layoutHeight = h", 1, true) ~= nil,
          "narrow: ...which sets layoutHeight, the number the layout pass reads")
    check(verb:find("RefreshStates", 1, true) ~= nil,
          "narrow: ...and re-runs the page's layout pass")
    check(verb:find("if host.layoutHeight == h then return end", 1, true) ~= nil,
          "narrow: ...and early-outs when nothing moved, so a re-flow cannot loop")

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
    -- The verb it fed is still there for the band host that still needs one; only
    -- this consumer went.
    check(SHELL:find("host.dfSetHeight = function", 1, true) ~= nil,
          "narrow: the shell keeps the verb for any flowing block that still needs it")

    -- The band layout builds no chips ON THE PAGE at all, so it has nothing to
    -- compensate for; its copy flows inside a panel, against a width that is
    -- known before the first chip is placed.
    check(HEAD:find("if not skipChips then", 1, true) ~= nil,
          "narrow: the chips are the split panel's alone")
    check(CARDS:find("S.BuildFilterChips(pane, width)", 1, true) ~= nil,
          "narrow: ...and the band layout's flow against a width known before it starts")

    -- The split panel still re-flows on resize; what it no longer does is try to
    -- move bands it does not have.
    local reflow = HEAD:match('chipsFrame:SetScript%("OnSizeChanged", function%(_, w%)(.-)end%)')
    check(reflow ~= nil, "narrow: the chip row still re-flows on resize")
    check((reflow or ""):find("Relayout(w)", 1, true) ~= nil,
          "narrow: ...at the width the resize reports")
    check(HEAD:find([[obHint:SetPoint("TOPLEFT", chipsFrame, "BOTTOMLEFT"]], 1, true) ~= nil,
          "narrow: what follows the chips is anchored TO them, so a re-wrap carries it")

    -- ---- class one: the choice cards ------------------------------------
    -- A card's description WRAPS inside a fixed 58px card. Two lines at 850,
    -- three in a 640px window -- out through the bottom and into the card below.
    check(SW:find("if opts.width and opts.width > 40 then group:SetWidth(opts.width) end", 1, true) ~= nil,
          "narrow: a choice-card block takes an explicit width when its caller knows one")
    check(SW:find("cardH = math.max(cardH, 12 + (title:GetStringHeight() or 0) + 3", 1, true) ~= nil,
          "narrow: ...and a card grows to the height its wrapped description took")
    check(SW:find("card.layoutHeight = cardH", 1, true) ~= nil,
          "narrow: ...reporting THAT height, not the constant, to whatever stacks it")
    check(SW:find("card.layoutHeight = CHOICE_CARD_H", 1, true) == nil,
          "narrow: ...and the constant is no longer what a caller advances by")
    -- (X) THE TWO SITES SPELL IT DIFFERENTLY, AND THE TEST HAS TO. The add
    -- block's table is aligned ("width    = COL_W") and the picker arm's card is
    -- not ("width = COL_W"), so a search for the shorter string is satisfied by
    -- the card and says nothing at all about the block. My first version passed
    -- with the block's width deleted.
    check(HEAD:find("width    = COL_W,", 1, true) ~= nil,
          "narrow: the Effects tab's add block passes that width down")
    check(HEAD:find("width = COL_W,", 1, true) ~= nil,
          "narrow: ...and so does the picker arm's own card list")
    check(EDIT:find("width    = COL_W", 1, true) ~= nil,
          "narrow: ...and so do the two Layout Groups blocks")

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
    check(ROWS:find("section:SetHeaderRightInset(badgeShown and 96 or (delBtn and 56 or 30))", 1, true) ~= nil,
          "narrow: an effect's header declares its eye, delete and warning badge")
    check(ROWS:find("section:SetHeaderRightInset(spec.showEye and 56 or 30)", 1, true) ~= nil,
          "narrow: ...and a layout group's declares its own")

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
    check(ROWS:find('label  = L["Add Indicator"],', 1, true) ~= nil,
          "add: ...behind one row on the page")
    check(ROWS:find("build  = addMount,", 1, true) ~= nil,
          "add: ...whose panel is that builder")
    -- """ + SK + """ NO TICK AND NO FOOTER. The row holds no settings -- it is a verb --
    -- and a footer that quietly wrote nothing is the failure phase 0 was blocked
    -- on. Same rule the Members and Linked Filters rows follow.
    local addBlock = ROWS:match("local addBand = GUI:CreateSettingsGroup(.-)Add%(addBand, nil, \"both\"%)")
    check(addBlock ~= nil, "add: ...and that row's construction can be read")
    addBlock = addBlock or ""
    check(addBlock:find("WireModifiedTick", 1, true) == nil,
          "add: the add row takes no modified tick -- it holds no settings")
    check(addBlock:find("WireFooter", 1, true) == nil,
          "add: ...and no footer, so nothing offers to reset what it does not own")
    check(addBlock:find("if not ctx.adEnabled then addRow.disableOn", 1, true) ~= nil,
          "add: ...but it greys with the designer, like every other row here")

    -- """ + SK + """ SPELL FIRST. The old order was scope, then type, then spell; the panel
    -- asks for the spell first and the scope cards are its SECOND step.
    local pane = CARDS:match("S%.BuildAddIndicatorPane = function%(host, opts%)(.-)\nend\n")
    check(pane ~= nil, "add: the panel builder's body can be read")
    pane = pane or ""
    -- The bare call appears three times -- both back routes reach it -- so this
    -- names the builder's LAST statement, which is the one that decides which step
    -- the panel opens on.
    check(pane:find('Show("spell")\n    return { Show = Show }', 1, true) ~= nil,
          "add: the panel opens on the spell step")
    local spellAt = pane:find("local spellPane = NewPane()", 1, true)
    local scopeAt = pane:find("local scopePane = NewPane()", 1, true)
    local typeAt  = pane:find("local typePanes = {}", 1, true)
    check(spellAt and scopeAt and typeAt and spellAt < scopeAt and scopeAt < typeAt,
          "add: ...then the scope cards, then the types -- spell, scope, type")
    check(pane:find('Crumb(scopePane, "spell")', 1, true) ~= nil,
          "add: the scope step can go back to the spell it was given")

    -- """ + WA + """ THE FILTER SCOPE IS NOT SPELL-FIRST AND DOES NOT PRETEND TO BE. It hangs
    -- the effect off a whole filter, so it is offered on step ONE and skips the
    -- scope step entirely -- including on the way back out.
    check(pane:find('onClick = function() Show("type:filter") end', 1, true) ~= nil,
          "add: the filter route is offered on the FIRST step")
    check(pane:find('Crumb(pane, (key == "filter") and "spell" or "scope")', 1, true) ~= nil,
          "add: ...and its back button skips the scope step it never took")

    -- """ + SK + """ THE STEPS ARE BUILT ONCE AND SHOWN OR HIDDEN. Frames cannot be
    -- garbage-collected in this client and a pane's contents are built once, so a
    -- step that re-drew itself would leak a card set per click.
    check(pane:find("for _, p in pairs(panes) do p:Hide() end", 1, true) ~= nil,
          "add: changing step hides the others rather than rebuilding them")
    -- ☠ ...AND THE FOURTEEN TYPE CARDS ARE THE ONE THING NOT BUILT EAGERLY.
    -- A pane's contents are constructed on EVERY page build -- a tab switch, a
    -- pool switch, a preset switch, an add -- and frames cannot be
    -- garbage-collected here, so fourteen cards for a step most rebuilds never
    -- reach is fourteen frames retained per rebuild. MEMOISED, not merely lazy:
    -- at most three exist per panel, so it cannot leak per click either.
    check(pane:find("local function TypePane(key)", 1, true) ~= nil,
          "add: the type cards are built on demand")
    check(pane:find("if typePanes[key] then return typePanes[key] end", 1, true) ~= nil,
          "add: ...and kept, so a second visit builds nothing")
    check(pane:find("if scopeKey then TypePane(scopeKey) end", 1, true) ~= nil,
          "add: ...built by the step change that asks for them")
    check(pane:find("if opts.SetHeight then opts.SetHeight(h) end", 1, true) ~= nil,
          "add: ...and reports the new height instead of assuming one")
    check(ROWS:find("SetHeight = function(h) if ready then GUI:RelayoutHost(pane, h) end end", 1, true) ~= nil,
          "add: ...through the shared re-flow verb, which re-sizes pane and panel")
    -- """ + WA + """ AND IT IS SILENT UNTIL THE PANE HAS JOINED ITS GROUP. The builder shows
    -- its first step as it finishes; a height reported before AddWidget has run
    -- would walk past the group and re-run the PAGE's state pass mid-build.
    check(ROWS:find("ready = true", 1, true) ~= nil,
          "add: ...armed only after the pane is in the group")
    local addPaneAt  = ROWS:find("g:AddWidget(pane, max(pane:GetHeight() or 1, 1))", 1, true)
    local readyAt    = ROWS:find("ready = true", 1, true)
    check(addPaneAt and readyAt and addPaneAt < readyAt,
          "add: ...which is what makes the flag true after the add, not before")

    -- The three type lists are ONE declaration now: the panel and the split
    -- panel's block both build their cards from it.
    check(CARDS:find("local function AddFlowScopes()", 1, true) ~= nil,
          "add: the scopes and their type lists are declared once")
    check(CARDS:find("local SCOPES = AddFlowScopes()", 1, true) ~= nil,
          "add: ...and read as a verb, so the labels are not frozen on enUS")
    local scopeReads = 0
    for _ in CARDS:gmatch("AddFlowScopes%(%)") do scopeReads = scopeReads + 1 end
    eq(scopeReads, 3, "add: ...by the panel and the split panel's block, off one list")

    -- The add-by-ID path survives the reordering: the half of ADAddByID that
    -- NAMES a spell had to come out, because the flow has no type yet.
    check(CARDS:find("local function ADResolveByID(idNum, idText)", 1, true) ~= nil,
          "add: the naming half of add-by-ID is a verb of its own")
    check(CARDS:find("local auraName, display, isAdHoc, blocked = ADResolveByID(idNum, idText)", 1, true) ~= nil,
          "add: ...and ADAddByID is what is left of it")
    check(pane:find("ADResolveByID(idNum, idText)", 1, true) ~= nil,
          "add: ...so typing a spell ID still works on the spell step")

    -- """ + WA + """ SPELL-FIRST CREATES A STATE THE OLD ORDER COULD NOT REACH: a spell that
    -- already has THIS type of effect. The old picker greyed those rows because it
    -- knew the type; this one cannot, so the type card says so instead of
    -- silently doing nothing.
    check(pane:find('DF:Say(L["Already added."])', 1, true) ~= nil,
          "add: a duplicate is refused out loud on the type card")

    -- ...and the page it came off no longer draws the block at all.
    check(CARDS:find("if S.effectsPicker and not skipAdd then", 1, true) ~= nil,
          "add: the row layout never enters the split panel's picker column")
    local headBody = CARDS:match("S%.BuildEffectsHeadArea = function%(parent, yPos, opts%)(.-)\nend\n")
    check(headBody ~= nil, "add: the head area's body can be read")
    headBody = headBody or ""
    check(headBody:find("if not skipAdd then", 1, true) ~= nil,
          "add: ...and the pinned block is behind that same switch")
end

print("-- Aura Designer: Preview Scale is a glyph, not a row across the canvas")
do
    -- ---- move 2: the slider moves behind a glyph -----------------------
    check(CARDS:find("local scaleBtn = GUI:CreateGlyphButton(container, {", 1, true) ~= nil,
          "scale: the compact canvas carries a glyph, not a slider")
    check(CARDS:find('scaleBtn:SetPoint("TOPRIGHT", container, "TOPRIGHT", -6, -2)', 1, true) ~= nil,
          "scale: ...in the top-right of its own label strip")
    -- """ + SK + """ EXACTLY ONE INLINE SLIDER IN THE FILE, and it is the split panel's.
    -- If a second appears the 30px CANVAS_FURNITURE gave back is being drawn over.
    local inline = 0
    for _ in CARDS:gmatch("GUI:CreateSlider%(container,") do inline = inline + 1 end
    eq(inline, 1, "scale: the canvas builds one inline slider, in the non-compact arm")
    local compactArm = CARDS:match("local scaleBtn = GUI:CreateGlyphButton%(container,(.-)local scaleSlider = GUI:CreateSlider%(container,")
    check(compactArm ~= nil, "scale: ...and the arm before it can be read")
    compactArm = compactArm or ""
    check(compactArm:find("\n    else\n", 1, true) ~= nil,
          "scale: ...reached only when the band form did NOT take the glyph")

    -- """ + SK + """ THE PANEL IS POOLED BY KEY, so its build runs once and keeps whatever
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

print("-- Aura Designer: Template and Spec share a row")
do
    -- ---- move 3: four action buttons become one menu --------------------
    local SW = options_file_source("GUI/SettingsWidgets.lua")
    check(SW:find("if opts.overflowActions then", 1, true) ~= nil,
          "row: the preset bar can put its four actions behind one glyph")
    check(SW:find('overflowBtn:SetPoint("RIGHT", bar, "RIGHT", 0, 0)', 1, true) ~= nil,
          "row: ...which takes the right end the four used to chain from")
    check(SW:find('ddBtn:SetPoint("RIGHT", overflowBtn, "LEFT", -6, 0)', 1, true) ~= nil,
          "row: ...and the dropdown spans everything left of it")
    -- """ + SK + """ THE MENU ITEM PRESSES THE BUTTON. Four prompts, two confirmations and
    -- the Default-template guard live on those buttons; a second copy in the menu
    -- is a second place for "Delete asks first" to stop being true.
    local ov = SW:match("if opts.overflowActions then(.-)\n    end\n\n    %-%-")
    check(ov ~= nil, "row: the overflow block can be read")
    ov = ov or ""
    check(ov:find("b:GetScript(\"OnClick\")(b)", 1, true) ~= nil,
          "row: ...so an item fires the real button rather than repeating its body")
    check(ov:find("PromptPresetName", 1, true) == nil,
          "row: ...and no prompt is written a second time")
    check(ov:find("ConfirmDeletePreset", 1, true) == nil,
          "row: ...nor the delete confirmation, which is the one that must not be lost")
    check(ov:find("item.dfOff = (b and b.IsEnabled and not b:IsEnabled()) or false", 1, true) ~= nil,
          "row: ...and an item greys when its button is disabled, rather than vanishing")
    -- Still labelled and chained for every caller that did not ask.
    check(SW:find('delBtn:SetPoint("RIGHT", bar, "RIGHT", 0, 0)', 1, true) ~= nil,
          "row: a caller that asks for nothing keeps the four-button chain")

    -- ☠ AND SPEC HAS SINCE LEFT THAT ROW AGAIN. Section 20.2 puts the pool picker
    -- beside Spec, and three labelled pickers do not fit one band at the window's
    -- 520px minimum -- where the preset bar's own dropdown is already down to
    -- ~113px. So the pair moved DOWN to the band the pool strip held, and row 2
    -- is the template bar's alone: the overflow menu now buys the bar its own
    -- width back rather than buying Spec a seat.
    check(ROWS:find("S.BuildSpecPicker = function(host)", 1, true) ~= nil,
          "row: the spec picker is a block, not a strip")
    check(ROWS:find([[presetBar:SetPoint("RIGHT", banner, "RIGHT", -10, -18)]], 1, true) ~= nil,
          "row: ...and row 2 of the banner is the template bar's whole width")
    check(ROWS:find([[presetBar:SetPoint("RIGHT", specHost, "LEFT", -10, 0)]], 1, true) == nil,
          "row: ...with nothing sharing it")
    check(ROWS:find("overflowActions = true", 1, true) ~= nil,
          "row: the four actions are still behind one glyph")
    check(ROWS:find("SPECBAR_H", 1, true) == nil,
          "row: ...and the 26px spec strip is still gone")
    check(ROWS:find("S.BuildSpecStrip", 1, true) == nil,
          "row: ...along with the verb that built it")
    -- The banner no longer sizes a block it does not hold.
    check(ROWS:find("specHost:SetWidth(max(120, math.floor(w * 0.34)))", 1, true) == nil,
          "row: the banner no longer sizes a spec block")
    check(ROWS:find([[banner:HookScript("OnSizeChanged", function(_, w) SizeSpec(w) end)]], 1, true) == nil,
          "row: ...nor re-takes a share for one")
end

print("-- Aura Designer: the canvas folds, under a literal key")
do
    -- ---- move 4: the fold ----------------------------------------------
    check(SHELL:find("local fold = opts.canvasFold", 1, true) ~= nil,
          "fold: the shell can put a fold header over the canvas band")
    check(SHELL:find("if fold and fold.collapseKey then", 1, true) ~= nil,
          "fold: ...only when the caller named a stable key for it")
    check(SHELL:find("{ collapseKey = fold.collapseKey })", 1, true) ~= nil,
          "fold: ...which is what the section persists under")
    check(SHELL:find("if section then section:RegisterChild(host) end", 1, true) ~= nil,
          "fold: the canvas band is the section's one child, so the page hides it")
    check(SHELL:find("if section and not section.expanded then return end", 1, true) ~= nil,
          "fold: ...and a folded canvas is not regrown by a pinned scale slider")

    -- """ + SK + """ THE HAZARD THIS EXISTS FOR. CreateCollapsibleSection persists a fold
    -- under the section's TITLE TEXT unless told otherwise -- so a localised title
    -- writes a second profile key and a reworded one orphans the first. Section
    -- 14's correction 7 of the rework spec is the same trap, found the hard way.
    local SW = options_file_source("GUI/SettingsWidgets.lua")
    check(SW:find("local stateKey = section.collapseKey or text", 1, true) ~= nil,
          "fold: the section reads its state from the caller's key when it has one")
    check(SW:find("local persistKey = self.collapseKey or self.sectionTitleText", 1, true) ~= nil,
          "fold: ...and writes it back to the same slot, not to the title")
    check(SW:find("saved[persistKey] = (not self.expanded) or nil", 1, true) ~= nil,
          "fold: ...which is the only place the fold is stored")

    check(ROWS:find('collapseKey = "ad_canvas"', 1, true) ~= nil,
          "fold: the Aura Designer names its slot with a literal")
    check(ROWS:find("collapseKey = L[", 1, true) == nil,
          "fold: ...never with a localised string")
    local TDROWS = options_file_source("TextDesigner/UI/Rows.lua")
    check(TDROWS:find('collapseKey = "td_canvas"', 1, true) ~= nil,
          "fold: the Text Designer names its own, DIFFERENT slot")
    check(TDROWS:find('collapseKey = "ad_canvas"', 1, true) == nil,
          "fold: ...so folding one designer's preview does not fold the other's")

    -- One title, not two: the fold header says FRAME PREVIEW, so the canvas
    -- underneath it must not print the same two words six pixels lower.
    check(CARDS:find("if opts and opts.hideLabel then previewLabel:Hide() end", 1, true) ~= nil,
          "fold: a canvas under a fold header drops its own duplicate caption")
    check(ROWS:find("hideLabel = true", 1, true) ~= nil,
          "fold: ...which the Aura Designer asks for")
    check(TDROWS:find("hideLabel = true", 1, true) ~= nil,
          "fold: ...and so does the Text Designer")
end

print("-- Aura Designer: what the chrome now costs, band by band")
do
    -- ☠ THE POINT OF THE WHOLE DIET, AS A NUMBER. Every figure is READ OUT OF
    -- THE SOURCE rather than restated here, so this fails if a band grows back --
    -- restating them would only test that this file agrees with itself.
    local banner  = tonumber(ROWS:match("banner, (%d+)\n"))
                 or tonumber(ROWS:match("return banner, (%d+)"))
    local scope    = tonumber(ROWS:match("local SCOPEROW_H = (%d+)"))
    local pool     = tonumber(ROWS:match("local BUFFTAB_H = (%d+)"))
    local pooltabs = tonumber(ROWS:match("local POOLTABS_H = (%d+)"))
    local tabbar  = tonumber(SHELL:match("local TABBAR_H = (%d+)"))
    local F, PAD, DY = CARDS:match("local CANVAS_FURNITURE, CANVAS_PAD, CANVAS_DY = (%d+), (%d+), (%d+)")
    F, PAD, DY = tonumber(F), tonumber(PAD), tonumber(DY)
    local foldHeader = tonumber(SHELL:match("Add%(section, (%d+), \"both\"%)"))
    check(banner and scope and pool and pooltabs and tabbar and F and PAD and DY and foldHeader,
          "chrome: every band's height can be read from the source")

    -- The canvas at the scale the complaint was measured at.
    local fh, scale = 64, 1.5
    local canvas = math.max(132, math.ceil(math.max(2 * F - 2 * DY + fh * scale,
                                                    2 * PAD + 2 * DY + fh * scale)))
    -- A popout row is one plate plus its gap -- the kit's own constants. There is
    -- ONE of them above the list now: Add Indicator. The filter's row became a
    -- glyph on a caption the page was already paying for.
    local THEME = ui_file_source("Theme.lua")
    local plate = tonumber(THEME:match("plate%s*= (%d+)"))
    local gap   = tonumber(THEME:match("gap%s*= (%d+)"))
    check(plate and gap, "chrome: ...including what a popout row costs")
    local popoutRow = plate + gap

    -- ☠ AND THE BAND SECTION 19 NEVER COUNTED. The ACTIVE INDICATORS caption
    -- sits between the last row and the first indicator and was left out of every
    -- earlier sum. It is the caption and nothing else -- the glyph rides inside
    -- the 16px the caption already spends: the caller starts its y cursor at -4,
    -- the caption costs 16, and the band is -(y) + 4.
    local startY  = tonumber(ROWS:match("S%.BuildEffectsHeadArea%(host, %-(%d+),"))
    -- ⚠ SCOPED TO THE CAPTION'S OWN LINES, not the file and not to a comment.
    -- "ACTIVE INDICATORS heading" also appears in a section header 700 lines
    -- earlier, so a match anchored on THAT spans a region with no yPos in it at
    -- all -- which is how the first version of this came back nil.
    local headBlock = CARDS:match("activeHeader:SetTextColor(.-)local chipsFrame")
    local caption = headBlock and tonumber(headBlock:match("yPos = yPos %- (%d+)"))
    check(startY and caption, "chrome: ...and what the caption band costs")
    local head = (startY or 0) + (caption or 0) + 4

    local open   = banner + pooltabs + foldHeader + canvas + scope + tabbar + popoutRow + head
    local folded = banner + pooltabs + foldHeader + scope + tabbar + popoutRow + head

    -- Was 542 at the start of the diet (banner 68, canvas 160, pool 30, spec 26,
    -- tabs 28, add block 230), on a basis that counted neither the caption band
    -- nor a filter row, and 406 counted honestly at the end of section 20.
    -- On THIS basis: 68 + 30 + 28 + 132 + 26 + 28 + 50 + 24.
    check(open <= 386,
          "chrome: the page above the first indicator is under 386px with the canvas open")
    check(folded <= 254,
          "chrome: ...and under 254px with it folded")
    check(canvas <= 132,
          "chrome: the canvas at 1.5x is back to its 132px floor")

    -- ☠ THE POOL STRIP CAME BACK, AND IT IS PAID FOR OUT OF THE FILTER ROW.
    -- Section 21 predicted -46 by also folding the scope row away; Spec did not
    -- fit beside Template at the window's 520px minimum, so that band stays and
    -- the real figure is -20 (406 -> 386). The two halves that DID land:
    --   + the pool strip returns, at exactly what it costs in the split panel
    --   - the Showing row goes, at a whole plate and gap
    check(pooltabs == pool,
          "chrome: the band layout's pool strip costs what the split panel's does")
    check(popoutRow > pooltabs - scope,
          "chrome: ...and the filter row it traded away was the larger of the two")

    -- ⚠ ON SECTION 19'S OWN BASIS -- which stopped at the add row and counted a
    -- pool strip but no spec strip -- the page GREW, from 332 to 362, because Spec
    -- kept a band of its own. Asserted rather than quietly dropped: that basis is
    -- the one every figure before section 20 was quoted on, and the number it now
    -- gives is 362.
    check(banner + pooltabs + foldHeader + canvas + scope + tabbar + popoutRow <= 362,
          "chrome: on section 19's own basis the page is 362px")
    check(banner + pooltabs + foldHeader + scope + tabbar + popoutRow <= 230,
          "chrome: ...folded, 230px")
end
