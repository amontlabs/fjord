# Performance

How Fjord stays fast, what was measured, and the rules a change has to keep. Written after the October 2026 performance
pass (branch `perf/snappy`); update the numbers when they move.

## Budgets

| What the user does | Budget | How it's measured |
| --- | --- | --- |
| Close the window (shortcut, close button) | first moving frame ≤ 1 frame after the request (`Close to first flush` ≤ 16 ms p95) | `scripts/morph-timings.sh` |
| Open the window | first moving frame ≤ 1 frame (`Open to first flush`); window live when the spring settles | same |
| Any capture | never on the critical path of an open, a close, or input | `Capture*` signposts must not sit inside `Open`/`Close` before the handoff |
| Typing (composer, rule editor) | no store write, sort or full relayout per keystroke | code review; `RouterMentionField` coordinator caches |
| Idle, window closed | no repeating main-thread timers; no 1 Hz clock | `sample <pid> 3` should show an idle main thread |
| Idle, window open, nothing changing | main thread near idle; no layout passes | `sample <pid> 3` |

## Measuring

- **`scripts/morph-timings.sh`**: plays `--demo busy --motion-script "open,close x10" --quit-after` on a release build and prints
  every `com.amontlabs.fjord` signpost interval's count, p50, p95 and max from the unified log. No Instruments, nothing kept on
  disk. `--bin` compares another build (e.g. `main` built in a `git archive` copy under `/tmp`); `--json` writes the summary.
  It takes the screen for ~1.5 s per step.
- **Signposts** (subsystem `com.amontlabs.fjord`, category `morph`): `Open`, `Close` (whole intervals), `Open to first flush`,
  `Close to first flush`, `Bring in`, `Capture` (split into `Capture bitmap`, `Capture draw`, `Capture image`, `Capture flag
  on/off`, `Unblend sidebar`), `Glance drawn`, `Install picture`, `Handoff`, `Overlay going`; category `latency`: `Bar away`.
- **The installed app logs these too** (they are persisted): `log show --last 1h --signpost --style compact --predicate
  'subsystem == "com.amontlabs.fjord"'` gives real-world numbers with real data, without running anything.
- **Idle CPU**: `sample <pid> 3 -file /tmp/fjord-sample.txt` on the running app; look at the main thread's share and at the
  `fjord.claude` queue.
- `scripts/motion-trace.sh` (xctrace, hitches) exists for frame-level work; guard the disk (Instruments' scratch in
  `$TMPDIR` once reached ~58 GB) and keep recordings short.
- Demo data at the default window size understates real costs: the same capture was 66 ms on demo data and 520 ms live
  (1617×1188 pt window, real data, heavy Router canvas). Design for the expensive case.

## What made open and close slow (October 2026)

Live, before: open 807–865 ms from request to overlay gone, close ~0.5 s frozen then a 0.46 s shrink.

1. **One synchronous full-window capture on every open and every close** — `cacheDisplay` of the theme frame on the main
   thread. Its cost is SwiftUI's display list redrawn on the CPU in the hosting view's own layer: it scales with content and
   pixel count, not with layer count or effects. 1x is ~3.5× cheaper than 2x. `CALayer.render(in:)` costs the same.
   ScreenCaptureKit needs Screen Recording permission and `CGWindowListCreateImage` is unavailable in the macOS 26 SDK, so
   there is no cheap GPU path to the window's own pixels.
2. **The close waited a display refresh** (with a 100 ms fallback) before moving.
3. **Content re-attach** on each open re-ran every `onAppear`/`.task`/`onChange(initial:)`, and replayed as animations every
   change made while the window was closed.
4. **Work landing mid-morph**: a GitHub sync started one turn after opening, a 20k-folder code scan on app activation, the
   Claude/Router feed applying every ~0.5 s, the inbox memo evaluated inside a view body.
5. **Whole-tree invalidation**: the bar and window roots read whole `router`/`agents` structs and rebuilt their environment
   closures, so every Claude read redrew everything.

After (release build, demo `busy`, `morph-timings "open,close x10"`, default size and 1617×1188):

