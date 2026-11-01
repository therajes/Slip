import Darwin
import Foundation

/// A kernel-owned lease shared by the app and its background worker. The kernel
/// releases it on process exit; no wall-clock timeout can unlock active work.
final class FileLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(_ url: URL, wait: Bool = false) throws -> FileLease? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        while flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return FileLease(fd)
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
    deinit { release() }
}
