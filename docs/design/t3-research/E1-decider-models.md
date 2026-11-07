# E1: which model decides the routing (2026-11-06)

Aggregate numbers only; no message text. Raw answers and boards stay in the scratchpad (`.../scratchpad/deciders/res_{sonnet,haiku,luna}.jsonl`, runner and scorer beside them).

## Setup
- **Moments:** the same 182 as runs C–F: 120 dev + 62 realB (realB outside the sealed groups and the dev 120). Strict gold, one sample per moment.
- **Board:** Fable's recipe E, the Sonnet rendering (`build_sonnet` in the run-E script), every text field through `boards.redact()`; same role text and `ROUTE_SCHEMA` for all three. **Not rendered in T3's shell shape.** The shell shape needs T3 records the 182 Claude-transcript moments don't have (and E already carries most of R1 §A: status, last answer, your last message, waiting text, "new in <project>" with content). Do it when the board renderer is rebuilt for the app.
- **Calls:** Sonnet `claude -p --model claude-sonnet-5-5`, Haiku `claude-haiku-5-5` (same flags as `manager_eval.call`, JSON schema); luna `codex exec -m gpt-6-luna --ephemeral --ignore-user-config --sandbox read-only --output-schema <strict copy of the schema> < /dev/null`, cwd in an empty directory, default reasoning effort. 4 calls at a time, so latencies include some contention. Codex read redacted text only.
- **Harness check:** Sonnet rerun on all 182 vs the recorded E run: project 92% vs 91%, session 76% vs 74%, sent 47% vs 47%, same pick on 156 of 182. Recorded realB session 79% reproduced exactly. New work 6/19 against 8/19 recorded and wrong sends 3 against 2 are the run-to-run noise of one sample.

## Results (send bar 0.8; "eq" = luna's bar moved to Sonnet's send rate)
Wrong-thread = a send (action and confidence over the bar) to any destination other than the gold one, wrong-project included.

| Pooled 182 | Proj top-1 | Sess top-1 | Sent | Wrong-thread sends | Wrong-project sends | New right (of 19) | p50 / p95 | Cost |
|---|---|---|---|---|---|---|---|---|
| Sonnet @0.8 | 92% | 76% | 47% | 3 (1.6%/msg) | 1 | 6 | 5.8 / 9.9 s | $0.018 |
| Haiku @0.8 | 85% | 63% | 46% | 7 (3.8%) | 3 | 4 | 5.3 / 8.3 s | $0.0015 |
| luna @0.8 | 82% | 55% | 81% | 51 (28%) | 17 | 4 | 5.0 / 9.6 s | n/a (about 6k tokens/call) |
| luna @0.97 (equal coverage) | 82% | 55% | 46% | 18 (9.9%) | 5 | 4 | same | |

| Split | Model | Proj | Sess | Sent | Wrong-thread | Wrong-proj | New |
|---|---|---|---|---|---|---|---|
| dev 120 | Sonnet | 90% | 75% | 45% | 1 | 1 | 3/12 |
| dev 120 | Haiku | 86% | 67% | 44% | 3 | 2 | 2/12 |
| dev 120 | luna @0.8 / eq | 82% | 52% | 78% / 44% | 35 / 13 | 10 / 2 | 2/12 |
| realB 62 | Sonnet | 95% | 79% | 50% | 2 | 0 | 3/7 |
| realB 62 | Haiku | 84% | 56% | 50% | 4 | 1 | 2/7 |
| realB 62 | luna @0.8 / eq | 82% | 61% | 85% / 50% | 16 / 5 | 7 / 3 | 2/7 |

Paired bootstrap 95% CI, points (4,000 resamples over moments), pooled 182:

| Pair | Proj | Sess | Sent | Wrong-thread per message |
|---|---|---|---|---|
| Haiku − Sonnet @0.8 | −7 (−12, −2) | −13 (−19, −7) | −1 (−7, +5) | +2 (−1, +5) |
| luna − Sonnet @0.8 | −10 (−15, −5) | −21 (−28, −15) | +34 (+26, +42) | +26 (+20, +33) |
| luna − Sonnet, equal coverage | −10 (−15, −5) | −21 (−28, −15) | −1 (−8, +7) | +8 (+4, +13) |

realB alone: Haiku − Sonnet project −11 (−21, −3), session −23 (−34, −13); luna − Sonnet project −13 (−23, −3), session −18 (−29, −6).

## Latency
`claude -p` and `codex exec` are dominated by start-up. A trivial call took about 2.3 s (Haiku, `claude -p`) and 3.4 s (`codex exec --ephemeral --ignore-user-config`; 7.9 s with the user config and hooks loaded; low reasoning effort made no difference on the trivial call). So p50 around 5 s is roughly 2–3.5 s start-up plus 2–3 s of model. None of the three is near the 2 s gate through a CLI; the gate can only be tested with direct API calls. luna used about 5.8k tokens a call with the user config ignored (about 17k with it loaded).

## Against the gates
| Gate | Sonnet | Haiku | luna |
|---|---|---|---|
| wrong-thread ≤1%/msg | fails: 1.6% (3 of 182; 2 on realB) | fails: 3.8% | fails: 28% (9.9% at equal coverage) |
| 0 wrong-project sends | fails by one (1 on dev, 0 on realB) | fails (3) | fails (17; 5 at equal coverage) |
| send rate ≥50% | 47% (45% dev, 50% realB) | 46% | passes only by being overconfident |
| new work ≥10/19 | 6/19 (8/19 recorded) | 4/19 | 4/19 |
| p50 ≤2 s | no (CLI) | no (CLI) | no (CLI) |

## Recommendation
- **Sonnet decides.** It is the only candidate near the gates, and the gap is not close: Haiku is 7 points lower on project and 13 on session (both CIs exclude 0), and luna is 10 and 21 lower.
- **Haiku** costs a twelfth as much and is the fallback if cost matters more than the 1–2 extra wrong sends per 100 messages, but at a 0.8 bar its wrong-project sends (3) rule it out for a no-wrong-project gate unless its bar rises.
- **luna is not usable as the decider** with this board and schema: its confidence is badly calibrated (81% of messages above 0.8, 28% of messages wrongly sent). Even with its bar raised to 0.97 to match Sonnet's coverage it makes 6 times Sonnet's wrong sends (18 vs 3) with lower top-1. Whether a stricter prompt, low effort or a calibration layer fixes that wasn't tried (low effort was not run on the 182).
- No candidate meets the gates today. Sonnet misses on send rate (47%), new work (6/19) and the single wrong-project send; those are the same weaknesses as in runs C–F, so the work is on the board (the new-work option) and the bar, not the model.

## What is noise
- One sample per moment: the Sonnet rerun moved new work from 8 to 6 of 19 and wrong sends from 2 to 3 with the same board. Differences of 1–2 sends or 1–2 new-work cases between models mean nothing; at 3 vs 7 vs 51 wrong sends only luna's gap is clear.
- realB is 62 moments (7 new-work): its split rows are wide; the pooled rows and CIs are the ones to cite.
- Latency was measured with 4 calls in flight and includes CLI start-up; cost is Anthropic API-price from the CLI, and not reported by Codex.
- Not tested: T3's shell shape, waiting-request handling, steer vs queue, luna at low effort, a direct API call.
