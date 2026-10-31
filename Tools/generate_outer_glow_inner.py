#!/usr/bin/env python3
"""
Generate DF_OuterGlowInner.tga: the inside-corner piece for the OUTER rested glow.

DF_OuterGlow.tga is a nine-slice whose edge bands fade from full alpha at the
shape's edge to nothing 24px (of 64) out. Where the glowed outline turns an
INSIDE corner (an L or step shape), the two edge strips meeting there would add
up (ADD blend) and double the brightness in the square between them. This piece
fills that square instead: alpha = the brighter of the two edge falloffs, i.e.
max(P(distance to the right edge), P(distance to the bottom edge)), with the
falloff P read straight out of DF_OuterGlow's top band so the two arts match.

Orientation: the shape sits along this piece's RIGHT and BOTTOM sides (the piece
lives up-left of the corner). The other three corners mirror it with texcoords.

TGA container: same as DF_OuterGlow.tga -- 64 x 64, 32-bit BGRA, uncompressed,
descriptor 0x08 (8 alpha bits, bottom-left origin), TGA 2.0 footer.
"""

import os
import struct

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
MEDIA = os.path.join(HERE, "..", "DandersFrames", "Media")
SRC = os.path.join(MEDIA, "DF_OuterGlow.tga")
OUT = os.path.join(MEDIA, "DF_OuterGlowInner.tga")
SIZE = 64
BAND = 24  # the source art's fade band, in its own pixels


def falloff_profile():
    """Alpha (0-255) by band row, row BAND = the shape's edge, row 0 = far out."""
    im = Image.open(SRC).convert("RGBA")
    px = im.load()
    col = im.size[0] // 2
    return [px[col, y][3] for y in range(BAND + 1)]


def sample(profile, d):
    """Alpha at distance d (0..BAND band pixels) from the edge, linear between rows."""
    row = BAND - d
    if row <= 0:
        return float(profile[0])
    if row >= BAND:
        return float(profile[BAND])
    lo = int(row)
    t = row - lo
    return profile[lo] * (1 - t) + profile[lo + 1] * t


def main():
    profile = falloff_profile()
    rows = []
    for y in range(SIZE):  # y = 0 is the TOP row
        row = []
        dy = (SIZE - (y + 0.5)) / SIZE * BAND  # distance to the bottom edge
        for x in range(SIZE):
            dx = (SIZE - (x + 0.5)) / SIZE * BAND  # distance to the right edge
            a = max(sample(profile, dx), sample(profile, dy))
            row.append(int(round(a)))
        rows.append(row)

    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x08)
    data = bytearray()
    for y in range(SIZE - 1, -1, -1):  # bottom-left origin
        for a in rows[y]:
            data += bytes((255, 255, 255, a))
    footer = struct.pack("<II", 0, 0) + b"TRUEVISION-XFILE.\x00"
    with open(OUT, "wb") as fh:
        fh.write(header + bytes(data) + footer)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
