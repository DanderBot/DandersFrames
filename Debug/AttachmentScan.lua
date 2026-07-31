local addonName, DF = ...

-- ============================================================
-- ATTACHMENT SCAN (diagnostic)
-- Lists frames from OTHER addons that are anchored to, or parented
-- onto, DandersFrames unit frames. Helps users tell DF's own
-- features apart from castbars / cooldowns / auras that another
-- addon has attached to our frames.
--
-- Read-only and run on demand via `/df debug attached`. WoW has no
-- "frame -> owning addon" API, so addon attribution is a best-effort
-- name heuristic; unknown frames are reported with their type and
-- attach method so the user can investigate.
--
-- Reliable case: a frame anchored (SetPoint) to a DF frame whose own
-- parent chain is NOT inside DF -> definitely foreign.
-- Limitation: a foreign frame RE-PARENTED onto a DF frame is
-- indistinguishable from a DF-created child without ownership tagging,
-- so we only flag re-parented frames that carry a non-DF name.
-- ============================================================

local pairs, ipairs = pairs, ipairs
local format = string.format
local tinsert, tsort = table.insert, table.sort
local pcall = pcall
local EnumerateFrames = EnumerateFrames
local issecretvalue = issecretvalue or function() return false end

-- Known addons keyed by a lowercase substring found in their frame names.
-- Best-effort only — extend as we see new culprits in bug reports.
local KNOWN_ADDONS = {
    { pat = "quartz",     name = "Quartz" },
    { pat = "weakauras",  name = "WeakAuras" },
    { pat = "plater",     name = "Plater" },
    { pat = "omnicc",     name = "OmniCC" },
    { pat = "minicc",     name = "MiniCC" },
    { pat = "details",    name = "Details!" },
    { pat = "bigwigs",    name = "BigWigs" },
    { pat = "littlewigs", name = "LittleWigs" },
    { pat = "cell",       name = "Cell" },
    { pat = "elvuf",      name = "ElvUI" },
    { pat = "elvui",      name = "ElvUI" },
    { pat = "grid2",      name = "Grid2" },
    { pat = "vuhdo",      name = "VuhDo" },
    { pat = "clique",     name = "Clique" },
    { pat = "gladius",    name = "Gladius" },
    { pat = "sarena",     name = "sArena" },
    { pat = "tellmewhen", name = "TellMeWhen" },
    { pat = "nugrunning", name = "NugRunning" },
    { pat = "hekili",     name = "Hekili" },
    { pat = "exrt",       name = "MethodRaidTools/exRT" },
    { pat = "w-method",   name = "MethodRaidTools" },
}

-- Derive a probable addon name from a frame name's leading token, e.g.
-- "MiniCC_Container_57" -> "MiniCC", "QuartzCastBarplayer" -> "Quartz".
-- Returns nil for names too short/generic to be meaningful.
local function DerivePrefix(name)
    -- Leading alphabetic run, stopping at first underscore or digit.
    local prefix = name:match("^(%a+)")
    if not prefix or #prefix < 3 then return nil end
    -- Generic container / root words aren't addon names on their own.
    -- (GetDebugName of an anonymous frame yields its parent path, often
    -- "UIParent…", which would otherwise produce a misleading guess.)
    local lower = prefix:lower()
    if lower == "frame" or lower == "button" or lower == "container"
       or lower == "ui" or lower == "status" or lower == "uiparent"
       or lower == "worldframe" then
        return nil
    end
    return prefix
end

-- Addons we never attribute to: ourselves (we touch some foreign-adjacent
-- frames) and Blizzard's UI namespace (taint of "Blizzard_*" isn't a useful
-- third-party answer here).
local IGNORE_ADDON = { DandersFrames = true }

-- Taint owner of a global variable, or nil. A frame created with a global name
-- has that global written from its creating addon's code, tainting it.
local function GlobalTaint(name)
    if not name or name == "" then return nil end
    local ok, isSecure, addon = pcall(issecurevariable, name)
    if ok and not isSecure and addon and addon ~= "" and not IGNORE_ADDON[addon] then
        return addon
    end
    return nil
end

