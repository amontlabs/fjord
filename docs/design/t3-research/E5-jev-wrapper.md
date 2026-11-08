# E5: code around Jev, on T3's board (2026-11-08)

Aggregates only. Scripts, raw answers and full sweeps are in the scratchpad (`.../scratchpad/deciders-t3/e5/`):
- `build.py`: the board, Jev's requests and the BM25.
- `e5run.py` and `combo_run.py`: the calls.
- `score_a.py`, `score_b.py`, `rules_b.py`, `fusion.py`, `c_eval.py`, `c_final.py`, `d_eval.py`, `e_eval.py`, `extra_e5.py`: the scoring.
- `raw/*.jsonl`: the answers.
- `out/*.txt`: every table below, in full.

## Setup
- **Data:** the same 182 moments as [E3](E3-decider-t3-board.md) and [E4](E4-jev-on-t3-board.md): 120 dev and 62 realB. The candidates are E3's (`common.candidates`).
- **Gold:** lenient. The duplicate copy from J2's `dup_gold.json` (26 moments) counts as right. Strict counts are given beside it.
- **Model:** `jev-1.14.0`, pinned. Every response reported `jev-1.14.0`.
- **Calls:** 4 at a time, through `evals/router/jev.py`, so the answers are disk-cached. Everything sent goes through `redact()`.
- **Volume:** about 2.3k Jev calls in all, at about $0.60.

### The board, with the J2/J3 fixes
- **No intents among the places.** Jev chooses among the candidate threads plus one `new in <project>` per project. That project option keeps E4's `about` and `its threads` fields.
- **Each thread's `now`** carries:
  - title, status and age;
  - "thread started with" (200 characters);
  - "your earlier messages" (the last 3, 100 characters each);
  - "latest reply began" (300 characters, shown when the reply runs past 600);
  - "last message" (the last 600 characters);
  - "you last said there (N ago)", marked when your latest message went to this thread;
  - current step, for a running thread;
  - waiting request.
- **The latest assistant reply is always shown.** For the 104 of 1,730 candidates that had no reply on E3's board, it was filled from the transcript before the moment.
- **Ages are real activity time:** the transcript times before the moment.
- **No branch.** The moments carry none, so it is not on the board.
- **Route question:** reworded for threads, with the `earlier messages` line dropped.

### The yes/no checks
Each check is one question per idle candidate. All of a moment's checks go in one call.
- **`nx_old`:** the October next-message noul, verbatim. Its conversation is what you last said (300 characters) and the session's last message (400).
- **`nx_task`:** a noul: "is `message` your next message in this thread, continuing the same work?" It is asked over the thread's title, status and first ask, plus a conversation of what you last said (300), the head of the reply (200) and the tail of the reply (600).
- **`ans`:** a noul on the same block: does `message` reply to the thread's last message (answer it, accept it, reject it, correct it, or react to its result)?
- **`nx_choice`:** `nx_task` asked as a yes/no `choice`, so it returns probabilities for both answers.

### Samples, drafts and the shipping call
- **Samples:** route and checks were each asked twice (samples 0 and 1).
- **Drafts:** route and checks were also asked on a draft: the message cut at 60% of its characters, on a word boundary, at least 12 characters long. 165 of the 182 moments have one.
- **The shipping shape:** route, `ans` and `nx_choice` on the 3 latest idle threads, in a single request, asked one call at a time for latency. This is in effect a third sample.

### Sonnet
Sonnet's answers are E3's `res_b1` and `res_b2`, with bars of 0.80 for an idle thread and 0.90 for a running one. No new Sonnet calls were made.

## A. Jev ranker alone, new format

| Lenient, pooled 182 | Top-1 | Top-3 | Sent | Wrong-thread (strict) | Wrong-project | New sent right |
|---|---|---|---|---|---|---|
| E4 base, 0.70 | 48% | 81–83% | 21% | 6 (6) | 0 | 6 |
| **A, 0.70** | **63%** | **85%** | 37–39% | 9–10, 4.9–5.5%/msg (11–12) | 0 | 8 |
| A, 0.80 | | | 26% | 7–8 (3.8–4.4%) | 0 | 5–7 |
| A, 0.90 | | | 14–15% | 5 (2.7%) | 0 | 3 |
| A, 0.95 | | | 8–10% | 2 (1.1%) | 0 | 2–3 |

