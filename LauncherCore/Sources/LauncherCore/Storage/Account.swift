import Foundation

/// A Microsoft account known to the launcher. Its tokens live in the Keychain under
/// `keychainService`, written only by its account service.
public struct Account: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The gamertag once the account has signed in, shown by the launcher and appended to the
    /// game's window title. Empty until then.
    public var label: String
    public let keychainService: String
    /// Being added: its service may hold a device or a user for it, which the launcher removes if
    /// the sign-in does not finish. It is neither shown nor played.
    public var isPending = false
    /// The account must sign in before it plays: its service found no signed-in user, or
    /// Microsoft refused the user's sign-in.
    public var needsSignIn = false
    /// The build of the account service that last read the account's Keychain item, by its code
    /// directory hash; nil before one has.
    public var lastServiceCDHash: Data?

    public init(label: String) {
        id = UUID()
        self.label = label
        keychainService = "dev.macrock.account.\(id.uuidString.lowercased())"
    }

    /// An account whose credentials already exist under another Keychain service, such as the
    /// engine's development namespace.
    public init(label: String, adopting keychainService: String) {
        id = UUID()
        self.label = label
        self.keychainService = keychainService
    }
}

extension Account {
    /// Libraries written by earlier launchers lack the fields added since.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        keychainService = try container.decode(String.self, forKey: .keychainService)
        isPending = try container.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
        needsSignIn = try container.decodeIfPresent(Bool.self, forKey: .needsSignIn) ?? false
        lastServiceCDHash = try container.decodeIfPresent(Data.self, forKey: .lastServiceCDHash)
    }

    /// Whether macOS will ask for the user's password before this build of the service reads the
    /// account's Keychain item. Without a Team ID the item trusts builds by code directory hash:
    /// the one that last wrote it, and those the user always allowed. Before any service has read
    /// the item, no prompt is expected.
    public func keychainAsks(for cdhash: Data) -> Bool {
        lastServiceCDHash.map { $0 != cdhash } ?? false
    }

    /// How long the account's service may take to be ready: the user may have a Keychain prompt
    /// to answer first.
    func serviceReadinessTimeout(for cdhash: Data) -> Duration {
        keychainAsks(for: cdhash) ? .seconds(300) : .seconds(60)
    }
}
