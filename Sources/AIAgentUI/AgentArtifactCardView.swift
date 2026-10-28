import Foundation
import UIKit
import WebKit
import SwiftSignalKit
import Display
import AppBundle
import AIAgentModel
import AsciiReveal

/// Where everything of a result card goes; thread-safe to compute.
public final class AgentArtifactCardLayout {
    public let size: CGSize
    /// The project's picture; the message's time sits on its corner, as on a photo.
    public let previewFrame: CGRect?
    let eventTileFrame: CGRect?
    let eventMonth: NSAttributedString?
    let eventDay: NSAttributedString?
    /// The type chip's row; a card without a picture shows the message's time at its end.
    public let chipFrame: CGRect
    let chipText: NSAttributedString
    let chipTextFrame: CGRect
    let chipIconFrame: CGRect
    let languageChipFrame: CGRect?
    let languageText: NSAttributedString?
    let languageTextFrame: CGRect
    let languageDotFrame: CGRect
    let languageColor: UIColor?
    let title: NSAttributedString
    let titleFrame: CGRect
    let subtitle: NSAttributedString?
    let subtitleFrame: CGRect
    let stats: NSAttributedString
    let statsFrame: CGRect
    let openFrame: CGRect
    let openTitle: NSAttributedString
    let shareFrame: CGRect?
    let shareTitle: NSAttributedString?

    init(size: CGSize, previewFrame: CGRect?, eventTileFrame: CGRect?, eventMonth: NSAttributedString?, eventDay: NSAttributedString?, chipFrame: CGRect, chipText: NSAttributedString, chipTextFrame: CGRect, chipIconFrame: CGRect, languageChipFrame: CGRect?, languageText: NSAttributedString?, languageTextFrame: CGRect, languageDotFrame: CGRect, languageColor: UIColor?, title: NSAttributedString, titleFrame: CGRect, subtitle: NSAttributedString?, subtitleFrame: CGRect, stats: NSAttributedString, statsFrame: CGRect, openFrame: CGRect, openTitle: NSAttributedString, shareFrame: CGRect?, shareTitle: NSAttributedString?) {
        self.size = size
        self.previewFrame = previewFrame
        self.eventTileFrame = eventTileFrame
        self.eventMonth = eventMonth
        self.eventDay = eventDay
        self.chipFrame = chipFrame
        self.chipText = chipText
        self.chipTextFrame = chipTextFrame
        self.chipIconFrame = chipIconFrame
        self.languageChipFrame = languageChipFrame
        self.languageText = languageText
        self.languageTextFrame = languageTextFrame
        self.languageDotFrame = languageDotFrame
        self.languageColor = languageColor
        self.title = title
        self.titleFrame = titleFrame
        self.subtitle = subtitle
        self.subtitleFrame = subtitleFrame
        self.stats = stats
        self.statsFrame = statsFrame
        self.openFrame = openFrame
        self.openTitle = openTitle
        self.shareFrame = shareFrame
        self.shareTitle = shareTitle
    }
}

/// A result the agent sends instead of a plain file: what it is, what it took to make, and a way to open it.
public final class AgentArtifactCardView: UIView {
    public enum Action {
        case open
        case share
    }

    private let previewContainer = UIView()
    private let previewView = AsciiImageRevealView()
    private let previewSkeleton = AsciiSkeletonView(variant: .dither)
    private let eventTile = UIView()
    private let eventMonthLabel = UILabel()
    private let eventDayLabel = UILabel()
    private let chipView = UIView()
    private let chipIconView = UIImageView()
    private let chipLabel = UILabel()
    private let languageChipView = UIView()
    private let languageDotView = UIView()
    private let languageLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statsLabel = UILabel()
    private let openButton = UIView()
    private let openLabel = UILabel()
    private let shareButton = UIView()
    private let shareLabel = UILabel()

    private var currentLayout: AgentArtifactCardLayout?
    private var theme: AgentChatTheme?
    private var artifactId: Int64?
    private var chipIconKind: AgentArtifact.Kind?
    private var hasPreview = false
    private let previewDisposable = MetaDisposable()

    /// Cards that have played their reveal, so it plays once per result.
    private static var revealedArtifacts = Set<Int64>()

