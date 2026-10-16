import Foundation
import SwiftProtobuf
import Synchronization
import Testing

@testable import LauncherCore

struct AccountInstallTests {
    @Test func theServiceExtractsTheGameIntoItsProductsStaging() async throws {
        let installed =
            try Xodus_InstallUpdate.with { $0.installed.version = "1.26.5203.0" }.serializedBytes()
            as Data
        let fixture = try await AccountFixture()
        let fake = try fixture.fakeService { type, payload in
            guard type == 212, let request = try? Xodus_Install(serializedBytes: payload) else {
                return nil
            }
            _ = try? makeGameFolder(in: URL(filePath: request.staging))
            return installed
        }
        let store = InstallationStore(in: fixture.setup.directory)

        let version = try await fixture.account.install(
            .release, with: fixture.setup,
            progress: AsyncStream.makeStream(of: InstallProgress.self).continuation)

        #expect(version == "1.26.5203.0")
        #expect(
            try GameFolder(url: store.staging(for: .release).appending(path: "game")).version
                == "1.26.5203.0")
        #expect(try store.installations().isEmpty)
        #expect(try await fixture.released)
        _ = fake
    }

    @Test func aCancelledInstallKeepsItsDownloadForTheNextOne() async throws {
        let downloading =
            try Xodus_InstallUpdate.with {
                $0.progress.phase = .downloading
                $0.progress.total = 2_069_975_040
            }.serializedBytes() as Data
        let fixture = try await AccountFixture()
        let fake = try fixture.fakeService { type, payload in
            guard type == 212, let request = try? Xodus_Install(serializedBytes: payload) else {
                return nil
            }
            let download = URL(filePath: request.staging).appending(path: "1.26.5203.0.msixvc.part")
            try? Data("part".utf8).write(to: download)
            return downloading
        }
        let store = InstallationStore(in: fixture.setup.directory)
        let (account, setup) = (fixture.account, fixture.setup)
        let (updates, progress) = AsyncStream.makeStream(of: InstallProgress.self)

        let install = Task {
            try await account.install(.release, with: setup, progress: progress)
        }
        for await _ in updates { break }
        install.cancel()

        await #expect(throws: CancellationError.self) { try await install.value }
        #expect(try store.installations().isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: store.staging(for: .release).appending(path: "1.26.5203.0.msixvc.part").path
            ))
        #expect(try await fixture.released)
        _ = fake
    }

    @Test func asksOneServiceForThePackagesOfEveryProduct() async throws {
        let release =
            try Xodus_PackageResult.with {
                $0.package.version = "1.26.5203.0"
                $0.package.size = 2_069_975_040
            }.serializedBytes() as Data
        let unavailable =
            try Xodus_PackageResult.with { $0.failure.reason = .unavailable }.serializedBytes()
            as Data
        let fixture = try await AccountFixture()
        let fake = try fixture.fakeService { type, payload in
            guard type == 210, let request = try? Xodus_Package(serializedBytes: payload) else {
                return nil
            }
            return request.productID == GameProduct.release.storeID ? release : unavailable
        }

        let packages = try await fixture.account.servedPackages(
            of: [.release, .preview], with: fixture.setup)

        #expect(
            packages[.release] == .success(GamePackage(version: "1.26.5203.0", size: 2_069_975_040))
        )
        #expect(packages[.preview] == .failure(.microsoftUnavailable))
        #expect(try await fixture.released)
        _ = fake
    }

    @Test func installsPreviewApartFromRelease() async throws {
        let installed =
            try Xodus_InstallUpdate.with { $0.installed.version = "1.26.6030.0" }.serializedBytes()
            as Data
        let fixture = try await AccountFixture()
        let request = Mutex<Xodus_Install?>(nil)
        let fake = try fixture.fakeService { type, payload in
            guard type == 212, let install = try? Xodus_Install(serializedBytes: payload) else {
                return nil
            }
            request.withLock { $0 = install }
            _ = try? makeGameFolder(in: URL(filePath: install.staging))
            return installed
        }
        let store = InstallationStore(in: fixture.setup.directory)

        let version = try await fixture.account.install(
            .preview, with: fixture.setup,
            progress: AsyncStream.makeStream(of: InstallProgress.self).continuation)

        #expect(version == "1.26.6030.0")
        #expect(request.withLock { $0?.productID } == GameProduct.preview.storeID)
        #expect(request.withLock { $0?.staging } == store.staging(for: .preview).path)
        _ = fake
    }

    @Test func anAccountWithoutTheGameInstallsNothing() async throws {
        let notOwned =
            try Xodus_InstallUpdate.with { $0.failure.reason = .notOwned }.serializedBytes() as Data
        let fixture = try await AccountFixture()
        let fake = try fixture.fakeService { type, _ in type == 212 ? notOwned : nil }
        let store = InstallationStore(in: fixture.setup.directory)

        await #expect(throws: ServiceFailure.notOwned) {
            try await fixture.account.install(
                .release, with: fixture.setup,
                progress: AsyncStream.makeStream(of: InstallProgress.self).continuation)
        }
        #expect(try store.installations().isEmpty)
        #expect(try await fixture.released)
        _ = fake
    }
}

