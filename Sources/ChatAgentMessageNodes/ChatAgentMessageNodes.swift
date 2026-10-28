import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import LottieSettings
import ChatControllerInteraction
import ChatMessageBubbleContentNode
import ChatMessageItemCommon
import ChatMessageDateAndStatusNode
import AIAgentModel
import AIAgentCore
import AIAgentUI

/// Opens an agent's result or code; installed by the chat, which knows how to present sheets.
public enum ChatAgentMessageActions {
    public static var openArtifact: ((_ context: AccountContext, _ message: EngineMessage, _ artifact: AgentArtifact, _ initialFileName: String?) -> Void)?
    public static var openSnippet: ((_ context: AccountContext, _ message: EngineMessage, _ step: AgentStep) -> Void)?
    public static var requestPermission: ((_ context: AccountContext, _ message: EngineMessage, _ permission: AgentPermission, _ completion: @escaping (Bool) -> Void) -> Void)?
    public static var shareArtifact: ((_ context: AccountContext, _ artifact: AgentArtifact) -> Void)?
}

private func agentAttribute(_ message: EngineMessage) -> AgentDemoMessageAttribute? {
    return message.agentDemoAttribute
}

private func agentTheme(_ item: ChatMessageBubbleContentItem) -> AgentChatTheme {
    return AgentChatTheme(theme: item.presentationData.theme.theme, strings: item.presentationData.strings, fontSize: item.presentationData.fontSize.baseDisplaySize, isIncoming: true)
}

/// The agent's path of work at the top of its message. The answer below it is the message text, drawn by the regular
/// text node.
public final class ChatMessageAgentRunBubbleContentNode: ChatMessageBubbleContentNode {
    private let runView = AgentRunView()
    private var run: AgentRun?

    override public var visibility: ListViewItemNodeVisibility {
        didSet {
            self.runView.updateIsVisible(self.visibility != .none)
        }
    }

