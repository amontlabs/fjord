import CryptoKit
import Foundation

// Every live routing decision, kept locally for the future benchmark set (R1 D: after about 200 moments it becomes the headline):
// the board the model read (and its hash), the candidates, the pick, confidence, latency, tokens, and later what you did with
// it. One JSON object per line in Application Support/Fjord/decider-log.jsonl, readable by you alone. It holds your words and
// your threads' text, so it stays in that folder and never goes into the repo; nothing reads it back but the eval.

final class DeciderLog: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "fjord.decider-log")

    init(url: URL) { self.url = url }

    /// `Application Support/Fjord/decider-log.jsonl`; nil in a test run or a demo (no paths).
    static func live(_ paths: RouterPaths?) -> DeciderLog? {
        paths.map { DeciderLog(url: $0.support.appendingPathComponent("decider-log.jsonl")) }
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// What was on screen when you sent (E5's focus signals): the thread open in Fjord, the one your latest message went to,
    /// and the candidates with a reply you haven't opened (T3's `lastVisitedAt` before `latestRunCompletedAt`).
    struct Focus: Equatable {
        var open: String?
        var lastTold: String?
        var unseen: [String] = []
    }

    /// A decision: the entry it belongs to (`id`), the message, the board, and what the decider did. `fused`: E5's Jev-led
    /// path's answer ; `preview`: what the composer showed while you typed. The fields are E5's "Live logging".
    func decision(id: UUID, message: String, decision d: RouterProjectDecision, board: String, candidates: [(id: String, key: String)],
                  sent: String, fused: JevPath.Result? = nil, preview: RouterShown? = nil,
                  focus: Focus? = nil, now: Date = Date()) {
        var kind: String
        var target = ""
        var places: [String] = []
        switch d.kind {
        case .thread(let t): kind = "thread"; target = t
        case .newThread(let p): kind = "new_thread"; target = p
        case .answer: kind = "answer"
        case .ask(let ps):
            kind = "ask"
            places = ps.map { k in
                switch k {
                case .thread(let t): "thread:" + t
                case .newThread(let p): "new_thread:" + p
                default: "other"
                }
            }
        }
        var record: [String: Any] = [
            "type": "decision", "id": id.uuidString, "at": ISO8601DateFormatter().string(from: now),
            "decider": d.decider.rawValue, "action": d.action, "kind": kind, "target": target, "places": places,
            "confidence": d.confidence, "projectConfidence": d.projectConfidence, "reason": d.reason, "sent": sent,
            "message": message, "boardHash": Self.hash(board), "board": board,
            "candidates": candidates.map { ["id": $0.id, "thread": $0.key] },
        ]
        // N4b's fields of Sonnet's answer, and the context it read.
        if let p = d.pNew { record["pNew"] = p }
        if !d.deliverable.isEmpty { record["deliverable"] = d.deliverable }
        if d.pNew != nil {
            record["fits"] = d.fits.map { ["thread": $0.thread, "how": $0.how, "stateOK": $0.stateOK] }
            record["ownedBy"] = d.ownedBy
        }
        if let u = d.referentUnique { record["referentUnique"] = u }
        if !d.contextKey.isEmpty { record["contextKey"] = d.contextKey }
        if !d.contextSizes.isEmpty { record["contextSizes"] = d.contextSizes }
        if let latency = d.latency { record["latencyMs"] = Int(latency * 1000) }
        if let u = d.usage {
            var usage: [String: Any] = ["input": u.inputTokens, "output": u.outputTokens, "cacheRead": u.cacheReadTokens,
                                        "cacheCreation": u.cacheCreationTokens]
            if let c = u.costUSD { usage["costUSD"] = c }
            record["usage"] = usage
        }
        // Which path decided: E5's fused path alone, or Sonnet (or Jev's ask without a key).
        record["path"] = d.action == "fused" ? "fused" : d.decider.rawValue
        let final = d.target?.targetID
        if let f = fused {
            var out = Self.fused(f)
            // Agreement with where it went now (an ask's pick comes later, as its outcome).
            if let final { out["agrees"] = f.top?.place.targetID == final }
            out["wouldSend"] = f.send() != nil
            record["fused"] = out
        }
        if let preview {
            var shown: [String: Any] = ["target": preview.target, "p": preview.p, "forTheseWords": preview.text == message,
                                        "decider": preview.decider, "sure": preview.sure]
            // The final decision differs from the place shown: a preview miss.
            shown["miss"] = final != preview.target
            record["preview"] = shown
        }
        if let focus {
            var out: [String: Any] = ["unseen": focus.unseen]
            if let open = focus.open { out["open"] = open }
            if let told = focus.lastTold { out["lastTold"] = told }
            record["focus"] = out
        }
        append(record)
    }

    /// The fused path's answer as the log keeps it: every place with its features, Jev's answers, the BM25, the gates.
    static func fused(_ f: JevPath.Result) -> [String: Any] {
        var out: [String: Any] = [
            "model": f.model, "requestHash": f.requestHash, "reused": f.reused,
            "pick": f.top?.place.targetID ?? "", "p": f.p, "runningMass": f.runningMass,
            "abstain": f.abstain?.rawValue ?? "", "ans": f.ans, "nextChoice": f.next, "bm25": f.bm25, "twins": f.twins,
            "rows": f.rows.map { r -> [String: Any] in
                ["target": r.place.targetID, "jev": r.jev, "p": r.p, "running": r.running, "features": r.features.named]
            },
        ]
        if let fjord = f.fjord { out["fjord"] = fjord }
        if let latency = f.latency { out["latencyMs"] = Int(latency * 1000) }
        return out
    }

    /// A message that went where you fixed it from the preview's menu (no decision ran): what was shown and what you picked.
    func previewPick(id: UUID, shown: RouterShown?, picked: String, now: Date = Date()) {
        var record: [String: Any] = ["type": "preview", "id": id.uuidString, "at": ISO8601DateFormatter().string(from: now),
                                     "picked": picked]
        if let shown {
            record["shown"] = shown.target
            record["p"] = shown.p
            record["changed"] = shown.target != picked
            record["decider"] = shown.decider
        }
        append(record)
    }

    /// What you then did with a decision: `sent` (acted on at once), `picked` (an ask's pick, with whether it was the guess),
    /// `dismissed`, `sent_elsewhere` (a wrong send asked again), `reverted`.
    func outcome(id: UUID, _ what: String, target: String = "", guess: Bool? = nil, now: Date = Date()) {
        var record: [String: Any] = ["type": "outcome", "id": id.uuidString, "at": ISO8601DateFormatter().string(from: now), "what": what]
        if !target.isEmpty { record["target"] = target }
        if let guess { record["wasGuess"] = guess }
        append(record)
    }

    /// One step of a draft's read while typing (`RouterV2Reader`): a pause that ended, a model call started or skipped, a read
    /// cancelled by the next key. `sinceKeyMs` counts from the key that began the read; the constants in `RouterV2` are tuned
    /// from these lines, not from a simulation.
    func typing(event: String, phase: String, characters: Int, sinceKeyMs: Int, extra: [String: Any] = [:], now: Date = Date()) {
        var record = extra
        record["type"] = "typing"
        record["at"] = ISO8601DateFormatter.string(from: now, timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        record["event"] = event
        record["phase"] = phase
        record["characters"] = characters
        record["sinceKeyMs"] = sinceKeyMs
        append(record)
    }

    private func append(_ record: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(record),
              var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        queue.async { [url] in
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Waits for what was queued to be written (tests).
    func flush() { queue.sync {} }
}
