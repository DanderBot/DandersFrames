# DandersFrames Changelog

## [4.0.8] - 2026-02-24

### New: Aura Designer
Visual indicator system for tracking buffs, debuffs, and auras on your frames. Requires the Harrek's Advanced Raid Frames (HARF) companion addon.
* **8 indicator types** — 3 placed indicators (Icon, Square, Bar) that occupy anchor points on the frame, plus 5 frame effects (Border, Health Bar Color, Name Text Color, Health Text Color, Frame Alpha) that affect the entire frame
* **Drag-to-place** — drag auras from the spell list onto any of 9 anchor points (corners, edges, center) with X/Y offset adjustment
* **Icon indicators** — spell icon with cooldown swipe, duration text, and stack count display
* **Square indicators** — colored square with cooldown swipe, duration text, and stack count
* **Bar indicators** — progress bar showing remaining duration with horizontal/vertical orientation, match-frame-width option, fill color, background color, and bar-color-by-time gradient
* **Border frame effect** — 5 styles: Solid, Animated, Dashed, Glow, and Corners Only with configurable thickness and color
* **Health Bar Color frame effect** — Replace or Tint mode with adjustable blend strength
* **Name/Health Text Color frame effects** — override unit name or health text color when an aura is active
* **Frame Alpha frame effect** — adjust entire frame transparency based on aura presence
* **Expiring system** — all 8 indicator types support an expiring color that activates below a configurable remaining-duration threshold, fully combat-safe using Blizzard's Duration object API
* **Priority stacking** — configurable priority per aura (1-20); frame effects only show the highest-priority active aura, placed indicators coexist on separate anchors
* **Global defaults** — configure default icon size, scale, duration/stack font, font scale, and outline style; new indicators inherit these automatically with per-indicator overrides available
* **Live preview** — indicators render on the frame preview in the options panel with mock aura data
* **Per-spec aura lists** — curated aura lists for 8 healer and augmentation specs
* **Not-installed overlay** — setup instructions with CurseForge and Discord links when HARF is missing

### New: Auto Layouts (Raid Only)
Automatically switches your raid frame layout based on content type and raid size. Does not apply to party, solo, or arena.
* **Three content categories** — Instanced/PvP (raids, dungeons, battlegrounds), Mythic (fixed 20-player), and Open World (world bosses, outdoor groups)
* **Per-size-range profiles** — create multiple layouts per content type, each covering a custom player range (e.g., 1-10, 11-20, 21-40). Mythic is a single fixed layout for 20 players
* **Automatic switching** — monitors group roster, zone changes, and instance type; applies the matching layout on-the-fly when content or raid size changes
* **Override-only storage** — each layout stores only the settings that differ from your global profile; everything else is inherited automatically
* **Full settings coverage** — overrides can include frame size, growth direction, groups per row, group visibility, bar colors, text settings, aura filters, icon toggles, pinned frame configuration, and more
* **Live editing** — click "Edit Settings" to enter editing mode with live frame preview; every change is tracked as an override with visual indicators showing which settings are modified vs global
* **Override indicators** — green checkmark for global values, orange star with reset button for modified values, per-tab override counts
* **Non-destructive** — uses a read-through overlay system so your global profile is never mutated; exiting editing mode restores your base settings cleanly
* **Crash recovery** — if editing is interrupted, the next login detects and restores your base settings
* **Status display** — shows current content type, instance name, raid size, active layout, and override count
* **Export/import support** — auto layout configurations included in profile exports

### New Features
* Health fade system — fades frames above a configurable health threshold, with dispel cancel override (contributed by X-Steeve)
* Class power pips — Holy Power, Chi, Combo Points, etc. displayed on the player frame as colored pips with configurable size, position, and anchor (contributed by X-Steeve)
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
