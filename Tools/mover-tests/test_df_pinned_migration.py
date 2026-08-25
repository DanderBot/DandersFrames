"""Headless regression test for the DandersFrames pinned-record migration
(PinnedFrames.MigrateProfileRecords / NormaliseLegacyRecord / FoldPendingRef).

Runs the REAL helpers extracted from DandersFrames/Features/PinnedFrames.lua against a
set of real (anonymised) pre-migration records and asserts that the container's growth
corner lands on the same screen spot before and after the migration, within 0.5 px:

  * pre  = the pre-merge screen branch (151aa861), reproduced verbatim below
  * post = the current PositionPinnedContainer on the migrated record, at every stage:
           ADDON_LOADED pass with NO trusted UIParent size (pendingRef deferral),
           PLAYER_ENTERING_WORLD fold with the real size, a second idempotent pass,
           and the one-shot path (trusted size available on the first pass -- import).

Usage: python Tools/mover-tests/test_df_pinned_migration.py
"""
import pathlib, sys
try:
    from lupa import lua51 as lupa_mod      # WoW is Lua 5.1
except ImportError:
    import lupa as lupa_mod

HERE = pathlib.Path(__file__).resolve().parent
PF_PATH = HERE.parents[1] / "DandersFrames" / "Features" / "PinnedFrames.lua"
src = PF_PATH.read_text(encoding="utf-8").replace("\r\n", "\n")

def grab(start, end="\nend\n"):
    i = src.index(start)
    return src[i:src.index(end, i) + len(end)]

def grab_table(start):
    i = src.index(start)
    return src[i:src.index("}", i) + 1]

# Real helpers from PinnedFrames.lua. DF / IsInRaid / UIParent are stubbed: the screen
# branch never touches them, and every record here is a screen record (no anchorTo).
NEW_CODE = "\n".join([
    "local PinnedFrames = {}",
    "local DF, IsInRaid, UIParent = {}, function() return false end, nil",
    grab("local function GetSetGrowDirection(set)"),
    grab("local function GetContainerAnchorPoint(set)"),
    grab("local function AnchorFractions(point)"),
    grab_table("local FRAMES_ANCHOR_POINTS = {"),
    grab_table("local FRAMES_TARGET_MODE = {"),
    grab("local function FramesGlue(a)"),
    grab("local function MirrorAnchorTo(a)"),
    grab("local function CopyAnchor(a)"),
    grab("function PinnedFrames.ReadXY(pos)"),
    grab("function PinnedFrames.WriteXY(set, point, x, y)"),
    grab("local function ResolveFramesAnchorTarget()"),
    grab("local function ResolveGlueTarget(target)"),
    grab("local function PositionPinnedContainer(container, set, pos, frameW, frameH)"),
    grab("function PinnedFrames.NormaliseLegacyRecord("),
    grab("function PinnedFrames.FoldPendingRef("),
    grab("function PinnedFrames.ConvertLegacyAnchorTo("),
    grab("function PinnedFrames.MigrateProfileRecords("),
    "PinnedFrames.Position = PositionPinnedContainer",
    "PinnedFrames.Fractions = AnchorFractions",
    "return PinnedFrames",
])

# The PRE-MERGE screen branch, verbatim from 151aa861:DandersFrames/Features/PinnedFrames.lua
# (PositionPinnedContainer, anchored branch dropped -- no record here has anchorTo).
OLD_CODE = "\n".join([
    "local PinnedFrames = {}",
    grab("local function GetSetGrowDirection(set)"),
    grab("local function GetContainerAnchorPoint(set)"),
    grab("local function AnchorFractions(point)"),
    """
local function PositionPinnedContainer(container, set, pos, frameW, frameH)
    if not container then return end
    local growth = GetContainerAnchorPoint(set)
    local s = container:GetScale() or 1

    local ref = (pos and pos.point) or growth
    local gfx, gfy = AnchorFractions(growth)
    local rfx, rfy = AnchorFractions(ref)
    -- pos.x/y are screen-space (÷scale → container units); the frame offset is
    -- already in container-local units, so it is NOT divided by scale.
    local x = ((pos and pos.x) or 0) / s + (gfx - rfx) * (frameW or 0)
    local y = ((pos and pos.y) or 0) / s + (gfy - rfy) * (frameH or 0)
    container:ClearAllPoints()
    container:SetPoint(growth, UIParent, ref, x, y)
end
PinnedFrames.Position = PositionPinnedContainer
return PinnedFrames
""",
])

