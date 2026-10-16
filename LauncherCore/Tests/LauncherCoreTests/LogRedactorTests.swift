import LauncherCore
import Testing

struct LogRedactorTests {
    let redactor = LogRedactor(knownValues: ["SilverFox42"])

    @Test(arguments: [
        (
            "Authorization: XBL3.0 x=1234567890;eyJhbGciOiJSUzI1NiJ9.eyJ4dWkiOlt7fV19.c2ln",
            "Authorization: <redacted>"
        ),
        ("header XBL3.0 x=1234567890;opaque, next", "header XBL3.0 x=<redacted>, next"),
        ("Cookie: MSPOK=$uuid-1234; PPAuth=abc", "Cookie: <redacted>"),
        ("token eyJhbGciOiJSUzI1NiJ9.eyJ4dWkiOlt7fV19.c2lnbmF0dXJl end", "token <redacted> end"),
        (
            "POST /RST2.srf t=EwAoA+pvBAAUKods17HmdQZ6/ah1pwcRgwmnpYoAAQ&p=",
            "POST /RST2.srf t=<redacted>&p="
        ),
        (
            "<BinarySecret>AAECAwQFBgcICQoLDA0ODw==</BinarySecret>",
            "<BinarySecret><redacted></BinarySecret>"
        ),
        (
            #"<e:CipherValue Id="c">q83vEjRWeJA=</e:CipherValue>"#,
            #"<e:CipherValue Id="c"><redacted></e:CipherValue>"#
        ),
        (#""puid":"0003BFFD8A2C1E5F""#, #""puid":"<redacted>""#),
        ("signed in as someone.else@example.co.uk", "signed in as <redacted>"),
        ("xuid 2535412345678901 joined", "xuid <redacted> joined"),
        (
            "Minecraft Bedrock/Users/1234567890123456789/games/com.mojang",
            "Minecraft Bedrock/Users/<redacted>/games/com.mojang"
        ),
        (
            "refresh M.C540_BAY.0.U.-CkKj3t8YxsQl7Pq2Wn5Rz9Vb1Ma4Hd6Fg0Je2Lc8",
            "refresh M.C540_BAY.0.U.<redacted>"
        ),
        ("welcome back SilverFox42", "welcome back <redacted>"),
        (
            "key AAAAAQdPpXWd2JkZ/9rJc3VuYmZmQ2xvdWQxMjM0NTY3OA+abcDEF== end",
            "key <redacted> end"
        ),
        (
            #"0024:trace:winhttp:add_request_headers L"Authorization: XBL3.0 x=1;abc""#,
            "0024:trace:winhttp:add_request_headers L\"Authorization: <redacted>"
        ),
    ])
    func masksSecrets(line: String, expected: String) {
        #expect(redactor.redact(line) == expected)
    }

    @Test(arguments: [
        "0124:fixme:ntdll:NtQuerySystemInformation info_class SYSTEM_PERFORMANCE_INFORMATION",
        "1791466958 fps=60.0 avg_ms=16.68 max_ms=17.38 slow=0",
        #"Z:\Users\vincenzo\Library\Application Support\macrock\Minecraft.Windows.exe"#,
        "=>0 0x0000000140001000 in minecraft.windows (+0x1000) (0x000000000011fe40)",
        "sha256 43f49e615fa9d63a9ce1fd6c7e90a83c7bef0f0ef2e7e76a85056b8b69fb1496",
        "Game license for 9NBLGGH2JHXJ: active true, trial false",
        "XODUS_SOCKET=/var/folders/4v/lthmbtbj291gr8hxsgwv987c0000gn/T/macrock/5f1a0c3e.sock",
        "0024:fixme:dwmapi:DwmSetWindowAttribute (0000000000010064, 14, 000000000010F750, 4) stub",
        "0024:fixme:appx:package_manager2_FindPackagesByUserSecurityIdWithPackageTypes iface stub",
        "",
    ])
    func keepsDiagnostics(line: String) {
        #expect(redactor.redact(line) == line)
    }
}
