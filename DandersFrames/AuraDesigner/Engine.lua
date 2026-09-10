local addonName, DF = ...

-- ============================================================
-- AURA DESIGNER - ENGINE
-- Runtime loop that reads per-aura config, queries the adapter
-- for active auras, and dispatches to indicator renderers.
--
-- Called from the frame update cycle (UpdateAuras) when the
-- Aura Designer is enabled for a frame's mode.
-- ============================================================

local wipe = table.wipe

-- Hot-path globals, cached once: the cooldown watcher and its ticker read these on every
-- event and every tick, all fight long.
local C_Spell = C_Spell
local C_Timer = C_Timer
local issecretvalue = issecretvalue



DF.AuraDesigner = DF.AuraDesigner or {}

local Engine = {}
DF.AuraDesigner.Engine = Engine

local Adapter   -- Set during init
local SoundEngine -- Set during init (AuraDesigner/SoundEngine.lua)

-- ============================================================
-- SPEC RESOLUTION
-- ============================================================

function Engine:ResolveSpec(adDB)
    if adDB.spec == "auto" then
        if not Adapter then
            Adapter = DF.AuraDesigner.Adapter
        end
        if not Adapter then return nil end
        return Adapter:GetPlayerSpec()
    end
    return adDB.spec
end

-- ============================================================
-- HIDE ALL INDICATORS
-- Called when Aura Designer is disabled or unit doesn't exist.
-- ============================================================

function Engine:ClearFrame(frame)
    -- Tear down any native-factory AD containers (12.1 path) hung off this frame.
    if DF.AuraDesigner.Factory then
        DF.AuraDesigner.Factory:ClearFrame(frame)
    end
    -- Stop sound engine when AD is disabled
    if not SoundEngine then
        SoundEngine = DF.AuraDesigner.SoundEngine
    end
    if SoundEngine then
        SoundEngine:StopAll()
    end
    -- Clear active instance IDs so buff bar dedup doesn't stale-filter
    if frame.dfAD_activeInstanceIDs then
        wipe(frame.dfAD_activeInstanceIDs)
    end
end

-- ============================================================
-- FORCE REFRESH ALL AD-ENABLED FRAMES
-- Re-runs UpdateFrame on every visible AD frame so changed
-- global defaults (fonts, sizes, etc.) take effect immediately.
-- ============================================================

function Engine:ForceRefreshAllFrames()
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    local function TryUpdate(frame)
        if not frame then return end
        if DF:IsAuraDesignerEnabled(frame) then
            -- Live 12.1 path: re-sync the factory containers immediately so an
            -- editor change applies now, not one aura event late.
            if frame:IsVisible() and Factory and DF.UseFactoryForAD
                and DF:UseFactoryForAD(frame, DF:GetFrameDB(frame)) then
                Factory:SyncFrame(frame)
            end
        else
            -- AD is OFF for this frame's mode (toggled off, or a profile swap to
            -- an AD-off profile) -- tear down any leftover indicators so they
            -- don't linger on screen until the next /reload.
            Engine:ClearFrame(frame)
        end
    end

    if DF.IteratePartyFrames then
        DF:IteratePartyFrames(TryUpdate)
    end
    if DF.IterateRaidFrames then
        DF:IterateRaidFrames(TryUpdate)
    end
    -- ☠ THROUGH THE SHARED WALKER, NOT A HAND-ROLLED HEADER LOOP — this walked
    -- PinnedFrames.headers only, so an Aura Designer edit never reached a pinned BOSS
    -- frame, and neither did the AD-off teardown. (Audit 2026-08-17.)
    if DF.IteratePinnedFrames then
        DF.IteratePinnedFrames(TryUpdate)
    end

    -- The native factory buff row derives its Aura-Designer dedup set from the AD
    -- config at build time, so an AD config change must re-drive the buff row for
    -- the derived exclusion to follow (sig-gated, cheap when unchanged).
    if DF.InvalidateAuraLayout then
        DF:InvalidateAuraLayout()
    end

    -- Refresh the test previews too when the editor is used with test mode open.
    if (DF.testMode or DF.raidTestMode) and DF.UpdateAllTestAuraDesigner then
        DF:UpdateAllTestAuraDesigner()
        -- ⚠ NO Indicator Info rebuild here, deliberately. One was added at this line
        -- and it fixed only the editor's own actions: the designer PRESET bar changes
        -- every indicator on screen without going through this function at all, so the
        -- marks stayed stale exactly where they were first reported. The rebuild now
        -- hangs off Factory:SyncFrame / Factory:ClearFrame — the mutation itself, which
        -- every path reaches by definition. Do not re-add a caller-side hook here; it
        -- would double-fire the one below and still not cover anything new.
    end
end

-- ============================================================
-- POWER INFUSION HELPER -- THE GATE
-- ============================================================
-- Decides WHEN the helper's marks go dark, and broadcasts the edge. The settings panel and the
-- recipe live on the Options side (AuraDesigner/UI/Cards.lua); this is the resident half, and
-- it must work with the settings panel never having been opened.
--
-- The gate itself lives in AuraContainer (recordCandidateFilters). This file only decides
-- WHEN it is shut and broadcasts the edge. That split is the point: config is never touched,
-- so a rebuild produces something already gated rather than something we correct.
--
-- Superseded design, for the record: a per-container map swap plus a re-assert after every
-- rebuild. It worked, and it was a race we would have had to keep winning against every
-- rebuild path added later. Watched failing 2026-08-23 -- clobber recorded in combat,
-- rendered at combat end.
-- ============================================================

-- The spell whose cooldown drives the gate. Power Infusion, and the panel offers no way to
-- change it: "which spell hides this" is a question about plumbing rather than about the
-- feature, and nobody asked for it. Left as a value rather than a constant because the
-- mechanism is not priest-specific -- any "I have a strong thing ready" cooldown works -- so a
-- picker could return without the engine changing.
local PI_SPELL_ID = 10060       -- Power Infusion

local pihGateOpen = true        -- true = show (gate spell ready), false = dark (on cooldown)

-- ☠ MANUAL OVERRIDE. The slash driver and the watcher both write this state; without a notion
-- of who is driving, the watcher stamps over a hand-set gate on the very next global cooldown
-- -- which reads exactly like an external overwrite and is not one. Cost us a round.
-- nil = watcher drives; true/false = held by hand until `/df debug pi auto`.
local pihManual = nil

-- ★★★ SHOW IN COMBAT ONLY (2026-09-10), an option Krathe asked for.
-- ⚠ FORWARD-DECLARED. pihShouldShow reads pihGateEnabled, declared a couple of hundred lines
-- below, while pihSet -- which is above it -- has to call it. Same idiom as pihSyncWatcher.
local pihCombatOnly = false
local pihShouldShow

