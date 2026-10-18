# 70. What Fjord needs from the engine

**Host scope (95 §3):** Fjord controllers and Silo engine hosts are Macs only; Linux and macOS **computers** remain supported. Linux-host service, package-update and headless-setup examples are retired, not future engine paths.

Scope: what Fjord (the Swift app in `/Users/polarzero/code/projects/lookout`) needs from the engine beyond what Silo does today. Each need cites the Fjord mechanism that has to work with a computer, or an external source, then names the engine methods that serve it. Where Fjord can do the work itself over a generic method, this section says so and specifies no Fjord-specific method.

## How sources are written here

- **Fjord:** `Sources/Fjord/<File>.swift:<lines>` in the lookout repo (HEAD `87b3623`).
- **Silo:** `src-tauri/src/<file>.rs:<lines>` means `app/SiloUI/src-tauri/src/` in `/Users/polarzero/code/projects/microsandbox-workspaces` (HEAD `94d81937`). Silo docs are `docs/SiloUI-*.md:<lines>`.
- **MicroSandbox:** `msb:<path>:<lines>` means `https://github.com/superradcompany/microsandbox/blob/09df3d4b9d832adaede1fb9a198cfc660bfab8cd/<path>`. That commit is the `sourceCommit` Silo pins for MicroSandbox 0.7.6 (`app/SiloUI/runtime-inputs.json:3-5`). It was read from the local Cargo checkout `~/.cargo/git/checkouts/microsandbox-68382ab00d031574/09df3d4` (its `git log -1` is `09df3d4b9d832adaede1fb9a198cfc660bfab8cd`). Silo's patches on top are in `app/SiloUI/patches/`.
- **External docs** were fetched as Markdown on 2026-10-13 and are cited by URL and section:
  - **[Desktop]** https://code.claude.com/docs/en/desktop
  - **[SSH-3P]** https://claude.com/docs/third-party/claude-desktop/ssh-remote-sessions
  - **[Storage-3P]** https://claude.com/docs/third-party/claude-desktop/data-storage
  - **[Auth]** https://code.claude.com/docs/en/authentication
  - **[Headless]** https://code.claude.com/docs/en/headless
  - **[Messaging]** https://code.claude.com/docs/en/cross-session-messaging
  - **[Network]** https://code.claude.com/docs/en/network-config
  - **[Setup]** https://code.claude.com/docs/en/setup
  - **[DeepLinks]** https://code.claude.com/docs/en/deep-links

[SSH-3P] and [Storage-3P] are written for Claude Desktop on third-party providers. [Desktop] (first party) links to [SSH-3P] only for deployments on a third-party provider ("Read SSH remote sessions in Claude Desktop on 3P before you deploy these keys", [Desktop] § Turn off local sessions and distribute SSH connections). Where a fact below comes only from a 3P page, that is said. Whether all of it also holds for a claude.ai sign-in is an Open question.

## Conventions

