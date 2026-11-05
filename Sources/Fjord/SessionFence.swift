import Foundation

/// Text a session wrote, fenced for a model as untrusted. Whatever in it could close the fence, or open another, is broken up
/// first (any case, any spacing), so the session's words stay inside it: every place that fences a session's text goes
/// through here.
enum SessionFence {
    static let open = "<session-content untrusted=\"true\">"
    static let close = "</session-content>"

    /// The text with every `<session-content` and `</session-content` made inert (a zero-width space after the `<`).
    static func neutralized(_ text: String) -> String {
        text.replacingOccurrences(of: #"<(\s*/?\s*)(session-content)"#, with: "<\u{200B}$1$2", options: [.regularExpression, .caseInsensitive])
    }

    /// The text between the fence's lines.
    static func fence(_ text: String) -> String { open + "\n" + neutralized(text) + "\n" + close }
}
