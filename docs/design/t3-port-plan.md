# Porting Fjord to T3 Code: the implementation plan

Status: plan, 2026-11-07. Nothing in it is built yet. Inputs: [`t3-code-map.md`](t3-code-map.md) (its owner-decisions block is binding),
[`t3-research/S1-spikes.md`](t3-research/S1-spikes.md) (live wire facts), [`R1-routing-advice.md`](t3-research/R1-routing-advice.md),
`F2-part-A..D.md`, `F3-features.md`, and the code as of `40de8c1a`. `SF/` = `Sources/Fjord/`, `TF/` = `Tests/FjordTests/`.

Built in parallel and assumed below: `SF/T3Client.swift`, `SF/T3Types.swift` (`T3ThreadShell`, `T3Project`, `T3Projection`,
`T3RuntimeRequest`, `T3Question`, `T3Plan`, `T3TurnItem`, `T3Command`, `T3LaunchRequest`, `T3DeliveryIntent`…), `SF/T3Store.swift`
(shell and projection reducer, command encoding), `SF/AnthropicClient.swift`, and `t3-research/decider-board-spec.md`.

## 1. The new core model

### 1.1 Names

`Thread` is taken by Foundation (`Thread.isMainThread` in `Theme.swift`, `Thread.sleep` in tests), so the provider-neutral name is
**`AgentThread`**. Everything is keyed by `ThreadKey`, never by a folder path or a Claude session id.

