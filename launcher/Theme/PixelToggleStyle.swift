import SwiftUI

/// Bedrock's switch, after the label: a sunken track, green when on, and a light knob on the side
/// it is on. The whole row switches it.
struct PixelToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 16) {
                configuration.label
                Spacer(minLength: 12)
                Switch(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct Switch: View {
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Bevel(
                    fill: isOn ? Palette.green : Palette.slot,
                    light: Color(hex: isOn ? 0x2A6A1B : 0x0B0B0C),
                    dark: Color(hex: isOn ? 0x4E9C35 : 0x3A3B3C)
                )
                .overlay(alignment: isOn ? .leading : .trailing) {
                    Group {
                        if isOn {
                            Rectangle().fill(Palette.text).frame(width: 2, height: 10)
                        } else {
                            Rectangle().strokeBorder(Palette.disabledText, lineWidth: 2)
                                .frame(width: 10, height: 10)
                        }
                    }
                    .frame(width: 26)
                }
                Bevel(fill: Color(hex: 0xD0D1D4), light: .white, dark: Color(hex: 0x8C8D90))
                    .frame(width: 26)
            }
            .frame(width: 52, height: 26)
            .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

extension ToggleStyle where Self == PixelToggleStyle {
    static var pixel: PixelToggleStyle { PixelToggleStyle() }
}
