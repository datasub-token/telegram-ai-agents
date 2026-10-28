import Foundation

// A port of the timing and glyph logic of ascii-reveal (github.com/quanhoangindex/ascii-reveal, MIT). Pure and
// deterministic: the same seed always plays the same reveal, so it can be tested on the host.

/// The glyphs and pace of one look of the effect.
public struct AsciiPresetSpec: Equatable {
    public enum ColorMode: Equatable {
        case mono
        case source
        case accent
    }

    /// From empty to dense, with a space first.
    public let ramp: [Character]
    /// What a character shows while it scrambles.
    public let scramble: [Character]
    /// The ramp condenses towards the real glyph before scrambling; otherwise it scrambles the whole time.
    public let condensesRamp: Bool
    public let colorMode: ColorMode
    /// Image cell sizes in points, coarse to fine.
    public let cells: [Double]
    /// Milliseconds between glyph changes.
    public let tickMs: Double
    public let cursor: Character?
    public let accentGlyphs: Bool

    public static let decode = AsciiPresetSpec(ramp: Array(" .:-=+*#%@"), scramble: Array("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789#%&*+=?/"), condensesRamp: true, colorMode: .mono, cells: [24, 16, 11, 8, 6], tickMs: 60, cursor: nil, accentGlyphs: false)
    public static let dither = AsciiPresetSpec(ramp: Array(" ░▒▓█"), scramble: Array("░▒▓█"), condensesRamp: true, colorMode: .source, cells: [20, 14, 10, 7, 5], tickMs: 85, cursor: nil, accentGlyphs: false)
    public static let terminal = AsciiPresetSpec(ramp: Array(" .-:=+*#"), scramble: Array("01<>/\\{}[]|_=+-;:"), condensesRamp: false, colorMode: .mono, cells: [22, 15, 10, 7, 6], tickMs: 40, cursor: "█", accentGlyphs: false)
    public static let blueprint = AsciiPresetSpec(ramp: Array(" ·-+=x#"), scramble: Array("+-/\\|x·"), condensesRamp: false, colorMode: .accent, cells: [26, 18, 13, 9, 7], tickMs: 95, cursor: nil, accentGlyphs: true)
}

public enum AsciiPaceSpec: Equatable {
    case fast
    case cinematic

    /// Wave speed in points per millisecond and the cap on its delay.
    var wave: (velocity: Double, maxDelayMs: Double) {
        switch self {
        case .fast:
            return (3.2, 220.0)
        case .cinematic:
            return (1.15, Double.infinity)
        }
    }

    /// How long an image takes, in milliseconds.
    public var mediaDurationMs: Double {
        switch self {
        case .fast:
            return 450.0
        case .cinematic:
            return 1150.0
        }
    }
}

/// A uniform number in 0..<1 for a seed and an index.
public func asciiHash(_ seed: UInt64, _ index: Int) -> Double {
    var z = seed &+ UInt64(bitPattern: Int64(index)) &* 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    z = z ^ (z >> 31)
    return Double(z >> 11) / Double(UInt64(1) << 53)
}

/// The delay before a target at `distance` points from the origin starts.
public func asciiWaveDelay(distance: Double, pace: AsciiPaceSpec, speed: Double = 1.0) -> Double {
    let wave = pace.wave
    return min(distance / (wave.velocity * max(0.01, speed)), wave.maxDelayMs)
}

/// When each character of a text starts and locks.
public struct AsciiTextSchedule: Equatable {
    public enum GlyphState: Equatable {
        case hidden
        case cursor
        case glyph(Character)
        /// The real glyph, with how much of the flash colour is left (1 → 0 over 420 ms).
        case locked(flash: Double)
    }

    public let count: Int
    public let seed: UInt64
    /// Milliseconds.
    public let starts: [Double]
    public let ends: [Double]

    public static let flashMs: Double = 420.0

    public init(count: Int, seed: UInt64, pace: AsciiPaceSpec, delayMs: Double = 0.0, speed: Double = 1.0) {
        self.count = count
        self.seed = seed
        let scale = 1.0 / max(0.01, speed)
        let n = Double(max(1, count))
        let spread: Double
        let base: Double
        let random: Double
        switch pace {
        case .fast:
            spread = min(200.0, 40.0 + n * 4.0)
            base = 90.0
            random = 110.0
        case .cinematic:
            spread = min(720.0, 90.0 + n * 13.0)
            base = 200.0
            random = 240.0
        }
        var starts: [Double] = []
        var ends: [Double] = []
        for k in 0 ..< count {
            let start = delayMs + ((Double(k) / n) * spread * 0.72 + asciiHash(seed, k) * spread * 0.28) * scale
            starts.append(start)
            ends.append(start + (base + asciiHash(seed &+ 1, k) * random) * scale)
        }
        self.starts = starts
        self.ends = ends
    }

    /// When the last character locks.
    public var durationMs: Double {
        return self.ends.max() ?? 0.0
    }

