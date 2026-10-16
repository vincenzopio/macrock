import Foundation

/// A pack the game loads from the shared `com.mojang`: a folder with its `manifest.json`.
public struct Pack: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, CaseIterable {
        case resources, behavior, skins

        /// Where the game looks for packs of the kind, in the shared `com.mojang`.
        var folder: String {
            switch self {
            case .resources: "resource_packs"
            case .behavior: "behavior_packs"
            case .skins: "skin_packs"
            }
        }
    }

    public let folder: URL
    public let kind: Kind
    public let name: String
    public let version: String
    public let icon: URL?
    /// The ID in its manifest, the same in every version of the pack.
    let uuid: UUID

    public var id: URL { folder }

    /// Reads the pack in `folder`. Manifests may have comments and trailing commas, which the
    /// game accepts.
    init(folder: URL) throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let manifest: Manifest
        do {
            manifest = try decoder.decode(
                Manifest.self, from: Data(contentsOf: folder.appending(path: "manifest.json")))
        } catch {
            throw ContentError.notAPack
        }
        let types = Set(manifest.modules.map(\.type))
        if types.contains("resources") {
            kind = .resources
        } else if !types.isDisjoint(with: ["data", "script"]) {
            kind = .behavior
        } else if types.contains("skin_pack") {
            kind = .skins
        } else {
            throw ContentError.unsupportedPack(types.sorted().joined(separator: ", "))
        }
        self.folder = folder
        name = try Self.localized(manifest.header.name, in: folder)
        version = manifest.header.version.text
        let icon = folder.appending(path: "pack_icon.png")
        self.icon = FileManager.default.fileExists(atPath: icon.path) ? icon : nil
        uuid = manifest.header.uuid
    }

    /// Packs often name themselves with a key of their English texts, `pack.name`.
    private static func localized(_ name: String, in folder: URL) throws -> String {
        let file = folder.appending(path: "texts/en_US.lang")
        guard FileManager.default.fileExists(atPath: file.path) else { return name }
        let texts = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        guard
            let line = texts.split(whereSeparator: \.isNewline).first(where: {
                $0.hasPrefix("\(name)=")
            })
        else { return name }
        return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
    }

    private struct Manifest: Decodable {
        struct Header: Decodable {
            let name: String
            let uuid: UUID
            let version: Version
        }

        /// `[1, 0, 0]`, or `"1.0.0"` in the manifests of format 3.
        struct Version: Decodable {
            let text: String

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let parts = try? container.decode([Int].self) {
                    text = parts.map(String.init).joined(separator: ".")
                } else {
                    text = try container.decode(String.self)
                }
            }
        }

        struct Module: Decodable {
            let type: String
        }

        let header: Header
        let modules: [Module]
    }
}
