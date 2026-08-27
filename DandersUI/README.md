# DandersUI

The shared settings-UI toolkit behind DandersFrames and DandersMover: one palette,
one set of widget factories, one popup dialog, one popout shell, one pixel-border
implementation.

It is a LibStub **library, not an addon** — it is embedded in each addon that uses
it rather than installed on its own.

## Embedding

1. Copy this folder into your addon as `YourAddon/Libs/DandersUI/`.
2. Load it from your TOC, after LibStub:

```
Libs\LibStub\LibStub.lua
Libs\DandersUI\DandersUI.xml
```

3. Take a host off it (see below) and build your panel from that.

Standard LibStub rules apply: every addon may ship its own copy, and the one with
the highest MINOR wins for the whole session — so keep your copy up to date and
bump MINOR in `Core.lua` whenever you change the library.

Media paths resolve inside the **embedding** addon
(`Interface\AddOns\<YourAddon>\Libs\DandersUI\Media\`), so the `Media` folder has
to travel with the copy.

## Split loading

The pack ships **two** manifests. `DandersUI.xml` is the base half — everything a
running addon needs. `DandersUI_Options.xml` is the settings-panel half: surfaces
only a settings window ever builds, so an addon that opens its panel on demand
should not pay for them at login.

```
Libs\LibStub\LibStub.lua
Libs\DandersUI\DandersUI.xml            <- the resident addon
...
Libs\DandersUI\DandersUI_Options.xml    <- the load-on-demand companion addon
```

The two are normally listed by **different addons**: the base half by the resident
one, the options half by its `LoadOnDemand` companion. Each of them needs its own
`Libs\DandersUI` copy (junction locally, real copy in CI via `Tools/sync-libs.sh`),
because a TOC can only reference files inside its own addon folder. Listing both
manifests in one addon also works and is the simpler case.

`OptionsCore.lua` heads the options manifest and installs the `NS.__DandersUI`
handshake for the files after it. Because it may load in an addon that never
loaded `Core.lua`, it resolves the library through **LibStub** rather than the
handshake, and falls back to `NS.__DandersUI` only for the same-addon case. If the
base half is missing, or is a different revision, it prints one plain error and
returns **without** setting the handshake — so every later file's
`local UI = NS.__DandersUI; if not UI then return end` guard makes it inert
instead of throwing per file. `UI.MEDIA` is left alone: it points inside whichever
addon carries the base copy.

☠ **`EXPECTED_MINOR` in `OptionsCore.lua` must track `MINOR` in `Core.lua`.** Any
commit that bumps `MINOR` bumps `EXPECTED_MINOR` in the same commit. They are
compared for **equality**, not "at least" — an options half paired with any other
revision refuses to load, which is the point: LibStub hands the whole session to
the highest-MINOR base copy, and a mismatched options half would build on
surfaces that copy may not have.

## Getting a host

Every consumer takes its own HOST rather than using the library directly, because
locale, accent, fonts and settings behaviour differ per addon:

```lua
local UI = LibStub("DandersUI-1.0"):NewHost("MyAddon", {
    L = MyAddon.L,          -- REQUIRED; everything else is optional
})
```

`NewHost` returns a table whose metatable `__index` is the shared factory table, so
`UI:CreateSlider(...)` runs one shared function body with `self` bound to your host.
Calling it twice with the same name returns the existing host. A host without `L`
errors immediately.

The library has no SavedVariables and depends on nothing but LibStub.

## Hooks

| Hook | Signature | Default when absent |
|---|---|---|
| `L` | locale table | **required** |
| `print` | `(msg)` | `print` |
| `error` | `(msg)` | `geterrorhandler()` |
| `getFontSetting` | `() -> fontName, outlineFlags` | client font, no outline |
| `resolveFontPath` | `(name) -> path` | the name itself |
| `safeSetFont` | `(obj, name, size, flags) -> handled` | plain `SetFont` |
| `fontFamily` | `(path, outline, size) -> fontObject or global name` | none (no alphabet fallback) |
| `getScale` | `() -> number` | `1` |
| `accentFor` | `(isRaid) -> {r,g,b}` | the host accent |
| `getOverrideState` | `(db, key) -> state, globalValue` | no override indicators |
| `resetOverride` | `(db, key) -> globalValue` | reset buttons do nothing |
| `interceptWrite` | `(db, key, value) -> handled` | writes always land |
| `onSettingWritten` | `(db, key, value)` | no-op |
| `refresh` / `refreshNow` | `()` | no-op |
| `onDragStart` / `onDragStop` / `isDragging` | `(lightFn, name, previewMode)` / `()` / `() -> bool` | no drag bracketing — sliders commit per change instead of the preview/commit split below |
| `registerSearch` | `(kind, label, key, widget, meta)` | no search index |
| `onIndicatorsRefreshed` | `()` | no-op |
| `onPopupOpen` | `()` | no-op |
| `pickerStore` | `() -> store` with `saved` / `recent` / `square` | colour picker remembers nothing past a reload |
| `pickerTitle` | string, or `() -> string` | the colour picker carries no title text |
| `debug` | `(cat) -> printer or nil` | silent |
| `onSectionToggled` | `(key, expanded)` | no-op |
| `scrollToSection` | `(page, section) -> widget` | link-to-setting controls don't render |
| `getSettingsDB` | `() -> table or nil` | settings-group `hideOn` / `disableOn` / `refreshContent` predicates never fire |

`state` is `"none"`, `"runtime"` (overridden by something the user cannot reset here),
`"overridden"` (differs from the global, resettable) or `"editing"` (matches the global).

## Factories

All take `(parent, opts)` and return the widget frame.

| Factory | Key opts |
|---|---|
| `CreateSlider` | `label, min, max, step, get, set, onChanged, lightweight, accent, dbRef` (`previewMode` accepted, deprecated, ignored) |
| `CreateDropdown` | `label, options, get, set, onChanged, dbRef, accent, inline, optionsFunc, searchable, menuAlign, maxVisible, onRuntimeWrite` |
| `CreateAnchorGrid` | `label, getH, setH, getV, setV, onChanged, dbRef = { db, keyH, keyV }, transposedFn, verticalInertFn, wrapMirroredFn` |
| `CreateCheckbox` | `label, get, set, onChanged, tooltip, accent, size` |
| `CreateEditBox` | `width, height, get, set, onCommit, numeric, tooltip, maxLetters, placeholder` |
| `CreateButton` | `text, width, height, onClick, style = "primary"/"ghost"/"tab"/"tinted", tone, icon, accent, tooltip, align, fitText, themeRoot` |
| `CreateLabel` | `text, size, color, font, width, justify` |
| `CreateTextArea` | `width, height, text, readOnly, autoFocus, onTextChanged, onEscape, plain, insets, maxLetters, bgColor, borderColor, fontObject, fontSize, fontFlags` |
| `CreateCloseButton` | `size, tone, tooltip, tooltipDesc, onClick` |
| `CreateGlyphButton` | `size, width, height, texture, iconSize, color, hoverColor, rotation, tooltip, onClick` |
| `CreateElementBackdrop` | `bgColor, borderColor, fill, outline, edgeSize, inset` |
| `CreateGroupBox` | `title, width, padding` — a titled settings-group box; returns a frame with `.title`, `.content` (the padded inner frame to anchor rows into) and `:SetContentHeight(h)`, which sizes the box around its content. Look only: it does no row layout |
| `CreatePanelBackdrop` | `bgColor, bgAlpha, border, borderColor` |
| `CreateMoverBackdrop` | `color, fill, fillAlpha, borderAlpha, edgeSize, isRaid` |
| `PromptName` | `title, message, default, acceptLabel, maxLetters, onAccept` — takes `(opts)` only, no parent |

`dbRef = { db, key }` is optional settings metadata handed to the settings hooks. A
widget without it never calls them, so a consumer with no settings hooks gets a plain
widget and none of the override machinery.

`CreateSlider` and `CreateDropdown` have **no `tooltip` opt** — they attach the house
tooltip to their label, and read the spec off the returned widget. Set
`widget.tooltip = "text"` (or a `{ title, lines }` table) after creating it.

## Preview vs commit (sliders and the colour picker)

A drag is a stream of values the user is still choosing between, ending in ONE
value they chose. `CreateSlider` gives those different events different slots
(the same split Cell draws between `onValueChangedFn` and `afterValueChangedFn`):

- **`lightweight` is the PREVIEW.** It runs only while the bar is held, at most
  once per rendered frame (pumped from an OnUpdate, not from OnValueChanged),
  and only when the snapped value actually moved. Make it cheap.
- **`onChanged` is the COMMIT.** It runs exactly once — on release after a drag,
  and on a typed value in the box. Never per drag tick.
- The bound value (`set` / `dbRef`) is still written on every tick; only the
  work moves.
- A slider with **no `lightweight` previews nothing** during a drag except its
  own readout. It does not fall back to `onChanged` or the `refresh` hook.
- `previewMode` is deprecated: accepted, passed through to `onDragStart` for
  signature compatibility, consumed by nothing. Deleted next minor.

The split needs a host that publishes `onDragStart`/`onDragStop`; without them a
slider keeps the older per-change behaviour (refresh + `onChanged` on every value
change). The hooks are refcount-friendly: every start is matched by exactly one
stop, including stolen mouseups (release outside the bar) and a slider hidden
mid-drag. The colour picker's five drag surfaces (square, hue, alpha, circle
value, wheel) announce themselves through the same two hooks, with the live
`onChange` callback bounded to one call per changed colour while a bar is held;
its commit stays on OK/Apply.

## Other API

| Call | Purpose |
|---|---|
| `UI:StyleButton(btn, opts)`, `UI:StyleCheckButton(cb, opts)`, `UI:StyleEditBox(eb, opts)` | Apply the house look to a frame you built yourself |
| `UI:ShowTooltip(owner, { title, lines, tone, anchor })`, `UI:HideTooltip()`, `UI:AttachTooltip(widget, label, labelRegion)` | The house tooltip. Never use raw `GameTooltip` for your own tooltips |
| `UI:ShowPopupAlert(config)`, `UI:ShowPopupInput(config)`, `UI:IsPopupShown()` | One shared modal dialog. A second call while one is open takes the frame over |
| `UI:CreateSettingsGroup(parent, width, opts)`, `UI:CreateInfoBanner(parent, opts)`, `UI:CreateLink(parent, opts)`, `UI:FlashWidget(widget)`, `UI:LinkToSetting(widget, target)`, `UI:ShowGameTooltip(owner, opts)`, `UI:GroupInnerWidth(group)`, `UI:GetToneColor(tone)`, `UI:ToneHex(tone)`, `UI:CreateDisabledOverlay(frame)` | The page-composition layer (options manifest): collapsible settings groups (`group:AddWidget(widget, height)`), the toned info banner, inline links, link-to-setting jumps and the game-data tooltip. Collapse state persists through the host's `GetCollapsedGroups` method when it has one; section toggles fire `onSectionToggled`; link-to-setting notes render only when `scrollToSection` exists |
| `UI:OpenColorPicker(initialColor, hasAlpha, onAccept, onCancel, onChange, defaultColor)`, `UI:GetColorPickerFrame()` | The shared colour picker (options manifest). One frame for the whole pack, like the popup: a second open takes it over. Colours are `{r,g,b,a}` in 0-1. Palettes and the square/wheel preference persist through `pickerStore`, the title comes from `pickerTitle`, and `GetColorPickerFrame` is a handle for a consumer that has to react to the picker opening or closing |
| `UI:SetAccent(r, g, b)`, `UI:GetAccent()`, `UI:RegisterAccentListener(fn)` | Per-host accent. The default is the party purple-blue |
| `UI:ApplySettingsFont()`, `UI:SetSettingsFont(fs, size, outline)`, `UI:RefreshSettingsFont()` | Drive the `DFFont*` objects from your font hooks |
| `UI:RefreshAllOverrideIndicators()` | A method, not a bare function. The widget registry it sweeps is pack-wide, not per host; `onIndicatorsRefreshed` fires on whichever host you call it on |
| `UI:RegisterMenu(frame)`, `UI:CloseAllMenus()` | The open-menu registry. Call `CloseAllMenus` on any context switch |
| `UI:ApplyPixelBorder(frame, color, weight)`, `UI:HidePixelBorder(frame)`, `UI.StyleScrollBar(scrollFrame[, opts])` | Chrome. `opts.overlay` gives the hairline-until-it-matters bar: it rests at `UI.Scroll.overlayIdle` and low alpha, widens to `UI.Scroll.bar` at full alpha while hovered or scrolling, and shrinks back after `UI.Scroll.overlayHold`. The gutter a consumer reserves is unchanged either way |
| `UI:CreateSelectionMarker(parent, opts)` | One accent bar for a whole group of tabs or rows, which GLIDES between them. `opts.axis` `"x"` (an underline along the member's bottom edge) or `"y"` (a rail down its left). `marker:SetTo(target, color, instant)` / `:Clear()` / `:ClearIf(target)` / `:GetOwner()`. Pair with `StyleButton{ tab = true, tabStripe = false }` so members draw no stripe of their own |
| `UI.Colors`, `UI.DialogColors`, `UI.RowGap`, `UI.RowHeight`, `UI.Space`, `UI.MEDIA` | Palette and metrics. Never hardcode a colour. `UI.Colors` carries the neutrals (`background`, `panel`, `element`, `border`, `hover`, `text`, `textDim`), the two accent poles (`accent`, `raid`), the note tones (`warning`, `notice`) and the mover-overlay roles `anchorRoot` (green: a mover that other movers are anchored to) and `anchored` (purple: a mover anchored to another mover), plus `danger` (red: a blocked or occupied surface) |
| `UI.SnapLen(frame, v)`, `UI.SnapLenUp(frame, v)`, `UI.SnapHeightEven(frame, v)`, `UI:CursorPos(frame)` | Pixel-grid maths |

Scroll frames must use `ScrollFrameTemplate` (not `UIPanelScrollFrameTemplate`) for
`StyleScrollBar` to find their parts.

## Popouts

`UI:CreatePopout(opts)` is a small panel that **docks beside a region**: it picks
the side that fits, follows the region while it moves, and can be pinned loose.
The shell owns the frame, the title bar, the docking, the pin and the chrome; you
mount the content in `build` and decide in `onClose` what closing means.

**Connected, then detached.** While the popout *follows*, it and its region are
drawn as one object: a 1px accent border on the popout, the same border laid over
the source, a ~10px accent diamond — the **connection point** — on the edge the
popout docked against, and a short **beam** across the dock gap joining the two.
The colour is the host accent unless `opts.accent` overrides it. **Pin** it and
every one of those goes: pinning says "this is its own window now", and it looks
like it.

**Retargeting glides.** Handing `Follow` a different region while the popout is
already up and following slides it across (~0.18s, ease-out) rather than
teleporting, so it reads as the same panel now about something else. The re-dock
is suspended for the ride and the landing is exact. `PlaceFree` and a pinned
popout are unaffected.

Per host and `key` there is **one unpinned popout**, pooled: asking for a key that
already has one hands the same object back, re-targeted, without re-running
`build`. Pinning promotes an instance out of the pool and the next request for
that key builds a fresh one — so `build` has to be re-runnable, and per-instance
state belongs on the popout object, never in a file-scope local.

A popout is built **hidden**: placing it is what presents it, because the entrance
pops out of the edge it docked against and that edge is not known until it has
something to dock to.

| Opt | Purpose |
|---|---|
| `key` | **required** identity string; the pool is per host + key |
| `family` | exclusivity group — opening one closes every other popout in its family, pinned ones included. A nil family coexists with everything |
| `pinnable` | default true. `false`: no pin button, `AutoPin` no-ops, and the popout dies with its source |
| `title` / `icon` | title bar; changeable later with `:SetHeader` |
| `parent` | frame to parent to (default `UIParent`). The beam and the source outline are parented alongside it, so a consumer that hides its own overlay hides them too |
| `width` | CONTENT width; the height follows what `build` mounted |
| `build(popout, content)` | called ONCE per instance to mount the content |
| `onClose(popout, reason)` | `reason`: `"cross"`, `"family"`, `"source"`, `"api"` |
| `onPin(popout)` | fired by a hand pin and an auto-pin alike |
| `canAutoPin` | boolean or `function(popout)`, evaluated per call; false makes `AutoPin` a no-op |
| `tetherSource` | region or `function(popout) -> region` — the far end of the beam and the source outline, for when the thing the popout is *about* is not the thing it docked to |
| `accent` | `{r,g,b[,a]}` overriding the host accent for this popout's border, connection point, beam and source outline. Re-read on every open, so a pooled popout tracks a theme change |
| `headerControls(popout, bar)` | returns `leftFrame, rightFrame` (either may be nil) — the consumer's own controls IN the title bar. Called ONCE per instance, like `build`, and for the same reason: a pooled popout re-targeted at something else re-BINDS them (the consumer's job) rather than rebuilding them. The shell anchors `left` where the title starts, `right` inboard of the pin/close cluster, and squeezes the title between them |

`onUnpin`, `actions` and `badge` are accepted and reserved: v1 never unpins and
draws neither.

| Call | Purpose |
|---|---|
| `po:Follow(region, opts)` | Dock beside `region` and track it. `opts.side` forces `"left"` / `"right"` / `"above"` / `"below"`; without it the side is whichever fits on screen. Handed a NEW region while already up and following, it glides across. On a pinned popout it only re-points the tether |
| `po:Follow(row, { outsideOf = window, clipTo = viewport })` | The **settings placement**: `row` lives inside `window` (typically in a scroll child), and the popout docks outside the WINDOW's vertical edge at the ROW's height rather than beside the row — so it never covers the list the row was picked from. Only `"left"` / `"right"` are meaningful for `opts.side`; it flips to the window's left edge when the right lacks screen room. The tether chrome stays on the ROW and hides (popout still up and docked) while the row is scrolled out of view. **`clipTo` is what decides that**, and it should be the scroll frame, not the window: a window's own title bar and padding sit inside the window and outside the viewport, so gating on the window leaves the beam and outline drawn over that chrome for the 50-odd pixels between the row leaving the list and its rect leaving the window. Omitted, it falls back to `outsideOf`. A plain `Follow` clears both |
| `po:PlaceFree(x, y)` | Absolute placement, for consumers that own their own layout: no source, so nothing to follow and nothing to tether to. Stops a glide |
| `po:Pin([silent])`, `po:AutoPin()`, `po:IsPinned()` | Take it off its leash: it stops following, drops the connection point, beam and source outline, becomes draggable by its title bar, and from there the only way out is the cross. `AutoPin` is the same thing gated on `canAutoPin` and without the confirm pop |
| `po:SetHeader(title, icon)`, `po:GetTitle()` | Title bar contents |
| `po:Resize()` | Re-fit the height after changing the content's height |
| `po:GetAccent()` | The colour this popout's chrome is drawn in: `opts.accent`, else the host accent |
| `po:SetAccent(c)` | Live re-tint of a popout that is already up: border, connection point, beam and source outline all repaint, **and the colour cascades into the widgets the consumer mounted** (see below). `nil` hands it back to the host accent. `adopt` paints at open time; this is the only way to repaint one mid-flight (a party/raid mode switch under an open panel) |
| `po:HideChrome()` | Take the beam and the source outline down at once, animations cancelled — for a consumer hiding the popout by hand (a combat suspend, a drag). Neither is a child of `po.frame`, so nothing else would |
| `po:Close([reason])`, `po:IsShown()` | Close hands `reason` to `onClose`. A pinned instance is discarded; an unpinned one goes back to the pool |
| `UI.PopoutPickSide(src, w, h, gap, screenW, screenH)`, `UI.PopoutDockPos(src, side, w, h, gap)`, `UI.PopoutOutsidePos(win, row, w, h, gap, screenW, screenH, forcedSide)`, `UI.PopoutNotchTip(rect, side, size)`, `UI.PopoutNearestOnRect(rect, x, y)`, `UI.PopoutIsAdjacent(a, b, gap)` | The docking and beam geometry as pure functions (on the library, not a host). Rects are centre-based, in UIParent-centre units. `PopoutOutsidePos` is the settings placement's whole geometry — it answers `side, x, y` for a popout standing outside `win`, **centred on** `row`, then clamped into the window's vertical span (skipped when the popout is taller than the window, since no position there satisfies it) and finally onto the screen; the dock, the retarget glide and the tests all read that one answer. Centred, not hung from the row's top: a tall popout hung by its top drops its whole body below the row it belongs to and ends up level with a part of the list it has nothing to do with. `PopoutIsAdjacent` is published for consumers; the shell itself no longer consults it |

`po.frame` is the shell, `po.content` the frame `build` was handed.

**The box model.** `po.frame`'s height is
`UI.PopoutTitleHeight + UI.PopoutPad + <content height> + UI.PopoutPad`, and its
width is `opts.width + 2 × UI.PopoutPad` — both numbers live in `Theme.lua` so a
consumer laying out a fixed-height panel can work out what the chrome costs it
without reading `Popout.lua`. The title bar is `UI.PopoutTitleHeight` tall and
holds the icon, the caption, whatever `headerControls` returned, the pin and the
cross; the content hangs one `PAD` below it, with the same `PAD` under and either
side of it.

**The ink rect.** A region's frame and the part of it that is actually painted
are not always the same rect — a settings row's frame is its whole layout slot,
gap to the next row included. Any region the shell tethers to may declare
`region.popoutInset = { left, right, top, bottom }` (pixels trimmed off each
edge), and every rect the shell takes of it honours that: the source outline is
drawn round the ink, the beam aims at the ink, the clip gate tests the ink, and
the settings placement measures the ink. Undeclared means "the whole frame". The
inset is stated in the **region's own** units — the design pixels it lays itself
out in — so a scaled surface declares the same numbers an unscaled one does.

**Scale.** A popout can dock outside a window that carries its own `SetScale`
(DandersFrames' settings window has a user scale slider), and a frame's
`GetCenter`/`GetWidth` answer in that frame's **own** coordinate space, not
UIParent's. The shell converts on both legs — every rect it reads is multiplied
into UIParent units, and every offset it writes back (a screen anchor, a beam
endpoint, the connection point's slide) is divided into the units of the frame
receiving it. Consumers do not have to do anything; the thing to know is that a
number you read out of `po` (a rect, a dock position) is in UIParent units and
is **not** interchangeable with a `SetPoint` offset on a scaled frame. Left
unconverted the error is `distance-from-screen-centre × (1/scale − 1)`, which at
a window edge is over a hundred pixels — the beam stopping dead in the gutter
beside its row rather than touching the plate.

**The accent cascade.** A popout's accent is not just its chrome. Whenever the
accent is applied — at open, and on every `SetAccent` — the popout walks its own
frame tree (from `po.frame`, so the title bar and any `headerControls` are
included), collects the `ThemeListeners` lists it finds and calls
`ApplyThemeColor(c)` on each entry with the popout's colour. Without it a popout
whose accent changed under an open panel ended up a purple-bordered box full of
orange sliders.

`ApplyThemeColor(c)` is the kit's "tint to THIS colour" entry point and is the
only one the cascade drives. **`UpdateTheme()` takes no arguments and must not
start** — several call sites reach it through colon syntax (`slider:UpdateTheme()`),
which would fill a colour parameter with the widget table itself. It means
"repaint to the host accent"; a widget that wants to be scope-tintable publishes
`ApplyThemeColor` as well (sliders, buttons, check boxes and collapse arrows all
do).

Two things it does not reach, by design or by limit: a widget built with an
explicit `opts.accent` registers no listener at all (that colour is the call
site's choice, not an inherited one), and any repaint that reads
`host:GetAccent()` at *click* time rather than at theme time — a dropdown menu
building its rows, an anchor grid cell re-activating — comes up in the host
colour until it is next rebuilt.

### Popout rows (options manifest)

`UI:CreatePopoutRow(parent, opts)` — a settings row that hands its controls to a
popout: toggle, name, live summary, count badge, chevron, and the whole row opens
a popout docked outside the settings window (`Follow(row, { outsideOf = window })`)
carrying the group's real controls. Lives in `DandersUI_Options.xml` (PopoutRow.lua),
so resident addons never pay for it.

**One panel across every row of a host.** All rows share one popout key
(`opts.popoutKey` overrides), so clicking another row glides the SAME panel across.
Each row's content is a pane built once per (instance, row) by `opts.build(popout,
pane)` — the build must SIZE its pane — and swapped in on retarget. A pane taller
than 60% of the screen gets the kit scroll region. Pinning promotes the instance out
with the pinned row's content; the next row click gets a fresh instance, and pinned
panels coexist. The popout's content width is `UI.PopoutContentWidth` (260 — the
settings-group inner width every factory is already built for, so widgets mount
unchanged).

**The row is a plate, and it says which one is open.** Every metric it draws with
lives in `UI.PopoutRow` (Theme.lua) — a 44px plate in a 50px slot, the inner
padding, the column gaps, the glyph sizes, the two type sizes and the state
alphas — so the look is retuned there rather than inside the widget. At rest the
plate is the kit's element fill inside the kit's element border, the same pair a
dropdown wears; hovering brightens it. When the panel that is up is about THIS
row, the plate wears the row's accent as its border plus a wash inside it, and
the label takes the accent too — so a column of rows always shows which one the
floating panel belongs to, including after a retarget glide, and including a row
whose panel was pinned loose. Active is answered by walking the row's bound
instances, not kept as a flag, so a pinned panel and the shared one can each
light their own row. Toggled OFF outranks active on the label: a feature that is
switched off has nothing to be the subject of. The count sits in a small pill of
its own — darker fill, its own 1px border, fixed size — and a row with no
declared count draws no pill while keeping the column.

**Toggled off gates the pane.** When the row's toggle is off, every widget the
build mounted into that row's pane greys and stops taking input — `SetEnabled(false)`
where the widget has one, a dim to the same 0.4 where it does not — so a switched-off
feature never shows a panel of live controls that do nothing. The popout's own header
toggle, pin and cross stay enabled: that tick is the way back on. The gate BORROWS the
enabled state rather than owning it — it records what each widget's own logic last
asked for and replays exactly that on the way back out, so a control a page's
`disableOn` had already disabled is not resurrected by switching the feature on. Gating
that changes *while* the gate is shut has no `SetEnabled` call to record, so opening the
gate hands the pane back to whoever wired it (a settings group's `RefreshChildStates`,
else each widget's `refreshContent`) to re-assert itself; that is a no-op on a pane with
no wiring of its own. This is not `opts.enabled` — the dependent grey is a separate
mechanism about a feature you cannot act on yet, and a dependent-greyed row whose own
toggle is on keeps its popout's controls live. A consumer wrapping several widgets in one
frame should give that wrapper a `SetEnabled` (as the kit's own containers do); the gate
walks the pane's direct children and cannot reach past a wrapper that answers nothing.

| Opt | Purpose |
|---|---|
| `label` | **required** row name (the consumer localises) |
| `db` | table or `function -> table`, re-resolved on every refresh, handed to `summary` / `enabled` |
| `toggle` | `{ db = t\|fn, key = "k" }` (db defaults to `opts.db`) or `{ get, set }` |
| `summary` | `fn(db) -> string`, rendered live in the row. Authoring rule: max 4 items, fixed order, `·` separated, labels/units only where a bare value is ambiguous |
| `offText` | the word shown instead of the summary while toggled off (default: host `L["Off"]`) |
| `count` | declared control count — the badge, and what the build-time count check compares against (mounted child FRAMES; mismatch reaches the host `debug("popoutrow")` hook) |
| `build(popout, pane)` | mounts the group's widgets, once per (instance, row); must size the pane |
| `accent` | per-row accent override; `enabled` — bool or `fn(db)`, false greys the whole row (popout still opens) |
| `onToggle(v)` | after a toggle write from the row OR the popout header (one write path, both stay in sync) |
| `window` | **required** to open: the frame the popout docks outside of |
| `clipTo` | the region that actually clips this row — the scroll frame the list lives in. The popout's connected chrome hides while the row is scrolled out of it. Omitted, the shell falls back to `window`, which is too generous by that window's own title bar and padding |
| `title` | popout header title (default: `label`) |

Returns the row frame with `.Refresh()` / `.refreshContent(db)` (the settings-group
refresh path), `:SetEnabled(bool)` (an explicit call overrides `opts.enabled` from
then on), `:SetAccent(c)` (re-tints the row and every panel it has open, pinned
included), `:OpenPopout()`, `:ClosePopout(reason)` and `.popout`. Its parts are
`.plate` (the bordered surface everything else is anchored inside), `.checkButton`,
`.label`, `.summary`, `.badgePill` / `.badge`, `.gear` and `.chevron`. Lay a column
of them out at `UI.PopoutRow.slot` apart — `row.preferredHeight` already carries it.

The close matrix is the consumer's to wire, through two host verbs:
`host:CloseUnpinnedPopoutRows(reason)` (page switch — pinned panels survive) and
`host:CloseAllPopoutRows(reason)` (window close — takes everything).

## Fx

`UI.Fx` (reachable from any host via `__index`) is a small set of fade helpers for
chrome that animates in and out. Nothing in it is load-bearing: every entry point
shows/hides the target immediately and only decorates that with an animation, so a
target without `CreateAnimationGroup` (headless tests) still lands in the right
state, and a target hidden mid-animation ends up hidden. Works on frames and
regions alike; per-target animation groups are cached on the target itself.

| Call | Purpose |
|---|---|
| `Fx.FadeIn(target, dur, ox, oy)` | Show + fade in, optionally sliding onto its anchor from `(ox, oy)` |
| `Fx.PopIn(target, dur, ox, oy, fromScale, origin)` | Fade + slide + scale up from `fromScale` (default 0.92) with the scale originating at `origin`; ease-out |
| `Fx.PopOut(target, dur, ox, oy, toScale, origin, onDone)` | The mirror of `PopIn`: fade + slide + scale down to `toScale` about `origin`, then `onDone`. Pass `PopIn`'s own offsets and origin and the exit retraces the entrance. A cancelled pop-out skips `onDone` |
| `Fx.FadeOut(target, dur, onDone)` | Fade out, then call `onDone` (which usually hides). A cancelled fade skips `onDone` |
| `Fx.FadeTo(target, alpha, dur)` | Fade to a resting alpha and stay there (restore with `FadeTo(target, 1)`) |
| `Fx.ScaleTo(target, scale, dur)` | Scale to a resting scale and stay there. Frames only — a region has no `SetScale`. ⚠ A scaled frame moves whatever is anchored TO it; anchor neighbours to the row, not to the thing that lifts |
| `Fx.MoveTo(target, place, dur)` | Re-anchor and glide in from where it was. `place(target)` does the `ClearAllPoints`/`SetPoint` and is called immediately, so the anchors are correct before anything animates. Frames only. A target with unresolved anchors, or one that did not move, simply lands |
| `Fx.Cancel(target)` | Stop any running fade and restore alpha 1 — for paths that must be instant. The resting scale and position are the caller's and are left alone |

## Conventions

- Colours come from `UI.Colors` / the host accent. No literals.
- Row heights come from `UI.RowHeight`; a fixed-height factory stamps its own slot.
- Every user-facing string goes through your `L` table.
- A widget that can be gated needs a `SetEnabled(bool)` that dims its DISTINCTIVE
  element, not just its label — otherwise a grey-out sweep silently skips it.
