# Router: data design

> Superseded: Fjord now runs on T3 Code instead of Claude Code and claude.ai. See [t3-code-map.md](t3-code-map.md).

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

## One tab per project: measured cost (2026-11-04)

Up to 8 hidden, pinned, inactive watcher tabs (`autoDiscardable: false`) at the test projects' pages, beside Fjord's own tab, with
a structure-only script (row and thread ids, kinds, times; no main scan). Chrome 156 on macOS. Memory is the renderers' physical
footprint (`footprint`; RSS swung 400 to 570 MB with no change, from compression); CPU is renderer CPU time over the window, in % of
one core.

| Watcher tabs | Renderers | Footprint | Delta vs none | Idle CPU (all renderers) |
|---|---|---|---|---|
| 0 | 4 | 959 MB | | 0.35% |
| 1 | 5 | 1,245 MB | +286 MB | 0.07% settled |
| 2 | 6 | 1,599 MB | +640 MB | 0.55% |
| 3 | 7 | 1,877 MB | +918 MB | 0.3% settled (2.8% with a spike) |
| 5 | 9 | 2,560 MB | +1,601 MB | 1.0 to 2.3% settled |
| 8 | 12 | 3,550 MB | +2,591 MB | 3.3% over 4 min |
| closed again | 4 | 947 MB | -12 MB | 0% |

- Per tab: one renderer process each (same-site tabs did not share one), 286 to 354 MB, mean about 324 MB. Idle about 0.4% of a
  core per tab: every tab wakes once a minute together (0.2 to 0.5% over 30 s), and now and then one spikes to 3 to 8% for 15 s.
  Loading a tab costs about 40% of a core for 10 to 15 s.
- During a coordinator turn (5 and 8 watchers): each watcher of a project in the turn 8 to 15% for about 20 s; watchers of an
  idle project about 1%; Fjord's tab 35 to 52% (its existing cost). All renderers peaked at about 105% for 10 s, back under 1% in 20 s.
- Liveness: no tab was frozen or discarded. Watchers hidden 1.5 to 7 min saw test-b's reply 6.8 s after the send while Fjord's tab
  was on test-a; Fjord's tab saw that row 461 s later, when it next went there. Watchers hidden 6 to 15 min (past intensive
  throttling) saw every new row, streaming ones too, within 0.4 s of Fjord's tab: the page's updates come over the network, not on
  throttled timers.
- Projection, at 324 MB a tab, pessimistic 500 MB (real projects' longer transcripts; Fjord's own tab sits at 830 MB after a long
  session): 10 projects 3.2 GB (5 GB), 20 projects 6.5 GB (10 GB). Idle CPU 4% (10) and 8% (20) of a core, pessimistic double for
  the spikes; a turn adds 8 to 15% per watcher of that project.
- Caveats: test projects with short transcripts; replies of a few seconds; no thread was made, so no thread-row events were seen;
  idle windows of at most 15 min; on power, no Energy Saver freezing; a test-b watcher moved itself to the project's last thread
  (`?thread=`), so a watcher's address is the page's to change.

Read: live enough, CPU acceptable, memory too high to keep one tab for every project. One tab per project with a turn under way,
opened when Fjord sends and closed after a quiet spell, keeps the liveness for a few hundred MB at a time.

## Live project-activity signals (2026-11-04)

Hidden, pinned, inactive observer tabs on `/code/projects/browse` (its list and the sidebar) and `/code` (the sidebar only), and,
for comparison, on test projects' own pages. Each observer logged per project row, by its id (`a[href^="/code/project/chan_"]`),
its place, rows added or gone, and every element of the row as tag, class tokens and `data-*`, `aria-*`, `role` and `datetime`
attributes. It also logged its own fetches by path. No text was logged. Fjord's tab did the sends. There were 4 test sends:
a reply in test-a, a thread asked of test-b, the test-a reply again after the observers had been hidden for 7 min or more, and a
thread in test-a.

