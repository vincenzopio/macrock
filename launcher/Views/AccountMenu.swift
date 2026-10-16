import LauncherCore
import SwiftUI

/// The selected account and whether it can play; its menu chooses, adds, signs in again and
/// removes accounts.
struct AccountMenu: View {
    /// What the player is told before each new account signs in.
    static var beforeSigningIn: String {
        String(
            localized:
                "Sign in with the account that bought Minecraft for Windows. To sign in, macrock registers this Mac with Microsoft as a Windows device, which sends Microsoft this Mac's model, serial number and hardware UUID. The account's tokens stay in your login keychain."
        )
    }

    @Environment(AppModel.self) private var model
    @Environment(Popups.self) private var popups

    var body: some View {
        PixelMenu(width: 280) {
            if let account = model.selectedAccount {
                let signedIn = model.readiness.signedIn == true
                PickerLabel(
                    icon: Artwork.head(for: account.id), title: account.label,
                    detail: signedIn
                        ? String(localized: "Signed in") : String(localized: "Sign-in needed"),
                    detailColour: signedIn ? Palette.positive : Palette.warning, opensUp: false)
            } else {
                PickerLabel(
                    icon: nil, title: String(localized: "No account"),
                    detail: String(localized: "Add one from here"), opensUp: false)
            }
        } items: {
            let accounts = model.library.accounts.filter { !$0.isPending }
            if !accounts.isEmpty {
                PixelMenuSection(title: "Accounts")
                ForEach(accounts) { account in
                    PixelMenuItem(checked: account.id == model.library.selectedAccount) {
                        model.selectAccount(account.id)
                    } label: {
                        PixelImage(image: Artwork.head(for: account.id))
                            .frame(width: 18, height: 18)
                        Text(verbatim: account.label)
                    }
                }
                PixelMenuDivider()
            }
            if let account = model.selectedAccount {
                let usable = model.mayUse(account) && model.selectedSession == nil
                PixelMenuItem("Sign In Again…") { model.signInAgain(account.id) }
                    .disabled(!usable)
                PixelMenuItem("Remove “\(account.label)”…", role: .destructive) {
                    confirmRemoval(of: account)
                }
                .disabled(!usable)
                PixelMenuDivider()
            }
            PixelMenuItem("Add Account…") { askToAdd() }
                .disabled(!model.canAddAccount)
        }
        .buttonStyle(.pixel(minHeight: PickerLabel.height))
        .frame(width: 250)
        .disabled(model.isSigningIn || model.isInstallingGame)
    }

    private func askToAdd() {
        popups.dialog = Dialog(
            title: String(localized: "Add a Microsoft account"), message: Self.beforeSigningIn,
            answers: [
                .init(title: String(localized: "Cancel"), role: .cancel),
                .init(title: String(localized: "Continue")) { model.addAccount() },
            ])
    }

    private func confirmRemoval(of account: Account) {
        popups.dialog = Dialog(
            title: String(localized: "Remove “\(account.label)”?"),
            message: String(
                localized:
                    "macrock signs the account out on this Mac and deletes its Windows prefix. Its worlds, packs and settings are kept in a backup first."
            ),
            answers: [
                .init(title: String(localized: "Cancel"), role: .cancel),
                .init(title: String(localized: "Remove"), role: .destructive) {
                    model.removeAccount(account.id)
                },
            ])
    }
}
