#!/usr/bin/env python3
"""
Generate DandersUI/Media/Round/pill_w4.tga -- the rounded cap texture for a
vertical selection marker (UI:CreateSelectionMarker with opts.pill).

A 4px-wide bar with fully round ends: radius 2, so each end is a half circle.
Baked at ONE TEXEL PER UI UNIT, like every Round/ texture (see THE SLICE
CONTRACT in DandersUI/Round.lua): the marker slices it with margins
(0, 2, 0, 2) so the caps hold their size and only the middle stretches down
the bar's length.

Canvas 4 x 8: a 2px cap, 4 free rows to stretch, a 2px cap. Flat white with
the shape in alpha, so SetVertexColor tints it. Same TGA layout as the other
Round/ textures (write_tga in generate_rounded.py).

Run from the repo root:  python Tools/generate_pill.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from generate_rounded import in_rrect, write_tga  # noqa: E402

W, H, R = 4, 8, 2.0
SS = 16     # supersampling per axis


def render():
    rows = []
    for y in range(H):
        row = []
        for x in range(W):
            hit = 0
            for sy in range(SS):
                for sx in range(SS):
                    if in_rrect(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS, W, H, R,
                                ("tl", "tr", "bl", "br")):
                        hit += 1
            row.append(hit / float(SS * SS))
        rows.append(row)
    return rows


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "DandersUI", "Media", "Round", "pill_w4.tga")
    write_tga(out, render())
    print("wrote", out)


if __name__ == "__main__":
    main()
