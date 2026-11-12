# Wave 2 handoff notes (from wave 1, 2026-11-12)

## Track 6 (acts) — fb67f31d 03fb6530 dc30a294 b7f42605 36735c71
- `RouterActs.live(store:records:emit:)` is the real `RouterV2Source`; it sets `store.routerDispatcher.onSend` itself.
- 9a must wire: `reader` (track 5's reader), `decision` (track 5's latest decision, for the decision log), `models` (launch catalog), `emit`, and `records` (track 3's store must adopt `RouterActsRecords`: began/took/ended(send:), hide(_:on:), notForMe(_:on:), seen(_:)).
- History drawer's own Revert still goes through the old brief hold until 9a switches it to the records.
- Open: a refused settle/snooze can't toast its reason (no toast case in `RouterV2Change`; `.refused` ignored for lines with no `sent`) and the page's undo entry stays (⌘Z would unsettle a never-settled thread). Needs a port addition + model seam.
- Open: `RouterV2Thread` has no request id (picks read against the request held at Return); `start` has no mentions; a failed Stop is silent.
- `start(project:)` matches T3 projects by id, then title.

## Track 2 w1 (detail, PRs) — 03e74f19 af1fcebe
- `RouterDetail.make(projection, now:)`: working (todo step → first sentence of latest words → tool → "starting"), steps, reply/writing, request, queued, diff (summed per turn; may double-count a file touched in two checkpoints), lastStep, steers.
- `RouterPullRequests(link:github:)`: `states(for:reply:)` (cheap, T3 state wins, named PRs linked once), `onChange(threadId)`, `refresh()` (window open + Triage sync), `forget(_:)`. 9a/track 3 wire `link` to `dispatch(.pullRequestLink)` and pass the last reply text.
- A PR with unknown state is hidden (no `.unknown` state).

## Track 5 (reader, launch catalog) — 86e314e5 5ac956c3 c159e1ad
- `RouterV2Reader`: read/cancel/now/searchHits; closures jev, decide, search, boardKey, eligible, allowed, tagged, onRead. Pauses still 600/1200 ms in the reader (plan default 300/600; move into `enum RouterV2` and set 300/600 in wave 2).
- `RouterLaunchCatalog.make/offer`; `RouterLaunchFeed` reads `server.getConfig` on `connected()`, emits `.launch` on change. Lists every ready provider (Codex too); efforts only from option id `effort`.
- Decider: `DeciderContext.Inputs.open`. (Removed 2026-11-12: `launch`, `launch_words`, `launchRole`, `taken` and the "approval-required" mapping; settings are `@` pills now, `RouterSetting.swift`, `RouterV2Settings.swift`.)
- 9b wiring: feed on connect/reconnect; reader `decide` passes `open: selected`, `launch: feed.offer`; jev→readDraft, search→searchDraft, boardKey→deciderBoardKey, eligible→routerDispatcher.eligible, tagged→RouterPointers.context; searchHits in place of routerPreview.searchHits; `onRead` decision → `RouterContext.decided` (and RouterActs.decision).
- Eval (wave 2): 300 dev moments vs N4 (top-1, wrong-thread sends, new-work starts); 40 drafts with settings asides (launch/launch_words, nothing meant for the agent taken); share of Sonnet calls cancelled by keystrokes.

## Track 8 (composer, dock, keys) — c6bf9a8a fdbbc311 479577b2 db35e0ab
- 9a: set `routerV2Composer` env (store + RouterModel) so the composer is `MentionField`; pass `composer:` into `RouterV2Keys.key(event, model:, composer:)` from the window's key monitor; set `routerV2Waiting` env, fill `RouterV2Waiting.items` (unattended actions with no place), wire its `pick`.
- Live-only checks for wave 3: caret-anchored @ list position, IME in the new field, ⇧Return, new-thread pill vs real project names.

## Track 4 (verdicts) — 1b601827 788b165a 5298cf78 cedf3faa
- `ClaudeStream` (streamed claude -p, PartialJSON field-by-field), `RouterVerdicts` (ask/cancel/isAsked/onEvent, cap 4, purpose()), `ProjectPurposes` (9b wires into decider block B), eval export `evals/router/verdict/export.py` + `VerdictEvalDump` (FJORD_VERDICT_EVAL_DIR, FJORD_VERDICT_EVAL_RUN=1); 169 real cases dumped.
- MISMATCH: track 3's RouterRecords defines its own VerdictAsk/VerdictStep(+named)/Verdict. Wave 2 maps VerdictAsk(thread+RouterDetail) → RouterVerdictRequest and events back (name call `.done` → `.named`), or aligns the types.
- Latency: state 2.3 s alone, 4.7–5.1 s for finished turns with 4 at once (Haiku 5.5 thinks ~150 tokens; no flag to stop it). Plan said ~1.9 s. Options for wave 2: smaller input for finished turns, ask-only first pass, or a faster model by eval.
- Ask only once the reply is loaded (same fingerprint with new input is ignored). `.words(done:true)` precedes `.done` by 0.3–0.5 s.
- Seam wanted: `RouterTools.redacted` nonisolated (RouterMCP.swift) so input builds fully off main.

## Track 3 (records, banners) — 84a829c2 ea8ba6c4 cfdcd8f1 655021c0
- Uses track 4's types now: `records.verdict(id, fingerprint:, RouterVerdictEvent)` ← `verdicts.onEvent`; `records.ask` → `verdicts.ask` (RouterVerdictRequest). The earlier type mismatch is resolved.
- Conforms to `RouterActsRecords` (+ `delivered(_:)`, `cancelledQueue(_:)`).
- 9a: `records.shell(item)` first in `onShell`; `detail(id, RouterDetail.make(…))` in `onThread`; `delivered(_:)` from whoever watches `Store.delivery`; `projectName` = `Store.folderName`; `notifier.post` = `Store.notifyRouter`; `pullRequests` → track 2's `RouterPullRequests.states`; `RouterVerdictFile.live(supportDir)`, `flush()` on quit.
- Open: `RouterActs.Send.Kind.start` needs `name: String?` so a new thread's line keeps the read's name; permission `warning/warned` empty (ThreadRequest has none); Stopped lines kept 7 days.
- Perf: 500-row shell reduces in 2.85 ms (debug).

## Track 7 (rendering) — ad0b9369 22b44659 ce129ef8 3a4992d6 6aa49c4d
- Streamed `.words`/`.reply` must go through `RouterV2Model.post(_:)` (the per-frame coalescer), not `apply` (9a wires tracks 3/4 to it).
- `RouterV2Thread.live` (default true): track 3 should set it from `ThreadRequest.live` (not-live card shows Open in T3).
- Load scenario: `--router-v2-load`; `scripts/morph-timings.sh --args`.
- GATES MISSED (release, load): event→commit p50 41 / p95 99 / max 225 ms (budget p95 ≤ 8); Select p95 68–83 ms (≤ 8). Per-record work is ≤ 1–2 ms; the cost is SwiftUI laying out and drawing the whole 60-row page each frame. Needs a list layout change (stored row heights, lazy stack, or per-row drawing isolation). Idle 0.10 % (met). Bodies per change met.

## Wave 2 small fixes (owned by 9a unless noted)
- `RouterActs.Send.Kind.start` gains `name: String?` (track 3 open item).
- Refused settle/snooze: a port case for a toast with the reason, and drop the page's undo entry (track 6 open item).
- Reader pauses to 300/600 ms, moved into `enum RouterV2`.
- `RouterTools.redacted` nonisolated (RouterMCP.swift, 9b's file) so verdict input builds off main.

## 9b (bar, palette, MCP, decider) — 86240d4b 721ad8e7
- Bar/palette/MCP/RouterRun/RouterJev/decider read the records; Rewrite Briefs (⌘R, menu, palette) gone; `RouterTools.redacted` nonisolated; `Store.lineTitle` in RouterDispatcher.
- For 9a: construct `ProjectPurposes(verdicts:url: ProjectPurposes.live(paths))` → `store.routerPurposes`, `keep(only:)` + `flush()` on quit; window's `pickBriefEntry` handler → `routerPage.select(.line(thread))`.
- Wave 3: delete remaining RouterBriefs readers (RouterComposer, RouterKeys, RouterView, RouterDrawer, Playground, AppWindowShots, AppSidebar, AppWindow, DemoBriefs) and change pickBriefEntry's type; RouterV2WiringTests; HubTests coverage for RouterRecordLine; RouterRunContext heading wording.
- Open: a project's purpose stays empty while any live thread lacks a readable first ask.

## Decider eval fixes — a6f3ab8b (eval) e8f5fe73 0cc83bc8
- Brackets cut with the aside; "don't edit anything" → approval-required; Sonnet only when Jev is unsure, ≥12 chars and ≥10 new chars since the last start (Jev 300 ms, Sonnet 600 ms).
- 9a: in `makeRouterReader()` set `reader.log = <store's DeciderLog>` (typing pause/start/skip/cancel/done lines).
- Watch live: new work pushed into old threads 1.5% (was 0.7%); refit the idle bar after ~200 live decisions (`refit.py`).

## 9a (store, window, drawer, shots) — 3647701b e3723422 f38f9add
- `Store+RouterV2.swift` makes and wires records, verdicts, reader, acts, launch feed, PRs and `ProjectPurposes`; `wireThreads` feeds the records first. `routerFocus(thread)` replaces `routerBriefs.focus`; `routerDrawerOpen`, `routerNeedsYou` on the store.
- `RouterV2Screen(model:store:text:)` hosts the History drawer (beside from `sideFrom` ≈ 1130 pt, else under), its ⌥⌘B toggle and `RouterSetupNotice`. Shots: `v2-drawer`, `v2-drawer-narrow`, `v2-setup`, `v2-off`.
- Shots reset `RouterV2Demo.model` before each store: a store's lazy `routerPage` adopted the last shot's demo model and the second v2 shot spun in a SwiftUI update loop (cause inside the loop not pinned down; `routerPage = RouterV2Demo.model ?? …` is worth a look in wave 3).
- Wave 3: `RouterSetupNotice` (in RouterView.swift) spans the page's width with Theme padding instead of the column's edges; move it out and align it. Playground's `openRouterWindow` still draws `RouterCodeView` (old brief shots).
- Flaky under the full suite's load only (pass alone): `RouterVerdictsTests.theStateComesBeforeTheWordsAndTheWordsGrow`, `RouterV2ReaderTests.notSureSonnetDecides…`, `RouterV2RenderTests.aHoverFromOneRowToAnotherRunsTwoLineBodies`.
- Not done: the live check on the owner's T3 (needs the owner's go).

## Live check follow-ups (LIVE-CHECK.md) — to do after the layout-perf agent lands (page files)
1. While verdicts are pending on a cold launch, the page says "Nothing needs you." and a needs-you thread sits in Done, then jumps. Fix: a finished thread whose verdict is pending shows as being read (logo + sheen) and doesn't count as settled-in-Done; the empty state never says "Nothing needs you" while any verdict is pending ("Reading 2 threads…"). Names cut at ~22 chars with a shimmer disc although the row has room: use the row's width.
2. Working lines show raw shell commands. Prefer the tool call's own description (Claude's Bash `description`) or the agent's latest sentence; a command only as last resort.
3. Pill said `lookout` (folder) vs T3 `fjord`: fixed in 10ab9eda.
4. Verdict/name wording changes between launches (fresh support folder, no cache) and one vague line; check the verdict file persists and loads before the first paint.
5. The three state tokens at the top right do nothing when pressed: they must filter by state (DESIGN 1.2).
6. Not yet seen live: a real turn end streaming a verdict and moving a line; PR states.


