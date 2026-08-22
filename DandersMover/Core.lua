local addonName, NS = ...

-- ============================================================
-- LIBRARY OBJECT
-- The public API lives on the LibStub object; internals live on NS.
-- ============================================================
local MAJOR, MINOR = "DandersMover-1.0", 1
local Lib = LibStub:NewLibrary(MAJOR, MINOR)
if not Lib then return end
NS.Lib = Lib
NS.VERSION = C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version") or "dev"

function NS:Print(msg)
    print("|cff2e9cc9DandersMover:|r " .. tostring(msg))
end

function NS:Debug(msg)
    if NS.db and NS.db.debug then print("|cff888888DandersMover:|r " .. tostring(msg)) end
end

-- ============================================================
-- SLASH
-- ============================================================
SLASH_DANDERSMOVER1 = "/mover"
SlashCmdList.DANDERSMOVER = function(msg)
    NS:Print(NS.VERSION)
end
