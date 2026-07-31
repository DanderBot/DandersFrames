local addonName, DF = ...

-- ============================================================
-- TEXT DESIGNER - MODULE ENTRY
-- Feature for designing arbitrary text elements on unit frames.
-- See docs/superpowers/specs/2026-05-22-text-designer-phase1-design.md
-- ============================================================

local pairs, ipairs = pairs, ipairs

DF.TextDesigner = DF.TextDesigner or {}

-- ============================================================
-- DB STUB INITIALIZATION
-- Phase 1 only needs enough schema to track editor state.
-- Full per-element schema firms up in Phase 2 when rendering wires up.
-- ============================================================

function DF.TextDesigner:EnsureDB(db)
    if not db then return end
    db.textDesigner = db.textDesigner or {}
    db.textDesigner.enabled = db.textDesigner.enabled
    if db.textDesigner.enabled == nil then db.textDesigner.enabled = false end
    -- Live-testing toggle: when ON, the built-in name / health / status text
    -- widgets are hidden on every unit frame so Phase C live TD rendering can
    -- be tested without visual overlap. Defaults OFF — existing user settings
    -- govern when the toggle is off.
    if db.textDesigner.hideLegacyText == nil then db.textDesigner.hideLegacyText = false end
    db.textDesigner.nextElementID = db.textDesigner.nextElementID or 1
    db.textDesigner.elements = db.textDesigner.elements or {}
    db.textDesigner.previewScale = db.textDesigner.previewScale or 1.0
    db.textDesigner.globalDefaults = db.textDesigner.globalDefaults or {
        font = "DF Roboto SemiBold",
        fontSize = 10,
        color = {r = 1, g = 1, b = 1, a = 1},
        outline = "SHADOW;NONE",
        useClassColor = false,
    }
    return db.textDesigner
end

DF:Debug("TD", "TextDesigner module loaded (channel=%s)", tostring(DF.RELEASE_CHANNEL))