## Settings pills (2026-11-12)

Owner: free text never sets a new thread's settings. `@` lists models (T3 names, slugs, aliases), the model's efforts and access, `@plan`/`@build` in a Settings section; a pick is `RouterPointer.setting(RouterSetting)` (a pill, not sent: `RouterV2Mentions.plain` drops it); `RouterV2Model.launchPills` feeds `launch` (hand picks give way when a pill names the same field). The demo types it (`updateScriptedMention`, `pickScripted`, `RouterV2Dock.drawn`). Shots `v2-new-thread-pills`, `-mention`, `-mention-bare`, `-plan`. Known: in the script a mid-roll pill crossfade overlaps briefly.

## Activity on the line (subagents, background work, waits) — 03cbdbc7 328b03fa 4fe12355
- `RouterV2Activity.make(projection)` (RouterActivity.swift) → `RouterDetail.activity` → `RouterV2Thread.activity`; the records stamp a start T3 doesn't give (roster tasks) with the time Fjord first saw it. Subagent models come from the projection's `subagents[].model` (886 of 889 real records carry it; an agent type's name such as `judge` when started as a named agent).
- Views: `RouterV2ActivityViews.swift` (glyphs, peek, rows); the working card lists them. Shots `v2-activity`, `v2-activity-peek`, `v2-activity-card` (+ `-dark`); storyboard beat 19.
- **SEAM, not applied** (the layout-performance track owned RouterV2Line/Page while this landed). Until it is, the glyphs and their peek don't draw on the page (the card's list does). Two edits:
  - `RouterV2Line.swift`, `RouterV2LineView.row`: after `RouterV2SentenceView(model: model, box: box)` add `.routerV2Activity(model, thread)` (before `.padding(.leading, M.sentenceGap)`).
  - `RouterV2Page.swift`, `RouterV2Floating.body`: before the housekeeping peek add
    `if let id = model.activityPeeked, let thread = model.thread(id), let frame = frames[.activity(id)] { hung(from: frame, width: RouterV2.Peek.width) { RouterV2ActivityPeek(model: model, thread: thread) }.id("activity-" + id).transition(.scaleFade(0.98, reduce: reduce)) }`
    and after `.motion(.fade, value: model.peeked)` add `.motion(.fade, value: model.activityPeeked)`.
  - Checked with both applied: the three shots and beat 19's frames (`--from 19 --until 19 --frames`).
