import Foundation

// Cancel: a message the Router delivered to a session, taken back from its history line. The session's plugin (`abort-v1`)
// gets a signed abort in its inbox naming the delivery, and answers how far it had gone (`RouterDecision.Cancelled`): not
// started (it never will), working (the turn is stopped and doesn't carry on; a command it was running finishes on its
// own, its result unseen), or over. Nothing the agent did is undone,
// and the words stay in the session's history: Claude Code can't take a submitted prompt back out.

extension Store {
    /// An abort of the delivery `cancels` for the session `target` (its CLI id), signed with the key as last read; nil when
    /// there's none (the Router is off), as for `signRelay`.
    func signAbort(target: String, cancels: String) -> String? {
        guard let paths = routerFiles else { return nil }
        if let cached = relayKeyCache, cached.matches(paths.relayKey) {
            return RelaySigner.signAbort(target: target, cancels: cancels, key: cached.key)
        }
        relayKeyCache = nil
        Task { await reloadRelayKey() }
        return nil
    }

    /// Takes a delivery back through its session's inbox, and reads how far it had gone from the plugin's answer. `gate` is
    /// asked on the main actor right before the abort is written: a reason refuses it, unwritten.
    func cancelDelivery(_ sent: RouterDecision.Delivered, gate: (@MainActor @Sendable () -> String?)? = nil) async throws -> RouterDecision.Cancelled {
        guard let paths = routerFiles else { throw RouterTools.Failure("The Router is off") }
        guard await supportsAbort(sent.cli) else {
            throw RouterTools.Failure("Fjord's plugin in the session can't cancel, or the session is gone")
        }
        var text = signAbort(target: sent.cli, cancels: sent.nonce)
        if text == nil, await reloadRelayKey() { text = signAbort(target: sent.cli, cancels: sent.nonce) }
        guard let text else { throw RouterTools.Failure("The Router is off") }
        let ack = try await RelayInbox(root: paths.relay).deliver(text, to: sent.cli, gate: gate)
        guard let how = RouterDecision.Cancelled(ack: ack) else { throw RouterTools.Failure("The session's plugin answered “\(RouterDecision.clip(ack, 60))”") }
        return how
    }

    /// Whether a history entry's message can still be cancelled, as Fjord sees its session now.
    func canCancel(_ decision: RouterDecision, now: Date = Date()) -> Bool {
        guard let sent = decision.delivered else { return false }
        return sent.cancellable(session: threads[sent.session], now: now)
    }
}
