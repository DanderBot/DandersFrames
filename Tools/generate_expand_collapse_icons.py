#!/usr/bin/env python3
"""
Generate DandersFrames/Media/Icons/expand_content.tga and
collapse_content.tga -- the glyphs on every settings page's Expand All /
Collapse All buttons.

THE SHAPE. Material's `expand_content` / `collapse_content` pair: two L-shaped
corner brackets on a diagonal, drawn as the corners of a box being pulled apart
or pushed together.

    expand    brackets hug the TOP-RIGHT and BOTTOM-LEFT extremes, their arms
              running back towards the centre -- the box is at its biggest, so
              the corners sit on the canvas bounds.
    collapse  the SAME two brackets, turned through 180 degrees so each corner
              faces the middle, and pulled INSET -- the box has been drawn in.

One diagonal for both, so the pair reads as one gesture reversed rather than as
two unrelated glyphs. Geometry is axis-aligned rectangles in the icon's own 32px
space, supersampled into coverage, written as flat white with the shape in the
alpha channel so SetVertexColor tints them like every sibling.

WEIGHT. Authored at final size against the siblings, the way
generate_undo_icons.py does: the ink fills x/y 3..29 like close.tga,
refresh.tga and open_in_full.tga, and the 3.4px stroke keeps the coverage in the
13-17% band those carry.

Output matches the sibling 32px icons byte-for-byte in format: 32x32, 32-bit
BGRA, uncompressed (image type 2), BOTTOM-left origin (descriptor 0x08), plus
the TGA 2.0 footer they all carry.

Run from anywhere:  python generate_expand_collapse_icons.py <repo-root>
                    python generate_expand_collapse_icons.py --preview
"""

import os
import struct
import sys

W = 32          # canvas, and the siblings' size
LO, HI = 3.0, 29.0      # the ink box every 32px sibling fills
T = 3.4         # stroke thickness
ARM = 11.0      # how far each arm runs from its corner
INSET = 4.0     # how far collapse's corners are drawn in from the bounds
SS = 4          # supersampling per axis


def bracket(cx, cy, dx, dy):
    """One L: the corner at (cx, cy), arms running ARM px along -dx and -dy."""
    # The stroke lies on the INSIDE of its corner: a corner at the right bound
    # grows leftwards, one at the left bound grows rightwards. (Drawn the other
    # way round, the arms of the bound-hugging expand glyph fall off the canvas.)
    x0 = cx - T if dx > 0 else cx
    x1 = x0 + T
    y0 = cy - T if dy > 0 else cy
    y1 = y0 + T
    # The horizontal arm runs back along x, the vertical one back along y; both
    # start at the corner so the join is solid rather than two rects meeting.
    hx0 = cx - ARM if dx > 0 else cx
    hx1 = hx0 + ARM
    vy0 = cy - ARM if dy > 0 else cy
    vy1 = vy0 + ARM
    return [
        (hx0, hx1, y0, y1),     # horizontal arm
        (x0, x1, vy0, vy1),     # vertical arm
    ]


def rects(expand):
    # One diagonal for both glyphs -- top-right and bottom-left -- so the pair
    # reads as one gesture reversed.
    if expand:
        # Corners ON the bounds, arms running back towards the middle.
        return (bracket(HI, LO, 1, -1)      # top right
                + bracket(LO, HI, -1, 1))   # bottom left
    # Turned through 180: each corner faces the middle and its arms run OUT to
    # the bounds. The corner therefore sits one arm in, so nothing clips.
    return (bracket(HI - ARM, LO + ARM, -1, 1)      # top right, pulled in
            + bracket(LO + ARM, HI - ARM, 1, -1))   # bottom left, pulled in


def render(expand):
    boxes = rects(expand)
    rows = []
    step = 1.0 / SS
    for y in range(W):
        row = []
        for x in range(W):
            hits = 0
            for sy in range(SS):
                py = y + (sy + 0.5) * step
                for sx in range(SS):
                    px = x + (sx + 0.5) * step
                    for (x0, x1, y0, y1) in boxes:
                        if x0 <= px <= x1 and y0 <= py <= y1:
                            hits += 1
                            break
            row.append(hits / float(SS * SS))
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
        print("    " + "".join("#" if a > 0.6 else ("+" if a > 0.15 else ".") for a in row))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    preview_only = "--preview" in sys.argv[1:]
    root = args[0] if args else os.getcwd()
    out_dir = os.path.join(root, "DandersFrames", "Media", "Icons")

    for name, expand in (("expand_content", True), ("collapse_content", False)):
        rows = render(expand)
        if not preview_only:
            path = os.path.join(out_dir, name + ".tga")
            write_tga(path, rows)
            print("wrote", os.path.normpath(path))
        report(name, rows)


if __name__ == "__main__":
    main()
