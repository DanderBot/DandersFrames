local addonName, DF = ...
DF.ADDON_VERSION = "v4.0.7-alpha.21"
DF.BUILD_DATE = "2026-02-22T22:35:19Z"
DF.RELEASE_CHANNEL = "alpha"
DF.CHANGELOG_TEXT = [===[
# DandersFrames Changelog

## Unreleased (v4.0.7-alpha.21)

- Update 4.0.7 changelog with merged PRs and AD combat fixes
- Fix ApplyBar: default matchFrameWidth to true when nil
- Fix ApplySquare falling back to global defaults for size and scale
- Match square size slider max (64) to icon slider max
- Fix ChangeInstanceType baking TYPE_DEFAULTS instead of falling through to globals
- Instance proxies fall through to global defaults for size/scale/duration/stacks
- Fix square default size to 24 (was 10 in TYPE_DEFAULTS)
- Refactor AD to instance-based placed indicators
- Fix double beta release and wrong release channel detection
- Add click-cast binding tooltip on unit frame hover
- feat(options): add health gradient color mode for missing health bar

---


## [4.0.7] - 2026-02-22

### Bug Fixes
* Fix health fade errors with secret numbers — rewritten to use curve-based engine-side resolution, no Lua comparison of protected values
* Fix health fade not working correctly on pet frames
* Fix health fade not working in test mode and not updating during health animation
* Fix health fade threshold slider causing lag during drag
* Fix profiles not persisting per character — each character now remembers their own active profile
* Fix pet frames vanishing after reload
* Fix pet frame font crash on non-English clients
* Fix party frame container not repositioning when dragging width or height sliders
* Fix profile direction switch not applying when switching profiles
* Fix resource bar border not showing after login/reload
* Fix resource bar showing white when first made visible
* Fix resource bar not matching frame width on resize and test mode
* Fix heal absorb bar showing smaller than actual absorb amount
* Fix absorb bar not fading when unit is out of range
* Fix name text truncation not applied to offline players
* Fix summon icon permanently stuck on frames after M+ start or group leave
* Fix icon alpha settings (role, leader, raid target, ready check) reverting to 100% after releasing slider
* Fix click-casting not working when clicking on aura/defensive icons
* Fix click-casting "Spell not learned" when queuing as different spec
* Fix DF click-casting not working until reload when first enabled
* Fix Clique compatibility — prevent duplicate registration, defer writes, commit all header children
* Fix aura click-through not updating safely on login
* Fix leader icon not updating on first leader change (contributed by riyuk)
* Fix forbidden table iteration in FindHealthManaBars (contributed by riyuk)
* Fix forbidden table iteration in click-casting Blizzard frame registration (contributed by riyuk)
* Fix double beta release and wrong release channel detection in CI (contributed by riyuk)
* Fix Aura Designer indicators not displaying in combat — switched to Duration object pipeline for secret value compatibility
* Fix Aura Designer bar duration text and expiring color flicker in combat
* Various auto layout stability fixes
* Fix auto layout settings contamination between party and raid modes
* Fix auto layout override values getting stuck on test mode frames after profile switch

### New Features
* Add health fade system — fades frames when a unit's health is above a configurable threshold, with dispel cancel override and test mode support (contributed by X-Steeve)
* Add class power pips — displays class-specific resources (Holy Power, Chi, Combo Points, etc.) on the player's frame as colored pips with configurable size, position, and anchor (contributed by X-Steeve)
* Add class power pip color, vertical layout, and role filter options
* Add "Sync with Raid/Party" toggle per settings page (contributed by Enf0)
* Add per-class resource bar filter toggles
* Add click-cast binding tooltip on unit frame hover — shows active bindings with usability status (contributed by riyuk)
* Add health gradient color mode for missing health bar, with collapsible Health Bar / Missing Health sections (contributed by Enf0)
* Auto-reload UI when toggling click-casting enable/disable
* Auto-show changelog when opening settings after an update
* Rename "Auto Profiles" to "Auto Layouts" throughout the UI
* Debug Console — in-game debug log viewer (`/df debug` to toggle, `/df console` to view)
* Aura Designer — icon, square, and bar indicators with instance-based placement; drag to place, toggle type per-instance, global defaults inheritance

## [4.0.6] - 2026-02-15

### Bug Fixes
* `/df resetgui` command now works — was referencing wrong frame variable, also shows the GUI after resetting
* Settings UI can now be dragged from the bottom banner in addition to the title bar
* Fix party frame mover (blue rectangle) showing wrong size after switching between profiles with different orientations or frame dimensions
* Fix Wago UI pack imports overwriting previous profiles — importing multiple profiles sequentially no longer corrupts the first imported profile
* Fix error when duplicating a profile

## [4.0.5] - 2026-02-14

### Bug Fixes
* Raid frames misaligned / anchoring broken
* Groups per row setting not working in live raids
* Arena/BG frames showing wrong layout after reload
* Arena health bars not updating after reload
* Leader change causes frames to disappear or misalign
* Menu bind ignores out-of-combat setting
* Boss aura font size defaulting to 200% instead of 100%
* Click casting profiles don't switch on spec change
* Clique not working on pet frames
* Absorb overlay doesn't fade when out of range
* Heal absorb and heal prediction bars don't fade when out of range
* Defensive icon flashes at wrong opacity when appearing
* Name text stays full opacity on out-of-range players
* Health text and status text stay full opacity on out-of-range players
* Name alpha resets after exiting test mode
* Glowy hand cursor after failed click cast spells
* Macro editing window gets stuck open when reopened
* Flat raid unlock mover sized incorrectly
* Fonts broken on non-English client languages

### New Features
* Click casting spec default profile option
* Group visibility options now available in flat raid mode
* Slider edit boxes accept precise decimal values for fine-tuned positioning and scaling
]===]
