local addonName, DF = ...
DF.ADDON_VERSION = "v4.0.8-alpha.6"
DF.BUILD_DATE = "2026-02-26T17:01:52Z"
DF.RELEASE_CHANNEL = "alpha"
DF.CHANGELOG_TEXT = [===[
# DandersFrames Changelog

## [4.0.8] - 2026-02-26

### Auras
* **Buff deduplication** — buffs already displayed by the Defensive Bar or Aura Designer placed indicators are automatically hidden from the buff bar. Enabled by default, toggle in Buffs tab
* **Direct Aura API mode** — optional mode that queries C_UnitAuras directly with configurable filter strings (PLAYER, RAID, BIG_DEFENSIVE, etc.), giving full control over which auras appear. Configure in Auras > Aura Filters
* **Multi-defensive icons** — Defensive Bar now shows all active big defensives simultaneously (up to configured max), not just one
* **Defensive bar compound growth** — growth direction now supports two-axis layouts (e.g., RIGHT_DOWN, LEFT_UP) with configurable wrap count, matching the buff/debuff icon grid system
* **Important Spells filter** — Direct mode now has an "Important Spells" checkbox for both buffs and debuffs, using the 12.0.1 IMPORTANT aura filter
* Max buff and debuff icon count increased from 5 to 8

### Aura Designer
* **Buff coexistence** — standard buff icons can now display alongside Aura Designer indicators. When enabling AD a popup asks whether to keep or replace standard buffs, with info banners in both tabs for quick toggling
* **Health Bar Color tint mode rework** — uses a StatusBar overlay instead of color blending, fixing tint not working reliably with Blizzard's protected health values
* **Preview scale slider** — adjustable zoom (0.75×–2.5×) for the frame preview window, making it easier to place indicators on small frames like raid frames
* Aura Designer now refreshes when switching specs so per-spec aura lists update immediately

### Click Casting
* Binding tooltip moved to main Tooltip settings with full anchor and position controls
* Removed "Show Tooltips" toggle from click-cast panel (now in Tooltip settings)

### Bug Fixes
* Fix defensive icons and aura durations showing stale data after entering/exiting vehicles — aura cache is now invalidated on vehicle swaps
* Fix unit name getting stuck to the vehicle name after exiting a vehicle
* Fix Aura Designer bar indicators getting stuck in a corrupted visual state after the tracked aura expires
* Fix Direct Aura API only tracking one player's auras — RegisterUnitEvent in a loop silently dropped all but the last unit
* Fix animated border flickering in Aura Designer border mode
* Fix missing raid groups when reloading UI during combat — header visibility is now set up during the ADDON_LOADED grace window
* Fix permanent buff duration text showing on non-expiring auras — native countdown text now stays as child of cooldown frame for proper auto-hiding when auras shift
* Fix debuffs being hidden when Aura Designer is enabled — debuffs now always display regardless of AD state
* Fix Health Bar Color replace mode not reverting when the aura drops off
* Fix blend slider still showing when Health Bar Color mode is set to Replace
* Fix click-casting reload popup appearing on every login when the Clicked conflict warning is set to Ignore

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
