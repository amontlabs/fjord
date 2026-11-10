# Brief rebuild: settled threads ignored, stateless briefs (2026-11-10)

Owner: "When I settle a thread in T3 I consider it done; the router shouldn't keep mentioning it." Plus the 2026-11-09 audit:
Silo's brief said PRs #95/#97/#103 "wait for your merge" 3 to 19 h after they merged, because every call starts from the
previous brief, working threads send no text, nothing checks PR state, and the lead is built from project prose.
Design by Fable (2026-11-10). Implementation status at the bottom.

## Design

**Scope.** One predicate shared by brief and decider: `inPlay = !snoozed && (!settled || running || waitsForYou)`. A settled,
failed, unseen thread is out (T3 unsettles on a real new failure). Done-unsettled persists until settled: under 24 h
(`BriefLog.recentWindow`) it may appear in prose; 24 h to 7 days it is only a deterministic "N finished, not settled" row;
over 7 days off the board. Paused threads (never ran) only for 24 h.

**Stateless brief.** The project call no longer gets "Current brief:". Its input is the board alone: per in-play thread its
id, title, status, last run end, latest reply (tail-clipped, with its time; also for working threads), PRs with state, the
request text and options; then recent sends. Model output shrinks to `now`, `needs_you`, `purpose` (`decisions` and
`loose_ends` go: never rendered, only stale memory). Calls are triggered by a per-project trigger key (thread set, status,
run-end time, request ids, PR states, last send time; not reply text), and skipped when the key equals the one the stored
prose was written from. Rules: "Threads is everything that exists; a merged or closed PR is not waiting on anyone."

**Settle.** `apply` drops instantly every `now` line and model entry that tags an off-board thread (whole lines, never
spans); the changed key then causes one rebuild; bursts coalesce through `running`/`dirty`. `entries(model:board:)`
requires the thread on the board (no stranded exception). `checked` accepts board ids only.

**Lead.** Built from the thread facts plus the projects' validated `needs_you` entries, never from `now` prose.
`for_you`/`worth_a_look` become line arrays (tolerant decoder) so the same prune applies. `refresh` marks it dirty when
`leadSignature` changes.

**PR state.** T3's `projection_thread_pull_requests` was empty in the 2026-11-09 copy, so T3 can't be trusted for it. PRs
come from T3 links plus GitHub PR URLs in thread replies, refreshed through `GitHubClient` (only those last seen open); state
goes on the board and in the trigger key. The view shows the state on PR links. No text checker over prose.

**Speed/UI.** Project calls in parallel (cap 4), then the lead; progress (done, total); a second Rewrite press during a run
queues one more pass. Header `BriefUpdated` shows "Rewriting… 3/8"; otherwise when facts were last checked (a skipped call
counts). The separate "Rewriting…" scroll line (RouterBriefView.swift:30) goes.

**Page.** Finished-unsettled tier with a count row for the older ones and Settle as the primary action; `told` only dims.

**Decider.** Settled threads stay routable (Archive, BM25). `retrievalBlock` labels hits `settled`; `nowBlock` adds
"Settled since the snapshot: ids"; role rule: pick a settled thread only when the message names it, reopens it or continues
its exact deliverable; topic overlap alone is new work, never `answers_its_question`/`reacts_to_its_result`. Threads the
brief tags are always in Live. "Each project's newest" is bounded by the 7-day backstop.

## Commits

| # | Piece | Track |
|---|---|---|
| 1 | Prune off-board mentions in `apply`; `entries` needs the board; `refresh` dirties the lead | engine |
| 2 | `AgentThread.inPlay`; `listed` tiers + paused rule; `Store.deciderBoard` uses it | scope |
| 3 | Board facts: reply + time for every thread, PRs with state, request text/options | engine |
| 4 | Stateless call: new context/schema/rules, board-only `checked`, trigger key replaces cursor | engine |
| 5 | Lead from facts + entries, line arrays | engine |
| 6 | Parallel project calls, progress, queued second press | speed |
| 7 | Header "Rewriting… n/m", facts-checked time, drop scroll line | speed |
| 8 | Page: finished-unsettled tier, Settle, `told` dims, PR state on links | page |
| 9 | Decider: settled labels, role rule, brief-tagged threads in Live | decider |
| 10 | PR state refresh via `GitHubClient` + PR URLs from replies | pr |
| 11 | Cleanup: drop decisions/looseEnds paths and the engine's log-item reads (BriefLog keeps `seen` for banners) | engine |

Regression test: replay the 2026-11-09 Silo inputs (merged #95/#97/#103) and check no line says they wait.

## Status

- Done: 1 (0bd01ac5), 2 (b8c3e62b), 3 (f7736d51), 4 (a381bda0), 5 (2163624a), 9 (c2399450), 10 fetcher (0b134485), 11 (6c07ffcd).
- Done too: 6 (c03a67dc), 7 (b2859b3b), 10 wiring (6534f931), 8 (62ee68d3); fixes 77a90ee1 (header helper misplaced by
  partial staging), test updates, demo prose 77d0e613. Full suite: 1320 tests, all pass but
  `DeciderContextTests.theArchiveIsFrozenForTheDayAndOnDisk`, which waits on an async disk write and passes alone (flaky
  under load, not touched by this work).
- Eval on real 2026-11-09 boards (~110 Haiku calls): 0 settled-thread mentions, 0 claims against replies or PR states;
  lead and first-person fixes in 10dd414f; dump helper bd464457 (`FJORD_BRIEF_EVAL_DIR`); only your own words count as
  sent (c4b9b9cd). Built from a clean export and installed 2026-11-10.
- Open: the lead sees only a reply's last 600 characters; finished threads that ask get kind `request` about half the
  time (the UI treats it like `question`).
