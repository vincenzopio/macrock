import os

extension Logger {
    static let session = Logger(subsystem: "dev.macrock", category: "session")
    static let install = Logger(subsystem: "dev.macrock", category: "install")
}
