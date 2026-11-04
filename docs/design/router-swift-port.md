# Router: the Swift port of the delivery engine

Plan, 2026-11-04. The source is `poc/router` (contract: [EVENTS.md](../../poc/router/EVENTS.md); design:
[router-data-design.md](router-data-design.md)). What the owner agreed:

1. The daemon's core moves into the app in Swift. The Python fake page and the seeded fuzz harness stay as the reference. They
   drive the Swift core over the same JSON events, and it has to pass the same tests before it replaces anything.
2. The Chrome native-messaging bridge becomes a `--native-host` mode of the Fjord binary, and the app writes Chrome's manifest.
   Another agent is building this now. It uses the same framed-stdio-to-Unix-socket protocol as `native_host.py`.
3. The extension stays unpacked, with a fixed key.
4. The Router pill shows each state: sending, delivered, failed (with its cause, and a late "delivered after all"), paused (with
   its reason and one button), and tools (with Revert).
5. First-run setup fits on one screen.

## Scope

The engine is one rule: **only the page's own rows prove anything**. Everything that touches the page, its proofs and its
timing is ported line for line. Everything that decides or reads the Mac already exists in the app, so it maps onto that code.

| POC part | Becomes | Why |
|---|---|---|
| `routerd.py` `Core` (runs, sends, looks, watches, jump, replay, `done`, tools) | Swift engine, ported line for line | All the hard-won timing rules live here. The tests pin them |
| `board.py` (fold, `assign`, `new_rows`, loose words) | Swift engine | Pure. Proof depends on it |
| `do.py` (baseline, anchors, `proved`, `blocked`, `stranded`, `tool_args`) | Swift engine | Pure |
| `page.py` (events become Seen rows) | Swift engine | Pure |
| `store.py` (seen, intents, told, notes) | Swift engine, **same SQLite schema** | The Python tests and `router.py` read the file directly |
| `tell.py` fact diff and `plan` | Swift engine (`CourierTell`), pure | Small, and `Core.tell` has 28 tests. Turning facts into words stays in the app's brief (`RouterBrief`, `RouterDigest`) |
| `decide.py` (Jev 0.7, Sonnet 0.5, setup question 0.5) | **App**: `RouterJev.swift`, `RouterDispatcher.swift` | The app already decides with Jev. The engine never calls a model |
| `context.py` | **App**: `RouterContext` in `RouterDispatcher.swift`, built from the engine's Board snapshot | Same job |
| `look.py` (session files, registry, `pgrep`) | **App**: its existing local-session reading, fed to the engine as `local(...)` | The app already watches these files. The engine keeps the decisions (`waiting_app`, stranded, the 20 s grace) |
| `native_host.py` | `--native-host` mode (the other agent's work) | Done elsewhere |
| `routerd.py` server (socket, timers, `watch`) | Swift `CourierHost` actor | Glue specific to the app |
| `fake_page.py`, `tests/*`, `router.py` | Stay Python | They're the reference and the debug client |

### The seam

`RouterDispatcher` decides the target as it does today. Local sessions still go through `RouterSender.send`. A target that is a
claude.ai project or thread is handed to the engine instead:

```swift
enum CourierIntent {
    case send(words: String, project: String, thread: String?, continues: String? = nil)   // explicit target: no model
    case tool(name: CourierTool, args: [String: JSON])   // create_project, set_goal, set_instructions, add_repo, preapprove_folder
    case confirm(intentID: Int)                          // preapprove_folder's grant
    case correct(intentID: Int, project: String)
}
// CourierHost.submit(_:) -> Int (the intent id, after the 120 s duplicate check)
// CourierHost.updates: AsyncStream<CourierUpdate>
struct CourierUpdate { let intentID: Int; let state: CourierState; let cause: String?; let before: JSON?; let at: Date }
enum CourierState { case sending, taken, delivered, deliveredLate, failed, refused, paused, awaiting, toolDone, toolUnconfirmed }
```

The app gets three things back: the update stream (one per status or cause change of an intent, read from the same rows the
`intents` table holds), `board()` (a snapshot for `RouterContext` and the brief), and `tell()` (facts not yet told).

How the pill maps the states:

- `sending` and `taken` show as sending. `delivered` shows as delivered.
- `failed` shows its cause. A later `deliveredLate` replaces it with "delivered after all".
- `paused` shows the reason (signed out, the page changed, waiting for the Claude app, Chrome's tab not connected) with one
  button: Open Chrome, Sign in, or Show the Claude app.
- A tool shows Revert only when `before` was kept and a reverse exists (`set_goal`, `set_instructions`). Revert is just another
  `.tool` intent carrying `before`.

## File map (Sources/Fjord)

The prefix is `Courier`, which nothing in the app uses yet. Each file names the POC code it ports.

| File | Main types | Ports |
|---|---|---|
| `CourierJSON.swift` | `JSON` (an enum holding any JSON value, with dict/array/string helpers and Python-equal encoding) | Python's dicts |
| `CourierTypes.swift` | `CourierEvent`, `CourierCommand`, `Run` (a struct with the same field names, `Codable`), `Proof`, `Intent` | EVENTS.md shapes |
| `CourierStore.swift` | `CourierStore` (`import SQLite3`, WAL mode) | `store.py`, with its `SCHEMA` copied verbatim |
| `CourierPage.swift` | `enum CourierPage` (`seenRows`, `place`, `turning`) | `page.py` |
| `CourierBoard.swift` | `CourierBoard`, `enum CourierFold` (`start`, `step`, `finish`, `assign`, `newRows`, `loose`) | `board.py` |
| `CourierDo.swift` | `enum CourierDo` (constants, `baselined`, `anchor`, `proved`, `blocked`, `refusal`, `stranded`, `toolArgs`) | `do.py` |
| `CourierTell.swift` | `enum CourierTell` (`facts`, `plan`) | `tell.py`, apart from the wording |
| `CourierCore.swift` | `final class CourierCore`: state, `handle`, `connection`, `replay`, `done`, `local`, `say`, `tool`, `confirm` | `routerd.py` lines 94–760 and 1641–1980 |
| `CourierCoreRuns.swift` | `extension CourierCore`: `advance`, `advanceAll`, `awaitProof`, `finish`, `tick`, `jump`, `nextDeadline` | lines 760–1330 and 1743–1870 |
| `CourierCoreWatch.swift` | `extension CourierCore`: watched sends, `backToWatched`, `confirmLate`, `reconcileSends` | the watch rules in EVENTS.md |
| `CourierCoreTools.swift` | `extension CourierCore`: `advanceTool`, `stepTool`, `toolDone`, `already`, `reconcile` | lines 1330–1560 |
| `CourierHost.swift` | `actor CourierHost`: socket, timer, clocks, app API, update stream | `serve`, `link`, `wake` |
| `CourierTestMode.swift` | `enum CourierTestMode` (`--courier-test`) | none: the conformance bridge |
| `RouterCourier.swift` | the dispatcher's handoff to `CourierHost`, and the pill's view model | none |
| `RouterCourierPill.swift`, `RouterCourierSetup.swift` | the pill's views and the one-screen setup | none |

### Threading and clocks

`CourierCore` is a plain, non-`Sendable` class with synchronous methods, just like the Python `Core`. Keeping it synchronous is
what keeps ordering identical to the reference. Re-entrant `out` calls behave as they do in Python: a command is appended and
written, never awaited. `CourierHost` is an actor that owns the one core and serializes every input through it: socket lines,
the timer, app calls and the local-file feed. The UI reads only `CourierUpdate`s, on the main actor.

Clocks are injected as `struct CourierClock { var now: () -> Double; var uptime: () -> Double }`.

- In the app: `Date().timeIntervalSince1970` and `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`, which stands still while the Mac
  sleeps, as `time.monotonic` does on macOS.
- In the bridge: both come from the request.

The timer is one `Task.sleep` until `nextDeadline()`. It's re-armed after every input, and on firing it calls `tick()`. Wakes
from `wake_me` go through the same deadline set, as in Python. `kwatch` isn't ported: the app's file watching calls
`host.local(_:)`, then `recheckPauses()`.

### Socket and persistence

- `CourierHost` listens on `NativeHost.socketPath()`: `router.sock` in the app's support folder (`Fjord Dev` for a debug build),
  or `FJORD_SOCKET`. `AF_UNIX`, one JSON object per line, on a `DispatchSource` read loop. `--native-host` connects to it.
- A host's first line links it (`connection(true)`), and EOF unlinks it. As in `serve`, a probe connect refuses a second
  listener.
- `{"op": …}` debug lines (`dev_command`, `reload_tab`, `reload_extension`) are answered the same way, so `router.py` works
  against the app.
- The database is `router.db` next to the socket. The schema is the same string as `store.py`, append-only triggers included,
  and the JSON columns hold the same keys. `Run` is never stored: a restart rebuilds it through the same `RESUME` and
  `restarted` rules.

## The conformance bridge

`Fjord --courier-test --db <path>` runs a test-only mode. It reads JSON lines on stdin, writes JSON lines on stdout, and opens
no window. Every request carries the injected time: `{"id": n, "t": <wall>, "up": <uptime>, "op": …}`. Before each reply it writes
the commands the core sent meanwhile (`{"out": command}`) and the callbacks it fired (`{"reply": n, "event": …}`,
`{"finished": n, "intent": …}`).

| Op | Maps to |
|---|---|
| `handle {event}`, `connection {up, current}`, `local {local}` | the same `Core` methods |
| `say {message, project, thread}`, `tool {name, args}`, `confirm {intent}`, `correct`, `note`, `tell` | same. `say` and `tool` return a callback id |
| `tick`, `next_deadline` | same |
| `dev_command {kind, fields}`, `dev_cancel` | same. The reply callback comes as a `reply` line |
| `state` | dump: `runs` (every field, Python names), `watched`, `watch_open`, `watch_back`, `moves`, `unproved`, `stale_goal`, `unsettled`, `arrived`, `pages`, `linked`, `known`, `dev`, `closing`, `relinked`, `unheard_sends`, `claimed`, `board` |
| `set_run {id, field, value}` | test-only write into a run (4 tests in `test_do.py`, 3 in `test_routerd.py` do this) |
| `set_constant {name, value}` | whitelist: `KEPT`, `DEV_WAIT` (what `mock.patch` changes today) |
| `call {name, args}` | whitelist of internals the tests call: `advance_all`, `safely`, `acting`, `yielded`, `in_page`, `tab_held`, `tab_idle`, `cancel_send`, `finish`, `command`, `next_id`, `remember`, `recheck_pauses`, `ready`, `stale`, `goto`, `advance`, `start`, `tool_busy` |
| `pure {fn, args}` | `board.*`, `do.*`, `page.*`, `tell.*` functions, for the pure test files |

On the Python side, `poc/router/tests/swift_core.py` holds `SwiftCore`. It has the `Core` constructor's signature and starts one
bridge process for each core.

- **Clock.** It keeps the Python `Clock`, so `core.clock.t += 5` and `sleep()` work unchanged.
- **Database.** `core.db` is a Python `store.connect(path)` connection to the same file. `memory_db()` returns a temp-file path
  when switched.
- **State.** `runs`, `watched` and the other internals are properties that fetch `state` (cached until the next op). A run
  dict's `__setitem__` sends `set_run`.
- **Methods.** Unknown attribute calls go through `call`.
- **Commands.** `out` lines go to the fake page's `receive`. `page.pump(core)` then calls `core.handle` as it does today.
- **The switch.** `FJORD_CORE=swift` in `support.py` makes `world()` and the fuzz `Harness` build a `SwiftCore`, and a
  `conftest`-free `unittest` shim makes `board`, `do`, `page` and `tell` call `pure` for their functions.

### What can't go through the proxy

| Test | Why | What to do |
|---|---|---|
| `test_decide.py` (35), and any test passing `Models(jev=Spy…)` | Model calls aren't the engine's | Skipped under `swift`. The app's Jev tests cover deciding |
| `test_context.py`, `test_look.py`, `test_native.py` | They map to app code | Skipped under `swift`. Swift unit tests for the app side |
| `test_routerd.py:1367` (patches `routerd.watch`), `:1421` (patches `Core.connected`), `:1901` (patches `Core.tab_held`) | They replace a method | Rewrite each to reach the state through events if it can be reached that way. Otherwise mark it `@python_only` with a reason |
| Anything reading `core.lock`, `core.models`, `core.acc` or `core._board` | Python object identity | The `state` dump's `board` replaces `_board` and `acc`. The rest is `@python_only` |
| `serve` and `native_host` socket tests | Process glue | Swift `FjordTests`: `CourierHostTests` on a temp socket |

Every skip goes through one decorator, `@python_only("reason")`, so the uncovered set stays visible: `grep python_only`.

## Slices

The files in each slice are disjoint from the others'. `main.swift` gets one line, from slice 5.

| # | Slice | Files | Needs | Done when (with `FJORD_CORE=swift`) |
|---|---|---|---|---|
| 1 | Types, store, page, board | `CourierJSON`, `CourierTypes`, `CourierStore`, `CourierPage`, `CourierBoard` | none | `test_page.py` and `test_board.py` pass. A Swift test checks the schema is byte-equal to `store.SCHEMA` |
| 5 | Bridge and proxy | `CourierTestMode.swift`, its line in `main.swift`, `poc/router/tests/swift_core.py`, the switch in `support.py`, `python_only` | 1's type names (agreed on day one); the `pure` ops can start on stubs | The proxy runs `test_page.py` through Swift. `scripts/test.sh` still passes with the switch off |
| 2 | Do: proof and assignment | `CourierDo.swift`, `CourierTell.swift` | 1 | The pure parts of `test_do.py` and `test_tell.py` pass |
| 3 | Core: runs, sends, looks, watches | `CourierCore`, `CourierCoreRuns`, `CourierCoreWatch` | 1, 2, 5 | `test_routerd.py`, `test_do.py`, `test_tell.py` and `test_board.py`'s core tests pass, apart from `python_only` |
| 4 | Core: tools | `CourierCoreTools.swift` (with stubs in 3 until it lands) | 3's skeleton | `test_tools.py` passes |
| 6 | Fuzz | none new: fixes land in 3 and 4 | 3, 4 | `test_fuzz.py` passes both sweeps, plus 2,000 extra seeds once |
| 7 | Host | `CourierHost.swift`, `Tests/FjordTests/CourierHostTests.swift` | 3; the `--native-host` socket path | Socket link and unlink, `wake` and `tick` on a fake clock, restart replay from a real `router.db`, `router.py status` against the app |
| 8 | App seam and pill | `RouterCourier.swift`, `RouterCourierPill.swift`, a shot in `AppWindowShots.swift` | 7 (protocol only: it can start on a fake host) | Every pill state renders in `--window-shots`. The dispatcher hands a project target to the engine, and local targets are unchanged |
| 9 | First-run setup | `RouterCourierSetup.swift`, a shot | 7; the manifest writer from the native-host work | One screen with Chrome found, extension loaded (fixed key, unpacked path shown), profile picker off, tab connected and signed in. Each line is a live check with one button |

Order: 1 and 5 start together. Then 2, then 3, then 4. 7 starts once 3 compiles, and 8 and 9 start on 7's protocol. 6 is the
gate. Nothing in the app sends through the engine until 6 is green. After that, one live run of the POC's benchmark through the
app, and then `routerd.py` stops being run.

Each slice also adds a few Swift unit tests in `Tests/FjordTests/Courier*Tests.swift`, which run in `scripts/test.sh`. The Python
conformance run stays a separate script, `poc/router/tests/run_swift.sh`: it builds the debug binary, then runs `unittest` with
`FJORD_CORE=swift`. Only one test load runs at a time.

## Risks

- **Line-for-line fidelity.** `Core` is 2,000 lines of interlocking timing rules, and a paraphrased port will drift. Port each
  method under its Python name (in camelCase) and keep the comments. Do no refactoring until the fuzz gate is green.
- **JSON equality.** Python compares dicts, `None` and missing keys loosely, and `JSON` must do the same.
  - Use `nil` and `.null` as Python uses `None` and absent keys (`.get` returns `None` for both).
  - Integers and floats compare equal (`1 == 1.0`).
  - Keys come out in insertion order for the `state` dump.
- **Float time.** Deadlines are float seconds, with 50 ms rounding for wakes. Use `Double` everywhere and copy the same
  rounding (`math.ceil` on ms/50).
- **Proxy cost.** Every `core.runs` read is a round trip, and 3,200 lines of `test_routerd` do many of them. Cache `state` until
  the next mutating op. Expect the suite to run in tens of seconds, not seconds.
- **Re-entrancy.** In Python, the fake page's `receive` only queues and `pump` delivers. Keep that, or the order of events
  changes under the proxy.
- **Two writers on one SQLite file.** In tests, Python writes to `core.db` (5 places in `test_routerd.py`) while Swift holds it
  open. WAL mode and short transactions should cover it, and the bridge re-reads intents it caches (`unproved`, `chatted`)
  whenever `core.db` is written. Mark a test `python_only` if one still disagrees.
- **Clock in the app.** `CLOCK_UPTIME_RAW` must be what the POC measured as "uptime stands still while asleep". Check it with one
  live sleep before slice 8 ships.

## Stays Python for now

- `fake_page.py`, every test, `test_fuzz.py`, and `router.py` (the debug client).
- `decide.py` and its 60-message benchmark, as the reference for the app's Jev routing until the app reproduces those numbers.
  Moving that benchmark is a later slice.
- `look.py`'s session reading, until the app's reader is checked to give the same `local` input. Diff the two on the owner's
  machine once.
- `install_native.py`, until the app writes the manifest.
- `routerd.py`, which still runs during development until slice 6 is green and the live benchmark has passed through the app.
