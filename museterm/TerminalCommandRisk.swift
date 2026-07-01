import Foundation

enum TerminalCommandRiskLevel: String, Codable, Equatable {
    case readOnly = "read_only"
    case mutating
    case dangerous
    case unknown

    var contextLabel: String {
        rawValue
    }
}

enum TerminalCommandRiskReason: String, Codable, Equatable {
    case readOnlyInspection = "read_only_inspection"
    case unknownEffects = "unknown_effects"
    case multiCommandSequence = "multi_command_sequence"
    case privilegeEscalation = "privilege_escalation"
    case fileMutation = "file_mutation"
    case fileDeletion = "file_deletion"
    case gitStateChange = "git_state_change"
    case gitDestructiveReset = "git_destructive_reset"
    case packageInstall = "package_install"
    case networkOperation = "network_operation"
    case pipedRemoteScript = "piped_remote_script"
    case serviceOrContainerChange = "service_or_container_change"
    case kubernetesMutation = "kubernetes_mutation"
    case databaseDestructiveOperation = "database_destructive_operation"
    case infrastructureDestructiveOperation = "infrastructure_destructive_operation"
    case diskDestructiveOperation = "disk_destructive_operation"
    case dockerDestructiveCleanup = "docker_destructive_cleanup"

    var contextLabel: String {
        rawValue
    }
}

struct TerminalCommandRiskProfile: Codable, Equatable {
    let level: TerminalCommandRiskLevel
    let reasons: [TerminalCommandRiskReason]
}

enum TerminalCommandRiskAnalyzer {
    static func profile(for command: String) -> TerminalCommandRiskProfile {
        let normalized = normalize(command)
        guard !normalized.isEmpty else {
            return TerminalCommandRiskProfile(level: .unknown, reasons: [.unknownEffects])
        }

        var reasons: [TerminalCommandRiskReason] = []
        appendSequenceReasons(for: normalized, to: &reasons)
        appendDangerousReasons(for: normalized, to: &reasons)
        if reasons.containsDangerousReason {
            return TerminalCommandRiskProfile(level: .dangerous, reasons: reasons)
        }

        appendMutatingReasons(for: normalized, to: &reasons)
        if reasons.containsMutatingReason {
            return TerminalCommandRiskProfile(level: .mutating, reasons: reasons)
        }

        appendNetworkReasons(for: normalized, to: &reasons)
        if isKnownReadOnly(normalized) {
            append(.readOnlyInspection, to: &reasons)
            return TerminalCommandRiskProfile(level: .readOnly, reasons: reasons)
        }

        if !reasons.isEmpty {
            append(.unknownEffects, to: &reasons)
            return TerminalCommandRiskProfile(level: .unknown, reasons: reasons)
        }

        return TerminalCommandRiskProfile(level: .unknown, reasons: [.unknownEffects])
    }

    private static func appendSequenceReasons(for normalized: String, to reasons: inout [TerminalCommandRiskReason]) {
        if normalized.contains("\n")
            || normalized.contains(" && ")
            || normalized.contains(" || ")
            || normalized.contains(";") {
            append(.multiCommandSequence, to: &reasons)
        }
    }

    private static func appendDangerousReasons(for normalized: String, to reasons: inout [TerminalCommandRiskReason]) {
        if normalized.contains("curl ") && normalized.contains("|") && normalized.contains(" sh")
            || normalized.contains("wget ") && normalized.contains("|") && normalized.contains(" sh") {
            append(.pipedRemoteScript, to: &reasons)
        }
        if normalized.contains("rm -rf /")
            || normalized.contains("rm -fr /")
            || normalized.contains("sudo rm -rf")
            || normalized.contains("sudo rm -fr") {
            append(.fileDeletion, to: &reasons)
        }
        if normalized.contains("drop database")
            || normalized.contains("drop schema")
            || normalized.contains("truncate table") {
            append(.databaseDestructiveOperation, to: &reasons)
        }
        if normalized.contains("kubectl delete")
            || normalized.contains("kubectl drain")
            || normalized.contains("kubectl scale") {
            append(.kubernetesMutation, to: &reasons)
        }
        if normalized.contains("terraform destroy") {
            append(.infrastructureDestructiveOperation, to: &reasons)
        }
        if normalized.contains("mkfs.")
            || normalized.contains("diskutil erase")
            || normalized.contains("dd if=") && normalized.contains(" of=/dev/") {
            append(.diskDestructiveOperation, to: &reasons)
        }
        if normalized.contains("docker system prune") && normalized.contains("-a") {
            append(.dockerDestructiveCleanup, to: &reasons)
        }
        if normalized.contains("git reset --hard") {
            append(.gitDestructiveReset, to: &reasons)
        }
    }

