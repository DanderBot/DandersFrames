local NS = ...

-- ============================================================
-- A TONED BUTTON IN THE ALERT POPUP -- DandersUI/Popup.lua
-- ------------------------------------------------------------
-- An alert button may carry tone = "danger" (or "success"): the kit's toned
-- button, hover and label in that colour -- the destructive choice of a confirm
-- (the Modules page's Reset). StyleButton fixes a button's hover colour when it
-- is built, so toned buttons are pooled apart from plain ones: a slot that was
-- red in one dialog is never handed to the next dialog's plain button.
-- The real Popup.lua over a recording kit; the label colour is the one table the
-- kit's StyleButton reads too (UI.ButtonToneLabel, Widgets.lua).
-- ============================================================

local saved = { CreateFrame = CreateFrame, PlaySound = PlaySound, SOUNDKIT = SOUNDKIT,
                Mixin = Mixin, BackdropTemplateMixin = BackdropTemplateMixin, UISpecialFrames = UISpecialFrames }

local function Frame()
    local f = FakeUIFrame()
    -- Fields the popup tests for truth: unset, a fake frame answers a no-op function.
    f.InputBox, f.InputAreaBox = false, false
    f.CreateFontString = function()
        local fs = FakeUIFrame()
        fs.SetTextColor = function(self, r, g, b) self._tc = { r, g, b } end
        return fs
    end
    return f
end
local created = {}
CreateFrame = function(...) local f = Frame(); created[#created + 1] = f; return f end
PlaySound = function() end
SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 1 }
Mixin = function(t) return t end
BackdropTemplateMixin = {}
UISpecialFrames = {}

-- The label colours are the kit's own table: read it out of Widgets.lua rather
-- than restating the numbers here.
local WSRC = ui_file_source("Widgets.lua"):gsub("\r\n", "\n")
local tableSrc = WSRC:match("\nUI%.ButtonToneLabel = UI%.ButtonToneLabel or (%b{})")
check(tableSrc ~= nil, "kit: Widgets.lua publishes UI.ButtonToneLabel")
local TONES = tableSrc and loadstring("return " .. tableSrc)() or {}
check(WSRC:find("local toneLabel = opts.tone and UI.ButtonToneLabel[opts.tone] or nil", 1, true) ~= nil,
      "kit: StyleButton's own toned label reads the same table")

local styled = {}
local UI = {
    DialogColors = { text = { r = 1, g = 1, b = 1 }, background = { r = 0, g = 0, b = 0 },
                     panel = { r = 0.1, g = 0.1, b = 0.1 } },
    ButtonToneLabel = TONES,
    hooks = { L = setmetatable({}, { __index = function(_, k) return k end }) },
}
function UI:StyleButton(btn, opts) styled[btn] = opts end
function UI:CreateElementBackdrop() end
function UI:GetAccent() return { r = 0.5, g = 0.4, b = 1 } end
function UI:Call() return nil end
function UI:CreateCloseButton() return Frame() end
function UI:AddFontRoot() end
function UI:GetToneColor() return { 1, 0.3, 0.3 } end
function UI:Error(msg) error(msg) end

load_ui_file_into("Popup.lua", { __DandersUI = UI })
check(type(UI.ShowPopupAlert) == "function", "setup: the popup is loaded over the recording kit")

print("-- Popup: a danger button beside a plain one")
UI:ShowPopupAlert({ title = "Reset Toy?", tone = "danger", message = "Body",
                    buttons = { { label = "Reset", tone = "danger" }, { label = "Cancel" } } })
local f = created[1]
local pool = f and f.alertButtonFrames or {}
local red, plain = pool["danger:1"], pool[2]
check(red ~= nil, "tone: the danger button is pooled under its own key")
eq(pool[1], nil, "tone: ...and the plain slot 1 was never made for it")
eq(red and styled[red] and styled[red].tone, "danger", "tone: it is built as the kit's danger button")
eq(red and red.Text:GetText(), "Reset", "tone: labelled")
local dc = TONES.danger or {}
check(red and red.Text._tc and red.Text._tc[1] == dc[1] and red.Text._tc[2] == dc[2] and red.Text._tc[3] == dc[3],
      "tone: its label wears the danger label colour")
check(red and red:IsShown(), "tone: shown")
check(plain and styled[plain] and styled[plain].tone == nil, "plain: Cancel is an untoned button")
check(plain and plain.Text._tc and plain.Text._tc[1] == 1 and plain.Text._tc[2] == 1, "plain: in the plain text colour")

print("-- Popup: the next dialog never inherits the red")
UI:ShowPopupAlert({ title = "Notice", message = "Body", buttons = { { label = "OK" }, { label = "Later" } } })
local first = pool[1]
check(first ~= nil and first ~= red, "pool: a plain button 1 is its own button")
eq(first and styled[first] and styled[first].tone, nil, "pool: ...untoned")
check(red and not red:IsShown(), "pool: the danger button is hidden for a dialog that has none")

UI:ShowPopupAlert({ title = "Again", message = "Body",
                    buttons = { { label = "Reset", tone = "danger" }, { label = "Cancel" } } })
check(pool["danger:1"] == red and red:IsShown(), "pool: a later danger button reuses the one built for it")
check(first and not first:IsShown(), "pool: ...and the plain slot it displaced is hidden")

for k, v in pairs(saved) do _G[k] = v end
