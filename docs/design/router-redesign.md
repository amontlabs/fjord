# Router redesign: projects, a manager, and what it knows

Status: proposal for discussion, 2026-11-02. Nothing here is built. Facts checked against CLI 2.1.311 and Claude desktop
4.4212.0 by reading the binaries, docs and local files; no live runs. Unverified items are listed at the end.

## Where the Router stands

| Complaint | What the audit found |
|---|---|
| Claude comes forward | Every new session and fork opens `claude://resume` through `Link.open`, a plain `NSWorkspace.open` that activates the app. Delivery falls back to opening a session when no other session can carry. SSH starts need it. |
| Unrelated sessions messaging others | Since 2026-10-23 (`58fe1038`) every message, even to a running session, goes through a carrier: any other desktop session with Fjord's plugin, idle first, then most recent (`RouterCarry.carriers`). Project isn't considered. The carrier's title shows whenever the target's plugin doesn't rewrite the envelope. 33 of 85 cross-session entries in the last 30 days came from another project (bodies not read). |
| Poor routing | Jev sees a title, a project, one status line (300 characters) and what you last told the session (160). On the sealed benchmark the Router is level with always asking (2.20 vs 2.09 loss per message, top-1 67%). |
| Not general-purpose, no chat | Router runs are stateless Haiku with `board`, settings and Triage tools. No transcript access, no conversation. The chat lived one day (2424b4bc, removed by 1458482d); the commit gives a principle, not a measurement. |

Live traffic is thin: 64 real routings in 11 active days. 72% went without an ask, 27 of them by `@tag`. Of 17 asks, 9 were
corrected, and 8 of those 9 were new work offered an existing session in the right project. Silent wrong sends can't be
seen: the trace has no edit or override event.

## Why the project is the right unit

On 393 replayed real submits:

| | session level | project level |
|---|---|---|
| Top-1 | 69.2% | 83.0% |
| Wrong rate of top pick at sureness ≥ 0.9 | 3.9% | 1.0% |
| Ask card's first suggestion | 61% | 78% |
| Last finished session baseline | 54% | 74% |

5 of 6 wrong sends had the right project. A typical board is 11 sessions in 4 projects. A median day touches 5 projects;
the top two take 82% of prompts. 135 folders collapse to 36 projects (25 for Desktop), and 6 hold 80% of sessions.

Limits: this replays the Oct 14 policy, unrefitted, so project-level numbers are a floor on what a project-level decision
could do.

## Claude Code Projects as the backend (open again)

**Direction (2026-11-02):** drop private routes and use the real page only: type in the real composer, read the visible
thread list, and read everything else from local files. The owner accepts the remaining terms risk for this light use.
Tested in a hidden window:

- `data-testid="code-prompt-input"` and `code-prompt-send` send to the coordinator. With `?thread=<id>`, the page has a second
  composer that replies to that thread. Both arrived as `from="human" trust="principal"`, with Claude staying in the background.
- `overview-thread-row` gives title, state, unread, what it needs and the thread id (`data-home-card`).
- Labels follow the page's language (the hidden view ran in French), so select by test id, never by visible text.
- `router.py` still uses the private routes and must move to these.

This lowers the risk, but doesn't remove it: it's still automated access under the Consumer Terms, and the sign-in rule
below still applies to a window inside Fjord.

**Direct replies vs project only (2026-11-02).** The same 60 messages in the owner's style went through two identical
projects, using only the real composer, in cloud threads. Outcomes were scored by a reviewer who saw X and Y labels shuffled per
message. The labels hide the design, but a direct reply is still visible in the outcome text.

| | Right | Acceptable | Asked | Wrong | Decision |
|---|---|---|---|---|---|
| Project, direct or ask | 46 | 11 | 2 | 1 | 6.9 s, $0.032 |
| Project only | 51 | 5 | 3 | 1 | 5.6 s, $0.032 |

- The nine direct replies were all right, but project only was no worse, so the extra path isn't worth its rules.
  The seven messages that differ are too few to prove project only is better.
