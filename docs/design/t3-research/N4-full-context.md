# N4: one call, complete context, no tools (2026-11-08)

Aggregates only. Code is in `evals/router/t3/` (`n4ctx.py` builds the context and runs it, `n4score.py` scores it, plus `n4recall.py`, `n4top1.py`, `n4paired.py`); the data stays in `evals/router/t3/data/` (gitignored). The design is [N4b](N4b-context-design.md); the evidence for the lean variant is [N4a](N4a-what-the-agent-looked-up.md); the benchmark, clean gold, CV bars and the `agent` baseline are [N3](N3-ceiling.md).

## Question
Can one Sonnet call, given context complete enough that it never needs a tool, match or beat N3's `agent` (Sonnet with `search_threads` and `read_thread`)? The context is built in code, ordered stable to volatile so the prompt cache hits, with a generous token budget.

**Answer: yes.** On the 300 dev moments, `ctx` routes as well as `agent` on new work and sends about 10 more points of follow-ups at the same error. It is also faster (3.4 s p50 against 5.4 s) but costs about twice as much per decision. On the sealed test it sends 40–46% of follow-ups with no wrong-thread send, against `agent`'s 29–40% with 2–4% wrong, and it starts as much new work (62–75% against 72–74%).

## 1. The spec as built (`n4ctx.py`)
One request: `claude-sonnet-5-5`, thinking `between_tools` (off), effort high, JSON schema output, `max_tokens` 1500. Blocks in cache order:

| # | Block | Built from | Marker | Size p50 / p90 (chars) |
|---|---|---|---|---|
| A | N2's `ROLE4` without the `need` line, a description of the sections, the §3 procedure, how to read a card, "times are absolute; recency and topic are facts, not a ranking" | fixed | system, 1 h | 3.7k |
| B | One line per project: name and purpose | `purposes.json` | (with C) | 1.5k |
| C | **Archive, a day snapshot.** Every listed thread (settled ones included) active in the 30 days before the working day's 04:00 Paris start, in creation order. Each is a header (id, project, title, created and last-active dates, settled, branch), the first ask (160 chars) and its Haiku card (deliverable 140, status, left 80): about 490 chars, or about 160 tokens at the measured 2.9 chars per token. | history before 04:00 | 1 h, on B+C | 71k / 123k (146 / 255 threads) |
| D | **Live threads**, in creation order. N4b's rules: every running thread, every thread finished within 24 h, the newest thread of each project, and any created in the last 30 min, capped at 16 (running threads are never cut). Each has: id, project and title; a state line with absolute times (running, or finished at; you last wrote here at; created at; revived after settling); git; the Haiku card; and a transcript digest with a time on every turn. Then each project's thread count and when its newest thread started. | board and history at t | none offline (5 min when shipped) | 38k / 45k (13 / 16 threads) |
| E | **Retrieval.** BM25 over the title and every turn before t of every thread in C or on the board. Gives the top 6 hits, each labelled live / archive / older with its project, title, last-active time and a snippet around its rarest matching word, then "words of the message no thread mentions". | history at t | none | 2.0k |
| F | **Now.** Today's date and time; your last message anywhere (its time only, not where it went); which live threads finished a reply since then; which are running. Then the message. | board at t | none | 0.3k |

- **Ids** are `t-` plus 4 hex of a hash of the T3 id. They are stable per thread, so a thread has the same name in C, D and E.
- **Digests.** D tiers its transcripts. Running threads and the 6 most recently active get N3's full `digest` (first ask 1200 chars, your turns 500, earlier replies 300, the latest reply's tail 1500, budget 5000, newest turns kept first). The rest get a short one (first ask 300, turns 200 / 150, last reply tail 400, budget 900). With every thread at full digest, D was 60k chars (about 20k tokens) at p50, not N4b's 8k tokens: the 24 h window and the newest-per-project rule give 13 live threads at p50, not 5–9. The gold follow-up thread is in D for 100% of follow-ups (weighted) and has a full digest for 97.6% (`n4recall.py`). The shipped candidates hold it for 96.6%.
- **Cards** are N3's Haiku summary (`n3dec.SUM_SYS`, `claude-haiku-5-5`, thinking off, effort low), keyed by thread and its last turn, and precomputed off the decision path (`n4ctx.py cards`). Dev needed 1,014 unique cards ($0.39) and test 642 ($0.24). That is off-path cost, not counted per decision. Live, a card costs about $0.0004 per run that completes.

