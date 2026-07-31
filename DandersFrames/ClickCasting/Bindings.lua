local addonName, DF = ...

-- Get module namespace
local CC = DF.ClickCast
local L = DF.L

-- Local aliases for shared constants (defined in Constants.lua)
local DEFAULT_BINDING = CC.DEFAULT_BINDING

-- Local aliases for helper functions (defined in Profiles.lua)
local GetCombatCondition = function(b) return CC.GetCombatCondition(b) end
local BuildModifierPrefix = function(m) return CC.BuildModifierPrefix(m) end
local GetButtonNumber = function(b) return CC.GetButtonNumber(b) end

-- BUG #10 / BUG #860 FIX: Combat-conditional type attribute via RegisterAttributeDriver.
-- SecureHandlerWrapScript on PreClick can't block type="target" or type="togglemenu"
-- because SecureActionButton_OnClick reads attributes keyed off the ORIGINAL mouse
-- button, not any value the PreClick prescript returns. RegisterAttributeDriver
-- solves this natively: it evaluates a macro conditional and writes the result to
-- the named attribute, re-evaluating whenever relevant events fire (e.g. combat
-- entry/exit). It runs in the restricted environment, so it works during lockdown.
--
-- For a "combat only" target binding:  [combat] target;     → "target" in combat, "" out
-- For a "nocombat only" target binding: [nocombat] target;   → "target" out of combat, "" in
--
-- Tracks registered driver attribute names on frame.dfAttrDriverList so they can
-- be unregistered when bindings change.
local function AddCombatConditional(frame, typeAttr, realType, combatCond)
    local macro = "[" .. combatCond .. "] " .. realType .. ";"
    RegisterAttributeDriver(frame, typeAttr, macro)
    frame.dfAttrDriverList = frame.dfAttrDriverList or {}
    table.insert(frame.dfAttrDriverList, typeAttr)
end

-- ============================================================
-- 12.0.7 CLICK GATE WORKAROUND (target / menu via ungated proxy)
-- 12.0.7 added a gate inside SecureUnitButton_OnClick: when the resolved
-- action is "target"/"menu"/"togglemenu" AND C_ClickBindings.GetBindingType
-- for that button+modifier is None, the click is dropped. Only the default
-- interaction buttons (plain left/right) pass, so target/menu bound to any
-- other key or button silently stops working. SecureActionButton_OnClick is
-- NOT gated, so we route those actions through a hidden SecureActionButton
-- child via the secure "click" action: the unit button delegates with
-- :Click(button), the proxy's ungated handler runs target/togglemenu, and
-- the action fires. Credit: Ellesmere (EllesmereUI). Version-agnostic — the
-- "click" action and an ungated SecureActionButton work on pre-12.0.7 too.

-- Lazily create the per-frame proxy button (out of combat only). useparent-unit
-- makes the proxy inherit the frame's real unit token (party1, raid3, ...), so
-- targeting keeps working at any range. Returns nil if we're in combat.
local proxyCount = 0
function CC:EnsureClickProxy(frame)
    if frame.dfClickProxy then return frame.dfClickProxy end
    -- Returns nil by contract (caller falls back to the @mouseover path);
    -- the proxy is created on the next out-of-combat binding pass.
    if InCombatLockdown() then return nil end
    -- GLOBAL NAME: the 12.1 macro reroute below reaches the proxy via
    -- "/click <name> <button>", which needs a named button. Harmless pre-12.1.
    proxyCount = proxyCount + 1
    local proxy = CreateFrame("Button", "DFClickProxy" .. proxyCount, frame, "SecureActionButtonTemplate")
    proxy:EnableMouse(false)              -- only ever clicked programmatically
    proxy:RegisterForClicks("AnyUp")      -- fire on the up stroke (menu-safe)
    proxy:SetAttribute("useparent-unit", true)
    proxy:SetAttribute("useOnKeyDown", false)
    frame.dfClickProxy = proxy
    return proxy
end

-- ★ 12.1 PTR (build 12.1.0): SECURE_ACTIONS.click is BROKEN — Blizzard's new
-- forbidden-aspects check calls `button:HasAnyForbiddenAspects(...)` where
-- `button` is the mouse-button STRING, so EVERY delegated type="click" action
-- throws "attempt to call a nil value" (SecureTemplates.lua:564; verified in the
-- local dump AND Gethe ptr — hits Clique-style delegation addon-wide). Until
-- Blizzard fixes it, route the delegation through SECURE_ACTIONS.macro instead:
-- `/click <proxyName> <button>` clicks the SAME ungated proxy with identical
-- button + held-modifier resolution, and the macro type is not in the
-- SecureUnitButton gate's expectBinding set — so the 12.0.7 None-drop still
-- never fires. RE-CHECK EACH PTR BUILD; delete this path once click is fixed.
local CLICK_DELEGATE_BROKEN = select(4, GetBuildInfo()) >= 120100

local CLICK_BUTTON_NAME = { ["1"] = "LeftButton", ["2"] = "RightButton",
                            ["3"] = "MiddleButton", ["4"] = "Button4", ["5"] = "Button5" }
-- The mouse-button name delegate:Click(button) would have received, derived from
-- the type attribute: "ctrl-type2" -> "RightButton"; virtual "type-<vbtn>" -> "<vbtn>".
local function ProxyClickButtonFor(typeAttr)
    local suffix = typeAttr:match("type(.+)$")
    if not suffix then return "LeftButton" end
    local virtual = suffix:match("^%-(.+)$")
    if virtual then return virtual end
    return CLICK_BUTTON_NAME[suffix] or "LeftButton"
end

