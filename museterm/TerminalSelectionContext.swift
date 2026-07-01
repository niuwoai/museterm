import Foundation

struct TerminalSelectionContext: Equatable {
    let rawText: String
    let trimmedText: String
    let singleLineText: String?
    let escapedPathArgument: String?
    let normalizedURL: URL?
    let port: Int?
    let pid: Int32?
    let gitHash: String?
    let prettyJSON: String?

    init?(selection: String?) {
        guard let raw = selection,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        rawText = raw
        trimmedText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        singleLineText = trimmedText.contains(where: \.isNewline) ? nil : trimmedText
        escapedPathArgument = TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: trimmedText)
        normalizedURL = Self.normalizedURL(from: singleLineText)
        port = Self.port(from: singleLineText, normalizedURL: normalizedURL)
        pid = Self.pid(from: singleLineText)
        gitHash = Self.gitHash(from: singleLineText)
        prettyJSON = Self.prettyJSON(from: trimmedText)
    }

    var isLikelyPath: Bool {
        guard let text = singleLineText, escapedPathArgument != nil else { return false }
        if normalizedURL != nil { return false }
        if localPathExists { return true }
        if text.hasPrefix("/") || text.hasPrefix("./") || text.hasPrefix("../") || text.hasPrefix("~/") {
            return true
        }
        if text.hasPrefix("'") || text.hasPrefix("$'") || text.contains("\\") {
            return true
        }
        if text.contains("/") {
            return true
        }
        guard port == nil, pid == nil, gitHash == nil else { return false }
        return Self.isLikelyFileName(text)
    }

    var isExistingLocalDirectory: Bool {
        guard let path = localPathCandidate else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var localPathExists: Bool {
        guard let path = localPathCandidate else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var localPathCandidate: String? {
        guard let text = singleLineText else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("'"),
              !expanded.hasPrefix("$'"),
              !expanded.contains("\\") else {
            return nil
        }
        return expanded
    }

    var urlEncodedText: String? {
        trimmedText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }

    var urlDecodedText: String? {
        guard let decoded = trimmedText.removingPercentEncoding,
              decoded != trimmedText else {
            return nil
        }
        return decoded
    }

    var base64EncodedText: String {
        Data(trimmedText.utf8).base64EncodedString()
    }

    var base64DecodedText: String? {
        let compact = trimmedText
            .split(whereSeparator: \.isWhitespace)
            .joined()
        guard let data = Data(base64Encoded: compact),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty else {
            return nil
        }
        return decoded
    }

    var markdownCodeBlock: String {
        let language = prettyJSON == nil ? "text" : "json"
        return "```\(language)\n\(trimmedText)\n```"
    }

    var interactiveRemoveCommand: String? {
        escapedPathArgument.map { "rm -i -- \($0)" }
    }

    var aiPrompt: String {
        L10n.format("terminal.context.ai_prompt_template", trimmedText)
    }

    private static func normalizedURL(from text: String?) -> URL? {
        guard let text else { return nil }
        if let url = URL(string: text),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           url.host != nil,
           isValidPort(url.port) {
            return url
        }
        if hostPortRegex.matches(text),
           let url = URL(string: "http://\(text)"),
           isValidPort(url.port) {
            return url
        }
        return nil
    }

    private static func port(from text: String?, normalizedURL: URL?) -> Int? {
        if let port = normalizedURL?.port {
            return port
        }
        guard let text, text.hasPrefix(":") else { return nil }
        let candidate = String(text.dropFirst())
        guard candidate.allSatisfy(\.isNumber),
              let port = Int(candidate),
              isValidPort(port) else {
            return nil
        }
        return port
    }

    private static func isValidPort(_ port: Int?) -> Bool {
        guard let port else { return true }
        return (1...65_535).contains(port)
    }

    private static func pid(from text: String?) -> Int32? {
        guard let text,
              !text.hasPrefix(":"),
              text.allSatisfy(\.isNumber),
              let value = Int32(text),
              value > 0 else {
            return nil
        }
        return value
    }

    private static func gitHash(from text: String?) -> String? {
        guard let text, gitHashRegex.matches(text) else { return nil }
        return text
    }

    private static func prettyJSON(from text: String) -> String? {
        guard text.hasPrefix("{") || text.hasPrefix("["),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return pretty
    }

    private static func isLikelyFileName(_ text: String) -> Bool {
        guard !text.contains(":") else { return false }
        if text.hasPrefix(".") {
            let rest = text.dropFirst()
            return !rest.isEmpty
                && rest.contains(where: \.isLetter)
                && !rest.contains(where: \.isWhitespace)
                && !rest.contains("/")
        }
        guard let dot = text.lastIndex(of: ".") else { return false }
        let base = text[..<dot].trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = text[text.index(after: dot)...]
        guard !base.isEmpty,
              (1...12).contains(ext.count),
              ext.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return false
        }
        let numericVersionCharacters = CharacterSet(charactersIn: "0123456789.")
        if base.unicodeScalars.allSatisfy({ numericVersionCharacters.contains($0) }),
           ext.allSatisfy(\.isNumber) {
            return false
        }
        return true
    }

    private static let hostPortRegex = RegexMatcher(
        pattern: #"^(?:localhost|127(?:\.\d{1,3}){3}|\[::1\]|[a-zA-Z0-9.-]+):\d{1,5}(?:/.*)?$"#
    )
    private static let gitHashRegex = RegexMatcher(pattern: #"^[0-9a-fA-F]{7,40}$"#)
}

private struct RegexMatcher: Equatable {
    let pattern: String

    func matches(_ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
