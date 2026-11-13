# Router v2 · live check on the owner's T3 (track 9a, read-only)

2026-11-12, about eight minutes. The debug build (`swift build`, `.build/debug/Fjord --open`, its own `Fjord Dev` support
folder, the Keychain's T3 token) against the real T3 server. Nothing was sent, answered, settled, snoozed, stopped,
started or renamed; the only input was pressing the project pills and the All pill (AX press by pid), and the quit
through the app's own menu. T3's own data was read from its SQLite file, read-only, for the comparison.

The window captures taken during the check showed the owner's real threads and were removed (FINAL-REVIEW #19); this
note keeps the findings only, with no thread, project or verdict text.

## What matched

| Check | Result |
| --- | --- |
| `--t3` read-only path | Linked; first shell in about 6 s (debug). |
| Threads on the page | The lines plus the "finished earlier, not settled" line equal T3's top-level unsettled threads exactly; subagent threads are left out. |
| Groups and counts | Needs you, Done and Working counts, the header pills, "All" and the sidebar badge (= Needs you) all equal the lines. |
| Nothing settled appears | No settled thread on the page; none settled by T3 during the run reappeared. |
| Project pills | Filtering to a project shows its lines, "Nothing needs you in <project>." and its housekeeping line; "Clear esc" shown; All restores. |
| Sample vs T3 (every thread in play) | Working: one running thread, and one whose run completed while a background subagent still runs (the page says working, "background: …": right). Done, Needs you and the folded threads match T3's states. Ages match T3's `updated_at`. |
| "new" dot | Only on the thread with unseen activity. |
| PR states | No thread in play had a linked PR in T3: not exercised live. |
| Errors | None in stdout, no crash report, no refusal. |

## Verdict timings (second launch, verdicts file moved aside, polled every 0.2 s)

- Launch to first paint of the lines: about 3.9 s (T3's first shell).
- First verdict 4.5 s after launch, second 8.3 s; names landed with the first write; idle working threads get no
  verdict (right).
- On a cold launch the lines wait about 0.6 to 4.4 s after the page shows them for a verdict.
- Streaming was not observed (no real turn ended during the run): "a real turn end moves a line and streams a verdict"
  is still open.

## Problems seen (worst first)

1. **Placeholder state on a cold launch**: "Nothing needs you." showed while verdicts were pending, then a needs-you
   thread jumped from Done to Needs you. Names were cut at about 22 characters with a half-filled shimmer disc though
   the row had room.
2. **Working lines show raw tool commands** in monospace (a `grep …`, a heredoc). The planned fallback without T3's
   to-do setting, but a shell command is not a status. A "background: …" line reads well.
3. **A project pill shows the folder's name** where T3's project has another title.
4. **Verdict and name wording is not stable between launches** for the same thread, and a completed thread with no
   reply got a vague line (FINAL-REVIEW #2: its verdict was asked without the reply).
5. **The status icons at the top right do not filter** when pressed: inert buttons, or legends exposed as buttons.
6. **Cache is per support folder**: the dev build's `router-verdicts.json` is its own; the installed copy keeps its own.

## Not checked

Streaming of a verdict on a live turn end, a real answer going out (not allowed), the `thread.pull-request.link`
call, Needs-you cards for a real question or plan (none existed), keyboard use of the page, the History drawer. No Fjord
process of this check was left running.
