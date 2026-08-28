# DandersFrames GUI conventions & shared helpers

The settings UI is built on one shared, theme-aware helper layer in `GUI/GUI.lua`. The whole point
is that every panel looks and behaves the same: one theme, one tab style, one tooltip system,
grey-when-disabled everywhere, and fully translatable text.

> This file travels with the repo and with pull requests, but is **excluded from the packaged
> addon** via `.pkgmeta` (`ignore: docs`) — it is for contributors, not for users.

## The core rule — build from helpers, never hand-roll

**One edit must be able to change the whole addon.** That is the entire point of the helper layer,
and it is not an abstract nicety — before the factory existed, moving a border by one pixel or
changing a hover colour meant editing hundreds of call sites by hand, and the ones that were missed
are exactly why the UI had drifted out of alignment. Every widget that goes through a helper is a
widget the next sweeping change reaches for free. Every widget that doesn't is a site somebody has
to find and fix by hand, forever.

So: **hand-rolling is the last resort, not a judgement call.**

1. **Need a button / checkbox / dropdown / slider / edit box / colour picker / tooltip / panel /
   banner / section box?** Use the helper. Do **not** hand-roll a widget a helper already covers,
   even "just this once" and even if the helper is slightly more than you need.
2. **Helper missing a capability you need?** **Extend the helper** — add an option/mode and keep
   existing callers working — so every consumer benefits. Don't fork a one-off. A new option on an
   existing helper is almost always the right change; a second near-identical widget almost never is.
3. **Nothing fits at all?** Then the answer is usually a **new helper**, not a local widget. If two
   pages would plausibly want it, it belongs in `GUI/`.
4. **Genuinely bespoke and single-use** (a stateful drag widget, a pooled list row, a complex
   custom control where generalising makes no sense)? Only then hand-roll — but still reuse the
   palette (`GUI.Colors`), the backdrop helpers, `ShowTooltip`/`AttachTooltip`, the pixel-snap
   helpers, and wire up grey-when-disabled. Add a short comment saying **why** it's bespoke, so the
   next reader knows it was a decision and not an oversight.
5. **New user-facing text** → wrap in `L["..."]` and add the key to `Locales/enUS.lua`.
6. **New disable-able setting** → wire grey-when-disabled (see below).

If you find yourself copying backdrop / hover / border / spacing code from another widget, stop —
that is the signal to use or extend a helper instead. Copied code is the drift.

## Consistency is the feature

A user should not be able to tell which page they are on from how the controls look or what they
are called. Two things get us there, and both are cheap at the time of writing and expensive later:

- **Uniform layout.** Same two-column order on every page, same box vocabulary, same row heights,
  same spacing — all of which come from the factory, so following the standard is mostly a matter
  of *not* overriding it. See "Page layout standard" and "Row heights are factory-owned" below.
  Call-site geometry that fights the factory is how pages start looking subtly different.
- **Uniform naming.** Reuse the established name for a box, a setting, or an action rather than
  inventing a synonym for the same thing. `Appearance` is always `Appearance`; a thing that adds is
  always `Add`. Different words imply different behaviour, and users read them that way. If a new
  concept genuinely needs a new word, pick one and then use it *everywhere* that concept appears —
  including the locale keys and the tooltips.

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

85 `GUI:` helpers, 49 of them `Create*`. **Check here before you build anything** — the table below
is the widget layer, and the one after it is the behaviour layer that is easiest to miss and most
often hand-rolled by accident.

