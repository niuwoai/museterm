import Foundation

// ZMODEM (rz/sz) bridge support types, extracted from TerminalHostView so
// the pure logic is unit-testable. The app never implements the ZMODEM
// protocol itself: the remote lrzsz talks to a local lrzsz process, and
// these types shuttle bytes between the PTY and that process.

enum TerminalFileTransferKind: Equatable {
    case upload
    case download
}

enum TerminalFileTransferPhase: Equatable {
    case checkingRemote
    case transferring
    case completed
    case failed
}

struct TerminalFileTransferStatus: Equatable {
    let kind: TerminalFileTransferKind
    let phase: TerminalFileTransferPhase
    let reason: String?
    let progress: TerminalFileTransferProgress?

    var isActive: Bool {
        phase == .checkingRemote || phase == .transferring
    }

    var localizedSummary: String {
        if let reason, phase == .failed {
            return reason
        }

        switch (kind, phase) {
        case (.upload, .checkingRemote):
            return L10n.string("file_transfer.upload.checking")
        case (.upload, .transferring):
            return L10n.string("file_transfer.upload.running")
        case (.upload, .completed):
            return L10n.string("file_transfer.upload.completed")
        case (.upload, .failed):
            return L10n.string("file_transfer.upload.failed")
        case (.download, .checkingRemote):
            return L10n.string("file_transfer.download.checking")
        case (.download, .transferring):
            return L10n.string("file_transfer.download.running")
        case (.download, .completed):
            return L10n.string("file_transfer.download.completed")
        case (.download, .failed):
            return L10n.string("file_transfer.download.failed")
        }
    }

    static func checkingRemote(kind: TerminalFileTransferKind) -> Self {
        Self(kind: kind, phase: .checkingRemote, reason: nil, progress: nil)
    }

    static func transferring(kind: TerminalFileTransferKind, progress: TerminalFileTransferProgress?) -> Self {
        Self(kind: kind, phase: .transferring, reason: nil, progress: progress)
    }

    static func completed(kind: TerminalFileTransferKind) -> Self {
        Self(kind: kind, phase: .completed, reason: nil, progress: TerminalFileTransferProgress(percent: 1, fileName: nil, detail: nil))
    }

    static func failed(kind: TerminalFileTransferKind, reason: String) -> Self {
        Self(kind: kind, phase: .failed, reason: reason, progress: nil)
    }
}

struct TerminalFileTransferProgress: Equatable {
    let percent: Double?
    let fileName: String?
    let detail: String?

    init(percent: Double?, fileName: String?, detail: String?) {
        self.percent = percent.map { min(1, max(0, $0)) }
        self.fileName = fileName
        self.detail = detail
    }
}

final class PendingZModemProbe {
    enum Result {
        case ready(initialRemoteBytes: [UInt8])
        case missing
    }

    let id = UUID()
    let kind: TerminalFileTransferKind
    let startLocalTransfer: ([UInt8]) -> Void
    private let readyMarker: [UInt8]
    private let missingMarker: [UInt8]
    private var buffer: [UInt8] = []
    private let maxProbeBufferSize = 16_384

    init(
        kind: TerminalFileTransferKind,
        readyMarker: String,
        missingMarker: String,
        startLocalTransfer: @escaping ([UInt8]) -> Void
    ) {
        self.kind = kind
        self.readyMarker = Array(readyMarker.utf8)
        self.missingMarker = Array(missingMarker.utf8)
        self.startLocalTransfer = startLocalTransfer
    }

    func acceptRemoteProbeData(_ bytes: [UInt8]) -> Result? {
        buffer.append(contentsOf: bytes)
        if buffer.count > maxProbeBufferSize {
            buffer.removeFirst(buffer.count - maxProbeBufferSize)
        }

        if buffer.firstRange(of: missingMarker) != nil {
            return .missing
        }

        guard let readyRange = buffer.firstRange(of: readyMarker) else {
            return nil
        }

        let trailingBytes = Array(buffer[readyRange.upperBound...])
        return .ready(initialRemoteBytes: trailingBytes)
    }
}

extension Array where Element == UInt8 {
    func firstRange(of marker: [UInt8]) -> Range<Int>? {
        guard !marker.isEmpty, marker.count <= count else { return nil }
        for index in 0...(count - marker.count) {
            if self[index..<(index + marker.count)].elementsEqual(marker) {
                return index..<(index + marker.count)
            }
        }
        return nil
    }
}

struct ZModemDownloadPlan {
    let remoteBasename: String
    let destinationFile: URL
    let temporaryDirectory: URL

