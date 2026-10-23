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
5. The target's plugin answers in its own inbox folder, `<nonce>.ack`: that is how Fjord knows it went.

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

Each message has a nonce and a signed payload. Fjord persists `{nonce, target, kind, body hash, state}` and **waits for the
write to reach the disk** before giving the order (a message that can't be recorded is not sent). States: **waiting**
(persisted, ordered), **sent** (the target's plugin acked), **unsure** (no ack in time, or an error from the app after it had the
message: resolved by the plugin's late ack, found when Fjord next starts, never by sending again), **refused** or **needs you**,
with the reason. The app's own receipt says "not delivered … did no turn" for a running target whose plugin consumed it, and
"no sign of starting" for one slow to start that can still pick the message up: the target plugin's ack, not the app's receipt,
says it went. The ack is written only once the engine took the words in (a prompt a hook beneath drops, or the engine rejects,
is refused). The target's ack file is removed only after the outcome it gave is on disk. A late ack found at the next launch
also updates the run in the history (delivered, refused or unsure), not only the operation.

A new session's id is persisted (`StartReservation`) before its bootstrap and followed through bootstrapped, imported and
delivered; a Retry of the message continues from the step the reservation reached, with the same session.

## What the build settled

- **The body survives the app's escaping.** The app's `kf` scrubs only a `<` that opens a tag it knows (and, across
  machines, turns `@` into a full-width one). Fjord's signed text is a header line and base64: neither occurs. Checked on the
  app's own function (extracted from its bundle) and by a test that no signed text holds `<` or `@`.
- **Answers.** The target's plugin writes `<nonce>.ack` ("ok …", or "refused: why" once the signature held; never for a
  forgery) in its inbox folder, for a message that came by the app as for one that came from the inbox. A carrier writes
  `<nonce>.taken` as it begins (the app answers a send only once the target's turn started, which a cold start makes long) and
  `<nonce>.ack` with the app's own words: `ok …`, `refused: …` only for what the app refused before handing the message to any
  session ("Message not delivered: …", no session named), and `unsure: …` for every other error and for a failed call (the
  session can still pick the message up, so no second carrier is asked). The app calls a running target's consumed message
  "not delivered": only the target's ack counts.
- **Withdrawing an order.** Fjord withdraws a carry order nobody has taken in six seconds by writing `<nonce>.withdrawn` and
  only then looking for `<nonce>.taken`; the carrier's plugin writes `taken` and only then looks for `withdrawn` (and answers
  `refused: withdrawn`, calling nothing). Whoever wrote first is seen by the other, so a plugin that read the order but was
  slow to check it never carries out a message Fjord called unsent.
- **A cold start with settings.** The engine refuses `$.command.run` inside a `prompt.submit` hook, so a first prompt with a
  model or effort can't set them there. Such a prompt is dropped (no turn) and its words submitted from the plugin's next look,
  after the settings, with the app's guidance ahead of the words in the text (a plugin's submit takes no context). Without
  settings the rewrite carries the guidance as `context` as above. A running target's settings are set from the next look too.
- **Which sessions carry.** The registry entry (`entrypoint: claude-desktop`, `status`, `updatedAt`) and the presence file
  (`carry-v1`, `turn`) of a live plugin: idle first, then most recently updated. A running target whose plugin is older than
  `carry-v1` is given its message in its own inbox.
- **Asleep.** A session with no process (and one Claude Code id) is signed for without its plugin being up; a session with a
  process but no plugin up is never sent to (it would read the message as a peer's).

## Live checks

1. **Passed 2026-10-22.** A plugin's `$.mcp.call send_message` from an ordinary session starts a sleeping one; the
   carrier's Claude and conversation are untouched; asked afterwards, neither session's Claude knew of the other.
2. **Passed 2026-10-23.** Carrying the words: asleep (rewritten first prompt) and running (`session.receive` + `asUser`):
   Claude said both were typed by the user; the app shows both as ordinary messages of the user's.
3. To do: a new session at the cap end to end; carrier and target in different permission modes; no session running after
   a relaunch; a sleeping SSH session.
