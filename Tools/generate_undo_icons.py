#!/usr/bin/env python3
"""
Generate DandersFrames/Media/Icons/undo.tga and redo.tga -- the settings
header's undo/redo glyphs.

The set had no undo symbol: the slots were built with chevron_left/chevron_right
as placeholders, and a bare chevron is the wrong word -- it means "previous page"
everywhere else in this UI (the profile carousel, the popout back arrow). The
Material `undo` shape says "put it back" and nothing else, so it is drawn here,
analytically, the way generate_scale_icon.py draws the header's scale glyph:
geometry in the icon's own 32px space, supersampled into coverage, written out as
flat white with the shape in the alpha channel so SetVertexColor tints it like
every sibling.

THE SHAPE. Material's `undo` is one stroke that leaves the head, runs right,
turns through a half circle and comes back left underneath itself:

    * a filled TRIANGLE head at the top left, pointing left;
    * a TOP BAR running right from the head to the ring;
    * a half-ANNULUS -- the right half of a ring -- which is the U-turn;
    * a BOTTOM BAR running back left from the bottom of the ring, longer than
      the top one, so the tail reads as passing under the head rather than
      stopping level with it.

The bars butt onto the ring exactly: each bar's centreline sits on the ring's
mid-radius, so the two pieces share an edge at the tangent point and there is no
step to hide. `redo.tga` is the SAME geometry sampled mirrored in x -- one shape,
two files, so the pair cannot drift apart.

WEIGHT. Authored directly at final size, with no fit pass, because the numbers
are already chosen against the siblings: the ink fills x/y 3..29 like close.tga,
refresh.tga and open_in_full.tga do, and the 2.8px stroke lands the coverage at
~16% -- refresh.tga is 16.5%, sync.tga 13.7%. A glyph fitted to the canvas
instead would have come out at ~22%, which reads as a bolder icon sitting next to
the Test and Unlock buttons rather than as one of them.

Output matches the sibling 32px icons byte-for-byte in format: 32x32, 32-bit
BGRA, uncompressed (image type 2), BOTTOM-left origin (descriptor 0x08), plus
the TGA 2.0 footer they all carry.

Run from anywhere:  python generate_undo_icons.py [repo-root] [--preview]
"""

import os
import struct
import sys

W = H = 32
SUB = 6           # sub-samples per axis -> 36 per pixel
MARGIN = 3.0      # the clear border close.tga / refresh.tga keep

# --- the glyph, in the icon's own 32px space (y DOWN, like the drawing) -----
#
# Stroke: 2.8px, i.e. half-width 1.4. Measured off refresh.tga and sync.tga,
# which are the two other arc-and-arrow glyphs in the set.
HW = 1.4

# The U-turn. A half annulus, the RIGHT half (x >= CX), so the ring opens LEFT
# towards the head and the bars. Its outer edge is the icon's right margin:
# CX + R + HW = 29.
R = 7.6
CX, CY = 20.0, 17.8
R_OUT, R_IN = R + HW, R - HW

# The two bars, each centred on the ring's mid-radius so it meets the ring at the
# tangent point with a flat, seamless butt joint.
TOP_Y = CY - R                  # 10.2
BOT_Y = CY + R                  # 25.4
TOP_L = 11.5                    # left end of the top bar (buried in the head)
BOT_L = 9.0                     # ...and of the bottom bar, which reaches further

# The head: an isoceles triangle pointing LEFT, its apex on the top bar's
# centreline and its base standing just right of where the bar begins, so the two
# overlap rather than meeting at a seam that anti-aliasing would show as a notch.
TIP_X = MARGIN                  # 3.0 -- the left margin
BASE_X = 11.8
HEAD_HH = 5.0                   # half-height at the base


def inside(x, y):
    """Is (x, y) in the UNDO glyph? The union of head, two bars and the ring."""
    # Ring: the right half of the annulus.
    if x >= CX:
        d2 = (x - CX) ** 2 + (y - CY) ** 2
        if R_IN * R_IN <= d2 <= R_OUT * R_OUT:
            return True
    # Bars.
    if TOP_L <= x <= CX and abs(y - TOP_Y) <= HW:
        return True
    if BOT_L <= x <= CX and abs(y - BOT_Y) <= HW:
        return True
    # Head: half-height grows linearly from 0 at the tip to HEAD_HH at the base.
    if TIP_X <= x <= BASE_X:
        hh = HEAD_HH * (x - TIP_X) / (BASE_X - TIP_X)
        if abs(y - TOP_Y) <= hh:
            return True
    return False


def render(size, mirror=False):
    """Coverage rows, TOP row first, each entry an alpha 0..1.

    `mirror` flips the SAMPLING in x rather than the geometry, so redo.tga is
    the exact reflection of undo.tga -- same maths, same anti-aliasing, no second
    set of numbers to keep in step.
    """
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            hit = 0
            for sy in range(SUB):
                for sx in range(SUB):
                    x = px + (sx + 0.5) / SUB
                    y = py + (sy + 0.5) / SUB
                    if mirror:
                        x = size - x
                    if inside(x, y):
                        hit += 1
            row.append(hit / float(SUB * SUB))
        rows.append(row)
    return rows


def write_tga(path, rows):
    size = len(rows)
    # 0x08 = bottom-left origin + 8 alpha bits, which is what every 32px icon in
    # this folder uses -- so the coverage rows go out BOTTOM first.
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 0x08)
    with open(path, "wb") as f:
        f.write(header)
        for row in reversed(rows):
            for a in row:
                f.write(bytes((255, 255, 255, int(round(255.0 * a)))))   # B, G, R, A
        f.write(b"\x00" * 8 + b"TRUEVISION-XFILE." + b"\x00")


def report(name, rows):
    """Coverage, ink box and an ASCII preview -- the only way to eyeball a glyph
    that nothing in this toolchain can render."""
    total, xs, ys = 0.0, [], []
    for y, row in enumerate(rows):
        for x, a in enumerate(row):
            total += a
            if a > 0.0:
                xs.append(x)
                ys.append(y)
    print("  %s: coverage %.1f%%, ink box x %d..%d  y %d..%d"
          % (name, 100.0 * total / (len(rows) ** 2), min(xs), max(xs), min(ys), max(ys)))
    for row in rows:
        print("  " + "".join("#" if a > 0.6 else ("." if a > 0.15 else " ") for a in row))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    preview_only = "--preview" in sys.argv[1:]
    root = args[0] if args else os.getcwd()
    out_dir = os.path.join(root, "DandersFrames", "Media", "Icons")

    for name, mirror in (("undo", False), ("redo", True)):
        rows = render(W, mirror)
        if not preview_only:
            path = os.path.join(out_dir, name + ".tga")
            write_tga(path, rows)
            print("wrote", os.path.normpath(path))
        report(name, rows)


if __name__ == "__main__":
    main()
