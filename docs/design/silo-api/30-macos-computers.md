# 30 · macOS computers

Everything the engine API needs that is specific to macOS computers: the inventory and its
state machine, creation (restore image, install, provisioning, templates), the lifecycle rules
that differ from Linux, the engine-owned screen window, the remote screen path, the clipboard,
guest access, the bridge, the gaps and start at launch.

Shared lifecycle (`computers.*`), checkpoints (`checkpoints.*`), logs (`logs.*`) and the event
stream (`events.*`) are specified in their own sections. This section gives only the macOS
parameters, rules and errors those methods take, and points at them.

- **One API for both kinds** (80 §2 N1): the macOS inventory, creation and lifecycle are the
  macOS part of `computers.list`, `computers.create {kind:"macos"}` and
  `computers.start/stop/forceStop/delete` (10 §2-§4), and their event is `computers.changed`.
  `macos.snapshot`, `macos.create` and `macos.action` are historical source names, RETIRED by [95 §3](95-decisions.md#3-amendments-owner-2026-10-13-later). All clients, including Silo's Tauri UI, use only the canonical methods; no aliases or old-name dispatch remain.
- **`macos.*` keeps only what macOS alone has:** `macos.setup.retry`, `macos.template.delete`
  and `macos.display.connect/resize/stream/session`.

## Conventions

- **Host scope (NEW, justified by 95 §3 Linux hosts dropped):** Hosts are Macs only; they run both Linux and macOS computers under the Mac LaunchAgent, controlled by Fjord. Linux engine services, Debian/AppImage updates and headless Linux setup are out of scope. This section's macOS guest requirements remain unchanged.
- **No legacy (NEW, justified by 95 §3):** Stored keys and managed SSH aliases use `computerId`. Any required conversion runs once at engine launch through existing `runtime_migration` (20 `migration.*`); no name-keyed fallback or alternate migration path remains. Source bridge/Tauri names below document implementation seams and coverage, not supported alternate API names.

- **Silo** is `/Users/polarzero/code/projects/microsandbox-workspaces` at `94d81937`.
  - `src/…` means `app/SiloUI/src-tauri/src/…`.
  - `ui/…` means `app/SiloUI/src/…`.
  - `guest/…` means `app/SiloUI/src-tauri/guest/…`.
- **Docs:**
  - **MAC** is `docs/SiloUI-MACOS-COMPUTERS.md`, cited by section and line.
  - **CONN** is `docs/SiloUI-CONNECTIONS.md`.
  - **ENGINE-R** is `docs/research/macos-guest-engine-2026-10-09.md`.
  - **DISPLAY-R** is `docs/research/macos-remote-display-2026-10-10.md`.
- **Fjord** paths are relative to `/Users/polarzero/code/projects/lookout`. **BRIEF** is
  `docs/design/silo-api/00-brief.md`.
- **Errors:**
  - Today every macOS error is a plain sentence. Over the bridge it becomes `BridgeError`
    with code `internal` (`src/bridge_error.rs:104-108`), the macOS quit and update gates
    included (`src/macos_computers.rs:455-463`; `src/runtime/shutdown.rs:50-59`). Only the
    bridge's own refusals carry other codes: `unsupported_remote_operation` for an unknown
    method (`src/remote.rs:2241`; `src/macos_remote.rs:95`), `incompatible_version`
    (`src/remote.rs:2166-2177`), and `cancelled` when the controlling Silo starts quitting
    during a change (`src/remote.rs:1310-1314`). The codes are listed at
    `src/bridge_error.rs:6-15`. Wire codes are snake_case (`src/bridge_error.rs:4-15`;
    80 §2 N17).
  - The error lists below retain today's sentences for context. NEW contract, justified by 95 A-10: macOS refusal/guest/file failures use stable snake_case codes in `ErrorCode` and its fixtures (OQ7); existing snapshot `internal` mappings are not the new API guarantee.
- **Jobs:** long macOS work (create, Retry setup, Start, Stop, Delete, checkpoints) follows the
  job contract of 05 §4.2 E: it returns `{jobId}` in the `job:` space at once, reports
  `operations.job.progress` with `source: "macos"` and ends with `operations.job.finished`.
  NEW, justified by 95 A-31/§3 Queue: macOS work joins the shared operation queue (10 §6). A conflicting job waits, shown as “Waiting…” with Cancel, rather than being refused; cancelling it removes waiting work before admission. Admitted framework work retains existing cancellation limits (`NotCancellable`, 05 §4.2 F). Creation is cancelled by `computers.delete`, as today. Completed outcomes persist on disk across engine restart until a client acknowledges showing them (95 §3 Job results; 05 `operations.job.get`/`operations.job.acknowledge`).
- **Addressing:** per-computer methods take `computerId` and `deviceId?` (10 §0.2, flattened;
  80 §2 N16). Absent `deviceId` means this engine.
- **Main window only:** every local Tauri command below first refuses any window other than
  `main` (`src/macos_computers.rs:755-761`). That is a UI gate. The engine replaces it with
  its own client authorization, which is outside this section.

## 1. Availability and host requirements

- **Which hosts can run them:**
  - **Apple Silicon only.** The module builds the real engine only for
    `target_os = "macos"` on `aarch64`. Everywhere else it builds `unsupported.rs`
    (`src/macos_computers.rs:14-18`).
  - The snapshot then reports `supported: false` with "macOS computers need a Mac with
    Apple silicon." (`src/macos_computers.rs:51`, `651-665`).
- **Entitlement:**
  - On a Mac the binary must carry `com.apple.security.virtualization`
    (`src/macos_computers/engine.rs:241-268`), and the framework must report
    `VZVirtualMachine.isSupported` (`engine.rs:270-287`).
  - So `silod` must be signed with that entitlement: MAC §Development and signing,
    lines 479-486; ENGINE-R §Framework constraints, lines 54-58.
- **Process and thread:**
  - The VM, its installer and its view belong to the main queue of the process that owns
    them (ENGINE-R lines 66-68).
  - Framework calls run on the main thread through `on_main` (`engine.rs:142-183`),
    `on_main_patient` (`185-205`) and `run_on_main_thread` (`1434`, `1521`), so `silod` must
    run an AppKit main loop.
- **User session:**
  - A macOS VM host must run in a logged-in GUI session: a LaunchAgent works, a
    LaunchDaemon does not.
  - From macOS 15, the login keychain must also be unlocked (DISPLAY-R §C, lines 174-186).
  - This matches the owner's decision to run `silod` as a LaunchAgent (BRIEF line 9).
- **Running limit:**
  - The framework refuses a third running macOS guest (ENGINE-R lines 64-65). The error is
    reported as "macOS allows at most two macOS computers running at once on this Mac."
    (`engine.rs:43-44`, `125-135`).
  - Linux computers don't count toward the limit.
  - There is no cap on how many macOS computers exist (MAC §Behaviour, lines 42-44).

## 2. Inventory and state

### computers.list (macOS part)

- **Kind:** query.
- **Platforms:** macOS computer. The host must be Apple Silicon to have any; other hosts
  answer `supported: false`.
- **Status:** EXTENDED: tauri `read_macos_computers` (`src/macos_computers.rs:782-794`), bridge `macos.snapshot` (`src/remote.rs:266`; `src/macos_remote.rs:68-70`); NEW combined inventory and per-row `kind` (95 A-12; canonical owner/status in 10).
  - Tauri `read_macos_computers`: `src/macos_computers.rs:781-794`.
  - Bridge `macos.snapshot`: `src/remote.rs:266`, dispatched at `src/macos_remote.rs:68-70`
    through `state_for_remote` (`src/macos_computers.rs:918-923`). This source name is RETIRED; canonical `computers.list` handles both platforms (NEW, justified by 95 §3; 80 §2 N1).
- **Params:** `deviceId?` (10 §2). The macOS part takes nothing else.
- **Result:** the `macos` member of `computers.list`'s result is `MacosComputersState`
  (10 §2), unchanged.
- **Side effects:**
  - Loads the registry on first use (`ensure_loaded`, `src/macos_computers.rs:546-570`).
  - Re-reads the templates (`572-594`).
  - At most every 600 s, asks the framework for the newest macOS in the background, so
    `template.current` and `minDiskGiB` follow the build a new computer would get
    (`refresh_latest_build`, `622-643`).
- **Errors:** "Silo could not find its data folder." (`518-522`).
- **Shared section:** `computers.list` is owned by the `computers.*` section (10 §2). Its
  macOS rows are `MacosComputer` below.

#### Type `MacosComputersState` (EXISTS, `src/macos_computers.rs:104-114`; TS `ui/features/macos-computers/model/macos-computers.ts:61-69`)

| Field | Type | Meaning |
| --- | --- | --- |
| `supported` | bool | This host can run macOS computers |
| `unsupportedReason` | string \| null | Why not: no Apple Silicon (`:51`), or a missing entitlement or framework support (`engine.rs:270-287`) |
| `computers` | `MacosComputer[]` | In creation order (`store.rs:442`) |
| `template` | `TemplateSummary` \| null | The newest template on disk (`:588-592`) |
| `minDiskGiB` | u64 | The smallest disk a new computer may have. It is the size of the template a new computer would be copied from, and at least 32 (`:582-587`; `store.rs:14`) |

#### Type `TemplateSummary` (EXISTS, `src/macos_computers.rs:94-102`; TS `macos-computers.ts:53-59`)

| Field | Type | Meaning |
| --- | --- | --- |
| `macosVersion` | string | For example "26.6.2" |
| `build` | string | For example "25G83" |
| `current` | bool | This template is the one a new computer would be copied from: same base version, and the newest build when known (`:576-592`; `templates.rs:194-209`) |

#### Type `MacosComputer` (EXISTS, `src/macos_computers.rs:68-92`, filled at `155-178`; TS `macos-computers.ts:29-50`)

| Field | Type | Source and meaning |
| --- | --- | --- |
| `id` | string (UUID v4) | `store.rs:201`. The bridge refuses non-UUID ids (`src/macos_remote.rs:31-36`) |
| `name` | string | The Linux name rule (`src/runtime.rs:6204-6220`) |
| `cpus` | u64 | May be raised at install to what the restore image needs (`engine.rs:604-612`) |
| `memoryGiB` | u64 | The same as `cpus` |
| `diskGiB` | u64 | The size the guest really has after personalization (`provision.rs:356-359`) |
| `osVersion` | string \| null | `"<version> (<build>)"` from `restoreImage` (`store.rs:129-133`) |
| `state` | `State` | See the state machine |
| `progress` | f64 \| null | 0..1 while downloading and installing. Events about it are sent at most once a second (`:706-725`, `:52`) |
| `detail` | string \| null | The current step or a failure sentence. See the detail strings |
| `displayOpen` | bool | The engine's screen window for this computer exists (`:2235`, `:2232`, `:1805`) |
| `installed` | bool | macOS is on the disk (`store.rs:87`) |
| `setupComplete` | bool | All provisioning steps are done and no personalization is pending (`store.rs:67-71`) |
| `needsPersonalizing` | bool | A copy or fork that still has its source's credentials. It can't be started (`store.rs:257-260`) |
| `checkpoints` | `Summary[]` | Newest first. The type belongs to the `checkpoints.*` section (`src/macos_computers/checkpoints.rs:91-100`) |
| `checkpointOperation` | `Operation` \| null | `{kind, status:"running", stage}` (`checkpoints.rs:136-152`). The TS schema also allows `status:"failed"` and `error` (`macos-computers.ts:22-27`), which Rust never sends |
| `pendingRestore` | `{checkpointId, memory}` \| null | The next Start continues a Restore (`checkpoints.rs:121-125`) |

The TS schema marks `needsPersonalizing`, `checkpoints`, `checkpointOperation` and
`pendingRestore` optional (`macos-computers.ts:43-48`); Rust always sends them.

### State machine

`State` (EXISTS, `src/macos_computers/store.rs:21-36`) serializes in lowercase, with
`setting-up` hyphenated. The values are `preparing`, `copying`, `downloading`, `installing`,
`setting-up`, `stopped`, `starting`, `running`, `stopping` and `failed`.

The registry's own table is at `src/macos_computers.rs:187-213`. All transitions happen
under the registry lock. Framework callbacks and the 2-second watcher only move a computer
forward from a state they have just re-read.

| From | Event | To | Source |
| --- | --- | --- | --- |
| (none) | `computers.create {kind:"macos"}` admitted | `preparing` | `:978-1005` |
| `preparing` | A template matches and the copy starts | `copying` | `:1103-1106`, `:1191` |
| `copying` | The volume can't clone files; the copy is undone | `preparing` | `:1216-1218`, `:1123` |
| (none) | `checkpoints.fork` admitted | `copying` | `:2105` |
| `copying` (fork) | Checkpoint cloned, record saved | `setting-up` | `:2161-2177` |
| `preparing` | No template matches (or the copy fell back), download starts | `downloading` | `:1122-1134` |
| `downloading` | Image complete | `installing` | `:1154` |
| `installing` / `copying` | Files in place, record saved | `setting-up` | `:1170-1178`, `:1107-1119` |
| `setting-up` | Provisioning finished | `stopped` | `finish_workflow`, `:374-394` |
| any creation state | A step failed | `failed` + detail | `:384` |
| any creation state | Quit aborted it, macOS installed | `stopped` | `:386` |
| any creation state | Quit aborted it, not installed | `failed` + "Installation was interrupted. Delete this computer and create it again." | `:387`; `store.rs:18-19` |
| any creation state | Delete (cancel) accepted | removed. If removal fails: `failed` + message | `:1726-1731`, `:357-370` |
| `stopped` / `failed` | `macos.setup.retry` (action `setup`) | `setting-up` | `:1545-1571`; `store.rs:312-329` |
| `stopped` / `failed` | Start | `starting` | `:1351-1388`; `store.rs:253-270` |
| `starting` | Machine running | `running`, detail = memory-restore note or null | `:1405-1414` |
| `starting` | Start failed, machine released | `stopped` | `:1417-1423`, `:1430-1435` |
| `starting` | Start failed, machine still held | `stopping` + "The computer could not be stopped after it failed to start. Use Force stop." | `:1430-1458` |
| `running` / `stopping` | Stop | `stopping` (detail = confirm-in-screen note when the framework's stop request, the virtual power button, was used: setup incomplete or the SSH shutdown failed) | `:1646-1701` |
| `running` / `starting` / `stopping` | Force stop | `running` becomes `stopping`; `starting` and `stopping` keep their state; detail cleared | `:396-415`, `:1703-1712` |
| `stopping` | Stop or Force stop could not be issued | `running`, if it was `running` before | `:417-424`, `:1685-1688`, `:1706-1709` |
| `running` / `stopping` | Force stop failed, machine alive | `running` + message | `:426-435`; callers `engine.rs:1247-1254`, `:2306-2307` |
| `starting` / `running` / `stopping` | Guest shut down, or a host stop finished | `stopped` | `:1783-1810`; `engine.rs:87-97`, `1236-1239` |
| `starting` / `running` / `stopping` | Machine stopped with an error | `failed` + "The computer stopped unexpectedly. …" (the watcher's sentence); a host stop that ends in error sets the framework's description alone | `engine.rs:99-109`, `1240-1246`; `:2276-2282` |
| `stopping` | Machine still running after 20 s (the guest ignored the stop) | `running` | `:2313-2321`, `:55` |
| `stopping` | Machine gone, no callback | `stopped` | `:2325-2363` |
| `running` / `stopping` | Machine paused, nothing operating on it | unchanged; the machine is resumed and the detail cleared, or set to the paused-failure detail | `:2284-2299` |
| `running` / `stopping` | Machine paused, Restore not consumed | `stopping` (force stop; `running` becomes `stopping`) | `:2300-2310` |
| `running` / `stopping` | `checkpoints.restore` finished | `stopped`, detail cleared | `:2026-2033` |
| `stopped` / `failed` | Delete | removed (on error: `failed` + message) | `:1714-1767` |
| `starting` / `running` / `stopping` | Delete | refused: "Stop the computer first." | `store.rs:247-249` |

A checkpoint operation is not a state. The source conflict refusals below document today's ungated macOS code. NEW, justified by 95 A-31/§3 Queue: the engine queues conflicting work as “Waiting…” with Cancel; once admitted, it revalidates the existing state/setup preconditions. Queued status is shown from `operations.list.waiting` (10 §6; existing queue type `src/runtime/operation_gate.rs:119-125`), not a new macOS VM state. Queue reconstruction after restart is probe B-37 (05 §10 OQ25).

- **While one runs:**
  - The computer keeps its state.
  - It refuses Start, Stop, Force stop, Delete and a second operation with "A checkpoint
    operation is in progress on this computer. Wait for it to finish."
    (`:202-204`; `checkpoints.rs:40-41`).
- **Start is also refused when** (besides the state rules at `store.rs:261-269`):
  - macOS isn't installed: "Installation was interrupted. Delete this computer and create it
    again." (`store.rs:254-256`);
  - Quit or an update is under way: "Silo is quitting and stopping its computers. …" /
    "Silo is installing an update. …" (`:455-463`, `:1356`);
  - the computer is being deleted: "This computer is being deleted." (`:1363-1365`);
  - it needs personalizing: "This computer is not ready yet. Use Retry setup to finish it,
    or delete it." (`store.rs:16-17`);
  - a Restore was left unfinished: "A Restore of this computer did not finish. Restart Silo
    to settle it before starting the computer." (`:1461-1462`).

On load, an installed computer is `stopped`. A computer that isn't installed is `failed`
with the interrupted-install sentence (`store.rs:224-230`).

### Detail strings

`detail` is free text. These are every step and note string the code sets, so a client can
recognise them. Failure details are the sentence of whatever failed; the fixed ones are in the
state table.
They remain sentences; no new step enum is required by 95 A-12 (OQ8).

- **Steps of `setting-up`:**
  - Set through `Provision::say` (`provision.rs:110-115`): "Starting macOS for the first
    time", "Creating the account", "Starting macOS", "Finishing the account", "Preparing
    Recovery", "Turning off System Integrity Protection", "Checking System Integrity
    Protection", "Installing computer use", "Setting up the clipboard", "Updating Computer
    Use", "Personalizing the computer", "Checking the computer" and "Shutting down"
    (`provision.rs:145-535`).
  - "Stopping the computer" is set after a failure (`provision.rs:587`).
- **Inside "Installing computer use" and "Updating Computer Use":**
  - "Downloading LCU", "Downloading LCU (N%)", "Checking LCU", and the same three with
    "ChatGPT" (`guest_computer_use.rs:645-658`).
  - "Copying computer use to the computer" and "Copying the ChatGPT app to the computer"
    (`:364`, `:378`).
- **At the end of setup:** "Saving a template" (`src/macos_computers.rs:1261`).
- **While `running`:**
  - "Updating Computer Use: <step>" during an in-place update, <step> being "starting" or
    one of the sub-steps above (`guest_computer_use.rs:50`, `505-512`).
  - The memory-restore notes (`checkpoints.rs:750-766`).
  - "macOS is asking to confirm in the computer's screen. Confirm there, or use Force
    stop." (`src/macos_computers.rs:1575-1576`).
  - "The computer is paused and could not be resumed (…). Use Force stop." (`:2296`).
- **During a cancelled creation:** "Cancelling…" (`:1730`).
- **When personalization could not fill the disk:** "Silo could not expand the disk to N GiB,
  so the computer has M GiB. It is otherwise ready to start." The computer is `failed` but
  complete and startable (`provision.rs:340-346`, `365`; MAC lines 168-170).

### Setup steps

`SetupProgress` (EXISTS, `store.rs:55-71`) is persisted in `computer.json`, so a retry
resumes.

| Field | Meaning |
| --- | --- |
| `account` | The offline account, first-boot finalization and Recovery language are done (`provision.rs:215-250`) |
| `sip` | System Integrity Protection is off and verified (`provision.rs:144-181`) |
| `computerUse` | The ChatGPT app and LCU are installed (`provision.rs:182-191`) |
| `clipboard` | A no-op kept as a step (`guest_clipboard.rs:348-352`; `provision.rs:192-196`) |
| `needsPersonalizing` | A copy or fork still has its source's credentials (`provision.rs:135-137`, `256-366`) |

`complete` means all four are true and `needsPersonalizing` is false (`store.rs:67-71`).

> **NEW (proposed): expose `setup` in `MacosComputer`.**
>
> - Today the row only has `setupComplete` and `needsPersonalizing`, so a client can't
>   show which steps are left.
> - Required by: BRIEF lines 15 and 19 (add what's missing; the Computers tool). MAC
>   §Not covered yet, line 497, "status in the UI", is about computer use, so it backs only
>   the `computerUse` step.
> - Shape: the `SetupProgress` fields as they are.

### Event `computers.changed` (macOS part)

- **Kind:** subscription event, named in 05's event catalogue (05 §4.2 D; 80 §2 N1, N15).
  `macos.changed` is not an event name.
- **Status:** EXTENDED: existing Tauri event `silo://macos-computers-changed`; NEW unified platform envelope and subscription sequence number (95 A-4; 05 event catalogue). Source:
  (`src/macos_computers.rs:50`, `667-669`), listened to at
  `ui/desktop/macos-computers.ts:22`. It has no bridge event: remote controllers poll
  the bridge's `macos.snapshot`, `computers.list {deviceId}` in the API (MAC §On another Mac,
  lines 413-415). NEW remote delivery, justified by 95 A-4: the owner pushes state through Stream-class `events.subscribe`, relayed by the local engine (95 A-3; 05 §4.2 D).
- **Payload:** the whole `MacosComputersState`. The macOS part already carries its state
  today, so it keeps it; Linux changed-state events also carry the new state (NEW, justified by 95 A-4; 05 §4.2 D).
- **When it fires:**
  - after registry changes (`update`, `:672-685`, and explicit `emit` calls such as `:1001`);
  - after a template change (`:806`, `:1066`, `:1765`);
  - when the newest build is learned (`:645-649`);
  - for progress, at most once a second (`:706-725`).
- **Progress as a job:** the progress part is also `operations.job.progress` with
  `source: "macos"` and `data: {computerId, state, progress, detail, checkpointOperation}`,
  the fields of the row, at most once a second as today (05 §4.2 E item 4).
- **In the engine:** it is delivered through `events.subscribe` (05 §4.2 D), as the topic
  `computers.*`.
  - NEW, justified by 95 A-4: remote engines push this state through a Stream-class SSH subscription; clients receive it from their local engine (95 A-3; 05 §4.2 D).

### `computer.json` (the `Record`, EXISTS, `store.rs:73-116`)

| Field | Meaning |
| --- | --- |
| `schemaVersion` | 1. Other values are skipped at load (`store.rs:9`, `438`) |
| `id`, `name`, `cpus`, `memoryGiB`, `diskGiB`, `createdAt` (RFC 3339) | Identity and resources |
| `macAddress` | Random locally administered address, fixed for life (`engine.rs:309-316`). It must not change, because a memory state needs it (MAC line 246) |
| `restoreImage` | `{version, build}` of the installed or copied macOS, or null until creation picks one (`store.rs:86`, `210`) |
| `installed` | macOS is on the disk |
| `setup` | `SetupProgress` |
| `pristine` | Installed here and never started by the user since setup. Cleared by Start, Restore, copy and fork (`:1376-1380`, `:2022`, `:1203`, `:2099`) |
| `template` | The folder name of the source template, for a copy |
| `setupVersion` | The base fingerprint the guest has |
| `computerUseVersion` | The computer-use fingerprint the guest has. Missing means stale |
| `computerUseApproval` | `ask` or `auto`, as the computer-use step last applied it |
| `pendingRestore` | `{checkpointId, memory}` |
| `inheritedAccess` | A fork whose credentials are still in `inherited-access/` |

### Store

- **Root:** the app data directory. In Silo Dev it is
  `~/Library/Application Support/org.silo.dev` (MAC §Storage, lines 63-76).
- **Per computer:** `macos-computers/<id>/` (`store.rs:331-333`, `364-405`) holds:
  - `computer.json`, written atomically with fsync (`store.rs:407-420`);
  - `disk.img`, sparse raw (`store.rs:455-459`);
  - `auxiliary-storage.img`, `hardware-model.bin` and `machine-identifier.bin`;
  - `guest-access/` (mode 0700): `password`, `id_ed25519` and `.pub`, `known_hosts` and
    `askpass` (`guest_access.rs:50-52`, `60-63`, `98-156`, `281-307`);
  - `checkpoints/` (`checkpoints.rs:32`, `157-159`);
  - `inherited-access/` (`checkpoints.rs:37`, `834-836`).
- **Elsewhere:**
  - `macos-templates/` (see Templates);
  - `macos-restore-images/` (`store.rs:360-362`);
  - `macos-computer-use/`, the cached app and LCU archives (`guest_computer_use.rs:33`,
    `360`).
- **Logs:**
  - Setup logs are at `<app log dir>/macos-computers/<id>/runtime.log`, rotated at 1 MiB
    with 3 rotations (`setup_log.rs:1-8`, `19-23`, `35-43`).
  - Passwords are redacted (`setup_log.rs:59`).
  - Failed-Recovery evidence is kept beside them (`recovery.rs:113-270`).
  - Canonical `logs.query` serves them. Today's retired bridge name `runtime.logs` already dispatches macOS computer ids (`src/runtime_logs.rs:610-614`, `667-669`); no alternate name is retained (95 §3).
- **Not in the Linux registry:** macOS computers aren't entries in the MicroSandbox
  registry, so Linux lifecycle, health, backup and Connections code never sees them (MAC
  lines 78-80).
- **Shared names:** names are unique across both kinds.
  - A macOS create reserves its name against Linux names (`src/macos_computers.rs:983-984`;
    `src/computer_names.rs:23-42`).
  - Linux creation reads macOS names (`src/runtime.rs:4292`, `4358`).
  - Against a Linux name, or a name another creation holds, the error is "Computer names
    must be unique." (`computer_names.rs:13`, `35-39`); against an existing macOS computer
    it is "A macOS computer named '<name>' already exists." (`store.rs:169-174`).

## 3. Creation

### computers.create {kind:"macos"} (macOS part)

- **Kind:** job (05 §4.2 E). It returns at once, and the work continues in the background as
  state changes.
- **Platforms:** macOS computer, on an Apple Silicon host.
- **Status:** EXTENDED: tauri `create_macos_computer` (`src/macos_computers.rs:813-821`), bridge `macos.create` (`src/remote.rs:267`); NEW developer-tools provisioning (95 A-19; 00 dev-computer need; §Developer-tools provisioning; B-19 evidence there), Waiting/Cancel admission (95 A-31/§3) and durable acknowledged job outcome (95 §3; 05 job contract).
  - Tauri `create_macos_computer` (`src/macos_computers.rs:812-821`).
  - Historical bridge `macos.create` (`src/remote.rs:267`; `src/macos_remote.rs:71-76`) is RETIRED; clients call canonical `computers.create {kind:"macos"}` (95 §3; 80 §2 N1); the name change reuses existing creation behavior.
  - Controller Tauri `remote_macos_create` (`src/macos_remote.rs:141-152`).
- **Shared section:** `computers.create` is owned by the `computers.*` section (10 §3); the
  macOS kind takes these parameters.
- **Params:** `{kind: "macos", request: CreateRequest, deviceId?}` (10 §3; `CreateRequest`
  at `store.rs:136-145`). The bridge nests it as `{request: {...}}` (`macos_remote.rs:38-41`).
  - `name`: string. It must start with a lowercase letter and have at most 32 lowercase
    letters, digits or hyphens (`src/runtime.rs:6204-6220`). It must be unique.
  - `cpus`: u64, from 2 to the host's CPU count (`store.rs:10`, `175-180`;
    `engine.rs:289-307`).
  - `memoryGiB`: u64, from 4 to the host's memory minus 4 GiB (`store.rs:11-13`, `154-160`,
    `181-186`).
  - `diskGiB`: u64, from `max(32, minDiskGiB)` to 1024 (`store.rs:14-15`, `187-194`).
- **Result:** `{jobId}` (`job:<n>`, 05 §4.2 E) plus the new `MacosComputer` in state
  `preparing` (`src/macos_computers.rs:995-1004`). macOS create is the one job that also
  returns a row at once (05 §4.2 E item 3).
  - `operations.job.finished` ends the job when the creation workflow ends
    (`finish_workflow`, `src/macos_computers.rs:374-394`). Its `result` is empty: today
    nothing is returned at the end, and a failed creation is data in the row (`state:
    "failed"` and `detail`), read with `computers.list` (05 §4.2 E item 5). The end point
    keeps the existing workflow boundary; the outcome is saved to disk, survives restart and remains readable until a client acknowledges showing it (NEW, justified by 95 §3 Job results; 05 §4.2 E).
- **Progress and events:** `operations.job.progress` with `source: "macos"` (05 §4.2 E), and
  `computers.changed` (macOS part), through the states above.
- **Cancel:** `operations.cancel {jobId}` answers `NotCancellable` (05 §4.2 F). The creation
  is cancelled by `computers.delete`, as today (§4 Delete; 10 §3). NEW queue cancellation, justified by 95 A-31: a conflicting create waits as “Waiting…” with Cancel; cancelling before admission removes it from the queue, while an admitted framework workflow retains those existing cancellation limits (95 §3 Queue).
- **Gate:** NEW, justified by [95 A-31](95-decisions.md): macOS create enters the shared operation queue with its computer id. Ordinary operation conflicts wait and expose Cancel, not busy refusal (95 §3 Queue). Device-wide update/shutdown admission retains its explicit closed-admission contract (05 §6). Existing operation-gate types are `src/runtime/operation_gate.rs:69-125`; wiring the macOS workflow to them is new.
- **Errors** (returned by the call, before the job starts): validation sentences, for
  example:
  - "A macOS computer named 'x' already exists.";
  - "CPUs must be between 2 and N on this Mac.";
  - "Memory must be between 4 and N GiB on this Mac.";
  - "Disk size must be between N and 1024 GiB, as new computers are copied from a template
    of N GiB." (`store.rs:162-196`);
  - the name rule;
  - "Computer names must be unique." (`src/computer_names.rs:13`, reserved at
    `src/macos_computers.rs:983-984`);
  - the Quit and update gates: "Silo is quitting and stopping its computers. …" and "Silo
    is installing an update. …" (`src/macos_computers.rs:454-463`);
  - `runtime::shutdown::ensure_accepting_operations` (`src/macos_computers.rs:819`): "Silo
    is quitting and stopping its local computers. Wait for shutdown to finish."
    (`src/runtime/shutdown.rs:50-58`).
- **Semantics:**
  - The record is saved before the work starts, so a crash leaves a visible computer that
    reports the interruption (`:993-994`).
  - Admission and the Quit snapshot share one lock (`:475-493`).
  - Over the bridge it is a change method: one `operationId`, replayed on a lost
    connection, `startWithinMs` (CONN lines 146-147).
  - Apple's license allows two macOS VMs per Mac for development, testing and personal use.
    Silo states it in the form and doesn't cap the number (ENGINE-R §Apple's license terms,
    lines 80-106).

