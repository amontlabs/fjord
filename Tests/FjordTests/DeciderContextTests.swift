import Foundation
import Testing
@testable import Fjord

/// The decider's full context (N4's `ctx_compact`, ported from evals/router/t3/n4ctx.py): the blocks in cache order, the day's
/// archive frozen, the caps, creation order everywhere, absolute times and no "latest" labels, read state, BM25. Invented threads.
@MainActor
@Suite struct DeciderContextTests {
    static let zone = TimeZone(identifier: "Europe/Paris")!
    /// Sat 2026-11-07 15:00 Paris.
    static let now = Date(timeIntervalSince1970: 1_794_060_000)

    static func thread(_ key: String, project: String = "harbor", title: String = "Tide table import", created: TimeInterval = -86400 * 3,
                       active: TimeInterval = -3600, running: Bool = false, onBoard: Bool = true, said: String = "", first: String = "",
                       run: TimeInterval? = nil, visited: TimeInterval? = nil, wrote: TimeInterval? = nil) -> ContextThread {
        var t = ContextThread(key: key, project: project, title: title, created: now.addingTimeInterval(created), lastActive: now.addingTimeInterval(active))
        t.running = running
        t.onBoard = onBoard
        t.said = said
        t.first = first
        t.lastRunCompletedAt = run.map { now.addingTimeInterval($0) }
        t.lastVisitedAt = visited.map { now.addingTimeInterval($0) }
        t.youWroteAt = wrote.map { now.addingTimeInterval($0) }
        return t
    }

    static func build(_ message: String, threads: [ContextThread], tagged: String? = nil, unattended: Bool = false,
                      turns: [String: [ThreadTurn]] = [:], cards: [String: ThreadCard] = [:]) -> DeciderContext.Built {
        let index = ThreadIndex()
        for t in threads { index.put(t.key, title: t.title, text: (turns[t.key] ?? []).map(\.text).joined(separator: " ") + " " + t.said, stamp: "1") }
        let x = DeciderContext.Inputs(projects: ["harbor", "fjord"], purposes: ["harbor": "Notes for sailors"], threads: threads, cards: cards,
                                      turns: turns, index: index, now: now, zone: zone)
        return DeciderContext.build(message, x, tagged: tagged, unattended: unattended)
    }

    static func turn(_ role: String, _ ago: TimeInterval, _ text: String) -> ThreadTurn { ThreadTurn(role: role, at: now.addingTimeInterval(ago), text: text) }

    @Test func theBlocksComeInCacheOrderAndTheMessageLast() {
        let ts = [Self.thread("a", said: "The importer reads both CSV layouts.", run: -3600),
                  Self.thread("old", title: "Chart tiles", created: -86400 * 10, active: -86400 * 5, onBoard: false)]
        let b = Self.build("fix the trailing comma in the tide importer", threads: ts,
                           turns: ["old": [Self.turn("user", -86400 * 6, "cache the chart tiles")]])
        #expect(b.blocks.count == 3)
        let u = b.user
        let marks = ["## Projects", "## Archive", "## Live threads (creation order)", "## Project facts", "## Threads whose text", "## Now", "Message:\n<message>"]
        let at = marks.map { u.range(of: $0).map { u.distance(from: u.startIndex, to: $0.lowerBound) } ?? -1 }
        #expect(!at.contains(-1) && at == at.sorted())
        #expect(b.blocks[0].hasPrefix("## Projects\n- harbor | purpose: Notes for sailors\n- fjord | purpose: unknown"))
        #expect(b.system.hasPrefix("You route one message") && !b.system.contains("Always return need"))
        #expect(b.system.contains("Archive (a snapshot at the start of today") && b.system.contains("message_deliverable"))
    }

    @Test func idsAreStableShortHashesAndMapBack() {
        let ts = [Self.thread("thread-one"), Self.thread("thread-two", created: -100)]
        let ids = DeciderContext.ids(ts)
        #expect(ids.values.allSatisfy { $0.hasPrefix("t-") && $0.count == 6 })
        #expect(DeciderContext.ids(ts.reversed()) == ids)
        let b = Self.build("hello there friend", threads: ts)
        #expect(b.ids[ids["thread-one"]!] == "thread-one")
    }

