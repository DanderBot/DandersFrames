#!/usr/bin/env python3
"""
Generate DandersUI/Media/Round/ -- the art for UI:CreateRoundedSurface.

☠ REWRITTEN 2026-08-27. THIS USED TO BAKE QUARTER CORNERS. It does not any more,
and the reason is worth having in front of you before reading a line of it.

The old surface was FIFTEEN objects: four quarter-disc corners, four quarter-arc
corners, and seven flat SetColorTexture strips anchored to butt against them. The
joints were exact in UI units -- every edge a whole-number offset from the frame
-- and they still opened up ON SCREEN, because a butt joint between two quads is
only seamless when both quads land on the same device-pixel grid. During the
popout's scale animation they do not: Fx drives a frame's scale through a
continuum of fractional values, each quad is rasterised independently at that
scale, and two adjacent quads whose shared edge falls at x.5 can round APART.
That is the "gaps when the popout animates in and out" report, and no amount of
anchor arithmetic fixes it -- the arithmetic was already right.

The engine has a primitive for exactly this: NINE-SLICE, via
Texture:SetTextureSliceMargins(left, top, right, bottom) plus
SetTextureSliceMode(Enum.UITextureSliceMode.Stretched). ONE texture, ONE quad,
ONE draw -- the corners are held at their baked size and only the middle bands
stretch. There is no joint to open because there is no second quad.

So this file now bakes WHOLE SHAPES, not pieces:

    rect_rN.tga          a filled rounded rectangle, all four corners round
    ring_rN_wW.tga       the matching border ring, stroke W drawn INSIDE the
                         same outline
    rect_top_rN.tga      top corners round, bottom square -- a title strip
    ring_top_rN_wW.tga   ...and its ring

------------------------------------------------------------
THE CANVAS, AND WHY IT IS THE SIZE IT IS

A nine-sliced texture is cut into 3 x 3 by the margins. With a margin of N on
every side, the canvas has to hold TWO N-pixel corner bands per axis plus a
middle band with something in it to stretch:

    canvas = next_pot(2N + MID_MIN)

    N=4  -> next_pot(12) = 16   corners 4+4, middle 8
    N=6  -> next_pot(16) = 16   corners 6+6, middle 4
    N=8  -> next_pot(20) = 32   corners 8+8, middle 16

⚠ THE MIDDLE BAND MUST NOT BE ZERO. A canvas of exactly 2N would leave the
stretched region one pixel wide at best and empty at worst, and an empty middle
band is a texture that draws its two corners and nothing between them. MID_MIN is
4 rather than 2 so the round-up always lands clear of that edge even at a radius
that is already a power of two.

⚠ ONE TEXEL PER UI UNIT -- and this is a CONTRACT, not a quality knob.
SetTextureSliceMargins takes TEXTURE PIXELS, and passing an N-pixel corner band is
what is INTENDED to make `radius = N` mean "N UI units of curve" at the other end.
Change the bake density here and every consumer's radius changes meaning.
Round.lua's SLICE CONTRACT note is the other half of this sentence -- INCLUDING
its warning that whether the engine actually honours the 1:1 is unverified, with
a reference addon on record saying it scales sliced texels by
regionShort/artSize instead. If that turns out to be the live behaviour, the fix
starts here: bake every radius on ONE canvas size, so at least the radii stay in
order.

(The near-drawn-size philosophy that produced the old 1-texel-per-unit rule is
kept for the same reason it was adopted: WoW builds no mip chain for these files,
so every baked pixel past the drawn size is a source texel the sampler skips
rather than averages. Here it is additionally forced by the slice contract.)

------------------------------------------------------------
FLUSHNESS

Under nine-slice the texture's four EDGES map directly onto the frame's four
edges, so ink that stops one pixel short of the canvas is a one-pixel transparent
gutter around every surface in the game. The shape is therefore drawn FLUSH to
all four canvas edges -- no padding anywhere, unlike the old quarter-corner bake
which needed slack on its outer side.

That costs nothing here: the outer side of the curve now faces the canvas edge at
the corner only, and a corner band's outermost texel is transparent by geometry
rather than by padding.

`--dump` prints an ASCII coverage map of every shape and `--verify` (implied by
--dump) runs the numeric checks the flushness claim rests on:

  * every one of the four canvas edges carries solid ink somewhere
  * a fill's middle-of-edge run is SOLID and a ring's is exactly W deep
  * every column of a horizontally-stretched band is IDENTICAL (and every row of
    a vertical one) -- a band that varies across the stretch axis smears
  * a ring's centre band is EMPTY, so the stretch does not flood the interior
  * a fill's centre band is SOLID

------------------------------------------------------------
Output matches the sibling icon art (Media/Icons/*.tga, see generate_pin.py):
32-bit BGRA, uncompressed (image type 2), top-left origin (descriptor 0x28),
flat white with the shape in the ALPHA channel so SetVertexColor tints it, and
no TGA 2.0 footer.

Anti-aliasing is analytic: SUB x SUB sub-samples per canvas pixel tested against
the maths, the same way generate_pin.py does it, so there is no downsample pass
and no resampling of an already-rasterised edge.

Run from anywhere:  python Tools/generate_rounded.py [repo-root] [--dump] [--verify]
"""

