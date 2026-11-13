import AppKit
import SwiftUI

// Router v2's page model: a send that failed, the acts with a Revert (Settle, Snooze, Doesn't need me), and Esc.

extension RouterModel {
    // MARK: Failures

    func sendAgain(_ failure: Int) {
        guard let f = failures.first(where: { $0.id == failure }), let t = thread(f.thread) else { return }
        animate(.spatial) {
            failures.removeAll { $0.id == failure }
            if selection == .failure(failure) { selection = nil }
        }
        dispatch(f.words, to: t, kind: f.kind)
    }

    /// Edit: the words go back to the composer, the line goes.
    func edit(_ failure: Int) {
        guard let f = failures.first(where: { $0.id == failure }) else { return }
        animate(.spatial) {
            failures.removeAll { $0.id == failure }
            if selection == .failure(failure) { selection = nil }
        }
        if !f.continuing { setDraft(f.words) }
        focusTick &+= 1
    }

    // MARK: Acts with a Revert

    private func act(_ toast: RouterToast, threads: [String], undo: @escaping () -> Void) {
        undos.append((toast.id, threads, undo))
        animate(.fade) { self.toast = toast }
        startToastLife(Router.toastLife)
        undoManager?.registerUndo(withTarget: self) { model in model.revert(toast.id) }
        undoManager?.setActionName(toast.before)
        disarm()
    }

