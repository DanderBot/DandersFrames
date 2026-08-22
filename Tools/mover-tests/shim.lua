-- Headless shim: just enough WoW globals for Undo/Solver/Registry.
geterrorhandler = geterrorhandler or function() return function(err) print("ERROR: " .. tostring(err)) end end
securecallfunction = securecallfunction or function(f, ...) return f(...) end
InCombatLockdown = InCombatLockdown or function() return false end
wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
strsplit = strsplit or function(sep, s) local out = {} for piece in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = piece end return unpack(out) end

-- Fake frames: enough for Registry:GetRect.
function FakeFrame(cx, cy, w, h, scale)
    local f = { _cx = cx, _cy = cy, _w = w, _h = h, _scale = scale or 1, _shown = true }
    function f:GetCenter() return self._cx, self._cy end
    function f:GetSize() return self._w, self._h end
    function f:GetWidth() return self._w end
    function f:GetHeight() return self._h end
    function f:GetEffectiveScale() return self._scale end
    function f:GetScale() return self._scale end
    function f:IsShown() return self._shown end
    function f:IsProtected() return false end
    return f
end
UIParent = FakeFrame(960, 540, 1920, 1080, 1)

-- Test harness
T = { pass = 0, fail = 0 }
function check(cond, msg)
    if cond then T.pass = T.pass + 1 else T.fail = T.fail + 1; print("  FAIL: " .. tostring(msg)) end
end
function eq(a, b, msg)
    local ok = a == b or (type(a) == "number" and type(b) == "number" and math.abs(a - b) < 1e-6)
    if not ok then msg = (msg or "") .. string.format(" (got %s, want %s)", tostring(a), tostring(b)) end
    check(ok, msg)
end
