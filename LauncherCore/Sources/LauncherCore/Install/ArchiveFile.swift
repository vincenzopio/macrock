import AppleArchive
import Foundation
import System

/// An Apple Archive, as `aa archive` writes them.
struct ArchiveFile {
    let url: URL

    init(_ url: URL) {
        self.url = url
    }

    /// Extracts the archive's directories, regular files and symbolic links into `directory`,
    /// with their modes and times. Blocks until done: run it on a thread of its own.
    ///
    /// AppleArchive fails the extraction on an entry outside `directory` or one that would be
    /// written through or over a symbolic link. Everything else an archive can hold is left
    /// out: AppleArchive would open a FIFO and wait for a reader forever, and ownership, file
    /// flags, extended attributes and ACLs could make files impossible to delete or put them in
    /// quarantine.
    func extract(into directory: URL) throws {
        let ignoredFields = ArchiveHeader.FieldKeySet()
        for key in ["UID", "GID", "FLG", "XAT", "ACL"] {
            ignoredFields.insert(.init(key))
        }
        do {
            try ArchiveByteStream.withFileStream(
                path: FilePath(url.path), mode: .readOnly, options: [], permissions: []
            ) { file in
                try ArchiveByteStream.withDecompressionStream(readingFrom: file) { data in
                    try ArchiveStream.withDecodeStream(readingFrom: data) { entries in
                        try ArchiveStream.withExtractStream(
                            extractingTo: FilePath(directory.path),
                            selectUsing: Self.skipSpecialFiles
                        ) { files in
                            try ArchiveStream.withConvertStream(
                                writingTo: files, insertKeySet: .init(),
                                removeKeySet: ignoredFields
                            ) { converter in
                                _ = try ArchiveStream.process(
                                    readingFrom: entries, writingTo: converter)
                            }
                        }
                    }
                }
            }
        } catch is ArchiveError {
            throw ReleaseError.unreadableArchive
        }
    }

    private static func skipSpecialFiles(
        _ message: ArchiveHeader.EntryMessage, _ path: FilePath,
        _ data: ArchiveHeader.EntryFilterData?
    ) -> ArchiveHeader.EntryMessageStatus {
        guard message == .extractBegin, case .header(let header) = data else { return .ok }
        switch header.entryType {
        case .regularFile?, .directory?, .link?: return .ok
        default: return .skip
        }
    }
}
