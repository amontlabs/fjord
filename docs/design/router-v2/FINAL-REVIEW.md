# Router v2 · final review (2026-11-13)

Commits 36f90b83..871e8422, read-only. Checked by reading the code against DESIGN.md, the installed T3 (0.1.7 Beta,
`app.asar`) and the t3code checkout (`~/code/research/t3code`, 322f6544). Nothing was built, run or tested: every finding
is from the code, and each says how sure it is. No full test run, no live app.

22 findings: 2 P0, 8 P1, 8 P2, 4 P3.

## P0

### 1. A pick kept from an earlier request crashes the page, or pre-picks an option on a new request

`Sources/Fjord/RouterModel.swift:698-703` (`answerWords`), `:767-800` (`upsert`), `:813-822` (`removeLine`).

`picks`, `typed` and `formAt` are keyed by thread and cleared only by the owner's own send, Esc and "Doesn't need me".
A T3 change of the thread never clears them. `answerWords` then indexes `options[$0 - 1]` with no bounds check, and
`destination` calls it for the selected thread whenever the draft is empty.

- **Crash.** Pick option 2 on a question card (⇧2) and don't send. Answer it in T3 or on the phone instead (or the run
  is stopped, or T3 restarts). The line moves to Working with `options == []`; the selection moves on, the pick stays.
  Later, ↑↓ onto that line: `destination` → `answerWords` → `options[1]` on an empty array → index out of range.
- **Wrong answer.** Pick "Allow once" on a permission and don't send. That request is resolved elsewhere and the thread
  asks a second permission. Same state, same section, so the card stays open with "Allow once" already picked and the
  row showing it: Return allows a command the owner didn't pick for. With fewer options than the old pick it crashes
  instead.

Sure (the code path is direct).

Fix: carry the request's id on `RouterThread` (WAVE2-NOTES lists it as open) and drop `picks`/`typed`/`formAt` in
`upsert` when it changes or the state leaves that ask, and in `removeLine`. Bounds-check in `answerWords` as well.

### 2. A finished turn's verdict is asked without the agent's reply, and cached

`Sources/Fjord/RouterRecords.swift:477-499` (`askIfNeeded`, `input`), `Sources/Fjord/RouterVerdictPrompt.swift:44-50`,
`Sources/Fjord/Threads.swift:387-389` (`syncThreadDetail`), `Sources/Fjord/AgentThread.swift:115`.

The verdict's reply is `detail.reply`, else the shell's `latestVisibleMessage`. T3 0.1.7 always sends
`latestVisibleMessage: null` (FEASIBILITY.md says so; confirmed in the installed build), and a projection is held only
for threads that run or wait on a T3 request. So a finished thread with no projection held has no reply at all, and
`yourWords` is nil too. The verdict is made from the title and the PR list, saved under the fingerprint in
`router-verdicts.json`, and never asked again.

- Cold launch, a thread finished while Fjord was closed, its reply ending "Want me to merge it?". Verdict: `done`,
  quiet. It sits in Done; the owner is never told it waits on them. The file keeps that verdict across launches.
- Already visible in the live check: a completed thread's line read "no reply or result shown yet" (LIVE-CHECK.md
  problem 4 read it as vague wording).
- The same gap empties the cards: `lastLines`, `diff` and `stop.lastStep` come from the detail, so after a launch a
  Done, Stopped or "left you a step" card shows its title and nothing of what the agent said (`RouterRecords.swift:532-540`).
- Asks have the same race: the `.ask` verdict goes out on the shell row, before the projection that carries the
  request has arrived (certain on a cold launch). The prompt says "the request listed under It waits on you" and none
  is listed; the line it writes replaces T3's own verbatim question and is cached for that request.
- EVAL-verdicts.md scored turns that had their reply, so its 3 % does not describe this path.

Sure about the mechanism; how often a thread that finishes while Fjord runs has its whole reply at the shell event
depends on T3's ordering of the two streams, which I didn't measure.

Fix: read the thread once when it needs a verdict and has no projection (`T3Store.readProjection`, as FEASIBILITY.md
planned: "a Done thread: one read at its turn end"), ask only once the reply (or the request) is in the input, and
hold the selected line's projection while its card is open. Throw away the verdicts saved so far (a version in the file).

## P1

### 3. "Fjord answers here": Return empties the composer and nothing happens

`Sources/Fjord/RouterReader.swift:246`, `Sources/Fjord/RouterModel+Draft.swift:363-391` (`deliver`, `case .here: break`).

When the decider's kind is `.answer`, the read is `[.here]`, sure. The row says "Fjord answers here". Return calls
`deliver`, which empties the draft first and then does nothing for `.here`. A held Return does the same when the read
lands. The words are gone, with no answer and no failure line. Sure.

