# Claude Code Projects: how it really works

> Superseded: Fjord now runs on T3 Code instead of Claude Code and claude.ai. See [t3-code-map.md](t3-code-map.md).

Working reference for the Router POC, started 2026-11-02. Everything here is private and can change. "Tested" means seen
working on this account. "Code" means read in the claude.ai client, not run yet.

**Not for shipping.** Automating these calls conflicts with Anthropic's Consumer Terms and Claude Code's credential rules
unless Anthropic gives explicit permission. See the terms note in [router-redesign.md](router-redesign.md).

## Model

- A project is a **channel** (`chan_…`). Its coordinator is one cloud session (`channel_session_id`, `cse_…`).
- A session has two id forms: `cse_X` and `session_X`.
- Local threads are real sessions on your Mac, started by a Remote Control server for a connected folder.
- Your desktop sessions show up in `/v1/code/sessions` as `environment_kind: bridge`, tag `remote-control-sdk`, with
  `title`, `status`, `worker_status`, `connection_status` and `unread`.

## Calling it

Base: `https://claude.ai`. The signed-in cookie plus `anthropic-version: 2023-06-01` was enough for reads (tested). The app
also sends `anthropic-beta: ccr-byoc-2025-07-29`, `anthropic-client-feature: ccr` and `x-organization-uuid`. A
`cf-mitigated: challenge` response means Cloudflare wants the browser to prove itself, so plain HTTP clients may not work.

## Calls

| Purpose | Call | Status |
|---|---|---|
| List projects | `GET /v1/code/channels?scope=all&include_members=true&limit=200` | Tested |
| Create project | `POST /v1/code/channels` `{name, visibility, icon, color}`; no repo needed | Tested |
| Project details, settings | `GET /v1/code/channels/:id`, `/config` | Tested |
| Send to coordinator | `POST /v1/code/channels/:id/messages` `{body, client_message_id, sender_timezone}` | Tested |
| Read timeline | `GET /v1/code/channels/:id/timeline?limit=200` (also `thread_roots_only`, `bound_only`) | Tested |
| Live project feed | `GET /v1/code/channels/:id/messages/stream?from=tail&caught_up=true` (SSE) | Tested |
| Live feed of all sessions | `GET /v1/code/sessions/watch?...&channels_changed=true` | Seen |
| List sessions | `GET /v1/code/sessions?statuses=active&statuses=paused&limit=50` | Tested |
| Project's sessions | `GET /v1/code/sessions?hearth_channel_id=:id` | Returned non-project sessions too; check |
| Session events | `GET /v1/code/sessions/:id/events?limit=200&sort_order=desc` | Seen |
| Daily thread limit | `GET /v1/code/channels/:id/headroom`: 500 a day per project | Tested |
| Connected folders, preapproval | `GET /v1/code/channels/:id/remote-control-preapproval` | Tested |
| Set preapproval | `POST …/remote-control-preapproval` `{enabled, environment_id, worktree, folder_path}` | Code |
| Add allowed folders | `POST …/remote-control-preapproval/folders:allow` `{session_id, paths}` | Code |
| Worktree per thread | `POST …/remote-control-worktree` `{worktree}` | Code |
| Send to a session | `POST /v1/code/sessions/:id/events`, body includes `{uuid, session_id, type: "user", message: {role, content}}` | Code |
| Move a session into a project | `POST /v1/code/sessions/:id/hearth-channel` `{hearth_channel_id}` | Code |
| Archive session | `POST /v1/code/sessions/:id/archive` | Code |
| Mark read | `POST /v1/code/sessions/:id/mark_read` `{event_id}` | Seen |

## Timeline rows

Each row has `id`, `body`, `author_account_id` (you) or `author_session_id` (coordinator), `thread_root_id`,
`thread_status`, `thread_any_session_working`, `open_decisions`, `links`, `reply_count`, `has_unread`.

Routing is machine-readable. A `server_notice` row's body is JSON:
`{"kind":"message_routed","thread_root_id":…,"session_id":…,"message_ids":[…],"text":"Routed to a thread."}`

## What a thread receives

- Your message: `<wake reason="mention">` holding `<message from="human" trust="principal">`, with
  `projectsUserTurn: true`. It counts as your words.
