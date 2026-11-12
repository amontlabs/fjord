import Foundation

/// A thread's pull requests for Router v2's card (docs/design/router-v2/IMPLEMENTATION.md 1.7): the ones T3 links to it
/// (their state pushed with the thread), and the ones its last reply names, which are linked in T3 once so T3 polls them too.
/// A state T3 doesn't give is asked of GitHub (`PullRequestStates`): when a pull request is first seen, and on `refresh()`
/// (Triage's own sync turn, the window opening). No timer.
///
/// `states(for:reply:)` is cheap enough for the shell's hot path: it parses a reply only when the reply changed and reads
/// dictionaries otherwise. A pull request whose state isn't known yet is left out rather than drawn with a guessed state.
@MainActor
final class RouterPullRequests {
    /// Links `url` to the thread in T3 (`T3Command.pullRequestLink`); throws when T3 refuses or is away.
    typealias Link = @Sendable (_ thread: String, _ url: String) async throws -> Void

    /// A thread's pull requests changed: compose its record again.
    var onChange: ((String) -> Void)?

    private let link: Link?
    private let github: PullRequestStates?

    /// A pull request a reply names, per thread: the reply it was read from, and what it names.
    private var named: [String: (reply: String, refs: [PullRequestRef])] = [:]
    private var linking = Set<Key>()
    private var linked = Set<Key>()
    private var failed = Set<Key>()
    /// What GitHub said, per pull request.
    private var fetched: [PullRequestRef: PRState] = [:]
    private var asked = Set<PullRequestRef>()
    /// The threads that show each pull request (to tell them when its state moves).
    private var threads: [PullRequestRef: Set<String>] = [:]

    private struct Key: Hashable { var thread: String; var ref: PullRequestRef }

    /// `link`: nil when T3 can't take it (every named pull request is then read from GitHub). `github`: nil asks no one.
    init(link: Link?, github: PullRequestStates?) {
        self.link = link
        self.github = github
    }

    /// The pull requests of `thread`, linked in T3 and named in `reply` (its last message), with their states.
    func states(for thread: AgentThread, reply: String?) -> [RouterV2Thread.PR] {
        var refs: [(ref: PullRequestRef, t3: PRState?)] = []
        var seen = Set<PullRequestRef>()
        for pr in thread.pullRequests {
            guard let ref = PullRequestRef.extract(from: pr.url).first, seen.insert(ref).inserted else { continue }
            refs.append((ref, pr.state.flatMap { PRState(rawValue: $0.lowercased()) }.flatMap { $0 == .unknown ? nil : $0 }))
        }
        for ref in namedRefs(thread.id, reply) where seen.insert(ref).inserted {
            refs.append((ref, nil))
            if sameRepository(ref, thread.repo) { linkOnce(Key(thread: thread.id, ref: ref)) }
        }

        var out: [RouterV2Thread.PR] = []
        var numbers = Set<Int>()
        for (ref, fromT3) in refs {
            threads[ref, default: []].insert(thread.id)
            var state = fromT3
            if state == nil {
                if !linking.contains(Key(thread: thread.id, ref: ref)) { ask(ref) }
                state = fetched[ref].flatMap { $0 == .unknown ? nil : $0 }
            }
            guard let state, let shown = RouterV2Thread.PR.State(rawValue: state.rawValue),
                  numbers.insert(ref.number).inserted else { continue }
            out.append(.init(number: ref.number, state: shown))
        }
        return out
    }

    /// Asks GitHub again about every open pull request seen so far (a final one is never fetched again).
    func refresh() {
        guard let github else { return }
        let open = threads.keys.filter { fetched[$0]?.isFinal != true }
        guard !open.isEmpty else { return }
        Task { [weak self] in self?.fetchedStates(await github.refresh(open)) }
    }

    /// Forgets a thread that left the page.
    func forget(_ thread: String) {
        named[thread] = nil
        for ref in threads.keys { threads[ref]?.remove(thread) }
    }

    // MARK: Inside

    private func namedRefs(_ thread: String, _ reply: String?) -> [PullRequestRef] {
        guard let reply, !reply.isEmpty else { named[thread] = nil; return [] }
        if let held = named[thread], held.reply == reply { return held.refs }
        let refs = PullRequestRef.extract(from: reply)
        named[thread] = (reply, refs)
        return refs
    }

    private func sameRepository(_ ref: PullRequestRef, _ repo: String?) -> Bool {
        guard let repo else { return true }
        return "\(ref.owner)/\(ref.repo)" == repo.lowercased()
    }

    /// Links a named pull request in T3, once per thread; a refusal sends it to GitHub.
    private func linkOnce(_ key: Key) {
        guard let link, !linking.contains(key), !linked.contains(key), !failed.contains(key) else { return }
        linking.insert(key)
        let url = key.ref.url.absoluteString
        Task { [weak self] in
            let ok: Bool
            do { try await link(key.thread, url); ok = true } catch { ok = false }
            self?.linkFinished(key, ok)
        }
    }

    private func linkFinished(_ key: Key, _ ok: Bool) {
        linking.remove(key)
        if ok { linked.insert(key) } else { failed.insert(key) }
        // T3 pushes the linked pull request's state with the thread; a failed link is read from GitHub now.
        onChange?(key.thread)
    }

    private func ask(_ ref: PullRequestRef) {
        guard let github, asked.insert(ref).inserted else { return }
        Task { [weak self] in self?.fetchedStates(await github.refresh([ref])) }
    }

    private func fetchedStates(_ changed: [PullRequestRef: PRState]) {
        var touched = Set<String>()
        for (ref, state) in changed where fetched[ref] != state && state != .unknown {
            fetched[ref] = state
            touched.formUnion(threads[ref] ?? [])
        }
        for thread in touched { onChange?(thread) }
    }
}
