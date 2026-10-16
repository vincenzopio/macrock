import Foundation

/// The launcher's non-secret metadata, kept in `library.json`.
public struct Library: Codable, Sendable, Equatable {
    private static let currentVersion = 1

    private var version = Library.currentVersion
    /// When the first-run wizard was finished; until then the launcher shows it.
    public var setupCompleted: Date?
    /// The identity of the engine sessions use, in the engine store.
    public private(set) var engine: String?
    /// The engine it replaced, kept to go back to.
    public private(set) var previousEngine: String?
    public var accounts: [Account] = []
    public var selectedAccount: Account.ID?
    /// The `lib` directory of the Game Porting Toolkit import.
    public var graphics: URL?
    /// When the player agreed to install packages whose origin can't be verified; asked once.
    public var packageConsent: Date?
    /// What PLAY can play: for each product, at least one profile that follows the latest
    /// version Microsoft serves, then the player's copies and the versions kept at updates.
    public private(set) var profiles = GameProduct.allCases.map(Profile.init(product:))
    public var selectedProfile: Profile.ID?
    /// Whether the user was told how to answer the game's sign-in prompt.
    public var toldAboutSignInPrompt = false

    public init() {
        selectedProfile = profiles.first?.id
    }

    public var engines: Set<String> {
        Set([engine, previousEngine].compactMap(\.self))
    }

    public func account(_ id: Account.ID) -> Account? {
        accounts.first { $0.id == id }
    }

    public func profile(_ id: Profile.ID) -> Profile? {
        profiles.first { $0.id == id }
    }

    public func latestProfile(of product: GameProduct) -> Profile? {
        profiles.first { $0.followsLatest(of: product) }
    }

    public mutating func useEngine(_ identity: String) {
        guard identity != engine else { return }
        previousEngine = engine
        engine = identity
    }

    /// Called before the account's service can register anything, so that the launcher can remove
    /// what it registers even after a crash.
    public mutating func addPendingAccount(_ account: Account) {
        var account = account
        account.isPending = true
        accounts.append(account)
    }

    /// The first account to sign in becomes the selected one.
    public mutating func markSignedIn(_ id: Account.ID, gamertag: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].label = gamertag
        accounts[index].isPending = false
        accounts[index].needsSignIn = false
        if selectedAccount == nil {
            selectedAccount = id
        }
    }

    /// The profiles that follow the latest version of a product all play the same installation.
    public mutating func setInstallation(_ installation: UUID?, of profile: Profile.ID) {
        guard let changed = self.profile(profile) else { return }
        let sharing = changed.kind == .latest
        for index in profiles.indices
        where profiles[index].id == profile
            || (sharing && profiles[index].followsLatest(of: changed.product))
        {
            profiles[index].installation = installation
        }
    }

    /// Nil gives the profile the launcher's name back.
    public mutating func setName(_ name: String?, of profile: Profile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == profile }) else { return }
        profiles[index].name = name
    }

    public mutating func setSettings(_ settings: Profile.Settings, of profile: Profile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == profile }) else { return }
        profiles[index].settings = settings
    }

    /// Keeps the installation the profile plays as a profile of its own, since once an update has
    /// replaced it, it can't be downloaded again.
    public mutating func keepCopy(of profile: Profile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == profile }),
            let installation = profiles[index].installation
        else { return }
        profiles.insert(Profile(keeping: installation, of: profiles[index]), at: index + 1)
    }

    @discardableResult
    public mutating func duplicate(_ profile: Profile.ID, named name: String) -> Profile.ID? {
        guard let index = profiles.firstIndex(where: { $0.id == profile }) else { return nil }
        let copy = Profile(copying: profiles[index], named: name)
        profiles.insert(copy, at: index + 1)
        return copy.id
    }

    /// Every profile can be removed except the last one that follows its product's latest version.
    public func canRemoveProfile(_ id: Profile.ID) -> Bool {
        guard let profile = profile(id) else { return false }
        return profile.kind == .kept
            || profiles.contains { $0.id != id && $0.followsLatest(of: profile.product) }
    }

    /// A selected profile gives way to one that follows the latest version of its product.
    public mutating func removeProfile(_ id: Profile.ID) {
        guard canRemoveProfile(id), let removed = profile(id) else { return }
        profiles.removeAll { $0.id == id }
        if selectedProfile == id {
            selectedProfile = latestProfile(of: removed.product)?.id
        }
    }

    /// Brings the profiles in line with the installations on disk, given newest first. Kept
    /// profiles whose installation is gone are removed. A profile that follows a product's latest
    /// version and has lost its installation, or never had one, takes the newest installation of
    /// the product that no other profile plays, such as one finished just before the launcher
    /// quit.
    public mutating func reconcile(with installed: [Installation]) {
        let present = Set(installed.map(\.id))
        for profile in profiles
        where profile.kind == .kept && profile.installation.map(present.contains) != true {
            removeProfile(profile.id)
        }
        for product in GameProduct.allCases {
            guard let latest = latestProfile(of: product),
                latest.installation.map(present.contains) != true
            else { continue }
            let played = Set(profiles.compactMap(\.installation))
            let newest = installed.first { $0.product == product && !played.contains($0.id) }
            setInstallation(newest?.id, of: latest.id)
        }
    }

    public mutating func noteKeychainAccess(of id: Account.ID, by cdhash: Data) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].lastServiceCDHash = cdhash
    }

    public mutating func requireSignIn(of id: Account.ID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].needsSignIn = true
    }

    public mutating func removeAccount(_ id: Account.ID) {
        accounts.removeAll { $0.id == id }
        if selectedAccount == id {
            selectedAccount = accounts.first { !$0.isPending }?.id
        }
    }

    /// An empty library when the file does not exist yet.
    public init(contentsOf file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            self.init()
            return
        }
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        let version = try decoder.decode(Header.self, from: data).version
        guard version == Self.currentVersion else {
            throw LibraryError.unsupportedVersion(version)
        }
        self = try decoder.decode(Library.self, from: data)
    }

    public func write(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    private struct Header: Decodable {
        let version: Int
    }
}

extension Library {
    /// Libraries written by earlier launchers lack the fields added since.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        setupCompleted = try container.decodeIfPresent(Date.self, forKey: .setupCompleted)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        previousEngine = try container.decodeIfPresent(String.self, forKey: .previousEngine)
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        selectedAccount = try container.decodeIfPresent(Account.ID.self, forKey: .selectedAccount)
        graphics = try container.decodeIfPresent(URL.self, forKey: .graphics)
        packageConsent = try container.decodeIfPresent(Date.self, forKey: .packageConsent)
        if let profiles = try container.decodeIfPresent([Profile].self, forKey: .profiles) {
            self.profiles = profiles
        }
        selectedProfile =
            try container.decodeIfPresent(Profile.ID.self, forKey: .selectedProfile)
            ?? profiles.first?.id
        toldAboutSignInPrompt =
            try container.decodeIfPresent(Bool.self, forKey: .toldAboutSignInPrompt) ?? false
    }
}

public enum LibraryError: Error, Equatable {
    case unsupportedVersion(Int)
}
