#!/usr/bin/env python3
"""Make a binary PPM (P6) test card: colour bars, grey ramp, geometry and a
corner grid. Pure stdlib, so the self-test runs on a bare macOS python3.

  gen_testcard.py out.ppm [W H]
"""
import sys


def edge_bars(w, h, bars):
    out = bytearray()
    cols = [
        (255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
        (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0),
    ]
    for y in range(bars[0], bars[1]):
        for x in range(w):
            out += bytes(cols[min(len(cols) - 1, x * len(cols) // w)])
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "testcard.ppm"
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 640
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 496

    px = bytearray(w * h * 3)

    def put(x, y, c):
        if 0 <= x < w and 0 <= y < h:
            i = (y * w + x) * 3
            px[i:i + 3] = bytes(c)

    top = h // 8
    mid = h * 5 // 8
    px[0:len(edge_bars(w, h, (0, top)))] = edge_bars(w, h, (0, top))  # colour bars

    for y in range(top, mid):                                          # grey ramp
        for x in range(w):
            v = x * 255 // max(1, w - 1)
            put(x, y, (v, v, v))

    for y in range(mid, h):                                            # grid + shapes
        for x in range(w):
            g = 24 if ((x // 32) + (y // 32)) % 2 else 200
            put(x, y, (g, g // 2, 255 - g))

    # crosshair and circles
    cx, cy, r = w // 2, h // 2, min(w, h) // 6
    for t in range(-2, 3):
        for x in range(w):
            put(x, cy + t, (255, 255, 0))
        for y in range(h):
            put(cx + t, y, (255, 255, 0))
    for a in range(0, 3600):
        import math
        th = a * math.pi / 1800
        x = int(cx + r * math.cos(th))
        y = int(cy + r * math.sin(th) * h / w * (w / h))
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                put(x + dx, y + dy, (255, 0, 0))

    # corner blocks so orientation mistakes are obvious
    for (bx, by, c) in ((0, 0, (255, 0, 0)), (w - 40, 0, (0, 255, 0)),
                        (0, h - 40, (0, 0, 255)), (w - 40, h - 40, (255, 255, 255))):
        for y in range(by, by + 40):
            for x in range(bx, bx + 40):
                put(x, y, c)

    with open(path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (w, h))
        f.write(bytes(px))
    print("%s: %dx%d" % (path, w, h))


if __name__ == "__main__":
    main()
