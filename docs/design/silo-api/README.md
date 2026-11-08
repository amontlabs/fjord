# Silo engine API: a spec for Fjord's frontend

> **Fjord no longer has a Computers feature (2026-11-08).** It was removed outright while Silo is rewritten, so this spec describes an integration Fjord does not contain.

Silo becomes an engine: a Rust library run by `silod`, a long-running LaunchAgent in the Mac user’s GUI login session. Hosts and controllers are Macs only; they manage both Linux and macOS computers (95 §3). Fjord becomes the macOS app that drives it. This folder specifies the engine's full API: everything Silo can do today except drawing UI, plus what Fjord and the missing macOS features need.

Status as of 2026-10-13: drafted, citation-checked, reconciled and audited. It's against Silo `94d81937` and Fjord `87b3623`. **0 owner decisions are open**: all 37 are decided by [95](95-decisions.md), including its §3 amendments. Live evidence is folded into the contracts: **8 probes SETTLED, 15 PARTLY, 10 OPEN for implementation, 4 CLOSED**. The 25 remaining probe/remainder items and 9 research items are tracked in [80 §4](80-coverage-and-consistency.md#4-consolidated-open-questions).

## The rule every section follows

Every statement cites a file:line, a doc section or a URL. Every method is marked **EXISTS** (same name and behavior), **EXISTS (renamed)** (existing behavior re-exposed under a canonical name), **EXTENDED** (existing behavior plus a named, justified NEW part), or **NEW** (no current implementation, with a cited requirement). Existing behavior cites its current command or bridge method and file:line. Renaming alone never counts as NEW; a required platform extension counts as EXTENDED. Anything that couldn't be backed is under Open questions. See [00-brief.md](00-brief.md).

## Files

| File | Covers |
| --- | --- |
| [00-brief.md](00-brief.md) | Decisions, rules, method format, shared domains |
| [05-engine-architecture.md](05-engine-architecture.md) | Process model, removing Tauri, Mac hosting, canonical transport built from v5 framing, **job contract** (`#job-contract`), **event catalogue** (§4.2 D), multiple clients, shutdown and update, startup behaviours |
| [10-computers-lifecycle.md](10-computers-lifecycle.md) | Inventory, configuration, lifecycle, operations queue, activity, logs, storage, identities, account preparation |
| [20-checkpoints-exports-preparation.md](20-checkpoints-exports-preparation.md) | Checkpoints (Linux and macOS), export and import, migration, pre-upgrade backup, preparation (image, LCU, ChatGPT), dependencies |
| [30-macos-computers.md](30-macos-computers.md) | macOS state machine, creation and setup, templates, the engine-owned VM window, clipboard, guest access, every macOS gap |
| [40-desktop-display-computer-use.md](40-desktop-display-computer-use.md) | Linux desktop service and viewer, the native Linux display (later), computer use and LCU, no input leases, guest recording mechanisms and NEW independent viewer connections |
| [50-access-network-files.md](50-access-network-files.md) | GitHub, push, secrets, network and ports, SSH access, SSH aliases for the Claude app, files |
| [60-connections-settings-services.md](60-connections-settings-services.md) | Connections, settings, system integrations, notifications, updates, app shell, onboarding |
| [70-fjord-needs.md](70-fjord-needs.md) | Claude desktop sessions over SSH into a computer, the Router's delivery inside a guest, `guest.exec` / `guest.files.*`, Triage headless runs, clones |
| [80-coverage-and-consistency.md](80-coverage-and-consistency.md) | Coverage from code (0 missing, 0 conflicts), **unified method index**, **consolidated Open questions** (0 open owner decisions; probes and research), Silo bugs and stale docs |
| [90-codex-independent-audit.md](90-codex-independent-audit.md) | An independent completeness audit by Codex |
| [91-codex-findings-verified.md](91-codex-findings-verified.md) | Historical audit findings checked against the code; all 18 applied |
| [92-macos-proxy-research.md](92-macos-proxy-research.md) | Source research for the macOS host proxy and the B-27 gateway probe |
| [95-decisions.md](95-decisions.md) | All 37 owner decisions, technical defaults and binding §3 amendments |
| [probes/](probes/) | Live macOS, Linux, proxy and Connections evidence, follow-ups and track summaries |

## Counts (from 80)

