# F1 — How Fjord observes and understands sessions, and every model call it makes

Scope: Sources/Fjord (paths below are relative to it unless prefixed `docs/`). Read-only inventory; no git, no app runs.
"INFERRED" marks anything not stated directly by code/comments. Line numbers are from the files as read in this session.

Files read in full: Claude.swift, ClaudeProcesses.swift, ClaudeLinkStatus.swift, Router.swift, RouterStatus.swift, RouterStream.swift,
RouterRun.swift, RouterBrief.swift, RouterBriefEngine.swift, RouterBriefSource.swift, RouterCardJudge.swift, RouterRoute.swift,
RouterJev.swift, Jev.swift, RouterFormReply.swift, YourMessages.swift, GuestTranscripts.swift, SessionControl/Fence/Glyph.swift,
Agents.swift, Peers.swift, CourierLocal.swift, RouterProjectContext.swift, RouterProjectDecide.swift.
Read in part (targeted): Store.swift (Claude/persistence parts), ClaudePlugin.swift, Forms.swift, RouterDispatcher.swift, RouterMCP.swift,
RouterCarry.swift, RouterPrepare.swift, RouterProjectProposal.swift, RouterBriefs.swift, RouterCourier.swift, CourierCore/Board.swift,
GuestRouterRuntime/DesktopStart/RouterPaths.swift, JevGate.swift, LevelDB.swift, RouterDecisions.swift.
Not relevant to observation (checked by grep, no Claude artifact use): Clock.swift, Signposts.swift, Lifecycle.swift (only reads `allAgentRows`),
AutomaticCheckpoint.swift (Silo checkpoints), Tools.swift (label strings), AgentTools.swift (Silo guest Node/Claude CLI install labels),
RouterChangeGate.swift, RouterCapabilities.swift, RouterDrawer.swift, RouterBriefDoc/Markup.swift (pure doc/markup parsing; model output schema lives in BriefDoc, not read in full).
NOT read in full (gap): RouterBriefDoc.swift (`BriefDoc.schema`/`parse`/`checked`), RouterBriefView.swift, RouterChangeGate/Capabilities/Fjord/Drawer bodies, RouterProjectProposal body, RouterCarry body, RouterMCP body beyond `board`/`answer` specs, SessionIcons.swift.

---------------------------------------------------------------------------------------------------------------------------------
## 0. Big picture (what the observation stack is)

Fjord never talks to a Claude API directly for sessions. It has FIVE observation channels on a Claude Desktop + Claude Code install, plus one plugin/hook layer it installs itself:

| # | Channel | Artifact |
|---|---|---|
| A | Claude Desktop session metadata | `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json` |
| B | Claude Code transcripts | `~/.claude/projects/<project>/<cliSessionId>.jsonl` (+ subagent transcripts, `.meta.json`) |
| C | Claude Code live-process registry | `~/.claude/sessions/<pid>.json` + libproc/sysctl process table |
| D | Claude Desktop sidebar unread dots | Chromium LevelDB `Application Support/Claude/Local Storage/leveldb`, key suffix `epitaxy-unread-v1` |
| E | Background tasks | `/private/tmp/claude-<uid>/<project>/<cliID>/tasks/<id>.output` (symlink to subagent transcript, or command output file) + open-file scan |
| F | Fjord-installed hook + plugin (writes into Claude Code) | `~/.claude/settings.json` PermissionRequest hook; Claude Code plugin `fjord` (presence, inbox, carry, abort) |

Plus: running Claude Code headless (`claude -p`) for model calls (Haiku/Sonnet), and the Claude Desktop app's own `claude://` URL scheme for opening sessions.
Cross-cutting fragility statement in code: "Nothing here is a public API: every field is optional on disk, and anything unexpected is skipped rather than trusted." (Claude.swift:5-6). UI string for format break: "The app's session format changed" (ClaudeLinkStatus.swift:12).

---------------------------------------------------------------------------------------------------------------------------------
## 1. Dependency entries

