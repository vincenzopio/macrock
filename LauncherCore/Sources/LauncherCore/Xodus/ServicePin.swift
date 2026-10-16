import Foundation

/// The account service in the app, written by `scripts/vendor-engine.sh` and covered by the app's
/// signature, so it anchors the trust in the service's own: the code directory hash the service
/// must have, and the protocol the runtime must speak with it.
public struct ServicePin: Decodable, Sendable, Equatable {
    public let cdhash: Data
    /// The `service_protocol` of the release the service came from.
    public let serviceProtocol: Int

    public init(contentsOf file: URL) throws {
        self = try JSONDecoder().decode(ServicePin.self, from: Data(contentsOf: file))
    }

    init(cdhash: Data, serviceProtocol: Int) {
        self.cdhash = cdhash
        self.serviceProtocol = serviceProtocol
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cdhash = try container.decodeHexadecimal(forKey: .cdhash)
        serviceProtocol = try container.decode(Int.self, forKey: .serviceProtocol)
    }

    private enum CodingKeys: String, CodingKey {
        case cdhash, serviceProtocol
    }
}