| Today | Becomes | Built from |
|---|---|---|
| `ClaudeSession` (`Claude.swift:7`) | `AgentThread` | `T3ThreadShell` + its `T3Project`: `key`, `projectID`, `title`, `status`, `pendingRequest` (`{id, kind, blocking}`), `hasPlan` (`hasActionableProposedPlan`), `unseen` (`lastVisitedAt` null or `< updatedAt`), `latestVisibleMessage`, `lastRunEndedAt`, `lastUserMessageAt`, `branch`, `pullRequests`, `tags`, `snoozedUntil`, `settledAt`, `backgroundTasks` count, `limitResetAt` |
| — | `ThreadKey { environmentID, threadID }` | `Hashable, Codable`; `id` string `"<env>/<thread>"` for persistence, notifications and MCP |
| `ClaudeActivity` | `ThreadWork` | the thread projection: current turn item (by item type, never by tool name), `todo_list`, last `assistant_message` as narration |
| `ClaudeTask` | `BackgroundWork` | shell `pendingBackgroundTasks`, `subagent` items |
| `PendingForm` + `FormSnapshot` (`Forms.swift:93`, `RouterBriefDoc.swift`) | `ThreadRequest` | `T3RuntimeRequest` + `user_input_request` / `approval_request` items + `T3Plan`: `.question([T3Question])`, `.approval(kind, prompt, decisions)`, `.plan(planID, markdown)`, with `requestID`, `live: Bool` (`responseCapability.type == "live"`) |
| `AgentEntry` / `AgentsState` (`Agents.swift:7,25`) | `ThreadEntry` / `ThreadsState` | Fjord-local only: `icon`, `rejectedIcons`, `label` (see 1.3) |
| `AgentRow` / `AgentCache` / `AgentGroup` | `ThreadRow` / `ThreadCache` / `ThreadGroup` | as today, with `group` from T3 state (1.2) |
| `ClaudeLink` (`Agents.swift:76`), `ClaudeLinkStatus` | `T3LinkState` per environment, `T3LinkStatus` | descriptor check, socket, token |
| `RouterCourier.Target` (string target ids) | `RouteTarget` | `.thread(ThreadKey)`, `.newThread(environmentID, projectID)`, Fjord intents; ids `t3:thread:<env>/<id>`, `t3:new:<env>/<project>` |
| `BriefTarget(project, thread)` | unchanged shape | `project` = T3 project id, `thread` = T3 thread id; the environment is looked up in `T3Store` (UUIDs don't collide) |

### 1.2 What decides a row's state

All from the shell row; no timers, leases or heuristics.
- `needsYou`: `pendingRequest?.blocking == true` (the shell keeps `status: running` during an approval, S1 e), or `hasPlan`, or
  `status == failed`, or a usage limit with no auto-resume.
- `working`: `status` in `preparing, queued, starting, running`, or background work left.
- `done`: `unseen` and finished (`completed, interrupted, cancelled`).
- `idle`: the rest; listed for `Store.recentWindow` after the last activity, as today.
- Never listed: archived, `settledAt` set, snoozed until later, or not `isListedThreadLineage` (subagents route to their parent).

### 1.3 How data flows

```
T3Client (one socket per environment) → T3Store (shell rows, projects, subscribed projections)
   → Store.threads [ThreadKey: AgentThread], Store.threadWork, Store.requests [ThreadKey: ThreadRequest]
        → ThreadCache → bar, window list, palette (PaletteRouterSource, PaletteTriageSource)
        → BriefLog (briefs.db) → T3BriefSource → RouterBriefEngine (Haiku, claude -p) → BriefPage
        → RouterProjectContext (decider-board-spec) → RouterProjectDecider (Jev, then Sonnet via AnthropicClient)
        → RouterMCP board tool (Router run)
Acts: ThreadSender / ThreadLauncher / ThreadActs → T3Command via T3Client.dispatch → confirmed by the next shell/thread event
```

- `T3Store` holds `subscribeShell` for every environment, always. It opens `subscribeThread` only for threads that are working or
  waiting and are listed or feed a brief, and closes it once the thread settles (peak about 25 streams, S1 h). Requests and
  `ThreadWork` come only from those projections, because the shell carries no question text.
- `Store` sets observed properties only on change, as `ingest` does today, so views redraw once per real change.
- Triage reaches threads only through the Router (`ActionPrompt` → `RouterContext.action`), so it needs no separate feed;
  `T3Project.repositoryIdentity` joins threads to Triage repos (used for the "later" PR features).
- Kept Fjord-local: icons (Jev) and labels in `ThreadsState`, keyed by `ThreadKey`; project colours keyed by `projectID`; muted
  projects; brief versions, prose, `told` and `notified` marks in `briefs.db`; the decision log. Read state, archive, snooze and tags
  are T3's, which also keeps them in step with T3's sidebar and phone app.
- Labels: the map (A9) says labels become T3 tags. A label is two letters or an emoji for Fjord's glyph and would read as noise
  in T3's tag list, so keep labels local and use tags only for words you mean as tags (open question Q1).

## 2. How the work runs

- Each step below is one commit: `swift build`, the step's `swift test --filter` suites, then `scripts/test.sh` must pass, and
  `swift build && .build/debug/Fjord --window-shots .build/shots router brief settings` must still render. Read the PNGs.
- Commit messages: conventional type, no scope (`refactor: `, `feat: `…), then a plain sentence about the result.
- Deletion rule: a step that replaces a path deletes the old one in the same commit, with its tests, its settings and its
  persisted fields. Nothing is kept as a fallback or behind a flag. Persisted fields that go are simply no longer decoded.
- Parallel steps (marked ∥) touch disjoint files except where noted. Sequential steps work on main. In a parallel pair, the
  second agent works in a `git worktree`. Its commit is rebased onto main and tested again there before it lands. **Only one
  `scripts/test.sh` runs at a time**, so the orchestrator queues test runs across agents.
- During the port the live Router has gaps: replies to local threads stop working between steps 4 and 9, and answering stops
  between steps 7 and 8. claude.ai routing keeps working until step 12. That window is intentional; keep it short.

## 3. Steps

| # | Step | After | ∥ with |
|---|---|---|---|
| 0 | T3Client/Types/Store, AnthropicClient, decider-board-spec (in flight) | — | — |
| 1 | Neutral names, mechanical | 0 | — |
| 2 | T3 link, token minting, settings and onboarding | 1 | 3 |
| 3 | Delete the Silo-guest Claude plumbing | 1 | 2 |
| 4 | Feed swap: the shell becomes `Store.threads` | 2, 3 | — |
| 5 | Thread detail: `ThreadWork` from projections | 4 | 6 |
| 6 | Open in T3 | 4 | 5 |
| 7 | Waiting requests from T3; the hook goes | 5 | — |
| 8 | Answering questions, permissions and plans | 7 | — |
| 9 | Sending: steer by default, ⌥Return queues; carry and plugin go | 8 | 13 |
| 10 | Queue control: interrupt, edit and cancel queued messages | 9 | 13 |
| 11 | Launching new threads | 10 | 13, 14 |
| 12 | The decider on the T3 board, Sonnet through the API | 11 + spec | 14 |
| 13 | The brief on T3 | 8 | 9–11 |
| 14 | Thread acts as T3 commands with Revert; notifications from the shell | 13 | 11, 12 |
| 15 | The Router run's tools on T3 | 12 | 14 |
| 16 | Courier and native host sweep | 12, 13, 15 | — |
| 17 | Demo and shots sweep | 16 | 18 |
| 18 | README and DEVELOPMENT | 16 | 17 |
| 19 | *Later phase:* Silo computers as T3 environments | 18 | — |

### Step 1: neutral names (`refactor:`)
A pure rename with no behaviour change, done with `sed` plus fixes:
- `ClaudeSession→AgentThread`, `ClaudeActivity→ThreadWork`, `ClaudeTask→BackgroundWork`, `AgentEntry→ThreadEntry`,
  `AgentsState→ThreadsState`, `AgentRow→ThreadRow`, `AgentCache→ThreadCache`, `AgentGroup→ThreadGroup`.
- Store properties: `claudeSessions→threads`, `claudeActivity→threadWork`, `claudeTasks→backgroundWork`, `openAgent→openThread`.
- The persisted `CodingKey` for `agents` stays until step 4 resets it.

Files: `Agents.swift` (rename to `Threads.swift`), `Claude.swift`, `Store.swift`, `Demo.swift`, `RouterView.swift`, `RouterMCP.swift`,
`RouterBriefs.swift`, `RouterDispatcher.swift`, `RouterProjectContext.swift`, `RouterRun.swift`, `RouterCancel.swift`, `Palette*Source.swift`,
`PaletteFixture.swift`, `PaletteView.swift`, `SessionGlyph.swift`, `Lifecycle.swift`, `ActionPrompt.swift`, `InboxActions.swift`, Guest*, tests.
Run it alone, because it touches almost everything.

### Step 2: T3 link (`feat:`) ∥ 3
- New `SF/T3Link.swift`. It finds the server from `~/.t3/userdata/server-runtime.json`, checks `/.well-known/t3/environment`
  (protocol 2), and keeps one `T3Client` per environment through `T3Store`.
- Token: Keychain `fjord-t3-token`. "Link to T3" in Settings runs `~/.t3/bin/t3 auth session issue --scope orchestration:read
  --scope orchestration:operate --label Fjord --ttl 365d --token-only` (that path is not on `PATH`).
- On a token rejection it mints again by itself when the CLI exists, and otherwise says so on the status line.
- Liveness: Fjord pings every 5 s and treats a missing `Pong` as a dead socket. It reconnects with the shell's `afterSequence`.
- `T3LinkStatus` replaces `ClaudeLinkStatus.swift` and `enum ClaudeLink`. Its states: no T3 installed, server not running,
  incompatible protocol, token rejected, connected (n threads).
- The Router switch is gated on T3 being installed instead of `Claude.isInstalled` (`SettingsView.swift:402`, `Onboarding.swift:47`).
- The Settings "Claude" section becomes "T3 Code": link status, Link/Unlink, and the Anthropic API key field (Keychain
  `fjord-anthropic-key`, for the decider).
- `HubView` shows the link state.
- Tests: new `T3LinkTests` (a descriptor stub, a 426 or 401 response, minting through a stubbed runner); `SettingsSystemStateTests`.

### Step 3: delete the Silo-guest Claude plumbing (`refactor:`) ∥ 2
- Delete `GuestRouterInstaller`, `GuestRouterRuntime`, `GuestRouterPaths`, `GuestNodeRuntime`, `GuestRelayInbox`, `GuestForms`,
  `GuestTranscripts`, `GuestBackgroundTasks`, `GuestDesktopStart`, `GuestClock`, `ClaudeSSHSettings.swift`, and `PendingDesktopStart`
  plus the `computer(...)` placement in `ProjectPlacement.swift`.
- Remove `Store.guestExecutionStates` and the `GuestRouterRuntime` calls (`Store.swift:33,37`).
- Keep `GuestCodeFolders`, and keep `GuestClient` only where code folders use it.
- Remove the "Claude Code" and "Node.js" entries from the computer agent tools (`AgentTools.swift`); step 19 adds `t3`.
- Tests deleted: `GuestRouterTests`, `ClaudeSSHSettingsTests`, `RunsOnRemoteTests`, `TriageGuestSessionTests`, and the Claude parts
  of `OwnGuestRuntime`/`FakeSiloUnixServer`.
- Shots: `computer-agent-tools` loses the Claude rows. "Runs on a computer" is gone until step 19.

### Step 4: feed swap (`feat:`)
- `Store` observes `T3Store`'s shell, builds `AgentThread`s (1.1) and fills `threads: [ThreadKey: AgentThread]`.
- `ThreadRow.group` follows 1.2.
- `ThreadsState` keeps only `entries` (icon, rejected icons, label), `projectColors` keyed by projectID, `mutedProjects`,
  `iconsEnabled` and the version fields. The persisted key becomes `threads`, and old state starts fresh.
- Deleted from `Claude.swift`:
  - `Claude.SessionReader`, `decodeSession`, `runningTimeout`, `isRunning`/`isFrontmost`;
  - `unreadIDs`/`parseUnread`, `ClaudeSnapshot`, `ClaudeStamp`, `ClaudeFeed`;
  - the presence and lease code (`readPresence`, `scanPresence`, `applying(presence:)`).
- Deleted from `Store.swift`: `watchClaude`, `scheduleClaudeTick`, the `claude*` timers and observers, `claudeReadAsked/Once`, the
  `isClaude` workspace notifications, and the sessions and dots `FolderWatcher`s. `routingMayBeReady` keys on the first shell snapshot.
- Deleted from `Agents.swift`: `ingest`'s seeding, the turn-delta unread logic and the sidebar-dot reconciliation.
- Deleted files: `LevelDB.swift`, `Peers.swift`, `ClaudeProcesses.swift`.
- `Demo.sessions()` and `Demo.agents()` feed `T3ThreadShell` fixtures into `T3Store` (a `T3Store.seed(shell:)` for demos and tests),
  so the bar and palette shots render on T3 shapes.
- `Demo.swift`'s `--claude [--watch]` becomes `--t3 [--watch]`: link state, threads by group, pending requests.
- Tests: rewrite `AgentsTests` on shell rows (grouping, listing, unseen, recent expiry). Delete `LevelDBTests` and
  `PermissionProcessTests`. Update `PaletteRouterSourceTests` and `HermeticTests` (no socket opens in tests).

### Step 5: thread detail (`feat:`) ∥ 6
- `T3Store` opens and closes thread subscriptions as in 1.3. `ThreadWork` comes from turn items:
  - `command_execution` → its input, `file_change` → the file name, `web_search`/`file_search`/`dynamic_tool{toolName}` → their words;
  - `todo_list` → `Todo`;
  - the last `assistant_message` → narration.
- `BackgroundWork` comes from the shell.
- Deleted from `Claude.swift`: transcripts, `tail`, `activity(tail:)`, `describe(tool:)`, `tailCalls`, permission merging, task folders,
  `openTaskOutputs`, `OpenOutputs`, `FolderWatcher` (if nothing else uses it), and the rest of `enum Claude` except `open`, which
  goes in step 6. Delete `YourMessages.swift`: user messages are `role: user` items.
- Jev icon inputs (`Jev.swift:318`, `Agents.swift` icon picking): title, first user message and the last turn's final message come
  from the projection, or once from `GET /threads/:id/transcript`, cached per thread at `updatedAt`.
- Tests: `AgentsTests` activity cases on projection fixtures, `JevGateTests` (`iconFirstMessage`), and `PrivateFolderTests` deleted.

### Step 6: Open in T3 (`feat:`) ∥ 5
- `openThread(key)` opens `t3code://threads/<env>/<thread>` and marks the thread visited (`thread.visit{opened:true}`).
- Ship Fjord's own glyph asset for it and stop reading Claude's spark in `ClaudeMark.openSymbol`.
- Change the labels "Open in Claude" → "Open in T3" (`RouterView.swift:632`, `RouterBriefView.swift:688`, `PaletteRouterSource`,
  `InboxActions` chip help). Delete `Claude.open`, `RouterBriefs.desktopSession` and `cli(...)`.
- Tests: an intercepted open (`interceptOpen`).

### Step 7: waiting requests from T3 (`feat:`)
- `Store.requests[ThreadKey]` holds the newest live `ThreadRequest` per thread, from subscribed projections. A declined approval
  that gets retried creates a new request id, so follow the newest pending one (S1 e).
- `BriefEntry.form` becomes `request: ThreadRequest?` (live, never stored); `RouterBriefs.resolved(_:)` reads it.
- Kinds:
  - question, with every question and its options;
  - plan, with markdown;
  - permission, with `requestKind` and `prompt`;
  - `stopped`, which replaces `stranded`: failed, interrupted, or a usage limit with `resumes at`.
- A request whose capability isn't live says so ("T3 restarted: answer it in T3" or "send words instead"). It never offers a dead form.
- Deleted from `Forms.swift`: `FormBridge`, `FormHook`, `FormHookInstaller`, `PendingForm`, `PrivateFile`, and the hook settings
  writes. Move `RouterPaths` to `Router.swift`.
- Also delete `--form-hook` (`main.swift:4`), `Store.pendingForms`/`heldForm`/`routerHookStatus`/`routerFormsLoaded`, the hook install
  on the Router switch (`Router.swift`), `RouterMCP.FormWriter` and Settings' hook line.
- Tests deleted: `FormHookTests`, `FormsTests`, `InstallerTests`, `PermissionWaitTests`. New: `ThreadRequestTests` on projection fixtures.
- Shots: `brief-hover-form` reads a demo `ThreadRequest` with two questions.

### Step 8: answering (`feat:`)
- Question: `runtime-request.respond{answers: {questionID: label | [label]}}` (for Claude, the question id is its text and the
  option value is its label, S1 d).
- Your own words: Jev picks an option id per question (`RouterFormReply.askFormAnswers`, which is already opaque-id based), and an
  answer is sent only when every question is clear.
- **Delete `RouterDispatcher.formAnswers`**: its trimmed and lower-cased label matching interprets words, which the owner's rules
  forbid. Keys 1–9 and clicks are the deterministic path.
- Permission: buttons `accept`, `acceptForSession`, `acceptAlways`, `decline`, offering only those the request allows (Claude sends
  no `options`, S1 7). Typed words mean decline with your words as feedback. Never infer a yes.
- Plan:
  - "Yes, auto-accept" sends `thread.runtime-mode.set{auto-accept-edits}`, `thread.interaction-mode.set{default}`, then
    `message.dispatch{sourcePlanRef, text: "PLEASE IMPLEMENT THIS PLAN:\n"+markdown}`;
  - "Yes, manually" does the same with `approval-required`;
  - "No" plus words is a normal message.
  - Jev's yes/no (`planDecision`) stays for typed replies.
- Deleted: "which only Claude can grant" (`RouterBriefView.swift:669`). `BriefAnswer` lines stay.
- Tests: `RouterBriefWiringTests` and `RouterCardJudge` cases on `ThreadRequest`, and the respond command encoding.
- Shots: add `brief-permission`.

### Step 9: sending (`feat:`) ∥ 13
- New `SF/ThreadSender.swift`: `message.dispatch{dispatchMode: start_immediately, deliveryIntent: steer}` by default.
  ⌥Return sends `queue_after_active`. `commandId` is derived from the decision id, so a retry can't send twice.
- Pills become `context.records` with inline `t3-context://` references where the pill sits (`RouterPointer`); `UntrustedText`
  fencing stays only for Fjord's own model prompts.
- Delivery is confirmed by `message.updated` for that message id, so the "unsure" state goes.
- The entry says "steered" or "queued (n)" from the resulting run: the server queues for providers that can't steer.
- Unattended category actions always queue and never steer (Q4).
- Composer (`RouterComposer`, `RouterKeys`): the live pick reads "steer <thread> (running)" in its own colour.
- `RouterDispatcher.plan`'s `.reply` goes to the `ThreadKey`.
- Deleted:
  - `RouterCarry.swift`, `SessionControl.swift`, `RouterSender` (`RouterRun.swift:441…`), `DeliveryOperation`, the relay key;
  - `ClaudePlugin.swift` + `Resources/ClaudePlugin`, the plugin install in `Router.swift`, Settings' plugin line;
  - `routerPluginStatus/Error/Runner`, `RouterMCP` `prepare`/`approveSend`, `retryGuestDelivery`.
- Tests: delete `ClaudePluginTests`, `DevPluginNamesTests`, `RouterCarryTests`. Rewrite `RouterTransportTests` and
  `RouterToldTests` on a stub `T3Client`.

### Step 10: queue control (`feat:`) ∥ 13
- The drawer and the message pill show a queued message with Edit (`queued-run.edit`) and Cancel (`queued-run.cancel`).
- A running thread offers Stop (`run.interrupt{holdQueue:true}`, then `queue.resume`).
- "Change your mind" on a queued message is real and instant. A steered message can't be taken back, and the pill says so.
- `RouterCancel.swift`'s `abort-v1` and the `deliveryCanceller` signing are deleted.
- Tests: rewrite `RouterCancelTests`.

### Step 11: launching new threads (`feat:`) ∥ 13, 14
- New `SF/ThreadLauncher.swift`: `orchestration.launchThread`.
  - `generateTitle: true`; `interactionMode: default`.
  - `runtimeMode`: per category action, defaulting to the project's; for your own messages, T3's default.
  - `workspaceStrategy`: `root` for your messages; `worktree{baseRef: default branch}` for unattended Triage actions (`RouterContext.action`).
- Revert archives the new thread (R1 B), as a `FjordChange` with Revert.
- Never launch into "No project", which makes a scratch dir per launch (S1 15).
- A code folder with no T3 project gets one through `projects.mutate`, but only from an explicit ask-back pick "New thread in <folder>".
- Delete `RouterProjectProposal*.swift` (claude.ai project name, instructions and repo, with its Sonnet reviser through `claude -p`),
  `routerProposal*` in `Store` and persisted state, and `RouterAskBack.newProject`.
- Tests: delete `RouterProjectProposalTests`. New `ThreadLauncherTests` (encoding, worktree only when unattended, Revert).

### Step 12: the decider on T3 (`feat:`) — needs `decider-board-spec.md`
- Rebuild `RouterProjectContext` from `T3Store` exactly as the spec says. R1's baseline:
  - candidates: waiting and live threads, the latest finished per project cut at 12 h, "new in <project>" with its purpose and
    last 3 titles, and Fjord;
  - per candidate: title, status and age, `latestVisibleMessage` (~600 chars), your last message, todo step, branch and PR, and the
    waiting request as text.
- One renderer serves the app and `evals/router` alike.
- `RouterProjectDecision.Kind` becomes `.thread(ThreadKey)`, `.newThread(projectID)`, `.answer`, `.ask` (no `.newProject`, no coordinator).
  When the project is sure and the thread isn't, start a new thread in it.
- Sonnet uses `AnthropicClient` structured output (`fjord-anthropic-key`). Without a key it's Jev alone and asks. Jev-first and the
  bars (send, thread, and a higher bar for running targets) come from the spec.
- After the pick, a waiting request maps deterministically (R1 A): question → Jev option, approval → decline with words, plan → message.
- `RouteTarget` replaces `RouterCourier.Target` in `RouterDispatcher`, `RouterDrawer`, `RouterPointer`, `ActionPrompt`,
  `RouterDecisions` (`courierIntent` becomes `commandID` + `sequence`) and `Demo`.
- Log every live decision (board, pick, confidence, latency, outcome) to a local JSONL file for the 200-moment set.
- Delete `RouterProjectDecider.cli` and `courierHandoff`.
- Tests: rewrite `RouterProjectDecideTests` and `RouterDispatcherTests` on a stub Sonnet and T3 board fixtures. Update `RouterDecisionsTests`.

### Step 13: the brief on T3 (`feat:`) ∥ 9–11
- New `SF/T3BriefSource.swift`:
  - `projects()`: T3 projects with listed threads;
  - `board(project:)`: deterministic threads and entries from `Store.threads` + `requests`;
  - `items(project:after:)`: read from a new **`BriefLog`** table in `briefs.db`.
- `BriefLog` is appended by `Store` on real transitions (status change, request or plan appears or resolves, a run finishes with its
  final message, your message sent). It stores the shell sequence, so a relaunch resumes `subscribeShell{afterSequence}` and logs
  what changed meanwhile.
- `briefs.db` moves to Fjord's Application Support (it sits next to Courier's `router.db` today, `RouterBriefs.swift:245`) and starts
  fresh, because old rows are keyed by `chan_*` and `local:` ids.
