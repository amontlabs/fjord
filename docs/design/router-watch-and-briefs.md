# Router: watching every project, and the briefs

Design, 2026-11-04, revised after an Opus review of the code it touches. Builds on the measurements in
[router-data-design.md](router-data-design.md), the project-state proposal in [router-redesign.md](router-redesign.md), the engine
in [router-swift-port.md](router-swift-port.md) and the page protocol in [poc/router/EVENTS.md](../../poc/router/EVENTS.md).

Three rules carry over: only the page's own rows prove anything; an item's key is its own id, not its text; every wait is an event,
except the engine's existing deadlines (`do.TIMEOUT` 20 s) and model calls. Where a fact was never measured, the text says what to
measure and designs for both outcomes.

## 1. Watching

### 1.1 Shape

One hidden, pinned, inactive tab (`#fjord`) runs Fjord's **top frame**, which does every delivery as today. Inside its document the
top frame keeps hidden same-origin `<iframe>` nodes (appended to `document.documentElement`, outside the React root, 1200×900 off
screen): a **project frame** per non-archived project on `/code/project/<id>`, and **thread frames** on `/code/project/<id>?thread=<key>`
(1.8). Frames run the same content script in **watch mode**: they report, never type or click a composer, and run only `wake`
and, in a thread frame, `answer` (3.5). Every event from a frame carries `frame: {project, thread|null, frameId}`.

| Who | Does | Reports |
|---|---|---|
| Top frame | `open`, `send`, tools, the projects list, adds and removes frames on `frames` | Everything in EVENTS.md; `frames: {have: [...]}` with every snapshot |
| Project frame | Stays on its overview | `page`, `threads` (whole, delta, departures), `rows` of the project side (coordinator rows), `notice`, `wake_me` |
| Thread frame | Stays on its thread view | `page`, `rows` of the thread side (decision rows with `answered` and `options`), `turning`, `notice`, `wake_me`, `done` for `answer` |
| Worker | Owns the tab, the port table, the frame set, the budget, the handover | `page` for the tab; `frame_blank`, `frame_gone` |

`frames: {want: [{project, thread: null|key}], base: bool}` is the whole wanted set each time; the top frame diffs it against its
nodes. **The engine is the one owner of the set** (project frames from the Board's projects, thread frames from 1.8, a frame an
`.answer` run needs through the same rule); the worker only relays `frames` to the top frame, counts loads, and never adds or drops a
frame itself. The top frame gives each `<iframe>` a `name` of `fjord:<project>:<thread|->`; a frame's script reads its identity from
`window.name`, never from its address (a project frame jumps to `?thread=` before it connects), and the worker ties `sender.frameId`
to that name at the port's `hello`.

### 1.2 Worker: ports, frames, injection

The POC's `onConnect` treats any port from Fjord's tab as *the* page (`isFjord`, then `pageGone(old)`, `page = port`, snapshot). That
stays true only for `sender.frameId === 0`. The worker keeps a **port table** keyed by `${tabId}:${frameId}:${documentId}`
(`port.sender.documentId`, which changes on every navigation of that frame):

| Port | Rule |
|---|---|
| Top frame of Fjord's tab (`frameId 0`) | `isFjord`, adoption, `pageGone`, `waitingForPage`, snapshot: as now |
| Top frame of any other tab | `stop`, as now |
| Frame (`frameId > 0`) of Fjord's tab (`sender.tab.id === tabId`, or the handover's `newTabId`) | Entered in the table with its `frame` (read from the port's first message, `frame_hello`, which carries `window.name`, never the address); sent its own `snapshot`; its `commands` lists only that frame's waiting commands and last 20 `done`s |
| Frame of any other tab | `stop` |

Routing of down messages: `open`, `send`, tools, `cancel`, `frames`, `reload` go to the top frame (`page`); `answer` goes to the
thread frame of its `(project, thread)`; the engine has already put that frame in `frames: {want}` when it issued the answer, so
if its port isn't in the table yet the worker queues the `answer` in that frame's own waiting list (`waitingForFrame[project|thread]`,
same collapse rules as `waitingForPage`) until the port connects;
`wake` goes to the port whose `wake_me` asked it (routerd's `wake` carries the `frame` the `wake_me` carried; one without goes to the
top frame). A frame port that drops is removed from the table and reported `frame_gone {frame}`; its waiting `answer`s go back to its
list for the next port of that frame.

Manifest: `content.js` gets `"all_frames": true` (`match_about_blank` stays false); `tag.js` stays top-only. In a frame
(`window !== window.top`) the script connects with port name `fjord-frame` and never runs delivery steps. `ensureTab`'s injection
uses `allFrames: true`, and its alive check (`chrome.tabs.sendMessage(tab.id, {kind: "hello"})`) passes `{frameId: 0}`, so a
frame's script never answers for the top frame. Frame loads are watched with `chrome.webNavigation` (new permission): `onCompleted`
for `tabId` and a `frameId > 0` is reported to routerd as `frame_loaded {frame, frameId}`. The frame's name comes from
`chrome.scripting.executeScript({target: {tabId, frameIds: [frameId]}, func: () => window.name})`, which runs even where the content
script didn't; a frame where it fails (a `chrome-error://` document) is reported `frame_blank` with the `src` matched from the top
frame's `frames: {have}` (which lists each node's `name` and the `src` the top frame set). The address is never used for identity.
`onErrorOccurred` is `frame_blank {frame}` at once. The
engine sets its own 20 s deadline on `frame_loaded` (`nextDeadline`, no worker timer): no `page` from that frame by then →
`frame_inject {frame, frameId}`, the worker injects once (`executeScript` with `frameIds: [frameId]`); a second miss is **blank**
in the engine. The top frame cannot see a frame's port or a `chrome-error://` document (cross-origin, `contentDocument` null), so
the worker and the engine decide blank, never the top frame.

Worker state that must survive a service-worker restart lives in `chrome.storage.session`: `tabId`, `handover`, `budget`,
`wantedFrames`, `createdInstance`. What is on screen is re-learned, not remembered: every top-frame snapshot answers with
`frames: {have}` and every frame port re-enters the table on connect.

### 1.3 The frame set

| Event | Effect |
|---|---|
| `projects` with `complete: true` | Wanted project frames := listed ids. Added ids get a frame; missing ids lose theirs and leave the Board |
| `create_project` `done` ok | Its id is wanted at once |
| A frame's `page` says the project side shows the archived stand-in (`data-composer-stand-in`, never read) | Frame removed; project `archived`; its threads fold to idle |
| Top frame `page` with a new (`loaded`, `instance`) (a reload, a sign-in return, a handover) | The document is new, so its frames are gone: the **engine** sends `frames: {want, base: true}`; the worker only relays |

