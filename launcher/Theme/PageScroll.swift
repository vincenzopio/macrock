import SwiftUI

extension EnvironmentValues {
    /// The height of the banners over the main window's pages, which pages that list things leave
    /// room for.
    @Entry var bannersHeight: CGFloat = 0
}

/// A page of the main window that lists things: a column that scrolls, on dirt. The banners float
/// below the header, so the content starts below them.
struct PageScroll<Header: View, Content: View>: View {
    @Environment(\.bannersHeight) private var bannersHeight
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header.padding(.bottom, bannersHeight)
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 50)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dirtBackground()
    }
}
