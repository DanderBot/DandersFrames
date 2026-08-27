local addonName, DF = ...

-- ============================================================
-- THE DANDERSFRAMES GUI HOST
-- ------------------------------------------------------------
-- The widget toolkit lives in DandersUI, an embedded library loaded from
-- Libs\DandersUI by the TOC. This file creates DandersFrames' HOST on it and
-- supplies the hooks the shared factories call back into: locale, fonts, the
-- auto-profile override semantics, the settings search index, and the
-- live-refresh throttle.
--
-- Everything below the host block is DandersFrames-only chrome that never
-- belonged in a shared kit: the party/raid mode flag, the New badges, the
-- section-prefix registry, the designer-preset prompts, and the four /df debug
-- probes.
--
-- ☠ DF.GUI is now a PROXY. Reads fall through to the pack via __index; writes
-- land on the host and SHADOW the pack. That is how the options companion can
-- keep defining GUI:CreateCheckbox / CreateButton / CreateEditBox / CreateLabel
-- with their positional signatures on top of the pack's native ones.
-- ============================================================
local L = DF.L
local format, rawget, rawset, tostring, type = string.format, rawget, rawset, tostring, type
local setmetatable = setmetatable

-- ============================================================
-- COLOUR-PICKER STORE
-- ------------------------------------------------------------
-- The pack asks for a store with three fields -- saved, recent, square -- and
-- knows nothing about our SavedVariables. This proxy maps those three names onto
-- the keys the picker has always written, so the on-disk layout stays
-- byte-identical and no migration is needed.
--
-- ☠ DandersFramesDB_v2 is read AT ACCESS TIME, not captured: this file loads
-- before the SV table is guaranteed to exist, and a captured nil would strand
-- every read on an empty table forever. A write creates the SV table if it is
-- still missing, mirroring the picker's own save guard.
--
-- Anything OTHER than the three mapped names lives on the proxy itself, so the
-- pack can keep scratch state next to the persistent fields without it leaking
-- into SavedVariables.
local PICKER_KEYS = {
    saved  = "colorPickerSaved",
    recent = "colorPickerRecent",
    square = "colorPickerSquare",
}
local pickerStore = setmetatable({}, {
    __index = function(_, key)
        local mapped = PICKER_KEYS[key]
        if not mapped then return nil end
        return DandersFramesDB_v2 and DandersFramesDB_v2[mapped]
    end,
    __newindex = function(t, key, value)
        local mapped = PICKER_KEYS[key]
        if not mapped then return rawset(t, key, value) end
        if not DandersFramesDB_v2 then DandersFramesDB_v2 = {} end
        DandersFramesDB_v2[mapped] = value
    end,
})

-- ☠ Declared on its own line first. `local GUI = LibStub(...):NewHost(...)`
-- would put the closures below in the scope BEFORE the local exists, so every
-- one of them (accentFor, getOverrideState, interceptWrite) would capture a nil
-- global instead of the host.
local GUI
GUI = LibStub("DandersUI-1.0"):NewHost("DandersFrames", {
    L = L,

    print = function(msg) DF:Say(tostring(msg)) end,
    error = function(msg) DF:DebugError("GUI", "%s", tostring(msg)) end,

    -- ---- fonts -------------------------------------------------
    getFontSetting = function()
        if not DF.db then return "DF Roboto SemiBold", "" end
        return DF.db.settingsFont or "DF Roboto SemiBold", DF.db.settingsFontOutline or ""
    end,
    resolveFontPath = function(name) return DF:GetFontPath(name) end,
    -- Returns true when it handled the write. SafeSetFont builds the
    -- multi-alphabet family, which is the whole reason DFFont inheritors do not
    -- render CJK as boxes.
    safeSetFont = function(obj, name, size, flags)
        if not DF.SafeSetFont then return false end
        DF:SafeSetFont(obj, name, size, flags)
        return true
    end,
    fontFamily = function(path, outline, size)
        return DF.GetSettingsFontFamilyName and DF:GetSettingsFontFamilyName(path, outline, size)
    end,

    -- ---- chrome ------------------------------------------------
    getScale = function()
        local ws = DF.GetWindowState and DF:GetWindowState()
        return (ws and ws.scale) or 1
    end,
    -- A mover belongs to the thing it moves, so its pole is pinned rather than
    -- following whichever page the window happens to be showing.
    accentFor = function(isRaid) return GUI.GetThemeColorFor(isRaid) end,
    onPopupOpen = function() DF:ClearSettingHighlights() end,

    -- ---- auto-profile override semantics ------------------------
    -- Four states, not three. A RUNTIME overlay (an active auto layout driving
    -- the live raid frames outside an editing session) shows the star and the
    -- global value but must NOT offer a reset -- the layout has to be edited
    -- instead. Folding it into "overridden" would show a button that cannot work.
    getOverrideState = function(db, key)
        if not key or type(key) ~= "string" then return "none" end
        if GUI.SelectedMode ~= "raid" then return "none" end
        local AP = DF.AutoProfilesUI
        if not AP then return "none" end
        if db and rawget(db, "_skipOverrideIndicators") then return "none" end
        local editing = AP:IsEditing()
        local runtime = AP:IsOverriddenByRuntime(key)
        if not editing and not runtime then return "none" end
        if runtime and not editing then
            return "runtime", AP:GetRuntimeGlobalValue(key)
        end
        if AP:IsSettingOverridden(key) then
            return "overridden", AP:GetGlobalValue(key)
        end
        return "editing", AP:GetGlobalValue(key)
    end,

    -- ...and the OTHER comparison, which is not an override at all. The three
    -- hooks around it ask "does this differ from the auto-layout global"; this
    -- one asks "does this differ from the value DandersFrames SHIPS", which is
    -- true in party mode as readily as in raid and has nothing to do with auto
    -- layouts. Read-only. DF.Defaults answers false for any table it cannot
    -- resolve, so an aura proxy or a scratch table simply never dots.
    isModifiedDefault = function(db, key)
        local D = DF.Defaults
        if not (D and key) then return false end
        return D:IsModified(db, key)
    end,

    -- Drops the layout override AND writes the true global back into the live
    -- table, so the widget can redraw from db[key] straight after.
    resetOverride = function(db, key)
        local AP = DF.AutoProfilesUI
        if not AP or not key then return nil end
        AP:ResetProfileSetting(key)
        local globalVal = AP:GetGlobalValue(key)
        if db then db[key] = globalVal end
        return globalVal
    end,

    -- True when the write was redirected to the baseline, in which case the
    -- caller skips its live refresh (repainting an unchanged overlay).
    -- The raid-mode gate lives HERE, not in the pack.
    interceptWrite = function(db, key, value)
        if not key then return false end
        -- ☠ THE UNDO CAPTURE COMES FIRST, BEFORE THE REDIRECT DECISION. This hook
        -- is the only moment in the write where db[key] still holds the OLD
        -- value, and the answer below does not change that -- a redirected write
        -- simply never reaches onSettingWritten, so its capture is never
        -- committed. Taking the capture after the redirect check would leave
        -- every raid-mode write under a running layout uncapturable.
        local SU = DF.SettingsUndo
        if SU then SU:OnInterceptWrite(db, key, value) end
        if GUI.SelectedMode ~= "raid" then return false end
        local AP = DF.AutoProfilesUI
        if not AP then return false end
        return AP:HandleRuntimeWrite(key, value) and true or false
    end,

    -- Record the override when a layout is being edited. The plain write has
    -- already landed in db[key] by the time this runs.
    --
    -- `label` is the widget's display name, forwarded by the kit for anything
    -- that shows the user what changed. The auto-profile half ignores it.
    --
    -- `applyFn` is the widget's own commit callback, by reference. The undo
    -- engine stores it on the entry and replays it, because for a great many
    -- settings that callback IS the apply -- the generic sweep alone moves the
    -- number and leaves the frames where they were. The auto-profile half
    -- ignores this one too.
    --
    -- ⚠ AUTO-PROFILE FIRST, UNDO SECOND. The layout recorder is the SEMANTIC
    -- half of the write and its behaviour is unchanged by anything below it;
    -- the undo engine only observes. Reordering them would put a bookkeeping
    -- concern in front of the one that decides what the profile stores.
    onSettingWritten = function(db, key, value, label, applyFn)
        local AP = DF.AutoProfilesUI
        if AP and key and AP:IsEditing() then
            AP:SetProfileSetting(key, value)
        end
        local SU = DF.SettingsUndo
        if SU then SU:OnSettingWritten(db, key, value, label, applyFn) end
    end,

    onIndicatorsRefreshed = function()
        local AP = DF.AutoProfilesUI
        if AP and AP.RefreshTabOverrideStars then AP:RefreshTabOverrideStars() end
    end,

    -- ---- live refresh + drag bookkeeping ------------------------
    -- BOTH refresh hooks land on the same coalescing sink now, one frame apart
    -- from nothing: ThrottledUpdateAll is a deprecated alias for UpdateAll, and
    -- UpdateAll is an arm-stub (Core\ApplyScheduler.lua), so however many times
    -- a page fires either of these inside one rendered frame, one pass runs.
    --
    -- The drag pair is REFCOUNTED host-side (Core.lua): the widget kit is not the
    -- only surface that holds a drag open -- the colour picker's bars do too --
    -- and every start must be matched by exactly one stop. onDragStop no longer
    -- performs the general full update; the kit's release path asks for that
    -- through refreshNow.
    refresh    = function() DF:ThrottledUpdateAll() end,
    refreshNow = function() DF:UpdateAll() end,
    --
    -- The undo engine rides the same pair, and for the same reason it is
    -- refcounted: a slider fires onSettingWritten once per step crossed, so
    -- "one entry per drag" is a question about the gesture, not about the writes.
    onDragStart = function(lightFn, name, previewMode)
        DF:OnSliderDragStart(lightFn, name, previewMode)
        local SU = DF.SettingsUndo
        if SU then SU:OnDragStart() end
    end,
    onDragStop  = function()
        DF:OnSliderDragStop()
        local SU = DF.SettingsUndo
        if SU then SU:OnDragStop() end
    end,
    isDragging  = function() return DF.sliderDragging and true or false end,

    -- ---- settings search ----------------------------------------
    -- Search lives in the options companion, so BOTH the table and the method
    -- are guarded: a mismatched pair would find the table and not the function.
    registerSearch = function(kind, label, key, widget, meta)
        local Search = DF.Search
        if not Search then return end
        meta = meta or {}
        local entry
        if kind == "slider" and Search.RegisterSlider then
            entry = Search:RegisterSlider(label, key, meta.minVal, meta.maxVal, meta.step, nil, meta.callback)
        elseif kind == "dropdown" and Search.RegisterDropdown then
            entry = Search:RegisterDropdown(label, key, meta.options, nil, meta.callback)
        end
        if entry then
            widget.searchEntry = entry
            -- Hand the entry a reference back so an inline search result can read
            -- the tooltip the caller sets on the widget after the factory returns.
            if Search.LinkSourceWidget then Search:LinkSourceWidget(widget) end
        end
    end,

    -- ---- options-module bridges ---------------------------------
    -- Consumed by pack code that lives in the load-on-demand options manifest
    -- (Libs\DandersUI\DandersUI_Options.xml). Wiring them from the RESIDENT host
    -- is deliberate: a host is created once and its hooks table is never
    -- rebuilt, so the bridges have to exist before the companion loads. Until
    -- that pack code lands they are simply never called.

    -- Persistent colour-picker memory. See the proxy at the top of this file:
    -- the three field names the pack uses map onto the SavedVariables keys the
    -- picker has always written.
    pickerStore = function() return pickerStore end,

    -- The colour picker's window title. The pack may not name whoever embeds it
    -- and has no locale key of its own, so it titles the frame from here or
    -- leaves the title blank. Resolved on the FIRST open (the frame is built
    -- once), which is why it is a function: L is swapped wholesale by the
    -- language override, and a plain string captured at host creation would
    -- freeze the title in whatever locale was live at login.
    pickerTitle = function() return L["DandersFrames Color Picker"] end,

    -- Category debug printer, so pack code logs through /df debug like ours does.
    debug = function(cat) return DF:MakeDebugPrinter(cat) end,

    -- The settings table a settings group evaluates its children's hideOn /
    -- disableOn / refreshContent predicates against: whichever mode the window
    -- is currently editing. Every predicate in the pages takes exactly this
    -- table, so it has to follow SelectedMode rather than being pinned.
    getSettingsDB = function() return DF.db and DF.db[GUI.SelectedMode] end,

    -- A collapsible settings group opened or closed. The Aura Designer page owns
    -- its own layout and has to re-run it either way; BuildPage pages re-flow
    -- themselves and need nothing here.
    onSectionToggled = function(key, expanded)
        if DF.AuraDesigner_RefreshPage then DF:AuraDesigner_RefreshPage() end
    end,

    -- Jump the settings scroll to a section header and hand back the widget it
    -- landed on, for the caller to flash. Search lives in the options companion,
    -- so both the table and the method are guarded (same reason as registerSearch).
    scrollToSection = function(page, section)
        if DF.Search and DF.Search.ScrollToSection then
            return DF.Search:ScrollToSection(page, section)
        end
    end,
})
DF.GUI = GUI

