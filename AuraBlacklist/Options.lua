local addonName, DF = ...

-- ============================================================
-- AURA BLACKLIST - RETIREMENT NOTICE
-- The blacklist was superseded by the filter registry: buffs are
-- controlled per-spell via Filter Designer presets and per-row
-- filter selections, and debuff spell filtering is not possible
-- on friendly frames on this game version. The page stays
-- registered so users find this notice instead of a vanished
-- tab. The stored data (DF.db.auraBlacklist) is kept but no
-- longer enforced anywhere.
-- Called from Options/Options.lua via DF.BuildAuraBlacklistPage()
-- ============================================================

local L = DF.L

-- ============================================================
-- MAIN PAGE BUILD
-- ============================================================

function DF.BuildAuraBlacklistPage(guiRef, pageRef, dbRef)
    -- Static notice — build once, nothing to refresh on later visits
    if pageRef._auraBlacklistBuilt then return end
    pageRef._auraBlacklistBuilt = true

    local GUI = guiRef
    local parent = pageRef.child

    -- ========== RETIREMENT NOTICE ==========
    local banner = GUI:CreateInfoBanner(parent, {
        tone = "info",
        text = L["The Aura Blacklist has been retired and replaced by the filter system."],
    })
    banner:SetPoint("TOPLEFT", 10, -10)
    banner:SetPoint("RIGHT", -10, 0)

    local desc = parent:CreateFontString(nil, "OVERLAY", "DFFontHighlightSmall")
    desc:SetPoint("TOPLEFT", banner, "BOTTOMLEFT", 0, -12)
    desc:SetPoint("RIGHT", -10, 0)
    desc:SetJustifyH("LEFT")
    desc:SetWordWrap(true)
    desc:SetText(L["To hide specific buffs, disable them in the Filter Designer or change which filters your buff bar uses on the Aura Filters page. On this version of the game, individual debuffs cannot be hidden on party and raid frames."])
    desc:SetTextColor(0.6, 0.6, 0.6)

    -- ========== NAVIGATION BUTTONS ==========
    -- Same SelectTab-with-Pages-guard idiom as the Aura Filters page's
    -- Manage Filters button: no-op unless the target page id exists, so
    -- the buttons can't strand the panel on a blank page.
    local filtersBtn = GUI:CreateButton(parent, L["Aura Filters"], 140, 22, function()
        if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filters"] then
            GUI.SelectTab("auras_filters")
        end
    end)
    filtersBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)

    local designerBtn = GUI:CreateButton(parent, L["Filter Designer"], 140, 22, function()
        if GUI.SelectTab and GUI.Pages and GUI.Pages["auras_filterdesigner"] then
            GUI.SelectTab("auras_filterdesigner")
        end
    end)
    designerBtn:SetPoint("LEFT", filtersBtn, "RIGHT", 10, 0)
end
