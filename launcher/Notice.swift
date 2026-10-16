import Foundation
import LauncherCore

/// A message at the top of the window: what happened, in the player's terms, and a folder to
/// look into.
struct Notice: Identifiable, Equatable {
    enum Kind {
        case information, warning, problem
    }

    enum Folder: Equatable {
        case logs(URL)
        case backup(URL)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    var folder: Folder?
}

extension Notice {
    /// Nothing to say when the player quit the game or it closed when asked.
    init?(outcome: SessionOutcome, logs: URL) {
        switch outcome {
        case .exited(.exited(0)), .stopped:
            return nil
        case .exited:
            self.init(
                kind: .problem, title: String(localized: "Minecraft quit unexpectedly"),
                message: String(localized: "The session's logs show what it was doing."),
                folder: .logs(logs))
        case .forced:
            self.init(
                kind: .information, title: String(localized: "Minecraft was ended"),
                message: String(localized: "It did not close when asked, so macrock ended it."),
                folder: .logs(logs))
        }
    }

    /// D3DMetal 4.0b2's Metal 4 backend draws the classic renderer's interface wrong when
    /// anti-aliasing is on. Said at every start on Metal 4 until the engine works around it.
    static var metal4AntiAliasing: Notice {
        Notice(
            kind: .warning, title: String(localized: "Metal 4 has a known issue"),
            message: String(
                localized:
                    "With Simple or Fancy graphics and anti-aliasing on, the interface can turn purple. Turn anti-aliasing off, use Vibrant Visuals, or choose Metal 3."
            ))
    }

    /// The service in the app is a build that hasn't read this account's Keychain item yet, so
    /// macOS asks for the user's password first.
    static var keychainPrompt: Notice {
        Notice(
            kind: .warning, title: String(localized: "macOS will ask for your password"),
            message: String(
                localized:
                    "The account service has been updated and needs your permission to read this account's sign-in. Enter your login password and choose Always Allow."
            ))
    }

    init(error: any Error, logs: URL? = nil) {
        let (title, message) = Self.copy(for: error)
        self.init(kind: .problem, title: title, message: message, folder: logs.map(Folder.logs))
    }

    init(installed installation: Installation) {
        let title =
            switch installation.product {
            case .release: String(localized: "Minecraft \(installation.version) is installed")
            case .preview:
                String(localized: "Minecraft Preview \(installation.version) is installed")
            }
        self.init(
            kind: .information, title: title, message: String(localized: "It's ready to play."))
    }

    /// The game turns packs on only once the player chooses them.
    init(added packs: [Pack]) {
        let names = packs.map(\.name).formatted(.list(type: .and))
        self.init(
            kind: .information, title: String(localized: "Added \(names)"),
            message: String(
                localized:
                    "Turn resource packs on in the game's Global Resources, and behavior packs in a world's settings."
            ))
    }

    init(added world: World, to product: GameProduct) {
        self.init(
            kind: .information, title: String(localized: "Added “\(world.name)”"),
            message: String(localized: "It's among the worlds of \(product.title)."))
    }

    static var contentNeedsAccount: Notice {
        Notice(
            kind: .information, title: String(localized: "Add an account first"),
            message: String(
                localized:
                    "Worlds and packs belong to an account. Add yours from the menu at the top right."
            ))
    }

    static var contentWhilePlaying: Notice {
        Notice(
            kind: .warning, title: String(localized: "Close Minecraft first"),
            message: String(localized: "Worlds and packs can't change while the account plays."))
    }

    static var contentWhileBusy: Notice {
        Notice(
            kind: .information, title: String(localized: "macrock is busy"),
            message: String(localized: "Open the file again once the current task is done."))
    }

    init(removed account: Account, backup: URL) {
        self.init(
            kind: .information, title: String(localized: "“\(account.label)” was removed"),
            message: String(localized: "Its worlds, packs and settings are kept in a backup."),
            folder: .backup(backup))
    }

