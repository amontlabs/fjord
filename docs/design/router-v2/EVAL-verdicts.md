# Router v2 verdicts on real threads (wave 2 eval, 2026-11-12)

Data: 169 real cases from T3's state (150 finished turns of 7 days, 19 asks), exported by `evals/router/verdict/export.py`
and dumped by `VerdictEvalDump`. Calls are made the way the app makes them (`claude -p`, streamed, no tools, `effort low`,
4 at once; `evals/router/verdict/run.py`). The ground truth for `needs_you` is a blind Opus judge that sees only the case
facts (`judge.py label`); the same judge grades each line, name and `worth` with the verdict in view (`judge.py grade`).
The machine was under heavy load during the runs (load average about 60), so the absolute times are pessimistic.

## Caveats

- Labels are Opus's, not the owner's. 40 of the 150 finished turns are positive; 26 of those are high-confidence. **Every
  config below finds all 26 high-confidence positives with no high-confidence false alarm.** All differences are in
  medium-confidence cases, which are close calls (see the errors).
- The v2 prompt was written after reading the base prompt's errors on these same cases, so its numbers are not held out.
  Re-run on the owner's next week of threads before treating the difference between v2 and base as proven.
- Asks (19): `state` is fixed by code, so only line and name matter; see the end.

## Results (finished turns, n = 150)

| config | precision | recall | wrong of flagged | line accurate | name ok | worth ok | state p50 / p90 | line p50 | end p50 |
|---|---|---|---|---|---|---|---|---|---|
| Haiku, app prompt (base) | 0.82 | 0.93 | 18 % | 0.98 | 0.89 | 0.97 | 5.2 / 6.5 s | 5.5 s | 5.8 s |
| Sonnet, app prompt (base) | 0.92 | 0.82 | 8 % | 0.99 | 0.97 | 0.98 | 2.5 / 3.6 s | 3.0 s | 4.6 s |
| Haiku, v2 prompt | 0.95 | 0.93 | 5 % | 0.97 | 0.97 | 0.95 | 5.1 / 6.8 s | 5.4 s | 5.7 s |
| Sonnet, v2 prompt | 0.97 | 0.85 | 3 % | 0.99 | 0.97 | 0.98 | 2.4 / 3.7 s | 3.0 s | 4.6 s |
| Haiku, v2 lite (`low`) | 0.93 | 0.93 | 7 % | 0.96 | 0.99 | 0.97 | 4.2 / 5.5 s | 4.5 s | 4.6 s |
| **Sonnet, v2 lite (`low`)** | **0.97** | **0.90** | **3 %** | **0.99** | **0.98** | **0.98** | **2.1 / 3.4 s** | **2.8 s** | **2.8 s** |
| Sonnet, v2 lite, reply clipped to 1500 | 0.92 | 0.90 | 8 % | not graded | | | 2.0 / 2.4 s | | 2.7 s |

"lite" = schema without `ask`, `options`, `result` (and their prompt lines). Errors, Sonnet v2 lite: 1 false alarm, 4 misses.

**Plan's gate** (no line states a fact the reply or PR does not; 90 % of turns that leave a step found; at most 10 % of
`needs_you` wrong): met by Sonnet v2 lite (found 36 of 40 = 90 %, 3 % wrong, 1 of 150 lines flagged inaccurate) and by
Haiku v2 (93 %, 5 %, 5 of 150 lines flagged). Not met by Haiku base (18 % wrong) or Sonnet base (82 % found).
Sonnet v2 full-schema sits at 85 % found, just under; the lite prompt's wording edit moved it to 90 %, which is within
noise of one or two cases.

## Errors (Sonnet v2 lite)

- False alarm `0e4ce60a-r94` (also wrong for every other config): the reply says the agent resumed after a stall and is
  waiting on its own background work, but the input carries a stall notice and the line says "agent stalled; check and
  restart". Arguably right on the facts the model had; the judge saw only the reply.
- Misses, all medium-confidence, all "the agent holds an offer and waits for a go": `f0aad427-r11` (two PRs agreed, none
  opened, "I'd confirm with a quick test first"), `ba8afcc9-r23` (the owner stopped it; an 11 px overflow is
  left unfixed and uncommitted), `9290c216-r27` (a Linear edit is pending a reconnect only the owner can do),
  `c0734ac2-r60` ("safe to delete whenever you say so"). The lines are accurate and carry the open item, only `state`
  says `done` (worth is `look` on three of them).
- Haiku's extra errors are false alarms on agents handling it themselves (`485e9190-r252`, `ba8afcc9-r25`) and misses of
  `6dbbe30a-r2`, `ba8afcc9-r14`.

