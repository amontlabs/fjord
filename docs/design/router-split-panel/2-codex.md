**I’d keep the shared plan architecture, reject automatic grammatical splitting, and narrow my own rewriting proposal. Your no-word-rules constraint rules out much of Gemini’s “deterministic” path and part of Fable’s segmenter.**

The central distinction is **structure you supplied versus meaning Fjord inferred**. Explicit structure can authorize dispatch directly. Inferred division, context sharing, or wording changes require a reviewable proposal.

**What I’d keep and drop from Gemini**

Keep:

- Unified recipients across tags, reply chips, and Brief selection, with the reply chip supplying a default rather than overriding everything.
- Overlapping source ranges for shared context and source-backed pronoun repairs.
- Exact outgoing messages, per-recipient controls, one parent history entry, and independent failure outcomes.
- Keeping future-output dependencies out of an immediate dispatch operation.

Drop:

- **Relay-verb regexes, connector word lists, title matching to strip framing, and punctuation rules that declare text “shared.”** These interpret language, violating your standing rule. “Because” does not establish which recipients need a clause.
- **Applying today’s fusion thresholds to fragments.** The fitted confidence concerns whole-message routing, not whether a split preserved instructions, conditions, and context. Neither 0.93 nor scoped 0.60 establishes that.
- **Executing Fjord’s part before the rest is resolved.** That preserves today’s central surprise: a submission changes the app while still waiting for you to approve what it means.
- **Sending the whole sentence to both recipients when extraction gets hard.** That gives each session instructions intended for the other. The session knowing its own title is not a reliable boundary.
- **“Mathematically impossible” prompt injection.** Source-only construction prevents introducing outside bytes. It does not prevent turning “Do not delete production data” into “delete production data.” Cryptography authenticates the resulting instruction; it does not validate its meaning.
- The unsupported “95%” coverage and latency claims.

Several code claims are wrong:

- `compound` **already includes two sessions without Fjord**, both in the route option and both compound gates: [RouterRoute.swift:34](/Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift:34), [51](/Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift:51), [53](/Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift:53). Gemini’s quoted instruction “False if all for sessions” is absent. The execution path mishandles this case; the classifier definition does not exclude it.
- Jev is remote, not local: [Jev.swift:7](/Users/polarzero/code/projects/lookout/Sources/Fjord/Jev.swift:7). The live debounce is **600 ms**, not 150 ms: [RouterJev.swift:58](/Users/polarzero/code/projects/lookout/Sources/Fjord/RouterJev.swift:58).
- Replying does not unconditionally clear a card through the claimed `repliedToCard` call. Forms use revision-checked answer paths; ordinary messages subsequently invoke card judgment: [RouterDispatcher.swift:803](/Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift:803), [862](/Users/polarzero/code/projects/lookout/Sources/Fjord/RouterDispatcher.swift:862).
- Several references point to the wrong files: `RelaySigner` lives in [ClaudePlugin.swift:943](/Users/polarzero/code/projects/lookout/Sources/Fjord/ClaudePlugin.swift:943), and `RouterLiveTarget` lives in `RouterJev.swift`.

**What I’d keep and drop from Fable**

Keep:

- **Do not reuse whole-message fusion as calibrated split confidence.** This is the strongest correction to Gemini.
- Batched classification of candidate parts as an experiment, source-based preparation, and notification/category attachments scoped to the recipient’s part.
- “Several places” while typing instead of unstable live segmentation.
- Reading `lastTold` and `toldAll` from actual recipient bodies.
- Keeping the existing classification vocabulary during migration, rather than casually changing fitted inputs.

Drop:

- **Grammar disguised as structure.** Abbreviation lists, connector matching, and sentence interpretation exceed your allowed structural rules. Line breaks, actual pill positions, and code boundaries are legitimate; deciding what an “and” means requires classification.
- **The promise that consequences fall out for free.** Extraction does not automatically preserve scope, pronouns, or authority. Per-part cancellation and forks require real record changes.
- **Shared context automatically prepended to every recipient.** Sharing can involve a subset. A trailing qualification should retain its position unless you approve moving it.
- **Assigning unclear spans to the most-labelled destination.** Uncertainty should remain unresolved, not become a plausible-looking default.
- **Automatically sending tagged prose despite dangling references.** Fable’s `@CI … @docs document it` example follows its immediate-send rule, yet its explanation says a card shows the problem. Those are incompatible behaviors.
- An eight-span cliff that returns longer messages to manual splitting, and treating 90% proposal accuracy as grounds for silent dispatch. Those are unsupported thresholds.
- “The plugin needs nothing new” as an end-to-end conclusion. Fan-out needs no new signature format, but reliable outcome reporting still needs the receipt fix discussed below.

