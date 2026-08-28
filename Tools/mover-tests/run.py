"""Headless tests for DandersMover's pure modules. Usage: python Tools/mover-tests/run.py [filter]"""
import sys, pathlib
try:
    from lupa import lua51 as lupa_mod      # WoW is Lua 5.1
except ImportError:
    import lupa as lupa_mod
lua = lupa_mod.LuaRuntime(unpack_returned_tuples=True)

HERE = pathlib.Path(__file__).resolve().parent
ADDON = HERE.parents[1] / "DandersMover"
loader = lua.eval("function(src, name) return assert((loadstring or load)(src, '@' .. name)) end")

def run(path, *args):
    return loader(path.read_text(encoding="utf-8"), path.name)(*args)

# The addon's own Libs/ copies are the normal source. Until they exist
# (Task 1 Step 1 copies them), fall back to the identical DandersFrames copies.
LIBS = ADDON / "Libs"
if not (LIBS / "LibStub" / "LibStub.lua").exists():
    LIBS = HERE.parents[1] / "DandersFrames" / "Libs"
    print(f"WARNING: DandersMover/Libs missing, loading libs from {LIBS}")

run(HERE / "shim.lua")
run(LIBS / "LibStub" / "LibStub.lua")
run(LIBS / "CallbackHandler-1.0" / "CallbackHandler-1.0.lua")
ns = lua.table()
# Fx lives in DandersUI (UI.Fx). Load the canonical copy the way the embedded
# lib would land it -- onto NS.__DandersUI -- so the mover's Fx.lua alias
# below finds it (headless runs never load DandersUI/Core.lua or a host).
ns["__DandersUI"] = lua.table()
ns.Lib = ns.Lib or lua.eval("{ callbacks = { Fire = function() end } }")   # winner marker: the lost-copy guards check NS.Lib
run(HERE.parents[1] / "DandersUI" / "Fx.lua", "DandersMover", ns)

# ---- the surface style, taken from the REAL Theme.lua -------------------
# Popout / PopoutRow / Sections all resolve opts.surface through
# UI.ResolveSurfaceStyle, which Theme.lua owns. In-game the manifest guarantees
# it (Theme.lua is listed before Round.lua and Popout.lua in DandersUI.xml);
# headless, nothing loads the theme half, so without this every suite that
# builds a popout would nil-call on the first adopt.
#
# ☠ THE REAL FUNCTIONS, NOT A COPY OF THEM. Theme.lua loads clean under the shim
# (it declares tables and functions and touches no frame at file scope), so it is
# loaded into a THROWAWAY namespace and exactly four names are lifted across.
# Re-implementing the resolver here would mean a test suite that agrees with a
# stub rather than with the library -- and `false means square, nil means ask the
# host` is precisely the kind of rule that drifts when it is written twice.
#
# The throwaway namespace is what keeps this surgical: Theme.lua also installs
# CreateElementBackdrop, the pixel border, the colour table and the whole box
# model, and every suite below stubs its own versions of those. None of that is
# copied over.
_theme_ns = lua.table()
_theme_ui = lua.table()
_theme_ui["_state"] = lua.table()
_theme_ui["_priv"] = lua.table()
_theme_ns["__DandersUI"] = _theme_ui
run(HERE.parents[1] / "DandersUI" / "Theme.lua", "DandersUI", _theme_ns)
for _name in ("SurfaceStyle", "ResolveSurfaceStyle", "SetSurfaceStyle", "GetSurfaceStyle"):
    ns["__DandersUI"][_name] = _theme_ui[_name]

# ⚠ THE PIXEL BORDER IS NOT LIFTED, either half, and the reason is the fake
# frames rather than the functions. FakeUIFrame's metatable answers EVERY unset
# key with a no-op function, so the real HidePixelBorder's `frame._pxBorder`
# comes back truthy and it indexes a function; the real ApplyPixelBorder builds
# textures and re-derives its weight from GetPhysicalScreenSize, which the shim
# does not answer. Both are stubbed instead -- ApplyPixelBorder per suite (each
# wants its own recording), HidePixelBorder here, because the rounded chrome
# helpers call it on every rounded paint and nothing asserts anything about it
# beyond "it was taken down".
ns["__DandersUI"]["HidePixelBorder"] = lua.eval(
    "function(_, frame) if frame then frame._pxHidden = true end return frame end")

# ...and Round.lua, for the same reason and with less ceremony: the popout's
# chrome paint calls UI:RemoveRoundedChrome / RemoveRoundedStrip on EVERY paint,
# square included (each shape has to take the other down -- see _PaintChrome), so
# every suite that builds a popout needs the module present even though none of
# the square ones ever draws a curve. It is a base-manifest file that loads
# before Popout.lua in-game, it declares no frames, and it is idempotent on a
# re-load -- test_round.lua loads it again under its own UI.MEDIA to pin the
# texture paths, and that re-load is what those assertions run against.
run(HERE.parents[1] / "DandersUI" / "Round.lua", "DandersUI", ns)

# DandersUndo-1.0's canonical home moved from DandersMover to DandersUI, so the
# resident DandersFrames addon gets the lib without the (optional) mover installed.
run(HERE.parents[1] / "DandersUI" / "Undo.lua", "DandersUI", ns)

