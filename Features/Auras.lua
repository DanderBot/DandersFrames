local addonName, DF = ...

-- ============================================================
-- AURA FILTERING SYSTEM
-- Hooks into Blizzard's raid frame aura filtering to capture results
-- ============================================================

-- Local caching of frequently used globals and WoW API for performance
local pairs, ipairs, type, pcall, wipe = pairs, ipairs, type, pcall, wipe
local tinsert, tremove = table.insert, table.remove
local C_UnitAuras = C_UnitAuras
local UnitIsUnit = UnitIsUnit
local GetTime = GetTime

-- Additional cached API for direct aura update (Tier 1 optimization)
local UnitExists = UnitExists
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitIsConnected = UnitIsConnected
local InCombatLockdown = InCombatLockdown
local issecretvalue = issecretvalue
local strsplit = strsplit
local C_CurveUtil = C_CurveUtil
local GetAuraDataByAuraInstanceID = C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID
local IsAuraFilteredOut = C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID
local strfind = string.find

-- Table pool to reduce garbage collection
-- PERFORMANCE FIX 2025-01-20: Reuse aura entry tables instead of creating new ones
local tablePool = {}
local poolSize = 0

-- Forward declarations: these helpers are defined later in the file but used
-- by code above their definitions (the ClassifyAura defensive/dispel filter
-- pass), computing aura classification via the secret-safe
-- IsAuraFilteredOutByInstanceID API.
local BuildDirectDefensiveFilters

-- ============================================================
-- DIRECT AURA API PROVIDER
-- Queries C_UnitAuras directly with user-configured filter strings
-- Builds the native filter strings the 12.1 container rows consume.
-- ============================================================

-- Cache AuraUtil filter constants (available in 11.1+)
local AuraFilters = AuraUtil and AuraUtil.AuraFilters or {}

-- Cached filter tables per mode (rebuilt only when settings change)
-- Each is nil (show all / unavailable) or a table of individual filter strings
-- e.g. {"HELPFUL|PLAYER", "HELPFUL|RAID", "HELPFUL|BIG_DEFENSIVE"}
local cachedPartyBuffFilters = nil
local cachedRaidBuffFilters = nil
local cachedDefensiveFilters = nil   -- mode-independent

-- Build the filter string for buffs. One native group: category selection is
-- expressed via candidateFilters spell-ID maps (see BuildAuraRowConfig), so the
-- filterString only carries HELPFUL + Only Mine.
local function BuildDirectBuffFilters(db)
    return { db.directBuffOnlyMine and "HELPFUL|PLAYER" or "HELPFUL" }
end

-- Blizzard's AuraUtil.DispellableDebuffTypes verbatim — the map form of the
-- Dispellable filter in "ALL" mode. Shared READ-ONLY by reference: Blizzard
-- reads it from candidateFilters, we never mutate it (each record's cf table
-- itself is per-record; only this inner map is shared).
local DISPEL_TYPES = { Magic = true, Curse = true, Disease = true, Poison = true, Bleed = true }

