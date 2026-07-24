# Frame-level border/tint via the |T reveal — exploration

Status: **EXPLORATION (nothing built).** Question: can we cleanly put a border or tint over
the *whole unit frame*, driven by remaining time, using the same secret-safe `|T`-in-fontstring
reveal the icons use? Resume with the probes in §6.

> **★ PTR-6 UPDATE (datamined build 68824, 2026-07-21):** the hoped-for `SetAuraBorder`
> colour-curve path does **NOT** reopen frame borders. The real `CustomAuraButtonBorderOptions`
> curve/map (`customDispelColorMap` / `customDispelColorCurve`) colours the border by **dispel
> type**, evaluated via `GetAuraDispelTypeColor` — there is **no time-remaining input**, so it
> can't drive an expiry reveal at all. Frame border stays dead; the `|T` companion remains the
> only secret-safe remaining-time reveal, and (per below) only the TINT survives the font-scaling.
> The dispel curve/map is a Dispel-Overlay lever, not an expiry one.

## 1. The one variable that decides everything: the `|T` is font-coupled

The reveal is an inline `|T` texture inside a **fontstring**, swapped in below the threshold by
a `SetDurationText` band formatter. The critical, empirically-confirmed fact:

> **A `|T`'s on-screen size scales with the fontstring's font size**, not just its baked
> `:height:width:` numbers.

Evidence:
- **Icon (works):** we bake the `|T` at `iconSide × 0.75` **and** set the font size to that same
  value; it renders at ~`iconSide`. (`BORDER_ICON_RATIO = 0.75`.)
- **Bar (failed — tiny):** `resolveBarSize` returns the *full* frame width, and the bar itself
  renders full width, so the geometry was right — but the code sets the font size to the bar
  *height* (`~6px × 0.75 ≈ 4`). `SafeSetFont` passes a size of 4 straight through (it only
  clamps `<= 0`). A ~4pt font collapses the whole `|T`, however wide it's baked.

So the enemy is **a thin target**: a short target ⇒ tiny font ⇒ collapsed `|T`. Width is not the
problem; the small *height*-driven font is.

## 2. Why a whole frame is a fundamentally better candidate than a bar

A unit frame is **tall** (≈ 32–48 px) where a duration bar is thin (≈ 6 px). So the height-driven
font size is a healthy ~24–36 pt, not the ~4 pt that killed the bar. The exact formula that failed
for the bar (`bake = dim × 0.75`, `font = height × 0.75`) may well **just work for a frame**,
purely because the frame isn't thin. That is the single most important thing to test (§6, Probe A).

Aspect is also milder: a party frame is ~2.5:1, a raid frame ~2:1, versus a bar's ~15–20:1. A
**solid fill** stretches to any aspect with no artifacts (nothing to distort), so a frame **TINT**
is the natural fit.

## 3. Options, enumerated

### A. Frame TINT — a solid full-frame wash  ✅ most promising
One `|T` of a solid white texture, tinted, baked to the frame's `width × height` (×0.75),
centred on a companion sized to the frame, revealed below the threshold. No thin dimension, mild
aspect, healthy font size. This is the "unit flashes red as the buff expires" cue — the high-value
one for healers. **Verdict: plausible; blocked only on the scaling-law calibration (§6).**

### B. Frame BORDER — single `|T` frame texture  ❌ distorts
A square 64×64 frame art stretched to a 2.5:1 frame gives borders ~2.5× thicker on the sides than
top/bottom (e.g. 6 px vs 2.5 px). Less extreme than a bar, still visibly lopsided, and it varies
with every frame aspect (party vs raid vs layout). Not clean.

### C. Frame BORDER — four solid edge strips  ❌ thin strips collapse
Build a border from four solid `|T` strips (top/bottom = wide+thin, left/right = thin+tall), each
a solid line so stretching is artifact-free and thickness is uniform regardless of aspect. Elegant
in theory — **but every strip has a thin dimension (the border thickness ≈ 2–4 px)**, which drives
a tiny font and collapses the strip exactly like the bar. Same wall. Also 4 companions per frame
(×40 in a raid = 160 extra containers) is a real perf cost.

### D. Non-`|T` mechanisms (for completeness)  ❌
- `SetDurationBar` (a StatusBar over the frame) drains continuously — it can't threshold to "last
  N seconds", and there's no native way to reveal it only below a threshold.
- Presence covers (the healthbar/border indicators) toggle on *aura present*, not *remaining < N* —
  there is no secret-safe remaining-time presence gate.
- `|A` atlases behave like `|T` (same font-coupling), no advantage.
- Tiling multiple `|T`/`\n` into a grid: alignment + sizing is unmanageable, not clean.

**So `|T` is the only viable remaining-time frame reveal, and only the solid TINT survives.**

## 4. Provisional verdict

- **Frame TINT (full-frame wash): looks achievable** — worth the probes. If the scaling law is
  linear (the 0.75 icon relationship holding at frame scale), the existing rectangular engine
  may need only a font-size tweak (don't drive font off a tiny dimension) to work.
- **Frame BORDER: stays an icon/square feature** — a border is inherently thin, so it hits the
  bar's collapse (4-strip) or aspect distortion (single-|T). "So be it," per the ask.

## 5. If the tint works — the rest of the wiring (already mostly solved)
- **Engine:** the rectangular `EffectiveSize` / `|T` w×h path already exists (Phase A). The only
  likely change is decoupling the font size from the baked height (bake big, pick a font that
  scales the `|T` to size — TBD by the calibration).
- **Companion over the frame:** frame-level indicators already position covers sized to
  `fdb.frameWidth/frameHeight` (`syncFrameLevelMissing` in Factory.lua); a tint companion reuses
  that. One companion per frame (cheap, unlike the 4-strip border).
- **GUI:** the shared `GUI:CreateExpirationControls` with `include = { border=false, tint=true,
  match=false }` — same opt-in pattern as the bar. No hand-rolled GUI.
- **Layering/alpha:** draw above the frame content with the existing Opacity so the frame reads
  through the wash.

## 6. Probes for tomorrow (resolve the unknowns in DF_AuraLab / a `/df` command)

The whole feasibility reduces to the `|T` scaling law. Concrete, ordered:

1. **Probe A — does the frame tint "just work"?** Point a rectangular tint companion at a real
   frame (reuse the Phase-A rect engine; geometry = `fdb.frameWidth × frameHeight`). Look: does
   the wash cover the frame, or is it mis-sized? A frame's height gives a ~24–36 pt font, so this
   may already be right. Fastest signal.
2. **Probe B — derive the law (if A is off).** In a fontstring, render a solid `|T` and sweep two
   knobs independently: (i) fix baked `h:w`, vary font size (10/20/30/40) → measure on-screen size;
   (ii) fix font, vary baked → measure. Two sweeps give `rendered = f(baked, fontSize)`. Then solve
   for `(baked, font)` that hits a target `width × height`.
3. **Probe C — aspect check.** With the law known, render a wide `|T` (frame aspect) and confirm
   width and height land where predicted (isotropic-with-font vs independent).
4. **Probe D — layering.** Confirm the companion, sized/anchored to the frame, lets the `|T` cover
   the whole frame (overflow/anchor), and that Opacity keeps the frame legible under the wash.

If A (or B→calibration) yields a clean full-frame wash: build it as a frame-level TINT consumer of
DF.Expiration (health-bar / frame types), Border stays icon-only. If the law can't be made to fill
a frame cleanly: tint is an icon/square feature and frame-level expiry is Text/Glyph only.
