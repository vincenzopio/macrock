import Foundation
import SwiftProtobuf
import Synchronization
import Testing

@testable import LauncherCore

/// A session over stand-ins: an ad hoc engine bundle whose `wine` and `wineserver` are scripts,
/// the stand-in account service relaying to a fake service on the session's socket, a game folder
/// with the real GameInput package when `MACROCK_GAME_FOLDER` names one.
struct SessionFixture {
    let temporary: TemporaryDirectory
    let directory: DataDirectory
    let runtime: FakeRuntime
    let plan: SessionPlan
    let account = Account(label: "Main")

    init(
        game behaviour: String, settings: Profile.Settings = Profile.Settings(),
        backingUpGameData: Bool = false,
        openingEditor: Bool = false
    ) async throws {
        temporary = try TemporaryDirectory()
        let sockets = URL.temporaryDirectory.appending(
            path: "lc-\(UInt32.random(in: .min ... .max))")
        try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true)
        directory = DataDirectory(root: temporary.url.appending(path: "macrock"), sockets: sockets)

        let bundle = temporary.url.appending(path: "macrock-engine-0.1.0.bundle")
        runtime = try FakeRuntime(
            at: bundle.appending(path: "Contents/Resources/runtime"),
            calls: temporary.url.appending(path: "calls"),
            behaviours: [
                "wine wineboot": #"mkdir -p "$WINEPREFIX/drive_c/windows/system32""#,
                #"wine G:\Minecraft.Windows.exe"#: behaviour,
                // Wine's taskkill finds the game as soon as its process exists; the fake waits
                // for the game to write its pid.
                "wine taskkill":
                    #"until [ -s "$WINEPREFIX/game.pid" ]; do sleep 0.05; done; "#
                    + #"pid=$(cat "$WINEPREFIX/game.pid"); [ "$2" = /f ] && kill -KILL $pid || kill -TERM $pid"#,
            ])
        let prefixFiles = runtime.url.appending(path: "share/macrock-engine/prefix")
        try FileManager.default.createDirectory(at: prefixFiles, withIntermediateDirectories: true)
        try Data(
            #"{"schema": 1, "revision": 1, "dll_overrides": "mscoree,mshtml=", "game_drive": "g:", "steps": []}"#
                .utf8
        ).write(to: prefixFiles.appending(path: "setup.json"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.macrock.engine", "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "0.1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        try await runTool("/usr/bin/codesign", ["--sign", "-", bundle.path])
        let cdhash = try await runOnDedicatedThread { try StaticCode(bundle).cdhash() }
        let index = try EngineIndex(
            json: Data(releaseIndex(version: "0.1.0", cdhash: cdhash.hexadecimal).utf8))

        let game = try makeGameFolder(in: temporary.url)
        if let realInstaller {
            try FileManager.default.createDirectory(
                at: game.appending(path: "Installers"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: realInstaller, to: game.appending(path: "Installers/GameInputRedist.msi"))
        }
        let service = try await serviceStandIn.value
        let engine = try await runOnDedicatedThread {
            try EngineRuntime(bundle: bundle, index: index)
        }
        let serviceCDHash = try await runOnDedicatedThread { try StaticCode(service).cdhash() }
        plan = SessionPlan(
            id: "5e55107d", account: account,
            engine: engine,
            d3dmetal: D3DMetalPayload(
                lib: temporary.url.appending(path: "gptk/lib"), version: "4.0b2"),
            game: try GameFolder(url: game),
            service: ServiceSetup(
                executable: service, pin: ServicePin(cdhash: serviceCDHash, serviceProtocol: 1),
                directory: directory,
                host: HostEnvironment(
                    home: NSHomeDirectory(), user: NSUserName(),
                    temporaryDirectory: NSTemporaryDirectory())),
            settings: settings, backsUpGameData: backingUpGameData, opensEditor: openingEditor)
    }

    /// The same session for another account, under another name.
    func plan(of account: Account, named id: String) -> SessionPlan {
        SessionPlan(
            id: id, account: account, engine: plan.engine, d3dmetal: plan.d3dmetal,
            game: plan.game, service: plan.service, settings: plan.settings,
            backsUpGameData: plan.backsUpGameData, opensEditor: plan.opensEditor)
    }

    /// A fake service with these license replies, the last one repeated, and this account status,
    /// for the fixture's session unless `session` names another.
    func fakeService(
        licenses: [String], status: Xodus_AccountStatus = .with { $0.state = .signedIn },
        session: String? = nil
    ) throws -> FakeService {
        let replies = Mutex(licenses)
        let status =
            try Xodus_AccountStatusResult.with { $0.status = status }.serializedBytes()
            as Data
        return try FakeService(path: directory.socketPath(named: session ?? plan.id)) {
            type, payload in
            if type == 206 { return (207, status) }
            guard type == 100 else { return (type + 1, payload) }
            let reply = replies.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
            let parts = reply.split(separator: " ")
            let xml =
                "<GameLicenseResponse><Result>\(parts[0])</Result><IsActive>\(parts[1])</IsActive>"
                + "<IsTrial>false</IsTrial><SkuStoreId></SkuStoreId></GameLicenseResponse>"
            return (101, Data(xml.utf8))
        }
    }

    var recorded: [String] {
        get throws { try runtime.recorded }
    }

    var sessionFolder: URL {
        get throws {
            let folders = try FileManager.default.contentsOfDirectory(
                at: directory.sessions, includingPropertiesForKeys: nil)
            return try #require(folders.first)
        }
    }

    func leftovers(of session: SessionPlan? = nil) throws -> [String] {
        let session = session ?? plan
        var left: [String] = []
        if FileManager.default.fileExists(atPath: try directory.socketPath(named: session.id)) {
            left.append("socket")
        }
        if FileManager.default.fileExists(
            atPath: directory.runs.appending(path: "\(session.id).json").path)
        {
            left.append("run record")
        }
        if WinePrefix(url: directory.prefix(for: session.account.id)).runningServer() != nil {
            left.append("wineserver")
        }
        return left
    }
}

/// A game that writes its pid where the fake taskkill finds it, once it handles TERM, and runs
/// until a signal.
private let waitingGame =
    #"trap 'exit 0' TERM; echo $$ > "$WINEPREFIX/game.pid"; while :; do sleep 0.1; done"#

struct GameSessionTests {
    @Test(.enabled(if: realInstaller != nil)) func playsUntilTheGameQuitsAndLeavesNothing()
        async throws
    {
        let fixture = try await SessionFixture(game: "sleep 0.3")
        let service = try fixture.fakeService(licenses: ["0 true"])
        let session = GameSession(plan: fixture.plan)
        let phases = Task {
            var phases: [SessionPhase] = []
            for await phase in session.phases { phases.append(phase) }
            return phases
        }

        let outcome = try await session.run()

        #expect(outcome == .exited(.exited(0)))
        #expect(
            await phases.value == [
                .startingService, .checkingLicense, .preparingPrefix, .launching, .running,
                .stopping,
            ])
        let game = try fixture.recorded.first { $0.hasPrefix(#"wine G:\Minecraft.Windows.exe"#) }
        #expect(
            game?.hasSuffix(
                "WINEMSYNC=1 WINEDLLOVERRIDES=mscoree,mshtml=;d3d12,d3d11,d3d10,dxgi=b;nvapi64=")
                == true)
        #expect(try fixture.leftovers().isEmpty)
        let folder = try fixture.sessionFolder
        let launch = try String(contentsOf: folder.appending(path: "launch.json"), encoding: .utf8)
        #expect(!launch.contains("Main"))
        #expect(!launch.contains(fixture.account.keychainService))
        _ = service
    }

    @Test(.enabled(if: realInstaller != nil)) func backsUpTheWorldsBeforeAKeptCopyPlays()
        async throws
    {
        let fixture = try await SessionFixture(game: "exit 0", backingUpGameData: true)
        let service = try fixture.fakeService(licenses: ["0 true"])
        let world = "Minecraft Bedrock/Users/Shared/games/com.mojang/minecraftWorlds/w/level.dat"
        let level = fixture.directory.prefix(for: fixture.account.id).appending(
            path: "drive_c/users/\(NSUserName())/AppData/Roaming/\(world)")
        try FileManager.default.createDirectory(
            at: level.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("world".utf8).write(to: level)

        _ = try await GameSession(plan: fixture.plan).run()

        let backups = try FileManager.default.contentsOfDirectory(
            at: fixture.directory.backups.appending(
                path: fixture.account.id.uuidString.lowercased()),
            includingPropertiesForKeys: nil)
        let backup = try #require(backups.first)
        #expect(backups.count == 1)
        #expect(backup.lastPathComponent.hasSuffix("-before-1.26.5203.0"))
        #expect(
            try String(contentsOf: backup.appending(path: world), encoding: .utf8) == "world")
        #expect(try String(contentsOf: level, encoding: .utf8) == "world")
        _ = service
    }

    @Test(.enabled(if: realInstaller != nil)) func opensTheEditorWhenAsked() async throws {
        let fixture = try await SessionFixture(
            game: #"[ "$2" = "minecraft://creator/?Editor=true" ]"#, openingEditor: true)
        let service = try fixture.fakeService(licenses: ["0 true"])

        let outcome = try await GameSession(plan: fixture.plan).run()

        #expect(outcome == .exited(.exited(0)))
        let launch = try String(
            contentsOf: try fixture.sessionFolder.appending(path: "launch.json"), encoding: .utf8)
        #expect(launch.contains(#""editor" : true"#))
        _ = service
    }

    @Test(.enabled(if: realInstaller != nil)) func runsTheGameWithTheProfilesSettings() async throws
    {
        var settings = Profile.Settings()
        settings.usesMsync = false
        settings.usesRetinaMode = true
        settings.writesFPSLog = false
        let fixture = try await SessionFixture(
            game: #"[ -z "${MACROCK_FPS_LOG:-}" ]"#, settings: settings)
        let service = try fixture.fakeService(licenses: ["0 true"])

        let outcome = try await GameSession(plan: fixture.plan).run()

        #expect(outcome == .exited(.exited(0)))
        let calls = try fixture.recorded
        let retina = try #require(calls.firstIndex { $0.contains("/v RetinaMode") })
        let game = try #require(
            calls.firstIndex { $0.hasPrefix(#"wine G:\Minecraft.Windows.exe"#) })
        #expect(retina < game)
        #expect(calls[retina].contains("/d y /f"))
        #expect(calls[game].contains("WINEMSYNC=unset"))
        _ = service
    }

    @Test(.enabled(if: realInstaller != nil)) func stopAsksTheGameToClose() async throws {
        let fixture = try await SessionFixture(game: waitingGame)
        let service = try fixture.fakeService(licenses: ["0 true"])
        let session = GameSession(plan: fixture.plan, closeGrace: .seconds(2))
        let running = Task {
            for await phase in session.phases where phase == .running { return true }
            return false
        }
        let outcome = Task { try await session.run() }
        #expect(await running.value)

        await session.requestStop()

        #expect(try await outcome.value == .stopped)
        #expect(try fixture.leftovers().isEmpty)
        _ = service
    }

    @Test(.enabled(if: realInstaller != nil)) func stopEndsAGameThatIgnoresTheCloseRequest()
        async throws
    {
        let fixture = try await SessionFixture(
            game: #"trap '' TERM; echo $$ > "$WINEPREFIX/game.pid"; while :; do sleep 0.1; done"#)
        let service = try fixture.fakeService(licenses: ["0 true"])
        let session = GameSession(plan: fixture.plan, closeGrace: .milliseconds(500))
        let running = Task {
            for await phase in session.phases where phase == .running { return true }
            return false
        }
        let outcome = Task { try await session.run() }
        #expect(await running.value)

        await session.requestStop()

        #expect(try await outcome.value == .forced)
        #expect(try fixture.leftovers().isEmpty)
        _ = service
    }

    @Test(.enabled(if: realInstaller != nil)) func stopBeforeTheGameStartsEndsTheSession()
        async throws
    {
        let fixture = try await SessionFixture(game: waitingGame)
        let service = try fixture.fakeService(licenses: ["0 true"])
        let session = GameSession(plan: fixture.plan)
        let preparing = Task {
            for await phase in session.phases where phase == .preparingPrefix { return true }
            return false
        }
        let outcome = Task { try await session.run() }
        #expect(await preparing.value)

        await session.requestStop()

        #expect(try await outcome.value == .stopped)
        #expect(try !fixture.recorded.contains { $0.hasPrefix(#"wine G:\Minecraft.Windows.exe"#) })
        #expect(try fixture.leftovers().isEmpty)
        _ = service
    }

    @Test(.enabled(if: realInstaller != nil)) func twoAccountsPlayAtOnceAndStopApart() async throws
    {
        let fixture = try await SessionFixture(game: waitingGame)
        let secondPlan = fixture.plan(of: Account(label: "Second"), named: "0a4e7b2c")
        let services = (
            try fixture.fakeService(licenses: ["0 true"]),
            try fixture.fakeService(licenses: ["0 true"], session: secondPlan.id)
        )
        let first = GameSession(plan: fixture.plan, closeGrace: .seconds(2))
        let second = GameSession(plan: secondPlan, closeGrace: .seconds(2))
        let running = Task {
            for await phase in first.phases where phase == .running { break }
            for await phase in second.phases where phase == .running { return true }
            return false
        }
        let outcomes = (Task { try await first.run() }, Task { try await second.run() })
        #expect(await running.value)

        await first.requestStop()

        #expect(try await outcomes.0.value == .stopped)
        #expect(try fixture.leftovers().isEmpty)
        let pidFile = fixture.directory.prefix(for: secondPlan.account.id).appending(
            path: "game.pid")
        let secondGame = try #require(
            Int32(
                try String(contentsOf: pidFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(secondGame, 0) == 0)

        await second.requestStop()

        #expect(try await outcomes.1.value == .stopped)
        #expect(try fixture.leftovers(of: secondPlan).isEmpty)
        _ = services
    }

    @Test func refusesAnAccountWithoutTheGame() async throws {
        let fixture = try await SessionFixture(game: "exit 0")
        let service = try fixture.fakeService(licenses: ["0 false"])

        await #expect(throws: SessionError.notOwned) {
            try await GameSession(plan: fixture.plan).run()
        }

        #expect(try fixture.recorded.isEmpty)
        #expect(try fixture.leftovers().isEmpty)
        let result = try String(
            contentsOf: try fixture.sessionFolder.appending(path: "result.json"), encoding: .utf8)
        #expect(result.contains("notOwned"))
        _ = service
    }

    @Test func recordsASessionWhoseServiceDidNotStart() async throws {
        let fixture = try await SessionFixture(game: "exit 0")
        let service = try FakeService(path: fixture.directory.socketPath(named: fixture.plan.id)) {
            _, _ in (0, Data([77]))
        }

        await #expect(throws: XodusServiceError.keychainRefused) {
            try await GameSession(plan: fixture.plan).run()
        }

        #expect(try fixture.directory.pastSessions().map(\.ending) == [.failed("keychainRefused")])
        #expect(try fixture.leftovers().isEmpty)
        _ = service
    }

    @Test(arguments: [
        (["2147500037 false", "0 false"], SessionError.notOwned),
        (["2147500037 false", "2147500037 false", "0 false"], .licenseUnknown(0x8000_4005)),
    ])
    func asksAgainOnceWhenTheServiceCannotTell(licenses: [String], error: SessionError)
        async throws
    {
        let fixture = try await SessionFixture(game: "exit 0")
        let service = try fixture.fakeService(licenses: licenses)

        await #expect(throws: error) { try await GameSession(plan: fixture.plan).run() }
        _ = service
    }

    @Test(arguments: [
        Xodus_AccountStatus.with {
            $0.state = .signedIn
            $0.signInAgain = true
        },
        .with { $0.state = .deviceOnly },
        .with { $0.state = .empty },
    ])
    func asksToSignInAgainWhenTheServiceHasNoUsableSignIn(status: Xodus_AccountStatus)
        async throws
    {
        let fixture = try await SessionFixture(game: "exit 0")
        let service = try fixture.fakeService(
            licenses: ["2147500037 false", "0 true"], status: status)

        await #expect(throws: SessionError.signInAgain) {
            try await GameSession(plan: fixture.plan).run()
        }
        #expect(try fixture.recorded.isEmpty)
        _ = service
    }

    @Test func refusesASecondSessionOfTheAccount() async throws {
        let fixture = try await SessionFixture(game: "exit 0")
        try FileManager.default.createDirectory(
            at: fixture.directory.prefixes, withIntermediateDirectories: true)
        let lock = try AccountLock(file: fixture.directory.prefixLock(for: fixture.account.id))

        await #expect(throws: SessionError.alreadyRunning) {
            try await GameSession(plan: fixture.plan).run()
        }
        withExtendedLifetime(lock) {}
    }

    @Test func refusesAPrefixWhoseServerStillRuns() async throws {
        let fixture = try await SessionFixture(game: "exit 0")
        let prefix = fixture.directory.prefix(for: fixture.account.id)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let holder = try await ServerLockHolder(prefix: prefix)
        defer { holder.release() }

        await #expect(throws: SessionError.prefixInUse(holder.process.processIdentifier)) {
            try await GameSession(plan: fixture.plan).run()
        }
    }
}
