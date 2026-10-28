import Foundation
import UIKit
import CoreText
import Display
import AsciiRevealCore

// The views of the ASCII reveal effect, a port of ascii-reveal (github.com/quanhoangindex/ascii-reveal, MIT). They draw
// with Core Graphics at ~30 fps, and only while an effect runs and the view is in a window.

/// The four looks of the effect, after the ascii-reveal presets.
public enum AsciiRevealPreset: Equatable {
    /// Light-to-dense glyphs condensing into letters (" .:-=+*#%@").
    case decode
    /// Shaded blocks (" ░▒▓█").
    case dither
    /// Code-like glyphs with a block cursor.
    case terminal
    /// Thin construction glyphs (" ·-+=x#") in the accent colour.
    case blueprint

    var spec: AsciiPresetSpec {
        switch self {
        case .decode:
            return .decode
        case .dither:
            return .dither
        case .terminal:
            return .terminal
        case .blueprint:
            return .blueprint
        }
    }
}

public enum AsciiRevealPace: Equatable {
    /// Readable within ~0.4 s.
    case fast
    /// Slower, for a moment that deserves attention (~1.15 s for an image).
    case cinematic

    var spec: AsciiPaceSpec {
        switch self {
        case .fast:
            return .fast
        case .cinematic:
            return .cinematic
        }
    }
}

/// Global switch. When off (the concept switch is off, or Reduce Motion is on) every reveal becomes a short fade and
/// skeletons stand still.
public enum AsciiRevealSettings {
    public static var isEnabled: Bool = true
}

/// Runs a callback ~30 times a second while asked to.
private final class AsciiFrameDriver {
    private var link: SharedDisplayLinkDriver.Link?
    private let update: () -> Void

    init(update: @escaping () -> Void) {
        self.update = update
    }

    deinit {
        self.link?.invalidate()
    }

    var isRunning: Bool {
        get {
            return self.link != nil
        }
        set {
            if newValue && self.link == nil {
                self.link = SharedDisplayLinkDriver.shared.add(framesPerSecond: .fps(30), { [weak self] _ in
                    self?.update()
                })
            } else if !newValue, let link = self.link {
                link.invalidate()
                self.link = nil
            }
        }
    }
}

private func monospacedFont(size: CGFloat) -> UIFont {
    return UIFont.monospacedSystemFont(ofSize: max(4.0, size), weight: .regular)
}

private func drawGlyph(_ character: Character, in rect: CGRect, font: UIFont, color: UIColor) {
    let string = NSAttributedString(string: String(character), attributes: [.font: font, .foregroundColor: color])
    let size = string.size()
    string.draw(at: CGPoint(x: rect.midX - size.width / 2.0, y: rect.midY - size.height / 2.0))
}

// MARK: - Text

/// A label that draws its own text and can reveal it glyph by glyph through the ASCII effect.
public final class AsciiTextRevealView: UIView {
    private struct Grapheme {
        let range: NSRange
        let rect: CGRect
        let isWhitespace: Bool
    }

    private var text: NSAttributedString = NSAttributedString()
    private var graphemes: [Grapheme] = []
    private var layoutSize: CGSize = CGSize()

    private var schedule: AsciiTextSchedule?
    private var preset: AsciiPresetSpec = .decode
    private var flashColor: UIColor?
    private var startTime: Double = 0.0
    private var completion: (() -> Void)?
    private lazy var driver = AsciiFrameDriver(update: { [weak self] in
        self?.frameUpdated()
    })

    public private(set) var isRevealing: Bool = false

