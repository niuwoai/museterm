import Darwin
import Foundation

nonisolated enum TerminalRuntimeConnectionError: Error {
    case unavailable, timedOut, cancelled, invalidCapability, invalidResponse
    case incompatibleProtocol, serviceChanged, frameTooLarge, rejected(String)

    /// Stable diagnostic codes only; never expose paths or capability values.
    var diagnosticCode: String {
        switch self {
        case .unavailable: "unavailable"
        case .timedOut: "timed_out"
        case .cancelled: "cancelled"
        case .invalidCapability: "invalid_capability"
        case .invalidResponse: "invalid_response"
        case .incompatibleProtocol: "incompatible_protocol"
        case .serviceChanged: "service_changed"
        case .frameTooLarge: "frame_too_large"
        case .rejected(let code):
            code.utf8.count <= 64 && code.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) ? code : "rejected"
        }
    }
}

/// One instance is owned by one serial executor. cancel() may be called from
/// another executor; it shuts down the socket but never closes/reuses its FD
/// while an owner-side operation is still running. No automatic input retries.
nonisolated final class TerminalRuntimeConnection {
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var wasCancelled = false
    private let capability: String
    private var incoming = Data()
    private var epoch: UUID?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let maximumResponseBytes = TerminalRuntimeLimits.maximumResponseBytes

    init(root: URL) throws {
        var attributes = Darwin.stat()
        guard lstat(root.path, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o077 == 0 else {
            throw TerminalRuntimeConnectionError.invalidCapability
        }
        capability = try Self.readCapability(root.appendingPathComponent("ui-capability"))
        let path = root.appendingPathComponent("runtime.sock").path
        guard path.utf8.count < 100, !path.utf8.contains(0) else { throw TerminalRuntimeConnectionError.unavailable }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TerminalRuntimeConnectionError.unavailable }
        do {
            var disabled: Int32 = 1
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &disabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw TerminalRuntimeConnectionError.unavailable
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                for (index, byte) in path.utf8.enumerated() { target[index] = byte }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result < 0 {
                guard errno == EINPROGRESS else { throw TerminalRuntimeConnectionError.unavailable }
                var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard Darwin.poll(&pending, 1, 1_000) > 0 else { throw TerminalRuntimeConnectionError.timedOut }
                var status: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &status, &size) == 0, status == 0 else {
                    throw TerminalRuntimeConnectionError.unavailable
                }
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw TerminalRuntimeConnectionError.invalidCapability }
        } catch { Darwin.close(fd); throw error }
        descriptor = fd
        do { _ = try request(.init(action: .hello)) }
        catch { close(); throw error }
    }

    private static func readCapability(_ url: URL) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw TerminalRuntimeConnectionError.invalidCapability }
        defer { Darwin.close(fd) }
        var attributes = Darwin.stat()
        guard fstat(fd, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_mode & 0o077 == 0,
              attributes.st_size == 72 else { throw TerminalRuntimeConnectionError.invalidCapability }
        var bytes = [UInt8](repeating: 0, count: 72)
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count,
              bytes.allSatisfy({ $0 == 45 || (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let token = String(bytes: bytes, encoding: .utf8) else { throw TerminalRuntimeConnectionError.invalidCapability }
        return token
    }

    func request(_ value: TerminalRuntimeRequest) throws -> TerminalRuntimeResponse {
        var value = value
        value.capability = value.action == .hello ? nil : capability
        var bytes = try encoder.encode(value)
        bytes.append(0x0A)
        guard bytes.count <= TerminalRuntimeLimits.maximumFrameBytes else { throw TerminalRuntimeConnectionError.frameTooLarge }
        let deadline = ProcessInfo.processInfo.systemUptime + TerminalRuntimeLimits.requestDeadline
        do {
            try send(bytes, deadline: deadline)
            return try receive(id: value.id, action: value.action, deadline: deadline)
        } catch { close(); throw error }
    }

    /// For an already-started subscribe request. A timeout can be treated as an
    /// idle stream only by reconnecting with the last acknowledged output cursor.
    func next(id: UUID, action: TerminalRuntimeAction = .subscribe, timeout: TimeInterval = 5) throws -> TerminalRuntimeResponse {
        guard timeout.isFinite, timeout >= 0 else { throw TerminalRuntimeConnectionError.timedOut }
        do { return try receive(id: id, action: action, deadline: ProcessInfo.processInfo.systemUptime + min(60, max(0, timeout))) }
        catch { close(); throw error }
    }

    private func send(_ bytes: Data, deadline: TimeInterval) throws {
        var offset = 0
        while offset < bytes.count {
            let fd = try wait(for: Int16(POLLOUT), deadline: deadline)
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if written > 0 { offset += written }
            else if written < 0 && errno != EINTR && errno != EAGAIN { throw TerminalRuntimeConnectionError.unavailable }
        }
    }

    private func receive(id: UUID, action: TerminalRuntimeAction, deadline: TimeInterval) throws -> TerminalRuntimeResponse {
        while true {
            try checkCancellation()
            if let newline = incoming.firstIndex(of: 0x0A) {
                let frame = incoming.prefix(upTo: newline)
                guard frame.count <= Self.maximumResponseBytes else { throw TerminalRuntimeConnectionError.frameTooLarge }
                guard let response = try? decoder.decode(TerminalRuntimeResponse.self, from: frame),
                      response.id == id, response.action == action else { throw TerminalRuntimeConnectionError.invalidResponse }
                incoming.removeSubrange(...newline)
                guard response.protocolVersion == TerminalRuntimeLimits.protocolVersion else {
                    throw TerminalRuntimeConnectionError.incompatibleProtocol
                }
                if let epoch, epoch != response.serviceEpoch { throw TerminalRuntimeConnectionError.serviceChanged }
                epoch = response.serviceEpoch
                guard response.ok else {
                    let code = response.error ?? "runtime_error"
                    guard code.utf8.count <= 64, code.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else {
                        throw TerminalRuntimeConnectionError.invalidResponse
                    }
                    throw TerminalRuntimeConnectionError.rejected(code)
                }
                return response
            }
            guard incoming.count <= Self.maximumResponseBytes else { throw TerminalRuntimeConnectionError.frameTooLarge }
            let fd = try wait(for: Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                // A socket read may contain the end of one maximum-sized frame
                // and the beginning of the next. Bound the extra read chunk too.
                guard count + incoming.count <= Self.maximumResponseBytes + bytes.count else { throw TerminalRuntimeConnectionError.frameTooLarge }
                incoming.append(contentsOf: bytes.prefix(count))
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) { throw TerminalRuntimeConnectionError.unavailable }
        }
    }

    private func wait(for event: Int16, deadline: TimeInterval) throws -> Int32 {
        while true {
            stateLock.lock()
            let fd = descriptor
            let cancelled = wasCancelled
            stateLock.unlock()
            guard !cancelled else { throw TerminalRuntimeConnectionError.cancelled }
            guard fd >= 0 else { throw TerminalRuntimeConnectionError.unavailable }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw TerminalRuntimeConnectionError.timedOut }
            var pending = pollfd(fd: fd, events: event, revents: 0)
            let result = Darwin.poll(&pending, 1, Int32(min(remaining * 1_000, 250)))
            try checkCancellation()
            if result < 0 && errno != EINTR { throw TerminalRuntimeConnectionError.unavailable }
            // POLLHUP can accompany final readable bytes; drain those first.
            if pending.revents & event != 0 { return fd }
            if pending.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw TerminalRuntimeConnectionError.unavailable }
        }
    }

    private func checkCancellation() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        if wasCancelled { throw TerminalRuntimeConnectionError.cancelled }
    }

    func cancel() {
        stateLock.lock(); defer { stateLock.unlock() }
        wasCancelled = true
        if descriptor >= 0 { _ = shutdown(descriptor, SHUT_RDWR) }
    }

    /// Only the owning serial executor calls close().
    func close() {
        stateLock.lock(); defer { stateLock.unlock() }
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    deinit { close() }
}
