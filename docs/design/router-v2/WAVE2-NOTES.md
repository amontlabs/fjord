# Wave 2 handoff notes (from wave 1, 2026-11-12)

## Track 6 (acts) — fb67f31d 03fb6530 dc30a294 b7f42605 36735c71
- `RouterActs.live(store:records:emit:)` is the real `RouterV2Source`; it sets `store.routerDispatcher.onSend` itself.
- 9a must wire: `reader` (track 5's reader), `decision` (track 5's latest decision, for the decision log), `models` (launch catalog), `emit`, and `records` (track 3's store must adopt `RouterActsRecords`: began/took/ended(send:), hide(_:on:), notForMe(_:on:), seen(_:)).
- History drawer's own Revert still goes through the old brief hold until 9a switches it to the records.
- Open: a refused settle/snooze can't toast its reason (no toast case in `RouterV2Change`; `.refused` ignored for lines with no `sent`) and the page's undo entry stays (⌘Z would unsettle a never-settled thread). Needs a port addition + model seam.
- Open: `RouterV2Thread` has no request id (picks read against the request held at Return); `start` has no mentions; a failed Stop is silent.
- `start(project:)` matches T3 projects by id, then title.
