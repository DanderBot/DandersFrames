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

## API

| Call | Purpose |
|---|---|
| `Mover:RegisterAddon(name, { title, icon })` | Group your elements in the UI |
| `Mover:Register(addon, key, def)` | Make a frame movable. `def`: `title`, `frame` or `getFrame`, `getPos`, `onChanged(pos, reason)`, optional `default`, `secure`, `getSize`, `anchorable`, `group` |
| `Mover:RegisterAnchorTarget(addon, key, { title, frame or getFrame })` | Something others can anchor to but that is not itself movable |
| `Mover:RefreshAnchorTarget(addon, key)` | Call when a `getFrame` target now resolves to a different frame |
| `Mover:Apply(addon, key)` | Re-solve and re-fire `onChanged` (e.g. after you change the frame's scale) |
| `Mover:Unregister(addon, key)`, `Mover:UnregisterAddon(addon)` | Cleanup |
| `Mover:Unlock([addon])`, `Lock()`, `Toggle()`, `IsUnlocked()` | Drive the editor from your own UI |
| `Mover:IsEnabled(addon[, key])` | Respect the user's mover toggles |
| `Mover.ApplyPosition(frame, pos)` | SetPoint + scale maths helper |
| `Mover.RegisterCallback(obj, event, fn)` | Events: `Unlocked`, `Locked`, `Saved`, `Discarded`, `PositionChanged(addon, key, pos, reason)` |

`reason` values: `drag nudge anchor detach reset center undo redo discard reapply parent`.

Slash: `/mover` toggle, `/mover config` settings, `/mover demo` built-in demo.