lua = lupa_mod.LuaRuntime(unpack_returned_tuples=True)
NEW = lua.execute(NEW_CODE)
OLD = lua.execute(OLD_CODE)

mk_container = lua.eval("""function(s)
  local c = { scale = s }
  function c:GetScale() return self.scale end
  function c:ClearAllPoints() self.pts = nil end
  function c:SetPoint(p, rel, rp, x, y) self.pts = { p = p, rp = rp, x = x, y = y } end
  return c
end""")
deep = lua.eval("function(t) local function cp(v) if type(v) ~= 'table' then return v end local o = {} for k, x in pairs(v) do o[k] = cp(x) end return o end return cp(t) end")

# ---- real records (anonymised: only the fields the geometry reads). One profile per
# row group; party/raid baseline sizes are that profile's frameWidth/Height/Scale.
REAL = [
    # the profile that flew away: enabled TOPRIGHT-referenced sets (dragged), plus a
    # BOTTOMRIGHT one and a TOPLEFT raid set; raid set 1 carries a per-set scale
    dict(party=dict(frameWidth=125, frameHeight=64, frameScale=1), raid=dict(frameWidth=104, frameHeight=54, frameScale=1), sets={
        "party": [
            dict(growDirection="VERTICAL", frameAnchor="START", columnAnchor="END", matchMode="party",
                 position=dict(point="TOPRIGHT", x=-2501.130033202477, y=-859.8333270289015)),
            dict(growDirection="HORIZONTAL", frameAnchor="END", columnAnchor="END", matchMode="party",
                 position=dict(point="BOTTOMRIGHT", x=-2581.667602539063, y=381.3334350585938)),
        ],
        "raid": [
            dict(growDirection="VERTICAL", frameAnchor="START", columnAnchor="END", matchMode="raid", scale=1.299999952316284,
                 position=dict(point="TOPRIGHT", x=-2589.668686304276, y=-794.666513729833)),
            dict(growDirection="HORIZONTAL", frameAnchor="START", columnAnchor="START", matchMode="raid",
                 position=dict(point="TOPLEFT", x=1338.832930181169, y=-606.3332024514647)),
        ]}),
    # never-dragged defaults (CENTER reference -> half-frame fold only) next to dragged TOPLEFT
    dict(party=dict(frameWidth=125, frameHeight=64, frameScale=1), raid=dict(frameWidth=104, frameHeight=54, frameScale=1), sets={
        "party": [
            dict(growDirection="HORIZONTAL", frameAnchor="START", columnAnchor="START", matchMode="party",
                 position=dict(point="CENTER", x=0, y=200)),
            dict(growDirection="HORIZONTAL", frameAnchor="START", columnAnchor="START", matchMode="party",
                 position=dict(point="TOPLEFT", x=1559.999267578125, y=-754.6665649414062)),
        ],
        "raid": [
            dict(growDirection="VERTICAL", frameAnchor="START", columnAnchor="END", matchMode="raid", scale=1.299999952316284,
                 position=dict(point="TOPRIGHT", x=-2566.33542238552, y=-857.1664912849585)),
            dict(growDirection="HORIZONTAL", frameAnchor="START", columnAnchor="START", matchMode="raid",
                 position=dict(point="TOPLEFT", x=1338.832930181169, y=-606.3332024514647)),
        ]}),
    # CENTER defaults with a frameScale ~= 1 baseline, and a raid set matched to party sizes
    dict(party=dict(frameWidth=130, frameHeight=70, frameScale=1.15), raid=dict(frameWidth=130, frameHeight=53, frameScale=0.9), sets={
        "party": [
            dict(growDirection="HORIZONTAL", frameAnchor="START", columnAnchor="START", matchMode="party",
                 position=dict(point="TOPLEFT", x=1001.666687011719, y=-364.9999389648438)),
            dict(growDirection="HORIZONTAL", frameAnchor="CENTER", columnAnchor="CENTER", matchMode="party",
                 position=dict(point="CENTER", x=0, y=-200)),
        ],
        "raid": [
            dict(growDirection="HORIZONTAL", frameAnchor="START", columnAnchor="START", matchMode="party", customWidth=90,
                 position=dict(point="TOPLEFT", x=1001.666687011719, y=-372.5)),
            dict(growDirection="VERTICAL", frameAnchor="END", columnAnchor="END", matchMode="raid",
                 position=dict(point="CENTER", x=0, y=-200)),
        ]}),
]

