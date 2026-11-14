# Router visuals: ideas and first prototypes (2026-11-14)

Round 1 (research-led: diff maps, claim checkmarks, option grids) was rejected by the owner: it was not visual,
and it was built on things the owner never looks at. Round 2 started from the owner's own messages.

## Pain points (1,880 owner messages in T3, 2026-10-28 → 11-14)
- Visual work judged and corrected in words, ~185: videos, logos, the website, the Router UI. One list took 12
  corrections in 15 minutes.
- "Help me visualize / explain simpler / I don't understand", ~115: how things work, what an agent sees, who holds
  what.
- "How is it going, what's taking time", ~65.
- "Really done? Which model actually ran?", ~65.
- "Show me the real thing", ~60. The owner approves visual work on sight and everything else on trust.
- Never asked for a diff, a file list, code or a log. A motion-graphics explainer video of Silo worked where five
  rounds of prose had failed.

## Ideas (Fable, two lenses)
1. **Point-and-say.** Mark a spot on the thread's real render and type about 5 words. A vision model writes the
   instruction, and the next render comes back as a before/after crop per mark.
2. **Fjord's own before/after.** When a UI turn finishes, Fjord renders the shot catalog at the turn's start and end
   checkpoints and shows what visibly changed, or "nothing visible changed". No model is involved.
3. **Storyboard.** An agent's explanation of a mechanism becomes 4 to 8 frames in a fixed grammar: actors, arrows,
   a moving token, and a caption of 12 words at most. Each frame carries a verbatim source quote. Step with ← →.
4. **Run picture.** Swimlanes for the main agent, the subagents (with the model each actually ran on), background
   commands and waits.
5. Further ideas:
   - **Agent's eye:** the literal context an agent received, stacked by who put it there.
   - **Splice board:** rendered options you can recombine.
   - **Take reel:** video versions on one synced timeline, with the changed stretches lit.
   - **Decision pictured:** options drawn as their consequences.
   - **Fleet map:** rejected, too close to the October exploration.

## Prototypes on real data (scratchpad, not in the repo)
- **Storyboard.** Two real lastdrop explanations that confused the owner. Sonnet generated the boards in one pass,
  with no fixes needed, and all 14 sources were checked verbatim.
  - Board A answers the question in a few key presses.
  - Board B follows the agent's story and misses the owner's actual question (context bloat, processes, cost).
  - Lesson: feed the owner's question in, make the last frame answer it, and include the screen the owner was
    looking at.
- **Run picture.** Three real runs.
  - The asked-vs-ran flag is clearly better than text: "use flash and gemini" next to 3 subagents recorded on Opus.
  - The Silo run's facts line already answers the question: 9% of the time running, 94 min waiting on subagents,
    59 min idle, 44 min on one Gemini review.
  - The lanes add only shape, and turn into noise at 112 subagents. Keep the facts line and the flag; lanes are
    secondary.
- **Point-and-say.** Four real Router corrections.
  - A box plus 5 words replaced 11 to 45 typed words.
  - Sonnet named *where* the problem was well, and was as precise as the owner on 2 of 4.
  - On the other 2 it gave a confident wrong *what to change*, where the cause wasn't visible (a fade layer, an
    alignment rule).
  - To work it needs the full render, the measured element frames, and the instruction shown before Return.

## Round 3: motion explainers (owner: "simpler, and why no motion graphics?")
- Format: answer line on top (the owner's question answered in ≤ 18 words), then a 15-30 s animation in 3-5
  scenes with one moving protagonist, a caption of ≤ 10 words per scene, a verbatim source per scene (checked),
  and ← → / Space. A fixed player shell, with the model writing only `setup`/`render(T)` (pure in time, so it can
  be scrubbed and captured at any frame for a check).
- Research: segmenting (system- or learner-paced chunks) helps across 56 studies (Rey et al. 2019); animation alone
  often doesn't beat stills (Tversky 2002; Höffler & Leutner 2007): motion only for what changes or travels.
  Generated explainers mostly fail on layout (TheoremExplainAgent): a render-and-look pass is required.
- Results (proto/motion in scratchpad): Opus case A (29 s), Opus case B (27 s), Sonnet case A. All quotes verbatim,
  1-2 min each including one look-and-fix pass that caught real overlaps. Case B, with the question fed in, now
  answers it, and says "not stated" for context size instead of inventing one. Gap: the thread mock in case A uses
  generic tool rows, not the real ones.

## Round 4: the creator, first real run (scratchpad/explainer)
- One `claude -p` on Opus 5.5 with no tools except `preview`. The system prompt is stable and cached: the role,
  principles, the kit API and one worked example. The user part is the moment: the ask, the last turns with the
  focused reply, and the activity.
- Kit: GSAP 3.15.0 (MotionPath, DrawSVG, MorphSVG, CustomEase) plus a small Fjord layer: node, chip, panel, link,
  region, badge, cross; appear, draw, travel, moveTo, recolor, relabel, dim. Pieces start invisible. Time comes only
  from the timeline, so the player can scrub, step scenes and render any frame offscreen.
- `preview(code, at)` renders the held frame at the end of each scene and returns the frames, timing and errors.
  Each call is a saved version, which is the live stream the dock shows while the creator corrects.
- 8 real moments: all produced a final explainer in 43-103 s (2-4 turns, 1-3 previews), $0.21-0.51 each at API
  prices.

## Round 5: answer-first flow and kit v2 (2026-11-14, final)
- The owner's question goes to the thread as usual. When that turn ends, the creator gets the question, the agent's
  answer and the turn's activity. The answer-first inputs removed every "not stated".
- Kit v2 (Fable, two passes): Geist, a camera that never cuts a piece, Lucide icons, cards, windows, threads,
  terminals and docs, flow, travel with a landing, spotlight, big type, counters. The preview reports layout notes.
  A theme switch keeps time and play state.
- 8 regenerated: $0.22-0.43 and 45-95 s each. Workspace: docs/design/router-visuals/explainer (untracked).
