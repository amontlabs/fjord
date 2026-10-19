# Router benchmark: messages meant for several places

Which of two Router designs handles one message meant for several places better, without losing the everyday
single-place messages:

- **A, Haiku alone** (`candidates.Model`): one `claude -p` call with Haiku and a JSON schema, given the message, its
  composer context (reply chip, @tags, pills, pin) and the board as the Router's Jev options describe it today (title,
  project, what it's doing now, what you last told it). It returns the whole list (place, text) and whether it is sure;
  when it isn't, nothing is sent and its places are the ask card.
- **B, today's pipeline extended** (`candidates.Pipeline`): the structure you made first (a reply chip and @tags are
  places; split from tag to tag when each tag starts its own sentence or line, else one Haiku call divides among the
  tagged places; every untagged sentence beside a tag gets a Jev check of whether it is for that tag's place and is
  routed alone when not); without tags, the shipped Router as the v2 replay plays it (rules.py, combo-o, final3), and
  only when Jev's compound gates say several places (gate_compound ≥ 0.75, gate_compound2 ≥ 0.5) one Haiku call
  divides the text. On single-place messages B is exactly the shipped Router (checked decision for decision).
- **S, Sonnet alone**: A with Sonnet, a reference ceiling.

Every model gets the same instruction for the words: the user's own words, only what isn't for that place removed,
a sentence several places need may be copied.

## Data (all under `v2/data/multi/`, gitignored)

| file | what |
|---|---|
| `mined.jsonl` | your own past messages flagged as concerning several places (or only looking like it), on the board as it stood then (`mine.py`; raw transcripts read by local code, redacted before any model, flagged by Claude) |
| `written.jsonl` | messages written in your style on real dev boards by Claude (Sonnet), GPT (6.1 Sol) and Gemini (4 Argon), eight kinds: several @tags, no tags, Fjord + sessions, shared context, pronouns across parts, a reply chip plus a tag, dependencies, and messages that only look multi (`write.py`) |
| `labels.jsonl`, `cases.jsonl` | two blind labels per case by the two families other than the writer's (GPT + Gemini for your own messages); each unit of the message assigned to the places that must (`for`) and may get it; gold = both for `for`, either for `may`; required places = both, allowed = either (`label.py`) |
| `runs/` | candidate outputs on the single-place slice (v2 dev episodes) and the multi dev split |
| `sealed/`, `test_report.json`, `ledger.jsonl` | the multi test split, read only by `seal.py`, aggregates only |
| `blind/blind.md` | ~40 dev cases with three divisions in random order (gold, A, B) for you to tick (`blind.py`) |

Splits: by group (session-day); 40% dev, 60% test by hash, and every group the v2 benchmark holds out (calib, sealed)
goes to test.

## Scoring (`score.py`)

Multi-place, per case: places right (required ⊆ sent ⊆ allowed), text right per place (no required unit missing, no
unit meant only for others; units found by aligning the part's words to the message), parts with added words, all
right, click-loss (sure: 25 per wrong place, 4 per missed place, 4 per wrong text; unsure: 1 + 4 per defect), the
same loss when every division of two places or more is previewed, latency and cost. 2,000 bootstrap replicates
resampling groups, paired differences.

Single-place: the v2 replay's own score (v2/run/score.py, compare.py: loss, wrong sends, asks, real moments apart) and,
on right sends, whether the words sent are the message as typed.

## Run

```sh
python3 -m v2.multi.mine
python3 -m v2.multi.write
python3 -m v2.multi.label
python3 -m v2.multi.run single haiku        # and pipeline, sonnet
python3 -m v2.multi.run multi haiku --split dev
python3 -m v2.multi.score single haiku pipeline
python3 -m v2.multi.score multi dev haiku pipeline
python3 -m v2.multi.seal haiku pipeline sonnet   # once, after dev
python3 -m v2.multi.blind make
```
