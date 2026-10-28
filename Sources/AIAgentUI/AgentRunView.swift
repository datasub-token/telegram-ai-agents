import Foundation
import UIKit
import Display
import AppBundle
import AIAgentModel
import AsciiReveal

// MARK: - Layout

/// Where everything of a run goes, computed off the main thread by `AgentRunView.layout` and applied by
/// `AgentRunView.apply`.
public final class AgentRunLayout {
    public let size: CGSize
    let width: CGFloat
    let theme: AgentChatTheme
    let summary: AgentRunSummaryLayout?
    let rows: [AgentRunRowLayout]
    /// The rail runs between these dot centres.
    let rail: (top: CGFloat, bottom: CGFloat)?
    let separatorY: CGFloat?

    init(size: CGSize, width: CGFloat, theme: AgentChatTheme, summary: AgentRunSummaryLayout?, rows: [AgentRunRowLayout], rail: (top: CGFloat, bottom: CGFloat)?, separatorY: CGFloat?) {
        self.size = size
        self.width = width
        self.theme = theme
        self.summary = summary
        self.rows = rows
        self.rail = rail
        self.separatorY = separatorY
    }
}

struct AgentRunSummaryLayout {
    let frame: CGRect
    let text: NSAttributedString
    let textFrame: CGRect
    let isExpanded: Bool
}

final class AgentRunRowLayout {
    enum Kind {
        case step(AgentStep)
        /// Older steps folded away while the path is long: "+3 steps".
        case folded(Int)
    }

    let id: String
    let kind: Kind
    /// In the run view's coordinates.
    let frame: CGRect
    /// The rest are in the row's coordinates.
    let headerHeight: CGFloat
    let dotCenter: CGPoint
    let title: NSAttributedString
    let titleFrame: CGRect
    let titleLines: Int
    let detail: NSAttributedString?
    let detailFrame: CGRect
    let durationFrame: CGRect?
    let chevronFrame: CGRect?
    let isExpanded: Bool
    let content: AgentRunContentLayout?

    init(id: String, kind: Kind, frame: CGRect, headerHeight: CGFloat, dotCenter: CGPoint, title: NSAttributedString, titleFrame: CGRect, titleLines: Int, detail: NSAttributedString?, detailFrame: CGRect, durationFrame: CGRect?, chevronFrame: CGRect?, isExpanded: Bool, content: AgentRunContentLayout?) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.headerHeight = headerHeight
        self.dotCenter = dotCenter
        self.title = title
        self.titleFrame = titleFrame
        self.titleLines = titleLines
        self.detail = detail
        self.detailFrame = detailFrame
        self.durationFrame = durationFrame
        self.chevronFrame = chevronFrame
        self.isExpanded = isExpanded
        self.content = content
    }

    var step: AgentStep? {
        if case let .step(step) = self.kind {
            return step
        }
        return nil
    }
}

enum AgentRunContentLayout {
    case text(NSAttributedString, CGRect)
    case plan(AgentPlanLayout, CGRect)
    case io(AgentIOLayout, CGRect)
    case liveCode(AgentLiveCodeLayout, CGRect)
    case permission(AgentPermissionLayout, CGRect)

    var frame: CGRect {
        switch self {
        case let .text(_, frame), let .plan(_, frame), let .io(_, frame), let .liveCode(_, frame), let .permission(_, frame):
            return frame
        }
    }

    var kindKey: String {
        switch self {
        case .text:
            return "text"
        case .plan:
            return "plan"
        case .io:
            return "io"
        case .liveCode:
            return "liveCode"
        case .permission:
            return "permission"
        }
    }
}

struct AgentPlanLayout {
    struct Item {
        let title: NSAttributedString
        let titleFrame: CGRect
        let circleFrame: CGRect
        let isDone: Bool
    }
    let items: [Item]
    let size: CGSize
}

struct AgentIOLayout {
    struct Section {
        let label: NSAttributedString
        let labelFrame: CGRect
        let code: String
        let language: String?
        let codeFrame: CGRect
    }
    let sections: [Section]
    let showAll: NSAttributedString?
    let showAllFrame: CGRect?
    let size: CGSize
}

struct AgentLiveCodeLayout {
    let fileName: NSAttributedString
    let fileNameFrame: CGRect
    let iconFrame: CGRect
    let counterFrame: CGRect
    let bodyFrame: CGRect
    let lineHeight: CGFloat
    let liveCode: AgentLiveCode
    let size: CGSize
}

struct AgentPermissionLayout {
    let tileFrame: CGRect
    let title: NSAttributedString
    let titleFrame: CGRect
    let reason: NSAttributedString
    let reasonFrame: CGRect
    let scopes: [(text: NSAttributedString, frame: CGRect, checkFrame: CGRect)]
    let declineFrame: CGRect
    let allowFrame: CGRect
    let declineTitle: NSAttributedString
    let allowTitle: NSAttributedString
    let size: CGSize
}

// MARK: - View

/// The agent's path of work inside its message: a thin rail with a dot for every step, live while the agent works and
/// collapsed into one summary line once it has answered.
public final class AgentRunView: UIView {
    public enum Action {
        case toggleStep(String)
        case togglePath
        case openSnippet(stepId: String)
        case permission(granted: Bool)
    }

    /// Asks the bubble for a relayout when the height has to change without a model update.
    public var requestRelayout: ((ContainedViewLayoutTransition) -> Void)?

    private let railLayer = CAShapeLayer()
    private let separatorLayer = CALayer()
    private var summaryView: AgentRunSummaryView?
    private var rowViews: [String: AgentRunRowView] = [:]

    private var currentLayout: AgentRunLayout?
    private var currentRun: AgentRun?
    private var isVisible = false
    private var displayLink: SharedDisplayLinkDriver.Link?
    private var displayLinkFps = 0

    /// Runs whose summary has already played its reveal, so it plays once per run.
    private static var revealedSummaries = Set<Int64>()

    override public init(frame: CGRect) {
        super.init(frame: frame)

        self.railLayer.fillColor = nil
        self.railLayer.lineWidth = 1.0
        self.railLayer.lineCap = .round
        self.layer.addSublayer(self.railLayer)
        self.layer.addSublayer(self.separatorLayer)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.displayLink?.invalidate()
    }

    // MARK: Layout

    private struct Metrics {
        let railX: CGFloat
        let textX: CGFloat
        let rowPadding: CGFloat
        let contentSpacing: CGFloat
        let durationWidth: CGFloat
        let chevronWidth: CGFloat
        let summaryHeight: CGFloat

        init(theme: AgentChatTheme) {
            self.railX = 7.0
            self.textX = theme.size(22.0)
            self.rowPadding = theme.size(5.0)
            self.contentSpacing = theme.size(7.0)
            self.durationWidth = theme.size(44.0)
            self.chevronWidth = theme.size(18.0)
            self.summaryHeight = theme.size(30.0)
        }
    }

