import Darwin
import Foundation

final class RuntimeSocket {
    let root: URL
    let fd: Int32
    let lockFD: Int32
    let capability: String
    private let path: String

    init(root: URL) throws {
        self.root = root
        guard root.path.hasPrefix("/"), !root.path.utf8.contains(0) else { throw RuntimeFailure.invalidRequest }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        var stat = Darwin.stat()
        guard lstat(root.path, &stat) == 0, stat.st_uid == getuid(),
              stat.st_mode & S_IFMT == S_IFDIR, stat.st_mode & 0o077 == 0 else {
            throw RuntimeFailure.invalidCapability
        }
        let socketPath = root.appendingPathComponent("runtime.sock").path
        path = socketPath
        guard socketPath.utf8.count < 100 else { throw RuntimeFailure.invalidRequest }
        let lock = Darwin.open(root.appendingPathComponent("runtime.lock").path,
                               O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw RuntimeFailure.unavailable }
        guard fstat(lock, &stat) == 0, stat.st_uid == getuid(), stat.st_mode & S_IFMT == S_IFREG,
              stat.st_mode & 0o077 == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock); throw RuntimeFailure.unavailable
        }
        lockFD = lock
        capability = UUID().uuidString + UUID().uuidString
        let handle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { Darwin.close(lock); throw RuntimeFailure.unavailable }
        do {
            try Self.nonblocking(handle)
            // Only the lock owner can remove the previous owner's dead socket.
            if unlink(path) < 0 && errno != ENOENT { throw RuntimeFailure.unavailable }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in socketPath.utf8.enumerated() { buffer[index] = byte }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(handle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(path, 0o600) == 0, listen(handle, 16) == 0 else { throw RuntimeFailure.unavailable }
            let capabilityURL = root.appendingPathComponent("ui-capability")
            // Atomic replacement of a private file; never follows a pre-existing symlink.
            let temporary = root.appendingPathComponent("capability-\(UUID())")
            let file = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw RuntimeFailure.unavailable }
            let writer = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            do { try writer.write(contentsOf: Data(capability.utf8)); try writer.close() }
            catch { try? writer.close(); unlink(temporary.path); throw error }
            guard rename(temporary.path, capabilityURL.path) == 0 else {
                unlink(temporary.path); throw RuntimeFailure.unavailable
            }
        } catch { Darwin.close(handle); Darwin.close(lock); throw error }
        fd = handle
    }

    static func nonblocking(_ fd: Int32) throws {
        var disabled: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &disabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw RuntimeFailure.unavailable
        }
    }

    func acceptClient() -> Int32? {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return nil }
        var uid: uid_t = 0
        var gid: gid_t = 0
        do {
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { throw RuntimeFailure.invalidCapability }
            try Self.nonblocking(client)
            return client
        } catch { Darwin.close(client); return nil }
    }

    func authorizes(_ candidate: String?) -> Bool {
        guard let candidate, candidate.utf8.count == capability.utf8.count else { return false }
        return zip(candidate.utf8, capability.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    deinit { Darwin.close(fd); unlink(path); Darwin.close(lockFD) }
}
