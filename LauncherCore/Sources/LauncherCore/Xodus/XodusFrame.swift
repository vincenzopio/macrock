import Foundation

/// A message of the Xodus IPC (xodus-service `connection/mod.rs`): a little-endian header with a
/// magic, the message type and the payload length, then the payload. A reply's type is the
/// request's plus one. The public socket carries XML, the launcher channel protobuf messages.
struct XodusFrame: Equatable {
    enum Magic: UInt32 {
        case xml = 0x5844_5358
        case protobuf = 0x5844_5350
    }

    static let headerSize = 8

    let magic: Magic
    let type: UInt16
    let payload: Data

    func encoded() throws(XodusError) -> Data {
        guard let length = UInt16(exactly: payload.count) else { throw .payloadTooLarge }
        var data = Data(capacity: Self.headerSize + payload.count)
        withUnsafeBytes(of: magic.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: type.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: length.littleEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    /// Reads a header with `magic`: the message type and the length of the payload that follows.
    static func header(_ data: Data, magic: Magic) throws(XodusError) -> (
        type: UInt16, length: Int
    ) {
        let bytes = [UInt8](data)
        guard bytes.count == headerSize else { throw .unexpectedReply }
        func value(at offset: Int, size: Int) -> UInt32 {
            (0..<size).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        guard value(at: 0, size: 4) == magic.rawValue else { throw .unexpectedReply }
        return (UInt16(value(at: 4, size: 2)), Int(value(at: 6, size: 2)))
    }
}
