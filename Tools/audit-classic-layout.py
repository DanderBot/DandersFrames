"""Audit: does anything in the Classic settings layout go missing in Modern?

Usage:  python Tools/audit-classic-layout.py [--all] [page-filter]

For every settings page builder (`BuildPage(pageX, function ... end)`) in the
companion's page files, this walks the builder TWICE -- once as the Classic
layout would run it, once as Modern would -- and collects what each run can
reach:

  key     a string literal handed to a control (db keys, customGet/Set keys,
          copy-button key lists, section ids ...)
  field   a `db.X` / `d.X` / `DF.db.X` read or write
  label   an `L["..."]` string (control labels, button captions, tooltips)
  call    a `GUI:CreateX` / `GUI.X` / `tools.X` / `DF:X` / `UI:X` call

"Walking as Classic" means: inside `if classicLayout then A else B end` only A
is taken (B for Modern; `if not classicLayout` is the mirror), and in the
ternary `classicLayout and A or B` A is dropped for Modern. Every local
function the builder references (by name, e.g. a `Build<X>Group` handed to
both arms, or passed to OpenSection as a pane builder) is expanded in place
under the same layout, recursively, so a builder both arms share counts for
both and an `if classicLayout` inside a shared builder is honoured.

The report is every item Classic reaches that Modern does not, with the
file:line where Classic reaches it. Labels and layout-only calls (the classic
box furniture: CreateSettingsGroup, CreateHeader, CreateCollapsibleSection,
AddSpace ...) are hidden unless --all is passed; keys, fields, button captions
and control calls are always shown. The output is a list to REVIEW, not a
verdict: a key can legitimately live in a header tick or a merged card.

Pure text analysis -- nothing is loaded or run.
"""
import sys, re, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
PAGE_FILES = sorted((ROOT / "DandersFrames_Options" / "GUI" / "Pages").glob("*.lua"))

# ---------------------------------------------------------------- tokenizer
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
NUM_RE = re.compile(r"0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?")
LONG_OPEN = re.compile(r"\[(=*)\[")
SYMS3 = ("...",)
SYMS2 = ("..", "==", "~=", "<=", ">=")


def tokenize(src):
    toks = []          # (kind, value, line)
    i, n, line = 0, len(src), 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1; i += 1; continue
        if c in " \t\r":
            i += 1; continue
        if src.startswith("--", i):
            m = LONG_OPEN.match(src, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                j = n if j < 0 else j + len(close)
            else:
                j = src.find("\n", i)
                j = n if j < 0 else j
            line += src.count("\n", i, j); i = j; continue
        m = LONG_OPEN.match(src, i)
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, m.end())
            j = n if j < 0 else j
            toks.append(("str", src[m.end():j], line))
            line += src.count("\n", i, j); i = j + len(close); continue
        if c in "\"'":
            j, buf = i + 1, []
            while j < n and src[j] != c:
                if src[j] == "\\":
                    buf.append(src[j:j + 2]); j += 2
                else:
                    if src[j] == "\n":
                        line += 1
                    buf.append(src[j]); j += 1
            toks.append(("str", "".join(buf), line)); i = j + 1; continue
        m = NAME_RE.match(src, i)
        if m:
            toks.append(("name", m.group(0), line)); i = m.end(); continue
        m = NUM_RE.match(src, i)
        if m and m.group(0):
            toks.append(("num", m.group(0), line)); i = m.end(); continue
        for s in SYMS3 + SYMS2:
            if src.startswith(s, i):
                toks.append(("sym", s, line)); i += len(s); break
        else:
            toks.append(("sym", c, line)); i += 1
    return toks


def is_kw(t, v):
    return t[0] == "name" and t[1] == v


