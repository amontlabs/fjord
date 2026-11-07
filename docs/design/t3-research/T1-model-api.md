# T1 — T3 Code core data model & external-client API (v0.1.7)

Repo: `/Users/polarzero/code/research/t3code` @ tag `v0.1.7`. Read-only. Paths below are relative to that repo.
Convention: `OV2` = `packages/contracts/src/orchestrationV2.ts` (4323 lines). Every claim cites `path:line`; **INFERRED** = my reading, not stated in source/docs. **NOT VERIFIED** = I did not open it.

---------------------------------------------------------------------------
## 0. TL;DR for Fjord

- One server per machine ("environment"). Live one on this Mac: `http://127.0.0.1:3773`, server 0.1.7 (`~/.t3/userdata/server-runtime.json`: `{"version":1,"pid":74231,"host":"127.0.0.1","port":3773,"origin":"http://127.0.0.1:3773","serverVersion":"0.1.7",...}` — no credentials in it; schema `apps/server/src/serverRuntimeState.ts:10-35`).
- Transport = **Effect-RPC over one WebSocket at `GET /ws`**, JSON serialization (`apps/server/src/ws.ts:3427-3431, 3461-3463, 3496`). Plus a few plain JSON HTTP GETs for snapshots (`packages/contracts/src/environmentHttp.ts:685-727`).
- Observation model = **snapshot + sequence cursor + replay**. `subscribeShell` (all projects/threads, one row per thread, status already computed) and `subscribeThread` (full detail + raw domain events for one thread). There is **no single firehose of raw events across all threads** (INFERRED from `ORCHESTRATION_V2_WS_METHODS`, OV2:3574-3595: only `subscribeShell`, `subscribeThread`, `subscribeCommandOutput`).
- "Needs the user" is already computed server-side per thread: `ThreadShell.pendingRuntimeRequest` (+`kind`), `hasActionableProposedPlan`, `status`, `lastError`. The mobile-notification logic (`packages/shared/src/agentAwareness.ts:60-128`) is the canonical derivation of waiting_for_input / waiting_for_approval / completed / failed.
- All actions Fjord needs exist as commands via `orchestration.dispatchCommand` (answer permission, answer question, send/queue/steer/interrupt, mark read, archive, rename, fork, revert).
- Credentials: a local third-party client can mint its own bearer token with the `t3` CLI (`t3 auth session issue --token-only` / `t3 auth pairing create`) — no GUI step. Contracts package is `private`, unpublished, no JSON-Schema export → a Swift client must hand-write Codable models (see §8).
- Server's "text generation" (titles/commit/PR text) is **internal only**, fixed operations, not exposed over RPC → cannot replace Fjord's Haiku briefs (§6).

---------------------------------------------------------------------------
## 1. Domain model

Source of truth doc: `docs/orchestration-v2/core-graph-and-data-model.md` (graph at :5-15, entity summary :42-137). Where doc and code differ, **code (OV2) wins** — the doc is a "target architecture" (`docs/orchestration-v2/README.md:3`) and is older (e.g. doc says `defaultProvider`, code uses `providerInstanceId`).

Glossary (`docs/internals/glossary.md:11-34`): Environment = one running server; Project = env-local workspace rooted at a dir; Thread = durable conversation; **Turn = a V2 "run"**; Activity = non-message timeline item; Runtime mode = permission policy; Interaction mode = e.g. planning.

### 1.1 Project — `OrchestrationProjectShell` (`packages/contracts/src/orchestrationProject.ts:6-24`)
`id: ProjectId, title, workspaceRoot, repositoryIdentity?, defaultModelSelection: ModelSelection|null, defaultThreadEnvMode?, autoPull?, faviconPath?, projectIcon?, scripts: ProjectScript[], pinnedAt?, archivedAt?, createdAt, updatedAt`.
Projects are mutated via `projects.mutate` (WS `rpc.ts:415`, HTTP `POST /api/projects/mutate` environmentHttp.ts:736) and listed via `GET /api/projects` (:729). Streamed inside shell snapshot (`projects` field, OV2:2223-2228) and as `project.updated`/`project.removed` shell items (OV2:2239-2248).

### 1.2 Thread — `OrchestrationV2AppThread` (OV2:444-518)
Fields: `createdBy: "user"|"agent"|"system"`, `creationSource: "web"|"mobile"|"mcp"|"provider"|"server"` (OV2:89-99), `id: ThreadId, projectId, title (non-empty), providerInstanceId, modelSelection, runtimeMode, interactionMode, branch|null, worktreePath|null, linkedPullRequest?, pullRequests? (ThreadPullRequestLink[]), branchPullRequest?, activeProviderThreadId|null, historyOrigin? ("native"|"v1_import"), linkOrigin?, delegatedFrom?, lineage, forkedFrom|null, createdAt, updatedAt, archivedAt|null, settledOverride ("settled"|"active"|null), settledAt, unsettledAt?, snoozedUntil?, snoozedAt?, lastSnoozeWakeAt?, limitRecovery?, guestShare?, pinnedAt?, autoSettleDisabledAt?, pinOrderKey?, activeOrderKey?, tags?: string[], lastVisitedAt|null, opens?, titleRegeneration?, rollbackRequestId?, rollbackFailure?, deletedAt|null`.

- `ModelSelection` = `{instanceId: ProviderInstanceId, model: string, options?: ProviderOptionSelections}` (`modelSelection.ts:9-14, 22-51`; legacy `provider` key accepted on decode).
- `RuntimeMode` = `"approval-required"|"auto-accept-edits"|"auto"|"full-access"` (default `full-access`) (`providerPolicy.ts:25-32`). Live default in this Mac's settings: `"auto"` (`~/.t3/userdata/settings.json`).
- `ProviderInteractionMode` = `"default"|"plan"` (`providerPolicy.ts:45`) → **plan mode** is per-thread `interactionMode`.
- `lineage` = `{parentThreadId|null, relationshipToParent: "fork"|"subagent"|null, rootThreadId, sideChat?}` (OV2:154-160). Subagents/side-chats are hidden from thread lists: `isListedThreadLineage` (OV2:163-164).
- `forkedFrom` = `{type:"run",threadId,runId} | {type:"node",nodeId} | {type:"provider_thread",providerThreadId,providerTurnId?}` (OV2:463-473).
- **Archive**: `archivedAt` (`thread.archive`/`unarchive`). **Settled** (server-owned "done" state, auto by PR merge/inactivity; `docs/internals/overview.md:93-103`): `settledOverride/settledAt`. **Snooze**: `snoozedUntil`. **Pin**: `pinnedAt`, `pinOrderKey`. **Tags** (labels): `tags` (`threadTags.ts:7-13`: string ≤64 chars, single line, exact-match). **Read state**: `lastVisitedAt` watermark (see §5.3).
- **PR links**: `linkedPullRequest`, `pullRequests`, `branchPullRequest` (types in `threadPullRequest.ts`, NOT VERIFIED in detail).
- **Worktrees**: `branch`, `worktreePath` on thread; creation strategy `OrchestrationV2ThreadLaunchWorkspaceStrategy` = `{type:"root",branch?} | {type:"existing_worktree",worktreePath,branch?} | {type:"worktree",baseRef,branch?,startFromOrigin?}` (OV2:654-671). Run status `preparing` = worktree/setup in progress; helper `orchestrationV2WorktreePending` (OV2:721-733).
- **Titles**: `title`; regenerated by `thread.metadata.update{regenerateTitle:true}` (OV2:3050) → `titleRegeneration:{requestId,startedAt}` marker while in flight (OV2:499-506); also generated from first message when `titleSeed` / `generateTitle` set (OV2:3161, 3639).
- Other: `limitRecovery:{requestId?,runId,resetAt,autoResume,snooze?}` (usage-limit auto-resume, OV2:400-407), `guestShare` (guest links, `docs/user/guest-links.md`), `opens` (search-ranking stats).