    /// Thread-safe: measures with Core Text and creates no views.
    public static func layout(run: AgentRun, uiState: AgentRunUIState, hasAnswerBelow: Bool, width: CGFloat, theme: AgentChatTheme, now: Double) -> AgentRunLayout {
        let metrics = Metrics(theme: theme)
        var y: CGFloat = 0.0
        var summary: AgentRunSummaryLayout?
        var rows: [AgentRunRowLayout] = []

        let isPathLive = run.isPathLive
        let showsPath = isPathLive || uiState.isPathExpanded

        if !isPathLive {
            let text = NSAttributedString(string: AgentFormatting.summary(run: run, now: now, isRussian: theme.isRussian), font: theme.bodyFont, textColor: theme.secondary)
            let textSize = AgentTextMeasure.singleLine(text, maxWidth: width - metrics.textX - metrics.chevronWidth)
            let frame = CGRect(x: 0.0, y: y, width: width, height: metrics.summaryHeight)
            summary = AgentRunSummaryLayout(frame: frame, text: text, textFrame: CGRect(x: metrics.textX, y: floor((frame.height - textSize.height) / 2.0), width: textSize.width, height: textSize.height), isExpanded: uiState.isPathExpanded)
            y += frame.height
        }

        if showsPath {
            var steps = run.steps
            if steps.isEmpty && isPathLive {
                // The run message exists a moment before its first step; it starts thinking right away.
                steps = [AgentStep(id: "think-1", kind: .thinking, status: .active, icon: .thinking, title: theme.text("Думаю…", "Thinking…"), startedAt: run.startedAt)]
            }

            var foldedCount = 0
            if isPathLive && !uiState.isPathExpanded && steps.count > 6 {
                let candidates = steps.prefix(steps.count - 5)
                let foldable = candidates.prefix(while: { $0.status == .done || $0.status == .failed })
                if foldable.count >= 2 {
                    foldedCount = foldable.count
                    steps.removeFirst(foldedCount)
                }
            }

            if foldedCount != 0 {
                let row = self.foldedRowLayout(count: foldedCount, y: y, width: width, theme: theme, metrics: metrics)
                rows.append(row)
                y += row.frame.height
            }
            for step in steps {
                let row = self.rowLayout(step: step, isExpanded: uiState.expandedStepIds.contains(step.id), y: y, width: width, theme: theme, metrics: metrics)
                rows.append(row)
                y += row.frame.height
            }
        }

        var separatorY: CGFloat?
        if hasAnswerBelow && (summary != nil || !rows.isEmpty) {
            y += theme.size(4.0)
            separatorY = y
            y += theme.size(3.0)
        }

        var rail: (top: CGFloat, bottom: CGFloat)?
        if rows.count >= 2, let first = rows.first, let last = rows.last {
            rail = (first.frame.minY + first.dotCenter.y, last.frame.minY + last.dotCenter.y)
        }

        return AgentRunLayout(size: CGSize(width: width, height: ceil(y)), width: width, theme: theme, summary: summary, rows: rows, rail: rail, separatorY: separatorY)
    }

    private static func foldedRowLayout(count: Int, y: CGFloat, width: CGFloat, theme: AgentChatTheme, metrics: Metrics) -> AgentRunRowLayout {
        let title = NSAttributedString(string: theme.isRussian ? "+\(AgentFormatting.steps(count, isRussian: true))" : "+\(AgentFormatting.steps(count, isRussian: false))", font: theme.titleFont, textColor: theme.secondary)
        let titleSize = AgentTextMeasure.singleLine(title, maxWidth: width - metrics.textX)
        let height = metrics.rowPadding * 2.0 + titleSize.height
        return AgentRunRowLayout(id: "folded", kind: .folded(count), frame: CGRect(x: 0.0, y: y, width: width, height: height), headerHeight: height, dotCenter: CGPoint(x: metrics.railX, y: metrics.rowPadding + titleSize.height / 2.0), title: title, titleFrame: CGRect(x: metrics.textX, y: metrics.rowPadding, width: titleSize.width, height: titleSize.height), titleLines: 1, detail: nil, detailFrame: CGRect(), durationFrame: nil, chevronFrame: nil, isExpanded: false, content: nil)
    }

    private static func rowLayout(step: AgentStep, isExpanded: Bool, y: CGFloat, width: CGFloat, theme: AgentChatTheme, metrics: Metrics) -> AgentRunRowLayout {
        let contentWidth = width - metrics.textX
        let hasDuration = step.kind == .thinking || step.kind == .tool
        let hasChevron = step.isExpandable && !(step.status == .active && step.liveCode != nil)
        let trailing = (hasDuration ? metrics.durationWidth : 0.0) + (hasChevron ? metrics.chevronWidth : 0.0)

        let titleColor: UIColor
        switch step.status {
        case .failed:
            titleColor = theme.destructive
        case .stopped:
            titleColor = theme.secondary
        case .active, .done, .waiting:
            titleColor = step.kind == .thinking ? theme.secondary : theme.primary
        }

        let titleString: String
        switch step.kind {
        case .note:
            titleString = step.noteText ?? ""
        case .plan:
            let items = step.planItems ?? []
            let done = items.filter(\.isDone).count
            titleString = theme.isRussian ? "План · \(done) из \(items.count)" : "Plan · \(done) of \(items.count)"
        case .thinking, .tool, .permission:
            if step.status == .stopped {
                titleString = theme.text("Остановлено", "Stopped")
            } else {
                titleString = step.displayTitle
            }
        }
        let title = NSAttributedString(string: titleString, font: step.kind == .plan ? theme.titleMediumFont : theme.titleFont, textColor: titleColor)

        let titleLines = step.kind == .note ? 0 : 1
        let titleSize: CGSize
        if titleLines == 1 {
            titleSize = AgentTextMeasure.singleLine(title, maxWidth: contentWidth - trailing)
        } else {
            titleSize = AgentTextMeasure.size(title, width: contentWidth)
        }
        let titleFrame = CGRect(x: metrics.textX, y: metrics.rowPadding, width: titleSize.width, height: titleSize.height)

        var headerBottom = titleFrame.maxY
        var detail: NSAttributedString?
        var detailFrame = CGRect()
        if step.kind == .tool || step.kind == .thinking, step.status != .stopped, let detailString = step.displayDetail, !detailString.isEmpty {
            let detailString = NSAttributedString(string: detailString, font: theme.detailFont, textColor: step.status == .failed ? theme.destructive.withAlphaComponent(0.8) : theme.secondary)
            let size = AgentTextMeasure.singleLine(detailString, maxWidth: contentWidth - trailing)
            detailFrame = CGRect(x: metrics.textX, y: headerBottom + 1.0, width: size.width, height: size.height)
            detail = detailString
            headerBottom = detailFrame.maxY
        }
        let headerHeight = headerBottom + metrics.rowPadding

        let lineHeight = theme.titleFont.lineHeight
        let dotCenter = CGPoint(x: metrics.railX, y: metrics.rowPadding + floor(min(titleSize.height, lineHeight) / 2.0))

        var durationFrame: CGRect?
        var chevronFrame: CGRect?
        var trailingX = width
        if hasChevron {
            let size = theme.size(14.0)
            chevronFrame = CGRect(x: trailingX - size, y: dotCenter.y - size / 2.0, width: size, height: size)
            trailingX -= metrics.chevronWidth
        }
        if hasDuration {
            let height = ceil(theme.durationFont.lineHeight)
            durationFrame = CGRect(x: trailingX - metrics.durationWidth, y: dotCenter.y - height / 2.0, width: metrics.durationWidth, height: height)
        }

        var content: AgentRunContentLayout?
        let contentOrigin = CGPoint(x: metrics.textX, y: headerBottom + metrics.contentSpacing)
        switch step.kind {
        case .thinking:
            if isExpanded, let text = step.thinkingText, !text.isEmpty {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 2.0
                let string = NSAttributedString(string: text, attributes: [.font: theme.bodyFont, .foregroundColor: theme.secondary, .paragraphStyle: paragraph])
                let size = AgentTextMeasure.size(string, width: contentWidth)
                content = .text(string, CGRect(origin: contentOrigin, size: size))
            }
        case .tool:
            if step.status == .active, let liveCode = step.liveCode {
                let layout = self.liveCodeLayout(liveCode: liveCode, width: contentWidth, theme: theme)
                content = .liveCode(layout, CGRect(origin: contentOrigin, size: layout.size))
            } else if isExpanded {
                let layout = self.ioLayout(step: step, width: contentWidth, theme: theme)
                if !layout.sections.isEmpty {
                    content = .io(layout, CGRect(origin: contentOrigin, size: layout.size))
                }
            }
        case .plan:
            let layout = self.planLayout(items: step.planItems ?? [], width: contentWidth, theme: theme)
            if !layout.items.isEmpty {
                content = .plan(layout, CGRect(x: contentOrigin.x, y: headerBottom + theme.size(4.0), width: layout.size.width, height: layout.size.height))
            }
        case .permission:
            if step.status == .waiting, let permission = step.permission {
                let layout = self.permissionLayout(permission: permission, width: contentWidth, theme: theme)
                content = .permission(layout, CGRect(origin: contentOrigin, size: layout.size))
            }
        case .note:
            break
        }

        var height = headerHeight
        if let content {
            height = content.frame.maxY + metrics.rowPadding + theme.size(3.0)
        }

        return AgentRunRowLayout(id: step.id, kind: .step(step), frame: CGRect(x: 0.0, y: y, width: width, height: ceil(height)), headerHeight: headerHeight, dotCenter: dotCenter, title: title, titleFrame: titleFrame, titleLines: titleLines, detail: detail, detailFrame: detailFrame, durationFrame: durationFrame, chevronFrame: chevronFrame, isExpanded: isExpanded, content: content)
    }

