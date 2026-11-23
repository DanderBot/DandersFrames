-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's.
-- Take the parent's table from the global it publishes (see GUI/Panel.lua).
local DF = DandersFrames
local GUI = DF and DF.GUI
if not GUI then return end
local UFO = GUI.UnitFrameOptions
local TL = DF.TestLabels
if not (UFO and TL) then return end
local L = DF.L

local ipairs, pairs, type, next = ipairs, pairs, type, next

-- ============================================================
-- INDICATOR INFO ON THE UNIT FRAME PREVIEWS
-- Test mode's "Indicator Info" (TestMode/Labels.lua) on the units test mode's
-- previews (DandersFrames_UnitFrames/Preview.lua, Boss.lua): the element under
-- the cursor is marked and named, and a left click opens ITS UNIT's page for it
-- (uf_<unit>_<kind>), at the element's section when that unit's page has it.
-- Wired through Labels.lua's extension seam only:
--   * a frame source ("units") over every preview frame, boss slots included,
--     wanting labels while the units test mode is on with its own Indicator Info
--     switch (the units test settings' testShowLabels);
--   * `accepts` drops every element the unit has no page for (Missing Buffs and
--     the party Rested ZZZ never, a Class Power bar only on the player...), so
--     the region under it answers instead;
--   * `open` replaces the group navigation: never a party / raid mode switch;
--     the shared link action switches to the unit page, scrolls, expands, flashes;
--   * the unit-frame-only elements (portrait, cast bar, class power, the unit
--     icons, the dragon and the class border) are targets of their own.
-- Labels.lua loads before this file (TOC); the previews call
-- DF.TestLabels:HandleClick from their own OnClick (Preview.lua).
-- ============================================================

local SOURCE_ID = "units"

-- Element identity colours: the ones Labels.lua gives bars and icons.
local C_BARS  = { 0.45, 0.80, 0.74 }
local C_ICONS = { 0.93, 0.85, 0.45 }

-- ============================================================
-- TARGET KEY -> UNIT PAGE
-- kind      the unit page kind (UFO.pagesByUnit[unit][kind])
-- sections  section header (L key) -> the page record's card key. A section is
--           passed only when that unit's page shows the card; else none.
-- A key not listed has no unit page at all (Missing Buffs, the party Rested ZZZ):
-- never labelled on a preview.
-- ============================================================
local function icon(field, title)
    return { kind = "icons", sections = { [title] = "icons_" .. field } }
end

UFO.LABEL_KINDS = {
    -- The group targets (Labels.lua TARGETS).
    buff = { kind = "buffs" },
    debuff = { kind = "debuffs" },
    defensive = { kind = "defensive" },
    ad = { kind = "auradesigner" },
    role = icon("roleIcon", "Role Icon"),
    leader = icon("leaderIcon", "Leader Icon"),
    raidTarget = icon("raidTargetIcon", "Target Marker Icon"),
    readyCheck = icon("readyCheckIcon", "Ready Check Icon"),
    ping = icon("pingIcon", "Ping Icon"),
    summon = icon("summonIcon", "Summon Icon"),
    resurrection = icon("resurrectionIcon", "Resurrection Icon"),
    phased = icon("phasedIcon", "Phased Icon"),
    afk = icon("afkIcon", "AFK Icon"),
    vehicle = icon("vehicleIcon", "Vehicle Icon"),
    raidRole = icon("raidRoleIcon", "Raid Role Icon (MT/MA)"),
    bgCarrier = icon("bgCarrierIcon", "BG Carrier Icon"),
    combat = icon("combatIcon", "Combat Icon"),
    text = { kind = "text" },
    absorb = { kind = "absorbs", sections = { ["Absorb Shield"] = "absorbs_shield" } },
    healabsorb = { kind = "absorbs", sections = { ["Heal Absorb"] = "absorbs_healabsorb" } },
    healpred = { kind = "healpred" },
    missinghealth = { kind = "health", sections = { ["Missing Health"] = "health_missing" } },
    power = { kind = "resource" },
    health = { kind = "health" },
    dispel = { kind = "dispel", sections = { ["Dispel Symbol"] = "dispel_symbol" } },
    frame = { kind = "frame" },
    -- The unit-frame-only targets (UF_TARGETS below).
    ufPortrait = { kind = "portrait" },
    ufCastBar = { kind = "castbar" },
    ufClassPower = { kind = "classpower" },
    ufResting = { kind = "unitIcons", sections = { ["Resting Icon"] = "resting_icon" } },
    ufPvP = { kind = "unitIcons", sections = { ["PvP Icon"] = "pvp_icon" } },
    ufClassification = { kind = "unitIcons", sections = { ["Elite / Rare"] = "elite_rare" } },
    ufDragon = { kind = "unitIcons", sections = { ["Elite Dragon"] = "class_decorations" } },
    ufClassBorder = { kind = "unitIcons", sections = { ["Classification Border"] = "class_decorations" } },
}

-- The unit page records (PageData.lua, GENERATED). Read through UFO's own maps
-- once the settings window has built its pages (Pages.lua UFO.BuildPages), and
-- straight from the data before that: the previews can be up with the window
-- never opened, and the page ids are the same either way (UFO.PageName).
local function Data() return UFO.data or DF.UnitFramePageData end

local function PageRec(kind)
    local rec = UFO.pageByKind and UFO.pageByKind[kind]
    if rec then return rec end
    for _, r in ipairs(Data() and Data().pages or {}) do
        if r.kind == kind then return r end
    end
end

local function PageId(unit, kind)
    local pages = UFO.pagesByUnit and UFO.pagesByUnit[unit]
    if pages and next(pages) ~= nil then return pages[kind] end
    local rec = PageRec(kind)
    if rec and not rec.later and rec.units and rec.units[unit] then return UFO.PageName(unit, kind) end
end

-- The page and section a click on `key` opens on `unit`'s preview: page id (nil
-- when the unit has no such page) and the section text (nil when that unit's page
-- does not show it). `section` is the localised text Labels.lua resolved.
function UFO.LabelTarget(unit, key, section)
    local e = UFO.LABEL_KINDS[key]
    if not (e and unit) then return nil end
    local page = PageId(unit, e.kind)
    if not page then return nil end
    local out
    if section and e.sections then
        local rec = PageRec(e.kind)
        for lkey, card in pairs(e.sections) do
            if L[lkey] == section and rec and UFO.CardAllowed(rec, unit, card) then out = section end
        end
    end
    return page, out