    @Test func liveThreadsFollowN4bsRulesCapAndCreationOrder() {
        var ts: [ContextThread] = []
        // 20 finished within 24 h, created in reverse order of their keys; 2 running ones, oldest of all.
        for i in 0..<20 { ts.append(Self.thread("f\(i)", created: -Double(1000 + i * 10), active: -Double(60 * (i + 1)))) }
        ts.append(Self.thread("run1", created: -900_000, active: -86400 * 3, running: true))
        ts.append(Self.thread("run2", created: -800_000, active: -86400 * 3, running: true))
        // Old, finished, but its project's newest: kept. Old and not newest: out. Off the board: never live.
        ts.append(Self.thread("lone", project: "fjord", created: -86400 * 9, active: -86400 * 8))
        ts.append(Self.thread("stale", project: "fjord", created: -86400 * 20, active: -86400 * 19))
        ts.append(Self.thread("settled", created: -10, active: -5, onBoard: false))
        let sel = DeciderContext.liveThreads(ts, now: Self.now)
        #expect(sel.count == 16 && sel.contains { $0.key == "run1" } && sel.contains { $0.key == "run2" })
        // Over the cap, an old project's newest is cut like any other idle thread; off the board is never live.
        #expect(!sel.contains { $0.key == "lone" } && !sel.contains { $0.key == "stale" } && !sel.contains { $0.key == "settled" })
        #expect(sel.map(\.created) == sel.map(\.created).sorted())
        // The cut keeps the most recently active of the rest.
        #expect(sel.contains { $0.key == "f0" } && !sel.contains { $0.key == "f19" })
        // Just created (30 min) is live whatever else.
        let fresh = DeciderContext.liveThreads([Self.thread("new", project: "fjord", created: -600, active: -86400 * 2),
                                                Self.thread("newer", project: "fjord", created: -300, active: -60)], now: Self.now)
        #expect(fresh.map(\.key) == ["new", "newer"])
        // Under the cap, each project's newest is live within 7 days; an older one isn't, nor a newest past the backstop.
        let quiet = DeciderContext.liveThreads([Self.thread("lone", project: "fjord", created: -86400 * 9, active: -86400 * 6),
                                                Self.thread("stale", project: "fjord", created: -86400 * 20, active: -86400 * 19)], now: Self.now)
        #expect(quiet.map(\.key) == ["lone"])
    }

    @Test func settledThreadsAreLabelledAndABriefsTagsAreAlwaysLive() {
        var settled = Self.thread("s", title: "Tide table import", created: -86400 * 5, active: -86400 * 2, onBoard: false)
        settled.settledAt = Self.now.addingTimeInterval(-3600)
        let live = Self.thread("l", title: "Tide table import")
        let index = ThreadIndex()
        let ts = [settled, live]
        let byKey = Dictionary(uniqueKeysWithValues: ts.map { ($0.key, $0) })
        let ids = ["s": "ts", "l": "tl"]
        let e = DeciderContext.retrievalBlock(message: "tide table", index: index, keys: ["s", "l"], live: ["l"], archive: ["s"], threads: byKey,
                                              ids: ids, search: [DeciderContext.SearchHit(thread: "s", snippet: "tide table")], now: Self.now,
                                              zone: Self.zone, turns: [:])
        #expect(e.contains("ts (settled,") && !e.contains("ts (archive"))
        let f = DeciderContext.nowBlock([live], all: ts, ids: ids, now: Self.now, zone: Self.zone)
        #expect(f.contains("Settled since the snapshot: ts."))
        // A tagged settled thread is live even over the cap; an untagged one off the board is not.
        var many: [ContextThread] = []
        for i in 0..<20 { many.append(Self.thread("f\(i)", created: -Double(1000 + i * 10), active: -Double(60 * (i + 1)))) }
        many.append(settled)
        #expect(DeciderContext.liveThreads(many, now: Self.now, mentioned: ["s"]).contains { $0.key == "s" })
        #expect(!DeciderContext.liveThreads(many, now: Self.now).contains { $0.key == "s" })
        #expect(DeciderContext.stateLine(settled, zone: Self.zone, now: Self.now).hasPrefix("state: settled"))
        #expect(DeciderContext.role.contains("names it, reopens it, or continues its exact deliverable"))
    }

