import AppKit
import SwiftUI

// The Router v2 page's stills for `--window-shots <dir> v2` (docs/design/router-v2/DESIGN.md 6.1): each key state on the
// demo's records, light and dark (`-dark`), drawn still (the sheen and the dots hold one pose).

@MainActor
enum RouterShots {
    private typealias ID = RouterDemo.ID

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
        let compose: (RouterComposerModel, Store) -> Void
    }

    private static func shot(_ name: String, _ look: NSAppearance.Name, _ screen: Screen) -> AppWindowShots.Shot {
        AppWindowShots.Shot(name: name, destination: { _ in .router }, size: screen.size, compose: screen.compose,
                            appearance: look, v2: { RouterDemo.records(still: true) })
    }

    private static let screens: [Screen] = [
        // The History drawer beside the page (from `RouterScreen.sideFrom`), and under it in a narrower window.
        Screen(name: "v2-drawer", size: CGSize(width: 1600, height: 960)) { _, store in store.routerDrawerOpen = true },
        Screen(name: "v2-drawer-narrow", size: CGSize(width: 900, height: 960)) { _, store in store.routerDrawerOpen = true },
        // Claude Code not found: the notice under the title, with Look again.
        Screen(name: "v2-setup") { model, _ in model.claudeCodeMissing = true },
        // The Router off: the notice with Turn on.
        Screen(name: "v2-off") { _, store in store.switchRouter(false) },
    ]

    private struct State {
        let name: String
        let make: (RouterModel) -> Void
        var pointer: ((RouterModel) -> Void)?
        var size = CGSize(width: 1280, height: 960)
    }

    private static func shot(_ name: String, _ look: NSAppearance.Name, _ state: State) -> AppWindowShots.Shot {
        AppWindowShots.Shot(name: name, destination: { _ in .router }, size: state.size, appearance: look,
                            v2: {
                                let model = RouterDemo.records(still: true)
                                state.make(model)
                                return model
                            },
                            v2Pointer: state.pointer)
    }

    private static func activity(_ model: RouterModel) {
        model.select(nil)
        for (id, a) in RouterDemo.activity(at: model.now) { model.activity(id, a) }
    }

    /// A draft for a new thread in silo, read: the row shows what it starts with. `pills`: settings picked from the @ list,
    /// after the words. `typing`: an @ word being typed, its list open.
    private static func newThread(_ model: RouterModel, pills: [RouterSetting] = [], typing: String? = nil) {
        model.select(nil)
        let words = "silo: write the changelog for 0.4"
        let marks = String(repeating: MentionText.markString + " ", count: pills.count)
        let text = words + (pills.isEmpty ? "" : " " + marks) + (typing.map { (pills.isEmpty ? " " : "") + "@" + $0 } ?? "")
        model.edit(text, marks: RouterMentions.marks(text, pointers: pills.map { .setting($0) }, name: { _ in "" }))
        model.apply(.read(RouterRead(draft: model.plainDraft, places: [.newThread(project: "silo")], sure: true,
                                       name: "write the changelog for 0.4")))
    }

    /// Your words to Checkpoint boot, sent from its block the way Return sends them; nothing selected after.
    private static func sendReply(_ model: RouterModel) {
        model.select(.line(ID.checkpoint))
        model.setDraft(RouterDemo.Item.reply)
        model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.checkpoint)], sure: true)))
        model.send()
        model.select(nil)
    }

    /// The selected card's reply longer than its quote: cut with a fade and "Show all" under it.
    private static func longReply(_ model: RouterModel) {
        guard var settings = model.thread(ID.settings) else { return }
        settings.lastLines = RouterDemo.longReply
        model.apply(.upsert(settings))
    }

    private static let opus = RouterSetting(kind: .model, value: "claude-opus-5-5", label: "Opus 5.5")
    private static let medium = RouterSetting(kind: .effort, value: "medium", label: "Medium")

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
        State(name: "v2-card-quote") { model in longReply(model) },
        State(name: "v2-card-quote-open") { model in
            longReply(model)
            model.expand(true)
        },
        State(name: "v2-card-permission") { model in
            RouterDemo.askPermission(model)
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
        State(name: "v2-card-decide") { $0.select(.line(ID.valCenis)) },
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
            model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.tab)], sure: true)))
        },
        State(name: "v2-peek", make: { $0.select(nil) }, pointer: { model in
            model.hoverRow = ID.guide
            model.hoverName = ID.guide
        }),
        State(name: "v2-peek-older", make: { $0.select(nil) }, pointer: { $0.hoverControl = .housekeepingWords }),
        // Subagents, background commands and waits: the glyphs on the lines, their peek, and the open card's list.
        State(name: "v2-activity") { activity($0) },
        State(name: "v2-activity-peek", make: { activity($0) }, pointer: { model in
            model.hoverRow = ID.tab
            model.hoverControl = .activity(ID.tab)
        }),
        State(name: "v2-activity-card") { model in
            activity(model)
            model.select(.line(ID.tab))
        },
        // Working threads as the Router's model sums them up: the page, the line's peek, the card's timeline.
        State(name: "v2-working-summary") { model in
            model.select(nil)
            RouterDemo.workingSummaries(model)
        },
        State(name: "v2-working-hover", make: { model in
            model.select(nil)
            RouterDemo.workingSummaries(model)
        }, pointer: { model in
            model.hoverRow = ID.tab
        }),
        State(name: "v2-working-card") { model in
            RouterDemo.workingSummaries(model)
            model.select(.line(ID.tab))
        },
        // Five runs read as a conversation: each run's summaries, then under them what started it as T3 marks it (your
        // words, a subagent or a background command finishing, the usage limit's reset), newest first.
        State(name: "v2-working-card-runs") { model in
            RouterDemo.workingRuns(model)
            model.select(.line(ID.tab))
        },
        // The whole kept history read back: scrolled down inside the card, faded at its bottom, two new summaries held
        // behind the `↑ 2 new` pill at its top edge.
        State(name: "v2-working-card-scroll") { model in
            RouterDemo.workingScrolled(model)
            model.select(.line(ID.tab))
        },
        // A new summary being written: the line sheens on its last one, the card's timeline unchanged under it.
        State(name: "v2-working-writing") { model in
            RouterDemo.workingSummaries(model)
            RouterDemo.writingSummary(model, ID.tab)
            model.select(.line(ID.tab))
        },
        // With a to-do list and waits: the timeline, then the steps, then what it waits on.
        State(name: "v2-working-card-steps") { model in
            RouterDemo.workingSummaries(model)
            model.select(.line(ID.checkpoint))
        },
        // Open items per thread (OPEN-ITEMS.md): Checkpoint boot's block (Stuck, Decide, Know while it runs), Bar count's
        // one item listed under its line as well; an item's card; right after your words (sheen, Fjord's mark, your line); the read landed.
        State(name: "v2-items") { model in
            model.select(nil)
            RouterDemo.items(model)
        },
        // The pointer on a running block's header: its working peek hangs under the whole block, never over its items.
        State(name: "v2-items-hover", make: { model in
            model.select(nil)
            RouterDemo.items(model)
        }, pointer: { model in
            model.hoverRow = ID.checkpoint
        }),
        State(name: "v2-items-card") { model in
            RouterDemo.items(model)
            model.select(.line(ID.checkpoint))
            model.focusItem(RouterDemo.Item.keep)
            model.pick(1)
        },
        State(name: "v2-items-checking") { model in
            RouterDemo.items(model)
            sendReply(model)
        },
        State(name: "v2-items-resolved") { model in
            RouterDemo.items(model)
            sendReply(model)
            model.itemsRead(ID.checkpoint, RouterDemo.replyRead, settle: false)
        },
        // What an item's line leaves out (OPEN-ITEMS.md): the whole sentence wrapping on the line and in a block; the
        // peek with the item's detail and the agent's words behind it; the card with them, the link and its acts.
        // In a window a little narrower, as the owner's: the Do's sentence wraps on its line too.
        State(name: "v2-item-line-wrap", make: { model in
            model.select(nil)
            RouterDemo.itemsLook(model)
        }, size: CGSize(width: 1040, height: 900)),
        State(name: "v2-item-peek", make: { model in
            model.select(nil)
            RouterDemo.itemsLook(model)
        }, pointer: { model in
            model.hoverRow = RouterModel.itemKey(ID.transcriptGap, RouterDemo.Item.update)
        }),
        State(name: "v2-item-peek-row", make: { model in
            model.select(nil)
            RouterDemo.itemsLook(model)
        }, pointer: { model in
            model.hoverRow = RouterModel.itemKey(ID.checkpoint, RouterDemo.Item.smaller)
        }),
        // The pointer on an item's row: its age gives way to a quiet Done (here under the pointer, lit); it doesn't move
        // the row.
        State(name: "v2-item-hover-done", make: { model in
            model.select(nil)
            RouterDemo.itemsLook(model)
        }, pointer: { model in
            let key = RouterModel.itemKey(ID.checkpoint, RouterDemo.Item.smaller)
            model.hoverRow = key
            model.hoverControl = .itemDone(key)
        }),
        // A thread with one item is the list shape too: its line with its Done outcome, the item on a row under it; the
        // pointer on the item's row gives its Done, as on any item.
        State(name: "v2-item-single", make: { model in
            model.select(nil)
            RouterDemo.itemsLook(model)
        }, pointer: { model in
            model.hoverRow = RouterModel.itemKey(ID.transcriptGap, RouterDemo.Item.update)
        }),
        State(name: "v2-item-card") { model in
            RouterDemo.itemsLook(model)
            model.select(.line(ID.transcriptGap))
            model.focusItem(RouterDemo.Item.update)
        },
        State(name: "v2-item-card-block") { model in
            RouterDemo.itemsLook(model)
            model.select(.line(ID.checkpoint))
            model.focusItem(RouterDemo.Item.keep)
        },
        State(name: "v2-reassessing") { model in
            model.select(nil)
            RouterDemo.askPermission(model)
            model.turnEnded(ID.upstream)
            model.pr(ID.guide, 41, .merged)
        },
        State(name: "v2-filter") { model in
            model.select(nil)
            model.toggle(project: "silo")
            model.toggle(section: .working)
            model.enterFilterMode()
        },
        // A state token pressed alone: only Done's lines, every project; the pills count under it.
        State(name: "v2-filter-state") { model in
            model.select(nil)
            model.toggle(section: .done)
        },
        State(name: "v2-filter-empty") { model in
            model.select(nil)
            model.toggle(project: "docs-site")
            model.toggle(section: .working)
        },
        State(name: "v2-destination-unsure") { model in
            model.select(nil)
            model.setDraft("the spacing is off again")
            model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.settings), .thread(ID.tab), .newThread(project: "fjord")],
                                          sure: false)))
        },
        State(name: "v2-destination-sure") { model in
            model.select(nil)
            model.setDraft("bar count: push it and open the PR")
            model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.bar)], sure: true)))
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
        State(name: "v2-new-thread-pills") { model in
            newThread(model, pills: [opus, medium])
        },
        State(name: "v2-new-thread-mention") { model in
            // "@op" typed after the words: the list offers Opus 5.5 (and the threads and projects it also finds).
            newThread(model, typing: "op")
        },
        State(name: "v2-new-thread-mention-bare") { model in
            // A bare @: a few threads, then the settings.
            newThread(model, typing: "")
        },
        State(name: "v2-new-thread-plan") { model in
            newThread(model, pills: [RouterSetting(kind: .access, value: "approval-required", label: "Supervised"),
                                     RouterSetting(kind: .mode, value: "plan", label: "Plan")])
        },
        State(name: "v2-new-thread-unsure") { model in
            model.select(nil)
            model.setDraft("the spacing is off again")
            model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.settings), .thread(ID.tab), .newThread(project: "fjord")],
                                          sure: false)))
            model.light(2)
        },
        State(name: "v2-new-thread-sent") { model in
            newThread(model, pills: [opus, medium])
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
            model.apply(.read(RouterRead(draft: model.draft, places: [], sure: false)))
        }, pointer: { $0.openPlaces() }),
        State(name: "v2-unreachable") { model in
            model.select(.line(ID.bar))
            model.setDraft("also bump the version")
            model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.bar)], sure: true)))
            model.connection(lost: true)
        },
        State(name: "v2-queued") { model in
            model.select(.line(ID.checkpoint))
            model.setDraft("then delete the old checkpoint image too")
            model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.checkpoint)], sure: true)))
            model.send(queue: true)
        },
        State(name: "v2-sent") { model in
            model.pick(2)
            model.send()
        },
        State(name: "v2-failure") { model in
            model.select(.line(ID.bar))
            model.setDraft("also bump the version")
            model.apply(.read(RouterRead(draft: model.draft, places: [.thread(ID.bar)], sure: true)))
            model.send()
            model.connection(lost: true)
            model.refused(ID.bar, reason: Router.Copy.unreachable, offline: true)
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
        // A cold launch: the finished threads' verdicts are pending, so they wait as being read (no check, the sentence
        // sheening, Fjord's mark after it) under "Reading 2 threads…", never as settled Done lines; a long T3 title takes
        // the row's room while the model names it.
        State(name: "v2-cold-reading") { model in
            model.select(nil)
            RouterDemo.coldReading(model)
        },
        State(name: "v2-nothing-needs-you") { model in
            model.select(nil)
            model.apply(.batch(model.threads.filter { $0.section == .needsYou }.map { .remove($0.id) }))
        },
    ]
}
