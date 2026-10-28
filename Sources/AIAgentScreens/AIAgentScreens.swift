import Foundation
import UIKit
import WebKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import ComponentFlow
import TelegramCore
import TelegramPresentationData
import AccountContext
import LocalizedPeerData
import PresentationDataUtils
import AttachmentUI
import ChatSendMessageActionUI
import UndoUI
import AvatarNode
import AppBundle
import TabSelectorComponent
import MoreHeaderButton
import AIAgentModel
import AIAgentUI
import AsciiReveal

/// The texts are not in the language packs; they follow the app's language.
private func text(_ strings: PresentationStrings, _ russian: String, _ english: String) -> String {
    return strings.baseLanguageCode == "ru" ? russian : english
}

// MARK: - Project sheet

/// A project the agent made, opened like a Mini App: it slides up from the bottom and expands to the whole screen.
public enum AgentProjectSheet {
    public enum Tab: Int {
        case preview
        case code
        case details
    }

    public static func make(context: AccountContext, artifact: AgentArtifact, botPeer: EnginePeer?, initialTab: Tab, initialFileName: String?) -> ViewController {
        let controller = AttachmentController(
            context: context,
            chatLocation: nil,
            buttons: [.standalone],
            initialButton: .standalone,
            hasTextInput: false,
            makeEntityInputView: {
                return nil
            }
        )
        controller.requestController = { _, present in
            let screen = AgentProjectScreen(context: context, artifact: artifact, botPeer: botPeer, initialTab: artifact.entryFile == nil ? .code : initialTab, initialFileName: initialFileName)
            present(screen, nil)
            return true
        }
        controller.title = artifact.title
        return controller
    }
}

final class AgentProjectScreen: ViewController, AttachmentContainable {
    private let context: AccountContext
    private let artifact: AgentArtifact
    private let botPeer: EnginePeer?
    private var presentationData: PresentationData
    private let initialTab: AgentProjectSheet.Tab
    private let initialFileName: String?
    private let moreButton: MoreHeaderButton

    var requestAttachmentMenuExpansion: () -> Void = {}
    var updateNavigationStack: (@escaping ([AttachmentContainable]) -> ([AttachmentContainable], AttachmentMediaPickerContext?)) -> Void = { _ in }
    var parentController: () -> ViewController? = { return nil }
    var updateTabBarAlpha: (CGFloat, ContainedViewLayoutTransition) -> Void = { _, _ in }
    var updateTabBarVisibility: (Bool, ContainedViewLayoutTransition) -> Void = { _, _ in }
    var cancelPanGesture: () -> Void = {}
    var isContainerPanning: () -> Bool = { return false }
    var isContainerExpanded: () -> Bool = { return false }
    var isMinimized: Bool = false
    var mediaPickerContext: AttachmentMediaPickerContext? {
        return nil
    }
    var getCurrentSendMessageContextMediaPreview: (() -> ChatSendMessageContextScreenMediaPreview?)? {
        return nil
    }
    var ignoresInputHeightInRegularLayout: Bool {
        return true
    }

    private var screenNode: AgentProjectScreenNode {
        return self.displayNode as! AgentProjectScreenNode
    }

