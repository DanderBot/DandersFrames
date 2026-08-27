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

☠ SIZE -- REWRITTEN 2026-08-27, AND THE OLD RULE WAS THE PIXELATION.

This used to bake at SS = 4 canvas pixels per radius unit, rounded up to a power
of two: a radius-6 corner was a 32px file drawn into a 6-UI-unit box. At the
scales the settings window actually runs (a UI scale slider under 1, times the
window's own scale slider) that box is 3-8 DEVICE pixels, so the GPU was asked
for a 4:1 to 8:1 minification of a diagonal edge with NO MIPMAPS behind it. That
is a point-sampled undersample of a curve, and it reads exactly the way Danders
described it: pixelated, and crawling as a scrolling parent moves it.

Oversampling only helps a resampler that averages. WoW's texture path does not
build mip chains for these, so every extra baked pixel past the drawn size was
one more source texel the sampler simply skipped.

So the art is now baked NEAR THE DRAWN SIZE: one canvas pixel per radius unit,
i.e. a radius-N shape is N px of ink. The canvas is next_pot(N + 2) and the
shape is placed FLUSH INTO ITS BOTTOM-RIGHT CORNER, which leaves the spare
pixels on the top-left -- the OUTER side of a top-left corner, where the shape
is transparent anyway.

    N=4  -> 8px canvas, 4px pad     N=6  -> 8px canvas, 2px pad
    N=8  -> 16px canvas, 8px pad

WHY THE PADDING IS ON THAT SIDE AND NOT THE OTHER. The two edges of the corner
box that BUTT AGAINST THE FLAT STRIPS are its right edge and its bottom edge
(see WHY THE SHAPES LINE UP, above) -- those two carry full-strength ink and
must land on the texture's own edge, so that a sampler running off the end of
the quad clamps to ink rather than to nothing and the join with the strip stays
solid. The top and left edges are the outside of the curve, where the shape is
already transparent; padding there gives the bilinear filter honest transparent
texels to blend towards instead of clamping a half-covered edge texel outward
into the gap beside the corner box.

Round.lua crops to the shape with SetTexCoord rather than growing the quad --
see its RETEXTURE note for why that is the version that keeps the strips flush.

⚠ POWER OF TWO IS NOT COSMETIC. Every one of the ~90 textures this project
already ships is power-of-two, so an NPOT file here would be the first, and the
failure mode for one the client dislikes is a texture that silently does not
draw -- a black or absent corner with nothing in a log to explain it. Not worth
finding out in-game for 8px of file size, so the canvas is rounded up and the
slack becomes the padding described above. The + 2 is what guarantees there IS
slack: without it a radius that is already a power of two (4, 8) would bake
edge-to-edge with nothing for the filter to reach into.

☠ THE CANVAS RULE IS DUPLICATED IN Round.lua (its CANVAS table) because the
crop fraction is pad/canvas and the module cannot read this file. The two are
pinned together by test_round.lua, which asserts the texcoords this rule
implies. Change the rule here and that test fails -- which is the point.

Output matches the sibling icon art (Media/Icons/*.tga, see generate_pin.py):
32-bit BGRA, uncompressed (image type 2), top-left origin (descriptor 0x28),
flat white with the shape in the ALPHA channel so SetVertexColor tints it, and
no TGA 2.0 footer.

Anti-aliasing is analytic: SUB x SUB sub-samples per canvas pixel tested against
the maths, the same way generate_pin.py does it, so there is no downsample pass
and no resampling of an already-rasterised edge. SUB stays at 8 -- that is the
ONLY oversampling that ever did anything here, because it is averaged into the
baked alpha rather than left for a sampler that will not average it.

Run from anywhere:  python Tools/generate_rounded.py [repo-root] [--dump]

--dump prints an ASCII coverage map of every shape (' ' empty, '.' faint,
'+' partial, '#' near-solid, '@' solid) so the flushness claims above can be
read off the output instead of taken on trust: the RIGHT column and the BOTTOM
row of the ink must be '@' for a fill, and W px of '@' at the ends of the arc.
"""

import os
import struct
import sys

# Canvas pixels per radius unit. ONE, deliberately -- see the SIZE note. This is
# no longer a quality knob; SUB below is.
PPU = 1
# Free canvas pixels the shape does NOT use, so the power-of-two round-up always
# leaves the filter something transparent to reach into on the outer side.
PAD_MIN = 2
# Sub-samples per axis -> 64 per canvas pixel. THIS is the anti-aliasing.
SUB = 8

RADII = (4, 6, 8)
WIDTHS = (1, 2)


def canvas_for(n):
    """Texture size in px for a radius-n corner: the n px of shape plus at least
    PAD_MIN spare, rounded UP to a power of two. See the SIZE note -- the round-up
    is not negotiable and the spare pixels are not waste, they are the filter's
    landing room on the outer side of the curve."""
    want = n * PPU + PAD_MIN
    size = 1
    while size < want:
        size *= 2
    return size


def pad_for(n):
    """How many canvas pixels sit ABOVE and LEFT of the shape. The shape is flush
    into the bottom-right corner, so this is the whole of the slack."""
    return canvas_for(n) - n * PPU


def render(n, width=None):
    """Coverage rows (top -> bottom) for the TOP-LEFT corner, alpha 0..1.

    `n` is the radius in UI units and one canvas pixel is one unit, so the shape
    is n px across; the canvas is canvas_for(n) px square and the shape sits
    flush in its BOTTOM-RIGHT corner. That puts the circle's centre exactly on
    the canvas's bottom-right corner (size, size) in canvas-pixel coordinates,
    which is the whole of the mapping -- there is no scale factor left.

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
                    # Canvas px -> offset from the circle centre, which is the
                    # canvas's own bottom-right corner. Both are <= 0.
                    du = (px + (sx + 0.5) / SUB) - size
                    dv = (py + (sy + 0.5) / SUB) - size
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
    """Total coverage, in whole pixels. At one pixel per unit a quarter disc of
    radius n should come out near pi/4 * n^2 -- printed so a bad mapping is
    visible without opening the file."""
    return sum(sum(row) for row in rows)


RAMP = ((0.999, "@"), (0.75, "#"), (0.25, "+"), (0.02, "."))


def dump(rows, label):
    """ASCII coverage map. What to look for -- see the --dump note in the header:
    the shape's RIGHT column and BOTTOM row are the edges that butt against the
    flat strips, so those must be solid ('@') for a fill and W px of '@' at the
    two ends of an arc. Everything left of / above the shape is padding and must
    be blank."""
    print("   " + label)
    for row in rows:
        line = []
        for a in row:
            ch = " "
            for lo, c in RAMP:
                if a >= lo:
                    ch = c
                    break
            line.append(ch)
        print("     |" + "".join(line) + "|")


def main():
    args = [a for a in sys.argv[1:]]
    want_dump = "--dump" in args
    args = [a for a in args if not a.startswith("--")]
    root = args[0] if args else os.getcwd()
    out = os.path.join(root, "DandersUI", "Media", "Round")
    os.makedirs(out, exist_ok=True)

    for n in RADII:
        size = canvas_for(n)
        pad = pad_for(n)
        rows = render(n)
        path = os.path.join(out, "corner_fill_r%d.tga" % n)
        write_tga(path, rows)
        print("wrote %s  %dx%d  shape %dpx  pad %dpx  crop %.4f  ink %.1f px (ideal %.1f)" %
              (os.path.basename(path), size, size, n, pad, pad / float(size),
               ink(rows), 3.14159265358979 / 4.0 * n * n))
        if want_dump:
            dump(rows, "fill r%d" % n)

        for w in WIDTHS:
            rows = render(n, w)
            path = os.path.join(out, "corner_edge_r%d_w%d.tga" % (n, w))
            write_tga(path, rows)
            inner = max(0, n - w)
            print("wrote %s  %dx%d  shape %dpx  pad %dpx  crop %.4f  ink %.1f px (ideal %.1f)" %
                  (os.path.basename(path), size, size, n, pad, pad / float(size),
                   ink(rows), 3.14159265358979 / 4.0 * (n * n - inner * inner)))
            if want_dump:
                dump(rows, "edge r%d w%d" % (n, w))

    print("\n-> " + os.path.normpath(out))


if __name__ == "__main__":
    main()
