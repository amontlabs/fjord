# A message split across threads (1.9.2, look only, 2026-11-13)

Owner-approved behaviour; the demo shows the look, the decider doesn't split yet. This replaces the first look
(tinted parts in the composer, one row a destination over it), which the owner found confusing.

- **The composer stays plain:** the owner's words and pills, no tints, no fragments.
- **The Router writes each destination's message** from the owner's words (`RouterRead.sends`, each a place and its
  `words`): it keeps their wording and only trims what belongs elsewhere; it never rephrases and never adds intent or
  initiative. No code splits on punctuation.
- **Return sends all.**

## On the page, on the targets

```
→ [? Settings layout]  sidebar, one page, or tabs?                    fjord  25m
    → “keep the sidebar icons in the page headers”
  [? Val Cenis booking]  found a chalet for five; nothing reserved yet        12m
→       ? reserve for five? about €62 more than for four                      12m
          → yes, reserve for five
  Working 4
→ ┆New thread┆                                                        fjord
    → “trim the onboarding copy to two screens”
```

- **The target's arrow** sits in its dot's slot (`arrow.right` 9 pt semibold, `Text.accent`), lines and items alike, so
  the targets read down one edge of the page.
- **The pending line**, under the row: a muted `arrow.right` in the mark's box (under the name's mark; an item's under
  its mark), then exactly what the target will receive, footnote `Text.secondary` at 75 % (not yet sent), up to three
  lines. Words to a thread are quoted; an answer to an item is said as the answer. A part the Router guessed at ends
  with `· a guess` muted.
- **A new thread** is a ghost line first in Working: the arrow, `New thread` on a dashed outline where a name's ground
  sits, its project pill in the pills' column, no age, and its pending line.
- Pending lines and ghosts fade in and out (`Motion.fade`) as the read changes; the rows under them glide.

## Over the composer

One compact row a destination, saying what the page's pending lines say (same arrow, same wording, same quotes rule):

```
→ [? Settings layout fjord]  “keep the sidebar icons in the page headers”
→ [? reserve for five?]      yes, reserve for five
→ + New thread fjord         “trim the onboarding copy to two screens”
  +2 more                                                              past four rows
```

- Each row: the target arrow, the place as the page names it (a thread's mark, name and project; an item's kind mark and
  short words; `+ New thread` and its project), then what it receives, cut once at the end. A guess ends `· a guess`.
- **Past four rows**, `+N more`; the part ⌘1–3 light is always among the four.
- **Reading again:** the rows the last read knew stay; a skeleton row with Fjord's mark stands for what is still read.
  The first read of a draft shows the usual mark and skeleton row (1.9).
- **Unsure part:** its row shows its usual places (the guess lit with the `chosen` fill, a place you lit yourself with
  the accent's tint, the light sliding on `Motion.glass`), then its words; ⌘1–3 (by key position, AZERTY-safe) or a
  click light one, and its pending line moves to that target. Only the focused part shows its places.
- The pointer on a row lights its target on the page; a click brings it into view (a new thread: its ghost line).
- A place you pick yourself for the whole message (a thread pill, the places menu) ends the split.

Shots: `v2-split-page`, `v2-split-reading`, `v2-split-unsure`, `v2-split-one`, `v2-split-many` (light and `-dark`).
Suite: `RouterSplitTests`.

## Not done (look only)

The decider's schema and prompt (sends with their words), Return sending each message, Tab between unsure parts, a
click on a pending line on the page, and the failure line for one send of several.