**Flow** (`run_creation`, `src/macos_computers.rs:1075-1179`):

1. `preparing`: the engine asks the framework for the newest supported macOS
   (`engine::fetch_latest`, `engine.rs:340-370`: `fetchLatestSupportedWithCompletionHandler`
   with a 60 s timeout).
2. **Copy instead of install** when a template matches (`templates::lease_matching`,
   `templates.rs:263-279`; the rule is `choose`, `templates.rs:190-209`). A template
   matches when it has the newest build and the current base, or, offline, the newest
   template of the current base. Then the engine:
   - reserves 4 GiB of expected writes against the free disk;
   - clones the files in state `copying`;
   - goes to `setting-up` with personalization pending (`src/macos_computers.rs:1100-1121`,
     `1183-1231`).
3. **Otherwise it installs:**
   - It records `restoreImage`.
   - It downloads, in state `downloading` with `progress`.
   - It installs, in state `installing` with `progress`.
   - It marks `installed` and goes to `setting-up` (`:1122-1178`).

### Restore image selection and download

- **Selection:** the framework picks the image (`fetchLatestSupported`), not Apple's public
  catalog. For example, on 2026-10-09 the catalog offered 27.0.1, but a 26.5 host was given
  26.6.2 (ENGINE-R lines 59-63).
