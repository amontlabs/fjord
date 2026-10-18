# 05: Engine architecture, process model and transport

Scope: how the Silo engine runs as a process (`silod`), what it needs from its host instead of Tauri, where it runs as a Mac LaunchAgent hosting Linux and macOS computers, the wire protocol to local and remote clients, multiple clients, and quit, update and shutdown. Feature methods (computers, checkpoints, display, and so on) are other sections; this section fixes the transport fields and the `engine.*` and `events.*` methods they use. It also fixes two things every section follows: the [event catalogue](#event-catalogue) (§ 4.2 D) and the [job contract](#job-contract) for long work, progress and cancellation (§ 4.2 E and F).

**Path conventions.** Silo snapshot: `/Users/polarzero/code/projects/microsandbox-workspaces`, HEAD `94d81937` (2026-10-10).
- `src-tauri/src/...` and `src/...` are relative to `app/SiloUI/` in that repo.
- `docs/...` is relative to that repo's root.
- `Fjord: Sources/...` and `Fjord: scripts/...` are relative to `/Users/polarzero/code/projects/lookout`.
- `cua: libs/lume/...` is the local Lume checkout `/Users/polarzero/code/projects/cua` at `5845488` (2026-10-03).

Line numbers are for those snapshots.

**Binding amendment (NEW, justified by [95 §3](95-decisions.md#3-amendments-owner-2026-10-13-later)):** The methods below are the only contract names. Silo's Tauri UI moves to them; old bridge names, old-name aliases, legacy decoders and compatibility dispatch are removed. §1–§4.1 document today's source behaviour, not retained compatibility. Both engine sockets use the canonical protocol of §4.2. Hosts are Macs only; there is no Linux service, Debian/AppImage updater, or headless Linux setup (95 §3 Linux hosts dropped). Linux computers on Mac hosts remain in scope. Only a migration executed at engine launch through existing `runtime_migration` may converge stored data to the new version (20 `migration.*`); no alternate old/new storage paths or caller-triggered migration compatibility are supported.

---

## 1. Today's process model

### 1.1 One Tauri process owns everything

- **Startup.** `main()` fixes the build channel from the bundle identifier compiled in by `tauri::generate_context!()`, before anything else (`src-tauri/src/main.rs:91-95`). It then checks `argv[1]` for the helper modes (1.2). Without one, it builds the Tauri app.
- **Single instance.** The single-instance plugin is registered first, so a second launch exits inside it before any setup runs (`src-tauri/src/main.rs:113-117`; `src-tauri/src/single_instance.rs:13-21`). The second launch focuses the running copy and shows a dialog when the executables differ (`src-tauri/src/single_instance.rs:30-52`).
- **Setup hook.** `setup` installs every subsystem in the app process (`src-tauri/src/main.rs:291-352`):
  - settings and shutdown state;
  - the operation-queue listener;
  - migration;
  - computer use;
  - the pre-upgrade backup;
  - the Connections control socket (`remote::start`);
  - secrets;
  - GitHub;
  - backup;
  - the status panel;
  - the tray and app menu;
  - the main window;
  - notifications;
  - updates;
  - the SSH-access monitor;
  - editor transports;
  - the storage monitor;
  - launch-time startup (`startup::install`).
- **Run loop.** The AppKit terminate handler is installed before the event loop starts (`src-tauri/src/main.rs:358-361`). `app.run` handles three events (`src-tauri/src/main.rs:362-380`):
  - `RunEvent::Exit`: settings backstop, then closing SSH listeners, tunnels and transfers;
  - `ExitRequested`: the graceful Quit gate;
  - `Reopen`: reopens the main window.
- **Setup failure.** It exits through `startup_failed`, which skips the Quit path because it "would stop computers that this process never managed" (`src-tauri/src/main.rs:383-401`).
- **Connections.** `docs/SiloUI-CONNECTIONS.md` § Connections states the model: "It does not install an independent management daemon". `src-tauri/src/remote.rs:1` says the same: "App-lifetime Connections. SSH only transports framed requests to the running owner."

### 1.2 Helper modes of the same executable (no Tauri runtime)

`main.rs` checks `argv[1]` before building Tauri and returns after the helper finishes (`src-tauri/src/main.rs:96-112`). The channel is still fixed first, so helpers use the right `~/.silo` or `~/.silo-dev` (`src-tauri/src/main.rs:92-95`; `docs/SiloUI-BUILD-CHANNELS.md` § One source of truth).

| Mode | Entry | What it does | Who runs it |
| --- | --- | --- | --- |
| `--remote-bridge` | `remote::run_bridge` (`src-tauri/src/remote.rs:1748-1773`) | Connects to `<state dir>/desktop-remote/control.sock` and fails with "Silo is not running on this device." if absent. Reads one frame from stdin and forwards it. For a non-stream method it watches stdin EOF, which means the controller left, and half-closes the socket. It writes `\0SILO-BRIDGE-REPLY\n` and then the reply frame to stdout. For a stream method it then splices raw bytes both ways. | sshd, as the forced command of Silo's restricted key (`src-tauri/src/remote.rs:24-30`; `src-tauri/src/channel.rs:92-103`) |
| `--remote-guest <device> <computer> [port]` | `remote::guest_stream_params` and `run_remote_stream(.., "guest.ssh", ..)` (`src-tauri/src/remote.rs:1804-1860`) | Controller side. Reads the saved device read-only (`read_existing_config_in`), runs `ssh … <bridge command>`, sends a `guest.ssh` request and splices stdio to the reply stream. A trailing port marks a published-port forward. | An editor's or ssh's `ProxyCommand` that Silo writes (`src-tauri/src/editor.rs:841-860`) |
| `--msb-ssh-serve <runtime home> <computer>` | `editor::run_transport` (`src-tauri/src/editor.rs:862-902`) | `exec`s the bundled `msb ssh serve <name> --stdio --no-start --no-inactivity-timeout` with `MSB_HOME`, `MSB_PATH` and `MSB_LIBKRUNFW_PATH`. Only AppImage builds use it, because their bundled tools have no stable path. RETIRED Linux-host helper (95 §3); no engine helper remains on Macs. | Editor `ProxyCommand` under an AppImage (`src-tauri/src/editor.rs:807-839`; `docs/SiloUI-EDITOR-HANDOFF.md` G-12 paragraph) |

The `~/.local/bin/silo-remote` link that the forced command names points at the app executable. The former AppImage target is RETIRED Linux-host source behaviour (95 §3). It refuses a translocated app (`src-tauri/src/remote.rs:338-404`). It is re-pointed on every launch while Connections is on (`src-tauri/src/remote.rs:2054-2068`).

### 1.3 Linux computers: detached `msb` runtime processes

- **Runtime commands.** Silo runs the bundled `msb` as a child with `MSB_HOME`, `MSB_PATH` and `MSB_LIBKRUNFW_PATH`, and secrets on stdin (`src-tauri/src/runtime.rs:1593-1680`).
- **Worker lock.** Only `create`, `modify`, `remove`, `stop`, `restore` and `adopt-disk` take the worker flock (`src-tauri/src/runtime.rs:1514-1521`). The lock is inherited by the child, so "A surviving child must keep the flock if Silo exits before it does" (`src-tauri/src/runtime.rs:1674-1680`).
- **Start is detached.** "Start commands do not inherit the lock, because their computer daemon intentionally survives." Recovery waits on the inherited lock for the others (`docs/SiloUI-RUNTIME-BACKUP-FINDINGS.md` § Interrupted backup and restore). The pinned MicroSandbox start "serializes detached starts" (same doc, § Standalone computer actions after app interruption).
- **Recovery after a restart.** Lifecycle recovery accounts for "A surviving detached start" (`src-tauri/src/runtime/lifecycle_recovery.rs:189`).

### 1.4 macOS computers: inside the app process, on the main queue

- **Main thread.** "Every framework object is created and used on the main thread … `initWithConfiguration` … binds them to the main queue" (`src-tauri/src/macos_computers/engine.rs:1-8`).
- **Reaching it.** Workers get there through `on_main` / `on_main_patient`, which call Tauri's `AppHandle::run_on_main_thread`. `on_main` waits for at most 10 s (`MAIN_THREAD_WAIT`, `src-tauri/src/macos_computers/engine.rs:39`, `:142-183`); `on_main_patient` waits without a bound, because its work must never be abandoned (`src-tauri/src/macos_computers/engine.rs:185-205`).
- **Docs.** "The framework runs the computer inside the Silo process, on its main queue. A crash of Silo therefore turns its macOS computers off abruptly" (`docs/SiloUI-MACOS-COMPUTERS.md` § Development and signing). The engine research agrees: "The VM, its installer and its view belong to the main queue of the Silo process" (`docs/research/macos-guest-engine-2026-10-09.md` § Framework constraints found).
- **Screen window.** The screen is a Tauri `WebviewWindow` on `about:blank` with a native `VZVirtualMachineView` added to its `NSWindow` content view (`src-tauri/src/macos_computers.rs:2205-2240`; `src-tauri/src/macos_computers/engine.rs:1449-1518`). Setup also opens a "Setting up" window, which it reads with Vision to type the Recovery sequence (`docs/SiloUI-MACOS-COMPUTERS.md` § Provisioning for computer use, step 3; § On another Mac).
- **Why in-process.** "a `VZVirtualMachineView` must be in the process that owns the `VZVirtualMachine`" (`docs/research/macos-guest-engine-2026-10-09.md` § Decision).

### 1.5 Other children and listeners owned by the app process

- **Owned tunnels** (`src-tauri/src/owned_tunnel.rs:1-46`). Each forward runs under a `/bin/sh` watchdog that leads its own process group and watches a pipe held by Silo. "ends the whole group … when Silo's end of stdin closes: on Drop, and also when Silo crashes or is force-quit, since the kernel closes it then" (`src-tauri/src/owned_tunnel.rs:8-11`). Published-port and desktop forwards share it (`docs/SiloUI-CONNECTIONS.md` § Published-port readiness, last paragraph). Controller tunnels live in `remote_network.rs` and are closed by `close_all` (`src-tauri/src/remote_network.rs:771-780`).
- **SSH-access listeners.** "Opt-in SSH listeners with isolated client keys and pipe-owned runtime children" (`src-tauri/src/ssh_access.rs:1`). They are closed by `close_all` (`src-tauri/src/ssh_access.rs:504-513`).
- **Transfers.** In-process SFTP transfers are cancelled and drained by `transfer::close_all` (`src-tauri/src/transfer.rs:1179-1190`).
- **Control socket** `control.sock`, held under `control.lock` (`src-tauri/src/remote.rs:2014-2050`). See 4.1.

### 1.6 What survives a quit, a crash, a session end or an update

| Event | Linux computers (`msb`) | macOS computers | Owned tunnels, SSH listeners, transfers | Accepted remote changes |
| --- | --- | --- | --- | --- |
| **Quit** (menu, ⌘Q, tray, Dock) | Stopped and verified. Quit takes the device-wide gate, closes SSH access and viewers, stops macOS computers, then stops every present Linux computer in parallel (`src-tauri/src/runtime/shutdown.rs:96-129`, `:158-283`). A stop failure keeps Silo open (`src-tauri/src/settings.rs:879-895`). | Asked to shut down, then forced off at the deadline (`src-tauri/src/macos_computers.rs:2421-2429`; `docs/SiloUI-MACOS-COMPUTERS.md` § Behaviour, Quit). Disk images are detached (`src-tauri/src/macos_computers.rs:2431-2449`). | Closed (`src-tauri/src/settings.rs:914`; `src-tauri/src/runtime/shutdown.rs:104-110`). Transfers get up to 5 s (`src-tauri/src/runtime/shutdown.rs:61-70`). | New ones are refused (`ensure_accepting_operations`, `src-tauri/src/runtime/shutdown.rs:50-58`). Remote retries stop with `cancelled` (`src-tauri/src/remote.rs:1308-1316`). "Computers on other devices are not stopped" (`docs/SiloUI-CONNECTIONS.md` § Close and Quit). |
| **Session end** (logout, restart, shutdown, SIGTERM) | Stopped within `SESSION_END_BUDGET` = 20 s; a failure never cancels the exit (`src-tauri/src/system_shutdown.rs:1-13`, `:23`, `:87-104`; `src-tauri/src/settings.rs:981-1018`) | Same path | Same | Same |
| **AppKit terminate without asking** (`RunEvent::Exit` without approval) | `exit_backstop` stops computers within 20 s (`src-tauri/src/settings.rs:1026-1041`) | Same | `RunEvent::Exit` closes them (`src-tauri/src/main.rs:363-367`) | — |
| **Crash or kill** | **Survive**: detached daemons (1.3) | **Turned off abruptly**: in-process (1.4) | Tunnels end through the watchdog pipe (`src-tauri/src/owned_tunnel.rs:8-11`); in-process listeners die with the process | On-disk markers keep a restarted owner from replaying (`src-tauri/src/remote/operations.rs:1-9`, `:146-157`) |
| **Update** (Tauri updater) | The running set is written to `update-resume.json`, then stopped (`src-tauri/src/runtime/update_recovery.rs:1-2`, `:184-230`). The updater restarts the app; startup resumes exactly that set (`src-tauri/src/startup.rs:227-233`; `src-tauri/src/runtime/update_recovery.rs:300-310`). | **Update refused** while any macOS computer is busy or running: "macOS computers live in this process and cannot be restored" (`src-tauri/src/updates.rs:806-811`; `src-tauri/src/macos_computers.rs:466-472`, `:2417-2419`) | Transfers paused, then closed (`src-tauri/src/updates.rs:671-682`, `:827-841`) | Admission closed before restart (`src-tauri/src/updates.rs:845-851`) |

Durable journals that a relaunch resumes, in order (`src-tauri/src/startup.rs:153-268`):
1. backup and restore (`backup-operation.json`, `docs/SiloUI-RUNTIME-BACKUP-FINDINGS.md` § Interrupted backup and restore);
2. configuration recovery;
3. lifecycle recovery;
4. update resume;
5. then the optional "start at launch".

---

## 2. Tauri coupling to remove

### 2.1 Method

I scanned every non-test `.rs` file under `src-tauri/src/`:
- skipped `*_tests.rs`, `test_support*`, `desktop_viewer_bench*`, and `#[cfg(test)]` modules and items;
- removed string literals and `//` comments before matching;
- counted lines, so one line can fall into several categories.

The scanner is not checked in. It found:
- 617 lines that mention `AppHandle`;
- 159 `#[tauri::command]` functions, exactly the 159 entries of `generate_handler!` (`src-tauri/src/main.rs:130-290`). The brief's 160 is a plain `grep` count that includes one more `#[tauri::command` string, inside a test at `src-tauri/src/remote.rs:3510`.

Categories and what they match:

| Category | Matches | What it is used for |
| --- | --- | --- |
| Paths | `app_data_dir`, `app_config_dir`, `app_cache_dir`, `app_log_dir`, `resource_dir`, `home_dir` on Tauri's path resolver | Where data, settings, logs and bundled tools live |
| Event emission | `.emit(`, `.emit_to(` | Notifying webviews |
| `run_on_main_thread` | the call | Reaching the AppKit or GTK main thread |
| Window creation and control | `WebviewWindowBuilder`, `get_webview_window`, `ns_window`, `on_window_event`, `set_focus`, … | Main, status, viewer, help and macOS display windows |
| Dialogs | `tauri_plugin_dialog`, `.dialog()` | Pickers and message boxes |
| Opener | `tauri_plugin_opener` | Reveal in Finder |
| Updater | `tauri_plugin_updater`, `.restart()`, `RESTART_EXIT_CODE` | Self-update and restart |
| Tray | `TrayIcon*`, `tray_by_id` | Status item |
| Other: menu | `tauri::menu` types, `set_menu`, `on_menu_event` | Native app menu |
| Other: managed state | `.manage(`, `.state::<`, `State<'_` | Process-wide singletons |
| Other: async runtime | `tauri::async_runtime` | tokio spawn and `spawn_blocking` |
| Other: caller window | `window: WebviewWindow` or `Window` params, `.label()` | Which window called: main-only checks, per-window ownership |
| Other: exit and run events | `RunEvent`, `ExitRequestApi`, `app.exit(` | Process lifecycle |
| Other: identity | `generate_context`, `package_info()`, `bundle_type()` | Channel, version, package kind |
| Other: theme | `set_theme`, `tauri::Theme` | Native appearance |
| Other: plugins | `.plugin(`, single-instance | Plugin wiring |
| Other: `tauri::Url` | the type | Window URLs |
| Other: command macro | `#[tauri::command]` | IPC entry points |

### 2.2 Counts per module

Columns:
- `AppHandle`: lines mentioning `AppHandle`;
- `paths`: paths;
- `emit`: emission;
- `main`: `run_on_main_thread`;
- `win`: windows;
- `dlg`: dialogs;
- `open`: opener;
- `upd`: updater;
- `tray`: tray;
- `menu`: menu;
- `state`: managed state;
- `async`: async runtime;
- `caller`: caller window;
- `exit`: exit and run events;
- `ident`: identity;
- `theme`: theme;
- `plug`: plugins;
- `url`: `tauri::Url`;
- `cmd`: commands.

A module groups its file and its subdirectory (for example `runtime` = `runtime.rs` + `runtime/*`).

| Module | AppHandle | paths | emit | main | win | dlg | open | upd | tray | menu | state | async | caller | exit | ident | theme | plug | url | cmd |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `macos_computers` | 175 | 2 | 1 | 4 | 13 |  |  |  |  |  |  | 3 | 11 |  |  |  |  | 1 | 10 |
| `runtime` | 53 | 11 | 20 |  |  |  |  |  |  |  |  | 15 | 1 |  | 1 |  |  |  | 20 |
| `github` | 35 | 1 | 7 |  | 2 |  |  |  |  |  |  | 10 | 18 |  |  |  |  |  | 10 |
| `settings` | 30 | 1 | 5 |  | 6 |  |  | 1 |  |  | 26 | 4 | 22 | 5 |  | 4 |  |  | 12 |
| `backup_controller` | 26 | 2 | 1 |  |  | 3 | 1 |  |  |  | 16 | 13 | 13 |  |  |  |  |  | 11 |
| `runtime_migration` | 20 | 4 | 2 |  |  |  |  | 2 |  |  | 10 | 5 |  |  |  |  |  |  | 3 |
| `remote` | 17 |  |  |  |  |  |  |  |  |  |  | 10 |  |  |  |  |  |  | 12 |
| `chatgpt_app` | 15 | 1 | 1 |  |  |  |  |  |  |  |  | 1 |  |  |  |  |  |  | 2 |
| `updates` | 15 | 1 | 5 |  |  |  |  | 5 |  |  | 9 | 5 |  |  | 2 |  |  |  | 6 |
| `system_shutdown` | 14 |  |  | 1 |  |  |  |  |  |  |  | 1 |  | 1 |  |  |  |  |  |
| `remote_network` | 11 |  | 1 |  |  |  |  |  |  |  |  | 5 |  |  |  |  |  |  | 4 |
| `desktop` | 10 |  | 2 |  |  |  |  |  |  |  |  | 2 | 3 |  |  |  |  |  | 3 |
| `editor` | 10 | 8 | 1 |  |  |  |  |  |  |  |  | 1 | 2 |  | 1 |  |  |  | 1 |
| `applications` | 9 |  |  | 2 |  | 2 |  |  |  |  |  | 2 | 4 |  |  |  |  |  | 2 |
| `host_push_operations` | 9 |  | 1 |  |  |  |  |  |  |  |  | 4 |  |  |  |  |  |  | 2 |
| `notifications` | 9 |  | 1 |  | 1 |  |  |  |  |  |  | 2 |  |  |  |  |  |  | 2 |
| `status_panel` | 9 |  | 2 |  | 20 |  |  |  |  |  | 6 |  |  |  |  |  |  |  | 5 |
| `system_integrations` | 9 |  |  | 1 |  | 2 |  |  |  |  |  | 4 | 6 |  |  |  |  |  | 5 |
| `tray` | 9 |  |  | 1 | 2 |  |  |  | 4 |  | 6 | 1 |  |  |  |  |  |  | 1 |
| `app_menu` | 8 | 2 | 1 | 1 | 9 |  |  |  |  | 17 | 4 | 1 | 4 |  | 1 |  |  | 2 | 2 |
| `desktop_viewer` | 8 | 1 | 1 | 1 | 21 |  |  |  |  |  |  | 4 | 19 |  |  |  |  | 4 | 4 |
| `pre_upgrade_backup` | 8 | 4 | 2 |  |  |  | 1 |  |  |  |  | 1 | 6 |  |  |  |  |  | 5 |
| `macos_remote` | 7 |  |  |  |  |  |  |  |  |  |  | 1 | 5 |  |  |  |  |  | 3 |
| `macos_remote_viewer` | 7 |  |  |  | 7 |  |  |  |  |  |  | 3 | 6 |  |  |  |  | 1 | 3 |
| `network` | 7 |  | 1 |  |  |  |  |  |  |  |  | 2 |  |  |  |  |  |  | 4 |
| `secrets` | 7 | 1 | 5 |  |  |  |  |  |  |  |  | 4 | 4 |  |  |  |  |  | 4 |
| `ssh_access` | 7 |  | 2 |  |  |  |  |  |  |  |  | 2 |  |  |  |  |  |  | 2 |
| `viewer_shortcuts` | 7 |  |  |  | 2 |  |  |  |  |  |  |  | 3 |  |  |  |  |  |  |
| `github_personal_token` | 6 |  | 1 |  |  |  |  |  |  |  |  | 2 | 4 |  |  |  |  |  | 2 |
| `transfer` | 6 |  | 6 |  |  | 3 |  |  |  |  |  | 3 | 9 |  |  |  |  |  | 4 |
| `remote_access` | 5 |  |  |  |  |  |  |  |  |  |  | 7 |  |  |  |  |  |  |  |
| `startup` | 5 |  | 1 |  | 4 |  |  |  |  |  | 5 | 1 |  |  |  |  |  |  |  |
| `computer_use` | 4 |  | 2 |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `desktop_viewer_media` | 4 |  |  |  |  |  |  |  |  |  |  | 3 | 6 |  |  |  |  |  | 4 |
| `host_push` | 4 | 1 | 3 |  |  |  |  |  |  |  |  | 1 |  |  |  |  |  |  | 1 |
| `remote_ssh_access` | 4 |  |  |  |  |  |  |  |  |  |  | 2 |  |  |  |  |  |  | 2 |
| `runtime_logs` | 3 |  |  |  |  |  |  |  |  |  |  | 1 |  |  |  |  |  |  | 1 |
| `single_instance` | 3 |  |  |  | 1 | 2 |  |  |  |  |  |  |  |  |  |  | 3 |  |  |
| `viewer_clipboard` | 3 |  | 1 |  |  |  |  |  |  |  |  | 1 |  |  |  |  |  |  |  |
| `bundled_tools` | 2 | 1 |  |  |  |  |  |  |  |  |  |  |  |  | 1 |  |  |  |  |
| `creation_inputs` | 2 |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `dependencies` | 2 | 10 |  |  |  |  |  |  |  |  |  | 1 |  |  | 1 |  |  |  | 1 |
| `files` | 2 |  |  |  |  |  |  |  |  |  |  | 1 |  |  |  |  |  |  | 1 |
| `health_watch` | 2 |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `log_export` | 2 |  |  |  |  | 2 |  |  |  |  |  | 1 | 3 |  |  |  |  |  | 2 |
| `preparation` | 2 | 1 | 1 |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | 2 |
| `ssh_connection` | 2 |  |  |  |  | 2 |  |  |  |  |  | 1 | 2 |  |  |  |  |  | 1 |
| `terminal` | 2 |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `main` | 1 |  | 1 |  | 9 | 3 |  | 1 |  |  |  |  | 1 | 3 | 2 |  | 3 | 1 |  |
| `titlebar` | 0 |  |  | 1 | 6 |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| `window_material` | 0 |  |  | 1 | 1 |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| **Total** | 617 | 52 | 78 | 13 | 104 | 19 | 2 | 9 | 4 | 17 | 82 | 131 | 152 | 9 | 9 | 4 | 6 | 9 | 159 |

The `AppHandle` column counts every line that names the type, mostly parameters passed through to reach the capabilities in the other columns. For example, the 175 in `macos_computers` carry the handle down to `on_main` and `app_data` (`src-tauri/src/macos_computers/engine.rs:142-205`; `src-tauri/src/macos_computers.rs:518-522`).

### 2.3 Call sites by category (file:line)

Paths are relative to `src-tauri/src/`.

**Paths** (52 lines)

`app_menu.rs`: 431, 451; `backup_controller.rs`: 262, 278; `bundled_tools.rs`: 11; `chatgpt_app.rs`: 1931; `dependencies.rs`: 207, 231, 871, 892, 1003, 1120, 1152, 1269, 1271, 1284; `desktop_viewer.rs`: 282; `editor.rs`: 38, 86, 766, 1119, 1152, 1154, 1193, 1230; `github.rs`: 769; `host_push.rs`: 798; `macos_computers.rs`: 520; `macos_computers/setup_log.rs`: 38; `pre_upgrade_backup.rs`: 439, 442, 472, 514; `preparation.rs`: 243; `runtime.rs`: 755, 774, 776, 778, 781, 786, 795, 802, 820, 825, 845; `runtime_migration.rs`: 824; `runtime_migration/vocabulary.rs`: 176, 178, 179; `secrets.rs`: 906; `settings.rs`: 700; `updates.rs`: 233

**Event emission** (78 lines)

`app_menu.rs`: 497; `backup_controller.rs`: 413; `chatgpt_app.rs`: 1985; `computer_use.rs`: 1348, 1366; `desktop.rs`: 824, 848; `desktop_viewer.rs`: 649; `editor.rs`: 1099; `github.rs`: 266, 441, 667, 820, 1137, 2585, 3069; `github_personal_token.rs`: 247; `host_push.rs`: 92, 1219, 1241; `host_push_operations.rs`: 224; `macos_computers.rs`: 668; `main.rs`: 299; `network.rs`: 822; `notifications.rs`: 126; `pre_upgrade_backup.rs`: 450, 517; `preparation.rs`: 233; `remote_network.rs`: 541; `runtime.rs`: 3343, 3348, 3371, 3586, 4181, 4183; `runtime/checkpoints.rs`: 804, 1797, 2208, 2493, 2768; `runtime/configuration_recovery.rs`: 604, 632, 646; `runtime/lifecycle_recovery.rs`: 449; `runtime/remote_ops.rs`: 49, 101, 112, 127; `runtime/shutdown.rs`: 127; `runtime_migration.rs`: 961, 1030; `secrets.rs`: 531, 777, 849, 869, 929; `settings.rs`: 759, 924, 960, 962, 1143; `ssh_access.rs`: 667, 963; `startup.rs`: 243; `status_panel.rs`: 68, 160; `transfer.rs`: 1288, 1291, 1294, 1300, 1398, 1449; `updates.rs`: 171, 335, 445, 536, 795; `viewer_clipboard.rs`: 254

**run_on_main_thread** (13 lines)

`app_menu.rs`: 92; `applications.rs`: 208, 268; `desktop_viewer.rs`: 422; `macos_computers/engine.rs`: 156, 196, 1434, 1521; `system_integrations/macos.rs`: 210; `system_shutdown/macos.rs`: 150; `titlebar.rs`: 9; `tray.rs`: 139; `window_material.rs`: 69

**Window creation and control** (104 lines)

`app_menu.rs`: 363, 400, 436, 479, 528, 531, 532, 541, 543; `desktop_viewer.rs`: 20, 21, 372, 377, 382, 384, 396, 397, 401, 413, 416, 485, 573, 579, 594, 629, 631, 653, 667, 687, 725; `github.rs`: 2775, 2777; `macos_computers.rs`: 2210, 2212, 2215, 2221, 2223, 2229, 2230, 2237, 2244, 2247; `macos_computers/engine.rs`: 1436, 1439, 1461; `macos_remote_viewer.rs`: 19, 127, 129, 138, 140, 145, 146; `main.rs`: 81, 121, 315, 320, 321, 324, 327, 392, 393; `notifications.rs`: 293; `settings.rs`: 930, 932, 961, 1127, 1139, 1140; `single_instance.rs`: 48; `startup.rs`: 165, 196, 219, 258; `status_panel.rs`: 4, 17, 20, 21, 22, 33, 49, 70, 74, 91, 92, 93, 99, 101, 137, 140, 147, 163, 167, 168; `titlebar.rs`: 2, 10, 57, 60, 61, 62; `tray.rs`: 58, 185; `viewer_shortcuts.rs`: 138, 268; `window_material.rs`: 13

**Dialogs** (19 lines)

`applications.rs`: 4, 236; `backup_controller.rs`: 17, 524, 554; `log_export.rs`: 13, 95; `main.rs`: 128, 387, 396; `single_instance.rs`: 11, 41; `ssh_connection.rs`: 9, 174; `system_integrations.rs`: 3, 112; `transfer.rs`: 35, 1350, 1461

**Opener plugin** (2 lines)

`backup_controller.rs`: 727; `pre_upgrade_backup.rs`: 536

**Updater** (9 lines)

`main.rs`: 129; `runtime_migration.rs`: 683, 1077; `settings.rs`: 690; `updates.rs`: 17, 449, 496, 497, 851

**Tray** (4 lines)

`tray.rs`: 36, 39, 45, 75

**Other: native menu** (17 lines)

`app_menu.rs`: 123, 177, 199, 218, 230, 248, 255, 263, 289, 306, 321, 335, 345, 355, 358, 364, 373

**Other: managed state** (82 lines)

`app_menu.rs`: 135, 144, 367, 391; `backup_controller.rs`: 308, 333, 454, 510, 576, 634, 711, 785, 807, 1568, 1631, 2056, 2120, 2150, 5675, 5690; `runtime_migration.rs`: 656, 836, 848, 895, 915, 949, 967, 1020, 1028, 1044; `settings.rs`: 704, 705, 706, 711, 727, 767, 782, 880, 899, 921, 938, 954, 976, 984, 1001, 1009, 1022, 1029, 1045, 1126, 1128, 1155, 1172, 1185, 1195, 2264; `startup.rs`: 154, 157, 271, 276, 282; `status_panel.rs`: 15, 25, 52, 78, 156, 173; `tray.rs`: 216, 235, 243, 255, 257, 274; `updates.rs`: 164, 242, 285, 296, 331, 417, 474, 515, 767

**Other: async runtime** (131 lines)

`app_menu.rs`: 458; `applications.rs`: 195, 230; `backup_controller.rs`: 457, 514, 552, 584, 725, 816, 901, 1639, 1727, 2060, 2126, 2155; `backup_controller/recovery.rs`: 928; `chatgpt_app.rs`: 2274; `dependencies.rs`: 1279; `desktop.rs`: 890, 911; `desktop_viewer.rs`: 325, 571, 708, 717; `desktop_viewer_media.rs`: 313, 349, 365; `editor.rs`: 1124; `files.rs`: 150; `github.rs`: 3023, 3033, 3045, 3059, 3079, 3093, 3149, 3178, 3343, 3413; `github_personal_token.rs`: 323, 359; `host_push.rs`: 76; `host_push_operations.rs`: 214, 222, 410, 442; `log_export.rs`: 91; `macos_computers.rs`: 774; `macos_computers/guest_clipboard.rs`: 295; `macos_computers/restore_image.rs`: 234; `macos_remote.rs`: 123; `macos_remote_viewer.rs`: 109, 205, 288; `network.rs`: 828, 950; `notifications.rs`: 138, 286; `pre_upgrade_backup.rs`: 480; `remote.rs`: 324, 448, 515, 818, 1372, 1402, 1473, 1591, 1691, 1731; `remote_access.rs`: 56, 99, 117, 137, 151, 158, 169; `remote_network.rs`: 194, 652, 665, 716, 736; `remote_ssh_access.rs`: 44, 60; `runtime.rs`: 2042, 2157, 2653, 2669, 2881, 3265, 3283, 4107, 4265, 4333; `runtime/checkpoints.rs`: 2901; `runtime/operation_gate.rs`: 496, 502; `runtime/remote_ops.rs`: 7; `runtime/storage.rs`: 760; `runtime_logs.rs`: 716; `runtime_migration.rs`: 681, 971, 987, 1023, 1075; `secrets.rs`: 792, 803, 864, 883; `settings.rs`: 726, 766, 781, 1209; `ssh_access.rs`: 628, 649; `ssh_connection.rs`: 132; `startup.rs`: 156; `system_integrations.rs`: 65, 77, 88, 100; `system_shutdown.rs`: 89; `transfer.rs`: 1348, 1394, 1446; `tray.rs`: 222; `updates.rs`: 275, 294, 329, 799, 870; `viewer_clipboard.rs`: 252

**Other: caller window/label** (152 lines)

`app_menu.rs`: 71, 74, 84, 85; `applications.rs`: 189, 192, 224, 227; `backup_controller.rs`: 406, 509, 549, 575, 633, 710, 784, 806, 1567, 1630, 2055, 2119, 2149; `desktop.rs`: 885, 944, 953; `desktop_viewer.rs`: 161, 167, 319, 322, 547, 556, 573, 593, 597, 616, 628, 655, 674, 699, 703, 707, 716, 721, 725; `desktop_viewer_media.rs`: 295, 299, 307, 332, 341, 361; `editor.rs`: 1114, 1116; `github.rs`: 3040, 3042, 3056, 3058, 3077, 3078, 3091, 3092, 3110, 3112, 3143, 3145, 3170, 3173, 3330, 3333, 3407, 3410; `github_personal_token.rs`: 319, 322, 356, 358; `log_export.rs`: 28, 74, 83; `macos_computers.rs`: 756, 784, 798, 815, 826, 840, 852, 865, 878, 891, 905; `macos_remote.rs`: 113, 118, 134, 144, 158; `macos_remote_viewer.rs`: 92, 102, 106, 201, 204, 283; `main.rs`: 120; `pre_upgrade_backup.rs`: 463, 489, 500, 510, 525, 546; `runtime.rs`: 4347; `secrets.rs`: 783, 799, 860, 879; `settings.rs`: 723, 725, 779, 780, 796, 799, 806, 809, 816, 819, 832, 833, 1153, 1154, 1166, 1170, 1183, 1184, 1193, 1194, 1207, 1208; `ssh_connection.rs`: 122, 129; `system_integrations.rs`: 48, 62, 73, 85, 96, 108; `transfer.rs`: 1308, 1344, 1347, 1374, 1388, 1392, 1432, 1483, 1484; `viewer_shortcuts.rs`: 275, 281, 316

**Other: app exit and run events** (9 lines)

`main.rs`: 363, 369, 373; `settings.rs`: 937, 1129, 1134, 1147, 1175; `system_shutdown.rs`: 113

**Other: identity, version, bundle type** (9 lines)

`app_menu.rs`: 193; `bundled_tools.rs`: 17; `dependencies.rs`: 893; `editor.rs`: 878; `main.rs`: 94, 95; `runtime.rs`: 803; `updates.rs`: 252, 261

**Other: native theme** (4 lines)

`settings.rs`: 29, 31, 32, 751

**Other: plugins (single instance)** (6 lines)

`main.rs`: 117, 128, 129; `single_instance.rs`: 15, 16, 27

**Other: tauri::Url** (9 lines)

`app_menu.rs`: 516, 538; `desktop_viewer.rs`: 357, 538, 541, 631; `macos_computers.rs`: 2220; `macos_remote_viewer.rs`: 52; `main.rs`: 391

**Other: #[tauri::command]** (159 lines)

`app_menu.rs`: 68, 83; `applications.rs`: 186, 221; `backup_controller.rs`: 452, 506, 546, 573, 631, 708, 781, 1564, 2053, 2116, 2146; `chatgpt_app.rs`: 2317, 2334; `dependencies.rs`: 1259; `desktop.rs`: 882, 941, 950; `desktop_viewer.rs`: 316, 544, 696, 715; `desktop_viewer_media.rs`: 304, 331, 338, 358; `editor.rs`: 1111; `files.rs`: 139; `github.rs`: 3031, 3037, 3053, 3076, 3090, 3107, 3140, 3167, 3327, 3404; `github_personal_token.rs`: 316, 353; `host_push.rs`: 69; `host_push_operations.rs`: 402, 435; `log_export.rs`: 73, 80; `macos_computers.rs`: 781, 797, 812, 823, 837, 849, 862, 875, 888, 902; `macos_remote.rs`: 131, 141, 155; `macos_remote_viewer.rs`: 99, 198, 280; `network.rs`: 826, 841, 900, 944; `notifications.rs`: 316, 321; `pre_upgrade_backup.rs`: 486, 497, 507, 522, 543; `preparation.rs`: 355, 361; `remote.rs`: 328, 410, 437, 445, 511, 815, 1362, 1400, 1467, 1578, 1684, 1722; `remote_network.rs`: 650, 656, 709, 729; `remote_ssh_access.rs`: 39, 50; `runtime.rs`: 55, 62, 2037, 2147, 2649, 2663, 2876, 3255, 3616, 4103, 4252, 4321; `runtime/checkpoints.rs`: 777, 1775, 2182, 2471, 2747, 2896; `runtime/storage.rs`: 745, 752; `runtime_logs.rs`: 711; `runtime_migration.rs`: 965, 992, 1036; `secrets.rs`: 789, 796, 857, 876; `settings.rs`: 720, 778, 793, 803, 813, 831, 1043, 1152, 1163, 1182, 1192, 1206; `ssh_access.rs`: 626, 640; `ssh_connection.rs`: 119; `status_panel.rs`: 131, 145, 153, 171, 176; `system_integrations.rs`: 59, 70, 82, 93, 105; `transfer.rs`: 1341, 1371, 1429, 1482; `tray.rs`: 405; `updates.rs`: 292, 323, 370, 512, 761, 866

### 2.4 What each category is used for

**Paths (52 lines; 17 modules).** All of them resolve Silo's per-identifier directories or the bundle's resources:
- `app_data_dir`: runtime home and storage (`src-tauri/src/runtime.rs:755-845`), macOS computers (`src-tauri/src/macos_computers.rs:518-522`), secrets, GitHub, ChatGPT, backups, migration, updates, pre-upgrade backup, preparation;
- `app_config_dir`: settings (`src-tauri/src/settings.rs:699-701`; `src-tauri/src/runtime_migration/vocabulary.rs:178`);
- `app_cache_dir`: backup scratch (`src-tauri/src/backup_controller.rs:262`);
- `app_log_dir`: macOS setup logs (`src-tauri/src/macos_computers/setup_log.rs:38`);
- `resource_dir`: bundled `msb`, Git and the help files (`src-tauri/src/bundled_tools.rs:11`; `src-tauri/src/dependencies.rs:1269-1284`; `src-tauri/src/runtime.rs:774-776`; `src-tauri/src/host_push.rs:798`; `src-tauri/src/app_menu.rs:431`, `:451`);
- `home_dir`: editor SSH files (`src-tauri/src/editor.rs:38`, `:86`, `:766`, `:1119`, `:1193`, `:1230`) and the storage migration's state directory (`src-tauri/src/runtime_migration/vocabulary.rs:176`).

Tauri keys these directories by bundle identifier (`docs/SiloUI-BUILD-CHANNELS.md` § Shared state that is now per channel; `docs/SiloUI-SETTINGS.md` § Saved values, last paragraphs). An engine that is not the Tauri bundle must compute the same directories, or it orphans existing data. The doc warns "A production identifier, path, or name must never change: existing users' data lives there" (`docs/SiloUI-BUILD-CHANNELS.md`, intro). Engine-side.

**Event emission (78 calls; 33 files).** Every call is listed in the coverage table (§ 9) with its payload.
- 40 calls send the payload-less `silo://application-state-changed` hint, and the UI re-reads state when it arrives (`src/desktop/production-source.ts:1080-1086`).
- 16 calls use `emit_to` a specific window label (`"main"`, `"status"`, a viewer shell). In a multi-client engine those become per-client or UI-only.

Engine-side, except the window-targeted UI ones listed in § 9.

**`run_on_main_thread` (13 calls).**
- Engine-side (4): the macOS VM and display-window calls (`src-tauri/src/macos_computers/engine.rs:156`, `:196`, `:1434`, `:1521`).
- Engine or host side: the AppKit terminate reply (`src-tauri/src/system_shutdown/macos.rs:150`), which is engine-side only while the engine owns an `NSApplication` (§ 3.4).
- Client: notification-center delegate install (`src-tauri/src/system_integrations/macos.rs:210`).
- UI-only: Linux icon loading and the app picker (`src-tauri/src/applications.rs:208`, `:268`), Linux menu popup (`src-tauri/src/app_menu.rs:92`), viewer (`src-tauri/src/desktop_viewer.rs:422`), titlebar (`src-tauri/src/titlebar.rs:9`), tray (`src-tauri/src/tray.rs:139`), window material (`src-tauri/src/window_material.rs:69`).

**Window creation and control (104 lines).**
- Engine-side by owner decision ("the engine owns the VM and opens its own native `VZVirtualMachineView` window"): only the macOS display window (`src-tauri/src/macos_computers.rs:2209-2249`; `src-tauri/src/macos_computers/engine.rs:1432-1535`, `:1595-1623`) and the setup window that reads its own screen (§ 1.4).
- UI-only:
  - the main window (`src-tauri/src/main.rs:313-337`);
  - the status panel (`src-tauri/src/status_panel.rs:13-179`);
  - the Linux desktop viewer (`src-tauri/src/desktop_viewer.rs:372-726`);
  - the macOS remote noVNC viewer (`src-tauri/src/macos_remote_viewer.rs:127-150`);
  - help (`src-tauri/src/app_menu.rs:528-545`);
  - titlebar and material (`src-tauri/src/titlebar.rs`, `src-tauri/src/window_material.rs`);
  - viewer shortcuts (`src-tauri/src/viewer_shortcuts.rs:138`, `:268`).
- Engine logic that reaches for the main window today, which must stop doing so:
  - `startup.rs:165`, `:196`, `:219`, `:258` show startup errors in a dialog parented to `main`;
  - `settings.rs:930`, `:961`, `:1127-1140` show, focus and target the main window during Quit;
  - `notifications.rs:291-296` reads whether the main window is focused, to choose between toast and system notification;
  - `github.rs:2775-2777` focuses `main` after OAuth.

**Dialogs (19 lines; 8 files).** All UI-only. Their results become parameters:

| Command | Dialog | Engine parameter instead |
| --- | --- | --- |
| `choose_backup_destination` (`src-tauri/src/backup_controller.rs:506-543`) | Folder picker | It also canonicalizes the path and remembers it as the next default (`remember_destination`). The engine keeps that as a setter taking a path. |
| `choose_backup_archive` (`src-tauri/src/backup_controller.rs:546-570`) | File picker | Path |
| `choose_upload_files` (`src-tauri/src/transfer.rs:1342-1370`) | File picker | Paths. It also issues a selection token bound to the window label (`issue_selection(&owner, paths)`), which becomes per client (§ 5). |
| `download_file` (`src-tauri/src/transfer.rs:1430-1470`) | Save dialog in the middle of a transfer | Destination path, chosen before the call |
| `export_computer_logs` (`src-tauri/src/log_export.rs:80-115`) | Save dialog | Destination path |
| `ssh_connection` with `download: true` (`src-tauri/src/ssh_connection.rs:118-180`) | Save dialog | Destination path |
| `choose_application` (`src-tauri/src/applications.rs:219-245`) | App picker | Client-only: the terminal, editor and browser choice is a client preference (§ 5) |
| `show_integration_error` (`src-tauri/src/system_integrations.rs:104-118`) | Error box | Engine work calls it for startup failures (`src-tauri/src/startup.rs:164-171`, `:195-205`, `:218-224`, `:257-264`) and failed Quit (`src-tauri/src/settings.rs:929-933`). These become `notifications.notice` events (§ 4.2). |
| `startup_failed` (`src-tauri/src/main.rs:383-401`) | Error box | Engine exit status plus a log line; the client shows it |
| `single_instance::second_launch` (`src-tauri/src/single_instance.rs:30-52`) | Warning | Client-only |

**Opener (2).** `reveal_item_in_dir` for `reveal_backup_archive` (`src-tauri/src/backup_controller.rs:727`) and `reveal_pre_upgrade_backup` (`src-tauri/src/pre_upgrade_backup.rs:536`). UI-only: the engine returns the path and the client reveals it.

**Updater (9).** UI or host-only. Today this is Tauri's updater plugin and `AppHandle::restart` (`src-tauri/src/updates.rs:17`, `:449`, `:851`; `src-tauri/src/main.rs:129`). The migration also restarts the whole process after converting storage (`src-tauri/src/runtime_migration.rs:680-684`, `:1074-1078`). `settings.rs:690` tells a restart from a Quit. The engine needs an update handshake and a self-restart, not the plugin (§ 6).

**Tray (4), menu (17), theme (4).** UI-only:
- `src-tauri/src/tray.rs:36-75`;
- `src-tauri/src/app_menu.rs:123-373`;
- `src-tauri/src/settings.rs:29-33`, `:751` (native theme for windows).

**Managed state (82 lines).** Process singletons registered with `app.manage`:
- `SettingsState`, `ShutdownState` and `QuitConfirmation` (`src-tauri/src/settings.rs:703-707`);
- the backup `Controller` (`src-tauri/src/backup_controller.rs:308`);
- the updates `Controller` (`src-tauri/src/updates.rs:242`);
- the migration controller (`src-tauri/src/runtime_migration.rs:836`);
- `StartupState` (`src-tauri/src/startup.rs:154`);
- `PanelState` (`src-tauri/src/status_panel.rs:15`), `TrayState` (`src-tauri/src/tray.rs:216`) and the menu `Controller` (`src-tauri/src/app_menu.rs:367`).

Engine-side for the first five; the last three are UI-only. These become fields of an engine struct, which needs no capability from a host.

**Async runtime (131 lines).** `tauri::async_runtime::spawn_blocking` and `spawn` around blocking work, for example `src-tauri/src/remote.rs:322-328` and `src-tauri/src/runtime/operation_gate.rs:496-503`. Engine-side; it maps to tokio directly. The updater loop already uses `tokio::time::sleep` (`src-tauri/src/updates.rs:276-281`).

**Caller window (152 lines).** Three uses:
- **Main-only authorization.** There are 71 non-test call sites of `require_main`, `require_main_label`, `main_window_only` or `label() != "main"` (79 lines with test modules included, plus 10 definitions), for example `src-tauri/src/settings.rs:737-743`, `src-tauri/src/backup_controller.rs:405-408`, `src-tauri/src/github.rs:3040-3042` and `src-tauri/src/system_integrations.rs:47-57`.
- **Per-window ownership.** Transfer selections are keyed by window label (`src-tauri/src/transfer.rs:1347`, `:1392`, `:1483-1484`). Viewer windows check that a command comes from the viewer opened for that computer (`src-tauri/src/desktop_viewer.rs:699-707`; `src-tauri/src/macos_remote_viewer.rs:201-204`).
- **Draft hiding.** Non-main windows get no onboarding draft (`src-tauri/src/settings.rs:779-791`).

In a multi-client engine this becomes a caller identity attached to each request (§ 4.2, § 5).

**Exit and run events (9).** Process control (`src-tauri/src/main.rs:362-380`; `src-tauri/src/settings.rs:937-950`, `:1123-1180`; `src-tauri/src/system_shutdown.rs:106-114`). Engine-side as `ProcessControl`.

**Identity (9).**
- the channel from the compiled bundle identifier (`src-tauri/src/main.rs:94-95`);
- the app version (`src-tauri/src/updates.rs:252`; `src-tauri/src/app_menu.rs:193`);
- the package kind: Mac bundle; AppImage/deb branches are RETIRED Linux-host source behaviour (95 §3; `src-tauri/src/bundled_tools.rs:17`, `src-tauri/src/dependencies.rs:893`, `src-tauri/src/editor.rs:878`, `src-tauri/src/runtime.rs:803`, `src-tauri/src/updates.rs:261`).

Engine-side.

**Plugins (6), `tauri::Url` (9), command macro (159).**
- The single-instance plugin is replaced by an engine lock (§ 5).
- The URLs are window URLs and UI-only (`src-tauri/src/desktop_viewer.rs:357`, `src-tauri/src/macos_remote_viewer.rs:52`), except `about:blank` for the macOS display window (`src-tauri/src/macos_computers.rs:2220`). The engine-owned window needs no webview, so it disappears.
- Commands become the dispatch table of § 4.

### 2.5 `EngineContext`: the interface the library needs instead (NEW)

Required by:
- the owner decision ("Silo becomes … a Rust library; a long-running engine process");
- the call sites above.

There is one capability per category that has engine-side call sites. Categories that only have UI call sites get none.

```rust
/// Everything the engine library takes from its host process instead of `tauri::AppHandle`.
pub trait EngineContext: Send + Sync + 'static {
    /// Paths (52 lines, § 2.4). Same directories Tauri resolves for the channel identifier,
    /// so existing data is found (docs/SiloUI-BUILD-CHANNELS.md § Shared state …).
    fn paths(&self) -> &EnginePaths;
    /// Identity (main.rs:94-95, updates.rs:252, bundled_tools.rs:17).
    fn identity(&self) -> &EngineIdentity;
    /// Event emission (78 calls). Replaces `emit` and `emit_to`; `audience` replaces window labels.
    fn publish(&self, event: Event, audience: Audience);
    /// `run_on_main_thread` for Virtualization.framework and AppKit (engine.rs:156, :196,
    /// :1434, :1521; system_shutdown/macos.rs:150). `None` on hosts without an AppKit loop (Linux).
    fn main_thread(&self) -> Option<&dyn MainThread>;
    /// Exit and restart (main.rs:362-380, settings.rs:1123-1180, runtime_migration.rs:680-684).
    fn process(&self) -> &dyn ProcessControl;
}

pub struct EnginePaths {
    pub app_data: PathBuf,   // app_data_dir: runtime, macOS computers, secrets, backups …
    pub app_config: PathBuf, // app_config_dir: settings.json (settings.rs:699-701)
    pub app_cache: PathBuf,  // backup scratch (backup_controller.rs:262)
    pub app_log: PathBuf,    // macOS setup logs (macos_computers/setup_log.rs:38)
    pub resources: PathBuf,  // bundled msb, git, help (bundled_tools.rs:11, dependencies.rs:1269)
    pub home: PathBuf,       // editor SSH files (editor.rs:38 …); state_dir via channel.rs:77-79
}

pub struct EngineIdentity {
    pub channel: Channel,       // channel.rs:16-49, from the identifier, not from Tauri
    pub version: String,        // package version
    pub package_kind: PackageKind, // Mac bundle only (NEW, 95 §3); source enum: updates.rs:138-161
}

pub trait MainThread: Send + Sync {
    /// Runs `work` on the AppKit main thread (engine.rs:142-183 waits for it, with a timeout).
    fn run(&self, work: Box<dyn FnOnce() + Send>) -> Result<(), String>;
}

pub trait ProcessControl: Send + Sync {
    fn exit(&self, code: i32);
    /// Replaces the running engine image (runtime migration, updates).
    fn restart(&self) -> !;
}
```

| Capability | Category | Call sites it serves | Side |
| --- | --- | --- | --- |
| `paths()` | Paths | 52 lines in 17 modules (§ 2.3) | Engine |
| `identity()` | Other: identity | 9 lines (§ 2.4) | Engine |
| `publish(event, audience)` | Event emission | 78 calls (§ 2.3); window-targeted ones are classified in § 9 | Engine |
| `main_thread()` | `run_on_main_thread` | 4 engine call sites plus the AppKit terminate reply (§ 2.4) | Engine on macOS |
| `process()` | Other: exit and run events, updater restart | 9 + 3 lines | Engine |
| (none: plain Rust `Arc`s) | Other: managed state | 5 engine singletons (§ 2.4) | Engine |
| (none: tokio) | Other: async runtime | 131 lines | Engine |
| Request `Caller` (§ 4.2), not a context method | Other: caller window | 152 lines | Engine checks, client supplies |
| — | Window creation | UI windows; the macOS display window is engine-owned AppKit code (§ 3.6), not a Tauri capability | Client, except macOS display |
| — | Dialogs | 19 lines (§ 2.4 table) | **Client only** |
| — | Opener | 2 | **Client only** |
| — | Updater plugin | Tauri updater stays in the Silo UI app; Fjord has its own updater (Fjord: `Sources/Fjord/Updater.swift:7-9`) | **Client** (§ 6 handshake) |
| — | Tray, menu, theme, status panel, titlebar, material, viewer shortcuts, Url | §§ 2.3-2.4 | **Client only** |

`Audience` (NEW) replaces `emit_to(label, …)`:
- `All` replaces `emit`;
- `Client(ClientId)` replaces `emit_to("main", …)` when the event answers that client's own request, such as setup progress (`src-tauri/src/runtime.rs:3586`).

Labels such as `"status"` and `"desktop-shell-*"` do not map, because their emits are UI-only (§ 9). The clipboard outcome `desktop-clipboard` (`src-tauri/src/viewer_clipboard.rs:249-256`) is one of them: it reports a transfer that a shortcut in the Tauri shell started, and in the API the client starts every transfer itself and gets the `Report` as the method result (§ 9.3).

Native notifications are not a Tauri call today: `notify_native` delivers through the system in-process (`src-tauri/src/notifications.rs:118-138`). NEW, justified by [95 A-27](95-decisions.md): remove OS delivery from the engine, retain the latest notice per key, and let Fjord present it (60 §4.2).

---

## 3. Engine hosting on macOS

### 3.1 Constraints from sources

| Constraint | Source |
| --- | --- |
| No LaunchDaemon. A root launchd daemon running a macOS VM fails intermittently ("Unable to access security information", `ctkd … SepKey ACL`). DTS: "Virtualization links with AppKit, which is obviously not daemon-safe". | https://developer.apple.com/forums/thread/841688; `docs/research/macos-remote-display-2026-10-10.md` § C, rows 1-2 |
| A LaunchAgent or an app in the user's session works, but needs that session | `docs/research/macos-remote-display-2026-10-10.md` § C, row 3 and conclusion |
| macOS 15 and later: the framework needs an unlocked `login.keychain` while a VM runs ("SecKeyCreateRandomKey_ios failed", "Interaction is not allowed with the Security Server"). Fixes: log in once through the GUI, then automatic login or `security unlock-keychain`. | https://tart.run/faq/ (Headless machines) |
| Restoring saved VM state needs the Mac unlocked: "The saved state is protected by the keychain." | https://developer.apple.com/forums/thread/782007 |
| FileVault: "there is no solution that'll work with FileVault" for unattended reboots. Options are automatic login, Screen Sharing or SSH. | https://developer.apple.com/forums/thread/737381 |
| Automatic login is unavailable when FileVault is turned on | https://support.apple.com/en-us/102316 |
| Risk 3: "No LaunchDaemon; the user must be logged in with an unlocked login keychain, which conflicts with FileVault-on unattended reboots" | `docs/research/macos-remote-display-2026-10-10.md` § Risks, 3 |
| The view must be in the VM's process | `docs/research/macos-guest-engine-2026-10-09.md` § Decision |

### 3.2 LaunchAgent registered with `SMAppService` (NEW)

**Required by:**
- the owner decision ("On macOS it runs as a LaunchAgent in the user's GUI login session");
- the rows above.

**What the API gives:**
- `SMAppService.agent(plistName:)`: the plist "must correspond to a property list in the calling app's `Contents/Library/LaunchAgents` directory" (https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)). macOS 13+ (https://developer.apple.com/documentation/servicemanagement/smappservice).
- `register()`: the agent "is immediately bootstrapped and may begin running" and is bootstrapped again at each login. It must be called once per user (https://developer.apple.com/documentation/servicemanagement/smappservice/register()).
- `status` has `notRegistered`, `enabled`, `requiresApproval` and `notFound`. `requiresApproval` means the user must allow it in System Settings, and is also returned after the user revokes consent (https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval). `openSystemSettingsLoginItems()` opens that pane (https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems()).
- Plist keys (https://keith.github.io/xcode-man-pages/launchd.plist.5.html):
  - `BundleProgram`: an "app-bundle relative path to the executable", "only supported for plists that are installed using SMAppService";
  - `KeepAlive`: true "to unconditionally keep the job alive";
  - `ProcessType`: `Interactive` jobs "run with the same resource limitations as apps, that is to say, none";
  - `ExitTimeOut`: the wait between SIGTERM and SIGKILL when launchd stops the job;
  - `LimitLoadToSessionType`: applies to agents. That page does not list the session values; see Open questions.
- Apple's sample: plists inside the signed bundle can't be changed "without breaking the code signature", and users see the providing app under Login Items (https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api).

**Precedent in Silo.** Silo already uses `SMAppService.mainAppService()` for "Launch at login", including the `requiresApproval` state (`src-tauri/src/system_integrations/macos.rs:46-66`, `:113-138`).

**Precedent elsewhere.** Lume's installer writes a per-user `~/Library/LaunchAgents/com.trycua.lume_daemon.plist` that runs `lume serve` with `RunAtLoad` and `KeepAlive`. It does not use SMAppService (`cua: libs/lume/scripts/install.sh:525-570`; https://github.com/trycua/cua/blob/main/libs/lume/scripts/install.sh).

**SIGTERM.** The engine already turns SIGTERM into the session-end path (`src-tauri/src/system_shutdown.rs:87-104`). launchd sends SIGTERM and later SIGKILL when it stops a job (launchd.plist(5), `ExitTimeOut`). `SESSION_END_BUDGET` is 20 s (`src-tauri/src/system_shutdown.rs:23`), so `ExitTimeOut` must be at least that.

**Live hosting evidence (B-3/B-4/B-5).** The signed SMAppService harness ran as uid 501 in an Aqua GUI session with `LimitLoadToSessionType=Aqua`, `ProcessType=Interactive`, `RunAtLoad=true` and `KeepAlive=false`. These qualify session/process settings on macOS 26.5, not the production restart policy; login-window exclusion and macOS 15 remain OPEN. See [macos.md §Environment and method](probes/macos.md#environment-and-method) and [§B-3](probes/macos.md#b-3--partly).

The agent reached guest NAT SSH/22 in 11 ms. After Silo's guest Screen Sharing TCC/setup sequence, it reached 5900 in 1 ms on one boot; a later immediate restart check got no route. Treat guest service readiness separately from host Local Network privacy, and qualify repeated boots and macOS 15 during implementation. No host privacy change was needed in these runs ([macos.md §B-4](probes/macos.md#b-4--partly), [Follow-up §B-4](probes/macos.md#b-4--confirmed-on-one-boot)).

The same agent mounted an added read/write VirtioFS device with `mount_virtiofs` and verified bidirectional files without an observed TCC prompt. This settles the tested mount configuration, not arbitrary protected host folders, and adds no shared-folder API ([macos.md §B-5](probes/macos.md#b-5--confirmed)).

### 3.3 Entitlements and signing

| Entitlement | Why | Source |
| --- | --- | --- |
| `com.apple.security.virtualization` | Creating a `VZVirtualMachine`. Silo checks for it at run time and reports the feature as unsupported without it. | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization; `src-tauri/src/macos_computers/engine.rs:42`, `:243-268`; `src-tauri/Entitlements.plist` |
| `com.apple.security.hypervisor` | Carried by the app today; the `msb` sidecar is signed "with the Hypervisor entitlement" | `src-tauri/Entitlements.plist`; `docs/SiloUI-RUNTIME-BACKUP-FINDINGS.md` § Bundled runtime |
| `com.apple.security.automation.apple-events` | Carried by the app for opening terminal tabs (`Info.plist` usage string). NEW, justified by 95 A-22: the engine returns commands for the client to launch and needs no Apple Events entitlement (§2.4). | `src-tauri/Entitlements.plist`; `src-tauri/Info.plist` |
| Bridged networking (`com.apple.vm.networking`) | Not used: NAT needs no entitlement | `docs/research/macos-guest-engine-2026-10-09.md` § Framework constraints found |

An unsigned binary fails: `tauri dev` runs unsigned, and macOS computers fail there (`docs/SiloUI-MACOS-COMPUTERS.md` § Development and signing). An ad-hoc signature with the entitlement works (`docs/research/macos-guest-engine-2026-10-09.md` § Framework constraints found).

### 3.4 Main thread and the AppKit run loop

- Today every VM, installer and view is bound to the main queue (`src-tauri/src/macos_computers/engine.rs:1-8`). Workers reach it through Tauri's event loop (`src-tauri/src/macos_computers/engine.rs:144-183`).
- Without Tauri, the engine process must run an `NSApplication` loop on its main thread, so that `MainThread::run` (§ 2.5) has a queue that drains.
- The framework also allows a VM on a non-main serial queue: `init(configuration:queue:)` says "You must perform all VM-related operations on the specified queue" (https://developer.apple.com/documentation/virtualization/vzvirtualmachine/init(configuration:queue:)).
- Lume runs AppKit on the main thread "while Virtualization.framework uses a dedicated serial queue for VM operations" (`cua: libs/lume/src/VM/NativeApplicationLoop.swift:8-13`).
- `VZVirtualMachineView` "Inherits From: NSView" (https://developer.apple.com/documentation/virtualization/vzvirtualmachineview). The view stays on the main thread either way.

**Qualified queue choice (B-1):** use a dedicated serial queue for VM operations and AppKit's main thread for the view. On macOS 26.5, a VM created on that queue started in 0.441 s and attached to `VZVirtualMachineView`; this settles the tested pre-macOS-27 mechanism. Qualify the other supported host versions during implementation ([macos.md §B-1](probes/macos.md#b-1--confirmed)).

### 3.5 Session, keychain, auto-login and FileVault

- The engine needs a logged-in GUI session with an unlocked login keychain (§ 3.1).
- For the always-on host Mac (owner decision), the documented way to keep a session across reboots is automatic login (https://tart.run/faq/), which FileVault prevents (https://support.apple.com/en-us/102316; https://developer.apple.com/forums/thread/737381).
- "Locked screen keeps the keychain unlocked" is marked **unverified** in `docs/research/macos-remote-display-2026-10-10.md` § C, row 4, and stays an Open question.
- The engine cannot fix any of this. It can report it: see `device.*` in Open questions.

### 3.6 The engine-owned VM window and activation policy

**Decision (owner).** "the engine owns the VM and opens its own native `VZVirtualMachineView` window when a client asks, as VMPal does. Fjord doesn't embed it."

**API.**
- `NSApplication.setActivationPolicy(_:)` returns `Bool`; since macOS 10.9 any policy can be set at run time (https://developer.apple.com/documentation/appkit/nsapplication/setactivationpolicy(_:)).
- The policies (https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum):
  - `.regular`: "appears in the Dock and may have a user interface";
  - `.accessory`: no Dock icon and no menu bar, "but it may be activated programmatically or by clicking on one of its windows". It corresponds to `LSUIElement`=1 (https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory; https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement);
  - `.prohibited`: "may not create windows or be activated". It is the default for unbundled executables without an Info.plist (https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/prohibited).

So an engine started from a bare binary is `.prohibited` and cannot show the window. It must switch, or run from a bundle with `LSUIElement`.

**Precedent.**

| Who | What | Source |
| --- | --- | --- |
| Fjord | Switches between `.accessory` (bar only) and `.regular` while its window is open | Fjord: `Sources/Fjord/AppWindow.swift:9-20`; `LSUIElement` set in Fjord: `scripts/build-app.sh:41` |
| Lume | `lume run` starts `.accessory` (or `.regular` with a startup window) and "keeps them ready for a later native attach". `VMDisplayPresenter.show` switches to `.regular` when it attaches a VM window. | `cua: libs/lume/src/VM/NativeApplicationLoop.swift:8-46`; `cua: libs/lume/src/VM/VMDisplayPresenter.swift:242-247` |
| Tart | Chooses once at launch: `.prohibited` plus `NSApplication.run()` for `--no-graphics` (or VNC without graphics), else the UI path, whose app delegate sets `.regular` | https://github.com/cirruslabs/tart/blob/main/Sources/tart/Commands/Run.swift |

**What the engine window has to carry** (from today's window):
- the clipboard toolbar (`src-tauri/src/macos_computers/engine.rs:1328-1430`);
- the subtitle used for outcomes (`src-tauri/src/macos_computers/engine.rs:1432-1446`);
- focusing that returns the window number (`src-tauri/src/macos_computers/engine.rs:1616-1623`);
- input locking during setup (`src-tauri/src/macos_computers/engine.rs:1694-1762`);
- `display_open` state shown to the UI (`src-tauri/src/macos_computers.rs:2229-2240`).

**DECIDED (95 A-21):** `silod` uses `.regular` while at least one VM window is open, appearing in the Dock and ⌘-Tab, and `.accessory` when the last VM window closes. The process keeps the main-thread run loop of §3.4. Activation switching is NEW, justified by [95 A-21](95-decisions.md); the AppKit setter and Fjord precedent above support the transition. B-3's follow-up observed regular/Foreground with the window open and accessory/UIElement after close through a separate OS observer. These establish Dock/⌘-Tab eligibility; no visual screenshot or login-window test was retained ([macos.md Follow-up §B-3](probes/macos.md#b-3--confirmed-for-app-classification)). Login-window exclusion remains OPEN.

### 3.7 Linux host retirement

**DECIDED (95 A-23, overridden by 95 §3 Linux hosts dropped):** Only Macs host the engine, running as the LaunchAgent of §3.2 and hosting both Linux and macOS computers. Fjord controls them. No Linux engine service, linger policy, Debian/AppImage updater or headless Linux setup is specified; existing Linux packages stop receiving engine updates. Probes B-9/B-26 are closed.

Historical Linux host seams are RETIRED source coverage, not engine contract: XDG autostart (`src-tauri/src/system_integrations/linux.rs:15-71`), logind/SIGTERM shutdown (`src-tauri/src/system_shutdown.rs:9-13`, `:64-71`), the package guard (§7.1) and AppImage SSH helper (§8). Linux guest runtime methods, including full snapshot/`--cow-mem` update resume, remain specified on Mac hosts (§6; 10/20/50).

---

## 4. Transport

### 4.1 Today's bridge protocol (protocol version 5), as implemented

**Path through the system.** On the controller, Silo runs:

```
/usr/bin/ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10
  -o ServerAliveInterval=15 -o ServerAliveCountMax=2 [-i <key> [-o IdentitiesOnly=yes]]
  -- <address> "exec ~/.local/bin/silo-remote --remote-bridge"
```

(`src-tauri/src/remote.rs:695-726`, `:1104-1120`)

On the owner, sshd runs the bridge (§ 1.2). The bridge relays one frame to the running Silo's `control.sock` and relays the reply back.

**Framing.**
- A frame is a 4-byte big-endian unsigned length, then that many bytes of UTF-8 JSON (`src-tauri/src/remote.rs:546-555`, `:649-659`).
- `LIMIT` = 4 MiB in both directions. A larger frame fails with "Remote response exceeds the size limit." (`src-tauri/src/remote.rs:37`, `:548-550`, `:653-655`).
- **On ssh stdout only**, the reply is preceded by the preamble `\0SILO-BRIDGE-REPLY\n`. The reader skips up to 64 KiB of shell-startup noise before it (`src-tauri/src/remote.rs:556-609`). Replies on `control.sock` have no preamble (`src-tauri/src/remote.rs:2127-2135`).

**Request** (built at `src-tauri/src/remote.rs:1276-1282`, `:1322`, `:1846`, `:1938`):

| Field | Type | Meaning | Source |
| --- | --- | --- | --- |
| `version` | u32 | Protocol version; must equal `VERSION` = 5 | `src-tauri/src/remote.rs:34-36`, `:2166-2178` |
| `deviceId` | UUID string | The owner's device id as the controller saved it. Checked on every method except `handshake`. | `src-tauri/src/remote.rs:2179-2183` |
| `method` | string | One of `METHODS` | `src-tauri/src/remote.rs:236-272` |
| `params` | JSON | Method parameters | `src-tauri/src/remote.rs:2238` |
| `operationId` | UUID string | Change methods only. Stays the same across retries. | `src-tauri/src/remote.rs:1282`; `src-tauri/src/remote.rs:2255-2259` |
| `startWithinMs` | u64 | Change methods only. Half of the controller's remaining time; the owner caps it at `request_timeout`. | `src-tauri/src/remote.rs:1322`, `:2260-2265` |

**Response.**
- Success: `{"result": <value>}` (`src-tauri/src/remote.rs:2128-2130`). A reply with both `result` and `error`, or neither, is "Invalid remote Silo response." (`src-tauri/src/remote.rs:1078-1089`).
- Error: `{"error": <legacy text>, "code": <ErrorCode>, "message": <text>}`, plus `"version"` and `"appVersion"` when the code is `incompatible_version` (`src-tauri/src/remote.rs:564-577`). The legacy `error` text is `SILO_SANDBOX_UPDATE_IN_PROGRESS` for `update_in_progress`, the `UNSUPPORTED` text for `unsupported_remote_operation`, and the message otherwise.
- When the connection budget is exhausted, the reply is the bare frame `{"error": "This device has too many active Silo connections. …"}` with no code (`src-tauri/src/remote.rs:2076-2082`).

**Error codes.** `ErrorCode` serializes in snake_case (`src-tauri/src/bridge_error.rs:4-15`):

| Code | Produced by |
| --- | --- |
| `update_in_progress` | `BridgeError::updating()`: "Computer configuration is being updated." (`src-tauri/src/bridge_error.rs:46-51`) |
| `unsupported_remote_operation` | An unknown method, or a stream method that reached dispatch (`src-tauri/src/remote.rs:2240-2241`; `src-tauri/src/bridge_error.rs:53-58`) |
| `cancelled` | `GateError::Cancelled`, `RuntimeError::Cancelled`, or a retry stopped by shutdown (`src-tauri/src/bridge_error.rs:121`, `:132`; `src-tauri/src/remote.rs:1310-1316`) |
| `already_queued` | `GateError::AlreadyQueued` (`src-tauri/src/bridge_error.rs:119`) |
| `busy` | `GateError::Busy`, `RuntimeError::Busy` (`src-tauri/src/bridge_error.rs:120`, `:131`) |
| `not_found` | Declared (`src-tauri/src/bridge_error.rs:12`); no non-test code produces it (only the contract test lists it, `src-tauri/src/bridge_error.rs:152`) |
| `incompatible_version` | Version mismatch (`src-tauri/src/remote.rs:2166-2178`) |
| `internal` | Everything else, including any `String` error (`src-tauri/src/bridge_error.rs:104-108`) |

- Wire contract fixture: `src/test/contracts/bridge-errors.json` (`src-tauri/src/bridge_error.rs:145-164`).
- The decoder maps legacy text from devices that predate codes, and maps an unknown code to `internal` (`src-tauri/src/bridge_error.rs:60-95`).
- Version mismatch messages say which side to update. The controller names the device (`src-tauri/src/remote.rs:1247-1258`; `docs/SiloUI-CONNECTIONS.md` § Published-port readiness, version paragraph).

**Method classes** (`src-tauri/src/remote.rs:224-235`):
- **Read**: "Observes state only; repeating it changes nothing."
- **Change**: "accepted once per request identity, never replayed."
- **Stream**: "An interactive byte stream, served before request dispatch."

"A method is reachable only once it is classified here" (`src-tauri/src/remote.rs:234-235`):

| Read | Change | Stream |
| --- | --- | --- |
| `handshake`, `runtime.snapshot`, `runtime.logs`, `runtime.configuration`, `desktop.connect`, `desktop.status`, `chatgpt.status`, `ssh.access.state`, `files.list`, `network.state`, `repository.push.status`, `macos.snapshot`, `macos.display.connect`, `macos.display.resize` | `runtime.action`, `runtime.upsert`, `runtime.delete`, `desktop.action`, `chatgpt.retry`, `computerUse.approval`, `ssh.access.connection`, `ssh.access.save`, `guest.prepare`, `network.publish`, `network.unpublish`, `repository.push.start`, `repository.push`, `repository.dismiss`, `checkpoint.create`, `checkpoint.fork`, `checkpoint.restore`, `macos.create`, `macos.action` | `guest.ssh`, `macos.display.stream` |

The table above is `src-tauri/src/remote.rs:236-272`. `macos.display.resize` is a Read on purpose, because it is idempotent and repeated (`docs/SiloUI-CONNECTIONS.md` § macOS computer methods).

**Dispatch.**
- `handshake` is handled in the bridge itself.
- `runtime.*` goes to `runtime::remote_ops::dispatch`, `macos.*` to `macos_remote::dispatch`, and the rest to `remote_access::dispatch` (`src-tauri/src/remote.rs:2201-2219`).

**`handshake`.**
- Params: optional `sshKey`. If present, the owner rewrites Silo's older unrestricted or forwarding-enabled `authorized_keys` lines for that key into the restricted form (`src-tauri/src/remote.rs:2203-2214`, `:885-960`).
- Result: `{"deviceId", "name" (hostname), "version": 5, "capabilities": [every METHODS name]}` (`src-tauri/src/remote.rs:2242-2247`, `:2222-2224`).
- Controllers cache capabilities for 60 s (`src-tauri/src/remote.rs:1217-1244`).

**Stream upgrade.**
- The owner checks `macos.display.stream` and `guest.ssh` before dispatch (`src-tauri/src/remote.rs:2090-2123`). Each goes through `authorize`: Connections on, not quitting, version, deviceId.
- The stream moves from the connection budget (64) to the stream budget (192; it must exceed `remote_network::TUNNEL_LIMIT`) (`src-tauri/src/remote.rs:3376-3396`).
- The owner opens the target first: it spawns the guest SSH child, or opens TCP to guest port 5900 (`docs/SiloUI-CONNECTIONS.md` § macOS computer methods, `macos.display.stream` row). Then it writes `{"result":{}}` and splices raw bytes (`src-tauri/src/remote.rs:2806-2849`).
- The splice ends when either side ends, or when `allowed()` turns false. `allowed()` checks Connections on and not quitting (`src-tauri/src/remote.rs:2098-2102`, `:2116-2120`, `:2852-2967`).
- `guest.ssh` params: `computerId`, optional `purpose: "port"` with `port` 1..65535 (`src-tauri/src/remote.rs:2733-2747`; `computerId` at `:1806`, `:1813`). Unpublishing a port revokes its open streams at once (`src-tauri/src/remote.rs:2794-2805`).
- On the controller, `open_bridge_stream` waits up to 60 s for the reply, and can be cancelled (`src-tauri/src/remote.rs:1877-1991`).

**Durable operation journal and replay** (`src-tauri/src/remote/operations.rs`):
- **Acceptance.** It runs under a short lock. A marker `<state dir>/desktop-remote/operations/<operationId>.json` is written with status `accepted` (`src-tauri/src/remote/operations.rs:131-171`; `src-tauri/src/remote.rs:2266-2267`).
- **Same id.** A request whose `operationId` is known in memory attaches to it and waits up to `wait` = `request_timeout` for the result. The attach is refused with REUSED if the fingerprint `{method, params}` differs (`src-tauri/src/remote/operations.rs:117-147`, `:244-279`).
- **After an owner restart.** The marker answers instead. `finished` gives "already finished … Refresh"; `expired` gives "did not start … nothing changed"; anything else gives "Its result is uncertain" (`src-tauri/src/remote/operations.rs:33-40`, `:146-157`).
- **Start condition.** A change starts only before its deadline, while Connections is on and not quitting, and while a connection for it is open or was seen within `RECONNECT_GRACE` = 10 s. Otherwise it becomes `expired` and never runs (`src-tauri/src/remote/operations.rs:174-222`, `:24-25`; `src-tauri/src/remote.rs:2288-2291`). "Admission expiration … does not cancel work that has already started" (`docs/SiloUI-CONNECTIONS.md` § Checkpoint request deadlines).
- **Retention.** Results are kept 1 h in memory, at most 256 finished. Markers are pruned every 60 s once older than 1 h (`src-tauri/src/remote/operations.rs:22-31`, `:281-326`).
- **Controller retries.** Only after a `Lost` failure, with the same `operationId`, after 1 s and then 4 s. They stop if a shutdown begins (`src-tauri/src/remote.rs:1055`, `:1291-1334`).
- **Lost vs permanent.** A lost connection is ssh exit 255 without a permanent cause: host key, auth, name or refusal (`src-tauri/src/remote.rs:1091-1103`).
- **Legacy.** `ssh.access.connection` from older controllers carries no id or deadline and gets a synthetic one (`src-tauri/src/remote.rs:2250-2265`).

**Deadlines** (`request_timeout`, used by both sides; `src-tauri/src/remote.rs:981-1010`):

| Request | Timeout |
| --- | --- |
| `checkpoint.create`, `checkpoint.fork`, `checkpoint.restore` | 2 × (`RESTORE_EXPECTED_DURATION` + 60 s), the "122-minute complete-request window" (`docs/SiloUI-CONNECTIONS.md` § Checkpoint request deadlines) |
| `runtime.upsert` that creates (no `expected`) or names a desktop; `desktop.action` `update-streamer` / `setup-lcu` / `setup-computer-use`; `computerUse.approval` | 2100 s |
| Everything else | 600 s |

Other timeouts:
- 15 s on the owner to receive the first frame (`src-tauri/src/remote.rs:2087`);
- 30 s write timeouts (`src-tauri/src/remote.rs:2086`, `:1753`);
- 60 s to open a stream (`src-tauri/src/remote.rs:1877`).

The controller kills ssh at the deadline, or when stdout grows past 4 MiB + 4 + preamble + 64 KiB or stderr past 64 KiB. It then reports "Its outcome is unknown" (`src-tauri/src/remote.rs:1149-1155`).

**Disconnect detection.** The bridge half-closes the socket when the controller's stdin hits EOF (`src-tauri/src/remote.rs:1785-1801`). The owner probes with `recv(MSG_PEEK|MSG_DONTWAIT)` (`src-tauri/src/remote.rs:2293-2313`).

**Connections gate and deviceId** (`validate_authorization`, `src-tauri/src/remote.rs:2161-2185`), in order:
1. `enabled` false gives "Connections are turned off on this device."
2. Quitting gives the shutdown message.
3. Version.
4. `deviceId` must equal this device's id; `handshake` is exempt.

`changes_allowed` re-checks `REMOTE_ENABLED` and shutdown while a change waits (`src-tauri/src/remote.rs:2288-2291`). Turning Connections off "ends Silo guest sessions and rejects new management requests; already accepted computer operations retain their owner" (`docs/SiloUI-CONNECTIONS.md` § Close and Quit).

**Control socket.**
- Path: `<home>/<state dir>/desktop-remote/control.sock`. The state dir is `.silo` or `.silo-dev` (`src-tauri/src/channel.rs:73-81`; `src-tauri/src/remote.rs:124-136`, `:2031-2050`).
- The state dir is created `0700`, owned by this euid, and group or other bits are stripped (`src-tauri/src/runtime.rs:861-889`). `desktop-remote` is set `0700` (`src-tauri/src/remote.rs:133-135`) and the socket `0600` (`src-tauri/src/remote.rs:2047-2048`).
- A stale socket is removed only when connecting is refused. A live one means "Another Silo instance owns Connections." (`src-tauri/src/remote.rs:2034-2046`).
- Ownership is a non-blocking exclusive `flock` on `control.lock` (`0600`, `O_NOFOLLOW`) (`src-tauri/src/remote.rs:2014-2030`).
- The socket is bound at every launch even when Connections is off; the gate is per request (`src-tauri/src/remote.rs:2054-2068`).
- One request per connection: read a frame, reply, done. Streams are the exception (`src-tauri/src/remote.rs:2069-2140`).
- **No peer-credential check** exists. There is no `getpeereid`, `SO_PEERCRED` or `LOCAL_PEERCRED` in `src-tauri/src/`; the only protection is the directory and socket modes above.

**SSH forced command and restricted key.**
- Key: `~/.silo/desktop-remote/id_ed25519` (`src-tauri/src/remote.rs:673-678`).
- The installed line (`src-tauri/src/remote.rs:24-30`, `:875-883`) is:
  ```
  restrict,command="exec ~/.local/bin/silo-remote --remote-bridge" ssh-ed25519 <blob> Silo remote management
  ```
  The dev channel uses `silo-remote-dev` and "Silo Dev remote management" (`src-tauri/src/channel.rs:92-107`).
- `restrict` disables forwarding. Published ports use the guest transport instead (`docs/SiloUI-CONNECTIONS.md` § Published-port readiness).
- Installation pipes the line through `ssh … sh -c '…'`, which appends it once to `authorized_keys` (`src-tauri/src/remote.rs:20-23`, `:816-858`).
- ssh offers Silo's key alone first (`IdentitiesOnly`). After an auth failure it falls back once to every key and remembers what worked (`src-tauri/src/remote.rs:661-752`).

**Controller-side health.**
- Three failed polls in a row close a device's tunnels and viewers.
- A revoked device (wrong id, Connections off, auth or host-key change, `incompatible_version`) closes everything.
- An offline device is answered from its last error for 20 s (`src-tauri/src/remote.rs:1490-1577`; constants `CLOSE_AFTER_FAILURES` = 3 and `OFFLINE_FOR` = 20 s at `:1499`, `:1501`).

### 4.2 What the engine API needs on top

Each item names the need, then gives the spec. All items are **NEW** unless marked.

#### A. Local clients on a Unix socket, without the Connections gate

- **Need.**
  - The Silo UI becomes a client of the engine (owner decision).
  - Today the UI reaches the backend through in-process Tauri commands with no Connections gate. The gate exists only on `control.sock` (`src-tauri/src/remote.rs:2149-2185`).
  - `control.sock` refuses everything while Connections is off (`src-tauri/src/remote.rs:2161-2164`), and Connections is off by default (`src-tauri/src/remote.rs:146-151`).
- **Spec.**
  - A second socket, `<state dir>/engine.sock`. It has the same directory rules (`0700` dir, `0600` socket, stale-socket check) and is served by the same process, which holds the engine lock (§ 5).
  - `control.sock` keeps its Connections authorization gate, and uses the same NEW canonical methods/request-id framing as `engine.sock`; no v5 compatibility exchange is served (NEW, justified by 95 §3).
  - The bridge keeps connecting only to `control.sock`, a hard-coded path (`src-tauri/src/remote.rs:1749`). So the restricted key can never reach `engine.sock` (see C).

#### B. A persistent, multiplexed connection

- **Need.**
  - Today one connection carries one request (`src-tauri/src/remote.rs:2087-2128`).
  - Local clients need events on a long-lived connection (C).
  - The UI issues overlapping reads today (`src/desktop/production-source.ts:983-993`).
- **Spec.**
  - NEW transport, justified by [95 A-7 and §3](95-decisions.md): retain §4.1's frame shape (4-byte BE length, JSON, 4 MiB cap), without the old bridge preamble, and add request ids for multiplexing on both `engine.sock` and `control.sock`. The SSH relay carries this same canonical framed session; the Tauri client uses it too. Old one-shot exchange and method dispatch are removed.
  - Every request adds `"id"` (string, unique per connection). Responses echo it: `{"id", "result"}` or `{"id", "error": {"code", "message"}}`. NEW, justified by 95 A-7/§3: `code` uses the existing `ErrorCode` names (`src-tauri/src/bridge_error.rs:4-15`), extended under A-10. There is no duplicate legacy error text or old-text decoder.
  - Requests may be in flight concurrently; responses may arrive in any order.
  - `operationId` and `startWithinMs` keep their § 4.1 meaning for Change methods. A local client may send `operationId` to make a retry idempotent; the same registry applies (`src-tauri/src/remote/operations.rs:117-129`).

#### C. Authentication of local clients

- **Today.**
  - Silo checks no peer credentials (§ 4.1). Trust is "same account": the private directory and `0600` socket (`src-tauri/src/runtime.rs:861-889`; `src-tauri/src/remote.rs:2047-2048`).
  - Connections "does not revoke an OS account's pre-existing general SSH permissions" (`docs/SiloUI-CONNECTIONS.md` § Close and Quit). Anyone with an unrestricted SSH key for the account can already reach both sockets.
- **Spec.**
  - Keep the directory and socket modes.
  - Add a peer euid check on accept: it must equal the engine's euid. On macOS use `getpeereid(3)`, which returns the peer's effective uid and gid on a connected UNIX-domain stream socket (https://keith.github.io/xcode-man-pages/getpeereid.3.html). No Linux host peer-credential path is specified; hosts are Macs only (95 §3 Linux hosts dropped).
  - Any same-euid client may change shared settings; no peer code-signature check is required. NEW authorization, justified by [95 A-5](95-decisions.md).

#### D. Pushed events: a subscription method and an event envelope

- **Need.**
  - The backend emits 24 event names today (§ 9.3), and the UI subscribes to them in `src/desktop/production-source.ts:1080-1110`, `:1750`, `src/desktop/settings.ts:38`, `:107-108`, `:135`, `src/desktop/updates.ts:8`, `src/desktop/macos-computers.ts:22`, `src/desktop/preparation.ts:32`, `src/desktop/notices.ts:49`, `src/desktop/shutdown-boundary.tsx:41`, `:71`, `src/desktop/editor-include.ts:9`, `src/desktop/pre-upgrade-backup.ts:13`, `src/desktop/computer-use-bridge.ts:28`, `src/desktop/app-menu.ts:36` and `src/desktop/use-main-route.ts:32`, among others.
  - **Remote devices push nothing.** Controllers poll:
    - the application and remote snapshots every 10 s while visible (`src/desktop/production-source.ts:1124-1132`);
    - remote macOS computers every 10 s (`src/features/macos-computers/model/macos-computers.ts:174`, `:309-317`);
    - push status every 2 s, backing off to 30 s (`src/desktop/production-source.ts:336-339`).
  - Each poll is a new ssh process (`src-tauri/src/remote.rs:1104-1205`).
- **Spec (NEW, justified by [95 A-3/A-4](95-decisions.md)).** Clients use only their local engine. It relays remote events through a NEW Stream-class `events.subscribe` bridge method. Events carry new state plus sequence numbers; buffers are bounded. A gap or reconnect requires re-reading the affected domain before using subsequent events. Buffer capacity remains an implementation measurement, not an owner choice (§10 OQ12). See the methods and envelope below.

**Event envelope (NEW).** Pushed on the connection that subscribed:

```json
{"event": "computers.changed", "subscription": "s1", "deviceId": "owner-device", "seq": 42, "payload": { } }
```

| Field | Type | Why |
| --- | --- | --- |
| `event` | string, `domain.noun.verb` style | Brief naming rule |
| `subscription` | string | Which `events.subscribe` asked for it |
| `deviceId` | string | NEW source-engine identity for relayed events, justified by 95 A-3/A-4; uses the owning handshake's existing `deviceId` (`src-tauri/src/remote.rs:2203-2213`) |
| `seq` | u64, increasing per subscription | Clients drop stale data today with revision numbers: settings `revision` (`src-tauri/src/settings.rs:18-26`), the backup `revision` (`src-tauri/src/backup_controller.rs:410-413`). "numbered snapshots prevent old replies from replacing newer state" (`docs/SiloUI-SETTINGS.md` § Shared state and failures). A gap in `seq` tells the client to re-read. |
| `payload` | JSON | The new state for changed-state topics; existing progress, notice and exec payloads retain their domain types. NEW, justified by [95 A-4](95-decisions.md); existing macOS state snapshots are precedent (`src-tauri/src/macos_computers.rs:667-669`). |

Distinguishing frames: a response has `id`; an event has `event`.

**Topics.** `events.subscribe` takes names or `domain.*` prefixes, so a topic is a prefix. 10's `computers.watch` is `events.subscribe {events: ["computers.*", "operations.*"]}`, as 10 itself proposes ("If that section defines one `events.subscribe` with topics, this is its `computers` topic", 10 §12.2). `deviceIds?` relays selected remote engines through the local engine (NEW, justified by [95 A-3/A-4](95-decisions.md)). The client reads current state on initial subscribe and reconnect; the decision does not require an initial pushed snapshot.

<a id="read-triggered-maintenance"></a>
#### Engine behaviour: maintenance that today runs on client reads

**Status: EXTENDED, internal.** Existing client state reads trigger the passes below; secret removal, retry and startup, log searches, and successful starts provide the additional triggers shown. Busy passes rely on later reads for another attempt (sources in the table). The always-on host Mac needs a trigger independent of connected clients (`00-brief.md` § What was decided; Mac-only hosts in 95 §3). The replacement is **NEW, justified by [95 A-26](95-decisions.md)**: autonomous engine timers run secret-revocation retries, stopped-computer log expiry and published-port repair even with no client connected. Preserve the existing one-pass guards and hourly log-cleanup cap below; retry busy work on a later timer pass. Exact intervals for revocation and repair require a deterministic no-client probe (§10 OQ23), not a new owner decision.

| Pass | Today's trigger | Skips when | Source |
| --- | --- | --- | --- |
| Pending secret revocations | `read_application_state`, also bridge `runtime.snapshot`; secret removal, legacy-removal retry and startup | The computer's gate is busy: retry on a later state refresh. A stop clears that computer's pending records | `src-tauri/src/runtime.rs:2671`, `:13029-13060`; `src-tauri/src/runtime/remote_ops.rs:6-11`; `src-tauri/src/secrets.rs:752-780`, `:870`, `:888-895`, `:928`, `:369-379` |
| Expired-log cleanup of stopped computers | `read_application_state`, at most hourly per stopped computer; a fresh log search also performs opportunistic cleanup | State-read cleanup cannot take the hidden device gate; log-query cleanup cannot take the hidden computer gate | `src-tauri/src/runtime.rs:2676-2701`, `:2730-2795`; `src-tauri/src/runtime_logs.rs:639-657` |
| Forward repair of published ports | `read_network_state`; desired rules are also reapplied after each successful start | Background repair cannot take the computer's gate | `src-tauri/src/network.rs:729-770`, `:827-836`, `:973-984` |

The health watch already reads while the main window is hidden (`src-tauri/src/health_watch.rs:242-273`), but uses `health_observations` → `read_application_state_with`, rather than the read command that schedules this maintenance (`src-tauri/src/runtime.rs:3007-3031`, `:2663-2698`).

<a id="event-catalogue"></a>
**Event catalogue (canonical names).** Every section uses these names and no others. Names follow 80 §2 N15. Emit sites are under `src-tauri/src/`.

**DECIDED (95 A-4):** Changed-state events carry the relevant read method's new state. Existing state/progress/notice payloads retain their fields. All events use the sequence envelope above; clients re-read on a gap or reconnect. This is NEW for today's hint events, justified by [95 A-4](95-decisions.md).

| Event | Replaces today | Emitted at today | Payload | Owner |
| --- | --- | --- | --- | --- |
| `computers.changed` | `silo://application-state-changed` (computer emit sites); `silo://macos-computers-changed` | `runtime.rs:3348`, `:3371`; `runtime/remote_ops.rs:49`, `:101`, `:112`, `:127`; `runtime/lifecycle_recovery.rs:449`; `runtime/configuration_recovery.rs:604`, `:646`; `startup.rs:243`; `runtime/shutdown.rs:127`; `desktop.rs:824`, `:848`; `computer_use.rs:1348`, `:1366`; `macos_computers.rs:668` | **NEW (justified by 95 A-4):** `{linux?: ApplicationSource, macos?: MacosComputersState}`, the kind that changed (10 §12.2). The macOS part already carries state today. | 10 |
| `checkpoints.changed` | `silo://application-state-changed` (checkpoint emit sites) | `runtime/checkpoints.rs:804`, `:1797`, `:2208`, `:2493`, `:2768` | **NEW (justified by 95 A-4):** those results. | 20 |
| `exports.changed` | `silo://application-state-changed` (backup emit site) | `backup_controller.rs:413` | **NEW (justified by 95 A-4):** `BackupState` (`backup_controller.rs:86-104`). Running progress is also on `operations.job.progress` (§ E). | 20 |
| `migration.changed` | `silo://application-state-changed` (migration emit sites) | `runtime_migration.rs:961`, `:1030` | **NEW (justified by 95 A-4):** its result. | 20 |
| `migration.preUpgradeBackup.changed` | `silo://pre-upgrade-backup-changed` | `pre_upgrade_backup.rs:450`, `:517` | **NEW (justified by 95 A-4):** its result. | 20 |
| `github.changed` | `silo://application-state-changed` (GitHub emit sites) | `github.rs:266`, `:441`, `:667`, `:820`, `:1137`, `:2585`, `:3069`; `github_personal_token.rs:247` | **NEW (justified by 95 A-4):** `GitHubState` (50). | 50 |
| `secrets.changed` | `silo://application-state-changed` (secret emit sites) | `secrets.rs:531`, `:777`, `:849`, `:869`, `:929` | **NEW (justified by 95 A-4):** its result. | 50 |
| `push.changed` | `silo://application-state-changed` (push emit sites) | `host_push.rs:92`, `:1219`, `:1241`; `host_push_operations.rs:224` | **NEW (justified by 95 A-4):** those results. | 50 |
| `operations.queue.changed` | `silo://operation-queue-changed` | `main.rs:297-300` (the gate listener; `runtime/operation_gate.rs:593-609`) | **NEW (justified by 95 A-4):** `OperationQueue` (`runtime/operation_gate.rs:119-125`), as 10 §6 proposes. | 10 |
| `network.changed` | `silo://network-state-changed` | `network.rs:822`; `remote_network.rs:541`; `ssh_access.rs:667`, `:963` | **NEW (justified by 95 A-4):** those results. | 50 |
| `editor.includeNotice.changed` | `silo://editor-include-changed` | `editor.rs:1099` | **NEW (justified by 95 A-4):** its result. | 50 |
| `operations.job.progress` | `silo://computer-configuration-progress`, `silo://lifecycle-progress`, `silo://transfer-progress`; the progress parts of `silo://application-state-changed` (backup), `silo://macos-computers-changed` and `silo://update-state` | `runtime.rs:3586`, `:4181`, `:4183`; `runtime/configuration_recovery.rs:632`; `runtime.rs:3343`; `transfer.rs:1398`, `:1449` | Always a payload: § E | 05 |
| `operations.job.finished` | none: today the command returns | — | Always a payload: § E | 05 |
| `engine.shutdown.changed` | `silo://shutdown-state-changed` | `settings.rs:924`, `:960` | `{shuttingDown: bool}` (a `bool` today) | 05 |
| `settings.changed` | `settings:changed` | `settings.rs:759` | the settings `Snapshot` without the draft, as today | 60 |
| `updates.changed` | `silo://update-state` | `updates.rs:171`, `:335`, `:445`, `:536`, `:795` | `updates::Snapshot` (`updates.rs:41-61`), as today | 60 |
| `preparation.changed` | `silo://preparation-status` | `preparation.rs:233` | the status snapshot, as today | 20 |
| `preparation.chatgpt.changed` | `chatgpt-app-status` | `chatgpt_app.rs:1985` | the status, as today | 20 |
| `notifications.notice` | `silo://notice` | `notifications.rs:126` | `Notice`, as today; engine retains the latest per key and posts no OS notifications (NEW, justified by 95 A-27; 60 §4.2) | 60 |
| `connections.devices.changed` | none (NEW, justified by 95 A-4) | — | the device-health read state (60 `connections.devices.health`) | 60 |
| `notifications.cleared` | none (NEW, 60 §4.2) | — | 60 §4.2 | 60 |
| `computers.unexpectedChange` | none: today the health watch only posts notices (`health_watch.rs:91-138`) | — | `{computerId, name, state}` (NEW, 10 §12.2) | 10 |
| `display.viewer.page` | none (NEW, 40 §2); delivered to one client (`Audience::Client`) | — | 40 §2 | 40 |
| `guest.exec.output` | none (NEW, 70 §2.1); job-scoped | — | `{jobId, seq, stream, data}` (70) | 70 |
| `guest.exec.exited` | none (NEW, 70 §2.1); job-scoped | — | `{jobId, exitCode, signal?}` (70) | 70 |
| `guest.files.changed` | none (NEW, 70 §2.1); delivered to the `guest.files.watch` subscription | — | 70 §2.1 | 70 |

Names that are **not** events: `computers.lifecycleProgress`, `computers.configurationProgress` and `files.transfer.progress` are `operations.job.progress` (§ E); `operations.changed` is `operations.queue.changed`; `macos.changed` is `computers.changed`; the event `updates.state` is `updates.changed`; `editor.changed` is `editor.includeNotice.changed`; `computerUse.app.status` as a subscription is `preparation.chatgpt.changed`. The UI-only events (`silo://quit-requested`, `settings:flush-request`, `silo://viewer-drag`, `silo://viewer-drop`, `silo://desktop-viewer-page`, `desktop-clipboard`, `silo://menu-command`, `desktop:status-opened`, `desktop:route-requested`) are listed in § 9.3.

<a id="job-contract"></a>
#### E. Jobs: one contract for long work, its progress, its result and its id

This is the one job contract of the API. Every section's long methods (Kind `job`), their progress, their completion and their cancellation follow it, and point here instead of defining their own. The `operations.*` section (10 §6) owns the `operations.list` and `operations.cancel` method entries; their params and semantics are the ones fixed here and in § F.

**Need: what exists today.** Progress, results and cancellation reach the UI in a different way for each kind of work. Every field below is a real field of the cited type.

| Work | Its id today | Type and fields | Delivery today | Cancel today |
| --- | --- | --- | --- | --- |
| Operation gate (every gated job) | `OperationEntry.id: u64`, a new id per admission (`next_id`, `src-tauri/src/runtime/operation_gate.rs:249-256`) | `OperationEntry {id, label, kind: OperationKind, computerId?, computerName?, sinceMs, cancellable, expectedMs?, blockedByHidden}`, `OperationQueue {running, waiting}` (`src-tauri/src/runtime/operation_gate.rs:69-125`) | Payload-less `silo://operation-queue-changed` (`src-tauri/src/main.rs:297-300`), then `read_operation_queue` (`src-tauri/src/runtime.rs:55-58`) | `cancel_operation(id)` (`src-tauri/src/runtime.rs:60-65`; `src-tauri/src/runtime/operation_gate.rs:1043-1076`) |
| Linux computer setup (create, edit, delete, retry) | `requestId`: given by the client, or a generated UUID; non-blank, at most 256 chars (`src-tauri/src/runtime.rs:4125-4131`) | `ComputerConfigurationProgress {schemaVersion, type, requestId, phase, step, computer, fraction?, message, safeForDisplay, timestamp, level, elapsedSeconds, downloadedBytes?, totalBytes?, failureCode?, exitCode?, diagnostic?, partial}` (`src-tauri/src/runtime.rs:3462-3494`). The TS side is `siloProgressEventSchema` (`src/contracts/silo.ts:89-111`): it adds `revision`, which Rust never writes (80 §5 B-8), and lists `failureCode` values `auth`, `access`, `disk`, `permission`, `network`, `timeout`, `integrity`, `resources`, `configuration`, `unavailable`, `runtime` (`src/contracts/silo.ts:105`) | Pushed with payload, only to `main` (`src-tauri/src/runtime.rs:3586`, `:4181`, `:4183`; `src-tauri/src/runtime/configuration_recovery.rs:632`) | Only through its gate entry (device scope, kind `computerConfiguration`: `src-tauri/src/runtime.rs:4345-4347`, `src-tauri/src/runtime/operation_gate.rs:630-641`; retry at `src-tauri/src/runtime.rs:4276-4278`), which never opts in, so only while it waits. The creation wait before the gate (`src-tauri/src/runtime.rs:4344`, `:4274`) ends only on Quit (`src-tauri/src/creation_inputs.rs:112-114`, `:147`) |
| Linux lifecycle steps (start, restart) | None: `{computerId, action}` | `{computerId, action, step}`, `step` one of `boot`, `network`, `account` (`src-tauri/src/runtime.rs:3340-3346`; `LifecycleStep`, `src-tauri/src/runtime.rs:1273-1292`) | Broadcast `silo://lifecycle-progress` (`src-tauri/src/runtime.rs:3343`) | Through the gate entry; start and restart opt in, stop does not (`src-tauri/src/runtime.rs:3301`, `:3318-3319`) |
| Export and import | The journal identity, reported as `BackupState.operationId` while the journal exists (`src-tauri/src/backup_controller.rs:91-92`, `:485-487`); returned by `start_backup` (`src-tauri/src/backup_controller.rs:782-789`, `:906`) but not by `start_restore`, which returns `()` (`src-tauri/src/backup_controller.rs:1565-1572`) | `BackupState.operation` (`src-tauri/src/backup_controller.rs:48-82`): `Running {operation, archive, runningNames, targetName?, progress: u8, indeterminate?, canCancel?, phases}` or `Result {operation, archive, runningNames, targetName?, outcome, title, message, detail?}`; `Phase {title, detail, tone}` (`:40-46`); `Archive {name, archivePath, completedLabel, size, destination, computers, checkpointName?}` (`:28-39`) | Payload-less `silo://application-state-changed` (`src-tauri/src/backup_controller.rs:413`), then `read_backup_state` (`src/desktop/production-source.ts:986-993`) | `cancel_backup_operation`, no id: it cancels the running one, and refuses once `canCancel` is false (`src-tauri/src/backup_controller.rs:2054-2092`) |
| Archive inspection | `requestId`, optional, generated when absent (`src-tauri/src/backup_controller.rs:574-584`) | Result only: `ArchiveInspectionResult {archive, valid, reason?}` (`src-tauri/src/backup_controller.rs:107-114`) | Returned by the command | `cancel_backup_inspection(requestId)` (`src-tauri/src/backup_controller.rs:630-640`) |
| File transfers | `transferId`, picked by the client (`src-tauri/src/transfer.rs:1375`, `:1433`); one transfer at a time (`src-tauri/src/transfer.rs:1079-1100`) | `Progress {id, computer, direction, state, name, fileIndex, fileCount, bytesDone, bytesTotal}` (`src-tauri/src/transfer.rs:103-115`); `direction` is `upload` or `download`, `state` is `transferring`, `done`, `cancelled` or `failed` (`src-tauri/src/transfer.rs:787`, `:882`, `:1017`, `:1074`, `:1418-1420`, `:1471-1473`) | Broadcast `silo://transfer-progress` (`src-tauri/src/transfer.rs:1398`, `:1449`) | `cancel_transfer(transferId)` (`src-tauri/src/transfer.rs:1483-1495`) |
| Host Push | `operationId`, picked by the client and journaled before the push starts (`src-tauri/src/host_push_operations.rs:189-217`, `:403-433`) | The push operation `{operationId, computer, repositoryPath, status, commitCount, message?, target}`; `status` is `pushing` (`src-tauri/src/host_push_operations.rs:157`), `succeeded`, `unknown` or `failed` (`src-tauri/src/host_push.rs:1283`, `:1290`, `:1299`), and `unknown` after a restart lost the result (`src-tauri/src/host_push_operations.rs:98-100`) | Polled with `repository_push_status` (`src-tauri/src/host_push_operations.rs:436-454`); a payload-less hint at completion (`:224`) | Only through its gate entry, which opts in (kind `push`, `src-tauri/src/host_push.rs:786-791`) |
| macOS computer work (create, install, setup, start, stop, checkpoints) | None. A computer has at most one checkpoint operation (`src-tauri/src/macos_computers.rs:131-132`); macOS work has no gate today (10 §6); it joins the queue under 95 A-31 | The row's `state`, `progress`, `detail` and `checkpointOperation` (`MacosComputer`, `src-tauri/src/macos_computers.rs:68-92`); `checkpointOperation` is `{kind: capture \| restore \| fork \| delete, status, stage}` (`src-tauri/src/macos_computers/checkpoints.rs:127-153`) | The whole snapshot on `silo://macos-computers-changed`, progress at most once a second (`src-tauri/src/macos_computers.rs:52`, `:667-669`, `:707-724`) | None; Delete of a computer being created cancels and removes it (10 §3 `computers.delete`) |
| Log export | None: a cancellation generation (`src-tauri/src/log_export.rs:15-25`) | Result only: `bool` (`src-tauri/src/log_export.rs:81-85`) | Returned by the command | `cancel_log_export`, no id: it cancels every export in flight (`src-tauri/src/log_export.rs:73-78`; 80 §5 B-17) |
| GitHub connect | None: a cancellation generation (`src-tauri/src/github.rs:142`, `:3044`); one flow at a time (`src-tauri/src/github.rs:25`, `:3046-3047`) | Result only (`src-tauri/src/github.rs:3038-3051`); state through `silo://application-state-changed` | Returned by the command | `cancel_github_connection`, no id (`src-tauri/src/github.rs:3054-3075`) |
| Update download | None; one update operation at a time (`src-tauri/src/updates.rs:520-522`) | `updates::Snapshot` (`src-tauri/src/updates.rs:41-61`), including `downloadedBytes` and `totalBytes` | Broadcast `silo://update-state` (`src-tauri/src/updates.rs:536`) | None |
| Guest exec | None: NEW (70 §2.1) | `guest.exec.output {jobId, seq, stream, data}`, `guest.exec.exited {jobId, exitCode, signal?}` (70 §2.1) | NEW | NEW (70 §2.1) |

**Three facts shape the contract.**
1. **A gate id names one admission, not one job.** "The gate is re-acquired per attempt … between attempts the guard is dropped, so the retry has no queue entry while it backs off", and "A single cancel token spans the whole sequence" (`src-tauri/src/runtime.rs:3160-3178`). So a job's id can't be its gate id.
2. **Today several jobs never enter the gate:** transfers, archive inspection, log export, GitHub connect, update download and macOS work (10 §6). NEW, justified by 95 A-31: macOS work joins the queue in this API; other nongated domains retain their existing scope. `guest.exec.start` takes no lifecycle/configuration gate (70 §2.1).
3. **Several jobs already have a domain id** that exists before any gate entry, and outlives it in a journal: the setup `requestId` (`setup-activity.json`, 10 §7), the push `operationId` (`repository-push-operations.json`, `src-tauri/src/host_push_operations.rs:196-198`) and the export journal (`src-tauri/src/backup_controller.rs:948`).

**Spec (NEW).**

**1. Two id spaces.**
- **Gate entries** keep `OperationEntry.id: u64`, one per admission, shown by `operations.list`.
- **Jobs** get a `JobId`: a string `"<space>:<id>"` that names the job for its whole life, across gate admissions and retries.
- NEW field `OperationEntry.jobId?: JobId` links a gate entry to its job. It is absent for gate work that is not a job (methods of Kind `command`, and hidden maintenance, which never appears in the queue: `src-tauri/src/runtime/operation_gate.rs:305-311`).

**2. `JobId` spaces.** The space says where the id comes from. Where the source domain already assigns an id, the new JobId wraps that domain id. Silo's Tauri UI adopts the canonical job contract without old-name adapters (95 §3 No legacy). Completed job identities remain addressable across engine restart until acknowledged (95 §3 Job results); durable allocation across all JobId spaces is probe B-37.

| Space | `<id>` is | Jobs | Status |
| --- | --- | --- | --- |
| `setup:` | the `requestId` (`src-tauri/src/runtime.rs:4125-4131`) | Linux `computers.configuration.change`, `computers.create`, `computers.delete`, `computers.configuration.retry` | id EXISTS |
| `transfer:` | the client's `transferId` (`src-tauri/src/transfer.rs:1375`, `:1433`) | `files.upload`, `files.download` | id EXISTS |
| `push:` | the client's push `operationId` (`src-tauri/src/host_push_operations.rs:403-433`) | `push.start` | id EXISTS |
| `exports:` | the journal identity, `BackupState.operationId` (`src-tauri/src/backup_controller.rs:485-487`, `:948`) | `exports.create`, `exports.import` | id EXISTS; returning it from import is NEW (80 §5 B-9) |
| `inspect:` | the `requestId` (`src-tauri/src/backup_controller.rs:574-584`) | `exports.inspect` | id EXISTS |
| `job:` | a durable identity the engine assigns when it accepts the request; allocation is probe B-37 (NEW, justified by 95 §3) | every other job: Linux lifecycle, Linux and macOS checkpoints, `storage.reclaim`, `computers.identities.configure`, `desktop.action`, `computerUse.setup`, engine-launch migration, `engine.shutdown`, `engine.update.prepare`, `updates.download`, `logs.export`, `github.connect`, every macOS job, `guest.exec.start` | NEW: these jobs have no id today (table above) |

- Clients treat a `JobId` as opaque. The prefix lets the engine route `operations.cancel` (§ F) and tells a client which domain read keeps the job's outcome (item 5).
- **NEW, justified by [95 §3 Job results](95-decisions.md#3-amendments-owner-2026-10-13-later), overriding A-25:** completed job outcomes are saved to disk, survive engine restart and remain available through `operations.job.get` until a client acknowledges showing them with `operations.job.acknowledge`. No 1-hour expiry or restart deletion applies. `job:` identity must not collide with another logical job across restart; durable allocation/journal mechanics and recovery of unfinished work are unsourced and require probe B-37 (§10 OQ25). Existing domain journals are source precedents, not a generic completed-job journal (`src-tauri/src/host_push_operations.rs:196-198`; `src-tauri/src/backup_controller.rs:948`).
- Work the engine starts itself gets a `job:` id too, so its progress has a `jobId`. Example: a start at launch takes the computer's lifecycle lane "with the same label, key and cancellability as a user Start" (10 §4.6; `src-tauri/src/runtime.rs:5116-5186`). NEW, required by 10 §4.4, which asks for lifecycle steps on launch starts.
- Where the id is the client's (`transferId`, push `operationId`, setup `requestId`), the client keeps sending it in the method's params and the engine returns the wrapped `jobId`. A repeated id behaves as today: Host Push returns the journaled job instead of starting a second one (`src-tauri/src/host_push_operations.rs:202-205`).
- The bridge's transport `operationId` (§ 4.1) is a different thing: the idempotency key of one Change request. It keeps that name. The push param of the same name is a domain id, and becomes the `push:` job id (80 §2 N11).

**3. Starting a job.** A method of Kind `job` returns at once:
- `{jobId: JobId}`;
- plus anything today's command returns before its background work starts. The relevant source cases are:
  - macOS create returns the new row in state `preparing` (10 §3 `computers.create`; `src-tauri/src/macos_computers.rs:978-1005`);
  - launch migration may run in the background, using the existing `runtime_migration` conversion path (`src-tauri/src/runtime_migration.rs:993-995`, `:1019-1034`); `migration.retry` as an alternate compatibility path is retired (95 §3; 20 `migration.*`).
- macOS create/setup retry finish at `finish_workflow` (`src-tauri/src/macos_computers.rs:374-394`), with an empty result, retaining the existing workflow boundary (30 §3). A successful launch migration restarts the engine (`src-tauri/src/runtime_migration.rs:673-684`); its completed outcome must be saved before restart and remains readable until acknowledged (NEW, justified by 95 §3 Job results). Exact completion/persistence ordering remains probe B-37 and 20 OQ11; restart is not a reason to discard a finished outcome.

What today's command returns at the end moves to `operations.job.finished.result` (item 5).

**4. Progress: `operations.job.progress`.**

```
{ jobId: JobId, kind?: OperationKind, computerId?: string, source: JobSource, data: <the source type, unchanged> }
```

- `kind` is present when the job holds or waits for a gate entry (`OperationKind`, `src-tauri/src/runtime/operation_gate.rs:69-92`).
- `computerId` is present when the job is about one computer.
- `data` is today's type, field for field. Nothing is flattened or dropped.

| `source` | `data` (every field kept) | Replaces |
| --- | --- | --- |
| `setup` | `ComputerConfigurationProgress` (table above) | `silo://computer-configuration-progress` |
| `lifecycle` | `{computerId, action, step}` | `silo://lifecycle-progress` |
| `transfer` | `transfer::Progress` | `silo://transfer-progress` |
| `backup` | `BackupState.operation` while `kind: "running"`, with `phases` | the backup hint plus `read_backup_state` |
| `push` | the push operation value while `status: "pushing"` | polling `repository_push_status` |
| `macos` | `{computerId, state, progress, detail, checkpointOperation}`, the fields of that `MacosComputer` row, at most once a second as today | the progress part of `silo://macos-computers-changed` |
| `update` | `updates::Snapshot` | the download progress of `silo://update-state` |

- **Jobs not in this table report no progress today**, and none is invented for them. Clients follow them through their gate entry on `operations.queue.changed` (`label`, `sinceMs`, `expectedMs`, `cancellable`). For example, a shutdown relabels its entry "Stopping {name} ({index} of {total})" (`src-tauri/src/runtime/shutdown.rs:116-120`). Their domain's `*.changed` event also fires.
- **Exec output** is not on this event. `guest.exec.output` and `guest.exec.exited` (70 §2.1) are job-scoped events keyed by the same `jobId`, with their own `seq` for replay through `guest.exec.get`. `operations.job.progress` has no byte stream and no sequence per stream (80 §2 N15).
- **Audience is today's.** Setup progress goes only to the client that started the job (`emit_to("main")`, `src-tauri/src/runtime.rs:3586`, becomes `Audience::Client`). Every other source is broadcast, as `silo://lifecycle-progress`, `silo://transfer-progress` and `silo://macos-computers-changed` are today (`src-tauri/src/runtime.rs:3343`; `src-tauri/src/transfer.rs:1398`; `src-tauri/src/macos_computers.rs:668`).

**5. Completion: `operations.job.finished`.**

```
{ jobId: JobId, result?: <today's final return value>, error?: {code: ErrorCode, message: string} }
```

- Every job ends with one terminal `operations.job.finished`, with the same audience as its progress. Persist the terminal outcome before publishing completion or a planned engine restart (NEW, justified by 95 §3 Job results). Re-reading a saved outcome is not execution replay; recovery of an unfinished process remains probe B-37.
- `result` is what today's command returns at the end, unchanged:
  - Linux setup and lifecycle: `ApplicationSource` (10 §1.3);
  - transfers: `UploadOutcome` / `DownloadOutcome` (`src-tauri/src/transfer.rs:85-101`);
  - Host Push: the final push operation value;
  - exports: `BackupState.operation` with `kind: "result"`;
  - inspection: `ArchiveInspectionResult`;
  - log export: the `bool`;
  - update download: `updates::Snapshot` (`src-tauri/src/updates.rs:513`);
  - exec: `{exitCode, signal?}`, as `guest.exec.exited` (70);
  - other jobs: the result their section gives.
- **Failure and cancellation that today are data stay data.** These stay in `result`:
  - a push `status: "failed" | "unknown"`;
  - a backup `outcome`;
  - a transfer's `{status: "cancelled"}` (`UploadOutcome::Cancelled`, `DownloadOutcome::Cancelled`, `src-tauri/src/transfer.rs:83-101`).
  `error` is set only where today's command returns an error.
- `error.code` is a wire `ErrorCode`, in snake_case (`src-tauri/src/bridge_error.rs:4-15`; § 4.1). A job whose command returns a cancellation as an error today ends with `error.code: "cancelled"`.
- **Setup failure details** (`failureCode`, `exitCode`, `diagnostic`, `partial`) arrive in the last `setup` progress, the `setup-failed` event, before `finished`, as today (`src-tauri/src/runtime.rs:4211-4239`). `error.message` is the command's error text.
- **A client that missed `finished`** reads the durable outcome with `operations.job.get`, including after engine restart. After showing it, the client calls `operations.job.acknowledge`, which drops that outcome. Reads and disconnects do not acknowledge; no time-based expiry applies (NEW, justified by 95 §3 Job results). Domain state can be re-read independently with `activity.setup.read`, `push.status`, `exports.state`, `guest.exec.get`, `migration.state` or `computers.list`.

**6. Remote engines.** A remote job belongs to the engine doing the work and is addressed by `(deviceId, jobId)` (80 §2 N16). Clients call only their local engine, which relays methods and Stream-class event subscriptions over SSH. NEW, justified by [95 A-3/A-4](95-decisions.md); today's non-stream bridge calls instead wait for a reply (`src-tauri/src/remote.rs:981-1011`). The remote owner persists outcomes until a client acknowledges showing them; the local engine relays get/acknowledge to that owner (NEW, justified by 95 §3 Job results).

#### F. Cancellation

**Need.** Today there are six cancel commands, plus work with no cancel at all:
- `cancel_operation(id)` (`src-tauri/src/runtime.rs:60-65`);
- `cancel_backup_operation`, which takes no id (`src-tauri/src/backup_controller.rs:2054-2092`);
- `cancel_backup_inspection(requestId)` (`src-tauri/src/backup_controller.rs:630-640`);
- `cancel_transfer(transferId)` (`src-tauri/src/transfer.rs:1483-1495`);
- `cancel_log_export`, which takes no id (`src-tauri/src/log_export.rs:73-78`);
- `cancel_github_connection`, which takes no id (`src-tauri/src/github.rs:3054-3075`).
- Host Push has no cancel command; it cancels through its gate entry (`src-tauri/src/host_push.rs:786-791`).
- macOS work and update downloads have no cancel (table in § E).

A running gate operation is cancellable only if it opted in (`src-tauri/src/runtime/operation_gate.rs:104-108`, `:1251-1254`).

**Spec.** `operations.cancel` takes `jobId: JobId` only, routed by its space below. NEW, justified by [95 A-25 and §3](95-decisions.md): gate ids still identify queue admissions for display, but clients cancel the owning job. Today's `cancel_operation(id)` and the domain-specific cancel names are retired, not alternate API entry points.

| Job | Cancel goes to | Semantics (today's) |
| --- | --- | --- |
| `setup:` | its gate entry | A waiting entry leaves the queue. The running change never opted in, so it answers `NotCancellable`. The creation wait before the gate is not cancellable: only Quit ends it (`src-tauri/src/creation_inputs.rs:112-114`, `:147`), and `computers.creation.skipComputerUseWait` skips its ChatGPT part (10 §3) |
| `push:` | its gate entry, which opts in | `src-tauri/src/host_push.rs:786-791` |
| `exports:` | `cancel_backup_operation` | Refused with "This operation is finishing and can no longer be cancelled." once `canCancel` is false (`src-tauri/src/backup_controller.rs:2069-2076`). NEW: the `<id>` must match `BackupState.operationId`; today the command takes no id |
| `inspect:` | `cancel_backup_inspection(requestId)` | Stops the check started under that id (`src-tauri/src/backup_controller.rs:630-640`) |
| `transfer:` | `cancel_transfer(transferId)` | Sets the cancel flag when the id is the active transfer; any other id succeeds without effect (`src-tauri/src/transfer.rs:1483-1495`) |
| `job:` holding gate entries (Linux lifecycle, Linux checkpoints, `storage.reclaim`, `computers.identities.configure`, `engine.shutdown`, …) | its current gate entry | Gate rules (`src-tauri/src/runtime/operation_gate.rs:1043-1076`): a waiting entry leaves; a running one only if it opted in, with a 250 ms grace after admission. Between retry attempts, the shared token stops the next attempt (`src-tauri/src/runtime.rs:3167-3178`) |
| `job:` log export | the log-export cancellation | NEW, justified by [95 A-30](95-decisions.md): cancel only the named log-export job. Today the shared flag cancels every export in flight (`src-tauri/src/log_export.rs:18-25`, `:73-78`); per-job flags replace that scope |
| `job:` GitHub connect | `cancel_github_connection` | `src-tauri/src/github.rs:3054-3075`; one flow runs at a time (`:3046-3047`) |
| `job:` macOS work | its gate entry (NEW, justified by 95 A-31) | Work waits in `operations.list.waiting`, displayed as “Waiting…” with Cancel, instead of a conflict refusal (95 §3 Queue). Cancelling a waiting job removes it before admission; admitted framework work retains its existing cancellation limits. Creation is cancelled through `computers.delete` as today (10 §3); do not claim framework cancellation support |
| `job:` update download | — | `NotCancellable`: no cancel exists (`src-tauri/src/updates.rs:513-536`) |
| `job:` guest exec | the process | NEW: SIGTERM, a grace period, then SIGKILL, with the exit confirmed (70 §2.1) |

- **Errors.**
  - An unknown `jobId` returns `not_found` (NEW, justified by [95 A-25](95-decisions.md)); the source gate's unknown-id no-effect success (`src-tauri/src/runtime/operation_gate.rs:1053-1055`) is not exposed as a second cancel path (95 §3). A retained finished job can be identified and needs no further cancellation.
  - `NotCancellable` reaches the client as `internal` with "This operation can't be cancelled." (`src-tauri/src/runtime/operation_gate.rs:62`; `src-tauri/src/bridge_error.rs:115-126`). 95 A-10 chooses stable macOS/exec/file codes, but does not name a new wire code for `NotCancellable`; this existing mapping stays until a separately sourced code is specified.
  - The cancelled job's `operations.job.finished` carries `error.code: "cancelled"`, except where today's command reports the cancellation as data, which stays in `result` (transfers; [§ 4.2 E](#job-contract) item 5).
- **Domain-specific cancel entry points are retired (95 §3).** Silo's Tauri UI calls `operations.cancel {jobId}` directly. `files.transfer.cancel`, `exports.cancel`, `exports.inspect.cancel`, `logs.export.cancel` and `github.connect.cancel` are source mappings only, not supported methods. Log exports cancel exactly one job (95 A-30).

A remote change's admission deadline is not a cancellation: work that has started runs to completion (`docs/SiloUI-CONNECTIONS.md` § Checkpoint request deadlines).

#### G. Capabilities and version negotiation

**Today.**
- The bridge **protocol** version must match exactly. Today it is 5 (`src-tauri/src/remote.rs:34-36`, checked at `:2166-2178`).
  - The check does not compare application releases. A mismatch is refused with `incompatible_version`; its reply also carries `version` and `appVersion` (`src-tauri/src/remote.rs:571-574`).
  - `docs/SiloUI-CONNECTIONS.md` § Published-port readiness, line 103, overstates this as a requirement for the same Silo release. The code requires the same protocol version (`src-tauri/src/remote.rs:2161-2184`).
  - Different releases are not refused merely for sharing protocol 5. Callers inspect the handshake's `capabilities` for missing methods (`src-tauri/src/remote.rs:1217-1244`); `unsupported_remote_operation` becomes, for example, "Update Silo on that device to use computer use." (`src-tauri/src/chatgpt_app.rs:2260-2268`).
- A mismatch closes every connection to that device (`src-tauri/src/remote.rs:1513-1525`).
- The handshake already lists method names as `capabilities` (`src-tauri/src/remote.rs:2222-2224`). Callers use it to skip methods an owner lacks (`device_capabilities`, `src-tauri/src/remote.rs:1217-1244`).

**Need.**
- Fjord is the user app; Silo maintains and ships the engine, and both apps use one engine per channel (95 A-1). The packaging paths remain implementation research (§10 OQ1/2).
- Builds of each channel derive every name from the bundle identifier and never share state (`src-tauri/src/channel.rs:1-9`; `docs/SiloUI-BUILD-CHANNELS.md`).
- Silo Dev never updates (`docs/SiloUI-BUILD-CHANNELS.md`, table row Updates).

So a client and the engine it reaches can come from different builds. Remote engines too: "Engines on other devices are reached over SSH" (owner decision).

**Spec.** `engine.handshake` (below) carries a protocol range and returns the chosen version and the capability list.
- Both sockets negotiate the new canonical protocol. No v5 controller exchange, legacy decoder or old-name dispatch is served (NEW, justified by 95 §3). The numeric new protocol version remains schema research (§10 OQ14).
- `incompatible_version` stays the refusal code.

#### H. JSON Schema from Rust and a generated Swift client (NEW, justified by 95 A-7)

What exists today:
- **TypeScript.** The Tauri UI parses every native payload with Zod schemas (`src/contracts/silo.ts`, for example `siloProgressEventSchema` at `:89`).
- **JSON fixtures.** Checked-in fixtures in `src/test/contracts/` are produced by Rust tests serializing the native structs. Frontend tests parse them (`src/test/contracts/README.md`).
- Rust types use `serde` with `rename_all = "camelCase"` throughout, for example `src-tauri/src/runtime/operation_gate.rs:94-95`.

**DECIDED (95 A-7):** Generate JSON Schema from the Rust types and generate Swift `Codable` from that schema; preserve existing serde names and check against the existing JSON fixtures. `schemars` honours serde attributes (https://docs.rs/schemars/latest/schemars/, v1.2.3). The generator choice and fixture proof remain implementation research; there is one source schema rather than a second manually defined wire model.

#### Methods

### engine.handshake
- **Kind:** query
- **Platforms:** both computer kinds; Mac hosts only (95 §3 Linux hosts dropped)
- **Status:** EXTENDED: bridge `handshake`, `src-tauri/src/remote.rs:237`, `:2203-2213`, `:2242-2247`, already returns device identity and capabilities and restricts the controller key. NEW protocol-range negotiation, client metadata and per-client identity support the authorized multiplexed engine connection (95 A-5/A-7). Renaming alone adds no behaviour (95 §3).
  - EXISTS: bridge `handshake`, Read (`src-tauri/src/remote.rs:237`, `:2203-2213`, `:2242-2247`).
  - NEW method contract, justified by [95 A-5/A-7](95-decisions.md): fields `protocol`, `client` and `clientId` support the authorized multiplexed local connection (§4.2 G, §5). Existing source fields below are the implementation baseline; old wire names are not accepted (95 §3).
- **Params:**
  - `sshKey?: string`: Silo's public key, to restrict (EXISTS, `src-tauri/src/remote.rs:2205`);
  - `protocol: {min: u32, max: u32}`: NEW, required versions the client speaks; no omitted-field legacy protocol fallback (95 §3);
  - `client?: {name: string, version: string}`: NEW, for logs and per-client state.
- **Result:**
  - `deviceId: string`, `name: string`, `capabilities: string[]` (EXISTS source fields);
  - `protocol: u32`: NEW, chosen version;
  - `clientId: string`: NEW, on `engine.sock` only.
- **Errors:** `incompatible_version` (with `version` and `appVersion`, `src-tauri/src/remote.rs:571-574`); `internal` when key restriction fails (`src-tauri/src/remote.rs:962-969`).
- **Semantics:**
  - On `control.sock`, canonical `engine.handshake` is exempt from the deviceId check, reusing today's check position (`src-tauri/src/remote.rs:2179`); old `handshake` is retired (NEW, justified by 95 §3).
  - On `engine.sock` it is the first request of a connection.
  - `capabilities` lists every method this engine serves (`src-tauri/src/remote.rs:2222-2224`). Today it is every `METHODS` name, so it also advertises `repository.push`, which is no longer served (80 §5 B-6; `src-tauri/src/remote.rs:261`). The new engine lists only canonical methods, leaving all retired names and that stub out (NEW, justified by 95 §3).
- **Sources:** above.

### engine.state
- **Kind:** query
- **Platforms:** both computer kinds; Mac hosts only (95 §3 Linux hosts dropped)
- **Status:** EXTENDED: tauri `read_shutdown_state`, `src-tauri/src/settings.rs:1043-1046`, already returns the active shutdown flag. NEW phase, generation, session-end and update-pending projections let clients observe engine shutdown and update preparation (95 A-2/A-6).
  - EXISTS in part: tauri `read_shutdown_state` returns `ShutdownState.active()` (`src-tauri/src/settings.rs:1043-1046`).
  - NEW method contract, justified by [95 A-2/A-6](95-decisions.md): fields below let other clients observe explicit engine shutdown and engine-update preparation (§6).
- **Params:** none.
- **Result:**
  - `shuttingDown: bool` (EXISTS as the bool);
  - `phase: "idle" | "requested" | "approved" | "finishing" | "flushing"`: NEW. These are the `ShutdownProgress.phase` values 0-4: 0 is idle, then `REQUESTED` = 1, `APPROVED` = 2, `FINISHING` = 3, `FLUSHING` = 4 (`src-tauri/src/settings.rs:539-551`);
  - `generation: u64`: NEW, from `ShutdownProgress.generation` (`src-tauri/src/settings.rs:541`);
  - `sessionEnding: bool`: NEW, from `session_deadline.is_some()` (`src-tauri/src/settings.rs:543-544`);
  - `updatePending: bool`: NEW, true while `update-resume.json` exists (`src-tauri/src/runtime/update_recovery.rs:18-20`, `:194-198`).
- **Progress/events:** `engine.shutdown.changed`, which replaces `silo://shutdown-state-changed` (`src-tauri/src/settings.rs:924`, `:960`).
- **Errors:** none.
- **Sources:** above.

### events.subscribe
- **Kind:** subscription
- **Platforms:** both computer kinds; Mac hosts only (95 §3 Linux hosts dropped)
- **Status:** EXTENDED: the existing Tauri `listen` adapter and event subscription loop (`src/desktop/production-source.ts:5`, `:33`, `:1081-1112`) already deliver selected local backend events. NEW engine-owned subscription identities, state-bearing sequenced bounded delivery and remote SSH relay replace remote polling (95 A-3/A-4; §4.2 D).
- **Params:** `events: string[]`, event names or `domain.*` prefixes; `deviceIds?: string[]`, NEW target engines to relay through the local engine, justified by 95 A-3/A-4. Omitted means this engine only.
- **Result:** `{subscription: string}`. Events then arrive with the envelope of § 4.2 D. The names are the [event catalogue](#event-catalogue) of § 4.2 D.
- **Semantics:**
  - On `engine.sock` the subscription lives on the connection.
  - Over SSH it is a NEW Stream-class method, justified by 95 A-4, of `METHODS` (`src-tauri/src/remote.rs:224-235`), because today's non-stream bridge request ends after one reply (`src-tauri/src/remote.rs:1748-1773`); that old exchange is replaced by the common canonical framed session (95 §3). It counts against the stream budget of 192 (`src-tauri/src/remote.rs:3380-3382`), and the Connections gate ends it like other streams (`src-tauri/src/remote.rs:2098-2102`).
- **Errors:** `unsupported_remote_operation` for an engine that lacks it (G).
- **Sources:** above.

### events.unsubscribe
- **Kind:** command
- **Platforms:** both computer kinds; Mac hosts only (95 §3 Linux hosts dropped)
- **Status:** EXTENDED: existing Tauri subscriptions return unlisten closures and invoke them on disposal (`src/desktop/production-source.ts:1109-1116`, `:2087`). NEW engine subscription-id disposal and remote-stream cleanup release the subscriptions introduced by `events.subscribe` (95 A-4).
- **Params:** `subscription: string`.
- **Result:** `null`.
- **Semantics:** idempotent. Closing the connection unsubscribes everything on it.

---

## 5. Channels and multiple clients

### 5.1 Channel isolation (production vs dev)

- There are exactly two channels, chosen by the compiled bundle identifier: `org.silo.preview` is production, and anything else is development (`src-tauri/src/channel.rs:15-49`).
- Every host-visible name derives from the channel: state dir, keychain services, bridge link and command, key comment, alias prefix, profiles, desktop entry, tray id (`src-tauri/src/channel.rs:51-131`). Tests pin production names and require every dev name to differ (`src-tauri/src/channel.rs:140-269`).
- "both channels can run at the same time on one device; they cannot collide on a socket, lock, link, key, or service name" (`docs/SiloUI-BUILD-CHANNELS.md` § Shared state that is now per channel).

**Engine consequences (NEW, from those rules).**
- `silod` must call `channel::init` from its own identifier. Today that identifier comes from `tauri::generate_context!()` (`src-tauri/src/main.rs:91-95`). See `EngineIdentity`, § 2.5.
- `engine.sock`, the engine lock and the LaunchAgent label must be channel-derived, like `control.sock`.
- One engine per channel per user.

### 5.2 The single-instance rule

- **Today there are two locks.**
  - The Tauri single-instance plugin, keyed by bundle identifier, so one app process per channel (`src-tauri/src/single_instance.rs:1-3`; `docs/SiloUI-BUILD-CHANNELS.md`, table row "macOS login item, notification permission, single-instance lock").
  - `control.lock`, so one Connections owner (`src-tauri/src/remote.rs:2014-2030`).
- **For the engine:**
  - NEW, justified by [95 A-1](95-decisions.md): Fjord is the user app; Silo maintains/ships the engine in Silo.app, whose UI is a client. Both app installations share one engine per channel. The engine uses an exclusive `flock` like `control.lock`; packaging/registration paths remain research (OQ1/2).
  - A second `silod` of the same channel exits.
  - Clients are many by design, so the client app's own single-instance rule is a client concern.

### 5.3 Two clients at once (Silo's UI and Fjord): per-client vs engine state

Today the "clients" are Tauri windows of one process. Windows are told apart by label: `main`, `status`, `desktop-shell-*`, `help` (§ 2.4, caller window).

| State | Where it lives today | Engine or per client | Why |
| --- | --- | --- | --- |
| Onboarding draft | `settings.json` `onboardingDraft`, written only by `main` (`src-tauri/src/settings.rs:47-50`, `:803-812`). Stripped from broadcasts (`src-tauri/src/settings.rs:755-760`) and from non-main reads (`src-tauri/src/settings.rs:779-791`). | **Per client** | It is one window's unfinished input: "the current step, saved computer configurations, unfinished computer editor …" (`docs/SiloUI-SETTINGS.md` § Saved values) |
| Quit confirmation | `QuitConfirmation {enabled, session_ending, pending, next}`. `enabled` is set by the main UI (`src-tauri/src/settings.rs:1051-1060`, `:1152-1161`). The prompt is `emit_to("main", "silo://quit-requested")` (`src-tauri/src/settings.rs:1141-1149`). | **Per client** (§ 6) | It asks the person in front of one UI |
| Settings flush on quit | `settings:flush-request` to `main`; `begin`/`complete`/`cancel_settings_flush` (`src-tauri/src/settings.rs:961-963`, `:1182-1211`) | **Per client** | It drains one webview's pending edits (`docs/SiloUI-SETTINGS.md` § Shared state and failures, last paragraph) |
| Window routes | `PanelState.route`, `open_main(route)` / `take_main_route` (`src-tauri/src/status_panel.rs:153-174`) | **Client only** | Navigation |
| Transfer selections | Keyed by window label (`src-tauri/src/transfer.rs:1342-1392`) | **Per client** (key by `clientId`) | A selection token is valid only for the client that picked the files |
| Viewer window ownership | Viewer commands check their own label (`src-tauri/src/desktop_viewer.rs:699-707`; `src-tauri/src/macos_remote_viewer.rs:201-204`) | **Client only**, except the engine-owned macOS window | UI windows |
| Main-window focus | `notifications::main_window_focused` picks toast or system notification (`src-tauri/src/notifications.rs:291-296`) | **Per client** | Only Fjord shows notices; the engine retains latest notices per key and posts no OS notifications (NEW, justified by 95 A-27) |
| Preferences read by the engine | `startComputersAtLaunch`, `startupComputerIds`, `onboardingComplete` (`src-tauri/src/startup.rs:18-37`); `computerUseAutoApproval` (`src-tauri/src/computer_use.rs:197`); `notificationsEnabled`, `notify*` (`src-tauri/src/notifications.rs:105-115`) | **Engine**, except notice presentation preferences belong to Fjord | Startup/computer-use behaviour stays shared; notice presentation moves to Fjord (95 A-27) |
| Preferences only UIs use | `theme`, `reduceMotion`, `alphaNoticeDismissed`, `editorIncludeNoticeDismissed`, `computerOrder` ("the UI owns the keys"), `terminal`/`editor`/`browser` and their paths (`src-tauri/src/settings.rs:245-283`; theme applied natively at `src-tauri/src/settings.rs:745-752`; app choices used for launching at `src-tauri/src/applications.rs:95-130`) | **Per client** | Presentation and launching apps on the client's machine |
| `launchAtLogin` | `SMAppService.mainAppService` of the Silo app (`src-tauri/src/system_integrations/macos.rs:113-138`) | **Per client** (the app's own login item); the engine agent is separate (§ 3.2) | Different services |
| Computers, operations, backups, Connections, secrets, GitHub, update journal, shutdown state | Engine modules (§ 1) | **Engine** | Shared device state |

The `settings.*` section owns the method split. This section only fixes the rule:
- engine keys are read and written through the engine;
- per-client keys are scoped by `clientId` from `engine.handshake`, or kept by the client.

Writes from two clients are already serialized by one Rust mutex (`src-tauri/src/settings.rs:762-776`; `docs/SiloUI-SETTINGS.md` § Shared state and failures).

---

## 6. Quit, update and shutdown for an engine that outlives clients

### 6.1 Today

- **Quit (today).** Every Quit entry point (menus, ⌘Q, tray, status panel; the Linux window-close path is RETIRED under 95 §3) calls `request_quit` (`src-tauri/src/settings.rs:1119-1150`). Then:
  - With confirmation enabled and computers running, it emits `silo://quit-requested {requestId, computers}` to `main` and waits for `answer_quit_request` (`src-tauri/src/settings.rs:1062-1068`, `:1163-1180`). Otherwise it exits.
  - `ExitRequested` is gated (`src-tauri/src/settings.rs:937-950`). `begin_exit` cancels startup, closes admission (`runtime::shutdown::begin`), emits `shutdown-state-changed: true` and asks `main` to flush. A 2 s fallback covers a webview that never acknowledges (`src-tauri/src/settings.rs:529-535`, `:953-972`).
  - `finish_exit` stops local computers, flushes settings, closes tunnels and exits. On failure, `cancel_exit` reopens admission and shows the error (`src-tauri/src/settings.rs:879-935`).
- **Session end.** No prompt, a 20 s bound, and a failure never cancels it (`src-tauri/src/settings.rs:981-1018`).
- **Update.** `install_update(stop_computers)` (`src-tauri/src/updates.rs:761-865`):
  1. cancels startup;
  2. refuses while a macOS computer is busy (`close_for_update`);
  3. takes the backup, GitHub and secrets update guards and the device-wide gate;
  4. flushes settings (`flush_for_update`, `src-tauri/src/settings.rs:2261-2272`);
  5. pauses transfers;
  6. `update_recovery::prepare`: requires consent if computers run, writes `update-resume.json {version: 1, computers: [{id, name}]}` before the first stop, stops them, and retires other saved lifecycle intents (`src-tauri/src/runtime/update_recovery.rs:6-17`, `:184-230`);
  7. installs;
  8. on failure, reopens macOS admission and restores the running set (`src-tauri/src/updates.rs:838-844`);
  9. on success, `shutdown::begin()`, then `restart()`. Restart skips the Quit flow (`ExitRequest::Restart`, `src-tauri/src/settings.rs:678-697`).
- **After the update.** At the next start, `update_recovery::recover` resumes exactly that set and deletes the journal. A partial failure keeps the failed entries (`src-tauri/src/runtime/update_recovery.rs:231-310`; `src-tauri/src/startup.rs:227-233`).
- **Fjord's own updater** waits only for Fjord's own PID, then swaps the whole `.app` bundle and opens it (Fjord: `Sources/Fjord/Updater.swift:337-361`).

### 6.2 Client quit and engine update are separate contracts

**DECIDED (95 A-2):** With running computers, the client asks “Quit Fjord? 2 computers are running: dev, linux-1.” and offers **Cancel / Keep running / Stop and quit**. It reads `computers.list` (10 §1.3; Linux `runtime.snapshot`, `src-tauri/src/remote.rs:238`; macOS `macos.snapshot`, `:266`) and uses platform state to identify running computers. Cancel leaves the connection and computers unchanged. Keep running flushes client edits and calls `engine.disconnect`; Stop and quit calls `computers.stop` for those computer ids, observes `computers.changed` until they have stopped, then disconnects. A stop refusal leaves the client open to show the error. These client behaviours are NEW, justified by [95 A-2](95-decisions.md), building on current confirmation and stop commands (§6.1; 10 §4; 30 §4).

A Fjord update or Fjord crash only loses that client connection; neither calls `engine.shutdown` nor stops computers (95 A-2). The separate `silod` process continues to own macOS VMs (§1.4). This does not claim VM survival after an engine crash.

**DECIDED (95 A-6):** Replace the engine only when its own version changes. The containing Mac app's installer prepares save-and-resume, waits for preparation to finish, calls `engine.shutdown {reason: "update", stopComputers: false}`, waits for engine exit, replaces its package, then restarts its LaunchAgent. A client-only update skips this handshake. No Debian/AppImage or Linux-service update route exists (95 §3 Linux hosts dropped). The installer never replaces an engine executable while it is serving; Fjord's present updater waits only for its own PID (Fjord: `Sources/Fjord/Updater.swift:337-361`), so this coordination is NEW, justified by 95 A-6. The exact package owner and installed paths require packaging research (OQ1/2).

**Qualified macOS saved-state mechanism (B-30).** On host macOS 26.5 / guest 26.6.2, pause → `saveMachineStateTo` → APFS disk/auxiliary clone → host-process SIGKILL → new process with the same VZ configuration → restore → resume preserved `kern.boottime` and the same guest sleep process/PID/start time. Guest uptime advanced 42→44 s while host time advanced about 50 s, so the saved interval is excluded from guest uptime. Follow-up timings were pause 0.007 s, save 2.279 s, clone 0.241 s, restore 6.708 s, resume 0.484 s and SSH readiness 1.184 s ([macos.md Follow-up §B-30](probes/macos.md#b-30--confirmed-for-saved-guest-state)).

The update contract uses this macOS path to preserve running guest state across process replacement. Holding/releasing the saved generation, durable update-journal ordering, install rollback, partial-save/restore failures and host/runtime compatibility still require implementation qualification; Linux continuity was not run. A successful process replacement is not a complete engine-update transaction (95 A-6; B-30).

### engine.disconnect
- **Kind:** command
- **Platforms:** both computer kinds; Mac hosts, local clients only
- **Status:** NEW: no current engine-client detach method exists; today ownership is tied to Tauri windows/process (§1/§5). Required by [95 A-2](95-decisions.md): Keep running and completed Stop and quit detach the caller without stopping the engine or computers.
- **Params:** none; the connection's `clientId` from `engine.handshake` identifies the caller (NEW per-client identity, §5).
- **Result:** `null`, then the caller's local connection closes.
- **Progress/events:** none; it unsubscribes that connection's events (§4.2 D).
- **Errors:** no computer lifecycle error; unsaved edits must be flushed before this call (60 `settings.flush`; `src-tauri/src/settings.rs:831-848`).
- **Semantics:** drops only the caller's subscription/viewer attachments; other clients and accepted engine work continue. Each client owns an independent viewer connection (NEW, justified by 95 A-28). Closing/crashing the client connection has the same detach semantics (95 A-2).
- **Sources:** 95 A-2/A-28; current per-window viewer ownership (`src-tauri/src/desktop_viewer.rs:699-707`; `src-tauri/src/macos_remote_viewer.rs:201-204`).

### operations.job.get
- **Kind:** query
- **Platforms:** both computer kinds; Mac hosts, local or remote engine through the local engine
- **Status:** NEW: no generic current job/outcome lookup exists. Remote change retries attach through `src-tauri/src/remote/operations.rs:117-132`; domain journals are not this query. Required by [95 §3 Job results](95-decisions.md#3-amendments-owner-2026-10-13-later), overriding A-25: clients read completed outcomes saved to disk until acknowledged.
- **Discovery:** read `operations.list.unacknowledgedJobIds` (10 §6) after a fresh client connection or engine restart, then get/show/acknowledge each retained completion (NEW, justified by 95 §3).
- **Params:** `jobId: JobId` (§4.2 E); `deviceId?: string` selects the owning remote engine (NEW relay, justified by 95 A-3; 80 §2 N16).
- **Result:** NEW `{jobId, state: "waiting" | "running" | "finished", outcome?: {result?, error?}}`; `jobId` identifies the job, `state` distinguishes queued/running work from a terminal outcome, and `outcome` carries the `result`/`error` fields of `operations.job.finished` (§4.2 E). New fields are justified by 95 §3 Job results/Queue. Recovery representation for interrupted unfinished jobs remains probe B-37; no process continuation is invented.
- **Progress/events:** `operations.job.progress`, `operations.job.finished` (§4.2 E); queued work is shown through `operations.queue.changed`/`operations.list.waiting` (95 A-31/§3 Queue).
- **Errors:** `not_found` for an unknown or acknowledged/dropped outcome, rather than because of time elapsed or engine restart (NEW use, justified by 95 §3; existing code `src-tauri/src/bridge_error.rs:4-15`). Disk-read failures use `internal` with a message, not a fabricated missing outcome (same existing error enum).
- **Semantics:** the owning engine persists every completed outcome until a client acknowledges showing it. Reads never consume it; restart does not discard it. Generic durable storage/ID allocation and interrupted-work recovery need probe B-37 (§10 OQ25).
- **Sources:** 95 §3 Job results; existing domain journal precedents `src-tauri/src/host_push_operations.rs:196-198`, `src-tauri/src/backup_controller.rs:948`. These sources do not establish a generic durable job registry.

### operations.job.acknowledge
- **Kind:** command
- **Platforms:** both computer kinds; Mac hosts, local or remote engine through the local engine
- **Status:** NEW: no current generic outcome acknowledgement/drop method exists; remote change results expire instead (`src-tauri/src/remote/operations.rs:22-31`). Required by [95 §3 Job results](95-decisions.md#3-amendments-owner-2026-10-13-later): drop a completed outcome after a client has shown it.
- **Params:** `jobId: JobId`, identifies the displayed outcome; `deviceId?: string`, selects its owning remote engine (95 A-3; 80 §2 N16). Both fields are NEW, justified by 95 §3's acknowledge requirement and the remote-owner job contract (§4.2 E).
- **Result:** `null` after durable acknowledgement/drop.
- **Progress/events:** none required; reads after a successful drop return `not_found`.
- **Errors:** `busy` if the job is still waiting/running, because no terminal outcome has been shown; `internal` on persistence failure, leaving the outcome retained (NEW uses, justified by 95 §3; existing codes `src-tauri/src/bridge_error.rs:4-15`). An already dropped/unknown id succeeds without effect, keeping acknowledgement idempotent; unknown cancellation remains `not_found` (§4.2 F).
- **Semantics:** call only after showing a terminal outcome. The owning engine drops that outcome globally when any authorized client acknowledges it; other clients can no longer read it. Success survives engine restart. Repeated calls succeed without dropping unrelated state. It changes outcome retention, not the finished job's domain effects. Durable commit/drop and concurrent get/acknowledge races require probe B-37; no storage mechanism is invented.
- **Sources:** 95 §3 Job results; local authorization §4.2 C and remote-owner addressing §4.2 E.

### engine.shutdown
- **Kind:** job (long; returns a job id, reports progress)
- **Platforms:** both computer kinds; Mac hosts only (95 §3 Linux hosts dropped)
- **Status:** EXTENDED: tauri `status_panel::quit_app`, `src-tauri/src/status_panel.rs:176-179`, reaches shutdown through `begin_exit` → `finish_exit` (`src-tauri/src/settings.rs:879-972`) and `end_session` (`:981-1018`), including `stop_local_computers` (`src-tauri/src/runtime/shutdown.rs:96-129`). NEW explicit engine shutdown independent of client Quit, durable job reporting and release of a prepared saved VM generation for update follow 95 A-2/A-6/§3 Job results.
  - EXISTS as behaviour: the Quit path `begin_exit` → `finish_exit` (`src-tauri/src/settings.rs:879-972`); the session-end path `end_session` (`src-tauri/src/settings.rs:981-1018`); `stop_local_computers` (`src-tauri/src/runtime/shutdown.rs:96-129`).
  - NEW part, justified by [95 A-2/A-6 and §3 Job results](95-decisions.md): separate engine/session shutdown with durable job reporting and saved-generation release for update.
- **Params:**
  - `stopComputers: bool`. NEW, justified by 95 A-2/A-6: `true` explicitly stops local computers using today's shutdown behaviour. `false` with `reason: "update"` requires successful save-and-resume preparation and releases the saved runtime instances without guest shutdown. Other `false` requests require no macOS machine still owned by this engine (§1.4). Client Quit uses `engine.disconnect`, not this method (§6.2).
  - `reason: "user" | "sessionEnd" | "update"`. These are today's `ShutdownReason::UserQuit` and `Logout`/`Shutdown` (`src-tauri/src/system_shutdown.rs:31-38`) and `ExitRequest::Restart` (`src-tauri/src/settings.rs:678-697`). `sessionEnd` never cancels on failure. `update` requires a completed `engine.update.prepare`, preserves the saved disk/memory set and performs no guest shutdown (NEW, justified by 95 A-6).
  - `deadlineMs?: u64`: the bound for `sessionEnd` (default `SESSION_END_BUDGET` = 20 000, `src-tauri/src/system_shutdown.rs:23`).
- **Result:** `{jobId}` ([§ 4.2 E](#job-contract)). The engine exits after `operations.job.finished` with no error. `ProcessControl.exit`, § 2.5.
- **Progress/events:**
  - `engine.shutdown.changed {shuttingDown}` (today `silo://shutdown-state-changed`, `src-tauri/src/settings.rs:924`, `:960`);
  - its gate entry on `operations.queue.changed`, relabelled "Stopping {name} ({index} of {total})" (`src-tauri/src/runtime/shutdown.rs:116-120`). It reports no `operations.job.progress` source of its own ([§ 4.2 E](#job-contract) item 4);
  - `operations.job.finished` at the end.
- **Errors:**
  - `internal` with the existing texts, such as "Silo stayed open because its local computers could not shut down safely …" or "Local computers stopped, but Silo could not save its settings …" (`src-tauri/src/settings.rs:892-909`). Admission then reopens (`cancel_exit`, `src-tauri/src/settings.rs:920-935`).
  - A `stopComputers: false` update request without a completed save journal is refused (NEW, justified by 95 A-6); an active save or failed save never authorizes package replacement. Other requests retaining a live macOS machine remain refused because exiting its owner destroys it (§1.4).
- **Semantics:**
  - On begin: `runtime::shutdown::begin()` refuses new operations everywhere (`src-tauri/src/runtime/shutdown.rs:13-20`, `:50-58`). It cancels waiting gate entries (`src-tauri/src/runtime/shutdown.rs:132-156`), cancels startup (`src-tauri/src/settings.rs:953-958`), and cancels transfers (`src-tauri/src/runtime/shutdown.rs:19`).
  - Remote retries in flight end with `cancelled` (`src-tauri/src/remote.rs:1308-1316`).
  - It never stops computers on other devices (`src-tauri/src/runtime/shutdown.rs:1-2`).
  - It is idempotent while a shutdown runs: a second request attaches. Today `request_generation` returns `None` when a phase is active (`src-tauri/src/settings.rs:557-566`).
- **Sources:** above.

### engine.update.prepare
- **Kind:** job
- **Platforms:** both computer kinds; Mac hosts only (95 §3 Linux hosts dropped)
- **Status:** EXTENDED: tauri `install_update`, `src-tauri/src/updates.rs:799-834`, already guards admission, flushes settings and journals the running set through `update_recovery::prepare` (`src-tauri/src/runtime/update_recovery.rs:184-230`). NEW split engine-update preparation, memory-preserving save/hold/resume and durable job outcomes are required by 95 A-6/§3 Job results.
  - EXISTS as the first half of `install_update`, before `update.install` (`src-tauri/src/updates.rs:799-834`), and `update_recovery::prepare` (`src-tauri/src/runtime/update_recovery.rs:184-214`).
  - NEW part: split engine handoff and save/resume contract, justified by [95 A-6](95-decisions.md): the engine update saves running computers to disk and resumes them after replacement; existing stop/start recovery below is the baseline, not the new guarantee.
- **Params:** none. NEW, justified by 95 A-6: this prepares an engine-version change using save/resume rather than consent to guest shutdown. Callers compare the engine version before invoking (§6.2).
- **Result:** `{jobId}` at once ([§4.2 E](#job-contract)); finished result is `{resuming: [{id, name}]}`, existing `RunningComputer` identity entries (`src-tauri/src/runtime/update_recovery.rs:6-17`). NEW durable journal state references identify each computer's saved disk and memory; their on-disk representation is implementation research (§10 OQ24), justified by 95 A-6.
- **Progress/events:** its gate entry on `operations.queue.changed` (`OperationKind::Shutdown`, label "Installing update", `src-tauri/src/updates.rs:817-819`); `operations.job.finished` with the result; `engine.shutdown.changed`.
- **Errors:**
  - macOS memory-save unsupported or failed: refuse the update and resume any paused machine; never substitute a cold boot for a running task (NEW, justified by 95 A-6; existing refusal `src-tauri/src/macos_computers/checkpoints.rs:378-380`);
  - "Wait for active operations to finish before updating." (`src-tauri/src/updates.rs:810`);
  - the backup, GitHub and secrets guard errors (`src-tauri/src/updates.rs:813-815`);
  - "A previous update still has computers to resume. Relaunch Silo before updating again." (`src-tauri/src/runtime/update_recovery.rs:194-198`).
- **Semantics:**
  - Holds admission closed until `engine.shutdown {reason: "update"}` or `engine.update.abort`.
  - Flushes settings (`src-tauri/src/settings.rs:2261-2272`).
  - Persist the running set and save references before releasing any runtime, extending today's journal-before-stop ordering (`src-tauri/src/runtime/update_recovery.rs:221-229`). NEW, justified by 95 A-6.
  - **macOS:** reuse the existing pause → `saveMachineStateToURL` → disk/auxiliary-storage capture path (`src-tauri/src/macos_computers/engine.rs:1097-1125`; `src-tauri/src/macos_computers/checkpoints.rs:340-353`, `:414-471`). Resume with `restoreMachineStateFromURL` then `resume_paused` (`engine.rs:809-810`, `:935`, `:1055-1068`). Today's checkpoint helper resumes immediately; holding the saved generation through the update and settling release/recovery is NEW orchestration. Cross-process saved clock/process continuity is confirmed by [macos.md Follow-up §B-30](probes/macos.md#b-30--confirmed-for-saved-guest-state); full update failure recovery remains OQ24.
  - **Linux:** reuse a verified full `msb snapshot create --full --guest-flush required --integrity` for running computers (`src-tauri/src/runtime/checkpoints.rs:650-658`, `:704-725`), then resume through the existing `msb restore <group>:<checkpoint> --name <name> --cow-mem` path (`:1297-1309`). The current updater instead shuts down and starts (`runtime/update_recovery.rs:184-310`); integrating full capture, suspend/release and crash-safe restore is NEW, justified by 95 A-6, pending OQ24.
  - A memory restore that cannot preserve the run refuses or reports failed resume and keeps the journal. Today macOS checkpoints may cold-boot after a host-build change (`macos_computers/checkpoints.rs:744-759`); that fallback does not satisfy engine-update continuity and must not be used silently here (95 A-6).
  - The next engine start resumes the set before any start-at-launch (`src-tauri/src/startup.rs:227-233`). A failed resume is reported to the update state (`src-tauri/src/updates.rs:191-206`).
- **Sources:** above.

### engine.update.abort
- **Kind:** command
- **Platforms:** both computer kinds; Mac hosts only (95 §3 Linux hosts dropped)
- **Status:** EXTENDED: the failure branch of tauri `install_update`, `src-tauri/src/updates.rs:838-844`, already reopens macOS admission and calls `update_recovery::restore_locked` (`src-tauri/src/runtime/update_recovery.rs:231-257`). NEW explicit rollback of saved-memory generations instead of cold starts is required by 95 A-6.
  - EXISTS as the failure branch of `install_update` (`src-tauri/src/updates.rs:838-844`): `macos_computers::reopen_after_update` (`src-tauri/src/macos_computers.rs:501-503`), then `update_recovery::restore_locked` (`src-tauri/src/runtime/update_recovery.rs:231-257`).
  - NEW part: saved-state rollback contract, justified by [95 A-6](95-decisions.md): failed installation must resume the saved running set without cold-starting tasks.
- **Params:** none.
- **Result:** `null`.
- **Errors:** "{error}\nComputers could not resume: {resume}. Relaunch Silo to retry." (`src-tauri/src/updates.rs:842-843`).
- **Semantics:**
  - Restores/resumes the exact saved running set, then reopens admission; any failed resume remains journaled. NEW, justified by 95 A-6; today's recovery idempotency below is reused, while saved-memory orchestration remains OQ24.
  - Each success is persisted, so a retry is idempotent (`src-tauri/src/runtime/update_recovery.rs:231`, `:274-298`).

---

## 7. Engine startup sequence (for reference by the other sections)

**Mac-only engine startup (NEW, justified by 95 §3 Linux hosts dropped):** `silod` runs in its Mac LaunchAgent GUI login session (§3.2). The Linux package guard is RETIRED source coverage (§7.1), not a startup step. Both Linux and macOS computers remain managed by this engine.

Then `silod` runs what Tauri's `setup` runs today, minus UI, in this order (`src-tauri/src/main.rs:291-352`). NEW, justified by 95 §3: all required stored-data conversion runs here at launch through existing `runtime_migration`; old/name-keyed runtime paths and migration compatibility methods are removed once the new version is reached:
1. vocabulary migration (`runtime_migration::vocabulary::run`);
2. settings and shutdown state;
3. operation-queue listener;
4. storage migration (`runtime_migration::install`);
5. computer use;
6. pre-upgrade backup;
7. Connections (`remote::start`);
8. secrets (startup recovery, 50 §`secrets.*` Background; `src-tauri/src/secrets.rs:903-931`, called at `src-tauri/src/main.rs:305`);
9. GitHub;
10. backup;
11. pending storage migration (`runtime_migration::start_if_pending`);
12. notifications;
13. updates state (without the Tauri plugin);
14. SSH-access monitor;
15. editor transports;
16. storage monitor;
17. `startup::install`, with recovery order as § 1.6.

The tray, menu, status panel, main window and titlebar are not part of it (§ 2.4).

### 7.1 Linux package-update guard (RETIRED source behaviour)

**DECIDED (95 A-23, overridden by 95 §3 Linux hosts dropped):** The Linux startup guard is not part of `silod`; no Debian/AppImage engine updater or Linux service exists. Existing Linux packages stop receiving engine updates, and probes B-9/B-26 are closed.

Historical coverage: today's app checks `/usr/bin/silo-ui` and `/var/lib/silo/package-update-in-progress` before helper dispatch (`src-tauri/src/main.rs:83-104`; `src-tauri/src/system_integrations.rs:161-203`). Debian preinst creates the marker and refuses replacement while the app/bundled runtime runs (`app/SiloUI/scripts/debian/preinst:4-37`); postinst/postrm remove it (`postinst:18`; `postrm:34`). The old notice uses stderr/GTK (`src-tauri/src/system_integrations/linux.rs:277-294`). These are RETIRED host paths, not APIs or implementation requirements. Mac app replacement still uses `engine.update.prepare`/`engine.shutdown`/`engine.update.abort` (§6), preserving Linux and macOS computers with save/resume.

---

## 8. Mode and binary mapping

| Today | Engine world | Status |
| --- | --- | --- |
| Tauri app process (`src-tauri/src/main.rs:113-381`) | `silod` (engine) plus clients (Silo UI, Fjord) | NEW (owner decision) |
| `--remote-bridge` (`src-tauri/src/remote.rs:1748-1773`) | Relay the canonical multiplexed framed session to `control.sock`; no old one-shot/v5 name dispatch. The stable installed target remains OQ2 | NEW, justified by 95 A-7/§3; today's helper is the source seam |
| `--remote-guest` (`src-tauri/src/remote.rs:1804-1860`) | Stream canonical `guest.ssh` using `computerId`; read only the current device schema and no old-name fallback | NEW contract, justified by 95 A-11/A-13/§3; existing stream relay is the seam |
| `--msb-ssh-serve` (`src-tauri/src/editor.rs:862-902`) | RETIRED AppImage-only source helper; Mac guest SSH uses the canonical transport in 50 | RETIRED, 95 §3 Linux hosts dropped |
| Linux package-update guard (`src-tauri/src/main.rs:83-90`) | RETIRED source behaviour (§7.1); no Mac engine startup dependency | RETIRED, 95 §3 Linux hosts dropped |

---

## 9. Coverage table

### 9.1 Tauri commands in scope

| Tauri command | Source | API mapping |
| --- | --- | --- |
| `read_shutdown_state` | `src-tauri/src/settings.rs:1043-1046` | `engine.state` (`shuttingDown`) |
| `answer_quit_request` | `src-tauri/src/settings.rs:1163-1180` | UI-only, not in API: client confirmation offers Cancel / Keep running / Stop and quit; uses `computers.list`, `computers.stop` and `engine.disconnect` (95 A-2; §6.2) |
| `enable_quit_confirmation` | `src-tauri/src/settings.rs:1152-1161` | UI-only, not in API: per-client flag (§ 5.3) |
| `flush_settings` | `src-tauri/src/settings.rs:831-848` | `settings.flush` (60 §2.2), per 80 §2 N14: it retries a failed save and bumps `revision` (`src-tauri/src/settings.rs:831-849`), which is engine work. The engine also flushes inside `engine.shutdown` and `engine.update.prepare` (`src-tauri/src/settings.rs:898-914`, `:2261-2272`). A client's drain of its own pending edits stays client-side |
| `begin_settings_flush` | `src-tauri/src/settings.rs:1182-1190` | UI-only, not in API: webview acknowledgement of `settings:flush-request` (§ 5.3) |
| `complete_settings_flush` | `src-tauri/src/settings.rs:1206-1211` | UI-only handshake. It triggers `finish_exit`, which maps to `engine.shutdown` |
| `cancel_settings_flush` | `src-tauri/src/settings.rs:1192-1204` | UI-only: the client does not call `engine.shutdown` |
| `status_panel::open_main` | `src-tauri/src/status_panel.rs:153-169` | UI-only, not in API: window routing (§ 5.3) |
| `status_panel::take_main_route` | `src-tauri/src/status_panel.rs:171-174` | UI-only, not in API |
| `status_panel::hide_status` | `src-tauri/src/status_panel.rs:145-151` | UI-only, not in API: status window |
| `status_panel::resize_status` | `src-tauri/src/status_panel.rs:131-143` | UI-only, not in API: status window |
| `status_panel::quit_app` | `src-tauri/src/status_panel.rs:176-179` | UI-only entry to the client's three-option quit (§6.2; 95 A-2) |
| `app_menu::set_app_menu_state` | `src-tauri/src/app_menu.rs:68-81` | UI-only, not in API: native menu (`src-tauri/src/app_menu.rs:123-373`) |
| `app_menu::show_app_menu` | `src-tauri/src/app_menu.rs:83-95` | UI-only, not in API |
| `tray::update_tray` | `src-tauri/src/tray.rs:405-408` | UI-only, not in API: status item |
| `updates::install_update` | `src-tauri/src/updates.rs:761-865` | `engine.update.prepare` (80 §2 N13). The sequence is `engine.update.prepare` → `engine.shutdown {reason: "update", stopComputers: false}` → installer replaces package → engine restart/resume; a pre-shutdown failure calls `engine.update.abort`. Save-and-resume is NEW, justified by 95 A-6 (60 §5.2). The download and check commands are the `updates.*` section's |
| `settings::initialize_settings`, `read_settings`, `update_settings`, `update_onboarding_draft`, `import_legacy_theme` | `src-tauri/src/settings.rs:719-829` | In order: engine startup loads settings, no method (§ 7 step 2); `settings.read`; `settings.update`; client-owned onboarding draft (95 A-5); retired legacy theme import (95 §3; no API method). The engine vs per-client split is fixed in § 5.3 |
| `system_integrations::set_login_item`, `read_system_integrations` | `src-tauri/src/system_integrations.rs:59-80` | UI-only, not in API: the client's own login item. The engine's LaunchAgent registration is separate (§ 3.2); `device.*` reports engine hosting. |
| `system_integrations::show_integration_error` | `src-tauri/src/system_integrations.rs:104-118` | UI-only (dialog). Engine-originated uses become `notifications.notice` events (§ 2.4) |
| `transfer::choose_upload_files` | `src-tauri/src/transfer.rs:1342-1370` | UI-only picker; the engine takes paths (§ 2.4), `files.*` section |
| `backup_controller::choose_backup_destination` | `src-tauri/src/backup_controller.rs:506-543` | UI-only picker; the engine takes a path, and its remembered default is an `exports.*` setter |
| `backup_controller::choose_backup_archive` | `src-tauri/src/backup_controller.rs:546-570` | UI-only picker; path param, `exports.*` |
| `applications::choose_application` | `src-tauri/src/applications.rs:219-245` | UI-only, client preference (§ 5.3) |
| `backup_controller::reveal_backup_archive`, `pre_upgrade_backup::reveal_pre_upgrade_backup` | `src-tauri/src/backup_controller.rs:708-730`; `src-tauri/src/pre_upgrade_backup.rs:525-540` | UI-only (opener); the engine returns paths |

### 9.2 Bridge methods and modes in scope

| Bridge method or mode | Source | API mapping |
| --- | --- | --- |
| `handshake` (historical) | `src-tauri/src/remote.rs:237`, `:2203-2213`, `:2242-2247` | RETIRED source name → canonical `engine.handshake` (EXTENDED: negotiated protocol/client identity, 95 A-5/A-7; rename required by 95 §3) |
| All other `METHODS` (transport only) | `src-tauri/src/remote.rs:236-272` | Canonical method names and current classes on `control.sock`; changed old names are RETIRED and never accepted as aliases (95 §3; domain sections) |
| `--remote-bridge`, `--remote-guest`, `--msb-ssh-serve` | § 1.2 | § 8 |
| Linux package-update guard | `src-tauri/src/main.rs:83-90` | RETIRED Linux-host source behaviour (95 §3); coverage only, §7.1 |

### 9.3 Events and their delivery

"Hint" means a payload-less event after which the client re-reads.

| Event (today) | Emitted at | Payload | Delivery today | API mapping |
| --- | --- | --- | --- | --- |
| `silo://application-state-changed` | 40 sites (§ 2.3, for example `src-tauri/src/runtime/shutdown.rs:127`, `src-tauri/src/backup_controller.rs:413`, `src-tauri/src/startup.rs:243`) | none | Broadcast hint; UI re-reads `read_application_state` and `read_backup_state` (`src/desktop/production-source.ts:986-993`) | Split by emit site into `computers.changed`, `checkpoints.changed`, `exports.changed`, `migration.changed`, `github.changed`, `secrets.changed` and `push.changed` ([catalogue](#event-catalogue)); NEW state payload, justified by 95 A-4. Backup progress is also `operations.job.progress` with `source: "backup"` ([§ 4.2 E](#job-contract)) |
| `silo://operation-queue-changed` | `src-tauri/src/main.rs:297-300` | none | Broadcast hint, then `read_operation_queue` | `operations.queue.changed`; NEW state payload, justified by 95 A-4 |
| `silo://computer-configuration-progress` | `src-tauri/src/runtime.rs:3586`, `:4181`, `:4183`; `src-tauri/src/runtime/configuration_recovery.rs:632` | `SiloProgressEvent` | `emit_to("main")` | `operations.job.progress` with `source: "setup"`, `Audience::Client` of the requester ([§ 4.2 E](#job-contract)) |
| `silo://lifecycle-progress` | `src-tauri/src/runtime.rs:3343` | `{computerId, action, step}` | Broadcast | `operations.job.progress` with `source: "lifecycle"` ([§ 4.2 E](#job-contract)) |
| `silo://network-state-changed` | `src-tauri/src/network.rs:822`; `src-tauri/src/remote_network.rs:541`; `src-tauri/src/ssh_access.rs:667`, `:963` | none | Broadcast hint | `network.changed` (50); NEW state payload, justified by 95 A-4 |
| `silo://shutdown-state-changed` | `src-tauri/src/settings.rs:924`, `:960` | `bool` | Broadcast | `engine.shutdown.changed` |
| `silo://quit-requested` | `src-tauri/src/settings.rs:1143` | `{requestId, computers}` | `emit_to("main")` | UI-only, not in API (per-client confirmation, § 5.3) |
| `settings:flush-request` | `src-tauri/src/settings.rs:962` | none | `emit_to("main")` | UI-only, not in API (§ 5.3) |
| `settings:changed` | `src-tauri/src/settings.rs:759` | `Snapshot` without draft | Broadcast | `settings.changed` (`settings.*` section) |
| `silo://update-state` | `src-tauri/src/updates.rs:171`, `:335`, `:445`, `:536`, `:795` | `updates::Snapshot` (`src-tauri/src/updates.rs:41-62`) | Broadcast | `updates.changed` (60); download progress also `operations.job.progress` with `source: "update"` |
| `silo://macos-computers-changed` | `src-tauri/src/macos_computers.rs:666-668` | macOS snapshot | Broadcast | `computers.changed`, its macOS part (10; 80 §2 N1); row progress also `operations.job.progress` with `source: "macos"` |
| `silo://preparation-status` | `src-tauri/src/preparation.rs:233` | status snapshot | `emit_to("main")` | `preparation.changed` (20), broadcast to subscribers |
| `chatgpt-app-status` | `src-tauri/src/chatgpt_app.rs:1985` | status | Broadcast | `preparation.chatgpt.changed` (20; 80 §2 N5) |
| `silo://pre-upgrade-backup-changed` | `src-tauri/src/pre_upgrade_backup.rs:450`, `:517` | none | Broadcast hint | `migration.preUpgradeBackup.changed` (20; 80 §2 N15); NEW state payload, justified by 95 A-4 |
| `silo://editor-include-changed` | `src-tauri/src/editor.rs:1099` | none | Broadcast hint | `editor.includeNotice.changed` (50); NEW state payload, justified by 95 A-4 |
| `silo://notice` | `src-tauri/src/notifications.rs:126` | `Notice` | Broadcast plus native notification (`src-tauri/src/notifications.rs:124-138`) | `notifications.notice`; engine retains latest per key and posts no OS notification; Fjord presents it (95 A-27) |
| `silo://transfer-progress` | `src-tauri/src/transfer.rs:1398`, `:1449` | `Progress` | Broadcast | `operations.job.progress` with `source: "transfer"` ([§ 4.2 E](#job-contract)) |
| `silo://viewer-drag`, `silo://viewer-drop` | `src-tauri/src/transfer.rs:1288-1300` | bool / selection | `emit_to(shell)` | UI-only, not in API: window drag and drop |
| `silo://desktop-viewer-page` | `src-tauri/src/desktop_viewer.rs:649` | none | `emit_to(shell)` | UI-only, not in API: webview page load |
| `desktop-clipboard` | `src-tauri/src/viewer_clipboard.rs:254` | report | `emit_to(label)` | UI-only, not in API: it reports a transfer that a shortcut in the Tauri shell started (`src-tauri/src/viewer_clipboard.rs:249-256`). In the API the client starts every transfer and gets the `Report` as the result of `clipboard.transfer` (80 §2 N9) |
| `silo://menu-command` | `src-tauri/src/app_menu.rs:497` | command | `emit_to("main")` | UI-only, not in API |
| `desktop:status-opened` | `src-tauri/src/status_panel.rs:68` | none | `emit_to("status")` | UI-only, not in API |
| `desktop:route-requested` | `src-tauri/src/status_panel.rs:160` | none | `emit_to("main")` | UI-only, not in API |
| (none today) remote devices | — | — | Polling: 10 s, 10 s, 2-30 s (§ 4.2 D) | `events.subscribe` as a Stream-class bridge method (NEW); remote owners push state/events (NEW, justified by 95 A-4) |

---

### 9.4 Contract method classifications

| Method | Status and requirement | Existing behaviour reused |
| --- | --- | --- |
| `engine.handshake` | EXTENDED: negotiated protocol/client identity, 95 A-5/A-7 | bridge `handshake`, `remote.rs:237`, `:2242-2247`; §4.1/§4.2 G |
| `engine.state` | EXTENDED: shutdown/update state projections, 95 A-2/A-6 | tauri `read_shutdown_state`, `settings.rs:1043-1046`; §6.1 |
| `events.subscribe`, `events.unsubscribe` | EXTENDED: engine subscription identities, bounded sequenced events and SSH relay, 95 A-3/A-4 | Tauri `listen`/unlisten adapter, `src/desktop/production-source.ts:33`, `:1109-1116`; §4.2 D |
| `engine.disconnect` | NEW, justified by 95 A-2/A-28 | per-window viewer ownership, §6.2 |
| `operations.job.get`, `operations.job.acknowledge` | NEW, justified by 95 §3 Job results | existing domain journals are partial precedents; generic durable outcome storage/acknowledgement is probe B-37 (§4.2 E) |
| `engine.shutdown` | EXTENDED: separate engine shutdown, durable job and saved-generation release, 95 A-2/A-6/§3 | tauri Quit/session-end, `settings.rs:879-1018`; §6 |
| `engine.update.prepare`, `engine.update.abort` | EXTENDED: split engine handoff and saved-memory prepare/rollback, 95 A-6 | tauri `install_update`, `updates.rs:799-844`, and current update journal; §6 |

## 10. Open questions

1. **DECIDED (95 A-1):** Fjord is the user app, Silo maintains and ships the engine, and both installed apps use one engine per channel.
   - Remaining implementation research: bundle registration and installed engine paths; verify forced-command stability in B-22 (80 §4 B). The decision names no exact bundle path.
2. **DECIDED (95 A-1):** Both apps use the same installed engine and Connections owner.
   - PARTLY B-22: after repointing the helper to a copied Silo Dev bundle and relaunching, a pre-installed key completed a v5 handshake. The original-path baseline authenticated but failed with `EINVAL` before any frame. Stable engine/Fjord packaging paths and a successful before/after baseline remain OPEN ([linux.md Connections (run 2) §B-22](probes/linux.md#b-22--forced-command-after-bundle-replacement)); current link source is `src-tauri/src/remote.rs:338-362`.
3. **SETTLED for the tested host (B-1):** dedicated serial-queue VM operations can attach to a main-thread `VZVirtualMachineView` on macOS 26.5 (§3.4; [macos.md §B-1](probes/macos.md#b-1--confirmed)). Other supported OS versions still need implementation qualification.

4. **Host macOS lock screen.** Does a VM keep running, and can one start, while the Mac session is locked after auto-login? This is OS-session qualification, not an input lease; no GUI-driver screen lock exists in the API (95 A-8).
   - `docs/research/macos-remote-display-2026-10-10.md` § C marks it unverified; probe 4 in § Needs a live probe lists it.
   - *Settles it:* that live probe.
5. **PARTLY (B-3):** Aqua/Interactive hosting and regular/Foreground ↔ accessory/UIElement classification are observed (§3.2/§3.6; [macos.md Follow-up §B-3](probes/macos.md#b-3--confirmed-for-app-classification)). Login-window exclusion remains OPEN; no direct Dock/⌘-Tab screenshot was retained.
6. **PARTLY (B-4):** LaunchAgent NAT SSH works; Screen Sharing/5900 worked after guest setup on one boot, then failed an immediate restart check (§3.2; [macos.md Follow-up §B-4](probes/macos.md#b-4--confirmed-on-one-boot)). Repeated boots and macOS 15 Local Network qualification remain OPEN.
7. **SETTLED for the tested configuration (B-5):** LaunchAgent VirtioFS mounted read/write without an observed TCC prompt ([macos.md §B-5](probes/macos.md#b-5--confirmed)); no shared-folder method is selected.

8. **DECIDED (95 A-27):** The engine posts no OS notifications; it keeps the latest notice per key for Fjord to read (60 `notifications.list`).
9. **DECIDED (95 A-22):** The engine returns terminal/editor/browser commands, clients launch them, and `silod` needs no Apple Events entitlement. Today backend terminal launch is `src-tauri/src/remote.rs:816-830`; it becomes client work.
10. **DECIDED (95 A-23, overridden by 95 §3 Linux hosts dropped):** Hosts are Macs only; there is no Linux engine service/linger policy, and B-9/B-26 are closed. Linux computers on Mac hosts remain in scope (§3.7).
11. **DECIDED (95 A-5):** Local authorization uses peer euid matching the engine user; any same-user client may change settings. No code-signature authorization layer is required (§4.2 C).
12. **DECIDED (95 A-4):** Subscriber buffers are bounded; a sequence gap or reconnect requires a domain re-read.
    - Remaining implementation measurement: buffer capacity and slow-subscriber test; the policy is fixed (§4.2 D).
13. **DECIDED (95 A-4):** Remote engines push state/events through a Stream-class bridge subscription, relayed by the controller's local engine (95 A-3).
    - It consumes the existing stream budget of 192 (`src-tauri/src/remote.rs:3380-3382`); qualify budget/backpressure under multiple controllers (§4.2 D).
14. **DECIDED (95 A-7; overridden by 95 §3):** Both sockets use canonical names and common request-id framing; no old one-shot v5 exchange or compatibility decoder is preserved (§4.2 B).
    - Remaining schema research: choose the numeric local protocol version; 95 names no number.
15. **DECIDED (95 A-7; 95 §3):** Generate JSON Schema from the canonical Rust types and Swift `Codable`; the Tauri UI moves to the same schema without old-name adapters (§4.2 H).
    - Remaining research: generator selection and fixture validation.
16. **DECIDED (95 A-5):** Onboarding drafts live in each client; an engine restart has no authority over their storage (§5.3; 60 §2).
17. <a id="oq-17"></a>**DECIDED (95 A-2):** Client Quit offers Cancel / Keep running / Stop and quit; client updates/crashes never stop computers (§6.2).
    - Client Quit uses `computers.list`, explicit `computers.stop`, and `engine.disconnect`. `engine.shutdown.changed` reports engine lifecycle only.
18. <a id="oq-18"></a>**DECIDED (95 A-4):** Events carry new state and sequence numbers, use bounded buffers, and require re-read after gaps/reconnects; remote subscriptions use Stream-class SSH relay (§4.2 D).
    - `deviceIds` selects remote engines through the local engine (95 A-3). Initial subscribe reads current state; 95 does not require an initial pushed snapshot.
19. <a id="oq-19"></a>**DECIDED (95 A-25, overridden by 95 §3 Job results):** Outcomes are saved to disk, survive restart, and are dropped after a client acknowledges showing them (`operations.job.get`/`operations.job.acknowledge`; §4.2 E).
20. <a id="oq-20"></a>**DECIDED (95 A-23, overridden by 95 §3 Linux hosts dropped):** No Debian/AppImage engine update route is specified; existing Linux packages stop receiving engine updates. B-26 is closed; the Mac app/LaunchAgent update saves/resumes both computer kinds (§6).
21. <a id="oq-21"></a>**DECIDED (95 A-25, overridden by 95 §3 Job results):** Completed outcomes survive restart, including a launch migration that restarts the engine; clients read and acknowledge them.
    - macOS create/setup keep the existing `finish_workflow` boundary (`src-tauri/src/macos_computers.rs:374-394`; 30 §3). Remaining launch-migration probe (20 OQ11; 95 §3): terminal-event ordering around today's process restart (`src-tauri/src/runtime_migration.rs:673-684`); persistence is required by 95 §3 Job results and its exact ordering is probe B-37.
22. **DECIDED (95 A-25, overridden by 95 §3 Job results):** Outcomes persist on disk until a client acknowledges showing them; unknown job cancellation still returns `not_found`.
    - Existing domain journals remain source precedents; generic finished outcomes persist, while recovery of unfinished work remains probe B-37 (§4.2 E/F). The old gate-id cancel entry point is retired; clients cancel by `jobId` only (NEW, justified by 95 §3; §4.2 F).
23. **DECIDED (95 A-26):** Engine-owned timers run secret revocation retries, log expiry and port repair without client reads.
    - Preserve hourly log expiry and one-pass-at-a-time guards (`src-tauri/src/runtime.rs:2700-2701`, `:2730-2765`; `src-tauri/src/secrets.rs:753-780`; `src-tauri/src/network.rs:737-750`). Remaining probe: timer intervals and retry recovery with all clients disconnected; no interval is sourced in 95.
24. **Save/resume continuity across an engine update (probe B-30, 95 A-6).**
    - PARTLY: macOS saved clock/process continuity across a killed host process and replacement is confirmed ([macos.md Follow-up §B-30](probes/macos.md#b-30--confirmed-for-saved-guest-state); §6). Existing `save_running` resumes immediately; full update hold/release, journal and failure recovery remain NEW. Linux continuity remains OPEN.
    - Settles it: a disposable one-command probe preserving a running task/counter across save, runtime release, engine binary replacement and memory restore on each platform, plus failure injection before/after journal sync and restore. Qualify memory-save support, host/runtime version compatibility, disk/auxiliary-storage identity, same computer id, saved-state cleanup, and exact release ordering. The API requires save/resume and refuses unsupported preparation; it does not invent these mechanisms.
25. **Durable job registry, acknowledgement and interrupted work (probe B-37, 95 §3 Job results/Queue).**
    - Current remote operation results expire after 1 hour (`src-tauri/src/remote/operations.rs:22-31`); current gate ids use a process-local counter (`src-tauri/src/runtime/operation_gate.rs:249-256`). Neither establishes the required generic persistent job registry.
    - Settles it: a disposable one-command probe with crashes before/after completion save, completion delivery and acknowledgement; verify unacknowledged results survive, acknowledged results stay dropped, ids do not collide after restart, concurrent get/acknowledge is consistent, and local-engine SSH relay targets the owner journal. Separately qualify queue reconstruction and recovery/reconciliation of an interrupted running process. The decision requires durable results, not automatic replay or process survival.
