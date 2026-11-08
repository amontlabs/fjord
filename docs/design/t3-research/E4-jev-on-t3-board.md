# E4: Jev in front of Sonnet, on T3's board (2026-11-08)

Aggregates only. Scripts and raw answers are in the scratchpad (`.../scratchpad/deciders-t3/jev/`: `port.py` is the port of
`jevRequest`, `score_jev.py` and `extra.py` score it, `jev_s0.jsonl` / `jev_s1.jsonl` hold Jev's picks, top-5
probabilities, latency and tokens per moment, and `out.txt` / `out_extra.txt` the full sweeps). The Sonnet answers compared
against are E3's `res_b1` / `res_b2` ([E3](E3-decider-t3-board.md)), with no new Sonnet calls.

## Setup
- The same 182 moments as E3 (120 dev, 62 realB), with strict gold, E3's candidates (`common.candidates`) and its purposes.
- **The request** is `RouterProjectDecider.jevRequest` ported line for line. The thread options are the board's candidates,
  most recent first, named by title (cut to 80; `(project)` added on a duplicate title; `.` becomes `_`; `'` added on a
  clash, with the intent names reserved first). Each thread's criterion is `{kind, project, now}`, where `now` is the
  thread's board lines (`DeciderBoard.lines`, the same text Sonnet reads). Then one `new in <project>` per project, with
  `about` (the purpose, cut to 140, or "no description") and `its threads` (its 6 most recent titles). Then the 4 intents
  (`change_fjord`, `question`, `compound`, `unclear`). The instructions are `RouterTools.routeQuestion` and the state is
  `{message}`. Every text goes through `redact()`.
- Options are sent in Fjord's order (`JEV_ORDERED=1`), 4 calls at a time, 2 samples (sample index 0 and 1).
- **The decision** is `jevDecision`. A thread is taken at the bar `t`, except a running thread, which needs 0.90 (the fixed
  `runningBar`). A new thread is taken at `t`. An intent is never taken.
- **Approximations:**
  - Swift's `JSONSerialization` writes the keys inside each criterion and the question body in no fixed order; here they
    are in insertion order. The order of the options is exact.
  - Project names in the criteria are redacted too, which changes nothing.
  - The moments have no `tagged`.
  - Latency is measured with `urllib`, which opens a new TLS connection on every call. The app's `URLSession` keeps its
    connections, so these times are an upper bound.
  - Sonnet's latencies are E3's concurrent b1/b2 times (p50 2.37 s), not its sequential 2.26 s.
- **Scoring:** E3's metrics. When Jev picks an intent, it has no place, so project and thread top-1 count as misses; a
  "best place" top-1 (Jev's highest-ranked thread or new thread) is given beside it.
- **Cost:** Jev bills input only, at $0.042 per million tokens (`evals/router/usage.py`, router-research.md). Sonnet's
  cost is E3's per-call usage at $3 / $15 per million.

## Jev alone
| | Proj top-1 | Thread top-1 | Best-place proj / thread | Sent at 0.70 | Wrong-thread | Wrong-project | New right |
|---|---|---|---|---|---|---|---|
| s0, 182 | 63% | 46% | 83% / 57% | 21% | 6 (3.3%) | 0 | 6 of 19 |
| s1, 182 | 60% | 46% | 83% / 59% | 23% | 6 (3.3%) | 0 | 6 of 19 |
| Sonnet b1, 182 (0.80/0.90) | 91% | 75% | | 51% | 3 (1.6%) | 0 | 7 of 19 |

- Jev picks an intent (usually `unclear` or `question`) on 54–58 of 182 moments.
- **Sweep, dev 120 (s0):**

  | Bar | Sent | Wrong-thread | Wrong-project |
  |---|---|---|---|
  | 0.50 | 39% | 7 | 1 |
  | 0.60 | 29% | 4 | 1 |
  | 0.70 | 22% | 3 | 0 |
  | 0.80 | 16% | 2 | 0 |
  | 0.90 | 9% | 2 | 0 |
  | 0.95 | 4% | 2 | 0 |

  realB follows the same curve (s0 at 0.70: 19% sent, 3 wrong). s1 is within one send of s0 at every bar.
- **No bar has zero wrong answers, and none passes E3's selection rule** (0 wrong-project, at most 1 wrong, 0 wrong to a
  running thread): even at 0.95, Jev's dev sends hold 2 wrong ones in both samples.
  - One is a running thread picked at 0.94–0.95 where the gold is new work, so the message would interrupt it.
  - The other is a new thread at 0.96 where the gold is an existing thread. Under R1's "an archived new thread is an ask"
    accounting, this one is soft.
