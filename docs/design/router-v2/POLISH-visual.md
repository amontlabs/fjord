# Router v2: visual and motion polish (review of router-v2.mp4 and the v2 stills, 2026-11-12)

Reviewed: `router-v2.mp4` (60 fps, 3:44) as one frame every 2 s, then every frame or every 2nd–6th frame around each
transition; the `v2` stills in light and dark (`--window-shots`, 34 shots a theme). Times are seconds in the video.
"f" = frames at 60 fps. Files are in `Sources/Fjord/`. Ranked by how visible each one is. 52 findings.

Evidence: a time given alone was opened frame by frame. "Same act at …" means the same code path runs there and the
frame-difference scan shows the same one-frame spike, but those frames were not opened. Fixes name the place and the
value; none of them was built or run.

Not checked: the half-speed and Reduce Motion clips; the card's loading skeleton in motion (it is only in the
`v2-card-loading` still); hover on real hardware.

## Status after the fix pass (2026-11-12)

Each finding below is marked **fixed** (done as written, or to the same effect), **changed** (done another way, or decided
otherwise) or **skipped** (left as it is), with the reason. Checked with `swift build`, the `v2` stills in light and dark
(1280 × 960 now) and `--frames` captures at 10, 20 and 30 frames a second around the transitions. Nothing was filmed:
this app has no Screen Recording permission, so the recorder's changes (finding 12 of the visual review) are not verified.