| Surface | Activity: a reply, a turn, a thread started, running and finished | At load |
|---|---|---|
| Sidebar row (`[data-group-list=<id>]`, on every page; lists 5 projects, not all) | Nothing changed, in either observer, for any send, over up to 6 min each | `[role=status]` holds `[data-cds=Pulse]` first, then `span.status-dot[data-kind=ready]` on 3 of 5 rows (both test projects and one real one), the same whether a turn was running or not |
| Projects page card (`.group/card`) | Nothing changed | `time[datetime]` is not the last activity: it stayed 2 days old after today's sends. The first 5 cards (the sidebar's) have 6 more elements; the order is the same for both |
| Order of the rows | Never changed | |
| The observers' own fetches | Only at load (`/v1/code/channels`, `/v1/code/sessions`, …), then nothing: no polling | |
| A project's own page, overview (`[data-testid=overview-thread-row]`) | A new thread row 5.9 s after the send (Fjord's tab: 6.0 s); its status icon swapped from an `svg` circle to `span.animate-spin[data-cds=Icon]` at 6.8 s (Fjord's tab: 6.8 s); its `time[datetime]` changed at 13.2 s; the row left the list at 13.5 s when the thread finished | Thread rows with section, status mark and `time[datetime]` |

- Neither list surface gives a reliable signal. A hidden list page is a snapshot of its load: it gets no updates while it stays
  hidden, and `status-dot[data-kind]` showed `ready` both during a turn and when idle. An observer reloaded during test-b's
  turn showed the same.
- Only a project's own page shows activity: thread rows appear, a spinner marks a running thread, and finished threads leave the
  list. That is the one-tab-per-project cost above. test-b's page always reopens its last thread (`?thread=`), where the
  overview's thread rows aren't shown. An observer of such a project sees no threads without a navigation.
- Throttling doesn't matter for the list: it never updates, hidden 1 min or 9 min.
- Found on the way: content.js sends `threads` only when there is at least one row (`if (threads.length)`), so a project's last
  active thread leaving (finished) is never said. Fjord's Board still held it as `unknown` (running) after it had finished.
- Caveats: one account and 5 sidebar projects; `data-kind` values other than `ready` were never seen, and what sets `ready` is
  unknown; a page shown in front may update its list (not tried: no focus was taken).

## Sharing one renderer (2026-11-04)

**A. Same-origin frames in Fjord's tab.** Hidden `<iframe src="/code/project/<id>">` nodes were added to `document.documentElement`,
outside the React root, off screen at 1200×900. A structure-only watcher ran in each frame (`all_frames`), and Fjord's logic ran only
in the top frame.

| Frames | Renderers | Fjord's renderer footprint | Delta |
|---|---|---|---|
| 0 | 4 | 862 MB | |
| 1 (test-b) | 4 | 1,035 MB | +173 MB |
| 3 (test-b, test-a, fjord-poc-test) | 4 | 1,272 MB | +410 MB, about 137 MB a frame |

- No refusal: no blank frame and no framing error. Each frame loaded the full app, with sidebar, composers, transcript and thread
  rows, and its DOM was readable from the top frame.
- All frames ran in Fjord's own renderer process; no process was added. Idle CPU of that renderer with 3 frames was 0.1 to 1.2%,
  against about 0.2% without frames. During a turn it peaked at 59% for 10 s.
- Live, in a hidden tab, both at once and after 7.5 min hidden. With Fjord's top frame on test-a, then on test-b, the test-a frame
  saw:
  - your row at 1.6 to 2.6 s, against 2.0 s (pending 1.3 s) in Fjord's top frame;
  - the thread row new (`active`, `dashed`) at 4.9 to 5.7 s, against 5.0 to 5.7 s;
  - the spinner (`running`, `.animate-spin`) at 5.8 to 6.4 s, against 5.8 to 6.3 s;
  - the thread row leaving as it finished at 13.7 s and 19.2 s, both after Fjord's top frame had left for test-b.

  The test-b frame saw test-b's rows within 0.1 to 0.5 s of the top frame.
- Delivery kept working: 4 of 4 sends were confirmed with 3 frames present.
- test-b's frame lands on `?thread=` (its last thread) within 2.2 s, also after setting its `src` to the overview again. There it
  shows the project's transcript rows live but no thread rows.
- Memory isn't given back: after the frames were removed, and even after a tab reload, Fjord's renderer stayed at about 1.45 GB
  (same process).

**B. A tab the page opens.** `window.open('/code/project/<id>')` from Fjord's hidden top frame, as a dev command without a user
gesture, was not blocked. The tab opened in front (`active`, visible) and the Chrome window became the focused one. It was closed
about 20 s later. Its renderer and memory were not measured. Not usable: it steals focus.

Read: frames share Fjord's process for about 137 MB a project, against 324 MB for a tab, with the same liveness. The costs are
the memory kept after removal and projects that reopen a thread. 10 projects would be about 1.4 GB on top of Fjord's tab, and 20
about 2.7 GB.

## Keeping frames on the overview, and handing over to a fresh tab (2026-11-04)

**Staying on the overview.** A framed project that jumps to `?thread=` is restoring the view last shown for that project in this
browser. On its own, test-b's frame jumped back to `?thread=` 1.5 to 2.2 s after each load.
- **(a) The crumb** (`overview-thread-crumb-back`, clicked by test id in the frame): the frame moved to the overview at once and
  stayed there. Reloads after that stayed on the overview too (one reload, watched 25 s).
- **(b) Thread view:** it has no `overview-thread-row` and no `data-home-*`. The only trace of a thread there is a
  `channel-created-thread` card in the project's transcript, with no running or finished state. Not enough.
- **(c) URL variants:** the projects page links to the plain `/code/project/<id>`, which is what jumps. The page uses no other
  overview address.
- **(d) In-frame move as content.js makes it** (`history.pushState` to `/code/project/<id>`, then a `popstate`): the frame went to
  the overview and showed its thread rows, and the next reload stayed there, as with (a).
- **Recurrence:** while the frame is on the overview, nothing moves it. That held through a new thread made by a send and through
  Fjord's own tab opening a thread in that project. But the next load of the frame went back to that thread (1.5 s after the load).
- **Chosen:** each frame's script moves it back with (d) whenever it lands on `?thread=`, and falls back to (a) if the move doesn't
  take. That needs no crumb to exist, and it covers every load: a reload, a handover, or a thread opened since.
- **Live on the overview, hidden 6 min or more** (test-b, thread asked by a send):

| Event | Frame | Fjord's tab |
|---|---|---|
| Thread row new (`active`, `dashed`) | 5.0 s | 5.1 s |
| Spinner (`running`, `.animate-spin`) | 5.8 s | 5.9 s |
| Back to `active`, `dashed` when finished | 22.8 s | 31.2 s |

  A send in that thread showed the spinner at 1.1 s and the finish at 18.3 s. In the fresh tab (frames hidden 4 min) the
  thread was new at 4.7 s and the spinner came at 5.5 s, both with Fjord's tab. It left the list at 15.1 s; Fjord's tab saw that
  only at 33.6 s.

**Fresh-tab handover.** The extension made a pinned, inactive tab at the projects page (`#fjord`), waited for its load, and
closed the old tab. The worker then adopted the new tab through its usual path for a removed tab: find the tagged tab, then
inject.

| | Old tab | New tab |
|---|---|---|
| Renderer | exited (its process went) | new process |
| Footprint | 1,166 MB with 3 frames after 9 min | 330 to 400 MB with no frames; 698 to 784 MB with 3 frames |

- **Timing:** new tab created at 0.1 s, loaded at 0.7 s, old tab closed at 0.7 s, new page adopted at 0.8 s.
- **Sends:** one sent just before and one 1 s into the handover were both confirmed on the first attempt, in 4.0 s and 2.4 s.
- **Focus:** no focus or tab-activation event in the whole run.
- **Frames:** they load again in the new tab, landing on the overview. Their first rows came in 1 to 3 s. A change during that
  gap shows up as the current state, not as an event.

**Growth with 3 frames.**
- First tab: 648 MB with no frames, 1,011 to 1,022 MB 2 to 5 min after the frames were added, 954 to 969 MB at 6 min, 1,166 MB
  at 9 min. Each frame reload (5 in that time) added about 70 to 100 MB, and garbage collection gave some back.
- Fresh tab: 698 to 784 MB over 7 min, with a thread made in that time; 652 MB after the frames were removed.
- Threshold: hand over when Fjord's renderer is about 400 MB over what its frames cost at the start (about 1.2 GB for 3
  projects), or after a run of frame reloads. A handover costs under 1 s and lost neither send.

