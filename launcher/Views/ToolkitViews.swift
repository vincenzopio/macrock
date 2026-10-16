import AppKit
import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

/// Apple's license for the Game Porting Toolkit, shown before D3DMetal is copied.
struct ToolkitLicenseSheet: View {
    @Environment(AppModel.self) private var model
    let license: ToolkitImage.License

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PixelText("Game Porting Toolkit license", size: 20)
            Text(
                "macrock copies D3DMetal \(license.version) from Apple's Game Porting Toolkit as it is. Apple's license covers that copy: accept it to go on."
            )
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            RichText(rtf: license.rtf)
                .frame(height: 360)
                .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 2))
            HStack(spacing: 10) {
                Spacer()
                Button("Decline") { model.decideToolkitLicense(accepted: false) }
                    .buttonStyle(.pixel())
                    .fixedSize()
                Button("Accept") { model.decideToolkitLicense(accepted: true) }
                    .buttonStyle(.pixel(.primary))
                    .fixedSize()
            }
        }
        .padding(24)
        .frame(width: 680)
        .presentationBackground(Palette.panel)
    }
}

/// Rich text as AppKit lays it out, in a light page whatever the window's appearance: Apple's
/// license is RTF written for one.
private struct RichText: NSViewRepresentable {
    let rtf: Data

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.appearance = NSAppearance(named: .aqua)
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.textStorage?.setAttributedString(
                NSAttributedString(rtf: rtf, documentAttributes: nil) ?? NSAttributedString())
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}

extension NSOpenPanel {
    /// Asks for the Game Porting Toolkit disk image, which Apple's developer downloads put in
    /// the Downloads folder.
    static func chooseToolkitImage() -> URL? {
        let panel = NSOpenPanel()
        panel.message = String(
            localized: "Choose the Game Porting Toolkit 4 disk image you downloaded from Apple.")
        panel.allowedContentTypes = [.diskImage]
        panel.directoryURL = .downloadsDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }
}
