import Foundation
import os

/// A disk image, attached read-only while a closure looks into it, out of the Finder's sight
/// unless it carries a license agreement. `diskutil image` does the work: `hdiutil attach` is
/// deprecated in macOS 27.
struct DiskImage {
    let url: URL

    init(_ url: URL) {
        self.url = url
    }

    /// Attaches the image, runs `body` with its mounted volume, then ejects the image whatever
    /// `body` does. macOS picks the mount point: `diskutil` honours a chosen one only for images
    /// with a single partition. An image that is already attached, by the Finder for one, is used
    /// as it is, and stays attached.
    ///
    /// An image that carries a license agreement is attached by DiskImageMounter, which shows the
    /// agreement in a window, as the Finder does: `diskutil` shows an agreement whose text it can
    /// read only in a terminal, and cancels the attach without one, even for an image that is
    /// attached already. Throws `DiskImageError.licenseDeclined` when the user doesn't agree.
    func withMounted<Value>(_ body: (URL) async throws -> Value) async throws -> Value {
        let existing = try await existingAttachment()
        let attachment: Attachment
        if let existing {
            attachment = existing
        } else if carriesLicenseAgreement {
            _ = try await Self.run(
                "/usr/bin/open", ["-W", "-b", "com.apple.DiskImageMounter", url.path])
            guard let agreed = try await existingAttachment() else {
                throw DiskImageError.licenseDeclined
            }
            attachment = agreed
        } else {
            do {
                let output = try await Self.diskutil(
                    ["image", "attach", "--plist", "--readOnly", "--nobrowse", url.path])
                attachment = try PropertyListDecoder().decode(Attachment.self, from: output)
            } catch {
                throw DiskImageError.notADiskImage
            }
        }
        guard let disk = attachment.entities.lazy.compactMap(\.device).first else {
            throw DiskImageError.notADiskImage
        }
        let result: Result<Value, any Error>
        if let volume = attachment.entities.lazy.compactMap(\.mountPoint).first {
            do {
                result = .success(
                    try await body(URL(filePath: volume, directoryHint: .isDirectory)))
            } catch {
                result = .failure(error)
            }
        } else {
            result = .failure(DiskImageError.noVolume)
        }
        if existing == nil {
            do {
                _ = try await Self.diskutil(["eject", disk])
            } catch {
                Logger.install.error("Ejecting \(disk, privacy: .public) failed: \(error)")
            }
        }
        return try result.get()
    }

    /// Whether macOS shows a license agreement when it attaches the image, and attaches it only
    /// once the user agrees. A UDIF image ends with a 512-byte `koly` block that locates a
    /// property list of its resources, the agreement being the `LPic` one. An image this can't
    /// read is taken to carry none.
    var carriesLicenseAgreement: Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd(), end >= 512,
            (try? file.seek(toOffset: end - 512)) != nil,
            let trailer = try? file.read(upToCount: 512), trailer.starts(with: Data("koly".utf8))
        else {
            return false
        }
        func number(at offset: Int) -> UInt64 {
            trailer[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
        }
        let resourcesOffset = number(at: 0xD8)
        let resourcesLength = number(at: 0xE0)
        guard resourcesLength < 64 << 20, (try? file.seek(toOffset: resourcesOffset)) != nil,
            let xml = try? file.read(upToCount: Int(resourcesLength)),
            let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil),
            let resources = (plist as? [String: Any])?["resource-fork"] as? [String: Any]
        else {
            return false
        }
        return resources["LPic"] != nil
    }

    /// The attachment of this image file, if it is attached already. `diskutil` has no list of
    /// attached images; `hdiutil info` has, and unlike `hdiutil attach` it is not deprecated.
    private func existingAttachment() async throws -> Attachment? {
        struct Info: Decodable {
            struct Image: Decodable {
                let path: String
                let entities: [Attachment.Entity]?

                private enum CodingKeys: String, CodingKey {
                    case path = "image-path"
                    case entities = "system-entities"
                }
            }

            let images: [Image]
        }
        let output = try await Self.run("/usr/bin/hdiutil", ["info", "-plist"])
        let file = url.resolvingSymlinksInPath()
        let image = try PropertyListDecoder().decode(Info.self, from: output).images.first {
            URL(filePath: $0.path).resolvingSymlinksInPath() == file
        }
        return image.map { Attachment(entities: $0.entities ?? []) }
    }

    private static func diskutil(_ arguments: [String]) async throws -> Data {
        try await run("/usr/sbin/diskutil", arguments)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        let name = "macrock-\(UUID().uuidString)"
        let outputFile = FileManager.default.temporaryDirectory.appending(path: "\(name).out")
        let errorsFile = FileManager.default.temporaryDirectory.appending(path: "\(name).err")
        for file in [outputFile, errorsFile] {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        defer {
            for file in [outputFile, errorsFile] {
                try? FileManager.default.removeItemIfPresent(at: file)
            }
        }
        let output = try FileHandle(forWritingTo: outputFile)
        let errors = try FileHandle(forWritingTo: errorsFile)
        let child = try ChildProcess.run(
            URL(filePath: tool), arguments: arguments,
            environment: HostEnvironment.current.variables, output: output, errors: errors)
        let termination = await child.termination
        try output.close()
        try errors.close()
        guard termination == .exited(0) else {
            let message = String(
                decoding: FileManager.default.contents(atPath: errorsFile.path) ?? Data(),
                as: UTF8.self)
            Logger.install.error(
                "\(tool, privacy: .public) \(arguments[0], privacy: .public) failed: \(message)")
            throw DiskImageError.toolFailed(arguments[0], termination)
        }
        return try Data(contentsOf: outputFile)
    }

    private struct Attachment: Decodable {
        /// `hdiutil info` lists an image that is still being attached with entities that have no
        /// device yet.
        struct Entity: Decodable {
            let device: String?
            let mountPoint: String?

            private enum CodingKeys: String, CodingKey {
                case device = "dev-entry"
                case mountPoint = "mount-point"
            }
        }

        /// The image's whole disk first, then its partitions and volumes.
        let entities: [Entity]

        private enum CodingKeys: String, CodingKey {
            case entities = "system-entities"
        }
    }
}

public enum DiskImageError: Error, Equatable {
    /// `diskutil` couldn't attach it: not a disk image, or an encrypted one.
    case notADiskImage
    /// It holds no volume macOS can mount.
    case noVolume
    /// The user didn't agree to its license agreement.
    case licenseDeclined
    case toolFailed(String, Termination)
}
