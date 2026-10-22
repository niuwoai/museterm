import Foundation

enum TerminalAgentKind: String, Codable { case claude, codex }
enum TerminalAgentActivity: String, Codable { case unknown, working, idle, blocked, exited }
enum TerminalAgentBlockReason: String, Codable { case approval, question, other }
enum TerminalAgentResult: String, Codable { case completed, failed, interrupted, unknown }
enum TerminalAgentSource: String, Codable { case integration, foregroundProcess, shellCommand }
enum TerminalAgentConfidence: String, Codable { case high, medium, low }
enum TerminalAgentReason: String, Codable {
    case bound, reported, launched, foregroundDetected, screenApproval, screenQuestion, screenWorking
    case unrecognizedScreen, expired, processExited, commandEnded, foregroundLost
}

struct TerminalAgentSnapshot: Codable, Equatable {
    let instanceID: UUID
    let runID: UUID
    let kind: TerminalAgentKind
    var activity: TerminalAgentActivity
    var blockReason: TerminalAgentBlockReason?
    var lastResult: TerminalAgentResult?
    var source: TerminalAgentSource
    var confidence: TerminalAgentConfidence
    var reason: TerminalAgentReason
    var updatedAt: Date
    var expiresAt: Date?
    var reportSequence: UInt64
    let ruleVersion: Int
}

/// Returned only when an explicitly paired client binds a status reporter. Never in snapshots/events.
struct TerminalAgentGrant: Codable {
    let instanceID: UUID
    let runID: UUID
    let token: String
}

struct TerminalAgentReport: Codable {
    let instanceID: UUID
    let runID: UUID
    let token: String
    let sequence: UInt64
    let activity: TerminalAgentActivity
    var blockReason: TerminalAgentBlockReason? = nil
    var result: TerminalAgentResult? = nil
}

enum TerminalAgentReportError: String, Error {
    case invalidCapability, staleSequence, invalidState, unavailable
}

/// Pure reducer: callers supply time. Silence never becomes success or idle.
struct TerminalAgentMonitor {
    static let reportLifetime: TimeInterval = 120
    static let observedLifetime: TimeInterval = 15
    private(set) var snapshot: TerminalAgentSnapshot?
    private var capability: String?
    private var boundCommandID: UUID?
    private var isClosed = false
    private var retiredObservedRunIDs: Set<UUID> = []

    mutating func bind(kind: TerminalAgentKind, commandID: UUID? = nil, now: Date) throws -> TerminalAgentGrant {
        guard !isClosed else { throw TerminalAgentReportError.unavailable }
        let grant = TerminalAgentGrant(instanceID: UUID(), runID: UUID(),
                                       token: UUID().uuidString + UUID().uuidString)
        capability = grant.token
        boundCommandID = commandID
        snapshot = TerminalAgentSnapshot(instanceID: grant.instanceID, runID: grant.runID,
            kind: kind, activity: .unknown, source: .integration, confidence: .high,
            reason: .bound, updatedAt: now, expiresAt: now.addingTimeInterval(Self.reportLifetime),
            reportSequence: 0, ruleVersion: TerminalAgentScreenRules.version)
        return grant
    }

    mutating func report(_ report: TerminalAgentReport, now: Date) throws {
        guard !isClosed, var current = snapshot, current.activity != .exited,
              current.instanceID == report.instanceID, current.runID == report.runID,
              capability == report.token, capability != nil else {
            throw TerminalAgentReportError.invalidCapability
        }
        guard report.sequence > current.reportSequence else { throw TerminalAgentReportError.staleSequence }
        guard (report.activity == .blocked) == (report.blockReason != nil),
              report.result == nil || report.activity == .idle || report.activity == .exited else {
            throw TerminalAgentReportError.invalidState
        }
        current.activity = report.activity
        current.blockReason = report.blockReason
        if let result = report.result { current.lastResult = result }
        else if report.activity == .working { current.lastResult = nil }
        current.source = .integration
        current.confidence = .high
        current.reason = .reported
        current.updatedAt = now
        current.expiresAt = report.activity == .exited ? nil : now.addingTimeInterval(Self.reportLifetime)
        current.reportSequence = report.sequence
        snapshot = current
        if report.activity == .exited { capability = nil }
    }