-- ============================================================
-- THE SURFACE STYLE -- this consumer's settings surfaces are ROUND.
--
-- ONE line, and it is the whole of "DandersFrames goes rounded". Every shell in
-- the pack that can wear either shape -- the popout, the feature row's plate,
-- the settings group box -- asks the HOST what shape this consumer is, and this
-- is where the answer is given. The window's own chrome reads it back through
-- GUI:GetSurfaceStyle (DandersFrames_Options/GUI/Panel.lua).
--
-- ☠ DECLARED ON THE HOST, NEVER IN THE LIBRARY. UI.SurfaceStyle is a definition
-- and rounds nothing on its own; a consumer that never makes this call keeps the
-- square backdrop it has always had. DandersMover never makes it, which is why
-- the mover editor and its own popout are still square while this window is not
-- -- and it is why the two addons can share one copy of the kit and still look
-- like two different things on purpose.
--
-- ⚠ RESIDENT, NOT IN THE COMPANION, even though only the companion draws
-- settings UI. A host is created once, here, and the style is a property OF that
-- host -- putting it behind the load-on-demand boundary would mean the shape of
-- the shell depended on load order, which is the kind of thing that produces a
-- square group box in a round window exactly once and then never reproduces.
GUI:SetSurfaceStyle(GUI.SurfaceStyle)




-- "/df debug guiwidth" — width ground truth for the page on screen: every top-level child and
-- every settings-group child with its live width, flagging any that is non-positive or
-- narrower than its group allows.
-- Use it to TELL APART the two causes of truncated label text, which look identical:
--   * a real width fault  -> frames show up flagged here;
--   * a stale FontString wrap -> every width reads correct and the count is 0, yet the
--     text is visibly ellipsised (and scrolling the window snaps it back, because that
--     re-renders the string). That is CreateLabel's Reflow case, not a sizing bug.
-- Recorded because the second one cost two wrong fixes before this dump ruled out the first.
function GUI:DebugDumpWidths()
    local page = GUI.CurrentPageName and GUI.Pages[GUI.CurrentPageName]
    if not page or not page.children then
        DF:Say("GUI width", "no built page on screen", "WARN")
        return
    end
    local content = GUI.contentFrame and GUI.contentFrame:GetWidth() or -1
    local o = DF:Out("GUI Width", ("page '%s'"):format(GUI.CurrentPageName))
    o:Section("Widths")
    o:Field("content frame", ("%.0f"):format(content), content > 0 and "GOOD" or "BAD")
    o:Field("scroll child", ("%.0f"):format(page.child and page.child:GetWidth() or -1), "NEUTRAL")

    o:Section("Widgets")
    local bad = 0
    local function flag(w, limit)
        if not w or w <= 0 then bad = bad + 1; return "|cffff4444 <== NON-POSITIVE|r" end
        if limit and w < limit - 1 then bad = bad + 1; return "|cffffcc00 <== NARROW|r" end
        return ""
    end
    for i, widget in ipairs(page.children) do
        if widget.isSettingsGroup then
            local gw = widget:GetWidth() or 0
            local inner = gw - (widget.padding or 10) * 2
            print(("  [%d] group  w=%.0f inner=%.0f col=%s shown=%s%s")
                :format(i, gw, inner, tostring(widget.layoutCol), tostring(widget:IsShown()), flag(gw)))
            for j, entry in ipairs(widget.groupChildren or {}) do
                local c = entry.widget
                local cw = c and c:GetWidth() or 0
                print(("      (%d) w=%.0f h=%.0f shown=%s%s")
                    :format(j, cw, entry.height or -1, tostring(c and c:IsShown()), flag(cw, inner)))
            end
        else
            local w = widget:GetWidth() or 0
            print(("  [%d] widget w=%.0f col=%s shown=%s%s")
                :format(i, w, tostring(widget.layoutCol), tostring(widget:IsShown()), flag(w)))
        end
    end
    o:Section("Result")
    o:Field("suspect frames", bad, bad > 0 and "WARN" or "GOOD")
    o:Siblings("guiwidth")
end