### 1.3 Run (= user-visible "turn") — `OrchestrationV2Run` (OV2:676-709)
`id: RunId, threadId, ordinal (1..), providerInstanceId, modelSelection, providerThreadId|null, userMessageId, rootNodeId|null, activeAttemptId|null, status, queuePosition?, queueHeld?, requestedAt, startedAt|null, completedAt|null, checkpointId|null, contextHandoffId|null, restartContinuationOfRunId?, delegatedTaskId?, workStartedAt?, restartCancelledBackgroundWork?, sourcePlanRef?:{threadId,planId}, delegatedCompletion?, workspacePreparation?`.
**Run status values** (`OrchestrationV2RunStatus`, OV2:590-601): `preparing, queued, starting, running, waiting, completed, interrupted, failed, cancelled, rolled_back`.
`RunAttempt` (OV2:735-758): one provider execution attempt; reasons per doc `initial|steering_restart|retry|provider_recovery` (doc :232).

### 1.4 Thread status (what a list UI shows) — `OrchestrationV2ThreadShell.status`
`OrchestrationV2ShellThreadStatus = "idle" | RunStatus` (OV2:2047-2051) i.e. `idle, preparing, queued, starting, running, waiting, completed, interrupted, failed, cancelled, rolled_back`. Extra shell fields (OV2:2072-2151): `latestRunId, latestRunRequestedAt/StartedAt/CompletedAt, latestRunStopRequested, activeRunId, activityRunStartedAt, activityRunStatus ("preparing"|"starting"|"running"|"waiting"|null), blockedOnThreadWait, lastError, lastErrorClass, lastErrorCode, usageLimitResetAt, pendingRuntimeRequest, pendingGuestMessageCount, latestVisibleMessage:{id,role,text,updatedAt}|null, latestUserMessageAt, latestUserAuthoredMessageAt, hasActionableProposedPlan, pendingBackgroundTasks[], providerInstanceHistory[], goal, itemCount, visibleItemCount` + all the AppThread org fields.
`ProviderFailureClass` = `usage_limit|provider_error|transport_error|permission_error|validation_error|unknown` (OV2:1447-1455).
"Live" = `queued|preparing|starting|running|waiting` (`LIVE_SHELL_STATUSES`, OV2:2154-2160).

### 1.5 ExecutionNode / Subagent / ProviderSession / ProviderThread / ProviderTurn
- `ExecutionNode` kinds (doc :261-272): `root_turn, assistant_message, reasoning, plan, todo_list, tool_call, approval_request, user_input_request, subagent, hook, system`; status `pending|running|waiting|completed|interrupted|failed|cancelled|rolled_back` (doc :273-281). Code struct OV2:760-799 (NOT VERIFIED in detail).
- `ProviderSession` (OV2:946-958; doc :322): status `starting|ready|running|waiting|stopped|error`.
- `ProviderThread` (OV2:1074-1109): `id, driver, providerInstanceId, providerSessionId, appThreadId, ownerNodeId, nativeThreadRef, nativeConversationHeadRef, status ("not_loaded"|"idle"|"active"|"archived"|"closed"|"error"), firstRunOrdinal, lastRunOrdinal, handoffIds, forkedFrom, pendingBackgroundTasks, contextUsage: ThreadTokenUsageSnapshot|null, nativeMetadata, goal, createdAt, updatedAt`. `nativeThreadRef` = the provider's own session id (e.g. Claude Code session id) wrapped as `OrchestrationV2ProviderRef{driver,nativeId,strength,fingerprint?,ordinal?}` (OV2:145-152).
- `ProviderTurn` (OV2:1168-1188) includes `tokenUsage?: OrchestrationV2ProviderTurnTokenUsage` (OV2:1185).

### 1.6 Messages — `OrchestrationV2ConversationMessage` (OV2:1288-1318)
`id: MessageId, threadId, runId|null, nodeId|null, role: "user"|"assistant"|"system", text, context?, attachments: ChatAttachment[], streaming: boolean, createdAt, updatedAt` + `createdBy, creationSource, notification?, scheduledTaskId?, senderThreadId?, idleCompaction?, workflowScript?, delegatedCompletion?`.
`ChatAttachment` = image | file | unknown (`chatAttachment.ts:201-206`):
 - image `{type:"image", id, name≤255, mimeType image/*, sizeBytes ≤10 MiB, source?}`; allowed mimes gif/jpeg/png/webp (`chatAttachment.ts:12-20, 118-125`).
 - file `{type:"file", id, name, mimeType, sizeBytes 1..50 MiB, source?: pasted-text}` (:127-139). Max 100 attachments per send (:13).
 - Upload: `attachments.createUploadUrl` (WS `rpc.ts:428, 1405`) then reference by id; capability flags `attachmentUploads`, `fileAttachments.maxUploadBytes`, `questionAttachments` in the env descriptor (`environment.ts:80-85`). Upload-format detail NOT VERIFIED.

### 1.7 Turn items (the ordered "activity"/timeline) — `OrchestrationV2TurnItem` (OV2:1595-1818)
Common base (OV2:1495-1522): `id: TurnItemId, threadId, runId|null, nodeId|null, providerThreadId, providerTurnId, nativeItemRef, parentItemId, ordinal, status, title, startedAt, completedAt, updatedAt` (+ tool* display hints, wire-only `deferredWork`).
`TurnItemStatus` = `idle|pending|running|waiting|completed|failed|cancelled|interrupted` (OV2:1425-1434).
Item `type` values: `notification, user_message, assistant_message, reasoning, proposed_plan, todo_list, user_input_request, file_change, command_execution, file_search, web_search, approval_request, checkpoint, run_interrupt_request, run_interrupt_result, system_notice, error, compaction, handoff, fork, thread_created, secret_request, link_request, subagent, dynamic_tool`.
Key shapes:
 - `user_message`: `messageId, inputIntent ("turn_start"|"queued_turn"|"steer"|"promoted_queued_to_steer"), text, attachments, modelSwitch?, context?` (OV2:1601-1617; intents :1479-1483).
 - `assistant_message`: `messageId, text, streaming` (:1618-1626).
 - `approval_request`: `requestId: RuntimeRequestId, requestKind, prompt?, reason?, fullAccessOverride?, appName?, options?: ProviderApprovalOption[]` (:1690-1700).
 - `user_input_request`: `requestId, questions: UserInputQuestion[], questionAnswer?, responseMode?: "message"` (:1647-1654).
 - `proposed_plan`: `planId, markdown, streaming` (:1633-1639). `todo_list`: `planId, steps[{id,text,status pending|running|completed,durationMs?}], explanation?` (:1640-1646; PlanStep OV2:1320-1327).
 - `file_change`: `fileName, additions?, deletions?, diffStr?, oldStr?, newStr?, changes?` (:1655-1665). `command_execution`: `input, output?, outputOmitted?, exitCode?, monitor?` (:1666-1677; live output via `subscribeCommandOutput`, OV2:3604-3613). `file_search`, `web_search`, `dynamic_tool{toolName,input,output}`.
 - `checkpoint`: `checkpointId, scopeId, files[], filesTotal?` (:1701-1710).
 - `error`: `failure:{class,message,code,retryable,resetAt?}, retry?{attempt,maxAttempts,retryDelayMs}` (:1728-1733; failure OV2:1463-1470).
 - `run_interrupt_request/result`, `system_notice`, `compaction{beforeTokenCount,afterTokenCount,summary}`, `handoff{...}`, `fork{...}`, `subagent{subagentId,childThreadId,prompt,progress,result}`.
 - Unknown future item types are skipped by clients (`ForwardCompatibleUnionArray`, OV2:1821-1842, 2032) — **a Swift decoder must also tolerate unknown `type` values**.
