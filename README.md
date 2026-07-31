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
folder rather than being it, the way ElvUI and Grid2 are laid out:

```
<repo>/
  DandersFrames/            the addon
  README.md  CHANGELOG.md  .pkgmeta  .github/  Tools/
```

WoW only loads addons from `Interface/AddOns/<Name>/<Name>.toc`, so the repo
cannot live inside `AddOns/` any more. Clone it anywhere and link the addon
folder in with a **directory junction** — a junction (`/J`), not a symlink
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
is no copy or sync step. `git status`, branches and PRs are unchanged — one
repo, one branch, one PR.

### Why a container, rather than one addon folder

`DandersFrames_Options` is a load-on-demand companion holding the settings
panel, both designers, the click-casting UI, test mode and the debug tools —
30 files, about a third of the code. WoW resolves `LoadAddOn("Name")` to
`AddOns/Name/Name.toc`, so a companion has to be a top-level addon folder — a
sibling of `DandersFrames`, not a subfolder. That is only possible if the repo
root is a container, hence this layout.

Measured on the PTR build: with that payload not loaded, DandersFrames uses
**8,957 KB instead of 12,348 KB — 3,391 KB less, 27.5%** — and ~55,000 lines
are never parsed at login. The saving lasts until the settings panel is
opened; the login cost is avoided every time.

Users do none of this: the packager ships the two folders as siblings in the
zip, and `.pkgmeta` maps them. The junctions exist only because there is no
packager running locally.

**Nothing may depend on the companion to work.** Live behaviour that happened
to live in a settings file has to move back to the main addon, not be guarded
away — the auto-profile engine, the click-casting bootstrap and the aura
migrations are all resident for that reason. `docs/reorg-tools/lod_login_check.py`
catches the common form of this.

### Verification tooling

`docs/reorg-tools/` holds the checkers used during the restructure — TOC
completeness, load order, split-plumbing aliases, and the load-on-demand
boundary. They default to `<repo>/DandersFrames`, so they run with no
arguments from the repo root. `docs/` is gitignored; the tools are local.

## License

All rights reserved.
