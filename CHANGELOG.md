# DandersFrames Changelog

## [4.0.7] - 2026-02-16

### Bug Fixes
* Fix pet frames vanishing after reload — pet frame updates were skipped in header mode, so they were never shown after login or `/rl`
* Fix pet frame font crash on non-English clients
* Reduce redundant pet frame updates during startup (throttled from 6 calls to 1-2)
* Fix resource bar border not showing after login/reload — was calling non-existent function
* Fix heal absorb bar showing smaller than actual absorb amount — calculator was subtracting incoming heals from absorb value
* Replace pcall wrappers with nil checks in absorb/heal calculator hot paths for better performance
* Fix profile direction switch not applying — switching to a profile with a different grow direction now correctly reconfigures header orientation
* Fix name text truncation not applied to offline players — offline frames showed full names ignoring the truncation setting
* Fix summon icon permanently stuck on frames after M+ start or group leave — summon icons now refresh on roster and zone changes
* Fix icon alpha settings (role, leader, raid target, ready check) reverting to 100% after releasing the slider — appearance system was ignoring user-set alpha values
* Fix click-casting not working when clicking on aura/defensive icons — mouse click events were not propagating to the parent unit button
* Fix click-casting "Spell not learned" when queuing as different spec — macros now resolve the current spec's spell override instead of using the stored root spell name

### New Features
* Debug Console — persistent debug logging system with in-game viewer (`/df debug` to toggle, `/df console` to view). Logs persist across reloads with category filtering, severity levels, and clipboard export

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
