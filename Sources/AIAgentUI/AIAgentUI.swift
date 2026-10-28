import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramPresentationData
import TextFormat
import AIAgentModel

/// Colours and fonts of an agent message, taken from the bubble it is drawn in, so the path reads like part of the
/// message in every theme and at every chat text size.
public struct AgentChatTheme: Equatable {
    public let primary: UIColor
    public let secondary: UIColor
    public let accent: UIColor
    public let accentControl: UIColor
    public let destructive: UIColor
    public let isDark: Bool
    /// The chat's message text size (17 by default).
    public let fontSize: CGFloat
    public let isRussian: Bool

    public init(theme: PresentationTheme, strings: PresentationStrings, fontSize: CGFloat, isIncoming: Bool = true) {
        let colors = isIncoming ? theme.chat.message.incoming : theme.chat.message.outgoing
        self.primary = colors.primaryTextColor
        self.secondary = colors.secondaryTextColor
        self.accent = colors.accentTextColor
        self.accentControl = colors.accentControlColor
        self.destructive = colors.scamColor
        self.isDark = theme.overallDarkAppearance
        self.fontSize = fontSize
        self.isRussian = strings.baseLanguageCode == "ru"
    }

    public init(primary: UIColor, secondary: UIColor, accent: UIColor, accentControl: UIColor, destructive: UIColor, isDark: Bool, fontSize: CGFloat, isRussian: Bool) {
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
        self.accentControl = accentControl
        self.destructive = destructive
        self.isDark = isDark
        self.fontSize = fontSize
        self.isRussian = isRussian
    }

    /// Everything scales with the chat's text size.
    public var scale: CGFloat {
        return max(0.8, min(1.6, self.fontSize / 17.0))
    }

    public func size(_ value: CGFloat) -> CGFloat {
        return floor(value * self.scale)
    }

    public var titleFont: UIFont {
        return Font.regular(self.size(15.0))
    }

    public var titleMediumFont: UIFont {
        return Font.medium(self.size(15.0))
    }

    public var detailFont: UIFont {
        return Font.regular(self.size(13.0))
    }

    public var bodyFont: UIFont {
        return Font.regular(self.size(14.0))
    }

    public var captionFont: UIFont {
        return Font.semibold(self.size(11.0))
    }

    public var durationFont: UIFont {
        return UIFont.monospacedDigitSystemFont(ofSize: self.size(13.0), weight: .regular)
    }

    public var codeFont: UIFont {
        return UIFont.monospacedSystemFont(ofSize: max(10.0, floor(12.5 * self.scale * 2.0) / 2.0), weight: .regular)
    }

    /// Inset cards (input/output, live code, permission) on the bubble.
    public var cardColor: UIColor {
        return self.accentControl.withAlphaComponent(self.isDark ? 0.12 : 0.07)
    }

    public var railColor: UIColor {
        return self.secondary.withAlphaComponent(0.22)
    }

    public func text(_ russian: String, _ english: String) -> String {
        return self.isRussian ? russian : english
    }
}

/// The Telegram Mini App theme variables for the agent's projects, so they look native in the current theme.
public enum AgentMiniAppTheme {
    public static func cssVariables(theme: PresentationTheme) -> String {
        func hex(_ color: UIColor) -> String {
            var r: CGFloat = 0.0
            var g: CGFloat = 0.0
            var b: CGFloat = 0.0
            var a: CGFloat = 0.0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02x%02x%02x", Int(round(r * 255.0)), Int(round(g * 255.0)), Int(round(b * 255.0)))
        }
        let list = theme.list
        let values: [(String, UIColor)] = [
            ("bg-color", list.plainBackgroundColor),
            ("secondary-bg-color", list.blocksBackgroundColor),
            ("section-bg-color", list.itemBlocksBackgroundColor),
            ("text-color", list.itemPrimaryTextColor),
            ("hint-color", list.itemSecondaryTextColor),
            ("link-color", list.itemAccentColor),
            ("accent-text-color", list.itemAccentColor),
            ("button-color", list.itemCheckColors.fillColor),
            ("button-text-color", list.itemCheckColors.foregroundColor),
            ("destructive-text-color", list.itemDestructiveColor),
            ("section-separator-color", list.itemBlocksSeparatorColor)
        ]
        let body = values.map { "--tg-theme-\($0.0): \(hex($0.1));" }.joined(separator: " ")
        return ":root { \(body) color-scheme: \(theme.overallDarkAppearance ? "dark" : "light"); }"
    }
}

/// Syntax highlighting for snippets and project files through Telegram's own highlighter. Results are cached by text, so
/// a snippet is highlighted once and then drawn synchronously.
public final class AgentSyntaxHighlighter {
    public static let shared = AgentSyntaxHighlighter()

    private var cache: [CachedMessageSyntaxHighlight.Spec: MessageSyntaxHighlight] = [:]
    private var pending = Set<CachedMessageSyntaxHighlight.Spec>()
    private var waiting: [CachedMessageSyntaxHighlight.Spec: [() -> Void]] = [:]
    private var lock = os_unfair_lock()

    /// libprisma's names for the languages the agent writes.
    private static func engineLanguage(_ language: String?) -> String? {
        guard let language = language?.lowercased(), !language.isEmpty, language != "text" else {
            return nil
        }
        switch language {
        case "html":
            return "markup"
        case "js":
            return "javascript"
        default:
            return language
        }
    }

