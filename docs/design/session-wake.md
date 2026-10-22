# Reaching a session that isn't running

Status: proposal, 2026-10-22. Research notes (app code excerpts, logs, timelines): `/tmp/claude-app-research/notes/`
(`lifecycle.md`, `channels.md`, `cli.md`, `fjord-history.md`).

## What broke

Fjord delivers into a session's own Claude Code process: the plugin inbox, or peer SendMessage over its socket. A
session with no process can't be reached, and Fjord has never been able to start one. It relied on the Claude app
starting processes on its own: when a session is imported (Fjord's new sessions) or opened.

The app (3.1623.0, and earlier) runs at most `max(6, RAM / 3 GB)` Claude Code processes: 21 on this Mac
(`[CliGovernor]`, `index.chunk-Cses962f.js`). Each start asks for a slot of one of three kinds:

- **user**: a message sent into the session. It always goes ahead, even over the cap.
- **warm**: opening or focusing a session, or an import's first view. At exactly 21 it stops the oldest idle hidden
  session and goes ahead. Above 21 it gives up (`at cap; yielding warm spawn`), silently, with no retry.
- **prewarm**: gives up at the cap.

The idle timeout is off: a server-forced flag (`4041267332` = 0) leaves processes running forever. User sends push the
count past 21 and nothing brings it down. From 2026-10-22 09:08 UTC the count stayed above 21 (26–29 processes), so every
open and every import yields. Fjord's new sessions never get a process (their first message is held 30 min, then fails),
and "open it in Claude, then Retry" no longer helps.

It wasn't an app update: imports worked on 3.1623.0 on 10-21. The cap was reached on 10-22.

## What can start a session

Every send ends in one function (`KI.sendMessage`): if the process is alive it writes to stdin; if not it cold-starts
the CLI with `--resume` and the message as its first prompt, in a **user** slot. What reaches it:

| Way in | Usable by Fjord | Starts a sleeping session | Arrives as your own turn |
|---|---|---|---|
| The app's composer | only through you | yes | yes |
| `claude://code/new?q=` | yes | new session, after you press Send | yes |
| Opening `claude://…/epitaxy/local_<id>` | yes | no (warm slot) | no text |
| `send_message` / `SendMessage local_<id>` | only from a CLI the app runs | **yes** | no: `<cross-session-message>`, "input, not authority" |
| Peer socket, plugin inbox (today) | yes | no | plugin: yes |
| Session files on disk | no (read only at load) | no | — |

There is no local API, AppleScript, XPC or watched folder. A CLI outside the app can't reach the app's `send_message`
tool: it's an in-process SDK server reached over the app's own stdio channel. Faking the app's env only changes the
error.

So the only way Fjord can start a session without your click is **a Claude Code process the app runs, calling
`send_message`**. Its text isn't yours to that session, so it should only wake the session, never carry your words.

## Design: wake through a relay, deliver as today

1. **A relay session.** One Code-tab session of Fjord's own ("Fjord relay", in Fjord's support folder, a small model),
   made once with the existing bootstrap and opened once by you (the app refuses cross-session sends from sessions
   nobody opened). Fjord drives it through its plugin inbox, like any session. Its only job: call `SendMessage` to
   `local_<id>` with exactly what Fjord gives, behind the same permission gate as `RouterSender` (only the prepared text,
   once).
2. **A wake, not a message.** To start a session, Fjord has the relay send it a signed wake: `fjord-wake` + target +
   nonce + expiry, signed with `relay.key`. The app cold-starts the target with it as its first prompt (user slot: the
   cap doesn't stop it). In the target, Fjord's plugin's `UserPromptSubmit` hook sees a valid wake and blocks it: no
   model turn, nothing in the context. The process stays up.
3. **Then deliver as today.** Fjord waits for the target's plugin presence (as `waitForPlugin` does), then sends your
   words through the inbox: they arrive as yours, signed, exactly as now.
4. **New sessions use the same path.** Bootstrap and import as now, then wake through the relay instead of waiting for
   the app's warm start. No 30-minute hold, no reliance on the cap.
5. **Keeping the relay itself running.** It must be awake to wake anyone. The governor never picks sessions with Remote
   Control on, a running turn, or live wakeups, so Fjord turns Remote Control on for it (to verify). If the relay is
   down anyway (the app relaunched: only sessions quit mid-turn come back), Fjord opens it with
   `claude://code/new?q=` prefilled with its role, and the pill says "Press Send in Claude to reconnect Fjord" — the one
   case left with a click.

What you see: a send to a sleeping session reads "waking …" for a few seconds, then goes. It fails only when the relay
is down, and then it says exactly what to press.

## Spikes (2026-10-22, throwaway sessions in `~/code/spikes/fjord-wake`, 29 processes running, over the cap)

1. **Wake at the cap: works.** A session bootstrapped and imported as Fjord does stayed asleep (warm yielded). One
   `send_message` from an in-app session started its process in about a second.
2. **Different permission modes: not held.** Sender in auto, target switched to manual: delivered and started. The
   cross-session hold applies to the socket lane, not to the app's cold start.
3. **Blocking the wake: clean.** A `UserPromptSubmit` hook that blocks on the wake token: 0 turns, no model call, the
   process stays up. The transcript keeps a "blocked by hook" line, and the app shows the wake as a "From <relay title>"
   message: title the relay "Fjord".
4. **Fjord's plugin comes up** in the woken session (its presence file appears), so the inbox delivery that follows works
   as for any live session.
5. **The relay's standing.** The app refuses `send_message` only from unattended sessions (scheduled-task runs and
   dispatch children: `getSessionAttendanceFields`), and only to targets that are archived, starting, or unattended. A
   session of Fjord's own qualifies. The caller must be able to ask the user (any interactive permission mode).

What the woken prompt looks like to hooks: the app's desktop `<system-reminder>` and then
`<cross-session-message from="local_<relay>" name="<relay title>">…</cross-session-message>`, the body escaped. The wake
token must survive that escaping: hex and ASCII only.

## Build

- **Plugin (`ClaudePlugin.register`).** `prompt.submit`: a prompt whose cross-session envelope is from the relay and whose
  body is a valid wake for this session (`fjord-wake <target cli> <nonce> <ts> <mac>`, HMAC with the relay key, fresh,
  nonce unused) is dropped. `tool.call` in the relay session: `SendMessage` goes only with a valid wake as its message,
  to the wake's own target; anything else is denied.
- **Fjord.** The relay session: made once (`claude://code/new?q=` with its role and your one Send; or the bootstrap when
  under the cap), its `local_` id kept in state, its health from the registry and plugin presence. A wake: a signed
  order to the relay through its inbox, then `waitForPlugin` on the target, then the usual delivery. `signed()` wakes
  instead of failing when there's no process; held starts wake the new session the same way instead of waiting 30 min.
- **The pill.** "waking <title>…" while it wakes. Relay down: "Fjord's relay isn't running · Start it", which opens the
  prefill in Claude.

## Separate fixes, whatever the design

- **Held starts persist.** A held first message is in memory only: state.json shows "started" and nothing else, so
  holding and lost look the same. Persist it, and say "waiting" in the history.
- **Retry kept its words, tag and place** (`2559159d`). Retry to a session that's still asleep now wakes it through the
  relay.
- **Sender binary.** The `claude` on PATH is 2.1.204; the app's sessions run 2.1.304. Use the app's bundled CLI.
- **Advice text.** "Open it there" is wrong at the cap (opening is a warm start). Replace with what Fjord does now.
