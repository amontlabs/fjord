# Router routing evals

How well Jev routes what you type in the Router, measured on boards like yours. The whole story (what worked, what
wasn't enough, dead ends, mistakes, open leads) is in docs/design/router-research.md.

- `cases/` (210: everyday, hard, traps) and `heldout/` (150, written independently, bigger boards): see CASES.md. Gold
  was relabelled blind; what either labeler accepts counts, asking is fine when either allows it.
- `jev.py`: TypeSafe client (key from Lookout's Keychain item), answers cached in `cache/`.
- `formats.py`: ways of asking. `v0` is what Lookout sent before (opaque t-keys, fenced descriptions, the last
  decisions); `v3-told+g` is what it sends now.
- `run.py FORMAT --orders 3 [--cases "heldout/*.jsonl" --tag=-ho] [--pad 22]`: asks every case (each order shuffles
  the options), saves the answers in `runs/`.
- `analyze.py`, `crossval.py`, `cv.py`: policies swept over saved answers, tuned on one set and tested on the other,
  pooled k-fold cross-validation.
- `rerank.py` (a second pass over the top candidates), `transforms.py` (boards padded to 22 sessions), `veto.py`
  (Lookout's word-overlap veto).

## Findings (jev-1.13.0, 2026-10-11)

Both sets pooled (360 cases, 2–3 option orders each), one configuration fixed in advance:

| | right sends | wrong session | wrong, to Lookout's own (question, compound) | needless asks |
|---|---|---|---|---|
| before | 42.9% | 1.7% | 0% | 29.8% |
| now | 68.6% | 1.1% | 1.2% | 11.4% |

What moved it, and what did not:

1. A card and its session were two options, so Jev's sureness of the session was split between them (p 0.5 + 0.4
   reads as unsure). One option per destination: +18 points of right sends on the first set, no new call.
2. Opaque keys whose descriptions sat in a fenced state blob flipped the top answer with the options' order in 38 of
   210 cases. Options named by the session, described in their own criteria, ranked better (top1 89% vs 85%).
   Correction (round 2): jev.py sends `json.dumps(sort_keys=True)`, so named options always reached Jev in the same
   (alphabetical) order and their "0–8 flips" measured nothing; only v0's flips are real, as its keys change with the
   order. Lookout sends the options in Swift dictionary order, which varies from run to run.
3. Context: what you last told a session belongs on that session's option. The global list of your last 10 messages
   was worse with it (61% vs 69% right) and caused the worst errors: "yes" sent to the session you last messaged
   instead of the one asking. Examples of past routings had no measurable effect on these sets and were dropped.
4. Bare replies ("yes", "lgtm", "nope", "the second one") read as `unclear` in the route question even with one card
   waiting. A yes/no per waiting card ("is `message` the answer to `card`?") gets them: 0.6–0.85 where the route said
   0.05. When it and the route both point elsewhere with confidence, ask.
5. "Turn a setting off" went to the session building that feature, in every format. A yes/no gate on whether the
   message changes how Lookout behaves, and one on whether it asks for several things, decide those first.
6. Thresholds by what a wrong pick costs: a session ≥ 0.7, a new session ≥ 0.6, Lookout's own intents (answered, or a
   change you can revert) ≥ 0.6. One bar for all (0.75 with a 0.3 lead) asked on a third of clear messages.
7. The word-overlap veto (`evidenced`) blocked 48 right sends and no wrong one on top of this.
8. Not worth it: a second, narrower pass (better top-1, overconfident), asking per-session yes/no instead of one
   choice (77% top-1 vs 89%), averaging several option orders (helps the old format only), instruction rules
   (more rules, worse), shortening long-idle sessions (noise).
9. Latency: one call, median 0.24 s, p95 0.3–0.4 s, about 1–2k input tokens.

Differences under ~5 points between similar variants are noise at this size (bootstrap 95% intervals ±5–7).

## Round 2 (2026-10-11): real moments

Written cases misled. `real/` rebuilds 611 moments from your own Claude Code transcripts (the message you typed into
a session, the board as Lookout would have shown it then, where it went; labelled by whether the board alone shows
it; keys and tokens redacted before anything reaches Jev; data stays in gitignored `real/data/`), and 332 Router-style
messages were written on those boards (`style`). `bench.py` scores every set; tune on `realA`, judge on `realB`
(sessions never tuned on) and `heldout`. On real moments round 1's router was right 15% of the time and wrong 20%.

| set (right / wrong) | round 1 | now (`combo` + `explore.fuse2:guarded`) |
|---|---|---|
| synth | 64.3 / 2.4 | 58.6 / 1.4 |
| heldout | 75.3 / 1.3 | 68.0 / 2.0 |
| style | 70.8 / 1.8 | 69.6 / 0.9 |
| realB | 14.5 / 21.5 | 34.6 / 4.7 |

Every real wrong send left is one the labellers found ambiguous (mostly a session's first message where a near-identical
session existed). What did it (explore/, one module per explorer):
1. `question` caught questions you ask a session about its own work (p > 0.95); worded as "a question to Lookout
   about the board, not to a session about its own work", plus a gate on whether the message speaks to one agent as
   "you" that vetoes Lookout's intents, and a compound gate that says one long message for one session is no:
   real wrong 20% → 9%.
2. Recency: a real message went to the session that just finished 60% of the time; Jev reads "3m ago" poorly. A
   yes/no per latest session ("is `message` your next message in this conversation?") is right 91 of 95 times when one
   stands out and the route doesn't disagree; a small fitted model (P ∝ exp(w·features): Jev's log p, recency ranks,
   running, the checks, the gates) weighs Jev with the board, and a logistic on the moment says how sure its pick is.
