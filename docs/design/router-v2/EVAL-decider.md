> **Superseded in part (owner, 2026-11-12):** the `launch` / `launch_words` path, its section 2 and the `launchRole` and `taken` fixes below were removed; settings are `@` pills and free text sets nothing. The open-card prior results (section 1) stand.

# Track 5 eval: the decider with `launch`, `launch_words` and the open-card prior

2026-11-12. Aggregates only; nothing here is a real message. Code: `evals/router/t3/w2run.py` (300 moments, prior runs),
`evals/router/w2/launch_eval.py` + `launch_drafts.py` (settings asides), `evals/router/w2/typing_pauses.py` (pauses). Data stays in
the gitignored `evals/router/t3/data/` (`n4_w2*_dev.jsonl`).

**Method notes that matter for reading the numbers**
- The API credits are out, so every call here went through `claude -p` exactly as the app does (`--tools "" --setting-sources "" --json-schema …`, effort high, thinking off), 3 at a time. N4's baseline (`ctx`, 2026-11-08) ran on the raw API. Same blocks A–F, same moments, same gold, same scoring (`n4score.py`); the only differences are the shipped additions (`launchRole` appended to the system prompt, `launch`/`launch_words` in the schema, enums from this install's four models) and the transport. One run each, so some of every difference below is run-to-run noise.
- The Python blocks are N4's, not the Swift builder's, so the settled/read-state lines the Swift `DeciderContext` added after N4 are not in this eval (the history has no read state). It measures the schema and the prior line, not the whole shipped prompt.

## 1. The 300 dev moments against N4

