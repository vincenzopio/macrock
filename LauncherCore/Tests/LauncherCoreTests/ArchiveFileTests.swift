import Foundation
import Testing

@testable import LauncherCore

struct ArchiveFileTests {
    let temporary: TemporaryDirectory
    let inside: URL
    let outside: URL

    init() throws {
        temporary = try TemporaryDirectory()
        inside = temporary.url.appending(path: "inside")
        outside = temporary.url.appending(path: "outside")
        for folder in [inside, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        try Data("kept".utf8).write(to: outside.appending(path: "kept.txt"))
    }

    func archive(_ entries: [ArchiveEntry]) throws -> ArchiveFile {
        try ArchiveFile.make(at: temporary.url.appending(path: "test.aar"), entries)
    }

    func outsideIsUntouched() throws -> Bool {
        let names = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        let kept = try String(contentsOf: outside.appending(path: "kept.txt"), encoding: .utf8)
        return names == ["kept.txt"] && kept == "kept"
    }

    @Test func extractsDirectoriesFilesAndLinks() throws {
        try archive([
            .directory("b"), .file("b/run", "#!/bin/sh\n", mode: 0o755),
            .link("b/start", to: "run"),
        ]).extract(into: inside)
        let run = inside.appending(path: "b/run")
        #expect(try String(contentsOf: run, encoding: .utf8) == "#!/bin/sh\n")
        #expect(FileManager.default.isExecutableFile(atPath: run.path))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: inside.appending(path: "b/start").path) == "run")
    }

    @Test func refusesEntriesOutsideTheFolder() throws {
        let paths = [
            "../outside/escaped.txt", "b/../../outside/escaped.txt",
            outside.appending(path: "escaped.txt").path,
        ]
        for path in paths {
            let archive = try archive([.directory("b"), .file(path, "escaped")])
            #expect(throws: ReleaseError.unreadableArchive) { try archive.extract(into: inside) }
        }
        #expect(try outsideIsUntouched())
    }

    @Test(arguments: ["b/a", "b/A"])
    func neverWritesThroughALink(named link: String) throws {
        let archive = try archive([
            .directory("b"), .link(link, to: outside.path), .file("b/a/escaped.txt", "escaped"),
        ])
        #expect(throws: ReleaseError.unreadableArchive) { try archive.extract(into: inside) }
        #expect(try outsideIsUntouched())
    }

    @Test func neverWritesOverALink() throws {
        let archive = try archive([
            .directory("b"), .link("b/kept.txt", to: outside.appending(path: "kept.txt").path),
            .file("b/kept.txt", "overwritten"),
        ])
        #expect(throws: ReleaseError.unreadableArchive) { try archive.extract(into: inside) }
        #expect(try outsideIsUntouched())
    }

    @Test func skipsAFIFOInsteadOfWaitingForAReader() throws {
        try archive([.directory("b"), .fifo("b/pipe"), .file("b/after.txt", "after")])
            .extract(into: inside)
        #expect(!FileManager.default.fileExists(atPath: inside.appending(path: "b/pipe").path))
        #expect(FileManager.default.fileExists(atPath: inside.appending(path: "b/after.txt").path))
    }

    @Test func leavesOutOwnerFlagsAndQuarantine() throws {
        try archive([.directory("b"), .lockedFile("b/locked.txt")]).extract(into: inside)
        let file = inside.appending(path: "b/locked.txt")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.ownerAccountID] as? UInt32 == getuid())
        #expect(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
        try FileManager.default.removeItem(at: file)
    }
}
