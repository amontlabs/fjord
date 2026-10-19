# Round 2: cross-examination

## 1. Keep

**From Codex**
- *Freeze the plan before any effect; approval binds the exact version.* My round 1 had the card before sends but let the Fjord part be "a span run by Haiku"; Codex is right that a Fjord mutation is an effect too and must wait for Send with the rest. Adopt.
- *Recipient vs reference by position.* A pill in the strip or at a paragraph/line/sentence start addresses; a pill inline is a reference and stays text. This is the same distinction `Addressing.withoutLeadingPills` already draws for the message start (RouterPrepare.swift:369), made structural and general. It is cleaner than my "at a span start or after a connector" (the connector half was a word rule, see §3). Adopt.
- *Every clause assigned, shared or explicitly dropped; unassigned text blocks Send.* Better than my "unclear spans default to the most-labelled destination". Adopt.
- *Form answers and card judging on the part, not the whole message.* Correct reading of the code: `reply()` reads `job.text` for the form (RouterDispatcher.swift:797) and `judgeCards(message: job.text)` (RouterDispatcher.swift:862). Each part's `reply()` must get the part's body. Adopt.
- *`gate_you` is whole-message and can't veto a part.* Right. In the span call the Fjord options are plain choices per span; no `gate_you`.
- *Dependencies ("after CI passes, tell Docs…", "ask X and tell Y the answer") are not several sends.* Don't orchestrate; surface and hold. Adopt as one yes/no in the span call (§4).
- *`lastTold` must read the delivered body, not the submission* (RouterRoute.swift:538-547 reads `.you(text)`, the whole message). Adopt (already implied by `parts`).
- *The plugin acks an ordinary delivery before `submit` resolves* — verified: ClaudePlugin.swift:744-749, `void sending` unless it is an interrupt. True and worth a ticket, but it is transport, not this design.
- *First action: 30 real multi-recipient drafts, review proposed bodies before building delivery changes.* Yes; 11 compound episodes already exist in `evals/router/v2/data/episodes/dev/episodes.jsonl`.

**From Gemini**
- The parcel table with locked rows for parts you addressed, per-row Retry, and the `sentMessage` fix (RouterFork.swift:234-239 does refuse `links.sessions.count != 1`; parts with their own target and body fix it). Same shape as my card; keep.
- Reply chip as the default anchor for unaddressed text, pills anchoring their own clause: identical to my rule 2; agreement.
- Flagging "ask @api … and tell @web to use it" as needing @api's reply first, rather than sending both: good; folds into Codex's dependency hold.
- Hovering a live chip underlines its span: nice, later.

**From the prior session**
- Haiku answering with **word ranges over numbered words**, checked exactly, falling back to the card on any failure. This is the right tool for the one thing Jev cannot do (cut inside a sentence). Adopt as a bounded fallback (§4).
- "Confirmed at first; later previewed over the composer so sending is the confirmation." Adopt as the trajectory.

## 2. Drop

**Gemini**
- *Relay-verb stripping and the `ClauseSplitter` regex* (`/(?:tell|ask|have|in|for|on)\s+\S+/`): exactly the word rules your standing rule forbids, and the de-framing "tell CI to rerun → rerun" is interpretation of what the words mean. Drop. (The repo already has `spokenAddressee`/`addressee`/`notAddressees` in RouterMCP.swift:919-950; I would not add to them, and would not build splitting on them.)
- *Antecedent splice* ("it" → "the login timeout"): a model choosing a substitution is adding words at a position you didn't write them. It's bounded generation; the previous failure in miniature. Drop; share the antecedent's sentence instead (§3).
- *Send when every parcel ≥ 0.93*: the fusion's sureness is fitted on whole messages (RouterRoute.swift:380-422); it says nothing about a division being right. Drop for v1.
- *Fjord parcel executes immediately while a session parcel asks*: an effect before approval. Drop.
- *⌘-click "Directed" mode when ΔP > 0.5*: a hidden mode switch keyed on a probability. Drop; pins are recipients of unaddressed text, period; a compound message with pins goes through the span call restricted to the pins and shows the card.
- Code claims that are wrong: `RouterLiveTarget` is in RouterJev.swift:33, not Router.swift#938 (that is `Store.countCardChanges`); `RouterModel.restore` is RouterView.swift:475, not Router.swift#552; there is no `RelaySigner` in RouterPrepare.swift (signing is `RouterTools.signed`, RouterMCP.swift; `RelaySigner` appears only in ClaudePlugin.swift comments); `store.repliedToCard` does not exist; `withoutLeadingPills` is RouterPrepare.swift:369, not #120; the live debounce is 600 ms (RouterJev.swift:58), not 150; and the gate wording "False if all for sessions or all for Fjord" does not exist — `gate_compound` (RouterRoute.swift:51) says "different places (sessions or Fjord itself)" and `compound`'s criteria (RouterRoute.swift:34) names "two different sessions". So "a message for two sessions never triggers gate_compound" is false as written; if it under-fires that is calibration, measured, not a design gap.

