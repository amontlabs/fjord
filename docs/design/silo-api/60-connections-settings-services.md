# 60 · Connections, settings, system integrations, notifications, updates, app shell, onboarding

Domains: `connections.*`, `settings.*`, `notifications.*`, `updates.*`, plus the classification of system integrations, the app shell and onboarding.

Snapshot: Silo `microsandbox-workspaces` at `94d81937`.

**Host scope, NEW and justified by 95 §3 Linux hosts dropped:** engines and controllers are Macs only, managing both Linux and macOS computers. Existing Linux-host code below is historical evidence, not an API path. No Linux service, Debian/AppImage updater or headless Linux setup remains; B-9/B-26 are closed. Paths below are relative to `app/SiloUI/src-tauri/src/` unless they start with `app/`, `docs/` or `Sources/`. `Sources/…` paths are in the Fjord repo (`/Users/polarzero/code/projects/lookout`, `87b3623`).

Silo's Tauri commands return `Result<T, String>` unless noted. A few return `BridgeError` `{code, message}`, whose `code` is one of `update_in_progress`, `unsupported_remote_operation`, `cancelled`, `already_queued`, `busy`, `not_found`, `incompatible_version` or `internal` (`bridge_error.rs:4-24`). Below, "Errors: text" means the method returns a plain message today.

---

## 1. Connections (`connections.*`)

### 1.1 What Connections is today

- **Purpose:** Silo on one device manages the computers of another device, while Silo runs on that device (`docs/SiloUI-CONNECTIONS.md` § intro, l.3).
  - SSH carries only framed requests to the running owner (`remote.rs:1`).
  - Silo installs no separate management daemon (`docs/SiloUI-CONNECTIONS.md` l.3).
- **Why the engine keeps it:** the owner decision says engines on other devices are reached over SSH, building on this bridge (`00-brief.md` l.13). Fjord wants an always-on host Mac with controllers on other Macs (`00-brief.md` l.25).
- **Roles:**
  - The **owner** serves a private existing Connections Unix socket, `~/.silo/desktop-remote/control.sock` (`remote.rs:2032-2053`). The process that serves it holds the `control.lock` lease (`remote.rs:2015-2031`).
  - The **controller** runs `ssh <address> exec ~/.local/bin/silo-remote --remote-bridge` (`remote.rs:1104-1119`, `channel.rs:93-103`).
  - The bridge mode of the binary (`main.rs:97-112`, `remote.rs:1748-1772`) connects to that socket, relays one frame and relays the reply. It refuses with "Silo is not running on this device." when no owner process serves the socket (`remote.rs:1749-1751`).
- **Where computers run:**
  - Lifecycle, edit and delete run on the owning device (`docs/SiloUI-CONNECTIONS.md` § User behavior, steps 4-5).
  - Terminals and editors launch on the controlling device and reach the guest through the owner (step 6).
  - Files, logs, repository push and network go to the owning device (step 6).
- **Remote computer targets:** `silo-remote:<deviceId>:<computerId>`, both UUIDs (`docs/SiloUI-CONNECTIONS.md` § Implementation boundaries, l.32; parser `remote_access.rs:8-19`; frontend `app/SiloUI/src/features/application/model/connections.ts:10-18`).

### 1.2 State and files

| File | Content | Source |
| --- | --- | --- |
| `~/.silo/desktop-remote/config.json` (dev channel: `~/.silo-dev/…`) | `Config { deviceId: String (UUID), enabled: bool, devices: [Device], …extra preserved }` | `remote.rs:57-66`, `channel.rs:73-81`, `remote.rs:124-136` |
| `~/.silo/desktop-remote/id_ed25519` | this device's Connections key; the private key never leaves the device | `remote.rs:673-678`; `docs/SiloUI-CONNECTIONS.md` step 3 ("No private key is copied") |
| `~/.silo/desktop-remote/control.sock`, `control.lock` | the owner's socket (mode 0600) and its single-owner lease | `remote.rs:2015-2053` |
| `~/.silo/desktop-remote/operations/` | one marker per accepted remote change, kept 1 h | `remote.rs:2264-2266`, `remote/operations.rs:1-9,22-23` |
| `~/.local/bin/silo-remote` (dev: `silo-remote-dev`) | a symlink to the app executable: the forced command of the installed key | `remote.rs:364-405`, `channel.rs:93-103` |

- The directory is private: mode 0700 (`remote.rs:129-136`).
- `config.json` is capped at 1 MiB and written atomically with fsync (`remote.rs:206-224`).
- A damaged file is reported, not replaced (`remote.rs:172-205`).

`Device` (`remote.rs:50-56`; TS `connections.ts:4`):

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string (UUID) | the device identity that device reported in its handshake |
| `name` | string | its host name, from the handshake: non-empty, at most 255 bytes, no control characters (`remote.rs:1414-1420`) |
| `address` | string | what the user typed: an SSH alias, host, `user@host` or `ssh://user@host:port` (`remote.rs:467-510`) |

`ConnectionsStatus` (`remote.rs:66-78`; TS `connections.ts:5`):

| Field | Type | Meaning |
| --- | --- | --- |
| `enabled` | bool | "Allow connections from other devices" |
| `deviceId` | string | this device's UUID |
| `name` | string | `gethostname()` (`remote.rs:285-293`) |
| `address` | string | the first of `addresses`, else `$USER@<name>` (`remote.rs:294-311`) |
| `addresses` | `[{address: string, kind: "name" \| "tailscale" \| "network"}]` | `$USER@<name>.local` and `$USER@<name>` (only `$USER@<name>` when the host name contains a dot), then Tailscale 100.64/10 addresses, then other IPv4 interface addresses; loopback, link-local and unspecified addresses are excluded (`remote.rs:78-123`) |
| `error` | string \| null | why Connections does not work although Silo runs: another instance owns it, a file blocks the bridge link, or the settings file could not be read at start (`remote.rs:310-320,2054-2068`) |

### 1.3 Device identity and address changes

- **Identity:**
  - The UUID is created (v4) the first time the app process reads a missing `config.json`, and saved then (`remote.rs:139-155`).
  - Helper processes never create it. The `--remote-guest` stream helper reads the file and errors when it is missing (`remote.rs:157-171,1818-1827`); the `--remote-bridge` mode reads no config and only connects to the socket (`remote.rs:1748-1750`).
  - It is not `device_identity.rs`, which is the Git/jj author (`device_identity.rs:1-17`) and belongs to another section.
- **Ownership is by UUID, not address:**
  - "Address changes do not change ownership; an address returning a different device identity is rejected until explicitly reconnected" (`docs/SiloUI-CONNECTIONS.md` l.32).
  - Owner side: every request except `handshake` must carry `deviceId` equal to the owner's UUID. Otherwise: "This address now belongs to a different Silo device. Reconnect it explicitly." (`remote.rs:2177-2182`).
  - Controller side: such a refusal counts as **revoked**. Tunnels and viewers for that device close at once (`remote.rs:1513-1525,1563-1577`).
- **Reconnecting at a new address:**
  - `connect_device` with a UUID already saved at another address fails with "<name> is already saved at <old>. Use <new> for it instead only if that device moved to this address." (`remote.rs:1453-1459`).
  - The UI then offers "Use this address", which retries with `replace: true` (`app/SiloUI/src/features/application/components/connections-settings.tsx:42`).
  - On success the entry is replaced (`remote.rs:1461-1463`).
- **Self and cloned identities:**
  - A handshake that returns this device's own UUID is refused (`remote.rs:1443-1451`).
  - If the name also matches, the address points to this device.
  - Otherwise the other device copied this device's settings. The message says which `config.json` to delete there.

### 1.4 SSH setup steps: what needs Terminal and the user

All SSH runs `/usr/bin/ssh`, with the user's own OpenSSH configuration, aliases, keys and agent (`docs/SiloUI-CONNECTIONS.md` step 2).

| Step | Who / where | Interaction | Source |
| --- | --- | --- | --- |
| 1. Turn on Remote Login on the Mac owner; the former Linux-owner SSH-server path is retired (95 §3) | user, in OS settings on the owner | yes; Silo never installs or enables an SSH server | `docs/SiloUI-CONNECTIONS.md` step 1 and l.14 ("automatic SSH-server installation [is] outside this change"); UI hint `connections-settings.tsx:186`; the refused-connection message "Turn on Remote Login (SSH) there." `remote.rs:1026-1027` |
| 2. Turn on Connections on the owner | engine (`connections.setEnabled`) | no | `remote.rs:410-436` |
| 3. Authorize SSH: trust the host key, unlock the user's key into the agent | **Terminal on the controller** | **yes**: fingerprint prompt (`StrictHostKeyChecking=ask`), passphrase (`BatchMode=no`, `AddKeysToAgent=yes`) | `remote.rs:511-544`; UI `connections-settings.tsx:43` |
| 4. Set up Silo's SSH key: append the restricted public key line to the owner account's `~/.ssh/authorized_keys` | **Terminal on the controller** | **yes**: SSH's normal trust and password prompts | `remote.rs:815-859`; `docs/SiloUI-CONNECTIONS.md` step 3; UI `connections-settings.tsx:44` |
| 5. Connect: handshake, save the device | engine (`connections.devices.connect`) | no: `BatchMode=yes`, `StrictHostKeyChecking=yes` | `remote.rs:698-726,1400-1430` |
| 6. Key restriction upgrade | owner, during every handshake | no | `remote.rs:2203-2213,962-969` |

Details that bind the API:

- **Authorize command** (`remote.rs:523-544`):
  - It runs `/usr/bin/ssh -o StrictHostKeyChecking=ask -o BatchMode=no -o AddKeysToAgent=yes -o ConnectTimeout=10 -- <address> true`, shell-quoted.
  - It is opened in the terminal the user chose in Settings (`applications.rs:94-115`, `applications::open_terminal`).
  - The call returns once the terminal is open, not when the user is done. The UI tells the user to "Confirm the device's fingerprint and unlock your SSH key, then connect again" (`connections-settings.tsx:43`).
- **Key setup command** (`remote.rs:832-859`):
  1. Creates `id_ed25519` if needed (`editor::key`, `editor.rs:337`) and derives its public key with `ssh-keygen -y` (`editor.rs:362-366`).
  2. Pipes the line `restrict,command="exec ~/.local/bin/silo-remote --remote-bridge" ssh-ed25519 <blob> Silo remote management` (`remote.rs:25-34,876-883`) into ssh, which runs `INSTALL_PUBLIC_KEY`.
  3. `INSTALL_PUBLIC_KEY` creates `~/.ssh` (0700) and `authorized_keys` (0600), then appends the line only if it is absent. The script is POSIX `sh` in single quotes, so fish, csh and nushell login shells pass it through (`remote.rs:20-24`).
  4. Afterwards the controller offers Silo's key alone first for that address (`remote.rs:823-824`).
- **Key choice and fallback** (`remote.rs:660-752`):
  - Silo first offers only its own key (`IdentitiesOnly=yes`), so a long agent list cannot exhaust `MaxAuthTries`.
  - After an authentication failure it retries once with every key, and remembers which choice worked for that address.