    private static func planLayout(items: [AgentPlanItem], width: CGFloat, theme: AgentChatTheme) -> AgentPlanLayout {
        var result: [AgentPlanLayout.Item] = []
        var y: CGFloat = 0.0
        let circleSize = theme.size(15.0)
        let rowHeight = max(ceil(theme.bodyFont.lineHeight), circleSize) + theme.size(6.0)
        for item in items {
            let title = NSAttributedString(string: item.title, font: theme.bodyFont, textColor: item.isDone ? theme.secondary : theme.primary)
            let textX = circleSize + theme.size(8.0)
            let size = AgentTextMeasure.singleLine(title, maxWidth: width - textX)
            result.append(AgentPlanLayout.Item(title: title, titleFrame: CGRect(x: textX, y: y + floor((rowHeight - size.height) / 2.0), width: size.width, height: size.height), circleFrame: CGRect(x: 0.0, y: y + floor((rowHeight - circleSize) / 2.0), width: circleSize, height: circleSize), isDone: item.isDone))
            y += rowHeight
        }
        return AgentPlanLayout(items: result, size: CGSize(width: width, height: y))
    }

    static let ioMaxLines = 8

    private static func ioLayout(step: AgentStep, width: CGFloat, theme: AgentChatTheme) -> AgentIOLayout {
        let padding = theme.size(10.0)
        var sections: [AgentIOLayout.Section] = []
        var y = padding
        var totalLines = 0
        var isTruncated = false
        let codeFont = theme.codeFont
        let pairs: [(String, AgentSnippet?)] = [(theme.text("ВВОД", "IN"), step.input), (theme.text("ВЫВОД", "OUT"), step.output)]
        for (labelText, snippet) in pairs {
            guard let snippet, !snippet.text.isEmpty else {
                continue
            }
            if !sections.isEmpty {
                y += theme.size(10.0)
            }
            let label = NSAttributedString(string: labelText, attributes: [.font: theme.captionFont, .foregroundColor: theme.secondary, .kern: 0.3 as NSNumber])
            let labelSize = AgentTextMeasure.singleLine(label, maxWidth: width - padding * 2.0)
            let labelFrame = CGRect(x: padding, y: y, width: labelSize.width, height: labelSize.height)
            y = labelFrame.maxY + theme.size(4.0)

            let lines = snippet.text.components(separatedBy: "\n")
            totalLines = max(totalLines, lines.count)
            let visible = Array(lines.prefix(self.ioMaxLines))
            if lines.count > visible.count {
                isTruncated = true
            }
            let code = visible.joined(separator: "\n")
            let codeHeight = ceil(codeFont.lineHeight * CGFloat(visible.count))
            let codeFrame = CGRect(x: padding, y: y, width: width - padding * 2.0, height: codeHeight)
            y = codeFrame.maxY
            sections.append(AgentIOLayout.Section(label: label, labelFrame: labelFrame, code: code, language: snippet.language, codeFrame: codeFrame))
        }
        var showAll: NSAttributedString?
        var showAllFrame: CGRect?
        if isTruncated {
            y += theme.size(8.0)
            let string = NSAttributedString(string: theme.isRussian ? "Показать всё (\(AgentFormatting.lines(totalLines, isRussian: true)))" : "Show all (\(AgentFormatting.lines(totalLines, isRussian: false)))", font: theme.detailFont, textColor: theme.accent)
            let size = AgentTextMeasure.singleLine(string, maxWidth: width - padding * 2.0)
            showAllFrame = CGRect(x: padding, y: y, width: size.width, height: size.height)
            showAll = string
            y += size.height
        }
        y += padding
        return AgentIOLayout(sections: sections, showAll: showAll, showAllFrame: showAllFrame, size: CGSize(width: width, height: sections.isEmpty ? 0.0 : y))
    }

    static let liveCodeVisibleLines = 8

    private static func liveCodeLayout(liveCode: AgentLiveCode, width: CGFloat, theme: AgentChatTheme) -> AgentLiveCodeLayout {
        let padding = theme.size(10.0)
        let headerHeight = theme.size(28.0)
        let iconSize = theme.size(16.0)
        let fileName = NSAttributedString(string: liveCode.fileName, font: Font.medium(theme.size(13.0)), textColor: theme.primary)
        let counterWidth = theme.size(80.0)
        let nameSize = AgentTextMeasure.singleLine(fileName, maxWidth: width - padding * 2.0 - iconSize - theme.size(6.0) - counterWidth)
        let lineHeight = ceil(theme.codeFont.lineHeight)
        let bodyHeight = lineHeight * CGFloat(self.liveCodeVisibleLines)
        let bodyFrame = CGRect(x: padding, y: headerHeight, width: width - padding * 2.0, height: bodyHeight)
        return AgentLiveCodeLayout(
            fileName: fileName,
            fileNameFrame: CGRect(x: padding + iconSize + theme.size(6.0), y: floor((headerHeight - nameSize.height) / 2.0) + 1.0, width: nameSize.width, height: nameSize.height),
            iconFrame: CGRect(x: padding, y: floor((headerHeight - iconSize) / 2.0) + 1.0, width: iconSize, height: iconSize),
            counterFrame: CGRect(x: width - padding - counterWidth, y: floor((headerHeight - nameSize.height) / 2.0) + 1.0, width: counterWidth, height: nameSize.height),
            bodyFrame: bodyFrame,
            lineHeight: lineHeight,
            liveCode: liveCode,
            size: CGSize(width: width, height: bodyFrame.maxY + padding)
        )
    }