`ProjectedTurnItem` = `{position, visibility: "local"|"inherited"|"synthetic", sourceThreadId, sourceItemId, item}` (OV2:1844-1851); forked threads show inherited source items via `visibleTurnItems` (doc :618-622).

### 1.8 Approvals / permission requests — `OrchestrationV2RuntimeRequest` (OV2:1205-1230)
`id: RuntimeRequestId, nodeId, providerTurnId|null, nativeRequestRef|null, kind, status ("pending"|"resolved"|"expired"|"cancelled"), responseCapability, createdAt, resolvedAt|null, decision?, feedback?, answers?`.
 - `kind` = `ProviderRequestKind` (`"command"|"file-read"|"file-change"|"mcp-elicitation"|"permission"`, `providerPolicy.ts:49-56`) ∪ `"dynamic_tool_call"|"user_input"|"auth_refresh"`.
 - `responseCapability`: `{type:"live", providerSessionId, supportsFeedback?}` | `{type:"message"}` (answer delivered as a normal message) | `{type:"not_resumable", reason}` — requests survive restart but are only respondable if `live`/`message` (doc :501; OV2:1215-1223).
 - Approval decisions `ProviderApprovalDecision` = `accept|acceptForSession|acceptAlways|decline|cancel` (`providerPolicy.ts:58-65`); `ProviderApprovalOption{decision,label,warning?}` (:72-77); `fullAccessOverride` = `ask_rule|provider_check` (:68-70).

### 1.9 User-input questions — `OrchestrationV2UserInputQuestion` (OV2:1329-1346)
`id, header, question, options: [{label, description, value?, preview?}], multiSelect?, allowCustomAnswer?, initialAnswer?, required?`.
 - Answers are `ProviderUserInputAnswers = Record<string, unknown>` keyed by question id (`providerPolicy.ts:79`) — exact value shape per question (string vs string[] for multiSelect) is NOT pinned by the schema (INFERRED: string / string[]; check `packages/client-runtime/src/secretRequest.ts`/web composer before relying).
 - Per-question attachments: `attachmentsByQuestionId: Record<qid, (image|file)[]>` ≤100 each (`providerPolicy.ts:82-88`; command field OV2:3283). Only questions with `allowCustomAnswer` accept files; files upload to the thread's environment and the agent gets paths (`docs/user/question-attachments.md:5-9`). Capability `questionAttachments` (environment.ts:81).
 - Echoed back on the item as `UserInputAttachmentAnswerPayload{requestId,questionTextById?,answers,attachmentsByQuestionId}` (`providerPolicy.ts:90-96`).
 - Async questions: `PendingRuntimeRequestSummary.blocking:false` = "the run keeps working past it" (OV2:2057-2058).

### 1.10 Plans / plan mode
`PlanArtifact` union (OV2:1357-1369): `proposed_plan{markdown}` | `todo_list{steps, explanation?}`; both `{id: PlanId, threadId, runId|null, nodeId, status: "draft"|"active"|"completed"|"superseded"}` (:1348-1355). Shell flag `hasActionableProposedPlan` (OV2:2115). Plan mode = thread `interactionMode:"plan"`. **Approve/implement plan** has no dedicated command: client sends `message.dispatch` with `sourcePlanRef:{threadId,planId}` (OV2:3163; client usage `packages/client-runtime/src/operations/commands.ts:754, 778`) — the run records it in `Run.sourcePlanRef` (OV2:700-705). (Switching back to default interaction mode is a separate `thread.interaction-mode.set`, OV2:3127-3132 — whether the web UI sends both is NOT VERIFIED.)

### 1.11 Checkpoints / diffs
`CheckpointScope` (OV2:931; doc :299-313) kinds `root_run|subagent|tool|provider_thread|manual`. `Checkpoint` (OV2:1388-1402): `id, threadId, scopeId, runId|null, nodeId, parentCheckpointId, ordinalWithinScope, appRunOrdinal, ref (hidden git ref), status "ready"|"missing"|"error"|"stale", files: [{path,kind,additions,deletions}], filesTotal?, capturedAt`. Stored as hidden Git refs, no commits on the user's branch (`docs/internals/overview.md:88-90`). Diffs: `orchestration.getTurnDiff` / `getFullThreadDiff` (OV2:3576-3577; inputs `checkpointDiff.ts:29-46`: `{threadId, fromTurnCount/toTurnCount, ignoreWhitespace?}`). Revert = `checkpoint.rollback` (§4).

### 1.12 Lineage / forks / handoffs / transfers
 - `thread.fork` creates a new app thread from `sourcePoint: latest_stable | run{runId} | checkpoint{checkpointId}` (OV2:185-189, 3299-3309); optional `sideChat`.
 - `ContextTransfer` (OV2:232-258): `type: fork|provider_handoff|merge_back|subagent_spawn|subagent_result`, `sourceThreadId, targetThreadId, sourcePoint, basePoint, status pending|resolved_native|resolved_portable|failed|consumed|superseded, resolution{native_fork|portable_context|delta_context|fork_delta_context|checkpoint_context}`.
 - `ContextHandoff` (OV2:1124-1166; doc :422-445): materialized summary used when switching provider/model family mid-thread.
 - `provider.switch{threadId, modelSelection}` switches provider for subsequent runs (OV2:3366-3371); `thread.merge_back` merges a fork's delta back (OV2:3310-3318).
 - Delegated tasks / subagents: `delegated_task.request` etc (OV2:3319-3364); `Subagent` (OV2:884-923) with `origin provider_native|app_owned`.

### 1.13 Usage / tokens / rate limits
 - Per-thread context usage: `ProviderThread.contextUsage: ThreadTokenUsageSnapshot` (`providerRuntime.ts:30-54`): `usedTokens, maxTokens?, inputTokens?, cachedInputTokens?, outputTokens?, reasoningOutputTokens?, last*?, toolUses?, durationMs?, compactsAutomatically?, autoCompactThreshold?, cost?{amount,currency}`.
 - Per-turn: `ProviderTurn.tokenUsage` (OV2:1185, 217-229 incl. `promptCacheExpiresAt`).
 - Rate-limit windows per provider instance: `ServerProviderUsageLimits{checkedAt, windows:[{id, kind: session|weekly|monthly|other, label, usedPercent 0-100, resetsAt?, windowDurationMins?}], resetCredits?, externalUsage?, unavailable?}` (`providerUsageLimits.ts:13-50`); delivered via the server config/provider snapshots (`server.getConfig`, `server.refreshProviders`, rpc.ts:635-641; exact carrier field NOT VERIFIED).
 - Historical spend: `server.getUsageSummary` (rpc.ts:538; contract `usage.ts`, `USAGE_CONTRACT_VERSION = 6`, scans provider transcripts incl. Claude/Codex, `usage.ts:1-60`).
 - Thread-level: `lastErrorClass: "usage_limit"`, `usageLimitResetAt`, `limitRecovery` auto-resume.