fails = 0
def check(cond, msg):
    global fails
    if not cond:
        fails += 1
        print("FAIL", msg)

def to_lua_profile(p):
    prof = {"party": dict(p["party"]), "raid": dict(p["raid"])}
    for mode in ("party", "raid"):
        prof[mode]["pinnedFrames"] = {"sets": {i + 1: s for i, s in enumerate(p["sets"][mode])}}
    return lua.table_from(prof, recursive=True)

def baseline(prof, mode, s):
    base = prof[s["matchMode"] or mode] or prof[mode]
    w = s["customWidth"] or base["frameWidth"] or 120
    h = s["customHeight"] or base["frameHeight"] or 50
    sc = s["scale"] or base["frameScale"] or 1
    return w, h, sc

def corner(PF, prof, mode, s, uiW, uiH):
    """Growth corner in UIParent units from UIParent CENTER after PF.Position's SetPoint."""
    w, h, sc = baseline(prof, mode, s)
    c = mk_container(sc)
    PF.Position(c, s, s["position"], w, h)
    p = c.pts
    rfx, rfy = NEW.Fractions(p.rp)
    return p.p, rfx * uiW + p.x * sc, rfy * uiH + p.y * sc

def each_set(prof):
    for mode in ("party", "raid"):
        sets = prof[mode]["pinnedFrames"]["sets"]
        for i in sets.keys():
            yield mode, i, sets[i]

def compare(label, pre, PFm, prof, uiW, uiH):
    for mode, i, s in each_set(prof):
        g0, x0, y0 = pre[(mode, i)]
        g1, x1, y1 = corner(PFm, prof, mode, s, uiW, uiH)
        d = max(abs(x0 - x1), abs(y0 - y1))
        check(g0 == g1, f"{label} {mode} set{i}: growth corner {g0} vs {g1}")
        check(d <= 0.5, f"{label} {mode} set{i}: corner moved by {d:.2f} px: pre=({x0:.2f},{y0:.2f}) post=({x1:.2f},{y1:.2f})")

nsets = 0
for (uiW, uiH) in ((2560, 1440), (1920, 1080)):
    for pi, rec in enumerate(REAL):
        orig = to_lua_profile(rec)
        pre = {(mode, i): corner(OLD, orig, mode, s, uiW, uiH) for mode, i, s in each_set(orig)}
        nsets += len(pre)
        tag = f"[{uiW}x{uiH} profile{pi}]"

        # 1. ADDON_LOADED pass: no trusted size -> corner term deferred via pendingRef
        prof = deep(orig)
        NEW.MigrateProfileRecords(prof, None, None)
        for mode, i, s in each_set(prof):
            pf = prof[mode]["pinnedFrames"]
            check(pf["positionsV2"] is True, f"{tag} positionsV2 stamped on {mode}")
            pos = s["position"]
            want_ref = orig[mode]["pinnedFrames"]["sets"][i]["position"]["point"]
            if want_ref == "CENTER":
                check(pos["pendingRef"] is None, f"{tag} {mode} set{i}: CENTER ref needs no deferral")
            else:
                check(pos["pendingRef"] == want_ref, f"{tag} {mode} set{i}: pendingRef {pos['pendingRef']} != {want_ref}")
        compare(f"{tag} untrusted pass", pre, NEW, prof, uiW, uiH)

        # 2. PLAYER_ENTERING_WORLD fold with the real size
        NEW.MigrateProfileRecords(prof, uiW, uiH)
        for mode, i, s in each_set(prof):
            pos = s["position"]
            check(pos["pendingRef"] is None, f"{tag} {mode} set{i}: pendingRef not folded")
            check(pos["point"] == corner(OLD, orig, mode, orig[mode]["pinnedFrames"]["sets"][i], uiW, uiH)[0],
                  f"{tag} {mode} set{i}: point is not the growth corner")
        compare(f"{tag} folded", pre, NEW, prof, uiW, uiH)

        # 3. idempotent: a further pass changes nothing
        snap = {(m, i): (s["position"]["point"], s["position"]["x"], s["position"]["y"]) for m, i, s in each_set(prof)}
        NEW.MigrateProfileRecords(prof, uiW, uiH)
        for m, i, s in each_set(prof):
            p = s["position"]
            check(snap[(m, i)] == (p["point"], p["x"], p["y"]), f"{tag} {m} set{i}: second pass changed the record")
        compare(f"{tag} idempotent", pre, NEW, prof, uiW, uiH)

        # 4. one-shot path (trusted size on the first pass, e.g. an import after login)
        prof2 = deep(orig)
        NEW.MigrateProfileRecords(prof2, uiW, uiH)
        for m, i, s in each_set(prof2):
            check(s["position"]["pendingRef"] is None, f"{tag} {m} set{i}: one-shot left a pendingRef")
        compare(f"{tag} one-shot", pre, NEW, prof2, uiW, uiH)
        for m, i, s in each_set(prof2):
            a, b = s["position"], prof[m]["pinnedFrames"]["sets"][i]["position"]
            check(abs(a["x"] - b["x"]) < 1e-6 and abs(a["y"] - b["y"]) < 1e-6,
                  f"{tag} {m} set{i}: deferred and one-shot records differ")

        # 5. the bug: folding the corner with an untrusted (smaller) size moves the set
        prof3 = deep(orig)
        NEW.MigrateProfileRecords(prof3, uiW * 0.75, uiH * 0.75)
        moved = 0
        for m, i, s in each_set(prof3):
            g0, x0, y0 = pre[(m, i)]
            _, x1, y1 = corner(NEW, prof3, m, s, uiW, uiH)
            if max(abs(x0 - x1), abs(y0 - y1)) > 0.5: moved += 1
        check(moved > 0, f"{tag} a wrong fold size must be observable (sanity of the harness)")

