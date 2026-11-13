#!/usr/bin/env python3
# Checks the Router demo's frames for rows that aren't drawn where they are: for each `frame-*.jpg` that `--frames` wrote
# with its `rows-*.json` (each row's drawn rect, glide included), counts the ink in the row's own band (a line's top
# 34 pt, a header's whole row) and lists the frames where a row has less than 30 % of its usual ink. Rows under the
# dock's fade are left out (`--bottom`, in points from the content view's top). Needs Pillow.
#
#   .build/debug/Fjord --window --router-v2-demo --select-check few --frames /tmp/sc --frames-rate 60 --quit-after
#   python3 scripts/router-frames-check.py /tmp/sc
#
# A frame where a key landed between the picture and the rects (the picture is the last composited frame) can show the
# rows at their old places: look at it before counting it.
import json
import os
import sys

from PIL import Image


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
    seen = []
    counts = {}
    frames = sorted(f for f in os.listdir(folder) if f.startswith("frame-"))
    for name in frames:
        at = name[6:11]
        rects = os.path.join(folder, f"rows-{at}.json")
        if not os.path.exists(rects):
            continue
        rows = json.load(open(rects))
        image = Image.open(os.path.join(folder, name)).convert("L")
        scale = image.width / 1280.0
        pixels = image.load()
        for row, (x, y, w, h) in rows.items():
            band = h if row.startswith(("header", "housekeeping", "reading")) else min(h, 34)
            if h < 12 or y < 0 or y + band > bottom:
                continue
            x0, x1 = int((x + 24) * scale), min(int((x + 380) * scale), image.width)
            y0, y1 = int((y + 4) * scale), int((y + band - 4) * scale)
            ink = sum(1 for yy in range(y0, y1, 2) for xx in range(x0, x1, 2) if pixels[xx, yy] < 150)
            counts.setdefault(row, []).append(ink)
            seen.append((at, row, ink, round(y)))
    usual = {row: sorted(v)[len(v) // 2] for row, v in counts.items()}
    missing = [s for s in seen if s[2] < max(20, 0.3 * usual[s[1]])]
    print(f"{len(frames)} frames, {len(seen)} rows checked, {len(missing)} missing")
    for at, row, ink, y in missing:
        print(f"  frame {at}: {row} at y {y} has {ink} ink (usually {usual[row]})")
    sys.exit(1 if missing else 0)


main()
