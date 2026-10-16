import Foundation
import LauncherCore
import Observation
import os

@MainActor
@Observable
final class AppModel {
    private(set) var library = Library()
    /// Whether `start()` has read the library: until then the launcher can't tell whether this
    /// is the first run, and writes no library over the one on disk.
    private(set) var hasStarted = false
    private var startBegan = false
    /// Why `start()` couldn't read the library. The launcher then changes none of its files: the
    /// installations a library lists would look unused to it.
    private(set) var libraryFailure: (any Error)?
    private(set) var systemCheck: SystemCheck?
    private(set) var installingRosetta = false
    private(set) var readiness = Readiness(
        rosettaInstalled: SystemCheck.hasRosetta, engine: false, graphics: false, game: false,
        signedIn: nil)
    private(set) var sessions: [Account.ID: RunningSession] = [:]
    private(set) var notice: Notice?
    /// Prefixes whose Wine processes outlived a session the launcher did not end.
    private(set) var leftovers: [WinePrefix] = []
    private(set) var installedEngine: EngineIndex?
    /// The engine the current one replaced, kept to revert to.
    private(set) var previousEngine: EngineIndex?
    private(set) var engineUpdate: EngineUpdate?
    /// The update the player put off until the launcher starts again.
    private var postponedEngineUpdate: EngineUpdate?
    /// When the published engines were last read, or why they couldn't be.
    private(set) var lastEngineCheck: Result<Date, any Error>?
    private(set) var engineInstall: EngineInstall?
    private(set) var installations: [Installation] = []
    private(set) var gameInstall: GameInstall?
    private(set) var servedGames: [GameProduct: Result<GamePackage, ServiceFailure>] = [:]
    /// When the served games were last asked for, or why they couldn't be.
    private(set) var lastGameCheck: Result<Date, any Error>?
    /// Bumped by every change to worlds and packs, so that the views listing them reload.
    private(set) var contentChanges = 0
    private(set) var graphicsVersion: String?
    private(set) var graphicsImport: GraphicsImport?
    /// The page the account signing in is on; nil while its service signs in with what the last
    /// page posted.
    private(set) var signInPage: SignInPage?
    /// Worlds and packs opened without a game to put them in, until the player chooses one.
    private(set) var filesToPlace: [URL] = []

    let directory = DataDirectory.standard
    private var servicePin: ServicePin?
    private var pending: Task<Void, Never>?
    private var signingIn: Task<Void, Never>?
    private var checkingAccount: Task<Void, Never>?
    /// A check of the served game, which holds the selected account's lock while it runs.
    private var checkingGame: Task<Void, Never>?
    private var licenseDecision: CheckedContinuation<Bool, Never>?
    private var pagePosted: CheckedContinuation<ServerData, any Error>?
    private var filesBeforeStart: [URL] = []

    var selectedAccount: Account? {
        library.selectedAccount.flatMap(library.account)
    }

    var selectedSession: RunningSession? {
        selectedAccount.flatMap { sessions[$0.id] }
    }

    var playState: PlayState {
        var readiness = readiness
        readiness.anotherAccountPlaying = selectedSession == nil && !sessions.isEmpty
        readiness.installingEngine = engineInstall != nil
        readiness.installingGame = gameInstall != nil
        return PlayState(readiness: readiness, phase: selectedSession?.phase)
    }

    var isSigningIn: Bool { signingIn != nil }

    var canAddAccount: Bool { newAccount() != nil }

    /// Whether sessions may switch to another engine now: never while a Wine server could be
    /// running, since none may outlive a change of engine.
    var canChangeEngine: Bool {
        engineInstall == nil && !wineMayRun
    }

    /// Whether D3DMetal may be imported now: its files must not change under a running game.
    var canImportGraphics: Bool {
        graphicsImport == nil && !wineMayRun
    }

    var pendingToolkitLicense: ToolkitImage.License? {
        guard case .awaitingLicense(let license) = graphicsImport else { return nil }
        return license
    }

    /// The licenses and the sources notes of the engine sessions use.
    var engineDocumentation: URL? {
        library.engine.flatMap { store.documentation(of: $0) }
    }

    var graphicsLicense: URL? {
        library.graphics.flatMap { ToolkitImage.license(forImportAt: $0) }
    }

