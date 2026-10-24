import Darwin
import Foundation

enum RuntimeFailure: String, Error {
    case invalidRequest = "invalid_request", invalidCapability = "invalid_capability"
    case unavailable, generationChanged = "generation_changed", controlChanged = "control_changed"
    case controlOwned = "control_owned", resourceLimit = "resource_limit", processLaunchFailed = "process_launch_failed"
    case writeFailed = "write_failed", resizeFailed = "resize_failed"
    case inputEchoChanged = "input_echo_changed", inputForegroundChanged = "input_foreground_changed"
}

final class RuntimeSession {
    let id: UUID
    let pid: Int32
    let directory: String
    var fd: Int32
    var journal: TerminalRuntimeOutputJournal
    var controlEpoch = UUID()
    var owner: String?
    var leaseDeadline: TimeInterval = 0
    var leaseExpiresAt: Date?
    var columns: Int
    var rows: Int
    var exitStatus: Int32?
    var pendingInput = Data()
    var nextInputSequence: UInt64 = 1
    private var revision: UInt64 = 1
    private(set) var outputRevision = 0
    let nativeAgentContext = TerminalNativeAgentContext()
    var agentMonitor = TerminalAgentMonitor()
    let commandLedger = TerminalRuntimeCommandLedger()
    private let bellParser = TerminalBellParser()
    private let attention: TerminalAttentionStore
    private(set) var reminderPolicy: TerminalReminderPolicy
    private let events: TerminalSessionEventStore