    override public init(frame: CGRect) {
        super.init(frame: frame)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.contentMode = .redraw
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Sets the text. While no reveal runs it is drawn as is, starting at the view's top left corner.
    public func update(text: NSAttributedString, size: CGSize) {
        if !self.text.isEqual(to: text) || self.layoutSize != size {
            self.text = text
            self.layoutSize = size
            self.graphemes = AsciiTextRevealView.graphemes(text: text, size: size)
            self.setNeedsDisplay()
        }
    }

    private static func graphemes(text: NSAttributedString, size: CGSize) -> [Grapheme] {
        guard text.length != 0 else {
            return []
        }
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1.0, size.width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0.0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        var result: [Grapheme] = []
        let string = text.string as NSString
        var index = 0
        while index < string.length {
            let range = string.rangeOfComposedCharacterSequence(at: index)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let substring = string.substring(with: range)
            result.append(Grapheme(range: range, rect: rect, isWhitespace: substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            index = range.location + range.length
        }
        return result
    }

    /// Plays the reveal from nothing to the real text. `completion` runs on the main queue.
    public func playReveal(preset: AsciiRevealPreset = .decode, pace: AsciiRevealPace = .fast, flashColor: UIColor? = nil, completion: (() -> Void)? = nil) {
        guard AsciiRevealSettings.isEnabled, !self.graphemes.isEmpty else {
            if !AsciiRevealSettings.isEnabled {
                self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
            completion?()
            return
        }
        let visible = self.graphemes.filter { !$0.isWhitespace }.count
        self.schedule = AsciiTextSchedule(count: max(1, visible), seed: UInt64(truncatingIfNeeded: self.text.string.hashValue), pace: pace.spec)
        self.preset = preset.spec
        self.flashColor = flashColor
        self.startTime = CACurrentMediaTime()
        self.completion = completion
        self.isRevealing = true
        self.driver.isRunning = self.window != nil
        self.setNeedsDisplay()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if self.isRevealing {
            self.driver.isRunning = self.window != nil
        }
    }

    private func frameUpdated() {
        guard let schedule = self.schedule else {
            self.driver.isRunning = false
            return
        }
        let elapsedMs = (CACurrentMediaTime() - self.startTime) * 1000.0
        if elapsedMs > schedule.durationMs + AsciiTextSchedule.flashMs {
            self.schedule = nil
            self.isRevealing = false
            self.driver.isRunning = false
            let completion = self.completion
            self.completion = nil
            completion?()
        }
        self.setNeedsDisplay()
    }

    override public func draw(_ rect: CGRect) {
        guard let schedule = self.schedule, self.isRevealing else {
            self.text.draw(with: CGRect(origin: CGPoint(), size: CGSize(width: max(1.0, self.layoutSize.width), height: CGFloat.greatestFiniteMagnitude)), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            return
        }
        let elapsedMs = (CACurrentMediaTime() - self.startTime) * 1000.0
        var visibleIndex = 0
        for grapheme in self.graphemes {
            if grapheme.isWhitespace {
                continue
            }
            let index = visibleIndex
            visibleIndex += 1
            let attributes = self.text.attributes(at: grapheme.range.location, effectiveRange: nil)
            let font = attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 15.0)
            let color = attributes[.foregroundColor] as? UIColor ?? .black
            switch schedule.state(index: index, timeMs: elapsedMs, preset: self.preset) {
            case .hidden:
                break
            case .cursor:
                if let cursor = self.preset.cursor {
                    drawGlyph(cursor, in: grapheme.rect, font: monospacedFont(size: font.pointSize), color: self.flashColor ?? color)
                }
            case let .glyph(character):
                drawGlyph(character, in: grapheme.rect, font: monospacedFont(size: font.pointSize * 0.95), color: color.withAlphaComponent(0.55))
            case let .locked(flash):
                var drawColor = color
                if let flashColor = self.flashColor, flash > 0.0 {
                    drawColor = flashColor.mixedWith(color, alpha: CGFloat(1.0 - flash))
                }
                var lockedAttributes = attributes
                lockedAttributes[.foregroundColor] = drawColor
                NSAttributedString(string: (self.text.string as NSString).substring(with: grapheme.range), attributes: lockedAttributes).draw(at: grapheme.rect.origin)
            }
        }
    }
}

// MARK: - Image

/// Shows an image and can reveal it through an ASCII grid that refines from coarse to fine cells, then cross-fades into
/// the image.
public final class AsciiImageRevealView: UIView {
    private struct Cell {
        let index: Int
        let rect: CGRect
        let glyph: Int
        let color: UIColor
        let gateHash: Double
        let distance: Double
    }

    private let imageLayer = CALayer()
    private let glyphView = AsciiImageGlyphView()
    private var image: UIImage?
    private var glyphColor: UIColor = .gray
    private var size: CGSize = CGSize()
    private var preset: AsciiPresetSpec = .dither
    private var steps: [[Cell]] = []
    private var maxDistance: Double = 1.0
    private var duration: Double = 1.15
    private var startTime: Double?
    private var drivenProgress: CGFloat?
    private var completion: (() -> Void)?
    private lazy var driver = AsciiFrameDriver(update: { [weak self] in
        self?.frameUpdated()
    })

    override public init(frame: CGRect) {
        super.init(frame: frame)
        self.clipsToBounds = true
        self.imageLayer.contentsGravity = .resizeAspectFill
        self.layer.addSublayer(self.imageLayer)
        self.addSubview(self.glyphView)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(image: UIImage?, size: CGSize, glyphColor: UIColor, backgroundColor: UIColor, cornerRadius: CGFloat) {
        self.image = image
        self.size = size
        self.glyphColor = glyphColor
        self.imageLayer.contents = image?.cgImage
        self.imageLayer.frame = CGRect(origin: CGPoint(), size: size)
        self.glyphView.frame = CGRect(origin: CGPoint(), size: size)
        self.backgroundColor = backgroundColor
        self.layer.cornerRadius = cornerRadius
    }

    /// Plays the reveal. `origin` is where the wave starts, in the view's coordinates (the centre by default).
    public func playReveal(preset: AsciiRevealPreset = .dither, pace: AsciiRevealPace = .cinematic, origin: CGPoint? = nil, completion: (() -> Void)? = nil) {
        guard AsciiRevealSettings.isEnabled, let image = self.image else {
            self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
            completion?()
            return
        }
        self.preset = preset.spec
        self.prepare(image: image, origin: origin ?? CGPoint(x: self.size.width / 2.0, y: self.size.height / 2.0))
        self.duration = pace.spec.mediaDurationMs / 1000.0
        self.startTime = CACurrentMediaTime()
        self.completion = completion
        self.render(q: 0.0)
        self.driver.isRunning = true
    }

    /// Drives the reveal by progress (0...1) instead of time, e.g. while a step is building the image. `nil` shows the
    /// plain image.
    public func setProgress(_ progress: CGFloat?) {
        self.drivenProgress = progress
        guard let progress, let image = self.image else {
            self.imageLayer.opacity = 1.0
            self.glyphView.reset(ramp: self.preset.ramp)
            return
        }
        if self.steps.isEmpty {
            self.prepare(image: image, origin: CGPoint(x: self.size.width / 2.0, y: self.size.height / 2.0))
        }
        self.render(q: Double(progress))
    }

    private func prepare(image: UIImage, origin: CGPoint) {
        guard let cgImage = image.cgImage, self.size.width > 0.0, self.size.height > 0.0 else {
            self.steps = []
            return
        }
        // Sample the image once at 1 px per point.
        let width = max(1, Int(self.size.width))
        let height = max(1, Int(self.size.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buffer in
            if let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        func sample(_ x: Double, _ y: Double) -> (lum: Double, r: Double, g: Double, b: Double) {
            let px = max(0, min(width - 1, Int(x)))
            let py = max(0, min(height - 1, height - 1 - Int(y)))
            let offset = (py * width + px) * 4
            let r = Double(pixels[offset]) / 255.0
            let g = Double(pixels[offset + 1]) / 255.0
            let b = Double(pixels[offset + 2]) / 255.0
            return (AsciiImageMath.luminance(r: r, g: g, b: b), r, g, b)
        }
        // The background is what the image's corners are.
        let corners = [sample(1, 1), sample(Double(width - 2), 1), sample(1, Double(height - 2)), sample(Double(width - 2), Double(height - 2))]
        let backgroundLuminance = corners.map(\.lum).reduce(0.0, +) / Double(corners.count)

        let cellScale = AsciiImageMath.cellScale(width: Double(self.size.width), height: Double(self.size.height))
        let rampCount = self.preset.ramp.count
        self.maxDistance = Double(hypot(max(origin.x, self.size.width - origin.x), max(origin.y, self.size.height - origin.y)))
        var steps: [[Cell]] = []
        for (stepIndex, cellSize) in self.preset.cells.enumerated() {
            let cell = max(3.0, cellSize * cellScale)
            var cells: [Cell] = []
            var y = 0.0
            var row = 0
            while y < Double(self.size.height) {
                var x = 0.0
                var column = 0
                while x < Double(self.size.width) {
                    let points = [(x + cell / 2.0, y + cell / 2.0), (x + cell / 3.0, y + cell / 3.0), (x + 2.0 * cell / 3.0, y + cell / 3.0), (x + cell / 3.0, y + 2.0 * cell / 3.0), (x + 2.0 * cell / 3.0, y + 2.0 * cell / 3.0)]
                    var bestInk = 0.0
                    var bestColor = (r: 0.5, g: 0.5, b: 0.5)
                    for point in points {
                        let value = sample(point.0, point.1)
                        let ink = AsciiImageMath.ink(luminance: value.lum, backgroundLuminance: backgroundLuminance)
                        if ink > bestInk {
                            bestInk = ink
                            bestColor = (value.r, value.g, value.b)
                        }
                    }
                    let index = stepIndex &* 100_003 &+ row &* 1_009 &+ column
                    let flicker: Double? = asciiHash(17, index) < 0.16 ? asciiHash(23, index) : nil
                    if let glyph = AsciiImageMath.glyphIndex(ink: bestInk, flicker: flicker, rampCount: rampCount) {
                        let rect = CGRect(x: x, y: y, width: cell, height: cell)
                        let color: UIColor
                        switch self.preset.colorMode {
                        case .source:
                            color = UIColor(red: CGFloat(bestColor.r), green: CGFloat(bestColor.g), blue: CGFloat(bestColor.b), alpha: 1.0)
                        case .mono, .accent:
                            color = self.glyphColor
                        }
                        cells.append(Cell(index: cells.count, rect: rect, glyph: glyph, color: color, gateHash: asciiHash(31, index), distance: Double(hypot(rect.midX - origin.x, rect.midY - origin.y))))
                    }
                    x += cell
                    column += 1
                }
                y += cell
                row += 1
            }
            steps.append(cells)
        }
        self.steps = steps
        self.glyphView.reset(ramp: self.preset.ramp)
    }

    private func frameUpdated() {
        guard let startTime = self.startTime else {
            self.driver.isRunning = false
            return
        }
        let q = min(1.0, (CACurrentMediaTime() - startTime) / self.duration)
        self.render(q: q)
        if q >= 1.0 {
            self.startTime = nil
            self.driver.isRunning = false
            self.glyphView.reset(ramp: self.preset.ramp)
            self.imageLayer.opacity = 1.0
            let completion = self.completion
            self.completion = nil
            completion?()
        }
    }

    private func render(q: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.imageLayer.opacity = Float(AsciiImageMath.imageOpacity(q: q))
        CATransaction.commit()
        guard !self.steps.isEmpty else {
            return
        }
        let step = AsciiImageMath.step(q: q, stepCount: self.steps.count)
        let visible = self.steps[step].compactMap { cell -> (index: Int, rect: CGRect, glyph: Int, color: UIColor)? in
            guard AsciiImageMath.isCellVisible(hash: cell.gateHash, distance: cell.distance, maxDistance: self.maxDistance, q: q) else {
                return nil
            }
            return (cell.index, cell.rect, cell.glyph, cell.color)
        }
        self.glyphView.render(step: step, cells: visible)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.glyphView.layer.opacity = Float(AsciiImageMath.glyphOpacity(q: q))
        CATransaction.commit()
    }
}

/// Draws the visible cells of the current step into a bitmap, adding only the cells that became visible since the last
/// frame; a new step starts a new bitmap. Single-glyph CTLines are cached per glyph and size.
private final class AsciiImageGlyphView: UIView {
    private var ramp: [Character] = AsciiPresetSpec.dither.ramp
    private var lines: [String: CTLine] = [:]
    private var context: CGContext?
    private var contextStep = -1
    private var drawnCells = Set<Int>()
    private var scale: CGFloat = 2.0
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func reset(ramp: [Character]) {
        self.ramp = ramp
        self.context = nil
        self.contextStep = -1
        self.drawnCells.removeAll()
        self.layer.contents = nil
    }
    
    private func line(glyph: Int, fontSize: CGFloat) -> CTLine {
        let key = "\(glyph):\(fontSize)"
        if let line = self.lines[key] {
            return line
        }
        let string = NSAttributedString(string: String(self.ramp[min(glyph, self.ramp.count - 1)]), attributes: [
            .font: monospacedFont(size: fontSize),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let line = CTLineCreateWithAttributedString(string)
        self.lines[key] = line
        return line
    }
    
    /// `cells` are the step's cells with their indices; only the indices not drawn yet are drawn.
    func render(step: Int, cells: [(index: Int, rect: CGRect, glyph: Int, color: UIColor)]) {
        let size = self.bounds.size
        guard size.width >= 1.0, size.height >= 1.0 else {
            return
        }
        if self.context == nil || self.contextStep != step {
            self.scale = min(2.0, UIScreen.main.scale)
            let width = Int(ceil(size.width * self.scale))
            let height = Int(ceil(size.height * self.scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                return
            }
            context.scaleBy(x: self.scale, y: self.scale)
            context.setShouldSmoothFonts(false)
            self.context = context
            self.contextStep = step
            self.drawnCells.removeAll()
        }
        guard let context = self.context else {
            return
        }
        var drewAny = false
        for cell in cells where !self.drawnCells.contains(cell.index) {
            self.drawnCells.insert(cell.index)
            drewAny = true
            let fontSize = floor(cell.rect.height * 1.05)
            let line = self.line(glyph: cell.glyph, fontSize: fontSize)
            let bounds = CTLineGetBoundsWithOptions(line, [])
            context.setFillColor(cell.color.cgColor)
            // The context is not flipped: y grows upwards.
            context.textPosition = CGPoint(x: cell.rect.midX - bounds.width / 2.0, y: size.height - cell.rect.midY - (bounds.minY + bounds.height / 2.0))
            CTLineDraw(line, context)
        }
        if drewAny, let image = context.makeImage() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.contents = image
            CATransaction.commit()
        }
    }
}

// MARK: - Skeleton

/// Rows of ASCII glyphs with a light band sweeping across them: a loading placeholder.
public final class AsciiSkeletonView: UIView {
    public enum Variant: Equatable {
        case dither
        case scan
        case braille
        case terminal

        var glyphs: [Character] {
            switch self {
            case .dither:
                return Array("░▒▓█")
            case .scan:
                return Array("-=≡_")
            case .braille:
                return Array("⠁⠃⠇⡇⣇⣧⣷⣿")
            case .terminal:
                return Array("01<>/\\{}[]|_=+-;:")
            }
        }
    }

    public let variant: Variant
    private var color: UIColor = .gray
    private var lineHeight: CGFloat = 14.0
    private var font: UIFont = monospacedFont(size: 11.0)
    private var rows: [[Character]] = []
    private var rowWidths: [CGFloat] = []
    private let startTime = CACurrentMediaTime()
    private lazy var driver = AsciiFrameDriver(update: { [weak self] in
        self?.setNeedsDisplay()
    })

    public init(variant: Variant) {
        self.variant = variant
        super.init(frame: CGRect())
        self.isOpaque = false
        self.backgroundColor = .clear
        self.contentMode = .redraw
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lays the rows out in `size`. The sweep runs while the view is in a window and stops when it leaves.
    public func update(size: CGSize, color: UIColor, lineHeight: CGFloat, font: UIFont) {
        self.color = color
        self.lineHeight = max(6.0, lineHeight)
        self.font = monospacedFont(size: font.pointSize)
        let cellWidth = max(4.0, ("M" as NSString).size(withAttributes: [.font: self.font]).width)
        let rowCount = max(1, Int(size.height / self.lineHeight))
        let columns = max(1, Int(size.width / cellWidth))
        var rows: [[Character]] = []
        var widths: [CGFloat] = []
        let glyphs = self.variant.glyphs
        for row in 0 ..< rowCount {
            // Rows of different lengths read like text.
            let fraction = row == rowCount - 1 ? 0.55 : 0.7 + 0.3 * asciiHash(41, row)
            let count = max(4, Int(Double(columns) * fraction))
            rows.append((0 ..< count).map { glyphs[Int(asciiHash(43, row &* 997 &+ $0) * Double(glyphs.count)) % glyphs.count] })
            widths.append(CGFloat(count) * cellWidth)
        }
        self.rows = rows
        self.rowWidths = widths
        self.updateDriver()
        self.setNeedsDisplay()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        self.updateDriver()
    }

    override public var alpha: CGFloat {
        didSet {
            self.updateDriver()
        }
    }

    private func updateDriver() {
        self.driver.isRunning = self.window != nil && self.alpha > 0.01 && AsciiRevealSettings.isEnabled && !UIAccessibility.isReduceMotionEnabled
    }

    override public func draw(_ rect: CGRect) {
        let time = CACurrentMediaTime() - self.startTime
        let cellWidth = max(4.0, ("M" as NSString).size(withAttributes: [.font: self.font]).width)
        let flicker = AsciiSkeletonMath.flickerFrame(time: time)
        let glyphs = self.variant.glyphs
        let isAnimated = self.driver.isRunning
        for (rowIndex, row) in self.rows.enumerated() {
            let y = CGFloat(rowIndex) * self.lineHeight
            let width = Double(self.rowWidths[rowIndex])
            let bandX = AsciiSkeletonMath.bandX(time: time, row: rowIndex, width: width)
            // One string per row, a colour run per glyph: drawing glyph by glyph is too slow at 30 fps.
            let string = NSMutableAttributedString()
            for (column, glyph) in row.enumerated() {
                let x = CGFloat(column) * cellWidth
                let brightness = isAnimated ? AsciiSkeletonMath.brightness(x: Double(x), bandX: bandX, width: width) : 0.0
                var character = glyph
                if brightness > 0.0 && flicker == 1 {
                    character = glyphs[Int(asciiHash(47, rowIndex &* 997 &+ column) * Double(glyphs.count)) % glyphs.count]
                }
                string.append(NSAttributedString(string: String(character), attributes: [.font: self.font, .foregroundColor: self.color.withAlphaComponent(CGFloat(0.16 + 0.6 * brightness))]))
            }
            let size = string.size()
            string.draw(at: CGPoint(x: 0.0, y: y + floor((self.lineHeight - size.height) / 2.0)))
        }
    }
}

// MARK: - Typing code

/// Code typed out line by line with a terminal block cursor after the last visible line. A line that becomes visible
/// scrambles for ~150 ms before it locks into its real glyphs.
public final class AsciiTypingCodeView: UIView {
    private var lines: [NSAttributedString] = []
    private var visibleLineCount = 0
    private var lineHeight: CGFloat = 16.0
    private var cursorColor: UIColor = .systemBlue
    private var scrambleColor: UIColor = .gray
    private var lineAppearTimes: [Int: Double] = [:]
    private var scrollOffset: CGFloat = 0.0
    private var scrollFrom: CGFloat = 0.0
    private var scrollTo: CGFloat = 0.0
    private var scrollStart: Double = 0.0
    private let startTime = CACurrentMediaTime()
    private lazy var driver = AsciiFrameDriver(update: { [weak self] in
        self?.frameUpdated()
    })

    override public init(frame: CGRect) {
        super.init(frame: frame)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.clipsToBounds = true
        self.contentMode = .redraw
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `lines` are already highlighted. Only the first `visibleLineCount` are shown; when there are more than fit, the
    /// newest ones are kept in view (the text scrolls up within `size`).
    public func update(lines: [NSAttributedString], visibleLineCount: Int, size: CGSize, lineHeight: CGFloat, cursorColor: UIColor, scrambleColor: UIColor) {
        let now = CACurrentMediaTime()
        if visibleLineCount > self.visibleLineCount {
            for index in self.visibleLineCount ..< visibleLineCount {
                self.lineAppearTimes[index] = now
            }
        }
        self.lines = lines
        self.visibleLineCount = max(0, min(lines.count, visibleLineCount))
        self.lineHeight = max(8.0, lineHeight)
        self.cursorColor = cursorColor
        self.scrambleColor = scrambleColor

        let visibleRows = max(1, Int(floor(size.height / self.lineHeight)))
        let target = CGFloat(max(0, self.visibleLineCount - visibleRows)) * self.lineHeight
        if target != self.scrollTo {
            self.scrollFrom = self.scrollOffset
            self.scrollTo = target
            self.scrollStart = now
        }
        self.driver.isRunning = self.window != nil
        self.setNeedsDisplay()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        self.driver.isRunning = self.window != nil
    }

    private var lastBlinkPhase: Bool?
    
    private func frameUpdated() {
        let now = CACurrentMediaTime()
        var needsDisplay = false
        let progress = min(1.0, (now - self.scrollStart) / 0.12)
        let offset = self.scrollFrom + (self.scrollTo - self.scrollFrom) * CGFloat(easeInOut(progress))
        if offset != self.scrollOffset {
            self.scrollOffset = offset
            needsDisplay = true
        }
        if self.lineAppearTimes.values.contains(where: { now - $0 < AsciiTypingMath.scrambleSeconds + 0.04 }) {
            needsDisplay = true
        }
        let blinkPhase = AsciiTypingMath.isCursorVisible(time: now - self.startTime)
        if blinkPhase != self.lastBlinkPhase {
            self.lastBlinkPhase = blinkPhase
            needsDisplay = true
        }
        if needsDisplay {
            self.setNeedsDisplay()
        }
    }

    override public func draw(_ rect: CGRect) {
        let now = CACurrentMediaTime()
        let isEnabled = AsciiRevealSettings.isEnabled && !UIAccessibility.isReduceMotionEnabled
        let scramble = AsciiPresetSpec.terminal.scramble
        var cursorPoint: CGPoint?
        var cursorHeight: CGFloat = self.lineHeight
        for index in 0 ..< self.visibleLineCount {
            let y = CGFloat(index) * self.lineHeight - self.scrollOffset
            if y + self.lineHeight < 0.0 || y > self.bounds.height {
                continue
            }
            let line = self.lines[index]
            var drawn = line
            if isEnabled, let appeared = self.lineAppearTimes[index] {
                let locked = AsciiTypingMath.lockedFraction(elapsed: now - appeared)
                if locked < 1.0 && line.length > 0 {
                    // The newest line scrambles before it locks, left to right.
                    let lockedLength = Int(Double(line.length) * locked)
                    let mutable = NSMutableAttributedString(attributedString: line.attributedSubstring(from: NSRange(location: 0, length: lockedLength)))
                    let font = line.attribute(.font, at: 0, effectiveRange: nil) as? UIFont ?? monospacedFont(size: 12.0)
                    var tail = ""
                    let tick = Int(now * 25.0)
                    let string = line.string as NSString
                    for position in lockedLength ..< line.length {
                        let character = string.character(at: position)
                        if character == 32 {
                            tail.append(" ")
                        } else {
                            tail.append(scramble[Int(asciiHash(UInt64(index), position &* 31 &+ tick) * Double(scramble.count)) % scramble.count])
                        }
                    }
                    mutable.append(NSAttributedString(string: tail, attributes: [.font: font, .foregroundColor: self.scrambleColor]))
                    drawn = mutable
                }
            }
            drawn.draw(at: CGPoint(x: 0.0, y: y))
            if index == self.visibleLineCount - 1 {
                let size = drawn.size()
                cursorPoint = CGPoint(x: size.width + 1.0, y: y)
                cursorHeight = min(self.lineHeight, max(8.0, size.height))
            }
        }
        if self.visibleLineCount == 0 {
            cursorPoint = CGPoint(x: 0.0, y: 0.0)
        }
        if let cursorPoint, !isEnabled || AsciiTypingMath.isCursorVisible(time: now - self.startTime) {
            if let context = UIGraphicsGetCurrentContext() {
                context.setFillColor(self.cursorColor.cgColor)
                context.fill(CGRect(x: cursorPoint.x, y: cursorPoint.y + 1.0, width: max(5.0, floor(self.lineHeight * 0.45)), height: cursorHeight - 2.0))
            }
        }
    }
}
