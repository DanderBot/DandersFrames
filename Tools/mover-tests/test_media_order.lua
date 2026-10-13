local NS = ...

-- ============================================================
-- MEDIA MENU ORDER -- GUI/Controls.lua
-- The texture, font and sound menus: DandersFrames' media first, then
-- SharedMedia_MyMedia's, then everything else, each group A-Z, grouped by the
-- registered FILE PATH. The helpers are lifted out of the file by their banner.
-- ============================================================

local SRC = options_file_source("GUI/Controls.lua"):gsub("\r\n", "\n")
local a = SRC:find("\nlocal MEDIA_GROUPS = {", 1, true)
local b = SRC:find("\nlocal function MarkMediaGroup", 1, true)
check(a ~= nil and b ~= nil and a < b, "lift: the media order helpers are where expected")
local f, err = loadstring(SRC:sub(a, b) .. "\nreturn SortMedia\n", "=media order")
check(f ~= nil, "lift: they parse (" .. tostring(err) .. ")")
local SortMedia = f and f()

if SortMedia then
    local function opts(t)
        local list = {}
        for name, path in pairs(t) do list[#list + 1] = { key = path, value = name } end
        return list
    end
    local list = opts({
        ["Aluminium"]        = "Interface\\AddOns\\SharedMedia\\statusbar\\Aluminium",
        ["Bars"]             = "Interface\\AddOns\\SomeUI\\media\\Bars.tga",
        ["DF Minimalist"]    = "Interface\\AddOns\\DandersFrames\\Media\\Textures\\Minimalist.tga",
        ["DF Stripes Soft"]  = "Interface\\AddOns\\DandersFrames\\Media\\Textures\\StripesSoft.tga",
        ["My Glossy"]        = "Interface\\Addons\\SharedMedia_MyMedia\\statusbar\\Glossy.tga",
        ["Another Mine"]     = "Interface/AddOns/SharedMedia_MyMedia/statusbar/Mine.tga",
        ["Solid (No Texture)"] = "Solid",
    })
    SortMedia(list, function(o) return o.key end)
    local names = {}
    for i, o in ipairs(list) do names[i] = o.value end
    eq(table.concat(names, " | "),
       "Solid (No Texture) | DF Minimalist | DF Stripes Soft | Another Mine | My Glossy | Aluminium | Bars",
       "order: Solid, then DF, then MyMedia (any slash or case), then the rest, each A-Z")
    eq(list[2].group, list[3].group, "groups: DF media share a group")
    check(list[4].group ~= list[3].group, "groups: MyMedia starts a new one (a divider)")
    check(list[6].group ~= list[5].group, "groups: ...and so does everything else")

    local empty = {}
    SortMedia(empty, function(o) return o.key end)
    eq(#empty, 0, "an empty (filtered-out) list is fine")
end
