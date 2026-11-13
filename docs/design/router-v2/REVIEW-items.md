# Review: open items engine (3741dbe1..HEAD)

Scope: `RouterItemLedgers`, `RouterItemsPrompt`, the records' wiring, `RouterVerdicts` items path, `Store+Router`
fetch, the page wiring, summary fixes. Read-only; `swift build` is green. The findings below are ranked by the
owner's promise first. Each was traced in the code; the ones marked *plausible* depend on T3's timing.

## 1. Lost reads, wrong closes (the core promise)

**1.1 A message from T3 or the phone is read with an older message's words, then marked read.**
`RouterItemLedgers.swift:65` and `:234` and `:278`. `l.facts` is kept from the last projection read and never cleared.
`message(at:)` falls back to "the latest message before `at`", so `has()` is true for a new message whenever any earlier
message is in the stale facts. No fetch happens.
Scenario: turn T ends and its facts are fetched; they include your earlier message M1. You then write M2 from the
phone. `observe` enqueues `msg:<M2>`, `has` matches M1 through the fallback, and the read gets M1's words with
`replyBefore` from M1. `msg:<M2>` is then marked read. M2 is never read, so items it answers stay open and items it
raises never land. The block also shows M1's words as "sent".
Fix: match only within the 2 s window, with no fallback. On a miss, fetch again (drop `l.facts` when an input is
enqueued, or key the facts by the input they were fetched for).

**1.2 A read that fails is marked read, so offline, usage limits and a missing binary drop inputs for good.**
`RouterItemLedgers.swift:317-326` (`.failed` → `markRead`), with `RouterVerdicts.swift:148` (6 attempts, 2+4+8+16+32 s,
about 1 min) and `:410-416` (no binary: `failed` at once, no retry).
Scenarios:
- The laptop is offline for 2 min. Every turn end and message in that window fails after its retries, is marked read,
  and is gone.
- Claude Code's own usage limit ends the call with an error result, not an HTTP 429. Every read fails until the reset.
- Claude Code is being updated and `binary()` is briefly nil. Every queued read fails instantly and is marked read.
Because `Saved.run` and `message` were already advanced in `observe`, nothing re-enqueues these inputs.
Fix: on `failed`, leave the input unread. Keep it at the head of a persisted pending list and try it again on the next
`moved`, reconnect or backoff wake. Only a well-formed answer marks a key read.

**1.3 Pending inputs live only in memory, while their triggers are persisted as already seen: a relaunch, archive or
settle loses them.**
`RouterItemLedgers.swift:182-197`. `observe` stores `s.run = run` and `s.message = at` before the input is read. The
queue and `reading` are in `Live`, which is in memory only.
Scenario A (wake): run A ends and B starts at once. The `turn:A` input is queued and `s.run = B` is saved. You quit, or
Fjord crashes, before A's read lands. On relaunch, `prev == run`, so A is never read. That is exactly the turn R7 was
built to keep.
Scenario B (message): you write in T3 while a read is under way. `s.message` is saved and the message input is queued.
You quit, and the message is never read. The same loss happens through `dropped()` (archive, then unarchive) and
`settled()` (`:432-447`), which cancel without re-enqueueing.
Fix: persist the queue (`Saved.pending: [Input]`, as keys plus `words`), or derive inputs from "seen but not in
`read`" on load.

**1.4 Head-of-line block: a queued turn whose facts can't be found freezes the thread's ledger for good.**
`RouterItemLedgers.swift:227` and `:253-257`, with `RouterItemFacts.kept = 8` at `:33` and `:38`.
A turn input whose run is not among the projection's last 8 non-queued runs never satisfies `has`.
`facts()` sets `factsFailed = key` and `pump` returns. `moved()` only clears the flag; the next fetch misses again.
Everything queued behind it is stuck: later turn ends and your messages are never read, and the block sheens
"checking" forever (`busy`).
Scenario: you snooze a working thread, or hide it, or turn the Router off. `reads` is false, so `s.run` stays at R.
The agent runs 9 or more background-wake turns. When the thread is back on the page, `turn:R` is enqueued
(`:185`), is outside the last 8 runs, and blocks the thread.
The turns between R and the latest are also never read, so items they raised are lost. The same freeze happens when
`fetch` answers nil (a T3 timeout during the launch burst): an idle Done thread whose row never changes again never has
its last turn read.
Fix: a turn absent from fresh facts is skipped and marked read, so it doesn't block. Better: read the runs since
`s.run` in order, capped. A nil fetch retries on a backoff, not only on `moved`.