    override public init(frame: CGRect) {
        super.init(frame: frame)

        self.previewContainer.clipsToBounds = true
        self.previewContainer.layer.cornerRadius = 10.0
        if #available(iOS 13.0, *) {
            self.previewContainer.layer.cornerCurve = .continuous
            self.chipView.layer.cornerCurve = .continuous
            self.languageChipView.layer.cornerCurve = .continuous
            self.openButton.layer.cornerCurve = .continuous
            self.shareButton.layer.cornerCurve = .continuous
            self.eventTile.layer.cornerCurve = .continuous
        }
        self.previewContainer.addSubview(self.previewSkeleton)
        self.previewContainer.addSubview(self.previewView)
        self.addSubview(self.previewContainer)

        self.eventTile.layer.cornerRadius = 12.0
        self.eventMonthLabel.textAlignment = .center
        self.eventDayLabel.textAlignment = .center
        self.eventTile.addSubview(self.eventMonthLabel)
        self.eventTile.addSubview(self.eventDayLabel)
        self.addSubview(self.eventTile)

        self.chipIconView.contentMode = .scaleAspectFit
        self.chipView.addSubview(self.chipIconView)
        self.chipView.addSubview(self.chipLabel)
        self.addSubview(self.chipView)
        self.languageChipView.addSubview(self.languageDotView)
        self.languageChipView.addSubview(self.languageLabel)
        self.addSubview(self.languageChipView)

        self.titleLabel.numberOfLines = 2
        self.subtitleLabel.numberOfLines = 2
        self.addSubview(self.titleLabel)
        self.addSubview(self.subtitleLabel)
        self.addSubview(self.statsLabel)