---------------------------------------------------------------------------
## 2. Event stream, subscriptions, read models

### 2.1 Mechanics
 - Every committed event has a store-assigned monotonic `sequence` on the *envelope* (`OrchestrationV2StoredEvent{sequence, commandId|null, event}`, OV2:2264-2269; doc :31-38). Contract: "read snapshot at N → stream events with sequence > N"; `snapshotSequence` is the authoritative cursor (doc :38, 610).
 - Event base fields: `{id: EventId, threadId, runId?, nodeId?, driver?, providerInstanceId?, rawEventId?, occurredAt}` (OV2:1853-1862).
 - **Shell stream** `orchestration.subscribeShell` input `{afterSequence?, requestCompletionMarker?, omitIdleSubagents?, omitOlderSettled?}` (OV2:3675-3688). Items (OV2:2230-2262): `synchronized` | `snapshot{snapshot: ShellSnapshot, resolvedRepositoryIdentityRoots?}` | `project.updated{sequence,project}` | `project.removed` | `thread.updated{sequence, location:"active"|"archive", thread: ThreadShell}` | `thread.removed{sequence, location, threadId}`. `ShellSnapshot = {schemaVersion, snapshotSequence, threads[], archivedThreads[], projects[], olderSettled?}` (OV2:2215-2228). So the shell stream sends **whole updated ThreadShell rows**, not raw events.
 - **Thread stream** `orchestration.subscribeThread` input `{threadId, afterSequence?, requestCompletionMarker?, acceptBoundedSnapshot?, acceptDeferredWork?, acceptCompactTurnItems?, acceptDedupedBodies?, acceptCompactIds?}` (OV2:3773-3783). Items (OV2:3884-3907): `synchronized` | `snapshot{snapshotSequence, projection: ThreadProjection, historyCursor?, hasMoreHistory?, latestLocalTurnOrdinal?, turnItemsOmitLocalVisible?, idTable?}` | `event{sequence, event: DomainEvent}` | `unknown-event{sequence,eventType}` (unknown types are skipped but advance the cursor, OV2:3851-3882).
   - Resume: pass `afterSequence = last applied`. Server replays if gap small, else sends a fresh snapshot: replay capped at **128 events / 1 MiB** (`apps/server/src/orchestration-v2/ThreadStream.ts:16-23, 99-115`: fall back to snapshot if `afterSequence > highWater` or caps exceeded). Reconnect may also just reset from a fresh snapshot (doc :610).
   - Opt-in compression flags (`acceptCompactIds`/`idTable`, `acceptDedupedBodies`, `*Omitted` markers like `textOmitted`) are all **opt-in** → a minimal Swift client can omit them and get plain shapes (INFERRED from "Server-side only: set it on a response for a client that opted in", OV2:3786-3790). `acceptBoundedSnapshot` default off = full projection; bounded snapshots page older history via `historyCursor` (`GET /api/orchestration/threads/:id/history`).
 - Reference reducer for applying events to a projection: `packages/client-runtime/src/state/orchestrationV2Projection.ts` (421 lines, `applyOrchestrationV2ProjectionEvent` :259) — port this logic to Swift.
 - Unread semantics: see §5.3.

### 2.2 Read models
 - `ThreadShell` (sidebar row, OV2:2072-2151) — "fast sidebar list" (doc :601).
 - `ThreadProjection` (thread detail, OV2:2011-2036): `thread, runs, attempts, nodes, subagents, providerSessions, providerThreads, providerTurns, runtimeRequests, messages, plans, turnItems, checkpointScopes, checkpoints, contextHandoffs, contextTransfers, visibleTurnItems, updatedAt`.
 - `ThreadTranscript` `{threadId,title,updatedAt,items[]}` (OV2:2039-2045) — cheap read-only transcript: `GET /api/orchestration/threads/:threadId/transcript` (environmentHttp.ts:701).
 - `ThreadFamily` (root + forks + subagent trees, OV2:3701), `ArchivedShellSnapshot` (OV2:3624), `OlderSettledThreadsPage`, `WorktreeThreadIds`, search results (`searchThreads`, `searchThread`, `searchThreadStream`).
 - HTTP snapshot equivalents (need Bearer + header `x-t3-orchestration-protocol: 2`, environmentHttp.ts:83): `GET /api/orchestration/shell`, `/threads/:id`, `/threads/:id/transcript`, `/threads/:id/bounded`, `/threads/:id/history` (environmentHttp.ts:685-727).

### 2.3 Domain event types (`OrchestrationV2DomainEvent`, OV2:1864-2008) — exhaustive
Payload in parentheses.
 - **Thread (payload = full `AppThread`)**: `thread.created`; `thread.archived`, `thread.unarchived`, `thread.deleted`; `thread.settled`, `thread.unsettled`; `thread.snoozed`, `thread.unsnoozed`; `thread.pinned`, `thread.unpinned`, `thread.pin-reordered`, `thread.active-reordered`; `thread.auto-settle-set`; `thread.tags-updated`; `thread.visited` (read watermark moved), `thread.marked-unread`; `thread.metadata-updated` (title/branch/worktree/etc.); `thread.pull-request-synced`; `thread.runtime-mode-updated`, `thread.interaction-mode-updated`, `thread.model-selection-updated`, `thread.provider-switched`; `thread.guest-share-updated`.
 - `thread.pull-request-link-updated` (payload `ThreadPullRequestLink`).
 - **Run**: `run.created`, `run.updated` (`Run`); `run.background-work-cancelled` (`{runId, restartCancelledBackgroundWork[]}`); `run-attempt.created`, `run-attempt.updated`.
 - **Graph**: `node.updated` (ExecutionNode); `subagent.updated`; `provider-session.attached`, `provider-session.updated`, `provider-session.detached`; `provider-thread.updated`; `provider-turn.updated`.
 - **User-facing records**: `runtime-request.updated` (RuntimeRequest — approvals & questions appear/resolve here); `message.updated` (ConversationMessage; streaming deltas land here); `turn-item.updated` (TurnItem); `plan.updated` (PlanArtifact).
 - **Checkpoints**: `checkpoint-scope.created`, `checkpoint.captured`, `checkpoint.rollback-requested`.
 - **Context**: `context-handoff.updated`, `context-transfer.created`, `context-transfer.updated`.
 Note: events are *state upserts* (whole-record payloads), not deltas — apply by id replace (INFERRED from payload types).

