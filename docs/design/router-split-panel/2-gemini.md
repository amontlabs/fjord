Here is my Round 2 cross-examination, code verification, and delta design.

---

## 1. What I’d Keep from the Others (and Why)

### From Advisor Fable
- **Routing via Jev’s multi-question batching (“the span call”), not Haiku:** [`JevClient.ask`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/Jev.swift#L85-L90) bills only for input and answers multiple `structuredChoice` questions (`part0`, `part1`, …) over a single `state` in ~250ms. Adding `shared` (*“context every part needs: a fact, a deadline, a constraint; not a request”*) and `fjord` to the existing [`destinations`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift#L121-L148) criteria in one Jev call is faster, cheaper, and strictly classification-only.
- **Passing span indices—never strings—into [`RouterTools.prepare`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterMCP.swift#L1227-L1241):** Having `RouterTools` reconstruct each part’s bytes directly from `turnText` + span indices, run [`Addressing.edit`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift#L356-L364) on that slice, and attach [`RouterPointers.attach`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterMCP.swift#L1172) **only for `@notification` / `@category` mentions inside that part’s ranges** preserves the [`approveSend`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterMCP.swift#L1245-L1270) `sameBytes` invariant by construction.
- **`Edit…` on the split card restores the draft with `@session` pills inserted at Jev’s proposed cut points:** Reusing [`RouterModel.restore`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/Router.swift#L552-L561) + [`MentionText.restoring`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPointer.swift#L533-L553) to materialize Jev’s split as real `@` pills in the composer is brilliant: if you tweak a pronoun and hit Return, the resend hits the deterministic tagged path and flies without asking again.
- **Per-part `lastTold` / `toldAll` ([`RouterDecisions.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDecisions.swift#L430-L478)) and per-part [`RouterRun.run`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRun.swift#L67-L164) input:** Recording only the part’s body in `lastTold` (which feeds Jev’s `next` check and BM25 `f_you` in [`RouterRoute.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift#L216-L260)) and passing only `fjord`-labeled spans into Haiku’s `changeFjord`/`question` run prevents cross-contamination.

### From Advisor Codex
- **Per-part card/form resolution in [`RouterDispatcher.reply`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift#L793-L864):** Today `reply` passes `said` (the whole message) into [`planDecision`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift#L807) / [`formAnswers`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift#L823) / [`askFormAnswers`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift#L826), and passes `job.text` into [`store.judgeCards`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift#L862). In a split, each session’s form/card check must read **only that session’s part**, or a sibling’s words will corrupt form matching or prematurely clear open turn cards.
- **Recipient vs. Reference distinction for `@` pills:** An `@session` pill at the start of a span (or after a structural boundary) addresses that span; an `@session` pill mid-clause (*“@docs check if @ci’s change affects the guide”*) is a reference, not a second recipient. Note that [`Addressing.withoutLeadingPills`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift#L369-L391) already enforces this at message start; generalizing it to span starts is completely natural.
- **Even with a reply chip armed, ask Jev whether the whole message is for one place:** Arming `replyTo` sets the default label for unaddressed spans, but should not blind the Router when you type two sentences meant for two places (*“Yes use SQLite. Also mute notifications for an hour.”*).

### From Prior Thinking
- **Word-index ranges over numbered tokens if an LLM ever proposes cuts:** Models miscount UTF-8/character offsets, whereas selecting word indices `w[i..j]` over tokenized words is trivial to validate and maps 1-to-1 back to `Range<String.Index>`.

---

## 2. What I’d Drop from Each (and Where Their Code Claims Are Wrong)

### Drop from Advisor Codex
1. **Mandatory pre-send review modal for *every* multi-recipient message, including explicitly tagged ones (`@CI rerun; @Docs add page`):**
   - *Why drop:* If you explicitly wrote `@CI ...` and `@Docs ...`, stopping to show a review panel adds friction to the most unambiguous path in the app. When every span’s target is fixed by your own tags/pins, it should fly immediately.
2. **A separate LLM “decomposition pass” + “repair drafts” that rewrite `"it"` → `"the migration"`:**
   - *Why drop:* First, adding an LLM call before Jev adds 1–2s latency to every message. Second, model-proposed wording repairs violate the byte-identity invariant and re-introduce the exact failure mode of `e2b3a47`.
3. **Dry-run staging of Fjord tool mutations (`FjordChange` patches before execution):**
   - *Code error:* Codex cites `RouterFjord.commit` at [`RouterFjord.swift:295`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterFjord.swift#L295) (it is actually `RouterTools.commit(_:_:reason:apply:)`). More importantly, `commit` is called *inside* live MCP tool handlers ([`saveCategory`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterFjord.swift#L342), [`markEntries`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterFjord.swift#L143), [`setSetting`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterFjord.swift#L145)) during a `claude -p` Haiku run, and [`FjordGate.reason`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterFjord.swift#L298) **already** holds consequential changes in `change.pending` with Apply/Discard buttons while applying safe changes with a Revert button. Building a second pre-run patch-staging layer duplicates `FjordGate`.
4. **Claim that [`ClaudePlugin.swift:743`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/ClaudePlugin.swift#L743-L749) (`else void sending`) is a bug to “fix upstream”:**
   - *Code error:* In [`accept`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/ClaudePlugin.swift#L744-L749), `submit($, signed.nonce, body)` wraps `$.prompt.submit({ text: body, asUser: true })`. When `apply == false` (line 814, inside the `session.receive` hook) or when a turn is currently running (`!signed.interrupt`), `$.prompt.submit` queues behind the active turn or hook. Awaiting `sending` before writing the `.ack` file in [`poll`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/ClaudePlugin.swift#L793-L794) would stall the inbox for up to `POLL_STUCK_MS` (5s) or until the running turn finishes! That `else void sending` is deliberate, and `startedBy` in [`turn.start`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/ClaudePlugin.swift#L831-L846) tracks when the queued prompt actually begins a turn.
5. **Mischaracterizing [`RouterDepends.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDepends.swift#L1-L100):**
   - *Code error:* Codex cites `RouterDepends` as a composer routing mechanism. In fact, `RouterDepends` runs in `RouterTriage` on *a session’s completed turn output* (`Store.dependsExtra` at [`RouterDepends.swift:90`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDepends.swift#L90)) to mark a session card as `.waiting` on another running session.

### Drop from Advisor Fable
1. **Unaddressed spans after an inline `@pill` automatically inheriting the pill’s “address scope” across later sentences:**
   - *Why drop:* Fable says a pill labels every following sentence up to the next pill. That works for `"@CI pull main. Run the tests. @docs update the guide"`, **but breaks** when you write a leading tag followed by an untagged switch of topic: `"@CI rerun the flaky job. Also mute notifications for an hour."` or `"@CI rerun the flaky job. And tell docs to add the page."` If `@CI` blindly scopes the rest of the message, rule 3 (“All spans labelled by you → send now, no Jev”) will silently send `"Also mute notifications for an hour"` to `CI` without ever asking Jev!
   - *Fix:* Even when pills or `replyTo` cover the message, run the fast Jev check (or check `gate_compound` / per-span Jev) whenever there is >1 sentence/clause, or only let a pill scope the clause/sentence it leads unless Jev agrees the following unaddressed sentence is for the same target.
2. **Not updating [`RouterFeed.fjordSent`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/Router.swift#L793-L803):**
   - *Code gap:* Both Fable and Codex noticed `entry.delivered` in `RouterDecision`, but missed [`RouterFeed.fjordSent`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/Router.swift#L796-L802), which checks `entry.delivered` to distinguish Fjord-sent messages from messages you typed directly in the Claude app. If `fjordSent` isn’t updated to iterate `entry.parts`, multi-part deliveries will be misread by `RouterFeed` as manual replies in Claude Desktop.
3. **Dropping `RouterActionChecks` (stop/interrupt/archive) completely on divided messages:**
   - *Why drop:* If you write `"stop @CI, and @docs add the page"`, or if one of the parts in a split targets a running session where you want `"Stop and send this"` ([`.interrupt`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift#L1710)), per-part interrupt/say options on the split card already exist in [`typedOption`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift#L1696-L1738) and should work.

### Drop from Prior Thinking
- **Creating separate child `RouterDecision` rows (`splitFrom`):** Having 1 message spawn $N$ top-level history rows cluttered the log in `e2b3a47`. One `RouterDecision` containing `parts: [Part]` is strictly cleaner.

---

## 3. Where I Change My Design vs. Where I Hold My Ground

### What I Change in My Design (Applying Your Standing Rule + Best of Fable/Codex)
1. **Drop all word rules, regex clause splitters, relay-verb stripping (`"tell X to"`), and pronoun splicing.**
   - My Round 1 design proposed stripping relay prefixes (`"tell CI to "`) and splicing antecedent noun phrases for pronouns. **I drop both completely.** They violate your standing rule (*“No word rules: Fjord never interprets a message with regexes or word lists”*) and violate spec B.1 (*“Anything else, `tell <the session> to …` included, goes as you wrote it”*).
   - Every part is now strictly **ordered spans of your exact bytes**, cut only at structural boundaries you made (newlines, bullets, sentence ends, punctuation/connector boundaries, and `@` address pills), with only leading `@` address pills and `@router` asides removed by [`Addressing`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift#L348-L540).
2. **Drop Haiku as the slicer; use Fable’s single-call Jev span classification.**
   - Instead of calling Haiku to return character offsets, [`Segmenter`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift) cuts candidate spans deterministically on structure, and **one Jev call** ([`JevClient.ask`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/Jev.swift#L85)) classifies each span over `destinations + [shared, fjord, unclear]`.
3. **Adopt Fable’s inline tinted Split Card + `Edit…` pill insertion** instead of my Round 1 table editor. Showing your message as written with tinted spans, a target chip per span, and `Edit…` (which restores the text to the composer with `@` pills inserted at the cuts) is much faster to scan and avoids turning the ask card into a second text editor.

### Where I Hold My Ground
1. **Against Codex (Fast path for explicit multi-tag / reply+tag):** When you explicitly tag the parts (`@CI rerun the job. @docs add the page.` or armed `replyTo` + `yes. @docs add the page`), and Jev does not flag an unaddressed span as switching targets, **send immediately without a review card**. Requiring a confirmation click when you already typed explicit `@` pills punishes the fastest workflow.
2. **Against Fable (Don’t let a leading pill blind the Router on multi-sentence messages):** Fable skips Jev completely whenever a message starts with a pill or has `replyTo` armed (`"All spans labelled by you → send each part now, no Jev"`). That recreates today’s bug whenever you start with `@CI` (or a reply chip) and add a second sentence for Fjord or another session without a tag (`"@CI looks good. Turn off notifications."`). **Hold:** A pill or `replyTo` fixes the label of the span it *starts* (and acts as the default), but if there are subsequent unaddressed spans, Jev’s fast call still checks whether any unaddressed span is `fjord`, `shared`, or another session.
3. **Against Fable on ⌘-clicking on Brief:** Fable didn’t design ⌘-clicking on Brief ([`RouterDigest.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDigest.swift)). I hold my ground (aligned with Codex) on adding `pinnedTargets` to `RouterModel` so ⌘-clicking Brief spans adds target chips above the composer without opening the peek card.

---

## 4. Revised Design (Deltas Against Round 1)

### Delta 1: Structural Segmentation Only (`Segmenter` in [`RouterPrepare.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift))
- Replace Round 1’s `ClauseSplitter` and `SpanSlice` with a pure structural `Segmenter.spans(text:mentions:) -> [Span]` outside [`Addressing.codeMask`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift#L422) and [`quoteMask`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift#L467):
  - **Hard cuts:** line breaks, bullet lines, `@router` asides ([`Addressing.asides`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift#L489)), sentence boundaries (`.?!` + whitespace, respecting [`abbreviations`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift#L759)), and any `@session`/`@project` pill ([`RouterPointer.addresses`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPointer.swift#L22)) standing at the start of a span or immediately after punctuation/conjunction (`,`, `;`, `—`, `and`, `then`). Mid-clause pills (`"ask @CI about it"`) stay inside the span as text.
  - **Candidate sub-cuts:** coordinating connectors (`, and `, `; `, ` — `, ` and `) inside a single untagged sentence are kept as candidate split points that only activate if Jev assigns the two halves to different destinations with high margin ($\ge 0.7$ each, margin $\ge 0.3$ over whole-sentence). When cut, only the connector bytes between the two spans are omitted; every word inside each span is untouched.

### Delta 2: Decision Order & The Single Jev Span Call ([`RouterDispatcher.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift), [`RouterRoute.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift))
1. **Explicitly addressed spans (`@CI do X. @docs do Y.`, or `@CI @docs do X`):**
   - Adjacent leading pills (`@CI @docs pull main`) label that span for **both** targets.
   - If *every* span has its own explicit `@` pill (or `replyTo` on a single-span reply), dispatch all parts concurrently right now—no Jev call, no ask card.
2. **Messages with unaddressed spans (no tags, preface before first tag, or trailing unaddressed sentences after a tag/`replyTo`):**
   - Run the normal Jev routing call. If `gate_compound` fires ($\ge 0.75$ and `gate_compound2` $\ge 0.5$) **or** the message has both addressed and unaddressed spans:
   - Run the **Jev span call**: one [`JevClient.ask`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/Jev.swift#L85) passing `parts: [{i, text}]` and asking one `structuredChoice` per unaddressed span over `destinations + [shared, fjord, unclear]`.
   - Merge adjacent spans with the same destination; prepend `shared` spans (in original byte order) to every session part; route `fjord` spans to `RouterRun` (passing only the `fjord` spans’ bytes).

### Delta 3: The Split Card & Composer Restore ([`RouterPage.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPage.swift), [`RouterPointer.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPointer.swift))
- Whenever Jev divides a message (any span wasn’t explicitly tagged by you), show **one Split Card** before executing any part (including any `fjord` part, so a misread never mutates settings prematurely):
  - Displays your message with each span tinted and a clickable destination chip (`CI`, `docs`, `Change Fjord`, `Context for all`, `Nowhere`).
  - **Send** dispatches all parts concurrently.
  - **Edit…** puts the message back into the composer via [`MentionText.restoring`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPointer.swift#L533-L553) with `@session`/`@project` pills inserted at the start of each session span so you can fix a dangling pronoun (`"it"`) and hit Return to send deterministically.

### Delta 4: Gate Enforcement & Plumbing ([`RouterMCP.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterMCP.swift), [`Router.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/Router.swift), [`RouterDecisions.swift`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDecisions.swift))
- `RouterTools.prepare` takes `PartSpec` (`spans: [Range<Int>]`), slices `turnText` directly, strips leading pills/asides via [`Addressing.edit`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPrepare.swift#L356), attaches notification/category blocks only for mentions overlapping `spans`, and keys `prepared[to]` by target so [`approveSend`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterMCP.swift#L1245) stays byte-exact.
- Update [`RouterDispatcher.reply`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift#L793-L864) (`formAnswers`, `planDecision`, `judgeCards`), [`RouterFeed.fjordSent`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/Router.swift#L793-L803), [`lastTold`/`toldAll`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDecisions.swift#L430-L478), and [`sentMessage`](file:///Users/polarzero/code/projects/lookout/Sources/Fjord/RouterFork.swift#L234) to read per-part (`entry.parts`), never the whole message.

---

## 5. Two Real Product Decisions for You (Not Technical Ones)

1. **What does a mid-message `@pill` scope when another sentence follows it?**
   - Suppose you write: `"@CI rerun the flaky build. Check the logs for timeouts. @docs add the page."`
   - Here, `"Check the logs for timeouts."` has no pill.
   - **Option A (Strict Pill Scope — Fable):** Every `@pill` automatically scopes all following sentences until the next `@pill`. If you started the message with `@CI`, the whole thing sends immediately with zero confirmation. Fast, but if your second sentence was meant for Fjord (`"@CI rerun the build. Mute notifications for an hour."`), it silently goes to `CI`.
   - **Option B (Guardrailed Scope — My recommendation):** A pill scopes following sentences by default, *except* we still check `gate_compound` / Jev when unaddressed sentences follow a pill; if Jev sees a target switch (like a Fjord command or another session), it pops the Split Card instead of blindly sending to `@CI`.

2. **When you write `"tell CI to rerun and tell docs to add the page"` without `@` pills, should `"tell CI to "` stay in the text sent to CI?**
   - Under your **No Word Rules** principle and current spec B.1, `"tell CI to rerun"` is sent verbatim to `CI`. Claude Code understands `"tell CI to rerun"` fine in practice, and `Edit…` lets you trim it if you care.
   - If seeing `"tell CI to …"` land in `CI`’s transcript bothers you, the *only* non-regex way to remove it is to let a model propose a word-drop span and require your click on the Split Card (Codex’s approach). My advice: **keep B.1 verbatim**—never let a model trim prose inside a span, and let `@CI rerun` be the clean syntax when you want clean bytes.
