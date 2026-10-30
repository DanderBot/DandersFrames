-- Part 5 of the settings pages, split from Options.lua.
-- The parts run as a chain so the pages build in their original order.
-- ☠ Companion addon: `...` yields THIS addon's private table, not the
-- parent's, so every DF.* read here would be nil. Take the parent's table
-- from the global it publishes at DandersFrames/Core.lua:9 (`_G[addonName]
-- = DF`). NOT from ## AllowAddOnTableAccess -- that directive governs
-- access to an addon's PRIVATE table and has nothing to do with the global
-- name; deleting Core.lua:9 as "redundant" would nil DF in every file here.
local DF = DandersFrames
local format = string.format
function DF._SetupGUIPagesPart5(GUI, CreateCategory, CreateSubTab, BuildPage, L, AddColorsPageLink, CreateCopyButton, pagePinnedFrames, pageBuffs, pageIcons)
    BuildPage(pageIcons, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        -- Every icon on the page needs its own prefix; "combatIcon" was the one
        -- omission, so the Combat icon's seven settings were skipped by Copy, Sync
        -- and Reset while every other icon on the same page travelled.
        Add(CreateCopyButton(self.child, {"roleIcon", "leaderIcon", "raidTargetIcon", "readyCheckIcon", "pingIcon", "summonIcon", "resurrectionIcon", "phasedIcon", "afkIcon", "vehicleIcon", "raidRoleIcon", "bgCarrierIcon", "combatIcon", "statusIconFont", "statusIconFontSize", "statusIconFontOutline"}, L["Icons"], "indicators_icons"), 25, 2)

        local anchorOptions = {
            CENTER = L["Center"],
            TOP = L["Top"],
            BOTTOM = L["Bottom"],
            LEFT = L["Left"],
            RIGHT = L["Right"],
            TOPLEFT = L["Top Left"],
            TOPRIGHT = L["Top Right"],
            BOTTOMLEFT = L["Bottom Left"],
            BOTTOMRIGHT = L["Bottom Right"],
        }

        local roleStyleOptions = {
            BLIZZARD = L["Blizzard"],
            CUSTOM = "DF Icons",
            EXTERNAL = L["External"],
        }

        -- ===== THE PAGE'S CARDS ===========================================
        -- The biggest page in the addon: one shared typography block plus
        -- THIRTEEN status icons, each carrying the same Settings / Appearance /
        -- Position trio (AFK adds its timer text). ~215 widgets, and every icon
        -- says the same three things with a different prefix.
        --
        -- ☠ SO THE SHAPE IS WRITTEN ONCE AND PARAMETERISED, NOT THIRTEEN TIMES.
        -- BuildIconSettingsGroup / BuildIconAppearanceGroup /
        -- BuildIconPositionGroup take a SPEC -- key prefix, enable key and label,
        -- which callbacks the icon's own render path wants, and the handful of
        -- extras that are genuinely per-icon -- and MountIcon queues it. Thirteen
        -- copies of a builder would drift, and the first thing to drift would be
        -- one of the callbacks: eleven icons repaint through
        -- DF:LightweightUpdateIcon*(tag) and two through
        -- DF:UpdateAllFramesStatusIcons, which is exactly the kind of difference
        -- a copy-paste pass flattens by accident.
        --
        -- ONE CARD PER ICON: the icon's Settings, Appearance and Position
        -- builders mounted one after another into the same card. The icon's
        -- Enable is the card's HEADER TICK (the Settings builder skips its
        -- in-body copy through hoistToggle), so an icon is switched on or off
        -- without opening anything, and a shut card says "Off" or its summary.
        -- Role has no single enable, so its card has no tick. Icon Text Settings
        -- is a card of its own. AFK's Timer Text sits inside the AFK card under
        -- its own header: it has its own Font, Offset X and Offset Y, and hides
        -- as a unit.
        --
        -- The cards are grouped by subject (ICON_GROUPS, after the last
        -- MountIcon), each group under its header in its column. Every card
        -- decides how its icon LOOKS (text or icon, scale, alpha, where it
        -- sits), so every card pins.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE CARD: the Debuff Bar's helper (tools.OpenSection) and its opt-ins,
        -- which every card here takes. Shut on a first run: fifteen cards read
        -- as a gallery of headers, each with its icon's preview.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true, collapsed = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- The summary convention, once: at most four items, a fixed order,
        -- "\194\183" between them, WORDS localised and numbers raw, every read
        -- guarded because a profile mid-migration may be missing any of these keys.
        local function Join(parts) return table.concat(parts, " \194\183 ") end

        -- The two callback families this page has, named once. Eleven icons
        -- repaint through the lightweight per-tag helpers; BG Carrier and Combat
        -- have no lightweight path and go through the status-icon pass.
        local function StatusIconsCB() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end
        -- The status TEXT boxes are the one control that does NOT refresh the test
        -- frames -- they never did, and typing into an edit box is not a moment to
        -- rebuild them.
        local function StatusTextCB() DF:UpdateAllFramesStatusIcons() end

        -- ============================================
        -- ICON TEXT SETTINGS (Collapsible, at top)
        -- ============================================
        local function BuildIconTextGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            local function add(widget, height) return group:AddWidget(widget, height) end

            add(GUI:CreateLabel(parent, L["Font settings for icons displayed as text (Summon, Res, AFK, etc.)"], 240), 30)
            add(GUI:CreateFontDropdown(parent, L["Font"], db, "statusIconFont", StatusIconsCB), 55)
            add(GUI:CreateSlider(parent, L["Font Size"], 8, 24, 1, db, "statusIconFontSize", StatusIconsCB, StatusIconsCB, true), 55)
            add(GUI:CreateOutlineDropdown(parent, L["Outline"], db, "statusIconFontOutline", StatusIconsCB), 55)
            add(GUI:CreateShadowCheckbox(parent, L["Shadow"], db, "statusIconFontOutline", StatusIconsCB), 30)

            -- ⚠ Fixed-layout link (GUI:CreateLink) — it flows once at build and reports its own
            -- height, so it must be Add'd at note.layoutHeight rather than a guessed row.
            local shadowNote = GUI:CreateGlobalFontsShadowLink(parent, 240)
            add(shadowNote, shadowNote.layoutHeight)
            shadowNote.hideOn = function(d) return not DF:OutlineHasShadow(d.statusIconFontOutline) end
        end

        -- The two facts a font block has that are worth reading off a shut plate.
        local function IconTextSummary(d)
            if not d then return "" end
            local parts = {}
            if type(d.statusIconFont) == "string" and d.statusIconFont ~= "" then
                parts[#parts + 1] = d.statusIconFont
            end
            local size = tonumber(d.statusIconFontSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            return Join(parts)
        end

        -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
        -- Debuff Bar's placement: they act on cards in both columns, and
        -- "both" carries them through the one-column fold intact. With
        -- fifteen cards on the page they matter more here than anywhere.
        Add(tools.SectionControls(self.child), 24, "both")
        -- The page's shared typography, first. The sentence and the shadow
        -- link are not settings, so each takes a row of its own; the four
        -- controls between them lay out 2 x 2 when the card is wide enough.
        -- It decides how status text LOOKS, so it pins.
        Add(GUI:CreateHeader(self.child, L["Text"]), 40, 1)
        local band = OpenSection(L["Icon Text Settings"], "icons_text", 1, IconTextSummary,
            nil, nil, BuildIconTextGroup)
        BuildIconTextGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- ★ PER-ICON TEXT COLOURS DO NOT LIVE HERE. Each sits in its OWN icon's Settings
        -- group, beside that icon's Show as Text and label controls, and hides when Show as
        -- Text is off -- so the control is where you are already looking when you turn text on.
        -- ⚠ Adding a new status icon? Its text colour belongs in ITS section, not here.
        -- What remains in this section is genuinely SHARED typography: one font, size,
        -- outline and shadow for every status icon that renders as text.

        -- Per-icon TEXT COLOUR row. One helper rather than seven near-identical pairs:
        -- ⚠ it also keeps SEVEN locals out of this function. DF._SetupGUIPagesPart5 is
        -- ~2200 lines in a single scope and Lua caps locals at 200 per scope, so a batch
        -- of throwaway handles is a real cost here, not a style preference.
        -- Hidden unless that icon is in text mode -- an icon-mode colour picker controls
        -- nothing visible.
        local function AddTextColor(group, parent, label, key, showKey)
            local w = group:AddWidget(GUI:CreateColorPicker(parent, label, db, key, false, nil,
                StatusIconsCB, true), 30)
            w.hideOn = function(d) return not d[showKey] end
            return w
        end

        -- ============================================
        -- ROLE ICON (Collapsible)
        -- ============================================
        -- ☠ THE ONE ICON WITH NO ENABLE. Role has three per-role Show toggles and
        -- no master boolean, so its card carries NO header tick and nothing on it
        -- greys -- there is no page gate here and no per-icon gate either. (The
        -- third distinct reason a card refuses a tick, after Highlights' "the
        -- master is a MODE" and Personal Targeted's "not everything in the group
        -- depends on it": here there is no single master at all.)
        local roleSection

        -- Header preview: the Tank/Healer/DPS icons in the currently selected
        -- style. Rebuilt live whenever the style, an external path, or a
        -- per-role Show toggle changes. Each role's icon desaturates when its
        -- Show toggle is off (matching the other icon sections' previews);
        -- the whole preview dims only when all three roles are off.
        local roleShowKeys = { TANK = "roleIconShowTank", HEALER = "roleIconShowHealer", DAMAGER = "roleIconShowDPS" }
        local function UpdateRolePreview()
            if not (roleSection and roleSection.SetPreviewIcons) then return end
            local icons = {}
            local anyShown = false
            for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
                -- tex may be an atlas name (no coords) or a texture path (+coords).
                local tex, l, r, t, b = DF:GetRoleIconTexture(db, role)
                if tex then
                    local shown = db[roleShowKeys[role]] ~= false
                    anyShown = anyShown or shown
                    icons[#icons + 1] = { texture = tex, coords = l and { l, r, t, b } or nil, desaturate = not shown }
                end
            end
            roleSection:SetPreviewIcons(icons)
        end

        local function RoleSettingsCB() DF:UpdateAllRoleIcons(); UpdateRolePreview() end

        local function BuildRoleSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateDropdown(parent, L["Icon Style"], roleStyleOptions, db, "roleIconStyle", RoleSettingsCB), 55)
            local roleExtTank = group:AddWidget(GUI:CreateEditBox(parent, L["Tank Icon Path"], db, "roleIconExternalTank", RoleSettingsCB, nil, "Interface\\MyIcons\\Tank.tga"), 55)
            roleExtTank.hideOn = function(d) return d.roleIconStyle ~= "EXTERNAL" end
            local roleExtHealer = group:AddWidget(GUI:CreateEditBox(parent, L["Healer Icon Path"], db, "roleIconExternalHealer", RoleSettingsCB, nil, "Interface\\MyIcons\\Healer.tga"), 55)
            roleExtHealer.hideOn = function(d) return d.roleIconStyle ~= "EXTERNAL" end
            local roleExtDPS = group:AddWidget(GUI:CreateEditBox(parent, L["DPS Icon Path"], db, "roleIconExternalDPS", RoleSettingsCB, nil, "Interface\\MyIcons\\DPS.tga"), 55)
            roleExtDPS.hideOn = function(d) return d.roleIconStyle ~= "EXTERNAL" end
            local roleExtNote = group:AddWidget(GUI:CreateLabel(parent, L["Paths are relative to your WoW folder and must start with Interface\\. Pasting a full path works — anything before 'Interface' is stripped. Leave empty for DF Icons."], 250), 70)
            roleExtNote.hideOn = function(d) return d.roleIconStyle ~= "EXTERNAL" end
            -- Per-role filters: which roles ever show an icon (global — apply in and
            -- out of combat). The Hide In Combat toggle (Appearance) is an independent gate.
            group:AddWidget(GUI:CreateCheckbox(parent, L["Show Tank"], db, "roleIconShowTank", RoleSettingsCB), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Show Healer"], db, "roleIconShowHealer", RoleSettingsCB), 30)
            group:AddWidget(GUI:CreateCheckbox(parent, L["Show DPS"], db, "roleIconShowDPS", RoleSettingsCB), 30)
        end

        -- The style, and which roles are LEFT ON -- named the way Personal Targeted's
        -- Content Types row names them: all three ship on, so the row is silent about
        -- them on a default profile rather than reciting the default back, and the
        -- moment one is off there are at most two left to name. Style plus two roles
        -- is inside the four-item budget; three roles can only be printed when none
        -- has been switched off, which is the case that prints none of them.
        local function RoleSettingsSummary(d)
            if not d then return "" end
            local parts = {}
            local style = roleStyleOptions[d.roleIconStyle]
            if style then parts[#parts + 1] = style end
            local tank, healer, dps = d.roleIconShowTank ~= false, d.roleIconShowHealer ~= false, d.roleIconShowDPS ~= false
            if not (tank and healer and dps) then
                if tank then parts[#parts + 1] = L["Tank"] end
                if healer then parts[#parts + 1] = L["Healer"] end
                if dps then parts[#parts + 1] = L["DPS"] end
                -- Every role switched off: the icon is enabled and draws nothing,
                -- and the row has to say so rather than read as a default.
                if not (tank or healer or dps) then parts[#parts + 1] = L["None"] end
            end
            return Join(parts)
        end

        -- ============================================
        -- STATUS-ICON HEADER PREVIEWS
        -- Each icon card shows a representative swatch in its header icon slot,
        -- desaturated when the icon is disabled. Refreshers are registered
        -- globally and re-run by hooked frame-update functions, so previews track
        -- live enable changes without touching every control's callback. This
        -- block must run before MountIcon, which wires every card's preview.
        -- ============================================
        if not DF._iconPreviewHooked then
            DF._iconPreviewHooked = true
            -- ⚠ HOOK THE BODY, NOT THE STUB. DF:UpdateAllFrames is now an
            -- arm-stub that only marks the sweep dirty (Core\ApplyScheduler.lua);
            -- a post-hook on it would refresh the previews before the sweep it
            -- is meant to follow. `_Now` is the real body.
            if DF.UpdateAllFrames_Now then
                hooksecurefunc(DF, "UpdateAllFrames_Now", function() DF:RefreshIconPreviews() end)
            end
            if DF.UpdateAllFramesStatusIcons then
                hooksecurefunc(DF, "UpdateAllFramesStatusIcons", function() DF:RefreshIconPreviews() end)
            end
        end
        if DF.iconPreviewRefreshers then wipe(DF.iconPreviewRefreshers) end

        -- A card's preview is one icon in its header's icon slot, with no room
        -- for text (see SetPreviewIcons), so it is always the icon.
        local function WireStatusPreview(section, opts)
            local function refresh(force)
                if not section.SetPreviewIcons then return end
                if not force and not section:IsVisible() then return end
                local enabled = (not opts.enableKey) or (db[opts.enableKey] ~= false)
                local entries = {}
                for _, ic in ipairs(opts.icons or {}) do
                    if type(ic) == "table" then
                        -- table form: { texture = <path OR atlas name>, coords = {l,r,t,b} }
                        -- for icons that need a texcoord slice (e.g. raid-target markers
                        -- off the shared UI-RaidTargetingIcons sheet). SetIconTextureOrAtlas
                        -- auto-detects atlas vs path, so a plain texture string still works.
                        entries[#entries + 1] = { texture = ic.texture, coords = ic.coords, inset = ic.inset,
                                              color = ic.colorKey and db[ic.colorKey] or ic.color }
                    else
                        entries[#entries + 1] = { texture = ic }
                    end
                end
                for _, e in ipairs(entries) do e.desaturate = not enabled end
                section:SetPreviewIcons(entries)
            end
            if DF.iconPreviewRefreshers then table.insert(DF.iconPreviewRefreshers, refresh) end
            refresh(true)
        end

        -- ============================================
        -- ONE ICON'S OPTION SHAPE, SAID ONCE
        -- --------------------------------------------
        -- The three builders below are what all thirteen icons are made of. A
        -- spec names the key prefix, the enable, the extras and which callback
        -- family the icon repaints through; everything else is identical --
        -- test_icons_page_builders.lua pins the builders control by control AND
        -- every spec field.
        --
        -- Spec fields, all optional except `key`, `section` and `col`:
        --   key             db prefix ("summonIcon"); also the card's fold key,
        --                   "icons_<key>"
        --   section         the card's name
        --   col             the card's column
        --   id              the lightweight render tag ("summon"); absent = this icon
        --                   repaints through the status-icon pass instead
        --   enableKey/enableLabel/enableTooltip/onEnable   the master switch
        --                   (the card's header tick)
        --   note/noteHeight                                one explanatory label
        --   showTextKey/texts                              the Show as Text block
        --   before/after    per-icon widgets around that block
        --   hideInCombatLabel/onHideInCombat               the Appearance extra
        --   summary         replaces the shared Settings summary (Role)
        --   summaryExtra    what this icon's Settings summary says beyond the shared part
        --   extraGroup      AFK's Timer Text: a header inside the icon's own card
        --   preview         WireStatusPreview's opts: the header's icon preview
        -- ============================================
        local function BuildIconSettingsGroup(tools2, spec)
            local group, parent = tools2.group, tools2.parent

            -- Suppressed when the CARD's header carries this tick. Still built in
            -- a pinned panel, where it is this icon's only on/off control. The
            -- group gate arrives either way: the Appearance and Position
            -- builders, mounted after this one, set it.
            if spec.enableKey and not tools2.hoistToggle then
                group.disableChildrenOn = spec.gate
                local enableCb = group:AddWidget(GUI:CreateCheckbox(parent, spec.enableLabel, db, spec.enableKey, spec.onEnable), 30)
                enableCb.keepEnabled = true
                if spec.enableTooltip then enableCb.tooltip = spec.enableTooltip end
            end
            if spec.note then group:AddWidget(GUI:CreateLabel(parent, spec.note, 240), spec.noteHeight) end
            if spec.before then spec.before(group, parent) end
            if spec.showTextKey then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show as Text"], db, spec.showTextKey, StatusIconsCB), 30)
                for _, t in ipairs(spec.texts) do
                    group:AddWidget(GUI:CreateEditBox(parent, t.label, db, t.key, StatusTextCB, 120), 55)
                end
                AddTextColor(group, parent, L["Text Color"], spec.key .. "TextColor", spec.showTextKey)
            end
            if spec.after then spec.after(group, parent) end
        end

        local function BuildIconAppearanceGroup(tools2, spec)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = spec.gate
            group:AddWidget(GUI:CreateSlider(parent, L["Scale"], 0.5, 2.5, 0.1, db, spec.key .. "Scale", nil, spec.cbPosition, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0.1, 1.0, 0.05, db, spec.key .. "Alpha", nil, spec.cbAlpha, true), 55)
            group:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, db, spec.key .. "FrameLevel", nil, spec.cbFrameLevel, true)), 55)
            if spec.hideInCombatLabel then
                group:AddWidget(GUI:CreateCheckbox(parent, spec.hideInCombatLabel, db, spec.key .. "HideInCombat", spec.onHideInCombat), 30)
            end
        end

        local function BuildIconPositionGroup(tools2, spec)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = spec.gate
            group:AddWidget(GUI:CreateDropdown(parent, L["Anchor"], anchorOptions, db, spec.key .. "Anchor", spec.cbPosition), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -50, 50, 1, db, spec.key .. "X", nil, spec.cbPosition, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -50, 50, 1, db, spec.key .. "Y", nil, spec.cbPosition, true), 55)
        end

        -- The three summaries, also once. Every one is silent on a default profile
        -- and says only what has been changed -- with thirteen icons on one page,
        -- a row that recited its defaults would be thirteen lines of noise.
        local function IconSettingsSummary(spec)
            return function(d)
                if not d then return "" end
                local parts = {}
                if spec.showTextKey and d[spec.showTextKey] then
                    parts[#parts + 1] = L["Show as Text"]
                    local first = spec.texts and spec.texts[1]
                    local text = first and d[first.key]
                    if type(text) == "string" and text ~= "" then parts[#parts + 1] = text end
                end
                if spec.summaryExtra then spec.summaryExtra(d, parts) end
                return Join(parts)
            end
        end

        local function IconAppearanceSummary(spec)
            return function(d)
                if not d then return "" end
                local parts = {}
                local scale = tonumber(d[spec.key .. "Scale"])
                if scale and scale ~= 1 then parts[#parts + 1] = format("%.1fx", scale) end
                local alpha = tonumber(d[spec.key .. "Alpha"])
                if alpha and alpha < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], alpha) end
                if spec.hideInCombatLabel and d[spec.key .. "HideInCombat"] then
                    parts[#parts + 1] = spec.hideInCombatLabel
                end
                return Join(parts)
            end
        end

        local function IconPositionSummary(spec)
            return function(d)
                if not d then return "" end
                local parts = {}
                local anchor = anchorOptions[d[spec.key .. "Anchor"]]
                if anchor then parts[#parts + 1] = anchor end
                local x = tonumber(d[spec.key .. "X"]) or 0
                local y = tonumber(d[spec.key .. "Y"]) or 0
                if x ~= 0 or y ~= 0 then parts[#parts + 1] = format("%d, %d", x, y) end
                return Join(parts)
            end
        end

        -- A card's corner: the three summaries above, in the card's own order
        -- (settings, looks, place), each only when it has something to say.
        local function IconCardSummary(spec)
            local fns = { spec.summary or IconSettingsSummary(spec),
                          IconAppearanceSummary(spec), IconPositionSummary(spec) }
            return function(d)
                if not d then return "" end
                local parts = {}
                for _, fn in ipairs(fns) do
                    local s = fn(d)
                    if s ~= "" then parts[#parts + 1] = s end
                end
                return Join(parts)
            end
        end

        -- ============================================
        -- ONE ICON'S CARD
        -- --------------------------------------------
        -- The icon's three builders -- Settings (or the icon's own, Role's),
        -- Appearance, Position -- mounted one after another into ONE card. The
        -- same function is the pin's builder, so a pinned panel holds exactly
        -- what the card does (plus the enable checkbox, which a panel has no
        -- header to carry).
        --
        -- ☠ THE ENABLE IS THE HEADER'S TICK, and the Settings builder skips its
        -- in-body copy (hoistToggle) -- one checkbox per setting. Its commit is
        -- what the in-body checkbox ran (spec.onEnable), then the state pass that
        -- re-greys the card and a repaint of a pinned panel -- never a rebuild.
        --
        -- ⚠ AFK'S TIMER TEXT IS IN THE AFK CARD, under its own header right
        -- after Show Timer -- where it is switched on. Header and controls hide
        -- together unless Show Timer is on in icon mode (extra.hideOn). Its
        -- Color and Offset X / Y say "Timer", or they would repeat the icon's
        -- own names.
        -- ============================================
        local function MountIconCard(spec)
            local settingsBuild = spec.settings or BuildIconSettingsGroup
            local extra = spec.extraGroup
            local function BuildExtraInCard(tools2)
                local group = tools2.group
                local first = #(group.groupChildren or {}) + 1
                group:AddWidget(GUI:CreateHeader(tools2.parent, extra.label, { keepSearchSection = true }),
                    GUI.RowHeight.sectionHeader)
                extra.build({ group = group, parent = tools2.parent,
                              refreshStates = tools2.refreshStates }, spec)
                for i = first, #(group.groupChildren or {}) do
                    local w = group.groupChildren[i].widget
                    local own = w.hideOn
                    w.hideOn = function(d) return extra.hideOn(d) or (own and own(d)) or false end
                end
            end
            local function BuildIconCard(tools2)
                settingsBuild(tools2, spec)
                if extra then BuildExtraInCard(tools2) end
                BuildIconAppearanceGroup(tools2, spec)
                BuildIconPositionGroup(tools2, spec)
            end
            local toggle
            if spec.enableKey then
                toggle = {
                    db = db, key = spec.enableKey, label = spec.enableLabel,
                    tooltip = spec.enableTooltip,
                    onChanged = function()
                        if spec.onEnable then spec.onEnable() end
                        self:RefreshStates()
                        tools.ReflowMounted()
                    end,
                }
            end
            local band = OpenSection(spec.section, "icons_" .. spec.key, spec.col, IconCardSummary(spec),
                nil, nil, BuildIconCard, toggle)
            local section = band.collapsibleSection
            if spec.onSection then spec.onSection(section) end
            if spec.preview then WireStatusPreview(section, spec.preview) end
            BuildIconCard({
                group = band, parent = self.child,
                refreshStates = function() self:RefreshStates() end,
                hoistToggle = spec.enableKey ~= nil,
            })
            CloseSection(band)
            if spec.afterMount then spec.afterMount() end
        end

        -- The cards mount by subject group once every spec is in (the loop
        -- after the last MountIcon), so MountIcon only completes the spec and
        -- queues it.
        local queuedIcons = {}
        local function MountIcon(spec)
            spec.gate = spec.enableKey and function(d) return not (d or db)[spec.enableKey] end or nil
            if spec.id then
                spec.cbPosition   = function() DF:LightweightUpdateIconPosition(spec.id) end
                spec.cbAlpha      = function() DF:LightweightUpdateIconAlpha(spec.id) end
                spec.cbFrameLevel = function() DF:LightweightUpdateFrameLevel(spec.id) end
            else
                spec.cbPosition, spec.cbAlpha, spec.cbFrameLevel = StatusIconsCB, StatusIconsCB, StatusIconsCB
            end

            queuedIcons[#queuedIcons + 1] = spec
        end

        -- The shared enable callback: eleven of the twelve switchable icons run
        -- exactly this, and Ping runs it after its own mirror wiring.
        local function OnIconEnabled() DF:UpdateAllFrames() end

        -- ============================================
        -- ROLE ICON (Collapsible)
        -- ============================================
        MountIcon({
            key = "roleIcon", id = "role", section = L["Role Icon"], col = 1,
            onSection = function(section) roleSection = section end,
            settings = BuildRoleSettingsGroup,
            summary = RoleSettingsSummary,
            hideInCombatLabel = L["Hide In Combat"],
            onHideInCombat = function() DF:UpdateAllRoleIcons() end,
            -- Initial header preview for the current style.
            afterMount = UpdateRolePreview,
        })

        -- ============================================
        -- LEADER ICON (Collapsible)
        -- ============================================
        MountIcon({
            key = "leaderIcon", id = "leader", section = L["Leader Icon"], col = 1,
            enableKey = "leaderIconEnabled", enableLabel = L["Enable Leader Icon"],
            onEnable = OnIconEnabled,
            hideInCombatLabel = L["Hide in Combat"], onHideInCombat = OnIconEnabled,
            preview = { enableKey = "leaderIconEnabled", icons = { "Interface\\GroupFrame\\UI-Group-LeaderIcon" } },
        })

        -- ============================================
        -- RAID TARGET ICON (Collapsible)
        -- ============================================
        MountIcon({
            key = "raidTargetIcon", id = "raidTarget", section = L["Target Marker Icon"], col = 1,
            enableKey = "raidTargetIconEnabled", enableLabel = L["Enable Target Marker Icon"],
            onEnable = OnIconEnabled,
            hideInCombatLabel = L["Hide in Combat"], onHideInCombat = OnIconEnabled,
            -- Header preview: the four most-used markers (square / cross / triangle / circle),
            -- sliced from the raid-target sheet via texcoords (the atlas form won't render here).
            preview = { enableKey = "raidTargetIconEnabled", icons = {
                { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.25, 0.5,  0.25, 0.5  }, inset = 1.5 },  -- square   (6)
                { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.5,  0.75, 0.25, 0.5  }, inset = 1.5 },  -- cross    (7)
                { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.75, 1.0,  0.0,  0.25 }, inset = 1.5 },  -- triangle (4)
                { texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcons", coords = { 0.25, 0.5,  0.0,  0.25 }, inset = 1.5 },  -- circle   (2)
            } },
        })

        -- ============================================
        -- READY CHECK ICON (Collapsible)
        -- ============================================
        MountIcon({
            key = "readyCheckIcon", id = "readyCheck", section = L["Ready Check Icon"], col = 1,
            enableKey = "readyCheckIconEnabled", enableLabel = L["Enable Ready Check Icon"],
            onEnable = OnIconEnabled,
            after = function(group, parent)
                group:AddWidget(GUI:CreateSlider(parent, L["Persist (seconds)"], 0, 15, 1, db, "readyCheckIconPersist"), 55)
            end,
            summaryExtra = function(d, parts)
                local persist = tonumber(d.readyCheckIconPersist)
                if persist then parts[#parts + 1] = format("%ds", math.floor(persist)) end
            end,
            hideInCombatLabel = L["Hide in Combat"], onHideInCombat = OnIconEnabled,
            preview = { enableKey = "readyCheckIconEnabled", icons = { "UI-LFG-ReadyMark-Raid" } },
        })

        -- ============================================
        -- PING ICON (Collapsible)
        -- Mirrors Blizzard's 12.1 frame pings; see Features/PingMirror.lua.
        -- ============================================
        MountIcon({
            key = "pingIcon", id = "ping", section = L["Ping Icon"], col = 1,
            enableKey = "pingIconEnabled", enableLabel = L["Enable Ping Icon"],
            enableTooltip = L["Shows a group member's ping on the frame of the unit they pinged."],
            onEnable = function()
                if DF.OnPingIconToggled then DF:OnPingIconToggled() end
                DF:UpdateAllFrames()
            end,
            hideInCombatLabel = L["Hide in Combat"], onHideInCombat = OnIconEnabled,
            -- NEGATIVE insets: the ping atlases are about half padding, so they draw
            -- larger to show the same amount of icon as the other cards' (~18 of a
            -- 24 slot). Measured per atlas in game -- the three are not padded alike.
            preview = { enableKey = "pingIconEnabled", icons = {
                { texture = "Ping_Frame_Warning", inset = -5.5 },
                { texture = "Ping_Frame_Attack",  inset = -3.5 },
                { texture = "Ping_Frame_Assist",  inset = -3 },
            } },
        })

        -- ============================================
        -- SUMMON ICON (Collapsible)
        -- ============================================
        MountIcon({
            key = "summonIcon", id = "summon", section = L["Summon Icon"], col = 1,
            enableKey = "summonIconEnabled", enableLabel = L["Enable Summon Icon"],
            onEnable = OnIconEnabled,
            showTextKey = "summonIconShowText",
            texts = {
                { label = L["Pending Text"],  key = "summonIconTextPending" },
                { label = L["Accepted Text"], key = "summonIconTextAccepted" },
                { label = L["Declined Text"], key = "summonIconTextDeclined" },
            },
            hideInCombatLabel = L["Hide in Combat"], onHideInCombat = OnIconEnabled,
            preview = { enableKey = "summonIconEnabled", icons = { "RaidFrame-Icon-SummonPending" } },
        })

        -- ============================================
        -- BG OBJECTIVE CARRIER ICON (Collapsible)
        -- Lights up a unit carrying a battleground objective
        -- (flag / orb). Detection is UnitPvpClassification, so it
        -- works with Blizzard raid frames fully disabled.
        -- ============================================
        MountIcon({
            key = "bgCarrierIcon", section = L["BG Carrier Icon"], col = 2,
            enableKey = "bgCarrierIconEnabled", enableLabel = L["Enable BG Carrier Icon"],
            onEnable = OnIconEnabled,
            note = L["Shows on a friendly party/raid member carrying a battleground objective (flag, orb). Only active inside battlegrounds."],
            noteHeight = 44,
            showTextKey = "bgCarrierIconShowText",
            texts = { { label = L["Carrier Text"], key = "bgCarrierIconText" } },
            preview = { enableKey = "bgCarrierIconEnabled", icons = { "Interface\\Icons\\inv_bannerpvp_02" } },
        })

        -- ============================================
        -- COMBAT ICON (Collapsible)
        -- ============================================
        MountIcon({
            key = "combatIcon", section = L["Combat Icon"], col = 2,
            enableKey = "combatIconEnabled", enableLabel = L["Enable Combat Icon"],
            onEnable = OnIconEnabled,
            note = L["Shows crossed swords on a party/raid member who is in combat."],
            noteHeight = 44,
            -- Preview the swords quadrant of the UI-StateIcon sheet (texcoord slice); also
            -- greys the section header when the icon is disabled.
            preview = { enableKey = "combatIconEnabled", icons = { { texture = "Interface\\CharacterFrame\\UI-StateIcon", coords = {0.5, 1.0, 0, 0.49} } } },
        })

        -- ============================================
        -- RESURRECTION ICON (Collapsible)
        -- ============================================
        MountIcon({
            key = "resurrectionIcon", id = "resurrection", section = L["Resurrection Icon"], col = 2,
            enableKey = "resurrectionIconEnabled", enableLabel = L["Enable Resurrection Icon"],
            onEnable = OnIconEnabled,
            showTextKey = "resurrectionIconShowText",
            texts = { { label = L["Casting Text"], key = "resurrectionIconTextCasting" } },
            -- ("Pending Text" removed: resurrectionIconTextPending was never read by
            -- any render path — live or test — since inception. The pending state
            -- renders as the yellow icon tint.)
            preview = { enableKey = "resurrectionIconEnabled", icons = { "RaidFrame-Icon-Rez" } },
        })

        -- ============================================
        -- PHASED ICON (Collapsible)
        -- ============================================
        MountIcon({
            key = "phasedIcon", id = "phased", section = L["Phased Icon"], col = 2,
            enableKey = "phasedIconEnabled", enableLabel = L["Enable Phased Icon"],
            onEnable = OnIconEnabled,
            showTextKey = "phasedIconShowText",
            texts = { { label = L["Status Text"], key = "phasedIconText" } },
            after = function(group, parent)
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show LFG Eye for Cross-Instance"], db, "phasedIconShowLFGEye", OnIconEnabled), 30)
            end,
            summaryExtra = function(d, parts)
                if d.phasedIconShowLFGEye then parts[#parts + 1] = L["Show LFG Eye for Cross-Instance"] end
            end,
            hideInCombatLabel = L["Hide in Combat"], onHideInCombat = OnIconEnabled,
            preview = { enableKey = "phasedIconEnabled", icons = { "RaidFrame-Icon-Phasing" } },
        })

        -- ============================================
        -- AFK ICON (Collapsible)
        -- AFK is the one icon with a fourth box (Timer Text) on top of the
        -- standard Settings / Appearance / Position trio.
        -- ============================================
        local afkTimerCB = function() DF:UpdateAllFramesStatusIcons(); DF:RefreshTestFrames() end
        -- Timer Text — elapsed-time text under the icon. Icon mode only (Show as
        -- Text off) with Show Timer on, so the whole box is gated.
        local function AFKTimerHidden(d) return not d.afkIconShowTimer or d.afkIconShowText end
        local function BuildAFKTimerGroup(tools2, spec)
            local group, parent = tools2.group, tools2.parent

            group.disableChildrenOn = spec.gate
            group:AddWidget(GUI:CreateFontDropdown(parent, L["Font"], db, "afkIconTimerFont", afkTimerCB, "statusIconFont"), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Size"], 6, 24, 1, db, "afkIconTimerFontSize", afkTimerCB, afkTimerCB, true), 55)
            group:AddWidget(GUI:CreateOutlineDropdown(parent, L["Outline"], db, "afkIconTimerOutline", afkTimerCB, "statusIconFontOutline"), 55)
            -- ⚠ SHADOW LIVES INSIDE THE OUTLINE STRING, so this checkbox writes the SAME key as
            -- the dropdown above — hence the matching inheritKey. afkIconTimerOutline ships
            -- UNSET so the timer follows the shared status-icon outline; without the fallback
            -- the box would read unchecked while inheriting a shadow, and ticking it would pin
            -- the outline to NONE, throwing the inherited style away.
            group:AddWidget(GUI:CreateShadowCheckbox(parent, L["Shadow"], db, "afkIconTimerOutline", afkTimerCB, "statusIconFontOutline"), 30)
            -- Same note the shared Icon Text Settings box carries: only WHETHER there is a
            -- shadow is per-timer. Its offset and colour are global (fontShadow* keys) because
            -- on 12.0.7 the shadow rides the font OBJECT — fontstring SetShadow* is a silent
            -- no-op — and font objects are shared. Shown only while a shadow is actually on.
            local afkTimerShadowLink = GUI:CreateGlobalFontsShadowLink(parent, 230)
            local afkTimerShadowNote = group:AddWidget(afkTimerShadowLink, afkTimerShadowLink.layoutHeight)
            afkTimerShadowNote.hideOn = function(d)
                return not DF:OutlineHasShadow(d.afkIconTimerOutline or d.statusIconFontOutline)
            end
            group:AddWidget(GUI:CreateColorPicker(parent, L["Timer Color"], db, "afkIconTimerColor", false, nil, afkTimerCB, true), 30)
            group:AddWidget(GUI:CreateSlider(parent, L["Timer Offset X"], -50, 50, 1, db, "afkIconTimerX", afkTimerCB, afkTimerCB, true), 55)
            group:AddWidget(GUI:CreateSlider(parent, L["Timer Offset Y"], -50, 50, 1, db, "afkIconTimerY", afkTimerCB, afkTimerCB, true), 55)
        end

        MountIcon({
            key = "afkIcon", id = "afk", section = L["AFK Icon"], col = 2,
            enableKey = "afkIconEnabled", enableLabel = L["Enable AFK Icon"],
            onEnable = OnIconEnabled,
            showTextKey = "afkIconShowText",
            texts = { { label = L["Status Text"], key = "afkIconText" } },
            after = function(group, parent)
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Timer"], db, "afkIconShowTimer", StatusTextCB), 30)
                -- In text mode the timer is merged into the status text, so the Timer
                -- Text box is hidden; explain it inherits the main text styling.
                local afkTimerInheritNote = group:AddWidget(GUI:CreateLabel(parent, L["In Text mode the timer joins the status text and uses its font, colour and position."], 230), 40)
                afkTimerInheritNote.hideOn = function(d) return not d.afkIconShowText or not d.afkIconShowTimer end
            end,
            -- The timer, once: its own text size while it draws as its own text,
            -- else just that it shows (in text mode it joins the status text).
            summaryExtra = function(d, parts)
                if not d.afkIconShowTimer then return end
                local size = not AFKTimerHidden(d) and tonumber(d.afkIconTimerFontSize)
                parts[#parts + 1] = size and format("%s %dpx", L["Timer"], math.floor(size)) or L["Show Timer"]
            end,
            extraGroup = {
                label = L["Timer Text"], build = BuildAFKTimerGroup, hideOn = AFKTimerHidden,
            },
            hideInCombatLabel = L["Hide in Combat"], onHideInCombat = OnIconEnabled,
            preview = { enableKey = "afkIconEnabled", icons = { "characterupdate_clock-icon" } },
        })

        -- ============================================
        -- VEHICLE ICON (Collapsible)
        -- ============================================
        MountIcon({
            key = "vehicleIcon", id = "vehicle", section = L["Vehicle Icon"], col = 2,
            enableKey = "vehicleIconEnabled", enableLabel = L["Enable Vehicle Icon"],
            onEnable = OnIconEnabled,
            showTextKey = "vehicleIconShowText",
            texts = { { label = L["Status Text"], key = "vehicleIconText" } },
            hideInCombatLabel = L["Hide in Combat"], onHideInCombat = OnIconEnabled,
            preview = { enableKey = "vehicleIconEnabled", icons = { "RaidFrame-Icon-Vehicle" } },
        })

        -- ============================================
        -- RAID ROLE ICON (Collapsible)
        -- ============================================
        MountIcon({
            key = "raidRoleIcon", id = "raidRole", section = L["Raid Role Icon (MT/MA)"], col = 2,
            enableKey = "raidRoleIconEnabled", enableLabel = L["Enable Raid Role Icon"],
            onEnable = OnIconEnabled,
            before = function(group, parent)
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Main Tank"], db, "raidRoleIconShowTank", OnIconEnabled), 30)
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Main Assist"], db, "raidRoleIconShowAssist", OnIconEnabled), 30)
            end,
            showTextKey = "raidRoleIconShowText",
            texts = {
                { label = L["Tank Text"],   key = "raidRoleIconTextTank" },
                { label = L["Assist Text"], key = "raidRoleIconTextAssist" },
            },
            summaryExtra = function(d, parts)
                -- Both ship on, so the row is silent about them until one is off --
                -- and then it names the one still showing. With both off the icon
                -- draws nothing, which the row says outright.
                local tank, assist = d.raidRoleIconShowTank ~= false, d.raidRoleIconShowAssist ~= false
                if not (tank and assist) then
                    if tank then parts[#parts + 1] = L["Show Main Tank"] end
                    if assist then parts[#parts + 1] = L["Show Main Assist"] end
                    if not (tank or assist) then parts[#parts + 1] = L["None"] end
                end
            end,
            hideInCombatLabel = L["Hide in Combat"], onHideInCombat = OnIconEnabled,
            preview = { enableKey = "raidRoleIconEnabled", icons = { "RaidFrame-Icon-MainTank", "RaidFrame-Icon-MainAssist" } },
        })

        -- The icon cards by subject, each group under its header in its
        -- column. An icon in no group still mounts, after the groups, so a new
        -- one cannot silently drop off the page.
        local ICON_GROUPS = {
            { label = L["Group Roles"], col = 1, keys = { "roleIcon", "leaderIcon", "raidRoleIcon" } },
            { label = L["Markers"],     col = 1, keys = { "raidTargetIcon", "pingIcon" } },
            { label = L["Status"],      col = 2, keys = { "readyCheckIcon", "summonIcon", "resurrectionIcon",
                                                          "phasedIcon", "afkIcon", "vehicleIcon" } },
            { label = L["Combat"],      col = 2, keys = { "combatIcon", "bgCarrierIcon" } },
        }
        local byKey, mounted = {}, {}
        for _, spec in ipairs(queuedIcons) do byKey[spec.key] = spec end
        for _, grp in ipairs(ICON_GROUPS) do
            Add(GUI:CreateHeader(self.child, grp.label), 40, grp.col)
            for _, key in ipairs(grp.keys) do
                local spec = byKey[key]
                if spec then
                    spec.col = grp.col
                    MountIconCard(spec)
                    mounted[key] = true
                end
            end
        end
        for _, spec in ipairs(queuedIcons) do
            if not mounted[spec.key] then MountIconCard(spec) end
        end
    end)
    
    -- Indicators > Highlights
    local pageHighlights = CreateSubTab("indicators", "indicators_highlights", L["Highlights"])
    BuildPage(pageHighlights, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"selectionHighlight", "hoverHighlight", "aggroHighlight", "aggro"}, L["Highlights"], "indicators_highlights"), 25, 2)

        local highlightModes = {
            ["NONE"] = L["Hidden"],
            ["SOLID"] = L["Solid Border"],
            ["ANIMATED"] = L["Animated Border"],
            ["DASHED"] = L["Dashed Border"],
            ["GLOW"] = L["Glow"],
            ["CORNERS"] = L["Corners Only"],
        }

        local aggroModes = {
            ["NONE"] = L["Hidden"],
            ["HEALTH_COLOR"] = L["Health Bar Color"],
            ["SOLID"] = L["Solid Border"],
            ["ANIMATED"] = L["Animated Border"],
            ["DASHED"] = L["Dashed Border"],
            ["GLOW"] = L["Glow"],
            ["CORNERS"] = L["Corners Only"],
        }

        -- All three highlights are the same Thickness / Inset / Alpha trio, so the
        -- Inset explanation is written once. Thickness and Alpha get nothing —
        -- they say what they are; Inset is the one that reads as jargon, and here
        -- the label is a bare "Inset" with not even "Border" in front of it.
        local TIP_HL_INSET = L["How far inside the frame edge the highlight sits. Negative values push it outward, so it rings the frame instead of hugging it — useful when the highlight would otherwise sit under auras or text."]

        -- ===== THE PAGE'S CARDS ===========================================
        --   column 1   Aggro Highlight, Threat Colors -- the one highlight with
        --              behaviour of its own (Only Show When Tanking, Hide on
        --              Tanks) and the palette it paints with.
        --   column 2   Selection Highlight, Hover Highlight -- a mode plus the
        --              border's looks, and nothing else.
        --
        -- ☠ NOTHING ON THIS PAGE TAKES A HEADER TICK. Each highlight's master
        -- control is its MODE -- a dropdown whose "Hidden" entry is the off
        -- switch -- not a boolean, so there is nothing a tick could carry. Threat
        -- Colors' "Use Custom Colors" looks like a candidate and is not one: with
        -- it off the card still does something (the game's own threat palette),
        -- so it is a MODE rather than an enable, and a tick would print "Off"
        -- over a card that was still colouring frames.
        --
        -- There is no page-wide gate here at all: the three highlights are three
        -- independent features, so no card greys another. All four decide how a
        -- highlight LOOKS, so all four take a pin.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates }, so a pinned copy rebuilds the same
        -- controls -- test_highlights_page_builders.lua pins each inventory.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE CARD: the Debuff Bar's helper (tools.OpenSection) and its two
        -- opt-ins, which every card here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end

        -- ===== THE PAGE'S GATES AND APPLIES, AT PAGE SCOPE ================
        -- ⚠ ABOVE EVERY BUILDER. A builder is a CLOSURE, and a closure captures
        -- the upvalue that exists when it is created -- so one declared above
        -- these lines would see nil rather than the function.
        --
        -- Every gate here is a VARIANT gate on a dropdown pick, which is exactly
        -- the case the addon-wide convention leaves as a hide -- so they are
        -- handed to the widgets as hideOn.
        local function HideSelectionOptions(d) return d.selectionHighlightMode == "NONE" end
        local function HideHoverOptions(d) return d.hoverHighlightMode == "NONE" end
        local function HideAggroOptions(d) return d.aggroHighlightMode == "NONE" or d.aggroHighlightMode == "HEALTH_COLOR" end
        local function HideAggroModeNone(d) return d.aggroHighlightMode == "NONE" end
        local function HideCustomColorOptions(d) return d.aggroHighlightMode == "NONE" or not d.aggroUseCustomColors end
        local function HideNonTankingColors(d) return d.aggroHighlightMode == "NONE" or not d.aggroUseCustomColors or d.aggroOnlyTanking end

        -- The summary convention, once: at most four items, a fixed order,
        -- "\194\183" between them, WORDS localised and numbers raw, every read
        -- guarded because a profile mid-migration may be missing any of these
        -- keys.
        local function Join(parts) return table.concat(parts, " \194\183 ") end

        -- Selection and Hover are the SAME four facts about the same four keys,
        -- so the summary is written once and given the prefix. The mode word
        -- first, because it is the one that decides whether the rest exists at
        -- all -- with it on Hidden there is no thickness, inset or alpha behind
        -- the row, and the card hides those controls outright.
        local function HighlightSummary(d, prefix)
            if not d then return "" end
            local parts = {}
            local mode = d[prefix .. "HighlightMode"]
            local word = highlightModes[mode]
            if word then parts[#parts + 1] = word end
            if mode == "NONE" then return Join(parts) end
            local t = tonumber(d[prefix .. "HighlightThickness"])
            if t then parts[#parts + 1] = format("%dpx", math.floor(t)) end
            local inset = tonumber(d[prefix .. "HighlightInset"])
            if inset and inset ~= 0 then parts[#parts + 1] = format("%s %d", L["Inset"], inset) end
            local a = tonumber(d[prefix .. "HighlightAlpha"])
            if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
            return Join(parts)
        end
        local function SelectionSettingsSummary(d) return HighlightSummary(d, "selection") end
        local function HoverSettingsSummary(d) return HighlightSummary(d, "hover") end

        -- Aggro is the same shape plus the two questions that are only about
        -- aggro -- and it has a SECOND mode with nothing to report:
        -- HEALTH_COLOR tints the bar rather than drawing a border, so there is no
        -- thickness behind it either. Inset and alpha are dropped to keep the
        -- four-item budget for the two flags, which are what people come to this
        -- row for.
        local function AggroSettingsSummary(d)
            if not d then return "" end
            local parts = {}
            local mode = d.aggroHighlightMode
            local word = aggroModes[mode]
            if word then parts[#parts + 1] = word end
            if mode == "NONE" then return Join(parts) end
            if mode ~= "HEALTH_COLOR" then
                local t = tonumber(d.aggroHighlightThickness)
                if t then parts[#parts + 1] = format("%dpx", math.floor(t)) end
            end
            if d.aggroOnlyTanking then parts[#parts + 1] = L["Only Show When Tanking"] end
            if d.aggroHideOnTanks then parts[#parts + 1] = L["Hide on Tanks"] end
            return Join(parts)
        end

        -- The one thing three swatches cannot say for themselves: whether they
        -- are being used at all. "Default" on the shipped profile, which takes
        -- the game's own threat palette.
        local function ThreatColorsSummary(d)
            if not d then return "" end
            if not d.aggroUseCustomColors then return L["Default"] end
            local parts = { L["Use Custom Colors"] }
            -- With Only Show When Tanking on, two of the three swatches are out
            -- of reach -- the highlight only ever appears at tanking threat --
            -- so the row names the one that is left.
            if d.aggroOnlyTanking then parts[#parts + 1] = L["Tanking (Red)"] end
            return Join(parts)
        end

        -- ========================================
        -- SELECTION HIGHLIGHT SECTION
        -- ========================================
        -- ★ Frame Level (all three groups). Highlights were pinned at 75/76/77 in
        -- Highlights.lua with no way to reach them. The old answer was "raise the
        -- element above the highlight", which only works in one direction and
        -- cannot reorder the three against each other. Defaults keep the pinned
        -- values, so nothing moves until someone drags this.
        local function BuildSelectionHighlightGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateDropdown(parent, L["Mode"], highlightModes, db, "selectionHighlightMode", function()
                tools2.refreshStates()
            end), 55)
            local selThick = group:AddWidget(GUI:CreateSlider(parent, L["Thickness"], 1, 10, 1, db, "selectionHighlightThickness", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
            selThick.hideOn = HideSelectionOptions
            local selInset = group:AddWidget(GUI:CreateSlider(parent, L["Inset"], -10, 10, 1, db, "selectionHighlightInset", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
            selInset.hideOn = HideSelectionOptions
            selInset.tooltip = TIP_HL_INSET
            local selLevel = group:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, db, "selectionHighlightFrameLevel", nil, function() DF:LightweightUpdateHighlight("selection") end, true)), 55)
            selLevel.hideOn = HideSelectionOptions
            local selAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0.1, 1.0, 0.05, db, "selectionHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("selection") end, true), 55)
            selAlpha.hideOn = HideSelectionOptions
            local selCol = group:AddWidget(GUI:CreateColorPicker(parent, L["Color"], db, "selectionHighlightColor", false, nil, function() DF:LightweightUpdateSelectionHighlightColor() end, true), 35)
            selCol.hideOn = HideSelectionOptions
        end

        -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
        -- Debuff Bar's placement: they act on cards in both columns, and
        -- "both" carries them through the one-column fold intact.
        Add(tools.SectionControls(self.child), 24, "both")
        -- Five of the six answer to the mode dropdown's hideOn, so the card
        -- is one dropdown tall until a mode is picked. Column 2, and the
        -- first card added, so the one-column fold still reads in the order
        -- the three sections had.
        Add(GUI:CreateHeader(self.child, L["Targeting"]), 40, 2)
        local band = OpenSection(L["Selection Highlight"], "highlights_selection", 2, SelectionSettingsSummary,
            nil, nil, BuildSelectionHighlightGroup)
        BuildSelectionHighlightGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- ========================================
        -- HOVER HIGHLIGHT SECTION
        -- ========================================
        local function BuildHoverHighlightGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateDropdown(parent, L["Mode"], highlightModes, db, "hoverHighlightMode", function()
                tools2.refreshStates()
            end), 55)
            local hoverThick = group:AddWidget(GUI:CreateSlider(parent, L["Thickness"], 1, 10, 1, db, "hoverHighlightThickness", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
            hoverThick.hideOn = HideHoverOptions
            local hoverInset = group:AddWidget(GUI:CreateSlider(parent, L["Inset"], -10, 10, 1, db, "hoverHighlightInset", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
            hoverInset.hideOn = HideHoverOptions
            hoverInset.tooltip = TIP_HL_INSET
            local hoverLevel = group:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, db, "hoverHighlightFrameLevel", nil, function() DF:LightweightUpdateHighlight("hover") end, true)), 55)
            hoverLevel.hideOn = HideHoverOptions
            local hoverAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0.1, 1.0, 0.05, db, "hoverHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("hover") end, true), 55)
            hoverAlpha.hideOn = HideHoverOptions
            local hoverCol = group:AddWidget(GUI:CreateColorPicker(parent, L["Color"], db, "hoverHighlightColor", false, nil, function() DF:LightweightUpdateHighlight("hover") end, true), 35)
            hoverCol.hideOn = HideHoverOptions
        end

        -- The same six and the same mode gate as Selection, under it.
        local band = OpenSection(L["Hover Highlight"], "highlights_hover", 2, HoverSettingsSummary,
            nil, nil, BuildHoverHighlightGroup)
        BuildHoverHighlightGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- ========================================
        -- AGGRO HIGHLIGHT SECTION
        -- ========================================
        -- Aggro Settings Group (col1)
        local function BuildAggroHighlightGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            group:AddWidget(GUI:CreateDropdown(parent, L["Mode"], aggroModes, db, "aggroHighlightMode", function()
                -- ⚠ THIS ONE MOVES THE OTHER ROW. Hidden takes the Threat Colors
                -- row out of the band entirely, exactly as it took the box out of
                -- the column -- and the state pass is what does it, in both
                -- layouts, through the same door.
                tools2.refreshStates()
                if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
            end), 55)
            local aggroOnlyTanking = group:AddWidget(GUI:CreateCheckbox(parent, L["Only Show When Tanking"], db, "aggroOnlyTanking", function()
                -- ⚠ AND SO DOES THIS ONE, one level down: with it on, two of the
                -- three swatches on the Threat Colors row are out of reach.
                tools2.refreshStates()
                if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
            end), 28)
            aggroOnlyTanking.hideOn = HideAggroModeNone
            -- These two sound like the same thing and are not: one is about YOUR
            -- role, the other about the unit's. Both say which, from their side.
            aggroOnlyTanking.tooltip = L["Only highlight threat while YOU are tanking. As a healer or damage dealer the highlight stays off entirely."]
            local aggroHideOnTanks = group:AddWidget(GUI:CreateCheckbox(parent, L["Hide on Tanks"], db, "aggroHideOnTanks", function()
                if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
            end), 28)
            aggroHideOnTanks.hideOn = HideAggroModeNone
            aggroHideOnTanks.tooltip = L["Skip the highlight on tanks in your group — they are supposed to have threat, so lighting them up is noise. Everyone else still shows."]
            local aggroThick = group:AddWidget(GUI:CreateSlider(parent, L["Thickness"], 1, 10, 1, db, "aggroHighlightThickness", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
            aggroThick.hideOn = HideAggroOptions
            local aggroInset = group:AddWidget(GUI:CreateSlider(parent, L["Inset"], -10, 10, 1, db, "aggroHighlightInset", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
            aggroInset.hideOn = HideAggroOptions
            aggroInset.tooltip = TIP_HL_INSET
            local aggroLevel = group:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, db, "aggroHighlightFrameLevel", nil, function() DF:LightweightUpdateHighlight("aggro") end, true)), 55)
            aggroLevel.hideOn = HideAggroOptions
            local aggroAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Alpha"], 0.1, 1.0, 0.05, db, "aggroHighlightAlpha", nil, function() DF:LightweightUpdateHighlight("aggro") end, true), 55)
            aggroAlpha.hideOn = HideAggroOptions
        end

        -- Threat Colors Group (col2)
        local function BuildThreatColorsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            local useCustomColors = group:AddWidget(GUI:CreateCheckbox(parent, L["Use Custom Colors"], db, "aggroUseCustomColors", function()
                tools2.refreshStates()
                if DF.UpdateAllHighlights then DF:UpdateAllHighlights() end
            end), 28)
            useCustomColors.hideOn = HideAggroModeNone
            local colorHighThreat = group:AddWidget(GUI:CreateColorPicker(parent, L["High Threat (Yellow)"], db, "aggroColorHighThreat", false, nil, function()
                DF:LightweightUpdateHighlight("aggro")
            end, true), 30)
            colorHighThreat.hideOn = HideNonTankingColors
            local colorHighestThreat = group:AddWidget(GUI:CreateColorPicker(parent, L["Highest Threat (Orange)"], db, "aggroColorHighestThreat", false, nil, function()
                DF:LightweightUpdateHighlight("aggro")
            end, true), 30)
            colorHighestThreat.hideOn = HideNonTankingColors
            local colorTanking = group:AddWidget(GUI:CreateColorPicker(parent, L["Tanking (Red)"], db, "aggroColorTanking", false, nil, function()
                DF:LightweightUpdateHighlight("aggro")
            end, true), 30)
            colorTanking.hideOn = HideCustomColorOptions
            group:AddWidget(GUI:CreateLabel(parent, L["Yellow=high, Orange=highest, Red=tanking."], 230), 25)
        end

        -- ☠ COLUMN 1, what the page DOES down the left: Aggro is the only
        -- highlight with behaviour of its own (Only Show When Tanking, Hide on
        -- Tanks). With Threat Colors under it that is also the balanced
        -- split -- two cards against Selection and Hover's two.
        Add(GUI:CreateHeader(self.child, L["Threat"]), 40, 1)
        local band = OpenSection(L["Aggro Highlight"], "highlights_aggro", 1, AggroSettingsSummary,
            nil, nil, BuildAggroHighlightGroup)
        BuildAggroHighlightGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- The card's gate covers both halves: with the aggro mode on Hidden no
        -- highlight uses this palette, so the whole card goes, header and body
        -- together. The legend under the swatches is prose, so it takes a row
        -- of its own.
        band = OpenSection(L["Threat Colors"], "highlights_threat", 1, ThreatColorsSummary,
            nil, HideAggroModeNone, BuildThreatColorsGroup)
        BuildThreatColorsGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        CloseSection(band)

        -- See Also links
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_dispel", label = L["Dispel Overlay"]},
        }), 30, "both")
    end)
    
    -- Auras > Dispel Overlay (moved from Indicators)
    local pageDispel = CreateSubTab("auras", "auras_dispel", L["Dispel Overlay"])
    BuildPage(pageDispel, function(self, db, Add, AddSpace, AddSyncPoint)
        -- Copy button at top
        Add(CreateCopyButton(self.child, {"dispel"}, L["Dispel Overlay"], "auras_dispel"), 25, 2)

        -- 12.1: the container factory owns the overlay unconditionally, so the
        -- Display/Icon/Border/Gradient groups are always live here.

        -- Every dispel-page callback funnels through here: the version bump
        -- breaks the 12.1 factory drive's fast-path latch, so structural changes
        -- (colour source, me/all, icon slots, bleed opt-in) rebuild their slot
        -- set and pure styling re-applies. Cheap out of combat; no-op impact
        -- pre-12.1 (the legacy path reads settings directly).
        local function ApplyDispelSettings()
            if DF.InvalidateAuraLayout then DF:InvalidateAuraLayout() end
            if DF.UpdateAllDispelOverlays then DF:UpdateAllDispelOverlays() end
        end

        local function InvalidateCurves()
            if DF.InvalidateDispelColorCurve then DF:InvalidateDispelColorCurve() end
            ApplyDispelSettings()
        end

        local function OnDispelTypeChanged()
            InvalidateCurves()
        end

        -- ===== THE PAGE'S CARDS ===========================================
        --   column 1   Settings -- whether the overlay exists at all (the PAGE
        --              gate, which stays in its body), which dispels light it
        --              up, where its colours come from, and Pulse Overlay.
        --              Gradient -- the overlay's own wash.
        --   column 2   Dispel Symbol, Border -- the two things drawn ON it.
        --
        -- ⚠ GRADIENT SITS IN COLUMN 1: it is the OVERLAY's wash, so it goes with
        -- the overlay's settings rather than with the symbol and ring drawn over
        -- it -- and as the tallest card it is also what balances the columns.
        --
        -- Show Dispel Symbol, Show Border and Show Gradient are the three cards'
        -- header ticks (their builders skip their in-body copy through
        -- hoistToggle). Those three cards also PIN; Settings decides what shows,
        -- so it does not.
        --
        -- Every group's widgets live in a `Build<X>Group(tools2)` taking
        -- { group, parent, refreshStates } and, where a toggle is hoisted,
        -- `hoistToggle`, so a pinned copy rebuilds the same controls --
        -- test_dispel_page_builders.lua pins each inventory.
        local tools = GUI:CreatePopoutPageTools(self)

        -- ONE CARD: the Debuff Bar's helper (tools.OpenSection) and its two
        -- opt-ins, which every card here takes.
        local function OpenSection(label, key, col, summaryFn, dimFn, hideFn, builder, toggle)
            return tools.OpenSection(Add, label, key, col, summaryFn, dimFn, hideFn, builder, toggle,
                { twoTrack = true, quietLabels = true })
        end
        -- ☠ THE BAND GOES IN AFTER ITS LAST CONTROL -- see tools.CloseSection.
        local function CloseSection(band)
            tools.CloseSection(Add, band)
        end
        -- What each of the three header ticks commits: what its in-body checkbox
        -- ran (the apply and a state pass, which re-greys the card's controls)
        -- plus a repaint of any pinned panel -- never a page rebuild.
        local function OnDispelCardTick()
            ApplyDispelSettings()
            self:RefreshStates()
            tools.ReflowMounted()
        end

        -- ===== THE PAGE'S VOCABULARY, AT PAGE SCOPE =======================
        -- The rows print the chosen value as their SUMMARY, and a summary is written
        -- OUTSIDE the group's builder -- so the word has to come out of the same
        -- table the dropdown offers, or a row could say one thing while the
        -- control behind it says another.
        --
        -- ⚠ AND ABOVE EVERY BUILDER. A builder is a CLOSURE, and a closure
        -- captures the upvalue that exists when it is created — so one declared
        -- above these lines would see nil rather than the table.
        -- Read as one phrase under the label, as on the Debuff Bar: "Dispellable By: Me".
        local dispelIndicatorOptions = { [1]= L["By Me"], [2]= L["All"] }
        local DISPEL_OVERLAY_TYPES = {
            { name = "Magic",   key = "dispelOverlayHideMagic",   desc = "Never light the overlay for Magic debuffs." },
            { name = "Curse",   key = "dispelOverlayHideCurse",   desc = "Never light the overlay for Curse debuffs." },
            { name = "Poison",  key = "dispelOverlayHidePoison",  desc = "Never light the overlay for Poison debuffs." },
            { name = "Disease", key = "dispelOverlayHideDisease", desc = "Never light the overlay for Disease debuffs." },
            { name = "Bleed",   key = "dispelOverlayHideBleed",   desc = "Never light the overlay for Bleed effects, including a Dwarf's own Stoneform bleeds." },
        }
        local iconPositions = {
            ["CENTER"]= L["Center"], ["TOP"]= L["Top"], ["BOTTOM"]= L["Bottom"],
            ["LEFT"]= L["Left"], ["RIGHT"]= L["Right"],
            ["TOPLEFT"]= L["Top Left"], ["TOPRIGHT"]= L["Top Right"],
            ["BOTTOMLEFT"]= L["Bottom Left"], ["BOTTOMRIGHT"]= L["Bottom Right"],
        }
        local gradientStyles = {
            ["FULL"]= L["Full Frame"], ["TOP"]= L["Top Edge"], ["BOTTOM"]= L["Bottom Edge"],
            ["LEFT"]= L["Left Edge"], ["RIGHT"]= L["Right Edge"], ["EDGE"]= L["Edge Glow (All Sides)"],
        }
        local blendModes = { ["ADD"]= L["Glow (ADD)"], ["BLEND"]= L["Solid (BLEND)"] }

        -- Boolean toggles GREY their dependent controls in place (addon-wide
        -- convention); hideOn stays for the feature/variant switches only.
        local DisableIfNoGradient = function(d) return d.dispelShowGradient == false end
        local DisableIfNoBorder = function(d) return d.dispelShowBorder == false end
        local DisableIfNoIcon = function(d) return d.dispelShowIcon == false end

        -- ☠ THE PAGE GATE IS A GREY, NOT A HIDE. Hiding a card's controls leaves
        -- its header over an EMPTY body, and a header tick on it that nothing
        -- under it answers. So the three looks cards' headers dim (dimOn) and
        -- their ticks grey, and every card body, and every pinned panel, greys
        -- whole (GreyWithPage) -- the convention stated just above: a boolean
        -- toggle greys in place.
        --
        -- ⚠ THE SETTINGS CARD'S OWN SWITCH IS THE EXCEPTION, for the Buff Bar's
        -- reason: it IS the gate, so greying it would leave no way to switch the
        -- overlay back on (keepEnabled, in its builder).
        local function DispelOffRow(d) return not (d or db).dispelOverlayEnabled end

        -- A card body or a pinned panel greys whole while the overlay is off.
        local function GreyWithPage(tools2)
            tools2.group.disableChildrenOn = DispelOffRow
        end

        -- The summary convention, once: at most four items, a fixed order,
        -- "\194\183" between them, WORDS localised and numbers raw, every read
        -- guarded because a profile mid-migration may be missing any of these
        -- keys.
        local function Join(parts) return table.concat(parts, " \194\183 ") end

        -- ===== ENABLE + SHARED SETTINGS (the first card) =====
        -- 12.1 unified overlay: ONE container-slot-driven system (Features/
        -- Dispel.lua factory path) covering normal AND private-aura dispels
        -- natively, switched by this single toggle.
        --
        -- ☠ ENABLE DISPEL OVERLAY STAYS IN THE BODY, as Show Buffs does on the
        -- Buff Bar: it is the PAGE gate, a fold is not a switch, and a header
        -- tick that greyed the whole page would surprise people.
        local function BuildDispelSettingsGroup(tools2)
            local group, parent = tools2.group, tools2.parent

            -- ⚠ NO PAGE REBUILD ON THIS SWITCH: the state pass is all the gate
            -- needs, and a rebuild retires the control being clicked and leaks
            -- the page.
            local enableCb = group:AddWidget(GUI:CreateCheckbox(parent, L["Enable Dispel Overlay"], db, "dispelOverlayEnabled", function()
                ApplyDispelSettings()
                tools2.refreshStates()
            end), 30)
            -- The gate's own switch stays live under the card's grey.
            enableCb.keepEnabled = true
            GreyWithPage(tools2)
            local dispelIndicatorDropdown = group:AddWidget(GUI:CreateDropdown(parent, L["Dispellable"], dispelIndicatorOptions, db, "dispelOverlayDispelType", function()
                OnDispelTypeChanged()
            end), 55)
            dispelIndicatorDropdown.tooltip = "|cffffffff" .. L["By Me"] .. ":|r " .. L["debuffs your current spec can remove."]
                .. "\n|cffffffff" .. L["All"] .. ":|r " .. L["every debuff that can be dispelled, including ones you can't remove."]

            -- Per-type Hide, the Debuff Bar's Dispel Type rows with only their Hide box:
            -- the mode above already decides what can light the overlay up.
            local typeHead = group:AddWidget(GUI:CreateShowHideHeader(parent, L["Dispel Type"], db,
                { showOffWhen = function() return true end }), 24)
            typeHead.fullRow = true
            for _, t in ipairs(DISPEL_OVERLAY_TYPES) do
                local row = group:AddWidget(GUI:CreateShowHideRow(parent, L[t.name], db, nil, t.key, OnDispelTypeChanged), 26)
                row.tooltip = L[t.desc]
                row.fullRow = true
            end
            -- Dispel-type colours come from the shared account palette on the Colors page
            -- (defaults = the game palette; Reset restores it). The overlay always follows
            -- it — no game-vs-custom toggle — so this is just a link to where you edit them.
            local overlayColorsLink = GUI:CreateDispelColorsPageLink(parent, 260)
            group:AddWidget(overlayColorsLink, (overlayColorsLink.layoutHeight or 16) + 2)
        end

        -- The one thing the row does not already say with its tick: WHICH dispels
        -- light the overlay up. Always printed — it is the row's whole substance,
        -- and the shipped profile's answer (All Dispellable) is the one people
        -- most often want to change.
        local function DispelSettingsSummary(d)
            if not d then return "" end
            local parts = {}
            local which = dispelIndicatorOptions[d.dispelOverlayDispelType]
            if which then parts[#parts + 1] = which end
            local hidden = 0
            for _, t in ipairs(DISPEL_OVERLAY_TYPES) do
                if d[t.key] then hidden = hidden + 1 end
            end
            if hidden > 0 then parts[#parts + 1] = format(L["Hiding %d"], hidden) end
            return Join(parts)
        end

        -- ☠ THE PAGE'S TWO BULK VERBS, ABOVE EVERYTHING, at col "both" -- the
        -- Debuff Bar's placement: they act on cards in both columns, and
        -- "both" carries them through the one-column fold intact.
        Add(tools.SectionControls(self.child), 24, "both")
        -- Holds the page gate, so it never greys and never dims; decides
        -- what SHOWS, so no pin.
        Add(GUI:CreateHeader(self.child, L["Content"]), 40, 1)
        local band = OpenSection(L["Settings"], "dispel_settings", 1, DispelSettingsSummary)
        BuildDispelSettingsGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
        })
        -- ⚠ PULSE OVERLAY LIVES IN THE SETTINGS CARD. It pulses the whole
        -- overlay -- the wash, the ring and the symbol together -- so it goes
        -- in the card about the whole overlay; the card's grey covers it.
        local pulse = band:AddWidget(GUI:CreateCheckbox(self.child, L["Pulse Overlay"], db, "dispelAnimate", ApplyDispelSettings), 30)
        pulse.fullRow = true
        CloseSection(band)

        -- ===== DISPEL SYMBOL (column 2) =====
        local function BuildDispelIconGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            GreyWithPage(tools2)

            -- Suppressed when the CARD's header carries this tick; still the
            -- group's own head in a pinned panel.
            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Dispel Symbol"], db, "dispelShowIcon", function()
                    ApplyDispelSettings()
                    tools2.refreshStates()
                end), 30)
            end
            local iconSize = group:AddWidget(GUI:CreateSlider(parent, L["Symbol Size"], 10, 40, 1, db, "dispelIconSize", function()
                ApplyDispelSettings()
            end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
            iconSize.disableOn = DisableIfNoIcon
            -- Commit callback only: each change re-tunes the row's container.
            local iconMax = group:AddWidget(GUI:CreateSlider(parent, L["Max Symbols"], 1, 5, 1, db, "dispelIconMax", function()
                ApplyDispelSettings()
            end), 55)
            iconMax.disableOn = DisableIfNoIcon
            iconMax.tooltip = L["How many dispellable debuffs get their own symbol. 1 shows the one the overlay is showing."]
            local iconAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Symbol Opacity"], 0.1, 1.0, 0.1, db, "dispelIconAlpha", function()
                InvalidateCurves()
            end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
            iconAlpha.disableOn = DisableIfNoIcon
            local iconPos = group:AddWidget(GUI:CreateDropdown(parent, L["Symbol Position"], iconPositions, db, "dispelIconPosition", function()
                ApplyDispelSettings()
            end), 55)
            iconPos.disableOn = DisableIfNoIcon
            local iconOffsetX = group:AddWidget(GUI:CreateSlider(parent, L["Offset X"], -50, 50, 1, db, "dispelIconOffsetX", function()
                ApplyDispelSettings()
            end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
            iconOffsetX.disableOn = DisableIfNoIcon
            local iconOffsetY = group:AddWidget(GUI:CreateSlider(parent, L["Offset Y"], -50, 50, 1, db, "dispelIconOffsetY", function()
                ApplyDispelSettings()
            end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
            iconOffsetY.disableOn = DisableIfNoIcon
        end

        -- Size in pixels, then where it sits, then the two things that are only
        -- worth naming while they are doing something — the offsets and the
        -- opacity (a row reading "1.00" on every default profile is noise, the
        -- Buff Bar's appearance rule).
        local function DispelIconSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.dispelIconSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            -- Only worth naming when it is doing something -- the offsets' rule.
            local max = tonumber(d.dispelIconMax) or 1
            if max > 1 then parts[#parts + 1] = format("x%d", max) end
            local pos = iconPositions[d.dispelIconPosition]
            if pos then parts[#parts + 1] = pos end
            local x, y = tonumber(d.dispelIconOffsetX) or 0, tonumber(d.dispelIconOffsetY) or 0
            if x ~= 0 or y ~= 0 then parts[#parts + 1] = format("%d, %d", x, y) end
            local a = tonumber(d.dispelIconAlpha)
            if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
            return Join(parts)
        end

        -- ☠ SHOW DISPEL SYMBOL IS THE HEADER'S TICK; the builder skips its
        -- own (hoistToggle). The key reads off only when explicitly false, and
        -- the tick greys with the page gate, as the header dims. A pin: it
        -- decides how the symbol LOOKS.
        Add(GUI:CreateHeader(self.child, L["Appearance"]), 40, 2)
        local band = OpenSection(L["Dispel Symbol"], "dispel_symbol", 2, DispelIconSummary, DispelOffRow, nil,
            BuildDispelIconGroup, {
                db = db, key = "dispelShowIcon", label = L["Show Dispel Symbol"],
                isOn = function(d) return d.dispelShowIcon ~= false end,
                disableOn = DispelOffRow,
                onChanged = OnDispelCardTick,
            })
        BuildDispelIconGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
            hoistToggle = true,
        })
        CloseSection(band)

        -- ===== BORDER (column 2) =====
        local function BuildDispelBorderGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            GreyWithPage(tools2)

            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Border"], db, "dispelShowBorder", function()
                    ApplyDispelSettings()
                    tools2.refreshStates()
                end), 30)
            end
            local borderSize = group:AddWidget(GUI:CreateSlider(parent, L["Border Thickness"], 1, 6, 1, db, "dispelBorderSize", function()
                ApplyDispelSettings()
            end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
            borderSize.disableOn = DisableIfNoBorder
            local borderInset = group:AddWidget(GUI:CreateSlider(parent, L["Border Inset"], -4, 4, 1, db, "dispelBorderInset", function()
                ApplyDispelSettings()
            end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
            borderInset.disableOn = DisableIfNoBorder
            borderInset.tooltip = L["How far inside the frame edge the dispel border sits. Negative values push it outward, ringing the frame rather than hugging it."]
            local borderAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Border Opacity"], 0.1, 1.0, 0.1, db, "dispelBorderAlpha", function()
                InvalidateCurves()
            end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
            borderAlpha.disableOn = DisableIfNoBorder
        end

        -- The sweep's border summary, for a hand-rolled border rather than the
        -- shared toolkit's: thickness in pixels, then the inset and the opacity
        -- only while they are doing something. There is no style word to print —
        -- this ring is always the one shape.
        local function DispelBorderSummary(d)
            if not d then return "" end
            local parts = {}
            local size = tonumber(d.dispelBorderSize)
            if size then parts[#parts + 1] = format("%dpx", math.floor(size)) end
            local inset = tonumber(d.dispelBorderInset)
            if inset and inset ~= 0 then parts[#parts + 1] = format("%s %d", L["Inset"], inset) end
            local a = tonumber(d.dispelBorderAlpha)
            if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
            return Join(parts)
        end

        -- ☠ SHOW BORDER IS THE HEADER'S TICK, Dispel Symbol's pattern: the
        -- builder skips its own, the tick greys with the page gate. A pin.
        local band = OpenSection(L["Border"], "dispel_border", 2, DispelBorderSummary, DispelOffRow, nil,
            BuildDispelBorderGroup, {
                db = db, key = "dispelShowBorder", label = L["Show Border"],
                isOn = function(d) return d.dispelShowBorder ~= false end,
                disableOn = DispelOffRow,
                onChanged = OnDispelCardTick,
            })
        BuildDispelBorderGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
            hoistToggle = true,
        })
        CloseSection(band)

        -- ===== GRADIENT (column 1, under Settings) =====
        -- This is the OVERLAY's own gradient (Full Frame / Top Edge / Edge
        -- Glow), so it belongs with the overlay's settings rather than with the
        -- border drawn over it.
        local function BuildDispelGradientGroup(tools2)
            local group, parent = tools2.group, tools2.parent
            GreyWithPage(tools2)

            if not tools2.hoistToggle then
                group:AddWidget(GUI:CreateCheckbox(parent, L["Show Gradient"], db, "dispelShowGradient", function()
                    ApplyDispelSettings()
                    tools2.refreshStates()
                end), 30)
            end
            local gradStyle = group:AddWidget(GUI:CreateDropdown(parent, L["Gradient Position"], gradientStyles, db, "dispelGradientStyle", function()
                tools2.refreshStates()
                ApplyDispelSettings()
            end), 55)
            gradStyle.disableOn = DisableIfNoGradient
            gradStyle.tooltip = L["Where the coloured wash sits on the frame. Full covers the whole bar; the edge options leave the middle clear so you can still read health and text underneath."]
            local onHealthCheck = group:AddWidget(GUI:CreateCheckbox(parent, L["Show On Current Health Only"], db, "dispelGradientOnCurrentHealth", function()
                ApplyDispelSettings()
            end), 30)
            onHealthCheck.hideOn = function(d) return d.dispelGradientStyle ~= "FULL" end
            onHealthCheck.disableOn = DisableIfNoGradient
            onHealthCheck.tooltip = L["Keeps the wash inside the filled part of the health bar, so it shrinks as the unit takes damage instead of covering the empty section too."]
            local gradSize = group:AddWidget(GUI:CreateSlider(parent, L["Gradient Size"], 0.1, 1.0, 0.1, db, "dispelGradientSize", function()
                ApplyDispelSettings()
            end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
            gradSize.disableOn = DisableIfNoGradient
            local gradAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Gradient Opacity"], 0.1, 1.0, 0.1, db, "dispelGradientAlpha", function()
                InvalidateCurves()
            end, function() DF:InvalidateDispelColorCurve(); DF:LightweightUpdateDispelOverlay() end, true), 55)

            -- ★ Frame Level. The dispel widget was the only element in the health band with
            -- no way to reach it, and it is the one that generated a day of "the wash is
            -- covering X" reports. Moves the ring, the icons and the FULL-FRAME wash together.
            -- ⚠ NOT hidden behind DisableIfNoGradient: it positions the ring and icons too,
            -- which exist with no gradient at all.
            local dispelLevel = group:AddWidget(GUI:SetFrameLevelTooltip(GUI:CreateSlider(parent, L["Frame Level"], 0, 100, 1, db, "dispelOverlayFrameLevel", function()
                ApplyDispelSettings()
            end, function() DF:LightweightUpdateDispelOverlay() end, true)), 55)
            dispelLevel.tooltip = L["Where the dispel display sits against the other frame elements. Raise it to draw over absorbs and heal prediction, lower it to sit beneath them. Show On Current Health Only ignores this and always stays below them."]
            gradAlpha.disableOn = DisableIfNoGradient
            local blendDropdown = group:AddWidget(GUI:CreateDropdown(parent, L["Blend Mode"], blendModes, db, "dispelGradientBlendMode", function()
                ApplyDispelSettings()
            end), 55)
            blendDropdown.disableOn = DisableIfNoGradient
            -- Darken effect lives at the bottom of the Gradient group (it only
            -- renders behind the gradient).
            local darkenCheck = group:AddWidget(GUI:CreateCheckbox(parent, L["Darken Behind Gradient"], db, "dispelGradientDarkenEnabled", function()
                tools2.refreshStates()
                ApplyDispelSettings()
            end), 30)
            darkenCheck.disableOn = DisableIfNoGradient
            darkenCheck.tooltip = L["Dims the frame underneath the wash so the dispel colour reads cleanly over a bright class colour or a busy health bar."]
            local darkenAlpha = group:AddWidget(GUI:CreateSlider(parent, L["Darken Amount"], 0.1, 1.0, 0.05, db, "dispelGradientDarkenAlpha", function()
                ApplyDispelSettings()
            end, function() DF:LightweightUpdateDispelOverlay() end, true), 55)
            -- HIDE when the dispel feature is off (variant); GREY when the boolean
            -- toggles it depends on are off (disabled-in-place).
            darkenAlpha.disableOn = function(d)
                return d.dispelShowGradient == false or not d.dispelGradientDarkenEnabled
            end
        end

        -- Where the wash sits, then the three things worth naming only while they
        -- are doing something: the opacity, the non-default blend, and the darken
        -- pass. Gradient Size is left out — it means nothing without the style
        -- word beside it, and the style word is already the first item.
        local function DispelGradientSummary(d)
            if not d then return "" end
            local parts = {}
            local style = gradientStyles[d.dispelGradientStyle]
            if style then parts[#parts + 1] = style end
            local a = tonumber(d.dispelGradientAlpha)
            if a and a < 1 then parts[#parts + 1] = format("%s %.2f", L["Alpha"], a) end
            if d.dispelGradientBlendMode == "ADD" then parts[#parts + 1] = L["Glow (ADD)"] end
            if d.dispelGradientDarkenEnabled then parts[#parts + 1] = L["Darken Behind Gradient"] end
            return Join(parts)
        end

        -- ☠ SHOW GRADIENT IS THE HEADER'S TICK, Dispel Symbol's pattern. A
        -- pin. Column 1, under Settings: see the essay at the top. It is
        -- added last, so the one-column fold reads Settings, Dispel Symbol,
        -- Border, Gradient -- the order the page always had.
        local band = OpenSection(L["Gradient"], "dispel_gradient", 2, DispelGradientSummary, DispelOffRow, nil,
            BuildDispelGradientGroup, {
                db = db, key = "dispelShowGradient", label = L["Show Gradient"],
                isOn = function(d) return d.dispelShowGradient ~= false end,
                disableOn = DispelOffRow,
                onChanged = OnDispelCardTick,
            })
        BuildDispelGradientGroup({
            group = band, parent = self.child,
            refreshStates = function() self:RefreshStates() end,
            hoistToggle = true,
        })
        CloseSection(band)

        -- See Also links
        AddSpace(GUI.Space.block, "both")
        Add(GUI:CreateSeeAlso(self.child, {
            {pageId = "auras_debuffs", label = L["Debuff Bar"]},
            {pageId = "indicators_highlights", label = L["Highlights"]},
        }), 30, "both")
    end)
    
    -- ========================================
    -- CATEGORY: Profiles
    -- ========================================
    -- The Profiles rail item's own sidebar: Manage, Spec & Character, Auto
    -- Layouts, Click Casting, Import / Export and Changed Settings. Built in
    -- GUI/Pages/Profiles.lua; created HERE so the category keeps its place in
    -- the page build order.
    if DF.SetupProfilesPages then
        DF:SetupProfilesPages(GUI, CreateCategory, CreateSubTab, BuildPage)
    end

    -- ========================================
    -- CATEGORY: Wizards
    -- ========================================
    -- Wizards category hidden for now (builder still in development)
    -- CreateCategory("wizards", "Wizards")

    -- Wizards > Setup Wizards (launcher/manager page) — disabled while category is hidden

    -- ========================================
    -- CATEGORY: Debug
    -- ========================================
    CreateCategory("debug", L["Debug"])

    -- Single page containing four collapsible sections in workflow order:
    -- Settings -> Categories -> Live Log -> Script Runner.
    -- All sections are collapsible and start expanded.
    local pageDebugConsole = CreateSubTab("debug", "debug_console", L["Console"])
    BuildPage(pageDebugConsole, function(self, db, Add, AddSpace, AddSyncPoint)

        -- Proxy for dropdown/slider keys (they don't support customGet/customSet)
        local debugProxy = setmetatable({}, {
            __index = function(_, k)
                return DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug[k]
            end,
            __newindex = function(_, k, v)
                if DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                    DandersFramesDB_v2.debug[k] = v
                end
            end,
        })

        -- Tracks the currently-open collapsible section so AddToSection() can
        -- automatically register subsequent widgets as its children.
        local currentSection = nil

        local function AddToSection(widget, height, col)
            Add(widget, height, col)
            if currentSection then
                currentSection:RegisterChild(widget)
            end
            return widget
        end

        -- ============================================================
        -- 1) SETTINGS SECTION
        -- ============================================================
        local settingsSection = Add(GUI:CreateCollapsibleSection(self.child, L["Settings"], true), 36, "both")
        currentSection = settingsSection

        AddToSection(GUI:CreateCheckbox(self.child, L["Enable Debug Logging"], nil, nil, function()
            if DF.DebugConsole then DF.DebugConsole:RefreshDisplay() end
        end, function()
            return DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.enabled or false
        end, function(val)
            if DF.DebugConsole then
                DF.DebugConsole:SetEnabled(val)
            elseif DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                DandersFramesDB_v2.debug.enabled = val
            end
        end), 28, "both")

        AddToSection(GUI:CreateCheckbox(self.child, L["Echo to Chat"], nil, nil, nil, function()
            return DandersFramesDB_v2 and DandersFramesDB_v2.debug and DandersFramesDB_v2.debug.chatEcho or false
        end, function(val)
            if DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                DandersFramesDB_v2.debug.chatEcho = val
            end
        end), 28, "both")

        local logLevelOptions = {
            ["INFO"]  = L["Info (All)"],
            ["WARN"]  = L["Warnings + Errors"],
            ["ERROR"] = L["Errors Only"],
        }
        local logLevelDrop = GUI:CreateDropdown(self.child, L["Minimum Log Level"], logLevelOptions, debugProxy, "logLevel", function()
            if DF.DebugConsole then DF.DebugConsole:RefreshDisplay() end
        end)
        -- ☠ The control DROPS lines below the chosen level now rather than hiding them, so
        -- it is a real buffer lever and the tooltip has to say so. Read as a view filter it
        -- would be set, a bug reproduced, and the missing detail treated as a bug of its own.
        logLevelDrop.tooltip = L["Lines below this level are not recorded at all, so raising it keeps a long capture readable and stops chatter evicting the part you need. Lowering it again only affects what is logged from that point on."]
        AddToSection(logLevelDrop, 55, 1)

        AddToSection(GUI:CreateSlider(self.child, L["Max Log Entries"], 100, 10000, 100, debugProxy, "maxLines", function()
            if DF.DebugConsole then
                DF.DebugConsole:PruneLog()
                DF.DebugConsole:RefreshDisplay()
            end
        end), 55, 2)

        -- The log lives in SavedVariables, so one left behind is re-read from disk at
        -- every login until something clears it. 0 = keep forever, for anyone chasing
        -- a bug that only shows up across several days.
        -- "0 = never" is in the LABEL because CreateSlider has no value-label map to
        -- put it in: parameter 9 is `lightweightUpdate` (a per-drag-tick FUNCTION) and
        -- 10 is `usePreviewMode` (the boolean that arms it). Passing a table into
        -- either would read as truthy and quietly change how the slider commits.
        AddToSection(GUI:CreateSlider(self.child, L["Clear Log After (Days, 0 = Never)"],
            0, 30, 1, debugProxy, "logMaxAgeDays"), 55, 1)

        AddSyncPoint()

        -- ============================================================
        -- 2) LOGGED CATEGORIES SECTION
        -- ============================================================
        local categoriesSection = Add(GUI:CreateCollapsibleSection(self.child, L["Logged Categories"], true), 36, "both")
        currentSection = categoriesSection

        AddToSection(GUI:CreateNote(self.child,
            L["Unchecked categories are not logged at all. Disable noisy categories before reproducing a bug to keep the buffer focused."],
            { width = 540 }), 36, "both")

        local function CollectAllCategories()
            local set = {}
            if DF.DebugConsole then
                for _, g in ipairs(DF.DebugConsole:GetCategoryGroups()) do
                    for _, cat in ipairs(g.categories) do
                        set[cat.key] = true
                    end
                end
                for cat in pairs(DF.DebugConsole:GetKnownCategories()) do
                    set[cat] = true
                end
            end
            return set
        end

        -- Track all created rows so All/None can refresh their visual state
        self.filterRows = {}
        local function RefreshAllRows()
            for _, row in pairs(self.filterRows) do
                if row.RefreshState then row:RefreshState() end
            end
            if DF.DebugConsole then DF.DebugConsole:RefreshDisplay() end
        end

        local function SetAllFilters(value)
            if not (DandersFramesDB_v2 and DandersFramesDB_v2.debug) then return end
            local filters = DandersFramesDB_v2.debug.filters
            for cat in pairs(CollectAllCategories()) do
                filters[cat] = value
            end
            RefreshAllRows()
        end

        local filterBtnRow = GUI:CreateButtonRow(self.child, {
            { label = L["All"],  width = 60, onClick = function() SetAllFilters(true) end },
            { label = L["None"], width = 60, onClick = function() SetAllFilters(false) end },
            -- The baseline: everything on except the per-frame firehoses. All/None
            -- are blunt; this is the state you actually want to start an
            -- investigation from, and the way back after turning things on.
            { label = L["Default"], width = 80,
              onClick = function()
                  if DF.DebugConsole and DF.DebugConsole:ApplyDefaultFilters() then
                      RefreshAllRows()
                  end
              end,
              tooltip = {
                  title = L["Default"],
                  lines = {
                      L["Turns every category on except the noisy ones, which log many lines per frame during layout and sorting."],
                      L["Enable those only while reproducing a layout or sorting bug."],
                  },
              } },
        }, { height = 22 })

        AddToSection(filterBtnRow, 28, "both")

        -- One colour for the category-group headings, passed to CreateLabel rather
        -- than baked into each string as a |c escape -- an escape inside a
        -- localised string is invisible to translators and easy to unbalance.
        local GROUP_HEADING_COLOR = { r = 0.93, g = 0.65, b = 0.37 }

        if DF.DebugConsole then
            local groups = DF.DebugConsole:GetCategoryGroups()
            for _, group in ipairs(groups) do
                local groupLabel = L[group.name] or group.name
                AddToSection(GUI:CreateLabel(self.child, groupLabel, 540, GROUP_HEADING_COLOR), 22, "both")
                for _, cat in ipairs(group.categories) do
                    -- The firehoses are marked in the row itself, so "why is this
                    -- one off?" is answered where the user is looking rather than
                    -- only in the Default button's tooltip. The row renders it as
                    -- the shared caution icon.
                    -- ⚠ L[cat.desc], mirroring L[group.name] a few lines up. The group
                    -- HEADINGS resolved through the locale table and the category
                    -- descriptions beneath them did not, so half this page translated
                    -- and half did not. CreateDebugCategoryRow does a plain SetText on
                    -- whatever it is handed, so the lookup belongs at this call site.
                    local row = GUI:CreateDebugCategoryRow(self.child, cat.key,
                        L[cat.desc] or cat.desc, 540, cat.noisy)
                    self.filterRows[cat.key] = row
                    AddToSection(row, 28, "both")
                end
            end

            -- Append auto-discovered categories that aren't in the registry
            local registered = DF.DebugConsole:GetRegisteredCategorySet()
            local known = DF.DebugConsole:GetKnownCategories()
            local extras = {}
            for cat in pairs(known) do
                if not registered[cat] then
                    tinsert(extras, cat)
                end
            end
            if #extras > 0 then
                table.sort(extras)
                AddToSection(GUI:CreateLabel(self.child, L["Discovered"], 540, GROUP_HEADING_COLOR), 22, "both")
                for _, cat in ipairs(extras) do
                    local row = GUI:CreateDebugCategoryRow(self.child, cat, nil, 540)
                    self.filterRows[cat] = row
                    AddToSection(row, 28, "both")
                end
            end
        end

        AddSyncPoint()

        -- ============================================================
        -- 3) LIVE LOG SECTION
        -- ============================================================
        local logSection = Add(GUI:CreateCollapsibleSection(self.child, L["Live Log"], true), 36, "both")
        currentSection = logSection

        -- Entry count label
        local entryCountLabel = GUI:CreateLabel(self.child, "", 540)
        local function UpdateEntryCount()
            local count = DF.DebugConsole and DF.DebugConsole:GetLogEntryCount() or 0
            -- No |c escape: CreateLabel's default colour is already the dim body tone.
            entryCountLabel:SetText(format(L["Log entries: %d"], count))
        end
        UpdateEntryCount()
        AddToSection(entryCountLabel, 20, "both")

        -- Action buttons row (Refresh / Clear Log / Copy to Clipboard)
        -- Was a hand-rolled dialog: ~35 lines building its own frame, backdrop,
        -- title, drag handlers and close button. ☠ It also called CreateFrame
        -- with the FIXED global name "DFDebugExportPopup" on every click, so a
        -- second export built a second frame over the same global and orphaned
        -- the first — a leak per click. The shared input popup is a singleton
        -- and is the same control the click-cast profile export already uses.
        --
        -- PAGED: one giant export string blanks the popup's content-sized text
        -- area exactly like the live box (region-size ceiling), so the console
        -- slices the export into parts and this pages through them. One part =
        -- the old single dialog; more parts add a "Next Part" button. The parts
        -- with a Next button are not readOnly (the popup only offers an accept
        -- button on editable inputs) — stray edits in a copy box are harmless.
        local function ShowExportChunk(chunks, i)
            local isLast = i >= #chunks
            DF:ShowPopupInput({
                title       = (#chunks > 1)
                    and format(L["Debug Log Export (part %d of %d)"], i, #chunks)
                    or L["Debug Log Export (Filtered)"],
                message     = L["Press Ctrl+A to select all, then Ctrl+C to copy"],
                text        = chunks[i],
                multiline   = true,
                readOnly    = isLast,
                acceptLabel = (not isLast) and L["Next Part"] or nil,
                onAccept    = (not isLast) and function()
                    -- The popup hides itself right AFTER this callback runs
                    -- (button onClick -> callback -> Hide), so reopening in the
                    -- same tick would be hidden immediately. Next tick.
                    C_Timer.After(0, function() ShowExportChunk(chunks, i + 1) end)
                end or nil,
                cancelLabel = L["Close"],
            })
        end
        local function CopyLogToClipboard()
            if not DF.DebugConsole then return end
            ShowExportChunk(DF.DebugConsole:GetExportChunks(), 1)
        end

        local actionRow = GUI:CreateButtonRow(self.child, {
            { label = L["Refresh"], width = 100, onClick = function()
                if DF.DebugConsole then
                    DF.DebugConsole:RefreshDisplay()
                    UpdateEntryCount()
                end
            end },
            { label = L["Clear Log"], width = 100, onClick = function()
                if DF.DebugConsole then
                    DF.DebugConsole:ClearLog()
                    UpdateEntryCount()
                end
            end },
            { label = L["Copy to Clipboard"], width = 140, onClick = CopyLogToClipboard },
        })

        AddToSection(actionRow, 32, "both")

        -- Full-width log viewer
        local logScrollContainer = GUI:CreateTextArea(self.child, {
            width = 540, height = 480,
            -- Typing in the log is not an edit — it just re-renders the buffer.
            onTextChanged = function(_, userInput)
                if userInput and DF.DebugConsole then
                    DF.DebugConsole:RefreshDisplay()
                end
            end,
        })
        local logEditBox = logScrollContainer.EditBox

        AddToSection(logScrollContainer, 485, "both")

        -- Register live EditBox with DebugConsole
        if DF.DebugConsole then
            DF.DebugConsole:SetLiveEditBox(logEditBox)
            DF.DebugConsole:RefreshDisplay()
            UpdateEntryCount()
        end

        -- Unregister on page hide
        self:SetScript("OnHide", function()
            if DF.DebugConsole then
                DF.DebugConsole:SetLiveEditBox(nil)
            end
        end)

        AddSyncPoint()

        -- ============================================================
        -- 4) SCRIPT RUNNER SECTION (developer-only utility, unrelated)
        -- ============================================================
        local scriptSection = Add(GUI:CreateCollapsibleSection(self.child, L["Script Runner"], true), 36, "both")
        currentSection = scriptSection

        local scriptScrollContainer = GUI:CreateTextArea(self.child, {
            width = 540, height = 120,
            text = (DandersFramesDB_v2 and DandersFramesDB_v2.debug
                    and DandersFramesDB_v2.debug.lastScript) or nil,
            onTextChanged = function(text, userInput)
                if userInput and DandersFramesDB_v2 and DandersFramesDB_v2.debug then
                    DandersFramesDB_v2.debug.lastScript = text
                end
            end,
        })
        local scriptEditBox = scriptScrollContainer.EditBox

        AddToSection(scriptScrollContainer, 125, "both")

        local scriptStatusLabel = GUI:CreateLabel(self.child, "", 540)
        AddToSection(scriptStatusLabel, 20, "both")

        -- Status is a TONE, not an ad-hoc colour: these were five hand-picked hex
        -- values that drifted from the info/caution/danger/success language every
        -- banner, note and tooltip in the GUI already speaks. ToneHex is the one
        -- source for the inline form.
        local function SetScriptStatus(text, tone)
            if tone then
                scriptStatusLabel:SetText("|c" .. GUI:ToneHex(tone) .. text .. "|r")
            else
                scriptStatusLabel:SetText(text)   -- default dim body tone
            end
        end

        AddToSection(GUI:CreateButton(self.child, L["Run Script"], 540, 26, function()
            local code = scriptEditBox:GetText()
            if not code or code == "" then
                SetScriptStatus(L["No script to run."])
                return
            end
            local fn, err = loadstring(code)
            if not fn then
                SetScriptStatus(format(L["Error: %s"], tostring(err)), "danger")
                DF:DebugError("SCRIPT", "Compile error: %s", tostring(err))
                return
            end
            local ok, result = pcall(fn)
            if ok then
                if result ~= nil then
                    SetScriptStatus(format(L["Result: %s"], tostring(result)), "info")
                else
                    SetScriptStatus(L["Script executed successfully."], "success")
                end
            else
                SetScriptStatus(format(L["Runtime: %s"], tostring(result)), "danger")
                DF:DebugError("SCRIPT", "Runtime error: %s", tostring(result))
            end
        end), 32, "both")

        currentSection = nil
    end)

end
