"""Cost of the Router v2 typing pauses (Jev at J ms, Sonnet at S ms after the last key) in model calls per message.
No keystroke timing is logged anywhere (no decider-log.jsonl exists on this machine yet), so this simulates typing:
inter-key gaps lognormal (median 170 ms, sigma .5; a non-touch typist on an AZERTY keyboard, Dhakal 2018 reports a 238 ms mean),
plus a thinking pause after a key with probability P_THINK, lognormal (median 800 ms, sigma .8), more likely at spaces.
A message's length (characters) is drawn from the dev moments' real lengths if evals/router/t3/data is present, else 130.
Sonnet reads: one starts when a gap >= S passes; it is wasted when a key follows within CALL ms (the call is cancelled); the last one is used.
  python3 typing_pauses.py [--n 4000]"""
import json, math, pathlib, random, statistics, sys

HERE = pathlib.Path(__file__).parent
try:
    sys.path.insert(0, str(HERE.parent / "t3")); import n3common as C
    M = C.moments(); LENS = [len(M[i]["message"]) for i in sorted(C.load_sample()["ids"])]
    LENS = [min(max(n, 15), 600) for n in LENS]   # a real typed message; pasted walls are clipped
except Exception:   # noqa: BLE001
    LENS = [130]
CALL = 4000   # ms a Sonnet call takes (claude -p, N4 p50 3.4 s + start-up)


def draft(rng, n, p_think):
    t, keys = 0.0, []
    for k in range(n):
        gap = rng.lognormvariate(math.log(170), .5)
        if rng.random() < p_think * (2.5 if k % 6 == 5 else 1): gap += rng.lognormvariate(math.log(800), .8)
        t += gap; keys.append(t)
    return keys


def calls(keys, J, S):
    gaps = [b - a for a, b in zip(keys, keys[1:])]
    jev = 1 + sum(g >= J for g in gaps)                       # every pause >= J reads, plus the one after the last key
    # Sonnet starts at S after a key when no key arrives sooner; it is wasted if a key arrives within CALL of its start
    starts = [(S, g) for g in gaps if g >= S]
    wasted = sum(1 for _, g in starts if g < S + CALL)
    return jev, 1 + len(starts), wasted


def gated(keys, S, min_chars=12, new_chars=10):
    """Sonnet starts with two guards: the draft has at least `min_chars` keys, and `new_chars` more than at the last start."""
    gaps = [b - a for a, b in zip(keys, keys[1:])] + [10 ** 9]
    last, starts, wasted = -10 ** 9, 0, 0
    for n, g in enumerate(gaps, 1):
        if g >= S and n >= min_chars and n - last >= new_chars:
            starts += 1; last = n
            if g < S + CALL: wasted += 1
    return starts, wasted


def main(n=4000, seed=7):
    rng = random.Random(seed)
    print("| thinking pauses per key | pauses (J / S) ms | Jev reads / message | Sonnet starts / message | cancelled Sonnet / message | cancelled per 100 chars |")
    print("|---|---|---|---|---|---|")
    for pt in (0.02, 0.05, 0.10):
        sample = [draft(rng, rng.choice(LENS), pt) for _ in range(n)]
        for J, S in ((600, 1200), (600, 600), (300, 600), (300, 1200), (200, 400)):
            r = [calls(k, J, S) for k in sample]; ch = statistics.mean(len(k) for k in sample)
            print(f"| {pt:.0%} | {J} / {S} | {statistics.mean(x[0] for x in r):.2f} | {statistics.mean(x[1] for x in r):.2f} | {statistics.mean(x[2] for x in r):.2f} | {100*statistics.mean(x[2] for x in r)/ch:.2f} |")
    print("\nWith the guards (>= 12 characters, >= 10 new characters since the last start), Sonnet pause S:")
    print("| thinking pauses per key | S ms | Sonnet starts / message | cancelled / message |\n|---|---|---|---|")
    for pt in (0.02, 0.05, 0.10):
        sample = [draft(rng, rng.choice(LENS), pt) for _ in range(n)]
        for S in (600, 1200):
            r = [gated(k, S) for k in sample]
            print(f"| {pt:.0%} | {S} | {statistics.mean(x[0] for x in r):.2f} | {statistics.mean(x[1] for x in r):.2f} |")
    print(f"\nmean length {statistics.mean(LENS):.0f} chars, median {statistics.median(LENS):.0f}")


if __name__ == "__main__":
    main(int(sys.argv[sys.argv.index("--n") + 1]) if "--n" in sys.argv else 4000)
