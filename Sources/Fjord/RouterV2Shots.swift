import AppKit
import SwiftUI

// The Router v2 page's stills for `--window-shots <dir> v2` (docs/design/router-v2/DESIGN.md 6.1): each key state on the
// demo's records, light and dark (`-dark`), drawn still (the sheen and the dots hold one pose).

@MainActor
enum RouterV2Shots {
    private typealias ID = RouterV2Demo.ID

    static var catalog: [AppWindowShots.Shot] {
        states.flatMap { state in
            [shot(state.name, .aqua, state), shot(state.name + "-dark", .darkAqua, state)]
        } + screens.flatMap { screen in
            [shot(screen.name, .aqua, screen), shot(screen.name + "-dark", .darkAqua, screen)]
        }
    }

    /// What the screen around the page draws from the app's store: the History drawer, the setup notice.
    private struct Screen {
        let name: String
        var size = CGSize(width: 1280, height: 960)
        let compose: (RouterModel, Store) -> Void
    }

    private static func shot(_ name: String, _ look: NSAppearance.Name, _ screen: Screen) -> AppWindowShots.Shot {
        AppWindowShots.Shot(name: name, destination: { _ in .router }, size: screen.size, compose: screen.compose,
                            appearance: look, v2: { RouterV2Demo.records(still: true) })
    }

    private static let screens: [Screen] = [
        // The History drawer beside the page (from `RouterV2Screen.sideFrom`), and under it in a narrower window.
        Screen(name: "v2-drawer", size: CGSize(width: 1600, height: 960)) { _, store in store.routerDrawerOpen = true },
        Screen(name: "v2-drawer-narrow", size: CGSize(width: 900, height: 960)) { _, store in store.routerDrawerOpen = true },
        // Claude Code not found: the notice under the title, with Look again.
        Screen(name: "v2-setup") { model, _ in model.claudeCodeMissing = true },
        // The Router off: the notice with Turn on.
        Screen(name: "v2-off") { _, store in store.switchRouter(false) },
    ]

    private struct State {
        let name: String
        let make: (RouterV2Model) -> Void
        var pointer: ((RouterV2Model) -> Void)?
    }

    private static func shot(_ name: String, _ look: NSAppearance.Name, _ state: State) -> AppWindowShots.Shot {
        AppWindowShots.Shot(name: name, destination: { _ in .router }, size: CGSize(width: 1280, height: 960), appearance: look,
                            v2: {
                                let model = RouterV2Demo.records(still: true)
                                state.make(model)
                                return model
                            },
                            v2Pointer: state.pointer)
    }

    /// A draft for a new thread in silo, read: the row shows what it starts with. `aside`: the words that say its
    /// settings, as the Router's model returns them.
    private static func newThread(_ model: RouterV2Model, aside: String = "", launch: RouterV2LaunchAsk = RouterV2LaunchAsk()) {
        model.select(nil)
        model.setDraft("silo: write the changelog for 0.4" + aside)
        model.apply(.read(RouterV2Read(draft: model.draft, places: [.newThread(project: "silo")], sure: true,
                                       name: "write the changelog for 0.4", launch: launch,
                                       taken: aside.isEmpty ? nil : aside.trimmingCharacters(in: .whitespaces))))
    }

