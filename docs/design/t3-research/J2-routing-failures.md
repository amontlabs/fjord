# J2: why Jev and Sonnet route to the wrong thread or ask (2026-11-08)

This doc holds aggregates and abstract class descriptions only. Per-moment notes, dossiers (board, answers and the source transcript around each moment), classes and probe answers are in the scratchpad under `deciders-t3/jev-context/`:
- `failures/classes_*.jsonl`: one line per failing moment.
- `failures/dossiers_*.txt`: what was read for each moment.
- `failures/probe_*.jsonl` and `failures/sonnet_H.jsonl`: the probe answers.
- `probe.py`, `score_probe.py`, `agg.py`: the scripts.

The data is [E3](E3-decider-t3-board.md) and [E4](E4-jev-on-t3-board.md): the 182 moments, the T3-shape board, Sonnet b1/b2, and Jev s0/s1.

## Method
- **Failure set: 104 of 182 moments.** A moment is in it when Jev's or Sonnet's top-1 is wrong in either sample, when either sent wrong, or when Sonnet asked.
  - Jev s0: 98 top-1 misses, 54 of them an intent pick, and 6 wrong sends at 0.70.
  - Sonnet b1: 46 top-1 misses, 3 wrong sends, and 21 asks.
- **Classification.** Four Sonnet subagents classified 26 moments each, against a fixed list of codes. For each moment they read the board as the models saw it, both answers, the gold, and the local source transcript: the turns before, the turn itself with the reply, and the turn after.
  - Each moment got a primary class, up to two more, a gold-quality verdict, and the piece of context that would have resolved it.
  - I spot-checked the wrong sends and every questionable gold.
  - Read the counts as ±2–3: one reader per moment.
- **Probes.**
  - Jev was re-asked with variant requests on all 182 moments, not only the failures, so its numbers are real scores. Each variant is one sample, and E4's s0 against s1 differ on 12 of 182 picks.
  - Sonnet was re-asked once, on its 39 top-1 misses that aren't duplicate-gold, so that probe is indicative only.
  - Everything sent went through `redact()`.

## Gold quality
- **26 of 182 moments (14%) are duplicate-gold.** The message sits verbatim, at the same timestamp, in a second session. These are copies of one conversation stored under two ids: identical turns and timestamps, and the copy continues identically after the moment. Picking the copy is right, but strict gold counts it as wrong.
  - 15 of them are in the failure set, and Sonnet picked the copy on 7.
- **7 more golds are questionable:**
  - two threads were equally plausible;
  - a "new thread" label where the real thread had been cut from the data;
  - the owner re-ran the same task in a fresh thread beside a running one;
  - the owner retyped a refined request into the twin of a thread that had just answered it.
- **None is plainly wrong.** In all, 22 of the 104 failures (12% of all moments) have a questionable gold.
- **Lenient rescoring** (duplicate copy counts as right):

  | | Top-1, strict → lenient | Wrong sends, strict → lenient |
  |---|---|---|
  | Sonnet b1 | 75% → 79% | 3 → 2 |
  | Sonnet b2 | | 4 → 2 |
  | Jev s0 | 46% → 48% | 6 → 6 |

- **Sonnet's confidence is clean at the top.** At ≥0.90 it is right on 55 of 55 (lenient), and at 0.80–0.89 on 36 of 39.

## Failure classes
Counts are primary (any) among each model's non-success outcomes on the 104:
- Jev: 104 = 54 intent picks, 38 wrong and held, 6 wrong sends, 6 right but under the bar.
- Sonnet: 79 = 27 right and held, 10 asked with the right best guess, 11 asked with the wrong one, 27 wrong and held, 4 wrong sends. The other 25 moments were right sends, failed only by Jev.

