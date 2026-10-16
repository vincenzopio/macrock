import Foundation

/// The lock that keeps one session per account. It is an advisory lock on a file next to the
/// account's prefix, so it also holds against a second launcher, and it is released when the
/// launcher exits, however it exits.
final class AccountLock: Sendable {
    private let descriptor: Int32

    init(file: URL) throws {
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            guard error == EWOULDBLOCK else {
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            throw SessionError.alreadyRunning
        }
        // Set last: once every property is set, a throw would run deinit, which closes the
        // descriptor again, whatever file has its number by then.
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }
}

extension Account {
    func withLock<Value>(
        in directory: DataDirectory, _ body: () async throws -> Value
    ) async throws -> Value {
        try FileManager.default.createDirectory(
            at: directory.prefixes, withIntermediateDirectories: true)
        let lock = try AccountLock(file: directory.prefixLock(for: id))
        defer { withExtendedLifetime(lock) {} }
        return try await body()
    }
}
