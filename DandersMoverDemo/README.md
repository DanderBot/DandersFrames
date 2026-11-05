# DandersMoverDemo

A dev-only test consumer for [DandersMover](../DandersMover/README.md). It is a
separate addon that pretends to be somebody else's: it registers six long-form
movable elements, one anchor target and a set of short-form elements through the
public `LibStub("DandersMover-1.0")` API and nothing else, so anything it can do
proves a third-party addon can do the same. It owns its own SavedVariables (`DandersMoverDemoDB`), never touches
DandersFrames, and loads harmlessly with DandersMover disabled — the frames
still appear at their saved coordinates, just without proxies or a panel. It is
excluded from both `.pkgmeta` files and never ships.

## Installing

Junction it into an AddOns folder alongside `DandersMover` (junctions need no
admin rights or Developer Mode):

```
mklink /J "<AddOns>\DandersMoverDemo" "<repo>\DandersMoverDemo"
```

A full client restart is needed the first time — `/reload` will not pick up a
new addon folder.

## Commands

`/mdemo show` · `hide` · `reset` · `unlock` · `status`

`status` prints each element's stored `point/x/y` and its anchor target, which
is the quickest way to confirm the library is writing back into the consumer's
own records rather than storing positions itself. These five only cover the six
long-form elements; `/mover reset dandersmoverdemoeasy` resets the Easy ones.

## The easy API (`Easy.lua`, library minor 9)

The six frames above stay long form to prove the old API still works. `Easy.lua`
adds frames that use only the short form: `db` + `dbKey`, no `getPos`, `onChanged`
or `secure`. With the library present it never places them itself, so a frame in
the right place means the library put it there. With DandersMover missing or older
than minor 9 it prints one line, registers nothing and places the frames from their
records. The new commands then only explain what they need.

| Frame | Addon key | What it is for |
|---|---|---|
| `leader`, top left | `DandersMoverDemoEasy` | The frame everything follows. The commands below move it directly |
| `follower` | `DandersMoverDemoEasy` | After `link`, sits under `leader`, with `backup` as its fallback |
| `backup` | `DandersMoverDemoEasy` | The fallback target |
| `easySecure` | `DandersMoverDemoEasy` | A real `SecureUnitButtonTemplate` button, detected as secure |
| `easyLate` | `DandersMoverDemoEasy` | Created and registered 3s after `PLAYER_LOGIN` |
| `easyLazy` | `DandersMoverDemoEasy` | `getFrame` answers nil until the frame is made, 5s after `PLAYER_LOGIN` |
| `manualLeader`, top right | `DandersMoverDemoManual` | `watch = false`, so nothing follows it without being told |
| `manualFollower` | `DandersMoverDemoManual` | After `link`, sits under `manualLeader` |

| Command | What it does |
|---|---|
| `/mdemo move` | Moves `leader` and `manualLeader` by a direct `SetPoint`, or back to their records. The records do not change |
| `/mdemo size` | Toggles `leader` and `manualLeader` between two sizes |
| `/mdemo scale` | Toggles `leader` between scale 1 and 1.3 |
| `/mdemo toggle` | Hides or shows `leader` and `manualLeader` |
| `/mdemo link` | Anchors `follower` to `leader` (fallback `backup`) and `manualFollower` to `manualLeader` |
| `/mdemo unlink` | Detaches both where they sit |
| `/mdemo stats` | Prints `GetWatcherStats` |
| `/mdemo stress [n]` | Registers n small frames (default 40, cap 200) in a chain from `leader`. Their records are not saved |
| `/mdemo stress off` | Unregisters them and hides them |
| `/mdemo selftest` | Runs the timed check below |

`link` is saved, like any record, until `unlink`. A `scale` change makes the watcher
re-apply `leader`, which puts it back at its record even after `move`: the record is
the truth, and `move` deliberately did not change it.

`selftest` takes about 6 seconds and prints PASS or FAIL per line, then a summary. It
refuses in combat or while the editor is unlocked, stops early if either starts, and
always puts back the records, sizes, scales, shown state and positions it touched. It
checks that:

- `follower` follows a move of `leader` by the same amount
- `follower` re-solves on the moved edge when `leader` resizes
- `follower` goes to `backup`'s seat when `leader` hides, and comes back when it shows
- `leader` stays centred on its record when its scale changes
- `manualFollower` does not move until `RefreshAnchorTarget` is called
- `easySecure` is protected
- `easyLate` and `easyLazy` exist and sit at their records
- the watcher is running

## In-game test checklist

1. Restart the client: `Easy.lua` is a new file, and `/reload` does not pick those up.
2. Wait a few seconds after login, then run `/mdemo selftest`. Every line should say PASS.
3. `/mdemo link`, then `/mover`, and drag `leader`. `follower` should stay under it, and
   stay there after you save. Then `/mover` to lock.
4. By eye, with the link still on:
   - `/mdemo move`: `follower` jumps after `leader` within a fraction of a second, and
     `manualFollower` stays behind.
   - Then bring `manualFollower` along by hand:
     `/run LibStub("DandersMover-1.0"):RefreshAnchorTarget("DandersMoverDemoManual", "manualLeader")`
   - `/mdemo toggle`: `follower` goes to `backup`. Toggle again and it comes back.
5. In-combat move of `easySecure`. Hit a training dummy, then in combat run:
   `/run LibStub("DandersMover-1.0"):SetAnchor("DandersMoverDemoEasy", "easySecure", { target = "DandersMoverDemoEasy:backup", edge = "right", align = "center" })`
   There should be no error and no movement until combat ends, when it jumps beside
   `backup`. Undo it with `/run LibStub("DandersMover-1.0"):Detach("DandersMoverDemoEasy", "easySecure")`
   and `/mover reset dandersmoverdemoeasy`.
6. `/mdemo stress 40`, wait a few seconds, then `/mdemo stats`. `lastMs` is the cost of
   one idle tick and `maxMs` the worst so far, at five ticks a second. `/mdemo move` shows
   a busy tick, and `/mdemo stress off` clears the frames.
7. Disable DandersMover and reload. The demo should still load with one line saying the
   section was skipped, and every frame should be at its saved spot.

## What it lets you check

- **Proxy icon from the consumer's logo** — `RegisterAddon` passes an `icon`, so
  every proxy should show this addon's orange diamond rather than the bundled
  DandersFrames fallback.
- **Inset `getRect`** — "Buff Row" reports a visible rect 10px tighter than the
  frame on all four sides. Its proxy, its snap zones and its drag maths should
  all follow the smaller rect, and the gap between record and rect must not
  drift as it is dragged.
- **`MIN_PROXY`** — "Tiny Badge" is 20x20, under the library's minimum proxy
  size, so its proxy has to grow past the frame it stands for and still drag,
  snap and nudge correctly.
- **Hidden frame proxies** — "Combat Only" is hidden out of combat. Unlocking
  should still expose it (the library never changes your frame's visibility),
  and it must not offer itself as a snap target while hidden. It also declares
  an `isRelevant` predicate; DandersMover 1.0 ignores the field, so that is
  documentation of intent rather than behaviour today.
- **Secure deferral** — `DandersMoverDemoSecure` is a real
  `SecureUnitButtonTemplate` button registered with `secure = true`. Entering
  combat mid-session should suspend the editor, and the position change should
  land after combat rather than throwing a protected-frame error.
- **Blizzard frame as an anchor target** — `minimap` registers `Minimap` as
  something to anchor to but not something to move.
- **Cross-addon anchoring** — with DandersFrames loaded, these elements and the
  DandersFrames party/raid frames should appear in each other's anchor target
  lists and snap to one another.
