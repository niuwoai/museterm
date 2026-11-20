import Foundation

nonisolated enum TerminalCommandLifecycleState: String, Codable, Equatable {
    case running
    case succeeded
    case failed
    case interrupted
    case superseded
    case completedUnknownStatus = "completed_unknown_status"

    var contextLabel: String {
        rawValue
    }
}
