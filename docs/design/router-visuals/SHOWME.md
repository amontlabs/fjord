# Show me: implementation plan

Status: plan, 2026-11-14. Nothing built beyond the demo UI. `SF/` = `Sources/Fjord/`, `EX/` = `docs/design/router-visuals/explainer/`,
`T3:` = `~/code/research/t3code` at v0.1.7 (the running server is 0.1.7 too).

The approved flow, project, creator, kit and UI are as the brief states; this file decides how they are built. Each decision
gives its reason in the code. **Blockers and spikes** are collected in §11.

## 0. Shape in one paragraph

Fjord keeps one hidden T3 project, **Explainers**, whose folder is `~/Library/Application Support/Fjord/Explainers`. Fjord
writes the creator's instructions there as `CLAUDE.md`, a `.claude/settings.json` that blocks every tool but `preview`,
and a `.mcp.json` that points at a second, persistent instance of Fjord's MCP server (`ExplainerMCP`), which serves one
tool, `preview`. `preview` renders the code in an offscreen `WKWebView` in Fjord, saves it as the next version, and updates
the dock straight away. A send with Show me on puts an entry in a persisted queue. When the source thread's turn ends
(a shell event), Fjord builds the input from the thread's projection and starts one explainer thread with
`orchestration.launchThread` (Opus 5.5, full access). When that run ends, Fjord reads the final code block from its last
message. The project and its threads are removed from the shell at its single entry point (`T3Store`), so every Router
surface stays clean without a filter of its own.

## 1. The explainer project

### 1.1 Folder

`~/Library/Application Support/Fjord/Explainers/`. It sits next to `state.json`, `thread-cards/` and `model-usage.jsonl`
(`Store.routerFiles?.support`, `SF/Store.swift:410`). In a test or demo `routerFiles` is nil, so nothing is made.

```
Explainers/
  CLAUDE.md                 creator instructions (managed)
  .claude/settings.json     tool lock, hook (managed)
  .claude/settings.local.json   enabledMcpjsonServers: ["fjord"] (managed)
  .mcp.json                 0600: fjord server url + bearer token (rewritten when the port or token changes)
  .fjord/guard.sh           PreToolUse allowlist (managed, 0755)
  .fjord/stamp              hash of the bundled resources last copied
  kit/                      player.html, player.css, kit.js, vendor/, fonts/ (managed)
  queue.json                pending Show me requests (§3)
  runs/<threadId>/          one explainer: meta.json, input.md, v1.js, v1/{index.html, explainer.js, f-*.jpg}, …
```

"Managed" files are overwritten whenever the stamp differs. `runs/` and `queue.json` are never touched by an update.

### 1.2 Shipping and updating