- **What the engine's later connections rely on:** non-interactive SSH with `StrictHostKeyChecking=yes` and the account's normal `known_hosts`/config (`remote.rs:698-726`). Steps 3-4 must therefore run **as the same OS account as the engine**, so the host key and agent they set up are the ones the engine uses. The engine as a LaunchAgent in the user's GUI login session (`00-brief.md` l.9) runs as that account.
- **Failure messages map to the next step** (`remote.rs:1012-1053`):
  - "Host key verification failed. Connect once with SSH in a terminal…" means step 3.
  - `AUTHENTICATION_FAILED` ("Set up Silo's SSH key for this device…") means step 4.
  - "Connection refused" means step 1.
  - "Silo is not running on the other device" means the owner engine is down.
  - "Silo's remote bridge is missing" (exit 127, or "silo-remote: not found") means the `~/.local/bin` link is missing.
  - These are text matches today. The UI shows both buttons on any connect error except "already saved" (`connections-settings.tsx:43-44`).
- **Onboarding** offers only the Authorize action, not key setup, when connecting another device (`app/SiloUI/src/desktop/production-onboarding.tsx:194-205`).

### 1.5 The bridge `handshake`

- **Kind:** bridge read (`remote.rs:236-238`). API name: `engine.handshake`, defined in 05 §4.2 (`00-brief.md` § Shared domains: "`engine.*` (handshake, version, capabilities)"), which adds NEW `protocol`, `client` and `clientId`. This section agrees with 05 (80 §2 N18). It is documented here because it also installs the restricted key.
- **Request:** `{version: 5, method: "handshake", params: {sshKey: string | null}}`. Only the handshake may omit `deviceId` (`remote.rs:1404,2179`). `sshKey` is the controller's public key, or null when it has none (`remote.rs:970-980`).
- **Result:** `{deviceId, name, version: 5, capabilities: [method…]}` (`remote.rs:2238-2246`). `capabilities` lists every `METHODS` entry (`remote.rs:2222-2225`). So today it also advertises `repository.push`, which is no longer served (`remote_access.rs:124-125`; 80 §5 B-6); 05's `engine.handshake` leaves it out.
- **Side effect: restricted key install** (`remote.rs:2203-2213,906-921,885-905`). With `sshKey`, the owner rewrites its own `~/.ssh/authorized_keys`:
  - It rewrites the exact old Silo lines (unrestricted, or `restrict,port-forwarding,permitopen=…`) to `restrict,command="…"`.
  - It leaves other lines untouched.
  - It refuses with a repair error when the file is externally managed (a symlink) but still holds an old line (`remote.rs:906-921,923-941`).
  - "Restrictions affect new authentications" (`docs/SiloUI-CONNECTIONS.md` l.103-107).
- **Version gate** (`remote.rs:2161-2185`; `docs/SiloUI-CONNECTIONS.md` l.103):
  - The protocol version must equal 5 on both sides, or the request fails with `incompatible_version`.
  - The error reply carries `version` and `appVersion` (`remote.rs:564-577`). The controller names which device to update (`remote.rs:1246-1258`).
  - A version mismatch counts as revoked (`remote.rs:1514`).
- **Capability cache:** controllers cache a device's capabilities for 60 s; failures are not cached (`remote.rs:1214-1245`).

### 1.6 Existing bridge transport and the NEW canonical contract

The pinned transport below is source evidence (`docs/SiloUI-CONNECTIONS.md:30`). The NEW contract, justified by 95 A-7 and §3, uses canonical method names and common request-id framing on both sockets: `{id, method, params, …}` replies as `{id, result}` or `{id, error: {code, message}}` (05 §4.2 B). No old-name, one-shot/preamble or legacy error decoder survives. Silo's Tauri UI moves to these names (95 §3). Existing framing, length cap, SSH custody, operation guards and stream budgets remain the sourced seams below.

- **Frame:** a 4-byte big-endian length, then JSON, at most 4 MiB (`remote.rs:37,546-556,649-660`).
  - The reply is preceded by `\0SILO-BRIDGE-REPLY\n`, so text printed by the owner's shell startup files is skipped, up to 64 KiB (`remote.rs:557-561,586-609`).
- **Request envelope:** `{version, deviceId, method, params}`. Changes add `operationId` (UUID) and `startWithinMs` (`remote.rs:1275-1282,1322`).
- **Error reply:** `{error: legacyText, code, message[, version, appVersion]}` (`remote.rs:564-577`).
- **Access classes:** `Read`, `Change`, `Stream` (`remote.rs:225-234`). A method is served only if `METHODS` lists it (`remote.rs:236-273`).
- **Change semantics** (`remote/operations.rs:1-9`, `remote.rs:2247-2284`):
  - Each change is accepted once per `operationId`.
  - It waits in the operation gate, and starts only while the controller's connection is open and before `startWithinMs` runs out.
  - A retry with the same id attaches to the result instead of running the change again. Results stay 1 h in memory, with an on-disk marker per change.
  - The controller retries after a lost connection, after 1 s and then 4 s (`remote.rs:1055,1300-1335`).
- **Deadlines:** 600 s by default; 2100 s for desktop-capable creation, streamer/LCU/computer-use setup and approval; about 122 min for checkpoint create, fork and restore (`remote.rs:981-1010`; `docs/SiloUI-CONNECTIONS.md` § Checkpoint request deadlines).
- **Admission:** at most 64 management connections and 192 streams (`remote.rs:3375-3396`). A change requires Connections on and Silo not shutting down (`remote.rs:2287-2291`).
- **Controller lifetime signal:** the bridge's stdin stays open until the reply. EOF tells the owner to drop work that has not started (`remote.rs:1785-1802`, `remote/operations.rs:6-8`).
- **Health** (`remote.rs:1490-1577`):
  - One failed poll is transient.
  - Three in a row close the device's tunnels and viewers; they reopen when it answers again.
  - A revoked device loses everything.
  - For 20 s after repeated failures, network-state reads answer from the last error (`remote.rs:1547-1560`, used at `remote_network.rs:221-226`); snapshot polls always retry.

### 1.6.1 NEW GitHub callback route (justified by 95 A-17)

For remote or headless-owner GitHub sign-in, the controller opens the authorization URL in its browser. Its local engine carries the loopback callback to the owner over the existing Connections SSH connection (95 A-17, A-3, A-22; canonical `github.connect`/`github.connect.reopen` contract in 50). Preserve the owner OAuth state and callback validation (`github.rs:2474-2514`, `:2589-2618`, `:2664-2680`); do not move token custody to the controller (95 A-14/A-16). The installed management key is restricted to the bridge forced command (`remote.rs:876-883`), so ordinary SSH port forwarding is not an existing capability. `github.connect.callback` is the NEW Stream-class request/response route, bound to the owner connect job (50 §github.connect.callback); qualification and GitHub registration/redirect compatibility remain B-25 (95 A-17; 50 Q1).

### 1.7 Methods

#### connections.status
- Kind: query
- Platforms: macOS hosts only
- Status: EXISTS (renamed): tauri `connections_status`, `remote.rs:328-336`; re-exposes the existing status query as `connections.status`.
- Params: none
- Result: `ConnectionsStatus` (§1.2)
- Errors: text: settings unreadable or damaged (`remote.rs:172-205`)
- Semantics:
  - Reading creates `config.json` with a new UUID if it is missing (`remote.rs:139-155`).
  - The Silo UI polls this together with `device_list` (`app/SiloUI/src/desktop/production-source.ts:919-933`), with a 10 s refresh while visible (`production-source.ts:1125-1132`).
- Sources: `docs/SiloUI-CONNECTIONS.md` step 1

#### connections.setEnabled
- Kind: command
- Status: EXISTS (renamed): tauri `set_connections_enabled`, `remote.rs:410-436`; re-exposes the existing enable/disable behaviour as `connections.setEnabled`.
- Params: `enabled: bool`
- Result: `ConnectionsStatus`
- Errors (text):
  - "~/.local/bin/silo-remote already exists. Choose a different name…" when a foreign file is in the way (`remote.rs:364-405`).
  - "Move Silo to the Applications folder…" when running translocated (`remote.rs:342-363`).
- Semantics:
  - Socket ownership errors ("Another Silo instance owns Connections.") are not returned: they are recorded and appear in the returned status's `error` (`remote.rs:424-433,2015-2050`).
  - Enabling: points `~/.local/bin/silo-remote` at the executable, replacing only a link Silo made (`remote.rs:364-405`); saves the flag; starts serving the socket if not already (`remote.rs:420-433`).
  - Disabling: ends Silo guest sessions and rejects new requests. Accepted changes keep running. The OS account's general SSH access is not revoked (`docs/SiloUI-CONNECTIONS.md` l.26; `remote.rs:2161-2165`).
  - At engine start, when Connections is on, the link is re-pointed every launch; the socket is served whether or not Connections is on (`remote.rs:2054-2068`).
- Sources: `docs/SiloUI-CONNECTIONS.md` step 1, § Connections settings

#### connections.devices.list
- Kind: query
- Status: EXISTS (renamed): tauri `device_list`, `remote.rs:437-444`; re-exposes saved-device listing as `connections.devices.list`.
- Params: none
- Result: `Device[]`
- Errors: text
- Semantics: saved devices only. Reachability comes from `computers.list {deviceId}` (below) and the health record (§1.6).

#### connections.devices.connect
- Kind: command
- Status: EXISTS (renamed): tauri `connect_device`, `remote.rs:1400-1430`; re-exposes the existing handshake, identity validation and saved-address confirmation as `connections.devices.connect`.
- Params:
  - `address: string`: alias, host, `user@host` or `ssh://user@host:port`; IPv6 is allowed (`remote.rs:467-510`)
  - `replace: bool?`: confirm that a known device moved to this address (`remote.rs:1433-1465`)
- Result: `Device`
- Errors: text. `connection_failure` messages (§1.4), version mismatch, "Invalid device identity.", "is already saved at", self or cloned identity (`remote.rs:1442-1457`).
- Semantics: handshake (§1.5), validate the reported id and name, then save. It never takes over another saved entry silently (`remote.rs:1433-1435`).
- Sources: `docs/SiloUI-CONNECTIONS.md` step 2

#### connections.devices.remove
- Kind: command
- Platforms: Mac controllers and owners
- Status: EXTENDED: tauri `remove_device`, `remote.rs:445-466`, already performs local key/device/tunnel/viewer cleanup. NEW owner-side key revocation before local removal is required by 95 A-36.
- Params: `deviceId: string` (existing saved `Device.id`, `remote.rs:50-56`).
- Result: none, after owner key revocation and local removal succeed (95 A-36).
- Progress/events: `connections.devices.changed` after the saved/health state changes (95 A-4; §connections.devices.health).
- Errors: owner connection or key-file rewrite failure; preserve the saved device for retry, following today's local-key failure rule (`remote.rs:451-453`; 95 A-36).
- Semantics: first call `connections.keys.revoke` on the owner through the local engine with this controller's public Connections key; only after acknowledgement forget per-device guest keys, remove the saved entry, clear health and close tunnels/viewers. Local cleanup EXISTS (`remote.rs:445-466`; `ssh_connection.rs:96-111`); owner revocation is NEW (95 A-36). Offline removal cannot report successful revocation. Existing SSH-session invalidation remains probe B-28, rather than a claim that changing `authorized_keys` terminates sessions.
- Sources: 95 A-36; `remote.rs:445-466`, `:673-678`, `:906-959`.

