import CryptoKit
import Foundation

extension WinePrefix {
    /// Makes the prefix ready for the game, doing only what is missing: creates it, updates it
    /// for a new engine, maps the drives, applies the engine's prefix setup and sets Wine's
    /// Retina mode.
    ///
    /// The prefix's wineserver must not be running: Wine's programs here run with and without
    /// msync, and each run ends with the server stopped.
    public func prepare(
        setup: PrefixSetup, engine: String, game: GameFolder, retinaMode: Bool, tool: WineTool,
        output: FileHandle
    ) async throws {
        var state = try LauncherState(prefix: url)
        if state?.stage == .creating {
            try FileManager.default.removeItem(at: url)
            state = nil
        }
        if state == nil {
            try await create(engine: engine, tool: tool, output: output)
        } else if var state, state.engine != engine {
            try await boot(tool: tool, output: output)
            state.engine = engine
            try state.write(prefix: url)
        }
        try mapDrives(gameDrive: setup.gameDrive, game: game.url)
        try await apply(setup, tool: tool, output: output)
        try await setRetinaMode(retinaMode, tool: tool, output: output)
    }

    private func create(engine: String, tool: WineTool, output: FileHandle) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try LauncherState(stage: .creating, engine: engine).write(prefix: url)
        try await boot(tool: tool, output: output)
        try await runToEnd(
            [
                "reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog", "/t",
                "REG_DWORD", "/d", "0", "/f",
            ], tool: tool, output: output)
        try LauncherState(stage: .ready, engine: engine).write(prefix: url)
    }

    /// Creates or updates the prefix with `wineboot -u` as the engine's tests do, with msync.
    private func boot(tool: WineTool, output: FileHandle) async throws {
        try await runToEnd(
            ["wineboot", "-u"], tool: tool, output: output, msync: true, timeout: .seconds(180))
    }

    /// Links `c:`, `z:` and the game drive. Wine also maps the volumes mounted when the prefix
    /// was created, which can take the game drive's letter: its device link (`g::`) goes.
    private func mapDrives(gameDrive: String, game: URL) throws {
        let devices = url.appending(path: "dosdevices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        for (drive, target) in [("c:", "../drive_c"), ("z:", "/"), (gameDrive, game.path)] {
            let link = devices.appending(path: drive)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target {
                continue
            }
            try FileManager.default.removeItemIfPresent(at: link)
            try FileManager.default.createSymbolicLink(
                atPath: link.path, withDestinationPath: target)
        }
        try FileManager.default.removeItemIfPresent(at: devices.appending(path: "\(gameDrive):"))
    }

    /// Applies the steps the prefix does not have yet, with the semantics of the engine's
    /// `tests/game/prefix-setup.py`: a step runs again when its file changes. A copied file that
    /// went missing or changed is copied again.
    private func apply(_ setup: PrefixSetup, tool: WineTool, output: FileHandle) async throws {
        var state = try EngineState(prefix: url) ?? EngineState(revision: setup.revision)
        for step in setup.steps {
            let source = tool.runtime.appending(path: step.action.source)
            let digest = try sha256(of: source)
            switch step.action {
            case .copy(_, let target):
                let destination = url.appending(path: target)
                guard state.steps[step.id] != digest || (try? sha256(of: destination)) != digest
                else { continue }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.removeItemIfPresent(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
            case .registry:
                guard state.steps[step.id] != digest else { continue }
                try await importRegistry(source, tool: tool, output: output)
            }
            state.revision = setup.revision
            state.steps[step.id] = digest
            try state.write(prefix: url)
        }
    }

    /// Wine's Mac driver reads Retina mode once for the whole prefix, from the registry. The
    /// prefix keeps the value set last, so that `reg` runs only when it changes.
    private func setRetinaMode(_ on: Bool, tool: WineTool, output: FileHandle) async throws {
        guard var state = try LauncherState(prefix: url) else { throw WinePrefixError.notCreated }
        guard (state.retinaMode ?? false) != on else { return }
        try await runToEnd(
            [
                "reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t",
                "REG_SZ", "/d", on ? "y" : "n", "/f",
            ], tool: tool, output: output)
        state.retinaMode = on
        try state.write(prefix: url)
    }
}

extension WinePrefix {
    /// Installs GameInput from the game's own redistributable, unless the prefix has it.
    public func installGameInput(from game: GameFolder, tool: WineTool, output: FileHandle)
        async throws
    {
        guard var state = try LauncherState(prefix: url) else { throw WinePrefixError.notCreated }
        if state.gameInput, GameInput.isInstalled(in: url) { return }
        let registry = url.appending(path: ".macrock-gameinput.reg")
        try GameInput(installer: game.gameInputInstaller).install(into: url, registry: registry)
        try await importRegistry(registry, tool: tool, output: output)
        try FileManager.default.removeItem(at: registry)
        state.gameInput = true
        try state.write(prefix: url)
    }

    /// Imports a registry file with the runtime's `reg.exe`, which sees the Mac's files on `z:`.
    private func importRegistry(_ file: URL, tool: WineTool, output: FileHandle) async throws {
        try await runToEnd(
            ["reg", "import", "Z:" + file.path.replacing("/", with: #"\"#)], tool: tool,
            output: output)
    }

    /// Runs one of Wine's programs on the prefix, then waits for the prefix's wineserver to stop,
    /// so that the next program may use msync or not.
    private func runToEnd(
        _ arguments: [String], tool: WineTool, output: FileHandle, msync: Bool = false,
        timeout: Duration = .seconds(60)
    ) async throws {
        try await tool.run(
            arguments, environment: environment(host: tool.host, msync: msync), output: output,
            timeout: timeout)
        try await tool.waitForServer(of: self, output: output)
    }
}

public enum WinePrefixError: Error, Equatable {
    case notCreated
}

private func sha256(of file: URL) throws -> String {
    Data(SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))).hexadecimal
}

/// `.macrock-launcher.json`: whether the prefix was fully created, by which engine, whether it
/// has GameInput, and the Retina mode it was given.
private struct LauncherState: Codable, Equatable {
    enum Stage: String, Codable {
        case creating, ready
    }

    static let file = ".macrock-launcher.json"

    var stage: Stage
    var engine: String
    var gameInput = false
    /// Nil until the launcher sets it; Wine's default is off.
    var retinaMode: Bool?

    init(stage: Stage, engine: String) {
        self.stage = stage
        self.engine = engine
    }

    init?(prefix: URL) throws {
        let file = prefix.appending(path: Self.file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func write(prefix: URL) throws {
        try JSONEncoder().encode(self).write(
            to: prefix.appending(path: Self.file), options: .atomic)
    }
}

/// `.macrock-engine.json`, the format the engine's tests also read: the SHA-256 of each
/// applied step's file.
private struct EngineState: Codable {
    static let file = ".macrock-engine.json"

    var revision: Int
    var steps: [String: String] = [:]

    init(revision: Int) {
        self.revision = revision
    }

    init?(prefix: URL) throws {
        let file = prefix.appending(path: Self.file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func write(prefix: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: prefix.appending(path: Self.file), options: .atomic)
    }
}
