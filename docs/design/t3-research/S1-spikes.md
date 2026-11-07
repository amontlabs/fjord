# S1: live spikes against T3 Code v0.1.7

Run 2026-11-06 against the local server (`127.0.0.1:3773`, protocol 2), with a scoped token (`orchestration:read` + `orchestration:operate`, 30 d, label `Fjord-spike`) kept in Keychain only (`fjord-t3-token`). All runs used Claude Haiku 5.5 in 13 throwaway threads in the "No project" scratch project, now archived. No existing thread of the owner's was touched.

Client and raw frames (they contain the owner's real data from the shell snapshot, so they stay out of the repo): `/private/tmp/claude-501/-Users-polarzero-code-projects-lookout/93627f13-f8e2-4df4-9cdf-5dece64b1da9/scratchpad/t3spike/` (`lib.mjs` is the client; `a1`..`j` are the spikes; `*.frames.jsonl` are the exact frames).

Source paths: `T3:` = `~/code/research/t3code`; `OV2` = `T3:packages/contracts/src/orchestrationV2.ts`.

## Surprises (things that contradict or change the map)

1. **`dispatchCommand` payload is the command itself, not `{command}`.** `Rpc.make(dispatchCommand, {payload: OrchestrationV2Command})` (`T3:packages/contracts/src/rpc.ts:1722-1726`; `ws.ts:1999` handler takes `command` directly). Frame: `{"_tag":"Request","id":"5","tag":"orchestration.dispatchCommand","payload":{"commandId":"…","type":"thread.visit","threadId":"…","visitedAt":"…"},"headers":[]}`. Map §1 says `dispatchCommand{command}`; wrong.
2. **Clients MUST Ack chunks.** Without `Ack`, the server sends the first chunk of a stream and then stalls (Effect's per-request latch, `T3:.repos/effect/packages/effect/src/rpc/RpcServer.ts:474-499`). Observed: with no Ack, 12 s of live traffic (a thread launched meanwhile) produced zero further chunks; a late Ack released one coalesced chunk (the latest row per thread, not every intermediate update). So Ack every `Chunk`, immediately.
3. **Provider capability flags are NOT in `server.getConfig`.** `getConfig.providers[]` has `driver, enabled, installed, status, auth, models[], slashCommands, skills, usageLimits…` but no steering/question flags. They live in each thread's projection: `providerSessions[].capabilities` (`turns.supportsActiveSteering`, `turns.activeSteeringInterruptsTools`, `planning.supportsStructuredQuestions`, `approvals.*`…), and only exist once a provider session was attached (after the first run). The shell rows have none. Gating buttons on a brand-new thread must be by driver, until a session exists. Also: `server.getConfig` works with only `orchestration:read` and returns the owner's provider account email and workspace id (`auth.email`), so don't log it.
4. **There is no "steer" `dispatchMode` that the T3 client uses.** T3's own composer sends `dispatchMode:{type:"start_immediately"}` + `deliveryIntent:"steer"|"auto"|"restart"` and lets the server resolve it (`T3:packages/client-runtime/src/operations/commands.ts:759-781`; `T3:apps/server/src/orchestration-v2/CommandPolicy.ts:92-183`). The explicit `steer_active{targetRunId}` also works and behaves identically. `restart_active` is rejected for Claude.
5. **Claude steering interrupts the running tool, with a ~5 s lag.** The user message appears in 50-70 ms, but the running Bash item flips to `failed` about 5.0 s after the steer, then the agent answers (verified twice). Same run id, one run, no new `run.created`.
6. **A declined permission's feedback becomes a user message**, and the agent may simply retry the command (Haiku did, producing a second approval request in the same run). A decline is not a stop; a second `runtime-request.respond` must target the new request id.
7. **`approval_request.options` is absent for Claude command approvals** (`options` is optional, `OV2:1698`). Fjord can't render provider-given buttons there; fall back to the fixed decision list `accept, acceptForSession, acceptAlways, decline, cancel` (`T3:packages/contracts/src/providerPolicy.ts:58-65`) and only offer those the shell/request allows.
8. **`approval-required` does not gate read-only commands.** `date` ran with no approval. A write (`echo hi > f`) did prompt.
9. **A question's `id` is the question text for Claude** (no stable id): `questions[0].id = "Which two of the three colors do you choose?"`. Options have `label`, `description`, and no `value`, so the answer value is the label.
10. **The shell snapshot arrives as two chunks** (the second has `threads:[]`, an extra `resolvedRepositoryIdentityRoots`, and the same `snapshotSequence`); `snapshot` items recur later with only projects (repo-identity updates). Treat every `snapshot` as a merge of projects and threads, never as a reset. `OV2:2230-2262` lists `synchronized` too (only with `requestCompletionMarker`).
11. **Shell `status` is `idle` for almost everything** (455 of 459). Imported (v1) threads are `idle` with `latestRunId:null`, 439 of 443 listed threads are `v1_import` and have no T3 run history. Peak-concurrency estimates therefore have to use `latestUserMessageAt` (see 9.8).
12. **Archive removes the thread from the shell stream** (`thread.removed{location:"active"}`); archived rows come from `orchestration.getArchivedShellSnapshot`.
13. **Thread events are named `run.updated` / `run-attempt.updated` (plus `run.created` only for queued runs).** A launched thread's first run is announced by `turn-item.updated`/`run.updated status:"starting"`, not `run.created`.
14. **Mode changes restart the provider session:** `thread.runtime-mode.set` emitted `provider-session.detached` (next run respawns the session).
15. **Each launched thread gets its own scratch directory** (`~/.t3/scratch/<date>-<prompt-slug>-<id8>`, run `workspacePreparation: existing_worktree`) even with `workspaceStrategy:{type:"root"}` in "No project". The spikes left 13 small dirs there (one holds `spike.txt`/`hello.txt`).

## §9.1 Effect-RPC over a live socket: VERIFIED

- `GET /.well-known/t3/environment` (no auth) returns 200 with `environmentId`, `serverVersion:"0.1.7"`, `orchestrationProtocolVersion:2`, `databaseMigration:79`, `capabilities{…}` (e.g. `threadForceStop`, `threadSnooze`, `threadVisitedTracking`, `fileAttachments.maxUploadBytes:52428800`).
- `GET /ws` with a bad token and no protocol query: **426**. With `?orchestrationProtocol=2` + `Authorization: Bearer` header: upgrade OK. Node's global `WebSocket` accepts `{headers}` (undici), no query token needed.
- Frames (JSON text, one message per frame, no batching seen):
  - out `{"_tag":"Request","id":"1","tag":"orchestration.subscribeShell","payload":{},"headers":[]}` (ids are decimal strings)
  - in `{"_tag":"Chunk","requestId":"1","values":[{"kind":"snapshot","snapshot":{schemaVersion:2,snapshotSequence:39055,threads:[455],archivedThreads:[],projects:[7]}}, …]}`
  - out `{"_tag":"Ack","requestId":"1"}` after each Chunk
  - out `{"_tag":"Interrupt","requestId":"1"}` → in `{"_tag":"Exit","requestId":"1","exit":{"_tag":"Failure","cause":[{"_tag":"Interrupt","fiberId":…}]}}`
  - unary: in `{"_tag":"Exit","requestId":"2","exit":{"_tag":"Success","value":{…}}}`; failure `exit:{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"OrchestrationV2DispatchCommandError","commandId","commandType","message","detail"}}]}`.
  - `Ping` → `Pong` works (client-initiated; **the server never pings**, 15 s idle saw none). Effect's client pings every 5 s by default (`RpcClient.ts:1451-1456`); Fjord should ping and treat a missing Pong as a dead socket.
- Shell items: `snapshot`, then `thread.updated{sequence,location:"active",thread:<whole ThreadShell>}`, `thread.removed{sequence,location,threadId}` (and `project.*`). Whole-row upserts, coalesced per thread under backlog.
- Thread stream (`orchestration.subscribeThread {threadId[,afterSequence]}`): first value `{"kind":"snapshot","snapshotSequence":N,"projection":{thread,runs,attempts,nodes,subagents,providerSessions,providerThreads,providerTurns,runtimeRequests,messages,plans,turnItems,checkpointScopes,checkpoints,contextHandoffs,contextTransfers,visibleTurnItems,updatedAt}}`, then `{"kind":"event","sequence":N,"event":{id,threadId,runId,nodeId,providerInstanceId,occurredAt,type,payload}}`. Chunks hold 1-5 values.
- Reconnect (`afterSequence`):
  - Shell, `afterSequence=<base>`: server replays only the changed rows (a `snapshot` with `threads:[]` + projects, then `thread.updated` rows) and no full snapshot. `afterSequence=5` (too old): full snapshot (462 threads).
  - Thread, `afterSequence=39310`: 22 `event` items (#39311…#40781), no snapshot. `afterSequence=40000`: 5 events. `afterSequence=99999999` (ahead of head): a fresh snapshot. No `afterSequence`: snapshot only.
- Token scopes: `server.getConfig` and `server.probe` (`{}`) succeed with read scope (`T3:apps/server/src/auth/RpcAuthorization.ts:63-64`).

## §9.2 Token: VERIFIED

`~/.t3/bin/t3 auth session issue --scope orchestration:read --scope orchestration:operate --label Fjord-spike --ttl 30d --token-only` prints the token on stdout (the CLI is `~/.t3/bin/t3`, a wrapper over the app's bundled server; it is not on PATH). `--ttl` takes `5m`, `1h`, `30d`. Session shows in `t3 auth session list` as `subject: cli-issued-session, client: Fjord-spike | bot`. `t3 auth session revoke <id>` works (it prints a harmless Electron `node_init` error line). I minted three tokens by mistake (a piped `tail` swallowed output), revoked the two unused ones; one session `b1e8e41a-…` remains (expires 2026-12-06), the one in Keychain. Revoke it when the spike is done.

## b. launchThread and dispatch latency: VERIFIED

`orchestration.launchThread` payload (fields from `OV2:3632-3662`, verified live):
```json
{"commandId":"<uuid>","creationSource":"mcp","threadId":"<uuid>","projectId":"49919390-…","title":"…","generateTitle":false,
 "modelSelection":{"instanceId":"claudeAgent","model":"claude-haiku-5-5"},"runtimeMode":"full-access","interactionMode":"default",
 "workspaceStrategy":{"type":"root"},"initialMessage":{"messageId":"<uuid>","text":"…","attachments":[]}}
```
Result: `{threadId, projection:{…}, resumed:false, sequence:39294}`.
Latencies (client clock; several runs agree):
- launch RPC returns in **7-13 ms**.
- first thread events (`turn-item` "Preparing workspace", `run.updated starting`) **~10-20 ms** after the request; `run.updated running` ~20 ms; provider session attached ~25 ms.
- shell `thread.updated status:"running"` ~60 ms.
- first model output: ~2.0 s (Haiku, one-word answer); completion events (`run.updated waiting` → `completed`) at ~2.07 s.
- `message.dispatch` returns `{sequence}` in 4-20 ms, and its `message.updated` event arrives within ~50-60 ms.
`message.dispatch` needs `createdBy:"user"` and `creationSource` in the body (schema `OV2CreationFields`); the server overrides provenance to `user` regardless (`T3:apps/server/src/ws.ts:2023-2029`).

## c. Steering, queueing, cancel, edit, interrupt: VERIFIED

Long tool used: `python3 -c "import time; time.sleep(40)"` (a bare `sleep` is blocked by Claude Code and fails instantly, so don't use it as a test tool).

| Mode sent while a tool runs | Result |
|---|---|
| `start_immediately` + `deliveryIntent:"steer"` | OK. User message at +60 ms, same run; the running command became `failed` ~5.0 s later (interrupted), agent then answered the steered text. |
| `dispatchMode:{type:"steer_active",targetRunId}` | Identical. |
| `deliveryIntent:"auto"` | Not run live; source: running provider turn + `supportsActiveSteering` → `steer_active`, else queue (`CommandPolicy.ts:140-183`). |
| `queue_after_active` | OK. Immediately emits `run.created` (queued, `queuePosition:1`) and `message.updated`; the first run finishes untouched (tool completes in 40 s, `FIRSTDONE`), then run 2 starts and answers. |
| `restart_active{targetRunId}` | **Rejected**: `OrchestrationV2DispatchCommandError message:"Claude cannot redirect an active run. Stop it first, then send the message."` (`UserFacingErrors.ts:55`). |

Capability flags for Claude: `turns.supportsActiveSteering:true`, `activeSteeringInterruptsTools:true` (`ClaudeAdapterV2.ts:405-406`), `supportsSteeringByInterruptRestart:false`, `supportsQueuedMessages:true`.

Queue control (single thread, tool running):
- `queue A`, `queue B` → two `run.created`, `status:"queued"`, `queuePosition` 1 and 2, each with `userMessageId`.
- `queued-run.edit {threadId, runId, text}` → `{sequence}` in 5 ms, `message.updated` with the new text, and the edited text is what the agent later received ("EDITED").
- `queued-run.cancel {threadId, runId}` → `run.updated status:"cancelled"`, `run-attempt.updated cancelled`.
- `run.interrupt {threadId, runId, reason, holdQueue:true}` → `run_interrupt_request` item, tool `command_execution interrupted` ~0.7 s later, `run.updated interrupted`; the next queued run stays `queued` (held). `queue.resume {threadId}` then started it (`starting` → `running` in ~10 ms).
- Not exercised live: `queued-run.reorder`, `queued-message.promote-to-steer`, `forceStopThread`.

## d. Structured multi-select question: VERIFIED

Prompt asked Haiku to use AskUserQuestion. Events: `turn-item.updated dynamic_tool running AskUserQuestion`, `runtime-request.updated`, and `turn-item.updated user_input_request status:"waiting"`.
```json
{"type":"user_input_request","requestId":"runtime-request:provider:claudeAgent:…:native-request:toolu_…:<uuid>",
 "questions":[{"id":"Which two of the three colors do you choose?","header":"Colors","question":"Which two of the three colors do you choose?",
   "options":[{"label":"Red","description":"Choose red"},{"label":"Green","description":"Choose green"},{"label":"Blue","description":"Choose blue"}],"multiSelect":true}]}
```
`runtime-request.updated` payload: `kind:"user_input"`, `status:"pending"`, `responseCapability:{type:"live",providerSessionId}`, `createdAt`, `resolvedAt:null`.

Answer shape, from T3's composer: `answers: Record<questionId, string | string[]>`; multi-select is `string[]` of option values (`option.value ?? option.label`), single is a string, a custom answer is a free string (`T3:packages/client-runtime/src/state/pendingUserInput.ts:60-90`, `usePendingThreadRequests.ts:299-340`). Sent:
```json
{"commandId":"…","type":"runtime-request.respond","threadId":"…","requestId":"<request id>","answers":{"Which two of the three colors do you choose?":["Red","Green"]}}
```
→ `{sequence:40345}` in 6 ms; request `status:"resolved"`, item `completed`, and the agent replied **"GOT: Red, Green"** (both answers received).
Shell `pendingRuntimeRequest` is `{id,kind,createdAt,blocking:true}` only (seen for the command request; the question was answered within 25 ms so no shell row was seen, but the shape is the same field). No question text in the shell, so the brief needs a thread subscription to show it (confirms map §7.2).

## e. Permission prompt: VERIFIED

Thread launched with `runtimeMode:"approval-required"`. For `echo hi > spike.txt`:
- item `approval_request status:"waiting"`: `{requestId, requestKind:"command", prompt:"echo hi > spike.txt"}`; no `options`, `reason` or `warning` keys for Claude.
- `runtime-request.updated kind:"command" status:"pending" responseCapability:{type:"live",…}`.
- shell row meanwhile: `status:"running"`, `pendingRuntimeRequest:{id,kind:"command",createdAt,blocking:true}`. Status stays `running` (not `waiting`).
- decline: `{type:"runtime-request.respond",threadId,requestId,decision:"decline",feedback:"Do not run it now. Just reply with the single word DECLINED."}` → ok in 7 ms. Effects: the request item becomes `cancelled`, **a `user` message with the feedback text is created** (`createdBy:"user"`), the command item `failed`. Haiku then ignored the feedback and retried the command: a **new** `runtime-request` (new `toolu_…` id) went pending in the same run.
- A second message sent while that approval was open was queued (run 2).
- Responding to the old, resolved request: `Failure … "Runtime request … is resolved."` (clean error, `detail` repeats it).
- accept: `{decision:"accept"}` on the pending request id → ok in 2 ms; item `completed`, command ran in ~420 ms, the run finished; the queued run then started and asked again (`approvals` are per tool call). `acceptForSession` / `acceptAlways` not tried.
- Reads (`date`) were not gated in `approval-required`.

## f. Implementing a proposed plan: VERIFIED (§9.4)

Source (what T3's own client does for "implement here", empty draft): `T3:apps/web/src/components/chat/useProposedPlanSend.ts:176-207` calls `persistThreadSettingsForNextTurn` (`T3:apps/web/src/components/ChatView.tsx:2027-2090`), which dispatches, only if they differ, `thread.runtime-mode.set` and **`thread.interaction-mode.set{interactionMode:"default"}`**, then `startThreadTurn` → `message.dispatch` with `text = "PLEASE IMPLEMENT THIS PLAN:\n" + markdown.trim()` (`T3:apps/web/src/proposedPlan.ts:53-58`), `sourcePlanRef:{threadId,planId}`, `deliveryIntent:"auto"`, `dispatchMode:start_immediately` (`commands.ts:733-781`). Typed text instead of an empty draft keeps `plan` mode and sends the text as a refinement (`proposedPlan.ts:60-78`). "Implement in a new thread" does `thread.create` + the same dispatch (`useProposedPlanSend.ts:300-345`).

Live (plan-mode thread, `approval-required`): the agent called `ExitPlanMode`; T3 emitted `plan.updated`, `turn-item proposed_plan` (completed), and `ExitPlanMode` ended `failed` (T3's deny) while the run finished normally. `projection.plans[]` = `{id,threadId,runId,nodeId,status,kind,markdown}`; the plan item carries `planId` and `markdown`. Shell `hasActionableProposedPlan` went `false → true` when the plan arrived and back to `false` after implementing. Then I sent, in order: `thread.runtime-mode.set auto-accept-edits` (also emitted `provider-session.detached`), `thread.interaction-mode.set default`, and `message.dispatch` with `sourcePlanRef` → run 2 created the file; thread ended `interactionMode:"default"`, `runtimeMode:"auto-accept-edits"`. Confirms map A5.

## g. Where capability flags reach a client (§9.7): PARTLY (location differs)

- `server.getConfig` (`{}` payload, read scope) returns `environment, auth, cwd, keybindings, issues, providers[], availableEditors, remoteOpenTargets, directEndpoints, observability, settings, shell*/thread* capability booleans, scratchWorkspaceRoot, newProjectsRoot`. `providers[]` item keys: `instanceId, driver, displayName, continuation, showInteractionModeToggle, reportsContextWindow, setup, enabled, installed, version, status, auth, checkedAt, models[], slashCommands, skills, workspaceSnapshots, usageLimits, versionAdvisory, compatibilityAdvisory, updateState`. Here: codex (8 models) and claudeAgent (13 models) `ready`; cursor, grok, opencode, antigravity, fx, kiro, muse, pi `disabled`.
- Real capability flags are `providerSessions[].capabilities` in `getThreadProjection`/the thread snapshot (`OV2:270-345`), e.g. for Claude: `turns{supportsInterrupt:true, supportsActiveSteering:true, activeSteeringInterruptsTools:true, supportsSteeringByInterruptRestart:false, supportsQueuedMessages:true}`, `approvals{supportsCommandApproval:true, supportsFileChangeApproval:true, approvalCallbacksAreLiveOnly:true}`, `planning{emitsProposedPlan:true, emitsTodoList:true, supportsStructuredQuestions:true}`, `sessions.pendingRequestsSurviveRestart:false`. Static per driver in the adapters (`ClaudeAdapterV2.ts:405,439`; `CodexAdapterV2.ts:261,294`; Cursor `supportsStructuredQuestions:false`, `supportsActiveSteering:false`).
- Server-side routing already uses them (`resolveDeliveryIntent`, `CommandPolicy.ts:118-183`), so Fjord can send `deliveryIntent:"steer"` and let the server fall back to queue for providers that can't steer, without reading flags at all.

## h. Real data counts (§9.8): VERIFIED, with a caveat

Read-only `subscribeShell` snapshot at 2026-11-06 ~18:08 (excluding my throwaways):
- 459 threads in 7 projects: 443 top-level + 16 subagent threads; none archived; 351 Claude / 92 Codex among the 443.
- `status`: idle 455, completed 3, running 1 (plus 1 more running earlier). **Working now: 1** ("Map App Features to T3 Code"); **waiting / with a pending runtime request: 0**.
- 439 of 443 are `v1_import` (historic, `settledAt` set, no run); only 4 threads have a T3 run, so T3's run timestamps can't give a usage history yet.
- Snapshot size 0.9 MB (455 whole `ThreadShell` rows), delivered in ~70 ms.
- Proxy for load, from the imported threads' `latestUserMessageAt` (a thread counted once, at its last message), hourly over 30 days, threads active in a trailing 2 h window: **peak 20** (2026-11-02 11:00), p99 13, p90 3, median 0. Days with most last-activity: 34, 41 threads.
- Estimate: a brief following running, waiting, or finished-in-2 h threads would hold **0-3 `subscribeThread` streams at p90, about 13-20 at the observed peak** (an undercount, since only each thread's last message is counted, so budget for ~25). Streams are cheap (a snapshot plus a handful of events per turn), so §7.2 (questions in the shell) isn't forced by volume; it would still save the subscription just to display a question.

## i. Attachment upload format (§9.5): VERIFIED BY SOURCE (nothing uploaded)

1. RPC `attachments.createUploadUrl` (needs `orchestration:operate`, `RpcAuthorization.ts:162`) with `{type?:"image", name, mimeType, sizeBytes}` or `{type:"file", name, mimeType, sizeBytes}` (name ≤ 255, image mime in a fixed list, size ≥ 1 and ≤ per-type cap, file max advertised as `fileAttachments.maxUploadBytes` = 52 428 800; `T3:packages/contracts/src/assets.ts:90-121`). Result `{attachmentId, relativeUrl, expiresAt}`; the URL lives 10 min (`ATTACHMENT_UPLOAD_URL_TTL_MS`).
2. Upload: `POST <origin><relativeUrl>` (`/api/attachments/upload/<signed token>`, `AttachmentUpload.ts:41`), raw bytes as the body, `Content-Type: <mimeType>` (`apps/web/src/lib/attachmentUploadQueue.ts:143-145`), `Content-Length` must equal `sizeBytes`; success is **204** (`T3:apps/server/src/http.ts:464-499`). The token in the URL is the authorization.
3. Reference it in the command: `attachments:[{type:"image"|"file", id:<attachmentId>, name, mimeType, sizeBytes}]` (`ChatImageAttachment`/`ChatFileAttachment`, `chatAttachment.ts:148-173`) on `message.dispatch`/`launchThread.initialMessage`. Question answers use `attachmentsByQuestionId:{[questionId]:[…]}`. `attachments.delete {attachmentId}` removes a pending upload.

## j. visit, archive, deep link: VERIFIED

- `thread.visit {commandId, threadId, visitedAt:<iso>}` → `{sequence}` ~8 ms; shell `thread.updated` shows `lastVisitedAt` = the sent value. With `opened:true` the shell also carries `opens:{openedAt,score,picks}`.
- `thread.mark-unread {threadId}` → `lastVisitedAt` goes back to the thread's `updatedAt` minus 1 ms (`17:51:23.015Z` vs `updatedAt 17:51:23.016Z`), so "unseen" is `lastVisitedAt < updatedAt`.
- `thread.archive {threadId}` → ok ~7 ms, shell emits `thread.removed{location:"active",threadId}`; `getArchivedShellSnapshot {}` then lists 13 of mine.
- Deep link: `t3code://threads/<environmentId>/<threadId>` (`T3:packages/shared/src/promptLinks.ts:189-215`; scheme `t3code`, also `t3code-dev`, registered in the app's Info.plist). `environmentId` here is `4b6b96ba-7c00-4532-b671-de0c3afdd4ac` (from `/.well-known/t3/environment`). `t3code://new?prompt=…` opens a draft. Not opened.

## Throwaway threads (all archived)

`c314bfcf-062f-4aed-82dc-b1af5f8f2f07` b · `2ee665c2-e93e-488b-8ad3-e891648e60e0` a2 · `a7b41ccc-4b3c-4bde-9b43-9f5439a6ea4f` a3 · `710735aa-e746-4a69-9796-e8d4ca67d159` c steer-intent (first try, bare sleep) · `86990dbe-afb8-41b3-a372-ea49119e48f0` c steer-intent · `c1f0fe81-e85a-41e2-92a1-a8e2c22b5c1e` c steer-active · `62925664-1eb1-4e2c-a365-f4d1e12522cc` c queue · `12eb0a97-eedc-4043-ab34-f3338d8c9942` c restart · `9cdf0c8f-9385-45a3-9720-e614207d2d41` c2 queue-edit-cancel-interrupt · `3e4daa36-7677-4447-9258-917e596e466d` d question · `49080dd3-6f10-4bb5-958d-dec616273ee8` e (date, ungated) · `f11a06f6-ac41-4ab8-b5e5-2288cb683ef1` e permission · `553c4535-30d8-4612-b631-f40133c65239` f plan.

## Still open after this round

- `queued-run.reorder`, `queued-message.promote-to-steer`, `forceStopThread`, `acceptForSession`/`acceptAlways`, `deliveryIntent:"auto"` live, Codex behaviour (steering, approval `options`), attachments live.
- Whether the ~5 s delay between a steer and the tool interruption is the Claude CLI or T3 (only Haiku measured).
- §9.6 (guest T3 server through Silo) was out of scope.
