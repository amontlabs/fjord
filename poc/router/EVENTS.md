# Router POC: events, not polling

The page tells Fjord what changed. Fjord never reads the page on demand. This replaced every wait in `background.js`. Selectors in `content.js` stay.

```
page -> content.js (MutationObserver) -> Port -> worker -> native port -> native_host.py -> Unix socket -> routerd.py
```

`routerd.py` is one long-running process. It owns Seen, the Board in memory, Intents and Decide. `router.py` becomes a thin debug
client. The socket is `.build/router-poc/fjord.sock`, with one JSON object per line.

## Up: page to routerd

Only changes are sent, stamped with `path` and `thread` (from the address).

```json
{"type": "rows", "side": "project|thread", "full": false, "settled": true, "turning": false, "rows": [{"key": "cmsg_…", "pending": false, "streaming": false, "index": 12, "from": "you|claude|unknown", "text": "…", "decision": false}]}
{"type": "threads", "threads": [{"thread": "cmsg_…", "title": "…", "state": "…", "needs": "…", "text": "…"}]}
{"type": "projects", "projects": [{"id": "chan_…", "name": "…"}], "complete": false}
{"type": "notice", "text": "…"}
{"type": "composer", "side": "project|thread", "draft": "…", "disabled": false}
{"type": "page", "signed_in": true, "page_ok": true, "loaded": 1793706095915, "instance": "3f2c…"}
{"type": "page", "signed_in": null, "page_ok": false, "gone": true}
{"type": "page", "signed_in": null, "page_ok": false, "away": true}
{"type": "done", "id": "c1", "ok": true, "error": null, "refused": true}
{"type": "done", "id": "c5", "ok": true, "error": null, "before": "…", "saved": 200}
{"type": "settings", "project": "chan_…", "goal": "…", "instructions": "…", "repos": ["owner/name"], "folders": ["/path"], "offered_folders": null}
{"type": "wake_me", "after": 4050}
{"type": "commands", "waiting": ["c2"], "done": [{"type": "done", "id": "c1", "ok": true, "error": null}], "instance": "3f2c…"}
```

`wake_me` asks routerd for a `wake` after `after` ms (a step's delayed wake-up: a hidden tab's own timers are throttled by Chrome, by
15-20 s measured, a message over the port is not; the page keeps its timer as a fallback). routerd keeps every time asked (each rounded up to 50 ms, so close ones share one), and one `wake` answers all that have
passed; a later request isn't lost behind an earlier one. It caps a time at 30 s, ignores a value that isn't a number of ms, and sends no `wake` while no host is linked; a host that connects is
sent one `wake` at once (settling is idempotent), since one due while none was linked was dropped. A `wake_me` can go unsaid (asked
while the page is muted, below) or be lost (sent while the worker has no host): the page keeps each time asked until it passes, and
after every snapshot's `commands` sends one `wake_me` per distinct time still to come (its sides' settle wakes among them: the
snapshot's scan doesn't ask a second one for a side whose wake is still to come); the worker sends a snapshot whenever the host links again.

