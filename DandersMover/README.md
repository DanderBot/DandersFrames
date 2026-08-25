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

### Backup anchor

```lua
anchor = { target = "OtherAddon:key", edge = "bottom", align = "start", offsetX = 0, offsetY = 0,
           fallback = { target = "OtherAddon:spare", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 } }
```
`anchor.fallback` is an optional second anchor block carrying the same eight
fields as the primary (`target`, `mode`, `edge`, `align`, `point`, `relPoint`,
`offsetX`, `offsetY`). **One level only** — a fallback has no fallback of its
own, and the lib never writes one.

Resolution order is **primary → fallback → hold**. The primary drives the
element whenever its target is available (see the availability rule below); the
fallback takes over when it is not; when neither target is available the element
holds its last solved position instead of jumping. The panel names whichever
block is actually live and marks it `(backup)` when that is the fallback, and
the tether draws thin and muted while the fallback is holding.

The fallback lives *inside* the primary block, so the two are cleared together:
**Detach** and pulling the tether past its break point both drop the whole
anchor, fallback included (the drag says so with a toast). Re-anchoring keeps
it — from a snap zone, the panel's picker or a link-drag — unless the new
primary is the fallback's own target, which would make the two the same link.
`Copy to <twin>` carries the fallback onto the twin and drops it there on the
same cycle test the primary gets, so a copy can land the primary and drop the
fallback on its own.

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
| `Mover:Register(addon, key, def)` | Make a frame movable. `def`: `title`, `frame` or `getFrame`, `getPos`, `onChanged(pos, reason)`, optional `default`, `secure`, `getSize` (w, h in UIParent units), `getRect`, `anchorable`, `snappable`, `group`, `openSettings` (function — the panel shows a **Configure** button for the element that calls it; open your own settings UI for the element there), `twin` (`"addon:key"` of the element's counterpart, e.g. the raid container for the party container — the panel shows a **Copy to <twin>** button that copies the whole record onto the twin, re-solves it and pushes one undo entry; the anchor is dropped if carrying it over would create a loop) |
| `Mover:RegisterAnchorTarget(addon, key, { title, frame or getFrame })` | Something others can anchor to but that is not itself movable. Also takes `getSize` / `getRect` / `snappable` |
| `Mover:RefreshAnchorTarget(addon, key)` | Call when a `getFrame` target now resolves to a different frame |
| `Mover:RefreshAnchorTargets(addon, keys)` | The batched form: one union descendant set, one resolution order, one pass, so an element hanging off two of the listed targets is solved once instead of once per target. Use it when several targets move together (a header re-layout that shifts every sub-target) rather than looping `RefreshAnchorTarget` |
| `Mover:RenameKey(addon, old, new)` | Move an element's key in place. The user's enable toggle, the registry entry (with its paired anchor target) and every registered or queued record's anchor target *and* fallback target follow it; `twin` strings are re-pointed too. The element keeps its own table and its position — nothing is re-registered, nothing is re-solved. Returns `false` and changes nothing while a session is unlocked, or when `new` is already taken. Consumers that register later in the same login are caught by a replay at the lib's queue flush, so the order addons load in does not matter |
| `Mover:Apply(addon, key)` | Re-solve and re-fire `onChanged` (e.g. after you change the frame's scale) |
| `Mover:Unregister(addon, key)`, `Mover:UnregisterAddon(addon)` | Cleanup |
| `Mover:Unlock([filter])`, `Lock()`, `Toggle()`, `IsUnlocked()` | Drive the editor from your own UI. `filter` = nil, `"Addon"`, or `{ addon = "Addon", keys = { "k", ... } }`. Your addon is the initiator: only its listed keys get proxies (forced relevant for the session). Other addons' enabled+relevant elements stay anchor targets (snap zones, resolution) and get proxies only when the user turns on "Show other addons' movers" (Settings › Editor, or the legend) |
| `Mover:IsEnabled(addon[, key])` | Respect the user's mover toggles |
| `Mover.ApplyPosition(frame, pos)` | SetPoint + scale maths helper |
| `Mover.RegisterCallback(obj, event, fn)` | Events: `Unlocked`, `Locked`, `Saved`, `Discarded`, `PositionChanged(addon, key, pos, reason)`, `RegistryChanged(addon, key)` |

`RegistryChanged` fires after every registration or unregistration — element, anchor target or addon. `addon`/`key` name what changed; **both nil** means a wholesale change (the login queue draining through `Registry:Flush`). Consumers churn these in bursts, so debounce (`C_Timer.After(0, ...)`) if you only want to redraw once. The settings list and an open unlock session both listen, so an element that appears or disappears mid-session is reflected straight away.

`reason` values: `drag nudge anchor detach fallback reset center copy undo redo discard reapply parent`.

Slash: `/mover` toggle, `/mover config` settings, `/mover demo` built-in demo.

## Anchoring without dragging

Two ways to tie an element to a target without moving it: the lib derives the
anchor spec that reproduces where the element already sits, so the relationship
changes and the position does not.

The panel's **Anchor** section holds all of it: a **Target** row, an **Edge** /
**Align** pair (**Point** / **Rel point** when the anchor is in point mode), and
a **Backup** row. A free element still shows all three — the rows it has no
answer for grey out rather than vanishing.

- **The panel's target picker.** The selected element gets a searchable dropdown
  of every target it may legally anchor to, bucketed under the addon (and the
  `group`) that owns it; illegal picks — itself, its own descendants, anything
  that would close a loop, and elements the user has toggled off — are not
  listed at all. Targets with nothing on screen *are* listed, dimmed and marked
  `(hidden)`: that is how you anchor to something that only appears in raid.
  The **Backup** row picks the backup anchor from the same list, with a **None**
  row that clears it, minus whatever the primary already is. The seat pair edits
  the live anchor's seat in place.
- **Link-drag.** Each of the two picker rows ends in a chain handle: hold it and
  drag. A line follows the cursor from the element's slab, whatever legal target
  is under the cursor lights up with the same dashed plate a snap zone wears,
  and the release ties the two together without moving anything. The **Target**
  row's handle sets the primary (anchor in place); the **Backup** row's handle
  sets the backup anchor, and is live only once there is a primary to fall back
  from. The *smallest* target under the cursor wins, so a sub-target nested
  inside a container is still reachable. Esc, right-click, a release over
  nothing and combat starting all cancel the gesture with nothing committed.

Either one commits exactly one undo entry, the same as dropping into a snap zone.

## Behaviour rules worth knowing

- Dragging an anchored element shows a **tether** to its target. Within 3× the snap distance of its resolved anchor position the anchor holds: dropped outside every snap zone it springs back (dropping into a zone re-anchors). Pull further and the tether strains (reddens and thins); past 4× the snap distance it **snaps** — the element is free from that moment and the drop commits one "Detach" undo entry. The panel's Detach still frees it without the drag. Selecting or hovering a slab also shows its tether; hovering shows the whole chain (its parent's and all of its children's).
- Hidden frames are never snap targets. If your element is normally hidden (combat-only, raid-only), listen for the `Unlocked` / `Locked` callbacks and show it for the session — the lib never touches your frame's visibility.
- `isRelevant = function() -> bool` on `Register` / `RegisterAnchorTarget`: absent = relevant. Irrelevant elements get no proxy in an unfiltered session and are never snap targets (children anchored to them hold). A key named in an `Unlock` filter is forced relevant. Erroring callbacks count as relevant. `pointLocked = true` on `Register` hides the panel's 9-point picker (the consumer derives `point`).
- A target counts as *available* when it has a `getRect` and that `getRect` returns a rect, or when it has no `getRect` and its frame exists and is shown. A `getRect` that returns `nil` is how you say "not meaningfully on screen right now", and it wins even if the backing frame is technically shown. Unavailable targets are never offered as snap targets, and anything anchored to one holds its last position instead of jumping — it re-solves the next time you call `RefreshAnchorTarget` or `Apply` while the target is available again.
- `snappable = false` on `Register` / `RegisterAnchorTarget` (default true) takes a target out of the snap-zone pass only: a drag builds no zones for it and can never snap to it. It stays a first-class anchor target everywhere else — the panel's anchor and backup pickers both list it, link-drag can land on it, and anything already anchored to it keeps resolving. It is for dense sub-targets, like the per-unit frames inside a container, where twelve zones each would bury the screen.
- A drag snaps to the **nearest** free zone whose landing position is within the **Snap distance** setting (Settings › Snapping, default 25, 0–400) of where the element is now — measured centre to centre, i.e. how far it would jump on drop. The distance is independent of the element's size, so a wide raid container and a single icon snap from the same distance. The zone highlight uses the same radius, so a zone that lights up is a zone that will take the drop.
- Drags, nudges and X/Y edits are clamped so the visible rect stays on screen.
- The per-drag **distance measures** (lines to the nearest screen edge with a px readout) and the **grid snap lines** (the crosshair on the line a drag snapped to) are **off by default** — they are precision aids, and on every drag frame they are louder than the frame being dragged. Turn either on in Settings › Snapping.
- Proxies are dark slabs; the coloured dot and left edge give the role — host accent = free, purple = anchored, green ring = anchor root. On slabs too narrow for both, the addon icon wins and the dot drops (the left edge still carries the role, and a root's green ring moves onto the icon). Selection is a white outline; a faded slab means the real frame is hidden.
- Hold Shift while dragging to move horizontally only, Ctrl to move vertically only (both held = free drag). A nudge (arrow keys or the panel arrows) steps by 1; Shift makes it 10, Ctrl 100.
- Hold Alt (while not dragging) to peek: the slabs, strip and panel fade almost out so you can see the UI underneath; release restores them.
- While a session is open the unlock overlay captures the mouse across the whole screen: left-click on empty space deselects, and the world/camera behind it is not interactable. Lock the session to get the screen back: press Esc, use the top strip's Save & Exit / Discard, or type `/mover`.
