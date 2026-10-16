import Foundation
import Testing

@testable import LauncherCore

struct LibraryTests {
    let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory()
    }

    func install(_ product: GameProduct) throws -> Installation {
        let store = InstallationStore(
            in: DataDirectory(root: temporary.url, sockets: .temporaryDirectory))
        return try store.adopt(
            try makeGameFolder(in: store.staging(for: product)), of: product, consented: .now)
    }

    @Test func readsBackWhatItWrote() throws {
        var library = Library()
        library.accounts = [
            Account(label: "Main"), Account(label: "Dev", adopting: "macrock-engine dev"),
        ]
        library.accounts[0].needsSignIn = true
        library.noteKeychainAccess(of: library.accounts[0].id, by: Data(repeating: 7, count: 20))
        library.addPendingAccount(Account(label: ""))
        library.selectedAccount = library.accounts[1].id
        library.graphics = URL(
            filePath: "/Users/test/Library/Application Support/macrock/graphics/lib")
        library.setInstallation(UUID(), of: library.profiles[0].id)
        var settings = Profile.Settings()
        settings.backend = .metal3
        settings.usesRetinaMode = true
        library.setSettings(settings, of: library.profiles[1].id)
        library.setName("Preview on Metal 3", of: library.profiles[1].id)
        library.selectedProfile = library.profiles[1].id
        library.packageConsent = Date(timeIntervalSince1970: 1_791_000_000)
        library.toldAboutSignInPrompt = true
        library.useEngine("0.1.0-59358740b31f")
        library.useEngine("0.1.1-1ecbab43d666")
        library.setupCompleted = Date(timeIntervalSince1970: 1_791_560_000)
        let file = temporary.url.appending(path: "library.json")

        try library.write(to: file)

        #expect(try Library(contentsOf: file) == library)
    }

    @Test func aMissingFileIsAnEmptyLibrary() throws {
        let library = try Library(contentsOf: temporary.url.appending(path: "library.json"))
        #expect(library.accounts.isEmpty)
        #expect(library.engine == nil)
        #expect(library.setupCompleted == nil)
        #expect(library.profiles.map(\.product) == [.release, .preview])
    }

    @Test func refusesAnotherVersion() throws {
        let file = temporary.url.appending(path: "library.json")
        try Data(#"{"version": 2, "accounts": []}"#.utf8).write(to: file)

        #expect(throws: LibraryError.unsupportedVersion(2)) {
            try Library(contentsOf: file)
        }
    }

    @Test func readsALibraryWrittenBeforeEnginesWereInstalled() throws {
        let file = temporary.url.appending(path: "library.json")
        try Data(
            #"{"version": 1, "accounts": [], "backend": "metal4", "toldAboutSignInPrompt": true}"#
                .utf8
        ).write(to: file)
        let library = try Library(contentsOf: file)
        #expect(library.engine == nil)
        #expect(library.engines.isEmpty)
        #expect(library.setupCompleted == nil)
    }

    @Test func givesALibraryWrittenBeforeProfilesTheLatestOfEachProduct() throws {
        let file = temporary.url.appending(path: "library.json")
        try Data(
            #"{"version": 1, "accounts": [], "backend": "metal3", "game": "file:///Games/Minecraft"}"#
                .utf8
        ).write(to: file)

        let library = try Library(contentsOf: file)

        #expect(library.profiles.map(\.product) == [.release, .preview])
        #expect(
            library.profiles.allSatisfy {
                $0.installation == nil && $0.settings == Profile.Settings()
            })
        #expect(library.selectedProfile == library.profiles.first?.id)
    }

    @Test func givesSettingsAnEarlierLauncherDidNotWriteTheirDefaults() throws {
        let file = temporary.url.appending(path: "library.json")
        let profile = UUID()
        try Data(
            #"""
            {"version": 1, "accounts": [], "profiles": [{"id": "\#(profile)", "product": "release",
            "kind": "latest", "settings": {"backend": "metal3"}}]}
            """#.utf8
        ).write(to: file)

        let library = try Library(contentsOf: file)

        var expected = Profile.Settings()
        expected.backend = .metal3
        #expect(library.profiles.map(\.settings) == [expected])
    }

    @Test func findsProfilesAndAccountsByID() {
        var library = Library()
        library.accounts = [Account(label: "Main"), Account(label: "Second")]
        library.duplicate(library.profiles[1].id, named: "Preview copy")

        #expect(library.account(library.accounts[1].id) == library.accounts[1])
        #expect(library.account(UUID()) == nil)
        #expect(library.profile(library.profiles[2].id) == library.profiles[2])
        #expect(library.profile(UUID()) == nil)
        #expect(library.latestProfile(of: .preview) == library.profiles[1])
    }

    @Test func keepsACopyOfAProfilesInstallationAsAProfileOfItsOwn() {
        var library = Library()
        let latest = library.profiles[0]
        let installation = UUID()
        library.setInstallation(installation, of: latest.id)
        var settings = Profile.Settings()
        settings.backend = .metal3
        settings.showsMetalHUD = true
        library.setSettings(settings, of: latest.id)

        library.keepCopy(of: latest.id)

        let copy = library.profiles[1]
        #expect(copy.kind == .kept)
        #expect(copy.product == .release)
        #expect(copy.installation == installation)
        #expect(copy.settings == settings)
        #expect(library.profiles.map(\.kind) == [.latest, .kept, .latest])
    }

    @Test func duplicatesAProfileAfterItWithItsInstallationAndSettings() throws {
        var library = Library()
        let latest = library.profiles[0]
        let installation = UUID()
        library.setInstallation(installation, of: latest.id)
        var settings = Profile.Settings()
        settings.backend = .metal3
        library.setSettings(settings, of: latest.id)

        let duplicated = library.duplicate(latest.id, named: "Latest Release copy")
        let id = try #require(duplicated)

        let copy = library.profiles[1]
        #expect(copy.id == id)
        #expect(copy.id != latest.id)
        #expect(copy.name == "Latest Release copy")
        #expect(copy.kind == .latest)
        #expect(copy.product == .release)
        #expect(copy.installation == installation)
        #expect(copy.settings == settings)
    }

    @Test func theProfilesThatFollowAProductsLatestVersionPlayTheSameInstallation() throws {
        var library = Library()
        let latest = library.profiles[0]
        let kept = UUID()
        library.setInstallation(kept, of: latest.id)
        library.keepCopy(of: latest.id)
        let duplicated = library.duplicate(latest.id, named: "Metal 3")
        let copy = try #require(duplicated)
        let update = UUID()

        library.setInstallation(update, of: copy)

        #expect(library.profiles.map(\.installation) == [update, update, kept, nil])
    }

    @Test func removesEveryProfileButTheLastThatFollowsItsProductsLatestVersion() throws {
        var library = Library()
        let latest = library.profiles[0]
        let preview = library.profiles[1]
        library.setInstallation(UUID(), of: latest.id)
        library.keepCopy(of: latest.id)
        let kept = library.profiles[1]
        let duplicated = library.duplicate(latest.id, named: "Metal 3")
        let copy = try #require(duplicated)
        library.selectedProfile = latest.id

        library.removeProfile(latest.id)
        library.removeProfile(copy)
        library.removeProfile(kept.id)
        library.removeProfile(preview.id)

        #expect(library.profiles.map(\.id) == [copy, preview.id])
        #expect(library.selectedProfile == copy)
    }

    @Test func aKeptProfileGoesWithItsInstallation() throws {
        var library = Library()
        let latest = library.profiles[0]
        let old = try install(.release)
        let new = try install(.release)
        library.setInstallation(old.id, of: latest.id)
        library.keepCopy(of: latest.id)
        library.setInstallation(new.id, of: latest.id)

        library.reconcile(with: [new])

        #expect(library.profiles.map(\.kind) == [.latest, .latest])
        #expect(library.profiles[0].installation == new.id)
    }

    @Test func profilesWithoutTheirLatestInstallationTakeTheNewestNoOtherProfilePlays() throws {
        var library = Library()
        let latest = library.profiles[0]
        let kept = try install(.release)
        library.setInstallation(kept.id, of: latest.id)
        library.keepCopy(of: latest.id)
        library.duplicate(latest.id, named: "Metal 3")
        library.setInstallation(UUID(), of: latest.id)
        let finished = try install(.release)
        let preview = try install(.preview)

        library.reconcile(with: [preview, finished, kept])

        #expect(
            library.profiles.map(\.installation) == [finished.id, finished.id, kept.id, preview.id])
    }

    @Test func readsProfilesWrittenBeforeTheyCouldBeKept() throws {
        let file = temporary.url.appending(path: "library.json")
        try Data(
            #"{"version": 1, "profiles": [{"id": "1243593A-42A0-4D5A-A88E-1D33CAEDCEEE", "product": "release"}]}"#
                .utf8
        ).write(to: file)

        let profile = try #require(try Library(contentsOf: file).profiles.first)

        #expect(profile.kind == .latest)
        #expect(profile.name == nil)
        #expect(profile.settings == Profile.Settings())
        #expect(profile.installation == nil)
    }

    @Test func readsAccountsWrittenBeforeTheyCouldBePendingOrNeedToSignIn() throws {
        let file = temporary.url.appending(path: "library.json")
        try Data(
            #"""
            {"version": 1, "backend": "metal4", "toldAboutSignInPrompt": true,
            "accounts": [{"id": "96EDFA7E-FBA0-4FBC-B21C-AC7B7C51082D", "label": "Dev",
            "keychainService": "macrock-engine dev"}]}
            """#.utf8
        ).write(to: file)
        let account = try #require(try Library(contentsOf: file).accounts.first)
        #expect(account.label == "Dev")
        #expect(!account.isPending)
        #expect(!account.needsSignIn)
        #expect(account.lastServiceCDHash == nil)
    }

    @Test func aNewAccountIsPendingUntilItSignsInUnderItsGamertag() {
        var library = Library()
        let first = Account(label: "")
        let second = Account(label: "")
        library.addPendingAccount(first)
        library.addPendingAccount(second)
        #expect(library.accounts.allSatisfy { $0.isPending })
        #expect(library.selectedAccount == nil)

        library.markSignedIn(first.id, gamertag: "Steve")
        library.markSignedIn(second.id, gamertag: "Alex")

        #expect(library.accounts.map(\.label) == ["Steve", "Alex"])
        #expect(!library.accounts.contains { $0.isPending })
        #expect(library.selectedAccount == first.id)
    }

    @Test func signingInAgainLetsTheAccountPlay() {
        var library = Library()
        let account = Account(label: "Dev", adopting: "macrock-engine dev")
        library.accounts = [account]
        library.requireSignIn(of: account.id)
        #expect(library.accounts[0].needsSignIn)

        library.markSignedIn(account.id, gamertag: "Steve")

        #expect(library.accounts[0].label == "Steve")
        #expect(!library.accounts[0].needsSignIn)
    }

    @Test func macOSAsksBeforeAnotherBuildOfTheServiceReadsTheAccount() {
        var library = Library()
        let account = Account(label: "Steve")
        library.accounts = [account]
        let build = Data(repeating: 1, count: 20)
        let update = Data(repeating: 2, count: 20)
        #expect(!library.accounts[0].keychainAsks(for: build))

        library.noteKeychainAccess(of: account.id, by: build)

        #expect(!library.accounts[0].keychainAsks(for: build))
        #expect(library.accounts[0].keychainAsks(for: update))
    }

    @Test func removingTheSelectedAccountSelectsOneThatHasSignedIn() {
        var library = Library()
        let accounts = [Account(label: "Steve"), Account(label: ""), Account(label: "Alex")]
        library.accounts = [accounts[0]]
        library.addPendingAccount(accounts[1])
        library.accounts.append(accounts[2])
        library.selectedAccount = accounts[0].id

        library.removeAccount(accounts[0].id)
        #expect(library.accounts.map(\.id) == [accounts[1].id, accounts[2].id])
        #expect(library.selectedAccount == accounts[2].id)

        library.removeAccount(accounts[2].id)
        #expect(library.selectedAccount == nil)
    }

    @Test func usingAnEngineKeepsTheOneItReplaces() {
        var library = Library()
        library.useEngine("0.1.0-59358740b31f")
        library.useEngine("0.1.1-1ecbab43d666")
        library.useEngine("0.1.1-1ecbab43d666")
        #expect(library.engine == "0.1.1-1ecbab43d666")
        #expect(library.previousEngine == "0.1.0-59358740b31f")
        #expect(library.engines == ["0.1.0-59358740b31f", "0.1.1-1ecbab43d666"])
    }

    @Test func goingBackToThePreviousEngineSwapsThem() throws {
        var library = Library()
        library.useEngine("0.1.0-59358740b31f")
        library.useEngine("0.1.1-1ecbab43d666")
        library.useEngine(try #require(library.previousEngine))
        #expect(library.engine == "0.1.0-59358740b31f")
        #expect(library.previousEngine == "0.1.1-1ecbab43d666")
    }

    @Test func eachNewAccountGetsItsOwnKeychainService() {
        let main = Account(label: "Main")
        let second = Account(label: "Second")
        #expect(main.keychainService != second.keychainService)
        #expect(main.keychainService.hasPrefix("dev.macrock.account."))
        #expect(second.keychainService.hasPrefix("dev.macrock.account."))
    }
}