    /// The update to offer, unless the player put it off.
    var offeredEngineUpdate: EngineUpdate? {
        engineUpdate == postponedEngineUpdate ? nil : engineUpdate
    }

    var selectedProfile: Profile? {
        library.selectedProfile.flatMap(library.profile)
    }

    var installation: Installation? { selectedProfile.flatMap(installation(of:)) }

    func installation(of profile: Profile) -> Installation? {
        profile.installation.flatMap { id in installations.first { $0.id == id } }
    }

    /// A failed check fails every product.
    func served(_ product: GameProduct) -> Result<GamePackage, any Error>? {
        if case .failure(let error)? = lastGameCheck {
            return .failure(error)
        }
        return servedGames[product]?.mapError { $0 }
    }

    /// Kept copies never update.
    func update(for profile: Profile) -> GamePackage? {
        guard profile.kind == .latest, case .success(let served)? = served(profile.product),
            let installed = installation(of: profile), served.isNewer(than: installed.version)
        else { return nil }
        return served
    }

    var engineReleases: EngineReleases {
        #if DEBUG
            if let folder = UserDefaults.standard.url(forKey: Self.releasesFolderKey) {
                return EngineReleases(url: folder)
            }
        #endif
        return .github
    }

    var isInstallingGame: Bool { gameInstall != nil }

    var isCheckingGame: Bool { checkingGame != nil }

    /// Whether the selected account may install the game now: it installs with the account's
    /// service, which needs the account signed in and its lock free.
    var canInstallGame: Bool {
        !accountMayBeLocked && sessions.isEmpty && readiness.signedIn == true
            && selectedAccount.map(mayUse) == true && serviceSetup != nil
    }

    /// The installation whose files deleting the profile deletes: the one it plays, unless
    /// another profile plays it too.
    func installationDeleted(with profile: Profile) -> Installation? {
        guard let installation = installation(of: profile),
            !library.profiles.contains(where: {
                $0.id != profile.id && $0.installation == installation.id
            })
        else { return nil }
        return installation
    }

    /// Whether the profile, or the installation it plays, may be deleted now: no Wine process
    /// may be using its files.
    func canDelete(_ profile: Profile) -> Bool {
        (installation(of: profile) != nil || library.canRemoveProfile(profile.id))
            && gameInstall == nil && !wineMayRun
    }

    /// Whether work that may hold the selected account's lock runs: its session, the game's
    /// install, a sign-in, or other work the player started.
    private var accountMayBeLocked: Bool {
        selectedSession != nil || gameInstall != nil || signingIn != nil || pending != nil
    }

    /// Whether a Wine server may run: a session's, or one a session the launcher did not end left.
    private var wineMayRun: Bool { !sessions.isEmpty || !leftovers.isEmpty }

    private var store: EngineStore { EngineStore(in: directory) }

    private var installationStore: InstallationStore { InstallationStore(in: directory) }

    private var serviceSetup: ServiceSetup? {
        servicePin.map {
            ServiceSetup(
                executable: Self.embeddedService, pin: $0, directory: directory, host: .current)
        }
    }

    /// Reads what the launcher has and cleans up after installs and sessions a previous launch
    /// left unfinished. The main window calls it each time it opens; only the first call runs,
    /// since a later one would take this launch's sessions and installs for leftovers.
    func start() async {
        guard !startBegan else { return }
        startBegan = true
        do {
            try directory.create()
            library = try Library(contentsOf: directory.library)
        } catch {
            libraryFailure = error
            return
        }
        do {
            try await store.removeEngines(except: library.engines)
        } catch {
            notice = Notice(error: error)
        }
        hasStarted = true
        do {
            servicePin = try Self.embeddedServicePin()
        } catch {
            notice = Notice(
                kind: .problem, title: String(localized: "macrock is damaged"),
                message: String(
                    localized:
                        "The account service it was built with is missing. Install macrock again."))
        }
        leftovers = await directory.recoverSessions()
        await removePendingAccounts()
        await tidyInstallations()
        await refresh()
        open(filesBeforeStart)
        filesBeforeStart = []
    }

