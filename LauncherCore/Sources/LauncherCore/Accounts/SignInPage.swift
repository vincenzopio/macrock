import Foundation

/// Microsoft's sign-in page, shown as Windows' sign-in host shows it (xodus-cli `webview.rs`).
/// The page talks to its host through `window.external.notify`, asks it for its context, and
/// leaves the sign-in's result in `ServerData` once `ppsecure/post.srf` has loaded. The app's web
/// view shows it with a data store that does not persist, and loads only what `allows(_:)` lets
/// through.
public struct SignInPage: Sendable, Equatable {
    /// The user agent of Windows' sign-in host.
    public static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; MSAppHost/3.0) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36 Edge/18.26100"

    /// The script message handler `bridgeScript` posts to; answer each message with `reply(to:)`.
    public static let bridgeHandler = "external"

    /// Injected before the page's own scripts. Answers reach the page as the host's callback
    /// argument: data, never script.
    public static let bridgeScript = """
        window.external = {
            notify: message => window.webkit.messageHandlers.\(bridgeHandler).postMessage(message)
                .then(reply => reply && window["CloudExperienceHost.Bridge.dispatchMessage"](reply))
        };
        """

    /// The body of a function that returns the JSON of the page's `ServerData`, or null.
    public static let resultScript = """
        return typeof ServerData === "object" ? JSON.stringify(ServerData) : null;
        """

    // swift-format-ignore: NeverForceUnwrap
    // A literal that parses: the first use would trap otherwise. `mkt` is the page's locale, not
    // the license's market, which is a region.
    private static let signInURL = URL(string: "https://login.live.com/ppsecure/InlineLogin.srf")!
        .appending(queryItems: [
            URLQueryItem(name: "id", value: "80604"), URLQueryItem(name: "scid", value: "3"),
            URLQueryItem(name: "mkt", value: "en-US"),
            URLQueryItem(name: "Platform", value: "Windows10"),
            URLQueryItem(name: "clientid", value: "000000004424da1f"),
            URLQueryItem(name: "hosted", value: "1"),
        ])

    private static let capabilities =
        #"{"PrivatePropertyBag":1,"PasswordlessConnect":1,"PreferAssociate":1,"ChromelessUI":0}"#

    private static let getContext = "CloudExperienceHost.getContext"

    public let request: URLRequest
    /// Whether this is the page an inline auth URL named: its result signs in as `inlineAuth`.
    public let isInlineAuth: Bool

    public init() {
        var request = URLRequest(url: Self.signInURL)
        let headers = [
            "cxh-capabilities": Self.capabilities,
            "cxh-correlationId": UUID().uuidString.lowercased(),
            "cxh-msaBinaryVersion": "55",
            "cxh-identityClientBinaryVersion": "3",
            "cxh-osVersionInfo":
                #"{"platformId":2,"majorVersion":10,"minorVersion":0,"buildNumber":26100}"#,
            "cxh-platform": "CloudExperienceHost.Platform.DESKTOP",
            "cxh-protocol": "TokenBroker",
            "cxh-source": "TokenBroker",
            "hostApp": "CloudExperienceHost",
        ]
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        self.request = request
        isInlineAuth = false
    }

    /// Windows loads an inline auth page without the host's headers.
    public init(inlineAuth url: URL) {
        request = URLRequest(url: url)
        isInlineAuth = true
    }

    /// Microsoft's sign-in is https throughout.
    public static func allows(_ url: URL) -> Bool {
        url.scheme == "https"
    }

    public static func holdsResult(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == "login.live.com"
            && url.path() == "/ppsecure/post.srf"
    }

    /// The host's callback, as JSON, for the page's `getContext` request; nil for any other
    /// message.
    public static func reply(to message: String) -> String? {
        guard let message = try? JSONDecoder().decode(Invoke.self, from: Data(message.utf8)),
            message.type == "invoke", message.value.name == getContext
        else { return nil }
        let callback = Callback(
            value: Callback.Value(
                name: getContext,
                args: ["CloudExperienceHost", "TokenBroker", "TokenBroker", capabilities],
                context: message.value.context))
        guard let json = try? JSONEncoder().encode(callback) else { return nil }
        return String(decoding: json, as: UTF8.self)
    }

    private struct Invoke: Decodable {
        struct Value: Decodable {
            let name: String
            let context: String
        }

        let type: String
        let value: Value
    }

    private struct Callback: Encodable {
        struct Value: Encodable {
            let name: String
            let args: [String]
            let context: String
        }

        var type = "callback"
        let value: Value
    }
}

/// What the sign-in page posted, including the account's sign-in token. It goes to the account
/// service only, and neither prints nor reflects.
public struct ServerData: Sendable {
    let json: String
}

extension ServerData {
    /// The fields xodus-service reads (`models/live.rs`, `DAProperty`).
    private static let fields = [
        "sDAToken", "sDASessionKey", "sDAStartTime", "sDAExpires", "sSTSInlineFlowToken",
        "sSigninName", "K",
    ]

    /// Keeps only the fields the service reads, since a frame holds at most 64 KB. Nil when the
    /// page holds no sign-in, as after a wrong password.
    public init?(page json: String) {
        guard
            let page = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        var fields: [String: String] = [:]
        for field in Self.fields {
            guard let value = page[field] as? String else { return nil }
            fields[field] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
        else { return nil }
        self.json = String(decoding: data, as: UTF8.self)
    }
}

extension ServerData: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ServerData" }
    public var debugDescription: String { "ServerData" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
