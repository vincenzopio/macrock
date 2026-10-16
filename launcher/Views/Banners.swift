import AppKit
import LauncherCore
import SwiftUI

/// Goes away by itself after a while in front of the player: the time runs only while the window
/// is active and the pointer is not over the notice.
struct NoticeBanner: View {
    private static let lifetime = Duration.seconds(10)

    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    @State private var hovered = false
    let notice: Notice

    var body: some View {
        Banner(
            title: notice.title, message: notice.message,
            colour: colour
        ) {
            switch notice.folder {
            case .logs(let folder):
                RevealButton("Show Logs", url: folder)
            case .backup(let folder):
                RevealButton("Show Backup", url: folder)
            case nil:
                EmptyView()
            }
            Button("Dismiss") { model.dismissNotice(notice.id) }
                .buttonStyle(.pixel())
                .fixedSize()
        }
        .onHover { hovered = $0 }
        .task(id: appearsActive && !hovered) {
            guard appearsActive, !hovered else { return }
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            model.dismissNotice(notice.id)
        }
    }

    private var colour: Color {
        switch notice.kind {
        case .information: Palette.positive
        case .warning: Palette.warning
        case .problem: Palette.negative
        }
    }
}

struct LeftoversBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Banner(
            title: String(localized: "Minecraft is still closing"),
            message: String(
                localized:
                    "Windows programs of an earlier session are still running. End them to play again."
            ),
            colour: Palette.warning
        ) {
            Button("End Them") { model.endLeftovers() }
                .buttonStyle(.pixel(.danger))
                .fixedSize()
        }
    }
}

/// The engine being installed, a newer one to install, or why there is none to play with.
struct EngineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let install = model.engineInstall {
            let downloading = install.downloaded < 1
            Banner(
                title: downloading
                    ? String(localized: "Downloading engine \(install.version)")
                    : String(localized: "Installing engine \(install.version)"),
                message: downloading
                    ? install.downloaded.formatted(.percent.precision(.fractionLength(0)))
                    : String(localized: "Unpacking it and checking every file."),
                colour: Palette.positive
            ) {
                ProgressBar(value: install.downloaded)
                    .frame(width: 200)
            }
        } else if let update = model.offeredEngineUpdate {
            switch update {
            case .available(let release):
                let version = release.index.version
                Banner(
                    title: model.installedEngine == nil
                        ? String(localized: "Engine \(version) is ready to install")
                        : String(localized: "Engine \(version) is available"),
                    message: model.installedEngine.map {
                        String(
                            localized: "Install it now, or go on playing with engine \($0.version)."
                        )
                    } ?? String(localized: "macrock needs it to play."),
                    colour: Palette.positive
                ) {
                    Button("Later") { model.postponeEngineUpdate() }
                        .buttonStyle(.pixel())
                        .fixedSize()
                    Button(model.installedEngine == nil ? "Install" : "Update") {
                        model.installEngineUpdate()
                    }
                    .buttonStyle(.pixel(.primary))
                    .fixedSize()
                    .disabled(!model.canChangeEngine)
                }
            case .unsupported(_, let reason):
                let notice = Notice(error: reason)
                Banner(title: notice.title, message: notice.message, colour: Palette.warning) {
                    Button("Dismiss") { model.postponeEngineUpdate() }
                        .buttonStyle(.pixel())
                        .fixedSize()
                }
            }
        } else if model.installedEngine == nil, case .failure? = model.lastEngineCheck {
            Banner(
                title: String(localized: "macrock couldn't download the engine"),
                message: String(
                    localized: "It needs the engine to play. Check the connection, then try again."),
                colour: Palette.negative
            ) {
                Button("Try Again") { model.checkForEngineUpdateNow() }
                    .buttonStyle(.pixel())
                    .fixedSize()
            }
        }
    }
}

/// A panel with a coloured edge, a title, a message and its buttons.
private struct Banner<Actions: View>: View {
    let title: String
    let message: String
    let colour: Color
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                PixelText(verbatim: title, size: 14)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.vertical, 12)
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .background(alignment: .leading) { Rectangle().fill(colour).frame(width: 4) }
        .panelBackground(opacity: 0.96)
        .frame(maxWidth: 720)
    }
}