- A coordinator's start note: `<relay from="coordinator" reason="spawn">`, marked as not from you.
- Threads answer with `mcp__claude-code-remote__send_message` to `@parent`.

## Coordinator tools

`fetch_thread`, `fetch_project_timeline`, `fetch_messages`, `list_thread_sessions`, `list_project_prs`, `ask_decision`,
`update_status`, `set_thread_label`, `set_thread_resolved`, `start_thread_session`, `start_folder_thread`, `switch_model`,
`read_memory`, `update_memory`, `search_channels`, `get_project_session_id`, `list_project_files`, `read_project_file`,
`post_widget`, `pin_artifact`, `no_reply_needed`.

## Project settings that matter

Settings → Environment → Local: **Let Claude use your device**, **Pre-approved folders** ("use in any thread here without
asking"), **Use worktrees**.

Settings → Debug access: gives Claude in another project read-only access to this project's chat and threads, for a set time.

`GET …/remote-control-preapproval` marks each connected folder `folder_preapprovable`. A folder served by
`claude remote-control` with no GitHub remote was `false`, yet the `~/code/spikes/fjord-e2e` spike folder (served by a terminal Remote
Control) was granted live in 2.6 s, so the flag does not mean a folder can't be pre-approved. What `false` means isn't known.

## Timeline events

`server_notice` rows also carry `{"kind":"remote_control_session","phase":"proposed"|"active",…}` and
`{"kind":"thread_started","thread_root_id":…,"session_id":…}`. A thread waiting on the card shows `thread_status: needs_input`.
A running thread shows under `bound_sessions` with `title`, `status_bucket`, `device_route`, `device_state`, `machine_state`.

## Test results

- A project created with only a name; the coordinator answered "OK" in seconds with no thread (`fjord-poc-test`).
- A Fjord plugin message reached a local project thread as the owner's words.
- A `POST …/messages` call made the coordinator propose a local thread in the named folder. After Allow once, the thread
  ran, posted its result with `mcp__hearthbot__post_message`, and marked itself resolved with `set_thread_resolved`.
- `POST /v1/code/sessions/cse_X/events` with
  `{"events":[{"payload":{"type":"user","uuid":…,"session_id":"session_X","parent_tool_use_id":null,"message":{"role":"user","content":…}}}]}`
  reached that local thread as a plain turn with `origin: {kind: "human"}`, no wrapper. The thread was started by a CLI
  Remote Control server.
- `~/.claude/sessions/<pid>.json` gives `bridgeSessionId` (`session_X`), linking a local session to its cloud id.
- Without preapproval, a second local thread needs the card again.
- Opening a session page showed "Sign in again to verify your device". Not now dismissed it, and the send still worked.
- With a pre-approved folder, `POST …/messages` started a thread with no click: `thread_started` after 8.7 s, on a
  session with `entrypoint: claude-desktop`.

### How a message is framed

| Route | Terminal-run thread | Desktop-run thread |
|---|---|---|
| Web UI, `POST /sessions/:id/events` | human | human |
| Raw call, `POST /sessions/:id/events` | peer (`from: unknown`) | peer (`from: unknown`) |
| Raw call, `POST /channels/:id/messages` | human, `trust="principal"` | human, `trust="principal"` |

- **The way to send as yourself:** `POST /v1/code/channels/:id/messages` with `reply_to_message_id: <thread root>`. It
  reached a desktop-run thread 0.2 s later as `<message from="human" trust="principal">`, with no coordinator turn.
- `/sessions/:id/events` isn't an option for your words. The app's send has client headers a raw call lacks, and copying
  them to change the label would forge who sent it. We don't do that.
- The same route covers project threads only. Sessions outside a project keep the plugin path.

### From a native app

`poc/projects/ProjectsPOC.swift` holds a signed-in `WKWebView` and runs `fetch` inside the page. Email sign-in worked. List,
timeline, sessions and send all worked with no Cloudflare block, and no token leaves the web store.

`GET /v1/code/sessions` gives each session a `status_bucket` (`working`, `review_ready`, `blocked`, `completed`, `failed`),
so board state needs no model.

### Other results

- **Claude stays back.** The frontmost app stayed Brave for 14 s while a thread started (one run).
- **Local by default.** In a project with no repo and one pre-approved folder, a message that didn't mention local still
  started a local thread (one run).

### A stopped thread (killed with SIGTERM to imitate losing the process)

- The thread shows `device_state: disconnected`, so Fjord can see it.
- A channel reply isn't delivered and doesn't restart it (checked after about a minute).
- The coordinator said it was restarting the thread, but nothing restarted. Don't trust its words over the state data.
- `SendMessage` to `local_<id>` from an app-run session cold-started the process and it answered. But it came back without
  its project link: still `disconnected`, and a later channel reply didn't arrive.
- This imitates a crash, not a real eviction. The app spares Remote Control sessions from eviction apart from a narrow
  memory-pressure case, so it should be rare. App quit and Mac sleep aren't tested.
- Fjord now handles it: a reply to such a thread goes to the coordinator, asking for a new thread that continues it (see
  [router-data-design.md](router-data-design.md)).

## Still to test

1. What happens to threads when the app quits or the Mac sleeps, and how to recover a disconnected thread.
2. Can `hearth-channel` move a local session into a project?
3. Can a manager project use Debug access to read the others, and how long does access last?
4. How long the sign-in lasts.
5. Worktrees: does each thread get its own, and how do they get cleaned up?
6. Does Fjord's plugin keep working for cards and forms inside threads?
7. Anthropic's terms on automating claude.ai.
8. Plan usage for the coordinator and threads.

## Page signals for sending (measured 2026-11-02)

| Signal | Meaning |
|---|---|
| `data-entry-key` inside a `transcript-row` | The message's stable id: `cmsg_…` once the server has it |
| `cmsg_pending_<uuid>` | Your message, shown by the page, not yet confirmed. It also marks a message queued behind a coordinator's turn |
| `provisional:…` | A reply being written |
| `data-index` | Position only. It changed from 256 to 195 on reload, so it can't identify a row |
| `data-perf-row-streaming="true"` | The row is live. On Claude rows the text then includes status words |
| Send enabled with an empty draft | The page is still finishing the last send. A click typed into this window does nothing, and it doesn't stop the reply |
| Send goes disabled to enabled after typing | The page has taken the words. A click here always took |
| No Send with an empty draft | A coordinator's turn is running. Typing brings Send back |
| The words return to the draft after a click | The send failed. Offline, the page retried for about 11 s, restored the draft and showed an error toast |
| `code-prompt-stop` | The Stop button, a test id of its own: why Send is absent during a turn |
| `[data-row-decoration] [role="status"]` in a sidebar row | A project's mark: running or unread. Only the label tells them apart, and it follows the language |

A message sent during a coordinator's turn is delivered after that turn, even when the tab has moved to another project.

### Cloud threads and marks in other projects

Tested 2026-11-03 with a real cloud thread in fjord-test-a while another tab sat on the projects page. The Code recents (live
through `sessions/watch`, with `data-attention` and `data-shimmering`, even hidden) list no project threads. The other tab's sidebar
mark stayed "Running" while the thread was waiting on its question; its unread mark did clear when the thread was read elsewhere.
So no page shows other projects' cloud threads live. In Seen, 126 threads were local and 15 cloud, all 15 in test projects.

The sidebar mark is live only for the open project. A reply finishing in another project showed no mark after 80 s; marks seen on
other projects came from the page's load. Live cross-project reading of cloud threads still has no cheap signal.

### Where the Router tools act (mapped 2026-11-03, nothing submitted)

Pages and menus:


- **New project** (Projects page button): a dialog with Name (text input), "What do you want to work on?" (textarea, optional),
  and Context: Add repository, Add a file, Add a folder (uploads through a file picker), Add a Google Drive folder. Create is
  disabled until a name is typed. The dialog has no test ids and no `<form>`.
- **Project settings** (header "View options" menu, then Settings; a dialog, `?overviewTab=settings` doesn't open it):
  - General: name (max 200), "What do you want to work on?" (goal, 8,000 chars), coordinator and thread models, thread effort,
    auto-continue, Pause, Restart, Archive.
  - Memory: **Project instructions** (a CLAUDE.md for every new thread, 16,000 chars) and Auto memory (Claude's own notes).
  - Environment: Project repositories (Add opens a searchable list of your GitHub repos), cloud environment, Let Claude use
    your device, **Pre-approved folders** (Add lists only folders this device has already connected), Use worktrees.
- The project menu (More options) holds Unpin, Rename, Archive, Delete.
- Structure (no words): the project header has two `button[aria-haspopup="menu"]` outside the sidebar and the transcript; the
  second ("View options") opens a menu whose only `[role="menuitem"]` (the other is a `menuitemcheckbox`) opens Settings, a
  `[role="dialog"]` holding `[data-testid="settings-top-row"]`. Its sections are the `nav button`s in order: General 0, Memory 1,
  Environment 2, Usage 3, Debug access 4 (the open one has `aria-current="page"`). Menus open a beat after the click.
- Memory's instructions are the dialog's `textarea[aria-labelledby]`. Typed words save **on blur** (`PATCH …/config`), with no
  Save button; a reopened dialog read the saved text back.
- Environment: `[data-testid="project-preapproved-folders"]` holds the folders' Add (`button[aria-haspopup]`), whose popup lists
  this device's connected folders as `[role="option"]` (text = the path); added ones are `project-preapproved-folder-row`, the
  default marked by `project-preapproved-folder-default`. Repositories' Add is the dialog's first `button[aria-haspopup="dialog"]`:
  a popup with a `combobox` input and `[role="option"]` rows whose text is `owner/name`, `aria-selected` for chosen ones.
- Escape closes the whole settings dialog, not only an open popup.
- In a hidden tab (no animation frames) a closed dialog or popup keeps `data-closed` and `data-ending-style` for good, and a list
  ignores a press on an option that isn't highlighted, and Enter too: arrow keys to highlight it, then a press, choose it (measured).
  The repo picker saves on the choice (`PATCH …/config` with `default_source_urls`); pressing a chosen option removes it.
- A chosen option's text ends with a check glyph (a private-use character, `\ue03b`).
- Every message key starts with its project's id: `cmsg_01ALdwr3…` belongs to `chan_01ALdwr3…` (649 rows checked). After an in-page
  address change, the transcript can show the previous project's rows for a render (30 such rows were recorded under the wrong project).
- New project's name input has no `type` attribute. A project being created shows as `chan_pending_…` until the server answers.
- The settings dialog shows the values it opened with. Opening it fetches `…/config` (instructions, repositories, folders) about
  0.2 s later, but that open keeps the old values; the next open shows the fetched ones. The goal (the project record's `topic`) stays
  as the tab last knew it: neither a second open nor arriving on the project again (which refetches the record) refreshed it.
  Measured with a change made from another tab.
- Saves: the instructions save as the field is left in a shown tab, but in a hidden one only when the dialog closes; the goal saves
  when the dialog closes (a write to the project record, then a refetch). An unchanged field saves nothing. Resource timing shows each
  request with its status, so the server's answer to a save is observable without calling anything. A refused goal save (a 400) left
  one request and no refetch; an accepted one is followed by a refetch of the record, so the first request after the change is the
  save's answer. The page is optimistic: after a save the server refused (a 500 faked in the page),
  the next open showed the refused value; the fresh fetch showed the server's.
- The New project button has no test id and no popup marker; it is the one text button in the row of the page's `h1`.
- The header's Threads panel lists the open project's threads by state: waiting on you, idle, resolved.

### The "open Claude" prompt (read in the client, 2026-11-03)

It is claude.ai's project-link handoff, not a fault. When a **project link** (`/code/project/…`) is the page Chrome lands on,
the page sets `window.location.href = "claude://claude.ai/code/project/…"`, so Chrome asks to open the Claude app, and a toast
says links like this open in the desktop app, with **Keep in this browser**. It fires only when all hold: Chrome on macOS or
Windows; the desktop app is known to be installed; the local preference `code-project-links-keep-in-browser` is not set (the
toast's button sets it, for the whole profile); the tab is visible, and becomes so within 10 s of the load (a hidden tab waits,
and after 10 s it no longer hands off). Navigating inside the page never triggers it; only a fresh load of a project link does.
Accepted with "always", it brings the Claude app forward each time. Fjord's tab loaded a project link after a Chrome restart,
while visible: that was the trigger.
