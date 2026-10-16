import AppKit
import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

/// A profile's game files, and the worlds and packs the selected account has for its product,
/// which every profile of the product shares.
struct ContentsView: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    @State private var listing = Listing()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProfileHeader(profile: profile)
            if let account = model.selectedAccount, let data {
                Text(
                    "The worlds and packs of \(account.label) in \(profile.product.title), the same for every profile of it."
                )
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryText)
                Folders(profile: profile, data: data, account: account, listing: listing)
                Worlds(data: data, listing: listing)
                Packs(data: data, listing: listing)
                Development(data: data, listing: listing)
            } else {
                Text("Add an account to see its worlds and packs.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .task(id: model.contentChanges) { load() }
    }

    private var data: GameData? { model.gameData(of: profile.product) }

    private func load() {
        guard let data else { return }
        do {
            listing = Listing(
                user: try data.user(), worlds: try data.worlds(), packs: try data.packs(),
                regolithEnvironment: model.regolithEnvironment(),
                writesContentLog: try data.writesContentLog() == true)
        } catch {
            listing = Listing(unreadable: true)
        }
    }

    struct Listing {
        var user: URL?
        var worlds: [World] = []
        var packs: [Pack] = []
        var regolithEnvironment: String?
        var writesContentLog = false
        var unreadable = false
    }
}

private struct Folders: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    let data: GameData
    let account: Account
    let listing: ContentsView.Listing

    var body: some View {
        PanelSection(title: "Show in Finder") {
            HStack(spacing: 8) {
                OpenButton("Game Files", url: model.installation(of: profile)?.game)
                OpenButton("Worlds", url: listing.user?.appending(path: "minecraftWorlds"))
                OpenButton("Packs", url: data.shared)
                OpenButton("Screenshots", url: listing.user?.appending(path: "Screenshots"))
                OpenButton("Backups", url: model.directory.backups(of: account.id))
            }
        }
    }
}

private struct Worlds: View {
    @Environment(AppModel.self) private var model
    @Environment(Popups.self) private var popups
    let data: GameData
    let listing: ContentsView.Listing

    var body: some View {
        PanelSection(title: "Worlds") {
            HStack(spacing: 16) {
                RowLabel("Import a world", detail: "From a .mcworld file, under its own name.")
                Spacer(minLength: 12)
                Button("Import…") {
                    if let file = NSOpenPanel.chooseGameFile([.world]) {
                        model.importContent(from: [file], into: data)
                    }
                }
                .buttonStyle(.pixel())
                .fixedSize()
                .disabled(!model.canChangeContent || listing.user == nil)
            }
            if listing.unreadable {
                Text("The game's folders can't be read.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.negative)
            } else if listing.worlds.isEmpty {
                Text("No world yet. Those you create in the game show here.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
            }
            ForEach(listing.worlds) { world in
                HStack(spacing: 14) {
                    WorldIcon(file: world.icon)
                    RowLabel(verbatim: world.name, detail: detail(of: world))
                    Spacer(minLength: 12)
                    IconButton(title: "Show in Finder", icon: Artwork.folder) {
                        NSWorkspace.shared.activateFileViewerSelecting([world.folder])
                    }
                    Button("Export…") { export(world) }
                        .buttonStyle(.pixel())
                        .fixedSize()
                        .disabled(!model.canChangeContent)
                    IconButton(title: "Move to Trash", icon: Artwork.trash) { confirmTrash(world) }
                        .disabled(!model.canChangeContent)
                }
            }
        }
    }

    private func detail(of world: World) -> String {
        let size = world.size.formatted(.byteCount(style: .file))
        guard let played = world.lastPlayed else { return size }
        return String(
            localized: "Played \(played.formatted(date: .abbreviated, time: .shortened)), \(size)")
    }

    private func export(_ world: World) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            world.name.replacing(/[\/:]/, with: "-") + "." + ContentFile.world.rawValue
        panel.allowedContentTypes =
            [UTType(filenameExtension: ContentFile.world.rawValue)].compactMap(\.self)
        guard panel.runModal() == .OK, let file = panel.url else { return }
        model.export(world, of: data, to: file)
    }

    private func confirmTrash(_ world: World) {
        popups.dialog = Dialog(
            title: String(localized: "Move “\(world.name)” to the Trash?"),
            message: String(localized: "You can get it back from the Trash until you empty it."),
            answers: [
                .init(title: String(localized: "Cancel"), role: .cancel),
                .init(title: String(localized: "Move to Trash"), role: .destructive) {
                    model.trash(world, of: data)
                },
            ])
    }
}

private struct Packs: View {
    @Environment(AppModel.self) private var model
    @Environment(Popups.self) private var popups
    let data: GameData
    let listing: ContentsView.Listing

