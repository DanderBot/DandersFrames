# DandersFrames Changelog

## [4.0.8] - 2026-02-24

### Bug Fixes
* Fix click-casting "script ran too long" error when many frames are registered (ElvUI, etc.) — batch all frames in groups of 10 with yields between batches
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
* Fix Aura Designer health bar color tint mode not working — blend value was divided by 100 twice
* Fix Aura Designer health bar color not reverting to original when aura expires
* Fix Aura Designer health bar color flickering on health updates and form shifts
* Fix Aura Designer square indicator not inheriting global icon size defaults
* Fix Aura Designer square/bar color settings not saving across reloads (proxy copy-on-read for table defaults)
* Fix Aura Designer placed indicators becoming non-interactive after changing settings like size or scale
* Fix Aura Designer anchor dots consuming right-clicks intended for indicator deletion
* Fix Aura Designer not-installed overlay not showing when HARF is installed but disabled
* Fix Aura Designer URL copy popup error (use existing GUI popup system)
* Fix Harrek's logo not rendering (convert from non-power-of-2 PNG to 64x64 TGA)
* Fix Aura Designer expiring indicator errors — EvaluateRemainingPercent returns plain tables, not Color objects; all callbacks now use field access
* Fix "Apply to All" global fonts not reaching Aura Designer indicators — per-instance font overrides blocked global defaults inheritance
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
* Aura Designer border indicator now supports all highlight styles — Solid Border, Animated Border, Dashed Border, Glow, and Corners Only
* Aura Designer border and health bar color indicators render live in the options preview
* Aura Designer placed indicators can now be picked up and dragged to a different anchor point
* Aura Designer not-installed overlay with Harrek's logo, description, and CurseForge/Discord links
* Aura Designer attribution row shows Harrek's logo and orange-branded addon name
* Aura Designer global font settings now cascade to all indicator duration and stack text (icon, square, bar)
* "Apply to All" in Global Fonts page now updates Aura Designer defaults and clears per-instance font overrides
* Added Font Settings section to Aura Designer Global Defaults panel (duration/stack font, scale, outline)

### Improvements
* Replace all font-based Unicode icons with TGA textures (gear, checkmarks, close buttons, chevrons, dropdown arrows)
* Anchor dots only visible during drag operations for cleaner UI
* Aura Designer font dropdowns now use searchable font picker with font preview text
* Aura Designer global defaults changes now trigger full indicator refresh for immediate visual feedback

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
