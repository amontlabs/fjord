# Design: one message, many places — routing spans, not messages

## 1. Reframe

The problem is framed as "how do we split a message". The failure of commit cc3b8b95/e2b3a477 was not splitting; it was letting a model *write* the parts (`leftover`, "each a self-contained message written as the user would write it"). The fix is to notice that the Router already does a deterministic, byte-preserving edit of your message: `Addressing.edit` (`/Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift`) removes leading `@project` pills and `@router` asides and sends the rest verbatim. Splitting is the same operation generalised: **a message is a sequence of spans of your own bytes, cut at boundaries you already made (line breaks, bullets, sentence ends, address pills). Routing labels spans with destinations. A destination's part is the concatenation, in order, of the spans labelled for it; nothing is added, reordered or reworded.** The Router may choose *which* bytes go *where*; it may never produce bytes. That one invariant replaces the whole-message-one-destination model, and the current behaviour is the special case where every span carries the same label.

Consequences that fall out for free: Fjord's parts are never forwarded (they are spans labelled `fjord`, absent from every session's part); multiple tags work (each pill opens its own scope); the message reads as yours (every byte a session gets you typed, in your order); Cancel/send-elsewhere/edit-and-resend/fork keep working, per part.

Scale check: compound messages are ~2% of real moments (11 of 575 dev episodes labelled `compound` in `evals/router/v2/data/episodes/dev/episodes.jsonl`). The design must leave the 98% path untouched, so everything below is triggered only by the existing compound gates or by multiple address pills.

## 2. Segmentation (deterministic, no model)

`Segmenter.spans(text, pills) -> [Span]`, pure, next to `Addressing` in RouterPrepare.swift. Cut points, in the message's own words only (`codeMask`/`quoteMask` already exist; code, quotes and indented blocks are never cut inside):
- line breaks and bullet starts;
- sentence ends (`.?!` + whitespace, the `abbreviations` list from `RouterDispatcher.title(for:)`);
- an **address pill** (`RouterPointer.addresses`: project or session) standing at a span start or right after a connector (`,`/`;`/`—`/" and "/" then "). A pill glued mid-sentence ("ask @CI about it") is text, exactly as `withoutLeadingPills` treats non-leading pills today.
- Clause connectors (", and", "; ", " and then ", " — ") are *optional* cut points: a sentence is one span unless Jev labels its two halves differently with a clear margin (section 4). The connector itself is omitted from both parts (omission of your bytes, never substitution). This covers your example "tell CI to rerun and tell docs to add the page".

