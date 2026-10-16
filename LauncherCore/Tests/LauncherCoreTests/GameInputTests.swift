import Foundation
import Testing
import zlib

@testable import LauncherCore

/// The GameInput redistributable of the game folder in `MACROCK_GAME_FOLDER`: Microsoft's package
/// can't be part of the tests.
let realInstaller = realGameFolder?.appending(path: "Installers/GameInputRedist.msi")

struct CabinetTests {
    /// Two files in one MSZIP folder of two blocks; the second block refers back into the first,
    /// so it only inflates with the first block's output as its dictionary.
    @Test func inflatesBlocksThatShareAWindow() throws {
        let content = (0..<1_500).map { "line \($0 % 97) of the GameInput payload\n" }.joined()
        let bytes = [UInt8](content.utf8)
        let blocks = [Array(bytes.prefix(32_768)), Array(bytes.dropFirst(32_768))]
        let cabinet = try makeCabinet(
            blocks: blocks,
            files: [(name: "a.dll", size: 30_000), (name: "b.exe", size: bytes.count - 30_000)])

        let files = try Cabinet(cabinet).files

        #expect(files.map(\.declaredSize) == [30_000, bytes.count - 30_000])
        #expect(files[0].content == Array(bytes.prefix(30_000)))
        #expect(files[1].content == Array(bytes.dropFirst(30_000)))
    }

    @Test func refusesABlockThatIsNotMSZIP() throws {
        let cabinet = try makeCabinet(
            blocks: [Array("data".utf8)], files: [(name: "a", size: 4)], blockSignature: "XX")
        #expect(throws: MalformedArchive.self) { try Cabinet(cabinet) }
    }

    private func makeCabinet(
        blocks: [[UInt8]], files: [(name: String, size: Int)], blockSignature: String = "CK"
    ) throws -> [UInt8] {
        var data: [[UInt8]] = []
        var window: [UInt8] = []
        for block in blocks {
            data.append(
                Array(blockSignature.utf8)
                    + (try deflate(block, dictionary: Array(window.suffix(32_768)))))
            window += block
        }
        let fileEntries = files.reduce(into: (entries: [UInt8](), offset: 0)) { result, file in
            result.entries +=
                le32(file.size) + le32(result.offset) + le16(0) + le16(0) + le16(0)
                + le16(0x20) + Array(file.name.utf8) + [0]
            result.offset += file.size
        }.entries
        let filesOffset = 36 + 8
        let dataOffset = filesOffset + fileEntries.count
        var cabinet = Array("MSCF".utf8) + le32(0) + le32(0) + le32(0) + le32(filesOffset) + le32(0)
        cabinet += [3, 1] + le16(1) + le16(files.count) + le16(0) + le16(0) + le16(0)
        cabinet += le32(dataOffset) + le16(blocks.count) + le16(1)
        cabinet += fileEntries
        for (block, compressed) in zip(blocks, data) {
            cabinet += le32(0) + le16(compressed.count) + le16(block.count) + compressed
        }
        return cabinet
    }

    private func deflate(_ input: [UInt8], dictionary: [UInt8]) throws -> [UInt8] {
        var stream = z_stream()
        #expect(
            deflateInit2_(
                &stream, Z_BEST_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        var input = input
        var dictionary = dictionary
        var output = [UInt8](repeating: 0, count: input.count + 1_024)
        let written = dictionary.withUnsafeMutableBufferPointer { dictionary in
            input.withUnsafeMutableBufferPointer { input in
                output.withUnsafeMutableBufferPointer { output in
                    if dictionary.count > 0 {
                        deflateSetDictionary(
                            &stream, dictionary.baseAddress, uInt(dictionary.count))
                    }
                    stream.next_in = input.baseAddress
                    stream.avail_in = uInt(input.count)
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    _ = zlib.deflate(&stream, Z_FINISH)
                    return output.count - Int(stream.avail_out)
                }
            }
        }
        return Array(output.prefix(written))
    }

    private func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
    private func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16(value >> 16) }
}

