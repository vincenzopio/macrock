import Foundation

/// Runs the programs of an engine's runtime: `wine` with a Windows program, and `wineserver`.
public struct WineTool: Sendable {
    public let runtime: URL
    let host: HostEnvironment

    public init(runtime: URL, host: HostEnvironment) {
        self.runtime = runtime
        self.host = host
    }

    /// Runs `wine` with a Windows program and waits for it, killing it after `timeout`.
    @discardableResult
    public func run(
        _ arguments: [String], environment: [String: String], output: FileHandle,
        timeout: Duration
    ) async throws -> Termination {
        let program = arguments.first ?? "wine"
        let child = try ChildProcess.run(
            runtime.appending(path: "bin/wine"), arguments: arguments, environment: environment,
            output: output)
        guard let termination = await child.termination(within: timeout) else {
            child.kill()
            _ = await child.termination
            throw WineError.timedOut(program)
        }
        guard termination == .exited(0) else { throw WineError.failed(program, termination) }
        return termination
    }

    /// Waits for the prefix's wineserver to exit, which it does a few seconds after its last
    /// client; after `timeout` it is told to stop.
    public func waitForServer(
        of prefix: WinePrefix, output: FileHandle, timeout: Duration = .seconds(15)
    ) async throws {
        let waiting = try wineserver("-w", prefix: prefix, output: output)
        if await waiting.termination(within: timeout) == nil {
            waiting.kill()
            try await killServer(of: prefix, output: output)
        }
    }

    /// Ends the prefix's wineserver and every Windows process of the prefix. Wine gives them
    /// about ten seconds before it kills them.
    public func killServer(of prefix: WinePrefix, output: FileHandle) async throws {
        let killing = try wineserver("-k", prefix: prefix, output: output)
        _ = await killing.termination(within: .seconds(15))
        if let server = prefix.runningServer() {
            throw WineError.serverStillRunning(server)
        }
    }

    private func wineserver(_ option: String, prefix: WinePrefix, output: FileHandle) throws
        -> ChildProcess
    {
        var environment = host.variables
        environment["WINEPREFIX"] = prefix.url.path
        return try ChildProcess.run(
            runtime.appending(path: "bin/wineserver"), arguments: [option],
            environment: environment, output: output)
    }
}

public enum WineError: Error, Equatable {
    case timedOut(String)
    case failed(String, Termination)
    case serverStillRunning(pid_t)
}
