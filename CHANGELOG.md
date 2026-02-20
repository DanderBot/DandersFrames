# DandersFrames Changelog

## [4.0.7] - 2026-02-18

### Improvements
* Refactor auto layout runtime overrides to use a read-through overlay proxy — overrides are now applied transparently at read time instead of mutating the saved raid settings table, eliminating profile contamination on logout/reload and removing the strip/reapply save dance

### Bug Fixes
* Fix party frame container not repositioning when dragging the frame width or height slider — lightweight size update now re-applies header settings during drag
* Fix auto layout override editing contaminating the global profile — snapshot/restore now uses recursive deep copy to prevent shared nested table references
* Fix extra row spacing when editing auto layout overrides — slider drags now trigger full test frame layout refresh
* Fix auto layout edit button available on non-active profiles — greyed out with tooltip explaining only the active layout can be edited
* Fix auto layout override count showing +1 — unmapped keys no longer inflate the badge count
* Fix raidTestFrameCount not trackable as a profile override — added to OVERRIDE_TAB_MAP under Frame tab
* Fix auto layout override values not showing on test mode frames — entering edit mode now refreshes test frames after applying overrides
* Fix profiles not persisting per character — currentProfile is now stored in per-character saved variables so each character remembers their own profile
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
* Fix absorb bar not fading when unit is out of range — health event updates were overwriting the OOR alpha on every tick
* Fix pet health fade crash from secret number arithmetic — pet health APIs return opaque values that can't be compared directly
* Fix health fade not working in test mode — setting keys were mismatched between Config defaults and TestMode references
* Fix health fade threshold slider causing lag during drag — callback parameters were in the wrong position
* Fix health fade not updating during test mode animate health — animation ticker now re-evaluates the fade threshold
* Fix leader icon not updating on first leader change (contributed by riyuk)
* Fix forbidden table iteration in FindHealthManaBars (contributed by riyuk)
* Fix resource bar showing white when first made visible — color was not initialized before the first show
* Fix resource bar not matching frame width on resize and test mode — width now updates in both live and test frame paths
* Fix Clique compatibility — prevent duplicate ClickCastFrames registration, defer writes until after metatable is ready, and commit all header children instead of only unit-matched frames
* Fix DF click-casting not working until reload when first enabled — bindings are now applied immediately on enable without requiring `/rl`
* Fix aura click-through not updating safely on login — moved UpdateAuraClickThrough to ADDON_LOADED to avoid combat lockdown issues

### New Features
* Add "Sync with Raid/Party" toggle per settings page — keeps party and raid settings in sync automatically when enabled, with per-profile persistence (contributed by Enf0)
* Add health fade system — fades frames or individual elements when a unit's health is above a configurable threshold, with per-element alpha controls, dispel cancel override, and test mode support (contributed by X-Steeve)
* Add class power pips — displays class-specific resources (Holy Power, Chi, Combo Points, Soul Shards, Arcane Charges, Essence) on the player's party/raid frame as colored pips with configurable size, position, and anchor (contributed by X-Steeve)
* Add class power pip color options — custom foreground color toggle and background color picker with alpha
* Add vertical pip layout — LEFT/RIGHT anchor positions stack pips along the frame side
* Add class power role filter — checkboxes to show pips only for tank, healer, or DPS roles
* Add class power test mode multi-frame support — all relevant class test frames now show partially filled pips for preview
* Auto-show changelog when opening settings for the first time after an update
* Rename "Auto Profiles" to "Auto Layouts" throughout the settings UI
* Add per-class resource bar filter toggles — show or hide the resource bar based on class
* Auto-reload UI when toggling click-casting enable/disable — prompts for reload so bindings take effect immediately
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
