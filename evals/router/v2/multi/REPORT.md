# Messages meant for several places: Haiku alone (A) vs the extended pipeline (B)

2026-10-19. The harness and how to rerun it are in [README.md](README.md). Data is under `v2/data/multi/` (gitignored).

## Verdict

Neither design wins everywhere. Each loses where the other wins, and both results are clear.

- **Everyday single-place messages: B wins by a lot.** A sends about four times as many messages to the wrong place
  (10.5% of all submits vs 2.6%; 10.7% vs 1.5% on real moments). It costs 2.9 more click-equivalents per submit (95% CI
  +1.8 to +4.0), and changes your words in 12% of the messages it sends to the right place. Sonnet alone does better
  than Haiku but is still worse than B: +1.9 per submit (+0.7 to +3.1).
- **Messages that really go to several places: A wins by a lot.** A gets every place and every text right on 86% of
  them, against 59% for B (difference −27 points, CI −35 to −20). B's compound gates miss many messages that read
  as one sentence (pronouns: 13% of places right; shared context: 22%). B then sends the whole message to one place,
  or asks.
- **Messages that only look like several places: B wins.** A splits too readily: 24% of these messages send
  something to a place they weren't meant for, against 11% for B.

Shipping A as the Router would make everyday routing much worse to fix a rare case. An exploratory hybrid (dev only,
below) keeps B for where a message goes and asks Haiku only whether it splits. It recovers A's multi-place results at
a small cost on single-place messages (+0.26 per submit, CI −0.28 to +0.92). Its price is latency: it waits for Haiku.

## What was measured

| slice | what | size | groups |
|---|---|---|---|
| single-place | v2 dev episodes replayed through `v2/run` (click-loss, branches, corrections) | 574 episodes, 851–936 submits (216 / 393 real moments) | 92 |
| multi-place, test | written cases and your real messages, sealed: run once through `seal.py`, aggregates only | 248 (121 several places, 127 one place; 50 real) | 65 |
| multi-place, dev | the same kinds, read freely | 141 | 39 |

- **Multi-place data.** 1,928 of your own past messages, redacted, were read by Claude: only **1** concerns several
  places, and 58 only look like it (they mention other agents or sessions but are for one). That is expected, since
  in a session you could only ever write to one place. So the cases meant for several places are written: 348 in
  your style on real dev boards, by Claude, GPT-6.1 Sol and Gemini 4 Argon (about a third each). They cover 8 kinds:
  several @tags, no tags, Fjord plus sessions, shared context, pronouns across parts, a reply chip plus a tag,
  dependencies, and messages that only look multi. Your 59 real messages are kept as the real "looks multi" slice.
- **Gold.** Two labellers per case, both from families other than the writer's (GPT + Gemini for your own messages),
  blind to each other and to the writer's intent. Each assigned every unit of the message to the places that must get
  it and the places that may. Places agreed exactly on 95% of cases; whether a message is multi-place, κ = 0.93; unit
  assignment, 93%. The writer's intent fell within gold in 88% of cases. Required places are those both labellers
  named; allowed places are those either named. 18 of 407 cases (one Gemini batch that kept failing) have no gold.
- **Metrics.** Places right (required ⊆ sent ⊆ allowed). Text right per place: no unit it needs is missing and no
  unit meant only for other places is included, found by aligning the part's words to the message. The share of parts
  with words that aren't in the message. Click-loss: a wrong place costs 25, a missed place or a wrong text 4, a
  preview costs 1, plus a variant that previews every division. Latency, and cost per message. Intervals are 2,000
  bootstrap replicates resampling groups (session-days). Differences are paired.

## Numbers

Single-place slice (natural weighting; loss per submit, lower is better):

