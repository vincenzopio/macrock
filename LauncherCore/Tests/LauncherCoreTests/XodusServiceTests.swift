import Foundation
import SwiftProtobuf
import Synchronization
import Testing

@testable import LauncherCore

/// The service's binary is checked by the kernel at exec, so the stand-ins are signed Mach-O
/// tools: `serviceStandIn` relays its channel to a fake service, caffeinate runs until a signal,
/// env prints its environment and exits.
struct XodusServiceTests {
    let temporary: TemporaryDirectory
    let socketPath = shortSocketPath()
    let host = HostEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/")
    let caffeinate = URL(filePath: "/usr/bin/caffeinate")

    init() throws {
        temporary = try TemporaryDirectory()
    }

    func start(
        _ executable: URL? = nil, log: RedactedLog, pin: Data? = nil,
        readinessTimeout: Duration = .seconds(5)
    ) async throws -> XodusService {
        let standIn = try await serviceStandIn.value
        let executable = executable ?? standIn
        let cdhash = try await runOnDedicatedThread { try pin ?? StaticCode(executable).cdhash() }
        return try await XodusService.start(
            executable: executable, pinnedCDHash: cdhash,
            keychainService: "dev.macrock.account.test", socketPath: socketPath, host: host,
            log: log, readinessTimeout: readinessTimeout)
    }

    @Test func startsOnceTheChannelAndTheSocketAnswerAndStopsWithSIGINT() async throws {
        let fake = try FakeService(path: socketPath) { type, payload in (type + 1, payload) }
        let log = try RedactedLog(file: temporary.url.appending(path: "service.log"))

        let service = try await start(log: log)
        try await service.client.ping()

        #expect(await service.stop() == .signaled(SIGINT))
        #expect(!FileManager.default.fileExists(atPath: fake.path))
        try await log.close()
    }

    @Test func passesExactlyItsEnvironment() async throws {
        let logFile = temporary.url.appending(path: "service.log")
        let log = try RedactedLog(file: logFile)

        await #expect(throws: XodusServiceError.exitedBeforeReady(.exited(0))) {
            try await start(URL(filePath: "/usr/bin/env"), log: log)
        }
        try await log.close()

        let environment = try String(contentsOf: logFile, encoding: .utf8).split(separator: "\n")
        #expect(
            Set(environment) == [
                "HOME=/Users/test", "USER=test", "TMPDIR=/tmp/", "PATH=/usr/bin:/bin",
                "XODUS_SOCKET=\(socketPath)", "XODUS_KEYCHAIN_SERVICE=dev.macrock.account.test",
                "XODUS_LOG=xodus_service=info", "XODUS_LAUNCHER_CHANNEL=stdin",
            ])
    }

    @Test func refusesABinaryThatIsNotThePinnedBuild() async throws {
        let log = try RedactedLog(file: temporary.url.appending(path: "service.log"))
        await #expect(throws: XodusServiceError.notThePinnedBuild) {
            try await start(caffeinate, log: log, pin: Data(count: 20))
        }
        try await log.close()
    }

    @Test func refusesAnEmptyKeychainService() async throws {
        let log = try RedactedLog(file: temporary.url.appending(path: "service.log"))
        await #expect(throws: XodusServiceError.missingSetting) {
            try await XodusService.start(
                executable: caffeinate, pinnedCDHash: Data(), keychainService: "",
                socketPath: socketPath, host: host, log: log)
        }
        try await log.close()
    }

    @Test func givesUpOnAServiceThatAnswersItsChannelButNeverItsSocket() async throws {
        let fake = try FakeService(path: socketPath) { type, payload in
            type == 1 ? nil : (type + 1, payload)
        }
        let log = try RedactedLog(file: temporary.url.appending(path: "service.log"))
        await #expect(throws: XodusServiceError.notReady) {
            try await start(log: log, readinessTimeout: .milliseconds(600))
        }
        try await log.close()
        _ = fake
    }

    @Test func refusesAServiceThatSpeaksAnotherVersionOfTheChannel() async throws {
        let hello = try Xodus_Hello.with { $0.protocol = 1 }.serializedBytes() as Data
        let fake = try FakeService(path: socketPath) { type, _ in (type + 1, hello) }
        let log = try RedactedLog(file: temporary.url.appending(path: "service.log"))
        await #expect(throws: XodusServiceError.unsupportedChannel(1)) {
            try await start(log: log)
        }
        try await log.close()
        _ = fake
    }

    @Test(
        arguments: zip(
            [73, 77, 78, 69] as [UInt8],
            [
                .socketUnavailable, .keychainRefused, .launcherRefused,
                .exitedBeforeReady(.exited(69)),
            ]
                as [XodusServiceError]))
    func namesWhyTheServiceStoppedBeforeItWasReady(status: UInt8, error: XodusServiceError)
        async throws
    {
        let fake = try FakeService(path: socketPath) { _, _ in (0, Data([status])) }
        let log = try RedactedLog(file: temporary.url.appending(path: "service.log"))
        await #expect(throws: error) {
            try await start(log: log)
        }
        try await log.close()
        _ = fake
    }
}

