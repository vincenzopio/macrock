import Foundation

/// What every child process gets from the user's own environment.
public struct HostEnvironment: Sendable {
    public static let current = HostEnvironment(
        home: NSHomeDirectory(), user: NSUserName(), temporaryDirectory: NSTemporaryDirectory())

    public let home: String
    public let user: String
    public let temporaryDirectory: String

    public init(home: String, user: String, temporaryDirectory: String) {
        self.home = home
        self.user = user
        self.temporaryDirectory = temporaryDirectory
    }

    var variables: [String: String] {
        ["HOME": home, "USER": user, "TMPDIR": temporaryDirectory, "PATH": "/usr/bin:/bin"]
    }
}
