#!/usr/bin/env python3
"""Strip Lua comments from the addon sources at build time.

The repo keeps its comments; the packaged zip ships none. CI runs this with
--write just before the packager. Line breaks are preserved, so a line number
in a user's error report still points at the same line in the repo.

  --check                 dry run: strip in memory, run the bytecode gate, print sizes
  --write                 overwrite the files in place. CI ONLY (refuses unless CI=true)
  --comments-only REF     prove the working tree differs from git REF in comments only
  --selftest              run the built-in scanner fixtures

The bytecode gate compiles every file before and after stripping (Lua 5.1 via
lupa) and requires the two dumps to be byte-identical. Any mismatch exits 1
before a single file is written.
"""
import argparse
import os
import re
import subprocess
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ROOTS = ["DandersFrames", "DandersFrames_Options", "DandersMover", "DandersUI"]
# Libs is third-party (and licence headers); Locales carries every packager
# directive (--@do-not-package@, --@localization(...)@) and must reach the
# packager untouched.
EXCLUDE_DIRS = {"Libs", "Locales"}

LONG_OPEN = re.compile(r"\[(=*)\[")
DIRECTIVE = re.compile(r"--(\[=*\[)?\s*@")


def scan(src):
    """Yield (kind, text) covering src exactly. kind: code | string | comment."""
    i, n, start = 0, len(src), 0
    while i < n:
        c = src[i]
        if c == '"' or c == "'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
        elif c == "[" and LONG_OPEN.match(src, i):
            close = "]" + LONG_OPEN.match(src, i).group(1) + "]"
            j = src.find(close, i)
            j = n if j < 0 else j + len(close)
        elif c == "-" and src.startswith("--", i):
            m = LONG_OPEN.match(src, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i)
                j = n if j < 0 else j + len(close)
            else:
                j = src.find("\n", i)
                j = n if j < 0 else j
                if j > i and src[j - 1] == "\r":
                    j -= 1
            if start < i:
                yield "code", src[start:i]
            yield "comment", src[i:j]
            i = start = j
            continue
        else:
            i += 1
            continue
        if start < i:
            yield "code", src[start:i]
        yield "string", src[i:j]
        i = start = j
    if start < n:
        yield "code", src[start:n]


def strip(src):
    out = []
    for kind, text in scan(src):
        if kind != "comment" or DIRECTIVE.match(text):
            out.append(text)
            continue
        # Only the whitespace directly in front of the comment goes with it. That
        # run is code by construction, never the inside of a string.
        if out and out[-1] is not None:
            out[-1] = out[-1].rstrip(" \t")
        breaks = "".join(ch for ch in text if ch in "\r\n")
        out.append(breaks if breaks else (" " if text.startswith("--[") else ""))
    return "".join(out)


def chunks(src):
    """Comment-free, whitespace-insensitive view: strings verbatim, code split on whitespace."""
    out = []
    for kind, text in scan(src):
        if kind == "string":
            out.append(text)
        elif kind == "code":
            out.extend(text.split())
        elif DIRECTIVE.match(text):
            out.append(text)
    return out


def lua_files():
    for root in ROOTS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(REPO_ROOT, root)):
            dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDE_DIRS)
            for name in sorted(filenames):
                if name.endswith(".lua"):
                    yield os.path.join(dirpath, name)


def lua_runtime():
    try:
        from lupa import lua51 as mod
    except ImportError:
        try:
            import lupa as mod
        except ImportError:
            sys.exit("strip-comments: lupa is required for the bytecode gate (pip install lupa)")
    lua = mod.LuaRuntime(unpack_returned_tuples=True, encoding=None)
    dump = lua.eval(
        "function(s, name) local f, e = loadstring(s, name) "
        "if not f then return nil, e end return string.dump(f) end")
    return dump


def compile_or_die(dump, data, name, label):
    res = dump(data, name)
    if isinstance(res, tuple):
        sys.exit("strip-comments: %s does not parse: %s" % (label, res[1].decode("utf-8", "replace")))
    return res