The top frame's idle home is the projects page, reached by a **`home` step** that is not a run (`open` exists only inside a run,
`reach`, with `open_from`/`moving_to`/`lostOpen`; a run would loop, and a bare `open` landing after the next run's open would break its
proof). `home` is issued by `finish` only when no run remains that will act or is proving (`runs` empty of unyielded, unpaused runs
and of runs awaiting proof) and the top frame is not already on the projects page; a run submitted while `home` is wanted but not
issued skips it (so a send to the project the tab is on adds no open); one submitted after it was issued proceeds as now. `home` is
sent as an `open` of the projects page with `home: true`, so the page's existing same-kind collapse makes the run's `open` supersede
it (its `done` says `superseded`); it belongs to no run, keeps no proof and counts as a move (`moves += 1`), so the `back` rules see
it. Its `done` sets nothing on any run. Order after it: the page's own scan on arriving at the projects page sends the `complete`
`projects` read with (or just after) the open's `done`, and the engine folds it before it advances anything else, because
`backToWatched` only issues its move on the next `advance` after that `done`; so the list is read first, and a watched send's move
back to its place follows as after any move. Measured: a project made elsewhere is invisible until a fresh load (framed pages render
no sidebar at all; a hidden list page never updates; only the tab that made it sees its own row), so the `home` step's `complete`
read is **the** trigger: a project made outside Fjord gets its frame at the next idle run end, at launch, or at a handover.

### 1.4 Every frame load: the overview move

On every `page` with `loaded` in a project frame, and on every in-frame address change to `?thread=`, the frame moves itself
(`history.pushState` to `/code/project/<id>`, then `popstate`). If the next settled scan shows no overview container, it clicks
`overview-thread-crumb-back` by test id, once. If the next settled scan still shows none, it reports `frame_stuck`; the worker
reloads it once, then marks it **stale**. Thread frames never move: one that lands elsewhere is reloaded once, then stale.

### 1.5 Frame failure, retries, staleness

| Seen | Then |
|---|---|
| `frame_blank` | Reload once (`reload {frame}`: the top frame resets `src`), then stale |
| `frame_gone` without a removal | Reload once, then stale |
| `frame_stuck` twice | Stale |
| Frame `page` `signed_in: false` or `away` | The frame is stale; nothing else. Sign-in is the whole profile's, and only the top frame's health pauses runs (1.6). The top frame's next `page` with `signed_in: true` is a new document, so the engine sends `frames: {want, base: true}` (1.3) |
| Consent banner in a frame | Untouched; it never blocked the overview's rows |