`commands` comes first in every snapshot: the ids of the commands still waiting in the page, and the last 20 `done`s it sent, as sent.
`instance` (on `commands` and on every script-sent `page`, a random id made when the content script starts) names the script that said
it: an extension reload keeps the document, so its `loaded`, but injects a fresh script whose `done`s start empty. So "all its document
has said" is all that (`loaded`, `instance`) has said: a `commands` from another instance in the same document doesn't say a send it
doesn't list never ran. The worker's own `page` events (`gone`, no page) carry none.
The worker sends the page a `snapshot` each time it adopts its port (a reconnect too), so a page that reconnects sends no scan of its
own: the snapshot that follows the adoption says everything, `commands` first. From each port's connect until its `snapshot` arrives,
the page sends nothing (a `done` meanwhile is in the `commands` replay; what the page shows, the snapshot's scan says), so the script's
scan at start only notes what the page shows, and nothing on a new port comes ahead of that snapshot's `commands`. A muted scan
doesn't note the notices it couldn't say: the snapshot's scan says those still up then.
A closed Fjord tab is reopened (pinned, in the background, at the projects page) while the worker's port to the native host is open;
one closed with its window is opened in another normal window if there is one, else it waits for the next window you open (none is
opened for it), or the next command. A tab that navigated away from `claude.ai/code` (a sign-in flow, another site) is left alone,
never navigated back or injected: there is no page until it comes back and the manifest's script connects. The worker says why, from
the address's structure only, when a command or link looks for the tab: `signed_in: false` for claude.ai's `/login` or any other origin
(an identity provider), so runs pause as signed out; else `away: true` (another page of claude.ai), so they pause with "Fjord's tab has
left the Claude Code page" (`do.blocked`). Either way a no-page `page` (`page_ok: false`) carries the reason. `away: true` is also sent by the content script itself, in its own `page` events (with `signed_in: null, page_ok: false`), when the tab navigates inside claude.ai off `/code` and `/code/…` without reloading. The next `page` event, once the tab is back on `/code`, has no `away` and clears it.
The worker sends a `snapshot` both when its native port opens and when native_host.py relays routerd's link, so a page can answer two
snapshots in a row, and an event the page sends between the link and the snapshot can come ahead of it: routerd takes both as it takes
any repeat (a whole read replaces, a replayed `done` is ignored, a `wake` is idempotent). A routerd link with no page gets `page` with
`page_ok: false`, as the port's opening does.

`projects` is `complete` on the projects page, which lists them all: a project missing from it was deleted or archived, and leaves
the Board. It counts only once the page's own list shows and every transcript container and composer mounted at the last open's move
is out of the document or hidden (the old view's links aren't the list), until that open ends (done or cut off; superseded, the
newer open keeps the record); an open of the projects page, and its New project button, wait for the same. `notice` is the page's own message (a polite live region's open dialogs that weren't up at the last scan), passed on as
written; Fjord quotes it when a send fails and never reads it for meaning.

`settings` answers `read_settings`: the project's goal, instructions, repositories and pre-approved folders, read by structure. Anything
unreadable is missing, never guessed; `offered_folders` is always `null` (the read no longer opens the folder list). The read's `done`
carries the same read as `settings` (the event's fields, with the `path` and `thread` it was read at), since the `commands` replay
repeats a `done` and an event sent while the page was muted is lost. `done` says `refused` when the page doesn't
offer what was asked (nothing was committed), as opposed to a step that broke. A setting's `done` (`set_field`, `add_repo`,
`preapprove_folder`) also says what its open read (`before`: the field's text, or the list), and either `already: true` (it was so:
nothing done) or `saved`, the HTTP status of the server's answer to its save.

`threads` with an empty list (`"threads": []`) says the project's Threads list had rows since the arrival on its page and has none now, with the
project side's composer mounted and no thread open: those threads finished and left it. The Board folds every thread of the project the page
showed as `idle` with no ask, until a later `threads` row says otherwise. A list never seen with rows since the arrival (a page still loading)
is also sent empty, once per arrival, when the project side settled this visit with no thread open (the same settling as its
rows: this visit's own `/timeline` fetch, then a flush or the grace), so threads that finished while the tab was elsewhere don't stay running. It never
fires before this visit's data arrived.

`rows` and `threads` carry only what changed, except on page load, when they carry what is on screen. A full scan sends `rows` for a side
that has its composer even when there are none, once its transcript has mounted (its column's container, `transcript-sizer`, is in the
side's part of the page: before that, no rows is the page still loading, and an empty baseline would make an old row of yours look new),
its rows were fetched, and it stayed empty since (the page can mount the sizer before its rows, and show a placeholder in it: on the
project side a resource-timing entry for its channel's `/v1/code/channels/<chan>/timeline`, which each visit fetches once
(`?limit=200`, measured, below), must have ended since the arrival on the page (as for `settled`, below; at start one buffered entry counts,
this visit's (below), but it comes in the resource observer's first callback, a later task, so that callback's scan, not the start
scan, is the one that can settle the start read); then a flush that touched the sizer and came after the latest such fetch ended (the render of what it fetched: an unrelated
flush elsewhere in the page is no render) settles it, or 1 s (`RENDER_GRACE`) since the later of that fetch's end and the sizer's last
change (the last flush that touched it, else when it was first seen) (the fetch's report scans at once, and the side's wait then asks a
`wake_me` for the rest of the grace, only while its whole read is owed, and a `wake` scans): a change before the fetch ended counts for nothing, and a later fetch's end
starts the grace again. The
thread side can't be tied to its data: the page fetches `/v1/sessions/<session id>/events`, but content.js never learns the thread's
session id (the address and the row carry its `cmsg_` key), so it keeps the flush rule (a later flush that doesn't touch the
same sizer, or the same grace, since its last change or when it was first seen); a chat whose rows are never fetched after its sizer mounted stays unknown, and the run's
deadline covers it). A whole read that sent nothing because the side hadn't settled lets a later settled scan send the empty read again,
so an empty project is known to be empty and can be sent to (routerd refuses a full scan
of no rows for a chat whose rows it has seen, and for any thread, which always has its opening message: the page sent it before the
transcript mounted, and an old row would count as new); its `rows` events say
`full: true` and replace the place's rows on the Board. A whole read also says `settled`: whether it is the place's render done, by the
same rule (`settledRows`: on the project side a `/timeline` fetch of the chat must have ended since the arrival on the page (the latest
flush when the address's path changed, 0 for the scan at start), since a re-open shows the page's cached rows
at once and a fetch from an earlier visit lacks the rows added while away (measured: that one ended ~3 s before, this visit's ~0.33 s
after the open); then a flush that touched the sizer after the latest such fetch ended, or
`SETTLE_GRACE` (300 ms; the page renders a fetch's rows within ms of its end, even hidden) with no change in the sizer since the later
of that fetch's end and its last change (the fetch's report scans at once, and that scan asks the `wake_me` for the rest of the grace, only while the whole read is owed: a
side already told keeps tracking its changes on every scan but waits for nothing;
before any such fetch ended no wake is asked: the fetch's report scans, and at start that is the resource observer's first callback,
with the buffered entries, so the start scan itself never settles a project side; a side asks again only when none of its wakes is
pending or the new one is due sooner, since a pending earlier one scans and asks again); a chat never fetched after the arrival stays unsettled
(below: routerd's `fresh` open), else the run's deadline covers it; on the thread side a later flush that
doesn't touch the sizer, or `RENDER_GRACE` since its last change, or a last row that is `streaming`: the live reply is the bottom, and its flushes keep touching the
sizer; an empty read is sent only settled). Opening or closing a thread keeps the arrival and the project side's settling (the page
keeps the project's chat rendered beside the thread, and routerd keeps it settled: only the thread is arrived on); the project's
whole read is still sent again, and one that isn't settled (a remounted transcript) makes it unsettled for routerd as any does. A first render can lack the bottom rows, so a read that isn't
settled leaves the whole read owed: the next scan (a flush, the fetch's report, or the grace's `wake_me`) sends it again, settled. While
owed and unsettled it is sent again only when its rows changed (their signatures, below) or on a full scan, not on every flush. Any whole read sets
that mark, either way: one that isn't settled (a snapshot, or a forced scan, of a place that had settled) makes the place unsettled
again for routerd, and is owed again. A delta merges by `key`, in `index` order. A row with no key is sent only in a
whole read (routerd drops it; in a delta it would differ on every flush). A side's reads stay whole until one held a row with a server
key that isn't pending: routerd drops pending and keyless rows, so a whole read of only those replaced the place's rows with none.

Measured on project switches: each visit makes one `/timeline?limit=200` fetch of the chat, starting ~0.11 s and ending ~0.33 s
after the arrival, so a settled read holds the chat's latest 200 rows as the server has them.

A page whose resource timing buffer is full (250 entries by default; a script injected into a long-lived tab) gives `buffered` no newer
entries, though the observer still gets each new one: the shown chat's fetch can be missed, and that side never settles until the
page fetches it again. content.js leaves the buffer's size alone (it is the page's own world), and routerd's `fresh` open covers it. At
start the buffer can also hold a fetch from each earlier visit to the shown project, so of the buffered entries only the latest
`/timeline` fetch of any chat counts, and only when it is the shown project's (each visit fetches once, so it is this visit's), and
none when the buffer holds 250 entries or more (this visit's may be missing): a side never settles on a previous visit's fetch, and a
`fresh` open's first run reads the fetches the same way, so it bounces then.

A message's key starts with its project's id (`cmsg_<chan id without chan_>…`). Right after `open` changes the address the page can
still show the last project's rows for a render, so a row whose key names another project is dropped (page.py `belongs`, for the server's 24-character ids: the fake page's short ids are exempt, and routerd's test uses full-length ones).

A row is identified by `key` (`data-entry-key`), never by `index`, which is only a position and is renumbered on reload. `cmsg_…` means the
server has the row. `cmsg_pending_…` (your message just sent) and `provisional:…` (a reply being written) are `pending`: they are replaced
by a real key later, so the Board never holds them. A row has `streaming: true` while live; a Claude row counts only when settled (real
key, not streaming), since its text then includes status words. For your rows only the key matters. A row is sent again when its key,
index, author, decision, text or streaming changes, except that a streaming row's text is left out of that comparison: it is sent when it
starts and once settled, not as each snapshot. A row with no words, no card and not streaming is left out, unless its key was last sent
streaming: a streaming row that settles with no words still sends its `streaming: false`. `turning` says whether the side's turn is
under way: its bottom Claude row on screen (by index, pending or provisional too; a row whose key names another project is skipped, and so is one the rows leave out: no words, no decision card, not streaming and not
sent while streaming) is
streaming. It comes with every `rows` event, whole or delta, and whenever it changed since last told, alone in a delta with no rows if
nothing else changed: that one only once the side's whole read is no longer owed, never for a first `false`, and on the thread side only
with a thread open (one that comes before the place's first whole read leaves the Board's rows of it unread).
routerd takes `turning` as the place's reading when an event has it; once a place had one, an event without it says nothing of the
turn. For a place that never had one (an older page), routerd reads it from the event's Claude rows against what the place showed before: a streaming bottom row is a turn; a delta ends it only when its settled bottom row replaced
the place's last streaming row (its key or index) or is at or above the highest Claude index seen there (an older row settling while a
later one streams says nothing); a whole read says it outright. Arriving on a place, and a host lost, forget its reading. A read's `done`
replayed in `commands` with its `settings` has them handled first (one lost while the page was muted still proves a tool), only for a
read no `done` answered yet (a tool's or a dev command's) and once: as a settings read (it counts as a read, and may drop a goal's mark or
confirm a tool done unproved), not as the tab arriving there. A live `done`'s copy is ignored, its event came; and the snapshots after
it repeat it, ignored the same way, so an old read never counts as a later one.

## Down: routerd to page

```json
{"id": "c1", "kind": "open", "project": "chan_…", "thread": null, "fresh": true}
{"id": "c2", "kind": "send", "side": "project", "text": "…", "project": "chan_…", "thread": null, "intent": 12, "click_only": true}
{"id": "c3", "kind": "cancel", "target": "c2"}
{"id": "c4", "kind": "create_project", "name": "…", "goal": "…"}
{"id": "c5", "kind": "set_field", "project": "chan_…", "field": "instructions|goal", "text": "…"}
{"id": "c6", "kind": "add_repo", "project": "chan_…", "repo": "owner/name"}
{"id": "c7", "kind": "preapprove_folder", "project": "chan_…", "path": "/path"}
{"id": "c8", "kind": "read_settings", "project": "chan_…"}
{"id": "c9", "kind": "remove_folder", "project": "chan_…", "path": "/path"}
{"kind": "wake"}
```

`wake` answers a `wake_me`: the page scans (only changes are sent) and runs its waiting steps once, as a flush does. It has no id and no `done`, is not counted among the commands, and is no
command waiting in the page, so it never holds the tab or a run. The worker drops it when there is no page (it never opens a tab for it).

`send` is a step run on each flush of the page's observer, never on a timer: (a) the draft holds other words: clear it and wait;
(b) the draft is empty and Send is enabled: the page is settling (a click now does nothing), wait; (c) the draft is empty and
Send is disabled or missing (a turn runs, and typing brings Send back): type, once; (d) the words are in the draft and Send is enabled:
click once and report `done`. A missing composer waits like a disabled Send (a reload is under way); the 20 s deadline covers "never".
Where the page offers no composer it shows a note in its place (`data-composer-stand-in`, role="note": an archived project shows one on
each side, with a button to unarchive it, which Fjord never presses). An `open` whose place shows one, arrived as a composer would, and a
`send` that finds one where its composer would be, end at once with `refused: true` and the error "the page shows a note instead of the
composer: …", the note's words as written (data, like a notice: never read for meaning). routerd refuses the run at once on such an
open: no new open would bring a composer.
A page refusal, or a draft that differs from the words after typing, is an error. A newer `send` on the same side replaces the one still
waiting (`done` says `superseded`), so a retry is just another `send`: with the words already in the draft it only clicks. A `send` names
its place, and the step refuses it ("not on that place") while the tab shows another, before typing. After a click was reported, routerd's
retries say `click_only`: the step never types, and clicks only words already in the draft, else fails ("the words aren't in the draft"),
so words the page took late are never typed twice. A retry whose deadline crossed the click (sent before the click's `done` reached
routerd) isn't click-only, so the page guards too: it keeps the last click on each side (its place, the send's `intent`, the words,
loosely, and when), and a send that isn't click-only, finds the draft empty, and matches that click within `ATTEMPT` (20 s, routerd's
`do.TIMEOUT`) is treated as click-only and fails the same way. One that finds the words still in the draft within `TAKE_WAIT` (2 s,
routerd's) of that click isn't clicked: the page may be taking them yet, so it waits (`wakeAfter` the rest), and either the flush that
empties the draft fails it as above, or the window ends and it clicks, a real retry of a click the page ignored. Its `done` follows the click's on the one port (worker, host and socket
keep the order, and a replay lists them in order), so routerd has heard the click first and takes the empty draft as the page taking the
words. Another intent's same words (sent once the first was proved or failed) are typed: the guard matches the intent, not only the words. A `done` for any send the run issued counts, live or replayed (a replayed ok one is a click whose time and page aren't known: it marks no
reload as its loss, nor words back in a draft as its page giving up, and sets no `TAKE_WAIT`), whether it was
replaced by a retry or cancelled (a tool's dialog, the app closing): an ok one is a click, so the later retries are click-only; an error
from one replaced or cancelled is no answer for the run (a stranded thread's hand-off starts afresh: the coordinator's send is not
click-only for a click into the dead thread). A click-only retry of a click the page reported but ignored is part of the same attempt:
only a send with no click reported, or a retry after the attempt's 20 s deadline or a page error, uses one of the attempts. A `done` sent
while Fjord's host was gone (Chrome closes the host, the page lives on) comes back in the next `commands`: routerd handles one for a
command its run still waits on as the late `done` it is (an ok send's is its click, so its retry only clicks and an empty draft is the
page having taken it). A command still `waiting` is left to finish, unless an earlier routerd start sent it (its id lacks this start's
`c<start>.` prefix): no run answers for it, so routerd cancels it once (again after a host loss, which may have lost the cancel), and an old send can't click later. One sent before the host connected,
or before the worker said the page was gone (`page` with `gone: true`: the adopted page's port dropped, as on a reload; commands sent
after it wait in the worker and reach the next page before its snapshot, so that snapshot lists them), that the page neither waits on
nor did (a reloaded page, a Chrome restart) is out of the page (`dropped`): it no longer holds the tab from a paused run. It is never
taken as an answer. A send its run was waiting on reached a page (a send is made only while a host is linked) that may have typed and
clicked it before it went, and the next page may show the words in its draft (its saved draft): so it is never sent again, not even
click-only, and the run is taken at once (a paused run when it comes out of the pause): its row proves it, or it fails, unproved,
as "the page it was handed to went before it said what it did, and no row from you showed after", and is watched (below). One the
page held when it went (`gone`) is `reloaded` from then, as a click a reload may have lost is (that send only: the mark is dropped
once the next page lists it still waiting, and at the run's next send): it fails once the next page's settled
rows show no row from you, about 20 s after the reload (below); one found dropped only by a replay after a host reconnect waits 300 s.
A `commands` with fewer than 20 `done`s is all its script has said: a send sent before the link, to that script, that it neither lists
as waiting nor reports done never ran, and is no longer waited on as one that may have clicked (it counts as heard). If it was the send
its run waited on, the run isn't taken as above: it sends again (typed again unless an earlier send of the run reported a click), in the
same attempt with a fresh 20 s (it never ran, so it uses none of the retries). Only for the script the send was handed to (the
`commands`'s `instance` is the one of the latest `page` when it was sent; one without `instance` proves nothing): after a `gone` none is
marked, and after a host linked again (the tab or the extension may have reloaded while none was) the marks wait for the next `page`
and are made only if it carries the same `loaded` and `instance`; the run waiting on such a send is decided then too: sent again if that
`page` is the same script, taken as above if it is another. A document is counted as replaced (`pages`) at a `page` with another
(`loaded`, `instance`), or one with either missing after a `gone`. Only the host commands go to (the latest linked) leaving decides
dropped sends, clears lost opens and forgets cancels: an older host whose socket closes after a newer one linked takes nothing with it. The newest `done` per document,
which says a cut-off send never ran, is kept only while no `gone` or new link leaves the document a `done` comes from unknown. A command sent since the last of those
marks may not be listed yet, so it is never dropped: its run retries at its deadline. `cancel` drops a waiting command,
and the page sends no `done` for a cancelled send: a send routerd cancels (its place lost, its thread gone, the app closed, a tool's dialog) no
longer holds the tab either, though a click the page made before the cancel still counts when its `done` comes (except one into a thread
whose process was gone: the hand-off goes on). routerd sends `cancel` for a
send or an open still waiting when its run finishes, whatever the outcome, and for a tool's command when the run fails or is refused, so
nothing clicks or moves the tab later.
`done` says what the page did, not that it worked. `open` puts the place's address on the history and lets the page's router show
it, as the page's own links do: no document load, so claude.ai's "open in the desktop app" handoff of a freshly loaded project
link never runs, and hidden or resolved threads open too. It is over when the place's composer shows (two, with the thread's back
crumb, for a thread; for the projects page, a page update since the move and the page's own list, a project link outside the sidebar,
or its new project button; for a project open, the project's own composer, with or without a thread open beside it: such an open is over
at once, leaves the thread open, and its `done` names the thread shown, which routerd's `shows` takes as the project shown). After
its move, a composer counts only once the new view shows: one mounted since, or one the page kept from before once its side shows the
new place by structure (another `transcript-sizer` than at the move; on the thread side, a row of the target thread's opening message,
whose `data-entry-key` is the thread's id; on the project side, a `/timeline` fetch of the target ended since the move and a page update
after it that touched the side's `transcript-sizer`; or the side's rows another project's at a flush since the move and its own at a
later one). Until then the page sends no `composer` event from one kept from before, and a `send` waits rather than type into it; that
hold ends with the open, and the page scans again then, so a `composer` event it held back is sent. A newer open inherits a move still under way,
so it doesn't take the old view for its place either. A newer `open` replaces one still waiting (`superseded`); the run whose open was replaced lost the tab and opens
again at its deadline (or when it comes out of a pause), never failing for it, and holds nobody back meanwhile. An open the page or
the worker failed (no tab to be had, say) is lost the same way, nothing having been sent; a second such error in a row, with no open
that worked between, fails the run with that error. An unknown project shows no composer; the deadline covers it. It sends a full scan only when the place was
already shown (otherwise the new place says what it shows). `rows` is withheld for a side whose rows all belong to another project (a
stale render), so such a place has no full scan yet, rather than an empty one. `fresh` (optional): a send waiting for its project's
settled read, the project shown and unsettled `FRESH_AFTER` (2 s) after the tab arrived on it, opens it `fresh`, once a run (a thread
never: its side settles by the page's flushes). If the tab shows the place at the step's first run (for a project open, its project,
with or without a thread open beside it: the project side is what settles, and a thread's open is no arrival) and no `/timeline` fetch
of its chat ended since the arrival (an address no scan has seen yet is scanned first), the step goes to `/code` (the page that
starts a new task, "Créer" in the sidebar), waits until it has left the project's view (the address is `/code`, a page update came after the move, and every `transcript-sizer` the project
showed is out of the document) and comes back to the target: a new arrival (routerd's too), whose open fetches the chat's rows. It never
bounces through the projects page: that one's scan says `projects` `complete`, and a list still rendering would prune the Board; `/code`
lists projects only in the sidebar, never `complete`. Otherwise (a fetch whose render is
settling, the tab elsewhere) it opens as usual. A run whose place still never settles fails at its deadline as before. The bound is
routerd's (a timer, so a hidden tab's throttling doesn't delay it); whether a fetch came is content.js's (only it sees resource timing). The worker never loads a project link: a restored tab
is sent to the projects page (one that left `/code` is left alone, above).

Proof is a later `rows` event: a new row from you, one after the last row whose key the place held at the baseline (its latest 50 keys,
taken before sending, and the latest 200 other keys of the place Seen holds, by when they were last read; an empty baseline, an empty
chat: all are new). The page's first render of a place can lack its bottom rows, and the next delta brings them, and the stored keys
don't cover rows added while the tab was elsewhere (or Fjord was away): so each time the tab arrives on a place, routerd baselines a send
there only once a whole read of it says `settled`, a chat it has seen too (a restart starts with no place shown, so the first place
the page shows waits the same way). A send whose place showed but never settled fails at its deadline as "the page never settled on that
place" (one whose place never showed, as "the page never showed that place"); an older content.js that sends no `settled` fails so:
reload the extension. A tool doesn't wait for that: it acts in the settings dialog, so it starts once the tab shows its project and the
project's composer. A finished send's proof keeps only the last 5 keys of its baseline and anchors (all of them while it is watched
after failing after a click, below: cut to the 5 when its watch ends, by expiring (the tick at its end) or by a late confirmation, and at
start for every failed send no watch holds, those the start fails too). One row proves one send: the proving row's key is kept in the intent's result
(`row`) and claimed for its place (rebuilt from the confirmed sends' results at start), and a claimed row proves no other send, live or
watched after a failure (below). The place's live sends and watched ones are judged together: each new row from you goes first to
a send whose words (loosely) equal it, and only when none has its words to the send with the longest words it starts with (the
earliest among equals) and adds at most min(3, the send's word count - 1) words to: a row may carry a few rendered words after the
message, but a short send must match (nearly) exactly (a 1-word "yes" or "ok" only an equal row), so a hand-typed message that starts with it
can't confirm it. A lost "fix it" never takes the row of "fix it now please", nor of "fix it now, please do" while "fix it now" waits. A row that is another send's (given to it, or with exactly its words) is no row
from you for the rest: a watched send's late row doesn't hold a live send as taken. A live send comes before a watched one, so a new
send of the same words takes its row first. Rows that hold none of a non-empty baseline's keys can't be placed
against it (a reloaded page's window of older history, whose keys Fjord never saw, would look new), so none of them is new until a read
holds one of its keys; older rows rendered later sort before the baseline's keys and are never new. The anchors move forward: each read
placed adds the keys of Claude's rows it placed after the baseline to the proof's `anchors` (the latest 50; never a row from you, nor an
`unknown` one, which can turn out to be yours). A read that holds a baseline key is cut after the last one it holds, whatever anchors it
holds too (your row, queued while Claude's rows were written and anchored, can take its key before them). Only a read that holds none is
placed by the anchors, after the earliest one it holds, so a busy chat whose window scrolled past the baseline (a coordinator's long
turn while your message is queued, then a full scan of the latest rows) still proves the send. Any new row from you ends the
sending; its words matching loosely makes it proof. So `confirmed` means the server has the message. routerd's retry (another `send`,
after a `done` error or the deadline) covers a click that didn't take. A page reload doesn't reset the baseline: the reloaded page's rows
of the place, read afresh from the server, prove a click made before it (the place's rows are read again after the `gone`: the tab shows
no place until the new page says what it shows).

## Tools: the Router's setup commands

Each is a step like `send`, run on each flush, with no polling (a timer only wakes a step that waits for no page change); it acts once and reports `done`. `open` with no project shows the projects
page. The project's settings open by structure: the header's second menu button, its menu's one `menuitem`, then the section by its `nav`
button (General 0, Memory 1, Environment 2). The dialog shows the values it opened with, and opening it fetches the settings about 0.2 s
later, so a setting's step opens fresh: it opens, waits for that fetch, closes and opens again, which shows the server's instructions,
repositories and folders (measured), and waits for that open's own fetch too, so the change's answer is the next request. Each wait is
for a settings request that ended after the dialog showed (taken once the dialog has mounted): one that ended before it mounted (a slow save, or a read's) can't be the fetch the open joined. A goal is only
the tab's copy however often the dialog opens, so its step opens once. The step then reads what it changes (`before`), and when that is
already so (the field holds the text, the list the repository or folder) it closes and reports `already`, changing nothing: an
unchanged field saves nothing, and an option already chosen is never pressed (that unchooses it), including one the list marks chosen that the dialog's list doesn't show:
the step reports `already` and routerd judges it against `before` as for any other (it differs: "the page said it was already so, but what
it read differs"), instead of waiting for a save that never comes. Repositories in a read are the deepest elements whose text holds exactly
one owner/name token, so a row split across spans or with a suffix still reads. Otherwise it acts: fields are typed with
`insertText`, checked, then left (the page saves on blur). The dialog is closed before `done`. The step then waits for the server's answer
to the page's own save request, seen with its HTTP status in resource timing (the page is optimistic: it shows a refused change as
taken, so only that status proves it). A refused save is an error with nothing committed. A pick that pressed its option but saw no answered save
request says so when it is cut off: "the page saved nothing after the folder was chosen" for a folder, "the page saved nothing after the repository was chosen" for a repository, with `committed: true`:
resource timing lists a request only once it has ended, so a save still under way can't be told from none. The step waits for the save only
SAVE_WAIT (4 s) from the press, and takes as its answer only a request that started at or after the press (timed just before it:
the page may start the save in the press's own handlers; a settings fetch before the press is no answer) (a few ticks of a hidden tab's timers; saves answer well under 1 s), then reports `done` at once, not at
routerd's cut-off, with `ok: false`, `committed: true` and `unsaved: true` (an older page, cut off by `cancel`, says the same without
`unsaved`). For a folder or repository with `unsaved`, routerd's proving read is a fresh read taken after the act: if it lacks the folder or
repository the run fails at once with the act's error as the cause (no look, no "done, but not confirmed": the read shows it didn't take;
a later read that does show it still confirms it late); if it shows it, the run is confirmed. Without `unsaved` (and for a goal or any
other unanswered act) the proving read and the look decide as before. A save with no HTTP answer, after the change was made, is an error with
`committed: true`: routerd proves that act by a read (its proving read, then the look), keeping the error as the cause, and says it
after "not confirmed" if neither shows it. A goal is the exception: its dialog shows the goal as the tab last knew it (the typed one,
even if the server refused it), so only the answer to its save proves it, and one with `committed: true` (or a `done` with no 2xx `saved`)
fails at once as "not confirmed: <error>", never read for proof or reconciled later. A missing element is never guessed: the step keeps waiting, and when routerd cuts it off with `cancel` it
reports what it lacked (`no settings menu`, `no folder option ~/x; offered: …`), as `refused` when the page's list was there and held no
exact match for a repository or folder (matched by its text, which is data). Several exact matches are refused at once ("2 folder
options match ~/x"). A repository with no match is refused as soon as the search for the typed words (one that started after they were
typed, its `q` the repository when it has one) has answered and either a flush of the observer that touched the popup came after its response ended (the render of its results; an unrelated mutation is no render) or a grace of 1 s has passed since (a render with no match may change no DOM). The folder list (the `button[role=combobox][aria-haspopup=dialog]`) is opened from the keyboard, and its option
highlighted and pressed as measured below; a list that doesn't say it opened, or an option that never highlighted, is tried again on the next updates, and after
three tries fails as "the folder list never opened" (or "the hover never highlighted ~/x"), not as a refusal.

Measured on the folder list (live, hidden tab): ArrowDown on the button opens it with the first option highlighted; further arrows don't
move the highlight reliably, but hovering an option (pointerover, pointerenter, pointermove, mouseover, mouseenter, mousemove dispatched
on it) does. A press (pointerdown, mousedown, pointerup, mouseup, click) made within milliseconds of the list opening is ignored (the
popup closes, nothing is chosen); one made `PRESS_AFTER_OPEN` (1500 ms) or more after it opened chooses the option, the first too. In
a visible tab 300 ms is ignored and 500 chooses; in the hidden tab 700 ms chose only ~40% of the time and 1500 chose 8 of 8: the page
lets presses through once a short timer of its own has run, which a hidden tab defers to its next one-second slot. The step therefore
hovers the wanted option, waits until the list has been open that long and presses; since that wait is for no page change, routerd wakes
it (`wakeAfter`: `wake_me` / `wake`, below), with the tab's own `setTimeout` as a fallback (a tab hidden for a while can have those
throttled by 15 s or more, measured). Folders save to
`/v1/code/channels/<chan>/remote-control-preapproval` (not `/config`), its HTTP status being the answer, about 50 ms after the press.
A folder's row can carry a note beside its path ("Approuvé pour Remote Control uniquement sur cet ordinateur."): the path is read from the
element titled with it (`[title^="/"]`), so `before`, matches and `already` see the clean path.
The fjord-e2e spike folder, served by a terminal Remote Control, is pre-approvable (granted live in 2.6 s): no folder is known not to be.
A settings fetch that is still under way when the dialog opens is joined, not repeated (`responseEnd` is compared with when the dialog showed, not with when the open began).
The page's "Paramètres enregistrés." toasts are `role=dialog` and pile up open in a hidden tab (no animation frames), so an open
`role=dialog` is no sign of a modal.

A hidden tab runs no animation frames, so a closed dialog, menu or popup keeps `data-closed` (and `data-ending-style`) for good: only
`:not([data-closed])` counts as open. A list option is chosen by arrow keys until it is highlighted, then a press (pointer down, up,
click); in a hidden tab a press alone, or Enter, does nothing. An option already chosen is never pressed (that unchooses it). The
repository search is typed and the list gets one render before an option is chosen. `done` says `committed: true` when the step made
its change before an error, so routerd knows whether anything was done.

- `create_project`: the Projects page's dialog (its New project button is the one text button in the heading's row), name and goal
  typed, the last button clicked once enabled. Proof: a later `projects` event lists a project of exactly that name with an id not
  known before. The look's open may report `done` before its list: it fails only once a complete list that came after it lacks the name. `chan_pending_…` ids (the page's own until the server answers) are dropped, like pending message keys. A name that exists is refused before anything is done.
- `set_field` (`instructions`, `goal`) and `add_repo` and `preapprove_folder`: one command reads and acts, and its `done` is the proof
  when `saved` is 2xx: the run is confirmed then, with no read after. Its `before` is kept in the intent's result (for a goal, with
  `before_is`: the tab's copy, maybe older). `already` is confirmed without acting, "it was already so" (believed only when `before`
  shows it); for a goal, whose dialog shows the tab's copy, as "it was already so, as far as Fjord's tab knows". The page shows a goal as
  typed even when the server refused its save, so a goal refused that way and still shown is refused, "reload the tab first", until an
  act's `before` or a read shows another goal, a later goal's save is answered, or the page says its document was loaded after the mark
  (`page` carries `loaded`, the document's start: a fresh one read its goals from the server) (a host loss isn't a reload: the mark stays,
  and a restart marks again each project's latest typed goal that failed or was refused this way); a goal whose save got no answer (an
  unanswered save, a step that never reported back by its second deadline, or a restart before its answer; the intent's result holds
  `provable: false` from the act until the answer) is marked the same way, never reconciled, "Fjord can't tell whether the server took
  this goal: reload the tab first". The page decides `already` itself, so the rule needs nothing sent down: a marked goal is refused only
  when the step found it already shown. A `saved` that isn't 2xx, or an act that committed with no answer, is proved by a read: routerd
  reads to prove, and at the deadline reads once more and fails as "done, but not confirmed" without acting again. A later read that
  shows the change confirms it late. A folder the Mac hasn't connected is refused by the act itself (its list, read at once, lacks it):
  "connect ~/x in the Claude app first"; any other refusal of a folder is said as the page wrote it.
  A tool waits to start, and a proving read to read, while another tool run's command is in the page or that run opened its project to
  read and hasn't yet, or a dev command is in the page: two tool commands would share the one settings dialog (the page replaces a waiting command only by
  one of the same kind: a read and an act would both run, each opening, closing or reading the dialog under the other; two of one kind
  replace each other, and the replaced one's `done` says `superseded` with what a cut-off one says: `committed`, `before`, `refused`).
  A proving read also waits while another run is acting (opened, sent a command or past its start), but not for a run still at its
  start with nothing sent: a send that arrived meanwhile must not hold the read that a dialog left open by a failed save is waiting on.
  A replayed `done` for a dev command answers it, as a replayed one for a run's command does. One sent before the page went (or the
  host linked) that the next `commands` neither lists nor reports done went with it: its caller gets an error ("the page went before it
  answered"), and the sends it held go on.
  A tool's act keeps its command id (`act`) in the intent's result. The page's `commands` replay `done`s for acts whose runs are over
  (an earlier routerd start's, or one routerd cut short), and routerd matches them to the failed, unproved intents by `act`: `saved`
  2xx confirms it ("confirmed by the page's late report of its save"; a goal becomes `provable: true` and its stale-goal mark goes);
  `ok: false` without `committed` means nothing was done (`acted: false`, so no later read can confirm it; a goal's marks are
  recomputed, since the tab may show what was typed); `already` for a goal means nothing was typed and its mark goes; anything else
  changes nothing.
  A live tool run whose act the same document never ran (the worker failed it, its `done` lost with the port: a `commands` snapshot
  of fewer than 20 `done`s from the document and script the act was handed to neither lists it nor reports it, decided at the next
  `page` after a new link) is treated as an act that erred before its change: `acted: false` (a goal's `provable: true`), failed as
  "the page never ran the step: it went before it said what it did", with no stale-goal mark (nothing was typed in the tab). One
  dropped by another document still waits for its deadline ("the page never finished the step").
  A send never acts while a tool has a dialog open in the page: it waits (not fails) while any tool run has a command in the page, or a
  dev command is (answered or cancelled, it ends), is between its open and its read, or has finished with a read whose settings arrived and whose dialog the page is still closing (that read
  is left to close rather than cancelled: a cancel would stop the close sequence, and its cut-off report would be the read's first and
  only `done`). It is waited for until its `done`, a `commands` that no longer lists it, or its deadline (`do.TIMEOUT` from the run's end),
  when routerd lets it go and sends `cancel` for it: the gated sends go on, meet the page's dialog guard below if the dialog is still
  open (and end within their attempts), and the next tool's `openQuiet` closes a dialog left open. It goes on at once when that ends,
  and only to a place still ready (the tool may have moved the tab): otherwise it opens it first. A send the gate cuts off in the page
  keeps its attempt; one opening its place has its open cancelled and opens again, with a full wait, once the gate ends. A gated run
  keeps a deadline as a wake-up: every run that has begun and isn't paused has one. A `fresh` open gets its own full wait too. content.js's send step is the second guard: it types or clears nothing
  while a settings dialog or any open modal shows (it takes focus only when no settings dialog is open, so it doesn't pull it from an
  open menu), and reports the error "a dialog is open". routerd doesn't count that error as an attempt or retry at once against the dialog:
  the same attempt goes on when the tools end, else at its deadline.
  A create that took but isn't listed never creates again; a later list with that name reconciles it.
- `reload_extension` and `reload_tab` are dev-only ops (`{"op":"reload_extension"}`, `{"op":"reload_tab"}`): routerd sends the command of that name to the host at once and replies `{"ok": true}` (`{"ok": false, "error": "no host linked"}` when no host is connected). The extension reloads itself (edited scripts), or the tab loads afresh at the projects page.
- `remove_folder` is a dev-only step (no intent, no Router tool): `{"op":"dev_command","kind":"remove_folder","project":"chan_…","path":"/path"}`
  on routerd's socket (a client's `id` is dropped: the id is routerd's) sends the command, which is not tied to any run (the tab must already show the project), and replies with the
  page's `done` (or an error after 60 s, cancelling it; a `done` that came as the wait ended is the reply instead). With no host linked nothing is sent and it replies `{"ok": false, "error": "no host linked"}` at once. It opens the settings fresh, Environment, finds the folder's
  `project-preapproved-folder-row` by its path and presses the row's `button[aria-haspopup]`. The menu is the one that button names by
  `aria-controls` (the page reuses ids and a hidden tab keeps old menus open: the open element with that id is preferred). Its removal
  item is chosen by structure (words are localized): the destructive one (`data-variant`, `data-destructive`, a `remove`/`delete` test
  id, a destructive or danger class), else the last. As with the folder list, the item must be hovered and pressed `PRESS_AFTER_OPEN`
  (1500 ms) after its menu opened. Most folders then show a confirmation (a new open dialog with two buttons, the confirming one focused and
  last; never one in a live region, where the page's toasts are dialogs too), pressed after the same wait; the save (the folders endpoint, `remote-control-preapproval`) follows ~10 ms after that press (measured). Some
  folders (one served by a terminal's Remote Control) are removed at the item press with no confirmation: the step takes whichever comes
  first, the save or a new confirmation; neither, within SAVE_WAIT of the press, is the error "neither a save nor a confirmation followed the removal" (`committed: true`, `unsaved: true`).
  A pick returns as soon as it has pressed its option and does not find the option again: the save's answer, or its absence, and the proving read decide.
  `done` says `removed: true` and `saved`, the HTTP status of the folders endpoint's answer. A folder not in the list is refused, listing
  the ones there are.
- `preapprove_folder` is a permission grant: its intent is `awaiting` until `core.confirm(intent_id)`. A path the Mac hasn't connected
  is refused ("connect <path> in the Claude app first"). There is no delete tool, and nothing that widens visibility.

A tool run goes through stages, each of which opens the place at most once and reads at most once: `start` (the project and its
composer are shown, settled or not, or the projects page for a create; at the deadline it fails as "the page never showed that place",
"the page showed that place but never its composer", or "another tool's step held the page"), `act` (the one act, with a setting's `before`; a 2xx answer ends the run here), `prove` (it waits for the proof; a read
first opens the project again if a send moved the tab, and a read that breaks on its own waits for the deadline; one routerd cut off at
the deadline goes straight to the look when its `done` arrives, with no second wait), `look` (at the deadline, one
more read, or the projects page for a create; a look that another run kept from the tab waits for it, and isn't failed unread), then
confirmed or failed. Once its act is done a tool yields the composer to sends, but
a send that was taken away goes back to its place, or takes its look, only while no tool runs (a paused run with nothing in the page
doesn't count), and no other taken send is taking its look, since a proving tool may still open its project. It goes back while the
other runs are only taken sends, paused runs with nothing in the page, and steps still queued behind an earlier one; not while another
run, not paused and not yielded, is about to act: that one moves the tab anyway, and its move lets the send go back after it. While a
taken send's open (its going back, or its look) is in the page, and after its `done` until the tab arrives somewhere (the `done` can
come before the arrival: normally the arrival's `page` comes first, but a muted port's replay sends the `done` first), a tool doesn't
start or read and a send doesn't open or send: the place the Board shows is about to change. That hold lasts at most 20 s from the
open's sending, then 20 s from its `done`: an open the page dropped, or a tab that never arrived, holds nobody longer. An open that a
`commands` snapshot neither lists as waiting nor reports done (one sent before the page went or the host linked), or one sent before the
host went away, never ran and holds nobody: a going back may go back again, and a look is sent again once, with a fresh 20 s, when a
host is linked (a second lost look's open leaves it to its deadline; a look taken again after its end moved on, as one finding the coordinator mid-turn does, has its own retry); a look's open the page superseded or failed is the same: looked
again once, with a fresh 20 s, else left to its deadline. A look under way (its open sent, its end not passed) holds the tab against
every other run until it ends, at most its 20 s: a send made meanwhile, a retry or a tool's read or act waits, so the row the look
waits for can show in the place it opened, and goes on in the pass in which the look ends. The look ends early once its open is done
and a settled whole read of the place made after the open (the tab arrived since it went out, or its `done` came first, or the open's place was already shown when it was sent: it moves no tab, so the page's own read
after the send is the one it answers with; a render from before the send is what the look is there to refresh, and a look sent again starts afresh) came with no row from you (the proof was placed
against it): the outcome is known, and the tab is let go then, not 20 s later. A read that shows a row of yours still pending, or the
coordinator mid-turn, is no such answer: the server may hold your message queued and key it moments later, so the look waits on to
its end. A look that finds the coordinator mid-turn, so that its end moves on to the full wait, ends
there too: it holds nobody through the rest of that wait, and is taken again at the new end. A look doesn't start while a watched
send's going back is in flight (below): it goes once that is over. A look due while the page is away (Chrome closed or not running,
signed out, the page unreadable, no host) isn't waited for: the run fails at its bound, watched as any taken send that failed, so a
later row of yours still confirms it; only a look whose open was lost with the host gets its one fresh 20 s for a host to link. The tab arriving anywhere after an open's `done` ends that open's
hold, as does its arriving at the open's place between the open's sending and its `done` (an arrival elsewhere then may be a reloaded
page's own, before it runs the open), and a sleep moves the hold on with the run's other waits. A taken send goes back
once each time a run opens another place, never because another taken send went back; once a taken send that went back finishes, the
others may go back once more (the tab is theirs now), and a run that had the tab and lets it go (it yields or ends) has the
taken sends looked at again in the same pass, so one whose going back that run kept from the tab goes back at once, not at its deadline. A run coming out of a pause, or retrying at once after a page error, waits while another run has
the tab: one that hasn't yielded and is acting, or is paused with a command still in the page (of two such paused runs, the older goes
first); so does one whose deadline passes while paused. A tool waits for a look under way before it opens or acts, as a send does:
otherwise a tool made meanwhile acted ahead of an older one on the same field that the look held coming out of its pause (one made
while the host was away), both were confirmed, and the field was left with the older text. A create's look waits the same way. A run's step that raises fails that run ("routerd error: …"), so whoever waits gets an outcome.

One message can ask for several setup changes: Sonnet's `steps` is an ordered list of `{tool, args}`, usually one. Each step is its own
intent, and the decision shows them all (`steps`). A later step is `queued` until the one before it is confirmed, and its project is
checked only then (it may be the one an earlier step created). A step that fails or is refused refuses every later one, naming it
(`step 1 (create_project) failed: …`); wrong arguments in any step refuse them all before anything is done. A grant in the middle waits
for `confirm`, and the steps after it wait with it. A failed step that a later read confirms doesn't run the steps it stopped: they
stay refused, and their cause says it was confirmed later and they weren't run. Whoever waits on the message gets the last step's outcome, or the one that stopped
the chain. A restart refuses the steps still queued. `core.tool` stays one tool, with no model.

## Local threads that lost their process

Look reads whether the Claude app runs (`pgrep -x Claude`, once per pass) next to the process registry, and watches the app's exit, or
while it is closed its folder, which it writes to as it starts: nothing polls. While the page is away it watches Chrome the same way
(`pgrep -x "Google Chrome"`: its exit, or while it isn't running its folder), and the page going away wakes the watch at once. With the app closed, a local thread whose process is gone
is `waiting_app`, not stranded, and a reply to any local thread is `paused` ("waiting for the Claude app"): it goes on into the thread
when the thread's process is back. Once the app runs again, a thread still gone gets one more 20 s wait, then is handled as stranded.
A reply to a stranded thread (seen alive, gone while the app runs) is never sent into it while no click was reported and nothing was taken: it becomes one ordinary project send to the
thread's coordinator, the owner's words after a short note from Fjord ("Thread «title» lost its process. Start a new thread in the same
folder that continues it. Last state: … Message: …"), with the same proof, and `args.continues` naming the old thread. The tell says once
"«title» lost its process; last: … Reply to continue it in a new thread." for a thread lost while working, needing you or waiting for the
app, and "Claude app closed; N threads waiting" once for a closed app, in place of a line per thread. A loss that is back before the
tell isn't told.

## Rules

- No polling on the page or in the worker, apart from what Chrome needs to keep the connection alive. The page asks routerd to wake a step
  that waits for no page change (`wakeAfter`: `wake_me` / `wake`, the tab's own `setTimeout(woken)` only as a fallback: the folder list's press delay, the save wait, a crossed retry's `TAKE_WAIT`, an empty side's grace; a repository search's answer wakes the step through the resource observer, and one timer per answer (1 s) wakes it for a render that changed nothing; the shown chat's `/timeline` fetch scans at once, and each settling rule that then waits, its side's whole read owed, asks one for its own grace: `SETTLE_GRACE` for rows, `RENDER_GRACE` for an empty side).
- A content script that finds an older instance of itself in its isolated world (a reloaded extension) stops it first (`__fjordRouter.stop`:
  observers, waiting steps, port); if a reload doesn't share the world, there is nothing to stop. An orphaned script (its runtime gone)
  stops itself on its next observer, resource or timer callback.
- Once a row from you exists past the baseline, never resend. Words are compared loosely because the page renders Markdown. A row from
  you with other words (you typed in the chat meanwhile) fails a run that never clicked and isn't taken at once, with "a row from you
  arrived, but its words differ from what was sent": it has nothing of its own to wait for. One that may have sent keeps that cause
  and waits for its row as a taken run does.
- Fjord's tab is tagged with `#fjord` in its address, and its id is kept in `storage.session`, cleared with the browser session (tab ids
  restart small, so an old id could name one of your restored tabs) and by an extension reload: then the tagged tab is found again by
  its address, or adopted when its script's port says it loaded tagged. Only the remembered id or a tagged tab is adopted, so your own
  tabs are never touched. The limit: a tab that has left `/code` when the id is lost (an extension reload, a browser restart) can't be
  found by its address, which no longer matches `/code*`, and is not adopted by guessing; the worker then makes a second pinned tab,
  and the old one stays an untagged stray, to close by hand. `content.js` puts the tag back with `history.replaceState`
  after each in-page navigation, in a tab that loaded with it.
- The worker attaches its port listeners before it awaits anything, and always sends the page a `snapshot` after adopting it. A port
  whose tab it can't check (the check failed) it drops; the page reconnects at once after a port that lived, and after a wait that
  doubles from 250 ms to 30 s after one dropped within 1 s of its connect, so the two never loop hot. The page
  answers it with `commands` and a full scan, then runs its waiting steps (a `wake` due meanwhile may have been lost with a restarted worker).
- When the adopted page's port drops, the worker tells routerd at once (`page` with `signed_in: null, page_ok: false`, as when there is
  no page, and `gone: true`), so runs pause (`do.blocked`) and the next page's snapshot answers for what was sent so far; a page that
  connects again says what it shows. Commands that come while there is no page wait
  in the worker, collapsed as the page collapses its steps: a newer one of the same `kind` and `side` replaces a queued one (`done`
  `superseded`), and a `cancel` removes its queued target and isn't queued (a tool step's `done` says "the step didn't finish", as the
  page's cut-off one does; a send or open sends none). A `cancel` whose target isn't queued is queued: the target may still wait in the
  page, whose script outlives its port. When no tab can be had (finding or opening it failed), every queued
  command but a `cancel` fails at once (`done` with the error: routerd opens again at the run's deadline, above); the cancels stay
  queued and never get a `done`; a queued `cancel` expires after 20 s (`CANCEL_KEEP_MS`). A host that links again advances no run on the health kept from before it: the link sets `page_ok: false` until the worker's first event
  (its `page`, or any event from the content script, which is proof of a page) says whether there is one, and advances them; a run made meanwhile is paused. The worker finds or
  opens the tab one attempt at a time: callers that come while one runs share it.
- The page took the words (`taken`) when the draft is empty after a click was reported, in this attempt or an earlier one. If a click had
  left the words in the draft before it emptied (a navigation can drop a draft), a run that is never proved says the page may not have sent them. A taken run never resends and no longer blocks:
  the next run acts while it waits for its row, which a queued message (sent while the coordinator replies) shows only after that turn.
  When another run took the tab away before the row came (a tool's read, a send elsewhere), the run goes back to its place as soon as
  the tab is idle, so the row proves it at once. That open is the run's own: it is cancelled when the run finishes, and one that is
  superseded or errs costs nothing (the run goes back again after the next move). After 300 s a taken run opens its place once, so a full scan can prove it; still unproved, it fails as taken but never confirmed.
  A page that goes (`gone`) right after a reported click (within `RELOAD_LOSS`, 3 s, of the latest one: the run is `reloaded`) can take
  the words with it: the page shows your message as pending until the server answers, and a reload ~0.1 s after the click lost it
  (measured: the reloaded page's rows, and every later one, lacked it). A page that goes later went after its pending row had time to
  reach the server: the run waits as any taken one (300 s; a queued message shows once the turn ends). A `reloaded` run is taken
  whatever the new page shows (words back in its draft are its saved draft; so are words in the draft of any page that replaced the one
  that took the click, after a `gone` whose next `page` has another `loaded` (or none to tell by: an extension reload keeps the
  document and its `loaded`) or in a `page` with another `loaded`, as after a reload while no host was linked: only the page
  that clicked gives up by putting the words back): it never sends again, not even click-only, also when a
  signed-out page paused it (the server may yet have them, and a row that comes before the failure still proves it). When the reloaded
  page's rows of the place, placed against the baseline, hold no row from you after it (`vanished_at`, when they showed it; only once
  a whole read of the place was `settled`: an unsettled one can lack the bottom rows), the run ends `do.TIMEOUT` (20 s)
  after the page went, or `VANISH_GRACE` (1 s, a margin of its own) after those rows came if that is later (even a settled read
  may not hold the bottom yet: a later `/timeline` fetch can bring it), instead of at 300 s, and fails, unproved, as "the tab reloaded right after the click, and the reloaded page
  doesn't show the words" (a dropped send, above, with its own cause), except while the coordinator is mid-turn (a Claude row of the
  place is still streaming, also one already there at the baseline, or a reply the page shows only under its `provisional:` key, which the
page's `rows` read marks as the place's `turning` before it drops pending rows: the server may hold the words queued behind it), when it
waits: once the turn ends (the first read that no longer sees it), the end is `do.TIMEOUT` after that too, if later, so the queued
row has a full wait to show. Through the turn it waits the 300 s: with no look while the tab shows the place (its rows were just read from the server, and its stream brings a
  later row of yours), and through the look's open only when another run moved the tab away. The server may still have queued the words
  behind a coordinator's turn, which shows them only once it ends: for 300 s after that failure (on the Mac's uptime, which stands still while it sleeps) each `rows` event of the place (that
  side: a thread's rows are no project send's) is placed
  against the run's proof (its baseline and anchors, which keep moving forward), and a row from you with the words confirms the intent
  late ("confirmed late, by a later read that showed the words after it was failed"), as a tool's later read does, unless another send
  claimed that row (one row proves one send). A new send of the same words doesn't end the watch: a second row confirms both. Since
  those rows come only while the tab shows the place, a watched send goes back to it as a taken one does: once each time a run opened
  another place during its watch (and once after it failed, if the tab is elsewhere then), behind every live run: only while no run
  acts or is about to, no open or look is in the page, every taken send that may go back went, no tool or dialog may use the page and
  a host is linked. It only opens the place (an open never types or clicks), and is no move: a taken send whose place it left goes
  back after it, and no other watched send goes back for it. It holds the other runs (a send, a tool, another going back, a look)
  until a settled whole read of its place came after it (when the place was already shown at the send, one before the open's `done` counts too, and an ok `done` for a place shown and already read ends it at once), at most 20 s from its open's sending, then 20 s from its `done` (a sleep moves
  the hold on). Only that read uses up its going back for the move, as does the page failing its open or its hold running out (a
  place that never settles isn't opened again and again): one superseded by another open, lost with the host, dropped by a reloaded
  page (a `commands` snapshot neither lists it nor reports it done; a replayed `done` of it counts as its `done`), or left before the
  read (the tab went elsewhere after its `done`) may go back again. A project the tab shows
  beside a thread, whose rows weren't read again on arrival, counts as not shown. A host lost forgets where the tab was: each watched
  send may go back once more. Every send
  that fails after a click is watched so, not only a vanished one: taken but never confirmed, stuck, one whose place then left the Board
  (failed with the refusal's cause, not refused: the server may hold the words; one that surely never sent is refused), one failed while its send was
  still in the page (it may click before the cancel lands) or with any send it issued not heard from (a cut-off one may have clicked
before its cancel; such a run also isn't failed at once by a foreign row from you, it keeps the cause and waits for its row; a cut-off
send with no `done` counts as never run once a command routerd sent after its cancel was answered by the document it was handed to, since
the page runs commands in order and its cancel came first; an answer to a command sent before the cancel says nothing, as a send waits in
the page while it settles and a dev command or a read may run meanwhile), and every one the restart fails ("routerd restarted before the words were
  proved") that had issued a send (it has a baseline: a click may have come with no `done` heard), so a replayed ok `done` of it
  changes nothing. Its end is
  kept in the result too (`watch`, on the wall clock): a restart watches it again for the rest of it, its proof whole.
- A clock jump (the Mac slept) moves deadlines on by a full wait instead of acting, and does not use up the wait for a taken message: its marks move with it, by at least the sleep (when it was taken, when its page went or was replaced, when its words were seen gone, the last
  look at the coordinator's turn, its last click, its look's end, the app's thread's grace, its attempt's end, when its `fresh` open is
  due), and so does the tab's arrival on its project, whose settling had no time to come while the page slept.
  The jump is also seen against the last check (the wall clock's gap less uptime's, more than `do.TIMEOUT`), so a run with no
  deadline past (one paused across the sleep, or whose wait runs past it) has its taken wait, `vanished_at` and `reloaded` moved on by
  the sleep too and doesn't take its look at once. A long idle stretch while awake is no jump.
  The watch for a send failed as vanished is on uptime (macOS's monotonic clock, which doesn't advance during sleep), so it needs no
  run to see the jump.
- Growth: at start, chat and messages rows older than three days are dropped from Seen (the newest of each subject stays) and at most
  200,000 rows are replayed. The fold keeps only claims past the told mark, and the waiting facts and claims are capped.
- Missing elements give `unknown`, never a guess.
- Diagnostic: the extension logs `tab_front` (`console.warn` in the worker, never sent to routerd) when Fjord's tab becomes the selected one.
