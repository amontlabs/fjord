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

**Credentials.** GitHub access comes from `gh auth token`, `GH_TOKEN` / `GITHUB_TOKEN`, or a token pasted in Settings, which is stored in the Keychain. The Anthropic API key (the Router's decider, set in Settings, Keychain service `fjord-anthropic-key`) and the optional TypeSafe key (for Jev, TypeSafe's classifier) are kept in the Keychain too. Fjord's T3 token (minted with `t3 auth session issue`) is stored there as well. Demo, snapshot and playground runs never touch the Keychain, so a new build doesn't stop on an access prompt.

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

`router` is the brief over demo projects (DemoBriefs.swift): entries that need you (a question and a plan from T3 threads), working and finished threads, a decision log and an ask waiting for its pick.
For release window timings, run `scripts/morph-timings.sh --scenario router --steps "open,close x6"`.

### Window, bar and screenshots

| Command | What it does |
| --- | --- |
| `--window` | The window alone, on demo data. |
| `--window-shots <dir> [name…]` | Renders the window's pages as PNGs, offscreen (`window-<name>.png`); given names, only shots containing one of them. |
| `--playground` | The bar on a fake desktop, demo data, every edge. |
| `--playground-shots <dir> [name…]` | Renders the bar's states as PNGs, offscreen: every edge, every demo scenario, Reduce Motion / Increase Contrast / Differentiate Without Color variants, and a 1280×720 screen. Shots are named `<edge>-<state>` (`right-open`, `top-rest-signed-out`…); given names, only shots containing one of them are rendered. |

`FJORD_THEME=dark|light|claude` pins the look: Fjord light, Fjord dark, or Claude's own. The default is Fjord, following the Mac's appearance live.

```sh
FJORD_THEME=dark .build/debug/Fjord --window
```

### The Router's routing

Every message goes to a T3 thread as one `message.dispatch` over T3's WebSocket API (`T3Link`, `T3Client`). A reply armed on a brief entry (or one focused) goes to that
thread; a tagged project or thread goes there with no model; anything else is the project decider's (`RouterProjectDecider`: Jev first at 0.7, else
Sonnet over the Anthropic API, `AnthropicClient`), whose stage shows on the message's pill. A project that fits nothing is proposed under the
composer (`RouterProjectProposal`, revised by Sonnet). The brief's entries are the one model of what needs you (no cards):
mark read and archive are Fjord changes with a Revert in the history drawer, kept with the Told marks in briefs.db. Each history entry keeps who decided (`decision.decider`) and a
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

- `--lifecycle` prints the app's idle state (threads, how many are working, whether a window shows, Reduce Motion) for `scripts/idle-cpu.sh`.
- `--motion-script <steps> --quit-after` plays a scripted sequence of motions and quits, for `scripts/motion-trace.sh`.

## Tooling scripts

| Script | What it does |
| --- | --- |
| `scripts/build-app.sh` | Builds `build/Fjord.app` (see [Build and run](#build-and-run)). |
| `scripts/test.sh` | The test suite as CI runs it, output in `test.log`. |
| `scripts/idle-cpu.sh` | Checks the release build's CPU stays under its limit at rest and with the window kept open, on the right edge and along the top, on demo data. Puts the bar on screen for minutes. |
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
