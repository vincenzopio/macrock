import Foundation
import LauncherCore
import Testing

struct RedactedLogTests {
    let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    func write(_ text: String, to log: RedactedLog) async throws {
        try log.writer.write(contentsOf: Data(text.utf8))
        try await log.close()
    }

    @Test func writesRedactedLines() async throws {
        let file = directory.url.appending(path: "game.log")
        let log = try RedactedLog(file: file)

        try await write("ticket t=EwAoA+pvBAAUKods17HmdQZ6\nplain line\nno final newline", to: log)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == "ticket t=<redacted>\nplain line\nno final newline\n")
    }

    @Test func dropsTerminalColoursAndCarriageReturns() async throws {
        let file = directory.url.appending(path: "service.log")
        let log = try RedactedLog(file: file)

        try await write("\u{1B}[32m INFO\u{1B}[0m ready\r\n", to: log)

        #expect(try String(contentsOf: file, encoding: .utf8) == " INFO ready\n")
    }

    @Test func dropsOutputPastTheLimit() async throws {
        let file = directory.url.appending(path: "game.log")
        let log = try RedactedLog(file: file, limit: 20)

        try await write(String(repeating: "0123456789\n", count: 5), to: log)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == "0123456789\n[truncated after 20 bytes]\n")
    }

    @Test func cutsALineLongerThanTheLimitWithoutWaitingForItsEnd() async throws {
        let file = directory.url.appending(path: "game.log")
        let log = try RedactedLog(file: file, limit: 20)

        try log.writer.write(contentsOf: Data(String(repeating: "0123456789", count: 5).utf8))
        let deadline = ContinuousClock.now + .seconds(2)
        while try String(contentsOf: file, encoding: .utf8).isEmpty, .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(try String(contentsOf: file, encoding: .utf8) == "[truncated after 20 bytes]\n")
        try await log.close()
    }

    @Test func createsAPrivateFile() async throws {
        let file = directory.url.appending(path: "service.log")
        let log = try RedactedLog(file: file)

        try await write("", to: log)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func neverOverwritesAnExistingFile() throws {
        let file = directory.url.appending(path: "game.log")
        try Data("earlier session".utf8).write(to: file)

        #expect(throws: POSIXError.self) {
            try RedactedLog(file: file)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "earlier session")
    }
}
