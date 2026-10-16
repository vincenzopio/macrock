import Foundation
import Testing

@testable import LauncherCore

struct DataDirectoryTests {
    let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory()
    }

    @Test func keepsTheLatestBackupsMadeBeforeSessionsAndThoseOfRemovals() throws {
        let directory = DataDirectory(root: temporary.url, sockets: temporary.url)
        let account = UUID()
        let folder = directory.backups.appending(path: account.uuidString.lowercased())
        let names = [
            "20261010-090000-removed", "20261011-090000-before-1.26.5203.0",
            "20261012-090000-before-1.26.5203.0", "20261013-090000-before-1.26.5203.0",
            "20261014-090000-before-1.26.5203.0",
        ]
        for name in names {
            try FileManager.default.createDirectory(
                at: folder.appending(path: name), withIntermediateDirectories: true)
        }

        try directory.removeOldLaunchBackups(of: account, keeping: 3)

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [
                "20261010-090000-removed", "20261012-090000-before-1.26.5203.0",
                "20261013-090000-before-1.26.5203.0", "20261014-090000-before-1.26.5203.0",
            ])
    }

    @Test func socketPathUnderTheSystemTemporaryDirectoryFits() throws {
        let path = try DataDirectory.standard.socketPath(named: "5f1a0c3e")
        #expect(path.hasSuffix("/macrock/5f1a0c3e.sock"))
        #expect(path.utf8.count <= 103)
    }

    @Test func refusesASocketPathTooLongForAUnixSocket() {
        let sockets = URL(filePath: "/" + String(repeating: "d", count: 90))
        let directory = DataDirectory(root: temporary.url, sockets: sockets)
        #expect(throws: DataDirectoryError.self) {
            try directory.socketPath(named: "5f1a0c3e")
        }
    }

    @Test func prefixesAreNamedAfterTheAccountID() throws {
        let directory = DataDirectory(root: temporary.url, sockets: temporary.url)
        let account = try #require(UUID(uuidString: "6F2C1D0E-3B4A-4C5D-8E9F-0A1B2C3D4E5F"))
        #expect(
            directory.prefix(for: account).lastPathComponent
                == "6f2c1d0e-3b4a-4c5d-8e9f-0a1b2c3d4e5f")
        #expect(
            directory.prefixLock(for: account).lastPathComponent
                == "6f2c1d0e-3b4a-4c5d-8e9f-0a1b2c3d4e5f.lock")
    }

    @Test func createMakesBothDirectoriesPrivate() throws {
        let sockets = temporary.url.appending(path: "sockets")
        try FileManager.default.createDirectory(
            at: sockets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let directory = DataDirectory(
            root: temporary.url.appending(path: "macrock"), sockets: sockets)

        try directory.create()

        for url in [directory.root, directory.sockets] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.posixPermissions] as? Int == 0o700)
        }
    }
}