- Deleted:
  - `CourierBriefSource`, `CourierBriefFacts`, `CourierBriefChange` and the courier half of `RouterBriefLink`;
  - the coordinator (`BriefDoc.coordinator`, `coordinatorTurning`, `goal`), and `BriefEntry.source`/`card`;
  - the "on this Mac" wording;
  - `watch: "stale:"`, which now means "T3 unreachable since".
- Engine rules: "Claude threads" becomes "agent threads", the coordinator sentences go, and Haiku's loose-ends rule is tightened (E2).
- The prose and highlights look (`RouterBriefMarkup`, `<t id>`) is unchanged.
- `RouterBriefer` keeps `claude -p` but finds `claude` on the login-shell `PATH` (a new `ClaudeCLI` locator). Delete `RouterStatus.swift`.
- Tests: update `RouterBriefEngineTests` (source stub), `RouterBriefWiringTests` and `RouterBriefDocTests`. New `BriefLogTests`.

### Step 14: thread acts and notifications (`feat:`) ∥ 11, 12
| Act | Command | Revert |
|---|---|---|
| Mark read | `thread.visit` | `thread.mark-unread` |
| Archive | `thread.archive` | `thread.unarchive` |
| Snooze | `thread.snooze{until}` (new button) | `thread.snooze{until: null}` |
| Rename | `thread.metadata.update{title}` | the old title |
| Tag | `thread.tag.set` | the opposite tag |

