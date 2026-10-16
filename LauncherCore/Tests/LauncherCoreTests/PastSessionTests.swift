import Foundation
import Testing

@testable import LauncherCore

struct PastSessionTests {
    let temporary: TemporaryDirectory
    let directory: DataDirectory

    init() throws {
        temporary = try TemporaryDirectory()
        directory = DataDirectory(root: temporary.url, sockets: temporary.url)
    }

    func folder(_ name: String, ending: SessionEnding?) throws {
        let folder = directory.sessions.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let ending {
            try JSONEncoder().encode(EndingRecord(ending)).write(
                to: folder.appending(path: "result.json"))
        }
    }

    @Test(arguments: [
        SessionEnding.quit, .crashed(.exited(3)), .crashed(.signaled(SIGSEGV)), .stopped, .forced,
        .failed("notOwned"),
    ])
    func readsBackEveryEnding(ending: SessionEnding) throws {
        let record = try JSONDecoder().decode(
            EndingRecord.self, from: JSONEncoder().encode(EndingRecord(ending)))
        #expect(record.sessionEnding == ending)
    }

    @Test func listsSessionsNewestFirst() throws {
        try folder("20261008-170949-5e55107d", ending: .stopped)
        try folder("20261009-091500-0a1b2c3d", ending: nil)
        try folder("notes", ending: nil)

        let sessions = try directory.pastSessions()

        #expect(
            sessions.map(\.folder.lastPathComponent) == [
                "20261009-091500-0a1b2c3d", "20261008-170949-5e55107d",
            ])
        #expect(sessions.map(\.ending) == [nil, .stopped])
    }

    @Test func hasNoSessionsBeforeTheFirst() throws {
        #expect(try directory.pastSessions().isEmpty)
    }
}