    /// The text with highlight colours when they are known. When they aren't, the plain text is returned and
    /// `updated` runs on the main queue once they are.
    public func attributedString(_ text: String, language: String?, font: UIFont, color: UIColor, isDark: Bool, updated: (() -> Void)?) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle])
        guard let engineLanguage = AgentSyntaxHighlighter.engineLanguage(language), !text.isEmpty else {
            return result
        }
        let spec = CachedMessageSyntaxHighlight.Spec(language: engineLanguage, text: text)
        os_unfair_lock_lock(&self.lock)
        let cached = self.cache[spec]
        os_unfair_lock_unlock(&self.lock)
        if let cached {
            let length = result.length
            for entity in cached.entities where entity.range.lowerBound >= 0 && entity.range.upperBound <= length {
                var highlightColor = UIColor(rgb: UInt32(bitPattern: entity.color))
                if isDark {
                    highlightColor = highlightColor.withMultiplied(hue: 1.0, saturation: 0.8, brightness: 1.45)
                }
                result.addAttribute(.foregroundColor, value: highlightColor, range: NSRange(location: entity.range.lowerBound, length: entity.range.upperBound - entity.range.lowerBound))
            }
            return result
        }
        self.request(spec, updated: updated)
        return result
    }

    private func request(_ spec: CachedMessageSyntaxHighlight.Spec, updated: (() -> Void)?) {
        os_unfair_lock_lock(&self.lock)
        if let updated {
            self.waiting[spec, default: []].append(updated)
        }
        let isPending = self.pending.contains(spec)
        if !isPending {
            self.pending.insert(spec)
        }
        os_unfair_lock_unlock(&self.lock)
        if isPending {
            return
        }
        let _ = (asyncStanaloneSyntaxHighlight(current: nil, specs: [spec])
        |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else {
                return
            }
            os_unfair_lock_lock(&self.lock)
            self.cache[spec] = result.values[spec] ?? MessageSyntaxHighlight(entities: [])
            self.pending.remove(spec)
            let callbacks = self.waiting.removeValue(forKey: spec) ?? []
            os_unfair_lock_unlock(&self.lock)
            for callback in callbacks {
                callback()
            }
        })
    }
}

/// Small vector glyphs in Telegram's line style, drawn at any size so they stay crisp at every text size.
enum AgentGlyphs {
    static func checkmark(size: CGFloat, color: UIColor, lineWidth: CGFloat = 1.5) -> UIImage? {
        return generateImage(CGSize(width: size, height: size), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: size.width * 0.22, y: size.height * 0.52))
            context.addLine(to: CGPoint(x: size.width * 0.42, y: size.height * 0.72))
            context.addLine(to: CGPoint(x: size.width * 0.78, y: size.height * 0.30))
            context.strokePath()
        })
    }

    static func chevron(size: CGFloat, color: UIColor) -> UIImage? {
        return generateImage(CGSize(width: size, height: size), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.5)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: size.width * 0.38, y: size.height * 0.24))
            context.addLine(to: CGPoint(x: size.width * 0.64, y: size.height * 0.5))
            context.addLine(to: CGPoint(x: size.width * 0.38, y: size.height * 0.76))
            context.strokePath()
        })
    }

    /// Three dots on a line: the agent's path in miniature.
    static func path(size: CGSize, color: UIColor) -> UIImage? {
        return generateImage(size, rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            let x = size.width / 2.0
            let radius: CGFloat = 1.75
            let ys: [CGFloat] = [radius + 0.5, size.height / 2.0, size.height - radius - 0.5]
            context.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(1.0)
            context.move(to: CGPoint(x: x, y: ys[0]))
            context.addLine(to: CGPoint(x: x, y: ys[2]))
            context.strokePath()
            context.setFillColor(color.cgColor)
            for y in ys {
                context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2.0, height: radius * 2.0))
            }
        })
    }

    static func plus(size: CGFloat, color: UIColor) -> UIImage? {
        return generateImage(CGSize(width: size, height: size), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.5)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: size.width / 2.0, y: size.height * 0.25))
            context.addLine(to: CGPoint(x: size.width / 2.0, y: size.height * 0.75))
            context.move(to: CGPoint(x: size.width * 0.25, y: size.height / 2.0))
            context.addLine(to: CGPoint(x: size.width * 0.75, y: size.height / 2.0))
            context.strokePath()
        })
    }
}

/// Line-wrapped text measurement that is safe off the main thread.
enum AgentTextMeasure {
    static func size(_ string: NSAttributedString, width: CGFloat, maxLines: Int = 0) -> CGSize {
        guard string.length != 0, width > 0.0 else {
            return CGSize()
        }
        let rect = string.boundingRect(with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        var height = ceil(rect.height)
        if maxLines > 0, let font = string.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
            height = min(height, ceil(font.lineHeight * CGFloat(maxLines)))
        }
        return CGSize(width: min(width, ceil(rect.width)), height: height)
    }

    static func singleLine(_ string: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        guard string.length != 0 else {
            return CGSize()
        }
        let rect = string.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [.usesFontLeading], context: nil)
        let font = string.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        return CGSize(width: min(maxWidth, ceil(rect.width)), height: ceil(font?.lineHeight ?? rect.height))
    }
}
