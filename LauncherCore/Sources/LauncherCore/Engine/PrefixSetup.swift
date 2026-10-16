import Foundation

/// What a Wine prefix needs from the engine's runtime (engine `docs/runtime.md`, Prefix setup):
/// `share/macrock-engine/prefix/setup.json`, schema 1.
public struct PrefixSetup: Decodable, Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public let id: String
        public let action: Action
    }

    /// Paths of runtime files are relative to the runtime; `to` is relative to the prefix.
    public enum Action: Sendable, Equatable {
        case copy(String, to: String)
        case registry(String)

        /// The runtime file whose SHA-256 tells whether a prefix has this step.
        public var source: String {
            switch self {
            case .copy(let source, _), .registry(let source): source
            }
        }
    }

    public let revision: Int
    public let dllOverrides: String
    /// A drive letter and a colon, such as `g:`: the drive that maps to the game folder.
    public let gameDrive: String
    public let steps: [Step]

    public init(contentsOf file: URL) throws {
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        let schema = try decoder.decode(Schema.self, from: data).schema
        guard schema == 1 else {
            throw EngineError.unsupportedSchema(file.lastPathComponent, schema)
        }
        self = try decoder.decode(PrefixSetup.self, from: data)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int.self, forKey: .revision)
        dllOverrides = try container.decode(String.self, forKey: .dllOverrides)
        gameDrive = try container.decode(String.self, forKey: .gameDrive)
        guard gameDrive.wholeMatch(of: #/[a-z]:/#) != nil else {
            throw EngineError.invalidPrefixSetup("game drive \(gameDrive)")
        }
        steps = try container.decode([RawStep].self, forKey: .steps).map { try $0.step() }
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case dllOverrides = "dll_overrides"
        case gameDrive = "game_drive"
        case steps
    }

    private struct RawStep: Decodable {
        let id: String
        let copy: String?
        let to: String?
        let reg: String?

        func step() throws -> Step {
            let action: Action
            switch (copy, to, reg) {
            case (let source?, let target?, nil):
                try requireRelative(source)
                try requireRelative(target)
                action = .copy(source, to: target)
            case (nil, nil, let source?):
                try requireRelative(source)
                action = .registry(source)
            default:
                throw EngineError.invalidPrefixSetup("step \(id) needs one action")
            }
            return Step(id: id, action: action)
        }

        private func requireRelative(_ path: String) throws {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw EngineError.invalidPrefixSetup("step \(id) path \(path)")
            }
        }
    }
}
