local addonName, DF = ...

-- ============================================================
-- TEXT DESIGNER — RESOLVER
-- Maps (elem, source) -> display string.
-- One function per content type in CONTENT_TYPES.
-- All output is a string ready for FontString:SetText.
-- ============================================================

DF.TextDesigner = DF.TextDesigner or {}
local Resolver = {}
DF.TextDesigner.Resolver = Resolver

local L = DF.L

local MS  -- lazy resolve
local function getMS()
    if not MS then MS = DF.TextDesigner.MidnightSafe end
    return MS
end

-- ============================================================
-- HELPERS
-- ============================================================

-- Truncate / ellipsize a name string per the per-element name settings.
local function applyNameTrunc(name, elem)
    local maxLen = elem.nameLength or 30
    -- 0 (or less) means "off" — matches legacy name text, whose slider is
    -- labeled "Max Length (0=off)". `or 30` does NOT rescue a stored 0 here
    -- (0 is truthy in Lua), so the explicit guard is required.
    if maxLen <= 0 then return name end
    -- UTF-8 aware so multibyte names (Korean/Chinese/accented) count by
    -- character and never get cut mid-character. Safe here: the secret-name
    -- case returns before this is ever called.
    if DF:UTF8Len(name) <= maxLen then return name end
    local mode = elem.truncateMode or "ELLIPSIS"
    if mode == "ELLIPSIS" then
        return DF:UTF8Sub(name, 1, maxLen) .. "..."
    else
        return DF:UTF8Sub(name, 1, maxLen)
    end
end

