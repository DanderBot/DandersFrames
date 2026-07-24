# v5.0.0 Release Review & Fix Plan — 2026-07-16

**Scope:** the full delta from the last stable retail build (v4.7.2, `upstream/main`) to `krathe/v5-ptr` @ `b30926a` (v5.0.0-alpha.7) — 70 files, +19.4k/−23.2k. The 12.1 container rework, the old aura system's removal, FilterRegistry, and everything around them.

**Method:** direct audit of every migration in the addon (all ~39 Core.lua units + AD lazy family + TextDesigner + DesignerPresets + ClickCasting + AutoProfiles + Nicknames), a defaults↔export key cross-check (scripted), a GUI→engine wiring trace (trigger seam + test mode + combat), a two-direction stuck-state sweep (733 GUI-bound keys vs readers; every adopt-migration legacy key vs live readers), a dedicated FilterRegistry/TextStyle review, a dead-code/orphan sweep, a new-API guard sweep, and a syntax pass over all 57 changed Lua files. Every third-party (agent) claim was spot-verified against the code before inclusion.

**Status: NOT release-ready as-is.** Two blocker-class items (Stage 0 + Stage 1 below); everything else is well-defined cleanup. The engine, migration chain, and GUI wiring — the three things most likely to be structurally broken after a rework this size — all checked out.

**Recheck protocol for the next alpha:** re-run the greps named per finding (each finding cites file:line); nothing here depends on volatile state except the PTR checklist in Part 4. Expect little drift.

---

## Part 1 — Fix plan (staged, ready to execute)

