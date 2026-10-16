import Foundation
import Testing

@testable import LauncherCore

/// A process that holds the lock of a prefix's wineserver directory, as a running wineserver
/// does, until the test releases it.
struct ServerLockHolder {
    let process: ChildProcess
    private let directory: URL

    /// - Parameter serverDirectories: where wineservers keep their directories.
    init(prefix: URL, serverDirectories: URL = URL(filePath: "/tmp/.wine-\(getuid())"))
        async throws
    {
        let attributes = try FileManager.default.attributesOfItem(atPath: prefix.path)
        let device = try #require(attributes[.systemNumber] as? Int)
        let inode = try #require(attributes[.systemFileNumber] as? Int)
        directory = serverDirectories.appending(
            path: "server-\(String(device, radix: 16))-\(String(inode, radix: 16))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process = try ChildProcess.run(
            URL(filePath: "/usr/bin/perl"),
            arguments: [
                "-e",
                #"use Fcntl; open(my $f, ">", $ARGV[0]) or die; fcntl($f, F_SETLK, pack("q q l s s", 0, 1, 0, F_WRLCK, SEEK_SET)) or die; sleep 30"#,
                directory.appending(path: "lock").path,
            ], environment: [:])
        let server = WinePrefix(url: prefix, serverDirectories: serverDirectories)
        for _ in 0..<50 where server.runningServer() == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func release() {
        process.kill()
        try? FileManager.default.removeItem(at: directory)
    }
}