## Answering a thread's questions (2026-11-04)

Two fjord-test-a threads were started by sends. One asked two multiple-choice questions, then asked in plain words for approval
of a plan, then ran `date`. The other used its plan tools to present a plan, then ran `date`. They were watched from frames in
Fjord's hidden tab: one on the overview and one on each thread's view.

**The cards.** A multiple-choice question and the presented plan have the same structure:
- In the thread side's transcript, a `[data-testid=transcript-row]` holds `div[data-testid=decision-card]`.
- The card holds `ul[role=list]` > `button[type=button]` per option. The first option carries a `span[data-cds=Badge]`, and a
  `span[data-cds=TextLink][role=button]` follows the options.
- No `data-*` or test id tells a question from a plan. A pending card has no `data-state`; an answered one has
  `data-state=answered` and no controls left.
- content.js already flags such rows as `decision: true`. A frame on the thread's view sees the card. A frame on the overview
  sees only the row.
- The text-link control: clicking it changed nothing in the card. There is no free-text field in the card; the thread's composer
  takes a typed answer instead (below).
- The plain-words approval request had no card at all.
- No tool permission prompt came: `date` ran without one in both threads, in the project's cloud environment. The page has a place
  for prompts, `div[data-inline-approval-slot]` > `div[data-approval-cluster-host]` in `transcript-trailing`, and
  `div[data-approval-dock]` in the composer dock. Both stayed empty, so that layout is unmeasured.