    /// In the Editor, the game opens Minecraft Editor's projects instead of its menus.
    func play(inEditor editor: Bool = false) {
        guard pending == nil, graphicsImport == nil, playState == .ready,
            let account = selectedAccount, mayUse(account),
            let engine = library.engine, let graphics = library.graphics,
            let profile = selectedProfile, let installation, let serviceSetup
        else { return }
        let settings = profile.settings
        notice = settings.backend == .metal4 ? .metal4AntiAliasing : nil
        announceKeychainPrompt(for: account)
        let engineFolder = store.folder(of: engine)
        let task = Task {
            await endGameCheck()
            var logs: URL?
            do {
                let plan = try await SessionPlan(
                    account: account, engine: engineFolder, d3dmetal: graphics,
                    game: installation.game, service: serviceSetup, settings: settings,
                    backingUpGameData: profile.kind == .kept, openingEditor: editor)
                guard sessions[account.id]?.stopRequested == false else {
                    throw CancellationError()
                }
                let session = GameSession(plan: plan)
                logs = session.logs
                let outcome = try await run(
                    session, of: account.id, playing: installation, on: engine)
                notice = Notice(outcome: outcome, logs: session.logs)
            } catch is CancellationError {
            } catch {
                if error as? SessionError == .signInAgain {
                    updateLibrary { $0.requireSignIn(of: account.id) }
                }
                notice = Notice(error: error, logs: logs)
            }
            sessions[account.id] = nil
            await refresh()
        }
        sessions[account.id] = RunningSession(profile: profile.id, editor: editor, task: task)
    }

    /// Runs the account's session to its end, noting what its phases tell.
    private func run(
        _ session: GameSession, of account: Account.ID, playing installation: Installation,
        on engine: String
    ) async throws -> SessionOutcome {
        sessions[account]?.game = session
        async let outcome = session.run()
        for await phase in session.phases {
            sessions[account]?.phase = phase
            switch phase {
            case .checkingLicense: noteKeychainAccess(of: account)
            case .running:
                tellAboutSignInPrompt()
                noteRun(of: installation, on: engine)
            default: break
            }
        }
        return try await outcome
    }

    func stop() {
        if let account = selectedAccount {
            stop(account.id)
        }
    }

    /// A session still checking what it will run ends before it starts anything.
    func stop(_ id: Account.ID) {
        guard let session = sessions[id], !session.stopRequested else { return }
        sessions[id]?.stopRequested = true
        if let game = session.game {
            sessions[id]?.stopping = Task { await game.requestStop() }
        }
    }

    func endSessions() async {
        for id in sessions.keys {
            stop(id)
        }
        for session in sessions.values {
            await session.task.value
        }
    }

    /// Records the account as pending, then signs it in on the pages `signInPage` holds.
    func addAccount() {
        guard signingIn == nil, let setup = serviceSetup, let account = newAccount() else {
            return
        }
        updateLibrary { $0.addPendingAccount(account) }
        signIn(account, with: setup)
    }

    func selectAccount(_ id: Account.ID?) {
        guard let id, id != library.selectedAccount else { return }
        updateLibrary { $0.selectedAccount = id }
        checkingAccount = Task { await refresh() }
    }

    func signInAgain(_ id: Account.ID) {
        guard signingIn == nil, gameInstall == nil, sessions[id] == nil,
            let setup = serviceSetup, let account = library.account(id), mayUse(account)
        else { return }
        announceKeychainPrompt(for: account)
        signIn(account, with: setup)
    }

    func signInPagePosted(_ serverData: ServerData) {
        guard let pagePosted else { return }
        signInPage = nil
        self.pagePosted = nil
        pagePosted.resume(returning: serverData)
    }

    /// A new account is removed; an existing one stays as it was.
    func cancelSignIn() {
        guard let pagePosted else { return }
        signInPage = nil
        self.pagePosted = nil
        pagePosted.resume(throwing: CancellationError())
    }

    func removeAccount(_ id: Account.ID) {
        guard gameInstall == nil, sessions[id] == nil, let setup = serviceSetup,
            let account = library.account(id), mayUse(account)
        else { return }
        announceKeychainPrompt(for: account)
        perform {
            await self.endGameCheck()
            let backup = try await account.remove(with: setup)
            self.updateLibrary { $0.removeAccount(id) }
            self.notice = backup.map { Notice(removed: account, backup: $0) }
        }
    }

