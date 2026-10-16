import Foundation
import Testing

@testable import LauncherCore

struct EngineStoreTests {
    let temporary: TemporaryDirectory
    let store: EngineStore
    let bundle: URL

    init() async throws {
        temporary = try TemporaryDirectory()
        store = EngineStore(
            in: DataDirectory(
                root: temporary.url.appending(path: "macrock"), sockets: temporary.url))
        let build = temporary.url.appending(path: "build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
        bundle = try await makeEngineBundle(in: build, version: "0.1.1")
    }

    func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.root.path).sorted()
    }

    func install(from folder: ReleaseFolder) async throws -> EngineRuntime {
        try await store.install(
            folder.releases.latest(), progress: AsyncStream.makeStream(of: Double.self).continuation
        )
    }

    /// Installs from `folder` and returns what the progress stream reported until it finished.
    func installReportingProgress(from folder: ReleaseFolder) async throws -> [Double] {
        let (store, release) = (store, try await folder.releases.latest())
        let (fractions, progress) = AsyncStream.makeStream(of: Double.self)
        async let installed = store.install(release, progress: progress)
        var reported: [Double] = []
        for await fraction in fractions {
            reported.append(fraction)
        }
        _ = try await installed
        return reported
    }

    func changeWine(of engine: EngineRuntime) throws {
        try Data("changed".utf8).write(to: engine.wine)
    }

    @Test func installsTheLatestReleaseBesideItsIndex() async throws {
        let folder = try await ReleaseFolder.packaging(bundle, in: temporary.url)
        let engine = try await install(from: folder)
        let installed = store.folder(of: engine.identity)
        #expect(try contents() == [engine.identity])
        #expect(engine.bundle == installed.appending(path: "macrock-engine-0.1.1.bundle"))
        #expect(
            try Data(contentsOf: installed.appending(path: "index.json"))
                == Data(contentsOf: folder.releases.url.appending(path: "index.json")))
        #expect(try await store.open(engine.identity).identity == engine.identity)
    }

    @Test func reportsTheDownloadUntilTheInstallEnds() async throws {
        let reported = try await installReportingProgress(
            from: ReleaseFolder.packaging(bundle, in: temporary.url))
        #expect(reported.last == 1)
    }

    @Test func installsNothingFromADamagedArchive() async throws {
        let folder = try await ReleaseFolder.packaging(bundle, in: temporary.url)
        var archive = try Data(contentsOf: folder.archive)
        archive[archive.count / 2] ^= 0xff
        try archive.write(to: folder.archive)
        await #expect(throws: ReleaseError.damagedArchive) { try await install(from: folder) }
        #expect(try contents().isEmpty)
    }

    @Test func installsNothingWhenTheBundleIsNotTheBuildOfTheIndex() async throws {
        let packaged = try await ReleaseFolder.packaging(bundle, in: temporary.url)
        let mislabelled = try ReleaseFolder(
            in: temporary.url.appending(path: "mislabelled"),
            archive: Data(contentsOf: packaged.archive))
        // A progress stream left open on failure would keep this waiting.
        await #expect(throws: EngineError.buildMismatch) {
            try await installReportingProgress(from: mislabelled)
        }
        #expect(try contents().isEmpty)
    }

    @Test func readsTheIndexOfAnInstalledEngine() async throws {
        let engine = try await install(from: ReleaseFolder.packaging(bundle, in: temporary.url))
        #expect(store.installedIndex(of: engine.identity) == engine.index)
        #expect(store.installedIndex(of: "0.1.0-59358740b31f") == nil)
    }

    @Test func findsTheLicensesOfAnInstalledEngine() async throws {
        let engine = try await install(from: ReleaseFolder.packaging(bundle, in: temporary.url))
        let documentation = try #require(store.documentation(of: engine.identity))
        #expect(
            FileManager.default.fileExists(
                atPath: documentation.appending(path: "COPYING.LIB").path))
        #expect(store.documentation(of: "0.1.0-59358740b31f") == nil)
    }

    @Test func aChangedFileKeepsTheEngineFromOpening() async throws {
        let engine = try await install(
            from: ReleaseFolder.packaging(bundle, in: temporary.url))
        try changeWine(of: engine)
        await #expect(throws: EngineError.sealBroken) { try await store.open(engine.identity) }
    }

    @Test func installingAgainRepairsTheEngine() async throws {
        let folder = try await ReleaseFolder.packaging(bundle, in: temporary.url)
        try changeWine(of: try await install(from: folder))
        let engine = try await install(from: folder)
        #expect(try await store.open(engine.identity).identity == engine.identity)
        #expect(try contents() == [engine.identity])
    }

    @Test func removesEverythingButTheKeptEngines() async throws {
        for name in [
            "0.1.0-59358740b31f", "0.1.1-1ecbab43d666", ".staging-0C1A",
            "macrock-engine-0.1.0.bundle",
        ] {
            try FileManager.default.createDirectory(
                at: store.root.appending(path: name), withIntermediateDirectories: true)
        }
        try await store.removeEngines(except: ["0.1.1-1ecbab43d666"])
        #expect(try contents() == ["0.1.1-1ecbab43d666"])
    }

    @Test func anEmptyStoreHasNothingToRemove() async throws {
        try await store.removeEngines(except: [])
        #expect(!FileManager.default.fileExists(atPath: store.root.path))
    }
}
