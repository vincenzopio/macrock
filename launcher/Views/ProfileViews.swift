import LauncherCore
import SwiftUI

extension Artwork {
    static func icon(for profile: Profile) -> CGImage {
        switch (profile.kind, profile.product) {
        case (.kept, _): stone
        case (.latest, .release): grassBlock
        case (.latest, .preview): amethyst
        }
    }
}

/// The profiles as the items of a pixel menu, with the version each plays.
struct ProfileMenuItems: View {
    @Environment(AppModel.self) private var model
    let checked: Profile.ID?
    let choose: @MainActor (Profile.ID) -> Void

    var body: some View {
        PixelMenuSection(title: "Profiles")
        ForEach(model.library.profiles) { profile in
            PixelMenuItem(checked: profile.id == checked) {
                choose(profile.id)
            } label: {
                PixelImage(image: Artwork.icon(for: profile)).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.name(of: profile))
                    Text(verbatim: model.detail(of: profile))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }
}

/// The profile PLAY plays, with its version and graphics backend; its menu chooses the profile
/// and the backend, and leads to the rest of its settings.
struct ProfilePicker: View {
    @Environment(AppModel.self) private var model
    let changeable: Bool
    let showProfiles: @MainActor () -> Void
    let editProfile: @MainActor () -> Void

    var body: some View {
        PixelMenu(opensUp: true) {
            if let profile = model.selectedProfile {
                PickerLabel(
                    icon: Artwork.icon(for: profile), title: model.name(of: profile),
                    detail: "\(model.detail(of: profile)) · \(profile.settings.backend.title)",
                    opensUp: true)
            }
        } items: {
            ProfileMenuItems(checked: model.library.selectedProfile, choose: model.selectProfile)
            PixelMenuDivider()
            PixelMenuSection(title: "Graphics")
            ForEach(MetalBackend.allCases, id: \.self) { backend in
                PixelMenuItem(checked: model.selectedProfile?.settings.backend == backend) {
                    model.setBackend(backend)
                } label: {
                    Text(verbatim: backend.title)
                }
            }
            PixelMenuDivider()
            PixelMenuItem("Open in Editor") { model.play(inEditor: true) }
                .disabled(model.playState != .ready)
            PixelMenuItem("Profile Settings…", action: editProfile)
            PixelMenuItem("All Profiles", action: showProfiles)
        }
        .buttonStyle(.pixel(minHeight: PickerLabel.height))
        .frame(width: 310)
        .disabled(!changeable)
        .help("The profile PLAY plays, and the graphics backend D3DMetal renders it with")
    }
}

/// Installs the version of a profile's product Microsoft serves now. Before an update the
/// player may keep the version it replaces, which can't be downloaded again; before the first
/// install, they agree to packages macrock can't verify, which is asked once.
struct InstallGameButton: View {
    @Environment(AppModel.self) private var model
    @Environment(Popups.self) private var popups
    let profile: Profile
    let title: LocalizedStringKey
    var replacing: Installation?

    var body: some View {
        Button(title) {
            if model.library.packageConsent == nil {
                askConsent()
            } else if let replacing {
                askToKeep(replacing)
            } else {
                model.installGame(profile.id, keepingCopy: false)
            }
        }
        .buttonStyle(.pixel(.primary))
        .fixedSize()
        .disabled(!model.canInstallGame)
    }

    private func askConsent() {
        popups.dialog = Dialog(
            title: String(localized: "Install a package macrock can't verify?"),
            message: String(
                localized:
                    "Microsoft serves Minecraft over an unencrypted connection, and macrock can't check that the package comes from Microsoft. Every part of the download is checked against the package's own hashes, and the game's program against Microsoft's signature, so someone on your network could break the game, but not put code of their own in it. macrock asks this once."
            ),
            answers: [
                .init(title: String(localized: "Cancel"), role: .cancel),
                .init(title: String(localized: "Install")) {
                    model.consentToPackages()
                    model.installGame(profile.id, keepingCopy: false)
                },
            ])
    }

    private func askToKeep(_ replaced: Installation) {
        popups.dialog = Dialog(
            title: String(localized: "Update \(model.name(of: profile))?"),
            message: String(
                localized:
                    "Microsoft serves only the latest version, so \(replaced.version) can't be downloaded again once it's replaced. Keeping it adds a profile that plays it, and takes \(replaced.size.formatted(.byteCount(style: .file)))."
            ),
            answers: [
                .init(title: String(localized: "Cancel"), role: .cancel),
                .init(title: String(localized: "Update and Keep \(replaced.version)")) {
                    model.installGame(profile.id, keepingCopy: true)
                },
                .init(title: String(localized: "Update")) {
                    model.installGame(profile.id, keepingCopy: false)
                },
            ])
    }
}
