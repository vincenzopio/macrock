import Foundation

/// The engines the launcher installed. Each has a folder named after its identity, with the bundle
/// and the `index.json` it came with: what the bundle is checked against every time it opens.
public struct EngineStore: Sendable {
    public let root: URL

    public init(in directory: DataDirectory) {
        root = directory.engines
    }

    public func folder(of identity: String) -> URL {
        root.appending(path: identity)
    }

    /// The index an installed engine came with, or nil when the engine is missing or its index
    /// unreadable: either way it needs installing again.
    public func installedIndex(of identity: String) -> EngineIndex? {
        try? EngineIndex(contentsOf: folder(of: identity).appending(path: EngineRuntime.indexFile))
    }

    /// The licenses and the sources notes of an installed engine's runtime.
    public func documentation(of identity: String) -> URL? {
        guard let index = installedIndex(of: identity) else { return nil }
        let folder = folder(of: identity).appending(
            path: "\(index.bundle.path)/\(EngineRuntime.runtimePath)/share/doc/macrock-engine")
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// Opens an installed engine, checking every file, on a thread of its own.
    public func open(_ identity: String) async throws -> EngineRuntime {
        let folder = folder(of: identity)
        return try await runOnDedicatedThread { try EngineRuntime(installedIn: folder) }
    }

    /// Downloads the release's runtime, checks it and installs it, replacing an engine with the
    /// same identity. The work happens in a staging folder, so a failure leaves nothing behind.
    /// `progress` receives the fraction downloaded and finishes when the install does.
    public func install(
        _ release: EngineRelease, progress: AsyncStream<Double>.Continuation
    ) async throws -> EngineRuntime {
        defer { progress.finish() }
        let staging = root.appending(path: ".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItemIfPresent(at: staging) }
        let archive = staging.appending(path: release.index.bundle.file)
        try await release.downloadArchive(to: archive) { progress.yield($0) }
        return try await runOnDedicatedThread { [root] in
            let manager = FileManager.default
            let contents = staging.appending(path: "contents")
            try manager.createDirectory(at: contents, withIntermediateDirectories: false)
            try ArchiveFile(archive).extract(into: contents)
            let engine = try EngineRuntime(
                bundle: contents.appending(path: release.index.bundle.path), index: release.index)
            let installed = staging.appending(path: engine.identity)
            try manager.createDirectory(at: installed, withIntermediateDirectories: false)
            try release.document.write(to: installed.appending(path: EngineRuntime.indexFile))
            try manager.moveItem(
                at: engine.bundle, to: installed.appending(path: release.index.bundle.path))
            let destination = root.appending(path: engine.identity)
            try manager.removeItemIfPresent(at: destination)
            try manager.moveItem(at: installed, to: destination)
            return try EngineRuntime(installedIn: destination)
        }
    }

    /// Deletes every engine but the ones named, and what an interrupted install left, on a
    /// thread of its own.
    public func removeEngines(except kept: Set<String>) async throws {
        try await runOnDedicatedThread { [root] in
            let manager = FileManager.default
            guard manager.fileExists(atPath: root.path) else { return }
            for name in try manager.contentsOfDirectory(atPath: root.path)
            where !kept.contains(name) {
                try manager.removeItem(at: root.appending(path: name))
            }
        }
    }
}

extension EngineRuntime {
    fileprivate static let indexFile = "index.json"

    /// Opens an engine in the store's layout: the bundle in `folder`, checked against the index
    /// beside it.
    init(installedIn folder: URL) throws {
        let index = try EngineIndex(contentsOf: folder.appending(path: Self.indexFile))
        try self.init(bundle: folder.appending(path: index.bundle.path), index: index)
    }
}
