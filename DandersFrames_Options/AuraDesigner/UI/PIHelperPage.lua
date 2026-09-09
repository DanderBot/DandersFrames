-- Power Infusion Helper — the nav entry, and nothing else.
--
-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's, so every
-- DF.* read here would be nil. Take the parent's table from the global it publishes at
-- DandersFrames/Core.lua:9 (`_G[addonName] = DF`). Same preamble as the other AD parts.
local DF = DandersFrames
local S = DF.AuraDesigner._uiState
local L = DF.L

-- ============================================================
-- ☠☠ THIS FILE USED TO BE A WHOLE PAGE. IT SHOULD NEVER BE ONE AGAIN.
-- ============================================================
-- Over one afternoon it grew a split layout, a frame preview, a tab bar, an add flow, an
-- effect list and a settings column -- roughly 290 lines, every one of them a WORSE COPY of
-- something the Aura Designer already had twenty lines away. Krathe, after the third
-- screenshot: "what have you done... It should basically function EXACTLY as AD. It should
-- BE AD not a copy of it."
--
-- ★ AND THE ANSWER WAS HIS: "maybe we put it as a tab at the top of AD next to Any Buff...
-- and then the Power Infusion Helper in the menu just instant links to that."
--
-- So the helper is a fourth POOL -- My Buffs / Debuffs / Any Buff / Power Infusion Helper --
-- and every surface the designer owns works on it unchanged, because they all route through
-- the pool accessors in AuraDesigner/UI/Options.lua (CurrentAuraPool, CurrentAuraPoolWrite,
-- PoolKeyPrefix, IsOtherTab, VisibleLayoutGroups). The preview, the add tiles, the effect
-- cards: one implementation, four pools.

-- ============================================================
-- ☠☠ IT IS A LINK NOW, NOT A SECOND PAGE. AND THE SECOND PAGE IS WHAT WENT BLANK.
-- ============================================================
-- The first version of "the door" was a real page whose builder called the designer's
-- builder. Both pages then wanted the same island -- S.mainFrame, the one frame the classic
-- layout builds everything into -- and the designer's builder can only ever parent it to ONE
-- of them. Giving each page its own build (the S.mainFrameOwner guard) fixed the overlapping
-- widgets and traded them for something worse:
--
--   · open the helper's entry     -> full build, island parented to the HELPER's page
--   · open the Aura Designer      -> full build, island reparented to the DESIGNER's page
--   · open the helper's entry     -> the harness's cache is still valid, so its builder is
--                                    NOT re-run (GUI/Panel.lua RefreshCached: a valid cache
--                                    calls RefreshStates and returns) -- and RefreshStates
--                                    on this page is AuraDesigner_RefreshPage, which redraws
--                                    the island WHEREVER IT IS. It is on the other page.
--                                    ⇒ A BLANK PAGE, until something invalidates the cache.
--
-- Krathe, 2026-09-09: "the PI helper is blank sometimes when you select it in the side menu
-- vs via AD." Sometimes, because it is whichever of the two pages did not build last.
--
-- ⚠ THE LESSON IS THE SAME ONE AS THE COMMIT BEFORE IT, and I did not learn it the first
-- time: a page-cache hit does not re-run the builder, so ANY state a builder sets up for its
-- page has to survive without it. An island that can only be parented to one page at a time
-- cannot be shared by two pages under a cache that skips the reparenting.
--
-- ⇒ ONE PAGE OWNS THE ISLAND -- the Aura Designer's, which is the page the island is FOR --
-- and this entry is a LINK to it, exactly as Krathe described the design. Clicking it asks
-- for the helper's pool and selects the designer's own nav row; nothing here builds anything.
-- ============================================================