struct GameInputTests {
    let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory()
    }

    @Test func writesTheRegistryOfTheReferenceInstaller() {
        let expected =
            "Windows Registry Editor Version 5.00\n\n[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\GameInput]\n\"RedistDir\"=\"C:\\\\Program Files\\\\Microsoft GameInput\\\\x64\"\n\n[HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\Microsoft\\GameInput]\n\"RedistDir\"=\"C:\\\\Program Files\\\\Microsoft GameInput\\\\x64\"\n\n[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\GameInputRedistService]\n\"DisplayName\"=\"GameInput Redist Service\"\n\"Description\"=\"GameInput Redist Service\"\n\"ImagePath\"=hex(2):43,00,3a,00,5c,00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,00,20,00,46,00,69,00,6c,00,65,00,73,00,5c,00,4d,00,69,00,63,00,72,00,6f,00,73,00,6f,00,66,00,74,00,20,00,47,00,61,00,6d,00,65,00,49,00,6e,00,70,00,75,00,74,00,5c,00,78,00,36,00,34,00,5c,00,47,00,61,00,6d,00,65,00,49,00,6e,00,70,00,75,00,74,00,52,00,65,00,64,00,69,00,73,00,74,00,53,00,65,00,72,00,76,00,69,00,63,00,65,00,2e,00,65,00,78,00,65,00,00,00\n\"ObjectName\"=\"LocalSystem\"\n\"ErrorControl\"=dword:00000000\n\"Start\"=dword:00000003\n\"Type\"=dword:00000010\n\"PreshutdownTimeout\"=dword:0002bf20\n"
        #expect(GameInput.registryText == expected)
    }

    @Test func refusesAnotherPackage() throws {
        let installer = temporary.url.appending(path: "GameInputRedist.msi")
        try Data(repeating: 0xD0, count: 4_096).write(to: installer)
        #expect(throws: GameInputError.unrecognizedPackage) { try GameInput(installer: installer) }
    }

    @Test(.enabled(if: realInstaller != nil)) func installsTheFilesOfTheReviewedPackage() throws {
        let prefix = temporary.url
        try GameInput(installer: try #require(realInstaller)).install(
            into: prefix, registry: prefix.appending(path: "gameinput.reg"))
        #expect(GameInput.isInstalled(in: prefix))
        let registry = try Data(contentsOf: prefix.appending(path: "gameinput.reg"))
        #expect(registry.prefix(2) == Data([0xFF, 0xFE]))
    }

    @Test(.enabled(if: realInstaller != nil)) func installsIntoAPrefixOnce() async throws {
        let runtime = try FakeRuntime(in: temporary.url)
        let host = HostEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/")
        let prefix = WinePrefix(
            url: temporary.url.appending(path: "prefix"), serverDirectories: temporary.url)
        let game = try GameFolder(url: makeGameFolder(in: temporary.url))
        try FileManager.default.createDirectory(
            at: game.gameInputInstaller.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try #require(realInstaller), to: game.gameInputInstaller)
        let setup = try PrefixSetup(
            contentsOf: {
                let file = temporary.url.appending(path: "setup.json")
                try Data(
                    #"{"schema": 1, "revision": 1, "dll_overrides": "", "game_drive": "g:", "steps": []}"#
                        .utf8
                )
                .write(to: file)
                return file
            }())
        let tool = WineTool(runtime: runtime.url, host: host)
        try await prefix.prepare(
            setup: setup, engine: "0.1.0", game: game, retinaMode: false, tool: tool,
            output: .nullDevice)

        try await prefix.installGameInput(from: game, tool: tool, output: .nullDevice)
        let calls = try runtime.recorded.count
        try await prefix.installGameInput(from: game, tool: tool, output: .nullDevice)

        let recorded = try runtime.recorded
        #expect(recorded.count == calls)
        #expect(recorded.suffix(2).first?.contains(".macrock-gameinput.reg") == true)
        #expect(GameInput.isInstalled(in: prefix.url))
    }
}
