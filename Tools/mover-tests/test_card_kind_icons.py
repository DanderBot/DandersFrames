"""Guard for the settings cards' kind icons (see test_card_kind_icons.lua for
the header itself).

  * every kind in GUI.SectionCard.kinds (SettingsWidgets.lua) points at a
    texture that exists in DandersFrames/Media/Icons, at the icon spec
    (32x32, 32-bit, uncompressed, bottom-left origin, TGA 2.0 footer);
  * every kind used in GUI.SectionKindByKey (Controls.lua) is in that map;
  * every collapseKey tagged there is a real section key on some page, so a
    typo cannot silently leave a card without its icon.

Usage: python Tools/mover-tests/test_card_kind_icons.py
"""
import pathlib, re, struct, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SW = (ROOT / "DandersFrames_Options/GUI/SettingsWidgets.lua").read_text(encoding="utf-8")
CTRL = (ROOT / "DandersFrames_Options/GUI/Controls.lua").read_text(encoding="utf-8")
PAGES = "\n".join(p.read_text(encoding="utf-8")
                  for p in sorted((ROOT / "DandersFrames_Options/GUI/Pages").glob("*.lua")))

fails = 0
passes = 0


def check(cond, msg):
    global fails, passes
    if cond:
        passes += 1
    else:
        fails += 1
        print("  FAIL: " + msg)


print("-- Card kind icons: map -> files on disk, tags -> map, tags -> real keys")

m = re.search(r"GUI\.SectionCard\.kinds = \{(.*?)\n    \}", SW, re.S)
check(m is not None, "map: GUI.SectionCard.kinds found in SettingsWidgets.lua")
kinds = dict(re.findall(r'(\w+)\s*=\s*ICONS \.\. "(\w+)"', m.group(1))) if m else {}
check(len(kinds) == 13, "map: 13 kinds (got %d)" % len(kinds))
check(re.search(r'local ICONS = "Interface\\\\AddOns\\\\DandersFrames\\\\Media\\\\Icons\\\\"', SW) is not None,
      "map: textures resolve under the resident addon's Media/Icons")

ICON_DIR = ROOT / "DandersFrames/Media/Icons"
for kind, name in sorted(kinds.items()):
    path = ICON_DIR / (name + ".tga")
    check(path.is_file(), "file: kind %r -> %s.tga exists" % (kind, name))
    if not path.is_file():
        continue
    data = path.read_bytes()
    idlen, cmap, itype = data[0], data[1], data[2]
    w, h, bpp, desc = struct.unpack("<HHBB", data[12:18])
    check((itype, w, h, bpp, desc) == (2, 32, 32, 32, 0x08),
          "file: %s.tga is 32x32 BGRA uncompressed, bottom-left origin" % name)
    check(data.endswith(b"TRUEVISION-XFILE.\x00"), "file: %s.tga carries the TGA 2.0 footer" % name)

check(kinds.get("filters") == "filter_header",
      "map: filters uses the refitted filter_header, never the smaller filter_alt")

t = re.search(r"GUI\.SectionKindByKey = \{(.*?)\n\}", CTRL, re.S)
check(t is not None, "tags: GUI.SectionKindByKey found in Controls.lua")
tags = re.findall(r'^\s*(\w+)\s*=\s*"(\w+)",', t.group(1), re.M) if t else []
check(len(tags) > 50, "tags: the table is populated (%d tags)" % len(tags))
seen = set()
for key, kind in tags:
    check(key not in seen, "tags: %s is tagged once" % key)
    seen.add(key)
    check(kind in kinds, "tags: %s -> %r is a kind in GUI.SectionCard.kinds" % (key, kind))
    check(re.search(r'OpenSection\([^\n]*"%s"' % re.escape(key), PAGES) is not None,
          "tags: %s is a real section key on a settings page" % key)

# Nobody tags from a title: a page that passes kind itself must use the map too.
for kind in re.findall(r'\bkind\s*=\s*"(\w+)"', PAGES):
    check(kind in kinds, "pages: kind = %r used on a page is in the map" % kind)

print("%d passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