for name in ("Locales/enUS.lua", "Solver.lua", "Fx.lua", "Registry.lua"):
    p = ADDON / name
    if p.exists():
        run(p, "DandersMover", ns)

# Tests that need a UI-facing module (Proxy.lua) load it themselves, after
# stubbing the frame API it touches: load_addon_file("Proxy.lua").
lua.globals().load_addon_file = lambda name: run(ADDON / name, "DandersMover", ns)
# The same door for a DandersUI file (Popout.lua). The SAME ns goes in, so the
# file's `NS.__DandersUI` finds the table Fx already installed onto -- the test
# stubs the kit surface it needs onto that table first, then loads.
lua.globals().load_ui_file = lambda name: run(HERE.parents[1] / "DandersUI" / name, "DandersUI", ns)
# ...and the same door with a ns of the CALLER's choosing. The options manifest's
# head builds the `NS.__DandersUI` handshake itself, so a test of that handshake
# has to hand it a FRESH namespace rather than the shared one above.
lua.globals().load_ui_file_into = lambda name, tns: run(HERE.parents[1] / "DandersUI" / name, "DandersUI", tns)
# ...and the same door for a DandersFrames file. Same reason it takes its own ns:
# a DF module's namespace IS the addon table, so a test stubs the DF surface it
# needs (Debug, the _Now bodies) onto a fresh table and hands that in.
lua.globals().load_df_file_into = lambda name, tns: run(HERE.parents[1] / "DandersFrames" / name, "DandersFrames", tns)
# ...and the same door for an options-companion file. ⚠ Those files take their
# host off the GLOBAL (`local DF = DandersFrames`), not off the varargs, so the
# namespace handed in here is inert -- a test of one stubs `DandersFrames`
# itself before loading. The arg is kept so every door reads the same.
lua.globals().load_options_file_into = lambda name, tns: run(HERE.parents[1] / "DandersFrames_Options" / name, "DandersFrames_Options", tns)
# Source text only, for a compile-only (loadstring) syntax check that must not
# run the file. Read here rather than in Lua so the path resolves the same way
# every other load does, whatever the cwd is.
lua.globals().ui_file_source = lambda name: (HERE.parents[1] / "DandersUI" / name).read_text(encoding="utf-8")
# ...and the same door for the options companion. A page file is far too tangled
# in the panel to LOAD headlessly, but a constant it declares (the popout rows'
# control counts) can still be read out of its source and asserted against what a
# builder actually mounts -- which beats copying the number into the test and
# letting the two drift.
lua.globals().options_file_source = lambda name: (HERE.parents[1] / "DandersFrames_Options" / name).read_text(encoding="utf-8")
# ...and the same door for the RESIDENT addon, for the same reason in the other
# direction: a constant declared there (the settings window's default size) has
# readers on both sides of the load-on-demand split, and a test that copied the
# number would stop describing what ships the moment one of them moved.
lua.globals().df_file_source = lambda name: (HERE.parents[1] / "DandersFrames" / name).read_text(encoding="utf-8")

# ============================================================
# STATIC BAN: lib files never call bare shadowed factory names.
# DF's host shadows CreateSlider/CreateDropdown/CreateAnchorGrid/CreateCheckbox/
# CreateEditBox/CreateButton/CreateLabel with POSITIONAL shims, so lib code
# calling `self:CreateButton(parent, opts)` mis-parses every argument under the
# DF host. Lib code must use the *Native aliases. This has shipped twice
# (the popout title label 2026-08-26, the footer buttons 2026-08-27); the grep
# makes a third time a red suite instead of an in-game error.
# ============================================================
import re as _re
_SHADOWED = "Label|Button|Checkbox|EditBox|Slider|Dropdown|AnchorGrid"
_ban = _re.compile(r"(?:self|host|po\.host|row\.host|UI)\s*:\s*Create(?:%s)\s*\(" % _SHADOWED)
_defn = _re.compile(r"function\s+UI\s*:\s*Create(?:%s)\s*\(" % _SHADOWED)
_viol = []
for _f in sorted((HERE.parent.parent / "DandersUI").glob("*.lua")):
    for _n, _line in enumerate(_f.read_text(encoding="utf-8").splitlines(), 1):
        _c = _line.split("--", 1)[0]
        if _ban.search(_c) and not _defn.search(_c) and "Native" not in _c:
            _viol.append(f"{_f.name}:{_n}: {_line.strip()}")
if _viol:
    print("SHIM-SHADOW BAN: lib code must call the *Native factory aliases:")
    for _v in _viol:
        print("  " + _v)
    sys.exit(1)

flt = sys.argv[1] if len(sys.argv) > 1 else ""
for test in sorted(HERE.glob("test_*.lua")):
    if flt and flt not in test.name:
        continue
    print(f"== {test.name}", flush=True)
    run(test, ns)
T = lua.globals().T
print(f"\n{T['pass']} passed, {T['fail']} failed")

# DandersFrames-side headless tests (real helpers extracted from the addon files)
# live beside these as test_*.py and run as their own processes.
import subprocess
py_failed = 0
for test in sorted(HERE.glob("test_*.py")):
    if flt and flt not in test.name:
        continue
    print(f"== {test.name}", flush=True)
    if subprocess.run([sys.executable, str(test)]).returncode != 0:
        py_failed += 1
sys.exit(1 if (T["fail"] or py_failed) else 0)