    private static func permissionLayout(permission: AgentPermission, width: CGFloat, theme: AgentChatTheme) -> AgentPermissionLayout {
        let padding = theme.size(12.0)
        let tileSize = theme.size(40.0)
        let textX = padding + tileSize + theme.size(10.0)
        let textWidth = width - textX - padding
        let title = NSAttributedString(string: theme.isRussian ? "Подключить \(permission.serviceTitle)" : "Connect \(permission.serviceTitle)", font: Font.semibold(theme.size(15.0)), textColor: theme.primary)
        let titleSize = AgentTextMeasure.size(title, width: textWidth, maxLines: 2)
        let reason = NSAttributedString(string: permission.reason, font: theme.detailFont, textColor: theme.secondary)
        let reasonSize = AgentTextMeasure.size(reason, width: textWidth, maxLines: 2)
        let textHeight = titleSize.height + 2.0 + reasonSize.height
        let headerHeight = max(tileSize, textHeight)
        let tileFrame = CGRect(x: padding, y: padding + floor((headerHeight - tileSize) / 2.0), width: tileSize, height: tileSize)
        let titleFrame = CGRect(x: textX, y: padding + floor((headerHeight - textHeight) / 2.0), width: titleSize.width, height: titleSize.height)
        let reasonFrame = CGRect(x: textX, y: titleFrame.maxY + 2.0, width: reasonSize.width, height: reasonSize.height)

        var y = padding + headerHeight + theme.size(10.0)
        var scopes: [(text: NSAttributedString, frame: CGRect, checkFrame: CGRect)] = []
        let checkSize = theme.size(14.0)
        for scope in permission.scopes {
            let text = NSAttributedString(string: scope, font: theme.detailFont, textColor: theme.primary)
            let size = AgentTextMeasure.singleLine(text, maxWidth: width - padding * 2.0 - checkSize - theme.size(8.0))
            let rowHeight = max(size.height, checkSize) + theme.size(4.0)
            scopes.append((text, CGRect(x: padding + checkSize + theme.size(8.0), y: y + floor((rowHeight - size.height) / 2.0), width: size.width, height: size.height), CGRect(x: padding, y: y + floor((rowHeight - checkSize) / 2.0), width: checkSize, height: checkSize)))
            y += rowHeight
        }
        y += theme.size(10.0)
        let buttonHeight = theme.size(36.0)
        let buttonSpacing = theme.size(8.0)
        let buttonWidth = floor((width - padding * 2.0 - buttonSpacing) / 2.0)
        let declineFrame = CGRect(x: padding, y: y, width: buttonWidth, height: buttonHeight)
        let allowFrame = CGRect(x: width - padding - buttonWidth, y: y, width: buttonWidth, height: buttonHeight)
        y += buttonHeight + padding
        return AgentPermissionLayout(
            tileFrame: tileFrame,
            title: title,
            titleFrame: titleFrame,
            reason: reason,
            reasonFrame: reasonFrame,
            scopes: scopes,
            declineFrame: declineFrame,
            allowFrame: allowFrame,
            declineTitle: NSAttributedString(string: theme.text("Не сейчас", "Not Now"), font: Font.medium(theme.size(15.0)), textColor: theme.secondary),
            allowTitle: NSAttributedString(string: theme.text("Разрешить", "Allow"), font: Font.semibold(theme.size(15.0)), textColor: theme.accent),
            size: CGSize(width: width, height: y)
        )
    }

    // MARK: Apply

    public func apply(layout: AgentRunLayout, run: AgentRun, theme: AgentChatTheme, transition: ContainedViewLayoutTransition, now: Double) {
        let previousLayout = self.currentLayout
        self.currentLayout = layout
        self.currentRun = run

        // Summary.
        if let summaryLayout = layout.summary {
            let summaryView: AgentRunSummaryView
            var isNew = false
            if let current = self.summaryView {
                summaryView = current
            } else {
                summaryView = AgentRunSummaryView()
                self.summaryView = summaryView
                self.addSubview(summaryView)
                isNew = true
            }
            let playsReveal = isNew && previousLayout != nil && !AgentRunView.revealedSummaries.contains(run.id)
            AgentRunView.revealedSummaries.insert(run.id)
            if isNew {
                summaryView.frame = summaryLayout.frame
            } else {
                transition.updateFrame(view: summaryView, frame: summaryLayout.frame)
            }
            summaryView.update(layout: summaryLayout, theme: theme, transition: isNew ? .immediate : transition)
            if isNew && transition.isAnimated {
                summaryView.alpha = 0.0
                ContainedViewLayoutTransition.animated(duration: 0.25, curve: .easeInOut).updateAlpha(layer: summaryView.layer, alpha: 1.0)
                summaryView.layer.animatePosition(from: CGPoint(x: 0.0, y: 4.0), to: CGPoint(), duration: 0.25, delay: 0.08, additive: true)
            }
            if playsReveal {
                summaryView.playReveal(flashColor: theme.accent)
            }
        } else if let summaryView = self.summaryView {
            self.summaryView = nil
            transition.updateAlpha(layer: summaryView.layer, alpha: 0.0, completion: { [weak summaryView] _ in
                summaryView?.removeFromSuperview()
            })
        }

        // Rows.
        var validIds = Set<String>()
        for rowLayout in layout.rows {
            validIds.insert(rowLayout.id)
            if let rowView = self.rowViews[rowLayout.id] {
                transition.updateFrame(view: rowView, frame: rowLayout.frame)
                rowView.update(layout: rowLayout, theme: theme, now: now, transition: transition, animateAppearance: false, onRelayout: { [weak self] in
                    self?.requestRelayout?(.immediate)
                })
            } else {
                let rowView = AgentRunRowView()
                self.rowViews[rowLayout.id] = rowView
                self.addSubview(rowView)
                rowView.frame = rowLayout.frame
                rowView.update(layout: rowLayout, theme: theme, now: now, transition: .immediate, animateAppearance: transition.isAnimated, onRelayout: { [weak self] in
                    self?.requestRelayout?(.immediate)
                })
                if transition.isAnimated {
                    rowView.alpha = 0.0
                    ContainedViewLayoutTransition.animated(duration: 0.2, curve: .easeInOut).updateAlpha(layer: rowView.layer, alpha: 1.0)
                    rowView.layer.animatePosition(from: CGPoint(x: 0.0, y: 6.0), to: CGPoint(), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
                }
            }
        }
        for (id, rowView) in self.rowViews where !validIds.contains(id) {
            self.rowViews.removeValue(forKey: id)
            if transition.isAnimated {
                ContainedViewLayoutTransition.animated(duration: 0.2, curve: .easeInOut).updateAlpha(layer: rowView.layer, alpha: 0.0, completion: { [weak rowView] _ in
                    rowView?.removeFromSuperview()
                })
            } else {
                rowView.removeFromSuperview()
            }
        }

        // Rail.
        self.railLayer.strokeColor = theme.railColor.cgColor
        let railPath = CGMutablePath()
        if let rail = layout.rail {
            railPath.move(to: CGPoint(x: 7.0, y: rail.top))
            railPath.addLine(to: CGPoint(x: 7.0, y: rail.bottom))
        } else if let first = layout.rows.first {
            let y = first.frame.minY + first.dotCenter.y
            railPath.move(to: CGPoint(x: 7.0, y: y))
            railPath.addLine(to: CGPoint(x: 7.0, y: y))
        }
        if self.railLayer.path == nil || !transition.isAnimated {
            self.railLayer.path = railPath
        } else {
            transition.updatePath(layer: self.railLayer, path: railPath)
        }

        // Separator above the answer.
        self.separatorLayer.backgroundColor = theme.secondary.withAlphaComponent(0.18).cgColor
        if let separatorY = layout.separatorY {
            let frame = CGRect(x: 0.0, y: separatorY, width: layout.width, height: UIScreenPixel)
            if self.separatorLayer.opacity == 0.0 || self.separatorLayer.frame.isEmpty {
                self.separatorLayer.frame = frame
                transition.updateAlpha(layer: self.separatorLayer, alpha: 1.0)
            } else {
                transition.updateFrame(layer: self.separatorLayer, frame: frame)
            }
        } else {
            transition.updateAlpha(layer: self.separatorLayer, alpha: 0.0)
        }

        self.updateDisplayLink()
    }

    public func updateIsVisible(_ isVisible: Bool) {
        if self.isVisible != isVisible {
            self.isVisible = isVisible
            self.updateDisplayLink()
        }
    }

    private func updateDisplayLink() {
        guard let run = self.currentRun, self.isVisible, run.isPathLive else {
            self.displayLink?.invalidate()
            self.displayLink = nil
            self.displayLinkFps = 0
            return
        }
        let hasLiveCode = run.steps.contains(where: { $0.status == .active && $0.liveCode != nil })
        let fps = hasLiveCode ? 30 : 4
        if self.displayLink == nil || self.displayLinkFps != fps {
            self.displayLink?.invalidate()
            self.displayLinkFps = fps
            self.displayLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: .fps(fps), { [weak self] _ in
                self?.tick()
            })
        }
    }