    init(context: AccountContext, artifact: AgentArtifact, botPeer: EnginePeer?, initialTab: AgentProjectSheet.Tab, initialFileName: String?) {
        self.context = context
        self.artifact = artifact
        self.botPeer = botPeer
        self.initialTab = initialTab
        self.initialFileName = initialFileName
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        let navigationBarPresentationData = NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: self.presentationData.theme), strings: NavigationBarStrings(back: "", close: "", more: ""))
        self.moreButton = MoreHeaderButton(color: navigationBarPresentationData.theme.buttonColor)

        super.init(navigationBarPresentationData: navigationBarPresentationData)

        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style

        let titleView = AgentProjectTitleView()
        let subtitle: String
        if let botPeer, botPeer.addressName != nil {
            subtitle = "\(artifact.typeTitle.lowercased()) · \(botPeer.compactDisplayTitle)"
        } else {
            subtitle = artifact.typeTitle.lowercased()
        }
        titleView.update(title: artifact.title, subtitle: subtitle, theme: self.presentationData.theme)
        self.navigationItem.titleView = titleView

        self.navigationItem.setLeftBarButton(UIBarButtonItem(title: "___close", style: .plain, target: self, action: #selector(self.closePressed)), animated: false)
        self.moreButton.setContent(.more(MoreHeaderButton.optionsCircleImage(color: navigationBarPresentationData.theme.buttonColor)))
        self.moreButton.addTarget(self, action: #selector(self.morePressed), forControlEvents: .touchUpInside)
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(customDisplayNode: self.moreButton)
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = AgentProjectScreenNode(context: self.context, artifact: self.artifact, presentationData: self.presentationData, initialTab: self.initialTab, initialFileName: self.initialFileName, copied: { [weak self] in
            self?.showCopied()
        })
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let navigationHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.screenNode.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: transition)
    }

    @objc private func closePressed() {
        self.dismiss()
    }

    @objc private func morePressed() {
        let strings = self.presentationData.strings
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = []
        if !self.artifact.files.isEmpty {
            items.append(ActionSheetButtonItem(title: text(strings, "Скопировать код", "Copy Code"), action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                self?.screenNode.copyCurrentFile()
            }))
        }
        items.append(ActionSheetButtonItem(title: text(strings, "Поделиться", "Share"), action: { [weak self, weak actionSheet] in
            actionSheet?.dismissAnimated()
            self?.share()
        }))
        if self.artifact.entryFile != nil {
            items.append(ActionSheetButtonItem(title: text(strings, "Обновить", "Reload"), action: { [weak self, weak actionSheet] in
                actionSheet?.dismissAnimated()
                self?.screenNode.reloadPreview()
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: strings.Common_Cancel, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })])
        ])
        self.present(actionSheet, in: .window(.root))
    }

    private func share() {
        let files = self.artifact.files.map { "// \($0.name)\n\($0.text)" }.joined(separator: "\n\n")
        let activity = UIActivityViewController(activityItems: [files.isEmpty ? self.artifact.title : files], applicationActivities: nil)
        self.view.window?.rootViewController?.present(activity, animated: true)
    }

    private func showCopied() {
        self.present(UndoOverlayController(presentationData: self.presentationData, content: .copy(text: text(self.presentationData.strings, "Код скопирован", "Code copied")), action: { _ in return false }), in: .current)
    }
}

private final class AgentProjectTitleView: UIView {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.titleLabel.textAlignment = .center
        self.subtitleLabel.textAlignment = .center
        self.addSubview(self.titleLabel)
        self.addSubview(self.subtitleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, subtitle: String, theme: PresentationTheme) {
        self.titleLabel.attributedText = NSAttributedString(string: title, font: Font.semibold(17.0), textColor: theme.rootController.navigationBar.primaryTextColor)
        self.subtitleLabel.attributedText = NSAttributedString(string: subtitle, font: Font.regular(13.0), textColor: theme.rootController.navigationBar.secondaryTextColor)
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        self.titleLabel.frame = CGRect(x: 0.0, y: floor(size.height / 2.0) - 19.0, width: size.width, height: 22.0)
        self.subtitleLabel.frame = CGRect(x: 0.0, y: floor(size.height / 2.0) + 2.0, width: size.width, height: 17.0)
    }
}

private final class AgentProjectScreenNode: ASDisplayNode, WKNavigationDelegate {
    private let context: AccountContext
    private let artifact: AgentArtifact
    private var presentationData: PresentationData
    private let copied: () -> Void

    private let tabSelector = ComponentView<Empty>()
    private var selectedTab: AgentProjectSheet.Tab
    private var selectedFileName: String?

    private let previewContainer = UIView()
    private var webView: WKWebView?
    private let previewSkeleton = AsciiSkeletonView(variant: .terminal)
    private var previewLoaded = false

