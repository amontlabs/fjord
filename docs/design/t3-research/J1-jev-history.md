# J1: what Jev was given before, how well he did, and what the T3 port dropped (2026-11-08)

Aggregates only. Sources:
- git history: `d850021d`, `46c3e9bc`, `0e142b10`, `220bca9e`, `ccebd95b`, `01c0109e`, `29f4aefb`, `76f4c4fe`, `be41ca45`, `cdcb311e`, `b2b5dd34`, `3aa32532`, and `3d01fa5e..7cb200cc`;
- `docs/design/router-research.md` and `router-redesign.md` (its runs B–F, at `b2f41700`);
- `evals/router/{README,BENCHMARK}.md`, `research/interactions.md` and `v2/DIRECTIONS.md`;
- [E3](E3-decider-t3-board.md) and [E4](E4-jev-on-t3-board.md);
- the Swift code: `RouterRoute.swift` and `RouterJev.swift` as of `3aa32532^` (the last session-era code), and today's `RouterProjectDecide.swift` and `DeciderBoard.swift`;
- the eval cache: model versions only;
- the local traffic trace: counts only.

## 0. The short answer
- **Jev on his own has never routed well on real moments.** His raw top-1 has been in the mid-40s to low 50s every time:
  - 44% session top-1 on 610 real moments with the round-3 format;
  - 53% with a one-line summary per session;
  - 52–61% at project level on the 182 with session-era options;
  - 62% at project level with full context (Nov 4);
  - today, 46% thread top-1 and 63% project top-1 on the 182.

  E4 is consistent with every earlier Jev-alone number on real data. It is not a regression in how Jev reads.
- **The idea that he can route most messages with almost no wrong sends** comes from one of two places:
  - The written cases: 360 of them, at 68.6% right and 1.1% wrong (2026-10-11, jev-1.13.0). Real moments then gave 14.5% right and 21.5% wrong on the same design.
  - Project-level scoring: on Nov 4, Jev at ≥0.7 with full context made "0 wrong-project of 53 sends". A send to the wrong thread in the right project wasn't counted as wrong there. E4 has the same 0 wrong-project, plus 3.3% wrong-thread.
- **The best the old pipeline did on real moments** was 25–30% of messages sent at 0.5–1.4% wrong:
  - sealed: 25% sent, 1.1% wrong, top-1 67%;
  - dev with labelled gold: 30% sent, 1.4% wrong; 0.5% at the 0.93 bar.

  That came from the code around Jev, not from Jev or his context:
  - a fitted fusion of his route probability with board facts (recency, running, last told);
  - two kinds of yes/no in the same call (is it the next message in this conversation, does it answer this card);
  - five gates;
  - BM25 over transcripts;
  - a refitted sureness logistic with a 0.93 send bar;
  - rules and vetoes.

  The T3 port keeps only the single route choice and reads its raw probability.

## 1. Timeline of Jev's routing designs

Sets used below:
- **Written:** synth 210 plus heldout 150 = 360 written cases.
- **Real:** 611 real moments (610 labelled). Each is a message typed inside a Claude Code session, with the board rebuilt from transcripts. Gold is strict: where the message really went.
  - realA 397 and realB 213 are split by session; realB was never tuned on.
- **Style:** 332 Router-style messages written on real boards.
- **v2 episodes:** dev 393 real submits, calib, and sealed (181 real submits).
- **The 182:** 120 dev real moments plus 62 realB moments outside the sealed and dev groups. These are project-era and T3-era runs, at project and thread level.
- **Traffic:** the app's own trace. 57 traced decisions from 2026-10-12 to 10-25; 64 routings in 11 days by Nov 2.

Model: every October eval answer in `evals/router/cache` is jev-1.13.0 (59,334 answers; 18 are 1.14.0). All of E4's 364 calls are **jev-1.14.0**. The Nov 4 runs are not in the repo cache, so their version is unknown.