-- Route a gated action (target / togglemenu) on a DandersFrames frame through
-- the proxy. typeAttr is the action attribute on the frame (e.g. "shift-type2"
-- or "type-<vbtn>"); clickbuttonAttr is its matching clickbutton attribute. The
-- proxy carries the real action under the SAME suffix, so the delegated
-- :Click(button) resolves to it. Records the route on frame.dfProxyRoutes for
-- cleanup.
function CC:RouteProxyAction(frame, typeAttr, clickbuttonAttr, realAction, combatCond)
    local proxy = self:EnsureClickProxy(frame)
    if not proxy then
        -- In combat the proxy can't be created. Emit the (gated) direct action
        -- as a fallback; the whole binding set is reapplied after combat, which
        -- installs the proxy and replaces this. Record the write in the
        -- manifest so the next clear removes it (the apply loop is combat-
        -- guarded so this leg should be unreachable, but if it ever runs the
        -- attribute must not escape the bookkeeping).
        frame:SetAttribute(typeAttr, realAction)
        frame.dfWrittenAttrs = frame.dfWrittenAttrs or {}
        frame.dfWrittenAttrs[typeAttr] = "type"
        if combatCond then AddCombatConditional(frame, typeAttr, realAction, combatCond) end
        return
    end
    local macrotextAttr
    if CLICK_DELEGATE_BROKEN then
        -- Macro reroute (see CLICK_DELEGATE_BROKEN above): same proxy, same
        -- button/modifier resolution, but delegated via /click instead of the
        -- broken SECURE_ACTIONS.click. Proxy fires on the up stroke (AnyUp),
        -- which is /click's default.
        macrotextAttr = typeAttr:gsub("type", "macrotext", 1)
        frame:SetAttribute(typeAttr, "macro")
        frame:SetAttribute(macrotextAttr, "/click " .. proxy:GetName() .. " " .. ProxyClickButtonFor(typeAttr))
    else
        frame:SetAttribute(typeAttr, "click")
        frame:SetAttribute(clickbuttonAttr, proxy)
    end
    if combatCond then
        -- Gate on the proxy: the frame always delegates, the proxy decides
        -- whether the action runs based on combat state.
        AddCombatConditional(proxy, typeAttr, realAction, combatCond)
    else
        proxy:SetAttribute(typeAttr, realAction)
    end
    frame.dfProxyRoutes = frame.dfProxyRoutes or {}
    frame.dfProxyRoutes[#frame.dfProxyRoutes + 1] = { typeAttr = typeAttr, clickbuttonAttr = clickbuttonAttr, macrotextAttr = macrotextAttr }
end

-- Clear proxy routes from a frame: wipe the frame's click/clickbutton attrs,
-- the proxy's action attrs, and any combat drivers registered on the proxy.
function CC:ClearClickProxyRoutes(frame)
    if frame.dfProxyRoutes then
        for _, r in ipairs(frame.dfProxyRoutes) do
            frame:SetAttribute(r.typeAttr, "")
            frame:SetAttribute(r.clickbuttonAttr, nil)
            if r.macrotextAttr then frame:SetAttribute(r.macrotextAttr, nil) end
            if frame.dfClickProxy then
                frame.dfClickProxy:SetAttribute(r.typeAttr, "")
            end
        end
        frame.dfProxyRoutes = nil
    end
    if frame.dfClickProxy and frame.dfClickProxy.dfAttrDriverList then
        for _, attr in ipairs(frame.dfClickProxy.dfAttrDriverList) do
            UnregisterAttributeDriver(frame.dfClickProxy, attr)
        end
        frame.dfClickProxy.dfAttrDriverList = nil
    end
end

-- BINDING APPLICATION
-- ============================================================

-- Helper to check if a spell is known/usable (used at bind-time for fallback selection)
local function IsSpellKnownByName(spellName, spellId)
    if not spellName then return false end

    local bookType = Enum.SpellBookSpellBank.Player

    -- If we have a stored spell ID, check the override chain first
    -- This handles spec-specific variants (e.g. Remove Corruption -> Nature's Cure)
    -- where the stored name may not match the current spec's version
    if spellId and C_Spell.GetOverrideSpell then
        local overrideId = C_Spell.GetOverrideSpell(spellId)
        if overrideId then
            if C_SpellBook and C_SpellBook.IsSpellInSpellBook then
                if C_SpellBook.IsSpellInSpellBook(overrideId, bookType, true) then
                    return true
                end
            end
        end
    end

    -- Try by name (original behavior)
    local spellInfo = C_Spell.GetSpellInfo(spellName)
    if not spellInfo then return false end

    local resolvedId = spellInfo.spellID
    if not resolvedId then return false end

    -- Use IsSpellInSpellBook with includeOverrides=true to handle hero talent overrides
    -- (e.g., Chrono Flames which overrides Living Flame)
    if C_SpellBook and C_SpellBook.IsSpellInSpellBook then
        return C_SpellBook.IsSpellInSpellBook(resolvedId, bookType, true)
    end

    -- Fallback for older API
    if C_SpellBook and C_SpellBook.IsSpellKnownOrInSpellBook then
        return C_SpellBook.IsSpellKnownOrInSpellBook(resolvedId, bookType, true)
    end

    return false
end

-- Get the current display info for a spell, accounting for talent overrides
-- Returns: name, icon, spellId (all for the CURRENT form of the spell)
-- Used for UI display only - binding still uses base spell name for casting
local function GetSpellDisplayInfo(baseSpellId, baseSpellName)
    local displayName = baseSpellName
    local displayIcon = nil
    local displaySpellId = baseSpellId
    
    -- Try to get override spell if we have a base ID
    if baseSpellId and C_Spell.GetOverrideSpell then
        local overrideId = C_Spell.GetOverrideSpell(baseSpellId)
        if overrideId and overrideId ~= baseSpellId then
            displaySpellId = overrideId
            local overrideInfo = C_Spell.GetSpellInfo(overrideId)
            if overrideInfo then
                -- Debug: Log when an override is found
                -- print("|cffff00ffDF Override:|r " .. tostring(baseSpellId) .. " -> " .. tostring(overrideId) .. " (" .. tostring(overrideInfo.name) .. ")")
                displayName = overrideInfo.name or displayName
                displayIcon = overrideInfo.iconID
            end
        end
    end
    
    -- If no override or no icon yet, get from base spell
    if not displayIcon then
        if baseSpellId then
            local spellInfo = C_Spell.GetSpellInfo(baseSpellId)
            if spellInfo then
                displayIcon = spellInfo.iconID
                if not displayName then
                    displayName = spellInfo.name
                end
            end
        elseif baseSpellName then
            displayIcon = C_Spell.GetSpellTexture(baseSpellName)
        end
    end
    
    return displayName, displayIcon, displaySpellId
end

-- Export to CC namespace for use in UI files
CC.GetSpellDisplayInfo = GetSpellDisplayInfo

-- Resolve the display icon (texture path or fileID) for a binding. Single
-- source of truth for the action-type -> icon chain, shared by the full
-- binding row (BindingEditor) and the collapsed row (Main). Always returns a
-- texture; unknown/broken bindings get the question mark.
function CC:GetBindingDisplayIcon(binding)
    local QM = "Interface\\Icons\\INV_Misc_QuestionMark"
    if binding.actionType == "target" then
        return "Interface\\CURSOR\\Crosshairs"
    elseif binding.actionType == "menu" then
        return "Interface\\Buttons\\UI-GuildButton-OfficerNote-Up"
    elseif binding.actionType == "focus" then
        return "Interface\\Icons\\Ability_Hunter_MasterMarksman"
    elseif binding.actionType == "assist" then
        return "Interface\\Icons\\Ability_Hunter_SniperShot"
    elseif binding.actionType == CC.ACTION_TYPES.ITEM then
        if binding.itemType == "slot" and binding.itemSlot then
            local itemInfo = CC:GetSlotItemInfo(binding.itemSlot)
            if itemInfo and itemInfo.icon then
                return itemInfo.icon
            end
            for _, slotData in ipairs(CC.EQUIPMENT_SLOTS) do
                if slotData.slot == binding.itemSlot then
                    return slotData.icon
                end
            end
            return QM
        elseif binding.itemId then
            local itemInfo = CC:GetItemInfoById(binding.itemId)
            return (itemInfo and itemInfo.icon) or QM
        end
        return QM
    elseif binding.actionType == "macro" and binding.macroId then
        local macro = CC:GetMacroById(binding.macroId)
        if macro then
            -- Try to auto-detect icon from macro body first
            local autoIcon = CC:GetIconFromMacroBody(macro.body)
            if autoIcon then
                return autoIcon
            elseif macro.icon and type(macro.icon) == "number" and macro.icon > 0 then
                return macro.icon
            end
        end
        return QM
    elseif binding.spellId or binding.spellName then
        -- Current display icon (accounts for talent overrides like
        -- Divine Toll -> Holy Armaments)
        local _, displayIcon = GetSpellDisplayInfo(binding.spellId, binding.spellName)
        return displayIcon or QM
    end
    return QM
end

-- (Removed) CC:MigrateBindingsToRootSpells — the one-time rewrite of saved
-- bindings to root spell ids. It guarded on DandersFrames_ClickCastDB, a
-- global that never existed (the real DB is DandersFramesClickCastingDB), so
-- it silently no-opped for every user since it shipped. Superseded anyway:
-- root/override resolution happens live at bind time via C_Spell.GetBaseSpell
-- / GetOverrideSpell (see trueRootId below), so stored ids no longer need a
-- one-shot rewrite.

-- Check if a binding should be active based on load conditions
function CC:ShouldBindingLoad(binding)
    -- Per-spec click casting is done via loadout-assigned profiles. The old
    -- per-binding loadSpec field was config no UI ever wrote (import-only),
    -- and reading GetSpecialization() here made the binding list silently
    -- wrong whenever spec data was not resolved yet (cold login) -- retired
    -- in favor of the profile system.
    --
    -- Combat conditions are checked dynamically via state drivers / macro
    -- conditionals, not here.
    return not not binding.enabled
end

-- Every modifier prefix combination we ever write, in SecureActionButtonTemplate
-- canonical order (alt-ctrl-shift-meta). Shared by the clear paths; the apply
-- path derives prefixes per binding via BuildModifierPrefix.
local MODIFIER_COMBOS = {
    "alt-", "ctrl-", "shift-", "meta-",
    "alt-ctrl-", "alt-shift-", "alt-meta-", "ctrl-shift-", "ctrl-meta-", "shift-meta-",
    "alt-ctrl-shift-", "alt-ctrl-meta-", "alt-shift-meta-", "ctrl-shift-meta-",
    "alt-ctrl-shift-meta-",
}

-- Clear all click-cast bindings from a frame
-- preserveSnippet: keep the frame's existing dfBindingSnippet instead of
-- wiping it. Batched applies (ApplyBindings) pass their skipKeyboardUpdate
-- through here: the batch rebuilds every snippet in one RefreshKeyboardBindings
-- at the end, so wiping per-frame up front only created a window where combat
-- could interrupt the batch and strand EVERY processed frame with an empty
-- snippet — keyboard binds dead for the whole fight (field case 2026-07-20,
-- LFR: a roster-driven reapply was cut off by a pull; ~40 raid frames sat
-- snippet-less until combat end). Keeping the previous snippet is safe: it is
-- either identical (rescan/roster reapply, the common case) or one refresh
-- behind (profile switch), and the batch-end rebuild — deferred to combat end
-- if interrupted — overwrites it either way.
function CC:ClearBindingsFromFrame(frame, preserveSnippet)
    if not frame then return end
    -- Combat-safe by contract: only reached from ApplyBindingsToFrameUnified,
    -- which defers "bindingRefresh". Do not add a bare return here without one.
    if InCombatLockdown() then return end

    -- Check if this frame is currently being hovered
    local isCurrentlyHovered = (self.currentHoveredFrame == frame) or (frame.IsMouseOver and frame:IsMouseOver())

    -- Debug: warn if clearing bindings on a hovered frame
    local frameName = frame:GetName() or "unnamed"
    if isCurrentlyHovered then
        DF:DebugWarn("CLICK", "ClearBindings on HOVERED frame %s (preserving snippet/overrides)", frameName)
    else
        DF:Debug("CLICK", "ClearBindings %s", frameName)
    end

    -- Clear the binding snippet used by secure handlers
    -- BUT: if frame is currently hovered, DON'T clear - we want to preserve bindings
    if not isCurrentlyHovered and not preserveSnippet then
        frame:SetAttribute("dfBindingSnippet", "")
    end
    
    -- Clear any bindings set by secure handlers (SetBindingClick style)
    -- BUT: if frame is currently hovered, DON'T clear
    if frame.ClearBindings and not isCurrentlyHovered then
        pcall(function() frame:ClearBindings() end)
    end
    
    -- Clear exactly the attributes the last apply wrote (see WriteAttr).
    -- type attributes are cleared to "": a nil type lets the click fall
    -- through to wildcard *type<N> attributes or Blizzard's native
    -- interaction bindings, while an empty string suppresses both. Everything
    -- else clears to nil. The caller (ApplyBindingsToFrameUnified) rewrites
    -- current bindings right after, and its uncovered-base-button pass
    -- restores target/togglemenu defaults on non-DandersFrames.
    if frame.dfWrittenAttrs then
        for attr, kind in pairs(frame.dfWrittenAttrs) do
            if kind == "type" then
                frame:SetAttribute(attr, "")
            else
                frame:SetAttribute(attr, nil)
            end
        end
        frame.dfWrittenAttrs = nil
    end

    -- BUG #10 / #860 FIX: Unregister any combat-conditional attribute drivers.
    if frame.dfAttrDriverList then
        for _, attr in ipairs(frame.dfAttrDriverList) do
            UnregisterAttributeDriver(frame, attr)
        end
        frame.dfAttrDriverList = nil
    end

    -- 12.0.7 gate workaround: clear proxy click-action routes + proxy drivers.
    self:ClearClickProxyRoutes(frame)

    -- Also clear any existing override bindings on this frame (but not if hovered)
    if not isCurrentlyHovered then
        pcall(function() ClearOverrideBindings(frame) end)
    end
end

-- Last-resort full attribute scrub. The normal clear paths walk the
-- dfWrittenAttrs manifest; this sweeps every modifier/button combination we
-- could ever have written, for recovery when the manifest is suspected wrong
-- (it is plain Lua bookkeeping, so that means a code bug -- but binding state
-- has burned us enough times to keep the escape hatch). Reached only from
-- /dfccglobal scrub; NOT from the automatic repair path, because a scrub
-- without an immediate reapply strips every mouse binding on the frame.
function CC:ScrubAllClickAttributes(frame)
    if not frame or InCombatLockdown() then return end
    local combos = { "" }
    for _, m in ipairs(MODIFIER_COMBOS) do combos[#combos + 1] = m end
    for _, mod in ipairs(combos) do
        for btn = 1, 5 do
            frame:SetAttribute(mod .. "type" .. btn, nil)
            frame:SetAttribute(mod .. "spell" .. btn, nil)
            frame:SetAttribute(mod .. "macro" .. btn, nil)
            frame:SetAttribute(mod .. "macrotext" .. btn, nil)
            frame:SetAttribute(mod .. "unit" .. btn, nil)
            frame:SetAttribute(mod .. "clickbutton" .. btn, nil)
        end
    end
    -- The numeric sweep above only reaches <mod>type1..5 style mouse slots.
    -- Keyboard and scroll binds live in NAMED slots (type-<vbtn>,
    -- macrotext-<vbtn>, unit-<vbtn>, clickbutton-<vbtn>) whose names cannot be
    -- enumerated, so the manifest is the only record of them. Clearing it before
    -- discarding it matters: dropping the manifest first ORPHANED those
    -- attributes, leaving them set with no record for any later clear to find --
    -- precisely the state this last-resort escape hatch exists to undo.
    if frame.dfWrittenAttrs then
        for attr in pairs(frame.dfWrittenAttrs) do
            frame:SetAttribute(attr, nil)
        end
    end
    frame.dfWrittenAttrs = nil
    -- And the hover-key snippet, which is where keyboard binds are actually
    -- applied from; leaving it set meant the next hover re-applied them.
    frame:SetAttribute("dfBindingSnippet", "")
    if frame.dfAttrDriverList then
        for _, attr in ipairs(frame.dfAttrDriverList) do
            UnregisterAttributeDriver(frame, attr)
        end
        frame.dfAttrDriverList = nil
    end
    self:ClearClickProxyRoutes(frame)
    pcall(ClearOverrideBindings, frame)
end

-- Restore Blizzard default click behavior to a frame
function CC:RestoreBlizzardDefaults(frame)
    if not frame then return end
    -- Combat-safe by contract: callers (ApplyBindingsToFrameUnified,
    -- UnregisterFrame) defer on our behalf.
    if InCombatLockdown() then return end
    
    -- 12.0.7 gate workaround: drop any proxy click-action routes too.
    self:ClearClickProxyRoutes(frame)

    -- Clear exactly the attributes the last apply wrote (see WriteAttr).
    -- nil semantics here (not ""): the base type1/type2 defaults are written
    -- right below, and everything else should fall back to Blizzard behavior.
    if frame.dfWrittenAttrs then
        -- The recorded kind is irrelevant here: handing the frame back means
        -- everything we wrote goes to nil, so the frame's own behaviour
        -- (restored below) and Blizzard's wildcards apply again.
        for attr in pairs(frame.dfWrittenAttrs) do
            frame:SetAttribute(attr, nil)
        end
        frame.dfWrittenAttrs = nil
    end

    -- Unregister any frame-side combat-conditional drivers. The old sweep
    -- missed these (only ClearBindingsFromFrame handled them), so a driver
    -- could rewrite its type attribute on the next combat transition after
    -- the frame was restored.
    if frame.dfAttrDriverList then
        for _, attr in ipairs(frame.dfAttrDriverList) do
            UnregisterAttributeDriver(frame, attr)
        end
        frame.dfAttrDriverList = nil
    end

    -- Clear override bindings
    ClearOverrideBindings(frame)
    
    -- Clear the binding snippet so OnEnter won't apply any bindings
    frame:SetAttribute("dfBindingSnippet", "")
    
    -- Undo the modified-click suppression from ClearBlizzardClickCastFromFrame.
    -- Those writes are deliberately NOT in the manifest (they belong to the
    -- Blizzard-click-cast lifecycle, not to a binding apply, and manifesting
    -- them would let a routine apply drop the suppression mid-session), so the
    -- manifest walk above cannot reach them. Without this, every
    -- <modifier>-type1/type2 stayed "" after unregistering and modified clicks
    -- on Blizzard's frames kept doing nothing -- no fall-through to the
    -- wildcard *type attributes or to Blizzard's own click-casting -- until a
    -- reload.
    for _, mod in ipairs(CC.BLIZZARD_SUPPRESSED_MODIFIERS) do
        frame:SetAttribute(mod .. "type1", nil)
        frame:SetAttribute(mod .. "type2", nil)
    end

    -- Put back what the frame actually had, not what we assume it had.
    -- ClearBlizzardClickCastFromFrame captures type1/type2/*type1/*type2 once
    -- before the first takeover; a table means the capture succeeded, `false`
    -- means the client returned secret values and we fall back to Blizzard's
    -- stock behaviour. Restoring the capture matters for third-party unit frames,
    -- which may intentionally have no left-click target -- hardcoding
    -- target/togglemenu rewrote their click behaviour permanently after one
    -- register/unregister cycle.
    local orig = frame.dfOriginalClickBindings
    if type(orig) == "table" then
        frame:SetAttribute("type1", orig.type1)
        frame:SetAttribute("type2", orig.type2)
        frame:SetAttribute("*type1", orig.starType1)
        frame:SetAttribute("*type2", orig.starType2)
    else
        -- type1 = left click = target, type2 = right click = togglemenu
        frame:SetAttribute("type1", "target")
        frame:SetAttribute("type2", "togglemenu")
    end
    
    -- Reset to standard click registration (AnyUp is default)
    if frame.RegisterForClicks then
        frame:RegisterForClicks("AnyUp")
    end
end

-- Apply bindings to a single frame
-- Check if a binding should apply to a specific frame based on frames checkboxes
function CC:ShouldBindingApplyToFrame(binding, frame)
    if not binding or not frame then return false end
    
    -- Get frames settings (with defaults for backwards compatibility)
    local frames = binding.frames or { dandersFrames = true, otherFrames = true }
    
    -- Determine if this is a DandersFrames frame or an "other" frame
    -- DandersFrames = frames created by our addon (marked with dfIsDandersFrame)
    -- Other frames = Blizzard frames AND third-party addon frames
    local isDandersFrame = frame.dfIsDandersFrame == true
    
    -- Check if binding applies to this frame type
    if isDandersFrame then
        return frames.dandersFrames == true
    else
        return frames.otherFrames == true
    end
end

-- Apply bindings to all registered frames
-- Non-pinned frames are applied immediately.
-- Pinned frames are deferred to avoid "script ran too long" errors,
-- since each frame requires ~500 SetAttribute calls to clear+reapply bindings
-- and highlight headers pre-create up to 40 frames each (80 total).
function CC:ApplyBindings()
    -- MEMORY TEST (enableClickCastApplyBindings): a full rebuild is ~500
    -- SetAttribute calls per frame across up to 80 frames, so it is worth
    -- isolating. Bindings already applied stay live — this stops the REBUILD,
    -- which is the cost being measured.
    if DF:MemTestDisabled("enableClickCastApplyBindings") then return end
    if InCombatLockdown() then
        self:Defer("bindingRefresh")
        return
    end

    -- Cancel any pending batch binding pass from a previous call
    if self.batchBindingTimer then
        self.batchBindingTimer:Cancel()
        self.batchBindingTimer = nil
    end

    -- Hover keyboard/scroll binds are owned by the click-cast header, so a
    -- full rebuild starts by wiping the header's override bindings — any
    -- bind from the outgoing set that is still active (e.g. the user is
    -- hovering a frame right now) would otherwise survive with its OLD
    -- action until the next leave/enter cycle. The next OnEnter re-applies
    -- from the freshly built snippets.
    if self.header then
        pcall(ClearOverrideBindings, self.header)
    end
    
    -- Migrate existing macro bindings to have no fallbacks
    if self.db and self.db.bindings then
        for _, binding in ipairs(self.db.bindings) do
            if binding.actionType == "macro" or binding.macroId then
                -- Force macros to have no fallbacks
                binding.fallback = {
                    mouseover = false,
                    target = false,
                    selfCast = false,
                }
            end
        end
    end
    
    -- Build unified macro map (all bindings converted to macros)
    self.unifiedMacroMap = self:BuildUnifiedMacroMap()

    -- Set up hovercast button attributes for third-party frame support
    self:SetupHovercastButtonAttributes()

    -- IMPORTANT: Clear Blizzard click-casting BEFORE applying our bindings
    -- This ensures our bindings take precedence and aren't overwritten
    if self.db.enabled then
        self:RefreshBlizzardClickCastClearing()
    end

    -- Apply bindings to all registered frames in batches to avoid "script ran too long".
    -- With ElvUI or other addons, 100-150+ frames can be registered. Each frame requires
    -- ~300+ SetAttribute calls, so processing them all synchronously exceeds Lua's time limit.
    -- Frames are processed in batches of 10 with a yield between each batch.
    do
        local allFrames = {}
        if self.registeredFrames then
            for frame in pairs(self.registeredFrames) do
                allFrames[#allFrames + 1] = frame
            end
        end

        if #allFrames > 0 then
            local BATCH_SIZE = 10
            local batchIndex = 0

            local function ProcessNextBatch()
                if InCombatLockdown() then
                    -- Combat started during batch - flag for retry after combat
                    CC:Defer("bindingRefresh")
                    CC.batchBindingTimer = nil
                    return
                end

                local startIdx = batchIndex * BATCH_SIZE + 1
                local endIdx = math.min(startIdx + BATCH_SIZE - 1, #allFrames)

                for i = startIdx, endIdx do
                    CC:ApplyBindingsToFrameUnified(allFrames[i], true)
                end

                batchIndex = batchIndex + 1

                if endIdx < #allFrames then
                    -- More batches to process
                    CC.batchBindingTimer = C_Timer.NewTimer(0, ProcessNextBatch)
                else
                    -- All frames processed - refresh keyboard bindings once for all frames
                    CC.batchBindingTimer = nil
                    CC:RefreshKeyboardBindings()
                    -- The header wipe above kills a live hover; put it straight back.
                    CC:ReassertHoverBinds()
                end
            end

            -- Process first batch immediately (synchronous), defer the rest
            ProcessNextBatch()
        else
            -- Nothing registered, so there are no per-frame snippets to rewrite.
            -- The map has still just been rebuilt though, and RefreshKeyboardBindings
            -- is what makes a rebuilt map visible; with the only call site at the
            -- tail of the batch walker, this path did nothing at all. Cheap here
            -- (it iterates an empty registry) and keeps "ApplyBindings always
            -- leaves keyboard state consistent with the map" true on every path.
            self:RefreshKeyboardBindings()
            self:ReassertHoverBinds()
        end
    end

    -- Apply global bindings (hovercast and global scopes)
    self:ApplyGlobalBindings()
end

-- ============================================================

-- GLOBAL BINDING SUPPORT (On Hover & Global Scopes)
-- ============================================================

-- Pool of secure action buttons for global bindings

-- ============================================================

-- HOVERCAST GLOBAL BUTTON (Exact Clique-style approach)
-- ============================================================

-- Create the single global button used for all hovercast bindings
function CC:CreateHovercastButton()
    if self.hovercastButton then return end
    
    -- Don't create during combat. Keep retrying while combat lasts: the old
    -- single 1s retry gave up silently if combat was still active, leaving
    -- the hovercast button uncreated for the rest of the session.
    if InCombatLockdown() then
        CC:DeferAfter("createHovercastButton", 1, function()
            CC:CreateHovercastButton()
        end)
        return
    end
    
    -- Create the button with BOTH templates like Clique does
    -- SecureActionButtonTemplate provides the action execution
    -- SecureHandlerBaseTemplate provides Execute() for secure snippets
    local success = pcall(function()
        self.hovercastButton = CreateFrame("Button", "DFHovercastButton", UIParent, "SecureActionButtonTemplate, SecureHandlerBaseTemplate")
    end)
    
    if not success or not self.hovercastButton then
        -- Fallback: try without SecureHandlerBaseTemplate
        success = pcall(function()
            self.hovercastButton = CreateFrame("Button", "DFHovercastButton", UIParent, "SecureActionButtonTemplate")
        end)
    end
    
    if not success or not self.hovercastButton then
        DF:Say("Warning: Could not create hovercast button", nil, "WARN")
        return
    end
    
    self.hovercastButton:SetSize(1, 1)
    self.hovercastButton:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -100, -100)
    self.hovercastButton:Show()
    self.hovercastButton:EnableMouse(false)
    
    -- Register for BOTH down and up clicks to work regardless of ActionButtonUseKeyDown CVar
    -- This ensures the button receives the click whether WoW is set to fire on key down or key up
    self.hovercastButton:RegisterForClicks("AnyDown", "AnyUp")
    
    -- Debug hooks to see if button receives clicks
    -- These two are installed unconditionally at button creation, so they gate on
    -- the console category directly rather than on an armed flag.
    self.hovercastButton:HookScript("PreClick", function(btn, mouseButton, isDown)
        if not DF:DebugActive("CLICK") then return end
        DF:Debug("CLICK", "Hovercast PreClick: button=%s isDown=%s type-%s=%s macrotext-%s=%s",
            tostring(mouseButton), tostring(isDown),
            tostring(mouseButton), tostring(btn:GetAttribute("type-" .. (mouseButton or ""))),
            tostring(mouseButton), tostring((btn:GetAttribute("macrotext-" .. (mouseButton or "")) or ""):sub(1, 50)))
    end)

    self.hovercastButton:HookScript("PostClick", function(btn, mouseButton, isDown)
        DF:Debug("CLICK", "Hovercast PostClick: button=%s isDown=%s", tostring(mouseButton), tostring(isDown))
    end)
end

-- Set up the hovercast button with spell attributes for third-party frame click casting
-- This is called after bindings are built so the hovercast button can handle redirected clicks
function CC:SetupHovercastButtonAttributes()
    if not self.hovercastButton then return end
    -- Combat-safe by contract: only reached from ApplyBindings, which defers.
    if InCombatLockdown() then return end
    
    local btn = self.hovercastButton
    
    -- Clear existing attributes
    for i = 1, 5 do
        btn:SetAttribute("type" .. i, nil)
        btn:SetAttribute("spell" .. i, nil)
        btn:SetAttribute("macrotext" .. i, nil)
    end
    
    if not self.unifiedMacroMap then return end
    
    -- Set up attributes for each mouse binding
    for keyString, data in pairs(self.unifiedMacroMap) do
        local binding = data.templateBinding
        local bindType = binding.bindType or "mouse"
        
        if bindType == "mouse" and binding.button then
            local virtualBtn = self:GetVirtualButtonName(binding)
            local actionType = binding.actionType or self.ACTION_TYPES.SPELL
            
            -- Check if this should be treated as a special action
            local isSpecialAction = data.isSpecialAction
            if isSpecialAction == nil then
                isSpecialAction = (actionType == "menu" or actionType == "target" or 
                                   actionType == "focus" or actionType == "assist" or
                                   actionType == self.ACTION_TYPES.MENU or 
                                   actionType == self.ACTION_TYPES.FOCUS or
                                   actionType == self.ACTION_TYPES.ASSIST)
            end
            
            if isSpecialAction then
                if actionType == "menu" or actionType == self.ACTION_TYPES.MENU then
                    local typeAttr = "type-" .. virtualBtn
                    btn:SetAttribute(typeAttr, "togglemenu")
                    -- BUG #10 FIX: state-driver-based combat conditional
                    local combatCond = GetCombatCondition(binding)
                    if combatCond then
                        AddCombatConditional(btn, typeAttr, "togglemenu", combatCond)
                    end
                elseif actionType == "target" then
                    local typeAttr = "type-" .. virtualBtn
                    btn:SetAttribute(typeAttr, "target")
                    -- BUG #860 FIX: state-driver-based combat conditional
                    local combatCond = GetCombatCondition(binding)
                    if combatCond then
                        AddCombatConditional(btn, typeAttr, "target", combatCond)
                    end
                elseif actionType == "focus" or actionType == self.ACTION_TYPES.FOCUS then
                    btn:SetAttribute("type-" .. virtualBtn, "focus")
                elseif actionType == "assist" or actionType == self.ACTION_TYPES.ASSIST then
                    btn:SetAttribute("type-" .. virtualBtn, "assist")
                end
            else
                -- Use macro for all spell/macro bindings
                -- This supports smart res, combat conditionals, fallbacks, etc.
                btn:SetAttribute("type-" .. virtualBtn, "macro")
                btn:SetAttribute("macrotext-" .. virtualBtn, data.macroText)
            end
        end
    end
end

-- Get the suffix for a binding (like Clique's GetBindingPrefixSuffix)
-- For global bindings, returns something like "dfbuttonshiftf" or "dfmouseshift3"
function CC:GetHovercastSuffix(binding)
    local keyString = self:GetBindingKeyString(binding)
    if not keyString then return nil end
    
    -- Parse out modifiers and key
    local mods, key
    
    -- Special case: minus key (conflicts with modifier separator)
    if keyString == "-" then
        key = "-"
        mods = ""
    elseif keyString:sub(-2) == "--" then
        -- Modifier(s) + minus key (e.g., "SHIFT--", "CTRL-ALT--")
        key = "-"
        mods = keyString:sub(1, -3)  -- Strip the trailing "--"
    else
        -- Normal parsing for all other keys
        mods, key = keyString:match("^(.-)([^%-]+)$")
        if mods and mods:sub(-1, -1) == "-" then
            mods = mods:sub(1, -2)
        end
    end
    
    -- Safety check in case parsing still fails
    if not key then return nil end
    
    -- Normalize modifiers (lowercase, no separators)
    local modKey = (mods or ""):lower():gsub("[%-]", "")
    
    -- Check if it's a mouse button
    local buttonNum = key:match("^BUTTON(%d+)$")
    if buttonNum then
        -- Mouse button
        return "dfmouse" .. modKey .. buttonNum
    else
        -- Keyboard/scroll key. EncodeKeyToken: identical to the old :lower()
        -- for alphanumeric keys; international and punctuation keys get an
        -- ASCII-safe encoding so their bytes never enter attribute names
        -- (bug #977).
        return "dfbutton" .. modKey .. self:EncodeKeyToken(key)
    end
end

-- Build the setup script that sets both attributes AND bindings
-- This is the key insight from Clique: everything happens in one Execute() call
function CC:BuildHovercastSetupScript()
    local lines = {
        "local button = self",  -- Reference to the button
    }
    local clearLines = {
        "local button = self",  -- Must also define button in clear script!
    }
    
    -- Use the unified macro map
    if not self.unifiedMacroMap then
        self.unifiedMacroMap = self:BuildUnifiedMacroMap()
        -- Refresh keyboard bindings on all frames since map was just built
        self:RefreshKeyboardBindings()
    end
    
    -- Track unique bindings to avoid duplicates
    local uniqueKeys = {}
    
    for keyString, data in pairs(self.unifiedMacroMap) do
        local binding = data.templateBinding
        -- Use globalMacroText for global bindings (respects fallback settings only)
        local macroText = data.globalMacroText or data.macroText
        
        if binding.enabled ~= false and macroText then
            -- Check if binding explicitly needs global/onhover handling
            local scope = binding.scope or "unitframes"
            local needsGlobal = (scope == "onhover" or scope == "global")
            
            -- ALSO need global hovercast if binding has mouseover, target or self fallbacks
            -- These fallbacks only work when NOT hovering a frame, so we need
            -- the key binding to be active globally, not just when hovering
            local fallback = binding.fallback or {}
            -- alwaysCast needs the key active everywhere too — its whole point
            -- is casting while hovering nothing (bug #991)
            local hasFallbackThatNeedsGlobal = fallback.mouseover or fallback.target or fallback.selfCast or fallback.alwaysCast
            
            -- Check for useGlobalBind flag (for items/macros that need to work everywhere)
            local hasGlobalBindFlag = binding.useGlobalBind == true
            
            -- For unitframes scope with target/self fallbacks, we need BOTH:
            -- 1. Frame-specific bindings (handled by WrapScript OnEnter)
            -- 2. Global bindings (for when not hovering any frame)
            
            if needsGlobal or hasFallbackThatNeedsGlobal or hasGlobalBindFlag then
                if self:ShouldBindingLoad(binding) then
                    local suffix = self:GetHovercastSuffix(binding)
                    
                    if keyString and suffix and keyString ~= "" then
                        -- Skip unmodified left/right click (would break normal clicking)
                        if keyString ~= "BUTTON1" and keyString ~= "BUTTON2" then
                            if not uniqueKeys[keyString] then
                                uniqueKeys[keyString] = true
                                
                                -- Set the macro attributes
                                table.insert(lines, string.format(
                                    [[button:SetAttribute("type-%s", "macro")]],
                                    suffix
                                ))
                                table.insert(lines, string.format(
                                    [[button:SetAttribute("macrotext-%s", %q)]],
                                    suffix, macroText
                                ))
                                
                                -- Add clear commands
                                table.insert(clearLines, string.format([[button:SetAttribute("type-%s", nil)]], suffix))
                                table.insert(clearLines, string.format([[button:SetAttribute("macrotext-%s", nil)]], suffix))
                                
                                -- Now add the SetBindingClick call
                                -- Note: SetBindingClick needs frame NAME (string), not frame reference
                                table.insert(lines, string.format(
                                    [[self:SetBindingClick(true, %q, button:GetName(), %q)]],
                                    keyString, suffix
                                ))
                                
                                -- Add clear binding
                                table.insert(clearLines, string.format(
                                    [[self:ClearBinding(%q)]],
                                    keyString
                                ))
                            end
                        end
                    end
                end
            end
        end
    end
    
    return table.concat(lines, "\n"), table.concat(clearLines, "\n")
end

-- Apply global keybindings (for "onhover" and "targetcast" scopes)
-- Uses exact Clique-style approach: Execute() to set both attributes and bindings
function CC:ApplyGlobalBindings()
    -- Reached unguarded from PLAYER_ENTERING_WORLD, so defer rather than drop:
    -- ApplyBindings() re-runs this as part of the refresh.
    if self:CombatGuard("bindingRefresh") then return end
    
    if not self.db or not self.db.enabled then 
        self:ClearGlobalBindings()
        return 
    end
    
    -- Create the hovercast button if needed
    self:CreateHovercastButton()
    
    if not self.hovercastButton then
        DF:Err("Failed to create on hover button")
        return
    end
    
    -- First clear any existing bindings
    self:ClearGlobalBindings()
    
    -- Build the setup and clear scripts
    local setupScript, clearScript = self:BuildHovercastSetupScript()
    
    -- Store the clear script for later
    self.hovercastButton.clearScript = clearScript
    self.hovercastButton.setupScript = setupScript
    
    -- Execute the setup script to set all the bindings
    -- This runs in a secure environment where SetBindingClick is allowed
    if setupScript and setupScript ~= "" and setupScript ~= "local button = self" then
        -- Check if Execute is available
        if not self.hovercastButton.Execute then
            DF:Debug("CLICK", "OnHover: hovercast button missing Execute method")
        else
            -- Use pcall in case secure handler isn't working
            local execSuccess = pcall(function()
                self.hovercastButton:Execute(setupScript)
            end)
            
            if not execSuccess then
                DF:Say("Warning: Could not execute hovercast setup script", nil, "WARN")
            end
            
            if execSuccess and DF:DebugActive("CLICK") then
                local count = 0
                for line in setupScript:gmatch("[^\n]+") do
                    if line:find("SetBindingClick") then
                        count = count + 1
                    end
                end
                DF:Debug("CLICK", "OnHover: executed setup script, set %d bindings via Execute()\n%s",
                    count, setupScript)
            end
        end
    else
        DF:Debug("CLICK", "OnHover: no onhover bindings to set")
    end
end

-- Clear all global bindings
function CC:ClearGlobalBindings()
    -- Combat-safe by contract: only reached from ApplyGlobalBindings, which defers.
    if InCombatLockdown() then return end
    
    -- Clear using the hovercast button's Execute
    if self.hovercastButton and self.hovercastButton.Execute and self.hovercastButton.clearScript and self.hovercastButton.clearScript ~= "" then
        pcall(function()
            self.hovercastButton:Execute(self.hovercastButton.clearScript)
        end)
    end
    
end

-- Encode a captured key name into an ASCII-only token for use inside derived
-- names (virtual mouse button names -> secure attribute names). Keys from
-- non-US keyboard layouts (æ, ø, å, ñ, ü, ...) arrive from OnKeyDown as
-- multibyte UTF-8; embedding those raw bytes in attribute names is the one
-- structural difference between this pipeline and the systems that handle
-- such keys correctly (Blizzard's own bindings, Dominos, EllesmereUI — none
-- of which put key characters into derived names). The BINDING key itself is
-- always passed byte-exact as captured; only derived names go through this.
-- a-z / 0-9 pass through and A-Z lowercases, so alphanumeric keys (the vast
-- majority) produce the identical name the old :lower() did. Every other
-- byte — multibyte sequences AND ASCII punctuation — becomes "_" plus its
-- zero-padded byte value: fixed width, so two distinct keys can never encode
-- to the same token. Punctuation is deliberately encoded too: characters
-- like "*" carry wildcard meaning in secure attribute names, so raw
-- punctuation in a derived name was never safe either. (bug #977)
function CC:EncodeKeyToken(key)
    return (tostring(key or ""):gsub(".", function(c)
        local b = c:byte()
        if (b >= 97 and b <= 122) or (b >= 48 and b <= 57) then
            return c                            -- a-z, 0-9 unchanged
        elseif b >= 65 and b <= 90 then
            return string.char(b + 32)          -- A-Z -> a-z (legacy casing)
        end
        return string.format("_%03d", b)        -- everything else: byte-encoded
    end))
end

-- Get the WoW key string for a binding
function CC:GetBindingKeyString(binding)
    local key = ""
    
    -- Add modifiers in WoW's expected order: ALT-CTRL-SHIFT-META
    if binding.modifiers then
        local mods = binding.modifiers:upper()
        if mods:find("ALT") then key = key .. "ALT-" end
        if mods:find("CTRL") then key = key .. "CTRL-" end
        if mods:find("SHIFT") then key = key .. "SHIFT-" end
        if mods:find("META") then key = key .. "META-" end
    end
    
    -- Add the actual key
    if binding.bindType == "mouse" then
        if not binding.button then return nil end
        -- Convert mouse button names to WoW binding format
        local buttonMap = {
            ["LeftButton"] = "BUTTON1",
            ["RightButton"] = "BUTTON2",
            ["MiddleButton"] = "BUTTON3",
            ["Button4"] = "BUTTON4",
            ["Button5"] = "BUTTON5",
        }
        -- Check for Button6-Button31 (gaming mice)
        local mapped = buttonMap[binding.button]
        if not mapped then
            local num = binding.button:match("Button(%d+)")
            if num then
                mapped = "BUTTON" .. num
            else
                mapped = binding.button:upper():gsub("BUTTON", "BUTTON")
            end
        end
        key = key .. mapped
    elseif binding.bindType == "scroll" then
        -- Scroll wheel
        if binding.key == "SCROLLUP" then
            key = key .. "MOUSEWHEELUP"
        elseif binding.key == "SCROLLDOWN" then
            key = key .. "MOUSEWHEELDOWN"
        else
            return nil
        end
    else
        -- Keyboard key
        if not binding.key then return nil end
        key = key .. binding.key
    end
    
    return key
end

-- ============================================================

-- BINDING MANAGEMENT API
-- ============================================================

-- Check if a duplicate binding already exists
-- Returns the index of the duplicate if found, nil otherwise
function CC:FindDuplicateBinding(newBinding, excludeIndex)
    if not self.db or not self.db.bindings then return nil end
    
    for i, existing in ipairs(self.db.bindings) do
        -- Skip the binding we're editing
        if i ~= excludeIndex then
            -- Check if it's the same key combo
            local sameKey = false
            if newBinding.bindType == "mouse" and existing.bindType == "mouse" then
                sameKey = (newBinding.button == existing.button)
            elseif (newBinding.bindType == "key" or newBinding.bindType == "scroll") and 
                   (existing.bindType == "key" or existing.bindType == "scroll") then
                sameKey = (newBinding.key == existing.key)
            end
            
            -- Check if same modifiers
            local sameMods = (newBinding.modifiers or "") == (existing.modifiers or "")
            
            -- Check if same action/spell
            local sameAction = false
            if newBinding.actionType == existing.actionType then
                if newBinding.actionType == CC.ACTION_TYPES.SPELL then
                    -- For spells, check spell name or ID
                    sameAction = (newBinding.spellName and newBinding.spellName == existing.spellName) or
                                 (newBinding.spellId and newBinding.spellId == existing.spellId)
                elseif newBinding.actionType == CC.ACTION_TYPES.MACRO then
                    -- For macros, check macro ID or name
                    sameAction = (newBinding.macroId and newBinding.macroId == existing.macroId) or
                                 (newBinding.macroName and newBinding.macroName == existing.macroName)
                elseif newBinding.actionType == CC.ACTION_TYPES.ITEM then
                    -- For items, check item ID or slot
                    if newBinding.itemType == "slot" and existing.itemType == "slot" then
                        sameAction = (newBinding.itemSlot == existing.itemSlot)
                    else
                        sameAction = (newBinding.itemId and newBinding.itemId == existing.itemId)
                    end
                else
                    -- For other actions (target, menu, etc.), same type is enough
                    sameAction = true
                end
            end
            
            if sameKey and sameMods and sameAction then
                return i
            end
        end
    end
    
    return nil
end

-- Find bindings that use the same key combo but with different actions
-- Returns a table of conflicting bindings (not exact duplicates)
function CC:FindKeyConflicts(newBinding, excludeIndex)
    if not self.db or not self.db.bindings then return {} end
    
    local conflicts = {}
    
    for i, existing in ipairs(self.db.bindings) do
        -- Skip the binding we're editing
        if i ~= excludeIndex then
            -- Check if it's the same key combo
            local sameKey = false
            if newBinding.bindType == "mouse" and existing.bindType == "mouse" then
                sameKey = (newBinding.button == existing.button)
            elseif (newBinding.bindType == "key" or newBinding.bindType == "scroll") and 
                   (existing.bindType == "key" or existing.bindType == "scroll") then
                sameKey = (newBinding.key == existing.key)
            end
            
            -- Check if same modifiers
            local sameMods = (newBinding.modifiers or "") == (existing.modifiers or "")
            
            if sameKey and sameMods then
                table.insert(conflicts, {
                    index = i,
                    binding = existing
                })
            end
        end
    end
    
    return conflicts
end

-- Enable/disable click-casting
function CC:SetEnabled(enabled)
    -- Track whether the state is actually changing (callers may set db.enabled
    -- before calling this, so compare against the profile copy which is the
    -- last value committed by this function)
    local wasEnabled = self.profile and self.profile.options and self.profile.options.enabled

    self.db.enabled = enabled
    if self.profile and self.profile.options then
        self.profile.options.enabled = enabled
    end

    -- Update the header attribute so secure snippets know whether to run
    -- This is critical for allowing Clique/Clicked to work when we're disabled
    if self.header then
        if not InCombatLockdown() then
            self.header:SetAttribute("dfClickCastEnabled", enabled)
        end
    end

    -- Only prompt for reload when the state actually changes.
    -- Prevents a spurious reload popup on every login when the user has
    -- ignored the conflict warning (Clicked coexistence).
    if enabled ~= wasEnabled then
        DF:ShowPopupAlert({
            title   = L["Reload Required"],
            message = L["Click-casting changes require a UI reload to take effect.\n\nReload now?"],
            buttons = {
                { label = L["Reload"], onClick = function() ReloadUI() end },
                { label = L["Later"] },
            },
        })
    end
end

-- Check if click-casting is enabled
function CC:IsEnabled()
    return self.db.enabled
end

-- ============================================================

-- UTILITY FUNCTIONS
-- ============================================================

-- Get display string for a binding's key combination
function CC:GetBindingKeyText(binding, includeCombatState)
    if not binding then return "Unknown" end
    
    local parts = {}
    
    -- Add modifiers (they come in as "shift-ctrl-alt-" format)
    if binding.modifiers and binding.modifiers ~= "" then
        for mod in binding.modifiers:gmatch("(%w+)%-?") do
            table.insert(parts, mod:sub(1,1):upper() .. mod:sub(2))
        end
    end
    
    -- Add button/key based on bind type
    local bindType = binding.bindType or "mouse"
    local keyName
    
    if bindType == "key" then
        -- Keyboard binding
        local key = binding.key or "?"
        keyName = CC.KEY_DISPLAY_NAMES[key] or key
    elseif bindType == "scroll" then
        -- Scroll wheel binding
        local key = binding.key or "?"
        keyName = CC.SCROLL_DISPLAY_NAMES[key] or key
    else
        -- Mouse binding
        keyName = CC.BUTTON_DISPLAY_NAMES[binding.button] or binding.button
    end
    
    table.insert(parts, keyName)
    
    -- Use "+ " (with space) so text can wrap at + symbols
    local result = table.concat(parts, "+ ")
    
    -- Add combat state indicator if requested
    if includeCombatState then
        -- Fall back to legacy loadCombat for freshly-added bindings (pre profile-load migration)
        local combatSetting = binding.combat
            or (binding.loadCombat == "combat" and "incombat")
            or (binding.loadCombat == "nocombat" and "outofcombat")
            or "always"
        if combatSetting == "incombat" then
            result = result .. " [C]"
        elseif combatSetting == "outofcombat" then
            result = result .. " [OoC]"
        end
    end
    
    return result
end

-- Get display string for a binding's action (spell name, macro name, etc.)
function CC:GetBindingActionText(binding)
    if not binding then return "Unknown" end
    
    local actionType = binding.actionType
    
    if actionType == self.ACTION_TYPES.SPELL then
        return binding.spellName or "Unknown Spell"
    elseif actionType == self.ACTION_TYPES.MACRO then
        return binding.macroName or "Unknown Macro"
    elseif actionType == self.ACTION_TYPES.ITEM then
        return binding.itemName or "Unknown Item"
    elseif actionType == self.ACTION_TYPES.TARGET then
        return "Target Unit"
    elseif actionType == self.ACTION_TYPES.MENU then
        return "Open Menu"
    elseif actionType == self.ACTION_TYPES.FOCUS then
        return "Focus Unit"
    elseif actionType == self.ACTION_TYPES.FOLLOW then
        return "Follow Unit"
    elseif actionType == self.ACTION_TYPES.ASSIST then
        return "Assist Unit"
    else
        return actionType or "Unknown"
    end
end

-- Get display string for a binding
function CC:GetBindingDisplayString(binding)
    if not binding then return "Unknown" end
    
    local parts = {}
    
    -- Add modifiers (they come in as "shift-ctrl-alt-" format)
    if binding.modifiers and binding.modifiers ~= "" then
        for mod in binding.modifiers:gmatch("(%w+)%-?") do
            table.insert(parts, mod:sub(1,1):upper() .. mod:sub(2))
        end
    end
    
    -- Add button/key based on bind type
    local bindType = binding.bindType or "mouse"
    local keyName
    
    if bindType == "key" then
        local key = binding.key or "?"
        keyName = CC.KEY_DISPLAY_NAMES[key] or key
    elseif bindType == "scroll" then
        local key = binding.key or "?"
        keyName = CC.SCROLL_DISPLAY_NAMES[key] or key
    else
        keyName = CC.BUTTON_DISPLAY_NAMES[binding.button] or binding.button
    end
    
    table.insert(parts, keyName)
    
    return table.concat(parts, " + ")
end

-- Get display string for a binding's action
function CC:GetActionDisplayString(binding)
    if not binding then return "Unknown" end
    
    if binding.actionType == CC.ACTION_TYPES.SPELL then
        -- Get current display name (accounts for talent overrides)
        local displayName = GetSpellDisplayInfo(binding.spellId, binding.spellName)
        return displayName or binding.spellName or "No Spell"
    elseif binding.actionType == CC.ACTION_TYPES.MACRO then
        -- Try to get macro name from stored macro or binding
        if binding.macroId then
            local macro = CC:GetMacroById(binding.macroId)
            if macro then
                return macro.name
            end
        end
        return binding.macroName or "Macro"
    elseif binding.actionType == CC.ACTION_TYPES.ITEM then
        -- Item binding
        if binding.itemType == "slot" then
            return binding.itemName or "Slot " .. (binding.itemSlot or "?")
        else
            return binding.itemName or "Item"
        end
    elseif binding.actionType == CC.ACTION_TYPES.TARGET or binding.actionType == "target" then
        return "Target Unit"
    elseif binding.actionType == CC.ACTION_TYPES.MENU or binding.actionType == "menu" then
        return "Unit Menu"
    elseif binding.actionType == CC.ACTION_TYPES.FOCUS or binding.actionType == "focus" then
        return "Set Focus"
    elseif binding.actionType == CC.ACTION_TYPES.ASSIST or binding.actionType == "assist" then
        return "Assist"
    end
    
    return "Unknown"
end

-- Alias for GetBindingDisplayString
function CC:GetBindingDisplayText(binding)
    return self:GetBindingDisplayString(binding)
end

-- Get spell icon
function CC:GetSpellIcon(spellIdOrName)
    if not spellIdOrName then return nil end
    
    local spellInfo = C_Spell.GetSpellInfo(spellIdOrName)
    if spellInfo then
        return spellInfo.iconID
    end
    
    return nil
end

-- Auto-detect icon from macro body by finding spell names
function CC:GetIconFromMacroBody(macroBody)
    if not macroBody or macroBody == "" then return nil end
    
    -- Common patterns to find spell names in macros
    -- /cast SpellName
    -- /cast [conditions] SpellName
    -- /use SpellName
    -- #showtooltip SpellName
    
    local patterns = {
        "#showtooltip%s+([%w%s:']+)",          -- #showtooltip Spell Name
        "/cast%s+%[?[^%]]*%]?%s*([%w%s:']+)",  -- /cast [conditions] Spell Name
        "/use%s+%[?[^%]]*%]?%s*([%w%s:']+)",   -- /use [conditions] Spell Name
    }
    
    for _, pattern in ipairs(patterns) do
        local spellName = macroBody:match(pattern)
        if spellName then
            -- Clean up the spell name
            spellName = spellName:trim()
            -- Remove any trailing semicolons or conditions
            spellName = spellName:gsub(";.*$", ""):trim()
            spellName = spellName:gsub("%[.*$", ""):trim()
            
            if spellName ~= "" then
                local icon = self:GetSpellIcon(spellName)
                if icon then
                    return icon
                end
            end
        end
    end
    
    return nil
end

-- Close all macro-related dialogs
function CC:CloseAllMacroDialogs()
    if _G["DFMacroEditorDialog"] then _G["DFMacroEditorDialog"]:Hide() end
    if _G["DFImportMacroDialog"] then _G["DFImportMacroDialog"]:Hide() end
    if _G["DFQuickMacroDialog"] then _G["DFQuickMacroDialog"]:Hide() end
    if _G["DFIconPickerDialog"] then _G["DFIconPickerDialog"]:Hide() end
end

-- Get all player spells (for the spell grid)
function CC:GetAllPlayerSpells()
    local results = {}
    
    -- Track spells by displaySpellId, preferring "root" spells over override spells
    -- Root spells are those where baseSpellId != displaySpellId (they're being overridden)
    -- These are preferred because they always exist regardless of talents
    local spellsByDisplayId = {}  -- displaySpellId -> {spell data, isRoot}
    
    -- Get book type
    local bookType = Enum.SpellBookSpellBank.Player
    
    -- Get number of skill lines (tabs)
    local numTabs = C_SpellBook.GetNumSpellBookSkillLines()
    
    -- Get current spec name for identification
    local currentSpecIndex = GetSpecialization()
    local currentSpecName = currentSpecIndex and select(2, GetSpecializationInfo(currentSpecIndex)) or ""
    
    for tabIndex = 1, numTabs do
        local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(tabIndex)
        
        if skillLineInfo and not skillLineInfo.shouldHide then
            local offset = skillLineInfo.itemIndexOffset
            local numSlots = skillLineInfo.numSpellBookItems
            local tabName = skillLineInfo.name or ""
            
            -- Determine category priority (lower = higher priority)
            local categoryPriority = 4 -- Default: other
            local category = "other"
            
            if tabName == currentSpecName then
                categoryPriority = 1
                category = "spec"
            elseif skillLineInfo.isGuildPerkTab then
                categoryPriority = 5
                category = "guild"
            else
                -- Check if it's a class tab (usually the class name)
                local _, className = UnitClass("player")
                local localizedClassName = UnitClass("player")
                if tabName == localizedClassName or tabName == className then
                    categoryPriority = 2
                    category = "class"
                elseif tabName == "Racial" or tabName:find("Racial") then
                    categoryPriority = 3
                    category = "racial"
                elseif tabName == "General" then
                    categoryPriority = 4
                    category = "general"
                end
            end
            
            -- Iterate through spells in this tab
            for i = 1, numSlots do
                local slotIndex = offset + i
                
                -- Get spell book item info first
                local spellBookItemInfo = C_SpellBook.GetSpellBookItemInfo(slotIndex, bookType)
                
                if spellBookItemInfo then
                    local itemType = spellBookItemInfo.itemType
                    local baseSpellId = spellBookItemInfo.spellID
                    
                    -- Include regular spells only - if it's in spellbook as "Spell" type, it's usable
                    -- Skip FutureSpell (not yet learned), Flyout (spell groups), PetAction
                    if itemType == Enum.SpellBookItemType.Spell and baseSpellId then
                        local isPassive = C_SpellBook.IsSpellBookItemPassive(slotIndex, bookType)
                        
                        -- Use IsSpellInSpellBook with includeOverrides=true to properly detect
                        -- both regular known spells AND override spells (like Chrono Flames)
                        local isKnown = C_SpellBook.IsSpellInSpellBook and 
                            C_SpellBook.IsSpellInSpellBook(baseSpellId, bookType, true)
                        
                        if not isPassive and isKnown then
                            -- Get display info which handles override spells (e.g., Living Flame -> Chrono Flames)
                            local displayName, displayIcon, displaySpellId = GetSpellDisplayInfo(baseSpellId, nil)
                            
                            if displayName then
                                -- Find the TRUE root spell using GetBaseSpell
                                -- This handles cases where the spellbook entry itself is an override
                                -- e.g., Chrono Flames (431443) -> Living Flame (361469)
                                local trueRootId = baseSpellId
                                if C_Spell.GetBaseSpell then
                                    local baseId = C_Spell.GetBaseSpell(baseSpellId)
                                    if baseId and baseId ~= baseSpellId then
                                        trueRootId = baseId
                                    end
                                end
                                
                                -- Get spell name for binding (use true root spell)
                                local rootInfo = C_Spell.GetSpellInfo(trueRootId)
                                local baseName = rootInfo and rootInfo.name or displayName
                                
                                -- Determine if this is a "root" spell
                                -- Either the spellbook entry itself is being overridden (baseSpellId != displaySpellId)
                                -- OR the spellbook entry has a deeper root (trueRootId != baseSpellId)
                                local isRoot = (baseSpellId ~= displaySpellId) or (trueRootId ~= baseSpellId)
                                
                                local existing = spellsByDisplayId[displaySpellId]
                                
                                -- Add if we haven't seen this displaySpellId, OR if this is a root spell
                                -- and the existing one isn't (prefer root spells)
                                if not existing or (isRoot and not existing.isRoot) then
                                    -- When replacing, preserve the better category (lower priority = better)
                                    local useCategory = category
                                    local useCategoryPriority = categoryPriority
                                    local useTabName = tabName
                                    
                                    if existing and isRoot and not existing.isRoot then
                                        -- We're replacing an override spell with a root spell
                                        -- Keep the better category from the override spell if it has one
                                        if existing.spell.categoryPriority < categoryPriority then
                                            useCategory = existing.spell.category
                                            useCategoryPriority = existing.spell.categoryPriority
                                            useTabName = existing.spell.tabName
                                        end
                                    end
                                    
                                    spellsByDisplayId[displaySpellId] = {
                                        spell = {
                                            name = baseName,           -- Root spell name for binding
                                            displayName = displayName, -- Override name for display
                                            icon = displayIcon,
                                            spellId = trueRootId,      -- Use true root spell ID
                                            category = useCategory,
                                            categoryPriority = useCategoryPriority,
                                            tabName = useTabName,
                                        },
                                        isRoot = isRoot,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Convert to results array
    for displaySpellId, data in pairs(spellsByDisplayId) do
        table.insert(results, data.spell)
    end
    
    -- Sort by category priority first, then by name
    table.sort(results, function(a, b)
        if a.categoryPriority ~= b.categoryPriority then
            return a.categoryPriority < b.categoryPriority
        end
        return a.name < b.name
    end)
    
    return results
end

-- ============================================================
-- MACRO MANAGEMENT FUNCTIONS
-- ============================================================

-- Generate unique macro ID
function CC:GenerateMacroId()
    return "df_macro_" .. time() .. "_" .. math.random(1000, 9999)
end

-- Get all stored macros (custom + imported)
function CC:GetAllMacros(includeAutoGenerated)
    if not self.db or not self.db.customMacros then return {} end
    
    -- By default, hide auto-generated macros from the UI
    if includeAutoGenerated then
        return self.db.customMacros
    end
    
    local visible = {}
    for _, macro in ipairs(self.db.customMacros) do
        if not macro.autoGenerated then
            table.insert(visible, macro)
        end
    end
    return visible
end

-- Get macros filtered by source
function CC:GetMacrosBySource(source, includeAutoGenerated)
    local macros = self:GetAllMacros(includeAutoGenerated)
    if source == "all" then return macros end
    
    local filtered = {}
    for _, macro in ipairs(macros) do
        if macro.source == source then
            table.insert(filtered, macro)
        end
    end
    return filtered
end

-- Get macro by ID (always searches all macros including auto-generated)
function CC:GetMacroById(macroId)
    if not macroId then return nil end
    -- Must include auto-generated macros when looking up by ID
    for _, macro in ipairs(self:GetAllMacros(true)) do
        if macro.id == macroId then
            return macro
        end
    end
    return nil
end

-- Save a macro (create or update)
function CC:SaveMacro(macroData)
    if not self.db.customMacros then self.db.customMacros = {} end
    
    -- If updating existing
    if macroData.id then
        for i, macro in ipairs(self.db.customMacros) do
            if macro.id == macroData.id then
                self.db.customMacros[i] = macroData
                return macroData
            end
        end
    end
    
    -- Creating new
    if not macroData.id then
        macroData.id = self:GenerateMacroId()
    end
    table.insert(self.db.customMacros, macroData)
    return macroData
end

-- Delete a macro
function CC:DeleteMacro(macroId)
    if not self.db.customMacros then return false end
    
    for i, macro in ipairs(self.db.customMacros) do
        if macro.id == macroId then
            -- Also remove any bindings that use this macro
            self:ClearBindingsForMacro(macroId)
            table.remove(self.db.customMacros, i)
            return true
        end
    end
    return false
end

-- Get bindings for a specific macro
function CC:GetBindingsForMacro(macroId)
    local bindings = {}
    if not self.db or not self.db.bindings then return bindings end
    
    for _, binding in ipairs(self.db.bindings) do
        if binding.actionType == CC.ACTION_TYPES.MACRO and binding.macroId == macroId then
            table.insert(bindings, binding)
        end
    end
    return bindings
end

-- Clear all bindings for a macro
function CC:ClearBindingsForMacro(macroId)
    if not self.db or not self.db.bindings then return end
    
    for i = #self.db.bindings, 1, -1 do
        if self.db.bindings[i].actionType == CC.ACTION_TYPES.MACRO and self.db.bindings[i].macroId == macroId then
            table.remove(self.db.bindings, i)
        end
    end
    self:ApplyBindings()
end

-- ============================================================
-- UNIFIED MACRO-BASED BINDING SYSTEM
-- ============================================================
-- All bindings are converted to macros at configuration time.
-- This simplifies the code and provides consistent behavior.
-- Inspired by the Clicked addon's approach.
-- ============================================================

-- Resolve the localized spell name from a spell ID
local function GetLocalizedSpellName(spellId)
    if not spellId then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellId)
        return info and info.name
    end
    return nil
end

-- Get the player's available resurrection spells (returns localized names)
function CC:GetPlayerResurrectionSpells()
    local _, playerClass = UnitClass("player")
    local classSpells = self.RESURRECTION_SPELLS[playerClass]
    if not classSpells then return nil end

    local available = {}

    -- Helper to check if spell is known (works with spell ID)
    local function IsSpellAvailable(spellData)
        if not spellData then return false end
        local spellId = spellData.id
        if not spellId then return false end

        -- Use IsSpellInSpellBook with includeOverrides for proper override detection
        if C_SpellBook and C_SpellBook.IsSpellInSpellBook then
            return C_SpellBook.IsSpellInSpellBook(spellId, Enum.SpellBookSpellBank.Player, true)
        end
        return false
    end

    -- Check normal res — resolve localized name from spell ID
    if classSpells.normal and IsSpellAvailable(classSpells.normal) then
        available.normal = GetLocalizedSpellName(classSpells.normal.id) or classSpells.normal.name
    end

    -- Check mass res (healer specs only usually)
    if classSpells.mass and IsSpellAvailable(classSpells.mass) then
        available.mass = GetLocalizedSpellName(classSpells.mass.id) or classSpells.mass.name
    end

    -- Check combat res
    if classSpells.combat and IsSpellAvailable(classSpells.combat) then
        available.combat = GetLocalizedSpellName(classSpells.combat.id) or classSpells.combat.name
    end

    return available
end

-- Check if a spell is already a resurrection spell (locale-safe, uses spell ID)
function CC:IsResurrectionSpell(spellName, spellId)
    if spellId and self.RESURRECTION_SPELL_IDS[spellId] then
        return true
    end
    -- Fallback: resolve spell name to ID and check
    if spellName and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellName)
        if info and info.spellID and self.RESURRECTION_SPELL_IDS[info.spellID] then
            return true
        end
    end
    return false
end

-- Debug command to test resurrection spell detection
-- Note: If this doesn't work, use /dfrestest instead (defined in Core.lua)
SlashCmdList["DFCCRES"] = function(msg)
    -- Safety check
    if not CC or not CC.RESURRECTION_SPELL_NAMES then
        DF:Err("ClickCasting module not fully loaded.")
        print("Try using |cff00ff00/dfrestest|r instead for diagnostics.")
        return
    end
    
    local spellName = msg and msg ~= "" and msg or nil
    DF:Out("Click-Casting", "resurrection spells")
    
    if spellName then
        local isRes = CC:IsResurrectionSpell(spellName)
        print("Testing spell: |cffffffff" .. spellName .. "|r")
        print("IsResurrectionSpell: " .. (isRes and "|cff00ff00YES|r" or "|cffff0000NO|r"))
        print("Expected condition: " .. (isRes and ",dead" or ",nodead"))
    else
        print("Known resurrection spells:")
        for name, _ in pairs(CC.RESURRECTION_SPELL_NAMES) do
            print("  - " .. name)
        end
        print("")
        print("Usage: /dfccres <spell name>")
        print("Example: /dfccres Resurrection")
    end
    
    -- Also show current bindings with res spells
    if CC.db and CC.db.bindings then
        print("")
        print("Your res spell bindings:")
        local found = false
        for i, binding in ipairs(CC.db.bindings) do
            if binding.spellName and CC:IsResurrectionSpell(binding.spellName) then
                found = true
                print("  " .. (binding.spellName or "?") .. " -> detected as res spell")
            end
        end
        if not found then
            print("  (none found)")
        end
    end
end

-- Build smart resurrection macro parts
-- Returns array of macro condition strings to INSERT AT THE BEGINNING
-- Combat res takes highest priority for dead targets
function CC:GetSmartResurrectionParts(spellName, targetType, mountedStr)
    local mode = self.profile and self.profile.options and self.profile.options.smartResurrection or "disabled"
    mountedStr = mountedStr or ""
    
    -- Debug
    -- print("[DF SmartRes] mode:", mode, "spellName:", spellName, "targetType:", targetType)
    
    if mode == "disabled" then return nil end
    
    -- Don't add smart res to spells that are already resurrection spells
    if self:IsResurrectionSpell(spellName) then return nil end
    
    -- Only apply to friendly targets
    if targetType == "hostile" then return nil end
    
    local resSpells = self:GetPlayerResurrectionSpells()
    if not resSpells then 
        -- print("[DF SmartRes] No res spells available")
        return nil 
    end
    
    -- print("[DF SmartRes] Available res spells - normal:", resSpells.normal or "nil", "mass:", resSpells.mass or "nil", "combat:", resSpells.combat or "nil")
    
    local parts = {}
    
    -- Combat res FIRST (highest priority for dead targets in combat)
    if mode == "normal+combat" and resSpells.combat then
        table.insert(parts, "[@mouseover,help,exists,dead,combat" .. mountedStr .. "] " .. resSpells.combat)
    end
    
    -- Out of combat res (mass res preferred, then normal res)
    if resSpells.mass then
        table.insert(parts, "[@mouseover,help,exists,dead,nocombat" .. mountedStr .. "] " .. resSpells.mass)
    elseif resSpells.normal then
        table.insert(parts, "[@mouseover,help,exists,dead,nocombat" .. mountedStr .. "] " .. resSpells.normal)
    end
    
    if #parts == 0 then return nil end
    
    return parts
end

-- ============================================================
-- ITEM HELPER FUNCTIONS
-- ============================================================

-- Get item info for an equipment slot
function CC:GetSlotItemInfo(slotId)
    local itemId = GetInventoryItemID("player", slotId)
    if itemId then
        local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemId)
        local spellName = GetItemSpell(itemId)
        return {
            itemId = itemId,
            name = itemName,
            icon = itemIcon,
            hasOnUse = spellName ~= nil,
            onUseSpell = spellName,
        }
    end
    return nil
end

-- Get item info for an item ID (consumables)
function CC:GetItemInfoById(itemId)
    if not itemId then return nil end
    local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemId)
    if itemName then
        local spellName = GetItemSpell(itemId)
        return {
            itemId = itemId,
            name = itemName,
            icon = itemIcon,
            hasOnUse = spellName ~= nil,
            onUseSpell = spellName,
        }
    end
    return nil
end

-- Get item count in bags
function CC:GetItemCount(itemId)
    if not itemId then return 0 end
    return C_Item.GetItemCount(itemId) or GetItemCount(itemId) or 0
end

-- Build macro text for a single binding
-- This handles all action types and conditions
-- forGlobalBinding: if true, only use fallback settings (not appliesToFrames) for targeting
-- Resolve whether a binding should also target the unit it casts on.
-- A per-binding override (true/false) wins; otherwise inherit the global
-- "Target unit when click-casting" setting. nil = inherit.
function CC:GetEffectiveTargetOnCast(binding)
    if binding and binding.targetOnCast ~= nil then
        return binding.targetOnCast == true
    end
    return (self.db and self.db.global and self.db.global.targetOnCast) == true
end

-- Append a "/target the moused-over unit" line to a cast macro when enabled.
-- The [@mouseover,exists] gate means clicking a frame targets that unit, while
-- a target-fallback cast (nothing hovered) leaves the current target unchanged.
function CC:AppendTargetOnCast(macroText, enabled)
    if not macroText or not enabled then return macroText end
    if macroText:find("/target %[@mouseover", 1) then return macroText end
    return macroText .. "\n/target [@mouseover,exists] mouseover"
end

function CC:BuildMacroTextForBinding(binding, forGlobalBinding)
    if not binding then return nil end

    local actionType = binding.actionType or self.ACTION_TYPES.SPELL
    local targetType = binding.targetType or "all"
    local fallback = binding.fallback or {}
    local combatCond = GetCombatCondition(binding)
    
    -- Check if we should add nomounted/noflying condition
    -- noflying catches druid flight form (which isn't considered "mounted")
    local mountedStr = ""
    if self.db and self.db.global and self.db.global.disableWhileMounted then
        mountedStr = ",nomounted,noflying"
    elseif self.db and self.db.global and self.db.global.disableWhileFlying then
        mountedStr = ",noflying"
    end
    
    -- Build combat condition string
    local combatStr = ""
    if combatCond == "combat" then
        combatStr = ",combat"
    elseif combatCond == "nocombat" then
        combatStr = ",nocombat"
    end
    
    -- Build target type condition (help/harm)
    local targetStr = ""
    if targetType == "friendly" then
        targetStr = ",help"
    elseif targetType == "hostile" then
        targetStr = ",harm"
    end
    
    -- Handle different action types
    if actionType == self.ACTION_TYPES.SPELL then
        -- Resolve current spell name for the active locale.
        -- Bindings store the spell name from the language the client was using at
        -- creation time.  We must re-resolve via spell ID so the macro contains
        -- the name WoW's parser expects on the current client language.
        -- IMPORTANT: Always use the BASE spell name, never the override name.
        -- WoW's /cast command is override-aware and will automatically resolve
        -- base spells to their current form (e.g. /cast Flash of Light will cast
        -- Benediction when the proc is active). Using the override name in the
        -- macro causes "spell not learned" errors when the proc expires.
        local spellName = binding.spellName
        if binding.spellId then
            local localizedName = GetLocalizedSpellName(binding.spellId)
            if localizedName then
                spellName = localizedName
            end
        end
        if not spellName then return nil end
        
        local parts = {}
        
        -- Check if this is a resurrection spell - res spells need "dead" instead of "nodead"
        local isResSpell = self:IsResurrectionSpell(spellName, binding.spellId)
        local lifeCondition = isResSpell and ",dead" or ",nodead"
        
        -- SMART RESURRECTION FIRST (dead targets take priority)
        -- This must come before living target conditions
        -- Skip smart res logic if the spell itself is already a res spell
        if not isResSpell then
            local smartResParts = self:GetSmartResurrectionParts(spellName, targetType, mountedStr)
            if smartResParts then
                for _, part in ipairs(smartResParts) do
                    table.insert(parts, part)
                end
            end
        end
        
        -- Check what fallback options are enabled
        -- For frame click-casting to work, we ALWAYS need @mouseover when binding applies to frames
        -- because WoW sets the frame's unit as mouseover when you hover/click it
        -- BUT for global bindings (when not hovering frames), only use explicit fallback settings
        local frames = binding.frames or { dandersFrames = true, otherFrames = true }
        local appliesToFrames = frames.dandersFrames or frames.otherFrames
        local hasMouseover
        if forGlobalBinding then
            -- Global binding: only include @mouseover if explicitly enabled as fallback
            hasMouseover = fallback.mouseover == true
        else
            -- Frame binding: always need @mouseover for frame click-casting to work
            hasMouseover = appliesToFrames or fallback.mouseover == true
        end
        local hasTarget = fallback.target
        local hasSelf = fallback.selfCast and targetType ~= "hostile"
        
        -- Add mouseover (required for frames, optional fallback for world units)
        -- Use "dead" for res spells, "nodead" for everything else
        if hasMouseover then
            table.insert(parts, "[@mouseover" .. targetStr .. ",exists" .. lifeCondition .. combatStr .. mountedStr .. "] " .. spellName)
        end
        
        -- Target fallback - for when not hovering anything but have a target
        if hasTarget then
            table.insert(parts, "[@target" .. targetStr .. ",exists" .. lifeCondition .. combatStr .. mountedStr .. "] " .. spellName)
        end
        
        -- Self-cast fallback (only for friendly or all targets)
        if hasSelf then
            table.insert(parts, "[@player" .. combatStr .. mountedStr .. "] " .. spellName)
        end

        -- Always Cast: terminal unconditional clause — when no clause above
        -- matches (nothing hovered / ineligible unit), cast with WoW's default
        -- targeting so ground-targeted spells show their aiming circle
        -- (bug #991). With Self enabled the [@player] clause above always
        -- resolves first, so Self takes precedence. Combat/mounted gating
        -- still applies.
        if fallback.alwaysCast then
            local conds = (combatStr .. mountedStr):sub(2)   -- strip leading comma; "" when ungated
            table.insert(parts, (conds ~= "" and ("[" .. conds .. "] ") or "") .. spellName)
        end

        -- If no fallbacks enabled, just cast normally (will use WoW's default targeting)
        if #parts == 0 then
            table.insert(parts, spellName)
        end

        local macroText = "/cast " .. table.concat(parts, "; ")
        local fallbackTbl = binding.fallback or {}
        if fallbackTbl.stopSpellTarget then
            macroText = macroText .. "\n/stopspelltarget"
        end
        macroText = self:AppendTargetOnCast(macroText, self:GetEffectiveTargetOnCast(binding))
        return macroText

    elseif actionType == self.ACTION_TYPES.MACRO then
        -- For custom macros, just return the macro body
        local macro = self:GetMacroById(binding.macroId)
        if macro and macro.body then
            return macro.body
        end
        return nil
        
    elseif actionType == "target" then
        -- Target action uses native type="target"
        -- This requires the frame to have a "unit" attribute set
        -- For frames without a unit attribute, we need to set unit="mouseover"
        return nil
        
    elseif actionType == "focus" then
        local parts = {}
        local frames = binding.frames or { dandersFrames = true, otherFrames = true }
        local appliesToFrames = frames.dandersFrames or frames.otherFrames
        local hasMouseover
        if forGlobalBinding then
            hasMouseover = fallback.mouseover == true
        else
            hasMouseover = appliesToFrames or fallback.mouseover == true
        end
        if hasMouseover then
            table.insert(parts, "[@mouseover" .. targetStr .. ",exists" .. combatStr .. "]")
        end
        if fallback.target then
            table.insert(parts, "[@target" .. targetStr .. ",exists" .. combatStr .. "]")
        end
        -- If no fallbacks and no frames, default to mouseover for basic functionality
        if #parts == 0 then
            table.insert(parts, "[@mouseover" .. targetStr .. ",exists" .. combatStr .. "]")
        end
        return "/focus " .. table.concat(parts, "; ")
        
    elseif actionType == "assist" then
        local parts = {}
        local frames = binding.frames or { dandersFrames = true, otherFrames = true }
        local appliesToFrames = frames.dandersFrames or frames.otherFrames
        local hasMouseover
        if forGlobalBinding then
            hasMouseover = fallback.mouseover == true
        else
            hasMouseover = appliesToFrames or fallback.mouseover == true
        end
        if hasMouseover then
            table.insert(parts, "[@mouseover" .. targetStr .. ",exists" .. combatStr .. "]")
        end
        if fallback.target then
            table.insert(parts, "[@target" .. targetStr .. ",exists" .. combatStr .. "]")
        end
        -- If no fallbacks and no frames, default to mouseover for basic functionality
        if #parts == 0 then
            table.insert(parts, "[@mouseover" .. targetStr .. ",exists" .. combatStr .. "]")
        end
        return "/assist " .. table.concat(parts, "; ")
        
    elseif actionType == self.ACTION_TYPES.ITEM then
        -- Item binding (equipment slot or consumable)
        -- Resolve the item reference (slot number or item name/id)
        local itemRef
        if binding.itemType == "slot" then
            if not binding.itemSlot then return nil end
            itemRef = binding.itemSlot
        else
            itemRef = binding.itemName or binding.itemId
            if not itemRef then return nil end
        end

        -- Frame click-casting always needs @mouseover so hovering a frame
        -- targets that unit. Global keybinds only get @mouseover when the
        -- user explicitly opts in via the fallback.
        local frames = binding.frames or { dandersFrames = true, otherFrames = true }
        local appliesToFrames = frames.dandersFrames or frames.otherFrames
        local hasMouseover
        if forGlobalBinding then
            hasMouseover = fallback.mouseover == true
        else
            hasMouseover = appliesToFrames or fallback.mouseover == true
        end
        local hasTarget = fallback.target
        local hasSelf = fallback.selfCast and targetType ~= "hostile"

        local parts = {}

        if hasMouseover then
            table.insert(parts, "[@mouseover" .. targetStr .. ",exists,nodead" .. combatStr .. mountedStr .. "] " .. itemRef)
        end

        if hasTarget then
            table.insert(parts, "[@target" .. targetStr .. ",exists,nodead" .. combatStr .. mountedStr .. "] " .. itemRef)
        end

        if hasSelf then
            table.insert(parts, "[@player" .. combatStr .. mountedStr .. "] " .. itemRef)
        end

        if #parts == 0 then
            table.insert(parts, tostring(itemRef))
        end

        return self:AppendTargetOnCast("/use " .. table.concat(parts, "; "), self:GetEffectiveTargetOnCast(binding))

    elseif actionType == "menu" then
        -- Can't do menu via macro, will need special handling
        return nil
    end
    
    return nil
end

-- Build combined macro text for multiple bindings on the same key
-- Groups by target type and combat condition to create optimal macro
function CC:BuildCombinedMacroForBindings(bindings, forGlobalBinding)
    if not bindings or #bindings == 0 then return nil end
    
    -- Categorize bindings
    local friendly = {}
    local hostile = {}
    local any = {}
    
    for _, item in ipairs(bindings) do
        local b = item.binding or item
        if self:ShouldBindingLoad(b) then
            local targetType = b.targetType or "all"
            if targetType == "friendly" then
                table.insert(friendly, b)
            elseif targetType == "hostile" then
                table.insert(hostile, b)
            else
                table.insert(any, b)
            end
        end
    end
    
    -- Sort each category by priority
    local function sortByPriority(a, b)
        return (a.priority or 5) > (b.priority or 5)  -- higher number = higher priority
    end
    table.sort(friendly, sortByPriority)
    table.sort(hostile, sortByPriority)
    table.sort(any, sortByPriority)
    
    -- Find best spell for each category (first known spell)
    local function findBestSpell(list)
        for _, b in ipairs(list) do
            if b.actionType == self.ACTION_TYPES.SPELL and b.spellName then
                if IsSpellKnownByName and IsSpellKnownByName(b.spellName, b.spellId) then
                    return b
                end
            end
        end
        -- Fallback to first spell even if not confirmed known
        for _, b in ipairs(list) do
            if b.actionType == self.ACTION_TYPES.SPELL and b.spellName then
                return b
            end
        end
        -- Check for macros
        for _, b in ipairs(list) do
            if b.actionType == self.ACTION_TYPES.MACRO then
                return b
            end
        end
        return nil
    end
    
    local friendlyBinding = findBestSpell(friendly)
    local hostileBinding = findBestSpell(hostile)
    local anyBinding = findBestSpell(any)
    
    -- If we only have one type, just build macro for that binding
    if not friendlyBinding and not hostileBinding and anyBinding then
        return self:BuildMacroTextForBinding(anyBinding, forGlobalBinding), anyBinding
    end
    
    -- If we have only friendly or only hostile (no split)
    if friendlyBinding and not hostileBinding and not anyBinding then
        return self:BuildMacroTextForBinding(friendlyBinding, forGlobalBinding), friendlyBinding
    end
    if hostileBinding and not friendlyBinding and not anyBinding then
        return self:BuildMacroTextForBinding(hostileBinding, forGlobalBinding), hostileBinding
    end
    
    -- Build combined help/harm macro
    local parts = {}
    
    -- SMART RESURRECTION FIRST (dead targets take priority)
    -- Check friendly binding first, then any binding
    local smartResSpell = nil
    local smartResTargetType = nil
    if friendlyBinding and friendlyBinding.spellName then
        smartResSpell = friendlyBinding.spellName
        smartResTargetType = "friendly"
    elseif anyBinding and anyBinding.spellName then
        smartResSpell = anyBinding.spellName
        smartResTargetType = "all"
    end
    
    if smartResSpell then
        local smartResParts = self:GetSmartResurrectionParts(smartResSpell, smartResTargetType)
        if smartResParts then
            for _, part in ipairs(smartResParts) do
                table.insert(parts, part)
            end
        end
    end
    
    -- Friendly conditions
    if friendlyBinding and friendlyBinding.spellName then
        local spell = GetLocalizedSpellName(friendlyBinding.spellId) or friendlyBinding.spellName
        local fb = friendlyBinding.fallback or {}
        local combatCond = GetCombatCondition(friendlyBinding)
        local combatStr = combatCond == "combat" and ",combat" or (combatCond == "nocombat" and ",nocombat" or "")
        
        -- Check if this is a resurrection spell
        local isResSpell = CC:IsResurrectionSpell(spell)
        local lifeCondition = isResSpell and ",dead" or ",nodead"
        
        -- Check if binding applies to frames (if so, always need mouseover - unless forGlobalBinding)
        local frames = friendlyBinding.frames or { dandersFrames = true, otherFrames = true }
        local appliesToFrames = frames.dandersFrames or frames.otherFrames
        
        -- Mouseover help (required for frames, optional for world units)
        local hasMouseover = forGlobalBinding and fb.mouseover == true or (not forGlobalBinding and (appliesToFrames or fb.mouseover == true))
        if hasMouseover then
            table.insert(parts, "[@mouseover,help,exists" .. lifeCondition .. combatStr .. "] " .. spell)
        end
        -- Target help fallback
        if fb.target then
            table.insert(parts, "[@target,help,exists" .. lifeCondition .. combatStr .. "] " .. spell)
        end
    end
    
    -- Hostile conditions
    if hostileBinding and hostileBinding.spellName then
        local spell = GetLocalizedSpellName(hostileBinding.spellId) or hostileBinding.spellName
        local fb = hostileBinding.fallback or {}
        local combatCond = GetCombatCondition(hostileBinding)
        local combatStr = combatCond == "combat" and ",combat" or (combatCond == "nocombat" and ",nocombat" or "")

        -- Check if this is a resurrection spell (e.g., Soulstone can be used on hostile? unlikely but consistent)
        local isResSpell = CC:IsResurrectionSpell(spell)
        local lifeCondition = isResSpell and ",dead" or ",nodead"
        
        -- Check if binding applies to frames (if so, always need mouseover - unless forGlobalBinding)
        local frames = hostileBinding.frames or { dandersFrames = true, otherFrames = true }
        local appliesToFrames = frames.dandersFrames or frames.otherFrames
        
        -- Mouseover harm (required for frames, optional for world units)
        local hasMouseover = forGlobalBinding and fb.mouseover == true or (not forGlobalBinding and (appliesToFrames or fb.mouseover == true))
        if hasMouseover then
            table.insert(parts, "[@mouseover,harm,exists" .. lifeCondition .. combatStr .. "] " .. spell)
        end
        -- Target harm fallback (default on for hostile)
        if fb.target ~= false then
            table.insert(parts, "[@target,harm,exists" .. lifeCondition .. combatStr .. "] " .. spell)
        end
    end
    
    -- Any target fallback (no help/harm conditions)
    if anyBinding and anyBinding.spellName then
        local anySpell = GetLocalizedSpellName(anyBinding.spellId) or anyBinding.spellName
        local fb = anyBinding.fallback or {}

        -- Check if this is a resurrection spell
        local isResSpell = CC:IsResurrectionSpell(anySpell)
        local lifeCondition = isResSpell and ",dead" or ",nodead"
        
        -- Check if binding applies to frames (if so, always need mouseover - unless forGlobalBinding)
        local frames = anyBinding.frames or { dandersFrames = true, otherFrames = true }
        local appliesToFrames = frames.dandersFrames or frames.otherFrames
        
        -- Check what fallbacks are enabled for "any" binding
        local hasMouseover = forGlobalBinding and fb.mouseover == true or (not forGlobalBinding and (appliesToFrames or fb.mouseover == true))
        if hasMouseover then
            table.insert(parts, "[@mouseover,exists" .. lifeCondition .. "] " .. anySpell)
        end
        if fb.target then
            table.insert(parts, "[@target,exists" .. lifeCondition .. "] " .. anySpell)
        end
        -- If no specific fallbacks and no frames (or forGlobalBinding with no fallbacks), use empty condition
        if forGlobalBinding then
            if not fb.mouseover and not fb.target then
                table.insert(parts, "[] " .. anySpell)
            end
        else
            if not appliesToFrames and not fb.mouseover and not fb.target then
                table.insert(parts, "[] " .. anySpell)
            end
        end
    end
    
    -- Self-cast as final fallback for friendly
    if friendlyBinding and friendlyBinding.spellName then
        local fb = friendlyBinding.fallback or {}
        if fb.selfCast then
            local friendlySpell = GetLocalizedSpellName(friendlyBinding.spellId) or friendlyBinding.spellName
            local combatCond = GetCombatCondition(friendlyBinding)
            local combatStr = combatCond == "combat" and ",combat" or (combatCond == "nocombat" and ",nocombat" or "")
            table.insert(parts, "[@player" .. combatStr .. "] " .. friendlySpell)
        end
    end

    -- Always Cast (bug #991): terminal unconditional clause, mirroring the
    -- single-binding builder. First contributing binding with the flag wins;
    -- the self-cast clause above resolves first when enabled.
    for _, b in ipairs({friendlyBinding, hostileBinding, anyBinding}) do
        if b and b.fallback and b.fallback.alwaysCast and b.spellName then
            local spell = GetLocalizedSpellName(b.spellId) or b.spellName
            local combatCond = GetCombatCondition(b)
            local combatStr = combatCond == "combat" and ",combat" or (combatCond == "nocombat" and ",nocombat" or "")
            table.insert(parts, (combatStr ~= "" and ("[" .. combatStr:sub(2) .. "] ") or "") .. spell)
            break
        end
    end

    if #parts == 0 then return nil end

    -- Check if any contributing binding has stopSpellTarget enabled
    local useStopSpellTarget = false
    for _, b in ipairs({friendlyBinding, hostileBinding, anyBinding}) do
        if b and b.fallback and b.fallback.stopSpellTarget then
            useStopSpellTarget = true
            break
        end
    end

    local macroText = "/cast " .. table.concat(parts, "; ")
    if useStopSpellTarget then
        macroText = macroText .. "\n/stopspelltarget"
    end

    -- Target-on-cast: one macro, one /target line. Include it if ANY contributing
    -- binding resolves to on (the line targets whatever frame you clicked).
    local targetOnCast = false
    for _, b in ipairs({friendlyBinding, hostileBinding, anyBinding}) do
        if b and self:GetEffectiveTargetOnCast(b) then
            targetOnCast = true
            break
        end
    end
    macroText = self:AppendTargetOnCast(macroText, targetOnCast)

    return macroText, friendlyBinding or hostileBinding or anyBinding
end

-- Process all bindings and build unified macro map
-- Returns: { [keyString] = { macroText = "...", templateBinding = binding } }
-- Re-resolve click-casting state once cold-start data becomes available.
-- CheckLoadoutProfileSwitch can run before GetSpecialization() resolves at the
-- first login of a session. Picking a profile off an unknown spec sent spec-2+
-- players to spec 1's profile, and it stayed wrong all day until a /reload
-- ("none of my binds work in my first arena of the day"). The check now records
-- loadoutCheckUnresolved instead of guessing, and this resolver re-runs it once
-- real spec data arrives.
--
-- Debounced; the resolver clears its own flag on success and self-defers in
-- combat via the deferred-work queue. No-op in steady state, so the extra
-- triggers (spec/spell events, loading screens, arena prep) cost nothing.
--
-- The binding map itself is no longer spec-dependent: retiring the per-binding
-- loadSpec field removed the only path by which a cold-start build could drop
-- bindings, so there is no provisional-map half to resolve any more.
function CC:ResolveColdStartProfile(reason)
    if not self.loadoutCheckUnresolved then return end
    if not (self.db and self.db.enabled) then return end
    if self.provisionalResolveTimer then self.provisionalResolveTimer:Cancel() end
    self.provisionalResolveTimer = C_Timer.NewTimer(0.5, function()
        CC.provisionalResolveTimer = nil
        if CC.loadoutCheckUnresolved then
            DF:Debug("CLICK", "Re-running deferred loadout profile check (%s)", tostring(reason))
            CC:CheckLoadoutProfileSwitch()
        end
    end)
end

function CC:BuildUnifiedMacroMap()
    local macroMap = {}

    -- No cold-start guard needed here any more: the map used to be spec-
    -- dependent because ShouldBindingLoad dropped loadSpec-scoped bindings while
    -- GetSpecialization() was still nil, so a map built and cached in that window
    -- silently lost them. Retiring the per-binding loadSpec field removed that
    -- dependency entirely -- this build reads no spec state at all.

    -- Group all bindings by their key string
    local keyGroups = {}
    for i, binding in ipairs(self.db.bindings) do
        if binding.enabled ~= false then
            local keyString = self:GetBindingKeyString(binding)
            if keyString then
                if not keyGroups[keyString] then
                    keyGroups[keyString] = {}
                end
                table.insert(keyGroups[keyString], {binding = binding, index = i})
            end
        end
    end

    -- Build macro for each key group
    for keyString, group in pairs(keyGroups) do
        -- Check if this group contains any special actions or items (these don't combine)
        local specialBinding = nil
        local itemBinding = nil
        for _, item in ipairs(group) do
            local actionType = item.binding.actionType
            if actionType == "target" or actionType == "menu" or 
               actionType == "focus" or actionType == "assist" or
               actionType == self.ACTION_TYPES.MENU or
               actionType == self.ACTION_TYPES.FOCUS or
               actionType == self.ACTION_TYPES.ASSIST then
                specialBinding = item.binding
                break
            elseif actionType == self.ACTION_TYPES.ITEM then
                itemBinding = item.binding
                break
            end
        end
        
        if specialBinding then
            -- Special actions (target, menu, focus, assist) always use native WoW handling
            -- NOTE: We don't add smart res to target action because:
            -- 1. WoW's native type="target" works for cross-instance players
            -- 2. Macro-based targeting (/target) does NOT work for cross-instance players
            -- 3. PreClick handlers can't check unit state (UnitIsDeadOrGhost not available in restricted Lua)
            -- Smart res still works on healing spell bindings - click dead player with heal = casts res
            macroMap[keyString] = {
                macroText = nil,
                templateBinding = specialBinding,
                keyString = keyString,
                isSpecialAction = true,
            }
            
            DF:Debug("CLICK", "Special: %s -> %s", tostring(keyString), tostring(specialBinding.actionType or "?"))
        elseif itemBinding then
            -- Item binding - build simple /use macro
            local macroText = self:BuildMacroTextForBinding(itemBinding)
            local globalMacroText = self:BuildMacroTextForBinding(itemBinding, true)
            if macroText then
                macroMap[keyString] = {
                    macroText = macroText,
                    globalMacroText = globalMacroText,
                    templateBinding = itemBinding,
                    keyString = keyString,
                }
                
                DF:Debug("CLICK", "Item: %s\n%s", tostring(keyString), tostring(macroText))
            end
        else
            -- Normal spell/macro binding - try to build combined macro
            local macroText, templateBinding = self:BuildCombinedMacroForBindings(group)
            local globalMacroText = self:BuildCombinedMacroForBindings(group, true)
            if macroText and templateBinding then
                macroMap[keyString] = {
                    macroText = macroText,
                    globalMacroText = globalMacroText,
                    templateBinding = templateBinding,
                    keyString = keyString,
                }
                
                DF:Debug("CLICK", "Macro: %s\n%s", tostring(keyString), tostring(macroText))
            end
        end
    end
    
    return macroMap
end

-- ============================================================
-- SIMPLIFIED BINDING APPLICATION
-- ============================================================

-- Manifest-tracked attribute writer. Every attribute the binding loop writes
-- on a frame is recorded in frame.dfWrittenAttrs, so ClearBindingsFromFrame /
-- RestoreBlizzardDefaults can clear exactly what was written instead of
-- sweeping every combination that could ever exist (~500 SetAttribute calls
-- per frame per clear). The proxy path keeps its own dfProxyRoutes
-- bookkeeping and combat drivers keep dfAttrDriverList; this manifest covers
-- only direct frame attributes.
-- The manifest records HOW each attribute must be cleared, not just that it was
-- written: type attributes clear to "" (a nil type falls through to the wildcard
-- *type attributes and to Blizzard's own interaction bindings, which we do not
-- want), everything else clears to nil. Recording the kind at write time replaces
-- inferring it later from `attr:find("type")`, which was a substring test over
-- attribute names that include a caller-supplied virtual button name.
local function WriteAttr(frame, attr, value)
    frame:SetAttribute(attr, value)
    frame.dfWrittenAttrs = frame.dfWrittenAttrs or {}
    -- do not downgrade an existing "type" marker
    if frame.dfWrittenAttrs[attr] == nil then
        frame.dfWrittenAttrs[attr] = true
    end
end

local function WriteTypeAttr(frame, attr, value)
    frame:SetAttribute(attr, value)
    frame.dfWrittenAttrs = frame.dfWrittenAttrs or {}
    frame.dfWrittenAttrs[attr] = "type"
end

-- An attribute slot: where one action lands on a frame. Mouse slots spell
-- their attributes "shift-macrotext2" style (prefix..name..button); virtual
-- slots (keyboard, scroll, meta-mouse, third-party copies) use the named
-- "macrotext-<vbtn>" style.
-- Slot descriptors are filled into ONE reusable table rather than allocated per
-- binding per frame. ApplyBindingsToFrameUnified runs over every registered frame
-- (100-150+ with other unit-frame addons loaded) times every binding, and it is
-- already batched specifically because it hits Lua's time limit -- so allocating
-- a table per binding was the wrong direction.
--
-- The load-bearing property is NON-RE-ENTRANCY, which is what a future caller
-- could break silently. Safe today because: ApplyActionToSlot only reads fields
-- off the descriptor and never stores it; the two calls in the mouse branch are
-- strictly sequential; and RouteProxyAction copies typeAttr/clickbuttonAttr into
-- locals at call time, so a later mutation cannot reach back into an in-flight
-- route. Anything that makes this walk re-entrant -- a coroutine yield, a
-- callback that re-enters ApplyBindingsToFrameUnified -- must give itself its own
-- descriptor rather than reuse these.
local slotScratch = {}
local ctxScratch = {}

-- Blizzard's stock behaviour for the unmodified mouse buttons. Constant, so it is
-- not rebuilt once per frame inside the same batched walk.
local BASE_BUTTON_DEFAULTS = { [1] = "target", [2] = "togglemenu" }

local function MouseSlot(modPrefix, buttonNum)
    local s = slotScratch
    s.typeAttr  = modPrefix .. "type" .. buttonNum
    s.macroAttr = modPrefix .. "macrotext" .. buttonNum
    s.unitAttr  = modPrefix .. "unit" .. buttonNum
    s.clickAttr = modPrefix .. "clickbutton" .. buttonNum
    s.isVirtual = nil
    return s
end

local function VirtualSlot(virtualBtn)
    local s = slotScratch
    s.typeAttr  = "type-" .. virtualBtn
    s.macroAttr = "macrotext-" .. virtualBtn
    s.unitAttr  = "unit-" .. virtualBtn
    s.clickAttr = "clickbutton-" .. virtualBtn
    s.isVirtual = true
    return s
end

-- Write one resolved action into one slot. Single dispatch replacing four
-- near-identical copies (mouse/key x special/macro, each with proxy / direct /
-- combat-conditional variants). Behavior preserved from the originals:
--   * menu/target route through the 12.0.7 gate proxy when useProxy, EXCEPT
--     plain unmodified left-click target on the mouse slot (passes the gate
--     natively, stays direct).
--   * direct target sets unit="mouseover" on virtual slots only. The old
--     mouse-path variant gated it on dfIsBlizzardFrame, but Blizzard frames
--     always take the proxy route since the gate workaround shipped, so that
--     leg was unreachable and is not reproduced.
--   * focus/assist are never gated and never proxied; no combat drivers.
--   * spell/macro actions carry combat conditionals inside the macro text;
--     menu/target use attribute drivers (AddCombatConditional).
function CC:ApplyActionToSlot(frame, slot, ctx)
    local actionType = ctx.actionType
    if not ctx.isSpecialAction then
        WriteTypeAttr(frame, slot.typeAttr, "macro")
        WriteAttr(frame, slot.macroAttr, ctx.macroText)
        return
    end

    if actionType == "menu" or actionType == self.ACTION_TYPES.MENU then
        if ctx.useProxy then
            self:RouteProxyAction(frame, slot.typeAttr, slot.clickAttr, "togglemenu", ctx.combatCond)
        else
            WriteTypeAttr(frame, slot.typeAttr, "togglemenu")
            if ctx.combatCond then
                AddCombatConditional(frame, slot.typeAttr, "togglemenu", ctx.combatCond)
            end
        end
    elseif actionType == "target" then
        if ctx.useProxy and not (ctx.plainLeftClick and not slot.isVirtual) then
            self:RouteProxyAction(frame, slot.typeAttr, slot.clickAttr, "target", ctx.combatCond)
        else
            WriteTypeAttr(frame, slot.typeAttr, "target")
            if slot.isVirtual then
                WriteAttr(frame, slot.unitAttr, "mouseover")
            end
            if ctx.combatCond then
                AddCombatConditional(frame, slot.typeAttr, "target", ctx.combatCond)
            end
        end
    elseif actionType == "focus" or actionType == self.ACTION_TYPES.FOCUS then
        WriteTypeAttr(frame, slot.typeAttr, "focus")
    elseif actionType == "assist" or actionType == self.ACTION_TYPES.ASSIST then
        WriteTypeAttr(frame, slot.typeAttr, "assist")
    end
end

-- Apply all bindings to a frame using unified macro approach
-- skipKeyboardUpdate: when true, skip UpdateFrameBindingAttributes (caller will batch it)
function CC:ApplyBindingsToFrameUnified(frame, skipKeyboardUpdate)
    if not frame then return end
    if self:CombatGuard("bindingRefresh") then return end
    
    -- If click-casting is disabled, restore Blizzard defaults
    if not self.db.enabled then
        self:RestoreBlizzardDefaults(frame)
        return
    end
    
    local frameName = frame:GetName()
    if not frameName then return end

    -- Debug: track when bindings are reapplied (helps diagnose unexpected clears)
    local isHovered = (self.currentHoveredFrame == frame) or (frame.IsMouseOver and frame:IsMouseOver())
    DF:Debug("CLICK", "ApplyBindings %s hovered=%s", frameName, tostring(isHovered))
    if isHovered then
        DF:DebugWarn("CLICK", "ApplyBindings on HOVERED frame %s — bindings may flicker! caller: %s",
            frameName, debugstack(2, 1, 0) or "unknown")
    end

    -- Build unified macro map if not already built
    if not self.unifiedMacroMap then
        self.unifiedMacroMap = self:BuildUnifiedMacroMap()
        -- Refresh keyboard bindings on all frames since map was just built
        self:RefreshKeyboardBindings()
    end

    -- Check if this frame has ANY bindings that apply to it — BEFORE the
    -- destructive clear below, so a provisional (cold-start) map can bail out
    -- without touching the frame's existing state.
    local hasAnyBindings = false
    local isDandersFrame = frame.dfIsDandersFrame == true
    local isBlizzardFrame = frame.dfIsBlizzardFrame == true
    -- 12.0.7 gate workaround applies to frames whose clicks run through Blizzard's
    -- gated SecureUnitButton_OnClick. Our own frames and Blizzard's always qualify.
    -- Third-party unit frames (other unit-frame addons) built on
    -- SecureUnitButtonTemplate hit the same gate, so extend the proxy to them too --
    -- but only when the frame exposes a "unit" attribute, because the proxy resolves
    -- the target via useparent-unit (it reads the parent frame's unit at click time).
    -- Frames with no usable unit attribute keep the existing @mouseover fallback path.
    local tpUnit = (not isDandersFrame) and (not isBlizzardFrame)
        and frame.GetAttribute and frame:GetAttribute("unit")
    local thirdPartyHasUnit = type(tpUnit) == "string" and tpUnit ~= ""
    local useProxy = isDandersFrame or isBlizzardFrame or thirdPartyHasUnit

    for keyString, data in pairs(self.unifiedMacroMap) do
        local binding = data.templateBinding
        if self:ShouldBindingApplyToFrame(binding, frame) then
            hasAnyBindings = true
            break
        end
    end

    -- If no bindings apply to this frame, clean it up. (There used to be a
    -- provisional-map bailout here for a map built while spec data was still
    -- unresolved; retiring the per-binding loadSpec field removed the only way
    -- the map could be spec-dependent, so an empty map now always means the
    -- user's config, never a cold-start drop.)
    if not hasAnyBindings then
        self:ClearBindingsFromFrame(frame)
        if isDandersFrame then
            -- For DandersFrames, completely disable clicks when no bindings apply
            -- Our own frames get type1/type2 set in InitializeHeaderChild as a safety net
            if frame.RegisterForClicks then
                frame:RegisterForClicks()  -- Empty = no clicks registered
            end
        else
            -- For Blizzard frames AND third-party addon frames (QUI, ElvUI, etc.),
            -- restore default behavior (target/menu). These frames rely on type1/type2
            -- for basic click-to-target functionality and must not have clicks disabled.
            self:RestoreBlizzardDefaults(frame)
        end
        return
    end

    -- Clear existing bindings first. Deliberately below the applicability check
    -- so a frame that turns out to have no bindings is never stripped by this
    -- destructive pass before we know that.
    --
    -- In a batched apply (skipKeyboardUpdate) the keyboard snippet is preserved:
    -- the batch-end RefreshKeyboardBindings rewrites every registered frame's
    -- snippet anyway, and wiping it here opened the combat-interrupt window that
    -- left frames snippet-less for a whole fight (see ClearBindingsFromFrame).
    -- The no-bindings leg above must NOT preserve it -- nothing rewrites the
    -- snippet on a frame with no bindings, so there it has to be cleared.
    self:ClearBindingsFromFrame(frame, skipKeyboardUpdate)

    -- Register for clicks based on castOnDown option
    if frame.RegisterForClicks then
        local castOnDown = self.profile and self.profile.options and self.profile.options.castOnDown
        if castOnDown then
            frame:RegisterForClicks("AnyDown")
        else
            frame:RegisterForClicks("AnyUp")
        end
    end

    -- Enable mouse wheel for scroll bindings (like Clique does)
    if frame.EnableMouseWheel then
        frame:EnableMouseWheel(true)
    end
    
    -- Track which base (no modifier) mouse buttons get a binding applied to THIS frame.
    -- Used to restore defaults for uncovered buttons on non-DandersFrames.
    local coveredBaseButtons = {}

    -- Apply each macro binding (these will override defaults where bindings exist)
    local isThirdPartyFrame = not frame.dfIsDandersFrame and not frame.dfIsBlizzardFrame
    for keyString, data in pairs(self.unifiedMacroMap) do
        local binding = data.templateBinding

        -- Check if this binding should apply to this frame
        if self:ShouldBindingApplyToFrame(binding, frame) then
            local bindType = binding.bindType or "mouse"
            local actionType = binding.actionType or self.ACTION_TYPES.SPELL

            -- Check if this should be treated as a special action
            -- If macroMap has macroText for target (smart res), treat it like a spell macro
            local isSpecialAction = data.isSpecialAction
            if isSpecialAction == nil then
                -- Fallback for backwards compatibility
                isSpecialAction = (actionType == "menu" or actionType == "target" or
                                   actionType == "focus" or actionType == "assist" or
                                   actionType == self.ACTION_TYPES.MENU or
                                   actionType == self.ACTION_TYPES.FOCUS or
                                   actionType == self.ACTION_TYPES.ASSIST)
            end

            -- Reused, like the slot descriptors above: one table for the whole
            -- walk instead of one per binding per frame. plainLeftClick is reset
            -- here because only the mouse branch sets it.
            local ctx = ctxScratch
            ctx.actionType = actionType
            ctx.isSpecialAction = isSpecialAction
            ctx.macroText = data.macroText
            ctx.combatCond = GetCombatCondition(binding)
            ctx.useProxy = useProxy
            ctx.plainLeftClick = nil

            if bindType == "mouse" then
                local buttonNum = GetButtonNumber(binding.button)
                local modPrefix = BuildModifierPrefix(binding.modifiers)

                -- Track base (no modifier) mouse buttons that get a binding on this frame
                if modPrefix == "" then
                    coveredBaseButtons[buttonNum] = true
                end
                ctx.plainLeftClick = (buttonNum == 1 and modPrefix == "")

                self:ApplyActionToSlot(frame, MouseSlot(modPrefix, buttonNum), ctx)

                -- Named-attribute copy of the same action:
                --  * meta- (Mac Command) bindings always need one, because meta-
                --    frame attributes do not work on Mac;
                --  * third-party frames need one on the DIRECT paths. When
                --    menu/target go through the gate proxy, only the meta copy
                --    is made (matching the pre-refactor behavior).
                local hasMetaMod = binding.modifiers and binding.modifiers:lower():find("meta")
                local specialViaProxy = isSpecialAction and useProxy and
                    (actionType == "target" or actionType == "menu" or actionType == self.ACTION_TYPES.MENU)
                local wantVirtual = hasMetaMod or (not specialViaProxy and isThirdPartyFrame)
                if wantVirtual then
                    self:ApplyActionToSlot(frame, VirtualSlot(self:GetVirtualButtonName(binding)), ctx)
                end

            elseif bindType == "key" or bindType == "scroll" then
                -- Keyboard/scroll: the virtual named slot is the primary
                self:ApplyActionToSlot(frame, VirtualSlot(self:GetVirtualButtonName(binding)), ctx)
            end
        end
    end

    -- For non-DandersFrames, restore default behavior for any base mouse buttons
    -- that weren't covered by a binding on this frame. ClearBlizzardClickCastFromFrame
    -- wipes type1/type2 to "" when ANY binding targets other frames, but individual
    -- bindings may be DandersFrames-only. Without this, right-click menu (or left-click
    -- target) breaks on Blizzard frames when the binding doesn't apply to them.
    if not isDandersFrame then
        for btn, defaultType in pairs(BASE_BUTTON_DEFAULTS) do
            if not coveredBaseButtons[btn] then
                local currentType = frame:GetAttribute("type" .. btn)
                if not currentType or currentType == "" then
                    frame:SetAttribute("type" .. btn, defaultType)
                end
            end
        end
    end

    -- Debug: confirm final attribute state after apply
    local finalType1 = frame:GetAttribute("type1")
    local finalMacro1 = frame:GetAttribute("macrotext1")
    DF:Debug("CLICK", "ApplyBindings DONE %s type1=%s macro1=%s",
        frameName, tostring(finalType1), finalMacro1 and finalMacro1:sub(1, 50) or "nil")

    -- Update keyboard binding snippet for WrapScript to use
    -- Skip when caller will batch-refresh all frames (e.g. ApplyBindings)
    if not skipKeyboardUpdate then
        self:UpdateFrameBindingAttributes(frame)
    end
end

-- ============================================================

-- AUTO-GENERATED MACROS FOR HELP/HARM SPLITS
-- ============================================================


-- Get WoW global macros
function CC:GetWoWGlobalMacros()
    local macros = {}
    local numGlobal, numPerChar = GetNumMacros()
    
    for i = 1, numGlobal do
        local name, icon, body = GetMacroInfo(i)
        if name then
            table.insert(macros, {
                wowIndex = i,
                name = name,
                icon = icon,
                body = body,
                macroType = "global",
            })
        end
    end
    return macros
end

-- Get WoW character macros
function CC:GetWoWCharacterMacros()
    local macros = {}
    local numGlobal, numPerChar = GetNumMacros()
    
    -- Character macros start after global ones (index 121+)
    local startIndex = MAX_ACCOUNT_MACROS + 1
    for i = startIndex, startIndex + numPerChar - 1 do
        local name, icon, body = GetMacroInfo(i)
        if name then
            table.insert(macros, {
                wowIndex = i,
                name = name,
                icon = icon,
                body = body,
                macroType = "character",
            })
        end
    end
    return macros
end

-- Import a WoW macro (creates a copy in our storage)
function CC:ImportWoWMacro(wowMacro)
    local source = wowMacro.macroType == "global" and "global_import" or "char_import"
    
    -- Check if already imported
    for _, existing in ipairs(self:GetAllMacros()) do
        if existing.originalName == wowMacro.name and existing.source == source then
            -- Update existing import
            existing.body = wowMacro.body
            existing.icon = wowMacro.icon
            existing.lastSynced = time()
            return existing, "updated"
        end
    end
    
    -- Create new import
    local newMacro = {
        id = self:GenerateMacroId(),
        name = wowMacro.name,
        icon = wowMacro.icon,
        body = wowMacro.body,
        source = source,
        originalName = wowMacro.name,
        lastSynced = time(),
    }
    
    return self:SaveMacro(newMacro), "imported"
end

-- Sync an imported macro with its WoW original
function CC:SyncImportedMacro(macroId)
    local macro = self:GetMacroById(macroId)
    if not macro or not macro.originalName then return false, "Not an imported macro" end
    
    local wowMacros
    if macro.source == "global_import" then
        wowMacros = self:GetWoWGlobalMacros()
    else
        wowMacros = self:GetWoWCharacterMacros()
    end
    
    for _, wowMacro in ipairs(wowMacros) do
        if wowMacro.name == macro.originalName then
            macro.body = wowMacro.body
            macro.icon = wowMacro.icon
            macro.lastSynced = time()
            return true, "Synced successfully"
        end
    end
    
    return false, "Original macro not found"
end

-- Check if an imported macro is out of sync
function CC:IsMacroOutOfSync(macroId)
    local macro = self:GetMacroById(macroId)
    if not macro or not macro.originalName then return false end
    
    local wowMacros
    if macro.source == "global_import" then
        wowMacros = self:GetWoWGlobalMacros()
    else
        wowMacros = self:GetWoWCharacterMacros()
    end
    
    for _, wowMacro in ipairs(wowMacros) do
        if wowMacro.name == macro.originalName then
            return wowMacro.body ~= macro.body
        end
    end
    
    -- Original not found - definitely out of sync
    return true
end

-- Convert an imported macro to a custom one (breaks link to original)
function CC:ConvertToCustomMacro(macroId)
    local macro = self:GetMacroById(macroId)
    if not macro then return false end
    
    macro.source = "custom"
    macro.originalName = nil
    macro.lastSynced = nil
    return true
end

-- Quick macro builder - generate macro text from spell and pattern
function CC:BuildQuickMacro(spellName, pattern, options)
    options = options or {}
    local lines = {}
    
    if options.showTooltip ~= false then
        table.insert(lines, "#showtooltip")
    end
    
    if options.stopCasting then
        table.insert(lines, "/stopcasting")
    end
    
    -- Check if this is a resurrection spell
    local isResSpell = self:IsResurrectionSpell(spellName)
    local lifeCondition = isResSpell and "dead" or "nodead"
    
    local conditions = ""
    if pattern == "mouseover_target_self" then
        conditions = "[@mouseover,help," .. lifeCondition .. "][@target,help," .. lifeCondition .. "][@player]"
    elseif pattern == "mouseover_only" then
        conditions = "[@mouseover,help," .. lifeCondition .. "]"
    elseif pattern == "focus_mouseover_target" then
        conditions = "[@focus,help," .. lifeCondition .. "][@mouseover,help," .. lifeCondition .. "][@target,help," .. lifeCondition .. "]"
    elseif pattern == "mouseover_target" then
        conditions = "[@mouseover,help," .. lifeCondition .. "][@target,help," .. lifeCondition .. "]"
    elseif pattern == "harm_mouseover_target" then
        conditions = "[@mouseover,harm," .. lifeCondition .. "][@target,harm," .. lifeCondition .. "]"
    elseif pattern == "custom" and options.customConditions then
        conditions = options.customConditions
    end
    
    table.insert(lines, "/cast " .. conditions .. " " .. spellName)
    
    return table.concat(lines, "\n")
end

-- Common icon IDs for the icon picker
CC.COMMON_MACRO_ICONS = {
    -- Question mark / default
    134400, -- INV_Misc_QuestionMark
    -- Healing
    135915, -- Spell_Holy_FlashHeal
    135913, -- Spell_Holy_GreaterHeal  
    136041, -- Spell_Holy_Renew
    135907, -- Spell_Holy_HolyBolt
    -- Damage
    135812, -- Spell_Fire_FireBolt02
    135846, -- Spell_Shadow_ShadowBolt
    136197, -- Spell_Frost_FrostBolt02
    136048, -- Spell_Nature_Lightning
    -- Utility
    135894, -- Spell_Holy_DispelMagic
    136071, -- Spell_Nature_RemoveCurse
    135996, -- Spell_Nature_NullifyDisease
    135886, -- Spell_Holy_Resurrection
    -- Buffs
    135932, -- Spell_Holy_PowerWordFortitude
    135987, -- Spell_Nature_Regeneration
    135933, -- Spell_Holy_PowerWordShield
    136085, -- Spell_Nature_Slow
    -- Combat
    132355, -- Ability_Warrior_Charge
    132337, -- Ability_Rogue_Sprint
    132351, -- Ability_Vanish
    132336, -- Ability_Kick
    -- Misc
    136243, -- Spell_Nature_Polymorph
    136175, -- Spell_Frost_FreezingBreath
    135736, -- Spell_Holy_SealOfMight
    135940, -- Spell_Holy_SurgeOfLight
    132320, -- Ability_DualWield
    134414, -- INV_Misc_Bag_10
    133784, -- INV_Potion_54
    136235, -- Spell_Nature_TimeStop
}

-- ============================================================
-- DEBUG SLASH COMMAND
-- ============================================================

-- Non-dev: this is a DUMP, and dumps are what we ask a user to paste back on a
-- bug report. Dev-gating one makes it unrunnable by the only people who can
-- produce the state we need to see. (Traces stay dev-only — they belong in the
-- debug console, not in a user's chat frame.)
DF:RegisterDebugSlash("DFSPELLDUMP", "Raw spell dump", false, "/dfspelldump")
SlashCmdList["DFSPELLDUMP"] = function(msg)
    local searchTerm = msg and msg:lower() or ""
    local o = DF:Out("Click-Casting", "spellbook dump")
    if searchTerm ~= "" then
        o:Field("Filtering for", searchTerm)
    end
    
    local bookType = Enum.SpellBookSpellBank.Player
    local numTabs = C_SpellBook.GetNumSpellBookSkillLines()
    o:Field("Total tabs", numTabs)
    
    local totalSpells = 0
    local matchedSpells = 0
    
    for tabIndex = 1, numTabs do
        local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(tabIndex)
        if skillLineInfo then
            local offset = skillLineInfo.itemIndexOffset
            local numSlots = skillLineInfo.numSpellBookItems
            local tabName = skillLineInfo.name or "Unknown"
            local shouldHide = skillLineInfo.shouldHide
            
            print("  " .. DF.OUT.SECTION .. "Tab " .. tabIndex .. ": " .. tabName .. " (slots: " .. numSlots .. ", hide: " .. tostring(shouldHide) .. ")|r")
            
            for i = 1, numSlots do
                local slotIndex = offset + i
                local spellBookItemInfo = C_SpellBook.GetSpellBookItemInfo(slotIndex, bookType)
                
                if spellBookItemInfo then
                    local baseSpellId = spellBookItemInfo.spellID
                    local itemType = spellBookItemInfo.itemType
                    local itemTypeName = "Unknown"
                    
                    if itemType == Enum.SpellBookItemType.Spell then
                        itemTypeName = "Spell"
                    elseif itemType == Enum.SpellBookItemType.FutureSpell then
                        itemTypeName = "FutureSpell"
                    elseif itemType == Enum.SpellBookItemType.Flyout then
                        itemTypeName = "Flyout"
                    elseif itemType == Enum.SpellBookItemType.PetAction then
                        itemTypeName = "PetAction"
                    end
                    
                    local spellInfo = baseSpellId and C_Spell.GetSpellInfo(baseSpellId)
                    local spellName = spellInfo and spellInfo.name or "nil"
                    
                    -- Check for override
                    local overrideId = baseSpellId and C_Spell.GetOverrideSpell and C_Spell.GetOverrideSpell(baseSpellId)
                    local overrideName = nil
                    if overrideId and overrideId ~= baseSpellId then
                        local overrideInfo = C_Spell.GetSpellInfo(overrideId)
                        overrideName = overrideInfo and overrideInfo.name
                    end
                    
                    local isPassive = C_SpellBook.IsSpellBookItemPassive(slotIndex, bookType)
                    local isKnown = baseSpellId and C_SpellBook.IsSpellInSpellBook and 
                        C_SpellBook.IsSpellInSpellBook(baseSpellId, bookType, true)
                    
                    -- Check if matches search
                    local matchesSearch = searchTerm == "" or 
                        (spellName and spellName:lower():find(searchTerm, 1, true)) or
                        (overrideName and overrideName:lower():find(searchTerm, 1, true))
                    
                    totalSpells = totalSpells + 1
                    
                    if matchesSearch then
                        matchedSpells = matchedSpells + 1
                        local color = isKnown and "|cff00ff00" or "|cffff0000"
                        local passiveStr = isPassive and " [PASSIVE]" or ""
                        local overrideStr = overrideName and (" -> |cffff00ff" .. overrideName .. "|r") or ""
                        print(color .. spellName .. "|r (ID: " .. tostring(baseSpellId) .. ", Type: " .. itemTypeName .. ", Known: " .. tostring(isKnown) .. passiveStr .. ")" .. overrideStr)
                    end
                end
            end
        end
    end

    o:Siblings("spelldump")
end

-- ============================================================
-- CLICK CASTING DEBUG TOOLS
-- ============================================================

-- Debug: Show current mouseover state
SlashCmdList["DFCCMOUSEOVER"] = function()
    DF:Out("Click-Casting", "mouseover resolution")
    
    -- Check WoW's mouseover
    local moUnit = UnitExists("mouseover") and "mouseover" or nil
    local moName = moUnit and UnitName("mouseover") or "none"
    local moGUID = moUnit and UnitGUID("mouseover") or "none"
    print("WoW mouseover unit: " .. (moUnit or "nil") .. " (" .. moName .. ")")
    print("WoW mouseover GUID: " .. moGUID)
    
    -- Check what frame is under mouse
    local focus = GetMouseFocus and GetMouseFocus()
    if not focus and GetMouseFoci then
        local foci = GetMouseFoci()
        focus = foci and foci[1]
    end
    
    if focus then
        local frameName = focus:GetName() or "unnamed"
        local frameUnit = (focus.GetAttribute and focus:GetAttribute("unit")) or focus.unit or "none"
        local frameType = focus:GetObjectType()
        print("Frame under mouse: " .. frameName .. " (" .. frameType .. ")")
        print("Frame unit attr: " .. tostring(frameUnit))
        
        -- Check if it's a registered frame
        local isRegistered = CC.registeredFrames and CC.registeredFrames[focus]
        print("Is registered: " .. tostring(isRegistered))
        
        -- Check if secure OnEnter snippet actually ran (it sets these attributes)
        if focus.GetAttribute then
            local secureRan = focus:GetAttribute("dfSecureOnEnterRan")
            local secureBindingsSet = focus:GetAttribute("dfSecureBindingsSet")
            print("|cffff9900dfSecureOnEnterRan:|r " .. tostring(secureRan))
            print("|cffff9900dfSecureBindingsSet:|r " .. tostring(secureBindingsSet))
            if not secureRan then
                print("|cffff0000WARNING: Secure OnEnter snippet has NOT run on this frame!|r")
            elseif secureRan == "disabled" then
                print("|cffff0000WARNING: Snippet ran but dfClickCastEnabled was false!|r")
            end
            
            -- Show the binding snippet stored on the frame (Cell approach)
            local bindingSnippet = focus:GetAttribute("dfBindingSnippet")
            if bindingSnippet and bindingSnippet ~= "" then
                print("  " .. DF.OUT.SECTION .. "Frame Binding Snippet (Cell-style)|r")
                local bindCount = 0
                for _ in bindingSnippet:gmatch("SetBindingClick") do
                    bindCount = bindCount + 1
                end
                print("|cff00ff00SetBindingClick calls: " .. bindCount .. "|r")
                print(bindingSnippet)
                print("  " .. DF.OUT.SECTION .. "End Snippet|r")
            else
                print("|cffff6666No dfBindingSnippet set on frame|r")
            end
            
            -- Show _onenter attribute
            local onenter = focus:GetAttribute("_onenter")
            if onenter then
                print("|cff00ff00_onenter attribute IS set|r")
            else
                print("|cffff6666_onenter attribute NOT set - frame may not support SecureHandlerEnterLeaveTemplate|r")
            end
        end
        
        -- Show the OnEnter snippet from header (old approach, for reference)
        if CC.header then
            local headerSnippet = CC.header:GetAttribute("df_setup_onenter")
            local dfEnabled = CC.header:GetAttribute("dfClickCastEnabled")
            print("|cff00ff00dfClickCastEnabled on header:|r " .. tostring(dfEnabled))
            
            if headerSnippet and headerSnippet ~= "" then
                print("  " .. DF.OUT.SECTION .. "Header OnEnter Snippet|r")
                -- Count SetBindingClick calls
                local bindCount = 0
                for _ in headerSnippet:gmatch("SetBindingClick") do
                    bindCount = bindCount + 1
                end
                print("|cff00ff00SetBindingClick calls in snippet: " .. bindCount .. "|r")
                
                -- Show snippet (truncate middle if too long)
                if #headerSnippet > 1500 then
                    print(headerSnippet:sub(1, 700))
                    print("|cffff6666... (" .. (#headerSnippet - 1400) .. " chars omitted) ...|r")
                    print(headerSnippet:sub(-700))
                else
                    print(headerSnippet)
                end
                print("  " .. DF.OUT.SECTION .. "End Snippet|r")
            else
                print("|cffff6666No df_setup_onenter set on header|r")
            end
        else
            print("|cffff6666CC.header is nil!|r")
        end
        
        -- Show the old dfBindingSnippet if it exists (for comparison)
        if focus.GetAttribute then
            local snippet = focus:GetAttribute("dfBindingSnippet")
            if snippet and snippet ~= "" then
                print("  " .. DF.OUT.SECTION .. "Old Frame Binding Snippet (deprecated)|r")
                print(snippet)
                print("  " .. DF.OUT.SECTION .. "End Old Snippet|r")
            end
        end
        
        -- Show relevant attributes
        if focus.GetAttribute then
            print("  " .. DF.OUT.SECTION .. "Frame Attributes|r")
            for i = 1, 5 do
                local typeAttr = focus:GetAttribute("type" .. i)
                local spellAttr = focus:GetAttribute("spell" .. i)
                local macroAttr = focus:GetAttribute("macrotext" .. i)
                if typeAttr then
                    print("  type" .. i .. " = " .. tostring(typeAttr))
                    if spellAttr then print("  spell" .. i .. " = " .. tostring(spellAttr)) end
                    if macroAttr then print("  macrotext" .. i .. " = " .. tostring(macroAttr:sub(1, 80))) end
                end
            end
            -- Check shift-type1 etc
            local shiftType1 = focus:GetAttribute("shift-type1")
            if shiftType1 then
                print("  shift-type1 = " .. tostring(shiftType1))
                local shiftMacro = focus:GetAttribute("shift-macrotext1")
                if shiftMacro then print("  shift-macrotext1 = " .. tostring(shiftMacro:sub(1, 80))) end
            end
            
            -- Check virtual button attributes for keyboard bindings
            print("  " .. DF.OUT.SECTION .. "Virtual Button Attributes (for keyboard bindings)|r")
            -- Check common key names (not prefixed with "key")
            local virtButtons = {"Q", "F", "E", "R", "T", "G", "1", "2", "3", "4", "5",
                                 "shiftQ", "shiftF", "ctrlQ", "ctrlF", "altQ", "altF"}
            for _, vb in ipairs(virtButtons) do
                local vbType = focus:GetAttribute("type-" .. vb)
                if vbType then
                    local vbMacro = focus:GetAttribute("macrotext-" .. vb)
                    print("  type-" .. vb .. " = " .. tostring(vbType))
                    if vbMacro then print("  macrotext-" .. vb .. " = " .. tostring(vbMacro:sub(1, 60))) end
                end
            end
        end
    else
        print("No frame under mouse")
    end
end

-- Debug: Show current override bindings
-- Non-dev: DUMP (see the note on DFSPELLDUMP).
-- ⚠ Near-duplicate of /dfccbindcheck below — this one covers a wider key set,
-- that one only 1-9. Merge candidate, deferred until PR #218 lands.
SlashCmdList["DFCCKEYBINDS"] = function()
    DF:Out("Click-Casting", "override binding check")
    
    -- Check specific keys
    local keysToCheck = {"Q", "F", "E", "R", "T", "G", "1", "2", "3", "4", "5", 
                         "SHIFT-Q", "SHIFT-F", "CTRL-Q", "CTRL-F"}
    
    for _, key in ipairs(keysToCheck) do
        local action, owner = GetBindingAction(key, true)  -- true = check override bindings
        if action and action ~= "" then
            local ownerName = owner and owner:GetName() or "unknown"
            print(key .. " -> " .. action .. " (owner: " .. ownerName .. ")")
        end
    end
    
    -- Also check what frame is under mouse and its bindings
    local focus = GetMouseFocus and GetMouseFocus()
    if not focus and GetMouseFoci then
        local foci = GetMouseFoci()
        focus = foci and foci[1]
    end
    
    if focus and focus.dfActiveKeyboardBindings then
        print("  " .. DF.OUT.SECTION .. "Frame's tracked keyboard bindings|r")
        for _, bindKey in ipairs(focus.dfActiveKeyboardBindings) do
            print("  " .. bindKey)
        end
    end
end

-- Arms per-frame PreClick/PostClick tracing. Output goes to the debug console's
-- CLICK category; this command only INSTALLS the hooks, because HookScript
-- cannot be undone and so must not ride a console toggle the user flips freely.
-- Same shape as /df debug flatdebug.
SlashCmdList["DFCCDEBUGCLICKS"] = function()
    if CC.dfClickHooksArmed then
        DF:Say("Click hooks are already armed", "reload to remove them", "WARN")
        return
    end

    local hooked = 0
    if CC.registeredFrames then
        for frame in pairs(CC.registeredFrames) do
            if not frame.dfDebugClickHooked then
                frame:HookScript("PreClick", function(self, button, down)
                    if not DF:DebugActive("CLICK") then return end
                    local typeAttr = self:GetAttribute(button == "RightButton" and "type2" or "type1")
                    local macroAttr = self:GetAttribute(button == "RightButton" and "macrotext2" or "macrotext1")
                    DF:Debug("CLICK", "PreClick %s btn=%s down=%s unit=%s mouseover=%s\n  type=%s macro=%s",
                        tostring(self:GetName() or "unnamed"), tostring(button), tostring(down),
                        tostring(self:GetAttribute("unit") or self.unit or "none"),
                        tostring(UnitExists("mouseover") and UnitName("mouseover") or "none"),
                        tostring(typeAttr), tostring(macroAttr and macroAttr:sub(1, 60)))
                end)
                frame:HookScript("PostClick", function(self, button, down)
                    DF:Debug("CLICK", "PostClick mouseover=%s",
                        tostring(UnitExists("mouseover") and UnitName("mouseover") or "none"))
                end)
                frame.dfDebugClickHooked = true
                hooked = hooked + 1
            end
        end
    end

    CC.dfClickHooksArmed = true
    DF:Say("Click tracing armed on " .. hooked .. " frame(s)", "enable the CLICK console category to see them")
end

-- Debug: Show all bindings and their macro text
SlashCmdList["DFCCBINDINGS"] = function()
    DF:Out("Click-Casting", "bindings")
    
    if not CC.db or not CC.db.bindings then
        print("No bindings found")
        return
    end
    
    for i, binding in ipairs(CC.db.bindings) do
        if binding.enabled ~= false then
            local keyStr = CC:GetBindingKeyString(binding)
            local actionType = binding.actionType or "spell"
            local spellName = binding.spellName or binding.macroId or "?"
            local fallback = binding.fallback or {}
            local fallbackStr = ""
            if fallback.mouseover then fallbackStr = fallbackStr .. "MO " end
            if fallback.target then fallbackStr = fallbackStr .. "TGT " end
            if fallback.selfCast then fallbackStr = fallbackStr .. "SELF " end
            if fallbackStr == "" then fallbackStr = "none" end
            
            print("|cff00ff00" .. (keyStr or "?") .. "|r -> " .. actionType .. ": " .. spellName .. " [fallback: " .. fallbackStr .. "]")
            
            -- Show generated macro
            if CC.unifiedMacroMap and CC.unifiedMacroMap[keyStr] then
                local macro = CC.unifiedMacroMap[keyStr].macroText
                if macro then
                    print("  |cff888888" .. macro:gsub("\n", " / ") .. "|r")
                end
            end
        end
    end
end

-- Debug command: Check actual override bindings for common keys
-- Non-dev: DUMP. See the merge note on /dfcckeybinds above.
SlashCmdList["DFCCBINDCHECK"] = function()
    DF:Say("Checking override bindings for keys 1-9:")
    
    for i = 1, 9 do
        local key = tostring(i)
        local action = GetBindingAction(key, true)  -- true = check override bindings first
        print(string.format("  Key %s: action=%s", key, tostring(action)))
    end
    
    print("  " .. DF.OUT.SECTION .. "Checking hovered frame's bindings|r")
    local frame = CC.currentHoveredFrame
    if frame then
        local frameName = frame:GetName()
        print("Frame: " .. frameName)
    else
        print("No hovered frame")
    end
end

-- Debug command: Show binding attributes on hovered frame
-- Non-dev: DUMP. Reads the currently hovered frame, so the user must be hovering
-- one when they run it — worth saying in the reply when we ask for it.
SlashCmdList["DFCCFRAMEATTRS"] = function()
    local frame = CC.currentHoveredFrame
    if not frame then
        DF:Say("No frame currently hovered")
        return
    end
    
    local frameName = frame:GetName() or "unnamed"
    DF:Out("Click-Casting", "frame attributes — " .. frameName)
    
    -- Event counters
    print("  " .. DF.OUT.SECTION .. "Secure Event Counters|r")
    print("  _onenter fired: " .. tostring(frame:GetAttribute("dfOnEnterAttrCount") or 0))
    print("  _onenter ran snippet: " .. tostring(frame:GetAttribute("dfOnEnterRanSnippet") or "n/a"))
    print("  _onleave fired: " .. tostring(frame:GetAttribute("dfOnLeaveAttrCount") or 0))
    print("  WrapScript OnEnter: " .. tostring(frame:GetAttribute("dfWrapEnterCount") or 0))
    
    -- Check keyboard binding snippet
    local snippet = frame:GetAttribute("dfBindingSnippet") or ""
    local lineCount = 0
    for _ in snippet:gmatch("[^\n]+") do lineCount = lineCount + 1 end
    print("  " .. DF.OUT.SECTION .. "Binding Snippet (" .. lineCount .. " lines)|r")
    if snippet ~= "" then
        for line in snippet:gmatch("[^\n]+") do
            print("  " .. line)
        end
    else
        print("  (empty)")
    end
    
    -- Check actual bindings for keys in snippet
    print("  " .. DF.OUT.SECTION .. "Actual Bindings (GetBindingAction)|r")
    if snippet ~= "" then
        for line in snippet:gmatch("[^\n]+") do
            local key = line:match('SetBindingClick%(true,%s*"([^"]+)"')
            if key then
                local action = GetBindingAction(key, true)
                if action and action ~= "" then
                    print(string.format("  %s -> %s", key, action))
                else
                    print(string.format("  %s -> (none/actionbar)", key))
                end
            end
        end
    else
        print("  (no snippet)")
    end
    
    print("  " .. DF.OUT.SECTION .. "Frame State|r")
    print("  registered=" .. tostring(frame.dfClickCastRegistered) .. 
          ", isDandersFrame=" .. tostring(frame.dfIsDandersFrame) ..
          ", handlersSetup=" .. tostring(frame.dfKeyboardHandlersSetup))
end

-- Debug loadout profile switching
-- Non-dev: DUMP (see the note on DFSPELLDUMP).
SlashCmdList["DFCCLOADOUT"] = function()
    DF:Out("Click-Casting", "loadout")
    
    -- These are functions, not methods - don't use : syntax
    local specIndex = CC.GetCurrentSpec and CC.GetCurrentSpec() or GetSpecialization() or 0
    local loadoutID = CC.GetCurrentLoadoutConfigID and CC.GetCurrentLoadoutConfigID() or 0
    local loadoutName = CC.GetLoadoutName and CC.GetLoadoutName(loadoutID) or "Unknown"
    local currentProfile = CC:GetActiveProfileName()
    local assignedProfile, isSpecific = CC:GetProfileForLoadout(specIndex, loadoutID)
    
    print("  Current Spec Index: " .. tostring(specIndex))
    print("  Current Loadout ID: " .. tostring(loadoutID))
    print("  Current Loadout Name: " .. tostring(loadoutName))
    print("  Current Active Profile: " .. tostring(currentProfile))
    print("  Assigned Profile for Loadout: " .. tostring(assignedProfile or "none"))
    print("  Is Specific Assignment: " .. tostring(isSpecific))
    
    -- Show all loadout assignments for current spec
    local classData = CC:GetClassData()
    if classData and classData.loadoutAssignments and classData.loadoutAssignments[specIndex] then
        print("  All assignments for spec " .. specIndex .. ":")
        for lid, profile in pairs(classData.loadoutAssignments[specIndex]) do
            local lname = CC.GetLoadoutName and CC.GetLoadoutName(lid) or tostring(lid)
            print("    Loadout " .. tostring(lid) .. " (" .. lname .. ") -> " .. profile)
        end
    else
        print("  No loadout assignments found for this spec")
    end
    
    -- Manually trigger a check
    print("  Triggering CheckLoadoutProfileSwitch...")
    CC:CheckLoadoutProfileSwitch()
end

-- Debug: Comprehensive keyboard fallback diagnosis
SlashCmdList["DFCCKBFALLBACK"] = function()
    DF:Out("Click-Casting", "keyboard fallback")
    
    -- 1. Check if click-casting is enabled
    print("  " .. DF.OUT.SECTION .. "1. Click-Casting Status:|r")
    print("  Enabled: " .. tostring(CC.db and CC.db.enabled))
    
    -- 2. Check hovercast button
    print("  " .. DF.OUT.SECTION .. "2. Hovercast Button:|r")
    local hcButton = CC.hovercastButton
    if hcButton then
        print("  Button exists: yes")
        print("  Button name: " .. tostring(hcButton:GetName()))
        print("  Parent: " .. tostring(hcButton:GetParent() and hcButton:GetParent():GetName()))
        print("  Has Execute method: " .. tostring(hcButton.Execute ~= nil))
        
        -- Check setupScript/clearScript
        if hcButton.setupScript then
            local lineCount = 0
            local bindingCount = 0
            for line in hcButton.setupScript:gmatch("[^\n]+") do 
                lineCount = lineCount + 1
                if line:find("SetBindingClick") then
                    bindingCount = bindingCount + 1
                end
            end
            print("  setupScript: " .. lineCount .. " lines, " .. bindingCount .. " SetBindingClick calls")
        else
            print("  setupScript: nil")
        end
        
        -- Try to find what virtual button names are used
        -- Parse setupScript to find attribute names
        if hcButton.setupScript then
            print("  Checking attributes from setupScript...")
            local foundAttrs = 0
            for suffix in hcButton.setupScript:gmatch('type%-([^"]+)') do
                local typeAttr = hcButton:GetAttribute("type-" .. suffix)
                local macroAttr = hcButton:GetAttribute("macrotext-" .. suffix)
                if typeAttr then
                    foundAttrs = foundAttrs + 1
                    print("    " .. suffix .. ": type=" .. tostring(typeAttr) .. ", macro=" .. (macroAttr and macroAttr:sub(1, 40) or "nil") .. "...")
                else
                    print("    " .. suffix .. ": MISSING (script has it but attribute not set!)")
                end
            end
            if foundAttrs == 0 then
                print("    NO ATTRIBUTES FOUND - Execute() likely failed!")
            end
        end
    else
        print("  Button exists: NO - this is a problem!")
    end
    
    -- 3. Check global bindings with fallbacks
    print("  " .. DF.OUT.SECTION .. "3. Bindings with Fallbacks:|r")
    if CC.db and CC.db.bindings then
        local fallbackCount = 0
        for i, binding in ipairs(CC.db.bindings) do
            if binding.enabled ~= false then
                local fb = binding.fallback or {}
                if fb.mouseover or fb.target or fb.selfCast then
                    fallbackCount = fallbackCount + 1
                    local keyStr = CC:GetBindingKeyString(binding)
                    local fbStr = ""
                    if fb.mouseover then fbStr = fbStr .. "MO " end
                    if fb.target then fbStr = fbStr .. "TGT " end
                    if fb.selfCast then fbStr = fbStr .. "SELF " end
                    print("  " .. (keyStr or "?") .. " -> " .. (binding.spellName or "?") .. " [" .. fbStr .. "]")
                    
                    -- Check if this binding has global macro in unified map
                    if CC.unifiedMacroMap and CC.unifiedMacroMap[keyStr] then
                        local data = CC.unifiedMacroMap[keyStr]
                        print("    macroText: " .. (data.macroText and data.macroText:sub(1, 60) or "nil"))
                        print("    globalMacroText: " .. (data.globalMacroText and data.globalMacroText:sub(1, 60) or "nil"))
                    else
                        print("    NOT in unifiedMacroMap!")
                    end
                end
            end
        end
        if fallbackCount == 0 then
            print("  No bindings with fallbacks found")
        end
    end
    
    -- 4. Check actual override bindings
    print("  " .. DF.OUT.SECTION .. "4. Override Bindings (GetBindingAction):|r")
    local keysToCheck = {"Q", "E", "R", "T", "F", "G", "1", "2", "3", "4", "5",
                         "SHIFT-Q", "SHIFT-E", "CTRL-Q", "CTRL-E"}
    local foundOurs = false
    for _, key in ipairs(keysToCheck) do
        local action = GetBindingAction(key, true)
        if action and action ~= "" then
            local isOurs = action:find("DFHovercastButton") or action:find("dfbutton")
            if isOurs then
                foundOurs = true
                print("  " .. key .. " -> " .. action .. " (OURS)")
            else
                print("  " .. key .. " -> " .. action)
            end
        end
    end
    if not foundOurs then
        print("  WARNING: No keys bound to DFHovercastButton!")
        print("  This means Execute() failed or script wasn't run")
    end
    
    -- 5. Check current unit state
    print("  " .. DF.OUT.SECTION .. "5. Current Unit State:|r")
    local moExists = UnitExists("mouseover")
    local tgtExists = UnitExists("target")
    print("  mouseover: " .. (moExists and UnitName("mouseover") or "none"))
    print("  target: " .. (tgtExists and UnitName("target") or "none"))
    
    -- 6. Check if currently hovering a frame
    print("  " .. DF.OUT.SECTION .. "6. Currently Hovered Frame:|r")
    local hoveredFrame = CC.currentHoveredFrame
    if hoveredFrame then
        print("  Frame: " .. tostring(hoveredFrame:GetName()))
    else
        print("  None (fallbacks should be active if set)")
    end
    
    -- 7. Try to manually execute the setup script and report result
    print("  " .. DF.OUT.SECTION .. "7. Manual Execute Test:|r")
    if hcButton and hcButton.Execute and hcButton.setupScript then
        local success, err = pcall(function()
            hcButton:Execute(hcButton.setupScript)
        end)
        if success then
            print("  Execute() succeeded")
            -- Check if attributes are now set
            local foundAfter = false
            for suffix in hcButton.setupScript:gmatch('type%-([^"]+)') do
                local typeAttr = hcButton:GetAttribute("type-" .. suffix)
                if typeAttr then
                    foundAfter = true
                    print("  After Execute: " .. suffix .. " = " .. tostring(typeAttr))
                end
            end
            if not foundAfter then
                print("  Execute returned success but attributes STILL not set!")
                print("  This suggests SecureHandlerBaseTemplate isn't working")
            end
        else
            print("  Execute() FAILED: " .. tostring(err))
        end
    else
        print("  Cannot test - missing button, Execute, or setupScript")
    end
    
    print("|cff888888Tip: If fallbacks aren't working, check that:|r")
    print("|cff888888  1. Section [7] shows attributes are set after Execute|r")
    print("|cff888888  2. Section [4] shows keys bound to DFHovercastButton|r")
end

-- ============================================================
-- /df debug cc — one entry point for click-casting diagnostics
-- ============================================================
-- These were eleven separate /dfccXXX commands, each dumping one adjacent slice
-- of the same subsystem. Nobody remembers eleven names, and click-casting is our
-- highest-volume bug source, so the one thing a user must be able to do is find
-- the dump. The handlers are unchanged — only the way in is.
--
-- Resolved through SlashCmdList at CALL time, so it does not matter that three
-- of these handlers live in other files loaded after this one.
-- Which addon owns each frame's click-casting registration. Distinct from
-- "frames", which dumps secure attributes of the ONE currently hovered frame —
-- this is the ownership picture across all of them, and the two are read together
-- when a binding fires on some frames but not others.
SlashCmdList["DFCCREGISTRATION"] = function()
    local o = DF:Out("Click-Casting", "frame registration")
    if not ClickCastFrames then
        o:Line("ClickCastFrames does not exist — no click-casting addon has claimed it.", "WARN")
        return
    end
    local rows, count, idx = {}, 0, 0
    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(function(frame)
            idx = idx + 1
            local status = ClickCastFrames[frame]
            local label = status == true and "registered"
                or (status == false and "explicitly excluded" or "not registered")
            local tone = status == true and DF.OUT.GOOD
                or (status == false and DF.OUT.WARN or DF.OUT.NEUTRAL)
            rows[#rows + 1] = ("party%d  %s%s|r"):format(idx, tone, label)
            if status then count = count + 1 end
        end)
    end
    o:Section("Party frames", count .. " of " .. idx .. " registered")
    o:More(rows, 10)
end

-- Clears the ignore flag on the conflict warning, so it can fire again next login.
SlashCmdList["DFCCRESETCONFLICT"] = function()
    if not DandersFramesClickCastingDB then
        DF:Err("Click-casting database not loaded")
        return
    end
    DandersFramesClickCastingDB.ignoreConflictWarning = nil
    DF:Say("Conflict warning re-enabled", "it will show on next reload if conflicts are found")
end

local CC_SUBCOMMANDS = {
    -- name         handler key        dev?   what it shows
    { "bindings",   "DFCCBINDINGS",    false, "every binding and its macro text" },
    { "keybinds",   "DFCCKEYBINDS",    false, "keyboard binding state" },
    { "bindcheck",  "DFCCBINDCHECK",   false, "override key binding check" },
    { "frames",     "DFCCFRAMEATTRS",  false, "secure frame attributes" },
    { "loadout",    "DFCCLOADOUT",     false, "loadout internals" },
    { "spells",     "DFCCSPELLS",      false, "spellbook detection" },
    { "registration", "DFCCREGISTRATION", false, "which addon owns each frame's click-casting" },
    { "resetconflict", "DFCCRESETCONFLICT", false, "re-enable the conflict warning" },
    { "res",        "DFCCRES",         true,  "resurrection spell detection" },
    { "mouseover",  "DFCCMOUSEOVER",   true,  "mouseover resolution" },
    { "fallback",   "DFCCKBFALLBACK",  true,  "keyboard fallback diagnosis" },
    { "global",     "DFCCGLOBAL",      true,  "global bindings (apply|mouseover)" },
    { "clicks",     "DFCCDEBUGCLICKS", true,  "arm per-click tracing (until reload)" },
}

DF:RegisterDebugSlash("DFCC", "Click-casting diagnostics - run bare for the list", false, "/dfcc")
SlashCmdList["DFCC"] = function(msg)
    local word, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    word = (word or ""):lower()

    local dev = DF:IsDevBuild()

    if word ~= "" then
        for _, e in ipairs(CC_SUBCOMMANDS) do
            -- ☠ The dev flag (e[3]) has to gate EXECUTION, not just the listing
            -- below. It used to filter only the printed rows, so on a release
            -- build "/df debug cc clicks" still armed per-click tracing until
            -- reload — real overhead in the click hot path, from a command the
            -- user was never shown. Fall through to "unknown" rather than
            -- reporting "dev only": a hidden command must not advertise itself.
            if e[1] == word and (not e[3] or dev) then
                local handler = SlashCmdList[e[2]]
                if handler then
                    handler(rest or "")
                else
                    DF:Err("click-casting module not loaded")
                end
                return
            end
        end
        DF:Say("unknown click-casting command '" .. word .. "'")
    end

    local o = DF:Out("Click-Casting")
    for _, e in ipairs(CC_SUBCOMMANDS) do
        if not e[3] or dev then
            -- No %-10s padding: WoW's chat font is PROPORTIONAL, so space-padded
            -- columns do not line up. o:Item's separator does the alignment work.
            o:Item("/df debug cc " .. e[1], e[4] .. (e[3] and " (dev)" or ""))
        end
    end
end