    func endLeftovers() {
        guard let engine = library.engine, !leftovers.isEmpty else { return }
        perform { [store, leftovers] in
            let tool = WineTool(runtime: try await store.open(engine).runtime, host: .current)
            for prefix in leftovers {
                try await tool.killServer(of: prefix, output: .nullDevice)
            }
            self.leftovers = []
        }
    }

    /// Looks for a newer engine and a newer game now and once a day after, for as long as the
    /// calling task runs.
    func watchForUpdates() async {
        while !Task.isCancelled {
            await checkForEngineUpdate()
            await startGameCheck()?.value
            try? await Task.sleep(for: .seconds(24 * 60 * 60))
        }
    }

    func checkForEngineUpdateNow() {
        perform { await self.checkForEngineUpdate() }
    }

    func checkForGameUpdateNow() {
        guard let account = selectedAccount, startGameCheck(askedByPlayer: true) != nil else {
            return
        }
        announceKeychainPrompt(for: account)
    }

    func consentToPackages() {
        updateLibrary { $0.packageConsent = .now }
    }

    /// Installs what Microsoft serves now of the profile's product, with the selected account.
    /// The installation it replaces becomes a kept profile with `keepingCopy`, and is deleted
    /// otherwise.
    func installGame(_ id: Profile.ID, keepingCopy: Bool) {
        guard canInstallGame, let consented = library.packageConsent,
            let account = selectedAccount, let profile = library.profile(id),
            profile.kind == .latest, let setup = serviceSetup
        else { return }
        announceKeychainPrompt(for: account)
        let task = Task {
            await endGameCheck()
            let (updates, progress) = AsyncStream.makeStream(
                of: InstallProgress.self, bufferingPolicy: .bufferingNewest(1))
            async let extracted = account.install(
                profile.product, with: setup, progress: progress)
            for await update in updates {
                gameInstall?.progress = update
            }
            do {
                _ = try await extracted
                noteKeychainAccess(of: account.id)
                let installation = try await installationStore.addStagedGame(
                    of: profile.product, consented: consented)
                if keepingCopy {
                    updateLibrary { $0.keepCopy(of: profile.id) }
                }
                await use(installation, in: profile.id)
                notice = Notice(installed: installation)
            } catch is CancellationError {
            } catch {
                notice = Notice(error: error)
            }
            gameInstall = nil
            await refresh()
        }
        gameInstall = GameInstall(profile: profile.id, task: task)
    }

    /// The download stays for the next install.
    func cancelGameInstall() {
        gameInstall?.task.cancel()
    }

    /// Deletes the profile, or the installation it plays when it is the last that follows its
    /// product's latest version. The installation's files go once no profile plays them; worlds
    /// and settings stay in each account's prefix.
    func delete(_ id: Profile.ID) {
        guard let profile = library.profile(id), canDelete(profile) else { return }
        let installation = installation(of: profile)
        updateLibrary {
            if $0.canRemoveProfile(id) {
                $0.removeProfile(id)
            } else {
                $0.setInstallation(nil, of: id)
            }
        }
        checkGame()
        guard let installation,
            !library.profiles.contains(where: { $0.installation == installation.id })
        else { return }
        perform { try await self.installationStore.delete(installation) }
    }

    func installEngineUpdate() {
        guard case .available(let release) = engineUpdate else { return }
        install(release)
    }

    /// Installs the latest release again, whatever is installed, to repair an engine whose files
    /// changed.
    func reinstallEngine() {
        guard canChangeEngine, let servicePin else { return }
        perform {
            let release = try await self.engineReleases.latest()
            try release.index.checkCompatibility(serviceProtocol: servicePin.serviceProtocol)
            self.install(release)
        }
    }

    func revertEngine() {
        guard canChangeEngine, let previous = library.previousEngine else { return }
        updateLibrary { $0.useEngine(previous) }
        perform {
            await self.refresh()
            await self.checkForEngineUpdate()
        }
    }

    func postponeEngineUpdate() {
        postponedEngineUpdate = engineUpdate
    }

    func installRosetta() {
        guard !installingRosetta else { return }
        perform {
            self.installingRosetta = true
            defer { self.installingRosetta = false }
            try await SystemCheck.installRosetta()
        }
    }