    public func state(index k: Int, timeMs t: Double, preset: AsciiPresetSpec, isNumeric: Bool = false) -> GlyphState {
        guard k >= 0, k < self.count else {
            return .hidden
        }
        let s0 = self.starts[k]
        let s1 = self.ends[k]
        if t < s0 {
            return .hidden
        }
        if t >= s1 {
            return .locked(flash: max(0.0, 1.0 - (t - s1) / AsciiTextSchedule.flashMs))
        }
        let q = (t - s0) / max(1.0, s1 - s0)
        if preset.cursor != nil && q < 0.2 {
            return .cursor
        }
        let tick = Int(floor((t + asciiHash(self.seed &+ 2, k) * preset.tickMs) / preset.tickMs))
        if preset.condensesRamp && q < 0.7 && !isNumeric && preset.ramp.count > 2 {
            let count = preset.ramp.count
            var index = 1 + Int(floor((q / 0.7) * Double(count - 1)))
            let jitter = asciiHash(self.seed &+ 3, k &* 131 &+ tick)
            if jitter < 0.35 {
                index += jitter < 0.175 ? -1 : 1
            }
            index = max(1, min(count - 1, index))
            return .glyph(preset.ramp[index])
        }
        if isNumeric {
            let digits = Array("0123456789")
            return .glyph(digits[Int(asciiHash(self.seed &+ 4, k &* 7919 &+ tick) * Double(digits.count)) % digits.count])
        }
        let scramble = preset.scramble
        return .glyph(scramble[Int(asciiHash(self.seed &+ 4, k &* 7919 &+ tick) * Double(scramble.count)) % scramble.count])
    }
}

/// The image half of the effect: which cell size, which cells and which glyphs at progress `q` (0...1).
public enum AsciiImageMath {
    /// The cell size step, coarse to fine.
    public static func step(q: Double, stepCount: Int) -> Int {
        guard stepCount > 0 else {
            return 0
        }
        return min(stepCount - 1, max(0, Int(floor((q / 0.8) * Double(stepCount)))))
    }

    /// Cell sizes scale with the image so a small preview isn't all big blocks.
    public static func cellScale(width: Double, height: Double) -> Double {
        return max(0.4, min(1.0, min(width, height) / 230.0))
    }

    public static func isCellVisible(hash: Double, distance: Double, maxDistance: Double, q: Double) -> Bool {
        let gate = 0.5 * hash + 0.5 * (maxDistance > 0.0 ? distance / maxDistance : 0.0)
        return gate <= q * 2.3
    }

    /// How much a cell stands out from the background, 0...1.
    public static func ink(luminance: Double, backgroundLuminance: Double) -> Double {
        return abs(luminance - backgroundLuminance) / max(backgroundLuminance, 1.0 - backgroundLuminance, 0.0001)
    }

    /// The ramp glyph for a cell's ink, or nil for an empty cell.
    public static func glyphIndex(ink: Double, flicker: Double?, rampCount: Int) -> Int? {
        guard ink >= 0.04, rampCount > 1 else {
            return nil
        }
        var level = ink * 1.15
        if let flicker {
            level += (flicker - 0.5) * 0.35
        }
        let index = Int((max(0.0, min(1.0, level)) * Double(rampCount - 1)).rounded())
        return index == 0 ? nil : index
    }

    public static func imageOpacity(q: Double) -> Double {
        guard q > 0.68 else {
            return 0.0
        }
        return easeInOut((q - 0.68) / 0.32)
    }

    public static func glyphOpacity(q: Double) -> Double {
        guard q > 0.74 else {
            return 1.0
        }
        return max(0.0, 1.0 - (q - 0.74) / 0.26)
    }

    public static func luminance(r: Double, g: Double, b: Double) -> Double {
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

/// The loading placeholder: a light band sweeping across rows of glyphs.
public enum AsciiSkeletonMath {
    public static let cycle: Double = 1.8
    public static let rowStagger: Double = 0.09
    public static let bandFraction: Double = 0.45
    public static let strips = 16
    public static let flickerSeconds: Double = 0.12

    /// The band's left edge for `row` at `time` seconds, in a row `width` wide.
    public static func bandX(time: Double, row: Int, width: Double) -> Double {
        let bandWidth = width * self.bandFraction
        var phase = (time - Double(row) * self.rowStagger).truncatingRemainder(dividingBy: self.cycle) / self.cycle
        if phase < 0.0 {
            phase += 1.0
        }
        return (width - bandWidth) * (-1.2 + 3.4 * easeInOut(phase))
    }

    /// The opacity of strip `m` (0...1 across the band): fades in over 45 %, solid for 10 %, fades out over 45 %.
    public static func stripAlpha(_ m: Double) -> Double {
        if m < 0.45 {
            return m / 0.45
        } else if m > 0.55 {
            return max(0.0, (1.0 - m) / 0.45)
        } else {
            return 1.0
        }
    }

    /// How bright the glyph at `x` is: the band's strips over a dim base.
    public static func brightness(x: Double, bandX: Double, width: Double) -> Double {
        let bandWidth = width * self.bandFraction
        guard bandWidth > 0.0, x >= bandX, x <= bandX + bandWidth else {
            return 0.0
        }
        let m = (x - bandX) / bandWidth
        let strip = (floor(m * Double(self.strips)) + 0.5) / Double(self.strips)
        return self.stripAlpha(strip) * 0.9
    }

    public static func flickerFrame(time: Double) -> Int {
        return Int(floor(time / self.flickerSeconds)) % 2
    }
}

/// The live code card: the newest line scrambles briefly before it locks, and a block cursor blinks.
public enum AsciiTypingMath {
    public static let scrambleSeconds: Double = 0.15
    public static let cursorBlinkSeconds: Double = 0.53

    public static func isCursorVisible(time: Double) -> Bool {
        return Int(floor(time / self.cursorBlinkSeconds)) % 2 == 0
    }

    /// How much of a line that appeared `elapsed` seconds ago is locked, 0...1.
    public static func lockedFraction(elapsed: Double) -> Double {
        return max(0.0, min(1.0, elapsed / self.scrambleSeconds))
    }
}

/// An ease-in-out close to cubic-bezier(.45,.05,.55,.95).
public func easeInOut(_ t: Double) -> Double {
    let t = max(0.0, min(1.0, t))
    return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0
}