- The fixed board lifts Jev's top-1 by 15 points over E4 (48% → 63%). That is above J2's best probe, LNH at 57%. New-work top-1 is 9 of 19.
- His confidence is still not a send signal. At p ≥ 0.95 he is right on 16 of 18, and at 0.90–0.95 on 7 of 10.
- **No bar gets to ≤1% wrong at a useful send rate.** A on its own fails the goal.
- The two samples agree on 167 of 182 picks, with a mean |Δp| of 0.03.
- Latency: p50 0.165 s, at 4.4k input tokens.

## B. Yes/no checks

The rule: a check fires when one of the 3 most recent idle threads gets p ≥ a, and leads the next of those 3 by at least `lead`. Each cell is fires / wrong, pooled 182, sample 0.

| Check | a / lead | Fires | Wrong | Gold is the check's argmax (of 163) |
|---|---|---|---|---|
| `nx_old` (October wording) | 0.5 / 0.3 | 17 | 0 | 90 |
| `nx_task` | 0.8 / 0.4 | 21 | 0 | 115 |
| `ans` | 0.7 / 0.3 | 24 | 0 | 116 |
| `nx_choice` | 0.9 / 0.5 | 23 | 0 | **121** |

- **The checks are precise but narrow.** Fired over Jev's top 3 instead of the 3 latest, they make 1–10 wrong sends. Recency is what keeps them clean.
- The October combo rule (`nx_old` at ≥0.5 with a 0.3 lead, sent when the route agrees or is under 0.4) fires 16 times with 0 wrong. That is 9%: the same precision as October's "right 91 of 95", at lower coverage.
- **Rule B** (`nx_task`, `ans` and `nx_choice` vote; send when exactly one thread is named and Jev's route agrees):
  - 18% sent with 0 wrong, in both samples;
  - 18% on dev and 19–21% on realB.
  - Without the route agreeing, it sends 20%, with 0 or 1 wrong.
  - Adding Jev's raw pick at ≥0.95 raises it to 24%, but with 2–3 wrong.
- The check bars were first read off a pooled sweep. The same bars give 0 wrong on dev alone in both samples (`out/extra_e5.txt`), so the leak is mild. B is still indicative, and C is the clean test.
- The checks never fire for new work.
- Latency: each check call has a p50 of about 0.155 s, at 1.6–3.2k tokens.

## C. Fusion: a fitted model over Jev, the checks, recency and BM25

- **The model:** a conditional logit over each moment's places (threads plus `new in`), with L2 1.0.
- **Validation:** leave-one-session-day-out cross-validation on dev (14 day groups), for every choice. Then one fit on all of dev, applied once to realB.
- **The chosen setting, fixed before realB was scored:** F4-norun, bar 0.90, running guard 0.25.
  - Features:
    - `lp`: Jev's log p, floored at 0.001;
    - `fin0` and `fin1`: the most recent and second most recent idle thread;
    - `new`;
    - `nc` and `nc_lead`: `nx_choice`'s p, and its lead over the others among the 3 latest;
    - `an`: `ans`'s p among the 3 latest;
    - `lx_said`: BM25 of the message against the thread's last reply, normalised to the best candidate.
  - Weights fit on dev, sample 0: `lp` 0.62, `fin0` 1.09, `fin1` 0.51, `new` 0.32, `nc` 1.74, `an` 1.30, `nc_lead` 0.44, `lx_said` 1.03. Sample 1 is within 0.03 of each.
  - **Send** when the fused P of the top place is at least 0.90 and that place is an idle thread. Running threads are never sent to here. Jev's route mass on running threads must also be under 0.25. Anything else is not decided here.
- **Why no `run` feature:** the gold is never a running thread in the 182 (E3), so a fitted running weight would only learn that artifact.

| Lenient (strict) | Top-1 | Sent | Wrong-thread | Wrong-project | New sent |
|---|---|---|---|---|---|
| Recency only (no Jev), dev OOF / realB | 58% / 56% | 3% / 6% | 0 | 0 | 0 |
| Jev + recency, no checks (F1), realB, s0 / s1 | 69% / 73% | 31% / 27% | 1 / 1 | 0 | 0 |
| **Chosen, dev OOF, s0 / s1** | **82%** | **33% / 32%** | **0 / 0** | 0 | 0 |
| **Chosen, realB held out, s0 / s1** | **73% (strict 68%)** | **44% / 42%** | **1 / 1 (1.6%/msg)** | 0 | 0 |
| **Chosen, pooled 182, s0 / s1** | 79% | **37% / 36%** | **1 (0.55%/msg; 1 of 65–67 sends)** | 0 | 0 |
| Chosen, the shipping single call | 79% | 36% | 1 | 0 | 0 |
| Pooled leave-one-day-out on all 182 (sensitivity; realB in training) | 79–80% | 34% | 1 | 0 | 0 |
| Same, without the running guard | 79% | 39–41% | 1 | 0 | 0 |
| Same, bar 0.95 | | 30% | 1 | 0 | 0 |

- **The one wrong send is the same moment in every variant, sample and bar from 0.85 to 0.97.**
  - It is J2's "retyped twin" with questionable gold: the owner retyped a refined request into a fork of the thread that had just answered it.
  - Sonnet b1 and b2 send it to the same wrong place.
  - On a gold that isn't questionable, the path made 0 wrong sends out of 182.
- **Calibration of the fused P** (dev OOF plus realB, sample 0): at 0.95 and above, 57 of 58 right; at 0.90–0.95, 16 of 16; at 0.80–0.90, 9 of 12; at 0.70–0.80, 19 of 21. Jev's raw p at 0.90 and above was 23 of 28.
- **What carries it:**
  - Jev with recency alone already reaches 26–27% sent with 1 wrong.
  - The checks add about 10 points of sends at the same wrong count.
  - BM25 and the twin flag add nothing measurable (F3 is the same as F4).
  - Of the 67 sends, 57 go to the most recent idle thread, 7 to the second and 3 to the third. 4 are messages of 3 words or fewer. None is a new thread.
- **Fusion top-1 (79%) equals Sonnet's** (78–79% lenient). That rests on a fitted recency prior: the gold is the most recent idle thread in 105 of 163 existing-thread moments. See "What the 182 can't measure".

## D. Jev fast path, then Sonnet

The path from C sends when it is sure. Otherwise Sonnet b decides, at 0.80 idle and 0.90 running. "seq" calls Jev, then Sonnet; "par" calls both at once.

| Pooled 182 (realB) | Sent | Wrong-thread, lenient (strict) | Wrong-project | New right: top-1 / sent | Decided by Jev | p50 seq / par | Mean seq / par | $ per decision, seq / par |
|---|---|---|---|---|---|---|---|---|
| Sonnet b1 alone | 51% (55%) | 2, 1.1% (3) | 0 | 7 / 3 | 0% | 2.37 s | 2.65 s | 0.0114 |
| **D, s0×b1, 0.90, guard** | **55% (61%)** | **2, 1.1% (3)** | 0 | 7 / 3 | **37% (44%)** | 2.27 / 2.10 s | **1.88 / 1.76 s** | **0.0077** / 0.0116 |
| D, s1×b2, 0.90, guard | 55% (65%) | 2 (4) | 0 | 7 / 4 | 36% (42%) | 2.27 / 2.10 s | 1.77 / 1.66 s | 0.0079 / 0.0116 |
| D, 0.90, no guard | 56–57% | 2 | 0 | 7 / 3–4 | 39–41% | 2.22 / 2.05 s | 1.66–1.83 s | 0.0073–0.0075 |
| D, 0.95, guard | 53–54% | 2 | 0 | 7 / 3–4 | 30% | 2.35 / 2.17 s | 1.92–2.07 s | 0.0085 |

- **What the Jev path adds** (all four sample pairings agree):
  - Where Sonnet sends, Jev picks the same place in 58–64 of 58–64 cases.
  - Where Sonnet would ask, Jev sends 7–10 messages, and **all of them are right**.
  - He never sends where Sonnet would send elsewhere.
  - So the cascade adds sends and no wrong ones: its only wrong sends are Sonnet's own two, one of them the twin above.
  - This reverses E4, where Jev's 5 sends past Sonnet's asks were 5 wrong.
- **Paired bootstrap, D − Sonnet alone:** sent +4.4 points pooled (+1.6, +7.7) and +6.5 on realB (+1.6, +12.9). Wrong +0.0 (0, 0). Sample pairing s1×b2: +3.8 and +8.1.
- **Latency:** the single Jev call has a p50 of 0.176 s, a p95 of 0.218 s and a mean of 0.179 s, at 6.5k tokens (max 11.6k), over a new TLS connection each time.
  - 37% of decisions finish in about 0.18 s, and the mean falls from 2.65 s to about 1.8 s.
  - The p50 stays on Sonnet's side at 2.1–2.3 s, because Jev decides under half of the messages.
- **Cost:** the Jev call is $0.00027. Sequential D costs 32% less than Sonnet alone. Parallel D costs 2% more.

### Against R1's gates

| Gate | A, Jev raw 0.90 | B, the checks' rule | C, the Jev path alone | D, Jev path then Sonnet | Sonnet b alone |
|---|---|---|---|---|---|
| Wrong-thread ≤1%/msg | fails, 2.7% | passes, 0% | **passes, 0.55%** (0% excluding questionable gold) | fails, 1.1% (Sonnet's own) | fails, 1.1% lenient |
| 0 wrong-project | passes | passes | passes | passes | passes |
| Send ≥50% | fails, 15% | fails, 18% | fails, 36–37% | **passes, 55%** | passes, 51% |
| New work ≥10 of 19 | fails, 3 | fails, 0 | fails, 0 (never sends new) | fails, 7 top-1 / 3–4 sent | fails |
| p50 ≤2 s | passes, 0.18 s | passes | passes, 0.18 s | fails, 2.1–2.3 s (mean 1.7–1.9 s) | fails |
| R1 D: Jev-first only with 0 wrong | | | **passes against Sonnet**: adds 0 wrong; its 1 wrong is shared with Sonnet | | |

## E. The as-you-type preview

- **The preview:** the C path's fused pick, shown when P ≥ `tp` and the pick isn't running.
- **The two stages:**
  - **Full text:** the preview just before Return.
  - **60% draft:** 165 moments. Weights come from the full-message fit (the fold without that day for dev), with BM25 run on the draft.
- **Compared** against the gold, and against where D finally routed: the Jev path's send, or Sonnet's.

| | tp | Shown | Wrong vs gold | Final send elsewhere | Final asked |
|---|---|---|---|---|---|
| Full text | 0.70 | 59% | 6 (5.6% of shown) | 1 | 22 |
| Full text | **0.90** | **41%** | **1 (1.4%)** | **0** | 2 |
| 60% draft | 0.70 | 44% | 5 (6.8%) | 1 | 8–9 |
| 60% draft | **0.90** | **31%** | **1 (2.0%)** | **0** | 1–2 |
| 60% draft | 0.95 | 24% | 1 | 0 | 1 |
| 60% draft, Jev's raw pick | 0.90 | 11% | 3 (17%) | | |

- At 0.90 the preview shows on about a third of drafts. When it shows, it is the place the message ends up in every case the system sends. Its one miss against the gold is the twin.
- The draft's fused top-1 equals the full message's on 144 of 165.
- **Below 0.90 the preview misleads** (5–7% wrong when shown). Jev's raw pick misleads at any bar, so never show it.
- The 60% cut is a stand-in. Real drafts pause at word boundaries the cut doesn't reproduce, and the live chip re-asked Jev 600 ms after each pause.

## What is noise, and what the 182 can't show
- **Sample noise is small.** The two samples, and the single-call run, move sent by 1–2 points and wrong by 0.
- **The data can't certify ≤0.5%.** One wrong in 182 has an exact 95% upper bound of 3.0% per message. Showing ≤0.5% at 95% confidence needs about 600 logged messages with no wrong sends (rule of three).
  - realB alone: 1 of 62, with an upper bound of 8.7% per message.
  - CIs on sent: realB 42–44% (29–56%); pooled 36–37% (29–44%).
- **The recency prior is fitted on messages typed inside a session**, usually the one that had just finished.
  - In Fjord, all messages go through one box, so the owner may address non-latest threads more often. The fusion would then lean on the latest thread wrongly.
  - The fit must be redone on Fjord's own logs before its 0.90 bar is trusted.
- **Not measurable here:**
  - focus: what is on screen, `lastVisitedAt`, the last routed thread;
  - running and steer targets: the gold is never running, so the path abstains on them by rule;
  - waiting requests, Codex threads, branches and PRs;
  - Fjord-intent messages: there is no such gold, and the board has no intents. Live, a "for Fjord itself" noul should send them to Sonnet.
  - real drafts;
  - latency over kept-alive connections (likely lower).
- **New work:** the path never sends it. It stays with Sonnet, which still fails the 10-of-19 gate.
- **Live logging must capture**, per decision:
  - the request hash and Jev's full answer (route probabilities, `ans` and `nx_choice` per thread), the fused P, the BM25 scores, the features, and the model version;
  - Sonnet's answer, when it was called;
  - which path decided, and the latencies;
  - the preview shown during the draft, and whether you changed the target;
  - the outcome: kept, moved or `sent_elsewhere`, reverted, archived new thread, or a correction;
  - focus signals at send time: `lastVisitedAt`, the thread open in Fjord, the last routed thread;
  - twin flags.

## Verdict
**Yes on this data: a Jev-led path reaches about 0.5% wrong at well over 25% of messages. The 182 can't certify the 0.5%.**

On the 182 it sends 36–37% of messages with 1 wrong (0.55% per message). That send is on a questionable-gold fork, and Sonnet sends it to the same wrong place. Held-out realB sends 42–44% with that same single wrong send. In front of Sonnet, the path adds 4–8 points of right sends and 0 wrong ones, and cuts the mean latency to about 1.8 s and the sequential cost by 32%.

Jev's raw confidence never got there, at any bar. The gain comes from fusing his route with two yes/no checks on the 3 latest idle threads, recency, and BM25.

**The design to ship** (the shape of D):
1. **One Jev call**, `jev-1.14.0` pinned, with state `{message}`:
   - `route`: a choice over the candidate threads plus `new in <p>`, with no intents and the A board above;
   - `ans_k` (noul) and `nc_k` (yes/no `choice`) for the 3 most recent idle threads, over {title, status, first ask, [your last words 300, reply head 200, reply tail 600]};
   - add a "for Fjord itself?" noul. When it is ≥0.3, hand the message to Sonnet. This is untested here.
2. **Fuse in code:** P ∝ exp(0.62·log p_jev + 1.09·fin0 + 0.51·fin1 + 0.32·new + 1.74·nc + 0.44·nc_lead + 1.30·an + 1.03·bm25_lastreply). For shipping, refit on all 182: `lp` 0.63, `fin0` 0.77, `fin1` 0.42, `new` 0.07, `nc` 1.92, `nc_lead` 0.22, `an` 1.18, `lx_said` 0.77.
3. **Send without Sonnet** only when P ≥ 0.90, the target is an idle thread (never running, never new), and Jev's route mass on running threads is under 0.25. Otherwise use Sonnet at 0.80 / 0.90, as today.
   - Sequential costs least.
   - Parallel saves about 0.18 s on the fallthrough.
4. **Preview** the same fused pick at ≥0.90 while you type. Show nothing below that.
5. **Gate the switch on the log.** Run the path in shadow next to Sonnet until about 200 Fjord decisions are logged.
   - Switch it on if its sends match Sonnet's or your final place with 0 wrong.
   - Refit the 8 weights on that log, and keep refitting.
   - Certifying 0.5% takes about 600 messages with no wrong send.

**What would close the remaining gap:**
- **Focus signals** (`lastVisitedAt`, the open thread), for terse reactions.
- **Twin and fork collapsing,** which is the one wrong send here.
- **A new-work lever:** the path abstains on new work, and the 19 cases cap any measurement.
