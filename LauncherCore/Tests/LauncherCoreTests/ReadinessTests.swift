import Testing

@testable import LauncherCore

struct ReadinessTests {
    let ready = Readiness(
        rosettaInstalled: true, engine: true, graphics: true, game: true, signedIn: true)

    @Test func reportsTheFirstMissingRequirement() {
        var readiness = ready
        readiness.signedIn = nil
        readiness.game = false
        #expect(readiness.blocker == .gameMissing)
        readiness.installingGame = true
        #expect(readiness.blocker == .installingGame)
        readiness.installingGame = false
        readiness.game = true
        #expect(readiness.blocker == .accountMissing)
        readiness.signedIn = false
        #expect(readiness.blocker == .signInNeeded)
        readiness.accountAllowed = false
        #expect(readiness.blocker == .accountNotAllowed)
        readiness.engine = false
        #expect(readiness.blocker == .engineMissing)
        readiness.installingEngine = true
        #expect(readiness.blocker == .installingEngine)
        readiness.rosettaInstalled = false
        #expect(readiness.blocker == .rosettaMissing)
        readiness.anotherAccountPlaying = true
        #expect(readiness.blocker == .anotherAccountPlaying)
        readiness.earlierSessionRunning = true
        #expect(readiness.blocker == .earlierSessionRunning)
    }

    @Test(arguments: [
        (SessionPhase?.none, PlayState.ready),
        (.startingService, .starting(.startingService)),
        (.preparingPrefix, .starting(.preparingPrefix)),
        (.running, .running),
        (.stopping, .stopping),
    ])
    func followsTheSession(phase: SessionPhase?, state: PlayState) {
        #expect(PlayState(readiness: ready, phase: phase) == state)
    }

    @Test func aRunningSessionWinsOverWhatIsMissing() {
        var readiness = ready
        readiness.game = false
        #expect(PlayState(readiness: readiness, phase: nil) == .blocked(.gameMissing))
        #expect(PlayState(readiness: readiness, phase: .running) == .running)
    }

    @Test(arguments: [
        (PlayState.ready, true), (.blocked(.gameMissing), true),
        (.starting(.checkingLicense), false), (.running, false), (.stopping, false),
    ])
    func profilesChangeOnlyWithoutASession(state: PlayState, allowsChanges: Bool) {
        #expect(state.allowsChanges == allowsChanges)
    }
}