    private static func appendMutatingReasons(for normalized: String, to reasons: inout [TerminalCommandRiskReason]) {
        if startsWithCommand(normalized, "sudo") || startsWithCommand(normalized, "doas") {
            append(.privilegeEscalation, to: &reasons)
        }
        if normalized.contains(" > ")
            || normalized.contains(" >> ")
            || normalized.contains(" 2> ")
            || normalized.contains("sed -i")
            || startsWithAnyCommand(normalized, ["cp", "mv", "mkdir", "touch", "chmod", "chown", "ln"]) {
            append(.fileMutation, to: &reasons)
        }
        if startsWithAnyCommand(normalized, ["rm", "rmdir"]) {
            append(.fileDeletion, to: &reasons)
        }
        if normalized.contains("git commit")
            || normalized.contains("git merge")
            || normalized.contains("git rebase")
            || normalized.contains("git push")
            || normalized.contains("git pull")
            || normalized.contains("git checkout")
            || normalized.contains("git switch")
            || normalized.contains("git reset") {
            append(.gitStateChange, to: &reasons)
        }
        if normalized.contains(" install ")
            || startsWithAnyCommand(normalized, ["brew install", "apt install", "apt-get install", "dnf install", "yum install", "pacman -s", "apk add", "npm install", "npm i", "yarn add", "pnpm add", "pip install", "gem install", "cargo install", "go install"]) {
            append(.packageInstall, to: &reasons)
        }
        if startsWithAnyCommand(normalized, ["docker run", "docker build", "docker compose up", "docker stop", "docker rm"]) {
            append(.serviceOrContainerChange, to: &reasons)
        }
        if startsWithAnyCommand(normalized, ["kubectl apply", "kubectl patch", "kubectl rollout", "kubectl exec"]) {
            append(.kubernetesMutation, to: &reasons)
        }
        if startsWithAnyCommand(normalized, ["terraform apply", "terraform plan -out"]) {
            append(.infrastructureDestructiveOperation, to: &reasons)
        }
    }

    private static func appendNetworkReasons(for normalized: String, to reasons: inout [TerminalCommandRiskReason]) {
        if startsWithAnyCommand(normalized, ["curl", "wget", "ssh", "scp", "rsync", "sftp", "gh", "git clone", "git fetch"]) {
            append(.networkOperation, to: &reasons)
        }
    }

    private static func isKnownReadOnly(_ normalized: String) -> Bool {
        if startsWithAnyCommand(
            normalized,
            [
                "ls", "pwd", "cat", "less", "more", "tail", "head", "grep", "rg", "find", "awk",
                "jq", "yq", "ps", "lsof", "netstat", "ss", "whoami", "id", "uname", "date",
                "df", "du", "env", "printenv", "which", "where", "type", "echo", "printf",
                "git status", "git log", "git diff", "git show", "git branch", "git rev-parse"
            ]
        ) {
            return !normalized.contains(" -delete")
                && !normalized.contains(" -exec ")
                && !normalized.contains("sed -i")
                && !normalized.contains(" > ")
                && !normalized.contains(" >> ")
        }
        return false
    }

    private static func startsWithAnyCommand(_ normalized: String, _ commands: [String]) -> Bool {
        commands.contains { startsWithCommand(normalized, $0) }
    }

    private static func startsWithCommand(_ normalized: String, _ command: String) -> Bool {
        normalized == command || normalized.hasPrefix("\(command) ")
    }

    private static func append(_ reason: TerminalCommandRiskReason, to reasons: inout [TerminalCommandRiskReason]) {
        if !reasons.contains(reason) {
            reasons.append(reason)
        }
    }

    private static func normalize(_ command: String) -> String {
        command
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array where Element == TerminalCommandRiskReason {
    var containsDangerousReason: Bool {
        contains(.fileDeletion)
            || contains(.gitDestructiveReset)
            || contains(.databaseDestructiveOperation)
            || contains(.kubernetesMutation)
            || contains(.infrastructureDestructiveOperation)
            || contains(.diskDestructiveOperation)
            || contains(.dockerDestructiveCleanup)
            || contains(.pipedRemoteScript)
    }

    var containsMutatingReason: Bool {
        contains(.privilegeEscalation)
            || contains(.fileMutation)
            || contains(.fileDeletion)
            || contains(.gitStateChange)
            || contains(.packageInstall)
            || contains(.serviceOrContainerChange)
            || contains(.kubernetesMutation)
            || contains(.infrastructureDestructiveOperation)
    }
}
