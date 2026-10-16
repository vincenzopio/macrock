import SwiftUI

extension View {
    func panel() -> some View {
        padding(12)
            .frame(maxWidth: 720, alignment: .leading)
            .panelBackground()
    }

    /// A panel's fill and border, for content that lays itself out.
    func panelBackground(opacity: Double = 0.92) -> some View {
        background(Palette.panel.opacity(opacity), ignoresSafeAreaEdges: [])
            .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 2))
    }
}

struct PanelSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PixelText(title, size: 14)
            content.toggleStyle(.pixel)
        }
        .panel()
    }
}

struct RowLabel: View {
    let title: Text
    let detail: Text

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey) {
        self.title = Text(title)
        self.detail = Text(detail)
    }

    init(verbatim title: String, detail: String) {
        self.title = Text(verbatim: title)
        self.detail = Text(verbatim: detail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            detail
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
