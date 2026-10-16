import Foundation
import Testing

@testable import LauncherCore

struct EngineFileTests {
    let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory()
    }

    func file(_ name: String, _ text: String) throws -> URL {
        let url = temporary.url.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func readsTheServicePin() throws {
        let pin = try ServicePin(
            contentsOf: file(
                "service-pin.json",
                #"{"cdhash": "1f94f9c156b2499b93b5430fab424b7d281491ab", "serviceProtocol": 1}"#))
        #expect(pin.cdhash.first == 0x1f)
        #expect(pin.cdhash.count == 20)
        #expect(pin.serviceProtocol == 1)
    }

    @Test func readsTheIndexOfRelease011() throws {
        let index = try EngineIndex(contentsOf: file("index.json", releaseIndex()))
        #expect(index.version == "0.1.1")
        #expect(index.requires == .init(gptk: "4", macos: "27.0"))
        #expect(index.serviceProtocol == 1)
        #expect(index.bundle.file == "macrock-engine-0.1.1.aar")
        #expect(index.bundle.size == 49_611_888)
        #expect(index.bundle.sha256.count == 32)
        #expect(index.bundle.cdhash.first == 0x1e)
        #expect(index.bundle.path == "macrock-engine-0.1.1.bundle")
    }

    @Test func refusesAnotherIndexSchema() throws {
        let url = try file("index.json", #"{"schema": 1}"#)
        #expect(throws: EngineError.unsupportedSchema("index.json", 1)) {
            try EngineIndex(contentsOf: url)
        }
    }

    @Test(arguments: [
        ("../macrock-engine-0.1.1.aar", "macrock-engine-0.1.1.bundle"),
        ("macrock-engine-0.1.1.aar", "bundles/macrock-engine-0.1.1.bundle"),
        ("macrock-engine-0.1.1.aar", ".."),
    ])
    func refusesAReleaseFileNameThatIsAPath(file name: String, path: String) {
        #expect(throws: DecodingError.self) {
            try EngineIndex(json: Data(releaseIndex(file: name, path: path).utf8))
        }
    }

    @Test func runsOnTheRequiredMacOSAndLaterOnes() throws {
        let index = try EngineIndex(json: Data(releaseIndex(macOS: "27.1").utf8))
        try index.checkCompatibility(serviceProtocol: 1, macOS: macOS(27, 1, 0))
        try index.checkCompatibility(serviceProtocol: 1, macOS: macOS(27, 10, 0))
        #expect(throws: EngineError.needsMacOS("27.1")) {
            try index.checkCompatibility(serviceProtocol: 1, macOS: macOS(27, 0, 5))
        }
    }

    @Test func needsTheServiceProtocolOfTheApp() throws {
        let index = try EngineIndex(json: Data(releaseIndex(serviceProtocol: 2).utf8))
        #expect(throws: EngineError.serviceProtocolMismatch(engine: 2, service: 1)) {
            try index.checkCompatibility(serviceProtocol: 1, macOS: macOS(27, 0, 0))
        }
    }

    @Test(arguments: ["4.0b2", "4.1"])
    func takesD3DMetalOfTheRequiredToolkit(version: String) throws {
        try EngineIndex.Requirements(gptk: "4", macos: "27.0").checkD3DMetal(version: version)
    }

    @Test(arguments: ["3.1", "40.0", "5.0b1"])
    func refusesD3DMetalOfAnotherToolkit(version: String) {
        #expect(throws: SessionError.unsupportedD3DMetal(found: version, required: "4")) {
            try EngineIndex.Requirements(gptk: "4", macos: "27.0").checkD3DMetal(version: version)
        }
    }

    private func macOS(_ major: Int, _ minor: Int, _ patch: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    @Test func readsThePrefixSetupOfRelease010() throws {
        let setup = try PrefixSetup(
            contentsOf: file(
                "setup.json",
                """
                {
                  "schema": 1,
                  "revision": 1,
                  "dll_overrides": "mscoree,mshtml=;xgameruntime=n",
                  "game_drive": "g:",
                  "steps": [
                    {
                      "id": "xgameruntime",
                      "copy": "lib/macrock-engine/x86_64-windows/xgameruntime.dll",
                      "to": "drive_c/windows/system32/xgameruntime.dll"
                    },
                    {
                      "id": "winappsdk-1.8",
                      "reg": "share/macrock-engine/prefix/winappsdk-1.8.reg"
                    }
                  ]
                }
                """))
        #expect(setup.gameDrive == "g:")
        #expect(setup.dllOverrides == "mscoree,mshtml=;xgameruntime=n")
        #expect(
            setup.steps == [
                .init(
                    id: "xgameruntime",
                    action: .copy(
                        "lib/macrock-engine/x86_64-windows/xgameruntime.dll",
                        to: "drive_c/windows/system32/xgameruntime.dll")),
                .init(
                    id: "winappsdk-1.8",
                    action: .registry("share/macrock-engine/prefix/winappsdk-1.8.reg")),
            ])
    }

    @Test(arguments: [
        #"{"id": "a", "copy": "x.dll", "to": "y.dll", "reg": "z.reg"}"#,
        #"{"id": "a"}"#,
        #"{"id": "a", "copy": "x.dll"}"#,
        #"{"id": "a", "reg": "/etc/z.reg"}"#,
        #"{"id": "a", "copy": "x.dll", "to": "drive_c/../../y.dll"}"#,
    ])
    func refusesAnInvalidStep(step: String) throws {
        let url = try file(
            "setup.json",
            #"{"schema": 1, "revision": 1, "dll_overrides": "", "game_drive": "g:", "steps": [\#(step)]}"#
        )
        #expect(throws: EngineError.self) { try PrefixSetup(contentsOf: url) }
    }

    @Test func refusesAGameDriveThatIsNotALetter() throws {
        let url = try file(
            "setup.json",
            #"{"schema": 1, "revision": 1, "dll_overrides": "", "game_drive": "game", "steps": []}"#
        )
        #expect(throws: EngineError.invalidPrefixSetup("game drive game")) {
            try PrefixSetup(contentsOf: url)
        }
    }
}

