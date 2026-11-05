# Router canvas: implementation plan

> Superseded: the canvas is gone; the Router window is the brief (docs/design/router-watch-and-briefs.md).

The Router gets a second way to show Now: a canvas. It keeps the approved prototype's layout and UX (`docs/design/router-viz/demo/canvas2.html` and `canvas2-spec.md`): an infinite pan/zoom ground, each project folder a frame, state groups joined to their cards by curved lines, cards opening in place, filter chips, done-only folders folding, and messages that wait above the composer and then fly to their card. What goes inside comes from the app: its real cards and sessions, components, wording, actions and polish. Where they conflict, the graph keeps its shape and the app keeps its content.

**The canvas is a beta, an alternate view to try; the list is the default and untouched.** The Router's top bar always shows the List / Canvas switch, a Beta tag beside it and Canvas's tip starting "Beta:". A fresh install shows the list; your pick is kept under `routerLayout`. The list draws and behaves exactly as before the canvas: every shared view (`CardView`, `WaitingCard`, `WorkingCard`, `WorkingSummary`, `HistoryCardLine`) keeps its list output by default and changes only on a canvas node (`canvasNodeID` set, or `standalone`/`showsProject: false`/`open` passed by the canvas); `PaneSwitch` and `NowColumn` are as they were, and the canvas's own column, switch and Beta tag live in `RouterCanvasBeta.swift`. The list shots render the same pixels as before the canvas, but for the switch in the top bar and the busy line's dots, which animate.

Another session has uncommitted Router work in the main checkout, so this branch moves no code between files: types the canvas reuses lose `private` where they are, and nothing else about them changes unless stated.

## Infinite canvas (revision, supersedes §0.1, §2's range and first look, §3's columns and §5's bar)

The first build put the canvas in Now's column with History beside it and its frames in one column: it read as a list in boxes. As the prototype does, the canvas now is the page:

- **Whole page.** In Canvas mode `RouterPageView` draws `CanvasPage` (`RouterCanvasBeta.swift`) instead of the two columns: the canvas under the top bar, edge to edge, running under the composer. The list's branch is untouched.
- **Ground.** `CanvasDotGrid`, one `Path` of dots 24 apart in the content, offset and scaled with the camera, doubled in spacing until 14 pt or more on screen. No pan bounds. Zoom **0.25…1.0** about the pointer: above 1 `scaleEffect` scales the drawn layers and text blurs, so 1.0 stays the maximum.
- **Only you move the camera.** Your scroll, drag or pinch, the zoom buttons, Fit, a double-click or the context menu. It is kept under `routerCanvasCamera`; the very first open, with none kept, fits everything once. Opening a card, a search, Jev's pick, a reveal or a selection by the keys never move it: a node off the view gets a marker on the viewport's edge, towards it (`CanvasEdgeMarker`, `CanvasMetrics.edgePoint`), which takes you there when clicked. A message to a card off the view flies to that edge and leaves the marker.
- **2D layout.** `CanvasMetrics.columnCount(closed:)` picks the column count whose masonry packing is nearest 16:10, from the frames' closed heights alone (never the window). `preferred(_:placed:)` packs the frames you haven't placed as masonry under the ones you have. `CanvasBoard` draws a placed frame exactly at its place, always (overlaps allowed, the last moved on top, `stack`); a packed frame is pushed down under one it would overlap. Measured sizes are taken in whole points (`whole`), so a measure wavering by a fraction moves nothing. Gaps are 48.
- **Moving and resizing frames.** A drag on a frame's header or its own ground (never a card) moves it 1:1 at any zoom, with a shadow, on top. It stays exactly where it is dropped: no grid, no nudging. Every other frame keeps where it was drawn, and all are saved under `routerCanvasPositions`. Its right edge, bottom edge and corner resize it (resize cursors), down to 320 wide: its cards take its width less the labels' gutter (`cardWidth(frame:)`), and under 460 the groups are named by their glyph alone, the cards closer to the edge; a narrow card drops Jev's chips (under 380), then the kind's name for its icon (`KindGlyph`, under 280), its title truncating, nothing drawn past it. Your height wins: a frame never resized fits what it holds, one you made shorter keeps your height, its header fixed and its body scrolling under it (`CanvasBodyScroll`, `CanvasBodyScrolling`), faded where cut; a two-finger scroll over the body is the frame's, decided once per gesture by `CanvasEventView` (`scrollingFrame(at:)`). Sizes are saved under `routerCanvasSizes`. A chevron button in the header is the only way to fold or open a frame. A group opened past its first few ("+n more") shows "Show less" in the same place, folding it back. **Reset layout** clears places and sizes.
- **Floating chrome.** `CanvasChips` (chips, "Nothing needs you") and `CanvasNotices` (away strip, busy line, nothing found or matches) at the top left; `CanvasControls` at the top right: Summarize what's running, Zoom out, Zoom in, Fit, Reset layout, History (`IconButton`s with tips; History with its unread badge). They float on `ComposerMaterial` (glass on macOS 26 with glass chrome, else `s3` with a ring and the panels' shadow). The content's room starts under them (`topRoom`).
- **Steady rows.** On the canvas a Done line keeps fixed columns (`HistoryCardLine.canvasLine`): the unread dot's room, the words ("· how" always shown, Got it with them), then the caret, a 30 pt age and Open in Claude's room, always there, so hovering moves nothing and every line of a group lines up. A waiting row truncates its line rather than overflowing a narrow frame. Working's glyph on the canvas (its label and chip) is the app's animated logo, `FjordLoader`, still with Reduce Motion.
- **History panel.** `model.pane == .history` opens it: `HistoryColumn` in a 480-wide (45% at most) panel over the canvas's right side, under the buttons, sliding in; the History button or Esc (after the reply chip in the Esc chain) closes it. A message the Router answers with no card opens it, as a narrow window switched to History.
- **Composer.** On the canvas the composer and pending stack float with no ground behind them.
- **Shots** can't draw scroll views offscreen (`cacheDisplay`), so the history panel's lines and a plan's body show empty in them, as History does in the list's shots.

