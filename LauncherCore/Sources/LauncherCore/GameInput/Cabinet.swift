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

import zlib

/// The files of a cabinet whose data blocks are MSZIP compressed, as in the GameInput package.
/// Each block is a raw deflate stream that may refer back to the previous 32 KiB of output.
struct Cabinet {
    struct File {
        let declaredSize: Int
        let content: [UInt8]
    }

    static let signature = Array("MSCF".utf8)
    private static let window = 32_768

    let files: [File]

    init(_ bytes: [UInt8]) throws(MalformedArchive) {
        let cabinet = LittleEndianBytes(bytes)
        guard Array(try cabinet.slice(0, 4)) == Self.signature else { throw MalformedArchive() }
        let filesOffset = try cabinet.uint32(16)
        let folderCount = try cabinet.uint16(26)
        let fileCount = try cabinet.uint16(28)
        var offset = 36
        var folderReserve = 0
        var dataReserve = 0
        if try cabinet.uint16(30) & 4 != 0 {
            let headerReserve = try cabinet.uint16(offset)
            folderReserve = try cabinet.uint8(offset + 2)
            dataReserve = try cabinet.uint8(offset + 3)
            offset += 4 + headerReserve
        }

        var folders: [[UInt8]] = []
        for _ in 0..<folderCount {
            var block = try cabinet.uint32(offset)
            let blockCount = try cabinet.uint16(offset + 4)
            offset += 8 + folderReserve
            var content: [UInt8] = []
            for _ in 0..<blockCount {
                let compressedSize = try cabinet.uint16(block + 4)
                let size = try cabinet.uint16(block + 6)
                block += 8 + dataReserve
                let data = try cabinet.slice(block, compressedSize)
                block += compressedSize
                guard data.starts(with: Array("CK".utf8)) else { throw MalformedArchive() }
                content += try Self.inflate(
                    data.dropFirst(2), dictionary: content.suffix(Self.window), size: size)
            }
            folders.append(content)
        }

        var files: [File] = []
        offset = filesOffset
        for _ in 0..<fileCount {
            let size = try cabinet.uint32(offset)
            let start = try cabinet.uint32(offset + 4)
            let folder = try cabinet.uint16(offset + 8)
            offset += 16
            while try cabinet.uint8(offset) != 0 { offset += 1 }
            offset += 1
            guard folder < folders.count else { throw MalformedArchive() }
            let content = try LittleEndianBytes(folders[folder]).slice(start, size)
            files.append(File(declaredSize: size, content: Array(content)))
        }
        self.files = files
    }

    private static func inflate(
        _ input: ArraySlice<UInt8>, dictionary: ArraySlice<UInt8>, size: Int
    ) throws(MalformedArchive) -> [UInt8] {
        var stream = z_stream()
        guard
            inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                == Z_OK
        else { throw MalformedArchive() }
        defer { inflateEnd(&stream) }
        var dictionary = Array(dictionary)
        var input = Array(input)
        var output = [UInt8](repeating: 0, count: size)
        let status = dictionary.withUnsafeMutableBufferPointer { dictionary in
            input.withUnsafeMutableBufferPointer { input in
                output.withUnsafeMutableBufferPointer { output in
                    if dictionary.count > 0,
                        inflateSetDictionary(
                            &stream, dictionary.baseAddress, uInt(dictionary.count))
                            != Z_OK
                    {
                        return Z_DATA_ERROR
                    }
                    stream.next_in = input.baseAddress
                    stream.avail_in = uInt(input.count)
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    return zlib.inflate(&stream, Z_FINISH)
                }
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size else { throw MalformedArchive() }
        return output
    }
}