    func importToolkit(from image: URL) {
        guard canImportGraphics else { return }
        perform { [directory] in
            self.graphicsImport = .importing
            defer { self.graphicsImport = nil }
            let payload = try await ToolkitImage(image).importD3DMetal(
                into: directory, requiring: self.installedEngine?.requires
            ) { license in
                await withCheckedContinuation { decision in
                    self.graphicsImport = .awaitingLicense(license)
                    self.licenseDecision = decision
                }
            }
            if let payload {
                self.updateLibrary { $0.graphics = payload.lib }
            }
        }
    }

    func decideToolkitLicense(accepted: Bool) {
        guard case .awaitingLicense = graphicsImport, let licenseDecision else { return }
        graphicsImport = .importing
        self.licenseDecision = nil
        licenseDecision.resume(returning: accepted)
    }

    func completeSetup() {
        updateLibrary { $0.setupCompleted = .now }
    }

    func selectProfile(_ id: Profile.ID) {
        guard id != library.selectedProfile, selectedSession == nil else { return }
        updateLibrary { $0.selectedProfile = id }
        checkGame()
    }

    func setBackend(_ backend: MetalBackend) {
        guard let profile = selectedProfile else { return }
        var settings = profile.settings
        settings.backend = backend
        setSettings(settings, of: profile.id)
    }

    func setSettings(_ settings: Profile.Settings, of profile: Profile.ID) {
        updateLibrary { $0.setSettings(settings, of: profile) }
    }

    /// An empty name gives the profile its default name back.
    func rename(_ profile: Profile.ID, to name: String) {
        updateLibrary { $0.setName(name.isEmpty ? nil : name, of: profile) }
    }

    func duplicate(_ id: Profile.ID) {
        guard let profile = library.profile(id) else { return }
        let copyName = String(localized: "\(name(of: profile)) copy")
        updateLibrary { $0.duplicate(id, named: copyName) }
    }

    func gameData(of product: GameProduct) -> GameData? {
        selectedAccount.map {
            GameData(
                of: product, account: $0.id, in: directory, user: HostEnvironment.current.user)
        }
    }

