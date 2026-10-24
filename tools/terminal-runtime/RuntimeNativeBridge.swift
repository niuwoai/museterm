import Darwin
import Foundation

private struct RuntimeNativeRequest: Decodable {
    let id: String
    let action: String
    let tab: String?
    let nativeAgentToken: String?
    let agentKind: TerminalAgentKind?
    let agentReport: TerminalAgentReport?
    let eventCursor: TerminalEventCursor?
    let eventLimit: Int?
    let waitSpec: TerminalWaitSpec?
    let controlID: String?
    let waitID: String?
    let noResponse: Bool?
}

private struct RuntimeNativeResponse: Encodable {
    let id: String
    let action: String
    let version = AppVersion.value
    let schemaVersion = 1
    let appName = "QTerm"
    var snapshotSequence: UInt64
    var ok = true
    var agentGrant: TerminalAgentGrant?
    var agent: TerminalAgentSnapshot?
    var error: String?
    var eventBatch: TerminalEventBatch?
    var waitResult: TerminalWaitResult?
    var attention: [TerminalAttentionItem]?
}

private struct RuntimeReadOnlyMetadata: Encodable {
    let schemaVersion = 1
    let appEpoch: UUID
    let pid = ProcessInfo.processInfo.processIdentifier
    let version = AppVersion.value
    let cursor: TerminalEventCursor
}

/// This file endpoint has only status methods. Neither the bootstrap nor the
/// returned Agent grant is accepted by the UI/input Unix socket endpoint.
final class RuntimeNativeBridge {
    let root: URL
    private let requests: URL
    private let responses: URL
    private let events: TerminalSessionEventStore
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var responseOrder: [URL] = []
    var waits: TerminalWaitCoordinator?
    var attentionStore: TerminalAttentionStore?

