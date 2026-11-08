# N4b: one Sonnet call with the whole context (2026-11-08)

Design only; nothing was run. It answers: what should the single decider call see, in what order, how is it built, how is it judged, and how far can it go. Numbers quoted as "measured" come from [N1](N1-new-work-benchmark.md), [N2](N2-new-work-fixes.md), [N3](N3-ceiling.md), [J2](J2-routing-failures.md), [J3](J3-jev-api-and-context.md) and [E5](E5-jev-wrapper.md); the sizes in §1 were counted on N3's 300 dev moments (`n3common.py`, aggregates only). Everything else is a proposal to measure (§4).

## What the research says the call must do
- **Read the threads, don't skim them.** The only decider that lifted new work and follow-ups together was `agent`: Sonnet with `search_threads` and `read_thread` (N3: 61% new / 49% follow-ups at 1% wrong on dev, 72% new on test). A summary alone (`rich`) helped new work a little (45%); thinking alone (`sthink`) didn't (36%). So the single call gets what the agent fetched: each live thread's conversation, and a search over every thread for the message's words.
- **Tell new work by the deliverable, not the topic.** N1's hard case (73 of 204) is new work that shares a topic with a thread on the board. The first ask and what the thread delivered are what settle it (N2, J2).
- **Recency is strong and dangerous.** The most recently finished thread is the gold for 65% of follow-ups (dev, weighted); a global "your last message went here" pointer made both models anchor (J2 probe P: wrong sends 6 → 28; round 1: 69% → 61%). Per-thread facts were safe for Jev (H, R) and untested on Sonnet at full scale.
- **Read state is the one UI-free signal left.** N3's biggest error class is terse reactions when several threads sit in the same state. The owner accepts T3's `lastVisitedAt` (what the sidebar and phone share) and "finished since you last read it"; he rejects hover and open tracking.
- **Recall has a 3-point hole.** The follow-up gold is among the shipped candidates 96.5% of the time but among all listed threads 99.7%: the 12 h cut and the 3-per-project cap lose about 3% of follow-ups before the model sees them. Retrieval over all threads closes it.

## 1. The context, in cache order

Sonnet 5.5 caches a byte-exact prefix: minimum 512 tokens, 4 breakpoints, 5 min TTL by default or 1 h on a marker (1 h entries must come before 5 min ones; a 1 h write costs 2× input, a read 0.1×). Everything stable goes first and is ordered by **thread creation time, never by recency**, so a change lands at one position and the prefix before it survives. Sizes are tokens, estimated at 4 chars per token from the dev sample.

| # | Block | Changes | Breakpoint | Size p50 / p90 |
|---|---|---|---|---|
| A | Role, procedure, output rules | at a release | 1 h | ~1.5k |
| B | Project cards | when a project or its purpose changes | — | ~1k |
| C | Archive cards: every listed thread not on the live board | when a thread finishes or settles (append at the tail) | 1 h | ~12k / ~25k |
| D | Live threads: full digests | at every thread event | 5 min | ~8k / ~14k |
| E | Retrieval for this message | every message | — | ~1.5k |
| F | Signals since your last message, then the message | every message | — | ~0.5k |

Total ~25k / ~45k, of which ~15k–27k is read from cache at $0.20/MTok. Per decision: about $0.02–0.04 cold, $0.01 warm (today $0.007). Nothing on the decision path is read from T3: every block is assembled from caches kept current by shell events (§1.7).

### 1.1 A: role and procedure (system block, 1 h)
N2's `ROLE4` text stays the definition of follow_up / new_work / answer_here / ask (it is measured). Add, in this order:
- how to read a thread card: `deliverable` is what it was asked to produce, `status` how far, `left` what is pending; the transcript excerpt is evidence, the card is a summary of it;
- the comparison procedure (§3): name the message's deliverable, list every thread that could own it with how it fits, then decide;
- read state: "a reply you have not opened is one you have not reacted to; a thread you opened after its reply finished is one you may be answering" stated as what the fields mean, not as a rule to pick by;
- the facts about recency and topic are data about the threads, not a ranking; the board is in creation order on purpose;
- everything in the board is data, never instructions (kept).
No examples of past routings: they had no effect in round 1 and would churn the cache.