-- The helper sound choice, written by the settings panel through PIH_SetSound and restored on
-- login by PIH_ApplySaved. ⚠ SILENT UNTIL CHOSEN -- nil registers nothing, because an
-- audio cue nobody asked for is the fastest way to have a feature switched off wholesale.
local pihSoundCfg = nil

-- ☠ NOT PARTY-ONLY, AND IT WAS. This read hardcoded the party preset while the settings panel
-- writes to whichever mode the Aura Designer is editing -- so a helper configured in RAID mode
-- had its gate, its role exclusions and its sound silently dropped on every load, while its
-- indicators carried on rendering from the raid pool. It would have read as the gate simply
-- not working, with nothing on screen to explain it. Caught in review, before anyone met it.
--
-- ⚠ FIRST PRESET THAT HAS A HELPER WINS, PARTY FIRST. The gate is ONE switch for the whole
-- addon, so two presets carrying different helper settings is an ambiguity no read can resolve
-- -- taking the first is a choice, not a derivation. Party first because that is where the
-- feature is used. If this ever needs to differ per mode, the gate has to become per-mode
-- first, and that is a bigger change than a better read.
local PIH_MODES = { "party", "raid" }

-- ☠ "DOES A HELPER EXIST" IS ONE QUESTION, ANSWERED FROM THE MARKS -- the same
-- derivation the panel uses, so the two halves cannot disagree. An earlier version tested for
-- the recorded list id instead, and the two definitions drifted apart in exactly one state:
-- untick every signal without pressing Remove, and the panel correctly reported the helper
-- gone while the engine kept its event registrations and its armed sound, because the list id
-- outlives the signals (the spell list is still there; nothing points at it). Field-found.
--
-- ⚠ The marks ARE the record -- effects, placed instances and icon groups all carry
-- pihSignal -- so scanning for one is the definition, not a proxy for it. Cheap: it runs on
-- settings changes and login, never in a frame update.
local function pihHasHelper(adDB)
    if type(adDB) ~= "table" then return false end
    for _, auraCfg in pairs(adDB.otherAuras or {}) do
        if type(auraCfg) == "table" then
            for _, v in pairs(auraCfg) do
                if type(v) == "table" and v.pihSignal then return true end
            end
            for _, inst in ipairs(auraCfg.indicators or {}) do
                if type(inst) == "table" and inst.pihSignal then return true end
            end
        end
    end
    for _, g in ipairs(adDB.otherLayoutGroups or {}) do
        if type(g) == "table" and g.pihSignal then return true end
    end
    return false
end

-- ⚠ FIRST PRESET THAT HAS A HELPER WINS, PARTY FIRST. The gate is ONE switch for the
-- whole addon, so two presets carrying different helper settings is an ambiguity no read can
-- resolve -- taking the first is a choice, not a derivation. Party first because that is where
-- the feature is used. A preset whose settings table survived a Remove no longer shadows one
-- that actually has a helper, because the marks decide.
-- ☠☠ THE *LIVE* DESIGNER, NOT THE MODE BASE (2026-09-10). This read GetModeBaseAuraDesigner,
-- which is the EDITOR's variant -- Presets.lua says so directly: "GetMode*Designer ... the
-- ACTIVE designer a mode resolves to right now ... Used by LIVE consumers (SoundEngine,
-- migrations) that must match what's on screen. The EDITOR uses the GetModeBase* variants".
-- The helper is a live consumer and was reading the editor's answer.
--
-- ☠ WHAT IT COST, from Krathe's raid: a raid auto-layout can point its own AD PRESET at
-- something other than the mode base -- his 21-30 layout uses a "Flex 21-30" preset. The
-- frames render from THAT (DF:ResolveAuraDesigner honours the overlay) and it holds no
-- helper, so nothing draws; this read carried on finding the helper in the BASE preset and
-- happily armed the gate, the roles and THE SOUND for a preset that is not on screen.
-- ⇒ "I could hear the sound trigger but did not see the border or PI icon at all" is this,
-- and so is a status readout that reports a healthy helper while nothing renders. The
-- feature could not diagnose itself because its two halves were reading different presets.
-- ⚠ IT DOES NOT MAKE HIS HELPER APPEAR -- the records genuinely are not in that preset,
-- which is a choice the preset system offers and the user has to make. What it fixes is
-- the engine agreeing with the screen: no helper there means silent, ungated, and a
-- readout that SAYS so.
local function pihSettings()
    if not DF.GetModeAuraDesigner then return nil end
    for _, mode in ipairs(PIH_MODES) do
        local adDB = DF:GetModeAuraDesigner(mode)
        local s = adDB and adDB.pihelper
        if s and pihHasHelper(adDB) then return s end
    end
    return nil
end

-- Resolve the helper filter's spell map, for the sound registrations.
-- ☠ THIS RESOLVED THE WRONG FILTER ONCE, AND THE SOUND COULD THEREFORE NEVER PLAY.
-- It looked the list up BY NAME, and the name it used belonged to a throwaway test filter that
-- only existed if a developer had built it by hand. The recipe builds "Power Infusion Helper".
-- On every real install the lookup missed, the map came back nil, `helperSoundMapFor` bailed on
-- its first line, and every registration was skipped: zero sounds, always. ⚠ AND THE TEST
-- FOR IT PASSED -- it asked whether the SETTING survived a reload, which it did perfectly. A
-- test that never asks whether a sound comes out cannot tell a working feature from an inert
-- one. Caught in review, not in the field.
--
-- ⚠ BY ID, NOT BY NAME, and there is no name fallback any more. A custom filter can be
-- renamed in the Filter Designer, so the recipe records the id it created and this reads that.
local function pihResolvedMap()
    local R = DF.FilterRegistry
    if not (R and R.ResolveSelection) then return nil end
    local s = pihSettings()
    local id = s and s.cooldownFilterID
    if not (id and R.GetCustomFilter and R:GetCustomFilter(id)) then return nil end
    local res = R:ResolveSelection({ customs = { [id] = true } })
    return (res and res.kind == "include") and res.map or nil
end

-- Arm or disarm helper sound on every AD frame. Mirrors the visual gate: closed = silent.
-- ☠ SKIPS THE RESOLVE WHEN NOTHING COULD PLAY. With no sound chosen -- the shipped
-- default -- arming would resolve the whole spell list and walk every frame just to register
-- nothing. The DISARM pass still walks: teardown is the thing that actually silences.
-- The last arm pass, remembered for the status readout: how many registrations, over how
-- many frames, and when. ☠ A field failure ("no sound in the dungeon after a reload")
-- arrived with a readout that showed every SETTING healthy -- because the readout could not
-- see the per-frame wiring. These three numbers are what would have named it in one look.
local pihLastArmCount, pihLastArmFrames, pihLastArmAt = 0, 0, nil

