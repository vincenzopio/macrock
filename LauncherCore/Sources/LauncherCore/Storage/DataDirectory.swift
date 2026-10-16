import Foundation

/// Where the launcher keeps its files: data under Application Support, service sockets under the
/// user's temporary directory, whose path is short enough for a socket address.
public struct DataDirectory: Sendable {
    public static let standard = DataDirectory(
        root: .applicationSupportDirectory.appending(path: "macrock"),
        sockets: .temporaryDirectory.appending(path: "macrock"))

    private static let maximumSocketPathLength =
        MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    public let root: URL
    public let sockets: URL

    public init(root: URL, sockets: URL) {
        self.root = root
        self.sockets = sockets
    }

    public var library: URL { root.appending(path: "library.json") }
    public var engines: URL { root.appending(path: "engine") }
    /// D3DMetal imports, one folder per version.
    public var graphics: URL { root.appending(path: "graphics") }
    public var installations: URL { root.appending(path: "installations") }
    public var prefixes: URL { root.appending(path: "prefixes") }
    public var runs: URL { root.appending(path: "run") }
    public var sessions: URL { root.appending(path: "sessions") }
    /// The logs of account services started outside sessions, to sign accounts in or remove
    /// them.
    var accountLogs: URL { root.appending(path: "account-logs") }
    /// What the launcher kept of accounts' prefixes before deleting them, a folder per account.
    var backups: URL { root.appending(path: "backups") }

    public func prefix(for account: UUID) -> URL {
        prefixes.appending(path: account.uuidString.lowercased())
    }

    public func prefixLock(for account: UUID) -> URL {
        prefixes.appending(path: "\(account.uuidString.lowercased()).lock")
    }

    /// What the launcher kept of the account's worlds, packs and settings.
    public func backups(of account: UUID) -> URL {
        backups.appending(path: account.uuidString.lowercased())
    }

    /// Where an account's worlds, packs and settings go before a session plays an earlier
    /// version of the game on them, which may not read back what a later one wrote.
    func launchBackup(of account: UUID, before version: String) -> URL {
        let time = PastSession.stampFormatter.string(from: .now)
        return backups(of: account).appending(path: "\(time)-before-\(version)")
    }

    /// Deletes all but the latest `count` of the account's backups made before sessions; those
    /// made at its removal stay.
    func removeOldLaunchBackups(of account: UUID, keeping count: Int) throws {
        let folder = backups(of: account)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains("-before-") }
            .sorted(by: >)
        for name in names.dropFirst(count) {
            try FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// Where what the account's prefix held goes when the account is removed now.
    func removalBackup(of account: UUID) -> URL {
        let time = PastSession.stampFormatter.string(from: .now)
        return backups(of: account).appending(path: "\(time)-removed")
    }

    public func socketPath(named name: String) throws -> String {
        let path = sockets.appending(path: "\(name).sock").path
        guard path.utf8.count <= Self.maximumSocketPathLength else {
            throw DataDirectoryError.socketPathTooLong(path)
        }
        return path
    }

    /// Creates the root and the socket directory, or tightens them, so that only the user can
    /// enter them: a service makes its socket private only after it starts listening.
    public func create() throws {
        for directory in [root, sockets] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

public enum DataDirectoryError: Error, Equatable {
    case socketPathTooLong(String)
}