- **File:** `macos-restore-images/<last URL segment>` (`store.rs:361`). The name must end
  in `.ipsw` and use only safe characters (`restore_image.rs:70-89`).
- **Resume:**
  - An interrupted download resumes from `<name>.partial` with an HTTP Range request.
  - It makes 4 attempts with a 60 s stall timeout (`restore_image.rs:1-31`, `182-213`).
  - A finished file is reused (`:191-193`).
  - Two creations take turns, so they never write the same partial (`DOWNLOAD_TURN`,
    `src/macos_computers.rs:1136-1145`, `1321`).
- **Pruning:**
  - A fresh download removes other images unless an install is reading them
    (`restore_image.rs:156-167`, `350-370`).
  - Once a template of a build exists for the current base, its image and partial are
    deleted, and the computer's log notes it (`src/macos_computers.rs:1289-1318`;
    `restore_image.rs:376-412`).
  - The image is downloaded again only when an install is needed: no usable template, a
    changed base, or a newer build (MAC line 76).
- **Cancellation:** a Delete during the download cancels it (`restore_image.rs:197-209`).

### Install

- `engine::install` (`engine.rs:586-699`).
- **Requirements and resources:**
  - It loads the image's requirements (`load_requirements`, `engine.rs:379-420`).
  - It raises `cpus` and `memoryGiB` to the image's minimum, and fails with "This Mac can't
    give this computer the CPUs and memory its macOS needs." outside the framework's range
    (`engine.rs:595-612`).
- **Files it writes:**
  - `hardware-model.bin` and a sparse `disk.img` (`set_len`, `store.rs:455-459`);
  - new auxiliary storage and a new machine identifier.
- **Machine:** it builds the configuration (`engine.rs:432-520`) and runs
  `VZMacOSInstaller` on the main thread.
  - It polls `progress.fractionCompleted` once a second.
  - Cancellation cancels the installer's progress and stops the VM (`engine.rs:617-719`).
- **Configuration**, the same for every boot (`engine.rs:432-520`):
  - `VZMacGraphicsDisplayConfiguration` at 2560×1600, 220 ppi;
  - virtio block disk;
  - NAT network with the record's MAC;
  - Mac trackpad and USB screen-coordinate pointer;
  - Mac keyboard;
  - virtio sound, output only, to the host;
  - an entropy device.
- **Duration:** about 3 to 4 minutes from a cached image (MAC §Verification, lines 523-525).

### Provisioning steps

`provision::run` (`provision.rs:45-72`; MAC §Provisioning for computer use, lines 296-403).

- The state stays `setting-up`, and the detail names the step.
- Machines started here have no screen window, except during the Recovery step
  (`provision.rs:6-7`, `477-505`; `recovery.rs:3-5`).
- A failed or cancelled run force-stops the machine before it reports
  (`provision.rs:67-70`, `580-594`).

1. **Offline account** (`provision.rs:215-250`; `offline_setup.rs:1-57`):
   - **First boot.** The engine boots once until the guest has a DHCP address, waits
     50 s, then force-stops it.
     - The wait doubles each time launchd's state is still missing, for up to 3 attempts
       (`provision.rs:21-27`, `221-242`, `509-531`).
   - **Offline edit.** It attaches `disk.img` with `hdiutil`, mounts the Data volume and
     writes:
     - the account `silo` (UID 501) and its 24-character random password
       (`guest_access.rs:23`, `28`, `181-193`; `offline_setup.rs:28`);
     - `.AppleSetupDone` and the Setup Assistant keys;
     - automatic login (`/etc/kcpassword`);
     - Remote Login;
     - no sleep and no screen lock.
   - **Detach.** It detaches the disk (`offline_setup.rs:46-57`).
   - **Second boot.** It logs in with the password. OpenSSH's `SSH_ASKPASS` reads a 0600
     file, so the password is never in an argument (`guest_access.rs:281-321`).
     - As root, it installs the key and `/etc/sudoers.d/silo`
       (`silo ALL=(ALL) NOPASSWD: ALL`, `offline_setup.rs:671-673`).
     - It fixes ownership and runs `diskutil apfs updatePreboot`
       (`provision.rs:654-699`; `offline_setup.rs:678-722`).
   - **Recovery language.** It sets `nvram prev-lang:kbd=en-US:0`, so Recovery comes up in
     English with a US layout (`provision.rs:30`, `425-448`).
   - **Shutdown** (`provision.rs:534-550`).
2. **SIP off through Recovery** (`recovery.rs:1-107`):
   - It boots with `startUpFromMacOSRecovery` (`engine.rs:769-775`, `951-954`) into the
     engine's "Setting up <name>" window (§5).
   - It reads the screen by capturing its own window and running Vision OCR
     (`engine.rs:1647-1660`; `guest_screen.rs:1-8`). Silo needs no Screen Recording
     permission for this.
   - It types the `csrutil disable` sequence. It answers only a password prompt that names
     `silo` on the Terminal's last line, and never types into an unreadable screen
     (`recovery.rs:11-14`, `38`). It gives up after 5 unreadable reads.
   - It makes 2 attempts. It sets the language again before the second only when Recovery
     came up in another language (`recovery.rs:24`, `50-107`).
   - It then boots normally and checks `csrutil status` over SSH (`provision.rs:175-181`,
     `458-475`).
   - Evidence of a failure goes to the log folder (`recovery.rs:113-270`):
     - before credentials were typed, the screen image and text;
     - after that, only the screen names.
3. **Computer use** (`guest_computer_use.rs:1-7`, `353-422`; MAC lines 333-371):
   - **Pins.** The engine downloads the pinned archives once per host and checks their
     size and SHA-256 (`guest_computer_use.rs:631-694`):
     - ChatGPT 26.930.61225 from `persistent.oaistatic.com`
       (`guest/macos/chatgpt-app-lock.json`);
     - LCU 0.11.0 from `github.com` (`guest/macos/lcu-lock.json`).
   - **Staging.** It stages the script, `pinned.json` and LCU in
     `/private/tmp/silo-computer-use` over `scp`. It copies the 689 MB app (its size in
     `chatgpt-app-lock.json`) only when `app-present` fails (`guest_computer_use.rs:364-391`).
   - **Apply.** It runs `zsh silo-computer-use.zsh apply --approval ask|auto`, with a
     30-minute timeout (`:393-404`). The script (`guest/macos/silo-computer-use.zsh:1-36`):
     - checks that SIP is off;
     - installs and verifies `/Applications/ChatGPT.app`: the code signature, bundle
       `com.openai.codex` and team `2DC432GLL2`;
     - installs LCU's runtime;
     - writes TCC rows for Accessibility and Screen Recording;
     - turns on Screen Sharing with its TCC rows (`:263-292`);
     - runs `lcu setup --agent all --allow-missing --cross-turn on --unattended --session
       direct --yes --approval <mode>` (`:331-336`);
     - installs a reconcile LaunchAgent;
     - writes a receipt at `~/Library/Application Support/Silo/computer-use-receipt.json`
       (`:82-87`).
   - **Approval mode.** It comes from the `computerUseAutoApproval` setting at the moment
     of setup (`src/computer_use.rs:196-232`; `provision.rs:184-189`).
4. **Clipboard:** nothing is installed (`guest_clipboard.rs:348-352`).
5. **Personalization**, for a copy or fork only (`provision.rs:256-366`;
   `personalize.rs:1-60`; MAC lines 145-186):
   - It logs in with the source's key and runs one root script. The secrets arrive on
     stdin. The script:
     - sets the new password and `kcpassword`;
     - creates new host keys;
     - sets `ComputerName`, `LocalHostName` and `HostName` from the name;
     - clears `~/Library/Keychains`;
     - expands the APFS container if the disk was made larger;
     - replaces `authorized_keys` last.
   - It reboots and checks:
     - `csrutil status`;
     - LCU's receipt;
     - that `/dev/console` is owned by `silo` (`provision.rs:388-413`, `626`).
6. **End of setup:**
   - The computer shuts down, then a template may be saved (`src/macos_computers.rs:1235-1254`).
   - The whole run takes about 9 minutes for a fresh install, and about a minute for a copy
     (MAC lines 31-32, 526-529).

### Developer-tools provisioning (NEW, part of macOS setup)

**Required by:** [95 A-19](95-decisions.md#1-owner-decisions) GitHub/push/editor parity and [00 §What Fjord will use the engine for](00-brief.md#what-was-decided-owner-2026-10-13), the long-lived macOS dev computer with Xcode and LCU.

The current template has no working Git, Git LFS or Xcode command-line tools: `/usr/bin/git` is Apple's shim and exits 1, `xcode-select -p` has no active developer directory, no real Git/LFS executable was found, and a public HTTPS clone fails locally before network transport. These are observed absences, not a GitHub network failure ([macos.md Follow-up §B-19](probes/macos.md#b-19--settled-for-template-tooling)). Existing `provision::run` covers account, SIP, computer use and personalization, without this tools step (`src/macos_computers/provision.rs:45-72`; §3 above).

Add developer-tools provisioning to `computers.create {kind:"macos"}` / `macos.setup.retry` before declaring developer setup complete or saving a ready template. It must supply working Git and Git LFS plus Xcode command-line tools and an active developer directory, then verify `git --version`, `git lfs version` and `xcode-select -p` inside the guest. Full Xcode availability is required for Fjord's dev-computer workflow; its distribution, version selection, licensing/user steps and unattended install mechanism remain OPEN during implementation (B-34). Do not claim that command-line tools install full Xcode. Package source, pins, progress, cancellation and retry mechanics for this NEW step also remain B-34. No additional public method or status enum is added; use setup detail/progress and existing retry boundaries (§2–3; 95 A-12/A-19).

### macos.setup.retry

- **Kind:** job (05 §4.2 E). Today's command returns once the setup is admitted
  (`begin_setup`, `src/macos_computers.rs:1545-1571`), and setup runs on its own thread.
- **Platforms:** macOS computer.
- **Status:** EXTENDED: tauri `macos_computer_action` action=`setup` (`src/macos_computers.rs:824-835`), bridge `macos.action` (`src/remote.rs:268`; `src/macos_remote.rs:77-83`); NEW developer-tools provisioning (§Developer-tools provisioning; 95 A-19; 00 dev-computer need), Waiting/Cancel admission (95 A-31/§3) and durable acknowledged job outcome (95 §3).
  - `macos_computer_action` with `action: "setup"` (`src/macos_computers.rs:823-835`,
    `1332`).
  - Historical bridge `macos.action` with `setup` (`src/macos_remote.rs:77-83`) is RETIRED; clients call canonical `macos.setup.retry` (NEW, justified by 95 §3; 80 §2 N1).
- **Params:** `computerId`, `deviceId?`.
- **Result:** `{jobId}` (`job:<n>`, 05 §4.2 E).
  - `operations.job.finished` ends the job when the setup workflow ends (`finish_workflow`,
    `src/macos_computers.rs:374-394`; same existing workflow boundary as create). Its
    `result` is empty: the source Tauri command returns none. The old `macos.action` result shape is retired with that method name (95 §3); clients observe state with canonical `computers.list`/events.
  - A failed setup is data in the row (`failed` + `detail`), read with `computers.list`.
- **Progress and events:** `operations.job.progress` with `source: "macos"`, and
  `computers.changed` (macOS part).
- **Cancel:** NEW queue behaviour, justified by 95 A-31: conflicting setup waits as “Waiting…” with Cancel; cancelling before admission removes it from the queue. Admitted setup remains `NotCancellable` under its existing framework limitations (95 §3 Queue) (05 §4.2 F).
- **Gate:** NEW shared operation queue admission keyed by computer id (95 A-31; `src/runtime/operation_gate.rs:69-125`).
- **Errors:** from `setup_allowed` (`store.rs:312-329`) and `begin_setup`
  (`src/macos_computers.rs:1545-1559`):
  - "Installation was interrupted. …";
  - "This computer is already set up.";
  - "This computer is already being set up.";
  - "Stop the computer before setting it up.";
  - "macOS is still being installed on this computer.";
  - "This computer is being deleted.".
  - Also the Quit and update gates.
- **Semantics:**
  - It resumes at the first unfinished step (`provision.rs:134-210`).
  - It is the only way forward for a copy or fork that waits for personalization
    (MAC lines 179-183).
  - The new API name is proposed because "setup" is macOS-only (BRIEF §Shared domains).
    The old `macos.action` dispatch is removed; Silo's Tauri UI moves to this canonical method (NEW, justified by 95 §3).

### Setup fingerprints

- **Base version** (`templates::setup_version`, `templates.rs:98-103`):
  - A truncated SHA-256 (8 bytes, hex) of `offline_setup::setup_inputs()` and
    `SETUP_REVISION` (`offline_setup.rs:655-666`; `templates.rs:122-133`).
  - The inputs are the finalization script, the sudoers entry and a revision number.
- **Computer-use version** (`templates.rs:109-120`): the hash of the two lock files, the
  guest script and the approval mode (`guest_computer_use.rs:306-309`).
- **Stale:** a computer is stale when its `computerUseVersion` differs from the hash for its
  own `computerUseApproval`, or is missing (`store.rs:119-127`).
- **Checkpoints:** a checkpoint keeps the computer-use version it was taken with. Restore
  and fork give it back (`src/macos_computers.rs:2020`, `2101`; MAC lines 112-113).
- **In the API:** neither fingerprint is in `MacosComputer` today.
  - NEW (proposed): add `computerUseStale: bool` to `MacosComputer`.
  - Required by MAC line 497 ("status in the UI") and BRIEF line 20 (a long-lived dev
    computer with LCU).

### In-place computer-use updates

- **Status:** EXISTS. It is internal and has no method. `guest_computer_use::update_in_background`
  (`guest_computer_use.rs:430-456`) is called after every successful Start
  (`src/macos_computers.rs:1414`).
- **Rules:**
  - It runs only when setup is complete and the version is stale
    (`guest_computer_use.rs:424-428`).
  - It waits up to 600 s for SSH (`:46`, `497-500`).
  - It shows the detail "Updating Computer Use: <step>".
  - It records the new version only if the same Start still owns a running or stopping
    computer
    (`src/macos_computers.rs:286-313`).
  - Stop, Delete, a checkpoint operation, a new Start or Quit ends it. Delete waits up to
    60 s for it (`guest_computer_use.rs:47-48`, `146-165`, `458-461`).
  - A failure only logs, and the update runs again at the next Start (`:522-544`).
- **Doc gap:** MAC line 497 says "nothing triggers" an upgrade of the pinned app or LCU in
  existing computers. That is out of date: the code above does it, and MAC lines 121-129
  describe it.
- NEW `computerUse.approval` for macOS (§10) reuses this path.

### Templates

- **Folder:** `macos-templates/<build>-<base>-<computerUse>/` (`templates.rs:137-153`). It
  holds:
  - APFS clones of `disk.img`, `auxiliary-storage.img` and `hardware-model.bin`;
  - `template.json` (`Meta`, `templates.rs:48-64`), with fields `schemaVersion`,
    `macosVersion`, `build`, `setupVersion`, `computerUseVersion`, `diskGiB`, `createdAt`
    and `sourceComputerId`;
  - `template-access/` (0700), the source's password and key (`templates.rs:485-529`).
  - The folder is built under a `.partial-` name and renamed (`templates.rs:434-483`).
- **Qualification** (`eligible`, `templates.rs:392-399`). The computer must be:
  - installed, with a base version and complete setup;
  - `pristine`;
  - not a copy itself, and with a restore image.
  - Exception: a copy of a stale template, once updated, refreshes it when its disk is the
    template's size and the build and base match (`templates.rs:401-425`;
    `src/macos_computers.rs:1242-1251`).
