import Foundation
import os

/// One play session of one account: its service, its prefix and the game, from start to the
/// moment nothing of them is left running.
public actor GameSession {
    public nonisolated let phases: AsyncStream<SessionPhase>
    private let folder: SessionFolder
    private let phase: AsyncStream<SessionPhase>.Continuation
    private let plan: SessionPlan
    private let prefix: WinePrefix
    private let tool: WineTool
    private var running: (game: ChildProcess, launch: GameLaunch, log: RedactedLog)?
    private var stop: StopRequest?
    private let closeGrace: Duration

    private enum StopRequest {
        case gentle, forced
    }

    public init(plan: SessionPlan) {
        self.init(plan: plan, closeGrace: .seconds(10))
    }

    /// - Parameter closeGrace: how long the game has to close when asked, before it is ended.
    init(plan: SessionPlan, closeGrace: Duration) {
        self.plan = plan
        self.closeGrace = closeGrace
        folder = SessionFolder(plan: plan, start: .now)
        prefix = WinePrefix(url: plan.directory.prefix(for: plan.account.id))
        tool = WineTool(runtime: plan.engine.runtime, host: plan.host)
        (phases, phase) = AsyncStream.makeStream()
    }

    /// The session's logs and records, which may be attached to a bug report.
    public nonisolated var logs: URL { folder.url }

    /// Runs the session to its end. It returns once the game has exited and the prefix's
    /// wineserver and the account's service have stopped.
    public func run() async throws -> SessionOutcome {
        defer { phase.finish() }
        return try await plan.account.withLock(in: plan.directory) {
            if let server = prefix.runningServer() { throw SessionError.prefixInUse(server) }

            try folder.create()
            let record = plan.directory.runs.appending(path: "\(plan.id).json")
            let outcome: Result<SessionOutcome, any Error>
            do {
                let serviceLog = try RedactedLog(
                    file: folder.url.appending(path: "service.log"),
                    knownValues: folder.knownValues)
                phase.yield(.startingService)
                outcome = .success(
                    try await plan.account.withService(
                        plan.service, named: plan.id, log: serviceLog
                    ) { service in
                        try RunRecord(service: service, prefix: prefix).write(to: record)
                        return try await play(service: service, folder: folder)
                    })
            } catch {
                outcome = .failure(error)
            }
            try FileManager.default.removeItemIfPresent(at: record)
            try folder.writeResult(outcome)
            return try outcome.get()
        }
    }

    /// Ends the game: first by asking it to close, as its window's close button does; then by
    /// ending its process, for a game held by a dialog; and last by ending the prefix's server.
    /// Before the game has started, the session ends instead of starting it.
    public func requestStop() async {
        guard stop == nil else { return }
        stop = .gentle
        phase.yield(.stopping)
        guard let running else { return }
        await taskkill([], launch: running.launch, log: running.log)
        if await running.game.termination(within: closeGrace) != nil { return }
        stop = .forced
        await taskkill(["/f"], launch: running.launch, log: running.log)
        if await running.game.termination(within: closeGrace) != nil { return }
        do {
            try await tool.killServer(of: prefix, output: running.log.writer)
        } catch {
            Logger.session.error("The prefix's server did not stop: \(error)")
        }
    }

    private func play(service: XodusService, folder: SessionFolder) async throws -> SessionOutcome {
        phase.yield(.checkingLicense)
        try await checkLicense(with: service)

        phase.yield(.preparingPrefix)
        let prefixLog = try RedactedLog(file: folder.url.appending(path: "prefix.log"))
        do {
            try await prefix.prepare(
                setup: plan.engine.prefixSetup, engine: plan.engine.identity, game: plan.game,
                retinaMode: plan.settings.usesRetinaMode, tool: tool, output: prefixLog.writer)
            try await prefix.installGameInput(from: plan.game, tool: tool, output: prefixLog.writer)
        } catch {
            await stopPrefix()
            try? await prefixLog.close()
            throw error
        }
        try await prefixLog.close()
        if stop != nil { return .stopped }
        if plan.backsUpGameData, let product = GameProduct(storeID: plan.game.storeID) {
            let backup = plan.directory.launchBackup(of: plan.account.id, before: plan.game.version)
            if try prefix.copyGameData(of: product, into: backup, user: plan.host.user) {
                try plan.directory.removeOldLaunchBackups(of: plan.account.id, keeping: 3)
            }
        }

        phase.yield(.launching)
        let launch = GameLaunch(
            wine: plan.engine.wine, setup: plan.engine.prefixSetup,
            prefix: prefix, d3dmetal: plan.d3dmetal, game: plan.game,
            activation: plan.opensEditor
                ? GameProduct(storeID: plan.game.storeID)?.editorActivation : nil,
            socketPath: service.socketPath, settings: plan.settings,
            titleSuffix: " (\(plan.account.label))",
            fpsLog: plan.settings.writesFPSLog ? folder.url.appending(path: "fps.log") : nil,
            host: plan.host)
        let gameLog = try RedactedLog(
            file: folder.url.appending(path: "game.log"), knownValues: folder.knownValues)
        let game = try ChildProcess.run(
            launch.executable, arguments: launch.arguments, environment: launch.environment,
            currentDirectory: launch.currentDirectory, output: gameLog.writer)
        running = (game, launch, gameLog)
        phase.yield(.running)

        let termination = await game.termination
        if stop == nil { phase.yield(.stopping) }
        try await tool.waitForServer(of: prefix, output: gameLog.writer)
        try await gameLog.close()
        running = nil
        switch stop {
        case .gentle: return .stopped
        case .forced: return .forced
        case nil: return .exited(termination)
        }
    }

    /// After a failure, the prefix's server may still run a program that was cut short.
    private func stopPrefix() async {
        do {
            try await tool.waitForServer(of: prefix, output: .nullDevice)
        } catch {
            Logger.session.error("The prefix's server did not stop: \(error)")
        }
    }

    /// The game asks for its license in the market of the prefix's region; so does this check.
    /// A service that cannot find out answers E_FAIL, also when the network blinked: one retry,
    /// unless the account must sign in first.
    private func checkLicense(with service: XodusService) async throws {
        var license = try await service.client.gameLicense(
            storeID: plan.game.storeID, market: WinePrefix.market)
        if case .unknown = license {
            try await requireSignedIn(service.channel)
            license = try await service.client.gameLicense(
                storeID: plan.game.storeID, market: WinePrefix.market)
        }
        switch license {
        case .active: return
        case .inactive: throw SessionError.notOwned
        case .unknown(let result):
            try await requireSignedIn(service.channel)
            throw SessionError.licenseUnknown(result)
        }
    }

    /// E_FAIL also means that the service has no signed-in user, or that Microsoft refused the
    /// user's token; only the service can tell.
    private func requireSignedIn(_ channel: LauncherChannel) async throws {
        let status = try await channel.accountStatus()
        guard status.state == .signedIn, !status.mustSignInAgain else {
            throw SessionError.signInAgain
        }
    }

    private func taskkill(_ options: [String], launch: GameLaunch, log: RedactedLog) async {
        do {
            try await tool.run(
                ["taskkill"] + options + ["/im", GameFolder.executable],
                environment: launch.environment, output: log.writer, timeout: .seconds(10))
        } catch {
            Logger.session.error("taskkill \(options) failed: \(error)")
        }
    }
}

public enum SessionPhase: Sendable, Equatable {
    case startingService
    case checkingLicense
    case preparingPrefix
    case launching
    case running
    case stopping
}

public enum SessionOutcome: Sendable, Equatable {
    /// The game ended by itself: the player quit, or it crashed.
    case exited(Termination)
    /// The game closed when asked to.
    case stopped
    /// The game had to be ended.
    case forced
}

public enum SessionError: Error, Equatable {
    /// Another session of the account is running, in this launcher or another.
    case alreadyRunning
    /// Wine processes of the account's prefix are still running from an earlier session.
    case prefixInUse(pid_t)
    case unsupportedD3DMetal(found: String, required: String)
    case notOwned
    /// The account has no signed-in user, or Microsoft refused its sign-in.
    case signInAgain
    /// The account service could not tell whether the account owns the game.
    case licenseUnknown(UInt32)
}