    private static let states: [State] = [
        State(name: "v2-home") { _ in },
        State(name: "v2-card-question") { $0.pick(2) },
        State(name: "v2-card-form") { model in
            model.select(.line(ID.updater))
            model.pick(1)
        },
        State(name: "v2-card-plan") { $0.select(.line(ID.briefs)) },
        State(name: "v2-card-plan-open") { model in
            model.select(.line(ID.briefs))
            model.expand(true)
        },
        State(name: "v2-card-permission") { model in
            RouterV2Demo.askPermission(model)
            model.line(ID.checkpoint, "wants to remove the old checkpoint worktree, with --force")
            model.select(.line(ID.checkpoint))
            model.pick(1)
        },
        State(name: "v2-card-not-live") { model in
            // After a T3 restart: the question can't be answered from here.
            if var settings = model.thread(ID.settings) {
                settings.live = false
                settings.options = []
                model.apply(.upsert(settings))
            }
        },
        State(name: "v2-card-step") { $0.select(.line(ID.valCenis)) },
        State(name: "v2-card-done") { $0.select(.line(ID.guide)) },
        State(name: "v2-card-loading") { model in
            if var guide = model.thread(ID.guide) {
                guide.loading = true
                model.apply(.upsert(guide))
            }
            model.select(.line(ID.guide))
        },
        State(name: "v2-card-stopped") { $0.select(.line(ID.disk)) },
        State(name: "v2-card-working") { model in
            model.select(.line(ID.tab))
            model.reply(ID.tab, "The draft now survives the handover. I am wiring the composer so the caret lands where it was, then I will check the spacing against T3", writing: true)
            model.setDraft("keep the placeholder as it is")
            model.apply(.read(RouterV2Read(draft: model.draft, places: [.thread(ID.tab)], sure: true)))
        },
        State(name: "v2-peek", make: { $0.select(nil) }, pointer: { model in
            model.hoverRow = ID.guide
            model.hoverName = ID.guide
        }),
        State(name: "v2-peek-older", make: { $0.select(nil) }, pointer: { $0.hoverControl = .housekeepingWords }),
        State(name: "v2-reassessing") { model in
            model.select(nil)
            RouterV2Demo.askPermission(model)
            model.turnEnded(ID.upstream)
            model.pr(ID.guide, 41, .merged)
        },
        State(name: "v2-filter") { model in
            model.select(nil)
            model.toggle(project: "silo")
            model.toggle(section: .working)
            model.enterFilterMode()
        },
        State(name: "v2-filter-empty") { model in
            model.select(nil)
            model.toggle(project: "docs-site")
            model.toggle(section: .working)
        },
        State(name: "v2-destination-unsure") { model in
            model.select(nil)
            model.setDraft("the spacing is off again")
            model.apply(.read(RouterV2Read(draft: model.draft, places: [.thread(ID.settings), .thread(ID.tab), .newThread(project: "fjord")],
                                          sure: false)))
        },
        State(name: "v2-destination-sure") { model in
            model.select(nil)
            model.setDraft("bar count: push it and open the PR")
            model.apply(.read(RouterV2Read(draft: model.draft, places: [.thread(ID.bar)], sure: true)))
        },
        State(name: "v2-reading") { model in
            // The first read of a draft with nothing selected: Fjord's mark in the arrow's slot.
            model.select(nil)
            model.setDraft("bar count: push it and open the PR")
        },
        State(name: "v2-new-thread") { newThread($0) },
        State(name: "v2-new-thread-keys", make: { model in
            // Tab into the row, → to the effort: the ring is on its chip.
            newThread(model)
            model.moveLaunchFocus(forward: true, leaves: true)
            model.moveLaunchFocus(forward: true, leaves: false)
        }, pointer: { $0.stepLaunch(down: true) }),  // ↓: its menu opens, High to Extra high.
        State(name: "v2-new-thread-menu", make: { newThread($0) }, pointer: { $0.toggleLaunchMenu(.model) }),
        State(name: "v2-new-thread-access-menu", make: { newThread($0) }, pointer: { $0.toggleLaunchMenu(.access) }),
        State(name: "v2-new-thread-written") { model in
            newThread(model, aside: " (use opus medium)", launch: RouterV2LaunchAsk(model: "claude-opus-5-5", effort: .medium))
        },
        State(name: "v2-new-thread-plan") { model in
            newThread(model, aside: " (plan it first, and ask before running anything)", launch: RouterV2LaunchAsk(access: .supervised, plan: true))
        },
        State(name: "v2-new-thread-unsure") { model in
            model.select(nil)
            model.setDraft("the spacing is off again")
            model.apply(.read(RouterV2Read(draft: model.draft, places: [.thread(ID.settings), .thread(ID.tab), .newThread(project: "fjord")],
                                          sure: false)))
            model.light(2)
        },
        State(name: "v2-new-thread-sent") { model in
            newThread(model, aside: " (use opus medium)", launch: RouterV2LaunchAsk(model: "claude-opus-5-5", effort: .medium))
            model.send()
            if let id = model.threads.last?.id { model.select(.line(id)) }
        },
        State(name: "v2-held") { model in
            // Return before the read landed: the words are held, the send button stays pressed, Fjord's mark in the row.
            model.select(nil)
            model.setDraft("lcu: add a --dry-run flag to lcu apps")
            model.send()
        },
        State(name: "v2-card-flagged") { model in
            // A turn that ended on an error: Done at once, then the verdict moved it to Needs you.
            model.turnEnded(ID.snapshot, lastLines: "I added `restore(id:)` and its tests, but the package no longer builds: `cannot find 'RestoreToken' in scope` at Snapshots.swift:212. I could not find where it is defined, so I stopped here.",
                            diff: .init(files: 3, added: 74, removed: 9))
            model.verdict(ID.snapshot, step: "Fix the build, or tell it how.", result: "restore by id added; the build fails on 'RestoreToken'")
            model.line(ID.snapshot, "the build fails: cannot find 'RestoreToken'; it stopped there")
            model.select(.line(ID.snapshot))
        },
        State(name: "v2-pick-a-place", make: { model in
            model.select(nil)
            model.setDraft("that one test again")
            model.apply(.read(RouterV2Read(draft: model.draft, places: [], sure: false)))
        }, pointer: { $0.openPlaces() }),
        State(name: "v2-unreachable") { model in
            model.select(.line(ID.bar))
            model.setDraft("also bump the version")
            model.apply(.read(RouterV2Read(draft: model.draft, places: [.thread(ID.bar)], sure: true)))
            model.connection(lost: true)
        },
        State(name: "v2-queued") { model in
            model.select(.line(ID.checkpoint))
            model.setDraft("then delete the old checkpoint image too")
            model.apply(.read(RouterV2Read(draft: model.draft, places: [.thread(ID.checkpoint)], sure: true)))
            model.send(queue: true)
        },
        State(name: "v2-sent") { model in
            model.pick(2)
            model.send()
        },
        State(name: "v2-failure") { model in
            model.select(.line(ID.bar))
            model.setDraft("also bump the version")
            model.apply(.read(RouterV2Read(draft: model.draft, places: [.thread(ID.bar)], sure: true)))
            model.send()
            model.connection(lost: true)
            model.refused(ID.bar, reason: RouterV2.Copy.unreachable, offline: true)
        },
        State(name: "v2-toast") { model in
            model.select(.line(ID.guide))
            model.settle(ID.guide)
        },
        State(name: "v2-snooze", make: { $0.select(.line(ID.valCenis)) }, pointer: { $0.openSnooze() }),
        State(name: "v2-empty") { model in
            model.select(nil)
            model.apply(.batch(model.threads.map { .remove($0.id) } + [.older([])]))
        },
        State(name: "v2-nothing-needs-you") { model in
            model.select(nil)
            model.apply(.batch(model.threads.filter { $0.section == .needsYou }.map { .remove($0.id) }))
        },
    ]
}
