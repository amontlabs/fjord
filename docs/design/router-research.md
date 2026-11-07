# Router routing research (2026-10-11)

> Superseded: Fjord now runs on T3 Code instead of Claude Code and claude.ai. See [t3-code-map.md](t3-code-map.md).

What we learned making the Router decide where a typed message goes: what was measured, what shipped, what was not
enough, what was a dead end, and the mistakes made on the way. The code and data live in `evals/router/` (README.md
has the per-round tables, EXPLORE.md the protocol for explorers); the decision itself is in
`Sources/Fjord/RouterRoute.swift` (RouteFusion), `RouterLexical.swift` and `RouterDispatcher.swift` (the rank effect).

## The problem

A message typed in the Router's composer goes to one of your Claude Code sessions (a reply to its card or more work),
to a new session in a project, to Lookout itself (change a setting, a question about the board, several things at
once), or Lookout asks you (an ask-back card). Deterministic rules come first (an armed reply, a pinned target,
`@project` pills, "start a session in X", "tell X to"); what they leave goes to Jev (TypeSafe's decision model: typed
choice / yes-no / score questions over a state, one call, ~0.25 s, input tokens only, ~$0.04 per million) and to code
around it.

A wrong send is the costly outcome (your words land in the wrong session, or Lookout answers what a session should
have); an ask costs a click. Every number below is right sends / wrong sends as a share of messages, unless said.

## How it is measured (evals/router)

