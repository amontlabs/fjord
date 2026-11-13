# Developing Fjord

Everything for building, testing and releasing the app. For what the app does, see the [README](README.md).

- [Build and run](#build-and-run)
- [Tests](#tests)
- [Debug flags](#debug-flags)
- [Tooling scripts](#tooling-scripts)
- [Releasing](#releasing)
- [Signing certificate](#signing-certificate)
- [Implementation notes](#implementation-notes)

## Build and run

A Swift package (Swift tools 5.10, macOS 14+). The app is built into a bundle, which notifications and launch at login need:

```sh
./scripts/build-app.sh && open "build/Fjord.app"
```

`build-app.sh` needs Xcode's command-line tools (`xcrun actool` compiles the layered icon, `Resources/AppIcon.icon`). It takes:

| Variable | Effect |
| --- | --- |
| `VERSION=1.2.3` | Sets the bundle version (default `0.0.0-dev`). |
| `UNIVERSAL=1` | Builds the app for arm64 and x86_64, as releases do. |
| `SIGN_IDENTITY="…"` | Signs with that identity, and fails if it isn't in your keychain. |

Without `SIGN_IDENTITY`, local builds are signed with the release certificate (default name `Fjord Dev`) when it's in your keychain, and ad hoc otherwise. macOS treats every ad-hoc build as a new app, so Accessibility access has to be granted again each time. See [Signing certificate](#signing-certificate).

The debug flags below run the debug binary: `swift build`, then `.build/debug/Fjord …`.

**Credentials.** GitHub access comes from `gh auth token`, `GH_TOKEN` / `GITHUB_TOKEN`, or a token pasted in Settings, which is stored in the Keychain. The optional TypeSafe key (for Jev, TypeSafe's classifier) is kept in the Keychain too; the Router's Sonnet and Haiku calls run through `claude -p` on your subscription and need no key. Fjord's T3 token (minted with `t3 auth session issue`) is stored there as well. Demo, snapshot and playground runs never touch the Keychain, so a new build doesn't stop on an access prompt.

**State** lives in `~/Library/Application Support/Fjord/state.json`.

## Tests

```sh
scripts/test.sh
```

Runs `swift test` as CI does and writes the output to `test.log`. The run counts as passed only when the summary line is present: a test process that stops partway can still exit 0.

The `Test` workflow runs the same script on every push to `main`, on the same runner as releases (`macos-15`, 20-minute limit), so a test that fails only there shows up before a release.

## Debug flags

### Demo data

```sh
.build/debug/Fjord --demo [scenario] [--open] [--edge left|right|top|bottom]
```

Mock data with Triage on (and the Router, in its scenarios). Nothing is saved. `--open` opens the window; `--edge` puts the bar on that edge.

| Group | Scenarios |
| --- | --- |
| Plain sets | `busy` `botsOnly` `allClear` `snoozed` `error` `empty` `agents` |
| Empty lists and sync failures | `signedOut` `inboxFailed` `rateLimited` `contributionsEmpty` `botChatterEmpty` `doneEmpty` `firstSync` `syncFault` |
| Inbox | `inboxMany` `hiddenCategory` `jev` `sections` |
| CI | `noCI` `allPassing` `manyCI` `ciRunning` |
| Updates | `updateAvailable` `updateDownloading` `updateReady` |
| Router | `router` `routerOff` |

`router` is the Router page over the demo's threads (one asks a question, one holds a plan, others work or are done) and a decision log; `routerOff` the same with the Router off.
For release window timings, run `scripts/morph-timings.sh --scenario router --steps "open,close x10"`.

### Window, bar and screenshots

| Command | What it does |
| --- | --- |
| `--window` | The window alone, on demo data. |
| `--window-shots <dir> [name…]` | Renders the window's pages as PNGs, offscreen (`window-<name>.png`); given names, only shots containing one of them. |
| `--playground` | The bar on a fake desktop, demo data, every edge. |
| `--playground-shots <dir> [name…]` | Renders the bar's states as PNGs, offscreen: every edge, every demo scenario, Reduce Motion / Increase Contrast / Differentiate Without Color variants, and a 1280×720 screen. Shots are named `<edge>-<state>` (`right-open`, `top-rest-signed-out`…); given names, only shots containing one of them are rendered. |

`FJORD_THEME=dark|light|claude` pins the look: Fjord light, Fjord dark, or Claude's own. The default is Fjord, following the Mac's appearance live.

**Router page demo** (docs/design/router-v2/DESIGN.md). `--window --router-v2-demo` shows the Router page (`Router*.swift`: `RouterScreen`, `RouterPage`, `RouterLine`, `RouterCard`, `RouterDock`) on fake records and plays the storyboard on it: a drawn pointer, keys through the page's own key map, fake T3 events. `--beats 5,6,14` plays only those beats, `--from <beat>` runs the earlier ones at 30 times the speed, `--until <beat>` ends after that beat, `--speed <x>` scales every wait, `--reduce-motion` turns Reduce Motion on for the page, `--quit-after` quits at the end, `--frames <dir>` writes the window's own picture ten times a second while the script plays (`--frames-rate <n>` for more, up to 60; each file is named by its time in hundredths of a second; frames to check a beat's motion where nothing can be filmed; it needs no Screen Recording permission). With `--frames` or `--select-check` (and not filming) the window is drawn off every screen, as the window shots are: nothing shows, nothing takes the focus, no Dock icon. With `--frames`, each frame's `rows-*.json` says where each row of the list is drawn (its glide included); `scripts/router-frames-check.py <dir>` lists the frames where a row has no ink there (needs Pillow). `--select-check [few]` plays, instead of the beats, cards opened mid-list and last, switched, shut, and ↓/↑ walks (`few`: on five lines, a real page's shape), to check a card opens in place. When the script is over (and nothing records) the page is yours to try. Its stills are the `v2-` window shots, light and dark (`v2-home`, `v2-card-plan-dark`, `v2-new-thread-pills`, …). To film it: `FJORD_THEME=light FJORD_GLASS=0 scripts/record-window.sh router-v2 -- --window --router-v2-demo`.

**Router load scenarios** (the speed gates, docs/performance.md "Router page"). `--window --router-v2-load` is the demo's page grown to 60 lines in a 1617 × 1188 window for twelve seconds: eight lines stream a verdict, a record lands every 30 ms, a line moves four times a second. `--router-v2-load real` is the shape of a real T3 day: twenty lines, two streaming, a record about every second, a move every ten, thirty seconds. `--router-v2-load select` opens one card after another (↓ every 300 ms, 24 s) on the sixty lines with nothing else coming, for the Select gate. All quit with `--quit-after`; read them with `scripts/morph-timings.sh --args "--window --router-v2-load --quit-after"`. `FJORD_LOAD_OFF=streams,reply,records,moves` leaves parts out. The load runs draw the window off every screen, like `--frames`.

```sh
FJORD_THEME=dark .build/debug/Fjord --window
```

### The Router's routing

The Router page is one line per T3 thread (`RouterRecords`: the code's state from T3's shell and the thread's projection, then a Haiku or Sonnet verdict per finished turn, `RouterVerdicts`), grouped Needs you, Done, Working. With the Router off no verdict is asked and a finished thread is plain Done. Every message goes to a T3 thread as one `message.dispatch` over T3's WebSocket API (`T3Link`, `T3Client`), through `RouterActs`. Words typed with a line's card open answer that thread; a tagged project or thread goes there with no model; anything else is the project decider's (`RouterProjectDecider`: Sonnet through `claude -p` (`ClaudePrint`) on N4's full context, `DeciderContext`, at N4's 1% bars), whose stage shows on the message's pill. E5's Jev-led path
(`JevPath`, RouterJevPath.swift: one Jev call, two yes/no checks on the 3 latest idle threads, recency and BM25 fused in code) runs first (always on,
no setting, no shadow) and is logged in `decider-log.jsonl`; it sends to an idle thread at fused P ≥ 0.90
without Sonnet, and below that Sonnet decides. Your own messages are read in the composer before they go (`RouterReader`): Jev after a 300 ms typing pause, Sonnet after 600 ms when Jev isn't sure; the destination row under the draft says where Return sends: sure, the thread; unsure, the guess and 2 alternatives (shots `v2-destination-sure`, `v2-destination-unsure`). The context's thread cards, BM25 text and the day's archive are kept off the decision path in `Application Support/Fjord/thread-cards` (`ThreadCardStore`); every model call's tokens and cost go to `model-usage.jsonl`, shown in Settings › T3 Code (shot `settings-model-usage`). Refit its weights from
the log with `evals/router/t3/refit.py`. A project that fits nothing is proposed under the
composer (`RouterProjectProposal`, revised by Sonnet). Settle, snooze and the other acts on a line are T3 commands with a Revert (the toast, ⌘Z, the history drawer, ⌥⌘B). Each history entry keeps who decided (`decision.decider`) and a
correction (Send elsewhere, a different pick on an ask, a proposal you changed) as its outcome, for measurement.

### Live data

| Command | What it does |
| --- | --- |
| `--t3 [--watch]` | Prints what the Router reads of T3 (link, threads by group, what waits on you), read-only; `--watch` prints live changes. |
| `--check owner/repo` | Headless live sync of one repo; prints the inbox. |
| `--check-inbox` | Headless live sync with sample categories; prints every entry. |

### Live read-only checks

The T3 and Anthropic tests are skipped unless you opt in; run one suite at a time.

```sh
FJORD_T3_LIVE=1 swift test --filter T3Live            # reads your real T3 server's shell; prints counts only
FJORD_ANTHROPIC_LIVE=1 swift test --filter AnthropicLive   # a few tiny real API calls with your Keychain key
```

`FJORD_ANTHROPIC_LIVE=1` also enables the live decider smoke in `RouterProjectDecideTests`. Everything else in the T3 tests runs on stubs (`T3HTTPStub`, fixtures in `T3Fixtures.swift`) and never touches your T3 or the network.

### Updater

```sh
"build/Fjord.app/Contents/MacOS/Fjord" --update 0.1.0
```

Pretends to be version 0.1.0: checks for, downloads and verifies the latest release. Run it from the built bundle, not the debug binary.

### Tooling-only flags

- `--open router` opens the window on the Router page at launch (`--open` alone opens it where it was left).
- `--lifecycle` prints the app's idle state (threads, how many are working, whether a window shows, Reduce Motion) for `scripts/idle-cpu.sh`.
- `--motion-script <steps> --quit-after` plays a scripted sequence of motions and quits, for `scripts/motion-trace.sh`.

## Tooling scripts

| Script | What it does |
| --- | --- |
| `scripts/build-app.sh` | Builds `build/Fjord.app` (see [Build and run](#build-and-run)). |
| `scripts/test.sh` | The test suite as CI runs it, output in `test.log`. |
| `scripts/idle-cpu.sh` | Checks the release build's CPU stays under its limit at rest and with the window kept open, on the right edge and along the top, on demo data; `ROUTER=1` measures the window kept open on the Router page (`--demo router --open router`, limit 0.6 %). Puts the bar on screen for minutes. |
| `scripts/motion-trace.sh` | Records the release build with `xctrace` while it plays a motion script, then reports hitches and signpost latencies; `--baseline FILE` stores or compares against a baseline. Takes the screen while it runs. Options are documented at the top of the script. |
| `swift scripts/make-icon.swift [--preview DIR]` | Draws `Resources/AppIcon.icns` and the layers of `Resources/AppIcon.icon`. |

## Releasing

Push a version tag:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The `Release` workflow runs the tests, builds a universal app and publishes `Fjord-<version>.zip` and its `.sha256` to GitHub Releases.

Once Fjord is installed, it picks up later releases on its own. The updater installs a release only if its checksum matches and it is signed by the same certificate as the running copy.

## Signing certificate

Releases are signed with one self-signed certificate. That keeps the app's Accessibility access across updates, and lets the updater check a release is genuine. Set it up once:

Run `scripts/make-signing-cert.sh` once. It makes a self-signed `Fjord Dev` code-signing certificate, imports it into your login keychain, keeps its `.p12` in `~/.fjord-signing` (its password in the login keychain), and sets the repository secrets `SIGNING_CERT_P12` and `SIGNING_CERT_PASSWORD`. It stops if a `Fjord Dev` certificate already exists. Back the `.p12` up: existing apps refuse a release signed with another certificate, and everyone would have to update by hand once.

With the certificate in your keychain, `build-app.sh` signs local builds with it too.

## Implementation notes

### Global shortcuts run synchronously on the main thread

Global shortcut actions run before their callback returns. Carbon hot keys target `GetApplicationEventTarget()`, which this app dispatches through the [main-thread application event loop](https://developer.apple.com/library/archive/documentation/General/Conceptual/Devpedia-CocoaApp/MainEventLoop.html); AppKit [guarantees that local and global event monitors run on the main thread](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html). [`MainActor.assumeIsolated`](https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:)) verifies the executor before performing the action synchronously. Mouse-button shortcuts still defer their handler, to leave the CGEvent tap callback before any window work.

### What the Router reads and writes

The Router reads T3 through its WebSocket API: the shell stream (projects, threads, what waits on you) and the thread details Fjord asks for. It finds the server through `~/.t3` (`server-runtime.json`) and the `t3` CLI at `~/.t3/bin/t3`. T3's API isn't versioned for us; when it changes, the Router says so and Triage keeps working.

Switching the Router on writes nothing into any agent's config, `~/.claude` included: your words reach a thread as one `message.dispatch` to T3 (steering a running thread, ⌥Return queues; an unattended action always queues), and a queued message can be cancelled or edited in place.
