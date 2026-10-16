import Foundation

/// A game folder that `GameFolder` accepts: a decrypted executable and its config.
func makeGameFolder(in directory: URL) throws -> URL {
    let game = directory.appending(path: "game")
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    try Data("MZ\u{90}\0".utf8).write(to: game.appending(path: "Minecraft.Windows.exe"))
    let config = """
        <?xml version="1.0" encoding="utf-8"?>
        <Game configVersion="1">
          <Identity Name="Microsoft.MinecraftUWP" Version="1.26.5203.0" />
          <TitleId>35760C07</TitleId>
          <StoreId>9NBLGGH2JHXJ</StoreId>
        </Game>
        """
    try Data(config.utf8).write(to: game.appending(path: "MicrosoftGame.Config"))
    return game
}