**Codex**
- *Repair* (smallest generated edit, shown as a diff). Same objection as the splice: it is model-authored text under your signature, and the review is the only thing standing between it and a session. Your condition (1) "reads as mine" is met by dropping, not by editing. Hold: drop, never add; antecedents travel as shared spans.
- *Ask Jev whether the message is wholly for one recipient even when a reply or tag fixes it.* Today a single tag is a deterministic send with no Jev call (`plan` → `.route`, RouterDispatcher.swift:703-706). Adding a call to every tagged send trades latency on the fast path for catching "@CI rerun; also mute notifications". The `@router` aside already exists for the Fjord part of a tagged message. I'd keep tagged sends free of Jev. This is a product call (§4).
- *Opaque pointer markers in the decomposition input.* Right in spirit; Jev's per-span choice needs the destination names as options (that is how routing is measured), so apply it only to the Haiku range call, whose input is the sentence's own words and marker ids.

## 3. Where I change, where I hold

**Change.** My round 1 cut points included clause connectors (", and", " and then ", " — ") and reused the `abbreviations` list (RouterDispatcher.swift:759). Both are word rules. Revised: cuts are structural only — line breaks, bullets, sentence-ending punctuation followed by whitespace, code fences/indent/inline code (never inside), pills. An oversplit at "e.g." is harmless: both halves get the same label and merge. Anything inside a sentence is a model's answer (word ranges) or nothing.

**Change.** Fjord part: not run at labelling time. Shown on the card as the proposed change where the seam allows (`RouterFjord.commit`, RouterFjord.swift:294, holds a `FjordChange` with before/after; a dry-run mode is plausible but I haven't verified every tool can produce a patch without applying), else run on Send with its normal Revert card. Say which in the spec.

**Hold.** One history entry with `parts`, not child entries. Codex and Gemini agree; the prior session's `splitFrom` children make cancel/fork per child easy but split your one message across lines and need `inherited`/`generated` bookkeeping again.

**Hold.** A division the Router made is confirmed before anything is sent or changed, v1. Codex agrees; Gemini and the prior session want silent sends when sure. Wrong-send cost is ~25× an ask (RouterRoute.swift:414-418), compound is ~2% of messages, and no calibrated sureness for divisions exists yet.

**Hold.** Two adjacent recipient pills on one span = the same words to both. All three of us agree; the prior session's "two or more tags is always a split" is wrong for "@CI @Docs pull main".

## 4. Revised design, as deltas

- **D1 Segmentation.** Structure-only cuts (above). A recipient pill = in the strip (reply chip, pin, ⌘-click) or at a line/sentence start; it labels its span and following spans to the next recipient pill. Inline pills are references, text.
- **D2 Span call (Jev).** Per unaddressed span: `structuredChoice` over the existing destinations + `shared` + Fjord's two intents + `unclear`; plus per span one `noul` "is `part i` meant for more than one place?" and one whole-message `noul` "does a part depend on another part's result or on something happening first?".
- **D3 Intra-sentence cut (Haiku, bounded).** Only for a span the noul flags ≥ 0.75: one `claude -p` with `--json-schema`, input = that span's words numbered, destinations as opaque ids (no titles, no board), output = word ranges per id plus `shared` and `dropped`. Verified: in bounds, every word in exactly one of assigned/shared/dropped, non-empty parts. Any failure → the span stays whole on the card with its best label and a "cut this yourself" mark → Edit…. Dropping a word (a connector) is omission of your bytes; nothing is ever inserted.
- **D4 Card rules.** Every span assigned, shared or dropped before Send; a dependent part is marked "waits on …" with Hold (default) or Send anyway; the Fjord part is a row with its proposed change; parts you addressed are locked rows.
- **D5 Per-part execution.** `prepare(session, part: spans)` by indices into `turnText` (RouterMCP.swift, gate unchanged); `reply()` and `judgeCards` take the part's body; Fjord change applied on Send only; sends concurrent; outcomes per part; `lastTold`/`toldAll` over parts.
- **D6 Trajectory.** v1 confirms every division. Once "card right as proposed" ≥ 90% on the eval (build it from the 11 episodes + 30 collected drafts, per Codex), draw the division tinted over the composer while typing so Return is the confirmation — the prior session's step 2, earned not assumed.
- Everything else from round 1 stands: remove `Intent.compound`, `whole`/`Split…`, `fjordPartDone`, `splitFrom` (decode-only), the one-tag rule and the tagged-scope filter; keep the compound gates as the trigger and the `compound` route option until refit; inbox actions never segmented; checks (stop/archive) stay on the single path in v1.

**Product decisions for you, not technical ones**
1. **Words: drop-only, or drop plus a shown repair.** Codex and Gemini both want a bounded, reviewed rewrite (pronoun splice, "tell X to" removal). I say never: a session gets only bytes you typed, in order; pronouns are handled by sharing the sentence that holds the antecedent, and an awkward "tell docs to add the page" is the price. You wrote that the rule is open; this is the fork.
2. **Does a tagged or replied message still get asked whether all of it belongs there?** Codex: yes, always (one Jev call on every tagged send, catching a hidden Fjord or second-session part). Me: no — a tag is your decision, the aside is the tool for the rest, and the fast path stays model-free. Latency and trust versus a silent whole-message send when you forget a second tag.
3. (Smaller) **Fjord part on the card as a proposed patch vs applied on Send with Revert.** Depends on how much of `RouterFjord` can dry-run; I'd accept Revert-after for v1.

### Critical Files for Implementation
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterMCP.swift
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDecisions.swift
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterFjord.swift (commit seam for proposed-not-applied changes)