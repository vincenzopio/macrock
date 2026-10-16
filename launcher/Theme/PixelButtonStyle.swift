import SwiftUI

/// Bedrock's button: a flat face with a light top edge on a darker base that shows its depth,
/// and an outline. Pressed, the face sinks onto the base.
struct PixelButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary, danger

        fileprivate var face: (normal: Color, hover: Color, top: Color, base: Color) {
            switch self {
            case .primary:
                (
                    Color(hex: 0x3C8527), Color(hex: 0x4A9C31), Color(hex: 0x62B842),
                    Color(hex: 0x1D4D13)
                )
            case .secondary:
                (
                    Color(hex: 0x48494A), Color(hex: 0x58595A), Color(hex: 0x646566),
                    Color(hex: 0x262728)
                )
            case .danger:
                (
                    Color(hex: 0xA83232), Color(hex: 0xBD3B3B), Color(hex: 0xD15656),
                    Color(hex: 0x5C1414)
                )
            }
        }
    }

    var kind = Kind.secondary
    var size: CGFloat = 13
    var minHeight: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind, size: size, minHeight: minHeight)
    }

    private struct Face: View {
        let configuration: Configuration
        let kind: Kind
        let size: CGFloat
        let minHeight: CGFloat?
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let colours = kind.face
            let depth: CGFloat = size >= 20 ? 6 : 4
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .font(.pixel(size))
                .foregroundStyle(isEnabled ? Palette.text : Palette.disabledText)
                .pixelShadow(isEnabled)
                .lineLimit(1)
                .padding(.horizontal, size * 1.3)
                .padding(.vertical, size * 0.62)
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .background(
                    isEnabled ? (hovered ? colours.hover : colours.normal) : Color(hex: 0x38393A),
                    ignoresSafeAreaEdges: []
                )
                .overlay(alignment: .top) {
                    Rectangle().fill(isEnabled ? colours.top : Color(hex: 0x404142)).frame(
                        height: 2)
                }
                .padding(.bottom, pressed ? 1 : depth)
                .background(
                    isEnabled ? colours.base : Color(hex: 0x262728), ignoresSafeAreaEdges: []
                )
                .padding(2)
                .background(Bevel(fill: Palette.ink, light: Palette.ink, dark: Palette.ink))
                .padding(.top, pressed ? depth - 1 : 0)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

extension ButtonStyle where Self == PixelButtonStyle {
    static func pixel(
        _ kind: PixelButtonStyle.Kind = .secondary, size: CGFloat = 13, minHeight: CGFloat? = nil
    ) -> PixelButtonStyle {
        PixelButtonStyle(kind: kind, size: size, minHeight: minHeight)
    }
}
