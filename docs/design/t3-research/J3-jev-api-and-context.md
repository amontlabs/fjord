# J3: Jev's API, and the best routing context on T3 (2026-11-08)

Research only: no code changed. Paths: `SF/` = `Sources/Fjord/`, `T3:` = `~/code/research/t3code` (v0.1.7, `322f6544df`),
`OV2` = `T3:packages/contracts/src/orchestrationV2.ts`. TypeSafe docs were read from `https://docs.typesafe.ai/llms.txt`
and the pages it lists, plus `https://api.typesafe.ai/openapi.json` (copies are in the session scratchpad, `tsdocs/`).
The live probes used synthetic text only (scripts in the scratchpad, `probe/`). The key was read in-process and never printed.

## Part A: what Jev's API offers

### The whole surface
- **Two endpoints, nothing else:** `POST /v1/systemone` and `GET /v1/models` (openapi.json `paths`). There is no
  feedback, examples, fine-tune, few-shot or "learn from corrections" endpoint. The Models page says it outright: *"Jev is
  not fine-tuned or LoRA-adapted with customer data … the same weights serve every account. You shape its answers to your
  domain through the request."* Learning from corrections is therefore the client's job, in one of two ways:
  - Put past cases in the `state`. The "Simple memory system" cookbook does this with one extra Jev call per request that
    decides what to remember.
  - Fit a classical model on Jev's probabilities. The "Autoresearch" cookbook trains CatBoost on them. This is the same
    idea as the per-user fusion refit in `router-research.md` lead 1, which took late real wrong sends from 4.5% to 2.3%
    in a replay but was never built.
- **Request fields:** `model`, `state`, `questions`, `assets` (images). Two opt-in headers:
  - `TypeSafe-Danger-Zone-Long-Context` raises both context limits to 262k tokens. It is slower and less accurate.
  - `TypeSafe-Danger-Zone-Images`.
- **Response fields:** `model` (the versioned ID that answered), `answers`, and `usage{input_tokens, output_tokens}`.
- **There are no knobs:** no temperature, no seed, no top-k.

### Question types (openapi `components.schemas`)
| Type | Answer | Notes for routing |
|---|---|---|
| `choice` | `choice`, `confidence`, `probabilities` over **every** option | Up to 255 options (`criteria` maxProperties 255). Each option's criterion can be a string, null or any JSON (`primitives/advanced`), which is what `structuredChoice` uses. Probe: 40 options gave 40 probabilities, summing to 1, with 0.0 for the clear losers. |
| `noul` | `noul` = P(yes). There is **no confidence** field. | Use the value itself (docs suggest > 0.7 for yes, < 0.3 for no). |
| `score` | `score` (expected level), `confidence`, `legend`, and **`probabilities` per level** | 2 to 10 levels. `Jev.swift` parses `score` and `confidence` but drops the per-level `probabilities`, which the docs say is the number to act on when one level decides. |
| `box` | the edges of a box in an image | Jev 1.14 only; not relevant to routing. |

- **Confidence** is a function of the probability spread. For a choice with N options it is a monotone transform of the
  top probability (`confidence.md`: "(3 × p_max − 1)/2" for 3 options), so it adds no evidence of its own. The docs
  recommend putting the bar on **the probability of the option you will act on**, not on `confidence`.
  - `RouterProjectDecider.jevAsk` ranks by probability, which is right.
  - `RouterJev`'s older bars used confidence (not re-checked here).
- **Question IDs are not sent to the model** (`primitives.md`: "Question IDs are for your code"). Option names *are* read,
  so naming options by thread title, as Fjord does, is correct.
- **Several questions in one call:** the state is ingested once and every question is answered **independently, in
  parallel** (`concepts/state`, `models.md`).
  - Probe: one question cost 699 input tokens and 0.121 s; four questions on the same state cost 740 tokens and 0.133 s.
    Each extra question costs about 14 tokens and about 4 ms.
  - So "which project", "which thread", "is this a follow-up?" and "does any thread fit?" (the docs' *Companion Noul*
    pattern) can all go in one call almost for free.
  - What one call can't do is condition one answer on another: "thread given this project" needs a second call (~0.15 s
    more) or a code-side combination.
  - The docs' own ranking recipe (Skill suggestion, 194 options) is two calls: rank everything, then re-check the top 3
    with their full text plus one "does this fit?" noul each. `router-research.md` tried a second, narrower pass in
    round 1 and found it overconfident, but that was on the old boards.