    private static func copy(for error: any Error) -> (title: String, message: String) {
        switch error {
        case let error as SessionError: copy(for: error)
        case let error as XodusServiceError: copy(for: error)
        case let error as ServiceFailure: copy(for: error)
        case let error as EngineError: copy(for: error)
        case let error as ReleaseError: copy(for: error)
        case let error as WineError: copy(for: error)
        case let error as GameFolderError: copy(for: error)
        case let error as ContentError: copy(for: error)
        case is ProgramSignatureError:
            (
                String(localized: "This copy of Minecraft isn't signed by Microsoft"),
                String(
                    localized:
                        "It may have been changed on its way, so macrock didn't install it. Try again later."
                )
            )
        case GraphicsError.licenseDeclined:
            (
                String(localized: "D3DMetal wasn't imported"),
                String(
                    localized:
                        "macOS opens the Game Porting Toolkit only once you agree to Apple's license."
                )
            )
        case is GraphicsError:
            (
                String(localized: "This isn't Apple's Game Porting Toolkit"),
                String(
                    localized:
                        "Choose the Game Porting Toolkit 4 disk image from Apple's developer downloads."
                )
            )
        case is DiskImageError:
            (
                String(localized: "The disk image couldn't be opened"),
                String(localized: "It may be damaged or encrypted. Download it again from Apple.")
            )
        case is CodeSignatureError:
            (
                String(localized: "A component has been changed"),
                String(localized: "Its files no longer match their signature. Import it again.")
            )
        case is GameInputError:
            (
                String(localized: "Unknown GameInput package"),
                String(
                    localized:
                        "This version of the game ships a GameInput that macrock doesn't know yet.")
            )
        case is XodusError, is TimeoutError:
            (
                String(localized: "The account service didn't answer"),
                String(localized: "Try again in a moment.")
            )
        case is KeychainError:
            (
                String(localized: "The Keychain didn't answer"),
                String(localized: "Unlock the login keychain and try again.")
            )
        case is DataDirectoryError:
            (
                String(localized: "The account service can't start"),
                String(
                    localized:
                        "The path of macOS's temporary folder for macrock is too long for the service's socket."
                )
            )
        case is WinePrefixError:
            (
                String(localized: "The account's Wine prefix is incomplete"),
                String(localized: "Its setup didn't finish. Play again to finish it.")
            )
        default:
            (String(localized: "Something went wrong"), error.localizedDescription)
        }
    }

    private static func copy(for error: ContentError) -> (title: String, message: String) {
        switch error {
        case .gameNotRunYet:
            (
                String(localized: "Play this version once first"),
                String(
                    localized:
                        "Minecraft makes the folders of worlds and packs the first time it runs for the account."
                )
            )
        case .unreadableArchive:
            (
                String(localized: "The file can't be opened"),
                String(localized: "It isn't a zip archive, or it's damaged.")
            )
        case .unsafeArchive:
            (
                String(localized: "The file was refused"),
                String(
                    localized: "It holds a link, which could lead outside Minecraft's folders.")
            )
        case .notAWorld:
            (
                String(localized: "There's no world in the file"),
                String(localized: "A world's file holds its level.dat.")
            )
        case .notAPack:
            (
                String(localized: "There's no pack in the file"),
                String(localized: "A pack holds its manifest.json.")
            )
        case .unsupportedPack(let modules):
            (
                String(localized: "macrock can't add this kind of pack yet"),
                String(
                    localized:
                        "Its modules are \(modules). macrock adds resource, behavior and skin packs."
                )
            )
        case .duplicatePack:
            (
                String(localized: "The file holds one pack twice"),
                String(localized: "Two of its packs have the same ID, so macrock added none.")
            )
        }
    }

    private static func copy(for error: SessionError) -> (title: String, message: String) {
        switch error {
        case .alreadyRunning:
            (
                String(localized: "This account is already playing"),
                String(localized: "Another window of macrock runs a session of this account.")
            )
        case .prefixInUse:
            (
                String(localized: "The last session is still closing"),
                String(
                    localized: "Its Windows programs are still running. End them, then play again.")
            )
        case .unsupportedD3DMetal(let found, let required):
            (
                String(localized: "Game Porting Toolkit \(required) is needed"),
                String(
                    localized:
                        "This engine needs D3DMetal \(required); this one is \(found).")
            )
        case .notOwned: notOwned
        case .signInAgain: signInAgain
        case .licenseUnknown:
            (
                String(localized: "The license couldn't be checked"),
                String(localized: "Microsoft didn't answer. Check the network and try again.")
            )
        }
    }

    private static func copy(for error: ServiceFailure) -> (title: String, message: String) {
        switch error {
        case .refused:
            (
                String(localized: "Microsoft refused the sign-in"),
                String(localized: "Try again, or with another Microsoft account.")
            )
        case .notSignedIn: signInAgain
        case .keychainRefused: keychainRefused
        case .microsoftUnavailable:
            (
                String(localized: "Microsoft didn't answer"),
                String(localized: "Check the network and try again.")
            )
        case .notOwned: notOwned
        case .noSpace(let bytesNeeded):
            (
                String(localized: "There isn't enough space for Minecraft"),
                String(
                    localized:
                        "Installing it needs \(bytesNeeded.formatted(.byteCount(style: .file))) free on the disk. Free some space, then try again."
                )
            )
        case .packageDamaged:
            (
                String(localized: "Minecraft's download kept arriving damaged"),
                String(localized: "Try again later. What was downloaded intact is kept.")
            )
        case .packageUnreadable:
            (
                String(localized: "This version of Minecraft can't be installed"),
                String(localized: "macrock can't read the package Microsoft serves now.")
            )
        case .diskFailed:
            (
                String(localized: "Minecraft couldn't be written to the disk"),
                String(localized: "Check the disk in Disk Utility, then try again.")
            )
        case .invalidServerData, .unknown:
            (
                String(localized: "The account service couldn't do it"),
                String(localized: "Try again.")
            )
        }
    }

