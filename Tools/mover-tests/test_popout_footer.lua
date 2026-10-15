local NS = ...

-- ============================================================
-- THE POPOUT'S FOOTER -- DandersUI/Popout.lua
-- ------------------------------------------------------------
-- The action strip along the bottom of a panel: a consumer declares `actions`
-- and gets buttons for them. Its own file rather than more of test_popout.lua
-- because the host it needs is DIFFERENT -- a real CreateButton, a tooltip
-- surface -- and installing either on the SHARED library table would change what
-- the suites either side of this one see. Both live on this file's HOST instead,
-- where the factory lookup finds them first and nothing outside is touched.
--
-- What is worth pinning here, in the order the claims are made below:
--
--   1. A POPOUT WITH NO ACTIONS IS THE POPOUT IT ALWAYS WAS. No strip, no
--      buttons, and the SAME height -- asserted against one built the old way in
--      the same breath, not against a remembered number.
--   2. ☠ onHoldEnd FIRES EXACTLY ONCE PER onHoldStart, AND NEVER WITHOUT ONE.
--      It is the restore half of a preview: miss it and the user is left looking
--      at defaults with their settings gone; run it twice and the second restore
--      replays a snapshot that was already spent. Every way a press can end is
--      driven here -- the release, the panel closing, the panel hiding, the
--      button going disabled underneath it -- and each one is followed by the
--      release that would double-fire it.
--   3. THE FOOTER IS PER-ADOPT, NOT PER-BUILD. One pooled instance serves every
--      row on a host, so re-adopting it with different actions has to re-render
--      -- and re-adopting with none has to take the strip away and give the
--      height back.
--   4. `enabled` GREYS AND EXPLAINS. A false answer disables the button and its
--      reason reaches the tooltip the hover would show.
-- ============================================================
local UI = NS.__DandersUI

-- ---- what the base half would have installed ----------------------
-- Guarded throughout: test_panel.lua and test_popout.lua normally own these on
-- the shared table by the time this file runs. `run.py popout_footer` on its own
-- still works because each guard fills in what nobody installed.
UI.MEDIA = UI.MEDIA or ""
UI.Colors = UI.Colors or { text = { r = 0.9, g = 0.9, b = 0.9 }, textDim = { r = 0.5, g = 0.5, b = 0.5 } }
UI.Colors.panel  = UI.Colors.panel  or { r = 0.12, g = 0.12, b = 0.12 }
UI.Colors.border = UI.Colors.border or { r = 0.25, g = 0.25, b = 0.25 }
if not UI.GetAccent then
    local A = { r = 0.45, g = 0.45, b = 0.95, a = 1 }
    function UI:GetAccent() return A end
end
if not UI.CreatePanelBackdrop then
    function UI:CreatePanelBackdrop(frame, opts) frame._panelOpts = opts return frame end
end
if not UI.ApplyPixelBorder then
    function UI:ApplyPixelBorder(frame, color) frame._pxColor = color return frame end
end
if not UI.CreateLabel then
    function UI:CreateLabel(_, opts)
        local fs = FakeUIFrame()
        if opts and opts.text then fs:SetText(opts.text) end
        return fs
    end
end
UI.CreateLabelNative = UI.CreateLabelNative or UI.CreateLabel
if not UI.CreateCloseButton then
    local function stubButton(opts)
        local b = FakeUIFrame(16, 16)
        b._opts = opts
        b:Show()
        return b
    end
    function UI:CreateCloseButton(_, opts) return stubButton(opts) end
    function UI:CreateGlyphButton(_, opts) return stubButton(opts) end
end
if not UI.Hook then
    function UI:Hook(name)
        local h = rawget(self, "hooks")
        return h and h[name] or nil
    end
    function UI:Call(name, ...)
        local fn = self:Hook(name)
        if not fn then return nil end
        return fn(...)
    end
end

-- ---- Theme.lua metrics --------------------------------------------
-- Mirrors of the real values, for the reason the other popout suites spell out
-- at their own copies: Theme.lua is not loadable headless, and Popout.lua reads
-- all of these at FILE SCOPE.
UI.PopoutTitle = UI.PopoutTitle or { topPad = 6, row = 28, fill = 0.9, sepAlpha = 0.8 }
UI.PopoutTitleHeight = UI.PopoutTitleHeight or (UI.PopoutTitle.topPad + UI.PopoutTitle.row)
UI.PopoutPad = UI.PopoutPad or 10
UI.PopoutFooter = UI.PopoutFooter or { height = 26, btnHeight = 18, gap = 6, sepAlpha = UI.PopoutTitle.sepAlpha }