- New `Resources/Explainer/`: `kit/` (copied from `EX/kit`; `fonts/` is a symlink-free copy of `Resources/Fonts`'s three
  files, so there's one source), `CLAUDE.md` (the built prompt), `settings.json`, `settings.local.json`, `guard.sh`.
- `CLAUDE.md` is built from `EX/system.src.md` with `{{EXAMPLE}}` replaced by `EX/examples/lastdrop.js`, by a small
  `scripts/build-explainer-prompt.sh` that writes `Resources/Explainer/CLAUDE.md`. The built file is committed, so a
  plain `swift build` run has it. A test (`ExplainerProjectTests.promptIsBuilt`) fails if the built file is stale. The
  prompt gains one paragraph about follow-ups (§7).
- `scripts/build-app.sh`: `cp -R Resources/Explainer "$APP/Contents/Resources/"`, next to the Fonts line (`:25`). Also
  copy `Resources/ShowMeDemo` (the demo already looks for it in the bundle, `RouterShowMeDemo.folder`, but nothing
  copies it yet).
- Lookup: `ExplainerProject.resources` is the bundle's `Resources/Explainer`, or the repo's when run from
  `swift build`, using the `#filePath` fallback `RouterShowMeDemo.folder` already uses.
- `ExplainerProject.sync()` runs at launch, once T3 is linked. It hashes the bundled tree (SHA256 over sorted relative
  paths + bytes, CryptoKit as `ThreadCards.swift` uses). If `.fjord/stamp` differs, it rewrites the managed files
  atomically, then writes the stamp. A Fjord update therefore refreshes kit and prompt on the next launch. A thread
  already running keeps the CLAUDE.md it started with (Claude Code reads it at session start), which is fine.

### 1.3 Registering it in T3

Reuse `ThreadLaunchSupport.createProject` (`SF/ThreadLauncher.swift:160`, `POST /api/projects/mutate` with
`project.create`). `ExplainerProject.ensure(store)` finds the project by `workspaceRoot` (standardized path compare, as
`Store.t3Project(forFolder:)` does) in the **unfiltered** shell (`T3Store.hidden`, §5), and creates it titled
"Fjord explainers" if it's missing. Identity is the folder path, not a saved id, so a project the owner deletes in T3 is
made again and no state can drift. The project needs no git: launches use `workspaceStrategy: root`.

### 1.4 What T3 lets a launch set, and how Claude Code is locked

Read in source:
- `launchThread` takes `modelSelection{instanceId, model, options}`, `runtimeMode`, `interactionMode`,
  `workspaceStrategy`, `initialMessage` (`SF/T3Types.swift` `T3LaunchRequest`). There's **no per-thread system prompt,
  tool list or MCP config**.
- T3 calls the Agent SDK with `systemPrompt: {preset: "claude_code", append: T3's runtime instructions + the provider
  instance's launch-arg append}` (`T3:apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts:1650-1663`). The
  append comes from the **provider instance's** `launchArgs`, so it's global to every thread on that instance.
- T3 passes **no `settingSources`** in query options (`:1600-1665`). In SDK 0.3.x, omitted means "all sources loaded
  (matches CLI defaults)… must include 'project' to load CLAUDE.md" (`claude-agent-sdk/sdk.d.ts:2357-2367`). So the
  project's `CLAUDE.md`, `.claude/settings.json`, `.claude/settings.local.json` and `.mcp.json` are all read, and so is
  the user's `~/.claude`.
- `runtimeMode: full-access` → `bypassPermissions` (`:2612`). Deny rules and PreToolUse hooks still apply under bypass.

Decisions:
- **Instructions:** the project's `CLAUDE.md`. A dedicated T3 provider instance with `--append-system-prompt-file` would
  mean Fjord writing T3's provider settings and adding an entry to T3's model picker. That breaks "Fjord writes
  nothing into any agent's config" (DEVELOPMENT.md, "What the Router reads and writes"). CLAUDE.md is the documented
  place for project instructions (t3-code-map §8: "Instructions live in the repo").
- **Model:** `ThreadLaunchSettings(model: "claude-opus-5-5", effort: nil, runtimeMode: .fullAccess, interactionMode:
  .default)`, resolved with `ThreadLauncher.model(slug:…)` to T3's Claude instance. Effort is left at the model's
  default because the eval runs (`EX/run.py`: `claude -p --model claude-opus-5-5`, no effort) were measured that way.
  Raise it only after an eval.
- **Tools:** only `mcp__fjord__preview`, plus `ToolSearch` (Claude Code may defer MCP tools behind it; T3 sets
  `ENABLE_TOOL_SEARCH`, `ClaudeAdapterV2.ts` `toolSearchOverride`). Two layers:
  1. `.claude/settings.json` `permissions.deny`: `Bash`, `Read`, `Edit`, `Write`, `NotebookEdit`, `Glob`, `Grep`,
     `WebFetch`, `WebSearch`, `Task`, `Agent`, `TodoWrite`, `mcp__t3-code` (T3's own orchestration MCP, which it adds
     for every thread, `:1796`).
  2. `hooks.PreToolUse` (matcher `*`) → `"$CLAUDE_PROJECT_DIR/.fjord/guard.sh"`. It allows `mcp__fjord__preview` and
     `ToolSearch`, and denies everything else with a reason (`permissionDecision: "deny"`). This catches tools a deny
     list can't name: user-scope MCP servers (`mcp__lcu__*`, plugins) and future built-ins.
  The final code comes from the last message (§2.4), so there's **no Write**: nothing to restrict to an output folder.
- **MCP reach:** project `.mcp.json` with `{"mcpServers":{"fjord":{"type":"http","url":"http://127.0.0.1:<port>/mcp",
  "headers":{"Authorization":"Bearer <token>"}}}}`, the same shape as `RouterMCPServer.config(port:)`
  (`SF/RouterMCP.swift:453`). Project-scope servers need approval in Claude Code, so `.claude/settings.local.json` sets
  `"enabledMcpjsonServers": ["fjord"]`. **Spike S1** (§11).
- **Settings sources:** we can't turn the user's sources off per project. Their `~/.claude/CLAUDE.md` and plugins load
  too. The guard makes those inert as tools; their text is prompt noise (§11, B3).

## 2. The preview tool

### 2.1 Server: `ExplainerMCP` (new `SF/ExplainerMCP.swift`)

Reuse `RouterMCPServer` and `RouterRPC.handle` as they are, with three changes in `SF/RouterMCP.swift`:
- `RouterRPC.ToolResult` gains `images: [(mime: String, base64: String)]` and interleaved labels. `one(_:)` emits
  `content: [{type:"text"…}, {type:"image", data, mimeType}, …]`, the MCP image content block that FastMCP's `Image`
  produced for the Python server.
- `RouterMCPServer.init` takes an optional fixed `token` and a `preferredPort`. `start` tries
  `.hostPort(127.0.0.1, preferredPort)` first, then `.any`.
- `handle`'s `maxResponse` is already a parameter: the explainer passes 8 MiB.

The Router's own runs make a server per run with a fresh token. The explainer server is long-lived: one per app run,
started by `ExplainerEngine.start()`. Its token and port are kept in `.mcp.json` (0600), and it rebinds the same port
next launch. Only when that port is taken does it pick a new one and rewrite `.mcp.json`. The reason: Claude Code
reads `.mcp.json` at session start, and T3 keeps a Claude session alive per thread, so a moving port would strand a
live explainer. A session that loses the server anyway gets a tool error, the run ends, and §2.4's fallback applies.
`Limits.requestTimeout` stays 10 s (it bounds receiving the request, not answering it).

### 2.2 Renderer: `ExplainerRenderer` (new `SF/ExplainerRenderer.swift`, `@MainActor`)

The shipped app has no Playwright shell (`EX/preview_server.py:7`), so preview renders in Fjord with WebKit:
- An offscreen `NSWindow` (borderless, at `-10000,-10000`, `orderBack` never shown: the same trick `--window-shots`
  and `--frames` use, DEVELOPMENT.md) holding a `WKWebView` 1000 × 760 points, appearance `.aqua` (light).
- Configuration: `ExplainerWeb.configuration()`, shared with the player (§8): a `WKContentRuleList` that blocks every
  `http(s)`/`ws(s)` load, no script message handlers, and a navigation delegate that cancels anything but `file:`.
- `render(code:, version dir:, at:) async -> PreviewResult`:
  1. Write `v<n>/index.html` (`kit/player.html` with `KIT/` → `../../../kit/` and `ASK_JSON` → the ask, `</` escaped
     as `render.sh` does) and `v<n>/explainer.js`. `loadFileURL(index, allowingReadAccessTo: projectRoot)`.
  2. Wait with no polling: `WKNavigationDelegate.didFinish`, then
     `callAsyncJavaScript("await new Promise(r => document.body.dataset.ready ? r() : new MutationObserver((_, o) => { if (document.body.dataset.ready) { o.disconnect(); r(); } }).observe(document.body, {attributes: true}))")`.
     A syntax error in `explainer.js` never calls `explainer()`, so the kit gains one line
     (`addEventListener("error", …)` already exists, `kit.js:1012`): set `dataset.ready = "error"` from `fail` when
     `spec` is unset. Then the promise always resolves.
  3. Read `window.__timing`, `#errors` text, `body.broken`, and the new `window.__spec` (a kit line in `explainer()`:
     `{title, answer, captions}`) in one `evaluateJavaScript`.
  4. For each scene end (`__timing.scenes[i][1]`) and each `at`: `callAsyncJavaScript("__film.timeline.seek(t); await
     new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")`, then
     `takeSnapshot(with: WKSnapshotConfiguration())` → JPEG 0.8 at 1×, saved as `v<n>/f-scene-<i>.jpg` / `f-t-<t>.jpg`.
     Frames are taken one after another on one view (no per-frame reload, unlike the Python server's 3 parallel
     processes).
  5. Also take `poster-light.jpg` and `poster-dark.jpg` of the last scene's held frame (appearance switched, which the
     kit rebuilds keeping its time, `kit.js` `retheme`). These are the static stage for shots and the "making" stage.
