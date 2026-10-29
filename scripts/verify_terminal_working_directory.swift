import Darwin
import Foundation

@main
struct WorkingDirectoryProbe {
    static func main() throws {
        let prefix = CommandLine.arguments.dropFirst().first ?? "/private/tmp/museterm-working-directory"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-cwd-\(UUID())")
        let directory = root.appendingPathComponent("space 项目")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) { checks.append(["name": name, "passed": condition]) }
        var components = URLComponents()
        components.scheme = "file"; components.host = "fixture.local"; components.path = directory.path
        let uri = components.url!.absoluteString
        check("plain_existing_directory", TerminalWorkingDirectory.normalizedExistingDirectory(directory.path) == directory.path)
        check("osc7_hostname_and_percent_encoded_unicode", TerminalWorkingDirectory.normalizedExistingDirectory(uri) == directory.path)
        check("file_url_without_hostname", TerminalWorkingDirectory.normalizedExistingDirectory(directory.absoluteString) == directory.path)
        check("whitespace_trimmed", TerminalWorkingDirectory.normalizedExistingDirectory(" \n" + uri + "\n") == directory.path)
        check("missing_directory_rejected", TerminalWorkingDirectory.normalizedExistingDirectory(root.appendingPathComponent("missing").absoluteString) == nil)
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        check("regular_file_rejected", TerminalWorkingDirectory.normalizedExistingDirectory(file.absoluteString) == nil)
        check("query_rejected", TerminalWorkingDirectory.normalizedExistingDirectory(uri + "?fixture=value") == nil)
        check("fragment_rejected", TerminalWorkingDirectory.normalizedExistingDirectory(uri + "#fragment") == nil)
        components.user = "fixture-user"
        check("credential_url_rejected", TerminalWorkingDirectory.normalizedExistingDirectory(components.string) == nil)
        check("nul_path_rejected", TerminalWorkingDirectory.normalizedExistingDirectory(directory.path + "\0") == nil)
        check("empty_rejected", TerminalWorkingDirectory.normalizedExistingDirectory("  ") == nil)
        try FileManager.default.removeItem(at: root)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["generatedAt": ISO8601DateFormatter().string(from: Date()), "passed": passed,
            "scope": "生产目录规范化函数的真实文件系统探针；不是工作区或完整 UI 复验", "checks": checks]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: prefix + ".json"), options: .atomic)
        let rows = checks.map { "- \($0["name"]!): \($0["passed"]!)" }.joined(separator: "\n")
        try ("# OSC 7 directory validation\n\n" + rows + "\n").write(toFile: prefix + ".md", atomically: true, encoding: .utf8)
        print(String(decoding: json, as: UTF8.self))
        exit(passed ? 0 : 1)
    }
}
