local NS = ...

-- ============================================================
-- THE IMPORT ROUTER
-- DandersFrames_Options/Features/ImportRouter.lua
-- ------------------------------------------------------------
-- Profiles > Import / Export has one paste box for every string the addon
-- exports. The real file is loaded over a stub DF whose decoders record what
-- they were handed, so what is checked is the ROUTING: which flow each prefix
-- reaches, with what, and what junk and the retired wizard strings get.
-- ============================================================

local savedDF = DandersFrames

local seen
local DF = {}
function DF:ValidateImportString(str)
    seen[#seen + 1] = "profile:" .. str
    if str == "!DFP1!good" or str == "!DF1!good" then return { version = "v5" }, nil end
    if str:sub(1, 5) == "!DF2!" or str:sub(1, 5) == "!DF3!" or str:sub(1, 5) == "DF02:" then
        return nil, "Legacy format - please re-export"
    end
    if str == "bGVnYWN5" then return { version = "old" }, nil end   -- the unprefixed base64 branch
    return nil, "Invalid format"
end
function DF:GetImportInfo(data)
    return { version = data.version, profileName = "Shared", hasParty = true, hasRaid = false,
             detectedCategories = { "bars" } }
end
DF.ClickCast = {
    DeserializeString = function(_, payload)
        seen[#seen + 1] = "cc:" .. payload
        if payload == "good" then return { profile = { bindings = {} }, profileName = "Healer" } end
        if payload == "notable" then return { profile = 5 } end
        return nil
    end,
    DeserializeStringLegacy = function(_, payload)
        seen[#seen + 1] = "cclegacy:" .. payload
        if payload == "good" then return { profile = {}, profileName = "Old" } end
        return nil
    end,
}
DF.FilterRegistry = {
    DecodeFilterString = function(_, str)
        seen[#seen + 1] = "filter:" .. str
        if str == "!DFF1!good" then return { name = "Big Heals", spells = {}, rawIDs = {} } end
        if str == "!DFF1!newer" then return nil, "newer" end
        return nil, "corrupt"
    end,
}
DandersFrames = DF

seen = {}
load_options_file_into("Features/ImportRouter.lua", NS)
local R = DF.ImportRouter
check(R and R.Detect and R.Parse and R.Trim, "api: the router is on DF.ImportRouter")

-- ---- detect: every prefix --------------------------------------------
print("-- Import router: every prefix")
for _, case in ipairs({
    { "!DFP1!abc", "profile" }, { "!DF1!abc", "profile" }, { "!DF2!abc", "profile" },
    { "!DF3!abc", "profile" }, { "DF02:abc", "profile" },
    { "!DFC1!abc", "clickcast" }, { "DF01:abc", "clickcast" },
    { "!DFF1!abc", "filter" }, { "!DFW1!abc", "wizard" },
    { "hello there", "unknown" }, { "", "empty" }, { "   \n\t ", "empty" },
}) do
    local kind = R.Detect(case[1])
    eq(kind, case[2], "detect: " .. (case[1] == "" and "(empty)" or case[1]:gsub("%s", "_")) .. " is " .. case[2])
end
eq(R.Detect(nil), "empty", "detect: nil is empty, not an error")
eq(R.Detect(42), "empty", "detect: ...and so is a non-string")

-- ---- whitespace around the string ---------------------------------------
print("-- Import router: whitespace and line breaks around the string")
local kind, s = R.Detect("  \r\n\t!DFC1!good \n\n")
eq(kind, "clickcast", "trim: leading spaces and line breaks do not hide the prefix")
eq(s, "!DFC1!good", "trim: ...and the string handed on is the trimmed one")
eq(R.Trim("\n!DFP1!a b\n"), "!DFP1!a b", "trim: only the ends go; the inside is the string's own")

-- ---- parse: profile ------------------------------------------------------
print("-- Import router: profile strings reach the profile validator")
seen = {}
local p = R.Parse("\n  !DFP1!good  \n")
check(p.ok and p.kind == "profile", "profile: a current string parses as a profile")
eq(seen[1], "profile:!DFP1!good", "profile: ...handed to ValidateImportString trimmed")
eq(p.name, "Shared", "profile: ...with the name it carries")
check(p.info and p.info.hasParty and not p.info.hasRaid, "profile: ...and the import info for the options")
check(R.Parse("!DF1!good").ok, "profile: the legacy !DF1! still imports")
for _, legacy in ipairs({ "!DF2!x", "!DF3!x", "DF02:x" }) do
    local r = R.Parse(legacy)
    check(not r.ok and r.kind == "profile" and r.err == "Legacy format - please re-export",
          "profile: " .. legacy .. " gets the validator's own re-export reason")
end
local bad = R.Parse("!DFP1!broken")
check(not bad.ok and bad.err == "Invalid format", "profile: a broken one reports why")

-- ---- parse: click casting -----------------------------------------------
print("-- Import router: click-cast strings reach the click-cast decoder")
seen = {}
local c = R.Parse(" !DFC1!good ")
check(c.ok and c.kind == "clickcast", "clickcast: !DFC1! parses as click casting")
eq(seen[1], "cc:good", "clickcast: ...decoded from the payload after the prefix")
eq(#seen, 1, "clickcast: ...and never offered to the profile validator")
eq(c.name, "Healer", "clickcast: the profile name it carries")
eq(c.str, "!DFC1!good", "clickcast: the import is handed the whole trimmed string")
local legacy = R.Parse("DF01:good")
check(legacy.ok and legacy.name == "Old", "clickcast: the legacy DF01: decodes through the legacy decoder")
check(not R.Parse("!DFC1!notable").ok, "clickcast: a payload whose profile is not a table is refused")
check(not R.Parse("!DFC1!junk").ok and R.Parse("!DFC1!junk").err == "corrupt",
      "clickcast: an undecodable one is corrupt")
local savedCC = DF.ClickCast
DF.ClickCast = nil
local none = R.Parse("!DFC1!good")
check(not none.ok and none.err == "unavailable", "clickcast: no click-cast module is said, not thrown")
DF.ClickCast = { DeserializeString = function() error("boom") end }
check(not R.Parse("!DFC1!good").ok, "clickcast: a decoder that throws is caught")
DF.ClickCast = savedCC

-- ---- parse: filters -------------------------------------------------------
print("-- Import router: filter strings reach the filter decoder")
seen = {}
local f = R.Parse("!DFF1!good\n")
check(f.ok and f.kind == "filter" and f.name == "Big Heals", "filter: !DFF1! decodes, with its name")
eq(seen[1], "filter:!DFF1!good", "filter: ...trimmed")
local newer = R.Parse("!DFF1!newer")
check(not newer.ok and newer.err == "newer", "filter: the decoder's own reason comes back (a newer version)")
local savedR = DF.FilterRegistry
DF.FilterRegistry = nil
check(R.Parse("!DFF1!good").err == "unavailable", "filter: no registry is said, not thrown")
DF.FilterRegistry = savedR

-- ---- wizard, junk, empty ------------------------------------------------------
print("-- Import router: wizard strings, junk and nothing")
seen = {}
local w = R.Parse("!DFW1!whatever")
check(not w.ok and w.kind == "wizard" and w.err == "wizard", "wizard: refused, as a wizard string")
eq(#seen, 0, "wizard: ...without reaching any decoder")
local junk = R.Parse("this is not a string we made")
check(not junk.ok and junk.kind == "unknown" and junk.err == "unknown", "junk: refused as unknown")
eq(seen[1], "profile:this is not a string we made",
   "junk: ...after the profile validator's unprefixed legacy branch was asked")
local old = R.Parse("bGVnYWN5")
check(old.ok and old.kind == "profile", "junk: an unprefixed string the validator still takes is a profile")
local empty = R.Parse(" \n ")
check(not empty.ok and empty.err == "empty", "empty: nothing pasted is its own error")

-- ---- the page routes through it ------------------------------------------------
print("-- Import router: the Import / Export page is its one caller")
local PAGE = options_file_source("GUI/Pages/Profiles.lua"):gsub("\r\n", "\n")
check(PAGE:find("DF.ImportRouter.Parse(self.importEditBox:GetText())", 1, true) ~= nil,
      "page: Parse String asks the router")
check(PAGE:find("pcall(CC.ImportProfile, CC, parsed.str)", 1, true) ~= nil,
      "page: a click-cast string goes to CC:ImportProfile (its binding picker included)")
check(PAGE:find("DF.ImportFilterString(parsed.str)", 1, true) ~= nil,
      "page: a filter string goes to the Filter Designer's own flow")
check(PAGE:find("pcall(DF.ApplyImportedProfile, DF, importData,", 1, true) ~= nil,
      "page: a profile string keeps the profile import")
check(PAGE:find("if not parsed or parsed.str ~= now then", 1, true) ~= nil,
      "page: Import re-checks the box was not edited after Parse")
local FILTERUI = options_file_source("FilterRegistry/UI/Options.lua"):gsub("\r\n", "\n")
check(FILTERUI:find("onAccept    = function(text) DF.ImportFilterString(text) end,", 1, true) ~= nil,
      "page: the Filter Designer's own Import Filter runs the same flow")
local TOC = options_file_source("DandersFrames_Options.toc"):gsub("\r\n", "\n")
local routerAt = TOC:find("Features\\ImportRouter.lua", 1, true)
local pagesAt = TOC:find("GUI\\Pages\\Profiles.lua", 1, true)
check(routerAt ~= nil and pagesAt ~= nil, "toc: both new files are listed")

DandersFrames = savedDF
