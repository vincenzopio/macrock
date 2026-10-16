import Foundation
import SwiftProtobuf
import Synchronization
import Testing

@testable import LauncherCore

/// A new account whose service is the stand-in, relaying its channel to a fake service on the
/// account's socket.
struct AccountFixture {
    let temporary: TemporaryDirectory
    let account = Account(label: "")
    let setup: ServiceSetup

    init() async throws {
        temporary = try TemporaryDirectory()
        let directory = DataDirectory(root: temporary.url, sockets: .temporaryDirectory)
        let executable = try await serviceStandIn.value
        setup = ServiceSetup(
            executable: executable,
            pin: ServicePin(
                cdhash: try await runOnDedicatedThread { try StaticCode(executable).cdhash() },
                serviceProtocol: 1),
            directory: directory,
            host: HostEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/"))
    }

    /// A fake service for the account's next service to relay to, which answers HELLO and PING,
    /// and each other request with `reply`. A service that stops removes its socket, so each
    /// start needs a fake of its own.
    func fakeService(
        reply: @escaping @Sendable (_ type: UInt16, _ payload: Data) -> Data?
    ) throws -> FakeService {
        try FakeService(readyAt: socketPath, replies: { reply($0, $1).map { [$0] } })
    }

    /// Whether the account's service has stopped and let go of the account.
    var released: Bool {
        get async throws {
            guard !FileManager.default.fileExists(atPath: try socketPath) else { return false }
            return await AccountLock.isFree(at: setup.directory.prefixLock(for: account.id))
        }
    }

    private var socketPath: String {
        get throws { try setup.directory.socketPath(named: account.serviceName) }
    }
}

struct AccountSignInTests {
    @Test func signsInOnEachPageMicrosoftWantsAndReturnsTheGamertag() async throws {
        let secondPage = "https://login.live.com/ppsecure/InlineConnect.srf?id=80604"
        let signInReplies = Mutex([
            try Xodus_SignInResult.with { $0.inlineAuthURL = secondPage }.serializedBytes() as Data,
            try Xodus_SignInResult.with { $0.signedIn = .init() }.serializedBytes(),
        ])
        let profile =
            try Xodus_ProfileResult.with { $0.profile.gamertag = "Steve" }.serializedBytes() as Data
        let requests = Mutex<[Xodus_SignIn]>([])
        let fixture = try await AccountFixture()
        let fake = try fixture.fakeService { type, payload in
            switch type {
            case 202:
                if let request = try? Xodus_SignIn(serializedBytes: payload) {
                    requests.withLock { $0.append(request) }
                }
                return signInReplies.withLock { $0.removeFirst() }
            case 208: return profile
            default: return nil
            }
        }

        let serverData = ServerData(json: #"{"sDAToken":"t"}"#)
        var shown: [SignInPage] = []
        let gamertag = try await fixture.account.signIn(with: fixture.setup) { page in
            shown.append(page)
            return serverData
        }

        #expect(gamertag == "Steve")
        #expect(shown.map(\.isInlineAuth) == [false, true])
        #expect(shown.last?.request.url?.absoluteString == secondPage)
        #expect(requests.withLock { $0.map(\.inlineAuth) } == [false, true])
        #expect(requests.withLock { $0.map(\.serverData) } == [serverData.json, serverData.json])
        #expect(try await fixture.released)
        _ = fake
    }

    @Test func aClosedPageLeavesTheAccountForTheCallerToRemove() async throws {
        let signedOut =
            try Xodus_SignOutResult.with { $0.signedOut = .init() }.serializedBytes() as Data
        let requests = Mutex<[UInt16]>([])
        let fixture = try await AccountFixture()
        let signingIn = try fixture.fakeService { type, _ in
            requests.withLock { $0.append(type) }
            return nil
        }

        await #expect(throws: CancellationError.self) {
            try await fixture.account.signIn(with: fixture.setup) { _ in throw CancellationError() }
        }
        #expect(try await fixture.released)
        let removing = try fixture.fakeService { type, _ in
            requests.withLock { $0.append(type) }
            return type == 204 ? signedOut : nil
        }
        #expect(try await fixture.account.remove(with: fixture.setup) == nil)

        #expect(requests.withLock { $0 } == [204])
        #expect(try await fixture.released)
        _ = (signingIn, removing)
    }

