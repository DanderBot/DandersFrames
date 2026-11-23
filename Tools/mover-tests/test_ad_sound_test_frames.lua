local NS = ...

-- ============================================================
-- AURA DESIGNER SOUNDS: NEVER ARMED FROM A TEST FRAME
-- reconcileSoundNow registered sound alerts for any frame with a unit, test
-- frames included. A test frame shows sample auras under a real unit token, so
-- clearing its Aura Designer (ClearFrame ends in reconcileSoundNow) could arm real
-- alerts on that unit. The register branch now skips test and preview frames.
-- ============================================================

local function norm(s) return (s:gsub("\r\n", "\n")) end
local SRC = norm(df_file_source("AuraDesigner/Factory.lua"))
local a = SRC:find("\nlocal function reconcileSoundNow%(frame%)")
local b = a and SRC:find("\nend\n", a, true)
check(a ~= nil and b ~= nil, "found reconcileSoundNow")
if not (a and b) then return end
local body = SRC:sub(a, b)
check(body:find("if enabled and owns and frame.unit and not frame.dfIsTestFrame and not frame.dfPreview then", 1, true) ~= nil,
      "the register branch skips test frames and preview frames")
local _, gates = body:gsub("if enabled and owns and frame%.unit", "")
eq(gates, 1, "...and it is the only register branch")
