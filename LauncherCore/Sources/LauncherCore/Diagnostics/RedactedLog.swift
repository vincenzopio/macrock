import Foundation

/// A log file fed by child processes through a pipe. Each line goes through a `LogRedactor` before
/// it is written; past the size limit the rest is dropped after a marker line.
public final class RedactedLog: Sendable {
    /// The writing end to give to child processes, any number of them.
    public let writer: FileHandle
    private let reader: FileHandle
    private let writing: Task<Void, any Error>

    /// Creates the file, readable by the user only; an existing file is never overwritten.
    public init(file: URL, knownValues: [String] = [], limit: Int = 64 << 20) throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let pipe = Pipe()
        writer = pipe.fileHandleForWriting
        reader = pipe.fileHandleForReading
        // FileHandle.bytes reads on one serial queue for the whole process, so a log waiting for
        // output would stall every other log; a readability handler has a source of its own.
        let (chunks, received) = AsyncStream<Data>.makeStream()
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                received.finish()
            } else {
                received.yield(chunk)
            }
        }
        writing = Task {
            var lines = LineWriter(
                output: output, redactor: LogRedactor(knownValues: knownValues), limit: limit)
            for await chunk in chunks {
                try lines.append(chunk)
            }
            try lines.finish()
            try output.close()
        }
    }

    /// Closes the log's own writing end, then returns once every process that inherited it has
    /// exited and the last line is on disk. wineserver and Wine's services keep the stderr of the
    /// client that started them, so a Wine log ends only after the prefix's server has stopped.
    public func close() async throws {
        try writer.close()
        try await writing.value
    }
}

/// Splits output into lines and writes them redacted, without terminal colours, up to the limit.
private struct LineWriter {
    let output: FileHandle
    let redactor: LogRedactor
    let limit: Int
    private var pending = Data()
    private var remaining: Int

    init(output: FileHandle, redactor: LogRedactor, limit: Int) {
        self.output = output
        self.redactor = redactor
        self.limit = limit
        remaining = limit
    }

    mutating func append(_ chunk: Data) throws {
        guard remaining > 0 else { return }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            try write(pending[..<newline])
            pending.removeSubrange(...newline)
        }
        // Output without a newline is held only up to the room left, however long it runs.
        if remaining > 0, pending.count > remaining {
            try truncate()
        }
        if remaining == 0 {
            pending.removeAll()
        }
    }

    /// Writes a last line that has no newline.
    mutating func finish() throws {
        guard !pending.isEmpty else { return }
        try write(pending)
        pending.removeAll()
    }

    private mutating func write(_ line: Data) throws {
        guard remaining > 0 else { return }
        var text = String(decoding: line, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        if text.contains("\u{1B}") {
            text.replace(#/\x1B\[[0-9;]*m/#, with: "")
        }
        text = redactor.redact(text) + "\n"
        guard text.utf8.count <= remaining else { return try truncate() }
        remaining -= text.utf8.count
        try output.write(contentsOf: Data(text.utf8))
    }

    private mutating func truncate() throws {
        try output.write(contentsOf: Data("[truncated after \(limit) bytes]\n".utf8))
        remaining = 0
    }
}
