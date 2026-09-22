local NS = ...

-- ============================================================
-- PINNED FRAMES PAGE -- DandersFrames_Options/GUI/Pages/Frames.lua
-- ------------------------------------------------------------
-- General > Pinned Frames keeps its STRUCTURE in Modern -- the per-set tab
-- strip (add, remove, rename, the on/off pip), the Setup / Appearance /
-- Members sub-tabs and the Members roster -- and takes the other General pages'
-- look: the intro is an info banner, each box is a collapsible CARD in its
-- column behind its box's own sub-tab gate, and Expand All / Collapse All sits
-- under the sub-tabs.
--
-- ☠ THE PAGE HAD NO LAYOUT BRANCH BEFORE THIS, so every Modern difference is a
-- NEW `if classicLayout then ... else ... end` whose classic arm is the code the
-- page always ran. What this file pins:
--   ✓ each card's column, stable key and sub-tab gate, and that the box it
--     replaces is still what classic builds;
--   ✓ that the set machinery (add / remove / tab switch) is untouched;
--   ✓ that classic never takes the page tools.
--   ✗ nothing about runtime behaviour -- read in game.
-- ============================================================

local SRC = options_file_source("GUI/Pages/Frames.lua"):gsub("\r\n", "\n")

local PAGE
do
    local a = SRC:find("BuildPage(pagePinnedFrames, function(self, db, Add, AddSpace, AddSyncPoint)", 1, true)
    local b = SRC:find("DF._SetupGUIPagesPart3(", 1, true)
    check(a ~= nil and b ~= nil and b > a, "the Pinned Frames page builder is locatable by its own ends")
    PAGE = SRC:sub(a or 1, b or 1)
end

print("-- Pinned Frames page: the layout decision and the tools")
do
    check(PAGE:find("local classicLayout = DF:IsClassicSettingsLayout()", 1, true) ~= nil,
          "tools: the page asks which layout it is building")
    check(PAGE:find("local tools = (not classicLayout) and GUI:CreatePopoutPageTools(self) or nil", 1, true) ~= nil,
          "tools: ...and takes the page tools in Modern only, so classic runs exactly what it always did")
    local fwd = (PAGE:match("local function OpenSection%(label.-\n        end\n") or ""):gsub("%s+", " ")
    check(fwd:find("return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle, { twoTrack = true, quietLabels = true })", 1, true) ~= nil,
          "sections: every card goes through the shared helper")
    for _, gone in ipairs({ "GUI:CreatePopoutRow(", "GUI:CreateControlRow(", "tools.PopoutContent(",
                            "footerStrip", "inline = true" }) do
        check(PAGE:find(gone, 1, true) == nil, "furniture: " .. gone .. " never appears on the page")
    end
end

print("-- Pinned Frames page: the intro")
do
    -- Classic keeps the titled box and its deferred height measuring; Modern
    -- says the same sentence as a banner.
    check(PAGE:find('        if classicLayout then\n            local headerGroup = GUI:CreateSettingsGroup(self.child, 560)', 1, true) ~= nil,
          "intro: classic builds the header box, and only classic")
    check(PAGE:find('            Add(headerGroup, nil, "both")\n        else', 1, true) ~= nil,
          "intro: ...adding it where it always did")
    local text = 'L["Create separate frame groups to pin specific players like tanks, healers, or key raid members, or to track NPC frames. Add players using the Members tab."]'
    local n = 0
    for _ in PAGE:gmatch(text:gsub("%p", "%%%0")) do n = n + 1 end
    eq(n, 2, "intro: the one sentence, shipped string, in both layouts")
    check(PAGE:find('local pinnedIntro = GUI:CreateInfoBanner(self.child, {', 1, true) ~= nil
      and PAGE:find('Add(pinnedIntro, pinnedIntro.layoutHeight, "both")', 1, true) ~= nil,
          "intro: Modern's is an info banner spanning both columns")
end

