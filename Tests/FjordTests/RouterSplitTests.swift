import Foundation
import Testing
@testable import Fjord

/// A message split across threads (docs/design/router-v2/SPLIT.md), look only: when the rows show, which words each
/// destination's tint covers (verbatim, never rewritten), and ⌘1–3 on the part the Router isn't sure of.
@MainActor
@Suite struct RouterSplitTests {
    private typealias ID = RouterDemo.ID

    private func page(_ text: String, sends: [RouterSend], reading: Bool = false) -> RouterModel {
        let model = RouterDemo.records()
        model.select(nil)
        model.setDraft(text)
        model.apply(.read(RouterRead(draft: model.plainDraft, places: [sends[0].place], sure: false, sends: sends)))
        if reading { model.reading = true }
        return model
    }

    private let text = "bar count: push it, and the spacing is off again"
    private var two: [RouterSend] {
        [RouterSend(places: [.thread(ID.bar)], parts: ["bar count: push it"]),
         RouterSend(places: [.thread(ID.settings), .thread(ID.tab)], sure: false, parts: ["the spacing is off again"])]
    }

    @Test func rowsShowForTwoSendsOrWhileTheRestIsRead() {
        #expect(page(text, sends: two).split?.count == 2)
        // One send is the usual row, unless the read for the rest is under way.
        let one = [RouterSend(places: [.thread(ID.bar)], answers: [0])]
        #expect(page(text, sends: one).split == nil)
        #expect(page(text, sends: one, reading: true).split?.count == 1)
    }

    @Test func aPlaceYouPickYourselfEndsTheSplit() {
        let model = page(text, sends: two)
        model.explicit = .thread(ID.bar)
        #expect(model.split == nil)
    }

    @Test func eachPartIsTintedWhereItStandsAndOnlyThere() throws {
        let model = page(text, sends: two)
        let ink = try #require(model.splitInk)
        let chars = Array(text)
        let first = String(chars.indices.filter { ink[$0] == 0 }.map { chars[$0] })
        let second = String(chars.indices.filter { ink[$0] == 1 }.map { chars[$0] })
        #expect(first == "bar count: push it")
        #expect(second == "the spacing is off again")
        #expect(ink[text.count - "the spacing is off again".count - 1] == nil)
    }

    @Test func aPartTheDraftDoesNotHoldIsNeverShown() throws {
        var sends = two
        sends[1].parts = ["the spacing is wrong"]
        let ink = try #require(page(text, sends: sends).splitInk)
        #expect(!ink.contains(1))
    }

    @Test func cmdDigitsLightAPlaceForTheUnsurePart() throws {
        let model = page(text, sends: two)
        #expect(model.splitFocus == 1)
        #expect(model.cmdDigit(1))
        let send = try #require(model.split?[1])
        #expect(send.place == .thread(ID.tab))
        #expect(send.mine)
        // The sure part is untouched, and a key past its places does nothing.
        #expect(model.split?[0].place == .thread(ID.bar))
        #expect(!model.lightPart(2))
    }
}
