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
for name in ("Locales/enUS.lua", "Undo.lua", "Solver.lua", "Registry.lua"):
    p = ADDON / name
    if p.exists():
        run(p, "DandersMover", ns)

# Tests that need a UI-facing module (Proxy.lua) load it themselves, after
# stubbing the frame API it touches: load_addon_file("Proxy.lua").
lua.globals().load_addon_file = lambda name: run(ADDON / name, "DandersMover", ns)

flt = sys.argv[1] if len(sys.argv) > 1 else ""
for test in sorted(HERE.glob("test_*.lua")):
    if flt and flt not in test.name:
        continue
    print(f"== {test.name}")
    run(test, ns)
T = lua.globals().T
print(f"\n{T['pass']} passed, {T['fail']} failed")
sys.exit(1 if T["fail"] else 0)
