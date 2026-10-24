import Foundation

enum TerminalRuntimePresentationIssue: String { case connecting, disconnected, outputGap, inputRejected, inputTooLarge }

nonisolated struct TerminalRuntimeInputPreparation {
    let session: TerminalRuntimeSessionInfo
    let echoEnabled: Bool
    let foregroundPID: Int32
}

/// Main-thread projection. The service owns process lifetime and authoritative
/// state; destroying this object only detaches the viewer.
@MainActor
final class TerminalRuntimeSessionHandle {
    static let acknowledgementPendingCode = "attention_acknowledgement_pending"
    private let io: TerminalRuntimeSessionIO
    private(set) var info: TerminalRuntimeSessionInfo?
    private(set) var connected = false
    private(set) var lastError: TerminalRuntimeConnectionError?
    private(set) var lastErrorStage: String?
    private(set) var createdNewPTY = false
    private(set) var renderedCursor: TerminalRuntimeOutputCursor?
    private(set) var features: [String] = []
    private(set) var eventCursor: TerminalEventCursor?
    var agentReportRoot: URL { io.root.appendingPathComponent("native-tools", isDirectory: true) }
    var backendEventSource: TerminalToolBackendRuntime? {
        guard features.contains(TerminalRuntimeLimits.eventWaitFeature), let eventCursor else { return nil }
        return .init(root: agentReportRoot.path, cursor: eventCursor, features: features)
    }
    var onState: ((TerminalRuntimeSessionInfo) -> Void)?
    var onOutput: ((TerminalRuntimeResponse, Int, @escaping () -> Void) -> Void)?
    var onRenderedOutput: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private var pendingReminderPolicy: TerminalReminderPolicy?
    private var pendingAcknowledgements: Set<UUID> = []

    init(id: UUID, root: URL = TerminalRuntimeService.rootDirectory,
         executable: URL = TerminalRuntimeService.executableURL) {
        io = TerminalRuntimeSessionIO(id: id, root: root, executable: executable)
        io.onStarted = { [weak self] info, created, features in
            DispatchQueue.main.async {
                self?.createdNewPTY = created
                self?.features = features
                self?.accept(info)
            }
        }
        io.onState = { [weak self] info in
            DispatchQueue.main.async {
                self?.accept(info)
            }
        }
        io.onOutput = { [weak self] response, historicalBytes, completion in
            DispatchQueue.main.async {
                guard let self else { completion(); return }
                self.eventCursor = response.eventHead
                if let info = response.session { self.accept(info, receivedOutput: true) }
                let rendered = { [weak self] in
                    if let self, let cursor = response.cursor, self.renderedCursor != cursor {
                        self.renderedCursor = cursor
                        self.onRenderedOutput?()
                    }
                    completion()
                }
                if let onOutput = self.onOutput { onOutput(response, historicalBytes, rendered) } else { completion() }
            }
        }
        io.onFailure = { [weak self] error, stage in
            DispatchQueue.main.async {
                self?.connected = false
                self?.lastError = (error as? TerminalRuntimeConnectionError) ?? .unavailable
                self?.lastErrorStage = stage
                self?.onFailure?(error)
            }
        }
    }

    private func accept(_ info: TerminalRuntimeSessionInfo, receivedOutput: Bool = false) {
        guard self.info == nil || (self.info?.generation == info.generation && self.info!.revision <= info.revision) else { return }
        self.info = info
        if receivedOutput { connected = true; lastError = nil; lastErrorStage = nil }
        onState?(info)
    }

    func start(_ launch: TerminalRuntimeLaunch, restoring generation: UUID? = nil, existingOnly: Bool = false,
               renderedCursor: TerminalRuntimeOutputCursor? = nil, restarting previous: TerminalRuntimeSessionInfo? = nil) {
        io.start(launch, restoring: generation, existingOnly: existingOnly, renderedCursor: renderedCursor, restarting: previous)
    }