A stale frame is retried at each `home` step, one reload per frame per step, **three times**; after that only a different event
retries it (a handover, a `projects` complete read, its port reconnecting, the top frame's `signed_in: true`), each resetting the
count. So an always-failing project costs at most three loads per such event, never the budget on every run end.

Per project the Board holds `watch`: `live` (its frame's port is in the table, it has sent a settled whole read of its document, and
it is on the overview), `stale(since)` or `none`. Thread facts from a stale project carry `as_of: since`. A stale project's `turning`
is read as `false` for the brief (3.2), so a finish never waits on a frame that cannot say the turn ended.

### 1.6 Engine: events by frame

`CourierCore.handle` today replaces `loaded`/`instance` on any `page` event (`pages += 1`), ties proofs to that instance, writes
`signed_in`/`page_ok` into the single health row, and quotes `notice` as a send's failure cause. Frame events must touch none of that:

- An event with `frame` goes to `handleFrame`: per-frame state `frames[frame]: {loaded, instance, settled, notice, health}`. It never
  touches `pages`, `loaded`, `instance`, `linked`, `regone`, `relinked`, the health row or `notice`.
- Its `threads` and `rows` ingest into Seen with `source: "page"` plus `frame` provenance (`row("health", ...)` is not written).
- **What a frame's rows may prove:** positive evidence only. A frame's rows merge by key into the place (add or update), so a row of
  yours a frame saw first lets `holds` pass sooner. A frame's whole `rows` read is never `full` for the Board (it replaces no rows),
  so a lagging frame render can't roll rows back; `vanished`, `returned` (words back in the draft) and `reloaded` stay top-frame-only,
  as they reason about the clicking document. `readWhole` (the top frame's settle bookkeeping, `unsettled`, `chatted`) never runs on
  a frame's rows; frame rows go through `ingest` only. The one replacement a frame may make is a guarded whole `threads` read (2),
  through a new `replaceThreads(project, listed)` in the fold.
- A frame's `notice` is kept in Seen and quoted only for that frame's own `answer` failures.
- Thread statuses from frames are recorded as in 2; `watch` is folded from the frame's `health` and `settled`.

### 1.7 The tab handover

Memory isn't readable on a stable channel (`chrome.processes` is dev-only; `measureUserAgentSpecificMemory` needs cross-origin
isolation the page lacks). `performance.memory.usedJSHeapSize` rides on every top-frame `page` event as a logged measurement only.

**Budget.** Frame **loads** grow the renderer (70 to 100 MB each, never returned); removals don't. The worker counts, per tab
instance, project-frame reloads, project frames added after the first set, every kept thread-frame open and every check (1.8); a
`frames` with `base: true` (the engine's first set for a new document) counts 0 for all it lists. Handover wanted at **6** (about
+420 to 600 MB, the measured threshold). Arithmetic: a day with 20 thread runs, each one kept frame and about one check, plus a few
reloads, is about 45 loads, 7 or 8 handovers, each under 1 s and never mid-act; a launch that owes 30 checks is 5 more. Also wanted: a top-frame
`page` whose `loaded` the worker did not create (Chrome reloaded the tab: uncounted loads).

**Grant.** The worker sends `handover_wanted`; the engine answers `handover` at once when no run is `sending`, `taken` or in a tool
step, and no `.answer` run is between its issue and its `done` or `lost` (a click cut off by the handover would answer on the page
yet report `refused`), else at the next run `finish`, an answer's `done` included. Bound: at budget **12** the next `finish` grants
it even with runs queued (they wait in `waitingForPage`, and reach the new page before its snapshot); an answer in flight still
holds it, at most one 20 s deadline.

**Order** (differs from the measured run, which closed the old tab on load and adopted through the removed-tab path: that works but
would, with `tabId` still on the old tab, make `onRemoved` ensure a third tab). State in `storage.session`: `handover: {newTabId, since}`.

1. Create the new tab (pinned, inactive, `PIN_URL`); store `newTabId`.
2. Its top-frame port connects: `onConnect` sees `tab.id === handover.newTabId` and does **not** send `stop` and does not adopt yet; it
   sends that port a `snapshot`.
3. On that port's `commands`: `tabId := newTabId`, clear `handover`, `pageGone(old)`, `page := new port`, replay `waitingForPage` into
   it, send routerd `handover_done {tabId, instance}` (the new page's `instance`; the engine then sends `frames: {want, base: true}`
   as for any new document), then `chrome.tabs.remove(old)`. `onRemoved` sees `id !== tabId` and does nothing.
4. Failure: the engine, having granted `handover`, sets its own 20 s deadline (`nextDeadline`, as for a run) and, with no
   `handover_done` from the worker by then, sends `handover_abort`; the worker also aborts on the new page's `signed_in: false`.
   Abort: remove the new tab, clear `handover`, keep the old; the budget stays and the next increment asks again. A worker restart mid-handover reads `handover` and
   continues (step 2 waits for the port; `ensureTab` injects into `newTabId` if it has none); a `newTabId` that no longer exists clears it.
   Two tagged tabs after a crash: keep the one with the newest `commands`, close the rest (existing duplicate rule).

A change inside the 1 to 3 s gap shows as state in the new frames' whole reads, which is enough: items are keyed by id.

### 1.8 Thread frames: seeing what a thread waits on

Measured: a waiting multiple-choice card is invisible on the overview (the row is identical to idle, and even that transition lags
the card by about 12 s); plan cards and plain-words approvals show as `needs`/`pie` at 15 to 37 s; only the thread view shows the card,
in 1.6 s from a kept frame or about 2 s from a frame opened on the transition. A check frame is a load like a kept one, so a kept frame
costs the same memory per thread run, is about 10 s faster, and is also the surface an answer is clicked on. **Chosen: a thread frame
per running cloud thread, cap 3; beyond the cap, and for owed checks, the same frame used as a check.**

Two kinds, so checks are always serviceable: **kept frames** (cap 3, shared by `working` threads and threads holding a pending
card, which keeps the frame as the answering surface), and **one check slot** of its own, which never holds a frame past one
settled read. A frame opened for an `.answer` is a kept card frame. When a `working` thread needs a slot and all three are held, the
least recently used card frame (by its last card event) is evicted; its thread keeps its `needs_you` and `.answer` reopens a frame
on demand. The engine owns both sets (1.2). Load arithmetic for a question-heavy thread: ten questions in one run is one load (the
frame stays through card, answer, working, card), not ten; evictions add one load per reopening.

| Event | Thread frame |
|---|---|
| Row new or goes to `working` for a cloud thread (no `session` on the Board), under the kept cap | Kept frame opened |
| Same, over the cap | Evict the LRU card frame if any; else owed check queued |
| Project frame's row is `paused` (settled) **and** the kept frame's settled read shows no pending card and empty slots | Confirmed idle: status `done` (2); frame removed. The thread side's `turning` is never the signal: `turningNow` is true only while the bottom assistant row streams and drops between a message and a tool step, so it would tell a false finish mid-run |
| Same, but the project frame is stale | Measured: a running tool shows only as the thread composer dock's `[data-testid=code-prompt-stop]` (with `code-prompt-send` disabled), no spinner and no `aria-busy`; a streaming reply is a row with `data-perf-row-streaming=true`, `data-busy`, `data-is-streaming`; idle is no `code-prompt-stop`. Confirmed idle from the thread side: a settled read with no `code-prompt-stop` in the thread's dock (the second `rail-composer-dock`), no streaming row, no pending card, empty slots. Caveat: `code-prompt-stop` lingered after a `needs` until the next load, so its presence never means working on its own: it only withholds the finish, and a lingering one is cleared by the frame's next load (every reload resets it) or by the project frame coming back live, whose row then decides. The thread frame reports `stop: bool` with its `rows` |
| `.answer` needs a frame and the three kept slots are held by `working` threads | The answer frame takes the **check slot** (a check in flight is requeued first); an answer never waits for a slot. Once answered it stays as a kept card frame only if a slot is free, else it is removed after the proof |
| Kept frame's read shows a pending card | `needs_you` (below); frame kept |
| Row goes `needs` with no card (a plain-words request, 2) | The thread's frame, kept or check, is removed after its read; the project's model call writes the question from the reply that check read (3.3). Under a stale project frame such a request stays invisible until the frame is live again (no row, no `needs`); the project's `as_of` says so, and that is accepted |
| Row leaves the active list (all three sections: `needs`, `running`, `active`), to `done` or gone | Frame removed |
| **Owed check** queued for: a `working` thread over the cap once its row goes `paused`; every `paused` cloud thread with no thread-view read since its last `working`; after launch, a handover or any stale period of its project frame, every `paused` cloud thread whose row changed (structure or `time[datetime]`) since its last read, or never read; a thread with an open `needs_you` whose card isn't confirmed by a read | One entry per thread, needs-you first, then newest `time[datetime]`; served one at a time in the check slot: one settled read, then removed |
| Pending `[data-testid=decision-card]:not([data-state])` | status `needs you` from the thread view, with the card row's key, kind (`plan` when the row says `needs`/`pie`, else `question`) and the options' texts as data |
| `data-approval-cluster-host` or `data-approval-dock` non-empty | `needs_you` with `needs: permission` (3.7) |

Bounds: checks are loads, so they are in the budget (1.7); only threads touched within 24 h are checked unprompted (an older
`paused` thread shows "stopped, unchecked" and is checked when you expand or open it, or when its row changes), and a launch with
30 recent paused threads is at most 30 loads over a few minutes (about 5 handovers, each under 1 s). The owed queue is engine state in
`router.db`, so a handover loses none; a check in flight when a handover is granted is requeued first.

Local threads (the Claude app's sessions, which have a `session` on the Board) need no frame: `interruptedAwaitingPerson` in the
session file gives `needs you` at file change. Remote Control threads have no local file and are cloud threads here.
Thread frames are removed before a handover; the engine's first `frames` to the new document carries `base: true`, and the worker
counts 0 for every frame in a base set (the kept frames of `working` threads are reopened in it). Measured: loading a thread in a
frame does not clear the page's unread mark (unread: the row's title as `bdi.text-prose-semibold` plus a `span.sr-only`; read:
`bdi.text-prose-medium`, no `sr-only`; cleared when the row goes back to `running`; no per-thread mark in the sidebar). One mixed
case: a thread that went `needs` while its thread-view frame was open showed as read. Plainly: a kept frame on a `working` thread
can make that thread's new question show as already read in the owner's own claude.ai view. Chosen: accept it. The brief is the
owner's inbox for these (every `needs you` shows there whatever the page's mark says), and the kept frame is what makes the
question appear within 2 s; checks (one read, removed) never cost the mark. Fjord's own read mark is separate and the page's mark never
touches it; the row's mark is reported as data (`unread: bool` on `threads` rows) and shown as the page's mark, never read for
meaning. The brief shows a `needs you` whatever the page's mark says.

## 2. Facts: one log, every item stored once

Seen is the one log. Every observed item is stored once, under its own id, and seeing it again with the same content adds nothing: a
reload, a handover, a second frame reading the same page, a coordinator repeating itself. Nothing is ranked by source and nothing is
merged by rule; the model that writes the brief (3) reads the items and decides what they add.

