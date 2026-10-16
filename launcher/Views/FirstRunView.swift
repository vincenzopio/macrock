import AppKit
import LauncherCore
import SwiftUI

/// The first-run wizard. It shows until it is finished once; the engine downloads
/// meanwhile, and the game may still be installing when it is.
struct FirstRunView: View {
    enum Step: Int, CaseIterable {
        case mac, account, game, graphics

        var title: LocalizedStringKey {
            switch self {
            case .mac: "Mac"
            case .account: "Account"
            case .game: "Game"
            case .graphics: "Graphics"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var step = Step.mac

    var body: some View {
        VStack(spacing: 22) {
            PixelText("Welcome to macrock", size: 30)
            StepIndicator(current: step)
            Group {
                switch step {
                case .mac: MacStep()
                case .account: AccountStep()
                case .game: GameStep()
                case .graphics: GraphicsStep()
                }
            }
            .padding(22)
            .frame(width: 640, height: 270, alignment: .topLeading)
            .panelBackground(opacity: 0.96)
            EngineLine()
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .frame(width: 640, alignment: .leading)
                .panelBackground(opacity: 0.96)
            HStack {
                Button("Back") { move(by: -1) }
                    .buttonStyle(.pixel())
                    .fixedSize()
                    .disabled(step == Step.allCases.first)
                Spacer()
                if step == Step.allCases.last {
                    Button("Finish") { model.completeSetup() }
                        .buttonStyle(.pixel(.primary))
                        .fixedSize()
                        .disabled(!canContinue)
                } else {
                    Button("Continue") { move(by: 1) }
                        .buttonStyle(.pixel(.primary))
                        .fixedSize()
                        .disabled(!canContinue)
                }
            }
            .frame(width: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dirtBackground()
    }

    private var canContinue: Bool {
        switch step {
        case .mac: model.systemCheck?.rosettaInstalled == true
        case .account: model.readiness.signedIn == true
        case .game:
            model.library.latestProfile(of: .release).flatMap(model.installation(of:)) != nil
                || model.isInstallingGame
        case .graphics: model.graphicsVersion != nil && model.graphicsImport == nil
        }
    }

    private func move(by offset: Int) {
        if let next = Step(rawValue: step.rawValue + offset) {
            step = next
        }
    }
}

private struct StepIndicator: View {
    let current: FirstRunView.Step

    var body: some View {
        HStack(spacing: 18) {
            ForEach(FirstRunView.Step.allCases, id: \.self) { step in
                HStack(spacing: 8) {
                    PixelText(
                        verbatim: "\(step.rawValue + 1)", size: 12,
                        color: step.rawValue <= current.rawValue
                            ? Palette.ink : Palette.secondaryText
                    )
                    .frame(width: 24, height: 24)
                    .background(step.rawValue <= current.rawValue ? Palette.positive : Palette.slot)
                    .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 2))
                    PixelText(
                        step.title, size: 13,
                        color: step == current ? Palette.text : Palette.secondaryText)
                }
            }
        }
    }
}

private struct MacStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PixelText("This Mac", size: 17)
            if let check = model.systemCheck {
                CheckRow(
                    status: .good, title: String(localized: "macOS \(check.macOS)"),
                    detail: String(localized: "Metal 4 and D3DMetal 4 need macOS 27."))
                CheckRow(
                    status: .good, title: String(localized: "Apple silicon"),
                    detail: String(localized: "D3DMetal draws the game with the Mac's own GPU."))
                CheckRow(
                    status: check.rosettaInstalled ? .good : .bad,
                    title: String(localized: "Rosetta 2"),
                    detail: check.rosettaInstalled
                        ? String(
                            localized: "It runs the engine, which is built for Intel processors.")
                        : String(
                            localized:
                                "The engine is built for Intel processors and needs it. macOS asks for an administrator's password to install it."
                        )
                ) {
                    if !check.rosettaInstalled {
                        Button(model.installingRosetta ? "Installing…" : "Install") {
                            model.installRosetta()
                        }
                        .buttonStyle(.pixel(.primary))
                        .fixedSize()
                        .disabled(model.installingRosetta)
                    }
                }
                CheckRow(
                    status: check.hasRoom ? .good : .warning,
                    title: check.freeSpace.map {
                        String(localized: "\($0.formatted(.byteCount(style: .file))) free")
                    } ?? String(localized: "Free space unknown"),
                    detail: check.hasRoom
                        ? String(localized: "The engine, D3DMetal and the game take about 6 GB.")
                        : String(
                            localized:
                                "The engine, D3DMetal and the game take about 6 GB: make some room first."
                        ))
            }
        }
    }
}