### D0. First routing call, then live picks and learning (`d850021d`, 2026-10-11 00:00)
- **Options:** plain keys `o0…oN` with hints. A session and its open card were two separate options. Then a new session per project, then the intents (change Lookout, question, compound, unclear).
- **State:**
  - the message;
  - the last 10 decisions (`recentDecisions`), with corrections named;
  - `routingExamples`, introduced here: "how the user routed messages before (follow these)". At most 8 lines, newest kept, oldest first, each the words cut to 60 → target, "not" the wrong target for a correction. At most a third are confirmations: picks you sent as shown, picked on an ask, or pinned.
- **Same call:** a `rewording` yes/no (does it skip the Haiku rewording, at ≤0.1) and a `scope` score (the task's size, used to pick a model; removed the same day in `8073026e`).
- **Decision:** `RouterTools.decision`, 0.75 with a 0.3 lead.
- **Measured:** nothing yet.

### D1. Opaque keys and fenced state, the "v0" baseline (`46c3e9bc`, 2026-10-11 02:10)
- **Options:** `t1…tN`. Each criterion is fixed by Lookout ("Send to a Claude Code session: option tN, described under tN in the options state"). The session's words sit in a fenced state blob, one line per key. A card line is "Reply to the <kind> card of session “title” (project): text[:300]". A session line is "Session “title” in project P: activity or summary[:300]".
- **State:**
  - the message;
  - the last decisions, fenced (words cut to 100);
  - past routings by option key, fenced and "no longer to follow";
  - the options blob.
- **Decision:** the word-overlap veto `evidenced` blocks a sure pick that shares no word with the target, except a live-shown pick or a tagged project. Bar 0.75 with a 0.3 lead.
- **Measured** later as format `v0` on the 360 written cases: **42.9% right, 1.7% wrong session, 29.8% needless asks**. The options' order flipped the top answer in 38 of 210.

### D2. Round 1: named options, the message alone (`0e142b10`, shipped 2026-10-11 12:43; format `v3-told+g`, `swift`)
- **Options:**
  - One per destination: a card folds into its session.
  - Named by the session's title (cut to 80; `(project)` added on a repeated title; `'` added on a clash; `.` becomes `_`).
  - Criteria are `{kind: "Claude Code session", project, now, "the user last told it": text[:160] + " (Nm ago)"}`.
  - `now` is one line: "asks you a question: text[:300] Options: a / b", or "working: activity[:300]", or "finished Nm ago: last card or summary[:300]".
  - Then `new session in <p>` as `{kind, project}`, and the intents.
- **State:** `{message}` only. The global last-10 list made bare replies go to the session you last wrote to (61% against 69% right), so it was dropped. **Past routings and corrections had no measurable effect and were dropped.** Learning from corrections never came back into Jev's input.
- **Same call:**
  - a yes/no per waiting card: "is `message` the answer to `card` {session, asks[:400], options}?";
  - `gate_setting`, `gate_compound` and `gate_question`.
- **Decision:**
  - a gate at ≥0.75 decides its intent;
  - else a card check at ≥0.5 that stands out (others ≤0.4);
  - else the route's pick at its bar: 0.7 for a session, 0.6 for a new session or an intent.
  - The word-overlap veto was removed: it blocked 48 right sends and 0 wrong ones.
- **Measured:**
  - **written 360: 68.6% right, 1.1% wrong session, 1.2% wrong to Lookout's own, 11.4% needless asks**;
  - top-1 89% against 85% for opaque keys;
  - p50 0.24 s, 1–2k tokens.
  - **On real moments (built afterwards): realB 14.5% right, 21.5% wrong.** This is the origin of the "written cases mislead" lesson.
  - Bug found in round 2: `jev.py` sorted keys, and Swift sent options in random dictionary order. Shuffled for real, the decision changed on 14% of real moments. Since `220bca9e`, options go in Lookout's order: working sessions first, then the latest finished.

### D3. Round 2: `combo` plus fusion (`220bca9e`, 2026-10-11)
- **Intents reworded by who the message is for.** `question` became "a question to the Router … about the board … Not a question for a session about its own work". `compound` became "… Not one long message with several points for one session".
- **Gates:** `gate_compound2` (two or more places; several points for one session is no) and `gate_you` (it speaks to one agent as "you"). `gate_you` vetoes the intents. Real wrong sends went from 20% to 9% on that alone.
- **The next-message check:** a yes/no for each of the 3 latest finished sessions. "Is `message` the user's next message in `conversation`?", where the conversation is [{user: last told[:300]}, {session: last said[:400]}]. When one answer stands out (≥0.5, ahead by 0.3) and the route agrees, reads unclear or is under 0.4, it sends there. It was right 91 of 95 times when it fired.
- **Fusion:** a conditional logit, P(dest) ∝ exp(w·x), over Jev's log p, recency ranks `fin0`–`fin2`, `run`, the card check, `told0`, `nxt`, Jev's `unclear` mass times recency, and the gates. Then a logistic sureness on the moment. The rules' send stands when the fusion agrees. Otherwise the fused pick is sent at sureness 0.9, for 3 words or more, and never to an intent.
- **Measured:**
  - realB: **34.6% right, 4.7% wrong**, against 14.5 and 21.5 before;
  - synth 58.6 / 1.4; heldout 68.0 / 2.0; style 69.6 / 0.9.
  - Jev's own sureness was 97% right on written cases and **63% on real** (`RouteFusion`'s comment).
  - Not enough on their own: categorical recency words, a `latest` field (Jev obeys it: 32% wrong on realB), richer recent context (first ask, last 2 paragraphs: +4–5 top-1, within noise, +40% tokens), fewer options, a second verification call.

### D4. Round 3: BM25, the rules guard, short replies (`ccebd95b`, 2026-10-11; `combo-o` + `final3`)
- **BM25** between the message and each session's transcript turns, read while Jev answers. Fusion weights: the last answer +1.11, older turns (halving with age) +1.36, what you last told it −0.84 (later −0.64), the title −0.57. **Alone, BM25 names where a real follow-up went 54% of the time; Jev managed 40–48%.**
- **Rules guard:** a rules' send needs the fused pick to agree at sureness ≥0.6. The rules' path had made 24 of the 25 real wrong sends; the fused pick at 0.9 was right 78 of 79 times.
- **Short-reply rule:** under 3 words, sureness ≥0.95, and the session's last message asks or proposes something.
- **Ask card:** 4 options; the right one is on it 79–89% of the time.
- **Measured** (right / wrong):

  | Set | Right | Wrong |
  |---|---|---|
  | realA | 37.5% | 3.5% |
  | realB | 40.7% | 2.8% |
  | synth | 65.2% | 1.4% |
  | heldout | 72.0% | 2.7% |
  | styleB | 71.4% | 0.0% |

- Dead ends:
  - contextual calibration;
  - averaging two option orders;
  - a Haiku cascade on the asks (as wrong as right on real moments);
  - per-candidate checks.
- Promising, never built: a per-user refit from your corrections (late real wrong sends 4.5% → 2.3% in replay).

### D5. Round 4: v2 episodes, refit on real moments only (`fdb4eb2f` … 2026-10-12/14)
- Same request, plus the capabilities wording of `change_fjord`/`gate_setting` (+~150 tokens; `capabilities-o`, then archive and reopen).
- Six fusion weights and the sureness logistic refit on real moments only. Real top-1 +4.3 points (CV), 63.1% → 67.4%. The send bar went to **0.93**.
- **Measured:**
  - dev real, labelled gold: 1.86 loss per message against 2.05 for always asking; **30% sent, 1.4% wrong**; 0.5% wrong at the 0.93 bar.
  - calib: wrong sends 4.2% → 2.4%.
  - **Sealed** (read once): real 2.20 loss against 2.09 for always asking; **25% sent, 1.1% wrong, top-1 67%**, card hit@4 84%. Level with always asking.
  - On 393 replayed submits: top-1 69.2% at session level, **83.0% at project level**.
- Tried in this round and kept out of Jev's input:
  - a shortlist of options: −21 to −36% tokens, but 2–3 more wrong sends;
  - two wordings in one call;
  - a running session's last answer for BM25.

### D6. The whole-life line (2026-10-21, `12254f0a`; eval only, never shipped)
- One Haiku line (≤300 characters) per session option, `what it has been about overall`. The production form is a root rewritten from per-turn leaves.
- On 610 real moments, **Jev's raw top-1 went 44.3 → 53.1** (+8.9, CI +5.7 to +11.6):

  | Variant | Top-1 change |
  |---|---|
  | root line (production form) | +8.9 |
  | the latest turn's leaf alone | +6.6 |
  | a shuffled control (another session's line) | −6.1 |

  realB: 48.8 → 53.5. Right sends went up only with a refit; with the shipped weights, wrong sends rose from 3.1% to 3.9%. +18% tokens (3.1k → 3.7k). **This is the one context change that measurably lifted Jev's own ranking on real data.**

### D7. New work against the latest session (`249eeb3e`, `cdcb311e`, 2026-10-25)
- `new` weight 0.66 → 1.5.
- A session idle 12 h or more, and not waiting, loses every recency feature.
- A session beyond the 20 latest is offered only while its card waits on you.
- The focus sentence became "A message that starts a task none of the sessions has been doing goes to a new session in its project…". That is today's `routeQuestion`, word for word.
- **Measured:**
  - dev real: sent right 87 → 100, wrong 4 → 4;
  - real moments with a new session as gold: Jev's fused pick was new for 9 of 20, but only 1 of 20 was sent.
  - your traffic (18 asked again): 12 picks right, 0 sent wrong.

### D8. claude.ai projects era (Nov 4: runs B–F in `router-redesign.md`, shipped as `b2b5dd34` and `3aa32532`)
- **Run B (Jev + projects):** session-era options, plus a `claude.ai project` option per project listing its 6 latest titles. The decision is Jev's choice alone at 0.7, with no fusion.
  - project top-1: dev 58%, realB 61%;
  - without the project options (run A′): dev 52%, realB 60%.
- **Run D (full context):** every session option carries C's lines:
  - "running/idle, age ago";
  - "doing: [:240]";
  - "summary: [:300]";
  - "you last told it (age ago): [:200]";
  - "its last answer: tail 600";
  - "waiting (kind): [:300]".

  Median 3.6k tokens. On the 182: **project top-1 62%**, 29% sent at 0.7, 0 wrong-project of 53 sends. Session-level wrong sends were not scored. On realB, session top-1 was 42%. "The gap to Sonnet is the model, not the context" (D − B: +2 on top-1).
- **Run E (Fable's recipe: most recent first, a one-line "just doing / done" per option, last-told only for the top 3):** Jev got worse: dev project top-1 49% (−12), realB 52%, session top-1 27–34%.
- **Run F (shipped):** Jev with D's context answers at ≥0.7, else Sonnet. On realB, project top-1 95% and session 79%, the same as Sonnet. Jev answered 23% of messages (32% on dev). The 0.7 bar was set as "the lowest with no wrong Jev answer on dev", at **project level**.

### D9. T3 port (`3d01fa5e..7cb200cc`, E4 2026-11-08)
- Covered in section 2.
- **E4, 182, jev-1.14.0:** project top-1 60–63%, **thread top-1 46%**, best place 57–59%, top-3 81–83%. At 0.70 it sends 21–23% with 3.3% wrong-thread and 0 wrong-project. It picks an intent on 54–58 of 182 moments.
- In the app today, Jev is used only when Sonnet can't be called (no key, or a failed call), and then only to order an ask (`jevAsk`: three places, never a send).

## 2. What `jevRequest` sends today, against the best earlier design

The best earlier design for real moments is D5 (shipped `combo-o`/capabilities plus `RouteFusion`). D6's line is the best Jev-only lift.

| Field | Best earlier (D5, `3aa32532^`) | Today (`RouterProjectDecider.jevRequest`) | Effect |
|---|---|---|---|
| Option set | Working sessions, then the 20 most recent others (old ones dropped, a waiting card's session kept), up to 80; a new session per project; 4 intents | Board candidates: running and waiting, plus the 3 latest finished per project within 12 h, up to 20; `new in <p>` per project; 4 intents | Similar size. Gold present on 161 of 163. |
| Option order | Working first, then latest finished (14% of decisions moved with order; this order measured best) | Sorted by `minutesIdle` only, so a running thread is placed by its own idle time | Unmeasured change |
| Option name | Session title (cut to 80, `(project)` on a repeat) | Thread title, same rules | Same |
| `kind` | "Claude Code session" | "thread in a T3 project" | Vocabulary: the route instruction still says "session" |
| `now` | One line: waiting text[:300] with options, or "working: activity[:300]", or "finished Nm ago: last card or summary[:300]" | A multi-line blob: "- {hex id} \| {title} \| {status}, {age} ago", then "last message: tail 600" (else summary 300), "you last said there: [:200]", "current step: [:200]" (running only), "waiting request: [:300]" | Id and title repeated inside the criterion; last message twice as long, read from the end |
| Last told | Separate field, `the user last told it`: [:160] plus "(Nm ago)" | Inside `now`, with no age | Its age is lost |
| Whole-life or recent line | Not shipped (D6: +8.9 top-1) | None (the summary appears only when there is no last message) | Never gained |
| New-session option | `{kind: "new session", project}` | `{kind, project, about: purpose[:140] or "no description", its threads: 6 titles}` | More context. On Nov 4 (B), project lists of this kind made Jev ask more. |
| Intent wording | Round-2 wording: `question` "to the Router … not a question for a session about its own work"; `compound` "not one long message … for one session"; `change_fjord` as the capabilities text | **The pre-round-2 v0 wording** (`formats.INTENTS`, with Lookout→Fjord and session→thread): `question` "about what is going on now … not for any thread". `compound` remains, though Fjord no longer has that label. | **That wording caused `question` to catch questions to sessions at p>0.95 (real wrong 20% → 9% once fixed).** Today Jev picks an intent on 30% of moments. |
| Route instruction | `routeQuestion` (the D7 focus) | The same text: it still names `earlier messages` (absent) and "session" | Same, with the vocabulary mismatch |
| State | `{message}` | `{message}`, plus `tagged` and the unattended `note` | Same |
| Card-answer yes/no | One per waiting card (card text[:400], options) | Gone | The waiting thread's text is in `now` only |
| Next-message yes/no | One for each of the 3 latest finished sessions (last told[:300], last said[:400]) | **Gone** | The strongest single signal on real moments (91 of 95 when it fired) |
| Gates | `gate_setting`, `gate_compound`, `gate_question`, `gate_compound2`, `gate_you` | **Gone** | No veto on the intents |
| BM25 | Per field over transcripts (last answer, older turns, last told, title) | **Gone** | BM25 alone names a real follow-up 54% of the time; Jev 40–48% |
| Recency features | `fin0`–`fin2`, `run`, `told0`, `idle5u`, `fin0u`, `oldHours` 12 | **Gone.** Age appears only as text ("2h ago"), and Jev reads numbers poorly. | The main source of the round-2 gain |
| Decision | Fused P, logistic sureness, send at 0.93; rules' send only when the fusion agrees at 0.6; 3-word minimum; short-reply rule; never send to an intent | Raw Jev p: ≥t for idle, 0.90 for running (E4), or ask only (app) | Jev's raw p was 63% right on real moments even in October |
| Past routings and corrections | Dropped in round 1 (no effect); never re-added | None | None either way |
| Live pick, vetoes | `notTo` (Esc), the approval-card veto, named destinations ("tell X…") over Jev, the live-shown pick sent as shown | None (tags and pins only) | See section 3 |

What the port really reproduced: the Nov 4 run D (Jev with full context, project candidates, raw bar). E4's 63% project top-1 matches D's 62%. Nothing from the session-era stack (D3–D5) was carried over.

## 3. The as-you-type preview (the ghost chip)

**Where it lived:**
- `RouterLiveTarget` in `Sources/Lookout/RouterJev.swift` (later `Sources/Fjord/RouterJev.swift`);
- `RouterDispatcher.predict`, `liveCache`, `liveKey` and `boardRevision`;
- the chip view in `RouterComposer.swift`;
- the setting `jevReadsDrafts`.

**How it worked:**
- **Trigger** (`RouterLiveTarget.update`):
  - Jev is asked after a 600 ms pause in typing.
  - The draft needs at least 12 characters (as it will be sent, with pills written as @name).
  - Nothing is asked when something already fixes the target: an armed reply, a pinned target, or one `@project` (`plan != .classify`).
  - A new keystroke cancels the pending ask. A pick for older words stays up until the new one arrives.
- **The call** was the same routing call a send makes: the same options, gates, checks and fusion, all of section 2's left column.
- **What it showed:**
  - The chip gave the pick's title, or "New session · project" for a new session. Its tooltip described the target.
  - The page marked the card or working row the pick pointed at.
  - From `76f4c4fe` (10-23), a pick under the bar showed with a "?", marked nothing, and was not sent as shown.
  - From `29f4aefb` and `4e307a7d` (10-13), a renamed target renamed the chip without asking Jev again.
  - From `307848b5`, a pick whose card closed or whose session went was dropped, and Jev was asked again.
- **Click and Esc:**
  - Before `be41ca45`, a click fixed the target: a card's pick became the armed reply, anything else became the pinned target (logged `confirmed`).
  - From `be41ca45` (10-25), a click opened a menu of other places, his pick first, navigable with ↑↓. Picking one pinned it.
  - **Esc** waved the pick off for that draft. It wasn't shown again, and the message never went there without an ask (`notTo` forced an ask if Jev picked it again at send time).
- **"Sending the same words asks Jev nothing again":**
  - `liveCache` was keyed by the words plus the tagged projects and kept for 120 s (`liveFor`).
  - A send with a sure pick shown for those words reused that answer, with no new call and no action checks. The decision was logged `confirmed` with trace path `live`.
  - From round 4 (A7), a cached pick was reused only on the same `boardRevision`: the same open cards, running sessions, 3 latest finished and last-told session. Otherwise it was read again.
  - `forgetLive` (`5f38662d`) dropped every cached pick after a correction or a dismissal.
- **Learning:**
  - `d850021d` put corrections and confirmed picks (including live picks sent as shown) into Jev's state as `routingExamples`.
  - Round 1 (`0e142b10`, the same day) dropped them from the request: no measurable effect.
  - Later, `confirmed` and `corrected` fed only the trace and the history. The per-user refit (D4, `explore/personal.py`) was never built.
  - The live-shown pick did carry two privileges: it skipped the word-overlap veto (D1) and the permission-card veto.

**Cost.** Live predictions were most of Jev's spend: about 5 calls per message (router-research.md, "Mistakes"). Open lead 2 was to cut them with cancellation and a longer debounce.

**Accuracy.** **Never measured.**
- `research/interactions.md` C9: "prediction accuracy on drafts/prefixes: N". Round 4: "not measurable offline".
- Every offline number is for the full message, so its accuracy equals that of the full routing call (section 1, D3–D5) only when the draft is the final text.
- In the local trace (57 decisions, 10-12 to 10-25), 4 went by the `live` path, all kept. No outcome would show a silent wrong send, since the trace has no edit or override event.
- E4 adds an indirect number: Jev's ≥0.70 pick matched Sonnet's sent place 32 of 32 times. But in 5 of 6–8 cases where Sonnet asked, Jev's pick at ≥0.70 was wrong.

**Removed:** in `3aa32532` (2026-11-04), "the old session routing is gone". `RouterLiveTarget`, `predict`, the cache, the routing call, the fusion and BM25 were all deleted together. Routing became the project decider (Jev at ≥0.7 with full context, then Sonnet), which had no draft-time path. No measurement or written reason backs dropping the preview itself; it went with the code it ran on.

The T3 plan (`t3-port-plan.md` step 9; R1 §C) still describes "the live pick reads 'steer <thread> (running)'", but no live pick exists in `Sources/Fjord` today.

## 4. Why Jev is weak now: hypotheses, ranked

1. **Jev alone was never strong on real moments. The old stack's numbers came from fusion with board facts, and the port reads his raw probability.**
   - Evidence:
     - raw top-1 of 44–53% in October against 67–69% fused;
     - raw p 63% right on real moments;
     - round 2's fusion took realB from 21.5% to 4.7% wrong;
     - E4's 46% thread top-1.
   - **Test:** port `RouteFusion` features onto the T3 board for the 182. This costs no new calls for `fin0`–`fin2`, `run` and `told0` (from `minutesIdle`, the flags and "you last said there"), or for BM25 on last message and you-said. Refit with group CV on dev 120 and judge once on realB 62. Compare wrong-thread at matched send rate against Jev raw (21–23% at 3.3%) and against Sonnet b at 0.85 (37% at 0.5%). Also report the recency-only baseline (latest finished thread).
2. **The intent options went back to the v0 wording, and they drain his mass.**
   - Evidence:
     - `question` worded "not for any thread" is the text that caught questions meant for sessions at p>0.95;
     - E4 has 54–58 intent picks out of 182, and all of them are misses;
     - `compound` is still offered though Fjord has no such label.
   - **Test:** on the 182 with 2 samples, compare today's request against (a) the round-2 `intentCriteria` with `compound` dropped, (b) no intents at all (they are never taken), and (c) (a) plus `gate_you`. Read best-place and thread top-1, intent picks, and wrong-thread at each bar. That is about 1.1k calls, roughly $0.15.
3. **The same-call yes/no checks are gone: next-message for the 3 latest, and card-answer for waiting threads.**
   - Evidence: next-message was right 91 of 95 times when it fired, and recency is where real messages go.
   - **Test:** add `next0`–`next2` ([you last said there [:300], last message [:400]]) and a check per waiting request to the same call. Score combo's policy (≥0.5, lead 0.3, route agrees or <0.4) alone and fed into hypothesis 1's fusion. One call per moment.
4. **The criterion shape: one multi-line `now` with the hex id and title repeated, a 600-character tail, last-told without its age, and "thread" where the instructions say "session".**
   - Evidence: format changes moved Jev ±10 points before. Run E lost 11–12 points, and the order bug moved 14% of picks. Today's `now` is neither the October shape nor run D's.
   - **Test:** an A/B on the 182 with E4's harness:
     - (a) the October shape: `now` one line [:300] plus `the user last told it` [:160] with its age;
     - (b) today's lines without the id and title line;
     - (c) "thread" replaced by "session" in the kind, or `routeQuestion` reworded to threads with `earlier messages` removed.
5. **No summary of what each thread is about.**
   - Evidence: D6's root or leaf line was the only measured lift in Jev's own ranking (+6.6 to +8.9 on 610 real, +4.7 on realB). T3 threads have a title and a last message, and the summary is used only when the last message is empty.
   - **Test:** a Haiku leaf per finished turn, or reuse the brief's per-thread line if it exists, put in a field `what it has been about`. Rescore top-1; it needs a refit (hypothesis 1) before any send.
6. **Option order and model drift.**
   - Evidence: the port sorts by `minutesIdle` only, where October's order was working first, then latest finished. Jev moved from 1.13.0 (every October number) to 1.14.0 (E4).
   - **Tests:**
     - (a) rerun the 182 in the October order;
     - (b) re-ask a sample of cached October requests (`combo-o` on realB 213, sample index 1) on today's `jev-latest`, and compare against the cached 1.13.0 answers for top-1 and calibration. This needs no new design; at about 200 calls, it separates "the model changed" from "the request changed".
7. **The gold and the set cap what any decider can show.**
   - Evidence:
     - the 182 are messages typed inside sessions, not Router traffic;
     - gold is strict, and a running thread is never gold;
     - same-title twins exist;
     - real moments have an ask agreement of α 0.25–0.38;
     - even Sonnet tops out at 75% thread top-1.
   - **Test:** log live T3-era decisions (request, Jev's answer, outcome, edits or overrides) and score Jev on the Router's own traffic. Also check whether the wrong-thread sends are twins or truly ambiguous.

Not worth retrying, measured before:
- past routings or corrections in the state;
- a "latest" field (Jev obeys it);
- categorical recency words;
- richer recent context alone;
- shortlisting options;
- two wordings in one call;
- calibration against a content-free message;
- averaging option orders;
- a cheap-model cascade on the asks.