Bars as shipped (idle 0.90, running 0.90, new work 0.70, p_new 0.70; N4's 1% bars), weighted to the natural ratio, day-bootstrap CIs:

| | new right | new pushed | follow right | follow wrong thread | follow to new | pooled wrong | wrong project |
|---|---|---|---|---|---|---|---|
| N4 `ctx` | 55.5% (46–65) | 0.7% | 59.3% (49–68) | 0.3% | 0.3% | 1.4% | 1.0% |
| **`w2`** | 56.9% (49–67) | 1.5% | 51.0% (42–61) | **0.0%** | **0.0%** | **0.7%** | **0.6%** |

With CV-fitted bars at 1% / 2% (N4's own table): `w2` new right 70.8 / 70.8 (ctx 59.1 / 67.9), follow right 58.6 / 72.6 (ctx 60.3 / 70.3), follow wrong thread 0.3 / 0.7 (1.3 / 0.7), follow to new 0.0 / 0.0 (0.7 / 0.7), new pushed 2.9 / 5.8 (0.7 / 3.7). Paired `w2 − ctx`: new right +11.7 (+7…+17) at 1%, +2.9 (−1…+10) at 2%; follow right −1.7 / +2.3 (both CIs span 0).

Bar-free top-1 (what the model picks whatever its confidence): new right 70.8% (ctx 68.6), **follow right 93.3% (ctx 89.6)**, follow wrong thread 6.7% (8.7), follow to new 0.0% (1.4), **new work pushed into a thread 21.9% (16.8)**.

Idle-bar sweep (running 0.90, new 0.70, p_new 0.70), follow right / wrong thread / pooled wrong:

| idle bar | ctx | w2 |
|---|---|---|
| 0.95 | 29.3 / 0.3 / 1.4 | 21.0 / 0.0 / 0.7 |
| 0.90 | 59.3 / 0.3 / 1.4 | 51.0 / 0.0 / 0.7 |
| 0.85 | 69.3 / 0.7 / 1.8 | 66.6 / 0.3 / 1.1 |
| 0.80 | 74.3 / 1.0 / 2.4 | 72.7 / 0.3 / 1.2 |

**Gate: no loss on wrong sends. Held.** Wrong-thread sends, follow-ups sent to a new thread, wrong-project sends and pooled wrong are all ≤ N4's at every bar; thread top-1 is up 3.7 points. Two things to watch, neither a gate failure:
1. At the shipped 0.90 idle bar `w2` sends 8 points fewer follow-ups (51.0 vs 59.3, CIs overlap): its confidence on right threads is a little lower. At 0.85 it sends 66.6% for 0.3% wrong thread, where `ctx` needed 0.90 for the same 0.3%. Refit the idle bar on the first ~200 live decisions (see 4); don't change it on one run.
2. **New work started in an existing thread is up**: 1.5% vs 0.7% at the shipped bars (n.s.), 21.9% vs 16.8% bar-free, and 2.9 / 5.8% vs 0.7 / 3.7% under CV bars (2% target allows ≤ 4%). Unweighted at the shipped bars: 2 of 133 new-work moments pushed vs 1. It is the one place `w2` looks worse, and this eval can't say whether the cause is the longer system prompt or run noise. Watch `pNew`/`extends` in the decision log.

False positives on real messages: **0 of 300** moments set `launch` or `launch_words` (none of the dev messages carries a settings aside), and 0 `launch_words` that weren't a substring of the message.

Cost/latency, as the app runs it: 837 output tokens on average (the CLI reports more than the API did, 303), p50 8.6 s / p95 13.5 s with three calls in flight, measured $0.17 per call at API list price (the CLI sends the user text without cache markers, so blocks C–F are read at the uncached price; $51.63 for 300). N4's 3.4 s / $0.047 came from the raw API with markers and aren't comparable. Neither figure is from the schema change.

### The open-card prior (80 moments whose gold thread is on the live board; shipped bars)

The prior line is "The owner has the card of <id> open (<project>, <title>)." in the Now block. Three runs on the same 80:

| open card | sent right | wrong-thread sends | asked | top-1 right (bar-free) | mean confidence |
|---|---|---|---|---|---|
| none (`w2`) | 21 | 0 | 58 | 62 | 0.745 |
| the gold thread (`w2gold`) | 29 | 0 | 51 | **76** | 0.791 |
| a recent live thread that isn't the gold one (`w2wrong`) | 17 | **0** | 62 | 56 | 0.727 |

The prior moves what it should: a right card lifts top-1 by 14 of 80 and sends 8 more; a wrong card costs 6 top-1 and 4 sends but produces **no** wrong-thread send (the model asks instead). This is the risk of IMPLEMENTATION §4 item 2: it is small and fails safe. The prior stays in Sonnet's Now block only, as planned.

## 2. Settings asides (`launch`, `launch_words`)

Not 40 real drafts: real transcripts must not be committed, and none of the 300 dev messages has an aside, so `launch_drafts.py` has 40 written drafts in the owner's style (lowercase, short, a typo or two, "(use opus medium)", "use sonnet high, plan first", "full access", "opus xhigh, full access", asides at the start, middle and end) and 10 near-misses ("make the agent use opus for the subagents it spawns", "add a plan mode toggle to the composer toolbar", "full access mode is broken…", "write a system prompt that tells the agent to … plan first", a follow-up with an aside). They run on a small synthetic board (4 projects, 3 threads). Scored after `RouterLaunchCatalog.checked` (an effort the model doesn't take is dropped), three runs:

| | asides all right (settings + span) | settings exact | span right (brackets in or out) | span exact incl. brackets | **cut leaves "()" or a stray comma** | near-misses clean | span not in the draft (rewrite) | settings set on a non-new-work action |
|---|---|---|---|---|---|---|---|---|
| shipped prompt, run 1 | 38/40 | 38/40 | 40/40 | 30/40 | 13/40 | 9/10 | 0/50 | 0 |
| shipped prompt, run 2 | 39/40 | 39/40 | 40/40 | 29/40 | 14/40 | 10/10 | 0/50 | 0 |
| + the two lines in 4 | 39/40 | 39/40 | 40/40 | 40/40 | **0/40** | 10/10 | 0/50 | 0 |

- **The reading is right**: model, effort, runtime mode and plan mode correct in 38–39 of 40, never a wrong value, no setting added that the message didn't name, nothing taken for the agent in 29 of 30 near-miss runs, and the quoted span always a literal substring (the message can't be rewritten: `taken()` only cuts a verbatim span).
- **Failures**: (a) "use opus, dont edit anything" set the model but not `approval-required`, and quoted only "use opus" (runs 1–2); (b) the one near-miss that failed, a reply-shaped draft "yes go ahead (use opus medium)" on a board where a new thread was plausible, took the aside. That one was ambiguous by my construction, and I replaced it with an unambiguous follow-up, which stayed clean; (c) fixture errors of mine (Haiku has no efforts, so "haiku low" correctly yields just the model).
- **The real defect is the cut.** In 13–14 of 40 asides the model quotes "use opus medium" without the brackets around it, so taking it leaves `add a dark mode toggle to the settings page ()` in the message that gets sent. Exact quoting incl. brackets was 30/40.

## 3. What the typing pauses cost

