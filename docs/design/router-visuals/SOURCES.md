# Fjord's Router: context for advisors (2026-11-14)

## The product
Fjord is a native macOS app (SwiftUI) for one developer (the owner) who runs 5-20 AI coding agent threads at once
(Claude Code and Codex, hosted by T3 Code, a local agent GUI that Fjord reads and drives). The **Router** is Fjord's
main page: the owner lives there and opens T3 only occasionally. Core framing: keep the agent boost; Fjord absorbs the
overwhelm and funnels only what the owner must know or decide.

## The page today (Router v2, all text)
- One block per thread, grouped by state: **Needs you** (amber), **Stopped** (red), **Done** (grey; blue "worth a look"),
  **Working**, **Sent**. Stable order inside a section. Filter bar of project pills with counts.
- A thread line: name (model-written, short, coloured ground when it asks something), one sentence, activity glyphs
  (subagents, background commands, waits, with counts), project pill, age.
- **Open items** per thread (a ledger kept by a model read on every turn end and owner message): kinds **Stuck**
  (red), **Decide** (amber: question/choice), **Do** (amber: a step only the owner can take), **Know** (blue). Each
  item is an indented row: kind mark, sentence, age. Item card: detail, the agent's quoted lines, links, options
  (digits pick, Return sends), Done (revertible), Open in T3.
- T3 requests (question, multi-question form, plan approval, permission for a command) are Decide items with options.
- Working threads: a model (Haiku) writes a 9-word present-tense summary at most once a minute; the card shows the run's
  summaries as a timeline (newest first, up to 20), what started each run (your message, a subagent finishing, a
  background command finishing), to-do steps, subagents/commands/waits with ages.
- Done card: PR badges, "4 files +96 −212".
- Hover = line plus more; card = hover plus more (one layered structure).
- One composer (the only text field) at the bottom; a destination row says where Return sends (a thread, steer or
  queue, or a new thread with model/effort/mode pills).
- Instant feedback: sheen on lines being re-read by the model, Fjord's animated logo while the model works, streamed
  words, lines glide between sections.

## Data Fjord can read (from T3 and local)
Every thread's messages and tool calls; per-turn diffs and checkpoints (files changed, +/−, hunks; turn rollback);
PRs and their state; commands and their output; subagents (title, model, start); to-do steps; plans (markdown);
permission commands; question options; the summaries over time; the open-items ledger history; ages and timestamps;
projects/repos; local git. Images: agents in this very repo routinely render offscreen PNG "shots" of the UI they
changed (`--window-shots`) and recordings; T3 questions can carry image attachments. Fjord can also call models
(Haiku/Sonnet/Opus etc.) per event; generating a bespoke visual per item is cheap now.

## Owner's preferences (hard rules)
- Everything but the model decision must feel instant; no fixed waits/polling. Model work shows Fjord's logo + sheen.
- No modal confirm asks; reversible acts act at once with Revert. Keyboard-first, AZERTY: no letter shortcuts.
- No word lists/regex to interpret messages: a measured model, or a button.
- Concise prose with coloured, linked thread names and a hover peek is liked (the old "Digest brief").
- Settled/done work is ignored unless named. A coloured ground means it asks something of you.
- Prefer showing real outcomes over process.

## Lessons from an earlier visualization exploration (2026-10-11/12, Claude Code era, before Router v2)
It produced 37 proposals and a 15-demo gallery (dark board, flight-strip rack, timelines, file-collision maps,
commit braids, supervisor mirror). The owner's verdict: "you take one small thing and expand everything around it,
losing the big picture". Real data showed few file overlaps between sessions, so link/collision views looked empty.
What the owner wanted: the plain overview (threads by state per project, a few facts each) first, layers only after.
Research it relied on (don't redo): dark board (normal is dark, colour only for real deviations), cry-wolf (alerts
below ~50% precision get ignored), stable positions, factual now-anchored timelines beat predictions (MAUVE), open
queue with transparent ordering beats prescriptive FIFO, chronological resumption cues double resumption success
(Parnin & DeLine), workspace awareness (FASTDash/Palantír).

## What the owner asks now (2026-11-14, verbatim)
"We've been living in the text era, and now with AI we've come at a point where it's fast and cheap to generate novel
ways of understanding, including visualization. I feel like our router is a great ground for such innovation. Can you
think of any ways we could accompany the router with visualization? As in ways that would improve the user
experience, as in make it easier, more convenient, intuitive, faster, overall better to review what's happening, act
on it. ... novel and creative ideas. No fluff, no random ideas, really research first."
# Research: reviewing and steering agent work (Sonnet researcher, 2026-11-14)
Caveats: Sadowski 2018 and Horvitz 1999 not verified. Nothing sourced on LangSmith/Langfuse UI feedback. Several 26xx arXiv read from abstracts only.

