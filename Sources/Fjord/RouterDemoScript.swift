import AppKit
import Carbon
import SwiftUI

// Router v2's storyboard (docs/design/router-v2/DESIGN.md 6.3), played on the real page: a drawn pointer that sets hover
// and press as it moves (the real pointer is never moved), keys sent through the page's own key map, typing at 22
// characters a second, T3's events through the demo's source, and a caption per beat beside the window's title, shown
// a moment before its act (0.2 s a word) so it is read first.

/// What the script shows over the page: the beat's caption, the keys just pressed, the drawn pointer.
@MainActor @Observable
final class RouterStage {
    var beat = 0
    var caption = ""
    /// Moves with each caption: a beat can change its words on the way (the verdict lands, a thread starts again).
    var captionTick = 0
    /// Words typed where they aren't a draft (type-ahead in the filter bar): shown as text, never as a keycap (no
    /// letter key is a shortcut on this page).
    var typed = ""
    var keys: [String] = []
    var keysTick = 0
    var keysShown = false
    var pointer = CGPoint(x: 900, y: 420)
    var pointerShown = false
    var down = false
    /// Over a pill or a link: the pointing hand.
    var hand = false
}

/// Beside the title: the beat's number and caption, then the keys just pressed as keycaps.
struct RouterCaptionView: View {
    let stage: RouterStage

    var body: some View {
        HStack(spacing: 10) {
            if !stage.caption.isEmpty {
                (Text(verbatim: "\(stage.beat)").foregroundColor(CDS.Text.muted) + Text("  " + stage.caption).foregroundColor(CDS.Text.secondary))
                    .font(CDS.sans(CDS.Density.compact.body.0)).monospacedDigit().lineLimit(1)
                    .id(stage.captionTick)
                    .transition(.routerSwap)
            }
            if stage.keysShown, !stage.keys.isEmpty {
                RouterKeyHint(keys: stage.keys, ink: CDS.Text.secondary)
                    .id(stage.keysTick)
                    .transition(.opacity)
            }
            if stage.keysShown, !stage.typed.isEmpty {
                Text("typing “\(stage.typed)”").font(CDS.sans(CDS.Density.compact.footnote.0)).foregroundStyle(CDS.Text.muted)
                    .id(stage.keysTick)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 4)
        .motion(.fade, value: stage.captionTick)
        .motion(.fade, value: stage.keysTick)
        .motion(.fade, value: stage.keysShown)
        .accessibilityHidden(true)
    }
}

/// The drawn pointer: the system's arrow (the pointing hand over a pill), as a picture over the page.
struct RouterPointerView: View {
    let stage: RouterStage

    var body: some View {
        let cursor = stage.hand ? NSCursor.pointingHand : NSCursor.arrow
        Image(nsImage: cursor.image)
            .scaleEffect(stage.down ? 0.88 : 1, anchor: .topLeading)
            .offset(x: stage.pointer.x - cursor.hotSpot.x, y: stage.pointer.y - cursor.hotSpot.y)
            .opacity(stage.pointerShown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .motion(.fade, value: stage.pointerShown)
    }
}

@MainActor
final class RouterDemoScript {
    let model: RouterModel
    let source: RouterDemoSource
    let stage: RouterStage
    /// `--from <beat>`: the beats before it play at 30 times the speed.
    var from: Int?
    /// `--until <beat>`: the script ends after it.
    var until: Int?
    /// `--beats 5,6,14`: only these, one after the other.
    var only: [Int]?

    private var started = Date()
    private var task: Task<Void, Never>?
    private typealias ID = RouterDemo.ID
    private typealias Line = RouterDemoSource.Line

    init(model: RouterModel, source: RouterDemoSource, stage: RouterStage) {
        self.model = model
        self.source = source
        self.stage = stage
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor in await run() }
    }

    // MARK: Time

