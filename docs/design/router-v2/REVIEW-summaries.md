# Review: working summaries, pinned activity marks, own queued runs (6700f207..HEAD)

Commits: 6700f207 (context), 2aaf1beb 92af3716 3a2bc1fb 8acf550c df7015d2 3a7373f0 16b83787. Read-only review, 2026-11-13.
Checked: `swift build`, `--window-shots v2-working` (10 shots, light and dark), `swift test --filter ThreadSenderTests`
(1 failure, below), `swift test --filter "RouterSummaries|RouterDetailTests"` (33 pass).

8 findings plus the failing test. No high-severity bug turned up. The cancel path, the coalesce/gap path and the dedupe all
hold: a late `.words`/`.done` is guarded on `summarizing && summaryPrint == fingerprint`, `stopSummary` runs on every
non-working, paused, hidden or off-page refresh, and the engine drops by key. Asks and verdicts sort ahead of summaries.
The pay-per-thread cost limit is `summaryAskedAt + 60 s`, and nothing re-arms it in a loop.

## 0. `ThreadSenderTests.theNewestQueuedRunIsTheOneACancelTakesBack`: the test is wrong

`Tests/FjordTests/ThreadSenderTests.swift:80`. Since 6700f207, `newestQueuedRun` reads `ownQueuedRuns`
(`T3Types.swift:710`), which keeps only runs whose message is in `p.messages` with `createdBy == "user"`. The test's
projection has runs `r2`/`r3` pointing at `m2`/`m3` but passes no `messages`, so both runs are filtered out and the result
is nil. That is the intended behaviour: an unknown author isn't yours to cancel.
**Fix:** seed `messages` for m2/m3 with `createdBy: "user"`. Also add an `m4` `createdBy: "agent"` queued run at
position 3, and expect `r3`, so the test pins the new rule.

## 1. A summary in flight lands stamped with the *new* run (medium, correctness)

`Sources/Fjord/RouterRecords.swift:683`: `.done` keeps `run: t.latestRunID`, the run current when the answer *lands*, not
the run it was asked for.
**Scenario:** run r1 is working and a summary is asked for r1's facts (Haiku takes about 4 s, longer when queued behind the
cap of 4). Meanwhile r1 ends and the queued run r2 starts in the same shell update, or a steer starts a new run. The code
state stays `.working`, so `stopSummary` never runs and the answer is accepted (the print still matches). The summary
about r1 is saved with `run = r2`. `summed` then shows it as r2's line, and line 630 hands it to r2's next call as
`last` ("keep its wording when the work hasn't moved on"), so r1's wording carries into r2.
**Fix:** keep the run asked for (`e.summaryRun`, or parse it from the print's last field) and stamp that run.
Alternatively, drop the answer when `t.latestRunID` moved, the way the verdict path stops calls on a new fingerprint.

## 2. The card lists earlier runs' summaries as if they were this run's (medium, correctness/design)

`RouterRecords.swift:760` puts *all* saved summaries into `r.work`, of any run. `RouterCard.swift:46` (`summarized`) and
`RouterWorkViews.swift:22` (`listed`) don't look at the run.
**Scenario:** a thread finishes r1 with 6 summaries and stays on the page as Done (`forget: false`, so its timeline is
kept). You send a follow-up and r2 starts working. Until r2's first summary lands, which can be a minute or longer:
`lineReadsNewest` is false (the newest isn't r2's), so the card hides the last lines (`summarized` is true) and lists r1's
summaries. Its newest gets the 6 pt `Text.secondary` mark and `Text.primary` words that R6 reserves for "a newest the line
doesn't read", meaning a summary streaming in now. The card presents a finished run's step as the current one. After r2's
first summary, r1's lines still follow in the timeline with no break, read as the same run's history.
**Fix:** filter `r.work.summaries` to `run == t.latestRunID`, or base `summarized` and the primary styling on the current
run, and forget a run's timeline when a new run starts. DESIGN.md R6 should say which one.

## 3. A new run with the same to-do step and no words yet never gets a summary (low, correctness)

`RouterRecords.swift:607`: the trigger is `saidID|step` with no run in it.
**Scenario:** a thread's to-do list shows step S running and r1 had no whole message, or its words carried over. r2
starts with S still running and the agent writes nothing for minutes, only tools. The trigger string is unchanged, so
`summaryDirty` stays false and nothing is asked. The line falls back to the code's line (`summed` needs
`newest.run == run`) until the agent writes or the step moves. Finding 1 can also hide this.
**Fix:** add `t.latestRunID` to the trigger. The print already has it, so the dedupe is unaffected.