No keystroke timing is logged anywhere (no `decider-log.jsonl` exists on this Mac yet), so this is a simulation, not a measurement: `typing_pauses.py`, gaps lognormal (median 170 ms), thinking pauses with probability 2/5/10% per key (more at spaces), message lengths from the dev moments (median 127 chars, mean 184), a Sonnet call taking 4 s. A Sonnet read is wasted when a key arrives while it is in flight. Per message, Sonnet pause `S` with the Jev pause `J`:

| thinking pauses | J / S ms | Jev reads | Sonnet starts | **Sonnet cancelled** |
|---|---|---|---|---|
| 2% | 600 / 1200 | 5.7 | 2.8 | 1.7 |
| 2% | 300 / 600 | 28 | 5.7 | 4.6 |
| 5% | 600 / 1200 | 11 | 5.5 | 4.4 |
| 5% | 300 / 600 | 35 | 11 | 10 |
| 10% | 300 / 600 | 44 | 20 | 19 |

With two guards (at least 12 characters, at least 10 new characters since the last start): S = 600 → 4.4 / 6.9 / 10.0 starts and 3.5 / 6.1 / 9.3 cancelled at 2 / 5 / 10%; S = 1200 → 2.4 / 4.2 / 6.6 starts and 1.5 / 3.3 / 5.7 cancelled. Only reads where Jev isn't sure start Sonnet (about 60% of messages by E5's 36–42% sent rate), so scale by ~0.6.

A Jev read is ~$0.00004 and 0.24 s, so a 300 ms Jev pause costs nothing but main-thread discipline (cancel on the next key, ≤ 40 reads per message in the model). A Sonnet read costs a full prefill: $0.17 each at list price as run here, or about $0.008 in the design's estimate for a warm cache; only the first has been measured. At 600 ms and an unguarded start, a typical message wastes 5–10 Sonnet calls.

## 4. Recommendations

1. **Prompt (`DeciderContext.launchRole`)**, append after the "Never rewrite…" sentence (tested: bracket residue 13/40 → 0/40, span exact 30/40 → 40/40, "dont edit anything" now read right; nothing else changed):
   > When the settings are written inside brackets or parentheses, launch_words includes the brackets, so cutting it leaves no empty or half brackets. "don't edit anything" and "ask me before editing" say the approval-required runtime mode; "just read" or "read only" do too.

   Caveat: the second sentence made one draft ("use haiku, its just a read") also set `approval-required`, which is arguably right but is a guess about a mode; drop the "just read" half if you want settings only on explicit mode words.
2. **Code, regardless of the prompt (`RouterLaunchCatalog.taken`)**: after finding the span, if the characters just outside it are an opening and closing bracket, widen the cut to include both; and if the span leaves a leading or trailing `, ` / ` - ` / ` — ` at an end of the message, trim it. Today a model that omits the brackets leaves `()` in the sent message. A `taken` test: `"fix x (use opus medium)"` with words `use opus medium` → `"fix x"`.
3. **Keep the schema as built** (`launch` then `launch_words` after `p_new`; enums from the catalog): zero false positives on 300 real moments, zero rewrites in 150 scored answers.
4. **Bars**: ship at the current 0.90 idle bar (no wrong-thread sends at all in this run). After ~200 live decisions refit with `evals/router/t3/refit.py`; the idle-bar sweep says 0.85 is probably worth 8–15 more follow-up sends at 0.3% wrong. Watch new work started in an old thread (`extends`, `pNew` in the decision log): it is the one metric where `w2` is nominally worse than N4.
5. **Pauses**: Jev at 300 ms is fine. Don't start Sonnet at 600 ms on every pause: use `S = 1200` as designed, or 600 only behind the two guards above and only when Jev's read is unsure; Return still starts it at once. Measure the real pause histogram after the first live week (the reader should log each pause, start and cancel with timestamps into the decision log) and retune `enum RouterV2`'s constants from that, not from this simulation.
6. **Next eval**: rerun `w2` once with the Swift builder's actual prompt (settled labels, read state) when a cached export of live boards exists; the 80-moment prior test should be rerun on live decisions logged with `open` set.

## Split (2026-11-13)