# a write through WriteXY is CENTER-relative and voids a pending fold
pos = lua.table_from({"point": "TOPRIGHT", "x": -10, "y": -20, "pendingRef": "TOPRIGHT"})
setT = lua.table_from({"position": pos})
NEW.WriteXY(setT, "TOPRIGHT", 5, 6)
check(pos["pendingRef"] is None and pos["x"] == 5 and pos["y"] == 6, "WriteXY clears pendingRef")
# FoldPendingRef refuses an unusable size and leaves the record self-describing
pos = lua.table_from({"point": "TOPLEFT", "x": 100, "y": -50, "pendingRef": "TOPLEFT"})
check(NEW.FoldPendingRef(pos, 0, 0) is False and pos["pendingRef"] == "TOPLEFT" and pos["x"] == 100, "FoldPendingRef holds on a 0 size")
check(NEW.FoldPendingRef(pos, None, None) is False and pos["pendingRef"] == "TOPLEFT", "FoldPendingRef holds on nil")
check(NEW.FoldPendingRef(pos, 1920, 1080) is True and pos["pendingRef"] is None and pos["x"] == -860 and pos["y"] == 490, "FoldPendingRef folds TOPLEFT")

# ============================================================
# PHASE D -- STABLE PINNED-SET UIDS
# ============================================================
# Real code again, from two files:
#   * PinnedFrames.EnsureSetUid (+ its ModePinnedDB) -- stamp-on-read allocation
#   * Core.lua's MigratePinnedAnchorKeys, and the _pinnedUidsV1 block itself, sliced out
#     of DF:MigrateContainerPositionRecords's profile loop and wrapped in a function so
#     it can be called with a profile. `DF` is the block's only other free name.

CORE_PATH = HERE.parents[1] / "DandersFrames" / "Core.lua"
core_src = CORE_PATH.read_text(encoding="utf-8").replace("\r\n", "\n")

def core_grab(start, end="\nend\n"):
    i = core_src.index(start)
    return core_src[i:core_src.index(end, i) + len(end)]

BLOCK_START = 'if type(profile) == "table" and not profile._pinnedUidsV1 then'
BLOCK_END = "            profile._pinnedUidsV1 = true\n        end\n"
_i = core_src.index(BLOCK_START)
UIDS_BLOCK = core_src[_i:core_src.index(BLOCK_END, _i) + len(BLOCK_END)]

CORE = lua.execute("\n".join([
    core_grab("local function MigratePinnedAnchorKeys(pos, hasSet)"),
    "local function RunPinnedUidsV1(profile, DF)",
    UIDS_BLOCK,
    "end",
    "return { Rewrite = MigratePinnedAnchorKeys, Run = RunPinnedUidsV1 }",
]))

