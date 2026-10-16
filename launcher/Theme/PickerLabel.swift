import SwiftUI

/// The face of a menu that chooses something: its icon, what is chosen with a detail under it,
/// and an arrow towards the side the menu opens to.
struct PickerLabel: View {
    /// The height of PLAY's face, so that the two stand on one line.
    static let height: CGFloat = 58

    let icon: CGImage?
    let title: String
    let detail: String
    var detailColour = Palette.secondaryText
    let opensUp: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon {
                    PixelImage(image: icon)
                } else {
                    Rectangle().fill(Palette.slot)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .foregroundStyle(detailColour)
            }
            Spacer(minLength: 4)
            PixelImage(image: opensUp ? Artwork.arrowUp : Artwork.arrowDown)
                .frame(width: 10, height: 6)
        }
    }
}
