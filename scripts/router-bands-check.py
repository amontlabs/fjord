#!/usr/bin/env python3
# Checks the Router demo's frames for empty bands: for each `frame-*.jpg` that `--frames` wrote with its `rows-*.json`,
# finds the tallest run of the list's column that is bare page (no ink, no ground) between the top of the first row and
# the top of the last row drawn above the dock's fade (`--bottom`, in points from the content view's top), and lists
# the frames where it is taller than `--max` points (default 48: the air between two lines, or around a section header,
# is 32 at most). A card shutting in a block used to leave its height bare under the block for the glide's length.
#
#   .build/debug/Fjord --window --router-v2-demo --beats 45 --frames /tmp/b --frames-rate 60 --quit-after
#   python3 scripts/router-bands-check.py /tmp/b
import json
import os
import sys

from PIL import Image


def main():
    args = sys.argv[1:]
    opts = {"--bottom": 860.0, "--max": 48.0}
    for k in list(opts):
        if k in args:
            i = args.index(k)
            opts[k] = float(args[i + 1])
            del args[i:i + 2]
    if len(args) != 1:
        sys.exit("usage: router-bands-check.py <frames dir> [--bottom <pt>] [--max <pt>]")
    folder = args[0]
    frames = sorted(f for f in os.listdir(folder) if f.startswith("frame-"))
    worst, flagged, checked = 0.0, [], 0
    for name in frames:
        rects = os.path.join(folder, f"rows-{name[6:11]}.json")
        if not os.path.exists(rects):
            continue
        rows = [r for r in json.load(open(rects)).values() if r[3] >= 12 and r[1] >= 0]
        if not rows:
            continue
        image = Image.open(os.path.join(folder, name)).convert("L")
        scale = image.width / 1280.0
        px = image.load()
        x = min(r[0] for r in rows)
        x0, x1 = int((x + 8) * scale), int((x + 380) * scale)
        top = min(r[1] for r in rows)
        # Down to the last row's top: what is under the last row (a card opening at the page's end) is not between rows.
        bottom = max([r[1] for r in rows if r[1] + r[3] <= opts["--bottom"]] or [top])
        y0, y1 = int(top * scale), min(int(bottom * scale), image.height)
        if y1 <= y0:
            continue
        # The page's own colour: the most common shade just left of the rows (a card's ground is inside them).
        edge = [px[max(0, int((x - 6) * scale)), y] for y in range(y0, y1)]
        page = max(set(edge), key=edge.count)
        run = longest = 0
        for y in range(y0, y1):
            bare = all(abs(px[xx, y] - page) <= 3 for xx in range(x0, x1, 2))
            run = run + 1 if bare else 0
            longest = max(longest, run)
        tall = longest / scale
        checked += 1
        worst = max(worst, tall)
        if tall > opts["--max"]:
            flagged.append((name[6:11], round(tall)))
    for at, tall in flagged:
        print(f"frame {at}: a bare band {tall} pt tall")
    print(f"{len(flagged)} frames with an empty band over {opts['--max']:.0f} pt, of {checked} (tallest {worst:.0f} pt)")


if __name__ == "__main__":
    main()