-- What the nav row does INSTEAD of opening its own page. Also what the fallback button on
-- the stub page below calls, so there is one definition of "go to the helper".
--
-- ⚠ INVALIDATE BEFORE SELECT, AND THAT ORDER IS THE WHOLE FUNCTION. SelectTab takes the
-- cache path on a page that has already been built -- which is exactly the case here, since
-- the designer is where the user just was -- and the cache path never re-reads the pool. So
-- the request is made (S.pendingBuffTab), the cache is dropped, and only then is the page
-- selected: the rebuild that follows consumes the request. Without the invalidate this is
-- the blank-page bug again with the pool wrong instead of the parent.
function DF.OpenPIHelperInDesigner()
    if not (DF.IsPIHelperAvailable and DF.IsPIHelperAvailable()) then return false end
    local GUI = DF.GUI
    if not (GUI and GUI.SelectTab and GUI.Pages and GUI.Pages["auras_auradesigner"]) then
        return false
    end
    -- ⚠ BOTH, for the reason the designer's own build records: the PENDING one survives a
    -- full build (which resets the pool as part of its teardown), and the DIRECT one is what
    -- any path that skips the full build reads.
    S.pendingBuffTab = "pihelper"
    S.activeBuffTab  = "pihelper"
    -- Triggers is the helper's first tab, and someone who asked for the helper by name wants
    -- the helper's first tab -- not whichever sub-tab the designer was left on. The build
    -- would coerce a Layout Groups anyway (P.CoerceTabForPool), but coercion is a safety net
    -- and this is a choice: the entry means "show me the Power Infusion Helper".
    -- ⚠ THE KEY IS "global". On this pool that button is labelled Triggers and drawn first
    -- -- see P.SubTabDefs for why it is a relabel rather than a tab of its own.
    S.activeTab = "global"
    local page = GUI.Pages["auras_auradesigner"]
    if page and page.Invalidate then page:Invalidate() end
    GUI.SelectTab("auras_auradesigner")
    -- ⚠ AND THE RAIL GOES ON THE ROW THEY CLICKED, not on the row that owns the page.
    -- SelectTab has just lit the Aura Designer, which is true about the page and wrong about
    -- the click. Krathe: "clicking power infusion helper on the menu should highlight it."
    -- ⚠ AFTER SelectTab, never before -- its own tail clears every row and lights one, so a
    -- highlight set first would simply be undone.
    if GUI.SetNavHighlight then GUI.SetNavHighlight("auras_pihelper") end
    return true
end

-- ============================================================
-- THE STUB PAGE -- REACHED BY SEARCH, NOT BY THE NAV ROW
-- ============================================================
-- ⚠ IT EXISTS BECAUSE CreateSubTab BUILDS A PAGE WHETHER OR NOT ANYTHING SHOWS IT, and the
-- settings search can select any tab by name. The nav row is re-pointed at the designer
-- (GUI/Pages/Auras.lua), so in normal use nobody ever lands here -- but "nobody ever" is not
-- "nothing can", and the failure mode of an unhandled arrival is the blank page this whole
-- rework exists to remove. One banner and one button is cheap insurance.
-- ⚠ IT DOES NOT REDIRECT ITSELF. Calling SelectTab from inside a page's own builder is a
-- re-entrant page switch during a build; the button makes the same trip as an ordinary click.
function DF.BuildPIHelperPage(guiRef, pageRef, dbRef, Add, AddSpace)
    if not Add then return end
    local GUI = guiRef or DF.GUI
    local banner = GUI:CreateInfoBanner(pageRef.child, { tone = "info" })
    banner:SetText(L["The Power Infusion Helper is a tab inside the Aura Designer."])
    Add(banner, nil, "both")
    -- ⚠ NO EXTENSION ON THE ICON NAME. CreateIconButton concatenates the Media\Icons path and
    -- nothing else, and every other call site passes a bare name ("delete", "refresh").
    local btn = GUI:CreateIconButton(pageRef.child, "chevron_right",
        L["Power Infusion Helper"], 220, 22, function() DF.OpenPIHelperInDesigner() end)
    Add(btn, 22, "both")
end

-- ============================================================
-- IS THE HELPER OFFERED AT ALL?
-- ============================================================
-- ☠ CLASS, NOT SPEC, AND CONSTANT FOR THE LOGIN. Power Infusion is a priest ability and a
-- character cannot change class in session -- which is what all three callers want:
-- CreateSubTab's `hidden` flag decides whether the nav entry is BUILT, PoolDefs decides
-- whether the pool tab exists at all, and OpenPIHelperInDesigner refuses to send anyone to a
-- pool that is not there.
-- ⚠ Deliberately NOT gated on the helper existing. A page that appears only once you have
-- already added the helper is a page you cannot use to add it.
function DF.IsPIHelperAvailable()
    local _, class = UnitClass("player")
    return class == "PRIEST"
end
