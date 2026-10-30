-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). See the same note at the head of GUI/Panel.lua.
local DF = DandersFrames

local type, ipairs, pcall = type, ipairs, pcall

-- ============================================================
-- IMPORT ROUTER
-- Profiles > Import / Export has ONE paste box for every string the addon
-- exports. This file says what a pasted string IS and checks it decodes; the
-- page (GUI/Pages/Profiles.lua) shows the answer and hands the string to the
-- import flow that owns that kind:
--   profile    -> DF:ValidateImportString / GetImportInfo / ApplyImportedProfile
--   clickcast  -> CC:ImportProfile (with its binding picker)
--   filter     -> DF.ImportFilterString (the Filter Designer's own flow)
--   wizard     -> refused: the setup wizard is gone
-- Pure apart from the decoders it calls, so it is asserted headlessly
-- (Tools/mover-tests/test_import_router.lua).
-- ============================================================

local Router = {}
DF.ImportRouter = Router

-- Longest first is not needed (no prefix is a prefix of another), but the
-- order is the reading order: current formats, then the legacy ones.
Router.PREFIXES = {
    { prefix = "!DFP1!", kind = "profile" },
    { prefix = "!DFC1!", kind = "clickcast" },
    { prefix = "!DFF1!", kind = "filter" },
    { prefix = "!DFW1!", kind = "wizard" },
    -- Legacy profile strings. !DF1! still imports; !DF2!, !DF3! and DF02: are
    -- refused by the profile validator with its own "please re-export" reason.
    { prefix = "!DF1!",  kind = "profile" },
    { prefix = "!DF2!",  kind = "profile" },
    { prefix = "!DF3!",  kind = "profile" },
    { prefix = "DF02:",  kind = "profile" },
    -- Legacy click-cast strings.
    { prefix = "DF01:",  kind = "clickcast" },
}

-- Whitespace and line breaks AROUND the string go (a chat client or a forum
-- post adds them); anything inside is the string's own business.
function Router.Trim(str)
    if type(str) ~= "string" then return "" end
    return (str:match("^%s*(.-)%s*$")) or ""
end

-- kind, trimmed string. kind is a PREFIXES kind, "empty", or "unknown".
function Router.Detect(str)
    local s = Router.Trim(str)
    if s == "" then return "empty", s end
    for _, p in ipairs(Router.PREFIXES) do
        if s:sub(1, #p.prefix) == p.prefix then return p.kind, s end
    end
    return "unknown", s
end

-- ============================================================
-- PARSE -- what the paste box shows before anything is imported.
-- Returns a table:
--   kind      as Detect, except an unprefixed string the profile validator
--             still accepts (its oldest legacy branch) is "profile"
--   str       the trimmed string, which is what every import is handed
--   ok        true when the string decoded
--   err       a reason when it did not (shown as is -- the profile validator's
--             reasons are its own)
--   data      profile: the validated payload; filter: the decoded def;
--             clickcast: the decoded export table
--   name      the name it carries, when it carries one
-- ============================================================

local function ParseProfile(out)
    if not DF.ValidateImportString then
        out.err = "unavailable"
        return out
    end
    local data, err = DF:ValidateImportString(out.str)
    if not data then
        out.err = err or "invalid"
        return out
    end
    out.ok, out.data = true, data
    local info = DF.GetImportInfo and DF:GetImportInfo(data)
    out.info = info
    out.name = info and info.profileName or nil
    return out
end

local function ParseClickCast(out)
    local CC = DF.ClickCast
    if not CC then
        out.err = "unavailable"
        return out
    end
    local s, data = out.str, nil
    if s:sub(1, 6) == "!DFC1!" and CC.DeserializeString then
        local ok, res = pcall(CC.DeserializeString, CC, s:sub(7))
        data = ok and res or nil
    elseif s:sub(1, 5) == "DF01:" and CC.DeserializeStringLegacy then
        local ok, res = pcall(CC.DeserializeStringLegacy, CC, s:sub(6))
        data = ok and res or nil
    end
    -- The same shape test CC:ImportProfile applies before it touches anything.
    if type(data) ~= "table" or type(data.profile) ~= "table" then
        out.err = "corrupt"
        return out
    end
    out.ok, out.data = true, data
    out.name = type(data.profileName) == "string" and data.profileName or nil
    return out
end

local function ParseFilter(out)
    local R = DF.FilterRegistry
    if not (R and R.DecodeFilterString) then
        out.err = "unavailable"
        return out
    end
    local def, err = R:DecodeFilterString(out.str)
    if not def then
        out.err = err or "corrupt"
        return out
    end
    out.ok, out.data, out.name = true, def, def.name
    return out
end

function Router.Parse(str)
    local kind, s = Router.Detect(str)
    local out = { kind = kind, str = s, ok = false }
    if kind == "profile" then return ParseProfile(out) end
    if kind == "clickcast" then return ParseClickCast(out) end
    if kind == "filter" then return ParseFilter(out) end
    if kind == "wizard" then
        out.err = "wizard"
        return out
    end
    if kind == "unknown" then
        -- ⚠ THE PROFILE VALIDATOR'S OLDEST BRANCH TAKES AN UNPREFIXED STRING
        -- (sandboxed base64; see DF:ValidateImportString). The old Import box sent
        -- everything there, so this one still asks it before calling a string junk.
        if DF.ValidateImportString then
            local data = DF:ValidateImportString(s)
            if data then
                out.kind = "profile"
                out.ok, out.data = true, data
                local info = DF.GetImportInfo and DF:GetImportInfo(data)
                out.info = info
                out.name = info and info.profileName or nil
                return out
            end
        end
        out.err = "unknown"
        return out
    end
    out.err = "empty"
    return out
end