**Observed B-28 limit:** removing the saved offline `devbox` entry left this Mac's synthetic key and a separate authenticated localhost bridge session alive. That was not a session to the removed device and proves no connected-peer revocation. Matching owner-key removal, retry/offline refusal, existing sessions and reconnect races remain OPEN; editing `authorized_keys` must not be claimed to terminate authenticated sessions ([linux.md Connections (run 2) §B-28](probes/linux.md#b-28--controller-removal-key-retention-and-open-session)).

#### connections.keys.revoke
- Kind: command
- Platforms: macOS hosts only; runs on the owner
- Status: NEW: no current command revokes the controller key on the owner. Required by 95 A-36; existing `rewrite_authorized_keys_file`, `remote.rs:928-959`, supplies atomic file rewriting, while today tauri `remove_device`, `remote.rs:445-466`, performs only local cleanup.
- Params (NEW revocation request): `deviceId?: string` routes to the owner (95 A-3); `publicKey: string` identifies the installed controller Connections key, as today's handshake `sshKey` does (`remote.rs:970-980`, `:2203-2213`; 95 A-36).
- Result: none after the matching Silo restricted key is absent (95 A-36).
- Progress/events: none; controller removal publishes device state (§connections.devices.remove).
- Errors: key-file I/O or externally managed-file refusal, based on today's rewrite boundary (`remote.rs:906-959`).
- Semantics: remove the matching Silo management key on the owner, preserving unrelated keys and existing serialized atomic-write semantics (`remote.rs:885-959`; 95 A-36). Repeating revocation of an absent key succeeds. Session invalidation and reconnect races require B-28.
- Sources: 95 A-36; `remote.rs:885-959`, `:970-980`.

#### connections.devices.health
- Kind: query
- Platforms: macOS hosts only; controller's local engine
- Status: EXTENDED: existing health bookkeeping from tauri `device_snapshot`, `remote.rs:1467-1484`, and `poll_succeeded`/`poll_failed`, `remote.rs:1528-1552`. NEW query projection, last-success timestamp and state-bearing sequenced events expose that bookkeeping to clients under 95 A-4; Rust `Health` has no last-success timestamp (`remote.rs:1491-1495`).
- Params: none.
- Result (NEW projection): `devices: [{deviceId: string, connected: bool, busy: bool, error: string | null, lastSeen: string | null}]`; fields follow existing frontend health vocabulary (`app/SiloUI/src/features/application/model/connections.ts:4-6`), keyed by saved `Device.id` (`remote.rs:50-56`). `lastSeen` is the last successful owner observation, null before one; observing `update_in_progress` sets busy without a failed-poll increment (`remote.rs:1478-1484`; 95 A-4).
- Progress/events: `connections.devices.changed` carries the new projection plus sequence number in 05's catalogue (95 A-4).
- Errors: settings read errors (`remote.rs:172-205`).
- Semantics: after an event gap or reconnect, re-read this method; events use bounded subscriber buffers (95 A-4). Preserve transient/repeated/revoked behavior (`remote.rs:1502-1577`). Timestamp projection is NEW, not present in Rust `Health` today (`remote.rs:1491-1495`).
- Sources: 95 A-4; `remote.rs:1478-1577`; `connections.ts:4-6`.

#### computers.list {deviceId} (formerly `connections.devices.snapshot`)
- Kind: query
- Status: EXTENDED, inherited from `computers.list` in 10 §2; this is a cross-reference, not a separate method. Existing remote Linux listing is tauri `device_snapshot`, `remote.rs:1467-1489`, and bridge `runtime.snapshot`, `remote.rs:238`; the combined inventory and durable job contract are defined in 10. Local-engine routing follows 95 A-3.
- Params: `deviceId: string`, `refreshRepositories: bool?`
- Result: the owner's application state, the Linux member of `computers.list`'s result (10 §2; parsed by `parseRemoteApplicationSource`, `production-source.ts:822`).
- Errors: `BridgeError` (§ intro)
- Semantics (the Connections part of `computers.list` with `deviceId`):
  - Each call feeds device health: success clears it; failure goes to `close_after_failed_poll`; `update_in_progress` is not counted (`remote.rs:1478-1484`).

#### Existing authorize_device source

The existing launcher (`remote.rs:511-522`) is source evidence, not a retained compatibility path. Silo’s Tauri UI moves to canonical engine methods (95 §3). Clients obtain `connections.ssh.authorizationCommand` and launch their terminal (95 A-22).

#### connections.ssh.authorizationCommand
- Kind: query
- Status: EXISTS (renamed): tauri `authorize_device`, `remote.rs:511-522`, already builds this command through `authorize_command`, `remote.rs:523-544`. Re-expose command material as `connections.ssh.authorizationCommand`; terminal launch moves to the client under 95 A-22. Required by:
  - The owner decision that Fjord is the frontend and the engine a LaunchAgent, with Mac hosts running the GUI-session engine without a client window (`00-brief.md` l.9-12).
  - Silo's rule that terminals launch on the controlling device (`docs/SiloUI-CONNECTIONS.md` step 6).
  - Today the only path opens a terminal from the engine process and reads the terminal choice from the engine's settings (`remote.rs:511-522`, `applications.rs:94-115`).
- Params: `address: string`
- Result: `{command: string}`: the same shell command line `authorize_command` builds (`remote.rs:523-544`)
- Errors: text: invalid address (`remote.rs:467-510`)
- Semantics: the client runs `command` in an interactive terminal **as the engine's OS account** (§1.4), then calls `connections.devices.connect` again. Nothing on the engine changes.

#### Existing setup_device_key source

The existing launcher (`remote.rs:815-830`) is source evidence, not a retained compatibility path. Silo’s Tauri UI moves to canonical engine methods (95 §3). Clients obtain `connections.ssh.keySetupCommand` and launch their terminal (95 A-22).

#### connections.ssh.keySetupCommand
- Kind: command. It creates the key file if it is missing.
- Status: EXISTS (renamed): tauri `setup_device_key`, `remote.rs:815-830`, already creates the key and builds this command through `key_setup_command`, `remote.rs:832-859`. Re-expose that behaviour as `connections.ssh.keySetupCommand`; terminal launch moves to the client under 95 A-22.
- Params: `address: string`
- Result: `{command: string}`: what `key_setup_command` builds (`remote.rs:832-859`). It contains only the public key line.
- Semantics: preserve key creation and `remember_identity(address, Identity::SiloOnly)` from `setup_device_key`, without opening a terminal (`remote.rs:819-826`). The client runs `command` in an interactive terminal, then connects again.

Owner-side hosting of Connections (serving the socket at start, the lease) is engine lifecycle (`remote.rs:2054-2140`, called from `main.rs:304`). It has no method of its own.

### 1.8 Ownership and remote administration

- **Today, labelled "This device":** backup/restore, account configuration, secrets, runtime repair and application updates are local-only (`docs/SiloUI-CONNECTIONS.md:14`). **NEW remote administration, justified by 95 A-14/A-16:** another Mac can manage everything on the host through its local engine (95 A-3), including GitHub and secrets; secret values travel only over the user's SSH connection. Ownership/storage remain on the target engine; connecting does not copy or sync them (95 A-14/A-16; `docs/SiloUI-CONNECTIONS.md:14`).
- **Out of scope today:** per-computer sharing, migration, internet discovery and automatic SSH server installation (same line).
- **Keys:** per-controller guest private keys stay local; the owner authorizes only public keys. Guest streams cannot start stopped computers (`docs/SiloUI-CONNECTIONS.md` l.33; `remote_access.rs:197-226` uses `--no-start`).
- **Quit:** Today Silo Quit stops only local computers (`docs/SiloUI-CONNECTIONS.md` l.18). The new client asks Cancel / Keep running / Stop and quit; only Stop and quit explicitly stops the selected running computers through their owning engines, then disconnects (95 A-2; §6).
- **Computer use:** a computer's computer-use state is computed by its owner (`docs/SiloUI-CONNECTIONS.md` l.35).
- **ChatGPT app:** Today each device downloads its own ChatGPT for Linux copy, and controllers cannot prepare another device (same line). The new API permits remote administration through the local engine; preparation and downloaded bytes remain owned by the target Mac (95 A-14/A-3; 20 preparation.*).

---

## 1.9 Device facts

### device.facts
- Kind: query
- Platforms: macOS hosts only; local or remote owner
- Status: EXTENDED: tauri `read_application_state` exposes host capacity (`runtime.rs:2664-2706`, `:4780-4785`, `:562-589`, `:1883-1919`); tauri `create_macos_computer` validates against existing host limits (`macos_computers.rs:813-822`, `:991`; `macos_computers/engine.rs:289-307`). NEW Remote Login diagnostics are required by 95 A-35; the consolidated remote-readable facts query follows 95 A-12/A-14. No current implementation checks authoritative Remote Login status.
- Params: `deviceId?: string` routes through the controller's local engine (95 A-3).
- Result (NEW `DeviceFacts`):
  - `deviceCapacity: {logicalCpus: number, physicalMemoryBytes: number, maxMemoryGib: number} | null`, preserving `ApplicationSource.deviceCapacity` fields and unavailable measurement (`runtime.rs:562-589`, `:1883-1941`; 95 A-12).
  - `macosHostLimits: {cpus: number, memory_gib: number} | null`, preserving `HostLimits` field names and existing fallback values (`macos_computers/store.rs:147-160`; `macos_computers/engine.rs:289-307`; 95 A-12). macOS CPU/memory/disk creation bounds remain the existing validation in `store.rs:162-196`; disks remain fixed after creation (95 A-12).
  - `remoteLogin: "enabled" | "disabled" | "unknown"`, NEW diagnostic required by 95 A-35; `unknown` avoids treating a failed diagnostic as disabled. The current bridge only diagnoses connection refusal (`remote.rs:1026-1027`); an authoritative host probe is unsourced and remains C-10.
- Progress/events: none; re-read to refresh facts (95 A-12/A-35).
- Errors: remote transport/authorization errors (§1.6); unreadable diagnostic reports unknown, preserving the absence of an authoritative check in pinned code (95 A-35; C-10).
- Semantics: reads facts from the target host, without enabling its SSH server (`docs/SiloUI-CONNECTIONS.md:14`; 95 A-35). This method is distinct from the existing slow dependency check in 20 `device.dependencies`.
- Sources: 95 A-12/A-35/A-14/A-3; 10 §10; cited code above.

## 2. Settings (`settings.*`)

