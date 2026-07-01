import AppKit
import Foundation

struct SafetyDangerousCommandRule {
    let nameKey: String?
    let displayName: String?
    let matches: (String) -> Bool

    init(nameKey: String, matches: @escaping (String) -> Bool) {
        self.nameKey = nameKey
        displayName = nil
        self.matches = matches
    }

    init(displayName: String, matches: @escaping (String) -> Bool) {
        nameKey = nil
        self.displayName = displayName
        self.matches = matches
    }

    var localizedName: String {
        if let displayName {
            return L10n.format("safety.rule.custom", displayName)
        }
        guard let nameKey else { return L10n.string("safety.rule.custom_fallback") }
        return L10n.string(nameKey)
    }
}

enum SafetyInputAnalyzer {
    private static let dangerousRules: [SafetyDangerousCommandRule] = [
        SafetyDangerousCommandRule(nameKey: "safety.rule.recursive_delete") { command in
            let normalized = normalized(command)
            return normalized.contains("rm -rf /")
                || normalized.contains("rm -fr /")
                || normalized.contains("sudo rm -rf")
                || normalized.contains("sudo rm -fr")
        },
        SafetyDangerousCommandRule(nameKey: "safety.rule.database_drop") { command in
            let normalized = normalized(command)
            return normalized.contains("drop database")
                || normalized.contains("drop schema")
                || normalized.contains("truncate table")
        },
        SafetyDangerousCommandRule(nameKey: "safety.rule.kubernetes_delete") { command in
            let normalized = normalized(command)
            return normalized.contains("kubectl delete")
                || normalized.contains("kubectl drain")
                || normalized.contains("kubectl scale")
        },
        SafetyDangerousCommandRule(nameKey: "safety.rule.terraform_destroy") { command in
            normalized(command).contains("terraform destroy")
        },
        SafetyDangerousCommandRule(nameKey: "safety.rule.disk_destroy") { command in
            let normalized = normalized(command)
            return normalized.contains("mkfs.")
                || normalized.contains("diskutil erase")
                || normalized.contains("dd if=") && normalized.contains(" of=/dev/")
        },
        SafetyDangerousCommandRule(nameKey: "safety.rule.docker_prune") { command in
            let normalized = normalized(command)
            return normalized.contains("docker system prune") && normalized.contains("-a")
        },
        SafetyDangerousCommandRule(nameKey: "safety.rule.git_reset") { command in
            normalized(command).contains("git reset --hard")
        }
    ]

    static func isMultilinePaste(_ text: String) -> Bool {
        guard text.count > 1 else { return false }
        return nonEmptyLineCount(in: text) >= 2
    }

    static func nonEmptyLineCount(in text: String) -> Int {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    static func dangerousRule(for command: String, customRulesText: String) -> SafetyDangerousCommandRule? {
        dangerousRules.first { $0.matches(command) }
            ?? customDangerousRules(from: customRulesText).first { $0.matches(command) }
    }

    static func preview(_ text: String) -> String {
        let limit = 4_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n..."
    }

    static func multilinePasteConfirmationMessage(for text: String) -> String {
        if isMuseTermRemoteShellIntegrationBootstrap(text) {
            return [
                L10n.string("safety.multiline.remote_integration.message"),
                L10n.string("safety.multiline.remote_integration.scope")
            ].joined(separator: "\n\n")
        }

        return [
            L10n.format("safety.multiline.message", nonEmptyLineCount(in: text)),
            L10n.string("safety.multiline.reason")
        ].joined(separator: "\n\n")
    }

    static func multilinePasteConfirmationTitle(for text: String) -> String {
        isMuseTermRemoteShellIntegrationBootstrap(text)
            ? L10n.string("safety.multiline.remote_integration.title")
            : L10n.string("safety.multiline.title")
    }

    static func multilinePastePrimaryActionTitle(for text: String) -> String {
        isMuseTermRemoteShellIntegrationBootstrap(text)
            ? L10n.string("safety.multiline.remote_integration.action")
            : L10n.string("safety.action.send")
    }

    static func isMuseTermRemoteShellIntegrationBootstrap(_ text: String) -> Bool {
        text.contains("_museterm_remote_preexec")
            && text.contains("_museterm_remote_precmd")
            && text.contains("_museterm_remote_prompt_command")
            && text.contains("MuseTerm;start=")
            && text.contains("MuseTerm;end=")
    }

    private static func normalized(_ command: String) -> String {
        command
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func customDangerousRules(from text: String) -> [SafetyDangerousCommandRule] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

            if trimmed.lowercased().hasPrefix("regex:") {
                let pattern = String(trimmed.dropFirst("regex:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pattern.isEmpty,
                      let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    return nil
                }
                return SafetyDangerousCommandRule(displayName: "regex:\(pattern)") { command in
                    let range = NSRange(command.startIndex..<command.endIndex, in: command)
                    return regex.firstMatch(in: command, range: range) != nil
                }
            }

            let needle = normalized(trimmed)
            guard !needle.isEmpty else { return nil }
            return SafetyDangerousCommandRule(displayName: trimmed) { command in
                normalized(command).contains(needle)
            }
        }
    }
}

final class SafetyPreviewTextView: NSScrollView {
    init(text: String) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor

        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
        hasVerticalScroller = true
        borderType = .bezelBorder
        documentView = textView
    }

    required init?(coder: NSCoder) {
        nil
    }
}