    @Test func theArchiveHoldsThirtyDaysBeforeTheDaysStartInCreationOrder() {
        let start = DeciderContext.dayStart(Self.now, Self.zone)
        #expect(DeciderContext.at(start, Self.zone) == "Sat 11-07 04:00")
        let ts = [Self.thread("b", created: -86400 * 5, active: -86400 * 2), Self.thread("a", created: -86400 * 8, active: -86400 * 3),
                  Self.thread("gone", created: -86400 * 60, active: -86400 * 40), Self.thread("today", created: -600, active: -60)]
        let ids = DeciderContext.ids(ts)
        let card = ThreadCard(delivering: "the CSV importer", status: "done", open: "", last: "shipped")
        let a = DeciderContext.archiveBlock(ts, ids: ids, cards: ["a": card], turns: ["a": [Self.turn("user", -86400 * 8, "import the tide tables")]],
                                            firsts: [:], dayStart: start, zone: Self.zone)
        #expect(a.keys == ["a", "b"])
        #expect(a.text.contains("- \(ids["a"]!) | harbor | Tide table import | created 10-30, last active 10-30"))
        #expect(a.text.contains("  asked: import the tide tables\n  deliverable: the CSV importer · status: done · left: nothing"))
        #expect(a.text.contains("(not read yet)"))
        #expect(a.text.hasPrefix("## Archive: threads active in the 30 days before Sat 11-07 04:00 (the start of today)"))
    }

