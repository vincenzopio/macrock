import LauncherCore
import SwiftUI

/// The landscape fills the page; the account menu is at the top right, the launch bar at the
/// bottom.
struct PlayView: View {
    @Environment(AppModel.self) private var model
    let showProfiles: @MainActor () -> Void
    let editProfile: @MainActor () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            // Clipping hides what the filled picture overflows, but not from clicks: it would
            // cover the sidebar.
            Color.clear
                .overlay { PixelImage(image: Artwork.landscape).aspectRatio(contentMode: .fill) }
                .clipped()
                .allowsHitTesting(false)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.4),
                    .init(color: .black.opacity(0.55), location: 0.65),
                    .init(color: .black.opacity(0.92), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            LaunchBar(
                state: model.playState, onPlay: { model.play() }, onStop: model.stop,
                onShowProfiles: showProfiles,
                picker: ProfilePicker(
                    changeable: model.playState.allowsChanges, showProfiles: showProfiles,
                    editProfile: editProfile)
            )
            .padding(28)
        }
        .overlay(alignment: .topTrailing) {
            AccountMenu()
                .padding(.top, 22)
                .padding(.trailing, 28)
        }
    }
}

/// What the player can do now: the state on the left; on the right what plays, and the button.
struct LaunchBar<Picker: View>: View {
    let state: PlayState
    let onPlay: @MainActor () -> Void
    let onStop: @MainActor () -> Void
    let onShowProfiles: @MainActor () -> Void
    let picker: Picker

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                PixelText(caption.title, size: 18)
                if let detail = caption.detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            Spacer(minLength: 12)
            picker
            if state == .blocked(.gameMissing) {
                Button("INSTALL", action: onShowProfiles)
                    .buttonStyle(.pixel(.primary, size: 22, minHeight: PickerLabel.height))
                    .frame(width: 180)
            } else if state == .running || state == .stopping {
                Button("STOP", action: onStop)
                    .buttonStyle(.pixel(.danger, size: 22, minHeight: PickerLabel.height))
                    .frame(width: 180)
                    .disabled(state == .stopping)
            } else {
                Button("PLAY", action: onPlay)
                    .buttonStyle(.pixel(.primary, size: 22, minHeight: PickerLabel.height))
                    .frame(width: 180)
                    .disabled(state != .ready)
            }
        }
    }

    private var caption: (title: LocalizedStringKey, detail: LocalizedStringKey?) {
        switch state {
        case .ready: ("Ready", nil)
        case .running: ("Playing", "Quit from the game, or stop it here.")
        case .stopping: ("Closing Minecraft…", nil)
        case .starting(.startingService): ("Starting the account service…", nil)
        case .starting(.checkingLicense): ("Checking the license…", nil)
        case .starting(.preparingPrefix):
            ("Preparing Windows…", "The first time takes about half a minute.")
        case .starting: ("Starting Minecraft…", nil)
        case .blocked(.earlierSessionRunning):
            ("The last session is still closing", "End it from the message above.")
        case .blocked(.anotherAccountPlaying):
            ("Another account is playing", "Switch to it in the account menu to stop its game.")
        case .blocked(.rosettaMissing):
            ("Rosetta is not installed", "Install it with softwareupdate --install-rosetta.")
        case .blocked(.installingEngine): ("Installing the engine…", nil)
        case .blocked(.engineMissing):
            ("The engine is not installed", "macrock installs it as soon as it can download it.")
        case .blocked(.graphicsMissing):
            ("D3DMetal is missing", "Import Game Porting Toolkit 4 in Settings.")
        case .blocked(.installingGame): ("Installing Minecraft…", "Follow it in Profiles.")
        case .blocked(.gameMissing): ("Minecraft is not installed", "Install it from Profiles.")
        case .blocked(.accountMissing):
            ("No account", "Add your Microsoft account from the menu at the top right.")
        case .blocked(.accountNotAllowed):
            ("Not in this build", "A debug build plays only the development account.")
        case .blocked(.signInNeeded):
            ("Sign-in needed", "Choose Sign In Again from the account menu at the top right.")
        }
    }
}

#Preview("Launch bar", traits: .fixedLayout(width: 760, height: 520)) {
    let states: [PlayState] = [
        .blocked(.engineMissing), .blocked(.gameMissing), .ready, .starting(.preparingPrefix),
        .running, .stopping,
    ]
    VStack(spacing: 28) {
        ForEach(states.indices, id: \.self) { index in
            LaunchBar(
                state: states[index], onPlay: {}, onStop: {}, onShowProfiles: {},
                picker: PickerLabel(
                    icon: Artwork.grassBlock, title: "Latest Release",
                    detail: "1.26.5203.0 · Metal 4", opensUp: true
                )
                .frame(width: 310))
        }
    }
    .padding(28)
    .background(Palette.background)
}