struct GamePackageTests {
    let served = GamePackage(version: "1.26.5203.0", size: 2_069_975_040)

    @Test(arguments: [
        ("1.26.4100.0", true), ("1.26.900.0", true), ("1.26.5203.0", false), ("1.27.0.0", false),
    ])
    func isNewerThanAnEarlierVersionOnly(installed: String, newer: Bool) {
        #expect(served.isNewer(than: installed) == newer)
    }
}

struct InstallationStoreTests {
    let temporary: TemporaryDirectory
    let store: InstallationStore

    init() throws {
        temporary = try TemporaryDirectory()
        store = InstallationStore(
            in: DataDirectory(root: temporary.url, sockets: .temporaryDirectory))
    }

    func install() throws -> Installation {
        try store.adopt(
            try makeGameFolder(in: store.staging(for: .release)), of: .release, consented: .now)
    }

    @Test func makesNoInstallationOfAGameMicrosoftDidNotSign() async throws {
        let staging = store.staging(for: .release)
        let staged = try makeGameFolder(in: staging)

        await #expect(throws: ProgramSignatureError.malformed) {
            try await store.addStagedGame(of: .release, consented: .now)
        }
        #expect(try store.installations().isEmpty)
        #expect(FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func recordsTheInstallationOfAStagedGame() throws {
        let installation = try store.adopt(
            try makeGameFolder(in: store.staging(for: .preview)), of: .preview,
            consented: Date(timeIntervalSince1970: 1_791_000_000))

        #expect(installation.product == .preview)
        #expect(installation.version == "1.26.5203.0")
        #expect(installation.consented == Date(timeIntervalSince1970: 1_791_000_000))
        #expect(installation.size > 0)
        #expect(try store.installations() == [installation])
        #expect(
            !FileManager.default.fileExists(
                atPath: store.staging(for: .preview).appending(path: "game").path))
    }

    @Test func listsTheNewestInstallationFirst() throws {
        let older = try install()
        let newer = try install()

        #expect(try store.installations() == [newer, older])
    }

    @Test func removesWhatAnInterruptedInstallLeftAndKeepsANewerLaunchersInstallation()
        async throws
    {
        let installation = try install()
        let interrupted = store.root.appending(path: UUID().uuidString.lowercased())
        _ = try makeGameFolder(in: interrupted)
        let newer = store.root.appending(path: UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: false)
        try Data(#"{"schema": 2}"#.utf8).write(to: newer.appending(path: "installation.json"))

        try await store.removeUnfinished()

        #expect(try store.installations() == [installation])
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
        #expect(FileManager.default.fileExists(atPath: newer.path))
    }

    @Test func readsAnInstallationRecordedBeforeProductsAsRelease() throws {
        let folder = store.root.appending(path: UUID().uuidString.lowercased())
        _ = try makeGameFolder(in: folder)
        try Data(
            #"{"schema": 1, "version": "1.26.5203.0", "installed": 813496216, "size": 1, "consented": 813495659}"#
                .utf8
        ).write(to: folder.appending(path: "installation.json"))

        let installation = try #require(try store.installations().first)

        #expect(installation.product == .release)
        #expect(installation.lastEngine == nil)
    }

    @Test func recordsTheEngineTheGameRanOn() throws {
        let installation = try install()

        _ = try store.noteRun(of: installation, on: "0.1.1-1ecbab43d666")

        #expect(try store.installations().first?.lastEngine == "0.1.1-1ecbab43d666")
    }

    @Test func knowsWhenTheGamesProgramIsGone() throws {
        let installation = try install()
        #expect(installation.hasGame)
        try FileManager.default.removeItem(
            at: installation.game.appending(path: GameFolder.executable))
        #expect(!installation.hasGame)
    }

    @Test func deletesAnInstallation() async throws {
        let installation = try install()

        try await store.delete(installation)

        #expect(try store.installations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installation.folder.path))
    }
}
