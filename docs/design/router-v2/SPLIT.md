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

One line, the destination row's place and metrics:

```
→ 3 threads · Return sends                                          sure, several places
→ [? Settings layout fjord] · Return sends                          sure, one place
◐ 3 threads · Return sends   (sheen over the words)                 reading again after more typing
→ “the spacing”  [Tab handover fjord ⌘1]  Snapshot API ⌘2  new thread in fjord ⌘3  · Return sends   a part it isn't sure of
```

- While the Router reads, Fjord's mark takes the arrow's slot and the sheen passes over the words; the page keeps what
  the last read showed. The first read of a draft shows the usual mark and skeleton row (1.9).
- **Unsure part.** The line names it in a few of the owner's words (`RouterSend.part`) and shows its usual places
  (the guess lit with the `chosen` fill, a place you lit yourself with the accent's tint, the light sliding on
  `Motion.glass`); ⌘1–3 (by key position, AZERTY-safe) or a click light one, and its pending line moves to that
  target.
- A place you pick yourself for the whole message (a thread pill, the places menu) ends the split.

Shots: `v2-split-page`, `v2-split-reading`, `v2-split-unsure`, `v2-split-one` (light and `-dark`). Suite:
`RouterSplitTests`.

## Not done (look only)

The decider's schema and prompt (sends with their words), Return sending each message, Tab between unsure parts, a
click on a pending line, and the failure line for one send of several.
