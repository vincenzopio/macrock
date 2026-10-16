import Foundation
import Synchronization
import Testing

@testable import LauncherCore

struct XodusFrameTests {
    @Test func encodesALittleEndianHeader() throws {
        let frame = try XodusFrame(magic: .xml, type: 100, payload: Data("ab".utf8)).encoded()
        #expect([UInt8](frame) == [0x58, 0x53, 0x44, 0x58, 100, 0, 2, 0, 0x61, 0x62])
        #expect(try XodusFrame.header(frame.prefix(8), magic: .xml) == (100, 2))
    }

    @Test func refusesAPayloadThatDoesNotFitTheLength() {
        #expect(throws: XodusError.payloadTooLarge) {
            try XodusFrame(magic: .xml, type: 1, payload: Data(count: 65_536)).encoded()
        }
    }

    @Test func refusesAnotherMagic() {
        #expect(throws: XodusError.unexpectedReply) {
            try XodusFrame.header(Data([0x58, 0x53, 0x44, 0x58, 2, 0, 0, 0]), magic: .protobuf)
        }
    }
}

struct XodusClientTests {
    let path = shortSocketPath()

    func licenseReply(_ result: String, active: Bool) -> FakeService.Reply {
        { type, _ in
            let xml =
                "<GameLicenseResponse><Result>\(result)</Result><IsActive>\(active)</IsActive>"
                + "<IsTrial>false</IsTrial><SkuStoreId>9NBLGGH2JHXJ/0010</SkuStoreId></GameLicenseResponse>"
            return (type + 1, Data(xml.utf8))
        }
    }

    @Test func readsAnActiveLicense() async throws {
        let service = try FakeService(path: path, reply: licenseReply("0", active: true))
        let license = try await XodusClient(socketPath: service.path)
            .gameLicense(storeID: "9NBLGGH2JHXJ", market: "US")
        #expect(license == .active(trial: false))
    }

    @Test func readsAnAccountWithoutTheGame() async throws {
        let service = try FakeService(path: path, reply: licenseReply("0", active: false))
        let license = try await XodusClient(socketPath: service.path)
            .gameLicense(storeID: "9NBLGGH2JHXJ", market: "US")
        #expect(license == .inactive)
    }

    @Test func readsAServiceThatCouldNotFindOut() async throws {
        let service = try FakeService(path: path, reply: licenseReply("2147500037", active: false))
        let license = try await XodusClient(socketPath: service.path)
            .gameLicense(storeID: "9NBLGGH2JHXJ", market: "US")
        #expect(license == .unknown(result: 0x8000_4005))
    }

    @Test func escapesTheRequest() async throws {
        let requests = Mutex<[String]>([])
        let service = try FakeService(path: path) { type, payload in
            requests.withLock { $0.append(String(decoding: payload, as: UTF8.self)) }
            return (type + 1, Data())
        }
        await #expect(throws: XodusError.emptyReply) {
            try await XodusClient(socketPath: service.path).gameLicense(
                storeID: "<&>", market: "US")
        }
        #expect(
            requests.withLock { $0 } == [
                "<GameLicenseRequest><StoreId>&lt;&amp;&gt;</StoreId><Market>US</Market></GameLicenseRequest>"
            ])
    }

    @Test func refusesAReplyOfAnotherType() async throws {
        let service = try FakeService(path: path) { _, payload in (1, payload) }
        await #expect(throws: XodusError.unexpectedReply) {
            try await XodusClient(socketPath: service.path).ping()
        }
    }

    @Test func givesUpOnASilentService() async throws {
        let service = try FakeService(path: path) { _, _ in nil }
        let client = XodusClient(socketPath: service.path, timeout: .milliseconds(300))
        await #expect(throws: TimeoutError.self) { try await client.ping() }
    }
}

/// A socket path short enough for `sun_path`: the test's temporary directory is too deep.
func shortSocketPath() -> String {
    URL.temporaryDirectory.appending(path: "lc-\(UInt32.random(in: .min ... .max)).sock").path
}
