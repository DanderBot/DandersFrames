local NS = ...

-- ============================================================
-- SETTINGS PAGE BUILDERS -- DandersFrames_Options/GUI/Pages/Options.lua
-- ------------------------------------------------------------
-- General > Settings is the sweep's sixth page. Five of its seven groups become
-- popout feature rows -- Frame Modes, Blizzard Frames, Rendering, Settings Panel
-- Appearance, Notifications -- and the two single-control groups (Minimap,
-- Language) stay inline wearing the band skin, because a pane holding one
-- checkbox is a click that buys nothing. The info banner at the top is untouched.
--
-- ☠ THE PAGE CANNOT BE BUILT HEADLESSLY. It is welded to the panel -- a real
-- ScrollFrame, a real settings group, GUI.SelectedMode, DF.db -- so this file
-- does what the five page-builder suites before it do: it reads the page's
-- SOURCE and asserts against it.
--
-- ☠☠ AND THIS PAGE'S RULE IS THE HARDEST ONE ON THE SWEEP, which is most of why
-- it has a test. NOT ONE ROW HERE CARRIES A MODIFIED TICK OR A RESET STRIP.
-- DF.Defaults answers for DF.db.party / DF.db.raid / the stored raid baseline and
-- nothing else, and this page owns no plain per-mode profile key: the mode
-- enables and the two settings-font keys are at the DF.db ROOT, the Blizzard /
-- minimap / pixel-perfect toggles are read party-canonical and written to BOTH
-- mode tables by one setter, the update rate and the notification ticks are
-- account-wide, the language override is per-character, and the classic-layout
-- flag has no db table at all. So every row is a WAY IN: ClaimKeys for the search
-- jump, and neither WireModifiedTick nor WireFooter.
--
-- On Integrations and Global Fonts that footer would merely have been INERT.
-- Here it would be DESTRUCTIVE -- Reset Group writes ONE mode's table, which is
-- exactly the desync makeBlizSet exists to prevent, and two of these groups need
-- a UI reload to take effect. Section 7 is there so a later sweep "completing"
-- these rows breaks a test instead of a user's frames.
--
-- What that buys, and what it does not:
--   ✓ the widget CENSUS of each extracted builder -- kind, L key, qualified db
--     key and slot height, in order -- taken from the PRE-CHANGE source, so a
--     builder that quietly dropped a control or renamed a key fails here. This is
--     also the evidence that CLASSIC RENDERS AS IT DID: the classic branch mounts
--     the same builder into the same 280 box in the same column.
--   ✓ that ONE builder serves both layouts.
--   ✓ that the declared row COUNT matches what the pane mounts.
--   ✓ the classic-layout ESCAPE HATCH's decision (section 6): the rebuild stays
--     synchronous, and the panels come down first.
--   ✗ nothing about runtime behaviour -- the callbacks, the greying and the
--     summaries are read by eye and by the in-game checklist.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Options.lua")