    mutating func observe(kind: TerminalAgentKind, runID: UUID, source: TerminalAgentSource,
                         screen: String?, now: Date) {
        guard !isClosed, !retiredObservedRunIDs.contains(runID) else { return }
        if capability != nil {
            // A shell-confirmed replacement must retire the old reporter. Screen guesses cannot.
            guard source == .shellCommand else { return }
            if boundCommandID == nil, snapshot?.kind == kind {
                boundCommandID = runID
                return
            }
            guard boundCommandID != runID else { return }
            exit(reason: .commandEnded, now: now)
        }
        if snapshot?.runID != runID || snapshot?.kind != kind {
            snapshot = TerminalAgentSnapshot(instanceID: UUID(), runID: runID, kind: kind,
                activity: .unknown, source: source, confidence: .medium, reason: .launched,
                updatedAt: now, expiresAt: now.addingTimeInterval(Self.observedLifetime),
                reportSequence: 0, ruleVersion: TerminalAgentScreenRules.version)
        }
        guard var current = snapshot, current.activity != .exited else { return }
        let detection = screen.map { TerminalAgentScreenRules.detect(kind: kind, screen: $0) }
        current.activity = detection?.activity ?? .unknown
        current.blockReason = detection?.blockReason
        current.source = source
        current.confidence = detection == nil ? .medium : .low
        current.reason = detection?.reason ?? .foregroundDetected
        // Unchanged evidence refreshes freshness, but the session suppresses duplicate semantic events.
        current.updatedAt = now
        current.expiresAt = now.addingTimeInterval(Self.observedLifetime)
        snapshot = current
    }

    mutating func foregroundLost(now: Date) {
        guard capability == nil, var current = snapshot, current.activity != .exited else { return }
        guard current.activity != .unknown || current.reason != .foregroundLost else { return }
        current.activity = .unknown
        current.blockReason = nil
        current.reason = .foregroundLost
        current.updatedAt = now
        current.expiresAt = nil
        snapshot = current
    }

    mutating func expire(now: Date) {
        guard var current = snapshot, let expiry = current.expiresAt, now >= expiry else { return }
        current.activity = .unknown
        current.blockReason = nil
        current.reason = .expired
        current.updatedAt = now
        current.expiresAt = nil
        snapshot = current
    }

    mutating func endObservedRun(_ runID: UUID, now: Date) {
        if boundCommandID == runID {
            boundCommandID = nil
            exit(reason: .commandEnded, now: now)
            return
        }
        guard capability == nil, snapshot?.runID == runID else { return }
        // Bound memory: only the current observed run can be revived by ordinary observations.
        retiredObservedRunIDs = [runID]
        exit(reason: .commandEnded, now: now)
    }

    mutating func exit(reason: TerminalAgentReason = .processExited, now: Date, close: Bool = false) {
        capability = nil
        boundCommandID = nil
        isClosed = close
        guard var current = snapshot, current.activity != .exited else { return }
        current.activity = .exited
        current.blockReason = nil
        current.lastResult = current.lastResult ?? .unknown
        current.reason = reason
        current.updatedAt = now
        current.expiresAt = nil
        snapshot = current
    }
}

struct TerminalAgentScreenDetection {
    let activity: TerminalAgentActivity
    var blockReason: TerminalAgentBlockReason? = nil
    let reason: TerminalAgentReason
}

enum TerminalAgentScreenRules {
    static let version = 2
    static let maximumCharacters = 8_192
    static let maximumLines = 12

    static func kind(executable: String) -> TerminalAgentKind? {
        TerminalAgentKind(rawValue: URL(fileURLWithPath: executable).lastPathComponent)
    }

    static func launchedKind(command: String) -> TerminalAgentKind? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first, !tokens.contains(where: { ["--help", "--version", "-h"].contains($0) }),
              !command.contains(where: { ";|&`$\n".contains($0) }) else { return nil }
        return kind(executable: first)
    }

    static func detect(kind: TerminalAgentKind, screen: String) -> TerminalAgentScreenDetection {
        let lines = String(screen.suffix(maximumCharacters)).split(separator: "\n")
            .suffix(maximumLines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Require a visible, selected choice at the live bottom, not an isolated phrase in a log.
        let selectedApproval = lines.contains {
            ["❯ 1. Yes", "› 1. Yes, proceed (y)", "❯ 1. 是", "› 1. 是，继续 (y)"].contains($0)
        }
        let rejection = lines.contains { $0.hasPrefix("2. No") || $0.hasPrefix("3. No") || $0.hasPrefix("2. 否") || $0.hasPrefix("3. 否") }
        let approval = lines.contains { ["Do you want to proceed?", "Would you like to run the following command?", "是否继续？"].contains($0) }
        if selectedApproval && rejection && approval {
            return TerminalAgentScreenDetection(activity: .blocked, blockReason: .approval, reason: .screenApproval)
        }
        // Question and work state remain unknown until an integration reports them. Broad text
        // matching ("thinking", "?", "done") is intentionally excluded.
        return TerminalAgentScreenDetection(activity: .unknown, reason: .unrecognizedScreen)
    }
}
