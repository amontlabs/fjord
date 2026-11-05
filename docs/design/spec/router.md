# Router: a dispatcher, not a chat

Agreed with the user (2026-10-10). Replaces the single long-lived Claude Code session with a transcript.

## Principle
Every trigger is a typed event that runs a short workflow. Deterministic rules first, Jev second, a Claude run (Haiku) only when judgment or tools are needed. Each run builds its own context; there is no transcript and no resume. Every run appends one entry to the decision log, which is the history in the Router window's drawer.

## Surfaces
- Router: your claude.ai projects and their threads, replies to a card's local session, and Fjord itself (app tools, changes shown as cards with Revert). Never GitHub. It starts no sessions and divides no message.
- Inbox actions: the Router (a prompt, routed as a message of yours) and GitHub (comment, re-run checks).

## Workflows
### A. From Claude Code (session asks, plans, finishes, is stuck, works)
Deterministic, as today (RouterFeed): cards, banners, the live Working line. The feed is the subscription.
- A session cannot message the Router: with no long-lived process there is no peer named "Lookout" to receive it (Claude Code delivers `SendMessage` over a per-process socket it lists in `~/.claude/sessions/<pid>.json`, a private protocol Lookout does not imitate). What a session wants from you reaches you as its own cards (question, plan, done, stuck).
- Working cards are live, with a 1–2 sentence explanation of what is happening, and a 1–2 sentence summary of what the turn did when it ends. Source: the session's activity stream and the Claude app's own summary when present; Haiku fills gaps, only on change (turn start, at most every ~30 s while tools run, turn end). The end-of-turn line is the card's text in the history and context for later runs.

### B. You type
A message goes to one place, decided once (docs/design/router-redesign.md, "How a message flows"; RouterDispatcher.swift). Each message is a run of its own and one entry of the decision log; its stage shows on its pill over the composer.
1. No model: a reply armed on a card goes to that card's local session (a signed message, as your own prompt); a tagged claude.ai project or thread (a typed `@project`, a target pinned over the composer) goes there. The text is your own bytes, never a model's rewrite. Tags never divide a message.
2. Otherwise the project decider (RouterProjectDecide.swift), among your claude.ai projects and their threads only: Jev first, with each place's option carrying what Sonnet would read, taken when his top choice is a place at 0.7 or more; else Sonnet with the full board, acted on at 0.8. Measured on real moments (docs/design/router-redesign.md, "Routing on real moments"). Its result is a thread (the words go there), a project (its coordinator picks or starts the thread), new work in a project, a new project, an answer here (a question about the board, or an acknowledgement: nothing is sent), or an ask.
3. Unsure: "Where should this go?" under the message with the likeliest places as buttons. Nothing is sent until you pick; only a click picks, and text typed meanwhile is a message of its own.
4. No project fits: the pill under the composer proposes a new one (name, folder, repo, one line of instructions), live and with no modal. Typing revises it ("call it fjord-ios, no repo"); Return creates it through the engine and delivers the message there; Escape puts the message back in the composer, unsent. The folder grant is asked only on that Return.
5. A Claude run (Haiku) only for changing Fjord and questions about state: a fresh `claude -p` with a context built for the run (live-state snapshot, last 10 decisions, the message), only the tools that intent needs, a typed result (`--json-schema`).
- History: one entry per message with its place, its words and its outcome (sent, failed, cancelled, corrected). Cancel, Send elsewhere and Edit and resend act on it; a correction is kept as an example for the decider.
- No word lists or regexes interpret a message: Jev or Sonnet decide, or a button does.
- Removed: starting sessions, forks, dividing a message between places, waits on another place's answer, the Router's choice of a session, model and effort for a session.

### C. From an inbox action ("Send to the Router")
A message of yours (logged, "<Category> · …" in the history) with the thing tagged, routed as B is among claude.ai projects. It is unattended: when the decider isn't sure, or can't be asked, nothing is sent and the ask waits for you (no fallback). Its run follows the message: waiting on you, sent, or failed; the history chip says so.

## Memory
The decision log: one entry per run (trigger, decision, what was done, outcome: sent, changed, reverted, corrected). The last 10 entries are part of every Claude run's context; the decider reads what you last told each place. Entries where the user chose something other than the suggestion are labelled as corrections. Nothing else.