end

-- "Target > Health Bar": the unit (its tab) and the page title, as the settings
-- window shows them.
function UFO.LabelCrumb(unit, key)
    local e = UFO.LABEL_KINDS[key]
    local rec = e and PageRec(e.kind)
    if not (rec and unit) then return nil end
    return UFO.UnitLabel(unit) .. " > " .. L[rec.title]
end

-- ============================================================
-- THE UNIT-FRAME-ONLY TARGETS
-- Each region is measured where it draws, outside the frame or not (the dragon
-- pieces, a detached cast bar, an outside portrait); smallest region under the
-- cursor wins, so each beats the health bar it overlaps. The portrait's and cast
-- bar's K.Border edges draw OUTSIDE their frames and are not part of the region.
-- ============================================================
local function text(key) return function() return L[key] end end

local function crumbOf(kind)
    return function()
        local rec = PageRec(kind)
        if not rec then return "" end
        for _, cat in ipairs(Data() and Data().categories or {}) do
            if cat.id == rec.category then return L[cat.label] .. " > " .. L[rec.title] end
        end
        return L[rec.title]
    end
end

local function icons(f) return type(f.dfUFIcons) == "table" and f.dfUFIcons or nil end

UFO.LABEL_TARGETS = {
    { key = "ufPortrait", color = C_BARS, kind = "portrait", label = text("Portrait"),
      find = function(f, add) add(f.dfUFPortrait) end },
    { key = "ufCastBar", color = C_BARS, kind = "castbar", label = text("Cast Bar"),
      find = function(f, add) add(f.dfUFCastBar) end },
    { key = "ufClassPower", color = C_BARS, kind = "classpower", label = text("Class Power"),
      find = function(f, add) add(f.dfUFClassPower) end },
    { key = "ufResting", color = C_ICONS, kind = "unitIcons", label = text("Resting Icon"),
      section = text("Resting Icon"),
      find = function(f, add) local i = icons(f); if i then add(i.resting) end end },
    { key = "ufPvP", color = C_ICONS, kind = "unitIcons", label = text("PvP Icon"),
      section = text("PvP Icon"),
      find = function(f, add) local i = icons(f); if i then add(i.pvp) end end },
    { key = "ufClassification", color = C_ICONS, kind = "unitIcons", label = text("Elite / Rare"),
      section = text("Elite / Rare"),
      find = function(f, add) local i = icons(f); if i then add(i.classification) end end },
    -- Each drawn piece on its own (Indicators.lua NewDragon: tex[side][piece]); a
    -- hidden piece, or the whole dragon hidden, drops out.
    { key = "ufDragon", color = C_ICONS, kind = "unitIcons", label = text("Elite Dragon"),
      section = text("Elite Dragon"),
      find = function(f, add)
          local d = icons(f) and icons(f).dragon
          if type(d) ~= "table" or type(d.tex) ~= "table" then return end
          for _, side in ipairs({ "RIGHT", "LEFT" }) do
              local pieces = d.tex[side]
              if type(pieces) == "table" then
                  for _, piece in ipairs({ "TOP", "BOTTOM" }) do add(pieces[piece]) end
              end
          end
      end },
    -- Its four edges, not the frame-sized holder: the holder would claim the whole
    -- frame from the frame fallback.
    { key = "ufClassBorder", color = C_ICONS, kind = "unitIcons", label = text("Classification Border"),
      section = text("Classification Border"),
      find = function(f, add)
          local b = icons(f) and icons(f).classBorder
          if type(b) ~= "table" or type(b.edges) ~= "table" then return end
          for _, side in ipairs({ "top", "bottom", "left", "right" }) do add(b.edges[side]) end
      end },
}