    required public init(lottieSettings: LottieRenderingSettings) {
        super.init(lottieSettings: lottieSettings)

        self.runView.requestRelayout = { [weak self] _ in
            self?.requestFullUpdate?(ControlledTransition(duration: 0.3, curve: .spring, interactive: false))
        }
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func didLoad() {
        super.didLoad()
        self.view.addSubview(self.runView)
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, unboundSize: CGSize?, maxWidth: CGFloat, layout: (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        return { [weak self] item, layoutConstants, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { [weak self] constrainedSize, position in
                var topInset = layoutConstants.text.bubbleInsets.top + 2.0
                var bottomInset = layoutConstants.text.bubbleInsets.bottom + 2.0
                if case let .linear(top, bottom) = position {
                    if case .Neighbour = top {
                        topInset = layoutConstants.text.bubbleInsets.top
                    }
                    if case .Neighbour = bottom {
                        bottomInset = 0.0
                    }
                }

                let message = EngineMessage(item.message)
                let attribute = agentAttribute(message)
                var run = AgentRun(id: 0, status: .finished, startedAt: 0.0, finishedAt: 0.0, steps: [])
                if let attribute, let decoded = AgentPayloadCache.shared.payload(stableId: item.message.stableId, attribute: attribute)?.run {
                    run = decoded
                }
                let uiState = AgentRunUIStateStore.shared.state(stableId: item.message.stableId)
                let theme = agentTheme(item)
                let hasAnswerBelow = !item.message.text.isEmpty
                let horizontalInsets = layoutConstants.text.bubbleInsets.left + layoutConstants.text.bubbleInsets.right

                return (constrainedSize.width, { [weak self] boundingWidth in
                    let contentWidth = max(1.0, boundingWidth - horizontalInsets)
                    let now = Date().timeIntervalSince1970
                    let runLayout = AgentRunView.layout(run: run, uiState: uiState, hasAnswerBelow: hasAnswerBelow, width: contentWidth, theme: theme, now: now)
                    let size = CGSize(width: boundingWidth, height: topInset + runLayout.size.height + bottomInset)

                    return (size, { [weak self] animation, _, _ in
                        guard let self else {
                            return
                        }
                        self.item = item
                        self.run = run
                        let frame = CGRect(x: layoutConstants.text.bubbleInsets.left, y: topInset, width: contentWidth, height: runLayout.size.height)
                        animation.animator.updateFrame(layer: self.runView.layer, frame: frame, completion: nil)
                        self.runView.apply(layout: runLayout, run: run, theme: theme, transition: animation.transition, now: now)
                        self.runView.updateIsVisible(self.visibility != .none)
                    })
                })
            })
        }
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        guard let item = self.item, let run = self.run else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        let local = self.view.convert(point, to: self.runView)
        guard let action = self.runView.action(at: local) else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        let stableId = item.message.stableId
        let message = EngineMessage(item.message)
        let context = item.context
        return ChatMessageBubbleContentTapAction(content: .custom({ [weak self] in
            guard let self else {
                return
            }
            switch action {
            case let .toggleStep(stepId):
                HapticFeedback().impact(.light)
                AgentRunUIStateStore.shared.toggleStep(stableId: stableId, stepId: stepId)
                self.requestFullUpdate?(ControlledTransition(duration: 0.42, curve: .spring, interactive: false))
            case .togglePath:
                HapticFeedback().impact(.light)
                let state = AgentRunUIStateStore.shared.state(stableId: stableId)
                AgentRunUIStateStore.shared.setPathExpanded(stableId: stableId, !state.isPathExpanded)
                self.requestFullUpdate?(ControlledTransition(duration: 0.42, curve: .spring, interactive: false))
            case let .openSnippet(stepId):
                if let step = run.steps.first(where: { $0.id == stepId }) {
                    ChatAgentMessageActions.openSnippet?(context, message, step)
                }
            case let .permission(granted):
                if granted, let permission = run.steps.first(where: { $0.kind == .permission && $0.status == .waiting })?.permission, let requestPermission = ChatAgentMessageActions.requestPermission {
                    requestPermission(context, message, permission, { granted in
                        AIAgentDemoEngine.shared(context: context).respondToPermission(messageId: message.id, granted: granted)
                    })
                } else {
                    AIAgentDemoEngine.shared(context: context).respondToPermission(messageId: message.id, granted: granted)
                }
            }
        }))
    }
}

/// A result of the agent: a project with its stats, or a calendar event.
public final class ChatMessageAgentArtifactBubbleContentNode: ChatMessageBubbleContentNode {
    private let cardView = AgentArtifactCardView()
    private let dateAndStatusNode = ChatMessageDateAndStatusNode()
    private var artifact: AgentArtifact?
    private var hasAppeared = false

