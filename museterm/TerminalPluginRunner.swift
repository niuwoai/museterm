import Foundation

/// One short-lived Node process for one declared export. Stdout is newline-delimited JSON-RPC 2.0.
/// Stderr is discarded as a log and never parsed as a result.
enum TerminalPluginRunner {
    static let protocolVersion = 1
    static let commandTimeout: TimeInterval = 5
    static let suggestionTimeout: TimeInterval = 2
    static let recordingTimeout: TimeInterval = 1
    private static let responseLimit = 64 * 1024

    enum Call: Equatable {
        case command(plugin: TerminalPlugin, exportName: String, commandID: String, tab: TerminalPluginTabContext)
        case suggest(plugin: TerminalPlugin, request: String, context: TerminalPluginTabContext)
        case recording(plugin: TerminalPlugin, event: TerminalPluginRecordingEvent)

        var plugin: TerminalPlugin {
            switch self {
            case .command(let plugin, _, _, _), .suggest(let plugin, _, _), .recording(let plugin, _): return plugin
            }
        }

        var timeout: TimeInterval {
            switch self {
            case .command: return TerminalPluginRunner.commandTimeout
            case .suggest: return TerminalPluginRunner.suggestionTimeout
            case .recording: return TerminalPluginRunner.recordingTimeout
            }
        }

        var method: String {
            switch self {
            case .command: return "command"
            case .suggest: return "suggest"
            case .recording: return "recording"
            }
        }
    }

    static func run(_ call: Call, nodeExecutable: URL, sandbox: Bool = true) throws -> TerminalPluginResult {
        let plugin = call.plugin
        guard plugin.enabled else { throw TerminalPluginError.disabled(plugin.displayName) }
        guard FileManager.default.isExecutableFile(atPath: nodeExecutable.path) else {
            throw TerminalPluginError.failed(L10n.string("plugin.error.node"))
        }
        guard FileManager.default.fileExists(atPath: plugin.entryURL.path) else {
            throw TerminalPluginError.missingExport(plugin.entry)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let profile = temporary.appendingPathComponent("plugin.sb")
        if sandbox {
            let paths = TerminalPluginSandbox.paths(pluginDirectory: plugin.directory, temporaryDirectory: temporary)
            try TerminalPluginSandbox.profile(for: paths).write(to: profile, atomically: true, encoding: .utf8)
        }

        let process = Process()
        process.executableURL = sandbox ? URL(fileURLWithPath: "/usr/bin/sandbox-exec") : nodeExecutable
        process.arguments = sandbox
            ? ["-f", profile.path, nodeExecutable.path, "--input-type=module", "-e", bootstrap]
            : ["--input-type=module", "-e", bootstrap]
        process.currentDirectoryURL = plugin.directory
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": temporary.path,
            "TMPDIR": temporary.path,
            "MUSETERM_PLUGIN_ENTRY": plugin.entryURL.path,
        ]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let received = LockedData()
        let reader = output.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { received.append(chunk) }
        }
        try process.run()