Fix: send it through the dispatcher with no target (the Router's own answer) and show the answer, or don't offer the
place until it has somewhere to go; never clear the draft for a place that sends nothing.

### 4. A verdict call that fails once is never asked again

`Sources/Fjord/RouterRecords.swift:236-241, 484`, `Sources/Fjord/RouterVerdicts.swift:266, 380, 408-413`.

`failed` holds until the fingerprint moves or the app restarts. Every cause is covered by it: the 60 s timeout, the
network, Claude's usage limit, a 429. On a 429 the call that hit it is told `.failed`; the queue is then released by
the very next ask, so the queued calls all run into the same limit and fail too.

- The owner hits the Claude usage limit at 15:00. Codex threads that finish before the reset all read "finished",
  quiet Done, for the rest of the session, including the one that left a step.

Sure.

Fix: keep failed calls asked (the line stays "being read"), retry on the rate limit's own time or on the next T3
event, and put the 429'd job back in the queue instead of failing it.

### 5. Settle and Snooze on a question or permission card are always refused by T3

`Sources/Fjord/RouterCard.swift:251-254`, `Sources/Fjord/RouterModel+Acts.swift:96-110, 203-206`,
T3 `Orchestrator.ts:3326-3361` (settle) and `:3472-3513` (snooze).

T3 refuses `thread.settle` while a blocking request is pending, a run is live or a message is queued, and
`thread.snooze` with a pending request or a queued run. The installed 0.1.7 has the same texts. The card offers both
on every Needs-you card, and ⌘⌫ settles any selected line, Working and Sent included.

- ⌘⌫ on a question the owner doesn't care about: the line folds away, comes back, and the toast reads "T3 refused it
  for Updater · Thread 3f2a…-… is waiting on an approval or question. Answer it before settling." (T3's raw cause,
  with the thread's UUID).

Sure. This is a design gap as much as a bug: DESIGN 2.1 lists Settle and Snooze as ways out of a T3 ask.

Fix (owner's call): either the act answers the request first (Cancel, then settle), or the card doesn't offer what T3
won't take and ⌘⌫ does nothing there. Either way, say the reason in Fjord's words, without the id.

### 6. A settled thread that Fjord still counts as live stays hidden for the whole session

`Sources/Fjord/RouterRecords.swift:332-338, 461` (`hidden` ends only when `inPlay != hidden`).

`inPlay` is `!settled || running || waitsForYou`, and Fjord's `running` includes background tasks after the turn
ended, which T3 does not count when it accepts a settle. So T3 settles it, `inPlay` stays true, and `hidden` never
clears.

- A Working line reads "background: 2 running" (the turn is over, subagents still go). ⌘⌫: T3 accepts. The subagents
  end, T3 wakes the thread, it runs again and asks a permission. `inPlay` was true throughout, so the thread has no
  line, no badge and no banner (`refresh` skips the notifier for hidden threads) until Fjord is relaunched.
- The reverse for a plan: Settle on a plan card is accepted (a plan is no runtime request), hidden this session, and
  back in Needs you after a relaunch, since `waitsForYou` still holds for a settled thread with a plan.

Fairly sure; the wake after background work is from T3's `automaticQueuedRuns` path, not seen live.

Fix: end `hidden` on T3's word about the act itself (`settledAt` set or cleared, `snoozedUntil`), and drop it when the
fingerprint moves (a new run or request after the settle).

### 7. Cancel on a queued row can leave the message queued, and the records are never told

`Sources/Fjord/RouterActs.swift:167-170`, `Sources/Fjord/RouterRecords.swift:321-329` (never called),
`Sources/Fjord/ThreadSender.swift:176`.

`cancelQueued` cancels `projections[id].queuedRuns.last`. When T3 hasn't listed the queued run yet it returns without
doing anything; the dispatch's failure is dropped (`try?`); and `records.cancelledQueue` has no caller, so `e.queued`
stays and the next record puts the queued row back.

- ⌥Return on a working thread, then Cancel within a moment: the words are back in the composer, the queued message
  still goes at the turn's end, and the edited resend makes two.
- `.last` is the newest queued run of any kind. If T3 has queued a subagent's completion after the owner's words, that
  is the run cancelled.

Sure about the first; the second depends on T3 queueing automatic runs behind a live turn.

Fix: cancel the run whose `userMessageId` carries these words, wait for it when it isn't listed yet, call
`records.cancelledQueue`, and put a failure line when T3 refuses.

### 8. A new thread the decider picks is named by T3's project id

`Sources/Fjord/RouterReader.swift:248-252`, `Sources/Fjord/Store+Router.swift:81-85`,
`Sources/Fjord/RouterModel.swift:450`, `Sources/Fjord/RouterModel+Draft.swift:280-284, 381`.

The decision's place is `.newThread(project: board.projectID(name))`, T3's id. It reaches the page unchanged. Only the
`@` pill path maps ids to names (`RouteTarget.projectName`).

- The row reads "new thread in <project id>"; the places menu lists that and "new thread in fjord" as two places; the
  Sent line's pill and a new filter pill show the id until T3 lists the thread.

The start itself works (`projectID` matches ids first). Fairly sure: the tests use ids such as `p1`, and the live check
sent nothing, so this was never seen.

Fix: map the id to the page's project name in `Store+Router.swift` `reader.onRead`, as the pills do.

### 9. The open card never reaches the decider

`Sources/Fjord/Store+Router.swift:73-75` (`selected` dropped), `Sources/Fjord/DeciderContextSource.swift:55-57`
(`Inputs.open` never set).

5ac956c3 built "the decider sees the open card as a prior" and nothing passes it. The reader's cache key includes the
selection, so the call is repeated per card, but the answer is the same.

- A question card is open; the owner types "yes, the second one". The row first shows that card (the prior), then the
  read lands for whatever the board suggests: another thread, or "pick a place". A Return held meanwhile is not sent.

Sure about the wiring. EVAL-decider.md:45 measured the prior on 80 moments, so the eval's numbers with it are not what
the app does.

Fix: pass `selected` through `decideDraft` to `deciderContext` and set `Inputs.open`.

### 10. A line stays Sent forever when T3 takes the message and no run starts

`Sources/Fjord/RouterRecords.swift:446-456`.

A send to an idle thread ends only on a new run id, a new run start, or its request or plan going. If the provider
session fails before T3 makes a run, the row goes to failed with the same run id: the line keeps "Sent" at the top of
Working, the failure is never shown and no verdict is asked.

Plausible, not verified against T3's start-failure path.

Fix: also end the send when the row's status, `lastError` or `latestRunCompletedAt` moves after `send.at`.

## P2

### 11. A detail goes stale when its subscription closes

`Sources/Fjord/T3Store.swift:295-306` (`closeThread` tells nobody), `Sources/Fjord/Threads.swift:359-362, 387-389`.

The records hear the shell first, then `syncThreadDetail` closes the thread's stream in the same turn, and
`onThread` isn't called, so the records keep the last projection. Whatever arrives after the shell's "completed" is
lost: the turn's last checkpoint (the Done card's "4 files +96 −212"), and `writing` can stay true, a caret after the
last lines of a finished thread. Fixed by the read in finding 2 if that read replaces the detail.

### 12. The demo's models and defaults are the real page's until T3's config lands

`Sources/Fjord/RouterModel.swift:172-173`, `Sources/Fjord/RouterLaunch.swift:104-107`,
`Sources/Fjord/RouterLaunchCatalog.swift:107-119`.

`launchModels = RouterLaunch.demoModels` and `launchDefault = t3Default` (`claude-opus-5-5`, high, auto) in the real
model. If `server.getConfig` fails or lists no model, the chips and the `@` list offer four demo models, and a new
thread is sent with the hard-coded id. A fallback in the live path (owner rule: none).

Fix: no chips and no settings sent until `.launch` lands; the launcher then uses T3's own defaults.

### 13. Revert puts back the record as it was at the act, and ⌘Z reaches every act of the session

`Sources/Fjord/RouterModel+Acts.swift:31-38, 59-62, 134-145`, `Sources/Fjord/RouterKeys.swift:117-122`.

`undos` is never trimmed, and with an empty draft ⌘Z takes its last entry before the text's undo is asked. The revert
appends the saved `RouterThread`. When the records no longer give that thread a line (it passed 24 h, was archived),
they emit nothing, and the page keeps a line the store doesn't know: shown twice (also under "finished earlier") or
for a thread that is gone.

Fix: revert through the records only (the line returns when their record does), and keep ⌘Z to the act whose toast is
still up, or to the window's `UndoManager` order alone.

### 14. A second message to a thread just sent to goes as a steer and its Sent state ends at once

`Sources/Fjord/RouterModel+Draft.swift:373, 403, 419`, `Sources/Fjord/RouterRecords.swift:450-452`.

`isRunning` is true for Sent, so the second send is `steering`. The records end a steer when `!t.running`, which is
the case before the first run has started: the line drops back to Done with its old verdict, then to Working.

Fix: steer only when the thread's code state is working.

### 15. A refusal that arrives after the record moved is dropped

`Sources/Fjord/RouterModel.swift:855-856`. `sendRefused` needs `t.sent`. If a shell event ended the pending send
first (the request went at the same moment), there is no failure line and the words are lost without a word.

Fix: keep the words with the pending send in the model and always show the failure line.

### 16. The first character typed with no field focused is dropped when it needs ⌥ or a dead key

`Sources/Fjord/RouterKeys.swift:36, 249-253`. Only bare and ⇧ keys are passed to the composer. On AZERTY that leaves
out `{ [ | \ ~`, `@` where it is ⌥à (DESIGN 5.1 says it is), and ^ ¨ (`être` arrives as `etre`).

Fix: pass any key whose `event.characters` is printable and has no ⌘ or ⌃, and give dead keys to the field by
focusing it first.

### 17. Every selection tells T3 the thread was visited

`Sources/Fjord/RouterModel.swift:537-541`. `select` sends `thread.visit` for each line the arrows pass, new or not:
ten ↓ are ten commands and ten shell events, and threads only walked past are marked read on T3's sidebar and phone.

Fix: visit only when the line is new, and for a walk, at the next key that isn't an arrow (as `pendingSeen` does).

### 18. The typing log is not wired

`Sources/Fjord/RouterReader.swift:27`, `Sources/Fjord/Store+Router.swift:70-87`. `reader.log` is never set, so the
pause, start, skip and cancel lines that EVAL-decider.md says the 300/600 ms pauses are to be tuned from are never
written.

## P3: privacy and leftovers

### 19. Real thread names and lines are committed (not pushed yet)

`docs/design/router-v2/live-check/*.png` (11 window captures of the owner's real page) and `LIVE-CHECK.md` name real
threads, projects and verdict lines. `main` is 101 commits ahead of `origin/main`, so they can still be taken out of
the history before the push. The eval files added in the range are synthetic (`launch_drafts.py`) or code, with no
transcript text. `EVAL-verdicts.md:43` describes a few real misses by case id in a clause each; worth a read before a
push.

### 20. Untracked files that a `git add -A` would commit

`evals/router/w2/out/` and `test.log` are untracked and not ignored (`evals/router/.gitignore` covers `data/`,
`runs/`, `explore/*/out/`, not `w2/out/`). Add both.

### 21. The old "no model picker" rule is still written down

`Sources/Fjord/ThreadLauncher.swift:6` ("Fjord has no model picker, so the model is T3's own default") and
`docs/design/t3-code-map.md:12, 98, 121`. DESIGN 1.9.1 replaced it for new threads on 2026-11-12.

### 22. Dead code and names from the deleted brief

- Never called: `RouterRecords.cancelledQueue` and `Entry.cancelled` (`RouterRecords.swift:321-329, 416, 943`; see 7),
  `RouterVerdicts.isAsked` (`RouterVerdicts.swift:276-281`), `DeciderContext.Inputs.open` (see 9).
- Never filled: `RouterVerdictInput.firstAsk`, `files`, `diff` (`RouterVerdictPrompt.swift:28, 37-39`); the name rule
  still says "from its title and first ask".
- Brief names on live types: `BriefTarget`, `BriefAction` (`ThreadActs.swift:9`, its `before` reads "Needs you" for the
  deleted panel), `Store.routerNoticePrefix = "brief:"` (`Store+Router.swift:179`), `Router.space = "router-v2"`
  (`RouterTypes.swift:14`).

## Checked and found right

- Keyboard map against DESIGN 5: ⇧digits by key position, bare digit-row keys type, ⌘1–3 by position and never the Go
  menu's with a draft, Return and ⌘⌫ ignore repeats, Return never settles, ⇧Return and ⌥Return, Esc's order (5.3),
  filter mode's keys.
- Settings pills: a pill is taken out of the message with its space (`RouterMentions.plain`), sets its chip, beats an
  earlier hand pick and loses to a later one; on an existing thread it is dropped and sets nothing; free text sets
  nothing (the decider's `launch` fields are gone).
- Verdict lifecycle apart from 2 and 4: one call per fingerprint, cancelled when a run starts or your words are on
  their way, late answers dropped by fingerprint, Router off gives plain Done and asks when it comes on, the file is
  read before the first record and flushed on quit.
- A refused send puts the line and its picks back with a failure line; a refused settle or snooze drops its Revert.
- Logs: the typing log and the usage log carry counts, not text.

## Not checked

The views' layout and motion (the perf agent is in those files), the History drawer, the bar's Router panel, the
dispatcher's own send path beyond its seam with the page, and anything live.