**Deviations from N4b, and what can't be replayed:**
- **C is frozen for the working day.** N4b has C exclude the threads in D and append at its tail as threads leave D. A day snapshot keeps the 1 h prefix byte-identical all day, so a thread that is also live appears in both, and A says the live card wins. Measured: every one of the 300 time-ordered dev calls read the prefix from cache, and 22 of them (about one per day) wrote it.
- **B holds no counts.** Counts change with every new thread and would break the prefix in front of C, so the per-project facts moved to the end of D.
- **No 5 min marker on D offline.** The sampled moments are hours apart, so a D entry could only ever be written, never read. It ships with the marker; what it saves live is estimated below, not measured.
- **T3 `searchThreads` can't be replayed offline.** E is BM25 alone, standing in for both of N4b's sources.
- **Read state (`lastVisitedAt`) isn't in the history.** It is left out everywhere, along with every "unread / opened after its reply" line. N4b §2 stays unmeasured.
- **No waiting threads, PRs or todo steps exist in this history**, so those lines never appear.

**Schema and rule (N4b §3):** `message_deliverable`, `fits` (≤4 of {thread, how, state_ok}), `owned_by`, `referent_unique`, then `action`, `project`, `session`, `reason`, `alternatives`, `confidence`, `project_confidence`, `p_new`. The rule, in order:
1. `p_new ≥ bar_pnew` with a known project starts a new thread; so does `new_work` with `confidence ≥ bar_new`.
2. `follow_up` to a known thread, with `owned_by` naming it and `referent_unique` true, is sent at `bar_idle` (or `bar_running` when the thread runs).
3. Any other follow-up is asked.
4. `answer_here ≥ 0.80` answers here.
5. Everything else is asked.

Bars come from N3's grid and its day-grouped 6-fold CV (`n3bars.fit` / `cv`). The target is follow-up wrong-thread plus to-new ≤ the target, and new work pushed ≤ 2× the target.

**`lean`** is N4a's R1–R4 on N2's v4 board (the board `sthink` and `agent` saw):
- R1: a catalog line for every other thread active within 72 h.
- R2: the 5 most recently active threads in detail (first ask, the agent's last 6 turns one line each, your last 3 turns, the last reply's tail 1500).
- R3: BM25 top 3 with 2 snippets each.
- R4: the newest thread of each project with its card status.

It uses the same schema, rule and model, with A worded for its sections.

## 2. Dev: 300 moments, clean gold, CV bars
New-work and follow-up rates are weighted to the natural ratio, with day-bootstrap 95% CIs. "Terse" means follow-ups of 5 words or fewer (29 moments). "Off-board" means the gold thread wasn't among the shipped candidates (12 moments). Those two rows show the weighted share sent right / sent wrong.

| Decider | target | new right | new pushed | follow right | follow wrong thread | follow to new | terse right / wrong | off-board right / wrong |
|---|---|---|---|---|---|---|---|---|
| **ctx** | 1% | 59.1% (52–68) | 0.7% | **60.3% (49–70)** | 1.3% | 0.7% | 44% / 4.8% | 21% / 9.6% |
| **ctx** | 2% | 67.9% (59–77) | 3.7% | **70.3% (59–80)** | 0.7% | 0.7% | 60% / 0% | 42% / 9.6% |
| lean | 1% | 65.7% (55–73) | 1.5% | 51.6% (42–60) | 0.3% | 1.0% | 34% / 0% | 10% / 0% |
| lean | 2% | 65.7% (55–73) | 2.9% | 65.3% (55–75) | 1.3% | 1.0% | 50% / 0% | 21% / 9.6% |
| ctx_compact (D digests → N2 lines) | 1% | 57.7% | 2.2% | 55.3% | 0.3% | 0.7% | 29% / 0% | 31% / 0% |
| ctx_compact | 2% | 70.8% | 2.2% | 66.6% | 0.7% | 0.7% | 44% / 0% | 40% / 9.6% |
| ctx_noE (no retrieval) | 1% | 61.3% | 0.7% | 13.3% | 1.0% | 0.3% | 10% / 1.6% | 10% / 9.6% |
| ctx_noE | 2% | 69.3% | 4.4% | 70.0% | 1.0% | 1.0% | 58% / 3.2% | 42% / 9.6% |
| ctx_noC (no archive) | 1% | 53.3% | 2.2% | 62.0% | 0.3% | 0.3% | 48% / 0% | 40% / 9.6% |
| ctx_noC | 2% | 62.8% | 3.7% | 75.0% | 1.3% | 1.0% | 61% / 0% | 42% / 9.6% |
| N3 agent (tools) | 1% | 61.3% (50–70) | 2.2% | 49.1% (37–61) | 0.3% | 1.3% | 29% / 0% | 40% / 9.6% |
| N3 agent | 2% | 64.2% (54–73) | 2.9% | 60.8% (49–71) | 1.0% | 1.6% | 44% / 0% | 42% / 19.2% |
| N3 othink (Opus, thinking) | 1% | 62.8% (49–74) | 1.5% | 27.0% (20–35) | 0.3% | 1.3% | 15% / 0% | 0% / 19.2% |
| N3 othink | 2% | 66.4% (52–78) | 3.7% | 68.7% (61–75) | 1.3% | 1.7% | 66% / 0% | 0% / 9.6% |
| ctx_think (adaptive, effort medium; 136 moments, every other day) | 1% / 2% | 60.3% / 63.5% | 6.3% | 56.6% / 64.1% | 0.7% | 0.7% | 58% / 0% | — |
| ctx on the same 136 | 1% / 2% | 50.8% / 60.3% | 3.2% / 7.9% | 61.1% / 78.2% | 0.7% | 0.7–0.9% | 39–58% / 0% | — |

