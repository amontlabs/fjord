# F3: user-facing feature catalog and Claude-specific UI/plumbing

Repo: /Users/polarzero/code/projects/lookout (app "Fjord"). Sources in `Sources/Fjord`, cited as `File:line`. Read-only; no git, no run.
Legend. **C-data** = reads Claude/claude.ai state. **C-action** = writes to or acts on Claude (hook, plugin, claude -p, claude.ai tab, deep link). **Indep** = GitHub, CI, Silo or local only.
Coverage: I read README, DEVELOPMENT, the shot catalog, DemoBriefs, Settings, Onboarding, the sidebar, the Router views, the Hub files, Palette sources, Shortcuts, main.swift and the Claude design/brand files. Files I only skimmed or grepped are named in section 7.

## 0. Shape of the app (what matters for the T3 rebuild)

- Two tools plus an add-on, switched in Settings → Tools: **Triage** (GitHub inbox/CI), **Router** (Claude brief + composer), **Computers** (Silo VMs). `Tool.allCases` drives Onboarding (`Onboarding.swift:30`, `SettingsView.swift:149-165`).
- Surfaces: the bar (the "hub", `Hub*.swift`), the window (`AppWindow.swift`, sidebar + pages), the ⌘K palette (`Palette*.swift`), and Settings as a window page.
- Router is only on when the Claude desktop app is installed: the switch is disabled with "Needs the Claude desktop app" (`SettingsView.swift:399-410`, `Onboarding.swift:52-58`). `Claude.isInstalled` is the gate.
- README states the Router "follows sessions started in [the Claude app's] Code tab, not `claude` in a terminal" (README.md Install table). So the whole Router is tied to the Claude desktop app, not just to Claude Code.

## 1. FEATURE CATALOG

### 1a. Router (every row depends on Claude unless marked)