- **`pristine`:** set at creation (`store.rs:213`). Start clears it, and so do Restore, copy
  and fork (§2).
- **Copy:**
  - It first checks the requested disk: "This macOS template needs at least N GiB of disk.
    Create the computer again with a larger disk." (`templates.rs:544-552`).
  - It clones the three files and writes a new `VZMacMachineIdentifier`
    (`engine.rs:320-323`).
  - It grows `disk.img` if the request is larger (`templates.rs:557-596`).
  - A non-APFS volume falls back to an install (`CopyError::Unsupported`,
    `templates.rs:598-612`; `src/macos_computers.rs:1215-1218`).
- **Free space:** copies keep 5 GiB free and reserve 4 GiB each
  (`templates.rs:36-39`, `666-712`).
- **Personalization and disk growth:** see Provisioning step 5. Growth uses
  `diskutil apfs resizeContainer` in the guest, and the record keeps the measured size
  (`personalize.rs:66-98`; `provision.rs:291-359`).
- **Keeping only the newest:**
  - Saving a template prunes the others under the same lock, except those leased by an
    in-flight copy and those a computer awaiting personalization depends on
    (`templates.rs:309-343`, `475-482`; `src/macos_computers.rs:596-620`).
  - Pruning runs again when any creation or Retry setup ends (`:1062-1063`) and after
    Delete (`:1764`).
- **What templates enable:** copies make the second computer take about a minute instead of
  about fifteen (MAC lines 28-33). A pre-installed image can't be shipped: the license
  forbids redistributing macOS (MAC lines 204-209).

### macos.template.delete

- **Kind:** command.
- **Platforms:** macOS computer host.
- **Status:** EXTENDED: tauri `delete_macos_template` (`src/macos_computers.rs:798-810`); NEW remote control (95 A-14). There
  is no bridge method today; remote control is NEW, justified by 95 A-14: controllers can manage everything on the owner (MAC lines 419-420 describe the old local-only limit).
- **Params:** `deviceId?: string`, NEW remote owner selection justified by 95 A-14; omitted means local owner (80 §2 N16).
- **Result:** none. A `computers.changed` event (macOS part) follows.
- **Errors:**
  - "A computer is being copied from the template. Wait for it to finish.";
  - "A computer is still being set up from the template. Finish or delete it first."
    (`templates.rs:347-374`);
  - unsupported host;
  - Quit gate.
- **Semantics:**
  - It removes every template folder and leftover partials.
  - Computers made from a template keep working (`src/macos_computers.rs:796`).
  - Delete never removes the template (MAC lines 52-55).
- **Remote:** NEW bridge exposure, justified by [95 A-14](95-decisions.md); Change-class through the controller's local engine (95 A-3). Existing local template-delete semantics stay the same.

## 4. Lifecycle specifics

### computers.start / computers.stop / computers.forceStop / computers.delete (macOS part)

- **Platforms:** macOS computer. The methods are owned by the `computers.*` section (10 §4,
  §3); this is their macOS part.
- **Status:** EXTENDED: existing action commands/bridge below; NEW macOS Waiting/Cancel admission (95 A-31/§3; canonical statuses in 10). Existing adapters:
  - Tauri `macos_computer_action(id, action)` (`src/macos_computers.rs:823-835`). `Action`
    is kebab-case: `start`, `stop`, `force-stop`, `delete`, `setup` (`store.rs:38-47`).
  - Bridge `macos.action {computerId, action}`, class `change`
    (`src/remote.rs:268`; `src/macos_remote.rs:77-83`). It returns the owner's
    `MacosComputersState` today. Its old dispatch/result entry point is RETIRED; clients call only the canonical methods below (95 §3; 80 §2 N1). This renames existing action behavior; the queue is the NEW part.
  - Controller Tauri `remote_macos_action` (`:155-166`).
- **API names, one per action:** `start` → `computers.start`, `stop` → `computers.stop`,
  `force-stop` → `computers.forceStop` (refused on Linux, 10 §4), `delete` →
  `computers.delete`, and `setup` → `macos.setup.retry` (§3).
- **Params:** `computerId`, `deviceId?` (10 §0.2).
- **Kind and result:**
  - `computers.start`, `computers.stop` and `computers.delete` are jobs (05 §4.2 E). Each
    returns `{jobId}` (`job:<n>`) at once. `operations.job.finished` comes when today's
    command returns: Start once the machine runs or the start failed (`:1351-1425`); Stop
    once the stop request is issued, the row then moving through `stopping`
    (`:1662-1701`); Delete once the folder is removed (`:1714-1767`), or, in a creation
    state, once the cancel is marked (`:1726-1731`). Its `result` is empty: the Tauri
    command returns none (`:829`). Old `macos.action` is not exposed; clients read canonical state/events. A refusal below is the job's `error` (05 §4.2 E item 5; 95 §3).
  - `computers.forceStop` stays a command (10 §4), result none; clients read `computers.list`/events. No old `macos.action` result path is retained (95 §3).
- **Progress and events:** `operations.job.progress` with `source: "macos"` (05 §4.2 E), and
  `computers.changed` (macOS part).
- **Cancel/queue:** NEW, justified by [95 A-31](95-decisions.md): macOS work joins the operation queue keyed by computer id (`src/runtime/operation_gate.rs:69-125`). Conflicting jobs wait, shown as “Waiting…” with Cancel, rather than returning busy refusals; cancelling before admission removes the waiting job. Admitted framework work retains existing cancellation limits, including Delete's creation-cancel path (95 §3 Queue). Gate visibility is distinct from screen input; there is no GUI-driver lease (95 A-8).
- **Gates:** Start and Setup check the Quit gate first (`src/macos_computers.rs:831-833`,
  `936-941`). Every action
  loads the registry (`:1325-1334`).

**Start (macOS rules)** (`src/macos_computers.rs:1351-1425`):

- **Preconditions:** `start_allowed` (`store.rs:253-270`), no checkpoint operation, no
  unfinished Restore, not deleting.
- **Pristine and Restore:** it clears `pristine`. It continues a pending Restore from memory
  or from disk (`checkpoints.*` section; `src/macos_computers.rs:1393-1404`, `1481-1543`).
- **Disk image:** it detaches any host attachment of the disk first (`:1403`).
- **Retries:** it retries up to 6 times, 2 s apart, while the previous machine still holds
  the auxiliary storage lock (`engine.rs:839-879`).
- **No window:** Start opens no window, locally or remotely (MAC line 425;
  `src/macos_computers.rs:1351-1425` never calls `show_display`).
- **After success:** it starts the in-place computer-use update.
- **Third computer:** a third start fails with "macOS allows at most two macOS computers
  running at once on this Mac." (`engine.rs:43-44`, `125-135`). The computer goes back to
  `stopped`, or stays `stopping` while the framework still holds its machine
  (`src/macos_computers.rs:1417-1435`). The limit is the owner's (MAC line 421-422).

**Stop: SSH or the power button** (`src/macos_computers.rs:1573-1701`):

- **With setup complete:** it runs `echo SILO_SHUTDOWN; sudo -n /sbin/shutdown -h now` over
  SSH with a 15 s timeout. It counts only if the marker came back (`:1579-1609`).
- **Otherwise, or if SSH fails:** it presses the virtual power button
  (`VZVirtualMachine.requestStop`, `engine.rs:1137-1157`). macOS then asks for confirmation
  on its screen, and the row says so (`src/macos_computers.rs:1575-1576`).
- **A refused request:** after 20 s it reverts to `running` (`:2313-2321`).
- **Errors:**
  - "This computer isn't running.";
  - the checkpoint busy sentence;
  - "This computer can't be asked to stop right now. Use Force stop.".

**Force stop:** `VZVirtualMachine.stop` (`engine.rs:1205-1262`). The errors are "This
computer isn't running.", the checkpoint busy sentence and "This computer can't be force
stopped right now." (`src/macos_computers.rs:397-415`, `1703-1712`).

**Delete:**

- **In a creation state:** it cancels the creation and removes the computer
  (`store.rs:239-251`).
- **When stopped or failed:**
  - It closes the screen window.
  - It waits for any computer-use update.
  - It detaches the disk and removes the folder, checkpoints included
    (`src/macos_computers.rs:1714-1767`; MAC line 264).
- **Refused** while starting, running or stopping: "Stop the computer first.".
- **Other refusals:** the checkpoint busy sentence, "This computer no longer exists.",
  "This computer is already being deleted." (`src/macos_computers.rs:1718-1737`), and
  "Computer Use is still being updated in this computer. Try deleting it again in a
  moment." (`guest_computer_use.rs:155-160`).

**Quit**, the engine's shutdown (`stop_all`, `src/macos_computers.rs:2421-2555`; called
from `src/runtime/shutdown.rs:108-111`):

1. It closes admission (`src/macos_computers.rs:2462`).
2. It aborts creations, setups and checkpoint operations while keeping their files
   (`:2392-2395`, `2486-2490`).
3. It waits up to 30 s for starts and operations to settle (`:2493-2501`).
4. It asks each running guest to stop, using SSH when at least 2 s of the ≤ 8 s budget
   remains, otherwise the power button (`:2502-2518`, `1620-1629`).
5. It waits up to 60 s, never into the last 8 s before the deadline (`:1611-1618`).
6. It force-stops what is left and waits 8 s more (`:2541-2554`).
7. It detaches every computer's disk image, except those a creation or setup still owns
   (`:2431-2453`).

- **Result:** a creation in progress shows as failed on the next launch
  (MAC lines 59-61).
- **Today's updates** refuse while any macOS computer is busy (`src/macos_computers.rs:465-472`, `505-510`; `src/updates.rs:811`, `825`, `839`).
- **Engine contract (NEW, justified by [95 A-2/A-6](95-decisions.md)):** Client Quit offers Cancel / Keep running / Stop and quit. `computers.list` exposes running rows; Keep running calls `engine.disconnect`; Stop and quit calls `computers.stop`, waits for stopped state, then disconnects (05 §6.2). Client updates/crashes never call `stop_all` and leave `silod` running.
- **Engine updates** save running macOS machines with the existing pause/saveMachineState and disk/auxiliary-storage capture path, then restore memory and resume after engine replacement (05 `engine.update.prepare`, code citations and probe B-30 there). This replaces today's running-computer update refusal with a save/resume requirement. Unsupported or failed memory capture refuses preparation; it never silently cold-boots the run (95 A-6).
- Explicit engine/session shutdown still owns `stop_all`; `engine.shutdown {reason: "update", stopComputers: false}` requires completed saved-state preparation and does not request guest shutdown (05 §6).

**Crash behaviour:**

- A Fjord crash only disconnects its client; `silod` continues running its VMs (NEW, justified by 95 A-2). A crash of the VM-owning engine still turns its macOS computers off abruptly (MAC lines 488-489; ENGINE-R lines 66-68); the decision does not claim engine-crash survival.
- **On the next launch:**
  - Installed computers load as `stopped`, and uninstalled ones as `failed`
    (`store.rs:224-230`).
  - Interrupted checkpoint folders are swept, and interrupted Restores are settled from
    their journal (`src/macos_computers.rs:524-570`).
  - A creation interrupted after install shows Retry setup (`setup_allowed`,
    `store.rs:312-320`).
  - Disk images left attached are detached before the next boot and at Quit
    (`offline_setup.rs:145-151`; `src/macos_computers.rs:1403`, `2427`).
