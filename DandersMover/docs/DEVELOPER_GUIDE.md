# DandersMover Developer Guide

How to add DandersMover to your addon. For every option in detail, see the
[API Reference](API.md).

## How it works

Three ideas explain most of the system:

1. **You keep your positions.** DandersMover never stores them. You give it a table, it
   edits that table, and it tells you to apply the result. Your addon saves it as normal.
2. **Your addon works without it.** DandersMover is optional. Your saved position always
   holds real coordinates, so you can apply it with or without the library.
3. **It never touches your frames.** It doesn't move, show or hide them. It calls your
   `onChanged` function, and your code moves the frame.

## Step 1: Load after DandersMover

Add this to your TOC:

```
## OptionalDeps: DandersMover
```

DandersMover must be installed as its own addon, in `Interface\AddOns\DandersMover`. Don't
copy it into your `Libs` folder: it needs its own saved variables and loads its art from
that path. You can ship the whole folder alongside your addon in your zip, as
DandersFrames does.

## Step 2: The position record

Each frame needs a table saved in your saved variables:

```lua
{ point = "CENTER", x = 0, y = -200 }
```

`x` and `y` are measured from the centre of the screen, in UIParent units. `point` is the
part of your frame placed there. When a frame is anchored, the table also gets an `anchor`
block. You can save it without looking inside it.

Two rules:

- **`getPos` must always return the live table**, not a copy. DandersMover edits it directly.
  `default` doesn't create it for you, so create the record before you register. Until `getPos`
  returns a table, the library reports an error once, your element is left out of the editor,
  and `onChanged` isn't called.
- **Don't replace the table with a new one** while something still holds the old one. If
  you reset it yourself, change its contents instead.

## Step 3: A complete example

This is a whole working addon. Save it as `MyAddon.lua`, list it in your TOC, and add
`## SavedVariables: MyAddonDB`.

<!-- doc-example: complete-addon -->
```lua
local ADDON_NAME = ...

local DEFAULT_POS = { point = "CENTER", x = 0, y = -200 }

-- Your frame.
local bar = CreateFrame("Frame", "MyAddonBar", UIParent)
bar:SetSize(200, 30)
local background = bar:CreateTexture(nil, "BACKGROUND")
background:SetAllPoints()
background:SetColorTexture(0.1, 0.4, 0.8, 0.8)

-- Places the frame from a position record. Works with or without DandersMover.
local function applyPosition(frame, pos)
    local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    frame:ClearAllPoints()
    frame:SetPoint(pos.point or "CENTER", UIParent, "CENTER",
        (pos.x or 0) / ratio, (pos.y or 0) / ratio)
end

local Mover = LibStub and LibStub("DandersMover-1.0", true)

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        MyAddonDB = MyAddonDB or {}
        MyAddonDB.barPosition = MyAddonDB.barPosition
            or { point = DEFAULT_POS.point, x = DEFAULT_POS.x, y = DEFAULT_POS.y }

        -- Always apply your own position, with or without the library.
        applyPosition(bar, MyAddonDB.barPosition)

        if Mover then
            Mover:RegisterAddon(ADDON_NAME, { title = "My Addon" })
            Mover:Register(ADDON_NAME, "bar", {
                title     = "My Bar",
                frame     = bar,
                default   = DEFAULT_POS,
                getPos    = function() return MyAddonDB.barPosition end,
                onChanged = function(pos) applyPosition(bar, pos) end,
            })
        end
    elseif event == "PLAYER_LOGIN" and Mover then
        -- Other addons have registered by now, so saved anchors can be worked out.
        Mover:Apply(ADDON_NAME, "bar")
    end
end)
```

Type `/mover` in game and your bar has a mover. `/mover reset myaddon` puts it back to
`DEFAULT_POS`.

## Step 4: Keep anchors up to date

This is the step that's easiest to miss. DandersMover doesn't watch your frames, so it
only knows they changed when you tell it. If you don't, anything anchored to your frame
stays where it was.

