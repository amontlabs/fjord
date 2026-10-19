**Make one submission a dispatch plan with several independently tracked deliveries. Preserve your wording by default; require approval of the exact recipient messages whenever Fjord divides or repairs it.**

The wrong invariant is “one message, one destination.” Keep “one message, one history entry,” but let that entry contain several deliveries and Fjord actions. Decide the whole plan before executing any part. This keeps the Router a dispatcher: it prepares a concrete send, resolves ambiguity, commits it, and records the results. It does not become a conversation or a coordinator among agents.

**1. Change the unit of decision**

A plan contains:

- The original message, immutable, with its typed pointers and reply context.
- Parts of that message, including shared context and constraints.
- Operations: send to an existing session, start a session, answer a particular card, change Fjord, or answer locally.
- Anything unresolved, with the specific choice needed from you.

Several parts for one session normally become one delivery. A shared instruction can belong to several deliveries. Fjord-only parts belong to none of the session deliveries.

Today, [`RouterDispatcher.plan`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift:686) returns a single action; an armed reply wins before session tags are considered. [`think`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift:1170) executes a compound request’s Fjord portion, then offers the entire message to one session. Both behaviors must disappear. Multiplicity belongs in the plan, before effects, rather than in an exceptional “compound” execution path.

**2. Give addressing one consistent meaning**

Addressing supplies recipients and scope. It does not authorize sending unrelated clauses to those recipients.

Use the same underlying recipient representation for leading @ tags, the reply chip, and ⌘-selected Brief items. Store how each recipient was chosen, but do not give the three mechanisms competing precedence rules.

Distinguish two roles for pointers:

- **Recipient:** a chip above the composer or a prefix at the start of a paragraph.
- **Reference:** an inline pointer inside the prose.

Thus, `@CI @Docs` before a message means both are intended recipients. “Ask @Docs whether @CI’s change affects the guide” references CI without necessarily addressing it. Prefixes on separate paragraphs scope those paragraphs; the reply chip supplies the default for otherwise unaddressed text.

[`RouterMention`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterPointer.swift:64) already preserves identity and position. Extend that representation with addressing role and scope. Do not infer identity from a session’s displayed name. Keep the existing protection against titles accidentally consuming the user’s words.

Explicit recipients constrain the plan:

- Account for every selected recipient. Do not silently pick one or discard the others.
- Do not add another session outside that set without showing it as a proposed addition.
- Fjord may still receive clauses explicitly meant for Fjord.
- Selecting a project scopes destination resolution within that project. It does not broadcast to every session there.
- “New session” remains an explicit operation, with project, model, and effort shown.

A reply chip plus a tag pointing to the same session deduplicates to one recipient while retaining the card link. Different sessions produce a plan involving both. A reference to another session produces no additional delivery.

On the Brief, ⌘-click toggles recipient selection without opening or replying to that item. Show those selections above the composer. Today the Brief principally tracks one hovered and one open item in [`RouterDigestState`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDigest.swift:300); recipient selection should be separate from those presentation states.

**3. Separate understanding the message from finding its destinations**

Keep Jev’s proven single-destination routing. Do not replace it with “Haiku decides everything.”

Use this sequence:

1. Parse explicit addressing without effects.
2. Ask whether the message belongs wholly to one recipient or contains work for different recipients. Ask this even when a reply or tag fixes a default recipient.
3. For an ordinary single-recipient message, retain the existing routing and delivery path.
4. For multiple recipients, or uncertainty about whether the message needs dividing, build a tool-free proposed plan.
5. Resolve its recipients and validate the entire plan before review.

This removes the current blind spot where deterministic addressing bypasses the question of whether *all* the text belongs there.

The decomposition step should read **the user’s message and structural addressing metadata only**. Replace pill labels with opaque pointer markers in its input: a session title is external text even when displayed inside the composer.

Destination resolution may read the board, transcript evidence, and Jev scores. It returns destination IDs and evidence for the choice, not replacement prose. The component that writes recipient messages does not read transcripts, PR descriptions, or session titles.

That boundary directly addresses the authority problem: external material cannot become newly authored instructions through the wording step.

For untagged messages, reuse Jev and lexical evidence to propose destinations. Do not treat today’s calibrated confidence as confidence in the entire split. [`RouterRoute.swift`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift:31) models mutually exclusive destinations; correct partitioning is a different task. Its whole-message `gate_you` also needs to become local to a part: “you” in one clause cannot veto Fjord work in another.

The repository’s [routing research]( /Users/polarzero/code/projects/lookout/docs/design/router-research.md) already documents that Haiku was confidently wrong on ambiguous real routing cases. Use it to construct a reviewable proposal, not to bypass an uncertain destination.

