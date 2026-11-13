import Foundation

// What a new thread can start with, as T3 lists it (docs/design/router-v2/IMPLEMENTATION.md 1.5): the models, each one's
// reasoning efforts and default, the runtime modes its provider supports, and the defaults, all from `server.getConfig`
// (`providers[]`, `settings`). Nothing here is a constant of Fjord's: T3's lists are the lists. `make` is pure (a `T3JSON` in,
// values out); `RouterLaunchFeed` reads the config once connected and again after each reconnect, and tells the page.

/// What `server.getConfig` offers a new thread.
struct RouterLaunchOffer: Equatable, Sendable {
    var defaults: RouterLaunch
    var models: [RouterLaunchModel]

    static let empty = RouterLaunchOffer(defaults: .demoDefault, models: [])

    func model(_ slug: String) -> RouterLaunchModel? { models.first { $0.id == slug } }
}

enum RouterLaunchCatalog {
    /// The models and defaults for a new thread (in `project`, whose own default model wins when it has one).
    static func make(config: T3JSON, project: T3JSON? = nil) -> (defaults: RouterLaunch, models: [RouterLaunchModel]) {
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
        var models: [RouterLaunchModel] = []
        for provider in providers {
            guard let instance = provider.str("instanceId") else { continue }
            let label = provider.str("displayName") ?? RouterLaunch.label(provider.str("driver") ?? instance)
            let access = accessModes(provider["supportedRuntimeModes"])
            for m in provider["models"]?.array ?? [] where m["isLegacy"]?.bool != true {
                guard let slug = m.str("slug"), !models.contains(where: { $0.id == slug && $0.instance == instance }) else { continue }
                let (efforts, preferred) = efforts(m["capabilities"])
                // T3's other names for it ("opus" for Opus 5.5): what @ finds it by.
                let names = (m["aliases"]?.array ?? []).compactMap(\.string)
                models.append(RouterLaunchModel(id: slug, name: m.str("name") ?? slug, provider: label, instance: instance, efforts: efforts,
                                                  defaultEffort: preferred, access: access, aliases: names))
            }
        }
        guard let first = models.first else { return .empty }
        let chosen = selection?.str("model").flatMap { slug in models.first { $0.id == slug } } ?? first
        // The default effort: the selection's own, else the model's default, else its first.
        let said = (selection?["options"]?.array ?? []).first { $0.str("id") == "effort" }?["value"]?.string
        var effort = said.map { RouterLaunch.Effort(rawValue: $0) }.flatMap { chosen.efforts.contains($0) ? $0 : nil }
            ?? chosen.defaultEffort ?? chosen.efforts.first ?? RouterLaunch.Effort.high
        if !chosen.efforts.isEmpty, !chosen.efforts.contains(effort) { effort = chosen.efforts[0] }
        // T3's `resolveCompatibleRuntimeMode`: its default when the provider supports it, else the provider's first.
        let wanted = settings?.str("defaultRuntimeMode").map { RouterLaunch.Access(rawValue: $0) } ?? .full
        let access = chosen.access.contains(wanted) ? wanted : chosen.access.first ?? wanted
        return RouterLaunchOffer(defaults: RouterLaunch(model: chosen.id, effort: effort, access: access), models: models)
    }

    /// The runtime modes a provider supports, most supervised first; all four when it lists none (T3's rule).
    private static func accessModes(_ listed: T3JSON?) -> [RouterLaunch.Access] {
        let named = Set((listed?.array ?? []).compactMap(\.string))
        guard !named.isEmpty else { return RouterLaunch.Access.all }
        var modes = RouterLaunch.Access.all.filter { named.contains($0.rawValue) }
        // A mode T3 adds that Fjord has no name for still belongs to the list.
        modes += named.subtracting(modes.map(\.rawValue)).sorted().map { RouterLaunch.Access(rawValue: $0) }
        return modes
    }

    /// A model's reasoning efforts and its default: the select option whose id is `effort` (what a launch sends back).
    private static func efforts(_ capabilities: T3JSON?) -> ([RouterLaunch.Effort], RouterLaunch.Effort?) {
        guard let descriptor = (capabilities?["optionDescriptors"]?.array ?? []).first(where: { $0.str("id") == "effort" && $0.str("type") == "select" }) else {
            return ([], nil)
        }
        let options = descriptor["options"]?.array ?? []
        let efforts = options.compactMap { $0.str("id") }.map { RouterLaunch.Effort(rawValue: $0) }
        let marked = options.first { $0["isDefault"]?.bool == true }?.str("id") ?? descriptor.str("currentValue")
        return (efforts, marked.map { RouterLaunch.Effort(rawValue: $0) }.flatMap { efforts.contains($0) ? $0 : nil })
    }
}

// MARK: - Read from T3

/// Reads `server.getConfig` when T3 is connected (and again on each reconnect) and tells the page what a new thread offers.
/// Nothing polls: `connected()` is called when the connection comes up.
@MainActor final class RouterLaunchFeed {
    /// `server.getConfig`'s answer (`Store.liveLaunchSupport(_:).config`); tests stand in.
    var config: @MainActor () async throws -> T3JSON
    /// Where the page's change goes (`RouterModel.apply`, or the records' held window).
    var emit: @MainActor (RouterChange) -> Void = { _ in }
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
