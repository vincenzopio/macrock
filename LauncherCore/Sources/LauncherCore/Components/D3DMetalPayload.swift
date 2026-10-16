import Foundation

/// D3DMetal as imported from Apple's Game Porting Toolkit: the `lib` directory the engine loads
/// through `WINEDLLPATH_PREPEND` and `CX_APPLEGPTK_LIBD3DSHARED_PATH`.
public struct D3DMetalPayload: Sendable {
    /// The DLLs the game environment overrides with D3DMetal's builtin ones.
    static let libraries = ["d3d12", "d3d11", "d3d10", "dxgi"]
    private static let sharedLibrary = "external/libd3dshared.dylib"

    public let lib: URL
    /// D3DMetal's version, such as `4.0b2`.
    public let version: String

    /// Checks the layout and Apple's signatures of D3DMetal and libd3dshared.
    public init(lib: URL) throws {
        for name in Self.libraries {
            let dll = lib.appending(path: "wine/x86_64-windows/\(name).dll")
            guard FileManager.default.fileExists(atPath: dll.path) else {
                throw GraphicsError.missingFile("wine/x86_64-windows/\(name).dll")
            }
            let link = lib.appending(path: "wine/x86_64-unix/\(name).so")
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            guard target == "../../external/libd3dshared.dylib" else {
                throw GraphicsError.brokenLink("wine/x86_64-unix/\(name).so")
            }
        }
        guard let version = Self.statedVersion(at: lib) else {
            throw GraphicsError.missingFile("external/D3DMetal.framework")
        }
        try StaticCode(lib.appending(path: "external/D3DMetal.framework")).validate(
            requirement: #"anchor apple and identifier "com.apple.D3DMetal""#)
        try StaticCode(lib.appending(path: Self.sharedLibrary)).validate(
            requirement: #"anchor apple and identifier "com.apple.libd3dshared""#)
        self.lib = lib
        self.version = version
    }

    init(lib: URL, version: String) {
        self.lib = lib
        self.version = version
    }

    public var libd3dshared: URL { lib.appending(path: Self.sharedLibrary) }

    /// Whether the import at `lib` is still on disk, unchecked: sessions check its files and
    /// signatures.
    public static func isPresent(at lib: URL) -> Bool {
        FileManager.default.fileExists(atPath: lib.appending(path: sharedLibrary).path)
    }

    /// The version the bundle states, unchecked.
    public static func statedVersion(at lib: URL) -> String? {
        Bundle(url: lib.appending(path: "external/D3DMetal.framework"))?
            .infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

public enum GraphicsError: Error, Equatable {
    case missingFile(String)
    case brokenLink(String)
    /// No D3DMetal and Apple license in the disk image, or in an image inside it.
    case notAToolkitImage
    /// macOS didn't attach the image that carries Apple's license: the user declined it.
    case licenseDeclined
}