print("-- Pinned Frames page: the cards")
do
    local CARDS = {
        { label = "Settings",      key = "pinned_settings",     col = "1",      var = "settingsGroup",  gate = 'activeSubTab ~= "setup"',      width = "280" },
        { label = "Frame Type",    key = "pinned_frametype",    col = "2",      var = "frameTypeGroup", gate = 'activeSubTab ~= "setup"',      width = "280" },
        { label = "Frame Style",   key = "pinned_framestyle",   col = "1",      var = "layoutGroup",    gate = 'activeSubTab ~= "appearance"', width = "280" },
        { label = "Layout",        key = "pinned_layout",       col = "2",      var = "arrangeGroup",   gate = 'activeSubTab ~= "appearance"', width = "280" },
        { label = "Auto-Populate", key = "pinned_autopopulate", col = '"both"', var = "autoPopGroup",   gate = "membersHideOn",                width = "560" },
    }
    local order = {}
    for name in PAGE:gmatch('OpenSection%(L%["([^"]+)"%]') do order[#order + 1] = name end
    eq(table.concat(order, " | "), "Settings | Frame Type | Frame Style | Layout | Auto-Populate",
       "cards: the five boxes, in the page's order")

    for _, c in ipairs(CARDS) do
        local flat = PAGE:gsub("%s+", " ")
        check(flat:find(c.var .. ' = GUI:CreateSettingsGroup(self.child, ' .. c.width .. ')', 1, true) ~= nil,
              c.label .. ": classic still builds its " .. c.width .. " box")
        -- The OpenSection call, up to the `end` closing its else arm.
        local a = PAGE:find('OpenSection(L["' .. c.label .. '"]', 1, true)
        local b = a and PAGE:find("\n        end", a, true)
        local call = (a and b) and PAGE:sub(a, b):gsub("%s+", " ") or ""
        check(call:find('"' .. c.key .. '", ' .. c.col, 1, true) ~= nil,
              c.label .. ": Modern opens a card keyed " .. c.key .. " in column " .. c.col)
        check(call:find(c.gate, 1, true) ~= nil,
              c.label .. ": ...hidden outside its sub-tab, the same gate as the box")
        check(flat:find("if classicLayout then Add(" .. c.var .. ", nil, " .. c.col .. ") else CloseSection(" .. c.var .. ") end", 1, true) ~= nil,
              c.label .. ": classic adds the box where it always did; Modern closes the card after its last control")
    end
    -- Frame Type greys, header and body, while the set is disabled.
    local fa = PAGE:find('OpenSection(L["Frame Type"]', 1, true)
    local fb = fa and PAGE:find("\n        end", fa, true)
    local ft = (fa and fb) and PAGE:sub(fa, fb) or ""
    check(ft:find("function() return PinnedSetDisabled() end", 1, true) ~= nil,
          "cards: Frame Type's header greys while the set is disabled, as its body does")
    check(PAGE:find("if classicLayout then\n            AddSpace(GUI.Space.section, \"both\")\n        end", 1, true) ~= nil,
          "cards: the spacer between the Setup and Appearance boxes is classic's alone")
    check(PAGE:find('if not classicLayout then\n            Add(tools.SectionControls(self.child), 24, "both")\n        end', 1, true) ~= nil,
          "bulk: Expand All / Collapse All under the sub-tabs, Modern only")
end

print("-- Pinned Frames page: the set machinery is untouched")
do
    for _, line in ipairs({
        "local newIndex = DF.PinnedFrames:AddSet(GUI.SelectedMode)",
        "if DF.PinnedFrames:RemoveSet(idx, mode) then",
        'tab.removeBtn = GUI:CreateCloseButton(tab, { size = 16, onClick = function() DoRemoveSet(i) end })',
        "addSetBtn:SetScript(\"OnClick\", DoAddSet)",
        'Add(tabContainer, 32, "both")',
        'Add(subTabContainer, 26, "both")',
        'Add(unitSelHeader, 40, "both")',
        'Add(rosterWidget, 378, "both")',
    }) do
        check(PAGE:find(line, 1, true) ~= nil, "sets: `" .. line .. "` is still there")
    end
end
