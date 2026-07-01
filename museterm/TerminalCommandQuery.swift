import Foundation

struct TerminalCommandQuery: Equatable {
    let textTerms: [String]
    let riskLevels: Set<TerminalCommandRiskLevel>
    let lifecycleStates: Set<TerminalCommandLifecycleState>
    let boundaryConfidences: Set<TerminalCommandBoundaryConfidence>

    init(_ rawQuery: String) {
        var textTerms: [String] = []
        var riskLevels = Set<TerminalCommandRiskLevel>()
        var lifecycleStates = Set<TerminalCommandLifecycleState>()
        var boundaryConfidences = Set<TerminalCommandBoundaryConfidence>()

        for token in Self.tokens(in: rawQuery) {
            guard let separatorIndex = token.firstIndex(of: ":") else {
                textTerms.append(token)
                continue
            }

            let key = token[..<separatorIndex].lowercased()
            let rawValue = token[token.index(after: separatorIndex)...]
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            guard !rawValue.isEmpty else {
                textTerms.append(token)
                continue
            }

            switch key {
            case "risk", "risk_level":
                if let value = TerminalCommandRiskLevel(queryValue: String(rawValue)) {
                    riskLevels.insert(value)
                } else {
                    textTerms.append(token)
                }
            case "state", "lifecycle", "lifecycle_state":
                if let value = TerminalCommandLifecycleState(queryValue: String(rawValue)) {
                    lifecycleStates.insert(value)
                } else {
                    textTerms.append(token)
                }
            case "boundary", "boundary_confidence":
                if let value = TerminalCommandBoundaryConfidence(queryValue: String(rawValue)) {
                    boundaryConfidences.insert(value)
                } else {
                    textTerms.append(token)
                }
            default:
                textTerms.append(token)
            }
        }

        self.textTerms = textTerms
        self.riskLevels = riskLevels
        self.lifecycleStates = lifecycleStates
        self.boundaryConfidences = boundaryConfidences
    }

    var isEmpty: Bool {
        textTerms.isEmpty
            && riskLevels.isEmpty
            && lifecycleStates.isEmpty
            && boundaryConfidences.isEmpty
    }

    var historyTextQuery: String? {
        guard !textTerms.isEmpty else { return nil }
        return textTerms.joined(separator: " ")
    }

    func matches(_ block: TerminalCommandBlock) -> Bool {
        if !riskLevels.isEmpty, !riskLevels.contains(block.commandRiskProfile.level) {
            return false
        }
        if !lifecycleStates.isEmpty, !lifecycleStates.contains(block.commandLifecycleState) {
            return false
        }
        if !boundaryConfidences.isEmpty, !boundaryConfidences.contains(block.commandBoundaryConfidence) {
            return false
        }
        guard !textTerms.isEmpty else { return true }

        let searchableText = block.searchableText
        return textTerms.allSatisfy { term in
            searchableText.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func tokens(in rawQuery: String) -> [String] {
        rawQuery
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private extension TerminalCommandRiskLevel {
    init?(queryValue: String) {
        switch queryValue {
        case "read_only", "readonly", "read":
            self = .readOnly
        case "mutating", "mutation", "write":
            self = .mutating
        case "dangerous", "danger", "destructive":
            self = .dangerous
        case "unknown", "unclear":
            self = .unknown
        default:
            return nil
        }
    }
}

private extension TerminalCommandLifecycleState {
    init?(queryValue: String) {
        switch queryValue {
        case "running":
            self = .running
        case "succeeded", "success", "ok":
            self = .succeeded
        case "failed", "failure", "error":
            self = .failed
        case "interrupted", "interrupt":
            self = .interrupted
        case "superseded":
            self = .superseded
        case "completed_unknown_status", "unknown":
            self = .completedUnknownStatus
        default:
            return nil
        }
    }
}

private extension TerminalCommandBoundaryConfidence {
    init?(queryValue: String) {
        switch queryValue {
        case "high":
            self = .high
        case "medium", "med":
            self = .medium
        case "low":
            self = .low
        default:
            return nil
        }
    }
}