    @Test func throwsTheReasonMicrosoftRefusedTheSignIn() async throws {
        let refused =
            try Xodus_SignInResult.with {
                $0.failure = .with {
                    $0.reason = .refused
                    $0.status = 0x8004_8821
                }
            }.serializedBytes() as Data
        let fixture = try await AccountFixture()
        let fake = try fixture.fakeService { type, _ in type == 202 ? refused : nil }

        await #expect(throws: ServiceFailure.refused(status: 0x8004_8821)) {
            try await fixture.account.signIn(with: fixture.setup) { _ in ServerData(json: "{}") }
        }
        #expect(try await fixture.released)
        _ = fake
    }

    @Test func removingSignsOutTheDeviceWithTheUser() async throws {
        let signedOut =
            try Xodus_SignOutResult.with { $0.signedOut = .init() }.serializedBytes() as Data
        let device = Mutex<Bool?>(nil)
        let fixture = try await AccountFixture()
        let fake = try fixture.fakeService { type, payload in
            guard type == 204 else { return nil }
            device.withLock { $0 = try? Xodus_SignOut(serializedBytes: payload).device }
            return signedOut
        }

        _ = try await fixture.account.remove(with: fixture.setup)

        #expect(device.withLock { $0 } == true)
        #expect(try await fixture.released)
        _ = fake
    }

    @Test func removingAnAccountKeepsItsGameDataAndDeletesItsPrefix() async throws {
        let signedOut =
            try Xodus_SignOutResult.with { $0.signedOut = .init() }.serializedBytes() as Data
        let fixture = try await AccountFixture()
        let fake = try fixture.fakeService { type, _ in type == 204 ? signedOut : nil }
        let directory = fixture.setup.directory
        let prefix = directory.prefix(for: fixture.account.id)
        let world = "Minecraft Bedrock/Users/Shared/games/com.mojang/minecraftWorlds/w/level.dat"
        let previewWorld = "Minecraft Bedrock Preview/Users/Shared/games/com.mojang/options.txt"
        for (file, text) in [(world, "world"), (previewWorld, "options")] {
            let path = prefix.appending(path: "drive_c/users/test/AppData/Roaming/\(file)")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: path)
        }

        let removed = try await fixture.account.remove(with: fixture.setup)

        let backup = try #require(removed)
        #expect(
            try String(contentsOf: backup.appending(path: world), encoding: .utf8) == "world")
        #expect(
            try String(contentsOf: backup.appending(path: previewWorld), encoding: .utf8)
                == "options")
        #expect(backup.path().hasPrefix(directory.backups.path()))
        #expect(!FileManager.default.fileExists(atPath: prefix.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.prefixLock(for: fixture.account.id).path))
        _ = fake
    }

    @Test func keepsAnAccountWhosePrefixStillRuns() async throws {
        let requests = Mutex<[UInt16]>([])
        let fixture = try await AccountFixture()
        let fake = try fixture.fakeService { type, _ in
            requests.withLock { $0.append(type) }
            return nil
        }
        let prefix = fixture.setup.directory.prefix(for: fixture.account.id)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let holder = try await ServerLockHolder(prefix: prefix)
        defer { holder.release() }

        await #expect(throws: SessionError.prefixInUse(holder.process.processIdentifier)) {
            try await fixture.account.remove(with: fixture.setup)
        }
        #expect(requests.withLock { $0 }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: prefix.path))
        _ = fake
    }

    /// Without a fake, a service that started would stop before it was ready.
    @Test func leavesAnAccountThatPlaysAlone() async throws {
        let fixture = try await AccountFixture()
        try FileManager.default.createDirectory(
            at: fixture.setup.directory.prefixes, withIntermediateDirectories: true)
        let lock = try AccountLock(
            file: fixture.setup.directory.prefixLock(for: fixture.account.id))

        await #expect(throws: SessionError.alreadyRunning) {
            try await fixture.account.remove(with: fixture.setup)
        }
        withExtendedLifetime(lock) {}
    }
}
