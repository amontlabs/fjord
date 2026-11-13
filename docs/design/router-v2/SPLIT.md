# A message split across threads (1.9.2, look only, 2026-11-13)

Owner-approved behaviour; the demo shows the look, the decider doesn't split yet.

- **Only pills:** code routes each pill at once (an answer to its thread), no read.
- **Any free text:** the Router reads the whole message, with the pills as context, and returns a list of sends
  (`RouterRead.sends`): each a place (a thread or a new thread) and the exact parts of the owner's message for it,
  verbatim, never rewritten. A part can go to several places. Answer pills attach to their threads' sends.
- **Return sends all.**

## The rows

The destination row becomes one compact row a destination, in the order their words come in the message, 24 tall,
no gap between them (they read as one list), no ground, the arrow on the composer's text edge as before:

```
→ [? Settings layout fjord]  ▒keep the sidebar icons in the page headers▒  + 1 answer
→ [? Val Cenis booking]  answers “Reserve for five (+€62)”
→ [··· Tab handover fjord]  ▒tab handover: skip the fade for now▒
```

- **Tint.** Each destination has a tint, in row order: violet, green, cyan (`Router.Split.tints`), chosen away from the
  state colours (amber, red, blue) and the working clay. A part's words sit on that tint at 22 % in the composer and,
  the same, as the row's quote (radius 4, 18 tall, no quote marks, no outline: the ground is the link). Words two sends
  share keep the first one's tint. An answer pill's glyph takes its send's tint.
- **Answers.** After words, `+ 1 answer` muted. Alone, the row says the answer as a picked option's row does:
  `answers “…”`.
- **Unsure part.** Its row shows the usual places (up to three, the guess lit with the `chosen` fill, a place you lit
  yourself with the accent's tint, the light sliding on `Motion.glass`), then its words. The first unsure part is the
  focused one: only its places show `⌘1`–`⌘3`, and ⌘1–3 (by key position, AZERTY-safe) light its places.
- **Reading.** Pills are placed by code at once, so their rows show while the free text is read; one more row holds
  Fjord's mark in the arrow's slot and the skeleton bar with its sheen where the place will be.
- No mode words in a split row (steer / queue, "answers its question"): the row stays one line. A place you pick
  yourself for the whole message (a thread pill, the places menu) ends the split.

Shots: `v2-split-two`, `v2-split-pills`, `v2-split-unsure`, `v2-split-reading` (light and `-dark`). Suite:
`RouterSplitTests`.

## Not done (look only)

The decider's schema and prompt (sends with verbatim parts), the live `MentionField` tint (the stills draw the composer
themselves), Return sending each part, Tab between unsure parts, and the failure line for one send of several.
