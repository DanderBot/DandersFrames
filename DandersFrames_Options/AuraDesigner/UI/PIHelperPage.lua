-- Power Infusion Helper — its own settings page, beside the Aura Designer.
--
-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's, so every
-- DF.* read here would be nil. Take the parent's table from the global it publishes at
-- DandersFrames/Core.lua:9 (`_G[addonName] = DF`). Same preamble as the other AD parts.
local DF = DandersFrames
local L = DF.L
local GUI = DF.GUI
local S = DF.AuraDesigner._uiState
local P = DF.AuraDesigner._priv

local max, abs = math.max, math.abs

-- ============================================================
-- WHY THIS PAGE EXISTS
-- ============================================================
-- ☠ THE HELPER WAS A FEATURE WEARING AN AURA DESIGNER RECIPE'S CLOTHES. It behaves like a
-- feature — one switch, its own rules, its own class lists, its own sound — but it was
-- implemented as records in the Any Buff pool, so it inherited the designer's LOCATION as
-- well as its plumbing: priest-only, behind a non-default tab, four levels deep, with its
-- behaviour in one panel and the appearance of the things it created in a different card
-- further down the same page. Krathe, 2026-09-08: "it's not very clear how to use it or
-- even how to find it… the main settings and the added indicator are split."
--
-- ★ THE DECISION THAT UNLOCKED IT: the CARD does not have to live where the RECORDS live.
-- The pool still decides a record's caster filter — that constraint is real and unchanged,
-- and the helper still writes into Any Buff — but nothing required the user to go there to
-- find the switch. So the feature moves and the plumbing stays.
--
-- ⚠ WHAT THIS PAGE IS NOT: a second rendering path. Under 12.1 every aura-driven visual
-- goes through the container engine, and the helper's signals are ordinary AD records
-- carrying a `pihSignal` mark that the Factory reads to stamp `dfGate`
-- (AuraDesigner/Factory.lua:2236, :2681, :3446). Moving the UI changes none of that.
--
-- ⚠ AND IT IS NOT AN ISLAND. DF.BuildAuraDesignerPage builds a whole anchored sub-window
-- (S.mainFrame) because the designer needs one; this page is a column of settings, so it
-- goes through the page harness like any other page and inherits its chrome for free.
-- That is also what makes it LOOK like the designer without copying anything.

-- ============================================================
-- THE WIDTH DANCE
-- ============================================================
-- ☠ THE HARNESS SIZES A WIDGET *AFTER* Add, NOT BEFORE. GUI/Panel.lua's Add only records
-- layoutHeight/layoutCol; the actual SetWidth happens in PageRefreshStates' layout pass
-- (the `layoutCol == "both"` arm). S.BuildPIHelperPane needs a real width AT BUILD TIME —
-- the card measures its wrapped description against it, and falls back to 320 without one,
-- which is right for the 260px popout pane and wrong by half on a full-width page.
--
-- ⇒ Build LAZILY, on the first size we are given, and re-measure only when the width
-- actually moves. The height then flows the other way: the pane returns its measured
-- bottom, we publish that as layoutHeight and ask for ONE more layout pass.
--
-- ⚠ THAT FEEDBACK CANNOT LOOP, and the guard is deliberate rather than lucky: the rebuild
-- is gated on WIDTH changing, and the second pass changes only HEIGHT. `rebuilding` is a
-- belt on top of that, because a nested layout pass during a build would re-enter here
-- with the host half-populated.
local WIDTH_EPSILON = 2   -- sub-pixel jitter from the snapping pass is not a resize

-- ============================================================
-- THE PAGE
-- ============================================================
-- Signature mirrors DF.BuildAuraDesignerPage so the two register identically in
-- GUI/Pages/Auras.lua and neither is a special case at the call site.
function DF.BuildPIHelperPage(guiRef, pageRef, dbRef, Add, AddSpace)
    if not (Add and pageRef and pageRef.child) then return end
    if not (S and S.BuildPIHelperPane) then return end

    local host = CreateFrame("Frame", nil, pageRef.child)
    host:SetHeight(1)
    host.layoutHeight = 1
    host.layoutCol = "both"

    local content, lastWidth, rebuilding = nil, 0, false

    local function relayout()
        -- PageRefreshStates IS the layout pass (GUI/Panel.lua:186) — it re-anchors every
        -- child from its layoutHeight and refreshes states. It does NOT rebuild widgets,
        -- so calling it here re-flows the column around our new height without
        -- re-entering the builder.
        if pageRef.RefreshStates then pcall(pageRef.RefreshStates, pageRef) end
    end

    local function rebuild()
        if rebuilding then return end
        local w = host:GetWidth() or 0
        -- Nothing sensible can be measured against a collapsed width, and the harness
        -- hands us one on the very first pass. Wait for the real number.
        if w < 50 then return end
        rebuilding = true

        -- ☠ TEAR DOWN THROUGH THE TRASH FRAME, the same way BuildPage retires its own
        -- children. WoW cannot GC frames, but a hidden, unanchored, reparented subtree is
        -- not walked during layout — and leaving the old column parented here would stack
        -- two sets of controls on one page, each writing the same settings.
        if content then
            content:Hide()
            content:ClearAllPoints()
            content:SetParent(GUI._trashFrame or UIParent)
        end

        content = CreateFrame("Frame", nil, host)
        content:SetPoint("TOPLEFT", 0, 0)
        content:SetPoint("TOPRIGHT", 0, 0)
        content:SetHeight(1)

        -- ⚠ Refresh is THIS page's redraw, not S.SwitchTab. Every control in the pane
        -- calls opts.Refresh when it changes something structural; inside the designer
        -- that meant "rebuild the tab", and here it means "rebuild this page". Routing it
        -- at S.SwitchTab would redraw a designer that may not even be open.
        local yEnd = S.BuildPIHelperPane(content, {
            startY  = 0,
            Refresh = function()
                if pageRef.Refresh then pcall(pageRef.Refresh, pageRef) end
            end,
        })

        local h = max(1, -(yEnd or 0))
        content:SetHeight(h)
        rebuilding = false

        if abs((host.layoutHeight or 0) - h) > 0.5 then
            host.layoutHeight = h
            host:SetHeight(h)
            relayout()
        else
            host:SetHeight(h)
        end
    end

    host:SetScript("OnSizeChanged", function(self, w)
        w = w or 0
        if abs(w - lastWidth) <= WIDTH_EPSILON then return end
        lastWidth = w
        rebuild()
    end)

    Add(host, 1, "both")
    return host
end

-- ============================================================
-- IS THE PAGE OFFERED AT ALL?
-- ============================================================
-- ☠ CLASS, NOT SPEC, AND READ ONCE AT REGISTRATION. Power Infusion is a priest ability and
-- a character cannot change class in session, so this is a constant for the life of the
-- login — which is what CreateSubTab's `hidden` flag wants (it decides whether the entry is
-- built, not whether it is greyed).
-- ⚠ Deliberately NOT gated on the helper existing. A page that appears only once you have
-- already added the helper is a page you cannot use to add it — the exact discoverability
-- trap this move exists to undo.
function DF.IsPIHelperAvailable()
    local _, class = UnitClass("player")
    return class == "PRIEST"
end
