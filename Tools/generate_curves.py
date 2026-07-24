#!/usr/bin/env python3
"""
Generate DandersFrames duration-bar colour-curve ramps.

Output: 32-bit uncompressed TGA, written into ../Media/ next to this script.

A StatusBar CROPS its fill texture to the filled fraction, so a baked colour RAMP
as the fill texture makes the visible tip colour walk the ramp as the bar drains.
That is colour-by-remaining with ZERO reads, which is the only way to do it in 12.1
(remaining time is secret). See CURVE_TEXTURES in Features/Auras.lua.

Consequences that drive the art:
  * The ramp keys off FRACTION remaining, so its stops are PERCENTAGES. Both DF
    ramps are baked from the percent scale's DEFAULTS (DEFAULT_PERCENT_BREAKPOINTS
    in Features/Auras.lua). They carry the defaults, not the user's edited stops --
    a baked image cannot follow the colour pickers.
  * They are painted for the DRAIN case: 0% remaining at the LEFT end, so the tip
    walks green -> red as the bar empties. Reverse Fill needs no mirrored art
    (the StatusBar flips the texture with the fill) and VERTICAL bars need no
    second file (SetRotatesTexture turns the same art).

Two shapes off one stop list, mirroring the two ways the duration TEXT can read
the same ladder:
  * "smooth" blends between stops, for a continuous wash down the bar;
  * "step" holds each stop's colour until the next one, so the bar shows the same
    four hard bands the stepped duration text does. It FLOORS -- the highest stop
    at or below the fraction wins -- which is how the breakpoint ladder resolves
    everywhere else in the addon.

Only the DF ramps are generated here. Classic_Curve.tga is pre-existing art in a
different palette and this tool deliberately does not own or overwrite it.

TGA container (matches the files already in ../Media/):
  * 256 x 8 pixels -- one scanline's worth of ramp, repeated so the texture has
    some height to sample. Every row is identical, so origin does not matter.
  * 32-bit BGRA, uncompressed (image type 2), descriptor 0x08 (8 alpha bits).
  * TGA 2.0 footer appended.
"""

import os
import struct

W, H = 256, 8
OUTDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Media")

# (fraction remaining, hex). Keep in sync with DEFAULT_PERCENT_BREAKPOINTS in
# Features/Auras.lua -- thresholds 75 / 50 / 25 / 0 read bottom-up as fractions.
# Above the top stop both shapes hold flat, exactly as the breakpoint ladder does.
STOPS = [
    (0.00, "f75555"),   # red    -- about to fall off
    (0.25, "ff9838"),   # orange
    (0.50, "ffd23d"),   # gold
    (0.75, "5fe05f"),   # green  -- fresh, and flat from here to 100%
]

# File names are deliberately *_Curve, matching Classic_Curve.tga: the bare DF_* names
# belong to the LibSharedMedia STATUSBAR textures registered in Config.lua (DF_Smooth is
# one of them -- a user-selectable bar texture). Ramps must never land on one of those.
CURVES = {
    "DF_Curve_Smooth": ("smooth", STOPS),
    "DF_Curve_Stops":  ("step",   STOPS),
}


def rgb(h):
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def sample(mode, stops, t):
    """Colour at fraction t. "smooth" blends between stops; "step" floors to the
    highest stop at or below t. Both hold flat outside the end stops."""
    if t <= stops[0][0]:
        return rgb(stops[0][1])
    if mode == "step":
        hit = stops[0][1]
        for t0, h0 in stops:
            if t0 <= t:
                hit = h0
        return rgb(hit)
    for (t0, h0), (t1, h1) in zip(stops, stops[1:]):
        if t <= t1:
            f = (t - t0) / (t1 - t0)
            a, b = rgb(h0), rgb(h1)
            return tuple(int(round(a[c] + (b[c] - a[c]) * f)) for c in range(3))
    return rgb(stops[-1][1])


def write_tga(path, mode, stops):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, W, H, 32, 0x08)
    row = bytearray()
    for x in range(W):
        r, g, b = sample(mode, stops, x / (W - 1))
        row += bytes((b, g, r, 0xFF))                       # BGRA
    footer = b"\x00" * 8 + b"TRUEVISION-XFILE." + b"\x00"   # TGA 2.0
    with open(path, "wb") as f:
        f.write(header + bytes(row) * H + footer)


def main():
    for name, (mode, stops) in sorted(CURVES.items()):
        path = os.path.normpath(os.path.join(OUTDIR, name + ".tga"))
        write_tga(path, mode, stops)
        print("wrote %s (%s, %d x %d)" % (path, mode, W, H))


if __name__ == "__main__":
    main()