### Models, limits, pricing, latency
- **Models:** `GET /v1/models` lists only the aliases `jev-latest` and `jev-preview`. Both point to `jev-1.14.0`
  (released 2026-10-14; the `jev-latest` alias row is dated 2026-10-22). `jev-1.13.0` is still callable.
  - Every response carries the versioned `model`, and the probes got `jev-1.14.0`.
  - Fjord sends `jev-latest` (`SF/Jev.swift`, `evals/router/jev.py`). The README's findings and the 0.7 bars were measured
    on 1.13; E4 (2026-11-08) ran on 1.14.
  - The docs advise pinning a versioned ID once thresholds are tuned. **Recommendation: send `jev-1.14.0`, log
    `response.model`.**
- **Limits:**
  - 64k tokens per request, and 32k for the state plus any one question.
  - No limit on how many questions a request holds.
  - 32 MiB body, 64 levels of nesting, finite numbers only.
  - Rate limits are set per organization, in tokens/s and requests/s; going over returns 429 with Retry-After.
  - 529 means overloaded (`api/errors`).
  - gzip and zstd bodies are accepted.
- **Pricing:** $0.042 per million input tokens; output is free. Long context costs the same per token. E4's board
  (~3.2k tokens) costs ≈ $0.00013 a call.
- **Latency against state size**, measured live on 1.14 (median of 3, new TLS connection each time):

  | Input tokens | 545 | 2.3k | 8.3k | 20.3k |
  |---|---|---|---|---|
  | Latency | 0.156 s | 0.149 s | 0.177 s | 0.248 s |

  - A 40-option choice (1.2k tokens) took 0.234 s.
  - It grows gently: a full 20k-token board stays at about 0.25 s. Size is not the constraint; distraction is (below).
- **Long text:**
  - The docs list *large state full of irrelevant detail* as failure mode 5, alongside literal reading, numbers,
    dates/times, indirection, contradictory instructions and option order (Jev leans to the first option).
  - Probe: one distinctive fact buried at the start or the end of 1.5k words of filler in each of 3 options, placed in the
    criteria or in the state, was found with p = 1.0 every time. That task is easy, so this only shows he finds a strong
    cue in long text; it doesn't show he weighs subtle evidence there.
  - Our own measurements agree. Round 2 found that richer per-option context (first ask, last 2 paragraphs) gave +4–5
    top-1 points, within noise, for +40% tokens. The assistant's turns carry the evidence, and your own words are weak
    (round 3).
- **Recency and dates:** Jev reads "finished 3m ago" poorly (`EXPLORE.md`; docs failure mode 3). A state field naming
  the last-finished session lifted top-1 from 37% to 57%, but Jev obeys it as an instruction (realB 32% wrong; rejected,
  `router-research.md`). Do recency in code, not in Jev's text.

### What this means for routing
- E4 stands: Jev isn't the decider on T3's board, at any bar. He orders the ask (his top 3 holds the right place
  81–83% of the time), and he might serve as an instant preview (unmeasured).
- Untested API features that could still help:
  - (a) A companion noul, "is this new work none of these threads is doing?", in the same call, as a new-work feature.
    New work is the gate everyone fails (6–8 of 19).
  - (b) Scores' per-level probabilities.
  - (c) Pinning the model version.
  - (d) A client-side memory of your corrections in the state. Note that round 1 found "examples of past routings had no
    measurable effect"; the per-user fusion is the more promising form.
- None of these changes Sonnet's numbers. The gains that matter are in the board (Part B).

## Part B: every routing signal on T3, and what it costs live

### What the decider reads today
- **`Store.deciderBoard`** (`SF/DeciderBoardSource.swift:44-103`) builds each thread from the shell:
  - title;
  - flag (waiting / running / finished);
  - minutes idle from `AgentThread.lastActivity`;
  - `said` = `latestVisibleMessage` when its role is assistant;
  - `youSaid` = `latestVisibleMessage` when its role is user, else a read;
  - `step` = `threadWork.todo.active ?? threadWork.text`, for running threads only;
  - `waiting` = the held request's text, else words from the shell.
