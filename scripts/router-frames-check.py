#!/usr/bin/env python3
# Checks the Router demo's frames for rows that aren't drawn where they are: for each `frame-*.jpg` that `--frames` wrote
# with its `rows-*.json` (each row's drawn rect, glide included), counts the ink in the row's own band (a line's top
# 34 pt, a header's whole row) and lists the frames where a row has less than 30 % of its usual ink. Rows under the
# dock's fade are left out (`--bottom`, in points from the content view's top). Needs Pillow.
#
#   .build/debug/Fjord --window --router-v2-demo --select-check few --frames /tmp/sc --frames-rate 60 --quit-after
#   python3 scripts/router-frames-check.py /tmp/sc
#
# The picture is the render server's frame, made for the screen's next refresh, and the rects are read from the app's
# presentation layers now: while rows glide, the picture shows them all a little further on, 15 to 80 pt in a tall card's
# roll, contiguous. So the rows that moved since the frame before are counted at the one offset (within ±96 pt) that
# fits them best together; the rows that didn't, in place. A row that isn't drawn is blank at that offset while the rows
# around it are not. A frame where a key landed between the picture and the rects can still show the rows at their old
# places: look at it before counting it.
import json
import os
import sys

from PIL import Image

SPAN = 96


def main():
    args = sys.argv[1:]
    bottom = 860.0
    if "--bottom" in args:
        i = args.index("--bottom")
        bottom = float(args[i + 1])
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit("usage: router-frames-check.py <frames dir> [--bottom <pt>]")
    folder = args[0]
    frames = sorted(f for f in os.listdir(folder) if f.startswith("frame-"))
    pairs = [(name, os.path.join(folder, f"rows-{name[6:11]}.json")) for name in frames]
    pairs = [(name, json.load(open(rects))) for name, rects in pairs if os.path.exists(rects)]

    def band(row, h):
        return h if row.startswith(("header", "housekeeping", "reading")) else min(h, 34)

    # Each frame's rows to check, with their ink at every offset.
    measured = []
    previous = {}
    for name, rows in pairs:
        image = Image.open(os.path.join(folder, name)).convert("L")
        scale = image.width / 1280.0
        pixels = image.load()
        # Per column span, the dark pixels of every other pixel row, summed down the picture: a band's ink is a difference.
        sums = {}

        def ink(row, x, y, h):
            x0, x1 = int((x + 24) * scale), min(int((x + 380) * scale), image.width)
            if (x0, x1) not in sums:
                acc, total = [0], 0
                for yy in range(0, image.height, 2):
                    total += sum(1 for xx in range(x0, x1, 2) if pixels[xx, yy] < 150)
                    acc.append(total)
                sums[(x0, x1)] = acc
            acc = sums[(x0, x1)]
            y0, y1 = max(0, int((y + 4) * scale)), min(int((y + band(row, h) - 4) * scale), image.height)
            if y1 <= y0:
                return 0
            return acc[(y1 + 1) // 2] - acc[(y0 + 1) // 2]

        checked = []
        for row, (x, y, w, h) in rows.items():
            if h < 12 or y < 0 or y + band(row, h) > bottom:
                continue
            moved = row in previous and previous[row] != [x, y, w, h]
            offsets = range(-SPAN, SPAN + 1, 4) if moved else [0]
            checked.append((row, round(y), moved, {dy: ink(row, x, y + dy, h) for dy in offsets}))
        measured.append((name[6:11], checked))
        previous = rows

    counts = {}
    for _, checked in measured:
        for row, _, _, by in checked:
            counts.setdefault(row, []).append(by[0])
    usual = {row: max(1, sorted(v)[len(v) // 2]) for row, v in counts.items()}

    seen = []
    for at, checked in measured:
        moving = [c for c in checked if c[2]]
        best = 0
        if moving:
            best = max(range(-SPAN, SPAN + 1, 4), key=lambda dy: (sum(min(1.0, c[3][dy] / usual[c[0]]) for c in moving), -abs(dy)))
        for row, y, moved, by in checked:
            seen.append((at, row, by[best if moved else 0], y, best if moved else 0))
    missing = [s for s in seen if s[2] < max(20, 0.3 * usual[s[1]])]
    print(f"{len(pairs)} frames, {len(seen)} rows checked, {len(missing)} missing")
    for at, row, ink, y, dy in missing:
        print(f"  frame {at}: {row} at y {y} (+{dy}) has {ink} ink (usually {usual[row]})")
    sys.exit(1 if missing else 0)


main()