| What happened | Call |
|---|---|
| Your frames exist and you've finished registering | `Mover:Apply(addon, key)` once per element |
| Your code moved a frame | `Mover:RefreshAnchorTarget(addon, key)` |
| Several frames moved together | `Mover:RefreshAnchorTargets(addon, keys)` |
| A frame changed size | `Mover:RefreshMovedTargets(addon, keys)` |
| A frame's scale changed, and it may be anchored | `Mover:Apply(addon, key)` |
| A `getFrame` now returns a different frame | `Mover:RefreshAnchorTarget(addon, key)` |
| A frame hid or came back | `Mover:RefreshAnchorTarget(addon, key)` |

`Apply` works out the element's own position, calls your `onChanged`, and updates everything
anchored to it. That covers both directions at login: your frame anchored to someone else,
and someone else anchored to your frame.

The hide and show row matters more than it looks. Nothing watches for frames appearing or
disappearing, so a backup anchor only takes over, and the main anchor only takes back, when
the target's owner makes this call.

`RefreshMovedTargets` measures first and does nothing if nothing changed, so it's cheap
enough to call from your layout code. It returns how many targets moved. The first call for
each key always counts as moved. Use it for size changes, not for visibility: if the rect
hasn't changed, it won't notice a hide.

## Step 5: The options you're likely to need

### Protected frames

Set `secure = true` for frames that can't move in combat, such as anything built on a
secure template. `onChanged` then waits until combat ends.

```lua
Mover:Register("MyAddon", "unitFrame", {
    title     = "My Unit Frame",
    frame     = myUnitFrame,
    secure    = true,
    getPos    = function() return MyAddonDB.unitFrame end,
    onChanged = function(pos) Mover.ApplyPosition(myUnitFrame, pos) end,
})
```

### Frames that don't exist yet

Use `getFrame` in place of `frame`:

```lua
getFrame = function() return MyAddon.containerFrame end,
```

### Frames that aren't always on screen

Use `isRelevant` for frames that only matter sometimes:

```lua
isRelevant = function() return IsInRaid() end,
```

While it returns false, the element gets no mover in a normal session and can't be snapped
to, and anything anchored to it stays put.

DandersMover never shows your frame for you, and hidden frames can't be snapped to. To show
one during editing, use the callbacks:

```lua
Mover.RegisterCallback(MyAddon, "Unlocked", function() myCombatFrame:Show() end)
Mover.RegisterCallback(MyAddon, "Locked", function() myCombatFrame:Hide() end)
```

### Frames whose visible part differs from the frame

If your frame is bigger than what's visible, such as a large container holding a few
buttons, report the visible part with `getRect`. Movers, snapping and anchoring then use it.

```lua
getRect = function()
    local cx, cy = visiblePart:GetCenter()
    if not cx then return nil end
    local ratio = visiblePart:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    return {
        x = cx * ratio - ux,
        y = cy * ratio - uy,
        w = visiblePart:GetWidth() * ratio,
        h = visiblePart:GetHeight() * ratio,
    }
end,
```

All of these are in UIParent units, with `x` and `y` measured from the screen's centre.
Return `nil` to say there's nothing on screen.

