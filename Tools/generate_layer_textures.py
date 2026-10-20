"""Generate the texture-layer test set: white alpha masks the layer colour tints.

Usage: python Tools/generate_layer_textures.py

Patterns tile on BOTH axes, so every one is square, power-of-two and seamless:
each pixel is sampled with wrap-around from a supersampled field. Shading masks
tile along the bar and stretch across it (HORIZ); each ships a _Vert companion
generated along the other axis (VERT), never rotated from the finished image.
"""
import math
import pathlib

from PIL import Image

OUT = pathlib.Path(__file__).resolve().parents[1] / "DandersFrames" / "Media"
SS = 8  # supersamples per axis


def render(w, h, alpha_at, name):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            acc = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    u = (x + (sx + 0.5) / SS) / w
                    v = (y + (sy + 0.5) / SS) / h
                    acc += alpha_at(u, v)
            a = max(0.0, min(1.0, acc / (SS * SS)))
            px[x, y] = (255, 255, 255, int(round(a * 255)))
    img.save(OUT / f"{name}.png", optimize=True)
    print(f"{name}.png  {w}x{h}  {(OUT / f'{name}.png').stat().st_size} bytes")


def band(d, half_width):
    """1 inside a band of the given half width around d == 0, soft 1px-ish edge."""
    return 1.0 if abs(d) <= half_width else 0.0


# ---- patterns (BOTH) --------------------------------------------------------

def diagonal(periods, width):
    # Lines of slope 1 that wrap: the phase u + v repeats every 1/periods.
    def f(u, v):
        t = ((u + v) * periods) % 1.0
        d = min(t, 1.0 - t)
        return band(d, width)
    return f


def diagonal_vert(periods, width):
    # The companion's phase is a true 90-degree rotation, (x, y) -> (y, -x): the
    # lines lean the other way, as DF's art does on a vertical bar.
    def f(u, v):
        t = ((v - u) * periods) % 1.0
        d = min(t, 1.0 - t)
        return band(d, width)
    return f


def dots(radius):
    def f(u, v):
        du, dv = u - 0.5, v - 0.5
        return 1.0 if du * du + dv * dv <= radius * radius else 0.0
    return f


def grid(width):
    def f(u, v):
        du = min(u, 1.0 - u)
        dv = min(v, 1.0 - v)
        return 1.0 if du <= width or dv <= width else 0.0
    return f


def checker(level=0.6):
    def f(u, v):
        return level if (u < 0.5) != (v < 0.5) else 0.0
    return f


# ---- shading (HORIZ, gradient across the bar) -------------------------------

def shade_top(t):      # t = 0 at the top edge, 1 at the bottom
    return max(0.0, 1.0 - t / 0.55) ** 1.6 * 0.9


def shade_bottom(t):
    return shade_top(1.0 - t)


def shade_bevel(t):
    e = min(t, 1.0 - t)
    return max(0.0, 1.0 - e / 0.22) ** 1.4 * 0.85


def shade_tube(t):
    return math.sin(math.pi * t) ** 1.5 * 0.8


def horiz(fn):
    return lambda u, v: fn(v)


def vert(fn):
    # Companion for a vertical bar: the gradient runs across the bar's THICKNESS,
    # which is now the x axis; "top" (the start of the cross axis) becomes the left.
    return lambda u, v: fn(u)


if __name__ == "__main__":
    render(16, 16, diagonal(2, 0.12), "DF_Layer_Diagonal")
    render(16, 16, diagonal_vert(2, 0.12), "DF_Layer_Diagonal_Vert")
    render(64, 64, diagonal(2, 0.12), "DF_Layer_Diagonal_HD")
    render(64, 64, diagonal_vert(2, 0.12), "DF_Layer_Diagonal_HD_Vert")
    render(16, 16, dots(0.22), "DF_Layer_Dots")
    render(16, 16, grid(0.07), "DF_Layer_Grid")
    render(32, 32, checker(), "DF_Layer_Checker")
    for name, fn in (("Top", shade_top), ("Bottom", shade_bottom),
                     ("Bevel", shade_bevel), ("Tube", shade_tube)):
        render(8, 64, horiz(fn), f"DF_Layer_Shade_{name}")
        render(64, 8, vert(fn), f"DF_Layer_Shade_{name}_Vert")