-- Build the debuff filter records (native 12.1 category filters).
-- Returns nil (show all) or an array of records { filter, key, candidateFilters }
-- — the record form normalizeFilters accepts; each record becomes one container
-- group behind the single visual debuff row.
--
-- Dedup at build time (token ownership order: dispel > cc > raid): a group's
-- filterString appends "|!TOKEN" for every enabled token-backed filter with
-- higher priority than itself; the boolean-backed groups (bossrole, priority)
-- negate ALL enabled token filters. Dispellable in "ALL" mode has no token —
-- it dedups by merging excludeDispelTypes into every OTHER record instead
-- (same ownership outcome: the dispel group owns the overlap). "ANY" mode is
-- token-backed (PTR-5 DISPELLABLE) and dedups like PLAYER via "|!DISPELLABLE"
-- negations; without the token it degrades to the ALL map form. A record never
-- negates its own token. Priority×Boss/Role overlap is accepted (bools can't
-- be negated).
--
-- `claimed` (C1 row-claim dedup, ROW path only — nil on the AD facade path):
-- the set of categories owned by enabled Aura Designer debuff groups
-- (DF:GetClaimedDebuffCategories — keys boss/role/priority/crowdControl/raid/
-- dispellable). A claimed category's RECORD is dropped from the row, but its
-- negation / exclude-dispel contributions to the OTHER records are KEPT — the
-- AD group displays those auras, so the row must keep excluding them
-- everywhere. Dispellable claims are mode-agnostic (a group claiming
-- dispellable in either mode drops the row's dispel record whatever the row's
-- own mode is — simplest rule). Boss/role narrow independently: claiming only
-- boss while the row shows boss+role narrows the record to isRoleAura.
-- (A narrowed record keeps the accepted Priority×Boss/Role bool overlap above —
-- narrowing only shrinks the record's own flag, it never adds new negations.)
-- Show All short-circuits BEFORE claims — an ALL-mode row never consults them.
-- When claims empty a NON-empty selection the return is an EMPTY array (render
-- nothing) — distinct from nil (show all); normalizeFilters would map {} back
-- to show-all, so DriveDebuffFactory intercepts the empty list and parks the
-- row instead of building a container from it.
local function BuildDirectDebuffFilters(db, claimed)
    if db.directDebuffShowAll then
        -- ALL mode: no category filtering, but Hide Long Debuffs still applies as
        -- one native maxDuration record. Keep Important CANNOT be honoured here:
        -- exempting boss/role/priority needs a second un-capped record, and the
        -- ALL record can't negate those boolean flags — importants would render
        -- twice. The GUI hides the toggle in ALL mode. Claims stay unconsulted
        -- (ALL-mode rows show claimed categories too — accepted behavior).
        local allMaxDur = db.debuffMaxDurationEnabled and (db.debuffMaxDurationMinutes or 0) > 0
            and (db.debuffMaxDurationMinutes or 0) * 60 or nil
        if allMaxDur then
            return { { filter = "HARMFUL", key = "all", candidateFilters = { maxDuration = allMaxDur } } }
        end
        return nil
    end
    local dispelOn = db.debuffFilterDispellable
    local dispelMode = db.directDebuffDispellableMode
    -- ANY mode rides the PTR-5 DISPELLABLE token (any dispel type, regardless
    -- of whether anyone can dispel it). Defensive read like CrowdControl: on a
    -- client without the token this stays nil and ANY falls back to the ALL
    -- map form below (closest semantics).
    local anyToken = dispelOn and dispelMode == "ANY" and AuraFilters.Dispellable or nil
    local playerMode = dispelOn and dispelMode ~= "ALL" and dispelMode ~= "ANY"
    -- CC needs its Blizzard token; skip the group entirely if unavailable
    local ccToken = db.debuffFilterCrowdControl and AuraFilters.CrowdControl or nil
    local raidOn = db.debuffFilterRaid
    local dispelToken = AuraFilters.RaidPlayerDispellable or "RAID_PLAYER_DISPELLABLE"
    local maxDur = db.debuffMaxDurationEnabled and (db.debuffMaxDurationMinutes or 0) > 0 and (db.debuffMaxDurationMinutes or 0) * 60 or nil
    local keepImportant = db.debuffMaxDurationKeepImportant

    -- Negation suffix for a group, given which higher-priority token filters
    -- apply to it. ALL-mode dispel dedups via excludeDispelTypes (see cfFor).
    local function neg(excludeDispel, excludeCC, excludeRaid)
        local s = ""
        if excludeDispel then
            if playerMode then s = s .. "|!" .. dispelToken
            elseif anyToken then s = s .. "|!" .. anyToken end
        end
        if excludeCC and ccToken then s = s .. "|!" .. ccToken end
        if excludeRaid and raidOn then s = s .. "|!RAID" end
        return s
    end
    -- candidateFilters for one record. Hands each record its OWN table (extra
    -- is per-record); important groups (bossrole/priority) are exempt from
    -- maxDuration when Keep Important is on.
    local function cfFor(important, extra)
        local cf = extra or {}
        if dispelOn and not playerMode and not anyToken then cf.excludeDispelTypes = DISPEL_TYPES end
        if maxDur and not (important and keepImportant) then cf.maxDuration = maxDur end
        if next(cf) == nil then return nil end
        return cf
    end

    local filters = {}
    local boss, role = db.debuffFilterBoss, db.debuffFilterRole
    -- Claim-effective category flags (claimed nil = all pass; the negation/exclude
    -- machinery above deliberately keeps reading the RAW enabled flags).
    local effBoss = boss and not (claimed and claimed.boss)
    local effRole = role and not (claimed and claimed.role)
    if effBoss or effRole then
        local flag = (effBoss and effRole) and "isBossOrRoleAura" or (effBoss and "isBossAura" or "isRoleAura")
        filters[#filters + 1] = { filter = "HARMFUL" .. neg(true, true, true), key = "bossrole",
                                  candidateFilters = cfFor(true, { [flag] = true }) }
    end
    if db.debuffFilterPriority and not (claimed and claimed.priority) then
        filters[#filters + 1] = { filter = "HARMFUL" .. neg(true, true, true), key = "priority",
                                  candidateFilters = cfFor(true, { isPriorityAura = true }) }
    end
    if ccToken and not (claimed and claimed.crowdControl) then
        filters[#filters + 1] = { filter = "HARMFUL|" .. ccToken .. neg(true, false, false),
                                  key = "cc", candidateFilters = cfFor(false) }
    end
    if raidOn and not (claimed and claimed.raid) then
        filters[#filters + 1] = { filter = "HARMFUL|RAID" .. neg(true, true, false),
                                  key = "raid", candidateFilters = cfFor(false) }
    end
    if dispelOn and not (claimed and claimed.dispellable) then
        if playerMode then
            filters[#filters + 1] = { filter = "HARMFUL|" .. dispelToken,
                                      key = "dispel", candidateFilters = cfFor(false) }
        elseif anyToken then
            filters[#filters + 1] = { filter = "HARMFUL|" .. anyToken,
                                      key = "dispel", candidateFilters = cfFor(false) }
        else
            local cf = { includeDispelTypes = DISPEL_TYPES }
            if maxDur then cf.maxDuration = maxDur end
            filters[#filters + 1] = { filter = "HARMFUL", key = "dispel", candidateFilters = cf }
        end
    end
    if #filters == 0 then
        -- Claims emptied a NON-empty selection: EMPTY array = render nothing
        -- (DriveDebuffFactory intercepts — see the header comment).
        if claimed and (boss or role or db.debuffFilterPriority or ccToken or raidOn or dispelOn) then
            return filters
        end
        return nil  -- nothing selected: safe fallback = show all
    end
    return filters
end

-- Public facade over BuildDirectDebuffFilters for the Aura Designer's debuff
-- category groups (C1). The AD factory builds a facade db table from a group's
-- selection (directDebuffShowAll=false + the flat debuffFilter*/debuffMaxDuration*
-- keys) and calls this — the records come out byte-identical to a row configured
-- the same way. The AD path must NEVER pass `claimed` (claims derive FROM the AD
-- groups; feeding them back would be circular — row → claims → AD groups → this
-- facade, claim-free, is the whole chain). `claimed` exists for the ROW call
-- sites in DriveDebuffFactory only.
function DF:BuildDebuffFilterRecords(dbLike, claimed)
    return BuildDirectDebuffFilters(dbLike, claimed)
end

-- Build defensive filter table (BIG_DEFENSIVE + EXTERNAL_DEFENSIVE, nil if unavailable)
-- Assigned to the forward-declared local at the top of the file so it is
-- visible to code defined above this point.
function BuildDirectDefensiveFilters()
    if cachedDefensiveFilters then return cachedDefensiveFilters end
    local filters = {}
    if AuraFilters.BigDefensive then filters[#filters + 1] = "HELPFUL|" .. AuraFilters.BigDefensive end
    if AuraFilters.ExternalDefensive then filters[#filters + 1] = "HELPFUL|" .. AuraFilters.ExternalDefensive end
    if #filters == 0 then return nil end
    cachedDefensiveFilters = filters
    return cachedDefensiveFilters
end

-- Rebuild cached filter tables from current settings (per mode)
-- (Debuff filters are not cached — the debuff driver builds them fresh.)
function DF:RebuildDirectFilterStrings()
    local partyDb = DF:GetDB("party")
    local raidDb = DF:GetDB("raid")
    if partyDb then
        cachedPartyBuffFilters = BuildDirectBuffFilters(partyDb)
    end
    if raidDb then
        cachedRaidBuffFilters = BuildDirectBuffFilters(raidDb)
    end
    -- Defensive and dispel are mode-independent, clear to rebuild on next use
    cachedDefensiveFilters = nil

end

-- ============================================================
-- HOOK BLIZZARD'S COMPACT RAID FRAMES
-- ============================================================

-- ============================================================
-- EVENT FRAME FOR PROACTIVE UPDATES
-- ============================================================

-- (Removed) ApplyBlizzardFrameSettings — the login/roster stamp of Blizzard's
-- raidFramesDispelIndicatorType CVar from _blizzDispelIndicator. No GUI has
-- written that key since v4.3.4 (the dropdown writes dispelOverlayDispelType,
-- consumed only by DF's own overlay), so the stamp just re-imposed a frozen
-- value on Blizzard's frames every login. The key is stripped in Core.lua's
-- v5 legacy-aura cleanup.
-- DELIBERATE: this frame survives the removal above solely to feed the roster
-- diagnostics counter (/dfroster) — it tallies how many GROUP_ROSTER_UPDATE
-- handlers fire per roster change across the addon. No render work happens here.
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "GROUP_ROSTER_UPDATE" then
        if DF.RosterDebugEvent then DF:RosterDebugEvent("Auras.lua(blizz):GROUP_ROSTER_UPDATE") end
    end
end)

-- ============================================================
-- BUFF FACTORY BRIDGE
-- Routes the buff ROW through DF.AuraContainer (WoW 12.1 native aura widgets).
-- The container renders and self-updates; the drive below only keeps its
-- config current (build-once, sig-gated).
-- ============================================================

-- Is the factory buff path active for this frame right now? Excludes test mode:
-- the test drives (TestMode.lua) call DriveBuffFactory themselves with the test
-- provider, so the live update path must not double-drive.
function DF:UseFactoryForBuffs(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate: does the factory own the buff row for this mode's db? Unlike
-- UseFactoryForBuffs (the render gate, which also excludes test mode), this must NOT flip in
-- test mode — else "blocked" overlays would wrongly lift while previewing. Used by GUI when().
function DF:FactoryOwnsBuffRow(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- Curated atlas glyphs for the Aura Designer Expiry Alert.
-- Dropdowns display L[name] and store the KEY (never the label); the formatter
-- resolves key -> atlas at build time. Order = dropdown order; entry 1 is the
-- default. ⚠ EVERY atlas name here is UNVERIFIED against the live client — vet
-- each one in the atlas browser (Debug/AtlasBrowser.lua) before shipping.
DF.ExpiryAlertGlyphs = {
    { key = "WARNING",      atlas = "services-icon-warning",      name = "Warning Sign" },
    { key = "PING_WARNING", atlas = "Ping_Marker_Icon_Warning",   name = "Warning Ping" },
    { key = "PING_ATTACK",  atlas = "Ping_Marker_Icon_Attack",    name = "Attack Ping" },
    { key = "RED_X",        atlas = "UI-LFG-DeclineMark",         name = "Red X" },
    { key = "EXCLAMATION",  atlas = "QuestNormal",                name = "Exclamation Mark" },
    { key = "CLOCK",        atlas = "auctionhouse-icon-clock",    name = "Clock" },
    { key = "STAR",         atlas = "auctionhouse-icon-favorite", name = "Star" },
}

-- Expiry BORDER mode art: white-mask frame TGAs, revealed below the alert threshold via a |T
-- band and vertex-tinted (0-255) so one asset serves any colour. A scaled bitmap can't vary
-- its line weight, so THICKNESS is three separate arts (same 64px sheet, different band px).
-- NOT a glyph — Border is its own alert mode (own size/inset/colour/thickness controls).
local EXPIRE_BORDER_TEXSIZE = 64
local EXPIRE_BORDER_TEXTURES = {
    THIN   = "Interface\\AddOns\\DandersFrames\\Media\\DF_ExpireBorder_Thin",
    MEDIUM = "Interface\\AddOns\\DandersFrames\\Media\\DF_ExpireBorder",
    THICK  = "Interface\\AddOns\\DandersFrames\\Media\\DF_ExpireBorder_Thick",
    -- FILL = a solid 50%-alpha wash (not a frame) — same |T reveal, so the expiring
    -- overlay becomes a TINT over the icon instead of an outline. The whole pipeline is
    -- texture-agnostic, so this is just another "style" of the border overlay.
    FILL   = "Interface\\AddOns\\DandersFrames\\Media\\DF_ExpireBorder_Fill",
}
local function borderTexture(thickness) return EXPIRE_BORDER_TEXTURES[thickness] or EXPIRE_BORDER_TEXTURES.MEDIUM end

-- Resolve a glyph key -> its entry (atlas OR texture). Unknown/missing keys fall back to
-- entry 1 so a stale profile value still renders SOMETHING rather than a broken escape.
function DF:GetExpiryAlertGlyph(key)
    local list = DF.ExpiryAlertGlyphs
    for i = 1, #list do
        if list[i].key == key then return list[i] end
    end
    return list[1]
end

-- Cache-key token for a glyph: its atlas name (uniquely identifies the art). Used only to
-- key the formatter cache.
function DF:GetExpiryAlertAtlas(key)
    return DF:GetExpiryAlertGlyph(key).atlas
end

-- SINGLE source for the inline glyph escape, shared by the live alert band (element + inline
-- prefix) and the editor dropdown/preview so none can drift. `size` bakes into the escape —
-- the caller treats an alert change as structural.
function DF:GetExpiryAlertGlyphEscape(key, size)
    local gl = DF:GetExpiryAlertGlyph(key)
    local s = math.floor(tonumber(size) or 16)
    if s < 1 then s = 1 end
    return "|A:" .. tostring(gl.atlas) .. ":" .. s .. ":" .. s .. "|a"
end

-- Sanitize user alert text for use as a NumericRuleFormatter band format string.
-- Rule: '%' doubles to '%%' (the band format is printf-style — a bare % corrupts
-- it), control characters strip, '|' passes through UNTOUCHED (colour |c and
-- texture |T / |A escapes are legitimate user input here), no length cap.
local function SanitizeAlertText(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("%%", "%%%%"):gsub("[%z\1-\31\127]", ""))
end

-- Alert part of a duration formatKey. The native formatter is bind-frozen
-- (SetDurationText binds once per slot), so EVERY alert change is STRUCTURAL and
-- must move the slot signature -> Rebuild. Used by the Aura Designer factory
-- (its expiry-alert struct sigs append this).
function DF:GetExpiryAlertFmtKey(mode, threshold, text, glyphKey)
    if mode ~= "TEXT" and mode ~= "GLYPH" and mode ~= "BORDER" and mode ~= "TINT" then return "" end
    -- BORDER/TINT identity (colour mode / colour / inset / size / thickness) rides the struct
    -- key in DF.Expiration:StructSig, so the base key here is just mode + threshold.
    local tail = (mode == "GLYPH" and tostring(glyphKey or ""))
        or (mode == "TEXT" and tostring(text or "")) or ""
    return ":X" .. mode .. ":" .. tostring(tonumber(threshold) or 5) .. ":" .. tail
end

-- Display payload for one Expiry Alert band/preview: the sized |A atlas escape
-- (GLYPH) or the sanitized custom text, red-wrapped unless the user's own |c
-- escape already colours it (TEXT; empty text = ""). Shared by the alert-element
-- formatter below and the AD editor's canvas preview so the two can never drift.
function DF:GetExpiryAlertPayload(mode, text, glyphKey, size)
    if mode == "GLYPH" then
        return DF:GetExpiryAlertGlyphEscape(glyphKey, tonumber(size) or 14)
    end
    local txt = SanitizeAlertText(text)
    if txt ~= "" and not txt:find("|c", 1, true) then txt = "|cffff0000" .. txt .. "|r" end
    return txt
end

-- Duration-text formatters for the factory row, by format key:
--   NUMBER -> bare seconds (45), then "2m"/"1h"   (NumericRuleFormatter)
--   SHORT  -> "45s" / "2m" / "1h"                 (SecondsFormatter, OneLetter)
--   FULL   -> "45 Seconds" / "2 Minutes"          (SecondsFormatter, None = full word)
-- Blizzard's own default is SHORT-like; DF's legacy rows showed NUMBER. Built once per
-- format and cached (Blizzard securecopies the options table, so one object per format is fine).
-- {r,g,b} (0-1) -> "rrggbb" hex for the |cff escape.
local function colorToHex(c)
    local function b255(x) return math.max(0, math.min(255, math.floor((tonumber(x) or 1) * 255 + 0.5))) end
    return string.format("%02x%02x%02x", b255(c.r or c[1]), b255(c.g or c[2]), b255(c.b or c[3]))
end

-- Expiry BORDER/TINT escape: the full |T inline-texture form tinting the white-mask TGA to
-- (r,g,b from `hex`) at `width` x `height` px. |T wants HEIGHT then WIDTH:
-- path:h:w:offX:offY:texW:texH:l:r:t:b:R:G:B — trailing vertex-colour args (0-255) do the tint,
-- texW/texH + full texel range from the texture size. The art is a 64x64 square: h==w gives an
-- even frame/wash (icons); h~=w stretches it — a solid TINT fills any rectangle cleanly, a
-- frame would distort, so only TINT is ever fed a non-square rect. [LIVE 2026-07-20] Defined
-- after colorToHex so the public wrapper below can reach it (a local isn't in scope earlier).
local function borderEscapeHex(width, height, hex, texture)
    local ts = EXPIRE_BORDER_TEXSIZE
    local r = tonumber(hex:sub(1, 2), 16) or 255
    local g = tonumber(hex:sub(3, 4), 16) or 255
    local b = tonumber(hex:sub(5, 6), 16) or 255
    return "|T" .. texture .. ":" .. height .. ":" .. width .. ":0:0:" .. ts .. ":" .. ts
        .. ":0:" .. ts .. ":0:" .. ts .. ":" .. r .. ":" .. g .. ":" .. b .. "|t"
end

-- Public: one tinted escape at `width` x `height` px (height defaults to width = square) /
-- `color` ({r,g,b} 0-1) / `thickness` (THIN/MEDIUM/THICK/FILL). The AD editor's canvas preview
-- uses this; the live formatter calls borderEscapeHex per band.
function DF:GetExpiryBorderEscape(width, height, color, thickness)
    local w = math.max(1, math.floor(tonumber(width) or 18))
    local h = math.max(1, math.floor(tonumber(height) or tonumber(width) or 18))
    return borderEscapeHex(w, h, colorToHex(color or { r = 1, g = 0.2, b = 0.2 }), borderTexture(thickness))
end

-- Account-wide colour-by-time breakpoints (editable on the Colours page). Resolve to a
-- threshold-DESCENDING list of { threshold, hex } so the first match (highest threshold <=
-- remaining) wins. Falls back to the shipped low ladder if unset/malformed, and always ends
-- in a threshold-0 base band.
-- Vivid traffic-light (keep in sync with Config.lua durationColorByTimeBreakpoints).
local DEFAULT_DURATION_BREAKPOINTS = {
    { threshold = 8, hex = "5fe05f" }, { threshold = 5, hex = "ffd23d" },
    { threshold = 2, hex = "ff9838" }, { threshold = 0, hex = "f75555" },
}
-- PERCENT scale (keep in sync with Config.lua durationColorByPercentBreakpoints).
local DEFAULT_PERCENT_BREAKPOINTS = {
    { threshold = 60, hex = "5fe05f" }, { threshold = 35, hex = "ffd23d" },
    { threshold = 15, hex = "ff9838" }, { threshold = 0,  hex = "f75555" },
}
-- The BORDER ramp is expressed as PERCENT OF THE REVEAL WINDOW (100 = the threshold,
-- 0 = expiry), so it needs no re-tuning when the threshold moves (keep in sync with
-- Config.lua durationBorderColorStops).
local DEFAULT_BORDER_STOPS = {
    { threshold = 75, hex = "5fe05f" }, { threshold = 50, hex = "ffd23d" },
    { threshold = 25, hex = "ff9838" }, { threshold = 0,  hex = "f75555" },
}
-- FOUR account-wide ramps: two consumers (duration TEXT / the expiry BORDER+TINT reveal)
-- x two scales (seconds / percent). The consumer keeps only an on/off; which scale it
-- reads — and, for text, whether it blends — is account-wide on the Colours page, because
-- that is a property of the ramp rather than of any one aura row. Only ONE ramp per
-- consumer is live at a time; the other is retained so flipping the scale back finds it
-- untouched (thresholds cannot be reinterpreted between units).
local COLOR_SCALES = {
    TEXT_SECONDS   = { key = "durationColorByTimeBreakpoints",            fallback = DEFAULT_DURATION_BREAKPOINTS },
    TEXT_PERCENT   = { key = "durationColorByPercentBreakpoints",         fallback = DEFAULT_PERCENT_BREAKPOINTS  },
    BORDER         = { key = "durationBorderColorStops",                 fallback = DEFAULT_BORDER_STOPS },
}
-- Account-wide reading of each ramp. Text carries both dials; the border/tint is stepped
-- by construction (its |T escapes ignore the vertex colour a curve writes) and so carries
-- only a scale.
function DF:GetDurationTextColorScale()
    local g = DF.GetGlobalDB and DF:GetGlobalDB()
    return (g and g.durationTextColorScale == "SECONDS") and "SECONDS" or "PERCENT"
end
function DF:IsDurationTextColorSmooth()
    local g = DF.GetGlobalDB and DF:GetGlobalDB()
    return not (g and g.durationTextColorSmooth == false)
end
-- The expiry reveal's scale. Governs BOTH its colour ramp and the unit its Alert Below
-- threshold is read in — one formatter, one sampled property, so the two are inseparable.
function DF:GetDurationBorderColorScale()
    local g = DF.GetGlobalDB and DF:GetGlobalDB()
    return (g and g.durationBorderColorScale == "PERCENT") and "PERCENT" or "SECONDS"
end
local function GetDurationColorBreakpoints(scale)
    local def = COLOR_SCALES[scale] or COLOR_SCALES.TEXT_SECONDS
    local g = DF.GetGlobalDB and DF:GetGlobalDB()
    local raw = g and g[def.key]
    local out = {}
    if type(raw) == "table" then
        for _, bp in ipairs(raw) do
            local t = tonumber(bp and bp.threshold)
            if t and type(bp.color) == "table" then
                out[#out + 1] = { threshold = math.max(0, t), hex = colorToHex(bp.color), color = bp.color }
            end
        end
    end
    if #out == 0 then return def.fallback end
    table.sort(out, function(a, b) return a.threshold > b.threshold end)  -- descending
    if out[#out].threshold ~= 0 then out[#out + 1] = { threshold = 0, hex = out[#out].hex, color = out[#out].color } end
    return out
end

-- Colour hex for an absolute remaining threshold: the highest breakpoint whose threshold <= t.
local function colorHexAt(bps, t)
    for _, bp in ipairs(bps) do if t >= bp.threshold then return bp.hex end end
    return bps[#bps].hex
end

-- Stable cache signature for a breakpoints list (so an edit builds a fresh formatter).
local function breakpointsSig(bps)
    local p = {}
    for _, bp in ipairs(bps) do p[#p + 1] = bp.threshold .. ":" .. bp.hex end
    return table.concat(p, ",")
end

-- Expiry Alert (alertMode "TEXT"/"GLYPH" + alertThreshold seconds + alertText/alertAtlas):
-- extra breakpoint bands below the threshold — evaluated C-side against the SECRET
-- remaining time like everything else here; no Lua time read, works in combat.
-- ALERT-ELEMENT variant (alertElem = true, AD Expiry Alert element): the formatter IS
-- the whole output — payload band below the threshold, EMPTY band above (no countdown,
-- no colour-by-time, no hide-above; the indicator's own duration text is untouched and
-- keeps its own formatter). format/hideAboveT/colorByTime are ignored in this variant.
local function BuildDurationFormatter(format, hideAboveT, colorByTime, alertMode, alertThreshold, alertText, alertAtlas, alertElem, alertElemSize, alertGlyphKey)
    format = format or "NUMBER"
    local alertT
    if alertMode == "TEXT" or alertMode == "GLYPH" then
        alertT = tonumber(alertThreshold) or 5
        if alertT < 1 then alertT = 1 end
    else
        alertMode = nil
    end
    if alertElem then
        if not alertT then return nil end
        if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
        -- Payload composed by the shared helper for BOTH modes (GLYPH resolves
        -- key->atlas inside it), so the live band string and the editor-canvas
        -- preview (buildAlertPreview) can never drift.
        local payload = DF:GetExpiryAlertPayload(alertMode, alertText, alertGlyphKey, alertElemSize)
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            -- Two bands, emitted ascending: [0, alertT) = the payload (constant string,
            -- no numeric directive), [alertT, inf) = empty. Evaluated C-side against the
            -- SECRET remaining time — zero Lua time reads, works in combat.
            fmt:AddBreakpoint({ threshold = 0, step = 1, rounding = down, min = 1, format = payload })
            fmt:AddBreakpoint({ threshold = alertT, step = 1, rounding = down, format = "" })
            return fmt
        end)
        return ok and f or nil
    end
    -- Hide-above-threshold and/or COLOUR-BY-TIME buckets: both need per-band format
    -- strings, which only the NumericRuleFormatter has (SecondsFormatter carries none) —
    -- so SHORT/FULL are emulated with the matching unit suffix (the pre-existing
    -- hide-above tradeoff: English unit text, not locale-aware).
    --
    -- Colour-by-time: the smooth curve is NOT addon-reachable on 12.1 (see the
    -- GetDurationColorCurve tombstone below). Instead each band's format string EMBEDS a
    -- |cffRRGGBB escape; the C-side DurationTextBinding evaluates the SECRET remaining
    -- time against the breakpoints and renders the pre-coloured string — no aura read,
    -- no addon ticker, secret-safe (the DF_AuraLab-proven formatter trick). Bands are
    -- the legacy curve's colours discretised on ABSOLUTE remaining time:
    --   <5s red · 5-15s orange · 15-60s yellow · 60s+ green (fresh).
    -- (The legacy path coloured by PERCENT of total duration; a static formatter can't
    -- know the total, so absolute-seconds bands are the 12.1 equivalent.)
    if hideAboveT or colorByTime or alertT then
        if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
        local secFmt = (format == "SHORT" and "%.0fs") or (format == "FULL" and "%.0f Seconds") or "%.0f"
        local minFmt = (format == "FULL") and "%.0f Minutes" or "%.0fm"
        local hrFmt  = (format == "FULL") and "%.0f Hours"   or "%.0fh"
        local bps = colorByTime and GetDurationColorBreakpoints() or nil
        -- Blank-band start: hide-above unchanged, EXCEPT the alert region [0, alertT)
        -- always renders — an explicit alert outranks blanking, so when the user sets
        -- the alert threshold above the hide threshold the blank starts at alertT.
        local blankAt = hideAboveT
        if blankAt and alertT and alertT > blankAt then blankAt = alertT end
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            -- GLYPH alert: fixed 16px atlas escape prepended to every band that starts
            -- inside the alert region. Fixed size: the formatter is CACHED + bind-frozen
            -- while font size changes ride the LIGHTWEIGHT text update, so a font-derived
            -- size would go stale on a scale drag.
            local glyphPfx = (alertMode == "GLYPH") and (DF:GetExpiryAlertGlyphEscape(alertGlyphKey, 16) .. " ") or nil
            local cuts = {}    -- thresholds already holding a band
            local bands = {}   -- buffered: emitted ASCENDING below (the resume band
                               -- can be composed out of order; the pre-alert code
                               -- always emitted ascending, so keep that guarantee)
            -- Highest threshold <= remaining seconds wins.
            local function add(threshold, fstr, hex, components)
                if colorByTime and hex then fstr = "|cff" .. hex .. fstr .. "|r" end
                if glyphPfx and threshold < alertT then fstr = glyphPfx .. fstr end
                cuts[threshold] = true
                bands[#bands + 1] = { threshold = threshold, step = 1, rounding = down,
                                      min = 1, format = fstr, components = components }
            end
            if alertMode == "TEXT" then
                -- The whole sub-threshold region shows the custom text (countdown
                -- replaced). Red unless the user's own |c escape already colours it.
                -- Empty text = literal: a blank sub-threshold band.
                local txt = SanitizeAlertText(alertText)
                if txt ~= "" and not txt:find("|c", 1, true) then txt = "|cffff0000" .. txt .. "|r" end
                cuts[0] = true
                bands[#bands + 1] = { threshold = 0, step = 1, rounding = down, min = 1, format = txt }
            end
            -- Cut points = the configured colour thresholds (when colouring) UNION the format
            -- transitions (60s -> minutes, 3600s -> hours) UNION the base band at 0 UNION the
            -- alert resume threshold. Each band takes the colour of the highest breakpoint <=
            -- it and the number format of its range, so a colour band spanning a format
            -- boundary is split (same colour, m/h format). The blank band (hide-above, pushed
            -- up to alertT by an overlapping alert) drops every cut at/above its start — they
            -- would shadow it. TEXT alert: no cuts inside [0, alertT) — the custom text band
            -- (already buffered above) owns that whole region outright.
            local wanted = { [0] = true }
            if colorByTime then for _, bp in ipairs(bps) do wanted[bp.threshold] = true end end
            if not blankAt then wanted[60] = true; wanted[3600] = true end
            -- Resume band AT the alert threshold: above it the normal (un-alerted) format
            -- takes over. At 60+ the minute band IS the resume band.
            if alertT and alertT < 60 then wanted[alertT] = true end
            local sorted = {}
            for t in pairs(wanted) do
                if not (blankAt and t >= blankAt)
                    and not (alertMode == "TEXT" and t < alertT)
                    and not cuts[t] then
                    sorted[#sorted + 1] = t
                end
            end
            table.sort(sorted)   -- ascending
            for _, t in ipairs(sorted) do
                local hex = colorByTime and colorHexAt(bps, t) or nil
                if t >= 3600 then
                    add(t, hrFmt,  hex, { { div = 3600, step = 1, rounding = down } })
                elseif t >= 60 then
                    add(t, minFmt, hex, { { div = 60,   step = 1, rounding = down } })
                else
                    add(t, secFmt, hex)
                end
            end
            if blankAt then
                bands[#bands + 1] = { threshold = blankAt, step = 1, rounding = down, format = "" }
            end
            table.sort(bands, function(a, b) return a.threshold < b.threshold end)
            for i = 1, #bands do fmt:AddBreakpoint(bands[i]) end
            return fmt
        end)
        return ok and f or nil
    end
    if format == "NUMBER" then
        if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            fmt:AddBreakpoint({ threshold = 0,    step = 1, rounding = down, min = 1, format = "%.0f" })
            fmt:AddBreakpoint({ threshold = 60,   step = 1, rounding = down, min = 1, format = "%.0fm",
                                components = { { div = 60,   step = 1, rounding = down } } })
            fmt:AddBreakpoint({ threshold = 3600, step = 1, rounding = down, min = 1, format = "%.0fh",
                                components = { { div = 3600, step = 1, rounding = down } } })
            return fmt
        end)
        return ok and f or nil
    end
    -- SHORT / FULL: Blizzard's SecondsFormatter, differing only in the abbreviation.
    if not (C_StringUtil and C_StringUtil.CreateSecondsFormatter and C_CurveUtil and Enum) then return nil end
    local abbrev = (format == "FULL") and Enum.SecondsFormatterAbbreviation.None
                    or Enum.SecondsFormatterAbbreviation.OneLetter
    local ok, f = pcall(function()
        local fmt = C_StringUtil.CreateSecondsFormatter()
        local mult = 1.5
        local curve = C_CurveUtil.CreateCurve()
        curve:AddPoint(1 + mult * SECONDS_PER_MIN,  Enum.SecondsFormatterInterval.Minutes)
        curve:AddPoint(1 + mult * SECONDS_PER_HOUR, Enum.SecondsFormatterInterval.Hours)
        curve:AddPoint(1 + mult * SECONDS_PER_DAY,  Enum.SecondsFormatterInterval.Days)
        fmt:SetDefaultAbbreviation(abbrev)
        fmt:SetMinInterval(Enum.SecondsFormatterInterval.Seconds)
        fmt:SetMaxIntervalCurve(curve)
        fmt:SetDesiredUnitCount(1)
        -- SHORT: strip the space between number and unit ("45 s" -> "45s"; the default
        -- Preserve mode is why Short looked MORE spaced out than Number). Locale-aware:
        -- deDE/ruRU keep their space by design. FULL keeps the space ("45 Seconds").
        if format == "SHORT" and fmt.SetStripIntervalWhitespace
            and Enum.SecondsFormatterIntervalWhitespace then
            fmt:SetStripIntervalWhitespace(Enum.SecondsFormatterIntervalWhitespace.Strip)
        end
        return fmt
    end)
    return ok and f or nil
end

local durationFormatterCache = {}
local durationBreakpointsSigCache   -- memoized DF:GetDurationBreakpointsSig() string
-- Drop cached coloured formatters after a Colours-page breakpoint edit. The new formatters
-- rebind on the InvalidateAuraLayout re-drive the edit already triggers. (Uncoloured entries
-- are unaffected but wiping all is simplest and cheap — they rebuild on next demand.)
-- Anything that mutates durationColorByTimeBreakpoints MUST call this, or the memoized
-- signature below keeps the old formatter/row signatures alive.
function DF:InvalidateDurationFormatters()
    wipe(durationFormatterCache)
    durationBreakpointsSigCache = nil
    -- Colour curves are built from the same stops (DF:GetDurationColorSpec) — a stop edit
    -- must drop them too or the cached curve keeps painting the old ramp.
    if DF._wipeDurationCurves then DF:_wipeDurationCurves() end
end
local function GetDurationFormatter(format, hideAboveT, colorByTime, alertMode, alertThreshold, alertText, alertGlyphKey)
    format = format or "NUMBER"
    local key = format .. "|" .. tostring(hideAboveT or "") .. (colorByTime and "|C" or "")
    if colorByTime then key = key .. "|" .. DF:GetDurationBreakpointsSig() end
    local alertAtlas
    if alertMode == "TEXT" or alertMode == "GLYPH" then
        if alertMode == "GLYPH" then alertAtlas = DF:GetExpiryAlertAtlas(alertGlyphKey) end
        -- Distinct alert configs -> distinct cached formatters (text/atlas are part
        -- of the band strings, so they must key the cache too).
        key = key .. "|X" .. alertMode .. ":" .. tostring(tonumber(alertThreshold) or 5) .. ":"
                  .. (alertAtlas or tostring(alertText or ""))
    end
    if durationFormatterCache[key] == nil then
        durationFormatterCache[key] = BuildDurationFormatter(format, hideAboveT, colorByTime, alertMode, alertThreshold, alertText, alertAtlas) or false
    end
    return durationFormatterCache[key] or nil
end

-- The account-wide colour-by-time breakpoints signature. Folded into the STRUCTURAL
-- duration format keys (dur.formatKey here + the AD durationFmtKey) so a breakpoint edit
-- changes the row signature and forces a Rebuild — SetDurationText binds the formatter
-- ONCE per slot, so ApplyStyle alone can't swap in the recoloured formatter.
-- MEMOIZED: the AD struct sigs call this per indicator per UNIT_AURA inside syncPlacedPool,
-- a walk that is deliberately allocation-free — recomputing (GetGlobalDB scan + sort +
-- concat) there would churn garbage every aura event. The cache clears on
-- InvalidateDurationFormatters, which every breakpoint edit already fires.
function DF:GetDurationBreakpointsSig(scale)
    scale = scale or "TEXT_SECONDS"
    if scale ~= "TEXT_SECONDS" then return breakpointsSig(GetDurationColorBreakpoints(scale)) end
    if not durationBreakpointsSigCache then
        durationBreakpointsSigCache = breakpointsSig(GetDurationColorBreakpoints("TEXT_SECONDS"))
    end
    return durationBreakpointsSigCache
end

-- ============================================================
-- COLOUR-BY-TIME MODES (12.1 colour curve, build 68914+)
-- ============================================================
-- 68914 restored options.textColor on SetDurationText — it now forwards
-- SetTextColorCurve(curve, PROPERTY); the 68569 wrapper dropped the property arg, which
-- is the whole reason the curve was dead and colour shipped as |c escapes baked into the
-- formatter's bands. With the curve reachable, duration TEXT gets two independent dials:
--
--   INTERPOLATION  Linear = blends between stops · Step = snaps to the stop at or below
--   SCALE          seconds remaining · percent of total remaining
--
-- Probe-verified on 68914 (/al smoothcolor, readback in the lab log):
--   * Linear interpolates linearly in RGB and CLAMPS at both ends (below the first stop
--     and above the last) — it never falls to zero/black outside the authored range.
--   * Step FLOORS: x=2.5 yields the x=0 colour, x=7.5 the x=5 colour. That is exactly
--     DF's own "highest threshold <= remaining wins" rule, so STEP_SECONDS reproduces the
--     legacy bucket look with no compensation (no doubled points at band ends).
--   * RemainingPercent is expressed 0-100 (probe row G), matching the stops as stored.
--   * The curve writes the FONTSTRING's vertex colour, which inline |T textures IGNORE
--     (they keep their own baked vertex args). The expiry border/tint reveal is a |T
--     escape, so it can never blend — it stays stepped, and seconds-only because a static
--     formatter cannot know an aura's total duration. That asymmetry is a hard engine
--     ceiling, not a policy choice.
--   * |c escapes still beat the curve, so the legacy bucket path and a curve must never
--     both be armed on one fontstring (see the mutual exclusion in the row builders).
local DURATION_COLOR_MODES = {
    OFF            = { },
    SMOOTH_PERCENT = { scale = "TEXT_PERCENT", interp = "Linear" },
    SMOOTH_SECONDS = { scale = "TEXT_SECONDS", interp = "Linear" },
    STEP_PERCENT   = { scale = "TEXT_PERCENT", interp = "Step"   },
    STEP_SECONDS   = { scale = "TEXT_SECONDS", interp = "Step"   },
}
-- Curves need C_CurveUtil + the property enum; without them (pre-68914) every non-OFF
-- mode degrades to the legacy seconds BUCKETS, which is the only colour the old
-- SetDurationText could express.
local function curvesAvailable()
    return (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor
        and Enum and Enum.DurationTextBindingProperty and Enum.LuaCurveType) and true or false
end

-- A consumer's stored value is a plain ON/OFF; the MODE it resolves to is composed from
-- the account-wide dials, so every text consumer reads the ramp the same way and the
-- Colours page is the single place that decides how. (A stored mode STRING is still
-- honoured: an in-development profile may hold one, and "OFF" must keep meaning off.)
function DF:ResolveDurationColorMode(raw)
    if raw == false or raw == nil then return "OFF" end
    -- A stored MODE STRING means only "on". It is never honoured as a mode: the dials are
    -- account-wide by design, and a per-consumer mode would silently opt that consumer out
    -- of them. Strings exist because a development build briefly stored the mode here, and
    -- an Aura Designer indicator that picked up "STEP_SECONDS" that way rendered stepped
    -- seconds no matter what the Colours page said. Treating them as plain ON self-heals
    -- those profiles without touching stored data.
    if type(raw) == "string" and (raw == "OFF" or not DURATION_COLOR_MODES[raw]) then
        return "OFF"
    end
    local scale = (DF:GetDurationTextColorScale() == "SECONDS") and "SECONDS" or "PERCENT"
    return (DF:IsDurationTextColorSmooth() and "SMOOTH_" or "STEP_") .. scale
end

-- Colour spec for a mode: { curve, property } to hand to SetDurationText's textColor, or
-- `buckets = true` for the legacy |c-escape formatter path. Cached per mode (the curve is
-- a userdata we must keep alive anyway) and invalidated with the formatters, so a
-- Colours-page stop edit rebuilds it.
local durationCurveCache = {}
local function hexToColor(hex)
    return CreateColor((tonumber(hex:sub(1, 2), 16) or 255) / 255,
                       (tonumber(hex:sub(3, 4), 16) or 255) / 255,
                       (tonumber(hex:sub(5, 6), 16) or 255) / 255, 1)
end
function DF:GetDurationColorSpec(rawOrMode)
    local mode = DF:ResolveDurationColorMode(rawOrMode)
    if mode == "OFF" then return nil end
    local cached = durationCurveCache[mode]
    if cached ~= nil then return cached or nil end
    local def = DURATION_COLOR_MODES[mode]
    -- Pre-68914: no curve -> the legacy seconds buckets are the only expressible colour.
    if not curvesAvailable() then
        durationCurveCache[mode] = { buckets = true }
        return durationCurveCache[mode]
    end
    local ok, spec = pcall(function()
        local curve = C_CurveUtil.CreateColorCurve()
        curve:SetType(Enum.LuaCurveType[def.interp])
        -- Stops are stored DESCENDING; the curve wants ascending x. Threshold 0 is always
        -- present (GetDurationColorBreakpoints guarantees the base band), so the curve
        -- always spans from 0 and both Linear and Step clamp below it.
        local bps = GetDurationColorBreakpoints(def.scale)
        for i = #bps, 1, -1 do
            curve:AddPoint(bps[i].threshold, hexToColor(bps[i].hex))
        end
        return {
            curve    = curve,
            -- ★ Compare the FULL scale key. This briefly read `== "PERCENT"` after the
            -- scales were renamed TEXT_*/BORDER_*, which silently bound RemainingDuration
            -- (seconds) for EVERY mode — percent stops evaluated against remaining
            -- seconds, red-for-life on short auras. Field-diagnosed twice 2026-07-24
            -- (the first pass misblamed the curve domain; percent IS 0-100, matching
            -- the stops as stored).
            property = (def.scale == "TEXT_PERCENT") and Enum.DurationTextBindingProperty.RemainingPercent
                                                      or Enum.DurationTextBindingProperty.RemainingDuration,
        }
    end)
    durationCurveCache[mode] = (ok and spec) or { buckets = true }
    return durationCurveCache[mode]
end

-- Structural signature contribution for a colour mode. The curve binds ONCE per slot
-- (SetDurationText), so a mode change or a stop edit must move the row/indicator struct
-- sig and force a Rebuild — exactly like the formatter's own breakpoints sig.
function DF:GetDurationColorSig(rawOrMode)
    local mode = DF:ResolveDurationColorMode(rawOrMode)
    if mode == "OFF" then return "" end
    local def = DURATION_COLOR_MODES[mode]
    return ":C" .. mode .. ":" .. DF:GetDurationBreakpointsSig(def.scale)
end

-- True when this mode paints via the legacy |c-escape BUCKET formatter rather than a
-- curve — the formatter must then bake colour into its bands (and the two must never
-- both be armed, since escapes beat the curve).
function DF:DurationColorUsesBuckets(rawOrMode)
    local spec = DF:GetDurationColorSpec(rawOrMode)
    return (spec and spec.buckets) and true or false
end

-- Declared as a method so InvalidateDurationFormatters (defined ABOVE the cache) can
-- reach the upvalue without forward-declaring it.
function DF:_wipeDurationCurves()
    wipe(durationCurveCache)
end

-- /df cbt — colour-by-time ground truth. Reports what the engine ACTUALLY resolved
-- rather than what the Colours page shows: whether the curve APIs are reachable at all
-- (if not, every mode silently degrades to the legacy seconds buckets = stepped seconds
-- no matter what the dials say), the account-wide dials, the mode a plain enabled
-- consumer composes, and whether that mode produced a real curve or the bucket fallback.
function DF:DebugDumpColorByTime(threshold)
    local function say(fmt, ...) print(string.format(fmt, ...)) end
    say("|cff33ff99Color by Time|r")
    say("  curve APIs reachable: %s", tostring(curvesAvailable()))
    say("    C_CurveUtil.CreateColorCurve=%s CreateColor=%s DurationTextBindingProperty=%s LuaCurveType=%s",
        tostring(C_CurveUtil and C_CurveUtil.CreateColorCurve ~= nil), tostring(CreateColor ~= nil),
        tostring(Enum and Enum.DurationTextBindingProperty ~= nil), tostring(Enum and Enum.LuaCurveType ~= nil))
    local g = DF.GetGlobalDB and DF:GetGlobalDB()
    say("  stored dials: smooth=%s scale=%s", tostring(g and g.durationTextColorSmooth),
        tostring(g and g.durationTextColorScale))
    say("  resolved dials: smooth=%s scale=%s", tostring(DF:IsDurationTextColorSmooth()),
        tostring(DF:GetDurationTextColorScale()))
    local mode = DF:ResolveDurationColorMode(true)
    local spec = DF:GetDurationColorSpec(mode)
    say("  enabled consumer -> mode=%s  curve=%s  buckets=%s", tostring(mode),
        tostring(spec and spec.curve ~= nil), tostring(spec and spec.buckets == true))
    say("  sig=%s", tostring(DF:GetDurationColorSig(mode)))
    for _, s in ipairs({ "TEXT_SECONDS", "TEXT_PERCENT", "BORDER" }) do
        local bps = GetDurationColorBreakpoints(s)
        local parts = {}
        for _, bp in ipairs(bps) do parts[#parts + 1] = bp.threshold .. "=" .. tostring(bp.hex) end
        say("  %s: %s", s, table.concat(parts, " "))
    end

    -- EXPIRY REVEAL. Its bands and its Alert Below threshold are one formatter sampled
    -- against one property, so both are reported together — and only stops BELOW the
    -- threshold ever render, which is the usual "why is my top colour never showing".
    local bscale = DF:GetDurationBorderColorScale()
    local pct = (bscale == "PERCENT")
    local t = tonumber(threshold)
    if not t then t = pct and ((DF.Expiration and DF.Expiration.PERCENT_THRESHOLD_DEFAULT) or 30) or 5 end
    if t < 1 then t = 1 end
    say("|cff33ff99Expiry reveal|r  scale=%s  property=%s", bscale,
        pct and "RemainingPercent" or "RemainingDuration")
    say("  threshold %s%s (%s) — pass a number to /df cbt to test another",
        tostring(t), pct and "%" or "s",
        pct and "expiryAlertThresholdPercent" or "expiryAlertThreshold")
    -- Stops are a share of the WINDOW, so report both: the authored share and where it
    -- actually lands once scaled onto the threshold. Nothing can be dropped any more --
    -- that was the whole point of going window-relative.
    local parts = {}
    for _, bp in ipairs(GetDurationColorBreakpoints("BORDER")) do
        -- Mirror the formatter's clamp EXACTLY (a stop at 100 lands a hair under the
        -- hide band instead of being dropped) so this dump can never disagree with it.
        local at = t * math.min(tonumber(bp.threshold) or 0, 100) / 100
        if at >= t then at = t - 0.01 end
        parts[#parts + 1] = ("%d%%->%.2f%s=%s"):format(bp.threshold, at,
            pct and "%" or "s", tostring(bp.hex))
    end
    say("  bands (share of window -> where it lands): %s",
        (#parts > 0) and table.concat(parts, "  ") or "|cffff6060none|r")
    if pct then
        say("  on a 12s aura the reveal starts at %.1fs remaining", 12 * t / 100)
    end

    -- LIVE ALERTED INDICATORS: the threshold above is only the fallback — each placed
    -- indicator reads its OWN expiryAlert keys, and "reveals too late" is almost always
    -- this number. The % threshold is PER-AURA-DURATION (30% of a 12s buff = 3.6s;
    -- 100 = visible for the aura's whole life), unlike the absolute seconds one.
    local Engine = DF.AuraDesigner and DF.AuraDesigner.Engine
    local seen, found = {}, 0
    for _, adMode in ipairs({ "party", "raid" }) do
        local adDB = DF.GetModeAuraDesigner and DF:GetModeAuraDesigner(adMode)
        if adDB and not seen[adDB] then
            seen[adDB] = true
            local spec = Engine and Engine.ResolveSpec and Engine:ResolveSpec(adDB)
            local pools = {}
            if spec and adDB.auras and adDB.auras[spec] then pools[#pools + 1] = adDB.auras[spec] end
            if adDB.otherAuras then pools[#pools + 1] = adDB.otherAuras end
            for _, pool in ipairs(pools) do
                for auraName, auraCfg in pairs(pool) do
                    local inds = type(auraCfg) == "table" and auraCfg.indicators
                    if type(inds) == "table" then
                        for _, ind in ipairs(inds) do
                            if ind.expiryAlertEnabled and DF.Expiration then
                                found = found + 1
                                local liveT = DF.Expiration:Threshold(ind)
                                say("  [%s] %s %s: %s live=%s%s (stored %ss / %s%%) -> a 12s aura reveals at %.1fs",
                                    adMode, tostring(auraName), tostring(ind.type or "?"),
                                    tostring(ind.expiryAlertMode or "BORDER"),
                                    tostring(liveT), pct and "%" or "s",
                                    tostring(ind.expiryAlertThreshold), tostring(ind.expiryAlertThresholdPercent),
                                    pct and (12 * liveT / 100) or math.min(12, liveT))
                            end
                        end
                    end
                end
            end
        end
    end
    if found == 0 then say("  no alerted AD indicators found") end
end

-- Account-wide duration-text update rate (Wave 5a) -> the native binding's
-- `updateInterval` (minimum seconds between automatic text refreshes; 0 = every
-- game tick). Creation-frozen: SetDurationText forwards options.updateInterval
-- to the binding once per slot (Blizzard_CustomAuraButton.lua:164), so the value
-- rides every duration spec + struct sig (rows: rowStructSig; AD: durationFmtKey).
-- NORMAL — the default — returns NIL: the spec omits the key and the binding
-- keeps Blizzard's own default cadence. The C-side default is not documented
-- anywhere addon-readable, so the default option must not guess a number —
-- shipping is behavior-neutral by construction. MEMOIZED like the breakpoints
-- sig above (the builders/sigs run per drive); the Options dropdown fires the
-- invalidator on change.
local AURA_DURATION_UPDATE_INTERVALS = { SMOOTH = 0.1, PERFORMANCE = 1.0 }
local durationUpdateIntervalCache   -- resolved seconds, or false = NORMAL/native default
function DF:InvalidateAuraDurationUpdateInterval()
    durationUpdateIntervalCache = nil
end
function DF:GetAuraDurationUpdateInterval()
    local c = durationUpdateIntervalCache
    if c == nil then
        local g = DF.GetGlobalDB and DF:GetGlobalDB()
        c = (g and AURA_DURATION_UPDATE_INTERVALS[g.auraDurationUpdateInterval]) or false
        durationUpdateIntervalCache = c
    end
    return c or nil
end

-- Shared with the Aura Designer factory (P4.4): its placed icon/square/bar duration text
-- reuses the EXACT same secret-safe colour-by-time BUCKET formatter as the #205 buff/debuff
-- rows (|cRRGGBB escapes baked into the native NumericRuleFormatter bands, evaluated C-side).
-- Cached, so repeated SyncFrame calls return the same shared formatter object.
function DF:GetFactoryDurationFormatter(format, hideAboveT, colorByTime, alertMode, alertThreshold, alertText, alertGlyphKey)
    return GetDurationFormatter(format, hideAboveT, colorByTime, alertMode, alertThreshold, alertText, alertGlyphKey)
end

-- Expiry Alert ELEMENT formatter (AD placed indicators): the alert-element variant
-- of BuildDurationFormatter — payload below the threshold, EMPTY above; no countdown,
-- no colour-by-time (the indicator's duration text keeps its own formatter). Cached in
-- the shared duration cache under a distinct "XEL|" key prefix (duration-text keys
-- always start with the format name, so the two variants can never collide). `size`
-- keys the cache too: the GLYPH |A escape bakes it into the band string, and the
-- factory treats every alert change as STRUCTURAL (Rebuild re-binds the formatter).
function DF:GetExpiryAlertElementFormatter(mode, threshold, text, glyphKey, size)
    if mode ~= "TEXT" and mode ~= "GLYPH" then return nil end
    local alertAtlas
    if mode == "GLYPH" then alertAtlas = DF:GetExpiryAlertAtlas(glyphKey) end
    local key = "XEL|" .. mode .. ":" .. tostring(tonumber(threshold) or 5)
        .. ":" .. tostring(math.floor(tonumber(size) or 14))
        .. ":" .. (alertAtlas or tostring(text or ""))
    if durationFormatterCache[key] == nil then
        durationFormatterCache[key] = BuildDurationFormatter(nil, nil, nil,
            mode, threshold, text, alertAtlas, true, size, glyphKey) or false
    end
    return durationFormatterCache[key] or nil
end

-- Expiry BORDER element formatter (AD placed indicators): the |T frame TGA revealed below
-- the alert threshold, empty above. Two colour modes, both secret-safe (Blizzard picks the
-- band from the SECRET remaining time):
--   STATIC  -> one band, |T tinted to `staticColor`.
--   BYTIME  -> one band per BORDER-ramp step below the threshold, each |T tinted to that
--              breakpoint's colour. Breakpoints sig keys the cache (and the factory struct
--              key) so a Colours-page edit rebuilds the bind-frozen formatter.
-- The border/tint reads its OWN ramp (durationBorderColorStops), separate from
-- the duration text's: they are different media — a border reads well with two or three
-- bold steps where text carries four or five — and text can blend where this cannot (the
-- |T escapes ignore the fontstring vertex colour a colour curve writes).
-- SCALE: these bands and the reveal threshold are ONE formatter sampled against ONE
-- property, so the account-wide border scale governs both — its ramp AND the unit
-- `threshold` arrives in. On PERCENT the caller must bind this formatter to
-- RemainingPercent (Features/Expiration.lua feeds it through textFormat); binding it the
-- default way would judge percent bands against remaining seconds.
-- Cached under an "XBEL|" prefix (duration-text keys start with the format name, never "X").
function DF:GetExpiryBorderElementFormatter(threshold, width, height, colorMode, staticColor, thickness)
    if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and Enum and Enum.NumericRuleFormatRounding) then return nil end
    local alertT = tonumber(threshold) or 5
    if alertT < 1 then alertT = 1 end
    local w = math.max(1, math.floor(tonumber(width) or 18))
    local h = math.max(1, math.floor(tonumber(height) or tonumber(width) or 18))
    local tex = borderTexture(thickness)
    local byTime = (colorMode == "BYTIME")
    local scale = DF:GetDurationBorderColorScale()   -- property + threshold unit only; one ramp
    local key = "XBEL|" .. tostring(alertT) .. ":" .. tostring(w) .. "x" .. tostring(h) .. ":" .. tostring(thickness or "MEDIUM") .. ":" .. scale .. ":"
        .. (byTime and ("T:" .. DF:GetDurationBreakpointsSig("BORDER")) or ("S:" .. colorToHex(staticColor or { r = 1, g = 0.2, b = 0.2 })))
    if durationFormatterCache[key] == nil then
        local ok, f = pcall(function()
            local down = Enum.NumericRuleFormatRounding.Down
            local fmt = C_StringUtil.CreateNumericRuleFormatter()
            if byTime then
                -- One coloured band per stop, each holding its colour up to the next-higher
                -- band (mirrors colorHexAt). Stops are relative to the reveal WINDOW, so the
                -- ramp always spans exactly [0, threshold] and no stop can fall outside it —
                -- the old absolute stops silently built no band once they passed the
                -- threshold, and the topmost band's width depended on the gap to it.
                for _, bp in ipairs(GetDurationColorBreakpoints("BORDER")) do
                    -- Stops are % OF THE WINDOW, so scale each onto the threshold. A stop at
                    -- 100 (the window top) would land exactly ON the hide band — clamp it a
                    -- hair below instead of DROPPING it (the old guard silently deleted the
                    -- colour). Its band is near-zero width either way ("100% and above" of a
                    -- window that ENDS at 100); this is stored-data grace, not a real config —
                    -- a top colour wants its stop BELOW 100 (75 = the top quarter).
                    local at = alertT * math.min(tonumber(bp.threshold) or 0, 100) / 100
                    if at >= alertT then at = alertT - 0.01 end
                    fmt:AddBreakpoint({ threshold = at, step = 1, rounding = down, min = 1,
                        format = borderEscapeHex(w, h, bp.hex, tex) })
                end
            else
                fmt:AddBreakpoint({ threshold = 0, step = 1, rounding = down, min = 1,
                    format = borderEscapeHex(w, h, colorToHex(staticColor or { r = 1, g = 0.2, b = 0.2 }), tex) })
            end
            fmt:AddBreakpoint({ threshold = alertT, step = 1, rounding = down, format = "" })   -- empty above threshold
            return fmt
        end)
        durationFormatterCache[key] = (ok and f) or false
    end
    return durationFormatterCache[key] or nil
end

-- ⚠ STACKS FORMATTERS ARE FORBIDDEN on container rows — do not re-add one.
-- (Removed 2026-07-09; was the alpha.2 in-combat container freeze.) Blizzard's
-- ApplyApplicationCount calls formatter:FormatNumber(applications) in LUA with the
-- stack count, which is SECRET in combat; formatter userdata cannot hold secrets, so
-- the call throws inside the container's dirty pass → the dirty-flag latch bricks the
-- container for the session. Bind-time validation can't catch it (AssertValidFormatter
-- test-drives with a non-secret value). The native no-formatter path (shows counts > 1,
-- rendered secure-side via secretwrap) is the only secret-safe option — `stackMinimum`
-- other than 2 is therefore not expressible on 12.1 container rows. Duration-text
-- formatters are NOT affected (C-side DurationTextBinding handles secrets).

-- (Removed 2026-07-09: GetDurationColorCurve. The smooth duration-text colour curve is
-- NOT addon-reachable on 68569 — SetDurationText{textColorCurve} drops the required
-- `property` arg, and the button's DurationTextBinding is PRIVATE, so "apply it on the
-- binding" cannot work; poking Blizzard-owned binding state on a live button is also the
-- exact touch class behind the combat dirty-latch freeze. durationColorByTime ships as
-- discrete colour BUCKETS via the duration formatter (|cRRGGBB escapes in AddBreakpoint
-- format strings — C-side, secret-safe, the NSRT-proven path): BuildDurationFormatter above.)

-- (Removed 2026-07-13: BuildBuffExcludeMap / the manual aura blacklist. The filter
-- registry supersedes it — per-spell control lives in Filter Designer presets and
-- per-row filter selections. The stored data (DF.db.auraBlacklist) is kept but no
-- longer enforced; the Aura Blacklist page is a retirement notice.)

-- Stable signature of an excludeSpellIDs map (sorted IDs) — exclude-set changes
-- (AD-dedup, missing-buff hide) are TUNING (Wave 1: SetAuraGroupCandidateFilters is a
-- live mutator), so the row TUNING signature must move when the set does — the row
-- re-applies the maps in place via ApplyTuning instead of a teardown+recreate.
local function excludeSig(cf)
    local m = cf and cf.excludeSpellIDs
    if not m then return "" end
    local ids = {}
    for id in pairs(m) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- Include-map counterpart (filter-registry selection resolved to includeSpellIDs) —
-- same tuning rule: the row TUNING signature must move when the set does. Presence-marked
-- ("I:" prefix) so an EMPTY-but-present include map (include-nothing, e.g. the only
-- selected custom filter has zero spells) still differs from no map at all — the
-- all -> include-nothing transition must re-apply.
local function includeSig(cf)
    local m = cf and cf.includeSpellIDs
    if not m then return "" end
    local ids = {}
    for id in pairs(m) do ids[#ids + 1] = id end
    table.sort(ids)
    return "I:" .. table.concat(ids, ",")
end

-- Sort Order dropdown ("DEFAULT"/"TIME"/"NAME") + Mine First / Reverse checkboxes
-- -> config.sort (AuraContainerSortMethod/SortDirection member NAMES). Rides the
-- TUNING sig (rows: rowTuningSig serializes method + direction; AD groups fold
-- the raw fields into their tuning sig), so changes apply in place via
-- ApplyTuning. nil = no sort declared = Blizzard's inbound default (mine-first
-- slot order) — today's DEFAULT behaviour, kept byte-identical.
-- SHARED (Wave 2): exposed on DF so the AD group families (filter / other-buff /
-- debuff groups, AuraDesigner/Factory.lua) map their per-group sort fields
-- through the SAME function as the rows — callers feed their own storage.
function DF:BuildAuraSort(order, mineFirst, reverse)
    local method
    if order == "TIME" then
        method = mineFirst and "Expiration" or "ExpirationOnly"
    elseif order == "NAME" then
        method = mineFirst and "Name" or "NameOnly"
    elseif reverse then
        -- DEFAULT + Reverse: the direction needs an explicit method to ride on.
        method = "Default"
    end
    if not method then return nil end
    return { method = method, direction = reverse and "Reverse" or nil }
end

-- Colour-mode ramps. A StatusBar CROPS its fill texture to the filled fraction, so a
-- baked colour RAMP as the texture makes the visible tip colour walk the ramp as the
-- native fill drains: colour-by-remaining with ZERO reads, which is the only way to do
-- it in 12.1 (remaining time is secret). Two hard constraints, both probe-confirmed
-- 2026-07-20 (see the 12.1 lockdown notes + DF_AuraLab "Duration bar" verdicts):
--   * it keys off FRACTION remaining, never seconds — so it CANNOT mirror the
--     seconds-based durationColorByTimeBreakpoints thresholds, only their palette;
--   * the ramps are baked images and deliberately NOT driven by the colour pickers.
--     The fill crop clips only the statusbar's own texture (children are untouched),
--     and GetValue() returns a SECRET number, so neither a segmented ramp nor a
--     self-tinted one is possible. Don't re-litigate this without a new probe.
-- One orientation per curve. The ramp is painted for the DRAIN case: red at the left
-- end, green at the right, so the tip walks green -> red as the bar empties. That is
-- the only case there is - the bar always drains (see `direction` below), and Reverse
-- Fill needs NO mirrored art [confirmed in-game 2026-07-20]: the StatusBar flips the
-- texture along with the fill, so the ramp's relationship to the tip already survives.
local CURVE_TEXTURES = {
    DF      = "Interface\\AddOns\\DandersFrames\\Media\\DF_Curve",
    CLASSIC = "Interface\\AddOns\\DandersFrames\\Media\\Classic_Curve",
}

-- Shared predicate: does this colour mode swap the fill texture for a ramp? The GUI
-- uses it to dim Texture / Bar Color, both of which a curve mode overrides. One source
-- of truth: add a ramp to CURVE_TEXTURES above and every consumer follows.
function DF:IsDurationBarCurveMode(mode) return CURVE_TEXTURES[mode] ~= nil end
-- The ramp texture for a curve colour mode (nil for STATIC / unknown). Lets a consumer
-- outside this file (the AD bar factory) opt a StatusBar's fill into the same green->red
-- ramp the duration-bar strips use.
function DF:GetDurationBarCurveTexture(mode) return CURVE_TEXTURES[mode] end

-- Duration bar (Wave 3, #205): prefixed key block -> the engine's style.bar
-- STRIP spec (fill = false; the fill shape is AD-only). Returns nil when the
-- Enabled key is off/absent, so disabled configs stay byte-identical to
-- pre-Wave-3 output (no style.bar key at all). The tonumber clamps are
-- load-bearing: they guarantee styling (styleBarShared / strip geometry) and
-- the layout reservation (stripReservation) see the SAME number for height/gap
-- even if a profile carries garbage — both engine defaults are 4/1.
-- SHARED: rows pass (db, "buffDurationBar"/"debuffDurationBar"/
-- "defensiveDurationBar"); the AD group families pass (group.style,
-- "durationBar") — one builder, callers feed their own storage.
function DF:BuildDurationBarSpec(store, keyPrefix)
    if not store or store[keyPrefix .. "Enabled"] ~= true then return nil end
    local curve = CURVE_TEXTURES[store[keyPrefix .. "ColorMode"]]
    return {
        show        = true,
        fill        = false,   -- strip shape (out-of-rect; the engine reserves wrap space)
        position    = (store[keyPrefix .. "Position"] == "TOP") and "TOP" or "BOTTOM",
        height      = tonumber(store[keyPrefix .. "Height"]) or 4,
        gap         = tonumber(store[keyPrefix .. "Gap"]) or 1,
        -- Curve mode overrides the configured texture; `curve` tells styleBarShared to
        -- force a white tint, since any colour would multiply the ramp and muddy it.
        texture     = curve or store[keyPrefix .. "Texture"],
        curve       = curve and true or nil,
        color       = store[keyPrefix .. "Color"],
        bgColor     = store[keyPrefix .. "BGColor"],
        reverseFill = store[keyPrefix .. "ReverseFill"] and true or false,
        -- Enum.StatusBarTimerDirection MEMBER NAME, and deliberately NOT a setting.
        -- RemainingTime = the bar DRAINS; ElapsedTime (Blizzard's default, hence the
        -- explicit pass) fills from empty as the aura runs, which contradicts what a
        -- "duration bar" means and runs the colour curve backwards. Nobody wants that,
        -- so we don't expose it. Reverse Fill still flips which END it drains toward.
        direction   = "RemainingTime",
    }
end

-- Map a prefixed aura-row setting block (buff*/debuff*) -> DF.AuraContainer config.
-- prefix = "buff" (debuff reuses this later). opts.filterList is the PRE-BUILT native
-- filter list (buffs: BuildDirectBuffFilters); opts.unit is the initial unit token.
-- Scale note: layoutRow SetScale(layout.scale)'s each button, so fonts / border / spacing
-- all inherit the row scale — pass BASE (unscaled) sizes here, exactly as the db stores them.
function DF:BuildAuraRowConfig(db, prefix, opts)
    opts = opts or {}
    prefix = prefix or "buff"
    local function g(suffix) return db[prefix .. suffix] end
    local filter = opts.filterList
    if filter == nil then filter = (prefix == "debuff") and "HARMFUL" or "HELPFUL" end

    local iconSize = g("Size") or 20
    local dur
    if g("ShowDuration") ~= false then
        local durFormat = g("DurationFormat") or "NUMBER"
        -- Colour-by-time: the stored value is a MODE (legacy profiles hold a boolean —
        -- ResolveDurationColorMode maps true to STEP_SECONDS so they keep today's look).
        -- On 68914+ every mode paints through the native colour CURVE; only the pre-68914
        -- fallback bakes |c escapes into the formatter's bands, and the two are mutually
        -- exclusive because escapes beat the curve.
        local colorMode = DF:ResolveDurationColorMode(g("DurationColorByTime"))
        local colorSpec = DF:GetDurationColorSpec(colorMode)
        local colorByTime = DF:DurationColorUsesBuckets(colorMode)
        local hideAboveT = (g("DurationHideAboveEnabled") and g("DurationHideAboveThreshold")) or nil
        -- Text styling (font/scale/outline/anchor/offsets/justify/colour) is a shared
        -- DF.TextStyle spec; the factory applies it via TextStyle:Apply. The justify box
        -- is the icon rect. Feature fields (show/formatter/formatKey) ride on top.
        dur = DF.TextStyle:BuildSpec(db, prefix .. "Duration", {
            baseSize = 10, defaultAnchor = "CENTER", boxW = iconSize, boxH = iconSize,
        })
        dur.show = true
        dur.stableCenter = true   -- centred countdown: stable box, no shift, no wobble
        dur.formatter = GetDurationFormatter(durFormat, hideAboveT, colorByTime)
        -- Either colour path (curve or legacy buckets) owns the text colour outright, so
        -- the static colour must not stomp it. formatKey carries the mode + its scale's
        -- stops so a change moves the rebuild signature — BOTH the formatter and the
        -- curve are creation-frozen on the native bind.
        if colorSpec then dur.color = nil end
        dur.colorCurve, dur.colorProperty = (colorSpec and colorSpec.curve), (colorSpec and colorSpec.property)
        dur.formatKey = durFormat .. DF:GetDurationColorSig(colorMode) .. (hideAboveT and (":H" .. tostring(hideAboveT)) or "")
        -- Hide duration text on permanent auras (Wave 4, default ON): zeroText = ""
        -- flows to the native binding's zeroDurationText — Blizzard renders NO text
        -- on zero-duration/unconfigured durations. Absent key (pre-migration db)
        -- = ON; explicit false = the pre-Wave-4 spec shape (no zeroText at all).
        -- Creation-frozen (SetDurationText binds once) -> rides rowStructSig.
        if g("DurationHideOnPermanent") ~= false then dur.zeroText = "" end
        -- Duration-text update rate (Wave 5a, account-wide): nil at the NORMAL
        -- default (key absent -> the binding keeps Blizzard's default cadence,
        -- byte-identical to the pre-setting spec). Creation-frozen -> rowStructSig.
        dur.updateInterval = DF:GetAuraDurationUpdateInterval()
    end

    -- Buff rows get native spell-ID exclude maps (AD-dedup + missing-buff hide below).
    -- Debuff rows get NO spell-ID filters — harmful spell-ID maps are inert on
    -- friendly frames (the assist/attack gate).
    local candidateFilters
    if prefix == "buff" then
        -- Native max-TOTAL-duration filter (candidateFilters.maxDuration, seconds).
        -- Blizzard-side semantics: auras with duration > max OR duration == 0 are
        -- filtered — i.e. permanent auras are IMPLICITLY always hidden while this
        -- is on (documented in the GUI tooltip). Tuning: re-applied in place
        -- (SetAuraGroupCandidateFilters is a live mutator — rides the tuning sig).
        if db.buffMaxDurationEnabled and (db.buffMaxDurationMinutes or 0) > 0 then
            candidateFilters = candidateFilters or {}
            candidateFilters.maxDuration = (db.buffMaxDurationMinutes or 0) * 60
        elseif db.buffHidePermanent then
            -- Hide Permanent Auras alone: a max-FINITE cap. maxDuration rejects
            -- duration == 0 and no finite duration exceeds 2^31-1, so this hides
            -- ONLY permanents. Skipped when Hide Long Buffs already set a finite
            -- cap above — that cap rejects permanents by itself. Same tuning ride.
            candidateFilters = candidateFilters or {}
            candidateFilters.maxDuration = 2147483647
        end
        -- Missing Buff "Hide From Buff Bar": union every raid-buff ID (all ranks/
        -- variants) into the exclude map. Legacy did this with an icon-texture match
        -- in the scan, OUT of combat only (reads); the native filter holds in combat
        -- too — a strict upgrade. Tuning (rides excludeSig in the row tuning signature).
        if db.missingBuffHideFromBar and DF.RaidBuffs then
            candidateFilters = candidateFilters or {}
            local map = candidateFilters.excludeSpellIDs or {}
            candidateFilters.excludeSpellIDs = map
            for i = 1, #DF.RaidBuffs do
                local ids = DF.RaidBuffs[i][1]
                if type(ids) == "table" then
                    for j = 1, #ids do map[ids[j]] = true end
                else
                    map[ids] = true
                end
            end
        end
        -- Aura Designer dedup (derived, read-free). When the legacy "Hide Duplicate Buffs"
        -- toggle is on AND the native factory owns AD for this frame, hide every aura
        -- tracked by ANY Aura Designer indicator from the buff bar so it doesn't render
        -- twice. The set is RECOMPUTED from the AD config every time the row rebuilds
        -- (GetADTrackedSpellIDs) — no stored write, no refcount — so it is
        -- automatically correct across indicator add/remove, aura delete, profile
        -- switch and spec change. UNIONED into (never replacing) the exclude
        -- map above, and folded into the row tuning signature via excludeSig, so a
        -- change in the tracked set re-applies the buff row's candidate filters in
        -- place (see rowTuningSig / ApplyTuning). On 12.1 only
        -- the AD half of the legacy toggle is expressible — the defensive row's contents
        -- aren't enumerable as spell IDs read-free (category-filter driven).
        if db.buffDeduplicateDefensives and opts.frame and DF.GetADTrackedSpellIDs then
            local adIDs = DF:GetADTrackedSpellIDs(opts.frame, db)
            if adIDs then
                candidateFilters = candidateFilters or {}
                local map = candidateFilters.excludeSpellIDs or {}
                candidateFilters.excludeSpellIDs = map
                for id in pairs(adIDs) do map[id] = true end
            end
        end
        -- FILTER REGISTRY: fold the category selection into this group's spec.
        -- include-mode (categories selected) subtracts the exclude union above so
        -- AD-dedup / missing-buff still win inside one map; exclude-mode
        -- (Uncategorised on) unions the known-but-unselected set into it. "all"
        -- (Show All / empty selection) leaves the exclude union untouched — the
        -- pre-registry behavior, byte-for-byte.
        local res = DF.FilterRegistry:ResolveSelection(db.buffFilterSelection, db.directBuffShowAll)
        if res.kind == "include" then
            local inc = {}
            local excl = candidateFilters and candidateFilters.excludeSpellIDs
            for id in pairs(res.map) do
                if not (excl and excl[id]) then inc[id] = true end
            end
            candidateFilters = candidateFilters or {}
            candidateFilters.includeSpellIDs = inc
            candidateFilters.excludeSpellIDs = nil  -- redundant after subtraction
        elseif res.kind == "exclude" then
            candidateFilters = candidateFilters or {}
            local excl = candidateFilters.excludeSpellIDs or {}
            for id in pairs(res.map) do excl[id] = true end
            candidateFilters.excludeSpellIDs = excl
        end
    end

    -- Native sort: the legacy Sort Order dropdown (directBuffSortOrder) mapped onto
    -- AuraContainerSortMethod member NAMES, refined by the Wave-2 checkboxes.
    -- Mine First picks the composite comparators (Expiration/Name = own auras
    -- first, then the dimension); off keeps the *Only pure single-dimension
    -- sorts (the pre-Wave-2 behaviour, byte-identical with both boxes off).
    -- DEFAULT ignores Mine First (Blizzard's slot order is already mine-first;
    -- the GUI greys the box) and passes nothing — unless Reverse is on, which
    -- needs an explicit method ("Default") to hang the direction on. Reverse
    -- maps to sort.direction = "Reverse"; omitted = the engine's "Normal".
    -- The backend resolves member names against the securecopy'd global enums.
    local sort
    if prefix == "buff" then
        sort = DF:BuildAuraSort(db.directBuffSortOrder, db.directBuffSortMineFirst, db.directBuffSortReverse)
    elseif prefix == "debuff" then
        sort = DF:BuildAuraSort(db.directDebuffSortOrder, db.directDebuffSortMineFirst, db.directDebuffSortReverse)
    end

    -- Debuff rows: NATIVE dispel border when Color-by-Dispel-Type is on. The colour is
    -- applied PRIVATE-side (the dispel type is secret) — since 68824 the engine bind
    -- passes customDispelColorCurve built from the shared account palette
    -- (DF.db.dispelColors, Colors page), so DF's per-type colours ARE expressible;
    -- pre-68824 clients ignore the field and keep Blizzard's palette. Shows only on
    -- dispellable debuffs; the static DF.Border below renders always, so
    -- non-dispellable keeps the base border.
    -- Wave 5b: the spec also hosts the NATIVE dispel-type SYMBOL (colourblind letter,
    -- SetAuraSymbol) — DECOUPLED from the colour ring so either ships alone. Both are
    -- engine-written (zero aura reads); the symbol additionally renders in-game only
    -- while the colorblindMode CVar is on (test mode previews it regardless).
    local dispel
    if prefix == "debuff" then
        local colorByType = db.debuffBorderColorByType
        local showSymbol = db.debuffDispelSymbolEnabled == true
        if colorByType or showSymbol then
            dispel = { showWhenHarmful = true }
            if colorByType then
                -- thickness: match the icon's own DF border so the dispel ring reads as
                -- "the border took the dispel colour" (flat square line at the same
                -- weight; inset 0 lands exactly on it, negative insets halo outward).
                local ringSize = db.debuffBorderSize or 2
                if db.pixelPerfect and DF.PixelPerfect then ringSize = DF:PixelPerfect(ringSize) end
                dispel.nativeBorder = true
                dispel.style = "Color"
                dispel.inset = db.debuffDispelBorderInset or -2
                dispel.thickness = ringSize
            end
            if showSymbol then
                dispel.nativeSymbol = true
                -- Symbol styling is a shared TextStyle spec (the FontString is OURS;
                -- the engine only writes its text) — restyles in place via ApplyStyle.
                dispel.symbol = DF.TextStyle:BuildSpec(db, "debuffDispelSymbol", {
                    baseSize = 10, defaultAnchor = "CENTER", boxW = iconSize, boxH = iconSize,
                })
            end
        end
    end

    return {
        sort     = sort,
        unit     = opts.unit,
        mode     = "row",
        filter   = filter,
        max      = g("Max") or 5,
        -- Test-mode preview cap: the test panel's Buffs/Debuffs count sliders
        -- (hot-applied via Handle:SetTestMax from the test drive seam).
        testMax  = (prefix == "buff" and (db.testBuffCount or 2))
                or (prefix == "debuff" and (db.testDebuffCount or 2))
                or nil,
        enabled  = true,
        candidateFilters = candidateFilters,
        -- Native hover tooltips: governed by the Tooltips page's per-row Enable.
        -- (The old Integrations "click-through" toggle also suppressed them, but
        -- that's gone on 12.1 — the container icons are always click-through by
        -- design — so tooltips key off the Tooltips page alone now.)
        tooltips = db["tooltip" .. (prefix == "debuff" and "Debuff" or "Buff") .. "Enabled"] ~= false,
        layout = {
            size     = g("Size") or 20,
            scale    = g("Scale") or 1,
            spacingX = g("PaddingX") or 2,
            spacingY = g("PaddingY") or 2,
            anchor   = g("Anchor") or "BOTTOMRIGHT",
            growth   = g("Growth") or "LEFT_UP",
            wrap     = g("Wrap") or 3,
            offsetX  = g("OffsetX") or 0,
            offsetY  = g("OffsetY") or 0,
        },
        style = {
            icon   = { show = true, zoom = true, inset = 0 },
            border = g("ShowBorder") and { db = db, prefix = prefix } or nil,
            cooldown = { show = not g("HideSwipe"), reverse = true, edge = false, numbers = false },
            duration = dur,
            dispel   = dispel,
            -- Duration bar strip (nil when disabled — byte-neutral). Presence +
            -- geometry are structural (rowStructSig's s.bar entry, Wave 3.1);
            -- texture/colours restyle in place.
            bar      = DF:BuildDurationBarSpec(db, prefix .. "DurationBar"),
            -- Shared TextStyle spec (font/scale/outline/anchor/offsets/justify/colour).
            -- No formatter: forbidden on container rows (secret trap — see the
            -- GetStacksFormatter tombstone above). Native default = counts > 1.
            stacks = (function()
                local st = DF.TextStyle:BuildSpec(db, prefix .. "Stack", {
                    baseSize = 10, defaultAnchor = "BOTTOMRIGHT",
                    defaultOffsetX = 2, defaultOffsetY = -1,
                    boxW = iconSize, boxH = iconSize,
                })
                st.show = true
                return st
            end)(),
        },
    }
end

-- Canonical signature of one record's candidateFilters: boolean flags by name,
-- maxDuration, and sorted includeDispelTypes/excludeDispelTypes keys. Sorted
-- throughout so table-insertion order never moves the signature.
local function cfSig(cf)
    if not cf then return "" end
    local parts = {}
    for k, v in pairs(cf) do
        if type(v) == "boolean" then parts[#parts + 1] = k .. "=" .. tostring(v) end
    end
    table.sort(parts)
    if cf.maxDuration then parts[#parts + 1] = "max=" .. tostring(cf.maxDuration) end
    local function mapKeys(m)
        local keys = {}
        for k in pairs(m) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        return table.concat(keys, ",")
    end
    if cf.includeDispelTypes then parts[#parts + 1] = "incDispel=" .. mapKeys(cf.includeDispelTypes) end
    if cf.excludeDispelTypes then parts[#parts + 1] = "excDispel=" .. mapKeys(cf.excludeDispelTypes) end
    if cf.excludeSpellIDs then parts[#parts + 1] = "excSpell=" .. mapKeys(cf.excludeSpellIDs) end
    return table.concat(parts, "&")
end

-- Serialize cfg.filter for the row signature. Handles the three shapes
-- normalizeFilters accepts: plain string, array of strings (buff row — MUST
-- produce the exact same sig as the old table.concat(f, ";") so upgrades
-- don't spuriously rebuild buff rows), and array of records
-- { filter, key, candidateFilters } (debuff row).
local function filterListSig(f)
    if type(f) ~= "table" then return f end
    local parts = {}
    for i = 1, #f do
        local entry = f[i]
        if type(entry) == "table" then
            parts[i] = tostring(entry.filter) .. "#" .. tostring(entry.key) .. "#" .. cfSig(entry.candidateFilters)
        else
            parts[i] = entry
        end
    end
    return table.concat(parts, ";")
end

-- Public form of filterListSig for the AD debuff-group containers (C1): the
-- records DF:BuildDebuffFilterRecords returns are the exact record shape the
-- row folds into its own signature, so AD groups reuse the same serializer for
-- their structural sigs (a selection edit moves the records, the sig follows).
function DF:DebuffFilterRecordsSig(records)
    return filterListSig(records)
end

-- STRUCTURAL half of a filter list: token strings + record keys only — the parts
-- AddAuraGroup freezes (a group's filterString can't be changed live; the record SET
-- defines the groups themselves). Per-record candidateFilters are deliberately
-- EXCLUDED — they're live-tunable (see filterTuningSig).
local function filterStructSig(f)
    if type(f) ~= "table" then return tostring(f) end
    local parts = {}
    for i = 1, #f do
        local entry = f[i]
        if type(entry) == "table" then
            parts[i] = tostring(entry.filter) .. "#" .. tostring(entry.key)
        else
            parts[i] = entry
        end
    end
    return table.concat(parts, ";")
end

-- TUNING half of a filter list: each record's candidateFilters (boolean flags,
-- maxDuration, dispel-type maps via cfSig; spell-ID maps via include/excludeSig —
-- records carry none today, but the serializer must not go blind if they appear).
-- Positional, so it stays aligned with filterStructSig's record order.
-- Grammar note: the three "&"-joined components stay disambiguable because cfSig
-- parts always contain "=", includeSig is "I:"-prefixed, and excludeSig is bare
-- digits — any new token must keep its component recognisable within that grammar.
local function filterTuningSig(f)
    if type(f) ~= "table" then return "" end
    local parts = {}
    for i = 1, #f do
        local entry = f[i]
        if type(entry) == "table" then
            local cf = entry.candidateFilters
            parts[i] = cfSig(cf) .. "&" .. includeSig(cf) .. "&" .. excludeSig(cf)
        else
            parts[i] = ""
        end
    end
    return table.concat(parts, ";")
end

-- Public split halves for the AD debuff-group containers (AuraDesigner/Factory.lua,
-- Wave 1) — the record shape is the same one the row folds into its own signatures,
-- so the groups reuse the exact serializers. Struct half = record strings + keys
-- (a selection edit that changes the record SET Rebuilds); tuning half = per-record
-- candidateFilters (applies in place via ApplyTuning + the config.filter pre-swap).
-- The combined DF:DebuffFilterRecordsSig above stays as the canonical whole-record
-- serializer (harness equivalence oracle).
function DF:DebuffFilterRecordsStructSig(records)
    return filterStructSig(records)
end

function DF:DebuffFilterRecordsTuningSig(records)
    return filterTuningSig(records)
end

-- Row signatures, SPLIT (Wave 1). The old combined buffFactorySig forced a
-- teardown+recreate for every delta; now:
--   rowStructSig  — changes need a Rebuild (new container): the filter set
--     (token strings + record keys), region-presence toggles (ApplyStyle can't
--     CREATE or REMOVE a region), creation-frozen formatKeys + zeroText
--     (SetDurationText binds both once per slot), tooltips, the native dispel region.
--   rowTuningSig  — changes with the struct sig stable apply IN PLACE via
--     h:ApplyTuning (OOC immediate, combat defers to regen): max, native sort,
--     and every candidateFilters facet — config-wide include/exclude spell maps,
--     maxDuration, per-record flags/dispel maps.
-- Everything in neither sig is a plain in-place ApplyStyle (cosmetics).
local function rowStructSig(cfg)
    local s = cfg.style
    return table.concat({
        filterStructSig(cfg.filter), tostring(cfg.tooltips),
        tostring(s.duration ~= nil), tostring(s.duration and s.duration.formatKey),
        -- zeroText (hide-on-permanent, Wave 4): creation-frozen — SetDurationText
        -- forwards it to the binding once per slot. "" (on) vs nil (off) must Rebuild.
        tostring(s.duration and s.duration.zeroText),
        -- updateInterval (duration-text update rate, Wave 5a): creation-frozen the
        -- same way; nil at the NORMAL default, so only a non-default rate moves it.
        tostring(s.duration and s.duration.updateInterval),
        tostring(s.stacks and s.stacks.formatKey),
        tostring(s.border ~= nil), tostring(s.cooldown and s.cooldown.show ~= false),
        tostring(s.dispel ~= nil),          -- native dispel border (region is create-once -> Rebuild)
        -- Wave 5b: the dispel spec hosts TWO independent create-once regions (colour
        -- ring + colourblind symbol) — presence of EACH is structural on its own
        -- (ApplyStyle can't create/remove either; the symbol bind is also bind-once).
        tostring(s.dispel and s.dispel.nativeBorder), tostring(s.dispel and s.dispel.nativeSymbol),
        -- Duration bar: region is create-once (presence -> Rebuild), and strip geometry
        -- reserves layout space OUTSIDE the button rect (Wave 3.2), so shape/position/
        -- height/gap changes are structural too — the reservation must re-derive.
        tostring(s.bar ~= nil), tostring(s.bar and (tostring(s.bar.fill) .. ":" .. tostring(s.bar.position) .. ":" .. tostring(s.bar.height) .. ":" .. tostring(s.bar.gap))),
    }, "|")
end

local function rowTuningSig(cfg)
    local cf = cfg.candidateFilters
    return table.concat({
        tostring(cfg.max),
        tostring(cfg.sort and cfg.sort.method),      -- live: SetAuraGroupSortMethod
        tostring(cfg.sort and cfg.sort.direction),
        includeSig(cf), excludeSig(cf), cfSig(cf),   -- config-wide candidateFilters (cfSig carries maxDuration)
        filterTuningSig(cfg.filter),                 -- per-record candidateFilters (debuff row)
    }, "|")
end

-- Drive the factory buff row for one frame. Creates the container lazily, hides the legacy
-- icons (no double row), keeps it on the frame's unit, and applies setting changes. The
-- container self-updates from UNIT_AURA, so there is no per-tick render here.
function DF:DriveBuffFactory(frame, db)
    local h = frame.buffFactory
    if not h then
        h = DF.AuraContainer:Create(frame, DF:BuildAuraRowConfig(db, "buff", {
            unit = frame.unit,
            frame = frame,   -- for the derived Aura Designer buff-bar dedup union
            filterList = BuildDirectBuffFilters(db),
        }))
        frame.buffFactory = h
        frame.dfBuffFactoryVersion = DF.auraLayoutVersion or 0
        if h then
            frame.buffFactoryStructSig = rowStructSig(h.config)
            frame.buffFactoryTuningSig = rowTuningSig(h.config)
        end
    end

    if not h then return end

    -- Row-level opacity (legacy per-icon buffAlpha; container-frame children multiply it).
    -- BUILD-ONCE-LEAVE-IT: the standing container's frame tree is written ONLY on actual
    -- change, never per-event — the combat-proven DF_AuraLab pattern builds once and lets
    -- Blizzard drive; DriveBuffFactory runs per UNIT_AURA/range tick, so unconditional
    -- writes here would re-touch the live tree many times a second in combat.
    local rowAlpha = db.buffAlpha or 1
    if frame.dfBuffFactoryAlpha ~= rowAlpha then
        frame.dfBuffFactoryAlpha = rowAlpha
        h:GetFrame():SetAlpha(rowAlpha)
    end

    -- Keep the container on the frame's current unit. OOC retargets immediately; in combat
    -- the factory defers the retarget, so hide the row until regen rather than show the
    -- previous unit's buffs. Hide via the PLAIN anchor frame (GetFrame():SetShown), NOT
    -- h:SetShown -- the latter also queues an 'enable' op which, paired with the queued
    -- 'retarget', would upgrade to a full rebuild (frame leak). The container's own
    -- OnShow/OnHide drive event (de)registration. (SetUnit combat-legality is queued for Krathe.)
    if h:GetUnit() ~= frame.unit then
        h:SetUnit(frame.unit)
        frame.dfBuffFactoryHidden = InCombatLockdown() or nil
    elseif frame.dfBuffFactoryHidden and not InCombatLockdown() then
        frame.dfBuffFactoryHidden = nil
    end
    -- Show/hide only on state change (no per-event SetShown churn on the live tree).
    local rowShown = not frame.dfBuffFactoryHidden
    if frame.dfBuffFactoryShown ~= rowShown then
        frame.dfBuffFactoryShown = rowShown
        h:GetFrame():SetShown(rowShown)
    end

    -- Apply setting changes only when the layout version actually bumped — and only OUT
    -- of combat. In combat the standing container is left completely alone (the lab's
    -- proven pattern: existing containers keep running in combat; every addon-side
    -- re-touch — restyle, rebuild, SetFrameLevel, formatter churn — is a divergence).
    -- The version stays stale so the first OOC drive catches up.
    local ver = DF.auraLayoutVersion or 0
    if frame.dfBuffFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfBuffFactoryVersion = ver
        local cfg = DF:BuildAuraRowConfig(db, "buff", {
            unit = frame.unit,
            frame = frame,   -- for the derived Aura Designer buff-bar dedup union
            filterList = BuildDirectBuffFilters(db),
        })
        -- Re-apply the z-order level (buffs default to +40 = legacy parity). Not part of the sig.
        h:GetFrame():SetFrameLevel(math.max(0, frame:GetFrameLevel() + (cfg.frameLevelOffset or 40)))
        local structSig, tuningSig = rowStructSig(cfg), rowTuningSig(cfg)
        if frame.buffFactoryStructSig ~= structSig then
            frame.buffFactoryStructSig = structSig
            frame.buffFactoryTuningSig = tuningSig
            h:Rebuild(cfg)                      -- structural (filter set/regions/tooltips) — discrete, leak-safe
        else
            if frame.buffFactoryTuningSig ~= tuningSig then
                frame.buffFactoryTuningSig = tuningSig
                -- Per-record candidateFilters ride cfg.filter; the struct sig pins
                -- every record's filter string + key, so the fresh list is
                -- group-identical and applyGroupTuning re-derives per-record
                -- filters from it (keys line up with the declared groups).
                h.config.filter = cfg.filter
                h:ApplyTuning(cfg)              -- max/sort/candidateFilters — in place, no leak
            end
            h:ApplyStyle(cfg.style, cfg.layout) -- cosmetics — in place, no leak
        end
    end
end

-- ============================================================
-- DEBUFF FACTORY BRIDGE (P3) — mirror of the buff bridge with debuff keys.
-- Filter list = the native direct-debuff filters; dispel colouring = the native
-- SetAuraBorder Color style (Blizzard palette — custom per-type colours are not
-- expressible on 12.1; pickers frosted). Debuff rows get NO spell-ID candidate
-- filters: harmful spell-ID maps do nothing on friendly frames (Meorawr gate).
-- ============================================================

-- Render gate (excludes test mode, which paints legacy icons directly).
function DF:UseFactoryForDebuffs(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate (does NOT exclude test mode — see FactoryOwnsBuffRow).
function DF:FactoryOwnsDebuffRow(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- Drive the factory debuff row for one frame. Structure identical to DriveBuffFactory
-- (see its comments for the build-once / combat-defer / version-gate reasoning).
--
-- Row-claim dedup (C1): the filter records are built with the Aura Designer's
-- claimed-category set (DF:GetClaimedDebuffCategories — nil when AD is off /
-- doesn't own AD / has no debuff groups), so categories an enabled AD debuff
-- group displays are dropped from the row. Claims fold into the row signature
-- for free — they change the RECORDS, and filterListSig serializes the records
-- — so a claim/unclaim (which rides an auraLayoutVersion bump from the AD GUI's
-- structural refresh) re-enters the version gate below and rebuilds.
--
-- EMPTY-LIST PARK: claims can empty a non-empty selection (every selected
-- category claimed). normalizeFilters maps an EMPTY filter list back to
-- "HELPFUL" (show all), so an emptied row must never reach the container —
-- park instead: hide the plain anchor frame (combat-safe, no backend op) and
-- stamp dfDebuffFactoryEmptyVer so steady-state drives return without
-- rebuilding records. The next version bump re-evaluates the claims.
-- Merge the debuff blacklist (db.debuffBlacklist) into the debuff row's filter
-- records as excludeSpellIDs. ROW-ONLY (never the AD debuff-group facade). A nil
-- filterList (show-all) becomes one HARMFUL record carrying just the exclude; an
-- empty array (fully claimed) is left parked. Called in DriveDebuffFactory BEFORE
-- the row signature is taken, so a blacklist toggle moves cfSig and re-tunes the
-- row (cfSig now serializes excludeSpellIDs). No-op when nothing is blacklisted.
local function applyDebuffBlacklist(filterList, db)
    local blMap = DF.AuraBlacklist and DF.AuraBlacklist.BuildExcludeMap
        and DF.AuraBlacklist.BuildExcludeMap(db.debuffBlacklist)
    if not blMap then return filterList end
    if filterList == nil then
        return { { filter = "HARMFUL", key = "bl", candidateFilters = { excludeSpellIDs = blMap } } }
    end
    if #filterList == 0 then return filterList end   -- fully claimed: nothing to exclude from
    for i = 1, #filterList do
        local rec = filterList[i]
        local cf = rec.candidateFilters or {}
        cf.excludeSpellIDs = blMap
        rec.candidateFilters = cf
    end
    return filterList
end

function DF:DriveDebuffFactory(frame, db)
    local ver = DF.auraLayoutVersion or 0
    if frame.dfDebuffFactoryEmptyVer then
        if frame.dfDebuffFactoryEmptyVer == ver or InCombatLockdown() then return end
        frame.dfDebuffFactoryEmptyVer = nil   -- version moved: fall through and re-evaluate
    end

    local h = frame.debuffFactory
    if not h then
        local filterList = BuildDirectDebuffFilters(db,
            DF.GetClaimedDebuffCategories and DF:GetClaimedDebuffCategories(frame, db))
        filterList = applyDebuffBlacklist(filterList, db)
        if filterList and #filterList == 0 then
            frame.dfDebuffFactoryEmptyVer = ver   -- fully claimed: no container at all
            return
        end
        h = DF.AuraContainer:Create(frame, DF:BuildAuraRowConfig(db, "debuff", {
            unit = frame.unit,
            filterList = filterList,
        }))
        frame.debuffFactory = h
        frame.dfDebuffFactoryVersion = ver
        if h then
            frame.debuffFactoryStructSig = rowStructSig(h.config)
            frame.debuffFactoryTuningSig = rowTuningSig(h.config)
        end
    end

    if not h then return end

    local rowAlpha = db.debuffAlpha or 1
    if frame.dfDebuffFactoryAlpha ~= rowAlpha then
        frame.dfDebuffFactoryAlpha = rowAlpha
        h:GetFrame():SetAlpha(rowAlpha)
    end

    if h:GetUnit() ~= frame.unit then
        h:SetUnit(frame.unit)
        frame.dfDebuffFactoryHidden = InCombatLockdown() or nil
    elseif frame.dfDebuffFactoryHidden and not InCombatLockdown() then
        frame.dfDebuffFactoryHidden = nil
    end
    local rowShown = not frame.dfDebuffFactoryHidden
    if frame.dfDebuffFactoryShown ~= rowShown then
        frame.dfDebuffFactoryShown = rowShown
        h:GetFrame():SetShown(rowShown)
    end

    if frame.dfDebuffFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfDebuffFactoryVersion = ver
        local filterList = BuildDirectDebuffFilters(db,
            DF.GetClaimedDebuffCategories and DF:GetClaimedDebuffCategories(frame, db))
        filterList = applyDebuffBlacklist(filterList, db)
        if filterList and #filterList == 0 then
            -- Fully claimed while a container stands: park it hidden (plain anchor,
            -- combat-safe) until a version bump changes the claim set.
            h:GetFrame():Hide()
            frame.dfDebuffFactoryShown = false
            frame.dfDebuffFactoryEmptyVer = ver
            return
        end
        local cfg = DF:BuildAuraRowConfig(db, "debuff", {
            unit = frame.unit,
            filterList = filterList,
        })
        h:GetFrame():SetFrameLevel(math.max(0, frame:GetFrameLevel() + (cfg.frameLevelOffset or 40)))
        local structSig, tuningSig = rowStructSig(cfg), rowTuningSig(cfg)
        if frame.debuffFactoryStructSig ~= structSig then
            frame.debuffFactoryStructSig = structSig
            frame.debuffFactoryTuningSig = tuningSig
            h:Rebuild(cfg)                      -- structural — REPLACES the config wholesale
        else
            if frame.debuffFactoryTuningSig ~= tuningSig then
                frame.debuffFactoryTuningSig = tuningSig
                -- hideLong minutes / Keep Important within a stable category set
                -- live in the RECORDS' candidateFilters — swap the (group-identical)
                -- list so applyGroupTuning re-derives them (see the buff driver).
                h.config.filter = cfg.filter
                h:ApplyTuning(cfg)              -- max/sort/candidateFilters — in place, no leak
            end
            h:ApplyStyle(cfg.style, cfg.layout) -- cosmetics — in place, no leak
        end
    end
end

-- ============================================================
-- DEFENSIVE-ICON FACTORY BRIDGE (pilot — first non-buff consumer)
-- Routes the defensive row through DF.AuraContainer on 12.1 using the native
-- BIG_DEFENSIVE / EXTERNAL_DEFENSIVE filters. Reuses the buff bridge's config SHAPE
-- + rowStructSig/rowTuningSig (the element-agnostic row signatures). Defensive settings have a
-- different key layout (defensiveIcon* + defensiveBar*), so they get a dedicated
-- mapper rather than the prefix builder. Native-only on 12.1 (requires
-- on) + IsSupported → no effect on live 12.0.x.
-- Known v1 gaps (native filters can't exclude specific instances until PTR-4):
-- no AD/buff dedup, no range fade, CENTER growth falls back to RIGHT.
-- ============================================================

-- Render gate (excludes test mode, which paints legacy icons directly).
function DF:UseFactoryForDefensive(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and BuildDirectDefensiveFilters() ~= nil
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate (does NOT exclude test mode, so a "blocked" overlay doesn't
-- flicker while previewing). Mirrors DF:FactoryOwnsBuffRow.
function DF:FactoryOwnsDefensiveRow(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()
        and BuildDirectDefensiveFilters() ~= nil) or false
end

-- Map the defensive settings -> the AuraContainer config SHAPE. Filter = the native
-- defensive list the legacy classifier already uses; a row of up to defensiveBarMax
-- icons. Stacks use the legacy min-2 display. rowStructSig/rowTuningSig treat this cfg
-- the same as a buff cfg (they read derived fields, not db keys).
function DF:BuildDefensiveRowConfig(db, unit)
    local iconSize = db.defensiveIconSize or 24
    local dur
    if db.defensiveIconShowDuration ~= false then
        -- Colour-by-time mode + curve (see the buff/debuff row builder for the mechanism).
        local colorMode = DF:ResolveDurationColorMode(db.defensiveIconDurationColorByTime)
        local colorSpec = DF:GetDurationColorSpec(colorMode)
        local colorByTime = DF:DurationColorUsesBuckets(colorMode)
        -- Shared TextStyle spec (picks up defensiveIconDurationFont/Scale/Outline/X/Y/
        -- JustifyH/JustifyV/Color); feature fields ride on top.
        dur = DF.TextStyle:BuildSpec(db, "defensiveIconDuration", {
            baseSize = 10, defaultAnchor = "CENTER", boxW = iconSize, boxH = iconSize,
        })
        dur.show = true
        dur.stableCenter = true   -- centred countdown: stable box, no shift, no wobble
        dur.formatter = GetDurationFormatter("NUMBER", nil, colorByTime)
        if colorSpec then dur.color = nil end
        dur.colorCurve, dur.colorProperty = (colorSpec and colorSpec.curve), (colorSpec and colorSpec.property)
        dur.formatKey = "NUMBER" .. DF:GetDurationColorSig(colorMode)
        -- Hide duration text on permanent auras (Wave 4, default ON — see the
        -- buff/debuff row builder for the mechanism notes).
        if db.defensiveIconDurationHideOnPermanent ~= false then dur.zeroText = "" end
        -- Duration-text update rate (Wave 5a, account-wide; nil at the NORMAL default).
        dur.updateInterval = DF:GetAuraDurationUpdateInterval()
    end

    -- FILTER REGISTRY: the category selection drives the row as ONE plain HELPFUL
    -- group + a spell-ID map (include = selected presets/customs; exclude =
    -- Uncategorised complement). "all" (empty/absent selection) keeps the legacy
    -- token fallback below — the pre-registry behavior, byte-for-byte.
    -- SINGLE group (12.1): overlapping groups render DUPLICATE buttons — the container
    -- has no cross-group dedup and addon-side dedup is impossible (button contents are
    -- secret). Guardian Spirit proved BIG ∩ EXTERNAL ≠ ∅; externals are classified as
    -- big defensives (Blizzard's BigDefensive comparator expects them in ONE list), so
    -- one BIG_DEFENSIVE group covers the row with no dupes. Legacy/test mode keeps the
    -- two-filter scan + Lua dedup (BuildDirectDefensiveFilters) — different pipeline.
    -- IN-GAME CHECK: if an external-only defensive (e.g. PS/Ironbark on someone) stops
    -- showing, external ⊄ big on this build — revert to BuildDirectDefensiveFilters().
    local factoryFilter, defensiveCandidates
    local res = DF.FilterRegistry:ResolveSelection(db.defensiveFilterSelection, false)
    if res.kind == "include" then
        factoryFilter = { "HELPFUL" }
        defensiveCandidates = { includeSpellIDs = res.map }
    elseif res.kind == "exclude" then
        factoryFilter = { "HELPFUL" }
        defensiveCandidates = { excludeSpellIDs = res.map }
    else -- "all": legacy token fallback (empty selection safety net)
        if AuraFilters.BigDefensive then factoryFilter = { "HELPFUL|" .. AuraFilters.BigDefensive }
        elseif AuraFilters.ExternalDefensive then factoryFilter = { "HELPFUL|" .. AuraFilters.ExternalDefensive } end
    end

    return {
        unit     = unit,
        mode     = "row",
        adBorderAnim = true,   -- opt into DF-owned border animations (see buildPlacedConfig)
        filter   = factoryFilter or BuildDirectDefensiveFilters(),
        candidateFilters = defensiveCandidates,
        max      = db.defensiveBarMax or 4,
        enabled  = true,
        -- Native sort per the Sort Order dropdown (tuning-only — the filter string
        -- never moves with it). EXTERNALS (the default) = the shipped BigDefensive
        -- order: longest-duration external first, own defensives last
        -- (AuraUtil.BigDefensiveAuraCompare) — "show me the save someone else put
        -- on this player". TIME = soonest-to-expire first (ExpirationOnly).
        -- DEFAULT = nil = Blizzard's inbound slot order.
        sort     = (function()
            local o = db.defensiveSortOrder
            if o == "DEFAULT" then return nil end
            if o == "TIME" then return { method = "ExpirationOnly" } end
            return { method = "BigDefensive" }
        end)(),
        -- P5 preview: HELPFUL category alone would page the buff pool — show
        -- curated defensives instead (TestMode drives testMax per role).
        testPool = "defensives",
        tooltips = db.tooltipDefensiveEnabled ~= false,
        -- Z-order: match the legacy defensive level — contentOverlay+26 = frame+51 when auto
        -- (defensiveIconFrameLevel 0), else the user's own offset. Applied to the container's
        -- anchor frame in AuraContainer:Create + on each layout-version re-apply.
        frameLevelOffset = (db.defensiveIconFrameLevel and db.defensiveIconFrameLevel ~= 0)
            and db.defensiveIconFrameLevel or 51,
        layout = {
            size     = db.defensiveIconSize or 24,
            scale    = db.defensiveIconScale or 1,
            spacingX = db.defensiveBarSpacing or 2,
            spacingY = db.defensiveBarSpacing or 2,
            anchor   = db.defensiveIconAnchor or "CENTER",
            growth   = db.defensiveBarGrowth or "RIGHT_DOWN",
            wrap     = db.defensiveBarWrap or 5,
            offsetX  = db.defensiveIconX or 0,
            offsetY  = db.defensiveIconY or 0,
            preScaledStep = false,   -- legacy defensive spacing (unscaled size term; no double-scale)
        },
        style = {
            icon   = { show = true, zoom = true, inset = 0 },
            border = (db.defensiveIconShowBorder ~= false) and { db = db, prefix = "defensiveIcon" } or nil,
            cooldown = { show = not db.defensiveIconHideSwipe, reverse = true, edge = false, numbers = false },
            duration = dur,
            -- Duration bar strip (nil when disabled — byte-neutral; see the buff row).
            bar      = DF:BuildDurationBarSpec(db, "defensiveDurationBar"),
            -- TextStyle-shaped spec (defensive stacks have no db keys — legacy fixed
            -- look, size/outline explicit now that TextStyle owns the render defaults).
            -- No formatter: forbidden on container rows (secret trap — see the
            -- GetStacksFormatter tombstone above). Native default = counts > 1.
            stacks = {
                show      = true,
                anchor    = "BOTTOMRIGHT",
                offsetX   = 2,
                offsetY   = -1,
                size      = 14,
                outline   = "OUTLINE",
            },
        },
    }
end

-- Drive the factory defensive row for one frame. Mirrors DriveBuffFactory: lazy create,
-- hide the legacy defensive pool (no double render), keep on the frame's unit, re-apply
-- on a layout-version bump. The container self-updates from UNIT_AURA (no per-tick render).
function DF:DriveDefensiveFactory(frame, db)
    local h = frame.defensiveFactory
    if not h then
        h = DF.AuraContainer:Create(frame, DF:BuildDefensiveRowConfig(db, frame.unit))
        frame.defensiveFactory = h
        frame.dfDefFactoryVersion = DF.auraLayoutVersion or 0
        if h then
            frame.defensiveFactoryStructSig = rowStructSig(h.config)
            frame.defensiveFactoryTuningSig = rowTuningSig(h.config)
        end
    end

    if not h then return end

    -- Keep on the frame's unit; defer a wrong-unit show until regen in combat. Hide via the
    -- plain anchor frame (GetFrame():SetShown), NOT h:SetShown -- the latter queues an enable
    -- op that would upgrade a queued retarget into a full rebuild (frame leak).
    if h:GetUnit() ~= frame.unit then
        h:SetUnit(frame.unit)
        frame.dfDefFactoryHidden = InCombatLockdown() or nil
    elseif frame.dfDefFactoryHidden and not InCombatLockdown() then
        frame.dfDefFactoryHidden = nil
    end
    -- Show/hide only on state change (no per-event SetShown churn on the live tree —
    -- build-once-leave-it, mirrors DriveBuffFactory).
    local rowShown = not frame.dfDefFactoryHidden
    if frame.dfDefFactoryShown ~= rowShown then
        frame.dfDefFactoryShown = rowShown
        h:GetFrame():SetShown(rowShown)
    end

    -- Re-apply settings only on a layout-version bump (defensive option changes bump it
    -- via UpdateAllDefensiveBars -> InvalidateAuraLayout) — and only OUT of combat: the
    -- standing container is never re-touched in lockdown (lab parity); the stale version
    -- catches up on the first OOC drive.
    local ver = DF.auraLayoutVersion or 0
    if frame.dfDefFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfDefFactoryVersion = ver
        local cfg = DF:BuildDefensiveRowConfig(db, frame.unit)
        -- Re-apply the z-order level (honors runtime defensiveIconFrameLevel changes; survives
        -- Rebuild since the new container inherits relative to h.frame). Not part of the sig.
        h:GetFrame():SetFrameLevel(math.max(0, frame:GetFrameLevel() + (cfg.frameLevelOffset or 40)))
        local structSig, tuningSig = rowStructSig(cfg), rowTuningSig(cfg)
        if frame.defensiveFactoryStructSig ~= structSig then
            frame.defensiveFactoryStructSig = structSig
            frame.defensiveFactoryTuningSig = tuningSig
            h:Rebuild(cfg)                      -- structural (filter set/regions/tooltips)
        else
            if frame.defensiveFactoryTuningSig ~= tuningSig then
                frame.defensiveFactoryTuningSig = tuningSig
                h.config.filter = cfg.filter    -- group-identical records (see the buff driver)
                h:ApplyTuning(cfg)              -- max/sort/candidateFilters — in place, no leak
            end
            h:ApplyStyle(cfg.style, cfg.layout) -- cosmetics — in place, no leak
        end
    end
end

-- ============================================================
-- MISSING-BUFF FACTORY BRIDGE — read-free layout-push inversion (probe 32,
-- live-confirmed 2026-07-10). One "missing"-mode handle per tracked raid buff:
-- an empty spellID-filtered group parks the badge inside a clip window; the
-- buff's (blank) button pushes it out. ZERO aura reads — works in combat on
-- every assistable unit, independent of the transitional whitelist. Replaces
-- the legacy UnitHasBuff 4-method scan on 12.1.
-- Behaviour change vs legacy (flagged in the port plan §2.5): manual multi-buff
-- mode shows EVERY tracked-and-missing buff as a strip of badges — the old
-- "first missing only" priority pick was a cross-aura read, which is dead.
-- Class-detection mode (one buff) is identical to legacy.
-- ============================================================

local MISSING_BADGE_SIZE = 24   -- fallback when missingBuffIconSize is unset; missingBuffIconScale scales the strip
local MISSING_BADGE_GAP  = 2

-- Render gate (excludes test mode; the test drive calls the factory itself).
function DF:UseFactoryForMissingBuff(frame, db)
    return DF.AuraContainer and DF.AuraContainer.IsSupported()
        and not (DF.testMode or DF.raidTestMode)
end

-- GUI-facing predicate (does NOT exclude test mode — see FactoryOwnsBuffRow).
function DF:FactoryOwnsMissingBuff(db)
    return (DF.AuraContainer and DF.AuraContainer.IsSupported()) or false
end

-- Tracked raid buffs per settings: class-detection = only YOUR class's buff;
-- manual = every enabled missingBuffCheck* key. Returns DF.RaidBuffs entries
-- ({spellIDOrTable, configKey, name, class}) in DF.RaidBuffs order.
local function missingTrackedBuffs(db)
    local list = {}
    local playerKey
    if db.missingBuffClassDetection then
        playerKey = DF.ClassToRaidBuff and DF.ClassToRaidBuff[select(2, UnitClass("player"))]
        if not playerKey then return list end   -- class has no raid buff -> nothing to track
    end
    for i = 1, #DF.RaidBuffs do
        local info = DF.RaidBuffs[i]
        if (playerKey and info[2] == playerKey) or (not playerKey and db[info[2]]) then
            list[#list + 1] = info
        end
    end
    return list
end

-- Structural signature: the tracked set (cell handles are created per entry).
local function missingFactorySig(tracked)
    local keys = {}
    for i = 1, #tracked do keys[i] = tracked[i][2] end
    return table.concat(keys, ",")
end

-- Per-cell container config: HELPFUL + includeSpellIDs (any rank/variant ID of
-- the tracked buff matches). Helpful spell-ID maps apply on assistable units —
-- exactly the frames this feature targets (the badge is guard-hidden elsewhere).
local function buildMissingCellConfig(info, unit, size)
    local ids = type(info[1]) == "table" and info[1] or { info[1] }
    local map = {}
    for i = 1, #ids do map[ids[i]] = true end
    return {
        unit = unit,
        mode = "missing",
        filter = "HELPFUL",
        candidateFilters = { includeSpellIDs = map },
        badge = { w = size, h = size },
        enabled = true,
    }
end

-- Outward reach (px) of the missing-buff border animation — how far it extends BEYOND
-- the icon. The clip window keeps this much transparent margin around the badge so the
-- animation shows outside the icon when the buff is missing, and the layout-push grows to
-- match so it does NOT leak onto buffed units (the badge + its spill both clear the window
-- when the buff is present). Returns 0 when there's no border animation, so a non-animated
-- badge keeps the exact icon-sized window as before. Conservative — over-estimating is
-- harmless (the extra margin is transparent, and a bigger push still just clips off-window):
--   negative inset pushes the art out · offset shifts it · the effect's own glow/particles
--   reach ~half the icon at scale 1.
local function missingAnimSpill(db, badgeSize)
    if db.missingBuffIconShowBorder == false then return 0 end
    local t = db.missingBuffIconBorderAnimationType
    if not t or t == "NONE" then return 0 end
    local inset = db.missingBuffIconBorderAnimationInset or 0
    local offX  = math.abs(db.missingBuffIconBorderAnimationOffsetX or 0)
    local offY  = math.abs(db.missingBuffIconBorderAnimationOffsetY or 0)
    local scale = math.max(1, db.missingBuffIconBorderAnimationScale or 1)
    -- The anim rect (host) is the icon inset-adjusted by the animation inset (negative =
    -- larger). Some effects flare well past their steady state during the one-shot INTRO —
    -- Proc's contracting burst (PROC_BURST_SCALE 150/42 of the host) and Flash's opening
    -- outer glow (2F, F = host*1.4) — so size the window to the intro, not the loop, else
    -- the intro clips at the window edge. Others hug the border ~half the icon.
    local host = badgeSize - 2 * inset
    local artOut
    if t == "DF_PROC" then
        artOut = (host * (150 / 42) - badgeSize) / 2
    elseif t == "DF_FLASH" then
        artOut = (host * 2 * 1.4 - badgeSize) / 2
    else
        artOut = math.max(0, -inset) + badgeSize * 0.5 * scale
    end
    local out = math.max(0, artOut) + math.max(offX, offY)
    out = math.min(badgeSize * 5, math.max(0, math.ceil(out)))
    -- pp: the spill enters the badge's anchor offsets and the window size — a
    -- fractional-pixel spill shifts the badge off the grid (uneven border). Snap
    -- it in the strip's scaled space like the badge size/pitch.
    if out > 0 and db.pixelPerfect and DF.PixelPerfect then
        local ss = db.missingBuffIconScale or 1.5
        out = DF:PixelPerfect(out * ss) / ss
    end
    return out
end

-- Paint one cell's badge: spell icon + unified DF.Border (missingBuffIcon* keys).
-- The badge frame's POSITION derives from the container's secret size (§20c):
-- never pixel-snap it or read its rect; secretRect borders render anchor-only.
-- Animation is stripped like the container rows (expiry-triggered anim is dead
-- and the badge should match the aura buttons' treatment).
local function styleMissingBadge(h, db, frame, info)
    local badge = h.GetBadgeFrame and h:GetBadgeFrame()
    if not badge then return end
    local firstID = type(info[1]) == "table" and info[1][1] or info[1]
    if not badge.dfIcon then
        badge.dfIcon = badge:CreateTexture(nil, "ARTWORK")
        badge.dfIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    local iconTex
    if C_Spell and C_Spell.GetSpellTexture then iconTex = C_Spell.GetSpellTexture(firstID)
    elseif GetSpellTexture then iconTex = GetSpellTexture(firstID) end
    badge.dfIcon:SetTexture(iconTex)

    local showBorder = db.missingBuffIconShowBorder ~= false
    -- pp: no manual pre-snap here — the badge renders inside the strip's SetScale
    -- (layoutMissingStrip), so Border:Apply snaps via spec.renderScale below and the
    -- art inset goes through the same SnapThickness so both land identically.
    local borderSize = db.missingBuffIconBorderSize or 2
    if not badge.dfBorder then
        badge.dfBorder = DF.Border:New(badge, { frameLevelOffset = 0, secretRect = true })
    end
    local spec = DF.Border:BuildSpec(db, "missingBuffIcon", { unit = frame.unit, frame = frame, iconMode = true })
    spec.enabled = showBorder
    spec.size = borderSize
    spec.renderScale = db.missingBuffIconScale or 1.5   -- the strip's SetScale (layoutMissingStrip)
    -- DF_DASH sizes its dash layout from the border's frame width/height; the badge's
    -- rect is SECRET (secretRect on the container button subtree, reading it taints), so
    -- feed the configured badge size for the dash math to use instead.
    spec.knownWidth = db.missingBuffIconSize or MISSING_BADGE_SIZE
    spec.knownHeight = spec.knownWidth
    -- Animate only via the DF-owned (taint-safe) types — the LCG glows SetParent
    -- their pooled frames onto the secretRect badge, which is forbidden on the native
    -- button subtree. Continuous animation is safe now: the shared anim driver hosts on
    -- UIParent and the badge's border is torn down in _teardownContainer's StopAnimation
    -- pass (the GUI already hides the LCG types; this guards stale/imported profiles).
    local safeAnim = DF.AuraContainer and DF.AuraContainer.SAFE_BORDER_ANIM
    if spec.animation and not (safeAnim and safeAnim[spec.animation.type]) then
        spec.animation = nil
    end
    DF.Border:Apply(badge.dfBorder, spec)

    local artInset = showBorder
        and DF.Border:SnapThickness(borderSize, db.pixelPerfect, spec.renderScale) or 0
    badge.dfIcon:ClearAllPoints()
    badge.dfIcon:SetPoint("TOPLEFT", artInset, -artInset)
    badge.dfIcon:SetPoint("BOTTOMRIGHT", -artInset, artInset)
end

-- pp: the badge subtree renders under the strip's SetScale — quantize the badge
-- size in that scaled space so every cell window / badge edge lands on whole
-- physical pixels. Field-caught (/df ppdump): a raw size rendered the cell at
-- 28.13 physical px — the right/top edges straddled the grid and the badge
-- border drew visibly thicker on one side.
local function missingBadgeSizeFor(db)
    local size = db.missingBuffIconSize or MISSING_BADGE_SIZE
    if db.pixelPerfect and DF.PixelPerfect then
        local ss = db.missingBuffIconScale or 1.5
        size = DF:PixelPerfect(size * ss) / ss
    end
    return size
end

-- Whole-pixel cell pitch (badge size + gap) in strip space — cells 2+ otherwise
-- accumulate fractional offsets (size must already be quantized by the caller).
local function missingPitchFor(db, size)
    local gap = MISSING_BADGE_GAP
    if db.pixelPerfect and DF.PixelPerfect then
        local ss = db.missingBuffIconScale or 1.5
        gap = DF:PixelPerfect(gap * ss) / ss
    end
    return size + gap
end

-- Position/scale/level the strip (the OUR-side outer frame all cells live in) —
-- mirrors the missingBuffIcon* position keys, applied to the strip. The strip
-- is a plain DF frame (non-secret rect): pixel-snap is fine HERE.
local function layoutMissingStrip(frame, db, strip, cellCount)
    local size = missingBadgeSizeFor(db)
    local w = cellCount * size + math.max(0, cellCount - 1) * MISSING_BADGE_GAP
    strip:SetSize(math.max(w, 1), size)
    strip:SetScale(db.missingBuffIconScale or 1.5)
    local anchor = db.missingBuffIconAnchor or "CENTER"
    strip:ClearAllPoints()
    strip:SetPoint(anchor, frame, anchor, db.missingBuffIconX or 0, db.missingBuffIconY or 0)
    DF:SnapPointToPixelGrid(strip, db.pixelPerfect)
    local frameLevel = db.missingBuffIconFrameLevel or 0
    if frameLevel == 0 and frame.contentOverlay then
        strip:SetFrameLevel(frame.contentOverlay:GetFrameLevel() + 10)
    else
        strip:SetFrameLevel(math.max(0, frame:GetFrameLevel() + frameLevel))
    end
end

-- Drive the missing-buff strip for one frame. Mirrors the row drives: lazy create,
-- hide the legacy icon (no double render), guard visibility on the NON-aura state
-- (dead/offline/range/UnitCanAssist — the read-free mechanism only answers aura
-- presence), keep cells on the frame's unit, re-apply on a layout-version bump.
function DF:DriveMissingBuffFactory(frame, db)

    local strip = frame.missingBuffStrip
    local cells = frame.missingFactory

    -- Feature off -> hide the strip (keep the cells; cheap re-show on re-enable).
    if not db.missingBuffIconEnabled then
        if strip and frame.dfMissingStripShown ~= false then
            strip:Hide()
            frame.dfMissingStripShown = false
        end
        return
    end

    -- Lazy strip + cells; recreate the cells when the tracked set changes (rare:
    -- settings toggle / class-detection flip). Handle creation is combat-guarded
    -- inside the factory (defers the container build to regen).
    local tracked = missingTrackedBuffs(db)
    if #tracked == 0 then
        -- Nothing to track (no manual buffs checked / class has no raid buff):
        -- drop any stale cells and keep the strip hidden.
        if cells then
            for _, h in pairs(cells) do h:Destroy() end
            frame.missingFactory = nil
            frame.missingFactorySig = nil
        end
        if strip and frame.dfMissingStripShown ~= false then
            strip:Hide()
            frame.dfMissingStripShown = false
        end
        return
    end
    -- Badge size is NOT in the signature: it hot-applies through h:SetBadgeSize
    -- (live group-layout mutator + our frames) in the version-gated block below —
    -- a size slider drag must never recreate containers (per-tick churn).
    local badgeSize = missingBadgeSizeFor(db)
    local sig = missingFactorySig(tracked)
    if not strip then
        strip = CreateFrame("Frame", nil, frame.contentOverlay or frame)
        frame.missingBuffStrip = strip
        frame.dfMissingStripShown = nil
    end
    if not cells or frame.missingFactorySig ~= sig then
        if cells then
            for _, h in pairs(cells) do h:Destroy() end
        end
        cells = {}
        frame.missingFactory = cells
        frame.missingFactorySig = sig
        frame.dfMissingFactoryVersion = DF.auraLayoutVersion or 0
        local spill = missingAnimSpill(db, badgeSize)
        -- pp: whole-pixel cell pitch in the STRIP's scaled space (the strip carries
        -- missingBuffIconScale), else cells 2+ accumulate fractional offsets and
        -- their badge borders render uneven while cell 1's are clean.
        local pitch = missingPitchFor(db, badgeSize)
        for i = 1, #tracked do
            local info = tracked[i]
            local cellCfg = buildMissingCellConfig(info, frame.unit, badgeSize)
            cellCfg.badge.spill = spill   -- transparent room for the border animation to spill outside the icon
            local h = DF.AuraContainer:Create(strip, cellCfg)
            if h then
                h:ClearAllPoints()
                -- Shift the (spill-enlarged) window left by the spill so the CENTRED badge
                -- still lands on the badge-pitch grid — icon position unchanged, window grows.
                h:SetPoint("LEFT", strip, "LEFT", (i - 1) * pitch - spill, 0)
                styleMissingBadge(h, db, frame, info)
                cells[info[2]] = h
            end
        end
        layoutMissingStrip(frame, db, strip, #tracked)
    end

    -- Non-aura visibility guards: the badge must never claim "missing" on a
    -- corpse / offline / out-of-range / unassistable unit. All non-secret reads;
    -- range mirrors the legacy issecretvalue guard. DELIBERATE change vs legacy:
    -- no UnitIsPlayer — legacy excluded NPC group members because its aura SCAN
    -- couldn't check them, but raid buffs are castable on follower-dungeon NPCs
    -- (Krathe-verified) and the read-free widget works on any assistable unit.
    -- Pets stay excluded (pet frames don't run this feature).
    local unit = frame.unit
    local visible
    if DF.AuraContainer and DF.AuraContainer._testMode then
        -- P5 preview: fabricated test units fail every unit API — visibility is
        -- the test panel's toggle (UpdateTestMissingBuff gates on it before
        -- calling). The badges show because missing containers stay DISABLED
        -- for the test session (the provider bounce skips them), so every
        -- group is empty and every badge sits parked in its window.
        visible = true
    else
        visible = unit and UnitExists(unit)
            and not UnitIsDeadOrGhost(unit) and UnitIsConnected(unit)
            and not frame.isPetFrame and UnitCanAssist("player", unit)
        if visible then
            local inRange = frame.dfInRange
            if issecretvalue and issecretvalue(inRange) then
                visible = false
            elseif inRange == false then
                visible = false
            end
        end
    end
    visible = visible and true or false
    if frame.dfMissingStripShown ~= visible then
        frame.dfMissingStripShown = visible
        strip:SetShown(visible)
    end

    -- Keep cells on the frame's unit (roster churn); refresh the border spec with
    -- the new unit's class/role colour. Combat: SetUnit self-defers in the factory.
    local trackedByKey
    for key, h in pairs(cells) do
        if h:GetUnit() ~= unit then
            h:SetUnit(unit)
            if not trackedByKey then
                trackedByKey = {}
                for i = 1, #tracked do trackedByKey[tracked[i][2]] = tracked[i] end
            end
            if trackedByKey[key] then styleMissingBadge(h, db, frame, trackedByKey[key]) end
        end
    end

    -- Re-apply settings on a layout-version bump only, out of combat (build-once-
    -- leave-it: the badges/strip are ours, but the cadence mirrors the row drives).
    -- Size hot-applies per cell (window/badge/cell mutators) + cells re-space.
    local ver = DF.auraLayoutVersion or 0
    if frame.dfMissingFactoryVersion ~= ver and not InCombatLockdown() then
        frame.dfMissingFactoryVersion = ver
        layoutMissingStrip(frame, db, strip, #tracked)
        local spill = missingAnimSpill(db, badgeSize)
        for i = 1, #tracked do
            local info = tracked[i]
            local h = cells[info[2]]
            if h then
                if h.SetBadgeSize then h:SetBadgeSize(badgeSize, badgeSize) end
                -- Live-apply the animation spill (grows window/push, re-centres badge) with
                -- no teardown, so a slider drag re-flows the spill without restarting the anim.
                if h.SetBadgeSpill then h:SetBadgeSpill(spill) end
                h:ClearAllPoints()
                h:SetPoint("LEFT", strip, "LEFT", (i - 1) * missingPitchFor(db, badgeSize) - spill, 0)
                styleMissingBadge(h, db, frame, info)
            end
        end
    end
end

-- Immediately re-drive the factory rows on every active frame (out of combat).
-- The drives normally run inside the aura update cycle, so a GUI layout change —
-- which only bumps auraLayoutVersion — would otherwise apply "one aura event late"
-- (the live slider lag). Called from DF:InvalidateAuraLayout right after the bump.
-- Cheap when nothing changed: each drive is version-gated and its ApplyStyle path
-- uses the container's live layout mutators (no rebuild). Pinned-set frames catch
-- up on their next aura event (they share the same version check).
local function driveFactoryRowsNow(frame)
    if not frame or not frame.unit then return end
    local db = DF:GetFrameDB(frame)
    if not db then return end
    if db.showBuffs and DF:UseFactoryForBuffs(frame, db) then
        DF:DriveBuffFactory(frame, db)
    end
    if db.showDebuffs and DF:UseFactoryForDebuffs(frame, db) then
        DF:DriveDebuffFactory(frame, db)
    end
    if db.defensiveIconEnabled and DF:UseFactoryForDefensive(frame, db) then
        DF:DriveDefensiveFactory(frame, db)
    end
    if db.missingBuffIconEnabled and DF:UseFactoryForMissingBuff(frame, db) then
        DF:DriveMissingBuffFactory(frame, db)
    end
    -- Un-gated on the enable setting: the drive tears its container down when the
    -- overlay is off, so a GUI disable applies on this pass rather than one late.
    if DF.UseFactoryForDispelOverlay and DF:UseFactoryForDispelOverlay(frame, db) then
        DF:DriveDispelOverlayFactory(frame, db)
    end
    -- Aura Designer factory sync: AD otherwise re-syncs on the next aura event only,
    -- so a Filter Designer edit (which bumps auraLayoutVersion) would leave filter-
    -- group containers one event stale. The sync is cheap when nothing changed
    -- (sig-compare walk) — same gating as UpdateAuras_Enhanced.
    if DF.IsAuraDesignerEnabled and DF:IsAuraDesignerEnabled(frame)
        and DF.AuraDesigner and DF.AuraDesigner.Factory
        and DF.UseFactoryForAD and DF:UseFactoryForAD(frame, db) then
        DF.AuraDesigner.Factory:SyncFrame(frame)
    end
end

-- DEBOUNCED to one pass per frame-render: GUI callbacks often bump the version
-- several times in one click (Invalidate + UpdateAllFrames chains), and slider
-- drags fire per tick — coalescing keeps a 40-man raid drag at one drive pass
-- per rendered frame instead of one per callback. The 0-delay timer re-checks
-- combat when it fires (timers can land after lockdown re-engages).
local factoryRefreshQueued = false
function DF:RefreshFactoryRows()
    if factoryRefreshQueued then return end
    if not (DF.AuraContainer and DF.AuraContainer.IsSupported and DF.AuraContainer.IsSupported()) then return end
    factoryRefreshQueued = true
    C_Timer.After(0, function()
        factoryRefreshQueued = false
        if InCombatLockdown() then return end   -- drives self-defer in combat; version catches up at next drive
        if DF.IteratePartyFrames then DF:IteratePartyFrames(driveFactoryRowsNow) end
        if DF.IterateRaidFrames then DF:IterateRaidFrames(driveFactoryRowsNow) end
    end)
end

function DF:UpdateAuras_Enhanced(frame)
    if not frame or not frame.unit then return end

    -- PERF TEST: Skip if disabled
    if DF.PerfTest and not DF.PerfTest.enableAuras then return end

    -- Use raid DB for raid frames, party DB for party frames
    local db = DF:GetFrameDB(frame)

    -- Factory buff row (experimental). Compute once. If a container was built but the factory
    -- path is no longer active (dev toggle off, test mode, or showBuffs off),
    -- hide it via its plain anchor frame (combat-safe, queues no backend op) so the legacy
    -- render can't double up. DriveBuffFactory re-shows it when it drives.
    local buffFactoryActive = db.showBuffs and DF:UseFactoryForBuffs(frame, db)
    if frame.buffFactory and not buffFactoryActive then
        frame.buffFactory:GetFrame():Hide()
        frame.dfBuffFactoryShown = false   -- keep DriveBuffFactory's shown-cache coherent
    end
    local debuffFactoryActive = db.showDebuffs and DF:UseFactoryForDebuffs(frame, db)
    if frame.debuffFactory and not debuffFactoryActive then
        frame.debuffFactory:GetFrame():Hide()
        frame.dfDebuffFactoryShown = false
    end
    -- Missing-buff strip mirror: hide it when the factory path goes inactive (test
    -- mode enter / feature off) so the legacy/test render can't double up.
    local missingFactoryActive = db.missingBuffIconEnabled and DF:UseFactoryForMissingBuff(frame, db)
    if frame.missingBuffStrip and not missingFactoryActive and frame.dfMissingStripShown then
        frame.missingBuffStrip:Hide()
        frame.dfMissingStripShown = false
    end

    -- Aura Designer runs when enabled; standard buffs can coexist if showBuffs is on.
    local adEnabled = DF:IsAuraDesignerEnabled(frame)
    if adEnabled then
        -- Run AD engine (indicators, frame effects, etc.). On 12.1 the native factory
        -- bridge (DF.AuraDesigner.Factory) owns AD when DF:UseFactoryForAD is true; the
        -- legacy read-path engine stays byte-for-byte reachable when the gate is false
        -- (pre-12.1 clients, test mode, or adUseFactory=false).
        if DF.AuraDesigner and DF.AuraDesigner.Factory and DF:UseFactoryForAD(frame, db) then
            DF.AuraDesigner.Factory:SyncFrame(frame)
        end

    end


    -- Buff display: the native container renders the row (Blizzard-driven).
    -- Shown when: AD is off, OR AD is on with showBuffs enabled (coexistence)
    if (not adEnabled or db.showBuffs) and buffFactoryActive then
        DF:DriveBuffFactory(frame, db)
    end

    -- Debuff display (always runs — AD doesn't manage debuffs)
    if debuffFactoryActive then
        DF:DriveDebuffFactory(frame, db)
    end
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

local OriginalUpdateAuras = nil
local enhancedAurasInitialized = false

local function InitializeEnhancedAuras()
    if enhancedAurasInitialized then return end

    -- Replace UpdateAuras with enhanced version
    if DF.UpdateAuras and not OriginalUpdateAuras then
        OriginalUpdateAuras = DF.UpdateAuras
        DF.UpdateAuras = DF.UpdateAuras_Enhanced
    elseif not DF.UpdateAuras then
        -- DF.UpdateAuras doesn't exist yet - define it directly
        DF.UpdateAuras = DF.UpdateAuras_Enhanced
    end

    enhancedAurasInitialized = true

end

-- ============================================================
-- CRITICAL: Initialize synchronously, not with delay!
-- During combat reload, delayed initialization would fire AFTER combat
-- lockdown re-establishes, causing UpdateAuras to use the old (non-cached)
-- version instead of the Blizzard-cache-based enhanced version.
-- ============================================================
InitializeEnhancedAuras()

-- ============================================================
-- SAFEGUARD: Ensure enhanced version is used even if Icons.lua
-- loads after Auras.lua (shouldn't happen, but be defensive)
-- ============================================================
local auraInitFrame = CreateFrame("Frame")
auraInitFrame:RegisterEvent("ADDON_LOADED")
auraInitFrame:SetScript("OnEvent", function(self, event, arg1)
    if arg1 == "DandersFrames" then
        -- Double-check that enhanced version is active
        if DF.UpdateAuras ~= DF.UpdateAuras_Enhanced then
            if DF.UpdateAuras then
                OriginalUpdateAuras = DF.UpdateAuras
            end
            DF.UpdateAuras = DF.UpdateAuras_Enhanced
        end
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

-- ============================================================
-- HIDE/SHOW BLIZZARD RAID FRAMES
-- Blizzard mode: hide containers, strip events but keep UNIT_AURA
-- Direct mode: fully disable frames (unregister ALL events,
--   reparent party frames to hidden parent — Grid2 pattern)
-- ============================================================

-- Track if we've installed hooks (only do once)
local blizzardHooksInstalled = false

-- Track which frames have been stripped so we can restore them
local strippedFrames = {}

-- Track frames that have been reparented to the hidden frame
local reparentedFrames = {}

-- Hidden parent frame for fully disabling Blizzard frames (Grid2 pattern)
local blizzardHiddenParent = CreateFrame("Frame")
blizzardHiddenParent:Hide()

-- Track if Direct-mode full disable is active
DF.blizzardFramesFullyDisabled = false

-- Function to strip events from a Blizzard unit frame
-- fullDisable=true: unregister ALL events (Direct mode, no Blizzard aura data needed)
-- fullDisable=false: keep UNIT_AURA + combat events (Blizzard mode, need aura cache)
local function StripUnitFrameEvents(frame, fullDisable)
    if not frame then return end
    local unit = frame.unit
    if unit then
        pcall(function()
            frame:UnregisterAllEvents()
            if not fullDisable then
                -- Re-register UNIT_AURA so Blizzard's aura cache keeps updating
                frame:RegisterUnitEvent("UNIT_AURA", unit)
                -- Keep combat events for proper updates
                frame:RegisterEvent("PLAYER_REGEN_ENABLED")
                frame:RegisterEvent("PLAYER_REGEN_DISABLED")
            end
        end)
        strippedFrames[frame] = true
    end
end

-- Reparent a frame to the hidden parent (fully removes it from the visual tree)
local function ReparentToHidden(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    pcall(function()
        if frame.GetParent then
            reparentedFrames[frame] = frame:GetParent()
        end
        frame:SetParent(blizzardHiddenParent)
        frame:Hide()
    end)
end

-- Restore a reparented frame back to its original parent
local function RestoreParent(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    local originalParent = reparentedFrames[frame]
    if originalParent then
        pcall(function()
            frame:SetParent(originalParent)
        end)
        reparentedFrames[frame] = nil
    end
end

-- Function to restore all events on a frame (call Blizzard's setup function)
local function RestoreUnitFrameEvents(frame)
    if not frame then return end
    if not strippedFrames[frame] then return end

    -- Restore parent first if it was reparented
    RestoreParent(frame)

    pcall(function()
        -- Call Blizzard's function to restore all events
        if CompactUnitFrame_UpdateUnitEvents then
            CompactUnitFrame_UpdateUnitEvents(frame)
        end
    end)
    strippedFrames[frame] = nil
end

-- Install hooks once to intercept Blizzard's event registration
local function InstallBlizzardHooks()
    if blizzardHooksInstalled then return end
    
    -- Hook CompactUnitFrame_UpdateUnitEvents to strip events but keep UNIT_AURA
    if CompactUnitFrame_UpdateUnitEvents then
        hooksecurefunc("CompactUnitFrame_UpdateUnitEvents", function(frame)
            -- Only strip events if we're hiding Blizzard frames
            local raidDb = DF:GetRaidDB()
            local partyDb = DF:GetDB()
            local shouldStrip = false
            
            if frame.unit then
                if frame.unit:match("^raid") and raidDb.hideBlizzardRaidFrames then
                    shouldStrip = true
                elseif frame.unit:match("^party") and partyDb.hideBlizzardPartyFrames then
                    shouldStrip = true
                elseif frame.unit == "player" and partyDb.hideBlizzardPartyFrames then
                    shouldStrip = true
                end
            end
            
            if shouldStrip then
                -- In Direct mode, fully disable (no events at all)
                local isDirectMode = false
                if frame.unit then
                    if frame.unit:match("^raid") then
                        isDirectMode = true
                    else
                        isDirectMode = true
                    end
                end
                StripUnitFrameEvents(frame, isDirectMode)
            end
        end)
    end

    -- Hook side menu frames to forcibly re-hide when Blizzard re-shows them
    -- SetAlpha(0) alone is insufficient — Blizzard code resets alpha on various events
    local function ShouldHideSideMenu()
        -- Always hide side menu when solo — it's a party/raid UI element
        if not IsInGroup() and not IsInRaid() then return true end
        local raidDb = DF:GetRaidDB()
        local partyDb = DF:GetDB()
        if not raidDb or not partyDb then return false end
        if IsInRaid() then
            return raidDb.hideBlizzardRaidFrames and not raidDb.showBlizzardSideMenu
        else
            return partyDb.hideBlizzardPartyFrames and not partyDb.showBlizzardSideMenu
        end
    end

    local function ForceHideSideMenuFrame(frame)
        if not frame then return end
        pcall(function()
            if not InCombatLockdown() then
                frame:Hide()
            else
                frame:SetAlpha(0)
            end
        end)
    end

    if CompactRaidFrameManager then
        hooksecurefunc(CompactRaidFrameManager, "Show", function()
            if ShouldHideSideMenu() then
                ForceHideSideMenuFrame(CompactRaidFrameManager)
            end
        end)
        if CompactRaidFrameManager.displayFrame then
            hooksecurefunc(CompactRaidFrameManager.displayFrame, "Show", function()
                if ShouldHideSideMenu() then
                    ForceHideSideMenuFrame(CompactRaidFrameManager.displayFrame)
                end
            end)
        end
    end

    blizzardHooksInstalled = true
end

function DF:UpdateBlizzardFrameVisibility()
    local partyDb = DF:GetDB()
    local raidDb = DF:GetRaidDB()

    -- Separate settings for party and raid frames
    local hidePartyFrames = partyDb.hideBlizzardPartyFrames
    local hideRaidFrames = raidDb.hideBlizzardRaidFrames

    -- Check if Direct mode is active (allows full disable instead of just hiding)
    local partyDirectMode = true -- direct is the only aura source (4.6.1)
    local raidDirectMode = true
    DF.blizzardFramesFullyDisabled = (hidePartyFrames and partyDirectMode) or (hideRaidFrames and raidDirectMode)
    
    -- Side menu visibility - hide when solo, respect setting when grouped
    local showSideMenu
    if not IsInGroup() and not IsInRaid() then
        showSideMenu = false
    elseif IsInRaid() then
        showSideMenu = raidDb.showBlizzardSideMenu
    else
        showSideMenu = partyDb.showBlizzardSideMenu
    end
    
    -- Install hooks if we're hiding frames
    if hidePartyFrames or hideRaidFrames then
        InstallBlizzardHooks()
    end
    
    -- Function to safely apply visibility using SetAlpha only
    local function SafeHideFrame(frame, hide)
        if not frame then return end
        pcall(function()
            if hide then
                frame:SetAlpha(0)
            else
                frame:SetAlpha(1)
            end
        end)
    end
    
    -- Function to safely scale container frames
    local function SafeScaleContainer(frame, hide)
        if not frame then return end
        if InCombatLockdown() then return end
        pcall(function()
            if hide then
                frame:SetAlpha(0)
                frame:SetScale(0.001)
            else
                frame:SetAlpha(1)
                frame:SetScale(1)
            end
        end)
    end
    
    -- Function to safely apply just alpha
    local function SafeSetAlpha(frame, alpha)
        if frame and frame.SetAlpha then
            pcall(function() frame:SetAlpha(alpha) end)
        end
    end
    
    -- Function to hide selection highlights
    local function HideSelectionHighlights(frame)
        if not frame then return end
        pcall(function()
            if frame.selectionHighlight and frame.selectionHighlight.SetShown then
                frame.selectionHighlight:SetShown(false)
            end
            if frame.selectionIndicator and frame.selectionIndicator.SetShown then
                frame.selectionIndicator:SetShown(false)
            end
        end)
    end
    
    -- Hide/show the main container frames (raid-style)
    SafeScaleContainer(CompactRaidFrameContainer, hideRaidFrames)
    
    -- Handle CompactPartyFrame (raid-style party frames)
    if CompactPartyFrame then
        SafeSetAlpha(CompactPartyFrame, hidePartyFrames and 0 or 1)
        SafeSetAlpha(CompactPartyFrame.title, hidePartyFrames and 0 or 1)
        SafeSetAlpha(CompactPartyFrame.borderFrame, hidePartyFrames and 0 or 1)
        if hidePartyFrames then
            HideSelectionHighlights(CompactPartyFrame)
        end
    end
    
    -- Handle traditional portrait-style party frames
    if hidePartyFrames and partyDirectMode then
        -- Direct mode: fully disable (reparent to hidden frame)
        ReparentToHidden(PartyFrame)
    else
        RestoreParent(PartyFrame)
        SafeScaleContainer(PartyFrame, hidePartyFrames)
    end

    -- Handle individual traditional party member frames (PartyMemberFrame1-4)
    for i = 1, 4 do
        local frame = _G["PartyMemberFrame" .. i]
        if frame then
            if hidePartyFrames and partyDirectMode then
                ReparentToHidden(frame)
            else
                RestoreParent(frame)
                SafeHideFrame(frame, hidePartyFrames)
                local petFrame = _G["PartyMemberFrame" .. i .. "PetFrame"]
                SafeSetAlpha(petFrame, hidePartyFrames and 0 or 1)
                local buffFrame = _G["PartyMemberFrame" .. i .. "BuffFrame"]
                SafeSetAlpha(buffFrame, hidePartyFrames and 0 or 1)
                local debuffFrame = _G["PartyMemberFrame" .. i .. "DebuffFrame"]
                SafeSetAlpha(debuffFrame, hidePartyFrames and 0 or 1)
            end
        end
    end

    -- Handle individual compact party member frames
    for i = 1, 5 do
        local frame = _G["CompactPartyFrameMember" .. i]
        if frame then
            if hidePartyFrames then
                SafeHideFrame(frame, true)
                HideSelectionHighlights(frame)
                StripUnitFrameEvents(frame, partyDirectMode)
            else
                -- Restore events when showing
                RestoreUnitFrameEvents(frame)
            end
        end
    end
    
    -- Handle raid frames
    for i = 1, 40 do
        local frame = _G["CompactRaidFrame" .. i]
        if frame then
            SafeHideFrame(frame, hideRaidFrames)
            if hideRaidFrames then
                HideSelectionHighlights(frame)
                StripUnitFrameEvents(frame, raidDirectMode)
            else
                -- Restore events when showing
                RestoreUnitFrameEvents(frame)
            end
        end
    end

    for group = 1, 8 do
        for member = 1, 5 do
            local frame = _G["CompactRaidGroup" .. group .. "Member" .. member]
            if frame then
                SafeHideFrame(frame, hideRaidFrames)
                if hideRaidFrames then
                    HideSelectionHighlights(frame)
                    StripUnitFrameEvents(frame, raidDirectMode)
                else
                    -- Restore events when showing
                    RestoreUnitFrameEvents(frame)
                end
            end
        end
        -- Also hide group headers
        local groupFrame = _G["CompactRaidGroup" .. group]
        SafeHideFrame(groupFrame, hideRaidFrames)
    end
    
    -- Force hide/show a frame using actual Hide()/Show() outside combat,
    -- falling back to SetAlpha inside combat to avoid taint.
    -- The hooks on Show() only re-hide when ShouldHideSideMenu() is true,
    -- so calling Show() here is safe — if we're showing, the setting is on
    -- and the hook will be a no-op.
    local function ForceHideShow(frame, hide)
        if not frame then return end
        pcall(function()
            if InCombatLockdown() then
                frame:SetAlpha(hide and 0 or 1)
            else
                if hide then
                    frame:Hide()
                else
                    frame:SetAlpha(1)
                    frame:Show()
                end
            end
        end)
    end

    -- Handle raid frame manager
    if CompactRaidFrameManager then
        local sideMenuVisible = showSideMenu or not hideRaidFrames

        SafeHideFrame(CompactRaidFrameManager.container, hideRaidFrames)
        SafeHideFrame(CompactRaidFrameManager.toggleButton, hideRaidFrames)

        -- Handle the display frame (side panel with settings/pings) separately
        -- Use actual Hide() to prevent Blizzard from re-showing via alpha resets
        ForceHideShow(CompactRaidFrameManager.displayFrame, not sideMenuVisible)

        -- The main manager frame itself
        ForceHideShow(CompactRaidFrameManager, not sideMenuVisible)
    end

    -- Handle the side menu elements for party frames
    local partySideMenuVisible = showSideMenu or not hidePartyFrames

    if CompactPartyFrame then
        -- Only adjust title if we want to show/hide the side menu differently
        if not partySideMenuVisible then
            SafeSetAlpha(CompactPartyFrame.title, 0)
        else
            SafeSetAlpha(CompactPartyFrame.title, 1)
        end
        ForceHideShow(CompactPartyFrame.dropdown, not partySideMenuVisible)
        ForceHideShow(CompactPartyFrame.menuButton, not partySideMenuVisible)
    end

    if PartyFrame then
        ForceHideShow(PartyFrame.DropdownButton, not partySideMenuVisible)
        SafeSetAlpha(PartyFrame.PartyMemberFrameDropDown, partySideMenuVisible and 1 or 0)
    end

    if EditModeManagerFrame and EditModeManagerFrame.PartyFramesSidePanel then
        ForceHideShow(EditModeManagerFrame.PartyFramesSidePanel, not sideMenuVisible)
    end
end

-- One-shot HARD disable of Blizzard's compact raid/party system (mirrors ElvUI's
-- UF:DisableBlizzard). UpdateBlizzardFrameVisibility above only alpha-hides the
-- frames and strips per-frame events reactively — the CompactRaidFrameManager
-- (Raid Utility) keeps running its roster/layout work and the container keeps its
-- own events. This kills all of that once, at load, out of combat:
--   * UIParent's GROUP_ROSTER_UPDATE (drives UpdateRaidAndPartyFrames)
--   * CompactRaidFrameContainer / CompactPartyFrame event registration
--   * the CompactRaidFrameManager itself (unregister + reparent to a hidden frame
--     + tell Blizzard's own setting it should not show)
-- It is IRREVERSIBLE without a /reload, which is why the toggles now prompt for
-- one. Skipped entirely when the user keeps the Blizzard side menu (Raid Utility),
-- since that IS the manager — that case keeps the lighter alpha-hide behaviour.
-- Runs once (DF.blizzardHardDisabled); combat defers it to the next call (the
-- event handler below fires it again on PLAYER_REGEN_ENABLED).
function DF:HardDisableBlizzardFrames()
    if DF.blizzardHardDisabled then return true end
    if InCombatLockdown() then return false end

    local partyDb = DF.GetDB and DF:GetDB()
    local raidDb  = DF.GetRaidDB and DF:GetRaidDB()
    if not (partyDb and raidDb) then return false end

    local hideParty = partyDb.hideBlizzardPartyFrames
    local hideRaid  = raidDb.hideBlizzardRaidFrames
    -- Nothing to disable, or the user wants the Blizzard side menu (the manager) —
    -- either way, don't hard-disable. Mark done so we stop re-checking.
    if not (hideParty or hideRaid)
        or raidDb.showBlizzardSideMenu or partyDb.showBlizzardSideMenu then
        DF.blizzardHardDisabled = true
        return true
    end

    pcall(function()
        -- Stops Blizzard's UIParent from running UpdateRaidAndPartyFrames. That
        -- handler drives BOTH the party and raid default frames, so only drop it
        -- when both are disabled — otherwise a party-only disable would break the
        -- Blizzard raid frames the user still wants (and vice versa).
        if hideParty and hideRaid then
            UIParent:UnregisterEvent("GROUP_ROSTER_UPDATE")
        end

        if hideRaid then
            if CompactRaidFrameContainer then
                CompactRaidFrameContainer:UnregisterAllEvents()
            end
            if CompactRaidFrameManager then
                CompactRaidFrameManager:UnregisterAllEvents()
                CompactRaidFrameManager:SetParent(blizzardHiddenParent)
            end
            if CompactRaidFrameManager_SetSetting then
                CompactRaidFrameManager_SetSetting("IsShown", "0")
            end
        end

        if hideParty and CompactPartyFrame then
            CompactPartyFrame:UnregisterAllEvents()
        end
    end)

    DF.blizzardHardDisabled = true
    return true
end

-- Apply visibility on load and when group changes
local blizzFrameEventHandler = CreateFrame("Frame")
blizzFrameEventHandler:RegisterEvent("PLAYER_ENTERING_WORLD")
blizzFrameEventHandler:RegisterEvent("GROUP_ROSTER_UPDATE")
blizzFrameEventHandler:RegisterEvent("PLAYER_REGEN_ENABLED")
blizzFrameEventHandler:RegisterEvent("PLAYER_TARGET_CHANGED")
blizzFrameEventHandler:RegisterEvent("RAID_ROSTER_UPDATE")
blizzFrameEventHandler:RegisterEvent("PARTY_MEMBER_ENABLE")
blizzFrameEventHandler:RegisterEvent("PARTY_MEMBER_DISABLE")

-- Coalesce rapid-fire events into a single deferred update to prevent
-- the multiple timer callbacks from fighting each other and causing flicker
local blizzVisibilityPending = false

blizzFrameEventHandler:SetScript("OnEvent", function(self, event)
    -- One-shot hard disable of the Blizzard compact system (self-guarded; a no-op
    -- once done). Deferred by combat, so PLAYER_REGEN_ENABLED retries it here. The
    -- reactive visibility pass below still runs to hide the actual frames.
    if DF.HardDisableBlizzardFrames then DF:HardDisableBlizzardFrames() end

    if event == "GROUP_ROSTER_UPDATE" then
        if DF.RosterDebugEvent then DF:RosterDebugEvent("Auras.lua(visibility):GROUP_ROSTER_UPDATE") end
    end
    -- Debounced update — first event arms the timer, subsequent events within
    -- the window are ignored; the single callback fires once Blizzard has settled
    if not blizzVisibilityPending then
        blizzVisibilityPending = true
        C_Timer.After(0.3, function()
            blizzVisibilityPending = false
            if DF.UpdateBlizzardFrameVisibility then
                DF:UpdateBlizzardFrameVisibility()
            end
        end)
    end
    
    -- For target changes, also do an immediate check to hide selection highlights
    if event == "PLAYER_TARGET_CHANGED" then
        local db = DF.GetDB and DF:GetDB()
        local raidDb = DF.GetRaidDB and DF:GetRaidDB()
        local hideParty = db and db.hideBlizzardPartyFrames
        local hideRaid = raidDb and raidDb.hideBlizzardRaidFrames
        
        if hideParty or hideRaid then
            -- Hide selection highlights on all Blizzard frames
            local function HideSelectionHighlight(frame)
                if frame then
                    if frame.selectionHighlight and frame.selectionHighlight.SetShown then
                        frame.selectionHighlight:SetShown(false)
                    end
                    if frame.selectionIndicator and frame.selectionIndicator.SetShown then
                        frame.selectionIndicator:SetShown(false)
                    end
                end
            end
            
            if hideParty then
                for i = 1, 5 do
                    HideSelectionHighlight(_G["CompactPartyFrameMember" .. i])
                end
            end
            if hideRaid then
                for i = 1, 40 do
                    HideSelectionHighlight(_G["CompactRaidFrame" .. i])
                end
                for group = 1, 8 do
                    for member = 1, 5 do
                        HideSelectionHighlight(_G["CompactRaidGroup" .. group .. "Member" .. member])
                    end
                end
            end
        end
    end
end)

-- Hook Blizzard's selection highlight function to hide it when our option is enabled
if CompactUnitFrame_UpdateSelectionHighlight then
    hooksecurefunc("CompactUnitFrame_UpdateSelectionHighlight", function(frame)
        local db = DF.GetDB and DF:GetDB()
        local raidDb = DF.GetRaidDB and DF:GetRaidDB()
        
        -- Only affect party/raid frames, not nameplates
        local unit = frame.unit or frame.displayedUnit
        if unit then
            local isParty = unit:match("^party") or unit == "player"
            local isRaid = unit:match("^raid")
            
            local shouldHide = false
            if isParty and db and db.hideBlizzardPartyFrames then
                shouldHide = true
            elseif isRaid and raidDb and raidDb.hideBlizzardRaidFrames then
                shouldHide = true
            end
            
            if shouldHide and frame.selectionHighlight and frame.selectionHighlight.SetShown then
                frame.selectionHighlight:SetShown(false)
            end
        end
    end)
end

-- Slash command
DF:RegisterDebugSlash("DFAURAS", "Aura filtering / pipeline state dump", false, "/dfauras")
SlashCmdList["DFAURAS"] = function(msg)
    if msg == "hideparty" then
    elseif msg == "hideparty" then
        local db = DF:GetDB()
        db.hideBlizzardPartyFrames = not db.hideBlizzardPartyFrames
        DF:UpdateBlizzardFrameVisibility()
        print("|cff00ff00DandersFrames:|r Blizzard party frames " .. (db.hideBlizzardPartyFrames and "hidden" or "visible"))
    elseif msg == "hideraid" then
        local raidDb = DF:GetRaidDB()
        raidDb.hideBlizzardRaidFrames = not raidDb.hideBlizzardRaidFrames
        DF:UpdateBlizzardFrameVisibility()
        print("|cff00ff00DandersFrames:|r Blizzard raid frames " .. (raidDb.hideBlizzardRaidFrames and "hidden" or "visible"))
    elseif msg == "hideblizz" or msg == "hide" then
        -- Toggle both for convenience
        local db = DF:GetDB()
        local raidDb = DF:GetRaidDB()
        local newState = not (db.hideBlizzardPartyFrames or raidDb.hideBlizzardRaidFrames)
        db.hideBlizzardPartyFrames = newState
        raidDb.hideBlizzardRaidFrames = newState
        DF:UpdateBlizzardFrameVisibility()
        print("|cff00ff00DandersFrames:|r Blizzard frames " .. (newState and "hidden" or "visible"))
    elseif msg == "sidemenu" then
        -- Debug: list potential side menu frames
        print("|cff00ff00DandersFrames:|r Searching for side menu frames...")
        local framesToCheck = {
            "CompactPartyFrame",
            "CompactPartyFrameTitle",
            "CompactPartyFrameBorderFrame", 
            "PartyFrame",
            "CompactRaidFrameManager",
            "CompactRaidFrameManagerDisplayFrame",
            "CompactRaidFrameManagerContainerResizeFrame",
        }
        for _, name in ipairs(framesToCheck) do
            local frame = _G[name]
            if frame then
                print("  Found: " .. name .. " (shown: " .. tostring(frame:IsShown()) .. ", alpha: " .. tostring(frame:GetAlpha()) .. ")")
                -- List children
                if frame.GetChildren then
                    for i, child in ipairs({frame:GetChildren()}) do
                        local childName = child:GetName() or ("unnamed_" .. i)
                        if child:IsShown() then
                            print("    Child: " .. childName .. " (alpha: " .. tostring(child:GetAlpha()) .. ")")
                        end
                    end
                end
            end
        end
        -- Also check for any visible frame with "party" in name at UIParent level
        print("  Checking UIParent children for party-related frames...")
        for i, child in ipairs({UIParent:GetChildren()}) do
            local name = child:GetName()
            if name and (name:lower():find("party") or name:lower():find("compact")) and child:IsShown() then
                print("    UIParent child: " .. name .. " (alpha: " .. tostring(child:GetAlpha()) .. ")")
            end
        end
    else
        print("|cff00ff00DandersFrames:|r /dfauras hideparty | hideraid | hide | check")
    end
end

