import AppKit
import Foundation

struct TerminalShortcutExternalEditor: Identifiable {
    let name: String
    let bundleIdentifiers: [String]
    let applicationPaths: [String]
    let systemImage: String

    var id: String {
        (bundleIdentifiers.first ?? name).lowercased()
    }

    var applicationURL: URL? {
        for bundleIdentifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url
            }
        }

        for path in applicationPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return nil
    }

    static var installedEditors: [TerminalShortcutExternalEditor] {
        commonEditors
            .filter { $0.applicationURL != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func open(
        fileURL: URL,
        with editor: TerminalShortcutExternalEditor?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let editor else {
            completion(NSWorkspace.shared.open(fileURL))
            return
        }

        guard let appURL = editor.applicationURL else {
            completion(false)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                completion(error == nil)
            }
        }
    }

    private static let commonEditors: [TerminalShortcutExternalEditor] = [
        .init(
            name: "BBEdit",
            bundleIdentifiers: ["com.barebones.bbedit"],
            applicationPaths: applicationPaths(named: "BBEdit"),
            systemImage: "doc.text"
        ),
        .init(
            name: "CotEditor",
            bundleIdentifiers: ["com.coteditor.CotEditor"],
            applicationPaths: applicationPaths(named: "CotEditor"),
            systemImage: "doc.text"
        ),
        .init(
            name: "Cursor",
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            applicationPaths: applicationPaths(named: "Cursor"),
            systemImage: "terminal"
        ),
        .init(
            name: "MacVim",
            bundleIdentifiers: ["org.vim.MacVim"],
            applicationPaths: applicationPaths(named: "MacVim"),
            systemImage: "doc.text"
        ),
        .init(
            name: "Nova",
            bundleIdentifiers: ["com.panic.Nova"],
            applicationPaths: applicationPaths(named: "Nova"),
            systemImage: "curlybraces"
        ),
        .init(
            name: "Sublime Text",
            bundleIdentifiers: ["com.sublimetext.4", "com.sublimetext.3"],
            applicationPaths: applicationPaths(named: "Sublime Text"),
            systemImage: "doc.text"
        ),
        .init(
            name: "TextEdit",
            bundleIdentifiers: ["com.apple.TextEdit"],
            applicationPaths: applicationPaths(named: "TextEdit"),
            systemImage: "doc.plaintext"
        ),
        .init(
            name: "TextMate",
            bundleIdentifiers: ["com.macromates.TextMate"],
            applicationPaths: applicationPaths(named: "TextMate"),
            systemImage: "doc.text"
        ),
        .init(
            name: "Visual Studio Code",
            bundleIdentifiers: ["com.microsoft.VSCode"],
            applicationPaths: applicationPaths(named: "Visual Studio Code"),
            systemImage: "curlybraces"
        ),
        .init(
            name: "Zed",
            bundleIdentifiers: ["dev.zed.Zed"],
            applicationPaths: applicationPaths(named: "Zed"),
            systemImage: "curlybraces"
        )
    ]

    private static func applicationPaths(named appName: String) -> [String] {
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("\(appName).app", isDirectory: true)
            .path
        return [
            "/Applications/\(appName).app",
            "/System/Applications/\(appName).app",
            homeApplications
        ]
    }
}
