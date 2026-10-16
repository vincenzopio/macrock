import Foundation

/// How a session ended, as its folder records it.
public enum SessionEnding: Sendable, Equatable {
    /// The player quit the game.
    case quit
    case crashed(Termination)
    /// The game closed when asked to.
    case stopped
    /// The game had to be ended.
    case forced
    /// The session stopped before or while it ran, with this error.
    case failed(String)
}

extension SessionEnding {
    init(_ outcome: Result<SessionOutcome, any Error>) {
        switch outcome {
        case .success(.exited(.exited(0))): self = .quit
        case .success(.exited(let termination)): self = .crashed(termination)
        case .success(.stopped): self = .stopped
        case .success(.forced): self = .forced
        case .failure(let error): self = .failed(String(describing: error))
        }
    }
}

/// A session's folder: when it started and, once it is over, how it ended.
public struct PastSession: Sendable, Identifiable {
    public let folder: URL
    public let started: Date
    /// Nil while the session runs, or when the launcher ended before it could write it.
    public let ending: SessionEnding?

    public var id: URL { folder }

    init?(folder: URL) {
        let stamp = folder.lastPathComponent.prefix("yyyyMMdd-HHmmss".count)
        guard let started = Self.stampFormatter.date(from: String(stamp)) else { return nil }
        self.folder = folder
        self.started = started
        let result = folder.appending(path: "result.json")
        ending =
            (try? JSONDecoder().decode(EndingRecord.self, from: Data(contentsOf: result)))?
            .sessionEnding
    }

    static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

extension DataDirectory {
    /// The sessions that left a folder, newest first.
    public func pastSessions() throws -> [PastSession] {
        guard FileManager.default.fileExists(atPath: sessions.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: sessions, includingPropertiesForKeys: nil
        )
        .compactMap(PastSession.init(folder:))
        .sorted { $0.started > $1.started }
    }

    /// Stops what sessions the launcher did not end left running, and returns the prefixes
    /// whose Wine processes still run, for the user to end.
    public func recoverSessions() async -> [WinePrefix] {
        await RunRecord.recover(in: self)
    }
}

/// `result.json`: one flat record a person can read too.
struct EndingRecord: Codable {
    enum Kind: String, Codable {
        case quit, crashed, stopped, forced, failed
    }

    var ending: Kind
    var status: Int32?
    var signal: Int32?
    var error: String?

    init(_ ending: SessionEnding) {
        switch ending {
        case .quit:
            self.ending = .quit
        case .crashed(.exited(let status)):
            self.ending = .crashed
            self.status = status
        case .crashed(.signaled(let signal)):
            self.ending = .crashed
            self.signal = signal
        case .stopped:
            self.ending = .stopped
        case .forced:
            self.ending = .forced
        case .failed(let error):
            self.ending = .failed
            self.error = error
        }
    }

    var sessionEnding: SessionEnding {
        switch ending {
        case .quit: .quit
        case .crashed: .crashed(signal.map(Termination.signaled) ?? .exited(status ?? 0))
        case .stopped: .stopped
        case .forced: .forced
        case .failed: .failed(error ?? "")
        }
    }
}
