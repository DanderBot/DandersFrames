"""Guard for the GUI icons being 64x64 PNGs, and every reference finding one.

The client resolves an EXTENSIONLESS texture path to .blp/.tga only, so a
.png must be named with its extension -- and a reference that forgets it
draws nothing (or the green missing-texture square) with no error. This walks
every shipped Lua file and fails on:

  * a TGA left in either icon folder, or an icon that is not 64x64 RGBA;
  * an icon path written without ".png" (or still ".tga");
  * a ".png" icon path naming a file that is not there;
  * an icon-folder variable concatenated with a bare name;
  * a runtime-built icon name ("...Icons\\\\" .. expr) not followed by ".png".

Usage: python Tools/mover-tests/test_gui_icon_png.py
"""
import pathlib, re, struct, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
DF_DIR = ROOT / "DandersFrames/Media/Icons"
KIT_DIR = ROOT / "DandersUI/Media/Icons"
BS2 = r"\\\\"   # regex for the two characters \\ in Lua source

fails = passes = 0
def check(cond, msg):
    global fails, passes
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL: " + msg)

print("-- GUI icons: 64x64 PNG files, and every reference names a real .png")

names = {}
for d, tag in ((DF_DIR, "df"), (KIT_DIR, "kit")):
    check(not list(d.glob("*.tga")), "files: no TGA left in %s" % d.relative_to(ROOT))
    for p in d.glob("*.png"):
        data = p.read_bytes()
        w, h, depth, ctype = struct.unpack(">IIBB", data[16:26])
        check(data[:8] == b"\x89PNG\r\n\x1a\n" and (w, h, depth, ctype) == (64, 64, 8, 6),
              "files: %s is a 64x64 8-bit RGBA PNG" % p.relative_to(ROOT))
        names.setdefault(p.stem, set()).add(tag)
check(len(names) >= 55, "files: the icon set is there (%d names)" % len(names))

lua = [p for d in ("DandersFrames", "DandersFrames_Options", "DandersUI", "DandersMover", "DandersMoverDemo")
       for p in (ROOT / d).rglob("*.lua") if "Libs" not in p.parts]

LIT = re.compile(r'Icons' + BS2 + r'([A-Za-z0-9_]+)((?:\.[A-Za-z]+)?)"')
VARS = r'\b(?:ICONS|ICON_PATH|ICONS_PATH|ICON|mediaPath|iconPath|gradIconPath)\s*\.\.\s*"([A-Za-z0-9_]+)((?:\.[A-Za-z]+)?)"'
DYN_JOIN = re.compile(r'Icons' + BS2 + r'"\s*\.\.')   # "...Icons\\" .. expr
DYN_WRAP = re.compile(r'Icons' + BS2 + r'"\s*$')       # "...Icons\\"  <newline> .. expr
refs = 0
for p in lua:
    rel = p.relative_to(ROOT)
    lines = p.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines, 1):
        code = line.split("--", 1)[0]
        for m in LIT.finditer(code):
            name, ext = m.group(1), m.group(2)
            if name not in names:
                continue
            refs += 1
            check(ext == ".png", "%s:%d: icon %r is named with .png (got %r)" % (rel, i, name, ext or "none"))
            if "DandersFrames" + "\\\\" + "Media" in code:
                check("df" in names[name], "%s:%d: %s.png exists in DandersFrames/Media/Icons" % (rel, i, name))
        for m in re.finditer(VARS, code):
            if m.group(1) in names:
                refs += 1
                check(m.group(2) == ".png", "%s:%d: icon %r is named with .png" % (rel, i, m.group(1)))
        # A folder path joined to a name built at run time: the ".png" must
        # follow in the same statement. A line that ENDS on the folder path is a
        # folder variable's definition unless the next line carries on with "..".
        nxt = lines[i].split("--", 1)[0] if i < len(lines) else ""
        if DYN_JOIN.search(code):
            check('".png"' in code, "%s:%d: a runtime-built icon name gets .. \".png\"" % (rel, i))
        elif DYN_WRAP.search(code) and nxt.lstrip().startswith(".."):
            check('".png"' in nxt, "%s:%d: a runtime-built icon name gets .. \".png\"" % (rel, i))
check(refs > 150, "refs: the scan found the icon references (%d)" % refs)

print("%d passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
