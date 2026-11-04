import Foundation

// How the owner asked the Router to write to them (Settings). Every model call of the Router is built with `prompt`.

enum RouterStyle {
    static let defaultText = "Plain and short. No jargon unless accuracy needs it. Say what matters to me first. One or two sentences."

    /// A model's fixed rules, then how you asked to be written to: they never loosen the rules.
    static func prompt(_ rules: String, style: String) -> String {
        rules + "\n\nHow the user asked you to write to them, in their own words (follow it within the rules above):\n" + style
    }
}
