# DandersFrames Changelog

## [4.0.6] - 2026-02-15

### Bug Fixes
* `/df resetgui` command now works — was referencing wrong frame variable, also shows the GUI after resetting
* Settings UI can now be dragged from the bottom banner in addition to the title bar
* Test mode frames now properly reset to global settings when exiting auto-profile editing

### New Features
* Auto-profiles now activate at runtime — raid frame settings automatically switch based on content type and raid size
* Chat notifications when auto-profiles activate or deactivate
* Combat-safe profile switching — queued during combat, applied when combat ends
* Sidebar onboarding hint when entering auto-profile edit mode — highlights that all settings tabs are editable
* Orange star indicators on sidebar tabs that contain overridden auto-profile settings (visible during edit mode and when a runtime profile is active)
* `/df overrides` command — prints all overridden settings grouped by tab to chat
* Hover over override count on auto-profile rows to see a tooltip with full override details per tab

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