3. The decision: the rules' send when the fusion agrees (P ≥ 0.5), else the fusion's own pick at sureness 0.9, for
   three words or more, never Lookout's own.
4. Order: jev.py used to sort keys, so named options were never shuffled; shuffled for real, the decision changed on
   14% of real moments, and Lookout's own order (working, then latest finished) was the best. Lookout now sends them in
   that order (JevClient.orderedObject).
5. Not worth it: categorical recency words, a "latest" field (Jev obeys it as an instruction: 32% wrong), richer
   context (+4–5 top1 at +40% tokens), fewer options, a second verification call.
Swift (RouteFusion) decides exactly as the measured policy on all 360 written cases (RouterFusionParityTests).

## Round 3 (2026-10-11): research, and the words

A literature pass (disentanglement, calibration, selective prediction, per-user learning, cascades) and five explorers
(explore/state, personal, cascade, selective, lexical). Measured with options in Lookout's order (`combo-o`).

| set (right / wrong) | round 2 | round 3 (`combo-o` + `explore.final3:best`) |
|---|---|---|
| synth | 57.1 / 1.4 | 65.2 / 1.4 |
| styleB | 68.1 / 0.0 | 71.4 / 0.0 |
| realA | 29.2 / 3.8 | 37.5 / 3.5 |
| realB | 37.9 / 4.7 | 40.7 / 2.8 |
| heldout | 67.3 / 2.0 | 72.0 / 2.7 |

What helped:
1. Words (real/lexical.py, explore/lexical.py): BM25 between the message and each session's transcript, per field
   (its last answer +1.11, older turns halving with age +1.36, what you last told it −0.84: a message repeating your own
   last instruction starts something new; title −0.57). Alone it names where a real follow-up went 54% of the time.
2. A guard on the rules (explore/selective.py, lexical.py): 24 of 25 real wrong sends came from the rules' path, the
   fused pick at sureness 0.9 was right 78 of 79; a rules' send now needs the fused pick to agree at sureness ≥ 0.6.
3. Short replies (explore/state.py): "go", "2", "yes do it" go to the fused pick at sureness ≥ 0.95 when that
   session's last message asks or proposes something.
4. The ask card shows four options: the right one is among them 79–89% of the time on real asks.
What didn't: calibrating against a content-free message, averaging two option orders, exact identifiers (in 39 of
611 real messages), session-state × message-type features beyond the short-reply rule, Haiku on the asks (as wrong as
right on real asks, +1–4 s), a second Jev pass per candidate.
Promising, not built: a per-user refit of the fusion weights from your own corrections and kept sends (explore/
personal.py): after ~50 labels, late real wrong sends 4.5% → 2.3% in a time-ordered replay.
Two live keys in your transcripts (an OpenRouter and a z.ai key) reached TypeSafe in eval requests before redaction
caught them; real/boards.py now also strips any long letters-and-digits token, and Lookout redacts the same way
before anything goes to Jev (RouterTools.redacted).

## A whole-life line per session (2026-10-21, explore/life.py)

