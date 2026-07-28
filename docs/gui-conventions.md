# DandersFrames GUI conventions & shared helpers

The settings UI is built on one shared, theme-aware helper layer in `GUI/GUI.lua`. The whole point
is that every panel looks and behaves the same: one theme, one tab style, one tooltip system,
grey-when-disabled everywhere, and fully translatable text.

> This file travels with the repo and with pull requests, but is **excluded from the packaged
> addon** via `.pkgmeta` (`ignore: docs`) — it is for contributors, not for users.

## The core rule — build from helpers, don't hand-roll

1. **Need a button / checkbox / dropdown / slider / edit box / colour picker / tooltip / panel /
   banner / section box?** Use the helper. Do **not** hand-roll a widget a helper already covers.
2. **Helper missing a capability you need?** **Extend the helper** — add an option/mode and keep
   existing callers working — so every consumer benefits. Don't fork a one-off.
3. **Genuinely bespoke and single-use** (a stateful drag widget, a pooled list row, a complex
   custom control where generalising makes no sense)? Then hand-roll — but still reuse the palette
   (`GUI.Colors`), the backdrop helpers, `ShowTooltip`, and wire up grey-when-disabled. Add a short
   comment saying why it's bespoke.
4. **New user-facing text** → wrap in `L["..."]` and add the key to `Locales/enUS.lua`.
5. **New disable-able setting** → wire grey-when-disabled (see below).

If you find yourself copying backdrop/hover/border code from another widget, that's the signal to
use or extend a helper instead.

☠ **Search by what a surface *is*, not by the constructor you expect it to call.** A sweep for
`CreateFrame` / `SetBackdrop` once missed 26 dialogs, because the Blizzard dialog they were built
on uses neither.

## Page layout standard

Every settings page is two columns, and each column has a fixed running order:

```
column 1   Settings  →  Layout  →  Size  →  Position          (geometry / behaviour)
column 2   Appearance  →  Border  →  element extras           (styling)
```

* Boxes may sit inside **collapsible sections**. The rule then applies *within* each section,
  because the section is the sub-feature and its boxes are that sub-feature's set.
* A collapsible section means **"here is another one of these"** — a repeated peer. It is never a
  category heading.
* A surface holding *only* geometry or *only* styling has no left/right distinction to preserve;
  balance the columns instead of emptying one.
* `Appearance` is the column-2 name for a thing's own look (icon size, scale, frame level).
  `Settings` is for what it does and whether it is on.

Established box vocabulary, by how widely it is used: `Settings` · `Position` · `Appearance` ·
`Border` · `Size` · `Layout` · `Duration Bar` · `Duration Text` · `Stack Count` · `Order & Limits`.
Prefer an existing name over a new synonym.

## Theme & look

- **Mode accents:** party = **purple**, raid = **orange**. The active mode drives
  `GUI.GetThemeColor()`; widgets register on `root.ThemeListeners` so they re-tint on mode switch.
- **Fixed-identity accents:** Click Casting = **green**, Search = **blue**. These are deliberate —
  pass them explicitly (`accent = ...`); they do **not** follow the mode theme.
- **Palette:** pull colours from `GUI.Colors` (panel / element / border / text / text-dim / accents).
  Don't hardcode colour literals.
- **Dialogs share the page palette.** `GUI.DialogColors` reuses the *same tables* as `GUI.Colors`
  for every shared neutral, so the two theme-track in lockstep; only what genuinely differs
  (`selected`, the status green/red pair) is declared separately. ⚠ Read-only by convention — the
  tables are shared, so nothing may mutate them.
- Dark panels, 1px borders, a subtle accent hover wash, consistent section boxes and info banners.
- **Icons:** `Media/Icons/*.tga` are **32px white Material Symbols** (~81% glyph fill, even
  padding), tinted at runtime with `SetVertexColor`. Add new icons at the same spec (white, 32px);
  never bake colour into the file.

## The pixel grid

A box lands on the device-pixel grid only if the numbers it was **given** were whole pixels — and
usually they are not (a group's inner width is `width - 2 * padding`, and 10 UI units of padding is
a whole number of pixels only at exactly 1:1 scale). Everywhere else the right and bottom edges
fall mid-pixel and anything clipped by them loses part of itself.

So the **layout** picks whole-pixel numbers at the point each number is chosen:

| Helper | Use for |
|---|---|
| `GUI.SnapLen(frame, v)` | any length or offset — rounds to the *nearest* device pixel |
| `GUI.SnapLenUp(frame, v)` | lengths derived from a **measurement** (a button sized to its own label) — rounding down would clip the text it was measured from |

⚠ **The engine snaps LEFT and BOTTOM only**, so right and top edges depend on the layout handing
out whole-pixel widths — that is what `SnapLen` is for.
⚠ **Size snapping must stay per-surface.** A global default re-triggers a known relayout lockup.