- **Projects:** non-archived ones, each with a purpose from `routerBriefs.docs[p].purpose` and a repo slug.
- **The board text** (`SF/DeciderBoard.swift:131-170`):
  - each thread line has its last message (last 600 chars), "you last said there" (200), current step (200) and waiting
    request (300);
  - each project has a "new in" line with its purpose and 3 latest titles;
  - candidates: all live threads, plus the 3 latest finished per project within 12 h, 20 at most.
- **Sonnet** reads that text (`RouterProjectDecider.sonnetPrompt`, `SF/RouterProjectDecide.swift:288`).
- **Jev** (`jevRequest`, `:183-219`) gets:
  - the same lines as each thread option's `now`;
  - `{kind, project, about, its threads}` per new-thread option;
  - the 4 intents;
  - the state `{message, tagged?, note?}`.
- **"You last said there"** for candidates without it comes from `youSaidReads` (`DeciderBoardSource.swift:108-138`):
  - it reads the held projection, else one `subscribeThread` until its snapshot arrives;
  - this sits **on the decision path, up to 1.2 s**, before Sonnet is called (`SF/RouterDispatcher.swift:836`).
- Nothing else reaches the decider: no branch, PR, goal, files, first ask, search hits, what you looked at, or your past
  routings.

### Gaps found in the current board
1. **"N minutes ago" is not activity time.** `lastActivity = shell.updatedAt` (`SF/AgentThread.swift:73`). T3 bumps
   `updatedAt` on settle, unsettle, snooze, unsnooze, pin, unpin, unarchive and auto-settle changes
   (`T3:apps/server/src/orchestration-v2/Orchestrator.ts:3540-3650`).
   - So a thread you just pinned or woke reads "0m ago", sorts first, and survives the 12 h cut.
   - Visits don't bump it (`Orchestrator.ts:2932-2934`).
   - R1 asked for max(`latestRunCompletedAt`, `latestUserAuthoredMessageAt`). Both are on the shell, and Fjord already
     decodes `latestRunCompletedAt`.
   - Recency is the strongest routing signal ever measured: the latest finished session was the target 60% of the time,
     and one of the last two 84% (`EXPLORE.md`).
2. **No assistant text when your message is the latest one.** When the latest visible message is yours (a thread you
   just sent to, or one with a queued message), `said` is empty. `summary` is never filled by `deciderBoard`, so the
   thread shows no "last message" at all.
   - That is exactly the thread a follow-up most often goes to.
   - The last assistant message is in the projection that the youSaid read already fetches, or in a held one.
3. **Imported threads** (`historyOrigin: "v1_import"`; 439 of 455, R1) carry the import time as message `createdAt`.
   Any age derived from message times is wrong for them. `latestRunCompletedAt` is null until they run again on T3.
   Fall back to the import-safe fields and treat "no run on T3" as old.
4. **The youSaid read pulls the whole projection.** `T3Client.subscribeThread` sends only `threadId`
   (`SF/T3Client.swift:241`).
   - T3 offers `acceptBoundedSnapshot` (`OV2:3773-3783`), which caps the snapshot at the last 10 user turns, 75 items and
     1 MiB (`T3:apps/server/src/orchestration-v2/threadHistoryPaging.ts:15-20`).
   - `getThreadProjection` (`OV2:3669`) is a one-shot read.
   - Either way, the read belongs off the decision path: prefetch it when the shell row changes, and cache it by
     thread@`latestVisibleMessage.updatedAt`.

### Per-thread signals: where they come from, what they cost, how fresh they are
"Shell" means the row is already held from `subscribeShell` (`OV2:2072-2151`), so the signal costs nothing at decision time
and is live within one event. "Read" means a `subscribeThread` snapshot or a `getThreadProjection` per thread: a
WebSocket round trip on the local server plus decoding. That wasn't timed here; Fjord's own budget for it is 1.2 s.

