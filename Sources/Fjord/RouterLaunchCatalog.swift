import Foundation

// What a new thread can start with, as T3 lists it (docs/design/router-v2/IMPLEMENTATION.md 1.5): the models, each one's
// reasoning efforts and default, the runtime modes its provider supports, and the defaults, all from `server.getConfig`
// (`providers[]`, `settings`). Nothing here is a constant of Fjord's: T3's lists are the lists. `make` is pure (a `T3JSON` in,
// values out); `RouterLaunchFeed` reads the config once connected and again after each reconnect, and tells the page.

/// What `server.getConfig` offers a new thread, with the names the decider needs to read a draft's aside.
struct RouterLaunchOffer: Equatable, Sendable {
    var defaults: RouterV2Launch
    var models: [RouterV2LaunchModel]
    /// Each model's other names in T3 ("opus" for Opus 5.5), by slug.
    var aliases: [String: [String]] = [:]

    static let empty = RouterLaunchOffer(defaults: .t3Default, models: [])

    func model(_ slug: String) -> RouterV2LaunchModel? { models.first { $0.id == slug } }

    /// The slug a draft's model name stands for: a slug of T3's, else one of their aliases or names, ignoring case. Nil: T3
    /// doesn't have it.
    func slug(_ named: String) -> String? {
        let wanted = named.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let m = models.first(where: { $0.id.lowercased() == wanted }) { return m.id }
        if let m = models.first(where: { (aliases[$0.id] ?? []).contains { $0.lowercased() == wanted } }) { return m.id }
        return models.first { $0.name.lowercased() == wanted }?.id
    }

    /// Every effort, runtime mode a model offers, in T3's order and once each (the decider's enums).
    var efforts: [String] { unique(models.flatMap { $0.efforts.map(\.rawValue) }) }
    var accesses: [String] { unique(models.flatMap { $0.access.map(\.rawValue) }) }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum RouterLaunchCatalog {
    /// The models and defaults for a new thread (in `project`, whose own default model wins when it has one).
    static func make(config: T3JSON, project: T3JSON? = nil) -> (defaults: RouterV2Launch, models: [RouterV2LaunchModel]) {
        let o = offer(config: config, project: project)
        return (o.defaults, o.models)
    }

    /// `make`, with the models' aliases.
    static func offer(config: T3JSON, project: T3JSON? = nil) -> RouterLaunchOffer {
        let settings = config["settings"]
        let selection = project?["defaultModelSelection"] ?? settings?["defaultModelSelection"]
        let defaultInstance = selection?.str("instanceId")
        var providers = (config["providers"]?.array ?? []).filter { p in
            p.str("status") == "ready" && p["enabled"]?.bool != false && p["installed"]?.bool != false
        }
        // The default's provider first, then T3's order.
        if let defaultInstance, let at = providers.firstIndex(where: { $0.str("instanceId") == defaultInstance }), at > 0 {
            providers.insert(providers.remove(at: at), at: 0)
        }
        var models: [RouterV2LaunchModel] = []
        var aliases: [String: [String]] = [:]
        for provider in providers {
            guard let instance = provider.str("instanceId") else { continue }
            let label = provider.str("displayName") ?? RouterV2Launch.label(provider.str("driver") ?? instance)
            let access = accessModes(provider["supportedRuntimeModes"])
            for m in provider["models"]?.array ?? [] where m["isLegacy"]?.bool != true {
                guard let slug = m.str("slug"), !models.contains(where: { $0.id == slug && $0.instance == instance }) else { continue }
                let (efforts, preferred) = efforts(m["capabilities"])
                models.append(RouterV2LaunchModel(id: slug, name: m.str("name") ?? slug, provider: label, instance: instance, efforts: efforts,
                                                  defaultEffort: preferred, access: access))
                let names = (m["aliases"]?.array ?? []).compactMap(\.string)
                if !names.isEmpty { aliases[slug] = names }
            }
        }
        guard let first = models.first else { return .empty }
        let chosen = selection?.str("model").flatMap { slug in models.first { $0.id == slug } } ?? first
        // The default effort: the selection's own, else the model's default, else its first.
        let said = (selection?["options"]?.array ?? []).first { $0.str("id") == "effort" }?["value"]?.string
        var effort = said.map { RouterV2Launch.Effort(rawValue: $0) }.flatMap { chosen.efforts.contains($0) ? $0 : nil }
            ?? chosen.defaultEffort ?? chosen.efforts.first ?? RouterV2Launch.t3Default.effort
        if !chosen.efforts.isEmpty, !chosen.efforts.contains(effort) { effort = chosen.efforts[0] }
        // T3's `resolveCompatibleRuntimeMode`: its default when the provider supports it, else the provider's first.
        let wanted = settings?.str("defaultRuntimeMode").map { RouterV2Launch.Access(rawValue: $0) } ?? .full
        let access = chosen.access.contains(wanted) ? wanted : chosen.access.first ?? wanted
        return RouterLaunchOffer(defaults: RouterV2Launch(model: chosen.id, effort: effort, access: access), models: models, aliases: aliases)
    }

    /// The runtime modes a provider supports, most supervised first; all four when it lists none (T3's rule).
    private static func accessModes(_ listed: T3JSON?) -> [RouterV2Launch.Access] {
        let named = Set((listed?.array ?? []).compactMap(\.string))
        guard !named.isEmpty else { return RouterV2Launch.Access.all }
        var modes = RouterV2Launch.Access.all.filter { named.contains($0.rawValue) }
        // A mode T3 adds that Fjord has no name for still belongs to the list.
        modes += named.subtracting(modes.map(\.rawValue)).sorted().map { RouterV2Launch.Access(rawValue: $0) }
        return modes
    }

    /// A model's reasoning efforts and its default: the select option whose id is `effort` (what a launch sends back).
    private static func efforts(_ capabilities: T3JSON?) -> ([RouterV2Launch.Effort], RouterV2Launch.Effort?) {
        guard let descriptor = (capabilities?["optionDescriptors"]?.array ?? []).first(where: { $0.str("id") == "effort" && $0.str("type") == "select" }) else {
            return ([], nil)
        }
        let options = descriptor["options"]?.array ?? []
        let efforts = options.compactMap { $0.str("id") }.map { RouterV2Launch.Effort(rawValue: $0) }
        let marked = options.first { $0["isDefault"]?.bool == true }?.str("id") ?? descriptor.str("currentValue")
        return (efforts, marked.map { RouterV2Launch.Effort(rawValue: $0) }.flatMap { efforts.contains($0) ? $0 : nil })
    }

    // MARK: What the decider said

    /// The settings the decider named for a new thread, as T3 has them: only what T3 offers survives (a model T3 doesn't have, an
    /// effort or a runtime mode that model doesn't take, an interaction mode that is neither), and nothing without an offer.
    static func checked(model: String?, effort: String?, runtimeMode: String?, interactionMode: String?,
                        offer: RouterLaunchOffer?) -> RouterV2LaunchAsk {
        var ask = RouterV2LaunchAsk()
        guard let offer else { return ask }
        ask.model = model.flatMap(offer.slug)
        // Efforts and modes are the named model's, else the default model's.
        let info = offer.model(ask.model ?? offer.defaults.model)
        if let effort = effort?.trimmingCharacters(in: .whitespaces).lowercased(), !effort.isEmpty {
            let value = RouterV2Launch.Effort(rawValue: effort)
            if info?.efforts.contains(value) == true { ask.effort = value }
        }
        if let mode = runtimeMode?.trimmingCharacters(in: .whitespaces).lowercased(), !mode.isEmpty {
            let value = RouterV2Launch.Access(rawValue: mode)
            if info?.access.contains(value) == true { ask.access = value }
        }
        switch interactionMode?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "plan": ask.plan = true
        case "default": ask.plan = false
        default: break
        }
        return ask
    }

