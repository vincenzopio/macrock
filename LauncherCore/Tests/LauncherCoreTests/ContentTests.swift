import Foundation
import Testing

@testable import LauncherCore

/// A `level.dat` as the game writes it: an 8-byte header, then a little-endian NBT compound
/// with tags of other types before the two the launcher reads.
func levelDat(name: String, lastPlayed: Int64) -> Data {
    func littleEndian<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }
    func string(_ value: String) -> [UInt8] {
        littleEndian(UInt16(value.utf8.count)) + Array(value.utf8)
    }
    func tag(_ type: UInt8, _ name: String, _ payload: [UInt8]) -> [UInt8] {
        [type] + string(name) + payload
    }
    let tags =
        tag(1, "Difficulty", [2])
        + tag(
            9, "lastOpenedWithVersion",
            [3] + littleEndian(Int32(2)) + littleEndian(Int32(1)) + littleEndian(Int32(26)))
        + tag(10, "abilities", tag(5, "flySpeed", littleEndian(Float(0.05).bitPattern)) + [0])
        + tag(12, "seeds", littleEndian(Int32(1)) + littleEndian(Int64(42)))
        + tag(8, "LevelName", string(name))
        + tag(4, "LastPlayed", littleEndian(lastPlayed))
    let root: [UInt8] = [10] + string("") + tags + [0]
    return Data(littleEndian(Int32(10)) + littleEndian(Int32(root.count)) + root)
}

struct LevelDataTests {
    @Test func readsTheNameAndTheLastGamePastOtherTags() throws {
        let level = try #require(LevelData(data: levelDat(name: "Île", lastPlayed: 1_791_000_000)))

        #expect(level.name == "Île")
        #expect(level.lastPlayed == Date(timeIntervalSince1970: 1_791_000_000))
    }

    @Test func aCutLevelIsNone() {
        let data = levelDat(name: "World", lastPlayed: 1_791_000_000)

        #expect(LevelData(data: data.prefix(data.count - 5)) == nil)
    }
}

struct ContentFileTests {
    @Test(arguments: [
        ("World.mcworld", ContentFile?.some(.world)), ("Pack.MCPACK", .pack),
        ("Addon.mcaddon", .addon), ("World.zip", nil),
    ])
    func knowsTheFilesOfWorldsAndPacks(name: String, kind: ContentFile?) {
        #expect(ContentFile(URL(filePath: "/Users/test/Downloads/\(name)")) == kind)
    }
}

struct GameDataTests {
    let temporary: TemporaryDirectory
    let directory: DataDirectory
    let account = UUID()
    let data: GameData

    init() throws {
        temporary = try TemporaryDirectory()
        directory = DataDirectory(
            root: temporary.url.appending(path: "macrock"), sockets: .temporaryDirectory)
        data = GameData(of: .release, account: account, in: directory, user: "test")
    }

    /// Makes the folders the game makes the first time it runs, and returns the user's.
    @discardableResult
    func runGame() throws -> URL {
        let user = data.root.appending(path: "Users/1234567890123456789/games/com.mojang")
        for folder in [
            user.appending(path: "minecraftWorlds"), data.shared.appending(path: "resource_packs"),
        ] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return user
    }

