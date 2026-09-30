#!/usr/bin/env python3
"""
Generate the settings card headers' KIND icons into DandersFrames/Media/Icons/.

A settings card (GUI:CreateCollapsibleSection with opts.card) can carry a small
monochrome glyph between its chevron and its title, saying what KIND of section
it is -- appearance, layout, position, text... The kind -> texture map lives in
DandersFrames_Options/GUI/SettingsWidgets.lua next to GUI.SectionCard. Three
kinds reuse icons already in the folder (open_in_full, visibility); the rest are
drawn here:

    palette  grid_view  open_with  text_fields  format_color_fill  chat_info
    auto_awesome  border_style  swap_vert  timer
    filter_header   -- Material `filter_alt`, refitted for the headers ONLY

☠ filter_header IS NOT filter_alt.tga. The existing filter_alt.tga is used
elsewhere and is drawn smaller and fainter than its siblings (its ink box is
7..24, theirs 3..29), so beside the other header icons it read as a lighter
weight. It is left alone; this is a fresh copy fitted to the same box.

THE SOURCE. Material Symbols Outlined, weight 300, fill 0, grade 0, optical size
24 -- the path data below is copied verbatim from the published SVGs.
Material Symbols is (c) Google, licensed under the Apache License 2.0
(https://www.apache.org/licenses/LICENSE-2.0).

THE FIT. Each path's own bounding box is scaled so its LONGER side spans the
3..29px ink box every 32px sibling fills (close.tga, open_in_full.tga,
visibility.tga), centred on the canvas. Filled with the nonzero rule at 8x8
supersampling and box-averaged into coverage, written as flat white with the
shape in the alpha channel so SetVertexColor tints it like every sibling.

Output matches the sibling 32px icons byte-for-byte in format: 32x32, 32-bit
BGRA, uncompressed (image type 2), BOTTOM-left origin (descriptor 0x08), plus
the TGA 2.0 footer they all carry.

No third-party modules: plain Python 3, like the other generators here.

Run from anywhere:  python generate_header_icons.py <repo-root>
                    python generate_header_icons.py --preview
"""

import math
import os
import re
import struct
import sys

W = 32              # canvas, and the siblings' size
LO, HI = 3.0, 29.0  # the ink box every 32px sibling fills
SS = 8              # supersampling per axis
CURVE_STEPS = 8     # line segments per quadratic curve