for _, t in ipairs(UFO.LABEL_TARGETS) do
    t.page = UFO.PageName("player", t.kind)   -- nominal: the source's open picks the unit's
    t.crumb = crumbOf(t.kind)
    TL:RegisterTarget(t)
end

-- ============================================================
-- THE FRAME SOURCE
-- ============================================================
local function UF() return DF.UnitFrames end

local function Preview()
    local uf = UF()
    return uf and uf.Preview or nil
end

-- Every preview frame, shown or not (Labels.lua tears down through this too).
local function EachPreview(fn)
    local uf = UF()
    local P = uf and uf.Preview
    if P and type(P.frames) == "table" then
        for _, unit in ipairs(uf.SPAWNED_UNITS or {}) do
            local f = P.frames[unit]
            if f then fn(f) end
        end
    end
    local B = uf and uf.Boss
    if B and type(B.preview) == "table" then
        for i = 1, (uf.BOSS_COUNT or 8) do
            local f = B.preview[i]
            if f then fn(f) end
        end
    end
end

local function Wants()
    local P = Preview()
    if not (P and P.shown and P.IsTestMode and P:IsTestMode()) then return false end
    return P:TestOn("testShowLabels")
end

local function UnitOf(frame) return frame and frame.dfUFUnit end

-- Window up, then the shared link action owns the tab switch (into the Unit
-- Frames module and onto the unit), scroll, expand and flash. Never a party /
-- raid mode switch.
local function Open(frame, target, section)
    local page, sec = UFO.LabelTarget(UnitOf(frame), target.key, section)
    if not page then return end
    if not (DF.GUIFrame and DF.GUIFrame:IsShown()) then
        if DF.ToggleGUI then DF:ToggleGUI() end
    end
    if not (DF.GUIFrame and DF.GUIFrame:IsShown()) then return end
    if GUI.LinkToSetting then
        GUI:LinkToSetting({
            page = page,
            section = sec,
            flash = sec and { fill = false, border = true } or false,
        })
    elseif GUI.SelectTab then
        GUI.SelectTab(page)
    end
end

TL:RegisterFrameSource({
    id = SOURCE_ID,
    each = EachPreview,
    wants = Wants,
    open = Open,
    accepts = function(frame, target)
        return UFO.LabelTarget(UnitOf(frame), target.key) ~= nil
    end,
    crumb = function(frame, target)
        return UFO.LabelCrumb(UnitOf(frame), target.key)
    end,
})

-- ============================================================
-- KEEPING THE MARKS CURRENT
-- The party / raid refreshes rebuild the region list; the previews repaint on
-- their own path, so every repaint, show and hide asks for one rebuild on the
-- next tick (a frame painted this tick has no rect yet; Labels.lua's settle
-- retry covers a tick not being enough). Coalesced: a slider drag repaints every
-- frame.
-- ============================================================
local pending = false
local function Relabel()
    if pending or not DF.UpdateTestLabels then return end
    pending = true
    C_Timer.After(0, function()
        pending = false
        if DF.UpdateTestLabels then DF:UpdateTestLabels() end
    end)
end

local function Hook()
    local uf = UF()
    local P = uf and uf.Preview
    if not P or UFO._labelsHooked or not hooksecurefunc then return end
    UFO._labelsHooked = true
    for _, name in ipairs({ "Show", "Hide", "Refresh" }) do
        if type(P[name]) == "function" then hooksecurefunc(P, name, Relabel) end
    end
    local B = uf.Boss
    if B and type(B.PreviewRefresh) == "function" then hooksecurefunc(B, "PreviewRefresh", Relabel) end
end
Hook()