UniiChat keeps a chat as a tree of one-line summaries whose root says what the whole conversation has been about. Here
each session option also carries `what it has been about overall`: one line (≤ 300 chars) Haiku wrote from the
session's turns before the moment (earlier turns' messages and answers, the current turn's message alone), keyed by
session and turn (1,145 lines for the real boards, in gitignored real/data/life.json). Everything else is the ship form
(`combo-o` + final3); the written sets are no longer in the repo, so both formats are refit on realA + styleA (**with a
leaky style split, corrected in the next section**: the refit numbers below, and the realB-only ones, moved a little) and paired
per case on all 610 labelled real moments (95% intervals from a session-grouped bootstrap):

| real (paired) | combo-o | combo-life | Δ |
|---|---|---|---|
| Jev's top-1 (no fitting involved) | 44.3 | 52.1 | +7.9 [+5.2, +10.6], 61 gained / 13 lost |
| right sends | 35.7 | 41.6 | +5.9 [+3.3, +8.5] |
| wrong sends | 2.8 | 3.1 | +0.3 [−0.5, +1.1] |
| needless asks | 18.7 | 14.8 | −3.9 [−6.3, −1.6] |

- Top-1 rises on clear (+9.5) and plausible (+7.1) moments alike; Jev's own ranking needs no tuning, so this holds for
  realA too.
- realB alone (sessions never tuned on, n=213): right 36.6 → 39.4, wrong 2.8 → 2.8, top-1 48.8 → 52.6; the right-send
  gain there is within noise. Most of the right-send gain on all real is realA, where the weights were fit.
- With the shipped weights unchanged the line makes Jev surer and wrong sends rise (real 2.9 → 4.4%): shipping it needs
  a refit of RouteFusion's tables.
- Cost: +18% input tokens (3,130 → 3,680 per call), plus a cheap-model line per session turn, which an incremental
  tree (UniiChat's leaves merged in pairs) keeps to one short call per turn.
- Unlike round 2's richer *recent* context (first ask, last 2 paragraphs: noise), a line about the whole session is a
  measurable gain in ranking. The line here is written from the turns directly, an upper bound on a tree's root.

## The same line, the production way, with controls (2026-10-21, explore/lifetree.py)

Three things were wrong with the section above, all fixed here.
1. **Style split leak.** `bench.half()` hashed each style case's own id, so 54 of the 150 `styleA` cases (the fitting
   half) were written on boards of `realB` moments, and 106 of the 182 `styleB` ones on `realA` boards. `bench.load_set`
   now gives a style case the half of the real moment whose board it reuses (`style_half`): styleA 201, styleB 131
   cases. This changes every earlier table that fit or scored on `styleA`/`styleB` (the earlier tables were not re-run);
   real splits are untouched (realA 397, realB 213).
