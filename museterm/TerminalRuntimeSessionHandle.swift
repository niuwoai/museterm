import Foundation

enum TerminalRuntimePresentationIssue: String {
    case connecting, disconnected, sessionEnded, sessionReopened, outputGap, inputRejected, inputTooLarge
}

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
    private(set) var reconnecting = false
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
    var onCreationRequested: ((UUID?) throws -> Void)?
    var onFailure: ((Error) -> Void)?
    var onRecovering: (() -> Void)?
    private var pendingReminderPolicy: TerminalReminderPolicy?
    private var pendingAcknowledgements: Set<UUID> = []

    init(id: UUID, root: URL = TerminalRuntimeService.rootDirectory,
         executable: URL = TerminalRuntimeService.executableURL) {
        io = TerminalRuntimeSessionIO(id: id, root: root, executable: executable)
        io.onCreationRequested = { [weak self] epoch in
            try DispatchQueue.main.sync {
                guard let self else { throw TerminalRuntimeConnectionError.unavailable }
                try self.onCreationRequested?(epoch)
            }
        }
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
                // Late AppKit acknowledgements can overlap frames queued by a retry.
                let (response, historicalBytes) = TerminalRuntimeReplayBoundary.removingRenderedOverlap(
                    from: response, renderedThrough: self.renderedCursor, historicalBytes: historicalBytes)
                self.eventCursor = response.eventHead
                if let info = response.session { self.accept(info, receivedOutput: true) }
                let rendered = { [weak self] in
                    if let self, let cursor = response.cursor, self.renderedCursor != cursor,
                       self.renderedCursor == nil || self.renderedCursor?.generation != cursor.generation
                        || self.renderedCursor!.offset < cursor.offset {
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
                self?.reconnecting = false
                self?.lastError = (error as? TerminalRuntimeConnectionError) ?? .unavailable
                self?.lastErrorStage = stage
                self?.onFailure?(error)
            }
        }
        io.onRecovering = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = false; self.reconnecting = true
                self.lastError = (error as? TerminalRuntimeConnectionError) ?? .unavailable
                self.lastErrorStage = "subscription"
                self.onRecovering?()
            }
        }
    }

    private func accept(_ info: TerminalRuntimeSessionInfo, receivedOutput: Bool = false) {
        guard self.info == nil || (self.info?.generation == info.generation && self.info!.revision <= info.revision) else { return }
        self.info = info
        if receivedOutput { connected = true; reconnecting = false; lastError = nil; lastErrorStage = nil }
        onState?(info)
    }

    func start(_ launch: TerminalRuntimeLaunch, restoring generation: UUID? = nil, existingOnly: Bool = false,
               renderedCursor: TerminalRuntimeOutputCursor? = nil, restarting previous: TerminalRuntimeSessionInfo? = nil,
               recoverMissingLocalShell: Bool = false, pendingCreationEpoch: UUID? = nil) {
        io.start(launch, restoring: generation, existingOnly: existingOnly, renderedCursor: renderedCursor,
            restarting: previous, recoverMissingLocalShell: recoverMissingLocalShell, pendingCreationEpoch: pendingCreationEpoch)
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
                      owner: String?, expected: TerminalRuntimeSessionInfo? = nil,
                      completion: @escaping (Result<TerminalRuntimeResponse, Error>) -> Void) -> Bool {
        guard connected, let info, info.running else { return false }
        // AI input pins the epoch from the preflight rather than from enqueue
        // time: the lease it writes under is acquired in the same turn, so the
        // snapshot held at enqueue is already stale once the preflight returns.
        // Human input keeps the stricter check against the enqueue snapshot.
        let pinned = expected ?? preparation.session
        guard pinned.generation == preparation.session.generation,
              info.generation == preparation.session.generation,
              info.controlEpoch == pinned.controlEpoch else { return false }
        return io.input(data, expected: pinned, source: source, owner: owner,
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

    func reconnect() {
        reconnecting = true
        onRecovering?()
        // The previous reader may still be blocked on a frame the UI has not
        // finished parsing. Leave it running and a second reader never starts,
        // so the button would do nothing while the banner stays up.
        io.restartReader(replacingCurrent: true)
    }
    #if DEBUG
    func interruptSubscriptionForTesting() { io.interruptSubscriptionForTesting() }
    #endif
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
    private let commands = DispatchQueue(label: "im.some.museterm.runtime.commands")
    private let reader = DispatchQueue(label: "im.some.museterm.runtime.output")
    private let lock = NSLock()
    private var stopped = false
    private var closeRequested = false
    private var readerActive = false
    /// Bumped by a manual reconnect so the reader it replaces exits without
    /// reporting the cancellation as a failure.
    private var readerGeneration = 0
    /// The generation whose reader task is currently inside the loop. A manual
    /// reconnect starts the replacement at once; the replaced reader only clears
    /// this when it is still the one recorded here.
    private var runningReaderGeneration: Int?
    private var pendingInputBytes = 0
    private var readerConnection: TerminalRuntimeConnection?
    private var expectedEpoch: UUID?
    private var initialInfo: TerminalRuntimeSessionInfo?
    private var outputCursor: TerminalRuntimeOutputCursor?
    private var historicalBoundary: TerminalRuntimeOutputCursor?
    // A lost create reply must not replay a launch after the service disappears.
    private var creationWasRequested = false
    private var pendingCreationEpoch: UUID?
    var onCreationRequested: ((UUID?) throws -> Void)?
    var onState: ((TerminalRuntimeSessionInfo) -> Void)?
    var onStarted: ((TerminalRuntimeSessionInfo, Bool, [String]) -> Void)?
    var onOutput: ((TerminalRuntimeResponse, Int, @escaping () -> Void) -> Void)?
    var onFailure: ((Error, String) -> Void)?
    var onRecovering: ((Error) -> Void)?

    init(id: UUID, root: URL, executable: URL) { self.id = id; self.root = root; self.executable = executable }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func start(_ launch: TerminalRuntimeLaunch, restoring generation: UUID?, existingOnly: Bool,
               renderedCursor: TerminalRuntimeOutputCursor?, restarting previous: TerminalRuntimeSessionInfo?,
               recoverMissingLocalShell: Bool, pendingCreationEpoch: UUID?) {
        commands.async { [self] in
            self.pendingCreationEpoch = pendingCreationEpoch
            var retry = TerminalRuntimeReconnectPolicy()
            while !isStopped {
                do {
                    try startAttempt(launch, restoring: generation, existingOnly: existingOnly,
                                     renderedCursor: renderedCursor, restarting: previous,
                                     recoverMissingLocalShell: recoverMissingLocalShell)
                    return
                } catch {
                    guard !isStopped else { return }
                    guard let delay = retry.nextDelay(for: error, healthyFor: 0) else {
                        onFailure?(error, "startup")
                        return
                    }
                    onRecovering?(error)
                    let deadline = ProcessInfo.processInfo.systemUptime + delay
                    while !isStopped, ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: min(0.1, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                    }
                }
            }
        }
    }

    private func startAttempt(_ launch: TerminalRuntimeLaunch, restoring generation: UUID?, existingOnly: Bool,
                              renderedCursor: TerminalRuntimeOutputCursor?, restarting previous: TerminalRuntimeSessionInfo?,
                              recoverMissingLocalShell: Bool) throws {
        // Only a complete, authenticated list can establish that the original
        // process is gone. A transport or identity error never permits creation.
        try TerminalRuntimeService.ensureRunning(root: root, executable: executable)
        let connection = try TerminalRuntimeConnection(root: root)
        defer { connection.close() }
        let listed = try connection.request(.init(action: .list))
        guard let sessions = listed.sessions else { throw TerminalRuntimeConnectionError.invalidResponse }
        guard !creationWasRequested || pendingCreationEpoch == listed.serviceEpoch else {
            throw TerminalRuntimeConnectionError.serviceChanged
        }
        let existing = sessions.first { $0.id == id }
        var reopenedMissing = false
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
            // A create ACK may have been lost. Only adopt that replacement from
            // the same service we asked to create it, never an unrelated epoch.
            reopenedMissing = recoverMissingLocalShell && pendingCreationEpoch == listed.serviceEpoch
            guard generation == nil || generation == existing.generation || reopenedMissing else {
                throw TerminalRuntimeConnectionError.serviceChanged
            }
            info = existing
        } else {
            guard !creationWasRequested,
                  (generation == nil && !existingOnly) || recoverMissingLocalShell else {
                throw TerminalRuntimeConnectionError.sessionMissing
            }
            var request = TerminalRuntimeRequest(action: .create)
            request.sessionID = id; request.launch = launch
            try onCreationRequested?(listed.serviceEpoch)
            guard !isStopped else { return }
            creationWasRequested = true
            pendingCreationEpoch = listed.serviceEpoch
            do {
                guard let created = try connection.request(request).session else { throw TerminalRuntimeConnectionError.invalidResponse }
                info = created
            } catch TerminalRuntimeConnectionError.rejected(let code) {
                // A negative ACK proves this request created no process. Unlike
                // a lost reply, it must leave the tab eligible for a later retry.
                creationWasRequested = false
                pendingCreationEpoch = nil
                try onCreationRequested?(nil)
                throw TerminalRuntimeConnectionError.rejected(code)
            }
            reopenedMissing = recoverMissingLocalShell && (generation != nil || existingOnly)
        }
        let replayBoundary = reopenedMissing ? nil : renderedCursor
        if let replayBoundary {
            guard replayBoundary.generation == info.generation, replayBoundary.offset <= info.outputOffset else {
                throw TerminalRuntimeConnectionError.serviceChanged
            }
        }
        lock.lock(); expectedEpoch = listed.serviceEpoch; initialInfo = info; historicalBoundary = replayBoundary; lock.unlock()
        if isStopped {
            lock.lock(); let close = closeRequested; lock.unlock()
            if close {
                var request = TerminalRuntimeRequest(action: .close)
                request.sessionID = id; request.generation = info.generation; request.controlEpoch = info.controlEpoch
                _ = try connection.request(request)
            }
            return
        }
        onStarted?(info, existing == nil || previous != nil || reopenedMissing, listed.features ?? [])
        restartReader(replacingCurrent: false)
    }

    /// `replacingCurrent` is the manual reconnect path. It cancels the reader
    /// that is still alive and starts the replacement immediately, so the button
    /// works even while that reader is blocked waiting for the UI to finish
    /// parsing a frame.
    func restartReader(replacingCurrent: Bool) {
        lock.lock()
        if replacingCurrent, !stopped {
            readerGeneration += 1
            readerConnection?.cancel()
            readerActive = false
        }
        let generation = readerGeneration
        guard !stopped, !readerActive, let initialInfo, let expectedEpoch else { lock.unlock(); return }
        readerActive = true
        lock.unlock()
        reader.async { [self] in
            lock.lock()
            let stillCurrent = isCurrentReaderLocked(generation)
            if stillCurrent { runningReaderGeneration = generation }
            lock.unlock()
            defer {
                lock.lock()
                if runningReaderGeneration == generation {
                    readerActive = false
                    readerConnection = nil
                    runningReaderGeneration = nil
                }
                lock.unlock()
            }
            guard stillCurrent else { return }
            var retry = TerminalRuntimeReconnectPolicy()
            while !isStopped, isCurrentReader(generation) {
                var connectedAt: TimeInterval?
                var lastAcknowledgedAt: TimeInterval?
                do {
                    let connection = try TerminalRuntimeConnection(root: root)
                    defer { connection.close() }
                    lock.lock()
                    let superseded = !isCurrentReaderLocked(generation)
                    if !superseded { readerConnection = connection }
                    lock.unlock()
                    if superseded { connection.cancel(); return }
                    var request = TerminalRuntimeRequest(action: .subscribe)
                    request.sessionID = id; request.generation = initialInfo.generation; request.after = outputCursor
                    var response = try connection.request(request)
                    while !isStopped, isCurrentReader(generation) {
                        guard response.serviceEpoch == expectedEpoch, response.session?.generation == initialInfo.generation else {
                            throw TerminalRuntimeConnectionError.serviceChanged
                        }
                        let consumed = DispatchSemaphore(value: 0)
                        let historicalBytes = try TerminalRuntimeReplayBoundary.historicalBytes(
                            in: response, renderedThrough: historicalBoundary)
                        onOutput?(response, historicalBytes, { consumed.signal() })
                        // The bytes already belong to the app, and the helper drops the
                        // subscription itself once its outgoing queue passes the byte cap.
                        // Timing the UI's parse out here used to kill a healthy session:
                        // a full-screen redraw keeps the main thread busy past the
                        // deadline, the retries run out, and the banner sticks even
                        // though the process never stopped.
                        let deadline = ProcessInfo.processInfo.systemUptime + TerminalRuntimeLimits.consumerAcknowledgementDeadline
                        var consumerOverdue = false
                        while consumed.wait(timeout: .now() + 0.1) == .timedOut {
                            if isStopped || !isCurrentReader(generation) { return }
                            if !consumerOverdue, ProcessInfo.processInfo.systemUptime >= deadline {
                                consumerOverdue = true
                                onRecovering?(TerminalRuntimeConnectionError.timedOut)
                            }
                        }
                        outputCursor = response.cursor
                        lastAcknowledgedAt = ProcessInfo.processInfo.systemUptime
                        if connectedAt == nil { connectedAt = lastAcknowledgedAt }
                        if isStopped || !isCurrentReader(generation) { return }
                        response = try connection.next(id: request.id, timeout: 60)
                    }
                } catch {
                    guard !isStopped, isCurrentReader(generation) else { return }
                    let healthyFor = connectedAt.map { (lastAcknowledgedAt ?? $0) - $0 } ?? 0
                    guard let delay = retry.nextDelay(for: error, healthyFor: healthyFor) else {
                        onFailure?(error, "subscription"); return
                    }
                    onRecovering?(error)
                    let deadline = ProcessInfo.processInfo.systemUptime + delay
                    while !isStopped, isCurrentReader(generation), ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: min(0.1, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                    }
                }
            }
        }
    }

    private func isCurrentReader(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isCurrentReaderLocked(generation)
    }

    /// Caller holds `lock`.
    private func isCurrentReaderLocked(_ generation: Int) -> Bool {
        readerGeneration == generation
    }

    #if DEBUG
    func interruptSubscriptionForTesting() {
        lock.lock(); let connection = readerConnection; lock.unlock()
        connection?.interruptTransportForTesting()
    }
    #endif

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
