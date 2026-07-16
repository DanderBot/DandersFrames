# Unified Border & Expiry System

This document describes the unified border-rendering and aura-expiry system and
the shared options GUI that drives them. Every border and every "aura is
expiring" reaction in the addon flows through the four pieces below — consumers
opt features in or out; they do not re-implement them.

## Architecture at a glance

| Layer | Module | Responsibility |
|---|---|---|
| Render engine | `DF.Border` (`Frames/Border.lua`) | Draws & animates *every* border. One spec format, one renderer. |
| Expiry engine | `DF.Expiring` (`Frames/Expiring.lua`) | One registry + one ~3 FPS ticker drives *every* expiring reaction. Secret-safe. |
| Border GUI | `GUI:CreateBorderControls` | Emits the entire border options block; features toggled per consumer via `include.*` flags. |
| Expiry GUI | `GUI:CreateExpiringControls` | Emits the entire expiring options block; keyed to each consumer's DB schema via `opts.keys` + `include.*`. |

Design rule: a consumer opts a feature in or out; it never re-implements it. The
options panel for every border looks and behaves identically — a feature that
doesn't apply is simply not shown.

## `DF.Border` — the render engine

`DF.Border:New(frame)` returns a border object. `:BuildSpec(db, prefix)` reads a
consumer's DB keys into a spec; `:Apply(spec)` renders and animates in one call.
`:SetColor` / `:RecolorActive` / `:StartAnimation` / `:StopAnimation` handle live
updates.

Static appearance features:

- **Style** — `Solid`, `Gradient` (two-colour), or `Texture` (any LibSharedMedia
  border). Gradient is a *style*, not a separate toggle.
- **Thickness** — per-consumer min/max range.
- **Inset** — pulls the border in/out from the frame edge.
- **Offset X/Y** — nudges the border band (where enabled).
- **Alpha** — unified border alpha; on class/role-coloured borders the colour's
  alpha is the source.
- **Colour modes** — flat colour, plus opt-in **Class Colour** and **Role
  Colour** sources.
- **Shadow** and **Blend Mode** — opt-in.

### Animations (opt-in via `include.animate`)

| Type | Engine | Sub-controls |
|---|---|---|
| Pulsate | LibCustomGlow PixelGlow (pixel ring of N particles) | Frequency, Particles, Thickness, Inset/Offset, +mask toggle |
| DF Pulsate | native — gentle alpha fade of the border itself | Frequency only (no colour/positioning) |
| Chase | LibCustomGlow AutoCastGlow (rotating ring) | Frequency, Particles, positioning |
| Flash | LibCustomGlow ButtonGlow | Frequency |
| Proc | LibCustomGlow ProcGlow (proc-start flash) | Frequency, positioning |
| Wipe | custom overlay | Frequency, Thickness, positioning |
| Ripple | custom overlay | Frequency, Thickness, positioning |
| Segment Reveal | custom overlay | Frequency, Thickness, positioning |
| Sides Only | custom overlay | Thickness, positioning |
| Corners Only | custom overlay | Thickness, positioning |
| DF Dash | native marching-ants | Frequency = march **speed** (0 = static dashed), Thickness = dash size, positioning |

Sub-controls auto show/hide per type, so the panel only ever shows what the
chosen effect supports.

## `DF.Expiring` — the expiry engine

One registry, one shared ticker (~3 FPS), one evaluation function used by both
the immediate-register path and the ticker, so they can never drift.
**Secret-value-safe by construction**: in combat, aura remaining-time is tainted,
and the engine never branches on it.

Capabilities:

- **Threshold** in **Percent** or **Seconds** (a toggle, not two systems).
- **Colour curve** — a secret-safe `C_CurveUtil` curve evaluated through the
  aura's Duration object. Below threshold → expiring colour; above → original.
  Works on secret auras.
- **Tint** — a colour overlay gated by a visibility curve + `SetAlphaFromBoolean`;
  secret-safe, so it works on *any* aura including secret buffs/debuffs.
- **Manual twin** (`GradientColorAt` / `EvaluateManualColor`) — the non-secret
  evaluation used for preview auras (no Duration object), sharing one home for
  the gradient + threshold maths.
- **Effects trio** (non-secret, Aura Designer only): **Fill Pulsate**,
  **Whole-Alpha Pulse**, **Bounce**.

Why tint is universal but the effects trio is AD-only: the animation trio has to
branch on the (possibly secret) remaining time, which would taint combat
execution on live frames. Tint rides the secret-safe alpha-from-boolean path, so
it is safe everywhere.

## The unified GUI builders

`CreateBorderControls(group, db, prefix, opts)` emits Show Border, Thickness,
Style (Solid/Gradient/Texture), Colour (+ Class/Role source dropdown), Alpha,
Inset, Offset, Blend Mode, Shadow, and the full Animation panel. Each is gated by
an `include.*` flag and hides when Show Border is off.

`CreateExpiringControls(group, db, opts)` emits the master toggle, the threshold
row (slider + Percent/Seconds toggle button), colour override / dual colour,
alpha, thickness, inset, the animation panel, tint, and the icon-effects
sub-block. Keyed via `opts.keys` so each consumer's DB schema drives the same UI.

## Feature matrix — Borders

Check mark = feature exposed for that consumer.