    func startToastLife(_ seconds: Double) {
        toastLife?.cancel()
        guard !still else { return }
        // The clock stops while the pointer is on it (`hover`), and starts again as it leaves.
        guard hoverControl != .toast, hoverControl != .revert else { return }
        toastLife = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.animate(.fade) { self.toast = nil }
        }
    }

    /// The toast leaves now (the demo's last one, on an empty page).
    func dismissToast() {
        toastLife?.cancel()
        animate(.fade) { toast = nil }
    }

    /// ⌘Z or Revert: the newest act, undone.
    func undo() {
        guard let last = undos.last else { return }
        revert(last.toast)
    }

    var canUndo: Bool { !undos.isEmpty }

    func revert(_ id: Int) {
        guard let i = undos.firstIndex(where: { $0.toast == id }) else {
            // A toast with nothing left to revert (the act was refused): Revert only takes it away.
            if toast?.id == id { dismissToast() }
            return
        }
        let entry = undos.remove(at: i)
        entry.undo()
        if toast?.id == id {
            toastLife?.cancel()
            animate(.fade) { toast = nil }
        }
    }

    /// T3 refused a settle or a snooze: the line is back through its record; the act has nothing left to revert for that
    /// thread (an act on several keeps its Revert for the others), and the toast says why, with no Revert.
    func actRefused(_ id: String, reason: String) {
        var named = thread(id)?.name ?? older.first { $0.id == id }?.name ?? ""
        if let i = undos.firstIndex(where: { $0.threads.contains(id) }) {
            if toast?.id == undos[i].toast, named.isEmpty { named = toast?.name ?? "" }
            undos[i].threads.removeAll { $0 == id }
            if undos[i].threads.isEmpty { undos.remove(at: i) }
        }
        let refusal = RouterToast(id: fresh(), before: "T3 refused it for", name: named.isEmpty ? "this thread" : named,
                                    after: "· " + reason, revertible: false)
        animate(.fade) { toast = refusal }
        startToastLife(Router.toastLife)
    }

    /// Settle: the line leaves at once.
    func settle(_ id: String) {
        guard let t = thread(id) else { return }
        remove(t, toast: RouterToast(id: fresh(), before: "Settled", name: t.name)) { [weak self] in
            self?.source?.settle([id], on: false)
        }
        source?.settle([id], on: true)
    }

    func snooze(_ id: String, choice: Int) {
        guard let t = thread(id) else { return }
        remove(t, toast: RouterToast(id: fresh(), before: "Snoozed", name: t.name, after: Router.Copy.snoozedUntil[choice])) { [weak self] in
            self?.source?.snooze(id, until: nil)
        }
        source?.snooze(id, until: Self.snoozeEnd(choice, from: Date()))
    }

    /// When a snooze choice ends (`Router.Copy.snoozeChoices`): in an hour, in three, tomorrow at 9:00.
    static func snoozeEnd(_ choice: Int, from now: Date, calendar: Calendar = .current) -> Date {
        switch choice {
        case 0: return now.addingTimeInterval(3_600)
        case 1: return now.addingTimeInterval(3 * 3_600)
        default:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }

    /// `reverted`: what the Revert tells the source, after the line is back.
    private func remove(_ t: RouterThread, toast: RouterToast, reverted: @escaping () -> Void) {
        let next = selection == .line(t.id) ? neighbour(of: t.id) : selection
        let kept = (picks[t.id], typed[t.id])
        animate(.spatial) {
            threads.removeAll { $0.id == t.id }
            selection = next
            snoozeMenu = nil
            settleFilters()
        }
        advanced(to: next)
        act(toast, threads: [t.id]) { [weak self] in
            guard let self else { return }
            // It grows back where it was, selected.
            self.animate(.spatial) {
                self.threads.append(t)
                self.picks[t.id] = kept.0
                self.typed[t.id] = kept.1
                self.selection = .line(t.id)
            }
            self.show(t.id)
            reverted()
        }
    }

    /// The filtered project has no line left: its pill is gone, so is the filter.
    func settleFilters() {
        if let project, !projects.contains(project), !older.contains(where: { $0.project == project }) { self.project = nil }
    }

    /// Settle all on the housekeeping line.
    func settleAll() {
        let gone = shownOlder
        guard !gone.isEmpty else { return }
        let all = older
        animate(.spatial) {
            older.removeAll { o in gone.contains { $0.id == o.id } }
            if selection == .housekeeping { selection = nil }
            if hoverControl == .housekeepingWords || hoverControl == .settleAll { hoverControl = nil }
        }
        let name = gone.count == 1 ? gone[0].name : "\(gone.count) older threads"
        let ids = gone.map(\.id)
        act(RouterToast(id: fresh(), before: "Settled", name: name), threads: ids) { [weak self] in
            guard let self else { return }
            self.animate(.spatial) { self.older = all }
            self.source?.settle(ids, on: false)
        }
        source?.settle(ids, on: true)
    }

    /// Doesn't need me: a wrong verdict goes to Done, its line the verdict's result and no longer the ask.
    func notForMe(_ id: String) {
        guard let t = thread(id), t.state == .needsYou(.step) else { return }
        let next = selection == .line(id) ? neighbour(of: id) : selection
        move(id) {
            update(id) {
                $0.state = .done
                $0.worth = .look
                $0.since = now
                $0.order = fresh()
                if let result = $0.result { $0.sentence = .init(text: result, stream: $0.sentence.stream) }
                $0.question = nil
                $0.options = []
            }
            picks[id] = nil
            selection = next
        }
        advanced(to: next)
        act(RouterToast(id: fresh(), before: "Moved", name: t.name, after: "to Done"), threads: [id]) { [weak self] in
            guard let self else { return }
            self.move(id) {
                self.update(id) { $0 = t }
                self.selection = .line(id)
            }
            self.source?.notForMe(id, on: false)
        }
        source?.notForMe(id, on: true)
    }

    /// ⌘⌫: settles the selected row (the housekeeping line: all; a failure line: Edit).
    func settleSelected() {
        switch selection {
        case .line(let id)?: settle(id)
        case .housekeeping?: settleAll()
        case .failure(let id)?: edit(id)
        case nil: break
        }
    }

    func openSnooze() {
        guard let t = selectedThread, t.state != .working, t.state != .sent else { return }
        animate(.fade) { snoozeMenu = snoozeMenu == nil ? RouterSnoozeMenu(thread: t.id) : nil }
    }

    func moveSnooze(down: Bool) {
        guard var menu = snoozeMenu else { return }
        let n = Router.Copy.snoozeChoices.count
        menu.index = (menu.index + (down ? 1 : n - 1)) % n
        snoozeMenu = menu
    }

    func chooseSnooze(_ index: Int? = nil) {
        guard let menu = snoozeMenu else { return }
        snooze(menu.thread, choice: index ?? menu.index)
    }

    // MARK: Esc

    /// Esc, in order (5.3): the snooze, places or settings menu, filter mode, a held Return, a new thread's settings
    /// (back to the words), the row's guess or your place, the picked options, the selection, the filters. It never
    /// clears a draft. False when there was nothing to step out of.
    func escape() -> Bool {
        if snoozeMenu != nil { animate(.fade) { snoozeMenu = nil }; return true }
        if placesMenu { animate(.fade) { placesMenu = false }; return true }
        if launchMenu != nil { animate(.fade) { launchMenu = nil }; return true }
        if filterMode { filterMode = false; return true }
        // A held Return: the words are yours again.
        if held { unhold(); return true }
        // The keyboard in a new thread's settings: back to the words.
        if launchFocus != nil { leaveLaunch(); return true }
        if !draft.isEmpty {
            if explicit != nil { animate(.fade) { explicit = nil; settleLaunch() }; return true }
            if !waved, read?.places.isEmpty == false || (read == nil && selectedThread != nil) {
                animate(.fade) { waved = true; settleLaunch() }
                return true
            }
        }
        if let t = selectedThread, picks[t.id] != nil || typed[t.id] != nil {
            picks[t.id] = nil
            typed[t.id] = nil
            return true
        }
        if selection != nil { select(nil); return true }
        if filtered { clearFilters(); return true }
        return false
    }
}
