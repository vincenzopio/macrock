import CryptoKit
import Foundation

/// A stand-in for xodus-service. The kernel checks the service's binary at exec, which a script
/// can't pass, so it is a Mach-O tool, compiled from C whenever its source changes. It relays each
/// frame of its launcher channel (standard input) to the test's `FakeService` on XODUS_SOCKET, one
/// connection per frame, and writes back the replies the fake sends before it closes the
/// connection. A reply of type 0 makes it exit, with the reply's first byte as its status; SIGINT
/// ends it.
let serviceStandIn = Task { try await compile(standInSource) }

private let standInSource = """
    #include <stdint.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <sys/un.h>
    #include <unistd.h>

    static int read_exactly(int from, uint8_t *buffer, size_t count) {
        while (count > 0) {
            ssize_t done = read(from, buffer, count);
            if (done <= 0) return -1;
            buffer += done;
            count -= (size_t)done;
        }
        return 0;
    }

    static int write_all(int to, const uint8_t *buffer, size_t count) {
        while (count > 0) {
            ssize_t done = write(to, buffer, count);
            if (done <= 0) return -1;
            buffer += done;
            count -= (size_t)done;
        }
        return 0;
    }

    static size_t payload_length(const uint8_t *header) { return header[6] | header[7] << 8; }

    int main(void) {
        static uint8_t frame[8 + 65535];
        struct sockaddr_un fake = {.sun_family = AF_UNIX};
        strlcpy(fake.sun_path, getenv("XODUS_SOCKET"), sizeof fake.sun_path);
        while (read_exactly(0, frame, 8) == 0) {
            int connection = socket(AF_UNIX, SOCK_STREAM, 0);
            if (read_exactly(0, frame + 8, payload_length(frame)) != 0
                || connect(connection, (struct sockaddr *)&fake, sizeof fake) != 0
                || write_all(connection, frame, 8 + payload_length(frame)) != 0)
                return 1;
            while (read_exactly(connection, frame, 8) == 0) {
                if (read_exactly(connection, frame + 8, payload_length(frame)) != 0) return 1;
                if (frame[4] == 0 && frame[5] == 0) return payload_length(frame) > 0 ? frame[8] : 0;
                if (write_all(0, frame, 8 + payload_length(frame)) != 0) return 1;
            }
            close(connection);
        }
        return 0;
    }
    """

private func compile(_ source: String) async throws -> URL {
    let digest = SHA256.hash(data: Data(source.utf8)).prefix(8)
    let name = digest.map { String(format: "%02x", $0) }.joined()
    let binary = URL.temporaryDirectory.appending(path: "LauncherCoreTests-service-\(name)")
    if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
    let build = try TemporaryDirectory()
    let file = build.url.appending(path: "service.c")
    try Data(source.utf8).write(to: file)
    let output = build.url.appending(path: "service")
    try await runTool("/usr/bin/clang", ["-O2", "-o", output.path, file.path])
    _ = try FileManager.default.replaceItemAt(binary, withItemAt: output)
    return binary
}
