import Foundation
import Testing

@testable import LauncherCore

struct StaticCodeTests {
    let temporary: TemporaryDirectory
    let bundle: URL

    init() async throws {
        temporary = try TemporaryDirectory()
        bundle = temporary.url.appending(path: "Sample.bundle")
        let resources = bundle.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.macrock.sample", "CFBundlePackageType": "BNDL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        try Data("runtime file".utf8).write(to: resources.appending(path: "file"))
        try await runTool("/usr/bin/codesign", ["--sign", "-", bundle.path])
    }

    @Test func acceptsAnIntactBundle() async throws {
        try await runOnDedicatedThread { [bundle] in try StaticCode(bundle).validate() }
    }

    @Test func refusesAChangedFile() async throws {
        try Data("changed".utf8).write(to: bundle.appending(path: "Contents/Resources/file"))
        await #expect(throws: CodeSignatureError.self) {
            try await runOnDedicatedThread { [bundle] in try StaticCode(bundle).validate() }
        }
    }

    @Test func refusesAnAddedFile() async throws {
        try Data().write(to: bundle.appending(path: "Contents/Resources/extra"))
        await #expect(throws: CodeSignatureError.self) {
            try await runOnDedicatedThread { [bundle] in try StaticCode(bundle).validate() }
        }
    }

    @Test func checksARequirement() async throws {
        try await runOnDedicatedThread {
            try StaticCode(URL(filePath: "/usr/bin/true")).validate(requirement: "anchor apple")
        }
        await #expect(throws: CodeSignatureError.self) {
            try await runOnDedicatedThread { [bundle] in
                try StaticCode(bundle).validate(requirement: "anchor apple")
            }
        }
    }

    @Test func readsTheCDHashCodesignPrints() async throws {
        let details = try await runTool("/usr/bin/codesign", ["-dvvv", bundle.path])
        let printed = details.split(separator: "\n").first { $0.hasPrefix("CDHash=") }
        let cdhash = try await runOnDedicatedThread { [bundle] in try StaticCode(bundle).cdhash() }
        #expect(printed == "CDHash=" + cdhash.map { String(format: "%02x", $0) }.joined())
    }
}