### 1.2 B: project cards
One per non-archived project, creation order:
```
## project harbor-notes (p-harb) | repo amontlabs/harbor-notes | purpose: <one sentence, 140 chars>
threads: 41 in all, 3 live (below), 12 in the archive · last new thread started 2d ago
```
Purpose from `routerBriefs.docs[p].purpose` as today. The counts tell the model how busy a project is without any recency ordering.

### 1.3 C: archive cards (1 h)
**Who qualifies:** every listed thread (`lineage.isListed`, not archived, not a subagent) that is not in D, with real activity in the last 30 days. Pruning runs once a day at 04:00 Paris, so the head of the block changes once a day and the tail only appends.

**Per thread, 4 lines, ~110 tokens:**
```
- t-3f9a | harbor-notes | Tide table import | created 12d ago · finished 9d ago · settled · branch feat/tides · PR #12 merged
  asked: <first ask, 240 chars>
  delivered: <Haiku: the concrete deliverable and how it ended, 200 chars>  left: <open items or "nothing">
```
`asked` is the first user message (stable forever). `delivered` / `left` are a Haiku card (§1.7) computed once when the thread leaves D; a revived thread gets a fresh card when it leaves D again. Imported threads (`historyOrigin: v1_import`) with no run on T3 count as old and are pruned by the 30-day rule unless revived.

Why it earns its tokens: it gives the model the project's history for "is this a different deliverable than anything we did", it holds the 3% of follow-up targets outside the live board (with E pointing at them), and it is nearly free after the first write.