**On the overview** (`overview-thread-row`):

| What the thread waits on | Row |
|---|---|
| A multiple-choice card | `data-home-section=active`, `data-home-status-mark=dashed`, no `[data-home-status-line]`: the same as an idle thread, through about 3 min of waiting each time |
| The plan card, or the approval asked in plain words | `data-home-section=needs`, mark `pie`, `a[data-home-status-line]` present, at 37.3 s and 15.2 s |
| Working | `running`, `.animate-spin` |
| Finished | the row leaves the active list |

**Answering.**

| How | Card | Thread |
|---|---|---|
| (a) Typing in the thread's composer (a Fjord send to the thread) | `data-state=answered` 4.5 s after the send | went on to its next step: the second question card came at 4.9 s. A typed approval of the plain-words request ran the next step and the thread finished in about 7 s |
| (b) Clicking an option by structure (`[data-testid=decision-card]:not([data-state]) ul[role=list] button`) | the button got `aria-busy=true` and `aria-disabled=true`, the others `disabled`, at 0.2 to 0.8 s; `data-state=answered` and no controls at 0.5 to 1.1 s | running at 0.6 to 1.2 s. After the plan card's first option, the thread finished at 7.4 s |

- Both work for both card types. The page's proof of an answer is the card's `data-state=answered`, then the row going to
  `running`.
- A click needs no composer and doesn't move Fjord's tab, but which option means what is only in the words, which Fjord doesn't
  read. A typed answer works without that.
- Caveats: one account; two threads; no permission prompt seen; no focus or tab-activation event in the whole run.

## Seeing what a thread waits on (2026-11-04)

**Detecting a waiting multiple-choice card.** A frame on fjord-test-a's overview, in Fjord's hidden tab, logged each thread row's
whole structure: elements, class tokens, `data-*`, `time[datetime]` and its place. The thread asked two questions, then replied
and stopped.
- **Waiting is identical to idle.** On a card, the row goes from `running` (`span.animate-spin[data-cds=Icon]`) to `active` with
  `svg` > `circle` and mark `dashed`, with no `[data-home-status-line]`. Its structure then matches an idle thread's (a turn ended,
  not finished) except for the id: same `data-home-*` set, same children, `time[datetime]` unchanged. Nothing in the row says a
  card waits.
- **The row lags the card.** A thread-view frame left open saw the second card pending 1.6 s after the first was answered. The
  overview row went `active` only 12.5 s after that, at 15.4 s. `time[datetime]` changed only when the thread replied, not when
  a card came.
- **Position:** a new thread takes `#0`; an answered or finished one doesn't move.
- **Event-driven check:** on a row's `running` to `active`, the top frame opened one frame on that thread's view, counted pending
  `[data-testid=decision-card]:not([data-state])` and its option buttons, and removed the frame.

| Case | Frame opened after the transition | Frame loaded | Read | Result |
|---|---|---|---|---|
| First card | 3 ms | 179 ms | 1.86 s | 1 pending, 2 options |
| Second card | 0 ms | 252 ms | 2.09 s | 1 pending, 2 options |
| Idle (reply, stop) | 1 ms | 244 ms | 3.36 s | 0 pending (waited for both composers and rows, plus 3 s) |

