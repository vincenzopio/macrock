import CoreGraphics
import SwiftUI

/// A bitmap drawn pixel by pixel. Colours are 0xRRGGBB; pixels never set stay transparent.
struct PixelCanvas {
    let width: Int
    let height: Int
    private var pixels: [UInt32]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = Array(repeating: 0, count: width * height)
    }

    mutating func set(_ x: Int, _ y: Int, _ colour: UInt32) {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return }
        pixels[y * width + x] = 0xFF00_0000 | colour
    }

    var image: CGImage {
        let bytes = pixels.flatMap { pixel -> [UInt8] in
            let alpha = UInt8(pixel >> 24)
            return [
                UInt8(pixel >> 16 & 0xFF), UInt8(pixel >> 8 & 0xFF), UInt8(pixel & 0xFF), alpha,
            ]
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            preconditionFailure("an RGBA buffer of the declared size always makes an image")
        }
        return image
    }
}

/// SplitMix64: the same seed draws the same picture on every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The launcher's artwork, drawn in code: no texture of Mojang's is used.
enum Artwork {
    static let dirt = noise([0x2A2119, 0x302519, 0x241B13, 0x1C150F, 0x3A2C1F], size: 16, seed: 1)
    static let stone = noise([0x7F7F7F, 0x8C8C8C, 0x737373, 0x666666, 0x595959], size: 16, seed: 2)
    static let amethyst = noise(
        [0x8E5FC9, 0x6B3FA0, 0xA77FE0, 0x5A2E8A, 0xC4A2F0], size: 16, seed: 6)
    static let landscape = drawLandscape(width: 200, height: 120)
    static let check = sprite(
        [
            "........#",
            ".......##",
            "#.....##.",
            "##...##..",
            ".##.##...",
            "..###....",
            "...#.....",
        ], ["#": 0x55FF55])
    static let cross = sprite(
        [
            "##...##",
            ".##.##.",
            "..###..",
            "..###..",
            ".##.##.",
            "##...##",
        ], ["#": 0xFF5555])
    static let exclamation = sprite(["##", "##", "##", "##", "..", "##"], ["#": 0xFFAA00])
    static let arrowDown = sprite(["#####", ".###.", "..#.."], ["#": 0xB1B2B5])
    static let arrowUp = sprite(["..#..", ".###.", "#####"], ["#": 0xB1B2B5])
    static let arrowLeft = sprite(["..#", ".##", "###", ".##", "..#"], ["#": 0xFFFFFF])
    static let copy = sprite(
        [
            "OOOOOOOO....",
            "OwwwwwwO....",
            "OwwwwwwO....",
            "OwwOOOOOOOOO",
            "OwwOWWWWWWWO",
            "OwwOWlllllWO",
            "OwwOWWWWWWWO",
            "OwwOWlllllWO",
            "OOOOWWWWWWWO",
            "...OWlllWWWO",
            "...OWWWWWWWO",
            "...OOOOOOOOO",
        ], ["O": 0x1E1E1F, "w": 0xA0A1A4, "W": 0xE6E6E8, "l": 0x8C8D90])
    static let folder = sprite(
        [
            "............",
            "OOOOO.......",
            "OwwwwO......",
            "OwwwwwOOOOOO",
            "OwwwwwwwwwwO",
            "OOOOOOOOOOOO",
            "OWWWWWWWWWWO",
            "OWWWWWWWWWWO",
            "OWWWWWWWWWWO",
            "OWWWWWWWWWWO",
            "OOOOOOOOOOOO",
            "............",
        ], ["O": 0x1E1E1F, "w": 0xA0A1A4, "W": 0xE6E6E8])
    static let trash = sprite(
        [
            "....OOOO....",
            "....O..O....",
            "OOOOOOOOOOOO",
            "OLLLLLLLLLLO",
            "OOOOOOOOOOOO",
            ".OLLlLLlLLO.",
            ".OLLlLLlLLO.",
            ".OLLlLLlLLO.",
            ".OLLlLLlLLO.",
            ".OLLlLLlLLO.",
            ".OLLlLLlLLO.",
            "..OOOOOOOO..",
        ], ["O": 0x1E1E1F, "L": 0xD0D1D4, "l": 0x8C8D90])
    static let grassBlock = drawGrassBlock(size: 16)
    static let disc = drawDisc(size: 16)
    static let chest = sprite(
        [
            ".OOOOOOOOOOOOOO.",
            "OppppppppppppppO",
            "OpPPPPPPPPPPPPdO",
            "OpPPPPPPPPPPPPdO",
            "OpPPPPPPPPPPPPdO",
            "OOOOOOOLLOOOOOOO",
            "OpPPPPPLlPPPPPdO",
            "OpPPPPPPPPPPPPdO",
            "OpPPPPPPPPPPPPdO",
            "OpPPPPPPPPPPPPdO",
            "OpPPPPPPPPPPPPdO",
            "OddddddddddddddO",
            ".OOOOOOOOOOOOOO.",
        ],
        [
            "O": 0x2B1A0B, "p": 0xB98339, "P": 0x95622A, "d": 0x6B4420, "L": 0xC9C9C9,
            "l": 0x8A8A8A,
        ])

