import Foundation
import Testing

@testable import LauncherCore

struct EngineUpdateTests {
    func release(_ version: String, serviceProtocol: Int = 1) throws -> EngineRelease {
        let document = Data(releaseIndex(version: version, serviceProtocol: serviceProtocol).utf8)
        return EngineRelease(
            index: try EngineIndex(json: document), document: document, releases: .github)
    }

    @Test(arguments: [
        ("0.1.10", "0.1.9", true), ("0.2", "0.1.9", true), ("0.1.1", "0.1.1", false),
        ("0.1.0", "0.1.1", false),
    ])
    func comparesVersionsNumberByNumber(version: String, installed: String, newer: Bool) throws {
        #expect(try release(version).index.isNewer(than: installed) == newer)
    }

    @Test func offersALaterRelease() throws {
        let latest = try release("0.1.2")
        #expect(latest.update(fromVersion: "0.1.1", serviceProtocol: 1) == .available(latest))
    }

    @Test func offersTheFirstRelease() throws {
        let latest = try release("0.1.1")
        #expect(latest.update(fromVersion: nil, serviceProtocol: 1) == .available(latest))
    }

    @Test(arguments: ["0.1.1", "0.2.0"])
    func offersNothingWhenTheInstalledEngineIsAsRecent(installed: String) throws {
        #expect(try release("0.1.1").update(fromVersion: installed, serviceProtocol: 1) == nil)
    }

    @Test func explainsALaterReleaseThisLauncherCannotUse() throws {
        let latest = try release("0.2.0", serviceProtocol: 2)
        #expect(
            latest.update(fromVersion: "0.1.1", serviceProtocol: 1)
                == .unsupported(latest, .serviceProtocolMismatch(engine: 2, service: 1)))
    }
}
