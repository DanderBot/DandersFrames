local addonName, NS = ...
-- A copy that lost the LibStub race (a renamed duplicate install) must go
-- fully inert: Core.lua only sets NS.Lib on the winning copy.
if not NS.Lib then return end

-- ============================================================
-- FX ALIAS
-- The fade/pop helpers were promoted into DandersUI (UI.Fx, DandersUI/Fx.lua)
-- so every host addon can use them; the mover's files keep reaching them as
-- NS.Fx. NS.UI is the host taken in Core.lua. The headless tests run without
-- a host, so run.py preloads DandersUI/Fx.lua onto NS.__DandersUI and this
-- falls through to that copy.
-- ============================================================
local UI = NS.UI or NS.__DandersUI
NS.Fx = (UI and UI.Fx) or NS.Fx
