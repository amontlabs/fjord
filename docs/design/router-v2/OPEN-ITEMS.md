# Open items per thread (owner-approved design, 2026-11-13)

## Problem (today)
- "Needs you" is judged from the latest finished turn's reply only; nothing is kept across turns.
- Sending a message puts the thread back to Working and the needs-you item vanishes, remembered nowhere.
- A turn that ends and is woken again at once (a background agent finishing) has its read cancelled on run start: what it asked or told is never shown.
- The next finished turn is judged alone: an earlier unanswered question is lost unless the agent repeats it.

## Model
- Each thread keeps a ledger of open items. Kinds (four, no more):
  - **Stuck** (red, Needs you, first): blocked or struggling while running: loops, the same error again, missing access, says it can't go on. (Code's "Stopped" for a failed/interrupted run stays.)
  - **Decide** (amber, Needs you): a question or a choice.
  - **Do** (amber, Needs you): a step only the owner can take.
  - **Know** (blue, Done / worth a look): something to know.
- One read per input: every turn end (never cancelled when the run restarts) and every owner message. Input = the thread's open items + the new input (turn reply, or the owner's words) + small context. Output per item: keep / close (with a short "how": answered by your message, done by the agent, obsolete) / merge (same as an open item, restated: no duplicate, age resets) / add new.
- Cache: each turn and message is read once, keyed by its id; never re-read history; ledger persisted per thread; cleared on Settle. No word rules: the model decides.
- Not done: guessing items the agent never wrote.

## Page
- One block per thread, never twice; placed in the section of its most urgent open item (Stuck > Decide/Do > Know > Working); its other items travel with it.
- One item: the line is the item (as today). Two or more: the thread's line becomes a quiet header (name, working dots + summary if running, project, age) and each item is its own indented line (kind mark, kind word, sentence, age). All readable without hover.
- ↑/↓ walks threads and items. An item's card: its options, Done (Revert). The thread's card: working summary timeline.
- Working count includes threads shown elsewhere, faintly, so counts add up.

## Instant feedback
- Owner sends: the words appear at once as a line in the block (`↑ "…" · sent`); every open item gets the sheen and the header the Fjord logo ("being re-checked"); nothing reads settled until the read lands.
- New turn: header pulses once, items sheen, a faint "reading the new turn…" placeholder where new items land.
- Read lands: closed items strike briefly with their "how", then fold away; new items fold in with a brief highlight; merged ones stay and reset age; unchanged lose the sheen.

## Process
Real-app shots + a short recorded beat (send → sheen → resolve) for the owner to approve before wiring to real threads; eval on real threads with mid-run wakes.

## Look (2026-11-13, for approval)
Demo store only (`RouterDemoItems.swift`), not wired to real threads. Shots `v2-items`, `v2-items-card`,
`v2-items-checking`, `v2-items-resolved` (light and `-dark`); storyboard beat 45 (`--router-v2-demo --beats 45`). The
look is written down in DESIGN.md 1.15.

## Wired (2026-11-13)
Real threads now: `RouterItemLedgers` (the engine) through `RouterRecords`, Sonnet reads (`RouterItemsPrompt`), measured on
real sequences in [EVAL-items.md](EVAL-items.md). The per-turn needs-you verdict is gone. DESIGN.md 1.15 "The engine".
