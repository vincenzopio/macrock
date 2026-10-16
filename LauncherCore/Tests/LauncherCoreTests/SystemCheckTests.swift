import Testing

@testable import LauncherCore

struct SystemCheckTests {
    @Test(arguments: [
        (Int64?.some(SystemCheck.recommendedFreeSpace), true),
        (SystemCheck.recommendedFreeSpace - 1, false), (nil, true),
    ])
    func wantsRoomForTheEngineAndTheGame(freeSpace: Int64?, hasRoom: Bool) {
        let check = SystemCheck(macOS: "27.0", rosettaInstalled: true, freeSpace: freeSpace)
        #expect(check.hasRoom == hasRoom)
    }
}
