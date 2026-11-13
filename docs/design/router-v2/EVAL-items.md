# Router v2 open items on real threads (2026-11-13)

A thread's open items (OPEN-ITEMS.md, DESIGN.md 1.15 R7) are kept by one read per input: every turn the agent ends and
every message of yours (`RouterItemLedgers`, `RouterItemsPrompt`). This is how its prompt and model were chosen.

## Data and method

- **Sequences, not moments.** `evals/router/items/export.py` reads the owner's T3 history read-only (`statev2.sqlite`,
  `mode=ro`, never `userdata/secrets`) and cuts **45 sequences** of 3 to 8 inputs in order, each with at least two turns,
  from 29 threads of the last 7 days (subagent threads left out). Each turn carries its reply, the words that started it,
  or what woke it (a delegated task's completion); each message of yours carries the reply it answers. Tags, as picked:
  23 with a **mid-run wake** (a turn ends, then a run started by an agent's message follows within 10 minutes), 27 with a
  turn that asks something, 25 where you answer it, 15 with words sent into a live run, 7 where the agent asks again
  without you in between. The output (transcripts) stays in the gitignored `data/`.
- **A held-out set**: 45 more sequences (`--seed 7 --days 10 --exclude data/cases.json`, no step shared with the first),
  29 threads, 255 inputs: 20 wakes, 23 asks, 19 answers, 10 steers, 6 restates.
- **Inputs exactly as the app builds them**: the `ItemsEvalDump` test writes the system prompts, the schemas and each
  input's parts as `RouterItemsPrompt` renders them (redacted, fenced). `run.py` replays each sequence in order, as the
  engine does: a ledger starts empty; each turn is read with the items open then; your words are read only when something
  is open; closes, merges and adds are applied as `RouterItemLedgers.commit` does. Calls as the app makes them: `claude -p`,
  streamed, no tools, effort `low`, 4 at once.
- **Judge**: Opus (`judge.py`), blind to the prompt and the model. Per sequence it sees the same redacted inputs in order
  and, after each, what the engine did (closed with how, added, merged), and lists per input: real Stuck, Decide or Do items
  the engine missed, added items that aren't real (the agent handles it, an offer, routine news), wrong kinds, duplicates
  of an open item, wrong closes, closes it missed, unclear sentences. Recall = real items found / (found + missed);
  precision = real items / items added.

## Results

First set (n = 45 sequences, about 225 reads each):

| config | reads | added | precision | missed | recall | false | dup | merged | closes | wrong closes | missed closes | bad sentences | end p50 / p90 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Sonnet, v1 | 224 | 132 | 0.92 | 5 | 0.96 | 10 | 1 | 27 | 54 | 1 | 7 | 0 | 4.2 / 6.7 s |
| Haiku, v1 | 227 | 136 | 0.93 | 7 | 0.95 | 9 | 0 | 28 | 43 | 0 | 14 | 6 | 4.9 / 7.6 s |
| **Sonnet, v2** | 224 | 155 | 0.91 | 2 | 0.99 | 14 | 1 | 37 | 66 | 2 | 4 | 3 | 3.7 / 5.1 s |

Held-out set (n = 45, 234 reads each):

| config | added | precision | missed | recall | false | dup | merged | closes | wrong closes | missed closes | bad sentences | end p50 / p90 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Sonnet, v1 | 135 | 0.90 | 2 | 0.98 | 14 | 0 | 37 | 49 | 0 | 14 | 1 | 4.6 / 6.5 s |
| **Sonnet, v2** | 160 | **0.93** | 1 | **0.99** | 11 | 0 | 37 | 57 | 1 | 12 | 2 | 4.6 / 7.0 s |

| Sonnet, v2, after REVIEW-items fixes (2026-11-13, the app's inputs re-dumped: identical) | 156 | **0.96** | 1 | 0.99 | 6 | 0 | 37 | 60 | 2 | 13 | 1 | 4.0 / 5.9 s |

| Sonnet, v3: `detail` and `quote` per item (2026-11-13) | 129 | **0.96** | 1 | 0.99 | 5 | 0 | 35 | 48 | 1 | 7 | 1 | 3.4 / 5.2 s |

(The machine was busy with other agents; p50s are pessimistic, and two configs running at once share it.)

- **v3** (`prompts/system-turn-v3.txt`, `system-said-v3.txt`; the message prompt is v2's): each found item also has its
  `detail` (the whole item, at most about 280 characters, "" when the sentence says it all) and its `quote` (the agent's
  lines, copied exactly), and the sentence puts the key fact first. Held out, against v2 after the fixes: precision
  0.96 and recall 0.99 unchanged, no duplicates, wrong closes 2 → 1, missed closes 13 → 7, 156 → 129 items added (as
  precise, so fewer restatements and near-items), 231 reads, $0.0086 a read (the two fields add about $0.0006).
  133 details and 163 quotes; **2 quotes (1.2 %) fail the verbatim check** and are dropped (`RouterItemsReading.quote`):
  one spans a redacted id (as it should be dropped), one a sentence the model reworded a word of. `judge.py score` counts
  them (`run.py` checks each quote against the raw reply as the app does).

- **Model: Sonnet.** Haiku finds items as well (precision 0.93, recall 0.95) but misses twice the closes (14 against 7:
  items you already answered stay open) and wrote six unclear sentences to Sonnet's none, and it is slower (it thinks for
  about 500 tokens on every call, EVAL-verdicts.md). Your words are read on Sonnet too: they need the closes right and
  fast.
- **Prompt: v2** (the app's, `RouterItemsPrompt.turn` / `.message`; `evals/router/items/prompts/system-*-v2.txt`). v2 was
  written from v1's errors on the first set: your words close an item they settle without naming it (you agree, reject,
  redirect, or ask the agent to do it), a retracted know is obsolete, one item per open decision, and no item for work the
  agent handles itself (an implementer, a merge agent, its own next pass), offers it makes without stopping, or steps it
  logs for another agent. On the held-out set it is better on every count but closes (one wrong in 57): precision 0.90 →
  0.93, recall 0.98 → 0.99, missed closes 14 → 12.
- **Duplicates**: one in 155 on the first set, none held out; 37 items were merged (restated, age reset) in each set.
- **Mid-run wakes** are read like any turn, with "It was started by a notice, not the user" and what woke it.

## Mid-run inputs (2026-11-13)

A real miss: the agent ended its turn with "Do you want me to make that change?" while a subagent it delegated to still
ran, so T3 showed the thread working and no turn end was read until your next message. Two inputs fix it
(`RouterItemLedgers`): a turn that ends while its background work goes on is read as it ends (`waiting` below), and a
whole message the agent posts while its run goes on is read as it lands (`said`: keyed by T3's message id, one read in
flight per thread, at most one a minute, the newest waiting one read at the gap's end or when the run ends; read with
its own prompt, `RouterItemsPrompt.said`, which finds items and writes no line).

Two more held-out sets (`export.py --said` and `--said --waiting`, excluding every step of the two sets above):
**held-said**, 15 sequences, 84 steps, 33 mid-run reads (6 that end on a question, all of them the agent asking itself);
**held-wait**, 7 sequences, 43 steps, 18 turns that ended while background work went on, 7 of which ask you.

| set, config | reads | added | precision | missed | recall | false | wrong kind | closes | wrong closes | missed closes | bad sentences |
|---|---|---|---|---|---|---|---|---|---|---|---|
| held-said, said v1 | 82 | 35 | 0.86 | 0 | 1.00 | 5 | 2 | 11 | 0 | 1 | 3 |
| held-said, **said v2** | 82 | 36 | 0.86 | 0 | 1.00 | 5 | 1 | 9 | 0 | 4 | 1 |
| held-wait, **said v2** | 42 | 25 | 0.84 | 0 | 1.00 | 4 | 0 | 4 | 0 | 3 | 0 |

- **Mid-run reads alone** (held-said): v1 added 11 items, 3 false and 2 of the wrong kind (a default the agent takes
  unless told otherwise read as a Decide, a workaround it runs itself as a Know); **v2** (one rule more: its run goes
  on, so a question is a Decide only when the work it is about waits for the answer) adds 10, 1 false, 1 wrong kind, no
  miss, no wrong close. The turn and message reads in these sets are unchanged; their counts move between runs by the
  model's variance.
- **Waiting turns** (held-wait): 11 of the 18 leave or restate a Stuck, Decide or Do. Before the fix the app read none
  of them until the wake or your message.
- **No regression**: the turn and message prompts are unchanged; the first held-out set's inputs, re-dumped, are
  identical (`parts.json`, prompts, schemas), so its scores stand (precision 0.96, recall 0.99).
- **Cost**: the owner's last 7 days have about 320 mid-run messages a day outside subagent threads; coalesced to one a
  minute per thread, about 200 to 300 reads a day at about $0.007 (held-said: $0.0061 per read), so about $1.5 to $2 a
  day more.

## Done's outcome (2026-11-13)

Since the needs-you verdict went (7535f71d), a turn's read writes Done's sentence as `line`: v3 asked for "what the turn did
and where it stands" in 12 words, so an answer read "answered the question" and a line often listed steps. Worse, a turn
that ended before T3's projection had its reply was marked read with no line, and Done said only "finished" (two of the
owner's five ledgers on 2026-11-13; fixed: the turn waits for its reply, as a projection miss, f5aaa5bc). **v4**
(`prompts/system-turn-v4.txt`, the app's): `line` is the outcome, key fact first, the answer itself for a question (at
most 16 words); `detail` one or two sentences it leaves out; `facts` at most 3 chips the reply states that code can't know
(tests and their result, a version released, a number), each `kind` tests or note and a `tone`. Code adds the pull
requests and the diff, and the agent's last message is the source (`RouterThread.summary`).

**30 real finished turns** (`outcome.py pick`: the held-out set's turns, one per thread over 29 threads, read with nothing
open as the app reads them). A blind Opus judge sees the redacted parts and the two outcomes in random order:

| prompt | accurate | useful (1-5) | useful 5 | useful ≤ 3 | preferred | details | facts | line words | $/read | end p50 |
|---|---|---|---|---|---|---|---|---|---|---|
| v3 (line) | 30/30 | 3.60 | 1 | 13 | 3 | - | - | 12.6 | 0.0098 | 4.0 s |
| **v4 (outcome, detail, facts)** | 29/30 | **4.50** | 17 | 2 | **27** | 29 | 28 | 14.8 | 0.0125 | 4.9 s |

- v4 wins 27 of 30 (no ties). Its lines carry the result ("disk has 7.3 GB free of 926 GB; about 150 GB of dev build and
  cache data is clearable" against "audited disk usage; disk nearly full…").
- One inaccuracy: a detail said a rail card's discount covers one train type only, where the reply also listed another.
- Still loose: nearly every turn gets a detail (29 of 30; the rule says "only when it adds something"), and a few chips
  repeat the line ("7.3 GB free of 926 GB"). v3's line sometimes named what waited on the owner ("30 and 34 await you");
  v4 leaves that to the open items, which the same read writes.
- The two extra fields add about $0.003 and 0.9 s at the end of the read; the line still streams first (its field
  comes before them).

```sh
python3 evals/router/items/outcome.py pick
FJORD_ITEMS_EVAL_DIR=$PWD/evals/router/items/data/outcome swift test --filter ItemsEvalDump
python3 evals/router/items/outcome.py run v4
python3 evals/router/items/outcome.py run v3 --system evals/router/items/prompts/system-turn-v3.txt --schema evals/router/items/data/held/schema-turn.json
python3 evals/router/items/outcome.py judge v4 v3 && python3 evals/router/items/outcome.py score v4 v3
```

## What it still gets wrong

- **Missed closes** (12 of about 70 that should close, held out): mostly your words settling more than the item they
  name ("All good, make a new release" answers two questions; only one closed), or settling a know by correcting it ("I
  travel alone" makes a price for two stale), and a later turn making a caveat stale without saying so (the full checks
  passed). They stay open until the next read or your Done; the other way round is rare (one wrong close in 57: a question
  back about the token was taken as an answer).
- **False items** (11 of 160): a Know or Do for work the agent runs itself and promises to report (a calibration run,
  its own reviews before it merges), and unrequested offers ("If you'd like, I can…") read as a Decide.
- **Missed items** (one held out): a question the read merged into a know, which hid it as a decision.

## Latency, cost, and how often

- **Latency**: the read whole at about 4 s p50, 5 to 7 s p90; what closes lands first (its field comes first), then what
  is new, then the line streams.
- **Cost**: about $0.008 per read as `claude -p` reports it (about 3,200 input tokens, mostly the cached system prompt and
  Claude Code's own; about 200 output tokens). The app logs each read under the role `items` (Settings' usage).
- **Reads per day**: `calls.py` replays the owner's last 7 days: **262 turn ends a day** on average (389 on the busiest),
  and 98 messages of yours, of which about 70 % come with something open (the replay reads 70 to 77 % of them):
  **about 330 reads a day, about 500 on the busiest**, about **$2.6 a day** ($4 at most), out of the subscription. The
  finished-turn verdict it replaces was one Sonnet call per turn end at about $0.01, so the difference is your messages'
  reads, about $0.6 a day.

## Rerunning

```sh
python3 evals/router/items/export.py                               # data/cases.json (45 sequences, 7 days)
python3 evals/router/items/export.py --seed 7 --days 10 --out evals/router/items/data/held/cases.json --exclude evals/router/items/data/cases.json
FJORD_ITEMS_EVAL_DIR=$PWD/evals/router/items/data swift test --filter ItemsEvalDump     # prompts, schemas, parts.json
python3 evals/router/items/run.py v2-sonnet                         # the app's prompt -> data/runs/v2-sonnet
python3 evals/router/items/judge.py v2-sonnet && python3 evals/router/items/judge.py score v2-sonnet
ITEMS_DATA=$PWD/evals/router/items/data/held python3 evals/router/items/run.py ...       # the held-out set
python3 evals/router/items/calls.py                                 # reads a day
python3 evals/router/items/export.py --said --seed 7 --days 10 --out evals/router/items/data/held-said/cases.json --exclude evals/router/items/data/cases.json evals/router/items/data/held/cases.json
python3 evals/router/items/export.py --said --waiting --seed 7 --days 21 --out evals/router/items/data/held-wait/cases.json --exclude ... held-said/cases.json
```

`run.py NAME --model M --turn-system FILE --message-system FILE` tries another model or prompt. Sequences already run are
skipped, so a run resumes.