    private func tick() {
        guard let layout = self.currentLayout else {
            return
        }
        let now = Date().timeIntervalSince1970
        for row in layout.rows {
            self.rowViews[row.id]?.tick(layout: row, theme: layout.theme, now: now)
        }
    }

    // MARK: Taps

    public func action(at point: CGPoint) -> Action? {
        guard let layout = self.currentLayout else {
            return nil
        }
        if let summary = layout.summary, summary.frame.contains(point) {
            return .togglePath
        }
        for row in layout.rows where row.frame.contains(point) {
            let local = CGPoint(x: point.x - row.frame.minX, y: point.y - row.frame.minY)
            if case .folded = row.kind {
                return .togglePath
            }
            guard let step = row.step else {
                continue
            }
            if let content = row.content {
                switch content {
                case let .io(io, frame):
                    if let showAllFrame = io.showAllFrame, showAllFrame.offsetBy(dx: frame.minX, dy: frame.minY).insetBy(dx: -8.0, dy: -8.0).contains(local) {
                        return .openSnippet(stepId: step.id)
                    }
                case let .permission(permission, frame):
                    if permission.allowFrame.offsetBy(dx: frame.minX, dy: frame.minY).contains(local) {
                        return .permission(granted: true)
                    }
                    if permission.declineFrame.offsetBy(dx: frame.minX, dy: frame.minY).contains(local) {
                        return .permission(granted: false)
                    }
                    return nil
                case .text, .plan, .liveCode:
                    break
                }
            }
            if step.isExpandable && local.y <= row.headerHeight + 4.0 {
                return .toggleStep(step.id)
            }
            if case .text = row.content, step.isExpandable {
                return .toggleStep(step.id)
            }
        }
        return nil
    }
}

// MARK: - Summary row

private final class AgentRunSummaryView: UIView {
    private let glyphView = UIImageView()
    private let textView = AsciiTextRevealView()
    private let chevronView = UIImageView()
    private var theme: AgentChatTheme?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.glyphView)
        self.addSubview(self.textView)
        self.addSubview(self.chevronView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(layout: AgentRunSummaryLayout, theme: AgentChatTheme, transition: ContainedViewLayoutTransition) {
        if self.theme != theme {
            self.theme = theme
            self.glyphView.image = AgentGlyphs.path(size: CGSize(width: 6.0, height: theme.size(16.0)), color: theme.secondary)
            self.chevronView.image = AgentGlyphs.chevron(size: theme.size(14.0), color: theme.secondary.withAlphaComponent(0.7))
        }
        let glyphSize = self.glyphView.image?.size ?? CGSize()
        self.glyphView.frame = CGRect(x: 7.0 - glyphSize.width / 2.0, y: floor((layout.frame.height - glyphSize.height) / 2.0), width: glyphSize.width, height: glyphSize.height)
        self.textView.update(text: layout.text, size: layout.textFrame.size)
        transition.updateFrame(view: self.textView, frame: layout.textFrame)
        let chevronSize = self.chevronView.image?.size ?? CGSize()
        let chevronFrame = CGRect(x: layout.frame.width - chevronSize.width, y: floor((layout.frame.height - chevronSize.height) / 2.0), width: chevronSize.width, height: chevronSize.height)
        self.chevronView.center = CGPoint(x: chevronFrame.midX, y: chevronFrame.midY)
        self.chevronView.bounds = CGRect(origin: CGPoint(), size: chevronSize)
        transition.updateTransformRotation(view: self.chevronView, angle: layout.isExpanded ? CGFloat.pi / 2.0 : 0.0)
    }

    func playReveal(flashColor: UIColor) {
        self.textView.playReveal(preset: .decode, pace: .fast, flashColor: flashColor, completion: nil)
    }
}

// MARK: - Row

private final class AgentRunRowView: UIView {
    private let dotLayer = CAShapeLayer()
    private let pulseLayer = CAShapeLayer()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let durationLabel = UILabel()
    private let chevronView = UIImageView()
    private var contentView: UIView?
    private var contentKey: String?

    private var status: AgentStep.Status?
    private var isShimmering = false
    private var theme: AgentChatTheme?
    private var durationText: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.clipsToBounds = true

        self.pulseLayer.fillColor = nil
        self.pulseLayer.lineWidth = 1.5
        self.pulseLayer.opacity = 0.0
        self.layer.addSublayer(self.pulseLayer)
        self.layer.addSublayer(self.dotLayer)

