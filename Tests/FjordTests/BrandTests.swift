import AppKit
import SwiftUI
import Testing
@testable import Fjord

/// The look follows the Mac's appearance as it's drawn, so switching light and dark needs no relaunch.
@Suite struct BrandTests {
    private func resolved(_ color: Color, in name: NSAppearance.Name) -> NSColor? {
        var out: NSColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance { out = NSColor(color).usingColorSpace(.sRGB) }
        return out
    }

    private func luminance(_ c: NSColor) -> CGFloat { 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent }

    @Test func textAndGroundSwapWithTheAppearance() throws {
        let text = try #require(resolved(CDS.Text.primary, in: .darkAqua)), lightText = try #require(resolved(CDS.Text.primary, in: .aqua))
        let ground = try #require(resolved(CDS.Surface.s1, in: .darkAqua)), lightGround = try #require(resolved(CDS.Surface.s1, in: .aqua))
        #expect(luminance(text) > 0.8 && luminance(ground) < 0.15)
        #expect(luminance(lightText) < 0.15 && luminance(lightGround) > 0.85)
    }

    @Test func aCardsTintIsPaleOnLightAndTransparentOnDark() throws {
        let wash = Brand.wash(CDS.Fill.warning, 0.15)
        let light = try #require(resolved(wash, in: .aqua)), dark = try #require(resolved(wash, in: .darkAqua))
        #expect(light.alphaComponent == 1 && luminance(light) > 0.8)
        #expect(abs(dark.alphaComponent - 0.15) < 0.01)
    }
}

/// Claude's fonts are registered from the cache while the archive they were taken from is the same one.
@Suite struct ClaudeFontCache {
    private func font(_ name: String, _ text: String) -> (name: String, bytes: () -> Data) { (name, { Data(text.utf8) }) }

    @Test func eachArchiveHasAGenerationOfItsOwnMadeWholeOrNotAtAll() throws {
        let dir = TempDir()
        let archive = dir.path("app.asar"), root = dir.path("fonts")
        try Data("one".utf8).write(to: archive)
        let stamp = try #require(ClaudeFonts.archiveStamp(archive.path))
        #expect(ClaudeFonts.archiveStamp(dir.path("missing").path) == nil)
        #expect(ClaudeFonts.fonts(in: ClaudeFonts.generation(root: root, stamp: stamp)) == nil)
        let made = try #require(ClaudeFonts.store([font("A.woff2", "aaaa"), font("B.woff2", "bbbb")], root: root, stamp: stamp))
        #expect(made == ClaudeFonts.generation(root: root, stamp: stamp))
        #expect(ClaudeFonts.fonts(in: made) == ["A.woff2", "B.woff2"])
        #expect(try Data(contentsOf: made.appendingPathComponent("A.woff2")) == Data("aaaa".utf8))
        // Another build of the app, its fonts of the same names and sizes but other bytes: a generation of its own.
        try Data("another".utf8).write(to: archive)
        let next = try #require(ClaudeFonts.archiveStamp(archive.path))
        #expect(next != stamp && ClaudeFonts.fonts(in: ClaudeFonts.generation(root: root, stamp: next)) == nil)
        let second = try #require(ClaudeFonts.store([font("A.woff2", "AAAA")], root: root, stamp: next))
        #expect(try Data(contentsOf: second.appendingPathComponent("A.woff2")) == Data("AAAA".utf8))
        // The first is left as it was, for a process still running with it.
        #expect(try Data(contentsOf: made.appendingPathComponent("A.woff2")) == Data("aaaa".utf8))
        // One of its fonts gone: not whole.
        try FileManager.default.removeItem(at: made.appendingPathComponent("B.woff2"))
        #expect(ClaudeFonts.fonts(in: made) == nil)
    }

    @Test func olderGenerationsGoOnlyWhileNoOtherFjordRuns() throws {
        let dir = TempDir()
        let root = dir.path("fonts")
        let old = try #require(ClaudeFonts.store([font("A.woff2", "a")], root: root, stamp: "1 1 1.0"))
        let current = try #require(ClaudeFonts.store([font("A.woff2", "b")], root: root, stamp: "2 2 2.0"))
        ClaudeFonts.sweep(root, keeping: current, othersRunning: { true })
        #expect(FileManager.default.fileExists(atPath: old.path))
        ClaudeFonts.sweep(root, keeping: current, othersRunning: { false })
        #expect(!FileManager.default.fileExists(atPath: old.path) && ClaudeFonts.fonts(in: current) != nil)
    }

    @Test func aGenerationNotWholeIsPutAsideAndMadeAgainInItsPlace() throws {
        let dir = TempDir()
        let root = dir.path("fonts")
        let made = try #require(ClaudeFonts.store([font("A.woff2", "a"), font("B.woff2", "b")], root: root, stamp: "1 1 1.0"))
        try FileManager.default.removeItem(at: made.appendingPathComponent("B.woff2"))
        #expect(ClaudeFonts.fonts(in: made) == nil)
        // Made again over it would fail (the folder is there): put aside first, it is made whole.
        ClaudeFonts.setAside(made, in: root)
        let again = try #require(ClaudeFonts.store([font("A.woff2", "a"), font("B.woff2", "b")], root: root, stamp: "1 1 1.0"))
        #expect(again == made && ClaudeFonts.fonts(in: again) == ["A.woff2", "B.woff2"])
        // What was put aside goes with the next sweep.
        ClaudeFonts.sweep(root, keeping: again, othersRunning: { false })
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [again.lastPathComponent])
    }

    @Test func failuresAreCountedInTheDefaultsForTheArchiveAlone() throws {
        let defaults = try #require(UserDefaults(suiteName: "fjord-fonts-\(UUID().uuidString)"))
        // A cache folder that can't be written doesn't stop the count.
        for _ in 0..<ClaudeFonts.maxFailures { ClaudeFonts.noteFailure(stamp: "1 1 1.0", defaults: defaults) }
        #expect(ClaudeFonts.failures(stamp: "1 1 1.0", defaults: defaults) == ClaudeFonts.maxFailures)
        // Another archive: counted afresh, the old one's forgotten.
        ClaudeFonts.noteFailure(stamp: "2 2 2.0", defaults: defaults)
        #expect(ClaudeFonts.failures(stamp: "2 2 2.0", defaults: defaults) == 1)
        #expect(ClaudeFonts.failures(stamp: "1 1 1.0", defaults: defaults) == 0)
        // Taken out at last: the count starts again.
        ClaudeFonts.clearFailures(defaults: defaults)
        #expect(ClaudeFonts.failures(stamp: "2 2 2.0", defaults: defaults) == 0)
    }

    @Test func theRunningAppsAreAskedOnlyWhenThereIsSomethingToSweep() throws {
        let dir = TempDir()
        let root = dir.path("fonts")
        let current = try #require(ClaudeFonts.store([font("A.woff2", "a")], root: root, stamp: "2 2 2.0"))
        var asked = 0
        ClaudeFonts.sweep(root, keeping: current, othersRunning: { asked += 1; return false })
        #expect(asked == 0)
        _ = ClaudeFonts.store([font("A.woff2", "b")], root: root, stamp: "1 1 1.0")
        ClaudeFonts.sweep(root, keeping: current, othersRunning: { asked += 1; return false })
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(asked == 1 && left == [current.lastPathComponent])
    }
}
