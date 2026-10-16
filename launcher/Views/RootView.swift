import AppKit
import LauncherCore
import SwiftUI

enum Page: CaseIterable, Identifiable {
    case play, profiles, sessions, settings

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .play: "Play"
        case .profiles: "Profiles"
        case .sessions: "Sessions"
        case .settings: "Settings"
        }
    }
}

extension FocusedValues {
    /// The page the main window shows, for the menu bar's commands.
    @Entry var page: Binding<Page>?
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var page = Page.play
    /// What the Profiles page shows instead of the list.
    @State private var profileDetail: ProfileDetail?
    @State private var popups = Popups()
    @State private var dropTargeted = false
    @State private var bannersHeight: CGFloat = 0

    var body: some View {
        Group {
            if let failure = model.libraryFailure {
                UnreadableLibrary(error: failure)
            } else if !model.hasStarted {
                Color.clear
            } else if inFirstRun {
                FirstRunView()
            } else {
                HStack(spacing: 0) {
                    Sidebar(page: $page)
                    Rectangle().fill(Palette.ink).frame(width: 2)
                    Group {
                        switch page {
                        case .play:
                            PlayView {
                                page = .profiles
                            } editProfile: {
                                profileDetail = model.library.selectedProfile.map(
                                    ProfileDetail.settings)
                                page = .profiles
                            }
                        case .profiles: ProfilesView(detail: $profileDetail)
                        case .sessions: SessionsView()
                        case .settings: SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.bannersHeight, bannersHeight)
                }
                .focusedSceneValue(\.page, $page)
                .onChange(of: page) {
                    if page != .profiles { profileDetail = nil }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    model.open(urls, into: openContentsProduct)
                    return urls.contains { ContentFile($0) != nil }
                } isTargeted: {
                    dropTargeted = $0
                }
                .overlay {
                    if dropTargeted {
                        DropTarget(product: openContentsProduct)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if !inFirstRun {
                    if !model.leftovers.isEmpty {
                        LeftoversBanner()
                    }
                    EngineBanner()
                }
                if let notice = model.notice {
                    // A new notice is a new banner, with all of its time ahead.
                    NoticeBanner(notice: notice)
                        .id(notice.id)
                }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                bannersHeight = $0
            }
            .padding(.top, 84)
            .padding(.horizontal, 28)
            .padding(.leading, inFirstRun ? 0 : Sidebar.width)
        }
        .sheet(
            isPresented: Binding(
                get: { model.pendingToolkitLicense != nil },
                set: { if !$0 { model.decideToolkitLicense(accepted: false) } })
        ) {
            if let license = model.pendingToolkitLicense {
                ToolkitLicenseSheet(license: license)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.isSigningIn },
                set: { if !$0 { model.cancelSignIn() } })
        ) {
            SignInSheet()
        }
        .background(Palette.background)
        .ignoresSafeArea()
        .frame(minWidth: 920, minHeight: 600)
        .onChange(of: model.filesToPlace) {
            if !model.filesToPlace.isEmpty {
                popups.dialog = choiceOfGame(for: model.filesToPlace)
            }
        }
        .popups(popups)
        .task {
            await model.start()
            await model.watchForUpdates()
        }
    }

    /// Release last, so that Return chooses it.
    private func choiceOfGame(for files: [URL]) -> Dialog {
        let title =
            files.count == 1
            ? String(
                localized:
                    "Add “\(files[0].deletingPathExtension().lastPathComponent)” to which game?")
            : String(localized: "Add \(files.count) files to which game?")
        let account = model.selectedAccount?.label ?? ""
        return Dialog(
            title: title,
            message: String(
                localized:
                    "Worlds and packs go to \(account), and every profile of a game shares them."),
            answers: [
                .init(title: String(localized: "Cancel"), role: .cancel) { model.place(into: nil) }
            ]
                + model.playedProducts.reversed().map { product in
                    .init(title: product.title) { model.place(into: product) }
                })
    }

    /// The product of the Contents page on screen, which dropped files go to.
    private var openContentsProduct: GameProduct? {
        guard page == .profiles, case .contents(let id)? = profileDetail else { return nil }
        return model.library.profile(id)?.product
    }

    /// The wizard shows the engine's download itself, and no session can have run before it.
    private var inFirstRun: Bool {
        model.library.setupCompleted == nil
    }
}

private struct Sidebar: View {
    static let width: CGFloat = 196

    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PixelText(verbatim: "macrock", size: 22)
                .padding(.horizontal, 18)
                .padding(.top, 50)
                .padding(.bottom, 24)
            ForEach(Page.allCases) { item in
                NavigationItem(title: item.title, selected: item == page) { page = item }
            }
            Spacer()
            Activity()
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
    }
}

/// Where worlds and packs dropped on the window go.
private struct DropTarget: View {
    @Environment(AppModel.self) private var model
    let product: GameProduct?

    var body: some View {
        VStack(spacing: 10) {
            PixelText("Drop to add", size: 20)
            Text(verbatim: detail)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(24)
        .panel()
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
        .allowsHitTesting(false)
    }

    private var detail: String {
        guard let account = model.selectedAccount else {
            return String(localized: "Add an account first.")
        }
        guard let product else {
            return String(
                localized: "Worlds and packs go to \(account.label). Choose the game next.")
        }
        return String(localized: "Worlds and packs go to \(account.label) in \(product.title).")
    }
}

/// Shown instead of everything else while the library can't be read.
private struct UnreadableLibrary: View {
    @Environment(AppModel.self) private var model
    let error: any Error

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PixelText("macrock can't read its settings", size: 20)
            Text(verbatim: reason)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Until it can, macrock changes none of its files.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
            RevealButton("Show in Finder", url: model.directory.library)
        }
        .padding(24)
        .frame(width: 520, alignment: .leading)
        .panel()
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dirtBackground()
    }

    private var reason: String {
        switch error {
        case is LibraryError:
            String(
                localized: "A newer version of macrock saved them. Open macrock with that version.")
        default:
            error.localizedDescription
        }
    }
}

/// What the launcher is busy with, seen from every page: the game being installed, the sessions
/// starting, playing or closing.
private struct Activity: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let install = model.gameInstall, let profile = model.library.profile(install.profile)
            {
                VStack(alignment: .leading, spacing: 6) {
                    PixelText(verbatim: String(localized: "Installing"), size: 12)
                    Text(verbatim: model.name(of: profile))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                    ProgressBar(value: install.progress?.fraction ?? 0)
                }
            }
            ForEach(model.library.accounts) { account in
                if let session = model.sessions[account.id],
                    let profile = model.library.profile(session.profile)
                {
                    VStack(alignment: .leading, spacing: 6) {
                        PixelText(verbatim: title(of: session), size: 12, color: Palette.positive)
                        Text(verbatim: "\(model.name(of: profile))\n\(account.label)")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(of session: RunningSession) -> String {
        switch session.phase {
        case .running:
            session.editor ? String(localized: "In Editor") : String(localized: "Playing")
        case .stopping: String(localized: "Closing")
        case .startingService, .checkingLicense, .preparingPrefix, .launching:
            String(localized: "Starting")
        }
    }
}

private struct NavigationItem: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            PixelText(title, size: 14, color: selected ? Palette.text : Palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(selected ? 0.08 : (hovered ? 0.04 : 0)))
                .overlay(alignment: .leading) {
                    if selected { Rectangle().fill(Palette.positive).frame(width: 3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.horizontal, 10)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
