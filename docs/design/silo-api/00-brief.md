# Brief for writing the Silo engine API spec

Every author of a section in this folder reads this first.

## What was decided (owner, 2026-10-13)

Read [95-decisions.md](95-decisions.md) next. Its §3 amendments override earlier decisions; the requirements below incorporate them.

- **Silo becomes an engine:**
  - a Rust library;
  - a long-running engine process (called `silod` here) that hosts it. On macOS it runs as a LaunchAgent in the user's GUI login session.
- **Fjord becomes the main macOS frontend.** Fjord is the Swift app in `/Users/polarzero/code/projects/lookout`. Its tools are the Router and Triage.
- **Silo's current Tauri UI** becomes one more client of the same engine while Fjord progressively rewrites the screens in Swift.
- **Hosts and controllers are Macs only.** Linux hosts, their engine service, Debian/AppImage updates and headless setup are retired; Macs still run both Linux and macOS computers (95 §3).
- **Engines on other devices** are reached over SSH, building on Silo's existing Connections bridge.
- **The API must expose everything Silo can do today except drawing UI.** Not a single feature may be dropped.
- **The API must also add what's missing,** for macOS computers and for Fjord's use.
- **macOS VM screen:** the engine owns the VM and opens its own native `VZVirtualMachineView` window when a client asks, as VMPal does. Fjord doesn't embed it.
- **Linux native display:** comes later, when microsandbox#1805 lands. The runner's frames are drawn by the frontend. Specify only the API shape that existing sources support, and mark it as later.
- **What Fjord will use the engine for:**
  - **A Computers tool:** list, create, settings, screen, checkpoints, access to GitHub and secrets.
  - **One long-lived dev computer:** usually macOS, with Xcode and LCU.
  - **Router "Runs on":** Claude desktop app sessions running inside a computer over SSH. Fjord writes the SSH connection, installs its plugin and hook in the guest, and moves message delivery, forms and presence to and from the guest.
  - **Triage "Run in a computer":** unattended headless Claude Code runs inside a computer, with a checkpoint taken before each run.
  - **Proof:** recordings inside the guest, using Linux ffmpeg or the macOS built-in recorder, with no window required (95 A-9).
  - **No screen lock or input leases** (95 A-8).
  - **An always-on host Mac,** and controllers on other Macs.
- **Jobs:** outcomes persist on disk across engine restarts until a client acknowledges showing them (95 §3).
- **Queue:** macOS work waits with “Waiting…” and Cancel instead of refusing contention (95 §3).
- **Quit:** when computers are running, Fjord asks Cancel / Keep running / Stop and quit; updates and crashes never stop computers (95 A-2).
- **Canonical names only:** no old-name aliases or compatibility dispatch; conversion is allowed only at launch through `runtime_migration` (95 §3).

## The rules: zero guesses

- **Every statement has a source.** A source is one of:
  - a file with line numbers, for code: `path/to/file.rs:123-140`;
  - a doc with a section, for Silo docs;
  - a URL, for external facts.
- **If you can't back something, it does not go in the body.** Put it under **Open questions**, with what would settle it.
- **Mark every method:**
  - **EXISTS:** the same name and behavior exist today; cite the current command or bridge method and its file:line.
  - **EXISTS (renamed):** the behavior exists today under another name; cite the current Tauri command or bridge method and its file:line. Implementation re-exposes and renames it. Renaming does not imply a retained alias.
  - **EXTENDED:** cite the existing behavior and its command/bridge file:line, then name and justify the NEW part. Platform parity, durable job outcomes and changed results count as extensions when the method already has an implementation.
  - **NEW:** no current implementation provides this behavior; justify it with a cited requirement. A requirement is a Silo doc gap ("Not covered yet"), a Fjord need (a Fjord file:line or a cited research fact), or an owner decision.
  - Count each canonical method once. EXTENDED takes precedence over a rename or a same-name match when any required platform or behavior is missing. Shared transport framing, addressing and extraction from Tauri alone do not turn an existing domain behavior into NEW.
- **Never edit Silo or Fjord code.** Only write your own section file in this folder.
- **Don't start VMs, apps or builds.** Reading files, `git log`, `grep`, the web and docs is fine.

## Silo snapshot

- **Repo:** `/Users/polarzero/code/projects/microsandbox-workspaces`, HEAD `94d81937` (2026-10-10).
- **Code:** `app/SiloUI/src-tauri/src/`. **UI:** `app/SiloUI/src/`. **Docs:** `docs/`.
- **Places to start:**
  - `main.rs` registers 159 commands (`main.rs:131-289`; the extra attribute string is in a test at `remote.rs:3510`);
  - `remote.rs` has the bridge `METHODS` (protocol v5);
  - `app/SiloUI/src/` `production-source.ts` is the frontend's contract layer, with its TypeScript types;
  - `docs/SiloUI-VOCABULARY.md`.

## Shared domains

Several sections write in parallel, so everyone uses the same domain names. When a concept exists for both Linux and macOS computers, write one method with both platforms, and note the differences per platform rather than inventing `macos.`-prefixed duplicates. Keep `macos.*` for things only macOS computers have, such as templates and the setup steps.

`engine.*` (handshake, version, capabilities) · `device.*` (this device's facts, dependencies) · `preparation.*` · `computers.*` (inventory, create, edit, delete, lifecycle, for both kinds) · `operations.*` (queue, cancel, jobs) · `activity.*` · `logs.*` · `storage.*` · `checkpoints.*` · `exports.*` (export and import) · `migration.*` · `macos.*` · `display.*` (showing a computer's screen: the macOS engine window, the Linux viewer, the remote VNC) · `desktop.*` (the Linux desktop service in the guest) · `computerUse.*` · `clipboard.*` · `files.*` · `guest.*` (exec, SSH stream, guest access) · `network.*` · `sshAccess.*` · `editor.*` / `terminal.*` (only if not UI-only) · `github.*` · `secrets.*` · `push.*` · `connections.*` · `settings.*` · `notifications.*` · `updates.*` · `events.*` (the subscription stream and every event type)

## How to write a method

Use the bridge's style of names: `domain.verb` or `domain.noun.verb` (examples: `computers.list`, `computers.start`, `checkpoints.create`, `macos.display.show`). Reuse an existing bridge name when one exists.

For each method:

```
### computers.start
- Kind: query | command | job (long, returns a job id, reports progress) | stream (raw bytes) | subscription (pushed events)
- Platforms: Linux computer / macOS computer / both; host OS if it matters
- Status: EXISTS (same name and behavior; command/bridge, file:line) | EXISTS (renamed) (current command/bridge, file:line; re-expose and rename) | EXTENDED (current command/bridge, file:line; NEW part and cited requirement) | NEW (no implementation; required by: …)
- Params: name: type — meaning (cite the type definition)
- Result: …
- Progress/events: …
- Errors: … (cite the error enum)
- Semantics: queueing, idempotency (operationId), preconditions, side effects (cite)
- Sources: …
```

Types: give the real field names from the Rust or TypeScript definitions, with file:line. Don't invent fields. If a new method needs a new type, mark the type NEW and justify each field.

## Each section file ends with

1. **Coverage table:** every Tauri command, event and bridge method in your scope, and the API method it maps to. Nothing left unmapped. If something is purely UI (window chrome or menus, for example), say "UI-only, not in API" and cite why.
2. **Open questions:** each with what would settle it.