- Every act applies at once and leaves a `FjordChange` with Revert (`FjordChange.briefAction`).
- `BriefMarks` keeps only `told` and `notified`; the `read` and `archived` sets are deleted.
- **Cards leave only on Archive** (from Fjord or T3). A request answered elsewhere turns the card to "answered in T3" and doesn't remove it.
- Notifications fire the moment `Store` sees the transition (blocking request, plan, failure, finish), keyed by request, plan or run
  id. They don't wait for Haiku. `RouterBriefs.announce` switches to board entries.
- Tests: `SnoozeTests` for the T3 snooze, `UndoTests`, `RouterBriefReviewTests`, and announce dedupe.

### Step 15: the Router run's tools (`feat:`)
- `RouterMCP`'s `board` tool reads `T3Store`, and `answer` sends `runtime-request.respond`. `RouterRunContext` is built from threads.
- Optional, behind Q6: add T3's read-only MCP (`t3_thread_list/read/search`) to the run's `--mcp-config`.
- The run stays on `claude -p` stream-json, so `RouterStream` stays.
- Tests: rewrite `RouterMCPTests` (fake sessions `local_a` become thread fixtures); `RouterRunStreamTests` is unchanged.

### Step 16: Courier and native host sweep (`refactor:`)
- Delete every `Courier*.swift`, `RouterCourier.swift`, `RouterCourierPill.swift`, `RouterCourierSetup.swift`, `NativeHost.swift`,
  `NativeHostManifest.swift`, `CourierTestMode.swift` and `poc/router/extension`.
