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

The easiest way is from **[CurseForge](https://www.curseforge.com/wow/addons/danders-mover)**,
or any addon manager that uses it. It also comes with
[DandersFrames](https://github.com/DanderBot/DandersFrames).

To install it by hand, DandersMover has to be its own addon, in this exact folder:

```
World of Warcraft\_retail_\Interface\AddOns\DandersMover
```

The folder must contain `DandersMover.toc` directly, and has to be named
`DandersMover`. GitHub's "Download ZIP" names it `DandersMover-main`, so rename it.

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
local DEFAULT_POS = { point = "CENTER", x = 0, y = -200 }

-- Places the frame when DandersMover isn't installed.
local pos = MyAddonDB.barPosition or DEFAULT_POS
myBar:SetPoint(pos.point, UIParent, "CENTER", pos.x, pos.y)

local Mover, version
if LibStub then Mover, version = LibStub("DandersMover-1.0", true) end
if Mover and version >= 9 then
    Mover:Register("MyAddon", "bar", {
        title   = "My Bar",
        frame   = myBar,
        default = DEFAULT_POS,
        db      = MyAddonDB,
        dbKey   = "barPosition",
    })
end
```

That's all it takes. DandersMover places your frame, gives it a mover, and watches it so
that anything anchored to it follows. The [Developer Guide](docs/DEVELOPER_GUIDE.md) has a
complete addon you can copy, and the options you might want next.

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