# name -> SVG path `d`, Material Symbols Outlined, weight 300.
ICONS = {
    "palette": (
        "M479.23-100q-77.77 0-146.92-29.96-69.16-29.96-120.77-81.58-51.62-51.61-81.58-120.96T100-480"
        "q0-79.15 30.77-148.5t83.58-120.65q52.8-51.31 123.54-81.08Q408.62-860 488.77-860q75 0 142.15 25.58"
        " 67.16 25.58 117.96 70.81 50.81 45.23 80.96 107.5Q860-593.85 860-521.08q0 103.85-61.73 162.46"
        "Q736.54-300 640-300h-72.46q-17.08 0-27.31 11.15Q530-277.69 530-262.46q0 18.54 15 38.54T560-178"
        "q0 39.61-21.92 58.81Q516.15-100 479.23-100Zm.77-380Zm-220 30q21.38 0 35.69-14.31Q310-478.62 310-500"
        "q0-21.38-14.31-35.69Q281.38-550 260-550q-21.38 0-35.69 14.31Q210-521.38 210-500q0 21.38 14.31 35.69"
        "Q238.62-450 260-450Zm120-160q21.38 0 35.69-14.31Q430-638.62 430-660q0-21.38-14.31-35.69"
        "Q401.38-710 380-710q-21.38 0-35.69 14.31Q330-681.38 330-660q0 21.38 14.31 35.69Q358.62-610 380-610Z"
        "m200 0q21.38 0 35.69-14.31Q630-638.62 630-660q0-21.38-14.31-35.69Q601.38-710 580-710q-21.38 0-35.69"
        " 14.31Q530-681.38 530-660q0 21.38 14.31 35.69Q558.62-610 580-610Zm120 160q21.38 0 35.69-14.31"
        "Q750-478.62 750-500q0-21.38-14.31-35.69Q721.38-550 700-550q-21.38 0-35.69 14.31Q650-521.38 650-500"
        "q0 21.38 14.31 35.69Q678.62-450 700-450ZM479.23-160q9.77 0 15.27-4.81T500-178q0-14-15-31.46"
        "t-15-54.69q0-42.77 29-69.31T570-360h70q70.62 0 115.31-41.38Q800-442.77 800-521.08"
        "q0-121.38-93.08-200.15Q613.85-800 488.77-800q-137.15 0-232.96 93T160-480q0 133 93.5 226.5"
        "T479.23-160Z"
    ),
    "grid_view": (
        "M140-520v-300h300v300H140Zm0 380v-300h300v300H140Zm380-380v-300h300v300H520Zm0 380v-300h300v300H520Z"
        "M200-580h180v-180H200v180Zm380 0h180v-180H580v180Zm0 380h180v-180H580v180Zm-380 0h180v-180H200v180Z"
        "m380-380Zm0 200Zm-200 0Zm0-200Z"
    ),
    "open_with": (
        "M480-93.85 323.85-250l42.77-42.77L450-209.38V-390h60v180l82.77-83.38L636.15-250 480-93.85Z"
        "m-230-230L93.85-480l155.53-155.54 42.77 42.77L209.38-510H390v60H210l83.38 82.77L250-323.85Z"
        "m460 0-42.77-42.77L750.62-450H570v-60h180l-83.38-82.77L710-636.15 866.15-480 710-323.85Z"
        "M450-570v-180.62l-83.38 83.39L323.85-710 480-866.15 636.15-710l-42.77 42.77L510-750.62V-570h-60Z"
    ),
    "text_fields": (
        "M297.69-177.69v-520h-200v-84.62h484.62v84.62h-200v520h-84.62Zm360 0v-320h-120v-84.62h324.62"
        "v84.62h-120v320h-84.62Z"
    ),
    "format_color_fill": (
        "m255.46-880.54 42.39-42.53L632-588.92q21.08 21.08 21.08 51.61 0 30.54-21.08 51.62L458.92-311.85"
        "q-20.69 20.7-51.23 20.7-30.54 0-51.23-20.7L183.39-485.69q-21.08-21.08-21.08-51.62 0-30.53 21.08-51.61"
        "l181.92-181.77-109.85-109.85Zm152.62 152.62L224.77-545.38q-1.92 1.92-2.5 4.04-.58 2.11-.58 4.42"
        "h372q0-2.31-.57-4.42-.58-2.12-2.5-4.04L408.08-727.92Zm343.46 461.77q-29.16 0-49.58-20.43"
        "-20.42-20.42-20.42-49.57 0-19.46 10.96-40.19 10.96-20.73 23.65-39.04 8.23-11.23 17.08-22.69"
        " 8.85-11.47 18.31-22.7 9.46 11.23 18.31 22.7 8.84 11.46 17.07 22.69 12.69 18.31 23.66 39.04"
        " 10.96 20.73 10.96 40.19 0 29.15-20.43 49.57-20.42 20.43-49.57 20.43ZM80 0v-120h800V0H80Z"
    ),
    "chat_info": (
        "M480-687.69q13.92 0 23.11-9.2 9.2-9.19 9.2-23.11t-9.2-23.11q-9.19-9.2-23.11-9.2t-23.11 9.2"
        "q-9.2 9.19-9.2 23.11t9.2 23.11q9.19 9.2 23.11 9.2Zm-30 316.15h60v-241.54h-60v241.54Z"
        "M100-118.46v-669.23Q100-818 121-839q21-21 51.31-21h615.38Q818-860 839-839q21 21 21 51.31v455.38"
        "Q860-302 839-281q-21 21-51.31 21H241.54L100-118.46ZM216-320h571.69q4.62 0 8.46-3.85 3.85-3.84"
        " 3.85-8.46v-455.38q0-4.62-3.85-8.46-3.84-3.85-8.46-3.85H172.31q-4.62 0-8.46 3.85-3.85 3.84-3.85 8.46"
        "v523.08L216-320Zm-56 0v-480 480Z"
    ),
    # Published in the 24-unit space (no viewBox), not 960; the fit does not care.
    "auto_awesome": (
        "m18.5 8.6-1.05-2.35L15.1 5.2l2.35-1.075L18.5 1.8l1.05 2.325L21.9 5.2l-2.35 1.05Zm0 13.6"
        "-1.05-2.325L15.1 18.8l2.35-1.05 1.05-2.35 1.05 2.35 2.35 1.05-2.35 1.075Zm-9.625-3.4-2.1-4.675"
        "L2.1 12l4.675-2.125 2.1-4.675L11 9.875 15.675 12 11 14.125Zm0-3.65 1-2.15 2.15-1-2.15-1-1-2.15"
        "-1 2.15-2.15 1 2.15 1Zm0-3.15Z"
    ),
    "border_style": (
        "M293.85-140v-64.62h64.61V-140h-64.61Zm153.84 0v-64.62h64.62V-140h-64.62Zm153.85 0v-64.62h64.61"
        "V-140h-64.61Zm153.84 0v-64.62H820V-140h-64.62Zm0-153.85v-64.61H820v64.61h-64.62Zm0-153.84"
        "v-64.62H820v64.62h-64.62Zm0-153.85v-64.61H820v64.61h-64.62ZM140-140v-680h680v60H200v620h-60Z"
    ),
    "swap_vert": (
        "M336.16-453.85v-291.23L222.77-631.69 180-673.85 366.15-860l186.16 186.15-42.77 42.16"
        "-113.39-113.39v291.23h-59.99ZM593.46-100 407.31-286.15l42.77-42.16 113.38 113.39v-291.23h60"
        "v291.23l113.39-113.39 42.76 42.16L593.46-100Z"
    ),
    "timer": (
        "M367.69-850v-60h224.62v60H367.69ZM450-407.69h60v-224.62h-60v224.62ZM480-100q-70.15 0-132-26.77"
        "-61.85-26.77-108.15-73.08-46.31-46.3-73.08-108.15Q140-369.85 140-440t26.77-132q26.77-61.85"
        " 73.08-108.15 46.3-46.31 108.15-73.08Q409.85-780 480-780q60.08 0 115.73 20.39 55.65 20.38"
        " 103.35 58.38l49.84-49.84 42.15 42.15-49.84 49.84q38 47.7 58.38 103.35Q820-500.08 820-440"
        "q0 70.15-26.77 132-26.77 61.85-73.08 108.15-46.3 46.31-108.15 73.08Q550.15-100 480-100Z"
        "m0-60q116 0 198-82t82-198q0-116-82-198t-198-82q-116 0-198 82t-82 198q0 116 82 198t198 82Zm0-280Z"
    ),
    "filter_header": (
        "M455.39-180q-15.08 0-25.23-10.16Q420-200.31 420-215.39v-231.53L196.08-731.38q-11.54-15.39"
        "-3.35-32 8.2-16.62 27.66-16.62h519.22q19.46 0 27.66 16.62 8.19 16.61-3.35 32L540-446.92v231.53"
        "q0 15.08-10.16 25.23Q519.69-180 504.61-180h-49.22ZM480-468l198-252H282l198 252Zm0 0Z"
    ),
}

