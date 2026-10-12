local NS = ...

-- ============================================================
-- DISPEL OVERLAY: PER-TYPE HIDE
-- DandersFrames/Features/Dispel.lua  applyOverlayHides
-- ------------------------------------------------------------
-- A hidden type comes off every slot the way the talent-aware exclude does: an
-- including slot loses it (and goes when empty), any other slot excludes it, and
-- no table the plan shares is written. The real helpers are lifted by name.
-- ============================================================

print("-- Dispel overlay: per-type Hide")

local src = df_file_source("Features/Dispel.lua"):gsub("\r\n", "\n")
local a = src:find("local OVERLAY_HIDE_KEYS = {", 1, true)
local b = src:find("\nlocal function dispelSlotPlan(db, selfOnly)", 1, true)
check(a ~= nil and b ~= nil and a < b, "overlay: the hide helpers sit just above the slot plan")
if not (a and b) then return end
local hiddenOf, apply = assert(loadstring(src:sub(a, b) .. "\nreturn overlayHiddenTypes, applyOverlayHides"))()

check(hiddenOf({}) == nil, "overlay: nothing ticked, nothing hidden")
local h = hiddenOf({ dispelOverlayHideBleed = true })
check(h and h.Bleed and not h.Magic, "overlay: the Bleed key hides Bleed only")

local shared = { Disease = true }
local slots = {
    { key = "main", candidateFilters = { excludeDispelTypes = shared } },
    { key = "gap",  candidateFilters = { includeDispelTypes = { Bleed = true } } },
}
local out = apply(slots, h)
check(out and #out == 1 and out[1].key == "main", "overlay: the self-bleed slot goes when its only type is hidden")
local ex = out and out[1].candidateFilters.excludeDispelTypes or {}
check(ex.Disease and ex.Bleed, "overlay: the main slot keeps its talent exclude and gains the hidden type")
check(shared.Bleed == nil, "overlay: the shared exclude table is untouched")
check(apply({ { key = "main" } }, nil)[1].key == "main", "overlay: no hidden types leaves the plan as it was")
local marked = { mode = "alltypes", { key = "main", candidateFilters = {} } }
check(apply(marked, h).mode == "alltypes", "overlay: the rebuilt plan keeps its mode marker (the tuning signature reads it)")
local parked = apply({ { key = "x", candidateFilters = { includeDispelTypes = { Bleed = true } } } }, h)
check(parked and #parked == 1 and parked[1].candidateFilters.maxDuration == 0
      and parked[1].candidateFilters.includeDispelTypes == nil,
      "overlay: every type hidden parks the main slot (match nothing), never a nil plan")
check(src:find('tu[#tu + 1] = slots[i].key .. ":md=" .. tostring(scf.maxDuration)', 1, true) ~= nil,
      "overlay: ...and the park moves the tuning signature, so it is applied")