- Delete the `--native-host` and `--courier-test` flags (`main.swift:6,8`), `Store.routerCourier`/`routerCourierLink`, Settings'
  delivery setup, `Demo.claudeProjects`, the `courier-setup-*` shots and `scripts/migrate-to-fjord.sh`.
- Tests deleted: `CourierFramesTests`, `CourierSlice1-4Tests`, `CourierHostTests`, `NativeHostTests`, `RouterCourier*Tests`.
- Finish by grepping for `claude.ai`, `courier`, `cliID` and `Claude app`. What remains is design-system naming
  (`ClaudeControls`, `ClaudeDesign`, `CDS`) and `ClaudeFonts` (Q3).

### Step 17: demo and shots sweep (`test:`) ∥ 18
- `Demo.populate(.router)` and `DemoBriefs` are fully T3-shaped: UUID project and thread ids, and `T3Store.seed` with shells and
  projections that hold a question, a plan, a permission, a steer, a queued message and a stopped thread.
- Update the hover keys in `AppWindowShots` (`chan_demo_fjord/...`), then rename and add shots:
  - `brief-hover-stranded` → `brief-hover-stopped`;
  - add `brief-permission`, `router-steer`, `router-queued` and `settings-t3-link`.
- `ShotCatalogTests` and `DemoTests` must pass, and every shot renders.