        self.titleLabel.lineBreakMode = .byTruncatingTail
        self.detailLabel.lineBreakMode = .byTruncatingTail
        self.durationLabel.textAlignment = .right
        self.addSubview(self.titleLabel)
        self.addSubview(self.detailLabel)
        self.addSubview(self.durationLabel)
        self.addSubview(self.chevronView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(layout: AgentRunRowLayout, theme: AgentChatTheme, now: Double, transition: ContainedViewLayoutTransition, animateAppearance: Bool, onRelayout: @escaping () -> Void) {
        let themeUpdated = self.theme != theme
        self.theme = theme

        // Title: crossfades when its text changes (e.g. "Searching the web" -> "Found 8 sources").
        if let current = self.titleLabel.attributedText, !current.isEqual(to: layout.title), transition.isAnimated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            self.titleLabel.layer.add(fade, forKey: "fade")
        }
        self.titleLabel.attributedText = layout.title
        self.titleLabel.numberOfLines = layout.titleLines
        transition.updateFrame(view: self.titleLabel, frame: layout.titleFrame)

        if let detail = layout.detail {
            if let current = self.detailLabel.attributedText, !current.isEqual(to: detail), transition.isAnimated {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.2
                self.detailLabel.layer.add(fade, forKey: "fade")
            }
            self.detailLabel.attributedText = detail
            transition.updateFrame(view: self.detailLabel, frame: layout.detailFrame)
            transition.updateAlpha(layer: self.detailLabel.layer, alpha: 1.0)
        } else {
            transition.updateAlpha(layer: self.detailLabel.layer, alpha: 0.0)
        }

        if let chevronFrame = layout.chevronFrame {
            if themeUpdated || self.chevronView.image == nil {
                self.chevronView.image = AgentGlyphs.chevron(size: chevronFrame.width, color: theme.secondary.withAlphaComponent(0.7))
            }
            self.chevronView.center = CGPoint(x: chevronFrame.midX, y: chevronFrame.midY)
            self.chevronView.bounds = CGRect(origin: CGPoint(), size: chevronFrame.size)
            transition.updateTransformRotation(view: self.chevronView, angle: layout.isExpanded ? CGFloat.pi / 2.0 : 0.0)
            transition.updateAlpha(layer: self.chevronView.layer, alpha: 1.0)
        } else {
            transition.updateAlpha(layer: self.chevronView.layer, alpha: 0.0)
        }

        self.updateDot(layout: layout, theme: theme, transition: transition, animateAppearance: animateAppearance)
        self.updateDuration(layout: layout, theme: theme, now: now)
        self.updateShimmer(isActive: layout.step?.status == .active && layout.step?.kind != .plan)
        self.updateContent(layout: layout, theme: theme, now: now, transition: transition, onRelayout: onRelayout)
    }

    func tick(layout: AgentRunRowLayout, theme: AgentChatTheme, now: Double) {
        self.updateDuration(layout: layout, theme: theme, now: now)
        if let liveCodeView = self.contentView as? AgentLiveCodeCardView, case let .liveCode(liveCodeLayout, _) = layout.content, let step = layout.step {
            liveCodeView.tick(layout: liveCodeLayout, step: step, now: now)
        }
    }

    private func updateDot(layout: AgentRunRowLayout, theme: AgentChatTheme, transition: ContainedViewLayoutTransition, animateAppearance: Bool) {
        let status: AgentStep.Status
        switch layout.kind {
        case let .step(step):
            status = step.status
        case .folded:
            status = .done
        }
        let previousStatus = self.status
        self.status = status

        let center = layout.dotCenter
        let radius: CGFloat = status == .active || status == .waiting ? 4.0 : 3.5
        let dotFrame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0)
        self.dotLayer.path = CGPath(ellipseIn: CGRect(origin: CGPoint(), size: dotFrame.size), transform: nil)
        transition.updateFrame(layer: self.dotLayer, frame: dotFrame)

        switch status {
        case .active:
            self.dotLayer.fillColor = theme.accentControl.cgColor
            self.dotLayer.strokeColor = nil
        case .done:
            self.dotLayer.fillColor = theme.secondary.withAlphaComponent(0.55).cgColor
            self.dotLayer.strokeColor = nil
        case .failed:
            self.dotLayer.fillColor = theme.destructive.cgColor
            self.dotLayer.strokeColor = nil
        case .waiting:
            self.dotLayer.fillColor = UIColor.clear.cgColor
            self.dotLayer.strokeColor = theme.accentControl.cgColor
            self.dotLayer.lineWidth = 1.5
        case .stopped:
            self.dotLayer.fillColor = UIColor.clear.cgColor
            self.dotLayer.strokeColor = theme.secondary.withAlphaComponent(0.55).cgColor
            self.dotLayer.lineWidth = 1.5
        }

        // The pulse of the step being worked on.
        let pulseRadius: CGFloat = 4.0
        self.pulseLayer.frame = CGRect(x: center.x - pulseRadius, y: center.y - pulseRadius, width: pulseRadius * 2.0, height: pulseRadius * 2.0)
        self.pulseLayer.path = CGPath(ellipseIn: CGRect(x: 0.0, y: 0.0, width: pulseRadius * 2.0, height: pulseRadius * 2.0), transform: nil)
        self.pulseLayer.strokeColor = theme.accentControl.cgColor
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if status == .active && !reduceMotion {
            if self.pulseLayer.animation(forKey: "pulse") == nil {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 1.0
                scale.toValue = 2.4
                let opacity = CABasicAnimation(keyPath: "opacity")
                opacity.fromValue = 0.4
                opacity.toValue = 0.0
                let group = CAAnimationGroup()
                group.animations = [scale, opacity]
                group.duration = 1.6
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.repeatCount = .infinity
                group.isRemovedOnCompletion = false
                self.pulseLayer.add(group, forKey: "pulse")
            }
        } else {
            self.pulseLayer.removeAnimation(forKey: "pulse")
        }

        if status == .waiting && !reduceMotion {
            if self.dotLayer.animation(forKey: "breathe") == nil {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 1.0
                breathe.toValue = 0.45
                breathe.duration = 1.2
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.dotLayer.add(breathe, forKey: "breathe")
            }
        } else {
            self.dotLayer.removeAnimation(forKey: "breathe")
        }