    @discardableResult
    func makeWorld(_ name: String, lastPlayed: Int64, in folder: URL) throws -> URL {
        let world = folder.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: world.appending(path: "db"), withIntermediateDirectories: true)
        try levelDat(name: name, lastPlayed: lastPlayed).write(
            to: world.appending(path: "level.dat"))
        try Data("MANIFEST-000004".utf8).write(to: world.appending(path: "db/CURRENT"))
        return world
    }

    /// A pack folder whose manifest has a comment and a trailing comma, as the game accepts.
    @discardableResult
    func makePack(
        _ name: String, module: String, uuid: UUID = UUID(), version: String = "[1, 0, 0]",
        in folder: URL
    ) throws -> URL {
        let pack = folder.appending(path: name)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data(
            """
            {
              // Made for the tests
              "format_version": 2,
              "header": {"name": "\(name)", "uuid": "\(uuid)", "version": \(version),},
              "modules": [{"type": "\(module)", "uuid": "\(UUID())", "version": [1, 0, 0]}],
            }
            """.utf8
        ).write(to: pack.appending(path: "manifest.json"))
        return pack
    }

    func zip(_ folder: URL, keepingParent: Bool = false, as name: String) async throws -> URL {
        let file = temporary.url.appending(path: name)
        try await runTool(
            "/usr/bin/ditto",
            ["-c", "-k"] + (keepingParent ? ["--keepParent"] : []) + [folder.path, file.path])
        return file
    }

    func leftovers(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(".macrock-import-") }
    }

    @Test func listsTheWorldsTheLastPlayedFirst() throws {
        let worlds = try runGame().appending(path: "minecraftWorlds")
        try makeWorld("Old", lastPlayed: 1_700_000_000, in: worlds)
        try makeWorld("New", lastPlayed: 1_791_000_000, in: worlds)

        let listed = try data.worlds()

        #expect(listed.map(\.name) == ["New", "Old"])
        #expect(listed.allSatisfy { $0.size > 0 && $0.icon == nil })
    }

    @Test func existsOnceTheGameHasRun() throws {
        #expect(!data.exists)
        try runGame()
        #expect(data.exists)
    }

    @Test func aPrefixTheGameHasNotRunInHasNothingToShowOrTake() async throws {
        let world = try await zip(
            makeWorld("World", lastPlayed: 1_791_000_000, in: temporary.url), as: "w.mcworld")

        #expect(try data.worlds().isEmpty)
        #expect(try data.packs().isEmpty)
        await #expect(throws: ContentError.gameNotRunYet) {
            try await data.importWorld(from: world)
        }
        #expect(try data.regolithEnvironment().isEmpty)
    }

    @Test func pointsRegolithAtTheSharedAndThePlayersFolders() throws {
        let user = try runGame()

        #expect(
            try data.regolithEnvironment() == [
                #"COM_MOJANG_PACKS="\#(data.shared.path)""#,
                #"COM_MOJANG_WORLDS="\#(user.path)""#,
            ])
    }

    @Test func findsTheContentLogTheGameChangedLast() throws {
        #expect(try data.latestContentLog() == nil)
        try FileManager.default.createDirectory(at: data.logs, withIntermediateDirectories: true)
        let older = data.logs.appending(path: "ContentLog2026-10-15_17-12-16_10.txt")
        let newer = data.logs.appending(path: "ContentLog2026-10-15_17-12-16_9.txt")
        for (file, minutesAgo) in [
            (older, 10.0), (newer, 1.0), (data.logs.appending(path: "x"), 0),
        ] {
            try Data().write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(-minutesAgo * 60)],
                ofItemAtPath: file.path)
        }

        #expect(try data.latestContentLog()?.lastPathComponent == newer.lastPathComponent)
    }

    @Test func readsWhetherTheGameWritesItsContentLog() throws {
        #expect(try data.writesContentLog() == nil)
        let options = try runGame().appending(path: "minecraftpe/options.txt")
        try FileManager.default.createDirectory(
            at: options.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data("gfx_msaa:1\r\ncontent_log_file:0\r\n".utf8).write(to: options)
        #expect(try data.writesContentLog() == false)
        try Data("gfx_msaa:1\r\ncontent_log_file:1\r\ncontent_log_gui:0\r\n".utf8).write(
            to: options)
        #expect(try data.writesContentLog() == true)
    }

    @Test func givesPreviewTheVariablesOfRegolithsPreviewTarget() throws {
        let preview = GameData(of: .preview, account: account, in: directory, user: "test")
        for folder in [preview.shared, preview.root.appending(path: "Users/1/games/com.mojang")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        #expect(
            try preview.regolithEnvironment().map { $0.prefix { $0 != "=" } } == [
                "COM_MOJANG_PACKS_PREVIEW", "COM_MOJANG_WORLDS_PREVIEW",
            ])
    }

    @Test func importsAWorldUnderANewIDWithItsOwnName() async throws {
        let user = try runGame()
        let source = try makeWorld("Island", lastPlayed: 1_791_000_000, in: temporary.url)

        let world = try await data.importWorld(from: zip(source, as: "Island.mcworld"))

        #expect(world.name == "Island")
        #expect(world.id != source.lastPathComponent)
        #expect(world.id.count == 12)
        #expect(!world.id.contains("/"))
        #expect(
            try Data(contentsOf: world.folder.appending(path: "db/CURRENT"))
                == Data("MANIFEST-000004".utf8))
        #expect(try data.worlds().map(\.id) == [world.id])
        #expect(try leftovers(in: user).isEmpty)
    }

    @Test func importsAWorldZippedWithItsFolder() async throws {
        try runGame()
        let source = try makeWorld("Island", lastPlayed: 1_791_000_000, in: temporary.url)

        let world = try await data.importWorld(
            from: zip(source, keepingParent: true, as: "Island.mcworld"))

        #expect(world.name == "Island")
    }

    @Test func refusesAnArchiveWithoutAWorld() async throws {
        let user = try runGame()
        let folder = temporary.url.appending(path: "notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appending(path: "notes.txt"))

        await #expect(throws: ContentError.notAWorld) {
            try await data.importWorld(from: zip(folder, as: "notes.mcworld"))
        }
        #expect(try data.worlds().isEmpty)
        #expect(try leftovers(in: user).isEmpty)
    }

    @Test func refusesAnArchiveWithALink() async throws {
        try runGame()
        let source = try makeWorld("Island", lastPlayed: 1_791_000_000, in: temporary.url)
        let elsewhere = temporary.url.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "elsewhere"), withDestinationURL: elsewhere)

        await #expect(throws: ContentError.unsafeArchive) {
            try await data.importWorld(from: zip(source, as: "Island.mcworld"))
        }
        #expect(try data.worlds().isEmpty)
    }

    @Test func exportsAWorldWithoutWhatMacOSAddsToArchives() async throws {
        let worlds = try runGame().appending(path: "minecraftWorlds")
        let source = try makeWorld("Island", lastPlayed: 1_791_000_000, in: worlds)
        try await runTool(
            "/usr/bin/xattr",
            ["-w", "dev.macrock.test", "1", source.appending(path: "level.dat").path])
        let world = try World(folder: source)
        let file = temporary.url.appending(path: "Island.mcworld")

        try await data.export(world, to: file)

        let entries = try await runTool("/usr/bin/unzip", ["-Z1", file.path])
            .split(separator: "\n").map(String.init)
        #expect(entries.contains("level.dat"))
        #expect(entries.contains("db/CURRENT"))
        #expect(!entries.contains { $0.contains("._") })
    }

    @Test func changesNothingWhileTheAccountPlays() async throws {
        try runGame()
        let world = try await zip(
            makeWorld("World", lastPlayed: 1_791_000_000, in: temporary.url), as: "w.mcworld")
        try FileManager.default.createDirectory(
            at: directory.prefixes, withIntermediateDirectories: true)
        let session = try AccountLock(file: directory.prefixLock(for: account))

        await #expect(throws: SessionError.alreadyRunning) {
            try await data.importWorld(from: world)
        }
        withExtendedLifetime(session) {}
    }

    @Test func movesAWorldToTheTrash() async throws {
        let worlds = try runGame().appending(path: "minecraftWorlds")
        let world = try World(
            folder: makeWorld("Island", lastPlayed: 1_791_000_000, in: worlds))

        let trashed = try data.trash(world)
        defer { try? FileManager.default.removeItem(at: trashed) }

        #expect(try data.worlds().isEmpty)
        #expect(FileManager.default.fileExists(atPath: trashed.appending(path: "level.dat").path))
    }

    @Test func importsThePacksOfAnAddonWhereTheGameLooksForThem() async throws {
        try runGame()
        let addon = temporary.url.appending(path: "addon")
        let resources = try makePack("pack.name", module: "resources", in: addon)
        try FileManager.default.createDirectory(
            at: resources.appending(path: "texts"), withIntermediateDirectories: true)
        try Data("## English\npack.name=Shiny Blocks\n".utf8).write(
            to: resources.appending(path: "texts/en_US.lang"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: resources.appending(path: "pack_icon.png"))
        let behavior = try makePack(
            "Mobs", module: "data", version: #""2.1.0""#, in: temporary.url)
        let zipped = try await zip(behavior, as: "Mobs.mcpack")
        try FileManager.default.moveItem(at: zipped, to: addon.appending(path: "Mobs.mcpack"))

        let packs = try await data.importPacks(from: zip(addon, as: "Addon.mcaddon"))

        #expect(Set(packs.map(\.name)) == ["Shiny Blocks", "Mobs"])
        #expect(try data.packs().map(\.name) == ["Mobs", "Shiny Blocks"])
        let mobs = try #require(packs.first { $0.name == "Mobs" })
        #expect(mobs.kind == .behavior)
        #expect(mobs.version == "2.1.0")
        #expect(mobs.icon == nil)
        let shiny = try #require(packs.first { $0.name == "Shiny Blocks" })
        #expect(shiny.icon?.lastPathComponent == "pack_icon.png")
        #expect(mobs.folder.deletingLastPathComponent().lastPathComponent == "behavior_packs")
        #expect(try leftovers(in: data.shared).isEmpty)
    }

    @Test func replacesAnEarlierVersionOfAPack() async throws {
        try runGame()
        let uuid = UUID()
        let first = try makePack(
            "Shiny", module: "resources", uuid: uuid, in: temporary.url.appending(path: "1"))
        let second = try makePack(
            "Shiny", module: "resources", uuid: uuid, version: "[1, 1, 0]",
            in: temporary.url.appending(path: "2"))
        _ = try await data.importPacks(from: zip(first, as: "1.mcpack"))

        _ = try await data.importPacks(from: zip(second, as: "2.mcpack"))

        let packs = try data.packs()
        #expect(packs.map(\.version) == ["1.1.0"])
        #expect(packs.map(\.folder.lastPathComponent) == ["2"])
    }

    @Test func addsNoPackOfAnAddonWithTwoVersionsOfOnePack() async throws {
        try runGame()
        let uuid = UUID()
        let earlier = try makePack(
            "Shiny", module: "resources", uuid: uuid, in: temporary.url.appending(path: "1"))
        _ = try await data.importPacks(from: zip(earlier, as: "1.mcpack"))
        let addon = temporary.url.appending(path: "addon")
        try makePack("Shiny", module: "resources", uuid: uuid, version: "[1, 1, 0]", in: addon)
        try makePack("Shiny 2", module: "resources", uuid: uuid, version: "[1, 2, 0]", in: addon)

        await #expect(throws: ContentError.duplicatePack) {
            try await data.importPacks(from: zip(addon, as: "Addon.mcaddon"))
        }
        #expect(try data.packs().map(\.version) == ["1.0.0"])
        #expect(try leftovers(in: data.shared).isEmpty)
    }

    @Test func addsNoPackOfAnAddonWithOneItCannotPlace() async throws {
        try runGame()
        let addon = temporary.url.appending(path: "addon")
        try makePack("Shiny", module: "resources", in: addon)
        try makePack("Castle", module: "world_template", in: addon)

        await #expect(throws: ContentError.unsupportedPack("world_template")) {
            try await data.importPacks(from: zip(addon, as: "Addon.mcaddon"))
        }
        #expect(try data.packs().isEmpty)
        #expect(try leftovers(in: data.shared).isEmpty)
    }
}
