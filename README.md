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

This repo is a **container**, not an addon folder. Its root holds two addon
folders rather than being one:

```
<repo>/
  DandersFrames/            the addon (always loaded)
  DandersFrames_Options/    settings panel, designers, debug tools
                            (## LoadOnDemand — loads when /df is opened)
  README.md  CHANGELOG.md  .pkgmeta  .github/  Tools/  docs/
```

WoW only loads addons from `Interface/AddOns/<Name>/<Name>.toc`, so the repo
cannot live inside `AddOns/` any more, and a load-on-demand companion has to be
a **sibling** top-level folder rather than a subfolder. Clone the repo anywhere
and link **both** folders in with **directory junctions** — junctions (`/J`),
not symlinks (`/D`), so no admin rights or Developer Mode are needed.

### One-time, per game install

From your `Interface/AddOns` folder, with WoW closed:

```
mklink /J "DandersFrames"         "C:\path\to\repo\DandersFrames"
mklink /J "DandersFrames_Options" "C:\path\to\repo\DandersFrames_Options"
```

A junction cannot replace an existing directory, so anything already at those
names has to go first. Repeat per game install — `_retail_`, `_ptr_`, `_beta_`
— so six junctions if you run all three.

> ### ☠ Removing an existing `AddOns/DandersFrames` — read this
>
> If you already develop DandersFrames, that path is **probably a junction, not
> a folder**, and `rm -rf` in Git Bash *follows it* and deletes your working
> tree on the other side. Losing an unpushed branch to a cleanup step is a
> miserable way to start.
>
> Check what it is, then remove it as a link:
>
> ```
> cmd //c dir /AL "DandersFrames"     # lists it if it is a junction
> cmd //c rmdir "DandersFrames"       # removes the LINK, never the target
> ```
>
> `rmdir` refuses to touch a non-empty real directory, so it fails safe either
> way. Only reach for a recursive delete once you have confirmed it is a real
> folder you actually want gone.

**If `/df` does not open after this**, the usual cause is only the first
junction existing — the panel lives in `DandersFrames_Options`, so the addon
loads fine and the settings command does nothing useful. Note also that a new
addon folder is only picked up on a **full client restart**, not `/reload`.

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
migrations are all resident for that reason.

The rule in practice, when adding anything:

| Kind | Do |
|---|---|
| Deliberate user action (`/df test`, unlock, profiler, selective import/export) | **Load** the companion — `DF:EnsureOptionsLoaded()` |
| Background event (a talent-change UI refresh) | **Guard** and no-op — a refresh with no UI is correctly nothing |
| Live behaviour | **Keep it resident** |

☠ A companion file's `...` is the *companion's* addon table, not ours. Every
file there binds `local DF = DandersFrames` — the global published at
`DandersFrames/Core.lua:9`, **not** by `## AllowAddOnTableAccess`, which
governs private-table access and is unrelated to the global name.

### Verification tooling

A set of checkers was written during the restructure — TOC completeness, load
order, split-plumbing aliases, the load-on-demand boundary, and login-time work
stranded in the companion. Two are worth running after anything that moves code
between files: the alias checker (this caught two in-game crashes) and the
boundary checker (which watches the `DF`, `GUI` and `CC` namespaces separately,
because one that watches a single namespace is blind to the others).

⚠ These live under `docs/reorg-tools/`, which is **gitignored and not part of
this repo** — ask Krathe for a copy. Most of `docs/` is local; the one tracked
exception is `docs/gui-conventions.md`. Some in-code comments cite
`docs/reorg-tools/splits.manifest` for the same reason.

## License

All rights reserved.
