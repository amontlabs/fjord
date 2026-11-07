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


The embedded Silo engine (`silo-engine-<version>-macos-arm64.tar.gz`) runs on Apple Silicon only, like Silo hosts; on an Intel Mac the app starts but the engine can't run.

`build-app.sh` needs Xcode's command-line tools (`xcrun actool` compiles the layered icon, `Resources/AppIcon.icon`). It takes:

| Variable | Effect |
| --- | --- |
| `VERSION=1.2.3` | Sets the bundle version (default `0.0.0-dev`). |
| `UNIVERSAL=1` | Builds the app for arm64 and x86_64, as releases do. The embedded engine is arm64 only either way. |
| `SIGN_IDENTITY="…"` | Signs with that identity, and fails if it isn't in your keychain. |
| `SILOD_ARCHIVE=/path/to/silo-engine-*.tar.gz` | Embeds that local engine archive instead of downloading the release pinned in [`scripts/silod.release`](scripts/silod.release); the pin's hash isn't checked, the schema check still applies. For trying an unreleased Silo build. |
| `SILOD_PRODUCTION_CODE_REQUIREMENT="…"` | Overrides the code requirement written into the engine's Info.plist (`SiloEngineCodeRequirement`); otherwise the build pins the selected signing certificate, or the bundle identifier for ad-hoc builds. |

Without `SIGN_IDENTITY`, local builds are signed with the release certificate (default name `Fjord Dev`) when it's in your keychain, and ad hoc otherwise. macOS treats every ad-hoc build as a new app, so Accessibility access has to be granted again each time. See [Signing certificate](#signing-certificate).

The debug flags below run the debug binary: `swift build`, then `.build/debug/Fjord …`.

**Credentials.** GitHub access comes from `gh auth token`, `GH_TOKEN` / `GITHUB_TOKEN`, or a token pasted in Settings, which is stored in the Keychain. The optional TypeSafe key (for Jev, TypeSafe's classifier) is kept in the Keychain too. Demo, snapshot and playground runs never touch the Keychain, so a new build doesn't stop on an access prompt.

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

`router` is the brief over demo projects (DemoBriefs.swift): entries that need you (a claude.ai question and plan, a local
form the hook holds), working and finished threads, a decision log and an ask waiting for its pick.
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

Every message goes to a claude.ai project or thread through the delivery engine (`CourierHost`), which starts at launch
(never in `--demo`, the shots or tests). A reply armed on a brief entry (or one focused) goes to that
thread: its session on this Mac through the signed plugin, else its claude.ai thread; a tagged claude.ai project or
thread goes there with no model; anything else is the project decider's (`RouterProjectDecider`: Jev first at 0.7, else
Sonnet through `claude -p`), whose stage shows on the message's pill. A project that fits nothing is proposed under the
composer (`RouterProjectProposal`, revised by Sonnet). The brief's entries are the one model of what needs you (no cards):
mark read and archive are Fjord changes with a Revert in the history drawer, kept with the Told marks in briefs.db. Each history entry keeps who decided (`decision.decider`) and a
correction (Send elsewhere, a different pick on an ask, a proposal you changed) as its outcome, for measurement.

### Live data

| Command | What it does |
| --- | --- |
| `--t3 [--watch]` | Prints what the Router reads of T3 (link, threads by group, what waits on you), read-only; `--watch` prints live changes. |
| `--check owner/repo` | Headless live sync of one repo; prints the inbox. |
| `--check-inbox` | Headless live sync with sample categories; prints every entry. |

### Updater

```sh
"build/Fjord.app/Contents/MacOS/Fjord" --update 0.1.0
```

Pretends to be version 0.1.0: checks for, downloads and verifies the latest release. Run it from the built bundle, not the debug binary.

### Tooling-only flags

- `--lifecycle` prints the app's idle state (sessions, how many are working, whether a window shows, Reduce Motion) for `scripts/idle-cpu.sh`.
- `--motion-script <steps> --quit-after` plays a scripted sequence of motions and quits, for `scripts/motion-trace.sh`.
- `--form-hook` is what Claude Code runs through `~/.claude/hooks/fjord-form.sh` when a session asks a question, wants a plan approved, or opens a permission prompt for any other tool (it only notes that one, prints nothing and leaves at once). Not for direct use.

## Tooling scripts

