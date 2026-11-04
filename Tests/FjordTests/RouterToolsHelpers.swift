import Foundation
@testable import Fjord

extension RouterTools {
    /// The dispatcher calls prepare and answerForm directly (a run is offered only the board and
    /// Fjord's own tools); the tests go on naming them as the tools they were.
    func tool(_ name: String, _ args: [String: Any], ticket given: Ticket? = nil) async -> RouterRPC.ToolResult? {
        guard let store else { return .error("Fjord isn't ready") }
        let ticket = given ?? self.ticket()
        do {
            switch name {
            case "answer_form": return RouterRPC.ToolResult(text: try await answerForm(store, args, ticket: ticket))
            case "prepare":
                return RouterRPC.ToolResult(text: try await prepare(store, session: Self.string(args, "session"), ticket: ticket))
            default: return nil
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