- The app's `jevBar` 0.7, set on the old boards as "the lowest bar with no wrong Jev answer on the dev moments", does not hold on this board:
  at 0.70 Jev is wrong on 3 of 26 dev sends.

## Cascade: Jev at ≥ t, else Sonnet at 0.80 / 0.90
| Pooled 182 | Proj / thread top-1 | Sent | Wrong-thread | Wrong-project | New | Decided by Jev | p50 (seq / parallel) | $ per decision (seq / parallel) |
|---|---|---|---|---|---|---|---|---|
| Sonnet b1 alone | 91% / 75% | 51% | 3 (1.6%) | 0 | 7 | 0% | 2.37 s | $0.0114 |
| t 0.50, s0×b1 | 91% / 74% | 61% | 13 (7.1%) | 1 | 8 | 38% | 2.26 / 2.10 s | $0.0072 / 0.0115 |
| t 0.70, s0×b1 | 91% / 75% | 54% | 8 (4.4%) | 0 | 7 | 21% | 2.39 / 2.24 s | $0.0092 / 0.0115 |
| t 0.70, s1×b2 | 92% / 75% | 55% | 9 (4.9%) | 0 | 8 | 23% | 2.37 / 2.20 s | $0.0091 / 0.0115 |
| t 0.80, s0×b1 | 91% / 75% | 52% | 5 (2.7%) | 0 | 7 | 13% | 2.45 / 2.30 s | $0.0100 / 0.0115 |
| t 0.90, s0×b1 | 91% / 75% | 52% | 5 (2.7%) | 0 | 7 | 7% | 2.50 / 2.34 s | $0.0107 / 0.0115 |

- "seq" calls Jev, then Sonnet when Jev is below its bar. "parallel" calls both at once and acts on Jev when he clears his
  bar.
- Splits at t 0.70:
  - dev: 52–53% sent, 4 wrong (Sonnet alone: 49%, 1);
  - realB: 60% sent, 4–5 wrong (Sonnet alone: 55–56%, 2–3).
- **What Jev adds** (t 0.70, the four sample pairings agree):
  - Where Sonnet would also have sent, Jev picks the same place in 32–34 of 32–34 cases. These are pure latency wins, with
    no change to the outcome.
  - Where Sonnet would have asked, Jev sends 5–8 messages and **5 of them are wrong**.
  - At 0.90, Jev sends 2 messages Sonnet would ask, and both are wrong (the two dev cases above).
  - So Jev's confident sends add no right answers. They only turn some of Sonnet's asks into wrong sends. Top-1 doesn't
    move: Jev's wrong picks are moments where Sonnet's own best guess is wrong too.
- **Latency:**
  - Jev is fast: p50 0.157 s, p95 0.19 s, 3.2k input tokens (max 6.5k).
  - But he decides only 21–23% of messages at 0.70 (7% at 0.90), so the p50 stays on Sonnet's side, at 2.2–2.5 s.
  - At t 0.70, 21–23% of decisions finish under 0.5 s, and the mean drops from 2.65 s to 2.07–2.30 s. Calling Jev first
    adds about 0.16 s to every message that falls through to Sonnet.
  - Only the 0.50 bar and below put Jev past half of the messages, and there the wrong rate is 7%.
- **Cost:** Jev costs about $0.00014 a call. Calling him first saves about 20% of the Sonnet spend at t 0.70 ($0.0092
  against $0.0114) and adds about 1% when run in parallel.
- **Paired bootstrap, cascade t 0.70 (s0×b1) − Sonnet b1 alone, points (95% CI):**

  | Set | Project top-1 | Thread top-1 | Sent | Wrong-thread / msg | Wrong-project |
  |---|---|---|---|---|---|
  | Pooled 182 | +0.0 | +0.0 | +3.3 (+1.1, +6.0) | **+2.7 (+0.5, +5.5)** | 0 |
  | realB 62 | +0.0 | +0.0 | +4.8 (0, +11.3) | +3.2 (0, +8.1) | 0 |

  At t 0.90 (pooled): sent +1.1 (0, +2.7), wrong +1.1 (0, +2.7). The rise in wrong sends at 0.70 is outside the noise.

