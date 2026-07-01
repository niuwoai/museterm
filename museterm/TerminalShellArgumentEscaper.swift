import Foundation

enum TerminalShellArgumentEscaper {
    static func typedArgument(fromTerminalSelection selection: String?) -> String? {
        escapedPathArgument(fromTerminalSelection: selection).map { " " + $0 }
    }

    static func escapedPathArgument(fromTerminalSelection selection: String?) -> String? {
        guard let trimmed = selection?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isNewline }) else {
            return nil
        }

        if isExistingShellWord(trimmed) {
            return trimmed
        }

        if trimmed.hasPrefix("-") {
            return "./" + singleQuoted(trimmed)
        }
        return singleQuoted(trimmed)
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isExistingShellWord(_ value: String) -> Bool {
        var index = value.startIndex
        var sawShellEscaping = false

        while index < value.endIndex {
            if value[index] == "'" {
                guard advancePastSingleQuotedSegment(in: value, index: &index) else { return false }
                sawShellEscaping = true
            } else if value[index] == "$", value.index(after: index) < value.endIndex, value[value.index(after: index)] == "'" {
                guard advancePastANSICQuotedSegment(in: value, index: &index) else { return false }
                sawShellEscaping = true
            } else if value[index] == "\\" {
                let next = value.index(after: index)
                guard next < value.endIndex else { return false }
                index = value.index(after: next)
                sawShellEscaping = true
            } else if isSafeUnquotedShellCharacter(value[index]) {
                index = value.index(after: index)
            } else {
                return false
            }
        }

        return sawShellEscaping
    }

    private static func advancePastSingleQuotedSegment(in value: String, index: inout String.Index) -> Bool {
        index = value.index(after: index)
        while index < value.endIndex {
            if value[index] == "'" {
                index = value.index(after: index)
                return true
            }
            index = value.index(after: index)
        }
        return false
    }

    private static func advancePastANSICQuotedSegment(in value: String, index: inout String.Index) -> Bool {
        index = value.index(index, offsetBy: 2)
        while index < value.endIndex {
            if value[index] == "\\" {
                let next = value.index(after: index)
                guard next < value.endIndex else { return false }
                index = value.index(after: next)
            } else if value[index] == "'" {
                index = value.index(after: index)
                return true
            } else {
                index = value.index(after: index)
            }
        }
        return false
    }

    private static func isSafeUnquotedShellCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return true
            case 45, 46, 47, 58, 61, 64, 95, 43, 44, 37, 126:
                return true
            default:
                return false
            }
        }
    }
}