- **No ping-pong.** The overview frame moved back once, at its own load (it landed on Fjord's last thread). It didn't move again
  through 3 check frames and one thread frame kept open.
- **After an answer**, by a click on an option in a thread-view frame: `data-state=answered` at 1.1 to 1.3 s, the row `running`
  at 1.2 to 1.5 s.

**A tool permission prompt: not produced.**
- fjord-e2e was granted to fjord-test-a with `preapprove_folder` (awaiting, then confirmed) and removed afterwards with
  `remove_folder` (saved, status 200).
- A thread started on that folder (the row gained `[data-testid=thread-machine-mark]`) ran `touch` and `rm` without any prompt.
  The approval slots (`data-approval-cluster-host`, `data-approval-dock`) stayed empty and the row went from `running` straight to
  finished. The folder has no file left.
- The cause: the Remote Control serving the folder runs with `--permission-mode auto`, so the prompt needs a mode that asks, or an
  action that mode doesn't allow.
- No Claude-app `local_*.json` exists for a Remote Control thread. That app's files hold, among others, `permissionMode`,
  `sessionPermissionUpdates`, `alwaysAllowedReasons`, `interruptedAwaitingPerson`, `lastTurnEdgeAt` and `turnBoxDeclared`.

**Read:** a waiting card can be told only by looking at the thread itself. Checking on the row's `running` to `active` transition
answers in about 2 s with one short-lived frame, and leaves the overview frame stable. The transition can come about 12 s after
the card, so the check is late by that much.

## Five more page facts (2026-11-04)

Observed from frames in Fjord's hidden tab, Fjord's own top-frame sidebar, and one pinned, inactive observer tab on
`/code/projects/browse`.

1. **A new project elsewhere.** The project was made with `create_project` through Fjord's tab and confirmed. Only the tab that
   made it changed: its sidebar got a new `[data-group-list=<id>]` row at the top within 1.3 s, and its `projects` event grew from
   5 to 6. The observer tab's sidebar and list showed nothing in 30 s; an observer tab opened later shows the project at load.
   Framed pages render no sidebar at all (no `[data-group-list]`, no `[data-testid=sidebar]`). So a project made elsewhere is seen
   only by a fresh load of the projects page.
2. **Read marks.** A thread whose row is `needs` and unread shows its title as `bdi.text-prose-semibold` plus a `span.sr-only`; read,
   it shows `bdi.text-prose-medium`, with no `sr-only`.
   - When the thread went `needs` while a thread-view frame of it was open, the row turned up as read.
   - After both frames were loaded again, with the thread-view frame loaded 34 s before the overview, the overview showed the row
     unread. Loading the thread in a frame does not clear the mark.
   - The mark cleared when the row went back to `running`.
   - The sidebar has no per-thread mark.
3. **Empty versus loading.**
   - Loading: `[data-testid=overview-tab-strip]` and `[data-home-section=active]` only, with no rows.
   - Loaded: the sections `needs`, `active` and `done`, with `section[data-testid=home-empty-band]` and
     `div[data-home-empty-line=true]` in `needs` when nothing needs you, `section[data-home-group=default]` and
     `section[data-home-group=done]`, and `div[data-home-sort=priority][data-home-state=ready]` once the list has rows. It took
     0.1 s after the tab strip on test-a and 6 s on test-b.
   - A project with no active threads (test-b, earlier census): `home-empty-band`, `data-home-empty-line`, two
     `data-home-section` and one `data-home-group`, with no `data-home-state`.
   - A project that never had a thread (live, 2026-11-05: fjord-measure-temp, surplace.live, and test-a and test-b after their
     threads were gone): `[data-testid=threads-empty-explainer]` after the tab strip, and no `data-home-section` at all. Frames
     that waited for a section there reported `frame_stuck`, were reloaded, and used up the load budget in about a minute, so the
     tab was handed over again and again and every send paused on "the page can't be read".
4. **Coordinator rows and threads.**
   - The coordinator's report row carries a `channel-created-thread` card: `-box`, `-glyph`, `-title`, with `data-glyph` and
     `data-display` attributes. While the thread works it adds `channel-created-thread-step`; when the thread waits or ends it has
     `channel-created-thread-summary` instead.
   - That row's links and `data-*` hold only its own entry id (`data-entry-key`, `data-turn-key`, `data-item-key`), never the
     thread's.
   - The link is elsewhere: the thread's id (`data-home-card`) equals the `data-entry-key` of the project-chat row that opened it
     (`data-perf-row=human`). That row carries `working-activity-row`, `channel-overview-working-status` and
     `TurnStatusClayMark` while the thread starts, and `thread-step-text` while it works.
5. **A plain-words request to proceed** (no card). The row went `active`/`dashed` (new, 0.9 s), then `running` with the spinner
   (on its first step, 30 s). Then it went straight to `needs` (mark `svg.text-warning`, `a[data-home-status-line]`), 15 s after
   its last reply, without passing through `active`/`dashed`.
   - A thread-view frame meanwhile showed no card and no approval slot content.
   - The thread's composer kept `code-prompt-stop` for a while after `needs`; it was gone at the next load.
6. **A tool running in a thread's view** (`sleep`, then `date`).
   - The thread's composer dock (the second `rail-composer-dock`) shows `[data-testid=code-prompt-stop]` from the turn's start, with
     `code-prompt-send` disabled.
   - The thread view has no `.animate-spin` and no `aria-busy` during the tool.
   - The reply after it comes as a row with `data-perf-row-streaming=true`, `data-busy` and `data-is-streaming`, which goes once
     written.
   - Idle: no `code-prompt-stop`.
   - The overview row's spinner is the only spinner. The row's `time[datetime]` moves with each reply.

Left in the account: the test project `chan_01HwRR6j4vFs3JsEyrPKAXuu` (fjord-measure-temp); no tool archives a project. After the
extension reload at the end, the page read as unreadable (`page_ok: false`) until a `reload_tab`. The send queued meanwhile then
went through (confirmed).

## Two structure checks (2026-11-04)

1. **Finished threads stay in the list, in a collapsed group.** Their rows render inside `[data-home-section=done]` within
   `section[data-home-group=done]`. That group is collapsed by default: its one `button[aria-expanded=false]` hides the rows, so a
   finished row seems to leave.
   - Expanded (the button clicked by structure in a frame, then clicked again to collapse), the group showed 20 rows. Each row
     looked like an active one (`data-testid`, `data-home-card`, `data-home-simple`) but with `data-home-status-mark=icon`.
   - Live, a test-a thread went `section=active`/`group=default` (new, 6.1 s), then `section=running`/`group=running` (a group
     that exists only while a thread runs, 7.0 s), then `section=done`/`group=done` at the top (16.8 s).
   - The done list holds 20 rows: the oldest one left as the new one came in.
2. **No id ties the coordinator's rows to a thread.**
   - The opening row (`data-perf-row=human`) has `data-entry-key`, `data-epitaxy-entry` and `data-take-back-entry`, all equal to
     the thread's `data-home-card`, plus `data-thread-rename-anchor`. It has no `data-turn-key`.
   - The coordinator's thread-start row is the next transcript entry: `data-epitaxy-entry-index` one more than the opening row's.
   - Entry indexes aren't stable across loads (live, 2026-11-05: the same rows read 184 to 195 after a reload, 206 to 209 before),
     so they only relate rows read in one document. The log ignores them when it compares a row with the one it stored.
   - A decision card's option button names its parts: `aria-labelledby` the letter (its first child) and the label,
     `aria-describedby` the badge and the consequence line. Its plain text runs them together ("ARedThis thread replies…").
     Its `data-entry-key`, `data-epitaxy-entry`, `data-turn-key` and `data-item-key` (`<own id>:t1`) are all its own id. Its
     `channel-created-thread` card has `channel-created-thread-box[data-display=single]` and
     `channel-created-thread-glyph[data-glyph]`, which goes `working` to `CheckCircle` when the thread finishes (17.0 s, 0.2 s
     after the row moved to done).
   - The finish-report row has only its own keys and no card.
   - Nothing in either row or the card equals the thread id or the opening row's keys. The only tie is the start row's position
     right after the opening row, and the card's glyph changing on that start row.

## Open

- A real folder grant works: `~/code/spikes/fjord-e2e`, served by a terminal Remote Control, was granted live in 2.6 s (the folder
  list needs a press 700 ms or more after it opens; the save is `…/remote-control-preapproval`, its HTTP status the answer). An earlier
  note that such folders aren't pre-approvable was wrong. Granting one still needs the owner's OK for that folder.
- Tools are being made faster (one fresh read merged into the act, the save's answer as the proof).

Settled, not issues (advice from Fable, Gemini and two flash models, 2026-11-03): cloud threads in other projects are shown with
their age, and refreshed whenever a message goes to that project (the owner has had no real cloud threads); a goal changed elsewhere
is read as the tab's copy and said so; the Claude app closing and Mac sleep are handled by the pause and the clock-jump rule; the
rare ignored click is covered by the 2 s retry.