### Widgets

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
| Containers | `CreateSettingsGroup`, `CreateCollapsibleSection`, `CreatePanelBackdrop`, `CreateElementBackdrop`, `CreateMoverBackdrop` | **`CreateSettingsGroup(parent, width, { bandStyle = true })` is the standard for any box that stays inline on a page that has bands.** The title is drawn as the same accent header the bands use, above the box, and the box becomes a PopoutRow plate — so a swept page reads as one visual language instead of two. Widgets inside are untouched. Declare the opts table **once per page**, gated on `DF:IsClassicSettingsLayout()` (`local INLINE_BOX = (not classicLayout) and { bandStyle = true } or nil`) and pass it by name; the classic branch must get `nil`. See `Pages/Options.lua`'s Frame page |
| Banner / prose | `CreateInfoBanner` (tones info/caution/warning/danger/success; `:SetContent`), `CreateNote` | |
| Cross-links | `CreateLink`, `CreateSeeAlso`, `CreateColorsPageLink`, `CreateDispelColorsPageLink` | jump to a related page and flash the target section |
| Text | `CreateHeader`, `CreateLabel` | fonts via `SetSettingsFont` / `SafeSetFont` |
| Tooltip (attach one) | `GUI:AttachTooltip(widget, label, labelRegion)` | **the one you want for a setting.** Builds the hit frame over the *label's* rect, which is what makes "hover the label, not the control" true everywhere. Reads `widget.tooltip` |
| Tooltip (ours) | `GUI:ShowTooltip(owner, {title, lines, ...})` / `GUI:HideTooltip()` | the raw show/hide, for bespoke owners. **Never** raw `GameTooltip` for our own tooltips |
| Tooltip (game data) | `GUI:ShowGameTooltip(owner, opts)` | for real spells/auras — seeds from `SetSpellByID` / `SetUnitAura`, falls back to `fallbackTitle` + spell ID, then appends our own lines. Re-paints after a late spell load so the appended lines survive |
| Tooltip (canned) | `GUI:SetFrameLevelTooltip(container)` | the standard Frame Level explainer |
| Name prompt | `GUI:PromptName{title, message, default, acceptLabel, maxLetters, onAccept}` | "name this thing" — templates, filters, profiles. Wraps the DF input popup; don't build your own |
| Colour picker (raw) | `GUI:OpenColorPicker(initial, hasAlpha, onAccept, onCancel, onChange, default)` | for bespoke owners; `CreateColorPicker` is the db-bound widget |
| Search / icon in a box | `GUI:AddEditBoxIcon(editbox, texture, size)` | pass `frame.EditBox`, **not** the frame — it insets the text so neither the value nor the hint runs under the icon |
| "New" badge | `GUI:AddSectionNewBadge(widget, tabName, sectionId)` | marks a section as new until seen |
| Gradient preview | `CreateGradientBar(parent, w, h, db, prefix)` | colour-by-time preview strip |
| Debug row | `CreateDebugCategoryRow(parent, categoryKey, description, width)` | Debug page only |
| Roster picker | `CreateHighlightRosterWidget(parent, get, set, onChange)` | name-list picker |
| Ordered lists | `CreateClassOrderList`, `CreateRoleOrderList`, `CreateGroupOrderList` | drag-to-reorder |
| Tabs | `StyleButton{tab=true}` | one underline-tab style everywhere |
| Designer presets | `CreateDesignerPresetBar` | AD/TD named-preset bars |
| Growth direction | `CreateGrowthControl` | |
| Border / expiry | `CreateBorderControls` + `CreateExpirationControls` (+ `CreateExpiringSubheader`, `CreateExpiringThresholdRow`) | each consumer opts into a subset via `opts.include` |
| Text style block | `CreateTextControls` | font / scale / outline / shadow / colour / anchor / justify as one unit |
| Animation | `CreateAnimationControls` | border animation type + tuning |
| Override affordances | `CreateOverrideMarker`, `CreateOverrideResetButton`, `CreateDisabledOverlay` | register the widget with `GUI.RegisterOverrideWidget(widget)` or its indicator never refreshes |
| Theme | `GUI.GetThemeColor()`, `GUI.Colors`, `GUI.DialogColors`, `root.ThemeListeners` | |

### Behaviour — the layer that gets hand-rolled by accident

A bespoke widget still has to participate in these. Skipping one doesn't error; it just makes that
one surface behave unlike the rest of the addon.

