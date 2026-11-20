import Foundation

nonisolated struct TerminalShellReportedContext: Equatable {
    var workingDirectory: String?
    var user: String?
    var uid: Int?
    var host: String?
    var shell: String?

    var isEmpty: Bool {
        workingDirectory == nil && user == nil && uid == nil && host == nil && shell == nil
    }
}
