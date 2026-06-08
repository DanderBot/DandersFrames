local addonName, DF = ...

-- ============================================================
-- NICKNAMES - SOURCE PICKER  (Phase 2)
-- A popup to browse a source (current group / guild / in-game friends) and
-- add chosen characters as EXACT nickname rules, tagged with their source.
-- Candidates come from DF.Nicknames:Get*Candidates(); adds go through
-- NK:AddTyped, which fires NK.onChange so the main panel updates live.
--
-- NOTE: this file loads (Options/) BEFORE Features/Nicknames.lua, so we must
-- reference DF.Nicknames lazily inside functions, never at file scope.
-- ============================================================

local ipairs = ipairs
local tsort = table.sort
local mmax = math.max
local strlower = string.lower
local strfind = string.find
local CreateFrame = CreateFrame

local L = DF.L

-- sourceKey -> { label, tag (Source column value), getter method name }
local SOURCES = {
    group   = { label = L["Group"],   tag = "Group",  get = "GetGroupCandidates" },
    guild   = { label = L["Guild"],   tag = "Guild",  get = "GetGuildCandidates" },
    friends = { label = L["Friends"], tag = "Friend", get = "GetFriendCandidates" },
    bnet    = { label = L["B.net"],   tag = "B.net",  get = "GetBnetCandidates", bnet = true },
}

local picker  -- single reusable frame, built on first use

local function classColor(token)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then return c.r, c.g, c.b end
    return 0.9, 0.9, 0.9
end

local function styleEditBox(eb)
    eb:SetAutoFocus(false)
    eb:SetFontObject(DFFontHighlightSmall)
    eb:SetTextInsets(6, 6, 0, 0)
    eb:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    eb:SetBackdropColor(0, 0, 0, 0.5)
    eb:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
end

local ROW_H = 28
local SEP_H = 11   -- height of the favourites/rest divider band