-- ☠ THE REGISTRY MUST BE COMPLETE BEFORE ANYTHING READS IT.
--
-- DF:SectionOwnsKey (Core/Profile.lua) resolves prefix collisions by LONGEST MATCHING
-- PREFIX ACROSS THE WHOLE REGISTRY. That is only correct if every page is present.
-- Registration used to happen inside CreateCopyButton, inside a page's builderFunc,
-- which GUI Panel's DoBuild calls only on the FIRST VISIT to that page -- and skips
-- entirely for a page disabled in the current mode.
--
-- So the answer depended on which tabs you had opened this session. Fresh login →
-- Auras → Debuffs, without ever opening Aura Filters: auras_filterdesigner is absent,
-- its debuffFilter* / debuffBlacklist prefixes are not there to out-rank the Debuffs
-- page's plain "debuff", and Reset Page wipes the user's entire debuff blacklist and
-- all six filter toggles. Open Aura Filters first and the identical click is safe.
-- Same shape on Copy to Raid and on DF:SyncLinkedSections.
--
-- Seeding it here fixes a second, quieter case too: DF:SyncLinkedSections runs from
-- DF:UpdateAll() in the MAIN addon, which can run with the options companion never
-- loaded -- in which case the registry was simply empty and linked sections silently
-- did not sync at all.
--
-- ⚠ THIS TABLE MUST STAY IN STEP WITH THE CreateCopyButton CALL SITES. It was
-- transcribed from them via the AST rather than by hand, and CreateCopyButton still
-- writes its own entry on build, so a page that drifts self-heals once visited -- but
-- a drifted entry re-opens exactly the bug above until then. If you add or change a
-- section, change it here too.
DF.SECTION_PREFIXES = {
    -- ⚠ buffFilterSelection is listed EXPLICITLY here rather than left to "buff":
    -- it does not share a prefix with the rest, and the page that shows the control
    -- must own the key it writes.
    auras_buffs                  = { "buff", "showBuffs", "directBuff", "buffFilterSelection" },
    auras_debuffs                = { "debuff", "showDebuffs", "directDebuff", "debuffBlacklist" },
    auras_defensiveicon          = { "defensiveIcon", "defensiveFilterSelection", "defensiveSortOrder", "defensiveDurationBar", "defensiveBar" },
    auras_dispel                 = { "dispel" },
    -- ☠ auras_filterdesigner OWNS NOTHING, and the empty table is the statement.
    -- It used to claim buffFilterSelection, debuffFilter*, debuffBlacklist and the
    -- directBuff*/directDebuff* switches, because it displayed all of them. It no
    -- longer displays ANY of them -- filter selection moved to the consumer pages --
    -- so every key went back to the page whose controls now show it.
    --
    -- A control must write where it reads: leaving a claim here would let Reset Page
    -- on the filter library silently rewrite the Buff Bar's and Debuff Bar's
    -- settings, and SectionOwnsKey resolves by LONGEST matching prefix across the
    -- WHOLE registry, so a stale long entry here would outrank the real owner's
    -- shorter one and win keys back invisibly.
    --
    -- What this page does edit is not per-mode at all: preset overrides are per
    -- PROFILE, custom filters are per ACCOUNT. Neither is reachable by Copy to Raid
    -- or Sync with Raid, which is why owning nothing here is correct rather than a
    -- gap to be filled in later.
    auras_filterdesigner         = {},
    auras_missingbuffs           = { "missingBuff" },
    bars_absorb                  = { "absorbBar", "healAbsorb" },
    bars_healpred                = { "healPrediction" },
    bars_health                  = { "healthColor", "healthOrientation", "healthTexture", "classColor", "smoothBars", "background", "missingHealth", "reducedMaxHealth" },
    bars_resource                = { "resourceBar" },
    display_fading               = { "rangeFade", "rangeCheck", "rangeUpdate", "oor", "fadeDead", "healthFade", "hf" },
    display_pets                 = { "pet" },
    display_tooltips             = { "tooltip" },
    display_visibility           = { "soloMode", "hidePlayerFrame", "restedIndicator" },
    general_fonts                = { "fontShadow" },
    general_frame                = { "frame", "permanentMover", "border", "anchor" },
    general_labels               = { "groupLabel" },
    general_pinnedframes         = { "pinnedFrames" },
    general_sorting              = { "sort", "useFrameSort", "selfPosition", "rolePriority", "classPriority" },
    indicators_highlights        = { "selectionHighlight", "hoverHighlight", "aggroHighlight", "aggro" },
    indicators_icons             = { "roleIcon", "leaderIcon", "raidTargetIcon", "readyCheckIcon", "summonIcon", "resurrectionIcon", "phasedIcon", "afkIcon", "vehicleIcon", "raidRoleIcon", "bgCarrierIcon", "combatIcon", "statusIconFont", "statusIconFontSize", "statusIconFontOutline" },
    indicators_personal_targeted = { "personalTargeted" },
    indicators_targetedlist      = { "targetedList" },
}

DF.SectionRegistry = DF.SectionRegistry or {}

-- Seed eagerly at load. CreateCopyButton overwrites its own entry on first build,
-- which is harmless (same value) and keeps the self-heal described above.
for pageId, prefixes in pairs(DF.SECTION_PREFIXES) do
    if DF.SectionRegistry[pageId] == nil then
        DF.SectionRegistry[pageId] = prefixes
    end
end
-- ============================================================
-- MODE + THEME (DandersFrames-only)
-- ============================================================
-- Track selected mode: "party" | "raid" | "clicks".
GUI.SelectedMode = "party"

local C_ACCENT = GUI.Colors.accent    -- party purple-blue
local C_RAID   = GUI.Colors.raid      -- raid orange

-- The theme colour for an EXPLICIT mode. Use this for any surface that belongs
-- to a mode rather than to whatever page the options window happens to be
-- showing -- movers, pinned containers -- so a raid surface stays orange while
-- the window is on a party page. GetThemeColor() below is the follow-the-window
-- variant.
local function GetThemeColorFor(isRaid)
    if isRaid then return C_RAID else return C_ACCENT end
end
GUI.GetThemeColorFor = GetThemeColorFor

-- ☠ A BARE FUNCTION, NOT A METHOD, and it has to stay one. 132 call sites in
-- this addon and the options companion do `local GetThemeColor = GUI.GetThemeColor`
-- at file scope and then call it with no self. Making it a method would nil out
-- every one of them at once, mostly inside hover handlers where the failure is
-- silent until someone points at the control.
--
-- It reads the HOST ACCENT rather than deriving from SelectedMode, so there is
-- exactly one source of truth: the pack's factories read self:GetAccent() and
-- this reads the same table. Every SelectedMode write site is paired with a
-- GUI:SetAccent (see Panel.lua / Controls.lua).
local function GetThemeColor()
    return GUI:GetAccent()
end
GUI.GetThemeColor = GetThemeColor

-- Seed the accent to match the initial mode.
GUI:SetAccent(GetThemeColorFor(false))

-- Registry of tabs that should show a "New" badge until opened.
-- Add tab IDs here for new features; the badge auto-hides once viewed.
-- Reset each release cycle to the tabs that are new since the last stable
-- (prior entries are persisted as seen and would otherwise show stale badges).
GUI.NewTabs = {
    ["text_designer"] = true,
    ["general_nicknames"] = true,
}

-- Registry of section headers (inside a tab) that should show a "New" badge
-- until the user visits the tab and then navigates away. Keyed by
-- "<tabName>.<sectionId>" so entries are unambiguous across tabs.
-- The badge is created by GUI:AddSectionNewBadge and cleared by SelectTab
-- when the user leaves the owning tab (persisted via seenSections).
GUI.NewSections = {
}

-- Live-tracked badges pending a "seen" mark, keyed by tabName → { key = badge }.
-- Populated by AddSectionNewBadge, drained by SelectTab on tab leave.
GUI.pendingSectionBadges = {}


-- Pages that remain fully accessible regardless of whether party or raid
-- mode is disabled via General settings. All other mode-specific tabs
-- are greyed out and non-interactive when viewing a disabled mode.
-- Auto Layouts is intentionally NOT whitelisted: it edits per-profile
-- settings that would have no effect if all frames are disabled.
GUI.AlwaysAccessiblePages = {
    ["general_settings"]             = true,  -- the toggles themselves
    ["profiles_manage"]              = true,
    ["profiles_importexport"]        = true,
    -- The changed-settings ledger. A REPORT about the stored profile, not a
    -- page of controls, so it says the same true thing whether or not the mode
    -- it describes is currently switched on -- and a user with a mode disabled
    -- is exactly the one being asked to paste it into a support thread.
    -- Literal rather than DF.ChangedSettings.PAGE_ID: that lives in the
    -- load-on-demand companion, which is not loaded when this file runs.
    ["profiles_changed"]             = true,
    ["debug_console"]                = true,
    ["indicators_targetedlist"]      = true,
    ["indicators_personal_targeted"] = true,
}