    init(root: URL, events: TerminalSessionEventStore) throws {
        self.root = root; self.events = events
        requests = root.appendingPathComponent("requests", isDirectory: true)
        responses = root.appendingPathComponent("responses", isDirectory: true)
        for directory in [root, requests, responses] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            var stat = Darwin.stat()
            guard lstat(directory.path, &stat) == 0, stat.st_uid == getuid(),
                  stat.st_mode & S_IFMT == S_IFDIR, stat.st_mode & 0o077 == 0 else {
                throw RuntimeFailure.invalidCapability
            }
        }
        // A new service epoch owns no old requests or responses. Bound startup
        // cleanup too: an unexpected directory flood fails closed.
        for directory in [requests, responses] {
            var visited = 0
            visit(directory, limit: 1_025) { url in visited += 1; unlink(url.path) }
            guard visited <= 1_024 else { throw RuntimeFailure.resourceLimit }
        }
        let metadata = RuntimeReadOnlyMetadata(appEpoch: events.appEpoch, cursor: events.cursor)
        try writeFile(encoder.encode(metadata), to: root.appendingPathComponent("runtime.json"))
    }

    func process(sessions: [UUID: RuntimeSession]) {
        visit(requests, limit: 16) { url in
            do {
                let data = try readPrivate(url)
                guard let request = try? decoder.decode(RuntimeNativeRequest.self, from: data),
                      UUID(uuidString: request.id) != nil, url.lastPathComponent == request.id + ".json" else {
                    unlink(url.path); return
                }
                unlink(url.path)
                if let response = perform(request, sessions: sessions), request.noResponse != true {
                    try writePrivate(encoder.encode(response), name: request.id)
                }
            } catch {
                // The private endpoint fails closed. No request body or token is logged.
                unlink(url.path)
            }
        }
        waits?.expire()
        for result in waits?.drainCompletions() ?? [] {
            var response = RuntimeNativeResponse(id: result.waitID, action: "wait_session", snapshotSequence: events.sequence)
            response.waitResult = result
            do { try writePrivate(encoder.encode(response), name: result.waitID) }
            catch { NSLog("QTerm runtime could not publish a bounded wait result") }
        }
        visit(responses, limit: 32) { url in
            var stat = Darwin.stat()
            if lstat(url.path, &stat) == 0 && Date().timeIntervalSince1970 - Double(stat.st_mtimespec.tv_sec) > 300 {
                unlink(url.path)
            }
        }
    }

    private func perform(_ request: RuntimeNativeRequest, sessions: [UUID: RuntimeSession]) -> RuntimeNativeResponse? {
        var response = RuntimeNativeResponse(id: request.id, action: request.action, snapshotSequence: events.sequence)
        do {
            switch request.action {
            case "list_attention":
                guard let attentionStore else { throw TerminalAgentReportError.unavailable }
                if let tab = request.tab {
                    guard let id = UUID(uuidString: tab), sessions[id] != nil else { throw TerminalAgentReportError.unavailable }
                    response.attention = attentionStore.activeItems.filter { $0.tabID == id }
                } else { response.attention = attentionStore.activeItems }
                return response
            case "get_agent_state":
                guard let tab = request.tab, let id = UUID(uuidString: tab), let session = sessions[id] else {
                    throw TerminalAgentReportError.unavailable
                }
                response.agent = session.agentMonitor.snapshot
                return response
            case "read_session_events":
                response.eventBatch = try events.read(after: request.eventCursor ?? events.cursor, limit: request.eventLimit ?? 100)
                return response
            case "wait_session":
                guard let waits, let owner = request.controlID, let spec = request.waitSpec else { throw TerminalWaitError.invalidSpec }
                try waits.begin(id: request.id, owner: owner, spec: spec)
                return nil
            case "cancel_wait", "cancel_all_waits":
                guard let waits, let owner = request.controlID, UUID(uuidString: owner) != nil else { throw TerminalWaitError.invalidSpec }
                if request.action == "cancel_all_waits" { waits.cancelAll(owner: owner) }
                else if let id = request.waitID { _ = waits.cancel(id: id, owner: owner) }
                else { throw TerminalWaitError.invalidSpec }
                return response
            default: break
            }
            guard let tab = request.tab, let id = UUID(uuidString: tab), let session = sessions[id], session.running else {
                throw TerminalAgentReportError.unavailable
            }
            switch request.action {
            case "bind_native_agent":
                guard request.agentKind == .willdeep, session.nativeAgentContext.authorizes(request.nativeAgentToken) else {
                    throw TerminalAgentReportError.invalidCapability
                }
                response.agentGrant = try session.updateAgent { try $0.bind(kind: .willdeep, now: Date()) }
            case "report_agent_state":
                guard let report = request.agentReport else { throw TerminalAgentReportError.invalidState }
                try session.updateAgent { try $0.report(report, now: Date()) }
            default: throw TerminalAgentReportError.invalidCapability
            }
            response.agent = session.agentMonitor.snapshot
            response.snapshotSequence = events.sequence
        } catch {
            response.ok = false
            response.error = (error as? TerminalAgentReportError)?.rawValue ?? "invalid_request"
            if let error = error as? TerminalWaitError { response.error = error.rawValue }
            if let error = error as? TerminalEventReadError {
                response.error = error == .appRestarted ? "app_restarted" : error == .cursorExpired ? "cursor_expired" : "future_cursor"
            }
        }
        return response
    }

    private func visit(_ directory: URL, limit: Int, body: (URL) -> Void) {
        guard let listing = opendir(directory.path) else { return }
        defer { closedir(listing) }
        var examined = 0
        while examined < limit, let entry = readdir(listing) {
            examined += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".json"), !name.contains("/") else { continue }
            body(directory.appendingPathComponent(name))
        }
    }

    private func readPrivate(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw RuntimeFailure.invalidRequest }
        let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? reader.close() }
        var stat = Darwin.stat()
        guard fstat(fd, &stat) == 0, stat.st_uid == getuid(), stat.st_mode & S_IFMT == S_IFREG,
              stat.st_mode & 0o077 == 0, stat.st_size <= TerminalRuntimeLimits.maximumFrameBytes else {
            throw RuntimeFailure.invalidCapability
        }
        let data = try reader.read(upToCount: TerminalRuntimeLimits.maximumFrameBytes + 1) ?? Data()
        guard data.count <= TerminalRuntimeLimits.maximumFrameBytes else { throw RuntimeFailure.resourceLimit }
        return data
    }

    private func writePrivate(_ data: Data, name: String) throws {
        let target = responses.appendingPathComponent(name + ".json")
        try writeFile(data, to: target)
        responseOrder.append(target)
        if responseOrder.count > 256 { unlink(responseOrder.removeFirst().path) }
    }

    private func writeFile(_ data: Data, to target: URL) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pending")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimeFailure.unavailable }
        let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try writer.write(contentsOf: data); try writer.close()
            guard rename(temporary.path, target.path) == 0 else {
                throw RuntimeFailure.unavailable
            }
        } catch { try? writer.close(); unlink(temporary.path); throw error }
    }
}