    /// Each character a colour of `palette`; the others stay transparent.
    private static func sprite(_ rows: [String], _ palette: [Character: UInt32]) -> CGImage {
        var canvas = PixelCanvas(width: rows[0].count, height: rows.count)
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() {
                if let colour = palette[pixel] { canvas.set(x, y, colour) }
            }
        }
        return canvas.image
    }

    /// A face for an account, the same every time for the same account: hair, skin and eyes
    /// drawn from its ID.
    static func head(for id: UUID) -> CGImage {
        var random = SeededGenerator(
            seed: withUnsafeBytes(of: id.uuid) { $0.loadUnaligned(as: UInt64.self) })
        let hairs: [UInt32] = [0x3B2A1A, 0x6B4423, 0xD9B45A, 0x1E1E1E, 0xA33A2A]
        let skins: [UInt32] = [0xF1C9A5, 0xE0AC7E, 0xC68863, 0x8D5A3B]
        let eyes: [UInt32] = [0x2E5DB8, 0x3D7A3A, 0x5B3A1E, 0x4B4B4B]
        return sprite(
            [
                "hhhhhhhh",
                "hhhhhhhh",
                "hssssssh",
                "ssssssss",
                "swessews",
                "ssssssss",
                "sssmmsss",
                "ssssssss",
            ],
            [
                "h": hairs.randomElement(using: &random) ?? 0,
                "s": skins.randomElement(using: &random) ?? 0,
                "e": eyes.randomElement(using: &random) ?? 0, "w": 0xFFFFFF, "m": 0x6B3A2A,
            ])
    }

    /// The side of a grass block: grass that runs down unevenly into dirt.
    private static func drawGrassBlock(size: Int) -> CGImage {
        var random = SeededGenerator(seed: 5)
        var canvas = PixelCanvas(width: size, height: size)
        let grass: [UInt32] = [0x5EA236, 0x6DB33F, 0x4F8F2C]
        let dirt: [UInt32] = [0x866043, 0x9B7653, 0x79553A, 0x593D29]
        for x in 0..<size {
            let depth = Int.random(in: 3...5, using: &random)
            for y in 0..<size {
                let colours = y < depth ? grass : dirt
                canvas.set(x, y, colours.randomElement(using: &random) ?? 0)
            }
        }
        return canvas.image
    }

    private static func drawDisc(size: Int) -> CGImage {
        var canvas = PixelCanvas(width: size, height: size)
        let centre = Double(size - 1) / 2
        for y in 0..<size {
            for x in 0..<size {
                let distance = hypot(Double(x) - centre, Double(y) - centre)
                let colour: UInt32? =
                    switch distance {
                    case ..<1: 0x0F0F10
                    case ..<2.6: 0xC94B3B
                    case ..<6.6: Int(distance) % 2 == 0 ? 0x2B2B2D : 0x1C1C1E
                    case ..<7.7: 0x0F0F10
                    default: nil
                    }
                if let colour { canvas.set(x, y, colour) }
            }
        }
        return canvas.image
    }

    private static func noise(_ colours: [UInt32], size: Int, seed: UInt64) -> CGImage {
        var random = SeededGenerator(seed: seed)
        var canvas = PixelCanvas(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size { canvas.set(x, y, colours.randomElement(using: &random) ?? 0) }
        }
        return canvas.image
    }

    /// A valley at dusk over a cut through the ground: grass, dirt, stone with ores, bedrock.
    private static func drawLandscape(width: Int, height: Int) -> CGImage {
        var random = SeededGenerator(seed: 7)
        var canvas = PixelCanvas(width: width, height: height)
        let sky: [UInt32] = [0x1B2440, 0x24305A, 0x334576, 0x4B5E92, 0x6F7FAE, 0xA28FA6, 0xD6A27E]
        for y in 0..<height {
            let band = sky[min(sky.count - 1, y * sky.count / (height / 2))]
            for x in 0..<width { canvas.set(x, y, band) }
        }
        for _ in 0..<5 {
            let x = Int.random(in: 0..<width, using: &random)
            let y = Int.random(in: 6..<28, using: &random)
            let length = Int.random(in: 12..<30, using: &random)
            for dx in 0..<length { canvas.set(x + dx, y, 0xC9B7C6) }
            for dx in 3..<(length - 4) { canvas.set(x + dx, y - 1, 0xDCCAD3) }
        }

        let far = ridge(width: width, base: 54, amplitude: 9, seed: 11)
        let near = ridge(width: width, base: 68, amplitude: 6, seed: 12)
        for x in 0..<width {
            for y in far[x]..<height { canvas.set(x, y, 0x3E5A62) }
            for y in near[x]..<height { canvas.set(x, y, 0x2F4A3A) }
        }

        let ground = 82
        let layers: [(depth: Int, colours: [UInt32])] = [
            (3, [0x5EA236, 0x6DB33F, 0x4F8F2C]),
            (8, [0x866043, 0x9B7653, 0x79553A, 0x593D29]),
            (18, [0x7F7F7F, 0x8C8C8C, 0x737373, 0x666666]),
            (height, [0x575757, 0x343434, 0x1E1E1E, 0x454545]),
        ]
        for x in 0..<width {
            var y = ground + Int.random(in: 0...1, using: &random)
            for layer in layers {
                let bottom = min(height, y + layer.depth)
                while y < bottom {
                    canvas.set(x, y, layer.colours.randomElement(using: &random) ?? 0)
                    y += 1
                }
            }
        }
        for _ in 0..<14 {
            let x = Int.random(in: 0..<(width - 2), using: &random)
            let y = Int.random(in: (ground + 12)..<(ground + 28), using: &random)
            let ore: UInt32 = [0x3BD4CF, 0xE3C34A, 0xC94B3B].randomElement(using: &random) ?? 0
            canvas.set(x, y, ore)
            canvas.set(x + 1, y + 1, ore)
        }
        return canvas.image
    }

    private static func ridge(width: Int, base: Int, amplitude: Double, seed: UInt64) -> [Int] {
        var random = SeededGenerator(seed: seed)
        let phases = (0..<3).map { _ in Double.random(in: 0..<(2 * .pi), using: &random) }
        return (0..<width).map { x in
            let t = Double(x) / Double(width) * 2 * .pi
            let height =
                sin(t * 1.3 + phases[0]) + 0.6 * sin(t * 3.1 + phases[1]) + 0.3
                * sin(t * 7 + phases[2])
            return base - Int((height * amplitude / 1.9).rounded())
        }
    }
}

/// Pixel art at any size, without smoothing.
struct PixelImage: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1).resizable().interpolation(.none)
    }
}

extension View {
    /// The ground behind the pages that list things, darkened so that their panels come first.
    func dirtBackground() -> some View {
        background {
            Rectangle()
                .fill(
                    ImagePaint(
                        image: Image(decorative: Artwork.dirt, scale: 0.25).interpolation(.none))
                )
                .overlay(Palette.ink.opacity(0.6))
        }
    }
}
