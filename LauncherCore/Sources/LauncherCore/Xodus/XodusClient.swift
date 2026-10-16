import Foundation
import Network

/// Talks to an account service on its socket. Each request has a connection of its own: replies
/// carry no request id, so a connection whose request timed out is never reused.
struct XodusClient: Sendable {
    private enum MessageType {
        static let ping: UInt16 = 1
        static let gameLicense: UInt16 = 100
    }

    let socketPath: String
    let timeout: Duration

    init(socketPath: String, timeout: Duration = .seconds(30)) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    func ping() async throws {
        let payload = Data("macrock".utf8)
        guard try await request(MessageType.ping, payload) == payload else {
            throw XodusError.unexpectedReply
        }
    }

    /// Asks the service whether its signed-in account may play the title.
    func gameLicense(storeID: String, market: String) async throws -> GameLicense {
        let request =
            "<GameLicenseRequest><StoreId>\(storeID.xmlEscaped)</StoreId>"
            + "<Market>\(market.xmlEscaped)</Market></GameLicenseRequest>"
        let reply = try await self.request(MessageType.gameLicense, Data(request.utf8))
        guard !reply.isEmpty else { throw XodusError.emptyReply }
        return try GameLicense(reply: reply)
    }

    private func request(_ type: UInt16, _ payload: Data) async throws -> Data {
        let message = try XodusFrame(magic: .xml, type: type, payload: payload).encoded()
        let path = socketPath
        return try await withTimeout(timeout) {
            let connection = NetworkConnection(to: .unix(path: path)) { TCP() }
            try await connection.send(message)
            let reply = try await connection.receive(exactly: XodusFrame.headerSize).content
            let header = try XodusFrame.header(reply, magic: .xml)
            guard header.type == type + 1 else { throw XodusError.unexpectedReply }
            guard header.length > 0 else { return Data() }
            return try await connection.receive(exactly: header.length).content
        }
    }
}

/// What the account service knows about the account's license for a title.
enum GameLicense: Sendable, Equatable {
    case active(trial: Bool)
    case inactive
    /// The service could not find out, and answered with this HRESULT: no signed-in user,
    /// expired tokens or no network all give E_FAIL.
    case unknown(result: UInt32)

    init(reply: Data) throws {
        guard let fields = XMLFields(data: reply),
            let result = fields.texts["Result"].flatMap(UInt32.init)
        else {
            throw XodusError.unexpectedReply
        }
        guard result == 0 else {
            self = .unknown(result: result)
            return
        }
        self =
            fields.texts["IsActive"] == "true"
            ? .active(trial: fields.texts["IsTrial"] == "true") : .inactive
    }
}

public enum XodusError: Error, Equatable {
    case payloadTooLarge
    case unexpectedReply
    case emptyReply
    /// The launcher channel is closed: the service stopped, or a request did not finish.
    case channelClosed
}