- The text answer has the Python server's exact wording ("Version N. Total … Scenes start at …", "Errors and layout notes
  to fix:"), then a label and an image per frame. That's the format the prompt and evals were tuned on.

### 2.3 Versions and the live dock

`ExplainerVersions` (in `SF/ExplainerStore.swift`) writes `runs/<thread>/v<n>.js` and `meta.json` (`versions`,
`notes[n]` = the first layout note, `title`, `answer`, `captions`, `length` from timing). Attribution: a `preview` call
carries no thread id. The queue runs **one creator at a time** (§3), so the call belongs to the single explainer thread
whose run is live in the hidden shell (`T3Store.hidden.threads` with `activeRunId != nil` in the explainer project).
With none or two, the tool answers an error and saves nothing.

Every saved version calls `ExplainerEngine.versionSaved(thread, version)` on the main actor. That updates the page
model's Show me state (§6) in the same call, so the dock shows the draft the moment its frames exist, with no polling
or file watching. "What it's fixing" (`Stage.making(fixing:)`) is the previous version's first layout note: a fact the
tool produced, not a guess from text.

### 2.4 The final

**The final is the last ```js block in the explainer thread's last assistant message**, as `EX/run.py:20` does. It's read
when the explainer run completes (§3.2) from `routerSnapshots.read(thread)` (`SF/Store.swift:422`) →
`T3Projection.messages`, the last `role == "assistant"`. Why not a file: a file needs Write, which reopens the tool
surface §1.4 closes, and T3 already stores every message durably. Robustness:
- block == the last version's code (byte-equal after trimming) → that version is final.
- block differs → render it once more through §2.2 (no MCP), save as the next version, mark it final.
- no block (interrupted, failed, usage limit) → the last version without `body.broken` is final, marked `draft: true`;
  if there's none, the explainer is `failed` with "Open in T3".

## 3. Turn-end trigger and the queue

### 3.1 Entries

`ExplainerQueue` (`SF/ExplainerQueue.swift`), persisted to `Explainers/queue.json` (atomic write on every change):

```swift
struct ExplainerRequest: Codable, Equatable, Identifiable {
    var id: String              // the explainer thread id, minted up front (launchThread takes it: `thread minted:`)
    var source: String          // the thread whose answer it explains
    var ask: String?            // the user message id it explains (nil: "Show me" on a card = its latest reply)
    var sentAt: Date
    var followUp: String?       // words for an existing explainer (§7), queued while it makes another version
    var state: State            // waitingForTurn, waitingForCreator, launched
}
```

- **Composer send with Show me on / ⌘↩:** `RouterOutgoing` gets `showMe: Bool` (`SF/RouterPort.swift:43`). It's carried in
  `RouterActs.Send`, and when the dispatcher reports `.taken` (`RouterActs.sendEvent`, `SF/RouterActs.swift:215`) the
  engine enqueues `waitingForTurn` with the delivered `messageID` (`RouterDecision.Delivered`, set in
  `ThreadLauncher.swift:395` for new threads and in the send path for existing ones). Enqueueing only after `.taken`
  means a refused send leaves no orphan.
- **"Show me" on a Done card:** enqueue `waitingForCreator` with `ask: nil` right away.

### 3.2 Turn end

`Store.routerShellChanged` (`SF/Store+Router.swift:180`) gains one line: `explainers.shell(item)`. It's event-driven,
off the shell stream T3 already pushes. `ExplainerEngine.shell(_:)`:
- For each `waitingForTurn` entry, the source row in `t3.store.shell` has `activeRunId == nil` and
  `latestRunCompletedAt >= sentAt` → `waitingForCreator`. An interrupted or failed turn (`status` `.interrupted`/`.failed`/
  `.cancelled`) drops the entry and marks the dock row "Its turn stopped". A thread that disappears (archived) drops it.
- For the explainer thread being made (hidden shell): `activeRunId == nil` and `latestRunCompletedAt` advanced →
  finalize (§2.4), then `pump()`.
- `pump()`: if no explainer run is live, take the oldest `waitingForCreator`, build the input (§4), launch (§3.3).

**Restart:** `queue.json` is loaded in `ExplainerEngine.start()`. Its entries are evaluated on the first
`.synchronized` / snapshot item (`T3ShellState.answered`), the same moment `RouterRecords.purge` runs. A turn that ended
while Fjord was closed is then seen as ended, and a launched creator still running is picked up by its thread id. An
entry older than 24 h is dropped. No timers.

### 3.3 Launch

`ExplainerEngine.launch(_:)` builds a `T3LaunchRequest` with `ThreadLauncher.request(thread: req.id, project:
explainerProject.id, message: ThreadMessage(text: input), model:, runtimeMode: .fullAccess, workspace: .root)` and calls
`store.dispatch(.launchThread(…))` directly. It does **not** call `Store.launchThread`: that guards on the filtered shell
and records a `FjordChange` ("Started a thread in …") in History, which would show the project.

## 4. Building the input (`SF/ExplainerInput.swift`, pure)

`ExplainerInput.make(_ p: T3Projection, project: String, ask: String?, now: Date) -> Input?` (`Input{text, askText}`),
a port of `EX/build_case2.py` onto `T3Projection`, the projection Fjord already reads through `readSnapshot`
(`SF/T3Store.swift:297`) rather than T3's sqlite:
- **Messages:** `p.messages` sorted by `createdAt`. "Yours" means `role == "user" && createdBy == "user" &&
  notification == nil && delegatedTaskIds == nil`. That replaces the Python's "doesn't start with `<`": T3's own typed
  fields say what a message is, with no word rule.
- **Ask:** the message with id `ask`, else (card) the last of yours before the last assistant message. **Answer:** the
  assistant messages after it up to your next message, joined (as the Python merges consecutive agent turns). **Context:**
  one exchange before (your previous message and the agent's reply to it), so turns = `iask-2 ..< iask+2`.
- **Limits:** the focus turn at 7,000 characters, others at 1,500, with " …" (Python values).
- **Activity:** `p.turnItems` whose `updatedAt` falls in `[firstTurn - 5 min, answerEnd]`, with a `startedAt` from
  `raw`: `commandExecution` → `Bash <first line, 90>`, `dynamicTool` → `<toolName> <json input, 70>` (input read from
  `raw["input"]`), `fileChange` → `Edit <basename>`, `webSearch` → `Web search`. Subagents from
  `p.others["subagents"]` (raw: `title`, `model`, `startedAt`, `completedAt`) →
  `subagent "<title,60>" · <model> · HH:mm → HH:mm` or `(still running)`. Sorted. Over 40 lines: first 12, "… N more …",
  last 20.
- **Redaction:** `RouterTools.redacted` (`SF/RouterMCP.swift:734`, the key and token patterns already used for Jev),
  plus `NSHomeDirectory()` → `~` and the user's short name → `user`. **Escaping:** `<` → `‹`, `>` → `›` inside text, as
  `esc()` does.
- Output: `<ask>…</ask>` and `<thread name="…" project="…">` with `<turn by= at= ask=|focus=>` and `<activity>`, byte
  for byte the Python's layout, so `EX/cases2/*/user.md` serve as golden files (§9).
- `input.md` is saved in `runs/<id>/` (for Sources, and to rerun evals).

## 5. Hiding the project: one chokepoint, three explicit checks

`T3Store.shell` is read by everything that lists threads or projects: `RouterRecords.shell` (`rows()`), the Threads
reducer (`SF/Threads.swift:440-475`), `DeciderBoardSource` (`:82`), `RouterActs.swift:376`, `RouterMCP.board`
(`:718`), `RouteTarget`, the pointer's project suggestions (`RouterPointer.swift:550-570`, from the board), Jev's path and the
decider (from the board), `RouterModel.projects` (the filter bar and project pills, from the records' tally), the
notifier (`RouterRecords.refresh` → `notifier.changed`), thread cards (fed from records and shell). So filter **once, at
the source**:

- `T3Store` gains `hiddenRoot: String?` (set by `ExplainerProject`) and `private(set) var hidden = T3ShellState()`.
  `shell.apply(item)` in the shell task (`SF/T3Store.swift:157`) becomes `apply(item)`. That applies to `hidden` (the
  full state) and then sets `shell = hidden.without(projectRoot:)`, which drops the project whose standardized
  `workspaceRoot` is `hiddenRoot` and every thread with that `projectId`. `onShell?(item)` is called as now. Every
  consumer re-reads rows from `shell` by id (`RouterRecords.shell`: `shell.threads[t.id]` → nil → `drop`, a no-op for an
  id it never had; `Threads.swift:450` the same), so items about hidden threads fall through harmlessly.
  `T3ShellState.without` is pure and tested.
- **Not covered by the shell**, so checked by hand:
  1. `RouterThreads` `search_threads` / `read_thread` (`SF/RouterThreads.swift`, T3's `orchestration.searchThreads` and
     snapshots): drop hits and refuse ids whose thread is in `hidden` but not in `shell`.
  2. `Store.searchDraft` hits for the decider's E block: already kept only for "a thread the context knows"
     (`DeciderContext.swift:328`), which comes from the shell. A test pins it.
  3. `t3.store.projections` / `openThread`: the engine opens the explainer thread itself, and `routerThreadChanged`
     (`Store+Router.swift:188`) must ignore hidden ids (`guard t3.store.shell.threads[id] != nil`), or
     `RouterRecords.detail` would make an entry.
- The `--t3` probe (`T3Link.swift:189`) prints `shell`: hidden there too.
- T3's own sidebar still lists "Fjord explainers". That's accepted (T3 is the advanced UI). Option: archive the project
  in T3 (`archivedAt` makes pickers drop it, `orchestrationProject.ts:20`), if a launch into an archived project still
  works (**spike S3**).

## 6. Dock model

Real types in new `SF/ExplainerTypes.swift`; the demo uses the same ones.

```swift
struct RouterExplainer: Identifiable, Equatable {      // moves from RouterShowMe.swift, demo fields kept
    enum Stage: Equatable { case queued, making(draft: Int, fixing: String), ready, failed(String) }
    let id: String            // explainer thread id
    var title, thread, answer: String; var captions: [String]; var since: Date; var stage: Stage
    var length: Int           // seconds, from timing
    var page: URL?            // runs/<id>/v<final or latest>/index.html: the player's file
    var poster: (light: URL?, dark: URL?)   // held frames for the static stage
    var draft = false         // final fell back to a draft (§2.4)
    var unseen = false
}
```

`RouterShowMeState` stays (armed, open, selected, explainers). `picture: String` becomes the poster URLs; the demo maps
its `Resources/ShowMeDemo` names onto them. `scene/elapsed` leave the model: the web player keeps its own time, with no
bridge (§8).

- **Who owns it:** `ExplainerEngine` (`@MainActor`, a `Store` lazy var next to `threadCards`) keeps `[RouterExplainer]`
  and pushes it with `routerPage.showMe = …` on each change (queue, version saved, finalize, watched). `RouterModel.showMe`
  is non-nil only when the Router is on and the explainer project is ready (the toggle hides otherwise).
- **Persistence, re-read at launch:** `runs/*/meta.json` gives title, source, ask, versions, final, `watchedAt`,
  `createdAt`. `queue.json` gives queued ones. The hidden shell gives live state (a run active = making). The newest 20
  are listed; older runs stay on disk.
- **Unseen dot:** `unseen = final != nil && (watchedAt == nil || watchedAt < finalAt)`. `watchedAt` is written when the
  panel shows that explainer selected and the window is key. It's Fjord-local: explainer threads are hidden, so T3's
  `thread.visit` would mean nothing to anyone.

## 7. Follow-ups through the composer

`RouterDock` already swaps the destination row for `RouterShowMeDestination` when the panel has an explainer and the
draft isn't empty (diff in `RouterDock.swift`). The send must follow that row:
- `RouterModel+Draft.swift` (the send at `:514`): when `showMe.open && showMe.chosen != nil`, route to
  `ExplainerEngine.followUp(explainer, words)` instead of `source?.send`. It goes outside `RouterActs` and the
  dispatcher: no decider, no decision log or History entry (hidden), no Jev read. The reader must skip too, or the draft
  would be decided against real threads: `RouterReader.read` returns early while the panel targets an explainer.
- `followUp`: if the explainer's run is idle, `store.dispatch(.messageDispatch(threadId:, messageId:, text: words,
  dispatch: .startImmediately(.steer)))`, the same shape as every send. If another creator is live, queue it as
  `followUp` (one creator at a time, §2.3). The words go as the owner's, unwrapped.
- Prompt addition (in `system.src.md`, rebuilt into CLAUDE.md): "Later messages are the viewer's notes on your film.
  Make a new version that answers them: preview it, and finish with the full code block again." Every follow-up gives a
  new final version (`v<n>`), and the dock shows the newest. The panel may later list versions; not now.
- Attachments and pills on a follow-up are refused plainly ("Explainers take words only"), not dropped silently.

## 8. Player

New `SF/ExplainerPlayer.swift`: `ExplainerWebView: NSViewRepresentable` over a `WKWebView` made with
`ExplainerWeb.configuration()` (§2.2: no network, no message handlers). The page is the version's `index.html`, loaded
with `loadFileURL(_, allowingReadAccessTo: projectRoot)`.
- **Theme:** set `webView.appearance` from Fjord's scheme (`@Environment(\.colorScheme)`; the Claude theme maps by its
  own light/dark). The kit listens to `prefers-color-scheme` and rebuilds keeping its time (`kit.js` `retheme`,
  `mount()` keeps `time` and `paused`). No JS call needed.
- **Chrome:** the page draws its own answer, caption, segments, time and Sources (`player.html`). Without a bridge,
  SwiftUI can't know the page's time, so the SwiftUI `RouterExplainerPlayer` controls go for ready explainers. Keep the
  title row, and add "Open in T3" under the web view (`t3code://threads/<env>/<id>`). The kit gains an `?embed=1` mode in
  `player.css` that hides `.ask` and tightens padding and font sizes to the panel's (`CDS.sans(14)` answer). The view is
  sized by width: stage 16:9 plus a fixed chrome height.
