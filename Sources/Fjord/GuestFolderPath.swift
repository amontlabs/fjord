import Foundation

enum GuestFolderPath {
    /// Guest roots are passed to SSH unchanged. No host normalization, expansion, realpath, or existence check applies.
    static func validate(_ path: String) throws -> String {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\0") else { throw Failure.absolutePathRequired }
        return path
    }

    /// A child of a guest folder, built as strings: host path APIs never touch a guest path.
    static func join(_ root: String, _ child: String) -> String {
        root == "/" ? "/" + child : root.hasSuffix("/") ? root + child : root + "/" + child
    }

    enum Failure: LocalizedError, Equatable {
        case absolutePathRequired
        var errorDescription: String? { "Enter an absolute folder path in the computer." }
    }
}