-- Re-declared from the pack: these probes measure the same pixel grid the
-- widget factories snap to, so they must use the SAME function, not a copy.
local PixelsPerUnit = GUI._priv.PixelsPerUnit
local S = GUI._state

-- ============================================================
-- Stamped once when this file loads, so it identifies THIS session (and therefore
-- this build) for the pixelcheck and gapcheck captures. Declared HERE, above the
-- first function that reads it: a local declared further down the file is not an
-- upvalue for a function defined above it -- the read would silently resolve to a
-- nil global and every capture would look like a new session.
local GAP_SESSION = date and date("%Y-%m-%d %H:%M:%S") or "?"

-- /df debug pixelcheck -- measure, don't guess
--
-- The "top border of a box goes missing until you scroll" bug has now been
-- diagnosed twice from reasoning about the layout and fixed twice, and it is
-- still here. The two remaining explanations look IDENTICAL in a screenshot:
--
--   (a) sub-pixel  -- the box's top edge lands between two device rows, so the
--                     1px line is filtered across both at half intensity;
--   (b) clipping   -- the box's top edge sits within a pixel of the ScrollFrame's
--                     own clip boundary, so the line is simply cut off.
--
-- Scrolling "fixes" both, which is exactly why the screenshot can't separate
-- them. This reports the numbers for the open page so the next change is aimed.
-- Debug output: deliberately raw, like the other /df debug dumps.
-- ============================================================

-- Signed distance from `v` (UI units) to the nearest whole device pixel.
local function PixelOffsetOf(v, ppu)
    if not v or not ppu then return nil end
    local px = v * ppu
    return px - math.floor(px + 0.5)
end

