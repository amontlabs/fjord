# Fjord on T3 Code: the full map

Status: research, 2026-11-06. Nothing built. T3 Code v0.1.7 (the installed app, source at tag `v0.1.7` in `~/code/research/t3code`).
Paths: `SF/` = `Sources/Fjord/`; `T3:` = the t3code repo; `OV2` = `T3:packages/contracts/src/orchestrationV2.ts`.
Every T3 fact below was read in source. Items marked **unverified** were not run or not read to the end; they are listed in §9.

**Owner decisions (2026-11-06), these override anything below that disagrees:**
- **A full switch to T3.** No claude.ai, no Courier, no Claude desktop sessions, and no sync of any kind with Claude's apps. The owner already imported the old Claude sessions once; nothing more happens there.
- **claude.ai Projects are dropped entirely, so Fjord is the router again.** It picks the thread, or a new thread in the right repo, itself (§12). That needs fresh benchmarks.
- **Fjord is the router; T3 is the interface for anything advanced.** Fjord carries any useful per-thread information (branch, PRs, todos, files changed, waiting requests) but no model pickers, provider switching or usage windows.
- **Words for a running thread steer by default.** Queueing is the explicit alternative.
- **Brief and decider models are chosen by eval** (Codex gpt-6-luna against the current Claude Haiku and Sonnet), not by default.
- **Notifications:** Fjord notifies on the Mac. **Stock T3** first, with no fork. The owner approved minting a T3 token.

## 0. In short