If that visible part isn't centred on your record, add `visibleOffset` too, or anchored
frames will land off their seat. See the [API Reference](API.md#visibleoffset).

### Things that can be anchored to but not moved

Other addons can anchor to these, such as a Blizzard frame or a unit frame inside your
container:

```lua
Mover:RegisterAnchorTarget("MyAddon", "minimap", {
    title = "Minimap",
    frame = Minimap,
})
```

For a frame inside one of your movable elements, add `partOf` so nobody can anchor the
element to its own contents. For lots of small targets, add `snappable = false` so the
screen doesn't fill with snap zones. They stay available in the panel's target list.

```lua
Mover:RegisterAnchorTarget("MyAddon", "button1", {
    title     = "Button 1",
    frame     = button1,
    partOf    = "MyAddon:container",
    snappable = false,
})
```

## Step 6: Anchoring between addons

Every element is named `"AddonName:key"`, and that's all you need to anchor to it. Players
do this in the editor. Your code can also do it, for example behind an "attach to party
frames" checkbox:

```lua
local ok = Mover:SetAnchor("MyAddon", "bar", {
    target  = "DandersFrames:group",
    edge    = "bottom",
    align   = "center",
    offsetX = 0,
    offsetY = -4,
})
```

`DandersFrames:group` follows whichever group frames are showing, party or raid. Edge anchors
already have a 2-unit gap, so this example sits 6 units below.

`SetAnchor` returns `false` if the element isn't registered, the spec has no target, or it
would make a loop. It replaces the whole anchor, so include `fallback` if you want to keep one.
`Mover:Detach(addon, key)` frees the element where it sits.

The target doesn't have to be loaded when you set this. When the other addon registers and
calls `Apply` or `RefreshAnchorTarget`, yours follows. Until then your frame stays where it is.

To get notified of changes:

```lua
Mover.RegisterCallback(MyAddon, "PositionChanged", function(event, addon, key, pos, reason)
    -- runs for every element, so check addon and key
end)
```

Callback functions get the event name as their first argument.

## Step 7: Your own settings button

Open the editor from your own UI, showing only your frames:

```lua
Mover:Unlock("MyAddon")
```

Or only some of them. Keys named here get a mover even if `isRelevant` says no, which lets
a solo player arrange raid frames:

```lua
Mover:Unlock({ addon = "MyAddon", keys = { "raid", "raidPets" } })
```

Other addons' frames still work as snap and anchor targets in these sessions. Their movers
only show if the player turns on **Show other addons' movers**.

Going the other way, `openSettings` adds a **Configure** button to your element's panel:

```lua
openSettings = function() MyAddon:OpenOptions("bar") end,
```

To close the editor and find out whether it really closed, since the player can cancel the
unsaved-changes prompt:

```lua
Mover:Lock(function(ended)
    if ended then MyAddon:ContinueWhatYouWereDoing() end
end)
```

## Moving from your own mover

1. Convert your saved positions to the record format, once. `x` and `y` have to be measured
   from the screen's centre, and they're stored in UIParent units.
2. Keep your own apply code, so the addon still works without DandersMover.
3. Register each frame, and hide your old mover when `Mover` exists.
4. Point your "unlock" button at `Mover:Unlock("MyAddon")`.

If you later rename a key, call `Mover:RenameKey(addon, old, new)` before registering the new
key, so that anchors other elements have saved to it keep working. See the
[API Reference](API.md#moverrenamekeyaddon-old-new) for its limits.

## Supporting older versions

Players may have an older copy. `LibStub` also returns the version number, and you can
check for a function before calling it:

```lua
local Mover, minor = LibStub("DandersMover-1.0", true)
if Mover and minor >= 6 then
    Mover:SetAnchor("MyAddon", "bar", spec)
end
```

The [API Reference](API.md#version-history) lists what each version added.

## Checklist

- [ ] `## OptionalDeps: DandersMover` is in your TOC
- [ ] Your code still places the frame when `Mover` is nil
- [ ] `getPos` returns the live saved table
- [ ] `onChanged` moves the frame
- [ ] You pass a `default`, so `/mover reset` has somewhere to go
- [ ] You call `Mover:Apply` once at login
- [ ] You call a refresh function when your code moves or resizes a frame
- [ ] Protected frames have `secure = true`
- [ ] Keys never change without `RenameKey`

## Common problems

**"attempt to index a nil value" on `Mover`.** It isn't installed. Wrap your calls in
`if Mover then`, and pass `true` as the second argument to `LibStub`.

**`Mover` is nil even though it's installed.** The `OptionalDeps` line is missing, so your
addon loaded first.

**The frame snaps back after dragging.** If it's anchored, that's by design: a drop within 4x
the snap distance of its seat springs back. Otherwise your own code is re-applying an old
position, or `getPos` is returning a copy.

**Something anchored to my frame doesn't follow it.** Your code moved the frame without
telling DandersMover. See step 4.

**The frame lands off its seat when anchored.** Your `getRect` isn't centred on your record.
Add `visibleOffset`.

**Errors about protected frames in combat.** Add `secure = true`.
