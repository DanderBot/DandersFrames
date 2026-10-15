local NS = ...
local R = NS.Registry

-- ============================================================
-- UNLOCK FILTER: normalisation + the IsInSession / WantsProxy precedence matrix
-- (IsEnabled > key filter > isRelevant; other addons in on their own terms, proxied
-- only with showOtherAddons). Pure Registry; no Session needed.
-- ============================================================
local wasReady = R.ready
R.ready = true
NS.db = { addons = {} }

local function elDef(relevant)
    return { title = "x", frame = FakeFrame(0, 0, 10, 10),
             getPos = function() return { point = "CENTER", x = 0, y = 0 } end, onChanged = function() end,
             isRelevant = function() return relevant end }
end
R:RegisterAddon("F", { title = "F" })
R:RegisterAddon("O", { title = "Other" })
local yes = R:Register("F", "yes", elDef(true))
local no  = R:Register("F", "no",  elDef(false))
local oth = R:Register("O", "yes", elDef(true))
local othNo = R:Register("O", "no", elDef(false))

-- normalisation
do
    check(R:NormalizeFilter(nil) == nil, "nil stays nil")
    local s = R:NormalizeFilter("F")
    check(s.addon == "F" and s.keySet == nil, "string -> { addon }")
    local t = R:NormalizeFilter({ addon = "F", keys = { "a", "b" } })
    check(t.addon == "F" and t.keySet.a and t.keySet.b and not t.keySet.c, "table -> { addon, keySet }")
    local u = R:NormalizeFilter({ addon = "F" })
    check(u.addon == "F" and u.keySet == nil, "table without keys -> no keySet")
    check(not pcall(R.NormalizeFilter, R, { keys = { "a" } }), "keys without addon is an error")
    check(not pcall(R.NormalizeFilter, R, 42), "non-table non-string is an error")
    check(not pcall(R.NormalizeFilter, R, { addon = "F", keys = "a" }), "keys must be a table")
end

-- precedence matrix for the INITIATOR: enabled x in-keys x relevant
do
    local keyed = R:NormalizeFilter({ addon = "F", keys = { "yes", "no" } })
    local unlisted = R:NormalizeFilter({ addon = "F", keys = { "zzz" } })
    check(R:IsInSession(keyed, yes) and R:WantsProxy(keyed, yes), "E+K+R in")
    check(R:IsInSession(keyed, no) and R:WantsProxy(keyed, no), "E+K+!R in (key filter beats isRelevant)")
    check(not R:IsInSession(unlisted, yes), "E+!K+R out")
    check(not R:IsInSession(unlisted, no), "E+!K+!R out")
    R:SetEnabled("F", "yes", false); R:SetEnabled("F", "no", false)
    check(not R:IsInSession(keyed, yes), "!E+K+R out")
    check(not R:IsInSession(keyed, no), "!E+K+!R out")
    check(not R:IsInSession(unlisted, yes), "!E+!K+R out")
    check(not R:IsInSession(unlisted, no), "!E+!K+!R out")
    R:SetEnabled("F", "yes", true); R:SetEnabled("F", "no", true)
    -- no key filter: isRelevant decides
    check(R:IsInSession(nil, yes) and R:WantsProxy(nil, yes), "no filter: relevant in + proxied")
    check(not R:IsInSession(nil, no), "no filter: irrelevant out")
    local addonOnly = R:NormalizeFilter("F")
    check(R:IsInSession(addonOnly, yes) and R:WantsProxy(addonOnly, yes), "addon filter: relevant in + proxied")
    check(not R:IsInSession(addonOnly, no), "addon filter: irrelevant out")
    -- unknown key is simply ignored
    local unknown = R:NormalizeFilter({ addon = "F", keys = { "nope", "yes" } })
    check(R:IsInSession(unknown, yes) and not R:IsInSession(unknown, no), "unknown key ignored")
end

-- OTHER addons in a filtered session: in on their own terms, proxied only on request
do
    local keyed = R:NormalizeFilter({ addon = "F", keys = { "yes" } })
    local addonOnly = R:NormalizeFilter("F")
    check(R:IsInSession(keyed, oth), "other addon's relevant element is in (anchor target)")
    check(not R:IsInSession(keyed, othNo), "other addon's irrelevant element is out")
    check(R:IsInSession(addonOnly, oth), "same with a string filter")
    check(not R:WantsProxy(keyed, oth), "no proxy by default (showOtherAddons off)")
    NS.db.showOtherAddons = true
    check(R:WantsProxy(keyed, oth), "proxy when showOtherAddons is on")
    check(not R:WantsProxy(keyed, othNo), "still no proxy for an irrelevant one")
    NS.db.showOtherAddons = false
    R:SetEnabled("O", "yes", false)
    check(not R:IsInSession(keyed, oth), "other addon's toggle still wins")
    R:SetEnabled("O", "yes", true)
    check(R:IsInSession(nil, oth) and R:WantsProxy(nil, oth), "unfiltered: other addon proxied as always")
end

R:UnregisterAddon("F"); R:UnregisterAddon("O")
R.ready = wasReady
NS.db = nil
