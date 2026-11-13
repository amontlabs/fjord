import Foundation
import Testing

/// Reduce Motion across the app (glass-plan §5.7): every animation it starts goes through a `Motion` token resolved for
/// Reduce Motion (`Motion.X.resolved(reduce:)`, `.motion`, `.hoverMotion`) or an explicit Reduce Motion check, and nothing
/// loops in SwiftUI.
@Suite struct RouterMotionTests {
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/Fjord")

    /// Each `withAnimation(`, `.animation(`, `Transaction(animation:` and `.animation =` with its argument, but neither a
    /// TimelineView's schedule (`TimelineView(.animation(…, paused: reduceMotion))`) nor a fade's own animation
    /// (`.opacity.animation(…)`) nor a layer's (`layer.animation(forKey:)`); and `withAnimation {`, the default animation.
    private static let call = try! NSRegularExpression(pattern:
        #"(?:withAnimation\(|(?<!\.opacity)(?<!TimelineView\()\.animation\((?!forKey)|Transaction\(animation:\s*|\.animation\s*=(?!=)\s*)([^\n]*)|withAnimation\s*\{"#)

    /// A ternary on a Reduce Motion flag: `reduce ? nil : …`, `reduceMotion ? .easeOut(…) : …`.
    private static func checksReduce(_ argument: String) -> Bool {
        let name = argument.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.lowercased().contains("reduce") && argument.dropFirst(name.count).drop(while: \.isWhitespace).hasPrefix("?")
    }

    /// The deliberate exceptions, by file and a piece of the line: each says why it is not a token.
    static let allowed: [(file: String, line: String, reason: String)] = [
        ("AppSidebar.swift", ".animation(collapsed ? .easeIn(duration: 0.12).delay(0.12)",
         "the rail badge's timing: an opacity only, in after the labels have gone"),
        ("Playground.swift", ".animation(.easeOut(duration: 0.2), value: hub.toast)",
         "the playground's own toast, a development tool"),
        ("RouterHostedLine.swift", "RouterGlides.animation(glide.curve",
         "a Core Animation glide on a curve already resolved for Reduce Motion (`RouterCurve.curve(reduce:)`)"),
        ("RouterModel.swift", "withAnimation(curve.animation)",
         "the line move's curve, resolved for Reduce Motion the line before (`RouterCurve.lineMove.curve(reduce:)`)"),
    ]

    /// Unresolved for Reduce Motion: the call neither resolves its animation there, nor checks the flag, nor passes one
    /// resolved before (`let motion = ….resolved(reduce:)`, `var spring: Animation? { ….resolved(reduce:) }`), nor no
    /// animation. Comment lines are skipped.
    static func unresolved(_ text: String) -> [Int] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [Int] = []
        for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            let ns = line as NSString
            for match in call.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                guard match.range(at: 1).location != NSNotFound else { found.append(i + 1); continue }
                let argument = ns.substring(with: match.range(at: 1))
                // Resolved in the animation itself, not in the body it runs (`withAnimation(.spring) { x.resolved(reduce:) }`).
                let animation = argument.prefix { $0 != "{" }
                if animation.contains("resolved(reduce:") || argument.hasPrefix("nil") { continue }
                if checksReduce(argument) { continue }
                let name = argument.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty, argument.dropFirst(name.count).hasPrefix(")") {
                    let declared = try! Regex(#"\b(let|var) \#(name)\b.*resolved\(reduce:"#)
                    if lines.contains(where: { $0.contains(declared) }) { continue }
                }
                found.append(i + 1)
            }
        }
        return found
    }

    private static func swiftFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }.sorted()
    }

    private static func read(_ file: String) throws -> [String] {
        try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func everyAnimationHonoursReduceMotion() throws {
        let files = try Self.swiftFiles()
        #expect(files.contains("RouterPage.swift") && files.contains("Motion.swift"))
        var found: [String] = []
        var used = Set<Int>()
        for file in files {
            let lines = try Self.read(file)
            for n in Self.unresolved(lines.joined(separator: "\n")) {
                let line = lines[n - 1]
                if let i = Self.allowed.firstIndex(where: { $0.file == file && line.contains($0.line) }) {
                    used.insert(i)
                } else {
                    found.append("\(file):\(n)")
                }
            }
        }
        #expect(found.isEmpty, "Unresolved for Reduce Motion (use a Motion token): \(found)")
        let stale = Self.allowed.indices.filter { !used.contains($0) }.map { "\(Self.allowed[$0].file): \(Self.allowed[$0].line)" }
        #expect(stale.isEmpty, "Allowed exceptions no longer found: \(stale)")
    }

    /// A repeating animation runs in Core Animation, never in SwiftUI (it would redraw the view on every frame).
    @Test func nothingLoopsInSwiftUI() throws {
        var found: [String] = []
        for file in try Self.swiftFiles() {
            for (i, line) in try Self.read(file).enumerated()
            where line.contains(".repeatForever(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                found.append("\(file):\(i + 1)")
            }
        }
        #expect(found.isEmpty, "A SwiftUI animation that loops: \(found)")
    }

    @Test func everyFormOfAnAnimationIsCaught() {
        let caught = """
            Button { withAnimation(.easeOut(duration: 0.15)) { dismiss() } }
            withAnimation(Motion.spatial) { open() }
            withAnimation { open() }
            .animation(.easeOut(duration: 0.06), value: open)
            .animation(Motion.release.animation, value: on)
            withAnimation(plain) { open() }
            var transaction = Transaction(animation: .spring())
            .transaction { $0.animation = .easeOut(duration: 0.1) }
            """
        #expect(Self.unresolved(caught) == [1, 2, 3, 4, 5, 6, 7, 8])
        let fine = """
            private var spring: Animation? { Motion.spatial.resolved(reduce: reduceMotion) }
            withAnimation(spring) { open() }
            if let motion = Motion.release.resolved(reduce: reduceMotion) { withAnimation(motion) { go() } }
            withAnimation(Motion.fade.resolved(reduce: reduceMotion)) { open() }
            .animation(Motion.fade.resolved(reduce: reduce), value: shown)
            .animation(nil, value: shown)
            .animation(reduce ? nil : .timingCurve(0.34, 1.3, 0.64, 1, duration: 0.12), value: on)
            .motion(.easeOut(duration: 0.06), value: open)
            .motion(.fade, value: open)
            .hoverMotion(hovering)
            .transition(.opacity.animation(.easeOut(duration: 0.2)))
            TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { _ in }
            var instant = Transaction(animation: nil)
            .transaction { $0.animation = nil }
            if transaction.animation == nil { return }
            var isFading: Bool { layer.animation(forKey: kCATransition) != nil }
            /// `.animation(_:value:)` with a token.
            """
        #expect(Self.unresolved(fine).isEmpty)
    }
}
