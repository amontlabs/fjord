import Foundation

// Every call to Jev goes through one gate: a key TypeSafe rejected isn't used again until a new key is saved, a busy
// TypeSafe is left alone for as long as it says (Retry-After), and other failures back off, longer each time in a row. Each
// use (routing, triage, cards, icons, the inbox, actions) also needs its switch on, and the key it started with, both when
// it asks and when the answer comes back: a key removed or a switch turned off meanwhile sends nothing more, and what comes
// back is dropped.

/// What Jev is asked for, each with its own switch.
enum JevUse {
    /// Where a message you send goes.
    case routing
    /// Sessions' icons.
    case icons
    /// The inbox's new comments and requests.
    case inbox
    /// The clone a session an inbox action starts works in (it reads the item, so the inbox's switch too).
    case actions
    /// A category's or a section's icon.
    case categoryIcons
}

@MainActor final class JevGate {
    /// The clock (tests move it).
    var now: () -> Date = Date.init
    /// What sends Jev's requests (tests answer for TypeSafe); the network otherwise.
    var transport: JevClient.Transport?
    /// The first wait after a failure, doubled for each one after it in a row, up to `longest`.
    static let shortest: TimeInterval = 30
    static let longest: TimeInterval = 30 * 60

    /// Changes whenever the key does: what was asked with another key is dropped.
    private(set) var generation = 0
    /// The key TypeSafe rejected ("" for a test's stand-in): not used again until another is saved.
    private(set) var rejected: String?
    /// No call before this, and why.
    private(set) var until = Date.distantPast
    private(set) var paused: JevClient.Failure?
    /// Failures in a row (rate limits and overloads included).
    private(set) var failures = 0
    /// Counts the pauses failures put in: a call that worked doesn't lift one put in after it was let through.
    private(set) var pauses = 0

    /// Told when a call made in its task is let through the gate (`Store.throughJevGate`): a call refused at the gate was
    /// never sent, and is not a failure of what it asked about.
    final class Admission: @unchecked Sendable {
        private(set) var sent = false
        func letThrough() { sent = true }
    }

    @TaskLocal static var admission: Admission?

    /// Throws why no call may go now with `key`.
    func admit(key: String) throws {
        if let rejected, rejected == key { throw JevClient.Failure.unauthorized }
        if now() < until { throw paused ?? JevClient.Failure.transport("TypeSafe is paused") }
    }

    /// Whether a call with `key` may go now.
    func isOpen(for key: String) -> Bool { (try? admit(key: key)) != nil }

    /// A call worked: everything starts over, unless (`since`: the `pauses` it was let through at) a failure paused calls
    /// meanwhile, as an older call worked before TypeSafe said to wait.
    func succeeded(since: Int? = nil) {
        if let since, since != pauses { return }
        failures = 0
        until = .distantPast
        paused = nil
    }

    /// What a failure means for the next calls. Only TypeSafe's own failures count (a test's other errors don't).
    func failed(_ error: Error, key: String) {
        guard let failure = error as? JevClient.Failure else { return }
        switch failure {
        case .unauthorized:
            rejected = key
        case .rateLimited(let after), .overloaded(let after):
            failures += 1
            pause(after ?? backoff, failure)
        case .transport:
            failures += 1
            pause(backoff, failure)
        case .cancelled, .refused, .invalidAnswer:
            break
        }
    }

    /// A new key (or none): everything starts over, and calls made with the old one are dropped.
    func keyChanged() {
        generation &+= 1
        rejected = nil
        succeeded()
    }

    private var backoff: TimeInterval {
        min(Self.longest, Self.shortest * pow(2, Double(max(0, failures - 1))))
    }

    private func pause(_ seconds: TimeInterval, _ failure: JevClient.Failure) {
        until = max(until, now().addingTimeInterval(seconds))
        paused = failure
        pauses &+= 1
    }
}

extension Store {
    /// Whether `use` may ask Jev now: its switch (the key is the gate's to check).
    func jevAllows(_ use: JevUse) -> Bool {
        switch use {
        case .routing: routerOn
        case .icons: agents.enabled && agents.iconsEnabled
        case .inbox: jevReadsInbox
        // It reads the item (its title and what GitHub wrote): only when Jev may read the inbox.
        case .actions: toolsLinked && jevReadsInbox
        case .categoryIcons: true
        }
    }

    /// TypeSafe with `key`, through the gate's transport.
    func jevClient(_ key: String) -> JevClient {
        var client = JevClient(key: key)
        client.transport = jevGate.transport
        return client
    }

    /// One call for `use`, made with the key of `generation`: not made, or its answer or failure dropped (`cancelled`), when
    /// the key changed or the switch went off (a failure also when the task was cancelled); not made while the gate is closed;
    /// its failure tells the gate.
    func throughJevGate<T>(_ use: JevUse, generation: Int, _ call: () async throws -> T) async throws -> T {
        let key = typesafeKey ?? ""
        func allowed() throws {
            guard generation == jevGate.generation, jevAllows(use) else { throw JevClient.Failure.cancelled }
        }
        try allowed()
        try jevGate.admit(key: key)
        JevGate.admission?.letThrough()
        let pauses = jevGate.pauses
        let out: T
        do {
            out = try await call()
        } catch {
            // Asked with a key since replaced, or stopped: nothing failed (an old key's rejection says nothing of the new one).
            guard generation == jevGate.generation, !Task.isCancelled else { throw JevClient.Failure.cancelled }
            jevGate.failed(error, key: key)
            throw error
        }
        if generation == jevGate.generation { jevGate.succeeded(since: pauses) }
        try allowed()
        return out
    }

    /// Jev for `use`: `base` (a test's stand-in) or TypeSafe with the key now, through the gate. Nil with neither, or
    /// while the switch is off.
    func jevAsker(_ use: JevUse, base: JevAsker? = nil) -> JevAsker? {
        guard jevAllows(use) else { return nil }
        let generation = jevGate.generation
        let ask: JevAsker
        if let base {
            ask = base
        } else {
            guard let key = typesafeKey, !key.isEmpty else { return nil }
            var client = jevClient(key)
            // Routing waits for you: Jev answers it in about 0.25 s, so a slow answer is an outage, not a wait.
            if use == .routing { client.timeout = 2.5 }
            ask = { questions, state in try await client.ask(questions, about: state) }
        }
        return { [weak self] questions, state in
            guard let self else { throw JevClient.Failure.cancelled }
            return try await self.throughJevGate(use, generation: generation) { try await ask(questions, state) }
        }
    }

    /// Jev's pick among options for `use` (`base`: a test's stand-in), through the gate.
    func jevChooser(_ use: JevUse, base: Claude.Chooser? = nil) -> Claude.Chooser? {
        guard jevAllows(use) else { return nil }
        let generation = jevGate.generation
        let choose: Claude.Chooser
        if let base {
            choose = base
        } else {
            guard let key = typesafeKey, !key.isEmpty else { return nil }
            let client = jevClient(key)
            choose = { options, hints, state, instructions in
                try await client.choose(options, hints: hints, for: state, instructions: instructions)
            }
        }
        return { [weak self] options, hints, state, instructions in
            guard let self else { throw JevClient.Failure.cancelled }
            return try await self.throughJevGate(use, generation: generation) { try await choose(options, hints, state, instructions) }
        }
    }
}