**4. Extract first; allow narrowly repaired drafts**

I would change the current wording rule to:

> Automatic deliveries contain the user’s words with deterministic addressing edits. Generated wording is a draft until the user approves the exact recipient message.

A blanket prohibition on changed wording cannot satisfy arbitrary natural-language splitting. “Tell CI to fix the migration and Docs to document it” needs either context carried across the split or a repair to “it.” Conversely, unrestricted “write a self-contained message in my style” repeats the failed experiment.

Use three operations:

- **Extract:** preserve complete clauses and paragraphs verbatim.
- **Share:** include relevant user-written context or constraints in more than one delivery.
- **Repair:** propose the smallest edit needed to remove delegation scaffolding or resolve a reference from the user’s own message.

No summarizing, polishing, strengthening, or adding implementation advice. No tone imitation. Code, commands, paths, quoted material, negation, conditions, and quantities stay intact.

For example:

> For the release candidate, don’t deploy anything. Tell CI to rerun the failed jobs and tell Docs to add the migration page. Fjord, mute notifications for an hour.

The proposed messages are:

| Destination | Receives |
|---|---|
| CI | “For the release candidate, don’t deploy anything. rerun the failed jobs” |
| Docs | “For the release candidate, don’t deploy anything. add the migration page” |
| Fjord | Notifications muted for one hour |

The lower-case fragments are acceptable. Capitalization is not worth a rewrite. The shared constraint is essential; the unrelated task and Fjord instruction are absent.

For “Tell CI to fix the migration and Docs to document it,” propose Docs receiving “document the migration,” visibly marking the replacement of “it.” The antecedent comes from your message. If the antecedent exists only in another session, do not invent it. Ask you to identify it or explicitly attach the relevant source.

There are two distinct pronoun cases:

- “Fix it” addressed to the session whose conversation establishes “it”: preserve it.
- “Fix it” moved to a session that lacks that context: resolve from this message, include necessary user-written context, or ask.

Every part retains its source ranges. Every edit retains a diff. Every meaningful source clause must be assigned, shared, or explicitly excluded. Unassigned text is visible and blocks commitment until resolved or dropped by you.

These checks expose omissions; they do not prove semantic fidelity. Exact words can still become dangerous through deletion. Extracting “deploy” from “don’t deploy” would satisfy a naïve substring check. Human review remains necessary.

Commit `e2b3a47` removed model-written leftovers even though each already waited for a destination click. The distinction here is **source-first construction and approval of the complete recipient text**, rather than approving where a freely rewritten fragment goes.

**5. Review the complete send once**

Preserve today’s fast path for ordinary single-recipient messages. Every multi-recipient plan gets one review before any session prompt, form submission, stop, or Fjord mutation occurs.

Enter submits the draft for planning. A compact panel opens above the composer with:

- One row per destination and its exact outgoing message.
- Shared passages visibly identified.
- Wording repairs highlighted inline.
- Fjord changes shown as concrete before/after values.
- Unresolved references or destinations shown where they occur.

The primary button says **“Send to 2 sessions · change Fjord.”** Questions answered locally appear in the same panel or resulting history entry.

You can change a destination, edit its message, assign a passage to another recipient, share a passage, or remove an operation. Those edits update the plan. Nothing is sent while you repair it.

Do not show two empty text boxes and call that splitting. Fjord supplies the complete proposal; you correct the exceptional mistake.

Approval binds the exact plan version: recipients, bodies, attachments, card revisions, and Fjord changes. A later model result cannot replace approved text. A destination chip shown while typing is not approval of a division that appeared afterward.

For Fjord changes, preparation must produce proposed patches without applying them. [`RouterFjord.commit`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterFjord.swift:295) is the relevant seam, and `FjordChange` already carries before/after state. Recheck those preconditions at commitment. A materially changed patch comes back for review.

The cost is explicit: multi-recipient messages require another click and slower preparation. I would pay that cost before trusting automatic interpretation of several instructions carrying your authority.

**6. Make the difficult cases ordinary**

| Message or situation | Behavior |
|---|---|
| `@CI @Docs check your changes before committing` | One shared instruction to both. Review both exact messages. |
| `@CI rerun CI; @Docs add the page` | Two tasks, two deliveries. Neither receives the other’s task. |
| No tags: “tell CI to rerun and tell docs to add the page” | Propose both destinations and bodies. Resolve an ambiguous “CI” in place. |
| Reply to CI: “yes, use SQLite; @Docs document that choice” | CI’s answer and Docs’ instruction are separate. Docs receives the SQLite decision as necessary context. |
| Reply to CI: “does @Docs need this too?” | A question to CI. Docs is a reference, not automatically a recipient. |
| `@App fix the badge and Fjord turn off notifications` | One session delivery and one Fjord operation, approved together. |
| “Both of you do the same thing” | Shared instruction only if “the same thing” is established for both; otherwise resolve it before sending. |
| “After CI passes, tell Docs to publish” | Requires a future condition, not merely several sends. Do not dispatch Docs immediately. |

