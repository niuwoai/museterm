import Foundation

/// Reads a plugin package.json without executing it. The rules match `@niuwoai/museterm-plugin`.
enum TerminalPluginManifest {
    static let schemaVersion = 1
    static let permissions = ["palette", "terminal.fill", "ai.suggest", "recording.observe"]
    private static let lifecycleScripts = ["preinstall", "install", "postinstall", "prepare"]
    private static let dependencyFields = ["dependencies", "devDependencies", "optionalDependencies"]
    private static let remoteDependencyPrefixes = ["file:", "link:", "git+", "git:", "github:", "gitlab:", "bitbucket:"]
    private static let commandID = try! NSRegularExpression(pattern: "^[a-z][a-z0-9]{0,30}(?:-[a-z0-9]{1,31}){0,3}$")
    private static let exportName = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9]{0,62}$")
    private static let packageName = try! NSRegularExpression(pattern: "^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$")
    private static let versionPattern = try! NSRegularExpression(pattern: "^(\\d+)\\.(\\d+)\\.(\\d+)(?:-rc(\\d+))?$")

    static func read(packageData: Data, appVersion: String = AppVersion.value) -> Result<PluginDraft, TerminalPluginManifestFailure> {
        guard let value = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any] else {
            return .failure(TerminalPluginManifestFailure(issues: [issue("", "package.json \u{5fc5}\u{987b}\u{662f}\u{5bf9}\u{8c61}")]))
        }
        return read(package: value, appVersion: appVersion)
    }

    static func read(package value: [String: Any], appVersion: String) -> Result<PluginDraft, TerminalPluginManifestFailure> {
        var issues: [TerminalPluginIssue] = []
        let name = string(value["name"])
        if !matches(packageName, name) {
            issues.append(issue("/name", "\u{5305}\u{540d}\u{5fc5}\u{987b}\u{662f}\u{5408}\u{6cd5}\u{7684} npm \u{5305}\u{540d}"))
        }
        let version = string(value["version"])
        if version.isEmpty {
            issues.append(issue("/version", "\u{5fc5}\u{987b}\u{6709}\u{7248}\u{672c}\u{53f7}"))
        }
        if let scripts = value["scripts"] as? [String: Any],
           lifecycleScripts.contains(where: { scripts[$0] != nil }) {
            issues.append(issue("/scripts", "\u{4e0d}\u{80fd}\u{5e26} preinstall\u{3001}install\u{3001}postinstall \u{6216} prepare"))
        }
        issues.append(contentsOf: dependencyIssues(value))

        guard let manifest = value["museterm"] as? [String: Any] else {
            issues.append(issue("/museterm", "\u{7f3a}\u{5c11} museterm"))
            return .failure(TerminalPluginManifestFailure(issues: issues))
        }
        let manifestIssues = validate(manifest, appVersion: appVersion)
        issues.append(contentsOf: manifestIssues)
        guard manifestIssues.isEmpty, issues.isEmpty else {
            return .failure(TerminalPluginManifestFailure(issues: issues))
        }

        let commands = ((manifest["commands"] as? [[String: Any]]) ?? []).compactMap(command)
        let preferences = ((manifest["preferences"] as? [[String: Any]]) ?? []).compactMap(preference)
        let ai = manifest["ai"] as? [String: Any]
        let recording = manifest["recording"] as? [String: Any]
        return .success(PluginDraft(
            id: name,
            version: version,
            displayName: localized(manifest["displayName"]) ?? name,
            permissions: (manifest["permissions"] as? [String]) ?? [],
            commands: commands,
            preferences: preferences,
            suggestExport: string(ai?["suggest"]),
            recordingExport: string(recording?["onFinished"]),
            entry: string(manifest["entry"])
        ))
    }

    static func validate(_ manifest: [String: Any], appVersion: String) -> [TerminalPluginIssue] {
        var issues: [TerminalPluginIssue] = []
        let root = "/museterm"
        if manifest["schemaVersion"] as? Int != schemaVersion {
            issues.append(issue("\(root)/schemaVersion", "schemaVersion \u{5fc5}\u{987b}\u{662f} 1"))
        }
        let allowed = Set(["schemaVersion", "engines", "entry", "displayName", "permissions", "commands", "preferences", "ai", "recording"])
        for key in manifest.keys where !allowed.contains(key) {
            issues.append(issue(root, "\u{4e0d}\u{80fd}\u{6709}\u{989d}\u{5916}\u{5b57}\u{6bb5} \(key)"))
        }

        let engines = manifest["engines"] as? [String: Any]
        let range = string(engines?["museterm"])
        if range.isEmpty || range.count > 64 {
            issues.append(issue("\(root)/engines/museterm", "\u{5fc5}\u{987b}\u{58f0}\u{660e} engines.museterm"))
        } else if let covered = versionRangeCovers(range, appVersion), !covered {
            issues.append(issue("\(root)/engines/museterm", "\(range) \u{4e0d}\u{8986}\u{76d6}\u{5e94}\u{7528}\u{7248}\u{672c} \(appVersion)"))
        } else if versionRangeCovers(range, appVersion) == nil {
            issues.append(issue("\(root)/engines/museterm", "\u{7248}\u{672c}\u{8303}\u{56f4}\u{53ea}\u{63a5}\u{53d7}\u{7cbe}\u{786e}\u{7248}\u{672c}\u{3001}* \u{6216} >="))
        }

        let entry = string(manifest["entry"])
        if entry.isEmpty || entry.count > 200 || entry.contains("..") || entry.hasPrefix("/") {
            issues.append(issue("\(root)/entry", "entry \u{5fc5}\u{987b}\u{662f}\u{63d2}\u{4ef6}\u{76ee}\u{5f55}\u{5185}\u{7684}\u{76f8}\u{5bf9}\u{8def}\u{5f84}"))
        }
        if localized(manifest["displayName"]) == nil {
            issues.append(issue("\(root)/displayName", "\u{663e}\u{793a}\u{540d}\u{5fc5}\u{987b}\u{540c}\u{65f6}\u{6709} en \u{548c} zh-Hans"))
        }

        let declared = manifest["permissions"] as? [String] ?? []
        if declared.isEmpty {
            issues.append(issue("\(root)/permissions", "\u{81f3}\u{5c11}\u{58f0}\u{660e}\u{4e00}\u{9879}\u{6743}\u{9650}"))
        }
        if declared.count != Set(declared).count {
            issues.append(issue("\(root)/permissions", "\u{6743}\u{9650}\u{6709}\u{91cd}\u{590d}\u{9879}"))
        }
        for (offset, permission) in declared.enumerated() where !permissions.contains(permission) {
            issues.append(issue("\(root)/permissions/\(offset)", "\u{6743}\u{9650}\u{4e0d}\u{5728}\u{5141}\u{8bb8}\u{8303}\u{56f4}\u{5185}"))
        }

        let commands = manifest["commands"] as? [[String: Any]] ?? []
        if commands.isEmpty || commands.count > 24 {
            issues.append(issue("\(root)/commands", "\u{547d}\u{4ee4}\u{6570}\u{91cf}\u{5fc5}\u{987b}\u{5728} 1 \u{5230} 24 \u{4e4b}\u{95f4}"))
        }
        if !declared.contains("palette") && !commands.isEmpty {
            issues.append(issue("\(root)/permissions", "\u{58f0}\u{660e}\u{4e86}\u{547d}\u{4ee4}\u{5c31}\u{5fc5}\u{987b}\u{6709} palette \u{6743}\u{9650}"))
        }
        issues.append(contentsOf: commandIssues(commands))
        issues.append(contentsOf: preferenceIssues(manifest["preferences"]))

        if manifest["ai"] != nil && !declared.contains("ai.suggest") {
            issues.append(issue("\(root)/ai", "\u{58f0}\u{660e}\u{4e86} AI \u{5019}\u{9009}\u{5c31}\u{5fc5}\u{987b}\u{6709} ai.suggest \u{6743}\u{9650}"))
        }
        if manifest["recording"] != nil && !declared.contains("recording.observe") {
            issues.append(issue("\(root)/recording", "\u{58f0}\u{660e}\u{4e86}\u{5f55}\u{5236}\u{89c2}\u{5bdf}\u{5c31}\u{5fc5}\u{987b}\u{6709} recording.observe \u{6743}\u{9650}"))
        }
        if let ai = manifest["ai"] as? [String: Any], !matches(exportName, string(ai["suggest"])) {
            issues.append(issue("\(root)/ai/suggest", "\u{5bfc}\u{51fa}\u{51fd}\u{6570}\u{540d}\u{683c}\u{5f0f}\u{4e0d}\u{5bf9}"))
        }
        if let recording = manifest["recording"] as? [String: Any],
           !matches(exportName, string(recording["onFinished"])) {
            issues.append(issue("\(root)/recording/onFinished", "\u{5bfc}\u{51fa}\u{51fd}\u{6570}\u{540d}\u{683c}\u{5f0f}\u{4e0d}\u{5bf9}"))
        }
        return issues
    }

    /// A release is newer than a release candidate of the same number, so `>=1.262.0` does not cover `1.262.0-rc2`.
    static func versionRangeCovers(_ range: String, _ appVersion: String) -> Bool? {
        guard let current = parseVersion(appVersion) else { return nil }
        if range == "*" { return true }
        let bounded = range.hasPrefix(">=")
        let raw = bounded ? String(range.dropFirst(2)) : range
        guard !raw.isEmpty, !raw.contains(">"), !raw.contains(" "), let minimum = parseVersion(raw) else { return nil }
        let compared = compare(current, minimum)
        return bounded ? compared >= 0 : compared == 0
    }

    struct PluginDraft: Equatable {
        let id: String
        let version: String
        let displayName: String
        let permissions: [String]
        let commands: [TerminalPluginCommand]
        let preferences: [TerminalPluginPreference]
        let suggestExport: String
        let recordingExport: String
        let entry: String
    }

    private static func commandIssues(_ commands: [[String: Any]]) -> [TerminalPluginIssue] {
        var issues: [TerminalPluginIssue] = []
        var ids = Set<String>()
        var exports = Set<String>()
        for (offset, command) in commands.enumerated() {
            let path = "/museterm/commands/\(offset)"
            let id = string(command["id"])
            if !matches(commandID, id) {
                issues.append(issue("\(path)/id", "\u{547d}\u{4ee4} id \u{683c}\u{5f0f}\u{4e0d}\u{5bf9}"))
            } else if !ids.insert(id).inserted {
                issues.append(issue(path, "\u{547d}\u{4ee4} id \u{91cd}\u{590d}：\(id)"))
            }
            if localized(command["title"]) == nil {
                issues.append(issue("\(path)/title", "\u{6807}\u{9898}\u{5fc5}\u{987b}\u{540c}\u{65f6}\u{6709} en \u{548c} zh-Hans"))
            }
            let export = string(command["export"])
            if !matches(exportName, export) {
                issues.append(issue("\(path)/export", "\u{5bfc}\u{51fa}\u{51fd}\u{6570}\u{540d}\u{683c}\u{5f0f}\u{4e0d}\u{5bf9}"))
            } else if !exports.insert(export).inserted {
                issues.append(issue(path, "\u{547d}\u{4ee4}\u{5bfc}\u{51fa}\u{51fd}\u{6570}\u{540d}\u{91cd}\u{590d}：\(export)"))
            }
            if let priority = command["priority"] as? Int, !(0...TerminalPluginCommand.maximumPriority).contains(priority) {
                issues.append(issue("\(path)/priority", "\u{4f18}\u{5148}\u{7ea7}\u{5fc5}\u{987b}\u{5728} 0 \u{5230} \(TerminalPluginCommand.maximumPriority)"))
            }
        }
        return issues
    }

    private static func preferenceIssues(_ value: Any?) -> [TerminalPluginIssue] {
        guard let preferences = value as? [[String: Any]] else {
            return value == nil ? [] : [issue("/museterm/preferences", "\u{504f}\u{597d}\u{5fc5}\u{987b}\u{662f}\u{6570}\u{7ec4}")]
        }
        if preferences.count > 24 {
            return [issue("/museterm/preferences", "\u{504f}\u{597d}\u{6570}\u{91cf}\u{4e0d}\u{80fd}\u{8d85}\u{8fc7} 24")]
        }
        var issues: [TerminalPluginIssue] = []
        var names = Set<String>()
        for (offset, preference) in preferences.enumerated() {
            let path = "/museterm/preferences/\(offset)"
            let name = string(preference["name"])
            if !matches(commandID, name) {
                issues.append(issue("\(path)/name", "\u{504f}\u{597d}\u{540d}\u{79f0}\u{683c}\u{5f0f}\u{4e0d}\u{5bf9}"))
            } else if !names.insert(name).inserted {
                issues.append(issue(path, "\u{504f}\u{597d}\u{540d}\u{79f0}\u{91cd}\u{590d}：\(name)"))
            }
            if localized(preference["title"]) == nil {
                issues.append(issue("\(path)/title", "\u{6807}\u{9898}\u{5fc5}\u{987b}\u{540c}\u{65f6}\u{6709} en \u{548c} zh-Hans"))
            }
            let kind = string(preference["type"])
            switch kind {
            case "text":
                if let fallback = preference["default"], !(fallback is String) {
                    issues.append(issue("\(path)/default", "\u{6587}\u{672c}\u{504f}\u{597d}\u{7684}\u{9ed8}\u{8ba4}\u{503c}\u{5fc5}\u{987b}\u{662f}\u{5b57}\u{7b26}\u{4e32}"))
                }
                if preference["data"] != nil {
                    issues.append(issue("\(path)/data", "\u{6587}\u{672c}\u{504f}\u{597d}\u{4e0d}\u{80fd}\u{6709}\u{9009}\u{9879}"))
                }
            case "boolean":
                if let fallback = preference["default"], !(fallback is Bool) {
                    issues.append(issue("\(path)/default", "\u{5f00}\u{5173}\u{504f}\u{597d}\u{7684}\u{9ed8}\u{8ba4}\u{503c}\u{5fc5}\u{987b}\u{662f}\u{5e03}\u{5c14}\u{503c}"))
                }
                if preference["data"] != nil {
                    issues.append(issue("\(path)/data", "\u{5f00}\u{5173}\u{504f}\u{597d}\u{4e0d}\u{80fd}\u{6709}\u{9009}\u{9879}"))
                }
            case "dropdown":
                let choices = preference["data"] as? [[String: Any]] ?? []
                if choices.isEmpty || choices.count > 16 {
                    issues.append(issue("\(path)/data", "\u{4e0b}\u{62c9}\u{6846}\u{5fc5}\u{987b}\u{6709} 1 \u{5230} 16 \u{4e2a}\u{9009}\u{9879}"))
                }
                var values = Set<String>()
                for (choiceOffset, choice) in choices.enumerated() {
                    let choiceValue = string(choice["value"])
                    if choiceValue.isEmpty || choiceValue.count > 64 {
                        issues.append(issue("\(path)/data/\(choiceOffset)/value", "\u{9009}\u{9879}\u{503c}\u{4e0d}\u{80fd}\u{4e3a}\u{7a7a}\u{6216}\u{8d85}\u{8fc7} 64 \u{4e2a}\u{5b57}\u{7b26}"))
                    } else if !values.insert(choiceValue).inserted {
                        issues.append(issue("\(path)/data", "\u{9009}\u{9879}\u{503c}\u{91cd}\u{590d}：\(choiceValue)"))
                    }
                    if localized(choice["title"]) == nil {
                        issues.append(issue("\(path)/data/\(choiceOffset)/title", "\u{6807}\u{9898}\u{5fc5}\u{987b}\u{540c}\u{65f6}\u{6709} en \u{548c} zh-Hans"))
                    }
                }
                if let fallback = preference["default"] {
                    guard let fallback = fallback as? String, values.contains(fallback) else {
                        issues.append(issue("\(path)/default", "\u{9ed8}\u{8ba4}\u{503c}\u{5fc5}\u{987b}\u{662f}\u{9009}\u{9879}\u{4e4b}\u{4e00}"))
                        break
                    }
                }
            default:
                issues.append(issue("\(path)/type", "\u{504f}\u{597d}\u{7c7b}\u{578b}\u{53ea}\u{80fd}\u{662f} text\u{3001}boolean \u{6216} dropdown"))
            }
        }
        return issues
    }

    private static func preference(_ value: [String: Any]) -> TerminalPluginPreference? {
        guard let name = value["name"] as? String,
              let kind = TerminalPluginPreference.Kind(rawValue: string(value["type"])),
              let title = localized(value["title"]) else { return nil }
        let choices = ((value["data"] as? [[String: Any]]) ?? []).compactMap { choice -> TerminalPluginPreference.Choice? in
            guard let title = localized(choice["title"]), let choiceValue = choice["value"] as? String else { return nil }
            return TerminalPluginPreference.Choice(title: title, value: choiceValue)
        }
        return TerminalPluginPreference(name: name, kind: kind, title: title, choices: choices)
    }

    private static func command(_ value: [String: Any]) -> TerminalPluginCommand? {
        guard let id = value["id"] as? String, let export = value["export"] as? String,
              let title = localized(value["title"]) else { return nil }
        let priority = min(max(value["priority"] as? Int ?? 0, 0), TerminalPluginCommand.maximumPriority)
        return TerminalPluginCommand(
            id: id,
            title: title,
            subtitle: localized(value["subtitle"]) ?? "",
            symbol: (value["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "puzzlepiece.extension",
            priority: priority,
            exportName: export
        )
    }

    private static func dependencyIssues(_ value: [String: Any]) -> [TerminalPluginIssue] {
        dependencyFields.flatMap { field -> [TerminalPluginIssue] in
            guard let dependencies = value[field] as? [String: Any] else { return [] }
            return dependencies.compactMap { name, spec in
                guard let spec = spec as? String,
                      remoteDependencyPrefixes.contains(where: { spec.hasPrefix($0) }) else { return nil }
                return issue("/\(field)/\(name)", "\u{4f9d}\u{8d56}\u{4e0d}\u{80fd}\u{4f7f}\u{7528} file:\u{3001}link: \u{6216} git \u{5730}\u{5740}")
            }
        }
    }

    private static func localized(_ value: Any?) -> String? {
        guard let text = value as? [String: Any],
              let english = text["en"] as? String, !english.isEmpty,
              let chinese = text["zh-Hans"] as? String, !chinese.isEmpty else { return nil }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func issue(_ path: String, _ message: String) -> TerminalPluginIssue {
        TerminalPluginIssue(path: path, message: message)
    }

    private struct ParsedVersion {
        let major: Int
        let minor: Int
        let patch: Int
        let rc: Int?
    }

    private static func parseVersion(_ value: String) -> ParsedVersion? {
        let range = NSRange(value.startIndex..., in: value)
        guard let match = versionPattern.firstMatch(in: value, range: range), match.numberOfRanges == 5 else { return nil }
        func part(_ index: Int) -> String? {
            let part = match.range(at: index)
            guard part.location != NSNotFound, let range = Range(part, in: value) else { return nil }
            return String(value[range])
        }
        guard let major = part(1).flatMap(Int.init),
              let minor = part(2).flatMap(Int.init),
              let patch = part(3).flatMap(Int.init) else { return nil }
        return ParsedVersion(major: major, minor: minor, patch: patch, rc: part(4).flatMap(Int.init))
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    private static func compare(_ left: ParsedVersion, _ right: ParsedVersion) -> Int {
        let byNumber = left.major - right.major
        if byNumber != 0 { return byNumber }
        let byMinor = left.minor - right.minor
        if byMinor != 0 { return byMinor }
        let byPatch = left.patch - right.patch
        if byPatch != 0 { return byPatch }
        if left.rc == right.rc { return 0 }
        if left.rc == nil { return 1 }
        if right.rc == nil { return -1 }
        return (left.rc ?? 0) - (right.rc ?? 0)
    }
}
