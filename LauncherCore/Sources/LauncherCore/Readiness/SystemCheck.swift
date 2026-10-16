import Foundation

/// What this Mac offers the engine, for the first step of the first-run wizard.
public struct SystemCheck: Sendable, Equatable {
    /// Room for the engine (0.3 GB), D3DMetal (0.1 GB), the game (about 5 GB) and a prefix.
    public static let recommendedFreeSpace: Int64 = 8_000_000_000

    public let macOS: String
    public let rosettaInstalled: Bool
    /// Bytes free for important data on the volume of the launcher's files, when macOS says.
    public let freeSpace: Int64?

    init(macOS: String, rosettaInstalled: Bool, freeSpace: Int64?) {
        self.macOS = macOS
        self.rosettaInstalled = rosettaInstalled
        self.freeSpace = freeSpace
    }

    /// Looks at this Mac now. The directory must exist.
    public init(dataDirectory: DataDirectory) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let values = try? dataDirectory.root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        self.init(
            macOS: "\(version.majorVersion).\(version.minorVersion)",
            rosettaInstalled: Self.hasRosetta,
            freeSpace: values?.volumeAvailableCapacityForImportantUsage)
    }

    public var hasRoom: Bool {
        freeSpace.map { $0 >= Self.recommendedFreeSpace } ?? true
    }

    /// Whether Rosetta 2 can run the engine's x86_64 programs on this Mac.
    public static var hasRosetta: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    /// Installs Rosetta 2 with Apple's software update, once macOS has asked for an
    /// administrator's password. The user may cancel, or the download fail: `hasRosetta` tells.
    public static func installRosetta() async throws {
        let command = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
        let script = "do shell script \"\(command)\" with administrator privileges"
        let child = try ChildProcess.run(
            URL(filePath: "/usr/bin/osascript"), arguments: ["-e", script],
            environment: HostEnvironment.current.variables)
        _ = await child.termination
    }
}