    /// The draft's words that only say the settings, when the model quoted them exactly and something was left to send: nil
    /// otherwise, so nothing is ever cut from a message on a guess.
    static func taken(_ words: String, in draft: String, said: RouterV2LaunchAsk) -> String? {
        guard !words.isEmpty, said != RouterV2LaunchAsk(), let range = draft.range(of: words, options: .backwards) else { return nil }
        var lo = range.lowerBound
        var hi = range.upperBound
        // Brackets right around the words (a model that quoted "use opus medium" out of "(use opus medium)") go with them,
        // else the sent message keeps "()".
        var before = lo
        while before > draft.startIndex, draft[draft.index(before: before)].isWhitespace { before = draft.index(before: before) }
        var after = hi
        while after < draft.endIndex, draft[after].isWhitespace { after = draft.index(after: after) }
        if before > draft.startIndex, after < draft.endIndex, closer[draft[draft.index(before: before)]] == draft[after] {
            lo = draft.index(before: before)
            hi = draft.index(after: after)
        }
        // A comma or dash the words leave dangling at an end of the message goes too.
        let tail = draft[hi...].trimmingCharacters(in: .whitespacesAndNewlines)
        let head = draft[..<lo].trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty, let last = head.last, separators.contains(last) {
            lo = draft[..<lo].lastIndex { !$0.isWhitespace && !separators.contains($0) }.map { draft.index(after: $0) } ?? draft.startIndex
        } else if head.isEmpty, let first = tail.first, separators.contains(first) {
            var i = hi
            while i < draft.endIndex, draft[i].isWhitespace || separators.contains(draft[i]) { i = draft.index(after: i) }
            hi = i
        }
        let rest = (draft[..<lo] + draft[hi...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : String(draft[lo..<hi])
    }

    private static let closer: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    private static let separators: Set<Character> = [",", ";", "-", "—", "–"]
}

// MARK: - Read from T3

/// Reads `server.getConfig` when T3 is connected (and again on each reconnect) and tells the page what a new thread offers.
/// Nothing polls: `connected()` is called when the connection comes up.
@MainActor final class RouterLaunchFeed {
    /// `server.getConfig`'s answer (`Store.liveLaunchSupport(_:).config`); tests stand in.
    var config: @MainActor () async throws -> T3JSON
    /// Where the page's change goes (`RouterV2Model.apply`, or the records' held window).
    var emit: @MainActor (RouterV2Change) -> Void = { _ in }
    /// The offer as last read, for the decider's schema and the reader's checks.
    private(set) var offer: RouterLaunchOffer = .empty
    private var task: Task<Void, Never>?
    private(set) var reads = 0

    init(config: @escaping @MainActor () async throws -> T3JSON) { self.config = config }

    /// T3 is connected: read the config now. A read still under way is replaced; a failure keeps the last offer (the next
    /// reconnect reads again).
    func connected() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            self.reads += 1
            guard let json = try? await self.config(), !Task.isCancelled else { return }
            let next = RouterLaunchCatalog.offer(config: json)
            guard !next.models.isEmpty, next != self.offer else { return }
            self.offer = next
            self.emit(.launch(defaults: next.defaults, models: next.models))
        }
    }

    /// T3 went away: nothing to read until it is back.
    func disconnected() {
        task?.cancel()
        task = nil
    }
}