| Script | What it does |
| --- | --- |
| `scripts/build-app.sh` | Builds `build/Fjord.app` (see [Build and run](#build-and-run)). |
| `scripts/build-silod.sh` | Downloads the pinned Silo engine release (`scripts/silod.release`), verifies its SHA-256, sets the engine's code requirement, then assembles and signs the engine app embedded by `build-app.sh`. |
| `scripts/test.sh` | The test suite as CI runs it, output in `test.log`. |
| `scripts/generate-engine-client.sh --check` | Recreates the Swift types and canonical method wrappers from the checked-in Silo schema and fails if generated files drift. |
| `scripts/idle-cpu.sh` | Checks the release build's CPU stays under its limit at rest and with the window kept open, on the right edge and along the top, on demo data. Puts the bar on screen for minutes. |
| `scripts/motion-trace.sh` | Records the release build with `xctrace` while it plays a motion script, then reports hitches and signpost latencies; `--baseline FILE` stores or compares against a baseline. Takes the screen while it runs. Options are documented at the top of the script. |
| `swift scripts/make-icon.swift [--preview DIR]` | Draws `Resources/AppIcon.icns` and the layers of `Resources/AppIcon.icon`. |
| `scripts/migrate-to-fjord.sh` | A one-off for the owner's machine: moves Lookout's data, preferences, Keychain items and Claude Code setup over to Fjord. Not for users. |

### Regenerate the Silo client

`schemas/silo-api/schema.json` is copied from the canonical `silo-api` crate at the commit and SHA-256 recorded in `schemas/silo-api/manifest.json`. The snapshot must match the `schemaSha256` of the engine release in `scripts/silod.release`, and `build-silod.sh` fails when it doesn't. Copy `api/silo-api.schema.json` from that release's tarball, and update the snapshot and manifest together when Silo publishes a new API schema. The pinned quicktype renderer validates the schema dialect, integer formats, method metadata and typed method contracts before it writes generated Swift.

```sh
scripts/generate-engine-client.sh --check
scripts/generate-engine-client.sh --write
```

The first command checks the checked-in output. The second regenerates `Sources/Fjord/Generated/SiloAPI.swift` and `SiloMethods.swift`. `npm ci` uses the committed lockfile; Node and npm are generation-time tooling only.

`build-app.sh` embeds the pinned, prebuilt `silod` engine release (downloaded and checked by `build-silod.sh`) as a signed engine bundle and LaunchAgent plist. A regular Fjord launch never registers the agent. The Computers page first checks for an existing shared engine; the user must choose **Enable Silo Engine** before Fjord calls `SMAppService.agent.register()`. If macOS requires approval, Fjord opens Login Items in System Settings. Demo and test launches use `MockEngineClient`; ordinary launches start with an unavailable client until the engine connects. The socket defaults to `$HOME/.silo/engine.sock`; set `FJORD_SILO_SOCKET_PATH` to connect to another socket during development.

## Releasing

Push a version tag:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The `Release` workflow runs the tests, downloads the Silo engine release pinned in `scripts/silod.release`, builds a universal app around it (the engine inside is arm64 only) and publishes `Fjord-<version>.zip` and its `.sha256` to GitHub Releases. To ship a newer engine, publish its release in Silo, then update the version and tarball SHA-256 in that file.

Once Fjord is installed, it picks up later releases on its own. The updater installs a release only if its checksum matches and it is signed by the same certificate as the running copy.

## Signing certificate

Releases are signed with one self-signed certificate. That keeps the app's Accessibility access across updates, and lets the updater check a release is genuine. Set it up once:

Run `scripts/make-signing-cert.sh` once. It makes a self-signed `Fjord Dev` code-signing certificate, imports it into your login keychain, keeps its `.p12` in `~/.fjord-signing` (its password in the login keychain), and sets the repository secrets `SIGNING_CERT_P12` and `SIGNING_CERT_PASSWORD`. It stops if a `Fjord Dev` certificate already exists. Back the `.p12` up: existing apps refuse a release signed with another certificate, and everyone would have to update by hand once.

With the certificate in your keychain, `build-app.sh` signs local builds with it too.

**One-time transition from Fjord Computer.** Quit Fjord Computer. Run `scripts/make-signing-cert.sh`. Run `scripts/build-app.sh`, move `build/Fjord.app` to `/Applications/Fjord.app`, then run `scripts/migrate-to-fjord.sh` before launching Fjord and follow its output.

## Implementation notes

### Global shortcuts run synchronously on the main thread

Global shortcut actions run before their callback returns. Carbon hot keys target `GetApplicationEventTarget()`, which this app dispatches through the [main-thread application event loop](https://developer.apple.com/library/archive/documentation/General/Conceptual/Devpedia-CocoaApp/MainEventLoop.html); AppKit [guarantees that local and global event monitors run on the main thread](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html). [`MainActor.assumeIsolated`](https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:)) verifies the executor before performing the action synchronously. Mouse-button shortcuts still defer their handler, to leave the CGEvent tap callback before any window work.

### What the Router reads and writes

The Router reads the Claude desktop app's sessions, `~/.claude/projects` for what a working session is doing, and Claude Code's task list in `/private/tmp/claude-<uid>` for what a session left running. None of these is a public API; when a Claude update changes them, the Router says so and Triage keeps working.

Switching the Router on writes nothing into `~/.claude`: your words reach a thread as one `message.dispatch` to T3 (steering a running thread, ⌥Return queues; an unattended action always queues), and a queued message can be cancelled or edited in place.
