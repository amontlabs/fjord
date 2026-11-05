import Foundation
import Testing
@testable import Fjord

/// What the inbox keeps between launches, and how a click on its notifications finds a thing.
@MainActor
@Suite(.serialized) struct InboxPersistence {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fjord-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func baselinesAndResolvedReposAreKeptAndMarksAreOnlyMarks() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let category = InboxFixture.category()
        let resolved = Date(timeIntervalSince1970: 1_800_000_000)

        let first = Store()
        first.stateFile = file
        first.categories = [category]
        first.categoryBaselines = [category.id: Set(category.rules.map(\.id))]
        first.ownedRepos = ["me/own"]
        first.contributedRepos = ["o/c"]
        first.reposResolvedAt = resolved
        first.things = ["pr:a/one#1": InboxFixture.pr(1)]
        first.marks = ["pr:a/one#1": EntryMarks(seen: ["greptile:3"])]
        first.save()
        first.flushSave()

        let second = Store()
        second.stateFile = file
        second.load()
        #expect(second.categoryBaselines == [category.id: Set(category.rules.map(\.id))])
        #expect(second.ownedRepos == ["me/own"] && second.contributedRepos == ["o/c"])
        #expect(second.reposResolvedAt == resolved)
        #expect(second.marks.keys.sorted() == ["pr:a/one#1"])
        // The editor's preview has the repos a rule names without waiting for a refresh.
        #expect(second.inboxContext.contributedRepos == ["o/c"])
    }

    @Test func theStateReadEarlyOffTheMainThreadLoadsAsTheStateReadThen() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let category = InboxFixture.category()
        let first = Store()
        first.stateFile = file
        first.categories = [category]
        first.things = ["pr:a/one#1": InboxFixture.pr(1)]
        first.marks = ["pr:a/one#1": EntryMarks(seen: ["greptile:3"])]
        first.flushSave()

        Store.readSavedStateEarly(at: file)
        let second = Store()
        second.stateFile = file
        second.load()
        #expect(second.categories.map(\.id) == [category.id])
        #expect(second.things.keys.sorted() == ["pr:a/one#1"] && second.marks.keys.sorted() == ["pr:a/one#1"])

        // Taken once: a file that doesn't decode, read early, is kept aside as one read then would be.
        try Data("not json".utf8).write(to: file)
        Store.readSavedStateEarly(at: file)
        let third = Store()
        third.stateFile = file
        var keptAside: Data?
        third.keepAsideStandIn = { data, _ in keptAside = data; return "state.json.bak" }
        third.load()
        #expect(keptAside == Data("not json".utf8))
        #expect(third.categories == InboxStore.defaultCategories)
    }

    @Test func aDoneOrACategoryEditIsKeptByQuittingBeforeAnyPoll() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let category = InboxFixture.category()

        let first = Store()
        first.stateFile = file
        first.load()
        // No poll and no `save()`: only the edits themselves, then quitting.
        first.categories = [category]
        first.marks = ["pr:a/one#1": EntryMarks(seen: ["greptile:3"])]
        first.flushSave()

        let second = Store()
        second.stateFile = file
        second.load()
        #expect(second.categories.map(\.id) == [category.id])
        #expect(second.marks.keys.sorted() == ["pr:a/one#1"])
    }

    @Test func theSavedRulesSayTheirFirstKindForBuildsFromBeforeKinds() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let store = Store()
        store.stateFile = file
        store.categories = [InboxCategory(name: "Both", symbol: "tray", color: .blue, rules: [Rule(scope: Scope(kinds: [.issue, .pr]))])]
        store.flushSave()
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let scope = ((saved["categories"] as? [[String: Any]])?.first?["rules"] as? [[String: Any]])?.first?["scope"] as? [String: Any]
        #expect(scope?["kind"] as? String == "pr" && scope?["kinds"] as? [String] == ["pr", "issue"])
    }

    @Test func aWriteThatFailedIsNotCountedAsSavedAndQuittingTriesAgain() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Its folder isn't there yet: writing fails.
        let file = folder.appendingPathComponent("gone", isDirectory: true).appendingPathComponent("state.json")

        let first = Store()
        first.stateFile = file
        first.marks = ["pr:a/one#1": EntryMarks(seen: ["greptile:3"])]
        first.flushSave()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // The folder is back: the change still pending is written, though nothing changed since.
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        first.flushSave()

        let second = Store()
        second.stateFile = file
        second.load()
        #expect(second.marks.keys.sorted() == ["pr:a/one#1"])
    }

    /// The first inbox's file (fed5f6c): categories with no `actions` or `section`, rules with one `kind`, things with no
    /// `behindBase`, `headSha` or `reviewRequests`, and no sections.
    static let firstInboxFile = #"""
    {"settings": {"pollInterval": 60, "notifications": true},
     "categories": [{"id": "0E7C1A52-6A3B-4C59-9E0D-1F2A3B4C5D6E", "name": "Reviews", "symbol": "eye", "color": "violet",
                     "rules": [{"id": "5B0F3D9E-2C7A-4E1B-8F6D-7A8B9C0D1E2F", "scope": {"kind": "pr", "toRoles": ["reviewRequested"]},
                                "match": "any", "conditions": [], "createdAt": "2026-10-10T09:00:00Z"}],
                     "notifies": false, "hidden": false, "isCI": false}],
     "groups": [{"id": "9D8C7B6A-5F4E-4D3C-8B2A-1F0E9D8C7B6A", "name": "Friends", "kind": "people", "members": ["octo"]}],
     "things": {"pr:a/one#1": {"id": "pr:a/one#1", "kind": "pr", "repo": "a/one", "number": 1, "title": "Fix the build",
                               "url": "https://github.com/a/one/pull/1", "status": "open", "labels": [], "assignees": [],
                               "requestedReviewers": ["me"], "mentioned": [], "createdAt": "2026-10-09T09:00:00Z",
                               "updatedAt": "2026-10-10T09:00:00Z", "comments": [], "reviews": [], "threads": [], "commits": [],
                               "hasConflicts": false, "failingJobs": []}},
     "marks": {"pr:a/one#1": {"seen": ["k"], "acked": ["k"], "notified": ["k"], "doneAt": "2026-10-10T10:00:00Z"}},
     "categoryBaselines": ["0E7C1A52-6A3B-4C59-9E0D-1F2A3B4C5D6E", ["5B0F3D9E-2C7A-4E1B-8F6D-7A8B9C0D1E2F"]],
     "ownedRepos": ["me/own"], "contributedRepos": [], "reposResolvedAt": "2026-10-10T08:00:00Z"}
    """#

    @Test func aThingKeepsEveryFieldThroughAWriteAndARead() throws {
        var thing = InboxFixture.pr(4, updated: Date(timeIntervalSince1970: 1_700_000_500))
        thing.assignees = ["me"]
        thing.assignedAt = ["me": Date(timeIntervalSince1970: 1_700_000_000)]
        thing.reviewRequests = [ThingReviewRequest(reviewer: "me", at: Date(timeIntervalSince1970: 1_700_000_100))]
        thing.behindBase = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Thing.self, from: encoder.encode(thing))
        #expect(back.assignedAt == thing.assignedAt)
        #expect(back == thing)
    }

    @Test func theFirstInboxsFileKeepsItsCategoriesThingsAndMarks() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        try Data(Self.firstInboxFile.utf8).write(to: file)
        let store = Store()
        store.stateFile = file
        store.load()
        #expect(store.categories.map(\.name) == ["Reviews"])
        #expect(store.categories.first?.actions.isEmpty == true && store.categories.first?.notifies == false)
        #expect(store.categories.first?.rules.first?.scope.kinds == [.pr])
        #expect(store.groups.map(\.members) == [["octo"]])
        #expect(store.things["pr:a/one#1"]?.behindBase == false && store.things["pr:a/one#1"]?.reviewRequests == [])
        #expect(store.marks["pr:a/one#1"]?.acked == ["k"])
        #expect(store.categorySections == [.github])
        #expect(store.categoryBaselines.count == 1)
        // Nothing was lost: nothing is kept aside.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["state.json"])
    }

    @Test func aFileReadOnlyInPartIsKeptAsideBeforeItIsWrittenOver() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let original = Data(#"{"settings": {"pollInterval": 45, "notifications": true}, "categories": [{"name": 5}]}"#.utf8)
        try original.write(to: file)
        let store = Store()
        store.stateFile = file
        store.load()
        store.marks = ["pr:a/one#1": EntryMarks(seen: ["k"])]
        store.flushSave()
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("state.json.bak-") }
        #expect(backups.count == 1)
        #expect(try backups.first.map { try Data(contentsOf: folder.appendingPathComponent($0)) } == original)

        // A file that isn't read at all is kept aside too.
        let other = try self.folder()
        defer { try? FileManager.default.removeItem(at: other) }
        try Data("not json".utf8).write(to: other.appendingPathComponent("state.json"))
        let second = Store()
        second.stateFile = other.appendingPathComponent("state.json")
        second.load()
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).contains { $0.hasPrefix("state.json.bak-") })
    }

    @Test func theSameDamagedFileIsKeptAsideOnceAndOnlyTheLatestCopiesStay() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        func backups() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("state.json.bak-") }.sorted()
        }
        // Launch after launch with the same damaged file: one copy.
        for _ in 0..<3 {
            try Data("not json".utf8).write(to: file)
            let store = Store()
            store.stateFile = file
            store.load()
        }
        #expect(try backups().count == 1)
        // Distinct damaged files: the latest five stay.
        for n in 0..<7 {
            try Data("not json \(n)".utf8).write(to: file)
            let store = Store()
            store.stateFile = file
            store.load()
        }
        let kept = try backups()
        #expect(kept.count == Store.maxBackups)
        #expect(try kept.map { String(decoding: try Data(contentsOf: folder.appendingPathComponent($0)), as: UTF8.self) }.sorted()
                == (2..<7).map { "not json \($0)" })
    }

    @Test func aFileThatCouldNotBeKeptAsideIsNotWrittenOverUntilItIs() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let original = Data(#"{"settings": {"pollInterval": 45, "notifications": true}, "categories": [{"name": 5}]}"#.utf8)
        try original.write(to: file)
        struct Full: Error {}
        let store = Store()
        store.stateFile = file
        store.keepAsideStandIn = { _, _ in throw Full() }
        store.load()
        store.marks = ["pr:a/one#1": EntryMarks(seen: ["k"])]
        store.flushSave()
        // The copy failed, launch and save alike: the original stays as it was, and the change waits in memory.
        #expect(try Data(contentsOf: file) == original)
        #expect(store.marks.keys.sorted() == ["pr:a/one#1"])
        // The copy can be made: it is, then the change is written.
        store.keepAsideStandIn = nil
        store.flushSave()
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("state.json.bak-") }
        #expect(try backups.map { try Data(contentsOf: folder.appendingPathComponent($0)) } == [original])
        let second = Store()
        second.stateFile = file
        second.load()
        #expect(second.marks.keys.sorted() == ["pr:a/one#1"])
    }

    @Test func aFileThatIsThereButCannotBeReadIsNotWrittenOverUntilItCanBeAndIsKeptAside() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let original = Data(#"{"settings": {"pollInterval": 45, "notifications": true}}"#.utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let store = Store()
        store.stateFile = file
        store.load()
        store.marks = ["pr:a/one#1": EntryMarks(seen: ["k"])]
        store.flushSave()
        // Unreadable isn't absent: the only copy stays as it was.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["state.json"])
        // Readable again: it is kept aside, then the change is written.
        store.flushSave()
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("state.json.bak-") }
        #expect(try backups.map { try Data(contentsOf: folder.appendingPathComponent($0)) } == [original])
        let second = Store()
        second.stateFile = file
        second.load()
        #expect(second.marks.keys.sorted() == ["pr:a/one#1"])
    }

    @Test func aSaveThatCannotBeMadeIsSaidUntilOneIs() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        try Data(#"{"settings": {"pollInterval": 45, "notifications": true}}"#.utf8).write(to: file)
        let actions = folder.appendingPathComponent("actions.json")
        try Data(#"{"baselines": {}, "runs": {}}"#.utf8).write(to: actions)
        for url in [file, actions] { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path) }
        defer { for url in [file, actions] { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) } }
        let store = Store()
        store.stateFile = file
        store.load()
        // Unreadable: running on defaults, said from the start, the ledger's file too.
        #expect(store.stateSaveProblem?.contains("Running on defaults until the file can be read") == true)
        #expect(store.actionsSaveProblem?.contains("actions.json") == true)
        store.marks = ["pr:a/one#1": EntryMarks(seen: ["k"])]
        store.flushSave()
        #expect(store.stateSaveProblem?.contains("Running on defaults until the file can be read") == true)
        // Readable again: once a save works, nothing is said.
        for url in [file, actions] { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        store.flushSave()
        store.saveActions()
        store.flushActions()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.saveProblem == nil)
        // A write that fails (a full disk, a folder it can't write in) is said too, until one works.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        store.marks = [:]
        store.flushSave()
        store.saveActions()
        store.flushActions()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.stateSaveProblem?.hasPrefix("Saving state.json failed") == true)
        #expect(store.stateSaveProblem?.contains("Running on defaults") == false)
        #expect(store.actionsSaveProblem?.hasPrefix("Saving actions.json failed") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        store.flushSave()
        store.saveActions()
        store.flushActions()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.saveProblem == nil)
    }

    @Test func oneElementThatNoLongerDecodesIsLostAloneNotItsWholeList() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let good = InboxFixture.category()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try enc.encode(value), as: UTF8.self) }
        let decision = RouterDecision(at: Date(timeIntervalSince1970: 1_800_000_000), trigger: .you("hi"), outcome: .done)
        try Data("""
        {"settings": {"pollInterval": 60, "notifications": true},
         "categories": [\(try json(good)), {"name": 5}],
         "groups": [{"name": "broken"}, \(try json(InboxGroup(name: "Friends", kind: .people, members: ["octo"])))],
         "things": {"pr:a/one#1": \(try json(InboxFixture.pr(1))), "pr:a/one#2": {"id": 2}},
         "marks": {"pr:a/one#1": {"seen": ["k"]}, "pr:a/one#2": {"seen": 5}},
         "router": {"decisions": [\(try json(decision)), {"at": 5}], "changes": [{"nope": true}]}}
        """.utf8).write(to: file)
        let store = Store()
        store.stateFile = file
        store.load()
        #expect(store.categories.map(\.id) == [good.id])
        #expect(store.groups.map(\.name) == ["Friends"])
        #expect(store.things.keys.sorted() == ["pr:a/one#1"] && store.marks.keys.sorted() == ["pr:a/one#1"])
        #expect(store.router.decisions == [decision])
        // What was lost is kept aside, in the file as it was.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("state.json.bak-") })
    }

    @Test func aLossInTheRouterAloneKeepsTheFileAside() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let decision = RouterDecision(at: Date(timeIntervalSince1970: 1_800_000_000), trigger: .you("hi"), outcome: .done)
        let original = Data("""
        {"settings": {"pollInterval": 60, "notifications": true},
         "router": {"enabled": true, "decisions": [\(String(decoding: try enc.encode(decision), as: UTF8.self)), {"at": 5}]}}
        """.utf8)
        try original.write(to: file)
        let state = try { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return try d.decode(PersistedState.self, from: original) }()
        #expect(state.dropped == ["router: 1 of decisions"])
        #expect(state.router?.dropped == [])
        let store = Store()
        store.stateFile = file
        store.load()
        #expect(store.router.enabled && store.router.decisions == [decision])
        store.marks = ["pr:a/one#1": EntryMarks(seen: ["k"])]
        store.flushSave()
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("state.json.bak-") }
        #expect(try backups.map { try Data(contentsOf: folder.appendingPathComponent($0)) } == [original])
    }

    /// The launch migration: a file of the card model (its cards, waits, summaries, brief) loads with none of it lost
    /// aside, and the next save writes only what the Router keeps now.
    @Test func theCardModelsStateIsDroppedAtLaunch() throws {
        let decision = RouterDecision(at: Date(timeIntervalSince1970: 1_800_000_000), trigger: .you("hi"), outcome: .done)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let old = Data("""
        {"enabled": true, "decisions": [\(String(decoding: try enc.encode(decision), as: UTF8.self))],
         "cards": [{"id": "s#t1", "sessionID": "s", "kind": "question"}], "waits": {"s": 12}, "overviews": [{"at": 5}],
         "lives": {}, "seen": {"s": "x"}, "pendingTurns": {}, "heldWaits": {}, "digest": {"at": 5}, "chat": [{"text": "hi"}]}
        """.utf8)
        let state = try dec.decode(RouterSaved.self, from: old)
        #expect(state.dropped.isEmpty && state.enabled && state.decisions == [decision])
        let saved = try JSONSerialization.jsonObject(with: try enc.encode(state)) as? [String: Any] ?? [:]
        #expect(Set(saved.keys) == ["enabled", "changes", "decisions", "runsOnProjects", "pendingDesktopStarts",
                                    "guestRelayDeliveries", "guestPendingForms", "pendingGuestDisables", "pendingGuestRemovals",
                                    "operations"])
    }

    @Test func aChangeWhoseEntryIsLostGetsAnEntryOfItsOwn() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try enc.encode(value), as: UTF8.self) }
        var waiting = FjordChange(date: Date(timeIntervalSince1970: 1_800_000_000), title: "Changed the order",
                                    patch: .order(before: [], after: []))
        waiting.pending = "made by the Router"
        let applied = FjordChange(date: Date(timeIntervalSince1970: 1_800_000_100), title: "Changed the order back",
                                    patch: .order(before: [], after: []))
        let linked = RouterDecision(at: Date(timeIntervalSince1970: 1_800_000_200), trigger: .you("hi"), outcome: .done)
        // Its entry can't be read: the change waiting for your Apply is still reached, through an entry of
        // Fjord's.
        let state = try dec.decode(RouterSaved.self, from: Data("""
        {"changes": [\(try json(waiting)), \(try json(applied))], "decisions": [{"at": 5}, \(try json(linked))]}
        """.utf8))
        #expect(state.dropped == ["1 of decisions"])
        #expect(state.decisions.map(\.links.changes) == [[waiting.id], []])
        #expect(state.decisions.first?.trigger == .system && state.decisions.first?.at == waiting.date)
    }

    @Test func aRunUnderWayWhenTheAppQuitSaysItWasInterrupted() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let first = Store()
        first.stateFile = file
        let working = first.logDecision(RouterDecision(trigger: .you("fix the bug")))
        let finished = first.logDecision(RouterDecision(trigger: .you("hi"), done: [.sent(to: "a", text: "hi", original: nil)], outcome: .done))
        first.flushSave()
        let second = Store()
        second.stateFile = file
        second.load()
        let entry = second.router.decisions.first { $0.id == working }
        #expect(entry?.outcome == .done && entry?.done == [.failed("interrupted")] && entry?.summary == "failed")
        #expect(second.router.decisions.first { $0.id == finished }?.done == [.sent(to: "a", text: "hi", original: nil)])
    }

    @Test func aFileFromBeforeTheCategoriesLoadsWhatItCanAndLosesTheRest() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        try Data(#"""
        {"repos": [{"fullName": "a/one", "events": ["prComment"], "cursors": {}, "addedAt": "2026-01-01T00:00:00Z", "allComments": true}],
         "items": [{"id": "x", "repo": "a/one", "kind": "prComment", "number": 1, "title": "t", "snippet": "", "author": "u",
                    "authorIsApp": false, "url": "https://github.com/a/one", "createdAt": "2026-01-01T00:00:00Z", "state": "unread"}],
         "ci": {"a/one": {"state": "failure", "branch": "main", "failing": ["build"], "checkedAt": "2026-01-01T00:00:00Z"}},
         "settings": {"botHandles": ["vercel"], "treatAppsAsBots": true, "pollInterval": 30, "notifications": false,
                      "reviewRequests": true, "didInitialReviewSync": true}}
        """#.utf8).write(to: file)
        let store = Store()
        store.stateFile = file
        store.load()
        #expect(store.settings.pollInterval == 30 && !store.settings.notifications)
        #expect(store.things.isEmpty && store.marks.isEmpty && store.groups.isEmpty)
        // The default categories stand.
        #expect(store.categories.map(\.name) == ["My repos"])
    }

    @Test func theRulesAboutYouMatchAtLaunchBeforeGitHubSaysWhoYouAre() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let mine = InboxCategory(name: "My repos", symbol: "folder", color: .blue,
                                 rules: [Rule(scope: Scope(kinds: [.pr, .issue], in: Pick(include: [.owned])))])
        let first = Store()
        first.stateFile = file
        first.categories = [mine]
        first.things = ["pr:me/old#1": InboxFixture.pr(1, repo: "me/old")]
        first.me = GHUser(login: "me", avatarUrl: nil, type: nil)
        first.save()
        first.flushSave()

        let second = Store()
        second.stateFile = file
        second.load()
        #expect(second.me == nil)
        #expect(second.entries(in: mine.id).map(\.id) == ["pr:me/old#1"])
    }

    @Test func aPartThatNoLongerDecodesIsLostAlone() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        try Data(#"{"settings": {"pollInterval": 45, "notifications": true}, "categories": [{"name": 5}], "groups": []}"#.utf8).write(to: file)
        let store = Store()
        store.stateFile = file
        store.load()
        #expect(store.settings.pollInterval == 45)
        #expect(store.categories.map(\.name) == ["My repos"])
    }

    // MARK: Notification clicks

    @Test func aClickOnAThingsBannerOpensItsCategoryWithItSelected() {
        let category = InboxFixture.category()
        let store = InboxFixture.store([InboxFixture.pr(7)], category: category)
        var opened: [(UUID?, String?)] = []
        store.onOpenInbox = { opened.append(($0, $1)) }
        store.openNotification(id: "inbox:pr:a/one#7", url: "https://github.com/a/one/pull/7")
        #expect(opened.count == 1 && opened[0].0 == category.id && opened[0].1 == "pr:a/one#7")
    }

    @Test func aSummaryOpensTheInboxAndAGoneThingDoesNot() {
        let store = InboxFixture.store([InboxFixture.pr(7)])
        var opened = 0
        store.onOpenInbox = { category, thing in opened += 1; #expect(category == nil && thing == nil) }
        store.openNotification(id: Notifier.summaryPrefix + "x", url: nil)
        #expect(opened == 1)
        // A thing no rule holds any more is not in the inbox: the inbox does not open on it.
        store.openNotification(id: "inbox:pr:a/one#99", url: nil)
        #expect(opened == 1)
    }
}
