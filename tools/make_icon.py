"""Generates icon.tga (the addon-list icon). Pure Python, no dependencies.

    python tools/make_icon.py            # writes icon.tga next to the .toc
    python tools/make_icon.py preview.png   # also writes a PNG preview
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZE = 64
SS = 4  # supersampling per axis

BG = (14, 17, 23)
AMBER = (255, 184, 64)
GOLD = (255, 209, 46)
GOLD_DARK = (120, 78, 8)


def inside_round_rect(x, y, r, inset=0.0):
    """Rounded square covering the icon, shrunk by `inset` on every side."""
    lo, hi = inset, SIZE - inset
    cx = min(max(x, lo + r), hi - r)
    cy = min(max(y, lo + r), hi - r)
    return lo <= x <= hi and lo <= y <= hi and (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def sample(x, y):
    """Returns (r, g, b, a) for a point, or None if transparent."""
    if not inside_round_rect(x, y, 11):
        return None
    dx, dy = x - SIZE / 2, y - SIZE / 2
    d = math.hypot(dx, dy)

    # dark body with a thin dark-amber rim
    color = BG if inside_round_rect(x, y, 9, inset=2.0) else (130, 92, 32)

    # crosshair ring
    if 17.5 <= d <= 21.5:
        color = AMBER
    # ticks along the axes (outside and inside the ring)
    if (abs(dx) <= 1.6 and (9 <= abs(dy) <= 14 or 24 <= abs(dy) <= 29)) or (
        abs(dy) <= 1.6 and (9 <= abs(dx) <= 14 or 24 <= abs(dx) <= 29)
    ):
        color = AMBER
    # quest-style exclamation mark: tapered, round-topped bar plus a round dot,
    # gold with a darker outline (like the in-game quest "!")
    if in_bang(dx, dy, 1.1):
        color = GOLD_DARK
    if in_bang(dx, dy, 0.0):
        color = GOLD
    return color + (255,)


def in_bang(dx, dy, g):
    top, bottom, r_top, r_bot = -8.4, 3.0, 4.0, 1.5
    if math.hypot(dx, dy - top) <= r_top + g:
        return True
    if top <= dy <= bottom + g:
        t = min(max((dy - top) / (bottom - top), 0.0), 1.0)
        if abs(dx) <= r_top + (r_bot - r_top) * t + g:
            return True
    return math.hypot(dx, dy - 9.5) <= 3.1 + g


def render():
    rows = []
    for py in range(SIZE):
        row = []
        for px in range(SIZE):
            acc = [0, 0, 0, 0]
            for sy in range(SS):
                for sx in range(SS):
                    c = sample(px + (sx + 0.5) / SS, py + (sy + 0.5) / SS)
                    if c:
                        a = c[3]
                        acc[0] += c[0] * a
                        acc[1] += c[1] * a
                        acc[2] += c[2] * a
                        acc[3] += a
            n = SS * SS
            if acc[3] == 0:
                row.append((0, 0, 0, 0))
            else:
                row.append((round(acc[0] / acc[3]), round(acc[1] / acc[3]),
                            round(acc[2] / acc[3]), round(acc[3] / n)))
        rows.append(row)
    return rows


def write_tga(path, rows):
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8 | 0x20)
    data = b"".join(struct.pack("BBBB", b, g, r, a) for row in rows for (r, g, b, a) in row)
    Path(path).write_bytes(header + data)


def write_png(path, rows):
    raw = b"".join(b"\x00" + bytes(v for px in row for v in px) for row in rows)

    def chunk(tag, body):
        c = struct.pack(">I", len(body)) + tag + body
        return c + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    Path(path).write_bytes(png)


if __name__ == "__main__":
    pixels = render()
    out = Path(__file__).resolve().parent.parent / "icon.tga"
    write_tga(out, pixels)
    print("wrote", out)
    if len(sys.argv) > 1:
        write_png(sys.argv[1], pixels)
        print("wrote", sys.argv[1])
