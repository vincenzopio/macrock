import Foundation
import Testing

@testable import LauncherCore

struct ToolkitImageTests {
    let temporary: TemporaryDirectory
    let directory: DataDirectory

    init() throws {
        temporary = try TemporaryDirectory()
        directory = DataDirectory(
            root: temporary.url.appending(path: "macrock"), sockets: temporary.url)
    }

    /// The Toolkit's layout: D3DMetal and the license in an image inside the image.
    func toolkit(
        withD3DMetal: Bool = true, licenseAgreement: Bool = false
    ) async throws -> ToolkitImage {
        let environment = temporary.url.appending(path: uniqueVolumeName())
        try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
        if withD3DMetal {
            try await makeD3DMetalLayout(at: environment.appending(path: "redist/lib"))
            try Data(#"{\rtf1 License}"#.utf8).write(to: environment.appending(path: "License.rtf"))
        }
        let environmentImage = try await makeDiskImage(of: environment)
        if licenseAgreement {
            try await addLicenseAgreement(to: environmentImage)
        }
        let toolkit = temporary.url.appending(path: uniqueVolumeName())
        try FileManager.default.createDirectory(at: toolkit, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: environmentImage, to: toolkit.appending(path: "Evaluation environment.dmg"))
        try Data().write(to: toolkit.appending(path: "Read Me.webloc"))
        return ToolkitImage(try await makeDiskImage(of: toolkit))
    }

    @Test func showsTheLicenseFromTheImageInsideTheToolkit() async throws {
        let image = try await toolkit()
        var shown: ToolkitImage.License?
        do {
            _ = try await image.importD3DMetal(into: directory, requiring: gptk("4")) { license in
                shown = license
                return true
            }
            Issue.record("D3DMetal signed ad hoc was imported")
        } catch {
            // Accepting leads to the copy, which wants D3DMetal signed by Apple.
            #expect(error is CodeSignatureError)
        }
        #expect(shown?.version == "4.0b2")
        #expect(shown.map { String(decoding: $0.rtf, as: UTF8.self) } == #"{\rtf1 License}"#)
    }

    @Test(.enabled(if: realToolkitImage != nil, "a person agrees, as with Apple's image"))
    func macOSShowsAnAgreementThatDiskutilShowsOnlyInATerminal() async throws {
        let image = try await toolkit(licenseAgreement: true)
        do {
            _ = try await image.importD3DMetal(into: directory, requiring: gptk("4")) { _ in
                Issue.record("the license was shown again")
                return true
            }
            Issue.record("D3DMetal signed ad hoc was imported")
        } catch {
            // Agreeing leads to the copy, which wants D3DMetal signed by Apple.
            #expect(error is CodeSignatureError)
        }
    }

    @Test func copiesNothingWhenTheLicenseIsDeclined() async throws {
        let payload = try await toolkit().importD3DMetal(into: directory, requiring: nil) { _ in
            false
        }
        #expect(payload == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.graphics.path))
    }

    @Test func refusesAnotherMajorVersionBeforeShowingTheLicense() async throws {
        let image = try await toolkit()
        await #expect(throws: SessionError.unsupportedD3DMetal(found: "4.0b2", required: "5")) {
            try await image.importD3DMetal(into: directory, requiring: gptk("5")) { _ in
                Issue.record("the license was shown")
                return false
            }
        }
    }

    @Test func refusesAnImageWithoutD3DMetal() async throws {
        let image = try await toolkit(withD3DMetal: false)
        await #expect(throws: GraphicsError.notAToolkitImage) {
            try await image.importD3DMetal(into: directory, requiring: nil) { _ in true }
        }
    }
}

/// Apple's own image: its tests attach it one at a time, since a second attachment of an image
/// is the first one, ejected with it.
@Suite(.serialized, .enabled(if: realToolkitImage != nil))
struct AppleToolkitImageTests {
    let temporary: TemporaryDirectory
    let directory: DataDirectory

    init() throws {
        temporary = try TemporaryDirectory()
        directory = DataDirectory(
            root: temporary.url.appending(path: "macrock"), sockets: temporary.url)
    }

    @Test func carriesAppleLicenseInTheImageInsideIt() async throws {
        let toolkit = DiskImage(try #require(realToolkitImage))
        #expect(!toolkit.carriesLicenseAgreement)
        let inner = try await toolkit.withMounted { volume in
            try FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "dmg" }
                .map { DiskImage($0).carriesLicenseAgreement }
        }
        #expect(inner == [true])
    }

    @Test func importsD3DMetalAfterTheLicenseMacOSShows() async throws {
        let stale = directory.graphics.appending(path: "gptk-3.0")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let image = ToolkitImage(try #require(realToolkitImage))
        var asked = false
        let imported = try await image.importD3DMetal(into: directory, requiring: gptk("4")) { _ in
            asked = true
            return true
        }
        let payload = try #require(imported)
        let folder = directory.graphics.appending(path: "gptk-\(payload.version)")
        #expect(!asked)
        #expect(payload.lib == folder.appending(path: "lib"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "License.rtf").path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.graphics.path)
                == ["gptk-\(payload.version)"])
    }
}

private func gptk(_ majorVersion: String) -> EngineIndex.Requirements {
    EngineIndex.Requirements(gptk: majorVersion, macos: "27.0")
}
