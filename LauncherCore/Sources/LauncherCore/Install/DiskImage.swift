import Foundation
import os

/// A disk image, attached read-only and out of the Finder's sight while a closure looks into it.
/// `diskutil image` does the work: `hdiutil attach` is deprecated in macOS 27.
struct DiskImage {
    let url: URL

    init(_ url: URL) {
        self.url = url
    }

    /// Attaches the image, runs `body` with its mounted volume, then ejects the image whatever
    /// `body` does. macOS picks the mount point: `diskutil` honours a chosen one only for images
    /// with a single partition. An image that is already attached, by the Finder for one, comes
    /// back as the same disk, and stays attached.
    func withMounted<Value>(_ body: (URL) async throws -> Value) async throws -> Value {
        let attachedBefore = try await isAttached()
        let attachment: Attachment
        do {
            let output = try await Self.diskutil(
                ["image", "attach", "--plist", "--readOnly", "--nobrowse", url.path])
            attachment = try PropertyListDecoder().decode(Attachment.self, from: output)
        } catch {
            throw DiskImageError.notADiskImage
        }
        guard let disk = attachment.entities.first?.device else {
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
        if !attachedBefore {
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

    /// Whether this image file is attached already. `diskutil` has no list of attached images;
    /// `hdiutil info` has, and unlike `hdiutil attach` it is not deprecated.
    private func isAttached() async throws -> Bool {
        struct Info: Decodable {
            struct Image: Decodable {
                let path: String

                private enum CodingKeys: String, CodingKey {
                    case path = "image-path"
                }
            }

            let images: [Image]
        }
        let output = try await Self.run("/usr/bin/hdiutil", ["info", "-plist"])
        let file = url.resolvingSymlinksInPath()
        return try PropertyListDecoder().decode(Info.self, from: output).images.contains {
            URL(filePath: $0.path).resolvingSymlinksInPath() == file
        }
    }

    private static func diskutil(_ arguments: [String]) async throws -> Data {
        try await run("/usr/sbin/diskutil", arguments)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(
            path: "macrock-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItemIfPresent(at: file) }
        let output = try FileHandle(forWritingTo: file)
        let child = try ChildProcess.run(
            URL(filePath: tool), arguments: arguments,
            environment: HostEnvironment.current.variables, output: output, errors: .nullDevice)
        let termination = await child.termination
        try output.close()
        guard termination == .exited(0) else {
            throw DiskImageError.toolFailed(arguments[0], termination)
        }
        return try Data(contentsOf: file)
    }

    private struct Attachment: Decodable {
        struct Entity: Decodable {
            let device: String
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
    case toolFailed(String, Termination)
}
