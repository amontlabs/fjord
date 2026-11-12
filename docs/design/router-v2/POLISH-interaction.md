# Router v2: interaction, copy, pacing, realism review (2026-11-12)

Review of `router-v2.mp4` (3:44, all 41 beats watched at one frame a second, more around the beats), `DESIGN.md`,
`FEASIBILITY.md`, `CONTEXT.md` and `Sources/Fjord/RouterV2*.swift`. Read-only: nothing was changed.
Visual and motion polish is the other reviewer's; this file covers what the owner does, reads and is promised.

52 findings, ranked. `SF/` = `Sources/Fjord/`. Times are video times; "beat N" is DESIGN.md 6.3.
Tags: **I** interaction · **R** realism (FEASIBILITY) · **C** copy · **P** pacing · **D** consistency with the docs.

Two things need the owner's word before the fixer acts: finding 3 (is the aside sent or not) and finding 15 (does a
finished line wait for its verdict before it moves). Everything else can be fixed as written.

## Status after the fix pass (2026-11-12)

Each finding below is marked **fixed** (done as written, or to the same effect), **changed** (done another way, or decided
otherwise) or **skipped** (left as it is), with the reason. Checked with `swift build`, the `v2` stills in light and dark
(1280 × 960 now) and `--frames` captures at 10, 20 and 30 frames a second around the transitions. Nothing was filmed:
this app has no Screen Recording permission, so the recorder's changes (finding 12 of the visual review) are not verified.