- **With `silod`:** a crash of Fjord or of the Tauri UI doesn't touch the VMs; only a crash
  of `silod` does (BRIEF lines 9, 16).

## 5. Display

The owner's decision (BRIEF line 16): the engine owns the VM and opens its own native
`VZVirtualMachineView` window when a client asks. Fjord doesn't embed it.

Today that window is a Tauri webview window whose page is `about:blank`, with the native view
laid on top (`src/macos_computers.rs:2209-2241`). In `silod` it becomes an engine-created
`NSWindow`. Everything below that isn't Tauri-specific carries over as is.

### display.show (macOS computer, local)

- **Kind:** command.
- **Platforms:** macOS computer on this engine's host. The Linux viewer is specified in the
  `display.*` part of the Linux sections. The remote macOS path is below.
- **Status:** EXTENDED: tauri `open_macos_display` (`src/macos_computers.rs:838-846,2196-2203`); NEW engine Dock/⌘-Tab activation only while a VM window is open (95 A-21). Existing display behavior below is reused.
- **Remote route:** the current bridge has no native owner-window-opening method; its `macos.display.*` methods expose the VNC path instead (`src/remote.rs:269-271`; MAC lines 425-428).
- **Params:** `computerId`.
- **Result:** none.
- **Errors:**
  - "Start the computer to open its display." when not `running` (`:2199-2201`);
  - "Silo could not open the display.";
  - "Could not focus the display.";
  - "This computer isn't running." (`engine.rs:1459`);
  - unsupported host;
  - the Quit gate (`:844`).
- **Window** (`:2209-2241`; `engine.rs:1449-1516`):
  - **One window per computer** (label `macos-display-<id>`, `:751-753`). A second
    `display.show` brings it forward and focuses it.
  - **Title:** the computer's name. The size is 1440×900, at least 640×400, resizable.
  - **Toolbar:** "Paste into Computer" and "Copy from Computer", labels only and not
    customizable (`engine.rs:1325-1429`).
    - Outcomes show in the window subtitle for 5 s (`guest_clipboard.rs:287-310`).
    - The window has no clipboard keyboard shortcuts, because the guest owns ⌘C/⌘V
      (MAC lines 393-399).
  - **View:** `VZVirtualMachineView` with:
    - `capturesSystemKeys = true` (`engine.rs:1479`);
    - `automaticallyReconfiguresDisplay = true`, so the guest display follows the window
      (`engine.rs:1480`; MAC line 50);
    - constraints to the content layout guide, so the screen fits below the title bar and
      toolbar, including in full screen (`engine.rs:1484-1509`);
    - first-responder status (`engine.rs:1510`).
    - If an earlier view existed, it is detached first (`engine.rs:1473-1476`).
  - **Graphics and sound:**
    - Apple's paravirtualized GPU (`VZMacGraphicsDeviceConfiguration`, Metal in the guest;
      `engine.rs:462-471`; MAC lines 45-49).
    - Virtio sound playing through the Mac's output (`engine.rs:503-507`; MAC lines 45-49).
    - There is no audio input device.
  - **Command access:** today the page matches no capability, so the window can't call
    commands (`:2218-2219`). An engine `NSWindow` has no page at all.
- **Semantics:**
  - Closing the window detaches the view and keeps the computer running
    (`:2229-2234`; `engine.rs:1518-1533`).
  - A stopped or failed machine and Delete close the window (`:1792`, `1744`).
- **Engine notes:**
  - The window opens on the screen of the GUI session `silod` runs in. For a remote
    client, it opens on the owner (see §5 remote).
  - NEW, justified by [95 A-21](95-decisions.md): `silod` switches to regular activation while any VM window is open (Dock and ⌘-Tab), and accessory activation when the last closes (05 §3.6; qualification B-3).

### display.close (macOS computer, local)

- **Kind:** command.
- **Platforms:** macOS computer.
- **Status:** EXTENDED: today the window opened by tauri `open_macos_display` detaches its view on close (`src/macos_computers.rs:838-846,2229-2234`), and internal `close_display` destroys it (`:2243-2250`). NEW client-requested close with a setup safety refusal (00 brief’s engine-owned window), plus accessory activation after the last window closes (95 A-21).
  - Required by BRIEF line 16: the engine owns the window, so a client that asked for it
    must be able to close it without stopping the computer.
  - The internal path exists: `close_display` (`src/macos_computers.rs:2243-2250`) destroys
    the window. The destroy handler detaches the view and clears `displayOpen`
    (`:2229-2234`).
- **Params:** `computerId`.
- **Result:** none. It is idempotent: a computer without a window succeeds.
- **Errors:**
  - "This computer no longer exists.".
  - NEW (proposed): refuse while `state == setting-up`. During the Recovery step, setup
    reads and types into this very window (`recovery.rs:274-279`). With the window gone,
    every read fails with "This computer's display isn't open." (`engine.rs:1604-1607`).
- **Semantics:** the computer keeps running (MAC lines 50-51). Closing the last VM window returns `silod` to accessory activation (NEW, justified by 95 A-21; 05 §3.6).

### Display state and events

- **State:** `MacosComputer.displayOpen`, which EXISTS (`src/macos_computers.rs:82`).
  - It is set when the window is created (`:2235`).
  - It is cleared on window destroy (`:2232`) and when the machine stops (`:1805`, `2359`).
- **Events:** changes arrive in `computers.changed`, its macOS part (EXISTS as
  `silo://macos-computers-changed`). No separate display event exists, and none is needed
  while the row carries the flag.

### The Recovery "Setting up" window

- **Status:** EXISTS. Internal, and not a client method.
  - `recovery::prepare_window` → `show_display(app, id, "Setting up <name>", toolbar=false)`
    → `focus_display` → `lock_input` (`recovery.rs:60`, `274-279`).
- **Behaviour:**
  - The window has no toolbar.
  - The user's keyboard input, and pointer input over the screen, are dropped while the
    sequence runs. Events Silo sends itself still pass (`engine.rs:1690-1738`).
  - The subtitle reads "Silo is setting up this computer. Please don't type."
    (`recovery.rs:39`).
  - Input comes back when the sequence ends, however it ends (`recovery.rs:282-291`;
    `engine.rs:1740-1761`).
  - `displayOpen` is true meanwhile. This internal Recovery setup guard is existing behaviour, not a GUI-driver lease; no public screen lock method is added (95 A-8).
- **Remote setup:** for a computer set up on behalf of a remote controller, this window
  shows on the owning Mac, because setup reads it (MAC lines 425-427; §Not covered yet,
  line 496).
- **With `silod`:** the window needs the GUI session `silod` runs in (DISPLAY-R lines
  174-186). An owner without a logged-in GUI session can't run the SIP step.

### Remote macOS computers: the VNC path

A macOS computer on another Mac is viewed through the guest's own Screen Sharing (RFB
security type 30), relayed by the owner and shown by noVNC on the controller (MAC §On
another Mac, lines 440-469; DISPLAY-R §Probe and decision, lines 304-337).

- **Why Screen Sharing:** its port is reachable only from the owner, through the guest's NAT
  network. The private `_VZVNCServer` listens on every interface.
- **What it can't show:** installer, Setup Assistant and Recovery screens.

#### macos.display.connect (owner)

- **Kind:** query.
- **Status:** EXISTS. Bridge `macos.display.connect`, class `read` (`src/remote.rs:269`;
  `src/macos_remote.rs:84-88`) → `remote_display::session` (`remote_display.rs:99-113`).
- **Params:** `computerId` (UUID).
- **Result:** `DisplaySession {username, password, width, height}`
  (`remote_display.rs:29-37`).
  - `username` is `silo`.
  - `password` is the guest account's.
  - `width` and `height` are the framebuffer pixels. The default is 2560×1600 when unknown
    (`:24`).
- **Errors** (`remote_display.rs:49-73`, `26`):
  - "The computer is not running. Start it to show its screen.";
  - "The computer is still starting." and "The computer is stopping.";
  - "The computer is still being set up. Its screen is available once setup has finished.";
  - "Setup has not finished. …" (requires `installed`, `setup.computerUse` and not
    `needsPersonalizing`);
  - the Screen Sharing-not-available sentence, when port 5900 doesn't answer within 5 s;
  - the address and access errors of §7, the shutdown gate (`src/macos_computers.rs:944-948`),
    and "Invalid macOS computer request: missing computer identity." (`macos_remote.rs:27`,
    `35`).
- **Credentials:** returned only to the requesting device, and never logged (CONN lines
  152-155). Screen Sharing signs in with the computer's account; the legacy VNC password is
  off (MAC lines 360-361; `silo-computer-use.zsh:263-265`).

#### macos.display.resize (owner)

- **Kind:** command, classed `read` because it is idempotent (`src/macos_remote.rs:14-16`).
- **Status:** EXISTS. Bridge `macos.display.resize` (`src/remote.rs:270`;
  `macos_remote.rs:89-94`) → `remote_display::resize` (`remote_display.rs:115-126`)
  → `engine::reconfigure_display` (`engine.rs:1562-1590`, public
  `reconfigureWithSizeInPixels:error:`).
- **Params:** `computerId`, `widthPx: u64`, `heightPx: u64`. Both must be whole numbers
  (`macos_remote.rs:50-56`).
- **Result:** `{widthPx, heightPx}`, the size the framework took. The request is clamped to
  640×400 .. 7680×4320 with even sides (`remote_display.rs:39-47`).
- **Errors:**
  - the same readiness errors as connect;
  - "The computer's display could not be resized: …".

#### macos.display.stream (owner)

- **Kind:** stream (raw bytes).
- **Status:** EXISTS. Bridge `macos.display.stream`, class `stream` (`src/remote.rs:271`,
  `2090-2097`) → `remote_display::connect`, a TCP connection to `<guest NAT IP>:5900`
  with a 5 s timeout and `nodelay` (`remote_display.rs:89-97`).
- **Params:** `computerId`.
- **Semantics:**
  - The owner opens the guest connection before the reply, so a refusal reaches the viewer
    as a message (CONN lines 147-152).
  - It shares the stream budget with `guest.ssh` and ends when either side closes or
    Connections turn off.

#### macos.display.session (controller)

- **Kind:** command.
- **Platforms:** macOS computer; controller client reaches only its local engine (95 A-3).
- **Status:** EXTENDED: tauri `macos_display_session` (`src/macos_remote_viewer.rs:199-238`); NEW explicit target fields and independent client-owned gateways (95 A-20/A-28).
  - Today it takes no arguments: the target comes from the calling window's label in a
    registry of at most 8 viewers (`:21`, `65-96`).
- **Params:** `deviceId`, `computerId`; NEW explicit target fields and connection-scoped client ownership, justified by 95 A-20/A-28. The local engine allocates an independent gateway per client; one client's close/reconnect never replaces another client's guest stream.
- **Result:** `Session {url, username, password, width, height}` (`:184-193`). `url` is
  `ws://127.0.0.1:<port>/<token>` of a loopback gateway.
- **Gateway** (`src/macos_display_gateway.rs:1-8`, `30-31`, `103-166`, `182-183`, `306-318`):
  - It binds 127.0.0.1 only.
  - The URL path is a random token, and the `Host` header is checked.
  - `Origin` must be one of the app's own origins.
  - It serves one connection at a time, and a newer one ends the older.
  - Messages from the page are limited to 1 MiB.
  - Each WebSocket is spliced to a new `macos.display.stream` on the owner
    (`macos_remote_viewer.rs:240-276`).
- **Engine change (proposed):**
  - The `Origin` allow-list is the Tauri app's origins (`app_origins`). For other clients
    the engine needs the list as a parameter, or no `Origin` check for non-browser
    clients.
  - DECIDED (95 A-20): retain the existing Screen Sharing stream/viewer route. Per-client gateway connections are NEW, justified by 95 A-28: closing one client never closes another's viewer. Keep each browser gateway's origin allow-list scoped to its client; qualification of client origins remains a technical probe (B-21).

#### macos.display.resize (controller)

- **Status:** EXISTS. Tauri `macos_display_resize(widthPx, heightPx)`
  (`src/macos_remote_viewer.rs:278-299`). It relays to the owner's `macos.display.resize`.
- **In the API:** it is the same method as the owner's, called through the bridge. No
  separate name is needed.

#### display.show for a remote macOS computer (controller)

- **Status:** EXTENDED: tauri `open_macos_remote_display` (`src/macos_remote_viewer.rs:98-160`); NEW independent client-owned attachments (95 A-28). Canonical `display.show` reuses today’s Screen Sharing route (95 A-20).
- **What the source command does today:**
  - It confirms through the bridge's `macos.snapshot` (`computers.list {deviceId}` in the
    API) that the computer exists and runs (`:162-182`).
  - It opens a `desktop-shell-macos-<hash>` window running noVNC, with route
    `index.html?macosDisplay=<id>&device=<id>&name=<name>`. The route has no secrets
    (`:39-59`).
  - The window is 1200×820, at least 672×480 (`:138-142`).
- **Viewer page:**
  - It reconnects with backoff from 1 s to 15 s, up to 8 attempts.
  - It debounces resizes by 300 ms with `devicePixelRatio`
    (`ui/desktop/macos-remote-viewer-state.ts:27-32`; `macos-remote-viewer.tsx:63`,
    `91`, `228-229`).
- **In the API:** the window and the noVNC page are UI.
  - The engine part is `macos.display.session` plus the gateway.
  - `close_device` and `close_all` end gateways when a device is removed, disconnected or
    revoked, or the engine quits or updates (`:301-322`; `src/remote.rs:461`, `1569-1574`;
    `src/runtime/shutdown.rs:108`; `src/updates.rs:753`).
  - DECIDED (95 A-20): retain the existing Screen Sharing stream on the controller. The controller client owns its viewer UI; the stream/gateway remains engine work. Independent per-client attachment is NEW, justified by 95 A-28 (40 §2).

## 6. Clipboard

### clipboard.transfer (macOS part)

