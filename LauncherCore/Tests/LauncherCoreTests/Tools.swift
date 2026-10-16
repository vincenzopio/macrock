import Foundation
import LauncherCore

/// Runs a command-line tool to its end and returns its output; a nonzero exit fails the test.
@discardableResult
func runTool(_ path: String, _ arguments: [String]) async throws -> String {
    let directory = try TemporaryDirectory()
    let file = directory.url.appending(path: "output")
    let log = try RedactedLog(file: file)
    let child = try ChildProcess.run(
        URL(filePath: path), arguments: arguments, environment: ["PATH": "/usr/bin:/bin"],
        output: log.writer)
    let termination = await child.termination
    try await log.close()
    let output = try String(contentsOf: file, encoding: .utf8)
    guard termination == .exited(0) else {
        throw ToolFailure(tool: path, termination: termination, output: output)
    }
    return output
}

struct ToolFailure: Error {
    let tool: String
    let termination: Termination
    let output: String
}
