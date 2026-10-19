import Foundation

// Running a message that goes to several places (docs/design/spec/router.md, "Several places"). Tags decide with no model
// (`RouterTagSplit`): each place gets the words of its tag; a sentence after the first of a tag's words is for Jev to check
// (is it for the tag's place?), and one that isn't is routed as a message of its own; tags that don't each open a sentence go
// to the divider, limited to the places they fix. Each part then runs as a message of its own would: the same route, the same
// gates, its own tools, so a send passes the send gate with only that part's words. The entry is divided into parts
// (`RouterDecision.divide(into:)`), each with an id the runs, asks and lines act on.

/// How a held part ends its wait.
enum PartRelease {
    /// "Send now".
    case now
    /// "Don't send", the wait running out, or the Router switched off: why it wasn't sent.
    case drop(String)
}

/// One place of a divided message, as it is about to run.
struct SplitPart: Equatable {
    /// Where it goes: `answer:<card>`, `session:<id>`, `new:<folder>`, an intent, or `project:<folder>` (a project you tagged:
    /// Jev places it there).
    var target: String
    /// Its words, and the pills among them.
    var text: String
    var mentions: [RouterMention] = []
    var pills: [Range<Int>] = []
    /// The place whose answer it waits for: it is held until you send it.
    var waitsFor: String?
    /// You fixed the place (a tag, the armed reply, the pinned target), as against Jev or the divider placing it.
    var fixed = true
    /// The card the armed reply is on, for the part that answers it.
    var replyTo: String?
    var pinned = false
}

extension RouterDispatcher {
    /// The place a target stands for, to tell places apart: a card is its session's, Fjord's runs are one, a project you tagged
    /// is a place of its own.
    func place(_ target: String) -> String {
        if RouteLabel.isFjord(target) { return "fjord" }
        if let store, let session = Self.session(of: target, store: store) { return "session:" + session }
        return target
    }

    // MARK: Dividing

    /// What the tags of the message decided (`RouterTagSplit.plan`).
    func split(_ job: Job, _ result: RouterTagSplit.Result) async throws {
        switch result {
        case .none: try await classifyAndAct(job)
        case .broadcast(let recipients): try await broadcast(job, recipients)
        case .segments(let segments): try await byTags(job, segments)
        case .divider(let fixed): try await byDivider(job, fixed: fixed)
        }
    }

    /// Items picked on the Brief: each gets the whole message.
    private func broadcast(_ job: Job, _ recipients: [String]) async throws {
        guard let store else { return }
        var seen = Set<String>()
        let parts = recipients.filter { eligible($0, store: store) && seen.insert($0).inserted }.map {
            SplitPart(target: $0, text: job.text, mentions: job.context.mentions, pills: job.context.pills)
        }
        // None of them is there any more: the message is routed as if it had none.
        guard !parts.isEmpty else { return try await classifyAndAct(job) }
        try await go(job, parts, path: "recipients", sure: true) { self.ask(job, targets: [], doubt: []) }
    }

    /// A piece of the message on its way to a place: the words are cut from the message by `slices`.
    private struct Piece {
        var part: SplitPart
        var slices: [Range<Int>] = []
    }

