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
-- (the `layoutCol == "both"` arm). The builders need a real width AT BUILD TIME — the
-- settings groups size themselves against their parent, and the split's two halves are
-- computed from it — so nothing here can run until the first real size arrives.
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
    if not (S and S.BuildPIHelperCard and S.BuildPIHelperBody) then return end

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

        -- ── THE 50/50 SPLIT, THE DESIGNER'S OWN SHAPE ──
        -- ☠ MEASURED, NOT ANCHORED TO CENTER. The designer's splitContainer can anchor its
        -- halves to a CENTER point because it lives inside an island of known size; this
        -- column is measured by the page harness AFTER the fact, so the halves take an
        -- explicit width off the one number we do have. `w` is the host's real width, which
        -- is why nothing here runs until the first size arrives.
        -- ⚠ The 6px gutter and the CENTER-3 / CENTER+3 pair it comes from are the
        -- designer's, and the Text Designer's before that -- borrowed rather than picked, so
        -- three split panels in this addon do not drift to three different gaps.
        local SPLIT_GAP  = 6
        local halfW      = math.max(80, (w - SPLIT_GAP) / 2)

        local leftPanel = CreateFrame("Frame", nil, content, "BackdropTemplate")
        leftPanel:SetPoint("TOPLEFT", 0, 0)
        leftPanel:SetWidth(halfW)
        -- ⚠ NO BORDER, and the designer's own note says why: the inner preview container
        -- draws the visible dim border, and one on both stacks into a brighter doubled line.
        GUI:CreatePanelBackdrop(leftPanel, { border = false })

        local rightPanel = CreateFrame("Frame", nil, content, "BackdropTemplate")
        rightPanel:SetPoint("TOPRIGHT", 0, 0)
        rightPanel:SetWidth(halfW)
        GUI:CreatePanelBackdrop(rightPanel, { border = false })

        -- ── THE SETTINGS FIRST, BECAUSE THEY DECIDE THE HEIGHT ──
        -- ⚠ Refresh is THIS page's redraw, not S.SwitchTab. Every control in the pane calls
        -- opts.Refresh when it changes something structural; inside the designer that meant
        -- "rebuild the tab", and here it means "rebuild this page". Routing it at
        -- S.SwitchTab would redraw a designer that may not even be open.
        local function pageRefresh()
            if pageRef.Refresh then pcall(pageRef.Refresh, pageRef) end
        end

        -- The enable banner sits ABOVE the tabs: it turns the whole feature on, so it
        -- cannot live inside one of the two things it governs.
        local yPos, open = S.BuildPIHelperCard(rightPanel, {
            startY = 0, Refresh = pageRefresh,
        })

        -- ── THE TAB BAR, THE DESIGNER'S OWN STYLING ──
        -- ⚠ GUI:StyleButton's `tab` mode is what the designer's right panel uses -- faint
        -- cell when inactive, accent fill and underline when active -- so borrowing it is
        -- what makes this read as the same kind of page rather than a lookalike.
        -- ☠ THE ACTIVE TAB LIVES ON S, NOT IN A LOCAL. This whole builder re-runs on every
        -- rebuild (a tick, a colour, a width change), and a local would reset the user to
        -- Triggers every time they changed anything on Effects.
        if open and S.PIH_TABS then
            S.pihTab = S.pihTab or "triggers"
            local TAB_GAP, TAB_H = 4, 26
            local tabW = math.max(60, (halfW - 16 - TAB_GAP) / 2)
            local prev
            for _, def in ipairs(S.PIH_TABS) do
                local btn = CreateFrame("Button", nil, rightPanel, "BackdropTemplate")
                btn:SetSize(tabW, TAB_H)
                if prev then
                    btn:SetPoint("TOPLEFT", prev, "TOPRIGHT", TAB_GAP, 0)
                else
                    btn:SetPoint("TOPLEFT", 8, yPos)
                end
                GUI:StyleButton(btn, { tab = true, text = def.label, font = "DFFontHighlight" })
                if btn.SetActive then btn:SetActive(S.pihTab == def.key) end
                btn:SetScript("OnClick", function()
                    if S.pihTab == def.key then return end
                    S.pihTab = def.key
                    pageRefresh()
                end)
                prev = btn
            end
            yPos = yPos - (TAB_H + 8)
        end

        local yEnd = yPos
        if open then
            yEnd = S.BuildPIHelperBody(rightPanel, {
                startY  = yPos,
                tab     = S.pihTab or "triggers",
                Refresh = pageRefresh,
            })
        end

        local rightH = max(1, -(yEnd or 0))
        rightPanel:SetHeight(rightH)

        -- ☠☠ THE PANEL IS SIZED BEFORE THE PREVIEW IS BUILT, AND THAT ORDER IS THE WHOLE
        -- FIX. Without opts.thumb, CreateFramePreview anchors its container to ALL FOUR
        -- CORNERS of the parent -- so the canvas takes its height FROM the panel. The first
        -- cut built the preview into a 1px panel and then set the panel's height from the
        -- preview: circular, and it resolved to 1px of nothing. The left half rendered as a
        -- transparent gap with the game world showing through (Krathe, 2026-09-08).
        -- ⇒ Decide the height, THEN build into it. The designer never hits this because its
        -- leftPanel is anchored TOPLEFT+BOTTOMLEFT inside an island that already has a size.
        -- ☠☠ THE LEFT PANEL TAKES THE CANVAS'S HEIGHT, NEVER THE COLUMN'S. The mock frame is
        -- anchored SetPoint("CENTER", container, "CENTER") and the container fills its
        -- parent -- so a left panel stretched to match a long settings column centres the
        -- frame halfway down that column, which is why it appeared stranded near the bottom
        -- with empty space above it (Krathe, 2026-09-08). The designer does not show this
        -- because its two halves are the same height BY CONSTRUCTION: they fill an island
        -- sized to the viewport, and the settings side scrolls INSIDE it. This page is a
        -- measured column in a scrolling page, so the halves are independent and only the
        -- CONTENT height is shared.
        --
        -- ⚠ THE NUMBER IS THE CANVAS'S OWN, not one I picked. CanvasWantedHeight(false) is
        -- the non-compact form's floor; CanvasWantedHeight(true) is the height that actually
        -- fits the frame at the live preview scale, and the +30 is the file's own accounting
        -- for what the band form saves by putting the scale behind a glyph instead of a
        -- slider row ("that 30px goes straight into CANVAS_FURNITURE and back to the
        -- frame"). Taking the larger keeps the frame fitting when the scale slider moves.
        local canvasH = 260
        if P.CanvasWantedHeight then
            canvasH = max(P.CanvasWantedHeight(false, nil),
                          P.CanvasWantedHeight(true, nil) + 30)
        end
        -- The column is as tall as its taller half; only the CONTENT height is shared, and
        -- the two panels keep their own (see the note above -- a left panel stretched to
        -- match the settings would centre the mock frame halfway down the page).
        local colH = max(rightH, canvasH)
        leftPanel:SetHeight(canvasH)
        content:SetHeight(colH)

        -- ── THE PREVIEW, THE DESIGNER'S OWN CANVAS ──
        -- ⚠ THE SAME FACTORY, NOT A LOOKALIKE. CreateFramePreview is what the designer
        -- mounts in both its layouts, and the scope-card tiles already prove it stands
        -- alone with no right panel. Reusing it is the only way this page can promise the
        -- picture matches the live frame -- a second renderer is a second thing to drift.
        -- ☠ S.framePreview IS A SINGLETON AND WE TAKE IT, which is safe for the same
        -- reason the designer's two layouts can both assign it: only one options page
        -- renders at a time, and whichever page builds next re-assigns it. Navigating away
        -- leaves it pointing at a retired frame until the designer rebuilds and claims it
        -- back -- exactly what already happens when the settings layout is flipped.
        -- ⚠ PAINTED FROM THE HELPER'S OWN RECORDS, never the shared pool: S.PIH_PreviewPool
        -- hands over the same cfg tables the designer would paint, filtered to the ones
        -- carrying a helper mark. The Any Buff pool also holds the user's unrelated work,
        -- and rendering that here would show effects this page does not control.
        if P and S.PIH_PreviewPool and P.CreateFramePreview then
            -- ⚠ THE DESIGNER'S OWN FORM, not the band's. Non-compact is what gives this the
            -- "FRAME PREVIEW" caption and the Preview Scale SLIDER rather than the band's
            -- glyph in the corner -- Krathe asked for the designer's treatment and that is
            -- the difference between the two.
            -- ⚠ placement = false is the one thing suppressed: it gates the nine anchor
            -- dots, the drag hint and the three instruction rows, all of which are about
            -- POSITIONING an indicator. Nothing on this page can be dragged, so offering the
            -- furniture for it would be three lines of instructions for a gesture that does
            -- nothing. It does NOT gate the scale slider.
            local pv = P.CreateFramePreview(leftPanel, 0, nil, { placement = false })
            if pv then
                S.framePreview = pv
                if P.RefreshPreviewEffects then
                    pcall(P.RefreshPreviewEffects, { pool = S.PIH_PreviewPool() })
                end
            end
        end
        rebuilding = false

        if abs((host.layoutHeight or 0) - colH) > 0.5 then
            host.layoutHeight = colH
            host:SetHeight(colH)
            relayout()
        else
            host:SetHeight(colH)
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
