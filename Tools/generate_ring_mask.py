#!/usr/bin/env python3
"""
Generate DandersFrames_UnitFrames/Media/RingInnerMask.tga -- the HOLE of a ring.

An inverted circle mask: opaque white OUTSIDE a disc, transparent black INSIDE it,
the disc touching all four edges. A ring's fill and track textures take two masks
(DandersFrames_UnitFrames/Rings.lua):
  * Blizzard's disc mask sized to the ring's OUTER diameter (CLAMPTOBLACKADDITIVE:
    nothing outside it shows);
  * this one sized to the ring's INNER diameter, wrap mode CLAMPTOWHITE, so
    everything outside its square stays visible and only the disc is cut away.
Two masks multiply, so what is left is the band between the two circles -- with a
see-through centre, unlike a dark disc drawn on top.

RGB and alpha carry the same value, so it reads the same whichever channel the
client samples. The edge is anti-aliased over ~1.5px by coverage (4x4 supersampling).

Usage: python Tools/generate_ring_mask.py
"""
import pathlib, struct

SIZE = 256
SS = 4  # supersamples per axis
OUT = pathlib.Path(__file__).resolve().parents[1] / "DandersFrames_UnitFrames" / "Media" / "RingInnerMask.tga"


def coverage_inside(x, y):
    """Share of pixel (x, y) inside the disc of radius SIZE/2 centred on the canvas."""
    r = SIZE / 2.0
    hits = 0
    for sy in range(SS):
        for sx in range(SS):
            px = x + (sx + 0.5) / SS - r
            py = y + (sy + 0.5) / SS - r
            if px * px + py * py <= r * r:
                hits += 1
    return hits / (SS * SS)


def main():
    pixels = bytearray()
    for y in range(SIZE):
        for x in range(SIZE):
            v = int(round((1.0 - coverage_inside(x, y)) * 255))
            pixels += bytes((v, v, v, v))  # B, G, R, A
    # Uncompressed true-colour, 32 bpp, 8 alpha bits. Symmetric, so the origin
    # (bottom-left by default) does not matter.
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x08)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(header + bytes(pixels))
    print(f"wrote {OUT} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