| | loss | wrong / all submits | wrong / sends | sends | ask hit@4 | consequential wrong | words changed on right sends | latency p50 / p95 | cost / message |
|---|---|---|---|---|---|---|---|---|---|
| B pipeline (= shipped) | **2.39** [1.90, 2.86] | **2.6%** | 6.0% | 43% | 78% | 4 | 0% | **0.24 s / 0.28 s** | **$0.0002** |
| A Haiku alone | 5.31 [4.26, 6.38] | 10.5% | 15.9% | 66% | 66% | 18 | 11.8% (5.1% added words) | 3.3 s / 5.8 s | $0.0014 |
| S Sonnet alone | 4.27 [3.19, 5.44] | 8.7% | 11.9% | 73% | 67% | 12.5 | 8.6% | 2.9 s / 4.7 s | $0.025 |
| real moments: B / A / S | 2.06 / 5.26 / 2.83 | 1.5% / 10.7% / 6.0% | 6.1% / 22% / 11% | | | | | | |

Paired: A − B = +2.92 [+1.75, +4.04]. On real moments it is +3.20 [+2.12, +4.38]. Groups where only A sent
something wrong: 38; where only B did: 1 (McNemar p = 1.5e-10). A is worse in 14 of the 16 message families; it does
better only on small talk and topical follow-ups.

Multi-place test split (sealed; 95% CI in brackets):

| | all right | places right | text right / place | parts with added words | wrong send | loss (send when sure) | loss (preview divisions) |
|---|---|---|---|---|---|---|---|
| **meant for several places** (121) | | | | | | | |
| B | 59% [51, 66] | 63% | 95.2% | 1.8% | 0% | 3.52 [2.83, 4.23] | 4.15 |
| A | **86%** [81, 91] | 98% | 94.4% | 3.6% | 1.7% | **1.07** [0.44, 1.99] | **2.05** |
| S | 89% [84, 95] | 99% | 95.3% | 3.1% | 0.8% | 0.81 | 1.46 |
| **look multi, meant for one** (127) | | | | | | | |
| B | 29% | 31% | 93.8% | 7.7% | **11%** [7, 16] | **5.91** [4.94, 7.05] | 4.35 |
| A | 54% | 59% | 89.0% | 8.6% | 24% [17, 30] | 8.08 [6.56, 9.63] | 4.98 |
| **your real messages** (50, all one place) | | | | | | | |
| B | 6% | 6% | 100% | 0% | **8%** | **6.78** | 6.78 |
| A | 40% | 42% | 85% | 0% | 22% | 9.88 | 9.08 |
| **all 248** | B 44% / A 69% | B 46% / A 78% | | | B 5.6% / A 12.9% | B 4.75 / A 4.66 | B 4.25 / A 3.55 |

Paired, B − A: on several places, loss +1.29 to +3.34 and all right −35 to −20 points; on look-multi, loss −3.99 to −0.42
and wrong sends −20 to −5 points; on all 248, the loss difference spans 0 (−1.09 to +1.17). "All right" counts an ask
as not right, which is why B scores low on one-place messages while its loss is better: it asks where A guesses.

By kind (test, all right, B / A): @tags 95% / 95%, reply chip + tag 100% / 100% (structure decides both); Fjord + a
session 48% / 100%; no tags 67% / 95%; shared context 17% / 78%; pronouns 0% / 26% (texts are the hard part for
everyone: Sonnet 44%); dependencies 5% / 27%.