# ---------------------------------------------------------------- structure
class FileModel:
    def __init__(self, path):
        self.path = path
        self.rel = path.relative_to(ROOT).as_posix()
        self.toks = tokenize(path.read_text(encoding="utf-8"))
        self.match = {}      # opener index -> closer index (function/if/do/repeat)
        self.branches = {}   # if index -> [then/else/elseif indices]
        self._match_blocks()
        self.defs = []       # (name, is_field, body_start, body_end, def_start)
        self._find_defs()

    def _match_blocks(self):
        stack = []
        toks = self.toks
        for i, t in enumerate(toks):
            if t[0] != "name":
                continue
            v = t[1]
            # `a.end` / `a:do` cannot happen (keywords), but a field named like
            # a keyword can't either -- Lua forbids it -- so no guard needed.
            if v in ("function", "if", "do", "repeat"):
                stack.append(i)
                if v == "if":
                    self.branches[i] = []
            elif v in ("else", "elseif"):
                # belongs to the innermost open `if`
                for k in range(len(stack) - 1, -1, -1):
                    if toks[stack[k]][1] == "if":
                        self.branches[stack[k]].append(i); break
            elif v in ("end", "until"):
                if stack:
                    self.match[stack.pop()] = i
        # `while X do` / `for ... do`: the `do` is the opener, fine.

    def _find_defs(self):
        toks = self.toks
        for i, t in enumerate(toks):
            if not is_kw(t, "function"):
                continue
            # function Name ( / function A.B ( / function A:B (
            j = i + 1
            if j < len(toks) and toks[j][0] == "name":
                names = [toks[j][1]]
                j += 1
                while j + 1 < len(toks) and toks[j][1] in (".", ":") and toks[j + 1][0] == "name":
                    names.append(toks[j + 1][1]); j += 2
                end = self.match.get(i)
                if end is not None:
                    start = i - 1 if (i > 0 and is_kw(toks[i - 1], "local")) else i
                    self.defs.append((names[-1], len(names) > 1, i, end, start))
                continue
            # local Name = function (   -- ONLY the local form: `key = function`
            # inside a table constructor (onClick = function ...) is a callback
            # that belongs to the control it sits in, and is walked inline.
            if i >= 3 and toks[i - 1][1] == "=" and toks[i - 2][0] == "name" and is_kw(toks[i - 3], "local"):
                end = self.match.get(i)
                if end is not None:
                    self.defs.append((toks[i - 2][1], False, i, end, i - 3))
        self.def_at = {d[4]: d for d in self.defs}

    def def_starting_at(self, i):
        return self.def_at.get(i)

    def resolve(self, name, is_field, at, page_range):
        cands = [d for d in self.defs if d[0] == name and d[1] == is_field]
        if not cands:
            return None
        lo, hi = page_range
        inside = [d for d in cands if lo <= d[2] <= hi and d[2] <= at]
        if inside:
            return max(inside, key=lambda d: d[2])
        before = [d for d in cands if d[2] <= at and not (lo <= d[2] <= hi)]
        if before:
            return max(before, key=lambda d: d[2])
        return min(cands, key=lambda d: abs(d[2] - at))


# ---------------------------------------------------------------- the walk
DB_TABLES = {"db", "d", "dbTable", "pdb", "rdb", "gdb"}


def classic_cond(toks, i, then_i):
    """For `if <cond> then`, return 'classic', 'modern' or None."""
    cond = [t[1] for t in toks[i + 1:then_i]]
    if cond == ["classicLayout"]:
        return "classic"
    if cond == ["not", "classicLayout"]:
        return "modern"
    if cond in (["DF", ":", "IsClassicSettingsLayout", "(", ")"],):
        return "classic"
    if cond in (["not", "DF", ":", "IsClassicSettingsLayout", "(", ")"],):
        return "modern"
    return None


class Walker:
    def __init__(self, fm, page_range, mode):
        self.fm, self.page_range, self.mode = fm, page_range, mode
        self.items = {}           # item -> first line
        self.expanding = set()
        self.notes = []

    def add(self, item, line):
        self.items.setdefault(item, line)

    def walk(self, a, b):
        """Walk tokens [a, b)."""
        toks, fm = self.fm.toks, self.fm
        i = a
        while i < b:
            t = toks[i]
            # ---- a named function definition: skip, it runs only when referenced
            d = fm.def_starting_at(i)
            if d is not None:
                i = d[3] + 1
                continue
            # ---- if classicLayout / if not classicLayout
            if is_kw(t, "if"):
                end = fm.match.get(i)
                brs = fm.branches.get(i, [])
                then_i = next((k for k in range(i + 1, end or b) if is_kw(toks[k], "then")), None)
                which = classic_cond(toks, i, then_i) if then_i else None
                if which and end is not None:
                    if any(toks[k][1] == "elseif" for k in brs):
                        self.notes.append(f"{fm.rel}:{t[2]}: elseif on a layout branch -- walked both arms")
                    else:
                        els = brs[0] if brs else None
                        first = (then_i + 1, els if els is not None else end)
                        second = (els + 1, end) if els is not None else None
                        take = first if which == self.mode else second
                        if take:
                            self.walk(*take)
                        i = end + 1
                        continue
            # ---- ternary: classicLayout and A or B  (A is classic-only)
            if t[0] == "name" and t[1] == "classicLayout" and i + 1 < b and is_kw(toks[i + 1], "and"):
                j, depth = i + 2, 0
                while j < b:
                    v = toks[j][1] if toks[j][0] in ("sym", "name") else None
                    if toks[j][0] == "name" and v in ("function", "if", "do") and j in fm.match:
                        j = fm.match[j] + 1; continue
                    if v in ("(", "{", "["):
                        depth += 1
                    elif v in (")", "}", "]"):
                        depth -= 1
                    elif v == "or" and depth == 0:
                        break
                    j += 1
                if self.mode == "classic":
                    self.walk(i + 2, j)
                i = j + 1
                continue
            # ---- collection
            if t[0] == "str":
                if i >= 2 and toks[i - 1][1] == "[" and toks[i - 2][1] == "L":
                    self.add(("label", t[1]), t[2])
                elif NAME_RE.fullmatch(t[1]):
                    self.add(("key", t[1]), t[2])
                    # ...and, separately, the key as BOUND TO A CONTROL: the
                    # innermost open call around it is a widget factory. A key
                    # Modern only mentions (a summary, a reset list) but never
                    # hands to a control is a key the user cannot edit there.
                    owner = self.enclosing_call(i)
                    if owner:
                        self.add(("bound", t[1]), t[2])
            elif t[0] == "name":
                prev = toks[i - 1][1] if i > 0 else ""
                nxt = toks[i + 1][1] if i + 1 < len(toks) else ""
                if prev in (".", ":") and i >= 2:
                    owner = toks[i - 2][1]
                    if owner in DB_TABLES and prev == ".":
                        self.add(("field", t[1]), t[2])
                    elif owner in ("GUI", "tools", "UI", "DF", "Search") and nxt == "(":
                        self.add(("call", f"{owner}{prev}{t[1]}"), t[2])
                    # expand a field-defined local helper (P.BuildX / GUI:BuildX in this file)
                    if nxt in ("(", ",", ")", "}"):
                        self.expand(t[1], True, i)
                else:
                    self.expand(t[1], False, i)
            i += 1

    def enclosing_call(self, i):
        """Name of the widget factory whose argument list token i sits in, or None."""
        toks = self.fm.toks
        depth, j = 0, i - 1
        while j > 0 and i - j < 400:
            v = toks[j][1] if toks[j][0] == "sym" else None
            if v in (")", "}"):
                depth += 1
            elif v in ("(", "{"):
                if depth == 0:
                    if v == "(" and toks[j - 1][0] == "name":
                        name = toks[j - 1][1]
                        if name.startswith("Create") or name.startswith("Add") and name.endswith("Toggle"):
                            return name
                        if j >= 3 and toks[j - 3][1] == "tools":
                            return name
                    if v == "(":
                        return None
                else:
                    depth -= 1
            j -= 1
        return None

    def expand(self, name, is_field, at):
        d = self.fm.resolve(name, is_field, at, self.page_range)
        if d is None:
            return
        # a reference to itself at its own definition site is not a call
        if d[4] <= at <= d[2] + 1:
            return
        key = (d[2], self.mode)
        if key in self.expanding:
            return
        self.expanding.add(key)
        self.walk(d[2] + 1, d[3])
        # expanding stays set: one expansion per function per walk is enough


