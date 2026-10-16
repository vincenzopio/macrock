import Foundation
import Testing

@testable import LauncherCore

struct D3DMetalPayloadTests {
    let temporary: TemporaryDirectory
    let lib: URL

    init() async throws {
        temporary = try TemporaryDirectory()
        lib = temporary.url.appending(path: "lib")
        try await makeD3DMetalLayout(at: lib)
    }

    @Test func refusesAMissingDLL() async throws {
        try FileManager.default.removeItem(at: lib.appending(path: "wine/x86_64-windows/dxgi.dll"))
        await #expect(throws: GraphicsError.missingFile("wine/x86_64-windows/dxgi.dll")) {
            try await runOnDedicatedThread { [lib] in try D3DMetalPayload(lib: lib) }
        }
    }

    @Test func refusesACopiedLibraryInPlaceOfTheLink() async throws {
        let link = lib.appending(path: "wine/x86_64-unix/d3d12.so")
        try FileManager.default.removeItem(at: link)
        try Data().write(to: link)
        await #expect(throws: GraphicsError.brokenLink("wine/x86_64-unix/d3d12.so")) {
            try await runOnDedicatedThread { [lib] in try D3DMetalPayload(lib: lib) }
        }
    }

    @Test func refusesALinkToAnotherLibrary() async throws {
        let link = lib.appending(path: "wine/x86_64-unix/dxgi.so")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "/usr/lib/libz.1.dylib")
        await #expect(throws: GraphicsError.brokenLink("wine/x86_64-unix/dxgi.so")) {
            try await runOnDedicatedThread { [lib] in try D3DMetalPayload(lib: lib) }
        }
    }

    @Test func findsAnImportUntilItsSharedLibraryIsDeleted() throws {
        #expect(D3DMetalPayload.isPresent(at: lib))
        try FileManager.default.removeItem(at: lib.appending(path: "external/libd3dshared.dylib"))
        #expect(!D3DMetalPayload.isPresent(at: lib))
    }

    @Test func refusesD3DMetalNotSignedByApple() async throws {
        await #expect(throws: CodeSignatureError.self) {
            try await runOnDedicatedThread { [lib] in try D3DMetalPayload(lib: lib) }
        }
    }
}

struct GameFolderTests {
    let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory()
    }

    func makeGame(executable: Data? = nil, config: String? = nil) throws -> URL {
        let game = try makeGameFolder(in: temporary.url)
        if let executable {
            try executable.write(to: game.appending(path: "Minecraft.Windows.exe"))
        }
        if let config {
            try Data(config.utf8).write(to: game.appending(path: "MicrosoftGame.Config"))
        }
        return game
    }

    @Test func readsTheGameIdentity() throws {
        let game = try GameFolder(url: makeGame())
        #expect(game.version == "1.26.5203.0")
        #expect(game.storeID == "9NBLGGH2JHXJ")
    }

    @Test func refusesAnEncryptedExecutable() throws {
        let url = try makeGame(executable: Data([0x4D, 0x53, 0x43, 0x46]))
        #expect(throws: GameFolderError.executableNotDecrypted) { try GameFolder(url: url) }
    }

    @Test func refusesAFolderWithoutTheGame() {
        #expect(throws: GameFolderError.missingExecutable) { try GameFolder(url: temporary.url) }
    }

    @Test func refusesAConfigWithoutAVersion() throws {
        let url = try makeGame(config: "<Game><TitleId>1</TitleId><StoreId>2</StoreId></Game>")
        #expect(throws: GameFolderError.malformedConfig) { try GameFolder(url: url) }
    }
}
