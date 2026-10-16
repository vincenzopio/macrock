import Foundation

/// The files of worlds and packs the game opens, by their extensions.
public enum ContentFile: String, CaseIterable, Sendable {
    case world = "mcworld"
    case pack = "mcpack"
    case addon = "mcaddon"

    /// The kind of `file`, or nil when it is none of them.
    public init?(_ file: URL) {
        self.init(rawValue: file.pathExtension.lowercased())
    }
}