- The Router's own project choice: all 6 messages for other repos went to the right repo in both designs.
- Too many asks: the Router asked 13 times in project only, and only 3 needed it. Most were new topics that didn't name a
  project. The test stood in for the owner's click, so the reviewer saw only asks with nowhere to go.
- The coordinator split multi-part messages into separate threads in both designs.
- One known failure: "it keeps doing that its annoying" went to the wrong repo in both designs.

**Decision:** the Router picks the project; the coordinator does the rest. An explicit target (a click or a reply to a card) goes
straight to that thread.

**Where a thread runs.** There are three modes, not two:

1. **Cloud only:** the default. No access to your Mac.
2. **Cloud with folder access** (`device_folder_thread`): the thread runs in the cloud and reads and edits your folder remotely.
   No local Claude process, no local transcript, and none of your local tools or hooks. Anthropic's thread prompt says to use
   this by default for file work.
3. **Remote Control session:** a real local Claude Code session with your tools and credentials. Anthropic's thread prompt
   keeps this for work that must run on the device, like builds, tests and scripts, or when the person names it.

The composer's Local tag is plain text at the start of the message: `[Local: work on my computer]` or
`[Local: work on my computer in "<folder>"]`. With a pre-approved folder, a new topic with the tag started mode 2 with no click.
With a fitting thread already open, the coordinator reuses it wherever it runs. Pre-approval alone doesn't make threads
local, which corrects the earlier one-run result.

**A local project is a project instruction.** With a pre-approved folder plus this rule in Project instructions, every new topic
became a real local session, with no click and no local wording in the message:

> Run every thread as a Remote Control session on this computer in `<folder>`, using start_remote_control. Never use cloud threads
> or folder access, never ask where to run, and don't send work to a thread that isn't a Remote Control session.

Test: 6 messages. A question, a file summary and a command each started a `claude-desktop` session. A follow-up and a quick
check went to the local thread. A question about an older cloud topic was answered by the coordinator from what it knew, and
nothing went to the cloud thread. One run on one repo, all read-only.

**Reporting.** Only the coordinator can post in the project chat, and it decides whether to repeat a thread's result. A thread's
final message lives in the thread. Coordinator rules for this aren't on disk. Local threads have `post_widget` but not
`request_decision`.

**Terms check (2026-11-02).** The first POC's transport doesn't fit Anthropic's published rules:

- Consumer Terms: no access "through automated or non-human means, whether through a bot, script, or otherwise", except
  with an API key or where Anthropic explicitly permits it. They also bar reverse engineering the Services.
- [Claude Code legal page](https://code.claude.com/docs/en/legal-and-compliance): Anthropic doesn't permit third-party
  developers "to offer Claude.ai login into their own applications", and developers "may not collect, store, or
  intermediate Claude.ai credentials or session tokens". Anthropic may enforce this without notice.

A hidden web view holding a claude.ai sign-in and calling private routes is what these describe, and that holds for a
headless browser too. Options: ask Anthropic for explicit permission, or rebuild the transport on supported parts (own lead
session per project, the unmodified Claude Code, the plugin and an API key for the manager). The routing rules and
results below carry over to either.

An earlier version of this doc ruled Projects out because there's no public API. That was wrong technically: no public API
isn't the same as not composable. Tests show Projects works as a backend (details in
[projects-internals.md](projects-internals.md)). Working design:

- **One project per repo**, its folder pre-approved, worktrees on. Threads run on your Mac, unprompted.
- **New work:** Fjord posts your exact words to the project channel. The coordinator starts or reuses a thread.
- **Follow-ups:** Fjord replies to the thread through the channel. Your words arrive as yours in 0.2 s, with no coordinator
  turn, so most messages skip the extra hop.
- **Board:** session status, timeline events and the live stream, with no model calls.
- **Fjord's own job:** choose the project, watch everything, brief you, and chat. The per-project state below shrinks
  to what the coordinator and these feeds don't already give.
- **Sessions outside a project** keep the plugin route, until they're moved in or stop mattering.
- **Open gap:** recovering a thread that lost its process.

Sections below this one predate these tests and need revising.

### Routing on real moments

