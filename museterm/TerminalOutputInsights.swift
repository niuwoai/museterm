import Foundation

enum TerminalOutputInsightKind: String, CaseIterable, Codable {
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

struct TerminalOutputInsight: Identifiable, Equatable, Codable {
    let kind: TerminalOutputInsightKind
    let value: String
    let line: String

    var id: String {
        "\(kind.rawValue):\(value):\(line)"
    }
}

struct TerminalOutputSummary: Codable, Equatable {
    var insightKinds: [TerminalOutputInsightKind]
    var errorLine: String?
    var warningLine: String?
    var url: String?
    var filePath: String?
    var commitHash: String?
    var stackTraceLine: String?

    nonisolated var isEmpty: Bool {
        insightKinds.isEmpty
            && errorLine == nil
            && warningLine == nil
            && url == nil
            && filePath == nil
            && commitHash == nil
            && stackTraceLine == nil
    }

    nonisolated var searchableText: String {
        [
            insightKinds.map(\.rawValue).joined(separator: " "),
            errorLine ?? "",
            warningLine ?? "",
            url ?? "",
            filePath ?? "",
            commitHash ?? "",
            stackTraceLine ?? ""
        ].joined(separator: "\n")
    }

    nonisolated var aiContextText: String {
        var lines: [String] = []
        if !insightKinds.isEmpty {
            lines.append("Output insight kinds: \(insightKinds.map(\.rawValue).joined(separator: ", "))")
        }
        if let errorLine {
            lines.append("Output error: \(errorLine)")
        }
        if let warningLine {
            lines.append("Output warning: \(warningLine)")
        }
        if let url {
            lines.append("Output URL: \(url)")
        }
        if let filePath {
            lines.append("Output path: \(filePath)")
        }
        if let commitHash {
            lines.append("Output commit: \(commitHash)")
        }
        if let stackTraceLine {
            lines.append("Output stack: \(stackTraceLine)")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated var primaryDiagnosticLine: String? {
        [
            errorLine,
            warningLine,
            stackTraceLine,
            filePath,
            url,
            commitHash
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

enum TerminalOutputInsightAnalyzer {
    nonisolated private static let maxInsightsPerKind = 3

    // 这些正则在每个输出块、每一行上反复使用，必须只编译一次。
    nonisolated private static let urlRegex = compiledRegex(#"https?://[^\s<>"']+"#)
    nonisolated private static let absolutePathRegex = compiledRegex(#"(?<![\w.-])(?:/[\w .@%+=:,~_-]+)+(?::\d+(?::\d+)?)?"#)
    nonisolated private static let relativePathRegex = compiledRegex(#"\b[\w.-]+(?:/[\w .@%+=:,~_-]+)+\.(?:swift|go|js|jsx|ts|tsx|rb|py|rs|java|kt|m|mm|c|cc|cpp|h|hpp|json|yaml|yml|toml|md)(?::\d+(?::\d+)?)?"#)
    nonisolated private static let commitHashRegex = compiledRegex(#"\b[0-9a-f]{7,40}\b"#)
    nonisolated private static let commitContextRegex = compiledRegex(#"(?i)\b(commit|hash|sha|revision|rev)\b"#)
    nonisolated private static let stackFrameRegex = compiledRegex(#"^\s*at\s+\S+"#)
    nonisolated private static let yamlKeyValueRegex = compiledRegex(#"^[A-Za-z0-9_.-]+\s*:\s*.+"#)
    nonisolated private static let yamlListItemRegex = compiledRegex(#"^-\s+[A-Za-z0-9_.-]+\s*:\s*.+"#)

    nonisolated private static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    nonisolated private static func hasMatch(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    nonisolated static func insights(in text: String) -> [TerminalOutputInsight] {
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
                || hasMatch(stackFrameRegex, in: lowercased) {
                append(.stackTrace, value: keyPhrase(from: line), line: line)
            }

            for url in matches(in: line, regex: urlRegex) {
                append(.url, value: url, line: line)
            }
            for path in matches(in: line, regex: absolutePathRegex) {
                append(.filePath, value: path, line: line)
            }
            for relativePath in matches(in: line, regex: relativePathRegex) {
                append(.filePath, value: relativePath, line: line)
            }
            if hasMatch(commitContextRegex, in: line) {
                for hash in matches(in: line, regex: commitHashRegex) {
                    append(.commitHash, value: hash, line: line)
                }
            }
        }

        return result
    }

    nonisolated static func summary(in text: String) -> String {
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

    nonisolated static func outputSummary(in text: String) -> TerminalOutputSummary? {
        let insights = insights(in: text)
        guard !insights.isEmpty else { return nil }

        let kinds = TerminalOutputInsightKind.allCases.filter { kind in
            insights.contains { $0.kind == kind }
        }
        let result = TerminalOutputSummary(
            insightKinds: kinds,
            errorLine: firstLine(for: .error, in: insights),
            warningLine: firstLine(for: .warning, in: insights),
            url: firstValue(for: .url, in: insights),
            filePath: firstValue(for: .filePath, in: insights),
            commitHash: firstValue(for: .commitHash, in: insights),
            stackTraceLine: firstLine(for: .stackTrace, in: insights)
        )
        return result.isEmpty ? nil : result
    }

    nonisolated static func formattedJSON(in text: String) -> String? {
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

    nonisolated private static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[" else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    nonisolated private static func looksLikeYAML(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.count >= 2 else { return false }
        let yamlLikeCount = lines.prefix(12).filter { line in
            hasMatch(yamlKeyValueRegex, in: line) || hasMatch(yamlListItemRegex, in: line)
        }.count
        return yamlLikeCount >= 2
    }

    nonisolated private static func firstNonEmptyLine(in text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    nonisolated private static func keyPhrase(from line: String) -> String {
        String(line.prefix(180))
    }

    nonisolated private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n..."
    }

    nonisolated private static func firstValue(for kind: TerminalOutputInsightKind, in insights: [TerminalOutputInsight]) -> String? {
        insights.first { $0.kind == kind }?.value
    }

    nonisolated private static func firstLine(for kind: TerminalOutputInsightKind, in insights: [TerminalOutputInsight]) -> String? {
        insights.first { $0.kind == kind }?.line
    }

    nonisolated private static func matches(in text: String, regex: NSRegularExpression?) -> [String] {
        guard let regex else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]"))
        }
    }
}
