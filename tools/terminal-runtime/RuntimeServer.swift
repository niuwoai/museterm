import Darwin
import Foundation

private final class RuntimeClient {
    let fd: Int32
    var incoming = Data()
    var outgoing = Data()
    var lastProgress = ProcessInfo.processInfo.systemUptime
    var subscription: TerminalRuntimeRequest?
    var subscriptionCursor: TerminalRuntimeOutputCursor?
    var subscriptionRunning: Bool?
    var subscriptionAgent: TerminalAgentSnapshot?
    var subscriptionControlEpoch: UUID?
    var subscriptionControlExpiresAt: Date?
    var subscriptionPublishedAt = ProcessInfo.processInfo.systemUptime
    var subscriptionAttention: [TerminalAttentionItem] = []
    var disconnected = false
    var disconnectReason: String? = nil
    var lastAction: TerminalRuntimeAction? = nil
    init(fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }
}

final class RuntimeServer {
    let socket: RuntimeSocket
    let epoch = UUID()
    let events: TerminalSessionEventStore
    let attention: TerminalAttentionStore
    let nativeBridge: RuntimeNativeBridge
    private var sessions: [UUID: RuntimeSession] = [:]
    private var clients: [Int32: RuntimeClient] = [:]
    private var retired: [(pid: Int32, deadline: TimeInterval)] = []
    private var shutdownRequested = false
    private var disconnects: [TerminalRuntimeDisconnectDiagnostic] = []
    private var replies: [UUID: TerminalRuntimeResponse] = [:]
    private var replyOrder: [UUID] = []
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private lazy var waits = TerminalWaitCoordinator(events: events, target: { [weak self] id in
        guard let session = self?.sessions[id] else { return nil }
        return TerminalWaitTargetSnapshot(agent: session.agentMonitor.snapshot, outputRevision: session.outputRevision,
                                          commands: session.commandLedger.snapshots)
    }, attention: { [weak self] in self?.attention.activeItems ?? [] }, monitoringEnabled: { true })
    private static let pollMilliseconds: Int32 = 50
    private static let maximumRememberedRequests = 1_024

    init(root: URL) throws {
        socket = try RuntimeSocket(root: root)
        events = TerminalSessionEventStore(appEpoch: epoch)
        attention = TerminalAttentionStore(events: events)
        nativeBridge = try RuntimeNativeBridge(root: root.appendingPathComponent("native-tools", isDirectory: true), events: events)
        nativeBridge.waits = waits
        nativeBridge.attentionStore = attention
    }

