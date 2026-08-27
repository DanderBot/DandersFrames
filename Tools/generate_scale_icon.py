#!/usr/bin/env python3
"""
Generate DandersFrames/Media/Icons/open_in_full.tga -- the settings header's
UI-scale glyph (the Material `open_in_full` shape, the ⤢ the two-deck header
asks for).

The set had no scale/resize symbol: the closest existing glyphs are a 3x3 widget
grid, a gear and a pair of chevrons, none of which reads as "how big is this
window". So the shape is drawn here, analytically, the same way generate_pin.py
draws the popout's pin -- geometry in the icon's own 32px space, supersampled
into coverage, written out as flat white with the shape in the alpha channel so
SetVertexColor tints it like every sibling.

The glyph is two arrows along the "/" diagonal: a corner triangle at the
top-right, one at the bottom-left, and a shaft joining them.

Output matches the sibling 32px icons (notes.tga, close.tga) byte-for-byte in
format: 32x32, 32-bit BGRA, uncompressed (image type 2), BOTTOM-left origin
(descriptor 0x08), plus the TGA 2.0 footer they all carry.

Run from anywhere:  python generate_scale_icon.py <repo-root>
"""

import os
import struct
import sys

W = H = 32
SUB = 4           # sub-samples per axis -> 16 per pixel

# --- the glyph, in the icon's own 32px space (y DOWN, like the drawing) -----
# Corner arrowheads. Each is a right triangle hugging its corner; the numbers
# are its two legs' extents plus the hypotenuse that faces the shaft.
MARGIN = 3.0
FAR = W - MARGIN            # 29: the far edge on both axes
HEAD = 11.0                 # leg length -- the same fill weight as close.tga

# Shaft: a stroke along the "/" diagonal. Each end sits PAST the head's
# hypotenuse, at the triangle's midline -- the stroke buries ~2 units into the
# head, so the three pieces genuinely overlap instead of stopping short (the
# first version ended the shaft ~5 units shy of each hypotenuse and the arrows
# read as detached -- Danders, 2026-08-27).
SHAFT_A = (MARGIN + HEAD / 2 - 1.0, FAR - HEAD / 2 + 1.0)   # bottom-left end
SHAFT_B = (FAR - HEAD / 2 + 1.0, MARGIN + HEAD / 2 - 1.0)   # top-right end
SHAFT_HW = 1.5                                        # half-width -> 3px stroke


def _seg_dist2(px, py, ax, ay, bx, by):
    """Squared distance from (px, py) to the segment AB."""
    dx, dy = bx - ax, by - ay
    den = dx * dx + dy * dy
    t = 0.0 if den == 0.0 else ((px - ax) * dx + (py - ay) * dy) / den
    t = max(0.0, min(1.0, t))
    qx, qy = ax + t * dx, ay + t * dy
    return (px - qx) ** 2 + (py - qy) ** 2


def inside(x, y):
    """Is (x, y) in the glyph? The union of the two heads and the shaft."""
    # Top-right head: vertices (FAR-HEAD, MARGIN), (FAR, MARGIN), (FAR, MARGIN+HEAD).
    # Its hypotenuse is y = x - (FAR - HEAD - MARGIN); the interior is above it.
    if y >= MARGIN and x <= FAR and y <= x - (FAR - HEAD - MARGIN):
        return True
    # Bottom-left head, the same triangle turned through half a turn.
    if x >= MARGIN and y <= FAR and y >= x + (FAR - HEAD - MARGIN):
        return True
    if _seg_dist2(x, y, SHAFT_A[0], SHAFT_A[1], SHAFT_B[0], SHAFT_B[1]) <= SHAFT_HW ** 2:
        return True
    return False


def render(size):
    """Coverage rows, TOP row first, each entry an alpha 0..1."""
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            hit = 0
            for sy in range(SUB):
                for sx in range(SUB):
                    if inside(px + (sx + 0.5) / SUB, py + (sy + 0.5) / SUB):
                        hit += 1
            row.append(hit / float(SUB * SUB))
        rows.append(row)
    return rows


def write_tga(path, rows):
    size = len(rows)
    # 0x08 = bottom-left origin + 8 alpha bits, which is what notes.tga and
    # close.tga use -- so the coverage rows go out BOTTOM first.
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 0x08)
    with open(path, "wb") as f:
        f.write(header)
        for row in reversed(rows):
            for a in row:
                f.write(bytes((255, 255, 255, int(round(255.0 * a)))))   # B, G, R, A
        f.write(b"\x00" * 8 + b"TRUEVISION-XFILE." + b"\x00")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    out = os.path.join(root, "DandersFrames", "Media", "Icons", "open_in_full.tga")
    rows = render(W)
    write_tga(out, rows)
    print("wrote", os.path.normpath(out))
    for row in rows:
        print("".join("#" if a > 0.6 else ("." if a > 0.15 else " ") for a in row))


if __name__ == "__main__":
    main()