local function DescribeFrame(f)
    -- Prefer a human label so the output names the card, not "Frame".
    for _, key in ipairs({ "label", "title", "titleText", "Text", "header" }) do
        local o = f[key]
        if type(o) == "table" and o.GetText then
            local t = o:GetText()
            if t and t ~= "" then return t end
        end
    end
    if f.GetRegions then
        for _, r in ipairs({ f:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "FontString" then
                local t = r:GetText()
                if t and t ~= "" then return t end
            end
        end
    end
    return (f.GetObjectType and f:GetObjectType()) or "Frame"
end

-- Every SHOWN descendant carrying a border -- the only frames that can exhibit
-- this bug (a fill-only surface has no edge to lose).
--
-- Both mechanisms, deliberately. Testing edgeFile alone was right when that was
-- the only way a border got drawn; now that most surfaces own their four
-- textures instead, an edgeFile-only sweep would report a converted page as
-- having no bordered frames at all and the probe would quietly stop being able
-- to see the thing it exists to measure.
local function CollectBorderedFrames(root, out, depth)
    if not root or depth > 10 then return out end
    for _, child in ipairs({ root:GetChildren() }) do
        if child:IsShown() then
            local bd = child.GetBackdrop and child:GetBackdrop()
            if (bd and bd.edgeFile) or child._pxBorder then out[#out + 1] = child end
            CollectBorderedFrames(child, out, depth + 1)
        end
    end
    return out
end

-- What sits ON the box's top border row.
--
-- Geometry came back perfect on BOTH a broken and a working page (BOX 0/n,
-- top+0.00, edge=1.00px, nothing near the clip edge), so the difference is not
-- anything the box itself measures. The one thing that tracked the symptom was
-- how far the first box sits from the top: 62.7px on a page that loses its
-- border vs 76.8px on one that doesn't -- 14.1px apart, which at 1.4062 px/unit
-- is exactly the 10-unit group padding. A box that starts hard against whatever
-- is above it loses the line; one with a gap keeps it. That is the signature of
-- the row above covering it, so: find any sibling whose rect spans the box's top
-- border row, and report it with its frame level.
local function FindTopRowOverlaps(box)
    local out = {}
    local top, bL, bR = box:GetTop(), box:GetLeft(), box:GetRight()
    local parent = box:GetParent()
    if not (top and bL and bR and parent) then return out end
    -- ~1.5 device px expressed in UI units: the border row plus a hair.
    local band = 1.5 / (PixelsPerUnit(box) or 1)
    for _, sib in ipairs({ parent:GetChildren() }) do
        if sib ~= box and sib.IsShown and sib:IsShown() then
            local sT, sB, sL, sR = sib:GetTop(), sib:GetBottom(), sib:GetLeft(), sib:GetRight()
            if sT and sB and sL and sR
                and sB <= top + band and sT >= top - band   -- spans the border row
                and sR > bL and sL < bR then                -- and overlaps horizontally
                out[#out + 1] = ("%s(lvl%d)"):format(
                    DescribeFrame(sib):sub(1, 16), sib:GetFrameLevel() or 0)
            end
        end
    end
    return out
end

function GUI.PixelCheck()
    local page, pageName
    for name, p in pairs(GUI.Pages or {}) do
        if p.IsShown and p:IsShown() then page, pageName = p, name; break end
    end
    if not page then
        DF:Say("Pixel check", "no settings page is open", "WARN")
        return
    end

    local ppu = PixelsPerUnit(page)
    if not ppu then
        DF:Say("Pixel check", "scale unresolved — is the window shown?", "WARN")
        return
    end

    local scroll = page.GetVerticalScroll and page:GetVerticalScroll() or 0
    local scrollOff = PixelOffsetOf(scroll, ppu)
    local clipTop = page:GetTop()

    local o = DF:Out("Pixel Check", ("page %s"):format(tostring(pageName)))
    o:Section("Scale")
    o:Field("effective scale", ("%.4f"):format(page:GetEffectiveScale() or 0), "NEUTRAL")
    o:Field("px per unit", ("%.4f"):format(ppu), "NEUTRAL")

    o:Section("Scroll")
    -- Reported, not judged. This used to print a red NOT SNAPPED when the offset
    -- was off-grid, back when the scroll offset was quantised and being off-grid
    -- meant something had gone wrong. Nothing quantises it now -- a 2px border
    -- draws the same ink at any offset -- so an off-grid figure here is the
    -- normal state of a scrolled page, and flagging it as a fault sends the next
    -- person reading this output after a bug that is not there.
    o:Field("offset", ("%.3f  (%.2f px off grid)"):format(scroll, scrollOff or 0), "NEUTRAL")
    o:Line("Off-grid here is expected — nothing quantises the scroll offset.", "NEUTRAL")

    -- THE CLIP BOUNDARY ITSELF. Earlier runs measured each box's DISTANCE to this
    -- edge but never whether the edge is on-grid. A ScrollFrame clips to its own
    -- rect, so if that rect's top sits on a fractional device row the cut takes a
    -- partial row off whatever is nearest it -- which is exactly the reported
    -- pattern: pages whose boxes start at the top lose the border, pages with a
    -- gap do not. The scroll child is included because content is positioned
    -- against it, so its phase is what every box inherits.
    local dPageTop = PixelOffsetOf(page:GetTop(), ppu)
    local dPageBot = PixelOffsetOf(page:GetBottom(), ppu)
    local dPageH   = PixelOffsetOf(page:GetHeight(), ppu)
    -- Flag EITHER edge. This used to test only the top, so it printed
    -- "bot-0.38" on every run for weeks and never once marked it -- and an
    -- unflagged number in a wall of numbers is an invisible one. The bottom
    -- edge clips whatever rests against it just as hard as the top does, which
    -- is the entire See-Also footer bug.
    local badTop = dPageTop and math.abs(dPageTop) > 0.05
    local badBot = dPageBot and math.abs(dPageBot) > 0.05
    o:Section("Viewport", "the clip edge")
    o:Field("offsets", ("top%+.2f  bot%+.2f  h%+.2f"):format(dPageTop or 0, dPageBot or 0, dPageH or 0),
        (badTop or badBot) and "BAD" or "GOOD")
    if badTop or badBot then
        o:Line(("Clip edge OFF-GRID (%s) — it shaves a partial row off whatever rests against it."):format(
            badTop and (badBot and "top and bottom" or "top") or "bottom"), "BAD")
    end
    local kid = page.child or (page.GetScrollChild and page:GetScrollChild())
    if kid then
        local kppu = PixelsPerUnit(kid) or ppu
        local kidBad = math.abs(PixelOffsetOf(kid:GetTop(), kppu) or 0) > 0.05
        o:Field("scroll child", ("top%+.2f  w%+.2f"):format(
            PixelOffsetOf(kid:GetTop(), kppu) or 0, PixelOffsetOf(kid:GetWidth(), kppu) or 0),
            kidBad and "BAD" or "GOOD")
        if kidBad then
            o:Line("Content is positioned against this, so every box inherits its phase.", "BAD")
        end
    end

    -- "Is it the section BOXES or the controls inside them?" is the question the
    -- first version of this could not answer -- it ranked worst-first and the top
    -- of the list was all controls, so the groups never showed. Classify, and
    -- report the boxes separately no matter where they rank.
    local function KindOf(f)
        if f.LayoutChildren then return "BOX" end        -- CreateSettingsGroup
        if f.slider then return "slider" end
        return (f.GetObjectType and f:GetObjectType()) or "frame"
    end

    local frames = CollectBorderedFrames(page.child or page, {}, 0)
    local rows, offGrid, nearClip = {}, 0, 0
    local byKind = {}
    for _, f in ipairs(frames) do
        local top, bottom, h = f:GetTop(), f:GetBottom(), f:GetHeight()
        local fppu = PixelsPerUnit(f) or ppu
        local dTop = PixelOffsetOf(top, fppu)
        local dBot = PixelOffsetOf(bottom, fppu)
        local dH   = PixelOffsetOf(h, fppu)
        -- Distance from the scroll viewport's top clip edge, in device pixels.
        local clipGap = (top and clipTop) and ((clipTop - top) * fppu) or nil
        if dTop and math.abs(dTop) > 0.05 then offGrid = offGrid + 1 end
        if clipGap and clipGap > -1.5 and clipGap < 1.5 then nearClip = nearClip + 1 end
        -- Edge THICKNESS, which is the leg two earlier revisions of this probe
        -- did not capture and the one that turned out to matter. A box can
        -- measure a perfect 0.00 on every edge and still lose its border if the
        -- edge is drawn a fractional number of device pixels wide: it bleeds
        -- into the next row at partial intensity, and a settings-group edge is
        -- only ~8% alpha over a 3% fill, so both halves can land under the
        -- visibility floor. Alpha is reported alongside because it sets that
        -- floor.
        --
        -- A pixel border reports its own thickness instead: it is authored in
        -- device pixels, so it is a whole number by construction and edgeFrac
        -- is 0 -- which is exactly the point of it, and worth being able to SEE
        -- next to a surface still on the old edge.
        local bdInfo = f.GetBackdrop and f:GetBackdrop()
        local edgeUnits = bdInfo and bdInfo.edgeSize or nil
        -- f._pxDevicePx, not a recomputation from PX_BORDER_THICKNESS: that
        -- constant is declared several hundred lines below this probe, so
        -- naming it here would resolve to a nil GLOBAL, silently. Reading what
        -- LayoutPixelBorder actually drew is both safer and more truthful.
        local edgePx = edgeUnits and (edgeUnits * fppu) or f._pxDevicePx or nil
        local edgeFrac = edgePx and (edgePx - math.floor(edgePx + 0.5)) or nil
        -- NOT `local _,_,_,a = (f:GetBackdropBorderColor())` -- the parentheses
        -- truncate a multi-return to ONE value, so alpha came back nil every time
        -- and every row printed "a=n/a". Alpha is the whole point here: a
        -- settings-group edge is ~8% over a 3% fill, so it has almost no margin.
        local borderA
        if f.GetBackdropBorderColor then
            local _, _, _, a = f:GetBackdropBorderColor()
            borderA = a
        end
        local kind = KindOf(f)
        local bad = (dTop and math.abs(dTop) > 0.05) or false
        local k = byKind[kind]
        if not k then k = { n = 0, bad = 0 }; byKind[kind] = k end
        k.n = k.n + 1
        if bad then k.bad = k.bad + 1 end
        rows[#rows + 1] = {
            label = DescribeFrame(f), kind = kind, bad = bad,
            frame = f, level = f.GetFrameLevel and f:GetFrameLevel() or nil,
            dTop = dTop or 0, dBot = dBot or 0,
            dH = dH or 0, clipGap = clipGap,
            edgePx = edgePx, edgeFrac = edgeFrac, alpha = borderA,
            score = math.max(math.abs(dTop or 0),
                             (clipGap and math.abs(clipGap) < 1.5) and 1 or 0),
        }
    end

    table.sort(rows, function(a, b) return a.score > b.score end)
    o:Section("Bordered frames", #rows)
    o:Field("off-grid top", offGrid, offGrid > 0 and "BAD" or "GOOD")
    o:Field("within 1px of the clip edge", nearClip, nearClip > 0 and "WARN" or "GOOD")

    -- Per-kind tally: this is the line that says whether fixing controls would
    -- also fix the section boxes, or whether they are a separate problem.
    local kindLine = {}
    for kind, k in pairs(byKind) do
        kindLine[#kindLine + 1] = ("%s %d/%d"):format(kind, k.bad, k.n)
    end
    table.sort(kindLine)
    o:Field("by kind (bad/total)", table.concat(kindLine, "  "), "NEUTRAL")

    local function emit(r)
        local flag = ""
        if r.bad then flag = " |cffff6060OFF-GRID|r" end
        if r.clipGap and math.abs(r.clipGap) < 1.5 then flag = flag .. " |cffffaa00AT-CLIP|r" end
        -- A fractional edge width is the failure a perfect 0.00 box can still have.
        if r.edgeFrac and math.abs(r.edgeFrac) > 0.05 then flag = flag .. " |cffff6060SOFT-EDGE|r" end
        if r.alpha and r.alpha < 0.15 then flag = flag .. " |cffffaa00FAINT|r" end
        print(("    [%s] %-22s top%+.2f bot%+.2f h%+.2f edge=%s a=%s clip=%s%s"):format(
            r.kind:sub(1, 6), r.label:sub(1, 22), r.dTop, r.dBot, r.dH,
            r.edgePx and ("%.2fpx"):format(r.edgePx) or "n/a",
            r.alpha and ("%.2f"):format(r.alpha) or "n/a",
            r.clipGap and ("%.1f"):format(r.clipGap) or "n/a", flag))
    end

    -- The section boxes ALWAYS get listed, however they rank -- they are the ones
    -- you can actually see, and ranking buried them last time.
    local boxes = 0
    for _, r in ipairs(rows) do if r.kind == "BOX" then boxes = boxes + 1 end end
    if boxes > 0 then
        o:Section("Section boxes", boxes .. " — the outlines around each section")
        local shown = 0
        for _, r in ipairs(rows) do
            if r.kind == "BOX" and shown < 10 then
                emit(r)
                -- Anything sitting ON this box's top border row is the prime
                -- suspect now that the box's own geometry measures clean.
                local over = r.frame and FindTopRowOverlaps(r.frame) or {}
                if #over > 0 then
                    print(("           |cffff6060^ COVERED BY:|r %s  (box is lvl%s)")
                        :format(table.concat(over, ", "), tostring(r.level)))
                end
                shown = shown + 1
            end
        end
    else
        o:Section("Section boxes")
        o:Line("None found on this page.", "WARN")
    end

    o:Section("Worst overall")
    o:Line("topOff/botOff/heightOff are px from the grid; clip is px below the viewport top.", "NEUTRAL")
    for i = 1, math.min(#rows, 10) do emit(rows[i]) end
    print("  |cff808080Read: OFF-GRID = geometry. SOFT-EDGE = the edge is a fractional number of device px wide, so it bleeds into the next row -- a box can be a perfect 0.00 and still lose its border this way. FAINT = so little alpha that any split is invisible.|r")
    print("  |cff808080Nothing is corrected at runtime any more. Every widget gets its whole-pixel numbers from its FACTORY at construction (nudging them afterwards is what made chained button rows drift), so an off-grid row after a scale change is expected and is not a bug. What still matters here is SOFT-EDGE and FAINT.|r")

    -- Persist, for the same reason gapcheck does: transcribing a screenful of
    -- numbers out of the chat frame is not practical remotely, and every reading
    -- of this symptom that came from eyeballing rather than the file has been
    -- wrong. Same session stamp, so a capture never mixes two builds.
    DandersFramesDebugDB = DandersFramesDebugDB or {}
    if DandersFramesDebugDB.pixelSession ~= GAP_SESSION then
        DandersFramesDebugDB.pixelcheck = nil
        DandersFramesDebugDB.pixelSession = GAP_SESSION
    end
    DandersFramesDebugDB.pixelcheck = DandersFramesDebugDB.pixelcheck or {}
    local pdump = {
        when = date("%Y-%m-%d %H:%M:%S"),
        ppu = ppu, scroll = scroll,
        viewTop = dPageTop, viewBot = dPageBot, viewH = dPageH,
        rows = {},
    }
    for i, r in ipairs(rows) do
        pdump.rows[i] = {
            label = tostring(r.label):sub(1, 40), kind = r.kind,
            dTop = r.dTop, dBot = r.dBot, dH = r.dH,
            edgePx = r.edgePx, alpha = r.alpha, clipGap = r.clipGap,
            level = r.level,
            -- Raw geometry too: the deltas alone cannot distinguish "off-grid"
            -- from "the right size but drawn somewhere unexpected".
            top = r.frame and r.frame:GetTop() or nil,
            bottom = r.frame and r.frame:GetBottom() or nil,
            height = r.frame and r.frame:GetHeight() or nil,
            width = r.frame and r.frame:GetWidth() or nil,
            points = r.frame and r.frame:GetNumPoints() or nil,
        }
    end
    -- Never overwrite an earlier run of the SAME page: the whole point of running
    -- this twice is to compare a broken state against a working one, and keying
    -- purely by page silently threw the first away. Numbered within the session.
    local key, n = tostring(pageName), 1
    while DandersFramesDebugDB.pixelcheck[key] do
        n = n + 1
        key = ("%s #%d"):format(tostring(pageName), n)
    end
    DandersFramesDebugDB.pixelcheck[key] = pdump
    print(("  |cff00ff00saved|r %d rows to DandersFramesDebugDB.pixelcheck[\"%s\"] -- |cffffcc00/reload to flush.|r")
        :format(#rows, key))
end

-- ============================================================
-- /df debug navprobe -- catch the left-nav hover flash in the act
--
-- The symptom: sweeping the cursor down the nav list shows a "ghost" -- of the
-- row's text, or of the bottom part of the hover plate. It happens at moderate
-- speed, not just fast, and it survived snapping the row geometry.
--
-- Four causes would produce that, and they are INDISTINGUISHABLE in a
-- screenshot, which is why this measures instead of reasoning:
--
--   (a) two rows lit at once -- the previous row's OnLeave never ran, so two
--       plates are visible together for a frame or two;
--   (b) focus thrash -- the cursor sits still over one row but mouse focus
--       alternates between it and something else (the scroll frame, a sibling,
--       an overlapping rect), so the plate flickers on and off in place;
--   (c) geometry -- rows overlap, or leave a dead band between them where
--       NOTHING is lit, so crossing it reads as the plate breaking up;
--   (d) none of the above -- a pure rendering artefact, in which case the trace
--       shows exactly one clean enter/leave per row and the answer is elsewhere.
--
-- Static geometry first (overlaps and dead bands are visible without moving the
-- mouse), then a live trace of every change in focus and in each row's plate
-- alpha, stamped with the frame number. (a) and (b) show up as repeated
-- transitions within a single crossing; (c) as a run of frames with nothing lit.
function GUI.NavProbe(seconds)
    local container = GUI.tabContainer
    if not (container and container:IsVisible()) then
        DF:Say("the settings window is not open.")
        return
    end
    local ppu = PixelsPerUnit(container) or 1

    -- Rows in LAYOUT order (top to bottom), which is what makes the neighbour
    -- comparison below meaningful -- GetChildren order is creation order.
    local rows = {}
    for _, catName in ipairs(GUI.CategoryOrder or {}) do
        local cat = GUI.Categories and GUI.Categories[catName]
        if cat and cat:IsShown() then
            rows[#rows + 1] = { f = cat, label = "[" .. tostring(catName) .. "]" }
            for _, btn in ipairs(cat.children or {}) do
                if btn:IsShown() then
                    rows[#rows + 1] = { f = btn, label = DescribeFrame(btn) }
                end
            end
        end
    end

    local o = DF:Out("Nav Probe")
    o:Section("Rows")
    o:Field("visible", #rows, #rows > 0 and "GOOD" or "WARN")
    o:Field("px per unit", ("%.4f"):format(ppu), "NEUTRAL")

    -- The ANCESTOR CHAIN, because a row cannot be on the grid if the frame it
    -- hangs off is not: every ancestor here is two-corner anchored, so nothing
    -- corrects them after the fact and a fraction anywhere propagates to all 42
    -- rows identically. If the rows read a uniform offset, this line says which
    -- link introduced it -- that is how the 4-unit nav inset (0.375px) was found
    -- after the rows themselves measured clean on height.
    local chain, node = {}, container
    while node and #chain < 6 do
        local t = node:GetTop()
        chain[#chain + 1] = ("%s top%+.2f"):format(
            (node.GetObjectType and node:GetObjectType() or "?"):sub(1, 6),
            PixelOffsetOf(t, PixelsPerUnit(node) or ppu) or 0)
        node = node:GetParent()
    end
    print("  chain (row -> window): " .. table.concat(chain, " | "))

    -- Geometry: the gap to the row above, in DEVICE pixels. Negative = the rows
    -- overlap (both can claim the cursor); more than ~1px positive = a dead band
    -- with no row under the cursor at all. Either one produces a visible break.
    local overlaps, bands = 0, 0
    for i, r in ipairs(rows) do
        local f = r.f
        local top, bot, h = f:GetTop(), f:GetBottom(), f:GetHeight()
        local dTop = PixelOffsetOf(top, ppu) or 0
        local dH = PixelOffsetOf(h, ppu) or 0
        local gap
        if i > 1 then
            local prevBot = rows[i - 1].f:GetBottom()
            if prevBot and top then gap = (prevBot - top) * ppu end
        end
        local flag = ""
        if gap and gap < -0.05 then flag = " |cffff6060OVERLAPS ABOVE|r"; overlaps = overlaps + 1
        elseif gap and gap > 1.05 then flag = " |cffffaa00DEAD BAND|r"; bands = bands + 1 end
        if math.abs(dTop) > 0.05 or math.abs(dH) > 0.05 then
            flag = flag .. " |cffffaa00OFF-GRID|r"
        end
        print(("    %-24s top%+.2f h%+.2f gap=%s lvl%d%s"):format(
            r.label:sub(1, 24), dTop, dH,
            gap and ("%.2fpx"):format(gap) or "n/a",
            f:GetFrameLevel() or 0, flag))
    end
    print(("  %d overlapping rows, %d dead bands between rows"):format(overlaps, bands))

    -- Live trace.
    S.navTrace = S.navTrace or CreateFrame("Frame")
    S.navTrace:SetScript("OnUpdate", nil)
    local dur = tonumber(seconds) or 8
    local elapsed, frames, events = 0, 0, 0
    local lastLit, lastFocus = nil, nil
    print(("  |cff00ff00tracing for %ds|r -- sweep the cursor across the nav list now."):format(dur))

    S.navTrace:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        frames = frames + 1

        -- Which row the shared plate is parked on. There is only one plate now, so
        -- "TWO LIT" is structurally impossible -- that is the point of the change,
        -- and this still checks for it in case the plate is ever reintroduced
        -- per-row. No parentheses around the colour call: they would truncate the
        -- multi-return to one value and alpha would read nil every frame -- the
        -- exact mistake that cost three rounds on the border bug.
        local lit = {}
        local hl = GUI.navHover
        if hl and hl:IsShown() and hl.owner then
            local _, _, _, a = hl:GetBackdropColor()
            if a and a > 0.01 then
                for _, r in ipairs(rows) do
                    if r.f == hl.owner then lit[#lit + 1] = r.label:sub(1, 18) break end
                end
            end
        end
        local litKey = table.concat(lit, "+")

        -- What actually owns the mouse. If this is NOT the lit row, the plate and
        -- the focus disagree, which is cause (b).
        local focus = "-"
        local foci = GetMouseFoci and GetMouseFoci()
        local top = (foci and foci[1]) or (GetMouseFocus and GetMouseFocus())
        if top then
            for _, r in ipairs(rows) do if r.f == top then focus = r.label:sub(1, 18) break end end
            if focus == "-" then
                focus = "<" .. ((top.GetObjectType and top:GetObjectType()) or "?") .. ">"
            end
        end

        if litKey ~= lastLit or focus ~= lastFocus then
            events = events + 1
            if events <= 120 then
                print(("    f%-5d t=%.3f  lit=%-24s focus=%s%s"):format(
                    frames, elapsed,
                    (litKey ~= "" and litKey or "(none)"),
                    focus,
                    (#lit > 1) and " |cffff6060TWO LIT|r"
                        or ((litKey == "" and focus ~= "-") and " |cffffaa00FOCUS BUT UNLIT|r" or "")))
            end
            lastLit, lastFocus = litKey, focus
        end

        if elapsed >= dur then
            S.navTrace:SetScript("OnUpdate", nil)
            print(("  |cff00ff00navprobe done|r -- %d frames, %d state changes%s"):format(
                frames, events, events > 120 and " (first 120 shown)" or ""))
            print("  |cff808080Read: one enter + one leave per row = clean, look elsewhere. Repeated flips inside one crossing = focus thrash. TWO LIT = a stale plate. lit=(none) with focus on a row = the handler did not fire.|r")
        end
    end)
end

-- ============================================================
-- /df debug gapcheck -- measure the vertical rhythm, don't eyeball it
--
-- The question this answers: "which rows are too far apart, and which are too
-- close?" It cannot be answered from GUI.RowHeight alone, because those numbers
-- are SLOT heights, not gaps. LayoutChildren stacks rows flush (y = y - height),
-- so the visible gap between two rows is:
--
--     (slot height - content bottom) of the row above
--   + (slot top - content top)      of the row below
--
-- A row whose content is short inside a tall slot gets a big gap and nothing
-- flags it. The slider is the worst case by construction: it shares the 55 slot
-- with the dropdown and edit box, whose openers reach ~40, while a slider only
-- draws to ~32 (label, an 8px track, a 20px value box) -- so it carries ~23px of
-- slack against their ~15.
--
-- Measured, not derived, for a reason: labels WRAP, override markers hang off
-- rows, banners re-measure themselves after construction, and hideOn rows drop
-- out. Only the live rects know the real content extent, which is exactly the
-- lesson from the border bug -- the arithmetic looked right there too.
--
-- Rows are compared only against their SIBLINGS IN THE SAME GROUP. That is where
-- the rhythm actually reads, and it sidesteps having to reconstruct which column
-- a widget landed in.
local function ContentExtent(f)
    local top, bottom
    local function acc(o)
        if not o or not o.IsShown or not o:IsShown() then return end
        -- Skip things that draw NOTHING: an empty label or a fully transparent
        -- placeholder still has a rect, and counting it would inflate the content
        -- and hide the very slack we are looking for.
        --
        -- FontStrings ONLY. An EditBox also answers GetText, and an empty one
        -- would have been skipped here even though its box is plainly drawn --
        -- which would have under-measured every blank input on the page.
        if o.GetObjectType and o:GetObjectType() == "FontString" then
            local s = o:GetText()
            if s == nil or s == "" then return end
        end
        if o.GetAlpha and (o:GetAlpha() or 1) <= 0.01 then return end
        local t, b = o:GetTop(), o:GetBottom()
        if t and b then
            top = (top and math.max(top, t)) or t
            bottom = (bottom and math.min(bottom, b)) or b
        end
    end
    if f.GetRegions then for _, r in ipairs({ f:GetRegions() }) do acc(r) end end
    if f.GetChildren then for _, c in ipairs({ f:GetChildren() }) do acc(c) end end
    return top, bottom
end

-- Every SHOWN SettingsGroup under the page, at any depth (the Aura Designer nests
-- its groups inside cards).
local function CollectGroups(root, out, depth)
    if not root or (depth or 0) > 8 then return out end
    if root.groupChildren and root.IsShown and root:IsShown() then out[#out + 1] = root end
    if root.GetChildren then
        for _, c in ipairs({ root:GetChildren() }) do
            if c.IsShown and c:IsShown() then CollectGroups(c, out, (depth or 0) + 1) end
        end
    end
    return out
end

function GUI.GapCheck(mode)
    if mode == "clear" then
        DandersFramesDebugDB = DandersFramesDebugDB or {}
        DandersFramesDebugDB.gapcheck = nil
        DF:Say("saved capture cleared (/reload to flush).")
        return
    end

    local page, pageName
    for name, p in pairs(GUI.Pages or {}) do
        if p.IsShown and p:IsShown() then page, pageName = p, name break end
    end
    if not page then
        DF:Say("Gap check", "no settings page is open", "WARN")
        return
    end

    local groups = CollectGroups(page.child or page, {}, 0)
    local rows, byKind, pairs_, nRows = {}, {}, {}, 0

    for _, group in ipairs(groups) do
        local prev
        for _, entry in ipairs(group.groupChildren or {}) do
            local w = entry.widget
            if w and w.IsShown and w:IsShown() and entry.height then
                local slotTop = w:GetTop()
                local cTop, cBot = ContentExtent(w)
                if slotTop and cTop and cBot then
                    -- The slot is entry.height from the widget's TOP -- NOT the
                    -- widget's own rect. LayoutChildren only sets TOPLEFT (and
                    -- width), so a container constructed at 50 sitting in a 55
                    -- slot would under-report by 5 if we used GetBottom().
                    local slotBot = slotTop - entry.height
                    local kind = w.rowKind or (w.LayoutChildren and "group")
                        or (w.GetObjectType and w:GetObjectType()) or "?"
                    local r = {
                        kind    = kind,
                        label   = (w.GetText and w:GetText()) or (w.Text and w.Text.GetText and w.Text:GetText()) or kind,
                        slot    = entry.height,
                        content = cTop - cBot,
                        padTop  = slotTop - cTop,
                        padBot  = cBot - slotBot,
                        -- Absolute edges, because the gap has to be measured from
                        -- where the rows LANDED, not from entry.height. The layout
                        -- can shorten a row after the fact (the compact-run
                        -- tightening does exactly that), and slot arithmetic
                        -- cannot see it -- the first version of this reported the
                        -- untightened number and made the feature look inert.
                        cTop    = cTop,
                        cBot    = cBot,
                        -- The slot's own top, so the height the layout ACTUALLY
                        -- used is derivable offline (prev.slotTop - this.slotTop)
                        -- and can be compared against entry.height.
                        slotTop  = slotTop,
                        tight    = w._rowTightened or false,
                        nextKind = w._rowNextKind,
                    }
                    nRows = nRows + 1
                    rows[#rows + 1] = r

                    local k = byKind[kind]
                    if not k then k = { n = 0, slot = 0, content = 0, padTop = 0, padBot = 0 } byKind[kind] = k end
                    k.n, k.slot, k.content = k.n + 1, k.slot + r.slot, k.content + r.content
                    k.padTop, k.padBot = k.padTop + r.padTop, k.padBot + r.padBot

                    -- The gap the eye actually sees: the distance between where
                    -- the previous row's content ENDED and this one's STARTS,
                    -- straight off the resolved rects.
                    if prev then
                        local gap = prev.cBot - r.cTop
                        local key = ("%s -> %s"):format(prev.kind, kind)
                        local p = pairs_[key]
                        if not p then p = { n = 0, sum = 0, min = gap, max = gap } pairs_[key] = p end
                        p.n, p.sum = p.n + 1, p.sum + gap
                        p.min, p.max = math.min(p.min, gap), math.max(p.max, gap)
                    end
                    prev = r
                end
            end
        end
    end

    if nRows == 0 then
        local o = DF:Out("Gap Check", "page " .. tostring(pageName))
        o:Line("No measurable rows — is everything collapsed?", "WARN")
        o:Siblings("gapcheck")
        return
    end

    local o = DF:Out("Gap Check", "page " .. tostring(pageName))
    o:Section("Measured", "UI units")
    o:Field("groups", #groups, "NEUTRAL")
    o:Field("rows", nRows, "NEUTRAL")

    o:Section("Per kind")
    o:Line("slot is what RowHeight hands out; content is what it actually draws.", "NEUTRAL")
    local kinds = {}
    for kind in pairs(byKind) do kinds[#kinds + 1] = kind end
    table.sort(kinds, function(a, b) return (byKind[a].padBot / byKind[a].n) > (byKind[b].padBot / byKind[b].n) end)
    for _, kind in ipairs(kinds) do
        local k = byKind[kind]
        print(("    %-12s n=%-3d slot %5.1f  content %5.1f  padTop %4.1f  |cffffcc00padBottom %4.1f|r")
            :format(kind, k.n, k.slot / k.n, k.content / k.n, k.padTop / k.n, k.padBot / k.n))
    end

    -- Did the compact-run tightening actually fire? The gap alone cannot say --
    -- it only shows the result -- and reading the source said it should while the
    -- measurement said it had not. So count the decision directly, and when a run
    -- did NOT close up, name the kind that broke it.
    local tightened, compactRows, breakers = 0, 0, {}
    for _, r in ipairs(rows) do
        if GUI.RowCompact[r.kind] then
            compactRows = compactRows + 1
            if r.tight then
                tightened = tightened + 1
            elseif r.nextKind then
                breakers[r.nextKind] = (breakers[r.nextKind] or 0) + 1
            end
        end
    end
    if compactRows > 0 then
        local why = {}
        for k, n in pairs(breakers) do why[#why + 1] = ("%s x%d"):format(k, n) end
        table.sort(why)
        print(("  compact-run tightening: |cffffcc00%d/%d|r compact rows closed up%s")
            :format(tightened, compactRows,
                #why > 0 and ("  |cff808080(run broken by: %s)|r"):format(table.concat(why, ", ")) or ""))
    end

    print("  gaps between stacked rows (padBottom above + padTop below) -- widest first:")
    local keys = {}
    for key in pairs(pairs_) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return (pairs_[a].sum / pairs_[a].n) > (pairs_[b].sum / pairs_[b].n) end)
    for _, key in ipairs(keys) do
        local p = pairs_[key]
        local avg = p.sum / p.n
        -- A pair whose min and max differ is NOT a spacing constant -- something
        -- (a wrapped label, a hand-rolled AddSpace) is varying it, and averaging
        -- would hide exactly that.
        local spread = (p.max - p.min > 0.5)
            and ("  |cffff6060varies %.1f..%.1f|r"):format(p.min, p.max) or ""
        print(("    %6.1f  %-26s x%d%s"):format(avg, key, p.n, spread))
    end

    if mode == "all" then
        print("  every row, in layout order:")
        for _, r in ipairs(rows) do
            print(("    %-12s %-22s slot %5.1f  content %5.1f  padTop %4.1f  padBottom %4.1f")
                :format(r.kind, tostring(r.label):sub(1, 22), r.slot, r.content, r.padTop, r.padBot))
        end
    end

    -- Persist the RAW rows to SavedVariables. Reading a hundred rows out of the
    -- chat frame is not practical, and transcribing them by hand would introduce
    -- exactly the kind of error this probe exists to avoid.
    --
    -- Keyed BY PAGE so visiting several pages accumulates one dataset instead of
    -- each run overwriting the last -- walk the pages you care about, then
    -- /reload ONCE. SavedVariables are only flushed on logout or reload, so a run
    -- that is never followed by one is never written.
    --
    -- Its own saved variable, not a corner of DandersFramesDB_v2: diagnostics
    -- must not sit inside the profile DB, where they would ride along with every
    -- export and show up in the export audit.
    DandersFramesDebugDB = DandersFramesDebugDB or {}
    DandersFramesDebugDB.gapcheck = DandersFramesDebugDB.gapcheck or {}
    -- Drop everything from a PREVIOUS session first. Accumulating by page is what
    -- makes a multi-page capture possible, but it also means a page you did not
    -- revisit after a code change keeps its stale rows -- and mixing two builds
    -- invents variance that is not in either of them. (It already cost one wrong
    -- diagnosis: three stale pages made the row heights look like they had not
    -- applied at all.) One /reload = one dataset.
    if DandersFramesDebugDB.gapSession ~= GAP_SESSION then
        wipe(DandersFramesDebugDB.gapcheck)
        DandersFramesDebugDB.gapSession = GAP_SESSION
    end
    local dump = { when = date("%Y-%m-%d %H:%M:%S"), rows = {} }
    if page.GetEffectiveScale then dump.scale = page:GetEffectiveScale() end
    for i, r in ipairs(rows) do
        dump.rows[i] = {
            kind = r.kind, label = tostring(r.label):sub(1, 40),
            slot = r.slot, content = r.content,
            padTop = r.padTop, padBot = r.padBot,
            cTop = r.cTop, cBot = r.cBot,   -- so gaps can be re-derived offline
            slotTop = r.slotTop, tight = r.tight, nextKind = r.nextKind,
        }
    end
    DandersFramesDebugDB.gapcheck[tostring(pageName)] = dump

    local nPages = 0
    for _ in pairs(DandersFramesDebugDB.gapcheck) do nPages = nPages + 1 end
    print(("  |cff00ff00saved|r %d rows to DandersFramesDebugDB.gapcheck[\"%s\"] -- %d page(s) captured. |cffffcc00Visit the pages you care about, then /reload to flush.|r")
        :format(#rows, tostring(pageName), nPages))
    print("  |cff808080Read: padBottom is the slack under a row -- the knob is GUI.RowHeight[kind], and slot - content IS that slack. A kind sorting to the top of the first list is over-spaced; one near zero is cramped. In the second list, 'varies' means the gap is not coming from RowHeight alone. Add 'all' for every row, 'clear' to wipe the saved capture.|r")
end
-- (Removed) GUI.GapCheckAll — a no-arg alias for GapCheck("all"), superseded once the
-- dispatcher started forwarding the mode argument. Zero callers.

-- ============================================================
-- /df debug guiperf -- count the hook calls a settings change actually drives
--
-- Every hook a widget factory fires (refresh, refreshNow, onSettingWritten,
-- onDragStart/Stop, interceptWrite, …) goes through DandersUI's UI:Call, so the
-- pack can count them without knowing anything about us. This is the DF-side
-- door onto that: start, drag a slider, stop, report.
--
-- The question it answers is the one no screenshot can: how many full applies
-- one drag of one slider costs. "It feels laggy" and "it fires forty times a
-- second" look identical from the outside.
--
-- Debug output — developer-facing, so deliberately unlocalised like the rest of
-- the /df debug dumps.
-- ============================================================
function DF:GUIPerf(action)
    action = action and action:lower() or "report"
    -- ⚠ The pack reports through the `debug` hook's printer, which is silent
    -- unless PERF is a logged category. Without this line a report with debug
    -- off prints NOTHING and reads as "the counters recorded nothing".
    if not (DF.DebugActive and DF:DebugActive("PERF")) then
        DF:Say("GUI hook perf", "PERF logging is off — enable it in the debug console or output goes nowhere", "WARN")
    end
    if action == "start" then
        GUI:PerfStart()
        DF:Say("GUI hook perf", "RECORDING", "GOOD")
        DF:Say("Drag a slider, then: " .. DF:CmdPath("guiperf") .. " stop")
    elseif action == "stop" then
        GUI:PerfStop()
        DF:Say("GUI hook perf", "STOPPED", "NEUTRAL")
        GUI:PerfReport()
    elseif action == "report" then
        GUI:PerfReport()
    else
        DF:Err("guiperf: expected start, stop or report.")
    end
end

-- ============================================================
-- DESIGNER PRESET PROMPTS (DandersFrames-only)
-- Used by the Aura / Text Designer template bars in the options companion,
-- which alias them off GUI._priv. They stay here because deleting a preset is
-- DandersFrames' own data operation.
-- ============================================================
local function PromptPresetName(message, default, acceptLabel, callback)
    GUI:PromptName({
        title       = L["Template Name"],
        message     = message,
        default     = default,
        acceptLabel = acceptLabel,
        onAccept    = callback,
    })
end

local function ConfirmDeletePreset(kind, name, onDone)
    DF:ShowPopupAlert({
        title   = L["Delete Template"],
        message = format(L["Delete template \"%s\"? Anything using it reverts to Default."], name),
        buttons = {
            {
                label = L["Delete"],
                onClick = function()
                    if DF.DeleteDesignerPreset then
                        DF:DeleteDesignerPreset(kind, name)
                        if onDone then onDone() end
                    end
                end,
            },
            { label = L["Cancel"] },
        },
    })
end

-- Published on the HOST's _priv overlay (never the pack's shared table), which
-- is exactly what the overlay exists for. The options companion reads them via
-- `local P = GUI._priv`.
GUI._priv.PromptPresetName   = PromptPresetName
GUI._priv.ConfirmDeletePreset = ConfirmDeletePreset

-- The flag/dropdown order for the outline + shadow controls. The controls
-- themselves live in the options companion; only this constant was ever in the
-- resident half, and it is DandersFrames' own font vocabulary.
GUI._priv.OUTLINE_FLAG_ORDER = { "NONE", "OUTLINE", "THICKOUTLINE", "MONOCHROME", "MONOCHROME, OUTLINE", "MONOCHROME, THICKOUTLINE" }

-- ============================================================
-- OVERRIDE DEBUG SLASH
-- Forces every override marker and reset button visible regardless of state,
-- so you can see which controls carry the machinery at all. The FLAG lives on
-- the pack's shared _state (that is what AddOverrideIndicators reads); only the
-- command itself is DandersFrames'.
-- ============================================================
DF:RegisterDebugSlash("DFOVERRIDEDEBUG", "Force-show every override marker and reset button", true, "/dfoverridedebug")
SlashCmdList["DFOVERRIDEDEBUG"] = function()
    local S = GUI._state
    S.overrideDebugMode = not S.overrideDebugMode
    DF:Say("Override debug mode " .. (S.overrideDebugMode and "ENABLED" or "DISABLED"))
    GUI:RefreshAllOverrideIndicators()
end

-- ☠ Bare-callable on purpose, like GetThemeColor: three companion sites call
-- GUI.RefreshAllOverrideIndicators() with no self (and one aliases it at file
-- scope). The pack implementation is a method, so this closure pins the host.
function GUI.RefreshAllOverrideIndicators()
    return LibStub("DandersUI-1.0").RefreshAllOverrideIndicators(GUI)
end