    func run() throws {
        while true {
            maintainProcesses()
            nativeBridge.process(sessions: sessions)
            var descriptors = [pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0)]
            descriptors += clients.values.map { pollfd(fd: $0.fd,
                events: Int16(POLLIN) | ($0.outgoing.isEmpty ? 0 : Int16(POLLOUT)), revents: 0) }
            descriptors += sessions.values.filter { $0.fd >= 0 }.map { pollfd(fd: $0.fd,
                events: Int16(POLLIN) | ($0.pendingInput.isEmpty ? 0 : Int16(POLLOUT)), revents: 0) }
            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), Self.pollMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw RuntimeFailure.unavailable
            }
            if descriptors[0].revents & Int16(POLLIN) != 0 { acceptClients() }
            for descriptor in descriptors.dropFirst() where descriptor.revents != 0 {
                if let client = clients[descriptor.fd] { handle(client, events: descriptor.revents) }
                else if let session = sessions.values.first(where: { $0.fd == descriptor.fd }) {
                    do {
                        if descriptor.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 { try session.readOutput() }
                        if descriptor.revents & Int16(POLLOUT) != 0 { try session.flushInput() }
                    } catch { session.close() }
                }
            }
            publishSubscriptions()
            expireClients()
            if shutdownRequested && sessions.isEmpty && retired.isEmpty && waits.pendingCount == 0 && waits.completions.isEmpty
                && clients.values.allSatisfy({ $0.outgoing.isEmpty }) { return }
        }
    }

    private func maintainProcesses() {
        for session in sessions.values { session.refresh() }
        retired = retired.filter { child in
            var status: Int32 = 0
            let result = museterm_pty_poll_exit(child.pid, &status)
            if result != 0 { return false }
            if ProcessInfo.processInfo.systemUptime > child.deadline { _ = kill(child.pid, SIGKILL) }
            return true
        }
    }

    private func acceptClients() {
        for _ in 0..<8 {
            guard let fd = socket.acceptClient() else { return }
            guard clients.count < TerminalRuntimeLimits.maximumClients else { Darwin.close(fd); continue }
            clients[fd] = RuntimeClient(fd: fd)
        }
    }

    private func handle(_ client: RuntimeClient, events: Int16) {
        if events & Int16(POLLERR | POLLNVAL) != 0 { disconnect(client, reason: "socket_error"); return }
        if events & Int16(POLLIN | POLLHUP) != 0 {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(client.fd, &buffer, buffer.count)
            if count > 0 {
                client.lastProgress = ProcessInfo.processInfo.systemUptime
                client.incoming.append(contentsOf: buffer.prefix(count))
                if client.incoming.count > TerminalRuntimeLimits.maximumFrameBytes { disconnect(client, reason: "request_too_large"); return }
                // Limit decoded requests per poll, including pipelined clients.
                processFrames(client)
            } else if count == 0 { disconnect(client, reason: "peer_closed") }
            else if errno != EAGAIN && errno != EINTR { disconnect(client, reason: "read_failed") }
        }
        if events & Int16(POLLOUT) != 0 && !client.outgoing.isEmpty {
            let written = client.outgoing.withUnsafeBytes { Darwin.write(client.fd, $0.baseAddress!, $0.count) }
            if written > 0 {
                client.outgoing.removeFirst(written)
                client.lastProgress = ProcessInfo.processInfo.systemUptime
            } else if written < 0 && errno != EAGAIN && errno != EINTR { disconnect(client, reason: "write_failed") }
        }
    }

    private func processFrames(_ client: RuntimeClient) {
        for _ in 0..<8 {
            guard let newline = client.incoming.firstIndex(of: 0x0A) else { return }
            let frame = client.incoming.prefix(upTo: newline)
            guard let request = try? decoder.decode(TerminalRuntimeRequest.self, from: frame) else {
                disconnect(client, reason: "invalid_frame"); return
            }
            client.incoming.removeSubrange(...newline)
            client.lastAction = request.action
            let response = perform(request)
            enqueue(response, on: client)
            if response.ok && request.action == .subscribe {
                client.subscription = request
                client.subscriptionCursor = response.cursor
                client.subscriptionRunning = response.session?.running
                client.subscriptionAgent = response.session?.agent
                client.subscriptionControlEpoch = response.session?.controlEpoch
                client.subscriptionControlExpiresAt = response.session?.controlExpiresAt
                client.subscriptionPublishedAt = ProcessInfo.processInfo.systemUptime
                client.subscriptionAttention = response.attention ?? []
            }
            if client.disconnected { return }
        }
    }

    private func enqueue(_ response: TerminalRuntimeResponse, on client: RuntimeClient) {
        do {
            let encoded = try response.encodedTransportFrame(using: encoder)
            guard encoded.count + client.outgoing.count <= TerminalRuntimeLimits.maximumClientQueueBytes else {
                disconnect(client, reason: "output_backpressure"); return
            }
            // A quiet subscription has no pending write deadline. Start that
            // deadline when bytes become queued, rather than timing out its
            // first output/heartbeat using the previous period of silence.
            if client.outgoing.isEmpty { client.lastProgress = ProcessInfo.processInfo.systemUptime }
            client.outgoing.append(encoded)
        } catch { disconnect(client, reason: "encode_failed") }
    }

    private func perform(_ request: TerminalRuntimeRequest) -> TerminalRuntimeResponse {
        var response = TerminalRuntimeResponse(serviceEpoch: epoch, id: request.id, action: request.action)
        response.features = [TerminalRuntimeLimits.restartExitedFeature, TerminalRuntimeLimits.agentToolsFeature,
                             TerminalRuntimeLimits.eventWaitFeature, TerminalRuntimeLimits.commandLifecycleFeature,
                             TerminalRuntimeLimits.terminalAttentionFeature]
        do {
            guard request.protocolVersion == TerminalRuntimeLimits.protocolVersion else {
                response.ok = false; response.error = "incompatible_protocol"; return response
            }
            if request.action == .hello { return response }
            guard socket.authorizes(request.capability) else { throw RuntimeFailure.invalidCapability }
            if let previous = replies[request.id] {
                guard previous.action == request.action else { throw RuntimeFailure.invalidRequest }
                return previous
            }
            switch request.action {
            case .diagnostics:
                response.disconnects = disconnects
                response.pendingWaits = waits.pendingCount
            case .shutdownIfEmpty:
                guard sessions.isEmpty else { throw RuntimeFailure.controlOwned }
                waits.shutdown()
                shutdownRequested = true
            case .hello: break
            case .list:
                response.sessions = sessions.values.map(\.info).sorted { $0.id.uuidString < $1.id.uuidString }
            case .listAttention:
                response.attention = attention.activeItems.filter { request.sessionID == nil || $0.tabID == request.sessionID }
            case .acknowledgeAttention:
                guard let id = request.attentionID, let version = request.attentionVersion else { throw RuntimeFailure.invalidRequest }
                try attention.markRead(id: id, version: version)
                response.attention = attention.activeItems
            case .readEvents:
                response.events = try events.read(after: request.eventAfter ?? events.cursor, limit: request.eventLimit ?? 100)
            case .create:
                guard !shutdownRequested else { throw RuntimeFailure.unavailable }
                guard sessions.count + retired.count < TerminalRuntimeLimits.maximumSessions,
                      let launch = request.launch else { throw RuntimeFailure.resourceLimit }
                let id = request.sessionID ?? UUID()
                guard sessions[id] == nil else { throw RuntimeFailure.invalidRequest }
                let session = try RuntimeSession(id: id, launch: launch, nativeRoot: nativeBridge.root, events: events, attention: attention)
                sessions[id] = session; response.session = session.info
                events.publish(tabID: id, kind: .registered, location: .mainWindow)
            default:
                guard let id = request.sessionID, let session = sessions[id] else { throw RuntimeFailure.unavailable }
                session.refresh()
                try session.validate(request)
                switch request.action {
                case .configureReminders:
                    guard let policy = request.reminderPolicy else { throw RuntimeFailure.invalidRequest }
                    try session.configureReminders(policy)
                case .bindAgent:
                    guard session.running, let kind = request.agentKind else { throw TerminalAgentReportError.unavailable }
                    response.agentGrant = try session.updateAgent { try $0.bind(kind: kind, commandID: request.commandID, now: Date()) }
                case .reportAgent:
                    guard session.running else { throw TerminalAgentReportError.unavailable }
                    guard let report = request.agentReport else { throw TerminalAgentReportError.invalidState }
                    try session.updateAgent { try $0.report(report, now: Date()) }
                case .getAgentState: break
                case .restartExited:
                    try session.validate(request, control: true)
                    guard !shutdownRequested, !session.running, session.owner == nil,
                          let launch = request.launch else { throw RuntimeFailure.invalidRequest }
                    // Construct first: a failed launch must retain the exited
                    // session and its recovery identity. Never signal a live PTY.
                    let replacement = try RuntimeSession(id: id, launch: launch, nativeRoot: nativeBridge.root, events: events, attention: attention)
                    session.close()
                    events.publish(tabID: id, kind: .closed)
                    sessions[id] = replacement
                    events.publish(tabID: id, kind: .registered, location: .mainWindow)
                    response.session = replacement.info
                case .inspectInput:
                    let echo = museterm_pty_echo(session.fd)
                    let foreground = tcgetpgrp(session.fd)
                    guard session.running, echo >= 0, foreground > 0 else { throw RuntimeFailure.unavailable }
                    response.echoEnabled = echo == 1
                    response.foregroundPID = foreground
                case .read, .subscribe: try fillOutput(&response, session: session, after: request.after)
                case .input: response.echoEnabled = try session.input(request)
                case .resize: try session.resize(request)
                case .acquireControl, .renewControl, .releaseControl: try session.updateControl(request)
                case .close:
                    try session.validate(request, control: true)
                    session.close()
                    if session.running { retired.append((session.pid, ProcessInfo.processInfo.systemUptime + 3)) }
                    sessions[id] = nil
                    events.publish(tabID: id, kind: .closed)
                default: throw RuntimeFailure.invalidRequest
                }
                if request.action != .restartExited {
                    response.session = session.info
                    if session.fd >= 0 { response.foregroundPID = tcgetpgrp(session.fd) }
                }
                if [.bindAgent, .reportAgent, .getAgentState].contains(request.action) {
                    response.attention = attention.activeItems.filter { $0.tabID == id }
                }
            }
            if [.create, .restartExited, .bindAgent, .reportAgent, .input, .resize, .close, .acquireControl, .renewControl, .releaseControl,
                .acknowledgeAttention, .configureReminders].contains(request.action) {
                replies[request.id] = response; replyOrder.append(request.id)
                if replyOrder.count > Self.maximumRememberedRequests { replies[replyOrder.removeFirst()] = nil }
            }
        } catch {
            response.ok = false
            if let error = error as? RuntimeFailure { response.error = error.rawValue }
            else if let error = error as? TerminalRuntimeOutputError {
                switch error {
                case .generationChanged: response.error = "generation_changed"
                case .futureCursor: response.error = "future_cursor"
                default: response.error = "invalid_request"
                }
            } else { response.error = "runtime_error" }
            if let error = error as? TerminalEventReadError {
                switch error {
                case .appRestarted: response.error = "app_restarted"
                case .cursorExpired: response.error = "cursor_expired"
                case .futureCursor: response.error = "future_cursor"
                }
            }
            if let error = error as? TerminalAttentionMutationError { response.error = error.rawValue }
            if let error = error as? TerminalAgentReportError { response.error = error.rawValue }
        }
        response.eventHead = events.cursor
        return response
    }

    private func fillOutput(_ response: inout TerminalRuntimeResponse, session: RuntimeSession,
                            after: TerminalRuntimeOutputCursor?) throws {
        let batch = try session.journal.read(after: after, limit: TerminalRuntimeLimits.maximumOutputBytes)
        response.data = batch.data; response.cursor = batch.cursor
        response.hasGap = batch.hasGap; response.latestOffset = batch.latestOffset
        response.attention = attention.activeItems.filter { $0.tabID == session.id }
        response.eventHead = events.cursor
        if session.fd >= 0 { response.foregroundPID = tcgetpgrp(session.fd) }
    }

    private func publishSubscriptions() {
        for client in clients.values {
            guard let request = client.subscription, let id = request.sessionID else { continue }
            var response = TerminalRuntimeResponse(serviceEpoch: epoch, id: request.id, action: .subscribe)
            guard let session = sessions[id] else {
                response.ok = false; response.error = "target_closed"
                enqueue(response, on: client); client.subscription = nil; continue
            }
            let currentAttention = attention.activeItems.filter { $0.tabID == session.id }
            guard session.journal.cursor != client.subscriptionCursor || session.running != client.subscriptionRunning
                || !TerminalAgentSnapshot.sameEvidence(session.agentMonitor.snapshot, client.subscriptionAgent)
                || session.controlEpoch != client.subscriptionControlEpoch
                || session.leaseExpiresAt != client.subscriptionControlExpiresAt
                || ProcessInfo.processInfo.systemUptime - client.subscriptionPublishedAt >= TerminalRuntimeLimits.subscriptionHeartbeat
                || currentAttention != client.subscriptionAttention else { continue }
            do {
                try fillOutput(&response, session: session, after: client.subscriptionCursor)
                response.session = session.info
                enqueue(response, on: client)
                client.subscriptionCursor = response.cursor
                client.subscriptionRunning = session.running
                client.subscriptionAgent = session.agentMonitor.snapshot
                client.subscriptionControlEpoch = session.controlEpoch
                client.subscriptionControlExpiresAt = session.leaseExpiresAt
                client.subscriptionPublishedAt = ProcessInfo.processInfo.systemUptime
                client.subscriptionAttention = response.attention ?? []
            } catch { disconnect(client, reason: "subscription_failed") }
        }
    }

    private func expireClients() {
        let now = ProcessInfo.processInfo.systemUptime
        for client in clients.values {
            if !client.incoming.isEmpty { processFrames(client) }
            let idle = now - client.lastProgress
            let writeDeadline = client.subscription == nil ? TerminalRuntimeLimits.requestDeadline : TerminalRuntimeLimits.subscriptionWriteDeadline
            if client.disconnected || (!client.outgoing.isEmpty && idle > writeDeadline)
                || (client.subscription == nil && idle > TerminalRuntimeLimits.requestDeadline) {
                let reason = client.disconnectReason ?? (client.outgoing.isEmpty ? "idle_deadline" : "write_deadline")
                if reason != "peer_closed" && reason != "idle_deadline" {
                    disconnects.append(.init(reason: reason, lastAction: client.lastAction,
                        subscribed: client.subscription != nil, queuedBytes: client.outgoing.count, idleSeconds: max(0, idle)))
                    if disconnects.count > 32 { disconnects.removeFirst(disconnects.count - 32) }
                }
                clients[client.fd] = nil
            }
        }
    }

    private func disconnect(_ client: RuntimeClient, reason: String) {
        client.disconnected = true
        if client.disconnectReason == nil { client.disconnectReason = reason }
    }
}

@main
struct TerminalRuntimeMain {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--root" else {
                throw RuntimeFailure.invalidRequest
            }
            umask(0o077)
            _ = setsid()
            let server = try RuntimeServer(root: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            try server.run()
        } catch {
            // No launch arguments, terminal output, capabilities or host paths.
            fputs("MuseTerm Runtime could not start or continue.\n", stderr)
            exit(1)
        }
    }
}
