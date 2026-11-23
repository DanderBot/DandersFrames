# DandersMover Developer Guide

Add a mover to your addon in about ten lines. For every option, see the
[API Reference](API.md).

## How it works

- **You keep your positions.** They stay in your saved variables, so your addon still
  works without DandersMover.
- **DandersMover does the rest.** It places your frame, gives it a mover, and watches it
  so that anything anchored to it follows.

## Setup

### 1. Load after DandersMover

Add this to your TOC:

```
## OptionalDeps: DandersMover
## SavedVariables: MyAddonDB
```

Players install DandersMover as its own addon. Don't copy it into your `Libs` folder.

### 2. Register your frame

<!-- doc-example: complete-addon -->
```lua
local ADDON_NAME = ...
local DEFAULT_POS = { point = "CENTER", x = 0, y = -200 }

local bar = CreateFrame("Frame", "MyAddonBar", UIParent)
bar:SetSize(200, 30)

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON_NAME then return end
    self:UnregisterEvent("ADDON_LOADED")
    MyAddonDB = MyAddonDB or {}

    -- Places the frame when DandersMover isn't installed.
    local pos = MyAddonDB.barPosition or DEFAULT_POS
    bar:SetPoint(pos.point, UIParent, "CENTER", pos.x, pos.y)

    local Mover, version
    if LibStub then Mover, version = LibStub("DandersMover-1.0", true) end
    if Mover and version >= 9 then
        Mover:Register(ADDON_NAME, "bar", {
            title   = "My Bar",
            frame   = bar,
            default = DEFAULT_POS,
            db      = MyAddonDB,
            dbKey   = "barPosition",
        })
    end
end)
```

### 3. Try it

Type `/mover`. Your bar has a mover, it can snap and anchor to other addons' frames, and
theirs can anchor to it. `/mover reset myaddon` puts it back to `DEFAULT_POS`.

That's the whole setup. Everything below is optional.

## Common options

| You want | Add |
|---|---|
| A frame that doesn't exist yet | `getFrame = function() return MyAddon.frame end` in place of `frame` |
| A mover only when it applies | `isRelevant = function() return IsInRaid() end` |
| A Configure button on the panel | `openSettings = function() MyAddon:OpenOptions() end` |
| Your own code to move the frame | `onChanged = function(pos) ... end` |
| To supply the position yourself | `getPos = function() return myTable end` in place of `db` and `dbKey` |

Protected frames are detected automatically, and their moves wait until combat ends.

## Let other addons anchor to part of your addon

```lua
Mover:RegisterAnchorTarget("MyAddon", "button1", {
    title  = "Button 1",
    frame  = button1,
    partOf = "MyAddon:bar",   -- stops the bar anchoring to its own button
})
```

## Anchor from your code

Every frame is named `"AddonName:key"`:

```lua
Mover:SetAnchor("MyAddon", "bar", {
    target = "DandersFrames:group",
    edge   = "bottom",
    align  = "center",
})
```

Your frame stays put until the target loads, then follows it.

## Open the editor from your settings

```lua
Mover:Unlock("MyAddon")                                   -- only your frames
Mover:Unlock({ addon = "MyAddon", keys = { "raid" } })    -- only these frames
```

## Turning off the watcher

DandersMover checks watched frames a few times a second, so anchored frames follow them
automatically. Only frames that are anchored, or have something anchored to them, are
measured, so most frames cost almost nothing.

If a frame moves a lot, or you want full control, turn it off:

```lua
watch = false,
```

To turn it off for your whole addon, call this before you register your frames:

```lua
Mover:RegisterAddon("MyAddon", { watch = false })
```

You then have to report changes yourself, or anything anchored to that frame stops following:

| What happened | Call |
|---|---|
| Your frames exist and you've finished registering | `Mover:Apply(addon, key)` once per frame |
| Your code moved it, or it hid or came back | `Mover:RefreshAnchorTarget(addon, key)` |
| Several moved together | `Mover:RefreshAnchorTargets(addon, keys)` |
| It changed size | `Mover:RefreshMovedTargets(addon, keys)` |
| Its scale changed | `Mover:Apply(addon, key)` |

You can also make these calls with the watcher on. Followers then update straight away
rather than at the next check.

## Moving from your own mover

1. Convert your saved positions to `{ point, x, y }`, once. `x` and `y` are measured from
   the screen's centre, in UIParent units.
2. Keep your own placing code, so the addon works without DandersMover.
3. Register each frame, and hide your old mover when `Mover` exists.
4. Point your "unlock" button at `Mover:Unlock("MyAddon")`.

## Common problems

**`Mover` is nil even though it's installed.** The `OptionalDeps` line is missing.

**No mover appears, and no error.** The player's copy of DandersMover is older than version 9.

**The frame snaps back after dragging.** If it's anchored, that's by design: a drop close to
its seat springs back. Otherwise your own code is re-applying an old position.

**The frame jumps back after my code moved it.** Moving a frame doesn't change its saved
position, so the next login or scale change puts it back. Update `db[dbKey]` too if the move
should stick.

**The mover doesn't line up with what's visible.** Your frame is bigger than the part you can
see. Add `getRect`, covered in the [API Reference](API.md#getrect).

**Something anchored to my frame doesn't follow it.** You've set `watch = false` without
making the refresh calls above.