Borders are drawn as two device pixels of our own texture rather than a one-unit backdrop edge, so
they cannot land badly in the first place.

## Row heights are factory-owned

`GUI.RowHeight` is the single source of truth for how tall each control's layout slot is
(`checkbox` 35 · `slider` 46 · `dropdown` 54 · `colorpicker` 38 · `editbox` 53 · `toggle` 35 ·
plus `labelPad` and `sectionHeader`).

☠ **The height a call site passes is IGNORED** for fixed-height widgets. `ResolveRowHeight` reads
`widget.fixedRowHeight` + `widget.preferredHeight` and uses those. To change a row's spacing, edit
`GUI.RowHeight` — do not touch call sites. (`CreateHeader` marks itself `fixedRowHeight` precisely
so ~200 call sites didn't have to be swept.)

Labels are variable height because they wrap, so they have no fixed row — but they do have fixed
chrome, which `CreateLabel` adds to the measured text height.

## Shared GUI helpers (`GUI/GUI.lua`)

49 `GUI:Create*` helpers. The ones you'll reach for:

| Need | Helper(s) | Notes |
|------|-----------|-------|
| Button | `StyleButton(btn, opts)` | modes: `tab` (underline), `ghost`, `primary`, `tinted`; `SetActive` toggle; `SetDisabled`; `tone="danger"/"success"`; opts `text/icon/font/align/accent/width/height` |
| Button (built for you) | `CreateButton`, `CreateIconButton`, `CreateGlyphButton` | wrap StyleButton + a frame |
| Close / delete | `CreateCloseButton` | `tone="danger"` = red glyph for destructive actions |
| Checkbox | `StyleCheckButton(cb, opts)`, `CreateCheckbox(...)` | `CreateCheckbox` is db-bound and auto-calls `parent:RefreshStates()` on toggle so grey-gating updates live; opts `accent/manualCheck/themeRoot` |
| Two-state / segmented | `CreateRowToggle`, `CreateSegmentToggle` | |
| Dropdown | `CreateDropdown(parent,label,opts,db,key,cb, get,set, {accent,inline,optionsFunc})` | exposes `:RebuildOptions` / `:UpdateText` / `:SetEnabled`. **`inline=true` HIDES the label** — use non-inline for a labelled setting |
| Dropdown variants | `CreateTextureDropdown`, `CreateFontDropdown`, `CreateOutlineDropdown`, `CreateSoundDropdown`, `CreateShadowCheckbox` | |
| Slider | `CreateSlider(...,accentColor)`, `CreateRangeSlider(opts)` | customGet/customSet for nested db values |
| Edit box | `CreateEditBox` (db-bound, label + override indicators), `CreateInput` (bare), `CreateTextArea(parent, opts)` (multi-line), `StyleEditBox(eb, {multiline,skipFont})` | |
| Colour | `CreateColorPicker(...)` | hasAlpha + lightweight callback |
| Containers | `CreateSettingsGroup`, `CreateCollapsibleSection`, `CreatePanelBackdrop`, `CreateElementBackdrop`, `CreateMoverBackdrop` | |
| Banner / prose | `CreateInfoBanner` (tones info/caution/warning/danger/success; `:SetContent`), `CreateNote` | |
| Cross-links | `CreateLink`, `CreateSeeAlso`, `CreateColorsPageLink`, `CreateDispelColorsPageLink` | jump to a related page and flash the target section |
| Text | `CreateHeader`, `CreateLabel` | fonts via `SetSettingsFont` / `SafeSetFont` |
| Tooltip (ours) | `GUI:ShowTooltip(owner, {title, lines, ...})` / `GUI:HideTooltip()` | **never** raw `GameTooltip` for our own tooltips |
| Tooltip (game data) | `GUI:ShowGameTooltip(owner, opts)` | for real spells/auras — seeds from `SetSpellByID` / `SetUnitAura`, falls back to `fallbackTitle` + spell ID, then appends our own lines. Re-paints after a late spell load so the appended lines survive |
| Tooltip (canned) | `GUI:SetFrameLevelTooltip(container)` | the standard Frame Level explainer |
| Ordered lists | `CreateClassOrderList`, `CreateRoleOrderList`, `CreateGroupOrderList` | drag-to-reorder |
| Tabs | `StyleButton{tab=true}` | one underline-tab style everywhere |
| Designer presets | `CreateDesignerPresetBar` | AD/TD named-preset bars |
| Growth direction | `CreateGrowthControl` | |
| Border / expiry | `CreateBorderControls` + `CreateExpirationControls` (+ `CreateExpiringSubheader`, `CreateExpiringThresholdRow`) | each consumer opts into a subset via `opts.include` |
| Text style block | `CreateTextControls` | font / scale / outline / shadow / colour / anchor / justify as one unit |
| Animation | `CreateAnimationControls` | border animation type + tuning |
| Override affordances | `CreateOverrideMarker`, `CreateOverrideResetButton`, `CreateDisabledOverlay` | |
| Theme | `GUI.GetThemeColor()`, `GUI.Colors`, `GUI.DialogColors`, `root.ThemeListeners` | |

## Popups — never Blizzard's

There are **zero** `StaticPopupDialogs` / `StaticPopup_Show` calls left in the addon. Use the DF
popup system in `Popup.lua`:

| Call | For |
|---|---|
| `DF:ShowPopupAlert(config)` | a message or a confirm |
| `DF:ShowPopupInput(config)` | a message plus one text field |
| `DF:ShowPopupWizard(config)` | a multi-step flow |

☠ Three things that bite:
* The popup is a **singleton** — park the widgets you aren't using, or the last dialog's leftovers
  show through.
* **Escape only HIDES the frame**; it does not run your cancel path. Do cleanup explicitly.
* In `FilterRegistry`, `GUI` is a function-local — use `DF.GUI` at any call site outside those
  functions. (An out-of-scope local is a legal *global* read in Lua: it parses clean and errors
  only when that branch runs.)

## Grey-when-disabled (the standard gating model)

When a **feature toggle** is OFF, its dependent controls **grey out in place** — visible but dimmed
and non-interactive (a consistent "preview"). They do **not** disappear, and they do **not** stay
clickable. **Variant / mode selection** (party-vs-raid, a dropdown value, a content type, a
color-mode) **HIDES** the controls it gates instead.

- **Group-level grey:** `group.disableChildrenOn = function(db) return <featureIsOff> end`. Greys
  every child of the SettingsGroup except the header (child index 1) and any widget flagged
  `widget.keepEnabled = true` (that's the Enable toggle itself, which must stay live).
- **Per-widget grey:** `widget.disableOn = function(db) ... end` (composes with the group gate).
- **Variant / mode hide:** `widget.hideOn = function(db) ... end`.
- **Every widget helper's `SetEnabled` must visually dim** (it does, via `SetAlpha`) **and block
  input.** When you add a new widget type, give it a `SetEnabled` that dims its *distinctive*
  element (the check fill, swatch, preview, value box — not just the label), or `RefreshChildStates`
  silently skips it and it stays bright while everything around it greys.
- **Do not drive a `SetActive` toggle button via `SetDisabled`** — it fights the hover wash and
  renders a solid fill on hover. Dim a toggle with `SetAlpha(0.4)` + `EnableMouse(false)` instead.
- ⚠ A gate that can *never* fire is worse than no gate: it reads as deliberate and hides the fact
  that a control is unreachable. Check new `hideOn` / `disableOn` predicates against reality.

## Background engines / non-GUI helpers

- **Localization:** `L["..."]` (AceLocale; `local L = DF.L`). Keys live in `Locales/enUS.lua` inside
  the `--@do-not-package@` block. Use `format(L["… %s/%d …"], ...)` for interpolation so translators
  can reorder words. Never hardcode user-facing text — **including slash-command output**, which is
  user-visible too. Store the raw key and resolve at display. Never localize db keys / page IDs /
  texture paths / debug output.
  ⚠ `/df localewarn` swaps the `L` metatable to raise on a missing key. That beats any static
  sweep, because a good number of call sites build their key dynamically (`L[cat.name]`).
- **Border + expiry:** `DF.Border` (render) + `CreateBorderControls` / `BuildSpec` (GUI) +
  `DF.Expiring` (one throttled ticker). ☠ Create the border **and bind it inside `initializeFrame`**
  — that is the secure context; creating outside and binding inside does not work.
- **Fonts:** `SafeSetFont`. Shadows ride the font *object*, not fontstring `SetShadow*` (a no-op
  from 12.0.7 on).
- **Z-order:** `h:ApplyZOrder(cfg)` is the only path. Read the layer map before touching any
  `SetFrameLevel` / `SetFrameStrata`.
- **Secret values / taint (12.1):** never style secure unit frames through the config-UI helpers,
  and never do arithmetic or comparison on secret `UnitPower` / aura values. Aura reads are sealed —
  display goes through the container/button system.
- **Debug output:** `DF:Debug()` / `DF:DebugWarn()` / `DF:DebugError()` — never raw `print()` except
  a deliberate user-facing notice (and that notice must be `L["..."]`).
- ⚠ **A guard that skips required work while a success flag stays set is the antipattern to watch
  for.** If you early-return past setup, log it — a silent skip reads as "it worked".