The shipped split prompt (`DeciderContext.split`, appended to the role) and schema (`sends` last), read from the Swift source by
`evals/router/w2/splitcommon.py`, scored after a port of the Swift checks (`splitParts`: words the message has, two places at
least, one part a place, the whole message's bars). `claude -p` Sonnet, effort high, thinking off, as the app calls it.
Aggregates only.

### (a) The 300 dev moments against N4 (`evals/router/t3/splitrun.py`)

Every dev message has one gold place, so any split is a risk. The message as sent is the split's when the checks keep one,
else N4b's rule. Shipped bars (idle 0.90, running 0.90, new 0.70, p_new 0.70), weighted, day-bootstrap CIs:

| | new right | new pushed | follow right | follow wrong thread | follow to new | pooled wrong | wrong project |
|---|---|---|---|---|---|---|---|
| N4 `ctx` | 55.5% (46–65) | 0.7% | 59.3% (49–68) | 0.3% | 0.3% | 1.4% | 0.7% |
| `w2` | 56.9% (49–67) | 1.5% | 51.0% (42–61) | 0.0% | 0.0% | 0.7% | 0.6% |
| **`split`** | 48.2% (39–61) | 1.5% | 54.3% (44–64) | **0.0%** | **0.0%** | **0.7%** | **0.5%** |

**Gate: no more wrong sends. Held.** Wrong-thread, to-new, pooled-wrong and wrong-project sends are all at or under N4's and
`w2`'s. The model wrote `sends` on **1 of 300** real messages (two parts, both new work in the same project); the checks
dropped it (one place twice), so **0 of 300 split**. Under CV bars at 1% / 2%: new right 67.9 / 67.9 (`w2` 70.8 / 70.8),
follow right 61.3 / 70.7 (58.6 / 72.6), follow wrong thread 0.0 / 0.3 (0.3 / 0.7), new pushed 2.2 / 5.8 (2.9 / 5.8). The
shipped-bar new-right dip (48.2 vs 56.9) has overlapping CIs and isn't there under CV bars; one run, so watch it in the log
rather than act on it. Cost and latency unchanged: p50 7.9 s / p95 11.6 s, $0.178 a call as run here (`w2` $0.172), 830
output tokens on average.

### (b) 44 multi-destination drafts (`evals/router/w2/split_eval.py`, `split_drafts.py`)

Written in the owner's style (lowercase, short, typos, missing apostrophes) on a synthetic board of 8 threads in 4 projects
(a T3 question and a plan waiting, one running, one stopped): 27 splits (16 two places, 4 three places, 2 shared words for two
threads, 4 with item or thread pills in the "What the owner points at" block, 1 with an answer pill taken out of the words),
6 with an unsure part, 11 near-misses (one message about two things, or a place named in passing, for **one** place). Two runs;
an Opus judge reads every part against the message (trimmed only? rephrased? intent added?).

| | run 1 | run 2 |
|---|---|---|
| splits: every destination right | 27/27 | 27/27 |
| unsure drafts right (split, the unsure part asked or at an accepted place) | 3/6 | 3/6 |
| missed splits (sent whole or asked) | 3/33 | 3/33 |
| near-misses kept whole | 10/11 | 10/11 |
| **wrong sends** (a sure part, or the whole message, where it doesn't belong) | **0/44** | **0/44** |
| parts faithful (judge) | 30/31 | 31/31 |
| rephrased / intent added (judge) | 0 / 0 | 0 / 0 |
| a word not in the message (would be dropped by code) | 0/44 | 0/44 |

- **The three unsure misses** are safe: the model kept the message whole on the thread its first part names ("tabs. and the
  spacing is off again" → Settings at 0.85–0.92, "silent. and make it faster" → Updater), below the bar or at a place the
  draft allows. Nothing was sent to a place the words don't fit.
- **The near-miss that split** both runs: "bar count: push it, and make the snapshot count use the same rule" → Bar count
  (sure, right) + new work for the second half at 0.5, so it shows as an unsure part with its places; nothing wrong goes. It
  is arguably two things; the one Return would send the guess if you don't pick.
- **The one unfaithful part** (run 1): "thanks both, ship it — bar count and the install guide" became "thanks, ship it —
  bar count" and "thanks, ship it — the install guide": "both" was cut from shared words. No word was ever changed or added;
  the Swift check would have kept the split since every word is the owner's.
- Addressing words stay in a part now and then ("bar count: push it"); harmless, worth a line in the prompt if it shows live.
- Cost: $0.41–0.68 for 44 drafts on this small board.

**Next**: rerun (a) on live decisions once the log has `type: split` entries; count how often a Return after a split is
followed by a Send again or a move of one part (the log has each send's place and whether you lit it).
