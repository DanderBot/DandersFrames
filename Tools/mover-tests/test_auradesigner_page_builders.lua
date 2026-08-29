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

    check(ROWS:find("S.BuildEffectsHeadArea(host, -4)", 1, true) ~= nil,
          "head: the Effects add block and chips are the card layout's own")
    check(CARDS:find("S.BuildEffectsHeadArea = function(parent, yPos)", 1, true) ~= nil,
          "head: ...declared once, in the card file")
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
    check(ROWS:find("S.framePreview = CreateFramePreview(host, 0, nil, { compact = true })", 1, true) ~= nil,
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
    check(CARDS:find("function P.CanvasWantedHeight(compact)", 1, true) ~= nil,
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
-- 11. THE POOL STRIP IS ONE DEFINITION, TWO HOSTS
-- ============================================================
print("-- Aura Designer: the pool strip")
do
    check(ROWS:find("S.BuildPoolStrip = function(buffTabBar)", 1, true) ~= nil,
          "strip: the pool strip is declared once")
    check(EDIT:find("S.BuildPoolStrip(buffTabBar)", 1, true) ~= nil,
          "strip: ...and the split panel mounts it into its own slice")
    check(ROWS:find("build = function(host) S.BuildPoolStrip(host) end", 1, true) ~= nil,
          "strip: ...while the row page mounts it as a band")
    -- Decision 5: its own strip, above the sub-tabs -- which set is being edited
    -- is a prior question to which part of it you are looking at.
    local stripAt = ROWS:find("strips = {", 1, true)
    local tabsAt  = ROWS:find("tabs = {", 1, true)
    check(stripAt ~= nil and tabsAt ~= nil and stripAt < tabsAt,
          "strip: the pool strip sits above the tab strip")
end

-- ============================================================
-- 12. WIDE_PAGES IS NOT TOUCHED YET
-- Phase 6 drops the floor, and it must not land before Layout Groups, Global and
-- the Text Designer convert -- or the window shrinks around a layout that still
-- needs the width.
-- ============================================================
print("-- Aura Designer: the wide-page floor stands until phase 6")
do
    local PANEL = options_file_source("GUI/Panel.lua")
    check(PANEL:find("auras_auradesigner   = true", 1, true) ~= nil,
          "wide: the Aura Designer is still a wide page")
    check(PANEL:find("text_designer", 1, true) ~= nil,
          "wide: ...and so is the Text Designer")
end