| # | Status | Note |
|---|---|---|
| 1 | **fixed** | `held` is drawn: muted ink, no caret, the send button pressed with its glyph in the accent, the mark kept. Reads take 0.5 s (sure, idle thread) or 3.2 s; beat 31 shows an early Return. One rule changed: with only the skeleton shown, a held Return goes where the read is sure (as the real app does, t3-code-map §12). |
| 2 | **fixed** | With a draft ⌘1–3 never reach the Go menu; pressed during a read, the digit is kept and lit if the read lands unsure. |
| 3 | **fixed** | Owner's decision: the aside is left out only if its mark was on screen before Return; a held Return applies the settings and sends the draft as typed. Words to an existing thread are never taken. The address ("silo:") is still sent as typed. |
| 4 | **fixed** | A thread started here shows model · effort after its words while Sent (always, not only when they differ from the default), and its settings as the Working card's first footnote through its first run. |
| 5 | **fixed** | Disk test is a real stop (the connection dropped); beat 17 is a finished turn the verdict flags; a stop you asked for goes to Done, "stopped by you". |
| 6 | **fixed** | Return ignores repeats; a Stopped card's row shows “Continue where you left off.” and Return sends it; the button reads Continue. |
| 7 | **fixed** | State at 1.9 s, words from 2.0 s at one every 50 ms; four calls at once, the others wait sheening (beat 41); a turn that starts again drops its verdict (beat 33). |
| 8 | **fixed** | Tab opens the places menu (↑↓ Return) when the row asks for a place; a guess waved off is asked again when the draft grows or the selection changes. |
| 9 | **fixed** | The row says "· 1 more to answer" and the send button is dim; beat 9 is `2`, `3`, ⇧Tab, a typed answer, Return, Return. |
| 10 | **fixed** | The lit place always carries its mode, inside its chip; when the row is short of room only the lit chip keeps its project pill. |
| 11 | **fixed** | ↑ ↓ open the chip's menu and move through it; a ⇥ keycap after the chips; the mode's chip always shows (so the access menu no longer holds the mode). |
| 12 | **fixed** | Working lines are a to-do step, the agent's words or a command (mono); only Checkpoint boot has a step list. |
| 13 | **fixed** | No reason on a permission; T3's four options; the plan has two options; typed words "denies it, with your words". |
| 14 | **fixed** | T3 drops 0.3 s after Return: the failure line and the connection line come together. While T3 is away the row says so and Return keeps the words. The failure line takes the keyboard only when nothing, or the failed line, is selected; so beat 32 sends a typed message with nothing selected. |
| 15 | **changed** | Owner's decision: Done at once, then the verdict may promote it. The two moves are shown as they are (beats 14, 17), and the restart too (beat 33). |
| 16 | **fixed** | A steer takes 3 s in the demo. A thread that can't steer shows "queue after this turn" and Return queues (`steers`; written in DESIGN 1.9, no such thread in the demo). |
| 17 | **fixed** | Caption: "A PR merges: T3 sees it within a minute". |
| 18 | **fixed** | The words stay; when a verdict returns the same words nothing streams, the sheen just goes. |
| 19 | **fixed** | Opus 5.5 · High · Auto; Fable, Opus, Sonnet, Haiku; efforts up to Max. |
| 20 | **fixed** | The chips' values sheen while the draft is read again. |
| 21 | **skipped** | Picking by key position only when the key gives no letter would stop the é key from picking option 2 on the owner's AZERTY keyboard, the most used pick. Kept by position (CONTEXT: digits by position, no Shift). What leaks: a message that starts with é while a card with two or more options is open and the draft is empty. For the owner to decide. |
| 22 | **fixed** | With a draft, keycaps go disabled and a picked radio half strength. |
| 23 | **fixed** | The verdict keeps a result line; "Doesn't need me" swaps the line to it. |
| 24 | **fixed** | "Doesn't need me". |
| 25 | **fixed** | Title `Snooze`; `For 1 hour` · `For 3 hours` · `Until tomorrow, 9:00`. |
| 26 | **fixed** | The Esc keycap shows only when Esc would clear. |
| 27 | **fixed** | "Click for its card". |
| 28 | **fixed** | PR #2049 merges before the last settles; the second card is read before its ⌘⌫; the flagged build is answered in beat 32 and ends fixed. |
| 29 | **fixed** | Beat 41 waits for the last line, goes to Done's first line, then one ⌘⌫ every 0.6 s, top to bottom. |
| 30 | **fixed** | Captions lead their act by 0.2 s a word (0.8 s at least), and are 9 words at most; two beats change caption on the way. |
| 31 | **fixed** | Beat 6's run starts 1.6 s after the send. |
| 32 | **fixed** | A card your act advanced to clears its dot at your next key or pointer move. |
| 33 | **fixed** | Through 7: four calls at once. |
| 34 | **fixed** | Tooltip: "⌥Return queues after this turn". |
| 35 | **fixed** | "answers it" on a step Fjord found. |
| 36 | **fixed** | Written in DESIGN 1.5; Stop has no key. |
| 37 | **fixed** | `Edit` shows ⌘⌫ while the failure line has the keyboard. |
| 38 | **fixed** | Accepted, written in DESIGN 5.1. |
| 39 | **fixed** | A character no project starts with leaves filter mode and goes to the composer with what was typed. |
| 40 | **fixed** | The toast's clock stops on hover-in and starts again on hover-out. |
| 41 | **fixed** | Captions rewritten. |
| 42 | **fixed** | "finished". |
| 43 | **fixed** | Once T3 is back the reason is dropped. |
| 44 | **fixed** | "5 finished earlier, not settled". |
| 45 | **fixed** | Type-ahead shows as text (typing “f”), not a keycap. |
| 46 | **fixed** | Pills include projects that only have earlier finished threads (the pill reads 0). |
| 47 | **skipped** | As reviewed: faceted and correct; a tooltip only if the owner trips on it. |
| 48 | **skipped** | As reviewed: fine, kept. |
| 49 | **fixed** | Written in DESIGN 1.5 (not built in the demo). |
| 50 | **skipped** | As reviewed: by design, kept. |
| 51 | **fixed** | Written in DESIGN 5.3. |
| 52 | **fixed** | DESIGN section 7 updated. |

47 fixed, 1 changed, 4 skipped.

## Blockers: the demo promises or hides something that matters

### 1. Return before the read lands shows nothing, and real reads take 3 to 5 s (I, R)
- **Where:** beats 23, 24, 26, 29 (1:46 to 2:29). The demo reads every draft in 0.4 s (`SF/RouterV2Demo.swift:277`), so
  the case never shows. Real: 0.5 s only for a follow-up to an idle thread; a new thread, an unsure place and any
  "(use opus medium)" take a 1.2 s pause plus 3 to 5 s (FEASIBILITY gap 5).