The “~2% of real moments” claim does not establish production frequency. The current [dev dataset](/Users/polarzero/code/projects/lookout/evals/router/v2/data/episodes/dev/episodes.jsonl) contains **574 episodes and 1,054 submits**, mixing real moments, rewrites, goals, and scripted contracts. Only 216 episodes have `real-moment` provenance. Counting episode labels across that mixture cannot establish that 98% of your actual messages remain unaffected.

One migration detail also affects my answer: merely deleting `RouterRun.Intent.compound` while retaining the classification option changes behavior. Current routing uses membership in that execution enum to recognize intents: [RouterRoute.swift:365](/Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift:365), [515](/Users/polarzero/code/projects/lookout/Sources/Fjord/RouterRoute.swift:515). **Separate classification labels from runnable intents first.**

**What I’d keep and drop from the prior thinking**

Keep numbered source units instead of asking a model to count character offsets. Have the app map those units back to immutable original ranges, retaining punctuation and whitespace. Validate every reference and fail closed on malformed output.

Also keep the later possibility that submitting a fully visible, current preview constitutes confirmation. Confirmation need not permanently mean two submissions.

Drop “two tags always means a split” without distinguishing address position from reference position. “Ask @Docs about @CI” does not address both. Two explicit recipients also need not produce different bodies: an explicit broadcast sends the same instruction to both.

Use ordinary one-destination execution underneath, but keep its records inside the parent submission. Independent top-level decision entries with `splitFrom` recreate bookkeeping and history problems that nested operations avoid.

The deletion-only rule is a legitimate product choice, but it cannot promise self-contained messages for arbitrary prose.

**Changes to my round-one design**

I would make these deltas:

1. **Replace mandatory review for every multi-recipient submission with review for every inferred transformation.** Explicit recipient blocks, or an explicit “Send same message to these recipients” action, can dispatch directly when the exact bodies are visible and unchanged. Selecting several Brief items alone does not choose broadcast versus division.

2. **Restrict deterministic scopes to clear authored structure.** A recipient prefix beginning a line/block establishes scope. Inline pointers remain references until classification proposes otherwise. No connector lists, relay-prefix regexes, or abbreviation heuristics. This also means removing existing word-based destination shortcuts from the revised path, rather than preserving them because they already exist.

3. **Make source-range plans the default representation.** Let classification choose ranges, omissions, recipients, and shared passages. The app reconstructs the result exactly. Compare batched Jev labels with a numbered-range Haiku proposal on actual messages before choosing the parser. Neither has demonstrated split accuracy here.

4. **Narrow wording repair to an explicit alternative.** My first proposal allowed small repairs within the initial proposal. I would now show extraction first. Where it leaves an unresolved reference, offer a clearly marked repair such as `it → the migration`, sourced from your message. Never silently substitute it, and never substitute another session’s instructions as “context” without showing that assignment.

5. **Review both source coverage and actual recipient messages.** Tints alone conceal the effect of concatenation; recipient text alone conceals omissions. Show the outgoing bodies by default, with source highlighting on selection. Resolve omissions, references, and destinations in the same panel.

I hold my ground on **planning before effects**, preserving the single-recipient routing policy rather than replacing it wholesale, recipient-specific form interpretation, independent outcomes, and no automatic cross-session orchestration.

I also retain the receipt correction. Ordinary plugin delivery starts prompt submission without awaiting its outcome before returning success: [ClaudePlugin.swift:744](/Users/polarzero/code/projects/lookout/Sources/Fjord/ClaudePlugin.swift:744). Record acceptance, refusal, and uncertainty separately; never retry an uncertain delivery with a fresh nonce automatically.

**The two product decisions**

1. **May Fjord propose repaired wording, or only delete from your message?** I recommend source-only by default with explicitly accepted repairs. Deletion-only offers a stronger mechanical invariant but leaves some messages awkward or dependent on your edits.

2. **When does Return authorize multiple deliveries?** I recommend direct dispatch for explicit structure with exact bodies visible; inferred divisions get a review step. Later, a complete stable preview can make Return that review’s commit action. Destination chips alone are insufficient.

**Next action: evaluate real drafts against both wording policies, recording complete recipient-body correctness and correction effort, not just destination accuracy.**