        self.openButton.layer.cornerRadius = 10.0
        self.shareButton.layer.cornerRadius = 10.0
        self.openLabel.textAlignment = .center
        self.shareLabel.textAlignment = .center
        self.openButton.addSubview(self.openLabel)
        self.shareButton.addSubview(self.shareLabel)
        self.addSubview(self.openButton)
        self.addSubview(self.shareButton)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.previewDisposable.dispose()
    }

    // MARK: Layout

    /// `chipRowTrailingInset` keeps the end of the chip row free for the message's time.
    public static func layout(artifact: AgentArtifact, width: CGFloat, theme: AgentChatTheme, chipRowTrailingInset: CGFloat = 0.0) -> AgentArtifactCardLayout {
        var y: CGFloat = 0.0
        var previewFrame: CGRect?
        var eventTileFrame: CGRect?
        var eventMonth: NSAttributedString?
        var eventDay: NSAttributedString?

        if artifact.kind == .project {
            let frame = CGRect(x: 0.0, y: 0.0, width: width, height: floor(width * 10.0 / 16.0))
            previewFrame = frame
            y = frame.maxY + theme.size(10.0)
        }

        // Chip: the type, with the </> glyph of managed bots.
        let chipText = NSAttributedString(string: artifact.typeTitle, font: Font.medium(theme.size(13.0)), textColor: theme.accent)
        let chipTextSize = AgentTextMeasure.singleLine(chipText, maxWidth: width - 40.0)
        let chipHeight = theme.size(22.0)
        let iconSize = theme.size(14.0)
        let chipPadding = theme.size(8.0)
        let chipFrame = CGRect(x: 0.0, y: y, width: chipPadding + iconSize + theme.size(4.0) + chipTextSize.width + chipPadding, height: chipHeight)
        let chipIconFrame = CGRect(x: chipPadding, y: floor((chipHeight - iconSize) / 2.0), width: iconSize, height: iconSize)
        let chipTextFrame = CGRect(x: chipIconFrame.maxX + theme.size(4.0), y: floor((chipHeight - chipTextSize.height) / 2.0), width: chipTextSize.width, height: chipTextSize.height)

        // The language most of it is written in, with GitHub's colour for it.
        var languageChipFrame: CGRect?
        var languageText: NSAttributedString?
        var languageTextFrame = CGRect()
        var languageDotFrame = CGRect()
        var languageColor: UIColor?
        if artifact.kind == .project, let language = artifact.primaryLanguage {
            let text = NSAttributedString(string: language.name, font: Font.medium(theme.size(13.0)), textColor: theme.primary.withAlphaComponent(0.85))
            let textSize = AgentTextMeasure.singleLine(text, maxWidth: max(1.0, width - chipFrame.maxX - 40.0))
            let dotSize = theme.size(8.0)
            let frame = CGRect(x: chipFrame.maxX + theme.size(6.0), y: y, width: chipPadding + dotSize + theme.size(5.0) + textSize.width + chipPadding, height: chipHeight)
            if frame.maxX <= width - chipRowTrailingInset {
                languageChipFrame = frame
                languageText = text
                languageDotFrame = CGRect(x: chipPadding, y: floor((chipHeight - dotSize) / 2.0), width: dotSize, height: dotSize)
                languageTextFrame = CGRect(x: languageDotFrame.maxX + theme.size(5.0), y: floor((chipHeight - textSize.height) / 2.0), width: textSize.width, height: textSize.height)
                languageColor = UIColor(rgb: language.color)
            }
        }
        y = chipFrame.maxY + theme.size(8.0)

        var textX: CGFloat = 0.0
        var titleString = artifact.title
        var subtitleString: String? = artifact.description
        if artifact.kind == .event, let event = artifact.event {
            let tileSize = theme.size(52.0)
            let frame = CGRect(x: 0.0, y: y, width: tileSize, height: tileSize)
            eventTileFrame = frame
            let date = Date(timeIntervalSince1970: event.startDate)
            let monthFormatter = DateFormatter()
            monthFormatter.locale = Locale(identifier: theme.isRussian ? "ru_RU" : "en_US")
            monthFormatter.dateFormat = "LLL"
            let month = monthFormatter.string(from: date).replacingOccurrences(of: ".", with: "").uppercased()
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "d"
            eventMonth = NSAttributedString(string: month, font: Font.semibold(theme.size(11.0)), textColor: theme.accent)
            eventDay = NSAttributedString(string: dayFormatter.string(from: date), font: Font.semibold(theme.size(22.0)), textColor: theme.primary)
            textX = frame.maxX + theme.size(12.0)

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            let end = date.addingTimeInterval(Double(event.durationMinutes) * 60.0)
            titleString = event.title
            subtitleString = "\(timeFormatter.string(from: date)) – \(timeFormatter.string(from: end))"
        }

        let textWidth = width - textX
        let title = NSAttributedString(string: titleString, font: Font.semibold(theme.size(17.0)), textColor: theme.primary)
        let titleSize = AgentTextMeasure.size(title, width: textWidth, maxLines: 2)
        var titleFrame = CGRect(x: textX, y: y, width: titleSize.width, height: titleSize.height)
        var subtitle: NSAttributedString?
        var subtitleFrame = CGRect()
        if let subtitleString, !subtitleString.isEmpty {
            let string = NSAttributedString(string: subtitleString, font: Font.regular(theme.size(15.0)), textColor: artifact.kind == .event ? theme.primary : theme.primary.withAlphaComponent(0.85))
            let size = AgentTextMeasure.size(string, width: textWidth, maxLines: 2)
            subtitleFrame = CGRect(x: textX, y: titleFrame.maxY + 2.0, width: size.width, height: size.height)
            subtitle = string
        }
        var textBottom = max(titleFrame.maxY, subtitleFrame.maxY)
        if let eventTileFrame {
            // Centre the event's two lines on the tile.
            let blockHeight = textBottom - y
            if blockHeight < eventTileFrame.height {
                let offset = floor((eventTileFrame.height - blockHeight) / 2.0)
                titleFrame.origin.y += offset
                subtitleFrame.origin.y += offset
            }
            textBottom = max(eventTileFrame.maxY, subtitleFrame.maxY, titleFrame.maxY)
        }
        y = textBottom + theme.size(6.0)

        let statsString: String
        if artifact.kind == .event, let event = artifact.event {
            statsString = theme.isRussian ? "Напомню за \(event.reminderMinutes) мин · \(event.calendarTitle)" : "Reminder \(event.reminderMinutes) min before · \(event.calendarTitle)"
        } else {
            let stats = artifact.stats
            statsString = [
                AgentFormatting.duration(stats.seconds, isRussian: theme.isRussian),
                AgentFormatting.steps(stats.steps, isRussian: theme.isRussian),
                AgentFormatting.files(stats.files, isRussian: theme.isRussian),
                AgentFormatting.bytes(stats.bytes, isRussian: theme.isRussian)
            ].joined(separator: " · ")
        }
        let stats = NSAttributedString(string: statsString, font: theme.detailFont, textColor: theme.secondary)
        let statsSize = AgentTextMeasure.singleLine(stats, maxWidth: width)
        let statsFrame = CGRect(x: 0.0, y: y, width: statsSize.width, height: statsSize.height)
        y = statsFrame.maxY + theme.size(12.0)

        let buttonHeight = theme.size(36.0)
        let openTitle: NSAttributedString
        var shareFrame: CGRect?
        var shareTitle: NSAttributedString?
        let openFrame: CGRect
        if artifact.kind == .event {
            openTitle = NSAttributedString(string: theme.text("Открыть в календаре", "Open in Calendar"), font: Font.semibold(theme.size(15.0)), textColor: theme.accent)
            openFrame = CGRect(x: 0.0, y: y, width: width, height: buttonHeight)
        } else {
            let spacing = theme.size(8.0)
            let buttonWidth = floor((width - spacing) / 2.0)
            openTitle = NSAttributedString(string: theme.text("Открыть", "Open"), font: Font.semibold(theme.size(15.0)), textColor: theme.accent)
            openFrame = CGRect(x: 0.0, y: y, width: buttonWidth, height: buttonHeight)
            shareFrame = CGRect(x: width - buttonWidth, y: y, width: buttonWidth, height: buttonHeight)
            shareTitle = NSAttributedString(string: theme.text("Поделиться", "Share"), font: Font.medium(theme.size(15.0)), textColor: theme.primary)
        }
        y = openFrame.maxY

        return AgentArtifactCardLayout(size: CGSize(width: width, height: ceil(y)), previewFrame: previewFrame, eventTileFrame: eventTileFrame, eventMonth: eventMonth, eventDay: eventDay, chipFrame: chipFrame, chipText: chipText, chipTextFrame: chipTextFrame, chipIconFrame: chipIconFrame, languageChipFrame: languageChipFrame, languageText: languageText, languageTextFrame: languageTextFrame, languageDotFrame: languageDotFrame, languageColor: languageColor, title: title, titleFrame: titleFrame, subtitle: subtitle, subtitleFrame: subtitleFrame, stats: stats, statsFrame: statsFrame, openFrame: openFrame, openTitle: openTitle, shareFrame: shareFrame, shareTitle: shareTitle)
    }

    // MARK: Apply

    /// `previewHTML` is the project's page with the current theme; the card renders it once and caches the image.
    public func apply(layout: AgentArtifactCardLayout, artifact: AgentArtifact, theme: AgentChatTheme, previewHTML: String?, playsAppearance: Bool, transition: ContainedViewLayoutTransition) {
        self.currentLayout = layout
        let themeUpdated = self.theme != theme
        self.theme = theme

        if themeUpdated {
            self.chipView.backgroundColor = theme.accentControl.withAlphaComponent(0.1)
            self.languageChipView.backgroundColor = theme.secondary.withAlphaComponent(0.1)
            self.openButton.backgroundColor = theme.accentControl.withAlphaComponent(0.12)
            self.shareButton.backgroundColor = theme.secondary.withAlphaComponent(0.1)
            self.previewContainer.backgroundColor = theme.cardColor
            self.previewContainer.layer.borderWidth = UIScreenPixel
            self.previewContainer.layer.borderColor = theme.secondary.withAlphaComponent(0.3).cgColor
            self.eventTile.backgroundColor = theme.accentControl.withAlphaComponent(0.12)
        }

        if let previewFrame = layout.previewFrame {
            self.previewContainer.isHidden = false
            transition.updateFrame(view: self.previewContainer, frame: previewFrame)
            self.previewSkeleton.frame = CGRect(origin: CGPoint(), size: previewFrame.size).insetBy(dx: 12.0, dy: 12.0)
            self.previewSkeleton.update(size: self.previewSkeleton.bounds.size, color: theme.secondary.withAlphaComponent(0.5), lineHeight: theme.size(14.0), font: theme.codeFont)
            self.previewView.frame = CGRect(origin: CGPoint(), size: previewFrame.size)
            if self.artifactId != artifact.id {
                self.artifactId = artifact.id
                self.hasPreview = false
                self.previewView.alpha = 0.0
                self.previewSkeleton.alpha = 1.0
                let shouldReveal = playsAppearance && !AgentArtifactCardView.revealedArtifacts.contains(artifact.id)
                AgentArtifactCardView.revealedArtifacts.insert(artifact.id)
                if let previewHTML {
                    self.previewDisposable.set((AgentPreviewSnapshotter.shared.snapshot(artifactId: artifact.id, html: previewHTML, size: previewFrame.size, isDark: theme.isDark)
                    |> deliverOnMainQueue).start(next: { [weak self] image in
                        guard let self, let image else {
                            return
                        }
                        self.showPreview(image: image, theme: theme, reveal: shouldReveal)
                    }))
                }
            }
        } else {
            self.previewContainer.isHidden = true
        }

        if let tileFrame = layout.eventTileFrame {
            self.eventTile.isHidden = false
            transition.updateFrame(view: self.eventTile, frame: tileFrame)
            self.eventMonthLabel.attributedText = layout.eventMonth
            self.eventDayLabel.attributedText = layout.eventDay
            let monthHeight = ceil(Font.semibold(theme.size(11.0)).lineHeight)
            let dayHeight = ceil(Font.semibold(theme.size(22.0)).lineHeight)
            let top = floor((tileFrame.height - monthHeight - dayHeight) / 2.0)
            self.eventMonthLabel.frame = CGRect(x: 0.0, y: top, width: tileFrame.width, height: monthHeight)
            self.eventDayLabel.frame = CGRect(x: 0.0, y: top + monthHeight, width: tileFrame.width, height: dayHeight)
        } else {
            self.eventTile.isHidden = true
        }

        if themeUpdated || self.chipIconKind != artifact.kind {
            self.chipIconKind = artifact.kind
            // The </> glyph of managed bots for what the agent built; a calendar for an event.
            let iconName = artifact.kind == .event ? "Chat/Context Menu/Calendar" : "Peer Info/ManagedBotInlineTextIcon"
            self.chipIconView.image = generateTintedImage(image: UIImage(bundleImageName: iconName), color: theme.accent)
        }
        transition.updateFrame(view: self.chipView, frame: layout.chipFrame)
        self.chipView.layer.cornerRadius = layout.chipFrame.height / 2.0
        self.chipIconView.frame = layout.chipIconFrame
        self.chipLabel.attributedText = layout.chipText
        self.chipLabel.frame = layout.chipTextFrame

        if let languageChipFrame = layout.languageChipFrame {
            self.languageChipView.isHidden = false
            transition.updateFrame(view: self.languageChipView, frame: languageChipFrame)
            self.languageChipView.layer.cornerRadius = languageChipFrame.height / 2.0
            self.languageDotView.frame = layout.languageDotFrame
            self.languageDotView.layer.cornerRadius = layout.languageDotFrame.height / 2.0
            self.languageDotView.backgroundColor = layout.languageColor
            self.languageLabel.attributedText = layout.languageText
            self.languageLabel.frame = layout.languageTextFrame
        } else {
            self.languageChipView.isHidden = true
        }

        self.titleLabel.attributedText = layout.title
        transition.updateFrame(view: self.titleLabel, frame: layout.titleFrame)
        if let subtitle = layout.subtitle {
            self.subtitleLabel.isHidden = false
            self.subtitleLabel.attributedText = subtitle
            transition.updateFrame(view: self.subtitleLabel, frame: layout.subtitleFrame)
        } else {
            self.subtitleLabel.isHidden = true
        }
        self.statsLabel.attributedText = layout.stats
        transition.updateFrame(view: self.statsLabel, frame: layout.statsFrame)

        transition.updateFrame(view: self.openButton, frame: layout.openFrame)
        self.openLabel.attributedText = layout.openTitle
        self.openLabel.frame = CGRect(origin: CGPoint(), size: layout.openFrame.size)
        if let shareFrame = layout.shareFrame, let shareTitle = layout.shareTitle {
            self.shareButton.isHidden = false
            transition.updateFrame(view: self.shareButton, frame: shareFrame)
            self.shareLabel.attributedText = shareTitle
            self.shareLabel.frame = CGRect(origin: CGPoint(), size: shareFrame.size)
        } else {
            self.shareButton.isHidden = true
        }

        if playsAppearance && transition.isAnimated && !UIAccessibility.isReduceMotionEnabled {
            for view in [self.chipView, self.languageChipView, self.titleLabel, self.subtitleLabel, self.statsLabel, self.openButton, self.shareButton] {
                view.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3, delay: 0.1)
            }
        }
    }

    private func showPreview(image: UIImage, theme: AgentChatTheme, reveal: Bool) {
        guard !self.hasPreview else {
            return
        }
        self.hasPreview = true
        let size = self.previewView.bounds.size
        self.previewView.update(image: image, size: size, glyphColor: theme.secondary, backgroundColor: theme.cardColor, cornerRadius: 0.0)
        self.previewView.alpha = 1.0
        if reveal {
            self.previewView.playReveal(preset: .dither, pace: .cinematic, origin: nil, completion: nil)
            self.previewSkeleton.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
            self.previewSkeleton.alpha = 0.0
        } else {
            self.previewSkeleton.alpha = 0.0
        }
    }

    public func action(at point: CGPoint) -> Action? {
        guard let layout = self.currentLayout else {
            return nil
        }
        if let shareFrame = layout.shareFrame, shareFrame.contains(point) {
            return .share
        }
        if layout.openFrame.contains(point) {
            return .open
        }
        if let previewFrame = layout.previewFrame, previewFrame.contains(point) {
            return .open
        }
        return nil
    }
}