    var body: some View {
        PanelSection(title: "Packs") {
            HStack(spacing: 16) {
                RowLabel(
                    "Import packs",
                    detail:
                        "From a .mcpack or .mcaddon file. The game turns resource packs on in its Global Resources, and behavior packs in a world's settings."
                )
                Spacer(minLength: 12)
                Button("Import…") {
                    if let file = NSOpenPanel.chooseGameFile([.pack, .addon]) {
                        model.importContent(from: [file], into: data)
                    }
                }
                .buttonStyle(.pixel())
                .fixedSize()
                .disabled(!model.canChangeContent || !data.exists)
            }
            if listing.packs.isEmpty && !listing.unreadable {
                Text("No pack yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
            }
            ForEach(listing.packs) { pack in
                HStack(spacing: 14) {
                    PackIcon(file: pack.icon)
                    RowLabel(verbatim: pack.name, detail: "\(pack.kind.title) \(pack.version)")
                    Spacer(minLength: 12)
                    IconButton(title: "Show in Finder", icon: Artwork.folder) {
                        NSWorkspace.shared.activateFileViewerSelecting([pack.folder])
                    }
                    IconButton(title: "Move to Trash", icon: Artwork.trash) { confirmTrash(pack) }
                        .disabled(!model.canChangeContent)
                }
            }
        }
    }

    private func confirmTrash(_ pack: Pack) {
        popups.dialog = Dialog(
            title: String(localized: "Move “\(pack.name)” to the Trash?"),
            message: String(
                localized:
                    "Worlds that use it lose what it adds. You can get it back from the Trash until you empty it."
            ),
            answers: [
                .init(title: String(localized: "Cancel"), role: .cancel),
                .init(title: String(localized: "Move to Trash"), role: .destructive) {
                    model.trash(pack, of: data)
                },
            ])
    }
}

/// The game's folders as tools such as Regolith need them.
private struct Development: View {
    @Environment(AppModel.self) private var model
    let data: GameData
    let listing: ContentsView.Listing

    var body: some View {
        PanelSection(title: "Development") {
            if listing.user == nil {
                Text("Play this version once: the game makes these folders the first time it runs.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
            }
            folder("com.mojang for packs", shared)
            folder("com.mojang for worlds", listing.user)
            HStack(spacing: 16) {
                RowLabel(
                    "Regolith",
                    detail:
                        "Points Regolith's exports at these folders, for Minecraft and Minecraft Preview. Save it as .env in your project."
                )
                Spacer(minLength: 12)
                CopyButton(title: "Copy .env", text: listing.regolithEnvironment)
            }
            HStack(spacing: 16) {
                if listing.writesContentLog {
                    RowLabel(
                        "Content log",
                        detail:
                            "What packs and scripts report, a file for each start. The game writes it about a minute late."
                    )
                } else {
                    RowLabel(
                        "Content log",
                        detail: "Turn on Content Log File in the game's Creator settings.")
                }
                Spacer(minLength: 12)
                Button("Open Latest") {
                    if let file = model.latestContentLog(of: data) { NSWorkspace.shared.open(file) }
                }
                .buttonStyle(.pixel())
                .fixedSize()
                .disabled(!hasLogs)
                OpenButton("Show in Finder", url: data.logs)
            }
        }
    }

    private var hasLogs: Bool { FileManager.default.fileExists(atPath: data.logs.path) }

    private var shared: URL? {
        data.exists ? data.shared : nil
    }

    private func folder(_ title: LocalizedStringKey, _ url: URL?) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(verbatim: url?.path ?? "–")
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            CopyButton(title: "Copy Path", text: url?.path)
        }
    }
}

/// Copies `text` to the pasteboard, and says so for a moment.
private struct CopyButton: View {
    let title: LocalizedStringKey
    let text: String?
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : title) {
            guard let text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        }
        .buttonStyle(.pixel())
        .fixedSize()
        .disabled(text == nil)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// The picture the game took of a world, or grass until it has taken one.
private struct WorldIcon: View {
    let file: URL?

    var body: some View {
        AsyncImage(url: file) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            PixelImage(image: Artwork.grassBlock).frame(width: 28, height: 28)
        }
        .frame(width: 64, height: 36)
        .clipped()
        .slot()
    }
}

private struct PackIcon: View {
    let file: URL?

    var body: some View {
        AsyncImage(url: file) { image in
            image.resizable().interpolation(.none)
        } placeholder: {
            PixelImage(image: Artwork.chest)
        }
        .frame(width: 28, height: 28)
        .padding(4)
        .slot()
    }
}

extension NSOpenPanel {
    static func chooseGameFile(_ kinds: [ContentFile]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kinds.compactMap { UTType(filenameExtension: $0.rawValue) }
        panel.directoryURL = .downloadsDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }
}