| Need | Helper | ☠ What breaks if you skip it |
|------|--------|------------------------------|
| A dropdown-style popup menu | `GUI:RegisterMenu(frame)`, `GUI:CloseAllMenus()` | **Register every menu frame at creation.** A menu that isn't registered stays open through a page change, mode switch or window close, and floats over whatever comes next |
| A widget that changes height | `GUI:RelayoutHost(widget, slotHeight)` | Updates the group's stored slot, re-lays the group, **then bubbles to the page** so sibling groups re-anchor. Without the bubble a grown group's backdrop overshoots the next group's anchor and paints an empty rectangle above it |
| A border on a bespoke frame | `GUI:ApplyPixelBorder(frame, {r,g,b,a}, weight)`, `GUI:HidePixelBorder(frame)`, `GUI:RefreshPixelBorders()` | Our two-device-pixel border. A `SetBackdrop` edge instead gives you the thinning / vanishing hairline the whole system exists to avoid — see "The pixel grid" |
| Whole-pixel geometry | `GUI.SnapLen`, `GUI.SnapLenUp` | Right/top edges land mid-pixel and clip whatever they contain |
| Jump to a related setting | `GUI:LinkToSetting(target)`, `GUI:FlashWidget(widget, opts)` | `LinkToSetting` takes `scrollTo` for custom containers (e.g. an AD card) and `flash` to pick or suppress the pulse; `FlashWidget` works on a raw FontString too, so section headers can flash |
| Colour a word inline | `GUI:ToneHex(toneName)`, `GUI:GetToneColor(toneName)` | Hardcoded hex drifts from the palette and doesn't theme |
| Tab availability | `GUI:UpdateTabAvailability()`, `GUI:IsTabDisabledForCurrentMode(tabName)` | Call after anything that changes which tabs apply to the current mode |
| Colour-picker interop | `GUI:InstallColorPickerHook()` / `Uninstall…` / `IsColorPickerHookInstalled()` / `MarkColorPickerCall()` | Keeps Blizzard's picker from stomping our own; mark your call or the hook can't tell whose it is |
| Section collapse state | `GUI:GetCollapsedGroups()` | Persisted collapse state — read it, don't track your own |

### The menu registry — all three pieces are resident

The registry table, its writer and its reader live together in
`DandersFrames/GUI/Widgets.lua`, and they should stay that way:

| Piece | Where |
|---|---|
| `GUI._menus` (the registry table) | resident |
| `GUI:RegisterMenu(frame)` | resident |
| `GUI:CloseAllMenus()` | resident |

`CloseAllMenus` briefly lived in the companion during the load-on-demand split.
That left resident code able to *register* a menu but not close one — and
resident `GUI:CreateDropdown` does register, with a resident caller (the mover
panel's anchor dropdown). Nothing broke, because both `CloseAllMenus` callers
happened to be companion-side, but the failure mode was the bad kind: a bulk
"dismiss whatever is open" call that is nil half the time fails **silently**,
leaving a menu floating — the exact symptom the registry exists to prevent.

☠ Four lines are not worth an addon boundary. If you ever find yourself
nil-guarding a call like this, move the function instead — a guard documents
the split rather than removing it.

Not the same thing as `CloseOpenDropdown` (resident, published on `GUI._priv`),
which closes the *single currently-open* dropdown. That is what most call sites
actually want.

## Popups — never Blizzard's

There are **zero** `StaticPopupDialogs` / `StaticPopup_Show` calls left in the addon. Use the DF
popup system in `Popup.lua`:

| Call | For |
|---|---|
| `DF:ShowPopupAlert(config)` | a message or a confirm |
| `DF:ShowPopupInput(config)` | a message plus one text field |
| `DF:ShowPopupWizard(config)` | a multi-step flow |
| `GUI:PromptName(opts)` | the common "name this thing" case — prefer this over calling `ShowPopupInput` yourself |

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
