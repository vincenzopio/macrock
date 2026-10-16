import Foundation

/// A world of an account, a folder of the game user's `minecraftWorlds`.
public struct World: Sendable, Equatable, Identifiable {
    public let folder: URL
    /// The name the game shows; the folder's when its `level.dat` can't be read.
    public let name: String
    public let lastPlayed: Date?
    /// The bytes the world takes on disk.
    public let size: Int64
    public let icon: URL?

    public var id: String { folder.lastPathComponent }

    init(folder: URL) throws {
        self.folder = folder
        let level = LevelData(data: try Data(contentsOf: folder.appending(path: "level.dat")))
        name = level?.name ?? folder.lastPathComponent
        lastPlayed = level?.lastPlayed
        size = try FileManager.default.allocatedSize(of: folder)
        let icon = folder.appending(path: "world_icon.jpeg")
        self.icon = FileManager.default.fileExists(atPath: icon.path) ? icon : nil
    }

    static func isWorld(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "level.dat").path)
    }
}