private struct GraphicsStep: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PixelText("Apple's graphics", size: 17)
            switch model.graphicsImport {
            case .importing?:
                CheckRow(
                    status: .waiting, title: String(localized: "Importing D3DMetal…"),
                    detail: String(
                        localized:
                            "If macOS shows Apple's license, agree to it. Then every file is checked."
                    ))
            case .awaitingLicense?:
                CheckRow(
                    status: .waiting, title: String(localized: "Waiting for Apple's license"),
                    detail: String(localized: "Accept it to copy D3DMetal."))
            case nil:
                if let version = model.graphicsVersion {
                    CheckRow(
                        status: .good, title: String(localized: "D3DMetal \(version) imported"),
                        detail: String(
                            localized:
                                "Copied as Apple made it. The Library can import another later."))
                } else {
                    dropZone
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            PixelText("Drag the Game Porting Toolkit 4 disk image here", size: 13)
            Text(
                "It comes from Apple's developer downloads. macrock copies D3DMetal from it after you accept Apple's license."
            )
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Button("Choose…") {
                if let image = NSOpenPanel.chooseToolkitImage() {
                    model.importToolkit(from: image)
                }
            }
            .buttonStyle(.pixel())
            .fixedSize()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.slot.opacity(targeted ? 0.9 : 0.5))
        .overlay(
            Rectangle().strokeBorder(
                targeted ? Palette.positive : Palette.secondaryText,
                style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let image = urls.first(where: { $0.pathExtension == "dmg" }) else {
                return false
            }
            model.importToolkit(from: image)
            return true
        } isTargeted: {
            targeted = $0
        }
    }
}

private struct AccountStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PixelText("Your Microsoft account", size: 17)
            if let account = model.selectedAccount, model.readiness.signedIn == true {
                CheckRow(
                    status: .good, title: String(localized: "Signed in as \(account.label)"),
                    detail: String(localized: "The account menu adds other accounts later."))
            } else if model.isSigningIn {
                CheckRow(
                    status: .waiting, title: String(localized: "Signing in…"),
                    detail: String(localized: "Go on in Microsoft's sign-in window."))
            } else if let account = model.selectedAccount {
                CheckRow(
                    status: .warning,
                    title: String(localized: "\(account.label) needs to sign in again"),
                    detail: String(localized: "Microsoft no longer accepts its sign-in.")
                ) {
                    Button("Sign In…") { model.signInAgain(account.id) }
                        .buttonStyle(.pixel(.primary))
                        .fixedSize()
                        .disabled(!model.mayUse(account))
                }
            } else {
                Text(AccountMenu.beforeSigningIn)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Sign In…") { model.addAccount() }
                    .buttonStyle(.pixel(.primary))
                    .fixedSize()
                    .disabled(!model.canAddAccount)
            }
        }
    }
}

