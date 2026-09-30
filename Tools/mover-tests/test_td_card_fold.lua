local NS = ...

-- ============================================================
-- THE TEXT DESIGNER'S CARDS FOLD IN PLACE
-- ------------------------------------------------------------
-- ☠ WoW never frees a frame. Folding a text-element or group card used to
-- re-render the WHOLE card list: every card and every control in every body was
-- built again on each click, and the old ones were only hidden. A user folding
-- cards up and down leaked a full page of frames per click.
--
-- A fold now toggles the body, drives the chrome, sets the card's height and
-- re-anchors the cards below (RestackCards). This file RUNS the real card
-- builders and renderers, cut out of TextDesigner/UI/Options.lua, against stub
-- frames, and pins:
--   ✓ a fold makes no frames and calls no re-render;
--   ✓ the fold key (td_elem_<id> / td_group_<id>) is still written and cleared;
--   ✓ the cards below move up on a fold and back down on an unfold, and the
--     scroll child's height follows.
--   ✗ nothing about what the page looks like -- that is the in-game checklist.
-- ============================================================

local TD = options_file_source("TextDesigner/UI/Options.lua"):gsub("\r\n", "\n")

local function cut(src, startPlain, stopPlain)
    local s = src:find(startPlain, 1, true)
    if not s then return nil end
    local e = src:find(stopPlain, s, true)
    if not e then return nil end
    return src:sub(s, e + #stopPlain - 1)
end

print("-- TD card fold: a fold relays out in place, never re-renders")

local pieces = {
    restack    = cut(TD, "local function RestackCards(cards, child, gap)", "\nend\n"),
    elemCard   = cut(TD, "local function CreateTextElementCard(GUI, parent, yPos, elem, tdDB, state, page)", "\nend\n"),
    renderList = cut(TD, "local function RenderCardList(GUI, page, tdDB, state)", "\nend\n"),
    groupCard  = cut(TD, "local function CreateGroupCard(GUI, parent, yPos, elem, tdDB, state, page)", "\nend\n"),
    renderGrp  = cut(TD, "local function RenderGroupCardList(GUI, page, tdDB, state)", "\nend\n"),
}
check(pieces.restack ~= nil, "fold: RestackCards is declared in TextDesigner/UI/Options.lua")
for _, k in ipairs({ "elemCard", "renderList", "groupCard", "renderGrp" }) do
    check(pieces[k] ~= nil, "fold: " .. k .. " can be cut out of TextDesigner/UI/Options.lua")
end

-- ---- stubs ---------------------------------------------------------------
local framesMade = 0
local function MakeFrame(w, h)
    local f = FakeUIFrame(w, h)
    f.CreateTexture = function() return FakeUIFrame() end
    f.CreateFontString = function() return FakeUIFrame() end
    f.GetFrameLevel = function() return 1 end
    return f
end
local function CreateFrame(_, _, parent)
    framesMade = framesMade + 1
    local f = MakeFrame(300, 0)
    f:SetFakeParent(parent)
    return f
end

local collapsed = {}
local GUI = {
    SectionCard = { header = 40, gap = 8, titleGap = 6 },
    GetCollapsedGroups = function() return collapsed end,
    CreateCloseButton = function() return MakeFrame(22, 22) end,
    CreateCardChrome = function(_, card, header)
        header:SetHeight(40)
        local c = { chevron = MakeFrame(), title = MakeFrame(), summary = MakeFrame(), calls = {} }
        function c:LayoutText() end
        function c:SetSummary(s) self.summary:SetText(s) end
        function c:SetDimmed() end
        function c:Paint() end
        function c:SetExpanded(open, body) self.calls[#self.calls + 1] = { open = open, body = body } end
        return c
    end,
}
local rerenders = 0
local DF = {
    GUI = { CreateGlyphButton = function() return MakeFrame(18, 18) end },
    TextDesigner = {
        RenderCardList      = function() rerenders = rerenders + 1 end,
        RenderGroupCardList = function() rerenders = rerenders + 1 end,
        FullRebuildCards    = function() rerenders = rerenders + 1 end,
    },
}
DF.Debug = function() end
local L = setmetatable({}, { __index = function(_, k) return k end })
local CATEGORY_COLORS = { x = { r = 1, g = 1, b = 1, a = 1 }, group = { r = 1, g = 1, b = 1, a = 1 } }
local C_TEXT_DIM = { r = 0.6, g = 0.6, b = 0.6 }
local function FindContentType(key) return { category = "x", label = key } end
-- Every section is 100 tall, so an open body is 10 + 300 + 10 = 320.
local function BuildContentSection(GUI_, parent, elem, tdDB, state, page, card, yStart) return yStart - 100 end
local function BuildAppearanceSection(GUI_, parent, elem, card, yStart) return yStart - 100 end
local function BuildPositionSection(GUI_, parent, elem, tdDB, card, yStart) return yStart - 100 end

local api
if pieces.elemCard and pieces.renderList and pieces.groupCard and pieces.renderGrp then
    local src = "local CreateFrame, GUI, DF, L, CATEGORY_COLORS, C_TEXT_DIM, FindContentType,"
        .. " BuildContentSection, BuildAppearanceSection, BuildPositionSection = ...\n"
        .. (pieces.restack or "") .. "\n"
        .. pieces.elemCard .. "\n" .. pieces.renderList .. "\n"
        .. pieces.groupCard .. "\n" .. pieces.renderGrp .. "\n"
        .. "return { RenderCardList = RenderCardList, RenderGroupCardList = RenderGroupCardList }\n"
    local chunk, err = loadstring(src)
    check(chunk ~= nil, "fold: the cut parses (" .. tostring(err) .. ")")
    if chunk then
        api = chunk(CreateFrame, GUI, DF, L, CATEGORY_COLORS, C_TEXT_DIM, FindContentType,
                    BuildContentSection, BuildAppearanceSection, BuildPositionSection)
        -- The re-render exports count AND run the real renderers, so a fold that
        -- still re-renders is caught twice: by the count and by the frames it makes.
        DF.TextDesigner.RenderCardList = function(...)
            rerenders = rerenders + 1
            return api.RenderCardList(...)
        end
        DF.TextDesigner.RenderGroupCardList = function(...)
            rerenders = rerenders + 1
            return api.RenderGroupCardList(...)
        end
    end
end

-- The y offset a card's TOPLEFT anchor was last given.
local function topY(card)
    for _, pt in ipairs(card._points) do
        if pt[1] == "TOPLEFT" then return pt[5] end
    end
end

local OPEN, SHUT, GAP = 40 + 320, 40, 8

local function run(kind)
    local isGroup = kind == "group"
    local prefix = isGroup and "td_group_" or "td_elem_"
    wipe(collapsed)
    local tdDB = { elements = {} }
    for id = 1, 3 do
        tdDB.elements[id] = { id = id, enabled = true, label = "E" .. id,
                              contentType = isGroup and "group" or "name", groupItems = {} }
    end
    local child, container = MakeFrame(300, 1), MakeFrame(300, 1)
    local state = isGroup and { groupListChild = child, groupListContainer = container }
                          or  { listChild = child, listContainer = container }
    if isGroup then api.RenderGroupCardList(GUI, {}, tdDB, state)
    else            api.RenderCardList(GUI, {}, tdDB, state) end
    local frames = isGroup and state.groupCardFrames or state.cardFrames
    local c1, c2, c3 = frames[1], frames[2], frames[3]
    check(c1 and c2 and c3, kind .. ": three cards built")
    if not (c1 and c2 and c3) then return end
    eq(topY(c2), -(OPEN + GAP), kind .. ": built open, card 2 sits under an open card 1")

    -- FOLD card 1.
    local made, renders = framesMade, rerenders
    c1.header._scripts.OnClick()
    eq(framesMade - made, 0, kind .. " fold: makes no frames")
    eq(rerenders - renders, 0, kind .. " fold: calls no re-render")
    eq(collapsed[prefix .. "1"], true, kind .. " fold: the fold key is written")
    check(not c1.body:IsShown(), kind .. " fold: the body hides")
    eq(c1:GetHeight(), SHUT, kind .. " fold: the card is the header alone")
    local last = c1.chrome.calls[#c1.chrome.calls]
    check(last and last.open == false and last.body == c1.body, kind .. " fold: the chrome is told it is shut")
    eq(topY(c2), -(SHUT + GAP), kind .. " fold: card 2 moves up")
    eq(topY(c3), -(SHUT + GAP + OPEN + GAP), kind .. " fold: card 3 moves up")
    eq(child:GetHeight(), SHUT + OPEN + OPEN + 3 * GAP + 4, kind .. " fold: the scroll child shrinks")
    check(frames[1] == c1 and frames[2] == c2, kind .. " fold: the same card frames stay live")

    -- UNFOLD card 1.
    made, renders = framesMade, rerenders
    c1.header._scripts.OnClick()
    eq(framesMade - made, 0, kind .. " unfold: makes no frames")
    eq(rerenders - renders, 0, kind .. " unfold: calls no re-render")
    eq(collapsed[prefix .. "1"], nil, kind .. " unfold: the fold key is cleared")
    check(c1.body:IsShown(), kind .. " unfold: the body shows")
    eq(topY(c2), -(OPEN + GAP), kind .. " unfold: card 2 moves back down")
    eq(child:GetHeight(), 3 * OPEN + 3 * GAP + 4, kind .. " unfold: the scroll child grows back")

    -- A card built folded (key already stored) starts at header height.
    collapsed[prefix .. "2"] = true
    if isGroup then api.RenderGroupCardList(GUI, {}, tdDB, state)
    else            api.RenderCardList(GUI, {}, tdDB, state) end
    local d3 = (isGroup and state.groupCardFrames or state.cardFrames)[3]
    eq(topY(d3), -(OPEN + GAP + SHUT + GAP), kind .. ": a stored fold survives a rebuild")
end

if api then
    run("text")
    run("group")
end