- **Fjord becomes a client of the T3 server.** One WebSocket per T3 environment gives every thread's state, already computed. That one feed replaces all six private Claude sources Fjord reads today (Desktop session JSON, transcripts, process registry, LevelDB unread dots, the `/private/tmp/claude-<uid>` task folder, and Fjord's own hook and plugin).
- **Acting gets simpler and more honest.** T3 commands send your words as yours, answer questions, approve or decline permissions (which Fjord can't do today), implement plans, interrupt, cancel or edit a queued message, archive, and mark read. The plugin, the hook, the relay key, the carriers, the leases and the `claude://` deep links all go.
- **Not supported:** claude.ai Projects and cloud threads, sessions in the Claude desktop app, and following a terminal `claude` live. T3 can import old Claude Code sessions once and resume them. The Courier (Chrome extension) has no T3 counterpart, and I recommend dropping it rather than keeping it next to T3.
- **Fjord keeps:** the brief, routing, Jev, Triage, the GitHub client and every UI surface. Its own model calls also stay, because T3's text generation isn't exposed over RPC.
- **No fork is needed to ship.** Two small server changes would be worth upstreaming or forking later (§7).

## 1. How Fjord connects

| Need | T3 mechanism | Source |
|---|---|---|
| Find the server | `~/.t3/userdata/server-runtime.json` (`origin`, `port`, `pid`, `serverVersion`; holds no credentials). Here: `http://127.0.0.1:3773`. | `T3:apps/server/src/serverRuntimeState.ts:10-35` |
| Check it's compatible | `GET /.well-known/t3/environment` (unauthenticated) returns `environmentId`, `serverVersion`, `orchestrationProtocolVersion` and `capabilities` flags. Clients "must use advertised capabilities and handle their absence". | `T3:packages/contracts/src/environmentHttp.ts:531`, `environment.ts:77-183`, `docs/internals/remote.md` |
| Credentials | `t3 auth session issue --scope orchestration:read --scope orchestration:operate --label Fjord --ttl <n> --token-only` mints a scoped bearer token with no GUI step (help verified on this Mac). Keep it in Fjord's Keychain. Revoke with `t3 auth session revoke`. | `T3:apps/server/src/cli/auth.ts:169-203` |
| Socket | `ws://127.0.0.1:3773/ws?orchestrationProtocol=2` with `Authorization: Bearer`. A missing or wrong protocol gets HTTP 426. Without a `wsTicket` the upgrade uses normal header auth. | `T3:apps/server/src/ws.ts:693-697,3427-3443`; `EnvironmentAuth.ts:774,1295` |
| Framing | Effect RPC with JSON serialization (Effect 4.1.2). Client sends `{"_tag":"Request","id","tag":"<method>","payload","headers":[]}`; server replies `Chunk{requestId,values[]}` for streams and `Exit{requestId,exit:{_tag:"Success",value}|{_tag:"Failure",cause[]}}`; the client **must** send `Ack{requestId}` after every chunk or the stream stalls (S1 #2); the server never pings, so Fjord pings and treats a missing `Pong` as a dead socket; `Interrupt` ends a stream. | `T3:.repos/effect/packages/effect/src/rpc/RpcMessage.ts:76-335`; `RpcServer.ts:136,216`; `ws.ts:3496` |
| Scopes per method | `subscribeShell` and `subscribeThread` need `orchestration:read`; `dispatchCommand` needs `orchestration:operate`. | `T3:apps/server/src/auth/RpcAuthorization.ts:42-60` |
| All threads, live | `orchestration.subscribeShell{afterSequence?}`: a snapshot, then whole `ThreadShell` rows on every change (`thread.updated/removed`, `project.updated/removed`). | `OV2:2215-2262,3675-3688` |
| One thread's detail | `orchestration.subscribeThread{threadId, afterSequence?}`: a snapshot (`ThreadProjection`), then domain events. The server replays up to 128 events or 1 MiB, otherwise it sends a new snapshot. Unknown event types still advance the cursor. | `OV2:3773-3907`; `T3:apps/server/src/orchestration-v2/ThreadStream.ts:16-23,99-115` |
| Every action | `orchestration.dispatchCommand` whose payload **is** the command (not `{command}`; S1 #1) returns `{sequence}`. Each command carries a client `commandId`, and command receipts make retries idempotent. | `OV2:2895-3372,3664-3667` |
| Cheap reads | `GET /api/orchestration/shell`, `/threads/:id`, `/threads/:id/transcript` (Bearer + `x-t3-orchestration-protocol: 2`). | `T3:packages/contracts/src/environmentHttp.ts:685-727` |
| Reducer to port | `T3:packages/client-runtime/src/state/orchestrationV2Projection.ts` (421 lines). Events are whole-record upserts. | — |
| Open a thread in T3 | `t3code://threads/<environmentId>/<threadId>`. The app registers `t3code` and maps that path to the thread route. `t3code://new?prompt=…&repo=…` opens a draft and never runs it. | `Info.plist` CFBundleURLSchemes; `T3:packages/shared/src/promptLinks.ts:184-215` |

**Client shape.** I recommend a native Swift client with hand-written lenient `Codable` types for about 15 types, gated on the descriptor's capabilities and pinned to protocol 2. A Node sidecar that embeds `client-runtime` would avoid writing the framing, but it adds a runtime and a process hop to every event, which goes against "instant, no smells". The contracts are private TypeScript with no published schema, but Effect 4 ships `JsonSchema.ts`, so a build script run in a T3 checkout could export JSON Schema for the types Fjord uses. That keeps the Swift types honest across T3 releases without a fork.

**Real data on this Mac:** 448 threads in 7 projects (fjord, silo, surplace, sic, lastdrop, lcu, No project). Subagents are threads too (`relationshipToParent: "subagent"`), so Fjord lists only `isListedThreadLineage` threads (`OV2:163-164`).

## 2. Observation: every source Fjord reads today

| # | Today (Claude) | Where | T3 replacement | Design |
|---|---|---|---|---|
| O1 | Session list from Desktop JSON `claude-code-sessions/**/local_*.json` (title, cwd, archived, completedTurns, timestamps, `postTurnSummary`) | `SF/Claude.swift:73-195`, `CourierLocal.swift:25-76` | `ThreadShell` rows from `subscribeShell`: `title`, `projectId`, `status`, `archivedAt`, `latestRun*At`, `latestVisibleMessage`, `pullRequests`, `tags`, `pinnedAt`, `snoozedUntil`, `settledAt` (`OV2:2072-2151`). Projects carry `workspaceRoot` and `repositoryIdentity` (owner/name of the GitHub repo). | Key everything by `(environmentId, threadId)` and `projectId`, not by folder path. `repositoryIdentity` joins threads to Triage's repos for free. |
| O2 | "Running": a 2-hour heuristic plus app-running plus plugin presence `turn` | `SF/Claude.swift:140-147,1205-1231` | `status` (`idle, preparing, queued, starting, running, waiting, completed, interrupted, failed, cancelled, rolled_back`) and `activityRunStatus` (`OV2:2047-2051`) | It's exact, so delete the lease and presence logic. Use T3's attention rules (`T3:packages/shared/src/agentAwareness.ts:60-128`) as the base for "needs you". |
| O3 | Activity line from a 96 KB transcript tail and a hard-coded tool-name switch (Bash, Edit, Read, Grep…) | `SF/Claude.swift:343-409,593-632` | Turn items from `subscribeThread`: `command_execution{input,exitCode}`, `file_change{fileName,+/-}`, `file_search`, `web_search`, `dynamic_tool{toolName}`, `subagent`, `reasoning`, `assistant_message{streaming}` (`OV2:1595-1818`). Live command output: `subscribeCommandOutput`. | It works the same for every provider (Codex, Cursor and others), so the tool-name switch goes. Open a thread subscription only for working threads that are on screen or feeding a brief, and close it when the thread settles. The shell's `latestVisibleMessage` covers narration without one. |
| O4 | Todo progress from the last `TodoWrite` input | `SF/Claude.swift:396-403` | `todo_list{steps[{text,status}]}` and `plan.updated` (`OV2:1640-1646`) | Same for Claude, Codex, Cursor and Muse. Claude in T3 needs `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` (`T3:docs/user/providers-claude.md:97-102`). |
| O5 | Permission prompts: a `PermissionRequest` hook writes a note, and it ends when a `tool_result` or the approved Bash child process appears (libproc, `KERN_PROCARGS2`) | `SF/Forms.swift:446-463`, `ClaudeProcesses.swift` | `pendingRuntimeRequest{id,kind,blocking}` on the shell, and an `approval_request` item `{requestKind, prompt, reason, options[{decision,label,warning}]}` (`OV2:1690-1700,2053-2060`) | Exact start and end, from `runtime-request.updated`. **Fjord can now answer it** (§3, A4). |
| O6 | Questions (`AskUserQuestion`): the hook holds the form file for up to 24 h | `SF/Forms.swift:384-483` | `user_input_request{questions[{id,header,question,options[{label,description}],multiSelect,allowCustomAnswer,required}]}`, `pendingRuntimeRequest.kind == "user_input"` (`OV2:1329-1346,1647-1654`) | It works for every provider with structured questions (all except Cursor). Answers are keyed by question id, not by question text as the hook needed. |
| O7 | Plans (`ExitPlanMode`) through the same hook | `SF/Forms.swift:274-319` | `proposed_plan{planId, markdown}` plus shell `hasActionableProposedPlan` (`OV2:1633-1639,2115`). T3 denies `ExitPlanMode` so Claude stops and waits (`T3:apps/server/src/provider/Drivers/ClaudeAdapterV2.ts:9989-10006`). | T3's attention rules don't count a plan as needing you (it's not a push trigger), so Fjord must add `hasActionableProposedPlan` itself. |
| O8 | Unread: LevelDB `epitaxy-unread-v1`, `completedTurns` deltas, `lastFocusedAt` | `SF/Claude.swift:947-967`, `Agents.swift:441-465` | Per-thread `lastVisitedAt` watermark. Unseen = `lastVisitedAt` is null or older than `updatedAt` or the latest run's completion (`T3:packages/client-runtime/src/state/threadVisits.ts:93-135`) | Read state is shared with T3's own sidebar and the phone. Delete `LevelDB.swift`. |
| O9 | Background tasks: `/private/tmp/claude-<uid>/…/tasks/*.output` symlinks, an open-fd scan, `<task-id>` notices | `SF/Claude.swift:638-943` | Shell `pendingBackgroundTasks[]`, `subagent` items, `notification` items (`source: background_task|subagent|command|monitor`) (`OV2:1239-1282`) | "3 running" comes straight from the shell. |
| O10 | Your own messages, filtered out of the transcript | `SF/YourMessages.swift:21-57` | `user_message` items and messages with `role:"user"`, `createdBy:"user"` | No filtering needed. |
| O11 | "Result" text for the board (last 1,500 chars of assistant text) and project purpose from the README | `SF/CourierLocal.swift:79-112` | `latestVisibleMessage`, `GET …/threads/:id/transcript` | Keep the README purpose (it's Fjord's own). |
| O12 | Claude Code binary found inside the Claude app bundle | `SF/RouterStatus.swift:4-72` | Not needed for sessions. Fjord's own model calls still need a runner (§4). | — |
| O13 | Remote (Silo guest) sessions: guest transcripts, registry, presence and tasks read through `guest.files`, with `kill -0` for liveness | `SF/Guest*.swift`, `SiloGuestClient.swift` | A T3 server inside the computer (Linux or Apple Silicon Mac), reached as another environment. T3's own desktop-managed SSH downloads the server to `~/.t3/runtime` and port-forwards it (`T3:docs/user/remote-access.md:208-235`). | The same client code serves every machine: one more WebSocket per computer (§5). |
| O14 | Things nobody collects today: token use, Claude limits, branch, PR links | F1 §3 | `ProviderThread.contextUsage`, `ProviderTurn.tokenUsage`, provider `usageLimits` windows (session/weekly %, `resetsAt`) in `server.getConfig`, thread `branch`/`worktreePath`, `pullRequests[]` (`OV2:1074-1188`; `T3:packages/contracts/src/server.ts:264`; `providerUsageLimits.ts:13-50`) | New features (§6). |

## 3. Acting: everything Fjord does to sessions today

| # | Today (Claude) | Where | T3 command | Better behaviour, not 1:1 |
|---|---|---|---|---|
| A1 | **Your words into a session.** A signed relay file goes to Fjord's plugin, which calls `$.prompt.submit({asUser:true})`. Sleeping sessions are woken by a *carrier* session calling the app's `ccd_session_mgmt.send_message`, or by opening `claude://…/epitaxy`. There are 45/90/60 s waits and an "unsure" state. | `SF/RouterCarry.swift`, `RouterRun.swift:317-560`, `ClaudePlugin.swift` | `message.dispatch{commandId, threadId, messageId, text, context?, attachments, dispatchMode}`. The server stamps every client command `createdBy:"user"` (`T3:apps/server/src/ws.ts:2023-2026`), so your words arrive as yours by design. An idle thread resumes its provider session itself. | Delivery is proved by `{sequence}` and the `run.created`/`message.updated` events, so the "unsure" state goes. `commandId` = the operation's nonce, so a retry can't send twice. **While a thread runs, a routed message steers by default** (owner's decision), even though Claude's steering interrupts tool calls (`ClaudeAdapterV2.ts` capability `supportsActiveSteering`, "interrupts tools"). "Queue instead" is the explicit choice. A provider that can't steer (ACP agents) queues, and the entry says so. |
| A2 | **Cancel.** `abort-v1` cuts tool calls and aborts the turn, but "Claude Code has no way to take a submitted prompt back out" | `SF/RouterCancel.swift`, `ClaudePlugin.swift` (register 386-411) | Queued: `queued-run.cancel` takes it back for real. Running: `run.interrupt{runId, holdQueue?}`. Stuck: RPC `forceStopThread`. | "Change your mind" becomes real: a queued message can be **cancelled or edited** (`queued-run.edit{text}`), reordered (`queued-run.reorder`) or promoted to steer (`queued-message.promote-to-steer`) (`OV2:3226-3274`). "Edit and resend" turns into editing in place while it waits. |
| A3 | **Answer a question.** Write `forms/<key>.answer.json`; the hook prints `allow` + `updatedInput.answers` keyed by question text | `SF/Forms.swift`, `RouterMCP.swift:1085-1186` | `runtime-request.respond{requestId, answers:{<questionId>: value}, attachmentsByQuestionId?}`; dismiss with `thread.user-input.dismiss` (`OV2:3275-3290`) | It works for every provider. Questions that allow a custom answer also accept **images and files** per question (`T3:docs/user/question-attachments.md`). Pending requests don't survive a T3 restart (`pendingRequestsSurviveRestart:false`): show `expired`/`cancelled` plainly instead of offering a dead form. |
| A4 | **Permission prompts** are shown read-only ("only Claude can grant: open it") | `SF/RouterBriefView.swift:382,669` | `runtime-request.respond{requestId, decision: accept|acceptForSession|acceptAlways|decline|cancel, feedback?}`, only when `responseCapability.type == "live"` (`OV2:1205-1230`; `providerPolicy.ts:58-77`) | Offer exactly the buttons in the request's `options`, with any `warning` shown. A typed message means **decline with your words as feedback**, which is T3's own rule (`T3:docs/user/permission-modes.md:51-53`). Never infer a yes from words: a button is the only yes. |
| A5 | **Plans.** The hook prints `allow` (approve) or `deny` with Claude's rejection words; the brief offers "Yes, auto-accept / Yes, manually / No" | `SF/Forms.swift:311-319` | Implement = `message.dispatch` with `sourcePlanRef{threadId,planId}`, which is what T3's client sends (`T3:packages/client-runtime/src/operations/commands.ts:751-779`). Mode: `thread.interaction-mode.set{default}` and `thread.runtime-mode.set`. | "Yes, auto-accept" sets `auto-accept-edits` (or `auto`) and then implements; "Yes, manually" sets `approval-required` and then implements; "No" plus your words is a normal message, still in plan mode. |
| A6 | **Start new work.** A local clone via `claude://resume` import; claude.ai via its coordinator; an SSH computer needs your Send in the Claude app | `SF/InboxActions.swift`, `Courier*`, `GuestDesktopStart.swift` | `orchestration.launchThread{projectId, title, generateTitle, modelSelection, runtimeMode, interactionMode, workspaceStrategy: root|worktree{baseRef,branch,startFromOrigin}|existing_worktree, initialMessage}` (`OV2:3632-3662,654-671`) | **Zero clicks on any machine**, a computer included. Pick a worktree by default for unattended Triage work so it can't collide with your own checkout. Choose `runtimeMode` per category action (it replaces "runs with your Claude Code permission settings, unattended"). A clone with no T3 project gets one through `projects.mutate` (`T3:packages/contracts/src/environmentHttp.ts:736`). |
| A7 | Open in Claude: `claude://claude.ai/epitaxy/<id>`, or Chrome for cloud threads | `SF/Claude.swift:94-98`, `RouterBriefs.swift:577-596` | `t3code://threads/<env>/<thread>` | "Open in T3". Ship Fjord's own glyph rather than reading another app's bundle. |
| A8 | Mark read and archive are Fjord-local (`briefs.db` marks) | `SF/RouterBriefEngine.swift:116-130` | `thread.visit{visitedAt}`, `thread.mark-unread`, `thread.archive/unarchive`, `thread.settle`, `thread.snooze{until}` (`OV2:2895-3050`) | Mark read becomes `thread.visit` and syncs everywhere. Archive is real and still happens only on an explicit press. Keep `briefs.db` only for brief-entry marks such as "told" and "notified", which T3 has no notion of. Add **Snooze**: T3 wakes a snoozed thread on a new request or a failure. |
| A9 | Labels and icons stored per session id | `SF/Agents.swift:25-74` | `thread.tag.set{tag,tagged}` (≤64 chars) | Labels become T3 tags so both apps agree. Icons stay Fjord-local, keyed by thread id. |
| A10 | `@` pills appended as fenced blocks (`<github-content untrusted="true">`) after your words | `SF/RouterPointer.swift:196-270`, `UntrustedText.swift` | `context: {version:1, records:[…]}`, referenced inline as `[label](t3-context://v1/<kind>/<id>)`. Records of an unknown kind keep a JSON payload; T3 projects them into a `<t3_context>` envelope with `<` escaped so captured text can't forge a record. A `thread` kind exists for mentioning another thread. (`T3:packages/contracts/src/composerContext.ts:200-330`; `docs/internals/composer-context-references.md`) | Your words stay exactly yours, and the GitHub item, category or thread travels as typed context. T3's UI shows it as a chip and the agent gets structured, escaped data. Only referenced records reach the agent, so place the reference where the pill sits. |
| A11 | Turning the Router on edits `~/.claude/settings.json` (with backup), writes `~/.claude/hooks/fjord-form.sh`, installs `fjord@fjord`, and needs `/reload-plugins` in open sessions | `SF/Forms.swift:608-803`, `ClaudePlugin.swift:1071-1219`, `Router.swift:131-290` | Mint a token. That's all. | Fjord writes nothing into any agent's config. The README's install caveats go. |
| A12 | Rename, regenerate title | — | `thread.metadata.update{title | regenerateTitle:true}` | New, and cheap: "Rename" in the brief's panel. |
| A13 | Multi-mention send (⌘-click, one Return) | `SF/RouterView.swift:313-326` | One `message.dispatch` per thread, each with its own `commandId` | A refusing thread stays picked, as today. |

## 4. Fjord's own model calls

Today every call is a fresh `claude -p` through the Claude Code that ships inside the Claude app (`--tools "" --setting-sources "" --strict-mcp-config --no-session-persistence`, prompt on stdin):

| Call | Model | Where |
|---|---|---|
| Project brief, purpose, general lead | Haiku 5.5 | `SF/RouterBrief.swift:21-41`, `RouterBriefEngine.swift:468-655` |
| Router run (answers about Fjord, changes Fjord's settings through Fjord's MCP server) | Haiku, streaming | `SF/RouterRun.swift:84-205`, `RouterMCP.swift` |
| Where a message goes (without a key, Jev only orders the ask) | Sonnet 5.5 | `SF/RouterProjectDecide.swift:104-323` |
| New-project proposal reviser | Sonnet | `SF/RouterProjectProposal.swift:985-1111` |

**T3 can't run these for Fjord.** Its text generation does five fixed jobs (commit message, PR text, branch name, thread title, review guide) and has no RPC (`T3:packages/provider-core/src/server/textGeneration.ts:100-120`; no method in `rpc.ts:408-601`).

**What to do instead:**
1. **Now:** keep the one-shot runner but make it provider-neutral. Its inputs are a system prompt, stdin, a JSON schema, an optional MCP config and an optional stream. Runners: `claude -p` (the same flags T3 uses: `--json-schema --tools "" --strict-mcp-config --permission-mode dontAsk --settings {disableAllHooks:true}`, `T3:apps/server/src/textGeneration/ClaudeTextGeneration.ts:176-239`) and `codex exec`. Find the binaries the way T3 does: login-shell PATH, or the instance's configured path in T3 settings. Don't use the Claude app bundle.
2. **One fixed model per role (briefs, decider), chosen by eval.** There's no model picker in Fjord (owner, 2026-11-06). The routing measurements (95% right project, no wrong-project sends) were taken on Sonnet, so the candidates are measured on the same moments (§12).
3. **Router run, extended:** give it T3's **read-only** MCP surface (`t3_thread_list/read/search`, OAuth or a scoped token, read-only access level, `T3:docs/user/outside-agents.md`) next to Fjord's own `board`/`answer`/settings tools. Then "what did silo do today?" is answered from the threads themselves, and the Router still only talks.
4. **Later, if forking is acceptable:** see §7.1.

Jev (TypeSafe) is unaffected. Its inputs (titles, first message, a turn's final message) now come from T3 records instead of transcript heads (`SF/Jev.swift:318-331`, `Agents.swift:544-579`).

## 5. Computers (Silo) and remote work

> **Dropped for now (2026-11-08):** Fjord's Computers feature is removed outright while Silo is rewritten. Nothing below is built; this section is the old plan.

Today: the Claude app on the Mac runs Claude Code on the guest over SSH. Fjord writes `sshConfigs` into `~/.claude/settings.json` and installs a guest plugin, a Node form hook, a relay key and a pinned Node. It watches guest files through Silo, matches the session after **you press Send in the Claude app**, and can only answer questions and plans there (`F2-part-C`; `SF/GuestRouterInstaller.swift`, `ClaudeSSHSettings.swift`, `GuestDesktopStart.swift`).

On T3:
- **A computer runs a T3 server.** Silo's "agent tools" install `t3` and the chosen provider CLIs instead of Node plus Claude Code. Fjord mints a token on the guest with `guest.exec t3 auth session issue …` and reaches the guest's port through Silo's SSH alias (a forward). That last step is **unverified**: spike how `t3 serve` binds and how the forward is held.
- Everything in §2 and §3 then works there unchanged: zero-click starts, permissions, interrupts, queue edits.
- **Deleted:** `GuestRouterInstaller`, `GuestNodeRuntime`, `GuestRelayInbox`, `GuestForms`, `GuestTranscripts`, `GuestBackgroundTasks`, `GuestDesktopStart`, `GuestClock`, `ClaudeSSHSettings`, `PendingDesktopStart`, and the pending-disable and removal ledgers. `GuestCodeFolders` stays, since it's plain git.
- Alternative: T3's **linked environments** (beta flag `linkedEnvironmentsEnabled`). With it, the Mac's T3 can reach the computer's T3 over `/mcp` with a mode ceiling (`T3:docs/internals/remote.md` §Peer links), so an agent on the Mac can start work on a computer. Useful for agents, but Fjord should hold its own connection to each environment, because MCP gives no live stream.
- Auth on the guest is still the provider's own login on that machine (`T3:docs/user/remote-access.md:208-235`), exactly as today.

## 6. New things T3 makes possible (worth building, ranked)

1. **Answer permissions from the brief** (A4), with the provider's offered options, decline-with-words, and per-session "always" where offered.
2. **Real cancel, edit and reorder of queued messages** (A2). This is the "Change your mind" promise done properly.
3. **Every provider in one brief.** Codex, Cursor, OpenCode, Pi and the others are threads like Claude's. New threads use T3's default model, and Fjord offers no model or provider choice (owner, 2026-11-06). Gate actions on capabilities: Cursor has no structured questions or command approval, and ACP agents can't steer (T3-providers report, capability matrix).
4. **A thread that hit its limit says when it resumes** ("resumes by itself at 15:00", from `lastErrorClass:"usage_limit"`, `usageLimitResetAt`, `limitRecovery.autoResume`; `OV2:400-407,1447-1455`). That's thread information, so it belongs on the thread's entry. There are no account usage windows on the bar (owner, 2026-11-06). It replaces the old "stranded" entry, which can't happen in T3 because a dead process just resumes.
5. **Threads and PRs joined.** Each thread knows its `pullRequests[]` and `branchPullRequest`. Triage rows show the thread working on a PR, and the brief says "opened #123, checks failing". When Triage hands a PR to a thread, link it (`thread.pull-request.link`) and let T3 **watch** it (`thread.pull-request.watch`): T3 polls every 2 minutes and wakes the agent on failed or passed checks, new comments or reviews, and conflicts (`T3:apps/server/src/orchestration-v2/PullRequestWatchReactor.ts:43`). Triage then **skips** those facts for a watched PR, so the agent is never woken twice, and keeps its own triggers for issues, notifications and unwatched items.
6. **What finished, with proof.** A finished entry can show files changed (+/−) from checkpoints (`OV2:1388-1402`; `getTurnDiff`) and offer **Revert this turn** (`checkpoint.rollback`). It isn't instant-reversible, so it asks first.
7. **Snooze and settle** in the brief, matching T3's sidebar (A8). Fjord's "quiet" group becomes T3's settled set.
8. **Scheduled tasks in the brief.** `scheduledTasks.subscribe` shows recurring and webhook runs (`T3:apps/server/src/scheduledTasks`), so a nightly job that failed shows up like any thread.
9. **Context usage per thread** (`contextUsage`): a quiet hint when a thread nears auto-compaction.
10. **Phone parity for free.** Read state, archive, tags and answers are server state, so T3's mobile app and Fjord always agree.

## 7. Fork or upstream: only where it earns its keep

T3 is MIT, about 1M lines of Effect TypeScript, and "not actively seeking outside contributions" (CONTRIBUTING.md). AGENTS.md says "a large number of our users run forks". Keep any patch small and isolated:

1. **A generic text-generation RPC**, for example `textGeneration.run{system, prompt, jsonSchema, modelSelection}`. It would reuse T3's runners, provider auth, fallback on used-up windows and usage accounting. It removes Fjord's process spawning entirely and makes the brief writer follow T3's model settings. About one file per side; the runners already exist.
2. **Question and approval payloads in the shell summary.** Add `questions`/`prompt`/`options` to `pendingRuntimeRequest` (`OV2:2053-2060`). Then the brief never opens a thread subscription just to show what a thread asks: one stream covers every needs-you entry.
3. *Not worth forking:* outbound webhooks (the streams are better), a plugin system (Fjord is outside the app), or a Swift SDK (export JSON Schema with Effect's `JsonSchema` in a build step instead).

Start without a fork. Measure how many thread subscriptions the brief actually holds before doing (2).

## 8. What stops working, and what to do about it

| Gap | Today | On T3 | Recommendation |
|---|---|---|---|
| claude.ai Projects and cloud threads (the Router's only send target since 2026-11-04) | Courier: Chrome extension, native host, `router.sock`, `router.db`, setup checklist | Nothing (T3-providers §7: `claude.ai` appears only as install URLs, an OAuth field and MCP name rewriting) | **Drop it.** T3 projects replace claude.ai projects. The coordinator's job (picking or starting a thread) is Fjord's decider plus `launchThread`. T3 Connect and the phone app replace reaching claude.ai from anywhere. This also removes the recorded terms risk (`docs/design/projects-internals.md:6`; `router-redesign.md:99-110`). |
| Project goal and instructions (claude.ai settings) | Set through the page's settings dialog | T3 projects have no instructions field (`T3:packages/contracts/src/orchestrationProject.ts:6-24`) | Instructions live in the repo (`AGENTS.md`/`CLAUDE.md`, read by the agents). The goal becomes the brief's "purpose", which Fjord already keeps. No per-project system prompt. |
| Folder pre-approval, add repo | claude.ai tools | Not needed: work runs locally in the project's own folder, and the repo comes from `git remote` (`repositoryIdentity`) | Delete. |
| Sessions in the Claude desktop app's Code tab | Followed live | Invisible to T3 | Nothing. The owner already imported them once, and it's a full switch with no sync (owner, 2026-11-06). Fjord has no import step. |
| Terminal `claude` | Not followed today either (README) | Same | No change. |
| Mobile push | — | Only through T3 Connect, not addressable by other programs (`T3:docs/user/mobile-notifications.md`) | Fjord's native banners come from the shell stream. Decide who notifies on the Mac (§10). |
| Contract stability | Private formats, already flagged in the UI ("The app's session format changed") | Private TypeScript, but additive: protocol gate, capability flags, unknown events skipped (`OV2:1821-1842,3851-3882`) | Pin to protocol 2, decode leniently, test against T3's replay fixtures (`OV2:4279-4323`, `T3:apps/server/src/orchestration-v2/testkit/fixtures`). Keep a link-status line like `ClaudeLinkStatus`, reworded. |
| Pending requests after a T3 restart | Hook held them up to 24 h | Not resumable (`responseCapability: not_resumable`) | Show it plainly, and offer "Open in T3" or "send words instead" when the capability is `message`. |
| Models: Haiku and Sonnet through the Claude app's Claude Code | Works | No RPC | §4. |

## 9. Not verified yet (spike before building)

**Run live on 2026-11-06: see [`t3-research/S1-spikes.md`](t3-research/S1-spikes.md).** Items 1–5, 7 and 8 are settled there, with corrections: capability flags live in the thread projection's `providerSessions[].capabilities`, not in `server.getConfig`, so gate on the driver until a session exists; Claude's approval requests carry no `options`, so offer T3's fixed decision list; a question's id is its text for Claude; a declined permission's feedback becomes a user message and the agent may retry with a new request; steering is `start_immediately` + `deliveryIntent:"steer"`, and Claude's steer stops the running tool about 5 s later; archiving drops a thread from the shell stream. Item 6 (a guest's T3 through Silo) is still open. The list below is kept for its history.

1. The Effect-RPC exchange over a live socket, Ack behaviour included. Read from Effect's source, not run.
2. Minting the token. Not run, because it writes to T3's auth database. Needs your go-ahead.
3. The answer value shape for multi-select questions (`ProviderUserInputAnswers = Record<string, unknown>`, `T3:packages/contracts/src/providerPolicy.ts:79`): check T3's composer.
4. Whether T3's composer also switches the interaction mode to `default` when implementing a plan.
5. The attachment upload format (`attachments.createUploadUrl`).
6. Reaching a guest T3 server through Silo (`t3 serve` bind address, forward, token on the guest).
7. Where provider capability flags reach a client (`server.getConfig` providers), for gating buttons.
8. How many `subscribeThread` streams the brief would hold at peak on real data (448 threads here). This decides §7.2.

## 10. Decisions (settled 2026-11-06)

1. The claude.ai Courier is dropped, and so are claude.ai Projects (§12).
2. Fjord is the only notifier on the Mac (turn T3 desktop's off).
3. Words for a running thread steer by default; queueing is explicit.
4. Brief and decider models: decided by eval, Codex gpt-6-luna against Claude (§12).
5. Stock T3, no fork.
6. No model, provider or usage-window features in Fjord. Thread information is welcome.

## 12. Routing on T3: Fjord decides again

With claude.ai Projects gone, no coordinator picks the thread, so Fjord's decider does. It chooses an existing T3 thread, a new thread in a project, or Fjord itself. The last measurements at session level are in `docs/design/router-redesign.md` ("Routing on real moments"): on 62 realB moments, Sonnet with rich context got 79% session top-1 and 95% project top-1 with no wrong-project sends, and new work was weak (8 of 19). Work in progress:
- the decider's candidates and context rebuilt from T3 records (shell rows, latest visible message, todos, PRs, branch);
- candidate models on the same moments: Sonnet, Haiku, Codex gpt-6-luna, with Jev first;
- the brief writer: Haiku against luna;
- results go in `t3-research/` and are summarized here.

Unattended Triage actions ("Send to the Router") are told they are automated and new work by default: a follow-up is taken only at 0.95 (`actionFollowUpBar`, unmeasured; the live logs will tell), below it a new thread starts in the project. The item's repository, when exactly one T3 project has it (`repositoryIdentity`), is that project when the model's is missing or unsure, and a different model project asks.

**Jev-led path, in shadow (2026-11-08, [`E5-jev-wrapper.md`](t3-research/E5-jev-wrapper.md)).** `JevPath` (RouterJevPath.swift) ports E5's design to ship: one Jev call on `jev-1.14.0` ranks the places (threads and a new thread per project, no intents, E5's richer `now` lines) and asks `ans` and `nx_choice` of the 3 most recent idle threads, plus an untested "for Fjord itself?" check; code adds recency and a BM25 against each thread's last reply and fuses the 8 features with the all-182 refit weights. It sends without Sonnet only at fused P ≥ 0.90 to an idle thread, with Jev's route mass on running threads under 0.25 and the Fjord check under 0.30; never for an unattended action. Until the log has about 200 decisions with no wrong send it runs in shadow (Settings › T3 Code › "Let Jev send when sure", off): in parallel with Sonnet, never delaying it, its answer, features, request hash, latency, agreement with the final place and the focus signals logged per decision. Without an Anthropic key its fused ranking orders the ask. The composer previews the same pick at P ≥ 0.90 after a 600 ms pause (≥ 12 characters): a chip and a dashed mark on the brief, a click for its top 3 places, Esc to wave it off, and the answer reused when the same words are sent on the same board; a decision elsewhere is logged as a preview miss. Refit: `evals/router/t3/refit.py`.

Fable's advice is in [`t3-research/R1-routing-advice.md`](t3-research/R1-routing-advice.md). Its key fact: 439 of T3's 455 threads are imports stamped with the import time, so T3's database can't rebuild past boards. The 182 Claude-transcript moments stay the benchmark, rendered in T3's shell shape, until live decision logs have about 200 moments.

**Model results (2026-11-06):**
- **Decider: Sonnet stays** ([`E1-decider-models.md`](t3-research/E1-decider-models.md)). On the 182 moments:
  - Sonnet: 92% project, 76% thread, 47% sent, 1.6% wrong-thread sends per message.
  - Haiku: 85% project, 63% thread, 3.8% wrong-thread sends.
  - Codex gpt-6-luna: 82% project, 55% thread. Its confidence is badly calibrated: at 0.8 it sends 81% of messages and 28% go wrong, and at equal coverage 9.9% go wrong.
  - None meets Fable's gates. Sonnet's gaps (wrong-thread 1.6% against 1%, send rate 47% against 50%, new work 6/19, 1 wrong-project send) are to be fixed in the board and the bar, not the model.
  - Latency is ~5 s, of which 2.3 s is `claude -p` starting up. A direct API call is the way to the 2 s gate.
- **Briefs: Haiku stays** ([`E2-brief-models.md`](t3-research/E2-brief-models.md)). Opus judged blind and pairwise:
  - Haiku beat luna 15:10 and luna at low effort 19:6. There were no hallucinations in any model's output.
  - luna wins the one-line purpose (6–7 of 7), but drops links and sometimes leaves out a thread that waits on you.
  - Haiku's weakness is verbosity (4.7 loose ends per brief against 1.7). Tighten its loose-ends rule.
  - 2 of 25 briefs on each model went past Fjord's 30 s timeout.

## 11. What gets deleted

`Claude.swift` (session/transcript/LevelDB/tasks parts), `ClaudeProcesses`, `ClaudeLinkStatus` (reworded), `LevelDB`, `Peers`, `ClaudePlugin` + `Resources/ClaudePlugin`, `Forms` (hook), `RouterCarry`, `SessionControl`, the relay parts of `RouterRun` and `RouterMCP` (`prepare`/`approveSend`), `RouterStatus`, `ClaudeSSHSettings`, every `Guest*` file except `GuestCodeFolders`, every `Courier*` file, `NativeHost*`, `RouterCourier*`, `RouterCourierSetup`, `poc/router/extension`, `ClaudeMark`'s and `Fonts`' reads of `Claude.app`, the `--form-hook`/`--native-host`/`--courier-test`/`--claude` flags, `scripts/migrate-to-fjord.sh`, and about 55 test files that pin Claude formats (F3 report §5).
Kept, with T3 inputs: `RouterBrief*`, `RouterDispatcher`, `RouterProjectDecide`, `RouterFormReply` (Jev picks an option id, then `runtime-request.respond`), `RouterDecisions`, `RouterDrawer`, `RouterPointer` (emitting context records), `SessionFence`/`UntrustedText` (still used for Fjord's own model prompts), `Jev*`, all of Triage, Silo, the window, bar and palette, `Demo`/`DemoBriefs` and the shots (they run on Fjord's own types).

## Sources

Research reports with full citations, in [`t3-research/`](t3-research/): `F1-observation.md` (what Fjord reads, every model call), `F2-part-A..D.md` (plugin and hook, claude.ai Courier, Silo computers, other couplings), `F3-features.md` (feature catalog, UI, tests, evals), `T1-model-api.md` (T3 data model and client API), `T2-automation.md` (MCP, CLI, scheduling, PRs, extensibility), `T3-providers.md` (providers, how T3 runs Claude). Facts used above that matter most were re-read in source by hand: message context, client command provenance, Effect-RPC messages, RPC scopes, `t3 auth session issue`, import dedupe, scratch projects, thread deep links, project fields.

**Decider transport (2026-11-07):** the Sonnet decider calls the Anthropic Messages API directly with the owner's API key, kept in Keychain as `fjord-anthropic-key`, instead of going through `claude -p`. A tiny call made with it takes about 1.1–1.3 s in total, where `claude -p` needs about 2.3 s just to start. Briefs, purposes, leads and the Router run stay on `claude -p` (the subscription), because nobody waits on them.
