# DandersFrames Changelog

## [4.0.8] - 2026-02-24

### New: Aura Designer
Visual indicator system for tracking buffs, debuffs, and auras on your frames. Requires the Harrek's Aura and Raid Filter (HARF) companion addon.
* Five indicator types — Icon, Square, Bar, Border, and Health Bar Color
* Drag-to-place workflow — drag auras onto frame anchor points to position indicators visually
* Border indicator supports all highlight styles — Solid, Animated, Dashed, Glow, and Corners Only
* Expiring color system — highlights auras about to expire with a configurable time threshold
* Global defaults with per-indicator overrides for fonts, size, scale, and colors
* "Apply to All" in Global Fonts cascades to all indicator duration and stack text
* Searchable font picker with live preview
* Indicators render live in the options preview
* Not-installed overlay with setup instructions when HARF is missing

### New: Auto Layouts
Automatically switches your raid frame profile based on content type and group size.
* Per-content profiles — configure different layouts for instanced raids, Mythic raids (fixed 20), and open world
* Automatic switching — frames update when you join a raid or change content type
* Edit overrides — tweak settings while in a specific content type without affecting your base profile
* Independent party and raid settings — no contamination between modes

### New Features
* Health fade system — fades frames above a configurable health threshold, with dispel cancel override (contributed by X-Steeve)
* Class power pips — Holy Power, Chi, Combo Points, etc. displayed as colored pips with configurable size, position, and anchor (contributed by X-Steeve)
* Class power pip color, vertical layout, and role filter options
* "Sync with Raid/Party" toggle per settings page (contributed by Enf0)
* Per-class resource bar filter toggles
* Click-cast binding tooltip on unit frame hover — shows active bindings with usability status (contributed by riyuk)
* Health gradient color mode for missing health bar (contributed by Enf0)
* Debug Console — in-game debug log viewer (`/df debug` to toggle, `/df console` to view)
* Auto-reload UI when toggling click-casting enable/disable
* Auto-show changelog when opening settings after an update

### Bug Fixes
* Fix click-casting "script ran too long" error when many frames are registered (ElvUI, etc.)
* Fix health fade errors with secret numbers — rewritten to use curve-based engine-side resolution
* Fix health fade not working correctly on pet frames, in test mode, and during health animation
* Fix profiles not persisting per character — each character now remembers their own active profile
* Fix pet frames vanishing after reload
* Fix pet frame font crash on non-English clients
* Fix party frame container not repositioning when dragging width or height sliders
* Fix resource bar border, color, and width issues after login/reload/resize
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
* Fix forbidden table iteration in FindHealthManaBars and click-casting registration (contributed by riyuk)
* Fix double beta release and wrong release channel detection in CI (contributed by riyuk)

### Improvements
* Replace all font-based Unicode icons with TGA textures (gear, checkmarks, close buttons, chevrons, dropdown arrows)

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
