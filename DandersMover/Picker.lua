local addonName, NS = ...
-- A copy that lost the LibStub race (a renamed duplicate install) must go
-- fully inert: Core.lua only sets NS.Lib on the winning copy.
if not NS.Lib then return end

-- ============================================================
-- TARGET PICKER
-- The option list behind the panel's anchor dropdowns: every target the
-- selected element may legally anchor to, bucketed under the addon (and group)
-- that owns it. A pure read of the registry -- it decides WHAT may be picked,
-- never what happens when something is.
-- ============================================================
local Pk = {}
NS.Picker = Pk

local Registry, UI, L = NS.Registry, NS.UI, NS.L
local ipairs, tinsert = ipairs, table.insert

-- The "no backup" row's value; the panel maps it to Sess:ClearFallback.
Pk.NONE = "NONE"

-- kind: nil/"primary" = the anchor picker, "fallback" = the backup picker.
-- Returns the options table UI:CreateDropdown consumes (the keys ARE the
-- values, the row order is options._order) plus that order array.
function Pk:Options(el, kind)
    local order = {}
    local options = { _order = order }
    if not el then return options, order end

    local pos = Registry:GetPos(el)
    local primaryId = pos.anchor and pos.anchor.target or nil

    -- Anything hanging off this element is a loop by another name.
    -- WouldCreateCycle catches these too; the descendant set is the cheap pass.
    local descendant = {}
    for _, child in ipairs(Registry:Descendants(el.id)) do descendant[child.id] = true end

    if kind == "fallback" then
        tinsert(order, Pk.NONE)
        options[Pk.NONE] = { value = Pk.NONE, text = L["None"] }
    end

    -- Bucket by (addon, group) FIRST, in the order each bucket is met: a header
    -- is then only emitted for a bucket that actually kept a target, and its
    -- rows always follow it -- SortedTargets is id-ordered, which can interleave
    -- one addon's groups. \30 (record separator) joins the two halves of the
    -- bucket key so a group label cannot forge another bucket's key.
    local buckets, seen = {}, {}
    for _, t in ipairs(Registry:SortedTargets()) do
        local canon = Registry:CanonicalId(t.id)
        if canon ~= el.id
            and not descendant[canon]
            -- IsEnabled(addon, key) answers "is the whole addon off" as well.
            and Registry:IsEnabled(t.addon, t.key)
            -- A backup that IS the primary is not a backup.
            and not (kind == "fallback" and t.id == primaryId)
            and not Registry:WouldCreateCycle(el.id, t.id)
        then
            local addon = Registry:GetAddon(t.addon)
            local addonTitle = addon and addon.title or t.addon
            local key = "__hdr_" .. t.addon .. "\30" .. (t.group or "")
            local bucket = seen[key]
            if not bucket then
                bucket = {
                    key = key,
                    text = t.group and (addonTitle .. " — " .. t.group) or addonTitle,
                    targets = {},
                }
                seen[key] = bucket
                tinsert(buckets, bucket)
            end
            tinsert(bucket.targets, t)
        end
    end

    for _, bucket in ipairs(buckets) do
        tinsert(order, bucket.key)
        options[bucket.key] = { header = true, text = bucket.text }
        for _, t in ipairs(bucket.targets) do
            -- A target with nothing on screen is still a legitimate pick (it is
            -- how you anchor to something that only appears in raid), so it is
            -- offered -- dimmed and marked, not withheld.
            local text, color = t.title, nil
            if not Registry:IsTargetAvailable(t) then
                text = t.title .. " " .. L["(hidden)"]
                color = UI.Colors.textDim
            end
            tinsert(order, t.id)
            options[t.id] = { value = t.id, text = text, color = color }
        end
    end

    return options, order
end
