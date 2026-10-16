import LauncherCore
import SwiftUI

/// What the Profiles page shows instead of the list.
enum ProfileDetail: Equatable {
    case settings(Profile.ID)
    case contents(Profile.ID)

    var profile: Profile.ID {
        switch self {
        case .settings(let id), .contents(let id): id
        }
    }
}

/// What PLAY can play: each profile with its game and what can be done about it, or one
/// profile's settings or contents.
struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @Binding var detail: ProfileDetail?

    var body: some View {
        if let detail, let profile = model.library.profile(detail.profile) {
            PageScroll {
                Button {
                    self.detail = nil
                } label: {
                    HStack(spacing: 8) {
                        PixelImage(image: Artwork.arrowLeft).frame(width: 6, height: 10)
                        Text("Profiles")
                    }
                }
                .buttonStyle(.pixel())
                .fixedSize()
            } content: {
                switch detail {
                case .settings: ProfileEditor(profile: profile)
                case .contents: ContentsView(profile: profile)
                }
            }
        } else {
            PageScroll {
                HStack(alignment: .firstTextBaseline) {
                    PixelText("Profiles", size: 26)
                    Spacer()
                    Button("Check Now") { model.checkForGameUpdateNow() }
                        .buttonStyle(.pixel())
                        .fixedSize()
                        .disabled(!model.canInstallGame)
                        .help("Asks Microsoft for the latest version of Release and Preview")
                }
                .frame(maxWidth: 720)
            } content: {
                ForEach(model.library.profiles) { profile in
                    ProfileCard(profile: profile) { detail = $0 }
                }
            }
        }
    }
}

private struct ProfileCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Popups.self) private var popups
    let profile: Profile
    let show: @MainActor (ProfileDetail) -> Void

    var body: some View {
        let installation = model.installation(of: profile)
        let installing = model.gameInstall?.profile == profile.id
        Card(
            icon: Artwork.icon(for: profile), title: model.name(of: profile), status: status,
            progress: installing ? model.gameInstall?.progress?.fraction ?? 0 : nil
        ) {
            if installing {
                Button("Cancel") { model.cancelGameInstall() }
                    .buttonStyle(.pixel())
                    .fixedSize()
            } else {
                IconButton(title: "Contents", icon: Artwork.folder) {
                    show(.contents(profile.id))
                }
                IconButton(title: "Duplicate", icon: Artwork.copy) {
                    model.duplicate(profile.id)
                }
                IconButton(title: "Delete…", icon: Artwork.trash) { confirmDeletion() }
                    .disabled(!model.canDelete(profile))
                Button("Settings") { show(.settings(profile.id)) }
                    .buttonStyle(.pixel())
                    .fixedSize()
                if profile.kind == .latest {
                    if installation == nil {
                        InstallGameButton(profile: profile, title: "Install")
                    } else if let update = model.update(for: profile) {
                        InstallGameButton(
                            profile: profile, title: "Update to \(update.version)",
                            replacing: installation)
                    }
                }
            }
        }
    }

    /// Says what goes: the profile, with its game unless another profile plays it; or, for the
    /// last profile that follows its product's latest version, the game alone.
    private func confirmDeletion() {
        let name = model.name(of: profile)
        let title: String
        var message: [String] = []
        if model.library.canRemoveProfile(profile.id) {
            title = String(localized: "Delete \(name)?")
            if let deleted = model.installationDeleted(with: profile) {
                let size = deleted.size.formatted(.byteCount(style: .file))
                message.append(String(localized: "Its game goes with it, \(size) on disk."))
                if profile.kind == .kept {
                    message.append(String(localized: "This version can't be downloaded again."))
                }
            } else if model.installation(of: profile) != nil {
                message.append(
                    String(localized: "The game stays for the other profiles that play it."))
            }
        } else {
            let version = model.installation(of: profile)?.version ?? ""
            title = String(localized: "Delete Minecraft \(version)?")
            message.append(String(localized: "\(name) stays, to install the game again."))
        }
        message.append(String(localized: "Worlds, packs and settings stay with each account."))
        popups.dialog = Dialog(
            title: title, message: message.joined(separator: " "),
            answers: [
                .init(title: String(localized: "Cancel"), role: .cancel),
                .init(title: String(localized: "Delete"), role: .destructive) {
                    model.delete(profile.id)
                },
            ])
    }

    private var status: String {
        if let install = model.gameInstall, install.profile == profile.id {
            return install.progress?.summary
                ?? String(localized: "Asking Microsoft for the game…")
        }
        guard let installation = model.installation(of: profile) else {
            return served ?? String(localized: "Not installed.")
        }
        let size = installation.size.formatted(.byteCount(style: .file))
        switch profile.kind {
        case .kept:
            return String(
                localized:
                    "Kept at an update, \(size) on disk. The worlds are backed up before it plays, since an earlier version may not read what a later one wrote."
            )
        case .latest:
            let installed = String(
                localized:
                    "\(installation.version), installed \(installation.installed.formatted(date: .abbreviated, time: .omitted)), \(size) on disk."
            )
            return [installed, served].compactMap(\.self).joined(separator: " ")
        }
    }

    private var served: String? {
        guard model.readiness.signedIn == true else {
            return String(localized: "Sign in to install or update it.")
        }
        switch (model.served(profile.product), model.lastGameCheck) {
        case (.failure(let error)?, _):
            return Notice(error: error).title + "."
        case (.success(let served)?, .success(let date)?):
            if model.installation(of: profile) != nil, model.update(for: profile) == nil {
                return String(
                    localized:
                        "Up to date. Checked \(date.formatted(.relative(presentation: .named))).")
            }
            return String(
                localized:
                    "Version \(served.version) is available, a \(served.size.formatted(.byteCount(style: .file))) download."
            )
        default:
            return nil
        }
    }
}

