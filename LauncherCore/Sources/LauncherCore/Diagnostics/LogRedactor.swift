/// Removes Microsoft and Xbox credentials, and identifiers of the user, from log lines.
public struct LogRedactor {
    private static let mask = "<redacted>"

    /// The channel and function of a Wine debug line name Wine's code, never data.
    private let wineDebugHeader = #/^(?:[0-9a-f]{4}:){1,2}(?:fixme|err|warn|trace):[\w-]+:\S*/#

    /// The first capture is kept, the rest of the match is masked.
    private let labeledValues: [Regex<(Substring, Substring)>] = [
        #/(?i)((?:authorization|cookie|set-cookie)\s*[:=]\s*).+/#,
        #/(XBL3\.0 x=)[^\s"',]+/#,
        #/(<(?:\w+:)?(?:BinarySecret|BinarySecurityToken|CipherValue)\b[^>]*>)[^<]+/#,
        #/(?i)(\bpuid["']?\s*[:=]\s*["']?)[0-9a-f]{16}/#,
        #/(Users[\\/])\d{6,}/#,
    ]

    /// JWTs, MSA tickets and XUIDs. Wine prints pointers as 16 zero-padded hex digits, which can
    /// all be decimal; an XUID never starts with 0.
    private let secrets: [Regex<Substring>] = [
        #/\beyJ[\w-]+(?:\.[\w-]*){1,2}/#,
        #/\bEw[A-Za-z0-9+\/=%_-]{20,}/#,
        #/\b[1-9]\d{15}\b/#,
    ]

    private let emailAddress = #/[\w.%+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}/#

    /// Long base64 runs are taken for tokens when a stretch of them between slashes mixes upper
    /// case, lower case and digits: hex digests, Wine's addresses and the segments of paths such
    /// as the user's temporary directory do not.
    private let opaqueRun = #/[A-Za-z0-9+\/_-]{40,}={0,2}/#

    private let knownValues: [String]

    /// - Parameter knownValues: text to mask wherever it appears, such as an account's gamertag.
    public init(knownValues: [String] = []) {
        self.knownValues = knownValues.filter { !$0.isEmpty }
    }

    public func redact(_ line: some StringProtocol) -> String {
        let line = String(line)
        guard let header = line.prefixMatch(of: wineDebugHeader) else {
            return masked(line)
        }
        return header.output + masked(String(line[header.range.upperBound...]))
    }

    private func masked(_ text: String) -> String {
        var text = text
        for pattern in labeledValues {
            text.replace(pattern) { $0.output.1 + Self.mask }
        }
        for pattern in secrets {
            text.replace(pattern, with: Self.mask)
        }
        if text.contains("@") {
            text.replace(emailAddress, with: Self.mask)
        }
        text.replace(opaqueRun) { match in
            let looksRandom = match.output.split(separator: "/").contains { stretch in
                stretch.count >= 16 && stretch.contains(where: \.isUppercase)
                    && stretch.contains(where: \.isLowercase) && stretch.contains(where: \.isNumber)
            }
            return looksRandom ? Substring(Self.mask) : match.output
        }
        for value in knownValues {
            text.replace(value, with: Self.mask)
        }
        return text
    }
}
