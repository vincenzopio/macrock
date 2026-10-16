import AppleArchive
import Foundation
import System

@testable import LauncherCore

enum ArchiveEntry {
    case directory(String)
    case file(String, String, mode: UInt64 = 0o644)
    case link(String, to: String)
    case fifo(String)
    /// Owned by root, immutable and in quarantine.
    case lockedFile(String)
}

extension ArchiveFile {
    static func make(at url: URL, _ entries: [ArchiveEntry]) throws -> ArchiveFile {
        try ArchiveByteStream.withFileStream(
            path: FilePath(url.path), mode: .writeOnly, options: [.create, .truncate],
            permissions: [.ownerReadWrite]
        ) { file in
            try ArchiveByteStream.withCompressionStream(using: .lzfse, writingTo: file) { data in
                try ArchiveStream.withEncodeStream(writingTo: data) { encoder in
                    for entry in entries {
                        try encoder.write(entry)
                    }
                }
            }
        }
        return ArchiveFile(url)
    }
}

extension ArchiveStream {
    fileprivate func write(_ entry: ArchiveEntry) throws {
        let header = ArchiveHeader()
        func append(_ key: String, _ value: UInt64) {
            header.append(.uint(key: .init(key), value: value))
        }
        func append(_ key: String, _ value: String) {
            header.append(.string(key: .init(key), value: value))
        }
        var blobs: [(key: String, bytes: [UInt8])] = []
        switch entry {
        case .directory(let path):
            append("TYP", UInt64(ArchiveHeader.EntryType.directory.rawValue))
            append("PAT", path)
            append("MOD", 0o755)
        case .file(let path, let text, let mode):
            append("TYP", UInt64(ArchiveHeader.EntryType.regularFile.rawValue))
            append("PAT", path)
            append("MOD", mode)
            blobs.append(("DAT", Array(text.utf8)))
        case .link(let path, let target):
            append("TYP", UInt64(ArchiveHeader.EntryType.link.rawValue))
            append("PAT", path)
            append("LNK", target)
        case .fifo(let path):
            append("TYP", UInt64(ArchiveHeader.EntryType.fifo.rawValue))
            append("PAT", path)
            append("MOD", 0o644)
        case .lockedFile(let path):
            append("TYP", UInt64(ArchiveHeader.EntryType.regularFile.rawValue))
            append("PAT", path)
            append("MOD", 0o644)
            append("UID", 0)
            append("GID", 0)
            append("FLG", UInt64(UF_IMMUTABLE))
            let attributes = ArchiveHeader.EntryXATBlob()
            attributes.append(
                .init(key: "com.apple.quarantine", data: ContiguousArray("0081;0;Safari;".utf8)))
            blobs.append(("XAT", attributes.withAAEncodedData { Array($0) }))
            blobs.append(("DAT", Array("locked".utf8)))
        }
        for blob in blobs {
            header.append(.blob(key: .init(blob.key), size: UInt64(blob.bytes.count)))
        }
        try writeHeader(header)
        for blob in blobs {
            try blob.bytes.withUnsafeBytes { try writeBlob(key: .init(blob.key), from: $0) }
        }
    }
}