/// The profile a page is about.
struct ProfileHeader: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

    var body: some View {
        HStack(spacing: 14) {
            PixelImage(image: Artwork.icon(for: profile))
                .frame(width: 32, height: 32)
                .padding(6)
                .slot()
            PixelText(verbatim: model.name(of: profile), size: 26)
        }
    }
}

/// A profile's name and how its game runs.
private struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

    var body: some View {
        ProfileHeader(profile: profile)
        Text("A change applies the next time Minecraft starts.")
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondaryText)
        PanelSection(title: "Profile") {
            HStack(spacing: 16) {
                RowLabel("Name", detail: "Shown beside PLAY and in Profiles.")
                Spacer(minLength: 12)
                TextField(
                    text: Binding {
                        profile.name ?? ""
                    } set: {
                        model.rename(profile.id, to: $0)
                    },
                    prompt: Text(verbatim: model.defaultName(of: profile))
                ) {
                    Text("Name")
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .slot()
                .frame(width: 260)
            }
        }
        PanelSection(title: "Graphics") {
            HStack(spacing: 16) {
                RowLabel(
                    "Backend",
                    detail:
                        "D3DMetal renders on Metal 4, the faster, or on Metal 3, for when Metal 4 draws something wrong."
                )
                Spacer(minLength: 12)
                BackendMenu(backend: setting(\.backend))
            }
            Toggle(isOn: setting(\.usesRetinaMode)) {
                RowLabel(
                    "Retina",
                    detail:
                        "Sharper, at the display's full resolution. The GPU draws four times the pixels: best on Pro, Max and Ultra chips."
                )
            }
            Toggle(isOn: setting(\.showsMetalHUD)) {
                RowLabel(
                    "Metal HUD",
                    detail: "Apple's overlay with the frame rate and the GPU's time, over the game."
                )
            }
            Text("The frame rate cap and V-Sync are in the game's own video settings.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
        }
        PanelSection(title: "Engine") {
            Toggle(isOn: setting(\.usesMsync)) {
                RowLabel(
                    "msync",
                    detail:
                        "Wine's synchronization on macOS's own primitives. Without it the game stutters more: turn it off only to tell whether it causes a problem."
                )
            }
            Toggle(isOn: setting(\.writesFPSLog)) {
                RowLabel(
                    "FPS log",
                    detail: "Writes the frame rate of every second to the session's logs.")
            }
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<Profile.Settings, Value>)
        -> Binding<Value>
    {
        Binding {
            profile.settings[keyPath: keyPath]
        } set: { value in
            var settings = profile.settings
            settings[keyPath: keyPath] = value
            model.setSettings(settings, of: profile.id)
        }
    }
}

private struct BackendMenu: View {
    @Binding var backend: MetalBackend

    var body: some View {
        PixelMenu(width: 150) {
            HStack(spacing: 10) {
                Text(verbatim: backend.title)
                Spacer(minLength: 4)
                PixelImage(image: Artwork.arrowDown).frame(width: 10, height: 6)
            }
        } items: {
            ForEach(MetalBackend.allCases, id: \.self) { choice in
                PixelMenuItem(checked: choice == backend) {
                    backend = choice
                } label: {
                    Text(verbatim: choice.title)
                }
            }
        }
        .buttonStyle(.pixel())
        .frame(width: 150)
    }
}
