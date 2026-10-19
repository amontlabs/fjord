## Prior thinking

An earlier session proposed the following. Treat it as one more opinion, not a baseline.
- A split creates ordinary child messages, one destination each, linked to the original (`RouterDecision.splitFrom` is a leftover from the old split). That way cancel, send elsewhere and fork keep working per child.
- Each child is my message with the words not meant for it removed. A model may drop words, never add them. Shared context, or the words a pronoun refers to, can go to several children.
- Two or more tags is always a split: deterministic from tag to tag when each tag starts its own sentence or line, otherwise one Haiku call. Without tags, a split only when Jev says the message asks for several places, not on every message.
- Haiku answers with word ranges per destination over the numbered words, rather than character offsets, which models count badly. The app checks the answer exactly and falls back to the ask card on any failure.
- Splits are confirmed by me at first. Later, the split is previewed over the composer, so sending is the confirmation.
- Remove the current compound path and its "whole or split" card.

## A standing rule of mine you may not know

No word rules: Fjord never interprets a message with regexes or word lists (relay verbs like "tell X to", keyword triggers and so on). Interpretation is a measured classifier (Jev) or an explicit button. Fixed rules on structure I made (a pill's position, a line break, code fences) are fine; rules on what my words mean are not.
