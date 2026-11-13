# Router v2 working summaries on real threads (2026-11-13)

A working line reads a short line the Router's model writes about what its thread is doing now (DESIGN.md 1.4 "Working,
summed up", **R6**; `RouterSummaryPrompt.swift`, `RouterRecords.summarizeIfNeeded`). This is how its prompt was chosen.

## Data and method

- **30 moments** from the owner's T3 history of the last 7 days (`evals/router/summary/export.py`, read-only from
  `statev2.sqlite`, output in the gitignored `data/`). 15 runs of 4 minutes or more, picked at random from 163; two
  moments per run, a quarter and three quarters through it, each just after the agent finished writing something mid-run.
  The later moment is told the earlier one's line, as the app does.
- **Inputs exactly as the app builds them** (`SummaryEvalDump` test: redacted, fenced): the thread's title and project,
  your words that started the run (600 characters), the agent's latest whole words (their last 1,500 characters), the
  to-do list (none of these runs had one: T3's to-do setting is off), the tool running now and the three before it, the
  previous line.
- **Calls as the app makes them** (`run.py`): `claude -p`, Haiku 5.5, streamed, no tools, effort `low`, 4 at once.
- **Judge**: Opus (`judge.py`), blind to the prompt version. It sees the thread's facts and what the run really did from
  6 minutes before the moment to 2 minutes after (the agent's words and tools, the moment marked), and grades the line:
  `accurate` (nothing the facts don't support, the current step right), `useful` (tells concretely what it is on now; not
  vague, not a past step, no command dump), `reads_well` (short, plain, present tense), and a 1–5 score.

## Results (n = 30 each)

| prompt | accurate | useful | reads well | score | end p50 / p90 | output tokens |
|---|---|---|---|---|---|---|
| v1: rules, one `line` field | 0.87 | 0.93 | 1.00 | 3.90 | 3.3 / 4.7 s | 228 |
| v1, again (noise check) | 0.83 | 0.90 | 0.97 | 3.67 | 3.5 / 4.8 s | 172 |
| v2: + "the next thing, from the words' last sentences" | 0.80 | 0.93 | 1.00 | 3.73 | 3.4 / 4.0 s | 190 |
| v3: + "result so far; what they say it does next" | 0.87 | 0.93 | 0.97 | 3.80 | 3.5 / 5.7 s | 224 |
| **v4: `done`, `now`, then `line`** | **0.97** | **1.00** | **0.97** | **4.03** | **4.4 / 5.8 s** | 462 |
| v4, again | 0.93 | 1.00 | 0.97 | 3.87 | 4.6 / 5.8 s | 524 |

Between two runs of the same prompt the rates move by about 0.04 (one or two moments): v1 to v3 are the same prompt as far
as this eval can tell. Wording alone didn't fix their main error, Haiku calling a step the agent's words report as done
the current one ("New explanations are generated; now applying the layout" → "Generating project explanations; next,
applying layout"), about one moment in eight. **v4** asks for two short fields first, what the latest words report done
and what the agent is on now ("never something `done` lists"), and builds the line from them: that error went to one in
thirty, and every line was judged useful in both runs. It costs about 250 more output tokens and 1.1 s more to the line's
end; the line is the last field, so its words still stream (the line sheens for those seconds). Only `line` is kept.

**The app sends v4** (`evals/router/summary/prompts/system-v4.txt`, `schema-v4.json`; a test keeps them the same).

## What it still gets wrong

- `ba8afcc9-r63` (both v4 runs): an agent whose words are one terse sentence each ("Inspecting workflow details via
  task-678 in the background.") had pushed the release in a command a few minutes earlier; the line said "before
  release". The push is outside the input (only the tool now and the three before it are read), and widening the input
  for terse agents would cost every call.
- Judge notes on lines it still passed: a line can trail the agent by one step when the moment is right at a step's end,
  and two lines carried a raw field name (`plan_display_name`) where a plain phrase would read better.

## Latency, cost, and how often

- **Latency**: the line whole at 4.4 s p50, 5.8 s p90 (4 at once, the machine otherwise busy).
- **Cost**: $0.0004 to $0.0005 per call as `claude -p` reports it (about 2,100 input tokens, mostly the cached system
  prompt and Claude Code's own; about 500 output tokens, Haiku's thinking included). The app logs each call under the
  role `summary` (Settings' usage, `model-usage.jsonl`).
- **Calls per day**: replaying the owner's last 7 days of T3 runs (1,935 runs, 2,225 mid-run messages, subagent
  threads left out) through the app's rules (a call on new words or a to-do step, at most one a minute per thread, none
  after the run's last words) gives **211 calls a day on average, 315 on the busiest day**: about **$0.10 a day**
  ($0.15 at most), out of the subscription like the verdicts. With summaries queued behind every verdict, the 4-call cap
  is shared and asks and finished turns never wait on them.

## Rerunning

```sh
python3 evals/router/summary/export.py                                   # data/cases.json
FJORD_SUMMARY_EVAL_DIR=$PWD/evals/router/summary/data swift test --filter SummaryEvalDump   # system.txt, schema.json, inputs/
python3 evals/router/summary/run.py v4                                   # the app's prompt -> data/runs/v4
python3 evals/router/summary/judge.py v4 && python3 evals/router/summary/judge.py score v4
```

`run.py NAME --system FILE --schema FILE` tries another prompt. Answered moments are skipped, so a run resumes.