    @discardableResult
    func send(_ data: Data, source: TerminalRuntimeInputSource, owner: String? = nil,
              completion: ((Result<TerminalRuntimeResponse, Error>) -> Void)? = nil) -> Bool {
        guard connected, let info, info.running else { return false }
        return io.input(data, expected: info, source: source, owner: owner) { result in
            DispatchQueue.main.async { completion?(result) }
        }
    }

    func resize(columns: Int, rows: Int) {
        guard let info else { return }
        io.perform(.resize, expected: info, columns: columns, rows: rows)
    }

    func prepareInput(completion: @escaping (Result<TerminalRuntimeInputPreparation, Error>) -> Void) {
        guard connected, let info, info.running else { completion(.failure(TerminalRuntimeConnectionError.unavailable)); return }
        io.perform(.inspectInput, expected: info) { result in
            DispatchQueue.main.async {
                completion(result.flatMap { response in
                    guard let session = response.session, let echo = response.echoEnabled,
                          let pid = response.foregroundPID, pid > 0 else { return .failure(TerminalRuntimeConnectionError.invalidResponse) }
                    return .success(.init(session: session, echoEnabled: echo, foregroundPID: pid))
                })
            }
        }
    }

    @discardableResult
    func sendPrepared(_ data: Data, preparation: TerminalRuntimeInputPreparation, source: TerminalRuntimeInputSource,
                      owner: String?, completion: @escaping (Result<TerminalRuntimeResponse, Error>) -> Void) -> Bool {
        guard connected, let info, info.running, info.generation == preparation.session.generation,
              info.controlEpoch == preparation.session.controlEpoch else { return false }
        return io.input(data, expected: preparation.session, source: source, owner: owner,
            expectedEcho: preparation.echoEnabled, expectedForeground: preparation.foregroundPID) { result in
                DispatchQueue.main.async { completion(result) }
            }
    }

    func control(_ action: TerminalRuntimeAction, owner: String?,
                 completion: @escaping (Result<TerminalRuntimeResponse, Error>) -> Void) {
        guard let info else { completion(.failure(TerminalRuntimeConnectionError.unavailable)); return }
        io.perform(action, expected: info, owner: owner) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let response) = result, let info = response.session { self?.accept(info) }
                completion(result)
            }
        }
    }

    func reconnect() { io.restartReader() }
    func configureReminders(_ policy: TerminalReminderPolicy) {
        guard features.contains(TerminalRuntimeLimits.terminalAttentionFeature), let info,
              info.reminderPolicy != policy, pendingReminderPolicy != policy else { return }
        pendingReminderPolicy = policy
        io.perform(.configureReminders, expected: info, reminderPolicy: policy) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.pendingReminderPolicy == policy { self.pendingReminderPolicy = nil }
                if case .failure = result { self.onFailure?(TerminalRuntimeConnectionError.rejected("reminder_policy_unavailable")) }
            }
        }
    }
    func agentOperation(_ action: TerminalRuntimeAction, kind: TerminalAgentKind? = nil,
                        report: TerminalAgentReport? = nil, commandID: UUID? = nil,
                        completion: @escaping (Result<TerminalRuntimeResponse, Error>) -> Void) {
        guard let info else { completion(.failure(TerminalRuntimeConnectionError.unavailable)); return }
        io.perform(action, expected: info, agentKind: kind, agentReport: report, commandID: commandID) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let response) = result, let info = response.session { self?.accept(info) }
                completion(result)
            }
        }
    }
    func acknowledge(id: UUID, version: Int, completion: @escaping (Result<TerminalRuntimeResponse, Error>) -> Void) {
        guard let info else { completion(.failure(TerminalRuntimeConnectionError.unavailable)); return }
        guard pendingAcknowledgements.insert(id).inserted else {
            completion(.failure(TerminalRuntimeConnectionError.rejected(Self.acknowledgementPendingCode)))
            return
        }
        io.perform(.acknowledgeAttention, expected: info, attentionID: id, attentionVersion: version) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion(.failure(TerminalRuntimeConnectionError.unavailable))
                    return
                }
                if case .failure(TerminalRuntimeConnectionError.rejected(let code)) = result,
                   [TerminalAttentionMutationError.staleVersion.rawValue, TerminalAttentionMutationError.notFound.rawValue].contains(code) {
                    self.io.perform(.listAttention, expected: info) { [weak self] refreshed in
                        DispatchQueue.main.async {
                            self?.pendingAcknowledgements.remove(id)
                            completion(refreshed)
                        }
                    }
                } else {
                    self.pendingAcknowledgements.remove(id)
                    completion(result)
                }
            }
        }
    }
    func closeTerminal() { io.stop(closeTerminal: true) }
    func detach() { io.stop(closeTerminal: false) }
    deinit { io.stop(closeTerminal: false) }
}