# EnsureSetUid reaches its DB through ModePinnedDB -> DF:GetDB(mode); the harness hands
# it whichever profile the case under test is using.
UID = lua.execute("\n".join([
    "local PinnedFrames = {}",
    "local PROFILE",
    "local DF = {}",
    "function DF:GetDB(mode) return PROFILE and PROFILE[mode] end",
    'local function GetActualMode() return "party" end',
    grab("local function ModePinnedDB(mode)"),
    grab("function PinnedFrames:EnsureSetUid(setIndex, mode)"),
    "function PinnedFrames.UseProfile(p) PROFILE = p end",
    "return PinnedFrames",
]))

uid_checks = 0
def ucheck(cond, msg):
    global uid_checks
    uid_checks += 1
    check(cond, msg)

def mk_profile(party_sets, raid_sets, **extra):
    """A profile carrying only what the uid migration reads."""
    prof = {"party": {"pinnedFrames": {"sets": {i + 1: s for i, s in enumerate(party_sets)}}},
            "raid":  {"pinnedFrames": {"sets": {i + 1: s for i, s in enumerate(raid_sets)}}}}
    for mode, keys in extra.items():
        prof[mode].update(keys)
    return lua.table_from(prof, recursive=True)

NO_DF = lua.table_from({}, recursive=True)

def anchor(target, fallback=None):
    a = {"target": target}
    if fallback:
        a["fallback"] = {"target": fallback}
    return {"point": "CENTER", "x": 0, "y": 0, "anchor": a}

# ---- 1. backfill stamps uids in array order and sets nextUid = max + 1
prof = mk_profile([{"name": "a"}, {"name": "b"}, {"name": "c"}], [{"name": "r1"}, {"name": "r2"}])
CORE.Run(prof, NO_DF)
for mode, n in (("party", 3), ("raid", 2)):
    pfr = prof[mode]["pinnedFrames"]
    for i in range(1, n + 1):
        ucheck(pfr["sets"][i]["uid"] == i, f"backfill {mode} set{i}: uid {pfr['sets'][i]['uid']} != {i}")
    ucheck(pfr["nextUid"] == n + 1, f"backfill {mode}: nextUid {pfr['nextUid']} != {n + 1}")
ucheck(prof["_pinnedUidsV1"] is True, "backfill stamps _pinnedUidsV1")

# ---- 2. the flag is honoured: a second run does not touch a set added since
prof["party"]["pinnedFrames"]["sets"][4] = lua.table_from({"name": "d"}, recursive=True)
CORE.Run(prof, NO_DF)
ucheck(prof["party"]["pinnedFrames"]["sets"][4]["uid"] is None, "second run must not stamp (flag honoured)")
ucheck(prof["party"]["pinnedFrames"]["nextUid"] == 4, "second run must not move nextUid")

# ---- 3. nextUid is only ever RAISED, never lowered
prof = mk_profile([{"uid": 5}, {"uid": 7}], [{"uid": 2}])
prof["party"]["pinnedFrames"]["nextUid"] = 3      # stale/too low
prof["raid"]["pinnedFrames"]["nextUid"] = 100     # already past the array
CORE.Run(prof, NO_DF)
ucheck(prof["party"]["pinnedFrames"]["nextUid"] == 8, f"stale nextUid raised to 8, got {prof['party']['pinnedFrames']['nextUid']}")
ucheck(prof["raid"]["pinnedFrames"]["nextUid"] == 100, "a nextUid past the array is left alone")
ucheck(prof["party"]["pinnedFrames"]["sets"][1]["uid"] == 5, "an existing uid is not renumbered")

# ---- 4. EnsureSetUid: stamp-on-read allocates from nextUid and bumps it
prof = mk_profile([{"name": "a"}, {"name": "b"}], [])
prof["party"]["pinnedFrames"]["nextUid"] = 9
UID.UseProfile(prof)
ucheck(UID.EnsureSetUid(UID, 1, "party") == 9, "EnsureSetUid takes nextUid")
ucheck(prof["party"]["pinnedFrames"]["sets"][1]["uid"] == 9, "EnsureSetUid stamps the set")
ucheck(prof["party"]["pinnedFrames"]["nextUid"] == 10, "EnsureSetUid bumps nextUid")
ucheck(UID.EnsureSetUid(UID, 1, "party") == 9, "EnsureSetUid is idempotent on a stamped set")
ucheck(prof["party"]["pinnedFrames"]["nextUid"] == 10, "a re-read does not bump nextUid")
ucheck(UID.EnsureSetUid(UID, 2, "party") == 10, "the next set takes the bumped counter")
ucheck(UID.EnsureSetUid(UID, 7, "party") is None, "a set that does not exist gets no uid")
ucheck(UID.EnsureSetUid(UID, 1, False) == 9, "the isRaid boolean is accepted as the mode")