### 2.1 Document and snapshot

- **File:** `settings.json` in Tauri's `app_config_dir` (`settings.rs:699-701`):
  - production macOS: `~/Library/Application Support/org.silo.preview`;
  - dev: `org.silo.dev`;
  - Linux-host path, RETIRED (95 §3): `$XDG_CONFIG_HOME/…` (`docs/SiloUI-SETTINGS.md` § Saved values, l.310-315).
- **Shape:** `{schemaVersion: 1, settings: {…}, onboardingDraft: …|null}` (`settings.rs:46-52`).
  - `settings` holds explicit changes only. Defaults are applied in TypeScript and never written on mount (`docs/SiloUI-SETTINGS.md` l.266, l.325).
  - Unknown fields survive writes and are hidden from views (`settings.rs:73-77`).
- **Write protection:** an unsupported version, invalid value, invalid draft or unreadable file protects the document from writes for the session. Changes then apply in memory only (`settings.rs:63-96,101-105,183-193`).
- **Limits:** document 1 MiB, draft 256 KiB (`settings.rs:13-14`).
- **Saving:** every change saves at once (`settings.rs:148-180`). A failed save is retried by the next change or flush (`docs/SiloUI-SETTINGS.md` l.367-369).

`Snapshot` (`settings.rs:16-26`; TS `app/SiloUI/src/desktop/settings.ts:8-20`):

| Field | Type | Meaning |
| --- | --- | --- |
| `revision` | u64 | session counter; newer snapshots win (`docs/SiloUI-SETTINGS.md` l.344-347) |
| `settings` | object | validated known fields (§2.3) |
| `onboardingDraft` | object \| null | always null in engine API; drafts belong to clients (NEW, 95 A-5), replacing the main-window exception (`settings.rs:755-760,778-791`) |
| `saveError` | string \| null | the last save failure or protection reason |
| `writeProtected` | bool | the file is protected; changes are for this session only |

### 2.2 Methods

#### settings.read
- Kind: query
- Status: EXTENDED: tauri `read_settings`, `settings.rs:778-791`, already reads the settings snapshot. NEW automatic-checkpoint retention count/off setting is required by 95 A-18; client-owned drafts replace the main-window draft exception under 95 A-5.
- Params: none
- Result: `Snapshot`, with NEW `automaticCheckpointRetentionCount` in settings (§2.3; 95 A-18). `onboardingDraft` is always null in engine reads; drafts stay in each client (95 A-5), replacing today's main-window exception (`settings.rs:780-787`).
- Semantics: waits up to 10 s for initialization (`settings.rs:513-526`).

#### settings.update
- Kind: command
- Status: EXTENDED: tauri `update_settings`, `settings.rs:793-801`, already validates and persists patches. NEW automatic-checkpoint retention count/off validation is required by 95 A-18; peer-euid-authorized clients replace the main-window restriction under 95 A-5.
- Params: `patch: {key: value}`. Every key must be a known field with a valid value, or the whole patch fails with "Invalid settings change" (`settings.rs:111-123,245-283`).
- Result: `Snapshot`
- Events: `settings.changed`
- Semantics:
  - Patches are serialized by one mutex (`docs/SiloUI-SETTINGS.md` l.344).
  - After each change the engine refreshes the computer-use default for new computers (`settings.rs:770`, `computer_use.rs:204-209`) and the native theme (`settings.rs:745-753`).
  - Any local client authenticated as the engine's OS user by peer euid may update settings; remove the main-window restriction (`settings.rs:737-743`; 95 A-5). The automatic-checkpoint count/off setting is validated as a nonnegative integer (95 A-18; §2.3).

#### Client state: onboarding drafts

The old `update_onboarding_draft` command (`settings.rs:803-811`) is not retained as a compatibility path or engine method (95 §3). Each client owns and validates its draft. The engine retains `onboardingComplete` for autostart (95 A-5; `startup.rs:18-26`).

#### Existing import_legacy_theme source

The old command (`settings.rs:813-829`) is not exposed in this API. The Tauri UI moves to canonical settings; any required conversion runs once at engine launch through the existing launch-migration flow (95 §3; 20 migration.*). No legacy-theme compatibility method remains.

#### settings.flush
- Kind: command
- Status: EXISTS (renamed): tauri `flush_settings`, `settings.rs:831-849`; re-exposes the existing save retry and revision bump as `settings.flush`. Its Tauri caller-window gate becomes local engine authorization under 95 A-5.
- Params: none
- Result: none
- Errors: a save error. A write-protected document is not an error (`settings.rs:182-192`).
- Semantics: retries a failed save and bumps `revision`. Engine shutdown and update preparation flush natively (`settings.rs:898-906,2261-2273`; 05 §6). Client Quit flushes its pending changes before `engine.disconnect`; Stop and quit explicitly awaits computer stops (95 A-2).
- Agreement: kept as a method (80 §2 N14). 05 §9.1 now maps `flush_settings` to `settings.flush` too.

#### settings.changed (event)
- Kind: subscription
- Status: EXTENDED: existing event `settings:changed`, `settings.rs:755-760`, already emits the snapshot with a null draft. NEW automatic-checkpoint setting and sequenced bounded delivery follow 95 A-18/A-4; drafts stay client-owned under 95 A-5.
- Payload: `Snapshot` with `onboardingDraft: null`. Drafts stay client-side (95 A-5); NEW settings include the automatic-checkpoint count (95 A-18). Events carry a sequence number with the new state; bounded buffers require re-read after gaps (95 A-4; 05 catalogue).

`initialize_settings` (`settings.rs:720-735`) loads the document, then publishes theme and snapshot. In the engine, settings load at engine start: the lazy path `current_settings` already initializes them (`settings.rs:709-718`). It maps to engine startup, not to a method (coverage table).

### 2.3 Canonical settings fields, classified

"Engine reads" lists the Rust reader. "Engine state" means the engine's behaviour depends on the field. "Per-client" means only a frontend uses it. The canonical settings retain these client preferences; the Tauri UI moves to the new contract (95 §3), while Fjord keeps its own equivalents in `AppSettings` (`Sources/Fjord/Models.swift:78-101`).

| Field | Type (Rust `settings.rs:245-283` / TS `features/preferences/model/settings.ts:4-31`) | Default (TS `settings.ts:38-62`) | Engine reads | Class |
| --- | --- | --- | --- | --- |
| `theme` | `"system" \| "light" \| "dark"` | system | `settings.rs:28-35,745-753`: sets the Tauri app's native appearance | per-client UI |
| `reduceMotion` | bool | false | none (only `settings.rs`) | per-client UI |
| `launchAtLogin` | bool | true | none. A record of the last verified switch action, "not authority" (`docs/SiloUI-SETTINGS.md` l.15-21) | per-client UI; see §3 |
| `startComputersAtLaunch` | bool | false | `startup.rs:18-26,48-58` | **engine state** |
| `startupComputerIds` | string[] (≤256 entries, each ≤256 characters) | `[]` (native default: `dev`, else the first local computer, `startup.rs:60-84`) | `startup.rs:27-36,86-101` | **engine state** |
| `onboardingComplete` | bool | false | `startup.rs:19,53,64`: autostart only after onboarding | **engine state** (also gates the Tauri UI, `app/SiloUI/src/desktop/production-surface.tsx:92`) |
| `computerUseAutoApproval` | bool | false | `computer_use.rs:192-209`: the approval mode of computers created or imported on this device; `remote.rs:1703-1717` applies the controller's setting to a computer it creates on another device. For macOS computers, re-applying on change is "Not done yet" (`docs/SiloUI-MACOS-COMPUTERS.md` l.497) | **engine state** |
| `notificationsEnabled` | bool | true | `notifications.rs:105-117,298-311`: gates system delivery | per-client UI once delivery moves to clients (§4) |
| `notifyFailures` / `notifyChanges` / `notifyCompletions` | bool | true | same | per-client UI (§4) |

| `terminal`, `editor`, `browser` | string ≤256 | Terminal, Visual Studio Code, Safari | `applications.rs:68-77,96-109,122-137` | per-client: apps launch on the controlling device (`docs/SiloUI-CONNECTIONS.md` step 6). Today the engine process launches them; see the editor, terminal and network sections |
| `terminalPath`, `editorPath`, `browserPath` | absolute path ≤4096 \| null | null | same | as above |
| `terminalUseSystemDefault`, `editorUseSystemDefault`, `browserUseSystemDefault` | bool | true | same | as above |
| `computerOrder` | string[] (≤1024 entries, each ≤512 characters) | `[]` | none; "the UI owns the keys" (`settings.rs:276-277`) | per-client UI |
| `alphaNoticeDismissed` | bool | false | none | per-client UI |
| `editorIncludeNoticeDismissed` | string ≤8192 \| null | null | none (`settings.rs:266`) | per-client UI |
| `onboardingDraft` (document level) | object \| null (§7) | null | none outside `settings.rs` | client-owned UI state, not engine API (95 A-5) |
| `automaticCheckpointRetentionCount` (NEW) | nonnegative integer | **3**; **0 disables** automatic pre-run checkpoints | NEW engine retention/pre-run policy in 20 §1.4 | **engine state**, justified by 95 A-18; manual checkpoints are never deleted by this policy |

The old `notifyHealth`/`notifyActions`/`notifyBackup` fallback keys (`notifications.rs:95-117`; `docs/SiloUI-SETTINGS.md:262-264`) are not accepted or read as runtime fallbacks. Any required conversion runs once at launch through `runtime_migration`; no legacy path remains (95 §3).

Settings kept outside `settings.json`:

| Setting | Where | Engine reads | Class |
| --- | --- | --- | --- |
| Connections `enabled`, `deviceId`, `devices` | `desktop-remote/config.json` (§1.2) | `remote.rs` throughout | **engine state** |
| Automatic update checks `automatic_checks` (default true) | `update-preferences.json` in `app_data_dir` (`updates.rs:72-137,230-239`) | `updates.rs:239,423-434` | engine state for engine-version updates only (95 A-6; §5) |

---

## 3. System integrations

The Tauri commands are `read_system_integrations`, `set_login_item`, `request_notification_authorization`, `open_integration_settings` and `show_integration_error` (`system_integrations.rs:59-119`). All five run only from the main window (`system_integrations.rs:47-57,64,76,87,99,111`).

- **`SystemIntegrations`:** `{platform, loginItem: IntegrationStatus, notifications: IntegrationStatus}`, where `IntegrationStatus = {state: string, error: string | null}` (`system_integrations.rs:16-45`; TS `app/SiloUI/src/features/preferences/system-integrations-store.ts:8`, which types `platform` as `"macos" | "linux"`, l.11).
  - macOS login item states: `enabled`, `notRegistered`, `requiresApproval`, `notFound`, `unavailable`, `error` (`system_integrations/macos.rs:46-65,113-115`).
  - Notification states: `notDetermined`, `denied`, `authorized`, `provisional`, `unavailable`, `error` (`system_integrations/macos.rs:72-103`).
