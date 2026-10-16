#if DEBUG
    import AppKit
    import SwiftUI

    /// Debug builds only: point the launcher at what this Mac already has.
    struct DeveloperCommands: Commands {
        let model: AppModel

        var body: some Commands {
            CommandMenu("Developer") {
                Button("Use Engine Releases From Folder…") {
                    if let folder = choose(
                        message: "Choose a folder of macrock-engine packages.")
                    {
                        model.useEngineReleases(from: folder)
                    }
                }
                Button("Use Engine Releases From GitHub") { model.useEngineReleases(from: nil) }
                Divider()
                Button("Use the Development Account") { model.adoptDevelopmentAccount() }
                Button("Show the First-Run Wizard") { model.showFirstRunAgain() }
            }
        }

        private func choose(message: String) -> URL? {
            let panel = NSOpenPanel()
            panel.message = message
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            return panel.runModal() == .OK ? panel.url : nil
        }
    }
#endif
