# Router v2: design and demo storyboard (2026-11-12)

For the agent that builds the demo. Context and inputs: [CONTEXT.md](CONTEXT.md). The demo is real SwiftUI components
behind a flag (`Sources/Fjord/RouterV2*.swift`), on fake data, recorded for the owner; the same components are later fed
by the real engine.

Round 2 (2026-11-12, CONTEXT.md "Round 2") added two things, marked **R2** where they land: Fjord's mark wherever the
Router's model is at work (1.9, 2.2, 2.3), and a new thread's settings in the destination row (1.9.1, 5.1, beats 27–31).

Round 3 (2026-11-12) fixed the two polish reviews (POLISH-visual.md, POLISH-interaction.md) and moved the demo to the
latencies and behaviours FEASIBILITY.md measured. Its rules are marked **R3**.

Round 4 (2026-11-12) is the surfaces pass: one small system for every ground, pill, chip, key and panel (1.0), and a
line that changes section glides as itself. Its rules are marked **R4**; where an older line says otherwise, 1.0 wins.

Contents: 0 principles · 1 page anatomy (1.0 surfaces) · 2 thread state model · 3 live updates · 4 filters · 5 keyboard map ·
6 storyboard · 7 out of scope and later · 8 choices to check in the video.

## 0. Principles

1. **One line per thread, once.** The page is a pure function of one record per thread. Counts, colours, sections and
   cards all read that record.
2. **Code first, model second.** Code sets state, section, icon, counts and a plain line in the same frame as the event.
   The model only replaces the line's words (and may promote Done to Needs you). Only the words being replaced shimmer.
3. **One input.** The composer is the only text field. The destination row above it is the only place that says what
   Return will do.
4. **Pick shows live, Return sends.** Digits, ⌘1–3 and clicks on options only pick. Nothing leaves before Return.
5. **A coloured ground means it asks something of you.** Needs you (amber), Stopped (red), Done worth a look (blue).
   Working, Sent and quiet Done are plain text.
6. **Reversible acts act at once**, with one Revert toast and ⌘Z. No confirm step anywhere.
7. **No machinery on the page.** No "updated 3m ago", no "Rewriting", no "delivered". The header subtitle `BriefUpdated`
   goes.

All numbers below go in one place, `enum RouterV2` (metrics, curves, copy), so they can be tuned after the video.

## 1. Page anatomy

Top to bottom, inside the existing 720 pt column (`RouterBriefView.column`, gutter 32):

```
┌ filter bar (sticky) ─────────────────────────────────────────────────────────┐
│ All 11   fjord 4   silo 4   lcu 1   docs-site 1          ? 5    ✓ 2    ··· 4 │
└──────────────────────────────────────────────────────────────────────────────┘
Needs you 5
╭──────────────────────────────────────────────────────────────────────────────╮
│ • [? Settings layout] sidebar, one page, or tabs?                 fjord  25m │  selected line
│   Redesign the Settings window                                               │
│   ▏I can do a sidebar with sections, one scrolling page, or tabs. One page   │  card
│   ▏is simplest to maintain.                                                  │
│   ( ) A sidebar with sections                                            [1] │
│   (•) One scrolling page                                                 [2] │
│   ( ) Tabs across the top                                                [3] │
│                                   Snooze ⌥⌘⌫   Settle ⌘⌫   Open in T3 ⌘O    │
╰──────────────────────────────────────────────────────────────────────────────╯
  [? Val Cenis booking] reserve for five? about €62 more than for four    12m
  [▤ Briefs migration] plan ready: move briefs into BriefLog         fjord  6m
• [? Updater] silent or ask first? stable or beta?                    lcu   2m
  [▲ Disk test] failed: the connection to Claude dropped             silo   1h

Done 2
• [✓ Install guide] rewritten for the Chrome setup; PR #41 open  docs-site 10m
  ✓ Bar count  counts only unread; tests pass, not pushed           fjord  50m

Working 4
  ··· Tab handover  Editing TabHandover.swift                       fjord  12m
  ...
  5 finished earlier, not settled                                   Settle all

                 (floating dock, bottom of the page)
  [toast]  Settled Briefs migration   Revert ⌘Z
  [failure] ▲ “also bump the version” didn't go to Bar count …    Send again
  → [? Settings layout]  “One scrolling page”
  ┌ Answer Settings layout                                                 ↩ ┐
```

Text roles are `CDS.Density.compact`: prose 14/20, body 13/19, footnote 12/15, caption 11/17, code 12/17 (mono).
Colours are CDS tokens (dark values; `Brand.map` gives the light look). Hover fills follow Motion rule 1: instant on
(**R3:** and instant off on rows; the other controls keep `release` off, `.hoverMotion`).

### 1.0 Surfaces (R4)

One system for everything that has a ground: `RouterV2.Surface` and its helpers in `RouterV2Surfaces.swift`. The page is
words on the page's ground; a surface is the exception and has to say something.

**Nothing has an outline.** A 1 pt edge is allowed in two places only:

1. **The keyboard's ring** (`RouterV2Ring`): `CDS.Text.accent`, 1.5 pt, 1.5 pt clear of the thing, its radius + 3. One
   style everywhere the keyboard can be: the filter bar, a setting's chip, `Send again`.
2. **A panel that floats over other things** (`routerV2Floating`): the peek and the menus. `CDS.Surface.s3`, a 1 pt
   `CDS.border` hairline, one soft shadow (the panel's two drops at half strength) cast by the surface alone, never by
   the words on it. The composer card is CDS's own and unchanged.

Everything else is a fill or nothing. So there is never a box in a box: the card has no outline, its options no
outline and no dividers, keys no caps, chips and pills no edge. A control's glyph (a radio, a pending step) is a
glyph, not a surface.

| Radius | For (by height) |
|---|---|
| 4 `token` | up to 18 tall: project pill, PR badge, setting chip, a settings pill in the composer |
| 6 `control` | 20 to 24: a name's ground, a place in the row, filter pill, button, menu row, code block |
| 8 `row` | 28 to 36: a line under the pointer, an option, the reason banner, toast, failure line, housekeeping |
| 12 `card` | the selected line with its card |

What floats keeps CDS Menu's 10, the composer CDS's 14.

| Fill (neutral ink) | Token | Means |
|---|---|---|
| none | | rest |
| 5 % `quiet` | `Fill.neutral` | a ground at rest: the selected card, project pill, setting chip, code |
| 7.5 % `hover` | `Fill.ghostHover` | the pointer on something with no ground |
| 10 % `chosen` | `Fill.secondary` | chosen: a picked option, the lit place, a setting you changed, a button, the toast; and the pointer on a quiet ground (14 % on a chosen one) |
| 15 % `pressed` | `Fill.ghostSelected` | pressed, a menu open from it, the active filter |

| Tint | Means |
|---|---|
| a state's colour at 12 % (24 % under the pointer) | a name that asks something of you (principle 5); the danger ground of a stop's reason and of a failed send |
| the accent at 12 % or 24 % | it came from you: a setting as a pill sets it (24 %, fading), a place you picked yourself (24 %) |

- **Selection is a fill, focus is the ring.** A picked option, the lit place, the active filter and the selected card
  change ground; none gains an edge.
- **Keys are glyphs** (`RouterV2KeyHint`): `⇧1`, `⌥⌘⌫`, `⇥`, as a menu shows them, in the ink at 50 %, so a key reads
  as a hint beside its act. No cap.
- **Shadows** only under what floats (and the composer). A status line by the composer (toast, failure) floats over
  nothing: a ground, no edge, no shadow. The destination row has no ground at all.
- **A line in flight has no surface** (2.4): no plate, no edge, no shadow.

### 1.1 State colours and marks

| State | Tint | Mark (SF Symbol) | Name ground |
|---|---|---|---|
| Needs you: question, form | `CDS.Text.warning` | `questionmark.circle.fill` | tint 12 % |
| Needs you: plan | `CDS.Text.warning` | `list.bullet.clipboard.fill` | tint 12 % |
| Needs you: permission | `CDS.Text.warning` | `lock.fill` | tint 12 % |
| Stopped | `CDS.Text.danger` | `exclamationmark.triangle.fill` | tint 12 % |
| Sent | mark `CDS.Text.accent`, name `CDS.Text.primary` | `arrow.up.circle.fill` | none |
| Working | mark `CDS.Text.muted`, name `CDS.Text.primary` | CDS working dots (`Transcript.markDots`, Core Animation); `ellipsis` under Reduce Motion | none |
| Done, worth a look | `CDS.Text.accent` | `checkmark.circle.fill` | tint 12 % |
| Done, quiet | mark `CDS.Text.accent`, name `CDS.Text.primary` | `checkmark.circle.fill` | none |
| new (modifier) | `CDS.Fill.accent` | 6 pt dot (`CDS.Dot.size`) | n/a |

### 1.2 Filter bar

- **Layout.** One row, 24 pt controls, 12 pt above and below, sticky at the top of the scroll area (`safeAreaInset`),
  ground `CDS.Surface.s1` with a 24 pt fade under it, the same as over the dock (`RouterV2.Bar.fade`). Left group:
  project pills, `All` first, then projects with a line or a thread under the housekeeping line, alphabetical (the order
  never changes with activity; a pill can read 0 and then sits disabled). Right group: three state tokens in page
  order: Needs you, Done, Working. Gap 2 between pills, 4 between tokens. **R3.** With no thread at all the bar goes
  but its 48 pt stay, so the page doesn't jump.
- **Pill.** CDS Tabs metrics (`CDS.Tabs`): height 24, padding 8, radius 6, label 13/19 medium `CDS.Text.muted`, then
  the count 6 pt after (`Tabs.badgeGap`) in caption 11 `CDS.Text.muted`, `monospacedDigit`, `numericText` transition.
- **State token.** Same shell: the state's mark at 10 pt in its tint, then its count. No word (the tooltip and the
  accessibility label give it: "Needs you, 5"). A count of 0 draws at `CDS.Text.disabled`. **R3.** A token's count has
  room for two digits.
- **States.** Rest: no fill. Hover: `CDS.Fill.ghostHover`, label `CDS.Text.primary`. Pressed: `CDS.Fill.ghostSelected`,
  the shell squishes to 0.975 as `ClaudeButton` does. Active: label `CDS.Text.primary`, ground `CDS.Fill.ghostSelected`;
  one ground per group, sliding between pills with `matchedGeometryEffect` on `Motion.glass`. Keyboard ring (filter mode
  only): the page's ring (1.0, **R4**).
- **While any filter is on**, a ghost text button sits right after the last project pill (the tokens never move):
  `Clear` + the key `esc` (footnote, `CDS.Text.muted`). **R3.** The key shows only when Esc would clear: nothing
  selected, no draft, no menu open, not in filter mode.
- **Copy.** `All`, project names as T3 has them, `Clear`. Empty page: the bar is hidden.
- Overflow (more pills than fit) folds the last ones into a `More` CDS menu. Not in the demo.

### 1.3 Section header

- `Needs you 5` · `Done 2` · `Working 4`. Name: sans 12 semibold in the section tint (`Text.warning`, `Text.accent`,
  `Text.muted`). Count: sans 12 regular `CDS.Text.muted`, 6 pt after, `numericText`.
- Height 28; 20 pt above (8 for the first). Leading edge aligned with the lines' names.
- The count is the number of lines under it, always.
- A section with no lines has no header. Exception, Needs you: its place is taken by the sentence in 1.14.
  **R3.** The Needs-you header and that sentence are one row (id `header-0`): its content swaps, nothing folds. Counts
  tick inside their header (`geometryGroup`), so the header doesn't move with them.
- Click on a header = click on that state's token in the filter bar (section 4). Hover: name underlined.
- Stopped lines live in Needs you, after the asks: a stopped thread waits on you to continue or settle it. Sent lines
  live at the top of Working.

### 1.4 Thread line

```
[8][dot 6][6][ mark + name ][8][ sentence ……………… ][12][ project pill ][8][ age ][8]
```

- **Row.** Min height 34 (22 content + 6 above and below). The row's ground reaches 8 pt past the text on both sides,
  radius 8.
- **Dot slot.** 6 pt, always reserved. Holds the "new" dot; on the line a draft goes to, the destination row's arrow
  (below, **R4**).