**The thinking run didn't think.** Adaptive thinking under the JSON schema at effort medium produced 0 thinking tokens on all 136 calls (output 288 tokens at p50, the same as `ctx`). So `ctx_think` measures effort medium, not thinking. Paired against `ctx` on the same moments it is +9.5 on new work at 1% (CI +0…+20) and −14 on follow-ups at 2% (−24…−6): noise around no gain. A real thinking run needs effort high or xhigh, or no schema (N2 saw the same thing at high). It wasn't rerun: no budget left.

**Paired differences** (same moments, each decider under its own CV bars, day bootstrap; `n4paired.py`):

| Comparison | target | new right | follow right | mean of the two |
|---|---|---|---|---|
| ctx − agent | 1% | −2.2 (−12…+8) | **+11.2 (+2…+20)** | +4.5 (−2…+11) |
| ctx − agent | 2% | +3.7 (−4…+12) | **+9.5 (+2…+16)** | **+6.6 (+2…+10)** |
| ctx − othink | 1% | −3.7 (−16…+9) | **+33.2 (+21…+43)** | +14.8 (+6…+24) |
| lean − agent | 2% | +1.5 (−10…+10) | +4.4 (−2…+10) | +3.0 (−4…+8) |
| lean − ctx | 1% | +6.6 (−7…+17) | **−8.7 (−16…−2)** | −1.0 (−9…+6) |
| compact − ctx | 1% / 2% | −1.4 / +2.9 | −5.0 / −3.7 | −3.2 / −0.4 |
| noE − ctx | 1% / 2% | +2.2 / +1.5 | **−47.0** / −0.3 | −22.4 / +0.6 |
| noC − ctx | 1% / 2% | −5.8 / **−5.1 (−8…−2)** | +1.7 / +4.7 | −2.0 / −0.2 |
| ctx_think − ctx (136 moments) | 1% / 2% | +9.5 / +3.2 | −4.4 / **−14.1 (−24…−6)** | +2.5 / −5.5 |