    private var speed: Double { source.speed }
    private var baseSpeed = 1.0

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds / speed))
    }

    /// The storyboard's clock, in its own seconds.
    private var clock: Double = 0
    private var mark = Date()

    private func now() -> Double { clock + Date().timeIntervalSince(mark) * speed }

    private func setSpeed(_ new: Double) {
        clock = now()
        mark = Date()
        source.speed = new
    }

    /// How long each beat lasts, in the storyboard's seconds (6.3). The waits inside are real ones (a read of 3.2 s, a
    /// verdict of 2.5 s, a steer of 3 s): a beat is as long as its acts and the time to read what they did.
    private static let lengths: [Double] = [
        5.0, 4.5, 3.2, 6.4,                                 // 1–4   read
        4.4, 4.6, 7.6, 7.4, 9.6, 5.6, 3.0,                  // 5–11  answer from the keyboard
        6.6, 6.2, 7.6, 6.0, 4.6, 6.6, 3.6, 7.0,             // 12–19 T3 moves, live
        4.6, 5.0, 5.6, 3.0,                                 // 20–23 filters
        8.0, 12.6, 14.0, 9.6, 6.4, 5.6, 8.2, 5.4, 9.4, 13.0, // 24–33 send
        12.0, 5.6, 3.2, 3.2, 5.6, 5.4, 6.8, 6.4, 20.4, 6.0, // 34–43 clear
        7.0,                                                // 44    a cold launch
        21.0,                                               // 45    open items
    ]
    /// When each beat starts, and when the last one ends.
    private static let times: [Double] = lengths.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1) }
    private var onlyEnds: Date?

    /// Waits for the beat's second (at once if it has passed), then shows its caption and leaves the time to read it
    /// before the beat's first act: 0.2 s a word, 0.8 s at least. With `--beats`, each beat plays for its own length, one
    /// after the other.
    private func beat(_ number: Int, _ caption: String? = nil) async {
        if let from, number >= from, speed != baseSpeed { setSpeed(baseSpeed) }
        if only == nil {
            let wait = Self.times[number - 1] - now()
            if wait > 0 { await pause(wait) }
        } else {
            if let onlyEnds { await pause(max(0, onlyEnds.timeIntervalSinceNow * speed)) }
            await pause(1.0)
            onlyEnds = Date().addingTimeInterval(Self.lengths[number - 1] / speed)
        }
        log(String(format: "beat %d  (storyboard %.1f)", number, Self.times[number - 1]))
        // The keys of the beat before don't outlive it.
        stage.keysShown = false
        if let caption {
            stage.beat = number
            say(caption)
            await pause(max(0.8, 0.2 * Double(caption.split(separator: " ").count)))
        }
    }

    /// The beat's caption, or its next words on the way.
    private func say(_ caption: String) {
        stage.caption = caption
        stage.captionTick &+= 1
    }

    private func log(_ text: String) {
        let t = Date().timeIntervalSince(started)
        FileHandle.standardError.write(Data(String(format: "v2-demo %7.2f  %@\n", t, text).utf8))
    }

    // MARK: Pointer

    private func ease(_ t: Double) -> Double {
        // cubic-bezier(0.42, 0, 0.58, 1), solved for x = t.
        func bezier(_ u: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if bezier(mid, 0.42, 0.58) < t { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, 0, 1)
    }

    /// What the pointer is on at `p`: the row and the name under it, and the smallest other thing.
    private func hover(at p: CGPoint) {
        var row: String?
        var name: String?
        var control: RouterHit?
        var area = CGFloat.infinity
        for (hit, frame) in model.targets.frames where frame.contains(p) {
            switch hit {
            case .row(let id): row = id
            case .name(let id): name = id
            case .housekeeping, .toast: continue
            default:
                if frame.width * frame.height < area {
                    area = frame.width * frame.height
                    control = hit
                }
            }
        }
        if model.hoverRow != row { model.hoverRow = row }
        if model.hoverName != name { model.hoverName = name }
        if model.hoverControl != control {
            if let old = model.hoverControl { model.hover(old, false) }
            if let control { model.hover(control, true) }
        }
        var hand = false
        if case .pill? = control { hand = true }
        if case .prBadge? = control { hand = true }
        if stage.hand != hand { stage.hand = hand }
        if let control { model.pointerMoved(over: control, at: p) }
    }

    /// Moves the drawn pointer along an eased path; hover follows it on the way.
    private func move(to point: CGPoint) async {
        let from = stage.pointer
        let distance = hypot(point.x - from.x, point.y - from.y)
        guard distance > 0.5 else { hover(at: point); return }
        if !stage.pointerShown { stage.pointerShown = true }
        // A pointer move is the owner's: a card their last act opened is now seen.
        model.ownerActed()
        // 0.35 s a move, a little longer across the page so the eye can follow.
        let duration = (0.35 + min(0.2, Double(distance) / 2400)) / speed
        let glide = Animation.timingCurve(0.42, 0, 0.58, 1, duration: duration).resolved(reduce: false)
        withAnimation(glide) { stage.pointer = point }
        let began = Date()
        while true {
            let t = min(1, Date().timeIntervalSince(began) / duration)
            let e = ease(t)
            hover(at: CGPoint(x: from.x + (point.x - from.x) * e, y: from.y + (point.y - from.y) * e))
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The frame of something on the page, once it is laid out.
    private func frame(_ hit: RouterHit) async -> CGRect? {
        for _ in 0..<60 {
            if let frame = model.targets.frames[hit] { return frame }
            try? await Task.sleep(for: .milliseconds(16))
        }
        log("no frame for \(hit)")
        return nil
    }

    /// Where the pointer's tip goes on a thing: a row at the start of its sentence, a name inside it; anything else in
    /// its lower-right third, so the arrow never covers the words it clicks.
    private func point(_ hit: RouterHit, _ frame: CGRect) -> CGPoint {
        switch hit {
        case .row: CGPoint(x: frame.minX + frame.width * 0.52, y: frame.midY + 4)
        case .name: CGPoint(x: frame.minX + min(frame.width - 6, 64), y: frame.midY + 4)
        case .housekeepingWords: CGPoint(x: frame.minX + 70, y: frame.midY + 4)
        default: CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + frame.height * 0.72)
        }
    }

    private func move(to hit: RouterHit) async {
        guard let frame = await frame(hit) else { return }
        await move(to: point(hit, frame))
    }

    /// `rehover`: what the pointer is on once the page has moved under it lights (off when the script moves on at once).
    private func click(_ hit: RouterHit, rehover: Bool = true) async {
        await move(to: hit)
        await pause(0.14)
        stage.down = true
        model.pressed = hit
        await pause(0.1)
        stage.down = false
        model.pressed = nil
        if let action = model.targets.actions[hit] { action() } else { log("no action for \(hit)") }
        // The page moved under the pointer: what it is on now.
        guard rehover else { return }
        await pause(0.4)
        hover(at: stage.pointer)
    }

    /// Off the list, at the column's right, where it lights nothing.
    private func park() async {
        let x = model.targets.viewport.width - 70
        await move(to: CGPoint(x: x, y: min(stage.pointer.y, model.targets.viewport.height - 220)))
    }

    // MARK: Keys

    /// The keys just pressed, beside the caption: gone after 0.8 s, or with the beat.
    private func show(_ caps: [String], typed: String = "") {
        stage.keys = caps
        stage.typed = typed
        stage.keysTick &+= 1
        stage.keysShown = true
        let tick = stage.keysTick
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8 / speed))
            if stage.keysTick == tick { stage.keysShown = false }
        }
    }

    private func key(_ caps: [String], code: Int, flags: NSEvent.ModifierFlags = [], characters: String? = nil) {
        show(caps)
        // Timed as a real key is (`RouterKeys.key`): "Key" and "Key work".
        _ = RouterSignposts.key { RouterKeys.handle(RouterKey(code: code, flags: flags, characters: characters), model: model, inField: false) }
    }

    private func digit(_ n: Int) { key(["shift", "\(n)"], code: RouterKeys.digits[n - 1], flags: .shift, characters: "\(n)") }
    private func enter() { key(["enter"], code: kVK_Return) }
    private func escape() { key(["esc"], code: kVK_Escape) }
    private func down(option: Bool = false) { key(option ? ["alt", "down"] : ["down"], code: kVK_DownArrow, flags: option ? .option : []) }
    private func up() { key(["up"], code: kVK_UpArrow) }
    private func settle() { key(["cmd", "backspace"], code: kVK_Delete, flags: .command) }

    /// Types into the composer, 22 characters a second, each key through the page's map.
    private func type(_ text: String) async {
        for ch in text {
            let code = ch == " " ? kVK_Space : ch.wholeNumberValue.flatMap { $0 >= 1 ? RouterKeys.digits[$0 - 1] : nil } ?? -1
            _ = RouterSignposts.key { RouterKeys.handle(RouterKey(code: code, characters: String(ch)), model: model, inField: false) }
            await pause(1.0 / 22)
        }
    }

    private func thread(named name: String) -> String? { model.threads.first { $0.name == name }?.id }

    // MARK: The script

    private func run() async {
        started = Date()
        mark = Date()
        baseSpeed = source.speed
        if from != nil { source.speed = 30 * baseSpeed }
        // The recording's first second is trimmed: the storyboard's t = 0 is there.
        try? await Task.sleep(for: .seconds(1))
        mark = Date()
        clock = 0
        // Played alone from beat 45: its scene is set before the frames start (the frames are the beat's motion).
        if (only?.first ?? from) == 45 {
            itemsScene()
            try? await Task.sleep(for: .seconds(0.6))
        }
        if from == nil { RouterDemo.frames?.start() }
        let beats: [(Int, () async -> Void)] = [
            (1, beat1), (2, beat2), (3, beat3), (4, beat4), (5, beat5), (6, beat6), (7, beat7), (8, beat8), (9, beat9), (10, beat10),
            (11, beat11), (12, beat12), (13, beat13), (14, beat14), (15, beat15), (16, beat16), (17, beat17), (18, beat18), (19, beat19),
            (20, beat20), (21, beat21), (22, beat22), (23, beat23), (24, beat24), (25, beat25), (26, beat26), (27, beat27),
            (28, beat28), (29, beat29), (30, beat30), (31, beat31), (32, beat32), (33, beat33), (34, beat34), (35, beat35),
            (36, beat36), (37, beat37), (38, beat38), (39, beat39), (40, beat40), (41, beat41), (42, beat42), (43, beat43),
            (44, beat44), (45, beat45),
        ]
        if let shape = Self.selectCheck {
            RouterDemo.frames?.start()
            await selectCheck(few: shape == "few")
        }
        for (number, play) in beats where Self.selectCheck == nil && (only?.contains(number) ?? true) && number <= (until ?? .max) {
            // With `--from`, the frames start with the first beat played at its own speed.
            if let from, number == from { RouterDemo.frames?.start() }
            await play()
        }
        if Self.selectCheck != nil {
            await pause(1)
        } else if only != nil {
            if let onlyEnds { await pause(max(0, onlyEnds.timeIntervalSinceNow * speed)) }
            await pause(2)
        } else if let until, until < beats.count {
            await pause(Self.times[until] - now())
        } else {
            await pause(Self.times[beats.count] - now())
        }
        log("end")
        RouterDemo.frames?.finish()
        if WindowRecorder.isRequested {
            WindowRecorder.finish()
        } else if CommandLine.arguments.contains("--quit-after") {
            NSApp.terminate(nil)
        } else {
            // The script is over: the page is the owner's to try.
            stage.pointerShown = false
            model.scripted = false
        }
    }

    // MARK: The select check

    /// `--select-check [few]`: instead of the beats, cards opened and shut every way, to check in the frames that a line
    /// opens its card in place and no row goes missing on the way (`--frames`, its `rows-*.json`). `few`: a page shaped
    /// as a real one, five lines.
    static let selectCheck: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--select-check") else { return nil }
        return i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "all"
    }()

    private func selectCheck(few: Bool) async {
        if few {
            let keep: Set<String> = [ID.settings, ID.updater, ID.guide, ID.bar, ID.checkpoint]
            model.apply(.batch(model.threads.filter { !keep.contains($0.id) }.map { .remove($0.id) } + [.older([])]))
            await pause(1)
        }
        stage.pointerShown = true
        // The open card shut, then cards opened from nothing, mid-list and last, and shut again.
        escape()
        await pause(1.2)
        let lines = model.shownLines.map(\.id)
        guard lines.count >= 3, let last = lines.last else { return }
        let middle = lines[lines.count / 2]
        for (note, id) in [("open middle", middle), ("switch to last", last), ("shut last", last), ("open last", last),
                           ("switch to first", lines[0]), ("switch to middle", middle), ("shut middle", middle)] {
            RouterFrames.note(note)
            await click(.row(id))
            await pause(1.0)
        }
        await park()
        // The arrows: down the list from nothing, back up, and out.
        for _ in 0..<lines.count {
            RouterFrames.note("down")
            down()
            await pause(0.7)
        }
        for _ in 0..<2 {
            RouterFrames.note("up")
            up()
            await pause(0.7)
        }
        RouterFrames.note("escape")
        escape()
        await pause(1.2)
        await longReply()
    }

    /// A card whose reply is longer than its quote (a line both shapes keep, so no row folds in): → rolls the quote open
    /// to its whole text and it stays so until ←; then the same by its "Show all" and "Show less".
    private func longReply() async {
        guard var t = model.thread(ID.settings) else { return }
        t.lastLines = RouterDemo.longReply
        model.apply(.upsert(t))
        await pause(0.6)
        RouterFrames.note("open long reply")
        await click(.row(t.id))
        await pause(1.0)
        RouterFrames.note("right")
        key(["right"], code: kVK_RightArrow)
        await pause(1.5)
        RouterFrames.note("left")
        key(["left"], code: kVK_LeftArrow)
        await pause(1.2)
        RouterFrames.note("show all")
        await click(.longText(t.id))
        await pause(1.5)
        RouterFrames.note("show less")
        // The quote shuts from under the pointer, which stays put: rows gliding under it would light and peek over the
        // rows checked.
        await click(.longText(t.id), rehover: false)
        await pause(1.2)
        RouterFrames.note("escape")
        escape()
        await pause(1.2)
    }

    // Act 1: read

    private func beat1() async {
        await beat(1, "One line per thread, grouped by state")
    }

    private func beat2() async {
        // In from the right, across three rows, to rest on a name.
        stage.pointer = CGPoint(x: model.targets.viewport.width - 60, y: model.targets.viewport.height - 260)
        await beat(2, "Hover a name: a read-only peek")
        stage.pointerShown = true
        await pause(0.2)
        await move(to: .row(ID.tab))
        await move(to: .row(ID.bar))
        await pause(0.15)
        await move(to: .name(ID.guide))
    }

    private func beat3() async {
        await beat(3)
        await move(to: .name(ID.disk))
        await pause(1.7)
        await park()
    }

    private func beat4() async {
        await beat(4, "Click opens its card")
        await click(.row(ID.guide))
        await pause(1.9)
        await click(.row(ID.settings))
        await pause(0.4)
        await park()
    }

    // Act 2: answer from the keyboard

    private func beat5() async {
        await beat(5, "⇧ + a digit picks. Nothing is sent yet")
        digit(2)
        await pause(1.0)
        digit(3)
        await pause(0.9)
        digit(2)
    }

    private func beat6() async {
        await beat(6, "Return sends: Sent, then Working")
        // The Sent line stays long enough to be read: this run starts 1.6 s after the send.
        source.runDelay[ID.settings] = 1.6
        enter()
    }

    private func beat7() async {
        await beat(7, "Or just type: the row says where")
        await type("five, and ask for a late checkout on the 21st")
        // A follow-up to a waiting thread: the read lands in half a second.
        await pause(2.0)
        enter()
    }

    private func beat8() async {
        await beat(8, "Plan: → shows all of it")
        key(["right"], code: kVK_RightArrow)
        await pause(2.0)
        key(["left"], code: kVK_LeftArrow)
        await pause(1.1)
        digit(1)
        await pause(1.2)
        enter()
    }

    private func beat9() async {
        await beat(9, "Form: ⇧ + a digit per question, or type")
        digit(2)
        await pause(1.0)
        digit(3)
        await pause(1.0)
        // Tab is for this: the question typed words answer.
        key(["shift", "tab"], code: kVK_Tab, flags: .shift)
        await pause(0.8)
        await type("ask first, but never mid-call")
        await pause(1.1)
        enter()
        await pause(1.2)
        enter()
    }

    private func beat10() async {
        await beat(10, "Stopped: the reason, and Continue")
        await pause(1.8)
        enter()
    }

    private func beat11() async {
        await beat(11, "Nothing needs you")
    }

    // Act 3: T3 moves, live

    private func beat12() async {
        await beat(12, "A thread asks: it moves at once")
        RouterDemo.askPermission(model)
        source.verdict(ID.checkpoint, line: "wants to remove the old checkpoint worktree, with --force")
        await pause(RouterDemoSource.verdictWords)
        say("Then Fjord shortens the line")
    }

    private func beat13() async {
        await beat(13, "Permission: the command and its warning")
        down()
        await pause(2.0)
        digit(1)
        await pause(1.0)
        enter()
    }

    private func beat14() async {
        await beat(14, "A turn ends: Done at once")
        source.endTurn(ID.upstream, line: "PR #2049 is open: read the diff, then merge it",
                       lastLines: "I replied on the issue and opened PR #2049 with the fix for restore by id. It needs your review before it can merge.",
                       prs: [.init(number: 2049, state: .open)], diff: .init(files: 2, added: 38, removed: 6),
                       step: ("Read the diff of PR #2049, then merge it.", [], "replied on the issue; PR #2049"), stateWord: false)
        await pause(RouterDemoSource.verdictState)
        say("Then Fjord finds a step for you")
    }

    private func beat15() async {
        await beat(15, "A PR merges: T3 sees it within a minute")
        model.pr(ID.guide, 41, .merged)
        // Merged is not "live": the words stay, only the state word and the ground change.
        source.verdict(ID.guide, line: "rewritten for the Chrome setup; PR #41") { $0.verdict(ID.guide, worth: .quiet) }
    }

    private func beat16() async {
        await beat(16, "A new thread appears")
        let title = "Fix the sidebar glass on resize"
        var t = RouterThread(id: ID.glass, name: Router.firstWords(title), title: title, project: "fjord", state: .working,
                               sentence: .init(text: Router.Copy.starting), since: model.now)
        t.naming = true
        t.isNew = true
        model.appeared(t)
        source.after(0.9) { [model] in model.step(ID.glass, "Reading SidebarGlass.swift") }
        source.after(RouterDemoSource.naming) { [model] in model.named(ID.glass, "Sidebar glass") }
    }

    private func beat17() async {
        await beat(17, "A turn ends on an error: Fjord flags it")
        // A failed build is a finished turn in T3: it arrives as Done, and only the verdict can say it went wrong.
        source.endTurn(ID.snapshot, line: "the build fails: cannot find 'RestoreToken'; it stopped there",
                       lastLines: "I added `restore(id:)` and its tests, but the package no longer builds: `cannot find 'RestoreToken' in scope` at Snapshots.swift:212. I could not find where it is defined, so I stopped here.",
                       diff: .init(files: 3, added: 74, removed: 9),
                       step: ("Fix the build, or tell it how.", [], "restore by id added; the build fails on 'RestoreToken'"))
    }

    private func beat18() async {
        await beat(18, "Settled in T3: it just leaves")
        model.left(ID.guide)
    }

    private func beat19() async {
        await beat(19, "Subagents, background work and waits, at a glance")
        for (id, a) in RouterDemo.activity(at: model.now) { model.activity(id, a) }
        await pause(0.6)
        stage.pointerShown = true
        await move(to: .activity(ID.tab))
        await pause(2.2)
        await move(to: .activity(ID.checkpoint))
        await pause(1.4)
        // One of Tab handover's subagents is done: its count goes, the glyph stays.
        if var a = model.thread(ID.tab)?.activity {
            a.agents.removeFirst()
            model.activity(ID.tab, a)
        }
        await park()
    }

    // Act 4: filters

    private func beat20() async {
        await beat(20, "Click a project pill: the page filters")
        await click(.pill(ID.disk))
        await pause(0.6)
        await park()
    }

    private func beat21() async {
        await beat(21, "Add a state")
        await click(.state(.working))
        await pause(1.5)
        await click(.state(.working))
        await pause(0.3)
        await park()
    }

    private func beat22() async {
        await beat(22, "⌘F: filter from the keyboard")
        key(["cmd", "F"], code: kVK_ANSI_F, flags: .command, characters: "f")
        await pause(1.3)
        // Type-ahead, shown as typed text: no letter is a shortcut.
        show([], typed: "f")
        _ = RouterKeys.handle(RouterKey(code: kVK_ANSI_F, characters: "f"), model: model, inField: false)
        await pause(1.3)
        enter()
    }

    private func beat23() async {
        await beat(23, "Esc clears")
        escape()
    }

    // Act 5: send

    private func beat24() async {
        await beat(24, "Type with nothing selected: Fjord finds the place")
        let words = "bar count: push it and open the PR"
        source.reads[words] = RouterRead(draft: words, places: [.thread(ID.bar)], sure: true)
        await type(words)
        await pause(2.1)
        enter()
    }

    private func beat25() async {
        await beat(25, "Not sure: its guess first, ⌘1–3 pick")
        let words = "the spacing is off again"
        source.reads[words] = RouterRead(draft: words, places: [.thread(ID.settings), .thread(ID.tab), .newThread(project: "fjord")], sure: false)
        await type(words)
        // An unsure place is Sonnet's call: about three seconds, Fjord's mark in the row meanwhile.
        await pause(RouterDemoSource.slowRead + 1.5)
        key(["cmd", "2"], code: kVK_ANSI_2, flags: .command, characters: "2")
        await pause(1.5)
        enter()
    }

    private func beat26() async {
        await beat(26, "A working thread: Return steers, ⌥ queues")
        model.step(ID.checkpoint, "Checking the boot log",
                   steps: RouterDemo.steps(["Building the boot image", "Removing the old worktree", "Booting the VM from the checkpoint",
                                              "Checking the boot log", "Updating the README"], running: 3))
        await click(.row(ID.checkpoint))
        source.write(ID.checkpoint, "The VM boots from the checkpoint in 3.1 s. I am reading the boot log for the disk warnings we saw last week; two are gone, one is still there and I am tracing it to the image's fstab now.")
        await park()
        await pause(0.6)
        await type("then delete the old checkpoint image too")
        // The card's thread shows at once; what Return does there comes with the read.
        await pause(RouterDemoSource.slowRead + 0.9)
        show(["alt"])
        model.setOption(true)
        await pause(0.9)
        model.setOption(false)
        await pause(0.7)
        show(["alt"])
        model.setOption(true)
        await pause(0.7)
        key(["alt", "enter"], code: kVK_Return, flags: .option)
        model.setOption(false)
    }

    /// The new thread's words.
    private static let newThread = "silo: write the changelog for 0.4"

    private func beat27() async {
        await beat(27, "A new thread: the row shows how it starts")
        let words = Self.newThread
        source.reads[words] = RouterRead(draft: words, places: [.newThread(project: "silo")], sure: true, name: "write the changelog for 0.4")
        source.names[words] = "Changelog 0.4"
        source.newSteps[words] = .command("git log v0.3..HEAD --oneline")
        escape()
        await pause(0.6)
        await type(words)
    }

    private func beat28() async {
        await beat(28, "Tab into the row: arrows change a setting")
        key(["tab"], code: kVK_Tab)
        await pause(1.0)
        key(["right"], code: kVK_RightArrow)
        await pause(1.0)
        // Reasoning effort: its menu opens, High to Extra high.
        key(["down"], code: kVK_DownArrow)
    }

    private func beat29() async {
        await beat(29, "Or click a chip: its menu")
        guard let sonnet = model.launchModels.firstIndex(where: { $0.id == "claude-sonnet-5-5" }) else { return }
        await click(.launch(.model))
        await pause(0.9)
        await click(.launchChoice(.model, sonnet))
        await pause(0.3)
        await park()
    }

    private func beat30() async {
        await beat(30, "Or type @: the list offers the settings")
        // @op: Opus 5.5 is the list's first row; Return makes it a pill and the chip rolls to it. @med: Medium, the same.
        await type(" @op")
        await pause(1.0)
        model.pickScripted()
        await pause(1.1)
        await type("@med")
        await pause(1.0)
        model.pickScripted()
    }

    private func beat31() async {
        await beat(31, "Return starts it; the pills stay behind")
        enter()
    }

    private func beat32() async {
        await beat(32, "Return early: it goes when Fjord knows where")
        let words = "lcu: add a --dry-run flag to lcu apps"
        source.reads[words] = RouterRead(draft: words, places: [.newThread(project: "lcu")], sure: true, name: "add a --dry-run flag")
        source.names[words] = "Dry-run flag"
        source.newSteps[words] = .words("Reading Apps.swift")
        await type(words)
        await pause(0.15)
        // Before the read: the words are held, and go when it lands sure.
        enter()
    }

    private func beat33() async {
        await beat(33, "A send fails: it stays by the composer")
        let words = "snapshot api: RestoreToken moved to SiloCore"
        source.reads[words] = RouterRead(draft: words, places: [.thread(ID.snapshot)], sure: true)
        await type(words)
        await pause(1.5)
        enter()
        // T3 drops while the words are on their way.
        await pause(0.3)
        source.drop()
        await pause(2.2)
        source.reconnect()
        await pause(1.4)
        enter()
    }

    // Act 6: clear

    private func beat34() async {
        await beat(34, "Turns end; each line is read alone")
        source.endTurn(ID.settings, worth: .look, line: "now one scrolling page; PR #58",
                       lastLines: "Settings is one scrolling page now, with the sections in the order of the old tabs. The sidebar code is gone.",
                       prs: [.init(number: 58, state: .open)], diff: .init(files: 5, added: 184, removed: 97))
        await pause(1.2)
        source.endTurn(ID.briefs, worth: .look, line: "briefs moved into NoteLog; tests pass; PR #59",
                       lastLines: "The briefs live in NoteLog now. The old rows were copied once and checked row by row; briefs.db is kept for one release. All suites pass.",
                       prs: [.init(number: 59, state: .open)], diff: .init(files: 6, added: 212, removed: 148))
        await pause(1.2)
        source.endTurn(ID.valCenis, line: "reserved for five; late checkout asked; the confirmation is in your inbox",
                       lastLines: "Reserved for five, €1,302 for the week. I asked for a late checkout on the 21st; the owner answers within a day. The confirmation is in your inbox.")
        await pause(1.4)
        // One run end in four is followed by a new run: Done, sheening, then Working again with no line written.
        source.endTurn(ID.tab, line: "the tab hands over with no gap")
        await pause(1.1)
        source.restart(ID.tab, .words("Editing TabHandover.swift"))
        say("It started again: no line was written")
        await pause(2.2)
        // Checkpoint boot's turn ends and its queued words go.
        model.turnEnded(ID.checkpoint)
    }

    private func beat35() async {
        await beat(35, "Done: the result, the PR, what changed")
        down(option: true)
        await pause(0.9)
        down(option: true)
    }

    private func beat36() async {
        await beat(36, "Settle: gone at once")
        settle()
    }

    private func beat37() async {
        await beat(37, "⌘Z brings it back")
        key(["cmd", "Z"], code: kVK_ANSI_Z, flags: .command, characters: "z")
    }

    private func beat38() async {
        await beat(38, "⌘⌫ twice: two lines, one toast")
        settle()
        // The next card is read before it is settled too.
        await pause(1.8)
        settle()
    }

    private func beat39() async {
        await beat(39, "Snooze")
        key(["alt", "cmd", "backspace"], code: kVK_Delete, flags: [.command, .option])
        await pause(1.0)
        down()
        await pause(0.6)
        down()
        await pause(0.8)
        enter()
    }

    private func beat40() async {
        await beat(40, "Done on an open item: it strikes, then folds, and the thread goes to Done")
        down()
        await pause(2.2)
        await click(.footer(RouterModel.itemKey(ID.upstream, "i1"), .settle))
        await park()
    }

    private func beat41() async {
        await beat(41, "Finished earlier: one line, one act")
        await move(to: .housekeepingWords)
        await pause(2.2)
        await click(.settleAll)
        await pause(0.4)
        await park()
    }

    private func beat42() async {
        await beat(42, "Clearing the rest")
        // What was flagged is dealt with before it is settled: PR #2049 merges, and its line goes quiet.
        model.pr(ID.upstream, 2049, .merged)
        source.verdict(ID.upstream, line: "replied on the issue; PR #2049") { $0.verdict(ID.upstream, worth: .quiet) }
        let ends: [(String?, String, String, [RouterThread.PR])] = [
            (ID.updater, "asks before installing, never mid-call; stable channel",
             "Updates ask first and never during a call, from the stable channel. The tests pass.", []),
            (ID.disk, "the flake was a 120 s timeout under load; raised and fixed",
             "The test waited 120 s for the disk image, which is too short under load. I raised the wait and made the restore report its progress. 50 runs, no failure.", []),
            (ID.tab, "the tab hands over with no gap; spacing matches T3",
             "The tab hands over with no gap now, the draft and the caret survive it, and the composer's spacing matches T3 to the point.", []),
            (ID.checkpoint, "boots from a checkpoint; old worktree and image removed",
             "The VM boots from the checkpoint in 3.1 s. The old worktree and the old checkpoint image are removed.", []),
            (ID.glass, "the glass no longer flickers on resize",
             "The sidebar's glass keeps one layer through a resize, so it no longer flickers.", []),
            (ID.bar, "pushed; PR #60",
             "Pushed the branch and opened PR #60.", [.init(number: 60, state: .open)]),
            (thread(named: "Changelog 0.4"), "changelog written for 0.4",
             "The changelog for 0.4 is written from the 38 commits since 0.3, grouped by tool.", []),
            (thread(named: "Dry-run flag"), "lcu apps takes --dry-run; tests pass",
             "`lcu apps allow` and `revoke` take `--dry-run` and print what they would change. The tests pass.", []),
            (ID.snapshot, "the build passes with RestoreToken from SiloCore",
             "Imported SiloCore for `RestoreToken`. The package builds and the restore tests pass.", []),
        ]
        await pause(0.6)
        // Nine turns end, 0.4 s apart. Four verdicts at most run at once: the fifth and later lines sheen until a call
        // is free.
        for (id, line, reply, prs) in ends {
            if let id { source.endTurn(id, line: line, lastLines: reply, prs: prs) }
            await pause(0.4)
        }
        // Once the last line has streamed in: to Done's first line, then one ⌘⌫ a line, top to bottom.
        await pause(5.4)
        down(option: true)
        await pause(0.9)
        while model.selectedThread != nil {
            settle()
            await pause(0.6)
        }
    }

    private func beat43() async {
        await beat(43, "Nothing left")
        // The last toast doesn't sit on the empty page for its eight seconds.
        await pause(2.2)
        model.dismissToast()
    }

    // Act 6: a cold launch

    private func beat44() async {
        await beat(44, "A cold launch: Fjord reads what finished first")
        // The demo's threads as a relaunch finds them: the finished ones' verdicts pending, nothing known to need you.
        RouterDemo.coldReading(model, threads: RouterDemo.records().threads)
        await pause(2.0)
        // The guide's verdict: it left you a step. Its state first (it moves up under Needs you), then its words.
        if var guide = model.thread(ID.guide) {
            guide.judging = false
            guide.ledger.items = [RouterItem(id: "i1", kind: .do, sentence: "check the Chrome steps, then merge #41", since: model.now, state: .new)]
            model.apply(.upsert(guide))
            await pause(0.5)
            guide.name = "Install guide"
            guide.naming = false
            guide.sentence = .init(text: "rewritten for Chrome; check the steps, then merge #41")
            model.apply(.upsert(guide))
        }
        await pause(1.4)
        // The bar's: done, quiet. The reading row goes with it.
        if var bar = model.thread(ID.bar) {
            bar.judging = false
            bar.sentence = .init(text: "counts only unread; tests pass, not pushed")
            model.apply(.upsert(bar))
        }
        await pause(1.0)
    }

    // Act 7: open items (OPEN-ITEMS.md)

    /// The demo's threads as at t = 0 with their open items, in one still step.
    private func itemsScene() {
        model.selection = nil
        model.apply(.batch(RouterDemo.records().threads.map { .upsert($0) }))
        RouterDemo.items(model)
    }

    private func beat45() async {
        // The demo's threads as at t = 0, with Checkpoint boot's open items (Stuck, Decide, Know while it runs) and Bar
        // count's one: set in one still step, before the caption (the scene, not the beat's motion).
        if model.thread(ID.checkpoint)?.ledger.isEmpty != false { itemsScene() }
        await beat(45, "Your message is checked against what's open")
        await pause(0.8)
        // Its header's card, then your words: Return shows them in the block at once, the items sheen, Fjord's mark.
        await click(.row(ID.checkpoint))
        await park()
        await type(RouterDemo.Item.reply)
        await pause(RouterDemoSource.slowRead + 0.3)
        RouterFrames.note("send")
        enter()
        await pause(2.2)
        // The read lands: the choice it answered strikes, then folds away; a step for you folds in, lit.
        say("Answered items strike; new ones fold in")
        RouterFrames.note("read")
        model.itemsRead(ID.checkpoint, RouterDemo.replyRead)
        await pause(2.8)
        // A new turn: the header pulses once, the items sheen, a placeholder where new ones land.
        say("A new turn is read the same way")
        RouterFrames.note("turn")
        model.itemsTurnEnded(ID.checkpoint)
        await pause(2.2)
        RouterFrames.note("turn read")
        model.itemsRead(ID.checkpoint, RouterDemo.turnRead)
        await pause(2.2)
    }
}
