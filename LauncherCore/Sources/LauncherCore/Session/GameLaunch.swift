import Foundation

/// The D3DMetal backend the game renders with.
public enum MetalBackend: String, Codable, Sendable, CaseIterable {
    case metal4
    case metal3
}

/// How the game starts: the program, its argument and working directory, and its exact
/// environment, the one the engine's `tests/game/run.sh` composes.
public struct GameLaunch: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let currentDirectory: URL
    public let environment: [String: String]

    /// - Parameters:
    ///   - activation: the URI Windows would activate the game with, passed as its argument,
    ///     such as Minecraft Editor's.
    ///   - settings: the profile's; Retina mode is not in the environment but in the prefix,
    ///     which `WinePrefix.prepare` sets.
    ///   - titleSuffix: appended to the game's window title, to tell sessions apart.
    ///   - fpsLog: a file that receives one line of frame times per second.
    public init(
        wine: URL, setup: PrefixSetup, prefix: WinePrefix, d3dmetal: D3DMetalPayload,
        game: GameFolder, activation: String?, socketPath: String, settings: Profile.Settings,
        titleSuffix: String, fpsLog: URL?, host: HostEnvironment
    ) {
        let overrides =
            setup.dllOverrides + ";"
            + D3DMetalPayload.libraries.joined(separator: ",") + "=b;nvapi64="
        var environment = prefix.environment(
            host: host, msync: settings.usesMsync, dllOverrides: overrides)
        environment["WINEDLLPATH_PREPEND"] = d3dmetal.lib.appending(path: "wine").path
        environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = d3dmetal.libd3dshared.path
        environment["CX_ACTIVE_GRAPHICS_BACKEND"] = "d3dmetal"
        environment["D3DM_SUPPORT_DXR"] = "0"
        environment["D3DM_MTL4"] = settings.backend == .metal4 ? "1" : "0"
        environment["ROSETTA_ADVERTISE_AVX"] = "1"
        environment["XODUS_SOCKET"] = socketPath
        environment["XGAMERUNTIME_LOG_LEVEL"] = "fixme"
        environment["MACROCK_WINDOW_TITLE_SUFFIX"] = titleSuffix
        environment["MACROCK_FPS_LOG"] = fpsLog?.path
        if settings.showsMetalHUD {
            environment["MTL_HUD_ENABLED"] = "1"
        }
        executable = wine
        arguments =
            [setup.gameDrive.uppercased() + #"\"# + GameFolder.executable]
            + [activation].compactMap(\.self)
        currentDirectory = game.url
        self.environment = environment
    }
}