    required public init(lottieSettings: LottieRenderingSettings) {
        super.init(lottieSettings: lottieSettings)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func didLoad() {
        super.didLoad()
        self.view.addSubview(self.cardView)
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, unboundSize: CGSize?, maxWidth: CGFloat, layout: (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let statusLayout = self.dateAndStatusNode.asyncLayout()

        return { [weak self] item, layoutConstants, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { [weak self] constrainedSize, position in
                let message = EngineMessage(item.message)
                let artifact = agentAttribute(message).flatMap { AgentPayloadCache.shared.payload(stableId: item.message.stableId, attribute: $0)?.artifact }
                let theme = agentTheme(item)
                let insets = layoutConstants.text.bubbleInsets
                let horizontalInsets = insets.left + insets.right
                let maxWidth = min(constrainedSize.width, 340.0)

                let dateText = stringForMessageTimestampStatus(context: item.context, message: message, dateTimeFormat: item.presentationData.dateTimeFormat, nameDisplayOrder: item.presentationData.nameDisplayOrder, strings: item.presentationData.strings, associatedData: item.associatedData)
                // A project's time is on its picture, as on a photo; an event's ends the chip row.
                let timeOnPreview = artifact?.kind == .project
                let statusType: ChatMessageDateAndStatusType = timeOnPreview ? .ImageIncoming : .BubbleIncoming

                let previewHTML = artifact?.assembledHTML(themeCSS: AgentMiniAppTheme.cssVariables(theme: item.presentationData.theme.theme), stillFrame: true)

                return (maxWidth, { [weak self] boundingWidth in
                    let contentWidth = max(1.0, boundingWidth - horizontalInsets)

                    let statusContinue = statusLayout(ChatMessageDateAndStatusNode.Arguments(
                        context: item.context,
                        presentationData: item.presentationData,
                        edited: false,
                        impressionCount: nil,
                        dateText: dateText,
                        type: statusType,
                        layoutInput: .standalone(reactionSettings: nil),
                        constrainedSize: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
                        availableReactions: item.associatedData.availableReactions,
                        savedMessageTags: item.associatedData.savedMessageTags,
                        reactions: [],
                        reactionPeers: [],
                        displayAllReactionPeers: false,
                        areReactionsTags: false,
                        areStarReactionsEnabled: false,
                        messageEffect: nil,
                        replyCount: 0,
                        starsCount: nil,
                        isPinned: false,
                        hasAutoremove: false,
                        canViewReactionList: false,
                        animationCache: item.controllerInteraction.presentationContext.animationCache,
                        animationRenderer: item.controllerInteraction.presentationContext.animationRenderer
                    ))

                    // Laid out at its own width: at the content's width the node would take the whole line.
                    let (statusSize, statusApply) = statusContinue.1(statusContinue.0)
                    // The card ends with its buttons and keeps the same margin on every side.
                    let cardLayout = artifact.map { AgentArtifactCardView.layout(artifact: $0, width: contentWidth, theme: theme, chipRowTrailingInset: timeOnPreview ? 0.0 : statusSize.width + 8.0) }
                    let cardHeight = cardLayout?.size.height ?? 0.0
                    let margin = insets.left
                    let size = CGSize(width: boundingWidth, height: margin + cardHeight + margin)

                    return (size, { [weak self] animation, _, _ in
                        guard let self else {
                            return
                        }
                        self.item = item
                        self.artifact = artifact
                        let cardFrame = CGRect(x: insets.left, y: margin, width: contentWidth, height: cardHeight)
                        animation.animator.updateFrame(layer: self.cardView.layer, frame: cardFrame, completion: nil)
                        if let artifact, let cardLayout {
                            let playsAppearance = !self.hasAppeared && Date().timeIntervalSince1970 - artifact.createdAt < 20.0
                            self.hasAppeared = true
                            self.cardView.apply(layout: cardLayout, artifact: artifact, theme: theme, previewHTML: previewHTML, playsAppearance: playsAppearance, transition: animation.transition)
                        }

                        var statusFrame = CGRect(x: boundingWidth - insets.right - statusSize.width, y: size.height - insets.bottom - statusSize.height, width: statusSize.width, height: statusSize.height)
                        if let cardLayout {
                            if let previewFrame = cardLayout.previewFrame {
                                statusFrame.origin = CGPoint(x: cardFrame.minX + previewFrame.maxX - 6.0 - statusSize.width, y: cardFrame.minY + previewFrame.maxY - 6.0 - statusSize.height)
                            } else {
                                statusFrame.origin.y = cardFrame.minY + floor(cardLayout.chipFrame.midY - statusSize.height / 2.0)
                            }
                        }
                        if self.dateAndStatusNode.supernode == nil {
                            self.addSubnode(self.dateAndStatusNode)
                        }
                        self.dateAndStatusNode.frame = statusFrame
                        statusApply(animation)
                    })
                })
            })
        }
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        guard let item = self.item, let artifact = self.artifact else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        let local = self.view.convert(point, to: self.cardView)
        guard let action = self.cardView.action(at: local) else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        let context = item.context
        let message = EngineMessage(item.message)
        return ChatMessageBubbleContentTapAction(content: .custom({
            switch action {
            case .open:
                ChatAgentMessageActions.openArtifact?(context, message, artifact, nil)
            case .share:
                ChatAgentMessageActions.shareArtifact?(context, artifact)
            }
        }))
    }
}
