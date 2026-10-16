import Foundation
import Testing

@testable import LauncherCore

struct AccountLockTests {
    let temporary: TemporaryDirectory
    let file: URL

    init() throws {
        temporary = try TemporaryDirectory()
        file = temporary.url.appending(path: "account.lock")
    }

    @Test func refusesASecondLockUntilTheFirstIsReleased() async throws {
        do {
            let held = try AccountLock(file: file)
            #expect(throws: SessionError.alreadyRunning) { try AccountLock(file: file) }
            withExtendedLifetime(held) {}
        }
        #expect(await AccountLock.isFree(at: file))
    }

    /// A refused lock that closed its descriptor twice would close the file another thread
    /// opened with the same number in between.
    @Test func aRefusedLockClosesNoOtherFile() async throws {
        let other = temporary.url.appending(path: "other")
        try Data().write(to: other)
        let held = try AccountLock(file: file)
        let file = file

        async let refusing: Void = runOnDedicatedThread {
            for _ in 0..<20_000 { _ = try? AccountLock(file: file) }
        }
        let closedUnderneath = try await runOnDedicatedThread {
            var closed = 0
            for _ in 0..<5_000 {
                let opened = (0..<16).map { _ in open(other.path, O_RDONLY | O_CLOEXEC) }
                for descriptor in opened {
                    if fcntl(descriptor, F_GETFD) == -1 { closed += 1 } else { close(descriptor) }
                }
            }
            return closed
        }
        try await refusing
        #expect(closedUnderneath == 0)
        withExtendedLifetime(held) {}
    }
}

extension AccountLock {
    /// Whether the lock at `file` is free. A child that another test is spawning shares this
    /// process's descriptors until it execs, so a lock released a moment ago can look held for
    /// that long: this tries for a while.
    static func isFree(at file: URL) async -> Bool {
        for _ in 0..<50 {
            if (try? AccountLock(file: file)) != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
