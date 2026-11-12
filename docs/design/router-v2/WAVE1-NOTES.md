# Wave 1 handoff notes (from wave 0, 2026-11-12)

Seam (track 1, commits bf7264e0 cf15b0c9 73219846 0fa0a67a): `Sources/Fjord/RouterV2Port.swift` holds `RouterV2Change`,
`RouterV2Outgoing`, `RouterV2Source`. The model takes records only via `apply(_:)`. Demo store implements the same source.
T3 wire (track 2 w0, commits a6f039eb 6e892d06 0e76bec0 e7b688ac): shell `activityRunStartedAt`, `latestRunStopRequested`;
`AgentThread.latestRunID/runStartedAt/stopRequested`; `T3LaunchRequest.options` (`T3ModelOption.effort`), `ThreadLauncher.request(interactionMode:options:)`;
`T3Command.messageDispatch(continuationOf:)` → `manualContinuationOfRunId` (T3 allows it only after an interrupt or a usage limit);
`T3Command.pullRequestLink(threadId:url:)` (host/repository/number parsed by `T3PullRequestRef`); `T3Projection.checkpoints` → `T3Checkpoint` (per checkpoint sums).

Open items assigned to wave 1:
- Track 7: `.words(done:)` isn't used by the model yet; decide how `done` interacts with words that keep growing.
- Track 6: ⌘Z/Revert must mark History's `FjordChange` reverted (the page sends `on: false` / `until: nil`); pick the right runId for Continue.
- Track 5: `RouterLaunchCatalog` fills `RouterV2Change.launch` and `RouterV2Read.launch` from T3's server config.
- Track 2 (w1): `RouterDetail` sums a turn's checkpoints for the diff.
- Order: Sent and running share one order group (a run start doesn't move the line); keep it.
