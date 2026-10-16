import AppKit
import LauncherCore
import SwiftUI

/// Every session that left a folder, newest first, with how it ended and its logs.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [PastSession] = []
    @State private var unreadable = false

    var body: some View {
        PageScroll {
            PixelText("Sessions", size: 26)
        } content: {
            if unreadable {
                Text("The sessions folder can't be read.")
                    .foregroundStyle(Palette.negative)
            } else if sessions.isEmpty {
                Text("No session yet.")
                    .foregroundStyle(Palette.secondaryText)
            }
            ForEach(sessions) { session in
                SessionRow(session: session)
            }
        }
        .task(id: Set(model.sessions.keys)) { load() }
    }

    private func load() {
        do {
            sessions = try model.directory.pastSessions()
            unreadable = false
        } catch {
            unreadable = true
        }
    }
}

private struct SessionRow: View {
    let session: PastSession

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                PixelText(
                    verbatim: session.started.formatted(date: .abbreviated, time: .shortened),
                    size: 14)
                Text(ending.text)
                    .font(.system(size: 13))
                    .foregroundStyle(ending.colour)
            }
            Spacer()
            RevealButton("Show Logs", url: session.folder)
        }
        .panel()
    }

    private var ending: (text: LocalizedStringKey, colour: Color) {
        switch session.ending {
        case .quit: ("Quit", Palette.secondaryText)
        case .stopped: ("Stopped", Palette.secondaryText)
        case .forced: ("Ended: it did not close when asked", Palette.warning)
        case .crashed: ("Quit unexpectedly", Palette.negative)
        case .failed: ("Did not start", Palette.negative)
        case nil: ("Running, or the launcher quit before it ended", Palette.warning)
        }
    }
}
