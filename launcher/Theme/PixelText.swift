import SwiftUI

extension Font {
    /// Monocraft follows the pixel grid at its own sizes, so it does not scale with the system.
    static func pixel(_ size: CGFloat) -> Font {
        .custom("Monocraft", fixedSize: size)
    }
}

extension View {
    /// The hard, one-pixel shadow under Minecraft's text.
    func pixelShadow(_ visible: Bool = true) -> some View {
        shadow(color: .black.opacity(visible ? 0.65 : 0), radius: 0, x: 2, y: 2)
    }
}

struct PixelText: View {
    let text: Text
    var size: CGFloat = 14
    var color = Palette.text

    init(_ key: LocalizedStringKey, size: CGFloat = 14, color: Color = Palette.text) {
        text = Text(key)
        self.size = size
        self.color = color
    }

    init(verbatim string: String, size: CGFloat = 14, color: Color = Palette.text) {
        text = Text(verbatim: string)
        self.size = size
        self.color = color
    }

    var body: some View {
        text.font(.pixel(size)).foregroundStyle(color).pixelShadow()
    }
}
