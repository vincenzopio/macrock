import Foundation
import Testing

@testable import LauncherCore

struct GameLaunchTests {
    let temporary: TemporaryDirectory
    let game: GameFolder
    let setup: PrefixSetup

    init() throws {
        temporary = try TemporaryDirectory()
        game = try GameFolder(url: makeGameFolder(in: temporary.url))
        let file = temporary.url.appending(path: "setup.json")
        try Data(
            #"{"schema": 1, "revision": 1, "dll_overrides": "mscoree,mshtml=;xgameruntime=n", "game_drive": "g:", "steps": []}"#
                .utf8
        ).write(to: file)
        setup = try PrefixSetup(contentsOf: file)
    }

    func launch(
        settings: Profile.Settings = Profile.Settings(),
        fpsLog: URL? = URL(filePath: "/sessions/s/fps.log"), activation: String? = nil
    ) -> GameLaunch {
        GameLaunch(
            wine: URL(filePath: "/engine/runtime/bin/wine"), setup: setup,
            prefix: WinePrefix(url: URL(filePath: "/prefixes/a")),
            d3dmetal: D3DMetalPayload(lib: URL(filePath: "/gptk/lib"), version: "4.0b2"),
            game: game, activation: activation, socketPath: "/tmp/macrock/5f1a0c3e.sock",
            settings: settings,
            titleSuffix: " (macrock-engine)", fpsLog: fpsLog,
            host: HostEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/"))
    }

    /// The environment `tests/game/run.sh` gives the game, captured from the engine's own
    /// shell functions with `env` in place of `wine`.
    @Test func matchesTheEngineGameEnvironment() {
        #expect(
            launch().environment == [
                "CX_ACTIVE_GRAPHICS_BACKEND": "d3dmetal",
                "CX_APPLEGPTK_LIBD3DSHARED_PATH": "/gptk/lib/external/libd3dshared.dylib",
                "D3DM_MTL4": "1",
                "D3DM_SUPPORT_DXR": "0",
                "HOME": "/Users/test",
                "LC_ALL": "en_US.UTF-8",
                "MACROCK_FPS_LOG": "/sessions/s/fps.log",
                "MACROCK_WINDOW_TITLE_SUFFIX": " (macrock-engine)",
                "PATH": "/usr/bin:/bin",
                "ROSETTA_ADVERTISE_AVX": "1",
                "TMPDIR": "/tmp/",
                "USER": "test",
                "WINEARCH": "win64",
                "WINEDEBUG": "-all",
                "WINEDLLOVERRIDES":
                    "mscoree,mshtml=;xgameruntime=n;d3d12,d3d11,d3d10,dxgi=b;nvapi64=",
                "WINEDLLPATH_PREPEND": "/gptk/lib/wine",
                "WINEMSYNC": "1",
                "WINEPREFIX": "/prefixes/a",
                "XGAMERUNTIME_LOG_LEVEL": "fixme",
                "XODUS_SOCKET": "/tmp/macrock/5f1a0c3e.sock",
            ])
    }

    @Test func metal3ChangesOnlyTheBackendSwitch() {
        var settings = Profile.Settings()
        settings.backend = .metal3
        var metal4 = launch().environment
        var metal3 = launch(settings: settings).environment
        #expect(metal4.removeValue(forKey: "D3DM_MTL4") == "1")
        #expect(metal3.removeValue(forKey: "D3DM_MTL4") == "0")
        #expect(metal3 == metal4)
    }

    @Test func withoutMsyncOnlyItsSwitchGoes() {
        var settings = Profile.Settings()
        settings.usesMsync = false
        var withMsync = launch().environment
        #expect(withMsync.removeValue(forKey: "WINEMSYNC") == "1")
        #expect(launch(settings: settings).environment == withMsync)
    }

    @Test func theMetalHUDAddsOnlyItsSwitch() {
        var settings = Profile.Settings()
        settings.showsMetalHUD = true
        var withHUD = launch(settings: settings).environment
        #expect(withHUD.removeValue(forKey: "MTL_HUD_ENABLED") == "1")
        #expect(withHUD == launch().environment)
    }

    @Test func leavesTheFrameLogOutWhenNotAsked() {
        #expect(launch(fpsLog: nil).environment["MACROCK_FPS_LOG"] == nil)
    }

    @Test func startsTheGameFromItsDrive() {
        let launch = launch()
        #expect(launch.executable.path == "/engine/runtime/bin/wine")
        #expect(launch.arguments == [#"G:\Minecraft.Windows.exe"#])
        #expect(launch.currentDirectory == game.url)
    }

    @Test func passesAnActivationAfterTheProgram() {
        #expect(
            launch(activation: "minecraft://creator/?Editor=true").arguments == [
                #"G:\Minecraft.Windows.exe"#, "minecraft://creator/?Editor=true",
            ])
    }
}
