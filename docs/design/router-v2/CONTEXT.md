# Router v2: context for the design and the demo video (2026-11-12)

## What the owner asked
After three Fable reviews of the Router page (files below), the owner agreed with the whole assessment and all decisions:
- Group the page by **state** (Needs you / Done / Working, plus Stopped and Sent), drop the separate lead (For you / Worth a look).
- Opening a thread in T3 no longer clears an ask. Delete Mark read; asks leave on answer or Settle.
- One model verdict per thread, rerun only when that thread changes (new turn, new request, owner's message, PR state change).
- Delete the after-send "Where should this go?" card; destination is chosen before Return (one destination row, ⌘1-3, steer now / ⌥ queue).
- Remove hidden letter keys (o / a / r).
- **Project stays as pills** on each line. **Convenient filters**: clicking a project pill filters to that project; nice filter UI and UX.
- **Top-tier transitions and feedback.** Instant feedback with skeletons and streaming: an action by the owner, or anything happening inside T3 Code, shows on Fjord instantly: what is happening, what will be updated (skeleton/shimmer on the line being reassessed), then the update streams in live.

Owner's words: "Before changing anything, I want you to show me. Show me a video that is representative of the full new design, conceptually. Real components like it should be as if I was using the app, except on fake data, and shows every kind of state and interaction, so I know precisely and thoroughly everything you want to do."

## Inputs
- Reviews: /private/tmp/claude-501/-Users-polarzero-code-projects-lookout/790fd66f-cbe4-4485-ae63-8080a4beb1a6/scratchpad/review-state.md, /private/tmp/claude-501/-Users-polarzero-code-projects-lookout/790fd66f-cbe4-4485-ae63-8080a4beb1a6/scratchpad/review-information.md, /private/tmp/claude-501/-Users-polarzero-code-projects-lookout/790fd66f-cbe4-4485-ae63-8080a4beb1a6/scratchpad/review-interaction.md
- Summary page published to the owner (HTML source): /private/tmp/claude-501/-Users-polarzero-code-projects-lookout/790fd66f-cbe4-4485-ae63-8080a4beb1a6/scratchpad/router-rethink.html (sections 4-7: states table, ideal page mock, core loop).
- Current UI shots: /private/tmp/claude-501/-Users-polarzero-code-projects-lookout/790fd66f-cbe4-4485-ae63-8080a4beb1a6/scratchpad/shots/window-*.png. Current code: Sources/Fjord/RouterBriefView.swift, RouterBriefs.swift, RouterComposer.swift, RouterKeys.swift, DemoBriefs.swift, CDS (design system tokens: grep "enum CDS").
- Repo rules: CLAUDE.md, DEVELOPMENT.md. Shots: `.build/debug/Fjord --window-shots <dir> [name…]` (catalog Sources/Fjord/AppWindowShots.swift).

## Owner preferences (memory)
- Show UI in the real app, recorded window-only with ScreenCaptureKit (SCContentFilter(desktopIndependentWindow:)), 2x, 60 fps, mp4 + a half-speed copy. Never mockups, never screen-rect captures (they leaked other windows once).
- Everything but the model decision must feel instant; no fixed waits or polling.
- No modal confirm asks: show inferred decisions live, Return confirms. Reversible acts act at once with Revert.
- AZERTY keyboard, French macOS UI: no letter shortcuts; ⌘-chords, digits, arrows, Return, Tab, Esc are fine.
- No word lists/regex to interpret messages.
- Liked: concise prose with coloured, linked thread names and a hover peek.
- Answer concisely in plain words.
- Never kill Chrome; no parallel test loads (`scripts/test.sh` once, or `swift test --filter`).

## Round 2 (owner feedback on the first video, 2026-11-12)
"This is absolutely excellent." Nits and asks:
1. **Loading indicator:** use Fjord's existing animated logo (Sources/Fjord/FjordMark.swift; see where it animates, e.g. HubPeek/Onboarding/Playground) instead of a new spinner/"reading…" indicator, wherever the design shows the model working.
2. **New-thread preview shows its settings:** when the destination is a new thread, the destination row previews the model, reasoning effort and mode (runtime mode: auto / full access / approval-required…, maybe interaction mode plan/default), editable by the owner (keyboard-first, AZERTY-safe), and the owner can write it in the message, e.g. "do X (use opus medium)": the Router (the model that reads the draft, no word lists/regex) picks it up and the preview updates live. Note: this overrides the 2026-11-06 "no model pickers in Fjord" rule in docs/design/t3-code-map.md, for new threads only. T3's `orchestration.launchThread` takes modelSelection, runtimeMode, interactionMode (t3-code-map.md A6).
3. **Feasibility:** review that EVERYTHING in the design and demo can truly be built on T3's real data and APIs.
4. **Polish:** every rough edge, nit, bad animation found and fixed by Fable reviewers, until top-tier. Known: macOS sharing badge over traffic lights in recordings, Snooze menu overlapping the line, busy beat 36 (beat 40 since the new-thread beats 27–30 went in), ghost of closing card ~0.1 s, "Show all" cross-fade in two places, sheen subtle in light theme, skeleton not in video, first frame housekeeping under dock, draft-text selection highlight in stills.
