import Foundation

/// Minecraft for Windows as Microsoft's Store sells it. Each product installs on its own and
/// keeps its data apart in an account's prefix.
public enum GameProduct: String, Codable, Sendable, CaseIterable {
    case release
    case preview

    public var storeID: String {
        switch self {
        case .release: "9NBLGGH2JHXJ"
        case .preview: "9P5X4QVLC2XR"
        }
    }

    /// The URI Windows activates the game with to open Minecraft Editor, with the scheme of the
    /// product's `MicrosoftGame.Config`.
    var editorActivation: String {
        switch self {
        case .release: "minecraft://creator/?Editor=true"
        case .preview: "minecraft-preview://creator/?Editor=true"
        }
    }

    /// The folder of `%APPDATA%` where the product keeps worlds, packs and settings.
    var dataFolder: String {
        switch self {
        case .release: "Minecraft Bedrock"
        case .preview: "Minecraft Bedrock Preview"
        }
    }

    init?(storeID: String) {
        guard let product = Self.allCases.first(where: { $0.storeID == storeID }) else {
            return nil
        }
        self = product
    }
}

/// What PLAY plays: an installation of a product, and how it runs. Every account plays the same
/// profiles.
public struct Profile: Codable, Sendable, Equatable, Identifiable {
    /// How the game runs. A change applies from the next session.
    public struct Settings: Codable, Sendable, Equatable {
        public var backend = MetalBackend.metal4
        public var usesMsync = true
        /// Wine's Retina mode: D3DMetal renders at the display's pixels instead of its points,
        /// at a fraction of the frame rate.
        public var usesRetinaMode = false
        public var showsMetalHUD = false
        /// The engine's record of every second's frame rate, in the session's folder.
        public var writesFPSLog = true

        public init() {}
    }

    public enum Kind: String, Codable, Sendable {
        /// Plays what Microsoft serves of its product now: an update replaces its installation.
        case latest
        /// Plays a copy of an earlier version, kept when an update replaced it: Microsoft serves
        /// only the latest. It never changes.
        case kept
    }

    public let id: UUID
    /// The name the player gave the profile; nil while it goes by the launcher's.
    public var name: String?
    public let product: GameProduct
    public let kind: Kind
    /// The installation the profile plays; nil until its product is installed.
    public var installation: UUID?
    public var settings = Settings()

    public init(product: GameProduct) {
        id = UUID()
        self.product = product
        kind = .latest
    }

    /// A profile that keeps playing `installation`, with the settings of the profile it played
    /// for until now.
    init(keeping installation: UUID, of profile: Profile) {
        id = UUID()
        product = profile.product
        kind = .kept
        self.installation = installation
        settings = profile.settings
    }

    /// A copy of `profile` under another name, playing the same installation with the same
    /// settings.
    init(copying profile: Profile, named name: String) {
        id = UUID()
        self.name = name
        product = profile.product
        kind = profile.kind
        installation = profile.installation
        settings = profile.settings
    }
}

extension Profile {
    public func followsLatest(of product: GameProduct) -> Bool {
        kind == .latest && self.product == product
    }
}

extension Profile {
    /// Libraries written by earlier launchers lack the fields added since.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        product = try container.decode(GameProduct.self, forKey: .product)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .latest
        installation = try container.decodeIfPresent(UUID.self, forKey: .installation)
        settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
    }
}

extension Profile.Settings {
    /// Libraries written by earlier launchers lack the settings added since.
    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = try container.decodeIfPresent(MetalBackend.self, forKey: .backend) ?? backend
        usesMsync = try container.decodeIfPresent(Bool.self, forKey: .usesMsync) ?? usesMsync
        usesRetinaMode =
            try container.decodeIfPresent(Bool.self, forKey: .usesRetinaMode) ?? usesRetinaMode
        showsMetalHUD =
            try container.decodeIfPresent(Bool.self, forKey: .showsMetalHUD) ?? showsMetalHUD
        writesFPSLog =
            try container.decodeIfPresent(Bool.self, forKey: .writesFPSLog) ?? writesFPSLog
    }
}
