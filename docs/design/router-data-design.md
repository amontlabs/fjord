# Router: data design

Proposal, 2026-11-02, built as a POC in `poc/router`. Test results and how Projects works are in
[router-redesign.md](router-redesign.md) and [projects-internals.md](projects-internals.md).

## The rule

**Claude owns the work. Fjord owns only what it saw, what it meant to do, and what it told you.**

Nothing is done until Fjord sees it done. Words from a coordinator are never proof.

## Five tables

| Table | Holds | Kind |
|---|---|---|
| **Seen** | Every observation: time, source, what, fields. Unreadable means `unknown`, never `false` | Append-only |
| **Board** | Projects and threads right now | Rebuilt from Seen; safe to delete |
| **Intents** | What Fjord should do: tool, exact words, target, proof, status, attempts, cause | Fjord's truth |
| **Told** | Which facts you've been told | Fjord's truth |
| **Notes** | Your short routing preferences | Yours |

Decisions are Intents with their context hash and any correction attached, so one row is the outbox, the history, the undo
stack and the eval data.

## Four steps

1. **Look** (reads the world, writes Seen): local files, hooks and the visible page.
2. **Decide** (Board, Notes, recent Intents → Intent or answer): an explicit target uses no model. Otherwise one model call.
3. **Do** (one Intent → one small page step or plugin send).
4. **Tell** (Board changes, minus Told → a brief).

Building the Board, its changes and the Router's context are pure functions, so they can be replayed on logged data.

## Intents carry their proof

Every Intent says what Look must see: a new row from you with these words, under a real message id. A row the server hasn't
confirmed has a pending id and doesn't count, so `confirmed` means the server has the message.

1. Before typing, record the message ids already in the place.
2. Type in the real composer. Wait for the page to settle, then click Send once it enables after the typing.
3. An empty draft after the click means the page took the words. Never resend after that.
4. If the page gives up, it puts the words back in the draft: send again, at most three attempts, then show `failed`.

A taken message blocks nobody, so a message queued behind a coordinator's turn doesn't hold up the next send.

## Tell once

A fact's key is the change, not the text: `(thread, finished, turn)`. A thread's post and the coordinator's repeat are the same
fact. The brief uses whichever arrives first, and a later version updates it quietly. A coordinator message tells you only if
it has a decision or has no matching thread change.

Source trust: local process and files, then the thread on the page, then coordinator chat.

## Router context

A pure query with a hard size limit:

- Notes, overwritten by topic, never appended.
- Every project: name, cloud or local, purpose.
- Live threads, one line each: running, needs you, unread, or touched in the last 24 h.
- The last 8 messages, with the corrected destination when there was one.

Older detail stays reachable through `read_thread`.

## Failures

| Failure | What happens |
|---|---|
| Send didn't work | Intent stays unconfirmed, retries, then shows `failed` |
| Page changed | Field is `unknown`, Intents pause, one card tells you |
| Sign-in expired | Intents pause, resume after sign-in |
| Mac slept | On wake, Look runs first, then proofs, then retries |
| Claude app closed | Its local threads wait for it (`waiting_app`); replies to them pause, and go on when the thread is back. After the app returns, a thread still gone gets one more 20 s wait, then counts as stranded |
| Thread lost its process | Marked `stranded`. A reply goes to the coordinator as one project send, asking for a new thread in the same folder that continues it (`continues` ties them) |
| Coordinator claims something | Stored in Seen as a claim; state doesn't change |

## Choices between the advisors

- **Status questions go through the model.** Skipping it would need word rules, which Fjord avoids.
- **Setup stays a Router tool,** as the owner wants, but only on explicit request. Permission grants stop at one button in
  Fjord that shows the grant.
- **Notes change only when asked.** Corrections stay in Intents and can suggest a note.
- **The key is the change, not a text fingerprint.** Paraphrases can't break it.
- **Plugin sessions aren't a special case.** The plugin is one more Look source and one more Do route.
- **Cut for now:** search, Fjord's own mark-read (Told covers it), and any cached page state beyond the Board.

## Sign-in: a Chrome extension

Decided and tested 2026-11-02. The extension works inside the owner's already signed-in browser, so Fjord never hosts a login. It
keeps one pinned background tab, talks to a local bridge, and reads and types by test id.

| Test (hidden tab, never shown) | Result |
|---|---|
| Page finishes loading | Yes, thread list read in 5 s |
| Send through the real composer | Worked first try, 3.5 s, reply received |
| 30 minutes in the background | 7 reads in 0.1–0.2 s, 3 sends in about 4 s, all first try |
| New thread appears with no reload | Within 6 s |
| Tab state | Never discarded or frozen |

Chrome slowed the tab's timers to once a minute, as expected, so Fjord's code must not depend on page timers. Commands from
the extension's background worker weren't affected.

Zen failed: the Code page didn't finish rendering in a tab that had never been shown. Safari would need a packaged app.
One run in one Chrome profile, with Chrome open and the Mac awake. The test bridge has no key yet, so any local app could use it.
A real version needs one.

Chrome's profile picker: the extension runs only once a profile is open. So onboarding turns the picker off ("Show on startup") in
the profile that holds the extension, and Fjord says so when Chrome runs with no tab connected.

Cloud threads of other projects: no page shows them live (tested with a real cloud thread). They are as of the last visit, and the
brief states that age. Local threads stay live through files. So far every real thread of the owner was local.

## POC

`poc/router`: a Python daemon, a Chrome extension and 297 offline tests. Everything moves by events, so nothing on the page or in
the daemon polls.

```
page -> content.js (MutationObserver) -> worker -> native host -> Unix socket -> routerd.py
```