- **One web view**, kept by the panel and reused across selections (`load` on change), and released when the panel
  closes. Nothing runs at rest (the idle-CPU gate, `scripts/idle-cpu.sh`).
- **Static fallback:** `ExplainerStage` picks the web view only when `!Store.isDemo` and the explainer is `.ready`.
  Otherwise it draws `poster.light/dark` as an `Image`, the held frame as the approved tweak says (not dimmed), with the
  "Draft N · correcting" tag over it while making. Shots and demos never make a web view (shots can't capture one), and
  `v2-show-*` keep working on `Resources/ShowMeDemo`.

The approved tweaks land with the UI piece (P5):
1. While an explainer plays (`open && chosen?.stage == .ready`), `RouterShowMePanel` lists the selected row plus a
   "N more" row that expands the list on click.
2. `RouterShowMeToggle` shows only the glyph (width → `CDS.Composer.row`). The "Show me ⌘↩" hint
   (`RouterKeyHint`) appears beside it on hover or while it's on. `RouterShowMeLayout.toggle` and the composer's
   trailing padding (`RouterDock.swift` diff) follow the narrower width.
3. The making stage draws the draft's held frame at full opacity. The tag carries the state.

⌘↩: `RouterKeys` maps cmd+enter to "send with Show me once" with a draft, and to "Show me this reply" on a Done card with
an empty draft (hits `.showMe("toggle")` / `.footer(id, .showMe)` already exist in `RouterTypes.swift`).

## 9. Tests (`Tests/FjordTests/`, one suite per piece, `swift test --filter`)

- `ExplainerInputTests`: build the input from `T3Projection` fixtures made from two `EX/cases2` moments (projection JSON
  shaped like `T3Fixtures.swift`), compare with their `user.md`. Cases: steered follow-up; agent turns merged; notification
  and delegated-completion messages not counted as yours; activity windowing and the 40-line cut; subagent "(still
  running)"; redaction of tokens and home path; `<`/`>` escaped; card mode (no `ask`) picks the latest reply.
