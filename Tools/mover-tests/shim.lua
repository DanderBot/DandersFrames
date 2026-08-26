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
    -- Edge readers: the panel's "nothing fits on screen" fallback measures
    -- UIParent's right edge, and UIParent is one of these.
    function f:GetLeft() return self._cx - self._w / 2 end
    function f:GetRight() return self._cx + self._w / 2 end
    function f:GetBottom() return self._cy - self._h / 2 end
    function f:GetTop() return self._cy + self._h / 2 end
    return f
end
UIParent = FakeFrame(960, 540, 1920, 1080, 1)

-- ============================================================
-- FAKE UI FRAMES
-- The richer stub: FakeFrame above is a geometry-only rect (all Registry:GetRect
-- ever wanted), while a UI-facing module builds chrome -- textures, lines, drag
-- handlers -- and the tests have to READ BACK what it built. Everything a test
-- asserts on is recorded on the stub; everything else falls through the __index
-- fallback as a no-op, so a module may call any frame method it likes without
-- the stub having to grow a body for it.
--
-- Shared here rather than in one test file because two suites now want it
-- (test_panel/test_proxy keep their own older locals deliberately -- rewriting
-- them onto this would churn ~800 lines of green tests for no behaviour).
--
-- ⚠ The fx* fields are PLAIN FALSE, not absent: Fx reads them as booleans, and
-- the __index fallback would otherwise hand back a (truthy) function for
-- `target.fxIn` and Fx.Cancel would try to :Stop() it.
-- ============================================================

-- A Line object (frame:CreateLine). Every setter the tether path drives is
-- recorded, because a beam is only observable as the numbers it was given.
function FakeLine()
    local l = { _shown = false, _alpha = 1, _thickness = 0,
                fxIn = false, fxOut = false, fxPop = false, fxPopOut = false,
                fxTo = false, fxScale = false }
    function l:SetStartPoint(point, rel, x, y) self._start = { point = point, rel = rel, x = x, y = y } end
    function l:SetEndPoint(point, rel, x, y) self._end = { point = point, rel = rel, x = x, y = y } end
    function l:SetThickness(t) self._thickness = t end
    function l:SetColorTexture(r, g, b, a) self._color = { r = r, g = g, b = b, a = a } end
    function l:SetVertexColor(r, g, b, a) self._vertex = { r = r, g = g, b = b, a = a } end
    function l:SetAlpha(a) self._alpha = a end
    function l:GetAlpha() return self._alpha end
    function l:Show() self._shown = true end
    function l:Hide() self._shown = false end
    function l:SetShown(v) self._shown = v and true or false end
    function l:IsShown() return self._shown end
    function l:CreateAnimationGroup() return nil end     -- Fx takes its headless path
    return setmetatable(l, { __index = function() return function() end end })
end

-- A Frame/Texture/FontString stub. `_cx/_cy` are the SETTABLE fake centre: the
-- stub does not resolve anchors, so a test that needs a frame to have moved
-- says so (`f:SetFakeCenter(x, y)`) and asserts on the recorded SetPoint calls
-- instead of on geometry the stub would have to invent.
function FakeUIFrame(w, h, cx, cy)
    local f = { _shown = false, _alpha = 1, _scale = 1, _w = w or 0, _h = h or 0,
                _cx = cx or 0, _cy = cy or 0, _points = {}, _scripts = {},
                _lines = {}, _textures = {}, _text = "", _flags = {},
                fxIn = false, fxOut = false, fxPop = false, fxPopOut = false,
                fxTo = false, fxScale = false }
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:SetShown(v) self._shown = v and true or false end
    function f:IsShown() return self._shown end
    function f:IsVisible() return self._shown end
    function f:SetAlpha(v) self._alpha = v end
    function f:GetAlpha() return self._alpha end
    function f:SetScale(v) self._scale = v end
    function f:GetScale() return self._scale end
    function f:GetEffectiveScale() return self._scale end
    function f:SetSize(w2, h2) self._w, self._h = w2, h2 end
    function f:SetWidth(w2) self._w = w2 end
    function f:SetHeight(h2) self._h = h2 end
    function f:GetWidth() return self._w end
    function f:GetHeight() return self._h end
    function f:GetSize() return self._w, self._h end
    function f:SetFakeCenter(x, y) self._cx, self._cy = x, y end
    function f:GetCenter() return self._cx, self._cy end
    function f:GetLeft() return self._cx - self._w / 2 end
    function f:GetRight() return self._cx + self._w / 2 end
    function f:GetBottom() return self._cy - self._h / 2 end
    function f:GetTop() return self._cy + self._h / 2 end
    function f:ClearAllPoints() wipe(self._points) end
    function f:SetPoint(...) self._points[#self._points + 1] = { ... } end
    function f:GetNumPoints() return #self._points end
    function f:SetScript(name, fn) self._scripts[name] = fn end
    function f:HookScript(name, fn) self._scripts[name] = fn end
    function f:GetScript(name) return self._scripts[name] end
    function f:SetVertexColor(r, g, b, a) self._vertex = { r = r, g = g, b = b, a = a } end
    -- Recorded for the same reason FakeLine records it: a flat-colour texture is
    -- only observable as the colour it was handed (the popout's title strip and
    -- the hairline under it are both one of these).
    function f:SetColorTexture(r, g, b, a) self._color = { r = r, g = g, b = b, a = a } end
    function f:SetTexture(path) self._texture = path return true end
    function f:GetTexture() return self._texture end
    function f:SetText(t) self._text = t or "" end
    function f:GetText() return self._text end
    function f:GetStringWidth() return 7 * #self._text end
    function f:SetEnabled(v) self._enabled = v and true or false end
    function f:IsEnabled() return self._enabled ~= false end
    function f:CreateTexture()
        local t = FakeUIFrame()
        self._textures[#self._textures + 1] = t
        return t
    end
    function f:CreateFontString() return FakeUIFrame() end
    function f:CreateLine()
        local l = FakeLine()
        self._lines[#self._lines + 1] = l
        return l
    end
    function f:CreateAnimationGroup() return nil end     -- Fx takes its headless path
    -- Drag/movable plumbing: recorded as flags so a test can assert that the
    -- title bar only became draggable once the popout was pinned.
    function f:SetMovable(v) self._flags.movable = v and true or false end
    function f:IsMovable() return self._flags.movable == true end
    function f:EnableMouse(v) self._flags.mouse = v and true or false end
    function f:RegisterForDrag(...) self._flags.drag = { ... } end
    function f:StartMoving() self._flags.moving = true end
    function f:StopMovingOrSizing() self._flags.moving = false end
    function f:SetClampedToScreen(v) self._flags.clamped = v and true or false end
    function f:SetFrameStrata(v) self._flags.strata = v end
    function f:SetFrameLevel(v) self._flags.level = v end
    function f:GetFrameLevel() return self._flags.level or 1 end
    return setmetatable(f, { __index = function() return function() end end })
end

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
