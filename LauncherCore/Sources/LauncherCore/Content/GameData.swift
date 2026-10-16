import Foundation

/// One product's data in an account's prefix: the game user's worlds and screenshots, and the
/// packs every user of the prefix shares. Changes take the account's lock, which a session holds
/// while the game plays.
public struct GameData: Sendable {
    public let product: GameProduct
    let root: URL
    private let lock: URL

    /// - Parameter user: the user Wine runs as, whose profile holds the data.
    public init(of product: GameProduct, account: UUID, in directory: DataDirectory, user: String) {
        self.product = product
        root = WinePrefix(url: directory.prefix(for: account)).gameData(of: product, user: user)
        lock = directory.prefixLock(for: account)
    }

    /// `com.mojang` of the packs every user of the prefix sees.
    public var shared: URL { root.appending(path: "Users/Shared/games/com.mojang") }

    /// Whether the game has made this data: it does the first time it runs in the prefix.
    public var exists: Bool { FileManager.default.fileExists(atPath: shared.path) }

    /// `com.mojang` of the game's user, with worlds, skins and screenshots; nil until the game
    /// has made it. The game names its folder after the user.
    public func user() throws -> URL? {
        let users = root.appending(path: "Users")
        guard FileManager.default.fileExists(atPath: users.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(atPath: users.path)
            .filter { $0 != "Shared" && !$0.hasPrefix(".") }
            .map { users.appending(path: "\($0)/games/com.mojang") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The worlds, the last played first.
    public func worlds() throws -> [World] {
        guard let folder = try user()?.appending(path: "minecraftWorlds"),
            FileManager.default.fileExists(atPath: folder.path)
        else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        .filter(World.isWorld)
        .map(World.init(folder:))
        .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    /// The packs, by name. Folders that hold no pack the launcher can read are left out, as the
    /// game leaves them out.
    public func packs() throws -> [Pack] {
        try Pack.Kind.allCases.flatMap { kind in
            let folder = shared.appending(path: kind.folder)
            guard FileManager.default.fileExists(atPath: folder.path) else { return [Pack]() }
            return try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
            .compactMap { folder in
                do {
                    return try Pack(folder: folder)
                } catch is ContentError {
                    return nil
                }
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The lines of a `.env` that point Regolith's exports at this product's folders; empty until
    /// the game has made them. Regolith reads the `_PREVIEW` variables for its preview target.
    public func regolithEnvironment() throws -> [String] {
        guard let user = try user(), exists else { return [] }
        let suffix = product == .preview ? "_PREVIEW" : ""
        return [
            "COM_MOJANG_PACKS\(suffix)=\"\(shared.path)\"",
            "COM_MOJANG_WORLDS\(suffix)=\"\(user.path)\"",
        ]
    }

    /// Where the game writes its content logs, one file per start.
    public var logs: URL { root.appending(path: "logs") }

    /// The content log the game changed last, nil before any. A log fills about a minute late.
    public func latestContentLog() throws -> URL? {
        guard FileManager.default.fileExists(atPath: logs.path) else { return nil }
        let key = URLResourceKey.contentModificationDateKey
        return try FileManager.default.contentsOfDirectory(
            at: logs, includingPropertiesForKeys: [key], options: .skipsHiddenFiles
        )
        .filter { $0.lastPathComponent.hasPrefix("ContentLog") }
        .map { ($0, try $0.resourceValues(forKeys: [key]).contentModificationDate ?? .distantPast) }
        .max { $0.1 < $1.1 }?.0
    }

    /// Whether the game's settings have it write its content log; nil until the game has written
    /// its settings. The game rewrites them when it quits.
    public func writesContentLog() throws -> Bool? {
        guard let options = try user()?.appending(path: "minecraftpe/options.txt"),
            FileManager.default.fileExists(atPath: options.path)
        else { return nil }
        let text = String(decoding: try Data(contentsOf: options), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).contains("content_log_file:1")
    }

    /// Adds the world of a `.mcworld` file under a new ID, with the name it has, as the game
    /// does.
    public func importWorld(from file: URL) async throws -> World {
        guard let user = try user() else { throw ContentError.gameNotRunYet }
        let lock = try AccountLock(file: lock)
        defer { withExtendedLifetime(lock) {} }
        let worlds = user.appending(path: "minecraftWorlds")
        try FileManager.default.createDirectory(at: worlds, withIntermediateDirectories: true)
        return try await extracting(file, into: user) { staging in
            guard let world = try Self.root(in: staging, where: World.isWorld) else {
                throw ContentError.notAWorld
            }
            let destination = worlds.appending(path: Self.newWorldID(in: worlds))
            try FileManager.default.moveItem(at: world, to: destination)
            return try World(folder: destination)
        }
    }

    /// Writes the world as a `.mcworld` file, without the metadata macOS adds to archives.
    public func export(_ world: World, to file: URL) async throws {
        let lock = try AccountLock(file: lock)
        defer { withExtendedLifetime(lock) {} }
        try FileManager.default.removeItemIfPresent(at: file)
        try await ditto([
            "-c", "-k", "--norsrc", "--noextattr", "--noacl", world.folder.path, file.path,
        ])
    }

    /// Adds the packs of a `.mcpack` or `.mcaddon` file, which may hold `.mcpack` files of its
    /// own. A pack already there in another version is replaced. Nothing is added unless every
    /// pack in the file can be read.
    public func importPacks(from file: URL) async throws -> [Pack] {
        guard exists else { throw ContentError.gameNotRunYet }
        let lock = try AccountLock(file: lock)
        defer { withExtendedLifetime(lock) {} }
        return try await extracting(file, into: shared) { staging in
            try await extractNestedPacks(in: staging)
            let found = try Self.packFolders(in: staging).map(Pack.init(folder:))
            guard !found.isEmpty else { throw ContentError.notAPack }
            guard Set(found.map(\.uuid)).count == found.count else {
                throw ContentError.duplicatePack
            }
            let installed = try packs()
            return try found.map { pack in
                let folder = shared.appending(path: pack.kind.folder)
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                if let earlier = installed.first(where: { $0.uuid == pack.uuid }) {
                    try FileManager.default.removeItem(at: earlier.folder)
                }
                // A pack at the archive's root is in the staging folder, named for the import.
                let name =
                    pack.folder == staging
                    ? file.deletingPathExtension().lastPathComponent
                    : pack.folder.lastPathComponent
                let destination = Self.unused(name, in: folder)
                try FileManager.default.moveItem(at: pack.folder, to: destination)
                return try Pack(folder: destination)
            }
        }
    }

    @discardableResult
    public func trash(_ world: World) throws -> URL {
        try trash(world.folder)
    }

    @discardableResult
    public func trash(_ pack: Pack) throws -> URL {
        try trash(pack.folder)
    }

    private func trash(_ folder: URL) throws -> URL {
        let lock = try AccountLock(file: lock)
        defer { withExtendedLifetime(lock) {} }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: folder, resultingItemURL: &trashed)
        return (trashed as URL?) ?? folder
    }

    /// Unzips `file` into a staging folder in `parent`, on the same volume so that moving out of
    /// it is a rename, and removes what `work` leaves there. `ditto` keeps `../x` and `/x` entries
    /// inside the folder and writes link entries as files; any link left is still refused.
    private func extracting<Value>(
        _ file: URL, into parent: URL, _ work: (URL) async throws -> Value
    ) async throws -> Value {
        let staging = parent.appending(path: ".macrock-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try await ditto(["-x", "-k", "--noqtn", file.path, staging.path])
            try Self.refuseLinks(in: staging)
            let value = try await work(staging)
            try FileManager.default.removeItemIfPresent(at: staging)
            return value
        } catch {
            // What failed matters more than a leftover, which carries a name the game skips.
            try? FileManager.default.removeItemIfPresent(at: staging)
            throw error
        }
    }

    /// An `.mcaddon` may hold its packs as `.mcpack` files; each is unzipped beside itself.
    private func extractNestedPacks(in folder: URL) async throws {
        let archives = try Self.files(in: folder).filter {
            ["mcpack", "zip"].contains($0.pathExtension.lowercased())
        }
        for archive in archives {
            let destination = archive.deletingPathExtension()
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            try await ditto(["-x", "-k", "--noqtn", archive.path, destination.path])
            try FileManager.default.removeItem(at: archive)
        }
        try Self.refuseLinks(in: folder)
    }

    private func ditto(_ arguments: [String]) async throws {
        let child = try ChildProcess.run(
            URL(filePath: "/usr/bin/ditto"), arguments: arguments,
            environment: HostEnvironment.current.variables)
        guard await child.termination == .exited(0) else { throw ContentError.unreadableArchive }
    }

    private static func files(in folder: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }

    private static func refuseLinks(in folder: URL) throws {
        for file in try files(in: folder) {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw ContentError.unsafeArchive
            }
        }
    }

    /// `folder` when it is what is wanted, or the one folder in it that is: archives made by
    /// zipping a folder hold that folder.
    private static func root(in folder: URL, where isWanted: (URL) -> Bool) throws -> URL? {
        if isWanted(folder) { return folder }
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        guard contents.count == 1, let only = contents.first, isWanted(only) else { return nil }
        return only
    }

    /// The folders with a manifest, outermost first; a pack's own folders are not searched.
    private static func packFolders(in folder: URL) throws -> [URL] {
        if FileManager.default.fileExists(atPath: folder.appending(path: "manifest.json").path) {
            return [folder]
        }
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )
        .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        .flatMap(packFolders(in:))
    }

    /// Eight random bytes in base64, as the game names worlds, without the slash a folder name
    /// can't have.
    private static func newWorldID(in folder: URL) -> String {
        while true {
            let id = Data((0..<8).map { _ in UInt8.random(in: .min ... .max) })
                .base64EncodedString().replacing("/", with: "-")
            if !FileManager.default.fileExists(atPath: folder.appending(path: id).path) {
                return id
            }
        }
    }

    private static func unused(_ name: String, in folder: URL) -> URL {
        var candidate = folder.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(name) \(number)")
            number += 1
        }
        return candidate
    }
}

public enum ContentError: Error, Equatable {
    /// The prefix has no data of the product until the game has run in it once.
    case gameNotRunYet
    case unreadableArchive
    /// The archive holds a link, which could lead out of the game's folders.
    case unsafeArchive
    case notAWorld
    case notAPack
    /// A pack of a kind the launcher doesn't place, given by its module types.
    case unsupportedPack(String)
    /// The file holds two packs with one ID, such as two versions of a pack.
    case duplicatePack
}