- **Login item:**
  - macOS uses `SMAppService.mainAppService()`, the Silo app bundle itself (`system_integrations/macos.rs:113-147`).
  - RETIRED Linux-host source: an XDG autostart entry (`system_integrations/linux.rs:245-275`; `docs/SiloUI-SETTINGS.md` l.37-55; 95 §3).
  - Only an explicit switch action changes OS state (`docs/SiloUI-SETTINGS.md` l.15-21).
- **Notification authorization:** UserNotifications for the app bundle; it prompts only while `notDetermined` (`system_integrations/macos.rs:149-188`). The Linux-host D-Bus path (`docs/SiloUI-SETTINGS.md:78-86`) is historical and retired (95 §3).
- **`open_integration_settings`:** opens the System Settings Login Items or Notifications pane (`system_integrations/macos.rs:321-345`).
- **`show_integration_error`:** a native error dialog parented to the main window (`system_integrations.rs:105-119`).

Classification: **all client-side, not in the API.**

- Each describes the **calling app's** bundle: `mainAppService`, `UNUserNotificationCenter.current`.
- Fjord already has its own: login item `Sources/Fjord/System.swift:319-328`, notification setup and authorization `Sources/Fjord/System.swift:8-31`.
- The Tauri UI moves to the canonical engine methods and owns its own OS integrations, without old-command compatibility paths (95 §3).

`show_integration_error` is also called from engine code paths: startup failures (export/import recovery `startup.rs:164-171`, setup recovery `startup.rs:196-204`, action recovery `startup.rs:219-225`, autostart `startup.rs:258-265`), a failed Quit (`settings.rs:920-935`) and menu open failures (`app_menu.rs:436-444,478-488`). The setup, action and autostart cases also emit a notice (`startup.rs:187-195,210-218,249-257`); the export/import recovery case does not. In the engine those dialogs become the notice stream (§4) or the error of the method concerned. The engine opens no dialogs.

**What the engine itself needs:**

- **macOS:** the engine's own launch at login is its LaunchAgent in the user's GUI login session (`00-brief.md` l.9). That is not the client's `launchAtLogin`.
  - Apple's `SMAppService.agent(plistName:)` registers a LaunchAgent shipped in an app bundle (https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)). Packaging registration details remain B-22; product ownership and one engine are decided by 95 A-1.
- **Linux hosts retired:** no systemd/XDG autostart engine contract or Linux service remains. The earlier A-23 default is overridden by 95 §3; B-9 and B-26 are closed. Linux computers still run on Mac hosts.
- **Why it matters:** Connections need Silo running on the owner (`docs/SiloUI-CONNECTIONS.md` l.26), and the bridge fails with "Silo is not running on this device." otherwise (`remote.rs:1749-1751`). So the always-on host (`00-brief.md` l.25) depends on engine autostart.

---

## 4. Notifications (`notifications.*`)

### 4.1 Today

`notifications.rs` is the single router (`notifications.rs:1-14`; `docs/SiloUI-NOTIFICATIONS.md`). It has three ownership paths (`docs/SiloUI-NOTIFICATIONS.md` § Ownership):

| Owner | Results | Path |
| --- | --- | --- |
| Frontend | results of commands it awaited: push, GitHub apply, ports, checkpoints, storage reclaim, log export | the frontend toasts, then mirrors to the system via `deliver_notice` (`notifications.rs:315-319`) |
| Engine, the UI already shows the state | lifecycle (local and remote), export and import, computer setup and configuration, Git identity | `notify_native`: system notification only (`notifications.rs:130-139`) |
| Engine, no other UI owner | unexpected computer changes, startup and update-resume failures | `notify`: emits `silo://notice` and the system notification (`notifications.rs:123-128`) |

`Notice` (`notifications.rs:55-65`; TS `app/SiloUI/src/desktop/notices.ts:10-16`):

| Field | Type | Meaning |
| --- | --- | --- |
| `category` | `"failures" \| "changes" \| "completions"` | see below (`notifications.rs:30-39`) |
| `key` | string | stable identity; a newer notice with the same key replaces the older one |
| `title` | string | names the computer ("Couldn't start dev", "dev is running") |
| `body` | string | one line, at most 200 characters, ellipsized (`notifications.rs:327-339`) |
| `computer` | `{id, name}` \| null | `id` is qualified as `silo-remote:<device>:<computer>` when remote (`notifications.rs:46-53`, `remote.rs:1634-1644`) |

- **Categories:**
  - `failures`: something the user started, or background work, failed.
  - `changes`: a computer changed state without a Silo operation causing it (`health_watch.rs:1-6`).
  - `completions`: work that took at least `LONG_OPERATION` succeeded.
- **3 s threshold:** `LONG_OPERATION = 3 s`, measured from the command start (`notifications.rs:41-44`; `docs/SiloUI-NOTIFICATIONS.md` § Policy). It matches the frontend's `LONG_OPERATION_MS = 3000` (`app/SiloUI/src/lib/operation-toast.ts:111`).
  - Failures always notify.
  - User cancellations and `already_queued` never notify (`notifications.rs:341-393`).
- **Replacement by key (today):** on macOS the key is the request identifier; the retired Linux-host path uses `replaces_id` (95 §3) (`docs/SiloUI-NOTIFICATIONS.md` § Policy; `system_integrations/macos.rs:272-307`).
  - OS calls for one key are serialized by a gate with revisions; superseded deliveries are skipped (`notifications.rs:141-266`).
- **Keys in use:**
  - `computer:{id}:lifecycle` and `lifecycle:{name}` (`notifications.rs:371-374`)
  - `computer:{id}:transfer` and `transfer` (`notifications.rs:409-412`)
  - `computer:{id}:health`, `health`, `health:runtime` (`health_watch.rs:131,187,200`)
  - `startup:setup`, `startup:actions`, `startup:launch` (`startup.rs:190,213,252`)
  - `startup:editor-connections` (`editor.rs:1172,1212`)
  - `update:resume` (`updates.rs:191-206`)
  - `git-identity` (`runtime.rs:2180`)
  - `computer-setup` (`runtime.rs:4313`)
- **UI-bound policy:**
  - Focus: no system notification while the main window is visible and focused (`notifications.rs:291-311`).
  - Category preferences (`notifications.rs:105-117`).
  - OS authorization (`system_integrations/macos.rs:275-277`).
  - Click route `{"tab":"computers","computer":id}` (`notifications.rs:77-86`).
  - Thread grouping (`notifications.rs:88-94`).
- **Clearing:** deleting a computer, locally (`runtime.rs:4370`) or remotely (`remote.rs:1741-1744`), withdraws its queued and delivered notifications (`notifications.rs:281-289`; `docs/SiloUI-NOTIFICATIONS.md` § Policy, l.43-47).

### 4.2 Engine shape: retained notices that Fjord renders

Required by: Fjord renders its own notifications from its own model and settings:
- `Notifier` (`Sources/Fjord/System.swift:8-73`)
- posting gated on Fjord's window, `settings.notifications` and snooze (`Sources/Fjord/RouterKeys.swift:165-178`)
- the `notifications` setting (`Sources/Fjord/Models.swift:84`)

