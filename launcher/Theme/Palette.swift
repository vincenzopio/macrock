import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// The colours of Bedrock's own interface, and of its chat for states.
enum Palette {
    static let ink = Color(hex: 0x0F0F10)
    static let background = Color(hex: 0x1E1E1F)
    static let sidebar = Color(hex: 0x161617)
    static let panel = Color(hex: 0x313233)
    static let slot = Color(hex: 0x1A1A1B)
    static let text = Color.white
    static let secondaryText = Color(hex: 0xB1B2B5)
    static let disabledText = Color(hex: 0x7D7E80)
    static let green = Color(hex: 0x3C8527)
    static let positive = Color(hex: 0x55FF55)
    static let warning = Color(hex: 0xFFAA00)
    static let negative = Color(hex: 0xFF5555)
}