local function pihSoundsArmed(armed)
    local Factory = DF.AuraDesigner and DF.AuraDesigner.Factory
    if not (Factory and Factory.SetHelperSoundsArmed) then return 0 end
    if armed and not pihSoundCfg then armed = false end
    local map = armed and pihResolvedMap() or nil
    local n, frames = 0, 0
    local function visit(frame)
        if frame and DF:IsAuraDesignerEnabled(frame) then
            frames = frames + 1
            local got = Factory:SetHelperSoundsArmed(frame, armed, map, pihSoundCfg)
            n = n + (got or 0)
        end
    end
    if DF.IteratePartyFrames  then DF:IteratePartyFrames(visit)  end
    if DF.IterateRaidFrames   then DF:IterateRaidFrames(visit)   end
    if DF.IteratePinnedFrames then DF.IteratePinnedFrames(visit) end
    pihLastArmCount, pihLastArmFrames = n, frames
    pihLastArmAt = date and date("%H:%M:%S") or "?"
    return n
end

-- Flip the gate. ☠ No early return on an unchanged state: our variable records INTENT, never
-- what any container is carrying, and the two are allowed to differ -- a rebuild restores the
-- live map in config while this still reads "dark". An early return made "/df debug pi off" decline
-- to act while the border was lit.
-- ☠☠ NOTHING FIRES WHEN A COOLDOWN QUIETLY EXPIRES. `SPELL_UPDATE_COOLDOWN` fires when
-- cooldowns START or change, not when one runs out on its own. Watched 2026-08-23: the gate
-- shut on a Dispersion cast, Dispersion's cooldown ended, and the border stayed dark until the
-- player cast something unrelated -- which fired the event as a side effect of the GCD.
--
-- Earlier tests hid this because the player was casting throughout, so the reopen always had
-- an event to ride on. It is the exact mirror of the GCD bug above: that was an event firing
-- when it should not matter, this is no event firing when it should.
--
-- So while the gate is DARK we poll. Only while dark, one boolean read per tick, and it stops
-- itself the moment the spell is ready -- so the cost is a couple of reads per second during a
-- cooldown and nothing at all the rest of the time.
-- Reads FLAGS ONLY. `isActive` is plain in combat and `isOnGCD` is guarded below; startTime /
-- duration / modRate all seal and none of them is touched, so nothing here compares a secret.
--
-- ☠☠ BUT `isActive` CANNOT TELL A REAL COOLDOWN FROM THE GLOBAL COOLDOWN. Casting ANY spell
-- makes EVERY spell report active for the duration of the GCD. Watched 2026-08-23: with the
-- gate pointed at Dispersion, casting Power Word: Shield made Dispersion read unready and the
-- gate shut. With Power Infusion the flaw is masked -- its cooldown is minutes long, so the
-- GCD flicker hides inside a real cooldown -- but it is still there: every spell the player
-- casts would blink the helper off for a moment.
--
-- ⇒ SO THIS IS ONLY EVER USED FOR "IS IT READY AGAIN", NEVER FOR "HAS IT JUST GONE DOWN".
-- Opening on `not isActive` is safe: the GCD lapsing and the real cooldown ending both mean
-- genuinely ready. Shutting is driven by the CAST instead -- see the watcher below.
-- ⭐⭐ A REAL COOLDOWN IS `isActive` AND NOT `isOnGCD`. Danders' answer to our GCD finding
-- (2026-08-23), and it replaces the workaround rather than sitting beside it: `isActive` alone
-- reads true for EVERY spell while the global cooldown runs, so the helper blinked off whenever
-- the player cast anything. `isOnGCD` is the sibling flag that says which of the two it is, and
-- both stay readable in combat while startTime / duration / modRate seal.
--
-- Shape follows DandersCDM's `ClassifyCooldown` (Display/CooldownBar.lua), which credits
-- Ellesmere's hooks for the same discriminator -- "no duration/magnitude math, only the clean
-- bool flags". Danders pasted that function on 2026-08-24, so the branches below are checked
-- against the original rather than against a paraphrase of it.
--
-- ⚠ WE DELIBERATELY DO NOT COPY ITS DURATION FALLBACK, and the reason is our own rule. CDM
-- compares `duration` against the GCD when `isOnGCD` is missing, because CDM also serves clients
-- whose info table genuinely lacks the field. Ours never will, and Danders checked the history:
-- nobody has ever observed `isOnGCD` sealing. That branch would be one we could never exercise.
-- The `issecretvalue` GUARD stays -- a compare on a sealed value throws, so it prevents a hard
-- error rather than being dead weight -- but when it fires we resolve from charges instead.
--
-- ⚠ CHARGES, and this is where the old fail-safe hurt. With the flags readable a charge spell
-- needs no special handling: a charge in hand reads not-active (or active + isOnGCD during the
-- global), and zero charges reads active and NOT on GCD, which is exactly "genuinely on
-- cooldown". With the flags UNREADABLE, "assume on cooldown" would darken the helper while the
-- player still held a charge and could infuse right now. `currentCharges` stays non-secret and
-- answers precisely that, so it is what the unknown case resolves from.
--
-- ⚠ Latent, not live. The shipped panel has no gate-spell picker, so the gate spell is always
-- Power Infusion, which has no charges. This is correctness for a capability that exists
-- underneath, not a fix for anything a user can hit today.
--
-- ⚠ Charges also fire their own event -- SPELL_UPDATE_COOLDOWN does not cover a charge coming
-- back. SPELL_UPDATE_CHARGES is registered with the watcher below for that reason.
local function pihReadCharges(spellID)
    if not (C_Spell and C_Spell.GetSpellCharges) then return nil end
    local c = C_Spell.GetSpellCharges(spellID)
    if not c then return nil end
    local cur = c.currentCharges
    -- Secret check MUST precede everything else: even a nil test on a secret throws on 12.1.
    if issecretvalue and issecretvalue(cur) then return nil end
    if type(cur) ~= "number" then return nil end
    return cur
end

local function pihReadReady()
    local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(PI_SPELL_ID)
    if not info then return true end
    if info.isActive ~= true then return true end

    local gcd = info.isOnGCD
    local sealed = issecretvalue and issecretvalue(gcd)
    -- ☠ SEALED TEST FIRST. `and` evaluates left to right, so writing this as
    -- `gcd ~= nil and not sealed` runs the nil comparison BEFORE the guard that exists to
    -- prevent it -- and a comparison against a sealed value throws. The guard was decorative
    -- in exactly the branch it was written for. pihReadCharges gets the order right and says
    -- why; caught in Danders' PR review.
    if not sealed and gcd ~= nil then
        -- Active AND merely the global cooldown = not a real cooldown = still ready.
        return gcd == true
    end

    -- No usable flag. A charge in hand means usable, whatever the spell cooldown claims.
    local charges = pihReadCharges(PI_SPELL_ID)
    if charges ~= nil then return charges >= 1 end

    -- Nothing readable either way. Treat as on cooldown: the failure we can afford is a helper
    -- that hides when it did not have to, not one that marks people we cannot infuse.
    return false
