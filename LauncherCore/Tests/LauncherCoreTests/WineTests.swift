import Foundation
import LauncherCore
import Testing

struct WinePrefixTests {
    let temporary: TemporaryDirectory
    let host = HostEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/")

    init() throws {
        temporary = try TemporaryDirectory()
    }

    @Test func hasNoServerWhenNothingHoldsItsLock() throws {
        let prefix = WinePrefix(url: temporary.url, serverDirectories: temporary.url)
        #expect(prefix.runningServer() == nil)
    }

    @Test func findsTheProcessHoldingItsServerLock() async throws {
        let url = temporary.url.appending(path: "prefix")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let holder = try await ServerLockHolder(prefix: url, serverDirectories: temporary.url)
        defer { holder.release() }

        let prefix = WinePrefix(url: url, serverDirectories: temporary.url)
        #expect(prefix.runningServer() == holder.process.processIdentifier)
    }

    @Test func toolEnvironmentMatchesTheEngineTests() {
        let prefix = WinePrefix(url: URL(filePath: "/prefixes/a"))
        #expect(
            prefix.environment(host: host, msync: false) == [
                "HOME": "/Users/test", "USER": "test", "TMPDIR": "/tmp/", "PATH": "/usr/bin:/bin",
                "LC_ALL": "en_US.UTF-8", "WINEPREFIX": "/prefixes/a", "WINEARCH": "win64",
                "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "mscoree,mshtml=",
            ])
        #expect(prefix.environment(host: host, msync: true)["WINEMSYNC"] == "1")
    }
}

struct WineToolTests {
    let temporary: TemporaryDirectory
    let host = HostEnvironment(home: "/Users/test", user: "test", temporaryDirectory: "/tmp/")

    init() throws {
        temporary = try TemporaryDirectory()
    }

    func environment() -> [String: String] {
        WinePrefix(url: temporary.url).environment(host: host, msync: true)
    }

    @Test func reportsAProgramThatFails() async throws {
        let runtime = try FakeRuntime(in: temporary.url, behaviours: ["wine reg": "exit 5"])
        await #expect(throws: WineError.failed("reg", .exited(5))) {
            try await WineTool(runtime: runtime.url, host: host).run(
                ["reg", "import", "Z:\\x.reg"], environment: environment(), output: .nullDevice,
                timeout: .seconds(5))
        }
    }

    @Test func killsAProgramThatTakesTooLong() async throws {
        let runtime = try FakeRuntime(
            in: temporary.url, behaviours: ["wine wineboot": "exec sleep 30"])
        await #expect(throws: WineError.timedOut("wineboot")) {
            try await WineTool(runtime: runtime.url, host: host).run(
                ["wineboot"], environment: environment(), output: .nullDevice,
                timeout: .milliseconds(300))
        }
    }

    @Test func waitsForTheServerAndKillsItWhenItDoesNotStop() async throws {
        let runtime = try FakeRuntime(
            in: temporary.url, behaviours: ["wineserver -w": "exec sleep 30"])
        let prefix = WinePrefix(url: temporary.url, serverDirectories: temporary.url)
        try await WineTool(runtime: runtime.url, host: host).waitForServer(
            of: prefix, output: .nullDevice, timeout: .milliseconds(300))
        #expect(
            try runtime.recorded.last == "wineserver -k | WINEMSYNC=unset WINEDLLOVERRIDES=unset")
    }
}