- ParallelPilot (Long et al., arXiv 2609.33113, via agentpatterns.ai write-up; 16 devs): throughput .272→.445 tickets/min, concurrent agents 2.31→3.25; "noticed when agents finished/needed me" 3.63→6.19/7; "clear picture of progress" 3.44→6.06. Control, trust, ease of verification: no change. Awareness solved, verification/control not.
- Anthropic "Measuring AI agent autonomy in practice" (Feb 2026, 500k Claude Code sessions): most common self-stop = presenting a choice between approaches (35%); on complex tasks clarification stops outnumber human interrupts >2:1; experienced users auto-approve more (20%→40%) but interrupt more (5%→9% of turns); top human interrupt reason: missing context/corrections (32%).
- METR RCT 2025: AI-allowed issues took 19% longer while devs believed 20% speedup (early-2025 tools).
- Anecdote: parallel setups top out at 3-8 agents; review is bottleneck; sessions idle 90s+ waiting on approval.
- Bacchelli & Bird ICSE 2013: understanding the change is the central difficulty of review; tools don't support it.
- di Biase et al. (arXiv 1805.10978): decomposing composite changes → fewer wrong issues, more context-seeking; no effect on rationale understanding or defects found.
- Rahman et al. (arXiv 2609.04207, 1,355 devs): 10.2% find alphabetical file order optimal; 66% want dependency-aware grouping.
- Files higher in list get more comments (arXiv 2306.06956).
- Gong et al. MSR'26 (arXiv 2601.04886, 23,247 agent PRs): PRs whose description claimed unimplemented changes: 28.3% vs 80% acceptance, 3.5x slower merge. Wrong summaries are costly.
- Oskooei & Aktas IJCAI 2026 demo (16 AI engineers): four-panel dashboard (TODO/plan, reasoning apart from actions, sub-agent grid, filesystem view) vs LangSmith linear trace: time-to-insight 5.5→2.4 min (p=.004), NASA-TLX 64.8→43.7.
- AgentGUI (Zhao et al., arXiv 2607.26300, n=8): live timeline + feed: 145s→90s, accuracy 80→93%.
- Cursor 2.0: agents-first sidebar, one aggregated multi-file review view (mixed reviews). Conductor: worktree + diff panel. Vibe Kanban board sunset; Crystal deprecated.
- Outcomes: no controlled study of screenshots/videos speeding review; Zulip requires before/after screenshots for visual PRs; ICSME 2026 mining of Chromatic PRs.
- Decision asks: no study comparing option presentations found.

Implications: lead with state change; awareness doesn't buy trust → one-step evidence (diff, test, screenshot) next to every action; anchor summaries to checkable facts; structure beats linear log; Decide is the main item type.
# Research: AI-generated per-item visuals vs text (Sonnet researcher, 2026-11-14)
No controlled study of generated visuals for supervising parallel agents exists; real research gap.

- Larkin & Simon 1987: diagrams win only when they group needed info by location and support perceptual inference; arbitrary diagrams worth little (baseline was unlinked sentences).
- Graphologue (Jiang, Rayan, Dow, Xia, UIST 2023): long LLM text hard to scan; node-link diagrams helped grasp connections (qualitative, n=7-10).
- Graphionale (Wang et al., arXiv 2608.27932, n=204): graph rationales improved trust calibration for verbal reasoning but felt more demanding; for visual reasoning they impaired calibration but felt engaging. Feeling helpful ≠ calibrating.
- Gero et al. CHI 2024 (n=24): structure that surfaces similarities/differences across many LLM outputs made intractable sensemaking tractable.
- Google Generative UI (Nov 2025): preferred over text/markdown in blind preference, below expert-designed pages; takes "a minute or more", "occasional inaccuracies". Preference, not speed.
- Claude custom visuals in chat (Mar 2026): HTML/SVG on request or when judged useful, temporary. No usefulness data.
- CodeRabbit: Mermaid sequence diagrams for PRs that change component interactions; own essay: a visual should "answer a structural question rather than repeat the diff"; polished summary "does not substitute for comprehension".
- Failure: AI sequence diagrams hallucinate methods, show only happy path (CodeAnt guide).
- Bret Victor, Magic Ink: information software = context-sensitive information graphics; comparison across space beats across time; interaction is a curse to minimize (train timetable as time-distance graph).
- Geoffrey Litt "Enough AI copilots! We need AI HUDs" (Jul 2025): HUD overlays that become part of perception; AI-built visual debug view surfaced other problems; unusual high-stakes situations need instruments.
- Wattenberger "Why Chatbots Are Not the Future" (2023): comparing responses in chat laborious; let user choose when to switch generate/evaluate; over-automation → "machine operators". Semantic zoom talk (ladder of abstraction over text).
- Tableau Research (64 reading flows, 8 layouts): reading paths diverge; weakly emphasized important elements read late.