| set | what | gold |
|---|---|---|
| synth | 210 cases written by agents: everyday, hard disambiguation, traps | relabelled blind by a second agent, merged (either's acceptable destination counts, asking is fine if either allows it) |
| heldout | 150 cases written independently, bigger boards (15–21 sessions) | same blind relabel |
| real | 611 real moments: a message you really typed into a session, the board rebuilt as it stood then from your transcripts, where it went | strict (only where it went is right); labelled by agents clear / plausible / unclear by whether the board alone shows it |
| style | 332 Router-style messages written on those real boards | writer's |
| realA / realB | real split by session: tune on A, judge on B | |

- `bench.py FORMAT --policy ...` scores a format (how Jev is asked) and a policy (how its answers are decided) on every
  set. Always run with `JEV_ORDERED=1` (see the order mistake below). Answers are cached on disk (`cache/`), so policies
  are swept offline for free (`analyze.py`, `crossval.py`, `cv.py`).
- Real data stays on this machine: `evals/router/real/data/` is gitignored; keys and tokens are redacted before
  anything reaches Jev (`real/boards.py` `redact`).
- Differences under ~5 points between similar variants are noise at these sizes (bootstrap 95% intervals ±5–7).
- The lesson that shaped everything after round 1: **written cases mislead**. Agents write explicit, addressed
  messages; real ones are terse ("go", "commit it"), lean on recency, and ask questions meant for the session.
  Never judge a router change on written cases alone.

## Where it went

| | synth | heldout | real (B) |
|---|---|---|---|
| before round 1 (opaque keys, global history, 0.75/0.3 bar, word veto) | 36.5 / 2.5 | 62.7 / 1.0 | 14.5 / 21.5 (round-1 router) |
| round 1 (shipped, merged to main) | 64.3 / 2.4 | 75.3 / 1.3 | 14.5 / 21.5 |
| round 2 (`combo` + fusion, Lookout's order) | 57.1 / 1.4 | 67.3 / 2.0 | 37.9 / 4.7 |
| round 3 (`combo-o` + `final3`, branch router-jev-2) | 65.2 / 1.4 | 72.0 / 2.7 | 40.7 / 2.8 |

Round 1 looked excellent on written cases and was unsafe on real ones (one real message in five to the wrong place);
round 2 fixed that at a cost on written cases; round 3 recovered the written cases and cut real wrong sends further.

## Round 1: how Jev is asked

Shipped (merged into main as 46d50e6..62c0b94):
- **One option per destination.** A session and its open card were two options, so Jev's sureness of the session was
  split between them (0.5 + 0.4 read as unsure). Merging them: +18 points of right sends, no new call.
- **Options named by the session, described in their own structured criteria** (project, what it is doing now, what
  you last told it), instead of opaque keys `t1..tN` pointing into a fenced state blob. TypeSafe's docs say the same:
  option names are read, indirection costs accuracy. Top-1 89% vs 85%.
- **The message alone as the state.** The global list of your last 10 decisions made "yes" go to the session you last
  wrote to rather than the one asking; what you last told a session belongs on that session's option (69% vs 61%).
- **A yes/no per waiting card**: "is `message` the answer to `card`?". Bare replies ("lgtm", "nope") read as `unclear`
  in the route with one card waiting; the card check gets them (0.6–0.85 where the route said 0.05).
- **Gates**: yes/no checks for "changes how Lookout behaves" and "several things", decided first: "turn off jev labels"
  went to the session building that feature in every format.
- **Bars by what a wrong pick costs**: a session 0.7, a new session or Lookout's own 0.6 (one 0.75 bar with a 0.3 lead
  asked on a third of clear messages).
- **The word-overlap veto removed**: on top of the above it blocked 48 right sends and no wrong one.
- **Routing deadline 2.5 s** (was 20 s).

Not worth it in round 1:
- A second, narrower pass over the top candidates: better top-1, overconfident.
- One yes/no per session instead of one choice: 77% top-1 vs 89%.
- Averaging several option orders: helps the opaque format only.
- More rules in the instruction text: worse (56.7% vs 68.6%).
- Compact descriptions for long-idle sessions: noise.
- Examples of past routings in the state: no measurable effect, dropped.

## Round 2: real sessions

Built the real benchmark (above). On it the round-1 router was 15 / 20. Five explorers (`explore/intents`, `recency`,
`fusion`, `context`, `verify`), then a combination.

Causes of the real wrong sends, and what fixed them:
- **`question` caught questions you ask a session about its own work** ("what does X mean?") at p > 0.95. Fix: word
  Lookout's options by who the message is for ("a question to Lookout about the board … not a question for a session
  about its own work"), plus `gate_you` ("does it speak to one agent as you?") vetoing Lookout's intents. Real wrong
  20% → 9%.
- **The compound gate fired on one long multi-point message for one session.** Fix: `gate_compound2` ("meant for
  different places … several points for one session is no"), required beside the first.
- **Recency ignored.** The session that finished last is where a real message went 60% of the time (one of the last two:
  84%); Jev reads "finished 3m ago" poorly (numbers and dates are a known weak spot). Fix: a yes/no per latest session,
  "is `message` the user's next message in this conversation?" (right 91 of 95 times when one stands out and the route
  doesn't disagree), and a **fused model**: a conditional logit P(destination) ∝ exp(w · features) over Jev's log p,
  recency ranks, running, the checks and gates, with a logistic sureness on the moment; the rules' send when the fusion
  agrees, else the fusion's own pick at sureness 0.9, never for a message under 3 words or to Lookout's own.
- **A session stopped on a question counts as running in Lookout** (its turn is open); in the real boards a waiting
  session was never running, so the fusion's "running" penalty would have misfired. Fixed in Swift: a session waiting on
  you is not working.
- **Options reach Jev in Lookout's order** (working, then latest finished). Shuffled, the decision changed on 14% of real
  moments; Lookout's order was the best of the orders tried. Swift used to send them in dictionary order (random per
  run); `JevClient.orderedObject` now keeps the order.

Explored in round 2 and not enough on its own:
- Categorical recency words ("a few minutes ago"), a `latest: true` field: noise.
- A state field naming the session that finished last: top-1 37 → 57% but Jev obeys it as an instruction (realB 32%
  wrong). Rejected.
- Richer context per option (first ask, last 2 paragraphs): +4–5 top-1, within noise, +40% tokens.
- Fewer options (only the last N hours): no gain.
- A second verification call (pairwise or "fits"): mostly blocks wrong `question` sends; pairwise barely helps; +0.25 s.
- Raising intent bars alone: real wrong 20 → 12%; Jev is confidently wrong there (bars 0.8–0.95 identical).
- Asking intents only through gates (no intents in the route): leaks intent messages into sessions on written cases.

## Round 3: research and the words

A literature pass first; the ideas, what we did with them:

| idea (source) | result |
|---|---|
| Contextual calibration: ask about a content-free input, divide out the bias (Zhao et al. 2021, "Calibrate Before Use") | **Dead end.** Asked in the same call about an empty `nothing` field; dividing out (or weighting) its pull changed nothing beyond noise. Jev's bias here isn't a stable per-option pull. |
| Permutation debiasing / self-consistency (PriDe, Zheng et al. 2024; Tang et al. 2024) | **Dead end.** The route asked twice in one call, in Lookout's order and reversed, averaged: no gain. A fixed order already removes the variance. |
| Batch / domain-conditional calibration (Zhou et al. 2024; Holtzman et al. 2021) | Not pursued after the content-free result. |
| Disentanglement cues: time gaps, speaker, mentions (Elsner & Charniak 2008; Kummerfeld et al. 2019) | Recency already in the fusion; explicit message-type × session-state features (explore/state.py) were **noise**, except one rule (below). |
| Exact identifiers (URLs, PR numbers, paths) as "mentions" | **Not enough.** Only 39 of 611 real messages hold one; a unique best match is right 60%. |
| Lexical overlap / BM25 (disentanglement, email recipient prediction, Carvalho & Cohen 2008) | **Shipped.** Between the message and each session's transcript turns: alone it names where a real follow-up went 54% of the time (Jev 40–48%); by field (last answer +, older turns +, your last instruction −, title −) in the fusion. |
| Selective prediction with guarantees (Learn-then-Test, Angelopoulos et al.) | **Partly.** Risk–coverage showed the rules' path made 24 of 25 real wrong sends while the fused pick at 0.9 was right 78 of 79: a guard (the fused pick must agree at sureness 0.6) shipped. A wrong-send guarantee ≤ 5% isn't certifiable on our real data at useful coverage. |
| Per-user models and thresholds (Gmail Priority Inbox, Aberdeen et al. 2010) | **Promising, not built.** Refitting the fusion weights per user (MAP around the global weights) after ~50 labels: late real wrong 4.5 → 2.3% in a time-ordered replay. kNN over past messages and per-user thresholds added nothing on top. Needs Lookout to record labels (proposed as its own task). |
| Cascades (FrugalGPT, RouteLLM): a bigger model on the uncertain cases | **Dead end.** Haiku (via the CLI, 300 calls) on the asks: on real asks as wrong as right and confident either way (72–92 on both); +1–4 s. It looked good on written cases only (the round-2 trap again). |
| Response selection (Ubuntu next-utterance) | Already ours: the "next message?" yes/no. Asking it for BM25's top candidates too: no gain. Per-candidate checks instead of one choice: worse (round 1 again). |

Shipped in round 3 (branch router-jev-2): BM25 per field (RouterLexical, read from transcripts while Jev answers, the
board's text when there is none), the rules guard, a short-reply rule (under 3 words, fused sureness ≥ 0.95, and that
session's last message asks or proposes something), the ask card with four options (the right one among them on
79–89% of real asks), secret redaction on everything sent to Jev, Jev's question gate in the fusion.

Context-richness, again in round 3 (explore/lexical): text windows (last 1–6 turns, all with decay), user-only vs
assistant-only turns, stemming, French stop words, corpus vs board IDF: all within 3 points; the assistant's turns carry
the evidence, the user's own words are weak (and point away: a message repeating your last instruction starts
something new).

## Benchmark v2 (in progress, evals/router/v2, spec in evals/router/BENCHMARK.md)

Episodes rather than single messages: a board, then submits, card changes, picks and corrections in order.

- **Sources:** 501 real episodes (942 submits) on your real timelines; 180 scripted contracts plus 60 metamorphic
  siblings (the shipped Router passes every contract, 0 wrong sends); 763 written episodes (Claude 350 and GPT 350
  from 1,050 packets; Gemini still writing through `agy`, slowly).
- **Realism audit (v2/build/audit_realism.py): written messages are easy to tell from yours.** A logistic regression
  on simple features and character n-grams separates written first messages from real ones at AUC 0.90 (folds by
  session-day; GPT 0.88, Gemini 0.90, Claude 0.92; rewrites 0.80, goals 0.94). Give-aways: a lowercase first letter,
  "Lookout" in the text, more French, a closing period; yours have more "I", "you", "we", "and", code and "...".
  Written episodes go to the same session 26% of the time against your 52%, and their switches reach deeper into the
  board (median rank 4 against 2). Reweighting by length × question × destination fixes length and questions but not
  that gap. **Decision:** the headline is real moments alone (`real_only` in every scored report); written and scripted
  episodes count in the stress mix and their own slices, as coverage of flows your history lacks.
- **Written episodes are not typical traffic:** messages shorter than yours (p90 30–39 words against 73), fewer
  questions, more session switches (about 40% same against your 51%), and writers mark asking unnecessary about 80% of
  the time. They are kept for coverage of flows, weighted to the real mix, and never used for gold on asking.
  Curation drops rewrites that translated an English real message into French (15), and marks a first submit copied
  word for word from a real moment (179) so it plays but isn't scored twice.
- **Gold comes from blind labels: Claude and GPT on every event, Gemini as a third vote.** The plan was three
  families and never the writer's own, but Gemini's subscription quota ran out after about 120 calls ("Individual
  quota reached", resets every few hours), far short of the ~1,600 written events. So the writer's own family labels
  too, and a Gemini audit on a sample of written events measures whether that family agrees with its own writing more
  than the other family does. **Result (v2/build/family_bias.py): no own-family bias.** Against the writer's intended
  target, Claude matches 87.4% on Claude-written and 93.4% on GPT-written episodes, GPT 87.5% and 92.2%: the
  difference of differences is −0.7 points. Claude's writing is harder for every labeller, Gemini included (GPT agrees
  with Gemini 85% on Claude-written, 93% on GPT-written). Pilot on 30 events (29 with all three): the same target 66% of the time, pairwise 76%; almost every split is "a
  target" against "unknown", a split on whether the board is enough. Asking agreement is low (α 0.38): on real
  moments whether to ask is genuinely ambiguous, so asking gold is a majority with adjudication, not one label.
- **Labelling lessons:** in a batch, Claude put labels on neighbouring keys, and on a shared real board the wrong
  target still looked valid. Each label now echoes the opening words of its message. `agy` (Gemini) is an agent: given
  a ~70k-token batch it tries a shell command, which headless mode denies, and returns nothing; it gets small batches
  (≤3 events) and a JSON schema, and is never granted command permissions. It is slow (1.5–3 min per event).

## Round 4 (benchmark v2, dev split; directions ranked in evals/router/v2/DIRECTIONS.md)

The split was frozen by group before gold existed (`v2/data/episodes/groups.json`): dev 575 episodes, calib 312,
sealed 617. Numbers below are on dev's real moments (393 submits) with provisional ask gold ("allowed" until labels
land), so only changes that don't depend on ask gold are decided here.