### Step 18: docs (`docs:`) ∥ 17
- README: the Install table needs T3 Code and no Claude app; the Router follows T3 threads from any provider.
- README privacy: the decider uses the Anthropic API key; briefs use `claude -p` on your subscription.
- DEVELOPMENT: `--t3`, the link and token, and the T3 test stubs. "What the Router reads and writes" says it writes nothing into any
  agent's config. Remove the Claude-only flags.

### Step 19 (later phase): Silo computers as T3 environments
- Silo's agent tools install `t3` and the provider CLIs on the guest. Fjord mints a token with `guest.exec t3 auth session issue …`
  and reaches the guest's port through Silo's SSH forward. This needs a spike first: `t3 serve` bind address and forward lifetime
  (map §9.6).
- `T3Link` adds the guest as another environment, so every step above works there unchanged.
- "Runs on a computer" comes back as a choice of environment for `launchThread`.

## 4. Risks and open questions the map misses

1. **`Thread` collides with Foundation.** Hence `AgentThread`. Don't define a top-level `Thread` in the module.
2. **The brief has no log to read.** `BriefSource.items(after:)` expects a sequenced per-project log that Courier's `router.db`
   provides today. T3 has none, and its shell replay coalesces rows (S1 2, h), so status flips during a relaunch are lost. The
   Fjord-owned `BriefLog` (step 13) is required, not optional.
