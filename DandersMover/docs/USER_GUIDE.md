# DandersMover User Guide

This guide is for players. If you're adding DandersMover to your own addon, see the
[Developer Guide](DEVELOPER_GUIDE.md).

## The basics

Type `/mover` to open the editor. It's called a session, and it stays open until you
close it. Each frame gets a **mover**: a dark slab sitting on top of it.

- **Drag** a mover to move its frame.
- **Click** a mover to select it and open its panel.
- **Save & Exit** keeps your changes.
- **Discard** puts the frames in the session back to how they were when you opened the
  editor.

The world and camera still work during a session, so you can keep moving around. Clicking
empty space reaches the game rather than clearing your selection. Use Esc for that.

### Commands

| Command | What it does |
|---|---|
| `/mover` | Open or close the editor |
| `/mover unlock` | Open the editor |
| `/mover lock` | Close the editor |
| `/mover config` | Open the settings window |
| `/mover reset <addon>` | Put one addon's frames back to their default positions |
| `/mover reset all` | Put every frame back to its default position |

`/mover reset` on its own lists the addons you can reset.

### The top strip

A strip along the top of the screen holds **Save & Exit**, **Discard**, **Undo**,
**Redo**, **Settings** and **Grid**, plus a **Show other addons' movers** checkbox. It can
fold away to a small tab if it's in your way.

### Reading the movers

- The coloured dot and left edge show the mover's role:
  - Blue: a free frame.
  - Purple: an anchored frame.
  - Green: a free frame that others are anchored to.
  - Purple with a green ring: an anchored frame that others are anchored to.
- A white outline means selected.
- A dim white outline means the mover's panel is pinned.
- The word `hidden` in place of the coordinates means the real frame isn't on screen.
- The coordinates match the panel's X and Y: the frame's position when free, its offsets
  when anchored.
- Selecting or hovering a mover shows its tether. Hovering shows the whole chain.

### Keyboard and mouse

| Input | What it does |
|---|---|
| Hold **Shift** while dragging | Move horizontally only |
| Hold **Ctrl** while dragging | Move vertically only |
| **Arrow keys** on a selected mover | Nudge by 1 |
| **Shift** + arrows | Nudge by 10 |
| **Ctrl** + arrows | Nudge by 100 |
| **Ctrl+Z** / **Ctrl+Y** | Undo / redo |
| Hold **Alt** when not dragging | Fade the editor out to see your UI underneath |
| **Esc** | Back out one step: cancels a link drag, then clears the selection, then closes the editor |

If you close the editor with unsaved changes, it asks whether to **Save**, **Discard**
or **Cancel**.

## Snapping

There are three kinds of snapping, and each can be turned off in **Settings > Snapping**:

- **Frames.** Frames show **snap zones** around them as you get close. Dropping into a zone
  anchors your frame there, so this is also how drop-anchoring works. Turn it off and
  dropping near a frame no longer anchors it.
- **Grid.** Lines up with the grid. It doesn't anchor anything.
- **Screen.** Lines up with the screen's edges and centre lines. It doesn't anchor anything,
  and it has a fixed short reach that **Snap distance** doesn't change.

Grid and screen snapping apply when you're not over a snap zone.

Hidden frames never offer snap zones. A seat that's already taken shows dimmer and won't
accept a drop.

## Anchoring

An anchored frame follows its target. Move the target and the anchored frame comes
with it, even if the two belong to different addons.

### Three ways to anchor a frame

**Drop it into a snap zone.** Drag it near another frame and let go in a highlighted
zone. This moves your frame to that seat.

**Pick a target in the panel.** The **Target** row lists everything the frame can anchor
to, grouped by addon. The frame stays where it is, and the offset is worked out for you.

Targets marked `(hidden)` aren't on screen right now, which is how you anchor to something
that only appears in a raid. If that target has no position yet, your frame stays put until
it first appears, then lands on its centre. Adjust the offset at that point.

**Drag the chain icon.** Hold the chain icon on the **Target** row and drag to another
mover that's on screen. The frame stays where it is. If targets overlap, the smallest one
under your cursor wins, so you can reach a frame inside a larger container. Esc,
right-click, or letting go over nothing cancels it.

### Detaching

Press **Detach** in the panel, or pull the frame well away from its target.

While you drag an anchored frame, a line called a **tether** connects it to its target:

- **Near its seat**, the anchor holds. Drop it outside a snap zone and it springs back.
- **Further away**, the tether turns red and thin as a warning. It still springs back.
- **Past the limit** of 4x the snap distance, the tether snaps and the frame is free. Undo
  brings it back. This also clears any backup, and a message tells you so.

### Edge and alignment, or exact points

An anchor normally says which **Edge** of the target to sit beside (top, bottom, left or
right) and how to **Align** along it (start, center or end).

Some anchors use **Point** and **Rel point** instead, which join one exact point of your
frame to one exact point of the target. There's no switch for this. The editor uses it when
you link a frame that overlaps its target or can't sit beside an edge, and addons can set it
from code.

### Backup anchors

The **Backup** row picks a second target, used when the main target isn't available. For
example, anchor to raid frames with party frames as the backup. Pick from the list or drag
the row's chain icon. It needs a main anchor first.

