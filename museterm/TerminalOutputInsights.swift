import Foundation

enum TerminalOutputInsightKind: String, CaseIterable {
    case error
    case warning
    case url
    case filePath
    case json
    case yaml
    case stackTrace
    case commitHash

    var labelKey: String {
        "output_insight.\(rawValue)"
    }
}

struct TerminalOutputInsight: Identifiable, Equatable {
    let kind: TerminalOutputInsightKind
    let value: String
    let line: String

    var id: String {
        "\(kind.rawValue):\(value):\(line)"
    }
}

enum TerminalOutputInsightAnalyzer {
    private static let maxInsightsPerKind = 3

    static func insights(in text: String) -> [TerminalOutputInsight] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [TerminalOutputInsight] = []
        var counts: [TerminalOutputInsightKind: Int] = [:]

        func append(_ kind: TerminalOutputInsightKind, value: String, line: String) {
            guard (counts[kind] ?? 0) < maxInsightsPerKind else { return }
            let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanValue.isEmpty || !cleanLine.isEmpty else { return }
            let insight = TerminalOutputInsight(kind: kind, value: cleanValue, line: cleanLine)
            guard !result.contains(insight) else { return }
            result.append(insight)
            counts[kind, default: 0] += 1
        }

        if looksLikeJSON(trimmed) {
            append(.json, value: "JSON", line: firstNonEmptyLine(in: trimmed))
        }
        if looksLikeYAML(trimmed) {
            append(.yaml, value: "YAML", line: firstNonEmptyLine(in: trimmed))
        }

        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lowercased = line.lowercased()

            if lowercased.contains("error")
                || lowercased.contains("exception")
                || lowercased.contains("failed")
                || lowercased.contains("fatal") {
                append(.error, value: keyPhrase(from: line), line: line)
            }
            if lowercased.contains("warning") || lowercased.contains("warn:") {
                append(.warning, value: keyPhrase(from: line), line: line)
            }
            if lowercased.contains("traceback")
                || lowercased.contains("stack trace")
                || lowercased.range(of: #"^\s*at\s+\S+"#, options: .regularExpression) != nil {
                append(.stackTrace, value: keyPhrase(from: line), line: line)
            }

            for url in matches(in: line, pattern: #"https?://[^\s<>"']+"#) {
                append(.url, value: url, line: line)
            }
            for path in matches(in: line, pattern: #"(?<![\w.-])(?:/[\w .@%+=:,~_-]+)+(?::\d+(?::\d+)?)?"#) {
                append(.filePath, value: path, line: line)
            }
            for relativePath in matches(in: line, pattern: #"\b[\w.-]+(?:/[\w .@%+=:,~_-]+)+\.(?:swift|go|js|jsx|ts|tsx|rb|py|rs|java|kt|m|mm|c|cc|cpp|h|hpp|json|yaml|yml|toml|md)(?::\d+(?::\d+)?)?"#) {
                append(.filePath, value: relativePath, line: line)
            }
            for hash in matches(in: line, pattern: #"\b[0-9a-f]{7,40}\b"#) where line.range(of: #"(?i)\b(commit|hash|sha|revision|rev)\b"#, options: .regularExpression) != nil {
                append(.commitHash, value: hash, line: line)
            }
        }

        return result
    }

    static func summary(in text: String) -> String {
        let insights = insights(in: text)
        guard !insights.isEmpty else { return "" }

        var lines: [String] = []
        if let formattedJSON = formattedJSON(in: text) {
            lines.append("formattedJSON:")
            lines.append(limit(formattedJSON, to: 6_000))
            lines.append("")
        }
        for kind in TerminalOutputInsightKind.allCases {
            let items = insights.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            lines.append("\(kind.rawValue):")
            for item in items {
                let value = item.value.isEmpty ? item.line : item.value
                lines.append("- \(value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func formattedJSON(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeJSON(trimmed), let data = trimmed.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let formattedData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let formatted = String(data: formattedData, encoding: .utf8) else {
            return nil
        }
        return formatted
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[" else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func looksLikeYAML(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.count >= 2 else { return false }
        let yamlLikeCount = lines.prefix(12).filter { line in
            line.range(of: #"^[A-Za-z0-9_.-]+\s*:\s*.+"#, options: .regularExpression) != nil
                || line.range(of: #"^-\s+[A-Za-z0-9_.-]+\s*:\s*.+"#, options: .regularExpression) != nil
        }.count
        return yamlLikeCount >= 2
    }

    private static func firstNonEmptyLine(in text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func keyPhrase(from line: String) -> String {
        String(line.prefix(180))
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n..."
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]"))
        }
    }
}