/// The stand-in service, whose fake answers HELLO and PING, and each other request with `reply`.
struct ChannelFixture {
    let temporary: TemporaryDirectory
    let fake: FakeService
    let log: RedactedLog
    let service: XodusService

    init(replies: @escaping @Sendable (_ type: UInt16, _ payload: Data) -> [Data]?) async throws {
        temporary = try TemporaryDirectory()
        fake = try FakeService(readyAt: shortSocketPath(), replies: replies)
        log = try RedactedLog(file: temporary.url.appending(path: "service.log"))
        let executable = try await serviceStandIn.value
        service = try await XodusService.start(
            executable: executable,
            pinnedCDHash: runOnDedicatedThread { try StaticCode(executable).cdhash() },
            keychainService: "dev.macrock.account.test", socketPath: fake.path,
            host: HostEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/"),
            log: log)
    }

    var channel: LauncherChannel { service.channel }

    func stop() async throws {
        await service.stop()
        try await log.close()
    }
}

struct LauncherChannelTests {
    @Test func tellsTheAccountStatus() async throws {
        let status =
            try Xodus_AccountStatusResult.with {
                $0.status = .with {
                    $0.state = .signedIn
                    $0.signInAgain = true
                }
            }.serializedBytes() as Data
        let fixture = try await ChannelFixture { type, _ in type == 206 ? [status] : nil }

        #expect(
            try await fixture.channel.accountStatus()
                == AccountStatus(state: .signedIn, mustSignInAgain: true))
        try await fixture.stop()
    }

    @Test func throwsTheReasonTheServiceGives() async throws {
        func failure(
            _ reason: Xodus_Failure.Reason, status: UInt32 = 0, bytesNeeded: UInt64 = 0
        ) throws -> Data {
            try Xodus_ProfileResult.with {
                $0.failure = .with {
                    $0.reason = reason
                    $0.status = status
                    $0.bytesNeeded = bytesNeeded
                }
            }.serializedBytes()
        }
        let failures = Mutex([
            try failure(.refused, status: 0x8004_8821), try failure(.refused),
            try failure(.keychain), try failure(.notSignedIn),
            try failure(.noSpace, bytesNeeded: 4_600_000_000), try failure(.UNRECOGNIZED(42)),
        ])
        let fixture = try await ChannelFixture { type, _ in
            type == 208 ? [failures.withLock { $0.removeFirst() }] : nil
        }

        for expected in [
            ServiceFailure.refused(status: 0x8004_8821), .refused(status: nil), .keychainRefused,
            .notSignedIn, .noSpace(bytesNeeded: 4_600_000_000), .unknown,
        ] {
            await #expect(throws: expected) { try await fixture.channel.gamertag() }
        }
        try await fixture.stop()
    }

    @Test func aCancelledRequestClosesTheChannel() async throws {
        let fixture = try await ChannelFixture { _, _ in nil }
        let channel = fixture.channel

        let request = Task { try await channel.gamertag() }
        try await Task.sleep(for: .milliseconds(200))
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        await #expect(throws: XodusError.channelClosed) { try await channel.accountStatus() }
        try await fixture.stop()
    }

    @Test func findsThePackageMicrosoftServes() async throws {
        let package =
            try Xodus_PackageResult.with {
                $0.package = .with {
                    $0.version = "1.26.5203.0"
                    $0.size = 2_069_975_040
                }
            }.serializedBytes() as Data
        let request = Mutex<Xodus_Package?>(nil)
        let fixture = try await ChannelFixture { type, payload in
            guard type == 210 else { return nil }
            request.withLock { $0 = try? Xodus_Package(serializedBytes: payload) }
            return [package]
        }

        #expect(
            try await fixture.channel.package(storeID: "9NBLGGH2JHXJ", market: "US")
                == GamePackage(version: "1.26.5203.0", size: 2_069_975_040))
        #expect(request.withLock { $0?.productID } == "9NBLGGH2JHXJ")
        #expect(request.withLock { $0?.market } == "US")
        try await fixture.stop()
    }

    @Test func passesOnTheProgressOfAnInstallThenTheInstalledVersion() async throws {
        let updates = try [
            .progress(.downloading, 600, of: 1000), .progress(.downloading, 1000, of: 1000),
            .progress(.extracting, 400, of: 800), .with { $0.installed.version = "1.26.5203.0" },
        ].map { (update: Xodus_InstallUpdate) in try update.serializedBytes() as Data }
        let staging = Mutex<String?>(nil)
        let fixture = try await ChannelFixture { type, payload in
            guard type == 212 else { return nil }
            staging.withLock { $0 = try? Xodus_Install(serializedBytes: payload).staging }
            return updates
        }
        let reported = Mutex<[InstallProgress]>([])

        let version = try await fixture.channel.install(
            storeID: "9NBLGGH2JHXJ", market: "US", staging: URL(filePath: "/tmp/the staging")
        ) { progress in reported.withLock { $0.append(progress) } }

        #expect(version == "1.26.5203.0")
        #expect(
            reported.withLock { $0 } == [
                InstallProgress(phase: .downloading, done: 600, total: 1000),
                InstallProgress(phase: .downloading, done: 1000, total: 1000),
                InstallProgress(phase: .extracting, done: 400, total: 800),
            ])
        #expect(staging.withLock { $0 } == "/tmp/the staging")
        try await fixture.stop()
    }

    @Test func throwsTheFailureThatEndsAnInstallAndKeepsTheChannel() async throws {
        let updates = try [
            .progress(.downloading, 0, of: 1000),
            .with {
                $0.failure.reason = .noSpace
                $0.failure.bytesNeeded = 4_600_000_000
            },
        ].map { (update: Xodus_InstallUpdate) in try update.serializedBytes() as Data }
        let status =
            try Xodus_AccountStatusResult.with { $0.status.state = .signedIn }.serializedBytes()
            as Data
        let fixture = try await ChannelFixture { type, _ in
            switch type {
            case 212: updates
            case 206: [status]
            default: nil
            }
        }

        await #expect(throws: ServiceFailure.noSpace(bytesNeeded: 4_600_000_000)) {
            try await fixture.channel.install(
                storeID: "9NBLGGH2JHXJ", market: "US", staging: URL(filePath: "/tmp/staging")
            ) { _ in }
        }
        #expect(try await fixture.channel.accountStatus().state == .signedIn)
        try await fixture.stop()
    }

    @Test func cancellingAnInstallClosesTheChannel() async throws {
        let downloading =
            try Xodus_InstallUpdate.progress(.downloading, 0, of: 1000).serializedBytes() as Data
        let fixture = try await ChannelFixture { type, _ in type == 212 ? [downloading] : nil }
        let channel = fixture.channel
        let (started, start) = AsyncStream.makeStream(of: Void.self)

        let install = Task {
            try await channel.install(
                storeID: "9NBLGGH2JHXJ", market: "US", staging: URL(filePath: "/tmp/staging")
            ) { _ in start.yield() }
        }
        for await _ in started { break }
        install.cancel()

        await #expect(throws: CancellationError.self) { try await install.value }
        await #expect(throws: XodusError.channelClosed) { try await channel.accountStatus() }
        try await fixture.stop()
    }
}

extension Xodus_InstallUpdate {
    fileprivate static func progress(
        _ phase: Xodus_InstallProgress.Phase, _ done: UInt64, of total: UInt64
    ) -> Self {
        .with {
            $0.progress.phase = phase
            $0.progress.done = done
            $0.progress.total = total
        }
    }
}
