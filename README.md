# DandersFrames

A party and raid frame addon for World of Warcraft: Midnight.

## Features

- Customizable party and raid frames
- Aura tracking and dispel indicators
- Private aura support
- Buff/debuff indicators with targeted spell tracking
- Range checking and highlight options
- Flat raid frame styling
- Pinned frames and flexible sorting (including secure sort)
- Import/export profile support
- Built-in test mode for configuration
- Minimap button via LibDBIcon

## Installation

1. Download the latest release from the [Releases](../../releases) page
2. Extract the `DandersFrames` folder into your `World of Warcraft/_retail_/Interface/AddOns/` directory
3. Restart WoW or type `/reload` in-game

## Contributing

Pull requests are welcome! If you'd like to contribute, please follow these steps:

1. Fork this repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Commit your changes (`git commit -m "Add my feature"`)
4. Push to your fork (`git push origin my-feature`)
5. Open a Pull Request with a clear description of your changes

Please test all changes thoroughly in-game before submitting.

All pull requests are reviewed at our discretion, and not all submissions will be merged. We appreciate every contribution, but we reserve the right to decline changes that don't align with the direction of the project. We encourage respectful and constructive collaboration, and we're grateful to everyone who takes the time to contribute.

## Libraries

This addon bundles the following third-party libraries, each under their own respective licenses:

- LibStub
- CallbackHandler-1.0
- AceSerializer-3.0
- LibDataBroker-1.1
- LibDBIcon-1.0
- LibDeflate
- LibSerialize
- LibSharedMedia-3.0

## Development setup

This repo is a **container**, not an addon folder. Its root holds the addon
folders side by side, the way ElvUI and Grid2 do:

```
<repo>/
  DandersFrames/            the addon
  DandersFrames_Options/    load-on-demand companion (settings, editors, debug)
  README.md  CHANGELOG.md  .pkgmeta  .github/  Tools/
```

WoW only loads addons from `Interface/AddOns/<Name>/<Name>.toc`, so the repo
cannot live inside `AddOns/` any more. Clone it anywhere and link the addon
folders in with **directory junctions** — junctions (`/J`), not symlinks
(`/D`), so no admin rights or Developer Mode are needed.

### One-time, per game install

From your `Interface/AddOns` folder, with WoW closed:

```
mklink /J "DandersFrames"         "C:\path\to\repo\DandersFrames"
mklink /J "DandersFrames_Options" "C:\path\to\repo\DandersFrames_Options"
```

Delete any real `AddOns/DandersFrames` folder first — a junction cannot
replace an existing directory. Repeat per install (`_retail_`, `_ptr_`).

After that, edit in the repo and `/reload` in game; the junction means there
is no copy or sync step. `git status`, branches and PRs are unchanged: one
repo, one branch, one PR, even for a change spanning both folders.

### Without the junctions

WoW loads whatever it finds. If only `DandersFrames` is linked you get the
frames but no settings panel; if neither is, the addon simply is not there.
Nothing silently half-works.

### Verification tooling

`docs/reorg-tools/` holds the checkers used during the restructure — TOC
completeness, load order, split-plumbing aliases, and the load-on-demand
boundary. They default to `<repo>/DandersFrames`, so they run with no
arguments from the repo root. `docs/` is gitignored; the tools are local.

## License

All rights reserved.
