# Router v2: implementation plan (2026-11-12)

The plan to build the approved page ([DESIGN.md](DESIGN.md), demo in commit `36f90b83`) on the owner's T3 data and
**replace** the Router brief page. Owner: "You can build this entirely. Parallelize work as much as possible. Make sure
everything is extra optimized, ultra snappy and responsive."

Read first: [CONTEXT.md](CONTEXT.md), [DESIGN.md](DESIGN.md), [FEASIBILITY.md](FEASIBILITY.md),
`docs/performance.md`, `docs/design/t3-code-map.md` §12. Paths: `SF/` = `Sources/Fjord/`, `TF/` = `Tests/FjordTests/`.

Contents: 0 rules · 1 architecture · 2 performance · 3 tracks and waves · 4 risks and open questions.

## 0. Rules for everyone who builds this

- **A replacement.** When v2 is wired, the brief page, its engine, its store, its composer strip and its tests are
  deleted in the same wave. No flag, no setting, no fallback, no migration of `briefs.db` (it is just no longer opened).
- **The demo stays.** `--window --router-v2-demo`, the storyboard and the `v2-` shots keep working, on a demo store
  behind the same two interfaces as the real one (1.2). A track that changes a component checks its `v2-` shots.
- **Wave 1 adds, wave 2 rewires, wave 3 deletes.** Until wave 2's switch the brief page still works and its tests
  pass: a wave-1 change to a file the old page uses is additive (a new parameter with the old default, a new callback,
  a new optional field). The suite is green at the end of every wave, so `main` can be built and installed at each.
