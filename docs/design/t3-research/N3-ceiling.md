# N3: the ceiling of routing from the words alone (2026-11-08)

Aggregates only. Code is in `evals/router/t3/` (`n3common.py`, `n3judge.py`, `n3dec.py`, `n3bars.py`, `n3cause.py`, `n3test.py`), and the data is in `evals/router/t3/data/` (gitignored).

## Question
N2 left new work at 47% and follow-ups at about 3% wrong-thread. N3 asks two things:
1. Is the gold noisy? It records where the owner typed in T3.
2. Is the decider starved? It sees a few lines per thread, can't read any thread, and runs with thinking off.

## Setup
- **Dev sample:** 300 moments, stratified (new, new-continues, follow-ups, with N2's misses oversampled). Each moment carries a weight, so rates reweight to the natural ratio.
- **Clean gold:** two independent Opus 5.5 judges with thinking. Each read the full candidate threads before the moment and the hindsight after it, and labelled the moment as new thread (project), continues a given thread, or ambiguous. When the two disagree, either answer is accepted.
- **Deciders on the same boards:**
  - `sthink`: N2's prompt on Sonnet with thinking on.
  - `othink`: Opus with thinking.
  - `agent`: Sonnet with `search_threads` and `read_thread` tools, up to about 4 calls.
  - `rich`: a per-thread summary maintained by Haiku (what the thread delivers, its status, its open questions).
  - `agent_newdef`: `agent` framed as new-by-default.
- **Bars:** per-action bars (idle, running, new, p_new) fitted by day-grouped CV on dev, at a target of follow-up errors plus follow-ups started new.
- **Test:** a 112-moment sealed subsample (53 new, 52 follow-ups), judged by the same two judges. The two finalists ran once, with bars fitted on all of dev.
- **Spend:** about $80, mostly the two Opus judges at about $24 each on dev.

## 1. The gold is mostly right
- The two judges agree on 98% of moments (295 of 300; the disagreements are with "ambiguous").
- Against T3's gold:
  - Of 154 follow-ups, 146 really continue their thread, 7 are ambiguous and 1 is new work.
  - Of 146 first messages, 132 are new work, 7 continue an existing thread and 7 are ambiguous.
- So label noise is about 5%. It explains little of N2's failure, and the "noisy gold" hypothesis is mostly wrong.
- On test, the judges agree with each other on every moment they both labelled.

## 2. Smarter deciders: dev, clean gold, CV bars

At about 1% follow-up errors:

| Decider | New right | New pushed | Follow right | Follow wrong thread | Follow to new |
|---|---|---|---|---|---|
| sthink | 36% | 0% | 31% | 1.0% | 1.0% |
| rich | 45% | 2.2% | 27% | 0% | 0.7% |
| othink | 63% | 1.5% | 27% | 0.3% | 1.3% |
| agent | 61% | 2.2% | 49% | 0.3% | 1.3% |
| agent_newdef | 61% | 1.5% | 33% | 0.3% | 0.7% |

At about 3%, `agent` reaches 67% new right and 69% follow right (with 0.7% wrong-thread, 2.0% to new), and `othink` reaches 62% and 73%.

- **Reading threads (`agent`) is the best design.** It is the only decider that lifts new work and follow-ups together. Thinking alone (`sthink`) doesn't help. A maintained summary helps new work a little.
- **Test** (n=112, one sample; 1 error is about 1.9 points):

  | Finalist, bars from dev | New right | New pushed | Follow right | Follow wrong thread | Follow to new |
  |---|---|---|---|---|---|
  | agent at 1% | 72% | 1.9% | 29% | 1.9% | 1.9% |
  | agent at 2% | 74% | 1.9% | 40% | 3.8% | 1.9% |
  | othink at 1% | 74% | 0% | 21% | 1.9% | 3.8% |
  | othink at 2% | 74% | 1.9% | 48% | 3.8% | 3.8% |

  - **New work holds on test:** about 72–74% against N2's 47%.
  - **Follow-ups don't:** only 20–48% are sent, at about 2–4% wrong. That is far from top-tier.

## 3. Why follow-ups stay hard
The `agent` decider's remaining errors were classified (`n3cause.py`, weighted):
- The largest class is **UI context**: the message can only be placed by knowing what the owner was looking at or answering. Examples are a terse reaction ("yes, do it", "still broken") and a reply to a thread's latest output when several threads are in the same state.
- The second is **model error**.
- Then **information missing from the board** and **gold doubt**.
- 10 of the 31 follow-up errors are moments where the right thread is where the owner last wrote. A recency bar alone (`--ctx`) helps a little (follow right 49% to 55% at 1%) but doesn't close the gap.

In T3 history the owner typed inside the thread, so the thread being looked at *is* the gold. Routing from the words alone throws that signal away. No decider, however strong, can recover what was on the owner's screen.

## Conclusion
- Routing from the words alone has a ceiling of about 70% of new work and about 50% of follow-ups sent at about 1% wrong. Bigger models and thinking don't move it much. Reading threads moves new work.
- Top-tier routing needs Fjord to use the context of the moment of writing:
  - the brief item or thread being looked at or replied to;
  - the notification acted on;
  - the thread whose output was just read.
- That context should decide most follow-ups. The decider is left with unanchored messages, mostly new work and the choice of a project, where the `agent` design (search and read threads) reaches about 72%.
- This benchmark can't measure that context: it needs a simulation of writing from the brief, or Fjord's live logs (the decision log already records focus).

## What is noise
- Dev CIs are about ±10 points on each rate.
- Test has 53 new and 52 follow-ups, so 1 case is about 1.9 points.
- The judges' agreement is solid, and the variant ordering (`agent` > `othink` > `rich` > `sthink`) holds on dev.