### 1.1 Session list: title, folder, archived, last activity, turn summary (Channel A)
- **User sees:** the Router's rows/brief: session title, project (folder) colour/name, working/needs-you/done/idle dot, "Synced with Claude" status line.
- **Mechanism:** enumerates `Claude.sessionsDir = ~/Library/Application Support/Claude/claude-code-sessions` recursively for `local_*.json` (Claude.swift:73-76, 166-173). `Claude.bundleID = com.anthropic.claudefordesktop` (73). Re-decodes only files whose mtime changed (160-195). `isInstalled` = app registered or sessionsDir exists (81-84).
- **JSON fields read** (Raw, Claude.swift:102-128): `sessionId` (must start `local_`, 131), `cliSessionId`, `title`, `cwd`, `originCwd`, `gitAnchorsFolderRealpath`, `isArchived`, `completedTurns`, `createdAt`, `lastActivityAt`, `lastFocusedAt`, `latestUserFrameAt` (all ms epoch), `postTurnSummary{status_category,status_detail}`, `postTurnSummaryFor`, `lastAssistantUuid`, `sshConfig.sshHost`.
- **CourierLocal reads a second, richer set of the same files** (CourierLocal.swift:25-76): `remoteControlSpawn{ccrSessionId,folder,projectThreadChild}`, `bridgeSessionIds[]`, `cliSessionId`, `gitAnchors[0].gitRoot`, `cwd`, `lastActivityAt`, `isArchived`, `title`, `postTurnSummary{status_detail,needs_action,status_category,interruptedAwaitingPerson}`, top-level `interruptedAwaitingPerson`. Feeds the Courier "Board" (claude.ai projects/threads engine).
- **Data extracted:** title (default "Untitled session" 149), folder (worktrees collapse to git anchor; scratch = path containing `/Claude/scratch-workspaces/` → nil, 136), archived, completedTurns, lastActivity/lastFocused/lastUserMessage, summary {blocked: status_category=="blocked", detail}, cliID, sshHost. `activity` signature string `"completedTurns|latestUserFrameAt"` (34) drives unread logic.
- **Status derivation (running):** summary is "current" only when `postTurnSummaryFor == lastAssistantUuid` (140). `running = appRunning && !current && !archived && latestUserFrameAt within runningTimeout (2h)` (146-147, 79). Recomputed every read because it depends on clock and whether the Claude app process is running (184-190). So "running" is a heuristic from desktop-file state, later overridden by the plugin presence `turn` (1.7).
- **needs-you flags from desktop file:** `summary.blocked` → group needsYou only if unread (Agents.swift:118); CourierLocal: `needs_action`, `interruptedAwaitingPerson`, or category "blocked" → "needs_you"; "completed"→"resolved"; "review_ready"→"idle" (CourierCore.swift:112-119).
- **Timing:** FSEvents on the sessions dir (Store.swift:683, FolderWatcher Claude.swift:972-1028, latency 0.2s) + NSWorkspace launch/terminate/activate of Claude app (Store.swift:704-706) + screens sleep/wake (707-722) + one-shot timer at first expiry (2h running timeout, 60s while background tasks exist) (Store.swift:730-763).
- **Fragility notes in code:** "Nothing here is a public API" (Claude.swift:5); `.unreadable` link state if files exist but none decode (193); `Claude.open` uses the app's private deep link `claude://claude.ai/epitaxy/<id>` ("its own link format", 94-97).

### 1.2 Live activity: what a working agent is doing (Channel B)
- **User sees:** second line on a working row ("Editing foo.swift", "Running …", "Thinking", "Writing"), todo progress, latest narration, and "Asks your OK to …" prompts.
- **Mechanism:** finds `~/.claude/projects/*/<cliID>.jsonl` by listing every project dir (Claude.swift:200-201, 332-340; cached). Reads the last 96 KB (`tail`, 343-349), parses lines in reverse (`Claude.activity(tail:)`, 355-409).
- **Transcript line fields read:** `type` ("assistant"/"user"), `timestamp` (ISO8601 fractional), `message.content` (string or blocks), block `type` text/tool_use/tool_result, `tool_use.name/id/input`, `tool_result.tool_use_id`, `message.stop_reason` (578-591), `uuid`, `parentUuid`, `cwd`, `isMeta`, `isSidechain`, `isCompactSummary`, `toolUseResult` (YourMessages.swift:28-38).
- **Data extracted:** last tool → human sentence via `describe(tool:input:)` (593-632) for tools Bash(description/command), Edit/MultiEdit/NotebookEdit/Write/Read(file_path/notebook_path), Grep/Glob(pattern), Agent/Task(description), WebSearch, WebFetch(url host), TodoWrite, AskUserQuestion(questions[0].question), ExitPlanMode(plan first heading), Skill(skill), `mcp__<server>__*`. `waitsForYou` = last tool_use is `AskUserQuestion` or `ExitPlanMode` (375), carrying `tool` and `toolUseID`. Narration = last assistant text block (≤600 chars) since the current user message (387-395). Todo = last `TodoWrite` input `todos[].status/activeForm/content` (396-403).
- **Status derivation:** purely last-line heuristic: last assistant tool_use → tool description; assistant text → "Writing"; thinking-only → "Thinking"; user line (tool_result or message) → "Thinking" (370-385). Turn-end check `transcriptEndedTurn`: last assistant `stop_reason` in {end_turn, stop_sequence}; a user line last → not ended (578-591) — used for guest sessions without plugin turn field.
- **Timing:** FSEvents on `~/.claude/projects` with latency 0.5s and a `relevant` filter (only paths of working sessions or sessions with background tasks) (Store.swift:693-695, ClaudeFeed.isRelevant Claude.swift:1302-1306). Cache keyed by file mtime (Claude.swift:303-330). Activity only read for sessions where `running` (1345-1349).
- **Fragility:** whole feature rests on Claude Code's private transcript JSONL schema and tool names (hard-coded tool-name switch). "Only the lines that can hold them are parsed" for perf (354).

