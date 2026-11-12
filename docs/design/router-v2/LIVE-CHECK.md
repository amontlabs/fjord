# Router v2 · live check on the owner's T3 (track 9a, read-only)

2026-11-12, 21:17 to 21:25. The debug build (`swift build`, `.build/debug/Fjord --open`, its own `Fjord Dev` support
folder, the Keychain's T3 token) against the real T3 server. Nothing was sent, answered, settled, snoozed, stopped,
started or renamed; the only input was pressing the three project pills and the All pill (AX press by pid), and the
quit through the app's own menu. Window-only captures (`screencapture -l<window id>`): `live-check/*.png`.
T3's own data was read from its SQLite file, read-only, for the comparison.

## What matched

| Check | Result |
| --- | --- |
| `--t3` read-only path | Linked, 525 threads, first shell in 5.96 s (debug); lists the 2 working ones. |
| Threads on the page | 4 lines + "3 finished earlier, not settled" = 7. T3 has 1267 live threads, of which 742 subagent threads (left out) and 7 top-level unsettled: exact match. |
| Groups and counts | Needs you 1, Done 1, Working 2; header pills 1 / 1 / 2 and "All 4"; sidebar badge 1 (= Needs you). All equal the lines. |
| Nothing settled appears | No settled thread on the page; no thread settled by T3 during the run reappeared. |
| Project pills | lookout 1, microsandbox-workspaces 2; filtering to lookout gives "Nothing needs you in lookout." + its working line + "1 finished earlier"; "Clear esc" shown; All restores (`03`, `04`, `08`). |
| Sample vs T3 (all 7 in play; fewer than 10 exist) | Working: the colour-highlights thread (T3 run `running`) and the Silo handoff (T3 run `completed`, but a background subagent still runs: the page says working, "background: Draft atelier design overview"; right). Done: Linear account access (11 h, completed). Needs you: upstream issue reports (6 open PRs). Folded: the ski-trip costs, the Silo walkthrough video, the Router-respects-settled thread (all completed, unsettled, days old). Ages (11 h, 1 m, now) match T3's `updated_at`. |
| "new" dot | Blue dot on the Silo handoff line in every capture (unseen activity); not on the others. |
| PR states | No thread in play has a linked PR in T3, so nothing to show; the verdict's PR line (6 open) is from the agent's own text. Not exercised live. |
| Errors | None in stdout (hub-frame lines only), no crash report, no refusal. |

## Verdict timings (second launch, verdicts file moved aside, polled every 0.2 s)

- Launch to first paint of the lines: about 3.9 s (the first shell took 6 s in `--t3`, so it is T3's shell).
- First verdict (needs-you thread, 6 PRs): 4.5 s after launch; second (Linear): 8.3 s. Names landed with the first
  write at 3.9 s; the two idle working threads never get a verdict (right).
- So on a cold launch, 7 lines wait about 0.6 to 4.4 s after the page shows them for a verdict. Shot `09-t02s.png`
  shows the in-between state, `11-t15s.png` the settled one.
- Streaming itself was not observed (no real turn ended during the run; the colour-highlights thread kept running).
  "A real turn end moves a line and streams a verdict" is still open.

## Problems seen (worst first)

1. **Placeholder state on a cold launch is ugly** (`09-t02s.png`): "Nothing needs you." is shown while the verdicts
   are pending, then the needs-you thread jumps from Done ("finished") to Needs you. Names are cut mid-title at about
   22 characters with "…" and a half-filled shimmer disc, though the row has ample room. The owner can read
   "Nothing needs you" as a verdict when it is only "not asked yet".
2. **Working lines show raw tool commands** (`grep -n "projectName(of" Sources/Fjord/Store+RouterV2.swift; swift…`,
   `python3 - <<'EOF'`) in monospace. Without T3's to-do setting this is the planned fallback, but a shell command is
   not a status. The Silo handoff line ("background: …") reads well.
3. **Project pill says `lookout`, T3 calls the project `fjord`** (the folder name, `Store.folderName`). Probably
   intended, but it will differ from T3's sidebar after the rename.
4. **Verdict and name wording is not stable between launches** (the same thread: "six PRs are open upstream: review
   them, then merge" vs "six PRs open upstream: read the diffs, then merge them"; "Silo direction handoff" vs
   "Silo direction build"). The Linear thread's "no findings reported yet; nothing to act on" / "no reply or result
   shown yet" is vague for a completed thread with no reply.
5. **The three status icons at the top right (? / done / …) do not filter**: pressing them (AX press) changed
   nothing. If they are meant to be buttons, they are inert; if they are legends, they are exposed as buttons.
6. **Cache is per support folder**: the verdicts persisted in `Fjord Dev/router-verdicts.json` (written at launch), so a
   second launch re-asked only because the file was moved aside; the owner's installed copy keeps its own.

## Not checked

Streaming of a verdict on a live turn end, a real answer going out (not allowed), the `thread.pull-request.link`
call, Needs-you cards for a real question/plan thread (none exist right now), keyboard use of the page, History
drawer. Pre-existing: an old suspended `/Applications/Fjord.app … --router-v2-load` (pid 29151, from 7:45 PM) and the
installed app (pid 52735) were left alone; no Fjord process of this check is left running.
