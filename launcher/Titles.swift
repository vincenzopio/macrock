import Foundation
import LauncherCore

extension AppModel {
    func name(of profile: Profile) -> String {
        profile.name ?? defaultName(of: profile)
    }

    func defaultName(of profile: Profile) -> String {
        let version = installation(of: profile)?.version ?? ""
        return switch (profile.kind, profile.product) {
        case (.latest, .release): String(localized: "Latest Release")
        case (.latest, .preview): String(localized: "Latest Preview")
        case (.kept, .release): String(localized: "Release \(version)")
        case (.kept, .preview): String(localized: "Preview \(version)")
        }
    }

    /// What shows under a profile's name: the version it plays, or that it has none yet.
    func detail(of profile: Profile) -> String {
        switch profile.kind {
        case .kept: String(localized: "Kept copy")
        case .latest: installation(of: profile)?.version ?? String(localized: "Not installed")
        }
    }
}

extension GameProduct {
    var title: String {
        switch self {
        case .release: String(localized: "Minecraft")
        case .preview: String(localized: "Minecraft Preview")
        }
    }
}

extension Pack.Kind {
    var title: String {
        switch self {
        case .resources: String(localized: "Resource pack")
        case .behavior: String(localized: "Behavior pack")
        case .skins: String(localized: "Skin pack")
        }
    }
}

extension MetalBackend {
    var title: String {
        switch self {
        case .metal4: "Metal 4"
        case .metal3: "Metal 3"
        }
    }
}

extension InstallProgress {
    var fraction: Double {
        total > 0 ? min(Double(done) / Double(total), 1) : 0
    }

    var summary: String {
        let done = done.formatted(.byteCount(style: .file))
        let total = total.formatted(.byteCount(style: .file))
        return switch phase {
        case .downloading: String(localized: "Downloading: \(done) of \(total).")
        case .extracting: String(localized: "Unpacking: \(done) of \(total).")
        }
    }
}