- `T3ShellHiddenTests`: `without(projectRoot:)` drops the project and its threads (subagents too); a `threadUpdated` of
  a hidden thread leaves `shell` unchanged and `RouterRecords` makes no entry; the project tally (filter bar, pills)
  excludes it; `DeciderBoardSource` and `RouterMCP.board` don't list it; `search_threads` drops a hidden hit and
  `read_thread` refuses a hidden id; `routerThreadChanged` ignores a hidden id.
- `ExplainerQueueTests`: enqueue on `.taken` only (refused → nothing); turn end by shell rows (`activeRunId` nil,
  `latestRunCompletedAt >= sentAt`); stopped/failed/archived source drops the entry; one creator at a time, FIFO; follow-up
  held while another runs; reload from `queue.json` then evaluate on `.synchronized`; 24 h expiry.
- `ExplainerFinalTests`: last js block equal to the last version → final; different → new version; none → last unbroken
  version as draft; none at all → failed.
- `ExplainerProjectTests`: stamp unchanged → no write; changed → managed files rewritten, `runs/` untouched; `.mcp.json`
  0600 with the port and token; the built prompt matches `system.src.md` + example (`promptIsBuilt`); `guard.sh` allows
  exactly preview and ToolSearch (run with `/bin/sh` on sample stdin).
- `RouterMCPTests` (extend): image content blocks encoded; a preview call with no or two live explainer runs is an error
  and saves nothing.
- Not unit-tested: `ExplainerRenderer` against real WebKit. One opt-in `FJORD_EXPLAINER_LIVE=1 swift test --filter
  ExplainerRenderLive` renders `EX/examples/lastdrop.js` offscreen and checks timing, notes and frame count (no window
  shows, per "lean, useful checks").

## 10. Work split

