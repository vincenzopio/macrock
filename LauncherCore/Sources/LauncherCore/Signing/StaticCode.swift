import Foundation
import Security

/// The code signature of a binary or bundle on disk.
///
/// Checking one blocks: Security spreads the work over dispatch queues and waits for it. Run it
/// on a thread of its own, never on Swift's cooperative pool; a pool whose threads all wait on
/// checks can stop for good.
public struct StaticCode {
    private let code: SecStaticCode

    public init(_ url: URL) throws {
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
        guard let code else { throw CodeSignatureError(status: errSecCSUnsigned) }
        self.code = code
    }

    /// Checks every sealed file, as `codesign --verify --strict` does: a changed, missing or
    /// added file fails, and so does a symlink that leaves the bundle.
    public func validate(requirement: String? = nil) throws {
        var compiled: SecRequirement?
        if let requirement {
            try check(SecRequirementCreateWithString(requirement as CFString, [], &compiled))
        }
        let flags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSRestrictSymlinks | kSecCSRestrictSidebandData)
        try check(SecStaticCodeCheckValidity(code, flags, compiled))
    }

    /// The code directory hash, the identity `codesign` prints as CDHash.
    public func cdhash() throws -> Data {
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(code, [], &information))
        guard
            let cdhash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else {
            throw CodeSignatureError(status: errSecCSUnsigned)
        }
        return cdhash
    }
}

public struct CodeSignatureError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return message ?? "code signature error \(status)"
    }
}

private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw CodeSignatureError(status: status) }
}
