import Foundation
import Testing
@testable import Fjord

/// The state tokens filter items, not threads (docs/design/router-v2/DESIGN.md 1.2, 4): a thread shows under a token with
/// only the items that belong to it, and the counts follow the same rule.
@MainActor
@Suite struct RouterStateFilterTests {
    private func thread(_ id: String, _ state: RouterThread.State, project: String? = "p", _ kinds: [RouterItem.Kind] = []) -> RouterThread {
        var t = RouterThread(id: id, name: id, title: id, project: project, state: state, sentence: .init(text: id), since: .now)
        t.ledger.items = kinds.enumerated().map { RouterItem(id: "\(id)\($0.offset)", kind: $0.element, sentence: "s", since: .now) }
        return t
    }

    private func kinds(_ t: RouterThread?) -> [RouterItem.Kind]? { t.map { $0.ledger.items.map(\.kind) } }

    @Test func needsYouKeepsOnlyTheNeedingItems() {
        let t = thread("a", .working, [.stuck, .decide, .know])
        #expect(kinds(RouterFilter.lens(t, state: .needsYou)) == [.stuck, .decide])
        // Know alone: nothing of it needs you.
        #expect(RouterFilter.lens(thread("b", .working, [.know]), state: .needsYou) == nil)
        // A thread with no items that asks, or is stopped, is its own line.
        #expect(RouterFilter.lens(thread("c", .needsYou(.question)), state: .needsYou) != nil)
        #expect(RouterFilter.lens(thread("d", .stopped, [.know]), state: .needsYou) != nil)
        #expect(RouterFilter.lens(thread("e", .done), state: .needsYou) == nil)
    }

    @Test func doneKeepsDoneThreadsAndKnowItems() {
        #expect(kinds(RouterFilter.lens(thread("a", .working, [.stuck, .know]), state: .done)) == [.know])
        #expect(kinds(RouterFilter.lens(thread("b", .done, [.do]), state: .done)) == [])
        #expect(RouterFilter.lens(thread("c", .done), state: .done) != nil)
        #expect(RouterFilter.lens(thread("d", .working, [.decide]), state: .done) == nil)
    }

    @Test func workingKeepsRunningThreadsAsPlainLines() {
        #expect(kinds(RouterFilter.lens(thread("a", .working, [.stuck, .know]), state: .working)) == [])
        #expect(RouterFilter.lens(thread("b", .sent), state: .working) != nil)
        #expect(RouterFilter.lens(thread("c", .done, [.know]), state: .working) == nil)
    }

    @Test func noStateIsTheThreadWhole() {
        let t = thread("a", .working, [.stuck, .know])
        #expect(RouterFilter.lens(t, state: nil) == t)
    }

    @Test func pageAndCountsFollowTheItems() {
        let model = RouterModel()
        model.apply(.batch([
            .upsert(thread("a", .working, project: "x", [.stuck, .know])),
            .upsert(thread("b", .done, project: "x", [.know])),
            .upsert(thread("c", .done, project: "y")),
            .upsert(thread("d", .working, project: "y")),
        ]))
        // Unfiltered: every thread once, by its most urgent item.
        #expect(model.count(project: nil) == 4)
        #expect(model.count(section: .needsYou) == 1)
        // a counts under Done too (its Know), under Working (it runs); b under Done only.
        #expect(model.count(section: .done) == 3)
        #expect(model.count(section: .working) == 2)
        #expect(model.needsYou == 1)

        model.section = .needsYou
        #expect(model.shownLines.map(\.id) == ["a"])
        #expect(model.shownLines.first.map { $0.ledger.items.map(\.kind) } == [.stuck])
        model.section = .done
        #expect(Set(model.shownLines.map(\.id)) == ["a", "b", "c"])
        #expect(model.shownLines.first { $0.id == "a" }?.ledger.items.map(\.kind) == [.know])
        // Faceted with the project.
        model.project = "x"
        #expect(Set(model.shownLines.map(\.id)) == ["a", "b"])
        #expect(model.count(section: .done) == 2)
        #expect(model.count(project: "y") == 1)
        model.section = .working
        #expect(model.shownLines.map(\.id) == ["a"])
        #expect(model.shownLines.first?.ledger.items.isEmpty == true)
        // The box's thread record is whole: filtering never drops an item from it.
        #expect(model.thread("a")?.ledger.items.count == 2)
    }
}