local TITLE_H, PAD, FOOTER = UI.PopoutTitleHeight, UI.PopoutPad, UI.PopoutFooter

-- ---- WoW globals ---------------------------------------------------
local prevCreateFrame, prevTimer = CreateFrame, C_Timer
local prevPlaySound, prevSoundKit = PlaySound, SOUNDKIT
PlaySound = function() end
SOUNDKIT = { IG_MAINMENU_OPTION_CHECKBOX_ON = 1 }

-- ☠ A MISSING DATA FIELD MUST READ nil, NOT A FUNCTION -- the rule
-- test_popout_row.lua states at its own stub, and this file needs it for two
-- fields in particular. `dfDisabled` gates every press (a truthy no-op function
-- would mean no button in this suite could ever be clicked) and `_dfAct` is the
-- descriptor a pooled button is currently about (a truthy function would be
-- indexed as a table the moment a surplus button was cancelled).
local function dataAwareMeta(k)
    if k == "dfDisabled" then return nil end
    if type(k) == "string" and k:byte(1) == 95 then return nil end   -- "_"
    return function() end
end

CreateFrame = function(kind, _, parent)
    local f = FakeUIFrame()
    setmetatable(f, { __index = function(_, k) return dataAwareMeta(k) end })
    f._kind = kind
    f._children = {}
    f._parent = parent
    f.GetParent = function(self) return self._parent end
    -- The popout's accent cascade walks the frame tree, so the stub needs one.
    f.GetChildren = function(self) return unpack(self._children) end
    if type(parent) == "table" then
        local kids = rawget(parent, "_children")
        if not kids then kids = {}; parent._children = kids end
        kids[#kids + 1] = f
    end
    return f
end
C_Timer = { After = function(_, fn) fn() end }

-- ---- the host ------------------------------------------------------
-- CreateButton and the tooltip pair go on the HOST, not on the library: the
-- factory is called as `po.host:CreateButton(...)`, so a field on the host wins
-- and the shared table -- which test_panel.lua and test_ui_options.lua both have
-- their own stubs on -- is left exactly as it was found.
local L = setmetatable({}, { __index = function(_, k) return k end })
local tooltipShown                       -- the spec the last hover handed over
local host = setmetatable({ hooks = { L = L } }, { __index = UI })

-- Modelled on the real CreateButton's observable contract and no further: it
-- labels the button, it wires opts.onClick behind a dfDisabled early-out, and it
-- leaves SetDisabled behind (which is what the footer greys through -- a
-- disabled button here still takes the mouse, because its tooltip is the only
-- thing that says why it cannot be pressed).
function host:CreateButton(parent, opts)
    opts = opts or {}
    local b = FakeUIFrame(opts.width or 100, opts.height or 22)
    setmetatable(b, { __index = function(_, k) return dataAwareMeta(k) end })
    b._parent = parent
    b._opts = opts
    b.dfDisabled = false
    b:SetText(opts.text or "")
    b:Show()
    b.SetDisabled = function(self, disabled) self.dfDisabled = disabled and true or false end
    if opts.onClick then
        b:SetScript("OnClick", function(self)
            if self.dfDisabled then return end
            opts.onClick(self)
        end)
    end
    return b
end
-- The lib calls the shim-proof alias; in the stub they are the same function.
host.CreateButtonNative = host.CreateButton
function host:ShowTooltip(_, spec) tooltipShown = spec end
function host:HideTooltip() tooltipShown = nil end

-- Only if nobody has: test_panel.lua normally owns this load.
if not UI.CreatePopout then load_ui_file("Popout.lua") end

-- ---- fixtures ------------------------------------------------------
local CX, CY = 960, 540
local function source()
    local f = FakeUIFrame(80, 20, CX, CY)
    f:Show()
    return f
end

local W = 100
local function build(_, content) content:SetHeight(50) end

local keySeq = 0
local function popout(actions, key)
    keySeq = keySeq + 1
    return host:CreatePopout({
        key = key or ("footer" .. keySeq),
        width = W,
        title = "T",
        build = build,
        actions = actions,
    })
end

-- Press and release one footer button, the way the client would.
local function press(btn) btn:GetScript("OnMouseDown")(btn) end
local function release(btn) btn:GetScript("OnMouseUp")(btn) end
local function click(btn) btn:GetScript("OnClick")(btn) end
local function hover(btn) btn:GetScript("OnEnter")(btn) end

-- ============================================================
-- 1. NO ACTIONS IS THE POPOUT THAT ALWAYS WAS
-- The whole "every existing consumer is untouched" promise, and it is only worth
-- anything measured against a popout built without them IN THE SAME RUN.
-- ============================================================
do
    local bare = popout(nil)
    check(rawget(bare, "_footer") == nil, "footer: no actions builds no strip at all")
    check(not bare._footerOn, "footer: ...and the height flag stays down")
    eq(bare.frame:GetHeight(), TITLE_H + PAD + 50 + PAD,
       "footer: the bare popout is title + pad + content + pad, exactly as before")

    local withFooter = popout({ { text = "A", onClick = function() end } })
    eq(withFooter.frame:GetHeight(), TITLE_H + PAD + 50 + PAD + FOOTER.height,
       "footer: a popout WITH actions is the same panel plus the strip")
    eq(withFooter.frame:GetHeight() - bare.frame:GetHeight(), FOOTER.height,
       "footer: ...and the difference between the two is the strip and nothing else")

    -- An EMPTY array is "no actions", not "a strip with nothing in it": a
    -- consumer that builds its list conditionally must not be punished with 26px
    -- of empty panel when the conditions all said no.
    local empty = popout({})
    check(rawget(empty, "_footer") == nil, "footer: an empty actions array builds no strip")
    eq(empty.frame:GetHeight(), TITLE_H + PAD + 50 + PAD,
       "footer: ...and takes no height either")
end

-- ============================================================
-- 2. THE BUTTONS
-- N descriptors in, N buttons out, labelled, and a press runs the right one.
-- ============================================================
do
    local fired = {}
    local po = popout({
        { text = "Reset",  onClick = function(p) fired[#fired + 1] = { "reset", p } end },
        { text = "Revert", onClick = function(p) fired[#fired + 1] = { "revert", p } end },
    })
    local btns = po._footerBtns
    eq(#btns, 2, "footer: two descriptors build two buttons")
    eq(btns[1]:GetText(), "Reset", "footer: the first carries the first label")
    eq(btns[2]:GetText(), "Revert", "footer: ...and the second the second")
    check(btns[1]:IsShown() and btns[2]:IsShown(), "footer: both are up")
    eq(btns[1]:GetHeight(), FOOTER.btnHeight, "footer: at the strip's own button height")

    -- Equal shares of the content width, which is what makes a swap between two
    -- rows with different labels leave the strip looking the same.
    eq(btns[1]:GetWidth(), (W - FOOTER.gap) / 2, "footer: each button takes an equal share of the width")
    eq(btns[1]:GetWidth(), btns[2]:GetWidth(), "footer: ...so the two are the same size")

    click(btns[2])
    eq(#fired, 1, "footer: a click fires exactly one action")
    eq(fired[1][1], "revert", "footer: ...the one that was clicked")
    eq(fired[1][2], po, "footer: ...and it is handed the popout")
end

-- ============================================================
-- 3. enabled: THE GREY AND THE REASON
-- ============================================================
do
    local allowed, ran = false, 0
    local po = popout({
        {
            text = "Reset", tooltip = "Reset", tooltipDesc = "Puts it all back.",
            enabled = function()
                if allowed then return true end
                return false, "Not in combat."
            end,
            onClick = function() ran = ran + 1 end,
        },
    })
    local btn = po._footerBtns[1]
    check(btn.dfDisabled, "footer: a false `enabled` disables the button")
    click(btn)
    eq(ran, 0, "footer: ...and a click on a disabled button does nothing")

    tooltipShown = nil
    hover(btn)
    check(tooltipShown ~= nil, "footer: a disabled button still takes the hover")
    eq(tooltipShown.title, "Reset", "footer: the tooltip title is the action's")
    eq(tooltipShown.lines[1], "Puts it all back.", "footer: the description is the first line")
    local last = tooltipShown.lines[#tooltipShown.lines]
    eq(type(last) == "table" and last.text or last, "Not in combat.",
       "footer: ☠ the REASON reaches the tooltip -- a grey button with no explanation is a dead end")

    allowed = true
    po:_RefreshFooter()
    check(not btn.dfDisabled, "footer: re-evaluated on refresh, the button comes back")
    click(btn)
    eq(ran, 1, "footer: ...and now it runs")
    tooltipShown = nil
    hover(btn)
    local n = #(tooltipShown.lines or {})
    eq(n, 1, "footer: with nothing to explain, the tooltip is the description alone")

    -- A plain boolean is the other accepted form.
    local po2 = popout({ { text = "X", enabled = false, onClick = function() end } })
    check(po2._footerBtns[1].dfDisabled, "footer: `enabled = false` greys it too")
end

-- ============================================================
-- 4. ☠ PRESS AND HOLD -- EXACTLY ONCE, EVERY TIME
-- The clause the whole feature turns on. onHoldEnd is the RESTORE: every way a
-- press can end has to reach it, and no way may reach it twice.
-- ============================================================
do
    local starts, ends = 0, 0
    local function holdAction(extra)
        local a = {
            text = "Hold", hold = true,
            onHoldStart = function() starts = starts + 1 end,
            onHoldEnd   = function() ends = ends + 1 end,
        }
        for k, v in pairs(extra or {}) do a[k] = v end
        return a
    end

    -- (a) the ordinary gesture
    do
        local po = popout({ holdAction() })
        local btn = po._footerBtns[1]
        press(btn)
        eq(starts, 1, "hold: the press starts it")
        eq(ends, 0, "hold: ...and nothing has ended yet")
        release(btn)
        eq(ends, 1, "hold: the release ends it")
        -- The click the client delivers AFTER the release must not re-run the
        -- action: for a hold button the down and the up ARE the gesture.
        click(btn)
        eq(starts, 1, "hold: the click that follows a release starts nothing")
        eq(ends, 1, "hold: ...and ends nothing")
        release(btn)
        eq(ends, 1, "hold: a second release fires no second end")
    end

    -- (b) the panel CLOSES under the press. The cross, a family sweep, the source
    -- going away -- all three are Close, and the restore is still owed.
    starts, ends = 0, 0
    do
        local po = popout({ holdAction() })
        local btn = po._footerBtns[1]
        press(btn)
        eq(starts, 1, "hold: pressed")
        po:Close("cross")
        eq(ends, 1, "hold: ☠ closing the panel mid-press fires the end")
        release(btn)
        eq(ends, 1, "hold: ☠ ...and the release that follows does NOT fire it again")
    end

    -- (c) the panel is HIDDEN by hand (a consumer's combat suspend). The frame's
    -- own OnHide carries it, alongside the chrome teardown that hook already did.
    starts, ends = 0, 0
    do
        local po = popout({ holdAction() })
        local btn = po._footerBtns[1]
        press(btn)
        po.frame:GetScript("OnHide")(po.frame)
        eq(ends, 1, "hold: hiding the panel mid-press fires the end")
        release(btn)
        eq(ends, 1, "hold: ...once")
    end

    -- (d) the button goes DISABLED under the press -- combat starting mid-hold is
    -- the real case. A press nobody can release must not be left hanging.
    starts, ends = 0, 0
    do
        local ok = true
        local po = popout({ holdAction({ enabled = function() return ok end }) })
        local btn = po._footerBtns[1]
        press(btn)
        eq(starts, 1, "hold: pressed while it was allowed")
        ok = false
        po:_RefreshFooter()
        eq(ends, 1, "hold: going disabled under the press fires the end")
        release(btn)
        eq(ends, 1, "hold: ...once")
        -- ...and a press on a button that was ALREADY disabled starts nothing,
        -- so the end can never run without a start.
        press(btn)
        eq(starts, 1, "hold: a press on a disabled button starts nothing")
        release(btn)
        eq(ends, 1, "hold: ☠ ...so no end fires without a start")
    end

    -- (e) the strip is RE-RENDERED under the press (the panel swapped to another
    -- row). The descriptor is about to change, so the press is over.
    starts, ends = 0, 0
    do
        local po = popout({ holdAction() })
        press(po._footerBtns[1])
        po:SetActions({ { text = "Other", onClick = function() end } })
        eq(ends, 1, "hold: re-rendering the strip mid-press fires the end")
        eq(starts, 1, "hold: ...and starts nothing new")
    end

    -- (f) a plain action is NOT a hold. Its press and release must not fire the
    -- hold pair at all -- which is the other half of "never without a start".
    starts, ends = 0, 0
    do
        local po = popout({ { text = "Plain", onClick = function() end,
                              onHoldStart = function() starts = starts + 1 end,
                              onHoldEnd   = function() ends = ends + 1 end } })
        local btn = po._footerBtns[1]
        press(btn)
        release(btn)
        eq(starts, 0, "hold: a descriptor without `hold` never starts one")
        eq(ends, 0, "hold: ...and never ends one")
    end
end

-- ============================================================
-- 5. THE POOL -- THE FOOTER IS PER-ADOPT
-- One instance per host+key serves every consumer that asks for that key, so the
-- strip has to be re-rendered on every adopt. Rendered once at build, the second
-- consumer would be looking at the first one's buttons -- and pressing them
-- would act on the first one's settings.
-- ============================================================
do
    local ranA, ranB = 0, 0
    local A = { { text = "Alpha", onClick = function() ranA = ranA + 1 end } }
    local B = {
        { text = "Beta",  onClick = function() ranB = ranB + 1 end },
        { text = "Gamma", onClick = function() ranB = ranB + 1 end },
    }

    local po = popout(A, "shared")
    eq(po._footerBtns[1]:GetText(), "Alpha", "pool: the first consumer's action is on the strip")
    po:Close("api")

    local again = popout(B, "shared")
    eq(again, po, "pool: the same instance came back")
    eq(#again._footerBtns, 2, "pool: ...with a second button built for the second consumer")
    eq(again._footerBtns[1]:GetText(), "Beta", "pool: ☠ the strip is the NEW consumer's, not the old one's")
    eq(again._footerBtns[2]:GetText(), "Gamma", "pool: ...both of them")
    click(again._footerBtns[1])
    eq(ranA, 0, "pool: ☠ pressing it does NOT run the previous consumer's action")
    eq(ranB, 1, "pool: ...it runs this one's")

    -- The buttons are POOLED, not leaked: the second adopt reused the first
    -- button rather than building a third.
    local first = again._footerBtns[1]
    again:Close("api")
    local third = popout(A, "shared")
    eq(#third._footerBtns, 2, "pool: the button pool is kept across adopts")
    eq(third._footerBtns[1], first, "pool: ...and reused rather than rebuilt")
    eq(third._footerBtns[1]:GetText(), "Alpha", "pool: relabelled for whoever has it now")
    check(not third._footerBtns[2]:IsShown(), "pool: the surplus button is hidden, not left showing a stale verb")

    -- ...and a consumer that declares NONE takes the strip away entirely, height
    -- included. A pooled instance that kept an empty strip would hold 26px open
    -- for every consumer after the first one that used it.
    local h = third.frame:GetHeight()
    third:Close("api")
    local none = popout(nil, "shared")
    check(not none._footerOn, "pool: re-adopted with no actions, the strip is gone")
    check(not none._footer:IsShown(), "pool: ...and hidden")
    eq(none.frame:GetHeight(), h - FOOTER.height, "pool: ...and the panel gives the height back")
    eq(none.frame:GetHeight(), TITLE_H + PAD + 50 + PAD, "pool: ...landing on the bare popout's own height")
end

-- ============================================================
-- 6. THE GATE
-- The strip greys with the pane it stands under. Stated on the shell so the row
-- has one call to make, and idempotent so it can make it on every refresh.
-- ============================================================
do
    local ran = 0
    local po = popout({ { text = "Go", onClick = function() ran = ran + 1 end } })
    local btn = po._footerBtns[1]
    check(not btn.dfDisabled, "gate: open, the button is live")

    po:SetFooterGated(true)
    check(btn.dfDisabled, "gate: shut, it greys with the pane")
    click(btn)
    eq(ran, 0, "gate: ...and does nothing")

    po:SetFooterGated(false)
    check(not btn.dfDisabled, "gate: opened again, it comes back")
    click(btn)
    eq(ran, 1, "gate: ...and works")

    -- The gate is the LAST word: an action that says it is enabled still greys
    -- while the feature behind it is switched off.
    po:SetActions({ { text = "Go", enabled = true, onClick = function() end } })
    po:SetFooterGated(true)
    check(po._footerBtns[1].dfDisabled, "gate: it outranks an `enabled` that says yes")

    -- ...and it does NOT survive the pool. The next consumer's toggle has no
    -- relationship to the previous one's.
    po:Close("api")
    local next2 = host:CreatePopout({
        key = po.key, width = W, title = "T", build = build,
        actions = { { text = "Go", onClick = function() end } },
    })
    check(not next2._footerBtns[1].dfDisabled, "gate: ☠ a fresh adopt clears the previous consumer's gate")
end

-- ---- restore -------------------------------------------------------
CreateFrame, C_Timer = prevCreateFrame, prevTimer
PlaySound, SOUNDKIT = prevPlaySound, prevSoundKit
