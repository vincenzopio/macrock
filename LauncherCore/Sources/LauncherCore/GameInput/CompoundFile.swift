// Adapted from BedrockOnLinux bol/gameinput.py, commit 7a315c836b7ae8068042bc466b0540c16ffe3a5e
// (https://github.com/Wyze3306/BedrockOnLinux).
//
// MIT License
//
// Copyright (c) 2026 BedrockOnLinux contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

/// The streams of an OLE compound file, the container of an MSI package. A stream is a chain
/// of sectors, not a contiguous range, so reading one walks the file's allocation table.
struct CompoundFile {
    private static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let free = 0xFFFF_FFFF
    private static let endOfChain = 0xFFFF_FFFE

    private let file: LittleEndianBytes
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: Int
    private let allocation: [Int]
    private let miniAllocation: [Int]
    private let miniStream: [UInt8]
    private let entries: [(type: Int, start: Int, size: Int)]

    init(_ bytes: [UInt8]) throws(MalformedArchive) {
        let file = LittleEndianBytes(bytes)
        self.file = file
        guard Array(try file.slice(0, 8)) == Self.signature else { throw MalformedArchive() }
        sectorSize = 1 << (try file.uint16(0x1E))
        miniSectorSize = 1 << (try file.uint16(0x20))
        miniStreamCutoff = try file.uint32(0x38)

        var sectorsOfTable = try (0..<109).map { index throws(MalformedArchive) in
            try file.uint32(0x4C + 4 * index)
        }
        var next = try file.uint32(0x44)
        for _ in 0..<(try file.uint32(0x48)) where next != Self.free && next != Self.endOfChain {
            let values = try Self.integers(in: try Self.sector(next, of: file, size: sectorSize))
            sectorsOfTable += values.dropLast()
            next = values.last ?? Self.endOfChain
        }
        var allocation: [Int] = []
        for sector in sectorsOfTable where sector != Self.free {
            allocation += try Self.integers(in: try Self.sector(sector, of: file, size: sectorSize))
        }
        self.allocation = allocation

        let directoryStart = try file.uint32(0x30)
        let directory = LittleEndianBytes(
            try Self.read(
                chain: Self.chain(from: directoryStart, in: allocation), of: file,
                sectorSize: sectorSize, count: Int.max))
        var entries: [(type: Int, start: Int, size: Int)] = []
        for offset in stride(from: 0, to: directory.bytes.count - 127, by: 128)
        where try directory.uint16(offset + 64) != 0 {
            entries.append(
                (
                    try directory.uint8(offset + 66), try directory.uint32(offset + 116),
                    try directory.uint64(offset + 120)
                ))
        }
        self.entries = entries
        guard let root = entries.first(where: { $0.type == 5 }) else { throw MalformedArchive() }
        miniStream = try Self.read(
            chain: Self.chain(from: root.start, in: allocation), of: file, sectorSize: sectorSize,
            count: root.size)
        var miniAllocation: [Int] = []
        for sector in Self.chain(from: try file.uint32(0x3C), in: allocation) {
            miniAllocation += try Self.integers(
                in: try Self.sector(sector, of: file, size: sectorSize))
        }
        self.miniAllocation = miniAllocation
    }

    /// The first stream whose content starts with `prefix`.
    func stream(startingWith prefix: [UInt8]) throws(MalformedArchive) -> [UInt8]? {
        for entry in entries where entry.type == 2 && entry.size >= prefix.count {
            let content =
                entry.size >= miniStreamCutoff
                ? try Self.read(
                    chain: Self.chain(from: entry.start, in: allocation), of: file,
                    sectorSize: sectorSize, count: entry.size)
                : try miniStreamContent(start: entry.start, count: entry.size)
            if content.starts(with: prefix) { return content }
        }
        return nil
    }

    private func miniStreamContent(start: Int, count: Int) throws(MalformedArchive) -> [UInt8] {
        let stream = LittleEndianBytes(miniStream)
        var content: [UInt8] = []
        for sector in Self.chain(from: start, in: miniAllocation) {
            content += try stream.slice(sector * miniSectorSize, miniSectorSize)
        }
        guard content.count >= count else { throw MalformedArchive() }
        return Array(content.prefix(count))
    }

    private static func chain(from start: Int, in allocation: [Int]) -> [Int] {
        var sectors: [Int] = []
        var seen = Set<Int>()
        var sector = start
        while sector != free, sector != endOfChain, sector < allocation.count,
            seen.insert(sector).inserted
        {
            sectors.append(sector)
            sector = allocation[sector]
        }
        return sectors
    }

    private static func read(
        chain: [Int], of file: LittleEndianBytes, sectorSize: Int, count: Int
    ) throws(MalformedArchive) -> [UInt8] {
        var content: [UInt8] = []
        for sector in chain {
            content += try self.sector(sector, of: file, size: sectorSize)
        }
        return Array(content.prefix(count))
    }

    private static func sector(_ index: Int, of file: LittleEndianBytes, size: Int)
        throws(MalformedArchive) -> ArraySlice<UInt8>
    {
        try file.slice((index + 1) * size, size)
    }

    private static func integers(in sector: ArraySlice<UInt8>) throws(MalformedArchive) -> [Int] {
        let bytes = LittleEndianBytes(Array(sector))
        return try stride(from: 0, to: bytes.bytes.count, by: 4).map {
            offset throws(MalformedArchive) in
            try bytes.uint32(offset)
        }
    }
}