TOKEN = re.compile(r"[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?")


def parse(d):
    """SVG path -> list of polygons (lists of (x, y)). M/L/H/V/Q/T/Z only,
    which is every command these paths use; anything else is refused."""
    toks = TOKEN.findall(d)
    i = 0
    cmd = None
    x = y = sx = sy = 0.0
    cp = None
    polys, cur = [], []

    def num():
        nonlocal i
        v = float(toks[i])
        i += 1
        return v

    def quad(x0, y0, cx, cy, x1, y1):
        for k in range(1, CURVE_STEPS + 1):
            t = k / float(CURVE_STEPS)
            u = 1.0 - t
            cur.append((u * u * x0 + 2 * u * t * cx + t * t * x1,
                        u * u * y0 + 2 * u * t * cy + t * t * y1))

    while i < len(toks):
        if toks[i].isalpha():
            cmd = toks[i]
            i += 1
        rel = cmd.islower()
        C = cmd.upper()
        if C == "Z":
            if cur:
                polys.append(cur)
                cur = []
            x, y = sx, sy
            cp = None
            continue
        if C == "M":
            if cur:
                polys.append(cur)
            nx, ny = num(), num()
            if rel:
                nx += x
                ny += y
            x, y = sx, sy = nx, ny
            cur = [(x, y)]
            cmd = "l" if rel else "L"    # implicit lineto after a moveto
            cp = None
            continue
        if C == "L":
            nx, ny = num(), num()
            if rel:
                nx += x
                ny += y
            x, y = nx, ny
            cur.append((x, y))
            cp = None
        elif C == "H":
            nx = num()
            x = nx + x if rel else nx
            cur.append((x, y))
            cp = None
        elif C == "V":
            ny = num()
            y = ny + y if rel else ny
            cur.append((x, y))
            cp = None
        elif C == "Q":
            cx, cy, nx, ny = num(), num(), num(), num()
            if rel:
                cx += x
                cy += y
                nx += x
                ny += y
            quad(x, y, cx, cy, nx, ny)
            cp = (cx, cy)
            x, y = nx, ny
        elif C == "T":
            nx, ny = num(), num()
            if rel:
                nx += x
                ny += y
            cx, cy = (2 * x - cp[0], 2 * y - cp[1]) if cp else (x, y)
            quad(x, y, cx, cy, nx, ny)
            cp = (cx, cy)
            x, y = nx, ny
        else:
            raise ValueError("unsupported path command " + cmd)
    if cur:
        polys.append(cur)
    return polys