    init(id: UUID, launch: TerminalRuntimeLaunch, nativeRoot: URL, events: TerminalSessionEventStore,
         attention: TerminalAttentionStore) throws {
        self.events = events
        self.attention = attention
        reminderPolicy = launch.reminderPolicy ?? TerminalReminderPolicy()
        guard reminderPolicy.isValid else { throw RuntimeFailure.invalidRequest }
        journal = try TerminalRuntimeOutputJournal()
        let strings = [launch.executable, launch.directory, launch.executableName ?? ""]
            + launch.arguments + launch.environment.map { "\($0.key)=\($0.value)" }
        guard launch.executable.hasPrefix("/"), launch.directory.hasPrefix("/"),
              launch.directory.utf8.count < Int(PATH_MAX),
              launch.arguments.count <= 256, launch.environment.count <= 512,
              launch.executableName?.isEmpty != true,
              strings.allSatisfy({ !$0.utf8.contains(0) }),
              strings.reduce(0, { $0 + $1.utf8.count }) <= TerminalRuntimeLimits.maximumFrameBytes / 2,
              launch.environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }),
              (1...1000).contains(launch.columns), (1...1000).contains(launch.rows) else {
            throw RuntimeFailure.invalidRequest
        }
        var process: pid_t = 0
        let arguments = [launch.executableName ?? launch.executable] + launch.arguments
        let contextFile = try nativeAgentContext.prepare(tabID: id, root: nativeRoot)
        var childEnvironment = launch.environment
        childEnvironment["QTERM_AGENT_CONTEXT"] = contextFile.path
        let environment = childEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let childFD = try Self.withStrings(arguments) { argv in
            try Self.withStrings(environment) { envp in
                let result = qterm_pty_spawn(launch.executable, argv, envp, launch.directory,
                                            Int32(launch.columns), Int32(launch.rows), &process)
                guard result >= 0 else { throw RuntimeFailure.processLaunchFailed }
                return result
            }
        }
        self.id = id; pid = process; directory = launch.directory; fd = childFD
        columns = launch.columns; rows = launch.rows
    }

    private static func withStrings<T>(_ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        var pointers = strings.map { strdup($0) }
        defer { for pointer in pointers { free(pointer) } }
        guard pointers.allSatisfy({ $0 != nil }) else { throw RuntimeFailure.resourceLimit }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }

    var running: Bool { exitStatus == nil }
    var info: TerminalRuntimeSessionInfo {
        .init(id: id, revision: revision, pid: pid, generation: journal.generation, controlEpoch: controlEpoch,
              directory: directory, running: running, exitStatus: exitStatus, columns: columns, rows: rows,
              outputOffset: journal.cursor.offset, controlOwner: owner, nextInputSequence: nextInputSequence,
              agent: agentMonitor.snapshot,
            controlExpiresAt: leaseExpiresAt, outputRevision: outputRevision,
            commands: Array(commandLedger.commands.suffix(TerminalRuntimeCommandLedger.maximumProjectedCommands)),
            reminderPolicy: reminderPolicy)
    }

    func refresh() {
        updateAgent { $0.expire(now: Date()) }
        if owner != nil && ProcessInfo.processInfo.systemUptime >= leaseDeadline { releaseControl() }
        if running {
            var result: Int32 = 0
            let status = qterm_pty_poll_exit(pid, &result)
            if status == 1 {
                // Drain final markers before interpreting process exit as unknown completion.
                do { try readOutput() }
                catch { NSLog("QTerm runtime final output drain failed: %@", String(describing: error)) }
                exitStatus = result; pendingInput.removeAll(); revision += 1
                if fd < 0, let command = commandLedger.finish() { publishCommand(command) }
                if owner != nil { releaseControl() }
                updateAgent { $0.exit(now: Date()) }
                events.publish(tabID: id, kind: .processExited)
                recordProcessExit(result)
                nativeAgentContext.invalidate()
            }
            else if status < 0 && errno == ECHILD {
                exitStatus = -1; pendingInput.removeAll(); revision += 1
                if fd < 0, let command = commandLedger.finish() { publishCommand(command) }
                if owner != nil { releaseControl() }
                recordProcessExit(nil)
            }
        }
    }

    @discardableResult
    func updateAgent<T>(_ operation: (inout TerminalAgentMonitor) throws -> T) rethrows -> T {
        let previous = agentMonitor.snapshot
        let value = try operation(&agentMonitor)
        if previous != agentMonitor.snapshot { revision += 1 }
        if !TerminalAgentSnapshot.sameEvidence(previous, agentMonitor.snapshot) {
            events.publish(tabID: id, kind: .agentChanged, agent: agentMonitor.snapshot)
        }
        return value
    }

    func validate(_ request: TerminalRuntimeRequest, control: Bool = false) throws {
        guard request.generation == journal.generation else { throw RuntimeFailure.generationChanged }
        if control && request.controlEpoch != controlEpoch { throw RuntimeFailure.controlChanged }
    }

    func updateControl(_ request: TerminalRuntimeRequest) throws {
        try validate(request, control: true)
        guard running else { throw RuntimeFailure.unavailable }
        if request.action == .releaseControl {
            guard request.owner == nil || owner == nil || request.owner == owner else { throw RuntimeFailure.controlOwned }
            releaseControl(); return
        }
        guard let requested = request.owner, !requested.isEmpty, requested.utf8.count <= 128,
              requested.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else {
            throw RuntimeFailure.invalidRequest
        }
        if request.action == .renewControl {
            guard owner == requested else { throw RuntimeFailure.controlChanged }
        } else {
            guard owner == nil || owner == requested else { throw RuntimeFailure.controlOwned }
            if owner == nil { releaseControl() }
        }
        owner = requested
        leaseDeadline = ProcessInfo.processInfo.systemUptime + TerminalRuntimeLimits.leaseSeconds
        leaseExpiresAt = Date().addingTimeInterval(TerminalRuntimeLimits.leaseSeconds)
        revision += 1
    }

    func releaseControl() {
        owner = nil; leaseDeadline = 0; leaseExpiresAt = nil; controlEpoch = UUID()
        nextInputSequence = 1
        revision += 1
        // Queued AI bytes must not outlive a human reclaim or expired lease.
        pendingInput.removeAll()
    }

    func input(_ request: TerminalRuntimeRequest) throws -> Bool {
        try validate(request, control: request.source != .protocolReply)
        guard running, fd >= 0 else { throw RuntimeFailure.unavailable }
        guard let data = request.data, !data.isEmpty, data.count <= TerminalRuntimeLimits.maximumOutputBytes,
              data.count + pendingInput.count <= TerminalRuntimeLimits.maximumFrameBytes else {
            throw RuntimeFailure.resourceLimit
        }
        switch request.source {
        case .human: guard owner == nil else { throw RuntimeFailure.controlOwned }
        case .ai: guard owner != nil && owner == request.owner else { throw RuntimeFailure.controlChanged }
        case .protocolReply:
            guard TerminalRuntimeReplyPolicy.allows(data) else { throw RuntimeFailure.invalidRequest }
        case nil: throw RuntimeFailure.invalidRequest
        }
        guard request.inputSequence == nextInputSequence, nextInputSequence < UInt64.max else {
            throw RuntimeFailure.controlChanged
        }
        if let expected = request.expectedEchoEnabled {
            let echo = qterm_pty_echo(fd)
            guard echo >= 0, (echo == 1) == expected else { throw RuntimeFailure.inputEchoChanged }
        }
        if let expected = request.expectedForegroundPID {
            guard expected > 0, tcgetpgrp(fd) == expected else { throw RuntimeFailure.inputForegroundChanged }
        }
        // Reserve before any write, including a partial failure. Even after the
        // bounded request cache evicts an ACK, an old input cannot execute twice.
        nextInputSequence += 1
        if request.source == .ai {
            leaseDeadline = ProcessInfo.processInfo.systemUptime + TerminalRuntimeLimits.leaseSeconds
            leaseExpiresAt = Date().addingTimeInterval(TerminalRuntimeLimits.leaseSeconds)
        }
        revision += 1
        let wasEmpty = pendingInput.isEmpty
        pendingInput.append(data)
        let echoed = qterm_pty_echo(fd) == 1
        try flushInput()
        // Never record input whose actual write is deferred or echo is unknown.
        return wasEmpty && pendingInput.isEmpty && echoed
    }

    func flushInput() throws {
        guard !pendingInput.isEmpty, fd >= 0 else { return }
        let count = pendingInput.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        if count > 0 { pendingInput.removeFirst(count) }
        else if count < 0 && errno != EAGAIN && errno != EINTR { throw RuntimeFailure.writeFailed }
    }

    func readOutput() throws {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Yield to other terminals and clients even if this PTY writes continuously.
        for _ in 0..<4 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                let offset = journal.cursor.offset
                try journal.append(Data(buffer.prefix(count)))
                let bells = bellParser.accept(buffer.prefix(count))
                let semanticItem = attention.activeItems.contains { $0.tabID == id && $0.isAgent && $0.source == .integration }
                if bells > 0, reminderPolicy.allowsBell(agent: agentMonitor.snapshot, hasSemanticItem: semanticItem) {
                    var context = TerminalAttentionTerminalContext(kind: .bell, eventID: journal.generation,
                        commandID: nil, exitCode: nil, failed: false)
                    context.occurrences = bells
                    _ = attention.recordTerminal(context, tabID: id)
                }
                for command in commandLedger.accept(buffer.prefix(count), at: offset, generation: journal.generation) {
                    publishCommand(command)
                }
                revision += 1; outputRevision += 1
                events.publish(tabID: id, kind: .outputChanged, revision: outputRevision)
            }
            else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                Darwin.close(fd); fd = -1
                if !running, let command = commandLedger.finish() { publishCommand(command) }
                break
            } else { break }
        }
    }

    func resize(_ request: TerminalRuntimeRequest) throws {
        try validate(request)
        guard let columns = request.columns, let rows = request.rows,
              running, fd >= 0, qterm_pty_resize(fd, Int32(clamping: columns), Int32(clamping: rows)) == 0 else {
            throw RuntimeFailure.resizeFailed
        }
        self.columns = columns; self.rows = rows
        revision += 1
    }

    func close() {
        refresh()
        if let command = commandLedger.finish() { publishCommand(command) }
        // Only signal the child while waitpid still proves it is our live child.
        if running { _ = kill(pid, SIGHUP) }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        pendingInput.removeAll()
        nativeAgentContext.invalidate()
        updateAgent { $0.exit(now: Date(), close: true) }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    private func publishCommand(_ command: TerminalRuntimeCommandInfo) {
        revision += 1
        events.publish(tabID: id, kind: command.endedAt == nil ? .commandStarted : .commandFinished,
                       commandID: command.id, commandState: command.state)
        if command.endedAt != nil {
            recordCommandReminder(command)
            updateAgent { $0.endObservedRun(command.id, now: Date()) }
        }
    }

    func configureReminders(_ policy: TerminalReminderPolicy) throws {
        guard policy.isValid else { throw RuntimeFailure.invalidRequest }
        if reminderPolicy != policy { reminderPolicy = policy; revision += 1 }
    }

    private func recordProcessExit(_ code: Int32?) {
        guard reminderPolicy.processExits else { return }
        _ = attention.recordTerminal(.init(kind: .processExited, eventID: journal.generation, commandID: nil,
            exitCode: code, failed: code != nil && code != 0), tabID: id)
    }

    private func recordCommandReminder(_ command: TerminalRuntimeCommandInfo) {
        guard let ended = command.endedAt, let evidence = commandLedger.evidence[command.id] else { return }
        let duration = max(0, ended.timeIntervalSince(command.startedAt))
        guard reminderPolicy.allowsCommand(state: command.state, duration: duration,
            isLowInformation: evidence.isLowInformation, hasErrorSignal: evidence.hasErrorSignal) else { return }
        _ = attention.recordTerminal(.init(kind: .commandFinished, eventID: command.id, commandID: command.id,
            exitCode: command.exitCode, failed: command.state == .failed), tabID: id)
    }
}