-- First non-ignored addon taint among a frame's Lua-set fields, or nil.
-- issecurevariable(frame, key) reports which addon last wrote that field, so an
-- addon that stashes config/state on its (even anonymous) frame is identifiable.
local function FieldTaint(frame)
    local n = 0
    for k in pairs(frame) do
        if type(k) == "string" then
            local ok, isSecure, addon = pcall(issecurevariable, frame, k)
            if ok and not isSecure and addon and addon ~= "" and not IGNORE_ADDON[addon] then
                return addon
            end
        end
        n = n + 1
        if n >= 80 then break end   -- bound the scan
    end
    return nil
end

-- Best-effort source addon for a frame.
-- Returns: displayName, confident. displayName is nil only when nothing resolved.
local function GuessAddon(frame)
    local name = frame:GetName()

    -- 1. The frame's own global-name taint. Most reliable; real folder name.
    if name and name ~= "" and _G[name] == frame then
        local a = GlobalTaint(name)
        if a then return a, true end
    end

    -- 2. The frame's own field taint (addon stashed state on the anchor frame).
    local a = FieldTaint(frame)
    if a then return a, true end

    -- 3. Walk a few parent levels and check each ancestor's global-name and
    --    field taint. Catches anonymous frames whose owning addon set fields on
    --    a (possibly also anonymous) parent container — e.g. Northern Sky's
    --    private-aura frames are parented to its NSRTFrame.
    local p, guard = frame:GetParent(), 0
    while p and guard < 5 do
        if p == UIParent or p == WorldFrame or p:IsForbidden() then break end
        local pn = p:GetName()
        local pa = (pn and _G[pn] == p and GlobalTaint(pn)) or FieldTaint(p)
        if pa then return pa, true end
        p = p:GetParent()
        guard = guard + 1
    end

    -- 4. Name / debug-name heuristics: curated list, then leading-token guess.
    local names = {}
    if name and name ~= "" then names[#names + 1] = name end
    if frame.GetDebugName then
        local ok, dn = pcall(frame.GetDebugName, frame)
        if ok and dn and dn ~= "" then names[#names + 1] = dn end
    end
    for _, s in ipairs(names) do
        local low = s:lower()
        for _, entry in ipairs(KNOWN_ADDONS) do
            if low:find(entry.pat, 1, true) then
                return entry.name, true
            end
        end
    end
    for _, s in ipairs(names) do
        local prefix = DerivePrefix(s)
        if prefix then return prefix, false end
    end
    return nil, false
end

-- True for a WoW widget (frame/region), false for plain Lua tables.
local function IsWidget(v)
    return type(v) == "table" and type(v.GetObjectType) == "function"
        and type(v.GetParent) == "function"
end

-- Build the set of DF frames: headers, unit buttons, the documented
-- sub-elements other addons commonly anchor to, AND every widget DF stores
-- as a field on a unit button. The last part matters because DF parents some
-- of its own overlays (highlight borders, Aura Designer borders) to UIParent
-- to avoid clipping — those aren't reachable by an ancestor walk, but they ARE
-- referenced from the button (frame.dfSelectionHighlight, frame.dfAD_border…).
-- Returns set = { [frame] = "label" }.
local function BuildDFFrameSet()
    local set = {}

    local SUBS = {
        healthBar = ".healthBar", powerBar = ".powerBar", castBar = ".castBar",
        contentOverlay = ".contentOverlay", border = ".border",
        background = ".background", nameText = ".nameText", healthText = ".healthText",
    }

    -- Collect widgets DF stashed on the button: direct fields (frame.dfFoo) and
    -- one level into table fields (frame.dfAD_customBorders = { ... }).
    local function collectOwned(frame, label)
        for k, v in pairs(frame) do
            if IsWidget(v) then
                if not set[v] then set[v] = label .. "#" .. tostring(k) end
            elseif type(v) == "table" then
                for _, vv in pairs(v) do
                    if IsWidget(vv) and not set[vv] then
                        set[vv] = label .. "#" .. tostring(k)
                    end
                end
            end
        end
    end

    local function addUnit(frame, label)
        if not frame then return end
        set[frame] = label
        for key, suffix in pairs(SUBS) do
            local sub = frame[key]
            if sub then set[sub] = label .. suffix end
        end
        collectOwned(frame, label)
    end

    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(function(f, _, unit) addUnit(f, unit) end)
    end
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(function(f, _, unit) addUnit(f, unit) end)
    end
    if DF.IterateArenaFrames then
        DF:IterateArenaFrames(function(f, _, unit) addUnit(f, "arena:" .. unit) end)
    end

    -- Headers / containers so the ancestor walk still recognises DF
    -- descendants whose unit button wasn't iterated (e.g. hidden frames).
    local roots = { DF.partyHeader, DF.partyContainer, DF.arenaHeader }
    if DF.raidSeparatedHeaders then
        for _, h in pairs(DF.raidSeparatedHeaders) do roots[#roots + 1] = h end
    end
    if DF.FlatRaidFrames and DF.FlatRaidFrames.header then
        roots[#roots + 1] = DF.FlatRaidFrames.header
    end
    for _, h in ipairs(roots) do
        if h and not set[h] then set[h] = (h.GetName and h:GetName()) or "DFHeader" end
    end

    return set
end

-- Walk the parent chain; true if any ancestor (or the frame itself) is a DF frame.
local function IsInDFTree(frame, dfSet)
    local f, guard = frame, 0
    while f and guard < 80 do
        if dfSet[f] then return true end
        f = f:GetParent()
        guard = guard + 1
    end
    return false
end

function DF:ScanFrameAttachments()
    local dfSet = BuildDFFrameSet()

    local results = {}   -- [label] = { { otype, name, addon, kind }, ... }
    local total = 0

    local function record(label, foreign, kind)
        local addon, curated = GuessAddon(foreign)
        results[label] = results[label] or {}
        tinsert(results[label], {
            otype   = foreign:GetObjectType() or "?",
            name    = foreign:GetName(),
            addon   = addon,
            curated = curated,
            kind    = kind,
        })
        total = total + 1
    end

    local scanned = 0
    local f = EnumerateFrames()
    while f do
        scanned = scanned + 1
        if not f:IsForbidden() and not IsInDFTree(f, dfSet) then
            local parent = f:GetParent()
            if parent and dfSet[parent] then
                -- Re-parented onto a DF frame. Only report if it carries a
                -- non-DF name (anonymous re-parents can't be told apart from
                -- DF's own anonymous children, so we skip those).
                local nm = f:GetName()
                if nm and not nm:find("Danders", 1, true) then
                    record(dfSet[parent], f, "parented")
                end
            else
                -- Anchored (SetPoint) to a DF frame without re-parenting.
                -- In combat, GetNumPoints/GetPoint return secret values for
                -- protected frames — a secret can't be a for-loop limit. Skip
                -- those (foreign castbar/cooldown frames aren't protected, so
                -- they're still scanned); guard relTo the same way.
                local np = f:GetNumPoints()
                if type(np) == "number" and not issecretvalue(np) then
                    for i = 1, np do
                        local ok, _, relTo = pcall(f.GetPoint, f, i)
                        if ok and relTo and not issecretvalue(relTo) and dfSet[relTo] then
                            record(dfSet[relTo], f, "anchored")
                            break
                        end
                    end
                end
            end
        end
        f = EnumerateFrames(f)
    end

    local o = DF:Out("Attachment Scan", format("%d frames scanned", scanned))
    if total == 0 then
        -- Nothing attached is the DESIRABLE result here, so it reads GOOD.
        o:Line("No other addons appear to be attached to DandersFrames unit frames.", "GOOD")
        o:Line("A foreign frame re-parented onto ours with no name cannot be detected.", "NEUTRAL")
        return
    end

    local labels = {}
    for label in pairs(results) do labels[#labels + 1] = label end
    tsort(labels)

    for _, label in ipairs(labels) do
        o:Section(label, #results[label])
        for _, e in ipairs(results[label]) do
            local who
            if e.addon and e.curated then
                who = e.addon                       -- confident, from curated list
            elseif e.addon then
                who = e.addon .. "?"                -- guessed from frame name
            else
                who = "unknown addon"
            end
            local nm = e.name or "<anonymous>"
            o:Item(who, format("%s [%s, %s]", nm, e.otype, e.kind))
        end
    end
    -- A foreign attachment is a FINDING, not a fault: usually a deliberate setup
    -- by another addon. WARN so it stands out without accusing anyone.
    o:Line(format("%d attachment(s) found across %d frame(s).", total, #labels), "WARN")
end
