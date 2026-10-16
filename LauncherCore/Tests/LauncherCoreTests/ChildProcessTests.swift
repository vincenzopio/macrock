import Foundation
import LauncherCore
import LightweightCodeRequirements
import Testing

struct ChildProcessTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    /// Runs a child to its end, returning how it ended and what it wrote.
    func run(
        _ executable: String, _ arguments: [String] = [], environment: [String: String] = [:],
        requirement: LaunchCodeRequirement? = nil
    ) async throws -> (Termination, String) {
        let file = directory.url.appending(path: "\(UUID()).log")
        let log = try RedactedLog(file: file)
        let child = try ChildProcess.run(
            URL(filePath: executable), arguments: arguments, environment: environment,
            output: log.writer, requirement: requirement)
        let termination = await child.termination
        try await log.close()
        return (termination, try String(contentsOf: file, encoding: .utf8))
    }

    @Test func reportsTheExitStatus() async throws {
        let (termination, _) = try await run("/bin/sh", ["-c", "exit 3"])
        #expect(termination == .exited(3))
    }

    @Test func passesExactlyTheGivenEnvironment() async throws {
        let environment = ["PATH": "/usr/bin:/bin", "WINEPREFIX": "/tmp/prefix"]
        let (_, output) = try await run("/usr/bin/env", environment: environment)
        #expect(
            Set(output.split(separator: "\n")) == ["PATH=/usr/bin:/bin", "WINEPREFIX=/tmp/prefix"])
    }

    @Test func inheritsNoOtherDescriptor() async throws {
        let extra = open("/dev/null", O_RDONLY)
        defer { close(extra) }
        let script = "for fd in 3 4 5 6 7 8 9 \(extra); do (: <&$fd) 2>/dev/null && echo $fd; done"
        let (_, output) = try await run("/bin/sh", ["-c", script])
        #expect(output == "")
    }

    @Test func readsNothingFromTheLaunchersInput() async throws {
        let (termination, output) = try await run("/bin/cat")
        #expect(termination == .exited(0))
        #expect(output == "")
    }

    @Test func stopEndsAChildWithSIGINT() async throws {
        let child = try ChildProcess.run(
            URL(filePath: "/bin/sleep"), arguments: ["30"], environment: [:])
        #expect(await child.stop(grace: .seconds(5)) == .signaled(SIGINT))
    }

    @Test func stopKillsAChildThatIgnoresSIGINTAndSIGTERM() async throws {
        let child = try ChildProcess.run(
            URL(filePath: "/bin/sh"), arguments: ["-c", "trap '' INT TERM; exec sleep 30"],
            environment: [:])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await child.stop(grace: .milliseconds(200)) == .signaled(SIGKILL))
    }

    @Test func requirementMismatchKillsTheChildAtExec() async throws {
        let requirement = try LaunchCodeRequirement.allOf {
            CodeDirectoryHash(Data(repeating: 0, count: 20))
        }
        let (termination, _) = try await run("/usr/bin/true", requirement: requirement)
        #expect(termination == .signaled(SIGKILL))
    }
}
