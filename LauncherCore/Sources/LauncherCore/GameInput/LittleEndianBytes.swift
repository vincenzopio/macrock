/// Little-endian reads from a byte buffer that fail, instead of trapping, past its end.
struct LittleEndianBytes {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func slice(_ offset: Int, _ count: Int) throws(MalformedArchive) -> ArraySlice<UInt8> {
        guard offset >= 0, count >= 0, offset <= bytes.count - count else {
            throw MalformedArchive()
        }
        return bytes[offset..<offset + count]
    }

    func uint8(_ offset: Int) throws(MalformedArchive) -> Int {
        Int(try slice(offset, 1).first ?? 0)
    }

    func uint16(_ offset: Int) throws(MalformedArchive) -> Int {
        try integer(offset, size: 2)
    }

    func uint32(_ offset: Int) throws(MalformedArchive) -> Int {
        try integer(offset, size: 4)
    }

    func uint64(_ offset: Int) throws(MalformedArchive) -> Int {
        try integer(offset, size: 8)
    }

    private func integer(_ offset: Int, size: Int) throws(MalformedArchive) -> Int {
        try slice(offset, size).reversed().reduce(0) { $0 << 8 | Int($1) }
    }
}

struct MalformedArchive: Error {}