Fjord also has a card model for the Router and Triage (`RouterCard`, `Sources/Fjord/Router.swift:203`; Triage's `Thing`, `Sources/Fjord/InboxModel.swift:533`). Every piece of policy in §4.1 that depends on a window, OS authorization or a client preference therefore moves to the client. The engine retains and emits notices; only Fjord presents them, and the engine posts no OS notifications (95 A-27).

#### notifications.notice (event)
- Kind: subscription
- Status: EXTENDED: existing event `silo://notice`, `notifications.rs:27-28,123-128`. NEW (95 A-27/A-4): retained latest-per-key notices and sequenced bounded delivery replace engine OS delivery; notices from the `notify_native` path are emitted too. Today they reach only the OS (`notifications.rs:130-139`), so a client with no Silo React state layer would never see lifecycle, export/import, setup or Git-identity results. Required by Fjord rendering cards (above).
- Payload: `Notice` (§4.1) in the sequenced event envelope (95 A-4). Fjord renders notices from both existing engine paths; no presentation field or legacy Tauri toast-routing contract is needed (95 A-27, §3).
- Semantics:
  - The engine applies no focus, category or authorization filter. Fjord applies its notification preferences and focus rule. The engine and other clients do not present engine notices (95 A-27).
  - The key replaces earlier notices with the same key. Clients must replace, not stack.
  - The engine owns the 3 s rule for engine-produced completions (`notifications.rs:358-393,396-434`).
  - Keep the latest `Notice` for each `key`, including startup/editor/update-resume notices produced before clients connect. Fjord reads `notifications.list` when it opens and after event gaps; engine OS delivery is removed (95 A-27, A-4).

#### notifications.cleared (event)
- Kind: subscription
- Status: NEW (justified by 95 A-27). Required by the deletion-withdrawal behaviour (`docs/SiloUI-NOTIFICATIONS.md` § Policy, l.43-47; `remote.rs:1741-1744`, `runtime.rs:4370`). Fjord withdraws its system presentations (95 A-27), and the engine no longer holds the OS notifications.
- Payload: `{computerId: string}`, the same id form as `Notice.computer.id`
- Semantics: remove the deleted computer's retained keys and emit after local/remote deletion succeeds; Fjord withdraws its presentations (95 A-27; `notifications.rs:281-289`).

#### notifications.list
- Kind: query
- Platforms: macOS hosts only; optional remote owner via local engine
- Status: NEW: no current query retains and returns the latest complete notice per key. Required by 95 A-27; today's `Notice` is `notifications.rs:55-65`, while `Delivered` tracks OS-delivery keys/revisions (`notifications.rs:141-266`) rather than this client-readable notice registry.
- Params: `deviceId?: string` (remote route through the local engine, 95 A-3).
- Result: `Notice[]` (§4.1), the latest retained notice for each key (95 A-27).
- Progress/events: `notifications.notice` updates a key; `notifications.cleared` removes a computer's keys (§4.2).
- Errors: Connections errors when remote (§1.6).
- Semantics: reading does not acknowledge or clear notices. Fjord reads when opening and after a gap/reconnect (95 A-27, A-4). No engine OS notifications. Persistence across engine restarts and any cardinality/expiry policy remain probe B-29; A-27 does not specify them.
- Sources: 95 A-27, A-3, A-4; `notifications.rs:55-65`, `:141-289`.

`deliver_notice` and `clear_computer_notices` (`notifications.rs:315-324`) are calls from a client to its own OS integration: the frontend mirrors a toast it already shows. They are **client-side, not in the API**. No old-command compatibility path is retained; the Tauri UI moves to the canonical contract (95 §3). Frontend-owned results (push, GitHub apply, ports, checkpoints, storage reclaim, log export) stay client-produced from command results. Clients apply the same 3 s threshold (`app/SiloUI/src/lib/operation-toast.ts:111,150`; the frontend counts a success as long only above 3 s, the engine at 3 s or more, `notifications.rs:384,419`).

---

## 5. Updates (`updates.*`)

### 5.1 Today

- **Engine:** the Tauri updater with a signed feed (`updates.rs:1`).
- **Package kind:** macOS only for the new engine contract (95 §3). Current `macos` app-archive behavior is the seam (`updates.rs:138-162`). Existing `appimage`/`debian`/Linux `manual` paths and `/usr/lib/silo/silo-system-update` (`updates/debian.rs:14`; `docs/SiloUI-RELEASES.md` § Versioned distribution and updates) are retired source evidence; Silo Linux packages receive no further engine updates (95 §3).
- **Development channel:** never checks (`updates.rs:238-239,408-415`).
- **Release page:** `RELEASE_URL = https://github.com/amontlabs/silo/releases/latest` (`updates.rs:39`).
- **Download limit:** 2 GiB; the unpacked size is checked against free space before install (`updates.rs:40,571-652`).

`UpdateSnapshot` (Rust `Snapshot`, `updates.rs:41-61`):

| Field | Type | Meaning |
| --- | --- | --- |
| `phase` | `idle \| checking \| available \| downloading \| ready \| installing \| error` | `updates.rs:176,207-209,399,442,530,560,791` |
| `lastChecked` | RFC 3339 string \| null | `updates.rs:459-461` |
| `retryAction` | `check \| download \| install` \| null; `relaunch` is accepted (read at `updates.rs:383`; TS `app/SiloUI/src/features/updates/update-store.tsx:7`) but no Rust path sets it | `updates.rs:179-188,490` |
| `currentVersion` / `availableVersion` | string / string \| null | |
| `releaseNotes` | string \| null | |
| `downloadedBytes` / `totalBytes` | u64 / u64 \| null | progress, reported at most every 100 ms (`updates.rs:545-551`) |
| `automaticChecks` | bool | persisted in `update-preferences.json` (`updates.rs:104-137,235`) |
| `packageKind` | `"macos"` in the NEW engine contract (95 §3); old Linux values are retired | `updates.rs:138-162` is current source evidence |
| `releaseUrl` | string | |
| `error` / `errorDetails` | string \| null | |
| `runningComputers` | string[] | the local running computers the engine update will save and resume (NEW semantics, 95 A-6), replacing today's stop set (`updates.rs:306-317`) |
| `canInstall` / `installBlockReason` | bool / string \| null | readiness: operations idle, no backup, not shutting down (`updates.rs:210-229`) |


- **Automatic checks:** polled every 5 s, due once a day, with failure backoff (`updates/schedule.rs:3-4,34-47`).
- **Focus:** main-window focus brings a check forward when the last one was at least 60 s ago and there were no failures (`main.rs:321-323`, `updates.rs:283-291`, `updates/schedule.rs:25-32`).
- **Background checks** never replace verified bytes, a pending retry or an installed update awaiting relaunch (`updates.rs:374-384`).

The old `installStatus` Debian helper field (`updates.rs:713`) is not in the new `UpdateSnapshot` (95 §3).

### 5.2 Methods

These methods concern the engine's version and update package, separate from Fjord app updates (NEW, justified by 95 A-6). The current app updater is the code seam below; feed/package identity remains C-9.

#### updates.state
- Kind: query
- Status: EXTENDED: tauri `get_update_state`, `updates.rs:292-322`, already reads updater state and readiness. NEW engine-package/version identity and save/resume readiness replace app-package and macOS-running refusals under 95 A-6; feed identity remains C-9.
- Result: `UpdateSnapshot`, applied to the separate engine package (95 A-6). Preserve the readiness/running-set refresh from `get_update_state` (`updates.rs:292-322`); NEW save/resume readiness replaces its running-macOS refusal (§engine handoff; 05 §6).

#### updates.check
- Kind: command
- Status: EXTENDED: tauri `check_for_update`, `updates.rs:370-373,407-494`, already checks the signed update feed. NEW engine-package/version targeting separates engine releases from Fjord app releases under 95 A-6; feed identity remains C-9.
- Result: `UpdateSnapshot`
- Errors: "An update operation is already running." A failed check sets `phase: error` and `retryAction: check`, except that an already found or downloaded update stays `available`/`ready` (`updates.rs:471-491`; messages `updates.rs:496-511`).
- Events: `updates.changed`

#### updates.download
- Kind: job (05 §4.2 E)
- Status: EXTENDED: tauri `download_update`, `updates.rs:512-563`, already downloads and verifies signed bytes with progress. NEW engine-package targeting is required by 95 A-6; durable job outcomes retained until acknowledgement are required by 95 §3 Job results.
- Params: none
- Result: `{jobId}` (`job:<n>`, 05 §4.2 E); `operations.job.finished.result`: `UpdateSnapshot`, as `download_update` returns today.
- Progress/events: `operations.job.progress` with `source: "update"` and `data` = `updates::Snapshot` (`downloadedBytes`, `totalBytes`); `updates.changed`.
- Cancel: none. Update downloads are `NotCancellable` (05 §4.2 F; no cancel exists, `updates.rs:513-536`).
- Errors: "An update operation is already running." (`updates.rs:520-522`); old Linux `manual`/`debian` paths are retired (95 §3); "Check for an update before downloading."
- Semantics: signature-verified bytes are kept in memory until install (`updates.rs:555-560`). Today no outcome remains after return; NEW outcomes are saved to disk and survive engine restart until a client acknowledges showing them with `operations.job.acknowledge` (95 §3; 05 job contract). This does not promise persistence of downloaded package bytes; B-37 distinguishes payload/outcome storage from restartable downloads.

#### Existing install_update source and NEW engine handoff

`install_update` (`updates.rs:761-865`) maps to `engine.update.prepare` → `engine.shutdown {reason: "update", stopComputers: false}` → installer → engine restart/resume, with `engine.update.abort` on failure (05 §6). There is no separate `updates.install` API method. The engine is replaced only when its engine version changes; a Fjord update or crash never stops computers (95 A-6, A-2). Mac package-installer ownership and stable helper paths remain B-22/C-9, not open owner choices.

NEW handoff semantics, justified by 95 A-6: admission/operation guards, settings flush and transfer closure build on `updates.rs:806-834`; the running set is journaled before saving (`runtime/update_recovery.rs:214-230`). Save each running VM's memory state and disk, replace/restart the engine, then restore and resume exactly that set. macOS uses `saveMachineState`; Linux uses the existing snapshot or `--cow-mem` restore seam cited in 05 §6. Today's stop/cold-start recovery (`runtime/update_recovery.rs:232-310`) is not proof of memory continuity. Save/hold, compatible restore and failure recovery require 05's B-30 probe. `UpdateSnapshot.runningComputers` names the computers to save/resume, not consent to stop them (95 A-6).

**B-22 packaging evidence:** the same installed forced-command key worked after moving/relaunching Silo Dev and repointing the helper link, but the pre-update baseline failed `EINVAL`. This qualifies that post-replacement reconnect only, not a Fjord.app/installed-engine path or a complete update sequence ([linux.md Connections (run 2) §B-22](probes/linux.md#b-22--forced-command-after-bundle-replacement)).

Only Mac engine packages use this save/shutdown/replace/resume handoff (95 A-6 and §3). No Debian/AppImage package coordinator or Linux service exists in the new API; B-9/B-26 are closed. Stable Mac installer/LaunchAgent paths remain C-9/B-22.

#### updates.setAutomaticChecks
- Kind: command
- Status: EXTENDED: tauri `set_update_automatic_checks`, `updates.rs:323-368`, already persists and applies this preference. NEW engine-specific preferences and scheduling separate it from the client app updater under 95 A-6.
- Params: `enabled: bool`
- Result: `UpdateSnapshot`
- Events: `updates.changed` (`updates.rs:335`)

#### updates.focused
- Kind: command
- Status: EXTENDED: existing window-focus bridge to `updates::focused`, `main.rs:321-323`, and `updates.rs:283-291`, already brings checks forward on focus. NEW client-to-engine focus reporting targets the separate engine update schedule under 95 A-6.
- Params: none
- Result: none

#### updates.changed (event)
- Kind: subscription (05 §4.2 D event catalogue). Not named `updates.state`, which is the query (80 §2 N15).
- Status: EXTENDED: existing event `silo://update-state`, `updates.rs:171,335,445,536,795`, already carries updater state. NEW engine-package/version state follows 95 A-6; sequenced bounded delivery follows 95 A-4.
- Payload: the existing `UpdateSnapshot` fields, with engine-package/version identity and save/resume readiness replacing app-package readiness (95 A-6; §updates.state). Download progress also reaches `operations.job.progress` with `source: "update"` (`updates.download`).

`open_update_release` (`updates.rs:866-875`) opens `RELEASE_URL` in the user's chosen browser on the engine's host. **Client-side, not in the API:** `UpdateSnapshot.releaseUrl` carries the URL, and opening a browser is a launch on the user's device (§2.3 `browser*`).

Engine updates are separate from Fjord app updates: compare the engine version and use the save/resume handoff only when it changes (95 A-6). Fjord's existing app swap (`Sources/Fjord/Updater.swift:327-360`) must leave the running engine and computers alone when that version is unchanged (95 A-2, A-6). Stable Mac packaging and installer coordination remain B-22/C-9.
---

## 6. App shell: classification

| Item | Class | Reason |
| --- | --- | --- |
| `status_panel::open_main` (`status_panel.rs:153-169`) | UI-only, not in API | shows and focuses the main window; optional route handoff |
| `status_panel::take_main_route` (`status_panel.rs:171-174`) | UI-only | route handoff between the tray panel, notification click and main window |
| `status_panel::hide_status`, `resize_status` (`status_panel.rs:131-151`) | UI-only | the tray panel window's size and visibility (`docs/SiloUI-STATUS-PANEL.md`) |
| `status_panel::quit_app` (`status_panel.rs:176-179`) | client Quit | enters `settings::request_quit`; see Quit below |
| `app_menu::set_app_menu_state`, `show_app_menu` (`app_menu.rs:68-96`) | UI-only | native menu enablement and the retired Linux-host menu popup (`docs/SiloUI-NATIVE-MENUS.md` l.3-8) |
| `tray::update_tray` (`tray.rs:405-408`) | UI-only | menu bar icon tone and label |
| event `silo://menu-command` (`app_menu.rs:497`) | UI-only | native menu to webview dispatch |
| event `settings:changed` (`settings.rs:759`) | **engine** → `settings.changed` | state change of engine-stored settings |
| event `settings:flush-request` (`settings.rs:962`) | UI-only | the Tauri shell asks its webview to drain queued edits before Quit (`app/SiloUI/src/desktop/settings.ts:83-108`) |
| event `desktop:status-opened` (`status_panel.rs:68`) | UI-only | tells the panel webview to refresh (`production-source.ts:1085`, `settings.ts:108`) |
| event `desktop:route-requested` (`status_panel.rs:160`) | UI-only | pairs with `take_main_route` |
| event `chatgpt-app-status` (`chatgpt_app.rs:79,1981-1986`) | **engine** → `preparation.chatgpt.changed` (20; 80 §2 N5) | ChatGPT app status, served by the bridge as `chatgpt.status` (`remote.rs:247`) |
| event `desktop-clipboard` (`viewer_clipboard.rs:20-22,248-255`) | UI-only, not an API event (80 §2 N9) | the outcome of a shortcut-started copy or paste, reported to the viewer window that started it. In the API the client starts every transfer and gets the `Report` as the `clipboard.transfer` result |
| event `silo://quit-requested` (`settings.rs:1119-1150`) | client Quit | below |
| event `silo://shutdown-state-changed` (`settings.rs:924,960`) | **engine** → `engine.shutdown.changed` (05 §6) | marks that admission closed (`runtime::shutdown::begin`) or reopened after a failed Quit. Clients react: `production-source.ts:1088-1092`, `app/SiloUI/src/desktop/shutdown-boundary.tsx:41` |

**Quit and flush (coordinated with 05 §6).** Today Quit is one protocol between the Tauri shell and its webview:

1. `request_quit` → `silo://quit-requested {requestId, computers}` → `answer_quit_request` (`settings.rs:1060-1180`).
2. `ExitRequested` → `settings:flush-request` → `begin_settings_flush` / `complete_settings_flush` / `cancel_settings_flush`, with a 2 s fallback when the webview never acknowledges (`settings.rs:937-973,1182-1211`; `docs/SiloUI-SETTINGS.md` l.376-383).
3. `finish_exit` stops local computers, flushes settings, closes tunnels and exits (`settings.rs:879-918`).

`enable_quit_confirmation` opts the webview in (`settings.rs:1152-1161`). `read_shutdown_state` reads the phase (`settings.rs:1043-1046`).

Mapping:

| Part | Where it goes |
| --- | --- |
| `quit_app`, `enable_quit_confirmation`, `answer_quit_request`, `silo://quit-requested`, `begin_settings_flush`, `complete_settings_flush`, `cancel_settings_flush`, `settings:flush-request` | client-side, not in the API. They coordinate one client process with its own UI. The engine's settings are saved on every change (`settings.rs:148-152`) and on `settings.flush`. |
| Stopping local computers, closing owned tunnels, admission closing and the session-end budget (`settings.rs:879-918,983-1019`; `system_shutdown.rs:1-48`; `docs/SiloUI-CONNECTIONS.md` § Close and Quit) | `engine.shutdown` (05 §6), which exists whatever Quit means; today's Quit stopped computers; the NEW client flow uses inventory/stop/disconnect (95 A-2) |
| `read_shutdown_state` and `silo://shutdown-state-changed` | `engine.state` (`shuttingDown`) and `engine.shutdown.changed` (05) |

Quit with running computers asks **Cancel / Keep running / Stop and quit** (95 A-2). Read `computers.list` for running ids/names; Cancel leaves the client open, Keep running calls `engine.disconnect`, Stop and quit awaits `computers.stop` for the listed computers before disconnecting. A failure leaves the client open. Client quit never requests engine shutdown; Fjord updates and crashes never stop computers (95 A-2; 05 §6; existing quit inventory `settings.rs:1060-1180`).

---

## 7. Onboarding

**Steps:** `dependencies`, `computers`, `github`, `review` (`settings.rs:400-402`; TS `app/SiloUI/src/features/onboarding/model/onboarding-state.ts:8`, used by `onboarding-draft.ts:32`).

**Draft** (`valid_draft`, `settings.rs:378-477`):

| Field | Content |
| --- | --- |
| `currentStep` | one of the four steps |
| `computers` | at most 64 valid configurations with unique ids and names |
| `unfinishedComputerEditor` | `{draft, insertAt, originalID?, displayAfterID?}` \| null |
| `computerSelections` | `{repository, allowPushes}[]` per computer |
| `computerIdentities` | `{name, email, apply}` per computer |
| `computerRepositoryAccess?` | `{repositoryMode, allRepositoriesAllowChanges, authenticationMethod?}` per computer |

- **Limits:** credentials, runtime state and arbitrary fields are refused; 256 KiB maximum (`settings.rs:376-377,14`).
- **Persistence:** edits save immediately, incomplete text included. Cancel discards the editor draft; successful completion clears it (`docs/SiloUI-SETTINGS.md` l.329-335).
- **Resuming:** opening the app never creates computers from a draft. The footer reads "Not started" until Continue (`docs/SiloUI-DEPENDENCIES-BACKUP-TESTING.md` § Continue and the setup queue, step 1).

Engine calls behind each step, all in other sections. Each current command below is followed by its canonical API method; method status and contracts are in the owning section (10 §3/§5/§7; 20 §4.2; 50 §`github.*`; 05 §4.2 E/F):

| Step | Engine calls | Source |
| --- | --- | --- |
| Dependencies | `read_dependencies` → `device.dependencies`; `read_preparation_status` → `preparation.status`; `retry_preparation` → `preparation.retry` (20 §4.2) | `app/SiloUI/src/desktop/dependencies.ts:92`, `app/SiloUI/src/desktop/preparation.ts:30-31`; `docs/SiloUI-DEPENDENCIES-BACKUP-TESTING.md` § Dependencies |
| Computers | `change_computer_configuration` → `computers.configuration.change`; `retry_computer_configuration` → `computers.configuration.retry`; `read_setup_activity` → `activity.setup.read` (10 §3/§7); event `silo://computer-configuration-progress` → `operations.job.progress` with `source: "setup"` (05 §4.2 E) | `production-source.ts:788,1093-1100,1344-1345`; `docs/SiloUI-DEPENDENCIES-BACKUP-TESTING.md` § Continue and the setup queue, § Live activity |
| GitHub | `connect_github` → `github.connect`; `cancel_github_connection` → `operations.cancel {jobId}` for the running connect job (canonical job cancellation; old command not retained, 95 §3; 05 §4.2 F); `reopen_github_authorization` → `github.connect.reopen`; `read_github_state` → `github.state`; `save_github_configuration` → `github.configuration.save` (50 §`github.*`); identities `configure_computer_identities` → `computers.identities.configure`; `verify_computer_identities` → `computers.identities.verify` (10 §5) | `production-source.ts:1401,1436,1451,1544-1570,1870-1887`; `docs/SiloUI-DEPENDENCIES-BACKUP-TESTING.md` § Continue and the setup queue step 4, § Resume, retry and completion |
| Review / Finish | `settings.update {…applications, onboardingComplete: true}` after setup prerequisites succeed | `app/SiloUI/src/desktop/production-onboarding.tsx:243-252`; `docs/SiloUI-DEPENDENCIES-BACKUP-TESTING.md` § Continue and the setup queue step 4 |
| Connect another device instead | `connections.devices.connect`, `connections.ssh.authorizationCommand`, then `settings.update {onboardingComplete: true}` and `settings.flush` | `production-onboarding.tsx:194-205`; `docs/SiloUI-CONNECTIONS.md` l.14 ("A controller can connect during onboarding without creating a local computer") |

- **Settings calls:** onboarding reads settings (`settings.read`, `settings.changed`) and writes only through client-owned drafts, `settings.update` and `settings.flush` (95 A-5) (`app/SiloUI/src/features/onboarding/onboarding-app.tsx:165,234,273,292,300,309`; `production-onboarding.tsx:200-201,248`).
- **What the engine keeps:** only `onboardingComplete` matters to it, because autostart waits for it (`startup.rs:18-26`). The draft is per-client UI state (§2.3).
- **Fjord:** has its own first-launch onboarding (`Sources/Fjord/Onboarding.swift:3-9`) and flag (`AppSettings.toolsPicked`, `Sources/Fjord/Models.swift:80-81`).

---

## 8. Coverage table

Each row maps to exactly one canonical API method or event, or says why it is not in the API. Rows split by an `action` argument list one action per row.

### Tauri commands

| Tauri command | API |
| --- | --- |
| `remote::connections_status` | `connections.status` |
| `remote::set_connections_enabled` | `connections.setEnabled` |
| `remote::authorize_device` | client-side launcher using `connections.ssh.authorizationCommand` (95 A-22) |
| `remote::setup_device_key` | client-side launcher using `connections.ssh.keySetupCommand` (95 A-22) |
| `remote::device_list` | `connections.devices.list` |
| `remote::connect_device` | `connections.devices.connect` |
| `remote::remove_device` | `connections.devices.remove` |
| `remote::device_snapshot` | `computers.list {deviceId}` (10 §2; 80 §2 N2; local-engine routing decided by 95 A-3). Keeps the device-health side effect of §1.7 |
| `remote::remote_computer_action` action=`start` (`runtime/remote_ops.rs:162`) | `computers.start {computerId, deviceId}` (10) |
| `remote::remote_computer_action` action=`stop` | `computers.stop {computerId, deviceId}` (10) |
| `remote::remote_computer_action` action=`restart` | `computers.restart {computerId, deviceId}` (10) |
| `remote::remote_computer_action` action=`dismiss-error` | `computers.dismissError {computerId, deviceId}` (10) |
| `remote::remote_checkpoint_action` action=`create` (`remote.rs:1345-1357`) | `checkpoints.create {computerId, deviceId}` (20) |
| `remote::remote_checkpoint_action` action=`fork` | `checkpoints.fork {computerId, deviceId}` (20) |
| `remote::remote_checkpoint_action` action=`restore` | `checkpoints.restore {computerId, deviceId}` (20) |
| `remote::remote_upsert_computer` with `expected` absent (`remote.rs:1692`) | `computers.create {deviceId}` (10) |
| `remote::remote_upsert_computer` with `expected` set | `computers.configuration.change {deviceId}` (10) |
| `remote::remote_delete_computer` | `computers.delete {computerId, deviceId}` (10); emits `notifications.cleared` (§4.2) |
| `settings::initialize_settings` | engine startup (load at start, 05 §7 step 2); no method; reads use `settings.read` |
| `settings::read_settings` | `settings.read` |
| `settings::update_settings` | `settings.update` |
| `settings::update_onboarding_draft` | client-owned draft, not engine API (95 A-5) |
| `settings::import_legacy_theme` | no API compatibility method; conversion only at launch through runtime_migration (95 §3) |
| `settings::flush_settings` | `settings.flush` (80 §2 N14; 05 §9.1 agrees) |
| `settings::begin_settings_flush` | client-side Quit handshake, not in API (§6) |
| `settings::complete_settings_flush` | client-side, not in API (§6); the `finish_exit` it triggers is `engine.shutdown`'s work (05 §6) |
| `settings::cancel_settings_flush` | client-side, not in API (§6) |
| `settings::read_shutdown_state` | `engine.state` (05) |
| `settings::enable_quit_confirmation` | client-side, not in API (§6) |
| `settings::answer_quit_request` | client-side, not in API (§6) |
| `system_integrations::read_system_integrations` | client-side, not in API (§3) |
| `system_integrations::set_login_item` | client-side, not in API (§3); engine autostart → 95 A-1/A-23; B-22 registration probe |
| `system_integrations::request_notification_authorization` | client-side, not in API (§3) |
| `system_integrations::open_integration_settings` | UI-only, not in API (§3) |
| `system_integrations::show_integration_error` | UI-only, not in API; engine-originated uses → notices or method errors (§3) |
| `notifications::deliver_notice` | client-side, not in API (§4.2) |
| `notifications::clear_computer_notices` | client-side, not in API; engine emits `notifications.cleared` (§4.2) |
| `updates::get_update_state` | `updates.state` |
| `updates::check_for_update` | `updates.check` |
| `updates::download_update` | `updates.download` (job, `job:<n>`) |
| `updates::install_update` | `engine.update.prepare` (05 §6; 80 §2 N13); the client shuts down the saved engine before replacement, then restarts/resumes it; `engine.update.abort` resumes the saved set on an aborted handoff (05 §6). No separate `updates.install`; save/resume required by 95 A-6 |
| `updates::set_update_automatic_checks` | `updates.setAutomaticChecks` |
| `updates::open_update_release` | client-side, not in API (`UpdateSnapshot.releaseUrl`) |
| `status_panel::open_main` | UI-only, not in API |
| `status_panel::take_main_route` | UI-only, not in API |
| `status_panel::hide_status` | UI-only, not in API |
| `status_panel::resize_status` | UI-only, not in API |
| `status_panel::quit_app` | client-side Quit, not in API (§6); Cancel / Keep running / Stop and quit (95 A-2) |
| `app_menu::set_app_menu_state` | UI-only, not in API |
| `app_menu::show_app_menu` | UI-only, not in API |
| `tray::update_tray` | UI-only, not in API |

Methods without a dedicated current Tauri command: `connections.ssh.authorizationCommand` and `connections.ssh.keySetupCommand` re-expose existing command builders (EXISTS (renamed), §1.7); `connections.devices.health` extends existing bookkeeping (95 A-4); `updates.focused` extends the existing focus hook (§5.2). `connections.keys.revoke` (95 A-36) and `notifications.list` (95 A-27) are NEW behaviours.

### Events

| Event | API |
| --- | --- |
| `silo://notice` | `notifications.notice` (extended, §4.2) |
| — (today OS-only `notify_native` notices) | `notifications.notice` (NEW source coverage, 95 A-27) |
| — (deletion withdrawal) | `notifications.cleared` (NEW) |
| `silo://update-state` | `updates.changed` (05 §4.2 D; 80 §2 N15) |
| `settings:changed` | `settings.changed` |
| `settings:flush-request` | UI-only, not in API |
| `silo://quit-requested` | client-side, not in API |
| `silo://shutdown-state-changed` | `engine.shutdown.changed` (05) |
| `silo://menu-command` | UI-only, not in API |
| `desktop:status-opened` | UI-only, not in API |
| `desktop:route-requested` | UI-only, not in API |
| `chatgpt-app-status` | `preparation.chatgpt.changed` (20; 80 §2 N5) |
| `desktop-clipboard` | UI-only, not an API event: it reports a transfer a shortcut in the Tauri shell started (`viewer_clipboard.rs:249-256`); the API returns the `Report` as the `clipboard.transfer` result (80 §2 N9) |
| window focus hook `updates::focused` (`main.rs:321-323`) | `updates.focused` (NEW method, not an event) |

### Bridge methods (`remote.rs:236-273`)

Existing v5 names below are source evidence only. The new bridge uses canonical API names; no v5 alias is retained, and the Tauri UI moves with it (95 §3).

| Bridge method | API |
| --- | --- |
| `handshake` | `engine.handshake` (05; key restriction specified in §1.5) |
| `runtime.snapshot` | Existing source mapped to canonical `computers.list {deviceId}`, its Linux member (10 §2; 80 §2 N2) |
| `runtime.logs` | Existing source mapped to canonical `logs.query` (10) |
| `runtime.configuration` | Existing source mapped to canonical `computers.configuration.read` (10) |
| `runtime.action` action=`start` (`runtime/remote_ops.rs:162`) | Existing source mapped to canonical `computers.start` (10) |
| `runtime.action` action=`stop` | Existing source mapped to canonical `computers.stop` (10) |
| `runtime.action` action=`restart` | Existing source mapped to canonical `computers.restart` (10) |
| `runtime.action` action=`dismiss-error` | Existing source mapped to canonical `computers.dismissError` (10) |
| `runtime.upsert` with `expected: null` | Existing source mapped to canonical `computers.create` (10) |
| `runtime.upsert` with `expected` set | Existing source mapped to canonical `computers.configuration.change` (10) |
| `runtime.delete` | Existing source mapped to canonical `computers.delete` (10) |
| `desktop.connect` | `desktop.connect`, engine to engine only (40) |
| `desktop.status` | `desktop.status` (40) |
| `desktop.action` | `desktop.action` (40) |
| `chatgpt.status` | Existing source mapped to canonical `preparation.chatgpt.status` (20; 80 §2 N5) |
| `chatgpt.retry` | Existing source mapped to canonical `preparation.chatgpt.retry` (20; 80 §2 N5) |
| `computerUse.approval` | `computerUse.approval` (80 §2 N7) |
| `ssh.access.state` | Existing source mapped to canonical `sshAccess.state` (50) |
| `ssh.access.connection` | Existing source mapped to canonical `sshAccess.connection` (50) |
| `ssh.access.save` | Existing source mapped to canonical `sshAccess.save` (50) |
| `files.list` | `files.list` (50) |
| `guest.prepare` | `guest.prepare` (50) |
| `guest.ssh` | `guest.ssh` (50) |
| `network.state` | `network.state` (50) |
| `network.publish` | `network.publish` (50) |
| `network.unpublish` | `network.unpublish` (50) |
| `repository.push.status` | Existing source mapped to canonical `push.status` (50) |
| `repository.push.start` | Existing source mapped to canonical `push.start` (50) |
| `repository.push` | not in the API: listed in `METHODS` but no longer served (`remote_access.rs:124-125`; 80 §5 B-6) |
| `repository.dismiss` | Existing source mapped to canonical `push.dismiss` (50) |
| `checkpoint.create` | Existing source mapped to canonical `checkpoints.create` (20; 80 §2 N4) |
| `checkpoint.fork` | Existing source mapped to canonical `checkpoints.fork` (20; 80 §2 N4) |
| `checkpoint.restore` | Existing source mapped to canonical `checkpoints.restore` (20; 80 §2 N4) |
| `macos.snapshot` | Existing source mapped to canonical `computers.list`, its macOS member (10 §2; 80 §2 N1) |
| `macos.create` | Existing source mapped to canonical `computers.create {kind: "macos", request}` (80 §2 N1) |
| `macos.action` action=`start` (`macos_remote.rs:206-210`) | Existing source mapped to canonical `computers.start` (80 §2 N1) |
| `macos.action` action=`stop` | Existing source mapped to canonical `computers.stop` (80 §2 N1) |
| `macos.action` action=`force-stop` | Existing source mapped to canonical `computers.forceStop` (80 §2 N1) |
| `macos.action` action=`delete` | Existing source mapped to canonical `computers.delete` (80 §2 N1) |
| `macos.action` action=`setup` | Existing source mapped to canonical `macos.setup.retry` (30; 80 §2 N1) |
| `macos.display.connect` | `macos.display.connect` (30) |
| `macos.display.resize` | `macos.display.resize` (30) |
| `macos.display.stream` | `macos.display.stream` (30) |

### Process modes and engine lifecycle hooks

| Item | API |
| --- | --- |
| `--remote-bridge` (`main.rs:98`, `remote.rs:1748-1772`) | the canonical Connections transport (§1.6; 95 §3), not a client method |
| `--remote-guest` (`main.rs:99-102`) | ProxyCommand entry for `guest.ssh` (50; 80 §1.6) |
| Linux package-update guard (`main.rs:83-90`) | retired Linux-host source branch, not engine behavior or API (95 §3; B-9/B-26 closed) |
| `remote::start` at setup (`main.rs:304`, `remote.rs:2054-2068`) | engine startup (05 §7 step 7) |

---

## 9. Open questions

1. **DECIDED (95 A-1):** Fjord is the product, Silo ships engine changes in its app, and both apps share one engine. B-22 is PARTLY: a pre-installed key completed a v5 handshake after the helper link was repointed to a copied Silo Dev bundle and relaunched. The original-path baseline authenticated but failed `EINVAL` with no frame. Stable engine/Fjord paths, registration and a successful before/after baseline remain OPEN (`remote.rs:342-405`, `:2054-2068`; [linux.md Connections (run 2) §B-22](probes/linux.md#b-22--forced-command-after-bundle-replacement)).
2. **DECIDED (95 A-1):** Both apps are clients of one engine per channel (00 §What was decided; 05 §5.2); no second Connections socket owner (`remote.rs:2015-2031`).
3. **DECIDED (95 A-3):** Clients talk only to their local engine, which forwards remote methods over Connections SSH (`remote.rs:1260-1290`).
4. **DECIDED (95 A-4):** Push new device-health state plus a sequence number; bounded buffers require re-read after gaps/reconnect (§connections.devices.health; 05 event catalogue).
5. **DECIDED (95 A-2):** Quit offers Cancel / Keep running / Stop and quit; app updates and crashes never stop computers (§6; 05 §6).
6. **DECIDED (95 A-5):** Any peer-euid-authorized same-user local client may change settings; onboarding drafts stay client-side (`settings.rs:737-743`, `:778-791` are the restrictions being replaced).
7. **DECIDED (95 A-1):** The shared engine remains a macOS GUI-session LaunchAgent (00 §What was decided); exact registration/bundle paths remain B-22, not specified in 95.
8. **DECIDED (95 A-23, overridden by §3):** hosts are Macs only; no Linux engine service or package-update path. B-9/B-26 are closed; Linux computers remain supported on Macs.
9. **DECIDED (95 A-6):** Only an engine-version change triggers engine save/update/resume; Fjord's app updater otherwise leaves computers running (§5.2). Mac installer ownership/path and memory-compatible replacement remain B-22/C-9/B-30; 95 does not choose the installer process.
10. **DECIDED (95 A-27):** Keep the latest notice per key, expose `notifications.list`, and post no engine OS notifications (§4.2). Former OS-delivery probe B-6 is unnecessary. Restart persistence/expiry remain B-29.
11. **DECIDED (95 A-22):** Return terminal/editor/browser command material for clients to launch; the engine needs no Apple Events entitlement (§connections.ssh.authorizationCommand/keySetupCommand; 50).
12. **DECIDED (95 A-35):** Device facts include Remote Login status (§device.facts); the status probe's implementation remains unsourced.
13. **DECIDED (95 A-36):** Device removal revokes the controller key on the owner before completing local removal (§connections.devices.remove/keys.revoke); PARTLY B-28 observed only offline saved-entry removal with a separate localhost key/session unchanged. Connected-owner revocation and retry/session/reconnect behavior remain OPEN ([linux.md Connections (run 2) §B-28](probes/linux.md#b-28--controller-removal-key-retention-and-open-session)).
