# N4a: what the tool-using agent looked up (2026-11-08)

Aggregates only. The `agent` decider's tool calls were not stored, so they were replayed from the response cache (`data/cache/n3`, no new API calls) with a throwaway script, and compared with `sthink` (same model, same board, no tools) against the clean gold. Goal: find what a single-call router's context must hold so it never needs tools.

## Scope and method
- **Dev:** 300 moments; the agent used tools on 152 (51%): 74 follow-ups, 70 new work, 8 ambiguous. `sthink` ran on dev only.
- **Test:** 164 moments with agent runs, 64 used tools, 46 of them in the 112-moment judged subsample. Test has no `sthink`, so it is used only for the shape of the lookups.
- **Right/wrong is the raw answer, ignoring confidence bars.** Follow-up counts as right if the session is a gold thread, new work if the project is the gold project. "Fixed" means agent right and sthink wrong, "broke" the reverse. This is generous to the agent: at the default bars most of its answers would still be "ask".
- **Board today:** every live thread, plus finished threads idle under 12 h (3 per project, 20 in all). On average that is 6 shown threads of about 112 known (p90 219), and the whole prompt is about 2,100 tokens (p90 3,000). The "last threads" line lists the 3 newest titles per project.
- Classification of reads and queries is mechanical (token overlap, age, rank), so it is approximate.

## 1. What the agent did
- 424 tool calls over 216 moments: 231 searches and 193 reads. 5 reads used an id that doesn't exist.
- Call patterns: search only 35, read only 27, read read 24, search then read 23, longer chains the rest. Mean 2.0 to 2.4 calls per moment.
- Cost and time per tool-using decision: $0.033 vs $0.009 for sthink, 7.6 s vs 3.2 s.
- **Query types** (231 queries, not exclusive):

  | Type | Count |
  |---|---|
  | words copied from the message (70%+ of query words) | 132 (57%) |
  | partly from the message (30-70%) | 65 (28%) |
  | vocabulary not in the message | 34 (15%) |
  | 6 or more words (phrase-like) | 72 (31%) |
  | a project name | 32 (14%) |
  | PR or number | 29 (13%) |
  | file, identifier or code-like token | 27 (12%) |

  Most searches are the message itself: BM25 over the message would reproduce about 85% of them. Only about 15% (34) needed a different vocabulary (a feature name or a synonym the agent inferred).
- **Reads (193):**

  | Read thread | Count | Idle time (median) | Gold thread | Became the final answer |
  |---|---|---|---|---|
  | on the board | 147 (76%) | 2 min | 59 | 99 |
  | off board, finished more than 12 h ago | 31 | 39 h | 8 | 19 |
  | off board, finished under 12 h but beyond top 3 per project or the 20 cap | 10 | 3 h | 6 | 9 |

  So 24% of reads (41) were of threads the board hides, and those reads were disproportionately useful: 28 of 41 became the answer. No read was of a live thread that was hidden.
- **Age of every gold thread the agent read:** 129 reads overall were under 1 h idle. For the 67 reads of a gold thread of a follow-up, 66 were within 24 h and all within 72 h. 59 of 67 were in the top 3 threads of their project at any age, and 63 in the top 5.

## 2. Was the gold thread even visible? (all 154 dev follow-ups, tools or not)
- Shown on the board: 140 (91%).
- Not shown: 12 (8%). 6 were finished under 12 h ago (1 to 3 h idle) but beyond the 3 per project or the 20 cap, and 6 were finished 15 to 26 h ago. All 12 had tool use, and every one was found and answered right by the agent: all 7 off-board gold reads in the fixed set.
- So the hidden-thread loss is small in count (8% of follow-ups) but fully recoverable by a wider list.

## 3. Fixed and broken by the lookups (dev, sthink vs agent, raw answers)

| | Follow-ups | New work | Ambiguous |
|---|---|---|---|
| both right | 23 | 39 | 6 |
| **fixed** | **34** | **9** | 0 |
| **broke** | **2** | **5** | 0 |
| both wrong | 15 | 17 | 2 |

Net +34 follow-ups and +4 new work, of 152 tool-using dev moments. sthink's raw follow-up right rate on these was 25 of 74 (it answered new work for 16 of 34 fixed follow-ups and ask for 11), the agent's 57 of 74. On test (sealed, no sthink) the agent got 8 of 14 follow-ups and 17 of 27 new work raw among tool-using moments.

### What the fix came from (43 fixed moments)
| Where the lookup went | Fixed |
|---|---|
| read an on-board thread only | 24 (56%) |
| read a hidden thread (older, or beyond top 3 / cap) | 10 (23%) |
| search only, no read | 9 (21%): 4 follow-ups, 5 new work |

The 5 new-work fixes by search alone are the agent confirming that no thread owns the work (sthink had hedged with ask or follow-up on those). So absence needs evidence as much as presence does.