### 1.3 Permission prompts of ordinary tools (Channels B + C + F)
- **User sees:** a session row flips to needs-you with "Asks your OK to run `cmd`" / "edit X" etc.
- **Mechanism:** Fjord's hook (FormHook, `PermissionRequest` matcher `*`, Forms.swift:306-316, 642-646) writes a note JSON per prompt to `Application Support/Fjord/permissions/<session>-<ms>-<pid>.json` with `tool_name`, `tool_input`, `tool_use_id?`, `created_at` (Forms.swift:446-457; PermissionNote.read Claude.swift:493-523). Hook "prints nothing, so Claude Code's own prompt goes on untouched" (Forms.swift:446-449).
- **Ending the prompt:** Claude Code emits no event on approval. Ends when (a) the call's `tool_result` appears in transcript tail (or is found by backward scan, `locating`/`forEachLineBackward`, Claude.swift:455-489, `mergingPermission` 528-545), or (b) for Bash only, the approved command appears as a child process of the session's Claude Code pid whose argv is Claude Code's wrapper `<shell> -c '… && eval '<cmd>' < /dev/null && …'` (ClaudeProcesses.swift:55-80) detected with libproc `proc_listpids(PROC_PPID_ONLY)`, `PROC_PIDTBSDINFO`, sysctl `KERN_PROCARGS2` (ClaudeProcesses.swift:13-52) and a DispatchSource fork/exec watch (`CommandWatch`, 96-152).
- **Dependency on registry (C):** pid of session found via `~/.claude/sessions/*.json` (`sessionId`, `startedAt`) (Claude.swift:239-244, Peers.swift:40-53). Notes of sessions with no live process are deleted (Claude.swift:247-268).
- **Fragility recorded:** "Claude Code sends no event when a prompt is approved; the approved command starting is the sign" (Claude.swift:271-273; ClaudeProcesses.swift:82-84). The `eval '…'` wrapper shape is a private Claude Code detail. Hook decision format for plans "checked against Claude Code 2.1" (Forms.swift:311).

