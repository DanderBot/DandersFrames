#!/usr/bin/env python3
"""
Generate DandersFrames/Media/Icons/music_note.tga -- the mark on the Add
Indicator panel's Sound tile.

WHY IT EXISTS. Every tile in that panel is a picture of the result, and a sound
alert changes NOTHING about the frame -- so the Sound tile honestly draws an
untouched one. The trouble is that an untouched frame is also exactly what
"nothing chosen" looks like, so the honest picture said the wrong thing. A note
laid over the mock keeps the picture honest and adds the one word it was
missing. Nothing in Media/Icons was a sound or a note (the closest was
`notes.tga`, which is a document), so it is drawn here.

THE SHAPE. Material's `music_note`, which is a filled quaver:

    * a NOTEHEAD -- a circle, bottom left;
    * a STEM -- a thick bar rising from the notehead's right side;
    * a FLAG -- a block on the stem's right at the top.

Authored analytically the way generate_undo_icons.py and generate_scale_icon.py
are: geometry in the icon's own 32px space, supersampled into coverage, written
out as flat white with the shape in the alpha channel so SetVertexColor tints it
like every sibling.

WEIGHT. A filled quaver is a solid glyph rather than a stroked one, so it does
not sit at the ~15% coverage the arrow icons do; what it matches instead is the
ink BOX -- x/y 3..29, the clear border close.tga, refresh.tga and undo.tga all
keep -- so it reads at the same size beside them.

Output matches the sibling 32px icons byte-for-byte in format: 32x32, 32-bit
BGRA, uncompressed (image type 2), BOTTOM-left origin (descriptor 0x08), plus
the TGA 2.0 footer they all carry.

Run from anywhere:  python generate_music_note_icon.py [repo-root] [--preview]
"""

import os
import struct
import sys

W = H = 32
SUB = 6           # sub-samples per axis -> 36 per pixel

# --- the glyph, in the icon's own 32px space (y DOWN, like the drawing) -----
#
# Material's music_note is authored in a 24px box as: stem x 12..16 from y 3
# down to the notehead, flag x 16..20 y 3..7, notehead a circle at (10, 17)
# with r 4. Those proportions are kept; the numbers below are that drawing
# fitted to the 3..29 ink box its siblings use.

# The notehead.
NOTE_CX, NOTE_CY, NOTE_R = 9.3, 22.9, 6.1

# The stem: a thick bar off the notehead's right, running to the top margin.
# Its left edge is inside the notehead so the two read as one object rather
# than as a circle with a line resting on it.
STEM_L, STEM_R = 13.3, 18.1
STEM_TOP, STEM_BOT = 3.0, 22.9

# The flag: a block on the stem's right at the top. Wider than the stem and
# only a third as tall, which is what stops it reading as a second stem.
FLAG_L, FLAG_R = 18.1, 29.0
FLAG_TOP, FLAG_BOT = 3.0, 9.4


def inside(x, y):
    """Is (x, y) in the NOTE? The union of notehead, stem and flag."""
    if (x - NOTE_CX) ** 2 + (y - NOTE_CY) ** 2 <= NOTE_R * NOTE_R:
        return True
    if STEM_L <= x <= STEM_R and STEM_TOP <= y <= STEM_BOT:
        return True
    if FLAG_L <= x <= FLAG_R and FLAG_TOP <= y <= FLAG_BOT:
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
    """Coverage, ink box and an ASCII preview -- the only way to eyeball a glyph
    that nothing in this toolchain can render."""
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
        print("  " + "".join("#" if a > 0.6 else ("." if a > 0.15 else " ") for a in row))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    preview_only = "--preview" in sys.argv[1:]
    root = args[0] if args else os.getcwd()
    out_dir = os.path.join(root, "DandersFrames", "Media", "Icons")

    rows = render(W)
    if not preview_only:
        path = os.path.join(out_dir, "music_note.tga")
        write_tga(path, rows)
        print("wrote", os.path.normpath(path))
    report("music_note", rows)


if __name__ == "__main__":
    main()
