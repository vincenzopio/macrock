import Foundation

/// An engine runtime whose `bin/wine` and `bin/wineserver` are shell scripts: each call appends
/// one line to `calls` with the program, its arguments and the variables that matter, then runs
/// the script's behaviour, if any, for that first argument.
struct FakeRuntime {
    let url: URL
    let calls: URL

    init(in directory: URL, behaviours: [String: String] = [:]) throws {
        try self.init(
            at: directory.appending(path: "runtime"), calls: directory.appending(path: "calls"),
            behaviours: behaviours)
    }

    init(at url: URL, calls: URL, behaviours: [String: String] = [:]) throws {
        self.url = url
        self.calls = calls
        let bin = url.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cases = behaviours.map { "  \"\($0.key)\") \($0.value) ;;" }.joined(separator: "\n")
        for program in ["wine", "wineserver"] {
            let script = """
                #!/bin/sh
                printf '%s\\n' "\(program) $* | WINEMSYNC=${WINEMSYNC-unset} WINEDLLOVERRIDES=${WINEDLLOVERRIDES-unset}" >> '\(calls.path)'
                case "\(program) $1" in
                \(cases)
                esac
                """
            let file = bin.appending(path: program)
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    var recorded: [String] {
        get throws {
            guard FileManager.default.fileExists(atPath: calls.path) else { return [] }
            return try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(
                String.init)
        }
    }
}
