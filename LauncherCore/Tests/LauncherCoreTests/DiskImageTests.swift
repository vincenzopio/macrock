import Foundation
import Testing

@testable import LauncherCore

struct DiskImageTests {
    let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory()
    }

    func image(holding text: String) async throws -> (image: URL, volume: String) {
        let name = uniqueVolumeName()
        let folder = temporary.url.appending(path: name)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "inner"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appending(path: "inner/file.txt"))
        return (try await makeDiskImage(of: folder), name)
    }

    @Test func showsTheVolumeThenEjectsTheImage() async throws {
        let (image, _) = try await image(holding: "hello")
        let (volume, text) = try await DiskImage(image).withMounted { volume in
            (
                volume,
                try String(contentsOf: volume.appending(path: "inner/file.txt"), encoding: .utf8)
            )
        }
        #expect(text == "hello")
        #expect(!FileManager.default.fileExists(atPath: volume.path))
    }

    @Test func leavesAttachedAnImageThatWasAlready() async throws {
        let (image, _) = try await image(holding: "hello")
        let volume = try await DiskImage(image).withMounted { outer in
            try await DiskImage(image).withMounted { inner in #expect(inner == outer) }
            #expect(FileManager.default.fileExists(atPath: outer.appending(path: "inner").path))
            return outer
        }
        #expect(!FileManager.default.fileExists(atPath: volume.path))
    }

    @Test func ejectsTheImageWhenTheClosureFails() async throws {
        let (image, name) = try await image(holding: "hello")
        await #expect(throws: CancellationError.self) {
            try await DiskImage(image).withMounted { _ in throw CancellationError() }
        }
        #expect(!FileManager.default.fileExists(atPath: "/Volumes/\(name)"))
    }

    @Test func anImageOfAFolderCarriesNoLicenseAgreement() async throws {
        let (image, _) = try await image(holding: "hello")
        #expect(!DiskImage(image).carriesLicenseAgreement)
    }

    @Test func anImageWithLicenseResourcesCarriesALicenseAgreement() async throws {
        let (image, _) = try await image(holding: "hello")
        try await addLicenseAgreement(to: image)
        #expect(DiskImage(image).carriesLicenseAgreement)
    }

    @Test func refusesAFileThatIsNotADiskImage() async throws {
        let file = temporary.url.appending(path: "notes.dmg")
        try Data("notes".utf8).write(to: file)
        #expect(!DiskImage(file).carriesLicenseAgreement)
        await #expect(throws: DiskImageError.notADiskImage) {
            try await DiskImage(file).withMounted { _ in }
        }
    }
}