    init(remotePath: String, destinationFile: URL) throws {
        let remoteBasename = Self.basename(from: remotePath)
        guard !remoteBasename.isEmpty else {
            throw NSError(
                domain: "MuseTermZModem",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.string("file_transfer.error.remote_basename")]
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseTermZModem", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        self.remoteBasename = remoteBasename
        self.destinationFile = destinationFile
        self.temporaryDirectory = temporaryDirectory
    }

    func moveDownloadedFileToDestination() throws {
        let expected = temporaryDirectory.appendingPathComponent(remoteBasename)
        let source: URL
        if FileManager.default.fileExists(atPath: expected.path) {
            source = expected
        } else {
            let receivedFiles = try FileManager.default.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            guard let first = receivedFiles.first else {
                throw NSError(
                    domain: "MuseTermZModem",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: L10n.string("file_transfer.error.download_missing")]
                )
            }
            source = first
        }

        let destinationDirectory = destinationFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationFile.path) {
            try FileManager.default.removeItem(at: destinationFile)
        }
        try FileManager.default.moveItem(at: source, to: destinationFile)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private static func basename(from remotePath: String) -> String {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingSlash = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return withoutTrailingSlash.split(separator: "/").last.map(String.init) ?? ""
    }
}

final class ZModemProgressParser {
    private var bufferedText = ""
    private var lastFileName: String?
    private let maxBufferedTextLength = 8_192

    func accept(stderrData: Data) -> TerminalFileTransferProgress? {
        let text = String(data: stderrData, encoding: .utf8)
            ?? String(data: stderrData, encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else { return nil }

        bufferedText.append(text)
        if bufferedText.count > maxBufferedTextLength {
            bufferedText.removeFirst(bufferedText.count - maxBufferedTextLength)
        }

        let candidates = bufferedText
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map(Self.cleanProgressLine)
            .filter { !$0.isEmpty }
        guard let line = candidates.last else { return nil }

        if let fileName = Self.fileName(from: line) {
            lastFileName = fileName
        }

        let percent = Self.percent(from: line)
        return TerminalFileTransferProgress(
            percent: percent,
            fileName: lastFileName,
            detail: line
        )
    }

    nonisolated private static func cleanProgressLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func fileName(from line: String) -> String? {
        let prefixes = ["Sending:", "Receiving:"]
        for prefix in prefixes where line.localizedCaseInsensitiveContains(prefix) {
            let parts = line.components(separatedBy: ":")
            guard parts.count > 1 else { continue }
            let candidate = parts.dropFirst().joined(separator: ":")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return URL(fileURLWithPath: candidate).lastPathComponent
            }
        }
        return nil
    }

    nonisolated private static func percent(from line: String) -> Double? {
        if let percentText = firstMatch(in: line, pattern: #"(\d{1,3})(?:\.\d+)?\s*%"#),
           let percent = Double(percentText) {
            return percent / 100
        }

        if let fraction = firstFraction(in: line), fraction.total > 0 {
            return Double(fraction.current) / Double(fraction.total)
        }

        return nil
    }

    nonisolated private static func firstMatch(in line: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let valueRange = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[valueRange])
    }

    nonisolated private static func firstFraction(in line: String) -> (current: Int64, total: Int64)? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*/\s*(\d+)"#) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges > 2 else {
            return nil
        }
        guard
            let currentRange = Range(match.range(at: 1), in: line),
            let totalRange = Range(match.range(at: 2), in: line),
            let current = Int64(line[currentRange]),
            let total = Int64(line[totalRange])
        else {
            return nil
        }
        return (current, total)
    }
}

enum ZModemBridgeEndReason: Equatable {
    case none
    case userCancelled
    case timedOut
}