| # | Status | Note |
|---|---|---|
| 1 | **changed** | A flying line is its row alone: the card's content and the selected surface go in the frame it takes off, and the card's place folds on the move's own curve (closing it to height 0 in one frame made every row under it jump); the lifted ground and border are on the row only. |
| 2 | **fixed** | Through 1: a card never changes kind while it closes, it is gone before. |
| 3 | **fixed** | No opacity on the card: it rolls open and shut at full opacity, clipped, the surface and border on the same curve. |
| 4 | **fixed** | `geometryGroup` on headers, pills and tokens. |
| 5 | **fixed** | The roll is keyed on a count the model moves in the same mutation as the value; both faces drawn once; the old face is gone by mid-roll; faces fade at the chip's top and bottom; widths on the roll's curve. |
| 6 | **fixed** | `Surface.s3`, a border, the near shadow whole and the far one at 0.5; there from the first frame, faded out on landing. |
| 7 | **fixed** | One swap everywhere (`routerV2Swap`: old out 0.06 s, new in 0.12 s): sentences, names, placeholder, row words, toast, captions; the PR word swaps in one frame and only pops; ages tick with `numericText`. |
| 8 | **fixed** | The plan is one block in a place as tall as its first 8 lines; the place rolls; the button rides the edge and its label swaps. The last lines open the same way. |
| 9 | **fixed** | Under its button in the top half (over it in the bottom half), trailing edges aligned. |
| 10 | **fixed** | Stream lead 0.04 s, and a streamed line's container is there at once (its words fade in themselves). |
| 11 | **fixed** | Old name out in 0.06 s; the row slides on `spatial` when the name changes. |
| 12 | **changed** | The recorder fills behind the corners with the page's ground, and writes the window's clean top-left corner before the capture; `record-window.sh` lays it over the badge on every frame. Not verified here (no Screen Recording permission). |
| 13 | **fixed** | `Clear` sits after the last pill; the tokens never move. |
| 14 | **fixed** | The mark starts whole each time it appears (not on the wall clock's phase: this replaces DESIGN 2.2's shared phase), 13 pt on lines in `Text.secondary`, 14 pt in the row. |
| 15 | **fixed** | The stack makes room on `spatial`, the line enters 0.08 s later and shakes once it is there. In the demo the connection line and the failure line now arrive together. |
| 16 | **fixed** | Skeletons pass their own band: white 0.7 in light, white 0.10 in dark. |
| 17 | **fixed** | The placeholder is gone in the frame the first character lands; it comes back after the words have left. |
| 18 | **fixed** | The card follows its measured height on `spatial` (not keyed on the text, which would cross-fade every word); the caret is joined by a no-break space. |
| 19 | **fixed** | The fold's opacity shows only in its last 35 %. |
| 20 | **fixed** | One row, id `header-0`: the header and the sentence swap in place. |
| 21 | **fixed** | Same row for the empty sentence; the bar's 48 pt stay; the demo's last toast leaves after 2 s. |
| 22 | **fixed** | One toast view: its words swap, its width follows on `spatial`. |
| 23 | **fixed** | Danger ink at 14 % with a 35 % ring, both looks. |
| 24 | **fixed** | The line keeps its danger ring; the accent ring is on `Send again`. |
| 25 | **fixed** | Caret at −1.5 pt while the draft is empty; it no longer slides back across the placeholder after a send. |
| 26 | **fixed** | The dock's ground is solid from its top edge, with the fade above it. |
| 27 | **changed** | `Header.top` 16 was not enough: the demo and the stills are 1280 × 960. |
| 28 | **fixed** | All place chips medium. |
| 29 | **fixed** | Prose keeps to 560; option rows run the card's width. |
| 30 | **fixed** | Row hover is instant both ways. |
| 31 | **fixed** | Gap 10, near shadow whole. |
| 32 | **fixed** | `.replace.downUp` at speed 1.8. |
| 33 | **fixed** | Pop from 1.25 (line and badge). |
| 34 | **fixed** | Inline code at 0.92 of the text beside it (plan, options, asks, last lines, last step). |
| 35 | **fixed** | Connection line inset 10. |
| 36 | **fixed** | The name always takes its medium width (a hidden copy); the weight still follows the ground, as DESIGN 1.4 has it. |
| 37 | **fixed** | Token counts have room for two digits. |
| 38 | **fixed** | Ages tick with `numericText` on the counts' curve. |
| 39 | **fixed** | The queued row's arrow is in the mark's box. |
| 40 | **fixed** | The ring goes when the pointer enters a chip. |
| 41 | **fixed** | Keys leave after 0.8 s or with their beat. |
| 42 | **fixed** | The band's middle runs from the words' start to their end. |
| 43 | **fixed** | A 14 pt word space before the state word. |
| 44 | **fixed** | The pointer's tip aims at the lower-right third of what it clicks. |
| 45 | **fixed** | The toast enters with `scaleFade(0.96)`. |
| 46 | **fixed** | The chip ring slides with `matchedGeometryEffect` on `Motion.glass`. |
| 47 | **fixed** | Chips use `CDS.borderStrong`. |
| 48 | **fixed** | One rail, moved with `matchedGeometryEffect`. |
| 49 | **fixed** | The housekeeping peek is 400 wide. |
| 50 | **fixed** | Peeks enter with `scaleFade(0.98)`. |
| 51 | **fixed** | Ghost push buttons are footnote 12, `Text.secondary` (primary under the pointer). |
| 52 | **fixed** | Both fades 24. |

49 fixed, 3 changed, 0 skipped.

## Known list from CONTEXT.md Round 2

| Item | Now |
|---|---|
| Sharing badge over the traffic lights | Still there, whole video (finding 12) |
| Snooze menu over the line | Still there, 185–187 s and `v2-snooze` (finding 9) |
| Busy beat 40 | Still busy, 201.5–210 s (findings 1, 2, 4, 6) |
| Ghost of the closing card | Still there, and an empty hole follows it (findings 1, 3) |
| "Show all" cross-fade in two places | Still there, and the card's height snaps (finding 8) |
| Sheen subtle in light | Fixed on sentences (a clear dark band, 57–58 s, 75 s). The skeleton's sheen is now too dark (finding 16) |
| Skeleton not in the video | The destination row's is in (106.6, 112, 128 s). The card's loading skeleton is still only a still |
| First frame: housekeeping under the dock | Still there, 0–12 s (finding 27) |
| Draft selection highlight in stills | Fixed |

## Findings