        if animateAppearance && !reduceMotion {
            self.dotLayer.animateSpring(from: 0.4 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.35)
        } else if let previousStatus, previousStatus == .active, status == .done, transition.isAnimated, !reduceMotion {
            // A small pop when a step completes.
            self.dotLayer.animateSpring(from: 1.45 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.4)
        }
    }

    private func updateDuration(layout: AgentRunRowLayout, theme: AgentChatTheme, now: Double) {
        guard let frame = layout.durationFrame, let step = layout.step, step.status != .stopped else {
            self.durationLabel.isHidden = true
            return
        }
        self.durationLabel.isHidden = false
        let text = AgentFormatting.duration(step.duration(at: now), isRussian: theme.isRussian)
        if self.durationText != text {
            self.durationText = text
            self.durationLabel.attributedText = NSAttributedString(string: text, font: theme.durationFont, textColor: theme.secondary.withAlphaComponent(step.status == .active ? 1.0 : 0.8))
        }
        self.durationLabel.frame = frame
    }

    /// Telegram's AI thinking shimmer (peak alpha 0.3 over 1 s) on the title of the step being worked on.
    private func updateShimmer(isActive: Bool) {
        let isActive = isActive && !UIAccessibility.isReduceMotionEnabled
        let bounds = self.titleLabel.bounds
        if isActive {
            let mask: CAGradientLayer
            if let current = self.titleLabel.layer.mask as? CAGradientLayer {
                mask = current
            } else {
                mask = CAGradientLayer()
                mask.startPoint = CGPoint(x: 0.0, y: 0.5)
                mask.endPoint = CGPoint(x: 1.0, y: 0.5)
                mask.colors = [UIColor.white.cgColor, UIColor(white: 1.0, alpha: 0.3).cgColor, UIColor.white.cgColor]
                self.titleLabel.layer.mask = mask
            }
            let gradientWidth: CGFloat = 120.0
            let travel = bounds.width + gradientWidth
            let maskWidth = bounds.width + travel * 2.0
            let half = maskWidth > 0.0 ? (gradientWidth * 0.5) / maskWidth : 0.0
            mask.locations = [(0.5 - half) as NSNumber, 0.5 as NSNumber, (0.5 + half) as NSNumber]
            if !self.isShimmering || mask.bounds.width != maskWidth {
                mask.bounds = CGRect(x: 0.0, y: 0.0, width: maskWidth, height: max(1.0, bounds.height))
                mask.position = CGPoint(x: -gradientWidth * 0.5, y: bounds.height * 0.5)
                mask.removeAnimation(forKey: "shimmer")
                let animation = CABasicAnimation(keyPath: "position.x")
                animation.fromValue = 0.0
                animation.toValue = travel
                animation.isAdditive = true
                animation.duration = 1.0
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animation.repeatCount = .infinity
                mask.add(animation, forKey: "shimmer")
            }
            self.isShimmering = true
        } else if self.isShimmering {
            self.isShimmering = false
            self.titleLabel.layer.mask = nil
        }
    }

    private func updateContent(layout: AgentRunRowLayout, theme: AgentChatTheme, now: Double, transition: ContainedViewLayoutTransition, onRelayout: @escaping () -> Void) {
        guard let content = layout.content else {
            if let contentView = self.contentView {
                self.contentView = nil
                self.contentKey = nil
                if transition.isAnimated {
                    ContainedViewLayoutTransition.animated(duration: 0.18, curve: .easeInOut).updateAlpha(layer: contentView.layer, alpha: 0.0, completion: { [weak contentView] _ in
                        contentView?.removeFromSuperview()
                    })
                } else {
                    contentView.removeFromSuperview()
                }
            }
            return
        }

        var contentView = self.contentView
        if self.contentKey != content.kindKey {
            if let previous = contentView {
                if transition.isAnimated {
                    ContainedViewLayoutTransition.animated(duration: 0.18, curve: .easeInOut).updateAlpha(layer: previous.layer, alpha: 0.0, completion: { [weak previous] _ in
                        previous?.removeFromSuperview()
                    })
                } else {
                    previous.removeFromSuperview()
                }
            }
            let view: UIView
            switch content {
            case .text:
                let label = UILabel()
                label.numberOfLines = 0
                view = label
            case .plan:
                view = AgentPlanView()
            case .io:
                view = AgentIOCardView()
            case .liveCode:
                view = AgentLiveCodeCardView()
            case .permission:
                view = AgentPermissionCardView()
            }
            view.frame = content.frame
            self.addSubview(view)
            if transition.isAnimated {
                view.alpha = 0.0
                ContainedViewLayoutTransition.animated(duration: 0.18, curve: .easeInOut).updateAlpha(layer: view.layer, alpha: 1.0)
            }
            contentView = view
            self.contentView = view
            self.contentKey = content.kindKey
        } else if let contentView {
            transition.updateFrame(view: contentView, frame: content.frame)
        }

        switch content {
        case let .text(text, _):
            (contentView as? UILabel)?.attributedText = text
        case let .plan(plan, _):
            (contentView as? AgentPlanView)?.update(layout: plan, theme: theme, transition: transition)
        case let .io(io, _):
            (contentView as? AgentIOCardView)?.update(layout: io, theme: theme)
        case let .liveCode(liveCode, _):
            if let step = layout.step {
                (contentView as? AgentLiveCodeCardView)?.update(layout: liveCode, step: step, theme: theme, now: now)
            }
        case let .permission(permission, _):
            (contentView as? AgentPermissionCardView)?.update(layout: permission, theme: theme)
        }
    }
}

// MARK: - Plan

private final class AgentPlanView: UIView {
    private var itemViews: [(circle: CAShapeLayer, check: UIImageView, label: UILabel)] = []
    private var doneStates: [Bool] = []

    func update(layout: AgentPlanLayout, theme: AgentChatTheme, transition: ContainedViewLayoutTransition) {
        while self.itemViews.count < layout.items.count {
            let circle = CAShapeLayer()
            circle.lineWidth = 1.33
            self.layer.addSublayer(circle)
            let check = UIImageView()
            self.addSubview(check)
            let label = UILabel()
            self.addSubview(label)
            self.itemViews.append((circle, check, label))
            self.doneStates.append(false)
        }
        for (index, item) in layout.items.enumerated() {
            let views = self.itemViews[index]
            views.label.attributedText = item.title
            views.label.frame = item.titleFrame
            views.circle.frame = item.circleFrame
            views.circle.path = CGPath(ellipseIn: CGRect(origin: CGPoint(), size: item.circleFrame.size).insetBy(dx: 0.665, dy: 0.665), transform: nil)
            if item.isDone {
                views.circle.fillColor = theme.accentControl.cgColor
                views.circle.strokeColor = theme.accentControl.cgColor
            } else {
                views.circle.fillColor = UIColor.clear.cgColor
                views.circle.strokeColor = theme.secondary.withAlphaComponent(0.5).cgColor
            }
            if views.check.image == nil || views.check.bounds.size != item.circleFrame.size {
                views.check.image = AgentGlyphs.checkmark(size: item.circleFrame.width, color: .white, lineWidth: 1.5)
            }
            views.check.frame = item.circleFrame
            let wasDone = self.doneStates[index]
            self.doneStates[index] = item.isDone
            views.check.alpha = item.isDone ? 1.0 : 0.0
            if item.isDone && !wasDone && transition.isAnimated && !UIAccessibility.isReduceMotionEnabled {
                views.circle.animateSpring(from: 0.6 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.4)
                views.check.layer.animateSpring(from: 0.4 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.45)
                views.check.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15)
            }
        }
    }
}

// MARK: - Input / output card

private final class AgentIOCardView: UIView {
    private var labels: [UILabel] = []
    private var codeLabels: [UILabel] = []
    private let showAllLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerRadius = 10.0
        if #available(iOS 13.0, *) {
            self.layer.cornerCurve = .continuous
        }
        self.clipsToBounds = true
        self.addSubview(self.showAllLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(layout: AgentIOLayout, theme: AgentChatTheme) {
        self.backgroundColor = theme.cardColor
        while self.labels.count < layout.sections.count {
            let label = UILabel()
            self.addSubview(label)
            self.labels.append(label)
            let code = UILabel()
            code.numberOfLines = 0
            self.addSubview(code)
            self.codeLabels.append(code)
        }
        for (index, label) in self.labels.enumerated() {
            label.isHidden = index >= layout.sections.count
            self.codeLabels[index].isHidden = index >= layout.sections.count
        }
        for (index, section) in layout.sections.enumerated() {
            self.labels[index].attributedText = section.label
            self.labels[index].frame = section.labelFrame
            let codeLabel = self.codeLabels[index]
            codeLabel.attributedText = AgentSyntaxHighlighter.shared.attributedString(section.code, language: section.language, font: theme.codeFont, color: theme.primary, isDark: theme.isDark, updated: { [weak codeLabel] in
                guard let codeLabel else {
                    return
                }
                codeLabel.attributedText = AgentSyntaxHighlighter.shared.attributedString(section.code, language: section.language, font: theme.codeFont, color: theme.primary, isDark: theme.isDark, updated: nil)
            })
            codeLabel.frame = section.codeFrame
        }
        if let showAll = layout.showAll, let frame = layout.showAllFrame {
            self.showAllLabel.isHidden = false
            self.showAllLabel.attributedText = showAll
            self.showAllLabel.frame = frame
        } else {
            self.showAllLabel.isHidden = true
        }
    }
}