- **One shared checkout, on `main`** (the repo's rule: no branches, no worktrees). So:
  - A track edits only the files it owns (section 3). A shared file has one owner per wave; anyone else asks for the
    change through the seam named there.
  - New code goes in new files that compile against the seam alone. Never leave the tree unbuildable: write, `swift
    build`, then commit that piece. Commit your own hunks only (`git add -p` by path, never `git add -A`).
  - **Tests run one at a time, for the whole team.** Take the lock before any `swift test`:
    `mkdir .build/router-v2-test.lock` (wait while it exists), run one `swift test --filter <Suite>`, `rmdir` it. The
    full `scripts/test.sh` runs only at the end of a wave, by the orchestrator.
- **Commits:** one per verified piece, `feat:` / `fix:` / `refactor:` / `perf:` / `test:` / `docs:` + a plain sentence
  about the result, no scope. A `perf:` commit has its numbers in the message (`docs/performance.md` rule 9).
- **No word lists or regex to read a message**, no fixed waits, no polling, no letter shortcuts (AZERTY).
- **Never offscreen-check by launching the app.** `swift build`, then `.build/debug/Fjord --window-shots .build/shots v2`.

## 1. Architecture

### 1.1 Shape

```
T3Client (actor: socket, JSON decode, off main)
  └─ T3Store.onShell(item) / onThread(id) / onConnection(state)            SF/T3Store.swift:137-143
       ├─ RouterRecords.shell(item) · detail(id) · connection(state)       NEW, called first, O(1) per row
       │     code state (pure) ⊕ cached verdict ⊕ pending acts  →  one RouterV2Thread per thread
       │     └─ diff against what was last shown → RouterV2Change → RouterV2Model.apply(_:)   (one record)
       └─ Store.shellChanged(item)                                          existing: threads, decider reads, cards, icons

RouterV2Model (the approved page model: selection, filters, draft, picks, toasts; SF/RouterV2Model.swift)
  └─ acts → RouterV2Source                                                  demo: RouterV2DemoSource · real: RouterActs
       ├─ RouterActs      send, steer, queue, answer, Continue, Stop, visit, Settle, Snooze, Not for me, Revert
       ├─ RouterV2Reader  where a draft goes: Jev fast path, then Sonnet with the launch fields
       └─ RouterVerdicts  one streamed Haiku call per thread per fingerprint
```

New files (all under `SF/`): `RouterV2Port.swift` (the seam), `RouterRecords.swift`, `RouterCodeState.swift`,
`RouterDetail.swift`, `RouterPullRequests.swift`, `RouterNotifier.swift`, `ClaudeStream.swift`, `RouterVerdicts.swift`,
`RouterVerdictPrompt.swift`, `ProjectPurposes.swift`, `RouterV2Reader.swift`, `RouterLaunchCatalog.swift`,
`RouterActs.swift`, `ThreadAnswers.swift`, `RouterV2Screen.swift`, `RouterV2Model+Draft.swift`,
`RouterV2Model+Acts.swift`.

### 1.2 The seam: how the demo's model and components move to real data

Today `RouterV2Model` owns `threads: [RouterV2Thread]`, its "T3 events" methods (`turnEnded`, `asked`, `runStarted`,
`verdict`, `line`, `failed`, `pr`, `left`, `appeared`…, `SF/RouterV2Model.swift:1213-1474`) mutate them, and
`RouterV2Source` (`:10-22`) takes the acts. The components read the model only. The switch changes two things and
leaves every component and every owner act as approved:

1. **Events become whole records.** One entry point, `RouterV2Model.apply(_ change: RouterV2Change)`. The store
   (real or demo) says what a thread *is*; the model works out the motion (principle 1: the page is a pure function of
   one record per thread). The old event methods move, unchanged in name and signature, into an extension in
   `RouterV2Demo.swift` where each builds the next record and calls `apply`, so the script and the shots don't change.
2. **Acts all reach the source.** `RouterV2Source` grows the acts the demo did locally (settle, snooze, not for me,
   their reverts, settle all, cancel a queued message, structured answers, a thread id for a new thread).

The owner's acts keep mutating the model's own copy at once (the tuned choreography in `dispatch`, `remove`,
`notForMe`, `deliver` stays). The store mirrors each act as a **pending act** on that thread, so the next record it
composes already agrees and `apply` finds nothing to change. `apply` is idempotent: a record equal to the one held is
a no-op.

Contract (`SF/RouterV2Port.swift`, written by track 1; signatures are the spec, bodies are the tracks'):

```swift
enum RouterV2Change {
    case upsert(RouterV2Thread)                  // the whole record: code state ⊕ verdict ⊕ pending act
    case remove(String)                          // settled, snoozed, archived, aged out
    case older([RouterV2Older])                  // the housekeeping line's threads, whole
    case reply(String, text: String, writing: Bool)          // the card's last lines, growing (hot path)
    case words(String, stream: Int, text: String, done: Bool)// a verdict's line as it streams (hot path)
    case named(String, String)                   // the short name, once
    case read(RouterV2Read)                      // a draft's destination landed
    case refused(String, reason: String, offline: Bool)      // a send didn't go
    case connection(lost: Bool)
    case launch(defaults: RouterV2Launch, models: [RouterV2LaunchModel])
    case batch([RouterV2Change])                 // first load, or what a held window morph kept: one unanimated update
}

struct RouterV2Outgoing {                        // what Return sends
    enum Kind { case words, answer(picks: [Int: Int], typed: [Int: String]), continuing }
    var thread: String, words: String, kind: Kind, steering: Bool, queue: Bool
    var read: RouterV2Read?                      // the read the row showed, for the decision log
}

@MainActor protocol RouterV2Source: AnyObject {
    func read(_ draft: String, selected: String?, mentions: [RouterMention])   // answers with .read
    func send(_ out: RouterV2Outgoing)
    func cancelQueued(_ thread: String)
    func mintThread() -> String                  // the id a new thread will have (T3's own: a lowercase UUID)
    func start(_ thread: String, words: String, project: String, launch: RouterV2Launch, read: RouterV2Read?)
    func stop(_ thread: String)
    func visit(_ thread: String)
    func open(_ thread: String)
    func settle(_ threads: [String], on: Bool)   // on: false is the Revert; several: Settle all
    func snooze(_ thread: String, until: Date?)  // nil: unsnooze (the Revert)
    func notForMe(_ thread: String, on: Bool)
}
```

Rules of `apply` (track 1 writes them once, tested):

- `.upsert` of an unknown id: the line grows in (`Motion.spatial`). Of a known id whose section or order class changed
  (ask / stopped / sent / running / look / quiet): `move(id)` on `RouterV2.lineMove`; if it was selected and T3 moved it,
  the selection goes to its neighbour (DESIGN 2.1). Otherwise the fields change on `Motion.fade`.
- The model keeps what is its own across an upsert: `order` (a fresh one only when the state's case changes), the
  sentence's `stream` counter (never goes back), picks, typed answers, the open long text.
- `.reply` and `.words` touch one field of one line and animate nothing themselves (the views do).
- `.batch` and anything applied while `WindowArrival.appWindow.active`: no animation.
- T3 never opens a card and never moves the selection except to follow a line out of its section.

### 1.3 The record store (`RouterRecords`)

`@MainActor final class`, not observed by views. It holds, per thread id:

| Part | Source | Kept where |
|---|---|---|
| **Code state** | `RouterCodeState.make(thread: AgentThread, detail: RouterDetail?, now:)`, pure | memory |
| **Verdict** | `RouterVerdicts`, keyed by the thread's fingerprint | `Application Support/Fjord/router-verdicts.json` |
| **Name** | the verdict's `name`, once; again only when T3's title changes | same file |
| **Pending act** | this app's own act not yet confirmed by T3: `sent`, `hidden` (settle, snooze), `seen` | memory |
| **Not for me** | a mark on the verdict, with its fingerprint | same file |
| **Shown** | the last `RouterV2Thread` handed to the model, for the diff | memory |

**Scope** (the brief rebuild's rule, `SF/AgentThread.swift:76`, `SF/T3BriefSource.swift:47`): a thread has a line when
`inPlay(now)` and it is working, waiting on you, stopped, or finished under 24 h ago. Finished 24 h to 7 days ago and
not settled: one of the housekeeping line's (`RouterV2Older`, named by T3's title). Older, or never run: nothing. The
two clock boundaries (24 h, a snooze's end) are one one-shot timer for the next of them, as
`scheduleRecentExpiry` does (`SF/Threads.swift:266`); nothing ticks.

**Code state**, first match wins (DESIGN 2.1, FEASIBILITY gap 2):

| Shell says | State | Code line | `since` |
|---|---|---|---|
| a blocking `pendingRuntimeRequest`, or a held request | `needsYou(.question / .form / .permission)` (form: more than one question) | the question verbatim; "N questions: " + the first; the command in mono | the request's `createdAt` |
| `hasActionableProposedPlan` | `needsYou(.plan)` | "plan ready: " + the plan's first line | the plan's time |
| `running` (turn live, background work, or waits on another thread) | `working` | 1.7 | `activityRunStartedAt` |
| failed on a usage limit that resumes itself | `working`, paused | "paused at the usage limit, resumes HH:mm" | unchanged |
| failed on a usage limit that doesn't | `stopped` | "hit the usage limit" | run end |
| `failed`, or `interrupted` without `latestRunStopRequested` | `stopped` | "failed: " + `lastError`'s first line, or "interrupted" | run end |
| `interrupted` with `latestRunStopRequested` | `done`, quiet, no verdict | "stopped by you" | run end |
| any other finished run | `done` | "finished", then the verdict | `latestRunCompletedAt` |

Until a waiting thread's projection arrives the kind comes from the shell's `pendingRuntimeRequest.kind` and the card
shows its skeleton (`loading`). A request T3 can no longer answer (`ThreadRequest.live == false`, after a T3 restart)
has no options: the card shows Open in T3 (DESIGN 1.5).

**Fingerprint** (the verdict's cache key; from the shell row alone): `latestRunId`, `pendingRuntimeRequest.id`,
`hasActionableProposedPlan`, every PR's `url:state` sorted, `latestUserAuthoredMessageAt`. The name has its own key:
T3's title.

**Compose** (pure, tested): hidden → no line. A pending send → `sent` with its words and status (and the launch
settings for a thread started here). Else the code state, with the verdict when its fingerprint is the current one:
an ask keeps its state and takes the verdict's line; a finished turn takes `needs_you` (→ `needsYou(.step)` with the
ask, the options and the kept result line, unless marked not for me: then `done`, worth a look, the result line) or
`done` with `look` / `quiet`. No current verdict: the code line, `reassessing` while a call is queued or running,
`settled` when none will come (the call failed, Claude Code is missing).

**Pending acts end on T3's word, never on a timer:** a send's when the shell shows the run it started
(`activityRunStartedAt` at or after the send, another `latestRunId`, or the request's id gone), a steer's when the
thread's projection shows the message in a run (`Store.delivery`, `SF/ThreadSender.swift:155`); a settle's or
snooze's when the row says so or leaves; `seen` when `lastVisitedAt` moves. A refusal ends it at once and emits
`.refused`.

**The new dot:** `isUnseen` (`SF/T3Types.swift:354`), or a pending request made after `lastVisitedAt`. Opening a card
sends `thread.visit` (1.6).

**Order** is the model's (`ordered(_:)`, `SF/RouterV2Model.swift:253`) on the record's `since`; the store only keeps
`since` honest.

**While the window's morph plays** (`MotionGate`), shell and thread events are folded into the store's state as they
come and the changes are kept; released as one `.batch` when still (the existing `shellHeld` pattern,
`SF/Threads.swift:408-421`). With the window closed the store keeps running (badge, bar, banners) and the model takes
changes unanimated.

### 1.4 The verdict engine (`RouterVerdicts`)

- **When:** the store asks when a thread's fingerprint moves and its code state is `done` (not "stopped by you") or a
  `needsYou` ask; and once for a thread with no name yet (a name-only call). Nothing for Working, Stopped, Sent.
- **Call:** `claude -p --model claude-haiku-5-5 --output-format stream-json --verbose --include-partial-messages
  --json-schema …` with `ClaudePrint`'s other flags (`SF/ClaudePrint.swift:38-44`), the binary from `RouterStatus`. The
  process starts in the same turn as the event. No warm spare (FEASIBILITY: 0.3 s gained).
- **Schema, in this order** (the state lands first, the line can stream): `state` (`needs_you` | `done`), `worth`
  (`look` | `quiet`), `name` (28 characters at most), `line`, `ask`, `options`, `result`. For an ask the engine reads
  only `name` and `line`.
- **Input** (about 1,600 tokens, redacted and fenced as the brief's is, `RouterTools.redacted`, `SessionFence`): T3's
  title, the project, your last words there, the agent's last reply (its last 4,000 characters), the request's words
  and options, PRs with their states, the files changed. Rule from FEASIBILITY gap 2: a turn that ended on an error it
  couldn't fix is `needs_you`.
- **Streaming:** `ClaudeStream` runs the process and yields its stdout lines as they come (the line reader of
  `RouterRunStream`, `SF/RouterRun.swift:230`, is the model); `PartialJSON` reads the growing `StructuredOutput`
  input and gives each field as it closes and `line` as it grows, cut at the last whole word. The engine emits `state`
  (the store recomposes: the line may move, still sheening), then `.words` as the line grows, then the whole verdict.
- **Cancel:** a run starting, another fingerprint, the thread leaving: the task is cancelled, the process terminated
  (`OneShot`'s cancel handler, `SF/RouterPrepare.swift:92`), nothing is written. A late answer is checked against the
  fingerprint again before it is kept.
- **Cap:** 4 calls at once. The queue is by need: asks, then finished newest first, then names. A queued line sheens.
- **Failure:** the line settles on the code's words. The next fingerprint asks again. No retry loop.
- **Usage:** each call's tokens and cost go to `ModelUsageLog` under a new role, `verdict`.
- **`ProjectPurposes`** (same engine, same cap): the decider's block B needs each project's purpose, which the brief's
  project call wrote until now (`SF/DeciderBoardSource.swift:108`). One small Haiku call per project when the set of
  its threads' first asks changes, kept in `project-purposes.json`.

### 1.5 Where a draft goes (`RouterV2Reader`)

The model shows what code knows in the frame of the keystroke (the selection as the prior, or the mark and the
skeleton; a new thread's default chips). The reader only ever sends `.read(RouterV2Read)`.

1. **No model:** a `@thread` pill is an explicit place (the model's `explicit`); nothing is read.
2. **Jev** (`Store.readDraft`, `JevPath`): at the typing pause; sure (P ≥ 0.90, an idle thread) → `sure`, one place.
3. **Sonnet** (`Store.decideDestination`, `ClaudePrint`, structured output) when Jev isn't sure. Its schema
   (`DeciderContext.schema`) is N4b's alone: it reads no settings (they are `@` pills, `RouterSetting.swift`; owner, 2026-11-12). The decider never writes the message.
4. **The selection as a prior:** one line in Sonnet's Now block ("the owner has this thread's card open"). Jev's
   request is not changed (his weights are fitted).
5. A read is cancelled by the next keystroke and reused for the same words on the same board
   (`Store.deciderBoardKey`). A Return before it lands starts it without the pause; the model's held Return does the
   rest (`readLanded`, `SF/RouterV2Model.swift:648`).

`RouterLaunchCatalog` reads `server.getConfig` once connected and on each reconnect: the models (slug, name,
provider instance, aliases, each one's effort list and default), the runtime modes the provider supports, the
defaults (`ThreadLauncher.model`, `SF/ThreadLauncher.swift:53`); it emits `.launch`. `RouterV2Launch.Effort` and
`.Access` become string-backed so T3's lists are the lists.

The decision log keeps working: the send carries the read as `RouterContext.decided`, the owner's pick as
`target`, and what the row showed as `preview`.

### 1.6 Acts (`RouterActs`, the real `RouterV2Source`)

| Act | T3 | Existing code | To add |
|---|---|---|---|
| Send to an idle thread, answer in words | `message.dispatch`, `start_immediately` | `RouterDispatcher.submit` with `context.target` (`SF/RouterDispatcher.swift:190`), `Store.sendToThread` | the dispatcher reports each send per entry: taken (`{sequence}`), refused (reason, offline) |
| Steer, ⌥ queue | `deliveryIntent: steer` / `queue_after_active` | `ThreadSender.plan` (`SF/ThreadSender.swift:57`) | `steers` on the record from `Store.threadSteers` |
| Cancel a queued message | `queued-run.cancel` | `SF/ThreadSender.swift:178` | by thread: the run id from the projection's `queuedRuns` |
| Answer with picked options | `runtime-request.respond` | `Store.answerQuestion` / `answerPermission` / `implementPlan` / `sendBackPlan` (`SF/RouterView.swift:78-133`) | `ThreadAnswers`: the rules of `RouterBriefs.answerRequest` (`SF/RouterBriefs.swift:789`), moved out before that file goes |
| A step's option (the model's) | a normal message with the option's text | as a send | |
| Continue | `message.dispatch` "Continue where you left off." | | `manualContinuationOfRunId` on the command, sent after an interrupt or a usage limit |
| Stop | `run.interrupt`, `holdQueue` | `Store.stopThread` (`SF/ThreadSender.swift:226`) | |
| New thread | `orchestration.launchThread` | `Store.launchThread` (`SF/ThreadLauncher.swift:178`) | the thread id from `mintThread`, the model and its effort (`modelSelection.options: [{id: "effort", value}]`), `runtimeMode`, `interactionMode` |
| Card opened | `thread.visit` | `.threadVisit` | sent on `visit(_:)` |
| Settle, Snooze, Settle all, and Revert | `thread.settle` / `unsettle`, `snooze` / `unsnooze` | `Store.threadAct`, `replayBriefAction`, `FjordChange.briefAction` (`SF/ThreadActs.swift:83-118`) | hides through `RouterRecords`, not `RouterBriefs.holdAct`; a refusal puts the line back and the toast says why |
| Not for me | none (Fjord's own mark) | | `RouterRecords.notForMe` |
| ⌘Z | the reverse command | the model registers with the window's `UndoManager` (`SF/RouterV2Model.swift:1031`) | the undo also marks the `FjordChange` reverted (`revertFjordChange`, `SF/FjordChange.swift:370`), so History agrees |
| Open in T3 | `t3code://threads/<env>/<thread>` | `Store.openThread` | |

Return's path: the model mutates its record and calls `send` in the same turn; `RouterActs` records the pending send
and submits; nothing on that path awaits before the frame.

### 1.7 What a line and a card read (`RouterDetail`, `RouterPullRequests`)

`RouterDetail` is a value made from a thread's `T3Projection` by pure functions; the store keeps one per watched
thread (`Store.syncThreadDetail` already holds the working and the waiting ones, `SF/Threads.swift:376`).

- **Working line:** the running to-do step, else the first sentence of the agent's latest words between tools, else
  the running tool or command (`ThreadWork`, `SF/AgentThread.swift:194`), with a `mono` flag for a command. "starting"
  before any item.
- **Steps:** the to-do list's steps and their states (the list exists only with T3's to-do setting, FEASIBILITY gap 1).
- **Last lines, growing:** the last assistant message and its `streaming` flag → `.reply`. A Done thread not watched:
  one bounded read at its turn end (`Store.readEnd`, `SF/DeciderBoardSource.swift:149`), the card's skeleton meanwhile.
- **The request:** `ThreadRequest` (questions, options, decisions with warnings, the plan's markdown, `live`).
- **Queued words:** `projection.queuedRuns`. **Diff:** the turn's checkpoints summed (`files`, `additions`,
  `deletions`). **Last step** of a failed run: its last tool item, one bounded read.
- **PR state:** T3's linked PRs (`pullRequests[].snapshot.state`, pushed); a PR only named in a reply is linked with
  `thread.pull-request.link` so T3 polls it too. Where the link fails, `PullRequestStates` (GitHub) is asked on
  Triage's own sync turn and when the window opens: no timer of its own.
- **Ages:** `since`, drawn against one shared minute clock.

### 1.8 The screen

`RouterV2Screen` gains what `RouterMain` hosts today (`SF/RouterCode.swift:33`): the History drawer at the side or the
bottom with its ⌥⌘B toggle, `RouterSetupNotice`, the Router-off sentence. The composer's field becomes `MentionField`
(the @ list, pills, the IME rule), the taken words marked in its own text view. `RouterV2Keys` is the page's only key
map. The page model is made once per app run and kept across window opens.

### 1.9 What else read the brief

| Reader | Today | Becomes |
|---|---|---|
| Sidebar badge, bar cell, bar status | `routerBriefs.untoldNeedsYou` | `RouterRecords.needsYou` (a stored count) |
| Bar's Router panel | `routerBriefs.page().entries`, `BriefEntryLine` | the Needs-you records: name, sentence, age |
| Palette | `PaletteRouterSource` over `BriefPage` | over the records |
| "Fjord answers here" board, `RouterRun` | `RouterMCP.briefText` | the records as text, by section |
| Decider | brief purposes; threads the brief tags | `ProjectPurposes`; threads with a line |
| Banners | `RouterBriefs.announce`, `marks.notified` | `RouterNotifier`: on a record's code transition, keyed on the request, plan or run id |
| History's "write to this thread", bar's "open this entry" | `routerBriefs.focus` | `RouterV2Model.select(.line(id))` |
| Menu: Rewrite Briefs (⌘R) | `rewriteAll` | gone |

### 1.10 The demo store

`RouterV2DemoSource` implements the grown `RouterV2Source` (the new acts answer at once) and feeds through `apply`.
`RouterV2Demo.records` builds its page with one `.batch`. `--demo router` (the bar, the playground,
`morph-timings --scenario router`) is that page at rest; `DemoBriefs.swift` goes. A new load scenario,
`--router-v2-load`, is the same store with 60 lines and 8 of them streaming, for the gates in 2.4.

### 1.11 Deleted in wave 3

Files: `RouterBriefView`, `RouterBriefs`, `RouterBriefEngine`, `RouterBriefDoc`, `RouterBriefMarkup`, `RouterBrief`,
`T3BriefSource`, `BriefLog`, `DemoBriefs`, `RouterComposer`, `RouterPreview`, `RouterKeys`, `RouterCode`, and of
`RouterView.swift` everything but the composer's text model and the answer helpers. What v2 or kept code still uses
moves out first: `BriefTarget`, `BriefAge`, `BriefPanelPlacement`, `BriefKeys.digits`, `RouterEdges`,
`ComposerMaterial`, `MentionList`, `FieldAnchor`, `RouterSetupNotice`, `RouterPreview.Shown`. Behaviours: the project
call, the lead, `GeneralBrief`, Mark read, `told`, the after-send ask's view (`RouterAskPill`), the preview chip, the
strip, O / A / R, ⌘R, the Router style setting, the old shots (`router`, `router-composing`, `brief-*`,
`router-steer`, `router-destination-*`). Tests: the eleven `RouterBrief*Tests`, `BriefLogTests`, `BriefEvalDumpTests`,
`RouterToldTests`, and the brief parts of `RouterUITests`, `RouterStoreTests`, `SnoozeTests`, `ThreadActsTests`.

## 2. Performance

### 2.1 Budgets

| What happens | Budget | Gate |
|---|---|---|
| A T3 push reaches the page | the change is committed in the main-loop turn that takes the item: ≤ 1 frame after it; ≤ 2 ms of main-thread work per shell item | `T3 event` p95 ≤ 8 ms, max ≤ 16 ms |
| A key (typing, ↑↓, ⇧digit, Tab, Esc, ⌘⌫) | visible in the same frame; ≤ 2 ms of main-thread work | `Key` p95 ≤ 2 ms to the end of the handler, ≤ 8 ms to the commit |
| Return | the Sent line, the counts and the next card in the same frame | `Send` p95 ≤ 8 ms |
| A click, a hover | same frame; a hover redraws the two rows it leaves and enters | `Select` p95 ≤ 8 ms; render test |
| A verdict's words, a reply growing | at most one change per frame per thread; only that line's sentence (or that card's text) redraws | render test; `Flush` p95 ≤ 2 ms |
| One record changes | one record diffed, one line redrawn; the list's body not evaluated unless the order changed | render test |
| Idle, window open, nothing changing | main thread at rest, no layout passes; ≤ 0.6 % of a core with threads working | `scripts/idle-cpu.sh`, `sample <pid> 3` |
| Idle, window closed | no repeating timer, no view work on a T3 event | `sample <pid> 3` |
| Window open and close | no worse than today | `morph-timings --scenario router`: Open and Close p95 ≤ 325 ms, first flush p95 ≤ 16 ms, 0 captures |
| Verdict (the model's time, reported, not gated) | state ≈ 1.9 s, words done ≈ 2.5 s after the event | `Verdict` signposts in the installed app's log |

### 2.2 How

**Event to pixels.**
- JSON is decoded in the `T3Client` actor. `RouterRecords` is called first from `onShell`, with the item: one row
  re-reduced, one compose, one compare with what was shown, at most one `.upsert`. No sort over all threads, no board
  rebuild. `Store.applyShell`'s other work (decider reads, cards, icons, colours, `SF/Threads.swift:463-476`) is
  not on this path: it runs after the page's change.
- `RouterCodeState.make` and `compose` are pure and allocation-light: dates parsed once per row (`AgentThread.date`),
  no formatter, no regex.

**Diffing only what changed.**
- The model keeps one `@Observable` box per thread (as the bar's per-session boxes, `docs/performance.md`
  "Stored, narrow observables"). `RouterV2List` reads only the layout: a stored, `Equatable` array of row ids and
  kinds, rewritten only when a line's section or order key changes. A line's view reads its own box.
- What is per row and changes with the owner's pointer or keys (selected, hovered, pressed, moving, marked as the
  draft's destination) is a flag on the box, set on the two rows involved; no line reads `model.selection` or
  `model.hoverRow` in its body.
- Counts (sections, pills, tokens, the badge) are stored and updated with the layout, never filtered in a body.
- Only the open card has a body. A closed one costs nothing until its line is selected (it stays through its closing
  roll).

**Keys.**
- `setDraft` writes state only: no sort, no store write, no model call in the handler. The read starts in a task at
  the typing pause. `destination`, `placeholder`, `canSend` read stored fields.
- The key monitor's path (`SF/AppWindow.swift:1025`) allocates nothing per key beyond `RouterV2Key`.
- `MentionField` keeps its coordinator caches (`docs/performance.md`, "Typing").

**Streaming.**
- One coalescer for everything that arrives faster than frames (`.words`, `.reply`, bursts of shell items): changes
  are kept by thread and flushed once per main-loop turn from a run-loop observer (`beforeWaiting`), so a burst costs
  one layout. No display link, no timer: nothing runs when nothing arrives.
- The sentence's renderer fades in the words that arrived since its last update (0.12 s each batch); nothing in
  SwiftUI runs per frame.
- The sheen, the working dots, Fjord's mark and the caret stay Core Animation layers (`SF/RouterV2Effects.swift`),
  stopped when detached, hidden or under Reduce Motion.

**No polling, no fixed waits.** The only timers on the page: the toast's 8 s life (stopped under the pointer), one
one-shot for the next clock boundary (24 h, a snooze's end), the shared minute clock for ages (stopped with the
window), the typing pause before a read, and each model call's own deadline. Nothing waits for T3 by the clock: a
pending act ends on T3's event or on its error.

**MotionGate.**
- While a morph plays: records fold, nothing is applied to the model; one unanimated `.batch` when still.
- A verdict or a read that lands in a morph is kept the same way.
- Processes (`claude -p`) start off the main thread at once; their results obey the gate.
- The first update after the window's content is attached is unanimated (`WindowArrival`), every animation goes
  through `.motion(_:value:)` or `model.animate`.
- The verdict file is read off the main thread before the first frame; its writes are coalesced, off main, and
  flushed on quit (`PendingEdits`).

### 2.3 Measuring

- **Signposts** (subsystem `com.amontlabs.fjord`, category `router`; begun on the main thread, ended after the commit
  with `LatencySignposts.endAfterCommit`, `SF/Signposts.swift:42`): `T3 event`, `Key`, `Send`, `Select`, `Flush`,
  `Read` (pause to landed), `Verdict state`, `Verdict done`. A second `Key work` interval ends when the handler
  returns.
- **`scripts/morph-timings.sh --args "<flags>"`** (new option): runs the release build with those flags and prints
  every interval's count, p50, p95 and max. The gate runs are
  `--args "--window --router-v2-load --quit-after"` and `--args "--window --router-v2-demo --speed 4 --quit-after"`.
- **`scripts/idle-cpu.sh`** with the window open on `--demo router` (working lines, a sheen, the mark).
- **Render tests** (no screen): each component counts its body evaluations under `UnderTest`; a test applies one
  change and asserts which bodies ran.
- **The installed app** logs the same signposts on real data: `log show --last 1h --signpost --predicate 'subsystem ==
  "com.amontlabs.fjord" AND category == "router"'`.

### 2.4 Pass or fail (wave 3; a red line blocks the deletion)

| Gate | Run | Passes when |
|---|---|---|
| Event to pixels | load scenario, 1617 × 1188 | `T3 event` p95 ≤ 8 ms, max ≤ 16 ms |
| Keys | demo script (types 600+ characters) | `Key work` p95 ≤ 2 ms; `Key` p95 ≤ 8 ms |
| Send, select | demo script | `Send`, `Select` p95 ≤ 8 ms |
| Streaming | load scenario | `Flush` p95 ≤ 2 ms; render test: 1 line body per `.words` |
| One record | `RouterV2RenderTests` | an upsert that keeps the order runs 1 line body and 0 list bodies; a hover runs 2 |
| Idle | `scripts/idle-cpu.sh` | ≤ 0.6 % open on `router`; the closed-window limit unchanged |
| Morph | `morph-timings --scenario router --steps "open,close x10"` | Open, Close p95 ≤ 325 ms; first flush p95 ≤ 16 ms; no `Capture` inside |
| Suite | `scripts/test.sh` | all pass |

## 3. Tracks

Ten tracks in three waves after a short wave 0. Each is one agent's (Sonnet; track 1 is the hard one and suits the
`build-hard` agent). A track starts from its text here, the files it names and section 1.2.

```
wave 0   1 Seam ─┬─ 2 Wire
wave 1           ├─ 2 Detail and PRs   3 Records   4 Verdicts   5 Reader   6 Acts   7 Rendering   8 Composer and keys
wave 2   9 Integration (two file sets)      + the evals of 4 and 5 on real data
wave 3   10 Deletion, gates                 → Fable's final pass
```

End of each wave: the orchestrator runs `scripts/test.sh` once and the `v2` shots, then starts the next.

Track 1 ends with wave 0. Its files have one owner each from wave 1 on, and a track that needs a change in a file it
doesn't own asks that owner (a message with the exact lines), who commits it:

| File | Wave 0 | Wave 1 | Wave 2 |
|---|---|---|---|
| `RouterV2Port.swift` | 1 | frozen (the orchestrator, telling every track) | 9a |
| `RouterV2Model.swift`, `RouterV2.swift`, `RouterV2Demo.swift`, `RouterV2DemoScript.swift`, `RouterV2Shots.swift` | 1 | 7 | 9a |
| `RouterV2Model+Draft.swift`, `RouterV2Model+Acts.swift`, `RouterV2Launch.swift` | 1 | 8 | 9a |
| `RouterV2Page.swift`, `RouterV2Line.swift`, `RouterV2Card.swift`, `RouterV2Effects.swift`, `RouterV2Surfaces.swift` | untouched | 7 | 9a |
| `RouterV2Dock.swift`, `RouterV2Keys.swift`, `RouterMentionField.swift` | untouched | 8 | 9a |
| `ThreadLauncher.swift` | 2 | 6 | 9a |
| `ThreadActs.swift`, `ThreadSender.swift`, `RouterDispatcher.swift` | untouched | 6 | 9a |
| `T3Types.swift`, `AgentThread.swift` | 2 | 2 | 9a |
| `RouterView.swift`, `RouterComposer.swift`, `RouterPreview.swift`, `RouterBrief*.swift` | untouched | untouched | untouched (10 in wave 3) |

### Track 1 · The seam (wave 0)

- **Owns:** `RouterV2Port.swift` (new), `RouterV2Model.swift`, `RouterV2Model+Draft.swift` and
  `RouterV2Model+Acts.swift` (new, split out), `RouterV2.swift`, `RouterV2Demo.swift`, `RouterV2DemoScript.swift`,
  `RouterV2Shots.swift`, the model half of `RouterV2Launch.swift` (lines 1-310).
- **Does:**
  1. Split the model's methods by file with no change in behaviour: `+Draft` (the draft, the read, the destination,
     Return, held; today's `:599-1001`), `+Acts` (failures, acts with a Revert, Esc; `:1003-1211`). Stored properties
     stay in `RouterV2Model.swift`.
  2. Write `RouterV2Port.swift` as in 1.2, and `apply(_:)` with its rules.
  3. Move the "T3 events" methods to an extension in `RouterV2Demo.swift`, each through `apply`.
  4. Make every act reach the source: `settle`, `snooze`, `notForMe`, `settleAll` and their undos, `cancelQueued`,
     `mintThread`, `send(RouterV2Outgoing)` with the picks and typed answers, `read` with the mentions.
  5. `RouterV2Launch.Effort` and `.Access` string-backed; `RouterV2LaunchModel` gains `instance`, `efforts`,
     `defaultEffort`, `access`; `launchChoices` reads them.
- **Contract:** defines it. After this track nobody changes `RouterV2Port.swift` without telling every track.
- **Tests:** `TF/RouterV2ModelTests.swift` (new): `apply` is idempotent; an upsert that changes section moves the
  line and the selection follows; one that doesn't keeps `order`, picks and `stream`; `.batch` animates nothing; each
  act calls the source once with the right payload (a recording fake). `swift test --filter RouterV2Model`,
  `--filter ShotCatalog`.
- **Done:** the `v2` shots are pixel-identical to the ones from `36f90b83` (render both, `cmp`); the demo script plays
  to beat 42 with `--speed 30 --quit-after`; the build has no reference to the old event methods outside the demo.
- **Commits:** `refactor: the Router v2 model's draft and acts in files of their own` · `feat: the Router v2 page
  takes whole records through one apply, and the demo feeds it that way` · `feat: every act of the Router v2 page
  reaches its source, settle and snooze with their reverts included` · `refactor: a new thread's efforts and access
  are T3's own lists`.
- **Depends on:** nothing. Blocks all of wave 1 except track 2's wave-0 part.

### Track 2 · T3 wire (wave 0), then detail and PRs (wave 1)

- **Owns:** `T3Types.swift`, `AgentThread.swift`, `PullRequestStates.swift`, `TF/T3Fixtures.swift`; new
  `RouterDetail.swift`, `RouterPullRequests.swift`. In wave 0 only, the request builder of `ThreadLauncher.swift`
  (`:79-84`).
- **Wave 0 (small, lands first):**
  - `T3ThreadShell` / `AgentThread`: `runStartedAt` (`activityRunStartedAt`), `stopRequested`
    (`latestRunStopRequested`), `latestRunID`.
  - `T3LaunchRequest`: `options` for the effort, sent as `modelSelection.options`; `ThreadLauncher.request` takes the
    interaction mode instead of a constant.
  - `T3Command`: `messageDispatch(… continuationOf: String?)` (`manualContinuationOfRunId`), `pullRequestLink(threadId:
    url:)` (`thread.pull-request.link`).
  - Checkpoints decoded from the projection's raw `checkpoints` (`files`, `additions`, `deletions`, `filesTotal`).
- **Wave 1:** `RouterDetail` (1.7) as pure functions of `T3Projection`: the working line with `mono`, the steps, the
  reply and `writing`, the request, the queued words with their run id, the diff, the failed run's last step,
  `steers`. `RouterPullRequests`: the refs of a thread (linked, and named in its last reply), their states (T3's
  first, GitHub's for the rest), the link command for the named ones, a callback when a state changes.
- **Contract:** `struct RouterDetail: Equatable` and `static func make(_ p: T3Projection, now: Date) -> RouterDetail`;
  `RouterPullRequests.states(for thread: AgentThread, reply: String?) -> [RouterV2Thread.PR]` and `onChange`.
- **Tests:** `T3TypesTests` additions (each new field and command against T3's JSON shapes); `TF/RouterDetailTests`
  (new, on `T3Fixtures` projections: to-do step beats narration beats tool; a command is mono; a streaming message
  sets `writing`; the diff sums a turn's checkpoints); `TF/RouterPullRequestsTests` (a named PR is linked once; a
  failed link falls to the fetcher, a fake). `swift test --filter T3Types`, `--filter RouterDetail`,
  `--filter RouterPullRequests`.
- **Done:** wave 0 merged before wave 1 starts; no caller of the changed signatures is broken.
- **Commits:** `feat: T3's shell row says when its run started and whether you stopped it` · `feat: a launch can
  carry the model's effort and the interaction mode` · `feat: a message can continue an interrupted run, and a named
  pull request can be linked` · `feat: a thread's working line, steps, reply, queue and diff read from its projection`
  · `feat: a thread's pull requests with their states, the named ones linked in T3`.
- **Depends on:** nothing (wave 0); track 1's record types (wave 1).

### Track 3 · Records and banners (wave 1)

- **Owns:** `RouterRecords.swift`, `RouterCodeState.swift`, `RouterNotifier.swift` (new), `ThreadNotices.swift`.
- **Does:** 1.3 whole: scope, the code-state table, the fingerprint, compose, pending acts and when they end, the new
  dot, the housekeeping set, the clock boundary's one-shot, the diff against what was shown, the hold during a morph,
  the verdict file (read off main, coalesced writes, purged of threads T3 no longer lists). `RouterNotifier`: banners
  on a record's code transition (a new ask, a finish, a real stop, a usage limit), each once, keyed on the request,
  plan or run id, with `ThreadNotices`' words; and one when a verdict finds a step, keyed on the fingerprint.
- **Contract (what it offers):** `shell(_ item: T3ShellItem?)`, `detail(_ id: String, _ d: RouterDetail?)`,
  `connection(_:)`, `verdict(_ id:, _ event: RouterVerdictEvent)`, `began(send:)` / `ended(send:)`, `hide(_:on:)`,
  `notForMe(_:on:)`, `seen(_:)`; reads `needsYou: Int`, `record(_ id:) -> RouterV2Thread?`, `lines(in:) ->
  [RouterV2Thread]`; `emit: (RouterV2Change) -> Void`; `ask: (RouterVerdictRequest) -> Void`, `cancel: (String) ->
  Void` (the engine's side, a fake in tests). Inputs are values (`AgentThread`, `RouterDetail`), so tests need no
  socket.
- **Tests:** `TF/RouterCodeStateTests` (every row of the table; a request wins over `running`; "stopped by you";
  scope at 24 h and 7 days; settled and failed unseen is out); `TF/RouterRecordsTests` (one shell item emits at most
  one change; an unchanged row emits none; a verdict for an old fingerprint is dropped; a pending send holds `sent`
  until the run shows and ends on a refusal; not for me survives a restart and dies with the fingerprint; a morph's
  changes arrive as one batch; 500 rows reduce in under 5 ms in debug); `TF/RouterNotifierTests`. `swift test
  --filter RouterCodeState`, `--filter RouterRecords`, `--filter RouterNotifier`.
- **Done:** tests pass; the store has no import of SwiftUI and reads no view state.
- **Commits:** `feat: a thread's code state, scope and fingerprint as a pure function of T3's row` · `feat: the
  Router's record per thread, composed from code, verdict and pending acts, emitting only what changed` · `feat:
  banners keyed on the request or run they are about, from the records`.
- **Depends on:** tracks 1 and 2 (wave 0).

### Track 4 · Verdicts (wave 1)

- **Owns:** `ClaudeStream.swift`, `RouterVerdicts.swift`, `RouterVerdictPrompt.swift`, `ProjectPurposes.swift` (new),
  `ClaudePrint.swift`; `evals/router/verdict/` (new).
- **Does:** 1.4 whole. `ClaudeStream.run(binary:arguments:input:timeout:) -> AsyncThrowingStream<Data, Error>` (lines
  as they come; cancelling terminates the process); `PartialJSON` (pure); the engine with its queue, cap, cancel and
  fingerprint check; the prompt, schema and input builder; the `verdict` usage role; `ProjectPurposes`. A dump
  helper, as `BriefEvalDumpTests` was (`FJORD_VERDICT_EVAL_DIR`): each real thread's input and verdict to a folder,
  redacted.
- **Contract:** `struct RouterVerdictRequest { thread, fingerprint, kind: .finished | .ask | .name, input }`;
  `enum RouterVerdictEvent { case state(needsYou: Bool, worth), words(String, done: Bool), done(RouterVerdict),
  failed }`; `RouterVerdicts.ask(_:)`, `cancel(_ thread:)`, `onEvent: (String, fingerprint, RouterVerdictEvent) ->
  Void`. The runner is injected (`ClaudeStream.Runner`), as `ClaudePrint.Runner` is.
- **Tests:** `TF/ClaudeStreamTests` (`PartialJSON` on a real captured stream cut at every byte: fields in order, the
  line cut at whole words, escapes; a line split across chunks); `TF/RouterVerdictsTests` with a fake runner: `state`
  before words; at most 4 at once and the fifth waits; a cancel stops the process and emits nothing; asks go before
  finished before names; a failure emits `failed` once; usage is logged. `swift test --filter ClaudeStream`,
  `--filter RouterVerdicts`.
- **Done:** tests pass; one live call on made-up text (`FJORD_ANTHROPIC_LIVE=1`-style opt-in) shows `state` then
  growing words. **Eval (wave 2, with the orchestrator, on the owner's real threads):** 150 finished turns and every
  real ask: no line states a fact its reply or PR state doesn't; of the turns a person marks as leaving a step, 90 %
  found; at most 10 % of `needs_you` wrong. Below that the prompt is fixed before wave 3.
- **Commits:** `feat: a claude -p call streams its typed answer field by field` · `feat: one Haiku verdict per thread
  per fingerprint, four at once, cancelled when a run starts` · `feat: a project's purpose has its own small call` ·
  `test: verdicts dumped from real threads for scoring`.
- **Depends on:** track 1.

### Track 5 · Reader and a new thread's settings (wave 1)

- **Owns:** `RouterV2Reader.swift`, `RouterLaunchCatalog.swift` (new), `DeciderContext.swift`,
  `RouterProjectDecide.swift`, `DeciderLog.swift`.
- **Does:** 1.5 whole. The reader: the typing pause, Jev, Sonnet, cancel on a keystroke, reuse on the same words and
  board, a Return that skips the pause, T3's search hits as `RouterPreview` fires them (`SF/RouterPreview.swift:133`).
  The schema's `launch` and `launch_words`, their enums built from the catalog at call time; `RouterContextAnswer`
  decodes them; `RouterProjectDecision` carries them; mapping to `RouterV2Read` (`.thread`, `.newThread`, `.answer` →
  `.here`, `.ask(places)` → unsure, three at most). The prior's line in the Now block: `DeciderContext.build` takes
  the open card's thread as a new optional input (`SF/DeciderContext.swift:401`); its caller in
  `DeciderContextSource.swift` passes it in wave 2 (9b). The two typing pauses are constants this track asks track 7
  to add to `enum RouterV2`. The catalog from `server.getConfig` (a `T3JSON` in, values out, pure).
- **Contract:** `RouterV2Reader.read(_ draft:, selected:, mentions:)`, `cancel()`, `now(_ draft:)` (Return before the
  read), `onRead: (RouterV2Read, RouterProjectDecision?) -> Void`; closures for Jev, Sonnet, the board key and the
  search are injected, as `RouterPreview`'s are. `RouterLaunchCatalog.make(config: T3JSON, project: T3JSON?) ->
  (defaults: RouterV2Launch, models: [RouterV2LaunchModel])`.
- **Tests:** `TF/RouterV2ReaderTests` (Jev sure → no Sonnet; unsure → Sonnet; a keystroke cancels both; the same words
  on the same board reuse; a model T3 doesn't have is dropped; `launch_words` not in the draft takes nothing; a read
  for older words is never emitted); `TF/RouterLaunchCatalogTests` (this install's config: four models, efforts per
  model, default Opus 5.5 · High · Auto; a provider that lacks a runtime mode doesn't offer it);
  `RouterProjectDecideTests` and `DeciderContextTests` additions. `swift test --filter RouterV2Reader`, `--filter
  RouterLaunchCatalog`, `--filter RouterProjectDecide`, `--filter DeciderContext`.
- **Done:** tests pass. **Eval (wave 2):** the 300 dev moments with the new schema and the prior's line: thread
  top-1, wrong-thread sends and new-work starts no worse than N4's numbers (t3-code-map §12); 40 real drafts with
  settings asides: every setting read right, nothing taken that was meant for the agent.
- **Commits:** `feat: the decider reads a new thread's model, effort and modes from the draft, and quotes the words
  that say them` · `feat: the open card is a prior for where a draft goes` · `feat: a draft's destination read at
  the typing pause, Jev first, then Sonnet` · `feat: T3's models, efforts and modes as the new-thread row's choices`.
- **Depends on:** track 1.

### Track 6 · Acts (wave 1)

- **Owns:** `RouterActs.swift`, `ThreadAnswers.swift` (new), `ThreadSender.swift`, `ThreadActs.swift`,
  `ThreadLauncher.swift` (from wave 1), `RouterDispatcher.swift`.
- **Does:** 1.6 whole. `RouterActs: RouterV2Source` over a small set of closures (submit, answer, launch, dispatch a
  command, act with a `FjordChange`, open), so tests need no `Store`. The dispatcher reports each entry's send
  (`onSend: (UUID, SendEvent)`: taken, refused with its reason and whether T3 was away). `ThreadAnswers`: picks and
  typed words to T3's answers by the rules in `RouterBriefs.answerRequest`, on `RequestSnapshot`. `launchThread`
  takes the thread id, the model with its effort, the runtime and interaction modes (new parameters, today's values
  as their defaults). Continue's command. Settle all as one act with one Revert. A refused settle or snooze unhides
  the line and tells the model. `Store.threadAct` gains a `hold:` closure (default: the brief's `holdAct`, so the old
  page is untouched); `RouterActs` passes the records'. History's Revert (`replayBriefAction`) is switched to the
  records by 9a in wave 2.
- **Contract:** implements `RouterV2Source`; tells the records `began(send:)`, `ended(send:)`, `hide`, `notForMe`,
  `seen` (track 3's names, a protocol `RouterActsRecords` it declares for itself, so it compiles before track 3
  lands); emits `.refused` through a closure.
- **Tests:** `TF/RouterActsTests` (new; recording fakes): each kind of `RouterV2Outgoing` sends the right command
  (an idle send, a steer, a queue, an agent that can't steer queues, a picked option, a form with a typed answer, a
  permission typed is a decline with feedback, a plan's two options set the mode then implement, Continue with and
  without the run id); a refusal emits `.refused` and ends the pending send; settle then its revert send the two
  commands and mark the change reverted; a launch carries the four settings and the minted id.
  `ThreadSenderTests`, `ThreadActsTests`, `ThreadLauncherTests`, `RouterDispatcherTests` additions. `swift test
  --filter RouterActs`, then each of those.
- **Done:** tests pass; nothing in `RouterActs` awaits before it has recorded the pending act.
- **Commits:** `feat: the dispatcher says when T3 took a send and why it didn't` · `feat: a new thread starts with
  the model, effort, access and mode the row showed` · `feat: answers to a question, a permission and a plan from
  picks and typed words, in one place` · `feat: the Router v2 page's acts on T3: send, steer, queue, Continue, Stop,
  settle, snooze and their reverts`.
- **Depends on:** tracks 1 and 2 (wave 0).

### Track 7 · Rendering and signposts (wave 1)

- **Owns:** `RouterV2Page.swift`, `RouterV2Line.swift`, `RouterV2Card.swift`, `RouterV2Effects.swift`,
  `RouterV2Surfaces.swift`, `Signposts.swift`, `scripts/morph-timings.sh`, and from wave 1 `RouterV2Model.swift`,
  `RouterV2.swift`, `RouterV2Demo.swift`, `RouterV2DemoScript.swift`, `RouterV2Shots.swift`.
- **Does:** 2.2's "diffing only what changed" and "streaming": the per-thread boxes and the stored layout; per-row
  flags for selected, hovered, pressed, moving and marked; stored counts; only the open card built; one shared minute
  clock for ages in place of a `TimelineView` per row (`SF/RouterV2Line.swift:400`); the coalescer; the sentence
  taking words as they arrive (`.words`) with the same look as the demo's 50 ms stream; the card's reply from
  `.reply`; the card of a request that is no longer live (Open in T3 in the options' place). The `router` signposts
  (`enum RouterSignposts` in `Signposts.swift`: `begin(_ name:)` and `end(_:afterCommit:)`, declared in this track's
  first commit so tracks 3, 6 and 8 can call it) and `--args` in `morph-timings.sh`. Body-evaluation counters under `UnderTest`. `--router-v2-load` (with track 1's
  demo store: this track adds the scenario's flag and records in `RouterV2Demo.swift` only after track 1 is merged).
- **Contract:** the model's public face stays (`thread(_:)`, `rows()`, `shownLines`, `count(…)`, `apply`), so the
  other tracks don't notice. Seam: any other track that needs a stored property in `RouterV2Model.swift` during wave 1
  asks this track.
- **Tests:** `TF/RouterV2RenderTests` (new): an upsert that keeps the order runs one line body and no list body; a
  hover from row A to B runs two; `.words` runs that line's sentence only; opening a card builds one card; three
  `.words` for one thread in one turn flush once. `RouterMotionTests` still pass. `swift test --filter
  RouterV2Render`, `--filter RouterMotion`, `--filter ShotCatalog`.
- **Done:** tests pass; the `v2` shots unchanged; a `perf:` commit with `morph-timings --args "--window
  --router-v2-load --quit-after"` before and after.
- **Commits:** `perf: a Router v2 line redraws alone, the list only when the order changes` · `perf: hover and
  selection touch two rows` · `perf: only the open card is built` · `feat: a verdict's words appear as they
  arrive, one flush a frame` · `feat: the Router's event, key and send latencies as signposts, read by
  morph-timings`.
- **Depends on:** track 1.

### Track 8 · Composer, dock and keys (wave 1)

- **Owns:** `RouterV2Dock.swift`, `RouterV2Keys.swift`, `RouterV2Launch.swift`, `RouterV2Model+Draft.swift`,
  `RouterV2Model+Acts.swift`, `RouterMentionField.swift`.
- **Seam for the field:** `MentionField` needs the `Store` and the composer's text model (`RouterModel`,
  `SF/RouterMentionField.swift:141`), which the v2 screen isn't given. This track declares an environment value in
  `RouterV2Dock.swift`, `routerV2Composer: (store: Store, text: RouterModel)?`. With it set the composer is
  `MentionField`; without it (and in a still, or while the script types) it draws as today. 9a sets it in
  `AppContent` in wave 2; this track's tests and one new shot (`v2-mention`) set it themselves.
- **Does:** the composer's field is `MentionField` in the approved card (its text model: `RouterModel`'s draft,
  pills and @ state, used as it is until wave 3; the v2 model follows it through `setDraft`), with the script's and
  the shots' paths kept (a still draws words, the script types through the same model). The @ list over the caret,
  Tab or Return picks, a thread pill is the model's `explicit` place, ⌫ at the start drops it. The taken words
  marked in the text view itself (a temporary attribute on the range, several lines included). The held look. The
  row's note and words while T3 is away. Effort and access menus from the chosen model's lists. Tab into the places
  menu. An unattended action waiting for a place as a status-stack line with the places menu (risk 5). Keys: an IME
  composing keeps its keys; the `Key` and `Key work` signposts begin in `RouterV2Keys.key` (through track 7's
  `RouterSignposts`, declared in its first commit).
- **Contract:** reads the model; calls `model.setDraft`, `model.send`, the launch methods. No new source method.
- **Tests:** `TF/RouterV2KeysTests` (new; `RouterV2Keys.handle` with `RouterV2Key` values on a model with a recording
  source): every row of DESIGN 5.1 and the order of 5.3; Return and ⌘⌫ ignore repeats; ⇧digits pick by key position
  and a bare digit-row key types; ⌘1–3 with a draft never fall through. `RouterMentionFieldTests` additions (the
  taken range survives typing before it; a pill becomes an explicit place). `swift test --filter RouterV2Keys`,
  `--filter RouterMentionField`.
- **Done:** tests pass; the `v2-new-thread-*`, `v2-held`, `v2-destination-*` shots unchanged; typing in
  `--window --router-v2-demo` after the script feels as before (the orchestrator's check, once).
- **Commits:** `feat: the Router v2 composer takes @ mentions, a thread pill being an explicit place` · `feat: the
  words taken as settings are marked in the text itself` · `test: the Router v2 key map, row by row`.
- **Depends on:** track 1.

### Track 9 · Integration (wave 2; two agents on two file sets)

- **9a owns:** `Store.swift`, `Threads.swift`, `AppContent.swift`, `AppWindow.swift`, `AppSidebar.swift`,
  `AppWindowShots.swift`, `Demo.swift`, `Playground.swift`, `RouterV2Screen.swift` (new; `RouterV2Screen` moves out of
  `RouterV2Page.swift`), `RouterDrawer.swift`, and every file the table above gives it in wave 2 (for wiring fixes
  only; the tracks' work in them is done).
  - `Store`: `routerRecords`, `routerVerdicts`, `routerReader`, `routerActs`, `routerPage` (the one page model, made
    once, kept across window opens; the demo's when `RouterV2Demo.model` is set), wired with the closures each track
    asked for. `wireThreads` calls the records first from `onShell`, `onThread`, `onConnection`; `threadAct` and
    `replayBriefAction` hide through the records.
  - The window: `.router` shows `RouterV2Screen(model: store.routerPage)` with `routerV2Composer` set (track 8's
    seam); the key monitor always uses `RouterV2Keys`; the sidebar's badge reads `routerRecords.needsYou`.
  - The screen hosts the History drawer, its toggle, `RouterSetupNotice`, the Router-off sentence.
  - `--demo router` and the playground on the demo store at rest. New shots: `v2-drawer`, `v2-setup`, `v2-off`.
- **9b owns:** `HubSections.swift`, `HubComponents.swift`, `PaletteRouterSource.swift`, `PalettePlacesSource.swift`,
  `RouterMCP.swift`, `RouterRun.swift`, `DeciderBoardSource.swift`, `DeciderContextSource.swift`, `RouterJev.swift`,
  `RouterDecisions.swift`, `RouteTarget.swift`, `System.swift`: every row of 1.9, onto the records.
- **Seam between them:** 9b reads only `store.routerRecords` and `store.routerPage`, which 9a declares in its first
  commit (the properties, before their wiring).
- **Tests:** `TF/RouterV2WiringTests` (new, on `T3HTTPStub` and `T3Fixtures`): a seeded shell gives the page its
  lines; a `thread.updated` gives one `.upsert`; a turn end asks one verdict (fake runner) and its words reach the
  line; Return on a picked option sends `runtime-request.respond` and the line is Sent in the same turn; settle then
  ⌘Z sends settle then unsettle. `HubTests`, `PaletteRouterSourceTests`, `RouterMCPTests`, `DeciderContextTests`
  updated. `swift test --filter RouterV2Wiring`, then each.
- **Done:** on the owner's T3 (`--t3`-style read-only check first, then the installed build, at the owner's go): the
  page shows the real threads, a real turn end moves a line and streams a verdict, a real answer goes. Nothing reads
  `store.routerBriefs` any more except the files track 10 deletes.
- **Commits:** `feat: the Router page is v2 on T3's threads` · `feat: the History drawer and the setup notice in the
  Router v2 page` · `feat: the bar, the palette and the Router's own answers read the records` · `feat: the decider
  reads project purposes and the page's threads from the records`.
- **Depends on:** tracks 1 to 8.

### Track 10 · Deletion and gates (wave 3)

- **Owns:** everything in 1.11; `CLAUDE.md`, `DEVELOPMENT.md`, `README.md`, `docs/performance.md`,
  `docs/design/t3-code-map.md`, `docs/design/brief-rebuild.md` (a line saying what replaced it), `scripts/idle-cpu.sh`.
- **Does, in this order:**
  1. Move what is still used out of the files that go (1.11); slim `RouterModel` to the composer's text model.
  2. Delete the files, the old shots, the old tests, the `brief` shots in `ShotCatalogTests`, the Rewrite menu item
     and its palette command, the Router style setting.
  3. Rename `RouterV2*` to `Router*` in one mechanical commit (risk 9), the flag staying `--router-v2-demo`.
  4. Docs: the shot names in `CLAUDE.md`, the Router sections of `DEVELOPMENT.md`, a "Router v2" section in
     `docs/performance.md` with the gate table's numbers.
  5. Run 2.4's gates on a release build; fix or hand back what is red.
- **Tests:** `scripts/test.sh` (the whole suite, once, with the lock); `--window-shots` for every `v2` shot in both
  looks.
- **Done:** `grep -rn "RouterBrief\|routerBriefs\|BriefLog\|RouterPreview\|RouterComposer\b" Sources Tests` finds
  nothing; every gate of 2.4 passes with its numbers in a commit message; a build from a clean export installs and
  runs.
- **Commits:** `refactor: what the Router v2 page shares with the brief lives outside it` · `refactor: the Router
  brief page, its engine, its store and its tests are gone` · `refactor: Router v2's types are the Router's` ·
  `docs: the Router page as it is built, and its performance gates` · `perf: …` for each fix, with numbers.
- **Depends on:** track 9 and both evals passing.

**After wave 3:** one Fable pass over the whole diff (the seams: pending acts against T3's events, the verdict's
cancel and fingerprint check, the held Return, the morph hold), then the owner's install.

## 4. Risks and open questions

1. **The verdict's judgment is unmeasured.** `needs_you` on a finished turn decides what the owner sees first.
   *Default:* the eval in track 4 is a gate for wave 3; until it passes the old page is not deleted (and nothing ships
   half-switched).
2. **The decider's input changes** (the open card as a prior, four new fields). Its numbers were fitted without them.
   *Default:* the prior only in Sonnet's Now block, Jev untouched; track 5's eval must show no loss before wave 3.
3. **The typing pause is a wait.** It is the one timer between a key and a read, and it trades speed for cancelled
   Sonnet calls (about $0.008 each, from the subscription). *Default:* Jev 0.3 s after the last key, Sonnet 0.6 s
   (today 0.6 and 1.2); Return never waits for it. Both in `enum RouterV2`, tuned from the decision log.
4. **Many `claude -p` at once on the subscription.** The first launch has a verdict and a name to ask for every thread
   on the page (30 to 40), and seven or more at once was never run. *Default:* 4 at once, asks first; a rate-limit
   error stops the queue until the next T3 event or the time the error names; lines stay on the code's words.
5. **An unattended Triage action that isn't sure has no card to wait in** once the after-send ask goes.
   *Default:* its policy stands (a new thread in the item's project at 0.80); with no project known it waits as one
   line in the dock's status stack with the places menu, and in History.
6. **"Fjord answers here" has no surface in the design.** *Default:* the answer streams in one line of the status
   stack (the run's live text, click for the whole of it in History); the owner picks a better place after seeing it.
7. **`thread.pull-request.link` was never run live.** *Default:* try it in wave 2 on one real thread; if T3 refuses,
   named PRs are refreshed on Triage's sync turn and at window open. Either way a merge shows within about a minute.
8. **Working lines are thin without T3's to-do setting** (`CLAUDE_CODE_ENABLE_TODO_TOOLS=1` in T3 › Providers ›
   Claude › Environment; unverified with the `claude-thread` binary). *Default:* the owner sets it; without it the
   line is the agent's latest words, then the tool. Nothing is blocked.
9. **Eight agents in one checkout.** A half-written shared file breaks every build. *Default:* the ownership table
   and the test lock (section 0). If the tree breaks twice in a wave, ask the owner to allow agent worktrees for this
   build only.
10. **The `V2` in the names** is legacy once v1 is gone. *Default:* renamed in track 10's one mechanical commit.
