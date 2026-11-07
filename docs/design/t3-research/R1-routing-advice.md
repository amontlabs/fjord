# Routing on T3: Fable's design advice (2026-11-06)

Fable read the map (§12 and the decisions block), router-redesign.md "Routing on real moments" A–F, router-research.md,
evals/router/README.md, poc/projects/eval/manager_eval.py, T3's shell contract and the live statev2.sqlite. This file is
its answer, summarized faithfully.

## The fact that changes the benchmark plan
T3 holds 455 threads: 439 were imported (actor `system`), 4 were created by the user and 12 by agents. Imported messages
carry the time of the import as `createdAt` (all 2026-11-06T11:51), not when they were written. So the T3 database can't
rebuild "the board as it stood then", and there's no native traffic yet. A T3-native moment set has to grow from logs of
Fjord's live decisions.

## A. Candidates and context
- **Candidates:**
  - every thread with `pendingRuntimeRequest`, `hasActionableProposedPlan` or a live status;
  - the latest finished listed threads per project, ordered by max(`latestRunCompletedAt`, `latestUserAuthoredMessageAt`), cut at 12 h;
  - one "new in <project>" per project;
  - Fjord itself.
- **Excluded:** archived, settled, snoozed and unlisted (subagent) threads. This gives 10–25 options; cap them at 20 plus the waiting ones.
- **Per candidate, in order:**
  1. title;
  2. status and age;
  3. `latestVisibleMessage` (last ~600 chars);
  4. your last message there (read on demand, cached by thread@updatedAt);
  5. the current todo or plan step;
  6. branch and PR number/state;
  7. any waiting request, rendered as text.
- **Dropped:** model, runtimeMode, tags, worktree path, token usage and full todo lists.
- **Waiting requests:**
  - A waiting request folds into its thread's option.
  - After the decider picks that thread, a deterministic step maps the message onto the request.
  - A question gets an option picked by Jev.
  - An approval never infers yes: typed words decline with feedback.
  - A plan gets "No" plus your words, as a normal message.

## B. New work
- Use one call, not two stages. Project confidence and thread confidence stay separate in the schema.
- Fix new work with:
  - (a) a "new in X" option that has content: the project's purpose and its last 3 thread titles;
  - (b) the focus sentence;
  - (c) when the project is sure and the thread isn't, start a new thread in that project; never ask.
- A new thread can be reverted by archiving it, so a new-vs-existing mistake inside the right project costs an ask, not a wrong send.

## C. Steer by default
- A wrong send to a running thread now interrupts it, so the send bar for running targets should be higher than for idle ones.
- The live pick reads "steer <thread> (running)" in its own colour, and ⌥Return queues instead.
- Measure wrong sends to running threads on their own.

## D. Benchmark
- The 182 Claude-transcript moments remain valid for ranking. Rebuild the board renderer so it emits T3's shell shape, so the eval and the app share one function.
- They can't measure waiting-request handling across providers, Codex threads, steer vs queue, or Fjord's own traffic. Log every live decision (board, pick, confidence, latency, what you did), and after about 200 moments that set becomes the headline.
- **Gates to ship:**
  - wrong-thread sends per message ≤ 1%;
  - 0 wrong-project sends;
  - send rate ≥ 50%;
  - new work right ≥ 10 of 19;
  - p50 latency ≤ 2 s with a direct API call (CLI start-up is most of the current 5–6 s).
- **Comparing models:**
  - same moments, board and schema, with paired bootstrap;
  - compare at equal coverage, with each model's bar set for the same send rate;
  - Haiku and luna against Sonnet;
  - keep Jev-first only if it still has zero wrong answers.

## E. Map issues
1. §12 assumed T3 data yields moments. It can't: live logging is the source.
2. Request payloads in the shell (§7.2) matter for routing. Waiting threads are usually under 5, so reading them on demand is enough.
3. `lastVisitedAt` is a new recency signal ("you last looked here"). Measure it before trusting it.
4. A message about a delegated subagent's task routes to its parent (`delegatedFrom`).
5. Test T3's thread search in place of porting RouterLexical.