Before P1: the uncommitted demo (`RouterShowMe*.swift`, `Resources/ShowMeDemo`, the five modified Router files) is
committed as it stands (`feat: Show me demo …`), so pieces diff against it.

| # | Commit | Owns (new unless marked) | Depends |
|---|---|---|---|
| P1 | `feat: Fjord keeps a hidden Explainers project in T3, with the creator's instructions, the kit and a tool lock, and hides it from every Router surface` | `SF/ExplainerProject.swift`; `Resources/Explainer/**`; `scripts/build-explainer-prompt.sh`; `scripts/build-app.sh` (M); `SF/T3Store.swift` (M: `hidden`, `hiddenRoot`, `apply`, `without`); `SF/RouterThreads.swift` (M); `EX/system.src.md` (M: follow-up paragraph); tests `ExplainerProjectTests`, `T3ShellHiddenTests` | — |
| P2 | `feat: Fjord renders explainers offscreen in WebKit and serves preview over a persistent MCP server` | `SF/ExplainerRenderer.swift`, `SF/ExplainerWeb.swift` (shared config), `SF/ExplainerMCP.swift`, `SF/ExplainerStore.swift` (versions, meta); `SF/RouterMCP.swift` (M: images, token/port, maxResponse); `Resources/Explainer/kit/kit.js` (M: `__spec`, ready on load error) and `player.css` (M: `embed`), which P1 has already copied; tests `RouterMCPTests` (M), `ExplainerRenderLive` | P1 |
| P3 | `feat: a Show me request waits for its thread's turn to end, then starts an Opus explainer thread on the question, the answer and the turn's activity` | `SF/ExplainerInput.swift`, `SF/ExplainerQueue.swift`, `SF/ExplainerEngine.swift`, `SF/ExplainerTypes.swift`; `SF/Store.swift` (M: `explainers` lazy var, start); `SF/Store+Router.swift` (M: two lines in `routerShellChanged` / `routerThreadChanged`); tests `ExplainerInputTests`, `ExplainerQueueTests`, `ExplainerFinalTests` | P1. Calls P2 through a protocol `ExplainerRendering` that P3 declares in `ExplainerTypes.swift` and P2 conforms to; P3's tests use a stub |
| P4 | `feat: the explainer player is a sandboxed web view that follows Fjord's theme, with a held frame in shots and demos` | `SF/ExplainerPlayer.swift` (`ExplainerWebView`, `ExplainerStage`) | P2's `ExplainerWeb.swift` (or P4 writes it and P2 takes it: agree up front) |
| P5 | `feat: Show me is live on the Router page: the toggle and ⌘↩, Show me on a Done card, the dock and its panel, follow-ups from the composer` | `SF/RouterShowMe.swift`, `SF/RouterShowMePanel.swift`, `SF/RouterShowMeDemo.swift`, `SF/RouterDock.swift`, `SF/RouterModel.swift`, `SF/RouterModel+Draft.swift`, `SF/RouterPort.swift`, `SF/RouterActs.swift`, `SF/RouterReader.swift`, `SF/RouterKeys.swift`, `SF/RouterSummaryView.swift`, `SF/RouterTypes.swift`, `SF/RouterShots.swift` (all M); `RouterActsTests` (M: `showMe` carried to `.taken`) | P3, P4 |

Order: P1 → (P2, P3, P4 in parallel) → P5. P2 and P4 share only `ExplainerWeb.swift`: give it to P2 and have P4 build on
a stub until P2 lands, or write it in P1 (preferred: P1 adds the 30-line `ExplainerWeb.configuration()`, then P2 and P4
only read it). Each piece runs `scripts/test.sh` once before its commit. P5 checks the `v2-show-*` shots
(`.build/debug/Fjord --window-shots .build/shots v2-show`), light and dark.

## 11. Blockers, risks, spikes

- **B1 (spike S1, blocking P1's design): does a T3 Claude thread load the project's `.mcp.json` and settings?** The
  source says yes (no `settingSources`, so SDK default "all"). But project MCP servers need approval, and whether
  `enabledMcpjsonServers` in `settings.local.json` is enough under the SDK isn't verified. Spike: make the folder by
  hand, `project.create`, launch one Haiku thread that's asked to call `mcp__fjord__preview` against a stub server
  (`FJORD_T3_LIVE=1`, like `T3AttachmentLive`), and confirm the guard denies `Bash`. Options if it fails: (a)
  `enableAllProjectMcpServers: true`; (b) T3's own MCP config (T3 settings has MCP servers per provider? not found in
  0.1.7: check `server.getConfig`); (c) a dedicated T3 provider instance with `--mcp-config` in its launch args (writes
  T3's settings: needs the owner's yes).
