# Plan: dispel-type symbol + icon on the aura containers

**Status:** SCOPED, NOT BUILT. Parked for later (Krathe, 2026-07-14).

**Goal:** optional dispel-type **icon** and dispel-type **text** ("Ma" / "Cu" / "Di" / "Po")
rendered on the buff/debuff container buttons — the same type cues the dispel overlay
shows, but per aura icon. Primarily a clarity / colourblind aid (a coloured border alone
is the only type cue on the rows today).

---

## 1. Key finding — there is NO secret barrier here

Unlike the dispel-overlay **custom-colour** problem (which is genuinely unimplementable —
see §4), both of these are **engine-driven**. Blizzard knows the dispel type and writes the
cue for us, so DF never reads `dispelName`. Zero aura reads → works in combat, M+, and on
private/boss auras.

`Frames/AuraContainer.lua:54-55` is the governing constraint:

> Cannot read `IsShown` / `spellId` / `expirationTime` / `dispelName` / `presence` — all
> secret. Never branch on them. Filtering is Blizzard-side (filterString + candidateFilters).

The native binds route around that entirely.

---

## 2. What the API already gives us

### Text (the "Ma"/"Cu"/"Di"/"Po" symbol) — `SetAuraSymbol`

**Already implemented in the engine and completely unused.**

- `AuraContainer.lua:638-641` — on `dispelSpec.nativeSymbol`, creates a **FontString**
  (`slot.dfSymbol`, holder level 7, `GameFontNormalLarge`, anchored CENTER).
- `AuraContainer.lua:738-744` — binds it: `slot:SetAuraSymbol(slot.dfSymbol,
  { showWhenHarmful, showWhenHelpful })`. **The engine writes the symbol text into it.**
- **No consumer passes `nativeSymbol`.** Built, wired, never switched on or tested.

This is the intended mechanism for exactly this feature. It is **sort-neutral** (one group,
normal ordering preserved).

### Icon (the badge / orb) — `SetAuraBorder(..., showIcon)`

- `AuraContainer.lua:727-731` binds `SetAuraBorder(texture, { style, showWhenHarmful,
  showWhenHelpful, showIcon = false })`.
- **`showIcon = false` is HARDCODED.** Unhardcoding is a one-liner.
- ⚠️ **Art caveat — already rejected once.** `Features/Dispel.lua:1145-1148`:
  > Type icon: per-type slots (`includeDispelTypes` = type knowledge WITHOUT a native bind)
  > carrying DF's clean RaidFrame-Icon atlases. **The native Atlas style was tried first and
  > rejected: its `ui-debuff-border-*-icon` art is a BUTTON BORDER with a badge — renders as
  > a boxed icon** (Krathe, 2026-07-10).

  So expect the native icon to look wrong. Verify before committing to it.

---

## 3. The two routes for the ICON (and the important asymmetry)

| Route | How | Pro | Con |
|---|---|---|---|
| **A. Native** | unhardcode `showIcon` | 1-line; engine-drawn; sort-neutral | likely the "boxed icon" art already rejected |
| **B. Per-type groups** | `candidateFilters.includeDispelTypes` per type; DF stamps its own clean `RaidFrame-Icon-Debuff*` atlas + text at declare time | full DF art control (clean atlas, own colours/size/font) | **segments the debuff row by dispel type** |

### Why per-type groups DON'T duplicate here (unlike the overlay)

The overlay stacks on multi-type units because a **unit** can carry several dispel types at
once. But an **aura has exactly one dispel type**, so on aura *buttons* each debuff lands in
exactly ONE type group — **no duplicates**.

### The real cost of Route B

Container groups lay out **in sequence**, so per-type groups would render the debuff row
**segmented by type** (all Magic, then Curse, then Disease…), destroying a unified sort
(by time remaining etc.) across the row and adding more filter-block boundaries. For a
*row* that's a genuine regression; for the single-indicator overlay it was free.

---

## 4. Why the dispel-overlay CUSTOM COLOUR problem is different (context)

Recorded so this isn't relitigated. Custom per-type overlay colours need the type known at
**declare** time → one slot per dispel type → on a Magic+Curse unit **both slots show** →
stacked overlays. `candidateFilters` are **per-aura predicates**, so you cannot express
"Curse only if no Magic". And you cannot suppress the loser, because that means reading
`presence`/`IsShown` — explicitly secret. Blizzard's own priority (own-dispellable first,
then oldest) happens **inside a single slot**, before DF sees anything; it is not an exposed
knob. Removed 2026-07-11 (`Dispel.lua:1117-1120`).

**None of that applies to this plan** — the symbol/icon are engine-written per aura.

---

## 5. Recommendation

1. **Wire the native symbol for the TEXT.** It's the intended mechanism, already coded,
   sort-neutral, zero reads. Highest value / lowest risk.
2. **For the ICON: flip `showIcon` and LOOK at it first.** If it's the boxed badge again,
   probably drop it — the coloured border + the letter already convey the type, and Route B
   costs the row's sort order (not worth it).

---

## 6. Work required (if greenlit)

1. `AuraContainer.lua:730` — `showIcon = false` → `showIcon = dispelSpec.showIcon`.
2. `Features/Auras.lua:576-586` — the `dispel` spec is currently built **only** when
   `db.debuffBorderColorByType` is on. **Decouple it**, so the symbol/icon can be toggled
   independently of the colour-by-type ring:
   `if prefix == "debuff" and (colorByType or showSymbol or showIcon) then`
3. Config defaults + export keys + GUI toggles; for the symbol also font / size / outline /
   colour / anchor / offset (it's a plain FontString we own).
4. Locale strings (all user-visible text localised).
5. Buffs get it free if wanted — the spec already carries `showWhenHelpful`
   (stealable / purgeable).
6. Test-mode preview parity.

---

## 7. Unknowns — need an in-game `/al` probe before building

- What does the native symbol actually **render**? Two-letter abbreviations like the
  reference screenshot, or a single glyph?
- Is it **already coloured by dispel type** by the engine, or plain/white?
- Can we **restyle** the FontString (font / size / outline / anchor / colour), or does the
  engine own its look? (Content is engine-written either way. If the string is *secret* we
  can still display it — we just can never read or measure it, which is fine.)
- Note: we can NOT colour the symbol **per type** ourselves — that would need the type.
  Either the engine colours it, or it's one DF colour for all types.
- What does `showIcon = true` actually draw on an aura button?