| # | Feature | Where | Depends on Claude? how |
|---|---|---|---|
| R1 | Brief page: general lead ("for you" / "worth a look"), then one paragraph per project, ordered needs-you, stranded, finished-untold, working, quiet. 12 projects at most; the rest are folded into "Also: …" | `RouterBriefView.swift:3-9,30-60` | C-data. Prose is written by Haiku through Claude Code, per project doc (`BriefDoc`). Threads come from claude.ai (courier Board) and local Claude Desktop sessions. |
| R2 | Thread highlights in prose (`<t id=…>`), coloured by the thread's state, with a peek on hover and a popover on click | `RouterBriefView.swift:7-9`; `RouterBriefMarkup.swift`; shots `brief-hover*` (`AppWindowShots.swift:~255-262`) | C-data |
| R3 | Highlight panel kinds: question with options, plan (Yes auto-accept / Yes manual / No), a local form with several questions and one Send, finished thread with a message line, stranded ("stopped; tell it to go on"), permission ("waits for a permission, which only Claude can grant: open it") | `RouterBriefView.swift:560-720` (options, `formQuestions`, `placeholder`, `note`); `BriefEntryText.kindLabel` at `:712-720` | C-data and C-action. Answering a claude.ai thread goes through the courier tab. A local session is answered through the form hook / plugin (INFERRED from `Forms.swift`, `ClaudePlugin.swift`). |
| R4 | Keyboard on options: "Click an option, or press its number then Return" | `RouterBriefView.swift:678` | C-action |
| R5 | Mark read (leaves the brief, Revert in history) and archive | `RouterBriefView.swift:683-687`; DEVELOPMENT.md "Router's routing" | Fjord-local state (briefs.db "Told" marks). Meaning is about threads. **Indep of Claude as an action**; only the data it marks is Claude's. |
| R6 | Open in Claude (button, context menu, palette action, bar line): deep-links to the Claude app session or claude.ai thread | `RouterBriefView.swift:688`; `RouterView.swift:632`; `PaletteRouterSource.swift:59,76,106`; `Store.openAgent` | C-action: opens the Claude desktop app, or claude.ai (`.help` at `RouterBriefView.swift:690`). |
| R7 | Open a thread: Triage → Claude handoff chip "session started" / "sent to <session>" opens the session in Claude | `InboxActions.swift:791-810,1253` | C-action |
| R8 | Stale/"as of" markers: "as of 12m", "updated 3h ago", "Being rewritten" | `RouterBriefView.swift:168,202,206`; shots `brief-stale` | C-data (watch state from the courier / transcript feeds) |
| R9 | All-quiet and empty states ("Nothing going on…", "Turn the Router on and the brief will tell you…") | `RouterBriefView.swift:44-50` | Text refers to threads |
| R10 | History drawer: one line per event under its day: Sent (with status sending/delivered/asked/failed/cancelled), Answers, Changes (Fjord setting changes with Revert/Open). Failed sends are pinned on top with Send again and Elsewhere. Filters Sent / Answers / Changes. A click makes the thread the composer's mention. Right-side panel on wide windows, bottom on narrow. | `RouterDrawer.swift:1-70`, `RouterDrawer.Filter` `:21-24`, `:74-87` | Mixed. Sent/Answers are Claude-thread events. Changes are Fjord-local (**Indep** for Revert/Apply of Fjord settings changes, `RouterChangeCard.swift:78-83`). |
| R11 | Composer: type a message; the Router picks the claude.ai project/thread; "delivers your exact words as your own message" | README "Type once"; `RouterComposer.swift`; `RouterView.swift:310-340` | C-action: courier (Chrome + extension + claude.ai tab) or local plugin relay. |
| R12 | Send stages on the message pill (rules / Jev / Sonnet), Stop button ("Stops the Router's runs"), Send tip "Return · ⇧Return for a new line" | `RouterComposer.swift:207-212`; DEVELOPMENT.md "Router's routing" | C-action (`claude -p` runs: Sonnet decider, Haiku) |
| R13 | "Where should this go?" ask with ⌘1–⌘4 by key position, "New project…" option, the Router's own answer | `RouterComposer.swift:475-510`; `RouterKeys.swift:9,35`; README Keyboard | C-data (places = claude.ai projects/threads/local sessions) |
| R14 | Project proposal pill under the composer (create a claude.ai project: name, folder, repo, instructions, Create/Try again, "made"/"Your message is on its way there") | `RouterProjectProposalPill.swift:54-105`; shots `router-proposal-*` (`AppWindowShots.swift:~63-90 of 2nd part`) | C-action: creates a claude.ai project through the courier tools. |
| R15 | Courier pills over the composer, one per engine state (shots `router-courier-<state>[-dark]`) | `RouterCourierPill.swift`; `AppWindowShots.swift:347` | C-action state: claude.ai delivery engine status |
| R16 | Cancel / edit-and-resend / send-elsewhere ("Change your mind") | README Router bullet 3; `RouterCancel.swift` | C-action |
| R17 | Reply targets: arm a reply on a brief entry or focus, so the words go to that thread, no model | `RouterView.swift:313-330`; DEVELOPMENT.md | C-action |
| R18 | ⌘-click on highlights mentions several threads: a chip each over the composer, and Return sends to every one. A refusing thread stays picked. | `RouterView.swift:313-326`; shot `brief-mentions` | C-action |
| R19 | `@` mentions: project, session, GitHub item, saved prompt (snippet). Ranking prefix, then contains, then fuzzy. | `RouterView.swift:540-560` (`RouterMentions`); `RouterMentionField.swift`; README | Project/session mentions: C-data (folders from Claude sessions + code folders). GitHub items and snippets: **Indep**. |
| R20 | Working list (bar panel and sidebar): session glyph, title, activity ("Reading sandbox.rs"), minutes, running tasks tooltip; click opens in Claude; context menu Open in Claude / Pick an icon | `RouterView.swift:565-650`; `Store.routerWorkingRows` `:36-48` | C-data: Claude session JSON, transcripts, task list in `/private/tmp/claude-<uid>`. |
| R21 | Needs-you lines in the bar panel (BriefEntryLine, 2 lines: thread + age, kind · project · question) | `RouterView.swift:655-686` | C-data |
| R22 | Router sidebar row with amber needs-you count; accessibility "N need you" | `AppSidebar.swift:296-316` | C-data |
| R23 | Bar: Router cell with amber count corner badge; Router header "Router · N need you"; "N more in the Router"; "Open Router" button; ⌃⌥R | `HubComponents.swift:1058-1085`; `HubSections.swift:204-276`; `Shortcuts.swift:144,169` | C-data |
| R24 | Claude link notice in the bar ("Claude's sessions not found" / "Can't read Claude's sessions") and `ClaudeLinkStatus` (Synced with Claude / Claude isn't running / …) | `HubView.swift:504-515`; `ClaudeLinkStatus.swift:1-20` | C-data: the Claude app's `sessionsDir` health |
| R25 | Composer notices: "The Router is off" (Turn on), "Claude Code wasn't found. Install or open the Claude desktop app." (Look again), "The form hook couldn't be installed" | `RouterView.swift:~300-310` | C-data, C-action |
| R26 | Native banners for new needs-you entries, each told once; more than `notifyEach` collapse into "N threads need you" with project names | `RouterBriefs.swift:289-304` | C-data |
| R27 | Router's change cards: Apply/Discard/Open/Revert for Fjord changes proposed by the Router ("make a category for PRs by bots") | `RouterChangeCard.swift:78-83`; README "Triage" last paragraph | The proposing model is Claude (Haiku via `claude -p` with Fjord MCP, `RouterMCP.swift`). The apply/revert is **Indep**. |
| R28 | Router answers questions about the board itself (the Router's own answer), "It only talks; never edits files, runs commands or acts on GitHub" | README Router bullet 6; `RouterMCP.swift` | C-action (`claude -p` + local MCP server `http://127.0.0.1:…/mcp`, `RouterMCPTests.swift:63`) |
| R29 | Jev routing (TypeSafe classifier): where a message goes, how a turn ended, session icons | README Privacy; `SettingsView.swift:479-495`; `Jev*.swift` | **Not Claude** (TypeSafe), but it consumes Claude-session data and is part of routing. |
| R30 | Session icons: Jev picks an SF Symbol per session (code, debugging, data…), "Pick an icon / Pick another icon", labels (two letters or emoji) | `SessionIcons.swift`; `SessionGlyph.swift`; `Agents.swift:7-22` | Keyed by Claude session id; data = session title, project and first message. |
| R31 | Session status dot in lists: needs you #fab219, ready #2a78d6, working, quiet | `SessionGlyph.swift:40-60` (`ClaudeDot`) | C-data |
| R32 | Run sessions on a Silo computer: a "Runs on" picker per Router project (this Mac / computer), `pendingDesktopStarts`, guest project grouping "project · alias @ owner:folder" | `ProjectPlacement.swift`; `Router.swift:23`; `RouterView.swift:11-35`; `GuestDesktopStart.swift` | C-action: starts Claude Desktop sessions in a guest VM (needs Node.js + Claude Code CLI there, `ComputersPanels.swift:278`). |
| R33 | Muted folders: the Router ignores their sessions | `SettingsView.swift:497-530` | C-data |
| R34 | "How the Router writes to you": free-text style for Haiku's briefs/summaries; Reset | `SettingsView.swift:468-477` | C-action (prompt to Haiku via Claude Code) |
| R35 | Palette Router source: needs-you entries, threads touched in 24h, every session (open in Claude, linked PR), and the last "send to the Router" row | `PaletteRouterSource.swift:1-190`; shot `palette-router` | C-data / C-action |
| R36 | Setup health in Settings: "Form hook installed/outdated/not installed", "Fjord's Claude Code plugin: installed/update needed/…", "Claude Code <version>, from the Claude app" | `SettingsView.swift:419-455` | C-action (installs hook + plugin into `~/.claude`). |
| R37 | Settings → "Delivery through claude.ai" checklist: Chrome installed / extension loaded / Chrome can reach Fjord (native host manifest) / Fjord's tab connected / Signed in to claude.ai (Sign in button) | `RouterCourierSetup.swift:104-140,185-210`; shots `courier-setup-*` | C-action: Chrome extension + native messaging host. Other agents cover delivery in depth. |

### 1b. Triage (GitHub) and its Claude touchpoints

| # | Feature | Where | Claude? |
|---|---|---|---|
| T1 | Inbox of PRs/issues/workflows in categories, tabs in the bar and sidebar with unread counts (CI category shows "N failing") | `AppSidebar.swift:104-215`; `HubSections.swift:58,392` | **Indep** |
| T2 | Rules in plain sentences ("PRs by me in *Repos I contribute to*, when any of: new review by *Maintainers*, checks failing"), rule editor, rule words | `RuleEditor.swift`; `RuleLogic.swift`; `RuleWords.swift` | **Indep** (Jev conditions optional: comment labeled, rated at least) |
| T3 | Categories editor, sections (fold, reorder by drag), category colour/symbol, hidden categories, category history/undo | `CategoryEditor.swift`; `CategoriesView.swift`; `CategorySections.swift`; `Undo.swift` | **Indep**. Router can propose category changes (R27). |
| T4 | Archive (a row, count), Done page, back to inbox | `AppSidebar.swift:119-131` | **Indep** |
| T5 | Undo for Archive: line under the header, ⌘Z 30 s | `Undo.swift:1-30`; README Keyboard | **Indep** |
| T6 | Keyboard: Return opens on GitHub, Space read/unread, ⌥Space all read, ⌫ archive, ⌘R refresh, ⌘F search; remappable in Settings → Shortcuts, with mouse buttons | `Shortcuts.swift:130-170,221-241` | **Indep** except `.router` and `.openInRouter` (⌘↩, `Shortcuts.swift:144-145,169-170`) |
| T7 | Row actions: toggle read, archive, GitHub, "Open in Router" (tags the item in a Router message) | `HubComponents.swift:329-378` | Open in Router: C-action (Router must be on) |
| T8 | Category actions ("Then"): comment on GitHub, re-run failed jobs, **Send to the Router** (prompt with @this item tag, trigger "when it comes in" / "on each new fact") | `ActionEditor.swift:19,101-110,168-182,248`; `InboxActions.swift:19-37` | Comment and rerun: **Indep**. Send to the Router: **C-action**. It reaches a session working in the repo, or starts one in a local clone, running "with your Claude Code permission settings, unattended". Shows a prompt-injection warning "GitHub text reaches a Claude session on your Mac" (`ActionEditor.swift:175-180`). |
| T9 | Action chips on rows: "session started", "sent to <session>", "waiting on you in the Router", "failed"; ledger of runs (`ActionRun.sessionID`) | `InboxActions.swift:129-135,745-810,865-908` | C-data / C-action |
| T10 | Action outcome follows the Router's decision on the message (asked you, sent, started a session, failed) | `ActionPrompt.swift:164-215` | C-data |
| T11 | `SessionOrigin` for sessions the Router starts for an action (name, category, thing, action id; unattended) | `ActionPrompt.swift:144-150`; `InboxActions.swift:865` | C-action |
| T12 | Palette: Triage source (inbox items, categories, link between a thing and the session started for it) | `PaletteTriageSource.swift:1-80` | Link to session: C-data. Rest **Indep**. |
| T13 | GitHub sign-in (`gh auth token`, `GH_TOKEN`, pasted PAT in Keychain), "Retry", "Use gh CLI" | `SettingsView.swift:545-580` | **Indep** |
| T14 | GitHub rate-limit warning "N API calls left this hour" when < 500 | `RateLimitWarning.swift:1-16` | **Indep**. It is GitHub only. **There is no Claude usage/rate-limit display anywhere in the app** (grep of Claude-named files showed none; INFERRED). |
| T15 | Snippets (saved prompts) page; inserted with `@` | `AppSidebar.swift`; `Snippets.swift`; shot `snippets` | **Indep** (used in prompts to Claude) |
| T16 | Jev comment labels (asks you / to do / FYI / noise), review-request rating | `SettingsView.swift:459-466`; `InboxJev.swift` | TypeSafe, **Indep of Claude**. Consumes session context for "what a session waits on" (`SettingsView.swift:462`). |
| T17 | Desktop notification banners for inbox facts; snooze 30 m / 1 h / 3 h / until tomorrow | `SettingsView.swift:185-215`; `InboxSync.swift:1926` | **Indep** |
| T18 | Bar "agents" demo scenario and CI cells | `Demo.swift` scenarios `agents`, `ciRunning` | Bar CI cells **Indep**. Agents: C-data (INFERRED: `agents` sets Claude sessions via `Demo.sessions`, `Demo.swift:569-620`). |

### 1c. Computers (Silo) and platform shell: all **Indep** of Claude except where noted

| # | Feature | Where | Claude? |
|---|---|---|---|
| C1 | Computers page: list, create Linux/macOS computer, detail tabs (overview, files, network, access, activity, storage, viewer, checkpoints), queue, remote Macs, quit dialog | `ComputersView.swift`; shots `AppWindowShots.swift:124-240` | **Indep** (Silo engine) |
| C2 | **Agent tools panel**: "Node.js and Claude Code CLI" on the guest, Set up / Update, "Router sessions in this computer need Node.js and Claude Code" | `AgentTools.swift:1-12`; `ComputersPanels.swift:245-278`; `ComputersFeatures.swift:685-763` | **C-action**. Installs the Claude Code CLI inside guest VMs. |
| C3 | Computer defaults (automatic checkpoints, start at launch), Connected Macs (SSH alias, host key), allow other Macs | `ComputerHostSettings.swift:47-172` | **Indep** |
| C4 | Silo engine enable (SMAppService LaunchAgent) | DEVELOPMENT.md "Regenerate the Silo client" | **Indep** |
| C5 | Claude Desktop SSH connections owned by Fjord: `ClaudeSettingsFile` serializes writes to Claude's settings for the local PermissionRequest hook and "owned Desktop SSH connections" | `ClaudeSSHSettings.swift:1-14`; `ClaudeSSHSettingsTests.swift` | **C-action** (writes Claude Desktop config so it can run a session in a guest). No Settings UI section named SSH for Claude; the SSH UI is "Connected Macs" (`ComputerHostSettings.swift:123-172`), which is Silo. |
| W1 | Window: sidebar (Inbox heading, categories, Archive, Router, Computers, Settings), collapsible rail, back/forward, ⌘1…numbers for pages, restore | `AppSidebar.swift`; `AppNavigation.swift:35-40,229-300` | **Indep** (sidebar Router row is C-data) |
| W2 | Bar on any edge of any screen, hover to peek, click to open the window, update button, glass on macOS 26 | `HubView.swift`; `HubPeek.swift`; `Chrome.swift:1-40`; `UpdateButton.swift` | **Indep** apart from the Router cell |
| W3 | Palette ⌘K: places, settings rows, inbox, categories, sessions, threads | `Palette*.swift`; shots `palette*` | Sessions/threads/Router row: Claude. Rest **Indep**. |
| W4 | Onboarding: pick tools (Triage → GitHub sign-in, Router → optional TypeSafe key and "Needs the Claude desktop app", Computers) | `Onboarding.swift:1-80` | Router row: C-gate |
| W5 | Settings sections: Tools, GitHub, Notifications, Shortcuts, Updates, General, **Claude** (Router style, Muted folders, Jev inbox, Session icons), TypeSafe key, Delivery through claude.ai, Computer defaults, Connected Macs | `SettingsView.swift:149-395,545-620`; `RouterCourierSetup.swift:189` | Mixed |
| W6 | Updater: checks GitHub Releases, SHA-256 and same signing cert, swap and relaunch; Settings → Updates; "Restart to update" | `Updater.swift:1-20`; `SettingsView.swift:269-300` | **Indep** |
| W7 | General: check interval, Launch at login, center the bar on its edge, Quit | `SettingsView.swift:331-362` | **Indep** |
| W8 | Accessibility: Reduce Motion, Increase Contrast, Differentiate Without Color variants; Announce (VoiceOver) | `AppSidebar.swift:91`; `Playground.swift` shots | **Indep** |

## 2. Demo scenarios and shot catalog (the test-by-eye layer)

- `--demo [scenario]`: `busy botsOnly allClear snoozed error empty agents signedOut inboxFailed rateLimited contributionsEmpty botChatterEmpty doneEmpty firstSync syncFault inboxMany hiddenCategory jev sections noCI allPassing manyCI ciRunning updateAvailable updateDownloading updateReady router routerOff` (DEVELOPMENT.md Demo data). Claude-bound ones: `agents`, `router`, `routerOff`, `jev`.
- Demo data built from Claude types: `Demo.swift:165-210` (`claudeProjects`: fake claude.ai projects/threads "as the engine's Board would share them"); `:545-620` (`ClaudeSession`, `ClaudeActivity`, `ClaudeTask` fixtures); `DemoBriefs.swift` (5 projects: fjord, lcu (local), silo, docs-site, router-evals; thread statuses needsYou/working/done/paused; entries of kinds plan/question with `card:` ids "row_plan_1", `source: .cloud/.local`; `watch = "live"|"stale:<t>"`; `BriefDoc`, `BriefThread`, `BriefEntry`, `SentLine`, `GeneralBrief`, `BriefVersion`).
- **Rebuild implication**: shape of `BriefDoc/BriefEntry/BriefThread` is the app's own model; the shots can stay if the adapter feeds the same types.
- Window shots (`AppWindowShots.swift:116-310+`). Claude-bound: `router`, `router-composing`, `router-collapsed`, `router-760`, `router-courier-*`, `router-proposal-*`, `brief-home|needs-you|stale|quiet|drawer|drawer-narrow|hover|hover-plan|hover-question|hover-form|hover-finished|hover-stranded|mentions` (+ `-dark`), `courier-setup-missing|partway|done`, `palette-router`, `settings` (has Claude section). Independent: `category`, `reviews`, `ci`, `done`, `computers*`, `computer-*`, `categories*`, `snippets`, `palette*`, `settings-computers`.
- Playground shots (bar): every edge and demo scenario (`right-open`, `top-rest-signed-out`…); DEVELOPMENT.md Window/bar.

## 3. Claude-specific UI and plumbing

| Item | What it does | Cite |
|---|---|---|
| `ClaudeMark.swift` | Reads Claude's spark from **the user's installed Claude app**: PNG inside `Claude.app/Contents/Resources/app.asar` (`.vite/renderer/about_window/assets/icon-*.png`), falls back to the app's tray icon, else an asterisk. Used as the "Open in Claude" icon (`openSymbol = "fjord.open-in-claude"`). Also `clay` = #D97757. | `ClaudeMark.swift:5-9,45-60,66-68` |
| `Fonts.swift` (`ClaudeFonts`) | Loads **Anthropic Sans** from `/Applications/Claude.app/Contents/Resources/app.asar`; registered for this process only. Fjord's own look uses Geist (shipped), `ClaudeFonts` only when `FJORD_THEME=claude` (`Brand.swift:164`) | `Fonts.swift:5-14`; `Brand.swift:164`; `main.swift:13` |
| `ClaudeDesign.swift` (`CDS`) | The Claude desktop app's design system tokens (surfaces, text, borders, density, tiles, sidebar, settings metrics). Used by **every** view; "values traced to docs/design/spec/" | `ClaudeDesign.swift:1-40` |
| `Brand.swift` | Fjord's brand over CDS. `FJORD_THEME=dark|light|claude`; `.claude` draws CDS's own values | `Brand.swift:8-30` |
| `Theme.swift` | `Theme.claude` = clay #D97757 "for anything about Claude sessions", used for working text/minutes and the pending dot; project colour palette "for Claude sessions" | `Theme.swift:5,24-26`; `RouterView.swift:626-628`; `HubComponents.swift:288` |
| `Components.swift` | Claude-styled primitives (row highlight, Eyebrow, Badge, tooltip) with Anthropic Sans type scale; no data dependency | `Components.swift:7-96` |
| `ClaudeControls.swift` | `CDSTextArea`, `ClaudeButton` (variants primary/secondary/ghost, icon, shortcut keycaps) | `ClaudeControls.swift:1-14`; used at `RouterBriefView.swift:612,683,688` |
| `SessionGlyph.swift` / `SessionIcons.swift` | Session tile glyph + status dot; icon catalogue of SF Symbols in categories (`about:` text is read by Jev) | `SessionGlyph.swift:1-60`; `SessionIcons.swift:1-25` |
| `AppWindow.swift` / `WindowChrome.swift` | The window "as Claude's Code tab lays them out" (sidebar + page). A `checksClaudeCode` flag makes the Router page check for Claude Code when shown. Wiring only. | `AppWindow.swift:191,222-225,1194`; `WindowChrome.swift:94`; `RouterCode.swift:10,27` |
| `System.swift` | AppDelegate: launches. `--claude` → `ClaudeCheck.run()`; starts the **claude.ai delivery engine (`CourierHost`) at launch, never in demo**; terminates `claude` child processes on quit; `--window`, `--playground`, `--demo`, `--update`, `--check*` | `System.swift:575-621,818,851` |
| `main.swift` | `--form-hook` → `FormHook.main()` (Claude Code runs the binary as hook); `--native-host` → `NativeHost.main()` (Chrome native messaging); `--courier-test` → `CourierTestMode.main()` (conformance bridge). Then loads `ClaudeFonts` and `Brand` fonts, forces `AppleFontSmoothing=0` "as Claude's web view draws it". | `main.swift:1-24` |
| `AppIdentity.swift` | Support folder `Fjord` vs `Fjord Dev`; Silo socket path; LaunchAgent plist names. **No Claude dependency** (env `FJORD_SUPPORT_FOLDER`, `FJORD_E2E`, `FJORD_SILO_SOCKET_PATH`) | `AppIdentity.swift:1-51` |
| Store Claude watchers | `FolderWatcher` on `Claude.sessionsDir`, `localStorageDir`, `transcriptsDir`; observes app launch/terminate/activate of the Claude app, screen sleep/wake | `Store.swift:672-723` |
| `ClaudeLinkStatus` / `HubView.ClaudeNotice` | See R24 | `ClaudeLinkStatus.swift`; `HubView.swift:504` |
| `ClaudeProcesses.swift` | Process table lookups for the permission check | `ClaudeProcesses.swift:1-14` |
| `ClaudeChooser.swift` | Typealias for Jev's pick (`Claude.Chooser`), tests stub it | `ClaudeChooser.swift:1-5` |
| `ClaudePlugin.swift` | The signed `fjord@fjord` Claude Code plugin writer/installer (covered by other agents) | Settings text `SettingsView.swift:419-433` |

**Rate-limit / usage displays**: only `RateLimitWarning.swift` (GitHub, <500 calls left; `store.rateRemaining`). A demo scenario `rateLimited` exists for it (DEVELOPMENT.md). **No Claude subscription/usage/context display exists**; the only Claude-cost surface is the Settings copy "Two small requests, about $0.0002 a session" for Jev icons (`SettingsView.swift:480`, TypeSafe, not Claude).

**Settings → "Claude" section** (`SettingsView.swift:386-395`): Router style, Muted folders, "Let Jev label new comments" (Triage only), Icons picked for you. The Router toggle sits under Tools (`:149-165`, `:399-415`). There is **no SSH section for Claude** in Settings; Desktop-SSH writes are internal (`ClaudeSSHSettings.swift`).

## 4. README / DEVELOPMENT claims tied to Claude (must be rewritten for a T3 version)

| Claim | Cite |
|---|---|
| "joins GitHub, CI and your Claude Code sessions" | README.md "Keep the apps you use" |
| "one chat above all your Claude Code sessions … local and on claude.ai" | README "Router:" |
| Install table: Router needs the Claude desktop app and follows Code-tab sessions, not terminal `claude` | README Install |
| Switching Router on adds `~/.claude/hooks/fjord-form.sh` + the `fjord@fjord` plugin, backs up `~/.claude/settings.json`; off removes both | README Install; DEVELOPMENT "What the Router reads and writes" |
| "The Router reads Claude's local session files, which aren't a public API" | README Install; DEVELOPMENT |
| Privacy: "briefs, summaries and replies are written by Claude Haiku through your own Claude Code, on your account"; TypeSafe optional | README Privacy |
| Delivery: "Every message … goes to a claude.ai project or thread through the delivery engine (`CourierHost`)"; project decider: Jev first at 0.7, else Sonnet through `claude -p` | DEVELOPMENT "The Router's routing" |
| `--claude [--watch]` prints what the Router reads of Claude | DEVELOPMENT Live data; `Demo.swift:660-730` |
| `--form-hook` is what Claude Code runs on question / plan / permission prompt | DEVELOPMENT Tooling-only flags |
| "Triage: hand the item to a Claude Code session in your clone of the repo" | README Triage |
| Reads `~/.claude/projects` and Claude Code's task list in `/private/tmp/claude-<uid>` | DEVELOPMENT "What the Router reads and writes" |
| Independent of Claude: Triage, GitHub auth, Updates, Computers/Silo, Keyboard (except Router rows), Privacy GitHub + TypeSafe bullets | README |

## 5. Tests (`Tests/FjordTests`, ~140 files; `Fixtures/` holds only `SiloAPI`)

No test reads real transcripts or the real `~/.claude`; every Claude-shaped fixture is inline JSON or a temp dir written in the test. Counts of strings via grep for claude/jsonl/local_/asar; this is not a full read.

| Test file | Claude format it pins | Fixture data |
|---|---|---|
| `AgentsTests.swift` (793 lines) | Claude Desktop session JSON `local_*.json` (`sessionId`, `title`, `cwd`, `gitAnchorsFolderRealpath`, `latestUserFrameAt` ms) and transcript `.jsonl` lines (`type: assistant`, `tool_use`, timestamps) | Inline dicts `AgentsTests.swift:378-409` |
| `FormHookTests.swift`, `FormsTests.swift`, `InstallerTests.swift` | Claude Code hook protocol: `AskUserQuestion`/`ExitPlanMode`/permission tool_use lines in transcripts, `settings.json` hook entry (`matcher`, `hooks[].command`, `timeout: 86400`) | Inline JSON, temp `settings.json` (`InstallerTests.swift:10-25`) |
| `PermissionWaitTests.swift`, `PermissionProcessTests.swift`, `PrivateFolderTests.swift` | Transcript tool_use/tool_result, `is_error`, `~/.claude/sessions/<pid>.json` (`pid`, `sessionId`, `startedAt`), `permissions/<sid>-…json` | Temp dirs (`PermissionProcessTests.swift:95-111`) |
| `ClaudePluginTests.swift` (809), `DevPluginNamesTests.swift` | Plugin file layout (`.claude-plugin/plugin.json`, `marketplace.json`, `hooks/hooks.json`, `config.json` with `sessionsDir/presenceDir/keyPath`), `plugin-<cli>.json` registry | `PluginFixture` `ClaudePluginTests.swift:84-110` |
| `ClaudeSSHSettingsTests.swift` | `~/.claude/settings.json` serialized writes, symlinked dotfile | Temp home (`:7-73`) |
| `GuestRouterTests.swift` (1183), `GuestClientTests.swift`, `RunsOnRemoteTests.swift`, `TriageGuestSessionTests.swift`, `OwnGuestRuntime.swift`, `FakeSiloUnixServer.swift` | Installing plugin/hook into a guest `.claude` over the Silo API; Desktop session start in a guest | In-memory file maps, fake Silo server (`GuestRouterTests.swift:151-181,317`) |
| `RouterStreamTests.swift`, `RouterRunStreamTests.swift` | `claude -p --output-format stream-json --verbose --include-partial-messages` line schema (`system/init`, `stream_event`, `content_block_*`) | Inline lines (`RouterStreamTests.swift:58-77`; `RouterRunStreamTests.swift:6-18`) |
| `RouterMCPTests.swift` (803) | Fjord's MCP server exposed to `claude -p` (`type: http`, `/mcp`, tools with `inputSchema`) | Fake sessions `local_a`, `local_b` (`:63,88,145`) |
| `RouterDispatcherTests`, `RouterProjectDecideTests`, `RouterProjectProposalTests`, `RouterDecisionsTests`, `RouterCarryTests`, `RouterCancelTests`, `RouterPrepareTests`, `RouterToldTests`, `RouterFjordTests`, `RouterStoreTests`, `RouterBriefWiringTests`, `RouterBriefEngineTests`, `RouterBriefDocTests`, `RouterBriefMarkupTests`, `RouterBriefReviewTests` | Router logic over `ClaudeSession`/`BriefDoc` types and Sonnet/Haiku `claude -p` stubs | Inline model values |
| `CourierFramesTests` (631), `CourierSlice1-4Tests`, `RouterCourier*Tests`, `CourierHostTests`, `NativeHostTests` | Extension ↔ page ↔ engine frames (`type: page/projects/rows/composer`, ids `chan_*`, `cmsg_*`, `from: you|claude`); claude.ai page model | Inline JSON frames (`CourierFramesTests.swift:37-40`) |
| `InboxActionsTests` | Triage action ledger with session ids and `claudeSessions` titles | Inline |
| `JevTests`, `JevGateTests` | TypeSafe response format, not Claude | Stubbed `URLProtocol` |
| `PaletteRouterSourceTests`, `PaletteModelTests`, `PaletteTriageSourceTests`, `PalettePlacesSourceTests`, `RouterUITests`, `RouterMentionFieldTests` | Palette/Router rows over `Demo` data | `Demo.populate` |
| `BrandTests`, `AppWindowTests`, `AccessibilityTreeTests`, `WindowChromeTests`, `ShortcutTests`, `ShotCatalogTests`, `MotionGateTests`, `CategorySectionsTests` | Mention Claude only as design tokens or the Router destination | Demo / inline |
| Independent of Claude (examples) | `GitHubClientTests`, `GitHubStub`, `InboxEngineTests`, `InboxSyncTests`, `UpdaterTests`, `UndoTests`, `Snippets/Snooze/TimeTexts`, `LevelDBTests`, `KeychainAccessTests`, `Computers*`, `SiloAPIClientTests`, `AppIdentityTests`, `AppNavigationTests`, `CITests` | Stubs, `Fixtures/SiloAPI` |

CI/test runner: `scripts/test.sh` writes `test.log` and passes only on the summary line (DEVELOPMENT.md Tests). Test targets that would break outright if `Claude.swift`, `ClaudePlugin`, `Forms`, `RouterStream` and the Courier types go away: roughly 55 files listed by `grep -l -i claude` (list in my scratch run; includes everything above).

## 6. Scripts and evals

| Item | Claude dependence | Cite |
|---|---|---|
| `scripts/build-app.sh`, `build-silod.sh`, `generate-engine-client.sh`, `make-signing-cert.sh`, `make-icon.swift`, `silod.release`, `morph-timings.sh`, `motion-trace.sh` | **Indep** (Silo, signing, icon) | DEVELOPMENT Tooling scripts |
| `scripts/idle-cpu.sh` | Comments only: the demo "does not poll or watch Claude's files" | `idle-cpu.sh:5,34` |
| `scripts/test.sh` | **Indep** | |
| `scripts/migrate-to-fjord.sh` | **Heavily Claude**: moves `~/.claude/hooks/lookout-form.sh` → `fjord-form.sh`, edits `~/.claude/settings.json`, finds the bundled Claude Code binary (`Application Support/Claude/claude-code/<version>/*/claude.app/Contents/MacOS/claude`), runs `claude plugin list/uninstall/marketplace remove --json` for `lookout@lookout` and `fjord@fjord`. A one-off for the owner's machine. | `migrate-to-fjord.sh:25,197-199,277-375` |
| `evals/router/` | Measures routing of a typed message to a session using **TypeSafe Jev** (`jev.py`; key from the Keychain item; answers cached in `cache/`). Cases: `cases/` (210 written), `heldout/` (150), `style` (332 written). **`real/extract.py` rebuilds 611 "moments" from your own Claude Code transcripts under `/Users/polarzero/.claude/projects`** (`real/extract.py:10`), redacts keys and tokens, stores in gitignored `real/data/`. `real/` also has `boards.py` (the board as Fjord would have shown it), `entities.py`, `pii_scan.py`. `explore/` has per-explorer modules (fuse2, question gate, recency model, capabilities). No `claude -p` call found in the `.py` files I grepped (INFERRED: Claude is the data source, Jev is the model). `v2/` has asks/skipped/triage evals (`asks_eval`, `skipped_eval`, `triage_eval`, `multi`). The Swift side (`RouteFusion`) is tested for parity (`RouterFusionParityTests`, named in `README.md` evals). Docs: `evals/router/README.md`, `BENCHMARK.md`, `CASES.md`, `EXPLORE.md`; background in `docs/design/router-research.md`. | `evals/router/README.md`; `real/extract.py:10,77` |
| `docs/design/` | Router design docs: `claude-channel.md`, `router-watch-and-briefs.md`, `router-data-design.md`, `router-redesign.md`, `session-wake.md`, `projects-internals.md`, `spec/` (CDS spec read from Claude's shipped code), plus `fjord/`, `island/`, `palette/`, `router-brief/`, `router-flight/`, `router-split-panel/`, `router-viz/`. Untracked: `bar-mark/`, `router-viz/` (git status). | `docs/design` listing |
| `poc/router/` | Prototype of the claude.ai page/courier (Python `page.py`, `extension/`); `CourierPage.swift` "ports poc/router/page.py" | `CourierPage.swift:2`; `RouterCourierSetup.swift` `extensionFolder` doc |
| `schemas/silo-api/` | Silo schema (Indep) | DEVELOPMENT |

## 7. Not read in depth (gaps)

`Claude.swift` and `RouterStatus` (other agents), `Forms.swift`, `Hub*` internals beyond the Router cells, `ComputersView` panels beyond Agent tools, `CourierBoard/CourierCore*`, `CategoriesView`, `Snippets.swift`, `RouterCode.swift` layout, `Playground.swift`, the exact `agents` demo scenario body, `AppContent.swift` and `ComputerViewer.swift`.

## 8. Rebuild-on-T3 takeaways (INFERRED)

1. The cleanly Claude-free layer is Triage + Computers + window/bar/palette shell + updater + shortcuts. Its only Claude seams are the Router sidebar/bar cells, the `.router`/`.openInRouter` shortcuts, the "Send to the Router" action, and palette session rows.
2. The Router's UI vocabulary (BriefDoc/BriefEntry/BriefThread/BriefTarget, `AgentRow`, `ClaudeSession`, `ClaudeActivity`, `ClaudeTask`, `PendingForm`) is the model a T3 adapter would have to fill. Demo, shots and palette tests already run on those types, so they keep working if the adapter produces them.
3. Visual dependence on the installed Claude app: Anthropic Sans and the spark come out of `/Applications/Claude.app/.../app.asar`; with T3 and no Claude app, `ClaudeFonts` fails and the spark falls back to an asterisk (`ClaudeMark.swift:5-9`), while Fjord's own theme uses Geist (shipped, `Brand.swift:1-8`). `ClaudeMark.openSymbol` and the "Open in Claude" labels need a provider-neutral rename.
4. Onboarding and Settings gate the Router on `Claude.isInstalled`. That gate and its copy ("Needs the Claude desktop app", `Onboarding.swift:52`, `SettingsView.swift:399`) must become "T3 server reachable".
5. Delivery paths named in the UI: claude.ai courier (Chrome extension), local plugin relay, form hook, Desktop SSH, guest Claude Code install. Each has settings rows, tests and README text to retire or replace.
