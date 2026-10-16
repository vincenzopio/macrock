import LauncherCore
import SwiftUI
import WebKit

/// Microsoft's sign-in pages, in a web view that acts as Windows' sign-in host.
/// One web page shows every page of a sign-in, so that the second has the first one's cookies;
/// its data store goes away with the sheet.
struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @State private var browser: SignInBrowser?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let browser {
                    WebView(browser.page)
                } else {
                    Palette.panel
                }
            }
            .overlay {
                if model.signInPage == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        PixelText("Waiting for the account service…", size: 13)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.panel)
                }
            }
            .frame(width: 480, height: 560)
            HStack(spacing: 10) {
                if browser?.didNotLoad == true, let page = model.signInPage {
                    Text("Microsoft's page didn't load. Check the network.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.warning)
                    Button("Try Again") { browser?.load(page) }
                        .buttonStyle(.pixel())
                        .fixedSize()
                }
                Spacer()
                Button("Cancel") { model.cancelSignIn() }
                    .buttonStyle(.pixel())
                    .fixedSize()
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.signInPage == nil)
            }
            .padding(14)
        }
        .background(Palette.panel)
        .interactiveDismissDisabled()
        .task(id: model.signInPage) {
            let browser = browser ?? SignInBrowser()
            self.browser = browser
            guard let page = model.signInPage else { return }
            if let serverData = await browser.serverData(from: page) {
                model.signInPagePosted(serverData)
            }
        }
    }
}

/// The web page the sheet shows, set up as Windows' sign-in host: its user agent, its
/// `window.external` bridge, a data store that is never written to disk, and https only.
@MainActor
@Observable
final class SignInBrowser {
    let page: WebPage
    /// The last page did not load, or its web content stopped.
    private(set) var didNotLoad = false
    @ObservationIgnored private let bridge = Bridge()

    init() {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        let content = WKUserContentController()
        content.addUserScript(
            WKUserScript(
                source: SignInPage.bridgeScript, injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        content.addScriptMessageHandler(
            bridge, contentWorld: .page, name: SignInPage.bridgeHandler)
        configuration.userContentController = content
        page = WebPage(configuration: configuration, navigationDecider: SecureNavigations())
        page.customUserAgent = SignInPage.userAgent
    }

    func load(_ signInPage: SignInPage) {
        didNotLoad = false
        page.load(signInPage.request)
    }

    /// Shows `signInPage` and returns what it posted once the user signed in on it; nil when the
    /// calling task is cancelled first.
    func serverData(from signInPage: SignInPage) async -> ServerData? {
        load(signInPage)
        while !Task.isCancelled {
            do {
                for try await event in page.navigations where event == .finished {
                    didNotLoad = false
                    guard let url = page.url, SignInPage.holdsResult(url),
                        let json = try await page.callJavaScript(SignInPage.resultScript)
                            as? String,
                        let serverData = ServerData(page: json)
                    else { continue }
                    return serverData
                }
                return nil
            } catch WebPage.NavigationError.failedProvisionalNavigation(let error)
                where (error as? URLError)?.code == .cancelled
            {
                continue
            } catch {
                didNotLoad = true
            }
        }
        return nil
    }
}

/// Answers what the page posts through `window.external.notify`, from its main frame only:
/// that is where the bridge is.
private final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame, let body = message.body as? String else {
            replyHandler(nil, nil)
            return
        }
        replyHandler(SignInPage.reply(to: body), nil)
    }
}

/// Lets the page go only where `SignInPage.allows(_:)` does.
private struct SecureNavigations: WebPage.NavigationDeciding {
    func decidePolicy(
        for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        action.request.url.map(SignInPage.allows) == true ? .allow : .cancel
    }
}
