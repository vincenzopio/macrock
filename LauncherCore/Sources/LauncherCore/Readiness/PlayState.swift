import Foundation

/// The first thing missing before the account can play, in the order the user can fix them.
public enum Blocker: Sendable, Equatable {
    /// Wine processes of a session the launcher did not end still run; they must end first.
    case earlierSessionRunning
    /// Another account is playing: the launcher runs one session at a time.
    case anotherAccountPlaying
    case rosettaMissing
    case installingEngine
    case engineMissing
    case graphicsMissing
    /// The selected account is installing the game, and holds its lock until it is done.
    case installingGame
    case gameMissing
    case accountMissing
    /// This build of the launcher may not start the selected account's service.
    case accountNotAllowed
    case signInNeeded
}

/// What the launcher has, as far as playing is concerned.
public struct Readiness: Sendable, Equatable {
    public var earlierSessionRunning = false
    public var anotherAccountPlaying = false
    public var rosettaInstalled: Bool
    /// An engine is being installed: sessions wait until it is in place.
    public var installingEngine = false
    public var engine: Bool
    public var graphics: Bool
    public var installingGame = false
    public var game: Bool
    /// Whether the selected account is signed in; nil without an account.
    public var signedIn: Bool?
    /// Whether this build may start the selected account's service.
    public var accountAllowed = true

    public init(
        rosettaInstalled: Bool, engine: Bool, graphics: Bool, game: Bool, signedIn: Bool?
    ) {
        self.rosettaInstalled = rosettaInstalled
        self.engine = engine
        self.graphics = graphics
        self.game = game
        self.signedIn = signedIn
    }

    public var blocker: Blocker? {
        if earlierSessionRunning { return .earlierSessionRunning }
        if anotherAccountPlaying { return .anotherAccountPlaying }
        if !rosettaInstalled { return .rosettaMissing }
        if installingEngine { return .installingEngine }
        if !engine { return .engineMissing }
        if !graphics { return .graphicsMissing }
        if installingGame { return .installingGame }
        if !game { return .gameMissing }
        guard let signedIn else { return .accountMissing }
        if !accountAllowed { return .accountNotAllowed }
        return signedIn ? nil : .signInNeeded
    }
}

/// What the Play button shows and does.
public enum PlayState: Sendable, Equatable {
    case blocked(Blocker)
    case ready
    case starting(SessionPhase)
    case running
    case stopping

    public init(readiness: Readiness, phase: SessionPhase?) {
        switch phase {
        case .running: self = .running
        case .stopping: self = .stopping
        case let phase?: self = .starting(phase)
        case nil: self = readiness.blocker.map(PlayState.blocked) ?? .ready
        }
    }

    /// Whether the profile and its graphics backend may change: not while a session runs.
    public var allowsChanges: Bool {
        switch self {
        case .ready, .blocked: true
        case .starting, .running, .stopping: false
        }
    }
}