## 0. Decisions

1. **Scope.** The canvas replaces only `RouterNow`'s body. The top bar (title, search), `RouterSetupNotice`, `NowColumn`'s bar (pane switch, chips, `RouterBusyLine` on 26), the History column and the composer stay. `AwayStripView`, the pre-26 `RouterBusyLine`, `RouterNothingFound` and the "Nothing needs you" line live inside `RouterNow` today, so the canvas places them itself (§5). In a wide window (≥1040), History stays beside the canvas. In a narrow one, `PaneSwitch` Now/History still switches, and Now is the canvas.
2. **Nodes are the list's rows, keyed as the list keys them.** A card node's id is `card.id`; a Working or Waiting row's id is `RouterModel.workingID(session)`. So `selection`, `highlighted`, `expandedNeed`, `replyTo`, `revealRequest` and `tap` reach nodes unchanged. The groups hold exactly what `RouterPage` puts in each zone: a session in Needs you and Working at once has both nodes, as the list shows both, and keeps its live line in Working.
3. **Groups**, in the Router's order: Needs you (`needs + ready`), Worth a look (`notes`), Waiting, Working, Done. Unread is not a group; it shows as the accent dot on Done lines. Glyphs and tints are `RouterZone.symbol/.tint`; Done is `checkmark` in `CDS.Text.muted`.
4. **What Done holds.** For each session with no node in the other groups, its newest addressed or settled card (`!isOpen`) among `model.searchedHistory(store)` (not `history(store)`, which also applies History's Unread filter). Memoised per `store.routerSearchRevision` and the query, as `searchedHistoryMemo` is. Idle sessions with no card stay off the canvas, as they are off Now. Done shows 3, then "+n more"; a picked card is always drawn.
5. **Worth a look keeps the list's rule:** 3 shown, widened when the pick is past the third (`notesShown`/`showsAllNotes`), with "+n more" as the control, so the keys never land on an undrawn card.
6. **The app's content stays:** `TriageChips`, `KindTag`, `OriginTag`, "n of N left", went-ahead, briefs, Sparkles, `UnansweredLine`, Tell it. Spec §12's "no judgements" is overruled by the user's ask to carry the app's features.
7. **Messages with no card to fly to** (a reply to the Router only, Fjord changes, `decision.reply`) fade from the pending area and land in History, as today.
8. **Nothing is open by default** (the graph wins). At most one node is open. One source of truth: open cards use `model.expandedNeed`, closed ones `model.expanded`, Working rows `model.canvas.openWorking`; opening one clears the others. So the forms' state (`picks`, `sent`, `planDecided`, …) and `tap()`'s fold-back work unchanged.
9. **No new letter or ⌘-digit keys.** The keyboard is AZERTY, and ⌘1…⌘9 are the Go menu's (`GoMenuModel.slots`), except ⌘1–4 while an ask-back shows. Forms keep their own controls.
10. **No branch suffix on frames.** `ClaudeSession.folder` is the repository root with worktrees collapsed onto it, so the root's HEAD would mislabel every frame; the app shows no branch today.

## 1. Switch and persistence

- `enum RouterLayout: String { case list, canvas }` in `RouterZones.swift`, beside `RouterPane`, with `static let key = "routerLayout"`.
- `RouterModel.layout: RouterLayout`, `.list` by default. Its `didSet` writes `defaults` under `routerLayout`, as `folded` is written. `init(defaults:)` reads it; shots and tests get the list unless they call `pickCanvas()`.
- `RouterLayoutSwitch` goes in `RouterMain.topBar` (`RouterCode.swift`), between the Spacer and `InboxSearchField`, always.
  - Two icon segments: `list.bullet` ("List") and `square.on.square.dashed` ("Canvas", its tip starting "Beta:"), each with `.tip`, then a `BetaTag` (the app's Badge, xs, accent tint).
  - It draws `PaneSwitch`'s pill itself (`RouterCanvasBeta.swift`); `PaneSwitch` stays as it is.
- `RouterPageView` picks Now's column: `CanvasNowColumn` (the canvas under the same bar, with the canvas's chips) when `model.layout == .canvas`, else the list's `NowColumn`, unchanged.

## 2. Container (`RouterCanvas.swift`)

- **State.** `@Observable final class CanvasCamera { var origin: CGPoint; var scale: CGFloat }`, owned by `RouterCanvasState`, which lives on `RouterModel` as `model.canvas` (with `filter`, `folderFolds`, `openWorking`, `pendingIDs`, `pendingFrames`, `landed`, `flights`). Only the transform modifier reads the camera. The content (`CanvasContent`) is an `Equatable` child that never reads it, so a pan or zoom redraws one modifier and no cards.
- **Transform.** `ZStack(alignment: .topLeading) { CanvasContent }.scaleEffect(scale, anchor: .topLeading).offset(origin)`, then `.clipped()` and `.contentShape(Rectangle())` on the viewport, on `CDS.Surface.s1`. Scale runs **0.4…1.0** (`CanvasCamera.range`): `scaleEffect` scales drawn layers, so above 1 text, `ShimmerText` and forms blur.
- **Coordinate space.** Everything inside is measured in `.named("canvasContent")`, defined inside the transform, so a pan or zoom fires no geometry callbacks. Only a flight converts to `routerMain` space, once, when it starts.
- **Scroll and pinch: `CanvasScrollMonitor`**, an `NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify])` installed in `onAppear`, removed in `onDisappear`.
  - It acts only when `event.window === canvasWindow` and `locationInWindow`, converted to the canvas's window frame (flipped from SwiftUI), is inside the canvas.
  - Each gesture is decided once, at `phase == .began` (or the first event with no phase): "canvas", or "pass through" when the point is inside an open node's frame. The decision holds until `.ended` and through the momentum phases, so a pan that slides a form under the pointer never starts scrolling it.
  - Canvas scrolls apply `scrollingDeltaX/Y` (×10 when `!hasPreciseScrollingDeltas`) and are consumed. ⌘-scroll zooms: `scale *= exp(-dy * 0.01)`. `.magnify` zooms by `event.magnification` at `locationInWindow`, wherever the pinch starts (a `MagnifyGesture` on the background misses pinches over cards).
  - A `DragGesture(minimumDistance: 3)` on the background layer pans too.
- **Camera maths, pure** (tested without a window):
  - `zoom(by:at:)` keeps the point under the pointer fixed and clamps.
  - `fit(_ bounds: CGRect, in free: CGRect)`: `scale = clamp(min(1, free.w/b.w, free.h/b.h))`.
  - `origin(toShow rect: CGRect, in free: CGRect) -> CGPoint?`: nil when the rect is inside; when the rect is taller than the area, its top goes to the area's top.
- **Fit.** A double-click on the background (`onTapGesture(count: 2)`) and the Fit button (§5). On first appear it fits; if that would go under 0.6, it shows the columns' tops as wide as the room shows them (1.0 at most) instead. A search takes the first look again, so what it found shows.
- **Free area.** The canvas's bounds inset by 16, the bottom at the top of the composer plus the pending stack. On macOS 26 the canvas takes `.ignoresSafeArea(edges: .bottom)` so it runs under the composer's soft edge, and the bottom safe-area inset is the free area's bottom. On the pre-26 `VStack` path, the canvas ends at the pending stack, which sits explicitly above the composer.
- **`bringIntoView(_ rect:)`** applies `origin(toShow:)` with `Motion.spatial.resolved(reduce:)`.
- **Reveal.** `RouterCanvas.onChange` takes `model.revealRequest` and `zoneRequest` (`takeReveal`) and maps them through the pure `CanvasLayout.target(forReveal:) -> CanvasTarget?`: a card id or `working#…` → its node; a zone's raw value → that group's label in the first frame holding it; `endID` and `foldPrefix…` → nil (History's, or the list's). A change to `model.selection` or `model.highlighted` (Jev's prediction mark) pans the same way. Node rects come from the anchors of §3.
- **Performance at 20 sessions.** Placement is two `Layout`s, so SwiftUI measures and no height state loops back; connectors are one `Path` per frame; live lines keep their own scoped timers (`ShimmerText`, `WorkingCard`'s 1 s ticker). Culling isn't needed under ~40 frames.

## 3. Model and layout (`RouterCanvasLayout.swift`)

```swift
enum CanvasGroup: Hashable, CaseIterable { case needs, notes, waiting, working, done }   // Router order
enum CanvasItem: Identifiable { case card(RouterCard), waiting(RouterCard), working(AgentRow), done(RouterCard)
    var id: String /* card.id, or RouterModel.workingID(session) for rows */ }
struct CanvasFolder { let key: String; let name: String; let color: Color?
    var groups: [(group: CanvasGroup, items: [CanvasItem], more: Int, hidden: Bool)]; var doneOnly: Bool }
enum RouterCanvasModel {
    static func make(page: RouterPage, done: [RouterCard], muted: Set<String>, name: (String) -> String,
                     color: (String) -> Color?, filter: Set<CanvasGroup>, picked: String?, notesShown: Int) -> [CanvasFolder]
    static func order(_ folders: [CanvasFolder]) -> [String]        // keys and VoiceOver: folder, then group, then item
}
enum CanvasMetrics { /* the constants below */
    static func closedHeight(_ folder: CanvasFolder, folded: Bool) -> CGFloat
    static func columns(closed: [CGFloat], count: Int) -> [Int]                     // shortest column, by closed heights
    static func folderPlacement(rows: [(group: CanvasGroup, height: CGFloat)]) -> (nodes: [CGRect], labels: [CanvasGroup: CGRect])
    static func connector(label: CGRect, header: CGRect) -> (from: CGPoint, c1: CGPoint, c2: CGPoint, to: CGPoint)
}
```

- **`make`** (pure)
  - Groups `page`'s zones by `card.folder` / `row.session.folderKey`, keeping the page's order inside a group (`RouterPage.ranked` for Needs you). Done comes from the memoised newest-closed-per-session list (§0.4).
  - `""` is the Scratch frame (`ProjectLabel`'s `text.bubble`). Muted folders are dropped. Names and colours come from `store.folderName`/`projectColor`, as `routerProject` does.
  - A filtered-out group stays with `hidden: true`, so it fades in place, its room kept, without reflow. A frame left empty by search hides; one emptied only by the filter keeps its room, empty. A pick into a group the chips leave out lights its chip; into a folded frame, opens it.
  - Folders sort busiest first: Needs-you count, then Worth a look, then node count, then name (stable).
- **`order`** is a pure function of `make`'s output and needs no heights or columns.
- **Placement, two `Layout`s** calling the static maths above:
  - `CanvasMasonry` places folder frames in as many columns as the viewport holds at 0.85 or more (1 to 3, `CanvasMetrics.columns(width:)`). Each frame carries its closed height as a `LayoutValueKey`; the column is chosen from closed heights that ignore the chips, "+n more" and a pick's widening, then frames stack with their measured heights, so opening a card pushes only its own column down. Frames never move sideways.
  - `FolderLayout` places one flat `ForEach` of nodes and labels per folder, each child tagged with its group by `LayoutValueKey`. A node that changes group in the same folder keeps its identity and animates without `matchedGeometryEffect`; enter and exit use `scaleFade`.
  - Connectors: each node's header publishes an `anchorPreference` (in `canvasContent`), drawn in `overlayPreferenceValue` as one `Path` per folder, from (label trailing + 6, label midY) to (cardX, header midY), control points at the horizontal midpoint. Plain `Path`, never `Canvas {}` or `drawingGroup`, so `cacheDisplay` shots draw them.
  - A folded folder is `header` tall.

| Constant | Value |
|---|---|
| frameWidth | 560 |
| pad | 16 |
| header | 44 |
| labelX | 16 |
| labelMax | 92 |
| cardX | 124 |
| cardW | 420 |
| closedH | 52 (with a second line) |
| lineH | 34 (without) |
| moreH | 24 |
| gap | 6 |
| groupGap | 16 |
| columns | as many as give a 16:10 whole, from the frames (see the revision) |
| colGap | 48 |
| rowGap | 48 |
| labelH | 22 |

## 4. Nodes (`RouterCanvasNodes.swift`) and what they reuse

**In place, not moved.** In `RouterPage.swift`, drop `private` on `WorkingCard`, `WaitingCard`, `AskBackCard`, `HoverOpen`, `CardLead`, `CardGlyph`, `CardSessionMenu`, `SparklesButton`, `WorkingSummary`, `ZoneChip`, `CardDetails`, `HistoryCardLine`, `RouterBusyLine` and `cancelState`. Extract `HistoryDecisionLine.status` as `RouterDecision.status(store)` with its exact wording (`progress[id] + "…"`, `summary + " · " + held`), and have `HistoryDecisionLine` call it.

**Node environment.** `CanvasNodeView` sets `.environment(\.cdsColumnWidth, 420)` (compact header; `ProjectLabel` and the running chip's long form hide) and `.frame(width: 420)`.

| Group | Folded | Open in place | Actions |
|---|---|---|---|
| Needs you | `CardView(expanded: false, quiet: false, showsProject: false)` (new parameter, default true; the frame names the project): warm wash, approval tint, `KindTag`, `TriageChips`, excerpt, left/went-ahead/origin | `CardView(expanded: true, formCap: 360)`: brief, then `CodeFormCard` / `CodePlanCard` / asks / stuck prose in danger | Archive (with `secondClick`), Open in Claude; reply armed by the click |
| Ready to continue | `WaitingCard(standalone: true)` | the same plus its brief in full | Tell it (gate `store.triageOn \|\| triage.watch?.onCI != true` and "Sends it: …" tip unchanged), Open |
| Worth a look | `CardView(quiet: true, showsProject: false)` | brief and prose (`CDSProse`) | Archive, Open |
| Waiting | `WaitingCard(standalone: true)`: its own 12-radius tinted background, no 2 px bar | brief in full | Open; Archive in the context menu |
| Working | `WorkingCard(standalone: true, open: Binding<Bool>?)`: the binding is `model.canvas.openWorking`; with nil, its `@State` stays, so the list is unchanged. `ShimmerText` live line, running chip, duration, Sparkles, `UnansweredLine`, `WorkingSummary` | its `details`: every summary, newest first, then task rows | Open (quiet), Summarize |
| Done | `HistoryCardLine` unchanged at 420: `CardLead`, muted title, "· how", unread dot and tint, Got it, `HoverOpen` for the age, its accessibility actions and Equatable redraws | its `CardDetails` (KindTag, TriageChips, OriginTag, prose, Reopen); acknowledges on open | as History's |

- **Narrow header check first.** At 420, `CardView.wide` is false and `ViewThatFits` may fall back to two lines or shed `TriageChips`. Stage 1 shoots a card with `KindTag`, `TriageChips`, an approval tint and "n of N left" at 420; a header too long for the line truncates its title, keeping `KindTag`, `TriageChips` and the age. A ready card's line reads "ready to continue", what finished on the line under it.
- Selection or Jev's highlight draws the app's ring (1.5, `ghostSelected`). A landed message draws a ripple and "You: <text>" for 6 s (§6).
- Right-click opens `SessionMenu` or `CardSessionMenu` unchanged; nothing is added to them (Fork is already there).
- **Frame.** `CanvasFolderFrame`: fill `CDS.Surface.s0` (`alpha(.03)` in dark), 1 px `CDS.border` ring, radius 14. Header: `ProjectLabel(name, color)` at 13 medium, the folder path in `.tip`. A done-only folder adds " · n done", and its header is a button that folds it.
- **Labels.** `CanvasGroupLabel`: glyph 10 in tint, name 12 medium secondary, no count; Needs you semibold in `CDS.Text.warning`. Working's label carries the `RouterOverviewLine` text as its tip.
- **Lines.** 1 px, `alpha(.14)`; Needs you `CDS.Fill.warning` at 45%.

## 5. Chrome, filters, folding

- **Chips.** In canvas mode, `NowColumn`'s `ZoneChips` becomes `CanvasChips`: the same `ZoneChip` look, counts from `page.count(zone)` (asks included), plus a Done chip. A click calls `model.canvas.toggleFilter` (show only), never `model.chip`/`jump(to:)`, so nothing folds or scrolls. A click on a lit chip turns it off. No Clear button. The Working chip's tip is the overview line.
- **Bar buttons**, right of the chips: **Summarize what's running** (`SparklesButton` → `summarizer.requestAll`, as the Working header has it) and **Fit** (`arrow.up.left.and.arrow.down.right`, tip "Fit everything", detail "Double-click the canvas"). No zoom buttons, no replay.
- **What `RouterNow` held,** placed by the canvas as a top overlay in its free area: `AwayStripView`; the pre-26 `RouterBusyLine`; "Nothing needs you" when Needs you is empty; `RouterNothingFound` when a search empties everything, or "Nothing matches · Esc to clear" when the filter does.
- **Folder folds.** `model.canvas.folderFolds: [String: Bool]` overrides the default (`doneOnly`), kept in defaults under `routerCanvasFolds`, as `routerFoldedZones` is.

## 6. Composer, pending area, flights (`RouterFlight.swift`, `RouterCanvasPending.swift`)

Both layouts use `RouterFlights`, `FlightStack`, `FlightPillFace`, `FlightLayer` and `FlightTarget`. The canvas's former
24-point arrow-and-shimmer line, settled-decision watcher and separate arc have been removed: they bypassed composer
tracking, frame waiters, the Fjord loader, failure and Retry.

- **Send and pending.** `RouterModel.send` sets `context.flies = true` for either layout. The dispatcher records the run in
  `flying`; `FlightStack` syncs its signature into `RouterFlights`. A 34-point pill rises above the composer with `FjordLoader`,
  the user's words and “finding where it goes”, then the chosen destination. An ask unfolds into the same `AskBackCard` in
  place. Canvas also keeps asks from sends outside the composer here. Failure leaves the shared error pill with Retry and
  dismissal; Retry submits a new tracked run. Stopping uses the same brief stopped state as the list.
- **Destination and frames.** `RouterFlights.landing` resolves an answered card, started or existing session, or history.
  A session that was finished becomes Working before launching. `CanvasFlightPlaces` maps the canonical key to its card
  first, then its Working row. Nodes and frame headers register `canvas:<id>` using the same `flightTarget` modifier;
  resized bodies register clipping bounds. Measurement runs only while `RouterFlights.tracking` is true.
  [`GeometryProxy.frame(in:)`](https://developer.apple.com/documentation/swiftui/geometryproxy/frame(in:)) converts a view's
  bounds to the named coordinate space. Here that is `FlightSpace` outside the camera: measurements already include pan,
  zoom and viewport origin, so flight destinations must not apply that transform again. The hosted regression checks this
  against independent content-space node rects at two camera transforms.
- **Frame wait.** The shared preference-driven waiter holds the pending pill for up to 450 ms while a new Working node is
  laid out. A missing, folded, filtered or internally scrolled-out node falls back to its project's header. No camera,
  filter or folder state changes to make a flight happen. A project excluded by search or muting uses its section chip,
  then History, so the send still has a visible landing.
- **Flight and landing.** The shared flying copy replaces the pending pill and uses the list's quadratic path, resizing and
  fading into its target over 450 ms. An off-view target ends at the existing edge-marker position; arriving leaves the
  matching clickable marker, without moving the camera. A partially visible card receives the flight in its visible part,
  matching the existing marker policy that treats any visible part as in view. `FlightTarget` supplies the same landing glow as the list, while
  canvas keeps “You: …” on the node's bottom edge for six seconds. Clicking the marker alone moves the camera.
- **History.** The History button registers `pane:history`; a Router-only answer flies there and opens its panel on landing.
  Edits retain their existing immediate History behavior.
- **Reduce Motion.** The shared flying copy stays at its departure and fades over 220 ms, then lands and glows. There is
  no canvas pan or arc; the marker and landed words remain available.

## 7. Keyboard and accessibility

- **Open card accessor.** `RouterModel.openNeed(store)` returns `expandedNeed` only in canvas mode, else `page.openNeed(preferred:)`; `expandedPlan`, `RouterKeys`, the form keys and the list move to it. So Esc never puts an unseen plan into revise mode.
- **`select`/`showPick` in canvas mode** stay on Now (no `show(.history)` for closed cards), open the node per §0.8, and reveal by node id (`workingID` for waiting rows, as now). Callers unchanged: `AppWindow.swift` (170/522/794/797), `RouterAttention.swift:226`, `Playground.swift:177`.
- **`sections`/`cards`** in canvas mode: `earlier` (History's addressed cards, kept for ↑↓ since History stays beside the canvas) + the open cards (`needs + ready + notes` shown) in `RouterCanvasModel.order`. Done nodes are not added (they are `earlier`'s cards); Waiting is not walked, as in the list. Pure from `make`, no view cache, so `reconcile`, `address`, banners and keys work before the canvas draws. `move(down:)` and Return work unchanged; selection pans into view.
- **Esc chain**, in full: search field → plan revise-back → mentions → prediction → pinned → query → reply → enter revise (only when a plan is open on the canvas) → **fold the open node** → **clear the canvas filter** → close.
- **Accessibility.** The canvas is `.accessibilityElement(children: .contain)`, "Router canvas", with actions "Fit everything", "Zoom in", "Zoom out". Frames are containers "<project>, n sessions" (", folded"). Group labels are `.isHeader`. Children are declared in `order`. Nodes keep their labels, values and actions. `AccessibilityTreeTests` gains a canvas place.

## 8. Verification

**Shots.** `Shot` gains `layout`, a `camera` setup and `colorScheme` (dark sets `window.appearance = .darkAqua`), applied in `Shot.compose`. New `AppWindowShots.catalog` entries, destination `.router`, 1440×900 unless noted:

| Shot | Setup |
|---|---|
| `router-canvas` | `pickCanvas()` (every canvas shot starts so) |
| `router-canvas-dark` | dark |
| `router-canvas-card420` | a Needs-you card with KindTag, TriageChips, approval tint, "n of N left" (§4 check) |
| `router-canvas-open-needs` | the question card (lcu) open |
| `router-canvas-open-plan` | the plan card (linux) open |
| `router-canvas-open-working` | `local_demo-lookout` open |
| `router-canvas-open-notes` | a Worth a look card open, `Demo.routerTriage` |
| `router-canvas-triage` | `Demo.routerTriage` (approval, waiting, ready, finish) |
| `router-canvas-filter` | filter Needs you and Working |
| `router-canvas-done-folded` | done-only folders folded |
| `router-canvas-search` | `model.search.query = "lcu"` |
| `router-canvas-narrow` | 1000×760 |
| `router-canvas-pending` | a pending decision plus the demo's ask-back |
| `router-canvas-pending-pill` / `-dark` / `-narrow` | one tracked pending pill, Fjord loader directly above the composer |
| `router-list-pending-pill` | the same pending state in the list |
| `router-canvas-failed-pill` | shared failure, Retry and dismissal |
| `router-canvas-flight` | `model.flights.freezeFlight = 0.5`: shared pill mid-flight, landed words kept |
| `router-canvas-edge` | shared flight completed off view, its matching clickable marker |

**Commands**, from the worktree, then read each PNG:

```
cd /Users/polarzero/code/projects/lookout/.claude/worktrees/router-canvas
swift build
.build/debug/Fjord --window-shots /tmp/router-canvas router-canvas
ls /tmp/router-canvas   # then Read /tmp/router-canvas/window-router-canvas*.png
.build/debug/Fjord --window-shots /tmp/router-shots router   # the list mode is unchanged
```

**Check in the shots:** each open card 420 wide and fully above the composer; no frame shifts sideways; no text both in a header and its body; lines meet the headers' middles; nothing drawn over History or the top bar; light and dark both read.

**Tests**, one suite per run (`swift test --filter <Suite>`):
- `RouterCanvasLayoutTests` (new, pure): grouping by folder and Scratch; muted dropped; a session in Needs you and Working has both nodes, ids `card.id` and `working#…`; Done newest per session from searched history (Unread filter ignored), 3 then +n, picked kept; Worth a look 3 then +n, widened for a pick; busiest first; column choice by closed heights; an open height pushes only its column; connector endpoints; filtered groups hidden in place, search-emptied frames hide; folded folders header-tall; `order`; `target(forReveal:)`; camera `zoom(by:at:)`, `fit` clamps to 1.0, `origin(toShow:)`.
- `RouterFlightTests`: dispatcher-to-pill lifecycle in both layouts, failures and retry, asks, new Working row frame waiting,
  canonical destinations and one landing.
- `RouterFlightsTests`: card-before-row targeting, hidden and missing node fallbacks, clipping, transformed headers, edge
  destinations, landed words, and a camera that stays until the marker is clicked.
- `RouterCanvasFlightViewTests` (`.hostsWindows`): one 34-point pill above the composer, actual preference registration at
  two pan/zoom transforms, and pending sends retained when switching back to the list.
- `RouterCanvasTests` (new, `.hostsWindows`): mounts `RouterCodeView` with `.canvas`; the list by default; the switch writes `routerLayout` and a new model reads it; ↑↓ follow `earlier` then canvas order; the Esc chain folds, then clears the filter; Esc with nothing open never enters revise.
- Rerun: `RouterMotionTests`, `AccessibilityTreeTests`, `RouterUITests`, `RouterZonesTests`, `RouterLayoutTests`, `RouterCardRedrawTests`.

### Shared-flight verification (October 13, 2026)

The regression first reproduced a canvas composer send with no shared pill and `tracking == false`. After the fix,
`swift test --filter 'RouterFlightTests|RouterFlightsTests|RouterCanvasTests|RouterCanvasFlightViewTests|RouterCanvasLayoutTests|RouterMotionTests|RouterLayoutTests'`
passed **57 tests in 8 suites**. The required single `scripts/test.sh` run passed **1572 tests in 156 suites in 47.678 s**.

Checked offscreen PNGs, retained under `.build/shots/router-flight/`:

- `window-router-canvas-pending.png` and `window-router-canvas-pending-dark.png` (pending plus ask-back).
- `window-router-canvas-pending-pill.png`, `window-router-canvas-pending-pill-dark.png` and
  `window-router-canvas-pending-pill-narrow.png` (logo pill and composer spacing).
- `window-router-canvas-failed-pill.png` (error, Retry and dismissal).
- `window-router-canvas-flight.png` and `window-router-canvas-flight-dark.png` (shared pill held halfway).
- `window-router-canvas-edge.png` and `window-router-canvas-edge-dark.png` (completed shared flight's matching marker).
- `window-router-list-pending-pill.png` and `window-router-composing.png` (regular composer comparison).

The list's content area renders black in these offscreen captures, while its composer and pending pill render normally.
Building the original HEAD sources in this same worktree reproduced the black content area in
`.build/shots/router-flight-baseline/window-router-composing.png`; no other checkout was used. Canvas renders were complete.

Motion was checked through the shared path: no canvas animation remains; the same 450 ms flying pill completion calls
`RouterFlights.land`, supplying the glow, landed words and edge marker. Reduce Motion uses the same 220 ms stationary fade
before landing. No live run, Instruments, installation or persistent-default changes were needed. Temporary logs were removed.

## 9. Build order (three stages, each one commit, gated on build, its tests and its shots)

1. **Container, layout, frames, groups, connectors, folded nodes, switch.**
   - Work: drop `private` on the reused types; `PillSwitch`, `RouterLayout` and the switch; `RouterCanvasState`/`CanvasCamera`; `RouterCanvas` (monitor, pan, zoom, fit); `RouterCanvasModel`, `CanvasMetrics`, `CanvasMasonry`, `FolderLayout`, connectors, with the pure tests; `CanvasFolderFrame`, labels; folded nodes reusing `CardView`/`WorkingCard`/`WaitingCard`/`HistoryCardLine`; the top overlay (§5); shots `router-canvas`, `-dark`, `-card420`, `-triage`, `-narrow`.
   - Commit: "The Router has a Canvas view beside its list, switched from its top bar and kept across launches: every project folder is a frame with its sessions grouped under Needs you, Worth a look, Waiting, Working and Done, joined by lines to the Router's own cards, on a ground you pan with two fingers or a drag, zoom with a pinch or ⌘-scroll and fit with a double-click".
2. **Open in place, actions, filters, folding, keyboard.**
   - Work: one open node through `expandedNeed`/`expanded`/`openWorking`; `openNeed(store)`; `select`/`showPick` canvas branch; forms and plans with `formCap` 360 and pass-through scrolling; Archive, Open, Tell it, Summarize, Got it, Reopen, menus; `CanvasChips`, Summarize what's running, Fit; done-only folds kept; search empties; `sections` in canvas order; Esc steps; reveal, selection and prediction pans; accessibility; `RouterCanvasTests`; shots `-open-*`, `-filter`, `-done-folded`, `-search`.
   - Commit: one sentence on cards opening in place with their form, plan, summaries or details, the filter chips, the folding of done-only folders, and the keys walking the canvas.
3. **Composer, pending area, flights.**
   - Work: `RouterPendingStack` with ask-backs; `RouterDecision.status`; `RouterFlights.departures` with tests; `ArcFlight`, ripple, "You:"; the History switch rule; Reduce Motion paths; shots `-pending`, `-flight`; `router.md` "Page" gains a "Canvas" paragraph pointing here.
   - Commit: one sentence on messages waiting above the composer with what the Router is doing to them, then flying to the card they went to after it pans into view.

## 10. Review notes (rejected)

- "`sentMessage` doesn't exist": it does (`RouterFork.swift:234`), for single-session `.you` runs; it is the first target source, `delivered?.session` and `links.sessions.first` the fallbacks.
- "Use ⌘1–4 for the open question when no ask-back shows": without an ask-back, ⌘1–4 are the Go menu's destinations; forms keep their own controls.
- "Give the Needs-you node `WorkingCard`'s live line instead of a second node": keeping both nodes, as the list does, keeps the live line with no `CardView` change.
- "Show the branch only when every session's cwd agrees": no branch at all for now; the app shows none, and it needs per-session cwd reads for little gain.
- "Offer Cancel on the landed node's 'You:' line": left to History, where Cancel already lives; a 6 s line is too short-lived for it.
