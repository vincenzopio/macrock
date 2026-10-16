import Foundation
import Testing

@testable import LauncherCore

struct RunRecordTests {
    let temporary: TemporaryDirectory
    let directory: DataDirectory

    init() throws {
        temporary = try TemporaryDirectory()
        directory = DataDirectory(root: temporary.url, sockets: temporary.url)
        try FileManager.default.createDirectory(
            at: directory.runs, withIntermediateDirectories: true)
    }

    func writeRecord(pid: Int32, start: Int, socket: URL, session: String = "5e55107d") throws
        -> URL
    {
        let file = directory.runs.appending(path: "\(session).json")
        let json =
            #"{"servicePID": \#(pid), "serviceStart": \#(start), "socket": "\#(socket.path)", "prefix": "\#(temporary.url.path)/prefix"}"#
        try Data(json.utf8).write(to: file)
        return file
    }

    @Test func stopsTheServiceALauncherLeftRunning() async throws {
        let service = try ChildProcess.run(URL(filePath: "/usr/bin/caffeinate"), environment: [:])
        var info = proc_bsdinfo()
        _ = proc_pidinfo(
            service.processIdentifier, PROC_PIDTBSDINFO, 0, &info,
            Int32(MemoryLayout<proc_bsdinfo>.size))
        let socket = temporary.url.appending(path: "5e55107d.sock")
        try Data().write(to: socket)
        let record = try writeRecord(
            pid: service.processIdentifier, start: Int(info.pbi_start_tvsec), socket: socket)

        let prefixes = await RunRecord.recover(in: directory)

        #expect(prefixes.isEmpty)
        #expect(await service.termination == .signaled(SIGINT))
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test func recoversTheOtherSessionsPastAnUnreadableRecord() async throws {
        // Named to be read first: a folder lists its files in an order of its own.
        let unreadable = directory.runs.appending(path: "5e55107d.json")
        try Data("{".utf8).write(to: unreadable)
        let service = try ChildProcess.run(URL(filePath: "/usr/bin/caffeinate"), environment: [:])
        defer { service.kill() }
        var info = proc_bsdinfo()
        _ = proc_pidinfo(
            service.processIdentifier, PROC_PIDTBSDINFO, 0, &info,
            Int32(MemoryLayout<proc_bsdinfo>.size))
        let record = try writeRecord(
            pid: service.processIdentifier, start: Int(info.pbi_start_tvsec),
            socket: temporary.url.appending(path: "0a1b2c3d.sock"), session: "0a1b2c3d")

        _ = await RunRecord.recover(in: directory)

        #expect(await service.termination(within: .seconds(5)) == .signaled(SIGINT))
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(FileManager.default.fileExists(atPath: unreadable.path))
    }

    @Test func leavesAProcessThatReusedTheServicePID() async throws {
        let other = try ChildProcess.run(URL(filePath: "/usr/bin/caffeinate"), environment: [:])
        defer { other.kill() }
        let record = try writeRecord(
            pid: other.processIdentifier, start: 1,
            socket: temporary.url.appending(path: "none.sock"))

        _ = await RunRecord.recover(in: directory)

        #expect(other.isRunning)
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }
}