- **B2: one creator at a time.** `preview` can't say which thread called it (one `.mcp.json` per project, no
  per-session header). Serial creators are exact but make a second request wait, about 45–95 s per creator (the
  `EX/cases2/*/run.json` wall times, 1–3 versions each). Option if that hurts: a `ticket` argument the input hands the creator ("call
  preview with ticket=<id>"), a field the model copies. It's cheap, but it can be miscopied.
- **B3: the user's own `~/.claude` loads into the creator** (global CLAUDE.md, plugins, hooks such as lastdrop's agent
  routing). The guard stops their tools, but their text costs tokens and may distract the prompt the evals tuned with
  `--setting-sources ""`. Options: accept and eval it once on the eight `cases2` moments through T3; or a T3 provider
  instance with its own `CLAUDE_CONFIG_DIR` (a second login, a T3 settings write: the owner's call).
- **B4: MCP image budget.** Claude Code caps MCP tool output (`MAX_MCP_OUTPUT_TOKENS`). The Python server's 5–7 PNGs
  passed in `claude -p`, so JPEG at 1× should too. Verify in S1 with a 7-frame answer.
- **B5: `takeSnapshot` of an offscreen WKWebView** has to actually paint. A window off every screen paints for
  `cacheDisplay` (the shots), but WebKit may throttle a view it considers hidden. Spike S2: render `lastdrop.js` and
  compare frames with `EX/cases2/8-lastdrop-different/v*/scene-*.png`. Fallback: an `NSPanel` at alpha 0.01 inside a
  visible screen area, ordered back (no focus, no Dock icon; LSUIElement already).
- **S3:** can a thread launch into an archived T3 project (to hide it in T3's sidebar too)? Optional.
- Cost: an Opus creator per Show me (the eight cases ran $0.22–0.43 each, `run.json`). It only runs when asked, which is the
  owner's trade-off; it's logged per thread in T3's usage, not in `model-usage.jsonl` (that file is for Fjord's own calls).

## 12. Spike results (2026-11-14)

The scripts are throwaway, in the session scratchpad (`spikes/b1`, `b4`, `b5`). Nothing was committed, and the T3 project and threads were deleted.

- **B5 settled: no fallback needed.** A borderless `NSWindow` that is never ordered in (and one at −20000,−20000, ordered back) paints fully with `takeSnapshot(afterScreenUpdates: true)`: Geist and Geist Mono, GSAP state at the seek, and the kit's chrome. The two modes give byte-identical PNGs. Each page loads `?scene=N` and waits for `body[data-ready="1"]` through a `MutationObserver` and a script message, with no polling. On `cases2/1-claude-token/final.js`, 5 scenes: about 58 ms from load to ready, 58 ms for the snapshot (2000×1520 at 2×), and about 165 ms per frame including the PNG encode. The process ran with `.prohibited` activation policy: no Dock icon and no focus change. Plan changes: drop the alpha-0.01 `NSPanel` fallback. Pass `theme=` explicitly, because the page otherwise follows the system appearance. Set `WKSnapshotConfiguration.snapshotWidth` to 1000 for 1× frames.
- **B4 settled: 7 images arrive whole.** `claude -p --model sonnet` with a FastMCP stdio tool returning text plus 7 images at 1000×560 received all 7, with no warning or truncation. It read frame 7's headline and labels exactly. JPEG q80 was 61–84 KB per frame (about 485 KB total); PNG was 250–330 KB (about 2.1 MB). The token cost is the same, about 6.4k input tokens for the batch, because images are billed by pixels, so JPEG only saves bytes. Claude Code adds an `[Image: source: ~/.claude/projects/<cwd>/<session>/…]` text block per image and keeps a copy there. Plan change: JPEG at 1× is fine, and 7 frames per preview is within budget.
- **B1 settled: the project's `.mcp.json` and settings load in a T3 Claude thread.** A project on a folder with `.mcp.json` (stdio `ping`), `.claude/settings.json` (`enabledMcpjsonServers: ["ping"]`, deny `Bash`/`Write`/`Edit`/`WebFetch`, allow `mcp__ping__ping`) and a `CLAUDE.md` loaded all three. The thread was launched with `orchestration.launchThread`, `claudeAgent`/`claude-sonnet-5-5`, `runtimeMode: "auto"` and `interactionMode: "default"`. The ping tool was called once (server log); the model reached it after 2 `ToolSearch` calls, because project MCP tools are deferred. Bash was removed from the toolset outright ("No such tool available: Bash"), with no approval request. The `CLAUDE.md` marker word showed in the reply. `enableAllProjectMcpServers` wasn't needed. Plan changes: P1 writes `enabledMcpjsonServers` plus the deny list in `.claude/settings.json`. `launchThread` must send `runtimeMode` (it's required: "Missing key runtimeMode"). The creator's prompt should name the full tool name (`mcp__fjord__preview`) so its ToolSearch is one hop.
- **S3: yes.** `project.update {archived: true}` (a Boolean; `archivedAt` is silently ignored) archives the project, and `launchThread` into it is still accepted. P1 can archive the Explainers project to hide it from T3's sidebar.

## 13. Decisions after the spikes (2026-11-14)
- B2: creators run in parallel. The input gives each creator a `ticket` and the prompt tells it to pass `ticket` on
  every `preview` call (`mcp__fjord__preview`, named in full). A missing or unknown ticket is an error that names the
  fix.
- B3: accept the user's `~/.claude` loading; eval the eight `cases2` moments through T3 once P3 lands and compare with
  the `claude -p` runs.
- B5: there's no panel fallback; render with an explicit `theme=` and 1× frames (snapshot width 1000).
- Launches send `runtimeMode` explicitly. The Explainers project is archived in T3 (`archived: true`) so T3's sidebar
  hides it too; launches still work.
- `ExplainerWeb.configuration()` is written in P1; P2 and P4 only read it.

## Build notes

### P1 (2026-11-14)
- **No `settings.local.json`.** `enabledMcpjsonServers: ["fjord"]` sits in `.claude/settings.json` with the deny list and
  the hook, which is what spike B1 loaded.
- **Fonts have one source.** `Resources/Explainer/kit/` has no `fonts/`: `ExplainerProject.sync()` copies `Resources/Fonts`
  into `kit/fonts/`, and the stamp covers those files too. `Resources/Explainer/kit/` is the shipped kit now. `EX/kit` stays
  the eval copy.
- **The guard parses JSON with `/usr/bin/plutil`**, not sed. A `tool_name` inside a call's input can't pass as the tool's
  name, and input it can't read is denied.
- **Ticket.** The prompt tells the creator to call `mcp__fjord__preview` with `code` and the input's `ticket` (plus `at`).
  The input's first line is `<ticket>…</ticket>` (P3 writes it; the example input in the prompt shows it). P2's tool takes
  `code`, `ticket` and an optional `at`. `EX/preview_server.py` needs a `ticket` argument it ignores before evals run on
  the new prompt.
- **`ExplainerWeb.configuration()` is `async throws`**, because compiling the rule list is async (it's compiled once per
  run). The rule list blocks every load that isn't `file:`, not only http(s)/ws(s). `ExplainerWeb.LocalOnly` is a ready
  navigation and UI delegate for P4. P2's renderer calls `ExplainerWeb.policy(for:)` from its own delegate.
- **P1 wires nothing at launch**, because `Store*.swift` belongs to P3. P3's `ExplainerEngine.start()` must:
  (1) set `t3.store.hiddenRoot = project.root.path` before T3's shell arrives, whenever `ExplainerProject.at(support:)` is
  non-nil, whether the Router is on or off (Triage's lists read the shell too);
  (2) run `sync()` off the main actor;
  (3) on the first `t3.store.hidden.answered`, call `ensure(in: t3.store.hidden, mutate: ExplainerProject.liveMutate)` for
  the project id;
  (4) in `routerThreadChanged`, ignore ids where `t3.store.isHidden(thread:)` is true.
- **Archived projects.** T3's shell still lists archived projects (it drops only deleted ones), so `ensure` finds the
  archived project by its folder. `Store.t3Project(forFolder:)` and `Store.launchThread` refuse archived projects, which
  is one more reason P3 dispatches `.launchThread` directly.
- **`.mcp.json` is P1's file to write.** `writeServer(_:)` writes it with mode 0600, and only when it changes. `server()`
  reads back the port and token, so P2 can bind the same port next launch.

### P2 (2026-11-14)
- **`ExplainerMCP` is P3's `ExplainerRendering`.** `start(project:host:)` binds the port `.mcp.json` names with its token
  (`RouterMCPServer(token:preferredPort:)`), takes any port when that one is held, and rewrites `.mcp.json` through
  `writeServer`. `preview(code, ticket, at?)` resolves the ticket with `host.ticket(_:)`; a missing or unknown ticket, missing
  code or a bad `at` is an error that names the fix and saves nothing. `host.versionSaved` is called for `preview` saves only,
  not for the engine's own `render(_:ticket:)`. Renders share one web view and run one after another, across runs.
- **Files per version:** `runs/<run>/v<n>.js`, `v<n>/index.html`, `explainer.js`, `f-scene-<i>.jpg`, `f-t-<t>.jpg`,
  `poster-light.jpg`, `poster-dark.jpg`, and one entry in `meta.json` (`{versions: [{number, broken, note, title, answer,
  captions, length}]}`). `v<n>.js` is written before the render, so a crash mid-render never reuses its number.
- **Frames for the model are 1000 px wide (1×), scaled down from the Retina snapshot.** Posters keep the screen's scale (2000
  px on Retina), because the panel shows them.
- **One load per render, then seeks.** The page loads with `?theme=light&scene=0`; each frame is `__film.timeline.time(t)`
  (not `seek`, which skips the player's update, so the caption would lag), then a snapshot. No `requestAnimationFrame` wait:
  a window that's never ordered in may not run frames, and `takeSnapshot(afterScreenUpdates:)` paints anyway. The example
  (5 scenes, one `at`, both posters) takes about 1.0 s.
- **Errors in WebKit.** WebKit's `Error.stack` leaves out the message, and an error thrown by another `file:` script reads
  "Script error.". The kit's `fail` now keeps name, message and stack. Before loading, the renderer checks the code's syntax
  with JavaScriptCore (`JSCheckScriptSyntax`), which names the error and its line. Stack paths are shortened to
  `kit/kit.js:…` and `explainer.js:…`. A page that never gets ready in 20 s (an endless loop) is reported as broken, and the
  web view is made again.
- **Kit changes** (shipped kit only; `EX/kit` stays the eval copy and lacks them): `window.__spec`; `data-ready="error"` when
  explainer.js doesn't parse, throws first, never calls `explainer()`, or `explainer()` throws; `?embed=1` → `.embed` on the
  root, styled in `player.css` for the panel (no question, edge to edge, panel type sizes).
- **`EX/preview_server.py` takes and requires `ticket`.** `EX/run.py` still names its server `explainer`, so its tool is
  `mcp__explainer__preview` while the prompt says `mcp__fjord__preview`, and its inputs carry no `<ticket>` line. Both need
  updating before evals run on the new prompt.
- **Live check:** `FJORD_EXPLAINER_LIVE=1 swift test --filter ExplainerRenderLive` (offscreen, about 2 s);
  `FJORD_EXPLAINER_KEEP=<dir>` keeps the frames. It isn't listed in DEVELOPMENT.md yet, because P2 doesn't own that file.

### P3 (2026-11-14)
- **Creators run in parallel (§13), so the queue holds only requests that haven't launched.** `ExplainerRequest.State` is
  `waitingForTurn` / `waitingForCreator`; a launched request leaves `queue.json` and is a run from then on
  (`runs/<id>/run.json`: ticket, source, ask, final, draft, failed, `watchedAt`, `completedThrough`). There's no `followUp`
  field: `ExplainerEngine.followUp(id, words:)` steers the explainer's thread at once (`startImmediately(.steer)`, unwrapped).
  The renderer owns `meta.json` and `v<n>.*`; the engine never writes them.
- **The ticket is 8 hex characters minted per run**, not the thread id, so it copies cleanly. `host.ticket(_:)` resolves any
  run Fjord knows, so a follow-up's previews save into the same run.
- **Every follow-up run is finalized again.** A run is finalized when its hidden row has no live run and
  `latestRunCompletedAt` (or `updatedAt` for a stopped run) is newer than `completedThrough`.
- **Redaction is the Python's (`build_case2.py`), not `RouterTools.redacted`.** Jev's rule for long mixed strings cut paths,
  branch names and ids the explainer needs (and broke the golden files). This input goes to the provider that ran the thread,
  not to a third party. `at=` times are in the Mac's time zone (the Python's were UTC).
- **Golden files:** `ExplainerInputTests.theEvalMomentsBuildAgain` reads each `cases2/*/user.md` back into a projection and
  builds it again. All 8 match byte for byte, except the dynamic-tool briefs the Python cut: T3's JSON keeps no key order
  (`pythonJSON` sorts keys), so those lines are compared up to the tool's name. The test skips when the files are absent.
- **The dock type is `ExplainerItem`** (in `ExplainerEngine.swift`), not `RouterExplainer`, which lives in P5's
  `RouterShowMe.swift`. `ExplainerEngine.onChange` hands P5 the newest 20; P5 maps them onto `RouterExplainer` (or replaces
  it) and sets `routerPage.showMe`.
- **For P5:** call `store.explainers.requested(source:ask:sentAt:)` on `.taken` with the delivered message id,
  `requested(reply:)` for a Done card's Show me, `followUp(_:words:)` for the composer while the panel targets an
  explainer, and `watched(_:)` when the panel shows one with the window key. `start()` runs in `startServices` before
  `t3.start()` (not in tests or demos); `routerShellChanged` calls `explainers.shell(item)`, and `routerThreadChanged`
  ignores hidden ids.