end

local pihReadyTicker

local function pihStopTicker()
    if pihReadyTicker then pihReadyTicker:Cancel(); pihReadyTicker = nil end
end

-- ★★★ THE FEATURE SWITCH, AS DISTINCT FROM THE COOLDOWN GATE (2026-09-09).
--
-- ☠☠ "DISABLE" USED TO MEAN "DELETE THE RECORDS". The helper had no enabled flag of its own
-- -- its existence WAS its records -- so the panel's tick implemented off as a wholesale
-- delete with a stash to fake reversibility. Every bug in that area had one root: a switch
-- pretending to be a switch while actually being a delete. Krathe, 2026-09-09: "when I disable
-- the PI tracker, it seems to remove my border effect I added", then "it should function like
-- the rest of AD" -- and the rest of AD writes ONE BOOLEAN (modeDB.auraDesignerEnabled) and
-- deletes nothing.
-- ⇒ The records stay exactly where they are. This is what makes them not draw, and it costs
-- one file-local, because the gate's own machinery already means "dark, and nothing will
-- open it".
--
-- ⚠ TWO SWITCHES, THREE STATES, AND THEY DO NOT COLLAPSE INTO ONE:
--     enabled = false                -> forced DARK  (the feature is off)
--     enabled, gateEnabled = false   -> forced OPEN  (never hide, not even on cooldown)
--     enabled, gateEnabled           -> the watcher drives
-- Reusing pihGateEnabled for both would make "off" and "always show" the same field.
local pihEnabled = true

local function pihSet(dark)
    pihGateOpen = not dark
    local n = 0
    if DF.AuraContainer and DF.AuraContainer.SetHelperGate then
        n = DF.AuraContainer.SetHelperGate(dark)
    end
    -- Sound rides the SAME edge as the visuals. It is not a container, so the gate cannot
    -- reach it -- without this it would keep announcing while we are silent.
    pihSoundsArmed(not dark)

    if dark then
        -- ⚠ Never under a manual hold: the tick body refuses to act while held (below),
        -- so a ticker started here would idle at 2 Hz for the rest of the session. Handing
        -- control back re-enters through pihSet and starts it then, if still dark.
        -- ⚠ ...AND NEVER WHILE THE FEATURE IS OFF. This ticker exists to REOPEN the gate when
        -- the cooldown clears, which for a disabled helper would undo the very thing the
        -- switch just did -- and poll at 2 Hz forever to do it.
        if not pihReadyTicker and pihManual == nil and pihEnabled
            and C_Timer and C_Timer.NewTicker then
            pihReadyTicker = C_Timer.NewTicker(0.5, function()
                -- Held by hand: never fight a gate the user is holding themselves.
                if pihManual ~= nil then return end
                -- Re-asked every tick, not only at start: the switch can move under us.
                if not pihEnabled then return end
                -- ⚠ THE COMPOSITE, not the spell alone: with "combat only" on, a cooldown
                -- clearing out of combat must NOT reopen the gate.
                if pihShouldShow() then
                    pihStopTicker()
                    if not pihGateOpen then pihSet(false) end
                end
            end)
        end
    else
        pihStopTicker()
    end
    return n
end

-- ☠ THE GATE CAN BE SWITCHED OFF ENTIRELY. "Hide while Power Infusion is on cooldown" is the
-- whole point of the helper, so it defaults on -- but someone who just wants to see burst
-- windows can turn it off, and then the helper never hides.
--
-- Off means FORCE OPEN and stay there: the watcher stops driving, so a cooldown starting or
-- ending changes nothing. Not "ignore the events" -- the gate is genuinely open, which is what
-- the setting says.
local pihGateEnabled = true

-- ★★ EVERY GLOBAL CONDITION, IN ONE ANSWER. As against helperUnitExcluded, which is the
-- per-UNIT half (role, and the named-player list) -- this is the half that is true of the
-- whole helper at once.
--
-- ☠ THE COMBAT TEST COMES FIRST AND IGNORES THE COOLDOWN GATE. "Show in combat only" and
-- "show while Power Infusion is on cooldown" are independent: someone who has switched the
-- cooldown gate OFF still means it when they say combat only, and folding this in after the
-- `not pihGateEnabled` early-return would have silently ignored them.
--
-- ☠☠ `inCombat` IS AN ARGUMENT BECAUSE OF AN EVENT RACE. DF.playerInCombat is the house
-- source and is written by Core.lua from PLAYER_REGEN_DISABLED / _ENABLED -- the same two
-- events this file now watches. Handler order between two frames is not defined, so reading
-- the flag from inside our own handler can see the value from BEFORE the transition and
-- resolve the gate backwards. The regen branch passes the truth the event itself carries;
-- every other caller omits it and gets the flag, which by then has settled.
-- ⚠ NEVER InCombatLockdown() -- that is the addon-restriction state, not the player's
-- combat state, and this addon has a standing rule about the difference.
function pihShouldShow(inCombat)
    if inCombat == nil then inCombat = DF.playerInCombat and true or false end
    if pihCombatOnly and not inCombat then return false end
    if not pihGateEnabled then return true end   -- cooldown gate off: never hide for THAT
    return pihReadReady()
end

-- Stored on the helper; pushed by PIH_ApplySaved and by the panel through this setter.
function Engine:PIH_SetCombatOnly(on)
    pihCombatOnly = on and true or false
    if not pihEnabled then return pihCombatOnly end   -- the feature switch outranks it
    pihManual = nil
    pihSet(not pihShouldShow())
    return pihCombatOnly
end

-- The FEATURE switch. Off is a forced dark that nothing reopens; on hands control back to
-- whichever of the two remaining states applies. See pihEnabled for the three-state table.
-- ⚠ CALLED AFTER PIH_SetGateEnabled, always: turning the feature back on has to resume from
-- the gate's own setting, so that setting must already be in place. PIH_ApplySaved orders
-- them; so does the panel's P.PIH_Apply.
function Engine:PIH_SetEnabled(on)
    pihEnabled = on and true or false
    -- A manual hold is a debugging affordance and must not survive either transition -- the
    -- same reasoning as the gate switch below.
    pihManual = nil
    if not pihEnabled then
        pihSet(true)                    -- dark, and nothing will open it
    elseif not pihGateEnabled then
        pihSet(false)                   -- the gate is switched off: never hide
    else
        pihSet(not pihShouldShow())     -- resume from every live condition
    end
    return pihEnabled