        let request = try JSONSerialization.data(withJSONObject: requestObject(call))
        input.fileHandleForWriting.write(request)
        input.fileHandleForWriting.write(Data([0x0A]))
        try input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(call.timeout)
        while !received.containsNewline, received.count < responseLimit, Date() < deadline, process.isRunning {
            Thread.sleep(forTimeInterval: 0.02)
        }
        reader.readabilityHandler = nil
        if !received.containsNewline, process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw TerminalPluginError.timedOut
        }
        if process.isRunning { process.waitUntilExit() }
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        let line = received.prefix(upToNewline: responseLimit)
        guard !line.isEmpty else {
            throw TerminalPluginError.invalidResponse(L10n.string("plugin.error.empty_response"))
        }
        return try decode(line, expected: call)
    }

    static func requestObject(_ call: Call) throws -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": 1,
            "method": call.method,
            "params": try params(call),
        ]
    }

    static func decode(_ line: Data, expected: Call) throws -> TerminalPluginResult {
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw TerminalPluginError.invalidResponse(L10n.string("plugin.error.empty_response"))
        }
        if object["error"] != nil {
            throw TerminalPluginError.failed(L10n.string("plugin.error.export_rejected"))
        }
        guard let result = object["result"] as? [String: Any] else {
            throw TerminalPluginError.invalidResponse(L10n.string("plugin.error.empty_response"))
        }
        switch expected {
        case .command:
            return try commandResult(result, plugin: expected.plugin)
        case .suggest:
            return .suggestions(suggestions(result))
        case .recording:
            return .message(title: "", body: nil)
        }
    }

    private static func params(_ call: Call) throws -> [String: Any] {
        switch call {
        case let .command(_, exportName, commandID, tab):
            return [
                "protocol": protocolVersion,
                "export": exportName,
                "commandID": commandID,
                "preferences": preferenceValues(call.plugin),
                "tab": [
                    "id": tab.id,
                    "targetKind": tab.targetKind,
                    "environment": tab.environment,
                ],
            ]
        case let .suggest(_, request, context):
            return [
                "protocol": protocolVersion,
                "export": call.plugin.suggestExport ?? "",
                "request": request,
                "context": [
                    "targetKind": context.targetKind,
                    "targetName": context.targetName,
                    "user": context.user as Any,
                    "host": context.host as Any,
                    "workingDirectory": context.workingDirectory as Any,
                    "shell": context.shell as Any,
                    "environment": context.environment,
                ],
            ]
        case let .recording(_, event):
            return [
                "protocol": protocolVersion,
                "export": call.plugin.recordingExport ?? "",
                "event": [
                    "type": "capture.finished",
                    "shortcut": [
                        "id": event.id,
                        "title": event.title,
                        "eventCount": event.eventCount,
                        "durationMilliseconds": event.durationMilliseconds,
                        "hasProtectedInput": event.hasProtectedInput,
                        "requiresUserAuthentication": event.requiresUserAuthentication,
                        "allowsAutomationPlayback": event.allowsAutomationPlayback,
                    ],
                ],
            ]
        }
    }

    private static func commandResult(_ result: [String: Any], plugin: TerminalPlugin) throws -> TerminalPluginResult {
        switch result["type"] as? String {
        case "message":
            let title = trimmed(result["title"], limit: 200)
            guard !title.isEmpty else {
                throw TerminalPluginError.invalidResponse(L10n.string("plugin.error.empty_response"))
            }
            let body = optionalTrimmed(result["body"], limit: 2000)
            return .message(title: title, body: body)
        case "fill":
            guard plugin.permissions.contains("terminal.fill") else {
                throw TerminalPluginError.missingPermission("terminal.fill")
            }
            let command = singleLine(result["command"])
            guard !command.isEmpty else {
                throw TerminalPluginError.invalidResponse(L10n.string("plugin.error.empty_response"))
            }
            return .fill(command: command)
        default:
            throw TerminalPluginError.invalidResponse(L10n.string("plugin.error.empty_response"))
        }
    }

    private static func suggestions(_ result: [String: Any]) -> [(command: String, explanation: String)] {
        let candidates = result["candidates"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let command = singleLine(candidate["command"])
            guard !command.isEmpty, seen.insert(command).inserted else { return nil }
            let explanation = trimmed(candidate["explanation"], limit: 600)
            return (command, explanation)
        }.prefix(2).map { $0 }
    }

    static func preferenceValues(_ plugin: TerminalPlugin) -> [String: Any] {
        let stored = UserDefaults.standard.dictionary(forKey: "plugin.preferences.\(plugin.id)") ?? [:]
        var values: [String: Any] = [:]
        for preference in plugin.preferences {
            switch preference.kind {
            case .boolean:
                values[preference.name] = stored[preference.name] as? Bool ?? false
            case .text, .dropdown:
                values[preference.name] = stored[preference.name] as? String ?? ""
            }
        }
        return values
    }

    private static func singleLine(_ value: Any?) -> String {
        let text = trimmed(value, limit: 4000)
        guard !text.contains("\n"), !text.contains("\r") else { return "" }
        return text
    }

    private static func optionalTrimmed(_ value: Any?, limit: Int) -> String? {
        let text = trimmed(value, limit: limit)
        return text.isEmpty ? nil : text
    }

    private static func trimmed(_ value: Any?, limit: Int) -> String {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(text.prefix(limit))
    }

    /// Bytes arriving on the readability callback. `Pipe.availableData` would block until the process exits,
    /// so the timeout has to be checked against data that was already copied off the pipe.
    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return data.count
        }

        var containsNewline: Bool {
            lock.lock(); defer { lock.unlock() }
            return data.contains(0x0A)
        }

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        func prefix(upToNewline limit: Int) -> Data {
            lock.lock(); defer { lock.unlock() }
            let bounded = data.prefix(limit)
            guard let newline = bounded.firstIndex(of: 0x0A) else { return Data() }
            return Data(bounded[..<newline])
        }
    }

    /// Loads the declared entry and answers one request. Unknown methods are rejected.
    static let bootstrap = """
    const entry = process.env.MUSETERM_PLUGIN_ENTRY
    const input = await new Promise((resolve) => {
      let data = ""
      process.stdin.setEncoding("utf8")
      process.stdin.on("data", (chunk) => { data += chunk })
      process.stdin.on("end", () => resolve(data))
    })
    const line = input.split("\\n").find((item) => item.trim().length > 0) ?? ""
    const reply = (payload) => {
      process.stdout.write(JSON.stringify(payload) + "\\n")
    }
    let request
    try { request = JSON.parse(line) } catch { reply({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse" } }); process.exit(0) }
    try {
      const loaded = await import(entry)
      const params = request.params ?? {}
      const exported = loaded[params.export]
      if (typeof exported !== "function") throw new Error("missing")
      if (request.method === "command") {
        reply({ jsonrpc: "2.0", id: request.id, result: await exported({ commandID: params.commandID, preferences: params.preferences ?? {}, tab: params.tab }) })
      } else if (request.method === "suggest") {
        reply({ jsonrpc: "2.0", id: request.id, result: await exported({ request: params.request, context: params.context }) })
      } else if (request.method === "recording") {
        await exported(params.event)
        reply({ jsonrpc: "2.0", id: request.id, result: { type: "message", title: "ok" } })
      } else {
        reply({ jsonrpc: "2.0", id: request.id, error: { code: -32601, message: "method" } })
      }
    } catch {
      reply({ jsonrpc: "2.0", id: request?.id ?? null, error: { code: -32000, message: "failed" } })
    }
    """
}
