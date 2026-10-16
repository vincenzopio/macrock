import Foundation

/// Apple's Game Porting Toolkit disk image. D3DMetal is in the `redist/lib` of the "Evaluation
/// environment for Windows games" image inside it, beside Apple's license.
public struct ToolkitImage: Sendable {
    /// What the user reads and accepts before D3DMetal is copied.
    public struct License: Sendable {
        public let rtf: Data
        public let version: String
    }

    public let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    /// Copies D3DMetal and Apple's license into `graphics/gptk-<version>`, checks the copy, and
    /// leaves no other import there. Apple's files are copied as they are, symbolic links and
    /// extended attributes included: `libd3dshared` finds D3DMetal through a link.
    ///
    /// Apple's license comes first. When the image that holds D3DMetal carries it as its license
    /// agreement, macOS shows it and attaches the image only once the user agrees; otherwise
    /// `acceptLicense` shows it. Returns nil when the user declines it there.
    public func importD3DMetal(
        into directory: DataDirectory, requiring requirements: EngineIndex.Requirements?,
        acceptLicense: (License) async -> Bool
    ) async throws -> D3DMetalPayload? {
        try await withPayloadVolume { volume, agreedInMacOS in
            let lib = volume.appending(path: Self.lib)
            guard let version = D3DMetalPayload.statedVersion(at: lib) else {
                throw GraphicsError.notAToolkitImage
            }
            try requirements?.checkD3DMetal(version: version)
            if !agreedInMacOS {
                let rtf = try Data(contentsOf: volume.appending(path: Self.license))
                guard await acceptLicense(License(rtf: rtf, version: version)) else { return nil }
            }
            return try await runOnDedicatedThread {
                try Self.copy(from: volume, into: directory.graphics)
            }
        }
    }

    public static func license(forImportAt lib: URL) -> URL? {
        let file = lib.deletingLastPathComponent().appending(path: license)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private static let lib = "redist/lib"
    private static let license = "License.rtf"

    private static func copy(from volume: URL, into graphics: URL) throws -> D3DMetalPayload {
        let manager = FileManager.default
        let source = try D3DMetalPayload(lib: volume.appending(path: lib))
        let staging = graphics.appending(path: ".staging-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItemIfPresent(at: staging) }
        try manager.copyItem(at: source.lib, to: staging.appending(path: "lib"))
        try manager.copyItem(
            at: volume.appending(path: license), to: staging.appending(path: license))
        _ = try D3DMetalPayload(lib: staging.appending(path: "lib"))
        let destination = graphics.appending(path: "gptk-\(source.version)")
        try manager.removeItemIfPresent(at: destination)
        try manager.moveItem(at: staging, to: destination)
        for name in try manager.contentsOfDirectory(atPath: graphics.path)
        where name != destination.lastPathComponent {
            try manager.removeItem(at: graphics.appending(path: name))
        }
        return try D3DMetalPayload(lib: destination.appending(path: "lib"))
    }

    /// Runs `body` with the volume that holds D3DMetal and the license: this image, or the first
    /// image inside it that does. `body` learns whether macOS already had the user accept that
    /// image's license agreement.
    private func withPayloadVolume<Value>(
        _ body: (URL, _ agreedInMacOS: Bool) async throws -> Value
    ) async throws -> Value {
        try await Self.mount(url) { volume, agreed in
            if Self.holdsPayload(volume) {
                return try await body(volume, agreed)
            }
            let images = try FileManager.default.contentsOfDirectory(
                at: volume, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "dmg" }
            for image in images {
                let found = try await Self.mount(image) { inner, agreed in
                    Self.holdsPayload(inner) ? try await body(inner, agreed) : nil
                }
                if let found {
                    return found
                }
            }
            throw GraphicsError.notAToolkitImage
        }
    }

    /// Mounts an image, telling `body` whether it carries a license agreement: macOS attaches
    /// such an image only once the user agrees, so failing to attach it means they declined.
    private static func mount<Value>(
        _ url: URL, _ body: (URL, _ agreed: Bool) async throws -> Value
    ) async throws -> Value {
        let image = DiskImage(url)
        let agreement = image.carriesLicenseAgreement
        do {
            return try await image.withMounted { try await body($0, agreement) }
        } catch DiskImageError.notADiskImage where agreement {
            throw GraphicsError.licenseDeclined
        }
    }

    private static func holdsPayload(_ volume: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: volume.appending(path: "\(lib)/external").path)
            && manager.fileExists(atPath: volume.appending(path: license).path)
    }
}
