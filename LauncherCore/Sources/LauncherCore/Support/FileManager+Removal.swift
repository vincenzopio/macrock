import Foundation

extension FileManager {
    /// Removes the item if there is one. A symbolic link counts even when its target is gone.
    func removeItemIfPresent(at url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return }
        try removeItem(at: url)
    }
}
