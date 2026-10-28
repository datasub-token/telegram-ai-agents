import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import UndoUI
import ChatTitleView
import ChatAgentMessageNodes
import AIAgentModel
import AIAgentCore
import AIAgentUI
import AIAgentScreens
import AsciiReveal
import ConceptFeatures

/// The AI agent chat: what the user writes in a chat with an `_ai` bot goes to the local demo agent instead of the bot,
/// the header shows what the agent is doing, and the agent's results open in sheets.
extension ChatControllerImpl {
    private var aiAgentPeer: EnginePeer? {
        return self.presentationInterfaceState.renderedPeer?.peer.flatMap(EnginePeer.init)
    }

    /// Takes the messages for the demo agent. Returns false when the chat is not a demo agent chat, so the messages are
    /// sent as usual; true means nothing may be sent.
    func aiAgentHandleOutgoing(_ messages: [EnqueueMessage]) -> Bool {
        guard let peer = self.aiAgentPeer, AIAgentIdentity.isDemoActive(peer) else {
            return false
        }
        let strings = self.presentationData.strings
        var prompt: (text: String, entities: [MessageTextEntity], correlationId: Int64?)?
        var hasNonText = false
        for message in messages {
            switch message {
            case let .message(text, attributes, _, mediaReference, _, _, _, _, correlationId, _):
                if mediaReference != nil {
                    hasNonText = true
                } else if prompt == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let entities = attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities ?? []
                    prompt = (text, entities, correlationId)
                }
            case .forward:
                hasNonText = true
            }
        }
        let engine = AIAgentDemoEngine.shared(context: self.context)
        guard let prompt else {
            if hasNonText {
                self.aiAgentShowToast(AIAgentStrings.text(strings, "В демо-режиме агент понимает только текст", "In demo mode the agent understands text only"))
            }
            return true
        }
        // A prompt is plain text: formatting pasted along with it (code, bold) is not kept. While the agent works the
        // prompt is queued and answered next.
        engine.handleUserPrompt(peer: peer, text: prompt.text, entities: [], correlationId: prompt.correlationId)
        return true
    }

    /// Stops the demo agent's run in this chat; false when there is none (the bot's own streaming is stopped instead).
    func aiAgentStop() -> Bool {
        guard let peerId = self.chatLocation.peerId else {
            return false
        }
        if AIAgentDemoEngine.shared(context: self.context).stop(peerId: peerId) {
            HapticFeedback().impact(.light)
            return true
        }
        return false
    }

    /// The header's activity while the agent works: "thinking", "writing index.html", "waiting for permission".
    func aiAgentTitleActivities(peerId: EnginePeer.Id) -> ChatTitleComponent.Activities? {
        guard let peer = self.aiAgentPeer, peer.id == peerId, let status = AIAgentDemoEngine.shared(context: self.context).currentStatus(peerId: peerId) else {
            return nil
        }
        return ChatTitleComponent.Activities(peerId: peerId, items: [ChatTitleComponent.Activities.Item(peer: peer, activity: .typingText)], customText: status.text)
    }

    func aiAgentStartStatusUpdates(peerId: EnginePeer.Id) {
        self.aiAgentInstallActions()
        self.aiAgentStatusDisposable?.dispose()
        self.aiAgentStatusDisposable = (AIAgentDemoEngine.shared(context: self.context).liveStatus(peerId: peerId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] _ in
            guard let self else {
                return
            }
            let activities = self.aiAgentTitleActivities(peerId: peerId) ?? ChatTitleComponent.Activities(peerId: peerId, items: [])
            self.chatTitleView?.updateActivities(activities: activities, transition: .spring(duration: 0.4))
            self.chatDisplayNode.overlayTitleActivities = activities
        })
    }

    private func aiAgentShowToast(_ text: String) {
        self.present(UndoOverlayController(presentationData: self.presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), action: { _ in return false }), in: .current)
    }

    /// The agent's messages open sheets through these; the chat on screen presents them.
    private func aiAgentInstallActions() {
        AsciiRevealSettings.isEnabled = ConceptFeatures.isEnabled(.aiAgentAscii) && !UIAccessibility.isReduceMotionEnabled
        
        ChatAgentMessageActions.openArtifact = { [weak self] context, _, artifact, fileName in
            guard let self else {
                return
            }
            if artifact.kind == .event {
                self.aiAgentShowToast(AIAgentStrings.text(self.presentationData.strings, "Событие уже в календаре «\(artifact.event?.calendarTitle ?? "")»", "The event is in your \(artifact.event?.calendarTitle ?? "") calendar"))
                return
            }
            self.aiAgentPresentProject(AgentProjectSheet.make(context: context, artifact: artifact, botPeer: self.aiAgentPeer, initialTab: fileName == nil ? .preview : .code, initialFileName: fileName))
        }
        ChatAgentMessageActions.openSnippet = { [weak self] context, message, step in
            guard let self else {
                return
            }
            let snippet = step.output ?? step.input
            guard let snippet else {
                return
            }
            let fileName = step.liveCode?.fileName ?? (step.displayDetail ?? step.displayTitle)
            let language = step.liveCode?.language ?? snippet.language ?? "text"
            let file = AgentArtifactFile(name: fileName.isEmpty ? "output.txt" : fileName, language: language, text: snippet.text)
            let artifact = AgentArtifact(id: Int64(message.stableId), runId: 0, kind: .project, typeTitle: AIAgentStrings.text(self.presentationData.strings, "Результат шага", "Step result"), title: step.displayTitle, description: "", createdAt: Double(message.timestamp), stats: AgentArtifactStats(seconds: step.duration(at: step.finishedAt ?? step.startedAt), steps: 1, files: 1, lines: file.lineCount, bytes: file.byteCount), files: [file], entryFileName: nil, event: nil, path: [])
            self.aiAgentPresentProject(AgentProjectSheet.make(context: context, artifact: artifact, botPeer: self.aiAgentPeer, initialTab: .code, initialFileName: file.name))
        }
        // Allow in the request card grants access at once, and the agent goes on.
        ChatAgentMessageActions.requestPermission = { _, _, _, completion in
            HapticFeedback().success()
            completion(true)
        }
        ChatAgentMessageActions.shareArtifact = { [weak self] _, artifact in
            guard let self else {
                return
            }
            let files = artifact.files.map { "// \($0.name)\n\($0.text)" }.joined(separator: "\n\n")
            let activity = UIActivityViewController(activityItems: [files.isEmpty ? artifact.title : files], applicationActivities: nil)
            self.view.window?.rootViewController?.present(activity, animated: true)
        }
    }

    private func aiAgentPresentProject(_ controller: ViewController) {
        self.view.endEditing(true)
        controller.navigationPresentation = .flatModal
        if let navigationController = self.navigationController as? NavigationController {
            navigationController.pushViewController(controller)
        } else {
            self.present(controller, in: .window(.root))
        }
    }
}
