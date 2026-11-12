import SwiftUI

// A new thread's setting named in the Router v2 composer (docs/design/router-v2/DESIGN.md 1.9.1): typing @ lists T3's models,
// the efforts and access the chosen model takes, and the mode; picking one puts a pill in the draft and sets that chip in
// the destination row. The pill is not part of the message. Taking it out of the draft puts the setting back.
// Free text never sets anything: "use opus for subagents" is for the agent.

/// A setting a pill stands for: its kind, T3's value for it, and the name the chip and the pill say.
struct RouterSetting: Hashable, Codable {
    enum Kind: String, Codable, CaseIterable {
        case model, effort, access, mode

        var title: String {
            switch self {
            case .model: "Model"
            case .effort: "Reasoning effort"
            case .access: "Access"
            case .mode: "Mode"
            }
        }

        var symbol: String {
            switch self {
            case .model: "cpu"
            case .effort: "gauge.with.dots.needle.50percent"
            case .access: "lock.open"
            case .mode: "list.bullet.clipboard"
            }
        }
    }

    var kind: Kind
    /// T3's value: a model's slug, an effort's or a runtime mode's id, "plan" or "build".
    var value: String
    var label: String

    /// Quiet, with the kind's glyph and no "@": a setting reads differently from a thread.
    var look: MentionLook {
        MentionLook(label: label, symbol: kind.symbol, tint: CDS.Text.secondary, setting: true)
    }

    /// The settings the pills of a draft name, the last of each kind winning.
    static func ask(_ pointers: [RouterPointer]) -> RouterV2LaunchAsk {
        var ask = RouterV2LaunchAsk()
        for case .setting(let s) in pointers {
            switch s.kind {
            case .model: ask.model = s.value
            case .effort: ask.effort = .init(rawValue: s.value)
            case .access: ask.access = .init(rawValue: s.value)
            case .mode: ask.plan = s.value == "plan"
            }
        }
        return ask
    }
}

extension RouterPointer {
    var isSetting: Bool { if case .setting = self { true } else { false } }
}
