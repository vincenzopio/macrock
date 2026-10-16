import CryptoKit
import Foundation
import Security

/// A Windows program, as far as its Authenticode signature goes: a PKCS#7 signature in the
/// program's certificate table, over the digest of the rest of the file.
///
/// The Security framework's CMS decoder refuses Authenticode, whose signed content is not the
/// octet string CMS expects; the signature is read here, and checked with the framework's keys
/// and trust.
struct WindowsProgram {
    let url: URL

    /// Throws unless Microsoft signed the program as it is: the signature names the file's
    /// digest, verifies with its signer's key, and the signer chains to Microsoft's code signing
    /// root as it was when the signer's certificate was issued.
    func checkSignedByMicrosoft() throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let layout = try PELayout(file: file)
        try file.seek(toOffset: layout.certificateTable.lowerBound)
        guard let table = try file.read(upToCount: layout.certificateTable.count),
            table.count == layout.certificateTable.count, table.count > 8,
            table.littleEndian(UInt16.self, at: 6) == 0x0002
        else { throw ProgramSignatureError.malformed }
        let length = Int(table.littleEndian(UInt32.self, at: 0))
        guard (9...table.count).contains(length) else { throw ProgramSignatureError.malformed }
        let signature = try AuthenticodeSignature(
            der: table[(table.startIndex + 8)..<(table.startIndex + length)])
        guard try layout.digest(of: file) == signature.programDigest else {
            throw ProgramSignatureError.modified
        }
        try signature.checkSignedByMicrosoft()
    }
}

/// Why a Windows program is not one that Microsoft signed as it is.
public enum ProgramSignatureError: Error, Equatable {
    case unsigned
    /// The program or its signature is not what Authenticode makes.
    case malformed
    /// The signature uses an algorithm other than SHA-256 with RSA.
    case unsupportedAlgorithm
    /// The program differs from what was signed, or the signature does not verify.
    case modified
    /// The signer's certificate does not chain to Microsoft's code signing root, or does not
    /// name Microsoft.
    case notMicrosoft
}

/// Where a PE file keeps what its Authenticode digest leaves out: the checksum, the certificate
/// table's entry in the data directories, and the certificate table.
private struct PELayout {
    let size: UInt64
    let checksum: UInt64
    let securityEntry: UInt64
    let certificateTable: Range<UInt64>

    init(file: FileHandle) throws {
        size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        guard let headers = try file.read(upToCount: 4096), headers.count >= 0x40,
            headers.prefix(2) == Data("MZ".utf8)
        else { throw ProgramSignatureError.malformed }
        let pe = Int(headers.littleEndian(UInt32.self, at: 0x3C))
        let optional = pe + 24
        guard pe + 4 <= headers.count, headers[pe..<(pe + 4)] == Data([0x50, 0x45, 0, 0]),
            optional + 2 <= headers.count
        else { throw ProgramSignatureError.malformed }
        let directories: Int
        switch headers.littleEndian(UInt16.self, at: optional) {
        case 0x10B: directories = optional + 96
        case 0x20B: directories = optional + 112
        default: throw ProgramSignatureError.malformed
        }
        let entry = directories + 4 * 8
        guard entry + 8 <= headers.count else { throw ProgramSignatureError.malformed }
        checksum = UInt64(optional + 64)
        securityEntry = UInt64(entry)
        let offset = UInt64(headers.littleEndian(UInt32.self, at: entry))
        let length = UInt64(headers.littleEndian(UInt32.self, at: entry + 4))
        guard length > 0 else { throw ProgramSignatureError.unsigned }
        guard offset >= securityEntry + 8, offset + length <= size else {
            throw ProgramSignatureError.malformed
        }
        certificateTable = offset..<(offset + length)
    }

    /// The SHA-256 of the file without what the digest leaves out.
    func digest(of file: FileHandle) throws -> Data {
        var hash = SHA256()
        let ranges = [
            0..<checksum, (checksum + 4)..<securityEntry,
            (securityEntry + 8)..<certificateTable.lowerBound, certificateTable.upperBound..<size,
        ]
        for range in ranges where !range.isEmpty {
            try file.seek(toOffset: range.lowerBound)
            var left = range.count
            while left > 0 {
                guard let chunk = try file.read(upToCount: min(left, 1 << 20)), !chunk.isEmpty
                else { throw ProgramSignatureError.malformed }
                hash.update(data: chunk)
                left -= chunk.count
            }
        }
        return Data(hash.finalize())
    }
}