**Bar-free top-1** (each decider's best place whatever its confidence; `n4top1.py`):

| | new right | follow right | new pushed | follow wrong thread |
|---|---|---|---|---|
| ctx | 68.6% | 89.6% | 16.8% | 8.7% |
| lean | 67.2% | 89.9% | 15.3% | 7.8% |
| ctx_compact | 71.5% | 88.0% | 16.1% | 7.1% |
| ctx_noE | 70.1% | 87.7% | 15.3% | 10.3% |
| ctx_noC | 63.5% | 91.0% | 20.4% | 8.0% |
| agent | 67.9% | 90.1% | 18.3% | 6.3% |
| othink | 70.8% | 87.9% | 17.5% | 7.8% |
| sthink | 66.4% | 77.8% | 13.9% | 9.1% |

**What the tables say:**
- **The top-1 answers are the same.** Every reading decider lands at about 68% new / 90% follow-ups top-1; `sthink`, which reads nothing, is 12 points lower on follow-ups. So complete context reproduces what the tools found and adds little beyond it. The gain is in **calibration**: `ctx` gives higher confidence to its right follow-ups than `agent` does, so the same bars send more of them. That is the +10 points on follow-ups, and it holds at both targets.
- **The archive (C) earns its tokens on new work.** Without it, new work drops about 5 points at 2% (CI −8…−2), and new work pushed into an old thread rises from 16.8% to 20.4% top-1. That is the "this deliverable was already done" evidence N4a found missing. Follow-ups don't need it (+2 to +5, n.s.).
- **Retrieval (E) matters only at the strictest target.** Without it, a few confident wrong sends push the 1% bar to 0.95 or more, and follow-ups sent collapse to 13%. At 2% it makes no difference. It is cheap (2k chars), so keep it.
- **Full digests (D) vs N2's compact lines** is within noise: −5 / −4 on follow-ups, ±3 on new work. Most of what reading buys sits in the cards and in having the right threads listed, not in the long transcript. This is the cheapest lever if cost matters (below).
- **The `referent_unique` / `owned_by` guard (rule 3) never changes a decision.** All 24 guarded `ctx` follow-ups (27 for `lean`) had confidence ≤ 0.80, under every fitted idle bar (0.85–0.95). The model already lowers its confidence when two threads fit. Keep the `fits` shortlist for asks; drop rule 3 as a separate check.
- **Terse follow-ups** go from 29% / 44% sent (agent, at 1% / 2%) to 44% / 60% (ctx). At 1%, ctx sends some of them wrong (4.8%); at 2%, none. **Off-board follow-ups** (12 moments) are too few to separate the deciders.
- **`lean`** (5.3k-token design) ties on new work and is 5–9 points behind `ctx` on follow-ups, at half the cost.

## 3. Latency, tokens, cost (dev, time-ordered within each day)
| Decider | p50 / p95 | tokens per call: uncached / cache read / cache write / out (mean) | $/decision as run | warm, list price (est.) |
|---|---|---|---|---|
| ctx | 3.4 s / 4.4 s | 14.6k / 25.5k / 2.3k / 303 | $0.047 | $0.038 |
| ctx_compact | batch | 7.4k / 27.8k / 0 / 301 | (batch) | $0.024 |
| ctx_noC | batch | 14.6k / 2.4k / 0 / 296 | (batch) | $0.033 |
| lean | 3.1 s / 3.8 s | 9.1k / 1.8k / 0 / 298 | $0.022 | $0.022 |
| agent (N3) | 5.4 s / 10.5 s | (2–3 calls) | $0.022 | — |
| sthink (N3) | 2.8 s / 5.7 s | | $0.009 | — |
| ctx_think | batch | 14.0k / 27.3k / 2.5k / 286 | (batch) | $0.037 |

- Prompts were 45.6k tokens at p50 and 62k at p90. A+B+C, about 25k tokens, is read from cache at $0.20/MTok. Each day's first call writes it at the 1 h rate ($4/MTok, about $0.10 once a day).
- What a decision costs is the uncached D+E+F: about 14.6k tokens at $2/MTok, or $0.029. With D's 5 min marker in the shipped app, a message sent within 5 min of the previous one, with no thread event in between, reads D at a tenth of the price: about **$0.013** for such a call. This isn't measurable offline.
- The ablations, the thinking run and test ran through the Batch API (half price, no latency). Their "as run" spend is half of list.

## 4. Sealed test (112 judged moments, bars fitted on all dev)
n = 112 (53 new, 52 follow-ups). Each moment is about 1.9 points of a class rate. Terse follow-ups are 11 moments; off-board ones are 5.

| Finalist, bars from dev | new right | new pushed | follow right | follow wrong thread | follow to new | terse right / wrong |
|---|---|---|---|---|---|---|
| **ctx at 1%** (0.90 / 0.90 / 0.70 / 0.70) | 62.3% (47–78) | 1.9% | **40.4% (27–53)** | **0.0%** | **0.0%** | 55% / 0% |
| **ctx at 2%** (0.85 / 0.90 / 0.40 / 0.50) | **75.5% (66–85)** | 1.9% | **46.2% (35–58)** | 0.0% | 5.8% | 55% / 0% |
| lean at 1% (0.90 / 0.90 / 0.40 / 0.50) | 79.2% (67–90) | 1.9% | 38.5% (29–47) | 1.9% | 5.8% | 55% / 0% |
| lean at 2% (0.85 / 0.80 / 0.40 / 0.50) | 79.2% (67–90) | 1.9% | 44.2% (33–55) | 1.9% | 5.8% | 55% / 0% |
| agent at 1% (N3) | 71.7% (57–85) | 1.9% | 28.8% (17–38) | 1.9% | 1.9% | 36% / 0% |
| agent at 2% (N3) | 73.6% (60–87) | 1.9% | 40.4% (28–52) | 3.8% | 1.9% | 55% / 0% |
| othink at 2% (N3) | 73.6% (60–86) | 1.9% | 48.1% (38–58) | 3.8% | 3.8% | 55% / 0% |

- **Follow-ups hold on test:** `ctx` sends more follow-ups than `agent` (40% vs 29% at 1%, 46% vs 40% at 2%) with no wrong-thread send at all, where `agent` had 1.9–3.8%.
- **New work is a wash.** At 1% `ctx`'s new bar (0.70) is stricter than `agent`'s, so it starts 62% (3 of 53 fewer). At 2% it starts 75.5%, the best of the three. `lean` starts the most new work (79%), but it puts 1.9% of follow-ups in the wrong thread and starts 5.8% of them as new threads.
- **The 2% `ctx` bars cost 5.8% of follow-ups started as new threads** (3 of 52) on test; a new thread is revertible (archive). At 1% that is 0%, with 13 points less new work.
- **Overall, test agrees with dev:** one call with complete context **matches the agent on new work and beats it on follow-ups**, with fewer wrong sends.

## 5. The design to ship
- **Blocks, request and caps.** A system (1 h) · B+C as one user block (1 h) · D (5 min) · E+F+message, uncached. Caps:
  - C: 30 days of activity, frozen at 04:00 Paris, creation order, about 160 tokens per thread (about 24k tokens at p50).
  - D: N4b rules 1–5, at most 16 threads, creation order. Full digests (5000 chars) for running threads and the 6 most recently active; 900-char digests for the rest.
  - E: BM25 top 6, plus words that match nothing. Add T3 `searchThreads` when it lands before send.
  - F: time-ordered facts since your last message. Never where it went.
- **Precomputation, all off the decision path.**
  - The Haiku card at each `latestRunCompletedAt`.
  - Digests on `latestVisibleMessage.updatedAt`.
  - C rebuilt once a day.
  - BM25 index updates on every digest.
  - Decision time is string concatenation plus one call.
- **Schema.** N4b §3 as built. Keep `fits` as the ask's alternatives. Rule 3 can go: confidence already carries it.
- **Bars** (fitted on all 300 dev moments, idle / running / new / p_new):
  - At 1%: 0.90 / 0.90 / 0.70 / 0.70. On dev that sends 59% of follow-ups (0.3% wrong thread, 0.3% to new) and starts 56% of new work (0.7% pushed).
  - At 2%: 0.85 / 0.90 / 0.40 / 0.50. On dev, 69% of follow-ups and 68% of new work.
  - Ship **the 2% bars** if a follow-up started as a new thread is acceptable (it is revertible). Otherwise ship the 1% bars and accept about 10 points less new work.
- **If cost matters more than the last few points,** use `ctx_compact`: the same blocks with N2's compact lines in D. It costs about $0.024 per decision warm, roughly 0.6× `ctx`, and lands within noise of `ctx` on dev (top-1 new 71.5%, follow-ups 88%).
- **Unmeasured, to log live.** Read state (`lastVisitedAt`, "finished since you last read it") is not in this benchmark. It is the next lever for terse follow-ups (N4b §2, N3 §3) and has to be scored from the decision log.

## Spend
About **$44** of the $45 budget. Each run is billed as run; batch runs at half price.

| Run | Cost |
|---|---|
| ctx dev (live) | $13.94 |
| lean dev (live) | $6.49 |
| compact dev (batch) | $3.51 |
| noE dev (batch) | $6.73 |
| noC dev (batch) | $4.90 |
| ctx_think on 136 moments (batch) | $3.14 |
| ctx test (batch) | $3.32 |
| lean test (batch) | $1.17 |
| Haiku cards, off-path | $0.63 |
| smoke calls | about $0.30 |

N3's `agent` and `othink` were rescored from their saved answers at no cost; `n4score.py` reproduces N3's numbers for them exactly.
