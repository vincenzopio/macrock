import AppKit
import LauncherCore
import SwiftUI

/// Who made what macrock runs, and under which license.
struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 6) {
                    PixelText(verbatim: "macrock", size: 26)
                    Text("Version \(Self.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            Credit(
                title: "macrock",
                detail: String(localized: "Free software under the GNU GPL, version 3 or later.")
            ) {
                OpenButton(
                    "License", url: Bundle.main.url(forResource: "LICENSE", withExtension: nil))
            }
            PixelText("What it runs", size: 14, color: Palette.secondaryText)
                .padding(.top, 4)
            Credit(
                title: String(localized: "Account service"),
                detail: String(localized: "xodus-service, under the GNU GPL, version 3 only.")
            ) {
                OpenButton("License", url: Self.serviceFile("LICENSE"))
                OpenButton("Sources", url: Self.serviceFile("SOURCES.md"))
            }
            Credit(
                title: model.installedEngine.map { String(localized: "Engine \($0.version)") }
                    ?? String(localized: "Engine"),
                detail: String(
                    localized:
                        "Wine and xgameruntime under the GNU LGPL, version 2.1 or later, with the libraries they use."
                )
            ) {
                OpenButton("Licenses", url: model.engineDocumentation)
            }
            Credit(
                title: "Monocraft",
                detail: String(
                    localized:
                        "The pixel font, by Idrees Hassan, under the SIL Open Font License 1.1.")
            ) {
                OpenButton(
                    "License",
                    url: Bundle.main.url(forResource: "Monocraft-OFL", withExtension: "txt"))
            }
            Credit(
                title: model.graphicsVersion.map { String(localized: "D3DMetal \($0)") }
                    ?? String(localized: "D3DMetal"),
                detail: String(
                    localized:
                        "From Apple's Game Porting Toolkit, whose license allows its use “for the sole purpose of developing, testing, or evaluating video games for use on Apple-branded products”. Apple doesn't make or endorse macrock."
                )
            ) {
                OpenButton("License", url: model.graphicsLicense)
            }
            Text(
                "Minecraft is a trademark of Mojang Synergies AB. macrock isn't made or endorsed by Mojang or Microsoft."
            )
            .font(.system(size: 11))
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 600)
        .containerBackground(Palette.panel, for: .window)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static func serviceFile(_ name: String) -> URL? {
        Bundle.main.resourceURL?.appending(path: "Engine/Licenses/xodus-service/\(name)")
    }
}

/// One piece of software: what it is, its license, and the buttons that show them.
private struct Credit<Buttons: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                PixelText(verbatim: title, size: 13)
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            buttons
        }
    }
}

/// The app menu's About item, which opens macrock's own window instead of the standard panel.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About macrock") { openWindow(id: "about") }
    }
}

#Preview {
    AboutView().environment(AppModel())
}
