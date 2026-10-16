import Foundation

/// What one session runs, every part of it checked.
public struct SessionPlan: Sendable {
    /// Eight hexadecimal digits that name the session's socket, run record and folder.
    let id: String
    let account: Account
    let engine: EngineRuntime
    let d3dmetal: D3DMetalPayload
    let game: GameFolder
    let service: ServiceSetup
    let settings: Profile.Settings
    /// Whether the account's worlds, packs and settings are backed up before the game starts,
    /// as when it is an earlier version kept at an update.
    let backsUpGameData: Bool
    let opensEditor: Bool

    var directory: DataDirectory { service.directory }

    var host: HostEnvironment { service.host }
}

extension SessionPlan {
    /// Checks the components the session will run, off the cooperative pool since this reads
    /// every file of the engine: the installed engine in `engine` against its index and the
    /// service in the app, D3DMetal's signature and its version against the engine's
    /// requirement, the game's files.
    public init(
        account: Account, engine: URL, d3dmetal: URL, game: URL, service: ServiceSetup,
        settings: Profile.Settings, backingUpGameData: Bool, openingEditor: Bool
    ) async throws {
        let (runtime, d3dmetal, folder) = try await runOnDedicatedThread {
            (
                try EngineRuntime(installedIn: engine), try D3DMetalPayload(lib: d3dmetal),
                try GameFolder(url: game)
            )
        }
        try runtime.index.checkCompatibility(serviceProtocol: service.pin.serviceProtocol)
        try runtime.index.requires.checkD3DMetal(version: d3dmetal.version)
        self.init(
            id: String(format: "%08x", UInt32.random(in: .min ... .max)), account: account,
            engine: runtime, d3dmetal: d3dmetal, game: folder, service: service,
            settings: settings, backsUpGameData: backingUpGameData, opensEditor: openingEditor)
    }
}
