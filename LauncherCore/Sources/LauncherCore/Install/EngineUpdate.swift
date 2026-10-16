/// What the latest release means for the installed engine.
public enum EngineUpdate: Sendable, Equatable {
    /// A later release, or the first one, that this Mac and the app's account service can run.
    case available(EngineRelease)
    /// A later release this launcher can't install, and why.
    case unsupported(EngineRelease, EngineError)
}

extension EngineRelease {
    /// Nil when the installed engine, given by its version, is this release or a later one.
    public func update(fromVersion installed: String?, serviceProtocol: Int) -> EngineUpdate? {
        if let installed, !index.isNewer(than: installed) {
            return nil
        }
        do {
            try index.checkCompatibility(serviceProtocol: serviceProtocol)
            return .available(self)
        } catch {
            return .unsupported(self, error)
        }
    }
}