import os
import struct
import sys

# Free canvas pixels between the two corner bands. See THE CANVAS above -- this
# is what the nine-slice stretches, and it must never round down to nothing.
MID_MIN = 4
# Sub-samples per axis -> 64 per canvas pixel. THIS is the anti-aliasing.
SUB = 8

RADII = (4, 6, 8)
WIDTHS = (1, 2)

# The two baked shapes. `corners` is which of the four are round; Round.lua
# accepts exactly these two and refuses anything else, because anything else has
# no file.
SHAPES = (
    ("",     ("tl", "tr", "bl", "br")),   # rect_rN / ring_rN_wW
    ("top_", ("tl", "tr")),               # rect_top_rN / ring_top_rN_wW
)


def canvas_for(n):
    """Texture size in px for a radius-n shape: two n-px corner bands plus at
    least MID_MIN of stretchable middle, rounded UP to a power of two.

    ⚠ POWER OF TWO IS NOT COSMETIC. Every one of the ~90 textures this project
    ships is power-of-two, so an NPOT file here would be the first, and the
    failure mode for one the client dislikes is a texture that silently does not
    draw -- a black or absent surface with nothing in a log to explain it."""
    want = 2 * n + MID_MIN
    size = 1
    while size < want:
        size *= 2
    return size


def in_rrect(x, y, w, h, r, corners):
    """Is (x, y) inside a w x h rounded rectangle whose origin is (0, 0)?

    Image coordinates: x right, y DOWN, so 'tl' is small x and small y. Only the
    corners named in `corners` are cut; the rest are square, which is the whole
    of the top-only variant.
    """
    if x < 0.0 or y < 0.0 or x > w or y > h:
        return False
    if r <= 0.0:
        return True
    left, right = x < r, x > w - r
    top, bottom = y < r, y > h - r
    if left and top and "tl" in corners:
        return (x - r) ** 2 + (y - r) ** 2 <= r * r
    if right and top and "tr" in corners:
        return (x - (w - r)) ** 2 + (y - r) ** 2 <= r * r
    if left and bottom and "bl" in corners:
        return (x - r) ** 2 + (y - (h - r)) ** 2 <= r * r
    if right and bottom and "br" in corners:
        return (x - (w - r)) ** 2 + (y - (h - r)) ** 2 <= r * r
    return True


def render(n, corners, width=None):
    """Coverage rows (top -> bottom), alpha 0..1, for one shape.

    `width` None renders the FILL -- the whole rounded rectangle. A number
    renders the RING: the fill minus the same shape inset by `width` on all four
    sides with its radius reduced by `width`.

    ☠ THAT INSET IS THE EXACT INWARD OFFSET, not an approximation. The curve
    parallel to a circular arc at distance W is a circular arc of radius r - W
    about the same centre, and the centre of an inset rounded rect's corner is
    the centre of the original's. So the stroke is a true constant-W band all the
    way round, and the straight runs and the arcs meet with no step -- which is
    what the old assembly had to buy with anchor arithmetic.
    """
    size = canvas_for(n)
    inner_r = None if width is None else float(n) - float(width)

    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            hit = 0
            for sy in range(SUB):
                for sx in range(SUB):
                    x = px + (sx + 0.5) / SUB
                    y = py + (sy + 0.5) / SUB
                    if not in_rrect(x, y, size, size, float(n), corners):
                        continue
                    if width is not None:
                        w = float(width)
                        if in_rrect(x - w, y - w, size - 2 * w, size - 2 * w,
                                    inner_r, corners):
                            continue
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
    """Total coverage, in whole pixels -- printed so a bad mapping is visible
    without opening the file."""
    return sum(sum(row) for row in rows)


RAMP = ((0.999, "@"), (0.75, "#"), (0.25, "+"), (0.02, "."))


def dump(rows, label):
    """ASCII coverage map. What to look for: the shape touches all four edges
    (no blank border row or column anywhere), the middle of each edge is solid
    for a fill and W deep for a ring, and a ring's interior is blank."""
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


# ---- numeric verification -------------------------------------------
#
# Every check here is a claim the SLICE depends on, not a claim about how the
# picture looks. A shape that fails one of these renders as a gutter round the
# frame, a smear across the interior, or a band that changes as it stretches --
# all of which are invisible in a thumbnail and obvious at 400px wide.

FAILURES = []


def _claim(ok, what):
    if not ok:
        FAILURES.append(what)
    return ok