// MARK: - Live code card

private final class AgentLiveCodeCardView: UIView {
    private let iconView = UIImageView()
    private let fileNameLabel = UILabel()
    private let counterLabel = UILabel()
    private let codeView = AsciiTypingCodeView()
    private var theme: AgentChatTheme?
    private var codeText: String?
    private var lines: [NSAttributedString] = []
    private var visibleCount = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerRadius = 10.0
        if #available(iOS 13.0, *) {
            self.layer.cornerCurve = .continuous
        }
        self.clipsToBounds = true
        self.counterLabel.textAlignment = .right
        self.iconView.contentMode = .scaleAspectFit
        self.addSubview(self.iconView)
        self.addSubview(self.fileNameLabel)
        self.addSubview(self.counterLabel)
        self.addSubview(self.codeView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(layout: AgentLiveCodeLayout, step: AgentStep, theme: AgentChatTheme, now: Double) {
        if self.theme != theme {
            self.theme = theme
            self.backgroundColor = theme.cardColor
            self.iconView.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/File"), color: theme.secondary)
            self.codeText = nil
        }
        self.iconView.frame = layout.iconFrame
        self.fileNameLabel.attributedText = layout.fileName
        self.fileNameLabel.frame = layout.fileNameFrame
        self.counterLabel.frame = layout.counterFrame
        self.codeView.frame = layout.bodyFrame
        if self.codeText != layout.liveCode.text {
            self.codeText = layout.liveCode.text
            self.rebuildLines(layout: layout, theme: theme)
        }
        self.visibleCount = -1
        self.tick(layout: layout, step: step, now: now)
    }

    private func rebuildLines(layout: AgentLiveCodeLayout, theme: AgentChatTheme) {
        let text = layout.liveCode.text
        let highlighted = AgentSyntaxHighlighter.shared.attributedString(text, language: layout.liveCode.language, font: theme.codeFont, color: theme.primary, isDark: theme.isDark, updated: { [weak self] in
            guard let self, let theme = self.theme, self.codeText == text else {
                return
            }
            self.codeText = nil
            self.rebuildLines(layout: layout, theme: theme)
            self.codeText = text
            self.visibleCount = -1
        })
        var lines: [NSAttributedString] = []
        let nsString = highlighted.string as NSString
        var location = 0
        while location <= nsString.length {
            let range = nsString.range(of: "\n", options: [], range: NSRange(location: location, length: nsString.length - location))
            let end = range.location == NSNotFound ? nsString.length : range.location
            lines.append(highlighted.attributedSubstring(from: NSRange(location: location, length: end - location)))
            if range.location == NSNotFound {
                break
            }
            location = end + 1
        }
        self.lines = lines
    }

    func tick(layout: AgentLiveCodeLayout, step: AgentStep, now: Double) {
        guard let theme = self.theme else {
            return
        }
        let count = layout.liveCode.visibleLineCount(elapsed: now - step.startedAt)
        if count == self.visibleCount {
            return
        }
        self.visibleCount = count
        self.codeView.update(lines: self.lines, visibleLineCount: count, size: layout.bodyFrame.size, lineHeight: layout.lineHeight, cursorColor: theme.accentControl, scrambleColor: theme.secondary)
        self.counterLabel.attributedText = NSAttributedString(string: AgentFormatting.lines(count, isRussian: theme.isRussian), font: UIFont.monospacedDigitSystemFont(ofSize: theme.size(12.0), weight: .regular), textColor: theme.secondary)
    }
}

// MARK: - Permission card

private final class AgentPermissionCardView: UIView {
    private let tileView = UIView()
    private let tileIconView = UIImageView()
    private let titleLabel = UILabel()
    private let reasonLabel = UILabel()
    private var scopeViews: [(check: UIImageView, label: UILabel)] = []
    private let declineButton = UIView()
    private let declineLabel = UILabel()
    private let allowButton = UIView()
    private let allowLabel = UILabel()
    private var theme: AgentChatTheme?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerRadius = 12.0
        if #available(iOS 13.0, *) {
            self.layer.cornerCurve = .continuous
            self.tileView.layer.cornerCurve = .continuous
            self.declineButton.layer.cornerCurve = .continuous
            self.allowButton.layer.cornerCurve = .continuous
        }
        self.tileView.layer.cornerRadius = 10.0
        self.tileIconView.contentMode = .scaleAspectFit
        self.tileView.addSubview(self.tileIconView)
        self.addSubview(self.tileView)
        self.titleLabel.numberOfLines = 2
        self.reasonLabel.numberOfLines = 2
        self.addSubview(self.titleLabel)
        self.addSubview(self.reasonLabel)
        self.declineButton.layer.cornerRadius = 10.0
        self.allowButton.layer.cornerRadius = 10.0
        self.declineLabel.textAlignment = .center
        self.allowLabel.textAlignment = .center
        self.declineButton.addSubview(self.declineLabel)
        self.allowButton.addSubview(self.allowLabel)
        self.addSubview(self.declineButton)
        self.addSubview(self.allowButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(layout: AgentPermissionLayout, theme: AgentChatTheme) {
        if self.theme != theme {
            self.theme = theme
            self.backgroundColor = theme.cardColor
            self.tileView.backgroundColor = theme.accentControl.withAlphaComponent(0.12)
            self.tileIconView.image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Calendar"), color: theme.accentControl)
            self.declineButton.backgroundColor = theme.secondary.withAlphaComponent(0.1)
            self.allowButton.backgroundColor = theme.accentControl.withAlphaComponent(0.14)
            for (check, _) in self.scopeViews {
                check.image = nil
            }
        }
        self.tileView.frame = layout.tileFrame
        let iconSize = floor(layout.tileFrame.width * 0.6)
        self.tileIconView.frame = CGRect(x: floor((layout.tileFrame.width - iconSize) / 2.0), y: floor((layout.tileFrame.height - iconSize) / 2.0), width: iconSize, height: iconSize)
        self.titleLabel.attributedText = layout.title
        self.titleLabel.frame = layout.titleFrame
        self.reasonLabel.attributedText = layout.reason
        self.reasonLabel.frame = layout.reasonFrame

        while self.scopeViews.count < layout.scopes.count {
            let check = UIImageView()
            let label = UILabel()
            self.addSubview(check)
            self.addSubview(label)
            self.scopeViews.append((check, label))
        }
        for (index, views) in self.scopeViews.enumerated() {
            let isVisible = index < layout.scopes.count
            views.check.isHidden = !isVisible
            views.label.isHidden = !isVisible
            guard isVisible else {
                continue
            }
            let scope = layout.scopes[index]
            if views.check.image == nil {
                views.check.image = AgentGlyphs.checkmark(size: scope.checkFrame.width, color: theme.accentControl, lineWidth: 1.6)
            }
            views.check.frame = scope.checkFrame
            views.label.attributedText = scope.text
            views.label.frame = scope.frame
        }

        self.declineButton.frame = layout.declineFrame
        self.declineLabel.attributedText = layout.declineTitle
        self.declineLabel.frame = CGRect(origin: CGPoint(), size: layout.declineFrame.size)
        self.allowButton.frame = layout.allowFrame
        self.allowLabel.attributedText = layout.allowTitle
        self.allowLabel.frame = CGRect(origin: CGPoint(), size: layout.allowFrame.size)
    }
}
