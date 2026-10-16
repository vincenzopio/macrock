import Foundation

/// A Wine prefix: one account's Windows installation, with its worlds and settings.
public struct WinePrefix: Sendable {
    /// Every Wine process runs in this locale, as in the engine's tests. Wine derives the
    /// prefix's region from it, and the game asks for its license in that region's market.
    public static let locale = "en_US.UTF-8"
    public static let market = "US"

    public let url: URL
    private let serverDirectories: URL

    /// - Parameter serverDirectories: where wineservers keep their sockets and locks, one
    ///   directory per prefix; Wine uses `/tmp/.wine-<uid>`.
    public init(url: URL, serverDirectories: URL = URL(filePath: "/tmp/.wine-\(getuid())")) {
        self.url = url
        self.serverDirectories = serverDirectories
    }

    /// The wineserver running for this prefix, if any. A server holds a write lock on the
    /// `lock` file of its directory, named after the prefix's device and inode, for its whole
    /// life; `wineserver -k` finds it the same way. Wine's other processes leave the launcher's
    /// process tree, so this is how the launcher knows the prefix is still in use.
    public func runningServer() -> pid_t? {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        let directory = String(
            format: "server-%llx-%llx", UInt64(bitPattern: Int64(status.st_dev)), status.st_ino)
        let lock = open(
            serverDirectories.appending(path: "\(directory)/lock").path, O_RDONLY | O_CLOEXEC)
        guard lock >= 0 else { return nil }
        defer { close(lock) }
        var query = flock()
        query.l_type = Int16(F_RDLCK)
        query.l_whence = Int16(SEEK_SET)
        query.l_len = 1
        guard fcntl(lock, F_GETLK, &query) == 0, query.l_type == F_WRLCK else { return nil }
        return query.l_pid
    }

    /// The environment of Wine's own programs on this prefix, as in the engine's tests.
    ///
    /// A wineserver and its clients must agree on `msync`: a client that does not exits at
    /// once. Every program of one server's lifetime uses the same value.
    public func environment(
        host: HostEnvironment, msync: Bool, dllOverrides: String = "mscoree,mshtml="
    ) -> [String: String] {
        var environment = host.variables
        environment["LC_ALL"] = Self.locale
        environment["WINEPREFIX"] = url.path
        environment["WINEARCH"] = "win64"
        environment["WINEDEBUG"] = "-all"
        environment["WINEDLLOVERRIDES"] = dllOverrides
        if msync {
            environment["WINEMSYNC"] = "1"
        }
        return environment
    }
}

extension WinePrefix {
    /// Deletes the prefix, after moving the worlds, packs and settings of every product into
    /// `backup`. Returns whether the prefix had any.
    /// - Parameter user: the user Wine runs as, whose profile holds them.
    func delete(keepingGameDataIn backup: URL, user: String) throws -> Bool {
        var kept = false
        for product in GameProduct.allCases {
            let gameData = gameData(of: product, user: user)
            guard FileManager.default.fileExists(atPath: gameData.path) else { continue }
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: gameData, to: backup.appending(path: gameData.lastPathComponent))
            kept = true
        }
        try FileManager.default.removeItemIfPresent(at: url)
        return kept
    }

    /// Copies the product's worlds, packs and settings into `backup`, as clones that take room
    /// only once either side changes. Returns whether the prefix had them.
    /// - Parameter user: the user Wine runs as, whose profile holds them.
    func copyGameData(of product: GameProduct, into backup: URL, user: String) throws -> Bool {
        let gameData = gameData(of: product, user: user)
        guard FileManager.default.fileExists(atPath: gameData.path) else { return false }
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: gameData, to: backup.appending(path: gameData.lastPathComponent))
        return true
    }

    func gameData(of product: GameProduct, user: String) -> URL {
        url.appending(path: "drive_c/users/\(user)/AppData/Roaming/\(product.dataFolder)")
    }
}
