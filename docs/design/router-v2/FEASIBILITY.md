# Router v2: can it all run on real data? (2026-11-12)

Audit of [DESIGN.md](DESIGN.md), Round 2 of [CONTEXT.md](CONTEXT.md) and the demo video against the real sources.

**Answer: yes.** Nothing is impossible and nothing needs a change in T3. About half works with code Fjord already has;
the rest is small work in Fjord. Eight things in the demo look or time differently on real data (gaps below).

How it was checked:
- T3 Code v0.1.7 source (`~/code/research/t3code`, tag `v0.1.7`; the installed server is 0.1.7).
- Read-only queries on the real T3 database, 7 to 12 Nov: 1,659 finished runs in listed threads, 70,041 turn items.
- Four live `claude -p` calls on made-up text (Claude Code 2.1.322).
- The storyboard, the demo script and five frames of `router-v2.mp4` (they match the storyboard).

Paths: `SF/` = `Sources/Fjord/`, `T3:` = the t3code repo, `OV2` = `T3:packages/contracts/src/orchestrationV2.ts`.

## Measured

| What | Result |
|---|---|
| T3 event to Fjord | T3 batches shell and thread events for 50 ms (`T3:apps/server/src/ws.ts:1199`, `ThreadLiveEventCoalescer.ts:18`), then pushes on a local socket. Under 0.1 s. |
| Haiku verdict through `claude -p`, streamed | Process ready 0.2 s; first token 1.4 s; `state` field 1.85 s; whole answer 2.6 s. Fields arrive in schema order as `input_json_delta` chunks. |
| Same, on a process started 4 s ahead | `state` 1.55 s, whole answer 2.4 s. A warm spare saves only 0.3 s. |
| Verdict cost | $0.0002 to $0.0005 per call (1,600 tokens in, 330 out). About $0.001 with a long reply. |
| Volume | 256 to 364 run ends a day in 10 to 40 threads. So 300 to 400 verdicts a day: $0.15 to $0.40 a day at API prices, taken from the subscription. |
| Run ends followed by a new run in the same thread | 15% within 5 s, 25% within 30 s, 50% within 2 min (wakes after background work). |
| Settings parse, "silo: write the changelog for 0.4 (use opus medium, plan first, ask me before running commands)" | Sonnet (effort high): right in 2.5 s, $0.008. Haiku: right in 2.3 s, $0.0005, but it rewrote the message. |
| PR merge | A real one today: merged 12:36:45, in T3's shell 12:37:05. |
| Requests and stops | 24 requests in the whole database (17 permissions, 7 questions) and 1 plan. Since 7 Nov: 19 failed runs, 3 interrupted. |

## Every capability

Verdicts: **works** (code exists) · **small** (small work in Fjord) · **T3 change** · **not possible**.

### Events from T3

