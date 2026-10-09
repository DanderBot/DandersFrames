"""Guard for the Classic-layout hide: nothing reachable in Classic may be
missing from Modern.

Runs Tools/audit-classic-layout.py over every settings page and fails on any
item Classic reaches that Modern does not, except the reviewed list below
(each one is layout furniture, not a setting). Then proves the audit can
actually see a gap, by deleting a shared builder from one Modern card in
memory and checking the builder's keys are reported.

Usage: python Tools/mover-tests/test_classic_audit.py
"""
import importlib.util, pathlib, sys, tempfile
sys.dont_write_bytecode = True      # no Tools/__pycache__ from importing the audit

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("audit", HERE.parent / "audit-classic-layout.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

# Reviewed 2026-09-26. (page id, kind, value) -> why it is not a setting.
REVIEWED = {
    ("bars_healpred", "call", "GUI:RefreshCurrentPage"):
        "Classic rebuilds on Show Heals From to rebind its one colour picker; Modern builds all three pickers",
    ("general_pinnedframes", "key", "OnShow"):
        "a SetScript hook re-measuring Classic's intro label; Modern shows the same text as a banner",
    ("general_pinnedframes", "call", "GUI:AddSectionNewBadge"):
        "the gold 'New' badge on Classic's Frame Type box header",
    ("auras_debuffs", "call", "GUI:AttachHeaderSwatch"):
        "a read-only marker preview on Classic's Important Debuffs header",
    ("auras_debuffs", "field", "debuffImportantBadgeColor"):
        "read by that preview only; the colour picker is in the shared builder, in both layouts",
    ("auras_debuffs", "field", "debuffImportantMarkColor"):
        "read by that preview only; the colour picker is in the shared builder, in both layouts",
    ("general_frame", "call", "GUI.RelayoutCurrentPage"):
        "Classic's border box refresh callback; Modern's cards use their own state pass",
}

fails = 0
passes = 0


def check(cond, msg):
    global fails, passes
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL: " + msg)


print("-- classic audit: every page, Classic minus Modern")
pages_seen = 0
found = set()
for path in audit.PAGE_FILES:
    fm = audit.FileModel(path)
    for page in audit.find_pages(fm):
        pages_seen += 1
        missing, _ = audit.audit(fm, page, False)
        for kind, val, ln in missing:
            item = (page[0], kind, val)
            found.add(item)
            check(item in REVIEWED,
                  f"{page[0]}: {kind} {val!r} is reachable in Classic only ({fm.rel}:{ln})")
check(pages_seen >= 30, f"the audit finds the page builders (saw {pages_seen})")
for item in REVIEWED:
    check(item in found, f"reviewed item no longer reported, drop it from REVIEWED: {item}")

print("-- classic audit: it can see a gap")
src = (audit.ROOT / "DandersFrames_Options" / "GUI" / "Pages" / "Frames.lua").read_text(encoding="utf-8")
old = ('OpenSection(L["Shadow Settings"], "fonts_shadow", 1, ShadowSettingsSummary, nil, nil,\r\n'
       '                BuildShadowSettingsGroup)\r\n'
       '            BuildShadowSettingsGroup({')
if old not in src:
    old = old.replace("\r\n", "\n")
check(old in src, "self-test: the Shadow Settings card is where the mutation expects it")
if old in src:
    mutated = src.replace(old, old.replace("BuildShadowSettingsGroup", "Nothing"))
    with tempfile.TemporaryDirectory() as d:
        f = pathlib.Path(d) / "Frames.lua"
        f.write_text(mutated, encoding="utf-8")
        saved_root = audit.ROOT
        audit.ROOT = pathlib.Path(d).parent
        try:
            fm = audit.FileModel(f)
            page = next(p for p in audit.find_pages(fm) if p[0] == "general_fonts")
            keys = {v for k, v, _ in audit.audit(fm, page, False)[0] if k == "bound"}
        finally:
            audit.ROOT = saved_root
    for k in ("fontShadowOffsetX", "fontShadowOffsetY", "fontShadowColor"):
        check(k in keys, f"self-test: a Modern card that drops the shared builder reports {k}")

print(f"{passes} passed, {fails} failed")
sys.exit(1 if fails else 0)