| Consumer | Style+Gradient | Class | Role | Alpha | Inset | Offset | Blend | Shadow | Animate | Thickness |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|---|
| Frame Border | x | x | x | x | x | x | x | x | | 1–16 |
| Pet Frame | x | | | x | x | | x | x | | 1–6 |
| Resource/Power Bar | x | x | x | x | x | | x | x | | 1–6 |
| Defensive Icon | x | x | x | x | x | x | x | x | x | 0–8 |
| Buff Icon | x | | | x | x | x | x | x | x | 0–8 |
| Debuff Icon | x | | | x | x | x | x | x | x | 0–8 |
| Missing Buff Icon | x | | | x | x | | x | x | x | 1–6 |
| Targeted List | x | | | x | x | | x | x | | 1–6 |
| Personal Targeted Spell | x | | | x | x | | x | x | x | 1–5 |
| AD — Icon | x | | | x | x | x | x | x | x | 0–8 |
| AD — Square | x | | | x | x | x | x | x | x | 1–5 |
| AD — Bar | x | | | x | x | | x | x | x | 1–5 |
| AD — Bar Indicator | x | | | x | x | x | x | x | x | 0–8 |

Class/Role colour is reserved for the structural unit-frame chrome (Frame,
Resource Bar, Defensive Icon).

## Feature matrix — Expiring

The animation effects trio is the secret-value-sensitive set, hence Aura Designer
only.

| Consumer | Threshold | Border colour | Dual colour | Colour-by-time | Alpha | Thickness | Inset | Animation | Tint | Fill Pulsate | Whole-Alpha | Bounce |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Buff (live frames) | x | x | | x | x | 1–5 | x | x | x | | | |
| AD — Icon | x | x | | | x | 0–5 | | x | x | | x | x |
| AD — Square | x | x | x | | x | 0–5 | | x | x | x | x | x |
| AD — Bar | x | x | | | x | 0–8 | | x | x | | | |

Notes:

- **Tint is universal** — the one expiring effect safe on secret buffs/debuffs
  (red at 50% by default, matching the border red `#FF3333`, with a "Default"
  button).
- **Fill Pulsate** is Square-only (the only type with a fill region to pulse).
  **Whole-Alpha Pulse** and **Bounce** apply to Icon + Square. **Bars** signal
  expiry through their fill colour, so they take tint but none of the icon-pulse
  effects and have no separate expiring border.
- **AD bar fill** colour expiry is driven by the engine on both paths: live
  frames evaluate the colour curve via the Duration object; preview uses
  `DF.Expiring:EvaluateManualColor`.

## Intentionally outside this system

These remain separate by design and are not routed through the helpers: the
**Dispel overlay** borders (need direct StatusBar colour control), the
**Highlights / marching-ants selection** system, and the legacy **Targeted
Spell** page (superseded by Targeted List). (Masque integration has been
retired — Masque cannot skin the 12.1 container aura buttons.)

## Performance

This section compares the unified system against the prior baseline. Short
version: for a typical configuration it is **CPU-neutral-or-better** at steady
state, and smoother on frame-time. The only added cost is a small amount of
memory.

### What did not change

The baseline already drew **four real edge textures** per aura icon (it was never
a single "spoof" background), and already had expiring indicators driven by a
single shared timer. So the unification did not add textures to auras or
introduce expiry as new per-frame work.

### Render — event-driven, neutral-to-better

Every border re-styles only on events (aura/power updates, settings changes),
never on a per-frame tick. At steady state, borders cost **zero** CPU.

- Pet Frame, Resource Bar, and the AD Bar **dropped a `SetBackdrop` mixin** in
  favour of four lightweight `ColorTexture` edges — a small allocation win.
- The one cost: `DF.Border` wraps each border's four edge textures in **one
  container frame**. For consumers that previously used loose textures (the aura
  icons), that's **+1 empty frame per bordered icon** — no script, zero per-frame
  CPU. Worst case in a 40-man raid is a few hundred such frames (~1-2 MB,
  one-time), well below the noise floor of a real profile.

### Expiry — one shared, throttled engine

`DF.Expiring` runs **one** ticker for the whole addon. It wakes ~3 FPS, but each
registered entry only re-runs its (relatively expensive) Duration-curve
evaluation on a **per-entry interval (default 1.0 s), staggered** so a burst of
registrations doesn't land every entry on the same tick.

That 1.0 s interval matches the baseline's effective rate — its shared aura timer
woke at 5 FPS but was itself internally throttled to ~1 FPS per icon. So
steady-state evaluations per icon are **at parity**, and the explicit stagger
spreads the work more evenly than the baseline's incidental staggering did.
Freshly-registered entries (an aura just appeared or refreshed) still evaluate
immediately, so there's no first-frame flicker. The interval is a single tunable
constant — lower for snappier colour response at more cost.

### Opt-in features cost only when enabled

- **Tint** adds a registry entry per tinted icon (secret-safe, alpha-gated) —
  only when the user turns it on.
- **Animations** add a per-border `OnUpdate` driver (and glow effects spawn
  particle textures). This is the one thing that can bite at scale, so it is
  **off by default, fenced behind an explicit opt-in, and carries a perf
  warning** in the options UI. Borders without animation are static textures —
  effectively free once placed.

### Options GUI

The shared option builders instantiate some hidden-but-created widgets so
tab-switches just show/hide instead of rebuilding. That's a modest one-time
startup/memory cost (a few hundred extra widget objects across all settings
pages) and is **never on a gameplay hot path** — all of it is click-driven.

### Verdict

For a normal setup (solid/gradient borders, optional expiring colour, no per-icon
animation), the unified system is **perf-neutral to slightly better** at steady
state, trading a negligible per-icon container-frame memory cost and a one-time
heavier GUI build for the unified architecture and the new opt-in capabilities.
The only way to make it meaningfully heavier is to enable animations on auras at
raid scale — which is deliberately fenced.
