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
