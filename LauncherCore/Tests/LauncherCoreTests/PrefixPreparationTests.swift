import Foundation
import Testing

@testable import LauncherCore

struct PrefixPreparationTests {
    let temporary: TemporaryDirectory
    let runtime: FakeRuntime
    let setup: PrefixSetup
    let game: GameFolder
    let prefix: WinePrefix
    let host = HostEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/")

    init() throws {
        temporary = try TemporaryDirectory()
        runtime = try FakeRuntime(
            in: temporary.url,
            behaviours: ["wine wineboot": #"mkdir -p "$WINEPREFIX/drive_c/windows/system32""#])
        let files = runtime.url.appending(path: "share/prefix")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: files.appending(path: "xgameruntime.dll"))
        try Data("Windows Registry Editor Version 5.00".utf8).write(
            to: files.appending(path: "sdk.reg"))
        let setupFile = temporary.url.appending(path: "setup.json")
        try Data(
            """
            {"schema": 1, "revision": 1, "dll_overrides": "mscoree,mshtml=", "game_drive": "g:",
             "steps": [
               {"id": "xgameruntime", "copy": "share/prefix/xgameruntime.dll",
                "to": "drive_c/windows/system32/xgameruntime.dll"},
               {"id": "winappsdk-1.8", "reg": "share/prefix/sdk.reg"}]}
            """.utf8
        ).write(to: setupFile)
        setup = try PrefixSetup(contentsOf: setupFile)
        game = try GameFolder(url: makeGameFolder(in: temporary.url))
        prefix = WinePrefix(
            url: temporary.url.appending(path: "prefixes/a"), serverDirectories: temporary.url)
    }

    func prepare(engine: String = "0.1.0-593587", retinaMode: Bool = false) async throws {
        try await prefix.prepare(
            setup: setup, engine: engine, game: game, retinaMode: retinaMode,
            tool: WineTool(runtime: runtime.url, host: host), output: .nullDevice)
    }

    func clearCalls() throws {
        try FileManager.default.removeItemIfPresent(at: runtime.calls)
    }

    @Test func createsANewPrefixWithMsyncOnlyForWineboot() async throws {
        try await prepare()

        let regFile =
            "Z:"
            + runtime.url.appending(path: "share/prefix/sdk.reg").path
            .replacing("/", with: #"\"#)
        #expect(
            try runtime.recorded == [
                "wine wineboot -u | WINEMSYNC=1 WINEDLLOVERRIDES=mscoree,mshtml=",
                "wineserver -w | WINEMSYNC=unset WINEDLLOVERRIDES=unset",
                #"wine reg add HKCU\Software\Wine\WineDbg /v ShowCrashDialog /t REG_DWORD /d 0 /f | WINEMSYNC=unset WINEDLLOVERRIDES=mscoree,mshtml="#,
                "wineserver -w | WINEMSYNC=unset WINEDLLOVERRIDES=unset",
                "wine reg import \(regFile) | WINEMSYNC=unset WINEDLLOVERRIDES=mscoree,mshtml=",
                "wineserver -w | WINEMSYNC=unset WINEDLLOVERRIDES=unset",
            ])
        let dll = prefix.url.appending(path: "drive_c/windows/system32/xgameruntime.dll")
        #expect(try Data(contentsOf: dll) == Data("dll".utf8))
    }

    @Test func doesNothingTheSecondTime() async throws {
        try await prepare()
        try clearCalls()

        try await prepare()

        #expect(try runtime.recorded.isEmpty)
    }

    @Test func importsAChangedRegistryFileAgain() async throws {
        try await prepare()
        try clearCalls()
        try Data("changed".utf8).write(to: runtime.url.appending(path: "share/prefix/sdk.reg"))

        try await prepare()

        #expect(
            try runtime.recorded.map { $0.prefix(15) } == ["wine reg import", "wineserver -w |"])
    }

    @Test func copiesADeletedFileAgain() async throws {
        try await prepare()
        try clearCalls()
        let dll = prefix.url.appending(path: "drive_c/windows/system32/xgameruntime.dll")
        try FileManager.default.removeItem(at: dll)

        try await prepare()

        #expect(FileManager.default.fileExists(atPath: dll.path))
        #expect(try runtime.recorded.isEmpty)
    }