/// An Authenticode PKCS#7 signature: what it says the program's digest is, and how it signed
/// that.
private struct AuthenticodeSignature {
    private enum OID {
        static let signedData: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        static let indirectData: [UInt8] = [
            0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x04,
        ]
        static let sha256: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
        static let messageDigest: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]
        static let rsa: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        static let sha256WithRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    }

    /// The digest of the program the signature names.
    let programDigest: Data
    /// The SHA-256 the signed attributes give for the signed content.
    private let contentDigest: Data
    /// The signed content, a SpcIndirectDataContent, without its tag and length: Authenticode
    /// digests only its value.
    private let content: Data
    /// The signed attributes as the signature covers them, re-tagged as a SET OF.
    private let signedAttributes: Data
    private let signature: Data
    private let certificates: [SecCertificate]

    init(der: Data) throws {
        // ContentInfo, then SignedData.
        let info = try DERElement(padded: der).children()
        guard info.count == 2, info[0].value.elementsEqual(OID.signedData) else {
            throw ProgramSignatureError.malformed
        }
        let signedData = try DERElement(only: info[1].value).children()
        guard signedData.count >= 4 else { throw ProgramSignatureError.malformed }
        let encapsulated = try signedData[2].children()
        guard encapsulated.count == 2, encapsulated[0].value.elementsEqual(OID.indirectData)
        else { throw ProgramSignatureError.malformed }
        let indirect = try DERElement(only: encapsulated[1].value)
        content = indirect.value
        let digestInfo = try indirect.children()
        guard digestInfo.count == 2 else { throw ProgramSignatureError.malformed }
        let digest = try digestInfo[1].children()
        guard digest.count == 2, let algorithm = try digest[0].children().first else {
            throw ProgramSignatureError.malformed
        }
        guard algorithm.value.elementsEqual(OID.sha256) else {
            throw ProgramSignatureError.unsupportedAlgorithm
        }
        programDigest = digest[1].value

        certificates =
            try signedData.dropFirst(3).first { $0.tag == 0xA0 }.map {
                try $0.children().compactMap {
                    SecCertificateCreateWithData(nil, $0.encoded as CFData)
                }
            } ?? []
        guard let signerInfos = signedData.last, signerInfos.tag == 0x31,
            let signer = try signerInfos.children().first?.children(), signer.count >= 6,
            signer[3].tag == 0xA0
        else { throw ProgramSignatureError.malformed }
        guard try signer[2].children().first?.value.elementsEqual(OID.sha256) == true,
            let signing = try signer[4].children().first?.value,
            signing.elementsEqual(OID.rsa) || signing.elementsEqual(OID.sha256WithRSA)
        else { throw ProgramSignatureError.unsupportedAlgorithm }
        var attributes = signer[3].encoded
        attributes[attributes.startIndex] = 0x31
        signedAttributes = attributes
        contentDigest =
            try signer[3].children().first { attribute in
                try attribute.children().first?.value.elementsEqual(OID.messageDigest) == true
            }.flatMap { try $0.children().last?.children().first?.value } ?? Data()
        signature = signer[5].value
    }

    func checkSignedByMicrosoft() throws {
        guard Data(SHA256.hash(data: content)) == contentDigest,
            let signer = certificates.first(where: signs)
        else { throw ProgramSignatureError.modified }
        let others = certificates.filter { $0 != signer }
        var trust: SecTrust?
        guard
            SecTrustCreateWithCertificates(
                [signer] + others as CFArray,
                SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil), &trust)
                == errSecSuccess, let trust
        else { throw ProgramSignatureError.notMicrosoft }
        SecTrustSetAnchorCertificates(trust, [SecCertificate.microsoftRoot2011] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetNetworkFetchAllowed(trust, false)
        // A signature outlives its certificate: the chain must hold when the signer's
        // certificate was issued, the earliest it could have signed.
        if let issued = SecCertificateCopyNotValidBeforeDate(signer) {
            SecTrustSetVerifyDate(trust, (issued as Date).addingTimeInterval(1) as CFDate)
        }
        guard SecTrustEvaluateWithError(trust, nil),
            SecCertificateCopySubjectSummary(signer) as String? == "Microsoft Corporation"
        else { throw ProgramSignatureError.notMicrosoft }
    }

    private func signs(_ certificate: SecCertificate) -> Bool {
        guard let key = SecCertificateCopyKey(certificate) else { return false }
        return SecKeyVerifySignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, signedAttributes as CFData,
            signature as CFData, nil)
    }
}

/// One element of DER: its tag, its value, and all of its bytes.
private struct DERElement {
    let tag: UInt8
    let value: Data
    let encoded: Data

    /// The element `data` holds, with nothing after it.
    init(only data: Data) throws {
        var index = data.startIndex
        self = try DERElement(reading: data, at: &index)
        guard index == data.endIndex else { throw ProgramSignatureError.malformed }
    }

    /// The element at the start of `data`, which the certificate table pads with zeros.
    init(padded data: Data) throws {
        var index = data.startIndex
        self = try DERElement(reading: data, at: &index)
        guard data[index...].allSatisfy({ $0 == 0 }) else { throw ProgramSignatureError.malformed }
    }

    private init(reading data: Data, at index: inout Data.Index) throws {
        let start = index
        guard index < data.endIndex else { throw ProgramSignatureError.malformed }
        tag = data[index]
        index += 1
        guard index < data.endIndex else { throw ProgramSignatureError.malformed }
        var length = Int(data[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), index + count <= data.endIndex else {
                throw ProgramSignatureError.malformed
            }
            length = data[index..<(index + count)].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard length <= data.endIndex - index else { throw ProgramSignatureError.malformed }
        value = data[index..<(index + length)]
        index += length
        encoded = data[start..<index]
    }

    func children() throws -> [DERElement] {
        var elements: [DERElement] = []
        var index = value.startIndex
        while index < value.endIndex {
            elements.append(try DERElement(reading: value, at: &index))
        }
        return elements
    }
}

extension Data {
    fileprivate func littleEndian<Value: FixedWidthInteger>(
        _: Value.Type, at offset: Int
    ) -> Value {
        self[(startIndex + offset)...].prefix(MemoryLayout<Value>.size).reversed().reduce(0) {
            $0 << 8 | Value($1)
        }
    }
}
