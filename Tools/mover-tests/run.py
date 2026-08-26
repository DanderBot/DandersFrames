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
for name in ("Locales/enUS.lua", "Undo.lua", "Solver.lua", "Fx.lua", "Registry.lua"):
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
# Source text only, for a compile-only (loadstring) syntax check that must not
# run the file. Read here rather than in Lua so the path resolves the same way
# every other load does, whatever the cwd is.
lua.globals().ui_file_source = lambda name: (HERE.parents[1] / "DandersUI" / name).read_text(encoding="utf-8")

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
