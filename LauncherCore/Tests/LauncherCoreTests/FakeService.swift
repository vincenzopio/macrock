import Foundation

/// A stand-in for xodus-service on a Unix socket. Each connection carries one request; `replies`
/// returns the frames that answer it, in order, or nil to leave the request unanswered. The
/// replies have the request's magic, so the fake also answers the launcher channel's frames that
/// `serviceStandIn` relays.
final class FakeService: Sendable {
    typealias Frame = (type: UInt16, payload: Data)
    typealias Replies = @Sendable (_ type: UInt16, _ payload: Data) -> [Frame]?
    typealias Reply = @Sendable (_ type: UInt16, _ payload: Data) -> Frame?

    let path: String
    private let connections: any DispatchSourceRead

    private init(path: String, replies: @escaping Replies) throws {
        func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw failure() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            let error = failure()
            close(listener)
            throw error
        }
        // Only the cancel handler closes the listener, once no connection is being served: one
        // closed meanwhile would be accepted on again after another socket had taken its number.
        let connections = DispatchSource.makeReadSource(
            fileDescriptor: listener, queue: DispatchQueue(label: "FakeService"))
        connections.setEventHandler {
            let connection = accept(listener, nil, nil)
            if connection >= 0 { Self.serve(connection, replies: replies) }
        }
        connections.setCancelHandler { close(listener) }
        connections.activate()
        // Set last: once every property is set, a throw would run deinit, which removes the
        // socket at `path`, whoever bound it.
        self.path = path
        self.connections = connections
    }

    deinit {
        connections.cancel()
        unlink(path)
    }

    private static func serve(_ connection: Int32, replies: Replies) {
        defer { close(connection) }
        guard let header = read(connection, count: 8) else { return }
        let type = UInt16(header[4]) | UInt16(header[5]) << 8
        let length = Int(header[6]) | Int(header[7]) << 8
        guard let payload = read(connection, count: length) else { return }
        guard let frames = replies(type, payload) else {
            _ = read(connection, count: 1)
            return
        }
        for (replyType, replyPayload) in frames {
            var frame = header.prefix(4)
            frame.append(contentsOf: [UInt8(replyType & 0xff), UInt8(replyType >> 8)])
            frame.append(contentsOf: [
                UInt8(replyPayload.count & 0xff), UInt8(replyPayload.count >> 8),
            ])
            frame.append(replyPayload)
            _ = frame.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        }
    }

    private static func read(_ connection: Int32, count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < count {
            let received = Darwin.read(connection, &buffer, min(buffer.count, count - data.count))
            guard received > 0 else { return nil }
            data.append(contentsOf: buffer[..<received])
        }
        return data
    }
}

extension FakeService {
    /// A fake that answers each request with one frame.
    convenience init(path: String, reply: @escaping Reply) throws {
        try self.init(path: path, replies: { type, payload in reply(type, payload).map { [$0] } })
    }

    /// A fake account service that is ready at once: it answers HELLO, which it gets back with
    /// this launcher's version, and PING, and each other request with the payloads of `replies`.
    convenience init(
        readyAt path: String,
        replies: @escaping @Sendable (_ type: UInt16, _ payload: Data) -> [Data]?
    ) throws {
        try self.init(
            path: path,
            replies: { type, payload in
                guard type > 1, type != 200 else { return [(type + 1, payload)] }
                return replies(type, payload)?.map { (type + 1, $0) }
            })
    }
}
