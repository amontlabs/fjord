import Foundation

// The `.answer` intent (docs/design/router-watch-and-briefs.md §3.5, §3.6): a run outside `runs` (it never takes the top tab, so it is
// outside `tabFree`, `acting` and `yielded`) that holds its thread frame's document. Proof: the card `answered` in that frame's rows,
// then the thread's row `working`. One retry at the deadline, safe under the page's guards (a busy or disabled button is never clicked
// again; an answered or absent card ends `refused`). A cut-off answer (`frame_gone`, or a new document before its `done`) is reissued
// once to the frame's next port, after that port's `commands` says it neither ran nor waits.

extension CourierCore {
    static let answerAttempts = 2

    /// `.answer(project, thread, card, option)`: `card` is the decision row's key, `option` the button's number, 1-based, in page order.
    func answer(_ project: String, _ thread: String, card: String, option: Int, reply: @escaping (JSON) -> Void = { _ in },
                finished: @escaping (JSON) -> Void = { _ in }) throws {
        let (intent, created) = try sql.addIntent(clock(), "answer", words: "\(card)#\(option)", project: project, thread: thread,
                                                  args: ["card": .string(card), "option": .int(option)], proof: ["card": .string(card)])
        let id = intent["id"]?.asInt ?? 0
        reply(["event": "decision", "intent": intent, "warning": .null])
        if !created, let a = watching.answers[id] {  // the same answer again inside the window: that run's outcome
            let earlier = a.finished
            a.finished = { earlier($0); finished($0) }
            return
        }
        let f = CourierFrame(project: project, thread: thread)
        let a = CourierAnswer(id: id, frame: f, card: card, option: option, finished: finished)
        watching.answers[id] = a
        issueAnswer(a)
    }

    /// The answer's frame: its kept one, a free kept slot (or the LRU card frame's), else the check slot, at once (a check in flight
    /// is requeued first: it stays owed).
    func answerFrame(_ f: CourierFrame) {
        guard let thread = f.thread else { return }
        if let i = watching.keptIndex(thread) { watching.kept[i].card = true; watching.kept[i].used = clock(); return }
        if watching.check == f { watching.checkAnswer = true; return }
        if keep(f.project, thread, card: true) { return }
        if let c = watching.check, watching.checkAnswer, watching.pinned(c.thread) { return }  // another answer's: its deadline retries
        watching.check = f
        watching.checkAnswer = true
    }

    /// Each issue (the first, a retry, a reissue after a cut-off) wants its frame again: it may have gone meanwhile.
    func issueAnswer(_ a: CourierAnswer) {
        answerFrame(a.frame)
        syncFrames()
        a.attempts += 1
        a.lost = false
        a.frameInstance = watching.states[a.frame]?.instance
        a.command = command("answer", [("project", .string(a.frame.project)), ("thread", JSON(a.frame.thread)), ("card", .string(a.card)),
                                       ("option", .int(a.option)), ("frame", a.frame.json)])
        a.deadline = clock() + CourierDo.timeout
        wake()
    }

    func answerDone(_ event: JSON) throws {
        guard let id = event.get("id")?.asString, let a = watching.answers.values.first(where: { $0.command == id }) else { return }
        a.command = nil
        if event.get("refused") == .bool(true) {
            // after Fjord's own click, a card that shows answered is that click's: its proof is pending, not a refusal
            if a.clicked && event.get("error")?.asString == "already answered" { return try proveAnswers() }
            return try finishAnswer(a, "refused", (event.get("error")?.asString).flatMap { $0.isEmpty ? nil : $0 } ?? "the card was already answered or is gone")
        }
        if event.flag("ok") || event.flag("clicked") {
            a.clicked = true
            return try proveAnswers()
        }
        // a failure the page reported: the deadline retries it, once
    }

    /// Card answered, then the row working.
    func proveAnswers() throws {
        for a in Array(watching.answers.values) where a.answered || a.clicked {
            guard let thread = a.frame.thread else { continue }
            if a.answered && log.status[thread] == "working" { try finishAnswer(a, "confirmed", nil) }
        }
    }

    func answerTick(_ now: Double) throws {
        for a in Array(watching.answers.values) {
            guard let d = a.deadline, d <= now else { continue }
            a.deadline = nil
            if a.attempts < Self.answerAttempts && !(a.answered) {
                if let c = a.command { command("cancel", [("target", .string(c))]) }
                issueAnswer(a)
            } else if a.answered {
                try finishAnswer(a, "failed", "the card shows answered, but the thread never showed working")
            } else {
                let why = watching.states[a.frame]?.notice.map { ": \($0.text)" } ?? ""
                try finishAnswer(a, "failed", "the answer was not confirmed: the card never showed answered" + why)
            }
        }
    }

    /// The frame's port is back and says what it holds: a cut-off answer it neither ran nor holds is reissued, once.
    /// The frame counts live only after a settled whole read of this document, never at its `commands`.
    func frameReplay(_ f: CourierFrame, _ event: JSON) throws {
        let waiting = Set((event.get("waiting")?.asArray ?? []).compactMap(\.asString))
        let done = CourierPage.items(event.get("done"))
        for a in Array(watching.answers.values) where a.frame == f {
            guard let c = a.command else { continue }
            if let d = done.first(where: { $0.get("id")?.asString == c }) { try answerDone(d); continue }
            if waiting.contains(c) { a.lost = false; continue }
            if a.lost {
                a.command = nil
                if a.attempts < Self.answerAttempts { issueAnswer(a) } else { try finishAnswer(a, "failed", "the frame went before the answer was confirmed") }
            }
        }
    }

    func finishAnswer(_ a: CourierAnswer, _ status: String, _ cause: String?) throws {
        watching.answers.removeValue(forKey: a.id)
        if status != "confirmed", let t = a.frame.thread { watching.expectWork.remove(t) }
        if let c = a.command, status != "confirmed" { command("cancel", [("target", .string(c))]) }
        let updated = try sql.update(clock(), a.id, [("status", .string(status)), ("cause", JSON(cause)),
                                                     ("result", ["attempts": .int(a.attempts), "clicked": .bool(a.clicked), "answered": .bool(a.answered)])])
        if watching.check == a.frame && watching.checkAnswer {  // it stays as a kept card frame only if a slot is free
            watching.check = nil
            watching.checkAnswer = false
            if watching.kept.count < CourierFrames.keptCap, let t = a.frame.thread {
                watching.kept.append(CourierKept(thread: t, project: a.frame.project, card: true, used: clock()))
            }
        }
        watching.finishes += 1
        a.finished(updated)
        settle(updated)
        try afterWatch()
    }
}
