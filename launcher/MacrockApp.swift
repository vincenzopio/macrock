import AppKit
import CoreText
import SwiftUI

@main
struct MacrockApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("macrock", id: "main") {
            RootView().environment(delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutCommand() }
            CommandGroup(replacing: .appSettings) { SettingsCommand() }
            #if DEBUG
                DeveloperCommands(model: delegate.model)
            #endif
        }
        Window("About macrock", id: "about") {
            AboutView().environment(delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let font = Bundle.main.url(forResource: "Monocraft", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting with a game running asks first, then closes every game and waits until nothing
    /// of their sessions is left.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.sessions.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit macrock?")
        alert.informativeText = String(localized: "Minecraft is running and will close.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await model.endSessions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