    @Test func theArchiveIsFrozenForTheDayAndOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cards-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThreadCardStore(folder: dir)
        let day = DeciderContext.dayStart(Self.now, Self.zone)
        var builds = 0
        let first = store.archive(day: day, zone: Self.zone) { builds += 1; return ("A1", ["a"]) }
        let again = store.archive(day: day, zone: Self.zone) { builds += 1; return ("A2", ["a", "b"]) }
        #expect(first.text == "A1" && again.text == "A1" && builds == 1)
        // The next working day: built again.
        let next = store.archive(day: day.addingTimeInterval(86400), zone: Self.zone) { builds += 1; return ("B", []) }
        #expect(next.text == "B" && builds == 2)
        // The same day after a relaunch: read back from disk, byte for byte.
        let file = dir.appendingPathComponent("thread-cards/archive-2026-11-08.json")
        await waitUntil { FileManager.default.fileExists(atPath: file.path) }
        let relaunched = ThreadCardStore(folder: dir)
        #expect(relaunched.archive(day: day.addingTimeInterval(86400), zone: Self.zone) { ("other", []) }.text == "B")
        // And the whole prefix is the same for the same inputs.
        let built = DeciderContextTests.build("same words here", threads: [Self.thread("a")])
        let rebuilt = DeciderContextTests.build("same words here", threads: [Self.thread("a")])
        #expect(built.blocks[0] == rebuilt.blocks[0] && built.key == rebuilt.key)
    }

    @Test func timesAreAbsoluteAndNothingSaysLatest() {
        let ts = [Self.thread("a", said: "Done.", run: -1800, visited: -7200, wrote: -3000),
                  Self.thread("b", title: "Chart tile cache", created: -86400, said: "Cached.", run: -600, visited: -60, wrote: -5000),
                  Self.thread("r", title: "Runner", created: -500, running: true)]
        let u = Self.build("ok go", threads: ts).user.lowercased()
        #expect(!u.contains("latest") && !u.contains("most recent") && !u.contains("probably") && !u.contains(" ago"))
        #expect(u.contains("## now\nsat 11-07 15:00 paris."))
        #expect(u.contains("running now: "))
    }

    @Test func theReadStateLineSaysWhatYouOpened() {
        let unread = Self.thread("a", run: -1800, visited: -7200)
        let line = DeciderContext.stateLine(unread, zone: Self.zone, now: Self.now)
        #expect(line == "state: finished, last activity Sat 11-07 14:00 · its reply is not read yet (you last opened it Sat 11-07 13:00, before its reply) · created Wed 11-04 15:00")
        #expect(unread.unread)
        let read = Self.thread("b", run: -1800, visited: -60, wrote: -3600)
        #expect(DeciderContext.stateLine(read, zone: Self.zone, now: Self.now).contains("· you opened it Sat 11-07 14:59, after its reply · you last wrote here Sat 11-07 14:00"))
        #expect(!read.unread)
        let never = Self.thread("c", run: -60)
        #expect(DeciderContext.stateLine(never, zone: Self.zone, now: Self.now).contains("its reply is not read yet (you never opened it)"))
        // F lists the replies since your last message, oldest first, with their read state.
        let f = DeciderContext.nowBlock([never, read], all: [never, read], ids: ["c": "t-c", "b": "t-b"], now: Self.now, zone: Self.zone)
        #expect(f.contains("Your last message anywhere: Sat 11-07 14:00.") && f.contains("Since then: t-b replied 14:30; t-c replied 14:59 (not read yet)."))
    }

    @Test func t3sUnreadIsARunFinishedAfterYourLastVisitNotAnyUpdate() {
        func shell(visited: String?, run: String?, updated: String) -> T3ThreadShell {
            var j: [String: T3JSON] = ["id": "t", "updatedAt": .string(updated)]
            if let visited { j["lastVisitedAt"] = .string(visited) }
            if let run { j["latestRunCompletedAt"] = .string(run) }
            return T3ThreadShell(json: .object(j))
        }
        // Pinned or settled after you read it: still read.
        #expect(!shell(visited: "2026-01-02T03:00:00.000Z", run: "2026-01-02T02:00:00.000Z", updated: "2026-01-02T04:00:00.000Z").isUnseen)
        #expect(shell(visited: "2026-01-02T01:00:00.000Z", run: "2026-01-02T02:00:00.000Z", updated: "2026-01-02T02:00:00.000Z").isUnseen)
        #expect(shell(visited: nil, run: "2026-01-02T02:00:00.000Z", updated: "2026-01-02T02:00:00.000Z").isUnseen)
        // Never ran: nothing to read.
        #expect(!shell(visited: nil, run: nil, updated: "2026-01-02T02:00:00.000Z").isUnseen)
    }

    @Test func retrievalListsBM25HitsAndTheWordsNoThreadMentions() {
        let ts = [Self.thread("a", said: "The tide importer reads both CSV layouts; the trailing comma still fails."),
                  Self.thread("b", title: "Chart tile cache", said: "Tiles are cached to memory.")]
        let b = Self.build("fix the trailing comma in the tide importer for zanzibar", threads: ts)
        let e = b.blocks[2]
        let ids = DeciderContext.ids(ts)
        #expect(e.contains("- \(ids["a"]!) (live, harbor, Tide table import, last active Sat 11-07 14:00) · \"…"))
        #expect(!e.contains("- \(ids["b"]!) ("))
        #expect(e.contains("- words of the message no thread mentions: zanzibar"))
        // T3's own search adds a thread BM25 missed.
        let index = ThreadIndex()
        let x = DeciderContext.Inputs(projects: ["harbor"], threads: ts, index: index, search: [.init(thread: "b", snippet: "the zanzibar tiles")],
                                      now: Self.now, zone: Self.zone)
        let withSearch = DeciderContext.build("zanzibar", x)
        #expect(withSearch.blocks[2].contains("\"…the zanzibar tiles…\" (T3 search)"))
    }

    @Test func liveThreadsShowN2sCompactLines() {
        var t = Self.thread("a", said: String(repeating: "x", count: 700) + " the end", first: "import the tide tables")
        t.earlier = ["one", "two", "three", "four"]
        t.youSaid = "and the second layout"
        t.youSaidLast = true
        let lines = DeciderContext.compactLines(t)
        #expect(lines[0] == "first ask: import the tide tables")
        #expect(lines[1] == "your earlier messages there: two / three / four")
        #expect(lines[2].hasPrefix("its last reply: ") && lines[2].hasSuffix("the end") && lines[2].count == "its last reply: ".count + 600)
        #expect(lines[3] == "you said after that: and the second layout")
    }

    @Test func theCardDigestAndCapsArePythons() {
        let turns = [Self.turn("user", -500, "first"), Self.turn("assistant", -400, "a1"), Self.turn("user", -300, "second"),
                     Self.turn("assistant", -200, "a2")]
        #expect(ThreadCardStore.digest(turns) == "[first ask] first\n[agent] a1\n[owner] second\n[agent, latest reply] a2")
        let long = (0..<30).map { Self.turn($0 == 0 ? "user" : "assistant", Double($0), String(repeating: "w", count: 5000)) }
        let capped = ThreadCardStore.capped(long)
        #expect(capped.first?.role == "user" && capped.allSatisfy { $0.text.count <= ThreadCardStore.turnChars })
        #expect(capped.reduce(0) { $0 + $1.text.count } <= ThreadCardStore.threadChars + ThreadCardStore.turnChars)
    }

    @Test func aCardIsMadeOffPathWhenARunCompletesAndTheTextIsIndexed() async throws {
        let store = ThreadCardStore(folder: nil)
        let haikus = CardCounter()
        store.reader = { _ in [ThreadTurn(role: "user", at: Date(), text: "import the tide tables"), ThreadTurn(role: "assistant", at: Date(), text: "done")] }
        store.haiku = { _, user, _ in
            haikus.bump()
            #expect(user.hasPrefix("Thread title: Tides\nConversation before now:\n[first ask] import the tide tables"))
            return Data(#"{"delivering":"tide import","status":"done","open":"","last":"done"}"#.utf8)
        }
        store.refresh([(key: "a", title: "Tides", textStamp: "m1", cardStamp: "r1", running: false)])
        await store.settled()
        #expect(store.cards["a"]?.delivering == "tide import" && haikus.n == 1)
        #expect(store.index.search("tide", among: ["a"], k: 6).hits.first?.key == "a")
        // Nothing moved: nothing done again. A running thread gets no card.
        store.refresh([(key: "a", title: "Tides", textStamp: "m1", cardStamp: "r1", running: false),
                       (key: "b", title: "Run", textStamp: "m9", cardStamp: "r9", running: true)])
        await store.settled()
        #expect(haikus.n == 1 && store.cards["b"] == nil && store.turns["b"]?.isEmpty == false)
    }
}