### 1.4 Questions / plans (AskUserQuestion, ExitPlanMode) via hook (Channel F)
- **User sees:** brief entries with options; answer by number/Return or free words; plan approve/keep planning.
- **Mechanism:** `PermissionRequest` hook entry in `~/.claude/settings.json` (matcher `*`, command = `fjord-form.sh` / `fjord-dev-form.sh`, timeout 86400) installed by `FormHookInstaller` (Forms.swift:608-760), backup `settings.json.fjord-backup` (639). `Fjord --form-hook` holds the form file in `Application Support/Fjord/forms/` (`PendingForm`: `<session>-<ms>-<pid>`, questions, optional plan, hook pid, tool_use_id) and prints a permission decision when Fjord writes an answer file: `{"answers":{question:answer}}` or `{"plan":{"approve":Bool,"feedback":String}}` (Forms.swift:269-285). Decision JSON: `hookEventName: PermissionRequest`; plan Approve = `allow` with input as it came; Keep planning = `deny` with Claude Code's own rejection words (311-313, 410-420). Hook follows the transcript to see the question answered in-app (480-483).
- **Data:** question text, options (label, description), multiSelect, plan Markdown, tool_use_id (ties to the transcript's `toolUseID`, Claude.swift:45-46).
- **Fragility:** a bare `allow` "is ignored for this tool" so input must be echoed (Forms.swift:311); hook JSON schema from Claude Code; settings.json is co-written by Claude Code (retry on change, 607).

### 1.5 Process registry / peers (Channel C)
- **Mechanism:** `~/.claude/sessions/<pid>.json`: `pid`, `sessionId`, `hostSessionId` (the desktop `local_` id), `name`, `startedAt`, `entrypoint` (`claude-desktop`), `status` (`busy`/`idle`), `updatedAt` (Peers.swift:13-53); liveness via `FormBridge.processAlive`. CourierLocal also reads `status` and alive per cli id (CourierLocal.swift:38-44).
- **Uses:** pid for command watch; "peer" name for `SendMessage to`; carrier choice: process with `entrypoint == "claude-desktop"`, idle before busy (RouterCarry.swift:104-119); stranded detection (local thread seen alive then gone → "stranded", or "waiting_app" if Claude app closed) (CourierBoard.swift:93-105); working = `status == "busy"` (CourierCore.swift:113); plugin presence validity (1.7).
- **Fragility:** whole registry format is Claude Code-private; Peer name `[ref]` disambiguation (Peers.swift:55-70).

### 1.6 Sidebar unread dots (Channel D)
- **Mechanism:** minimal LevelDB reader (log/ldb/sst + Snappy) for the key ending `epitaxy-unread-v1` in `Claude/Local Storage/leveldb` (Claude.swift:947-953; LevelDB.swift). Chromium local-storage value: first byte 1=Latin-1, 0=UTF-16LE; JSON `{state:{unreadIds:[…]}}` (955-967). FSEvents latency 2s (Store.swift:687-689).
- **Data:** set of unread session ids → `AgentEntry.unread` (Agents.swift:460-464); persisted as `agents.appUnread`.
- **Fragility:** "The app writes this to disk lazily (up to ~30 s late)" (Claude.swift:949); reading another app's Chromium LevelDB while it runs "no locking: whatever is on disk now" (LevelDB.swift:3-5).

### 1.7 Fjord's Claude Code plugin: presence, turn state, inbox, carry, abort (Channel F)
- **User sees:** accurate "running"; messages delivered as the user's own words; Cancel (abort) of a sent message.
- **Mechanism:** Fjord writes a Claude Code plugin (marketplace folder `Application Support/Fjord/claude-plugin`, names `fjord`/`fjord-dev`, guest `fjord-guest`) and installs it via the Claude Code CLI (ClaudePlugin.swift:12-31; Router.swift:246-270 using `ClaudePluginInstaller`, binary found by `RouterStatus`). Plugin source is TS embedded in Swift (`register`, ClaudePlugin.swift ~207+).
- **Presence file** (per session, written by plugin to `Application Support/Fjord/plugin-sessions/<cliSessionId>`): `{state:"live", sessionId, pid, startedAt, keyId, renewedAt, activation, capabilities[], turn:{id,startedAt}|null}` (ClaudePlugin.swift:103-143, 446). Valid only if: state live, keyId equals current relay key id, `renewedAt` within 30 s lease (renewed every 10 s), pid alive, and `~/.claude/sessions` registry has same sessionId+startedAt for that pid (173-188).
- **Status derivation:** if presence has a `turn` field, `session.running = turn != nil` (overrides desktop-file guess) (Claude.swift:1205-1231). Re-scan on presence-folder FSEvents (0.5s) and at lease expiry (Claude.swift:1104-1185).
- **Capabilities:** `inbox-v1` (signed messages polled from `relay/<session>/<nonce>.msg`, ack `.ack`), `abort-v1` (stop a turn), `carry-v1` (plugin of another desktop session calls the app's `ccd_session_mgmt.send_message` MCP tool) (ClaudePlugin.swift:198-206, comments 235-260).
- **Plugin API used (Claude Code private plugin engine):** `import type { EngineInterface, Register } from 'claude-code'`, `$.session.id()`, `$.fs.read/write/list`, `$.clock.now()`, `$.mcp.call('ccd_session_mgmt','send_message',{session_id,message})`, `session.receive`, `prompt.submit` rewrite, peer channel messages signed `⟦fjord v1 <target> <nonce> <ms> <HMAC-SHA256>⟧` + base64 body (ClaudePlugin.swift:~207-260).
- **Fragility recorded:** "Claude Code has no way to take a submitted prompt back out"; app envelope `<cross-session-message from= name=>` behaviour; `--plugin-dir` plugin overrides installed one of same name; Claude Desktop copies the Mac's `fjord` plugin into SSH sessions without hooks (hence `fjord-guest`) (ClaudePlugin.swift:29-31). Per-app version bumps via digest of sources (22-26).
- **Docs:** docs/design/session-wake.md (Claude app 3.1623.0 caps Claude Code processes at `max(6, RAM/3GB)`; sleeping sessions can only be started via the app's `send_message` from a running CLI; `claude://code/new?q=`; "There is no local API, AppleScript, XPC or watched folder").

### 1.8 Background tasks: subagents and shell commands (Channel E)
- **User sees:** "3 running" after a turn ends; session stays "working".
- **Mechanism:** `tasksRoot = /private/tmp/claude-<uid>` → `<project>/<cliID>/tasks/<id>.output` (Claude.swift:638). `.output` that is a symlink = subagent transcript (target `.jsonl`, sibling `.meta.json` with `description` for title, 919-923); regular file = background shell command, "running" iff some process of the user has it open (`proc_pidfdinfo PROC_PIDFDVNODEPATHINFO`, 740-757). Command title: found by searching transcript for `with ID: <id>.` then the tool_use input `description`/`command` (926-943). End of a task: transcript contains `<task-id>ID</task-id>` notice (894-917); subagents dead after 30 min of no transcript mtime change (640). Subagent activity = same tail parser on its transcript (886-891).
- **Timing:** folder-stamp cached listings (stat ctime/mtime of folders) so a half-second cadence is cheap (1030-1047, 674-736); open-files walk cached 2 s (1398-1412); tick every 60 s while tasks exist (Store.swift:744).
- **Fragility:** relies on Claude Code's temp layout and `<task-id>` notice text.

### 1.9 "Your messages" in a transcript
- YourMessages.swift:21-57: user-typed entries only — `type:"user"`, has `uuid`, not `isMeta/isSidechain/isCompactSummary`, no `toolUseResult`, no `tool_result` block; excludes text starting `<command-name>`, `<command-message>`, `<local-command-`, `<bash-input>`, `<bash-stdout>`, `<bash-stderr>`, `<task-notification>`, `<system-reminder>`, `Caveat: The messages below`. Extracts uuid, parentUuid, text, cwd, timestamp. Used for guest-session evidence matching (GuestDesktopStart.swift:13-50).
- `Claude.firstMessage(head:)` (Jev.swift:318-331): first non-meta user text not starting `<`, ≤2000 chars, from first 256 KB of transcript — input to icon picking (Agents.swift:544).

### 1.10 Result text / purpose for the Courier "Board" (Channel A+B)
- CourierLocal.result (CourierLocal.swift:94-112): scans last 100 KB of `<cli>.jsonl`, takes last assistant `text` blocks joined, last 1500 chars; only if session active within 2 days. `purpose(folder)` reads the repo's `README.md` prose, 600 chars (79-91). Feeds the project decider / briefs. Sessions kept only if not archived, active within 21 days (`CourierLook.freshDays`, CourierCore.swift:104), non-scratch (home, `scratch-*`, `/tmp`, `/var/folders` rejected, CourierLocal.swift:49-55).
- Read triggered by FSEvents on sessions dir + registry dir + Claude launch/terminate; "never on a timer" (RouterCourier.swift:130-140; CourierLocal.swift:4-6).

### 1.11 Remote ("computer"/SSH guest) sessions (guest transcripts)
- Desktop SSH sessions run Claude Code on a guest. Fjord reads guest files via Silo `guest.files` (not local FS): `<home>/.claude/projects/*/<cli>.jsonl` (tail 1 MB, requires exactly one match), `<home>/.claude/sessions/*.json` (`sessionId`, `hostSessionId`, `pid`, `startedAt`), presence at `~/.local/share/fjord/router/presence`, key `…/relay.key`, `…/.claude/settings.json` hook (GuestRouterPaths.swift:17-33; GuestTranscripts.swift:59-97; GuestDesktopStart.swift:82-169). Liveness: `/bin/kill -0 pid` via guest exec (GuestDesktopStart.swift:~126). Running = plugin `turn` else `!transcriptEndedTurn(tail)` (GuestRouterRuntime.swift:514-516). Activity = same `Claude.activity(tail:)` (GuestTranscripts.swift:14). Local `ssh-<id>` mirror is "never consulted" (GuestTranscripts.swift:3). Background tasks on guest: GuestBackgroundTasks.swift (reads `.jsonl` symlink targets, tail 256 KB).
- Desktop mirrors set `sshConfig.sshHost` in the local session file (Claude.swift:23, 153).

### 1.12 Claude Code binary discovery (for model calls and plugin install)
- `RouterStatus.defaultRoot = ~/Library/Application Support/Claude/claude-code`; binary at `<version>/<hash>/claude.app/Contents/MacOS/claude`; highest numeric version wins (RouterStatus.swift:4-34). Re-resolved at every send "a send runs the app's bundled Claude Code, the version its sessions run" (66-72). UI: "Claude Code wasn't found. Install or open the Claude desktop app." (RouterView.swift:502).

### 1.13 Claude-the-brand dependencies in UI (low risk but listed)
- `ClaudeDot` mimics "Claude's session status dot (§1.7)" colours (SessionGlyph.swift:53-57); `ClaudeDesign.swift`, `ClaudeMark.swift`, `ClaudeButton`, "Open in Claude" (RouterBriefView.swift:688-691). `Claude.open(id)` → `claude://claude.ai/epitaxy/<id>`. Frontmost/running detection by bundle id (Claude.swift:86-92).

### 1.14 claude.ai Projects (Courier engine) — outside this slice, noted
- Messages to claude.ai projects/threads go through a Chrome-extension "Courier" engine (CourierHost etc.); local Claude sessions are inputs to its Board (`local` input, CourierCore.swift:142-170). Designed in docs/design/router-watch-and-briefs.md, router-swift-port.md. Briefs are built from that Board (RouterBriefSource.swift).

---------------------------------------------------------------------------------------------------------------------------------
## 2. How the derived status is assembled (summary table)

| Output | Source priority |
|---|---|
| `session.running` | plugin presence `turn` (if fresh & bound to live registry pid) > desktop file heuristic (no current summary & user frame <2h & app running). Guest: plugin turn > transcript stop_reason. (Claude.swift:146-147,1224-1231; GuestRouterRuntime.swift:516) |
| group needsYou | `running && activity.waitsForYou` (AskUserQuestion/ExitPlanMode in transcript, or hook permission note unresolved) > `unread && summary.blocked` (Agents.swift:115-123) |
| group working | running, or tasks non-empty (background subagents/commands) |
| group done | `entry.unread` (turn finished and not viewed; sidebar dot) |
| unread | `completedTurns` increase while not the focused session; sidebar LevelDB dot appears/disappears; `lastFocusedAt` advance clears (Agents.swift:441-465) |
| Brief entries | Board thread status "needs you" + card/permission/stranded; Haiku writes prose over items (1.x below) |

---------------------------------------------------------------------------------------------------------------------------------
## 3. Every model call

All model use is either (a) `claude -p` one-shots through the Claude Desktop-bundled Claude Code binary (OneShot.run, RouterPrepare.swift:28+, `cwd = Application Support/Fjord/router`), or (b) TypeSafe "Jev" HTTPS. No Anthropic API key is used anywhere in this slice; all Claude calls ride the user's Claude Code login. No Opus call exists (the only "opus" hit is a display string, RouterDecisions.swift:267).

Common flags on every `claude -p` call: `--tools ""` (no builtin tools), `--setting-sources ""`, `--strict-mcp-config`, `--no-session-persistence`, prompt on stdin, cwd = Router home (0700).

| # | Call | Where | Model | Purpose | Args beyond common | Input | Output schema |
|---|---|---|---|---|---|---|---|
| M1 | Project brief | RouterBrief.swift:21-41 via RouterBriefEngine.runCall (RouterBriefEngine.swift:468-486) | `claude-haiku-5-5`, timeout 30 s | Rewrite one project's brief from new log items | `--output-format json`, `--json-schema <BriefDoc.schema>`, `--system-prompt RouterStyle.prompt(rules, style)` | "Current brief" (purpose, now, needs_you, decisions, loose_ends, threads) + new items each in `<session-content untrusted="true">` (RouterBriefEngine.swift:568-585), redacted by `RouterTools.redacted` | `BriefDoc.Prose`: now[], needs_you[{thread,kind,question,options}], decisions[], loose_ends[] (schema in BriefDoc, NOT read; described rules.swift:248-270). Result read from `structured_output`, else text (RouterBrief.swift:35-40) |
| M2 | Project purpose | RouterBriefEngine.purposeCall (559-564) | Haiku | One-line purpose from goal/instructions | same | goal text fenced | `{"purpose":string}` |
| M3 | General brief lead | RouterBriefEngine.batchEnd (636-655) | Haiku | Top-of-brief "for_you"/"worth_a_look" across projects | same | each project's `now`, needs-you, finished (leadContext 600-619) | `leadSchema` `{for_you,worth_a_look}` (285) |
| M4 | Router run (judgment) | RouterRun.swift:84-205, dispatched by RouterDispatcher.think (666-683) | `claude-haiku-5-5`, 90 s | Answer a question about Fjord state / change Fjord settings via tools | `--mcp-config <tmp json> --strict-mcp-config --allowedTools mcp__fjord --output-format stream-json --verbose --include-partial-messages --json-schema {reply,done} --append-system-prompt <role>` (RouterRun.swift:137-142) | State block (briefs' entries, working sessions, last 10 decisions, tagged projects) fenced + user message (RouterRunContext.text 41-58) | `{reply:string, done:string}` via `structured_output` (156) or JSON-in-text fallback (159-166). Stream parsed live (`RouterRunStream`: `stream_event` content_block_start/delta; `StructuredOutput` tool_use; `thinking_delta`; `input_json_delta`, 275-319) |
|  | its tools | local HTTP MCP server per run (RouterMCPServer, RouterRun.swift:181-198): `board`, `answer`, + FjordTools (settings/Triage changes) (RouterMCP.swift:589-600) | | | | | |
| M5 | Project decider (route a message) | RouterProjectDecide.swift:104-120, 296-323 | `claude-sonnet-5-5`, 90 s, only after Jev under 0.7 | Where does the user's message go (thread / project / new work / answer here / ask) | `--output-format json --json-schema <ROUTE_SCHEMA> --append-system-prompt <ROLE>` (306-309) | "Board:" text of projects/threads (state, doing, summary, you-last-told, last answer ≤600 chars, waiting) + redacted message (sonnetPrompt 240-246; RouterProjectContext.board 119-133) | `{action: follow_up|new_work|answer_here|ask, project, session, reason, confidence, project_confidence, alternatives[], need[]}` (235). Acted on at ≥0.8, thread at ≥0.8 (91-96) |
| M6 | Proposal reviser | RouterProjectProposal.swift:985-1111 | Sonnet (`RouterProjectDecider.model`), 90 s | Revise a new-project proposal from user words | same as M5 | proposal JSON + message + words, secrets replaced by numbered `[redacted-N]` then restored | `{name,folder,repo,instructions}` |
| M7 | Delivery | RouterRun.swift:436-560 | none | No model; signed relay via plugin inbox or carrier | — | — | — |

Non-Claude model calls (Jev, TypeSafe, `https://api.typesafe.ai/v1/systemone`, model `jev-latest`, Bearer key from Keychain; Jev.swift:5-8, 101):
- J1 routing: first stage of the project decider; one structuredChoice over places/threads, taken at confidence ≥0.7 (RouterProjectDecide.swift:79-117, 195-215).
- J2 plan approval: noul "does the message approve the plan as it is" ≥0.7 (RouterFormReply.swift:10-27, CardJudge.sure 0.7 RouterCardJudge.swift:10).
- J3 form answers: one choice per question (option ids o1…, "other"), noul per option for multiSelect; 10 s timeout (RouterFormReply.swift:39-96).
- J4 session icons: two choices (category, then SF Symbol) from `session title`, `project`, `first message` (Agents.swift:570-579), uses `Claude.firstMessage(head:)` from transcript head.
- J5 also inbox/actions/category icons via JevGate (JevGate.swift:11-22).
Replacing Claude Code with T3 would not touch Jev, but J4 and J2/J3 read session/transcript text.

Prompt-injection hygiene present: `SessionFence` wraps session-written text in `<session-content untrusted="true">` and neutralises closing tags (SessionFence.swift); `UntrustedText.clean`, `RouterTools.redacted` strip keys/tokens.

---------------------------------------------------------------------------------------------------------------------------------
## 4. Fjord's own persisted state touching sessions

Main file: `Application Support/Fjord/state.json` (Store.swift:606-612; `PersistedState`, Models.swift:103-129). Backups `state.json.bak-<date>` on partial reads (Store.swift:1010). Sections relevant:

- `agents: AgentsState` (Agents.swift:25-74): `enabled`, `enabledAt`, `entries[AgentEntry{id (local_…), label, unread, seen ("turns|ms"), hiddenAt, focusedAt, icon, rejectedIcons}]`, `mutedFolders`, `appUnread[]` (last sidebar dots), `seeded`, `folderColors{folderPath:index}`, `iconsEnabled`, palette/icons versions. `claudeSessions`, `claudeActivity`, `claudeTasks` are NOT persisted (in-memory, rebuilt from disk).
- `router: RouterSaved` (Router.swift:9-36): `enabled`, `enabledAt`, `changes[FjordChange]`, `decisions[RouterDecision]` (trigger you/action/session/system; decided target/intent/decider(jev|sonnet)/confidence; done[sent(to,text,original), answered, asked, failed…]; `delivered{session,cli,nonce,at,turns,busy,abortable,cancelled}`; links.sessions, outcome; RouterDecisions.swift), `style`, `runsOnProjects`, `pendingDesktopStarts`, `guestRelayDeliveries`, `guestPendingForms`, `pendingGuestDisables/Removals`, `operations[DeliveryOperation{nonce,target cli id,kind,bodyHash,state waiting|sent|unsure|refused|needsYou,route,carrier,reason,decisionID,session,to,createdAt,updatedAt}]` (RouterCarry.swift:19-64; kept 500).
- `routerProposals` (Models.swift:129).
Other Fjord files (not state.json): `router.db` (SQLite Courier: seen/intents/items/checks, CourierStore.swift:9-28), `briefs.db` (SQLite: briefs versions, brief_cursors, brief_marks read/archived/told/notified, brief_lead; RouterBriefEngine.swift:116-130), `forms/`, `permissions/`, `plugin-sessions/`, `relay/`, `relay.key`, `claude-plugin/`, `router/` (cwd of `claude -p`) (Forms.swift:7-25). Keychain: TypeSafe key.

---------------------------------------------------------------------------------------------------------------------------------
## 5. Intended behaviour per docs (skim)

- docs/design/router-watch-and-briefs.md: Briefs are per-project documents (purpose, watch, threads, now, needs_you, decisions, loose_ends); deterministic part rebuilt on any Board change; model (Haiku 5.5, ~1.5k tokens in/150 out ≈ $0.002) called per project only when new items exist, one at a time, events not timers (§3.1-3.3). Local threads "need no frame: `interruptedAwaitingPerson` in the session file gives `needs you` at file change" (§1.8) — cloud (claude.ai project) threads require hidden iframes in Chrome. Permission prompts §3.7.
- docs/design/session-wake.md: constraints of waking sleeping sessions via the app's `send_message`; relay-session wake design.
- Other design docs (router-data-design, router-redesign, router-research, router-swift-port) only skimmed via headers/grep; they cover the claude.ai-Projects Courier engine, the routing measurements (Jev→Sonnet cascade "95% right project", router-redesign.md "Routing on real moments"), and the Python→Swift port. Not exhaustively read.

---------------------------------------------------------------------------------------------------------------------------------
## 6. Rebuild-on-T3 implications (INFERRED, brief)

- Everything in §1.1-1.3, 1.5, 1.6, 1.8 is a reverse-engineered file/process scrape of Claude Desktop/Code; with T3 Code as a server these should be replaced by a single event/state stream (session list, title, cwd, status, pending approvals/questions, last assistant message, turn running).
- Plugin/hook layer (§1.4, 1.7) exists only because Claude Code gives no API to answer questions/plans/permissions or inject user-authored prompts; with T3 these map to native approval/user-input requests and a send-message API. Abort-v1 maps to interrupt.
- Model calls M1-M6 need only a provider-agnostic "one-shot structured completion" (system prompt, stdin context, JSON schema, optional MCP tools, streaming for M4). M4 depends on `--mcp-config` + `--json-schema` + `stream-json` partial messages.
- Data NOT currently obtained anywhere in this slice: token usage, rate limits, git branch, PR links (rate-limit file is GitHub-only, RateLimitWarning.swift:5-6).
