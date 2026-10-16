import Foundation

extension FileManager {
    /// The bytes the files in `folder` take on disk.
    func allocatedSize(of folder: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let files = enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return 0
        }
        var size: Int64 = 0
        for case let file as URL in files {
            size += Int64(try file.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize ?? 0)
        }
        return size
    }
}
