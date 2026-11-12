import Foundation
import Testing
@testable import Fjord

/// A thread's pull requests for Router v2's card: T3's first, the named ones linked once, GitHub for the rest.
@MainActor
@Suite struct RouterPullRequestsTests {
    final class Links: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String] = []
        var fail = false
        func add(_ s: String) { lock.lock(); sent.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return sent }
    }
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var refs: [PullRequestRef] = []
        func add(_ r: PullRequestRef) { lock.lock(); refs.append(r); lock.unlock() }
        var all: [PullRequestRef] { lock.lock(); defer { lock.unlock() }; return refs }
    }

    private func thread(_ id: String = "t1", repo: String? = "acme/garden", linked: [(String, String?)] = []) -> AgentThread {
        var t = AgentThread(id: id, title: "T", folder: "/code/app")
        t.repo = repo
        t.pullRequests = linked.map { url, state in
            T3PullRequest(json: ["url": .string(url), "snapshot": ["state": state.map(T3JSON.string) ?? nil, "number": 1]])
        }
        return t
    }

    private func make(links: Links = Links(), asked: Asked = Asked(), github: [String: PRState] = [:], linkable: Bool = true)
        -> RouterPullRequests {
        let gh = PullRequestStates(minInterval: 0, fetch: { ref in
            asked.add(ref)
            return github["\(ref.repo)#\(ref.number)"] ?? .unknown
        })
        let r = RouterPullRequests(link: linkable ? { thread, url in
            links.add("\(thread) \(url)")
            if links.fail { throw URLError(.notConnectedToInternet) }
        } : nil, github: gh)
        return r
    }

    /// Runs the main actor's queue until `done`.
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func t3sStateComesFirstAndNothingIsAskedOfGitHub() async {
        let asked = Asked()
        let r = make(asked: asked)
        let t = thread(linked: [("https://github.com/acme/garden/pull/12", "MERGED"), ("https://github.com/acme/garden/pull/13", "open")])
        let prs = r.states(for: t, reply: nil)
        #expect(prs.map(\.state) == [.merged, .open])
        #expect(prs.map(\.number) == [12, 13])
        try? await Task.sleep(for: .milliseconds(30))
        #expect(asked.all.isEmpty)
    }

    @Test func aNamedPullRequestIsLinkedOnceAndLeftOutUntilItsStateIsKnown() async {
        let links = Links()
        let r = make(links: links)
        let t = thread()
        let reply = "Opened https://github.com/acme/garden/pull/40 for review."
        #expect(r.states(for: t, reply: reply).isEmpty)
        #expect(r.states(for: t, reply: reply).isEmpty)
        await settle { !links.all.isEmpty }
        _ = r.states(for: t, reply: reply)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(links.all == ["t1 https://github.com/acme/garden/pull/40"])

        // T3 now carries it.
        let after = thread(linked: [("https://github.com/acme/garden/pull/40", "OPEN")])
        #expect(r.states(for: after, reply: reply).map(\.state) == [.open])
        #expect(links.all.count == 1)
    }

    @Test func aFailedLinkFallsToGitHubAndTellsThePage() async {
        let links = Links(); links.fail = true
        let asked = Asked()
        let r = make(links: links, asked: asked, github: ["garden#41": .merged])
        var changed: [String] = []
        r.onChange = { changed.append($0) }
        let t = thread()
        let reply = "See github.com/acme/garden/pull/41"
        #expect(r.states(for: t, reply: reply).isEmpty)
        await settle { !changed.isEmpty }
        // The failed link recomposes the record, which now asks GitHub.
        #expect(r.states(for: t, reply: reply).isEmpty)
        await settle { r.states(for: t, reply: reply).first?.state == .merged }
        #expect(r.states(for: t, reply: reply).map(\.state) == [.merged])
        #expect(asked.all.map(\.number) == [41])
        #expect(changed.contains("t1"))
    }

    @Test func withoutALinkTheNamedOnesAreReadFromGitHubAtOnce() async {
        let r = make(github: ["garden#7": .open], linkable: false)
        var changed: [String] = []
        r.onChange = { changed.append($0) }
        let reply = "https://github.com/acme/garden/pull/7"
        #expect(r.states(for: thread(), reply: reply).isEmpty)
        await settle { !changed.isEmpty }
        #expect(r.states(for: thread(), reply: reply).map(\.state) == [.open])
    }

    @Test func aPullRequestOfAnotherRepositoryIsNotLinked() async {
        let links = Links()
        let r = make(links: links, github: ["other#5": .closed])
        var changed: [String] = []
        r.onChange = { changed.append($0) }
        let reply = "Related: https://github.com/someone/other/pull/5"
        _ = r.states(for: thread(), reply: reply)
        await settle { !changed.isEmpty }
        #expect(links.all.isEmpty)
        #expect(r.states(for: thread(), reply: reply).map(\.state) == [.closed])
    }

    @Test func aPullRequestBothLinkedAndNamedShowsOnce() async {
        let links = Links()
        let r = make(links: links)
        let t = thread(linked: [("https://github.com/acme/garden/pull/12", "OPEN")])
        let prs = r.states(for: t, reply: "Done: https://github.com/acme/garden/pull/12/files")
        #expect(prs.map(\.number) == [12])
        try? await Task.sleep(for: .milliseconds(30))
        #expect(links.all.isEmpty)
    }
}