The order is main target, then backup, then staying in the last position. While a frame is on
its backup, the panel marks the target `(backup)` and the tether is thin and muted. Detaching
a frame also clears its backup.

The switch happens when the addon that owns the target reports the change, so how quickly a
frame moves over depends on that addon.

### Mirroring

The **Mirror** row keeps a frame symmetrical with its target. Turn on **Mirror X** and
when the target moves left, your frame moves right by the same amount. **Mirror Y** does
the same up and down.

The line they mirror across is set by **Mirror Position**, which is the X or Y box relabelled
on a mirrored axis. `0` is the middle of the screen. Turning a mirror on places the line
halfway between the two frames, so nothing jumps. Turning it off keeps the frame where it is.

Dragging the target moves the mirrored frame the opposite way. Dragging the mirrored frame
moves its target too if the target is a free frame in this session. Otherwise the mirrored
frame is held on that axis.

Backup anchors don't mirror.

## The panel

Selecting a mover opens its panel beside it. There's only one panel, and it follows your
selection. It holds:

- **X and Y** boxes and nudge arrows
- A 9-point picker for which point of the frame is being positioned, shown on free frames
  unless the addon sets that point itself
- The **Anchor** section: Target, Edge, Align or Point and Rel point, Mirror and Backup. On a
  free frame, the rows it can't use are greyed out
- **Center**, which moves the frame to the middle of the screen and also detaches it
- **Reset**, which restores the addon's default position
- **Detach**, which frees the frame where it sits
- **Copy to...**, on frames with a partner, such as party and raid frames. It copies the
  position and anchor, dropping any part that would make a loop
- **Configure**, on frames whose addon provides it, which opens that addon's settings
- An icon row with Undo, Redo, Save & Exit, Discard and Settings

### Pinning

Press the pin button to stop the panel following your selection. It stays where you put
it and keeps editing the same frame. Drag it by its title bar.

Starting to edit also pins it, for example clicking in an X/Y box or pressing a nudge
arrow. To turn that off, use **Settings > Editor > Auto-pin panels when editing**.

Selecting a different mover closes a pinned panel and opens a new one there, so there's never
more than one. The X on a following panel also clears your selection.

## Settings

Open them with `/mover config` or the **Settings** button.

### General

| Setting | What it does |
|---|---|
| Scale | Size of the strip, panel, settings window and mover text. Movers always match their frames |
| Panel side | Which side the panel opens on: Auto, Left or Right |
| Mover Opacity | How solid the movers' fill is. Lower it to see your frames underneath. Default 0.5 |

### Snapping

| Setting | What it does |
|---|---|
| Snap to grid | Snap to grid lines |
| Snap to frames | Show snap zones, and anchor when you drop in one |
| Snap to screen | Snap to the screen's edges and centre lines |
| Show grid | Draw the grid |
| Show distance measures | Show lines to the nearest screen edge while dragging. Off by default |
| Show grid snap lines | Show which grid line you snapped to. Off by default |
| Snap distance | How close a frame must be before a zone catches it, centre to centre. Default 25 |
| Show snap zones within | How far away zones start to appear. Default 50 |

### Grid

| Setting | What it does |
|---|---|
| Grid Size | Space between grid lines |
| Grid line thickness | Width of the grid lines |
| Dim background | Darken the game world during a session. On by default |
| Dim amount | How dark it gets. Default 0.4 |

### Editor

| Setting | What it does |
|---|---|
| Keyboard nudge | Arrow keys move the selected mover |
| Auto-pin panels when editing | Editing pins the panel |
| Show movers for hidden frames | Give hidden frames a mover too |
| Show other addons' movers | When an addon opens the editor for its own frames, show other addons' movers as well |

### Addons

Lists every addon that has registered frames. Turn a whole addon or a single frame off
here. A frame that's off gets no mover, and you can't newly anchor to it in the editor.
Anchors that already exist keep working.

## Where your positions are saved

Each addon saves its own frame positions. DandersMover only saves your editor settings
and the on/off toggles. So if you remove DandersMover, your addons keep their frames where
you left them, though anchored frames stop following their targets.

## Troubleshooting

**A frame went off screen.** Run `/mover reset <addon>`, or `/mover reset` to see the
names. During a session, frames in that session can be undone one at a time or discarded.
Anything else, including frames you've turned off, resets straight away.

**"Movers cannot be unlocked in combat."** Wait until combat ends. If combat starts during
a session, the editor pauses and returns afterwards.

**An addon's frames aren't there.** The addon has to support DandersMover. Check
**Settings > Addons** to see what's registered and whether it's turned off. Frames that
don't apply right now, such as raid frames while you're solo, can also be left out.

**A frame isn't following its target.** Its target may be hidden, in which case it stays
put until the target returns. Add a **Backup** if you'd like it to go somewhere else. If the
target is visible, its addon may not be reporting that it moved, which is one for that addon's
author.

**I can't anchor to a frame.** That would create a loop, such as anchoring a frame to
something already anchored to it. These targets aren't listed, and the editor refuses them.

**The addon doesn't appear at all.** Check the folder is named exactly `DandersMover`, and
restart the game fully. `/reload` doesn't pick up new addon folders.