def verify(rows, n, label, corners, width=None):
    size = len(rows)
    mid = range(n, size - n)            # the stretched band, both axes
    solid = 0.999

    # 1. FLUSH. Ink reaches all four canvas edges. Under nine-slice the texture's
    #    edge IS the frame's edge, so a shape that stops short is a transparent
    #    gutter round every surface drawn from it.
    _claim(max(rows[0]) >= solid, label + ": top edge carries solid ink")
    _claim(max(rows[size - 1]) >= solid, label + ": bottom edge carries solid ink")
    _claim(max(r[0] for r in rows) >= solid, label + ": left edge carries solid ink")
    _claim(max(r[size - 1] for r in rows) >= solid, label + ": right edge carries solid ink")

    # 2. THE STRETCH IS UNIFORM. Every column of a horizontally-stretched band is
    #    the same column, and every row of a vertical one the same row. A band
    #    that varies along the stretch axis is smeared across the frame.
    for x in mid:
        _claim(all(rows[y][x] == rows[y][n] for y in range(size)),
               label + ": top/bottom bands are uniform across the stretch")
    for y in mid:
        _claim(all(rows[y][x] == rows[n][x] for x in range(size)),
               label + ": left/right bands are uniform across the stretch")

    # 3. WHAT THE MIDDLE OF AN EDGE LOOKS LIKE. A fill is solid the whole depth
    #    of the corner band; a ring is exactly `width` deep and then empty.
    col = [rows[y][n] for y in range(size)]      # a vertical cut through the middle
    row = rows[n]                               # a horizontal one
    if width is None:
        _claim(all(v >= solid for v in col), label + ": fill is solid top to bottom mid-span")
        _claim(all(v >= solid for v in row), label + ": fill is solid left to right mid-span")
    else:
        for depth, series, edge in ((width, col, "top"), (width, row, "left")):
            _claim(all(series[i] >= solid for i in range(depth)),
                   label + ": ring is solid for W at the " + edge + " edge")
            _claim(series[depth] < solid,
                   label + ": ring stops at W at the " + edge + " edge")
            _claim(all(series[size - 1 - i] >= solid for i in range(depth)),
                   label + ": ring is solid for W at the opposite edge")
        # 4. THE INTERIOR IS EMPTY. The centre band stretches over the whole
        #    inside of the frame; anything in it floods the surface.
        for y in mid:
            for x in mid:
                _claim(rows[y][x] == 0.0, label + ": ring's centre band is empty")

    if width is None:
        for y in mid:
            for x in mid:
                _claim(rows[y][x] >= solid, label + ": fill's centre band is solid")

    # 5. THE SQUARE CORNERS OF A TOP-ONLY SHAPE REALLY ARE SQUARE -- otherwise
    #    the strip's lower edge would not join the body it sits against.
    if "bl" not in corners:
        _claim(rows[size - 1][0] >= solid, label + ": bottom-left corner texel is square")
    if "br" not in corners:
        _claim(rows[size - 1][size - 1] >= solid, label + ": bottom-right corner texel is square")
    if "tl" in corners:
        _claim(rows[0][0] < 0.5, label + ": top-left corner texel is cut by the curve")


def main():
    args = list(sys.argv[1:])
    want_dump = "--dump" in args
    want_verify = want_dump or "--verify" in args
    args = [a for a in args if not a.startswith("--")]
    root = args[0] if args else os.getcwd()
    out = os.path.join(root, "DandersUI", "Media", "Round")
    os.makedirs(out, exist_ok=True)

    for n in RADII:
        size = canvas_for(n)
        for tag, corners in SHAPES:
            rows = render(n, corners)
            name = "rect_%sr%d.tga" % (tag, n)
            write_tga(os.path.join(out, name), rows)
            print("wrote %-20s %dx%d  margin %d  middle %d  ink %.1f px" %
                  (name, size, size, n, size - 2 * n, ink(rows)))
            if want_verify:
                verify(rows, n, name, corners)
            if want_dump:
                dump(rows, name)

            for w in WIDTHS:
                rows = render(n, corners, w)
                name = "ring_%sr%d_w%d.tga" % (tag, n, w)
                write_tga(os.path.join(out, name), rows)
                print("wrote %-20s %dx%d  margin %d  middle %d  ink %.1f px" %
                      (name, size, size, n, size - 2 * n, ink(rows)))
                if want_verify:
                    verify(rows, n, name, corners, w)
                if want_dump:
                    dump(rows, name)

    print("\n-> " + os.path.normpath(out))

    if want_verify:
        if FAILURES:
            # De-duplicated: a band check fires once per column, and one line per
            # failing column would bury the other claims.
            seen = []
            for f in FAILURES:
                if f not in seen:
                    seen.append(f)
            print("\nVERIFY FAILED (%d checks, %d distinct):" % (len(FAILURES), len(seen)))
            for f in seen:
                print("  " + f)
            sys.exit(1)
        print("verify: all flushness / stretch / interior claims hold")


if __name__ == "__main__":
    main()