## Cards: addressed
- Explicit: submitting a form, approving or sending back a plan, "Archive".
- Otherwise Jev decides, after any message that touches a session with open cards, per card: resolved → history ("addressed by your message"); partly (e.g. 1 of 3 questions) → stays, showing what is left; not → stays. Unsure → stays.
- Reopen from the history puts a card back in Needs you.

## Tiers: whose move is next (agreed 2026-10-11, RouterTiers.swift)
1. Needs you: the move is yours. Question, plan, OK, asks, stuck; Finish up (done, but a last step is left to you: merge, relaunch and try it, run something, test by hand); a wait that is over, until you tell it to continue. A wait on you is an ask.
2. Waiting: the move is something else's (CI, a deploy, another session, someone else's review, a rate limit).
3. Worth a look: done, nothing to do, but it tells you something (a caveat, a risk, a decision it took alone, a claim it didn't check, a finding). Unsure, a finished turn is this, never quieter.
4. Done: done, nothing to do, nothing to tell. It goes straight to the history (`settled`), unread until you click it, "Got it" or "Mark all read".
5. Working: the live rows.

Jev decides 3 and 4 and Finish up with two yes/no questions in the triage's one call: `userStep` (a concrete action left to the user now) and `notable`. A sure step (p ≥ 0.6) is Finish up, trivial or not; the history takes a turn only when Jev is sure it is done (p ≥ 0.7), a step and a note each at most 0.2 likely, and it claims nothing it didn't check; otherwise Worth a look. A trivial turn settles only when done (not partway, not unverified).

## Briefs (RouterBrief.swift)
Every card is told in your words' style: one Haiku call once its triage lands (a question or plan when it comes, a wait when it is over), saying what is needed from you (Needs you), what it waits on (Waiting), what is notable (Worth a look), or what was done (Done). Its input is the turn's final message, the card, Jev's triage and the form; nothing of it goes to Jev. Trivial finished turns keep Claude's own summary. Your style instructions (Settings, "How the Router writes to you") follow the fixed rules in the system prompt, for the briefs and the working sessions' summaries alike.

## Page
Bottom-anchored, the more it matters the nearer the composer: the history (the decision log and addressed cards, one line each, expandable; finished turns unread highlighted), Working (live lines) and Waiting under it, Worth a look (quiet, the first three), Needs you (prominent, one card open). The composer has inline @project pills. The badge counts Needs you (amber) and Worth a look (blue); the history's unread lines count for nothing.

Canvas (beta): Now can also be drawn as a canvas, picked from the top bar's List / Canvas switch (tagged Beta) and kept across launches (router-canvas.md). The list is the default, and the canvas leaves it exactly as it was. Each project folder is a frame on a ground you pan and zoom, its sessions under Needs you, Worth a look, Waiting, Working and Done, joined by lines to the same cards; nothing is open until you click, one at a time. History stays beside it. Your messages wait over the composer with what the Router is doing to them, the questions it asks back under them; once sent, each flies to the card of the session it went to, the canvas panning there first, and shows "You: …" under it for a few seconds. One the Router answered itself fades, and its answer is in the history.

## Removed
The Router's own session routing (starting sessions, forks, divided messages, model and effort for a session), the long-lived process, `--resume`, the transcript (`chat`), peer turns and the ability of a session to message the Router, the single serial queue (runs are independent), the role prompt's header grammar. What stays of the old file: `changes` (the records behind change cards); old `chat` and `claudeSessionID` keys are read (changes migrated) and dropped on the next save.

## Phases (each tested and committed on its own)
1. Decision log, and the history built on it.
2. Typed runs: dispatcher → rules → Jev → Haiku; the ask-back card.
3. Inbox actions send their prompt through the Router as a message of yours, tagged with its origin.
4. Superseded: model and effort for sessions the Router started, and sessions started by the Router at all (messages go to claude.ai projects only).
5. Jev decides what a message addresses.
6. Live Working explanations and end-of-turn summaries.
7. Remove the long-lived process, resume and transcript.

Research, what was tried and what was not enough: router-research.md.