2. **The line wasn't the production artefact.** It was written from the raw transcript, with your own past phrasing.
   Now: a *leaf* is one Haiku line per finished turn, from that turn alone (your message, clipped to 500 chars, and the
   session's answer, its last 900); a *root* is one Haiku line rewritten from all the session's leaves for turns finished
   by the moment, oldest first (first 8 + last 80 when a session has over 88 turns). The unfinished current turn gives no
   leaf. Leaves are cached by session@turn (2,013), roots by session@turns-finished (1,166); 3,179 Haiku calls, 0 failed,
   real/data/tree_{leaves,roots}.json (gitignored).
3. **Missing controls.** `combo-recent` = only the latest finished turn's leaf in the same field; `combo-shuffled` = the
   roots permuted among the session options of the same board (a derangement, seed per case), so length and style
   match but the content belongs to another session.

All formats are `combo-o` plus one field (`what it has been about overall`, ≤ 300 chars) on each session option;
final3 weights refit per format on realA + styleA (fixed split). Real (n=610, paired, refit; Jev's top-1 involves no
fitting; "right/wrong/needless" on realA are in-sample for the weights, so realB is the clean column):

| real, all (n=610) | top-1 | right | wrong | wrong to a session | needless asks | input tokens |
|---|---|---|---|---|---|---|
| combo-o | 44.3 | 36.2 | 3.3 | 3.0 | 18.4 | 3,126 |
| combo-life (direct line) | 52.1 | 42.0 | 3.0 | 2.6 | 14.3 | 3,677 |
| combo-root (production) | 53.1 | 42.0 | 2.8 | 2.5 | 14.6 | 3,688 |
| combo-recent (latest leaf) | 50.8 | 40.7 | 3.0 | 2.8 | 15.7 | 3,589 |
| combo-shuffled (control) | 38.2 | 31.6 | 2.5 | 2.1 | 22.6 | 3,688 |

| realB (n=213, never fit on) | top-1 | right | wrong | wrong to a session | needless asks | input tokens |
|---|---|---|---|---|---|---|
| combo-o | 48.8 | 37.6 | 3.3 | 3.3 | 18.3 | 2,889 |
| combo-life | 52.6 | 39.0 | 3.3 | 3.3 | 17.8 | 3,380 |
| combo-root | 53.5 | 40.4 | 2.3 | 2.3 | 16.9 | 3,391 |
| combo-recent | 53.5 | 38.5 | 3.3 | 3.3 | 18.3 | 3,299 |
| combo-shuffled | 43.7 | 31.5 | 3.3 | 3.3 | 23.5 | 3,391 |

Paired vs combo-o (points, session-grouped bootstrap 95% CI; gained/lost = cases where the metric rose/fell; for
wrong, `+` means more wrong sends):

| format | real top-1 | real right | real wrong | real needless | realB top-1 | realB right |
|---|---|---|---|---|---|---|
| combo-life | +7.9 [+5.0, +10.5] 61/13 | +5.7 [+3.3, +8.3] | −0.3 [−1.0, +0.3] | −4.1 [−6.6, −1.8] | +3.8 [+0.4, +7.8] | +1.4 [−1.5, +4.5] |
| combo-root | +8.9 [+5.7, +11.6] 64/10 | +5.7 [+3.2, +8.3] | −0.5 [−1.3, +0.3] | −3.8 [−6.0, −1.8] | +4.7 [+1.0, +9.0] | +2.8 [−0.8, +6.9] |
| combo-recent | +6.6 [+3.5, +9.3] 56/16 | +4.4 [+1.8, +6.7] | −0.3 [−1.0, +0.3] | −2.6 [−4.1, −1.0] | +4.7 [+1.0, +8.8] | +0.9 [−2.5, +4.5] |
| combo-shuffled | −6.1 [−9.9, −2.7] 21/58 | −4.6 [−6.6, −2.3] | −0.8 [−2.0, +0.2] | +4.3 [+2.2, +6.1] | −5.2 [−10.6, +0.5] | −6.1 [−9.9, −2.4] |

Root against its neighbours (real top-1): vs direct line +1.0 [−1.5, +3.3]; vs recent +2.3 [−0.2, +4.8] (realB +0.0
[−3.2, +3.2]); vs shuffled +14.9 [+11.3, +18.4]. Router-style cases (styleB, n=131) are near the ceiling (top-1 91.6)
and show no effect for any format (root top-1 +0.0, right −2.3 [−5.6, +1.0]); styleA the same (root top-1 −1.5).
Shipped (unrefit) weights: same ranking by top-1, but wrong sends rise with every real line (root 3.1 → 3.9, +0.8
[0.0, +1.8]; recent +0.3), so any of them needs the RouteFusion refit. Full tables: `python3 -m explore.lifetree report`.

**Verdict.**
- root ≈ direct line: the production-way root keeps the whole gain (top-1 +8.9 vs +7.9, difference within noise). The
  earlier result was not an artefact of the line being written from raw phrasing.
- root vs recent: the latest turn's one-liner alone gets most of it (+6.6 of +8.9 top-1; +4.7 on realB, equal to root's).
  Root's extra over recent is +2.3 top-1 [−0.2, +4.8], not distinguishable from zero, and 0 on realB. So most of the
  gain is recency (what each session was just doing, in a model's words) rather than whole-life content; a whole-life
  root adds at most a couple of points beyond it.
- shuffled ≪ root, and below the baseline: the gain is not "more text". A line that belongs to another session actively
  misleads Jev (top-1 −6.1, needless asks +4.3), so Jev does read the content.
- Right sends gain (+5.7 on real) is mostly realA (in-sample weights); on realB it is +2.8 [−0.8, +6.9] for root, not
  significant. Wrong sends do not rise under a refit (3.3 → 2.8 real, 3.3 → 2.3 realB).

Cost: +18% input tokens for root (3,126 → 3,688 per call; recent +15%); at ship time one short leaf call per finished
turn plus one root rewrite per session whenever a turn finishes (here 2,013 leaves + 1,166 roots over 610 moments, Haiku
via `claude -p`, ~3 h wall at 8 workers on a loaded machine; each call is a few hundred input tokens, roots up to ~4k).

Caveats: one Haiku sample per line (no variance across rewrites); 20 of the 610 moments share a board with another
(style cases take the first match with the same gold); sessions with no finished turn at the moment (new ones) have no
line in any format; shuffled leaves a board with a single described session unchanged; real/data/tree_*.json hold
redacted (real/boards.redact) text derived lines only on this machine.