# ---------------------------------------------------------------- pages
def find_pages(fm):
    toks = fm.toks
    tab_ids = {}
    for i in range(len(toks) - 6):
        if toks[i][1] == "CreateSubTab" and toks[i + 1][1] == "(" and toks[i - 1][1] == "=" and toks[i - 2][0] == "name":
            args = [toks[k][1] for k in range(i + 2, min(i + 12, len(toks))) if toks[k][0] == "str"]
            tab_ids[toks[i - 2][1]] = args[1] if len(args) > 1 else toks[i - 2][1]
    pages = []
    for i in range(len(toks) - 4):
        if toks[i][1] == "BuildPage" and toks[i + 1][1] == "(" and toks[i + 3][1] == "," and is_kw(toks[i + 4], "function"):
            fn = i + 4
            end = fm.match.get(fn)
            if end is None:
                continue
            var = toks[i + 2][1]
            pages.append((tab_ids.get(var, var), toks[i][2], fn, end))
    return pages


FURNITURE_CALLS = {
    "GUI:CreateSettingsGroup", "GUI:CreateHeader", "GUI:CreateCollapsibleSection",
    "GUI:CreatePopoutPageTools", "GUI:CreateLabel", "GUI:CreateNote", "GUI:CreateSeparator",
    "GUI:GroupInnerWidth",
}


def audit(fm, page, show_all):
    pid, line, fn, end = page
    rng = (fn, end)
    res = {}
    for mode in ("classic", "modern"):
        w = Walker(fm, rng, mode)
        w.walk(fn + 1, end)
        res[mode] = w
    c, m = res["classic"].items, res["modern"].items
    missing = []
    for item, ln in sorted(c.items(), key=lambda kv: kv[1]):
        if item in m:
            continue
        kind, val = item
        if not show_all:
            if kind == "call" and val in FURNITURE_CALLS:
                continue
            if kind == "label":
                continue
        missing.append((kind, val, ln))
    return missing, res["classic"].notes + res["modern"].notes


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show_all = "--all" in sys.argv
    flt = args[0] if args else None
    total = 0
    notes = set()
    for path in PAGE_FILES:
        fm = FileModel(path)
        for page in find_pages(fm):
            if flt and flt not in page[0]:
                continue
            missing, nts = audit(fm, page, show_all)
            notes.update(nts)
            if not missing:
                continue
            print(f"== {page[0]}  ({fm.rel}:{page[1]})")
            for kind, val, ln in missing:
                print(f"   {kind:6} {val!r:50}  {fm.rel}:{ln}")
                total += 1
    for n in sorted(notes):
        print("NOTE", n)
    print(f"\n{total} item(s) reachable in Classic but not in Modern.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