    /// One `.env` for every product the selected account has played; nil before any.
    func regolithEnvironment() -> String? {
        do {
            let lines = try GameProduct.allCases.compactMap(gameData(of:)).flatMap {
                try $0.regolithEnvironment()
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n") + "\n"
        } catch {
            notice = Notice(error: error)
            return nil
        }
    }

    func latestContentLog(of data: GameData) -> URL? {
        do {
            return try data.latestContentLog()
        } catch {
            notice = Notice(error: error)
            return nil
        }
    }

    /// Whether the selected account's worlds and packs may change now: nothing that holds the
    /// account's lock runs.
    var canChangeContent: Bool { !accountMayBeLocked }

    /// Worlds and packs opened from the Finder or dropped on the window go to the selected
    /// account, in `product`; without one they wait in `filesToPlace` for the player to choose
    /// among the games the account has played. Files opened before `start()` has read the library
    /// wait for it.
    func open(_ files: [URL], into product: GameProduct? = nil) {
        let files = files.filter { ContentFile($0) != nil }
        guard !files.isEmpty else { return }
        guard hasStarted else {
            filesBeforeStart += files
            return
        }
        guard selectedAccount != nil else {
            notice = .contentNeedsAccount
            return
        }
        if let product {
            add(files, to: product)
        } else if playedProducts.isEmpty {
            notice = Notice(error: ContentError.gameNotRunYet)
        } else {
            filesToPlace = files
        }
    }

    /// The player's choice for `filesToPlace`; nil leaves them out.
    func place(into product: GameProduct?) {
        let files = filesToPlace
        filesToPlace = []
        if let product {
            add(files, to: product)
        }
    }

    /// The games whose data the selected account has: those it has played.
    var playedProducts: [GameProduct] {
        GameProduct.allCases.filter { gameData(of: $0)?.exists == true }
    }

    private func add(_ files: [URL], to product: GameProduct) {
        guard let data = gameData(of: product) else { return }
        guard canChangeContent else {
            notice = selectedSession == nil ? .contentWhileBusy : .contentWhilePlaying
            return
        }
        importContent(from: files, into: data)
    }

    /// Adds worlds and packs one file after another; the notice tells about the last.
    func importContent(from files: [URL], into data: GameData) {
        changeContent {
            for file in files {
                if ContentFile(file) == .world {
                    let world = try await data.importWorld(from: file)
                    self.notice = Notice(added: world, to: data.product)
                } else {
                    self.notice = Notice(added: try await data.importPacks(from: file))
                }
            }
        }
    }

    func export(_ world: World, of data: GameData, to file: URL) {
        changeContent { try await data.export(world, to: file) }
    }

    func trash(_ world: World, of data: GameData) {
        changeContent { try data.trash(world) }
    }

    func trash(_ pack: Pack, of data: GameData) {
        changeContent { try data.trash(pack) }
    }

    /// Takes the notice away, unless another one has replaced it.
    func dismissNotice(_ id: Notice.ID) {
        if notice?.id == id {
            notice = nil
        }
    }

    func refresh() async {
        let prefix = selectedAccount.map { directory.prefix(for: $0.id).path }
        readiness.earlierSessionRunning = leftovers.contains { $0.url.path == prefix }
        let check = SystemCheck(dataDirectory: directory)
        systemCheck = check
        readiness.rosettaInstalled = check.rosettaInstalled
        readEngineAndGraphics()
        do {
            installations = try installationStore.installations()
        } catch {
            notice = Notice(error: error)
        }
        checkGame()
        await checkSignIn()
    }

    private func readEngineAndGraphics() {
        installedEngine = library.engine.flatMap { store.installedIndex(of: $0) }
        previousEngine = library.previousEngine.flatMap { store.installedIndex(of: $0) }
        readiness.engine = installedEngine != nil
        graphicsVersion = library.graphics.flatMap { D3DMetalPayload.statedVersion(at: $0) }
        readiness.graphics = library.graphics.map(D3DMetalPayload.isPresent(at:)) ?? false
    }

    private func checkSignIn() async {
        guard let account = selectedAccount else {
            readiness.signedIn = nil
            return
        }
        readiness.accountAllowed = mayUse(account)
        let signedIn: Bool
        do {
            signedIn = try await account.hasCredentials() && !account.needsSignIn
        } catch {
            signedIn = false
            notice = Notice(error: error)
        }
        // Another account may have been chosen meanwhile.
        if account.id == library.selectedAccount {
            readiness.signedIn = signedIn
        }
    }

    /// Debug builds can be injected into, so they only ever use the development namespace, even
    /// for an account a release build added.
    func mayUse(_ account: Account) -> Bool {
        #if DEBUG
            account.keychainService == Self.developmentNamespace
        #else
            true
        #endif
    }

    /// The account to add; in Debug builds, nil once an account uses the development namespace.
    private func newAccount() -> Account? {
        #if DEBUG
            let namespace = Self.developmentNamespace
            guard !library.accounts.contains(where: { $0.keychainService == namespace }) else {
                return nil
            }
            return Account(label: "", adopting: namespace)
        #else
            return Account(label: "")
        #endif
    }

    private func signIn(_ account: Account, with setup: ServiceSetup) {
        signingIn = Task {
            await endGameCheck()
            do {
                let gamertag = try await account.signIn(with: setup) { page in
                    try await withCheckedThrowingContinuation { pagePosted in
                        self.signInPage = page
                        self.pagePosted = pagePosted
                    }
                }
                updateLibrary { $0.markSignedIn(account.id, gamertag: gamertag) }
                noteKeychainAccess(of: account.id)
            } catch {
                if !(error is CancellationError) {
                    notice = Notice(error: error)
                }
            }
            await removePendingAccounts()
            signingIn = nil
            await refresh()
        }
    }

    /// Removes the accounts whose sign-in did not finish, now or before the launcher last quit.
    /// One that cannot be removed stays pending, to try again at the next start.
    private func removePendingAccounts() async {
        guard let setup = serviceSetup else { return }
        for account in library.accounts where account.isPending && mayUse(account) {
            do {
                _ = try await account.remove(with: setup)
                updateLibrary { $0.removeAccount(account.id) }
            } catch {
                Logger.accounts.error("A pending account was not removed: \(error)")
            }
        }
    }

    /// Call before the account's service starts.
    private func announceKeychainPrompt(for account: Account) {
        if let servicePin, account.keychainAsks(for: servicePin.cdhash) {
            notice = .keychainPrompt
        }
    }

    /// From now on macOS lets this build read the item without asking, unless the user allowed it
    /// only once.
    private func noteKeychainAccess(of id: Account.ID) {
        guard let servicePin else { return }
        updateLibrary { $0.noteKeychainAccess(of: id, by: servicePin.cdhash) }
    }

    /// The game asks a new profile to sign in, although the account service has already
    /// signed it in; "Maybe later" goes on signed in. Said once.
    private func tellAboutSignInPrompt() {
        guard !library.toldAboutSignInPrompt else { return }
        notice = Notice(
            kind: .information, title: String(localized: "If Minecraft asks you to sign in"),
            message: String(
                localized: "Choose “Maybe later”: macrock has already signed you in."))
        updateLibrary { $0.toldAboutSignInPrompt = true }
    }

    /// Reads the latest release, and installs it at once when no engine is: the launcher has
    /// nothing to play with until then.
    private func checkForEngineUpdate() async {
        guard let servicePin else { return }
        do {
            engineUpdate = try await engineReleases.latest().update(
                fromVersion: installedEngine?.version, serviceProtocol: servicePin.serviceProtocol)
            lastEngineCheck = .success(.now)
        } catch {
            Logger.engine.error("Checking for engine updates failed: \(error.localizedDescription)")
            lastEngineCheck = .failure(error)
        }
        if installedEngine == nil {
            installEngineUpdate()
        }
    }

    /// Asks Microsoft, through the selected account's service, which game it serves now. No
    /// check takes the account's lock from a session, a sign-in, a removal or an install; one
    /// the player didn't ask for waits for the next rather than have macOS ask for the user's
    /// password.
    @discardableResult
    private func startGameCheck(askedByPlayer: Bool = false) -> Task<Void, Never>? {
        guard checkingGame == nil, !accountMayBeLocked, sessions.isEmpty,
            readiness.signedIn == true, let account = selectedAccount,
            mayUse(account), let setup = serviceSetup, let servicePin,
            askedByPlayer || !account.keychainAsks(for: servicePin.cdhash)
        else { return nil }
        let check = Task {
            do {
                servedGames = try await account.servedPackages(
                    of: GameProduct.allCases, with: setup)
                lastGameCheck = .success(.now)
                noteKeychainAccess(of: account.id)
            } catch is CancellationError {
            } catch {
                Logger.game.error(
                    "Checking for game updates failed: \(error.localizedDescription)")
                lastGameCheck = .failure(error)
            }
            checkingGame = nil
        }
        checkingGame = check
        return check
    }

    /// Stops a check of the served game, and returns once its service has let go of the
    /// account's lock.
    private func endGameCheck() async {
        checkingGame?.cancel()
        await checkingGame?.value
    }

    /// Makes the profile play the installation, and deletes the one it played before unless a
    /// kept profile plays it. No session runs meanwhile: sessions and installs wait for each
    /// other.
    private func use(_ installation: Installation, in profile: Profile.ID) async {
        let replaced = library.profile(profile)?.installation
        updateLibrary { $0.setInstallation(installation.id, of: profile) }
        guard let replaced, !library.profiles.contains(where: { $0.installation == replaced }),
            let old = installations.first(where: { $0.id == replaced })
        else { return }
        do {
            try await installationStore.delete(old)
        } catch {
            Logger.game.error(
                "An earlier installation was not deleted: \(error.localizedDescription)")
        }
    }

    /// Deletes what interrupted installs and deletions left, brings the profiles in line with
    /// the installations left, and deletes those no profile plays.
    private func tidyInstallations() async {
        do {
            try await installationStore.removeUnfinished()
            let installed = try installationStore.installations()
            updateLibrary { $0.reconcile(with: installed) }
            let played = Set(library.profiles.compactMap(\.installation))
            for installation in installed where !played.contains(installation.id) {
                try await installationStore.delete(installation)
            }
        } catch {
            notice = Notice(error: error)
        }
    }

    private func checkGame() {
        readiness.game = installation?.hasGame ?? false
    }

    /// Records the engine the installation's game ran on, for when a later engine or game may
    /// not get along.
    private func noteRun(of installation: Installation, on engine: String) {
        do {
            _ = try installationStore.noteRun(of: installation, on: engine)
        } catch {
            Logger.game.error(
                "The engine the game ran on was not recorded: \(error.localizedDescription)")
        }
    }

    private func install(_ release: EngineRelease) {
        guard canChangeEngine else { return }
        let store = store
        notice = nil
        let task = Task {
            do {
                let (fractions, progress) = AsyncStream.makeStream(
                    of: Double.self, bufferingPolicy: .bufferingNewest(1))
                async let installed = store.install(release, progress: progress)
                for await fraction in fractions {
                    engineInstall?.downloaded = fraction
                }
                let identity = try await installed.identity
                updateLibrary { $0.useEngine(identity) }
                engineUpdate = nil
                try await store.removeEngines(except: library.engines)
            } catch {
                notice = Notice(error: error)
            }
            engineInstall = nil
            await refresh()
        }
        engineInstall = EngineInstall(version: release.index.version, task: task)
    }

    private func changeContent(_ change: @escaping @MainActor () async throws -> Void) {
        guard canChangeContent else { return }
        perform {
            defer { self.contentChanges += 1 }
            try await change()
        }
    }

    /// Runs one piece of menu work at a time, tells about the error it throws, then reads what
    /// the launcher has; the model owns it.
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard pending == nil else { return }
        pending = Task {
            do {
                try await work()
            } catch {
                notice = Notice(error: error)
            }
            await refresh()
            pending = nil
        }
    }

