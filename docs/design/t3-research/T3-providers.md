# T3 Code v0.1.7 — providers, and how T3 runs Claude

Source: /Users/polarzero/code/research/t3code (tag v0.1.7). Paths below are relative to it. "INFERRED" = my reading, not stated in source. Read-only; no secrets read.

## TL;DR for Fjord
- T3 runs Claude through the **Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk ^0.3.284`, `apps/server/package.json:37`), which itself spawns the user's installed `claude` binary (`pathToClaudeCodeExecutable`, ClaudeAdapterV2.ts:1646). So it is Claude Code underneath, with the user's login, `~/.claude` settings, skills and plugin skills.
- Permission prompts, AskUserQuestion and ExitPlanMode are answered **in-process through the SDK's `canUseTool` callback**. No hook or channel plugin is needed (ClaudeAdapterV2.ts:9863-10128).
- T3 can **import** old Claude sessions from `~/.claude/projects/*.jsonl` and resume them natively. Import is a one-shot copy of the last 200 messages; it is not live following.
- Nothing for claude.ai web, Claude desktop Code tab, or Remote Control. `claude.ai` appears only as an install URL, an OAuth credential field, and MCP-name rewriting.
- Remote Mac = a **T3 server on that Mac** reached over SSH port-forward. Threads execute there, with that machine's Claude login.
- Cheap-model utility = "text generation" (titles, commits, PRs, branches). For Claude it spawns `claude -p`. The model is a single user setting; it is Codex gpt-6-luna on this machine.

## 1. Provider architecture

**Layers.** Orchestration is provider-agnostic. Provider specifics live at the adapter boundary `packages/provider-core/src/server/ProviderAdapter.ts` (docs/internals/providers.md:1-10). A *driver kind* is an integration; an *instance* is one configuration/account, and work routes by instance (providers.md:8-10). Interface is `ProviderAdapterV2` (adding-a-provider.md:15-17). Design-doc shape (docs/orchestration-v2/provider-capability-system.md:250-268): `getCapabilities, startSession, ensureProviderThread, sendRun, steerRun?, interrupt, respondToRequest, readThreadSnapshot?, rollbackThread?, forkThread?, streamEvents`. Optional methods are guarded by capability flags (:270).

**Drivers registered** (`apps/server/src/provider/builtInDrivers.ts:28-40`): Codex, Claude, Cursor, Grok, fx, OpenCode, Antigravity, Kiro, Pi, Muse, AcpRegistry. Most live in `packages/provider-<name>`; Codex/Claude/Antigravity are still in `apps/server/src/provider/Drivers` (adding-a-provider.md:111-113).

**Integration shapes.** ACP agents use the shared ACP adapter (`packages/provider-acp/src/server/adapter.ts`); Grok, Antigravity, Fx and Kiro are small flavours over it. Native adapters: Codex, Claude, Cursor, OpenCode, Pi, Muse (adding-a-provider.md:9-17).

**Capability schema** (`packages/contracts/src/orchestrationV2.ts:381-398`): sessions, threads, turns, streaming, tools, approvals, planning, subagents, context, checkpointing, identity, runtimePolicy. Rule: a flag left on that fails at runtime is a bug (adding-a-provider.md:21-25).

### Capability matrix
Extracted from each adapter's `*ProviderCapabilitiesV2` block. ACP, Grok, Fx, Kiro and Antigravity are `...AcpProviderCapabilitiesV2` plus overrides (packages/provider-acp/src/server/adapter.ts:629-). Claude: ClaudeAdapterV2.ts:384-481. Codex: CodexAdapterV2.ts:240-. OpenCode 2.x: provider-opencode/src/server/v2/adapter.ts:93-. Muse: provider-muse/src/server/adapter.ts:101-. Cursor: provider-cursor/src/server/adapter.ts:78-. Pi: provider-pi/src/server/adapter.ts:92-.

| Flag | Claude | Codex | OpenCode 2 | Cursor | Pi | Muse | ACP base |
|---|---|---|---|---|---|---|---|
| multi provider threads/session | no | yes | yes | no | no | no | no |
| model switch in session | yes | yes | yes | yes | yes | yes | no |
| runtime-mode switch in session | no | yes | yes | no | no | no | no |
| pending requests survive restart | no | no | no | no | no | no | no |
| read thread snapshot | no | yes | yes | yes | yes | yes | no |
| rollback | yes | yes | yes | no | yes | no | yes |
| fork / fork from turn | yes / yes | yes / yes | yes / yes | no | yes / yes | no | no |
| native turn ids | no (weak) | yes | no | yes | no | yes | no |
| interrupt | yes | yes | yes | yes | yes | yes | yes |
| active steering | **yes** (interrupts tools) | yes | yes | no | yes | yes | no |
| steer by interrupt-restart | no | yes | yes | yes | no | no | yes |
| queued messages | yes | yes | yes | yes | yes | yes | yes |
| streams tool output | no | yes | no | yes | yes | yes | yes |
| MCP tools | yes | yes | no | yes | yes | yes | no |
| dynamic tool callbacks | yes | yes | no | no | no | no | no |
| command approval | yes | yes | yes | **no** | yes | yes | yes |
| file-read approval | yes | yes | yes | no | no | yes | yes |
| file-change approval | yes | yes | yes | no | yes | yes | yes |
| apply-patch approval | no | yes | yes | no | no | no | no |
| approvals from subagents | no | yes | yes | no | no | yes | no |
| structured questions | **yes** | yes | yes | **no** | yes | yes | yes |
| plan updated / todo list | yes / yes | yes / yes | no / no | yes / yes | no / no | yes / yes | yes / yes |
| proposed plan | yes | yes | no | yes | no | no | no |
| subagents | yes (no thread ids, no wait/close/fork) | yes (all) | yes (ids, wait) | yes (wait) | yes | yes | no |
| system/developer context | yes / yes | yes / yes | no / no | no | no | no | no |
| can generate summaries | yes | yes | no | yes | no | no | yes |
| checkpoint rollback conv. | yes | yes | yes | no | yes | no | yes |
| runtimePolicy enforcement | native | native | native | native | (unset) | native | client-boundary |

Overrides on the ACP base (same files):
- **Grok** (provider-grok/src/server/adapter.ts:88-115): model switch yes, thread snapshot yes, no fork, subagents with thread ids, MCP yes.
- **Fx** (provider-fx/src/server/adapter.ts:49-72): model switch, snapshot, MCP, subagent lifecycle.
- **Antigravity** (AntigravityAdapterV2.ts:56-71): model switch and runtime-mode switch yes, MCP yes, subagents flagged. Can capture workspace checkpoints but **cannot roll back conversation** (providers.md:131-134).
- **Kiro** (provider-kiro/src/server/adapter.ts:62-92): ACP base plus fork from turn, active steering via `_session/steer` (messages with images restart the turn), MCP, subagents.
- **Generic ACP registry agents**: base flags only; tools run in the agent's own mode and T3 answers approval requests by permission mode (docs/user/permission-modes.md:44-45).
- **OpenCode 1.x** adapter (provider-opencode/src/server/adapter.ts:113-) is a separate capability set (MCP yes, dynamic callbacks no); the driver probes the version and picks 1.x or 2.x (providers.md:14-25).

Provider-specific notes: Pi runs the user's own `pi` in RPC mode and owns extension/trust discovery (providers.md:32-37). Codex questions arrive as notifications, answered with a new user message (providers.md:109-121). Capability `pendingRequestsSurviveRestart` is false everywhere, but Codex-style `user_input_request` items persist.

## 2. Claude specifically

**SDK, not a bare CLI** — `import { query, forkSession, getSessionMessages, resolveSettings … } from "@anthropic-ai/claude-agent-sdk"` (ClaudeAdapterV2.ts:38-61). The SDK spawns the CLI; T3 overrides spawn to run it in its own process group and scope (`spawnClaudeProcessGroup` :354; `spawnClaudeCodeProcess` :1063). Options passed: `tools: {type:"preset", preset:"claude_code"}` (:1597, :497), `systemPrompt` = claude_code preset + appended T3 instructions (:1655-1665), `includePartialMessages`, `mcpServers`, `canUseTool`, `onUserDialog`, `onElicitation`, `permissionMode`, `resume`/`sessionId`, `resumeSessionAt` (:1604-1649). A `SubagentStart` hook is injected only for device tooling (:1666).

**Claude config is loaded.** Default `settingSources: ["user","project","local"]`; with a custom `CLAUDE_CONFIG_DIR` instance it uses `["project","local"]` plus reading `<home>/settings.json` itself (ClaudeAdapterV2.ts:4656, 4686). Docs: "T3 Code uses Claude Code's login and configuration" (providers-claude.md:3-5). Skills from `<config>/skills`, project `.claude/skills`, and enabled installed plugins (`installed_plugins.json` + `enabledPlugins`) appear in the composer (providers-claude.md:85-95; apps/server/src/provider/Drivers/ClaudeSkills.ts:218-346). CLAUDE.md is read by the CLI itself (INFERRED: standard Claude Code behaviour under the claude_code preset; T3 code only reads CLAUDE.md for git text generation, git/GitManager.ts:834). User hooks and MCP servers from settings are therefore live in chat turns (INFERRED from settingSources; contrast: the health probe and text generation explicitly disable them, `disableAllHooks: true`, `strictMcpConfig`, ClaudeProvider.ts:203-225, ClaudeTextGeneration.ts:177). T3 additionally injects its own `t3-code` HTTP MCP server (ClaudeAdapterV2.ts:1795-1811).

**Permission prompts** — `canUseToolEffect` (:9863-10128). Per tool:
- `AskUserQuestion`: builds a `user_input` runtime request with the questions, waits on a Deferred, returns `behavior:"allow"` with `updatedInput.answers` (:9919-9987). Pending requests are live-only (`approvalCallbacksAreLiveOnly: true`, `pendingRequestsSurviveRestart: false`).
- `ExitPlanMode`: captures the plan markdown as a proposed-plan artifact, then **denies** with "The client captured your proposed plan. Stop here and wait…" (:9989-10006).
- Other tools: approval request unless the mode auto-allows; typed with native request id = `toolUseID`. Dangerous-`rm` bypass denials get a special message (:10040-10060). In plan mode with approvals off, denies (:10010-10020). Typing text while an approval is pending declines it and gives feedback to the agent (permission-modes.md:51-53).
- Mapping runtime mode -> SDK `permissionMode` (`default|acceptEdits|auto|bypassPermissions|dontAsk|plan`) at :2568-2610; `canUseTool` callback installed when approval is needed, and always in plan mode (:2640-2662). If user settings disable bypass/auto, T3 downgrades (:2641-2646; reads `remote-settings.json`, settings.json via `resolveSettings`, :4640-4670).

**Resume/fork/rollback.** New thread passes `sessionId`, resumed passes `resume: nativeThreadId` (:1572-1574). Fork uses the SDK `forkSession` in a worker (`claude-history-worker.ts`, ClaudeAdapterV2.ts:905-950, 1331-1365). Rollback and fork-from-turn are advertised; subagent uuids live only in sidechain transcripts so they can't be forked (:8707).

**Import of existing Claude Code sessions.**
- Welcome wizard scans directories used by Claude Code, Codex and Pi and imports conversations active in the last 30 days (docs/user/welcome-wizard.md:59-100).
- Scanner reads `<claude home>/projects/*/*.jsonl` (apps/server/src/project/AgentSessionScanner.ts:1141-1190), home = instance setting, then `CLAUDE_CONFIG_DIR`, then `~/.claude` (:1129-1138).
- Keeps first user prompt plus newest visible user/assistant messages, 200 total; **drops tool activity and attachments**; limits 100 files and 4 GiB per project per attempt (welcome-wizard.md:81-93).
- Importer creates thread `import:<instance>:<sessionId>` with a stopped runtime and `resumeCursor {resume: sessionId}`, so the next message resumes the real Claude session natively (project/AgentSessionImporter.ts:240-290). It requires a UUID-shaped id (:264).
- This is a **one-time copy**, re-run to pick up new sessions; it does not tail a live transcript (INFERRED: no watcher found; `grep watch` in scanner returned nothing).
- `docs/user/browser-import.md` is unrelated: it imports browser cookies for the preview browser.
- `docs/user/thread-migration.md` is about T3 v1->v2 SQLite, not Claude.

**Sessions started outside T3 (terminal claude, Claude desktop).** Only via the import above (adoptable by resume; the `.jsonl` is shared, so a resumed session writes to the same transcript). No live read-only mirror. Conversely, "Outside agents" (docs/user/outside-agents.md) lets a terminal Claude/Codex/ChatGPT drive T3 over its **MCP server** (`claude mcp add --transport http t3 …/mcp`): read projects/threads, start/message/stop threads, with a read-only default; also `t3 thread start|send|show|list` on the host (:95-115).

**Auth.** Uses Claude Code login (`claude auth login`, install.md:164). Status comes from an SDK capabilities probe: email, subscriptionType, tokenSource, apiKeySource, apiProvider (ClaudeProvider.ts:170-185, 245-260). Bedrock/Vertex/other providers count as authenticated. Subscription vs API key both work; env vars per instance allow OpenRouter/routers (providers-claude.md:104-137). Here: auth type "Claude Ultra", Claude Code 2.1.319 (~/.t3/caches/claudeAgent.json). Separate accounts = separate `CLAUDE_CONFIG_DIR` instances; existing threads switch only between instances with the same config dir (providers-claude.md:7-35).

**Usage/limits.** Probe `get_usage` yields 5-hour "Session" and 7-day "Weekly" windows (+ optional spend budget) (provider/claudeUsageLimits.ts:19-40). Usage-limit errors are classified `usage_limit` with reset time; Claude holds the turn until the window reopens (providers-claude.md:77-83; adding-a-provider.md "Usage limits"). Usage page (docs/user/usage.md:9-47) reads local session history per provider, shows API-equivalent cost (not the bill). Text-generation runs are excluded for Claude 2.0.63+ (no saved history).

**Other Claude features.** Auto-compact threshold setting (100k-1M), idle compaction before cache expiry (this user has `idleCompaction: beforeCacheExpires`) (providers-claude.md:44-75); task lists need `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` (:97-102). `/goal` isn't emitted by the SDK; read from transcript/Stop hook (providers.md:123-129). Model catalog comes entirely from the manifest (model-manifest.md:17-26), with per-model `adapter.claudeCode.minVersion`.

## 3. Permission modes & plan mode
Four modes: Supervised (`approval-required`), Auto-accept edits, Auto, Full access (docs/user/permission-modes.md:13-18). Default is Full access (:10); this install has `defaultRuntimeMode: "auto"` (settings.json). Providers offer only modes they enforce natively via `supportedRuntimeModes`; unoffered stored modes run Supervised (adding-a-provider.md:26-31). Offered sets: Muse and Kiro = Supervised+Full; Pi/Antigravity = no Auto (provider-pi status.ts:56; AntigravityProvider.ts:189); OpenCode = all four (status.ts:579); fx = Supervised only/Auto; Grok no Auto-accept (permission-modes.md:34-58). "Auto" = provider's automatic review on Codex, Claude, Cursor, Grok, fx; others fall back to asking (:29-32). Admin can cap modes via managed policy (:20-21).
**Plan mode**: `interactionMode: "plan"`; toggle shown only if `showInteractionModeToggle` (true for Claude ClaudeProvider.ts:62, Codex CodexProvider.ts:86, Cursor status.ts:29, OpenCode 2 status.ts:578; false for Grok, Fx, Kiro, Muse, Pi, Antigravity, OpenCode 1). Claude: SDK `permissionMode:"plan"`, read-only tools, writes routed to callback, ExitPlanMode -> proposed-plan card (:2568-2575, 2656-2670). Muse rejects plan at adapter level (muse adapter.ts:293).

## 4. Provider switching / handoff
- A thread may mix providers; each provider keeps its own native thread handle; the app thread is canonical (docs/orchestration-v2/provider-switching-and-context.md:3). Returning to a provider resumes its old thread plus a **delta** handoff of runs it missed; otherwise fresh thread + full handoff (:9-11, 122-130). Capability `supportsProviderSwitchingViaHandoff` is true for all listed adapters.
- Handoff is **not an agent-written summary**: a budgeted selection of recent user/assistant messages, original request, and key activity (docs/user/portable-handoffs.md:6-18). Codex gets messages directly; others get attributed context. No reasoning, tool state or attachments are copied. Cap default 16,000 tokens (`T3CODE_CONTEXT_HANDOFF_TOKEN_CAP`, 1,024-64,000); fallback window 128k (:31-46). (docs/internals/context-handoffs.md describes the older text form: items truncated to 240 chars.)
- Forks: same-provider native fork when supported (Claude yes, Codex yes), else portable handoff; lazy, resolved on first dispatch (thread-lineage-and-context-transfer.md:270-282). Merge-back of forks and subagent context share the model.

## 5. Text generation / cheap-model utility
- Operations: thread title, commit message, PR content, branch name, review guide (provider-core/src/server/textGenerationOperations.ts:1-30). Per-provider runners: `apps/server/src/textGeneration/{Claude,Codex,Antigravity}TextGeneration.ts`, plus Grok, Muse, OpenCode 2 runners in their packages.
- **Claude runner spawns `claude -p`** (not the SDK): `--output-format json --json-schema … --model … --effort … --settings {disableAllHooks:true,…} --tools "" --disable-slash-commands --strict-mcp-config --permission-mode dontAsk`, prompt on stdin, temp cwd for titles (ClaudeTextGeneration.ts:176-239). Optional read-only "investigate" mode with Read/Glob/Grep (:208-216).
- Model choice: user setting `textGenerationModelSelection` (provider instance + model + options), default Codex (contracts/src/settings.ts:1318-1330, `DEFAULT_TEXT_GENERATION_MODEL`). Separate optional `sourceControlWriterModelSelection` and `reviewGuideModelSelection` (settings.ts:1078-1079). Here: Codex `gpt-6-luna`, effort low (~/.t3/userdata/settings.json). Any enabled provider can be chosen, including Claude Haiku.
- Model manifest (docs/internals/model-manifest.md): bundled `apps/server/src/provider/model-manifest.json` (updatedAt 2026-11-02) plus remote copy fetched from `main`; installed cache `~/.t3/userdata/model-manifest.json` has updatedAt 2026-11-05. Covers codex, claudeAgent, antigravity. Claude models: opus-5-5, sonnet-5-5, fable-5-1, haiku-5-5 current; opus-5, fable-5, opus-4-x, sonnet-5/4-6, haiku-4-5 legacy. Installed Claude cache lists 14 models and 72 slash commands.
- No separate "summarize the thread for the user" feature found in this slice beyond titles/PR/commit/review-guide (INFERRED).

## 6. Remote execution
- Model: each connection joins a client to one **environment** (a T3 server) which owns providers, execution, files and state; direct, Tailscale, SSH and T3 Connect only change reachability (docs/internals/remote.md:3-8). A project and its threads belong to one environment.
- **Desktop-managed SSH** (docs/user/remote-access.md:208-235): enter `user@host`; T3 downloads its server to `~/.t3/runtime` on the host, starts/reuses it and port-forwards. Host must be Linux or **Apple Silicon Mac** with curl/wget, tar, sha tools, and provider CLIs on a non-interactive login-shell PATH (`ssh host 'sh -lc "command -v claude codex"'`). Provider credentials and agent work stay on the remote. Implementation: `packages/ssh/src/{tunnel,command,auth,config}.ts`.
- So **yes, a thread can run on another Mac**, with Claude running there under that Mac's `~/.claude` and login (text generation also uses the connected server's config, providers-claude.md:40-42). Caveat: the remote needs `claude` installed and logged in (headless login must be done on the host). It is a T3 server there, not the Claude desktop app: it does not drive a Desktop Code-tab session.
- **Peer links** (remote.md:70-120, beta `linkedEnvironmentsEnabled`): one environment's agents can start/read/interrupt threads in another over its `/mcp`, with mode-narrowing (`T3-Mode-Limit`). Delegated tasks via MCP `delegate_task` (docs/orchestration-v2/orchestrator-mcp-server.md:228).
- Other access: T3 Connect (relay), LAN pairing, Tailscale, background service (`t3 up`), mobile app. **Devcontainer** doc is only for T3 maintainers (docs/internals/devcontainer.md:1-6), not a user execution target. WSL is supported by the desktop app (apps/desktop/src/wsl).
- Per-device Claude history is per machine; Usage can aggregate across environments (usage.md:56-59).

## 7. claude.ai / cloud
Searched `claude.ai`, `remote-control`, `cloud` across apps/packages/docs. Findings:
- No claude.ai Projects, no Claude cloud/web sessions, no Remote Control (`remoteControl` hits are only Codex app-server generated schema, packages/effect-codex-app-server/src/_generated/*).
- `claude.ai` uses: install script URLs (apps/web/src/onboarding/providerReadiness.logic.ts:78-79), release downloads (provider/Drivers/ClaudeMaintenance.ts:21), reading `claudeAiOauth.accessToken` for reset-credit info (provider/claudeResetCredits.ts:21,143), stripping the `mcp__claude_ai_` prefix from connector tool names (ClaudeAdapterV2.ts:3372, 7242), and disabling claude.ai MCP connectors in probes (`ENABLE_CLAUDEAI_MCP_SERVERS:"false"`, ClaudeProvider.ts:218-219). In chat turns claude.ai connectors may load as for Claude Code (INFERRED).
- `apps/server/src/cloud/*` is **T3's own** Connect/relay service (CloudLink, ManagedEndpointRuntime), unrelated to Claude cloud.

## 8. Mapping to Fjord's current dependencies (INFERRED)
| Fjord today | T3 equivalent |
|---|---|
| Read Claude transcripts | `claudeHistoryWorker`/SDK `getSessionMessages`; own event store (statev2.sqlite). Importer for old sessions |
| Form hook holding AskUserQuestion/permissions | `canUseTool` callback, request ids, `runtime-request.respond` (providers.md:116-121) |
| Channel plugin injecting words into a running session | Active steering (`supportsActiveSteering`, interrupts tools) or queued message; plus `t3 thread send` / MCP for external agents |
| Follow Desktop Code tab / claude.ai sessions | **Nothing**; only one-time import |
| SSH remote Macs | Desktop-managed SSH environments (T3 server on the remote) |
| `claude -p` Haiku/Sonnet for summaries/routing | Text-generation runner pattern (`claude -p --json-schema --tools ""`); Fjord would reuse or copy it, model configurable |
