# N1: a new-work benchmark from the owner's T3 history (2026-11-08)

Aggregates only: no message text, titles or project names. Code in `evals/router/t3/` (`extract.py`, `moments.py`, `purposes.py`, `judge.py`, `run.py`, `score.py`, `board.py`); data, raw answers and full tables in the gitignored `evals/router/t3/data/` (`score.txt`, `taxonomy.txt`, `diag_dev.txt`).

**Why:** the owner says the router often fails to see new work: a message that should start a thread is sent to an existing one, or asked about. The 182-moment set has 19 new-work cases, too few to measure that.

## Headline
- **New-work recall is about 1 in 5.** Sonnet sends new work to a new thread in the right project on 20% of dev (CI 14–29%) and 18% of test (11–26%). The app's combination is the same (20% / 16%). Jev's fused path never sends new work, by design.
- **The failure is mostly asking, not wrong sends.** On new work Sonnet asks 71% (dev) / 74% (test), pushes into an existing thread 5% / 3%, and answers in Fjord 4%.
- **Without the bars it would be the owner's complaint exactly.** Sonnet's best guess on new work is right 50% / 49% of the time, and it is an existing thread 35% / 31% of the time. Jev's fused top-1 is the same: 52% / 50% right, 39% / 32% an existing thread.
- **Follow-ups are fine but over-asked.** Sonnet sends 53% / 60% of them correctly, with 0.9% / 2.6% wrong-thread sends. The pooled send rate at the natural ratio is 51% / 59%, with 1.6% / 2.8% wrong.
- **Biggest finding on Jev's path:** its untested "for Fjord itself?" check (≥0.30) stops 22% of all follow-ups. On those, the fused pick is right 97% of the time (dev 330 of 339, test 193 of 198). Without that check the path would send about 48% of follow-ups instead of 26%. That is a dev observation to confirm, not a change made here.

## Data
- **Source:** T3's `statev2.sqlite`, opened read-only. Nothing in T3 was changed and `userdata/secrets` was never read. 715 threads.
- **Imported history is dateable.** R1 says imported messages carry the import time. That is no longer true. The v1-imported Claude threads carry their real times, checked against the session transcripts on disk to the millisecond. So they are used as moments, which goes against the brief's default: without them only 17 native owner threads exist (2 days).
- **Cut imports filled in.** 26 imported threads were cut by T3 ("N earlier messages were not imported"). The gap is filled from each session's own transcript: 6,136 text messages, user and assistant only.
- **Period:** 2026-09-27 to 2026-11-08, 43 working days (Paris time, the day turning at 04:00).
- **Overlap with the 182:** 100 of the 182 old moments are among these. Same sessions, a different board, different gold rules.

### Threads
| Kind | Threads | Used as |
|---|---|---|
| Imported Claude Desktop sessions | 321 | moments + board |
| Imported Claude CLI sessions | 2 | moments + board |
| Native T3 threads the owner created (web, mobile) | 18 | moments + board |
| Fjord-created (createdBy user, source mcp: the S1 spikes) | 13 | board only |
| Agent-launched top-level threads | 29 | board only |
| Subagent and delegated threads (lineage `subagent`, `delegatedFrom`) | 215 | excluded (unlisted) |
| Imported Codex threads (every one a review or eval run Claude launched) | 92 | excluded |
| Imported headless `sdk-cli` sessions (agent-run tasks and tests) | 24 | excluded |

### Messages, exclusions and gold
- **Owner messages:** `role user`, `createdBy user`, not empty.
- **Excluded:**
  - 2,890 system texts in user turns: task notifications, system reminders, wakes, relays, CI events, `<bash-input>`, AGENTS.md preambles, interruptions, compaction notes;
  - 54 slash commands;
  - 14 retries (the same words in the same thread within 30 min);
  - 756 fork copies;
  - 246 owner messages in excluded threads.
  - Fjord-routed messages (source `mcp`) are excluded too: their gold would be Fjord's own pick. None remained in moment threads.
- **Forks:** a fork copies its parent's history at the same timestamps. It counts from its first message that is not a copy. Its copies are not moments, and that first message is its own class (`fork_start`, 34). One thread that is a pure copy is dropped.
- **Gold:**
  - A thread's first owner message → a new thread in its project.
  - Every later owner message → that thread.
  - No lenient twins: forks are not on the board before they exist.

### The board at each moment
- Rebuilt from history at the moment t, with the shipped rules ported from Swift (`board.py`): candidates, 12 h cut, 3 finished per project, cap 20, render, short ids, redaction.
- **Threads:** each listed thread that existed and had a message before t, minus those archived before t, and minus those settled before t with no activity since.
- **Running:** a turn was under way at t. For other threads, the next message after t is the agent's. For the moment's own thread, the owner's turn before t had no reply yet.
- **Per thread:**
  - activity: the latest message before t;
  - the reply: the latest agent message before t;
  - your last words, first ask and earlier messages: from the owner messages before t (the first ask is the earliest of the last 10, as the read-ahead does);
  - "your latest message went here".
