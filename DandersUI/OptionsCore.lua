local addonName, NS = ...

-- ============================================================
-- DANDERSUI-1.0 -- OPTIONS MANIFEST HEAD
-- The first file of DandersUI_Options.xml, the load-on-demand half of the pack.
-- It does for that manifest exactly what Core.lua does for DandersUI.xml: it
-- installs the `NS.__DandersUI` handshake every file after it reads.
--
-- ☠ THIS FILE MAY LOAD IN AN ADDON THAT NEVER LOADED Core.lua. The options half
-- normally rides a SEPARATE, load-on-demand addon from the one carrying the base
-- half, so `NS` here is that companion's private table and the handshake Core.lua
-- set lives in a different one. So the base library is resolved through LibStub
-- -- the one place both halves can meet -- and only falls back to `NS.__DandersUI`
-- for the case where both manifests happen to load in the SAME addon.
--
-- ☠ ON FAILURE IT MUST NOT SET THE HANDSHAKE. Every later file in this manifest
-- opens with `local UI = NS.__DandersUI; if not UI then return end`, so leaving
-- the key unset is what turns the whole manifest inert after one visible error
-- instead of throwing a fresh Lua error per file.
--
-- ☠ MEDIA IS NOT TOUCHED HERE. UI.MEDIA points inside whichever addon carries
-- the BASE copy; deriving it from this addon's `addonName` would send every
-- texture lookup at a folder the options companion does not ship.
--
-- Canonical source lives at <repo>/DandersUI; never edit the copies under
-- */Libs/.
-- ============================================================

-- ☠ MUST match MINOR in Core.lua. Bumping one without the other disables the
-- options half at the next login -- see the README's split-loading section.
local EXPECTED_MINOR = 14

-- `true` on the LibStub call: a missing library is a case handled below, not an
-- error to throw at the user.
local UI = NS.__DandersUI or (LibStub and LibStub("DandersUI-1.0", true))

-- Raw print, not UI:Print: there is no library to print through, and the user
-- needs to see WHY their settings panel came up empty. One line, once.
if not UI then
    print("|cffff4040DandersUI_Options:|r base DandersUI library not found -- options UI disabled. Reinstall the addon.")
    return
end

-- A copy of the base half from an older (or newer) addon won the LibStub race.
-- The surfaces this manifest builds on may not exist, or may have changed shape,
-- so refuse rather than error halfway through a page build. The handshake is
-- CLEARED, not just left alone: a pre-set key (both manifests in one addon, but
-- with mixed-version files -- a broken install) would otherwise keep the later
-- files in THIS manifest running against the mismatched base. The resident
-- manifest's files read the key at their own load time, which has already
-- passed, so clearing it here only inerts the options half.
if UI.MINOR ~= EXPECTED_MINOR then
    print(("|cffff4040DandersUI_Options:|r version mismatch -- base DandersUI is minor %s but this options module expects minor %s. Update all addons that embed DandersUI.")
        :format(tostring(UI.MINOR), tostring(EXPECTED_MINOR)))
    NS.__DandersUI = nil
    return
end

NS.__DandersUI = UI