**1.5 A send that T3 refuses is still read, so items close "answered" by words the agent never got. `sentAt` then
swallows your next real message.**
`RouterRecords.swift:356` and `:361` call `items.sent` in `began(send:)`, before T3 accepts. `ended(send:)`
(`:384-397`) doesn't tell the ledger. `RouterItemLedgers.swift:191-195` dedupes any later T3 stamp
`>= sentAt - 5 s`, and `sentAt` is only cleared by a stamp.
Scenario: you answer a Decide while offline. T3 refuses (`.refused`) and the page puts your words back. Meanwhile the
read closes the item "answered by you". The Decide is gone, though the agent never saw the answer.
An hour later you write to the thread from the phone. Its stamp is later than `sentAt - 5`, so it is treated as the
refused message and not read.
Fix: read sent words on `took(send:)` (T3 accepted), not on `began`. On `ended(send:)`, cancel the read if it is
queued or in flight, and clear `sentAt`. Also bound the dedupe to a window (`at <= sent + 60 s`).

**1.6 Revert after Settle loses every open item (the known case), and the input in flight with it.**
`RouterRecords.swift:482` runs `items.settled(id)` as soon as T3's row says settled. That comes a few hundred ms after
Settle, well inside the toast's Revert. `RouterItemLedgers.swift:432-442` wipes `items` and `line`, and cancels the
read without re-enqueueing it.
Revert unsettles in T3, and the ledger is empty. Items that needed you vanish with no trace.
Fix: on settle, move the items to `Saved.settledItems` and keep the cancelled input's key unread. If T3 unsettles the
row and no newer run started since the settle, restore them and re-enqueue the input. Drop the stash on the next turn
end or after the Revert window.

**1.7 A message is dropped when any turn is queued after it, though that turn doesn't carry your words.**
`RouterItemLedgers.swift:243-251`. The rule assumes the next turn was started by the message. It isn't, for a queued
send (`.queue`), a steer, or a message written while the current run was still going.
Scenario: a read is under way. You steer, or queue, "use option B" to answer a Decide. The current run then ends and
`turn:R` is queued behind your message. The message is dropped and marked read. R's `yourWords` is R's original
starter, not your words, so the Decide stays open even though you answered it.
Fix: drop the message only if the later turn's run has `userMessageId` equal to that message. That needs the facts, so
decide it after the fetch. Otherwise read it.

**1.8 Done, then a restated item, makes duplicates or a Done that doesn't stick.**
`RouterItemLedgers.swift:342-353`, with `:409-428`. A read's prompt is built before you press Done. If its answer
restates the item (`sameAs: i3`), the commit doesn't find `i3` and adds a new item `i5`. You get a banner, and the
item you closed is back under a new id.
If you then Revert the toast, `i3` is reinserted: `i3` and `i5` are duplicates.
Related: Done on a striking item (closed by a read) or on a found preview (`:476-480`, ids guessed as `i\(next)`)
hits `guard ... firstIndex` and is a no-op. The model still shows the strike and the toast, and the item comes back on
the next publish.
Fix: keep `l.done` ids as tombstones for the read under way. A `sameAs` pointing at a done id is dropped, or replaces
it on Revert. Give preview rows non-actionable ids, or disable Done on them.

**1.9 Revert of Done is a no-op after the thread's `Live` is reset.**
`RouterItemLedgers.swift:421`. `l.done` is in `Live`, which `settled` and `dropped` reset, and which a relaunch loses.
The model puts the item back (`RouterModel.swift:684-686`), then the next records publish removes it again. The item
is silently gone.
Fix: keep the Done stash in `Saved`, or restore from the toast's own copy, `was`.

**1.10 *(plausible)* A turn whose final message still says `streaming` is read as "no words" and marked read.**
`RouterItemLedgers.swift:39-44` and `:268-275`. `has()` checks only the run's status (`!live`). Both reply sources
skip streaming messages.
If the held projection (`Store+Router.swift:551`) has the run complete but its last assistant message not yet
finalized, `reply` is `""`. The turn is then marked read with no read.
Fix: treat "run ended but its last assistant message is still streaming" as not ready (fetch again), not as empty.

## 2. Ordering and races

**2.1 An earlier run's line streams as the current Done line.**
`RouterItemLedgers.swift:310-313` sends `.words` for any turn read. `RouterRecords.swift:101-108` stores it in
`e.itemWords`. `:513` clears it only when the latest run isn't being read.
Scenario: A ends and B starts. A is being read while B ends and is queued. A's words stream into `e.itemWords`, and
compose (`:851-853`) shows them as B's sentence. They stay after A's commit until B's read streams.
This is the same class of bug 7deac2c6 fixed for summaries.
Fix: tag `itemWords` with the run, and show them only when the run is the latest.