| Class | Jev | Sonnet | What would resolve it | Live on T3 / Fjord? |
|---|---|---|---|---|
| **Escape to an intent**: Jev picks `unclear` or `question` although one thread plainly fits | **50** (55) | — | The option format: no `unclear` or `compound` among the route options, or places and intents scored apart | Yes (request format) |
| **Duplicate or forked twin**: two or three candidates with the same title, the same latest reply and the same last owner words | 13 (24) | **21** (24) | Collapse or mark copies before the decider sees them | Yes: equal latest message or checkpoint is checkable; T3's own fork links not checked |
| **Right but cautious**: Sonnet's pick is right and the board was enough, but its confidence is under the bar or it asks | — | **18** (35) | Nothing on the board; this is calibration | — |
| **Terse reaction**: a bare yes, go-ahead or one-word command; only what the owner was just looking at decides | 8 (31) | 11 (23) | What is focused or visible in Fjord's brief, the thread just read (`lastVisitedAt`), the last routing | Yes: Fjord's focus and routings; T3 `lastVisitedAt` |
| **New work vs follow-up**: new work pushed into a related thread, or a follow-up sent to a new thread | 11 (21) | 8 (10) | An explicit cue for new work; the thread's own task, so a finished job reads as finished | Partly: the first message and plan say what the job was |
| **Topic pull**: a thread sharing keywords (often one repeating the owner's own words) wins over the one doing the task | 4 (25) | 2 (17) | The thread's task and history, not only its title and tail | Yes (messages) |
| **Signal in older turns**: the thread's earlier task, files or decisions | 1 (16) | 5 (12) | The first message, the owner's earlier messages there, or a task summary | Yes (messages, plans, todos) |
| **Signal earlier in the latest reply**: a question or option list the 600-char tail cuts off | 0 (6) | 2 (5) | The reply's head, or the question it ends with | Yes (messages) |
| **Running thread**: pulled to a running thread, or not to a fresh one | 4 (10) | 4 (9) | The current todo step; whether the message would interrupt it | Yes (todos, activities) |
| **Wrong project** | 3 (6) | 4 (8) | A better project purpose | Yes (Fjord's purposes) |
| **Gold not on the board, or its facts cut**: the project's latest thread older than 12 h; a just-continued session dropped by the 3-per-project cap | 3 (5) | 2 (4) | Candidate rules: always the project's latest thread, and threads created in the last minutes | Yes (thread list) |
| **Jev ordering or calibration**: the first or most recent option wins; high confidence on a wrong pick | 7 (35 any) | — | No context fix found (below) | — |
| Questionable gold or Fjord meta as primary | 1 | 2 | — | — |

Context the readers named as the fix, primary (any), over the 104:

| Fix | Primary (any) | Fix | Primary (any) |
|---|---|---|---|
| Focus or what was just read | 23 (50) | Head of the latest reply | 7 (12) |
| Dedupe copies | 18 (24) | Better purpose | 4 (5) |
| Thread history summary | 14 (22) | New-work cue | 2 (8) |
| Jev option format | 14 (22) | Branch or diff | 1 (3) |
| The question the thread ended with | 9 (20) | Nothing would help | 3 |
| Recent routings | 9 (21) | | |

## Probes
**Jev on all 182, lenient gold.** Sends use the bar shown, with 0.90 for a running thread.

| Variant | Top-1 | Intent picks | Sent / wrong at 0.70 | 0.80 | 0.90 |
|---|---|---|---|---|---|
| base (E4 s0) | 48% | 54 | 21% / 6 | 13% / 3 | 7% / 2 |
| H: per thread "you last wrote here N ago", latest one marked | 50% | 56 | 29% / 5 | 18% / 3 | 10% / 3 |
| R: the thread of your latest message first | 50% | 51 | 26% / 5 | 17% / 3 | 9% / 3 |
| N: no `unclear` or `compound` | 52% | 29 | 25% / 8 | 18% / 5 | 8% / 2 |
| D: copies dropped | 48% | 54 | 24% / 6 | 15% / 3 | 7% / 2 |
| S: last message cut to 250 | 41% | 68 | 21% / 6 | 14% / 4 | 6% / 2 |
| L: + the first message, your last 3 messages, and the head of the latest reply | 51% | 46 | 21% / 4 | 19% / 4 | 10% / 2 |
| HND | 58% | 25 | 34% / 9 | 25% / 5 | 13% / 4 |
| LNH | 57% | 24 | 31% / 8 | 21% / 4 | 14% / 3 |
| P: the previous message and the thread it went to, in the state | 53% | 11 | 55% / 28 | 47% / 19 | 37% / 16 |

- **More context helps Jev's top-1, and less hurts it.** Thread history (L) and owner recency (H) each add 2–3 points. Dropping the escape intents (N) adds 4. Combined, top-1 goes from 48% to 57–58%, still under Sonnet's 79%.
- **No variant brings Jev's wrong sends near zero.** At 0.80, the best variants send 18–25% with 3–5 wrong (1.6–2.7%).
- **Jev's confidence stays flat at the top:** 10 of 12 right at ≥0.90 on base, 22 of 25 on LNH. Sonnet's is 55 of 55.
- **4 moments are wrong sends at 0.80 under 6 to 11 of the 11 variants:**
  - 2 have questionable gold: a re-run task beside a running thread, and a retyped twin;
  - 1 is new work in a project with a related finished thread;
  - 1 has its gold thread off the board (the project's latest thread was older than 12 h).
- **Recency is a trap when fed raw.** The thread your previous message went to is the gold in only 48% of existing-thread moments (79 of 163). The most recent idle thread is the gold in 60%.
  - When P puts the previous routing in the state, Jev anchors on it: sends rise to 55% but wrong sends to 28.
  - Marking it as a soft per-thread fact (H, R) costs nothing on wrong sends and adds 5–8 points of sends.
- **Sonnet with the H board, on its 39 non-duplicate top-1 misses (indicative):**
  - 10 flip to right;
  - but it sends 6, and 5 of them are wrong (2 of these 39 were sent wrong before);
  - and it asks on 10.

  Owner recency makes Sonnet surer in both directions. Don't add it to Sonnet's board without a full-set run.

## What this means for the context
1. **Dedupe copied or forked threads before the decider sees them.** This is the largest Sonnet class, and it holds Sonnet at about 0.6 on otherwise easy moments.
   - Most of it is a corpus artifact: one conversation stored twice.
   - On T3 it applies only where real forks or duplicate threads exist.
   - Score future evals with lenient gold.
2. **For Jev, fix the format before the context.** Half of Jev's misses are escape-intent picks. The question and change-Fjord intents need a separate yes/no gate, not a slot competing with the threads.
3. **Focus is the missing signal for terse reactions, and the 182 moments can't measure it.** The transcripts have no "what was on screen".
   - What the owner was last looking at in Fjord's brief, plus T3's `lastVisitedAt`, is live on T3 and Fjord.
   - Collect it in Fjord's routing logs before relying on it.
   - Last-routing alone is right only half the time, and models over-trust it.
4. **Add the thread's task, not more tail.**
   - The first message, the owner's recent messages there, and the question the reply ended with resolve most of the older-turns, latest-reply, topic-pull and new-vs-follow-up cases.
   - All of it comes from T3 messages, and it helps Jev (L, +3 points, fewer wrong at 0.70).
5. **Widen the candidate rules a little:** always the project's latest thread, and threads created minutes ago.
6. **Jev can't be the sender on this data, even with every context piece tried.** Its high-confidence band is wrong on about 1 in 8–10, and Sonnet's ≥0.90 band is clean.
   - The ideal, "Jev routes a large share and almost never sends wrong", is not reachable through context alone.
   - It would need a Jev-side calibration change, or live logs showing that focus closes the terse class.
