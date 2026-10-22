import Foundation

struct TerminalToolRuntime: Codable {
    let appEpoch: UUID
    let pid: Int32
    let version: String
    let cursor: TerminalEventCursor
}

extension TerminalToolPaths {
    static var runtimeFile: URL { rootDirectory.appendingPathComponent("runtime.json") }
}