def run_strip(write):
    if write and os.environ.get("CI") != "true":
        sys.exit("strip-comments: --write is CI only (it overwrites source files). Use --check.")
    dump = lua_runtime()
    before = after = 0
    results = []
    for path in lua_files():
        raw = open(path, "rb").read()
        new = strip(raw.decode("utf-8")).encode("utf-8")
        rel = os.path.relpath(path, REPO_ROOT).replace("\\", "/")
        name = ("@" + rel).encode("utf-8")
        if compile_or_die(dump, raw, name, rel) != compile_or_die(dump, new, name, rel + " (stripped)"):
            sys.exit("strip-comments: BYTECODE MISMATCH in %s -- nothing written." % rel)
        before += len(raw)
        after += len(new)
        results.append((path, new))
    if write:
        for path, new in results:
            with open(path, "wb") as fh:
                fh.write(new)
    print("strip-comments: %d files, bytecode identical. %.2f MB -> %.2f MB%s" % (
        len(results), before / 1e6, after / 1e6, " (written)" if write else " (dry run)"))


def run_comments_only(ref):
    dump = lua_runtime()
    out = subprocess.run(["git", "diff", "--name-only", ref, "--"] + ROOTS, cwd=REPO_ROOT,
                         capture_output=True, text=True, check=True).stdout.split()
    bad = checked = 0
    for rel in out:
        if not rel.endswith(".lua") or EXCLUDE_DIRS & set(rel.split("/")):
            continue
        path = os.path.join(REPO_ROOT, rel)
        if not os.path.exists(path):
            continue
        old = subprocess.run(["git", "show", "%s:%s" % (ref, rel)], cwd=REPO_ROOT, capture_output=True)
        if old.returncode != 0:
            continue
        new = open(path, "rb").read()
        checked += 1
        compile_or_die(dump, new, ("@" + rel).encode("utf-8"), rel)
        if chunks(old.stdout.decode("utf-8")) != chunks(new.decode("utf-8")):
            bad += 1
            print("CODE CHANGED: %s" % rel)
    print("strip-comments: %d changed files checked against %s, %d with code changes" % (checked, ref, bad))
    sys.exit(1 if bad else 0)


def run_selftest():
    cases = [
        ('local a = "--not a comment" -- gone', 'local a = "--not a comment"'),
        ("local b = '\\'--' .. x   -- gone", "local b = '\\'--' .. x"),
        ("local s = [[\n  keep --this  \n]] -- gone", "local s = [[\n  keep --this  \n]]"),
        ("local s = [==[ a ]] -- b ]==] --[[ gone ]] + 1", "local s = [==[ a ]] -- b ]==]  + 1"),
        ("x = 1 --[[ multi\nline ]] y = 2", "x = 1\n y = 2"),
        ("a = b --[[c]]- 1", "a = b - 1"),
        ("--@do-not-package@\nL.x = true\n--@end-do-not-package@", "--@do-not-package@\nL.x = true\n--@end-do-not-package@"),
        ("local t = x[y[1]] -- gone\r\nz = 1", "local t = x[y[1]]\r\nz = 1"),
        ("-- only\n\t-- only\ncode()", "\n\ncode()"),
    ]
    failed = 0
    for src, want in cases:
        got = strip(src)
        if got != want:
            failed += 1
            print("FAIL\n  src : %r\n  want: %r\n  got : %r" % (src, want, got))
    assert chunks("a = 1 -- x\n\n b=2") == chunks("a = 1\n b=2")
    assert chunks('a = "x" -- c') != chunks('a = "x " -- c')
    assert chunks("a = 1 -- c") != chunks("a = 2 -- c")
    print("strip-comments selftest: %d/%d passed" % (len(cases) - failed, len(cases)))
    sys.exit(1 if failed else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--comments-only", metavar="REF")
    mode.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        run_selftest()
    elif args.comments_only:
        run_comments_only(args.comments_only)
    else:
        run_strip(args.write)


if __name__ == "__main__":
    main()