## 4. `keep` merges same-text summaries across runs and keeps the old time (low)

`RouterRecords.swift:704`: when the new line reads the same as the newest, the newest's `print` and `run` are updated but
its `at` and `id` stay.
**Scenario:** r1's last summary at 13:20 is "Running the snapshot suite". r2 starts at 14:05 and its first summary says
the same. The timeline shows it at 13:20, and the line's newest now claims r2 with r1's timestamp.
**Fix:** merge only within one run (`newest.run == new.run`), otherwise insert.

## 5. Raw history goes to Opus unredacted in the eval judge (low, privacy)

`evals/router/summary/judge.py:29-33`: `facts()` sends `around` (up to 40 lines of agent words and **raw tool commands**,
from `export.py:118-126`) and `yourWords` straight to `claude -p --model opus`. They don't go through
`RouterTools.redacted` or the fence. Only `run.py` reads the app-built, redacted inputs from `SummaryEvalDump`. Commands
with tokens in env or args (`export X=…`, `curl -H "Authorization: …"`) reach the model as they are. Data stays in
gitignored `data/`, which is fine.
**Fix:** redact `around` and `yourWords` at export time with the app's rules, for example by having `SummaryEvalDump`
also write a redacted `around`, as the memory note on redacting transcripts before Jev asks.

## 6. The engine doesn't preempt for asks, and a summary's rate limit holds the whole queue (low, queue priority)

`RouterVerdicts.swift` `pump()`: priority applies only when picking from `queued`. A running summary keeps its slot.
**Scenario:** four working lines are due in the same few seconds (common right after `askingChanged()` or a launch,
since every working line is dirty at once). All 4 slots go to summaries, and a T3 permission ask waits for one to finish
(about 4 s p50, longer on retries). Separately, a summary call that hits the subscription's rate limit sets `held`, and
every ask and verdict waits for the limit's time. Summaries are the most frequent caller, so they are the likeliest to
trip it.
**Fix:** reserve a slot for asks/finished (summaries may use at most `cap - 1`), and/or put a summary that hits a rate
limit back without setting the global hold, or spread the first-wave summaries out (a random 0–60 s initial
`summaryDue` after launch/`askingChanged`).

## 7. `RouterDetail.work` can scan the whole run on every T3 event (low, perf, main actor)

`RouterDetail.swift:125`: the reversed loop breaks only when `said != nil && tools.count > 3`.
**Scenario:** a long run with no finished assistant message in it (a long tool-only stretch, or Codex runs whose words
are all still `streaming`). Every projection event (`Store+Router.swift:166`, on the main actor) walks every item of the
run, with `messages.first { … }` inside for empty texts. With thousands of items in a multi-hour run, that is O(n) per
event, on top of `working()`'s scan. It is cheap per call but sits on the T3-event path that docs/performance.md gates.
**Fix:** bound the walk, say to the last 200 items or the run's last N minutes, and treat no words found as `said = nil`.

## 8. The timeline clock is two-digit in 12-hour locales (nit, design)

`RouterWorkViews.swift:94`: `.hour(.twoDigits(amPM: .abbreviated))` gives "01:58 PM" in en_US. R6 and the comment say
"13:58". The shots render in a 24-hour locale, so they don't show it.
**Fix:** use `.hour(.defaultDigits(amPM: .abbreviated))`, or pin a 24-hour format if R6 means it.

## Shots

`v2-working-summary`, `-hover`, `-card`, `-writing` and `-card-steps` render as R6 describes in light and dark. The rail
stops clear of the marks, times sit in the ages column, the activity glyphs are pinned before the pill, and the working
peek is 400 pt with the activity rows under the steps. One note, by design (1.6) but worth knowing: the row-wide hover
peek hangs up from the name and covers the two or three lines above it, including Needs-you rows, whenever the pointer
crosses any working row (`RouterModel.swift:555`).
