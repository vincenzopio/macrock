import Foundation

/// The layout of a Game Porting Toolkit 4 `redist/lib`, with D3DMetal signed ad hoc.
func makeD3DMetalLayout(at lib: URL) async throws {
    let manager = FileManager.default
    let windows = lib.appending(path: "wine/x86_64-windows")
    let unix = lib.appending(path: "wine/x86_64-unix")
    let framework = lib.appending(path: "external/D3DMetal.framework")
    for directory in [windows, unix, framework.appending(path: "Resources")] {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    for name in ["d3d12", "d3d11", "d3d10", "dxgi"] {
        try Data().write(to: windows.appending(path: "\(name).dll"))
        try manager.createSymbolicLink(
            atPath: unix.appending(path: "\(name).so").path,
            withDestinationPath: "../../external/libd3dshared.dylib")
    }
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.apple.D3DMetal", "CFBundleShortVersionString": "4.0b2",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: framework.appending(path: "Resources/Info.plist"))
    try Data().write(to: lib.appending(path: "external/libd3dshared.dylib"))
    try await runTool("/usr/bin/codesign", ["--sign", "-", framework.path])
}

/// A disk image of `folder`. Its volume takes the folder's name, so tests give each folder a
/// name of its own: two volumes with one name would mount at different paths.
func makeDiskImage(of folder: URL) async throws -> URL {
    let image = folder.appendingPathExtension("dmg")
    try await runTool(
        "/usr/sbin/diskutil",
        ["image", "create", "from", "--format", "UDZO", folder.path, image.path])
    return image
}

/// Gives `image` a license agreement in US English whose text `diskutil` can read, so that it
/// shows the agreement only in a terminal.
func addLicenseAgreement(to image: URL) async throws {
    func resource(_ data: Data) -> [String: Any] {
        ["Attributes": "0x0000", "Data": data, "ID": "5000", "Name": "English"]
    }
    // The default language, then one language: US English, whose resources have ID 5000.
    let languages = Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
    let labels = [
        "English", "Agree", "Disagree", "Print", "Save...", "Click Agree to attach the image.",
        "License Agreement", "The text can't be saved.", "The text can't be printed.",
    ]
    var strings = Data([0, UInt8(labels.count)])
    for label in labels {
        strings.append(UInt8(label.utf8.count))
        strings.append(contentsOf: label.utf8)
    }
    let resources: [String: Any] = [
        "LPic": [resource(languages)], "STR#": [resource(strings)],
        "TEXT": [resource(Data("macrock test license".utf8))],
    ]
    let file = image.deletingPathExtension().appendingPathExtension("resources.plist")
    try PropertyListSerialization.data(fromPropertyList: resources, format: .xml, options: 0)
        .write(to: file)
    // `udifrez` is deprecated, but nothing else embeds resources in an image.
    try await runTool("/usr/bin/hdiutil", ["udifrez", "-xml", file.path, "", "-quiet", image.path])
}

func uniqueVolumeName() -> String {
    "macrock-test-\(UUID().uuidString.prefix(8))"
}

/// Apple's own Game Porting Toolkit image, for the tests that need D3DMetal signed by Apple.
let realToolkitImage = ProcessInfo.processInfo.environment["MACROCK_GPTK_IMAGE"].map {
    URL(filePath: $0)
}
