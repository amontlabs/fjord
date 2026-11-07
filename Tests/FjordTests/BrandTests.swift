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