- **Where the loss is (shipped, dev real):** 2.02 per message against 1.41 for always asking. Of the loss, wrong sends
  44% (14 of 129 sends, 10.9% of sends), asks without the answer in the first four 30%, asks with it 26%. On these
  numbers shipped does not beat always asking; the gap depends on how many asks are needless, which the labels decide.
- **The ask card (shipped):** its four were the ranking's first four, chosen for the first being safe to send. Now: the
  ranking's first, its best new session or Lookout intent among its first four, then sessions by recency. The answer
  is on the card 85% of the time against 77%; loss per message −0.13 (95% CI −0.23 to −0.03), sends unchanged, the
  written/scripted stress mix not significantly worse (+0.025, CI −0.03 to 0.09). Tried and dropped: the last-told
  session first (−0.16 on real but +0.07 on stress, losing new-session and intent answers), two of the ranking's
  first (−0.05), a BM25 slot (−0.11, worse than recency). Swift: `RouterTools.askCard`.
- **The fusion refitted on real moments alone** (explore/v2_fusion): six weights (`fin0`, `fin2`, `run`, `reply`, `nxt`,
  `f_you`) and the sureness. Real top-1 +4.3 points (95% CI +1.6 to +7.3, grouped CV; stable on three fold seeds),
  calibration error 0.056 → 0.023; in replay wrong sends 3.6% → 2.3%, loss −0.31 (CI −0.67 to +0.03), stress mix
  −0.17, scripted contracts all pass. Half the gain is messages to a session still working (shipped's `run` weight was
  −1.26: you often follow up while it works). The more written episodes in the fit, the smaller the real gain: they
  taught too many switches. Intent picks keep the earlier sureness: your transcripts predate the intents, so the refit
  learned that an intent pick is always wrong, and a clear setting stopped being sent (a dispatcher test caught it).
  Dead ends: BM25 absolute strength (A4), Jev's unused confidence/entropy/margins and same-title sibling mass (A3).
  `parity.py` now checks Swift against the weights Swift carries (an earlier attempt skipped installing the lexical
  features and produced a wrong fixture; the parity test caught it).