    /// Changes the library and writes it.
    private func updateLibrary(_ change: (inout Library) -> Void) {
        change(&library)
        guard hasStarted else { return }
        do {
            try library.write(to: directory.library)
        } catch {
            notice = Notice(error: error)
        }
    }

    private static var embeddedService: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/xodus-service")
    }

    /// What `scripts/vendor-engine.sh` wrote for the service the app carries.
    private static func embeddedServicePin() throws -> ServicePin {
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        return try ServicePin(contentsOf: resources.appending(path: "Engine/service-pin.json"))
    }
}

#if DEBUG
    extension AppModel {
        static let developmentNamespace = "macrock-engine dev"
        /// A folder of engine packages, such as the engine's `build.noindex/packages`, that
        /// stands in for GitHub.
        fileprivate static let releasesFolderKey = "EngineReleasesFolder"

        func showFirstRunAgain() {
            updateLibrary { $0.setupCompleted = nil }
        }

        /// Takes engine releases from `folder`, or from GitHub again when nil, and looks there.
        func useEngineReleases(from folder: URL?) {
            UserDefaults.standard.set(folder, forKey: Self.releasesFolderKey)
            perform {
                await self.checkForEngineUpdate()
                if case .failure(let error) = self.lastEngineCheck {
                    throw error
                }
            }
        }

        func adoptDevelopmentAccount() {
            perform {
                let account =
                    self.library.accounts.first { $0.keychainService == Self.developmentNamespace }
                    ?? Account(label: "Dev", adopting: Self.developmentNamespace)
                self.updateLibrary {
                    if !$0.accounts.contains(account) {
                        $0.accounts.append(account)
                    }
                    $0.selectedAccount = account.id
                }
            }
        }
    }
#endif

extension Logger {
    fileprivate static let engine = Logger(subsystem: "dev.macrock", category: "engine")
    fileprivate static let accounts = Logger(subsystem: "dev.macrock", category: "accounts")
    fileprivate static let game = Logger(subsystem: "dev.macrock", category: "game")
}

struct GameInstall {
    let profile: Profile.ID
    /// Nil until the service reports any progress.
    fileprivate(set) var progress: InstallProgress?
    fileprivate let task: Task<Void, Never>
}

struct EngineInstall {
    let version: String
    /// The fraction downloaded.
    fileprivate(set) var downloaded = 0.0
    fileprivate let task: Task<Void, Never>
}

/// One account's session, from Play until nothing of it is left running.
struct RunningSession {
    let profile: Profile.ID
    let editor: Bool
    fileprivate(set) var phase = SessionPhase.startingService
    fileprivate let task: Task<Void, Never>
    /// Nil while the session checks what it will run.
    fileprivate var game: GameSession?
    fileprivate var stopRequested = false
    fileprivate var stopping: Task<Void, Never>?
}

enum GraphicsImport {
    case importing
    case awaitingLicense(ToolkitImage.License)
}
