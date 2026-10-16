import SwiftUI

/// What floats over the window, drawn like the rest of it: the open menu and the question the
/// player is asked, one of each at most.
@Observable
final class Popups {
    fileprivate var openMenu: UUID?
    var dialog: Dialog?
}

/// A question to the player: a title, a message and its answers, the cancelling one first and
/// the default one last. Return never chooses an answer that deletes.
struct Dialog {
    struct Answer {
        let title: String
        var role: ButtonRole?
        var action: () -> Void = {}
    }

    let title: String
    let message: String
    let answers: [Answer]
}

/// A menu drawn like the window. The button shows `label`; the panel opens above or below it,
/// over the whole window, and closes on a choice, a click elsewhere or Escape.
struct PixelMenu<Label: View, Items: View>: View {
    @Environment(Popups.self) private var popups
    @State private var id = UUID()
    var opensUp = false
    /// The panel's width; the button's when nil.
    var width: CGFloat?
    @ViewBuilder let label: Label
    @ViewBuilder let items: Items

    var body: some View {
        Button {
            popups.openMenu = popups.openMenu == id ? nil : id
        } label: {
            label
        }
        .anchorPreference(key: OpenMenuKey.self, value: .bounds) { anchor in
            popups.openMenu == id
                ? OpenMenu(anchor: anchor, opensUp: opensUp, width: width, items: AnyView(items))
                : nil
        }
    }
}

/// A choice in a pixel menu: it closes the menu, then acts.
struct PixelMenuItem<Label: View>: View {
    @Environment(Popups.self) private var popups
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    var checked = false
    var role: ButtonRole?
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button {
            popups.openMenu = nil
            action()
        } label: {
            HStack(spacing: 10) {
                label
                Spacer(minLength: 0)
                if checked {
                    PixelImage(image: Artwork.check).frame(width: 12, height: 9)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(role == .destructive ? Palette.negative : Palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(hovered && isEnabled ? 0.08 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovered = $0 }
    }
}

extension PixelMenuItem where Label == Text {
    init(
        _ title: LocalizedStringKey, checked: Bool = false, role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.init(checked: checked, role: role, action: action) { Text(title) }
    }
}

struct PixelMenuSection: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.secondaryText)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

struct PixelMenuDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 4)
    }
}

extension View {
    /// Draws the open menu and the dialog over the window.
    func popups(_ popups: Popups) -> some View {
        overlayPreferenceValue(OpenMenuKey.self) { menu in
            if let menu {
                MenuLayer(menu: menu)
            }
        }
        .overlay {
            if let dialog = popups.dialog {
                DialogLayer(dialog: dialog)
            }
        }
        .environment(popups)
    }
}

private struct OpenMenu {
    let anchor: Anchor<CGRect>
    let opensUp: Bool
    let width: CGFloat?
    let items: AnyView
}

private struct OpenMenuKey: PreferenceKey {
    static var defaultValue: OpenMenu? { nil }

    static func reduce(value: inout OpenMenu?, nextValue: () -> OpenMenu?) {
        value = value ?? nextValue()
    }
}

private struct MenuLayer: View {
    @Environment(Popups.self) private var popups
    let menu: OpenMenu

    var body: some View {
        GeometryReader { window in
            let button = window[menu.anchor]
            let width = menu.width ?? button.width
            let x = min(max(button.minX, 8), window.size.width - width - 8)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .onTapGesture { popups.openMenu = nil }
                Button("Close") { popups.openMenu = nil }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                if menu.opensUp {
                    panel(width: width)
                        .frame(
                            width: window.size.width, height: max(button.minY - 6, 0),
                            alignment: .bottomLeading
                        )
                        .offset(x: x)
                } else {
                    panel(width: width).offset(x: x, y: button.maxY + 6)
                }
            }
        }
    }

    private func panel(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) { menu.items }
            .padding(6)
            .frame(width: width, alignment: .leading)
            .background(Color(hex: 0x252526))
            .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }
}

private struct DialogLayer: View {
    @Environment(Popups.self) private var popups
    let dialog: Dialog

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                PixelText(verbatim: dialog.title, size: 16)
                Text(verbatim: dialog.message)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer()
                    ForEach(dialog.answers.indices, id: \.self) { index in
                        let answer = dialog.answers[index]
                        self.answer(
                            answer,
                            isDefault: index == dialog.answers.count - 1
                                && answer.role != .destructive)
                    }
                }
                .padding(.top, 6)
            }
            .padding(20)
            .frame(width: 480)
            .background(Palette.panel)
            .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        }
    }

    private func answer(_ answer: Dialog.Answer, isDefault: Bool) -> some View {
        let kind: PixelButtonStyle.Kind =
            switch answer.role {
            case .destructive?: .danger
            case .cancel?: .secondary
            default: isDefault ? .primary : .secondary
            }
        return Button(answer.title) {
            popups.dialog = nil
            answer.action()
        }
        .buttonStyle(.pixel(kind))
        .fixedSize()
        .keyboardShortcut(
            answer.role == .cancel ? .cancelAction : isDefault ? .defaultAction : nil)
    }
}
