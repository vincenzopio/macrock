import Foundation

/// What the launcher shows of a world's `level.dat`: little-endian NBT after an 8-byte header.
/// The game shows the name in it, not the one in `levelname.txt`.
struct LevelData: Equatable {
    var name: String?
    var lastPlayed: Date?

    /// Nil when the data is not a level the game wrote.
    init?(data: Data) {
        var reader = NBTReader(bytes: [UInt8](data))
        do {
            try reader.skip(8)
            guard try reader.byte() == NBTReader.compound else { return nil }
            try reader.skipString()
            while let (type, name) = try reader.tag() {
                switch (type, name) {
                case (NBTReader.string, "LevelName"):
                    self.name = try reader.string()
                case (NBTReader.long, "LastPlayed"):
                    lastPlayed = Date(timeIntervalSince1970: TimeInterval(try reader.long()))
                default:
                    try reader.skipPayload(of: type, depth: 0)
                }
            }
        } catch {
            return nil
        }
    }
}

private struct NBTReader {
    static let long: UInt8 = 4
    static let string: UInt8 = 8
    static let compound: UInt8 = 10

    struct Malformed: Error {}

    let bytes: [UInt8]
    var offset = 0

    /// The next tag of a compound, nil at its end.
    mutating func tag() throws -> (type: UInt8, name: String)? {
        let type = try byte()
        return type == 0 ? nil : (type, try string())
    }

    mutating func byte() throws -> UInt8 {
        let start = offset
        try skip(1)
        return bytes[start]
    }

    mutating func string() throws -> String {
        let length = Int(try littleEndian(2))
        return String(decoding: try take(length), as: UTF8.self)
    }

    mutating func skipString() throws {
        try skip(Int(try littleEndian(2)))
    }

    mutating func long() throws -> Int64 {
        Int64(bitPattern: try littleEndian(8))
    }

    mutating func skip(_ count: Int) throws {
        guard count <= bytes.count - offset else { throw Malformed() }
        offset += count
    }

    mutating func skipPayload(of type: UInt8, depth: Int) throws {
        guard depth < 64 else { throw Malformed() }
        switch type {
        case 1: try skip(1)
        case 2: try skip(2)
        case 3, 5: try skip(4)
        case 4, 6: try skip(8)
        case 7: try skip(try count())
        case 8: try skipString()
        case 9:
            let elements = try byte()
            for _ in 0..<(try count()) {
                try skipPayload(of: elements, depth: depth + 1)
            }
        case 10:
            while let (type, _) = try tag() {
                try skipPayload(of: type, depth: depth + 1)
            }
        case 11: try skip(try count() * 4)
        case 12: try skip(try count() * 8)
        default: throw Malformed()
        }
    }

    /// The length of an array or list, which NBT stores signed.
    private mutating func count() throws -> Int {
        let count = Int32(bitPattern: UInt32(try littleEndian(4)))
        guard count >= 0 else { throw Malformed() }
        return Int(count)
    }

    private mutating func littleEndian(_ size: Int) throws -> UInt64 {
        try take(size).reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        let start = offset
        try skip(count)
        return bytes[start..<offset]
    }
}
