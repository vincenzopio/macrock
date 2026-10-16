import Foundation
import Testing

@testable import LauncherCore

struct EngineReleasesTests {
    let temporary: TemporaryDirectory
    let contents = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
    let release: ReleaseFolder

    init() throws {
        temporary = try TemporaryDirectory()
        release = try ReleaseFolder(in: temporary.url, archive: contents)
    }

    var destination: URL { temporary.url.appending(path: "engine.aar") }

    @Test func readsTheLatestIndexAsPublished() async throws {
        let latest = try await release.releases.latest()
        let published = try Data(contentsOf: release.releases.url.appending(path: "index.json"))
        #expect(latest.document == published)
        #expect(latest.index == (try EngineIndex(json: published)))
    }

    @Test func downloadsTheArchiveAndReportsItsProgress() async throws {
        let (fractions, reporter) = AsyncStream.makeStream(of: Double.self)
        try await release.releases.latest().downloadArchive(to: destination) {
            reporter.yield($0)
        }
        reporter.finish()
        var reported: [Double] = []
        for await fraction in fractions {
            reported.append(fraction)
        }
        #expect(try Data(contentsOf: destination) == contents)
        #expect(reported.last == 1)
        #expect(reported == reported.sorted())
    }

    @Test func refusesAnArchiveWithAChangedByte() async throws {
        var changed = contents
        changed[1000] ^= 0xff
        try changed.write(to: release.archive)
        await #expect(throws: ReleaseError.damagedArchive) {
            try await release.releases.latest().downloadArchive(to: destination) { _ in }
        }
    }

    @Test func failsWhenTheArchiveIsMissing() async throws {
        try FileManager.default.removeItem(at: release.archive)
        await #expect(throws: URLError.self) {
            try await release.releases.latest().downloadArchive(to: destination) { _ in }
        }
    }

    @Test func treatsAnHTTPStatusOtherThan200AsUnavailable() throws {
        let response = try #require(
            HTTPURLResponse(
                url: release.releases.url, statusCode: 404, httpVersion: "HTTP/1.1",
                headerFields: nil))
        #expect(throws: ReleaseError.unavailable(status: 404)) { try response.checkStatus() }
    }
}