### 2.4 Command types (`OrchestrationV2Command`, OV2:2895-3372, dispatched through `dispatchCommand`)
 Common: every command has `commandId: CommandId` (client-generated idempotency key — "Command receipt: durable record used to make retries idempotent", glossary :31; INFERRED: reuse same id on retry) and `threadId` (mostly).
 - **Lifecycle**: `thread.create`, `thread.stop`, `thread.archive`, `thread.unarchive`, `thread.delete{onlyIfUnused?}`, `thread.fork`, `thread.merge_back`, `provider.switch`, `provider-session.detach`.
 - **Organization/state**: `thread.settle`, `thread.auto-settle` (guarded), `thread.unsettle`, `thread.snooze{snoozedUntil}`, `thread.unsnooze`, `thread.auto-settle.set{enabled}`, `thread.pin{orderKey?}`, `thread.unpin`, `thread.pin.reorder`, `thread.active.reorder`, `thread.tag.set{tag,tagged}`, `thread.visit{visitedAt,opened?,searchQuery?}`, `thread.mark-unread`, `thread.metadata.update{title?,regenerateTitle?,branch?,worktreePath?,expected*?,expectedEmpty?,limitRecovery?,linkedPullRequest?}`, `thread.title.regeneration.complete`.
 - **PR**: `thread.pull-request.link/unlink/watch/sync`, `thread.pull-request-link.sync`.
 - **Modes**: `thread.runtime-mode.set`, `thread.interaction-mode.set`, `thread.model-selection.set`.
 - **Messaging/runs**: `message.dispatch` (§4), `prepared-run.release/progress/fail/retry`, `notification.delivery.accept`, `run.interrupt{runId,reason?,holdQueue?}`, `queued-message.promote-to-steer{queuedRunId,targetRunId}`, `queue.resume`, `queued-run.start/reorder/cancel/edit`, `subagent.stop`.
 - **Requests**: `runtime-request.respond{requestId,decision?,feedback?,answers?,attachmentsByQuestionId?}`, `thread.user-input.dismiss{requestId}`.
 - **Checkpoint**: `checkpoint.rollback{scopeId,checkpointId,restoreFiles?}`.
 - **Delegation**: `delegated_task.request/wake-policy/completion-delivery.acknowledge/dispose`, `thread.created.record`.
 - **Guest links**: `thread.guest-share.close`, `thread.guest-message.dismiss`.
 - **Server-internal only** (excluded from `dispatchCommand`, OV2:3375-3570): guest-share open/redeem/submit, `thread.project.adopt-folder`, `thread.pull-request-watch.sync`, `delegated_task.remote.*`, `checkpoint.rollback.fail`, `runtime-request.delivery.fail`, `thread.interrupt.unresponsive`, `thread.background-work.settle`, `secret_request.record`, `link_request.record`.
 - Result: `{sequence}` of the commit (`OrchestrationV2DispatchCommandResult`, OV2:3664-3667) → a client can wait until its stream reaches that sequence.

### 2.5 Orchestration RPC methods (`ORCHESTRATION_V2_WS_METHODS`, OV2:3574-3595; schemas OV2:4204-4277)
`orchestration.dispatchCommand`, `getTurnDiff`, `getFullThreadDiff`, `searchThreads`, `searchThread`, `searchThreadStream`, `getArchivedShellSnapshot`, `getThreadFamily`, `getWorktreeThreadIds`, `getOlderSettledThreads`, `getThreadProjection`, `getWorkflowScript`, `getNativeChildWork`, `stopWorkflow`, `forceStopThread`, `getTurnItem` (fetch withheld output), `launchThread` (create+first message+worktree in one call), `subscribeShell`, `subscribeThread`, `subscribeCommandOutput`.
Other relevant WS methods (`rpc.ts:408-601`): `projects.*`, `attachments.createUploadUrl/delete`, `assets.persistChatAttachments`, `agentSessions.scan/import` (§7), `server.getConfig`, `server.probe`, `server.updateSettings`, `server.getUsageSummary`, `vcs.*`, `git.*`, `pullRequests.*`, `terminal.*`, `scheduledTasks.*`, `peerLinks.*`.

---------------------------------------------------------------------------
## 3. Transport & auth

