import Foundation

/// A folder with the decrypted files of Minecraft for Windows.
public struct GameFolder: Sendable {
    public static let executable = "Minecraft.Windows.exe"

    public let url: URL
    public let version: String
    public let storeID: String

    public init(url: URL) throws {
        let executable = url.appending(path: Self.executable)
        guard let handle = try? FileHandle(forReadingFrom: executable) else {
            throw GameFolderError.missingExecutable
        }
        guard try handle.read(upToCount: 2) == Data("MZ".utf8) else {
            throw GameFolderError.executableNotDecrypted
        }
        let config = try GameConfig(contentsOf: url.appending(path: "MicrosoftGame.Config"))
        self.url = url
        version = config.version
        storeID = config.storeID
    }

    /// The game's own GameInput redistributable, which a new prefix needs.
    public var gameInputInstaller: URL {
        url.appending(path: "Installers/GameInputRedist.msi")
    }
}

public enum GameFolderError: Error, Equatable {
    case missingExecutable
    case executableNotDecrypted
    case malformedConfig
}

private struct GameConfig {
    let version: String
    let storeID: String

    init(contentsOf file: URL) throws {
        guard let fields = try XMLFields(data: Data(contentsOf: file)),
            let version = fields.attributes["Identity"]?["Version"],
            let storeID = fields.texts["StoreId"]
        else {
            throw GameFolderError.malformedConfig
        }
        self.version = version
        self.storeID = storeID
    }
}