**2.2 Only the latest message and the latest two runs are seen per T3 event.**
`RouterItemLedgers.swift:185-195`. `lastAuthoredAt` and `latestRunID` are single values. Two phone messages in one
coalesced shell update, or any messages while `reads` is false (snoozed, hidden, Router off, `.older` scope), are one
input: the earlier ones are never read.
Fix: enumerate the user messages newer than `s.message` from the facts once fetched, one input each.

## 3. Cost

**3.1 The version 3 migration throws the whole file away: a launch burst of Sonnet reads, name calls and banners.**
`RouterRecords.swift:1316` and `:1324-1327`. On the first launch, every Done or Stopped thread on the page has
`ledger == nil` and enqueues `turn:<latest>` (`RouterItemLedgers.swift:182` and `:187`). Names and `told` are dropped
too, so every thread is also renamed (Haiku). Each turn read needs a projection read as well, on top of the card's.
The read-once promise means none of these repeat, but the first launch spends one Sonnet read per Done line plus one
name call per thread.
It also fires a banner per Decide/Do found. `RouterNotifier.step` (`RouterNotifier.swift:41-46`) has no freshness
or `unseen` gate, unlike `changed`.
Fix: decode version 2 and keep `name`, `nameKey`, `told` and `summaries`, dropping only `verdict` and `fingerprint`.
Seed a first-seen ledger with `read = [turn:<latest>]` (or read only turns that ended within `ThreadNotices.fresh`).
Gate item banners like `changed`: fresh and `unseen`, not for the card you're on.

**3.2 Two projection reads per turn end.**
`Store+Router.swift:546` and `:548-557`, `Store.swift:595`. The card's `readIfNeeded` and the items' fetch each call
`readSnapshot` for the same turn: T3 load is doubled, and two `make`s run on main. Share the snapshot: one read,
both consumers.

**3.3 A deterministic bad answer costs 6 Sonnet calls per input.**
`RouterVerdicts.swift:469-479`. A parse failure is retried like a network error. Retry a schema or parse failure once
at most; keep the backoff for transport errors (see 1.2).

## 4. Privacy
No findings. Prompt inputs are redacted and fenced (`RouterItemsPrompt`, tested). The usage log records tokens only.
The eval data stays in the git-ignored `evals/router/items/data/`, and the judge sees the app's redacted parts.

## 5. Main thread

**5.1 A one-item thread becomes a block for every read, so the red 30–60 ms commit runs twice per read.**
`RouterItems.swift:99` (`block` when `items.count == 1 && read != nil`) and `RouterItemLedgers.swift:484-490` (`read`
set whenever busy). Each turn end or message on a one-item thread turns the line into a block and back when the read
lands. That puts the commit `docs/performance.md` marks red on the everyday path, about 330 reads a day.
Fix: show the read's state on the single line (sheen, an inline "↑ sent" tail) without becoming a block. Or make the
block transition cheap before it is the common path.

**5.2 `RouterItemFacts.make` runs on main over the whole projection.**
`Store+Router.swift:552` (held projection, built synchronously in `fetchItems`) and `:568` (snapshot, in `done`).
It builds a dictionary of every message and sorts every message, then runs 8 × `last(where:)` over messages and over
`turnItems`. On a long thread (thousands of turn items) this is ms on main per input.
Fix: build it off the main actor (the snapshot is already async; take a `Sendable` copy of the held projection). Walk
from the end once.

## 6. Leftovers (owner rule: no legacy paths)
- `RouterActs.swift:272-273`: `notForMe` is a no-op on real threads. `RouterPort.swift:88-91` keeps it in the
  protocol, and `RouterModel+Acts.swift:206-232` still drives it. It is now demo-only. Delete it with the demo's step.
- `.needsYou(.step)` is still a state: `RouterTypes.swift:430`, `RouterCard.swift:66`, `:98` and `:267-282`
  ("Doesn't need me"), `ThreadNotices.swift:92-93`, and `RouterDemo.swift:141`, `:604` and `:730`. Real threads can't
  reach it. Move the demo to open items and remove the state, the button, the `RouterLineAction.notForMe` case
  (`RouterTypes.swift:490-493`) and its copy.
- `RouterVerdicts.swift:115-116` (`case .items: return nil`) and `RouterVerdictPrompt.swift:123` and `:132` (items in
  the verdict prompt's `system` and `schema`) are unreachable: items never go through `RouterVerdictReading` or
  `RouterVerdictPrompt`. Remove `.items` from those switches by giving them their own path.
- `ThreadNotices.step` and the `step:` key prefix, and `RouterNotifier`'s header, still say "the verdict found a step".
- Items reads open signposts named "Verdict state" and "Verdict done" (`RouterVerdicts.swift:274-277`), which mixes
  them into the verdict gates' timings.