-- ---- the census reader (the Global Fonts page's, with two kinds added) ----
--
-- ⚠ CreateSeparator AND CreateInfoBanner ARE IN THE MAP. A chunk runs to the
-- start of the next KNOWN call, so an unknown factory is invisible rather than
-- merely unnamed -- and the divider between the third and fourth Blizzard ticks
-- is a real widget in the group's roster (the count badge counts it), so a reader
-- that skipped it would fold two of that group's five controls into one census
-- row and quietly agree with a wrong count.
local KIND = {
    CreateCheckbox = "checkbox", CreateSlider = "slider",
    CreateDropdown = "dropdown", CreateColorPicker = "colorpicker",
    CreateHeader = "header", CreateLabel = "label",
    CreateFontDropdown = "fontdropdown", CreateOutlineDropdown = "outlinedropdown",
    CreateShadowCheckbox = "shadowcheckbox", CreateNote = "note",
    CreateSeparator = "separator", CreateInfoBanner = "banner",
}

-- The body of a `local function <name>(tools2)` at the page builder's own indent.
-- Terminated on a newline + EIGHT spaces + `end`, which is that indent:
-- everything inside one of these bodies is indented further -- the Rendering
-- builder's `do ... end` block for the scale hint included, which is why its
-- close at twelve spaces cannot end this search early.
local function builderBody(name)
    local head = "local function " .. name .. "(tools2)"
    local a = SRC:find(head, 1, true)
    check(a ~= nil, "source: the page declares " .. name)
    if not a then return "" end
    local b = SRC:find("\n        end\n", a, true)
    check(b ~= nil and b > a, "source: ..." .. name .. " closes at the page builder's indent")
    return SRC:sub(a, b or a)
end

-- ⚠ THE KEY COLUMN IS QUALIFIED -- "<table>.<key>", not the bare key -- for the
-- reason the Global Fonts reader introduced it and this page makes unavoidable:
-- these controls bind to FIVE different stores (DF.db, DF.db.party,
-- DF:GetGlobalDB(), DandersFramesCharDB, and nothing at all), and WHICH table a
-- control writes is the entire argument of section 7. A reader printing only the
-- key would call two of them "notifyOutdated" and "partyEnabled" and say nothing
-- about where either lives.
--
-- ⚠ THE SECOND PATTERN IS NOT BELT-AND-BRACES. `DF:GetGlobalDB(), "key"` puts a
-- `)` immediately before the comma, and a table name is word characters and dots
-- -- so the first pattern cannot see the account-wide binding at all. Spelled as
-- its own literal rather than by widening the character class, because widening
-- it to include brackets makes `makeBlizSet("k"), "k"` match with a table name of
-- ")".
--
-- A control the reader cannot bind -- the custom get/set checkboxes, which pass
-- `nil, nil` and name their key at the END of the argument list -- comes back as
-- "(none)" and has its overrideKey pinned by source pattern in its own section.
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
        local tbl, k = chunk:match('([%w_%.]+)%s*,%s*"([%w_]+)"')
        if not tbl then
            tbl, k = chunk:match('(DF:GetGlobalDB%(%))%s*,%s*"([%w_]+)"')
        end
        local h = tonumber(chunk:match('%)%s*,%s*(%d+)%s*%)'))
        out[#out + 1] = { kind = at.kind, label = label,
                          key = (tbl and (tbl .. "." .. k)) or "(none)", height = h }
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
            check(false, string.format("%s: row %d unexpected (%s %s)", tag, i, g.kind, g.label))
        else
            eq(g.kind,   e[1], string.format("%s: row %d kind", tag, i))
            eq(g.label,  e[2], string.format("%s: row %d label", tag, i))
            eq(g.key,    e[3], string.format("%s: row %d db key", tag, i))
            eq(g.height, e[4], string.format("%s: row %d slot height", tag, i))
        end
    end
end

-- The Settings page, scoped by its own two ends: Pages/Options.lua holds a dozen
-- pages, and a bare 280 box (or a `local classicLayout`) on the Frame page below
-- is not this pass's business. Everything about THIS page reads PAGE rather than
-- SRC for exactly that reason.
local PAGE
do
    local a = SRC:find('local pageGeneral = CreateSubTab("general", "general_settings"', 1, true)
    local b = SRC:find("    -- General > Frame", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Settings page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

-- The block a row is declared in, from its label to the closing brace of the
-- CreatePopoutRow opts.
local function rowOpts(labelKey)
    local a = PAGE:find('label%s*=%s*L%["' .. labelKey .. '"%]')
    check(a ~= nil, "source: a popout row is declared for " .. labelKey)
    if not a then return "" end
    local b = PAGE:find("}))", a, true)
    return PAGE:sub(a, (b or a) + 2)
end

-- What every converted group on this page has in common.
local function checkShared(builder, rowLabel)
    -- ONE builder, BOTH layouts: the declaration and the two mounts.
    local calls = 0
    for _ in PAGE:gmatch(builder .. "%(") do calls = calls + 1 end
    eq(calls, 3, rowLabel .. ": declared once, mounted twice -- classic box and popout pane")

    -- The classic branch builds the box it always did, with its own header.
    local box = PAGE:match("local (%w+) = GUI:CreateSettingsGroup%(self%.child, 280%)\n%s*%1:AddWidget%(GUI:CreateHeader%(self%.child, L%[\"" .. rowLabel:gsub("%p", "%%%0") .. "\"%]%)")
    check(box ~= nil, rowLabel .. ": the classic 280 box is built with its own header")

    local opts = rowOpts(rowLabel)
    check(opts ~= "" and opts:find("build", 1, true) ~= nil,
          rowLabel .. ": the row is handed a pre-built mount")
    check(opts:find("window  = DF.GUIFrame", 1, true) ~= nil,
          rowLabel .. ": ...docked outside the settings window")
    check(opts:find("clipTo", 1, true) ~= nil,
          rowLabel .. ": ...and clipped by the page's own scroll frame, not the window")
    -- ☠ AND ITS db IS NAMED, NOT tools.RowDB. Every row on the five pages before
    -- this one reads the per-mode table because that is where its keys live; not
    -- one key on this page does, so each row names its own store instead.
    check(opts:find("db      = function()", 1, true) ~= nil,
          rowLabel .. ": ...reading the table its own keys actually live in")
    -- ⚠ THE CALL SHAPE, not the bare name: the row site's own comment says the
    -- words "NOT tools.RowDB", and a plain search would read the explanation as
    -- the thing it is explaining away.
    check(opts:find("= tools.RowDB", 1, true) == nil,
          rowLabel .. ": ...never the per-mode resolver, which holds none of them")
end

-- ============================================================
-- 1. THE PAGE TAKES THE SHARED MACHINERY
-- Same contract the four pages before it signed: the verbs come off
-- GUI:CreatePopoutPageTools rather than out of a sixth copy on the page.
-- ⚠ The Frame page, further down this SAME FILE, still compiles its own copy --
-- that is test_popout_page_tools' claim, and it scopes itself to that page for
-- exactly the reason this suite scopes itself to this one.
-- ============================================================
print("-- Settings page: the shared popout machinery, not a sixth copy of it")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = GUI:CreatePopoutPageTools(self)", 1, true) ~= nil,
          "tools: ...and takes the shared machinery unconditionally")

    for _, v in ipairs({ "PopoutContent", "ReflowPane", "ReflowMounted", "ClaimKeys",
                         "WireModifiedTick", "WireFooter", "RegisterHoistedToggle",
                         "RefreshAfterGroupWrite", "HoldReason", "RowDB" }) do
        check(PAGE:find("local function " .. v .. "(", 1, true) == nil,
              "tools: the page does not re-declare " .. v)
    end
    check(PAGE:find("_popoutHolders", 1, true) == nil,
          "tools: the page never manages the popout holders itself")
    check(PAGE:find("_popoutRowForKey", 1, true) == nil,
          "tools: ...nor the search row map")

    -- ⚠ tools.RowDB IS NEVER USED ON THIS PAGE, and that is the same fact as the
    -- header essay: it resolves DF.db[GUI.SelectedMode], and no row here reads a
    -- per-mode table.
    -- ⚠ BOUND SHAPES, not the bare name: two comments on the page say the words
    -- "tools.RowDB" while explaining why it is absent.
    check(PAGE:find("= tools.RowDB", 1, true) == nil,
          "tools: the per-mode resolver is never handed to a row")
    check(PAGE:find("tools.RowDB()", 1, true) == nil,
          "tools: ...nor called for a table -- this page owns no per-mode key")

    -- ---- the page-scope locals both layouts share --------------------
    -- The two write-both setters, the two reload prompts and the pixel-perfect
    -- refresh stay OUTSIDE the builders: the classic box and every pane instance
    -- have to drive the same work, and none of them closes over anything
    -- group-specific.
    local firstBuilder = PAGE:find("local function BuildFrameModesGroup(tools2)", 1, true)
    check(firstBuilder ~= nil, "helpers: the first builder is locatable")
    for _, v in ipairs({ "makeBlizGet", "makeBlizSet",
                         "PromptReloadAfterModeToggle", "PromptReloadBlizzard" }) do
        local at = PAGE:find("local function " .. v .. "(", 1, true)
        check(at ~= nil and firstBuilder ~= nil and at < firstBuilder,
              "helpers: " .. v .. " is a page-scope local, ahead of the builders")
    end
    local ppAt = PAGE:find("local function refreshPixelPerfect()", 1, true)
    local renderAt = PAGE:find("local function BuildRenderingGroup(tools2)", 1, true)
    check(ppAt ~= nil and renderAt ~= nil and ppAt < renderAt,
          "helpers: refreshPixelPerfect is a page-scope local, ahead of the Rendering builder")

    -- ...and the write-both contract itself, which is half of why this page has
    -- no reset strip. One read (party), two writes.
    check(PAGE:find("return function() return DF.db.party and DF.db.party[key] end", 1, true) ~= nil,
          "helpers: makeBlizGet still reads the party copy, canonically")
    check(PAGE:find("if DF.db.party then DF.db.party[key] = val end", 1, true) ~= nil,
          "helpers: makeBlizSet still writes party...")
    check(PAGE:find("if DF.db.raid  then DF.db.raid[key]  = val end", 1, true) ~= nil,
          "helpers: ...and raid, in the same call")
end

-- ============================================================
-- 2. FRAME MODES -- two ticks and an explainer, on the profile ROOT
-- ============================================================
local FRAME_MODES = {
    { "checkbox", "Enable Party Frames", "DF.db.partyEnabled", 30 },
    { "checkbox", "Enable Raid Frames",  "DF.db.raidEnabled",  30 },
    { "label", "Completely enable or disable the Party or Raid frame system. Disabled modes are never created, consuming zero performance in the background. Requires a UI reload to apply.", "(none)", 80 },
}

print("-- Settings page: Frame Modes")
do
    local body = builderBody("BuildFrameModesGroup")
    checkCensus(census(body), FRAME_MODES, "frame modes")
    checkShared("BuildFrameModesGroup", "Frame Modes")

    -- The two callbacks are the reload prompt and nothing else -- the popup is
    -- the whole point of these ticks, and this pass is not allowed to touch it.
    check(body:find('function() PromptReloadAfterModeToggle("party") end', 1, true) ~= nil,
          "frame modes: the party tick still raises the contextual reload prompt")
    check(body:find('function() PromptReloadAfterModeToggle("raid") end', 1, true) ~= nil,
          "frame modes: ...and so does the raid tick")

    local declared = tonumber(PAGE:match("local FRAME_MODES_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "frame modes: the page declares the row's count in one place")
    eq(declared, #FRAME_MODES, "frame modes: ...the whole census, because nothing is hoisted")

    local opts = rowOpts("Frame Modes")
    -- ⚠ NO TOGGLE, and there are two candidates. Neither tick means "am I doing
    -- anything" -- they are two independent modes -- so a row hoisting one would
    -- be claiming it speaks for the pair (the Integrations row's rule).
    check(opts:find("toggle", 1, true) == nil,
          "frame modes: the row hoists neither mode tick -- they are independent")
    check(opts:find("count%s*=%s*FRAME_MODES_COUNT") ~= nil,
          "frame modes: ...it does declare the count, and not as a literal")
    check(opts:find("summary%s*=%s*FrameModesSummary") ~= nil,
          "frame modes: ...and a summary")
    check(opts:find("db      = function() return DF.db end", 1, true) ~= nil,
          "frame modes: the row reads the profile ROOT, where these two keys live")

    -- The summary says which mode is OFF and nothing else. Both on is the shipped
    -- state and prints nothing.
    local sum = PAGE:match("local function FrameModesSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "frame modes: the summary is a named function on the page")
    if sum then
        -- ☠ `== false`, NOT `not d.partyEnabled`: ABSENT MEANS ENABLED for these
        -- two keys, so a profile that has not been seeded would otherwise be
        -- reported as having both modes off.
        check(sum:find("d.partyEnabled == false", 1, true) ~= nil,
              "frame modes: ...tested by presence, the way the reload prompt tests them")
        check(sum:find("d.raidEnabled  == false", 1, true) ~= nil,
              "frame modes: ...both of them")
        check(sum:find("not d.partyEnabled", 1, true) == nil,
              "frame modes: ...never by truthiness, which reads an unseeded profile as off")
        -- The words are the locale's own, paired label-then-value the way every
        -- other summary on the sweep pairs one. No string is invented here.
        check(sum:find('format("%s %s", L["Party"], L["Off"])', 1, true) ~= nil,
              "frame modes: ...printed with the locale's own words")
        check(sum:find("\\194\\183", 1, true) ~= nil,
              "frame modes: ...joined by the convention's dot")
        local items = 0
        for _ in sum:gmatch("parts%[#parts %+ 1%]") do items = items + 1 end
        check(items <= 4, "frame modes: at most four items reach the string at once")
    end
end

-- ============================================================
-- 3. BLIZZARD FRAMES -- four write-both ticks and the divider between them
-- ⚠ THE THIRD TICK BINDS NOTHING THE READER CAN SEE. It passes `nil, nil` and
-- names its key at the END of the argument list (the overrideKey slot), so the
-- census reports "(none)" and the three spellings of "hideDefaultPlayerFrame" are
-- pinned by source pattern below instead.
-- ============================================================
local BLIZZARD_FRAMES = {
    { "checkbox",  "Disable Blizzard Party Frames", "DF.db.party.hideBlizzardPartyFrames", 30 },
    { "checkbox",  "Disable Blizzard Raid Frames",  "DF.db.party.hideBlizzardRaidFrames",  30 },
    { "checkbox",  "Hide Blizzard Player Frame",    "(none)",                              30 },
    { "separator", "(none)",                        "(none)",                              14 },
    { "checkbox",  "Show Party/Raid Side Menu",     "DF.db.party.showBlizzardSideMenu",    30 },
}

print("-- Settings page: Blizzard Frames")
do
    local body = builderBody("BuildBlizzardFramesGroup")
    checkCensus(census(body), BLIZZARD_FRAMES, "blizzard frames")
    checkShared("BuildBlizzardFramesGroup", "Blizzard Frames")

    -- The custom get/set pairs, spelled out: one read of the party copy, one
    -- write to both, and -- for the keyless tick -- the overrideKey that carries
    -- the auto-profile indicator.
    check(body:find('makeBlizGet("hideBlizzardPartyFrames"),', 1, true) ~= nil,
          "blizzard frames: the party tick still reads party-canonical")
    check(body:find('makeBlizSet("hideBlizzardPartyFrames", function() DF:UpdateBlizzardFrameVisibility() end)', 1, true) ~= nil,
          "blizzard frames: ...and writes both tables, refreshing the frames")
    local playerKeys = 0
    for _ in body:gmatch('"hideDefaultPlayerFrame"') do playerKeys = playerKeys + 1 end
    eq(playerKeys, 3, "blizzard frames: the player tick still names its key three times -- get, set, overrideKey")
    check(body:find('makeBlizSet("hideDefaultPlayerFrame", function() DF:UpdateDefaultPlayerFrame() end),\n                "hideDefaultPlayerFrame"', 1, true) ~= nil,
          "blizzard frames: ...with the overrideKey last, where the factory expects it")

    -- The group's own gate stays INSIDE the builder: in classic the box greys the
    -- side-menu tick, and the pane has to do the same.
    check(body:find("sideMenuCheck.disableOn = function()", 1, true) ~= nil,
          "blizzard frames: the side-menu gate moved into the builder with its control")
    check(body:find("return not (p and (p.hideBlizzardPartyFrames or p.hideBlizzardRaidFrames))", 1, true) ~= nil,
          "blizzard frames: ...unchanged -- it is live only once a Blizzard frame is hidden")

    -- The three tooltips came across with their controls.
    local tips = 0
    for _ in body:gmatch("%.tooltip = L%[") do tips = tips + 1 end
    eq(tips, 4, "blizzard frames: all four tooltips came across with their controls")

    local declared = tonumber(PAGE:match("local BLIZZARD_FRAMES_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "blizzard frames: the page declares the row's count in one place")
    eq(declared, #BLIZZARD_FRAMES,
       "blizzard frames: ...the whole census, separator included -- the kit counts what is MOUNTED")

    local opts = rowOpts("Blizzard Frames")
    check(opts:find("toggle", 1, true) == nil,
          "blizzard frames: the row hoists none of the four -- they are independent switches")
    check(opts:find("count%s*=%s*BLIZZARD_FRAMES_COUNT") ~= nil,
          "blizzard frames: ...it does declare the count, and not as a literal")
    -- ☠ NO SUMMARY, and it is a judgement rather than a gap: every honest phrasing
    -- needs a word for the DIRECTION (these ticks HIDE things), and the only words
    -- the locale has for the frames are L["Party"] and L["Raid"] -- which is what
    -- the Frame Modes row directly above prints about the OPPOSITE state.
    check(opts:find("summary", 1, true) == nil,
          "blizzard frames: ...and NO summary -- the only available words say the inverse")
    check(opts:find("db      = function() return DF.db and DF.db.party end", 1, true) ~= nil,
          "blizzard frames: the row reads the party copy its own getters read")
end

-- ============================================================
-- 4. RENDERING -- one write-both tick, one account-wide dropdown, a live hint
-- ⚠ THE SCALE HINT'S CENSUS ROW IS ITS WRAP WIDTH, NOT ITS SLOT HEIGHT. The label
-- is built into a local and added on a LATER line (`group:AddWidget(scaleHint,
-- 72)`), so the only `), <n>)` the reader can see in that chunk is the 250 the
-- factory was given. The real slot height is pinned by its own check below.
-- ============================================================
local RENDERING = {
    { "checkbox", "Pixel-Perfect Scaling",     "(none)", 30 },
    { "label",    "Snaps sizes and borders to exact pixels for crisp rendering.", "(none)", 42 },
    { "label",    "(none)",                    "(none)", 250 },
    { "dropdown", "Aura Duration Update Rate", "DF:GetGlobalDB().auraDurationUpdateInterval", 55 },
    { "label",    "How often aura countdown text refreshes. Smooth updates ten times a second, Performance once a second. Normal keeps the standard rate.", "(none)", 52 },
}

print("-- Settings page: Rendering")
do
    local body = builderBody("BuildRenderingGroup")
    checkCensus(census(body), RENDERING, "rendering")
    checkShared("BuildRenderingGroup", "Rendering")

    check(body:find('makeBlizGet("pixelPerfect"), makeBlizSet("pixelPerfect"), "pixelPerfect"', 1, true) ~= nil,
          "rendering: the pixel-perfect tick keeps its get / set / overrideKey trio")
    check(body:find("nil, nil, refreshPixelPerfect,", 1, true) ~= nil,
          "rendering: ...and the page-scope refresh, which both layouts drive")

    -- ---- the live scale hint -------------------------------------------
    -- ☠ IT KEEPS ITS refreshContent, AND THAT IS WHAT MAKES IT WORK IN A PANE.
    -- The pane's reflow calls the group's RefreshChildStates, which walks
    -- groupChildren calling refreshContent on every shown child (DandersUI
    -- Sections.lua), so the hint re-computes inside an open panel exactly as it
    -- did inline on the page.
    check(body:find("local function computeScaleHint()", 1, true) ~= nil,
          "rendering: the hint's own compute moved into the builder with it")
    check(body:find("scaleHint.refreshContent = function()", 1, true) ~= nil,
          "rendering: ...and its refreshContent, which the pane's reflow reaches")
    check(body:find("if t ~= scaleHint._dfLastHint then", 1, true) ~= nil,
          "rendering: ...still idempotent, so a repaint cannot loop the layout")
    check(body:find("group:AddWidget(scaleHint, 72)", 1, true) ~= nil,
          "rendering: ...added at the slot height it always had (72, not the 250 wrap width)")

    -- The dropdown's option table came across whole, with its explicit order.
    check(body:find('SMOOTH = L["Smooth"], NORMAL = L["Normal"], PERFORMANCE = L["Performance"],', 1, true) ~= nil,
          "rendering: the update-rate options are unchanged")
    check(body:find('_order = { "SMOOTH", "NORMAL", "PERFORMANCE" },', 1, true) ~= nil,
          "rendering: ...and still carry _order, or the menu sorts alphabetically by display text")

    local declared = tonumber(PAGE:match("local RENDERING_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "rendering: the page declares the row's count in one place")
    eq(declared, #RENDERING, "rendering: ...the whole census, because nothing is hoisted")

    local opts = rowOpts("Rendering")
    check(opts:find("toggle", 1, true) == nil,
          "rendering: the row hoists no tick -- pixel-perfect is one of two settings, not the gate")
    check(opts:find("count%s*=%s*RENDERING_COUNT") ~= nil,
          "rendering: ...it does declare the count, and not as a literal")
    check(opts:find("db      = function() return DF:GetGlobalDB() end", 1, true) ~= nil,
          "rendering: the row reads the account-wide table -- the one its summary reports on")

    -- The summary is the update-rate word, and only when it is not the default.
    local sum = PAGE:match("local function RenderingSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "rendering: the summary is a named function on the page")
    if sum then
        check(sum:find('rate == "SMOOTH"', 1, true) ~= nil and sum:find('rate == "PERFORMANCE"', 1, true) ~= nil,
              "rendering: ...it names the two rates that are not the default")
        check(sum:find('"NORMAL"', 1, true) == nil,
              "rendering: ...and says nothing for NORMAL, which every default profile is on")
        -- pixelPerfect is not even IN the row's table (see db above), so a summary
        -- claiming it would be reaching behind the kit for a second store.
        check(sum:find("pixelPerfect", 1, true) == nil,
              "rendering: ...and nothing about pixel-perfect, which lives in the other table")
    end
end

-- ============================================================
-- 5. SETTINGS PANEL APPEARANCE -- two dropdowns, a blurb, and the escape hatch
-- ============================================================
local PANEL_APPEARANCE = {
    { "fontdropdown",    "Settings Font",         "DF.db.settingsFont",        55 },
    { "outlinedropdown", "Settings Font Outline", "DF.db.settingsFontOutline", 55 },
    { "label", "Font used for this settings panel. Does not affect in-game frame text — use the Text Designer for those.", "(none)", 60 },
    { "checkbox",        "Use classic settings layout", "(none)",              30 },
}

print("-- Settings page: Settings Panel Appearance")
do
    local body = builderBody("BuildPanelAppearanceGroup")
    checkCensus(census(body), PANEL_APPEARANCE, "panel appearance")
    checkShared("BuildPanelAppearanceGroup", "Settings Panel Appearance")

    local declared = tonumber(PAGE:match("local PANEL_APPEARANCE_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "panel appearance: the page declares the row's count in one place")
    eq(declared, #PANEL_APPEARANCE, "panel appearance: ...the whole census, because nothing is hoisted")

    local opts = rowOpts("Settings Panel Appearance")
    check(opts:find("toggle", 1, true) == nil,
          "panel appearance: the row hoists no tick -- the classic switch is not this group's gate")
    check(opts:find("count%s*=%s*PANEL_APPEARANCE_COUNT") ~= nil,
          "panel appearance: ...it does declare the count, and not as a literal")
    check(opts:find("db      = function() return DF.db end", 1, true) ~= nil,
          "panel appearance: the row reads the profile ROOT, where the two font keys live")

    -- The summary is the font NAME, unconditionally, through the addon's own
    -- resolver -- the same one CreateFontDropdown prints on its button, so the row
    -- and the control behind it cannot disagree (the Group Labels precedent).
    local sum = PAGE:match("local function PanelAppearanceSummary%(d%)(.-)\n            end")
    check(sum ~= nil, "panel appearance: the summary is a named function on the page")
    if sum then
        check(sum:find("DF.GetFontNameFromPath and DF:GetFontNameFromPath(d.settingsFont)", 1, true) ~= nil,
              "panel appearance: ...it resolves the font name the way the dropdown does")
        check(sum:find("settingsFontOutline", 1, true) == nil,
              "panel appearance: ...and spends no width on the outline beside it")
    end
end

-- ============================================================
-- 6. THE CLASSIC-LAYOUT ESCAPE HATCH -- the one decision this pass had to make
--
-- ☠ IN THE POPOUT LAYOUT THIS TICK LIVES INSIDE A PANE, so the click that turns
-- classic ON happens with a panel standing open -- and the rebuild it triggers
-- CANNOT close it. GUI:CreatePopoutPageTools returns early when
-- IsClassicSettingsLayout() is true, BEFORE its CloseAllPopoutRows("rebuild")
-- prologue, and a row popout is pinnable so the shell's own source-death tick
-- leaves it alone. Without an explicit close the user lands on a classic page
-- with an orphan panel floating beside it, wired to a row already in the trash.
--
-- ⚠ AND THE REBUILD STAYS SYNCHRONOUS, unlike the Frame page's Raid Layout Mode
-- toggle. That one defers because the tick is ON THE ROW and the kit calls
-- row.Refresh() after the write -- on a frame the rebuild has just retired. This
-- is an ordinary checkbox INSIDE the pane: the factory's OnClick does the write,
-- this callback, then `parent.RefreshStates` (a popout holder has none) and
-- DF:UpdateAll, so there is no row refresh to land on a dead frame.
-- ============================================================
print("-- Settings page: the classic-layout escape hatch")
do
    local body = builderBody("BuildPanelAppearanceGroup")

    local closeAt  = body:find('GUI:CloseAllPopoutRows("layoutFlip")', 1, true)
    local invalAt  = body:find("GUI:InvalidateAllPages()", 1, true)
    local rebuildAt = body:find("GUI:RefreshCurrentPage()", 1, true)
    check(closeAt ~= nil, "escape hatch: the flip closes the open panels itself")
    check(invalAt ~= nil, "escape hatch: ...drops every page's build cache")
    check(rebuildAt ~= nil, "escape hatch: ...and rebuilds the one on screen")
    check(closeAt and invalAt and rebuildAt and closeAt < invalAt and invalAt < rebuildAt,
          "escape hatch: ...in that order -- the panels come down before the rebuild")
    check(body:find("if GUI.CloseAllPopoutRows then", 1, true) ~= nil,
          "escape hatch: the close is guarded on the verb, so classic is a plain no-op")

    -- ☠ NOT DEFERRED. A C_Timer.After here would be cargo-cult: see the section
    -- header for why the Raid Layout Mode precedent does not transfer.
    check(body:find("C_Timer.After", 1, true) == nil,
          "escape hatch: the rebuild is synchronous -- this tick is not on the row")

    -- The storage is unchanged: account-level, get/set, and no overrideKey (it is
    -- not a profile setting, so it has no auto-profile override to indicate).
    check(body:find("function() return DF:IsClassicSettingsLayout() end", 1, true) ~= nil,
          "escape hatch: still read from the account-level flag")
    check(body:find("function(val) DF:SetClassicSettingsLayout(val) end", 1, true) ~= nil,
          "escape hatch: ...and written straight back to it")
    check(body:find("classicCheck.tooltip = L[", 1, true) ~= nil,
          "escape hatch: ...and it keeps the tooltip that says it is temporary")
end

-- ============================================================
-- 7. THE PAGE'S RULE -- claimed, but no tick and no footer, on EVERY row
-- ☠ THIS SECTION IS HALF THE POINT OF THE FILE. See the header essay: the
-- per-mode defaults engine can answer for none of these keys, and for the
-- write-both ones a Reset Group would actively desync the pair.
-- ============================================================
print("-- Settings page: every row is a way in, and nothing else")
do
    local ROWS = {
        { "modesRow",      "modesContent",      "Frame Modes" },
        { "blizRow",       "blizContent",       "Blizzard Frames" },
        { "renderRow",     "renderContent",     "Rendering" },
        { "appearanceRow", "appearanceContent", "Settings Panel Appearance" },
        { "notifyRow",     "notifyContent",     "Notifications" },
    }
    for _, r in ipairs(ROWS) do
        check(PAGE:find("tools.ClaimKeys(" .. r[1] .. ", " .. r[2] .. ")", 1, true) ~= nil,
              r[3] .. ": the keys ARE claimed -- that is what feeds the search jump's row map")
        check(PAGE:find("tools.WireModifiedTick(" .. r[1] .. ")", 1, true) == nil,
              r[3] .. ": ...no amber tick -- the defaults engine cannot answer for these keys")
        check(PAGE:find("tools.WireFooter(" .. r[1], 1, true) == nil,
              r[3] .. ": ...and no Reset Group / Hold strip")
    end
    -- Belt and braces: neither verb appears anywhere on the page under any name.
    -- The CALL shape again: the page's own essay names both verbs while saying
    -- why neither is wired.
    check(PAGE:find("tools.WireModifiedTick(", 1, true) == nil,
          "page rule: WireModifiedTick is not called on this page at all")
    check(PAGE:find("tools.WireFooter(", 1, true) == nil,
          "page rule: ...nor WireFooter")
    -- Nothing is hoisted off any row here, so nothing needs re-registering with
    -- search either -- the five claims are the whole search repair.
    check(PAGE:find("RegisterHoistedToggle", 1, true) == nil,
          "page rule: no toggle is hoisted on this page, so none is re-registered")

    -- ...and the reason is written down at the site, not just in this file.
    check(PAGE:find("DF.Defaults", 1, true) ~= nil,
          "page rule: the page names the engine that cannot answer for these keys")
    check(PAGE:find("makeBlizSet", 1, true) ~= nil,
          "page rule: ...and the setter whose pair a reset would desync")
end

-- ============================================================
-- 8. NOTIFICATIONS -- two account-wide ticks, and nothing to say about them
-- ============================================================
local NOTIFICATIONS = {
    { "checkbox", "Notify me when a newer version is available", "DF:GetGlobalDB().notifyOutdated",  30 },
    { "checkbox", "Show the login message",                      "DF:GetGlobalDB().showLoginMessage", 30 },
}

print("-- Settings page: Notifications")
do
    local body = builderBody("BuildNotificationsGroup")
    checkCensus(census(body), NOTIFICATIONS, "notifications")
    checkShared("BuildNotificationsGroup", "Notifications")

    -- The two empty-bodied callbacks came across WITH their comments: neither
    -- setting has anything to re-render now, and the comments are the reason
    -- nobody adds a refresh call to them.
    check(body:find("-- Setting applies immediately; no extra callback needed.", 1, true) ~= nil,
          "notifications: the version tick's callback is still deliberately empty")
    check(body:find("-- Read once at login; nothing to re-render now.", 1, true) ~= nil,
          "notifications: ...and so is the login message's")
    check(body:find("loginMsgCheck.tooltip = L[", 1, true) ~= nil,
          "notifications: the login message keeps its tooltip")

    local declared = tonumber(PAGE:match("local NOTIFICATIONS_COUNT%s*=%s*(%d+)"))
    check(declared ~= nil, "notifications: the page declares the row's count in one place")
    eq(declared, #NOTIFICATIONS, "notifications: ...the whole census, because nothing is hoisted")

    local opts = rowOpts("Notifications")
    check(opts:find("toggle", 1, true) == nil, "notifications: the row declares no toggle")
    -- ☠ NO SUMMARY. Two yes/nos with no word between them: both ship ON, so the
    -- only state worth reporting is one the user turned OFF -- which a summary
    -- cannot say without naming the setting it is about.
    check(opts:find("summary", 1, true) == nil,
          "notifications: ...and no summary -- two yes/nos have no word to spend")
    check(opts:find("db      = function() return DF:GetGlobalDB() end", 1, true) ~= nil,
          "notifications: the row reads the account-wide table, where both ticks live")
end

-- ============================================================
-- 9. WHAT STAYED INLINE, THE BAND, THE BANNER AND THE PAGE'S OWN ORDER
-- ============================================================
print("-- Settings page: the stay-inline boxes, the band, the banner and the order")
do
    -- ---- the skin, at the two stay-inline sites and nowhere else -----
    local sites = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280, tools and tools%.INLINE_BOX or nil%)") do
        sites = sites + 1
    end
    eq(sites, 2, "inline: exactly two groups stay inline and wear the band skin")
    check(PAGE:find("local minimapGroup = GUI:CreateSettingsGroup(self.child, 280, tools and tools.INLINE_BOX or nil)", 1, true) ~= nil,
          "inline: ...one of them is Minimap")
    check(PAGE:find("local languageGroup = GUI:CreateSettingsGroup(self.child, 280, tools and tools.INLINE_BOX or nil)", 1, true) ~= nil,
          "inline: ...and the other is Language")
    -- ⚠ THE FLAG IS NEVER WRITTEN AS A LITERAL. One shared table off the tools, so
    -- classic gets nil -- which is what "no opts" already meant.
    check(PAGE:find("bandStyle", 1, true) == nil,
          "inline: the skin is taken from the tools, never restated as a literal")

    -- Both boxes keep their single control, unchanged.
    check(PAGE:find('makeBlizGet("showMinimapButton"), makeBlizSet("showMinimapButton"), "showMinimapButton"', 1, true) ~= nil,
          "inline: the minimap tick keeps its get / set / overrideKey trio")
    check(PAGE:find('GUI:CreateDropdown(self.child, L["Addon Language"], languageValues, DandersFramesCharDB, "languageOverride"', 1, true) ~= nil,
          "inline: the language dropdown still writes the per-character SavedVariable")

    -- ---- the band ----------------------------------------------------
    check(PAGE:find("settingsBand = GUI:CreateSettingsGroup(self.child, tools.BandWidth(), { chromeless = true })", 1, true) ~= nil,
          "band: the band is chromeless, at the width the layout pass will give it")
    -- ☠ NO HEADER, AND ONE BAND. These five rows share no word that none of them
    -- says alone, and splitting them would mean inventing two section names the
    -- classic page never had.
    check(PAGE:find("settingsBand:AddWidget(GUI:CreateHeader", 1, true) == nil,
          "band: ...and carries no header, because its rows share no word")
    local order = {}
    for name in PAGE:gmatch("settingsBand:AddWidget%(GUI:CreatePopoutRow%(self%.child, {\n%s*label%s*=%s*L%[\"([^\"]+)\"%]") do
        order[#order + 1] = name
    end
    eq(#order, 5, "band: five rows go into the band")
    eq(order[1], "Frame Modes",               "band: the mode enables open it")
    eq(order[2], "Blizzard Frames",           "band: ...then Blizzard Frames")
    eq(order[3], "Rendering",                 "band: ...then Rendering, closing classic's column 1")
    eq(order[4], "Settings Panel Appearance", "band: ...then column 2's first box")
    eq(order[5], "Notifications",             "band: ...and Notifications last, as in classic")

    -- ---- the banner --------------------------------------------------
    -- Untouched, and still the first thing on the page: it is the sentence that
    -- explains why none of this has a party/raid split.
    local bannerAt = PAGE:find("local banner = GUI:CreateInfoBanner(self.child, {", 1, true)
    local bandAt   = PAGE:find("settingsBand = GUI:CreateSettingsGroup", 1, true)
    check(bannerAt ~= nil and bandAt ~= nil and bannerAt < bandAt,
          "banner: the info banner is still built ahead of everything the sweep touched")
    check(PAGE:find('Add(banner, banner.layoutHeight, "both")', 1, true) ~= nil,
          "banner: ...and still added full width at its own measured height")
    check(PAGE:find('tone = "info",', 1, true) ~= nil, "banner: ...with its tone unchanged")

    -- ---- the Add order ------------------------------------------------
    local adds = {}
    for name, col in PAGE:gmatch("Add%((%a[%w_]*),%s*nil,%s*([%w\"_]+)%)") do
        adds[#adds + 1] = { name = name, col = col }
    end
    local function indexOf(name, col)
        for i, e in ipairs(adds) do
            if e.name == name and (col == nil or e.col == col) then return i end
        end
    end
    -- ☠ THE BAND IS ADDED AFTER ITS LAST ROW AND BEFORE THE TWO INLINE BOXES, and
    -- both halves of that are forced. `Add` resolves a widget's slot height on the
    -- spot, so a band added before its rows would be measured empty; and "both" is
    -- a sync point, so a full-width band dropped in BELOW a lone column box would
    -- leave a hole beside it.
    check(PAGE:find("if not classicLayout then\n            Add(settingsBand, nil, \"both\")\n            Add(minimapGroup, nil, 1)\n            Add(languageGroup, nil, 2)\n        end", 1, true) ~= nil,
          "order: the popout arm adds the band, then the two boxes in their own columns")

    -- ...and the CLASSIC order and columns are exactly what they were: modes,
    -- Blizzard and Minimap and Rendering in column 1; Appearance, Language and
    -- Notifications in column 2, in that reading order. This is the one thing the
    -- pass was not allowed to move.
    local CLASSIC = {
        { "modesGroup", "1" }, { "blizzardGroup", "1" }, { "minimapGroup", "1" },
        { "renderingGroup", "1" }, { "panelAppearanceGroup", "2" },
        { "languageGroup", "2" }, { "notificationsGroup", "2" },
    }
    local last = 0
    for _, e in ipairs(CLASSIC) do
        local at = indexOf(e[1], e[2])
        check(at ~= nil, "order: the classic " .. e[1] .. " still goes to column " .. e[2])
        check(at ~= nil and at > last, "order: ...and still in its original place in the flow")
        last = at or last
    end

    -- Five bare 280 boxes are left, and every one is inside a classicLayout arm:
    -- a sixth appearing outside one is the drift this counts.
    local bare = 0
    for _ in PAGE:gmatch("GUI:CreateSettingsGroup%(self%.child, 280%)") do bare = bare + 1 end
    eq(bare, 5, "order: five bare 280 boxes left, and they are the classic branch's own")

    -- The page never had a copy button -- there is nothing per-mode on it to copy
    -- -- and this pass did not give it one.
    check(PAGE:find("CreateCopyButton", 1, true) == nil,
          "page: still no copy button, because nothing here is per-mode")
end
