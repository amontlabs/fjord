# One channel into Claude

Status: agreed and tested live, 2026-10-23. From independent proposals and cross-critiques by Fable and GPT-6.1 Sol
(`/tmp/claude-app-research/notes/{fable,sol}/{proposal,critique}.md`), then live spikes. Research: `session-wake.md`.
Supersedes the relay session in `session-wake.md`.

## The rule: one path for your words

Every message of yours goes the same way, whether the target session is running or asleep:

1. Fjord gives a signed order to **the plugin of any session the Claude app is running** (the "carrier"; not the target).
2. The carrier's plugin calls the app's own send tool, `$.mcp.call("ccd_session_mgmt", "send_message", { session_id,
   message })`, with Fjord's signed message as the text. No model turn: the plugin calls it, Claude in the carrier never
   sees it.
3. The app delivers it to the target. Asleep: it starts the target's Claude Code with it as the first prompt (a user
   start: the app's cap of 21 doesn't stop it). Running: it hands it over, queued behind a turn under way.
4. The target's plugin checks the signature and puts **your words, and only them**, in Claude's place:
   - asleep, first prompt: `prompt.submit` rewrites the prompt to your words; the app's desktop guidance that came with it
     goes as `context`;
   - running: `session.receive` consumes the message and submits your words with `$.prompt.submit({ asUser: true })`.

Claude reads your words as typed by you, and the app shows them as an ordinary message of yours: no "Received message
from…" row, no warning (verified: `wake test one path`, both cases).

## Everything else

| What | How |
|---|---|
| Stop, interrupt, cancel | Order → the target's own plugin (it is running when there is a turn to stop) → `$.turn.abort` |
| Forms, permission prompts | Unchanged for now (hook process, Bash watcher) until a plugin-only path is proven |
| State | The plugin's presence and events, as now |
| New local session | Bootstrap + `claude://resume` (the app's import link), then its first message goes by the one path |
| Open a session for you | `claude://…/epitaxy/local_<id>` |
| New session on an SSH computer | `claude://code/new` prefill, you press Send (the app's rule) |

Orders reach a plugin through the existing signed inbox files (a running plugin polls them).

## Which session carries

Any local session running in the Claude app with Fjord's plugin up, not the target. Prefer an idle one, then the most
recently active; try another if one fails. With none running (right after the Claude app relaunches), the app is under its
cap and starts sessions on its own again: Fjord opens the target with its link (the app starts it), then the target's own
plugin delivers. That switches the Claude window once; usually a session is running already.

The carrier keeps no trace in its conversation or in the app's view (verified). The app records a delivery receipt in its
own session record (bookkeeping, never shown to Claude). The target is flagged `peerMessaged`, which only changes
permission auto-approval for scheduled-task sessions.

## What goes

- The relay session and everything for it: `RouterRelay`, its folder, role, prefill, title, "Start it", the relay's model
  turn and its SendMessage gate, and the wake-then-deliver two-step (`fjord-wake`, the dropped prompt).
- The headless `claude -p --tools SendMessage` sender (`RouterSender`'s peer path) and its CLI lookup.
- The 30-minute held start and the 30 s wait for the app to start a session on its own.

## What stays (and why)

- **The import link** for new sessions: `start_session` refuses turns that aren't the person's own in 3.1623.0.
- **The deep link to open a session**: `ccd_window.open_session_in` only works on the caller's own children.
- **SSH prefill and your Send** for new sessions on computers: the app requires it.
- **Forms machinery**: plugin hooks have a 10 s budget and `tool.check` can't hold a native dialog open; to be proven
  before anything is deleted.

## Operations

Each message has a nonce and a signed payload. Fjord persists `{nonce, target, kind, body hash, state}` before giving the
order. States: **waiting** (persisted, ordered), **sent** (the target's plugin acked and its turn started), **unsure** (no
ack and the process is gone: resolved by asking the target's plugin, never by sending again), **refused** or **needs you**,
with the reason. The app's own receipt says "not delivered … did no turn" for a running target whose plugin consumed it:
the target plugin's ack, not the app's receipt, says it went. A new session's id is persisted before its bootstrap, so a
retry reuses it.

## Live checks

1. **Passed 2026-10-22.** A plugin's `$.mcp.call send_message` from an ordinary session starts a sleeping one; the
   carrier's Claude and conversation are untouched; asked afterwards, neither session's Claude knew of the other.
2. **Passed 2026-10-23.** Carrying the words: asleep (rewritten first prompt) and running (`session.receive` + `asUser`):
   Claude said both were typed by the user; the app shows both as ordinary messages of the user's.
3. To do: a new session at the cap end to end; carrier and target in different permission modes; no session running after
   a relaunch; a sleeping SSH session.
