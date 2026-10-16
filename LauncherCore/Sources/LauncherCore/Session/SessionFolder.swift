import Foundation

/// `sessions/<time>-<session>/`: the logs of one session, what it ran and how it ended. None of
/// it names the account: the folder may be attached to a bug report.
struct SessionFolder: Sendable {
    let url: URL
    /// Text the logs mask: the account's label shows in the game's window title.
    let knownValues: [String]

    private let launch: Launch

    init(plan: SessionPlan, start: Date) {
        let stamp = PastSession.stampFormatter.string(from: start)
        url = plan.directory.sessions.appending(path: "\(stamp)-\(plan.id)")
        knownValues = [plan.account.label]
        launch = Launch(
            engine: plan.engine.identity, d3dmetal: plan.d3dmetal.version,
            game: plan.game.version, editor: plan.opensEditor, settings: plan.settings)
    }

    func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try encoder.encode(launch).write(to: url.appending(path: "launch.json"))
    }

    func writeResult(_ outcome: Result<SessionOutcome, any Error>) throws {
        try encoder.encode(EndingRecord(SessionEnding(outcome)))
            .write(to: url.appending(path: "result.json"))
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private struct Launch: Encodable, Sendable {
        let engine: String
        let d3dmetal: String
        let game: String
        let editor: Bool
        let settings: Profile.Settings
    }
}
