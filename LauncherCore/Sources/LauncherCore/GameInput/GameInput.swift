import CryptoKit
import Foundation

/// Microsoft GameInput from the game's own redistributable, `Installers/GameInputRedist.msi`.
/// The game stops at start without it. Only the reviewed package is accepted: its four native
/// files are read from the MSI without running it and checked against pinned sizes and hashes.
public struct GameInput {
    private struct PinnedFile {
        let name: String
        let size: Int
        let sha256: String
        let isLibrary: Bool
    }

    private static let installerSHA256 =
        "4e325dbc8a6853ea7786504f6f326bee37a085b799d262a5ec296df95cc8601a"
    private static let cabinetSHA256 =
        "e1ef9aaf57b36bd75c75416772026835842353b764926ccf6242cf6a1cd676af"
    private static let pinnedFiles = [
        PinnedFile(
            name: "GameInputRedist.dll", size: 895_376,
            sha256: "ea6816937030fcf232de5c29628a0140d0643f81939b5ac47fb2a1f4bfaa374d",
            isLibrary: true),
        PinnedFile(
            name: "GameInputRedistService.exe", size: 137_616,
            sha256: "3959900e8a57e368e86f0b9d63585bc721d71ee78fba30086f224fc9981244c2",
            isLibrary: false),
        PinnedFile(
            name: "GameInputBridge.dll", size: 80_272,
            sha256: "00a5255333be1db3006485f5a5c6a9e1e42ccdb1d7ba35d05aeafedc9f1bc5c5",
            isLibrary: true),
        PinnedFile(
            name: "GameInputRawInputProxy.exe", size: 80_272,
            sha256: "76638d16c9bbd6c87b4b64bdbbcce166b2f83f261fc756ec6714a5a5f667dd81",
            isLibrary: false),
    ]

    /// Where the files go in a prefix, and the same place as Windows sees it.
    static let directory = "drive_c/Program Files/Microsoft GameInput/x64"
    private static let windowsDirectory = #"C:\Program Files\Microsoft GameInput\x64"#

    private let files: [String: Data]

    public init(installer: URL) throws {
        let package = try Data(contentsOf: installer)
        guard Self.sha256(package) == Self.installerSHA256 else {
            throw GameInputError.unrecognizedPackage
        }
        do {
            guard
                let cabinet = try CompoundFile([UInt8](package)).stream(
                    startingWith: Cabinet.signature),
                Self.sha256(Data(cabinet)) == Self.cabinetSHA256
            else {
                throw GameInputError.unrecognizedPackage
            }
            var files: [String: Data] = [:]
            for file in try Cabinet(cabinet).files {
                let content = Data(file.content)
                guard
                    let pinned = Self.pinnedFiles.first(where: { $0.sha256 == Self.sha256(content) }
                    )
                else { continue }
                guard files[pinned.name] == nil, file.declaredSize == pinned.size,
                    content.count == pinned.size,
                    Self.isWindowsImage(content, library: pinned.isLibrary)
                else {
                    throw GameInputError.unrecognizedPackage
                }
                files[pinned.name] = content
            }
            guard files.count == Self.pinnedFiles.count else {
                throw GameInputError.unrecognizedPackage
            }
            self.files = files
        } catch is MalformedArchive {
            throw GameInputError.unrecognizedPackage
        }
    }

    /// Whether the prefix has the four files, unchanged.
    static func isInstalled(in prefix: URL) -> Bool {
        pinnedFiles.allSatisfy { pinned in
            let file = prefix.appending(path: "\(directory)/\(pinned.name)")
            return (try? Data(contentsOf: file)).map(sha256) == pinned.sha256
        }
    }

    /// Writes the four files into the prefix, and the registry entries of GameInput and its
    /// service into `registry`, a file for `reg import`.
    func install(into prefix: URL, registry: URL) throws {
        let directory = prefix.appending(path: Self.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: directory.appending(path: name), options: .atomic)
        }
        var encoded = Data([0xFF, 0xFE])
        encoded.append(Self.registryText.data(using: .utf16LittleEndian) ?? Data())
        try encoded.write(to: registry, options: .atomic)
    }

    static var registryText: String {
        let directory = windowsDirectory.replacing(#"\"#, with: #"\\"#)
        let imagePath = (windowsDirectory + #"\GameInputRedistService.exe"# + "\0")
            .utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            .map { String(format: "%02x", $0) }.joined(separator: ",")
        return """
            Windows Registry Editor Version 5.00

            [HKEY_LOCAL_MACHINE\\Software\\Microsoft\\GameInput]
            "RedistDir"="\(directory)"

            [HKEY_LOCAL_MACHINE\\Software\\Wow6432Node\\Microsoft\\GameInput]
            "RedistDir"="\(directory)"

            [HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\GameInputRedistService]
            "DisplayName"="GameInput Redist Service"
            "Description"="GameInput Redist Service"
            "ImagePath"=hex(2):\(imagePath)
            "ObjectName"="LocalSystem"
            "ErrorControl"=dword:00000000
            "Start"=dword:00000003
            "Type"=dword:00000010
            "PreshutdownTimeout"=dword:0002bf20

            """
    }

    /// A 64-bit Windows image, a DLL or an executable as expected.
    private static func isWindowsImage(_ content: Data, library: Bool) -> Bool {
        let image = LittleEndianBytes([UInt8](content))
        guard content.starts(with: Array("MZ".utf8)), let header = try? image.uint32(60),
            let signature = try? image.slice(header, 6),
            Array(signature) == [0x50, 0x45, 0, 0, 0x64, 0x86],
            let characteristics = try? image.uint16(header + 22)
        else {
            return false
        }
        return (characteristics & 0x2000 != 0) == library
    }

    private static func sha256(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexadecimal
    }
}

public enum GameInputError: Error, Equatable {
    /// The game ships a GameInput package other than the reviewed one.
    case unrecognizedPackage
}