> **Fix status (2026-07-16, all commits local on `krathe/v5-ptr`, not pushed):**
> - ✅ Stage 0 — `45e6829` (main merge; see the stage's correction note)
> - ✅ Stage 1 — `10c4147` (FilterRegistry P1: all three walks + live overlay)
> - ✅ Stage 2.1 — `17e21f4` (OOR alpha repoint + key strip)
> - ✅ Stage 2.2 — `8fe4055` (CVar stamp retired + key stripped)
> - ✅ Stage 3 (partial) — Krathe's calls executed: Masque REMOVED entirely (`7ccb9f2`, may return if Masque gains container support); z-order family FROSTED with roadmap overlay + never-alive controls REMOVED (`69d2b62` — res Pending Text, myBuffs export category). CC root-spell migration DELETED (`6579c93` — never ran, superseded by live `trueRootId` resolution). **Stage 3 fully closed.**
> - ✅ Stage 4.1 — `7f60204` (v5 migrations post-import via `DF:RunV5LegacyMigrations`)
> - ✅ Stage 4.2+4.3 — `11c5ff8` (add-by-ID cap; picker ESC retry)
> - ✅ Stage 4.4 — `686506c` (roleColors export/import; stale entries removed)
> - ✅ Stage 4.5 — `8d54449` (deterministic import reuse + empty-filter name rule; GetCustomFilter shape self-heal; picker name fallback). Uncategorised orphan/raw asymmetry DEFERRED — touching it risks excluding canonical ids preset selections share; revisit with the in-game verify cycle.
> - ✅ Stage 5 — four commits: `25921a1` (dead migrations retired + pinned one-shot), `9a9dea6` (dead code, −167 lines, all zero-callsite-verified), `b1ef9cd` (81 dead settings keys, defaults↔export parity re-verified), `3397240` (21 locale orphans, zero missing keys). DEFERRED deliberately: the adopt-migration legacy source-key strip (safe but permanently deletes the last copy of never-adopted customisations on non-active-era profiles — needs a deliberate call) and the dead-end raidGroupOrder chain (harmless, self-consuming).
> - ⏸ Stage 4.6 — gated on in-game verify (override-edit overlay behaviour).
> - PTR probes still owed: empty `includeSpellIDs` semantics; override-edit overlay behaviour; smoke pass on the fixed flows (filter delete in a layout, v4-string import, pet text follows the OOR slider).

### Stage 0 — Merge `upstream/main` into the v5 line ✅ DONE (2026-07-16, merge commit `45e6829`, local — not yet pushed)
The v5 branch forked at "Start v4.8.0 development", **before v4.7.0**. What the merge actually brought (verified in the staged delta):
- **PR #209** — `issecretvalue(current)` skip in the click-casting frame walker (now at ClickCasting/Frames.lua:934). Was genuinely missing; this crash class is *more* likely on 12.1.
- **Keyboard-bind self-heal** (`CC:ProfileHasKeyboardBindings` / `RequestBindingRepair` / `RunBindingRepair` + Events.lua wiring) — was genuinely missing.
- The v4.7.0–4.7.2 CHANGELOG sections.

**Correction to the original finding:** PR #203 + #204 had already been backported to the v5 line in `82c8760` ("Backport v4.7.1 fixes to the v5 line") — the original review grepped for guessed symbol names instead of the commits' content and wrongly listed #204 as missing. Verified present post-merge: the `settingUp` picker guard (GUI/GUI.lua) and `elem.overrides.color = true` (TextDesigner/Options.lua).

Merge resolutions: `AuraDesigner/Indicators.lua` and `Frames/Expiring.lua` stay deleted — both #203 hunks target the retired addon-side expiring engine (expiry is Blizzard-driven on 12.1; the bug class cannot recur). Post-merge syntax check clean; Part 5 recheck greps re-run on alpha.8: all remaining findings still stand.

### Stage 1 — FilterRegistry P1: auto-layout-override customs invisible to the id lifecycle 🔴 BLOCKER
Layout-edit sessions deep-copy the whole `buffFilterSelection`/`defensiveFilterSelection` — including `.customs` — into `profile.raidAutoProfiles.<type>.profiles[i].overrides` (Options/AutoProfiles.lua:2613), re-applied on every layout activation (:3379-3394). Three passes never look there:
1. **Delete scrub** — `ScrubDeletedFilter` (FilterRegistry/Options.lua:107-166) walks profile party/raid + AD presets only. The confirm dialog's "removed from every profile" promise is broken; the dead id returns whenever that layout activates.
2. **Export ref collection** — `EmbedCustomFilterData` (Profile.lua:516-575) never collects from `exportData.raidAutoProfiles`; a filter referenced only by a layout override doesn't travel.
3. **Import remap** — Profile.lua:1015-1060 walks `importData.party/raid` + presets only; `importData.raidAutoProfiles` is applied wholesale carrying the exporter's raw `cfN` ids.

Failure modes (both verified in code): cross-account id aliasing — the importer's unrelated `cf3` silently resolves, **wrong auras with no error** — and dangling id → `ResolveSelection` keeps `anySel` truthy (Registry.lua:338), skips the show-all fallback, returns an **empty include map → the row renders nothing** while that layout is active.

**Fix (one symmetric shape):** add a `raidAutoProfiles` overrides walk (keys `buffFilterSelection`/`defensiveFilterSelection` → `.customs[cfId]`) to all three passes; in the scrub also nil the id from the live `DF.raidOverrides` overlay. ⚠ Prerequisite lab probe: confirm Blizzard treats an empty `includeSpellIDs` map as include-nothing (the "renders nothing" leg rests on it; the addon's own `includeSig` comment assumes it).

### Stage 2 — Stuck states (stale key drives live / GUI writes elsewhere)
1. **OOR text alpha split-brain** *(v5 regression)*. GUI = one "Text Alpha" slider → `oorTextAlpha` (Options/Options.lua:785); TD live render reads it (TextDesigner/Render.lua:398). Four readers still consume the legacy per-element keys nothing writes: `Features/ElementAppearance.lua:489` (`oorNameTextAlpha or 1` — live via Bars.lua:2184 + Update.lua:233, drives legacy fontstrings incl. pets), `:546` (`oorHealthTextAlpha or 0.25`), `Core.lua:1885/1891` and `TestMode/TestMode.lua:763` (test previews). `MigrateOORTextAlpha` folded name→unified once but left the old keys populated — slider moves TD text, pet/test text stays frozen. **Fix:** repoint all four readers to `oorTextAlpha` (keep sensible fallbacks), then add both legacy keys to a strip pass.
2. **`_blizzDispelIndicator` zombie CVar stamp** *(v4.3.4 leftover)*. `Features/Auras.lua:243` (login, ×2 timers) and `Core.lua:2521` force `SetCVar("raidFramesDispelIndicatorType", db._blizzDispelIndicator or 1)`. No GUI writes the key since v4.3.4 (the dropdown writes `dispelOverlayDispelType`, consumed only by DF's own overlay, Dispel.lua:1104). DF silently re-stamps Blizzard's setting every login and fights any outside change. **Fix:** retire both stamp sites, strip the key + `Config.lua:911` default. ⚠ Before deciding, PTR-check whether the CVar even exists on 12.1 (a `SetCVar` on a removed CVar can error at login — if it's gone, this is also a latent login error).

### Stage 3 — Decisions needed (Krathe) before their fixes
1. **Dead GUI controls — frost vs remove.** All verified zero-consumer, none currently frosted:
   - AD **"Frame Strata"** per-indicator ×3 (AuraDesigner/Options.lua:3888/4052/4178 → `inst.frameStrata`) + global **"Default Frame Strata"** (:4912 → `defaults.indicatorFrameStrata`). v4's deleted Indicators.lua consumed them; the v5 Factory hardcodes z per family. Editor preview also hardcodes (:3195/:5497) — dead-but-consistent.
   - AD global **"Default Frame Level"** (:4911 → `defaults.indicatorFrameLevel`). Factory reads only the per-indicator value (`tonumber(indicator.frameLevel) or 0`, Factory.lua:971/1150 — that slider WORKS); the editor proxy's fallback map (:1668/:1679/:1685) makes the editor *display* the global as if it applied — editor-vs-live illusion. Removing the illusion matters more than the control. (Core.lua:3376's backfill of these defaults goes with whatever is decided.)
   - AD **"Draw above frame border"** (:4291 → `drawAboveFrameBorder`) — v4 consumer deleted, zero v5 reads.
   - Res icon **"Pending Text"** (Options/Options.lua:8267 → `resurrectionIconTextPending`) — never read in v4 *or* v5 (summon's twin IS read, StatusIcons.lua:387). Remove, or wire like summon.
   - `masqueBorderControl` (:4157) — only read by always-false-on-12.1 visibility conditions (:6048/:6274); Masque groups registered but zero `:AddButton` calls. Ties to the open Masque-retire decision.
   Recommended default: frost with `BlockControl12_1("limitation", …)` matching the expiring group, except Pending Text (remove or wire) — but each is a call to make.
2. **Click-cast root-spell migration is a permanent silent no-op** *(found in this pass)*. `CC:MigrateBindingsToRootSpells` (ClickCasting/Bindings.lua:299) guards on `DandersFrames_ClickCastDB` — a global that does not exist anywhere; the real DB is `DandersFramesClickCastingDB` (toc line 10). Called at ClickCasting/Events.lua:82, returns immediately, has never run for anyone. Options: **(a)** delete as superseded — Bindings.lua:1555 already resolves `trueRootId` live at bind time (likely correct); **(b)** fix the global name — it would then fire for every user on next login (per-class `migrationVersion` gate exists, but this needs deliberate testing, not a drive-by rename).
3. **"My Buff Indicators" export checkbox** — `ExportCategoryInfo.myBuffs` (ExportCategories.lua:1325) builds a visible checkbox that exports zero keys; the "Look" preset (Options/Options.lua:9294) still lists `bossDebuffs` + `myBuffs`. Straight deletion, listed here only because it's user-visible.

### Stage 4 — Smaller fixes (no decisions needed)
1. **Run the v5 migrations post-import.** `ApplyImportedProfile` doesn't run `MigrateDispelSourceToEnabled` / `StripLegacyAuraKeys` / the retired-anim remap — an imported v4 string shows a wrong dispel-enable state and retired animation values until the next reload (all three re-run over all profiles at ADDON_LOADED, so it self-heals). Invoke them post-import the way `MigrateBorderInsetFold` already is (Profile.lua:1157-1163).
2. **Filter Designer add-by-ID cap.** `DoAddSpell` (FilterRegistry/Options.lua:408-434) checks only `^%d+$`; the shared picker also caps length >10 after zero-strip (SpellPicker.lua:538-541). An oversized id becomes a float in the **account-wide** store and hits `%d` formatting. Copy the cap (or centralize in `AddSpellToCustom`).
3. **SpellPicker ESC-close lost when built mid-combat.** `BuildInstance` skips `EnableKeyboard(true)` in combat and instances are cached per parent forever (SpellPicker.lua:572-575, :738-742). Move `EnableKeyboard` into `OpenSpellPicker` (only `SetPropagateKeyboardInput` is the protected call).
4. **`roleColors` never exported** *(pre-existing v4 gap)*. Role border colours live at profile root since `MigrateRoleBorderColors`; the export payload builder (Profile.lua:600-693) doesn't include them and the stale per-mode `roleBorderColor*` entries in ExportCategories.lua (:1202/:1543) export nothing. Add `roleColors` to export+import; drop the stale entries.
5. **FilterRegistry P2/P3 hardening** (from the dedicated review): import collapses content-equal filters including empty-vs-empty (Registry.lua:113-140 — require non-empty content or matching names before reuse); import reuse-scan is pairs-order dependent (:122-127); nil-shape guard in `GetCustomFilter` covers `ResolveSelection`/`DuplicateFilter`/`CustomSpellCount` assumptions; `BuildIndex` name-nil guard (SpellPicker.lua:233-235); orphan/raw-id asymmetry in Uncategorised mode (Registry.lua:344-364).
6. **Selection edits during an active auto-layout override land in the ephemeral overlay** (reported by review; verify in-game first). The Aura Filters checkboxes mutate inner tables in place (Options/Options.lua:5623-5648, 6721-6746); through the raid proxy that hits the overlay copy (Core.lua:2563-2584), visible immediately but reverted on the next layout re-apply and persisted nowhere.

### Stage 5 — Housekeeping batch (one pass, mechanical)
**Migrations:**
- Delete the unreachable externalDef→defensiveIcon migration (Core.lua:3394-3411) + `_defensiveIconMigrated = true` from Config.lua:912 (the defaults-backfill at :3333 seeds the guard flag before the migration can ever run; the strip list already covers the keys; today it's re-add/strip churn every load).
- Retire the HARF `removedAuras` cleanup (Core.lua:3859-3879) — obsolete premise on v5 (Pain Suppression/Life Cocoon/etc. are live AD registry entries again, AuraDesigner/Config.lua:331+); it only reaches the legacy inline store so modern preset data is safe, but the one case it still fires (ancient pre-preset import) now deletes spells v5 *can* track.
- `MigratePinnedMatchMode` (Core.lua:1505-1511): unflagged every-load clears of `scale == 1.0` / `spacing == 2` mean a deliberate override at exactly those values reverts to inherit each reload. Flag-gate it or use explicit sentinel handling.
- Adopt-migration legacy source keys → extend the strip pass (post-fold, keys verified reader-free once Stage 2.1 lands): `showFrameBorder`, `borderSize/Color/Style/Texture`, `borderClassColor`, `frameBorderUseClassColor/UseRoleColor` (after confirming the Core.lua:1314 fallback resolver is retired with them or kept canonical-first), `frameBorderGradientEnabled`, `defensiveIconBorderGradientEnabled`, `resourceBarBorderEnabled`, `resourceBarClassColor`, `buffBorderEnabled/Thickness`, `debuffBorderEnabled/Thickness`, `buffExpiringBorderPulsate`, `roleBorderColorTank/Healer/Damager`, `oorNameTextAlpha`, `oorHealthTextAlpha`, `targetedSpellHighlight*`, `_blizzDispelIndicator`.
- The dead-end `raidGroupOrder` chain (created at Core.lua:3602 from the ancient bool, normalized at :2945, zero live readers) can retire whenever ancient-profile support is dropped — both halves together.
**Dead code:**
- 3× guarded no-op `DF:UpdateMyBuffGradientHealth` calls (Frames/Update.lua:924/1188/1412) + the write-only `hasMyBuff` test field (TestMode/TestMode.lua:15-19/98/257/310).
- Dead functions: `DF:EnsureAuraDurationText` (Features/Auras.lua:279), `DF:GetDebuffTypeColor` (:331), `BuildDirectDispelFilter` + `cachedDispelFilter` (:200/:53), `DebugDuration` (Frames/Create.lua:335), `GetDefensiveGrowthOffset` (Frames/Icons.lua:33), `GetGrowthOffset` (Frames/Update.lua:35), the `DF:ApplyAuraDesignerTabState` no-op shell. The AuraContainer handle-API subset (`SetSort`:1880, `HasSort`:159, `SetFilter`:1857, `HasSpellFilter`:158, `_getConfig`:1340, `_getAnchorFrame`:1341, `_layoutSlots`:1620) is dead today but is exactly what Wave 1 of the container plan reworks — resolve via W1, don't blind-delete.
- Fix-or-delete `CC:MigrateBindingsToRootSpells` per the Stage 3.2 decision.
**Config/locale (update ExportCategories in lockstep — keep `/df exportaudit` green):**
- 45 dead aura keys: `buff/debuffCountdown*` (12), old `buffFilterCancelable/Mode/Player/Raid` (4), `debuffShowAll`, `buff/debuffWrapOffsetX/Y` (4), `debuffExpiring*` (11), `defensiveBar*` (10), `dispelAnimateSpeed`/`dispelBorderStyle`/`dispelFrameLevel` (3). Plus ~35 non-aura secondary (list in the review transcript). **Ask before touching `tooltipAura*`** (pre-seeded for the scoped AD-tooltips plan) and the strata/level defaults (Stage 3.1 decision).
- 21 orphan locale keys in enUS (old direct-filter descriptions, position-dropdown labels, ClassPower/LCG leftovers, `"Import failed"`, `"Ignore Full Health Fade"`); zero missing keys. Also retire the same phrases on the CurseForge localization platform.

---

## Part 2 — Additional verified findings not in the plan (context)

- **GUI wiring is architecturally guaranteed:** every widget click ends in `DF:UpdateAll()` → `InvalidateAuraLayout()` (version bump + immediate debounced OOC re-drive of buffs/debuffs/defensive/missing/dispel + AD `SyncFrame`) and routes test-mode repaints; test frames drive the same `DriveBuffFactory` with `SetTestMax`. Combat defers via `needsUpdate`/version gates and flushes at regen (Core.lua:5331, AuraContainer.lua:1995) — by design. Known-accepted micro-gaps (in-code comments own them): **pinned-set and arena frames catch up one aura event late** after a GUI edit (`RefreshFactoryRows` iterates party+raid only, Features/Auras.lua:1609-1610).
- **New-API usage is consistently guarded:** `AddAuraAppliedSound` nil-guarded (Factory.lua:1904/1952/2026), `CreateNumericRuleFormatter`/`CreateSecondsFormatter` guarded incl. Enum tables (Auras.lua:437/482/496), `GetOverrideSpell` guarded (Bindings.lua:164), provider bounce pcall-wrapped with arg fallback (AuraContainer.lua:209-210). Only unguarded external dependency found: the Stage 2.2 CVar stamp.
- **Rollback statement (adopt into the release notes):** v5's savedvars changes are one-way — `StripLegacyAuraKeys` removes bossDebuffs*/myBuff*/dev-toggle data, `dispelOverlayEnabled` is reused with new semantics, border insets are folded. Rolling back v5.0.0 → v4.7.2 after first login is **not supported cleanly**: those features return with defaults, not the user's old values. Acceptable; say it once in the changelog.
- **Locale pipeline:** non-enUS files are CurseForge `--@localization@` stubs — translations inject at package time. Action is on the platform (refresh phrases, retire the 21 orphans), not in the repo.
- **TOC/versioning:** TOC clean both directions (no deleted files listed, all new files listed, load order sane); Changelog.lua is CI-stamped correctly; `## Interface: 120100` needs the release-build bump at ship time.

## Part 3 — Verified healthy (do not re-audit)

- **Migration chain, complete sweep:** all ~39 Core.lua ADDON_LOADED units + AD lazy family (spec-scope, instances, priorities incl. CC twin + coarse→fine flag forwarding, border fold, defaults refresh) + TextDesigner (preset-hosted guards + stray-health-text correction) + DesignerPresets (per-profile flag, ghost-preset guard) + ClickCasting `MigratePrioritiesLazy` + AutoProfiles override strip + Nicknames. Flag-gated, value-idempotent, fresh-profile-safe (`dispelOverlayEnabled` default `true` makes the v5 dispel migration no-op-equivalent), ordering verified (v4.3.4 dispel source :3922 → Hybrid :4004 → v5 enabled :4036; group-order create :3602 before deprecate call :5070). The two zero-reader scares (`frameBorderColorSource`, `targetedSpellImportantBorder*`) are alive via dynamic `BuildSpec` suffix construction.
- **Export key coverage:** defaults↔export lists match ~1:1 (1,223 vs 1,226; deltas are deliberate machine-locals + nil-default runtime keys). The July-audit P0 ("export drops 188 settings") is fixed.
- **Aura Blacklist retirement** is deliberate and tidy: notice page, data kept unenforced, no render reads.
- **Stuck-state sweep negatives:** all buff*/debuff* row keys read via `g(suffix)` (Auras.lua:625+); duration/stack text via TextStyle `BuildSpec` prefixes; `healthColor*`/`missingHealthColor*` via prefix (Frames/Colors.lua:120+); `afkIconTimer*`/status-icon colours via `db[prefix..…]` (StatusIcons.lua:207+); tooltip position family and the AD expiring/min-stacks/missing-trigger/expire-alert groups all properly `BlockControl12_1`-frosted; the two legacy-boolean fallbacks (`frameBorderUseClassColor`, `resourceBarClassColor`) are canonical-key-first and can't shadow a GUI change.
- **TextStyle.lua:** stableCenter shadow compensation correct on both axes; all five consumer prefixes complete in defaults; nil-guards sound.
- **FilterRegistry internals:** id allocation monotonic/never recycled; SavedVariables registration + lazy init fresh-install-safe; no ids/names interpolated into filter strings (token-only; ids ride `candidateFilters`); empty/emptied debuff lists parked before reaching the container; SpellDB integrity script-verified (no duplicate ids).
- **Dead-code debt vs the July audit:** 108 dead functions → 13; 121 orphan locale keys → 21. The rework paid the debt down.
- **Syntax:** all 57 changed Lua files pass; no edit-damage patterns.

## Part 4 — In-game / release checklists (cannot be verified from source)

**PTR checklist (run on the release-candidate build):**
1. **Perf at raid scale** — the biggest untested risk: 40-frame raid with `C_AddOnProfiler` numbers (MSUF-PerfTrace-style wrap is banked in the plan); count container rebuilds across auto-layout flips (each rebuild leaks a frame set until Wave 1 lands).
2. **Combat-edge matrix:** reload in combat (arena path), join raid mid-combat, settings changed in combat → regen flush, test mode enter/exit in combat.
3. **Fresh install** (no SavedVariables) + profile reset + wizard run.
4. **Import a real v4.7.2 export string** end-to-end (exercises Stage 4.1 and AD/TD materialisation).
5. **Lab probes:** empty `includeSpellIDs` semantics (gates Stage 1's severity); `raidFramesDispelIndicatorType` existence (gates Stage 2.2's shape); selection-edit-during-override overlay behaviour (gates Stage 4.6).
6. **Click-casting end-to-end** (the `/click` macrotext reroute + hover binds) — most build-fragile subsystem; re-verify every new PTR build.
7. Re-run the DF_AuraLab structural probe set on each new build (existing habit — keep it).

**Release process:**
1. Merge `upstream/main` (Stage 0) *before* tagging anything user-facing.
2. TOC Interface bump to the live 12.1 build at ship.
3. One full tag→package CI pass (release.yml dropped the `-S` packager arg this cycle; alphas prove most of it).
4. CurseForge localization phrase refresh (new v5 keys in; 21 orphans retired).
5. Changelog: add the rollback statement (Part 2) and a short "known 12.1 limitations" block (min-stacks, tooltip anchoring, expiring effects, per-type dispel colours) to cut support noise.

## Part 5 — Recheck greps for the next alpha

```
# Stage 0 landed?           git log --oneline HEAD..upstream/main   (want: empty)
# P1 fixed?                 grep -n "raidAutoProfiles" FilterRegistry/Options.lua Profile.lua   (want: hits in scrub + embed + remap)
# OOR repointed?            grep -rn "oorNameTextAlpha\|oorHealthTextAlpha" --include=*.lua .   (want: strip-list only)
# CVar stamp retired?       grep -rn "raidFramesDispelIndicatorType" --include=*.lua .          (want: none, or a real control)
# CC migration decided?     grep -rn "DandersFrames_ClickCastDB" --include=*.lua .              (want: none)
# Dead controls decided?    grep -n "drawAboveFrameBorder\|\"frameStrata\"" AuraDesigner/Options.lua
# Export checkbox gone?     grep -n "myBuffs" ExportCategories.lua Options/Options.lua
# Housekeeping batch?       grep -n "_defensiveIconMigrated" Config.lua ; grep -n "removedAuras" Core.lua
```