    private let codeContainer = UIView()
    private var fileChips: [String: UIButton] = [:]
    private let codeScrollView = UIScrollView()
    private let lineNumbersLabel = UILabel()
    private let codeLabel = UILabel()

    private let detailsScrollView = UIScrollView()

    private var validLayout: (ContainerViewLayout, CGFloat)?

    init(context: AccountContext, artifact: AgentArtifact, presentationData: PresentationData, initialTab: AgentProjectSheet.Tab, initialFileName: String?, copied: @escaping () -> Void) {
        self.context = context
        self.artifact = artifact
        self.presentationData = presentationData
        self.selectedTab = initialTab
        self.selectedFileName = initialFileName ?? artifact.entryFileName ?? artifact.files.first?.name
        self.copied = copied
        super.init()
        self.backgroundColor = presentationData.theme.list.plainBackgroundColor
    }

    override func didLoad() {
        super.didLoad()
        let theme = self.presentationData.theme

        self.previewContainer.backgroundColor = theme.list.plainBackgroundColor
        self.previewContainer.addSubview(self.previewSkeleton)
        self.view.addSubview(self.previewContainer)

        self.codeContainer.backgroundColor = theme.list.plainBackgroundColor
        self.codeScrollView.alwaysBounceVertical = true
        self.codeScrollView.showsHorizontalScrollIndicator = false
        self.lineNumbersLabel.numberOfLines = 0
        self.codeLabel.numberOfLines = 0
        self.codeScrollView.addSubview(self.lineNumbersLabel)
        self.codeScrollView.addSubview(self.codeLabel)
        self.codeContainer.addSubview(self.codeScrollView)
        self.view.addSubview(self.codeContainer)

        self.detailsScrollView.backgroundColor = theme.list.blocksBackgroundColor
        self.detailsScrollView.alwaysBounceVertical = true
        self.view.addSubview(self.detailsScrollView)

        if let html = self.artifact.assembledHTML(themeCSS: AgentMiniAppTheme.cssVariables(theme: theme)) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: CGRect(), configuration: configuration)
            webView.isOpaque = false
            webView.backgroundColor = theme.list.plainBackgroundColor
            webView.scrollView.backgroundColor = theme.list.plainBackgroundColor
            webView.navigationDelegate = self
            webView.alpha = 0.0
            self.previewContainer.addSubview(webView)
            self.webView = webView
            webView.loadHTMLString(html, baseURL: nil)
        }

        self.updateCode()
        self.updateTabVisibility(transition: .immediate)
    }

    func reloadPreview() {
        guard let webView = self.webView, let html = self.artifact.assembledHTML(themeCSS: AgentMiniAppTheme.cssVariables(theme: self.presentationData.theme)) else {
            return
        }
        self.previewLoaded = false
        webView.alpha = 0.0
        self.previewSkeleton.alpha = 1.0
        webView.loadHTMLString(html, baseURL: nil)
    }

    func copyCurrentFile() {
        guard let file = self.artifact.files.first(where: { $0.name == self.selectedFileName }) ?? self.artifact.files.first else {
            return
        }
        UIPasteboard.general.string = file.text
        self.copied()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !self.previewLoaded else {
            return
        }
        self.previewLoaded = true
        Queue.mainQueue().after(0.15, { [weak self] in
            guard let self, let webView = self.webView else {
                return
            }
            UIView.animate(withDuration: 0.25, animations: {
                webView.alpha = 1.0
                self.previewSkeleton.alpha = 0.0
            })
        })
    }

    private func selectTab(_ tab: AgentProjectSheet.Tab) {
        guard self.selectedTab != tab else {
            return
        }
        self.selectedTab = tab
        HapticFeedback().impact(.light)
        self.updateTabVisibility(transition: .animated(duration: 0.25, curve: .easeInOut))
        if let (layout, navigationHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .animated(duration: 0.25, curve: .easeInOut))
        }
    }

    private func updateTabVisibility(transition: ContainedViewLayoutTransition) {
        transition.updateAlpha(layer: self.previewContainer.layer, alpha: self.selectedTab == .preview ? 1.0 : 0.0)
        transition.updateAlpha(layer: self.codeContainer.layer, alpha: self.selectedTab == .code ? 1.0 : 0.0)
        transition.updateAlpha(layer: self.detailsScrollView.layer, alpha: self.selectedTab == .details ? 1.0 : 0.0)
        self.previewContainer.isUserInteractionEnabled = self.selectedTab == .preview
        self.codeContainer.isUserInteractionEnabled = self.selectedTab == .code
        self.detailsScrollView.isUserInteractionEnabled = self.selectedTab == .details
    }

    private func updateCode() {
        guard let file = self.artifact.files.first(where: { $0.name == self.selectedFileName }) ?? self.artifact.files.first else {
            return
        }
        let theme = self.presentationData.theme
        let font = UIFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
        let lines = file.text.components(separatedBy: "\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        self.lineNumbersLabel.attributedText = NSAttributedString(string: (1 ... max(1, lines.count)).map(String.init).joined(separator: "\n"), attributes: [.font: font, .foregroundColor: theme.list.itemSecondaryTextColor.withAlphaComponent(0.6), .paragraphStyle: paragraph])
        let fileName = file.name
        self.codeLabel.attributedText = AgentSyntaxHighlighter.shared.attributedString(file.text, language: file.language, font: font, color: theme.list.itemPrimaryTextColor, isDark: theme.overallDarkAppearance, updated: { [weak self] in
            guard let self, self.selectedFileName == fileName else {
                return
            }
            self.updateCode()
        })
        if let (layout, navigationHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .immediate)
        }
    }

    @objc private func fileChipPressed(_ sender: UIButton) {
        guard let name = self.fileChips.first(where: { $0.value === sender })?.key, name != self.selectedFileName else {
            return
        }
        self.selectedFileName = name
        HapticFeedback().impact(.light)
        self.updateCode()
        self.codeScrollView.setContentOffset(CGPoint(), animated: false)
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationHeight)
        let theme = self.presentationData.theme
        let strings = self.presentationData.strings
        let width = layout.size.width
        let sideInset = 16.0 + layout.safeInsets.left

        // Tabs.
        var items: [TabSelectorComponent.Item] = []
        if self.artifact.entryFile != nil {
            items.append(TabSelectorComponent.Item(id: AnyHashable(AgentProjectSheet.Tab.preview.rawValue), content: .text(text(strings, "Превью", "Preview"))))
        }
        if !self.artifact.files.isEmpty {
            items.append(TabSelectorComponent.Item(id: AnyHashable(AgentProjectSheet.Tab.code.rawValue), content: .text(text(strings, "Код", "Code"))))
        }
        items.append(TabSelectorComponent.Item(id: AnyHashable(AgentProjectSheet.Tab.details.rawValue), content: .text(text(strings, "Детали", "Details"))))
        let tabSize = self.tabSelector.update(
            transition: ComponentTransition(transition),
            component: AnyComponent(TabSelectorComponent(
                context: self.context,
                colors: TabSelectorComponent.Colors(
                    foreground: theme.list.itemSecondaryTextColor,
                    selection: theme.list.itemSecondaryTextColor.withMultipliedAlpha(0.15),
                    simple: true
                ),
                theme: theme,
                items: items,
                selectedId: AnyHashable(self.selectedTab.rawValue),
                setSelectedId: { [weak self] id in
                    guard let self, let value = id.base as? Int, let tab = AgentProjectSheet.Tab(rawValue: value) else {
                        return
                    }
                    self.selectTab(tab)
                }
            )),
            environment: {},
            containerSize: CGSize(width: width - sideInset * 2.0, height: 50.0)
        )
        let tabFrame = CGRect(x: floor((width - tabSize.width) / 2.0), y: navigationHeight + 6.0, width: tabSize.width, height: tabSize.height)
        if let tabView = self.tabSelector.view {
            if tabView.superview == nil {
                self.view.addSubview(tabView)
            }
            transition.updateFrame(view: tabView, frame: tabFrame)
        }

        let contentTop = tabFrame.maxY + 8.0
        let contentFrame = CGRect(x: 0.0, y: contentTop, width: width, height: max(0.0, layout.size.height - contentTop))

        // Preview.
        transition.updateFrame(view: self.previewContainer, frame: contentFrame)
        if let webView = self.webView {
            webView.frame = CGRect(origin: CGPoint(), size: contentFrame.size)
            webView.scrollView.contentInset = UIEdgeInsets(top: 0.0, left: 0.0, bottom: layout.intrinsicInsets.bottom, right: 0.0)
        }
        let skeletonFrame = CGRect(x: sideInset, y: 20.0, width: width - sideInset * 2.0, height: min(320.0, contentFrame.height - 40.0))
        self.previewSkeleton.frame = skeletonFrame
        self.previewSkeleton.update(size: skeletonFrame.size, color: theme.list.itemAccentColor.withAlphaComponent(0.6), lineHeight: 18.0, font: UIFont.monospacedSystemFont(ofSize: 13.0, weight: .regular))

        // Code.
        transition.updateFrame(view: self.codeContainer, frame: contentFrame)
        var chipX = sideInset
        let chipHeight: CGFloat = 30.0
        for file in self.artifact.files {
            let chip: UIButton
            if let current = self.fileChips[file.name] {
                chip = current
            } else {
                chip = UIButton(type: .custom)
                chip.layer.cornerRadius = chipHeight / 2.0
                chip.addTarget(self, action: #selector(self.fileChipPressed(_:)), for: .touchUpInside)
                self.codeContainer.addSubview(chip)
                self.fileChips[file.name] = chip
            }
            let isSelected = file.name == self.selectedFileName
            chip.backgroundColor = isSelected ? theme.list.itemAccentColor.withAlphaComponent(0.14) : theme.list.itemSecondaryTextColor.withAlphaComponent(0.1)
            chip.setAttributedTitle(NSAttributedString(string: file.name, font: Font.medium(14.0), textColor: isSelected ? theme.list.itemAccentColor : theme.list.itemPrimaryTextColor), for: .normal)
            let chipWidth = ceil(chip.titleLabel?.intrinsicContentSize.width ?? 60.0) + 24.0
            chip.frame = CGRect(x: chipX, y: 4.0, width: chipWidth, height: chipHeight)
            chipX += chipWidth + 8.0
        }
        let codeTop: CGFloat = self.artifact.files.count > 1 ? 4.0 + chipHeight + 12.0 : 8.0
        self.codeScrollView.frame = CGRect(x: 0.0, y: codeTop, width: width, height: max(0.0, contentFrame.height - codeTop))
        let numbersSize = self.lineNumbersLabel.attributedText.map { AgentTextSize.size($0) } ?? CGSize()
        let codeSize = self.codeLabel.attributedText.map { AgentTextSize.size($0) } ?? CGSize()
        self.lineNumbersLabel.frame = CGRect(x: sideInset, y: 0.0, width: numbersSize.width, height: numbersSize.height)
        self.codeLabel.frame = CGRect(x: sideInset + numbersSize.width + 14.0, y: 0.0, width: codeSize.width, height: codeSize.height)
        self.codeScrollView.contentSize = CGSize(width: max(width, self.codeLabel.frame.maxX + sideInset), height: codeSize.height + layout.intrinsicInsets.bottom + 24.0)

        // Details.
        transition.updateFrame(view: self.detailsScrollView, frame: contentFrame)
        self.layoutDetails(width: width, sideInset: sideInset, bottomInset: layout.intrinsicInsets.bottom)
    }

    private var detailsLaidOutWidth: CGFloat?

    private func layoutDetails(width: CGFloat, sideInset: CGFloat, bottomInset: CGFloat) {
        guard self.detailsLaidOutWidth != width else {
            return
        }
        self.detailsLaidOutWidth = width
        for subview in self.detailsScrollView.subviews {
            subview.removeFromSuperview()
        }
        let theme = self.presentationData.theme
        let strings = self.presentationData.strings
        let isRussian = strings.baseLanguageCode == "ru"
        let stats = self.artifact.stats

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: isRussian ? "ru_RU" : "en_US")
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var y: CGFloat = 16.0
        func header(_ string: String) {
            let label = UILabel()
            label.attributedText = NSAttributedString(string: string.uppercased(), font: Font.regular(13.0), textColor: theme.list.sectionHeaderTextColor)
            label.frame = CGRect(x: sideInset + 16.0, y: y, width: width - sideInset * 2.0 - 32.0, height: 18.0)
            self.detailsScrollView.addSubview(label)
            y += 24.0
        }
        func section(_ rows: [(String, String)]) {
            let rowHeight: CGFloat = 44.0
            let background = UIView()
            background.backgroundColor = theme.list.itemBlocksBackgroundColor
            background.layer.cornerRadius = 16.0
            if #available(iOS 13.0, *) {
                background.layer.cornerCurve = .continuous
            }
            background.frame = CGRect(x: sideInset, y: y, width: width - sideInset * 2.0, height: rowHeight * CGFloat(rows.count))
            self.detailsScrollView.addSubview(background)
            for (index, row) in rows.enumerated() {
                let titleLabel = UILabel()
                titleLabel.attributedText = NSAttributedString(string: row.0, font: Font.regular(17.0), textColor: theme.list.itemPrimaryTextColor)
                titleLabel.frame = CGRect(x: 16.0, y: CGFloat(index) * rowHeight, width: background.bounds.width * 0.55, height: rowHeight)
                background.addSubview(titleLabel)
                let valueLabel = UILabel()
                valueLabel.textAlignment = .right
                valueLabel.attributedText = NSAttributedString(string: row.1, font: Font.regular(17.0), textColor: theme.list.itemSecondaryTextColor)
                valueLabel.frame = CGRect(x: background.bounds.width * 0.4, y: CGFloat(index) * rowHeight, width: background.bounds.width * 0.6 - 16.0, height: rowHeight)
                background.addSubview(valueLabel)
                if index != 0 {
                    let separator = UIView()
                    separator.backgroundColor = theme.list.itemBlocksSeparatorColor
                    separator.frame = CGRect(x: 16.0, y: CGFloat(index) * rowHeight, width: background.bounds.width - 16.0, height: UIScreenPixel)
                    background.addSubview(separator)
                }
            }
            y = background.frame.maxY + 24.0
        }

        header(text(strings, "О проекте", "About"))
        var rows: [(String, String)] = [
            (text(strings, "Тип", "Type"), self.artifact.typeTitle),
            (text(strings, "Создан", "Created"), dateFormatter.string(from: Date(timeIntervalSince1970: self.artifact.createdAt))),
            (text(strings, "Время работы", "Work Time"), AgentFormatting.duration(stats.seconds, isRussian: isRussian)),
            (text(strings, "Шаги", "Steps"), "\(stats.steps)")
        ]
        if !self.artifact.files.isEmpty {
            rows.append((text(strings, "Файлы", "Files"), "\(stats.files)"))
            rows.append((text(strings, "Строк кода", "Lines of Code"), "\(stats.lines)"))
            rows.append((text(strings, "Размер", "Size"), AgentFormatting.bytes(stats.bytes, isRussian: isRussian)))
        }
        section(rows)

        if !self.artifact.path.isEmpty {
            header(text(strings, "Путь агента", "Agent's Path"))
            section(self.artifact.path.map { item in
                return (item.title, AgentFormatting.duration(max(1.0, item.seconds), isRussian: isRussian))
            })
        }
        self.detailsScrollView.contentSize = CGSize(width: width, height: y + bottomInset)
    }
}

private enum AgentTextSize {
    static func size(_ string: NSAttributedString) -> CGSize {
        let rect = string.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}