-- Secret-safe zero check for amount values. Delegates to MS.IsZeroAmount, which
-- launders the value through a FontString (the only reliable way to test a
-- secret zero — a plain `== ""` comparison taints and lets secret zeros through,
-- which is why the first attempt at hide-when-0 didn't work).
local function isBlankAmount(v)
    return getMS().IsZeroAmount(v)
end

-- Format a numeric amount respecting Abbreviate + Hide-when-0.
-- hideWhenZero defaults ON (only an explicit false disables it), so amounts
-- blank out at zero unless the element opts out. Returns "" when hidden/absent.
local function formatAmount(v, abbreviate, hideWhenZero)
    if hideWhenZero ~= false and isBlankAmount(v) then return "" end
    return getMS().FormatNumber(v, abbreviate)
end

-- Health/power value text auto-hides on dead / offline / ghost units
-- (mirrors normal frames — a dead unit shows its status, not "0%"/"0"). There
-- is no per-state option; feigning units keep their real health.
local function deadHidden(elem, source)
    return source:IsDead() or (not source:IsConnected()) or source:IsGhost()
end

-- Wrap text in a |cAARRGGBB...|r colour escape. Safe with secret text: the
-- prefix is built with format() (plain) and concatenated, and the whole thing
-- goes straight to FontString:SetText. Used for per-item colours in groups,
-- since a group is one FontString and can only multi-colour via escapes.
local function colorize(text, c)
    if not c then return text end
    local floor = math.floor
    local a = floor((c.a or 1) * 255 + 0.5)
    local r = floor((c.r or 1) * 255 + 0.5)
    local g = floor((c.g or 1) * 255 + 0.5)
    local b = floor((c.b or 1) * 255 + 0.5)
    return string.format("|c%02x%02x%02x%02x", a, r, g, b) .. text .. "|r"
end

-- Normalise a group item to an elem-like table { contentType = ... }.
-- Items are stored either as a plain type-key string (legacy / unedited) or a
-- table. Older custom-text items used { type=, text= }; migrate those to
-- { contentType=, staticText= } in place. For a string this returns a NEW
-- transient table (callers that need persistence must assign it back).
local function normalizeGroupItem(rawItem)
    if type(rawItem) == "table" then
        if rawItem.contentType == nil and rawItem.type ~= nil then
            rawItem.contentType = rawItem.type
            rawItem.type = nil
        end
        if rawItem.staticText == nil and rawItem.text ~= nil then
            rawItem.staticText = rawItem.text
            rawItem.text = nil
        end
        return rawItem
    end
    return { contentType = rawItem }
end

-- ============================================================
-- INDIVIDUAL RESOLVERS
-- ============================================================

local RESOLVERS = {}

-- ───── Identity ─────

RESOLVERS.name = function(elem, source)
    local n = source:GetName()
    if n == nil then return "" end
    -- Secret name: display verbatim (SetText accepts secrets). A `== ""` compare,
    -- or the #/sub truncation in applyNameTrunc, throws on a secret string.
    if getMS().IsSecret(n) then return getMS().SafeText(n) end
    if n == "" then return "" end
    return applyNameTrunc(getMS().SafeText(n), elem)
end

RESOLVERS.class = function(elem, source)
    -- Display localized name by default
    return getMS().SafeText(source:GetClassLocalized())
end

RESOLVERS.group_number = function(elem, source)
    local n = source:GetGroupNumber()
    if not n then return "" end
    local fmt = elem.groupFormat or "STANDALONE"
    if fmt == "PREFIX" then return "G" .. tostring(n)
    elseif fmt == "SUFFIX" then return tostring(n)
    else return "G" .. tostring(n) end  -- STANDALONE default
end

RESOLVERS.level = function(elem, source)
    -- GetLevel already returns either a number or the string "??" (it handles
    -- the secret / unknown / <=0 cases), so just coerce — never compare here.
    local lvl = source:GetLevel()
    if lvl == nil then return "" end
    return tostring(lvl)
end

RESOLVERS.race = function(elem, source)
    return getMS().SafeText(source:GetRace() or "")
end

RESOLVERS.faction = function(elem, source)
    return getMS().SafeText(source:GetFaction() or "")
end

-- Kept for backward compat with any element saved before level/race/faction
-- were split into separate content types. No longer offered in the picker.
RESOLVERS.race_level_faction = function(elem, source)
    -- Migration-only (not in the picker). Identity strings can be secret, so
    -- avoid `~= ""` and table.concat (both throw on secrets): build with `..`
    -- (secret-safe for SetText) and treat a secret value as present.
    local MS = getMS()
    local lvl = source:GetLevel()
    local race = source:GetRace()
    local fac = source:GetFaction()
    local function present(v)
        if v == nil then return false end
        if MS.IsSecret(v) then return true end
        return v ~= ""
    end
    local s, has = "", false
    if present(lvl) then s = s .. MS.SafeText(lvl); has = true end
    if present(race) then s = s .. (has and " " or "") .. MS.SafeText(race); has = true end
    if present(fac) then s = s .. (has and " " or "") .. "(" .. MS.SafeText(fac) .. ")" end
    return s
end

RESOLVERS.custom_static = function(elem, source)
    return elem.staticText or ""
end

-- ───── Health ─────

RESOLVERS.hp_current = function(elem, source)
    if deadHidden(elem, source) then return "" end
    return formatAmount(source:GetHPCurrent(), elem.abbreviate, elem.hideWhenZero)
end

RESOLVERS.hp_max = function(elem, source)
    if deadHidden(elem, source) then return "" end
    return formatAmount(source:GetHPMax(), elem.abbreviate, elem.hideWhenZero)
end

RESOLVERS.hp_percent = function(elem, source)
    if deadHidden(elem, source) then return "" end
    return getMS().PctText(source:GetHPPercent(), elem.decimals or 0, elem.hidePercent)
end

RESOLVERS.hp_deficit = function(elem, source)
    if deadHidden(elem, source) then return "" end
    -- isBlankAmount launders the value through a FontString so secret zeros are
    -- detected correctly. At zero (full health): hide when Hide-when-0 is on
    -- (default), otherwise show a plain "0" (no minus). Nonzero: "-NNN".
    local v = source:GetHPDeficit()
    if v == nil then return "" end
    if isBlankAmount(v) then
        if elem.hideWhenZero ~= false then return "" end
        return "0"
    end
    return "-" .. getMS().FormatNumber(v, elem.abbreviate)
end

RESOLVERS.hp_max_reduction = function(elem, source)
    if deadHidden(elem, source) then return "" end
    local pct = source:GetHPMaxReductionPct()
    if pct == nil then return "" end
    -- Can be secret in combat (ReducedMaxHealth.lua guards the same API call);
    -- comparison and arithmetic on a secret throw, so hide like the bar does.
    if getMS().IsSecret(pct) then return "" end
    if pct == 0 then return "" end
    -- GetUnitTotalModifiedMaxHealthPercent returns a 0..1 fraction — the
    -- Reduced Max Health bar feeds it straight into SetValue on a 0..1 bar.
    -- Scale unconditionally; the old `pct <= 1` heuristic displayed small
    -- reductions as wildly wrong percentages.
    return string.format(elem.hidePercent and "-%.0f" or "-%.0f%%", pct * 100)
end

-- ───── Power ─────

RESOLVERS.power_current = function(elem, source)
    if deadHidden(elem, source) then return "" end
    return formatAmount(source:GetPowerCurrent(), elem.abbreviate, elem.hideWhenZero)
end

RESOLVERS.power_percent = function(elem, source)
    if deadHidden(elem, source) then return "" end
    return getMS().PctText(source:GetPowerPercent(), elem.decimals or 0, elem.hidePercent)
end

RESOLVERS.power_deficit = function(elem, source)
    if deadHidden(elem, source) then return "" end
    local v = source:GetPowerDeficit()
    if v == nil then return "" end
    if isBlankAmount(v) then
        if elem.hideWhenZero ~= false then return "" end
        return "0"
    end
    return "-" .. getMS().FormatNumber(v, elem.abbreviate)
end

RESOLVERS.power_type_string = function(elem, source)
    return getMS().SafeText(source:GetPowerTypeString())
end

-- ───── Shields & Heals ─────

RESOLVERS.absorb_amount = function(elem, source)
    return formatAmount(source:GetAbsorbAmount(), elem.abbreviate, elem.hideWhenZero)
end

RESOLVERS.heal_absorb_amount = function(elem, source)
    return formatAmount(source:GetHealAbsorbAmount(), elem.abbreviate, elem.hideWhenZero)
end

RESOLVERS.incoming_heal = function(elem, source)
    local v = source:GetIncomingHealTotal()
    if v == nil then return "" end
    if elem.hideWhenZero ~= false and isBlankAmount(v) then return "" end
    return "+" .. getMS().FormatNumber(v, elem.abbreviate)
end

RESOLVERS.incoming_heal_mine = function(elem, source)
    local v = source:GetIncomingHealFromPlayer()
    if v == nil then return "" end
    if elem.hideWhenZero ~= false and isBlankAmount(v) then return "" end
    return "+" .. getMS().FormatNumber(v, elem.abbreviate)
end

-- ───── Status / Threat / Range ─────

RESOLVERS.status_text = function(elem, source)
    if not source:IsConnected() then return L["Offline"] end
    if source:IsFeignDeath() then return L["FD"] end
    if source:IsGhost() then return L["Ghost"] end
    if source:IsDead() then return L["Dead"] end
    -- Preview only: the mock unit is "alive", so show a sample status so the
    -- element is visible and stylable. NOT applied to test/live sources.
    if source._isPreviewSample and source:_isPreviewSample() then return L["Dead"] end
    return ""
end

RESOLVERS.aggro_flag = function(elem, source)
    -- UnitThreatSituation is a plain 0-3 (threat is not secret), so == is safe.
    -- Each level's text is editable; nil falls back to the default, "" hides it.
    local s = source:GetAggroFlag() or 0
    if s == 1 then return elem.aggroText1 or "+"
    elseif s == 2 then return elem.aggroText2 or "++"
    elseif s == 3 then return elem.aggroText3 or L["AGGRO"]
    end
    return ""
end

RESOLVERS.threat_percent = function(elem, source)
    local pct = source:GetThreatPercent()
    if not pct then return "" end
    -- Skip "0%" display when not threatening. For secret values we can't
    -- compare to 0, so pass through (the display will show "0%" rather
    -- than blank, which is acceptable).
    if not getMS().IsSecret(pct) and pct == 0 then return "" end
    return getMS().PctText(pct, elem.decimals or 0, elem.hidePercent)
end

RESOLVERS.range_text = function(elem, source)
    -- Editable text for both states. In-range defaults to blank (show nothing),
    -- out-of-range defaults to "OOR". nil falls back to the default; "" hides.
    if source:IsInRange() then
        local inText = elem.rangeInText or ""
        -- Preview: the mock unit is in range. If there's no in-range text to
        -- show, fall back to the OOR sample so the element is visible/stylable.
        -- NOT applied to test/live sources.
        if inText == "" and source._isPreviewSample and source:_isPreviewSample() then
            return elem.rangeOutText or L["OOR"]
        end
        return inText
    end
    return elem.rangeOutText or L["OOR"]
end

-- ───── Group (meta) ─────

-- Groups concatenate other elements' resolved text. Phase B renders
-- groups as just their separator-joined item resolutions. (The real
-- implementation will deduplicate against per-item rendering once
-- live rendering ships; preview just shows the static concatenation.)
RESOLVERS.group = function(elem, source)
    -- groupItems is an array whose entries are either a typeKey string (live
    -- data) or a table { type = "custom_static", text = "..." } for custom text.
    -- Each item resolves as if it were a standalone element (settings cascade
    -- from the group). The group's separator joins the non-empty results.
    if not elem.groupItems or #elem.groupItems == 0 then
        DF:Debug("TD", "group resolver: elem id=%s has no groupItems", tostring(elem.id))
        return ""
    end
    DF:Debug("TD", "group resolver: elem id=%s items=%d separator=%q",
        tostring(elem.id), #elem.groupItems, tostring(elem.groupSeparator or " / "))
    local MS = getMS()
    local parts = {}
    for i, rawItem in ipairs(elem.groupItems) do
        -- Each item carries its OWN formatting (per-item, not cascaded from the
        -- group). Missing flags fall back to the standard per-type defaults.
        local item = normalizeGroupItem(rawItem)
        local typeKey = item.contentType
        local itemResolver = RESOLVERS[typeKey]
        if not itemResolver then
            DF:Debug("TD", "  [%d] %s: NO RESOLVER", i, tostring(typeKey))
        else
            local ab = item.abbreviate; if ab == nil then ab = true end
            local hz = item.hideWhenZero; if hz == nil then hz = true end
            local itemElem = {
                contentType  = typeKey,
                abbreviate   = ab,
                hideWhenZero = hz,
                hidePercent  = item.hidePercent,
                decimals     = item.decimals or 0,
                staticText   = item.staticText,
                aggroText1   = item.aggroText1,
                aggroText2   = item.aggroText2,
                aggroText3   = item.aggroText3,
                rangeInText  = item.rangeInText,
                rangeOutText = item.rangeOutText,
                nameLength   = item.nameLength,
                truncateMode = item.truncateMode,
                groupFormat  = item.groupFormat,
            }
            local v = itemResolver(itemElem, source)
            local isSec = MS.IsSecret(v)
            if v then
                -- Secret strings can't be compared with == (taints execution);
                -- skip the empty-string check when v is secret. Secret strings
                -- are never empty in practice. Apply the per-item colour to the
                -- non-empty result before joining.
                if isSec or v ~= "" then
                    -- Per-item colour: class colour wins, then a custom colour,
                    -- else the group's base font colour (no escape wrapping).
                    if item.useClassColor then
                        local token = source:GetClassToken()
                        local cc = token and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[token]
                        v = cc and colorize(v, cc) or v
                    elseif item.useColor then
                        v = colorize(v, item.color)
                    end
                    parts[#parts+1] = v
                end
            end
        end
    end
    DF:Debug("TD", "group resolver: parts collected=%d", #parts)
    -- IMPORTANT: cannot use table.concat() here — it throws on secret-tainted
    -- entries ("invalid value (secret) at index N in table for 'concat'").
    -- Manual `..` concat IS safe with secret strings as long as the final
    -- result is passed straight to FontString:SetText (which it is, via
    -- Render.lua → MS.SafeText → fs:SetText). The taint propagates through
    -- the concat result; SetText accepts secret strings natively.
    local separator = elem.groupSeparator or " / "
    local result
    for i, v in ipairs(parts) do
        if i == 1 then
            result = v
        else
            result = result .. separator .. v
        end
    end
    return result or ""
end

-- ============================================================
-- PUBLIC ENTRY POINT
-- ============================================================

-- Resolve(elem, source) -> string
-- Note: pcall has been intentionally removed here. If a resolver errors,
-- we want it to surface loudly so the underlying secret-value or API bug
-- gets fixed rather than silently masked. The resolvers themselves are
-- responsible for being secret-safe.
function Resolver:Resolve(elem, source)
    if not elem or not elem.contentType then return "" end
    local fn = RESOLVERS[elem.contentType]
    if not fn then
        DF:Debug("TD", "Resolver: unknown contentType '%s' for elem id=%s",
            tostring(elem.contentType), tostring(elem.id))
        return ""
    end
    return fn(elem, source) or ""
end

-- Expose for debugging
DF.TextDesigner.Resolver._RESOLVERS = RESOLVERS

-- Shared with Options.lua so the items list can persist-normalise group items
-- (string / legacy {type,text} → { contentType = ... } table) before editing.
DF.TextDesigner.Resolver.NormalizeGroupItem = normalizeGroupItem