- **Wrong:** with real timing the owner will press Return before the row has a place most of the time. The code then
  sets `held = true` (`SF/RouterV2Model.swift:744-746`, `754-759`) and draws nothing: the words stay, the row keeps its
  skeleton, the send arrow looks the same. The owner can't tell whether Return was taken.
- **Fix:**
  - `SF/RouterV2Model.swift`: make `held` observed (drop `@ObservationIgnored`). `SF/RouterV2Dock.swift`: while held,
    the draft's ink goes `CDS.Text.secondary`, the send button keeps its pressed fill and its ↩ glyph turns
    `CDS.Text.accent`; the arrow slot keeps Fjord's mark. No words (DESIGN.md allows no "reading…" label). Typing
    again cancels the hold (it already does) and the ink returns.
  - If the read lands and disagrees, the row changes and the ink returns: that is the "Return is asked again" moment.
  - `SF/RouterV2Demo.swift` `read()`: latency per case, not one 0.4 s: 0.5 s when the read is sure and the place is an
    idle thread; 3.0 s when unsure, a new thread, or the draft names settings.
  - `SF/RouterV2DemoScript.swift`: beat 26 keeps the skeleton for 3 s; add a beat after 30: type a new-thread draft,
    Return at once, the held look for about 2 s, then the line is born. Caption: "Return early: it goes when Fjord
    knows where".
  - DESIGN.md 1.9 "Reading" and section 3 "Demo latencies": write the held look and the two read times.

### 2. ⌘1–3 leave the page when the places aren't up yet (I)
- **Where:** beat 24 (1:52). `SF/RouterV2Keys.swift:77`: ⌘1–3 light a place only when the row is `.unsure`; otherwise
  they fall through to the Go menu.
- **Wrong:** an unsure read takes 3 to 5 s on real data. The owner who knows the second place is right presses ⌘2
  during that time and is taken to another page, mid-draft. Same chord, two unrelated acts, decided by a model's timing.
- **Fix:** `SF/RouterV2Keys.swift`: while the draft is not empty, ⌘1–3 never fall through. If the row is `.unsure`,
  light the place; if a read is under way (`model.reading`), remember the digit and light that place when the read
  lands unsure (drop it if the read lands sure); otherwise swallow the key. DESIGN.md 5.1 row "⌘1 ⌘2 ⌘3": "with a
  draft, never the Go menu's".

### 3. The aside: the two docs disagree, and the demo shows the riskier answer (D, R, I)
- **Where:** beats 29 and 30 (2:23 to 2:34). Caption 30: "the aside isn't sent". DESIGN.md 1.9.1 and choice 10: the
  words are removed. FEASIBILITY gap 8: "the draft is sent as typed, '(use opus medium)' included", because Haiku
  rewrote the message when asked to split it.
- **Also wrong:** with finding 1's timing, Return usually comes before the read. The code then sends by itself when the
  read lands (`SF/RouterV2Model.swift:596-605`) with the words removed (`SF/RouterV2Launch.swift:263-268`). The owner
  never saw the accent ground, so "nothing is taken silently" (1.9.1) doesn't hold.
- **Also inconsistent:** the address "silo:" is an instruction to Fjord too, and it is sent (2:32, the Sent line reads
  “silo: write the changelog for 0.4”).