def render(d):
    """Fit the path's bbox into LO..HI (longer side), centred; return W rows of
    coverage 0..1, top row first."""
    polys = parse(d)
    pts = [p for poly in polys for p in poly]
    x0 = min(p[0] for p in pts)
    x1 = max(p[0] for p in pts)
    y0 = min(p[1] for p in pts)
    y1 = max(p[1] for p in pts)
    scale = (HI - LO) / max(x1 - x0, y1 - y0)       # px per path unit
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    N = W * SS

    edges = []
    for poly in polys:
        sp = [(((px - cx) * scale + W / 2.0) * SS, ((py - cy) * scale + W / 2.0) * SS)
              for px, py in poly]
        for a, b in zip(sp, sp[1:] + sp[:1]):
            if a[1] != b[1]:
                edges.append((a, b))

    hi = [[0] * N for _ in range(N)]
    for row in range(N):
        yy = row + 0.5
        cross = []
        for (ax, ay), (bx, by) in edges:
            if (ay <= yy < by) or (by <= yy < ay):
                cross.append((ax + (yy - ay) * (bx - ax) / (by - ay), 1 if by > ay else -1))
        if not cross:
            continue
        cross.sort()
        wnd = 0
        line = hi[row]
        for k in range(len(cross) - 1):
            wnd += cross[k][1]
            if wnd != 0:    # nonzero rule
                a = max(int(math.ceil(cross[k][0] - 0.5)), 0)
                b = min(max(int(math.ceil(cross[k + 1][0] - 0.5)), 0), N)
                for px in range(a, b):
                    line[px] = 1

    rows = []
    area = float(SS * SS)
    for y in range(W):
        out = []
        for x in range(W):
            s = 0
            for sy in range(y * SS, (y + 1) * SS):
                s += sum(hi[sy][x * SS:(x + 1) * SS])
            out.append(s / area)
        rows.append(out)
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

    for name in sorted(ICONS):
        rows = render(ICONS[name])
        if not preview_only:
            path = os.path.join(out_dir, name + ".tga")
            write_tga(path, rows)
            print("wrote", os.path.normpath(path))
        report(name, rows)


if __name__ == "__main__":
    main()
