# DandersMoverDemo

A dev-only test consumer for [DandersMover](../DandersMover/README.md). It is a
separate addon that pretends to be somebody else's: it registers six movable
elements and one anchor target through the public `LibStub("DandersMover-1.0")`
API and nothing else, so anything it can do proves a third-party addon can do
the same. It owns its own SavedVariables (`DandersMoverDemoDB`), never touches
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
own records rather than storing positions itself.

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