end

function Engine:PIH_SetGateEnabled(on)
    pihGateEnabled = on and true or false
    -- ⚠ THE FEATURE SWITCH OUTRANKS THIS ONE. With the helper off, neither branch below may
    -- run: "never hide" and "resume from the cooldown" both mean SHOW, and there is nothing
    -- to show. Without this, ticking the cooldown option while disabled lit the helper up.
    if not pihEnabled then return pihGateEnabled end
    -- ⚠ BOTH ARMS GO THROUGH pihShouldShow NOW. Switching the cooldown gate off no longer
    -- means "open" outright -- "combat only" may still be holding it shut, and forcing it
    -- open here would have ignored that setting entirely.
    if not pihGateEnabled then
        pihManual = nil
        pihSet(not pihShouldShow())
    else
        -- ⚠ Re-enabling releases a manual hold too. Without this, "gate enabled" and
        -- "held by hand" could both be true at once, with the watcher suspended and nothing
        -- on screen to say so.
        pihManual = nil
        pihSet(not pihShouldShow())   -- resume from every live condition
    end
    return pihGateEnabled
end

-- ☠ THE SOUND CHOICE HAS TO BE APPLIED, NOT MERELY STORED. An early version kept it
-- only in the file-local above, which dies on reload, and the login path never armed it -- a
-- player who picked a sound and logged out had picked nothing.
-- The panel saves the key with the helper's other settings; this is the one place that turns a
-- saved key into live registrations, and it is called from both the panel and the login path.
-- An empty or missing key means SILENT: no sound was ever a default, and an audio cue nobody
-- asked for is the fastest way to have a feature switched off wholesale.
function Engine:PIH_SetSound(lsmKey)
    pihSoundCfg = (type(lsmKey) == "string" and lsmKey ~= "") and { soundLSMKey = lsmKey } or nil
    -- Armed only while the gate is open: sound is not a container, so nothing the gate does to
    -- the visuals reaches it -- it needs its own edge action or it announces windows during the
    -- exact minutes the helper is meant to be silent.
    return pihSoundsArmed(pihGateOpen and pihSoundCfg ~= nil)
end