Measured live on test projects, background tab:

| Case | Result |
|---|---|
| Acknowledgement, Jev only | 0.28 s |
| Click after the decision | 50-290 ms |
| Server confirmed, same project | 0.5-0.7 s |
| Server confirmed, with a project switch | 0.6-0.9 s |
| 7,154-character message | 1.8 s, one attempt |
| Multi-line, Markdown, punctuation | One attempt |
| Sends in the last six live benchmark runs | 97 of 97 first attempt |
| Sent right after a tab reload | 0.6 s, one attempt |
| Message queued behind a coordinator, tab moved away | Delivered, proved on the next visit |
| Offline | `failed` after 3 attempts, 35 s, nothing leaked |
| Chrome restart | Message waited as `paused`, sent within 6 s of the profile opening, no extra tab |

Routing, dry, on the 60 tested messages: 55 right, 3 wrong, 2 asked, median 0.20 s, no real request silenced. Again on 2026-11-03 with
the setup question added: 55 right, 4 wrong, 1 asked, median 0.20 s (Jev 31, Sonnet 25, silent 4); the shift is one borderline
message (Sonnet at 0.55) answered rather than asked. Jev decides alone when
it's at least 0.7 sure; Sonnet decides otherwise and asks under 0.5. Choosing that bar on the same 60 messages flatters the result.

Router tools (`create_project`, `set_instructions`, `set_goal`, `add_repo`, `preapprove_folder`) are intents like sends: Jev answers a
second yes/no question, "does this ask Fjord to set up a project?"; at 0.5 or more the message goes to Sonnet, whose `tool` action (or `core.tool(name, **args)`, with no model) makes the intent. Each acts once on the page, is proved by a
later read of the settings (or the projects list for a create), keeps the old value as `before`, and never acts twice: with no proof it reads once
more and fails as "done, but not confirmed", and a later read can still confirm it. `preapprove_folder` waits for `core.confirm`. Their page
structure is in [projects-internals.md](projects-internals.md); the commands are in `poc/router/EVENTS.md`.

Reviewed by Fable for ten rounds until one found nothing worth changing. Findings per round: 11, 9, 4, 4, 4, 2, 2, 1, 1, 0.
After the tools, ages and stranded threads (2026-11-03), reviewed again each round by Fable and by a line-level reviewer, with every
fix checked live: findings per round about 30, 20, 15, 10, 7, 4, 2, 1, then none from either. Final live run: 27 of 27 sends on the
first attempt, tools confirmed by the server's answer in about 5 s.

## Tools, measured live (2026-11-03, Fjord's tab hidden, test projects)

| Tool | Result |
|---|---|
| `create_project` (name and goal) | Confirmed in 0.42 s |
| `set_goal` | Confirmed in about 4.9 s by the server's answer to the save; a goal the tab already shows, 2.0 s, said as the tab knows it |
| `set_instructions` | Confirmed in about 5 s by the server's answer and a fresh read |
| `add_repo` | Confirmed in 3.6 to 7 s |
| `preapprove_folder`, folder not connected | Refused after confirm in 0.44 s: "connect ~/… in the Claude app first" |
| A setup request in words ("set the goal of fjord-tool-test to: …") | Jev's setup question 0.91, Sonnet picked `set_goal`, confirmed in 9 s |
| A tool and a send to another project 0.3 s apart | Both confirmed in 2.6 s (before the fix, the send waited for its 300 s look) |

Sends after today's changes (history `open`, row filter), four benchmark runs: 34 of 36 on the first attempt. Two clicks, each about
0.7 s after a send to the same project, were ignored by the page; the retry at 20 s sent them once (no duplicate). Switch median
0.75 to 1.0 s, same project 0.57 to 0.71 s.

Jev's setup score, dry: 16 setup requests in the owner's style scored 0.54 to 0.97 (median 0.93); the 60 routing messages scored
median 0.07, and 4 of them, plus 4 of 10 near misses ("add the repo link to the lcu readme"), passed 0.5. Sonnet, dry, gave all 16 the
right tool and arguments and sent all 8 near misses to their project. The bar is 0.5 because a missed setup request would reach a
coordinator as a message; the cost is one Sonnet call (about 7 s) on about 11% of other messages.

Every change is proved by the server's answer to the page's own save request (its status, in resource timing), because the page
shows a refused save as if it took.

## Rejections (faked server answers in the page, 2026-11-03)

| Server answer | What the page does |
|---|---|
| 429, 500, 503 | Retries 4 times over about 10.5 s, then puts the words back and shows "Couldn’t send the message" |
| 400, 401, 403, 404, 413 | Puts the words back at once (0.2 s) with the same notice |

The notice never says why. Fjord treats words back in the draft as a failed attempt, tries again, and after three fails with the
page's notice quoted in the cause. A project deleted or archived leaves the Board when the projects page lists without it.

## Open

- A real folder grant works: `~/code/spikes/fjord-e2e`, served by a terminal Remote Control, was granted live in 2.6 s (the folder
  list needs a press 700 ms or more after it opens; the save is `…/remote-control-preapproval`, its HTTP status the answer). An earlier
  note that such folders aren't pre-approvable was wrong. Granting one still needs the owner's OK for that folder.
- Tools are being made faster (one fresh read merged into the act, the save's answer as the proof).

Settled, not issues (advice from Fable, Gemini and two flash models, 2026-11-03): cloud threads in other projects are shown with
their age, and refreshed whenever a message goes to that project (the owner has had no real cloud threads); a goal changed elsewhere
is read as the tab's copy and said so; the Claude app closing and Mac sleep are handled by the pause and the clock-jump rule; the
rare ignored click is covered by the 2 s retry.
