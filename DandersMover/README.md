# DandersMover

Shared mover / anchor system for WoW addons. Register a frame, get dragging,
grid + screen + frame-to-frame snapping, anchor chains across addons, a docked
position panel, undo/redo, save/discard and combat-safe behaviour.

## Consumer quick start

```lua
local Mover = LibStub and LibStub("DandersMover-1.0", true)   -- nil when not installed
if Mover then
    Mover:RegisterAddon("MyAddon", { title = "My Addon" })
    Mover:Register("MyAddon", "bar", {
        title     = "Cooldown Bar",
        frame     = MyAddon.bar,
        getPos    = function() return MyAddon.db.barPosition end,
        onChanged = function(pos, reason) Mover.ApplyPosition(MyAddon.bar, pos) end,
        default   = { point = "CENTER", x = 0, y = -200 },
        secure    = false,      -- true for protected frames: the lib defers onChanged in combat
    })
end

-- Always apply your own position on load, with or without the lib:
local pos = MyAddon.db.barPosition
MyAddon.bar:ClearAllPoints()
MyAddon.bar:SetPoint(pos.point or "CENTER", UIParent, "CENTER", pos.x or 0, pos.y or 0)
```

## The position record (you own it)

```lua
{ point = "CENTER", x = 0, y = 0,
  anchor = nil or { target = "OtherAddon:key", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 } }
```
`point/x/y` are always valid absolute coordinates (UIParent units from UIParent
CENTER). When the lib is present it keeps them in sync with `anchor`; when it is
absent you apply them and ignore `anchor`.

### Anchor modes

```lua
-- outside (default when mode is nil): sit beside the target's edge
anchor = { target = "OtherAddon:key", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 }

-- point: SetPoint semantics
anchor = { target = "OtherAddon:key", mode = "point", point = "TOPLEFT", relPoint = "BOTTOMLEFT", offsetX = 0, offsetY = 0 }
```
**Outside** places the whole element next to one of the target's four edges,
aligned to its start / center / end, with a small gap. **Point** puts the
element's `point` directly on the target's `relPoint` plus the offset, exactly
like `child:SetPoint(point, target, relPoint, offsetX, offsetY)`.

### `getRect`

`getRect = function() return { x = cx, y = cy, w = w, h = h } end` reports the
element's *visible* rect (UIParent units from UIParent CENTER) when it differs
from the frame's own geometry — an oversized container, a frame with padding, a
header whose extent is not its children's. Snap zones, proxies and the drag
maths all use it, and dragging applies the movement as a delta to the record, so
the offset between record and visible rect never drifts. Return nil while there
is nothing to measure.

## API

| Call | Purpose |
|---|---|
| `Mover:RegisterAddon(name, { title, icon })` | Group your elements in the UI. `icon` (texture path) is shown on your proxies; omitted → the bundled DandersFrames icon |
| `Mover:Register(addon, key, def)` | Make a frame movable. `def`: `title`, `frame` or `getFrame`, `getPos`, `onChanged(pos, reason)`, optional `default`, `secure`, `getSize` (w, h in UIParent units), `getRect`, `anchorable`, `group` |
| `Mover:RegisterAnchorTarget(addon, key, { title, frame or getFrame })` | Something others can anchor to but that is not itself movable. Also takes `getSize` / `getRect` |
| `Mover:RefreshAnchorTarget(addon, key)` | Call when a `getFrame` target now resolves to a different frame |
| `Mover:Apply(addon, key)` | Re-solve and re-fire `onChanged` (e.g. after you change the frame's scale) |
| `Mover:Unregister(addon, key)`, `Mover:UnregisterAddon(addon)` | Cleanup |
| `Mover:Unlock([addon])`, `Lock()`, `Toggle()`, `IsUnlocked()` | Drive the editor from your own UI |
| `Mover:IsEnabled(addon[, key])` | Respect the user's mover toggles |
| `Mover.ApplyPosition(frame, pos)` | SetPoint + scale maths helper |
| `Mover.RegisterCallback(obj, event, fn)` | Events: `Unlocked`, `Locked`, `Saved`, `Discarded`, `PositionChanged(addon, key, pos, reason)` |

`reason` values: `drag nudge anchor detach reset center undo redo discard reapply parent`.

Slash: `/mover` toggle, `/mover config` settings, `/mover demo` built-in demo.

## Behaviour rules worth knowing

- Dragging an anchored element can only **re-anchor** it: dropped outside every snap zone it springs back. Use the panel's Detach to free it.
- Hidden frames are never snap targets. If your element is normally hidden (combat-only, raid-only), listen for the `Unlocked` / `Locked` callbacks and show it for the session — the lib never touches your frame's visibility.
- A target counts as *available* when it has a `getRect` and that `getRect` returns a rect, or when it has no `getRect` and its frame exists and is shown. A `getRect` that returns `nil` is how you say "not meaningfully on screen right now", and it wins even if the backing frame is technically shown. Unavailable targets are never offered as snap targets, and anything anchored to one holds its last position instead of jumping — it re-solves the next time you call `RefreshAnchorTarget` or `Apply` while the target is available again.
- Drags, nudges and X/Y edits are clamped so the visible rect stays on screen.