| | main | perf/snappy |
| --- | --- | --- |
| Open: request → window live | ~391 ms (overlay gone ~495) | p50 308–320, p95 321 |
| Close: request → done | ~460 ms after a 73–100 ms capture (520 live) | p50 314–319, p95 325 |
| Close: request → first moving frame | capture + up to 100 ms refresh wait | p50 7–9, p95 10–14 |
| Captures inside an open or a close | 1 each | 0 |

## The design now

### First-open AutoFill stall (October 13, 2026)

The reported release `open,close x10` run had Open p50/p95 **311/659 ms**, Handoff **37/378 ms**, and a first handoff of
**378 ms** despite a 6 ms `Warm window`. A fresh unmodified run was already fast (Open **309/322**, Handoff **32/41**,
first handoff **24 ms**): the stall is intermittent, not a fixed cost of revealing the window.

Temporary spans around reveal's alpha and ordering, the transaction commit and flush, and display-link creation and
registration measured at most 1 ms. Repeated fresh launches reproduced a **419 ms Handoff / 692 ms Open**. A two-second
`sample` caught the main thread in `SPCompletionListRemoteViewController.resizeRemoteWindow` →
`SPSafariPlatformSupport._updateWindowVisibility` → `SLSConnectionSynchronizeSLSCATransaction` →
`_SLSTransactionWaitSource`, waiting for the WindowServer to order AutoFill's remote completion window. Other launches
stalled before Handoff (Open 673–703 ms). The two-refresh fallback cannot run while this callback blocks the main thread.

