import Foundation
import JavaScriptCore
import Testing

@testable import LauncherCore

/// The page's scripts run in JavaScriptCore, as WebKit runs them, with a `window` that records
/// what reaches the host.
struct SignInPageTests {
    let capabilities =
        #"{"PrivatePropertyBag":1,"PasswordlessConnect":1,"PreferAssociate":1,"ChromelessUI":0}"#
    let signInFields = [
        "sDAToken": "token", "sDASessionKey": "key", "sDAStartTime": "2026-10-10T12:00:00Z",
        "sDAExpires": "2026-10-11T12:00:00Z", "sSTSInlineFlowToken": "flow",
        "sSigninName": "player@example.com", "K": "1234",
    ]

    @Test func asksEachPageWithANewCorrelationID() throws {
        let page = SignInPage()
        let correlation = try #require(page.request.value(forHTTPHeaderField: "cxh-correlationId"))

        #expect(UUID(uuidString: correlation) != nil)
        #expect(SignInPage().request.value(forHTTPHeaderField: "cxh-correlationId") != correlation)
        #expect(!page.isInlineAuth)
    }

    @Test func loadsTheInlineAuthPageWithoutTheHostsHeaders() throws {
        let url = try #require(
            URL(string: "https://login.live.com/ppsecure/InlineConnect.srf?id=1"))
        let page = SignInPage(inlineAuth: url)

        #expect(page.request.url == url)
        #expect(page.request.allHTTPHeaderFields?.isEmpty ?? true)
        #expect(page.isInlineAuth)
    }

    @Test func bridgesWindowExternalNotifyToTheMessageHandler() throws {
        let js = try bridgedPage()
        js.evaluateScript(#"window.external.notify('{"type":"event"}')"#)

        #expect(js.exception == nil)
        #expect(js.evaluateScript("posted[0]").toString() == #"{"type":"event"}"#)
        #expect(js.evaluateScript("dispatched.length").toInt32() == 0)
    }

    @Test func answersGetContextWithTheContextAsThePageSentIt() throws {
        let context = "a\"b\\c'</script>\n\u{2028}é"
        let message = try JSONSerialization.data(withJSONObject: [
            "type": "invoke",
            "value": ["name": "CloudExperienceHost.getContext", "args": [], "context": context],
        ])
        let js = try bridgedPage()

        js.objectForKeyedSubscript("window").objectForKeyedSubscript("external")
            .invokeMethod("notify", withArguments: [String(decoding: message, as: UTF8.self)])

        #expect(js.exception == nil)
        let dispatched = try #require(js.evaluateScript("dispatched[0]").toString())
        let callback = try #require(
            JSONSerialization.jsonObject(with: Data(dispatched.utf8)) as? [String: Any])
        let value = try #require(callback["value"] as? [String: Any])
        #expect(callback["type"] as? String == "callback")
        #expect(value["name"] as? String == "CloudExperienceHost.getContext")
        #expect(value["context"] as? String == context)
        #expect(
            value["args"] as? [String] == [
                "CloudExperienceHost", "TokenBroker", "TokenBroker", capabilities,
            ])
    }

    /// A page with the bridge, whose message handler records what the page posts and answers
    /// with `reply(to:)`, and whose host bridge records what it is sent.
    private func bridgedPage() throws -> JSContext {
        let js = try #require(JSContext())
        let reply: @convention(block) (String) -> Any = { SignInPage.reply(to: $0) ?? NSNull() }
        js.setObject(reply, forKeyedSubscript: "reply" as NSString)
        js.evaluateScript(
            """
            var posted = [];
            var dispatched = [];
            var window = {
                webkit: {messageHandlers: {\(SignInPage.bridgeHandler): {postMessage: message => {
                    posted.push(message);
                    return Promise.resolve(reply(message));
                }}}},
                "CloudExperienceHost.Bridge.dispatchMessage": message => dispatched.push(message)
            };
            """)
        js.evaluateScript(SignInPage.bridgeScript)
        return js
    }

    @Test(arguments: [
        #"{"type":"invoke","value":{"name":"CloudExperienceHost.getPreferredLanguage","context":"1"}}"#,
        #"{"type":"callback","value":{"name":"CloudExperienceHost.getContext","context":"1"}}"#,
        #"{"type":"invoke","value":{"name":"CloudExperienceHost.getContext"}}"#,
        "not JSON",
    ])
    func answersNothingElseThePagePosts(message: String) {
        #expect(SignInPage.reply(to: message) == nil)
    }

    @Test(arguments: [
        ("https://login.live.com/ppsecure/InlineLogin.srf", true),
        ("http://login.live.com/ppsecure/InlineLogin.srf", false),
        ("file:///etc/hosts", false),
        ("data:text/html,<p>", false),
        ("javascript:alert(1)", false),
    ])
    func loadsOnlyHTTPS(address: String, allowed: Bool) throws {
        #expect(SignInPage.allows(try #require(URL(string: address))) == allowed)
    }

    @Test(arguments: [
        ("https://login.live.com/ppsecure/post.srf?wa=wsignin1.0&id=80604", true),
        ("https://login.live.com/ppsecure/InlineLogin.srf?id=80604", false),
        ("http://login.live.com/ppsecure/post.srf", false),
        ("https://login.live.com.example.org/ppsecure/post.srf", false),
    ])
    func findsTheResultOnlyOnThePostPage(address: String, holdsResult: Bool) throws {
        #expect(SignInPage.holdsResult(try #require(URL(string: address))) == holdsResult)
    }

    @Test func keepsOnlyTheFieldsTheServiceReads() throws {
        var page: [String: Any] = signInFields
        page["urlPost"] = "https://login.live.com/ppsecure/post.srf"
        page["iMaxStackForKnockoutAsyncComponents"] = 10_000
        page["oStrings"] = ["sTitle": String(repeating: "x", count: 70_000)]
        let json = try JSONSerialization.data(withJSONObject: page)

        let serverData = try #require(ServerData(page: String(decoding: json, as: UTF8.self)))

        #expect(
            try JSONSerialization.jsonObject(with: Data(serverData.json.utf8)) as? [String: String]
                == signInFields)
    }

    @Test func aPageWithoutASignInHasNoServerData() throws {
        var withoutToken = signInFields
        withoutToken["sDAToken"] = nil
        var page: [String: Any] = signInFields
        page["K"] = 1234

        for json in [
            try JSONSerialization.data(withJSONObject: withoutToken),
            try JSONSerialization.data(withJSONObject: page), Data("null".utf8),
            Data("not JSON".utf8),
        ] {
            #expect(ServerData(page: String(decoding: json, as: UTF8.self)) == nil)
        }
    }

    @Test func serverDataNeitherPrintsNorReflects() {
        let serverData = ServerData(json: #"{"sDAToken":"EwA-secret"}"#)
        var dumped = ""
        dump(serverData, to: &dumped)
        for text in [String(describing: serverData), String(reflecting: serverData), dumped] {
            #expect(!text.contains("secret"))
        }
        #expect(Mirror(reflecting: serverData).children.isEmpty)
    }
}