A pill opens an **address scope**: it labels its own span and every following span up to the next address pill. Two adjacent pills ("@CI @docs pull main") label the scope for both: the same words go to both (that is what you wrote; it's the literal reading, not a copy of "everything").

Spans before the first address pill (the preface) and spans with no pill are **unaddressed**. What happens to them is section 3/4.

## 3. Deciding, in order (replaces `RouterDispatcher.plan` + `classifyAndAct` for typed messages)

Rule: **a span goes without asking only when its address is yours.** Yours = a pill scope, the reply chip, a pinned target, or (unchanged from today) a one-destination message the fused verdict is sure of.

1. **Segment.** Spans + pill scopes. `@router` asides stay exactly as today, read as spans labelled `fjord` (same syntax, same `Addressing.asides`; `forRouter` becomes "every span is `fjord`").
2. **Default label.** A reply chip (`RouterContext.replyTo`) or pinned target (`context.target`) is the default label for every unaddressed span. So "SQLite. @docs add the page" with a reply armed on a CI card → "SQLite" answers the card (form path in `reply()`, `formAnswers`), "add the page" goes to docs. Today `plan()` sends the whole thing to the card; that case changes.
3. **All spans labelled by you** (every span has a pill scope or the default) → send each part now, no Jev, no card. Trace path `tagged`. This is today's single-tag `.route` generalised; the `tagged.count == 1` special case in `plan()` goes.
4. **No pills, no default** → exactly today's path (`classifyAndAct`, fusion, checks, live prediction), unchanged, *except* what happens when the verdict is `compound` (the gates `gate_compound ≥ 0.75` and `gate_compound2 ≥ 0.5` in `RouterTools.verdict`, RouterRoute.swift): instead of `think(job, .compound)`, run the **span call** (section 4) and show the **split card** (section 5). Also run the span call when `gate_compound ≥ 0.6` and the route asks anyway: it is a cheap second opinion, and if it labels every span the same, the normal ask card shows as today.
5. **Some spans yours, some not** (a preface before the first pill, "Fix the tests. @docs add the page") → span call for the unaddressed spans only, options limited to: each tagged destination, "context for every part", Fjord (change/question), plus the usual destinations; then the split card. The addressed spans are shown already fixed on the card. Nothing is sent before you confirm, because the Router divided it.

Inbox actions (`context.action != nil`) are never segmented: one message, sessions only, as today.

## 4. The span call (Jev, one call, classification only)

Jev offers `choice`/`noul`/`score` (`/Users/polarzero/code/projects/lookout/Sources/Fjord/Jev.swift`), no generation, which is exactly right. Build on `RouterTools.routingQuestions`: the state is `{message, tagged}` as today (redacted), plus `parts: [ {i, text} ]`; one `structuredChoice` per unaddressed span, options = today's `destinations(...)` (same names and criteria, so the measured option wording is reused) + `shared` ("context every part needs: a fact, a deadline, a constraint; not a request") + `fjord` (the `change_fjord`/`question` criteria) + `unclear`. Instruction: "Which destination is `part i` of `message` meant for? Decide the part alone; `message` says what it refers to." All questions ship in one request (several per call is how routing already works; only input is billed). Clause-level cuts: ask the two halves of a sentence as extra spans only when the sentence holds a connector; cut only if both halves are ≥ 0.7 to different destinations and the margin over the sentence-as-one-span is ≥ 0.3; else the sentence stays whole and takes the sentence's label. Adjacent spans with the same label merge into one part. `shared` spans are prepended (in order) to every session part; they never form a part alone. `unclear` spans default to the most-labelled destination on the card, flagged.

No fusion for parts: the fusion (`RouteFusion`) is fitted on whole messages and compound moments are too few to refit. Since a Jev-divided message is always confirmed (section 3), per-span accuracy only changes how often the card is right as proposed (one click), never where words land. Measure that: extend `evals/router` with span gold on the 11 real compound episodes + written cases (mark the cut points and labels), metric "card right as proposed".

Keep the route question's options as they are (including `compound`) so `RouteFusion.weights` stay valid (`af480a6b` kept fitted texts for the same reason); the dispatcher just stops treating `compound` as a Haiku intent. Refit later without the option.

## 5. What you see: the split card

One card under the message (where today's ask unfolds, `RouterFlights`), never one card per part (the removed feature's five-cards problem). It shows your message as written, each span on a tint, a destination chip at each part's start (same words as `RouterDispatcher.option`: session title, "New session in lcu", "Change Fjord", "Answer from what Fjord knows", "Context for all"). Click a chip → menu of the same options (`pickerOptions` + Fjord + shared), or "Nowhere" (drop that span). Buttons: **Send** (every part at once), **Edit…**, Dismiss. Edit… puts the message back in the composer *with address pills inserted at the cut points Jev chose* (reuse `RouterModel.restore` + `MentionText.restoring`): you tidy a pronoun or move a sentence, press Return, and the resend is deterministic (rule 3), no card. Jev's proposal becomes tags you can see; your correction is logged as a correction, as ask picks are today.

For a running destination the chip says "· after its turn" (`typedOption(.say)`) and its menu offers "Stop and send this" (`.interrupt`). The checks call (`RouterActionChecks`, archive/stop) is not run for a divided message in v1; it stays on the single-destination path. A part that is a `fjord` span runs Haiku with **only those spans** as "the user's message" (`routerRunContext(message:)`), intent `changeFjord` or `question` by the span's label; `compoundRole` and its "say the rest is for a session" dance go.

Live prediction while typing: when the draft reads compound, the chip says "Several places" and nothing is marked on the page; the card comes on send. No live tinting (not worth the churn).

## 6. Delivery and the gate

`RouterTools` (RouterMCP.swift) holds `turnText`; `prepare` derives `Prepared` from it via `Addressing.edit`, and `approveSend` demands `sameBytes(ready.text, message)`. Generalise without weakening: `prepare(session, part: PartSpec)` where `PartSpec` is **span indices into the turn's segmentation**, never a string. `RouterTools` rebuilds the part's bytes itself from `turnText` + indices (then `Addressing.edit` for pills/asides inside it, then `RouterPointers.attach` for the notification/category blocks of pills *inside that part only*). No caller, test fake or run can hand the gate text it didn't cut from your bytes. `approveSend` is unchanged. Each part is a separate signed delivery (`RelayInbox` nonce each), sent concurrently; the plugin needs nothing new. A new-session part goes through `startSession` with `SessionStart.task` on the part's bytes.

## 7. History and the record

Keep one entry per message (the envelope: `trigger: .you(text)`, `mentions`), add `parts: [Part]` to `RouterDecision` (RouterDecisions.swift): `Part { spans: [Range<Int>], target, targetID, label, done: [Done], delivered: Delivered?, outcome }`. Every message has ≥ 1 part (today's messages: one part covering everything), so the model is uniform. `summary` reads "sent to CI, docs · changed Fjord"; the expanded line draws the message with the same tints as the card, one row per part with its own Cancel, Send elsewhere, Edit and resend, Fork from before (all today's per-entry operations become per-part; `sendElsewhere`'s `whole` branch goes). `lastTold`/`toldAll` iterate parts and record the part's body, not the whole message (what Jev reads as "the user last told it" must be what the session actually got). Flights: one pill rises, and on decision fans into N pills landing on N rows. Keep `Done.sent`, `delivered`, `splitFrom`, `fjordPartDone`, `inherited`, `generated` as decode-only for old files; write only `parts`.

## 8. Cases

- `@CI rerun the flaky job. @docs add the page.` → two parts, sent, no card. Pills removed as leading pills are today.
- `@CI @docs pull main` → both get "pull main".
- `tell CI to rerun and tell docs to add the page` (no tags) → gate fires → span call → card: "tell CI to rerun" → CI, "tell docs to add the page" → docs → Send. Each session sees the "tell X to" verbatim, as spec B.1 decided today ("tell <session> to …" is sent verbatim). Acceptable; a follow-up could strip a leading "tell X to " when `addressee()` resolves to the part's own destination, but that is a change of B.1, not of this design.
- `Deploy is at 5. @CI rerun before then. @docs mention the time.` → preface unaddressed → Jev: `shared` → card shows it tinted "all" → both parts start with "Deploy is at 5."
- `@CI rerun the job. @docs document it.` → "it" dangles for docs. No fix without rewording; the card shows docs' part, you press Edit… or accept. State this limit plainly in the spec.
- Reply chip on CI's question + `yes. @docs add the page` → "yes." answers the card (form path), rest to docs, no card.
- `turn off Jev labels and tell the CI one to rerun` → `turn off Jev labels` → fjord (change run gets only that), rest → CI. Card first.
- `update the category and tell CI to rerun the flaky job` (today's test) → same shape; the Fjord part runs only after you confirm the card, so a wrong read never changes settings.
- Span call fails/no key → today's ask card with the whole message plus Edit… (no Haiku compound run). A part's delivery fails → its row says why with Retry, others unaffected. Stop → `endTurn` ends all parts; each delivery still passes `live(ticket)`. Fjord quit mid-way → `settleInterrupted` marks unsent parts.

## 9. Remove

`RouterRun.Intent.compound`, `RouterCapability.compoundRole`/`available(.compound)`; `RouterAskBack.whole`/`split`, `splitRequest`, `RouterDispatcher.split`, the compound tail of `think()`, `fjordPartDone` logic in `sendElsewhere`; `plan()`'s one-tag rule and the "several tagged → Jev picks among them" scope filter in `classifyAndAct` (scope narrowing stays for the single path); the compound tests in RouterDispatcherTests/RouterCancelTests. Keep the compound gates (they are the trigger) and the `compound` route option until refit.

## 10. Trade-offs and doubts

- A Jev-divided message always asks. That is one more click on ~2% of messages, bought with "a wrong split can never send". If the card is right as proposed ≥ 90% in evals, consider sending silently when every span is ≥ 0.9 to its label; I would not do it in v1.
- Clause cuts inside a sentence are the only place where the output can read oddly (a dropped "and"). The card shows it; the margin rule keeps it rare. If evals show it misfires, restrict cuts to sentence/line boundaries.
- Unsure whether Jev's per-span choice with ~85 options degrades with many spans in one call; cap at 8 spans (longer messages: the compound gate is already unreliable on long text, `ilong` weight), beyond which the card shows the whole message with Edit… only.
- Broadcasting one scope to two adjacent pills could surprise someone who meant a split; the history shows two identical parts, so it is visible, and Edit… fixes it.

### Critical Files for Implementation
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift (plan/classifyAndAct/think/route/askBack: the decision order, the split card, per-part runs)
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift (Addressing → Segmenter: spans, pill scopes, clause cuts; byte-only edits)
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterMCP.swift (RouterTools.prepare/approveSend/startSession: parts as span indices into turnText, blocks attached per part)
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift (the span call built on routingQuestions/destinations; the compound verdict's new meaning)
- /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDecisions.swift (RouterDecision.parts, per-part Delivered/Done, lastTold/toldAll over parts)
- /Users/polarzero/code/projects/lookout/docs/design/spec/router.md (B.1–B.3 rewritten around spans; the invariant stated once)