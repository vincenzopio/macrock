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

func uniqueVolumeName() -> String {
    "macrock-test-\(UUID().uuidString.prefix(8))"
}

/// Apple's own Game Porting Toolkit image, for the tests that need D3DMetal signed by Apple.
let realToolkitImage = ProcessInfo.processInfo.environment["MACROCK_GPTK_IMAGE"].map {
    URL(filePath: $0)
}
