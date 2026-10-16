import Foundation
import Testing

@testable import LauncherCore

/// A game folder of Minecraft for Windows, for the tests that need Microsoft's signature.
let realGameFolder = ProcessInfo.processInfo.environment["MACROCK_GAME_FOLDER"].map {
    URL(filePath: $0)
}

struct AuthenticodeTests {
    let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory()
    }

    /// A PE32+ file with headers only, and a certificate table holding `certificate` if given.
    func program(certificate: Data?) throws -> URL {
        var file = Data(count: 0x200)
        file.replaceSubrange(0..<2, with: Data("MZ".utf8))
        file[0x3C] = 0x40
        file.replaceSubrange(0x40..<0x44, with: Data([0x50, 0x45, 0, 0]))
        file[0x58] = 0x0B
        file[0x59] = 0x02
        if let certificate {
            var table = Data()
            for value in [UInt32(8 + certificate.count)] {
                withUnsafeBytes(of: value.littleEndian) { table.append(contentsOf: $0) }
            }
            table.append(contentsOf: [0x00, 0x02, 0x02, 0x00])
            table.append(certificate)
            for (offset, value) in [(0xE8, UInt32(file.count)), (0xEC, UInt32(table.count))] {
                withUnsafeBytes(of: value.littleEndian) {
                    file.replaceSubrange(offset..<(offset + 4), with: $0)
                }
            }
            file.append(table)
        }
        let url = temporary.url.appending(path: "program.exe")
        try file.write(to: url)
        return url
    }

    @Test func refusesAProgramWithoutASignature() throws {
        let program = try program(certificate: nil)

        #expect(throws: ProgramSignatureError.unsigned) {
            try WindowsProgram(url: program).checkSignedByMicrosoft()
        }
    }

    @Test func refusesASignatureThatIsNotPKCS7() throws {
        let program = try program(certificate: Data([0x30, 0x03, 0x02, 0x01, 0x01]))

        #expect(throws: ProgramSignatureError.malformed) {
            try WindowsProgram(url: program).checkSignedByMicrosoft()
        }
    }

    @Test func refusesAFileThatIsNotAProgram() throws {
        let file = temporary.url.appending(path: "notes.exe")
        try Data(repeating: 0x41, count: 512).write(to: file)

        #expect(throws: ProgramSignatureError.malformed) {
            try WindowsProgram(url: file).checkSignedByMicrosoft()
        }
    }

    @Test(.enabled(if: realGameFolder != nil)) func acceptsTheGameAsMicrosoftSignedIt() throws {
        let game = try #require(realGameFolder)

        try WindowsProgram(url: game.appending(path: GameFolder.executable))
            .checkSignedByMicrosoft()
    }

    @Test(.enabled(if: realGameFolder != nil)) func refusesTheGameWithOneByteChanged() throws {
        let game = try #require(realGameFolder)
        let copy = temporary.url.appending(path: GameFolder.executable)
        try FileManager.default.copyItem(
            at: game.appending(path: GameFolder.executable), to: copy)
        let file = try FileHandle(forUpdating: copy)
        try file.seek(toOffset: 1 << 20)
        let byte = try #require(try file.read(upToCount: 1))
        try file.seek(toOffset: 1 << 20)
        try file.write(contentsOf: Data([~byte[byte.startIndex]]))
        try file.close()

        #expect(throws: ProgramSignatureError.modified) {
            try WindowsProgram(url: copy).checkSignedByMicrosoft()
        }
    }
}