- **Fix (recommended, needs the owner's yes):** remove words only when the owner saw them marked. That is: the aside is
  taken when the read had landed before Return (the ground was on screen); when Return came first, the settings apply
  and the draft goes as typed. Code: in `readLanded`, when `held` fires the send, pass `message: draft` not the
  stripped one. DESIGN.md 1.9.1 "The words that say the settings are not sent": add that rule. FEASIBILITY gap 8: the
  model still never writes the message; code removes a span the model quoted.
- **Cheaper alternative:** follow FEASIBILITY: never remove; keep the accent ground as "Fjord read this". Then caption
  30 becomes "Return starts it with those", `message` is deleted, and choice 10 in DESIGN.md 8 flips.

### 4. Nothing confirms what a new thread started with (I)
- **Where:** beat 30 (2:29 to 2:34). Caption: "Return starts it with those". The Sent line shows the words only; the
  settings are in the Sent card, which isn't open, and `runStarted` clears them 0.9 s later
  (`SF/RouterV2Model.swift:1155`).
- **Wrong:** the owner can't check which model the thread runs on, the one thing this feature is about.
- **Fix:** `SF/RouterV2Line.swift` (Sent sentence, about line 270): for a thread born here, after the words, the
  settings that differ from T3's default in footnote `CDS.Text.muted` ("Opus 5.5 · Medium"), for as long as the line is
  Sent. `SF/RouterV2Model.swift:1155`: keep `launch` through the thread's first run, and
  `SF/RouterV2Card.swift` `.working`: show `model.words(launch)` as the card's first footnote. DESIGN.md 1.5 "Sent"
  and 1.10.

### 5. Stopped examples are not stops in T3 (R)
- **Where:** Disk test from 0:00 ("failed: snapshot restore timed out after 120 s"), beat 10 (0:48), beat 17 (1:22,
  "swift build exited 1"), beat 38 to 40.
- **Wrong:** T3 fails a run only on a provider error, a transport error, a usage limit or an interrupt (22 of 1,659
  runs). A failed test or build is a normal finished turn: it arrives as Done, and only the verdict can flag it, about
  2 s later (FEASIBILITY gap 2). The demo shows them red in the same frame, "no sheen: this is code".
- **Fix:**
  - `SF/RouterV2Demo.swift` records: Disk test's stop becomes a real one: line `failed: the connection to Claude
    dropped`, error text the same, last step unchanged.
  - Beat 17 (`SF/RouterV2DemoScript.swift:470-475`): Snapshot API's turn ends (Done, "finished just now", sheen), then
    the verdict moves it to Needs you with the `checklist` mark and streams "the build fails: cannot find
    'RestoreToken'; it stopped there". Caption: "A turn ends on an error: Fjord flags it". Card: the step card, ask
    "Fix the build, or tell it how", no Rerun.
  - `SF/RouterV2Demo.swift:317-320` `stop()`: a stop you asked for goes to Done with the line "stopped by you", not to
    Needs you (FEASIBILITY "§2.1").
  - DESIGN.md 1.5 Stopped, 2.1, 6.2, beat 17: the same.

### 6. Rerun: Return carries over into it, and it isn't a rerun (I, R, C)
- **Where:** beat 9 into 10 (0:46 to 0:51); 0:51 the Sent line reads “Rerun”.
- **Wrong, interaction:** after the last answer the selection moves to the Stopped card, where Return with no row is
  Rerun. Return ignores nothing: a held or doubled Return answers the form and reruns Disk test
  (`SF/RouterV2Keys.swift:121-131` has no `isRepeat` check). This is the 2026-10-12 carry-over rule, missed for Return.
  It is also the one act Return does that the destination row doesn't show (principle 3).
- **Wrong, realism:** T3 has no rerun. Its button sends the words "Continue where you left off." (FEASIBILITY gap 3),
  and the thread then shows that message.
- **Fix:**
  - `SF/RouterV2Keys.swift:121`: `if isReturn, key.isRepeat { return true }`.
  - `SF/RouterV2Model.swift` `destination`: on a Stopped card with an empty draft return
    `.picked(thread:, words: "Continue where you left off.")`, so the row shows it and Return follows the one rule.
    Delete the Stopped branch in `send()` (`:715`). `rerun()` sends those words.
  - `SF/RouterV2Card.swift:188`: the button reads `Continue` with its ⏎.
  - DESIGN.md 1.5 Stopped, 5.1, 5.2, beat 10, section 7 "Stopped".

### 7. Verdict timing, and the turn that restarts (R, P)
- **Where:** beats 12, 14, 15, 32, 40. Demo: 1.4 s, state and words together (`SF/RouterV2Demo.swift:329`). Real:
  state at 1.9 s, words until 2.5 s; one run end in four is followed by a new run within 30 s; at most four calls at
  once (FEASIBILITY gap 4).
- **Fix:** `endTurn`: `verdict: 1.9`, then the line 0.1 s later with `RouterV2.wordEvery` at 0.05 so the words end
  near 2.5 s; beat 12 and 15 use 2.5 s. Beat 40: the fifth to seventh lines wait for a free call (their sheen runs
  about 2 s longer). Add to beat 32: a fourth thread ends, sheens for 1 s, then starts again and goes back to Working
  with no words landed. Caption: "It started again: no line was written". Stretch `times` by about 1 s per changed
  beat. DESIGN.md section 3 "Demo latencies".

## High: the owner would stumble

### 8. "pick a place" is a dead end from the keyboard (I)
- **Where:** not in the video; reachable in one key. Esc with a draft waves the guess off
  (`SF/RouterV2Model.swift:1032-1034`); a read with no guess gives the same row.
- **Wrong:** Return does nothing there, no key opens the places menu (only the chevron), `@` isn't built, and `waved`
  is never reset while the draft lives: more typing or another selection keeps the row stuck.
- **Fix:** one rule, "Tab goes into the row": `SF/RouterV2Keys.swift`: with a draft and a row that is `.noGuess` or
  `.unsure`, Tab opens the places menu with ↑↓ Return (as the snooze menu). `SF/RouterV2Model.swift` `select()` and
  `setDraft()` (when the draft grows): `waved = false`. DESIGN.md 5.1 Tab rows and 5.3.

### 9. A half-answered form: the row says Return sends, Return doesn't (I, P, D)
- **Where:** beat 9 (0:40 to 0:48). At 0:42 the row reads `→ Updater “Silently”` and the send arrow is lit; Return
  there only moves the rail (`SF/RouterV2Model.swift:722-725`). Typed words on a form are recorded, not sent (`:728-738`).
  Neither is in DESIGN.md 5.2.
- **Also:** the beat's ⇧Tab and Tab change nothing: digits pick across the whole form, and the second Tab is a no-op
  (the rail is already there). The caption "Tab moves" teaches a key the owner doesn't need.
- **Fix:** `SF/RouterV2Dock.swift` `.picked`: for a form with open questions, after the words, muted: `1 more to
  answer`; the send button stays dim. `SF/RouterV2DemoScript.swift` beat 9: keys `1`, `2`, `3`, Return, with the
  caption "Form: a digit per question, one Return". Show Tab once, for what it is for: after `2`, type "beta, but only
  for me", Return (it becomes "Your answer: …"), Return. DESIGN.md 5.2: add the two form rules.

### 10. The unsure row hides what Return will do to the guess (I)
- **Where:** beat 24 (1:55 to 1:58). The lit guess, Settings layout, is running: Return would steer it. The row says
  nothing until ⌘2, then "steer now · ⌥ queue" appears after the third chip, next to "new thread in fjord"
  (`SF/RouterV2Dock.swift:232`; `mode: ""` at `SF/RouterV2Model.swift:641`).
- **Fix:** always show the lit place's mode, inside its chip before the keycap (`chip(...)` in `RouterV2Dock.swift`),
  not at the row's end. `destination`: `mode: mode(read.places[lit])`.

### 11. A new thread's chips from the keyboard: blind, and ↓ raises the effort (I)
- **Where:** beat 27 (2:12 to 2:18). ↓ takes Medium to High. With no list on screen the owner can't know what the
  next press gives, least of all for the model; and ↓ meaning "more" reads backwards.
- **Fix:** `SF/RouterV2Launch.swift` `stepLaunch`: ↑ ↓ on a ringed chip open its menu (the one a click opens) and
  move through it, the value applying as it moves, so nothing is confirmed; Tab, Esc or a character close it. Same
  keys, same count, but the choices are seen. DESIGN.md 1.9.1 "Keyboard" and choice 12.
- **Also:** nothing on the row says Tab. Every other act on the page shows its key. Add a muted `⇥` keycap after the
  last chip (`RouterV2LaunchChips`), hidden while the keyboard is in the row.
- **Also:** the Build chip joins and leaves the row as the keyboard comes and goes, so the row changes width under the
  ring. Show the mode's chip whenever the row shows a new thread; quiet ink at Build.

### 12. Working lines and steps don't look like T3's (R)
- **Where:** every Working line, e.g. 0:23 "reading SettingsView.swift", 1:59 "re-measuring the composer spacing";
  the step lists at 2:01 and 2:38.
- **Wrong:** real data gives the running tool ("Editing Foo.swift", a raw command, "Thinking") or the first sentence
  of the agent's latest words; there is no to-do list unless `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` is set in T3
  (FEASIBILITY gap 1).
- **Fix:** `SF/RouterV2Demo.swift` `steps` and the records: mix the three real shapes: `swift test --filter
  SnapshotRestore` (mono), "Editing SettingsView.swift", "Thinking", and one sentence ("I'll rebuild the boot image
  first."). Beat 31's Bar count card: no step list (live reply and Stop only); keep the list on Checkpoint boot.
  DESIGN.md 1.4 Working row and 1.5 Working.

### 13. Permission and plan cards show what T3 doesn't send (R, C)
- **Where:** beat 13 (1:02), caption "Permission: the command and why"; beat 8 (0:33).
- **Wrong:** no permission in the real data has a reason (0 of 17); T3's options are Allow once · Allow for this
  thread · Deny · Cancel. T3 gives no plan options: Fjord's own are two, and "No" is typing (FEASIBILITY gaps 7 and
  "Plan").
- **Fix:** `SF/RouterV2Demo.swift:176-178`: no `reason`; options as T3's four. `SF/RouterV2Card.swift:131`: drop the
  reason line. Caption 13: "Permission: the command and its warning". Records: Briefs migration's options lose "No,
  keep planning" (the placeholder "Or say what to change in the plan" covers it). DESIGN.md 1.5, 6.2.
- **Copy:** typed words on a permission deny it. The row says "tells it what to do instead"
  (`SF/RouterV2Model.swift:612`): make it "denies it, with your words".

### 14. A send goes out while the page says T3 can't be reached (I, R)
- **Where:** beat 31 (2:34 to 2:43). The connection line is up at 2:35; the demo still types, sends, shows
  "steering…" for 1 s, then fails.
- **Wrong:** Fjord knew. Real: with T3 down the error comes at once (FEASIBILITY). And the failure line takes the
  selection even when a card with a picked option is open (`SF/RouterV2Model.swift:1255`), so Return changes meaning
  in one frame.
- **Fix:** script: Return first, T3 drops 0.3 s later (failure line and connection line together). While
  `connectionLost`, the row's mode words read "T3 Code isn't reachable" and Return keeps the words in the composer.
  `refused()`: take the selection only when nothing is selected or the selected line is the one that failed.

### 15. A finished line moves twice, or bounces (I, R; needs the owner's word)
- **Where:** beat 14 (1:07 to 1:13): Working → Done → Needs you in 2 s. With finding 7's restart, Working → Done →
  Working.
- **Wrong:** a quarter of real endings bounce, and every "left you a step" hops twice, with counts ticking each time.
- **Fix to weigh:** the mark and the words change at once (✓, "finished just now", sheen), but the line keeps its
  place until the verdict's state lands (1.9 s), then moves once to Done or Needs you; a restart inside that time just
  puts the dots back. It bends principle 2 (section in the same frame) for one move in place of two. If the owner
  prefers the rule as it is, keep it and show the bounce honestly (finding 7).

## Medium

16. **Steering is not that quick (R).** Beats 24, 31: "steering…" lasts 0.9 s. Claude stops its tool about 5 s after a
    steer; an agent that can't steer queues. Fix: `RouterV2DemoSource.send`: 3 s when `steering`. A thread that can't
    steer shows "queue after this turn" with no ⌥ words (`mode()`); add one such thread to beat 25 or say so in
    DESIGN.md 1.9.
17. **A PR merge is not instant (R).** Beat 15 (1:14). T3 re-reads a linked PR every minute; a PR only named in a reply
    isn't pushed at all yet (gap 6). Fix: caption "A PR merges (T3 sees it within a minute): only that line is read
    again". DESIGN.md section 3 PR row: "up to a minute after the event".
18. **Beat 15's new words overclaim (C, R).** "the guide is live with the Chrome setup": merged is not live. Fix
    (`RouterV2DemoScript.swift:453`): keep "rewritten for the Chrome setup; PR #41", so only the state word and the
    ground change.
19. **New-thread defaults and lists aren't this install's (R).** Beats 26 to 28. Real: default Opus 5.5, access Auto,
    efforts low to max, models Fable 5.2, Opus 5.5, Sonnet 5.5, Haiku 5.5 (FEASIBILITY). Fix
    (`SF/RouterV2Launch.swift:73-82`): `t3Default` = Opus 5.5 · the model's default effort · Auto; add `max`
    ("Max"); models as listed. The story still works: beat 27 changes the effort, beat 28 picks Sonnet 5.5, beat 29's
    "(use opus medium)" rolls both back. DESIGN.md 1.9.1 table: default access "T3's (`auto` here)".
20. **Chips don't show they are being re-read (R).** Beat 29 (2:23): for 3 s on real data the chips look final. Fix:
    while `reading` and the row shows a new thread, the chips' values sheen (`RouterV2LaunchChip`), as FEASIBILITY
    asks.
21. **AZERTY: the digit row eats first letters (I).** With a card open and an empty draft, the keys 1 to 9 pick by
    position (`SF/RouterV2Keys.swift:159`). On AZERTY those keys type `& é " ' ( - è _ ç`: a message starting "écris"
    or "ça" picks option 2 or 9 and loses its first letter. Fix: pick by position only when the key's character is not
    a letter (`key.characters?.first?.isLetter != true`). DESIGN.md 5.
22. **With a draft, the card still looks pickable (I).** Beat 7 (0:25 to 0:31): the option keycaps stay lit while
    digits are words, and a picked radio stays filled though it won't be sent. Fix (`RouterV2OptionRow`): while the
    draft is not empty, keycaps at `CDS.Text.disabled` and a picked radio at half strength.
23. **After "Not for me" the Done line still asks (C).** 3:13: under Done, "PR #2049 is open: read the diff, then merge
    it". Fix: the verdict keeps a result line beside the ask; `notForMe()` swaps to it ("replied on the issue; PR
    #2049 open"). Script: pass it in beat 14's `endTurn`.
24. **"Not for me" (C).** It reads as "not my job". It answers "Needs you". Fix (`SF/RouterV2Card.swift:203`):
    `Doesn't need me`. DESIGN.md 1.5, beat 38 caption "Doesn't need me: it goes to Done".
25. **Snooze menu (C, I).** 3:06: title "Snooze until" over "1 hour". Fix (`SF/RouterV2Card.swift:361`,
    `SF/RouterV2.swift:166`): title `Snooze`; items `For 1 hour` · `For 3 hours` · `Until tomorrow, 9:00`, as the
    toast says them.
26. **"Clear Esc" isn't always true (I).** 1:29 onward (`SF/RouterV2Page.swift:326`). Esc clears filters last (5.3):
    with a card open or a draft it does something else first. Fix: show the keycap only when Esc would clear (no
    selection, no draft, no menu); otherwise `Clear` alone.
27. **Peek's "Click to open" (C).** 0:07. "Open" is T3's word on this page ("Open in T3"). Fix
    (`SF/RouterV2.swift:165`): `Click for its card`.
28. **The story settles what it flagged (R, P).** 3:01 and 3:21 to 3:32: ⌘⌫ takes Settings layout (blue, PR #58 open,
    never read), Snapshot API (a failed build) and Upstream issue (PR #2049 still open). Fix: before beat 40, PR #2049
    merges (it turns quiet); in beat 36 read the second card for 1.5 s before its ⌘⌫.
29. **Beat 40 is hard to follow (P).** 3:21 to 3:33: ⌘⌫ starts while lines still arrive, and the selection sits
    mid-list, so settles go down then up. Fix: wait for the last line, ⌥↓ to Done's first line, then ⌘⌫ every 0.6 s.
30. **Long captions start with their action (P).** Beats 12, 14, 24, 26: 10 to 12 words, the event 0.8 s later. Fix:
    lead of 0.2 s a word (at least 0.8 s) in `beat()`, or captions of 7 words at most (list in 41).
31. **Beat 6's Sent state is gone in 0.9 s (P).** 0:21: the Sent line, the flying line, the counts and the next card
    all at once. Fix: in beat 6 only, the run starts 1.6 s after the send.
32. **Auto-advance clears "new" unseen (I).** 2:57: Settle opens the next card, which clears its dot and tells T3 it
    was visited. Fix (no timer): a card opened by advance clears the dot on the owner's first key or pointer move
    after it opened, not on opening.
33. **Seven model calls at once (R).** Beat 40; covered by 7. FEASIBILITY "Not verified" lists it.
34. **Mode words say "turn" three ways (C).** "starts a new turn", "queue after this turn", "queued, sends when this
    turn ends", and the send button's tooltip "queues behind the turn under way" (`SF/RouterV2Dock.swift:124`). Fix:
    tooltip "⌥Return queues after this turn".
35. **"answers its question" on a step Fjord found (C).** 0:29, Val Cenis: the thread asked nothing; the words start a
    new turn. Fix (`mode()`): for `.needsYou(.step)`, "answers it".

## Low

36. **Stop has no Revert and no key (I).** Fine as a button; say in DESIGN.md 1.5 that Stop is the page's one act
    with no way back, and keep it out of ⌘-chords.
37. **⌘⌫ on a failure line is Edit (I).** Elsewhere ⌘⌫ removes. Fix: show its keycap on `Edit`, or drop the chord.
38. **Snooze menu digits act at once (I).** On cards a digit only picks. Accept (the act has a Revert); say so in 5.1.
39. **Filter mode swallows a message (I).** ⌘F, then typing words: letters jump the ring, the rest is dropped
    (`SF/RouterV2Keys.swift:53-56`). Fix: a character that matches no project leaves filter mode and goes to the
    composer.
40. **Toast pause re-arms a 2 s timer (I).** `SF/RouterV2Model.swift:886`. The owner's rule is no polling: stop the
    clock on hover-in, restart on hover-out.
41. **Captions use machinery words (C).** Rewrites: 4 "Click opens its card" · 9 see finding 9 · 12 "A thread asks:
    it moves at once, Fjord shortens the line" · 14 "A turn ends: Done at once. Then Fjord finds a step for you" · 15
    see 17 · 26 "A new thread: the row shows how it starts" · 36 "⌘⌫ twice: two lines, one toast" · 38 see 24 · 39
    "Older finished threads: one line" · 41 "Nothing left".
42. **"finished just now" beside the age "now" (C).** Fix (`SF/RouterV2.swift:153`): `finished`.
43. **The failure line keeps a stale reason (C).** 2:41: T3 is back, the line still ends "T3 Code isn't reachable."
    Fix: once reconnected, "… didn't go to Bar count."
44. **"5 older finished, not settled" (C).** Telegraphic. Fix: `5 finished earlier, not settled`.
45. **Type-ahead looks like a letter shortcut (D).** 1:39: the caption shows an `F` keycap. CONTEXT bans letter keys.
    Fix: caption keys as typed text ("typing f"), not a keycap.
46. **docs-site's pill leaves while an older docs-site thread remains (I).** 1:27 (`projects` counts lines only). Fix:
    include `older` projects in `projects`.
47. **"All 8" under a state filter (I).** 1:34: All shows the Working count. Faceted and correct; note it in the
    token's tooltip only if the owner trips on it.
48. **Sent after a queue (I).** 2:49: the queued row rises as “then delete the old checkpoint image too” with no
    status. Fine; keep.
49. **The ask on a permission can go stale (R).** After a T3 restart a request can't be answered (FEASIBILITY). Add to
    DESIGN.md 1.5 Permission: the options give way to "Open in T3".
50. **Return on Done or Working does nothing, silently (I).** By design (5.2). The dim ↩ says it; keep.
51. **Esc never clears a draft (I).** By design; say it in 5.3 so nobody adds it.
52. **DESIGN.md section 7 still says `startImmediately(intent: .restart)` and "to-do step or last tool" (D).** Update
    with findings 6 and 12.

## What holds up

- The one rule "pick shows live, Return sends" reads without captions in beats 5 to 8 and 13.
- The destination row is recognised at once (mark, name, pill); the dashed outline at 1:50 ties it to the line.
- ⌥ flipping "steer now" to "queue after this turn" (2:05) and the queued row with Cancel are clear.
- Settle, Revert and ⌘Z (2:55 to 3:01) are instant and legible; one toast is right.
- Filters (1:29 to 1:46): counts, the sliding ground and "Nothing needs you in fjord." need no caption.
- Terms are steady: Needs you, Done, Working, Stopped, Sent, Settle, Snooze; T3's own names for access and mode.

Frames used for this review: `/tmp/rv2-frames/c/` (one a second, page column only).
