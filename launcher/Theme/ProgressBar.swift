import SwiftUI

/// Fills from the left, like the game's experience bar.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        Rectangle()
            .fill(Palette.ink.opacity(0.6))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle().fill(Palette.positive)
                        .frame(width: geometry.size.width * value)
                }
            }
            .frame(height: 12)
            .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 2))
            .animation(.linear(duration: 0.2), value: value)
    }
}