120 dev moments, same moments for each variant. Variants route with one typed `claude -p` call
([manager_eval.py](../../poc/projects/eval/manager_eval.py)). Shipped predictions exist for 56 of them.

| 120 moments | Session top-1 | Project top-1 | Sends at 0.8 | Wrong of those sends |
|---|---|---|---|---|
| Haiku, thin context | 54% | 78% | 15% | 28% |
| Haiku, rich context | 68% | 88% | 46% | 11% |
| Sonnet, rich context | 80% | 93% | 52% | 1.6% (1 of 62) |

| 56 moments with shipped data | Session top-1 | Project top-1 | Sends at 0.8 | Wrong of those sends |
|---|---|---|---|---|
| Shipped Router | 70% | 79% | 29% | 12.5% |
| Sonnet, rich context | 91% | 96% | 64% | 0% (0 of 36) |

Sonnet against shipped, paired: session +21 points (95% CI +11 to +34), project +18 (+7 to +30), asks −36 (−52 to −20).

- Both context and model matter. Context alone gave Haiku +14 points, and Sonnet added +12. This is why the earlier Haiku test failed.
- About 6 s and $0.021 a decision on Sonnet, $0.0013 on Haiku, at API prices. The time is mostly CLI start-up: Haiku took the same.
- **New work is still weak:** Sonnet got 4 of 12 right and sent 7 to an existing session. Only 12 cases, and new work is rare in
  this set by construction. The coordinator's own new-vs-existing call isn't measured yet.
- Limits: messages typed inside sessions, strict gold, one sample, written once and not tuned, and the shipped comparison
  covers under half of it.

#### 2026-11-04: the app's Jev with projects as candidates, against Sonnet

Project level (a project = the repo root of the true destination session), one sample per moment, strict gold. Sets: the same
120 dev moments, plus 62 realB moments outside the sealed groups and the 120 (182 in all; 83 have a recorded shipped
prediction). The runs: A is the shipped Router's recorded prediction (its full fusion, not Jev alone). B is one Jev call
over the `swift` format's sessions and new sessions, with one `claude.ai project` option per project (6 latest session titles
as threads, no purpose since the boards hold none), sent at 0.7. A′ is B without the project options (Jev alone, 0.7). C is
Sonnet with rich context at 0.8 (the earlier 120 results reused; fresh calls for the 62). New-work = gold is a new session
and the prediction is a new session in the right project (B can also pick a project, which hands the choice to its
coordinator: counted separately as "lenient").

| Set | Variant | n | Project top-1 | Sent without asking | Wrong of sent | New work right |
|---|---|---|---|---|---|---|
| 120 dev | A′ Jev, sessions | 120 | 52% | 22% | 3 of 26 | 1 of 12 |
| 120 dev | B Jev + projects | 120 | 58% | 14% | 0 of 17 | 0 of 12 (lenient 2) |
| 120 dev | C Sonnet rich | 120 | 92% | 52% | 2 of 62 | 4 of 12 |
| 56 dev with shipped | A shipped | 56 | 79% | 30% | 0 of 17 | 0 of 3 |
| 56 dev with shipped | B | 56 | 57% | 18% | 0 of 10 | 0 of 3 |
| 56 dev with shipped | C | 56 | 95% | 62% | 0 of 35 | 2 of 3 |
| 62 realB | A′ | 62 | 60% | 27% | 0 of 17 | 1 of 7 |
| 62 realB | B | 62 | 61% | 19% | 0 of 12 | 1 of 7 |
| 62 realB | C | 62 | 95% | 55% | 0 of 34 | 4 of 7 |
| 83 with shipped (dev + realB) | A shipped | 83 | 83% | 31% | 0 of 26 | 0 of 5 |
| 83 with shipped | B | 83 | 55% | 18% | 0 of 15 | 0 of 5 |
| 83 with shipped | C | 83 | 94% | 65% | 0 of 54 | 2 of 5 |

Paired differences in points, bootstrap 95% CI (4,000 resamples over moments):

