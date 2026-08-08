local addonName, DF = ...
DF.BUILD_DATE = "2026-08-08T21:07:14Z"
DF.RELEASE_CHANNEL = "alpha"
-- The changelog text itself lives in DandersFrames_Options/Changelog.lua:
-- it is a ~180 KB string only the settings panel ever reads, and holding it
-- resident cost every player that memory forever. Both files are GENERATED
-- by generate_changelog.sh -- edit CHANGELOG.md, not either output.