## Latency

Machine load average about 60 (other agents), 4 calls at once unless noted. Seconds from process start, median over the
cases:

| config | state | line | end |
|---|---|---|---|
| Haiku v2 full schema, effort low (app today) | 5.2 | 5.4 | 5.7 |
| same, `effort low` re-tested on 40 | 4.2 | 4.6 | 4.6 |
| Haiku lite, low, reply clipped 1500 | 4.3 | | 4.6 |
| Haiku lite, low, alone (12 calls, one at a time) | 3.8 | | 4.1 |
| `MAX_THINKING_TOKENS=0`, `CLAUDE_CODE_DISABLE_THINKING=1` on Haiku | 5.1 / 4.9 | | no change |
| Sonnet v2 full schema, low (40) | 1.9 | 2.5 | 3.4 |
| **Sonnet v2 lite, low (150)** | **2.1** (p90 3.4) | **2.8** | **2.8** |
| Sonnet v2 lite, low, alone | 1.8 | | 2.5 |

Cause: Haiku 5.5 spends 450 to 650 thinking tokens on every call and no flag or env var turns it off (both tried; the
usage report still counts 450 to 690 thinking tokens). Sonnet 5.5 thinks about none (0 to 7 tokens) and outputs the same
fields in under half the time. Cutting the input (reply clip) changes nothing measurable and the clip lost precision in
one run (`a7d55d9a-r8`, `1ec695c6-r5` flagged), so: **no clip**. Dropping the three needs_you-only fields saves 0.6 s at
`end` and nothing at `state`/`line`.
Cost: Sonnet about $0.01 per verdict ($1.6 per 150) against Haiku $0.0008; both come out of the subscription.

## Recommendation for the integrator

1. **Model: Sonnet (`claude-sonnet-5-5`) for finished-turn verdicts**, effort `low` (already in `RouterVerdictPrompt.swift`
   line 165). State at about 2 s, line at 2.8 s under 4-at-once, against 5 s. Keep Haiku for the ask and name kinds
   (their numbers: ask line accurate 0.95 on Haiku, 0.79 on Sonnet in the base run; names fine on both), where the
   first-launch queue is mostly asks and names.
2. **Prompt: `evals/router/verdict/prompts/system-finished-v2.txt` replaces the app's finished system text.** Its two edits
   against `data/system-finished.txt`:
   - `state` gains: `has a section for the user to decide ("For you to decide", "What I need from you")`; `asks to approve a
     next step ("Want me to merge it?") that the work really stops at`; `merge an open pull request, install or update the
     app, sign in, post a reply, run a command`; `ends on an error it couldn't fix and isn't handling`; and for `done`:
     `and when the agent itself is handling what comes next: it waits on its own background tasks, other agents, reviews or
     CI, it says it is fixing or rerunning a failure, or it only offers to narrow or extend its answer with more detail from
     the user. Notes about what it didn't check are not a step for the user unless it asks for one.`
   - `name`: `what the whole thread is about` and `never the latest step, phase or subtopic of the reply`.
3. **Schema: drop `ask`, `options`, `result` from the first pass of a finished turn** (`system-finished-v3-lite.txt` and
   `schema-finished-lite.json` are the trimmed forms) if the card for a `needs_you` turn can wait about 1 s more; if the
   card needs them at once, keep the full schema: with Sonnet it still gives state 1.9 s, line 2.5 s, done 3.4 s. Either
   way the first words appear in 2 to 3 s, which is the number that matters. Recommended: keep the full schema (no second
   call to build), since `state` and `line` are not slower.
4. **Do not clip the reply** and do not try to turn thinking off for Haiku.
5. Remaining misses are "the agent waits for a go on an offer". Do not widen the prompt for them: the lines already carry
   the open item and `worth: look`, and widening raised false alarms in the base run (18 % wrong).

## Asks (19, base run)

Haiku: line accurate 0.95, useful 0.74, name ok 0.95; Sonnet: accurate 0.79, useful 0.37, name ok 0.89. The `worth` column
for asks is meaningless (fixed by code, the judge's `worth_ok` there compares a field the app ignores). So Haiku stays on
asks. 19 cases is thin; not re-run for v2 since the ask prompt did not change.

## Reproduce

```sh
python3 evals/router/verdict/run.py NAME --system evals/router/verdict/prompts/system-finished-v2.txt --kind finished \
        --effort low --model claude-sonnet-5-5          # add --schema prompts/schema-finished-lite.json for lite
python3 evals/router/verdict/judge.py label; python3 evals/router/verdict/judge.py grade NAME; python3 evals/router/verdict/judge.py score NAME
```