| Pair | Set | Project top-1 | Sent | Wrong sends per message |
|---|---|---|---|---|
| B − A′ | 120 dev | +7 (+2 to +12) | −8 (−12 to −2) | −2 (−6 to 0) |
| C − B | 120 dev | +33 (+25 to +42) | +38 (+29 to +47) | +2 (0 to +4) |
| C − B | 182 | +34 (+27 to +41) | +37 (+29 to +45) | +1 (0 to +3) |
| C − A | 83 with shipped | +11 (+4 to +19) | +34 (+22 to +46) | 0 (0 to 0) |
| B − A | 83 with shipped | −28 (−39 to −17) | −13 (−24 to −2) | 0 (0 to 0) |

- Adding projects to Jev's candidates helps a little (+7 top-1) and makes it ask more, but it's still far under the shipped
  Router and Sonnet. Jev alone sees only titles and the sessions' status lines; Sonnet reads summaries, its last answers
  and what you last told it.
- Wrong sends are rare at project level for every variant (a send to the right project in the wrong session isn't wrong here),
  so the difference is in how many messages go through unasked: 14–31% for Jev and the shipped Router, 52–65% for Sonnet.
- New work stays weak for all: Sonnet 8 of 19, the others 0 to 2 of 19.
- Limits: B is Jev's choice alone at 0.7, not the app's full fusion and vetoes; the claude.ai project options are rebuilt from
  the local boards (no purposes, thread titles are session titles); the shipped numbers cover 83 moments; one sample, no
  tuning; the 120 dev moments were already used by the earlier run. Sonnet's number here is project-level, so it's higher
  than the session-level figures above. A realB set limited to dev/calib groups (62 extra) is small. Raw answers (with message
  text) stay in the scratchpad.

### The coordinator on new vs existing

10 read-only messages sent to the real `lcu` project, expected outcomes written first
([coordinator_test.py](../../poc/projects/eval/coordinator_test.py)).

| Kind | Result |
|---|---|
| New work | 4 of 4 started a new thread |
| Terse follow-ups ("which tests cover it?") | 3 of 3 went to the right thread |
| Follow-up after another topic ("back to the Junie one…") | Answered directly from what it knew, no routing. Arguably fine |
| Questions and chatter ("how many threads…", "ok thanks") | 2 of 2 started nothing |

The board-state answer was checked only against the thread list, and technical answers weren't checked. `lcu` stayed clean.
Threads ran in the cloud, because `lcu` has a repo and no pre-approved folder. These messages are written and easy,
so they don't settle this: written cases misled us before.

### The whole flow on messy messages

Messages written in the owner's style, on a read-only test project, four parallel topics, expected outcomes written first.
Each run used new messages.

| Run | Right | Asked | Wrong | Other |
|---|---|---|---|---|
| 1: first version | 14 | not separated | 10 | |
| 2: conversation memory, checks, ask under 70% | 10 | 10 | 4 | |
| 3: hand-off rule | 15 | 5 | 3 | 1 coordinator asked what to run |

The hand-off rule:

1. Sure it continues a thread (85%+): reply directly.
2. Sure of the project only: send to the coordinator, which picks the thread.
3. Unsure of the project: ask.

Reading run 3's three "wrong": twice the coordinator used a related tests thread and answered correctly, which my list was
too strict about. Once the manager answered "explain the followups" itself instead of sending it to the thread.

Still weak: a message with three requests became one thread, not three. Two asks came from low project confidence with
only one likely project. Decisions took about 10 s and $0.036 at API prices, with the whole board in each prompt.
The `lcu` repo stayed unchanged in every run.

Anthropic shipped this design on 2026-09-17 (beta): one coordinator conversation per project, threads as workers, and the
coordinator routes each message to a new or existing thread. Evidence from the real local thread on this Mac (`lcu`,
2026-10-25, session `c495f54f`):

- **Your words stay yours.** A project message arrives as `<wake reason="mention">` with
  `<message from="human" trust="principal">` and `projectsUserTurn: true`. A coordinator's spawn note arrives as
  `<relay from="coordinator">`, marked as not your words.
- **Threads report natively:** `mcp__claude-code-remote__send_message` to `@parent`.
- **Local threads are full local sessions:** they load your hooks, plugins, MCP servers and the desktop prompt.
- **Fjord already reaches them.** Its signed plugin delivered into this thread on 2026-11-02 as `asUser`.
- **This Mac is already set up:** Remote Control serving is on, with folders connected, this repo included.
- **The coordinator's tools are rich** (`hearthbot`): `fetch_project_timeline`, `fetch_thread`, `fetch_messages`,
  `list_thread_sessions`, `list_project_prs`, `ask_decision`, `update_status`, `set_thread_label`, `set_thread_resolved`,
  `start_thread_session`, `start_folder_thread`, `read_memory`, `update_memory`, `search_channels`,
  `get_project_session_id`.
- **The way in exists, unofficially.** Projects are served by claude.ai, so a browser can drive them. The client code
  also shows private routes (`/api/organizations/:org/projects/:id/detail`, docs, files, memory). The desktop app caches
  project data in its `https_claude.ai` IndexedDB, and `/code/project/` is a route the app handles.

If this works, Projects could replace Fjord's new-vs-existing decision, session starts and carriers. Starts would come
from the Remote Control server, not `claude://resume`, which would remove the app-forward problem for those sessions.

To settle, from a signed-in claude.ai session:

1. How a message reaches the coordinator, and how to read the project timeline and thread states.
2. Whether a local thread can start without clicking **Allow once** each time, or whether that card can be driven.
3. Whether a project can default to local threads, and with a worktree per thread.
4. Whether Fjord can get by on the browser or needs the private routes, and how each behaves over time.
5. Limits: plan usage of coordinator and threads, and terms on automating claude.ai.

Known limits: the coordinator runs in the cloud and sees what threads report, not your disk. Local threads don't load
project memory, stop if the app quits, and pause while the Mac sleeps. Sessions you started yourself stay outside a
project. Private routes and the UI can change without notice.

Whichever way this lands, keep what's public: the coordinator "sees what threads report back, not every step", works
"from recent messages, recent threads, and project memory rather than its full history", and sorts threads into Ready for
review, Waiting on you, Working, Landing, Idle and Resolved.

Remote Control: it's already on across current desktop sessions, which `/v1/code/sessions` lists as `bridge`. The web client's
calls are the likely way in, not a local endpoint: see [projects-internals.md](projects-internals.md) for what's tested. It
also keeps sessions alive: the app's idle-eviction filter (`peekLruIdleVictim`) spares them, apart from a narrow
memory-pressure case.

## Proposal

Two layers, split at the project:

**The manager (one, global).** The Router's new core and the thing you chat with. It holds a conversation, reads the
project states, answers questions about everything, acts on the board, and decides where a message goes. Same context
recipe as Anthropic's coordinator: recent exchanges, recent activity, memory; never the full history.

**Project state (one per project).** A short document Fjord keeps current. It replaces the brief writers and the
one-line session descriptions.

Words stay yours: the manager only returns a destination, and Fjord delivers your exact bytes through the signed plugin.
Nothing relays or rewords a message, except a divide you see before sending.

### What the manager knows

| Layer | Content | Size | Source |
|---|---|---|---|
| Always loaded | Your preferences and routing corrections; one line per active project; everything needing you | ~3k tokens | State docs |
| Loaded for candidates | Full state of the projects in play | ~1.5k tokens each | State docs |
| On demand | `session_tail`, `search`, PR status, read-only repo access | as needed | Transcripts, GitHub |
| Actions | send, start, fork, mark read, archive, reopen, stop, settings | | Fjord tools, each with Revert |

### What a project state holds

- **Purpose:** what this project is. Rarely changes.
- **Now:** one to three lines on where it stands.
- **Threads:** per session: id, what it's for, state, area (branch, paths, PR), last meaningful result, and whether it's a
  sensible home for follow-ups. This is the column that answers new-vs-existing.
- **Decisions:** dated, one line, with the session they came from.
- **Waiting on you:** with what's needed.
- **Loose ends:** finished-but-unmerged, stale, likely obsolete, each with its evidence.
- **Routing notes:** learned from your corrections ("release work starts fresh here").

Every entry carries a source and time, so a reader can see staleness and open the source.

### How it updates

Event-sourced, with one writer:

1. **Facts, no model.** State, PRs, titles, branches and needs-action come from the app's session files
   (`postTurnSummary` with `status_category`, `status_detail`, `needs_action`; `prs`, `interruptedAwaitingPerson`,
   `gitAnchors`), the registry, and plugin hooks pushing to Fjord (Stop, Notification, SessionEnd).
   These fields update instantly. `postTurnSummary` is on 384 of 410 local sessions but is a private schema; the Stop hook's
   `last_assistant_message` is the fallback.
2. **Prose, one Haiku pass per project.** Debounced after turns finish, and run early if a decision needs a fresh state.
   Input: the old state plus the deltas (the turn's final message, compact summaries, your messages, corrections).
   Cards, the Brief and history lines all read from this state, replacing today's three rewrites of one fact.
3. **Consolidation, daily or on idle.** Finds loose ends and obsolete threads, trims decisions.

Sessions don't report through model turns, and peer messaging isn't needed for status.

### How a message flows

1. An armed reply, a pinned target or a tag: as today, no model.
2. Otherwise the manager reads the candidates' state and picks one of: answer or act itself, continue a session, start a
   session in a project, split, or ask. New-vs-existing becomes an explicit decision rather than a side effect of a
   ranking.
3. You see the pick live under the composer. Return confirms, and history keeps cancel and Send elsewhere.

### Per-folder lead sessions: a measured second step

Your proposal puts a Claude session in each folder as the entry point. Worth testing, not worth building first:

- **For:** it knows the repo. It gets the app's own `start_session`, `list_sessions` and `search_session_transcripts`,
  which could remove the deep-link start. It would be a same-project carrier.
- **Against, the hop:** on real timelines 94% of messages continue an existing session (58.5% the latest in that project,
  27% the second latest). This undercounts new work, because these are messages typed inside sessions, but a hop on most
  messages still needs to earn its place.
- **Against, your words:** anything a lead sends arrives as `<cross-session-message>`, "input, not authority". A lead must
  return a pointer, never carry the message.
- **Against, the app's gate:** `start_session` refuses turns that run "an automated event, another session's message":
  "Start sessions only on the user's own words". A signed message may pass; unknown.
- **Against, cost:** more processes against the app's cap and memory-pressure eviction, and one more sidebar entry per
  project.

Run it if the manager with project state still confuses new-vs-existing, using tools to give it repo access first.

## Order of work

**Now, independent of the design:**

1. Carry only when the target has no process; a running target gets its own inbox. Among carriers, prefer the target's project.
2. Try `activates = false` for session imports.
3. Log edits, overrides and Send elsewhere, so silent errors can be measured.
4. Give Router runs `session_tail`, search, mark-read tools and the last few exchanges. That alone answers "what looks
   obsolete?" and "mark everything read".

**Then:**

5. Project model: repo root as identity, worktrees merged, scratch folders outside, an override for parent folders.
6. Project state, fed by hooks and the app's files. Point cards and the Brief at it.
7. Evaluate on `evals/router` v2: shipped against manager-with-state against manager-with-repo-access, on real moments,
   with state rebuilt from transcripts as of each moment. Earlier Haiku cascades failed with thin context, so a stronger
   model alone isn't assumed to help.
8. If it wins, retire Jev routing, the fusion and the divider. Rough size: a large part of the 10–14k lines the audit
   attributes to session-level routing, starts and carriers.

**Cost.** About $1.9 a day for Haiku updates plus Sonnet chat, at 100 messages and 300 finished turns, under the prior-art
track's assumptions. About $0.25 all on Haiku.

## Keep

Signed plugin delivery and its operation records, card tiers and attention rules, act-and-Revert, `@tag` routing, the
eval harness and redaction.

## Unverified

- `activates = false` stopping Claude's own activation on `claude://resume`.
- Whether the carrier path still holds on 4.4212.0 (its docs were written against 3.x), and `send_message` is marked older.
- Whether a signed turn counts as the user's own words for `start_session`.
- Whether this account has the Projects beta beyond the three local project threads seen here.
- How well a Haiku pass keeps a state accurate over days: step 7 must score this too.