private struct GameStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PixelText("Minecraft", size: 17)
            if let install = model.gameInstall {
                CheckRow(
                    status: .waiting, title: String(localized: "Installing Minecraft"),
                    detail: install.progress?.summary
                        ?? String(localized: "Asking Microsoft for the game…")
                ) {
                    Button("Cancel") { model.cancelGameInstall() }
                        .buttonStyle(.pixel())
                        .fixedSize()
                }
                ProgressBar(value: install.progress?.fraction ?? 0)
                Text("The download is about 2 GB. You can go on to the next step meanwhile.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
            } else if let version = release.flatMap(model.installation(of:))?.version {
                CheckRow(
                    status: .good, title: String(localized: "Minecraft \(version) installed"),
                    detail: String(localized: "Profiles shows when a newer one is out."))
            } else {
                Text(
                    "macrock downloads the version Microsoft serves now with your account's license, and keeps it ready for the engine. Worlds and settings are kept apart, for each account."
                )
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                served
                if let release {
                    InstallGameButton(profile: release, title: "Install")
                }
            }
        }
        .task {
            if release.flatMap(model.installation(of:)) == nil, model.served(.release) == nil {
                model.checkForGameUpdateNow()
            }
        }
    }

    /// The first run installs Release; Preview can be installed from Profiles later.
    private var release: Profile? { model.library.latestProfile(of: .release) }

    @ViewBuilder private var served: some View {
        if model.isCheckingGame {
            CheckRow(
                status: .waiting, title: String(localized: "Asking Microsoft for the game…"),
                detail: String(localized: "Through your account's service."))
        } else if case .failure(let error)? = model.served(.release) {
            let notice = Notice(error: error)
            CheckRow(status: .bad, title: notice.title, detail: notice.message)
        } else if case .success(let served)? = model.served(.release) {
            CheckRow(
                status: .good, title: String(localized: "Minecraft \(served.version)"),
                detail: String(
                    localized:
                        "A \(served.size.formatted(.byteCount(style: .file))) download; it takes about as much on disk."
                ))
        }
    }
}

/// The engine downloads while the player goes through the steps.
private struct EngineLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let install = model.engineInstall {
            CheckRow(
                status: .waiting, title: String(localized: "Engine \(install.version)"),
                detail: install.downloaded < 1
                    ? String(
                        localized:
                            "Downloading: \(install.downloaded.formatted(.percent.precision(.fractionLength(0))))."
                    )
                    : String(localized: "Checking every file…")
            ) {
                ProgressBar(value: install.downloaded)
                    .frame(width: 160)
            }
        } else if let engine = model.installedEngine {
            CheckRow(
                status: .good, title: String(localized: "Engine \(engine.version) installed"),
                detail: String(
                    localized:
                        "It runs the Windows edition of the game: Wine with macrock's patches and an Xbox runtime."
                ))
        } else if case .unsupported(_, let reason)? = model.engineUpdate {
            let notice = Notice(error: reason)
            CheckRow(status: .bad, title: notice.title, detail: notice.message)
        } else if case .failure? = model.lastEngineCheck {
            CheckRow(
                status: .bad, title: String(localized: "The engine couldn't be downloaded"),
                detail: String(localized: "Check the connection, then try again.")
            ) {
                Button("Try Again") { model.checkForEngineUpdateNow() }
                    .buttonStyle(.pixel())
                    .fixedSize()
            }
        } else {
            CheckRow(
                status: .waiting, title: String(localized: "Looking for the engine…"),
                detail: String(localized: "It downloads from the engine's releases on GitHub."))
        }
    }
}

/// A requirement: whether it is met, what it is, and what can be done about it.
private struct CheckRow<Actions: View>: View {
    enum Status {
        case good, warning, bad, waiting
    }

    let status: Status
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch status {
                case .good: PixelImage(image: Artwork.check).frame(width: 18, height: 14)
                case .warning: PixelImage(image: Artwork.exclamation).frame(width: 4, height: 12)
                case .bad: PixelImage(image: Artwork.cross).frame(width: 14, height: 12)
                case .waiting: ProgressView().controlSize(.small)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                PixelText(verbatim: title, size: 13)
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            actions
        }
    }
}

extension CheckRow where Actions == EmptyView {
    init(status: Status, title: String, detail: String) {
        self.init(status: status, title: title, detail: detail) { EmptyView() }
    }
}
