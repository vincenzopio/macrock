import SwiftUI

/// A raised or sunken block face: an outline with clipped corners, a light edge at the top and
/// left, a dark one at the bottom and right.
struct Bevel: View {
    var fill: Color
    var light: Color
    var dark: Color
    var outline: Color? = Palette.ink

    var body: some View {
        Canvas { context, size in
            var face = CGRect(origin: .zero, size: size)
            if let outline {
                context.fill(Path(face.insetBy(dx: 2, dy: 0)), with: .color(outline))
                context.fill(Path(face.insetBy(dx: 0, dy: 2)), with: .color(outline))
                face = face.insetBy(dx: 2, dy: 2)
            }
            context.fill(Path(face), with: .color(dark))
            context.fill(
                Path(
                    CGRect(
                        x: face.minX, y: face.minY, width: face.width - 2, height: face.height - 2)),
                with: .color(light))
            context.fill(Path(face.insetBy(dx: 2, dy: 2)), with: .color(fill))
        }
    }
}

extension View {
    /// A sunken slot, like those of the inventory.
    func slot() -> some View {
        background(
            Bevel(
                fill: Palette.slot, light: Color(hex: 0x0B0B0C), dark: Color(hex: 0x3A3B3C),
                outline: nil))
    }
}
