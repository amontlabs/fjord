# E2: which model writes Fjord's briefs (Haiku vs Codex gpt-6-luna)

Status: research, 2026-11-06. No Swift touched. Raw inputs, outputs and judgments (real session text, redacted) stay outside the repo in the session scratchpad (`.../scratchpad/briefs/`).

## What was compared

The three calls of `RouterBriefEngine.swift`: project brief (`rules` + `BriefDoc.schema`, lines 248-270), purpose (line 559) and general lead (`leadRules` + `leadSchema`). The prompts, schemas, default style line and input rendering (`context`, `leadContext`) were reproduced verbatim in Python. Haiku runs as Fjord runs it (`claude -p --model claude-haiku-5-5 --tools "" --setting-sources "" --strict-mcp-config --no-session-persistence --json-schema`). Luna runs as `codex exec -m gpt-6-luna --sandbox read-only --output-schema`, rules prepended to the input (codex has no system-prompt flag), in an empty cwd; "luna" = the owner's config default (reasoning high), "luna-low" = `-c model_reasoning_effort=low`.

Inputs (all redacted with `evals/router/real/boards.py redact`):
- 25 project snapshots from the owner's real T3 threads (461 threads, 7 projects: silo 4, fjord 5, surplace 3, sic 4, lastdrop 4, lcu 4, No project 1). A snapshot = threads of one project active in the 36 h before an anchor, items cut at the anchor, 1 to 8 threads (5 quiet single-thread cases, the rest busy). Rendered as Fjord does: `Threads:` list, then `thread` items (title + first real user message), the last three `message` rows, and a `status needs_you` item when a thread's last reply asks something. Thread statuses are a heuristic (last item user = working; reply ends in a question = needs_you; else done), since the real Board statuses do not exist in T3 data.
- 7 purpose inputs (the project's instructions file, or its first user goals).
- 6 leads, each over 3-5 projects, built from Haiku's own project briefs (the same lead input for all three models).
- Limits: no prior brief in "Current brief" (every case is a first write, so the "leave out what the brief covers" behaviour is untested); busy cases are busier than a real incremental batch; links appear in only 14 of 25 inputs.

Judging: Claude Opus, pairwise, order randomized, rubric from the brief's own rules plus owner taste (accuracy to input first, rule-following, concision, needs-you first, useful highlights). 114 judgments. Plus a mechanical check and 5 hand-read pairs.

## Results

| | Haiku | luna | luna-low |
|---|---|---|---|
| Schema-valid (38 calls each) | 38/38 | 38/38 | 38/38 |
| Project brief latency, 4 parallel: mean / p50 / max | 19.6 / 20.5 / 34.8 s | 17.3 / 16.2 / 36.5 s | 7.8 / 7.1 / 26.4 s |
| Same, run alone (4 cases, mean) | 15.4 s | 17.1 s | 6.1 s |
| Lead latency mean | 8.9 s | 11.9 s | 5.8 s |
| Purpose latency mean | 4.8 s | 5.0 s | 4.0 s |
| `now` length (words, mean) | 31 | 19 | 22 |
| Loose ends per brief | 4.7 | 1.7 | 1.7 |
| Links kept on words (14 cases had URLs) | 5 | 2 | 2 |
| Empty `now` | 0 | 2 | 1 |

Mechanical check (all briefs and leads): zero hallucinated thread ids, zero invented numbers, zero invented URLs, no ids outside tags, no markdown, no `now` over 40 words, needs-you recall 100% against the heuristic statuses, for all three. `needs_you` extras (entries for threads not flagged): haiku 0.56, luna 0.20, luna-low 0.32 per brief. Opus flagged unsupported claims (mostly inference in loose ends and decisions) 123 times for Haiku, 58 for luna, 100 for luna-low across 50 brief comparisons each.

Pairwise wins (Opus; ties omitted):

| Pair | Project briefs | Leads | Purposes |
|---|---|---|---|
| Haiku vs luna | 15 : 10 | 4 : 2 | 1 : 6 (luna) |
| Haiku vs luna-low | 19 : 6 | 5 : 1 | 1 : 6 (luna-low) |
| luna vs luna-low | 14 : 10 | 5 : 1 | 2 : 5 (luna-low) |

(One brief judgment errored and is excluded.)

## What the pairs show (5 hand-read, agree with the judge)

- Luna is terser and plainer, and it pads less: it leaves out the long tail of loose ends Haiku writes, and it states decisions more accurately in two cases. Haiku's loose ends are often "unverified" gaps or already-closed items, which the rules forbid ("a missing reason isn't a loose end").
- Luna under-reports: in one lcu case it left a thread that waited on the owner (AGENTS.md permission) out of `now` and `needs_you` entirely; in one fjord case it reused a thread's tag for an unrelated release and dropped the release link. It also returns an empty `now` for a quiet single-thread project that just finished (2 of 5 quiet cases), where Haiku says something. For the owner's "never miss what needs me" this is the worse failure.
- Luna-low is luna with shorter output and fewer details: the same style, a little less accurate, and it loses to Haiku clearly.
- Purpose is trivial; luna and luna-low win it by being a more natural single line.

## Latency

Haiku through `claude -p` is not fast here: 9-24 s alone, up to 35 s under load, so two of 25 Haiku briefs exceeded Fjord's 30 s timeout in the parallel run (luna: 2, luna-low: 0). Cause is output length (decisions and loose ends), not network. Luna-low is about 2.5x faster (6 s alone). The lead is 6-12 s either way.

## Recommendation

Keep Haiku for the project brief and the lead. Luna does not beat it on the brief that matters (Haiku wins 15:10, and 19:6 against luna-low), and its concision is bought with dropped needs-you items, dropped links and empty briefs on quiet projects, which hurts the owner more than extra loose ends do. Do not switch to luna-low for quality; use it only if brief latency becomes the problem, and then only with a guard: reject an empty `now` when a thread is in the log, and fall back to Haiku.

Cheaper win, not tested here: Haiku's weakness is verbosity (4.7 loose ends, 123 flagged inferences). Tightening the loose-ends rule in the prompt, or capping them, should capture most of luna's advantage and shorten Haiku's calls and timeouts. Purpose could move to luna-low (6 of 7 wins) but the call is a one-liner per project and not worth a second provider.

Caveats: first-write snapshots only; heuristic statuses; one Opus judge; n=25 briefs, so a 15:10 split is a lean, not a certainty.