### 3.1 Endpoints
 - Descriptor (unauthenticated): `GET /.well-known/t3/environment` → `ExecutionEnvironmentDescriptor{environmentId,label,platform,serverVersion,orchestrationProtocolVersion?,databaseMigration?,capabilities}` (environmentHttp.ts:531-533; `environment.ts:77-183`). Capabilities include `shellThreadFamilies`, `shellOlderSettled`, `attachmentUploads`, `questionAttachments`, `sideChats`, `threadSettlement` … (`environment.ts:77-172`). "Clients must use advertised capabilities and handle their absence" (`docs/internals/remote.md` §Access).
 - Auth HTTP (environmentHttp.ts:537-605): `GET /api/auth/session`, `POST /api/auth/browser-session`, `POST /oauth/token`, `POST /api/auth/websocket-ticket`, `POST /api/auth/websocket-ticket/:use`, `POST /api/auth/pairing-token`, `POST /api/auth/pairing-links/revoke`, `POST /api/auth/clients/revoke`, `POST /api/auth/clients/revoke-others`. MCP OAuth (`/mcp`, `/oauth/mcp/*`) is a separate audience (`docs/internals/environment-auth.md:42-71`).
 - RPC socket: `GET /ws` (ws.ts:3427-3431). **Requires query `orchestrationProtocol=2`** else HTTP 426 JSON `{code:"orchestration_protocol_incompatible",...}` (ws.ts:693-697, 3433-3443; constants `environment.ts:13-15`). Optional `clientCapabilities=` comma list (e.g. `settingsSecretReferences`, environment.ts:18-20; ws.ts:701).
 - Framing: Effect `RpcServer` with `RpcSerialization.layerJson` over WebSocket (ws.ts:3461-3463, 3496). **INFERRED (Effect library, not in this repo's source I read; node_modules absent)**: frames are JSON Effect-RPC messages (`Request{id,tag,payload,headers}` / `Chunk`/`Exit`/`Ping`/`Pong`/`Ack`/`Interrupt`), method name = `tag` (e.g. `"orchestration.dispatchCommand"`), streaming methods (subscribe*) reply with `Chunk` frames until `Exit`. The Swift client must implement this Effect protocol by hand — confirm against the installed Effect version's `RpcMessage` before building. Alternative to avoid it: use the HTTP GET snapshot endpoints for polling (but commands only exist via WS RPC; HTTP has no `dispatchCommand`).
 - Client driver reference: `packages/client-runtime/src/rpc/client.ts`, `rpc/session.ts` (session isn't "ready" until initial server config arrives, `connection-runtime.md` §Transport health), `connection/supervisor.ts` (jittered exp backoff, cap 5 min, probe on foreground), `connection/driver.ts`, `connection/registry.ts` (per-environment scoping).

### 3.2 Credentials & scopes
 - Model: environment issues its own scoped sessions (`environment-auth.md:3-6`). Bearer tokens, browser cookies, optional DPoP (sender-constrained) (:25-28). Long-lived bearer is NOT put on the socket URL: client POSTs `/api/auth/websocket-ticket` (bearer-authed) and opens `/ws?...&wsTicket=<ticket>` (:73-83; ws auth reads `wsTicket` query, EnvironmentAuth.ts:582-585, 1244-1292). **If no `wsTicket`, the upgrade falls back to normal request auth: `Authorization: Bearer <token>` header or session cookie** (`authenticateRequest`, EnvironmentAuth.ts:774-, called at :1295). A native URLSession WebSocket can set headers → no ticket needed (INFERRED; DPoP-less bearer).
 - Scopes (`auth.ts:31-48`): `orchestration:read`, `orchestration:operate`, `settings:write`, `providers:manage`, `environment:maintain`, `preview:operate`, `diagnostics:read`, `terminal:read`, `terminal:operate`, `source-control:write`, `filesystem:read`, `filesystem:write`, `access:read`, `access:write`, `relay:read`, `relay:write`. Default grant (`AuthStandardClientScopes`, auth.ts:150-167) = all of them. **Every RPC declares a required scope** checked by `RpcScopeAuthorization` (environment-auth.md:84-86; `apps/server/src/auth/RpcAuthorization.ts`). Fjord needs only `orchestration:read` + `orchestration:operate` (+ `filesystem:read` if reading attachments) — INFERRED from scope names; verify per-method in `RpcAuthorization.ts` (NOT VERIFIED).
 - Pairing → token exchange: one-time pairing credential is exchanged at `POST /oauth/token` using RFC 8693 token-exchange (`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`, `subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap`, `auth.ts:169-172, 221-223`); exchange may narrow, never widen, scopes (environment-auth.md:9-10).
 - **How a third-party local client gets credentials without the GUI**:
   1. `t3 auth session issue [--scope X]... [--ttl 30d] [--label Fjord] [--subject ...] [--token-only|--json] [--base-dir ~/.t3]` → prints a scoped bearer token directly (`apps/server/src/cli/auth.ts:169-203`; "Issue a scoped bearer access token for headless or remote clients"). It runs `EnvironmentAuth.layerRuntime` against the local `--base-dir` DB (cli/auth.ts:27-46) rather than calling the server (INFERRED: works while the server runs because it shares the SQLite files in `~/.t3/userdata`; `statev2.sqlite`, `server-owner.sqlite` exist there). Docs call this the "local auth control plane for headless deployments" (cli/auth.ts:251-253).
   2. `t3 auth pairing create [--scope] [--ttl] [--label] [--base-url] [--json]` → one-time pairing token (cli/auth.ts:90-121) then exchange at `/oauth/token`.
   3. `t3 pair` (cli/pair.ts:476-560) discovers the running server (`discoverPairTarget`, reads server-runtime.json) and prints pairing URL/QR (`/pair#token=...` hosted-web flow) — meant for phones.
   4. `t3 auth session list|revoke` manage sessions (cli/auth.ts:204-248). Access listing never reveals secrets (environment-auth.md:20-23).
   - Desktop path (not for us): `--bootstrap-fd` / `T3CODE_BOOTSTRAP_FD` envelope the Electron app passes to the server it spawns (`cli/config.ts:59, 154, 295-298`); "Desktop restarts forget the previous local bearer token" (environment-auth.md:101-106). The running desktop's own token is in the desktop's secret store; **don't read `~/.t3/userdata/secrets`** (rule) — mint a separate session instead.
   - Reusable `T3CODE_DEV_AUTH_TOKEN` is dev-only, ignored by desktop/non-dev servers (environment-auth.md:108-125).
 - **Port vs socket**: TCP only. Live: `127.0.0.1:3773` (server-runtime.json; `host`/`port` fields, serverRuntimeState.ts:12-20). No unix socket found in the server's runtime-state schema or CLI config (INFERRED; I grepped `cli/config.ts`/`bootstrap.ts` only). Port is advertised in `server-runtime.json` for discovery; `t3 pair` uses `discoverPairTarget` the same way. Background service listens on all private IPv4 only when no host configured (remote.md §Identity).
 - **Multiple environments / peers**: Each environment has stable `environmentId` (descriptor; `~/.t3/userdata/environment-id`), independent DB and sessions (environment-auth.md:116-119). Clients keep an ordered route list per environment (LAN/Tailscale/T3 Connect relay/SSH) (remote.md §Identity). A project and its threads belong to one env; cross-env only via **peer links** (`PeerLinks.ts`, MCP-based, beta flag `linkedEnvironmentsEnabled`) (remote.md §Peer links). Threads can carry `linkOrigin`/`delegatedFrom` (OV2:115-140). For Fjord on one Mac: one environment.

---------------------------------------------------------------------------
## 4. Commands a client issues (concrete)

All via WS RPC `orchestration.dispatchCommand` (input = `OrchestrationV2Command`) unless noted.

| Goal | Command | Notes |
|---|---|---|
| Start thread (+ first message, worktree) | RPC `orchestration.launchThread` `ThreadLaunchInput{commandId, creationSource?, threadId?, reuseExistingThread?, projectId, title, generateTitle?, modelSelection, runtimeMode, interactionMode, workspaceStrategy, initialMessage?{messageId?,text,context?,attachments[]}}` → `{threadId, projection, resumed, sequence?}` (OV2:3632-3662) | or `thread.create` (OV2:2907-2933) then `message.dispatch`. `thread.create.importedNativeThread{ref{driver,nativeId,strength:"strong"},metadata?}` imports an existing provider session by id (OV2:2923-2932). |
| Send message | `message.dispatch{commandId, threadId, messageId, text, attachments[], context?, modelSelection?, titleSeed?, createdBy, creationSource, dispatchMode, deliveryIntent?, sourcePlanRef?}` (OV2:3146-3186) | `modelSelection` here changes provider/model for this run (same-harness change = `modelSwitch` on user_message item; cross-provider triggers handoff). `createdBy:"user"`, `creationSource` one of web/mobile/mcp/provider/server — Fjord should pick a value that the server accepts (`"web"`/`"mobile"` are used by clients; no `"native"`/custom value exists → INFERRED, must reuse an existing literal, likely `"mobile"` or `"web"`). |
| Dispatch modes | `dispatchMode` = `defer_start{workspaceStrategy?}` \| `steer_active{targetRunId}` \| `restart_active{targetRunId}` \| `queue_after_active` \| `start_immediately`; `deliveryIntent` = `auto|steer|restart` (OV2:3168-3185) | Client mapping: `"queue"`→`queue_after_active`; else `start_immediately` with `deliveryIntent` auto/steer/restart (client-runtime commands.ts:733-781). `steer` while running = deliver into the active turn; `restart` = interrupt and replace attempt (doc :246). |
| Queue mgmt | `queued-run.start/reorder{beforeRunId}/cancel/edit{text,attachments?}`, `queued-message.promote-to-steer{queuedRunId,targetRunId}`, `queue.resume` (OV2:3234-3274) | Queued runs have `status:"queued"`, `queuePosition`, `queueHeld`. |
| Interrupt | `run.interrupt{runId, reason?, holdQueue?}` (OV2:3226-3233); `thread.stop{threadId, stopDelegatedTasks?}` (stops thread + delegated tasks); RPC `forceStopThread` if provider unresponsive (turn item `run_interrupt_request.unresponsiveAt`, OV2:1715-1717) | |
| Answer permission/approval | `runtime-request.respond{requestId, decision: accept\|acceptForSession\|acceptAlways\|decline\|cancel, feedback?}` (OV2:3275-3284) | Only if request `responseCapability.type==="live"` (and `supportsFeedback` for feedback) (OV2:1215-1220). `options` on the approval item lists offered decisions. |
| Answer question | same `runtime-request.respond{requestId, answers:{<questionId>: value}, attachmentsByQuestionId?}`; or `thread.user-input.dismiss{requestId}` | If `responseCapability.type==="message"`/item `responseMode:"message"` the answer is delivered as a message (OV2:1221, 1653). |
| Approve/implement plan | `message.dispatch` with `sourcePlanRef:{threadId,planId}` (+ optionally `thread.interaction-mode.set{interactionMode:"default"}`) | see §1.10 |
| Set permission/runtime mode | `thread.runtime-mode.set{runtimeMode}` ; plan mode: `thread.interaction-mode.set{interactionMode}` ; model: `thread.model-selection.set{modelSelection}` ; cross-provider: `provider.switch` | |
| Rename | `thread.metadata.update{title}` ; auto: `{regenerateTitle:true}` | |
| Archive / unarchive / delete | `thread.archive`, `thread.unarchive`, `thread.delete{onlyIfUnused?}` | |
| Mark read / unread | `thread.visit{visitedAt: ISO, opened?}` (read), `thread.mark-unread` | §5.3 |
| Pin, snooze, tags, settle | `thread.pin/unpin`, `thread.snooze{snoozedUntil}/unsnooze`, `thread.tag.set{tag,tagged}`, `thread.settle/unsettle` | |
| Fork | `thread.fork{sourceThreadId,targetThreadId(new id),sourcePoint,title?,sideChat?}` | creates `context-transfer` + `fork` turn item |
| Transfer / hand off | `provider.switch{threadId,modelSelection}`, `thread.merge_back{sourceThreadId,targetThreadId,sourcePoint}` | |
| Revert to checkpoint | `checkpoint.rollback{threadId,scopeId,checkpointId,restoreFiles?}` (OV2:3291-3298); failure surfaces in `AppThread.rollbackFailure` (OV2:507-515); must coordinate filesystem + provider conversation, provider that can't roll back rejects before touching files (overview.md:88-90) | |
| Diffs | `orchestration.getTurnDiff{threadId, turn range, ignoreWhitespace?}`, `getFullThreadDiff{threadId,toTurnCount}` | |
| Upload attachment | `attachments.createUploadUrl` → upload → reference `ChatAttachment{id,...}` | detail NOT VERIFIED |

Idempotency: each command carries a client `commandId` (CommandId); server keeps command receipts (glossary :31). Mutations are NOT auto-replayed on reconnect — "retry and idempotency rules belong to the operation" (connection-runtime.md last paragraph).

---------------------------------------------------------------------------
## 5. "Needs the user", notifications, activity log

### 5.1 Server-side attention derivation (the canonical rule)
`packages/shared/src/agentAwareness.ts:60-128` `projectThreadAwarenessV2` / `resolveThreadAwarenessPhaseV2`, input = `ThreadShell`:
 - Skip unlisted threads (subagents/side chats) (:64).
 - `pendingRuntimeRequest.kind === "user_input"` → **`waiting_for_input`** ("Waiting for input") (:101).
 - any other `pendingRuntimeRequest` except `auth_refresh` → **`waiting_for_approval`** ("Approval needed") (:102-107).
 - else by `activityRunStatus ?? status`: preparing/starting→`starting`; running/waiting→`running`; completed→`completed` (but `running` if background tasks hold completion) ; failed→`failed`; idle/queued/interrupted/cancelled/rolled_back→none (:108-127).
 - completed+`latestRunStopRequested` → none (:69); settled (`settledOverride==="settled"`) completed/failed → none (:71-77).
 - Phases enum `starting|running|waiting_for_approval|waiting_for_input|completed|failed|stale` (`relay.ts:20-28`).
 - Note: `hasActionableProposedPlan` is NOT part of awareness phases (plan-ready is not a push trigger) — INFERRED from the function above; a plan wait is visible only via that shell flag.
 - Worth knowing: `pendingRuntimeRequest` is a single summary `{id,kind,createdAt,blocking?}` (OV2:2053-2060); full question/approval content must come from the thread projection/turn item (`approval_request`/`user_input_request`).
### 5.2 Push notifications (mobile)
Via T3 Connect relay: `AgentAwarenessRelay.ts` publishes signed per-thread activity state to the relay (`relay.ts:271-275`, publish proof JWT, `AgentAwarenessRelay.ts:250-286`); per-device prefs `notifyOnApproval/notifyOnInput/notifyOnCompletion/notifyOnFailure`, `liveActivitiesEnabled`, `notificationsEnabled` (`relay.ts:30-40`). Requires T3 Connect login; direct/Tailscale alone gives no push (`docs/user/mobile-notifications.md:5,11`). **Not usable by Fjord** — Fjord should derive the same from the shell stream locally. There is no local push/webhook feed (INFERRED).
### 5.3 Read/unread state
Server stores a per-thread watermark `lastVisitedAt` (set by `thread.visit`, cleared-ish by `thread.mark-unread`). There is no server-computed `unread` boolean in `ThreadShell`; the client compares `lastVisitedAt` vs `updatedAt`/`latestRun.completedAt` (`packages/client-runtime/src/state/threadVisits.ts:93-135`: "unseen" = `lastVisitedAt` missing or older than `updatedAt` / run completion; wake messages count). INFERRED rule for Fjord: unread ⇔ `lastVisitedAt == null || lastVisitedAt < max(updatedAt, latestRunCompletedAt)` — the web client dispatches `thread.visit` with `visitedAt = shell.updatedAt` while the thread is open (throttled).
### 5.4 Activity log
`docs/user/activity-log.md` is purely UI grouping of tool turn-items (commands, file changes, orchestrator summaries); data = `turn-item.updated` events (`command_execution`, `file_change`, `dynamic_tool`, `subagent`...) plus live stdout via `orchestration.subscribeCommandOutput{threadId,itemId}` (frames `{kind:"replace"|"append",text,truncated,running}`, OV2:3597-3613). Diagnostics logs are separate (`~/.t3/userdata/logs`).
`notification` turn items/messages (`OrchestrationV2Notification{source{kind: delegated_task|subagent|command|monitor|background_task|system}, outcome completed|failed|cancelled|updated|unknown, summary, detail?}`, OV2:1276-1282) are agent-internal wake-ups (background task finished), not user push.

---------------------------------------------------------------------------
## 6. Summarization / text generation on the server

 - Service: `TextGeneration` (`apps/server/src/textGeneration/TextGeneration.ts:42-44`) implements `ProviderTextGeneration` with **five fixed operations only**: `generateCommitMessage`, `generatePrContent`, `generateBranchName`, `generateThreadTitle`, `generateReviewGuide` (`packages/provider-core/src/server/textGeneration.ts:100-120`; dispatcher TextGeneration.ts:116-153). Inputs are typed per op (e.g. `ThreadTitleGenerationInput{cwd, message, previousTitle?, forkSource?, attachments?, instructions?, linkedContext?, modelSelection}`, textGeneration.ts:59-72). **No generic "summarize this text" op and no RPC/HTTP exposure**: `generateThreadTitle` is referenced only by textGeneration/*, `ThreadTitleRegenerationService.ts`, and `provider/Drivers/CodexManagedProvider.ts` (grep) and no WS method maps to it (`rpc.ts` WS_METHODS list, :408-601). Thread titles are produced as a side effect of `message.dispatch{titleSeed}` / `launchThread{generateTitle}` / `thread.metadata.update{regenerateTitle}`. → **It cannot replace Fjord's Haiku summaries**; it only produces short titles/commit/PR text.
 - Model/provider choice: setting `textGenerationModelSelection: ModelSelection` (`settings.ts:1076, 1318-1330`; default Codex + `DEFAULT_TEXT_GENERATION_MODEL` low reasoning effort); `threadTitleInstructions`, `sourceControlWriterModelSelection`, `reviewGuideModelSelection` (settings.ts:1039-1045). **Live config on this Mac** (`~/.t3/userdata/settings.json`): `textGenerationModelSelection = {instanceId:"codex", model:"gpt-6-luna", options:[reasoningEffort=low, serviceTier=default]}`, `defaultModelSelection = {instanceId:"claudeAgent", model:"claude-opus-5-5"}`, `defaultRuntimeMode:"auto"`, `compactIdleThreads:true`, `idleCompaction:"beforeCacheExpires"`.
 - Fallback: if the chosen instance's usage window is exhausted, it automatically picks another enabled, installed, authed, text-gen-capable instance (TextGeneration.ts:64-114 via `exhaustedUsageWindow` / `fallbackTextGenerationModelSelection`).
 - Implementation detail: Claude backend shells out to `claude -p --output-format json --json-schema <schema> --model … --tools "" --disable-slash-commands --strict-mcp-config --permission-mode dontAsk` in a temp dir for titles (`textGeneration/ClaudeTextGeneration.ts:~190-225`). Codex/Grok/Antigravity/OpenCode2 have sibling files.
 - Other "summaries": `compaction` items & `ContextHandoff.summaryText` are provider-context machinery (not user briefs); `latestVisibleMessage` on the shell is just the raw last message text (OV2:2063-2068, 2111). Review guide generation (`pullRequests.generateReviewGuide`) is PR-specific.
 - Implication: Fjord must keep its own summarization (call Claude/Haiku itself) fed from `ThreadTranscript`/projection data. T3 supplies cheap structured inputs: `latestVisibleMessage`, `proposed_plan.markdown`, `user_input_request.questions`, `approval_request.prompt/reason`, `error.failure`, `Run` timings.

---------------------------------------------------------------------------
## 7. Where Fjord's current "Claude Code sessions" fit (flag for other slices)

 - T3 doesn't tail arbitrary external Claude Code transcripts. Two bridges exist: (a) **import**: `agentSessions.scan` / `agentSessions.import` find and import Claude/Codex/Pi sessions from disk into T3 threads (`rpc.ts:424-425`; `packages/contracts/src/agentSessions.ts:5-50`: `AgentSessionSource = claudeAgent|codex|pi`, with `providerSessionId`, `filePath`); `thread.create.importedNativeThread` (OV2:2923). Whether import is one-shot or stays in sync with the external CLI is NOT VERIFIED. (b) **Outside agents via MCP**: terminal Claude Code can read/start/message T3 threads through `/mcp` (`docs/user/outside-agents.md:1-12`) — the reverse direction.
 - Therefore sessions Fjord watches today (started in a terminal) would NOT appear in T3's shell stream unless started/resumed through T3. This is the key architecture question for another slice. (INFERRED.)

---------------------------------------------------------------------------
## 8. Assessment — cleanest way for a Swift app to be a full client

**Is there an official, stable contract for non-TS clients? No.**
 - `@t3tools/contracts` is `"private": true`, version `0.1.6` (app is 0.1.7), `exports` point at raw `.ts` source, no build to a package/registry (`packages/contracts/package.json:2-18`). Source is Effect `Schema` TypeScript. I found no checked-in JSON Schema / OpenAPI / protobuf export (looked via `ls packages/contracts` → only `package.json, src, tsconfig.json`; targeted grep for toJsonSchema unreliable due to shell glob — treat as "none found", re-verify with `grep -rn "JsonSchema" packages/contracts/src`).
 - Stability signals: the project is explicitly pre-1.0 beta. Compatibility is **additive and capability-based** rather than versioned-frozen: `ORCHESTRATION_PROTOCOL_VERSION = 2` gates the socket (426 on mismatch, ws.ts:3433-3443); unknown event/turn-item types are tolerated by official clients (OV2:3851-3882, 1821-1842); optional fields everywhere "Absent from older servers" (e.g. OV2:2058, 2110); descriptor `capabilities` flags; "Remote servers can outlive several client releases. Clients must use advertised capabilities and handle their absence" (remote.md). Scope/permission responses keep a legacy `scopes` vocabulary plus `permissions` (environment-auth.md:93-99). `pairing`/CLI: `t3 pair` refuses incompatible protocol versions (cli/pair.ts:~500-511). No semver promise for the wire beyond that.
 - The server does ship its own **replay fixtures**: `ProviderReplayTranscript` NDJSON schemas (OV2:4279-4323), useful as test data, and `docs/orchestration-v2/testing-strategy.md`.

**Recommended approach (ranked)**
 1. **Native Swift client over the real WS-RPC protocol** (what web/mobile do), pinned to `orchestrationProtocol=2` and to a tested server version range; feature-gate on descriptor `capabilities`; decode leniently (unknown enum cases/union tags → skip, optional everything not in a small required core). Hand-write `Codable` for the ~15 types Fjord needs: `ThreadShell`, `ShellStreamItem`, `ThreadStreamItem`, `DomainEvent` (the ones relevant), `RuntimeRequest`, `UserInputQuestion`, `ApprovalOption`, `TurnItem` subset, `Run`, `ModelSelection`, `ChatAttachment`, `Command` subset. Port the reducer from `client-runtime/src/state/orchestrationV2Projection.ts`. Main risk: implementing the Effect-RPC JSON framing in Swift (unverified, §3.1) — spike this first by sniffing `packages/client-runtime/src/rpc/client.ts` and a live socket.
 2. **Thin sidecar (Bun/Node) that embeds `@t3tools/client-runtime` + `@t3tools/contracts` directly** and exposes a simpler local API (JSON-over-stdio or unix socket) to Swift. Removes framing/versioning risk and gives schema-checked decoding at the cost of shipping a JS runtime; contracts aren't published so you'd vendor/pin the monorepo tag (INFERRED).
 3. **Read-only HTTP polling** of `/api/orchestration/shell` + `/threads/:id` (+ `x-t3-orchestration-protocol: 2`, Bearer) for observation, with writes still needing the WS (no HTTP dispatch). Good for a first milestone (attention/briefing) before doing the RPC framing.
 4. **MCP route** (`/mcp`, OAuth/PKCE, tool surface in `apps/server/src/mcp`, docs/orchestration-v2/orchestrator-mcp-server.md): official, designed for outside agents, narrower (runtime-mode ceiling, no pending-question response? NOT VERIFIED). Possibly good for "send message / start thread" but not for a live observer. Don't rely on it for approvals (NOT VERIFIED).

**Credential recipe for Fjord (verified from source, not executed)**: ensure server running (read `~/.t3/userdata/server-runtime.json` for `origin`; check `pid` alive) → `~/.t3/bin/t3 auth session issue --scope orchestration:read --scope orchestration:operate --label Fjord --ttl 365d --token-only` (flags per cli/auth.ts:169-203, authScopes.ts) → store token in Fjord's Keychain → `ws://127.0.0.1:3773/ws?orchestrationProtocol=2` with `Authorization: Bearer <token>`. (I did not run it: minting a session mutates the user's auth DB; do it only with the owner's go-ahead.)

**Known gaps in this report (not verified)**: exact Effect-RPC frame JSON; per-RPC required scopes; answer value shapes for multi-select questions; attachment upload wire format; whether `agentSessions.import` keeps syncing with terminal Claude Code; the `ExecutionNode`/`Subagent` struct details; where provider rate-limit windows are carried in `server.getConfig`.
