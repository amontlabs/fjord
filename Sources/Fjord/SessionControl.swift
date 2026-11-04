import Foundation

// Signing with the relay key for a message Fjord carries to a session (`RouterCarry`).

extension Store {
    /// `sign` applied to the relay key (read again when the cached one is stale).
    func localSigned(_ sign: (String) -> String) async throws -> String {
        guard let paths = routerFiles else { throw RouterTools.Failure("The Router is off") }
        if let cached = relayKeyCache, cached.matches(paths.relayKey) { return sign(cached.key) }
        guard await reloadRelayKey(), let key = relayKeyCache?.key else { throw RouterTools.Failure("The Router is off") }
        return sign(key)
    }
}
