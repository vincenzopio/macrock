import Foundation
import LightweightCodeRequirements

/// How a child process ended.
public enum Termination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    init(_ process: Process) {
        self =
            process.terminationReason == .uncaughtSignal
            ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
    }
}

/// A process that receives exactly the environment it is given. Nothing else is inherited from
/// the launcher: not its environment, its standard input or its other file descriptors.
public final class ChildProcess: Sendable {
    public let processIdentifier: Int32
    private let process: Process
    private let ending: Task<Termination, Never>

    /// - Parameters:
    ///   - output: receives standard output, and standard error unless `errors` is given.
    ///   - requirement: enforced by the kernel at exec. A binary that does not satisfy it is
    ///     killed with SIGKILL before it runs; this method still returns normally.
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String],
        currentDirectory: URL? = nil,
        input: FileHandle = .nullDevice,
        output: FileHandle = .nullDevice,
        errors: FileHandle? = nil,
        requirement: LaunchCodeRequirement? = nil
    ) throws -> ChildProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors ?? output
        process.launchRequirement = requirement
        let (exit, ended) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in ended.finish() }
        try process.run()
        return ChildProcess(process: process, exit: exit)
    }

    private init(process: Process, exit: AsyncStream<Void>) {
        self.process = process
        processIdentifier = process.processIdentifier
        ending = Task {
            for await _ in exit {}
            return Termination(process)
        }
    }

    public var termination: Termination {
        get async { await ending.value }
    }

    public var isRunning: Bool { process.isRunning }

    /// How the process ended, or nil if it is still running after `timeout` or the caller is
    /// cancelled first.
    public func termination(within timeout: Duration) async -> Termination? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning {
            guard ContinuousClock.now < deadline else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return nil
            }
        }
        return await termination
    }

    /// Asks the process to stop with SIGINT, then SIGTERM, each followed by `grace` to exit,
    /// and kills it if it is still running.
    public func stop(grace: Duration) async -> Termination {
        interrupt()
        if let termination = await termination(within: grace) { return termination }
        terminate()
        if let termination = await termination(within: grace) { return termination }
        kill()
        return await termination
    }

    private func interrupt() {
        process.interrupt()
    }

    private func terminate() {
        process.terminate()
    }

    public func kill() {
        guard process.isRunning else { return }
        Darwin.kill(processIdentifier, SIGKILL)
    }
}