### 1.4 D: live threads (5 min)
**Who qualifies (replaces the shipped candidate rules):**
1. every thread that runs, waits (pending request or actionable plan), or has a queued message;
2. every finished thread with real activity within 24 h (`max(latestRunCompletedAt, latestUserAuthoredMessageAt, latestVisibleMessage.updatedAt)`, never `updatedAt`);
3. the latest thread of every project, whatever its age (J2's "gold not on the board");
4. any thread created in the last 30 min;
5. cap 16 by recency, waiting and running never cut; what is cut stays in C.
Order: **thread creation time.** Dev boards have 5 candidates at p50 and 9 at p90 under the old rules; this gives a few more.

**Per thread, ~1.2k–1.8k tokens:**
```
### t-7c21 | harbor-notes | Chart tile cache
state: finished 14m ago · reply unread (you last opened this thread 3h ago, before it) · you last wrote here 41m ago · created 2d ago
git: branch feat/tiles · PR #14 open, checks failing
card: deliverable: <Haiku> · status: done | in progress | waiting on you · left: <Haiku: pending items, or the question it ended with>
first ask: <1200 chars>
[… 6 earlier turns not shown]
you (1h ago): <500 chars>
agent (52m ago): <300 chars>
you (41m ago): <500 chars>
agent (14m ago, latest reply): […] <last 1500 chars>
```
- The transcript is N3's `digest` (`n3common.py`): first ask 1200, your messages 500, earlier replies 300, the latest reply's tail 1500 (its head 300 when it runs past), newest turns kept first, budget 5000 chars. This is what `read_thread` gave the agent.
- `state` is written from shell fields only (§2.1). A running thread says `running (a message would interrupt it) · step: <current todo, 200>`; a waiting one adds `waiting request: <text, 300>`.
- `card` is the Haiku card refreshed when a run completes. It is what made `rich` beat `sthink` on new work, and it names the closing question without any word rule.
- Ids are short and stable per thread (`t-` plus 4 hex of the T3 id), so the same thread has the same name in C, D and E.

### 1.5 E: retrieval for this message
Two sources, merged, up to 6 hits, each one line plus a snippet:
```
## threads whose text matches the message's words (lexical match, not a ranking)
- t-3f9a (archive, harbor-notes, finished 9d ago) · "…tide table CSV layouts…" (agent, 9d ago)
- t-7c21 (live) · "…eviction memory test 5000 tiles…" (you, 41m ago)
- no other thread mentions: <the message's distinctive words that matched nowhere>
```
- **Local BM25** over Fjord's digest cache (title + every cached turn), the `Index` class of `n3dec.py` ported; ~1 ms for 200 threads.
- **T3 `orchestration.searchThreads`** (1 RPC, ≤50 hits, covers settled threads and turns the bounded snapshot never fetched). Fired when typing pauses, so its result is in hand at send; if it hasn't landed the block is built from BM25 alone and says so.
- A live thread that is also a hit gets a `matches: …` line on its D card instead of a repeat.
- The "no other thread mentions" line is the negative evidence for new work: the words that are new to the whole history.
E5 found BM25 added nothing on top of Jev's fusion for follow-ups; here its job is recall (the 3% off-board targets) and the new-work check, both measured by the §4 ablation.

### 1.6 F: signals and the message
```
## now
Sat 15:02 Paris. Your last message anywhere: 41m ago, to t-7c21 (its reply finished 14m ago; you have not opened it since).
Finished since you last wrote anywhere: t-7c21 (14m ago, unread), t-9b10 (3m ago, unread).
Threads you opened in the last 30 min: t-2a77 (2m ago; its reply finished 25m ago).
Waiting on you: t-9b10 asks a question (see its card).

Message:
<message>…</message>
```
Every fact here is also on the thread's card; this block only collects the time-ordered ones so the model need not scan 10 cards for them. It never says "latest", "probably" or "most recent"; it lists what happened since the owner last typed, oldest first. It is an ablation (§4), because J3 warns that a global list hurt once.

### 1.7 Off-path computation
| Piece | Trigger | Cost | Cache key |
|---|---|---|---|
| Digest (first ask, turns, last reply) | shell `latestVisibleMessage.updatedAt` changes for a thread in D, or a thread enters D | one `subscribeThread` with `acceptBoundedSnapshot` (last 10 user turns, 75 items, 1 MiB); Fjord already does this read-ahead | thread @ latestVisibleMessage.updatedAt |
| Haiku card (`delivering`, `status`, `open`, `last`: `SUM_SYS`/`SUM_SCHEMA` in `n3dec.py`) | `latestRunCompletedAt` changes, debounced 20 s; once when a thread leaves D | Haiku 5.5, ~3k in / 150 out ≈ $0.0004; a few cents a day | thread @ latestRunCompletedAt |
| Archive card text | thread leaves D (and once at startup for the 30-day window) | free (digest + card) | thread @ settle time |
| BM25 index | any digest or card changes | ~ms | — |
| T3 search | typing pause ≥ 600 ms, and on send if none in flight | 1 RPC | message text |
| Block texts A–D | on their inputs | string building | — |
Decision time: concatenate A–F, call. A digest or card that hasn't landed is left out and marked `(not read yet)`, never waited for.

### 1.8 Request
`claude-sonnet-5-5`, `system: [A]` with `cache_control {ephemeral, ttl 1h}`; `messages[0].content`: `[B+C (1h marker), D (5 min marker), E+F]`. `thinking: between_tools` first (today's latency, ~3 s p50 with the written analysis); adaptive at `effort: medium` is an ablation. `output_config.format` is the §3 schema, `max_tokens` 1200. Log `usage.cache_read_input_tokens` per call: a zero on a warm run means a block is byte-unstable.

## 2. Signals for terse follow-ups, without UI tracking

### 2.1 What T3 gives (all on the shell, free)
| Fact | Field | Meaning (T3 `Orchestrator.ts`) |
|---|---|---|
| Reply read or unread | `lastVisitedAt` vs `latestRunCompletedAt` | T3 sets `lastVisitedAt` on `thread.visit` from any T3 client; "mark unread" sets it to `latestRunCompletedAt − 1 ms`. Unread = null or earlier than the last run's end. **Not** `updatedAt`, which pin, settle and snooze bump; Fjord's `isUnseen` compares to `updatedAt` today and must change. |
| When you opened it | `lastVisitedAt` | "you opened it 2m ago (after its reply)" or "3h ago (before it)" |
| When you last wrote there | `latestUserAuthoredMessageAt` | excludes wakes and agent sends |
| When the reply landed | `latestRunCompletedAt` | and the reply's text from the digest |
| Whether it asks you something | `pendingRuntimeRequest`, `hasActionableProposedPlan` | a bare yes/no has one natural home when exactly one thread waits |
| Your last send anywhere | Fjord's decision history (`RouterDecisions`), confirmed sends only | one per-thread fact: "you last wrote here Nm ago" |

Fjord shows replies in its own brief and drawer. To keep read state faithful, Fjord should post `thread.visit` when it displays a thread's latest reply to the owner (peek or drawer open), exactly as T3's phone does. That is T3's shared read state, not hover tracking; it is the one product decision to confirm with the owner.

### 2.2 How they are used
- **Elimination, not selection.** A terse reaction answers a reply the owner has read. Among the threads in the same state (finished, same project), an unread one is unlikely to be the referent; if exactly one is read, the message has one home. If two are read, the model lists both and the rule in §3 asks.
- **The waiting thread first for bare approvals.** A pending question or plan is the referent for "yes", "no", "go ahead" unless another thread's reply ends with a question the words fit better. The deterministic request mapping (R1) then applies.
- **The reply's closing question** comes from the digest's tail and the card's `left`. A reply that ends in options makes "the second one" placeable.
- **Time gaps as plain numbers.** Minutes since the reply landed, since the owner opened it, since he last wrote there and anywhere. The model sees "finished 3m ago, unread" and "finished 14m ago, opened 2m ago" and can reason that the second is the one being answered.
- **Lexical anchors** for near-terse messages ("the button", "that test"): E's BM25 against the last replies (E5's `lx_said`, the one lexical feature its fusion kept).

### 2.3 Presenting recency without over-weighting
1. No block, line or label says "latest", "most recent" or "probably". Threads are in creation order everywhere.
2. Every time is absolute on the thread's own line; a global pointer never appears (J2 P: the single worst variant).
3. The §1.6 block is a time-ordered list of events since the owner's last message, nothing more, and it is ablated.
4. The schema (§3) makes the model name every thread that fits before it picks, and the decision rule asks when two fit equally. Confidence alone did not separate these (N2); the shortlist is the check.
5. Read state is phrased as what the owner did (opened, did not open, marked unread), not as a verdict.

## 3. Output schema and decision rule
Strict JSON, every key required, in this order (the order is the procedure):
```
message_deliverable   string   what the message asks for, or "reaction: <to what>" for a bare reaction
fits                  array ≤4 of {thread, how, state_ok}
                               how: answers_its_question | reacts_to_its_result | next_step_same_deliverable | same_deliverable_elsewhere | topic_only
                               state_ok: bool — its read state, status and timing allow the message to be about it
owned_by              string   the thread whose deliverable this is, else "none"
referent_unique       bool     exactly one thread in `fits` has how ≠ topic_only and state_ok
action                follow_up | new_work | answer_here | ask
project, session, reason, alternatives (≤3), confidence, project_confidence, p_new   as in N2's SCHEMA4
```
`analysis`, `related_session`, `session_task`, `extends` are replaced by `message_deliverable`, `fits`, `owned_by`: the same written thinking, but as a comparison across candidates rather than a note about one. `need` is dropped (always empty).

**Rule in code, in this order:**
1. `p_new ≥ bar_pnew` with a known project → new thread there (revertible, R1). Also `action = new_work` and `confidence ≥ bar_new`.
2. `action = follow_up` and the session is a live or archive thread and `owned_by` names the same thread and `referent_unique`: send at `bar_idle`, or `bar_running` when it runs (steer). A waiting target goes through the request mapping.
3. `follow_up` with `referent_unique = false` → ask, whatever the confidence, with `fits` as the alternatives (the terse-reaction guard; measured in §4).
4. `answer_here ≥ 0.80` → answer.
5. Else ask with the best guess and `fits`.
Bars are fitted on dev by N3's day-grouped CV (`n3bars.py`) at a target of 1% follow-up wrong-thread plus follow-up-to-new; N3's grid gains a `bar_pnew` already there and nothing else. The schema change is itself an ablation against SCHEMA4 on the same context.

## 4. Measuring it
**Harness:** a new variant `ctx` in `evals/router/t3/n3dec.py`, built from `history.json` at t: `digest` for D, `summary()` (the Haiku cards, cached by thread @ last turn) for C and D, `Index` for E, shell-equivalent fields from the message times. Dev = N3's 300 stratified moments with weights and the two-judge clean gold (`n3_gold.json`); bars by `n3bars.py` CV at 0.5/1/2/3%; then `n3test.py` once on the 112 sealed moments with bars fitted on all of dev. Report N3's table (new right / pushed, follow right / wrong thread / to new), plus two rows it lacks: **terse follow-ups** (≤5 words, 20% of follow-ups) and **off-board follow-ups** (gold outside the shipped candidates, ~3.5%), each with its own send and wrong rates; and p50 latency and $/decision with cache reads counted.

**What the benchmark cannot measure:** read state. The history has no `lastVisitedAt`; in Claude Desktop the owner typed inside the thread, so any proxy for "read" is the gold itself. So §2 is measured live only: the `DeciderLog` already records `open`, `lastTold` and `unseen` per decision; after ~200 attended decisions, score sends and reverts with and without the read-state lines by replaying the logged boards through the same call (the log keeps the board text). Until then the benchmark bounds the design without §2.

**Ablations, most important first** (each against the full `ctx` at the same CV target, paired over days):
1. **D digests → N2's compact lines.** Is the gain the agent's reading, reproduced without tools? Expected: most of the new-work lift.
2. **E off.** Recall of off-board follow-ups and the new-work negative evidence.
3. **C off.** Does the archive help new-vs-done beyond E's hits, or only cost tokens?
4. **Per-thread owner-recency facts off** ("you last wrote here", F block). J2's warning: watch follow-up wrong-thread, not only sends.
5. **§3 schema → SCHEMA4**, and rule 3 (`referent_unique` guard) on/off: does the shortlist buy precision on terse follow-ups?
6. **Haiku cards off** (digest only). `rich` suggested ~+9 points on new work; check it holds with full digests present.
7. **Creation order → recency order** in D. Measures recency anchoring directly.
8. **between_tools → adaptive medium.** N3 says thinking alone didn't help; with 30k tokens of evidence it might.
Budget: dev 300 × 9 variants × ~30k tokens ≈ $80 at list price without cache, far less with it; Haiku cards ~$3; test once.

## 5. Ceiling, honestly
- **On this benchmark** the full-context call should match the agent, whose information it reproduces: about **65–72% of new work** started right and **45–55% of follow-ups** sent at ~1% wrong, with the off-board 3 points recovered. Opus with thinking reached the same numbers as the Sonnet agent, so a bigger model is not the lever; a wider board was. Beyond that, the benchmark's own follow-ups were typed inside their thread, so it undercounts what any words-only decider can do live.
- **Live, with read state,** the terse class should move. 20% of follow-ups are ≤5 words; today the most recently finished thread is right for 65% of them and the model can't tell which of two finished threads is meant. Read/unread plus "opened after its reply" picks one in the common case (read one reply, react). A fair guess is **60–70% of follow-ups sent at ≤1% wrong**, the rest asked with the right thread first. This is a guess until the log has 200 decisions.
- **Irreducible from words plus read state:**
  - the owner reads several replies, then types "yes": only focus or reply-to knows which (the core of N3's UI class);
  - new work the owner deliberately types into a related finished thread (N1: 11% of first messages continue a thread; judges call 5% of moments ambiguous): the right answer is whatever he meant, and the board can't know;
  - a new deliverable that two projects could own (~1% wrong project today);
  - label noise of about 5% in any measurement, so "0 wrong" is not a measurable target: 0.5–1% wrong with reversible sends (Revert in history, archive for a new thread) is the honest bar.
- The composer's live preview, Return to confirm and one-key Revert are what make the remaining 1% cheap; the context spec above is what makes it 1% rather than 3%.
