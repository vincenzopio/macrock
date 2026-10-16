import SwiftUI

/// One thing macrock has: its icon, what it is and how it is, and what can be done about it.
/// The actions sit on the right with the main one last, or under the text when beside it they
/// would squeeze it into a narrow column.
struct Card<Actions: View>: View {
    let icon: CGImage
    let title: String
    let status: String
    var warning: String?
    var progress: Double?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    label.frame(minWidth: 280, idealWidth: 280, alignment: .leading)
                    Spacer(minLength: 12)
                    buttons
                }
                VStack(alignment: .trailing, spacing: 12) {
                    label.frame(maxWidth: .infinity, alignment: .leading)
                    buttons
                }
            }
            if let progress {
                ProgressBar(value: progress)
            }
        }
        .panel()
    }

    private var label: some View {
        HStack(spacing: 14) {
            PixelImage(image: icon)
                .frame(width: 32, height: 32)
                .padding(6)
                .slot()
            VStack(alignment: .leading, spacing: 4) {
                PixelText(verbatim: title, size: 14)
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning {
                    Text(warning)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.warning)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) { actions }
    }
}

/// A button that shows a pixel icon instead of its title, which it tells on hover.
struct IconButton: View {
    let title: LocalizedStringKey
    let icon: CGImage
    let action: @MainActor () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            PixelImage(image: icon)
                .frame(width: 18, height: 18)
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.pixel())
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }
}