The one method is owned by [40 §clipboard.transfer](40-desktop-display-computer-use.md#clipboardtransfer-linux-viewer-part); this section specifies its macOS adapter.

- **Kind:** command.
- **Platforms:** both. The Linux part is in the desktop viewer section. The macOS part is
  local computers only (MAC line 437-438).
- **Status:** EXTENDED: tauri `macos_computer_clipboard` (`src/macos_computers.rs:903-912`) → `guest_clipboard::run` (`guest_clipboard.rs:237-256`); NEW macOS Waiting/Cancel admission (95 A-31/§3; canonical owner/status in 40).
- **Queue:** NEW macOS transfer work waits as “Waiting…” with Cancel before admission (95 A-31/§3; 10 §6). Once admitted, the existing clipboard worker has no safe cancellation seam and reports `NotCancellable` (05 §4.2 F).
- **Params** (one shape for both platforms, 80 §2 N9):
  - `computerId`, `deviceId?`;
  - `action: "paste" | "copy"`, the values of the result's own `action` field. On macOS the
    engine maps them to the internal `Direction`, `paste-into` and `copy-from`
    (`guest_clipboard.rs:107-114`);
  - `connectionId` is required for Linux only (40 §2); the macOS part takes none.
- **Result:** `Report {action: "paste"|"copy", status, content: "text"|"image"|null,
  message}` (`src/viewer_clipboard.rs:29-66`; TS `ui/desktop/viewer-clipboard-feedback.ts:3-8`).
  - `status` is one of `pasted`, `copied`, `device-empty`, `computer-empty`, `too-large`,
    `not-connected`, `unsupported`, `busy` or `failed`.
- **Errors:** "Start the computer to use its clipboard." when not running
  (`guest_clipboard.rs:243-246`), and the access errors of §7.
- **Semantics:**
  - **Limits:** text up to 1 MiB and PNG up to 16 MiB (`src/desktop_bridge.rs:32-34`). The
    guest checks sizes before it prints anything (`guest_clipboard.rs:41-71`).
  - **Transport:**
    - It runs over SSH as `silo`, with JXA on `NSPasteboard` using explicit types
      `public.utf8-plain-text` and `public.png`, converting TIFF to PNG.
    - Payloads travel on stdin, and results come back as base64 output
      (`guest_clipboard.rs:1-15`, `44-105`).
    - Timeouts are 10 s for pasting text and 30 s for pasting an image or reading the guest
      clipboard (`:32-33`, `202`, `212`, `227`).
  - **One at a time:** one transfer runs per computer. Otherwise the status is `busy`
    (`:240-242`).
  - **Paste:** `action: "paste"` (internally `paste-into`) only sets the guest clipboard;
    the user presses ⌘V (`:218-221`).
  - **Result delivery:** a client gets the `Report` as this method's result. The engine
    window's toolbar shows its own transfers' `Report` in the subtitle (§5), which is UI.
    The Linux `desktop-clipboard` event is UI-only, not an API event (80 §2 N9).
  - **Host side:** it uses the clipboard of the device running the process
    (`crate::clipboard::system()`, `:251`).
- **Engine implication:** under `silod`, "this Mac's clipboard" is the engine host's. That
  is wrong for a client on another Mac (BRIEF line 25). See the NEW methods below.

### clipboard.read / clipboard.write (macOS computer)

- **Kind:** query (`clipboard.read`) / command (`clipboard.write`).
- **Platforms:** macOS computer. The Linux parity belongs to the desktop section.
- **Status:** EXTENDED: tauri `macos_computer_clipboard` already reads/writes the guest clipboard (`src/macos_computers.rs:903-912`; `guest_clipboard.rs:160-256`). NEW explicit payload input/output replaces the engine-host pasteboard for these methods, allowing the client to own its pasteboard and reach remote macOS guests (95 A-14/A-19). Required by:
  - BRIEF line 25: controllers on other Macs, whose own clipboard isn't the engine host's;
  - BRIEF line 13: remote engines;
  - MAC line 437-438 and line 496 ("clipboard transfer for remote computers" is not done).
- **`clipboard.write` params:**
  - `computerId`;
  - `content: {kind: "text", text}` or `{kind: "image", mime: "image/png", bytes}`.
- **`clipboard.read` result:** `{kind: "text"|"image"|"empty"|"too-large", …}`. This is
  `GuestClipboard` (`guest_clipboard.rs:131-158`; `src/desktop_bridge.rs:431-441`). It has no
  serde shape today, so the `kind` form is proposed.
- **Semantics:**
  - The guest side is the existing `MacGuest` (`guest_clipboard.rs:160-235`), with the same
    limits and timeouts. The client supplies or receives the payload instead of the
    engine's host clipboard.
  - `clipboard.transfer` stays as a local convenience.
- The bridge classes would be `change` for write and `read` for read.

## 7. Guest access

### What exists (internal, no method)

- **Account:** `silo` (`guest_access.rs:23`), home `/Users/silo`, within LCU's 13-byte limit
  (MAC lines 305-306, 370-371).
  - It has passwordless `sudo -n` (`offline_setup.rs:671-673`).
  - Automatic login is on, so a GUI session exists after boot (`offline_setup.rs:562-593`;
    checked at `provision.rs:388-413`).
- **Secrets:** in `macos-computers/<id>/guest-access/` (0700) (`guest_access.rs:50-52`,
  `100-156`):
  - `password`, 24 characters from a 57-character alphabet, file mode 0600
    (`:170-193`);
  - `id_ed25519` and its `.pub`, made by `ssh-keygen -t ed25519 -C silo`.
  - Not in the Keychain: anyone who can read that folder can read the disk too
    (MAC lines 401-403).
  - Templates keep a copy in `template-access/`, and forks in `inherited-access/`, until
    personalization replaces them (MAC lines 74-75).
- **Address:**
  - The newest lease for the record's MAC in `/var/db/dhcpd_leases`, with MACs normalized
    to two-digit groups (`guest_access.rs:24`, `197-265`).
  - Errors: "Silo could not read the Mac's network leases." and "The computer has no
    network address yet.".
- **SSH and SCP** (`guest_access.rs:323-388`), with:
  - `-F /dev/null`, so the user's SSH config never applies (`:4-6`, `331`);
  - `-i <key> IdentitiesOnly=yes BatchMode=yes PasswordAuthentication=no`, or for password
    logins, askpass;
  - `StrictHostKeyChecking=accept-new`;
  - `UserKnownHostsFile=<guest-access>/known_hosts`;
  - `HostKeyAlias=silo-<id>`, so host keys follow the computer and not its changing IP;
  - `ConnectTimeout=10`, `ServerAliveInterval=15`, `LogLevel=ERROR`.
  - Host keys are reset when personalization changes them (`:65-72`).
- **Command runners** (`guest_access.rs:454-588`; `CommandOutput {status, stdout, stderr}`
  at `:36-41`):
  - `run` (stdin, timeout);
  - `run_capped` (stdout cap, "The command in the computer printed too much.");
  - `run_cancellable`;
  - `copy` / `copy_cancellable` (scp).
  - Timeouts kill the tool with "The command in the computer took too long." (`:603-666`).
- **What's missing:** "Terminal, editor, Files, network ports, GitHub, secrets, working
  account | None. These use the Linux guest bridge over SSH, which macOS computers do not
  have" (MAC §Not covered yet, line 500).
  - There's no SSH config alias for macOS guests. The Linux alias comes from
    `editor::prepare` (`src/editor.rs:409-436`, `554-596`): a `Host silo-<suffix>-<name>`
    entry included from `~/.ssh/config`.
  - The Linux `guest.ssh` stream runs `msb ssh serve`, which is Linux-only
    (`src/remote_access.rs:197-226`).

**Qualified GUI execution (B-23).** An SSH helper used `sudo launchctl asuser <consoleUid> sudo -u silo -H …` and observed the console GUI domain and active display. Use that guest-side context when a command needs the GUI session; it does not confer Screen Recording permission ([macos.md §B-23](probes/macos.md#b-23--confirmed); recorder identity requirements are in 40 §5).

### What Fjord needs (cited)

- **Router "Runs on"** (BRIEF line 21): Claude desktop app sessions running inside a
  computer over SSH.
  - Fjord writes the SSH connection, installs its plugin and hook in the guest, and moves
    message delivery, forms and presence to and from the guest.
  - Today's host-side install:
    - writes the plugin folder (`Sources/Fjord/ClaudePlugin.swift:35-57`);
    - runs `claude plugin marketplace add`, `plugin install`, `plugin update` and
      `plugin enable` (`ClaudePlugin.swift:818-848`);
    - writes a hook script and `~/.claude/settings.json`
      (`Sources/Fjord/Forms.swift:594-596`, `633-662`).
  - In a guest, each of those is a file write or a command as `silo`.
- **Triage "Run in a computer"** (BRIEF line 22): unattended headless Claude Code runs. The
  `claude -p` runs Fjord already makes are on the host and for the Router only: its
  dispatcher (Haiku, no built-in tools) and its one-message sender
  (`Sources/Fjord/RouterRun.swift:155`, `230`). No Triage `claude` run exists yet. In
  a guest, a headless run would be a long-running command with streamed output.

### guest.exec (macOS computer)

- **Kind:** command, bounded by a timeout.
- **Platforms:** both. The method and its shape are 70's (70 §2.1; 80 §2 N19); this is its
  macOS part.
- **Status:** EXTENDED: existing command execution by `guest_access::run_capped` / `run_cancellable` (`guest_access.rs:467-524`), used by macOS setup (`guest_computer_use.rs:368-401,590-600`; tauri `macos_computer_action` action=`setup`, `src/macos_computers.rs:824-835`); NEW caller-supplied argv/cwd/env/cap control, byte-preserving output and signal field (95 A-37/A-38; canonical owner/status in 70).
  - Required by BRIEF lines 21-22 and the Fjord install code above; bounded stdout overflow stays an error with a configurable cap, and long Triage runs use `guest.exec.start` (95 A-37).
  - It is built on the existing `guest_access::run_capped` / `run_cancellable`
    (`guest_access.rs:467-524`).
- **Params:** 70's `GuestExecRequest`: `{computerId, argv[], cwd?, env?, as?, stdin?,
  timeoutMs, maxOutputBytes?}` (70 §2.1). On macOS:
  - **`argv`:** the existing runner sends one command string over SSH, run by the guest's
    login shell as `silo` (`guest_access.rs:454-545`). So the engine quotes `argv` into
    that string; no element is ever shell source (80 §2 N19). `cwd` and `env` have no
    runner parameter today and go into the same quoted string (NEW).
  - **`as: "root"`:** root work uses `sudo -n` inside the command (`:454`), which `silo` has
    without a password (`offline_setup.rs:671-673`).
  - **`stdin?`:** the way Silo already passes secrets (`personalize.rs:10-12`).
  - **`maxOutputBytes?`:** today's `run_capped` limit applies to stdout only
    (`src-tauri/src/macos_computers/guest_access.rs:467-483`, `:632-634`). Stderr is
    drained without a cap. The configurable stdout cap preserves that existing overflow behaviour (95 A-37); numeric cap/timeout qualification is B-32 (70).
- **Result:** 70's `{exitCode, signal?, stdout, stderr}` (70 §2.1). On macOS the existing
  output is `CommandOutput {status: i32, stdout: String, stderr: String}`
  (`src-tauri/src/macos_computers/guest_access.rs:36-41`): `exitCode` maps `status`;
  a signal exit maps to `-1` today (`:661-665`). A separate signal field and byte-preserving
  output are NEW API fields: today's drains decode with `String::from_utf8_lossy`
  (`:668-692`; 70 §2.1). There is no truncation-result contract: overflow returns the existing error, as decided by 95 A-37.
- **Errors:**
  - not running;
  - setup not complete (the same rule as the remote display: `remote_display.rs:49-73`);
  - "This computer's access is missing." (`guest_access.rs:77-96`);
  - the address errors;
  - "The command in the computer printed too much." (`OUTPUT_TOO_LARGE`, `:33`): today
    `run_capped` is documented to fail and stop the command once the stdout allowance
    is passed (`src-tauri/src/macos_computers/guest_access.rs:465-483`). The drain reads
    at most `limit + 1` bytes and sets an overflow flag; when the runner observes it,
    it kills and waits for its host SSH child, then returns the error with no
    `CommandOutput` (`:632-640`, `:668-692`);
  - "The command in the computer took too long.".
  - 70's codes for these (`not_running`, `output_too_large`, `timed_out`) are NEW codes,
    justified by 95 A-10 and added to `ErrorCode`/fixtures. Today the sentences become `internal` (`bridge_error.rs:104-108`; 80 §2 N17); that is snapshot evidence, not the new contract.
- **Semantics:** it runs over SSH as `silo` (`guest_access.rs:323-388`). Whether such a
  command can reach the auto-login GUI session is not in the sources (Open questions).
- **Bridge:** it must be added to `METHODS` as `change` (`src/remote.rs:236-272`), because a
  command can change the guest.
- **File writes:** Fjord installs the guest-compatible hook/plugin through `guest.files.*` (NEW, justified by 95 A-38; 70 §2.1). Today's stdin/scp runner is a possible adapter (§7); Linux guest PermissionRequest invocation is confirmed, but full Fjord guest artifact/form/presence integration stays B-15 ([linux.md Follow-up §B-15](probes/linux.md#b-15-permissionrequest-in-claude-code-desktop-ssh)), and no dependency on the host Fjord binary is permitted.

### guest.ssh (macOS computer)

- **Kind:** stream.
- **Platforms:** macOS computer (new), Linux (existing).
- **Status:** EXTENDED: existing Linux bridge `guest.ssh` (`src/remote.rs:255`; `remote_access.rs:197-226`); NEW macOS guest TCP relay (95 A-19).
  `remote_access.rs:197-226`).
  - Required by BRIEF line 21 (Claude app sessions over SSH) and BRIEF line 22 (headless
    runs).
  - The guest is reachable only from the owner (MAC lines 443-444; DISPLAY-R line 233), so a
    controller or a client on another Mac needs the owner to relay.
- **Params:** `computerId`.
- **Semantics:**
  - The owner opens TCP to `<guest NAT IP>:22` and splices bytes both ways. This is the same
    mechanism as `macos.display.stream` to port 5900 (`remote_display.rs:89-97`).
  - The SSH handshake and authentication happen end to end, between the client's `ssh` and
    the guest's `sshd`.
  - Readiness rules: those of `guest.exec`.

### guest.prepare (macOS part: key authorization)

`sshAccess.connection` keeps the `sshAccess.*` section's meaning for both kinds (the managed
listener, 50 §sshAccess.connection; 80 §2 N8). What this section first proposed as a macOS
`sshAccess.connection` splits in two: the key authorization below is the macOS part of 50's
`guest.prepare`, and the alias material is `guest.sshAlias.ensure` (owned by 50; 80 §2 N10).

- **Kind:** command.
- **Platforms:** macOS computer here. The Linux part is 50's `guest.prepare` (bridge
  `guest.prepare`, `src/remote.rs:254`; `src/remote_access.rs:68-87`).
- **Status:** EXTENDED: existing Linux bridge `guest.prepare` (`src/remote.rs:254`; `src/remote_access.rs:68-87`); NEW macOS client-key authorization and host-key result (95 A-19/A-13). Required by BRIEF line 21 ("Fjord writes the SSH connection")
  and MAC line 500 (macOS computers lack the Linux guest bridge over SSH). The Linux SSH
  alias comes from `editor::prepare` (`src/editor.rs:409-436`), which has no macOS path.
- **Params:**
  - `computerId`, `deviceId?`;
  - `publicKey`: the client's own key, the same input as Linux's `guest.prepare`
    (50 §guest.prepare) and `ssh.access.connection` (`ssh_connection.rs:144-146`).
- **Effect:** it appends `publicKey` to `/Users/silo/.ssh/authorized_keys` through
  `guest.exec`.
  - Personalization replaces `authorized_keys` whole (`personalize.rs:54-59`), so copies and
    forks never inherit a client's key.
- **Result:** `user: "silo"` and the guest's host key line, the macOS values of the fields
  50's `guest.prepare` returns (50 §guest.prepare).
- **What moves to `guest.sshAlias.ensure`** (50; 80 §2 N10). The facts this section gave
  for the macOS alias material stay true and are that method's macOS part:
  - `hostKeyAlias: "silo-<id>"` (`guest_access.rs:350`);
  - for a local client, the guest address (§7 Address) and port 22;
  - for a client that must go through the owner, a `ProxyCommand` that opens `guest.ssh`.
    That is the shape Linux uses for its private transport (`src/editor.rs:525-596`). 80
    §2 N10 adopts this relay for macOS, because DHCP leases change.
  - The `Include`d `~/.ssh/config` entry, as Linux writes it (`src/editor.rs:409-436`), is
    `guest.sshAlias.ensure`'s `installInclude?`. Whether the Claude desktop app honours it
    is a probe (Open questions; 80 §4 B-11).

### Shared handoffs and parity

- **Terminal and editor:** shared command-returning methods serve macOS; clients launch the commands (NEW, justified by 95 A-19/A-22; 50). `guest.sshAlias.ensure` uses `computerId` for the managed alias and no old-name alias fallback (95 A-13/§3).
- **Files, network ports and working account:** every shared Linux feature method in 50 applies to macOS as NEW, justified by 95 A-19. Today's macOS SSH access is the source seam (§7); unsupported mechanisms stay in 50's technical questions/probes and §10 rather than being invented.

## 8. Remote: bridge and controller commands

| Bridge method (owner) | Class | Source | API method |
| --- | --- | --- | --- |
| `macos.snapshot` (historical) | read | `src/remote.rs:266`; `src/macos_remote.rs:68-70` | RETIRED source name → canonical `computers.list {deviceId}` (95 §3; 80 §2 N1) |
| `macos.create` (historical) | change | `remote.rs:267`; `macos_remote.rs:71-76` | RETIRED source name → canonical `computers.create {kind:"macos"}` (95 §3; 80 §2 N1) |
| `macos.action` (historical) | change | `remote.rs:268`; `macos_remote.rs:77-83` | RETIRED dispatch name → canonical `computers.start`, `computers.stop`, `computers.forceStop`, `computers.delete`, `macos.setup.retry` (95 §3; 80 §2 N1; §11) |
| `macos.display.connect` | read | `remote.rs:269`; `macos_remote.rs:84-88` | `macos.display.connect` |
| `macos.display.resize` | read | `remote.rs:270`; `macos_remote.rs:89-94` | `macos.display.resize` |
| `macos.display.stream` | stream | `remote.rs:271`, `2090-2097`; `macos_remote.rs:99-105` | `macos.display.stream` |

| Controller Tauri command | Source | Calls today (retired source name) | API method |
| --- | --- | --- | --- |
| `remote_macos_snapshot(deviceId)` | `src/macos_remote.rs:130-138` | `macos.snapshot` | `computers.list {deviceId}` |
| `remote_macos_create(deviceId, request)` | `:140-152`. It checks the shape first (`parse_create`) | `macos.create` | `computers.create {kind:"macos", deviceId}` |
| `remote_macos_action(deviceId, computerId, action)` | `:154-166`. Only the five actions are accepted (`src/macos_computers/store.rs:38-47`; test `:203-221`) | `macos.action` | one per `action`, as in the first table (§11) |

- **Source dispatch today:** `macos_remote::dispatch` handles the old `macos.*` list (`src/remote.rs:2217`); unknown methods get `unsupported_remote_operation` (`macos_remote.rs:95`). NEW, justified by 95 §3: shared methods dispatch by `computerId`/platform under their canonical names, and only macOS-specific setup/template/display methods keep `macos.*`; no old-name dispatch branch remains.
- **Change rules:** one `operationId`, replay on loss, `startWithinMs` (CONN lines 146-147).
- **Remote rules:**
  - The remote Start and Setup use the same admission and attempt guards as local, and open
    no window on the owner (MAC lines 423-427).
  - Logs use canonical `logs.query` (10 §13). Historical `runtime.logs` serves the source behaviour (MAC lines 430-431) and is RETIRED, not an alternate wire name (95 §3).
  - A remote job belongs to the owner engine and is addressed by `(deviceId, jobId)` (05 §4.2 E item 6). NEW, justified by 95 A-3/A-4: the local engine relays owner progress/state events through a Stream-class SSH subscription. Today's bridge pushes nothing; that polling limit is replaced.
- **Not offered remotely today:** checkpoints and clipboard (MAC lines 437-438). Remote parity is NEW, justified by 95 A-14/A-19. The NEW methods in
  §6, §7 and §10 must be added to `METHODS` with their classes, because a method isn't
  reachable until it is classified there (`src/remote.rs:234-236`).

## 9. Start at launch

### macOS computers in `computers.launch` and `startupComputerIds`

- **Names:** no `macos.startAtLaunch` (80 §2 N19). The status is `computers.launch` (10
  §12.1). The selection is `settings.update {startupComputerIds, startComputersAtLaunch}`
  (the `settings.*` section). This part gives the macOS facts and rules both rely on.
- **Kind:** setting (the selection) and query (`computers.launch`).
- **Platforms:** macOS computer.
- **Status:** EXTENDED: tauri `read_settings` exposes launch selection (`src/settings.rs:779-792`), applied by `startup::install` (`src/startup.rs:152-268`); NEW macOS selected starts (95 A-19) and the observable `LaunchStatus.lastPass` outcome (00 brief, no drawing UI; canonical owner/status in 10). Required by:
  - MAC §Not covered yet, line 505: "Status panel, tray, notifications, start with Silo |
    None";
  - BRIEF line 25: "an always-on host Mac";
  - BRIEF line 20: "one long-lived dev computer: usually macOS".
- **Why today's setting excludes macOS computers:**
  - `startComputersAtLaunch` and `startupComputerIds` are read by `startup.rs`
    (`src/startup.rs:18-37`).
  - The selection is filtered to ids in the Linux runtime metadata
    (`settings_for_launch`, `startup.rs:87-101`).
  - Each id is started with `crate::runtime::start_at_launch` (`startup.rs:238-245`).
  - macOS computers aren't in that metadata (MAC lines 78-80), so their ids are dropped.
- **Why the always-on host needs it:**
  - `silod` starts as a LaunchAgent at login (BRIEF line 9).
  - After a reboot with automatic login (DISPLAY-R lines 176-186), nothing else would start
    the dev computer.
- **Shape (proposed):** reuse the existing setting and accept macOS computer ids in
  `startupComputerIds`. There is one list for both kinds, gated by the same
  `startComputersAtLaunch`.
  - The `settings.*` section owns the setting. `computers.launch` (10 §12.1) owns the
    launch pass and its status, and filters against both inventories. This section owns the
    macOS start rules.
- **Rules:**
  - Each selected macOS id is started with the ordinary Start (`src/macos_computers.rs:1351-1425`)
    after the registry loads, in list order.
  - A refusal is reported like a Linux launch failure (`startup.rs:246-264`), and appears in
    `computers.launch`'s `lastPass.failures` (10 §12.1). Refusals include:
    - needs personalizing (`src/macos_computers/store.rs:258-260`) or an interrupted
      install (`store.rs:254-256`);
    - an unfinished Restore (`src/macos_computers.rs:1370-1372`);
    - a third running macOS guest (`engine.rs:43-44`).
  - Not a refusal: a Restore pending from memory on a host whose build changed boots from
    disk with a note (`checkpoints.rs:754-757`).
  - Stopping a computer by hand doesn't remove it from the list. That is the Linux behaviour
    (`startup.rs:39-46` only drops recovered explicit stops).

## 10. Gaps

Each row from MAC §Not covered yet (lines 491-506), including every "None", with a decision. NEW in this gap table describes the missing macOS/remote part; methods that reuse existing behavior are classified EXTENDED in their Status lines.

The owner's rule: the API must expose everything Silo does and add what's missing, for macOS
computers and for Fjord's use (BRIEF lines 14-15). "Leave out" means not specified now; the
reason is given.

| Gap (MAC line) | Decision | Reason |
| --- | --- | --- |
| Checkpoints: export and import, size breakdown, abandoning a Restore (495) | Owned by the `checkpoints.*` section | That section covers all checkpoint methods. Remote checkpoints for macOS are below |
| Remote: checkpoints for remote computers (496) | **Include, NEW, justified by 95 A-14/A-19/§3:** canonical `checkpoints.create/fork/restore/delete` (20) handle remote macOS ids through the local engine. Historical bridge `checkpoint.create/fork/restore` (`src/remote.rs:263-265`, Linux) and `runtime.logs` (`src/runtime/remote_ops.rs:13-19`; `src/runtime_logs.rs:658-669`) are source seams only and are RETIRED. macOS checkpoint work uses `job:` progress `source: "macos"` (05 §4.2 E) | Triage takes pre-run checkpoints on the host (95 A-18; BRIEF line 22) |
| Remote: clipboard transfer (496) | **Include, EXTENDED:** `clipboard.read` / `clipboard.write` reuse guest transfer primitives with NEW client payload and remote access (§6) | BRIEF line 25 |
| Remote: screens before computer use is set up (installer, Setup Assistant, Recovery) (496) | Leave out | Silo automates those screens on the owner unwatched, and its log is readable remotely. `_VZVNCServer` is the documented exit, not the plan (DISPLAY-R lines 326-337) |
| Recovery step shows its window on the owning Mac (496) | Keep, documented in §5 | Setup reads that window (`recovery.rs:1-14`) |
| Computer use: re-apply when `computerUseAutoApproval` changes (497) | **Include, NEW:** `computerUse.approval {computerId, deviceId?, mode: "ask"\|"auto"}` for macOS, the canonical setter for both kinds (40 §4; 80 §2 N7). It sets `computerUseApproval`, which makes the computer stale (`store.rs:119-127`), and updates through the in-place path at the next Start (`src/macos_computers.rs:1414`; `guest_computer_use.rs:430-546`). Applying it at once on a running computer is a NEW call of that path. The bridge name EXISTS for Linux (`src/remote.rs:249`; `src/desktop.rs:670-682`, `880-903`) | MAC line 497. The dev computer runs LCU (BRIEF line 20) |
| Computer use: upgrading the pinned app or LCU in existing computers (497) | Already done in code (§3, in-place updates) | `src/macos_computers.rs:1414`; `guest_computer_use.rs:430-546`; MAC lines 121-129 |
| Computer use: status in the UI (497) | **Include, NEW:** the macOS part of `computerUse.state {computerId, deviceId?}`, with 40's result type (40 §4; 80 §2 N7). Its macOS fields read on demand come from the guest receipt `{schemaVersion, state, reason, chatgptVersion, lcuVersion, approval, at}` (`silo-computer-use.zsh:82-87`), read with `guest.exec`. Plus `computerUseStale` and `setup` in the row (§2, §3) | MAC line 497. BRIEF line 20 |
| Computer use: cancelling a download or copy in progress (497) | Leave out | It is internal responsiveness of Delete and Quit (`guest_computer_use.rs:631-643`), not a client method |
| Setup on other macOS versions (498) | Leave out | A qualification task, not API |
| Templates: one per build side by side; shrinking a template's disk (499) | Leave out | No cited Fjord need, and only the newest template is kept by design (`templates.rs:309-343`) |
| Terminal, editor (500) | **Include, NEW, justified by 95 A-19/A-22:** shared `terminal.command`, `guest.sshAlias.ensure` and guest preparation in 50 apply to macOS; clients launch returned commands | Existing guest SSH access (§7); alias/handoff qualification remains 50 Q12/B-11 |
| Files (500) | **Include, NEW, justified by 95 A-19:** macOS parity for `files.list`, `files.upload` and `files.download` is specified in 50 §SSH access, guest access and files on macOS computers; programmatic `guest.files.*` is defined in 70 §2.1 | Roots and SFTP qualification remain 50 Q14; Fjord callers are cited in 70 §2.1 |
| Network ports (500) | **Include, NEW, justified by 95 A-19:** macOS parity is specified in 50 §Network on macOS computers | Listener discovery and relay choice remain 50 Q10–Q11; the guest is NAT-only (`engine.rs:485-493`) |
| GitHub, secrets (500) | **Include, NEW, justified by 95 A-15/A-19**, specified in 50 §GitHub and secrets on macOS computers; the NEW host-proxy route is justified by 95 A-15; B-27 qualifies the FileHandle/gateway/frame mechanism and controlled secret/CA behavior; default DNS and production lifecycle remain OPEN (50 Q5–Q6; [proxy.md §Remaining seam](probes/proxy.md#spec-impact-and-remaining-seam)) | BRIEF line 19 ("access to GitHub and secrets"); `guest.exec` alone does not specify proxy substitution or token storage (50 Q5–Q6) |
| Working account (500) | **Include, NEW, justified by 95 A-19:** the shared working-account methods in 50 also apply to macOS | Today guest access uses `silo` (`guest_access.rs:23`); additional account provisioning/switching is unsourced and remains 50's parity mechanism question |
| Export, import and backup (501) | **Include, NEW, justified by 95 A-19:** macOS export/import is specified in 20 §2.1 | Archive format remains 20 OQ 4; 20 §1.5 cites the Silo gap |
| Clipboard: no continuous sync (502) | Leave out | The guest owns ⌘C/⌘V, and transfers are explicit by design (MAC lines 393-399) |
| Shared folders, VirtioFS (503) | No shared-folder method is added; Files parity is required (95 A-19) | B-5 mounted an added VirtioFS device bidirectionally without an observed prompt; B-14 confirms guest SFTP. Neither selects shared folders or Files roots ([macos.md §B-5](probes/macos.md#b-5--confirmed), [§B-14](probes/macos.md#b-14--confirmed)) |
| Editing resources after creation (504) | **Include, NEW, justified by 95 A-12/A-19:** the macOS part of `computers.configuration.change` (10 §3; 80 §2 N3), for `cpus` and `memoryGiB` only, when stopped. The macOS request uses the CPU/memory fields specified in 10 §3 (NEW, justified by 95 A-12/A-19); the existing Linux `expected` type is not imposed on a macOS record. Each boot builds the configuration from the record (`engine.rs:459-460`), within the same bounds as create (`store.rs:162-196`). Refuse while `pendingRestore.memory` is true, because a memory state needs the configuration it was saved with (MAC lines 237-247). Disk growth: not exposed; disks remain fixed after creation (DECIDED 95 A-12) | BRIEF line 19 ("settings") |
| Status panel, tray (505) | Leave out | UI-only |
| Notifications (505) | Owned by the `notifications.*` section, fed by `computers.changed` (macOS part) | — |
| Start with Silo (505) | **Include, NEW, justified by 95 A-19:** macOS ids in `startupComputerIds`, started by `computers.launch` (§9; 10 §12.1) | BRIEF lines 9, 20, 25 |
| Linux host devices (retired by 95 §3) and Intel Macs (506) | Linux-host API is retired; macOS guests cannot run on Intel hosts | The framework runs macOS guests only on Apple Silicon (ENGINE-R line 13; `src/macos_computers.rs:14-18`) |

## 11. Coverage table

Each row maps to one canonical API method, a RETIRED source name that points to its replacement, an event of 05's catalogue (05 §4.2 D), or "not in API" with the reason. RETIRED names are not served; Silo's Tauri UI calls the canonical names (95 §3). Renaming an existing behavior is not NEW implementation. `macos_computer_action` and the
bridge's `macos.action` fan out by their `action` argument, so they have one row per action.

| Item | Kind | Source | API |
| --- | --- | --- | --- |
| `read_macos_computers` | Tauri | `src/macos_computers.rs:781-794`; `src/main.rs:146` | `computers.list` (its `macos` member) |
| `create_macos_computer` | Tauri | `:812-821`; `main.rs:147` | `computers.create {kind:"macos"}` (job, `job:<n>`) |
| `macos_computer_action` action=`start` | Tauri | `:823-835`; `main.rs:148` | `computers.start` (job, `job:<n>`) |
| `macos_computer_action` action=`stop` | Tauri | `:823-835`; `main.rs:148` | `computers.stop` (job, `job:<n>`) |
| `macos_computer_action` action=`force-stop` | Tauri | `:823-835`; `main.rs:148` | `computers.forceStop` |
| `macos_computer_action` action=`delete` | Tauri | `:823-835`; `main.rs:148` | `computers.delete` (job, `job:<n>`) |
| `macos_computer_action` action=`setup` | Tauri | `:823-835`; `main.rs:148` | `macos.setup.retry` (job, `job:<n>`) |
| `open_macos_display` | Tauri | `:837-846`; `main.rs:149` | `display.show` (macOS, local) |
| `macos_computer_clipboard` | Tauri | `:900-912`; `main.rs:150` | `clipboard.transfer` (`action` param, 80 §2 N9) |
| `delete_macos_template` | Tauri | `:796-810`; `main.rs:151` | `macos.template.delete` |
| `create_macos_checkpoint` | Tauri | `:848-859`; `main.rs:152` | `checkpoints.create` (`checkpoints.*` section; job, `job:<n>`) |
| `restore_macos_checkpoint` | Tauri | `:861-872`; `main.rs:153` | `checkpoints.restore` (`checkpoints.*` section; job, `job:<n>`) |
| `fork_macos_checkpoint` | Tauri | `:874-886`; `main.rs:154` | `checkpoints.fork` (`checkpoints.*` section; job, `job:<n>`) |
| `delete_macos_checkpoint` | Tauri | `:888-898`; `main.rs:155` | `checkpoints.delete` (`checkpoints.*` section; job, `job:<n>`) |
| `remote_macos_snapshot` | Tauri | `src/macos_remote.rs:130-138`; `main.rs:156` | `computers.list {deviceId}` |
| `remote_macos_create` | Tauri | `macos_remote.rs:140-152`; `main.rs:157` | `computers.create {kind:"macos", deviceId}` |
| `remote_macos_action` action=`start` | Tauri | `macos_remote.rs:154-166`; `main.rs:158` | `computers.start {deviceId}` |
| `remote_macos_action` action=`stop` | Tauri | `macos_remote.rs:154-166`; `main.rs:158` | `computers.stop {deviceId}` |
| `remote_macos_action` action=`force-stop` | Tauri | `macos_remote.rs:154-166`; `main.rs:158` | `computers.forceStop {deviceId}` |
| `remote_macos_action` action=`delete` | Tauri | `macos_remote.rs:154-166`; `main.rs:158` | `computers.delete {deviceId}` |
| `remote_macos_action` action=`setup` | Tauri | `macos_remote.rs:154-166`; `main.rs:158` | `macos.setup.retry {deviceId}` |
| `open_macos_remote_display` | Tauri | `src/macos_remote_viewer.rs:98-160`; `main.rs:159` | UI-only, not in API: it opens a noVNC webview window (`:138-142`). Its engine call is the next row |
| `macos_display_session` | Tauri | `macos_remote_viewer.rs:195-238`; `main.rs:160` | `macos.display.session` (controller) |
| `macos_display_resize` | Tauri | `macos_remote_viewer.rs:278-299`; `main.rs:161` | `macos.display.resize` |
| `silo://macos-computers-changed` | Event | `src/macos_computers.rs:50`, `667-669` | `computers.changed` (macOS part, payload `MacosComputersState`) |
| `macos.snapshot` | Bridge | `src/remote.rs:266` | RETIRED source name (95 §3) → canonical `computers.list` |
| `macos.create` | Bridge | `remote.rs:267` | RETIRED source name (95 §3) → canonical `computers.create` |
| `macos.action` action=`start` | Bridge | `remote.rs:268`; `macos_remote.rs:77-83` | RETIRED source name (95 §3) → canonical `computers.start` |
| `macos.action` action=`stop` | Bridge | `remote.rs:268`; `macos_remote.rs:77-83` | RETIRED source name (95 §3) → canonical `computers.stop` |
| `macos.action` action=`force-stop` | Bridge | `remote.rs:268`; `macos_remote.rs:77-83` | RETIRED source name (95 §3) → canonical `computers.forceStop` |
| `macos.action` action=`delete` | Bridge | `remote.rs:268`; `macos_remote.rs:77-83` | RETIRED source name (95 §3) → canonical `computers.delete` |
| `macos.action` action=`setup` | Bridge | `remote.rs:268`; `macos_remote.rs:77-83` | RETIRED source name (95 §3) → canonical `macos.setup.retry` |
| `macos.display.connect` | Bridge | `remote.rs:269` | `macos.display.connect` |
| `macos.display.resize` | Bridge | `remote.rs:270` | `macos.display.resize` |
| `macos.display.stream` | Bridge stream | `remote.rs:271` | `macos.display.stream` |
| `runtime.logs` for macOS computers | Bridge | `src/runtime/remote_ops.rs:13-19`; `src/runtime_logs.rs:658-669` | RETIRED source name (95 §3) → canonical `logs.query` (10 §13) |
| `query_computer_logs` (macOS setup logs, local) | Tauri | `src/runtime_logs.rs:711-719`, `610-614`; `main.rs:270` | `logs.query` |
| `export_computer_logs` (macOS setup logs, local) | Tauri | `src/log_export.rs:80-81`, `109`; `main.rs:271` | `logs.export` |
| Screen window toolbar (Paste into / Copy from Computer) | Native UI | `engine.rs:1325-1429` | UI-only, not in API: chrome of the engine window. Its buttons run the same transfer as `clipboard.transfer` |
| Screen window subtitle feedback | Native UI | `guest_clipboard.rs:287-310`; `engine.rs:1431-1446` | UI-only, not in API: it shows a transfer's `Report` |
| Recovery "Setting up" window and input lock | Internal | `recovery.rs:274-291`; `engine.rs:1690-1761` | Not in API: a side effect of setup (§5) |
| In-place computer-use update | Internal | `guest_computer_use.rs:430-546` | Not in API: shown through `detail`, and triggered by NEW `computerUse.approval` |
| Quit for macOS computers | Internal | `src/macos_computers.rs:2421-2555`; `src/runtime/shutdown.rs:108-111` | Not in API as its own method: the macOS part of `engine.shutdown` (05 §6) |
| Update gate | Internal | `src/macos_computers.rs:505-510`; `src/updates.rs:811-839` | Not a standalone method: current refusal is replaced by NEW save/resume preparation (95 A-6; 05 §6; probe B-30) |
| NEW parts of EXTENDED methods | — | — | `display.close`, `clipboard.read`, `clipboard.write`, `guest.exec` (macOS part), `guest.ssh` (macOS), `guest.prepare` (macOS part), `computerUse.approval` (macOS), `computerUse.state` (macOS part), `computers.configuration.change` (macOS part: CPUs, memory), macOS ids in `computers.launch` / `startupComputerIds`, remote `macos.template.delete`, remote `checkpoints.*` for macOS, the row fields `setup` and `computerUseStale` |

- The progress part of `silo://macos-computers-changed` is also `operations.job.progress`
  with `source: "macos"` (05 §4.2 E; 05 §9.3). That is the job event of the jobs above, not a
  second mapping of the Tauri event.
- `operations.job.finished` ends every macOS job above (05 §4.2 E).

## 12. Open questions

1. **What SSH connection does the Claude desktop app take for a remote environment?** It
   could be a host from `~/.ssh/config`, an explicit host, user and key, or a `ProxyCommand`
   form.
   - The method is settled: `guest.sshAlias.ensure` (50) writes an `Include`d `Host` entry,
     as Linux does (`src/editor.rs:409-436`), and reaches macOS guests by the `ProxyCommand`
     relay (80 §2 N8, N10). 50 cites the app's `sshHost` taking "a host alias from
     ~/.ssh/config".
   - PARTLY B-11: first-party Desktop honored the Linux Silo Include/ProxyCommand with pinned keys and `IdentityAgent none`; Desktop overrode alias BatchMode to `no`. macOS Desktop relay integration and credential/plugin details remain OPEN ([linux.md §B-11](probes/linux.md#b-11--claude-desktop-ssh-alias); 50 Q4).
2. **DECIDED (95 A-38):** Fjord ships a guest-compatible hook script and plugin installed through `guest.files.*`; no guest component depends on Fjord's macOS binary.
   - Remaining probe B-15: validate guest paths, form delivery and presence with the new guest artifacts (70); today's hook execs the host binary (`Sources/Fjord/Forms.swift:616-626`) and plugin uses host absolute paths (`ClaudePlugin.swift:38-43`).
3. **DECIDED (95 A-20):** A remote macOS screen uses the existing Screen Sharing stream and controller viewer route (§5).
   - Independent per-client viewer connections are NEW, justified by 95 A-28; browser-origin qualification remains a technical probe (40 OQ3/B-21).
4. **DECIDED (95 A-21):** `silod` appears in the Dock and ⌘-Tab only while a VM window is open; it switches regular/accessory activation as windows open/close (05 §3.6).
   - B-3 confirms OS regular/Foreground and accessory/UIElement classification as the window opens/closes ([macos.md Follow-up §B-3](probes/macos.md#b-3--confirmed-for-app-classification)); login-window exclusion remains OPEN.
5. **DECIDED (95 A-8):** No GUI-driver screen lock or input lease is exposed. The existing internal Recovery setup input guard remains (§5; `engine.rs:1690-1738`).
6. **DECIDED (95 A-9):** Proof is recorded inside the VM, using its built-in macOS recorder; recording works without an engine window.
   - SETTLED B-24: use a guest ScreenCaptureKit app as its own Aqua LaunchAgent with a Silo-style Screen Recording TCC grant and approval ledger; a finalized movie was retrieved without a host view. SSH `screencapture` failed. This remains guest orchestration through generic guest methods, with no engine recording method (40 §5; [macos.md Follow-up §B-24](probes/macos.md#b-24-macos--confirmed)).
7. **DECIDED (95 A-10):** Add stable snake_case macOS refusal, guest exec and file codes to `ErrorCode` and its fixtures.
   - macOS codes are NEW: `running_limit`, `needs_personalizing`, `not_running`, `setup_incomplete`, `screen_sharing_unavailable`; existing wire enum/casing is `src/bridge_error.rs:4-15`. Until implemented, today's plain sentences map to `internal` (`:104-108`); that mapping describes the snapshot, not the new contract.
8. **DECIDED (95 A-12):** Keep the platform state enums in one `computers.list` distinguished by `kind`; host resource limits belong in device facts.
   - Existing `detail` sentences stay as sourced state (§2); 95 adds no machine-readable step id.
9. **DECIDED (95 A-12):** Disks stay fixed after creation, as on Linux; macOS resource editing changes stopped-computer CPU/memory only.
   - Existing personalization growth code (`provision.rs:291-359`; MAC §Personalization) does not establish post-creation disk growth. Probe B-8 is no longer a blocker for the chosen API.
10. **DECIDED (95 A-19):** macOS gets every shared Linux feature method in this API version, including Files; shared folders are not selected as its mechanism.
    - Guest SFTP is confirmed by B-14 (`/usr/libexec/sftp-server`, MaxSessions 10, OpenSSH 10.3p1; [macos.md §B-14](probes/macos.md#b-14--confirmed)); Files roots remain 50 Q14/C-7. B-5 qualifies an added VirtioFS mount but selects no shared-folder API.
11. **DECIDED (95 A-19; 95 §3):** Remote macOS checkpoints use canonical `checkpoints.*` names and `computerId`; old `checkpoint.*` names are retired.
    - Exact platform-specific serialization and source dispatch adaptation remain 20's contract and technical research (80 §4 C-5); no wire alias is retained.
12. **DECIDED (95 A-37):** Bounded `guest.exec` preserves stdout-overflow error with a configurable cap; long Triage runs use `guest.exec.start`.
    - PARTLY B-32 reproduced overflow/timeout; its proposed limits are inferred, with workload defaults and stderr/frame bounds still OPEN ([linux.md §B-32](probes/linux.md#b-32--run_capped-overflow-and-timeout); 70); today's longest setup timeouts are 30 minutes (`guest_computer_use.rs:39`, `41`).
13. **SETTLED B-23:** SSH can enter the console user's GUI bootstrap context with `launchctl asuser` and run as `silo`; the probe saw one active 1280×800 display ([macos.md §B-23](probes/macos.md#b-23--confirmed)). This grants no capture permission: the recorder still needs its own identity/TCC row (40 §5).

14. **DECIDED (95 A-4):** Remote engines push `computers.changed` state with sequence numbers over a Stream-class bridge subscription; the local engine relays it to the client (95 A-3; 05 §4.2 D).
15. **DECIDED (95 A-2):** Client Quit offers Cancel / Keep running / Stop and quit; Fjord updates/crashes never stop macOS computers.
    - `computers.list`, `computers.stop` and `engine.disconnect` implement the choice (05 §6.2). Engine crashes still destroy in-process VMs (§4).
16. **DECIDED (95 A-25, overridden by 95 §3 Job results):** Finished outcomes persist on disk across engine restart and are dropped once a client acknowledges showing them.
    - macOS create/Retry setup keep the existing `finish_workflow` boundary (`src/macos_computers.rs:374-394`), with empty result and failure data in the row (§3). `operations.job.get` reads durable completion and `operations.job.acknowledge` drops it after presentation (05 §6); generic journal/ID allocation and interrupted-work recovery remain probe B-37.