3. **The brief's look reads the Claude app.** `ClaudeFonts` (`Fonts.swift:14`, `app.asar`) and `ClaudeMark` read
   `/Applications/Claude.app`. After a full switch the owner may delete that app, and Anthropic Sans and the spark would silently
   fall back. **Q3:** keep the read while the app exists, or ship a licensed font and Fjord's own marks.
4. **Briefs need a `claude` CLI.** `RouterStatus` finds Claude Code inside the Claude app bundle. Without that app, briefs need
   `claude` on `PATH` (T3's Claude provider needs it too), and Settings must say so when it's missing.
5. **`formAnswers` breaks the no-word-matching rule** (`RouterDispatcher.swift:688`: trims, lower-cases, "the words alone"). Step 8
   deletes it.
6. **The shell status stays `running` during an approval** (S1 e), so `needsYou` must come from `pendingRequest.blocking`, not
   `status`. A declined approval can come back with a new id, so the card follows the newest one.
7. **Persisted state that dies:**
   - `ThreadsState` entries, colours and muted folders were keyed by Desktop ids and paths;
   - `RouterDecision.decision.targetID` and `courierIntent` hold claude.ai ids;
   - `routerProposals`;
   - `briefs.db` rows.
   No legacy: drop the fields, decode old history entries as text only, and start `briefs.db` fresh. **Q2:** is losing labels,
   icons and colours acceptable? (They are few.)
8. **Unattended actions could steer.** A category's "Then" firing on a PR comment would interrupt a running agent mid-tool
   (Claude's steer stops the tool after ~5 s, S1 5). **Q4:** proposal: unattended always queues, and only your typed words steer.
9. **`launchThread` fields Fjord doesn't choose.** S1 passed `modelSelection` explicitly. If it's required, Fjord must take T3's
   default from `server.getConfig` with no UI. The worktree `branch` naming is also open. **Q5:** read `OV2:3632-3662` for which
   fields are optional before step 11.
10. **Capabilities are unknown before a thread's first run** (S1 3). Sending `deliveryIntent: steer` lets the server fall back.
    Fjord must report what happened from the resulting run rather than assume it.
11. **Auth for the run's MCP.** The read-only T3 MCP (map §4.3) needs its own auth (OAuth or a scoped token in the `claude -p`
    MCP config, which is written to a temp file). **Q6:** is it worth it in step 15, or later?
12. **The token lives a long time.** A 365-day token in Keychain; re-minting needs `~/.t3/bin/t3`, which isn't on `PATH`. The spike
    left session `b1e8e41a-…` alive until 2026-12-06: revoke it (owner).
13. **One test run at a time** (CLAUDE.md) caps parallel lanes at about 2. Build caches are per worktree, so expect cold builds.
14. **The ping is a timer.** "Instant, no polling" holds for state. The 5 s heartbeat is liveness, not polling for data, and the
    `recentWindow` expiry stays one-shot.
15. **Subagent and settled threads.** 439 imported threads have `settledAt` set and must never appear or seed. Messages about a
    subagent's task route to `delegatedFrom` (R1 E4).
16. **Archive removes the row from the shell.** A Revert of archive must not need the row: keep the last `AgentThread` in the
    `FjordChange` payload until it expires.
17. **`HermeticTests`** must keep asserting that tests touch no real home: no `~/.t3`, no socket, no Keychain. Every test uses a stub
    `T3Client` or `T3Store.seed`.