    private static var signInAgain: (String, String) {
        (
            String(localized: "Sign in again"),
            String(localized: "Microsoft no longer accepts this account's sign-in.")
        )
    }

    private static var notOwned: (String, String) {
        (
            String(localized: "This account doesn't own Minecraft"),
            String(
                localized: "Sign in with the Microsoft account that bought Minecraft for Windows.")
        )
    }

    private static var keychainRefused: (String, String) {
        (
            String(localized: "The Keychain denied the account service"),
            String(
                localized:
                    "macOS asks for your password when the account service has changed. Try again and choose Always Allow."
            )
        )
    }

    private static func copy(for error: XodusServiceError) -> (title: String, message: String) {
        switch error {
        case .missingSetting, .notThePinnedBuild, .launcherRefused, .unsupportedChannel:
            (
                String(localized: "macrock is damaged"),
                String(
                    localized:
                        "The account service inside the app doesn't match it. Install macrock again."
                )
            )
        case .keychainRefused: keychainRefused
        case .socketUnavailable, .exitedBeforeReady:
            (
                String(localized: "The account service stopped"),
                String(localized: "It stopped before it was ready. Try again.")
            )
        case .notReady:
            (
                String(localized: "The account service didn't start"),
                String(localized: "It didn't answer in time. Try again.")
            )
        }
    }

    private static func copy(for error: EngineError) -> (title: String, message: String) {
        switch error {
        case .notAnEngineBundle, .versionMismatch, .buildMismatch, .sealBroken,
            .invalidPrefixSetup:
            (
                String(localized: "The engine is damaged"),
                String(localized: "Reinstall it in Settings.")
            )
        case .unsupportedSchema:
            (
                String(localized: "This macrock can't read the engine release"),
                String(localized: "Update macrock to install it.")
            )
        case .needsMacOS(let version):
            (
                String(localized: "The engine needs macOS \(version)"),
                String(localized: "Update macOS to install it.")
            )
        case .serviceProtocolMismatch(let engine, let service) where engine > service:
            (
                String(localized: "The engine needs a newer macrock"),
                String(localized: "Update macrock to install it.")
            )
        case .serviceProtocolMismatch:
            (
                String(localized: "The engine is older than this macrock"),
                String(localized: "No engine release works with this build of macrock yet.")
            )
        }
    }

    private static func copy(for error: ReleaseError) -> (title: String, message: String) {
        switch error {
        case .unavailable(let status):
            (
                String(localized: "The engine release isn't available"),
                String(localized: "The server answered with status \(status). Try again later.")
            )
        case .damagedArchive:
            (
                String(localized: "The engine download is damaged"),
                String(localized: "Try again.")
            )
        case .unreadableArchive:
            (
                String(localized: "The engine couldn't be unpacked"),
                String(localized: "Check that the disk has free space, then try again.")
            )
        }
    }

    private static func copy(for error: WineError) -> (title: String, message: String) {
        switch error {
        case .timedOut(let program):
            (
                String(localized: "Preparing Windows took too long"),
                String(localized: "\(program) didn't finish. The session's logs have the details.")
            )
        case .failed(let program, _):
            (
                String(localized: "Preparing Windows failed"),
                String(localized: "\(program) failed. The session's logs have the details.")
            )
        case .serverStillRunning:
            (
                String(localized: "Windows programs are still running"),
                String(localized: "They didn't stop when asked. Try again in a moment.")
            )
        }
    }

    private static func copy(for error: GameFolderError) -> (title: String, message: String) {
        switch error {
        case .missingExecutable:
            (
                String(localized: "Minecraft isn't in this folder"),
                String(localized: "Choose the folder that contains Minecraft.Windows.exe.")
            )
        case .executableNotDecrypted:
            (
                String(localized: "The game files are still encrypted"),
                String(localized: "macrock plays decrypted installations only.")
            )
        case .malformedConfig:
            (
                String(localized: "The game folder is damaged"),
                String(localized: "Its MicrosoftGame.Config can't be read.")
            )
        }
    }
}