- **Always checking the session you last messaged** (explore/v2_continuity): −0.196 per message (CI −0.415 to
  −0.021) but on 3 avoided wrong sends in 2 groups, and as a hedge (a middling yes lowers confidence in a wrong pick)
  more than a find. Not ported; re-tested with real gold.
- **Typing predictions are reused only on the board they were read on** (cards shown, sessions working, latest
  finished, last-told); else read again at send. Not measurable offline (every eval message is decided on its own
  board), which is the point: a stale reuse could only add wrong sends the benchmark never sees.
- **Dead ends this round:** a running session's last answer as its latest for BM25 (A8: it already counts at full
  weight in `f_old`; running-target errors are confusion between running sessions); a shortlist of the options Jev
  sees (A9: −21 to −36% tokens, but 2–3 more wrong sends below 12 options, as the sureness reads Jev's mass on full
  lists; last-told, BM25 and waiting cards add no recall beyond recency); two wordings of the route in one call (A12:
  no gain, +68% tokens, and the second question shifts the answer to the first).
- **Gold landed** (Claude and GPT on all 2,815 events, Gemini on 203): the labellers agree on the target 88% of the
  time, on asking at α 0.25. 1,787 events agree; the 1,028 that don't are **soft gold**: each labeller's view is
  kept and an event's loss is their mean (no fourth pass by one of the labellers' own families picks a side).