Fjord has search, editor and composer fields, but no security-code entry. Apple's
[`NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsautofillrequirestextcontenttypeforonetimecodeonmac)
opts these fields out of macOS 26's unsolicited security-code AutoFill; an explicitly marked `oneTimeCode` field can still
opt in. `Resources/AppInfo.plist` supplies this policy both as the SwiftPM executable's embedded `__TEXT,__info_plist`
and in the packaged app's Info.plist. No window is ordered in, no activation occurs, and no preparation work is added.
The removed `NSAutoFillHeuristicControllerEnabled` default is unsuitable on macOS 26.2 and later
([Chromium's current implementation](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/content/app/mac_init.mm)).

After, without temporary instrumentation, release `open,close x10`: Open **308/323 ms**, Handoff **28/41 ms**, first Open
**308 ms**, first Handoff **25 ms**; no SafariPlatformSupport/AutoFill connection appeared in that process's log. A regression
test reads the built executable's metadata through CoreFoundation, and the bundle metadata merge preserves its identity
and accessory policy. Six more fresh launches (`open,close x1`) had first Open **306–317 ms** and first Handoff **22–36 ms**.
The final release run with the live-close reopening fix also applied had Open **313/322 ms**, Handoff **35/40 ms**,
first Open **304 ms** and first Handoff **23 ms** (`open,close x10`).

### Window and motion

- **No capture inside an open or a close, ever.** Only the idle keeper captures. It runs while the window is visible, key
  and front; captures only once two looks agree (content at rest), input has been idle for max(0.5 s, 3× the capture's cost),
  no text is being composed, and the content changed. "Changed" is a quarter-scale glance plus `Marks` (window input, asks,
  and `Store.shownRevision`, which every store write that the window draws bumps). Costs are kept per size, scale and page
  (`CaptureCosts`, the last minute's maximum); a capture estimated over 30 ms is skipped, and on Retina the keeper keeps a
  half-scale ("soft") picture.
- **Close** starts in the request's turn: on the kept picture when it is fresh, else the live window fades out over 0.1 s
  above the overlay while the glass shrinks. Focus goes back to the previous app at once.
- **Open** starts from the kept picture (or the bare surface) and, at the handoff, cuts to the real window when the picture
  is exact (rechecked at the cut, `stillExact`) or fades over 0.12 s. The window is laid out and drawn in the turn it is
  brought in, so its first draw never lands on the handoff. It takes clicks once revealed. Reversing a live close fade
  keeps the window above the bare overlay through the handoff's two refreshes and the overlay fade; its normal level
  returns only after the overlay is ordered out. The regression steps both refreshes and waits for removal, for glass
  and opaque morphs with normal and reduced motion.
- **Springs**: open and close are critically damped at 0.30 s (glass and opaque alike); they are now the floor.
- **`MotionGate`** (`Sources/Fjord/MotionGate.swift`): the morph calls `began`/`ended`; main-thread work that can wait
  goes through `whenStill { }` / `await still()`. Released work runs one item per run-loop turn. A missed `ended` lets work go
  after 1.5 s. The sync, the Claude feed, Jev and brief results, `reportOpen`, service start-up and post-open scans use it.
  New work that lands on main and can wait half a second **must** use it.
- **`WindowArrival`** (`Motion.swift`): the window's first update after its content is re-attached is unanimated, so changes
  made while closed don't replay as springs during the handoff.
- **Content is detached on close and re-attached on open** (re-attach measured ~10 ms); keeping it attached would re-render a
  hidden window on every sync.
- **Launch**: `state.json` is decoded off main from `main.swift`, fonts register from a per-archive cache, the bar draws
  before services start, services start after the first frame (and after any first-launch morph).
- **Stored, narrow observables**: `Store.routerOn`/`triageOn` are stored Bools; `routerZones`/`routerCounts` are memoized
  (`RouterMemo`); cards are `Equatable`; selection and highlight are observed per row (`isSelected`, `isMarked`); session rows
  are per-session boxes refreshed only for sessions whose inputs changed.
- **Off main**: GraphQL → `Thing`, CI folding, workflow mapping, code-folder scans (`.utility`), task-folder listings (cached by
  inode/ctime, stat only the live sessions), `ClaudeMark`, `SessionIcons`, Settings' login-item and Accessibility reads, the
  Accessibility trust check behind modifier taps, the mouse-button event tap (its own thread and run loop).

## Router canvas idle (October 13, 2026)

Measured inside the `router-canvas` worktree, after merging main's 203 commits. Release binaries, macOS 26.5, the saved
1480×940 pt window open on Router canvas, five seconds to settle, then `sample <pid> 3`. CPU is the process's cumulative
CPU-time delta divided by wall time around `sample`; main-thread busy is the fraction of samples outside its run-loop
Mach-port wait. These are demo measurements, not the original live data's reported 30–90% CPU / ~38% main-thread busy.

| Build / change | CPU, one core | Main-thread busy | Hosting-layout samples |
| --- | ---: | ---: | ---: |
| Isolated `d2943a9`, Router demo on canvas | 6.73% | 183/2456 (7.45%) | 138 |
| Merged canvas with layout caches, before the working-dot fix | 10.01% | 266/2566 (10.37%) | 168 |
| Working dots on Core Animation | 3.05% | 71/2459 (2.89%) | 8 |
| Picture keeper also backs off when capture is over budget | **0.53%** | **17/2606 (0.65%)** | **3** |

The reproduced invalidation source was **`WorkingMark`'s 350 ms SwiftUI `TimelineView`**, used by the canvas's “The Router
is working” notice. Its animation caused hosting layout and CA flush work even with no input. Working's Fjord loader and
the activity-text sheen were already Core Animation layers. Temporary counters found only initial geometry writes
(`topRoom`, content size, viewport/free room and first fit), not a sustained geometry-to-state feedback loop. The exact
original live load was not reproduced with the smaller demo.

The three dots now step on `CAShapeLayer` opacity keyframes, with their wall-clock phase preserved, stopping when detached,
hidden or under Reduce Motion. Apple's [discrete keyframe mode](https://developer.apple.com/documentation/quartzcore/caanimationcalculationmode/discrete)
uses one value per interval and one additional end key time; no SwiftUI clock runs for the dots. The remaining sampled
work was mostly the idle picture keeper: it retried an over-budget capture every half second, redrawing expensive glances
although it could never capture. That refusal now increases its interval to four seconds, just as a kept picture does.
A failing regression first measured the stuck 0.5 s interval; the fix reaches 4 s without taking a picture.

The canvas also carries main's memoized zones, counts, equatable cards and hidden-history policy:

- Router-card copies compare a shared contents token first; all 22 stored fields replace it when changed, including nested
  edits. Independently created or decoded cards retain value equality; no token enters the saved file.
- Folder derivation and preferred packing are memoized on their full inputs, including names, colors, muted folders,
  picks, search, filters, folds, frame sizes and hand positions. Stack order is indexed once per body, not searched per frame.
- `CanvasBoard` and `CanvasFolderStack` share measured sizes between size requests and placement, proposing the same whole
  sizes they measured. Group and hand-placement inputs are explicit Layout properties: the interaction regression caught
  stale metadata-only cache updates before these were passed directly. Apple's [Layout cache lifecycle](https://developer.apple.com/documentation/swiftui/layout/updatecache(_:subviews:))
  invalidates on layout/subview changes; cached row heights and frame places must still address the actual inputs.
- Collision placement uses horizontal segment indexing and merged vertical intervals instead of pairwise rectangle scans.
  Forty generated scenes match an exhaustive oracle; 1000 stacked frames resolve in about 3 ms in the debug regression.
  A heap assigns shortest columns; a bounded search around the 16:10 crossing replaces trying every possible column count.
  This keeps a deterministic near-screen shape, rather than promising the exhaustive global minimum for arbitrary heights.

Final release `scripts/morph-timings.sh --scenario routerCanvas --steps "open,close x6"` (the canvas and its `routerCanvas` scenario are gone since; measure with `--scenario router`):

| Interval | p50 | p95 |
| --- | ---: | ---: |
| Open | **312 ms** | **316 ms** |
| Close | **314 ms** | **318 ms** |
| Open to first flush | 9 ms | 11 ms |
| Close to first flush | 2 ms | 4 ms |
| Bring in | 28 ms | 37 ms |
| Handoff | 15 ms | 16 ms |

No capture intervals appeared in that run. `--demo routerCanvas --open` selects the canvas directly using the Router demo's
same data, so measurement does not depend on the last saved page or layout. The targeted run passed **64 tests in 14
suites**; the final `scripts/test.sh` passed **1567 tests in 155 suites** in 45.733 s. Offscreen renders verified a narrow
frame, a resized scrolling frame and an expanded working card. Temporary counters, samples, binaries and shots were
removed and the bare binary's `Fjord` preferences restored.

## Router page (November 2026)

The Router page (docs/design/router-v2/IMPLEMENTATION.md, section 2) replaced the brief page on 2026-11-13. How it stays
fast:

- **One record per thread** (`RouterRecords`): a T3 push re-reduces one row and hands on at most one `.upsert`; nothing sorts
  every thread, nothing rebuilds a board. Streamed words go through one coalescer flushed once per main-loop turn
  (`RouterModel.post`), never a timer or a display link.
- **Narrow observables**: one box per line; the list reads only a stored, `Equatable` layout (row ids and kinds), rewritten
  when a line's section or order changes. Selection, hover and the draft's destination are flags on the two boxes involved.
- **Hosting views per row** (`RouterHostedRows`, `RouterGlideView`): each row has its own `NSHostingView` whose update
  requests don't relayout the list, rows are placed at once and glide on Core Animation.
- **Ticks on Core Animation** (`RouterTicks`): ages, section and filter counts and a state's mark roll as pictures, so a
  roll costs SwiftUI nothing per frame.
- **Verdicts only when they can come**: with the Router off nothing is asked and nothing sheens waiting.
- **Working summaries without polling** (R6, `RouterRecords.summarizeIfNeeded`): a summary is weighed only in the record's
  own refresh (a string of the latest message id and the running step, compared), asked through the verdicts' queue and
  cap, at most one a minute per thread; a trigger inside the minute sets the record store's one boundary timer, nothing
  ticks. The line sheens on its record, its words stream through `.words`, and the record is handed on twice per summary
  (its first words, its end); the card doesn't read the sentence (`RouterWork.lineReadsNewest`). The prompt's input is
  built off the main actor with the verdicts'.
- **Open items without polling** (R7, `RouterItemLedgers`): an input is noticed in the record's own refresh (the latest
  run and your last message's time, compared with what the ledger saw; nothing new returns before any work), read one at
  a time per thread through the verdicts' queue, its facts from one projection read (or the one already held). A read
  hands the record on at most four times (it starts, what closes, what is found, the end) and once more when the ledger
  settles 1.6 s later (one task, no timer). 500 rows still reduce in under 5 ms (`RouterRecordsTests`).

Gates (2.4), release build, 1617 × 1188, 2026-11-13, at `c889736e`: three runs each, interleaved with the build before
it (`5abf8131`); load average 4-12 throughout (a browser tab and WindowServer busy), so p95s move several ms between
identical runs. Before → after where it moved.

| Gate | Run | Budget | Measured (runs) | |
| --- | --- | --- | --- | --- |
| T3 event, synthetic | `--router-v2-load` | p95 ≤ 8, max ≤ 16 ms | p95 15 / 15 / 15, max 77 / 86 / 32 | red |
| Flush, synthetic | same | p95 ≤ 2 ms | 3 / 2 / 6 | red (was 4 / 5 / 5) |
| T3 event, real day | `--router-v2-load real` | p95 ≤ 8, max ≤ 16 ms | p95 26 / 18 / 20, max 31 / 18 / 29 | red |
| Flush, real day | same | p95 ≤ 2 ms | 10 / 11 / 11 | red |
| T3 event work (the handler alone) | synthetic / real | ≤ 2 ms | p95 1 / 3-5, max 2 / 5 (the same before) | real red |
| Key | `--router-v2-demo --speed 4` | p95 ≤ 8 ms | 27 / 26 / 26 → 25 / 25 / 26 | red |
| Key work | same | p95 ≤ 2 ms | 11 / 10 / 9 → 7 / 6 / 7 | red |
| Send | same | p95 ≤ 8 ms | 49 / 49 / 53 → 62 / 49 / 52 (p50 33-34 → 27-33) | red |
| Select | demo, speed 4 / `--router-v2-load select` | p95 ≤ 8 ms | 31 / 29 / 31 → 29 / 28 / 30; select load 27 / 27 / 24 → 27 / 28 / 27 | red |
| Select work | same | — | demo 12 / 13 / 12 → 7 / 7 / 7; select load 3 / 3 / 3 (max 15-17) → 0 / 0 / 0 (max 1) | |
| Working summaries, real day | `--router-v2-load real` (now with each working line's summary once a minute), release, 3 runs interleaved with `2aaf1beb`, load average 16-30 | no regression | T3 event p95 7 / 12 / 12 → 10 / 6 / 9 ms, max 12-18 → 12-16; work ≤ 1 ms both; Flush p95 3-4 → 4 ms; a summary landing 3 ms to commit (`FJORD_LOAD_OFF=records`) | as before |
| Open items, real day | `--router-v2-load real` (now with a read every 6 s on four blocks: pulse and sheen, the read landing, the ledger settling), release, 3 runs interleaved with `3741dbe1`, load average 19-30 | no regression | without the items (`FJORD_LOAD_OFF=items`): T3 event p95 6 / 12 / 10 → 9, max 14-22 → 20; work ≤ 1 ms; Flush p95 4 → 4. The reads alone: p95 9, max 9 ms. A line becoming a block (four at the load's start, timed with `FJORD_LOAD_ITEMS_SEED=1`): 30-60 ms each, one commit | reads green; becoming a block red |
| A line becoming a block | `FJORD_LOAD_BLOCKS=1 --router-v2-load real` (a line gets a second item, and loses it, every half second, a line after another), release, 2026-11-13, load 12-24 | ≤ 16 ms | a line's first time 7-16 ms, later ones 2-5 ms, back to a line 2-5 ms; the first in a launch 41 → 16 ms (`RouterBlockWarmup`). A one-item thread no longer becomes a block for a read at all. Real-day T3 event p95 10-13 ms, Flush p95 3; the max (53-86 ms) is the load's first event, in the commit of its untimed four-block setup, the same before the fixes | green |
| Bodies per change | `RouterRenderTests` | 1 line body per upsert, 0 list; 2 per hover | as budgeted (counted per page since `0ed63fcc`) | green |
| Idle, window open on the Router | `ROUTER=1 scripts/idle-cpu.sh` | ≤ 0.6 % | 0.30 %; 0.200 % → 0.133 % with working summaries; 0.100 % with open items (2026-11-13); 0.100-0.167 % after the REVIEW-items fixes (one run of five at 1.1 %, noise) | green |
| Open / Close | `morph-timings --scenario router --steps "open,close x10"` | p95 ≤ 325 ms | Open 314 / 318 / 315, Close 317 / 318 / 319 | green |
| First flush | same | p95 ≤ 16 ms | Open 16 / 21 / 18 (before 20 / 16 / 18), Close 10 / 8 / 8 | Open red by 0-5 ms |
| Captures inside a morph | same | 0 | 0 | green |

What is left red is SwiftUI's own update, layout and drawing at the commit, not Fjord's work. Under the demo script,
sampled, the main thread's display cycle is 8.9k of 53k samples, 6.1k of them SwiftUI's render (`updateOutputs`,
display-list rendering); the Router's own frames are a small part.

**One animation per hosting view per turn.** SwiftUI updates a hosting view synchronously, inside the code that writes,
when that view gets writes under two different animations in one turn: no animation then a spring, a fade then a
spring, `withAnimation(nil)` after a plain write. The same animation twice, or writes that reach different hosting
views, cost nothing (a standalone check with two hosting views). Under the demo script these updates were 296 of the
313 sampled ms inside the key map's handlers (`GraphHost.flushTransactions`). `c889736e` took away the three that
mattered: the key's "seen" write now goes in the act's own transaction (`RouterModel.takeSeen` / `markSeen`), the
scroll to the selection is a call (`revealer`), not an observed tick, and the draft empties in the row's reset. The
handlers' work halved; the key-to-commit time hardly moved: the same update now runs once, at the commit, and costs
about what its pieces did. Writes in a handler that views read must share one animation; give a view its own curve
(`.motion(.fade, value:)`) when it must keep one.

**Rows missing while a card opens or shuts, and the clicked line dropping** (found 2026-11-13). Clicking a line made it
vanish, come back lower and glide up as its card opened; the rows under it were blank for some 0.15 s. Four causes, each
seen in 60 fps frames (`--frames-rate 60`) and in the views' geometry logged per frame:

- *The list's stack animated its rows for a card.* Only a change of order was placed at once (`placedAtOnce`); a card
  opening or shutting kept SwiftUI's animation, so the stack moved each row's container (`_NSGraphicsView`) on the
  curve while the row's hosting view, under `routerGlides()`'s nil animation, sat at its new place inside it: up to
  216 pt outside the container, whose clip (the fold transition's `mask`, applied at identity too) cut it, and whose
  `visibleRect` left it out of SwiftUI's drawing. The ticks, Core Animation layers of their own, still drew. Now the
  list places its rows at once in every turn but one where rows come or go (`RouterModel.folding`), and the fold's mask
  reaches 20 000 pt above and below an open row, so a row gliding is drawn where it is.
- *SwiftUI animates a hosting view's new size around its root's new centre.* When a line's hosting view grew for its
  card in an animated update, its root took its new centre at once and its size on the curve: the line was drawn half
  the card's height lower and slid up. The line's hosting view now keeps one height (`RouterLineSlotView.room`, 2400 pt,
  grown in steps for a taller card); only the slot is hit.
- *A card's roll is drawn two or three frames behind the glides.* It is SwiftUI's, on the main thread; the rows glide on
  the render server. A line rising under a card that shut covered its last lines. The line's hosting layer has a mask
  down to the slot's bottom whose height rolls on the glides' own Core Animation curve (`RouterLineSlotView.clip`), with
  the selected ground's bottom corners.
- *The card's first layout was not its last.* A plan was cut at a height measured a turn later (the whole plan for a
  frame: the rows under it went off the page and came back), and the card's place had no width while closed (its clip
  grew across for the first frames). The plan is cut in the same layout (`RouterPlanCut`) and the place is the line's
  width.

Also: the line's slot took the list's proposed height, not the hosting controller's measurement, which lagged a turn and
left a shut card's slot at its open height, over the rows after it.

Checked with `--select-check [few]` (cards opened mid-list and last, switched, shut, ↓ and ↑ walks; `few`: five lines)
and `scripts/router-frames-check.py`, which reads each frame's `rows-*.json`: 0 rows missing in 3,759 frames (beat 4,
both scenarios). The Select load at `c3061d76` → after, release, two runs each, interleaved, load 7-8: p95 25 / 26 → 23 /
27 ms, p50 17 / 16 → 13 / 14.

**A card's quote that couldn't be opened** (found 2026-11-13). A reply longer than 320 pt opened into a second view, a
320 pt `ScrollView`: the whole text was drawn unclipped over the options for a few frames, then the box cut it with no
fade and, with overlay scrollers, no scroller: it read as shut again, and `→` had nothing left to open. The quote is now
one `Layout` (`RouterQuoteCut`): its words, the cut, the fade, the rail and "Show all" / "Show less" placed in one pass,
no inner scroll. Two more things the long roll showed, in 60 fps frames:

- *A view sized outside an `.animation(value:)` takes the new size at once.* The card's place follows its content on
  `.motion(.spatial, value: cardHeight)`, but the selected ground behind the line is the line's background: as a quote
  rolled shut with its card open, the ground shrank in one frame and the words were drawn below it until their roll
  ended. The ground has the same `.motion` now.
- *A button's colour changing mid-roll moved its title.* The quote rolling takes "Show less" from under the pointer;
  its title going back to muted put it at the roll's end at once while its key still rode the edge. The button is a
  `.geometryGroup()`. (Its titles are both always there, one clear; it is clipped to nothing, not swapped out by a
  `ViewThatFits`, when the quote has nothing past its first lines.)

The frames check now counts the rows that glide at the one offset that fits them together: the picture is the render
server's frame for the next refresh, ahead of the presentation layers the rects are read from, by 15 to 80 pt in a tall
card's roll. Checked with `--select-check` and `--select-check few` (a long reply opened by `→`, shut by `←`, opened by
"Show all", shut by "Show less"): 0 rows missing in 2,399 and 2,195 frames; a row painted out in a gliding frame is
found.

## Rules for new code

1. Nothing synchronous and expensive between a user's action and the first frame that answers it. If it must happen, do it
   at idle beforehand, or after the motion through `MotionGate`.
2. Never read a whole `Store` struct (`router`, `agents`, `things`) in a body that doesn't need all of it. Read a narrow
   stored or memoized value; add one if needed.
3. No sorting, filtering, regex, date formatting or attributed-string building in a `body` without a memo keyed on its inputs
   (and check that the key covers *every* input — stale memos were the most common review finding).
4. Don't create closures for the environment in a root body; build them once.
5. Timers: tolerance always; stop them when their window isn't visible; prefer one shared clock to one per row.
6. Files and processes: never on main. Use `OffMain.run(qos:)` with `.utility` for background scans.
7. Debounced writes must be flushed on disappear, on quit (`PendingEdits`), before undo/redo, and must address their target by
   id, not by index.
8. Anything that holds work for a motion must also handle cancellation after the wait and re-check its fences.
9. Measure before and after with `scripts/morph-timings.sh`, and paste the numbers in the commit message.

## Known open items

- The keeper's 30 ms budget means Retina machines keep half-scale pictures, so most openings fade (0.12 s) into the live
  window instead of cutting. A cheaper exact capture path would allow cuts.
- Whether `NSGlassEffectView`'s `cornerRadius` through `animator()` is driven on the main thread is unverified; if it is, the
  3–11 ms glance at the handoff could cost a corner frame.
