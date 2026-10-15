"""Guard for the icon browser's list matching the icon folders.

DandersFrames_Options/GUI/IconManifest.lua is generated from the folders on disk
(the client cannot list one), so an icon added without regenerating it would be
missing from /df debug icons. This rebuilds the manifest in memory and fails if
the committed file differs, and checks the browser reads the manifest rather than
a list of its own.

Usage: python Tools/mover-tests/test_icon_manifest.py
"""
import importlib.util, pathlib, sys
sys.dont_write_bytecode = True   # importing the generator must not leave a __pycache__ in Tools

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("gen", ROOT / "Tools/generate-icon-manifest.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

fails = passes = 0
def check(cond, msg):
    global fails, passes
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL: " + msg)

print("-- Icon browser: the manifest lists every icon on disk")

want = gen.render().replace("\r\n", "\n")
have = gen.OUT.read_bytes().decode("utf-8").replace("\r\n", "\n") if gen.OUT.exists() else ""
check(have == want, "IconManifest.lua is out of date -- run: python Tools/generate-icon-manifest.py")

for key, folder in gen.FOLDERS:
    n = len(list(folder.glob("*.png")))
    check(n > 0, "%s: the folder has icons to list (%d)" % (key, n))

toc = (ROOT / "DandersFrames_Options/DandersFrames_Options.toc").read_text(encoding="utf-8")
m, b = toc.find("GUI\\IconManifest.lua"), toc.find("GUI\\IconLib.lua")
check(m != -1, "the manifest is in the Options .toc")
check(m != -1 and b != -1 and m < b, "...and loads before the browser that reads it")

lib = (ROOT / "DandersFrames_Options/GUI/IconLib.lua").read_text(encoding="utf-8")
check("DF.ICON_MANIFEST" in lib, "the browser reads the generated manifest")
check("local ICONS = {" not in lib, "...and keeps no hand-written list of its own")

print("%d passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
