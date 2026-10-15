#!/usr/bin/env python3
"""
Regenerate DandersUI/Media/Icons/pin.tga -- the popout title bar's pin glyph,
TILTED.

The upright glyph is the Material `push_pin` (filled) shape as the existing
64px art already draws it, measured straight off that file:

    head     disc, centre (32, 15), r 12
    collar   rounded bar, x 14..50, y 27..37, corner r 3
    needle   tapered spike, half-width 6 at y 37 down to 1 at y 59

The tilt is baked in HERE rather than applied with SetRotation in Lua, because
the pin is drawn at 14px and a runtime rotation resamples an already-rasterised
64px bitmap -- soft edges on a glyph that is mostly edge. So the geometry is
rotated ANALYTICALLY and the supersampling happens AFTER the rotation: every
sub-sample is inverse-rotated back into the upright shape space and tested
against the maths, so the diagonal edges are as crisp as the upright ones were.

Scale is FITTED, not fixed: a 36 x 56 glyph turned 27 degrees needs a 58 x 67
box, which does not fit in 64. The first pass measures the rotated ink on an
oversized canvas, the second renders at whatever scale leaves MARGIN px of
clearance -- so nothing clips however the angle is retuned.

Output matches the sibling 64px icon (notch.tga) exactly: 64x64, 32-bit BGRA,
uncompressed (image type 2), top-left origin (descriptor 0x28), flat white with
the shape in the alpha channel so SetVertexColor tints it, no TGA 2.0 footer.

Run from anywhere:  python generate_pin.py <repo-root>
"""

import math
import os
import struct
import sys

W = H = 64
SUB = 6           # sub-samples per axis -> 36 per pixel
MARGIN = 2.0      # px of clearance kept on every side of the fitted glyph
# Degrees clockwise on screen: the head leans RIGHT, the point swings down-left.
# 25 rather than 30: past about 27 the glyph starts living on a diagonal band and
# gives up the top-left and bottom-right corners of a square button, which costs
# apparent size at the 14px it is actually drawn at. 25 still reads unmistakably
# tilted and keeps the ink box at 0.81 of the canvas -- the same fill ratio as
# close.tga and settings.tga, so the pin does not out-weigh the cross beside it.
ANGLE = 25.0

# --- the upright push_pin, in the icon's own 64px space ---------------------
HEAD_CX, HEAD_CY, HEAD_R = 32.0, 15.0, 12.0
COLLAR_L, COLLAR_R, COLLAR_T, COLLAR_B, COLLAR_RAD = 14.0, 50.0, 27.0, 37.0, 3.0
NEEDLE_CX, NEEDLE_TOP, NEEDLE_BOT = 32.0, 37.0, 59.0
NEEDLE_TOP_HW, NEEDLE_BOT_HW = 6.0, 1.0
PIVOT_X, PIVOT_Y = 32.0, 31.0     # centre of the upright glyph's ink box


def inside(x, y):
    """Is (x, y) inside the upright glyph? The union of the three parts."""
    if (x - HEAD_CX) ** 2 + (y - HEAD_CY) ** 2 <= HEAD_R * HEAD_R:
        return True
    if COLLAR_T <= y <= COLLAR_B and COLLAR_L <= x <= COLLAR_R:
        qx = max(COLLAR_L + COLLAR_RAD - x, x - (COLLAR_R - COLLAR_RAD), 0.0)
        qy = max(COLLAR_T + COLLAR_RAD - y, y - (COLLAR_B - COLLAR_RAD), 0.0)
        if qx * qx + qy * qy <= COLLAR_RAD * COLLAR_RAD:
            return True
    if NEEDLE_TOP <= y <= NEEDLE_BOT:
        t = (y - NEEDLE_TOP) / (NEEDLE_BOT - NEEDLE_TOP)
        hw = NEEDLE_TOP_HW + (NEEDLE_BOT_HW - NEEDLE_TOP_HW) * t
        if abs(x - NEEDLE_CX) <= hw:
            return True
    return False


def render(size, scale, offx=0.0, offy=0.0):
    """Coverage rows (top -> bottom), each entry an alpha 0..1.

    Every sub-sample is taken in OUTPUT space and mapped back through the
    inverse rotation into the upright shape -- i.e. the anti-aliasing is
    computed on the tilted silhouette, not carried over from an upright raster.

    (offx, offy) shifts the sampling window in ROTATED, unscaled units, so the
    second pass can centre the tilted ink rather than the pivot it turned about.
    """
    th = math.radians(ANGLE)
    cos, sin = math.cos(th), math.sin(th)
    c = size / 2.0
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            hit = 0
            for sy in range(SUB):
                for sx in range(SUB):
                    ox = px + (sx + 0.5) / SUB
                    oy = py + (sy + 0.5) / SUB
                    dx = (ox - c) / scale + offx
                    dy = (oy - c) / scale + offy
                    # transpose of the clockwise (screen, y-down) rotation
                    if inside(PIVOT_X + dx * cos + dy * sin,
                              PIVOT_Y - dx * sin + dy * cos):
                        hit += 1
            row.append(hit / float(SUB * SUB))
        rows.append(row)
    return rows


def ink_box(rows):
    xs, ys = [], []
    for y, row in enumerate(rows):
        for x, a in enumerate(row):
            if a > 0.0:
                xs.append(x)
                ys.append(y)
    return min(xs), max(xs), min(ys), max(ys)


def write_tga(path, rows):
    size = len(rows)
    # 0x28 = top-left origin (0x20) + 8 alpha bits (0x08). Same as notch.tga;
    # neither 64px icon carries the optional TGA 2.0 footer.
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 0x28)
    with open(path, "wb") as f:
        f.write(header)
        for row in rows:
            for a in row:
                b = int(round(255.0 * a))
                f.write(bytes((255, 255, 255, b)))   # B, G, R, A -- flat white


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    out = os.path.join(root, "DandersUI", "Media", "Icons", "pin.tga")

    # Pass 1: measure the tilted ink on an oversized canvas, at scale 1. The
    # rotated ink is NOT centred on the pivot it turned about, so both the fit
    # and the recentring offset come from what was actually drawn.
    probe = 128
    big = render(probe, 1.0)
    x0, x1, y0, y1 = ink_box(big)
    span = max(x1 - x0 + 1, y1 - y0 + 1)
    # Never ABOVE 1: the geometry above is the authored weight of the icon set,
    # and blowing it up to fill the canvas would make the pin read heavier than
    # the cross beside it. Shrink only if the tilt would otherwise clip.
    scale = min(1.0, (W - 2 * MARGIN) / float(span))
    offx = (x0 + x1 + 1) / 2.0 - probe / 2.0
    offy = (y0 + y1 + 1) / 2.0 - probe / 2.0

    # Pass 2: the real thing.
    rows = render(W, scale, offx, offy)
    x0, x1, y0, y1 = ink_box(rows)
    write_tga(out, rows)
    print("wrote", os.path.normpath(out))
    print("  angle %.1f deg, scale %.4f, ink box x %d..%d  y %d..%d" %
          (ANGLE, scale, x0, x1, y0, y1))


if __name__ == "__main__":
    main()
