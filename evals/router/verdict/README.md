# Router v2 verdicts on real threads

The verdict (`Sources/Fjord/RouterVerdicts.swift`, prompt in `RouterVerdictPrompt.swift`) decides what the owner sees
first: whether a finished turn left them a step (`needs_you`), whether it is worth a look, and the line. It gates wave 3
of Router v2 ([IMPLEMENTATION.md](../../../docs/design/router-v2/IMPLEMENTATION.md), track 4, risk 1). Everything here
writes to `data/` (gitignored: it holds message text and stays on this Mac).

```sh
python3 evals/router/verdict/export.py        # T3's statev2.sqlite, read-only -> data/cases.json (150 finished turns of 7 days, every ask)
FJORD_VERDICT_EVAL_DIR=$PWD/evals/router/verdict/data swift test --filter VerdictEvalDump                            # inputs only
FJORD_VERDICT_EVAL_DIR=$PWD/evals/router/verdict/data FJORD_VERDICT_EVAL_RUN=1 swift test --filter VerdictEvalDump   # + live verdicts
```

- `export.py`: a finished turn is a completed run with a reply: your words that started it, its last reply, the files
  its checkpoints changed, the PRs linked by its end with their state then. An ask is a question or permission T3
  raised, with the reply before it. `--days`, `--finished`, `--seed`.
- The dump writes `system-<kind>.txt` and `schema-<kind>.json` (what every call sends), `inputs/<id>.txt` (each case's
  input exactly as the app sends it: redacted, fenced), and with `FJORD_VERDICT_EVAL_RUN=1` `verdicts/<id>.json`: the
  verdict and the seconds to its state, its whole line and its end, four calls at once as in the app. Answered cases
  are skipped, so a run resumes. 169 cases take about 4 minutes and $0.10.

**Gate (wave 2, on the owner's threads):** no line states a fact its reply or PR state doesn't; of the turns a person
marks as leaving a step, 90 % found; at most 10 % of `needs_you` wrong. Below that the prompt is fixed before wave 3.
Label `needs_you` on the finished turns by hand (or with a judge the owner checks), then score against `verdicts/`.

First live run (2026-11-12, 4 cases, 4 at once): a finished turn's state at 4.7 to 5.1 s, its line whole at 5.0 to
5.4 s, the end at 5.2 to 5.8 s; an ask's line at 2.5 s. Haiku 5.5 thinks before answering (about 150 tokens) even with
`alwaysThinkingEnabled: false`; Claude Code has no flag to stop it.
