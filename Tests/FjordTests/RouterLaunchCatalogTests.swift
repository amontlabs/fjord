import Foundation
import Testing
@testable import Fjord

/// T3's models, efforts and modes as a new thread's choices (`RouterLaunchCatalog`, from `server.getConfig`), and what the decider's
/// aside about them becomes. The config is invented in the shape of `ServerProvider` / `ServerSettings` (T3 contracts).
@MainActor
@Suite struct RouterLaunchCatalogTests {
    static func efforts(_ ids: [String], default def: String? = nil) -> String {
        let options = ids.map { id in #"{"id":"\#(id)","label":"\#(id)"\#(id == def ? #","isDefault":true"# : "")}"# }.joined(separator: ",")
        return #"{"optionDescriptors":[{"id":"effort","label":"Reasoning","type":"select","options":[\#(options)]},{"id":"thinking","label":"Thinking","type":"boolean"}]}"#
    }

    static func model(_ slug: String, _ name: String, aliases: [String] = [], capabilities: String = "null", legacy: Bool = false) -> String {
        #"{"slug":"\#(slug)","name":"\#(name)","aliases":\#(aliases.map { "\"\($0)\"" }.joined(separator: ",").wrapped),"isCustom":false,"isLegacy":\#(legacy),"capabilities":\#(capabilities)}"#
    }

    /// This install's Claude: four models and an old one, default Opus 5.5 at its own default effort, runtime `auto`.
    static let claude = #"{"instanceId":"claudeAgent","driver":"claudeAgent","displayName":"Claude","enabled":true,"installed":true,"status":"ready","#
        + #""supportedRuntimeModes":["approval-required","auto-accept-edits","auto","full-access"],"models":["#
        + [model("claude-fable-5-2", "Fable 5.2", aliases: ["fable"], capabilities: efforts(["low", "medium", "high", "xhigh", "max"], default: "high")),
           model("claude-opus-5-5", "Opus 5.5", aliases: ["opus"], capabilities: efforts(["low", "medium", "high", "xhigh", "max"], default: "high")),
           model("claude-sonnet-5-5", "Sonnet 5.5", aliases: ["sonnet"], capabilities: efforts(["low", "medium", "high", "max"], default: "medium")),
           model("claude-haiku-5-5", "Haiku 5.5", aliases: ["haiku"]),
           model("claude-opus-4-1", "Opus 4.1", aliases: ["opus-4"], capabilities: efforts(["high"]), legacy: true)].joined(separator: ",")
        + "]}"

    static func config(providers: [String] = [claude], settings: String = Self.settings) -> T3JSON {
        T3JSON.parse(#"{"providers":[\#(providers.joined(separator: ","))],"settings":\#(settings)}"#)!
    }

    static let settings = #"{"defaultModelSelection":{"instanceId":"claudeAgent","model":"claude-opus-5-5"},"defaultRuntimeMode":"auto"}"#

    @Test func thisInstallsConfigIsFourModelsWithTheirOwnEffortsAndOpusHighAutoByDefault() throws {
        let (defaults, models) = RouterLaunchCatalog.make(config: Self.config())
        #expect(models.map(\.name) == ["Fable 5.2", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"])
        #expect(defaults == RouterV2Launch(model: "claude-opus-5-5", effort: .high, access: .auto))
        #expect(models[1].efforts == [.low, .medium, .high, .xhigh, .max] && models[1].defaultEffort == .high)
        #expect(models[2].efforts == [.low, .medium, .high, .max] && models[2].defaultEffort == .medium)
        #expect(models[3].efforts.isEmpty && models[3].defaultEffort == nil)
        #expect(models.allSatisfy { $0.provider == "Claude" && $0.instance == "claudeAgent" && $0.access == RouterV2Launch.Access.all })
    }

    @Test func aSettingsEffortAndAProjectsModelOverrideTheDefaults() {
        let settings = #"{"defaultModelSelection":{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"effort","value":"max"}]},"defaultRuntimeMode":"full-access"}"#
        #expect(RouterLaunchCatalog.make(config: Self.config(settings: settings)).defaults
            == RouterV2Launch(model: "claude-opus-5-5", effort: .max, access: .full))
        // An effort the model doesn't take falls back to the model's default; the project's model wins over the server's.
        let project = T3JSON.parse(#"{"defaultModelSelection":{"instanceId":"claudeAgent","model":"claude-sonnet-5-5","options":[{"id":"effort","value":"xhigh"}]}}"#)
        #expect(RouterLaunchCatalog.make(config: Self.config(), project: project).defaults
            == RouterV2Launch(model: "claude-sonnet-5-5", effort: .medium, access: .auto))
    }

    @Test func aProviderThatLacksARuntimeModeDoesNotOfferIt() {
        let codex = #"{"instanceId":"codex","driver":"codex","displayName":"Codex","enabled":true,"installed":true,"status":"ready","supportedRuntimeModes":["approval-required","full-access"],"models":["#
            + Self.model("gpt-6-sol", "GPT-6 Sol", aliases: ["sol"]) + "]}"
        let (_, models) = RouterLaunchCatalog.make(config: Self.config(providers: [Self.claude, codex]))
        let sol = models.first { $0.id == "gpt-6-sol" }
        #expect(sol?.access == [.supervised, .full] && sol?.provider == "Codex" && sol?.instance == "codex")
        #expect(models.first { $0.id == "claude-opus-5-5" }?.access.contains(.auto) == true)
        // A default the default model's provider lacks becomes its first mode.
        let onlyCodex = #"{"defaultModelSelection":{"instanceId":"codex","model":"gpt-6-sol"},"defaultRuntimeMode":"auto"}"#
        let defaults = RouterLaunchCatalog.make(config: Self.config(providers: [Self.claude, codex], settings: onlyCodex)).defaults
        #expect(defaults.model == "gpt-6-sol" && defaults.access == .supervised)
    }

    @Test func disabledAndNotReadyProvidersAndLegacyModelsAreNotOffered() {
        let off = #"{"instanceId":"grok","driver":"grok","enabled":false,"installed":true,"status":"disabled","models":["# + Self.model("grok-4", "Grok 4") + "]}"
        let broken = #"{"instanceId":"pi","driver":"pi","enabled":true,"installed":true,"status":"error","models":["# + Self.model("pi-1", "Pi") + "]}"
        let (_, models) = RouterLaunchCatalog.make(config: Self.config(providers: [off, Self.claude, broken]))
        #expect(models.map(\.id) == ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        // Nothing to offer: no models, T3's known default.
        let none = RouterLaunchCatalog.make(config: Self.config(providers: [off]))
        #expect(none.models.isEmpty && none.defaults == .t3Default)
    }

    @Test func aModelsNamesResolveByAliasAndOnlyToWhatT3Has() {
        let offer = RouterLaunchCatalog.offer(config: Self.config())
        #expect(offer.slug("opus") == "claude-opus-5-5" && offer.slug(" Sonnet ") == "claude-sonnet-5-5")
        #expect(offer.slug("claude-haiku-5-5") == "claude-haiku-5-5" && offer.slug("Fable 5.2") == "claude-fable-5-2")
        #expect(offer.slug("gpt-9") == nil && offer.slug("") == nil && offer.slug("opus-4") == nil)
        #expect(offer.efforts == ["low", "medium", "high", "xhigh", "max"] && offer.accesses == ["approval-required", "auto-accept-edits", "auto", "full-access"])
    }

    // MARK: What the decider said

    @Test func theDeciderSaidIsCheckedAgainstTheModelItNamed() {
        let offer = RouterLaunchCatalog.offer(config: Self.config())
        let ok = RouterLaunchCatalog.checked(model: "opus", effort: "Medium", runtimeMode: "approval-required", interactionMode: "plan", offer: offer)
        #expect(ok == RouterV2LaunchAsk(model: "claude-opus-5-5", effort: .medium, access: .supervised, plan: true))
        // A model T3 doesn't have is dropped; Sonnet has no xhigh; Haiku takes no effort; an unknown mode and mode are dropped.
        #expect(RouterLaunchCatalog.checked(model: "gpt-9", effort: nil, runtimeMode: nil, interactionMode: nil, offer: offer) == RouterV2LaunchAsk())
        #expect(RouterLaunchCatalog.checked(model: "sonnet", effort: "xhigh", runtimeMode: nil, interactionMode: nil, offer: offer)
            == RouterV2LaunchAsk(model: "claude-sonnet-5-5"))
        #expect(RouterLaunchCatalog.checked(model: "haiku", effort: "low", runtimeMode: nil, interactionMode: nil, offer: offer)
            == RouterV2LaunchAsk(model: "claude-haiku-5-5"))
        #expect(RouterLaunchCatalog.checked(model: nil, effort: "ultra", runtimeMode: "yolo", interactionMode: "agent", offer: offer) == RouterV2LaunchAsk())
        // An effort alone is the default model's; build is a setting too; nothing is taken without an offer.
        #expect(RouterLaunchCatalog.checked(model: nil, effort: "max", runtimeMode: nil, interactionMode: "default", offer: offer)
            == RouterV2LaunchAsk(effort: .max, plan: false))
        #expect(RouterLaunchCatalog.checked(model: "opus", effort: "max", runtimeMode: "auto", interactionMode: "plan", offer: nil) == RouterV2LaunchAsk())
    }

    @Test func theWordsAreTakenOnlyWhenTheyAreFoundExactlyAndSomethingIsLeftToSend() {
        let said = RouterV2LaunchAsk(model: "claude-opus-5-5", effort: .medium)
        let draft = "split the snapshot tests (use opus medium)"
        #expect(RouterLaunchCatalog.taken("(use opus medium)", in: draft, said: said) == "(use opus medium)")
        // Not in the draft (the model changed a word): nothing is cut.
        #expect(RouterLaunchCatalog.taken("(use Opus medium)", in: draft, said: said) == nil)
        #expect(RouterLaunchCatalog.taken("use opus on medium", in: draft, said: said) == nil)
        // No setting survived the check: no words either. The whole draft is never taken.
        #expect(RouterLaunchCatalog.taken("(use opus medium)", in: draft, said: RouterV2LaunchAsk()) == nil)
        #expect(RouterLaunchCatalog.taken("use opus medium", in: "use opus medium", said: said) == nil)
        #expect(RouterLaunchCatalog.taken("", in: draft, said: said) == nil)
    }

    // MARK: The feed

    @Test func theFeedReadsTheConfigWhenConnectedAndTellsThePageOnlyWhatChanged() async {
        let counter = Counter()
        let feed = RouterLaunchFeed(config: { counter.config })
        var changes: [RouterV2Change] = []
        feed.emit = { changes.append($0) }
        feed.connected()
        await waitUntil { !changes.isEmpty }
        guard case .launch(let defaults, let models)? = changes.first else { Issue.record("no launch change"); return }
        #expect(defaults.model == "claude-opus-5-5" && models.count == 4 && feed.offer.models.count == 4)
        // A reconnect with the same config: read again, nothing said again.
        feed.connected()
        await waitUntil { feed.reads == 2 }
        await Task.yield()
        #expect(changes.count == 1)
        // A new model on the next reconnect is told.
        counter.config = Self.config(providers: [Self.claude.replacingOccurrences(of: "claude-haiku-5-5", with: "claude-haiku-5-6")])
        feed.connected()
        await waitUntil { changes.count == 2 }
        #expect(feed.offer.models.last?.id == "claude-haiku-5-6")
    }

    @Test func aFailedConfigReadKeepsTheLastOffer() async {
        var fail = false
        let feed = RouterLaunchFeed(config: {
            if fail { throw ThreadLaunchFailure("away") }
            return Self.config()
        })
        var changes = 0
        feed.emit = { _ in changes += 1 }
        feed.connected()
        await waitUntil { changes == 1 }
        fail = true
        feed.connected()
        await waitUntil { feed.reads == 2 }
        await Task.yield()
        #expect(changes == 1 && feed.offer.models.count == 4)
    }

    @MainActor final class Counter { var config = RouterLaunchCatalogTests.config() }
}

private extension String {
    /// `a,b` as a JSON array body.
    var wrapped: String { "[" + self + "]" }
}