// Command and reader state have separate serial owners; cross-executor lifetime
// flags and connection cancellation are protected by lock. Callbacks are frozen
// by the projection before start() publishes the object to either executor.
nonisolated private final class TerminalRuntimeSessionIO: @unchecked Sendable {
    let id: UUID
    let root: URL
    let executable: URL
    private let commands = DispatchQueue(label: "im.some.qterm.runtime.commands")
    private let reader = DispatchQueue(label: "im.some.qterm.runtime.output")
    private let lock = NSLock()
    private var stopped = false
    private var closeRequested = false
    private var readerActive = false
    private var pendingInputBytes = 0
    private var readerConnection: TerminalRuntimeConnection?
    private var expectedEpoch: UUID?
    private var initialInfo: TerminalRuntimeSessionInfo?
    private var outputCursor: TerminalRuntimeOutputCursor?
    private var historicalBoundary: TerminalRuntimeOutputCursor?
    var onState: ((TerminalRuntimeSessionInfo) -> Void)?
    var onStarted: ((TerminalRuntimeSessionInfo, Bool, [String]) -> Void)?
    var onOutput: ((TerminalRuntimeResponse, Int, @escaping () -> Void) -> Void)?
    var onFailure: ((Error, String) -> Void)?

    init(id: UUID, root: URL, executable: URL) { self.id = id; self.root = root; self.executable = executable }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func start(_ launch: TerminalRuntimeLaunch, restoring generation: UUID?, existingOnly: Bool,
               renderedCursor: TerminalRuntimeOutputCursor?, restarting previous: TerminalRuntimeSessionInfo?) {
        commands.async { [self] in
            guard !isStopped else { return }
            do {
                if generation == nil && !existingOnly && previous == nil { try TerminalRuntimeService.ensureRunning(root: root, executable: executable) }
                let connection = try TerminalRuntimeConnection(root: root)
                defer { connection.close() }
                let listed = try connection.request(.init(action: .list))
                let existing = listed.sessions?.first { $0.id == id }
                let info: TerminalRuntimeSessionInfo
                if let previous {
                    guard listed.features?.contains(TerminalRuntimeLimits.restartExitedFeature) == true else {
                        throw TerminalRuntimeConnectionError.incompatibleProtocol
                    }
                    guard previous.id == id, !previous.running, let existing,
                          existing.generation == previous.generation else { throw TerminalRuntimeConnectionError.serviceChanged }
                    var request = TerminalRuntimeRequest(action: .restartExited)
                    request.sessionID = id; request.generation = previous.generation
                    request.controlEpoch = previous.controlEpoch; request.launch = launch
                    guard let restarted = try connection.request(request).session else { throw TerminalRuntimeConnectionError.invalidResponse }
                    info = restarted
                } else if let existing {
                    guard generation == nil || generation == existing.generation else { throw TerminalRuntimeConnectionError.serviceChanged }
                    info = existing
                } else {
                    guard generation == nil && !existingOnly else { throw TerminalRuntimeConnectionError.serviceChanged }
                    var request = TerminalRuntimeRequest(action: .create)
                    request.sessionID = id; request.launch = launch
                    guard let created = try connection.request(request).session else { throw TerminalRuntimeConnectionError.invalidResponse }
                    info = created
                }
                if let renderedCursor {
                    guard renderedCursor.generation == info.generation, renderedCursor.offset <= info.outputOffset else {
                        throw TerminalRuntimeConnectionError.serviceChanged
                    }
                }
                lock.lock(); expectedEpoch = listed.serviceEpoch; initialInfo = info; historicalBoundary = renderedCursor; lock.unlock()
                if isStopped {
                    lock.lock(); let close = closeRequested; lock.unlock()
                    if close {
                        var request = TerminalRuntimeRequest(action: .close)
                        request.sessionID = id; request.generation = info.generation; request.controlEpoch = info.controlEpoch
                        _ = try connection.request(request)
                    }
                    return
                }
                onStarted?(info, existing == nil || previous != nil, listed.features ?? [])
                restartReader()
            } catch { if !isStopped { onFailure?(error, "startup") } }
        }
    }

    func restartReader() {
        lock.lock()
        guard !stopped, !readerActive, let initialInfo, let expectedEpoch else { lock.unlock(); return }
        readerActive = true
        lock.unlock()
        reader.async { [self] in
            defer { lock.lock(); readerActive = false; readerConnection = nil; lock.unlock() }
            do {
                let connection = try TerminalRuntimeConnection(root: root)
                defer { connection.close() }
                lock.lock(); readerConnection = connection; let cancelled = stopped; lock.unlock()
                if cancelled { connection.cancel(); return }
                var request = TerminalRuntimeRequest(action: .subscribe)
                request.sessionID = id; request.generation = initialInfo.generation; request.after = outputCursor
                var response = try connection.request(request)
                while !isStopped {
                    guard response.serviceEpoch == expectedEpoch, response.session?.generation == initialInfo.generation else {
                        throw TerminalRuntimeConnectionError.serviceChanged
                    }
                    let consumed = DispatchSemaphore(value: 0)
                    let historicalBytes = try TerminalRuntimeReplayBoundary.historicalBytes(
                        in: response, renderedThrough: historicalBoundary)
                    onOutput?(response, historicalBytes, { consumed.signal() })
                    let deadline = ProcessInfo.processInfo.systemUptime + TerminalRuntimeLimits.consumerAcknowledgementDeadline
                    while consumed.wait(timeout: .now() + 0.1) == .timedOut {
                        if isStopped { return }
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw TerminalRuntimeConnectionError.timedOut }
                    }
                    outputCursor = response.cursor
                    if isStopped { return }
                    response = try connection.next(id: request.id, timeout: 60)
                }
            } catch { if !isStopped { onFailure?(error, "subscription") } }
        }
    }

    private func current(_ connection: TerminalRuntimeConnection, expected: TerminalRuntimeSessionInfo,
                         requiring feature: String? = nil) throws -> TerminalRuntimeSessionInfo {
        let response = try connection.request(.init(action: .list))
        if let feature, response.features?.contains(feature) != true {
            throw TerminalRuntimeConnectionError.rejected("unsupported_feature")
        }
        lock.lock(); let epoch = expectedEpoch; lock.unlock()
        guard response.serviceEpoch == epoch,
              let current = response.sessions?.first(where: { $0.id == id }), current.generation == expected.generation else {
            throw TerminalRuntimeConnectionError.serviceChanged
        }
        return current
    }

    func input(_ data: Data, expected: TerminalRuntimeSessionInfo, source: TerminalRuntimeInputSource, owner: String?,
               expectedEcho: Bool? = nil, expectedForeground: Int32? = nil,
               completion: @escaping (Result<TerminalRuntimeResponse, Error>) -> Void) -> Bool {
        lock.lock()
        guard !stopped, !data.isEmpty, data.count <= TerminalRuntimeLimits.maximumOutputBytes,
              data.count + pendingInputBytes <= TerminalRuntimeLimits.maximumFrameBytes else { lock.unlock(); return false }
        pendingInputBytes += data.count
        lock.unlock()
        commands.async { [self] in
            defer { lock.lock(); pendingInputBytes -= data.count; lock.unlock() }
            guard !isStopped else { completion(.failure(TerminalRuntimeConnectionError.cancelled)); return }
            do {
                let connection = try TerminalRuntimeConnection(root: root)
                defer { connection.close() }
                let info = try current(connection, expected: expected)
                if source != .protocolReply && expected.controlEpoch != info.controlEpoch { throw TerminalRuntimeConnectionError.rejected("control_changed") }
                var request = TerminalRuntimeRequest(action: .input)
                request.sessionID = id; request.generation = info.generation; request.controlEpoch = info.controlEpoch
                request.inputSequence = info.nextInputSequence; request.data = data; request.source = source; request.owner = owner
                request.expectedEchoEnabled = expectedEcho; request.expectedForegroundPID = expectedForeground
                let response = try connection.request(request)
                if let info = response.session { onState?(info) }
                completion(.success(response))
            } catch {
                completion(.failure(error))
                if case TerminalRuntimeConnectionError.rejected = error { return }
                if !isStopped { onFailure?(error, "input") }
            }
        }
        return true
    }

    func perform(_ action: TerminalRuntimeAction, expected: TerminalRuntimeSessionInfo, owner: String? = nil,
                 columns: Int? = nil, rows: Int? = nil,
                 attentionID: UUID? = nil, attentionVersion: Int? = nil,
                 agentKind: TerminalAgentKind? = nil, agentReport: TerminalAgentReport? = nil, commandID: UUID? = nil,
                 reminderPolicy: TerminalReminderPolicy? = nil,
                 completion: ((Result<TerminalRuntimeResponse, Error>) -> Void)? = nil) {
        commands.async { [self] in
            guard !isStopped else { completion?(.failure(TerminalRuntimeConnectionError.cancelled)); return }
            do {
                let connection = try TerminalRuntimeConnection(root: root)
                defer { connection.close() }
                let feature = action == .configureReminders ? TerminalRuntimeLimits.terminalAttentionFeature
                    : [.bindAgent, .reportAgent, .getAgentState].contains(action) ? TerminalRuntimeLimits.agentToolsFeature : nil
                let info = try current(connection, expected: expected, requiring: feature)
                if [.acquireControl, .renewControl, .releaseControl].contains(action), info.controlEpoch != expected.controlEpoch {
                    throw TerminalRuntimeConnectionError.rejected("control_changed")
                }
                var request = TerminalRuntimeRequest(action: action)
                request.sessionID = id; request.generation = info.generation; request.controlEpoch = info.controlEpoch
                request.owner = owner; request.columns = columns; request.rows = rows
                request.attentionID = attentionID; request.attentionVersion = attentionVersion
                request.agentKind = agentKind; request.agentReport = agentReport; request.commandID = commandID
                request.reminderPolicy = reminderPolicy
                let response = try connection.request(request)
                if let info = response.session { onState?(info) }
                completion?(.success(response))
            } catch {
                completion?(.failure(error))
                if case TerminalRuntimeConnectionError.rejected = error { return }
                if !isStopped { onFailure?(error, action.rawValue) }
            }
        }
    }

    func stop(closeTerminal: Bool) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true; closeRequested = closeTerminal; readerConnection?.cancel()
        let expected = initialInfo
        lock.unlock()
        guard closeTerminal, let expected else { return }
        commands.async { [self] in
            do {
                let connection = try TerminalRuntimeConnection(root: root)
                defer { connection.close() }
                let info = try current(connection, expected: expected)
                var request = TerminalRuntimeRequest(action: .close)
                request.sessionID = id; request.generation = info.generation; request.controlEpoch = info.controlEpoch
                _ = try connection.request(request)
            } catch { onFailure?(error, "close") }
        }
    }
}