That last case marks a boundary: this feature should not silently introduce workflow orchestration. The existing [`RouterDepends`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDepends.swift:1) recognizes session dependencies and readiness; another session finishing a turn does not prove CI passed. Surface the dependency and leave that operation pending clarification rather than pretending delivery order satisfies it.

Likewise, “ask Fjord what failed and tell CI to fix it” requires the answer to become context for the CI message. Show that context as a separately attributed attachment for approval. Do not quietly turn externally obtained findings into prose purportedly authored by you.

**7. Commit once; track outcomes separately**

After approval, freeze and persist the plan, then execute independent operations concurrently. Each session still receives an ordinary user prompt through the existing signed plugin path. No “Fjord says,” relay preamble, sibling transcript, or automatic message about what another recipient was told.

Retain the exact-byte gate in [`RouterTools.approveSend`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterMCP.swift:1245). Change its authorization input from “this run’s whole original message” to “this approved operation’s immutable body.”

Do not promise atomic delivery across sessions:

- Preflight every operation before beginning.
- A failure discovered before commitment leaves the plan unsent.
- A failure after commitment produces a partial result. Successful siblings remain successful.
- Retry targets only the unsuccessful operation, using its approved text.
- An unavailable explicit recipient is never silently replaced.

Held new-session starts remain held children of the plan, using the existing timeout and “Don’t send” behavior. The composer stays free. Starting a session and delivering its first prompt are distinct outcomes.

Fix receipt semantics upstream. In [`ClaudePlugin.swift`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/ClaudePlugin.swift:743), an ordinary delivery starts `submit(...)` without awaiting its result before returning success. That is not proof the prompt was accepted.

Track **accepted, refused, and unconfirmed** outcomes durably per delivery. Retry uncertain transport with the same nonce; never allocate a fresh nonce automatically. Preserve the difference between “the plugin claimed this nonce” and “the prompt was accepted.” There is a crash window between those events, so exactly-once submission is not an honest guarantee.

Form answers and card resolution operate on the recipient’s assigned part, not the original message. Today [`reply`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift:793) interprets and judges cards using the whole job text. In a split, Docs’ instructions must not affect whether CI’s question was answered. Keep card-revision checks and leave stale or uncertain cards open.

**8. Keep one history entry, with recipient-level controls**

Collapsed:

> **Your message → CI, Docs, Fjord · 2 accepted, 1 failed**

Expanded, show the original and each operation’s exact body, status, timestamp, and controls. Animate separate branches from the original message as deliveries succeed. A failure leaves its branch visible; one success must not make the whole submission appear complete.

Cancel, send elsewhere, edit and resend, and fork act on individual deliveries:

- Cancel pending siblings directly; attempt existing plugin cancellation for accepted prompts.
- “Stop remaining” prevents further dispatch. It does not undo successful operations.
- Send elsewhere preserves that delivery’s text and existing cancellation protections.
- Edit and resend forks only the affected session from before its delivered prompt.
- Fjord changes retain their own Revert controls.

Store the transcript entry ID when observable, alongside the nonce and timestamps. Do not depend solely on matching repeated words for fork boundaries.

This requires replacing the singular `RouterDecision.delivered` and singular target with operations, rather than appending several `.sent` events under today’s structure. [`RouterDecision`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDecisions.swift:159) currently retains one cancellable delivery, and [`sentMessage`]( /Users/polarzero/code/projects/lookout/Sources/Fjord/RouterFork.swift:234) deliberately refuses multi-session entries. Update `lastTold` to read each session’s actual delivered body, never the full original submission.

Remove `Intent.compound`, `RouterAskBack.whole`, `fjordPartDone`, the manual `Split…` recovery path, whole-message reply precedence, and the assumption that one flight has one landing. Keep legacy fields for decoding old history only. Retain Jev’s single-recipient policy, typed pointers, signed transport, least-privilege Fjord tools, revision checks, held starts, and existing cancellation limits.

The missing evidence is how often real multi-recipient messages need wording repair and whether you can review those repairs quickly. Existing routing scores establish neither. If most proposals require substantial editing, this design has failed its purpose, regardless of destination accuracy.

**First action: collect 30 actual multi-recipient drafts and review proposed recipients, exact bodies, shared constraints, and omissions before building the delivery changes.**