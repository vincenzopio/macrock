import Foundation

/// A release's `index.json` (engine `packaging/macos/manifest.py index`), schema 2. Only the
/// fields the launcher uses are read.
public struct EngineIndex: Decodable, Sendable, Equatable {
    public struct Requirements: Decodable, Sendable, Equatable {
        /// The Game Porting Toolkit major version D3DMetal must come from.
        public let gptk: String
        public let macos: String
    }

    /// The runtime's archive, and the sealed bundle in it.
    public struct Archive: Decodable, Sendable, Equatable {
        public let file: String
        /// In bytes.
        public let size: Int64
        public let sha256: Data
        public let cdhash: Data
        /// The bundle's name at the top of the archive.
        public let path: String

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            file = try container.decodeFileName(forKey: .file)
            size = try container.decode(Int64.self, forKey: .size)
            sha256 = try container.decodeHexadecimal(forKey: .sha256)
            cdhash = try container.decodeHexadecimal(forKey: .cdhash)
            path = try container.decodeFileName(forKey: .path)
        }

        private enum CodingKeys: String, CodingKey {
            case file, size, sha256, cdhash, path
        }
    }

    public let version: String
    public let requires: Requirements
    /// The version of the IPC between the runtime's xgameruntime and xodus-service.
    public let serviceProtocol: Int
    public let bundle: Archive

    public init(contentsOf file: URL) throws {
        try self.init(json: Data(contentsOf: file))
    }

    public init(json: Data) throws {
        let decoder = JSONDecoder()
        let schema = try decoder.decode(Schema.self, from: json).schema
        guard schema == 2 else {
            throw EngineError.unsupportedSchema("index.json", schema)
        }
        self = try decoder.decode(EngineIndex.self, from: json)
    }

    private enum CodingKeys: String, CodingKey {
        case version, requires, bundle
        case serviceProtocol = "service_protocol"
    }
}

extension EngineIndex {
    /// Throws unless this Mac can run the release and its runtime speaks the protocol of the
    /// account service in the app.
    public func checkCompatibility(
        serviceProtocol: Int,
        macOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws(EngineError) {
        let running = "\(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion)"
        guard requires.macos.compare(running, options: .numeric) != .orderedDescending else {
            throw .needsMacOS(requires.macos)
        }
        guard self.serviceProtocol == serviceProtocol else {
            throw .serviceProtocolMismatch(engine: self.serviceProtocol, service: serviceProtocol)
        }
    }

    public func isNewer(than version: String) -> Bool {
        self.version.compare(version, options: .numeric) == .orderedDescending
    }
}

extension EngineIndex.Requirements {
    /// Throws unless D3DMetal of this version, such as `4.0b2`, comes from the Game Porting
    /// Toolkit the engine needs.
    func checkD3DMetal(version: String) throws {
        guard version.prefix(while: \.isNumber) == gptk else {
            throw SessionError.unsupportedD3DMetal(found: version, required: gptk)
        }
    }
}

struct Schema: Decodable {
    let schema: Int
}

extension KeyedDecodingContainer {
    /// A name the launcher joins to a URL or a folder, so it must not reach outside them.
    fileprivate func decodeFileName(forKey key: Key) throws -> String {
        let name = try decode(String.self, forKey: key)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "not a file name")
        }
        return name
    }
}
