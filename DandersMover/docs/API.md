# DandersMover API Reference

For a step-by-step introduction, start with the [Developer Guide](DEVELOPER_GUIDE.md).

```lua
local Mover, minor = LibStub("DandersMover-1.0", true)   -- nil when not installed
```

The current version is MINOR 9. Anything not listed on this page is internal and may change.

## Addons

### `Mover:RegisterAddon(name, info)`

Groups your elements in the UI. Optional: `Register` does it for you if you skip it.

| Field | Purpose |
|---|---|
| `title` | Display name. Defaults to `name` |
| `icon` | Texture path shown on your movers. Defaults to the bundled icon |
| `watch` | `false` opts all your elements and targets out of the [watcher](#the-watcher). A `watch` set on one element or target wins over this |

Calling it again replaces all three fields.

### `Mover:UnregisterAddon(name)`

Removes the addon and all its elements and targets.

## Elements

### `Mover:Register(addon, key, def)`

Makes a frame movable. It also becomes an anchor target, unless `anchorable = false`. Its id
is `"addon:key"`. Calling it again with the same key replaces the entry, so any field you leave
out is lost.

Bad definitions raise a Lua error. Treat the return value as private.

```lua
Mover:Register("MyAddon", "bar", {
    frame   = bar,
    default = { point = "CENTER", x = 0, y = -200 },
    db      = MyAddonDB,
    dbKey   = "barPosition",
})
```

**Required**

| Field | Purpose |
|---|---|
| `frame` or `getFrame` | The frame, or a function returning it |
| `db` and `dbKey` | The record lives at `db[dbKey]`. `dbKey` is a string or a number |
| or `getPos` | `function() -> record`. Must return the live table |

**`db` and `dbKey`.** The library creates the record when you register, from a copy of `default`, or
at the screen's centre if there's no `default`. If you clear it later, it's created again. `db` is
captured when you register, so an addon that swaps profile tables should use `getPos`.

Giving `db` without `dbKey`, or `dbKey` without `db`, is a Lua error. So is giving `getPos` together
with either of them.

**`getPos`.** It doesn't create the record, so it should always return a table. If it errors or returns
anything else, the library reports it once, leaves the element out of the editor, and doesn't call
`onChanged`. Everything goes back to normal as soon as it returns a table.

**Optional**

| Field | Default | Purpose |
|---|---|---|
| `title` | `key` | Display name |
| `group` | none | Heading to list the element under |
| `default` | screen centre | The record that Reset restores, and that `db` and `dbKey` start from |
| `onChanged` | places the frame | `function(pos, reason)`. Left out, the library calls `Mover.ApplyPosition` on your frame. Give your own to move the frame yourself |
| `secure` | asks the frame | `true` delays `onChanged` until combat ends, and `false` never does. Left out, it delays when `frame:IsProtected()` is true. A frame that doesn't exist yet counts as not protected |
| `watch` | your addon's `watch`, else `true` | `false` opts this element out of the [watcher](#the-watcher). `true` keeps it in, even if your addon opted out |
| `getSize` | frame size | `function() -> w, h` in UIParent units. Ignored while `getRect` returns a rect |
| `getRect` | frame geometry | The visible rect. See [getRect](#getrect) |
| `visibleOffset` | none | See [visibleOffset](#visibleoffset) |
| `isRelevant` | always | See [Relevance](#relevance) |
| `partOf` | none | Same as on [anchor targets](#anchor-targets) |
| `anchorable` | `true` | `false` stops others anchoring to it |
| `snappable` | `true` | `false` removes its snap zones. It stays in the picker and link drag |
| `pointLocked` | `false` | `true` hides the panel's 9-point picker, for when you choose `point` yourself |
| `openSettings` | none | `function()`. Adds a **Configure** button to the panel |
| `twin` | none | `"addon:key"` of a counterpart. Adds a **Copy to...** button, which copies the whole record as one undo step. The anchor is dropped if keeping it would create a loop |

### `Mover:Unregister(addon, key)`

Removes one element or target.

### `Mover:RenameKey(addon, old, new)`

Changes a key without moving anything. The player's toggle, your entry, and the saved anchors and
`twin` values of elements already registered all follow.

Call it **before** registering the new key: if `new` is taken, it returns `false` and changes
nothing. It also returns `false` during a session or if the names match.

An addon that registers later with an anchor to the old id isn't updated, unless the rename ran
before the library finished loading.

### `Mover:Apply(addon, key)`

Works out the element's position if it's anchored, calls `onChanged(pos, "reapply")`, then updates
everything anchored to it.

The [watcher](#the-watcher) does this for you at login, for late registrations, and when the frame or
its scale changes. For a `watch = false` element, call it once at login, and after changing the
frame's scale.

### `Mover:IsEnabled(addon[, key])`

Returns whether the player has left this addon or element turned on.

## Anchor targets

### `Mover:RegisterAnchorTarget(addon, key, def)`

Something others can anchor to that isn't movable itself.

| Field | Purpose |
|---|---|
| `frame` or `getFrame` | Required. The frame, or a function returning it |
| `title` | Display name. Defaults to `key` |
| `group` | Heading to list it under |
| `getSize`, `getRect`, `isRelevant`, `snappable`, `watch` | Same as on elements |
| `partOf` | `"addon:key"` of the element this sits inside. Moving that element moves this target, so anchoring the element to it counts as a loop |

Registering a target on a key an element already uses replaces that element's own anchor target.

### `Mover:RefreshAnchorTarget(addon, key)`

Updates everything anchored to this target. It doesn't call the target's own `onChanged`.

For a `watch = false` target, call it when you move the frame, when a `getFrame` target now returns a
different frame, or when a target hides or comes back. For a watched target it's optional: followers
update straight away rather than at the next check.

### `Mover:RefreshAnchorTargets(addon, keys)`

The same for a list of keys, in one pass. An element anchored to two of them is only worked out
once. Prefer this to a loop when several targets move together.

### `Mover:RefreshMovedTargets(addon, keys)`

For size changes on `watch = false` targets, which nothing else reports. The watcher does the same
check for watched ones. It measures each key, and updates only the ones that changed by more than
half a unit, plus whatever is anchored to them. Returns how many moved. The first call for each key
always counts as moved, and keys with no anchor target (`anchorable = false`) are skipped.

It's cheap enough to call every frame. It does nothing if called from inside itself, so it's safe
if your `onChanged` leads back to it. `keys` has to stay valid for the whole call.

## Anchoring from code

### `Mover:SetAnchor(addon, key, spec)`

Anchors an element. `spec` is an [anchor block](#anchor-block) with a required `target`, and it's
copied. `nil` means `Detach`. It replaces the whole anchor, so include `fallback` to keep one.

Returns `false` and changes nothing if the element isn't registered, `target` is missing, or the
main or backup target would make a loop.

During a session it's one undo step, and Discard reverts it. Otherwise it writes the record, calls
`onChanged(pos, "anchor")`, and updates anything anchored to the element.

Setting an anchor converts the record to a `"CENTER"` point without moving the frame. If the target
isn't available yet, the frame stays where it is until the first solve.

### `Mover:Detach(addon, key)`

Frees an element where it sits. It works the same two ways, using `onChanged(pos, "detach")`.
Returns `false` only if the element isn't registered.

## The editor

### `Mover:Unlock([filter])`

Opens the editor. Refused in combat, with a chat message. If it's already open, nothing happens and
the filter is ignored.

| `filter` | Result |
|---|---|
| `nil` | Every enabled, relevant element |
| `"MyAddon"` | That addon's enabled, relevant elements get movers |
| `{ addon = "MyAddon", keys = { "a", "b" } }` | Only those keys get movers, and they're treated as relevant for the session |

With a filter, other addons' enabled and relevant elements still act as anchor targets. They only
get movers if the player turns on **Show other addons' movers**.

`keys` without `addon` is a Lua error.

### `Mover:Lock([onDone])`

Closes the editor, prompting first if there are unsaved changes. `onDone(true)` runs once it has
closed, or immediately if it wasn't open. `onDone(false)` runs if the player cancels the prompt.

### `Mover:Toggle()`, `Mover:IsUnlocked()`

Opens or closes the editor, and returns whether it's open.

## Helpers

### `Mover.ApplyPosition(frame, pos)`

Note the dot, not a colon. Clears the frame's points and sets it from `point`, `x` and `y`,
allowing for the frame's scale:

```lua
frame:SetPoint(pos.point or "CENTER", UIParent, "CENTER", (pos.x or 0) / ratio, (pos.y or 0) / ratio)
-- ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
```

## Callbacks

```lua
Mover.RegisterCallback(yourTable, "EventName", function(event, ...) end)
Mover.UnregisterCallback(yourTable, "EventName")
Mover.UnregisterAllCallbacks(yourTable)
```

This is standard CallbackHandler-1.0, so the first argument is the event name.

| Event | Arguments | When |
|---|---|---|
| `Unlocked` | none | The editor opened |
| `Locked` | none | The editor closed. Fires before `Saved` or `Discarded` |
| `Saved` | none | The session ended without being discarded, even if nothing changed |
| `Discarded` | none | The session ended and its changes were reverted |
| `PositionChanged` | `addon, key, pos, reason` | Right after any element's `onChanged`. `Apply` fires it even if nothing moved |
| `RegistryChanged` | `addon, key` | Something was registered or removed |

`RegistryChanged` has a nil `key` for `RegisterAddon`, `UnregisterAddon` and `RenameKey`. Both values
are nil after the login queue is processed. It can fire in bursts, so debounce it with
`C_Timer.After(0, ...)` if you only need to redraw once.

## `reason` values

Passed to `onChanged` and `PositionChanged`.

| Reason | Meaning |
|---|---|
| `drag` | The player dragged it. Fires every frame of a drag, and the anchor is absent until the drop. A tether break arrives as `drag` too |
| `nudge` | Arrow keys, panel arrows, typed X/Y or the 9-point picker |
| `anchor` | An anchor was set or changed |
| `detach` | The **Detach** button or `Mover:Detach` |
| `fallback` | The backup anchor was set or changed |
| `center` | The **Center** button, which also detaches. Reset in a session, for an element with no `default` |
| `reset` | Reset to `default`, or to the screen's centre outside a session if there's no `default` |
| `copy` | **Copy to...**, sent to the element being copied onto |
| `undo`, `redo` | Undo or redo |
| `discard` | The session was discarded |
| `reapply` | The library re-solved it: `Apply`, `RefreshMovedTargets`, the watcher, a drag that sprang back, or anything delayed by combat |
| `parent` | Its target moved and the library re-solved it |

A `secure` element that changes in combat gets `reapply` once combat ends, whatever the original
reason was. So `reason` can't fully separate a player's action from a re-solve. Treat `parent` as
always a re-solve, and `reapply` as usually one.

## Position record

```lua
{
    point = "CENTER",   -- which part of the frame sits at x, y. Defaults to "CENTER"
    x = 0,              -- UIParent units from the screen's centre
    y = 0,
    anchor = nil,       -- optional anchor block
}
```

`point`, `x` and `y` are always valid absolute coordinates. The library keeps them up to date while
a frame is anchored, so you can apply them and ignore `anchor` if the library isn't present.

An anchored solve normally rewrites `point` to `"CENTER"`, so your `onChanged` must honour `point`
rather than assuming it stays the same.

## Anchor block

```lua
anchor = {
    target = "OtherAddon:key",      -- required

    -- Outside mode, the default: sit beside one of the target's edges
    edge = "bottom",                -- top, bottom, left, right. Defaults to right
    align = "start",                -- start, center, end. Defaults to center

    -- Point mode: like child:SetPoint(point, target, relPoint, offsetX, offsetY)
    mode = "point",
    point = "TOPLEFT",
    relPoint = "BOTTOMLEFT",

    offsetX = 0,
    offsetY = 0,

    -- Optional: see below
    fallback = { target = "OtherAddon:spare", edge = "bottom", align = "start", offsetX = 0, offsetY = 0 },
    mirrorX = true, mirrorPosX = 0,
    mirrorY = true, mirrorPosY = 0,
}
```

Use outside mode or point mode, not both. Outside mode adds an automatic 2-unit gap on top of the
offsets. Point mode has none.

### Which anchor is live

The order is **main, then fallback, then hold**. The main anchor drives the element while its target
is [available](#availability), the fallback takes over when it isn't, and with neither the element
holds its last position.

This is decided when a solve runs, not continuously. See [Availability](#availability).

`fallback` has the same fields as the main block apart from mirroring, and can't have a fallback of
its own. It's stored inside the main anchor, so removing the anchor removes it too. Re-anchoring in the
editor keeps it, unless the new target is the fallback's own target. `Mover:SetAnchor` replaces the
whole anchor.

### Mirroring

On a mirrored axis, the element's centre is its target's centre reflected across a line. Using centres
means frames of different sizes still look symmetrical. The line is at `mirrorPosX` (a vertical line)
or `mirrorPosY` (a horizontal one), in UIParent units from the screen's centre. `nil` reads as `0`.

The offsets stay numbers on a mirrored axis. Each solve rewrites them to the plain offset that would
give the same position, so older code that doesn't know about mirroring still places the frame in the
right spot. Mirroring only applies to the main anchor.

## `getRect`

```lua
getRect = function() return { x = cx, y = cy, w = w, h = h } end
```

Reports the visible rect, in UIParent units with `x` and `y` measured from the screen's centre, when it
differs from the frame's own geometry. Snap zones, movers and drag maths all use it. Return `nil` when
nothing is on screen.

## `visibleOffset`

```lua
visibleOffset = function(pos) return dx, dy end
```

Says where the visible centre sits relative to the record you're given: at `(pos.x + dx, pos.y + dy)`.
Add it when your `getRect` isn't centred on your record, such as a container reserved for more than it
shows. An anchored solve then puts the visible rect on its seat rather than the container, and re-solves
keep your `point` rather than rewriting it to `"CENTER"`. Setting an anchor still sets it to `"CENTER"`
first.

Measure it live: your visible centre against your container's centre, plus where the record puts the
container. Return `nil` when you can't measure. The library then writes the seat's centre as a `CENTER`
point, which is right when your frame is your visible rect.

## Relevance

`isRelevant = function() -> bool`, on elements and targets, answers "does this take part right now?". A
relevant element gets a mover in an unfiltered session and can be snapped to. An irrelevant one doesn't,
and anything anchored to it holds.

A key named in an `Unlock` filter counts as relevant for that session. A function that errors counts as
relevant, and the error is reported.

The order is: player's toggle, then the `Unlock` key filter, then `isRelevant`.

## Availability

A target is available when all of this is true:

- It's relevant.
- If it has a `getRect`, that returns a rect. Returning `nil` wins even if the frame is shown.
- If it has no `getRect`, its frame exists and `IsVisible()` is true, so a frame under a hidden parent
  doesn't count.
- The watcher hasn't left it out because its callback threw. See [The watcher](#the-watcher).

Unavailable targets are never snap targets, and anything anchored to them holds.

**When this is checked.** The library has no show or hide hooks, so availability is only checked when a
solve runs. For a watched target, the [watcher](#the-watcher) sees it hide or return at its next check
and starts that solve, so an element switches to its backup and back by itself.

For a `watch = false` target, nothing polls. If it hides or returns, call `RefreshAnchorTarget`, `Apply`
or `RefreshMovedTargets`, or anything anchored to it stays where it is, including an element that should
switch to its backup.

## The watcher

Five times a second, the library checks the frames it's watching and makes the calls you'd otherwise
have to make yourself. Every element and target is watched unless you opt it out.

| What happens | What the watcher does |
|---|---|
| Login | Applies every watched element once, in one pass |
| An element registers after login | Applies it on the next frame |
| A target moves, resizes, hides or comes back | Updates everything anchored to it |
| An anchored element changes size | Works out its position again, as its size affects its seat |
| `getFrame` returns a different frame | Applies the element |
| The frame's scale changes | Applies the element |

These arrive as the `reapply` and `parent` reasons, the same as the calls they replace.

**Cost.** A check only measures targets named in an anchor (main or backup), and anchored elements. While
the editor is open it also measures every watched target, so that movers can resize. If nothing is
watched, the timer doesn't run.

**Opting out.** Set `watch = false` on an element or target, or use `RegisterAddon(name, { watch = false })`
as the default for your whole addon. An opted-out element isn't applied for you, so call `Apply` once at
login, and report changes with `RefreshAnchorTarget`, `RefreshAnchorTargets` and `RefreshMovedTargets`.

The target's setting is the one that counts for following. A watched element anchored to an opted-out target
only moves when the target's owner reports the change.

**Limits.**

- The watcher never writes a move your code made into the record. Followers follow the frame, but the
  next `Apply`, login or scale change puts the frame back at its record. Update the record too if the
  move should stick.
- An element with `anchorable = false` isn't measured, so its own resize isn't worked out again. Call
  `Apply` when it resizes.
- A frame going away doesn't apply the element, as there's nothing left to place. If it's a target, it
  counts as hidden.
- If `getRect`, `getSize` or `getFrame` throws during a check, the error is reported once. The element
  or target is then left out of watching until it's registered again, and as a target it counts as
  unavailable.
- While a mover is being dragged, the check is skipped, so a watched frame's followers don't update until
  the drag ends.
- Values that are secret in combat are skipped, and the next check tries again.

### `Mover:GetWatcherStats()`

Returns a new table, for measuring the watcher's cost in game:

```
/dump LibStub("DandersMover-1.0"):GetWatcherStats()
```

| Field | Meaning |
|---|---|
| `running` | Whether the timer exists |
| `watched` | How many element and target ids are watched |
| `measured` | How many targets the last check measured |
| `ticks` | How many checks have run. Skipped ones don't count |
| `lastMs`, `maxMs` | Time for the last check and the longest one, in milliseconds |

## Rules worth knowing

- **Loops are refused.** An element can't anchor to itself, its own descendants, or a target that's
  `partOf` it.
- **Anchors stay on screen.** A solve only gets pulled back if none of the element would be visible. A
  deliberate overhang keeps its seat. The anchor itself isn't changed, so it re-solves normally later.
- **Dragging is clamped.** On a free element, drags, nudges and typed values keep the visible rect on
  screen, apart from a drag held on a snap zone, which previews the exact seat. Anchored elements only
  follow the rule above.
- **The tether.** Up to 4x the snap distance from its seat, a drop outside every zone springs back. The
  tether strains from 2x. Past 4x it detaches, which is one undo step. At snap distance 0 it never breaks.
- **Combat.** A session pauses when combat starts and resumes afterwards. Changes to `secure` elements,
  and to protected frames when `secure` is left out, wait until combat ends.
- **Errors in your callbacks.** `onChanged`, `getPos`, `visibleOffset`, `isRelevant` and `openSettings`
  are protected: errors go to the normal error handler. `getRect`, `getSize` and `getFrame` aren't, and
  an error there stops whatever was running, so they must not error. The exception is a
  [watcher](#the-watcher) check, which catches them.

## Saved variables

`DandersMoverDB` holds editor settings and the player's toggles. It never holds positions.

## Version history

Check a function exists, or compare `minor`, before relying on these.

| MINOR | Added |
|---|---|
| 2 | `RefreshMovedTargets` |
| 3 | `visibleOffset` |
| 4 | `partOf` on targets |
| 5 | `Lock(onDone)` |
| 6 | `SetAnchor`, `Detach` |
| 7 | Mirroring: `mirrorX`, `mirrorY`, `mirrorPosX`, `mirrorPosY` |
| 8 | Fixes: a failing `getPos` no longer stops the editor opening, and anchoring to an unavailable target no longer moves the frame |
| 9 | Short registration: `db`, `dbKey`, optional `onChanged`. `secure` detected from the frame. The watcher: auto-apply, `watch`, `RegisterAddon`'s `watch`, `GetWatcherStats` |
