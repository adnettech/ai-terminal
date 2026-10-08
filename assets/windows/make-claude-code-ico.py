#!/usr/bin/env python3
"""Render the Claude Code mascot as a Windows icon (assets/windows/claude-code.ico).

The figure is Claude Code's own startup banner, decoded glyph by glyph: each block
character is a 2x2 grid of quadrants, and a terminal cell is twice as tall as it is wide,
so one quadrant is a 1-wide, 2-tall pixel. Body colour is Claude Code's clawd_body,
rgb(215,119,87). Re-run after changing the map (needs Pillow):
    uv run --with pillow python3 assets/windows/make-claude-code-ico.py
"""
import pathlib
from PIL import Image, ImageDraw

BANNER = [" ▐▛███▜▌", "▝▜█████▛▘", "  ▘▘ ▝▝"]
# quadrants per glyph: top-left, top-right, bottom-left, bottom-right
Q = {" ": "0000", "█": "1111", "▐": "0101", "▌": "1010", "▛": "1110", "▜": "1101",
     "▝": "0100", "▘": "1000", "▙": "1011", "▟": "0111", "▖": "0010", "▗": "0001"}
BODY = (215, 119, 87, 255)
TILE = (38, 24, 20, 255)          # dark rounded tile, like Claude Code's own app icon

w = 2 * max(len(r) for r in BANNER)
grid = [[0] * w for _ in range(2 * len(BANNER))]
for r, line in enumerate(BANNER):
    for c, ch in enumerate(line):
        tl, tr, bl, br = (int(x) for x in Q[ch])
        grid[2 * r][2 * c], grid[2 * r][2 * c + 1] = tl, tr
        grid[2 * r + 1][2 * c], grid[2 * r + 1][2 * c + 1] = bl, br
while grid and not any(grid[-1]):
    grid.pop()
cols = [c for c in range(w) if any(row[c] for row in grid)]
c0, c1 = min(cols), max(cols)
grid = [row[c0:c1 + 1] for row in grid]
gw, gh = len(grid[0]), len(grid) * 2          # quadrant pixels are 1 wide, 2 tall


def render(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=size * 0.22, fill=TILE)
    unit = (size * 0.80) / gw
    ox, oy = (size - gw * unit) / 2, (size - gh * unit) / 2
    for y, row in enumerate(grid):
        for x, on in enumerate(row):
            if on:
                d.rectangle([ox + x * unit, oy + 2 * y * unit,
                             ox + (x + 1) * unit - 1, oy + 2 * (y + 1) * unit - 1], fill=BODY)
    return img


out = pathlib.Path(__file__).resolve().parent / "claude-code.ico"
sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
big = render(1024)
big.save(out, sizes=[(s, s) for s in sizes])
print(f"wrote {out} ({', '.join(map(str, sizes))})")
