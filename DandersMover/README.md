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
| `Mover:Unlock([filter])`, `Lock()`, `Toggle()`, `IsUnlocked()` | Drive the editor from your own UI. `filter` = nil, `"Addon"`, or `{ addon = "Addon", keys = { "k", ... } }`. Your addon is the initiator: only its listed keys get proxies (forced relevant for the session). Other addons' enabled+relevant elements stay anchor targets (snap zones, resolution) and get proxies only when the user turns on "Show other addons' movers" (Settings › Editor, or the legend) |
| `Mover:IsEnabled(addon[, key])` | Respect the user's mover toggles |
| `Mover.ApplyPosition(frame, pos)` | SetPoint + scale maths helper |
| `Mover.RegisterCallback(obj, event, fn)` | Events: `Unlocked`, `Locked`, `Saved`, `Discarded`, `PositionChanged(addon, key, pos, reason)`, `RegistryChanged(addon, key)` |

`RegistryChanged` fires after every registration or unregistration — element, anchor target or addon. `addon`/`key` name what changed; **both nil** means a wholesale change (the login queue draining through `Registry:Flush`). Consumers churn these in bursts, so debounce (`C_Timer.After(0, ...)`) if you only want to redraw once. The settings list and an open unlock session both listen, so an element that appears or disappears mid-session is reflected straight away.

`reason` values: `drag nudge anchor detach reset center undo redo discard reapply parent`.

Slash: `/mover` toggle, `/mover config` settings, `/mover demo` built-in demo.

## Behaviour rules worth knowing

- Dragging an anchored element shows a **tether** to its target. Within 3× the snap distance of its resolved anchor position the anchor holds: dropped outside every snap zone it springs back (dropping into a zone re-anchors). Pull further and the tether strains (reddens and thins); past 4× the snap distance it **snaps** — the element is free from that moment and the drop commits one "Detach" undo entry. The panel's Detach still frees it without the drag. Selecting or hovering a slab also shows its tether; hovering shows the whole chain (its parent's and all of its children's).
- Hidden frames are never snap targets. If your element is normally hidden (combat-only, raid-only), listen for the `Unlocked` / `Locked` callbacks and show it for the session — the lib never touches your frame's visibility.
- `isRelevant = function() -> bool` on `Register` / `RegisterAnchorTarget`: absent = relevant. Irrelevant elements get no proxy in an unfiltered session and are never snap targets (children anchored to them hold). A key named in an `Unlock` filter is forced relevant. Erroring callbacks count as relevant. `pointLocked = true` on `Register` hides the panel's 9-point picker (the consumer derives `point`).
- A target counts as *available* when it has a `getRect` and that `getRect` returns a rect, or when it has no `getRect` and its frame exists and is shown. A `getRect` that returns `nil` is how you say "not meaningfully on screen right now", and it wins even if the backing frame is technically shown. Unavailable targets are never offered as snap targets, and anything anchored to one holds its last position instead of jumping — it re-solves the next time you call `RefreshAnchorTarget` or `Apply` while the target is available again.
- A drag snaps to the **nearest** free zone whose landing position is within the **Snap distance** setting (Settings › Snapping, default 25, 0–400) of where the element is now — measured centre to centre, i.e. how far it would jump on drop. The distance is independent of the element's size, so a wide raid container and a single icon snap from the same distance. The zone highlight uses the same radius, so a zone that lights up is a zone that will take the drop.
- Drags, nudges and X/Y edits are clamped so the visible rect stays on screen.
- Proxies are dark slabs; the coloured dot and left edge give the role — host accent = free, purple = anchored, green ring = anchor root. Selection is a white outline; a faded slab means the real frame is hidden.
- Hold Shift while dragging to move horizontally only, Ctrl to move vertically only (both held = free drag). A nudge (arrow keys or the panel arrows) steps by 1; Shift makes it 10, Ctrl 100.
- While a session is open the unlock overlay captures the mouse across the whole screen: left-click on empty space deselects, and the world/camera behind it is not interactable. Lock the session to get the screen back: press Esc, use the top strip's Save & Exit / Discard, or type `/mover`.