    /// Cuts the message at its tags: the words of each, the later sentences of each checked by Jev.
    private func byTags(_ job: Job, _ segments: [RouterTagSplit.Segment]) async throws {
        guard let store else { return }
        let c = Array(job.text)
        func words(_ r: Range<Int>) -> String { String(c[r]).trimmingCharacters(in: .whitespacesAndNewlines) }
        // A sentence is checked once, whoever shares it (tags side by side), against the words of its tag.
        var anchors: [Range<Int>: String] = [:]
        for segment in segments { for r in segment.check { anchors[r] = segment.anchor.trimmingCharacters(in: .whitespacesAndNewlines) } }
        let ranges = anchors.keys.sorted { $0.lowerBound < $1.lowerBound }

        var kept = Set<Range<Int>>()
        var moved: [Range<Int>: String] = [:]
        var doubt: [Classification] = []
        var unsure = false
        if !ranges.isEmpty {
            stage(job, "checking where each sentence goes")
            let yes = try await asks(job, ranges.map { (range: $0, sentence: words($0), tagged: anchors[$0] ?? "") })
            // For the tag's place (yes from 0.5), or not told: Jev can't be asked, so the tag you typed stands.
            var failed: [Range<Int>] = []
            for r in ranges { if let p = yes[r], p < 0.5 { failed.append(r) } else { kept.insert(r) } }
            if !failed.isEmpty {
                stage(job, "routing what isn't for the tag")
                let routed = try await reroutes(failed.map { (range: $0, sentence: words($0)) })
                for r in failed {
                    let found = routed[r]
                    // Where Jev is sure it goes (not "several places", not somewhere gone): there; else it stays, marked unsure.
                    if let found, found.sure, let top = found.top, top.target != RouteLabel.compound.rawValue, top.target != "unclear",
                       eligible(top.target, store: store) {
                        moved[r] = top.target
                    } else {
                        kept.insert(r)
                        unsure = true
                        if let found { doubt.append(found) }
                    }
                }
            }
        }

        var pieces: [Piece] = []
        func piece(_ target: String, fixed: Bool) -> Int {
            if let i = pieces.firstIndex(where: { place($0.part.target) == place(target) }) { return i }
            var part = SplitPart(target: target, text: "")
            part.fixed = fixed
            if let card = job.context.replyTo, target == "answer:\(card)" { part.replyTo = card }
            if let pin = job.context.target, target == pin { part.pinned = true }
            pieces.append(Piece(part: part))
            return pieces.count - 1
        }
        for segment in segments {
            pieces[piece(segment.target, fixed: true)].slices += segment.keep + segment.check.filter(kept.contains)
        }
        for r in ranges { if let target = moved[r] { pieces[piece(target, fixed: false)].slices.append(r) } }

        var parts: [SplitPart] = []
        for var piece in pieces where !piece.slices.isEmpty {
            let built = RouterTagSplit.assemble(job.text, piece.slices, mentions: job.context.mentions)
            // A place left with nothing but its tag has nothing to be sent.
            guard !built.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (try? Addressing.edit(built.text, pills: built.pills)) != nil else { continue }
            piece.part.text = built.text
            piece.part.mentions = built.mentions
            piece.part.pills = built.pills
            parts.append(piece.part)
        }
        let targets = (pieces.map(\.part.target) + parts.map(\.target)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        try await go(job, parts, path: parts.first.map(Self.pathName) ?? "tagged", sure: !unsure) {
            self.ask(job, targets: targets, doubt: doubt)
        }
    }

    /// Tags that don't each open a sentence: the divider decides which words go to which of the places they fix.
    private func byDivider(_ job: Job, fixed: [String]) async throws {
        guard let store else { return }
        stage(job, "dividing")
        let projects = Set(job.context.mentions.compactMap { m -> String? in if case .project(let f) = m.pointer { f } else { nil } })
        // Every place you tagged is among them, whatever the limits on the list leave out (an old session, a project's new one).
        let places = RouterDivider.places(job.tools.destinations(store, projects: nil, including: fixed))
        let request = RouterDivider.Request(message: job.text, places: places, cards: RouterDivider.cardLines(store, places: places),
                                            context: RouterDivider.contextLines(store, job.context, places: places),
                                            mode: .tags(fixed: fixed))
        let answer: RouterDivider.Answer
        do {
            answer = try await effects.divide(job.tools, request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No answer: the places you tagged are what it can go to.
            return ask(job, targets: fixed.map { askTarget($0, job: job) }, doubt: [])
        }
        try Task.checkCancellation()
        let parts = answer.parts.map { divided -> SplitPart in
            var target = divided.target
            var part = splitPart(divided, in: job)
            if let card = job.context.replyTo, let session = Self.session(of: "answer:\(card)", store: store),
               Self.session(of: target, store: store) == session {
                target = "answer:\(card)"
                part.replyTo = card
            } else if let pin = job.context.target, place(pin) == place(target) {
                target = pin
                part.pinned = true
            } else if target.hasPrefix("new:"), projects.contains(String(target.dropFirst(4))) {
                target = "project:" + target.dropFirst(4)
            }
            part.target = target
            return part
        }
        try await go(job, parts, path: "tags-divider", sure: answer.sure) {
            self.ask(job, targets: ([parts.first?.target].compactMap { $0 } + answer.alternatives).map { askTarget($0, job: job) }, doubt: [])
        }
    }

    // MARK: The gates

    /// Both compound gates are up: one Haiku call divides the message among every place there is (`RouterDivider`, with
    /// `waits_for`), as the benchmark's ship form does (evals/router/v2/multi/candidates.py, `Ship3`). Whether the message
    /// went as parts: true when it did. Two places or more with a part that isn't waiting: the parts go with no ask, the
    /// waiting ones held. One place, or every part waiting: that place is where Jev's compound pick goes, first in his ranking,
    /// sure only if he and the divider both are. No answer, or one that names no place: the message is ranked as if the gates
    /// hadn't fired.
    func byGates(_ job: Job, _ found: inout Classification, projects: [String]) async throws -> Bool {
        guard let store else { return false }
        let place = RouteLabel.compound.rawValue
        let key = Self.liveKey(job.text, projects)
        let answer: RouterDivider.Answer
        if let hit = shownDivision(key), hit.text == job.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Read while you typed: asked of the divider already.
            answer = .init(parts: hit.parts, sure: true, alternatives: [])
        } else {
            stage(job, "dividing")
            let places = RouterDivider.places(job.tools.destinations(store, projects: projects.isEmpty ? nil : Set(projects)))
            let request = RouterDivider.Request(message: job.text, places: places, cards: RouterDivider.cardLines(store, places: places),
                                                context: RouterDivider.contextLines(store, job.context, places: places), mode: .gates)
            do {
                answer = try await effects.divide(job.tools, request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                ungate(&found)
                return false
            }
            try Task.checkCancellation()
        }
        let places = Set(answer.parts.map { self.place($0.target) })
        if places.count >= 2, answer.parts.contains(where: { $0.waitsFor == nil }) {
            dispatch(job, parts: answer.parts.map { splitPart($0, in: job, fixed: false) }, inputs: found.trace)
            return true
        }
        // One place (the first part's, as the benchmark reads it), or nothing free to send: Jev's pick of compound goes there.
        if found.top?.target == place, let to = answer.parts.first?.target {
            let rest = found.ranked.filter { $0.target != place && $0.target != to }
            found.ranked = [Scored(target: to, p: found.top?.p ?? 0)] + rest
            found.card = [to] + (found.card ?? rest.map(\.target)).filter { $0 != place && $0 != to }
            found.sure = found.sure && answer.sure
        }
        return false
    }

    /// The ranking as if the gates hadn't fired. A compound pick that is still there isn't one to act on: it is not sure, and the
    /// ask doesn't list it.
    private func ungate(_ found: inout Classification) {
        if let single = found.ungated {
            found.ranked = single.ranked
            found.sure = single.sure
            found.card = single.card
        }
        guard found.top?.target == RouteLabel.compound.rawValue else { return }
        found.ranked.removeAll { $0.target == RouteLabel.compound.rawValue }
        found.card = found.card?.filter { $0 != RouteLabel.compound.rawValue }
        found.sure = false
    }

    /// The parts shown under the composer for these very words (`RouterContext.division`), as parts to send: none when they
    /// are for other words, are fewer than two, or one of them has no place to go to any more.
    func shownParts(_ job: Job) -> [SplitPart]? {
        guard let store, let shown = job.context.division, shown.text.trimmingCharacters(in: .whitespacesAndNewlines)
            == job.text.trimmingCharacters(in: .whitespacesAndNewlines), shown.parts.count >= 2,
              shown.parts.allSatisfy({ eligible($0.target, store: store) }) else { return nil }
        return shown.parts.map { splitPart($0, in: job, fixed: false) }
    }

    /// A part of a division as it is about to run: its pills are the ones of the message that its words kept.
    func splitPart(_ divided: RouterDivider.Part, in job: Job, fixed: Bool = true) -> SplitPart {
        var part = SplitPart(target: divided.target, text: divided.text)
        part.fixed = fixed
        part.waitsFor = divided.waitsFor
        part.mentions = Self.mentions(of: divided.text, from: job.context.mentions)
        part.pills = part.mentions.filter(\.pointer.addresses).map(\.range)
        return part
    }

    /// The parts a draft would be sent as, while you type: the divider asked of the draft once Jev's read of it has both gates
    /// up, kept by its words and projects for `liveFor` so that sending them asks nothing again. Nil when it isn't several
    /// places, can't be asked, or Jev may not read what you type.
    func predictDivision(_ text: String, found: Classification, projects: [String], mentions: [RouterMention] = []) async -> RouterDivision? {
        guard let store, store.jevAllows(.drafts), found.dividesNow else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var tagged = RouterContext(projects: projects)
        tagged.mentions = mentions
        let narrowed = Self.repoWorld(tagged, store: store).flatMap { $0.clones.isEmpty ? nil : $0.clones } ?? projects
        let key = Self.liveKey(text, narrowed)
        if let hit = divisionCache[key], Date().timeIntervalSince(hit.at) < Self.liveFor, hit.board == Self.boardRevision(store) {
            return hit.division
        }
        if let pending = divisionPending[key] { return await pending.task.value }
        let tools = RouterTools(store: store)
        tools.tagged = RouterPointers.context(mentions, store: store)
        configure?(tools)
        let places = RouterDivider.places(tools.destinations(store, projects: narrowed.isEmpty ? nil : Set(narrowed)))
        var context = tagged
        context.part = false
        let request = RouterDivider.Request(message: text, places: places, cards: RouterDivider.cardLines(store, places: places),
                                            context: RouterDivider.contextLines(store, context, places: places), mode: .gates)
        let id = UUID()
        let board = Self.boardRevision(store)
        // Its own task, as Jev's read of a draft is: a draft that changes, or is sent, doesn't stop it.
        let pending = Task { [weak self] () -> RouterDivision? in
            guard let self else { return nil }
            defer { if self.divisionPending[key]?.id == id { self.divisionPending[key] = nil } }
            guard self.store?.jevAllows(.drafts) == true, let answer = try? await self.effects.divide(tools, request),
                  self.store?.jevAllows(.drafts) == true else { return nil }
            // Several places, with a part to send: one that is only one place is the pick Jev's read already shows.
            let several = Set(answer.parts.map { self.place($0.target) }).count >= 2 && answer.parts.contains { $0.waitsFor == nil }
            let division = several ? RouterDivision(text: text, parts: answer.parts) : nil
            self.divisionCache = self.divisionCache.filter { Date().timeIntervalSince($0.value.at) < Self.liveFor }
            self.divisionCache[key] = (Date(), division, board)
            return division
        }
        divisionPending[key] = (id, pending)
        return await pending.value
    }

    /// A division kept from while you typed, while it is fresh and read on this board.
    private func shownDivision(_ key: String) -> RouterDivision? {
        guard let store, let hit = divisionCache[key], Date().timeIntervalSince(hit.at) < Self.liveFor,
              hit.board == Self.boardRevision(store) else { return nil }
        return hit.division
    }

    /// The parts as they stand: several go as parts; one is the message as it is, to its place (the path of today, when it is
    /// sure); none, or one that isn't sure, is asked.
    private func go(_ job: Job, _ parts: [SplitPart], path: String, sure: Bool, ask asked: () -> Void) async throws {
        if parts.count >= 2 { return dispatch(job, parts: parts) }
        guard parts.count == 1, sure else { return asked() }
        try await whole(job, parts[0], path: path)
    }

    /// The message as it is to one place: the parent run goes on itself (the entry stays one part).
    func whole(_ job: Job, _ part: SplitPart, path: String) async throws {
        var job = job
        if part.target.hasPrefix("project:") {
            // A project you tagged: Jev places it there, as a message with a lone @project is.
            job.context.projects = [String(part.target.dropFirst(8))]
            job.context.part = true
            // The armed reply and the pinned target were the place of the words no tag addressed; with none of them left, they
            // are not where these go.
            job.context.replyTo = nil
            job.context.target = nil
            return try await execute(job)
        }
        trace(job, path: path, action: "send", target: part.target)
        if part.fixed { confirm(job, part.target) } else { decide(job, part.target) }
        try await route(job, to: part.target)
    }

    /// Where it goes was Jev's or the divider's pick, not yours: no example for the next ones.
    func decide(_ job: Job, _ target: String) {
        guard let store else { return }
        store.updateDecision(job.id) {
            $0.decision.target = describe(target, store: store)
            $0.decision.targetID = target
            $0.decision.label = Self.label(target)
        }
    }

    private static func pathName(_ part: SplitPart) -> String {
        part.replyTo != nil ? "reply" : part.pinned ? "pinned" : "tagged"
    }

    /// A target as a button on an ask: a project you tagged is a new session in it.
    private func askTarget(_ target: String, job: Job) -> String {
        if target.hasPrefix("project:") { return "new:" + target.dropFirst(8) }
        if let store, let card = job.context.replyTo, let session = Self.session(of: "answer:\(card)", store: store),
           target == "session:\(session)" {
            return "answer:\(card)"
        }
        return target
    }

    /// Asks where the message goes: the places the tags fixed first, then what Jev made of the sentences he doubted.
    private func ask(_ job: Job, targets: [String], doubt: [Classification]) {
        var ranked = targets.map { Scored(target: askTarget($0, job: job), p: 0) }
        for found in doubt { ranked += found.ranked.filter { $0.target != RouteLabel.compound.rawValue } }
        askBack(job, Classification(ranked: ranked, sure: false, assisted: doubt.contains { $0.assisted }), path: "tags")
    }

    // MARK: Checks

    /// Jev's yes for each sentence, asked all at once; a sentence he couldn't be asked about has none.
    private func asks(_ job: Job, _ items: [(range: Range<Int>, sentence: String, tagged: String)]) async throws -> [Range<Int>: Double] {
        let tools = job.tools, message = job.text, effects = effects
        let tasks = items.map { item in Task { try? await effects.same(tools, message, item.sentence, item.tagged) } }
        let out = await withTaskCancellationHandler {
            var out: [Range<Int>: Double] = [:]
            for (item, task) in zip(items, tasks) { if let p = await task.value { out[item.range] = p } }
            return out
        } onCancel: { tasks.forEach { $0.cancel() } }
        try Task.checkCancellation()
        return out
    }

    /// Jev's routing of each sentence as a message of its own would be: with its own tools, so nothing of the rest goes with it.
    private func reroutes(_ items: [(range: Range<Int>, sentence: String)]) async throws -> [Range<Int>: Classification] {
        let tasks = items.map { item in
            Task { () -> Classification in
                let id = UUID()
                let tools = makeTools(id, item.sentence, pills: [])
                defer { tools.endTurn() }
                return await classify(Job(id: id, text: item.sentence, context: RouterContext(), tools: tools), projects: [])
            }
        }
        let out = await withTaskCancellationHandler {
            var out: [Range<Int>: Classification] = [:]
            for (item, task) in zip(items, tasks) { out[item.range] = await task.value }
            return out
        } onCancel: { tasks.forEach { $0.cancel() } }
        try Task.checkCancellation()
        return out
    }

    // MARK: Running the parts

    /// Divides the entry into `parts` and runs each as a message of its own: its words, its tools (so its send passes the
    /// send gate with only its words), its entry in the log.
    func dispatch(_ job: Job, parts: [SplitPart], inputs: RouterTrace.Inputs? = nil) {
        guard let store, parts.count >= 2 else { return }
        var ids: [UUID] = []
        store.updateDecision(job.id) { entry in
            let pieces = parts.map { part in
                RouterDecision.Part(text: part.text, mentions: part.mentions.isEmpty ? nil : part.mentions, place: part.target,
                                    waitsFor: part.waitsFor, decision: .init(intent: "message"),
                                    links: .init(cards: part.replyTo.map { [$0] } ?? []))
            }
            ids = entry.divide(into: pieces)
        }
        guard ids.count == parts.count else { return }
        trace(job, path: "split", action: "split", target: nil, inputs: inputs, parts: parts.map(\.target))
        replaceFlying(job.id, with: ids)
        for (part, id) in zip(parts, ids) {
            var context = RouterContext()
            context.part = true
            context.flies = job.context.flies
            context.mentions = part.mentions
            context.pills = part.pills
            context.replyTo = part.replyTo
            if part.pinned { context.target = part.target }
            if part.target.hasPrefix("project:") { context.projects = [String(part.target.dropFirst(8))] }
            let tools = makeTools(id, part.text, pills: part.pills, mentions: part.mentions)
            launch(Job(id: id, text: part.text, context: context, tools: tools), stage: "starting") { [self] job in
                try await run(job, part)
            }
        }
    }

    /// A part goes: held when it waits for another place's answer, else as a message of its own to its place.
    private func run(_ job: Job, _ part: SplitPart) async throws {
        if let waits = part.waitsFor { return holdPart(job, part, waitsFor: waits) }
        try await whole(job, part, path: part.fixed ? Self.pathName(part) : "split")
    }

    // MARK: Held parts

    /// A part that needs another place's answer first: not sent, its line saying what it waits for, with "Send now" and
    /// "Don't send". Nothing sends it on its own; it is dropped when `heldPartWait` runs out, and when the Router is switched
    /// off. Stop leaves it be.
    func holdPart(_ job: Job, _ part: SplitPart, waitsFor: String) {
        guard let store else { return }
        let id = job.id
        let place = describe(waitsFor, store: store)
        held[id] = "waits for \(place); it isn't sent unless you send it, and is dropped after \(Int(heldPartWait / 60)) minutes"
        // A turn of its own, as a held start's: this run's ends with it, and its send is checked against its words.
        let tools = makeTools(id, job.text, pills: job.context.pills, mentions: job.context.mentions)
        heldTools[id] = tools
        let context = job.context
        heldTasks[id] = Task { [weak self] in
            guard let self else { return }
            let released = await waitForRelease(id, place: place)
            held[id] = nil
            heldTasks[id] = nil
            heldTools[id] = nil
            switch released {
            case .now:
                var now = part
                now.waitsFor = nil
                launch(Job(id: id, text: job.text, context: context, tools: tools), stage: "sending") { job in
                    try await self.run(job, now)
                }
            case .drop(let why):
                tools.endTurn()
                store.updateDecision(id) {
                    $0.add(.failed(RouterDecision.clip("wasn't sent: " + why, 120)))
                    if $0.outcome == .pending { $0.outcome = .done }
                }
                follow(id)
                onFinish?(id)
            }
        }
    }

    private func waitForRelease(_ id: UUID, place: String) async -> PartRelease {
        let wait = heldPartWait
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.release(id, .drop("it waited too long for \(place)"))
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (wait: CheckedContinuation<PartRelease, Never>) in
                releases[id] = wait
                if Task.isCancelled { release(id, .drop("it was stopped")) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(id, .drop("it was stopped")) }
        }
    }

    /// Ends a held part's wait, once.
    func release(_ id: UUID, _ how: PartRelease) {
        releases.removeValue(forKey: id)?.resume(returning: how)
    }

    /// "Send now" on a held part: it goes as a message of its own to its place.
    func sendNow(_ id: UUID) {
        release(id, .now)
    }

    // MARK: Words

    /// The pills of `parent` that a part's `text` has kept: each "@name" where it stands in the words now.
    static func mentions(of text: String, from parent: [RouterMention]) -> [RouterMention] {
        let c = Array(text)
        var found: [RouterMention] = []
        func continues(_ i: Int) -> Bool {
            guard i < c.count else { return false }
            if c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "-" { return true }
            return (c[i] == "." || c[i] == "/") && i + 1 < c.count && (c[i + 1].isLetter || c[i + 1].isNumber)
        }
        for m in parent {
            let tag = Array("@" + m.name)
            var i = 0
            while tag.count > 1, i + tag.count <= c.count {
                if c[i] == "@", Array(c[i..<(i + tag.count)]) == tag, !continues(i + tag.count), i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber) {
                    found.append(RouterMention(range: i..<(i + tag.count), pointer: m.pointer, name: m.name))
                    i += tag.count
                } else {
                    i += 1
                }
            }
        }
        return mentions(found, in: text)
    }
}