final class ZModemBridgeProcess {
    /// ZMODEM cancel burst (8×CAN) followed by backspaces, the same abort
    /// sequence lrzsz itself sends. Sent to the remote so its rz/sz stops
    /// instead of leaving the remote shell hung.
    static let remoteCancelSequence: [UInt8] =
        Array(repeating: 0x18, count: 8) + Array(repeating: 0x08, count: 8)

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "app.museterm.zmodem.stdin")
    private let outputQueue = DispatchQueue(label: "app.museterm.zmodem.stdout")
    private let progressParser = ZModemProgressParser()
    private let stateLock = NSLock()
    private var endReasonValue: ZModemBridgeEndReason = .none
    private var lastActivity = Date()
    private var didFinish = false
    private var acceptingRemoteBytes = true
    private var watchdog: DispatchSourceTimer?

    let idleTimeout: TimeInterval
    private let onOutput: ([UInt8]) -> Void
    private let onProgress: (TerminalFileTransferProgress) -> Void
    private let onExit: (Int32, ZModemBridgeEndReason) -> Void

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectory: URL?,
        idleTimeout: TimeInterval = 30,
        onOutput: @escaping ([UInt8]) -> Void,
        onProgress: @escaping (TerminalFileTransferProgress) -> Void,
        onExit: @escaping (Int32, ZModemBridgeEndReason) -> Void
    ) throws {
        self.idleTimeout = idleTimeout
        self.onOutput = onOutput
        self.onProgress = onProgress
        self.onExit = onExit

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.outputQueue.async {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self.touchActivity()
                self.onOutput(Array(data))
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.touchActivity()
            if let progress = self.progressParser.accept(stderrData: data) {
                self.onProgress(progress)
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.handleTermination(exitCode: process.terminationStatus)
        }

        try process.run()
        startWatchdog()
    }

    var endReason: ZModemBridgeEndReason {
        stateLock.lock()
        defer { stateLock.unlock() }
        return endReasonValue
    }

    func acceptRemoteData(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        stateLock.lock()
        let accepting = acceptingRemoteBytes
        stateLock.unlock()
        guard accepting else { return }
        let data = Data(bytes)
        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.stdinPipe.fileHandleForWriting.write(contentsOf: data)
                self.touchActivity()
            } catch {
                self.stateLock.lock()
                self.acceptingRemoteBytes = false
                self.stateLock.unlock()
                self.stdinPipe.fileHandleForWriting.closeFile()
                if self.process.isRunning {
                    self.process.terminate()
                }
            }
        }
    }

    /// Abort the transfer: remember why, ask the remote rz/sz to stop
    /// (cancel burst) and terminate the local process. Completion is
    /// reported through the normal `onExit` path.
    func cancel(reason: ZModemBridgeEndReason) {
        stateLock.lock()
        if endReasonValue == .none {
            endReasonValue = reason
        }
        acceptingRemoteBytes = false
        stateLock.unlock()
        onOutput(Self.remoteCancelSequence)
        if process.isRunning {
            process.terminate()
        }
    }

    private func touchActivity() {
        stateLock.lock()
        lastActivity = Date()
        stateLock.unlock()
    }

    private func startWatchdog() {
        guard idleTimeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        let interval = max(idleTimeout / 4, 0.25)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.checkIdle()
        }
        watchdog = timer
        timer.resume()
    }

    /// A transfer with no bytes moving in either direction is dead (remote
    /// killed mid-frame, wedged handshake, …). Without this the terminal
    /// swallows every byte forever and the sidebar spins indefinitely.
    private func checkIdle() {
        stateLock.lock()
        guard !didFinish, endReasonValue == .none,
              Date().timeIntervalSince(lastActivity) >= idleTimeout else {
            stateLock.unlock()
            return
        }
        endReasonValue = .timedOut
        acceptingRemoteBytes = false
        stateLock.unlock()
        onOutput(Self.remoteCancelSequence)
        if process.isRunning {
            process.terminate()
        }
    }

    private func handleTermination(exitCode: Int32) {
        stateLock.lock()
        acceptingRemoteBytes = false
        stateLock.unlock()
        watchdog?.cancel()
        watchdog = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdinPipe.fileHandleForWriting.closeFile()

        // Process.terminationHandler can run before FileHandle delivers the
        // final stdout callback. Drain the leftover bytes on the same serial
        // queue as ordinary reads BEFORE reporting exit: the ZFIN/OO tail of
        // the ZMODEM session must reach the remote rz/sz, or the remote
        // shell never gets its prompt back after the transfer.
        let handle = stdoutPipe.fileHandleForReading
        outputQueue.async { [weak self] in
            guard let self else { return }
            let trailing = handle.readDataToEndOfFile()
            if !trailing.isEmpty {
                self.onOutput(Array(trailing))
            }
            self.finishOnce(exitCode: exitCode)
        }
    }

    private func finishOnce(exitCode: Int32) {
        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            return
        }
        didFinish = true
        let reason = endReasonValue
        stateLock.unlock()
        onExit(exitCode, reason)
    }
}

enum ZModemLocalTool {
    static func executable(named name: String) -> URL? {
        searchDirectories
            .lazy
            .map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var searchDirectories: [URL] {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }

        let commonDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }

        var seen = Set<String>()
        return (pathDirectories + commonDirectories).filter { url in
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}