| Signal | Where | Cost | Freshness / quirks | Today |
|---|---|---|---|---|
| Title | shell `title` | free | live; `titleRegeneration` marks a rename in flight | yes (80) |
| Project, repo | shell `projectId`; project `repositoryIdentity`, `workspaceRoot` (`T3:packages/contracts/src/orchestrationProject.ts:8-25`) | free | live | yes |
| Branch, worktree | shell `branch`, `worktreePath` | free | live; `getWorktreeThreadIds` lists the threads sharing a worktree | no |
| PRs | shell `pullRequests[]`: number, url, `snapshot{state,title,headBranch,baseBranch,isDraft,checksState,reviewDecision,additions,deletions}` (`T3:packages/contracts/src/threadPullRequest.ts:37-120`); `linkedPullRequest`, `branchPullRequest` | free | `snapshot.syncedAt` | no (decoded in `T3PullRequest`) |
| Running state | shell `status`, `activityRunStatus`, `activeRunId`, `latestRunStopRequested`, `blockedOnThreadWait` | free | exact | yes (flag) |
| Pending request | shell `pendingRuntimeRequest{kind,blocking}`, `hasActionableProposedPlan`; full text from the read (`approval_request`, `user_input_request`, `proposed_plan` items, `OV2:1635-1700`) | free (kind) / read (text) | exact | yes |
| Current step | `todo_list.steps` and the last live tool item from the read (`ThreadWork`, `SF/AgentThread.swift:136-170`) | read (held only for watched threads) | live while subscribed | yes, running only |
| Goal | shell `goal{objective,status,lastCheck}` (`OV2:1063-1071`) | free | live; only when the provider set one | no |
| Latest message | shell `latestVisibleMessage{role,text,updatedAt}` | free | live; full text, either role | yes (last 600), assistant only |
| Your last message | shell when it's the latest; else the read (`T3Store.lastUserMessage`) | free / read | cache by thread@time | yes |
| When you last wrote | shell `latestUserAuthoredMessageAt` (excludes wakes and agent sends) | free | import time for imported threads | no |
| First ask / older turns | the read (`firstUserMessage`, `messages[]`, bounded: last 10 user turns) | read | stable (first ask never changes) | no |
| Files touched, diffs | `file_change{fileName,+/-}` items, `checkpoint.files` (`OV2:1657-1712`); `getTurnDiff`, `getFullThreadDiff` (`OV2:4213-4220`) | read; diff RPCs run git | per turn | no |
| Compaction / handoff summaries | `compaction.summary`, `handoff.summary` items (`OV2:1736-1760`) | read | when present, a ready-made thread summary | no |
| Background work | shell `pendingBackgroundTasks[]` (subagents, commands, monitors) | free | live | no (shown in the UI) |
| Subagents, forks | shell `lineage{parentThreadId, relationshipToParent, sideChat}`; `getThreadFamily` | free | subagents and side chats are excluded (right) | excluded |
| Delegated / agent-made | shell `delegatedFrom{threadId,title}`, `createdBy` (user/agent/system), `creationSource`, `linkOrigin` | free | set once | no |
| What you looked at | shell `lastVisitedAt` (shared with T3's app and phone), `opens{openedAt, score}` (`OV2:429-442`) | free | `thread.visit` doesn't bump `updatedAt` | no |
| Settled / snoozed / pinned | shell `settledAt`, `snoozedUntil`, `pinnedAt`, `archivedAt` | free | these **bump `updatedAt`** (gap 1) | filters only |
| Errors / limits | shell `lastError`, `lastErrorClass`, `usageLimitResetAt`, `limitRecovery` | free | live | no |
| Model / provider | shell `modelSelection`, `providerInstanceId`, `runtimeMode` | free | — | dropped (R1) |
| Item counts | shell `itemCount`, `visibleItemCount` | free | — | no |
| Lexical match | `orchestration.searchThreads{query ≤200, limit ≤50, projectIds?, olderSettledBefore?}` returns `{threadId, source user/assistant, snippet ≤240, quality, hits}` (`T3:packages/contracts/src/threadSearch.ts:20-50`); `T3Store.search` already wraps it | 1 RPC per decision (server SQLite, substring scoring; latency not measured) | covers settled threads past the 12 h cut too | no (used only by the Router's own runs) |

### Fjord-side signals
| Signal | Where | Cost | Notes |
|---|---|---|---|
| Thread you clicked or tagged | `RouterBriefs.mentioned` / `focused` (`SF/RouterBriefs.swift:150-160`) → `RouterContext.replyTo`, `threadTargets` | free | Already a hard route (`threadTag`), not a hint. |
| Thread under the pointer | `RouterBriefs.hoveredTarget` | free | Not passed to the decider. A weak hint at best. |
| Last thread your words went to | `RouterDecision.decision.targetID` and `confirmed` in the history (`SF/RouterDecisions.swift:20-45`) | free | Round 1: a *global* list of your last 10 messages hurt (61% against 69%) and sent "yes" to the last-messaged session. Only per-thread wording ("you sent here 3m ago") is safe to try. |
| Corrections | `DeciderLog` outcomes `picked`, `sent_elsewhere`, `reverted` (`SF/DeciderLog.swift:58-64`) | free | The future benchmark (R1: ~200 moments). As context: per-user fusion or a few examples, after the log exists. |
| Brief per project | `BriefDoc{purpose, now[], needsYou[], decisions[], looseEnds[]}` (`SF/RouterBriefDoc.swift:93-113`), from Haiku | free (already generated) | Purpose already used. The `now` lines are per-project prose, not per-thread summaries, and lag by one brief run. |
| Project purposes | `routerBriefs.docs[p].purpose` | free | Used. E3's purposes were generated from titles; the README purpose is Fjord's own. |

## Ranked: the context additions most likely to help
Sonnet is the decider (E3, E4), so this ranking is for the board. Jev reads the same `now` lines, so his ask ordering
moves with it. Every item is still to be measured on the 182 moments where the data exists, and otherwise on the live
`DeciderLog`.

1. **Real activity time.** Age and order threads by max(`latestRunCompletedAt`, `latestUserAuthoredMessageAt`,
   `latestVisibleMessage.updatedAt`), not `updatedAt`, and treat imported threads with no T3 run as old.
   - Cost: free (shell).
   - Why: it fixes the candidate order, the 12 h cut and the "Nm ago" ages on a board where recency is the strongest
     signal. It is a bug fix more than an experiment.
2. **The last assistant message, always.** When the latest visible message is yours, show the previous assistant
   message (and a compaction or handoff summary when there is one) instead of nothing.
   - Cost: one bounded read per such thread, prefetched on shell change, so nothing on the decision path.
3. **Take the youSaid read off the decision path.** Prefetch "you last said there" (and 2) in the background with
   `acceptBoundedSnapshot` or `getThreadProjection`, cached by thread@`latestVisibleMessage.updatedAt`.
   - Cost: the same reads, moved earlier. It takes up to 1.2 s off p50 against the 2 s gate.
4. **Branch and PRs on the thread line** (number, title, state). For a Triage action, mark the thread whose
   `pullRequests` or branch is the action's item: that answers "a session already has this item" in code before
   `actionFollowUpBar` is consulted.
   - Cost: free (shell).
   - R1 recommended it; it is untested because the 182 moments have no PRs.
5. **The first ask** (the thread's task, first 200–300 chars) and its **goal objective** when set. The first ask is what
   tells new work from a follow-up, and new work fails every gate (6–8 of 19).
   - Cost: one read per thread, cached forever (the first ask never changes); the goal is free.
   - "Rich context" gave Haiku +14 top-1 points in `router-redesign.md`.
6. **Lexical hits from `searchThreads`** on the message's distinctive words: a "matches your words: <snippet>" line on
   candidates, and a way to bring in a settled thread outside the 20.
   - Cost: 1 RPC per decision, run while the board renders; latency to measure.
   - BM25 alone named the follow-up 54% of the time in round 3 (Jev 40–48%). T3's search scores substrings rather than
     BM25, so it may score lower.
7. **Per-thread "you opened it / sent here N min ago"** from `lastVisitedAt` / `opens.openedAt` and Fjord's last routed
   target.
   - Cost: free.
   - Keep it on the thread's own line, never as a global "latest" pointer, which both models have obeyed as an
     instruction before. Measure it on live logs only.
8. **Files touched** (the names in the latest turn's `file_change` items or checkpoint) on running and recently
   finished threads, for "the button in X" messages.
   - Cost: the same read as 2/3. Gate it on eval, because it adds tokens.
9. **Learning from corrections:** once the `DeciderLog` holds about 200 moments, try a per-user calibration or bar.
   There is no TypeSafe endpoint for it, and examples in the prompt had no effect in round 1.
   - Cost: free locally.

Not worth adding (R1, and Jev's failure modes): model, runtime mode, tags, worktree path, token use, full todo lists,
diffs' content, the brief's `now` prose (it lags, and it is model-written about the same threads), and a global history of
your messages.
