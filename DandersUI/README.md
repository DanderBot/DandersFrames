# DandersUI

The shared settings-UI toolkit behind DandersFrames and DandersMover: one palette,
one set of widget factories, one popup dialog, one pixel-border implementation.

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
| `onDragStart` / `onDragStop` / `isDragging` | `(lightFn, name, previewMode)` / `()` / `() -> bool` | no drag bracketing |
| `registerSearch` | `(kind, label, key, widget, meta)` | no search index |
| `onIndicatorsRefreshed` | `()` | no-op |
| `onPopupOpen` | `()` | no-op |

`state` is `"none"`, `"runtime"` (overridden by something the user cannot reset here),
`"overridden"` (differs from the global, resettable) or `"editing"` (matches the global).

## Factories

All take `(parent, opts)` and return the widget frame.

| Factory | Key opts |
|---|---|
| `CreateSlider` | `label, min, max, step, get, set, onChanged, lightweight, previewMode, accent, dbRef` |
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
| `CreatePanelBackdrop` | `bgColor, bgAlpha, border, borderColor` |
| `CreateMoverBackdrop` | `color, fill, fillAlpha, borderAlpha, edgeSize, isRaid` |
| `PromptName` | `title, message, default, acceptLabel, maxLetters, onAccept` — takes `(opts)` only, no parent |

`dbRef = { db, key }` is optional settings metadata handed to the settings hooks. A
widget without it never calls them, so a consumer with no settings hooks gets a plain
widget and none of the override machinery.

`CreateSlider` and `CreateDropdown` have **no `tooltip` opt** — they attach the house
tooltip to their label, and read the spec off the returned widget. Set
`widget.tooltip = "text"` (or a `{ title, lines }` table) after creating it.

## Other API

| Call | Purpose |
|---|---|
| `UI:StyleButton(btn, opts)`, `UI:StyleCheckButton(cb, opts)`, `UI:StyleEditBox(eb, opts)` | Apply the house look to a frame you built yourself |
| `UI:ShowTooltip(owner, { title, lines, tone, anchor })`, `UI:HideTooltip()`, `UI:AttachTooltip(widget, label, labelRegion)` | The house tooltip. Never use raw `GameTooltip` for your own tooltips |
| `UI:ShowPopupAlert(config)`, `UI:ShowPopupInput(config)`, `UI:IsPopupShown()` | One shared modal dialog. A second call while one is open takes the frame over |
| `UI:SetAccent(r, g, b)`, `UI:GetAccent()`, `UI:RegisterAccentListener(fn)` | Per-host accent. The default is the party purple-blue |
| `UI:ApplySettingsFont()`, `UI:SetSettingsFont(fs, size, outline)`, `UI:RefreshSettingsFont()` | Drive the `DFFont*` objects from your font hooks |
| `UI:RefreshAllOverrideIndicators()` | A method, not a bare function. The widget registry it sweeps is pack-wide, not per host; `onIndicatorsRefreshed` fires on whichever host you call it on |
| `UI:RegisterMenu(frame)`, `UI:CloseAllMenus()` | The open-menu registry. Call `CloseAllMenus` on any context switch |
| `UI:ApplyPixelBorder(frame, color, weight)`, `UI:HidePixelBorder(frame)`, `UI.StyleScrollBar(scrollFrame)` | Chrome |
| `UI.Colors`, `UI.DialogColors`, `UI.RowGap`, `UI.RowHeight`, `UI.Space`, `UI.MEDIA` | Palette and metrics. Never hardcode a colour |
| `UI.SnapLen(frame, v)`, `UI.SnapLenUp(frame, v)`, `UI.SnapHeightEven(frame, v)`, `UI:CursorPos(frame)` | Pixel-grid maths |

Scroll frames must use `ScrollFrameTemplate` (not `UIPanelScrollFrameTemplate`) for
`StyleScrollBar` to find their parts.

## Conventions

- Colours come from `UI.Colors` / the host accent. No literals.
- Row heights come from `UI.RowHeight`; a fixed-height factory stamps its own slot.
- Every user-facing string goes through your `L` table.
- A widget that can be gated needs a `SetEnabled(bool)` that dims its DISTINCTIVE
  element, not just its label — otherwise a grey-out sweep silently skips it.
