import CryptoKit
import Foundation

@testable import LauncherCore

/// An `index.json` of schema 2, with the fields tests change.
func releaseIndex(
    version: String = "0.1.1", macOS: String = "27.0", serviceProtocol: Int = 1,
    file: String = "macrock-engine-0.1.1.aar", size: Int = 49_611_888,
    sha256: String = "f43931713dfdc3843ecea50b62c8c9361a04c9da8bc0691915b838b8ffb6a9c0",
    cdhash: String = "1ecbab43d666cbf89169766906efe6eb99731ce3",
    path: String = "macrock-engine-0.1.1.bundle"
) -> String {
    """
    {
      "schema": 2,
      "name": "macrock-engine",
      "version": "\(version)",
      "build": 1,
      "published": "2026-10-09T14:19:14Z",
      "engine_commit": "b6d05eec9315146dcd34d63d94c0a4e45380c582",
      "dirty": false,
      "arch": "x86_64",
      "requires": {"gptk": "4", "macos": "\(macOS)", "rosetta": true},
      "service_protocol": \(serviceProtocol),
      "prefix_setup": {"schema": 1, "revision": 1},
      "components": {},
      "bundle": {
        "file": "\(file)",
        "size": \(size),
        "sha256": "\(sha256)",
        "sealed": true,
        "cdhash": "\(cdhash)",
        "path": "\(path)"
      },
      "helper": {
        "file": "xodus-service-0.1.1-arm64.aar",
        "size": 3489352,
        "sha256": "7dd4f70191efd531097ba308e339987e167e83399e64742b00bacd9a09df5cd3",
        "arch": "arm64",
        "path": "xodus-service-0.1.1/xodus-service"
      }
    }
    """
}

/// A folder laid out as a release: a runtime archive and the index that names it.
struct ReleaseFolder {
    let releases: EngineReleases
    let archive: URL

    init(in directory: URL, archive contents: Data, cdhash: Data = Data(count: 20)) throws {
        let url = directory.appending(path: "releases")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        archive = url.appending(path: "macrock-engine-0.1.1.aar")
        try contents.write(to: archive)
        try Data(
            releaseIndex(
                size: contents.count, sha256: Data(SHA256.hash(data: contents)).hexadecimal,
                cdhash: cdhash.hexadecimal
            ).utf8
        ).write(to: url.appending(path: "index.json"))
        releases = EngineReleases(url: url)
    }

    /// A release of an engine bundle, archived as the engine's `package.sh` does it.
    static func packaging(_ bundle: URL, in directory: URL) async throws -> ReleaseFolder {
        let archive = directory.appending(path: "packaged.aar")
        try await runTool("/usr/bin/aa", ["archive", "-D", bundle.path, "-o", archive.path])
        let cdhash = try await runOnDedicatedThread { try StaticCode(bundle).cdhash() }
        return try ReleaseFolder(in: directory, archive: Data(contentsOf: archive), cdhash: cdhash)
    }
}
