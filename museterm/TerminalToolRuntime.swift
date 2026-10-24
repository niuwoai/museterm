import Foundation

struct TerminalToolRuntime: Codable {
    let appEpoch: UUID
    let pid: Int32
    let version: String
    let cursor: TerminalEventCursor
    var backend: TerminalToolBackendRuntime? = nil
}

struct TerminalToolBackendRuntime: Codable {
    var schemaVersion = 1
    let root: String
    let cursor: TerminalEventCursor
    var features: [String]? = nil
}

extension TerminalToolPaths {
    static var runtimeFile: URL { rootDirectory.appendingPathComponent("runtime.json") }
}
