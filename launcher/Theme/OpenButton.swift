import AppKit
import SwiftUI

/// Opens a file in the app macOS picks for it, or a folder in the Finder; disabled until it
/// exists.
struct OpenButton: View {
    let title: LocalizedStringKey
    let url: URL?

    init(_ title: LocalizedStringKey, url: URL?) {
        self.title = title
        self.url = url
    }

    var body: some View {
        let existing = url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        Button(title) {
            if let existing { NSWorkspace.shared.open(existing) }
        }
        .buttonStyle(.pixel())
        .fixedSize()
        .disabled(existing == nil)
    }
}

/// Shows a file or folder selected in a Finder window.
struct RevealButton: View {
    let title: LocalizedStringKey
    let url: URL

    init(_ title: LocalizedStringKey, url: URL) {
        self.title = title
        self.url = url
    }

    var body: some View {
        Button(title) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .buttonStyle(.pixel())
            .fixedSize()
    }
}
