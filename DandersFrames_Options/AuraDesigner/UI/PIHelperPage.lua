-- Power Infusion Helper — the nav entry, and nothing else.
--
-- ☠ Companion addon: `...` yields THIS addon's private table, not the parent's, so every
-- DF.* read here would be nil. Take the parent's table from the global it publishes at
-- DandersFrames/Core.lua:9 (`_G[addonName] = DF`). Same preamble as the other AD parts.
local DF = DandersFrames
local S = DF.AuraDesigner._uiState

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
-- cards, the layout groups: one implementation, four pools.
--
-- ⚠ WHAT IS LEFT HERE IS THE DOOR. The nav entry exists because the tab is four levels deep
-- and a priest should not have to know that the helper lives inside the designer -- which was
-- the ORIGINAL complaint ("it's not very clear how to use it or even how to find it"). It
-- opens the designer with that pool selected. That is the whole file.
--
-- ⚠ IF THIS EVER NEEDS A CONTROL THE DESIGNER DOES NOT HAVE, add it to the designer for that
-- pool -- do not grow a page here again. The three rebuilds are in the git history if the
-- argument needs re-making.

-- ============================================================
-- THE PAGE: OPEN THE DESIGNER ON THE HELPER'S POOL
-- ============================================================
-- Signature mirrors DF.BuildAuraDesignerPage so the two register identically in
-- GUI/Pages/Auras.lua and neither is a special case at the call site.
function DF.BuildPIHelperPage(guiRef, pageRef, dbRef, Add, AddSpace)
    -- ☠☠ REQUESTED, NOT ASSIGNED, AND THE DIFFERENCE COST A BROKEN PAGE. Writing
    -- S.activeBuffTab here does nothing on a FULL build: BuildAuraDesignerPage resets the
    -- pool as part of its teardown, so the helper's own nav entry landed on My Buffs with
    -- none of its controls on screen -- and only sometimes, because a REVISIT takes the
    -- reuse path, which leaves the pool alone. Two behaviours from one click.
    -- ⇒ S.pendingBuffTab is a one-shot the builder CONSUMES at the point it would otherwise
    -- have defaulted. Set both: the pending one survives a full build, and the direct one is
    -- what the reuse path (which never touches pending) reads.
    if DF.IsPIHelperAvailable and DF.IsPIHelperAvailable() then
        S.pendingBuffTab = "pihelper"
        S.activeBuffTab  = "pihelper"
    end
    if DF.BuildAuraDesignerPage then
        DF.BuildAuraDesignerPage(guiRef, pageRef, dbRef, Add, AddSpace)
    end
end

-- ============================================================
-- IS THE HELPER OFFERED AT ALL?
-- ============================================================
-- ☠ CLASS, NOT SPEC, AND CONSTANT FOR THE LOGIN. Power Infusion is a priest ability and a
-- character cannot change class in session -- which is what both callers want: CreateSubTab's
-- `hidden` flag decides whether the nav entry is BUILT, and PoolDefs decides whether the pool
-- tab exists at all.
-- ⚠ Deliberately NOT gated on the helper existing. A page that appears only once you have
-- already added the helper is a page you cannot use to add it.
function DF.IsPIHelperAvailable()
    local _, class = UnitClass("player")
    return class == "PRIEST"
end
