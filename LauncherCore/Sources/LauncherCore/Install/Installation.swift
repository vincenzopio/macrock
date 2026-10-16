import Foundation

/// A copy of the game the launcher installed, in `installations/<id>/`: the game's files in
/// `game`, and what the launcher knows of them in `installation.json`, written last.
public struct Installation: Sendable, Equatable, Identifiable {
    fileprivate static let recordFile = "installation.json"

    public let id: UUID
    public let folder: URL
    public let product: GameProduct
    /// The game's version, such as 1.26.5203.0.
    public let version: String
    public let installed: Date
    /// The bytes the game's files take on disk.
    public let size: Int64
    /// When the player agreed to install a package whose origin can't be verified: the service
    /// checks its pages only against the package's own hashes.
    public let consented: Date
    /// The identity of the engine the game last ran on; nil until it has run.
    public fileprivate(set) var lastEngine: String?

    public var game: URL { folder.appending(path: "game") }

    /// Whether the game's program is still in `game`, unchecked: sessions check the game's files.
    public var hasGame: Bool {
        FileManager.default.fileExists(atPath: game.appending(path: GameFolder.executable).path)
    }

    fileprivate init(
        id: UUID, folder: URL, product: GameProduct, version: String, installed: Date,
        size: Int64, consented: Date, lastEngine: String?
    ) {
        self.id = id
        self.folder = folder
        self.product = product
        self.version = version
        self.installed = installed
        self.size = size
        self.consented = consented
        self.lastEngine = lastEngine
    }

    /// Reads the installation in `folder`, or returns nil when its record is missing or can't be
    /// read, as one from a newer launcher.
    fileprivate init?(folder: URL) {
        guard let id = UUID(uuidString: folder.lastPathComponent),
            let data = try? Data(contentsOf: folder.appending(path: Self.recordFile)),
            let record = try? JSONDecoder().decode(Record.self, from: data),
            record.schema <= Record.currentSchema
        else { return nil }
        self.init(
            id: id, folder: folder, product: record.product ?? .release, version: record.version,
            installed: record.installed, size: record.size, consented: record.consented,
            lastEngine: record.lastEngine)
    }

    fileprivate func writeRecord() throws {
        let record = Record(
            product: product, version: version, installed: installed, size: size,
            consented: consented, lastEngine: lastEngine)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(
            to: folder.appending(path: Self.recordFile), options: .atomic)
    }

    private struct Record: Codable {
        /// Schema 1 records had neither the product, only Release then, nor the engine.
        static let currentSchema = 2

        var schema = currentSchema
        let product: GameProduct?
        let version: String
        let installed: Date
        let size: Int64
        let consented: Date
        let lastEngine: String?
    }
}

/// The games the launcher installed, in `installations/`, a folder each.
public struct InstallationStore: Sendable {
    public let root: URL

    public init(in directory: DataDirectory) {
        root = directory.installations
    }

    /// Where the account service downloads a product and extracts it: beside the installations,
    /// so that the game moves into one with a rename. A stopped install leaves its download
    /// there for the next one to go on with; each product has its own, since the service removes
    /// the downloads of other versions.
    func staging(for product: GameProduct) -> URL {
        root.appending(path: ".staging/\(product.rawValue)")
    }

    /// The installations, the newest first.
    public func installations() throws -> [Installation] {
        try folders()
            .compactMap(Installation.init(folder:))
            .sorted { $0.installed > $1.installed }
    }

    /// Makes the game the service extracted into the product's staging folder an installation,
    /// on a thread of its own, once its executable carries a valid Microsoft signature: the
    /// download only proves that the package matches its own hashes.
    public func addStagedGame(of product: GameProduct, consented: Date) async throws -> Installation
    {
        try await runOnDedicatedThread { [self] in
            let staged = staging(for: product).appending(path: "game")
            try WindowsProgram(url: staged.appending(path: GameFolder.executable))
                .checkSignedByMicrosoft()
            return try adopt(staged, of: product, consented: consented)
        }
    }

    func adopt(_ staged: URL, of product: GameProduct, consented: Date) throws -> Installation {
        let game = try GameFolder(url: staged)
        let id = UUID()
        let folder = root.appending(path: id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let installation = Installation(
            id: id, folder: folder, product: product, version: game.version, installed: .now,
            size: try FileManager.default.allocatedSize(of: staged), consented: consented,
            lastEngine: nil)
        try FileManager.default.moveItem(at: staged, to: installation.game)
        try installation.writeRecord()
        return installation
    }

    public func noteRun(
        of installation: Installation, on engine: String
    ) throws -> Installation {
        var installation = installation
        installation.lastEngine = engine
        try installation.writeRecord()
        return installation
    }

    /// Deletes an installation, on a thread of its own. Its record goes first, so a deletion cut
    /// short leaves a folder that is no longer an installation.
    public func delete(_ installation: Installation) async throws {
        try await runOnDedicatedThread {
            let manager = FileManager.default
            try manager.removeItem(at: installation.folder.appending(path: Installation.recordFile))
            try manager.removeItem(at: installation.folder)
        }
    }

    /// Deletes what installs and deletions cut short left: folders without a record. Those whose
    /// record a newer launcher wrote stay.
    public func removeUnfinished() async throws {
        let unfinished = try folders().filter {
            !FileManager.default.fileExists(
                atPath: $0.appending(path: Installation.recordFile).path)
        }
        try await runOnDedicatedThread {
            for folder in unfinished {
                try FileManager.default.removeItem(at: folder)
            }
        }
    }

    private func folders() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }
            .map { root.appending(path: $0) }
    }
}