- **Silo source surface, all mapped:** 159 Tauri commands, 24 backend event names, 35 bridge entries, 4 process modes plus 1 startup guard. The Linux AppImage mode and Linux package guard are retired (95 §3; 80 §1.5).
- **API:** 146 methods (3 EXISTS, 10 EXISTS (renamed), 121 EXTENDED, 12 NEW); 26 catalogue events; 29 job methods.
- **Evidence:** 37 probe IDs = 8 SETTLED + 15 PARTLY + 10 OPEN + 4 CLOSED; 25 need implementation evidence. B-9/B-26 are closed because Linux hosts were dropped. 0 open owner decisions; 9 research items. Internal provisioning/recorder orchestration adds no API methods.

## Probe summary and work before implementation

The follow-ups qualify macOS serial-queue VM hosting, regular/accessory app classification, guest SFTP and GUI-session access, ScreenCaptureKit recording with the recorder's own guest TCC identity, and saved boot/process continuity across host-process replacement. Linux evidence qualifies Desktop's Silo SSH alias, disconnect survival, executable guest home, guest PermissionRequest hooks, ffmpeg display capture and local inotify performance. These are version-scoped observations, not completed engine adapters ([macos.md](probes/macos.md#follow-up), [linux.md](probes/linux.md#follow-up)).

Three contract changes follow directly: independent viewers require NEW engine/streamer work because Silo reuses one viewer and live Selkies admits a new primary; macOS setup needs NEW Git/LFS/Xcode developer-tools provisioning because the template lacks working tools; Fjord must read/watch guest transcripts through `guest.files.*` because its local `ssh-<id>` copy lagged and remained smaller. Real APFS costs inform last-three automatic checkpoint retention without inventing private/reclaimable byte metrics (40 §2, 30 §3, 70 §2, 20 §1.4; [linux.md §B-21](probes/linux.md#b-21--two-viewer-clients), [Follow-up §B-16](probes/linux.md#b-16-live-transcript-freshness-and-background-task-output), [macos.md Follow-up](probes/macos.md#follow-up)).

The macOS proxy mechanism is FileHandle → datagram gateway → patched `SmoltcpNetwork`, with guest route/DNS bootstrap and System-keychain CA trust. It passed controlled substitution, revocation and sequential isolation, but default guest DNS timed out; the 10 MiB frame transfer median was 245 ms / 42.81 MB/s versus NAT 122 ms / 85.64 MB/s. Production DNS, secret/GitHub/CA lifecycle and concurrent isolation remain open ([proxy.md §Results](probes/proxy.md#results), [§NAT comparison](probes/proxy.md#nat-comparison); 50).

Before implementing each dependent feature, close its research/remainder in [80 §4(B–C)](80-coverage-and-consistency.md#4-consolidated-open-questions). During implementation, run the 10 OPEN tests and regress the qualified mechanisms. Remaining evidence includes login-window/locked-session and repeatable guest service readiness; real Fjord plugin/forms/paste/watch integration; actual Claude OAuth bearer headers/destinations; independent close/resize/clipboard; successful before/after helper-path baseline and bridge EINVAL/remote creation waits; connected-peer revocation; full update journal/failure recovery and Linux continuity; macOS parity/tools provisioning; checkpoint retention under dependencies; notice/job persistence and event/timer/cap limits. Connections run 2 proves only post-replacement handshake and limited offline removal, not the unmeasured behavior ([linux.md Connections (run 2)](probes/linux.md#connections-run-2)).

## Reading order

1. [00-brief.md](00-brief.md) for scope and evidence rules, then [95-decisions.md](95-decisions.md), including §3, for binding decisions. Later amendments override earlier text.
2. [05-engine-architecture.md](05-engine-architecture.md) for transport, jobs, events and process lifetime.
3. Sections 10–60 for the domain contracts, then [70-fjord-needs.md](70-fjord-needs.md) for their Fjord uses.
4. [80-coverage-and-consistency.md](80-coverage-and-consistency.md) for the unified index, counts and remaining implementation evidence.
5. [92-macos-proxy-research.md](92-macos-proxy-research.md) and [probes/](probes/) for proxy research and probe evidence. Read 90–91 as historical audit records, subject to 95 and the current contracts.

## How it was produced

1. Eight section authors wrote one file each, from the brief.
2. Four citation checkers verified about 4,500 citations and fixed about 450.
3. A coverage check built the lists from Silo's code.
4. A reconciliation pass unified names, jobs and events.
5. Codex ran an independent audit. It produced 18 findings; each was checked against the code and applied.
6. Codex made a final pass: it rebuilt coverage from the code and ranked the decisions.

7. Folded live probe evidence and follow-ups into the contracts and reconciled all 37 probe statuses, preserving protected records and the pinned Silo source.