### A. Seen by anyone, at normal speed

1. **A sent, rerun or settled line drags its whole card across the page** (21.5–21.9, 50.9–51.2, 160.7–160.9, 202.7, 208.9; same act at 30.3, 38.3, 46.3, 65.6): the closing card's surface, about 110 pt tall with its contents at 10–40 %, travels with the line, hides the rows and the header it passes (Val Cenis, Briefs and Updater vanish at 21.55; "Done 2" and Install guide at 50.95; the Working header is gone for 6–8 f then comes back clipped at 21.85 and 51.15). Fix: `RouterV2Line.swift:132-140`, when `moving` the card is height 0 and opacity 0 in the same frame (`.transaction { if moving { $0.animation = nil } }` on the card's frame and opacity), the selected fill and border (`:142-151`) off in that frame too; `:153-156` the opaque moving ground covers only the 34 pt row.
2. **The closing card swaps to the Sent card while it fades** (21.50, 50.92): two footers ("Open in T3 ⌘O" at two heights), "One scrolling page" / "Rerun" ghosted over the options, and the content jumps 10 pt down in one frame. Fix: finding 1 removes it; also render a closing card from the thread as it was when selected (don't switch kind blocks while `!selected`).
3. **Card swap by click leaves a ghost, then a hole** (12.9–13.1, 209.0; same act at 16.0, 171.1): content fades in 0.1 s while the height folds over 0.3 s, so 3 f of ghost text then about 6 f of empty surface; the opening card's footer pops in last with keycap outlines poking under the card's edge (13.07, 209.0). Fix: `RouterV2Line.swift:134-135` delete the `.opacity` and its 0.1 s motion; the existing `.frame(height:)` + `.clipped()` then rolls the content up and down at full opacity on `Motion.spatial`; take `selected` out of `.hoverMotion` (`:146`) so fill and border run on the same spring.
4. **Counts fly away from their labels while headers move** (51.05, 202.9–203.0 "3" floats 12–19 pt above "Done", "5" above "Working"; 90.0 "2" above "Working"; a stray digit near y 122 at 202 s): `RouterV2Count` animates its own position on `.snappy` while the header moves on another spring. Fix: `.geometryGroup()` on the header's `HStack` (`RouterV2Page.swift:180-185`), the token's (`:370-375`) and the pill's (`:354-359`).
5. **A setting's value roll is broken** (135.38–135.55; 145.55–145.75): the old value is drawn twice (one copy leaves, one sits under it); set by words, the effort chip is empty for 5 f, first showing "Mediu" cut in a chip still "High" wide, then "High" comes back to roll out; the old value's last letter hangs at the chip's right edge while it narrows ("High u", "Opus 5.5 r"); values are cut hard at the chip's top and bottom. Fix: `RouterV2Launch.swift:366-410`, drop `onChange` + `DispatchQueue.main.async` (it shows the new value at rest for a frame, then snaps back); the model sets the old label and the direction in the same mutation as the value, one `withAnimation(RouterV2.roll.delay(stagger))`; both faces in one `ZStack` with offset + opacity; chip width on the same curve; replace `.clipShape` (`:340`) for the text with a 3 pt top and bottom fade mask.
6. **A line in flight looks like a glitch, not a lifted row** (57.2–57.35, 68.1–68.3, 69.6, 166–167, 202.95): its ground is the page's colour and its shadow is 35 % of the near shadow, so what shows is half-cut words of the rows under it (Bar count, Install guide, "Done 2", Checkpoint boot). Fix: `RouterV2Line.swift:153-156` fill `CDS.Surface.s3` and a 1 pt `CDS.border` stroke while `moving`; `RouterV2Page.swift:163-164` near shadow at full opacity plus the far one at 0.5; fade both in and out on `Motion.fade`.
7. **Every text swap shows two strings on top of each other for 4–6 f**: sentence ("waiting on a build" under the command 57.08; "starting"/"reading…" 80.5; "“Rerun” sending…store timed out" 50.95), age ("1h"/"now" 50.95), placeholder (12.9, 50.9), destination words ("Ask first'· Stable" 44.0), toast (183.0), PR word ("opemerged" 75.05). Fix: one transition used everywhere, old out in 0.06 s then new in 0.12 s: `.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.06)), removal: .opacity.animation(.easeOut(duration: 0.06)))` at `RouterV2Line.swift:304`, `RouterV2Dock.swift:17, 83, 205, 243`; the PR word swaps in one frame and only pops.
8. **"Show all" snaps** (33.72; same act closing at 35.9): the card jumps to full height in one frame, lines 9–23 fade in place, the button disappears and "Show less" appears 300 pt lower. Fix: `RouterV2Card.swift:276-293`, the lines in one container with `.frame(height:)` + `.clipped()` animated on `Motion.spatial` (value `open`), no per-line `.transition(.opacity)`; the button stays one view under it and rides the edge; only its label cross-fades.
9. **Snooze menu covers its own line and card** (185–187 the sentence and the age; `v2-snooze` the question and both options). Fix: `RouterV2Page.swift:435` `below: false` → `below: nil` (under the button in the top half, over it in the bottom half), and align its trailing edge with the Snooze button's.
10. **The model's line arrives after a blank** (58.52–58.62): the code line is gone, then 2 empty frames and 3 near-empty before the first word reads. Fix: `RouterV2Effects.swift:507` `.delay(RouterV2.codeFade)` → `.delay(0.04)`.
11. **A new name makes the sentence jump** (81.05–81.15): "Fix the sidebar glass on…" → "Sidebar glass", the sentence moves 60 pt left in one frame over the old name still fading ("glass on.reading"). Fix: `RouterV2Line.swift:228-231` old name out in 0.06 s; `.motion(.spatial, value: thread.name)` on the row's `HStack` (`:164`) so the sentence slides.
12. **Sharing badge over the traffic lights, and black wedges at the four window corners**, whole video. Fix: `WindowRecorder.swift:62-70` set `configuration.backgroundColor` to `CDS.Surface.s1` (kills the black corners); for the badge, hide the three standard window buttons on the recorded window, or overlay a clean patch of that 150 × 44 pt corner (cut from a `--frames` capture) with ffmpeg `overlay` in the trim step.
13. **Filter on: `Clear Esc` fades in over the tokens** (89.95–90.05, 103.93), then the three tokens shift 60 pt left; `Esc` also ends 8 pt past the column's right text edge. Fix: `RouterV2Page.swift:325-329` move `Clear` into the leading group, right after the last project pill (12 pt gap), so the tokens never move.
14. **Fjord's mark is invisible for its first 0.6 s** (57.3–57.9 after the command; 106.6–107.3 in the row): it starts on the wall clock's phase, often at "trace"; at 11 pt muted it then reads as a grey half-disc, not the mark. Fix: `RouterV2Effects.swift:126-136` start each loader at the whole mark (phase 0 when it appears); `RouterV2.Thinking.line` 11 → 13, `.row` 12 → 14; tint `CDS.Text.secondary` on lines.
15. **The failure line fades in on top of the connection line** (160.77–160.85, 5 f of two texts), and shakes while still at 40 % opacity. Fix: `RouterV2Dock.swift:37-38` add `.motion(.spatial, value: model.failures.count)`; `:29` insertion delayed 0.08 s; `:327-329` shake `.delay(0.12)`.
16. **Skeleton sheen is a dark slug in light** (106.6–108.3, 112, 128 s; `v2-reading`). Fix: `RouterV2Sheen` takes a colour; skeletons (`RouterV2Effects.swift:114`, `RouterV2Dock.swift:217`) pass white at 0.7 in light, white at 0.10 in dark, at opacity 1 (not `shimmerPeak` at 0.35).
17. **Placeholder fades out under the typed words** (128.0 "silo" over "…age your threads"; 106.0, 112.0). Fix: `RouterV2Dock.swift:83` removal `.identity` when the draft becomes non-empty.
18. **The agent's reply makes the list jump** (121.93; same act at 120.43, 123.48): each wrap grows the card 19 pt in one frame and every row under it jumps; the caret wraps alone onto an empty line (121.93). Fix: `.motion(.spatial, value: thread.lastLines.count)` on the card in `RouterV2Line.swift:132`; `RouterV2Card.swift:232` join the caret to the last word with U+2060.
19. **Leaving and arriving rows overlap their neighbours' words** (90.0 Checkpoint boot over Sidebar glass; 103.95 top slivers of glyphs; 202.8 a settled line at 10–50 % for 4 f): the fold's opacity is linear. Fix: `RouterV2Effects.swift:532` `.opacity(Double(min(1, max(0, (open - 0.65) / 0.35))))`.
20. **"Nothing needs you." and the Needs-you header trade places with a clipped fold** (57.1–57.2, 69.55, 202.85: half-cut glyphs for 2–3 f). Fix: `RouterV2Model.swift:277, 281` give both the id `header-0`, so it is one 28 pt row whose content cross-fades (finding 7's transition).
21. **Empty state arrives badly and looks unfinished** (212.2–212.4, then 213–223): the sentence jumps 26 pt up into the bar's place while the bar's ghost is still there; the last settled row lingers 3 f; then one grey sentence in a corner of an empty page with a toast for 8 s. Fix: `RouterV2Model.swift:264` id `header-0`, and append " Nothing is running." to the same row; keep the bar's 48 pt as empty space when there are no threads (`RouterV2Page.swift:119-125`) so nothing jumps; let the demo's last toast leave after 3 s.
22. **Toast replaced: width snaps, `Revert ⌘Z` doubles for 3 f** (183.0). Fix: `RouterV2Dock.swift:14-18` one toast view (no `.id(toast.id)`), its width on `Motion.spatial`, the words on finding 7's transition.

### B. Seen on a second look, or in the stills

23. **Dark: danger fills are a heavy maroon block** (`v2-failure-dark`, `v2-card-stopped-dark`), the loudest thing on a calm page. Fix: `RouterV2Card.swift:154`, `RouterV2Dock.swift:323` fill `CDS.Text.danger.opacity(0.14)`, ring `CDS.Text.danger.opacity(0.35)`.
24. **Blue keyboard ring on the pink failure line** (160–163, `v2-failure`). Fix: `RouterV2Dock.swift:324` keep `dangerRing` on the line; put the 1 pt accent ring (2 pt out, radius +2) on `Send again`, which is what Return presses.
25. **Composer caret sits on the placeholder's first letter** in every scripted frame with an empty draft ("0r say…", 32 s). Fix: `RouterV2Dock.swift:105` `.offset(x: model.draft.isEmpty ? -1.5 : 2.5)`.
26. **The list shows through right above the destination row** (122–127, 158: "5 older finished…" half-faded against the row's top). Fix: `RouterV2Page.swift:132-138` background = a 24 pt clear→`s1` gradient above a solid `s1`, `.padding(.top, -24)`, so the ground is solid from the dock's top edge.
27. **First frame hides the housekeeping line** (0–12 s). Fix: record at 1280 × 960 (DESIGN 6.1), or `RouterV2.Header.top` 20 → 16.
28. **Unsure row: the lit place is medium, the others regular**, so chip widths change when ⌘1–3 moves the light (114 → 116 s, `v2-destination-unsure`). Fix: `RouterV2Dock.swift:249` always `.medium`.
29. **Option rows stop at 560 pt, the footer and the age run to the column's edge** (every card): a 150 pt dead strip right of the options. Fix: `RouterV2Card.swift:34` keep 560 for prose, let `RouterV2Options` fill the card's width (keycaps then line up with `⌘O`).
30. **Hover leaves a trail**: two rows lit while the pointer crosses the list (5.9–6.3). Fix: `RouterV2Line.swift:146` rows cut off at once (release only on buttons and pills).
31. **Peek touches the hovered row's ground** (`v2-peek`, 9.6–11 s) and, in light, is close to the grey of the selected card it overlaps (10 s). Fix: `RouterV2.Peek.gap` 6 → 10; `RouterV2Line.swift:501` near shadow at full opacity.
32. **Mark swap leaves an empty slot for about 3 f** (69.8, check → checklist). Fix: `RouterV2Line.swift:246` `.symbolEffect(.replace.downUp, options: .speed(1.8))`.
33. **PR state pop is not perceptible** (75.05): 1 → 1.12 on an 11 pt word. Fix: `RouterV2Effects.swift:492`, `RouterV2Line.swift:522` 1.12 → 1.25.
34. **Mono looks a size bigger than the sans beside it**: "Last step: running `swift test…`" (`v2-card-stopped`), inline code in the plan (`v2-card-plan`). Fix: mono at about 0.92 × the sans size: `RouterV2Card.swift:156` 11; inline code 13 beside prose 14.
35. **Connection line's icon is about 10 pt left of the failure line's** (`v2-failure`). Fix: `RouterV2Dock.swift:20-24` `.padding(.leading, 10)`.
36. **Name weight changes with its ground** (`RouterV2Line.swift:219`, regular ↔ medium), so the sentence's start shifts whenever a line changes state (from the code; not measured). Fix: medium always, or reserve the medium width with a hidden copy.
37. **Token group shifts when a count gains a digit** (150.0, Working 9 → 10). Fix: `RouterV2Count` in tokens `.frame(minWidth: 14, alignment: .leading)`.
38. **Ages change with no transition** (`RouterV2Line.swift:350`; all ages tick between 56 and 58 s). Fix: `.contentTransition(.numericText())` + `.motion(RouterV2.counts, value:)` on the string.
39. **Queued row's words start about 3 pt left of the name above** (`v2-queued`, 128–163). Fix: `RouterV2Line.swift:366` arrow in a `markBox`-wide frame, spacing `markGap`.
40. **Chip ring stays on `High` while the pointer is on another chip** (138.0). Fix: drop `launchFocus` when the pointer enters the row.
41. **Key caps outlive their act** (212: `⌘⌫` beside "40 Clearing the rest" on an empty page). Fix: caps clear when the page they acted on changes again, or after 0.9 s, whichever is first.
42. **Sheen is off the words for about 0.35 s of each 1.4 s pass** (57.9–58.3). Fix: `RouterV2Effects.swift:81-82` sweep from `locations(sheenBand / 2)` to `locations(1 + sheenBand / 2)`.
43. **PR word sits about 2 pt after its link**; a word space at 14 pt is about 4 (`v2-home`, "PR #41 open"). Fix: 4 pt.
44. **Pointer covers what it clicks** (94.0 the count, 192.5 "Not for me"). Fix: aim the tip at the target's lower-right third.
45. **Toast enters with a fade only** (176.3) while the row beside it scales in. Fix: `RouterV2Dock.swift:17` `.scaleFade(0.96)`.

### C. Small

46. Ring on a chip moves with no motion (134.5): slide it with `matchedGeometryEffect` on `Motion.glass`, as the bar's ground.
47. Chip borders are faint at 1x in light (130 s): `CDS.border` → `CDS.borderStrong` for chips at T3's default.
48. Form: both questions show a rail mid-move (40.0): one rail, moved with `matchedGeometryEffect`.
49. Housekeeping peek cuts a name ("Score the decider on last week's mom…", 196 s): width 360 → 400 for this peek.
50. Peek only fades (6.4–6.6): add `.scaleFade(0.98)`.
51. `Settle all`, `Edit`, `Clear filter` are 13 pt primary (`RouterV2PushButton`), the footer's buttons 12 pt muted (`RouterV2TextButton`): one size, 12, for ghost text buttons.
52. The filter bar's fade is 20 pt, the dock's 30 (`RouterV2Page.swift:338`, `:136`): 24 both.
