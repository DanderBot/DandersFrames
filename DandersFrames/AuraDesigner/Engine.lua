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
local function pihSettings()
    if not DF.GetModeBaseAuraDesigner then return nil end
    for _, mode in ipairs(PIH_MODES) do
        local adDB = DF:GetModeBaseAuraDesigner(mode)
        local s = adDB and adDB.pihelper
        -- ☠ A pihelper TABLE ALONE IS NOT A HELPER. Remove leaves the table behind on
        -- purpose (behaviour survives a remove), so a preset that ONCE had a helper would
        -- otherwise shadow the preset that has one now -- settings configured in raid mode
        -- reverting to party leftovers on every reload. The recorded list id only exists
        -- while a helper is actually installed, so it is the installed test.
        if s and s.cooldownFilterID then return s end
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
    if gcd ~= nil and not sealed then
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
        if not pihReadyTicker and pihManual == nil and C_Timer and C_Timer.NewTicker then
            pihReadyTicker = C_Timer.NewTicker(0.5, function()
                -- Held by hand: never fight a gate the user is holding themselves.
                if pihManual ~= nil then return end
                if pihReadReady() then
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

function Engine:PIH_SetGateEnabled(on)
    pihGateEnabled = on and true or false
    if not pihGateEnabled then
        pihManual = nil
        pihSet(false)          -- open, and nothing will shut it
    else
        -- ⚠ Re-enabling releases a manual hold too. Without this, "gate enabled" and
        -- "held by hand" could both be true at once, with the watcher suspended and nothing
        -- on screen to say so.
        pihManual = nil
        local ready = pihReadReady()
        pihSet(not ready)      -- resume from the real cooldown state
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
function Engine:PIH_ApplySaved()
    local s = pihSettings()
    if not s then
        if DF.AuraContainer and DF.AuraContainer.SetHelperExcludedRoles then
            DF.AuraContainer.SetHelperExcludedRoles(nil)
        end
        pihManual = nil
        pihGateEnabled = true
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
    Engine:PIH_SetGateEnabled(s.gateEnabled ~= false)
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
local PIH_WATCH_EVENTS = { "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_CHARGES",
                           "UNIT_SPELLCAST_SUCCEEDED", "GROUP_ROSTER_UPDATE" }
local pihWatching = false
pihSyncWatcher = function()
    local want = pihSettings() ~= nil
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
    if event ~= "PLAYER_ENTERING_WORLD" then
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
        if not pihGateEnabled or pihManual ~= nil then return end
        -- ☠ THE ONE PLACE isActive MAY SHUT THE GATE. On load we never saw the cast, so a
        -- reload mid-cooldown would otherwise leave the helper showing for the rest of it.
        -- Safe here specifically because nothing is being cast at this instant, so a true
        -- reading is a real cooldown rather than a GCD.
        local ready = pihReadReady()
        if ready ~= pihGateOpen then pihSet(not ready) end
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
    local ready = pihReadReady()
    if not ready then return end
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
            (pihSoundCfg and pihGateOpen and pihLastArmCount == 0) and "bad" or "neutral")
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