Implications: visual only when the question is structural (what changed where, how options differ, how steps depend); fixed visual grammar filled by the model, never arbitrary layouts; checkable, tied to real files/lines/screenshots, text stays source of truth; generate ahead of the glance, text first; eval on own real moments, measure calibration not just speed.
# Research: compact glanceable encodings (Sonnet researcher, 2026-11-14)
No source measures non-text glyphs on a list of agent threads; implications are inferences.

- Goffin, Willett, Fekete, Isenberg TVCG 2014: word-scale graphics between lines / extra space / hover overlays; trade readability vs disruption; use hover where marks collide.
- Heer, Kong, Agrawala "Sizing the Horizon" CHI 2009: line charts stable to ~24 px high; 2-band horizon charts match/beat from ~12 px, usable ≥6 px; >2 bands cost time and error.
- Beck & Weiskopf word-sized graphics catalogue; no speed measurements.
- Matthews et al. 2006 glanceability framework (abstract only).
- Harrison et al. UIST 2007 progress bars: slowness tolerated early more than near the end.
- Data Mountain (Robertson UIST 1998): spatial layout + thumbnails retrieved faster than Favorites; extra cues beyond title slowed IE4.
- CommandMaps (Scarr, Cockburn CHI 2012): spatially stable layouts faster for experienced users.
- Gajos 2009: spatial adaptation prevents building visual-search habits.
- Nowell et al. InfoVis 2001: change blindness hides even major changes between snapshots.
- Heer & Robertson 2007: animated transitions improve tracking; Chevalier et al. 2014: staggering negligible or negative.
- Cockburn, Karlson, Bederson 2008 review: no ideal; overview+detail costs switching; fisheye/distortion largely fails; overview+detail and zoom usually pay off; fisheye text read faster but overview+detail better comprehension.
- AgentLens (arXiv 2402.08995): hierarchical temporal view of multi-agent runs, drill-down (n=14, result unknown). InconLens (2026): align trajectories across repeated runs.
- Rosenholtz CHI 2001: text-enhanced thumbnails matched best alternatives on search.
- No study shows LLM-generated icons/thumbnails speed scanning.

Implications: stable rows; mark what moved, no stagger; at most one small per-row history mark (12-24 px, ≤2 bands); channel budget = colour (state) + position (group) + one mark; detail via hover/inline card, not distortion; generated icons/thumbnails unproven.
# Advisor A (verification lens), ranked
1. Receipts: claims in the Done/Know sentence get word-scale marks: solid (backed by a fact: diff file, command exit, PR state, shot), dotted (nothing to check), red (contradicted). Model splits claims and tags a receipt type from a fixed vocabulary; code finds the fact and decides. Card lists receipts with ↗ diff / output. Risk: most claims uncheckable → dotted noise; fallback: red only. Experiment: offline over ~100 real Done turns.
2. Before/after: the agent's own rendered shots on the Done card, last shot before first edit vs newest; stale dimmed; model ≤6-word caption only. Risk: coverage. Experiment: count turns with shots + usable before.
3. Change map: diff as one strip of blocks per meaningful group (model groups, must cover exact path set; code sizes), test tick; only above ~5 files.
4. Run ribbon: working run as a 12 pt ribbon of edit/test ✗✓/command/subagent/wait from facts; is it thrashing or converging. Experiment: replay 30 runs, count red→green patterns summaries missed.
Rejected: generated architecture/sequence diagrams (hallucinate, worse calibration); model confidence meter (cry-wolf); generated icons/thumbnails, replay.
# Advisor B (decide/act lens), ranked
1. Option grid: Decide options as rows × fixed columns (touches, undo easy/care/one-way, agent leans, +1 free); same-for-all cells greyed, differing cells primary; every cell quoted word for word from the reply or shown as —; <2 cells → today's list. Experiment: Decides with ≥3 options; drop if <30% get ≥2 checked columns.
2. Clear-cost mark: trailing glyph per item (one pick / needs a read / needs a look / only outside Fjord) + a key that walks the quick ones. ≥80% prediction of owner's real act.
3. Plan spine: plan markdown → step spine with touched files and one-way ⚠ (quoted); strike or annotate steps; "approve with these corrections". Experiment: share of plan approvals followed by a correction (<15% → skip).
4. Off-course mark: Haiku compares newest summary to what started the run; one ⤳ mark where work left the ask; precision ≥70% or don't ship.
Rejected: generated icons/diagrams; attention score reordering the page; predicted ETAs.