struct EngineRuntimeTests {
    let temporary: TemporaryDirectory
    let bundle: URL

    init() async throws {
        temporary = try TemporaryDirectory()
        bundle = try await makeEngineBundle(in: temporary.url, version: "0.1.1")
    }

    func index(version: String = "0.1.1", cdhash: Data? = nil) async throws -> EngineIndex {
        let bundle = bundle
        let cdhash = try await runOnDedicatedThread { try cdhash ?? StaticCode(bundle).cdhash() }
        return try EngineIndex(
            json: Data(releaseIndex(version: version, cdhash: cdhash.hexadecimal).utf8))
    }

    func open(with index: EngineIndex) async throws -> EngineRuntime {
        try await runOnDedicatedThread { [bundle] in
            try EngineRuntime(bundle: bundle, index: index)
        }
    }

    @Test func opensTheBundleTheIndexDescribes() async throws {
        let engine = try await open(with: index())
        #expect(engine.version == "0.1.1")
        #expect(engine.wine == bundle.appending(path: "Contents/Resources/runtime/bin/wine"))
        #expect(engine.prefixSetup.gameDrive == "g:")
        #expect(engine.identity.hasPrefix("0.1.1-"))
        #expect(engine.identity.count == "0.1.1-".count + 12)
    }

    @Test func refusesAnotherVersion() async throws {
        let index = try await index(version: "0.2.0")
        await #expect(throws: EngineError.versionMismatch(found: "0.1.1", expected: "0.2.0")) {
            try await open(with: index)
        }
    }

    @Test func refusesAnotherBuild() async throws {
        let index = try await index(cdhash: Data(count: 20))
        await #expect(throws: EngineError.buildMismatch) { try await open(with: index) }
    }

    @Test func refusesAChangedRuntimeFile() async throws {
        let index = try await index()
        try Data("changed".utf8).write(
            to: bundle.appending(path: "Contents/Resources/runtime/bin/wine"))
        await #expect(throws: EngineError.sealBroken) { try await open(with: index) }
    }

    @Test func refusesABundleThatIsNotAnEngine() async throws {
        let info = bundle.appending(path: "Contents/Info.plist")
        var plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil)
                as? [String: Any])
        plist["CFBundleIdentifier"] = "dev.macrock.other"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: info)
        let index = try await index(cdhash: Data(count: 20))
        await #expect(throws: EngineError.notAnEngineBundle) { try await open(with: index) }
    }
}

/// A minimal engine bundle, sealed ad hoc like a release.
func makeEngineBundle(in directory: URL, version: String) async throws -> URL {
    let bundle = directory.appending(path: "macrock-engine-\(version).bundle")
    let runtime = bundle.appending(path: "Contents/Resources/runtime")
    let prefix = runtime.appending(path: "share/macrock-engine/prefix")
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: runtime.appending(path: "bin"), withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "dev.macrock.engine", "CFBundlePackageType": "BNDL",
        "CFBundleShortVersionString": version, "CFBundleVersion": "1",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundle.appending(path: "Contents/Info.plist"))
    try Data("#!/bin/sh\n".utf8).write(to: runtime.appending(path: "bin/wine"))
    let documentation = runtime.appending(path: "share/doc/macrock-engine")
    try FileManager.default.createDirectory(at: documentation, withIntermediateDirectories: true)
    try Data("LGPL".utf8).write(to: documentation.appending(path: "COPYING.LIB"))
    try Data(
        #"{"schema": 1, "revision": 1, "dll_overrides": "mscoree,mshtml=", "game_drive": "g:", "steps": []}"#
            .utf8
    ).write(to: prefix.appending(path: "setup.json"))
    try await runTool("/usr/bin/codesign", ["--sign", "-", bundle.path])
    return bundle
}
