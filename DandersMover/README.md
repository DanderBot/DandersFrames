# DandersMover

One mover for all your World of Warcraft addons.

Most addons ship their own way of moving frames, and those movers can't see each
other. DandersMover is a shared, open source system: any addon can register its
frames, and they all appear in one editor where they can snap to each other,
anchor to each other, and move together.

The more addons that use it, the more of your UI works as one piece.

## What you get

**As a player**

- One command, `/mover`, to arrange every supported addon at once
- Snapping to a grid, the screen edges and other frames
- Anchoring across addons, so moving one frame brings the frames attached to it
- A backup anchor for when a frame's target isn't on screen
- Mirroring, so two frames stay symmetrical around a centre line
- Undo, redo, save and discard

**As an addon author**

- A few lines of code get you a complete mover
- Your addon keeps its own saved positions and works without DandersMover installed
- Your frames can anchor to other addons' frames, and theirs to yours
- Protected frames are handled in combat: moves wait until combat ends
- You can open the editor from your own settings, limited to your own frames

## Install

DandersMover has to be its own addon, in this exact folder:

```
World of Warcraft\_retail_\Interface\AddOns\DandersMover
```

The folder must contain `DandersMover.toc` directly, and has to be named
`DandersMover`. GitHub's "Download ZIP" names it `DandersMover-main`, so rename it.

It also comes with [DandersFrames](https://github.com/DanderBot/DandersFrames), and
each DandersFrames release includes a standalone `DandersMover` zip.

Restart the game fully the first time. `/reload` doesn't pick up a new addon folder.

## Quick start for players

1. Type `/mover`.
2. Drag frames around. Drop one near another frame to snap and anchor it.
3. Click a frame to open its panel for exact positions and anchors.
4. Press **Save & Exit**, or **Discard** to undo the whole session.

The [User Guide](docs/USER_GUIDE.md) covers everything else.

## Quick start for addon authors

Add this to your TOC so DandersMover loads first:

```
## OptionalDeps: DandersMover
```

Then register your frame once your saved variables are loaded:

```lua
local Mover = LibStub and LibStub("DandersMover-1.0", true)   -- nil when not installed

-- Your addon owns the position, so create it and place the frame yourself.
MyAddonDB.barPosition = MyAddonDB.barPosition or { point = "CENTER", x = 0, y = -200 }
local pos = MyAddonDB.barPosition
myBar:ClearAllPoints()
myBar:SetPoint(pos.point, UIParent, "CENTER", pos.x, pos.y)

if Mover then
    Mover:RegisterAddon("MyAddon", { title = "My Addon" })
    Mover:Register("MyAddon", "bar", {
        title     = "Cooldown Bar",
        frame     = myBar,
        default   = { point = "CENTER", x = 0, y = -200 },
        getPos    = function() return MyAddonDB.barPosition end,
        onChanged = function(p) Mover.ApplyPosition(myBar, p) end,
    })
end
```

That gives your frame a mover. To finish the job, follow the
[Developer Guide](docs/DEVELOPER_GUIDE.md): it has a complete addon you can copy, and
explains what to do on login and when your frames move, which anchors depend on.

## Documentation

| Guide | For |
|---|---|
| [User Guide](docs/USER_GUIDE.md) | Using the editor, anchors, settings and fixing problems |
| [Developer Guide](docs/DEVELOPER_GUIDE.md) | Adding DandersMover to your addon, step by step |
| [API Reference](docs/API.md) | Every function, option, callback and rule |

## Open source and credit

DandersMover is open source under the [MIT licence](LICENSE). Use it, learn from it,
change it, and ship it in free or paid projects.

**Registering your frames** doesn't copy any of this code, so there's nothing you need
to do. A mention that you support DandersMover helps players find it, and that's
welcome.

**Copying or adapting the code**, in a fork or in your own mover, means keeping the
copyright and licence notice with it. That's the one condition the licence sets. Please
also credit the project somewhere people can see it, such as your README or addon page:

> Based on [DandersMover](https://github.com/DanderBot/DandersMover) by Danders.

The licence covers DandersMover and the DandersUI library embedded in it. It doesn't
cover the rest of DandersFrames. Bundled third-party parts keep their own terms, listed
at the bottom of the [LICENSE](LICENSE) file.

## Contributing

Bug reports, fixes and new ideas are all welcome, especially anything that helps more
addons join. Please open an issue or pull request on this repo.

Development happens inside the DandersFrames repo and is copied here automatically, so
an accepted pull request gets ported across rather than merged directly. The automated
tests also live there, under `Tools/mover-tests`.

### Forks

Improving this project helps every addon that uses it, so that's the best place for a
change. If you do fork it and change how it behaves, rename these before you release:

- The library name, `DandersMover-1.0`
- The addon folder and TOC
- `DandersMoverDB`
- The `/mover` command

Otherwise your copy and the original will fight to load, and other addons could end up
running a version they weren't written for.