final class CardCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var n: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

/// The model-usage log and its totals.
@Suite struct ModelUsageLogTests {
    @Test func callsAreSummedPerModelForTodayTheWeekAndAllTime() throws {
        let now = Date(timeIntervalSince1970: 1_794_060_000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Paris")!
        func e(_ role: ModelUsageLog.Role, _ ago: TimeInterval, cost: Double? = 0.01) -> ModelUsageLog.Entry {
            .init(at: now.addingTimeInterval(-ago), role: role, model: "m", usage: ModelUsage(inputTokens: 100, outputTokens: 10, cacheReadTokens: 50, cacheCreationTokens: 5, costUSD: cost))
        }
        let t = ModelUsageLog.totals([e(.decider, 60), e(.decider, 86400 * 3), e(.jev, 86400 * 30), e(.cards, 3600)], now: now, calendar: cal)
        #expect(t[.today]?[.decider]?.calls == 1 && t[.week]?[.decider]?.calls == 2 && t[.all]?[.decider]?.input == 200)
        #expect(t[.today]?[.jev] == nil && t[.all]?[.jev]?.calls == 1 && t[.today]?[.cards]?.cacheRead == 50)
        #expect(abs((t[.week]?[.decider]?.cost ?? 0) - 0.02) < 1e-9)
    }

    @Test func aCallWithoutACostIsPricedAndJevAtHisRate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ModelUsageLog(url: dir.appendingPathComponent("u.jsonl"))
        log.record(role: .cards, model: "claude-haiku-5-5", ModelUsage(inputTokens: 1_000_000, outputTokens: 1_000_000))
        JevClient.recordUsage(Data(#"{"model":"jev-1.14.0","answers":{},"usage":{"input_tokens":1000000,"output_tokens":12}}"#.utf8), log: log)
        log.flush()
        let es = log.entries()
        #expect(es.count == 2 && abs((es[0].usage.costUSD ?? 0) - 0.6) < 1e-9)
        #expect(es[1].role == .jev && abs((es[1].usage.costUSD ?? 0) - 0.042) < 1e-9 && es[1].usage.outputTokens == 12)
    }
}

// MARK: - The open card

extension DeciderContextTests {
    static func buildWith(_ message: String, threads: [ContextThread], open: String? = nil) -> DeciderContext.Built {
        let index = ThreadIndex()
        for t in threads { index.put(t.key, title: t.title, text: t.said, stamp: "1") }
        var x = DeciderContext.Inputs(projects: ["harbor", "fjord"], purposes: [:], threads: threads, index: index, now: now, zone: zone)
        x.open = open
        return DeciderContext.build(message, x)
    }

    @Test func theOpenCardIsOneLineInTheNowBlockAndWithoutItNothingChanges() {
        let ts = [Self.thread("a", title: "Tide table import"), Self.thread("b", title: "Chart tiles")]
        let plain = Self.buildWith("fix the trailing comma", threads: ts)
        let open = Self.buildWith("fix the trailing comma", threads: ts, open: "b")
        let id = DeciderContext.ids(ts)["b"]!
        #expect(open.blocks[2].contains("The owner has the card of \(id) open (harbor, Chart tiles)."))
        #expect(!plain.user.contains("The owner has the card"))
        // Only the Now block moves: the cached prefix is the same bytes, and the request is another one.
        #expect(open.blocks[0] == plain.blocks[0] && open.blocks[1] == plain.blocks[1] && open.key != plain.key)
        // A thread the context doesn't know is no prior.
        let unknown = Self.buildWith("fix the trailing comma", threads: ts, open: "zzz")
        #expect(unknown.user == plain.user && unknown.key == plain.key)
    }
}
