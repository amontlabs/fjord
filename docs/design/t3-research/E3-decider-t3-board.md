# E3: the decider on T3's board, through the API (2026-11-07)

Aggregates only. Raw answers, boards and scripts are in the scratchpad (`.../scratchpad/deciders-t3/`: `common.py` has `render_board`, `run.py`, `score.py`, `final.py`, `res_*.jsonl`). The board template is in [`decider-board-spec.md`](decider-board-spec.md).

## Setup
- Same 182 moments as E1 (120 dev, 62 realB), strict gold, `boards.redact()` on every field, Sonnet `claude-sonnet-5-5` called directly on the Messages API (JSON-schema output, prompt caching on the system block), 4 calls at a time.
- **a:** E1's board (`build_sonnet`), through the API. **b:** the T3-shape board (spec file). **c:** b plus the new-work rule, applied to b's answers (no extra calls). One sample each, then a second sample of b (b2) for noise.
- The 182 moments hold no T3 todo steps, branches or PRs; "current step" is the session's activity line, and project purposes are one Haiku sentence per project from its thread titles (they are not in the old boards, so b has information a lacks; this is part of the board effect).
- **Transport finding:** the model thinks by default. At the first attempt about 5% of calls were cut off at `max_tokens` (thinking counted), and the p50 was 4.3 s. `thinking: {"type": "between_tools"}` turns it off (it rejects `disabled`); all numbers below use it. The default-thinking runs (158 calls of a, 28 of b) are kept only for latency.

## Results, pooled 182 (bars 0.80 idle, 0.90 running)
| Variant | Proj top-1 | Thread top-1 | Sent | Wrong-thread sends | Wrong-project | New right (of 19) |
|---|---|---|---|---|---|---|
| a: E1 board via API | 90% | 73% | 49% | 4 (2.2%/msg) | 0 (1 at a flat 0.8) | 4 |
| b: T3 board, sample 1 | 91% | 75% | 51% | 3 (1.6%) | 0 | 7 |
| b: T3 board, sample 2 | 92% | 74% | 52% | 4 (2.2%) | 0 | 7 |
| c: b + new-work rule (p 0.84, idle 0.72) | 92% | 66% | 74% | 35 (19%), 29 of them a new thread in the right project where the gold was an existing one | 1 | 9 |

- E1's CLI Sonnet on the same moments: 92% / 76% / 47% / 3 / 1 / 6. **Transport has no effect on quality** (a against E1 is within the noise of its own rerun).
- Paired bootstrap, 95% CI in points, b1 − a: project +1.1 (−3.3, +4.9), thread +2.2 (−3.3, +7.7), sent +1.1 (−4.4, +6.6), wrong-thread −1.1 (−3.3, +1.1). **b is not distinguishable from a**, except that it gets new work 7 of 19 against 4 (a was 6 in E1: one-sample noise of that size, 2–3 cases). b1 and b2 agree on 176 of 182 picks; b and a on the same thread in 152.
- Splits at 0.80/0.90, b1 / b2: dev 120: 49% sent, 1 wrong, 4 of 12 new; realB 62: 55% / 56% sent, 2 / 3 wrong, 3 of 7 new.
- The new-work rule does what it was built for on send rate (51 to 74%) and ruins it elsewhere: when the model is sure of the project and unsure of the thread, the gold is a new thread in only 0 or 1 of about 24 cases (the rest are "which of two threads"). It adds 29 new threads that duplicate existing work, 1 wrong-project send, and only 2 more new-work cases. Under the "an archived new thread is an ask, not a wrong send" accounting the hard wrong sends are 6 of 182 (3.3%), still above the gate. If the rule is wanted, its trigger must not be the confidence pair.

## Bars
- Chosen on the 120 dev moments (most sends with 0 wrong-project and at most 1 wrong): **idle 0.74 for b1 (0.80 for b2), so 0.80**; the 0.74 vs 0.80 difference is one run's noise (b1 sends 3 at both).
- **Running targets: 0.90, not measurable.** In the 182 moments the gold thread is never running (it is idle by construction), so every pick of a running thread is wrong: 10 of b1's picks and 12 of a's, at confidence at most 0.8 (a) and 0.6 (b). A bar of 0.80 already catches all of them; 0.90 is a margin. Steer-vs-queue and wrong sends to running threads need Fjord's live logs.
- realB, once, at 0.80/0.90: b1 sent 55%, 2 wrong, 0 wrong-project; b2 56%, 3 wrong, 0 wrong-project.
- Frontier (pooled, idle bar, b1 / b2): 0.75 sends 52%, 3 / 4 wrong; 0.85 sends 37% / 36%, 1 / 1 wrong (0.5%); 0.90 sends 30% / 31%, 0 / 1 wrong. 1 of the 3–4 wrong sends is a same-title twin of the gold thread (two threads with the same title and last message), so the real rate is a little lower than counted.

## Latency and cost
- Thinking off, 30 calls one at a time on the same subset: **p50 2.26 s, p95 2.80 s** (the concurrent runs: 2.3–2.5 s p50, 3.7–5.1 s p95 with 4 in flight). With default thinking: p50 4.3–4.5 s.
- A "reason in at most 15 words" instruction cut the p50 to 2.03 s (output 162 to 103 tokens) but changed the pick on 9 of 30 moments (b1/b2 differ on 6 of 182), so not adopted unmeasured on the full set. The remaining time is mostly the output: dropping or capping `reason` and `alternatives` is the lever for the 2 s gate, to be measured on its own.
- Tokens per call for b: 2,970 input uncached + 720 cache-read, 149 output. a: 2,215 + 720, 150. The system block is cached (read on every call after the first); the board is the variable part and isn't cacheable.
- Cost at an assumed $3 / $15 per million tokens (cache read 0.1x): **$0.0114 per decision on b ($0.0091 on a)**, against $0.018 through `claude -p`. The whole task cost about $7.

## Against R1's gates (b, 0.80/0.90)
| Gate | Result |
|---|---|
| wrong-thread ≤1%/msg | **fails**: 1.6–2.2%. Holds at idle 0.85 (0.5%), where the send rate is 36–37% |
| 0 wrong-project sends | **passes** at 0.80/0.90 on both samples (a flat 0.8 let 1 through on a) |
| send rate ≥50% | passes (51–52%), but only together with the 1.6–2.2% wrong rate |
| new work ≥10 of 19 | **fails**: 7 (9 with the rule, at 29 duplicate threads) |
| p50 ≤2 s | **nearly**: 2.26 s sequential with thinking off; 2.03 s with a short reason |

## Recommendation
- Ship the T3 board (b) with Sonnet on the API, thinking off, bars 0.80 idle and 0.90 running. It is as good as E1's board, and it is the shape the app will have.
- Wrong-thread ≤1% and send ≥50% are not both reachable with this model and board: the frontier gives 37% at 1%, or 52% at 2%. Pick which gate to hold; the cheap lever is a bar of 0.85, with the Jev/ask path catching the rest.
- Do not use the confidence-pair new-work rule. New work needs a different lever (a prompt rule or a second look at `new_work` against the actions), and 19 cases can't rank levers: collect it from live logs.
- For the 2 s gate: cap `reason` (and measure picks on the full set), keep thinking off.

## What is noise
- Sample-to-sample: b1 and b2 differ by 1 wrong send, 1 point of sent, 0 on new work; differences of 1–3 sends or cases between variants mean nothing. 182 moments, 19 new-work cases, realB 62.
- Not tested: running targets (none in the gold), waiting requests, branch and PR, Codex threads, steer vs queue, real todo steps, Fjord's own purposes (they were generated from the same boards' titles).
