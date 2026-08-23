local addonName, NS = ...

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