- **A scoring mistake, caught by decomposing the loss:** a first run put shipped at 2.84 per real message against 2.05
  for always asking. The largest part (0.89) was sends to where you really sent the message, charged as wrong (×100
  when a labeller marked it consequential) because a labeller found the board alone insufficient. On a real moment the
  outcome is observed: such a send is right, and the policy's gambles are already charged when they miss. Now: where
  you sent it is always acceptable, and "ask required" means asking is never needless.
- **Dev real moments on labelled gold** (current Lookout, with the new card and the refit): 1.86 per message against
  2.05 for always asking and 21.6 for always sending to the latest session; 1.4% wrong sends, 30% of messages sent.
  The loss is mostly asks the labellers found needless (0.81), wrong sends (0.45, 0.13 of it consequential), and asks
  whose card missed the target (0.41).
- **The send bar, on gold:** the fused pick now sends at 0.93 (was 0.9). With a calibrated sureness, a send pays when
  (1 − p) × 25 is under an ask's cost (about 2 on real moments): p ≳ 0.92. Dev real loss 1.86 → 1.71 (CI −0.54 to
  +0.07), wrong sends 1.4% → 0.5%; 0.96 is worse. The rules' bar (0.6), the share it needs (0.5), the short-message
  bar (0.95) and the word minimum (3) are flat or best as they are. Dead ends: a stricter bar when the words suggest a
  consequential action (21% of real messages are labelled consequential; a word list finds 70% of them at 47%
  precision; dev worse at every bar, as the remaining wrong sends aren't those); the last-told check re-tested on gold
  with the refit (Δ 0.0: the refit absorbed it).
- **Confirmation, calib (read once, round 3 → round 4):** loss −0.71 per message on the natural mix (CI −1.42 to
  −0.16), −0.55 on stress (CI −1.20 to −0.11), wrong sends 4.2% → 2.4%; on real moments alone −0.96 (CI −2.68 to
  +0.48; 106 real episodes), the card's hit@4 +8.6 points (CI +2.1 to +14.9). The refit's top-1 gain shrinks out of
  sample: +1.1 points (CI −2.5 to +4.7) against +4.3 cross-validated on dev.
- **Sealed (read once, preregistered `v2.4`):** real moments 2.20 per message (CI 1.53 to 3.17), 1.1% wrong sends,
  25% sent, card hit@4 84%, top-1 67%; always asking 2.09 (CI 1.98 to 2.21). All sources 2.67 against 2.68. On sealed
  the Router is level with always asking: two consequential wrong sends (100 each) in 181 real submits outweigh what
  its sends save. The loss's cost of a wrong send is what decides whether sending is worth it at all; a cheaper wrong
  send (an undo window, C1) changes that, not a better classifier alone.
- **Raising the send bar looks large but waits for gold:** a sureness floor of 0.95 would turn 37 sends into asks and
  avoid 9 of the 14 wrong sends (−0.45 per message), but only if those asks count as "allowed".
- **Runner fixes found on the way:** a session started from an ask is named after its submit; changes to a started
  session the policy never started are skipped; a scripted pick with no pending ask is skipped; variant cards are
  deduplicated on canonical targets (a first sweep under-filled them and understated the gain).

## Capability wording (2026-10-14, evals/router/explore/capabilities.py)

`mark_seen` (mark a worth-a-look Router card seen) existed for the Router's own run, but the route's `change_fjord`
criteria and `gate_setting` only named settings and Triage's categories, so "seen the docs" could be sent to the docs
session. `capabilities-o` is `combo-o` with those two texts generated from one list of what Fjord itself does (settings,
Triage's categories/rules/groups, marking a card seen, marking inbox things done or seen); everything else frozen
(destinations, gates, order, `explore.final3:best` with the Swift weights, no refit).

| set | combo-o wrong / send / loss | capabilities-o wrong / send / loss |
|---|---|---|
| acknowledgement cases (40, written on real boards) | 5.0% / 12.5% / 3.70 | 0.0% / 32.5% / 1.50 |
| replay real B (162 submits) | 1.9% / 30.9% / 1.451 | 1.2% / 32.7% / 1.315 |
| replay real A (231) | 1.7% / 21.2% / 1.506 | 0.9% / 19.9% / 1.329 |
| bench realB (214) | 3.3% / 31.8% / 2.051 | 3.3% / 31.8% / 2.033 |
| bench realA (397) | 3.0% / 27.0% / 2.015 | 2.8% / 27.0% / 1.960 |

- Of the 22 acknowledgements whose gold is the Router: 2 went to a session before, none now; 10 go to the Router, 12
  ask. None of the 18 meant for a session (negations, quotes, instructions to the session) went to the Router.
- Real data: every interval includes 0; no measurable harm and a nominal drop in wrong sends. +~150 tokens a call, same
  latency. 2,062 fresh Jev calls (~$0.30). Adopted in Swift, with both texts made from one list.
- Limits: 40 written cases, gold for the mixed and approval-seen ones a judgement; real data has no Router-gold moments.
  Reproduce from `evals/router`: `python3 -m explore.caps_ack`, then `v2.run.episodes … --format capabilities-o`, then
  `python3 -m explore.caps_report episodes` and `bench`.

## Router actions from words (2026-10-14, explore/capabilities.py `capabilities-x…`)

Four more registry capabilities with an outcome phrase each: archive a card ("I'll do the theme one myself"), reopen an
archived card, mute or unmute a project, stop a running session's turn. Each phrase was added to the `change_fjord`
criteria and `gate_setting` text alone and together (one format per subset, `capabilities-x-<keys>`), on 42 new cases
written on real boards (`explore/caps_ack.py`, `ack_actions`): 26 clear asks (gold: Fjord itself) and 16 traps that use the
same words for a session's work ("archive the old logs in the repo", "stop using lodash in the code", "mute the warnings in
the build", "reopen the issue and fix it"; 8 addressed to a session, 8 bare). Everything else is frozen, as before.

Where the clear asks went (to Router / to a session / asked; the 6 to 8 cases of each kind):

| text | archive (8) | reopen (6) | mute (6) | stop (6) | traps to a session (8) | bare traps (8) | wrong sends (of 42) |
|---|---|---|---|---|---|---|---|
| capabilities-o (adopted before) | 0 / 1 / 7 | 0 / 2 / 4 | 4 / 0 / 2 | 1 / 4 / 1 | 0 / 1 / 7 | 0 / 0 / 8 | 7 |
| + archive | 3 / 0 / 5 | 1 / 1 / 4 | 4 / 0 / 2 | 1 / 4 / 1 | 0 / 1 / 7 | 0 / 0 / 8 | 5 |
| + reopen | 0 / 1 / 7 | 3 / 1 / 2 | 4 / 0 / 2 | 1 / 5 / 0 | 0 / 1 / 7 | 0 / 0 / 8 | 7 |
| + mute | 0 / 1 / 7 | 0 / 1 / 5 | 4 / 0 / 2 | 1 / 4 / 1 | 0 / 1 / 7 | 0 / 0 / 8 | 6 |
| + stop | 0 / 1 / 7 | 1 / 1 / 4 | 4 / 0 / 2 | 1 / 2 / 3 | 0 / 1 / 7 | 0 / 0 / 8 | 4 |
| + all four | 3 / 0 / 5 | 3 / 1 / 2 | 3 / 0 / 3 | 1 / 3 / 2 | 0 / 1 / 7 | 0 / 0 / 8 | 4 |
| **+ archive + reopen (adopted)** | 3 / 0 / 5 | 3 / 1 / 2 | 4 / 0 / 2 | 1 / 4 / 1 | 0 / 1 / 7 | 0 / 0 / 8 | 5 |

Real data, adopted text against capabilities-o (replay of the dev real episodes, and the bench on the 611 real moments;
wrong sends / loss per submit, delta with a paired 95% interval):

| set | capabilities-o | archive + reopen | all four | reordered base (placebo) |
|---|---|---|---|---|
| replay B (162) loss | 1.315 | 1.321 (+0.006 [-0.049, +0.045]) | 1.315 (0.000) | 1.290 (-0.025) |
| replay A (231) loss | 1.329 | 1.511 (+0.182 [-0.037, +0.634]) | 1.519 (+0.190) | 1.623 (+0.294) |
| replay A wrong sends | 0.9% | 1.7% | 1.7% | 2.2% |
| bench realB (214) loss | 2.033 | 1.930 (-0.103) | 2.033 (0.000) | 2.248 (+0.215) |
| bench realA (397) loss | 1.960 | 1.942 (-0.018) | 1.856 (-0.103) | 1.869 (-0.091) |
| 40 acknowledgements: gold Router reaches Router / asks | 10 / 12 | 11 / 11 | 10 / 12 | 10 / 12 |

- **The placebo is the noise.** The "reordered base" column is the same four capabilities in reverse order, with no new
  meaning. It moves 14 real submits and changes replay A more (+0.294 in loss, 5 wrong sends against 2) than either action
  text does. The two extra wrong sends in replay A under every new text are the same two messages that the placebo moves
  ("Tell me exactly what do you want to test?" and a follow-up, sent to a session that the board makes plausible): Jev's
  answer shifts with any change of wording, and the cost falls on the same replay A moments. Read against that, the real
  data show no harm from the new phrases (every interval includes 0) and the bench is flat to nominally better.
- **Verdict per action.** *Archive*: adopted. 3 of 8 reach the Router, 5 ask, none go to a session (before: 1 to a session);
  no trap reaches the Router. *Reopen*: adopted. 3 of 6 reach the Router, 2 ask, 1 goes to the session (before: 2 to
  sessions); no trap reaches the Router. *Mute*: dropped from the routing text. "Mute lookout" already reaches the Router
  (4 of 6) through the notifications phrase, the new phrase added nothing, and with all four phrases it was 3 of 6.
  *Stop*: dropped. "Stop the CI session" went to the session itself in 4 of 6 with or without the phrase (1 of 6 reached the
  Router): a session's name next to a command reads as a message for it, and a phrase doesn't change that. In both cases the
  tool stays in the run (`RouterCapability.routed` is false), reachable when a message reaches the Router another way, say
  in a compound message.
- **Traps never reach the Router**, under any text: 16 of 16 in all seven formats.
- Cost: about +85 input tokens a call (two phrases), same latency. A few thousand fresh Jev calls over the whole comparison (cached afterwards).
- Limits: 42 written cases; the stop and reopen asks name sessions by their titles (some awkward, they are real), the
  reopen boards show an open card where an archived one would be; a phrase that fails here may do better in another
  wording, and a stop that goes to a session is not necessarily wrong for the user (the session gets a message, it
  doesn't stop). Reproduce from `evals/router`: `python3 -m explore.caps_ack`, then `python3 -m v2.run.episodes
  v2/data/exp/ack_actions.jsonl --format capabilities-x-archive-reopen` (and each other format), then `python3 -m
  explore.caps_report actions|episodes|bench --base capabilities-o --new capabilities-x-archive-reopen`.

## Mistakes, and what they taught

- **Sorted keys hid option order.** `jev.py` sent `json.dumps(sort_keys=True)`, so named options always reached Jev in
  alphabetical order and round 1's "0 order flips" for them measured nothing. Found by the round-2 recency explorer.
  Fixed (`JEV_ORDERED=1`), and Lookout itself was found to send options in random dictionary order (fixed).
- **Two live keys reached TypeSafe** inside eval requests: an OpenRouter key and a z.ai key from transcripts, before
  redaction existed and then past the first pattern. Redaction now also strips any long letters-and-digits token, in
  the evals and in Lookout (`RouterTools.redacted`). Both keys should be rotated. Later (v2 stage A) a bank account
  number from an invoice pasted into a scratch session reached TypeSafe through the triage calls on finished turns;
  redaction (evals and Lookout) now also strips IBANs, card and account numbers and long digit runs. Lesson: personal
  data isn't only keys; every new path to a model needs the same scrub, and a scan of each derived file.
- **Porting slips caught only by parity tests** (`RouterFusionParityTests`, fixture from `evals/router/parity.py`):
  a gate the format asked but Swift didn't (`gate_question`), a BM25 quirk (a zero-weight field's words still count for
  IDF), weights rounded in Swift but not in Python, and "Jev's top" breaking ties by dictionary order (now: a tie counts
  as agreement). Every port since round 2 checks decision parity on all 360 written cases.
- **Credits ran out mid-round 2** (HTTP 402) after ~43,000 calls / 106M input tokens (≈ $4.50): benchmarks, not real use.
  Real use is ~5 calls per message (live prediction while typing, the send, card checks), ≈ $0.04/day at 100 messages.
  Most of that is the while-typing predictions.
- **A redaction pass over every string broke the scripted episodes:** the long-token pattern (28+ letters and digits)
  also matched long internal names, so episode, family and some session ids became `[redacted]`. Redact free text
  only, never identifiers; the scripted set was rebuilt and replayed.
- **Real-moment caveats**: the real set is messages typed inside a session (no address, context from the
  conversation), a stress test rather than the Router's own traffic; gold is strict; labels come from agents; a
  session's title is its final one; a running session is never the gold in this data (an artefact of the extraction).

## Open leads

1. Per-user learning from corrections, kept sends and answered asks (explore/personal.py has the replay and the
   recipe; proposed as a task).
2. Fewer while-typing Jev calls (they are most of the cost): cancel superseded predictions, longer debounce.
3. Real traffic logs: save the exact request and the outcome with each decision, so corrections become real labelled
   cases of the Router's own traffic (better than in-session moments).
4. Alternatives to Jev, not tested: Cloudflare Clef (Jev-compatible API, better on intent benchmarks per Cloudflare,
   ~6× the price), Laya (open, runs on-device, weak zero-shot past ~20 options). We stayed on Jev (2026-10-11).