| Item | Id | Seen from |
|---|---|---|
| Project | `chan_…` | The projects list |
| Thread | Root message id (`data-home-card`) | `threads` rows, the thread view |
| Message row | `data-entry-key` | Rows of the project chat (the coordinator's included) and of a thread view |
| Question card | Its row's key | A thread frame (1.8) |
| Local session | Session id | `CourierLocal` (files, processes, `interruptedAwaitingPerson`) |
| Thread status change | `(thread, status)` | Row sections and thread-view reads, below |

A row whose content changed (a card `answered`, a start row's glyph) is new content of the same id. A streaming row is stored when its
turn settles, not at every growth; `turning` and a streaming row's text are page state, never items.

**Status.** A thread is `working`, `needs you`, `paused` or `done`. content.js's `rowState` maps `active + dashed` to `idle` and the
spinner to `unknown`, which made a waiting card look finished; it now says `needs → needs you`, `active + animate-spin → working`,
`active + dashed → paused` (a turn ended: idle or waiting), else `unknown`. Measured, the overview rows are:

| Row | Status |
|---|---|
| `data-home-section=needs` | needs you |
| `section=running` (inside `section[data-home-group=running]`, which exists only while a thread runs), or the spinner | working |
| `section=active` + mark `dashed` | paused: idle or waiting on a card; the thread-view read decides. Some finished threads end here rather than in `done` |
| `section=done` (inside `section[data-home-group=done]`), mark `icon` | done |
| Gone from `active`/`running`/`needs` on a `listed` read (below), no `done` row seen | done |
| Gone from `done` | Nothing: the group keeps 20, the oldest dropping out is no live thread's departure |

A thread's status is recorded only when it differs from the last one recorded for that thread id, and that change is an item. A
pending card in a thread-view read makes the thread `needs you` whatever its row says. A `paused` thread with no thread-view read
shows as "stopped, checking" until its owed check (1.8) and is not recorded `done` before it; a read with no card, empty approval
slots and (under a stale project frame) no `code-prompt-stop` or streaming row is confirmed idle, and records `done`. A local
session's status comes from its file. Fjord never clicks the `done` group's expand button (that is the owner's view state); whether
its rows are in the DOM while collapsed is unrecorded, and both cases give the same status.

**Departures.** `threads` is a delta, so a thread leaving while others stay was never said (only an emptied list was). content.js
now emits, in the same `threads` event, `{"thread": id, "gone": true}` for every id in `told.threads` missing from the rendered list,
under the conditions the emptied case already requires (project composer mounted, no thread open, this visit's rows seen), and drops it
from `told.threads`. Across documents (a new frame, a handover) a **settled whole** `threads` read replaces the project's active list
only under the same guards, carried on the event as `listed: true`: composer mounted, no thread open, this visit's `/timeline` fetch
ended, and the overview **loaded by structure**, judged on the active sections only (`needs`, `running`, `active`; `done` rows are
ignored, so a `data-home-state=ready` that belongs to done rows never passes a still-loading active list). Loading shows only
`[data-testid=overview-tab-strip]` and `[data-home-section=active]` with no rows and no empty line. Loaded with active rows shows at
least one row in `needs`, `running` or `active` inside a non-done group with `data-home-sort=priority][data-home-state=ready]` on that
list. Loaded with **no active threads** shows `[data-home-section=active]` carrying `section[data-testid=home-empty-band]` +
`div[data-home-empty-line=true]`, no row in any active section, and exactly one non-done `[data-home-group]`. The empty band alone is
not enough: it also appears in the `needs` section of a loaded list with active rows, and a `needs` band beside a still-loading
`active` list makes no departures. The loaded state came 0.1 s to 6 s after the tab strip, which is why structure, not a grace,
decides. This is the one place a frame's whole read replaces Board state; rows never do (1.6). A Board-`working` thread absent from a
`listed` read is a departure and records `done`; a non-`listed` read says nothing, so every listed read either shows the row or ends
the thread's run.

**Plain-words approval.** Measured: a request with no card goes `running` straight to `needs` (`svg.text-warning`,
`a[data-home-status-line]`), 15 s after its last reply, never through `active + dashed`; the thread view shows no card and no slot
content, and the dock's `code-prompt-stop` lingers. So the row's `needs you` is the status, the dock's stop is ignored for a thread the
row says `needs`, and the question is written by the project's model call from the reply the check read (3.3).

**Coordinator.** Its rows (including `channel-created-thread` cards and their glyph, which goes `working` → `CheckCircle` when the
thread finishes) are items like any other. Nothing ties a coordinator row to a thread and nothing depends on the coordinator
reporting: thread statuses come from thread rows, and the model reads the coordinator's words next to them (3.3).

## 3. The per-project brief

### 3.1 Document

One per project in `router.db` (`briefs`: project, version, at, fields, diff, `cursor`).

| Field | Written by | From |
|---|---|---|
| `purpose` | Model, only when the goal changed | Goal, instructions |
| `watch` | Deterministic | Board (1.5) |
| `threads[]`: id, title, status, age, source, as_of | Deterministic | Board |
| `now` (1 to 3 lines), `needs_you[]` (thread, kind, question, options as data, since), `decisions[]`, `loose_ends[]` | Model | New items + the current brief |
| `routing_notes` | Yours (Notes) | Unchanged |
| `sent[]`: intent id, words, state | Deterministic | Intents |

A card's options are copied from the card item as data, in the page's order and words; a plain-words request gets a question the model
writes from the reply the check read.

### 3.2 Triggers

The deterministic part (the thread list with status, `as_of` for a stale project, `sent[]`) is rebuilt on every Board change of the
project, instantly, with no model. The model call runs when the project has new items past its `cursor`:

| New item | Call |
|---|---|
| A thread's status → `needs you`, a card seen, a local session stranded or its app closed | At once |
| Any other (messages, coordinator rows, other status changes, a new thread) | When the project's coordinator isn't mid-turn (`turning` false; a stale project counts as false), so its repeat lands in the same call; at once if no coordinator turn runs |
| Goal or instructions changed | A call that writes `purpose` only |
| `turning`, streaming text, your send, reload, handover, stale ↔ live, time passing | No call (not items, or already deterministic) |

One call per project at a time. Items that arrive during a call wait for the next one: the project is marked dirty and one call
follows on return, from the brief that call produced. Events decide, never timers.

### 3.3 The call, failures, persistence

Input: the project's new items since `cursor` and its current brief. Output: whether anything is worth telling, and the updated brief
(`now`, `needs_you`, `decisions`, `loose_ends`), leaving out what the brief already covers. This is the whole answer to a coordinator
repeating a thread's finish, a late report, or a coordinator that never reports: the model reads the brief, there are no rules for
them.

Haiku 5.5 (`claude-haiku-5-5`, the id the app's Haiku calls already use), about 1.5k tokens in and 150 out, about $0.002. Every call
(project, lead, plain-words question) is built with `RouterStyle.prompt(rules, style:)`, so the owner's style setting (SettingsView)
still shapes the words; `RouterStyle` moves out of `RouterBrief.swift` into `RouterStyle.swift` with its Settings binding. The answer
is checked: thread ids must exist, a card entry's options equal the card item's, `now` is cut at three lines, a decision names a
thread or your send. On failure the previous prose stays with `prose_stale: true` ("being rewritten"); the items are already stored.

Persistence: `cursor` is the last log position the brief covers, stored per project; it advances only on a landed answer. At launch
every project with items past its cursor runs, so a quit mid-call is rerun. After three failures in a row the project waits for its
next new item, the next launch, or the end of the next general-brief batch (4), whichever comes first.

Later, not in v1: Jev as a cheap filter in front of the call ("anything worth telling?"), measured on real data before it is added.

### 3.4 History and Revert

Each version is a row with its new items and prose diff; the view's history lists them. Revert applies to acts (archive, mark read, a
goal change) as reversible intents with `before`; prose is never reverted.
### 3.5 Acting from it

- A `needs_you` entry is the only place a thread's question shows: the question and, for a card, its options in the page's order
  and words.
- **Picking option N** shows live on the entry; **Return confirms** (an answer can't be unsent, so it's a decision, not a reversible
  act). It submits `.answer(project, thread, card, option)`. The worker routes it to the thread frame, opening one on demand (1.2):
  the frame's settled read must list the card's key as pending; then it clicks the nth `ul[role=list] button` of
  `[data-testid=decision-card]:not([data-state])` in that row, by structure, no composer, no tab move. Proof: the card's
  `answered: true` in the frame's rows, then the row `working`. Retry once at the 20 s deadline, safe under the guards: a button
  `aria-busy` or `disabled` is never clicked again, a card `answered` or absent ends with `refused` ("already answered" / "card
  gone") and the entry refreshes from the Board. A second failure shows `failed` with Open. A plan card's first option is the page's
  own approval, in the page's words.
- **Typing** with the composer pointed at the entry sends `.send(words, project, thread)`: explicit target, no model; it answers a
  card too (measured 4.5 s) and is the only way for a plain-words request.
- **Local threads** are entries too (5.0): their `needs_you` carries the plugin hook's `FormSnapshot`; picking an option or typing
  goes through `RouterFormReply` on the entry (the hook-based answer through the signed plugin, as today), with options as chips
  that fill the draft and Return.
- **Leaving:** one rule for both briefs. A `needs_you` entry leaves when the thread's status leaves `needs you` on proof (the row
  `working` or gone, the card `answered`, the file no longer interrupted), or when you mark it read (reversible). The general
  brief's count is the entries not yet read.
- Open: `chrome.tabs.create` active (you asked). Send elsewhere: the @-pill; the decision shows live; Return confirms. Archive and
  mark read: at once, Revert in history.

### 3.6 Engine additions and the protocol (EVENTS.md additions)

```swift
case answer(project: String, thread: String, card: String, option: Int)   // CourierIntent; card = the decision row's key
```

An `.answer` run never takes the top tab: it is outside `tabFree`, `acting` and `yielded`. It holds the frame's document instead:
`frame_instance` (the frame's `loaded`, `instance` from its `page`), `clicked` from its `done`, and `lost` when `frame_gone` or a new
`frame_instance` comes before its `done` (the `lostOpen` equivalent); a lost answer is reissued once to the frame's next port, after
that port's `commands` replay says it neither ran nor waits (the per-frame replay in 1.2). Proof and refusals as in 3.5.

| Message | Direction | New |
|---|---|---|
| `frame_hello {name}` | frame → worker | A frame port's first message, `window.name` (`fjord:<project>:<thread|->`); distinct from the top frame's `hello` alive check |
| `frame: {project, thread, frameId}` on `page`, `rows`, `threads`, `notice`, `wake_me`, `done`, `commands` | frame → routerd | Provenance |
| `wake_me {after, frame}` / `wake {frame}` | up / down | A wake goes to the port that asked; none means the top frame |
| `frames {want: [...], base}` / `frames {have: [...]}` | down to top / top in every snapshot | The wanted set and what is on screen |
| `reload {frame}` | down to top | `src` reset |
| `frame_blank`, `frame_gone`, `frame_stuck` `{frame}` | worker or frame → routerd | 1.2, 1.4, 1.5 |
| `threads` row `{thread, gone: true}`; `threads` event `listed: bool` | up | Departures (2) |
| `rows` row `answered`, `options` (texts); `rows` event `stop: bool` (the thread dock's `code-prompt-stop`) | up | Thread-frame decision rows and the running-tool signal (1.8) |
| `threads` row `section` (`needs`/`running`/`active`/`done`), `unread: bool` (`bdi.text-prose-semibold` + `span.sr-only`); `threads` event `listed: bool` (loaded by structure, 2) | up | Row states; the page's read mark as data; the whole-list guard |
| `rows` row `index` (`data-epitaxy-entry-index`) and `card: {glyph}` for a project-chat row with a `channel-created-thread` card | up | Row content, stored as an item (2) |
| `answer {id, project, thread, card, option}` / its `done {ok, refused, error}` | down to thread frame / up | 3.5 |
| `open {id, project: null, home: true}` / `done` | down to top / up | 1.3: sent as an `open`, so the page's same-kind collapse lets a run's `open` supersede it; the engine ties `home: true` to no run |
| `frame_loaded {frame, frameId}`, `frame_blank {frame}`, `frame_gone {frame}` | worker → routerd | Worker-originated, always with `frame`; blank's deadline is the engine's (1.2) |
| `frame_inject {frame, frameId}` | routerd → worker | Inject once into that frame |
| `handover_wanted {budget}` / `handover` / `handover_done {tabId, instance}` / `handover_abort` | worker ↔ routerd | 1.7 |
| `rowState`: `paused`, `working` | up | Replaces `idle`/`unknown` for those rows |

### 3.7 Permission prompts

The owner's Remote Controls run `--permission-mode auto`, so no prompt is expected (measured: `touch` and `rm` on a granted folder
ran with the approval slots empty). If a thread blocks anyway: a thread frame whose approval slots hold any element reports
`needs_you` with `needs: permission` and the slot's text as data; a thread with no frame gets it at its owed check. The brief shows
"waiting for a permission" with one act, Open. Fjord clicks nothing in a prompt it never measured, and `.send` to such a thread is
`refused` with that cause until the slots empty (whether the composer takes words then is unknown), which also clears the entry. A
local thread in a non-auto mode sets `interruptedAwaitingPerson`: same entry, answered in the Claude app.

One measurement, if the owner allows a non-auto Remote Control run (`--permission-mode default`, a scratch folder, one tool call that
asks), would add: the prompt's structure (test ids, button order, an answered marker), the row's `data-home-*` and lag during it,
whether the composer is disabled or takes words, whether and when `interruptedAwaitingPerson` is set, the proof of an approval (slot
empties, then `working`), and the frame's memory with the dock mounted. With those, approving becomes an `.answer`-style click with
Return and the `refused` send rule is kept or dropped on evidence.

## 4. The general brief

Built from the project briefs.

| Part | Rule |
|---|---|
| Lead (2 to 4 lines) | One Haiku call over every project's `now` and open needs-you entries. It runs after a batch of project calls changed what needs you or what finished, when no project call is in flight and the lead is dirty. Mark read, Revert and showing a section never trigger it; the view's counts are deterministic |
| Order | Needs-you projects first (oldest need first), then stranded, finished-untold (newest first), working, quiet; local-only projects in the same order |
| Size | 12 sections; the rest fold to one line of names |
| Per section | `now`, the needs-you entries, threads touched in 24 h, `sent[]`; the rest on expand |
| Staleness | "as of 12m ago" in a stale section's header |

The told rule moves from `DigestPage` to `RouterBriefView` (`BriefTold`): an entry leaves once its section was shown and settled.

## 5. UI and the files

The Router window: the composer with the pill and the live decision; above it the general brief; a section opens to the project
document; history (your messages, acts, Revert, prose versions) is a drawer under the composer.

**Keys**, live only while a brief entry is focused and the composer is empty (else every key types): Return reply or confirm; options
by physical top-row key codes (`NSEvent.keyCode` 18, 19, 20, 21, 23, 22, 26, 28, 25 for 1 to 9, the same keys on AZERTY where the
unshifted characters differ) and by click; O open, A archive, R mark read; Esc back. The bar mark counts untold needs-you.

### 5.0 One model: brief entries, no cards

`Router.swift` keeps `RouterCard` with `var triage: RouterTriage?` and `RouterTriage.kind(...)`, `Store.routerTriager`, and kept files
are built on `RouterCard`/`RouterState` (RouterFormReply, RouterMCP, RouterCarry, RouterDecisions, RouterRoute, RouterRun,
PaletteRouterSource, Models, FjordChange, Store). Keeping cards for local threads would be a second model. **Decided: the card model
goes; every thread, local or cloud, is a Board thread, and what you act on is a `BriefEntry`.**

```swift
struct BriefEntry: Codable, Hashable {  // RouterBriefDoc.swift
    var project: String; var thread: String            // Board ids (a local-only session: its session id)
    var kind: Kind                                     // question(card), plan(card), request(plain words), permission, stranded
    var state: ThreadState; var since: Double; var source: Source; var asOf: Double?
    var question: String?; var options: [String]       // the card's words, or the asks call's reading
    var card: String?                                  // the decision row's key (cloud)
    var form: FormSnapshot?                            // the plugin hook's form (local)
    var sent: [SentLine]
}
```

| Was | Becomes |
|---|---|
| `RouterCard`, `RouterState`, `RouterTriage`, `RouterTriage.kind` in `Router.swift` | Removed; `Router.swift` holds the `RouterModel` over `BriefDocs` (per project) and the general brief |
| `Store.routerTriager`, the card tables, `SessionRowBox` | Removed in the launch migration (no legacy) |
| `RouterFormReply.init(card:form:)` | `init(entry:form:)`; the hook-based answer through the signed plugin is unchanged; `CardJudge.ask` takes the entry's form and your words |
| `RouterMCP.card(store, id)` and the agents' card tools | `entry(store, project, thread)`, `brief` (the general brief's text), `entries` (needs-you list), `answer(project, thread, option|words)`: the same acts the view has |
| `PaletteRouterSource` rows from cards | Rows from entries (needs-you first, then threads touched in 24 h), same glyphs |
| `RouterCarry`, `RouterRoute`, `RouterRun`, `RouterDecisions`: a card id as the target | `(project, thread)`; a local target carries its session id through the Board's `session` |
| `Models` card types | Removed; `BriefEntry`, `BriefDoc` are the stored types |
| `FjordChange.cardAction` | `.briefAction(project, thread, act)` with Revert |
| The plugin hook's form push (`GuestRouterRuntime`) | Lands in Seen as a `files` row (`form` field) for that session, so `CourierLocal` and the hook agree on the thread |
| `RouterDispatcher`: `Job.reply(session:card:)`, the `answer`/`answerPlan` effect closures keyed by a card id, `"answer:<card>"` targets | `Job.reply(project:thread:)`; the closures take `(project, thread)` and the entry's `FormSnapshot`; targets are `"answer:<project>/<thread>"`, checked against the open entries instead of `routerShownOpenCards` |
| `GuestRouterRuntime` (~366, ~379): `store.router.cards.first { $0.id == cardID }`, `card.isOpen`, `guestPendingForm(for: card)` | `store.brief.entry(project, thread)`, open while its `kind` is a form kind, and `guestPendingForm(for: entry)`: the form is the entry's `form` (the hook's `FormSnapshot`), and the holds check keeps comparing `form.id` and `toolUseID` |
| `RouterComposer.replyTo` (a card id; the "Stop replying to" chip) and `RouterJev.replyTo` (validated against `cards`) | `replyTo: BriefTarget?` = `(project, thread)`; the chip names the thread's title; Jev's `RouterContext(replyTo:)` carries the same target, validated against the Board's threads |
| `JevGate` `.cards` case | `.entries` (the gate reads the needs-you entries) |
| `RouterProjectContext` (206–215): `store.routerShownOpenCards` filtered by `RouterTools.waitsOnYou` into each session's `f.waiting` | The project's open `needs_you` entries (kind question, plan, request, permission), by `since`, into the same `LocalFacts.waiting`; `RouterTools.waitsOnYou` becomes a set of `BriefEntry.Kind` |
| `RouterPage`'s History half (33 card uses: the conversation with the Router, addressed items, their cards) | The **drawer** (`RouterDrawer.swift`): your messages with their pill and state (`sent[]`), the acts with Revert (`.briefAction` rows), the brief's prose versions (3.4), and answered entries as one line each (thread title, what you answered, when); it reads `RouterDecisions`, the `briefs` table and Told, never a card |
| `AppWindow` (~1309), `Agents` (~344), `HubController`, `HubSections`, `HubView`, `System` (every `.cards` read: counts, rows, the bar mark) | The general brief's untold needs-you entries (`store.brief.needsYou`) |
| `PaletteTriageSource` (~82), `PaletteRouterSource` | Rows from entries |
| `Playground` (~467), `Demo`, `AppWindowShots`, `DemoJevAttention` | Demo scenarios populate `BriefDocs` and entries; the card scenarios go |

Every other `.cards`, `RouterCard` or `RouterState` use (the grep: `Models`, `FjordChange`, `Store`, `RouterBrief`, `RouterCardJudge`,
`RouterCarry`, `RouterDecisions`, `RouterFormReply`, `RouterKeys`, `RouterMCP`, `RouterRoute`, `RouterRun`, `RouterView`) is covered by
the rows above or by its file's deletion; the migration commit compiles only when `grep -rn '\.cards\b\|RouterCard\b\|RouterState\b'
Sources/Fjord` is empty.

### 5.1 Deleted, with where each need goes and what moves out first

| Delete | Gave | Now; types moved before deletion |
|---|---|---|
| `RouterCanvas`, `RouterCanvasBeta`, `RouterCanvasNodes`, `RouterCanvasLayout`, `RouterCanvasPending`, `CanvasObstacles` | The canvas and the Brief/canvas/list switch | Gone. `RouterCode` loses `FlightLayer` and `RouterLayoutSwitch` |
| `RouterZones`, `RouterFilter`, `RouterSearch` | Now's sections, solo/mute, search | Order in 4. `AppWindowKeys`, `RouterKeys` and `Store` drop the search bindings and field |
| `RouterPage` (Now half), `RouterSessions` | Lists, session rows, menus | Sections. `RateLimitWarning` → `RateLimitWarning.swift` (HubView); `SessionGlyph` → `SessionGlyph.swift` (Palette, PaletteView); `BlinkingDot` → `Motion.swift` (Motion, Lifecycle) |
| `RouterWaiting`, `RouterLive`, `RouterSummary`, `RouterLife`, `RouterLifeView` | CI waits, step line, click summaries, two lines per session | `turning`, `for`, `now`. `SessionLife` users: `AppWindowShots` gets brief shots instead; `Router.swift` drops it |
| `RouterTiers`, `RouterAttention`, `RouterCircles`, `RouterDepends`, `DemoJevAttention` | Tiers, banners, stuck and dependent detection | Facts and the bar mark. A `ThreadState` enum in `RouterBriefDoc.swift` replaces `Tier` for `RouterBrief`, `Store`, `Router.swift`, `UntrustedText`, `Demo` (Demo gets brief fixtures); `AwayStrip` goes with its key in `RouterKeys` |
| `RouterCardAction`, `RouterChangeCard` (card part), `RouterSent` | Per-card acts, change cards, sent line | `FjordChange.cardAction` becomes `.briefAction` (archive, mark read) with Revert; `sent[]`. `ClaudeButton` → `ClaudeControls.swift` first (users: `RouterCourierPill`, `RouterProjectProposalPill`, `RouterChangeCard`'s kept part); `ClaudeMark` has its own file and stays |
| `RouterDigest`, `RouterDigestWriter` | The prose Brief and its timer writer | `RouterBriefDoc` + `RouterBriefView`; `RouterMCP.briefText` returns the general brief's text (the agents' MCP brief tool keeps working); `Store`, `Router.swift`, `RouterView` point at the new type; the told rule → `BriefTold` |
| `RouterTriage`, `RouterTriageExtras`, `RouterReplies` | Per-turn triage, card clearing | A reply clears `needs_you` on proof; `Store`'s card tables go in the launch migration (no legacy). `RouterCardJudge` is **kept, trimmed** (moves table) |
| `RouterForms` (card views only) | Claude's form cards redrawn | Options are the entry's rows; `ClaudeButton` and `CDSTextArea` moved out first |
| `RouterFlight` | The flight animation | The pill; `RouterComposer` drops `FlightStack` and its flight code |

Moves the kept code still needs, each done before its file goes:

| Type | From | To (users) |
|---|---|---|
| `SessionFence` | `RouterTriage` | `SessionFence.swift` (RouterRun, RouterFormReply, RouterMCP, UntrustedText, RouterBrief) |
| `CardJudge.ask`, `sure`, `timeout`, `clearly` | `RouterCardJudge` | `RouterCardJudge.swift` is **kept**, trimmed to `ask`, `sure`, `timeout` and `clearly` (all used by RouterFormReply's local plan approval and option pick, now on an entry's form); `content`/`questions` over a `RouterCard` are rewritten over the entry, and the card-clearing part and `JevGate`'s `CardJudge` case go |
| `Claude.Chooser` | `RouterCardJudge` | `ClaudeChooser.swift` (CategorySections, RuleLogic) |
| `Claude.TranscriptStep`, `recentTimedSteps` | `RouterSummary` | `TranscriptSteps.swift` (GuestTranscripts) |
| `ClaudeButton`, `CDSTextArea` | `RouterForms` | `ClaudeControls.swift` (RouterCourierPill, RouterProjectProposalPill, RouterChangeCard, SettingsView). `ClaudeMark` has its own file: not moved |
| `ClaudeLinkStatus` | `RouterSessions` | `ClaudeLinkStatus.swift` (HubView) |
| `SessionRowBox` | `RouterSessions` | Deleted with `Store`'s field, in the launch migration |
| `BriefHistoryToggle`, `BriefUpdated` | `RouterDigest` | `RouterBriefView.swift` (RouterCode, for the new brief) |
| `DigestAction` | `RouterDigest` | Replaced by `BriefAction` in `RouterBriefView.swift` (RouterKeys) |
| `firstSentences` | `RouterLive` | `RouterBrief.swift` (its only kept user) |
| `routerJevAttention` | `DemoJevAttention` | Its shot is removed from `AppWindowShots` |
| `CanvasMetrics`, `CanvasTransform`, `RouterLeaf` | `RouterCanvasLayout`, `RouterLife` | Their shots are removed from `AppWindowShots`; deleted |
| `RouterStyle` | `RouterBrief` | `RouterStyle.swift` (SettingsView, the new calls) |

### 5.2 Kept, with purpose

`Router.swift` (model root, trimmed of Now and `SessionLife`); `RouterView` (window model: pick, draft, chips, trimmed); `RouterRoute`
(the chosen target type); `RouterRun`, `RouterStream`, `RouterJev`, `RouterProjectDecide`, `RouterProjectContext` (the one model
decision); `RouterStatus`, `RouterCapabilities`, `RouterPrepare` (environment, off-main work); `RouterKeys` (re-targeted at the
brief); `RouterCarry`, `RouterCancel`, `RouterChangeGate`, `RouterFormReply` (the local-thread route, forms and cancel through the
signed plugin, now on entries; `FormSnapshot` stays for `RouterDispatcher` and `GuestRouterRuntime`); `RouterCardJudge` (trimmed to
`ask`); `PaletteRouterSource` (rows from entries); `RouterCode` (layout, minus flights);
`RouterCourier`, `RouterCourierPill`, `RouterCourierSetup` (the engine link, pill, setup); `RouterFjord`, `RouterMCP` (Fjord's own
tools and the MCP brief tool); `RouterMentionField`, `RouterPointer`, `RouterComposer` (composer and @-pills);
`RouterProjectProposal`, `RouterProjectProposalPill` (the live decision); `RouterDispatcher`; `RouterDecisions` (the drawer's data);
`RouterTranscript` (prose styles); `RouterBrief` cut to the asks call. Each deletion is one commit after its users compile and tests pass.

## 6. Tests

Fakes must model: the 12 s lag of the row after a card; waiting rows identical to idle; frames jumping to `?thread=` on load; a thread
leaving while others stay; a new tab that waits for the old one's close.

| Piece | Test | Where |
|---|---|---|
| Port table: frame ports from Fjord's tab never adopted; a frame connecting mid-send leaves `page`, `waitingForPage` and the send untouched; `answer` routed to its thread frame, queued when none; `wake` to the asking port; foreign-tab frames told `stop` | node with a stubbed `chrome` (tabs, runtime, storage.session, webNavigation, scripting) | `poc/router/extension/test/worker.test.js` |
| Handover while the old tab is known: new port not stopped, adopted on its `commands`, old closed after, no third tab; failure keeps the old; worker restart mid-handover resumes | same | same |
| Blank: `onErrorOccurred`, `onCompleted` with no port → inject once, then `frame_blank` | same | same |
| Engine: a frame's `page`/`notice`/`signed_in` leave `pages`, `loaded`, `instance`, health and `notice` unchanged; a frame's rows pass `holds` but never `vanished`/`returned`; a frame's whole `rows` read replaces no rows, and only a `listed` whole `threads` read replaces the active list | fake_page grows frames with `frame` | conformance bridge, `poc/router/tests` |
| Dedupe: re-reads of the same id with the same content (a reload, a handover, a second frame, a coordinator repeat) add nothing to Seen; changed content of an id is stored once | Seen fixtures through the log | `CourierBoard` tests |
| Status: a change is recorded once per thread id; the same status re-read adds nothing; a pending card with a dashed row is `needs you`, never `done`; a departure among others and a row moving to `done` record `done`; `paused` becomes `done` only after a no-card read; a plain-words request (`running` straight to `needs`, stop lingering in the dock) is one `needs you` | fixtures | `CourierBoard` tests |
| The model call gets the project's new items past `cursor` plus its current brief, nothing older | pure `BriefTriggers`, canned answers | `swift test --filter BriefTriggers` |
| A coordinator repeat of a thread's finish adds no entry (canned model answer given the brief that already covers it); a late report and a coordinator that never reports behave the same way | canned answers | `swift test --filter BriefDoc` |
| Triggers and coalescing: needs-you status or a card calls at once; other items wait for the coordinator's turn to end; items during a call mark it dirty and one call follows; one call per project at a time | pure `BriefTriggers` | `swift test --filter BriefTriggers` |
| Cursor: a quit mid-call reruns the project at launch from its stored cursor; it advances only on a landed answer; three failures then retry on a new item, launch or batch end | canned answers | `swift test --filter BriefTriggers`, `BriefDoc` |
| The lead runs after the batch and not on mark-read | canned answers | `swift test --filter GeneralBrief` |
| Owed checks: a card already waiting at launch, one in the handover gap, one whose whole working phase passed under a stale frame, all found; three threads holding cards (kept) and a fourth thread's card is still found through the check slot; three `working` kept frames and an `.answer` takes the check slot at once; LRU card eviction when a working thread needs a slot; cap and queue order; a handover requeues the check in flight | fake overview + thread views | bridge |
| Confirmed idle: a kept frame's no-card read after `working` records `done` once; the row leaving later adds nothing; a card answered inside the 12 s lag then a second card are two card items | fixtures | `CourierBoard` tests |
| `home`: issued only with no run left; a run submitted before it is issued skips it; one submitted after has its `open` supersede the home's and its proof holds; an always-failing project frame is reloaded three times across run ends, then only on a handover | bridge | `poc/router/tests/test_home.py` |
| A project frame connecting after its own `?thread=` jump is identified by `window.name`, not its address; the engine's `frames` is the only source of the set (a worker-added frame doesn't exist by construction: the stub asserts the worker never calls the top frame but with the engine's `want`) | node stub + bridge | worker and bridge tests |
| A frame's first partial whole `threads` read (no `listed`) makes no departures; a `listed` one does; a `working` thread missing from a `listed` read is a departure and records `done` with no read | fake overview | bridge |
| `ensureTab`'s alive check when only a frame's script would answer: `{frameId: 0}` makes it inject the top frame | node stub | worker tests |
| An `.answer` issued, then the budget reached: no `handover` until its `done`; one cut off by `frame_gone` is reissued once after the replay | bridge | `test_answer.py` |
| A plan card found by a kept frame, then the row's `needs`: one status change, one entry, one model call | fixtures | `CourierBoard`, `BriefTriggers` |
| `listed` by structure: tab strip alone makes no departures; a `needs` band beside a still-loading `active` list makes none; `ready` on done rows only never passes; active rows or the empty line in `active` does; a project with only finished threads is listed right and a `working` thread absent from it records `done`; the oldest `done` row dropping out records nothing; a thread ending in `active + dashed` waits for its read; a resumed thread with `CheckCircle` re-read through a frame reload adds nothing; a `running` row or a pending card outranks a `done` signal | fake overview and project chat | bridge, `CourierBoard` |
| Confirmed idle under a stale project frame: no `code-prompt-stop`, no streaming row → `done`; a lingering stop withholds it until the frame's next load or the row's `paused` | fake thread view | bridge |
| After a top-frame reload or sign-in return, the only `frames` the top frame receives is the engine's `base: true` set; the worker sends none of its own | node stub + bridge | worker and bridge tests |
| Entries: a local thread's form entry answered through `RouterFormReply`; `RouterMCP.entry`/`answer`; the palette lists entries; `RouterProjectContext` builds its waiting context from the project's open `needs_you` entries | `swift test --filter BriefEntry` | app tests |
| `.answer` with no open frame opens one, confirms the key, clicks once; retry once; refused when answered or gone | fake thread view | `poc/router/tests/test_answer.py` |
| Keys: 1 to 9 by key code with an AZERTY layout, O/A/R inert while the composer holds text | `RouterKeys` tests | `swift test --filter RouterKeys` |
| The view | `--window-shots .build/shots brief brief-needs-you brief-stale brief-quiet` | `AppWindowShots.swift` |

The one live check, when asked: three real projects framed. Send a message that makes a thread ask two multiple-choice questions and
then present a plan. Expect: the first card's entry with its options under 3 s of the card, with no top-frame visit; option 1 then
Return gives `answered` then `working` and the entry leaves; the second answered by typing; the plan approved by its first option.
Then three frame reloads plus three thread opens reach the budget: the handover finishes under 2 s, no focus change, the thread frames
return, and the next send is confirmed.

## 7. Remaining measurements

Everything else above is measured ("Five more page facts" and "Two structure checks", router-data-design.md). Two are left, and
both outcomes of each are designed:

| Measurement | Measured | Until then |
|---|---|---|
| A tool permission prompt under a non-auto Remote Control (3.7) | Approval becomes a Return-confirmed click by structure; the refused-send rule kept or dropped on evidence | The slot's words with Open only; sends to that thread refused until the slots empty |
| Whether `done` rows are in the DOM while the group is collapsed (2, unrecorded by the check) | In the DOM: content.js reports them with `section: done`, which records `done` | Not in the DOM: the row is gone from the active list, which records `done` the same way; either way Fjord never expands the group. Accepted cost in this case only: a thread resumed and finished entirely inside a gap shows no status change, so nothing is recorded; if `done` rows are in the DOM their `time[datetime]` shows it |