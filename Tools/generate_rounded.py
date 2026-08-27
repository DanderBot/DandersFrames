#!/usr/bin/env python3
"""
Generate DandersUI/Media/Round/ -- the corner art for UI:CreateRoundedSurface.

A rounded surface is assembled from flat SetColorTexture strips (the straight
edges and the interior, which need no art at all) plus FOUR corner textures per
layer. Only the corners are curved, so only the corners are baked here.

Two shapes, both analytic, both quarter-turns of a circle centred on the corner
box's INNER corner:

    corner_fill_rN.tga     a quarter DISC   -- radius N, the interior's corner
    corner_edge_rN_wW.tga  a quarter ANNULUS -- outer N, inner N-W, the ring's
                           corner, anti-aliased on BOTH edges

ONE orientation is baked (the TOP-LEFT corner) and the other three are reached
with SetTexCoord's 8-argument form in Round.lua. Safe here in a way it is not
for a tiled texture: these are static, never wrapped, and both shapes are
symmetric about the diagonal, so a mirror and a quarter turn are the same
picture.

WHY THE SHAPES LINE UP WITH THE FLAT STRIPS. Take the top-left corner box, the
N x N square at the surface's top-left, image coordinates u right and v down.
The circle centre sits at (N, N) -- the box's INNER corner:

  * fill, at the box's right edge (u = N): covered where |v - N| <= N, i.e. the
    whole column. That is exactly the full-height top strip it butts against.
  * ring, at the same edge: covered where N-W <= N-v <= N, i.e. v in [0, W] --
    exactly the top border strip's thickness.

Both hold on the bottom edge by symmetry, so nothing overlaps and no seam is
left, at any radius or width.

Output matches the sibling icon art (Media/Icons/*.tga, see generate_pin.py):
32-bit BGRA, uncompressed (image type 2), top-left origin (descriptor 0x28),
flat white with the shape in the ALPHA channel so SetVertexColor tints it, and
no TGA 2.0 footer.

SIZE. The canvas targets SS px per radius unit and is then rounded UP to a power
of two, so a radius-6 corner is baked 32px square (not 24) and drawn at 6 UI
units. The oversampling is the point -- a rounded corner is a diagonal edge,
which is the case a 1:1 bake reads worst at, and the surface has to survive the
user's UI scale AND the settings window's own scale slider on top of it.

⚠ POWER OF TWO IS NOT COSMETIC. Every one of the ~90 textures this project
already ships is power-of-two, so an NPOT file here would be the first, and the
failure mode for one the client dislikes is a texture that silently does not
draw -- a black or absent corner with nothing in a log to explain it. Not worth
finding out in-game for 8px of file size, so: 16, 32, 32 for radii 4, 6, 8.

A consequence worth knowing: the quarter DISC is scale-invariant once
normalised, so corner_fill_r6 and corner_fill_r8 come out byte-identical (both
32px). They are still written as two files -- the naming stays uniform with the
arcs, which genuinely differ per radius because their inner/outer ratio does,
and a later per-radius shape tweak (a squircle, say) then has somewhere to go.

Anti-aliasing is analytic: SUB x SUB sub-samples per canvas pixel tested against
the maths, the same way generate_pin.py does it, so there is no downsample pass
and no resampling of an already-rasterised edge.

Run from anywhere:  python Tools/generate_rounded.py [repo-root]
"""

import os
import struct
import sys

# Canvas pixels per radius unit, before the power-of-two round-up. See SIZE.
SS = 4
# Sub-samples per axis -> 64 per canvas pixel.
SUB = 8

RADII = (4, 6, 8)
WIDTHS = (1, 2)


def canvas_for(n):
    """Texture size in px for a radius-n corner: n * SS, rounded UP to a power
    of two. See the POWER OF TWO note above -- this is not negotiable."""
    want = n * SS
    size = 1
    while size < want:
        size *= 2
    return size


def render(n, width=None):
    """Coverage rows (top -> bottom) for the TOP-LEFT corner, alpha 0..1.

    `n` is the radius in UI units; the canvas is canvas_for(n) px square, and
    the shape is mapped across it -- so the ROW COUNT changes with the round-up
    but the picture does not.
    `width` None renders the filled quarter disc; a number renders the quarter
    annulus with that border width (outer radius n, inner n - width).
    """
    size = canvas_for(n)
    r_out2 = float(n) * float(n)
    r_in2 = None
    if width is not None:
        inner = float(n) - float(width)
        # A width at or past the radius is a solid corner, not a ring.
        r_in2 = (inner * inner) if inner > 0.0 else None

    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            hit = 0
            for sy in range(SUB):
                for sx in range(SUB):
                    # Canvas px -> shape units, then offset to the circle
                    # centre at (n, n) -- the corner box's inner corner.
                    du = (px + (sx + 0.5) / SUB) * n / float(size) - n
                    dv = (py + (sy + 0.5) / SUB) * n / float(size) - n
                    d2 = du * du + dv * dv
                    if d2 <= r_out2 and (r_in2 is None or d2 >= r_in2):
                        hit += 1
            row.append(hit / float(SUB * SUB))
        rows.append(row)
    return rows


def write_tga(path, rows):
    h = len(rows)
    w = len(rows[0])
    # 0x28 = top-left origin (0x20) + 8 alpha bits (0x08). Matches the 64px
    # icons; neither those nor these carry the optional TGA 2.0 footer.
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x28)
    with open(path, "wb") as f:
        f.write(header)
        for row in rows:
            for a in row:
                f.write(bytes((255, 255, 255, int(round(255.0 * a)))))   # B, G, R, A


def ink(rows):
    """Total coverage, in whole pixels. A quarter disc of radius n rendered at
    SS px per unit should come out near pi/4 * (n*SS)^2 -- printed so a bad
    mapping is visible without opening the file."""
    return sum(sum(row) for row in rows)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    out = os.path.join(root, "DandersUI", "Media", "Round")
    os.makedirs(out, exist_ok=True)

    for n in RADII:
        size = canvas_for(n)
        rows = render(n)
        path = os.path.join(out, "corner_fill_r%d.tga" % n)
        write_tga(path, rows)
        print("wrote %s  %dx%d  ink %.1f px (ideal %.1f)" %
              (os.path.basename(path), size, size, ink(rows),
               3.14159265358979 / 4.0 * size * size))

        for w in WIDTHS:
            rows = render(n, w)
            path = os.path.join(out, "corner_edge_r%d_w%d.tga" % (n, w))
            write_tga(path, rows)
            inner = max(0, n - w) * size / float(n)
            print("wrote %s  %dx%d  ink %.1f px (ideal %.1f)" %
                  (os.path.basename(path), size, size, ink(rows),
                   3.14159265358979 / 4.0 * (size * size - inner * inner)))

    print("\n-> " + os.path.normpath(out))


if __name__ == "__main__":
    main()