- **Addressing.** Every per-computer method below takes `computerId` + `deviceId?` (10's `ComputerRef`, flattened; 80 §2 N16). An absent `deviceId` means this engine.
- **Error codes** are wire `ErrorCode`s, spelled snake_case as the wire does (`bridge_error.rs:4-15`; 80 §2 N17). `not_found` and `cancelled` EXIST. The others this section uses are NEW codes, pending 80 §4 A-10; until then each reaches the client as `internal` with the existing sentence, as every String error does today (`bridge_error.rs:104-108`): `not_running`, `open_ssh_missing`, `include_not_writable`, `account_not_migrated`, `timed_out`, `output_too_large`, `stdin_closed`, `permission_denied`, `not_a_file`, `exists`, `changed`.
- **Jobs** follow the job contract (05 §4.2 E), cancellation (05 §4.2 F) and the event catalogue (05 §4.2 D). This section adds no event outside that catalogue.

---

## 1. Claude desktop app sessions over SSH into a computer

Owner decision (brief): Router "Runs on" means Claude desktop app sessions running inside a computer over SSH, and Fjord writes the SSH connection.

### 1.1 What the Claude app does

**`sshConfigs` (the connection Fjord writes).**
- "Each entry requires `id`, `name`, and `sshHost`. The `sshPort` and `sshIdentityFile` fields are optional. Users can also add `sshConfigs` to their own `~/.claude/settings.json`." ([Desktop] § Pre-configure SSH connections for your team)
- The example entry has exactly `id`, `name`, `sshHost`, `sshPort` and `sshIdentityFile` (same section).
- The **SSH host** field takes "`user@hostname` or a host defined in `~/.ssh/config`", and **SSH key** is optional: "Leave empty to use your SSH config or SSH agent." ([Desktop] § SSH sessions)
- "If you leave `user@` out of `sshHost`, Desktop connects as the `User` that each developer's `~/.ssh/config` sets for the host, or else as their username on their own computer." ([Desktop] § Pre-configure SSH connections for your team)

**System OpenSSH and `~/.ssh/config`.**
- "Claude Desktop connects through the device's OpenSSH client on macOS and Linux … applies the host's entry from the device's `~/.ssh/config`." ([SSH-3P] § How a remote session works, step 1)
- "With the device's OpenSSH client (the default on macOS and Linux), `ssh` reads the entry itself." ([SSH-3P] § SSH configuration on the device)
- The client "must be OpenSSH 7.6 or newer" ([SSH-3P] § Host requirements). This requirement is on the device, not the host. The Mac this was written on runs `OpenSSH_10.2p1` (`ssh -V`, macOS 26.5).
- `ProxyCommand` is supported: "A `ProxyCommand` is permitted when the resolved hostname matches." ([SSH-3P] § Enable SSH remote sessions). The allowlist that sentence refers to (`sshHostAllowlist`) is read "from managed settings only" ([Desktop] § Restrict which SSH hosts users can connect to). A personal Mac without managed settings is not restricted by it on first party.

**Host requirements** ([SSH-3P] § Host requirements):
- "An SSH server with the SFTP subsystem. On Windows, Microsoft's OpenSSH Server; with other SSH servers, the engine does not survive a dropped connection."
- "An SSH server that accepts several sessions on one connection … `MaxSessions 1` in the server's `sshd_config` doesn't work. OpenSSH's default is 10. The server doesn't need to allow TCP, Unix socket, agent, or X11 forwarding."
- "A POSIX shell", "`git` on the path, for git features".
- "A home directory that the SSH user can write to and run programs from, with about 1 GB of disk space … A home directory mounted `noexec` doesn't work."
- On Linux, "glibc 2.17 or later, or musl".
- [Desktop] § SSH sessions: "The remote machine must run Linux or macOS. Desktop installs Claude Code on the remote machine automatically the first time you connect."

**Options forced off.** "With either client, the connection that carries the session leaves these settings off, whatever the entry says" ([SSH-3P] § SSH configuration on the device):
- **Forwarding:** `ForwardAgent`, `ForwardX11`, `Tunnel`, `LocalForward`, `RemoteForward`, `DynamicForward`.
- **Kerberos delegation:** `GSSAPIDelegateCredentials`.
- **Commands:** `RemoteCommand` and `LocalCommand`.

**Where Claude Code runs, and where transcripts live.**
- "Every file read, edit, shell command, and git operation runs on the host, in the working directory the user chose there." ([SSH-3P] § How a remote session works, step 3)
- The host gets `~/.claude/remote/srv/<version>/` (the remote server), `~/.claude/remote/ccd-cli/<version>` (the Claude Code engine, "one file per version"), `~/.claude/remote/run/<id>/`, `~/.claude/remote/plugins/<id>/` ("Plugins synced from the device"), `~/.claude/uploads/<session-id>/`, and "`~/.claude/` and `~/.claude.json` | Claude Code's own data, including session transcripts" ([SSH-3P] § Host requirements, path table).
- "For SSH remote sessions, transcripts are in `~/.claude/projects/` … in the SSH user's home directory on the remote host. Claude Desktop also copies those transcripts to the device, into folders in `~/.claude/projects/` whose names start with `ssh-`" ([Storage-3P] § Removing data).
- On first party: "An SSH session reads `~/.claude/skills/` from the remote host's home directory" and worktrees follow "`worktree.location` in `~/.claude/settings.json` on the remote machine" ([Desktop] § Use skills and § Choose where SSH session worktrees go). So the remote engine reads the host's `~/.claude`.
- The engine survives disconnects: "The engine keeps running on the host through a dropped SSH link, device sleep, or the user quitting Claude Desktop." Reopening "starts a fresh engine from the transcript stored on the host" ([SSH-3P] § How a remote session works).

**Plugin hooks are not copied.** "Plugins from your allowed marketplaces, copied to the host. A plugin's `hooks` directory is not copied, so its hooks do not run in a remote session, and a plugin whose manifest declares hooks elsewhere is not copied at all." ([SSH-3P] § Managed configuration on the remote host)

**The credential travels in the environment.** "A remote session runs Claude Code on the SSH host with your organization's inference credential in its process environment … Anyone who can read that process's environment on the host … can read the credential." And: "The remote engine uses only the credential Claude Desktop passes in its environment." ([SSH-3P] § Inference credentials on the remote host; 3P only.)

**No URL or CLI sends a session's first message.**
- A `claude://code/new?ssh_host=…&ssh_port=…&ssh_folder=…&q=…` link opens the new-session page. "Desktop fills in the prompt when the link opens … and never sends it for you." "A link can't carry a key file, a password, or a command." Desktop asks to confirm the connection first ([Desktop] § Open an SSH session from a link). `ssh_host`'s host part "takes only letters, digits, `.`, `_`, `:`, and `-`".
- `/resume` (picking up a CLI session) "is available in local sessions, not in SSH, WSL, or cloud sessions", and `claude --desktop --resume <id>` opens a CLI session of this machine in Desktop ([Desktop] § Coming from the CLI?).
- [DeepLinks] lists no `claude://resume` link. Fjord's own start relies on `claude://resume?session=<uuid>` (`Sources/Fjord/RouterPrepare.swift:865-869`), which the code calls "The verified way to make a desktop session" (`Sources/Fjord/RouterMCP.swift:1250-1251`). No documented equivalent exists for an SSH session.

**The peer channel stays on one machine.** Cross-session messages go "Over a per-session socket on macOS and Linux" on the same machine. Another machine is reached only "Through Anthropic servers, arriving over that machine's Remote Control connection" ([Messaging] § Message sessions on other machines).

### 1.2 Do Silo's guest SSH paths meet the host requirements?

#### Linux computers: `msb ssh serve --stdio`

Silo's ProxyCommand for a local computer runs `msb ssh serve <name> --stdio --no-start --no-inactivity-timeout` (`src-tauri/src/editor.rs:810-839`). The bridge stream `guest.ssh` spawns the same command on the owner (`src-tauri/src/remote_access.rs:197-224`). The CLI hands one stdio transport to the SDK's server: `server.serve_connection(SshStdioStream::new())` (`msb:crates/cli/lib/commands/ssh.rs:211-226`).

| Requirement | `msb ssh serve` at 0.7.6 + Silo patches | Evidence |
| --- | --- | --- |
| SFTP subsystem | Yes. The server answers `subsystem_request` for `"sftp"` when `settings.sftp` is on (`msb:sdk/rust/lib/sandbox/ssh.rs:1633-1685`), and it is on by default (`sftp: true`, `msb:sdk/rust/lib/sandbox/ssh.rs:969-981`). For a non-root user, Silo's patch runs the guest's OpenSSH `sftp-server` through the same identity-aware exec: `ExecCommand::Command("exec /usr/lib/openssh/sftp-server")` (`app/SiloUI/patches/microsandbox-sftp-user-0.7.6.patch:20-36`). The guest image installs `openssh-sftp-server` (`app/SiloUI/guest-image/Dockerfile:12`, `1:9.6p1-3ubuntu13.19` in `guest-image/image-lock.json:479`), and the build checks it as non-root (`scripts/build-guest-image.mjs:32,60`). | code |
| Several sessions on one connection | Yes. `SshSession` keeps `channels: HashMap<ChannelId, ChannelState>` (`msb:sdk/rust/lib/sandbox/ssh.rs:198-203`). `channel_open_session` inserts each new channel and accepts it (`ssh.rs:1526-1542`). The `russh::server::Config` sets only auth timing, host keys and the inactivity timeout (`ssh.rs:474-480`), so this code has no per-connection session cap. Exec, shell, PTY and env requests are handled per channel (`ssh.rs:1574-1631`). | code |
| No forwarding needed | The server also serves `direct-tcpip` (`ssh.rs:1544-1572`), which Claude doesn't need. | code; [SSH-3P] |
| POSIX shell, git | The image is `ubuntu:24.04` (`guest-image/Dockerfile:2`). "Guest Git/gh/LFS tools are baked into the bundled Ubuntu 24.04 image" (`docs/SiloUI-GITHUB-IMPLEMENTATION.md:51-52`). | code, doc |
| glibc ≥ 2.17 | `libc6` `2.39-0ubuntu8.9` (`guest-image/image-lock.json:121`). | lockfile |
| Writable home | Working account `silo`, UID/GID 1001, home `/home/silo` (`docs/SiloUI-WORKING-ACCOUNT.md:3`). B-13 confirmed executable root-overlay storage (`rw,relatime`, no `noexec`) and 98 GiB available in the probe computer; space is an observed value, not a universal capacity guarantee ([linux.md §B-13](probes/linux.md#b-13--guest-home-mount-and-space)). | doc |
| Survives a dropped connection | B-12 confirmed guest Claude/server and its running sleep survived killing the session ProxyCommand; Desktop reconnected and received `B12_DONE`, exit 0 ([linux.md §B-12](probes/linux.md#b-12--proxycommand-disconnect)). [SSH-3P] says that "with other SSH servers" (than Microsoft's OpenSSH Server, in its Windows sentence) the engine does not survive a drop. `msb ssh serve` is not OpenSSH. On `channel_close`, the server kills the exec's control (`msb:sdk/rust/lib/sandbox/ssh.rs:1762-1767`). agentd starts each exec child in a new session (`setsid`, `msb:crates/agentd/lib/session.rs:986`) and kills by process group (`kill(-pid, …)`, `msb:crates/agentd/lib/process.rs:490-491`). The live result qualifies Claude's behavior on the tested CLI/runtime version; it is not a survival guarantee for arbitrary SSH exec children or engine replacement. | code |
| Never starts a stopped computer | `--no-start` (`editor.rs:836`). "Guest streams cannot start stopped computers." (`docs/SiloUI-CONNECTIONS.md:33`) | code, doc |

#### macOS computers: the guest's own sshd

- Setup turns on "Remote Login" for account `silo` (home `/Users/silo`) (`docs/SiloUI-MACOS-COMPUTERS.md:303-307`). Silo then logs in with `/usr/bin/ssh` (`src-tauri/src/macos_computers/guest_access.rs:25,361-373`). This is Apple's OpenSSH sshd.
- Silo does not edit the guest's `sshd_config`: no file in `src-tauri/src/macos_computers/` mentions `sshd_config`, `MaxSessions` or `Subsystem`.
- macOS ships `Subsystem sftp /usr/libexec/sftp-server` and leaves `#MaxSessions 10` commented out. Evidence: `/etc/ssh/sshd_config:43,117` on this Mac (macOS 26.5). `sshd_config(5)`: "MaxSessions … The default is 10." B-14 inspected the actual macOS guest: effective `subsystem sftp /usr/libexec/sftp-server`, `maxsessions 10`, OpenSSH 10.3p1 and LibreSSL 3.3.6 ([macos.md §B-14](probes/macos.md#b-14--confirmed)).
- The guest's address comes from the host's DHCP leases by MAC address (`guest_access.rs:260-266`). Silo pins the host key under `HostKeyAlias=silo-<id>` with its own `known_hosts` (`guest_access.rs:347-353`). A fixed `HostName` would therefore go stale, which is why the alias below needs a ProxyCommand.
- There is no SSH alias for macOS computers today: "Terminal, editor, Files, network ports, GitHub, secrets, working account | None. These use the Linux guest bridge over SSH, which macOS computers do not have" (`docs/SiloUI-MACOS-COMPUTERS.md:500`).

### 1.3 Engine methods

Fjord does the rest itself:
- writes the `sshConfigs` entry (`id`, `name`, `sshHost` = the alias) into the device's `~/.claude/settings.json`;
- opens `claude://code/new?ssh_host=<alias>&ssh_folder=<path>&q=<task>` for a new session, which the person sends.

#### guest.sshAlias.ensure (use by Fjord; defined in 50)

The one definition, including `GuestSshAlias`, params, errors, Linux handoff checks and the macOS relay, is [50 §guest.sshAlias.ensure](50-access-network-files.md#guestsshaliasensure). Fjord uses its `alias` as `sshConfigs[].sshHost` and its `home` to build guest paths (this section §1.3 and §2). The method is EXTENDED: Linux config generation already exists (`src-tauri/src/editor.rs:409-437`, `:1222-1235`; tauri `computer_action` action=`open-editor`, `src-tauri/src/runtime.rs:3263-3270`); NEW ID-keyed records, Include controls/result and the macOS relay are justified by 95 A-13/A-19 as amended by §3. Re-exposure alone is a rename.

Fjord saves the alias in `~/.claude/settings.json`; Desktop matches saved connections by user, host and port ([Desktop] § Open an SSH session from a link). Today's alias embeds the immutable computer name (`editor.rs:586`; Linux refusal to rename, `runtime.rs:5484-5486`), and storage migration retains earlier aliases (`editor.rs:597-621`). NEW aliases and SSH records are keyed by `computerId`; no old-name compatibility exists. Any conversion is a one-time launch migration via `runtime_migration` (95 §3, overriding A-11/A-13; 50 §guest.sshAlias.ensure).

For macOS, use the engine relay to the current leased address on port 22 instead of a fixed `HostName` (`guest_access.rs:260-266`; 50 §SSH access, guest access and files on macOS computers; 80 §2 N10). B-11 confirms the Linux alias with first-party Desktop; macOS relay/Desktop integration and credential/plugin behavior remain OPEN in OQ1/50 Q4 ([linux.md §B-11](probes/linux.md#b-11--claude-desktop-ssh-alias)).

#### guest.sshAlias.remove (use by Fjord; defined in 50)

The one definition is [50 §guest.sshAlias.remove](50-access-network-files.md#guestsshaliasremove). It removes the generated SSH entry when Fjord removes the matching `sshConfigs` entry (this section §1.3; owner requirement, 00-brief.md §What was decided, Router “Runs on”).

#### guest.ssh (EXISTS, used by the alias for remote computers)
- Kind: stream
- Status: EXTENDED (bridge `guest.ssh`, `src-tauri/src/remote.rs:255,2106-2123`; `remote_access.rs:197-224`). NEW macOS guest SSH adapter, justified by 95 A-19; 50 owns this method.
- Owned by 50 (`guest.*`). Listed here because the remote ProxyCommand depends on it.

The `sshAccess.*` listener (bridge `ssh.access.*`, `remote.rs:250-252`; tauri `read_ssh_access_state`/`save_ssh_access`, `main.rs:190-191`) also exposes a computer's SSH on a TCP port (`docs/SiloUI-MANAGED-SSH.md` § Using access). Fjord doesn't need it, because the ProxyCommand alias needs no listener.

---

## 2. Router internals that assume a local session

Each row: the Fjord mechanism, where it is, and what it needs when the session's Claude Code runs in a guest. Paths in the guest follow from `guest.account` (`home`, `uid`).

| # | Mechanism (Fjord) | Local today | In a guest |
| --- | --- | --- | --- |
| a | **Relay inbox.** `RouterPaths` (`Forms.swift:7-36`) puts everything in `~/Library/Application Support/Fjord`. `RelayInbox.root` is `relay/` beside the presence folder (`ClaudePlugin.swift:1099-1102,1197-1200`). `deliver` writes `<session>/<nonce>.msg` atomically (temp file 0600 in a 0700 folder, then rename), polls `<nonce>.ack` every 30 ms for up to 6 s, then deletes both (`ClaudePlugin.swift:1105,1134-1183`). `sweep` deletes files older than 15 min by mtime (`ClaudePlugin.swift:1186-1195`). Callers: `RouterRun.swift:269-288`, `RouterCancel.swift:31`, `RouterDispatcher.swift:1426`, `RouterWaiting.swift:461`. | Files in the person's Application Support. | The plugin reads the inbox where it runs, which is the guest (it reads `config.json`'s `inboxDir`, `ClaudePlugin.swift:321-327`). Needs atomic write with mode (`guest.files.write`), read (`guest.files.read`), delete (`guest.files.remove`), list with mtime (`guest.files.list`), and a change signal instead of a 30 ms poll across the bridge (`guest.files.watch`). |
| b | **Presence files and pid checks.** The plugin writes `<presenceDir>/<sessionId>` with `pid`, `startedAt`, `keyId`, `renewedAt` and `capabilities` (`ClaudePlugin.swift:341-375`). Fjord counts a file only if the lease is under 30 s, the pid is alive (`kill(pid, 0)`, `Forms.swift:283-286`), and Claude Code's registry still has that pid for that session (`ClaudePlugin.swift:111,123-144`). Polled every 250 ms while a new session's plugin comes up (`RouterMCP.swift:1237-1248`); also `Router.swift:1155-1159`, `ClaudePlugin.swift:1203-1236`. Switching off deletes every presence file (`ClaudePlugin.swift:969-980`). | `kill(pid, 0)` on the host's process table. | The pid is a guest pid, so the check must run in the guest (`guest.exec`, e.g. `kill -0`). Listing and reading the folder use `guest.files.list` / `guest.files.read`; revoking uses `guest.files.remove`. |
| c | **Forms hook.** `FormHookInstaller` writes `~/.claude/hooks/fjord-form.sh` (mode 0755), which runs `exec <Fjord executable> --form-hook` (`Forms.swift:594,616-626,633-668`). It adds a `PermissionRequest` entry to `~/.claude/settings.json` with read, compute, re-read and replace-if-unchanged, 3 attempts (`Forms.swift:746-778`). The hook writes `forms/<key>.json`, polls `<key>.answer.json` every 0.25 s, and gives up when its parent dies (`getppid() != 1`) or the `.enabled` marker goes (`Forms.swift:315-318,330-420`). Fjord watches `forms/` (`FolderWatcher`, `Forms.swift:182-188`), drops forms whose hook pid is dead (`Forms.swift:208-222`), and writes the answer with `RENAME_EXCL`, so a second answer fails (`RouterMCP.swift:1336-1352`). | Hook = Fjord's own macOS binary. | The guest has no Fjord binary: a Linux guest can't run it, and a macOS guest doesn't have it installed. Fjord ships a guest-side hook (Fjord's job) and installs it with `guest.files.write` (mode 0755). The `settings.json` edit needs compare-and-replace (`guest.files.write` `ifSha256`). The answer needs create-only (`guest.files.write` `replace: "never"`). The forms folder needs `guest.files.watch`, the dead-hook check needs `guest.exec`, and cleanup needs `guest.files.remove`. Whether a `PermissionRequest` hook in the guest's `~/.claude/settings.json` runs in a Desktop SSH session is an Open question. |
| d | **Plugin install through the local CLI.** `ClaudePluginInstaller` runs `claude plugin marketplace add/remove`, `plugin install/update/enable/uninstall`, and `plugin list --json`, with the Claude app's bundled binary (`RouterStatus.swift:12-33`) under `/usr/bin/env -i` (`ClaudePlugin.swift:767-926`). The plugin folder holds `hooks/hooks.json` → `register.ts` and a `config.json` of absolute paths: `keyPath`, `presenceDir`, `sessionsDir`, `inboxDir` (`ClaudePlugin.swift:35-57,695-698`). The key is 32 random bytes, mode 0600 (`ClaudePlugin.swift:61-72`). | Local CLI, local paths. | Desktop syncs device plugins to the host but "A plugin's `hooks` directory is not copied" ([SSH-3P]). Fjord's plugin is entirely in `hooks/`, so the device copy does nothing remotely. Fjord installs it in the guest: files and key via `guest.files.write` with guest paths in `config.json`, and the CLI via `guest.exec` running the guest's Claude Code (`~/.claude/remote/ccd-cli/<version>` once Desktop has connected, [SSH-3P] path table; or a native install, `curl -fsSL https://claude.ai/install.sh \| bash` to `~/.local/bin/claude`, [Setup]). Whether a plugin installed in the guest's own user scope loads in a Desktop SSH session is an Open question. |
| e | **Session start and fork.** Bootstrap: `claude -p "/rename <title>" --session-id <uuid> --output-format json --setting-sources ""` in the folder (`RouterPrepare.swift:861-863`; run at `RouterMCP.swift:1252-1275`). Fork: `--resume <id> --fork-session --session-id <uuid> [--resume-session-at <entry>]` (`RouterFork.swift:55-59`). Then `claude://resume?session=<uuid>` (`RouterPrepare.swift:865-869`). Fjord waits for `local_<uuid>` in the registry and the app's session files (`RouterPrepare.swift:897-930`) and checks that the fork's folder exists (`RouterMCP.swift:1305-1309`). | Local `claude -p`, undocumented import link. | The bootstrap can run in the guest (`guest.exec` with `cwd`), and the folder check is `guest.files.list`. But no documented link or CLI imports a CLI session into an SSH session, and the SSH link only pre-fills ([Desktop]). Fjord's fallback is the `claude://code/new?ssh_host=…&q=…` link, which the person sends; an import path is an Open question. |
| f | **Transcript reads.** `Claude.transcriptsDir` = `~/.claude/projects` (`Claude.swift:193-224`). Fjord reads the last 96 KiB for activity (`Claude.tail`, `Claude.swift:225`), whole transcripts for forks (`RouterFork.swift:62-66`), and appended bytes by inode for background tasks (`Claude.swift:398-410`). | Local files. | Desktop copies SSH transcripts to the device under `~/.claude/projects/ssh-…` ([Storage-3P]). Fjord reads/tails the authoritative guest transcript with `guest.files.read` (`offset`/`length`, `inode`) and watches it with `guest.files.watch`. B-16 observed the local copy update about 1.1 s later and remain 1,168 bytes smaller even with a newer mtime; a fresh local timestamp is insufficient ([linux.md Follow-up §B-16](probes/linux.md#b-16-live-transcript-freshness-and-background-task-output)). |
| g | **Background tasks.** `Claude.tasksRoot` = `/private/tmp/claude-<uid>` (`Claude.swift:336-338`); task folders are listed (`Claude.swift:347-370`). Running shell commands are found by checking file descriptor 1 of every process of the user's uid for a path under the tasks root, with `proc_listallpids` / `proc_pidfdinfo` (`Claude.swift:372-389`). | Host process table (macOS APIs). | Must run in the guest: `guest.exec` (Linux `/proc/*/fd`, macOS `lsof`) plus `guest.files.list`. B-16 found output at `/tmp/claude-1001/-home-silo/<sessionId>/tasks/<taskId>.output`, including the sentinel and exit 0; resolve the uid/project/session in the guest rather than hardcoding the probe path ([linux.md Follow-up §B-16](probes/linux.md#b-16-live-transcript-freshness-and-background-task-output)). |
| h | **`~/.claude/sessions` registry.** `ClaudePeers.read` (keyed by `hostSessionId`) and `ClaudePeers.registry` (by pid) read `~/.claude/sessions/<pid>.json` and drop dead pids (`Peers.swift:3-47`). Used at `RouterMCP.swift:635-638,977-1011,1199-1208,1254`, `Router.swift:1117,1157` and `ClaudePlugin.swift:1209,1233`. The plugin reads it too (`sessionsDir`, `ClaudePlugin.swift:341-366`). | Local files plus local pid checks. | `guest.files.list` / `guest.files.read` of the guest's `~/.claude/sessions`, and pid checks via `guest.exec`. B-16 observed guest registry `hostSessionId=local_<uuid>`, `sessionId` and PID, matching Desktop's `local_` metadata. Keep pid/liveness checks guest-side ([linux.md §B-16](probes/linux.md#b-16--transcripts-session-metadata-and-task-folders)). |
| i | **Peer-channel fallback.** When no inbox answers, `RouterSender.send` starts a local `claude` that sends `SendMessage` (`RouterRun.swift:269-300`). | Same-machine sockets ([Messaging]). | Can't reach a guest session without Remote Control ([Messaging]). For guest sessions, the inbox (row a) is the only path. Fjord-side, no engine method. |
| j | **The Claude app's session records.** `Claude.sessionsDir` = `~/Library/Application Support/Claude/claude-code-sessions` (`Claude.swift:72-75`). Fjord keeps only files and ids starting `local_` (`Claude.swift:122-125,166`). | Device files. | These stay on the device. B-16 observed Desktop SSH `local_<uuid>` and the matching guest `hostSessionId`; preserve the distinction from transcript `sessionId` ([linux.md §B-16](probes/linux.md#b-16--transcripts-session-metadata-and-task-folders)). |

### 2.1 Engine methods (generic `guest.*`)

Linux and macOS computers on Mac hosts get the same methods (95 §3). All of them route to the owning device over the Connections bridge, as `files.list`, `guest.prepare` and `guest.ssh` do (`src-tauri/src/remote.rs:253-255`; `remote_access.rs:55-87,197-224`). Bridge frames are capped ("Frames are capped at 4 MiB", `docs/SiloUI-FILES.md:71`), so reads and outputs are chunked.

Nothing below is Claude-specific. Fjord ships a guest-capable hook script and plugin, installs them through `guest.files.*`, and owns presence/inbox/forms logic. Nothing in the guest depends on Fjord's macOS binary (95 A-38; `Forms.swift:616-626` is the host-only behavior being replaced).

**Guest hook evidence (PARTLY B-15).** A minimal guest `PermissionRequest` hook fired for `AskUserQuestion` during a first-party Desktop SSH session, after `SessionStart` by 5.090583211 s and before the UI question. A user-scope plugin validated/loaded in direct guest CLI, but full Fjord plugin callbacks, presence, form delivery and guest-compatible artifact packaging remain OPEN. Use guest settings/artifacts, not host binary paths (95 A-38; [linux.md initial §B-15](probes/linux.md#b-15--guest-permissionrequest-hook-and-user-plugin), [Follow-up §B-15](probes/linux.md#b-15-permissionrequest-in-claude-code-desktop-ssh)).

#### guest.account
- Kind: query
- Platforms: both
- Status: EXTENDED. Existing account inspection is reached by bridge `guest.prepare` (`src-tauri/src/remote.rs:254`; `remote_access.rs:68-87`) and macOS setup/lifecycle (`guest_access::account`, `src-tauri/src/macos_computers/guest_access.rs:77-95`). NEW: report guest uid/home alongside user on both platforms, required by the Fjord callers below (95 A-19). Current macOS `GuestAccount` contains user/password/key, not uid/home (`guest_access.rs:43-47`). Existing sources:
  - Linux: `working_account::inspect_user` (used at `src-tauri/src/remote_access.rs:73`; bridge `guest.prepare` returns `user`, `remote_access.rs:86`);
  - macOS: `guest_access::account` (`src-tauri/src/macos_computers/guest_access.rs:77`).
- Required by:
  - `config.json`'s absolute guest paths (`ClaudePlugin.swift:41-42`);
  - `RouterPaths` (`Forms.swift:7-36`);
  - the hook's location under `claudeDir` (`Forms.swift:594`);
  - the tasks root by uid (`Claude.swift:338`).
- Params: `computerId: string`, `deviceId?: string`
- Result (NEW type `GuestAccount`): `user: string`, `uid: number`, `home: string`. Each field is used by a site above.
- Errors: `not_running`, `account_not_migrated` (older Linux computers need migration before SSH, `docs/SiloUI-MANAGED-SSH.md` § Using access, step 3).

#### guest.exec
- Kind: command (bounded)
- Platforms: both
- Status: EXTENDED. Existing guest execution is used by Tauri `desktop_action` (`src-tauri/src/desktop.rs:950-959`, guest execution `:102-143`) through `runtime::run_msb` (`src-tauri/src/runtime.rs:1082-1108`), and by macOS computer setup through `guest_access::run_capped`/`run_cancellable` (`src-tauri/src/macos_computers/guest_access.rs:454-523`). NEW: general argv/cwd/env/root selection, Linux stdin/cap enforcement, and byte-preserving output/signal fields, required by the Fjord callers below and 95 A-37/A-10/A-19. Exposing the runner alone is extraction. Its flags at 0.7.6 are `--env`, `--workdir`, `--user`, `--tty/--no-tty`, `--no-stdin`, `--timeout`, `--rlimit`, `--quiet` and `--stream` (`msb:crates/cli/lib/commands/exec.rs:21-71`); Silo adds `--no-start` (`docs/SiloUI-FILES.md:36-40`). On macOS the internal equivalent is `guest_access::run`/`run_capped`/`run_cancellable`, as `silo` over SSH with stdin (`guest_access.rs:454-523`).
- This shape is canonical for both platforms (80 §2 N19). 30's macOS `guest.exec` is its macOS part. On macOS the engine quotes `argv` into one command string, because the existing runner sends one string over SSH (`command: &str`, `guest_access.rs:454-545`). 30 and 70 agree the bridge class is `change`.
- Required by, replacing:
  - the plugin CLI calls (`ClaudePlugin.swift:865-926`);
  - pid checks (`Forms.swift:283-286`, used by `ClaudePlugin.swift:139-140` and `Peers.swift:21,41`);
  - background-task detection (`Claude.swift:372-389`);
  - the bootstrap and fork `claude -p` runs (`RouterMCP.swift:1252-1275`);
  - the clone scan and `git` reads (§4).
- Params (NEW type `GuestExecRequest`):
  - `computerId: string`, `deviceId?: string`
  - `argv: string[]`: positional, never put into shell source. Silo already does this for guest scripts (`docs/SiloUI-FILES.md:28-30`).
  - `cwd?: string`: maps to `--workdir`. The bootstrap runs in the project folder (`RouterMCP.swift:1262-1263`).
  - `env?: {name: string, value: string}[]`: maps to `--env`. Fjord's plugin runs set a clean environment (`ClaudePlugin.swift:899-917`).
  - `as?: "account" | "root"`: default `account`. Runs as the working account with `USER`/`LOGNAME` set, as the editor check and the SFTP patch do (`editor.rs:62-74`; `patches/microsandbox-sftp-user-0.7.6.patch:5-12`).
  - `stdin?: bytes`: Fjord's runs take stdin (`OneShot.run(… input:)`, `RouterPrepare.swift:79`). Today Silo forces `--no-stdin` on every non-TTY exec (`runtime.rs:1523-1540`), so this needs that rule lifted for API calls.
  - `timeoutMs: number`: every Fjord run has one deadline (`RouterPrepare.swift:23-25`).
  - `maxOutputBytes?: number`: the current macOS building block caps stdout only (`src-tauri/src/macos_computers/guest_access.rs:467-483`, `:632-634`). The cross-platform API keeps stdout-only overflow as an error and allows a configurable cap (95 A-37); stderr behavior remains today's uncapped drain (`guest_access.rs:633-634`).
- Result (NEW API shape): `exitCode: number | null`, `signal?: string`, `stdout: bytes`, `stderr: bytes`. The existing macOS `CommandOutput` carries `status`, `stdout` and `stderr`, with strings decoded lossily and a signal exit represented as `-1`; a separate `signal` and byte-preserving output require NEW adaptation (`src-tauri/src/macos_computers/guest_access.rs:36-41`, `:661-692`; required by this method's cited Fjord callers). There is no successful `truncated` result; exceeding the stdout cap returns `output_too_large` (95 A-37, A-10; `guest_access.rs:668-692`).
- Errors: `not_running` (never starts it: `--no-start`, `docs/SiloUI-CONNECTIONS.md:33`), `timed_out`, `output_too_large` (`guest_access.rs:33`), `cancelled`.
- Semantics:
  - **Output overflow today (EXISTS, macOS runner):** `run_capped` is documented to stop and fail with "The command in the computer printed too much." (`src-tauri/src/macos_computers/guest_access.rs:32-33`, `:465-483`). Its drain reads at most the stdout limit plus one byte and sets a flag; when the runner observes it, it kills and waits for the host SSH child and returns the error without `CommandOutput` (`:632-640`, `:668-692`). Stderr is drained without a limit (`:633-634`). The proposed `output_too_large` stable code is NEW; today's String error becomes `internal` (`src-tauri/src/bridge_error.rs:104-108`). Linux stdout-cap enforcement is NEW because the sourced `run_msb` path has no equivalent of macOS `run_capped` (Status above).
  - Read-only from the engine's point of view. The command may change the guest, so the engine never replays it on reconnect (bridge "Change" methods are "accepted once per request identity, never replayed", `remote.rs:229-231`).
  - Takes no operation gate, as interactive guest access doesn't (`remote_access.rs:201-203`).

#### guest.exec.start
- Kind: job
- Platforms: both
- Status: EXTENDED. Existing execution runners are the `guest.exec` sources above. NEW: engine-owned long-running jobs, live stdout/stderr/input, bounded replay and durable terminal outcomes until acknowledgement (95 A-2/A-37; 95 §3 Job results). Required by: owner decision (Triage "Run in a computer": unattended headless runs); Fjord's stream-JSON runs (`RouterRun.swift:229-231`; `--output-format stream-json`, [Headless] § Get structured output).
- Params: `GuestExecRequest` without `timeoutMs`/`maxOutputBytes`, plus:
  - `stdinOpen: bool`: keep stdin open for `guest.exec.input`. Fjord's Router process takes `--input-format stream-json` on stdin (`RouterRun.swift:230`).
  - `retainOutputBytes: number`: how much output the engine keeps for `guest.exec.get`.
- Result: `{jobId}` (`job:<n>`, engine-assigned, 05 §4.2 E). `operations.job.finished.result`: `{exitCode, signal?}` (05 §4.2 E item 5).
- Progress/events: no `operations.job.progress` source (it has no byte stream and no `seq` per stream, 05 §4.2 E item 4). Output comes on job-scoped events keyed by the same `jobId`, each with its own `seq` (05 event catalogue):
  - `guest.exec.output {jobId, seq: number, stream: "stdout" | "stderr", data: bytes}`;
  - `guest.exec.exited {jobId, exitCode, signal?}`.
  The engine saves the terminal outcome to disk before `operations.job.finished`; once Fjord shows it, it calls `operations.job.acknowledge` to drop the retained outcome (95 §3; 05 job contract). Running-process and output-ring recovery remain B-37.
- Cancel: `operations.cancel {jobId}` (05 §4.2 F). The cancelled job's `operations.job.finished` carries `error.code: "cancelled"`.
- Errors: as `guest.exec`.
- Semantics:
  - **The engine owns the process.** It keeps running when the client disconnects or chooses Keep running at Fjord quit. The quit dialog offers Cancel / Keep running / Stop and quit (95 A-2). Fjord's own runs are the opposite: Fjord stops them at quit (`PluginRuns.shutdown`, `ClaudePlugin.swift:921-952`; `observePluginQuit`, `Router.swift:1091-1099`). An unattended run must outlive the app that started it (owner decision). Keep running disconnects the client without stopping the computer; Stop and quit explicitly stops it. Updates/crashes of Fjord never stop it (95 A-2; 05 §6).
  - **Cancellation**: 05 §4.2 F routes `operations.cancel` for a `job:` guest exec to the process: SIGTERM, a grace period, then SIGKILL, with the exit confirmed. That is Fjord's own contract for its runs (`RouterPrepare.swift:23-25,75-77`).
  - **Output** is bounded and replayable by `seq`.
  - Takes no operation gate (as `guest.exec`), so it has no gate entry on `operations.queue.changed`.

#### guest.exec.input
- Kind: command
- Platforms: both
- Status: NEW. No existing runner exposes writable stdin for an engine-owned job: bounded macOS `run` accepts one stdin payload (`src-tauri/src/macos_computers/guest_access.rs:454-477`), and Linux non-TTY execution forces `--no-stdin` (`runtime.rs:1523-1540`). Required by 95 A-19/A-37 and: stream-JSON input (`RouterRun.swift:229-231`).
- Params: `jobId: string` (the `job:<n>` from `guest.exec.start`), `data?: bytes`, `close?: bool`
- Result: none.
- Errors: `not_running`, `stdin_closed`.

#### guest.exec.get
- Kind: query
- Platforms: both
- Status: NEW. Current bounded execution runners return only to their caller and have no exec-job registry/output replay (`src-tauri/src/macos_computers/guest_access.rs:454-545`; `src-tauri/src/runtime.rs:1082-1108`). Required by 95 §3 Job results and Triage reattachment. Completed outcomes are saved to disk, survive engine restart, and remain until a client acknowledges showing them with `operations.job.acknowledge` (05 #job-contract).
- Params: `jobId: string` (the `job:<n>` from `guest.exec.start`), `sinceSeq?: number`
- Result: `state: "running" | "exited" | "cancelled" | "lost"`, `exitCode?`, `output: {seq, stream, data}[]`, `firstRetainedSeq: number`.
- It is also the exec job's domain read for a client that missed `operations.job.finished` (05 §4.2 E item 5). A client restart can reattach; a completed outcome is recovered from durable job storage even after engine restart, until acknowledged (95 §3). This does not promise that a running exec process or its output ring survives restart; reconcile process state, job identity and output retention in B-37. `lost` refers to unresolved running-process tracking, not deletion of a completed outcome.

#### guest.files.read
- Kind: query
- Platforms: both
- Status: EXTENDED. Existing Tauri `download_file` reads guest file bytes through SFTP (`src-tauri/src/transfer.rs:1429-1480`). NEW: arbitrary account-readable paths, ranged/chunked byte reads, inode/mode metadata and macOS adaptation, required by the Fjord callers below (95 A-19).
  - `files.list` lists only (`src-tauri/src/files.rs:139-150`).
  - `download_file` copies a file to the device over `sftp`, only under `/workspace` and `~/Downloads`, and only on Linux (`src-tauri/src/transfer.rs:1428-1440`; `docs/SiloUI-FILES.md:54-62,77-80`; `docs/SiloUI-MACOS-COMPUTERS.md:500`).
- Required by:
  - transcripts (`Claude.swift:193-225`, `RouterFork.swift:62-66`);
  - presence (`ClaudePlugin.swift:133-144`);
  - registry (`Peers.swift:13-47`, `RouterMCP.swift:997-1011`);
  - forms (`Forms.swift:208-222`);
  - acks (`ClaudePlugin.swift:1157-1162`);
  - `settings.json` (`Forms.swift:719-744`);
  - the key and its id (`ClaudePlugin.swift:75-82,1037-1043`; the key cache compares inode, mtime and size, `ClaudePlugin.swift:988-1007`);
  - git configs (`CodeFolders.swift:113-135`).
- Params:
  - `computerId: string`, `deviceId?: string`, `path: string` (absolute);
  - `offset?: number`, `length?: number`: tail and appended reads (`Claude.swift:225`, `Claude.swift:398-410`). Bounded by the bridge frame limit (`docs/SiloUI-FILES.md:71`).
- Result: `data: bytes`, `size: number`, `mtimeMs: number`, `inode: number`, `mode: number`.
- Errors: `not_found`, `permission_denied`, `not_a_file`, `not_running`.
- Transcript contract: Fjord uses these guest byte reads for activity, forks and task tracking. The local `ssh-<id>` mirror is not authoritative; it lagged and stayed smaller during/after the observed turn ([linux.md Follow-up §B-16](probes/linux.md#b-16-live-transcript-freshness-and-background-task-output)).

- Semantics: read as the working account.

#### guest.files.write
- Kind: command
- Platforms: both
- Status: EXTENDED. Existing Tauri `upload_files` writes guest files through SFTP (`src-tauri/src/transfer.rs:1371-1427`). NEW: arbitrary account paths, byte payloads, explicit mode, atomic/create-only/hash-conditional writes and macOS adaptation, required by the Fjord callers below (95 A-38/A-19).
- Required by:
  - `PrivateFile.write`/`prepare`+`commit`: temp file at its final mode, then rename (`Forms.swift:49-90`). Used for the inbox (`ClaudePlugin.swift:1143-1152`), presence-adjacent files and the forms marker (`Forms.swift:274-281`).
  - Create-only answers (`RENAME_EXCL`, `RouterMCP.swift:1336-1352`).
  - The `settings.json` compare-and-replace (`Forms.swift:746-778`).
  - The hook script, 0755 (`Forms.swift:637`); plugin files, 0644 (`ClaudePlugin.swift:52-56`); the key, 0600 (`ClaudePlugin.swift:70`).
- Params:
  - `computerId: string`, `deviceId?: string`, `path: string`, `data: bytes`;
  - `mode: number` (octal permission bits);
  - `createParents?: bool`: missing parents are made 0700, as `PrivateFile.prepare` does (`Forms.swift:57`);
  - `replace: "always" | "never" | "ifSha256"`, with `expectedSha256?: string | null` (`null` means the file must not exist).
- Result: `size`, `mtimeMs`, `inode`.
- Errors: `exists` (with `never`; Fjord maps it to `AlreadyAnswered`, `RouterMCP.swift:1350`), `changed` (with `ifSha256`; Fjord retries as `Forms.swift:746-778` does), `permission_denied`, `not_running`.
- Semantics:
  - Atomic: written to a temp file at `mode` in the same folder, then renamed. Never readable by others in between (`Forms.swift:53-78`).
  - Owned by the working account.

#### guest.files.list
- Kind: query
- Platforms: both
- Status: EXTENDED. Existing file listing is the Files-page implementation below. NEW: unrestricted account-readable paths, unpaged programmatic result and macOS adapter, required by the Fjord callers below (95 A-19). Existing sources:
  - tauri `list_computer_directory` (`files.rs:139-150`, registered `main.rs:181`);
  - bridge `files.list` (`remote.rs:253`; `remote_access.rs:50-66`);
  - limited to `/workspace` (`files.rs:67-75`), paged, Linux only (`docs/SiloUI-MACOS-COMPUTERS.md:500`).
  Resolved: both names stay (80 §2 N12). `files.list` is the Files page (roots, paging, transfer limits; 50); `guest.files.list` is programmatic access as the working account, with the semantics below.
- Required by:
  - presence (`ClaudePlugin.swift:133`), registry (`Peers.swift:14,37`), forms (`Forms.swift:209`);
  - inbox sweep by mtime (`ClaudePlugin.swift:1186-1195`);
  - transcripts folders (`Claude.swift:219-221`, `RouterFork.swift:63-64`);
  - task folders (`Claude.swift:347-370`);
  - the app-import check's equivalent (`RouterPrepare.swift:897-905`).
- Params: `computerId: string`, `deviceId?: string`, `path: string`
- Result: `entries: {name: string, type: "file" | "dir" | "link" | "other", size: number, mtimeMs: number}[]`
- Errors: `not_found`, `permission_denied`, `not_running`.
- Semantics: one folder, links not followed (as `files.list`, `docs/SiloUI-FILES.md:32-33`), any path the working account can read.

#### guest.files.remove
- Kind: command
- Platforms: both
- Status: NEW. Existing Files-page methods list/upload/download and expose no account-scoped multi-path guest removal (`src-tauri/src/files.rs:139-197`; `src-tauri/src/transfer.rs:1371-1480`; bridge `METHODS`, `src-tauri/src/remote.rs:237-272`). Required by 95 A-19/A-38 and the Fjord cleanup callers below.
- Required by:
  - form cleanup (`Forms.swift:214-217,389-392`);
  - inbox withdraw (`ClaudePlugin.swift:1156`);
  - revoking presence files (`ClaudePlugin.swift:969-980`);
  - removing the key (`ClaudePlugin.swift:85-87`), the marker (`Forms.swift:277-279`) and the hook (`Forms.swift:670-680`).
- Params: `computerId: string`, `deviceId?: string`, `paths: string[]`
- Result: `removed: string[]`
- Semantics: files only, no recursion. A missing file counts as removed, as Fjord's `try? removeItem` does.

#### guest.files.watch
- Kind: subscription (parameterized: a method that returns a subscription id and delivers through the 05 event envelope, 80 §2 N15)
- Platforms: both
- Status: NEW. Existing file listing is a one-shot/paged query, with no guest filesystem subscription (`src-tauri/src/files.rs:139-197`; bridge `METHODS`, `src-tauri/src/remote.rs:237-272`). Required by 95 A-19/A-38 and the Fjord polls/watchers below.
- Required by:
  - the forms folder watch (`FolderWatcher`, latency 0.1 s, `Forms.swift:182-188`);
  - the polls that would otherwise cross the bridge on every tick: the ack every 30 ms (`ClaudePlugin.swift:1134`), plugin presence every 250 ms (`RouterMCP.swift:1237-1248`), the registry every 250 ms (`RouterPrepare.swift:909-930`).
- Params: `computerId: string`, `deviceId?: string`, `paths: string[]` (folders)
- Result: `subscriptionId`
- Events: `guest.files.changed {subscriptionId, path}`, coalesced, delivered to this subscription only (05 event catalogue).
- Qualified Linux seam (PARTLY B-20): 40 guest-local `IN_CLOSE_WRITE` samples measured median/p95/max 0.135/0.321/0.630 ms versus 29.909/32.291/34.523 ms for 30 ms polling. Use an inotify helper on Linux; measure API/SSH end-to-end latency, rename/coalescing/loss handling and the macOS watch adapter during implementation. These numbers are not subscription latency guarantees ([linux.md §B-20](probes/linux.md#b-20--linux-inotify-against-30-ms-polling)).

- Semantics: a hint only. Fjord re-reads with `guest.files.list`/`read`, as it does locally (`Forms.swift:199-205`). Ends when the computer stops.

---

## 3. Triage unattended runs

**Today.** A Triage action hands an item to a Claude desktop session:
- `InboxActions.perform`, case `.askRouter`, sends the prompt through the Router (`InboxActions.swift:859-874`).
- The dispatcher treats it as unattended (`unattended = job.context.action != nil`, `RouterDispatcher.swift:1053`) and narrows it to the repo's local clones (`RouterDispatcher.swift:1471-1501`).
- It starts a session through `tools.startSession` (`RouterDispatcher.swift:1415`; `RouterMCP.swift:1152-1190`), which is the bootstrap plus `claude://resume` (`RouterPrepare.swift:861-869`).

**In a computer** (owner decision, amended 2026-10-15, see 95 §3 "Triage in a computer"): no headless run. A Triage action whose project lives in a computer goes through the Router like a Mac project's, and the Router starts it with the "Runs on" flow:

1. **Checkpoint first.** Before the session is prepared, Fjord reads `automaticCheckpointRetentionCount` (60 §2.3), skips the checkpoint when it is 0, and otherwise calls `checkpoints.create` with `kind: "automatic"` and `name: "Before run: <task>, deleted automatically"` (20 §1.4), then awaits its job (95 A-18). A failure is shown on the action's run and the session is not started.
2. **Session.** The Router prepares the `claude://code/new?ssh_host=…&ssh_folder=…&q=<prompt>` link, opens it, and records a pending start ("ready in Claude" on the action's chip). The owner presses Send once. Follow-ups reach the session through the guest plugin with no click.

No Triage-specific engine method is needed beyond `checkpoints.create`. `guest.exec.start`, `secrets.save` and the `claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` handling are no longer needed for Triage (B-17 is closed as unneeded). The earlier headless design (`claude -p` through `guest.exec.start`, a long-lived token behind a Silo secret, proof recordings) was removed from Fjord.

---

## 4. Clones inside a computer

**Today.**
- `CodeFolders.scan` walks the code folders 4 levels deep for `.git` (`CodeFolders.swift:11,38-78`). It reads each repo's GitHub remotes from its git config without running `git` (`CodeFolders.swift:8,113-167`).
- `clones(of:)` gives a repo's clones (`CodeFolders.swift:284`; `Store.localClones`, `CodeFolders.swift:386`).
- Users: Triage (`ActionPerformer.clones`, `InboxActions.swift:846-847`; preview, `InboxActions.swift:911-915`), the Router's repo world (`RouterDispatcher.swift:1497-1501`) and the start folder choice (`RouterMCP.swift:1156-1160`).

**In a computer.**
- Repos live in `/workspace` on Linux, owned by the working account (`docs/SiloUI-WORKING-ACCOUNT.md:30-32`), or under `/Users/silo` on macOS (`docs/SiloUI-MACOS-COMPUTERS.md:305`).
- Fjord does the listing itself: either `guest.exec` (a `find … -name .git` walk and `git -C <dir> config --get-regexp '^remote\..*\.url$'`), or `guest.files.list`/`read` reproducing `CodeFolders`' own reads.
- Cloning and fetching are `guest.exec.start` running `git clone https://github.com/<owner>/<repo>` / `git fetch` in the computer.
- **GitHub access.** That needs the computer to have access to the repo. On Linux this EXISTS: "Run standard Git/LFS/gh" with "the exact Authorization placeholder under verified TLS" (`docs/SiloUI-GITHUB-IMPLEMENTATION.md:19,46-48`), set per computer by tauri `save_github_configuration` (`main.rs:206`), API `github.configuration.save`. It is specified in the `github.*` section. On macOS it is "None" (`docs/SiloUI-MACOS-COMPUTERS.md:500`), so the `github.*` section must add it for macOS. Fjord needs from that section a way to grant one repo to one computer before a run.

macOS cloning depends on the NEW developer-tools step in 30: the tested template has no working Git/LFS or Xcode command-line tools, and its public clone attempt failed at the local shim before HTTPS. `/Users/silo` is the account home, not a chosen workspace/Git discovery root; roots remain C-7 ([macos.md Follow-up §B-19](probes/macos.md#b-19--settled-for-template-tooling); 95 A-19; 00 dev-computer requirement).

No clone-specific engine method.

---

## 5. Guest proof recordings

No screen lock or lease method is required (95 A-8; `docs/SiloUI-DESKTOP-VIEWER-DIRECTION.md:11-14`). Fjord starts and stops recording **inside the VM**, using Linux ffmpeg or macOS's built-in screen recorder, then attaches the resulting guest file to the run card. Recording must work without an open VM window (95 A-9).

This is Fjord-side/guest orchestration through `guest.exec.*` and `guest.files.*`, not a new engine capture API (95 A-9; this section §2.1). B-24 qualifies Linux ffmpeg display `:1` capture with Silo's Xauthority and macOS ScreenCaptureKit movie recording/retrieval without a host viewer. The macOS recorder runs as its own guest Aqua LaunchAgent with a Silo-style Screen Recording TCC grant and approval ledger; SSH `screencapture` did not work. Mechanism, finalized artifact facts and remaining recorder lifecycle validation are specified in [40 §5](40-desktop-display-computer-use.md#5-shared-input-and-recordings-as-proof), citing [linux.md §B-24](probes/linux.md#b-24--linux-ffmpeg-screen-capture) and [macos.md Follow-up §B-24](probes/macos.md#b-24-macos--confirmed).

---

## 6. An always-on host and controllers

Required by owner decision: "An always-on host Mac, and controllers on other Macs". Specified in the `connections.*` section. Fjord's side:
- **Every `guest.*` method routes to the owner.** Fjord on a controller calls its own engine, which forwards to the owner as the bridge does for `files.list`, `guest.prepare` and `guest.ssh` (`remote.rs:253-255`). "Silo must remain running on the owner for connections" (`docs/SiloUI-CONNECTIONS.md:26`).
- **The SSH alias for a remote computer** goes through the owner. EXISTS for Linux (`silo --remote-guest`, `editor.rs:841-860`); NEW for macOS (`docs/SiloUI-MACOS-COMPUTERS.md:496,500`). The Claude desktop app then runs on the controller while Claude Code runs in the guest on the host ([SSH-3P] § How a remote session works).
- **Long jobs belong to the owner's engine,** so a Triage run started from a controller keeps going when the controller sleeps (`guest.exec.start` semantics).

---

## Coverage table

The existing commands, bridge methods and internals this section relies on, and the one API method each maps to. Each is owned by the section named. Old bridge names below are current-source evidence mapped to canonical API names. They are not retained on the new wire (95 §3).

| Existing | Where | API method | Owner section |
| --- | --- | --- | --- |
| tauri `computer_action` action=`open-editor` (alias creation inside) | `runtime.rs:3254-3270`; `editor.rs:32-100` | UI-only, not in API: a launcher built on `guest.sshAlias.ensure` (80 §1.2 row 147) | 50 |
| tauri `read_editor_include_notice` | `editor.rs:1111-1127`; `main.rs:244` | `editor.includeNotice` | 50 |
| bridge `guest.prepare` | `remote.rs:254`; `remote_access.rs:68-87` | `guest.prepare` | 50 |
| bridge `guest.ssh` (stream) | `remote.rs:255,2106-2123`; `remote_access.rs:197-224` | `guest.ssh` | 50 |
| bridge `files.list` | `remote.rs:253`; `remote_access.rs:50-66` | `files.list` | 50 |
| tauri `list_computer_directory` | `files.rs:139-150`; `main.rs:181` | `files.list` | 50 |
| bridge `ssh.access.state` | `remote.rs:250` | Existing source mapped to canonical `sshAccess.state` (not used by Fjord) | 50 |
| bridge `ssh.access.connection` | `remote.rs:251` | Existing source mapped to canonical `sshAccess.connection` (not used by Fjord) | 50 |
| bridge `ssh.access.save` | `remote.rs:252` | Existing source mapped to canonical `sshAccess.save` (not used by Fjord) | 50 |
| tauri `read_ssh_access_state` | `main.rs:190` | `sshAccess.state` (not used by Fjord) | 50 |
| tauri `save_ssh_access` | `main.rs:191` | `sshAccess.save` (not used by Fjord) | 50 |
| bridge `checkpoint.create` | `remote.rs:263,1345-1347` | Existing source mapped to canonical `checkpoints.create` | 20 |
| tauri `create_checkpoint` | `runtime/checkpoints.rs:778-782`; `main.rs:278` | `checkpoints.create` | 20 |
| tauri `create_macos_checkpoint` | `macos_computers.rs:850-859`; `main.rs:152` | `checkpoints.create` | 20 (30) |
| tauri `save_secret` | `secrets.rs:797-810`; `main.rs:194` | `secrets.save` | 50 |
| tauri `save_github_configuration` | `main.rs:206` | `github.configuration.save` | 50 |
| internal `runtime::run_msb` exec (not a command) | `runtime.rs:1082-1108,1523-1540` | Not in API (internal function, no command); the engine's basis for the `guest.exec*` methods of §2.1 | 70 |
| internal `guest_access::run*` (macOS, not a command) | `macos_computers/guest_access.rs:454-545` | Not in API (internal function, no command); the engine's basis for the `guest.exec*` methods of §2.1 | 70 |

Notes on the rows:
- `editor.includeNotice` stays its own query; `guest.sshAlias.ensure`'s `includeInstalled` is the same fact for one computer (80 §2 N10).
- `guest.prepare` is the remote step `guest.sshAlias.ensure` uses for a computer on another device (`editor.rs:1222-1235`).
- `files.list` stays the Files page; Fjord uses the separate `guest.files.list` (80 §2 N12).

Events this section adds are all NEW and in the 05 event catalogue: `guest.exec.output`, `guest.exec.exited` (job-scoped, keyed by `jobId`) and `guest.files.changed` (delivered to its `guest.files.watch` subscription). The exec job also ends with `operations.job.finished` (05 §4.2 E). No existing event is in this section's scope.

## Fjord needs → engine methods

One row per engine method; the second column lists every Fjord need it serves.

| Engine method | Fjord need (Fjord file:line) | Status |
| --- | --- | --- |
| `guest.sshAlias.ensure` (owner 50) | SSH connection for a Desktop session in a computer: owner decision; `sshConfigs` per [Desktop] (Fjord writes it, no code yet) | EXTENDED: existing `open-editor` alias generation (`editor.rs:409-437,554-600,841-860,1222-1235`); NEW installInclude option, ID-keyed records and macOS adapter (50) |
| `guest.sshAlias.remove` (defined in 50) | Removing the SSH connection when a computer goes | NEW |
| `guest.ssh` (owner 50) | The ProxyCommand for a computer on another device | EXTENDED: NEW macOS adapter |
| `guest.account` | Guest paths (home, uid, user) for plugin config, hook, tasks root: `ClaudePlugin.swift:41-42`; `Forms.swift:7-36,594`; `Claude.swift:338` | EXTENDED: existing account inspection; NEW uid/home result |
| `guest.exec` | Presence pid checks (`Forms.swift:283-286`); forms dead-hook check (`Forms.swift:208-222`); plugin CLI in the guest (`ClaudePlugin.swift:767-926`); session bootstrap and fork (`RouterPrepare.swift:861-869`; `RouterFork.swift:55-59`; `RouterMCP.swift:1252-1309`); background tasks (`Claude.swift:372-389`); registry pid checks (`Peers.swift:21,41`); clone scan and `git` reads (`CodeFolders.swift:38-167`) | EXTENDED |
| `guest.exec.start` | Triage headless run with streaming (`InboxActions.swift:859-874`; `RouterDispatcher.swift:1053,1415`; `RouterRun.swift:229-231`); clone and fetch in a computer | EXTENDED (`job:<n>`, 05 §4.2 E) |
| `guest.exec.input` | Triage stream-JSON input (`RouterRun.swift:229-231`) | NEW |
| `guest.exec.get` | Triage reattach after a client restart; terminal outcomes survive engine restart until acknowledged (95 §3) | NEW |
| `operations.cancel` (owner 10; contract 05) | Triage cancel, `{jobId}` (`RouterPrepare.swift:23-25,75-77`) | EXTENDED: existing gate cancellation; NEW `{jobId}` routing (05 §4.2 F) |
| `operations.job.acknowledge` (owner 05) | Drop a durable terminal outcome after Fjord has shown the run result (95 §3) | NEW |
| `guest.files.read` | Relay inbox acks (`ClaudePlugin.swift:1157-1162`); presence (`ClaudePlugin.swift:123-144`); forms and `settings.json` (`Forms.swift:208-222,719-744`); registry (`Peers.swift:3-47`; `RouterMCP.swift:635-638,977-1011`); authoritative guest transcripts because the local `ssh-` copies lag ([linux.md Follow-up §B-16](probes/linux.md#b-16-live-transcript-freshness-and-background-task-output)) (`Claude.swift:193-225,398-410`; `RouterFork.swift:62-66`); key (`ClaudePlugin.swift:75-82`); git configs (`CodeFolders.swift:113-135`) | EXTENDED |
| `guest.files.write` | Relay inbox messages (`ClaudePlugin.swift:1143-1152`); forms hook script and `settings.json` entry, answer once (`Forms.swift:594-680,746-778`; `RouterMCP.swift:1336-1352`); plugin files and key in the guest (`ClaudePlugin.swift:35-72,695-698`) | EXTENDED |
| `guest.files.list` | Relay inbox sweep (`ClaudePlugin.swift:1186-1195`); presence (`ClaudePlugin.swift:133`); forms (`Forms.swift:209`); registry (`Peers.swift:14,37`); fork folder check (`RouterMCP.swift:1305-1309`); background-task folders (`Claude.swift:347-370`); transcripts folders (`Claude.swift:219-221`); clones | EXTENDED |
| `guest.files.remove` | Relay inbox withdraw (`ClaudePlugin.swift:1156`); presence revoke (`ClaudePlugin.swift:969-980`); forms cleanup and hook removal (`Forms.swift:214-217,389-392,670-680`) | NEW |
| `guest.files.watch` | Forms folder watch (`Forms.swift:182-188`); the ack, presence and registry polls (`ClaudePlugin.swift:1134`; `RouterMCP.swift:1237-1248`; `RouterPrepare.swift:909-930`) | NEW |
| `checkpoints.create` (owner 20) | Triage: checkpoint before run (owner decision) | EXTENDED: NEW automatic kind/name/retention (95 A-18); existing platform adapters in 20 |
| `secrets.save` (owner 50) | Triage: auth token in the guest ([Auth] § Generate a long-lived token) | EXTENDED: NEW macOS proxy, justified by 95 A-15/A-19, qualification B-27 |
| `github.configuration.save` (owner 50) | Clones in a computer: repo access (`InboxActions.swift:846-847`; `RouterDispatcher.swift:1497-1501`) | EXTENDED: NEW macOS adapter |

Not served by one method:
- **Proof recordings:** guest/Fjord concern; no engine lock or capture method (95 A-8, A-9; §5).
- **Controller ↔ always-on host** (owner decision): every method above takes `deviceId?` and is routed by `connections.*` (60). Bridge routing EXISTS for Linux guest access; NEW for the new methods and macOS. Clients only talk to their local engine, which routes to the owner (95 A-3).

## Open questions

1. **PARTLY B-11:** first-party Desktop honored the Linux Silo Include/ProxyCommand, `IdentityAgent none`, pinned host keys and forced-off forwarding; Desktop overrode alias BatchMode to `no`. `ssh_folder` selected `/home/silo`; `startDirectory` support is not established. First-party credential propagation, copied-plugin hooks/path-table details and macOS Desktop integration remain OPEN ([linux.md §B-11](probes/linux.md#b-11--claude-desktop-ssh-alias); 50 Q4).
2. **SETTLED B-12:** the guest Claude server/engine and running command survived the killed session ProxyCommand; Desktop reconnected and received exit 0. Preserve `msb ssh serve` for this qualified use; arbitrary exec survival and engine updates are separate ([linux.md §B-12](probes/linux.md#b-12--proxycommand-disconnect)).
3. **SETTLED B-13:** `/home/silo` was executable overlay storage with no `noexec` and 98 GiB available on this computer ([linux.md §B-13](probes/linux.md#b-13--guest-home-mount-and-space)).
4. **SETTLED B-14:** effective macOS guest SFTP, MaxSessions 10 and OpenSSH 10.3p1 / LibreSSL 3.3.6 were captured ([macos.md §B-14](probes/macos.md#b-14--confirmed)). Files roots remain C-7.
5. **B-15 hook invocation SETTLED:** a guest PermissionRequest hook ran for AskUserQuestion before Desktop's question, 5.09 s after SessionStart ([linux.md Follow-up §B-15](probes/linux.md#b-15-permissionrequest-in-claude-code-desktop-ssh)). The complete Fjord forms/hook integration remains OPEN.
6. **PARTLY B-15:** the guest user plugin loaded in direct CLI, but Desktop SSH plugin callbacks and Fjord presence/form delivery are OPEN; qualify the guest-compatible artifacts from 95 A-38 ([linux.md initial §B-15](probes/linux.md#b-15--guest-permissionrequest-hook-and-user-plugin)).

7. **Is there a way to import a CLI session into an SSH session, as `claude://resume?session=` does locally (undocumented)?** *Settle:* ask Anthropic, or test `claude://resume` with an SSH connection selected. Without one, a Router start in a computer is a pre-filled `claude://code/new?ssh_host=…&q=…` the person sends. Merged in 80 §4 C-2.
8. **PARTLY B-16, transcript contract settled:** local `ssh-<id>` transcript updates lagged about 1.1 s and remained 1,168 bytes smaller with a newer mtime during/after a turn. Fjord reads/watches the guest transcript through `guest.files.*`. Byte-completeness/reconciliation across more turns remains OPEN; no byte-for-byte comparison was performed ([linux.md Follow-up §B-16](probes/linux.md#b-16-live-transcript-freshness-and-background-task-output)).
9. **B-16 metadata observed:** guest session JSON contained PID, `sessionId` and `hostSessionId=local_<uuid>`, matching Desktop SSH metadata. Keep guest and Desktop identities distinct ([linux.md §B-16](probes/linux.md#b-16--transcripts-session-metadata-and-task-folders)).
10. **B-16 task path observed:** Linux background output lived at `/tmp/claude-1001/-home-silo/<sessionId>/tasks/<taskId>.output`, with sentinel and exit 0. Resolve actual guest uid/project/session rather than hardcoding this fixture path ([linux.md Follow-up §B-16](probes/linux.md#b-16-live-transcript-freshness-and-background-task-output)).
11. **PARTLY B-17:** controlled allowed-host `x-api-key` substitution and non-allowed-host passthrough passed. The request also supplied Authorization, so bearer rewrite was not isolated; actual Claude Code OAuth header/destination behavior remains OPEN ([linux.md Follow-up §B-17](probes/linux.md#b-17-allowed-host-substitution-to-apianthropiccom)).
12. **B-17 exec environment SETTLED:** `msb exec` inherited the token placeholder and existing `NODE_EXTRA_CA_CERTS=/.msb/tls/ca.pem`; no host secret value was exposed ([linux.md §B-17](probes/linux.md#b-17--oauth-placeholder-tls-ca-and-msb-exec)).
13. **DECIDED (95 A-15), PARTLY B-27:** macOS credentials stay on the owner; FileHandle gateway/substitution/revocation/sequential isolation and guest CA trust passed. Default DNS and production lifecycle remain OPEN (50; [proxy.md §Spec impact and remaining seam](probes/proxy.md#spec-impact-and-remaining-seam)).
14. **PARTLY B-20:** Linux local inotify p95 0.321 ms versus 32.291 ms for a 30 ms poll. macOS adapter and end-to-end guest/SSH/API delivery, loss and coalescing remain OPEN ([linux.md §B-20](probes/linux.md#b-20--linux-inotify-against-30-ms-polling)).

15. **DECIDED (95 A-37):** bounded `guest.exec` retains stdout overflow as an error with a configurable cap; long Triage runs use `guest.exec.start`. NEW snake_case error codes are added to `ErrorCode` and fixtures (95 A-10; `guest_access.rs:465-483`, `:632-640`, `:668-692`). B-32 reproduced exact-cap acceptance, overflow and timeout errors; 256 KiB default / 768 KiB maximum stdout and 30 s default / 180 s maximum timeout are inferred candidates, not selected API limits. Workload-based defaults/maxima and stderr/frame bounds remain OPEN ([linux.md §B-32](probes/linux.md#b-32--run_capped-overflow-and-timeout)).