local function buildPicker()
    local GUI = DF.GUI

    local f = CreateFrame("Frame", "DFNicknamePicker", UIParent, "BackdropTemplate")
    f:SetSize(380, 440)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.08, 0.08, 0.08, 0.98)
    f:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Title
    f.title = f:CreateFontString(nil, "OVERLAY", "DFFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -12)
    local tc = (GUI.GetThemeColor and GUI.GetThemeColor()) or { r = 0.9, g = 0.55, b = 0.15 }
    f.title:SetTextColor(tc.r, tc.g, tc.b)

    -- Close
    f.close = GUI:CreateIconButton(f, "close", "", 24, 24, function() f:Hide() end, 12)
    f.close:SetPoint("TOPRIGHT", -8, -8)
    f.close.Icon:ClearAllPoints()
    f.close.Icon:SetPoint("CENTER")

    -- Search
    f.search = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    f.search:SetPoint("TOPLEFT", 12, -40)
    f.search:SetPoint("TOPRIGHT", -12, -40)
    f.search:SetHeight(22)
    styleEditBox(f.search)
    f.search:SetScript("OnTextChanged", function() if f.Repopulate then f:Repopulate() end end)
    f.searchPH = f.search:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
    f.searchPH:SetPoint("LEFT", 6, 0)
    f.searchPH:SetText(L["Search..."])
    f.search:SetScript("OnEditFocusGained", function() f.searchPH:Hide() end)
    f.search:SetScript("OnEditFocusLost", function(self) if self:GetText() == "" then f.searchPH:Show() end end)

    -- List
    local listBg = CreateFrame("Frame", nil, f, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", 12, -70)
    listBg:SetPoint("BOTTOMRIGHT", -12, 12)
    listBg:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    listBg:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
    listBg:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)

    local scroll = CreateFrame("ScrollFrame", nil, listBg, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -24, 4)
    if GUI.StyleScrollBar then GUI.StyleScrollBar(scroll) end

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(320, 1)
    scroll:SetScrollChild(content)
    f.content = content

    -- Divider between the favourites block and the rest (Blizzard-style),
    -- shown/positioned per Repopulate.
    f.sep = content:CreateTexture(nil, "ARTWORK")
    f.sep:SetHeight(1)
    f.sep:SetColorTexture(0.95, 0.78, 0.25, 0.35)  -- faint gold, ties to star/tint
    f.sep:Hide()

    f.empty = listBg:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
    f.empty:SetPoint("CENTER", 0, 0)

    local rows = {}

    local function getRow(i)
        local r = rows[i]
        if r then return r end

        r = CreateFrame("Frame", nil, content)
        r:SetSize(320, ROW_H)

        -- Favourite-row tint (behind everything; shown only when favourited).
        r.bg = r:CreateTexture(nil, "BACKGROUND")
        r.bg:SetAllPoints()
        r.bg:SetColorTexture(0.95, 0.78, 0.25, 0.10)  -- subtle warm gold
        r.bg:Hide()

        -- Favourite star toggle (leads the row).
        r.fav = CreateFrame("Button", nil, r)
        r.fav:SetSize(16, 16)
        r.fav:SetPoint("LEFT", 4, 0)
        r.favTex = r.fav:CreateTexture(nil, "ARTWORK")
        r.favTex:SetAllPoints()
        r.favTex:SetAtlas("PetJournal-FavoritesIcon")
        r.fav:SetScript("OnClick", function() if r.DoFav then r.DoFav() end end)
        r.fav:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(L["Favourite"])
            GameTooltip:Show()
        end)
        r.fav:SetScript("OnLeave", function() GameTooltip:Hide() end)

        r.nameFS = r:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
        r.nameFS:SetPoint("LEFT", r.fav, "RIGHT", 4, 0)
        r.nameFS:SetWidth(150)
        r.nameFS:SetJustifyH("LEFT")

        r.nick = CreateFrame("EditBox", nil, r, "BackdropTemplate")
        r.nick:SetSize(80, 20)
        r.nick:SetPoint("LEFT", r.nameFS, "RIGHT", 4, 0)
        styleEditBox(r.nick)
        r.nick:SetScript("OnEnterPressed", function(self) self:ClearFocus(); if r.DoAdd then r.DoAdd() end end)

        r.add = GUI:CreateIconButton(r, "add", "", 24, 20, function() if r.DoAdd then r.DoAdd() end end, 12)
        r.add:SetPoint("RIGHT", -2, 0)
        r.add.Icon:ClearAllPoints()
        r.add.Icon:SetPoint("CENTER")

        r.addedFS = r:CreateFontString(nil, "OVERLAY", "DFFontDisableSmall")
        r.addedFS:SetPoint("RIGHT", -8, 0)
        r.addedFS:SetText(L["Added"])
        r.addedFS:Hide()

        rows[i] = r
        return r
    end

    function f:Repopulate()
        local NK = DF.Nicknames
        local cfg = self.cfg
        if not NK or not cfg then return end

        local isBnet = cfg.bnet
        local cands = NK[cfg.get](NK) or {}
        -- Annotate favourite state, then sort into 3 tiers: favourites, then
        -- online, then offline — alphabetical within each tier.
        for _, c in ipairs(cands) do
            local bucket, key = NK:FavoriteKey(c, isBnet)
            c._favBucket, c._favKey = bucket, key
            c._fav = (bucket and key and bucket[key]) and true or false
        end
        tsort(cands, function(a, b)
            if a._fav ~= b._fav then return a._fav end
            local ao, bo = a.online and true or false, b.online and true or false
            if ao ~= bo then return ao end
            return (a.fullName or a.label or "") < (b.fullName or b.label or "")
        end)

        local filter = strlower(self.search:GetText() or "")
        for _, r in ipairs(rows) do r:Hide() end

        local shown = 0
        local yOff = 0
        local sawFav, sepPlaced = false, false
        f.sep:Hide()
        for _, c in ipairs(cands) do
            local display = isBnet and c.label or c.fullName
            if filter == "" or strfind(strlower(display or ""), filter, 1, true) then
                shown = shown + 1
                local r = getRow(shown)

                -- Favourite star + row tint (hidden if this candidate can't be
                -- favourited, e.g. a B.net friend with no BattleTag).
                if c._favBucket and c._favKey then
                    r.fav:Show()
                    local favCand = c
                    r.DoFav = function()
                        NK:ToggleFavorite(favCand, isBnet)
                        f:Repopulate()
                    end
                    if c._fav then
                        r.favTex:SetDesaturated(false); r.favTex:SetAlpha(1.0); r.bg:Show()
                    else
                        r.favTex:SetDesaturated(true); r.favTex:SetAlpha(0.35); r.bg:Hide()
                    end
                else
                    r.fav:Hide(); r.bg:Hide(); r.DoFav = nil
                end

                if isBnet then
                    local extra = c.currentChar and ("  |cff7f7f7f(" .. c.currentChar .. ")|r") or ""
                    r.nameFS:SetText((display or "?") .. extra)
                    if c.online then
                        r.nameFS:SetTextColor(0.4, 0.85, 0.4)   -- online: green
                    else
                        r.nameFS:SetTextColor(0.7, 0.7, 0.7)    -- offline: grey
                    end
                else
                    r.nameFS:SetText(display)
                    r.nameFS:SetTextColor(classColor(c.class))
                end

                local added = isBnet and NK:HasBnetRule(c.battleTag) or NK:HasRuleFor(c.name, c.realm)
                if added then
                    r.nick:Hide(); r.add:Hide(); r.addedFS:Show()
                    r.DoAdd = nil
                else
                    r.addedFS:Hide(); r.nick:Show(); r.add:Show()
                    local suggest
                    if isBnet then
                        suggest = (c.label and c.label:match("^(.-)#")) or c.label or ""
                    else
                        suggest = c.name
                    end
                    r.nick:SetText(suggest)
                    local cand = c
                    r.DoAdd = function()
                        local nick = r.nick:GetText()
                        if not nick or nick:gsub("%s", "") == "" then return end
                        if isBnet then
                            NK:AddBnet(cand.battleTag, cand.label, nick)
                        else
                            NK:AddTyped("exact", cand.fullName, nick, cfg.tag)
                        end
                        f:Repopulate()  -- reflect the new "Added" state
                    end
                end

                -- Blizzard-style divider between the favourites block and the rest.
                if c._fav then
                    sawFav = true
                elseif sawFav and not sepPlaced then
                    f.sep:ClearAllPoints()
                    f.sep:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -(yOff + 4))
                    f.sep:SetPoint("TOPRIGHT", content, "TOPRIGHT", -6, -(yOff + 4))
                    f.sep:Show()
                    sepPlaced = true
                    yOff = yOff + SEP_H
                end

                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", 0, -yOff)
                r:SetPoint("TOPRIGHT", 0, -yOff)
                r:Show()
                yOff = yOff + ROW_H
            end
        end

        content:SetHeight(mmax(1, yOff))
        self.empty:SetShown(shown == 0)
        self.empty:SetText(cfg.emptyText or L["No characters found."])
    end

    return f
end

-- Public entry point — called by the "Add from..." buttons on the page.
function DF.OpenNicknamePicker(sourceKey)
    local cfg = SOURCES[sourceKey]
    if not cfg then return end
    if not picker then picker = buildPicker() end

    -- Per-source empty-list message.
    if sourceKey == "guild" and not IsInGuild() then
        cfg.emptyText = L["You are not in a guild."]
    elseif sourceKey == "group" then
        cfg.emptyText = L["No group members found."]
    elseif sourceKey == "bnet" then
        cfg.emptyText = L["No B.net friends found."]
    else
        cfg.emptyText = L["No characters found."]
    end

    picker.cfg = cfg
    picker.title:SetText(L["Add from"] .. " " .. cfg.label)
    picker.search:SetText("")
    picker.searchPH:Show()
    picker:Show()
    picker:Repopulate()
end
