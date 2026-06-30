import Foundation

enum RunbookSensitiveRedactor {
    nonisolated private static let replacement = "[REDACTED]"
    nonisolated private static let patterns: [(String, String)] = [
        (#"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#, replacement),
        (#"(?i)(authorization:\s*bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1\(replacement)"),
        (#"(?i)\b((?:api[_-]?key|token|secret|password|passwd|pwd)\s*[:=]\s*)['"]?[^'"\s]+['"]?"#, "$1\(replacement)"),
        (#"(?i)(^|\s)(--(?:api[_-]?key|token|secret|password|passwd|pwd)(?:=|\s+))['"]?[^'"\s]+['"]?"#, "$1$2\(replacement)"),
        (#"(?i)\b([a-z][a-z0-9+.-]*://[^/\s:@]+:)[^@\s/]+(@)"#, "$1\(replacement)$2"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, replacement),
        (#"\bASIA[0-9A-Z]{16}\b"#, replacement),
        (#"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"#, replacement),
        (#"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, replacement),
        (#"\bsk-[A-Za-z0-9_-]{20,}\b"#, replacement),
        (#"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b"#, replacement),
        (#"\bAIza[0-9A-Za-z_-]{35}\b"#, replacement),
        (#"\bnpm_[A-Za-z0-9]{36}\b"#, replacement),
        (#"(?i)\b(xox[baprs]-[A-Za-z0-9-]{20,})\b"#, replacement),
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, replacement)
    ]

    nonisolated static func redact(_ text: String) -> String {
        patterns.reduce(text) { current, rule in
            current.replacingOccurrences(
                of: rule.0,
                with: rule.1,
                options: .regularExpression
            )
        }
    }

    nonisolated static func containsSensitiveData(_ text: String) -> Bool {
        !text.isEmpty && redact(text) != text
    }
}
