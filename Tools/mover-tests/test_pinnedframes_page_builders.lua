local NS = ...

-- ============================================================
-- PINNED FRAMES PAGE -- DandersFrames_Options/GUI/Pages/Frames.lua
-- ------------------------------------------------------------
-- General > Pinned Frames keeps its STRUCTURE -- the per-set tab
-- strip (add, remove, rename, the on/off pip), the Setup / Appearance /
-- Members sub-tabs and the Members roster -- and takes the other General pages'
-- look: the intro is an info banner, each box is a collapsible CARD in its
-- column behind its box's own sub-tab gate, and Expand All / Collapse All sits
-- under the sub-tabs.
--
-- What this file pins:
--   ✓ each card's column, stable key and sub-tab gate;
--   ✓ that the set machinery (add / remove / tab switch) is untouched;
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
    -- The intro sentence is an info banner.
    local text = 'L["Create separate frame groups to pin specific players like tanks, healers, or key raid members, or to track NPC frames. Add players using the Members tab."]'
    local n = 0
    for _ in PAGE:gmatch(text:gsub("%p", "%%%0")) do n = n + 1 end
    eq(n, 1, "intro: the one sentence, shipped string")
    check(PAGE:find('local pinnedIntro = GUI:CreateInfoBanner(self.child, {', 1, true) ~= nil
      and PAGE:find('Add(pinnedIntro, pinnedIntro.layoutHeight, "both")', 1, true) ~= nil,
          "intro: an info banner spanning both columns")
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
        -- The OpenSection statement, up to the blank line after it.
        local a = PAGE:find('OpenSection(L["' .. c.label .. '"]', 1, true)
        local b = a and PAGE:find("\n\n", a, true)
        local call = (a and b) and PAGE:sub(a, b):gsub("%s+", " ") or ""
        check(call:find('"' .. c.key .. '", ' .. c.col, 1, true) ~= nil,
              c.label .. ": opens a card keyed " .. c.key .. " in column " .. c.col)
        check(call:find(c.gate, 1, true) ~= nil,
              c.label .. ": ...hidden outside its sub-tab")
    end
    -- Frame Type greys, header and body, while the set is disabled.
    local fa = PAGE:find('OpenSection(L["Frame Type"]', 1, true)
    local fb = fa and PAGE:find("\n\n", fa, true)
    local ft = (fa and fb) and PAGE:sub(fa, fb) or ""
    check(ft:find("function() return PinnedSetDisabled() end", 1, true) ~= nil,
          "cards: Frame Type's header greys while the set is disabled, as its body does")
    check(PAGE:find('\n        Add(tools.SectionControls(self.child), 24, "both")', 1, true) ~= nil,
          "bulk: Expand All / Collapse All under the sub-tabs")
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
