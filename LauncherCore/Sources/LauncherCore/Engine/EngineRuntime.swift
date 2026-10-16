import Foundation

/// An engine bundle that matches its release's index. Opening one checks every file of it, which
/// takes a fraction of a second: run it off the main actor and the cooperative pool.
public struct EngineRuntime: Sendable {
    public static let bundleIdentifier = "dev.macrock.engine"

    public let bundle: URL
    public let index: EngineIndex
    public let prefixSetup: PrefixSetup

    public init(bundle: URL, index: EngineIndex) throws {
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: bundle.appending(path: "Contents/Info.plist")), format: nil)
        guard let info = info as? [String: Any],
            info["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
            let version = info["CFBundleShortVersionString"] as? String
        else {
            throw EngineError.notAnEngineBundle
        }
        guard version == index.version else {
            throw EngineError.versionMismatch(found: version, expected: index.version)
        }
        do {
            let code = try StaticCode(bundle)
            guard try code.cdhash() == index.bundle.cdhash else { throw EngineError.buildMismatch }
            try code.validate()
        } catch is CodeSignatureError {
            throw EngineError.sealBroken
        }
        self.bundle = bundle
        self.index = index
        prefixSetup = try PrefixSetup(
            contentsOf: bundle.appending(
                path: "\(Self.runtimePath)/share/macrock-engine/prefix/setup.json"))
    }

    public var version: String { index.version }
    static let runtimePath = "Contents/Resources/runtime"

    public var runtime: URL { bundle.appending(path: Self.runtimePath) }
    public var wine: URL { runtime.appending(path: "bin/wine") }

    /// Names this exact build: a prefix booted by another one needs `wineboot -u`.
    public var identity: String { "\(version)-\(index.bundle.cdhash.hexadecimal.prefix(12))" }
}

public enum EngineError: Error, Equatable {
    case notAnEngineBundle
    case versionMismatch(found: String, expected: String)
    /// The bundle's code directory hash isn't the one in the index.
    case buildMismatch
    /// A file of the bundle was changed, added or removed since it was sealed.
    case sealBroken
    case unsupportedSchema(String, Int)
    case invalidPrefixSetup(String)
    case needsMacOS(String)
    case serviceProtocolMismatch(engine: Int, service: Int)
}