/// Renders a project's page offscreen and keeps the picture, so a result card shows what was built.
public final class AgentPreviewSnapshotter: NSObject, WKNavigationDelegate {
    public static let shared = AgentPreviewSnapshotter()

    private var cache: [String: UIImage] = [:]
    private var waiting: [String: [(UIImage?) -> Void]] = [:]
    private var webViews: [WKWebView: (key: String, size: CGSize)] = [:]

    private static var cacheDirectory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = caches.appendingPathComponent("ai-agent-previews-v4", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func snapshot(artifactId: Int64, html: String, size: CGSize, isDark: Bool) -> Signal<UIImage?, NoError> {
        let key = "\(artifactId)-\(isDark ? "dark" : "light")-\(Int(size.width))"
        return Signal { subscriber in
            Queue.mainQueue().async {
                if let image = self.cache[key] {
                    subscriber.putNext(image)
                    subscriber.putCompletion()
                    return
                }
                if let directory = AgentPreviewSnapshotter.cacheDirectory, let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".png")), let image = UIImage(data: data, scale: UIScreenScale) {
                    self.cache[key] = image
                    subscriber.putNext(image)
                    subscriber.putCompletion()
                    return
                }
                let isFirst = self.waiting[key] == nil
                self.waiting[key, default: []].append({ image in
                    subscriber.putNext(image)
                    subscriber.putCompletion()
                })
                if isFirst {
                    self.render(key: key, html: html, size: size)
                }
            }
            return EmptyDisposable
        }
    }

    private func render(key: String, html: String, size: CGSize) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else {
            self.finish(key: key, image: nil)
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The page is laid out for a phone screen and the top of it is shown on the card.
        let pageWidth: CGFloat = 390.0
        let pageSize = CGSize(width: pageWidth, height: floor(pageWidth * size.height / max(1.0, size.width)))
        // Left of the screen and away from its top and bottom edges: at the top the page would get the status bar's
        // safe area as `env(safe-area-inset-top)` and start with a blank band.
        let webView = WKWebView(frame: CGRect(origin: CGPoint(x: -pageSize.width - 100.0, y: floor((window.bounds.height - pageSize.height) / 2.0)), size: pageSize), configuration: configuration)
        // Off screen, but fully opaque: the snapshot keeps the view's alpha.
        webView.isOpaque = false
        webView.isUserInteractionEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = self
        window.addSubview(webView)
        self.webViews[webView] = (key, size)
        webView.loadHTMLString(html, baseURL: nil)

        Queue.mainQueue().after(6.0, { [weak self, weak webView] in
            guard let self, let webView, self.webViews[webView] != nil else {
                return
            }
            self.webViews.removeValue(forKey: webView)
            webView.removeFromSuperview()
            self.finish(key: key, image: nil)
        })
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Queue.mainQueue().after(0.35, { [weak self, weak webView] in
            guard let self, let webView, let entry = self.webViews[webView] else {
                return
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            configuration.snapshotWidth = NSNumber(value: Double(entry.size.width))
            webView.takeSnapshot(with: configuration, completionHandler: { [weak self, weak webView] image, _ in
                guard let self else {
                    return
                }
                if let webView {
                    self.webViews.removeValue(forKey: webView)
                    webView.removeFromSuperview()
                }
                if let image, let directory = AgentPreviewSnapshotter.cacheDirectory, let data = image.pngData() {
                    try? data.write(to: directory.appendingPathComponent(entry.key + ".png"))
                }
                self.finish(key: entry.key, image: image)
            })
        })
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let entry = self.webViews.removeValue(forKey: webView) else {
            return
        }
        webView.removeFromSuperview()
        self.finish(key: entry.key, image: nil)
    }

    private func finish(key: String, image: UIImage?) {
        if let image {
            self.cache[key] = image
        }
        let callbacks = self.waiting.removeValue(forKey: key) ?? []
        for callback in callbacks {
            callback(image)
        }
    }
}
