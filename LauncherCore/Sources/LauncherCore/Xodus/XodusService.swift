import Foundation
import LightweightCodeRequirements

/// A running account service, xodus-service: the only process that reads and writes its
/// account's tokens, in the Keychain namespace it is started with. It serves the game on its
/// socket and the launcher on its launcher channel.
final class XodusService: Sendable {
    let socketPath: String
    let channel: LauncherChannel
    private let process: ChildProcess

    /// Starts the service and returns once it answers on its channel and on its socket.
    ///
    /// The binary must be the pinned build: its code directory hash is checked before the
    /// launch, for a clear error, and again by the kernel at exec.
    static func start(
        executable: URL, pinnedCDHash: Data, keychainService: String, socketPath: String,
        host: HostEnvironment, log: RedactedLog, readinessTimeout: Duration = .seconds(60)
    ) async throws -> XodusService {
        guard !keychainService.isEmpty, !socketPath.isEmpty else {
            throw XodusServiceError.missingSetting
        }
        guard
            try await runOnDedicatedThread({ try StaticCode(executable).cdhash() }) == pinnedCDHash
        else {
            throw XodusServiceError.notThePinnedBuild
        }
        var environment = host.variables
        environment["XODUS_SOCKET"] = socketPath
        environment["XODUS_KEYCHAIN_SERVICE"] = keychainService
        environment["XODUS_LOG"] = "xodus_service=info"
        environment["XODUS_LAUNCHER_CHANNEL"] = "stdin"
        let (channel, serviceEnd) = try LauncherChannel.pair()
        let process = try ChildProcess.run(
            executable, environment: environment, input: serviceEnd, output: log.writer,
            requirement: .allOf { CodeDirectoryHash(pinnedCDHash) })
        let service = XodusService(socketPath: socketPath, channel: channel, process: process)
        do {
            // Only the service may hold its end, so that the channel ends when the service exits.
            try serviceEnd.close()
            try await service.waitUntilReady(timeout: readinessTimeout)
        } catch {
            process.kill()
            _ = await process.termination
            service.removeSocket()
            throw error
        }
        return service
    }

    private init(socketPath: String, channel: LauncherChannel, process: ChildProcess) {
        self.socketPath = socketPath
        self.channel = channel
        self.process = process
    }

    var client: XodusClient { XodusClient(socketPath: socketPath) }

    var processIdentifier: Int32 { process.processIdentifier }

    /// Stops the service: SIGINT, which it handles by closing its socket, then SIGTERM and
    /// SIGKILL if it is still running after `grace`.
    @discardableResult
    func stop(grace: Duration = .seconds(5)) async -> Termination {
        let termination = await process.stop(grace: grace)
        removeSocket()
        return termination
    }

    /// The service answers on its channel once it has checked that the launcher is its peer,
    /// and on its socket once it has read the account's credentials, which can wait for the user
    /// to answer a Keychain prompt.
    private func waitUntilReady(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let version: UInt32
        do {
            version = try await withTimeout(timeout) { try await self.channel.hello() }
        } catch XodusError.channelClosed {
            guard let termination = await process.termination(within: .seconds(5)) else {
                throw XodusServiceError.notReady
            }
            throw XodusServiceError(exitedBeforeReady: termination)
        } catch is TimeoutError {
            throw XodusServiceError.notReady
        }
        guard version == LauncherChannel.protocolVersion else {
            throw XodusServiceError.unsupportedChannel(version)
        }
        let probe = XodusClient(socketPath: socketPath, timeout: .seconds(2))
        while ContinuousClock.now < deadline {
            if let termination = await process.termination(within: .milliseconds(250)) {
                throw XodusServiceError(exitedBeforeReady: termination)
            }
            guard FileManager.default.fileExists(atPath: socketPath) else { continue }
            do {
                try await probe.ping()
                return
            } catch {
                continue
            }
        }
        throw XodusServiceError.notReady
    }

    /// A service that stops cleanly removes its socket itself; this covers the other ends. The
    /// socket lives in the launcher's private directory, so a failure leaves nothing exposed.
    private func removeSocket() {
        try? FileManager.default.removeItemIfPresent(at: URL(filePath: socketPath))
    }
}

public enum XodusServiceError: Error, Equatable {
    case missingSetting
    case notThePinnedBuild
    /// The service could not create its socket.
    case socketUnavailable
    /// The Keychain refused the service the account's credentials: the user denied its prompt.
    case keychainRefused
    /// The service did not take the launcher for its peer: one of them is not signed as built.
    case launcherRefused
    case exitedBeforeReady(Termination)
    /// The service speaks another version of the launcher channel's messages.
    case unsupportedChannel(UInt32)
    case notReady
}

extension XodusServiceError {
    /// What the exit status of a service that stopped before it was ready says (sysexits.h).
    init(exitedBeforeReady termination: Termination) {
        switch termination {
        case .exited(73): self = .socketUnavailable
        case .exited(77): self = .keychainRefused
        case .exited(78): self = .launcherRefused
        default: self = .exitedBeforeReady(termination)
        }
    }
}
