import Foundation
import os

/// `run/<session>.json`: what a session has running, so that the next start of the launcher can
/// clean up after a launcher that did not end its sessions.
struct RunRecord: Codable, Equatable {
    let servicePID: Int32
    /// When the service started, as the kernel tells it: a pid reused by another process has
    /// another start time.
    let serviceStart: Int
    let socket: String
    let prefix: String

    init(service: XodusService, prefix: WinePrefix) {
        servicePID = service.processIdentifier
        serviceStart = Self.startTime(of: service.processIdentifier) ?? 0
        socket = service.socketPath
        self.prefix = prefix.url.path
    }

    func write(to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    /// Stops the services of sessions the launcher left behind and removes their sockets and
    /// records. Returns the prefixes whose Wine processes still run, for the user to end. It
    /// never fails: what it cannot clean up is logged and left.
    static func recover(in directory: DataDirectory) async -> [WinePrefix] {
        guard FileManager.default.fileExists(atPath: directory.runs.path) else { return [] }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory.runs, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        } catch {
            Logger.session.error("Could not read the run records: \(error)")
            return []
        }
        var prefixes: [WinePrefix] = []
        for file in files {
            do {
                let record = try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: file))
                await record.stopService()
                try FileManager.default.removeItemIfPresent(at: URL(filePath: record.socket))
                let prefix = WinePrefix(url: URL(filePath: record.prefix))
                if prefix.runningServer() != nil { prefixes.append(prefix) }
                try FileManager.default.removeItem(at: file)
            } catch {
                Logger.session.error("Could not recover a session: \(error)")
            }
        }
        return prefixes
    }

    private func stopService() async {
        guard serviceStart != 0, Self.startTime(of: servicePID) == serviceStart else { return }
        kill(servicePID, SIGINT)
        for _ in 0..<50 where Self.startTime(of: servicePID) == serviceStart {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        }
        if Self.startTime(of: servicePID) == serviceStart { kill(servicePID, SIGKILL) }
    }

    private static func startTime(of pid: Int32) -> Int? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int(info.pbi_start_tvsec)
    }
}
