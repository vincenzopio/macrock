import CryptoKit
import Foundation
import Synchronization

/// Where macrock-engine releases are published: a release's `index.json` next to the archives
/// it names. GitHub serves the latest release's files this way, and so does a folder of
/// packages such as the engine's `build.noindex/packages`.
public struct EngineReleases: Sendable, Equatable {
    // swift-format-ignore: NeverForceUnwrap
    // A literal that parses: the first use would trap otherwise.
    public static let github = EngineReleases(
        url: URL(string: "https://github.com/vincenzopio/macrock-engine/releases/latest/download/")!
    )

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func latest() async throws -> EngineRelease {
        let session = URLSession(configuration: .releaseFiles)
        defer { session.finishTasksAndInvalidate() }
        let (document, response) = try await session.data(
            from: url.appending(path: "index.json"))
        try response.checkStatus()
        return EngineRelease(
            index: try EngineIndex(json: document), document: document, releases: self)
    }
}

/// A published release, as its index describes it.
public struct EngineRelease: Sendable, Equatable {
    public let index: EngineIndex
    /// The index as published, which the store keeps beside the installed engine.
    let document: Data
    let releases: EngineReleases

    /// Downloads the runtime archive to `file`, which must not exist, and checks it against the
    /// index. `progress` receives the fraction downloaded, on a URLSession queue.
    func downloadArchive(to file: URL, progress: @escaping @Sendable (Double) -> Void)
        async throws
    {
        let archive = index.bundle
        let download = ArchiveDownload(to: file, size: archive.size, progress: progress)
        let session = URLSession(
            configuration: .releaseFiles, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: releases.url.appending(path: archive.file))
        try await withTaskCancellationHandler {
            try await download.run(task)
        } onCancel: {
            task.cancel()
        }
        try await runOnDedicatedThread { try archive.check(file) }
    }
}

public enum ReleaseError: Error, Equatable {
    case unavailable(status: Int)
    /// The downloaded archive's size or SHA-256 isn't the one in the index.
    case damagedArchive
    /// AppleArchive couldn't extract it, or refused an entry.
    case unreadableArchive
}

extension EngineIndex.Archive {
    func check(_ file: URL) throws {
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        guard data.count == size, Data(SHA256.hash(data: data)) == sha256 else {
            throw ReleaseError.damagedArchive
        }
    }
}

extension URLResponse {
    /// File URLs have no status.
    func checkStatus() throws(ReleaseError) {
        if let response = self as? HTTPURLResponse, response.statusCode != 200 {
            throw .unavailable(status: response.statusCode)
        }
    }
}

extension URLSessionConfiguration {
    /// A new release replaces the files under the same URLs, so nothing is cached.
    fileprivate static var releaseFiles: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

/// The session's delegate for one download. The delegate `download(from:delegate:)` takes gets
/// no progress at all, so the download runs as a task of a session of its own.
private final class ArchiveDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    private let file: URL
    private let size: Int64
    private let progress: @Sendable (Double) -> Void
    private let finished = Mutex<CheckedContinuation<Void, any Error>?>(nil)

    init(to file: URL, size: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.file = file
        self.size = size
        self.progress = progress
    }

    func run(_ task: URLSessionDownloadTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            finished.withLock { $0 = continuation }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(min(Double(totalBytesWritten) / Double(size), 1))
    }

    /// The temporary file is deleted when this returns, so it is moved here.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        finish(
            with: Result {
                try downloadTask.response?.checkStatus()
                try FileManager.default.moveItem(at: location, to: file)
            })
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        if let error {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<Void, any Error>) {
        finished.withLock {
            $0?.resume(with: result)
            $0 = nil
        }
    }
}
