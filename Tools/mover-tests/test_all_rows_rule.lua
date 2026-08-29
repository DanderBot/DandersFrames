local NS = ...

-- ============================================================
-- THE ALL-ROWS RULE -- every settings page, swept in one pass
-- ------------------------------------------------------------
-- On a converted page every top-level object shares ONE left edge and ONE right
-- edge. There are exactly two shapes that satisfy that, and the sweep's per-page
-- census files pin which shape each SITE took:
--
--   a control row  -- one setting on a popout row's plate, in a band
--                     (DandersUI/ControlRow.lua)
--   a full-width box -- a group that could not convert, built at the BAND's
--                     width and added "both"
--
-- What no page may have any more is the third shape: a 280 box standing beside a
-- full-width band. The band skin (tools.INLINE_BOX) was only ever half an answer
-- to it -- it settles the BORDER and never the EDGE, so a skinned 280 box still
-- starts and ends somewhere nothing else on the page does.
--
-- ☠ THIS FILE IS THE RULE ITSELF, NOT ONE PAGE'S READING OF IT. Each census file
-- already counts its own page's boxes; that catches a regression on a page
-- somebody was editing. This catches the one they were NOT -- a new page, a
-- page's second pass, or a stay-inline box copied forward out of an older file.
--
-- ⚠ THE PAGE LIST COMES FROM THE TOC, NOT FROM A LITERAL HERE. A hardcoded list
-- is a rule that silently stops covering the next page added; the companion's
-- own manifest is the one place that cannot forget one.
--
-- What that buys, and what it does not:
--   ✓ no new-UI mount is left at a column's 280, on ANY page.
--   ✓ the band skin and the chromeless band are only ever asked for at the
--     band's width.
--   ✓ a control row is always mounted into a band, never straight into a column.
--   ✗ nothing about what any individual site SHOULD have become -- that is the
--     per-page censuses' job, and the in-game checklist's.
-- ============================================================

-- ---- the pages, off the companion's own manifest ---------------------
local TOC = options_file_source("DandersFrames_Options.toc")
local PAGES = {}
for name in TOC:gmatch("GUI\\(Pages\\[%w_]+%.lua)") do
    PAGES[#PAGES + 1] = "GUI/" .. name:gsub("\\", "/")
end

-- ⚠ AND THE ONE PAGE THAT IS NOT IN GUI\Pages. The Aura Designer's popout page
-- lives with the rest of the designer's editor rather than with the settings
-- pages, because it is one arm of a builder whose other arm is the split panel.
-- It is a settings page for every purpose this rule cares about, so a shape
-- exemption on the grounds of which folder it sits in would be exactly the gap
-- this file was written to close.
for name in TOC:gmatch("AuraDesigner\\(UI\\Rows%.lua)") do
    PAGES[#PAGES + 1] = "AuraDesigner/" .. name:gsub("\\", "/")
end
-- ...and the Text Designer's, which sits with its own editor for the same
-- reason and is the same kind of page.
for name in TOC:gmatch("TextDesigner\\(UI\\Rows%.lua)") do
    PAGES[#PAGES + 1] = "TextDesigner/" .. name:gsub("\\", "/")
end

print("-- All-rows rule: every settings page shares two edges")
do
    check(#PAGES >= 8, "toc: the manifest lists the page files (found " .. #PAGES .. ")")

    -- A settings group's whole call, parens balanced, so a width expression that
    -- is itself a call (tools.BandWidth()) is not cut in half.
    local groups, narrow, skinned, chromeless = 0, 0, 0, 0
    local rows, rowsInBand = 0, 0

    for _, page in ipairs(PAGES) do
        local src = options_file_source(page)

        for call in src:gmatch("GUI:CreateSettingsGroup%b()") do
            groups = groups + 1
            local inner = call:match("^GUI:CreateSettingsGroup%((.*)%)$") or ""
            -- Everything after the parent argument: "<width>[, <opts>]".
            local rest = inner:match("^[%w_%.]+%s*,%s*(.*)$")
            if rest then
                local width, opts = rest:match("^(%d+)%s*,%s*(.+)$")
                if width then
                    -- ☠ THE RULE. A bare number is a CLASSIC arm's box -- classic
                    -- passes no opts and always has. A number WITH an opts table is
                    -- a new-UI mount at a column's width, which is the shape this
                    -- whole pass removed.
                    narrow = narrow + 1
                    check(false, "alignment: " .. page ..
                          " mounts a new-UI box at a column width: " .. call)
                end

                -- The band skin, and the chromeless band, may only be asked for at
                -- the width the layout pass will hand a "both" widget.
                if rest:find("INLINE_BOX", 1, true) then
                    skinned = skinned + 1
                    check(rest:find("tools.BandWidth()", 1, true) ~= nil,
                          "alignment: " .. page .. " wears the band skin at the band's width")
                end
                if rest:find("chromeless", 1, true) then
                    chromeless = chromeless + 1
                    check(rest:find("tools.BandWidth()", 1, true) ~= nil,
                          "alignment: " .. page .. " builds its chromeless band at the band's width")
                end
            end
        end

        -- ⚠ AND THE ONE IDIOM THAT CANNOT SURVIVE THE RULE. `tools and
        -- tools.INLINE_BOX or nil` was how a stay-inline site served BOTH layouts
        -- from one construction -- which only works while the two layouts want the
        -- same width. They no longer do, so every site is an if/else (or an
        -- expression naming both widths) and the flag is only reached where the
        -- tools are known to exist.
        check(src:find("tools and tools.INLINE_BOX or nil", 1, true) == nil,
              "alignment: " .. page .. " has no one-construction stay-inline site left")

        -- A control row is a row: it goes into a band, never straight into a
        -- column. Every call site reads `<band>:AddWidget(GUI:CreateControlRow(`.
        for _ in src:gmatch("GUI:CreateControlRow%(") do rows = rows + 1 end
        for _ in src:gmatch("[%w_]+:AddWidget%(GUI:CreateControlRow%(") do
            rowsInBand = rowsInBand + 1
        end
    end

    eq(narrow, 0, "alignment: no new-UI mount on any page uses the bare 280 width")
    eq(rows, rowsInBand, "alignment: every control row is mounted into a band, never into a column")
    -- Floors rather than exact counts: this file is a RULE, and a rule that had
    -- to be re-numbered on every page added would be edited into agreement with
    -- whatever was there. The exact inventory per page is the censuses' job.
    check(groups > 200, "alignment: the sweep actually read the pages (" .. groups .. " groups)")
    check(skinned >= 4, "alignment: ...and found the full-width boxes (" .. skinned .. ")")
    check(chromeless >= 10, "alignment: ...and the bands (" .. chromeless .. ")")
    check(rows >= 6, "alignment: ...and the control rows (" .. rows .. ")")
end