- **Not rebuilt:**
  - titles: today's titles (some were renamed later, and imported ones summarise the whole session, so they can leak later work);
  - branch: today's;
  - not reconstructed at all: pull requests, current step, waiting requests.
- **Ids:** imported threads get their session uuid as the short id. The app would show `importcl…`-style ids for them, which is an artefact of the import.
- **Projects:** the 7 T3 projects on every board. Purposes are one Sonnet sentence per project from 12 thread titles of dev days (E3's method).
- **Board size:** median 5 candidates (mean 5.7, max 18). New-work moments have a median of 3 candidates in their own project.

### Splits and counts
- Days are split at random (seed fixed) into **24 dev days and 19 test days**.
- **The test is sealed:** nothing was tuned on it, and the lever notes below come from dev.

| Class | Dev | Test | What it is |
|---|---|---|---|
| `new` | 130 | 74 | a first message, the owner's words |
| `new_continues` | 16 | 10 | a first message the judge says continues an existing thread's work (the owner opened a new thread for a follow-up) |
| `brief` | 20 | 14 | a first message the judge reads as an agent-drafted brief (delegation prompts pasted into a new session) |
| `fork_start` | 19 | 15 | the first own message of a fork |
| `follow` | 1,540 | 920 | later messages in a thread |

- **Natural ratio:** new work (`new` + `new_continues`) is 8.6% of the 2,690 main moments, and 230 new-work cases in all (12x the 182 set).
- **Sub-types of `new` (both splits):**
  - 111 are in the same project as the latest active thread, 93 in another;
  - 42 have no candidate thread in their project;
  - 9 were retyped from another thread within 2 h.
- **Judge's relation for `new`:**
  - 138 share a topic with an existing thread; in 73 of them that thread is on the board (**the hard case**);
  - 66 are unrelated.
- **Typing bias, flagged:** every follow-up was typed inside its thread (Claude Desktop or T3), so it can lean on context the router doesn't see. First messages were typed standalone. 112 follow-up golds were running at the time, and 72 were off the board (older than 12 h, or settled).

## Gold check (model judge)
- **The judge:** Sonnet 5.5, thinking on, over the 25 most recent threads before the message (any age). Cost $5.25.
- **All 298 first messages:**
  - 71 continue an existing thread's work;
  - 156 share a topic with one;
  - 71 are unrelated.
  - 34 read as agent-drafted briefs.
  - Owner-written first messages that continue a thread: **26 of 230 (11%)** are kept as `new_continues`. The rest that "continue" are briefs (20) and forks.
- **80 random follow-ups:** 77 continue their thread, 2 are new work typed into an existing thread, 1 is unclear. So about 2.5% of follow-up gold is really new work.
- The judge's confidence is middling (median 0.7), so read its labels as ±10%.

## Results
- **Setup:**
  - Sonnet `claude-sonnet-5-5` is called as the app calls it: the role as a cached system block, JSON schema, thinking `between_tools`, max 700, bars 0.80 idle / 0.90 running.
  - Jev's fused path is `jev-1.14.0` with the shipped request, weights and gates, including the `fjord` check. All 2,758 moments, everything redacted.
  - Combined = the app: Jev's send when it sends, else Sonnet's decision.
- **Sampling:** Sonnet ran on every first message plus a seeded 30% of follow-ups (1,024 calls). Pooled rows reweight follow-ups to the natural ratio. The 95% CIs are a bootstrap over days.

### Dev (24 days)
| | New: right | New: pushed into a thread | New: asked | Follow: right | Follow: wrong thread | Follow: asked | Pooled sent | Pooled wrong | Wrong project |
|---|---|---|---|---|---|---|---|---|---|
| Sonnet | **20.0%** (14–29) | 5.4% (1–10) | 70.8% | 52.5% (46–59) | 0.9% (0–2) | 45.8% | 51.2% (45–57) | 1.6% (1–3) | 0.6% |
| Jev path | 0% | 3.1% | 96.9% | 25.4% | 0.2% | 74.4% | 23.8% | 0.6% | 0.1% |
| Combined | 20.0% (14–29) | 6.2% (1–11) | 70.0% | 54.9% (49–61) | 0.9% (0–2) | 43.4% | 53.5% (48–59) | 1.8% (1–3) | 0.6% |

### Test (19 days, sealed)
| | New: right | New: pushed into a thread | New: asked | Follow: right | Follow: wrong thread | Follow: asked | Pooled sent | Pooled wrong | Wrong project |
|---|---|---|---|---|---|---|---|---|---|
| Sonnet | **17.6%** (11–26) | 2.7% (0–6) | 74.3% | 60.0% (51–68) | 2.6% (1–5) | 36.6% | 59.2% (51–66) | 2.8% (1–4) | 0.8% |
| Jev path | 0% | 2.7% | 97.3% | 26.4% | 0.8% | 72.8% | 25.2% | 1.0% | 0.1% |
| Combined | 16.2% (10–23) | 4.1% (0–8) | 74.3% | 61.5% (53–69) | 3.0% (1–6) | 34.7% | 61.0% (53–67) | 3.4% (1–6) | 0.9% |

- **Precision of sends:** Sonnet 96.8% / 95.2%, combined 96.6% / 94.5%. Jev alone on every moment: 24.7% / 23.7% sent, with 0.7% / 1.1% wrong.
- **New work in Fjord:** Sonnet answers 4% of new work as "for Fjord" at ≥0.80.
- **Smaller classes** (dev / test), Sonnet then combined:
  - `new_continues`: 6% / 10% right with 25% / 10% pushed. Combined pushes 38% / 20%, and those pushes are arguably acceptable, since the judge says the message continues that thread.
  - `brief`: 55% / 71% right (combined 45% / 57%, pushed 30% / 36%). Explicit briefs are the easy new work.
  - `fork_start`: never a new thread; 33–47% are sent to an existing thread (the parent is the defensible place; which thread was not checked).
- **Top-1 without bars, on `new`:** Sonnet 50% / 49% right, 35% / 31% an existing thread. Jev fused 52% / 50% right, 39% / 32% an existing thread.
- **Latency:** Sonnet p50 2.17 s, p95 3.92 s (4 in flight). Jev p50 0.17 s, p95 0.22 s, at a mean of 5.3k input tokens.
- **Spend:** Sonnet $6.38, judge $5.25, Jev about $0.75. About $12.4 in all.

## Error taxonomy for new work (dev + test `new`, 204, Sonnet)
1. **Unsure new work: an ask that should have been a new thread.** This is the largest class.
   - Sonnet answers `new_work` on 92 of 204, in the right project on 80. Only 41 of those 92 reach the 0.80 bar (median confidence 0.72).
   - It asks outright on 33, and 25 of those asks put a new thread first (20 in the right project).
   - The confidence on new work is calibrated low, so the idle bar drops most correct new-work answers.
2. **Topic pull: the hard case.**
   - Of Sonnet's 68 top-1 picks of an existing thread, 53 are in the right project and 59 share a topic with the message (judge). In 40 the pick is the very thread the judge named as related.
   - When the related thread is on the board, Sonnet sends only 6 of 73 to a new thread.
   - This is "pushed into a session because it shares a topic", which the role forbids, and it still happens at about 0.6 confidence: held back by the bar, not avoided.
3. **Recency and running pull.** Of the 68 top-1 thread picks, 26 are a running thread and 34 are among the 3 most recent idle threads. 48 of the 68 are in the project of the latest active thread. New work in that project is the worse case (16 of 111 sent right, against 23 of 93 in another project).
4. **Fjord intent.** 18 of 204 new-work messages get `answer_here` (8 acted on at ≥0.80): new work read as a question for the manager.
5. **Wrong project:** rare. 1 new thread in the wrong project and 4 cross-project pushes over 204.
6. **Jev's path never sends new work by design** (`new_thread` abstain on 130). On follow-ups it abstains on: `below` 1,081, `fjord` 537, `new_thread` 103, `running` 79, `running_mass` 15.

## What the dev split suggests (not applied, test untouched)
- **A lower bar for `new_work` alone.** On dev, `new_work` answers at 0.70–0.79 were 11 right new threads against 2 sampled follow-ups (about 7 follow-ups at the natural ratio). A wrong new thread is revertible (R1), so this is the cheap lever, to be checked as a pre-registered change on test.
- **Re-check the `fjord` gate on Jev's path.** It vetoes 22% of follow-ups at 97% right, roughly doubling what the path could send. E5 never measured it.
- **For topic pull, a check of "is this thread's job done, and is this a different task?"** against the thread's first ask is the lever the taxonomy points to. Live: the board's purpose and "last threads" don't stop it.

## Caveats
- **The typing context isn't Fjord's.** Follow-ups were typed in-thread, and new messages were typed into a fresh session, not into Fjord's single box. Live traffic may hold more terse new work.
- **Today's titles, not the titles of the day.** Pull requests, current step and waiting requests weren't rebuilt.
- **Unknown routing in v1.** In v1, some imported messages may have been routed by Fjord's old router. They can't be told apart, so the gold may echo that router's picks.
- **The judge labels classes, not the gold.** Its 11% `new_continues` and 2.5% follow-up-as-new-work rates are single-judge estimates.
