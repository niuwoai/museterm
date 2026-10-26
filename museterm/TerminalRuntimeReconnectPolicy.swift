import Foundation

/// Reattach reads only. Never retries input or creates a replacement process.
nonisolated struct TerminalRuntimeReconnectPolicy {
    static let delays: [TimeInterval] = [0.25, 1, 3]
    static let stableInterval: TimeInterval = 30
    private(set) var attempts = 0

    mutating func nextDelay(for error: Error, healthyFor: TimeInterval) -> TimeInterval? {
        guard let error = error as? TerminalRuntimeConnectionError else { return nil }
        switch error {
        case .unavailable, .timedOut: break
        default: return nil
        }
        if healthyFor >= Self.stableInterval { attempts = 0 }
        guard attempts < Self.delays.count else { return nil }
        defer { attempts += 1 }
        return Self.delays[attempts]
    }
}
