import Foundation

public struct ServiceSetup: Sendable {
    let executable: URL
    let pin: ServicePin
    let directory: DataDirectory
    let host: HostEnvironment

    public init(executable: URL, pin: ServicePin, directory: DataDirectory, host: HostEnvironment) {
        self.executable = executable
        self.pin = pin
        self.directory = directory
        self.host = host
    }
}

extension Account {
    /// Signs the account in and returns its gamertag. `show` presents a sign-in page and returns
    /// what it posted; Microsoft may ask for a second page.
    ///
    /// The service stores the sign-in as soon as Microsoft issues it, so the caller must still
    /// sign out a new account that fails or is cancelled after that.
    public func signIn(
        with setup: ServiceSetup, show: (SignInPage) async throws -> ServerData
    ) async throws -> String {
        try await withService(setup, for: "sign-in") { channel in
            var page = SignInPage()
            while true {
                let serverData = try await show(page)
                switch try await channel.signIn(serverData, inlineAuth: page.isInlineAuth) {
                case .signedIn: return try await channel.gamertag()
                case .inlineAuth(let url): page = SignInPage(inlineAuth: url)
                }
            }
        }
    }

    /// Signs the account and its device out, which removes its Keychain item, then deletes its
    /// prefix after backing up the game's data to `backups/<account>/<time>-removed/`. Microsoft
    /// keeps the device registered.
    /// - Returns: the backup, if the prefix held game data.
    public func remove(with setup: ServiceSetup) async throws -> URL? {
        let directory = setup.directory
        let prefix = WinePrefix(url: directory.prefix(for: id))
        return try await withService(setup, for: "remove") { channel in
            if let server = prefix.runningServer() { throw SessionError.prefixInUse(server) }
            try await channel.signOut(device: true)
            let backup = directory.removalBackup(of: id)
            let kept = try prefix.delete(keepingGameDataIn: backup, user: setup.host.user)
            try FileManager.default.removeItem(at: directory.prefixLock(for: id))
            return kept ? backup : nil
        }
    }

    var serviceName: String {
        String(id.uuidString.lowercased().prefix(8))
    }

    /// Runs `body` with a service started for this account alone, holding the account's lock so
    /// that no session runs and no other service writes its Keychain item.
    func withService<Value>(
        _ setup: ServiceSetup, for purpose: String,
        _ body: (LauncherChannel) async throws -> Value
    ) async throws -> Value {
        try await withLock(in: setup.directory) {
            let logs = setup.directory.accountLogs
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let stamp = PastSession.stampFormatter.string(from: .now)
            let log = try RedactedLog(
                file: logs.appending(path: "\(stamp)-\(serviceName)-\(purpose).log"))
            return try await withService(setup, named: serviceName, log: log) {
                try await body($0.channel)
            }
        }
    }

    /// Starts the account's service on the socket `name`, runs `body` with it and stops it,
    /// however `body` ends. The caller holds the account's lock; `log` is closed once the service
    /// has stopped.
    func withService<Value>(
        _ setup: ServiceSetup, named name: String, log: RedactedLog,
        _ body: (XodusService) async throws -> Value
    ) async throws -> Value {
        let service: XodusService
        do {
            service = try await XodusService.start(
                executable: setup.executable, pinnedCDHash: setup.pin.cdhash,
                keychainService: keychainService,
                socketPath: setup.directory.socketPath(named: name), host: setup.host, log: log,
                readinessTimeout: serviceReadinessTimeout(for: setup.pin.cdhash))
        } catch {
            try? await log.close()
            throw error
        }

        let result: Result<Value, any Error>
        do {
            result = .success(try await body(service))
        } catch {
            result = .failure(error)
        }
        await service.stop()
        try await log.close()
        return try result.get()
    }
}
