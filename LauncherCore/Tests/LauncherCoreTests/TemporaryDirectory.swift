import Foundation

/// A directory that exists for the lifetime of one test.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "LauncherCoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
