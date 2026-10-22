# One channel into Claude

Status: agreed design, 2026-10-22, from independent proposals and cross-critiques by Fable and GPT-6.1 Sol
(`/tmp/claude-app-research/notes/{fable,sol}/{proposal,critique}.md`). Research and spikes: `session-wake.md`.
Supersedes the relay session in `session-wake.md`.

## The rule

Fjord talks to Claude through **its plugin, which runs inside every Claude Code session**. Everything Fjord does to a
session is a signed order to that session's plugin, answered by an ack. Links are used only for what the Claude app
accepts from outside and nothing else can do.

| What | How |
|---|---|
| Your words into a running session | Order → the session's plugin → `$.prompt.submit({ asUser: true })`: they arrive as yours |
| Your words into a sleeping session | Order to **any running session's plugin** → `$.mcp.call("ccd_session_mgmt", "send_message")` with a signed wake → the app starts the target → its plugin drops the wake (no turn) → delivered as above |
| Stop, interrupt, cancel | Order → the session's plugin → `$.turn.abort` |
| Forms, permission prompts | Unchanged for now (hook process, Bash watcher) until a plugin-only path is proven |
| State | The plugin's presence and events; the app's own session list through the same `$.mcp.call` later |
| New local session | Bootstrap + `claude://resume` (the app's import link), then woken like any sleeping session |
| Open a session for you | `claude://…/epitaxy/local_<id>` |
| New session on an SSH computer | `claude://code/new` prefill, you press Send (the app's rule) |

No session of Fjord's own, no model turn for plumbing, no headless `claude -p` sends.

## What goes

- The relay session and everything for it: `RouterRelay`, its folder, role, prefill, title, "Start it", the relay's model
  turn and its SendMessage gate.
- The headless `claude -p --tools SendMessage` fallback (`RouterSender`'s peer path) and its CLI lookup.
- The 30-minute held start and the 30 s wait for the app to start a session on its own.
- Resolving "reachable" from the PID registry: the plugin's presence says it.

## What stays (and why)

- **The import link** for new sessions: `start_session` refuses turns that aren't the person's own in 3.1623.0.
- **Deep link to open a session**: `ccd_window.open_session_in` only works on the caller's own children.
- **SSH prefill and your Send** for new sessions on computers: the app requires it.
- **Forms machinery**: plugin hooks have a 10 s budget and `tool.check` can't hold a native dialog open; to be proven before
  anything is deleted.

## Operations Fjord keeps

Each order already has a nonce and a signed payload. Fjord persists `{nonce, target, kind, body hash, state}` before
writing it. States: **waiting** (persisted, queued), **sent** (acked and its turn started), **unsure** (claimed, no ack,
process gone: resolved by asking the plugin, never by sending again), and **refused** or **needs you**, with the reason.
Wakes are coalesced per target. A new session's id is persisted before its bootstrap, so a retry reuses it.

## Which session wakes

Any local session running in the Claude app with Fjord's plugin up, not the target. Preferred: one with Remote Control on
(the app never stops those), then an idle one, then the most recently active. Try another if one fails. With none running
(right after the Claude app relaunches), Fjord opens one known session once with its link (the app starts sessions on its
own again then, being under its cap); usually you've opened one first anyway.

The woken session shows the wake as a "From <waking session>" line and a "blocked by hook" note: no turn, nothing in
Claude's context. The app's guidance that came with it goes with the next prompt (`929d6dc3`).

## Live checks, in order

1. A plugin's `$.mcp.call` `send_message` from an ordinary session wakes a sleeping one: zero turns on both sides; note
   every visible row on both.
2. The same to a running target; and a sender and target in different permission modes.
3. A new session at the cap, end to end, under 10 s, your words as yours.
4. With no session running after a relaunch: the one-time open, then a wake.
5. A sleeping SSH session woken the same way.