# ---- 5. EnsureSetUid derives a floor when nextUid is missing (import / round trip)
prof = mk_profile([{"uid": 4}, {"name": "b"}, {"name": "c"}], [])
UID.UseProfile(prof)
ucheck(UID.EnsureSetUid(UID, 2, "party") == 5, "floor = max uid in use + 1")
ucheck(prof["party"]["pinnedFrames"]["nextUid"] == 6, "the derived floor seeds nextUid")
prof = mk_profile([{"name": "a"}, {"name": "b"}, {"name": "c"}], [])
UID.UseProfile(prof)
ucheck(UID.EnsureSetUid(UID, 1, "party") == 4, "floor is at least the array length + 1")
ucheck(UID.EnsureSetUid(UID, 2, "party") == 5, "a later stamp cannot collide with the first")

# ---- 6. the record-string rewrite
prof = mk_profile(
    [{"name": "a"}, {"name": "b"}, {"position": anchor("DandersFrames:party.pinned1")}],
    [{"name": "r1"}],
    party={"position": anchor("DandersFrames:party.pinned3", "DandersFrames:raid.pinned1"),
           "personalTargetedPosition": anchor("DandersFrames:party.pinned4"),   # set 4 does not exist
           "targetedListPosition": anchor("DandersFrames:party")},
    raid={"position": anchor("SomeOtherAddon:party.pinned1")},
)
CORE.Run(prof, NO_DF)
ucheck(prof["party"]["position"]["anchor"]["target"] == "DandersFrames:party.pinned.3",
       "anchor.target rewritten to the uid format")
ucheck(prof["party"]["position"]["anchor"]["fallback"]["target"] == "DandersFrames:raid.pinned.1",
       "anchor.fallback.target rewritten to the uid format")
ucheck(prof["party"]["personalTargetedPosition"]["anchor"]["target"] == "DandersFrames:party.pinned4",
       "a string naming a set that does not exist is left as-is")
ucheck(prof["party"]["targetedListPosition"]["anchor"]["target"] == "DandersFrames:party",
       "a non-pinned DF key is left as-is")
ucheck(prof["raid"]["position"]["anchor"]["target"] == "SomeOtherAddon:party.pinned1",
       "another addon's key is left as-is")
ucheck(prof["party"]["pinnedFrames"]["sets"][3]["position"]["anchor"]["target"] == "DandersFrames:party.pinned.1",
       "a pinned set's OWN record is swept")

# ---- 7. the raid auto-layout overrides are swept through DF.ForEachRaidLayoutOverride
prof = mk_profile([{"name": "a"}, {"name": "b"}], [{"name": "r1"}])
layout = lua.table_from({"overrides": {
    "position": anchor("DandersFrames:party.pinned2"),
    "targetedListPosition": anchor("DandersFrames:raid.pinned1"),
}}, recursive=True)
DF_STUB = lua.table()
DF_STUB.ForEachRaidLayoutOverride = lua.eval("function(layouts) return function(profile, fn) fn(layouts) end end")(layout)
CORE.Run(prof, DF_STUB)
ucheck(layout["overrides"]["position"]["anchor"]["target"] == "DandersFrames:party.pinned.2",
       "a layout override's record is swept")
ucheck(layout["overrides"]["targetedListPosition"]["anchor"]["target"] == "DandersFrames:raid.pinned.1",
       "every override record field is swept")

# ---- 8. the rewrite helper on its own: a record with no anchor at all is untouched
plain = lua.table_from({"point": "CENTER", "x": 1, "y": 2}, recursive=True)
CORE.Rewrite(plain, lua.eval("function() return true end"))
ucheck(plain["x"] == 1 and plain["anchor"] is None, "an anchorless record survives the rewrite")
CORE.Rewrite(None, lua.eval("function() return true end"))
ucheck(True, "the rewrite tolerates a nil record")

print(f"pinned migration: {nsets} real set placements checked, {uid_checks} uid/rewrite checks, {fails} failed")
sys.exit(1 if fails else 0)
