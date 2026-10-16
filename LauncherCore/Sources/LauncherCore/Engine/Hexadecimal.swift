import Foundation

extension Data {
    init?(hexadecimal text: some StringProtocol) {
        guard text.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexadecimal: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension KeyedDecodingContainer {
    func decodeHexadecimal(forKey key: Key) throws -> Data {
        let text = try decode(String.self, forKey: key)
        guard let data = Data(hexadecimal: text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "not hexadecimal")
        }
        return data
    }
}