### Which part of the read thread mattered (34 fixed follow-ups; the 23 whose gold thread was already on the board)
Message words that appear in the thread, but not in anything the board shows for it:
| Where those words are | Moments |
|---|---|
| earlier agent turns (not the latest reply the board tails to 600 characters) | 16 (70%) |
| later owner turns (not the last 3 the board lists) | 8 (35%) |
| first ask (the board shows only part of it) | 4 (17%) |
| nothing new beyond the board text: only confidence and the "continues or different deliverable" call | 6 (26%) |

For the 34 reads: overlap was also in the latest agent reply for 19, the first ask for 12, the latest owner turn for 9, and middle turns for 26 (threads have a median of 52 turns, so middle overlap is expected). In 15 of 34, sthink's `related_session` was already the gold thread and it only called it new work or ask. So half the follow-up gain is the model seeing the deliverable and status of a thread it had already picked, the other half is locating the thread. A third of the gain also lies in deliverable-level detail that a 600-character tail and a first ask don't carry.

### What broke (7)
- 5 new-work messages were pushed to a thread after reading a related one (the agent over-linked once it had read the thread; 2 of them were reads of old threads).
- 2 follow-ups lost to a wrong thread.
- So reading raises the follow-up rate but costs some new work. The context should carry an explicit "what this thread delivered and finished" signal, not only raw text.

### Both wrong (34): the lookups did not help
17 new work and 15 follow-ups. Only 3 of those moments read the gold thread, and in 7 the answer was a thread the owner last wrote in. This matches N3: the rest needs the UI context (what the owner was looking at), not text.

## 4. Missing information, ranked

| # | Missing from the board | Decisions fixed | Decisions broken | Evidence |
|---|---|---|---|---|
| 1 | The thread's body beyond the board lines: earlier agent turns (what was delivered, status, open items) | about 24 follow-up and 3 new-work fixes (read on-board) | 4 | 16 of 23 on-board follow fixes had the overlap there |
| 2 | Threads older than 12 h or beyond top 3 per project | 10 | 2 | gold thread hidden for 12 of 154 follow-ups; 41 of 193 reads |
| 3 | Confirmation that nothing owns this work (a search-by-message miss) | 5 new work (search only) | 1 | all 5 had no read |
| 4 | The owner's later turns in a thread (beyond the last 3 listed) | 8 of the 23 | n/a | |
| 5 | Over-linking guard (what a thread delivered and finished) | 0 | 5 new work broken | |

## 5. Requirements and token costs
Measured on the 300 dev boards (tokens are characters over 4):

| Req | Rule | Evidence | Added tokens (mean / p90) |
|---|---|---|---|
| R1 | A compact catalog line (id, title, project, age) for every thread idle up to **72 h**, whether or not shown (28 threads on average, p90 47) | all 67 gold reads were within 72 h; 66 within 24 h. The 12 hidden-gold follow-ups are all under 26 h | catalog beyond what is shown: 24 h 105 / 231, 72 h 313 / 551, 7 d 651 / 1,072, 30 d 1,452 / 2,987. **Take 72 h, about +310** |
| R2 | The top **5** threads per recency (or those with the best message match) in a richer form: first ask in full, a **one-line digest per agent turn** for the last ~6 turns (what it delivered), the last 3 owner turns in full, and the latest reply to 1,500 characters | 16 of 23 on-board follow fixes needed earlier agent turns; 8 later owner turns; 4 the first ask | 1 read costs 1,178 / 1,508. A 5-thread rich block of the last 4 turns each is 2,650 / 3,770; 10 threads 4,900 / 6,400. **Take 5: about +2,000 to 2,700** |
| R3 | **BM25 top 3 over all threads' text** for the message, 2 snippet lines per hit, with project and age. No second query | 57% of queries copied the message, another 28% partly. For follow-ups, the gold thread was in the agent's top 5 for 30 of 41 moments (23 at rank 1); BM25 over the full history found threads that no board line holds | about +450 (search result is about 600 for 5 hits) |
| R4 | One line per project: when the newest thread there was last active and whether it delivered, plus a "no thread matches this message" note when BM25 returns nothing | 5 new-work fixes by search alone; 5 new-work breaks by over-linking | about +100 |

Total for a tool-free prompt: about 2,100 (today) plus 310 + 2,300 + 450 + 100, so **about 5,300 tokens** (p90 about 7,000), roughly 2.5 times the current board, against the agent's mean of 1,200 per read plus 1 to 3 round trips. The agent costs $0.033 and 7.6 s per tool-using decision. At a single call with a cached system block and a changing board, the single-call prompt is about 2.5 times the sthink board and should cost about $0.015 to $0.02 and about 4 s. These are estimates, not measured on a run.

## 6. What this does not tell us
- Dev CIs are about ±10 points. 43 fixes and 7 breaks make rankings 1 and 2 firm, and the split between R2 sub-parts soft.
- Overlap by words is a proxy for "mattered"; it can't see a decision made from tone or structure. 26% of fixes had no new words at all.
- The 34 both-wrong moments, and the 6 of 14 test follow-ups the agent got wrong or left to ask, need the UI-context signal (what was on the owner's screen), not more text.
- Whether the single-call prompt, with R1 to R4, matches the agent is untested: build it as the next variant and run it on the same dev moments (sthink board plus R1 to R4), which can be scored against the same gold.