-- ☠ THE RESIDENT HALF READS THE SAVED SETTINGS ITSELF. The panel that writes them lives in
-- the load-on-demand options addon, so anything that only applied when the panel was open
-- would silently not apply to a player who never opens their settings -- which is most of
-- them, most of the time. §1b's whole point.
--
-- Reads whichever preset actually has a helper installed, party first (see pihSettings); a
-- party/raid split sharing one preset shares the helper, which is the addon's model for
-- every other effect.
--
-- ☠ ALSO THE RESET PATH. Called on login AND after a profile switch, and the new
-- profile may have no helper -- in which case everything the old one pushed must come back
-- out: roles, the gate, and above all the sound registrations, which would otherwise keep
-- playing for a helper that no longer exists anywhere.
local pihSyncWatcher   -- defined beside the watcher below; registration follows helper existence
-- ★★★ NOT A PRIEST: THE WHOLE FEATURE IS A NO-OP (2026-09-10).
--
-- ☠ REPORTED FROM THE ALPHA: helper borders and icons rendering for NON-PRIESTS. There was
-- no class gate on this side at all -- only the Options UI checked (DF.IsPIHelperAvailable
-- hides the page, Rows.lua omits the pool tab), and hiding the controls does nothing about
-- records that already exist. A profile shared across an account, an imported preset, or a
-- priest's own profile opened on an alt all carry the marked records, and the factory renders
-- what the pool holds -- it has never asked whose class it is.
--
-- ⚠ DARK, NOT "NO HELPER". The `if not s` branch below opens the gate ("nothing is left to
-- hide"), which is right when the pool genuinely holds nothing and exactly wrong here: a
-- non-priest with marked records needs them SUPPRESSED, and an open gate renders them. The
-- two cases look alike and mean opposite things, which is why this is its own branch rather
-- than another condition on that one.
--
-- ⚠ PIH_SetEnabled(false) IS THE LEVER, not a new one. It is the feature switch: forced dark
-- that nothing reopens, the readiness ticker refused, the manual hold released, and sound
-- disarmed through pihSet. Everything a class gate needs, already written and already tested.
-- ⚠ THE RECORDS ARE NOT TOUCHED. Deleting a priest's work because their alt logged in would
-- be destroying data over a display question -- and the same profile on the priest must come
-- back intact. Suppression only.
--
-- ⚠ READ AT CALL TIME, NOT AT LOAD. UnitClass("player") is not dependable before login, and
-- this function runs on login and on every profile switch, which is exactly when it is.
-- A character's class cannot change, so there is nothing to re-check afterwards.
local function pihIsPriest()
    local _, class = UnitClass("player")
    return class == "PRIEST"
end
Engine.PIH_IsPriest = pihIsPriest

function Engine:PIH_ApplySaved()
    if not pihIsPriest() then
        if DF.AuraContainer then
            if DF.AuraContainer.SetHelperExcludedRoles then
                DF.AuraContainer.SetHelperExcludedRoles(nil)
            end
            if DF.AuraContainer.SetHelperAllowedPlayers then
                DF.AuraContainer.SetHelperAllowedPlayers(nil)
            end
        end
        -- Cleared BEFORE the switch, so nothing can re-arm behind it: PIH_SetEnabled goes
        -- through pihSet, which disarms against whatever cfg is standing at that moment.
        Engine:PIH_SetSound(nil)
        Engine:PIH_SetEnabled(false)
        if pihSyncWatcher then pihSyncWatcher() end
        return false
    end
    local s = pihSettings()
    if not s then
        if DF.AuraContainer and DF.AuraContainer.SetHelperExcludedRoles then
            DF.AuraContainer.SetHelperExcludedRoles(nil)
        end
        -- ☠ AND THE ALLOWLIST, ON THE RESET PATH AS MUCH AS THE APPLY ONE. A named-player list
        -- left pushed after a switch to a profile with no helper would go on narrowing a
        -- feature that is not there -- and would then narrow the NEXT helper the user builds,
        -- from a list they wrote somewhere else entirely. Same reasoning as the roles above,
        -- and the same reason this whole branch exists.
        if DF.AuraContainer and DF.AuraContainer.SetHelperAllowedPlayers then
            DF.AuraContainer.SetHelperAllowedPlayers(nil)
        end
        pihManual = nil
        pihGateEnabled = true
        pihCombatOnly = false      -- a stale hold would outlive the profile that set it
        pihEnabled = true          -- no helper here; the switch has nothing to suppress
        Engine:PIH_SetSound(nil)   -- tears down every live registration
        pihSet(false)              -- open; nothing is left to hide
        if pihSyncWatcher then pihSyncWatcher() end
        return false
    end

    if DF.AuraContainer and DF.AuraContainer.SetHelperExcludedRoles then
        local any = false
        for _ in pairs(s.roles or {}) do any = true break end
        DF.AuraContainer.SetHelperExcludedRoles(any and s.roles or nil)
    end
    -- ★ THE NAMED-PLAYER ALLOWLIST, stored as an ARRAY (the picker's order of entry) and
    -- pushed as a MAP (the container asks "is this unit in it", once per unit per push).
    -- ⚠ AN EMPTY LIST IS nil, NOT AN EMPTY MAP. The container reads a present map as "these
    -- players and nobody else", so an empty one would silence the helper completely -- for a
    -- user who had added two names and removed them again, which is exactly the moment they
    -- would expect it to go back to normal rather than break.
    if DF.AuraContainer and DF.AuraContainer.SetHelperAllowedPlayers then
        local map
        for _, fullName in ipairs(s.players or {}) do
            if type(fullName) == "string" and fullName ~= "" then
                map = map or {}
                map[fullName] = true
            end
        end
        DF.AuraContainer.SetHelperAllowedPlayers(map)
    end
    -- ⚠ BEFORE THE GATE SETTERS, because both resolve through pihShouldShow, which reads
    -- this. Loading it afterwards would settle the gate from the OLD value and leave it
    -- wrong until the next transition -- the same ordering the sound line below records.
    pihCombatOnly = s.combatOnly == true
    Engine:PIH_SetGateEnabled(s.gateEnabled ~= false)
    -- ⚠ AFTER THE GATE: turning the feature on resumes from the gate's setting, so the gate
    -- has to be in place first (PIH_SetEnabled says the same from its side).
    -- ⚠ DEFAULTS TRUE FOR A PROFILE THAT PREDATES THE FLAG. `enabled` did not exist before
    -- 2026-09-09, and every such profile that has helper records had a WORKING helper -- so
    -- absent must read as on, or the fix for a destructive switch would silently switch
    -- everyone off. A profile with no records shows nothing either way.
    Engine:PIH_SetEnabled(s.enabled ~= false)
    -- After the gate, never before: SetSound arms against the gate's current state, so calling
    -- it first would arm against the state we are about to leave.
    Engine:PIH_SetSound(s.soundOn and s.soundLSMKey or nil)
    if pihSyncWatcher then pihSyncWatcher() end
    return true
end

-- Public seam for the panel: create, remove and apply all change whether a helper exists,
-- which is what decides the watcher's registrations.
function Engine:PIH_SyncWatcher() if pihSyncWatcher then pihSyncWatcher() end end


-- ☠ SHUT ON THE CAST, OPEN ON THE COOLDOWN CLEARING.
-- §4b originally specified "read isActive, edge-detect, done" and explicitly REJECTED watching
-- the cast, on the grounds that predicting a cooldown's LENGTH would be a second source of
-- truth that could drift. That reasoning still stands and is not what this does: nothing here
-- predicts a duration. The cast is used only as the unambiguous "it has just gone down"
-- signal, and the cooldown itself still decides when it comes back.
--
-- Rejected alternative: only shut if the spell still reads unready after ~1.6s (longer than
-- any GCD). Simpler, no new events -- and it breaks under sustained casting, where the GCD
-- never lapses and therefore looks exactly like a real cooldown.
local pihWatcher = CreateFrame("Frame")
pihWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")

-- ☠ THE OTHER EVENTS ONLY EXIST WHILE A HELPER DOES. SPELL_UPDATE_COOLDOWN fires on
-- every global cooldown for every class, and the panel is priest-gated -- a permanent
-- registration would cost most users a cooldown read per GCD in service of a feature they
-- cannot even add. Login stays permanent: it is what discovers whether a helper exists.
--
-- ⚠ CHARGES FIRE THEIR OWN EVENT. A charge returning is a spell becoming usable again,
-- and SPELL_UPDATE_COOLDOWN does not fire for it -- so a charge-based gate spell would come
-- back ready with nothing to tell us. Power Infusion has no charges today; registered because
-- the capability underneath is not priest-specific and the failure would be silent. Danders'
-- own cooldown addon registers the pair for the same reason.
--
-- ⚠ UNIT_SPELLCAST_SUCCEEDED is filtered at the C level (RegisterUnitEvent): only the
-- player's own cast can shut the gate, and unfiltered this event is every cast by every
-- tracked unit -- party, raid, pets -- all discarded one line into the handler.
--
-- GROUP_ROSTER_UPDATE is for SOUND: registrations are per unit and are otherwise only made
-- on gate edges, so anyone who joined after the last edge got no cue -- and the player's own
-- no-register guard went stale when sorting moved them to another token.
-- ⚠ BOTH COMBAT TRANSITIONS, and the EXIT half is the one that goes missing: this addon has
-- a standing note that a gate keyed on combat needs a refresh on entering AND on leaving,
-- and that leaving is the half people forget. Registered unconditionally rather than with
-- the setting -- the watcher only exists for a priest who has a helper at all, and two more
-- events on that frame is cheaper than a re-registration dance every time the tick moves.
local PIH_WATCH_EVENTS = { "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_CHARGES",
                           "UNIT_SPELLCAST_SUCCEEDED", "GROUP_ROSTER_UPDATE",
                           "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }
local pihWatching = false
pihSyncWatcher = function()
    -- ⚠ AND NOT FOR A NON-PRIEST, whatever the pool holds. PIH_ApplySaved already forces
    -- the feature off for them, so the watcher's own tick would early-out anyway -- but a
    -- registration that can only ever decline to act is five events on every alt of every
    -- priest who shares a profile, for a feature they cannot enable. Same fact, one test.
    local want = pihIsPriest() and pihSettings() ~= nil
    -- The container's own backstop frame follows the same fact, from the same test -- one
    -- definition of "a helper exists" driving both registrations. Called unconditionally
    -- (it is idempotent) so it self-corrects even when our own state has not moved.
    if DF.AuraContainer and DF.AuraContainer.SetHelperGateActive then
        DF.AuraContainer.SetHelperGateActive(want)
    end
    if want == pihWatching then return end
    pihWatching = want
    for _, ev in ipairs(PIH_WATCH_EVENTS) do
        if not want then
            pihWatcher:UnregisterEvent(ev)
        elseif ev == "UNIT_SPELLCAST_SUCCEEDED" and pihWatcher.RegisterUnitEvent then
            pihWatcher:RegisterUnitEvent(ev, "player")
        else
            pihWatcher:RegisterEvent(ev)
        end
    end
end

local pihRosterPending = false
pihWatcher:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "GROUP_ROSTER_UPDATE" then
        -- Debounced: forming a group fires this in bursts, and one re-arm covers them all.
        -- Deliberately OUTSIDE the gate-enabled/manual guards below: gate off means the
        -- helper always shows, and its sound still has to reach a late joiner.
        if pihSoundCfg and not pihRosterPending and C_Timer and C_Timer.After then
            pihRosterPending = true
            C_Timer.After(0.5, function()
                pihRosterPending = false
                pihSoundsArmed(pihGateOpen)
            end)
        end
        return
    end
    -- ★★ COMBAT TRANSITIONS. Ahead of the cooldown guards below, deliberately: those
    -- return early when the cooldown gate is switched off, and "combat only" is a separate
    -- setting that still has to act for that user.
    -- ☠ THE EVENT CARRIES THE TRUTH, and we pass it rather than reading DF.playerInCombat.
    -- Core.lua writes that flag from these same two events, and handler order between two
    -- frames is undefined -- so reading it here can see the value from BEFORE the
    -- transition and resolve the gate backwards. See pihShouldShow.
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        if not pihCombatOnly then return end   -- nothing here concerns anyone else
        if not pihEnabled or pihManual ~= nil then return end
        local want = pihShouldShow(event == "PLAYER_REGEN_DISABLED")
        if want ~= pihGateOpen then
            local n = pihSet(not want)
            DF:Debug("AURADESIGNER", "PIH gate -> %s on combat %s (%d container%s)",
                want and "OPEN" or "DARK",
                event == "PLAYER_REGEN_DISABLED" and "start" or "end",
                n, n == 1 and "" or "s")
        end
        return
    end

    if event ~= "PLAYER_ENTERING_WORLD" then
        if not pihEnabled then return end       -- feature off: the gate stays dark
        if not pihGateEnabled then return end   -- switched off: nothing shuts or opens it
        if pihManual ~= nil then return end
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- The only thing that shuts the gate. Our own cast of the gate spell, nothing else.
        if unit ~= "player" or spellID ~= PI_SPELL_ID then return end
        if not pihGateOpen then return end
        local n = pihSet(true)
        DF:Debug("AURADESIGNER", "PIH gate -> DARK on cast (%d container%s)", n, n == 1 and "" or "s")
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        Engine:PIH_ApplySaved()   -- saved settings, before any gate decision
        -- ☠ RE-CHECK THE SWITCH AFTER APPLYING, because at login the file-locals
        -- still hold their initialisers until ApplySaved loads the saved values. Without
        -- this, a saved "don't hide" was overridden by the cooldown read below: reload
        -- mid-cooldown and the helper hid anyway -- the exact opposite of the setting --
        -- for the rest of that cooldown.
        -- ⚠ pihEnabled joins the same re-check, and for the identical reason: ApplySaved has
        -- just loaded it, and the cooldown read below would otherwise light up a helper the
        -- user has switched off.
        -- ⚠ pihGateEnabled IS NO LONGER AN EARLY-OUT HERE. It used to be, because it was the
        -- only condition below; pihShouldShow now folds it in alongside "combat only", and
        -- returning early would skip the combat test for anyone with the cooldown gate off.
        if not pihEnabled or pihManual ~= nil then return end
        -- ☠ THE ONE PLACE isActive MAY SHUT THE GATE. On load we never saw the cast, so a
        -- reload mid-cooldown would otherwise leave the helper showing for the rest of it.
        -- Safe here specifically because nothing is being cast at this instant, so a true
        -- reading is a real cooldown rather than a GCD.
        local want = pihShouldShow()
        if want ~= pihGateOpen then pihSet(not want) end
        return
    end

    -- SPELL_UPDATE_COOLDOWN / SPELL_UPDATE_CHARGES: OPENING ONLY, still.
    -- ⚠ pihReadReady can now tell a real cooldown from a global one, so this COULD shut the gate
    -- as well. It deliberately does not. The cast event shuts on an unambiguous fact -- the
    -- player pressed it -- where shutting from here would mean trusting a flag read at whatever
    -- instant a chatty event happened to fire. One shut path, one open path, and the read that
    -- was wrong before is only used where a wrong answer cannot shut anything.
    -- ⚠ Cheapest test first: this branch only ever OPENS the gate, so with the gate
    -- already open there is nothing to do and no reason to pay for a cooldown read -- and
    -- this event fires on every global cooldown, all fight long.
    if pihGateOpen then return end
    -- ⚠ THE COMPOSITE. A cleared cooldown is not enough on its own when the helper is set
    -- to combat only and we are standing in a city.
    if not pihShouldShow() then return end
    local n = pihSet(false)
    DF:Debug("AURADESIGNER", "PIH gate -> OPEN, cooldown cleared (%d container%s)",
        n, n == 1 and "" or "s")
end)

-- === DIAGNOSTIC COMMAND ===
-- WHAT SURVIVED, AND WHY. This began as the feature's entire control surface -- twelve
-- subcommands driving a throwaway filter, a settable gate spell, role lists, sound and a
-- rebuild probe. Every one of those is either in the settings panel now or was scaffolding for
-- a feature that did not exist yet, so it went with the rest of the test rig.
--
-- Three states stayed, and they are not scaffolding: forcing the gate open or dark is the only
-- way to watch the helper's behaviour without sitting out a real Power Infusion cooldown -- and
-- Power Infusion needs a friendly target, so without this EVERY check of the gate would need a
-- second player in the group.
--
-- Registered through DF:RegisterDebugSlash rather than as a loose SLASH_ global, so it lists
-- itself in the debug registry beside every other diagnostic instead of being reachable only by
-- already knowing it exists.
--
-- THE COMMAND IS "/df debug pi". "/dfpi" below is the REGISTRY SPELLING, not a working bind:
-- RegisterDebugSlash routes a /df-prefixed alias to DebugSlashBySub and deliberately creates no
-- SLASH_ global, because the addon retired the one-word /dfsomething forms -- they filled the
-- global slash namespace to document a spelling nobody needed twice. Same shape as /dfarena and
-- /dfpinned. During development this WAS a bare /dfpi; anyone whose fingers remember that needs
-- the long form now.
DF:RegisterDebugSlash("DFPI", "Power Infusion Helper: force the gate open or dark, or show its state", false, "/dfpi")
SlashCmdList["DFPI"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()

    if msg == "off" or msg == "dark" then
        pihManual = false
        DF:Out("PI Helper", "gate DARK (held by hand)")
            :Field("containers re-pushed", pihSet(true))
            :Line("watcher suspended -- \"/df debug pi auto\" hands it back", "neutral")
        return
    end

    if msg == "on" or msg == "open" then
        pihManual = true
        DF:Out("PI Helper", "gate OPEN (held by hand)")
            :Field("containers re-pushed", pihSet(false))
            :Line("watcher suspended -- \"/df debug pi auto\" hands it back", "neutral")
        return
    end

    if msg == "auto" then
        pihManual = nil
        local ready = pihReadReady()
        DF:Out("PI Helper", "watcher resumed")
            :Field("gate", ready and "OPEN" or "DARK")
            :Field("containers re-pushed", pihSet(not ready))
        return
    end

    -- INTENT AND REALITY ARE PRINTED SEPARATELY, ON PURPOSE. Our variable records what the gate
    -- was last TOLD; the chokepoint records what containers are actually being handed. They are
    -- allowed to differ -- a rebuild restores the live map in config while the gate still reads
    -- "dark" -- and a readout that collapsed them into one line would hide exactly the
    -- disagreement it exists to show.
    local dark = false
    if DF.AuraContainer and DF.AuraContainer.GetHelperGate then
        dark = DF.AuraContainer.GetHelperGate()
    end
    local out = DF:Out("PI Helper", "status")
    out:Field("gate intends", pihGateOpen and "OPEN" or "DARK")
        :Field("chokepoint says", dark and "DARK" or "OPEN",
               dark == (not pihGateOpen) and "good" or "bad")
        :Field("gate enabled", tostring(pihGateEnabled))
        :Field("gate spell", ("%d (%s)"):format(PI_SPELL_ID,
               tostring((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(PI_SPELL_ID)) or "?")))
        :Field("gate spell ready", tostring(pihReadReady()))
        :Field("driven by", pihManual ~= nil and "HAND (watcher suspended)" or "watcher")
        :Field("sound", pihSoundCfg and (pihSoundCfg.soundLSMKey or "custom") or "silent (none chosen)")
        -- RESOLVE IT HERE. A LibSharedMedia pack may register a sound whose NAME contains an
        -- inline texture escape -- SharedMedia_Causese ships one carrying the Power Infusion
        -- icon. Picked from the dropdown it works perfectly: the key is stored verbatim and
        -- resolved to a file path long before anything reaches the sound API, so the escape
        -- never travels. Printing the resolved path is how you tell a bad choice from a silent
        -- one without playing it.
        :Field("sound resolves to", (function()
            if not pihSoundCfg then return "n/a" end
            local p = DF.GetSoundPath and DF:GetSoundPath(pihSoundCfg.soundLSMKey)
            return tostring(p or pihSoundCfg.soundFile or "NOTHING -- will not play")
        end)(), (function()
            if not pihSoundCfg then return "neutral" end
            local p = DF.GetSoundPath and DF:GetSoundPath(pihSoundCfg.soundLSMKey)
            return (p or pihSoundCfg.soundFile) and "good" or "bad"
        end)())
        :Field("roles excluded", (function()
            local r = DF.AuraContainer and DF.AuraContainer.GetHelperExcludedRoles
                and DF.AuraContainer.GetHelperExcludedRoles()
            if not r then return "nobody" end
            local t = {}; for k in pairs(r) do t[#t + 1] = k end; table.sort(t)
            return table.concat(t, ", ")
        end)())
        :Field("watching events", pihWatching and "yes" or "no (no helper installed)")
        -- The per-frame wiring, which no setting above can show. Registrations counted at the
        -- LAST arm pass (armed on zero frames = the login-ordering failure); containers
        -- counted LIVE off both registries.
        :Field("sound registrations", ("%d over %d frame%s%s"):format(
            pihLastArmCount, pihLastArmFrames, pihLastArmFrames == 1 and "" or "s",
            pihLastArmAt and (" (last armed " .. pihLastArmAt .. ")") or ""),
            -- ⚠ Only a fault WITH A GROUP: solo there is no unit to register on (we
            -- never register the player's own), so zero is the right answer and a red zero
            -- would teach the reader to ignore the line that matters.
            (pihSoundCfg and pihGateOpen and pihLastArmCount == 0
             and GetNumGroupMembers and GetNumGroupMembers() > 1) and "bad" or "neutral")
        -- ★★ THE PLACED SLOTS, WHICH NOTHING ABOVE COULD SEE. Krathe, over four reports:
        -- the border cleared and the icon did not; the sound played and nothing drew; the
        -- group and border drew and the icon did not. Every one of those is a slot whose
        -- LAST PUSH disagrees with the gate, and no field here could show it.
        -- ⚠ READ THIS AGAINST "gate intends" ABOVE:
        --   gate OPEN + dark 0 + pending 0   -> the slots agree; look elsewhere.
        --   gate OPEN + pending > 0          -> a push deferred to PLAYER_REGEN_ENABLED and
        --                                       not yet drained. Power Infusion is pressed IN
        --                                       COMBAT, so this is the expected shape of the
        --                                       "icon lags the border" report.
        --   gate OPEN + dark > 0             -> a per-UNIT exclusion (role, or the named
        --                                       player list), not the gate.
        :Field("helper slots", (function()
            local AC = DF.AuraContainer
            if not (AC and AC.GetHelperSlotStatus) then return "n/a" end
            local total, dark, pending, parked = AC.GetHelperSlotStatus()
            if total == 0 then return "none (no placed helper effect)" end
            return ("%d total, %d would go dark, %d push deferred, %d parked")
                :format(total, dark, pending, parked)
        end)(), (function()
            local AC = DF.AuraContainer
            if not (AC and AC.GetHelperSlotStatus) then return "neutral" end
            local _, _, pending = AC.GetHelperSlotStatus()
            -- A deferral outstanding while the gate is open IS the fault, so it is marked as
            -- one -- that is the whole point of adding this line.
            return (pending > 0 and pihGateOpen) and "bad" or "neutral"
        end)())
        :Field("gated containers live", (function()
            local AC = DF.AuraContainer
            local n = 0
            for h in pairs((AC and AC._handles) or {}) do
                if h.config and h.config.dfGate then n = n + 1 end
            end
            for h in pairs((AC and AC._slotHandles) or {}) do
                if h.config and h.config.dfGate then n = n + 1 end
            end
            return n
        end)())
    -- ☠ The chain is REASSEMBLED here on purpose: a conditional line built as
    -- `cond and text or nil` fed a nil straight into the printer's concatenation and the
    -- readout crashed in the field -- precisely when test mode was OFF, which no dev session
    -- ever ran it in. A diagnostic must not have a state in which it throws.
    local out2 = out
    if DF.testMode or DF.raidTestMode then
        -- applyGroupTuning refuses in test mode, so a gate edge redraws nothing there --
        -- indistinguishable from a broken gate unless the readout says so.
        out2 = out2:Line("test mode is ON: gate changes do not redraw test previews", "neutral")
    end
    out2:Hints("/df debug pi off", "/df debug pi on", "/df debug pi auto")
end