Dependencies are a policy question, not a routing one. The labellers mostly gave the later place nothing ("ask X, then
tell Y the answer": Y can't act yet). Both designs send Y its part now, so most of the look-multi wrong sends on A
and B come from these 22 cases.

Exploratory hybrid (dev only, decided after the sealed read, so not confirmed). The structure and Jev as in B, and
Haiku alone asked in parallel; its division is used only when it names two places or more:

| dev | single-place loss (Δ vs B) | single-place real moments (Δ) | multi-place all right | look-multi wrong send | latency p50 |
|---|---|---|---|---|---|
| B | 2.39 | 2.06 | 63% | 8% | 0.24 s |
| hybrid | 2.65 (+0.26 [−0.28, +0.92]) | 2.35 (+0.29 [+0.03, +0.66]) | 88% | 23% | 3.2 s |
| hybrid, Haiku only when Jev isn't sure | 2.81 (+0.42 [+0.04, +1.00]) | 2.35 | 85% | 21% | 2.6 s |

## How sure

- The single-place gap is large, and has the same sign in every family but two, real moments included. The A − B
  interval excludes 0 by a wide margin. One caveat: B's fusion weights were refitted on real dev moments
  (RouterRoute's `weights`), so B has an in-sample edge there. That refit was worth about 4 points of top-1 under
  cross-validation, far below the gap measured here. The v2 calib and sealed episode files were never built, so there
  was no held-out single-place set to read.
- The multi-place results come from a sealed split read once (ledger entry 2026-10-19T03:42, code `added513f9c3d319`).
  A's lead on messages meant for several places, and B's lead on messages meant for one, both have intervals well
  clear of 0.
- The multi-place positives are written, not real: your transcripts contain only one. The real Router traffic in
  Fjord's trace (51 lines) has none either. How often these messages happen, and in what shape, is therefore unknown.
  That matters more than any number here: a design that makes 98% of messages worse to help a few is a bad trade
  unless those few are frequent.
- Writer and labeller changes forced by outages, which don't change the conclusions:
  - `claude -p` was logged out for about two hours, so the Claude writer and labeller ran as Sonnet subagents.
  - Gemini 4 Argon's quota ran out partway through labelling (it resets in a week). Gemini 3.8 Flash made 143 of the
    269 Gemini labels.
  - Agreement didn't differ by labeller pair: 95% for each pair.
- Text scoring is automatic: units are found by aligning words. It can't tell a harmless capital letter from a real
  change, so "added words" counts only words absent from the message. Your blind check is the anchor for this.

## For you to check (blind)

`v2/data/multi/blind/blind.md` holds 40 dev cases, stratified by kind. Each case shows three divisions in random
order: the gold, A's and B's. Tick the ones you'd accept as sent, then run `python3 -m v2.multi.blind read` to see
how often you agreed with the gold and with each design. The key is in `blind/key.json`; don't open it before you're
done.

## Exploratory: the mix with no ask before a split (dev only)

The user's direction after the report: speed doesn't matter, and a split is shown live under the composer, so Return
sends it with no ask. Every division is scored as sent. These variants were decided after the sealed read, and were
run on the single-place episodes and the multi dev split only (`candidates.NoAsk`, `noask.py`):

1. Jev and the structure decide where; Haiku runs on every message and its division is sent whenever it names two
   places or more.
2. As 1, plus a hold: Haiku is asked again on the messages it split, with a `waits_for` field per part (its own
   judgment, no word rule), and a part that waits for another place's answer is held, not sent.
3. As 2, but a split is sent only when Jev's compound gates also fire (gate_compound ≥ 0.75, gate_compound2 ≥ 0.5);
   otherwise B as shipped.

| vs B as shipped | 1 | 2 | 3 |
|---|---|---|---|
| everyday messages, extra wrong sends per 100 (B: 2.6) | +1.3 [+0.2, +2.5] | +1.5 [+0.6, +2.6] | **+0.2 [0.0, +0.5]** |
| same, real moments (B: 1.5) | +2.3 [+1.0, +3.8] | +2.3 [+1.0, +3.8] | **+0.3 [0.0, +0.8]** |
| everyday click-loss per submit | +0.55 [0.0, +1.24] | +0.68 [+0.23, +1.30] | +0.03 [−0.02, +0.11] |
| look-multi written (52, 20 groups), wrong sends per 100 (B: 9.6 [3.4, 17.5]) | 25.0 [17.3, 33.3] | **0** | **0** |
| look-multi, your real messages in dev (9), wrong sends per 100 (B: 0) | 11.1 (1 of 9) | 11.1 (1 of 9) | 0 |
| several places (80, 22 groups), fully right (B: 62.5% [54.4, 70.1]) | **87.5%** [81.0, 93.3] | 85.0% [79.5, 90.5] | 73.8% [64.6, 81.8] |

Only 9 of your 59 real look-multi messages are in dev. The other 50 are in the sealed split, which these variants
did not read. The hold removes every look-multi wrong send in written dev: those came from dependencies. It does
nothing for everyday messages, where Haiku's extra splits aren't dependencies.

**Pick: 3.** It costs at most half a wrong send per 100 everyday messages, against 1.5–2.3 for 1 and 2. In exchange
it gets 11 more of every 100 multi-place messages fully right (CI +4 to +19). Variant 2 gets another 11 per 100
multi-place messages right, at 1.3–2 more wrong sends per 100 everyday messages. That pays only if more than about
one message in eight is meant for several places, and your transcripts and router trace show nothing close to that.
Variant 3's limit is Jev's gates: it still misses the multi-place messages they don't flag, mostly pronouns and shared
context. Improving the gates is the lever if those turn out to be common.

### Variant 3 in the form being shipped (dev only)

The ship form (`candidates.Ship3`) makes at most one Haiku call per message: no unconditioned first call, and B's
no-waits divider never runs. It works like this:

- When Jev's two compound gates fire, one Haiku call runs, with `waits_for`, every place and no note.
- If Jev's pick is compound without the gates, the same call runs. That happened once in dev and twice in the
  single-place episodes.
- If the call's parts name two places or more and at least one part doesn't wait, those parts are sent and the
  waiting ones held.
- If it names one place, or every part waits, and Jev's pick is compound, that place goes first in Jev's ranking. The
  result is sure only if Jev and Haiku both are. Otherwise Jev's decision goes as shipped.
- If the call fails, Jev's decision goes with the gates read as 0: a compound pick becomes an ask on the rest of the
  ranking. No call failed in these runs.

Corrected on 2026-10-19. The first measurement of this form ran B's pipeline first. On a compound pick, that called
B's divider and then the `waits_for` call: two Haiku calls, with the first left out of the cost and latency. Its
one-place fallback could also take the divider's answer instead of the `waits_for` call's single place. The table
below is the rerun with one call. It differs from the first measurement only on messages meant for several places,
where it gets 77.5% fully right instead of 73.8%.

| vs B as shipped | 3 | 3, ship form (one call) |
|---|---|---|
| everyday messages, extra wrong sends per 100 (B: 2.6) | +0.2 [0.0, +0.5] | +0.1 [0.0, +0.3] |
| same, real moments (B: 1.5) | +0.3 [0.0, +0.8] | 0 [0.0, 0.0] |
| everyday click-loss per submit | +0.03 [−0.02, +0.11] | +0.01 [−0.03, +0.07] |
| look-multi written (52), wrong sends per 100 (B: 9.6 [3.4, 17.5]) | 0 | 0 |
| look-multi, your real messages in dev (9), wrong sends per 100 (B: 0) | 0 | 0 |
| several places (80), fully right (B: 62.5% [54.4, 70.1]) | 73.8% [64.6, 81.8] | **77.5%** [69.1, 84.9] (vs B +6.9 to +24.1) |

The one-call form is at least as good as variant 3 on every slice, and better on messages for several places, where it
uses the `waits_for` call's own division and single place. Haiku runs on 6 of 925 everyday submits and on 57 of the
141 multi dev cases. On those it adds about 4.3 s (p50, Jev plus `claude -p`) and $0.0018 per message.

## Exploratory: improving the divider's prompt (dev only)

These runs use the ship form (`Ship3`, prompts as shipped at ca486625) on the multi dev split and the single-place
episodes. They never read the sealed split.

**What fails today.** The ship form gets 18 of the 80 dev messages meant for several places wrong. Grouped by cause:

| cause | cases | the divider's fault? |
|---|---|---|
| Jev's gates didn't fire, so B sent the whole message to one place or asked (shared context 4, pronouns 3, no tags 3) | 10 | no: gate recall |
| a part that only has to wait for another session to finish ("once it's in, rebase on it") was held, so its place was missed | 5 | yes (`WAITS_RULE`) |
| a shared sentence went to a third, wrong session instead of both | 1 | yes |
| words changed ("No endless testing on either" → "No endless testing") | 1 | yes |
| a pronoun left dangling in a tag split ("include those changes"), which structure decides with no model | 1 | no |

The automatic score misses a sixth problem, the one in the smoke test: a dropped address that leaves a fragment. A
blind GPT judge read the 72 parts the live prompt sends in splits:

- 8 (11%) don't read as said to their session. Examples: "a minimal reproduction of the bug first.", "just give me
  what it has so far" and "commit what it has" sent to that same session, "one commit everything on main first".
- 5 (7%) lean on something only another part says.
- 1 (1.4%) has added words.

My own reading found 7 fragments. The look-multi messages split today are all correct holds of a dependent part (0
wrong sends).

**What changed.** The four revisions sit beside the live constants in `candidates.py`, and the live ones are
untouched (parity stays green):

| | address rule | dependency rule |
|---|---|---|
| v2 | `TEXT_RULE_V2`: own words only; keep a third-person clause whole rather than leave a fragment | `WAITS_RULE_V2`: hold only a part that needs another place's answer; send a part that only has to wait for another to finish, with what it waits for |
| v3 | `TEXT_RULE_V3`: the minimal turn of address ("what it picked" → "what did you pick?", its → your), nothing else | `WAITS_RULE_V2` |
| v4 | `TEXT_RULE_V3` | live `WAITS_RULE` |
| v5 | `TEXT_RULE_V2` | live `WAITS_RULE` |

**What it gained or cost** (multi dev, 80 cases for several places and 52 written look-multi; Δ is against the live
prompt, with a 95% interval over groups):

| | live | v2 | v3 | v4 | v5 |
|---|---|---|---|---|---|
| several places fully right | 77.5% [69.4, 84.9] | 81.2% (Δ −1.3 to +9.5) | 76.2% (Δ −5.3 to +2.7) | 76.2% (Δ −5.6 to +2.7) | 77.5% (Δ −3.7 to +3.6) |
| look-multi wrong sends per 100 (B: 9.6) | 0 | 3.8 [0, 10.4] | 5.8 [0, 14.0] | 0 | 0 |
| your real look-multi in dev (9) | 0 | 0 | 0 | 0 | 0 |
| split parts not said to their session (judge) | 11% | 8.5% | 1.0% | **2.8%** | 10% |
| split parts with added words | 1.4% | 16% | 25% | 15% | 1.4% |
| of which changed beyond the turn of address (judge) | 1.4% | 10.6% | 16.7% | 6.9% | 1.4% |
| everyday submits where the gates fire: wrong sends (8 submits; B 1 of 7) | 2 | 4 | 3 | 2 | 3 |

- **The own-words address rule (v5) does nothing.** Haiku still drops the address and leaves the fragment: 10% against 11%.
- **The turn of address (v4) fixes the fragments,** down from 11% to 3% of split parts. It has the smoke test's
  shape: "Are you finished?", "Just give me what you have so far.", "What exactly did you commit?". But 15% of split
  parts gain words, and 7% change more than the address. Some of those changes are wrong: "check the crash on the
  version before its commit" (its = the version's) became "before your commit", and "Rerun CI twice" gained "CI".
- **Sending what only has to wait (v2)** recovers some of the 5 held parts: +3.7 points fully right, but not clearly
  (the interval includes 0). In exchange it sends parts to sessions the labellers wanted left out (3.8 per 100
  look-multi). It also copies a referent by paraphrasing it ("Once the duplicate disks migration bug is fixed, rebase
  on it"): 16% of parts gain words. The labellers themselves split on these cases. Whether a part that only waits
  should go now is a product decision, not something a prompt can learn.
- **Nothing beats the live prompt clearly on dev,** and every revision adds words. 8 everyday submits are too few to
  read either way.

**Recommendation: keep the live prompts.** The biggest failure group, 10 of 18, is the gates' recall, not the divider.
The fragment problem is real (about 1 split part in 9). The only prompt that fixes it, v4, does so by rewording. It
breaks the own-words rule in 15% of parts, sometimes changing the meaning, so I wouldn't ship it. If you want the turn
of address anyway, confirm v4 on held-out data before porting it:
- a fresh written set of about 150 multi-place messages, weighted to third-person addresses ("ask X what it…", "tell
  X to … its …"), on calib boards;
- labelled by GPT and Gemini;
- judged blind for address, meaning kept and words changed;
- plus your own check of 40 address turns.

Ship it only if meaning-changing rewrites stay under 2% of parts.

## Exploratory: the gates' recall (dev only, 2026-10-20)

These runs use the ship form (`Ship3`, prompts as shipped) on the multi dev split and the single-place episodes, with
one more reason to ask the divider (`gates.Ship3Plus`, `python3 -m v2.multi.gates`). They never read the sealed split.
Every number is against the ship form; intervals are 95% over groups, paired.

**What fails.** Of the 80 dev messages for several places, the gates miss 10 (the divider is never asked). They are
plain to read: "Spacing one: keep the side bar full height. Wrapping one: add the coauthor", "in the microsandbox PRs
session rebase…, and the stability banner one commit…". `gate_compound` is often up (0.57–0.91); `gate_compound2` is
the one that stays down (0.19–0.45): it asks for sessions "it names", and "the CI one" doesn't read as naming. Haiku
gets 6 of the 10 fully right when asked, so 6 is the most a better trigger can recover here. The other 4 are pronoun
messages Haiku also gets wrong (pronouns stay 0 of 7 in every variant: that is the divider, not the gates).

**What was tried.** Three kinds, as asked:

- the thresholds: `gate_compound2`'s bar at 0.3 instead of 0.5 (`gt30`);
- a third signal Jev already returns: the routing call's own probability for `compound` (`pc30`, `pc50`; no new call);
- reworded gates, each asked alone in a Jev call of its own on the message, so the routing call's answers don't move:
  `addr` (instructions to two or more sessions, each picked out by what it works on: "the CI one: …", "in the X
  session …", "tell the Y one to …"), `addr-places` (the same over `places`, the board's session names), `split`
  ("should it be split…"), `agents` ("does it speak to two or more agents in turn…"). `split` and `agents` were dropped
  at the trigger stage: `split` catches 2 of the 6 at a bar where it fires on 17 everyday submits, `agents` at most 1
  (firing on 19).

| vs the ship form | several places fully right (80) | Δ | everyday extra wrong sends per 100 (v2 dev episodes) | real moments | everyday decisions changed |
|---|---|---|---|---|---|
| ship form | 77.5% [69.1, 84.9] | | (ship: 2.7) | (ship: 1.5) | |
| bar 0.3 for `gate_compound2` | 80.0% | 0 to +6.7 | +0.2 [0, +0.5] | +0.3 [0, +0.8] | 2 |
| route `compound` ≥ 0.5 | 78.8% | 0 to +4.3 | 0 | 0 | 0 |
| route `compound` ≥ 0.3 | 81.2% | 0 to +8.6 | +0.1 [0, +0.3] | 0 | 2 |
| `addr` ≥ 0.5 | 82.5% | +1.1 to +10.1 | 0 | 0 | 0 |
| `addr-places` ≥ 0.6 | 83.8% | +1.4 to +11.6 | +0.1 [0, +0.3] | 0 | 1 |
| **`addr-places` ≥ 0.7 (ported)** | **82.5%** [75.3, 88.6] | **+1.2 to +9.9** | **0** | **0** | **0** |
| the same, asked inside the routing call | 82.5% | +1.2 to +9.9 | −0.1 [−0.5, +0.2] | −0.5 [−1.3, 0] | 25 |
| route `compound` ≥ 0.3 or `addr-places` ≥ 0.7 | 85.0% [79.5, 90.5] | +2.4 to +13.3 | +0.1 [0, +0.3] | 0 | 2 |

Look-multi messages (52 written, 9 of yours): 0 wrong sends for every variant except the 0.3 bar (1 of your 9).

- **The everyday "wrong" sends** of `compound` ≥ 0.3 and `addr-places` ≥ 0.6 are one message: "can you stop nagging me
  about the lcu update…, and for the macos alternative…, make the background animated". It is plainly for Fjord and a
  session; its gold is soft (Claude: the session; GPT: compound), so the split counts half wrong. The other change of
  `compound` ≥ 0.3 is an ask that became a right split.
- **Inside the routing call** the new question moves the other answers: 25 everyday decisions change (11 right sends
  became asks and 8 asks right sends; 3 wrong sends became asks and 3 asks wrong sends), the fusion having been fitted
  on answers asked without it. Its own call
  moves nothing, so no refit is needed. That is the form ported.
- **A check on messages these were not chosen on**: the 332 Router-style messages written on your real boards in round 2
  (30 of them for several places) and 459 of your real moments not in the dev episodes, messages only:

| | Router-style, several places caught (30) | Router-style, fires on one-place (296) | real moments, fires (459) |
|---|---|---|---|
| ship form (gates or a compound pick) | 18 | 0 | 5 |
| + `addr-places` ≥ 0.7 | 20 | 0 | 5 |
| + route `compound` ≥ 0.3 | 25 | 1 | 7 |
| + both | 25 | 1 | 7 |

  Firing only asks the divider; it sends nothing to two places unless Haiku divides the message.

**Ported: `addr-places` ≥ 0.7, in a Jev call of its own** (`RouterTools.addressedGate`, `Classification.divides`). On dev
it gets 4 more of every 80 messages for several places fully right (82.5% against 77.5%, +1.2 to +9.9), changes no
everyday decision, and sends nothing wrong on look-multi messages. Held out, it catches 2 more of 30 Router-style
messages for several places and fires on nothing new. Its price: one more Jev call per message, in parallel with the
routing call (about 350–400 input tokens, so about $0.000015), and Haiku on 10 more of the 89 untagged dev messages
(the 6 misses it catches and 4 look-multi messages, all of whose dependent parts it holds).

**Ported too, on your go-ahead (2026-10-20): the route's `compound` ≥ 0.3 beside it** (`RouterTools.compoundRouteSure`,
read in `Classification.divides`, so the live split and the send ask the divider on the same messages). It adds 2 more
dev messages (85.0%, +2.4 to +13.3 against the ship form) and, held out, 5 more of the 30 Router-style ones (25 against
20). It costs no call: the score comes with the routing call. Its price: it splits the soft-gold message above (+0.1
wrong sends per 100 everyday submits, 0 to +0.3; none on real moments), and it fires on 2 more of your 459 real moments,
where Haiku then decides whether there is more than one place.

How sure: the wording and the bar were chosen on dev, among 4 wordings and 5 bars, on 10 misses. The neighbouring
choices agree (`addr` ≥ 0.5 and `addr-places` ≥ 0.6 give 82.5–83.8%), and the held-out Router-style messages agree in
direction, but the gain there is 2 of 30. What is left: 4 gate misses on dev (2 Haiku would get right), 7 pronoun
messages the divider gets wrong, the 5 parts the dependency rule holds, and the fragments.