## Agreement variants (both called; Sonnet's pick)
- **Agreement:** Sonnet acts at its normal bars, or at a lower idle bar `ts` when Jev's top pick is the same place at
  ≥ `tj`. Running targets stay at 0.90.
  - Chosen on dev with E3's rule, the best setting is `ts` 0.75 (any `tj`), or `tj` 0.70 with `ts` 0.65. Both are exactly
    Sonnet alone: 49% dev, 51% pooled, 3 wrong.
  - Lower bars send more and are wrong more: `tj` 0, `ts` 0.65 sends 57% pooled with 6 wrong (3.3%), and 55% with 8 wrong
    on s1×b2.
  - Against Sonnet alone at the same 0.65 bar (61%, 7 wrong), agreement sends 3.8 points less (−6.6, −1.1) and is wrong
    0.5 points less (−1.6, 0). That is the same trade as raising Sonnet's bar, not a better frontier. **Agreement does not
    raise the send rate at ≤1% wrong.**
- **Veto** (Sonnet sends only when Jev's top pick agrees): at 0.80 it sends 37–40% with 2–3 wrong (1.1–1.6%). Sonnet
  alone at 0.85 does better: 36–37% with 1 wrong.
- Both variants need the Sonnet call, so they save no latency and add Jev's cost.

## Against R1's gates
| Gate | Jev alone, 0.70 | Cascade, t 0.70 | Cascade, t 0.90 | Sonnet b alone (E3) |
|---|---|---|---|---|
| wrong-thread ≤1% | fails, 3.3% | fails, 4.4–4.9% | fails, 2.7–3.3% | fails, 1.6–2.2% |
| 0 wrong-project | passes | passes | passes | passes |
| send ≥50% | fails, 21–23% | passes, 54–55% | passes, 52–53% | passes, 51–52% |
| new work ≥10 of 19 | fails, 6 | fails, 7–8 | fails, 7 | fails, 7 |
| p50 ≤2 s | passes, 0.16 s | fails, 2.2–2.4 s | fails, 2.3–2.5 s | fails, 2.26 s seq |
| R1 D: Jev-first only with 0 wrong | | **fails at every bar** (2 wrong at 0.95 on dev) | | |

## Recommendation
- **Not Jev-first, at any bar.** Jev's confident sends add nothing right. Where Sonnet would send, he agrees, and where
  Sonnet would ask, he is mostly wrong (5 of 6–8 at 0.70, 2 of 2 at 0.90). The cascade worsens the gate that already
  fails (wrong +2.7 points, CI excludes 0) and leaves the p50 at about 2.3 s. Its only gains are 20% off the Sonnet spend
  and a sub-0.5 s answer on a fifth of messages.
- **Not agreement or veto.** On this data, each moves along Sonnet's own frontier. To trade sends for wrong sends, use
  Sonnet's bar (0.85 gives 37% at 0.5%).
- **Fallback: keep it only as an ask ranker; don't send on it.** Without Sonnet, Jev at the app's 0.70 sends 21–23% with
  3.3% wrong. His top 3 places hold the gold on 81–83% of moments, though (dev 98–99 of 120, realB 49–51 of 62), so he is
  useful for ordering the "Where should this go?" options. If the fallback keeps sending, its bar should be at least 0.90,
  and even there it sent 2 wrong in 9% of dev.
- **A use not measured here:** an instant preview. Shown as the live pick while Sonnet thinks, Jev's ≥0.70 pick matched
  Sonnet's sent place 32 of 32 times. Gating the preview on Jev alone would show a wrong place on the 5 moments where
  Sonnet asks. Measure it on live logs before relying on it.
- The 2 s gate needs Sonnet's own output trimmed (E3: capping `reason`), not Jev.

## What is noise
- The two Jev samples agree on 170 of 182 picks, with a mean |Δ confidence| of 0.036 (max 0.17). Jev's wrong sends at
  ≥0.65 are the same 6 moments in both samples, so they are systematic, not sampling noise.
- Differences of 1–3 sends or cases between variants, and the 7 against 8 on new work, are noise. 182 moments, 19
  new-work cases, realB 62.
- Running targets are scored as in E3: the gold is never a running thread, so Jev's one running pick at ≥0.90 counts as
  wrong. Here the gold is new work, so it is wrong on the merits too.
- **Not tested:**
  - waiting requests;
  - `tagged`;
  - live traffic;
  - Jev's latency over a kept-alive connection (likely a little lower);
  - Fjord's own purposes (E3's purposes came from the same boards' titles).
