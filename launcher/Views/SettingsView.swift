import AppKit
import LauncherCore
import SwiftUI

/// What macrock runs every profile on: the engine and Apple's graphics.
struct SettingsView: View {
    var body: some View {
        PageScroll {
            PixelText("Settings", size: 26)
        } content: {
            Text("What macrock runs every profile on.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
            EngineCard()
            GraphicsCard()
        }
    }
}

private struct EngineCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(
            icon: Artwork.disc, title: title, status: status, warning: releasesFolder,
            progress: model.engineInstall?.downloaded
        ) {
            MoreMenu {
                PixelMenuItem(model.installedEngine == nil ? "Install" : "Reinstall") {
                    model.reinstallEngine()
                }
                if let previous = model.previousEngine {
                    PixelMenuItem("Go Back to \(previous.version)") { model.revertEngine() }
                }
            }
            .disabled(!model.canChangeEngine)
            Button("Check Now") { model.checkForEngineUpdateNow() }
                .buttonStyle(.pixel())
                .fixedSize()
                .disabled(model.engineInstall != nil)
            if case .available(let release) = model.engineUpdate {
                Button("Update to \(release.index.version)") { model.installEngineUpdate() }
                    .buttonStyle(.pixel(.primary))
                    .fixedSize()
                    .disabled(!model.canChangeEngine)
            }
        }
    }

    private var title: String {
        model.installedEngine.map { String(localized: "Engine \($0.version)") }
            ?? String(localized: "No engine installed")
    }

    private var status: String {
        if let install = model.engineInstall {
            return String(localized: "Installing engine \(install.version)…")
        }
        switch model.lastEngineCheck {
        case nil:
            return String(localized: "Looking for a newer engine…")
        case .failure?:
            return String(localized: "The engine releases couldn't be reached.")
        case .success(let date)?:
            switch model.engineUpdate {
            case .available(let release)?:
                return String(localized: "Engine \(release.index.version) is available.")
            case .unsupported(let release, let reason)?:
                return String(localized: "Engine \(release.index.version) is out.") + " "
                    + Notice(error: reason).message
            case nil:
                return String(
                    localized:
                        "Up to date. Checked \(date.formatted(.relative(presentation: .named))).")
            }
        }
    }

    private var releasesFolder: String? {
        #if DEBUG
            if model.engineReleases != .github {
                return String(localized: "Releases from \(model.engineReleases.url.path)")
            }
        #endif
        return nil
    }
}

private struct GraphicsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(icon: Artwork.chest, title: title, status: status) {
            Button("Import…") {
                if let image = NSOpenPanel.chooseToolkitImage() {
                    model.importToolkit(from: image)
                }
            }
            .buttonStyle(.pixel(model.graphicsVersion == nil ? .primary : .secondary))
            .fixedSize()
            .disabled(!model.canImportGraphics)
        }
    }

    private var title: String {
        model.graphicsVersion.map { String(localized: "D3DMetal \($0)") }
            ?? String(localized: "No D3DMetal imported")
    }

    private var status: String {
        switch model.graphicsImport {
        case .importing?: String(localized: "Importing D3DMetal…")
        case .awaitingLicense?: String(localized: "Waiting for Apple's license.")
        case nil:
            String(localized: "From Apple's Game Porting Toolkit, copied as Apple made it.")
        }
    }
}

private struct MoreMenu<Items: View>: View {
    @ViewBuilder let items: Items

    var body: some View {
        PixelMenu(width: 220) {
            Text(verbatim: "…")
        } items: {
            items
        }
        .buttonStyle(.pixel())
        .fixedSize()
        .accessibilityLabel("More")
    }
}

/// ⌘, opens the Settings page, as Settings… does in every Mac app.
struct SettingsCommand: View {
    @FocusedBinding(\.page) private var page

    var body: some View {
        Button("Settings…") { page = .settings }
            .keyboardShortcut(",")
            .disabled(page == nil)
    }
}