- **Name.** The existing highlight (`BriefSpan`): mark at 9.5 pt semibold, 4 pt, name in sans 14 medium; with a ground:
  name in the tint, padding 5 × 1, radius 6 (**R4**), ground tint 12 %. Plain states: name `CDS.Text.primary`, regular weight, no
  ground, no underline. One line, never truncated under 28 characters. **R5.** Until the model names it, the name is T3's
  whole title, truncated at the row's own width (at most 45 % of the row, `RouterV2.Line.nameShare`); a name being given
  sheens with no mark of its own (the line's one Fjord mark is after its sentence). **R3.** The name always takes the width of its
  medium weight (a hidden copy), so the sentence doesn't shift when the ground comes or goes.
- **Sentence.** Sans 14 regular. `CDS.Text.secondary` for Needs you, Stopped, Done; `CDS.Text.muted` for Working; one
  line, tail truncation. Links inside it (a PR) keep the `BriefLink` look; the PR's state word after the link is drawn by
  code from the board, in footnote: open `BadgeTint.successText`, merged `BadgeTint.violetText`, closed `Text.danger`.
  **R3.** The word has a 14 pt space after the link. It swaps in one frame and pops from 1.25 (3).
- **Activity.** **R5** (2026-11-12, owner: "show in a super compact way when there are subagents running, background
  processes, something it's waiting on"). At the end of the sentence's place, right-aligned just before the project pill
  and the age, at least 8 pt after the words, so they never move as the sentence changes (owner, 2026-11-13: they jumped
  right whenever a command came): one glyph per kind the thread has,
  in page order subagents `person.2`, background commands `terminal`, waits `hourglass` (another thread, a monitor, a
  command the agent said it resumes after); 10 pt medium, 7 apart, `CDS.Text.muted`, no ground. A kind's count follows
  its glyph 2 pt on (sans 11, `monospacedDigit`, `numericText`) only when it is more than one: `person.2 2  terminal`.
  The words give way first; the glyphs never truncate. The pointer on them brightens them to `CDS.Text.secondary` and
  shows their peek (1.6). A glyph group comes and goes with `Motion.fade`; Reduce Motion: counts cross-fade. Read from
  T3's projection (`RouterActivity.swift`): `subagents[]` (title, model, start), the provider thread's
  `pendingBackgroundTasks` roster, the command item that started a background task, live `t3_thread_wait` / `Monitor`
  items. T3's own watch of a PR is not listed (it isn't the agent's work).
- **Project pill.** CDS Badge neutral xs (`CDS.Badge`): height 16, padding 4, radius 4, fill `alpha(0.05)`, 10 pt medium
  `CDS.Text.secondary`. Hover: fill `CDS.Fill.secondary`, ink `CDS.Text.primary`, pointing hand. Click filters (section
  4). A thread with no project has no pill. While a project filter is on, pills on lines fade out (the bar says it).
- **Age.** Sans 12 `CDS.Text.muted`, `monospacedDigit`, trailing, min width 28, `BriefAge.short` ("now", "4m", "2h",
  "3d"). Meaning by state: Needs you and Stopped, how long it has waited; Sent, "now"; Working, how long the run has
  run; Done, since it finished. **R3.** Ages tick with `numericText`.

Line states:

| State | Look |
|---|---|
| rest | no ground |
| hover (pointer anywhere on the row) | ground `CDS.Fill.ghostHover`; name ground goes 12 % → 24 %. **R3.** Instant on and instant off (no release) |
| pressed | ground `CDS.Fill.ghostSelected` |
| selected | the row and its card share one ground: fill `CDS.Fill.neutral`, radius 12, no outline (**R4**). **R3.** The card rolls open and shut at full opacity on the ambient curve, clipped |
| destination of the draft, not selected | **R4.** The destination row's arrow (`arrow.right` 9 pt `CDS.Text.accent`) in the line's dot slot, in place of the new dot while it is there. No outline on the name |
| reassessing | mark, name, pill, age solid; the sentence shows the code line in `CDS.Text.muted` with a sheen passing over it, and Fjord's mark after it (2.2) |
| streaming | the model's words fade in one by one over the sentence's place (2.3) |
| moving | **R4.** The row glides to its place as itself, drawn over the rows it passes (`zIndex 1`): no plate, no edge, no shadow. What it passes fades out under it and back behind it (2.4). **R3.** If it was selected, its card's content and the selected surface go in the frame it takes off, the card's place folds on the move's curve, and the card opens again after landing if the line is still selected |
| leaving, arriving (settled, snoozed, grown in) | **R3.** A fold (height to 0) on `Motion.spatial`; its opacity shows only in the last 35 % |

Exact sentence, by state, when the code writes it (the model's line replaces the ones marked *):

| State | Code line |
|---|---|
| question, form | T3's question verbatim; a form: "N questions: " + the first * |
| plan | "plan ready: " + the plan's first line * |
| permission | the command or tool, in `CDS.mono(12)` * |
| Stopped | **R3.** Real stops only: "failed: " + the error's first line ("failed: the connection to Claude dropped"); "hit the usage limit" (final: code only). A run you stopped yourself is Done, with "stopped by you" |
| Sent | your words in curly quotes, then the status: `sending…`, `steering…`, nothing once T3 has them. **R3.** For a thread started here the model and effort follow the status (footnote muted, plus access and Plan when not T3's default) |
| Working | **R3.** The running to-do step, else the agent's latest words, else the running tool or command (a command in `CDS.mono(12)`); "starting"; "paused at the usage limit, resumes 15:00" (final: code only) |
| Done | **R3.** "finished" * |

- **Working, summed up.** **R6** (2026-11-13, owner; `RouterWork.swift`, `RouterSummaryPrompt.swift`,
  `RouterRecords.summarizeIfNeeded`, shots `v2-working-*`). A working line's sentence is the newest of short lines the
  Router's model (Haiku, through the verdicts' queue and cap, after every verdict) writes about the run ("Image built;
  waiting on CI before it boots the VM"), not the raw command; at most 9 words, present tense, no commands or ids
  (EVAL-summaries.md). It is written when the agent finishes writing something new or its to-do step changes, at most one
  a minute per thread (a trigger inside the minute waits for its end, one wake), never twice for the same facts (the
  words, the step, the kind of tool running, the run), sheening on the line it replaces, then streaming in (2.2, 2.3).
  Until its run has one, the line is the code's (R3). A call that fails keeps the line it had; a run that ends cancels
  its call, and so does a new run starting while it is asked: a summary is kept only for the run it was asked for, and
  two runs' summaries never merge. Summaries leave one of the four calls free for asks and finished turns, and a
  summary's rate limit holds only the summaries. The summaries are kept, newest first, twenty at most, in the verdict file until the thread leaves the page.
  The pointer anywhere on a working line shows its one peek (1.6); its card lists the summaries (1.5).

### 1.4.1 One layered structure (R10)

**R10** (2026-11-13, owner-approved; `RouterSummaryView.swift`, `RouterTimeline` in `RouterWorkViews.swift`,
`RouterDemoLayers.swift`, shots `v2-layer-{done,working,item}-{line,hover,card}`, `v2-layer-item-block-card`). Every thread
and item has one structure in layers: the hover is the line plus more, the card is the hover plus more; nothing jumps
between them and nothing repeats. Where an older rule below says otherwise (1.5's blocks, 1.6's peeks), this wins.

- **Line.** The sentence: what matters now, never cut. It flows from after the name and wraps under it (`RouterFlow`,
  3 lines at most, a guard); the mark, the name, the activity glyphs, the pill and the age stay on its first line. A Sent
  line keeps to one.
- **Hover** (one peek for every line, item row and the activity glyphs: 360 wide, the floating shell): the sentence
  (prose 14 medium, primary), the detail (prose 14, primary; a real stop's error on the danger ground), the facts as quiet
  chips (18 tall, radius 4, the quiet fill, 11 medium; a PR as its tinted badge, the diff in the git inks, a fact's kind
  glyph 9 pt muted, its tone's ink; cut in the middle past 300). Only when there is a detail or a fact: a line that says
  it all has no hover.
- **Card**, under its line (which says the sentence), in order: the detail and the facts as the hover shows them; the
  source (the agent's own words: the last lines with rail, cut and Show all; an item's quote and its links; a plan; a
  permission's command; your words); then the controls that answer it (an item's or the ask's options, a form,
  Continue, the permission's buttons); THEN the history; last the footer's acts (Done / Settle · Snooze / Stop, Open in
  T3). What matters now comes before the past, so the history never pushes the answer down.
- **By state.** Done: sentence the outcome, facts PR, files, tests, source its last message. Working: sentence the
  summary, facts its subagents, background commands and waits, source the history itself. Needs you and items: sentence
  the item, detail why, source the quote, controls its options and Done. The engine fills `RouterThread.summary`
  (sentence, detail, facts, source) and `RouterItem.summary`; a question's own words are its detail until then.
- **History** (`RouterThread.history`, newest first): on every thread's card, under the controls and above the footer (for Working it is the
  source, not repeated). Summaries as words (body 13 secondary); quiet one-liners (footnote, the mark 9 pt hung in the
  gutter) for an item raised (its kind's mark at 80 %), an item closed (struck, muted, its how after it) and a turn
  ended (`checkmark.circle`, its outcome); under each run what started it (R6). Clock times in the ages column. An item
  still open isn't repeated there. Same height, scrolling, fade and `↑ new` pill as R6's timeline (the pill counts
  anything new but a run's start). An item's card in a block has none: its header's card has it.

### 1.5 Card (the selected line's)

One card component, inline under its line, inside the selected surface. Selection by ↑↓, click or page open shows the
same card. Body inset (**R9**, 2026-11-13): one text column, the line's name words (the name's ground at 14 from the ground's edge, the dot's column inside it, then the name's pad and mark: 36); trailing 14, as far from the edge as the name's ground starts, so the age, the footer's keys and the options' keys end there; bottom 10; blocks 10 apart. Every block's words start on the column: the last lines and quotes (their rail 10 left of it), the timeline and its run starts, steps, activity rows, option labels, a form's titles, the permission's command, a stop's error, a badge's words, a footer's leading text. Glyphs hang in the gutter to its left under the line's mark (a 13 box, 4 before the words): steps' marks, activity glyphs, a run start's arrow, a warning; option radios (16, 8 before the label) hang further, their grounds 8 past them; a form's current-question rail hangs left of those grounds; a ground around words (code, the danger banner, a badge, Continue) hangs by its pad. An item's card in a block takes its row's words as its column the same way. **R3.** Prose blocks keep to
560; option rows run the card's width. Inline code is 0.92 of the size of the text beside it.

Common blocks, in order (no T3 title: it is the start of the thread's first message, which says little; the name
says which thread it is):

1. **Last lines.** The agent's last message, body 13/19 `CDS.Text.secondary`, behind a 1 pt `Settings.railLine` rail
   with 10 pt inset, clipped to 4 lines (6 for Done) with a bottom fade and, under it, a footnote button "Show all" (`→`).
   `→`, the button or a click on the cut words opens it whole, no inner scroll: the card grows and the page scrolls;
   "Show less" (`←`) closes. While the thread's messages load: two skeleton bars (height 10, radius 5, fill
   `alpha(0.06)`, widths 92 % and 61 %, same sheen as 2.2). While the agent is writing (Working): the text grows live, a 2 × 14 pt caret in
   `CDS.Text.muted` after the last word. **R3.** `→` and `←` roll the text open and shut: one block in a place as tall as
   its first lines.
2. **Kind block** (below).
3. **Footer.** One row of text buttons, trailing: footnote 12 `CDS.Text.muted` (hover `CDS.Text.primary`), each with its
   keys (plain glyphs, 1.0), 16 apart. No hint text: the destination row says what Return does.

Kind blocks:

| Kind | Block | Options and keys | Footer |
|---|---|---|---|
| **Question** | the question, prose 14/20 `Text.primary`, when it isn't already the line | option rows `1`…`9` | Snooze ⌥⌘⌫ · Settle ⌘⌫ · Open in T3 ⌘O |
| **Form** | each question: title prose medium, its option rows; numbers run through the form (1, 2 then 3, 4). The current question has a 2 pt `CDS.Text.accent` rail on its left (**R3.** one rail that slides between questions); an answered one shows `checkmark` 10 pt `Text.muted` after its title. A typed answer shows as a row "Your answer: …" | digits pick anywhere; Tab / ⇧Tab move the current question; typing answers the current question | left: "1 of 2 answered" (footnote muted); then the same three |
| **Plan** | the plan's markdown (transcript prose), first 8 lines with a bottom fade; under it a footnote button "Show all · 23 lines" (`→`), "Show less" (`←`). **R3.** The button rides the edge of the text as it rolls and its label swaps | **R3.** Two options, Fjord's own (T3 gives a plan none): "Yes, and auto-accept edits" · "Yes, and manually approve edits". "No" is typing what to change | same three |
| **Permission** | **R3.** No reason block (T3 sends none). The command: `CDS.mono(12)` on `Transcript.codeFill`, radius 6, padding 8 × 6, selectable; an option's warning in footnote `Text.warning` | **R3.** T3's four options as rows: Allow once · Allow for this thread · Deny · Cancel. Typed words deny the request with your words. After a T3 restart a request can't be answered: the options give way to Open in T3 (not in the demo) | same three |
| **Done** | PR badges; "4 files" + `+96` in `Git.added`, `−212` in `Git.removed` (footnote, mono digits) | none | same three |
| **Stopped** | reason banner: fill `Text.danger` 12 % (`RouterV2.dangerFill`), no ring (**R4**), radius 8, padding 10; the error in `CDS.mono(12)` `Text.primary`, max 6 lines; under it "Last step: " + step, footnote muted | none | **R3.** left: `Continue` + the key `⏎` (the page's button, **R4**: 24 tall, radius 6, the chosen fill); then the same three. T3 has no rerun: Continue sends T3's own words, "Continue where you left off.", and the destination row shows them (1.9). The Sent line reads those words |
| **Working** | **R3.** T3's to-do steps only when the thread has a list (Claude sends one only with T3's to-do setting), footnote: done `checkmark` muted, running in `Text.primary` with the working dots, pending muted; at most 5, then "+3 more". A thread started here shows what it runs on as the card's first footnote through its first run | none | Stop · Open in T3 ⌘O. **R3.** Stop is the page's one act with no way back: a button, no key |
| **Working: summaries** | **R6.** In the last lines' place (no quote: the last turn's words aren't news): the model's summaries, newest first, all that are kept (twenty) with their runs' starts, about eight lines tall (`Router.Work.timelineHeight`) and scrolling inside the card past that, no scroll bar, softly faded (28) at the bottom while more is under it; no "Show all" (2026-11-13). The one the line above reads is left out (the card is what came before it; a summary streaming in on the line puts it back), so a run with one summary shows none. Read as a conversation (2026-11-13): no marks, no rail, every line on the line's text column; the words body 13/19 `Text.secondary` at the prose's width, 3 apart (a newest the line doesn't read: `Text.primary`); under each run's summaries, 3 below, what started it, from T3's fields on the run's message, never its words (`RouterDetail.starts`): your message (`createdBy: "user"`) as one quiet line, `↑ "the caret still jumps…"` (9 pt arrow, footnote muted, curly quotes, cut once at the end), the arrow pointing up at what it led to; else, unquoted at 70 %: `↑ subagent finished · <its title>` (a delegated completion or a subagent's notification; "2 subagents finished · a, b"), `↑ background command finished · <command>` (a `command` notification, the command in mono), `↑ resumed after the usage limit` (T3's `limit-resume:` message), `↑ resumed by itself` (anything else T3 queued); a run whose start isn't known shows nothing; runs 9 apart. **New while read back:** scrolled off its top, a new summary moves nothing: the timeline holds what it shows and a quiet pill `↑ 1 new` (footnote, the card's ground, a hairline) springs in at its top edge and counts up, on its own band: the timeline's top 25 (the pill, 2 over it and 3 under) hides the words, fading them back in over 12 under it, so the pill never sits on words and nothing moves as it comes; pressing it glides to the top (at once with Reduce Motion), where the new ones fold in on the lines' spring and the pill fades out; scrolling up there does the same. At the top, new ones just fold in. The clock time ("13:58", or "1:58 PM" on a 12-hour system), caption muted mono digits, trailing in the line's ages column, where the activity rows' ages end too. Then the steps, then the activity | none | as Working |
| **Working: activity** | **R5.** Under the steps, the activity peek's rows (1.6) at footnote size in `Text.muted`, the glyph column 14 wide like the steps'; **R6.** their ages trail in the line's ages column | none | as Working |
| **Sent** | your words, body `Text.primary`; a thread started here: under them what it starts with, footnote `Text.muted` ("Opus 5.5 · High · Auto"), until its run starts | none | Open in T3 ⌘O |

- **Option row.** Radio 16 (multi-select: checkbox, radius `Approval.checkboxRadius`), label prose 14/20, its key
  (`⇧1`) trailing; 34 tall. **R4.** Plain rows, 1 apart: no outline around them, no dividers. Each row's ground
  (radius 8) reaches 12 past the card's column on each side (**R8**), so the radios sit on the column and the keys end
  on the footer's and the ages'. Hover `hover`; pressed `pressed`; picked: accent radio
  and the `chosen` fill. A click picks it; it does not send. **R3.** With a draft under way the keys dim and a picked
  radio shows at half strength (digits are words now).
- **PR badge.** CDS Badge tinted, height 18: `#41 open` success, `#41 merged` violet, `#41 closed` danger. Click opens
  the PR.
- **Buttons that remove a line** (Settle, Snooze, an item's Done, Settle all) are disarmed when they arrive under a pointer
  that has not moved since: they arm on the first pointer move over them. Their chords ignore key repeats. This is the
  2026-10-12 rule (no carry-over from a doubled press), kept without a timer.

### 1.6 Hover peek

- Appears when the pointer is on a line's **name** (not the whole row), unless that line is selected. Gone when the
  pointer leaves the name. No delay, no grace timer; `Motion.fade` in and out.
- Read-only: `allowsHitTesting(false)`. Nothing in it can be clicked, so it never needs a pointer corridor.
- Shell: width 360, the page's floating shell (1.0, **R4**), radius 10; padding 12; placed
  10 pt under the name in the top half of the page, over it in the bottom half (`BriefPanelPlacement`). **R3.** It
  enters with `scaleFade` 0.98.
- Content: last lines (4, body secondary); then by kind, as plain text: the options
  numbered "1 A sidebar with sections"; a plan's first 4 lines; a permission's command; a stop's error line; PR badges
  for Done. No caption under it (2026-11-13: "Click for its card" went from every peek); a line with none of these has
  no peek.
- **R5.** The activity glyphs' peek (pointer on the glyphs, not on a selected line, whose card lists the same): the
  same shell, 360 wide, hung from the glyphs. One row per item, 6 apart: its glyph (10 pt muted, a 14 pt column), the
  words (body `Text.primary`, one line, tail truncation), then trailing, caption 12 muted mono digits: a subagent's name
  · its model as a person says it ("Opus 5.5"; T3's string when it isn't a Claude id) · its age; a background command
  in `CDS.mono(12)` · its age; a wait: what (a thread wait by the waited thread's page name, a command in mono) · its
  age. Ages are from T3's start, else from when Fjord first saw it. Subagents first, then commands, then waits.
- **R8.** An item's peek (the pointer anywhere on an item's row, unless its card is open; hung from the row's words): only what the line doesn't already say. The item's
  detail (body `Text.primary`) when it adds something, then the exact lines of the agent's message behind it, body
  `Text.secondary` behind the card's rail, cut by whole lines at 4 with a bottom fade; each bare link in it shown as its
  address without the scheme (never cut after `https://`). The cut never ends on the blank line between two
  paragraphs: it ends with the paragraph above it, so the rail ends with the words (`RouterQuoteStops`). No caption.
  An item with neither detail nor words quotes the thread's last lines; with nothing at all, no peek.
- **R6.** A working line's peek replaces both the name's and the glyphs' there: the pointer anywhere on the row. 400
  wide, the same shell, hung from the name. The command or tool running now (the working dots in the 14 pt
  glyph column, the words in `Text.primary`, a command in `CDS.mono(12)`, middle truncation) and up to three before it
  (`checkmark`, `Text.secondary`), each with its age trailing; then the activity rows.
- The housekeeping line's peek lists its threads: name, project pill, age. **R3.** It is 400 wide, its names being T3
  titles, whole.

| | Peek | Card |
|---|---|---|
| Trigger | pointer on the name | click on the row, ↑↓, page open, advance after your act |
| Place | floats over the next lines | inline, pushes the lines below |
| Acts | none | options, footer, composer aimed at it |
| Clears "new" | no | yes |

### 1.7 Dock

Floats at the bottom of the page, as the composer does today. From the bottom: composer card, destination row, status
stack; 6 apart (`Composer.dockGap`). The page's bottom inset follows the dock's height.

### 1.8 Composer

The existing `RouterComposer` card, unchanged in look. Changes: no strip of chips above it (the destination row replaces
the strip, the preview chip and the after-send card), and the placeholder names what Return does:

| Selection | Placeholder |
|---|---|
| none | Message your threads |
| question | Answer Settings layout |
| form | Answer “Which channel?” |
| plan | Or say what to change in the plan |
| permission | Or tell it what to do instead |
| Stopped | Tell Disk test how to go on |
| Working | Steer Tab handover |
| Done, Sent | Message Bar count |

Typing anywhere on the page goes to the composer, as today. With an empty draft, digits pick; the first other character
starts a draft and digits are words again. **R3.** The placeholder goes in the frame the first character lands, and a
new placeholder swaps in the same way (old out, new in; never two at once).

**R2.** A new thread's settings are named with `@` (1.9.1): picking one puts a quiet settings pill in the draft (no "@", an
outline, the kind's glyph). The pill is not part of the sent message. Free text never sets anything.

**R3.** Held look: a Return before the read lands keeps the words in the composer, their ink muted, the caret hidden,
and the send button keeps its pressed fill with its glyph in the accent. Typing or Esc takes the words back.

### 1.9 Destination row

One row, body 13, height 24. **R4.** It has no ground of its own: a line of words over the composer, its arrow on the
composer's text edge. Only what can be chosen in it has a ground (the lit place of several, a new thread's settings).
It shows only when Return would send something: a draft, or a picked option. It enters and leaves with `.scaleFade` +
`Motion.spatial`.

```
→ [? Settings layout fjord]  “One scrolling page”                       picked option
→ [? Val Cenis booking]  answers its question                           sure, free text
→ [✓ Bar count fjord]  starts a new turn                                sure, idle thread
→ [··· Tab handover fjord]  steer now · ⌥ queue                         sure, working thread
→ [··· Tab handover fjord]  queue after this turn                       while ⌥ is held, or an agent that can't take words mid-turn
→ [▲ Disk test silo]  “Continue where you left off.”                    Stopped card, empty draft
→ new thread in silo  [Opus 5.5] [High] [Auto] [Build] ⇥                sure, new thread: what it starts with (1.9.1)
→ Fjord answers here                                                    the Router answers itself
→ [Settings layout fjord ⌘1]  Tab handover fjord ⌘2  new thread in fjord ⌘3  steer now · ⌥ queue ⌄   unsure
→ not sure where this goes: pick a place  ⇥ ⌄                           no guess
◐ ▬▬▬▬▬▬                                                                first read, nothing selected
```

- `→` is `arrow.right` 10 pt `CDS.Text.accent`. A form with questions left adds, after the words, "· 1 more to
  answer", and the send button is dim (**R3**). With T3 away the words read "T3 Code isn't reachable" and Return keeps
  the words in the composer (**R3**). The mode words by state: a question "answers its question" or "answers
  it"; a form "answers “<its current question>”"; a plan "asks for changes to the plan"; a permission "denies it, with
  your words"; Stopped and Done "starts a new turn". A place is the thread's mark, its page name (body medium
  `Text.primary`) and its project pill: the same three things as on its line, so it is recognised at once. The mode
  words are body `CDS.Text.muted`.
- **Unsure (R4).** Up to three places, each its mark, name, pill and key (`⌘1`), 20 tall, 2 apart, on no ground. The
  guess is first and lit: the `chosen` fill, radius 6, its name in the primary ink (the others' in the secondary).
  ⌘1–3 or a click moves the light: one ground that slides from place to place (`Motion.glass`), as the filter bar's.
  A pick you made yourself is lit in the accent's tint (24 %): it came from you, and no later read changes it. No
  outline either way. Every place keeps its width whichever is lit, so nothing but the light moves; what Return does
  at the lit place is said once, after the places (it swaps when the light moves), always. When the row is short of
  room the places lose their project pills.
- **No guess (R3).** The key `⇥` shows; Tab opens the places menu (↑↓ Return, Tab or Esc closes it). A guess waved off
  with Esc is asked again when the draft grows or another card is selected. A Stopped card with an empty draft shows
  the Continue words as its place.
- **Reading (R2).** While the Router's model reads the draft (every read: the first, and each one after more typing),
  the arrow's slot holds **Fjord's mark as its loader** (`FjordLoader`, the same one the hub and the update button
  use): 14 pt (**R3**; 13 pt, `CDS.Text.secondary`, after a line's words), `CDS.Text.accent`, cross-fading with the arrow
  on `Motion.fade`. **R3.** The mark starts as the whole mark each time it appears (it no longer takes the wall clock's
  phase: at that phase it often came in as a trace). The mark is the Router thinking; the
  arrow is its decision. Nothing else in the row moves, so what it already shows stays readable while you type.
  Before the first read lands: with a thread selected, the row shows that thread at once (the selection is the
  prior); with none, the mark and a skeleton bar where the place will be (96 × 8, `alpha(0.06)`, the sheen). There
  are no words: no "reading…". The skeleton's sheen is a light band in both looks. Reduce Motion: the whole mark,
  still.
- **Return before the read lands (held) (R3).** The words stay in the composer (held look, 1.8), the mark stays in the
  arrow's slot, and the row has no words. When the read lands sure, the words go: to the new thread, or to the
  selected thread the row showed, if the read agrees; or, when the row showed only the skeleton, to where Fjord is
  sure. Unsure, or disagreeing: the row shows the places and Return is asked again. Typing or Esc takes the words
  back. This replaces the Round 1 rule "Return never sends to a place the row has not shown"; it is what the real app
  does (t3-code-map §12).
- The trailing chevron opens the existing places menu. There is no ×: Esc waves the guess off.
- ⌥ held flips "steer now" to "queue after this turn" live (`NSEvent` flags changed), words cross-fading on
  `Motion.fade`.

### 1.9.1 A new thread's settings (R2)

When the row's place is a new thread, the mode words' place holds what the thread starts with, as chips. T3's
`orchestration.launchThread` takes them (`modelSelection`, `runtimeMode`, `interactionMode`).

```
→ new thread in silo  [Opus 5.5] [High] [Auto] [Build] ⇥                 T3's defaults (this install's)
→ new thread in silo  [Opus 5.5] [(High)] [Auto] [Build]                Tab into the row: ring on a chip, ↑↓ open its menu and move through it
→ new thread in silo  [Opus 5.5] [Medium] [Auto] [Build]                after the pills @Opus 5.5 and @Medium
→ new thread in silo  [Opus 5.5] [High] [Supervised] [▤ Plan]           plan mode on
```

**R3.** The defaults are this install's (FEASIBILITY.md): Opus 5.5 · High · Auto. All four chips always show, Build
quietly. After the last chip the key `⇥` says Tab goes in; it is hidden while the keyboard is in the row.

| Chip | Values (menu order) | Default |
|---|---|---|
| Model | T3's models, by its picker's names; the provider after each in the menu (here Fable 5.2 · Opus 5.5 · Sonnet 5.5 · Haiku 5.5) | T3's default model (Opus 5.5) |
| Reasoning effort | Low · Medium · High · Extra high · Max (the model's own list) | the model's default (High) |
| Access (T3's runtime mode, under T3's names) | Supervised · Auto-accept edits · Auto · Full access | T3's (`auto` here) |
| Mode (T3's interaction mode) | Build · Plan | Build |

- **Chip.** Height 18, radius 4, padding 6, sans 12, 4 apart. **R4.** No outline: the `quiet` fill and
  `CDS.Text.secondary` at T3's default; the `chosen` fill and `CDS.Text.primary` when it differs from it (so what you
  changed reads at a glance). Hover one step up; pressed or menu open `pressed`.
- **The mode's chip** is always there (**R3**): `Build` quiet, or when plan mode is on `Plan` (`list.bullet.clipboard`
  9 pt) in the lit ink.
- **Three ways to change a setting, all live; none sends.**
  1. **Keyboard.** Tab moves from the words into the row (ring on the first chip), Tab again to the next chip and
     after the last one back to the words; ⇧Tab the other way. ← → move across the chips. **R3.** ↑ ↓ on the ringed
     chip open its menu (the one a click opens) and move through it, the value applying as it moves and its row lit
     (no wrap); Tab, ← →, Esc, Return or a character close the menu. Return still sends; Esc goes back to the
     words; any character typed is the words' again. Ring: the page's (1.0, **R4**), as the filter
     bar's; **R3.** it slides between chips (`Motion.glass`) and goes when the pointer enters the row. No letter key is
     involved, so it is the same on AZERTY.
  2. **Click.** A chip opens its menu above it (CDS menu, 220 wide): a title, the choices, a check on the current
     one. A click on a choice sets it and closes the menu; Esc or Return closes it. 
  3. **With `@`.** Typing `@` in the composer opens the mention list (threads, projects), which also has a **Settings**
     section: T3's models (by name, slug and its aliases: `@op` finds Opus 5.5), the efforts and the access the row's
     model takes (`@med`, `@low`, `@supervised`, `@auto-accept`, `@full`), and `@plan` / `@build`. Typing after the `@`
     filters it as it does threads (a setting is found by a prefix, a word or a substring, never by loose letters).
     Return or Tab on a row makes a **settings pill** in the draft and sets that chip at once, with the roll below.
     The pill is quieter than a thread's: no "@", the `quiet` fill at a token's radius and no outline (R4), the kind's glyph (cpu, gauge, lock, clipboard).
     It is **never sent**: it is taken out of the message with the space after it. ⌫ takes it out like any pill and the
     chip goes back to your pick, else T3's default. A pill beats a chip you set by hand before it; a chip you change by
     hand afterwards beats the pill. Two pills of one kind: the last wins. With the row on an existing thread the pill is
     dropped from the message and sets nothing. **R4 (owner, 2026-11-12):** free text never sets a setting: "use opus
     for subagents" and "don't edit anything" are for the agent. The decider reads no settings (no `launch`, no
     `launch_words`); a model never turns words into a runtime mode.
- **The change.** The value **rolls**: the new one comes in from below when it is further down its list and from
  above when it is further up, the old one leaves the other way, inside the chip (13 pt travel,
  `RouterV2.roll` = spring 0.34, bounce 0.22); the chip's width follows on the same curve. **R3.** Both faces are drawn
  once and moved by one progress, keyed on a count the model moves in the same mutation as the value; the old face is
  gone by the roll's middle; the faces fade at the chip's top and bottom edge, so there is no hard cut. A setting a pill sets also **glows**: the
  accent's tint (24 %) over its ground, no ring (**R4**), held 0.35 s then fading over 0.9 s; several roll one after the other, 70 ms
  apart, so the eye follows the sentence into the row. Reduce Motion: the values cross-fade in place; the glow stays
  (a colour, no movement).
- **Who wins.** The last act: a pill beats an earlier hand pick, a hand pick beats the pills. Taking the pill out puts it back to your pick, else T3's default. Settings last for the draft
  only: the next new thread starts from T3's defaults.
- **Unsure, and you light a new thread yourself** (⌘3): the row shows that chip and its settings; the other places
  fold into the menu (⌘1–3 still light them, Esc brings them back), so the row never outgrows the column.
- **Accessibility.** The row reads "Starts a new thread in silo with Opus 5.5 · High · Auto"; each chip is
  a button, "Model: Opus 5.5".

This replaces the 2026-11-06 rule "Fjord offers no model or provider choice" (`t3-code-map.md`), for new threads only.

### 1.10 Sent line

A sent message is the thread's own line, in state Sent, at the top of Working:

```
  ↑ Settings layout  “One scrolling page” sending…                   fjord  now
```

- Your words: sans 14 `CDS.Text.primary`, in curly quotes, one line. Status after them in `CDS.Text.muted` with the
  sheen: `sending…` (to an idle thread or a request), `steering…` (to a running one). When T3 has taken them the status
  goes; there is no "delivered". **R3.** Steering lasts until the running tool stops (about 3 s in the demo). A thread
  started here shows its model and effort after the words (`Opus 5.5 · High`).
- When the run starts, the line becomes Working: the mark cross-fades to the working dots and the words cross-fade to
  the running step (`Motion.fade`).
- **Queued** (⌥Return on a working thread): the thread stays Working with its step, and gets a second row inside its
  line, 22 pt high, indented under the name:
  `↑ “then delete the old checkpoint image too” · queued, sends when this turn ends   Cancel`. Footnote; words
  `Text.secondary`, the rest `Text.muted`; `Cancel` is a ghost text button that puts the words back in the composer.
  When the turn ends the row rises into the line, which becomes Sent.
- A new thread's line is born Sent: its name is your first words (28 characters at most) until the model names it.

### 1.11 Failure line

In the status stack, one per failed send, until handled:

```
▲ “also bump the version” didn't go to Bar count: T3 Code isn't reachable.     Edit   Send again ⏎
```

- Height 34, radius 8, the Stopped banner's ground (`RouterV2.dangerFill`), no ring (**R4**), padding 10. Mark
  `exclamationmark.triangle.fill` 11 pt `Text.danger`; your words body `Text.primary`; the rest body `Text.secondary`.
- `Send again`: the page's button (24 tall, the chosen fill). `Edit`: ghost; it puts the words back in the composer and removes the
  line.
- The thread's own line goes back to the state it had before the send (an answered question is asked again, its option
  still picked). **R3.** With T3 down the failure comes at once, with the connection line under it. Once T3 is back
  the reason is dropped: "“…” didn't go to Snapshot API."
- **R3.** It takes the keyboard when it appears, if the draft is empty and nothing is selected or the selected line is
  the one that failed: the page's ring (1.0) on `Send again` (what Return presses). `Edit` shows ⌘⌫ while the
  line has the keyboard.
- Enters with `.scaleFade` after the stack has made room (0.08 s), and, 0.2 s after it is there, shakes once: one short
  horizontal shake (6 pt, 2 cycles, 0.3 s; none under Reduce Motion).

Connection line, same stack, when T3 can't be reached: `T3 Code isn't reachable. Reconnecting…` Footnote
`Text.secondary`, mark `wifi.slash` `Text.muted`, no fill. It leaves when T3 answers. It is the page's only "stale" mark.

### 1.12 Housekeeping line

Last row of the list, after Working: `5 finished earlier, not settled` in body 13 `CDS.Text.muted`, then `Settle all`
(ghost sm, footnote 12) trailing. Older = finished more than 24 h and less than 7 days ago; those threads have no line
of their own.
Hovering the words shows the peek with their names. In the ↑↓ walk (selected: the `quiet` fill, radius 8, no outline,
**R4**); ⌘⌫ on it settles all. With one such thread the row
reads `1 finished earlier, not settled` and the button `Settle`. **R3.** The ghost buttons (Settle all, Edit, Clear
filter) are footnote 12.

### 1.13 Revert toast

- One slot, top of the status stack, leading. **R3.** One view: a new act swaps its words and the width follows. It
  enters with `scaleFade`. Height 28, radius 8. **R4.** The `chosen` fill, no edge, no shadow (it sits on the
  dock's ground, over nothing). Body 13: the act in `Text.secondary`, the thread's name in `Text.primary`; then `Revert` in `Text.accent`
  medium and its keys ⌘Z.
- Copy: `Settled Briefs migration` · `Settled 5 older threads` · `Snoozed Val Cenis booking until tomorrow, 9:00` ·
  `Moved Upstream issue to Done`. **R3.** The snooze menu's title is `Snooze`, its items `For 1 hour` · `For 3 hours` ·
  `Until tomorrow, 9:00`; it hangs under its button in the top half of the page (over it in the bottom half), trailing
  edges aligned.
- A new act replaces the toast (swapping its words). It leaves after 8 s, or when reverted. **R3.** The clock stops
  while the pointer is on the toast and starts again when it leaves (no re-armed timer). After that, Revert is in the History drawer, as today.
- Each act registers with the window's `UndoManager`, so ⌘Z is Edit ▸ Undo (found by character: right on AZERTY) and
  text undo in the composer keeps its normal order.
- Revert puts the line back where it was (it grows back in place) and selects it.

### 1.14 Empty states

| Case | What shows |
|---|---|
| No Needs-you line, other lines exist | in the header's place (the same row, 1.3): `Nothing needs you.` prose 14 `CDS.Text.secondary` |
| **R5.** Finished threads whose verdicts are pending (a cold launch) | never `Nothing needs you.`: `Reading 2 threads…` + Fjord's mark, same style, in the header's place (under the Needs-you lines when there are some); the threads being read are listed under it (newest first) with a dashed circle (`circle.dashed`, muted) for a mark, no check, the sentence sheening with the mark after it. They count on no token (not Done, not Needs you), only on the pills; a Working filter hides them. Each leaves the group as its verdict's state lands (2.3). Shot `v2-cold-reading`, storyboard beat 44 |
| No line at all | `Nothing needs you. Nothing is running.` same style; no filter bar, no housekeeping line; placeholder "Message your threads" |
| Filter on, nothing needs you there | `Nothing needs you in fjord.` |
| Filter on, no line at all | `No threads in docs-site right now.` + ghost `Clear filter` |
| Router off | today's sentence, unchanged |

All the sentences are the first row (1.3); the bar's place stays. The sentence fades in (`Motion.fade`) as the last
Needs-you line leaves. The sidebar's Router badge is the unfiltered
Needs-you count and disappears at 0.

### 1.15 Open items (R7)

**R7** (2026-11-13, owner-approved, [OPEN-ITEMS.md](OPEN-ITEMS.md); `RouterItems.swift`, `RouterItemLedgers.swift`,
`RouterDemoItems.swift`, shots `v2-items`, `v2-items-card`, `v2-items-checking`, `v2-items-resolved`, `v2-items-hover`,
beat 45). A running block's working peek hangs under the whole block (over it in the page's lower half), never over its
items. A thread keeps a ledger of what is open with
you (`RouterThread.ledger`): items of four kinds, each with an id, a sentence, an age, options if any, and a state (open,
checking, closing with how, new).

| Kind | Mark | Tint | Section |
|---|---|---|---|
| Stuck | `exclamationmark.octagon.fill` | `Text.danger` | Needs you, first |
| Decide | `questionmark.circle.fill` | `Text.warning` | Needs you |
| Do | `checklist` | `Text.warning` | Needs you |
| Know | `info.circle.fill` | `Text.accent` | Done (worth a look) |

- **One block per thread**, in the section of its most urgent open item (a real stop stays Stopped). **Always the list
  shape** (owner, 2026-11-13): a thread with any open item, even one, is its own line with its items listed under it,
  one a row; there is no line that is its one item. The line (the block's header): its name with the most urgent
  item's mark and tint on the name's ground (so a block reads as one thing, its colour on its name), then the thread's
  own sentence, flowing and wrapping as a line's (never cut): Done's outcome (`Text.secondary`), or while it runs the
  working dots and the newest summary (`Text.muted`), or nothing while it waits on you or is being read
  (`RouterBlockHeader.words`); project pill, age. A thread's first item swaps its line for the header in place, at the
  same height (no crossfade), and only the item's row folds in; its last going does the reverse. Under it, one 28 pt
  row per item: the kind's mark alone in its tint (no ground, no word; the accessibility label says the kind) under the
  name's words, the sentence (14, `Text.secondary`), the item's age. The block has 4 pt of air under it.
- **T3's requests and stops are items** (owner, 2026-11-13; `RouterThread.requestItem`, `RouterModel.threads`). A
  question, a form, a plan or a permission is a Decide row (each is answered by a choice; a permission's allow or deny
  too), a real stop a Stuck row, first in the thread's block, in the line's words (the code's or the model's, sheening
  while it is read again) and its age. The thread's line has its own sentence (Done's outcome, the run's summary, or
  nothing). Its card is the request's: the plan or the command, the options or the form, Continue for a stop, then
  `Done` · `Open in T3`; its picks, Return and ⌘⌫ are the thread's own. Done (on the card or on hover) is the thread's
  Settle, off with why while T3 holds the thread (a question, a form, a permission). Selecting the thread opens the
  request's card; a click on the header opens the header's. The reads never keep, close or add it; it goes when T3's
  request does. There is no line that is a request any more: a waiting or stopped name takes Decide's or Stuck's mark.
- **Done's mark is grey** (owner, 2026-11-13): a Done line's check, the Done filter token and section title, and the
  finished-earlier peek's checks are `Text.muted`; blue (`Text.accent`) is only Know's and a line the model marks worth
  a look (with its ground). The history's finished rows were already muted.
- **Working counts it faintly**: "Working 3 +1", the `+1` in `Text.disabled`, for running threads shown in another section.
- **R8. The whole sentence.** An item's sentence is never cut (at most 3 lines, a guard): it flows as text. On the line
  the name is its highlight at its start, and a line it wraps to starts at the name's ground's left edge and runs to the
  pill; in a block a line it wraps to starts under the kind's mark (`RouterFlow`: the first line starts with a blank as
  wide as the name or the mark). The first line runs to the pill too: the text ends with an invisible word (`RouterFlow.end`), as
  macOS's breaking would otherwise push a word down rather than leave one alone on the last line. The mark, the name, the pill and the age stay centred on its first line.
- **R8. An item's card**, in order: the detail (prose 14/20 `Text.primary`), the quote (the agent's lines behind the
  item, as the card's last lines: rail, 4 lines, fade, Show all `→`), links the quote doesn't show (in the detail) as quiet buttons; a link in the quote is clickable there, never doubled (22 tall,
  radius 6, the `quiet` fill, `chosen` under the pointer; `↗` and the address without its scheme, footnote 12
  `Text.secondary`, middle truncation), the options, then `Done ⌘⌫` · `Open in T3 ⌘O`. Never empty: an item with no
  detail, quote or options quotes the thread's last lines. An item's card hugs its row: its ground (as its row's
  pointer ground) starts at the item's mark gutter, as far before the item's mark as a line's ground starts before the
  line's mark (`Router.Items.groundLeading`), and its content column is the item's words' column. The header's card
  keeps the whole line's ground. Shots `v2-item-line-wrap`, `v2-item-peek`, `v2-item-peek-row`, `v2-item-card` (a
  one-item thread's item), `v2-item-card-block`, `v2-item-single`. The read fills them (`RouterItem.detail`, `.quote`, saved with the item): each
  found item has its `sentence` (key fact first), a `detail` (the whole item, at most about 280 characters, only when it
  adds something) and a `quote` (the agent's exact lines), kept only when it is word for word in the reply or message
  read, else dropped (`RouterItemsReading.quote`). Items saved before have neither and quote the thread's last lines.
- **One layout, one history** (the engine's side, 2026-11-13). Every record has `summary: RouterSummary` (sentence, detail,
  facts as chips, source): Done's is its last turn's outcome (the items read's `line`, `detail` and `facts`, EVAL-items.md
  "Done's outcome") with code's chips first (each pull request and its state, its link; the diff's files +/−) and the
  agent's last message as source; Working's its newest summary with its subagents, background commands and waits as chips
  and the agent's latest words; Stopped's its stop; an item's (`RouterItem.summary`) its sentence, detail and quote. Its
  sentence is the settled one, never words still streaming. `history: [RouterEvent]`, newest first, 40 at most: the
  summaries (`s<id>`), run starts (`r<run>`), items raised and closed (with how) and turn ends with their outcome, kept for
  every state while the thread is on the page (in the verdict file, optional fields), gone with its summaries when it
  leaves. `work.summaries` and `work.starts` are filled in every state.
- **↑↓** walk the header, then each item. The header's card is the thread's (the working timeline); an item's card is its
  options (they pick; Return sends the picked words to the thread, the destination row says so) and `Done ⌘⌫` · `Open in
  T3 ⌘O`. Done strikes the item "done by you", folds it after 1.6 s, and the toast offers Revert. The open card's ground
  is under its own row only.
- **Done on hover** (2026-11-13). The pointer on an item's row swaps its
  age for a quiet `Done` (footnote 12 `Text.muted`, its last letter where the age ends; under the pointer
  `Text.primary` on the `chosen` ground, radius 4), `Motion.fade`, drawn over the age so nothing moves. The card's
  own act: struck "done by you", Revert in the toast. It arms on a pointer move over it (a row sliding under a still
  pointer isn't done by it). None on a struck item, a read's preview, or a row whose card is open. Shots
  `v2-item-hover-done` (the pointer on Done) and `v2-item-single` (a one-item thread's row under the pointer).
- **Your words to a block** (Return): in the same frame `↑ "…" · sent` (13, the arrow in the accent) under the items,
  every open item sheens (`Text.muted` + the sheen), and Fjord's mark sits at the end of the header's words, where the
  activity glyphs are, so nothing moves. Nothing reads settled until the read lands.
- **A new turn**: the header's ground lights once (`chosen`, 0.7 s ease-out), the items sheen, a faint "reading the new
  turn…" (13, `Text.disabled`, sheening) where new items land.
- **The read lands** (`RouterLedger.land`): a closed item strikes in `Text.muted` with its how after it (12,
  `Text.secondary`: "answered by your message", "done by the agent", "no longer open"), its kind faded, for 1.6 s, then
  goes; a new item comes in on its kind's 12 % ground, which fades; a merged item stays and its age resets; the rest
  stop sheening.
- **The engine** (`RouterItemLedgers`, `RouterItemsPrompt`, EVAL-items.md, REVIEW-items.md). One read per input, in
  order, one at a time per thread: every turn the agent ends (Done or Stopped; a run that is no longer the latest is read
  too, so a turn woken at once by a background task's end is never lost, and a run starting again never cancels a read;
  turns that ended while the thread was off the page are read in order after it, and those between the last one read and
  it, which ended while Fjord was closed, before it; a turn that ends while its subagents or background work go on is
  ended: T3 shows the thread working, but its reply is read as it ends), every whole message the agent posts while its
  run goes on (`said:<T3 id>`: a question asked mid-run is a Decide as it is asked; read with its own prompt, which finds
  items and writes no line; one read in flight per thread, at most one a minute, the newest waiting one read at the
  gap's end or as soon as anything is queued behind it; it doesn't sheen the items) and every message of yours (sent here:
  shown at once, read once T3 takes it, never if T3 refuses it; from T3's composer or the phone: each message T3 stamped
  since the last one seen, listed from a projection read made after the stamp, by T3's id; read before the turn that
  ended after it; not read when nothing is open, nor when the turn after it is the one it started). Each input is a
  **pending entry in the verdict file**, written in the same write that marks its trigger seen, keyed by its own id
  (`turn:<run>`, `msg:<T3 id>`, `sent:<ms>`); it leaves only when its read's answer is applied. A read that fails
  (offline, a usage limit, Claude Code missing) keeps it pending and is made again after a wait (30 s doubling to 10 min),
  when T3 moves, or after a relaunch. A projection read that fails or doesn't have the input yet is made again a few
  times (2, 4, 8, 16 s), then the input goes on with what is known: an answer that doesn't read twice, or a turn or
  message T3 never lists, leaves a Know saying so ("a turn couldn't be read: open the thread…"), so nothing goes
  silently and nothing behind it waits. The read sees the open items with their ids and ages and the input (the turn's
  reply, what started or woke it, the PRs; or your words and the reply they answer), and says per item keep or close with
  how (answered, done, obsolete), then what is found: new, or the same as an open item (merged: its words and age new, no
  duplicate), then the turn's line (Done's sentence, only the latest run's). Sonnet, effort low, streamed: closes strike
  as soon as their field is whole, found items land, the line streams. The ledger is kept per thread in the verdict file
  (version 3; a version 2 file keeps its names, told banners and summaries). Settle keeps what was open, and the read
  under way, until a new run starts: its Revert puts them back. Done keeps the item in the file too: its Revert works
  after a relaunch, and a read under way that restates it doesn't bring it back. A thread first seen (a first launch)
  reads its latest input, however old, paced by the queues (four projection reads and four model calls at once). A new
  Stuck, Decide or Do item is told once as a banner, only for an input this run of Fjord saw happen (not one that ended
  before the launch, nor one left pending by the last run), while fresh and unseen (a mid-run question: as it lands);
  a banner names the thread by its page name, never T3's title. A one-item thread is a block through a read too (your words and the placeholder
  under its item). No legacy: a finished turn has no verdict of its own.
- **Motion.** A block moves as lines do, on `Motion.spatial`, with nothing at once and no whole-block fade. Its rows
  under the open card are on a layer of their own that glides with the card's mask and the lines under the block
  (`RouterBlockTail`, `RouterGlides`), so a card opening or shutting between its rows rolls in place, at full opacity,
  with its ground. The ground is there whole as a card opens and stays under it as it rolls shut, gone as the roll
  lands (an ease-in as long as the roll); the same under any line's card. A card moving to another row of the block (↑↓,
  a click on another item or on the header) is one motion (~0.3 s): the old card rolls shut under its row while the new
  one opens under its own, on the same spring from the same frame, the rows between gliding with them
  (`RouterBlockLeave`); no row jumps between the line's rows and the rows under the card. Between lines too: the old
  line's card stays whole while its slot's mask rolls it shut, so it never goes in a frame and leaves its height bare. An item, your words or
  the "reading" row arriving or leaving folds in or out as a line does (height from or to nothing, its opacity only in
  the fold's last part), and the rows after it slide on the curve the block's height glides on (an open card and its ground
  below a folding item too: its place glides with the rows above it); a struck item folds after its 1.6 s. A new item's ground fades over 0.6 s once it is seen. The name taking another kind's colour (its
  most urgent item changed) fades (`Motion.fade`) and its mark rolls over. Your words to a block leave it where it is
  (no flight). Reduce Motion: the folds fade and the rest eases out in 0.12 s.

### 1.15.1 Wide windows (open)

The page's column is 720 pt at any window width, centred (shot `v2-items-1600`).

A first wide layout (the column growing to 1120 pt, a block's name, project and age in a 180 pt left column, a hairline
down its rows) was turned down by the owner on 2026-11-13 and is removed: the ages ended up far from their words and
the names from their content, and a thread's own sentence should have no rail. Four other ways to use a wide window
are built behind a demo-only switch, with a recommendation, for the owner to choose from:
[WIDE-OPTIONS.md](WIDE-OPTIONS.md) (`FJORD_WIDE=a|b|c|d`, shots `v2-wide-<a..d>[-card]`).

## 2. Thread state model

### 2.1 The record

One record per thread: a **code state** plus a **model verdict** cached by fingerprint (last turn id, pending request
id, PR states, your last message to it).

| State | Set by | When | Leaves when |
|---|---|---|---|
| Needs you (question, form, plan, permission) | code, same frame | T3 request or plan appears | you answer, the request is withdrawn, Settle, Snooze |
| Needs you (an open Stuck, Decide or Do item) | model | **R7.** a read of a turn or of your words leaves one open (1.15) | the read that closes it, its Done, Settle, Snooze |
| Stopped | code | **R3.** a run T3 failed (a provider or transport error, a usage limit with no resume). A failed test or build is a finished turn: Done, and its read may then leave an open item (1.15). An interrupt you asked for is Done ("stopped by you") | Continue, your message, Settle, Snooze |
| Sent | code, at Return | you send or answer | T3 shows the run started → Working; failure → previous state |
| Working | code | a run is active (also: paused at a limit with auto-resume) | the run and its background work end |
| Done | code | last run ended with no request | new turn, Settle, Snooze, 24 h (then housekeeping) |
| new dot | code | T3 `unseen` | its card opens here, or it is opened in T3. Never moves the thread, never changes a colour. **R3.** A card you open clears it at once; a card your own act advanced to clears it at your next key or pointer move |

What the model writes, and nothing else: the short **name** (once per T3 title), a T3 ask's **line**, and (**R7**) a
thread's **open items** with a finished turn's **line** (1.15). A thread with an open Know is worth a look. Icon, colour, section, counts, age, PR state words, options of T3 requests and
every state above marked "code" are never the model's.

Order inside a section (stable, so nothing above your eyes moves):

- Needs you: asks, longest waiting first; then Stopped, longest first. A new ask enters at the end of the asks.
- Done: worth a look, newest first; then quiet, newest first.
- Working: Sent, newest first; then running, latest start first.

Selection:

- On page open: the first Needs-you line, card open. None if there is none.
- After your answer or send from a card: the next Needs-you line; none left → no selection.
- After Settle, Snooze, an item's Done: the next line of the same section; none left → no selection.
- T3 events never move the selection and never open a card. If the selected thread leaves because of T3, the selection
  goes to the next line of its section.
- The page scrolls to keep the selected line and its card in view (`Motion.follow`).

### 2.2 A line being reassessed

When a thread's fingerprint moves, in the same frame: the old model line is dropped, the code state and code line are
shown (table in 1.4), the line moves if its section changed, counts tick. Then, until the verdict lands:

- The sentence draws in `CDS.Text.muted` with a **sheen**: a band of `Transcript.shimmerPeak` 40 % wide, sweeping left
  to right across the sentence's own width, 1.4 s, linear, repeating (**R3**: it sweeps so that the band is on the words
  the whole pass). Core Animation (a `CAGradientLayer` whose
  `locations` animate, masked by the text), so SwiftUI draws nothing per frame (Motion rule 4).
- **R2.** After the sentence, 6 pt away: **Fjord's mark as its loader** (`FjordLoader`), **R3:** 13 pt,
  `CDS.Text.secondary`. The sheen says which words are about to be replaced; the mark says who is at it. **R3.** Each
  mark starts as the whole mark when it appears; marks are not put on a shared phase. It goes with the sheen, on
  `Motion.fade`.
- Only the sentence. The state's mark, name, pill, age, the card and its options stay solid and usable: you can
  answer a T3 question while its line is still being shortened.
- No spinner, no label ("reading…", "Rewriting"), no clock anywhere on the page: the mark is the only sign of the
  model at work, here and in the destination row (1.9).
- Reduce Motion: no sheen; the muted code line and the whole mark, still.

### 2.3 The model's line arriving

- **R3.** The verdict's state comes first (the demo: at 1.9 s). If it changes the section (Done → Needs you), the
  line moves at once (2.4), still sheening. A finished thread has already moved to Done in code, so it can move twice;
  that is the owner's decision, and it is shown as it is (beats 14, 17), and so is a turn that starts again inside the
  sheen (beat 34).
- Then the words (the demo: from 2.0 s, done by about 2.5 s): the model's words appear one by one in the same place,
  each fading 0 → 1 over 0.12 s (ease-out), no movement, at the rate they arrive (the demo: one word every 50 ms).
  Implement with a `TextRenderer` whose animatable progress is the number of words shown. **R3.** One text taking
  another's place (a sentence, a name, the placeholder, the row's words, the toast, a caption) swaps: the old one out
  in 0.06 s, then the new one in over 0.12 s (`routerV2Swap`), so the two are never read on top of each other. When
  the new line's words are the same (a PR merged), nothing streams and the sheen just goes. A name being given slides
  the sentence (spatial).
- The colour settles from muted to the sentence's colour as the first word lands.
- A name being given (first verdict of a new thread) sheens with the mark after it (R2, as 2.2), then cross-fades
  once, on `Motion.fade`.
- Reduce Motion: the whole line fades in at once (`Motion.fade`).
- **R3.** A verdict is dropped when a run starts meanwhile: the line goes back to Working and no line is written. At
  most four verdict calls run at once; the others wait, sheening.

### 2.4 A line changing section

- All rows (headers, lines, housekeeping) are one `ForEach` with stable ids (not lazy: at most ~60 rows). **R4.** They
  are declared in an order that never changes (by id) and laid out in the page's order by `RouterV2Stack`, a `Layout`
  that reads each row's place. A reordered `ForEach` in a `VStack` takes the row out and puts it back in (it folded
  away and folded in again: it never glided); a row whose place alone changes is the same view, and SwiftUI moves it.
  `matchedGeometryEffect` is used only for a ground that slides (the active filter, the lit place, the ring).
- Curve `RouterV2.lineMove` = `.spring(duration: 0.45, bounce: 0.14)`: a little longer than `spatial`, so the eye can
  follow it. The lines it passes slide by one row on the same spring.
- **R4. It glides as itself.** No plate, no edge, no shadow, nothing lifted. It is drawn over the rows it passes, and
  the crossing is solved by motion: the words it passes fade out under it and come back behind it (`RouterV2Veil`: the
  page's own ground, whole behind the line's words and fading to nothing 7 pt past the row, so there is no edge to
  see). The veil is there from the frame the line takes off and fades once it has landed in the gap the rows opened
  for it. A card that opens in the same act (you answered: that line leaves and the next card opens) opens its place
  at once and shows what is in it 0.14 s later, over 0.16 s (`RouterV2.cardAfterFlight`): the line has passed by then,
  so it never crosses a card's words. No curve is set on the list as a whole (one was, for the first row's swap, and
  took the glide from every line whenever that row changed).
- In the same transaction: mark and tint cross-fade (`contentTransition(.symbolEffect(.replace))` for the mark), the
  name ground fades in or out, both headers' counts tick (`numericText`, `.snappy`), a header appears or leaves with its
  first or last line (`.opacity` + height).
- Reduce Motion: the line fades out where it was and in where it goes (ease-out 0.12); counts change with `.opacity`.

## 3. Live updates from T3

**R3.** Demo latencies (scripted, the ones FEASIBILITY.md measured): T3 takes a send in 0.35 s; a run starts 0.9 s
after a send; a steer lands in 3 s ("steering…" sheens until then); a verdict's state lands at 1.9 s and its words
from 2.0 s, one every 50 ms, done by about 2.5 s; at most 4 verdict calls run at once and the others wait, sheening; a
verdict is dropped when a run starts meanwhile; a destination read takes 0.5 s when it is a sure follow-up to an idle
thread, and 3.2 s for a new thread, an unsure place, a running thread, or settings in the words; a new thread's name
comes 2.2 s after its start; a PR's state reaches T3 within a minute of the event. In the real app these are whatever
they are; nothing in the page waits a fixed time.

| T3 event | At once (code, same frame) | Marked as about to update | Final |
|---|---|---|---|
| **Turn ends**, no request | Working → Done: mark ··· → ✓, line "finished", moves to the top of Done, counts tick, new dot | sentence sheens | result line streams. `look`: blue ground fades in. `quiet`: stays plain. `needs_you`: turns amber with the `checklist` mark and moves to Needs you, then the ask streams. **R3.** A run that starts again before the verdict lands puts the line back in Working, no line written |
| **Turn ends on an error** (a failed test or build) | **R3.** The same as a turn that ends: Done, "finished" | sentence sheens | the verdict flags it: `needs_you`, the ask streams ("the build fails: …") |
| **New request** (question, form, plan, permission) | → Needs you with the kind's mark, line = T3's words verbatim, moves to the end of the asks, counts and sidebar badge tick, new dot. Card complete at once (options are T3's) | sentence sheens | the short line streams |
| **Run starts** (your send, a Continue, T3 on its own) | → Working: working dots, line "starting", then the step; moves under the Sent lines | nothing (code only) | step words cross-fade on each new step (`Motion.fade`); age ticks on the minute |
| **Step changes** in a run | the sentence cross-fades to the new step | nothing | — |
| **Failure** (a real stop: a provider or transport error, a usage limit with no resume) | → Stopped: red triangle, "failed: " + error's first line, moves to the end of Needs you, counts and badge tick | nothing (code only) | — |
| **Usage limit, auto-resume** | stays Working; dots stop; line "paused at the usage limit, resumes 15:00" | nothing | Working again when it resumes |
| **PR opens / merges / closes** (**R3:** up to a minute after the event) | the state word after the PR link flips colour and pops (scale 1.25 → 1, `.spring(duration: 0.35, bounce: 0.3)`, **R3**); the card's badge too | sentence sheens (PR state is in the fingerprint) | new line streams; a merged PR can turn `look` into `quiet`, or an ask ("merge #41") into Done |
| **Settled, snoozed or archived in T3** | the line leaves (height + fade, `Motion.spatial`), counts tick. No toast: it wasn't done here | nothing | — |
| **New thread** | a line grows in (height + fade) in its state's section: T3's title as the name (28 characters), new dot; its project's pill count ticks, or a new pill scales in (`.scaleFade`) | the name and the sentence sheen | the short name cross-fades in once; the line streams |
| **Unsettled / snooze over / reopened** | as a new thread | as above | as above |
| **Queued message's turn ends** | the queued row rises into the line: Sent with those words | nothing | Working when the run starts |
| **Your send is refused or T3 drops** | the Sent line returns to its previous state and place (`lineMove`); failure line enters (1.11); connection line if T3 is gone | nothing | Send again → Sent |
| **Thread renamed in T3** | nothing shows T3's title (the start of the first message, which says little) | name sheens | the short name may change, once |

Curves, in one place:

| Motion | Curve | Reduce Motion |
|---|---|---|
| Hover fills (**R3:** rows too) | instant on, instant off | instant |
| Card opens / closes; lines appear, leave, reflow; filter applies | `Motion.spatial` (spring 0.30, no bounce); **R3:** a fold whose opacity shows only in the last 35 % | ease-out 0.12 |
| Line changes section | `RouterV2.lineMove` (spring 0.45, bounce 0.14); **R4:** the line glides as itself, what it passes fades under it (2.4) | cross-fade 0.12 |
| Filter bar's active ground; **R4:** the lit place's ground in the destination row | `Motion.glass` (spring 0.35, bounce 0.12) | ease-out 0.12 |
| Counts | `numericText` on `.snappy` | `.opacity` |
| Peek, destination row words, step words | `Motion.fade` (ease-out 0.14) | the same |
| **R3.** Text taking another's place (sentence, name, placeholder, row words, toast, caption) | swap: old out 0.06 s, new in 0.12 s (`routerV2Swap`) | the same |
| Destination row, failure line, new pill entering | `.scaleFade(0.96)` on `Motion.spatial` | `.opacity` |
| PR state pop | spring 0.35, bounce 0.3, from 1.25 (the word swaps in one frame) | none |
| Option picked | radio fills instantly; row fill instant | the same |
| Sheen | Core Animation, 1.4 s linear loop | off |
| Fjord's mark, the model at work | `FjordLoader`: Core Animation, 2.6 s loop, each part fading to a trace in turn; **R3:** it starts as the whole mark each time it appears | the whole mark, still |
| Mark ↔ arrow in the destination row | `Motion.fade` | the same |
| A setting's value changing | `RouterV2.roll` (spring 0.34, bounce 0.22), 13 pt; both faces drawn once and moved by one progress, the old gone by the middle, faces fading at the chip's edges (**R3**); chips your words set 70 ms apart; widths on the same curve | cross-fade in place |
| A setting set by a pill | accent glow, held 0.35 s, ease-out 0.9 s | the same |
| Words streaming | 0.12 ease-out per word, one every 50 ms | whole line, `Motion.fade` |
| Working dots | Core Animation (as `BlinkingDot`) | still |
| Scroll to selection | `Motion.follow` | jumps |

All through `.motion(_:value:)`, so `RouterMotionTests` keeps passing and `WindowArrival` keeps the page from animating
as the window opens.

## 4. Filters

Two facets, one choice in each: **one project or All**, **one state or all**. No multi-select.

- **From a line:** click its project pill → that project. Click the pill of the project already filtered → All.
- **From the bar:** click a pill or a token → it is the choice; click the active one → cleared. `All` clears the
  project. Clicking a section header is clicking its token.
- **Combining:** project × state, e.g. silo × Working. Counts are faceted: each project pill counts its lines under the
  current state choice; each state token counts its lines under the current project choice; section headers count the
  lines shown. A pill whose count falls to 0 under a state choice stays, at `CDS.Text.disabled`.
- **What filtering does:** lines that don't match leave (height + fade, `Motion.spatial`), headers without lines leave,
  counts tick, the active ground slides. Lines keep their order. Project pills on lines fade out under a project filter.
  The housekeeping line counts only the filtered project's older threads.
- **What it doesn't do:** it doesn't change where words go, the sidebar badge, or what T3 events do. A line that
  starts matching (a new silo thread under the silo filter) grows in live.
- **Selection:** if the selected line is filtered out, the selection goes to the first Needs-you line shown, else none.
- **Clearing:** `Clear` after the last project pill; Esc when there is nothing else to step out of (5.3); ⌫ in filter mode;
  `All`. All of them animate the lines back in.
- **Threads with no project** show under `All` only. There is no "No project" pill.
- Filters last while the page is shown; they reset when the window closes.

Keyboard (filter mode):

| Key | Does |
|---|---|
| ⌘F | the keyboard goes to the bar: ring on the active pill, or `All`. ⌘F again leaves |
| ← → | move the ring across pills, then tokens |
| a letter | the ring jumps to the first project that starts with what was typed since entering (type-ahead; reset by any other key). **R3.** A character that no project starts with leaves filter mode and goes to the composer, with what was typed |
| Space | choose what's ringed (again: clear it); stay in the bar |
| Return | choose what's ringed and go back to the list |
| ⌫ | clear both facets |
| ↓ or Esc | back to the list; the filter stays |

⌘F opens the palette today, and so does ⌘K. On the Router page ⌘F becomes the filter; ⌘K stays the palette.

## 5. Keyboard map

AZERTY-safe: digits and ⌘digits are read by key position (`BriefKeys.digits`, `RouterKeys.pickKeys`), so no Shift is
needed on AZERTY. ⌘-letter chords are read by character (⌘F, ⌘O, ⌘K, ⌘Z are the keys printed with those letters). No
bare letter does anything but type. The o / a / r keys are gone, and so is ⌘R on this page. **R3.** Return ignores key
repeats. Digits pick with ⇧, by key position (owner, 2026-11-12): a bare digit-row key always types. (Was: on AZERTY a first character from the digit row (é on 2) picked when the open card
has that many options (POLISH-interaction 21, kept).

### 5.1 Anywhere on the page

| Key | Condition | Does |
|---|---|---|
| ↓ / ↑ | empty draft | select the next / previous row; the card follows. Walk order: lines top to bottom, housekeeping line, failure lines; it wraps. From no selection, ↓ takes the first line, ↑ the last row |
| ⌥↓ / ⌥↑ | empty draft | first line of the next / previous section; it wraps, and from no selection ⌥↓ takes the first section |
| ⇧1…⇧9 | card open, empty draft | pick that option (again: unpick; multi-select: toggle). Never sends. Shift is required (owner, 2026-11-12) so a bare digit-row key (é, &, ") always types |
| → / ← | card open, empty draft | open / close the long text (plan, last lines) |
| Tab / ⇧Tab | form card | next / previous question |
| @ (⌥+à on AZERTY), then ↑ ↓ / Return or Tab | draft | the mention list, with a Settings section; Return or Tab makes a settings pill and sets its chip; ⌫ takes the pill out and the chip goes back |
| Tab / ⇧Tab | draft, the row shows a new thread | into the row's settings: the next / previous chip; past the last (before the first) back to the words |
| Tab | draft, the row asks for a place | opens the places menu (↑↓ Return picks; Tab or Esc closes) |
| ← → | keyboard in the settings | the chip after / before |
| ↑ ↓ | keyboard in the settings | open the ringed setting's menu and move through it, the value applying as it moves |
| Return | option picked or draft | send to what the destination row shows |
| Return | Stopped card, empty draft | Continue (through the row: it shows T3's words) |
| Return | form with questions left | moves to the next open question |
| Return | before the read lands (a held Return) | holds the words; they go when the read lands sure (1.9) |
| Return | T3 away | keeps the words in the composer |
| Return | failure line focused | Send again |
| Return | Done, Working, or nothing picked, empty draft | nothing |
| ⌥Return | draft, destination is working | send queued |
| ⌥ held | destination is working | the row shows "queue after this turn" |
| ⇧Return | in the composer | new line |
| ⌘1 ⌘2 ⌘3 | the row shows numbered places | light that place. **R3.** With a draft they never fall through to the Go menu: pressed while the places are being read, the digit is kept and lit when the read lands unsure. With no draft, the Go menu's, as today |
| ⌘⌫ | row selected, empty draft, not a repeat | Settle it; on the housekeeping line, Settle all; on a failure line, Edit (its key shows) |
| ⌥⌘⌫ | line selected, empty draft | Snooze menu at the card: For 1 hour · For 3 hours · Until tomorrow, 9:00 (↑↓ Return, or ⇧1–3; **R3:** a digit acts at once, and the act has a Revert) |
| ⌘O | line selected | Open in T3 |
| ⌘Z | | Undo: the last act while it is the newest undo (Edit ▸ Undo Settle), else the text's |
| ⌘F | | filter mode (section 4) |
| ⌘K | | palette, unchanged |
| ⌥⌘B, ⌘B | | History drawer, sidebar, unchanged |
| @ | in the composer | mention list: ↑↓, Return or Tab picks, Esc closes; a mention is an explicit place |
| ⌫ | caret at the start of the draft | drop an explicit place |
| any character | no field focused | goes to the composer |

With a draft, ↑ ↓ ← → and ⌘⌫ are the text's (the arrows are the settings' while the keyboard is in them: Tab in, Esc
or any character out). In the mention list Tab picks, as before: the list comes first. Stop has no
key: a button only.

### 5.2 What Return does, in one rule

Return sends what the destination row shows. With no row: Send again on a focused failure line, otherwise nothing. It
never settles. **R3.** On a Stopped card the row shows the Continue words, so Return sends them like any other words.
A form with questions left: Return moves to the next open one; typed words on a form answer the current question
(recorded as "Your answer", sent with the rest). A held Return and T3 away are as in 1.9.

### 5.3 Esc, in order

1. the mention list
2. the snooze menu, places menu or a setting's menu
3. filter mode (back to the list)
4. a held Return (the words come back to the composer)
5. the keyboard in a new thread's settings (back to the words)
6. the row's guess (waved off: "pick a place"), or your explicit place
7. the picked option(s)
8. the selection (the card closes)
9. the filters

It never closes the window and never clears a draft.

## 6. Storyboard

### 6.1 Harness

- `.build/debug/Fjord --window --router-v2-demo [--from <beat>] [--until <beat>] [--beats 26,27] [--speed <x>]
  [--reduce-motion] [--frames <dir> [--frames-rate <n>]]`: the real window on a `RouterV2Demo` source that plays the
  script below. The components take the page as a value and send acts back, so the real engine
  can replace the demo source later without touching them.
- Window 1280 × 960 (**R3**), sidebar shown, light theme (`FJORD_THEME=light`), opaque chrome. Fake clock fixed at 14:02.
- **Pointer:** a drawn pointer (the system arrow, as an image in an overlay) that the script moves along eased paths
  (0.35 s per move). It sets hover and press state itself. The real pointer is never moved or captured.
- **Keys:** the script calls the same handler real keys reach (`RouterKeys.key`), and typing goes into the real
  composer at 22 characters a second.
- **Caption:** beside the window's title, where the "Checked…" subtitle used to be: beat number and text, footnote 12
  `CDS.Text.muted`, swapping (`routerV2Swap`). After it, the keys just pressed as glyphs (`RouterV2KeyHint`), shown 0.8 s.
  **R3.** A caption leads its act by 0.2 s a word (0.8 s at least) and can change mid-beat (beats 12, 14, 34).
  Type-ahead is shown as text ("typing “f”"), not as a key: no letter is a shortcut.
- Record the window only (ScreenCaptureKit, `SCContentFilter(desktopIndependentWindow:)`), 2x, 60 fps; trim the first
  second; mp4 plus a half-speed copy, in `docs/design/router-v2/`. Second clip, 25 s: beats 5, 6 and 14 with Reduce
  Motion on. **R3.** The recorder fills behind the window's corners with the page's ground and writes the window's
  clean top-left corner, which the cut lays over the sharing badge (not verified here: no Screen Recording
  permission).
- Stills for review in both themes: add `v2-` shots to `AppWindowShots` (`v2-home`, `v2-card-question`, `v2-card-form`,
  `v2-card-plan`, `v2-card-permission`, `v2-card-decide`, `v2-card-done`, `v2-card-stopped`, `v2-card-working`, `v2-peek`,
  `v2-reassessing`, `v2-filter`, `v2-destination-unsure`, `v2-queued`, `v2-failure`, `v2-toast`, `v2-empty`).
  R2: `v2-reading` (the mark in the arrow's slot), `v2-new-thread` (T3's defaults), `v2-new-thread-keys` (the ring, a
  changed effort, the mode's chip), `v2-new-thread-menu`, `v2-new-thread-access-menu`, `v2-new-thread-pills` (the
  pills @Opus 5.5 and @Medium, the chips set), `v2-new-thread-mention` ("@op" typed, the list), `v2-new-thread-mention-bare`, `v2-new-thread-plan`, `v2-new-thread-unsure`, `v2-new-thread-sent`.
  R3: `v2-held` (a Return before the read), `v2-card-flagged` (a step the verdict found), `v2-pick-a-place`,
  `v2-unreachable`.
- Where nothing can be filmed (no Screen Recording permission for the app the binary runs under), `--frames <dir>`
  writes the window server's picture of the app's own window ten times a second while the script plays (`--frames-rate
  <n>` for more), named by their time in hundredths of a second: enough to check a beat's motion frame by frame, not a
  film. **R4.** While frames are written, stderr says on the same clock when a line moves and when the destination
  row's light, ring or a setting changes (`v2-frame 01234  move settings`), so those frames can be found.

### 6.2 Fake data at t = 0

| Name (page) | T3 title | Project | State | Line | Age | New |
|---|---|---|---|---|---|---|
| Settings layout | Redesign the Settings window | fjord | Needs you, question | sidebar, one page, or tabs? | 25m | |
| Val Cenis booking | Book the Val Cenis chalet, 14–21 Feb | none | Needs you, left a step | reserve for five? about €62 more than for four | 12m | |
| Briefs migration | Move the briefs into BriefLog | fjord | Needs you, plan | plan ready: move briefs into BriefLog, copy the old rows once | 6m | |
| Updater | Ship the updater | lcu | Needs you, form | silent or ask first? stable or beta? | 2m | • |
| Disk test | Find the flaky disk test | silo | Stopped | failed: the connection to Claude dropped | 1h | |
| Install guide | Rewrite the install guide | docs-site | Done, look | rewritten for the Chrome setup; PR #41 (then the state word, "open", drawn by code) | 10m | • |
| Bar count | Count untold needs-you on the bar | fjord | Done, quiet | counts only unread; tests pass, not pushed | 50m | |
| Tab handover | Hand the tab over without a gap | fjord | Working | Editing TabHandover.swift (the running tool) | 12m | |
| Snapshot API | Snapshot API: restore by id | silo | Working | `swift test --filter SnapshotRestore` (a running command, in mono) | 31m | |
| Checkpoint boot | Boot the Linux VM from a checkpoint | silo | Working | Building the boot image (its running to-do step) | 6m | |
| Upstream issue | Answer upstream issue #2031 | silo | Working | I'll reproduce it on the 0.4 branch first. (the agent's latest words) | 18m | |

Bar: All 11 · fjord 4 · silo 4 · lcu 1 · docs-site 1; Needs you 5 · Done 2 · Working 4. Sidebar badge 5.

Older, not settled (5): Drop the canvas layout (fjord, 3d) · Glass capture fallback (fjord, 2d) · Score the decider on
last week's moments (fjord, 2d) · Approval panel copy (lcu, 4d) · Sitemap and redirects (docs-site, 2d).

Card contents:

- **Settings layout.** Last lines: "I can do a sidebar with sections, one scrolling page, or tabs. One page is simplest
  to maintain; the sidebar scales best if Settings keeps growing." Options: A sidebar with sections · One scrolling page
  · Tabs across the top.
- **Val Cenis booking.** Last lines: "The chalet takes five with the sofa bed. For five it is €1,302 for the week
  instead of €1,240. I have not reserved anything yet." Ask: "Reserve for five, or keep it at four?" Options (model):
  Reserve for five (+€62) · Keep it at four.
- **Briefs migration.** Plan, 23 lines, starting "1. Add a `briefs` table to BriefLog…". Options (Fjord's own: T3 gives
  a plan none): Yes, and auto-accept edits · Yes, and manually approve edits. "No" is typing what to change.
- **Updater.** Q1 "How should updates install?" 1 Silently · 2 Ask first. Q2 "Which channel?" 3 Stable · 4 Beta.
- **Disk test.** Error: "The connection to Claude dropped: the stream closed before the turn finished." Last step:
  running `swift test --filter SnapshotRestore`. Continue sends "Continue where you left off."
- **Install guide.** Last lines: "Rewrote the guide around the Chrome extension setup and removed the old CLI path.
  Screenshots are updated." `#41 open` · 4 files +96 −212.
- **Checkpoint boot** (before beat 12). To-do steps: Building the boot image (running) · Booting the VM from the
  checkpoint · Checking the boot log.
- **Checkpoint boot** (permission, beat 12). No reason (T3 sends none). Command: `git worktree remove --force
  ~/silo-work/checkpoint-old`. Options: Allow once · Allow for this thread · Deny · Cancel. Warning on the first two:
  "--force discards uncommitted changes there."

### 6.3 Beats

t in seconds from the trimmed start: the sum of the beats' lengths before it (`lengths` in `RouterV2DemoScript.swift`; a
beat is as long as its acts plus the time to read what they did). "Notice" is what the viewer should see. Counts are
Needs you / Done / Working, given where they can be derived with certainty. **R3.** The script has 43 beats in six acts
(the old act 5 grew by two, act 6 by one, act 3 by one); beats 27 to 31 are Round 2's (a new thread's settings), beat 19
shows a thread's subagents, background work and waits.

**Act 1: read (0:00–0:19)**

| # | t | What happens | Caption | Notice |
|---|---|---|---|---|
| 1 | 0.0 | The page, at rest. Settings layout is selected, its card open. Hold. | One line per thread, grouped by state | Three sections with counts; the question on the line; pills and ages; two new dots; the working dots alive; the first card already open |
| 2 | 5.0 | The drawn pointer comes in from the right, crosses two rows (Tab handover, Bar count), then rests on the name "Install guide" | Hover a name: a read-only peek | Rows light under the pointer; the peek floats, with the last reply and `#41 open`; nothing in it is a control |
| 3 | 9.5 | Pointer moves to the name "Disk test", rests, then leaves the list | (none: beat 2's stays) | The peek swaps to the error line; it goes the moment the pointer leaves |
| 4 | 12.7 | Click the Install guide row. Then click the Settings layout row | Click opens its card | Row pressed state; Settings' card rolls shut as Install guide's opens: result, PR badge, files; its new dot goes; then back |

**Act 2: answer from the keyboard (0:19–1:01)**

| # | t | What happens | Caption | Notice |
|---|---|---|---|---|
| 5 | 19.1 | Keys `2`, `3`, `2` | A digit picks. Nothing is sent yet | The radio moves at once; the destination row slides in: → Settings layout “One scrolling page” |
| 6 | 23.5 | Return. 0.35 s: T3 has it. The run starts 1.6 s after the send (longer than the usual 0.9 s, so the Sent line can be read) | Return sends: Sent, then Working | The line turns into ↑ with your words and moves to Working; counts tick to 4 / 2 / 5; the next card (Val Cenis) opens; "sending…" sheens and goes, then the line reads "Reading SettingsView.swift" with the dots |
| 7 | 28.1 | Type "five, and ask for a late checkout on the 21st". The read of a sure follow-up lands in 0.5 s. Wait, then Return | Or just type: the row says where | The option keys dim and digits are words now; the row shows Val Cenis at once, then "answers it"; a thread with no project has no pill; counts 3 / 2 / 6; Briefs migration's card opens |
| 8 | 35.7 | `→` opens the plan, `←` closes it. Key `1`. Return | Plan: → shows all of it | The plan rolls open to its 23 lines and back; then Sent “Yes, and auto-accept edits”; 2 / 2 / 7; Updater's card opens, its new dot goes |
| 9 | 43.1 | Key `2` (Ask first). Key `3` (Stable). ⇧Tab to the first question. Type "ask first, but never mid-call". Return. Return | Form: a digit per question, or type | The accent rail slides to the first question; the first Return records the typed words as its answer ("Your answer"); the second Return sends both; the line goes Sent, then Working "Editing UpdatePrompt.swift"; 1 / 2 / 8; Disk test's card opens |
| 10 | 52.7 | Disk test's card. Return | Stopped: the reason, and Continue | The red banner with the error and the last step; the destination row shows → Disk test “Continue where you left off.”; Return sends it; the line goes Sent with those words, then Working `swift test --filter SnapshotRestore` in mono; 0 / 2 / 9 |
| 11 | 58.3 | Hold | Nothing needs you | "Nothing needs you." takes the header's place; the sidebar badge is gone; no card is open |

**Act 3: T3 moves, live (1:01–1:50)**

| # | t | What happens | Caption | Notice |
|---|---|---|---|---|
| 12 | 61.3 | T3: Checkpoint boot asks a permission. The verdict's words stream from 2.0 s | A thread asks: it moves at once / Then Fjord shortens the line | In one frame: lock, amber, the raw command (mono) as the line, the line moves up to Needs you, 1 / 2 / 8, new dot, badge 1. Only its sentence sheens. The second caption comes as the words start: "wants to remove the old checkpoint worktree, with --force" appears word by word. No card opens by itself |
| 13 | 67.9 | Key ↓. Key `1`. Return | Permission: the command and its warning | The card: the command block and the warning (no reason: T3 sends none), T3's four options; Sent “Allow once”, then Working; "Nothing needs you." again; 0 / 2 / 9 |
| 14 | 74.1 | T3: Upstream issue's turn ends. At 1.9 s the verdict says it leaves you a step | A turn ends: Done at once / Then Fjord finds a step for you | Check, "finished", up to Done (0 / 3 / 8), sheen. The second caption comes with the verdict: it turns amber with the checklist mark, moves again to Needs you (1 / 2 / 8), and "PR #2049 is open: read the diff, then merge it" streams |
| 15 | 81.7 | GitHub: PR #41 merges (the demo shows T3 seeing it at once; in life, within a minute). The verdict says `quiet` | A PR merges: T3 sees it within a minute | On Install guide, "open" turns to "merged" in violet with a pop; its sentence sheens while every other line is still; the words are the same, so nothing streams; the sheen goes and the blue ground fades out |
| 16 | 87.7 | T3: a thread starts there: "Fix the sidebar glass on resize" (fjord) | A new thread appears | A line grows into Working with T3's title cut at 28 characters and a new dot; the name and the sentence sheen; the step "Reading SidebarGlass.swift" comes at 0.9 s, the name "Sidebar glass" at 2.2 s; fjord 4 → 5, All 11 → 12; 1 / 2 / 9 |
| 17 | 92.3 | T3: Snapshot API's turn ends (a failed build is a finished turn). The verdict flags it | A turn ends on an error: Fjord flags it | Done at once, then amber with the checklist mark in Needs you under the ask: "the build fails: cannot find 'RestoreToken'; it stopped there"; 1 / 3 / 8, then 2 / 2 / 8 |
| 18 | 98.9 | T3: Install guide is settled there | Settled in T3: it just leaves | The line folds away; 2 / 1 / 8; the docs-site pill leaves the bar; no toast |
| 19 | 102.5 | Subagents, background commands and waits appear on Tab handover (two subagents, a dev server), Checkpoint boot (waits on a CI run and on the boot log) and Sidebar glass (one subagent). The pointer rests on Tab handover's glyphs, then on Checkpoint boot's; then one of Tab handover's subagents ends | Subagents, background work and waits, at a glance | Muted glyphs right after each sentence, a count only past one (`person.2 2  terminal`, `hourglass 2`); the peek lists each subagent with its model and age, the command in mono, each wait; Checkpoint's peek swaps in; the `2` beside Tab handover's subagents goes, its glyph stays |

**Act 4: filters (1:50–2:08)**

| # | t | What happens | Caption | Notice |
|---|---|---|---|---|
| 20 | 109.5 | Click the `silo` pill on Disk test's line | Click a project pill: the page filters | The bar's ground slides from All to silo; other lines fold away; 2 / 0 / 2; Done's header leaves; the pills on lines fade (the bar says silo) |
| 21 | 114.1 | Click the Working token. Then click it again | Add a state | silo × Working: two lines; the project counts change with the state (All 8, fjord 4, silo 2, lcu 1); the second click brings the silo asks back |
| 22 | 119.1 | ⌘F. Type `f` (shown as the text "typing “f”"). Return | ⌘F: filter from the keyboard | The ring appears on silo, jumps to fjord; Return applies and returns to the list; "Nothing needs you in fjord." over Done 1 and Working 4 |
| 23 | 124.7 | Esc | Esc clears | Every line grows back in its place; `Clear` leaves the bar |

**Act 5: send (2:08–3:40)**

| # | t | What happens | Caption | Notice |
|---|---|---|---|---|
| 24 | 127.7 | Nothing selected. Type "bar count: push it and open the PR". The read lands in 0.5 s. Return | Type with nothing selected: Fjord finds the place | Fjord's mark in the arrow's slot and a skeleton place while the draft is read, then → ✓ Bar count fjord · starts a new turn, and a dashed outline on that line's name; Return: Bar count goes Sent, then Working `git push -u origin bar-count`; Done's header leaves (2 / 0 / 9) |
| 25 | 135.7 | Type "the spacing is off again". The unsure read takes 3.2 s. Key ⌘2. Return | Not sure: its guess first, ⌘1–3 pick | Fjord's mark in the row while it reads; then three places, each with mark, name and project; the guess lit, with what Return does there (steer now · ⌥ queue) inside its chip; ⌘2 moves the light to Tab handover; Return: the line reads ↑ “the spacing is off again” steering… for about 3 s, then Working "I'll re-measure the composer's spacing against T3." |
| 26 | 148.3 | Click Checkpoint boot's row. Type "then delete the old checkpoint image too". The read of a running thread takes 3.2 s. Hold ⌥ (0.9 s), release, hold again, ⌥Return | A working thread: Return steers, ⌥ queues | The Working card: five steps with the running one lit, the agent's reply growing live with a caret, Stop; the row flips to "queue after this turn" while ⌥ is down; the words land as a small queued row under the line, with Cancel |
| 27 | 162.3 | Esc. Type "silo: write the changelog for 0.4". The read takes 3.2 s | A new thread: the row shows how it starts | While it is read, Fjord's mark is in the arrow's slot; then → new thread in silo and four chips: Opus 5.5 · High · Auto · Build, quiet (they are T3's defaults), and the key ⇥ |
| 28 | 171.9 | Tab. →. ↓ | Tab into the row: arrows change a setting | The ring lands on the model's chip and slides to the effort with →; ↓ opens its menu and moves High to Extra high, the value rolling as it moves and its ink now primary; nothing is sent |
| 29 | 178.3 | Click the model's chip. Click "Sonnet 5.5". Pointer parks | Or click a chip: its menu | The ring goes (the pointer has the row); the menu hangs over the chip: the models with their providers, a check on Opus 5.5; the click rolls the chip to Sonnet 5.5 and closes the menu |
| 30 | 183.9 | Type " @op", Return, then "@med", Return | Or type @: the list offers the settings | The list over the @ word: Fable 5.2 · Opus 5.5 · Sonnet 5.5 · Haiku 5.5 at a bare @, only Opus 5.5 at "@op"; Return makes a quiet pill (glyph, outline, no "@") and the model chip rolls from Sonnet 5.5 to Opus 5.5 with the accent glow; the same for "@med": the list holds Medium, the pill lands and the effort chip rolls from Extra high to Medium a moment after |
| 31 | 192.1 | Return | Return starts it; the pills stay behind | A line is born Sent as ↑ “silo: write the changelog for 0.4”, without the pills, with Opus 5.5 · Medium after the status; its name is "write the changelog for 0.4", sheens with the mark after it, becomes "Changelog 0.4" at 2.2 s; the run starts at 0.9 s with `git log v0.3..HEAD --oneline`; silo 4 → 5 |
| 32 | 197.5 | Type "lcu: add a --dry-run flag to lcu apps". Return 0.15 s after the last key, before the read lands | Return early: it goes when Fjord knows where | The held look: the words stay in the composer, muted, the caret hidden, the send button pressed, the mark in the arrow's slot; when the read lands sure (3.2 s) the words go to a new thread in lcu; a line is born Sent, named "add a --dry-run flag", then "Dry-run flag"; Working "Reading Apps.swift" |
| 33 | 206.9 | Type "snapshot api: RestoreToken moved to SiloCore". Return. 0.3 s later T3 drops. 2.2 s on, T3 is back. 1.4 s later, Return | A send fails: it stays by the composer | The connection line and the red failure line at once (the Sent line returns to its flagged state), the failure line shaking once and taking the keyboard; once T3 is back the connection line leaves and the failure reads "… didn't go to Snapshot API."; Return = Send again: the failure line goes, the thread goes Sent, then Working "Editing Snapshots.swift" |

**Act 6: clear (3:40–4:54)**

| # | t | What happens | Caption | Notice |
|---|---|---|---|---|
| 34 | 219.9 | T3: Settings layout, Briefs migration and Val Cenis booking end their turns, 1.2 s apart. Then Tab handover ends, and 1.1 s later it starts again. Last, Checkpoint boot's turn ends and its queued words go | Turns end; each line is read alone / It started again: no line was written | Three lines go Done one after another, each sheens and streams by itself: "now one scrolling page; PR #58", "briefs moved into BriefLog; tests pass; PR #59" (both worth a look, blue), "reserved for five; late checkout asked; the confirmation is in your inbox" (quiet, plain). Tab handover goes Done, sheens, then back to Working with no line written (the second caption). The queued row rises into Checkpoint boot's line: Sent, then Working |
| 35 | 231.9 | ⌥↓, then ⌥↓ again, 0.9 s apart | Done: the result, the PR, what changed | The selection reaches Done's first line, Briefs migration: last lines, `#59 open`, 6 files +212 −148; the footer's three acts with their keys |
| 36 | 237.5 | ⌘⌫ | Settle: gone at once | The line folds away; toast "Settled Briefs migration · Revert ⌘Z"; the next Done card opens |
| 37 | 240.7 | ⌘Z | ⌘Z brings it back | The line grows back where it was, selected; the toast leaves |
| 38 | 243.9 | ⌘⌫. 1.8 s later, ⌘⌫ | ⌘⌫ twice: two lines, one toast | Two settles, two presses; the toast is replaced, not stacked; Val Cenis is selected |
| 39 | 249.5 | ⌥⌘⌫. ↓ ↓ Return | Snooze | The snooze menu at the card (For 1 hour · For 3 hours · Until tomorrow, 9:00); the second ↓ lights the last; "Snoozed Val Cenis booking until tomorrow, 9:00 · Revert ⌘Z"; Done's header leaves; no selection |
| 40 | 254.9 | ↓ (Upstream issue, the first line). Click its item's Done | Done on an open item: it strikes, then folds, and the thread goes to Done | The item's card: the Do, `#2049 open`; the item strikes "done by you" and folds; the thread moves to Done; toast "Done: … · Revert ⌘Z" |
| 41 | 261.7 | Pointer rests on "5 finished earlier, not settled", then clicks Settle all | Finished earlier: one line, one act | The peek lists the five; the row folds away; "Settled 5 older threads · Revert ⌘Z" |
| 42 | 268.1 | PR #2049 merges (Upstream issue goes quiet). 0.6 s on, nine turns end, 0.4 s apart. After 5.4 s: ⌥↓, then ⌘⌫ every 0.6 s while a line is selected | Clearing the rest | Lines go Done as they end; four verdicts run at once, so the fifth line on sheens until a call is free; each ⌘⌫ takes exactly one line down the Done list; pills leave the bar one by one |
| 43 | 288.5 | Hold. After 2.2 s the last toast is dismissed | Nothing left | "Nothing needs you. Nothing is running." No bar (its 48 pt stay), no badge; the composer says "Message your threads" |
| 44 | 294.5 | The demo's threads come back as a relaunch finds them: the finished ones' verdicts pending. 2.0 s later the guide's verdict (a step: Needs you, its state first, then its name and words); 1.4 s later the bar's (Done, quiet) | A cold launch: Fjord reads what finished first | "Reading 2 threads…" + the mark in the first row, the two lines under it (dashed circle, sheen); never "Nothing needs you"; the guide glides up under "Needs you 1", the row reads "Reading 1 thread…" under it; then the bar glides into Done and the row goes (**R5**) |

**Act 7: open items (5:01–5:22, OPEN-ITEMS.md)**

| # | t | What happens | Caption | Notice |
|---|---|---|---|---|
| 45 | 301.5 | Checkpoint boot runs with Stuck, Decide and Know open; Bar count has one Decide. Click Checkpoint boot's header. Type "keep 0.3 for now; boot it with 4 GB of RAM" (a running thread: the read takes 3.2 s). Return. 2.2 s later the read lands: the Decide closes, the Stuck is restated, a Do is new; 1.6 s on they settle. Then a new turn ends: 2.2 s later its read closes the Stuck | Your message is checked against what's open / Answered items strike; new ones fold in / A new turn is read the same way | One block, in Needs you, its header quiet; at Return, in one frame: `↑ "…" · sent` under the items, every item sheens, Fjord's mark at the header's end; then "keep the 0.3 checkpoint…" struck with "answered by your message", the Do lit amber, the Stuck's age now "now"; the struck line goes, the light fades; the new turn: the header lights once, the items sheen, "reading the new turn…" where new items land; the Stuck strikes "done by the agent" and goes |

Lines the script needs for beat 42 (all `quiet`, in the order the turns end): Updater "asks before installing, never
mid-call; stable channel" · Disk test "the flake was a 120 s timeout under load; raised and fixed" · Tab handover "the
tab hands over with no gap; spacing matches T3" · Checkpoint boot "boots from a checkpoint; old worktree and image
removed" · Sidebar glass "the glass no longer flickers on resize" · Bar count "pushed; PR #60" · Changelog 0.4
"changelog written for 0.4" · Dry-run flag "lcu apps takes --dry-run; tests pass" · Snapshot API "the build passes with
RestoreToken from SiloCore". Upstream issue's merged-PR line is "replied on the issue; PR #2049".

## 7. Out of scope for the demo, and what the real integration needs

Out of the demo:

- Liquid Glass on the dock (opaque chrome in the recording).
- Bar pills overflowing into `More`; more than three places in the row's menu; several mentions in one draft.
- Renaming a thread in place (click the T3 title in the card); for now rename stays in T3.
- The History drawer (unchanged), the palette, banners and the bar's tiles.
- Attachments, splitting one message across several threads, Triage.
- Narrow windows (under 760) and Increased Contrast variants; stills only.
- A new thread's worktree choice and its attachments; effort lists that differ per model (the demo has one list);
  a pill's look in the demo's drawn composer is a picture in the text (the real field draws it as an attachment).

For the real page later:

- **Thread record:** one store of code state per thread from T3 shell and thread events, replacing the board groups,
  `told`, `read` and `BriefSpanState`.
- **Verdict:** one model call per thread per fingerprint change; schema ordered `state`, `worth`, `name`, `line`,
  `ask`, `options`, so the state lands first and the line can stream from partial output. **R3.** The call is
  cancelled when a run starts; at most 4 run at once.
- **Names:** stored with the thread, written once, reused by lines, the row, toasts and History.
- **Deletions:** the project call, the lead call, `GeneralBrief`, Mark read, the after-send ask (`RouterAskPill`,
  `askBacks`), the composer strip, the preview chip, O / A / R, ⌘R on this page.
- **Sent:** the dispatcher reports each send's state per thread (sending, taken, refused, queued) to the record.
- **Working line (R3):** the running to-do step (it needs T3's `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`), else the agent's
  latest words, else the running tool; and the run's start time, from the thread's events.
- **Stopped (R3):** the error text and last step from the failed run. Continue goes through T3's own words, "Continue
  where you left off." (`manualContinuationOfRunId` when T3 allows it), not `startImmediately(intent: .restart)`.
- **PR state (R3):** through T3's linked PRs (link the ones only named), up to a minute after the event, into the
  fingerprint and the state word.
- **New dot:** opening a card sends `threadVisit`, so T3 agrees. **R3.** A new ask sets it like a new finish: a card
  you open clears it at once, a card your own act advanced to at your next key or pointer move.
- **Destination read (R3):** show what code knows at once (the selected thread as a prior); hold Return until the read
  lands (1.9). The decider returns settings only and never writes the message.
- **A new thread's settings (R2, R4):** not read from words at all. They come from `@` pills (1.9.1); the decider's
  schema is N4b's alone (no `launch`, no `launch_words`). Defaults and the model list (with each model's effort choices,
  its default and its aliases) come from T3's settings and provider status, not from constants; a provider that doesn't
  support a runtime mode shows only the ones it does (T3's `resolveCompatibleRuntimeMode`). `launchThread` gets them as
  `modelSelection`, `runtimeMode`, `interactionMode`.
- **Fjord's mark:** `FjordLoader` as it is; the row shows it for every decider call, a line for every verdict call.
- **Undo:** Settle, Snooze, an item's Done and Settle all registered with the window's `UndoManager` and in History.
- **Banners:** keyed on the request id, not on `unseen` (state review, item 2).
- **Evals:** score verdicts (needs_you / look / quiet, line faithfulness) on real boards before turning it on.

## 8. Choices to check in the video

Where this goes past the reviews, or picks between them:

1. **Return never settles.** The interaction review had Return settle a Done card. Here Settle is ⌘⌫ only, ignores key
   repeats, and its button is disarmed under a pointer that hasn't moved: the 2026-10-12 rule, now with a Revert toast.
2. **Stopped sits in Needs you**, after the asks, as in the agreed mock; **Sent sits in Working**. Three sections.
3. **Needs you is longest-waiting first**, so a new ask never pushes down what you are reading.
4. **The selection is a prior, not a lock.** Typed words are still read by the Router with a card open; the row shows
   the decision before Return. An explicit pick (⌘1–3, click, @) always wins.
5. **Filters are one project × one state**, counts faceted, and ⌘F moves from the palette to the filter on this page.
6. **The hover peek is read-only and only on the name.** That removes the grace timer and the pointer corridor.
7. **T3 events never open a card or move the selection**; only your own acts advance it.
8. **Quiet Done lines have no ground**; the blue ground is the model saying "worth a look".
9. **⌘R and Rewrite Briefs go.** A wrong item is closed with its Done, not a rerun.
10. **(R2, R4) Settings are explicit tokens, never read from words.** `@` lists T3's models, efforts, access and plan
    beside threads and projects; a pick is a pill that sets the chip and is not sent. "use opus for subagents" and
    "don't edit anything" are instructions for the agent and stay in the message untouched (owner, 2026-11-12; the
    model-read path, "don't edit anything → approval-required" included, was removed).
11. **(R2) The mark and the sheen together.** On a line being read the sheen stays (which words will change) and the
    mark is added after them (the model is at it). In the destination row the mark takes the arrow's slot.
12. **(R2, R3) Tab is the way into the settings**; ↑ ↓ on a chip open its menu (the one a click opens) and move through
    it, the value applying as it moves. The mode's chip is always there (Build quiet).
13. **(R2) Access is named as T3 names it** (Supervised · Auto-accept edits · Auto · Full access), so the row and T3's
    composer say the same thing; "Approval required" is T3's `approval-required`, shown as Supervised.
14. **(R3) Return early goes when Fjord is sure.** A Return before the read lands holds the words and sends them when
    the read lands sure; unsure or disagreeing, the row shows the places and Return is asked again.
15. **(R3) A finished line may move twice.** A finished thread goes to Done at once (code); the verdict may then promote
    it to Needs you. This is the owner's decision, shown as it is (beats 14, 17, 34).
16. **(R3) Fjord's mark starts whole** each time it appears, rather than in phase with the others.
17. **(R3) Digits pick by key position, kept on AZERTY.** A first character from the digit row (é on 2) picks when the
    open card has that many options. (Superseded: options pick with ⇧, section 5.)
18. **(R4) No outlines.** The card, its options, the chips, the places and the keys lose their edges; a border is the
    keyboard's ring or a floating panel's hairline (1.0). Keys are plain glyphs, as in a menu.
19. **(R4) What Return does at the lit place is said after the places**, not inside the lit one (R3 had it inside):
    the places then keep their widths and only the light moves. It still shows always.
20. **(R4) A line in flight is only itself.** It truly glides now (it used to fold away and fold in under a lifted
    plate); what it passes fades under it. The other choice, an opaque or lifted row, is the box the owner disliked.
21. **(R4) The line a draft goes to is marked by the row's arrow** in its dot slot, not by a dashed outline on its
    name.