    @Test func updatesThePrefixForAnotherEngine() async throws {
        try await prepare()
        try clearCalls()

        try await prepare(engine: "0.2.0-abcdef")

        #expect(
            try runtime.recorded.map { $0.prefix(16) } == ["wine wineboot -u", "wineserver -w | "])
    }

    @Test func setsRetinaModeOnlyWhenItChanges() async throws {
        try await prepare(retinaMode: true)
        #expect(
            try Array(runtime.recorded.suffix(2)) == [
                #"wine reg add HKCU\Software\Wine\Mac Driver /v RetinaMode /t REG_SZ /d y /f | WINEMSYNC=unset WINEDLLOVERRIDES=mscoree,mshtml="#,
                "wineserver -w | WINEMSYNC=unset WINEDLLOVERRIDES=unset",
            ])
        try clearCalls()

        try await prepare(retinaMode: true)
        #expect(try runtime.recorded.isEmpty)

        try await prepare(retinaMode: false)
        #expect(
            try runtime.recorded == [
                #"wine reg add HKCU\Software\Wine\Mac Driver /v RetinaMode /t REG_SZ /d n /f | WINEMSYNC=unset WINEDLLOVERRIDES=mscoree,mshtml="#,
                "wineserver -w | WINEMSYNC=unset WINEDLLOVERRIDES=unset",
            ])
    }

    @Test func recreatesAPrefixLeftHalfCreated() async throws {
        try FileManager.default.createDirectory(at: prefix.url, withIntermediateDirectories: true)
        try Data(#"{"stage": "creating", "engine": "0.1.0-593587", "gameInput": false}"#.utf8)
            .write(to: prefix.url.appending(path: ".macrock-launcher.json"))
        let leftover = prefix.url.appending(path: "leftover")
        try Data().write(to: leftover)

        try await prepare()

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(try runtime.recorded.first?.hasPrefix("wine wineboot -u") == true)
    }

    @Test func mapsTheGameDriveAndRemovesItsDeviceLink() async throws {
        try await prepare()
        let devices = prefix.url.appending(path: "dosdevices")
        try FileManager.default.removeItem(at: devices.appending(path: "g:"))
        try FileManager.default.createSymbolicLink(
            atPath: devices.appending(path: "g:").path, withDestinationPath: "/Volumes/Other")
        try FileManager.default.createSymbolicLink(
            atPath: devices.appending(path: "g::").path, withDestinationPath: "/dev/rdisk9")
        try FileManager.default.createSymbolicLink(
            atPath: devices.appending(path: "d:").path, withDestinationPath: "/Volumes/Disk")

        try await prepare()

        let manager = FileManager.default
        #expect(
            try manager.destinationOfSymbolicLink(atPath: devices.appending(path: "g:").path)
                == game.url.path)
        #expect(
            try manager.destinationOfSymbolicLink(atPath: devices.appending(path: "c:").path)
                == "../drive_c")
        #expect(
            try manager.destinationOfSymbolicLink(atPath: devices.appending(path: "z:").path) == "/"
        )
        #expect(
            try manager.destinationOfSymbolicLink(atPath: devices.appending(path: "d:").path)
                == "/Volumes/Disk")
        #expect(
            (try? manager.destinationOfSymbolicLink(atPath: devices.appending(path: "g::").path))
                == nil)
    }

    @Test func keepsTheStepsDoneBeforeAFailure() async throws {
        let failing = try FakeRuntime(
            in: temporary.url, behaviours: ["wine reg": #"if [ "$2" = import ]; then exit 1; fi"#])
        try FileManager.default.moveItem(
            at: runtime.url.appending(path: "share"), to: failing.url.appending(path: "share"))

        await #expect(throws: WineError.self) {
            try await prefix.prepare(
                setup: setup, engine: "0.1.0-593587", game: game, retinaMode: false,
                tool: WineTool(runtime: failing.url, host: host), output: .nullDevice)
        }

        let state = try JSONSerialization.jsonObject(
            with: Data(contentsOf: prefix.url.appending(path: ".macrock-engine.json")))
        let steps = (state as? [String: Any])?["steps"] as? [String: String]
        #expect(steps?.keys.sorted() == ["xgameruntime"])
    }

    @Test func writesTheEngineStateInTheEngineFormat() async throws {
        try await prepare()

        let state = try JSONSerialization.jsonObject(
            with: Data(contentsOf: prefix.url.appending(path: ".macrock-engine.json")))
        let object = try #require(state as? [String: Any])
        #expect(object["revision"] as? Int == 1)
        let steps = try #require(object["steps"] as? [String: String])
        #expect(steps.keys.sorted() == ["winappsdk-1.8", "xgameruntime"])
        #expect(steps["xgameruntime"]?.count == 64)
    }
}