| Capability | Real source | Verdict | Notes |
|---|---|---|---|
| Any change reaches the page at once | `orchestration.subscribeShell`: whole thread rows on every change (`SF/T3Client.swift:237`, `SF/T3Store.swift:153-161`) | works | Fjord holds shell changes while the window morph plays (`SF/Threads.swift:408-421`). |
| Turn ends: Working to Done | Shell `status`, `latestRunCompletedAt`, `pendingBackgroundTasks` (`SF/AgentThread.swift:66-81`, `SF/T3BriefSource.swift:35-40`) | works | A turn that left background work stays Working, as it should. |
| New question, form, permission, plan | Shell `pendingRuntimeRequest{id, kind, createdAt, blocking}`, `hasActionableProposedPlan` (`SF/T3Types.swift:230-241, 302`) | works | The words and options are only in the thread's own stream (`SF/T3Types.swift:579-580`). Fjord already holds that stream for every working thread (`SF/Threads.swift:376-378`), so the card is complete in the same 50 ms. |
| Run starts | Shell `status`, `activityRunStatus` | works | The run's age needs `activityRunStartedAt` (`OV2:2098`): one field Fjord doesn't decode yet. |
| Failure, interrupt | Shell `status`, `lastError`, `lastErrorClass` (`OV2:2104-2105`, `SF/AgentThread.swift:112-115`) | works | See gap 2: what "failed" means in T3. |
| Usage limit that resumes by itself | Shell `lastErrorClass: usage_limit`, `limitRecovery{autoResume, resetAt}` (`SF/AgentThread.swift:113-115`) | works | |
| Settled, snoozed, archived in T3 | Shell `settledAt`, `snoozedUntil`; `thread.removed` on archive (`SF/T3Store.swift:32-34`) | works | |
| New thread, unsettled, snooze over | Shell `thread.updated` with a new or changed row; subagents filtered (`SF/T3Types.swift:227`) | works | |
| Renamed in T3 | Shell `title` | works | |
| PR opens, merges, closes | Shell `pullRequests[].snapshot.state` (`SF/T3Types.swift:254-268`). T3 re-reads each linked PR every minute while it was touched in the last 30 min, every 5 min after, and at once after the agent's own merge command (`T3:apps/server/src/orchestration-v2/PullRequestSyncReactor.ts:41-46, 730`) | small | Pushed for PRs T3 has linked (the ones the agent creates; 18 threads have one). A PR only named in a reply goes through Fjord's GitHub check, which has no timer and runs only when a board is rebuilt (`SF/PullRequestStates.swift:63-65`, `SF/RouterBriefs.swift:401-419`). Gap 6. Never "instant": up to a minute. |
| T3 unreachable, back again | `connectionStates` (`SF/T3Client.swift:226`) | works | |

### The model's part

| Capability | Real source | Verdict | Notes |
|---|---|---|---|
| One verdict per thread, rerun only when it changes | Fingerprint from the shell row alone: `latestRunId`, `pendingRuntimeRequest.id`, PR states, `latestUserAuthoredMessageAt` | small | New engine code. It replaces the project call and the lead. |
| The verdict streams into the line | `claude -p --output-format stream-json --verbose --include-partial-messages --json-schema …` | small | `ClaudePrint` waits for the whole answer today (`SF/ClaudePrint.swift:38-64`). It needs a line reader and a reader of partial JSON. `state` lands first because the schema puts it first. |
| Short name, once | Same call | small | T3 also writes its own title (`generateTitle`); the page name is Fjord's. |
| "Left you a step", with options | Same call | small | The options send their text as a normal message. Needs the eval DESIGN.md §7 asks for. |
| Fjord's logo while the model works | UI | works | |

### What a line and a card show

