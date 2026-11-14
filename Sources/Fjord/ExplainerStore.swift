import Foundation

// Show me's saved versions (docs/design/router-visuals/SHOWME.md §2.3): every `preview` call, and the engine's final render,
// becomes the run's next version in `runs/<run>/`: `v<n>.js` (the code), `v<n>/` (the page, its frames and posters) and one
// line in `meta.json`. The renderer writes these and nothing else; the engine's `input.md` and `run.json` sit beside them
// (ExplainerTypes.swift).

struct ExplainerVersions: Sendable {
    /// `Explainers/runs`.
    let runs: URL

    /// What `meta.json` keeps of each version: everything in `ExplainerVersion` that isn't the code or a path.
    struct Entry: Codable, Equatable {
        var number: Int
        var broken: Bool
        var note: String?
        var title: String?
        var answer: String?
        var captions: [String]
        var length: Double?
    }

    struct Meta: Codable, Equatable {
        var versions: [Entry] = []
    }

    struct BadRun: LocalizedError {
        let run: String
        var errorDescription: String? { "“\(run)” isn't an explainer run id" }
    }

    /// A run id is one path component of letters, digits, `-` and `_` (T3's thread ids are UUIDs): nothing a ticket holds can
    /// reach outside `runs/`.
    static func valid(_ run: String) -> Bool {
        !run.isEmpty && run.count <= 128 && run.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    func folder(_ run: String) throws -> URL {
        guard Self.valid(run) else { throw BadRun(run: run) }
        return runs.appendingPathComponent(run, isDirectory: true)
    }

    func code(_ run: String, _ number: Int) throws -> URL { try folder(run).appendingPathComponent("v\(number).js") }
    func page(_ run: String, _ number: Int) throws -> URL {
        try folder(run).appendingPathComponent("v\(number)", isDirectory: true)
    }

    func meta(_ run: String) -> Meta {
        guard let url = try? folder(run).appendingPathComponent("meta.json"), let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return Meta() }
        return meta
    }

    /// The number the next version takes: one past the highest saved, or past a `v<n>.js` left by a render that stopped
    /// before its line in `meta.json` (so a number is never used twice).
    func next(_ run: String) throws -> Int {
        let folder = try folder(run)
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { name -> Int? in
            guard name.hasPrefix("v"), name.hasSuffix(".js") else { return nil }
            return Int(name.dropFirst().dropLast(3))
        }
        return max(meta(run).versions.map(\.number).max() ?? 0, onDisk.max() ?? 0) + 1
    }

    /// Adds a version's line to `meta.json` (replacing one with its number), written atomically.
    func save(_ version: ExplainerVersion) throws {
        let folder = try folder(version.run)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = meta(version.run)
        meta.versions.removeAll { $0.number == version.number }
        meta.versions.append(Entry(number: version.number, broken: version.broken, note: version.note, title: version.title,
                                   answer: version.answer, captions: version.captions, length: version.length))
        meta.versions.sort { $0.number < $1.number }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// The run's versions, oldest first, read back from disk. A version whose code is gone is skipped.
    func versions(of run: String) -> [ExplainerVersion] {
        meta(run).versions.compactMap { entry in
            guard let codeURL = try? code(run, entry.number), let code = try? String(contentsOf: codeURL, encoding: .utf8),
                  let dir = try? page(run, entry.number) else { return nil }
            func file(_ name: String) -> URL? {
                let url = dir.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            return ExplainerVersion(run: run, number: entry.number, code: code, broken: entry.broken, note: entry.note,
                                    title: entry.title, answer: entry.answer, captions: entry.captions, length: entry.length,
                                    page: file("index.html"), posterLight: file(ExplainerRenderer.posterLight),
                                    posterDark: file(ExplainerRenderer.posterDark))
        }
    }
}