| Capability | Real source | Verdict | Notes |
|---|---|---|---|
| Last lines (the agent's last message) | Not in the shell: T3 0.1.7 always sends `latestVisibleMessage: null` (`T3:apps/server/src/orchestration-v2/ProjectionStore.ts:1625, 1899`). From the thread stream (`SF/T3Store.swift:228-232`) or one bounded read (`SF/T3Store.swift:251`) | works | Working and waiting threads: already held. A Done thread: one read at its turn end (Fjord does it today, `SF/DeciderBoardSource.swift:141`). The design's skeleton covers the wait. |
| Reply growing live, with a caret | `message.updated` and `turn-item.updated` with `streaming: true` (`SF/T3Types.swift:482, 606`) | works | 50 ms batches. |
| Working line: what it does now | `ThreadWork` (`SF/AgentThread.swift:194-234`): the running item | works, reads differently | Gap 1. |
| To-do steps in the Working card | `todo_list` items (`SF/T3Types.swift:578`, `SF/AgentThread.swift:207-211`) | small (a T3 setting) | Gap 1: no to-do list exists in the real data. |
| Done: PR badge and state | As "PR opens" above | small | |
| Done: "4 files +96 −212" | Per turn: `checkpoints[].files{additions, deletions}` and `filesTotal` (`OV2:1372-1402`), in the thread stream, kept raw today (`SF/T3Store.swift:85`). Per PR: `snapshot.additions/deletions/changedFiles` in the shell | small | 964 of 991 recent runs have a checkpoint. Decode and sum. |
| Stopped: the reason | Shell `lastError` | works | |
| Stopped: "Last step" | The failed run's last tool item, from the thread stream | small | Stopped threads aren't watched (`SF/Threads.swift:377`): one bounded read. |
| Rerun | No retry command in T3 | small | Gap 3. |
| Plan: text, answer | `proposed_plan` markdown (`SF/T3Types.swift:517-527`); answer = set the modes, then `message.dispatch` with `sourcePlanRef` (`SF/RouterView.swift:118-123`) | works | T3 gives no plan options. Fjord's own two (`SF/ThreadRequest.swift:45`); "No, keep planning" is a typed message. |
| Form: several questions, one Return | `user_input_request.questions` (`SF/T3Types.swift:529-553`); one `runtime-request.respond{answers}` (`SF/RouterView.swift:85`) | works | |
| Permission: command, options, warning | `approval_request{prompt, options[{decision, label, warning}]}`; `runtime-request.respond{decision, feedback}` (`SF/RouterView.swift:103`) | works, minus "why" | Real data: `prompt` 17 of 17, `options` 14 of 17 ("Allow once", "Allow for this thread" with a warning, "Deny", "Cancel"), `reason` 0 of 17. Gap 7. Typed words decline with feedback. After a T3 restart a request can't be answered: show Open in T3. |
| "new" dot, and clearing it | `isUnseen` (`SF/T3Types.swift:354-358`); `thread.visit` (`SF/ThreadSender.swift:146`) | small | T3's rule only knows finished runs. A new ask on a running thread needs `pendingRuntimeRequest.createdAt` against `lastVisitedAt`, in code. Opening a card must now send `thread.visit` (today Fjord only does on a send). |
| Ages | Shell timestamps | works | |

### Your acts

| Capability | Real source | Verdict | Notes |
|---|---|---|---|
| Settle, and Revert | `thread.settle` / `thread.unsettle` (`SF/ThreadActs.swift:67`) | works | |
| Snooze, and Revert | `thread.snooze{until}` / `thread.unsnooze` (`SF/ThreadActs.swift:69-70`) | works | T3 wakes a snoozed thread on a new request or failure. |
| Settle all | One `thread.settle` per thread | works | |
| Not for me | Fjord only: a mark on the verdict, kept with its fingerprint | small | T3 has no such notion and needs none. |
| ⌘Z | The window's `UndoManager` plus the reverse commands above | small | |
| Stop | `run.interrupt` (`SF/ThreadSender.swift:226`) | works | Fjord sends `holdQueue: true`: queued words then wait. |
| Open in T3 | `t3code://threads/<env>/<thread>` (`SF/T3Store.swift:310`) | works | |
| Send to an idle thread, answer in words | `message.dispatch`, `start_immediately` (`SF/ThreadSender.swift:60, 141-143`) | works | The returned `{sequence}` is "T3 has them". |
| Steer now, ⌥ queue | `deliveryIntent: steer` / `queue_after_active` (`SF/ThreadSender.swift:57-66`) | works | Claude's steer stops its running tool about 5 s later. An agent that can't steer queues: the row must say so. |
| Queued row, Cancel, rises when the turn ends | `projection.queuedRuns` (`SF/T3Types.swift:691`); `queued-run.cancel` (`SF/ThreadSender.swift:178`) | works | |
| A send fails: failure line, Send again, Edit | `T3Error` (`SF/T3Types.swift:882-890`). A dropped socket is retried 3 times with the same `commandId`, so nothing sends twice (`SF/T3Client.swift:252-264`) | works | T3 down: the error comes at once. T3 hung: after 10 s (`SF/T3Client.swift:176`). |
| Filters, counts, sections, peek, housekeeping, keys | UI over the records; project names from T3 | works | Pure UI. |

### Where a draft goes, and new-thread settings

| Capability | Real source | Verdict | Notes |
|---|---|---|---|
| Destination shown while typing | `RouterPreview`: Jev after a 0.6 s pause, Sonnet after 1.2 s, cancelled by a keystroke, reused on send (`SF/RouterPreview.swift:51-52`) | works, slower than the demo | Gap 5. |
| The selection as a prior | Add the selected thread to the decider's context | small | Needs an eval: it changes what the decider sees. |
| Return before the read lands | Exists (t3-code-map §12) | works | |
| ⌘1–3 among places | The decider's alternatives | works | |
| New thread with a model, runtime mode, interaction mode | `orchestration.launchThread` (`OV2:3632-3653`); Fjord sends all three (`SF/T3Types.swift:862-870`) | works | Today always T3's default model, `default` mode (`SF/ThreadLauncher.swift:50-80`). |
| Reasoning effort | `modelSelection.options: [{id: "effort", value}]` (`T3:packages/contracts/src/modelSelection.ts:9-13`) | small | `T3LaunchRequest` has no options field yet. |
| The list of models, efforts and modes | `server.getConfig`: `providers[]{instanceId, status, supportedRuntimeModes, showInteractionModeToggle, models[]{slug, name, aliases, capabilities.optionDescriptors}}` (`T3:packages/contracts/src/server.ts:76-88, 207-256`). Read scope, which Fjord's token has (`T3:apps/server/src/auth/RpcAuthorization.ts:64`); Fjord calls it already (`SF/ThreadLauncher.swift:127`) | works | Here: Fable 5.2, Opus 5.5, Sonnet 5.5, Haiku 5.5 with aliases ("opus"); effort low, medium, high, xhigh, max; default Opus 5.5, runtime `auto`. `subscribeServerConfig` keeps it fresh. |
| "(use opus medium)" read from the draft | Four fields in the decider's schema, their allowed values taken from the list above | small | Tested: Sonnet and Haiku both gave opus, medium, plan, approval-required. No word lists. |
| The settings preview updates live | The decider call | small, slower than "live" | Gap 5. |
| Editing the settings by keyboard | UI | works | |

## Gaps, ranked, with the cheapest real fix

1. **Working lines and to-do steps don't read like the demo.** The demo says "re-measuring the composer spacing" and
   shows five steps. Real data gives the running tool: a raw command, "Editing Foo.swift", "Thinking". And there is not
   one to-do list in 70,041 real items: Claude in T3 only sends them with `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`, which isn't set.
   Fix: (a) the owner adds that variable in T3 › Settings › Providers › Claude › Environment; (b) the line is the running
   to-do step, else the first sentence of the agent's latest words between tools (`ThreadWork.narration`, already read),
   else the tool. No model call.
2. **"Stopped" is not a failed test or build.** T3 fails a run on a provider error, a transport error, a usage limit or
   an interrupt (19 failed and 3 interrupted of 1,659 runs). The demo's "swift build exited 1" is a normal finished turn
   in T3: it arrives as Done, and only the verdict can say it went wrong. Also, a run you stopped yourself is
   "interrupted": it shouldn't land in Needs you. Fix: the verdict prompt treats "ended on an error it couldn't fix" as
   `needs_you`; Stopped keeps only real stops; a stop you asked for (`latestRunStopRequested`, in the shell) goes to Done.
3. **Rerun has no command.** `deliveryIntent: restart` (DESIGN.md §7) restarts a *running* run and still needs a
   message (`T3:apps/server/src/orchestration-v2/CommandPolicy.ts:144-158`). T3's own button sends the words "Continue
   where you left off." with `manualContinuationOfRunId`, allowed only after an interrupt or a usage limit
   (`T3:apps/web/src/components/chat/useComposerResume.ts:119-134`, `Orchestrator.ts:5462-5480`). Fix: Rerun sends those
   words (with the run id when allowed, a plain message otherwise). The thread then shows that message, not “Rerun”.
4. **The verdict takes 2.5 s, not 1.4 s, and a quarter of them are wasted.** The state lands at about 1.9 s and the
   words stream until 2.5 s. One run end in four is followed by a new run within 30 s, so the line would turn Done,
   sheen, then go back to Working. Fix: start the call in the same frame as the event, cancel it when a run starts, at
   most 4 calls at once (as the briefs do). A warm spare process is not worth it (0.3 s).
5. **The destination and the settings are not read in 0.4 s.** Jev is fast but only sure for follow-ups to idle threads.
   A new thread, an unsure place and any "(use opus medium)" need Sonnet: a 1.2 s pause, then 3 to 5 s on the full
   context (2.5 s on a tiny prompt). Fix: show at once what code knows (the selected thread; for a new thread T3's
   default model, effort and modes), sheen the row until the read lands, keep holding Return until it does. Put the four
   settings fields in the decider's schema: one call, no second model. Start Sonnet at the 0.6 s pause to save 0.6 s, at
   the price of more cancelled calls.
6. **PR state is pushed only for PRs T3 has linked.** Fix: when a reply names a PR that T3 hasn't linked, Fjord sends
   `thread.pull-request.link` (`OV2:3062`; exists, not run live), so T3 polls it and pushes its state like the others.
   If that fails live: a 60 s timer in Fjord for open PRs on the page. Either way the flip takes up to a minute.
7. **A permission has no "why".** T3 sends the command, the options and their warnings, never a reason. Fix: drop the
   block; the model's line already says it ("wants to remove the old checkpoint worktree, with --force").
8. **The model must never write your words.** Haiku changed the message while reading its settings. Fix: the decider
   returns the settings only; the draft is sent as typed, "(use opus medium)" included.

## What should change in the design

- **§1.4 Working line:** "the running step (T3's to-do step, else the last tool)" becomes "to-do step, else the agent's
  latest words, else the tool". Demo lines should look like real ones: `swift test --filter SnapshotRestore`.
- **§1.5 Working card:** the step list shows only when the thread has one; without, the card is the live reply and Stop.
- **§1.5 Stopped, §6.2:** real reasons ("the connection to Claude dropped", "hit the usage limit", "interrupted"). Move
  the failed test and failed build examples (Disk test, Snapshot API, beat 17) to a Done turn the verdict flags.
- **§1.5 Rerun, beat 10:** the Sent line reads “Continue where you left off.”
- **§1.5 Permission:** no reason block; demo options as T3 gives them: Allow once · Allow for this thread · Deny · Cancel.
- **§1.5 Plan:** two options, not three; "No" is typing.
- **§2.1:** an interrupt you asked for is Done, not Stopped.
- **§3 demo latencies:** verdict 2.5 s (state at 1.9 s); destination read 0.5 s when Jev is sure, 3 to 5 s otherwise;
  PR flip up to a minute after the merge. Add a beat: a turn ends and restarts within the sheen.
- **§1.9 and Round 2:** the row shows the defaults at once and sheens the settings until the read lands. Efforts and
  modes are whatever `server.getConfig` lists for the chosen model.
- **§7 "Stopped":** replace `startImmediately(intent: .restart)` with gap 3's fix. **"New dot":** add the rule for a new
  ask. **"Working line":** to-dos need the T3 setting.

## Not verified

- `thread.pull-request.link` on a live server.
- That the to-do variable works with the owner's custom Claude binary (`claude-thread`).
- Providers other than Claude (2 Codex runs in the data): their options, steering and to-dos were read in source only.
- Seven or more `claude -p` calls at once against the subscription's limits (beat 36).
- No model usage log exists on disk yet, so the costs above are from the four test calls, not from history.
