import Foundation
import SwiftSignalKit
import Postbox

/// Messages of the AI agent demo. They are stored in `Namespaces.Message.Local` of a real bot chat and are never sent:
/// only messages flagged `.Unsent` reach the pending queue, and history validation only looks at cloud messages.
public extension TelegramEngine {
    final class AIAgentDemo {
        let account: Account

        init(account: Account) {
            self.account = account
        }

        /// Stores the user's prompt as an outgoing message. `correlationId` lets the chat play its send animation for it;
        /// `timestamp` dates it earlier than now (a conversation that happened before).
        public func addPrompt(peerId: EnginePeer.Id, text: String, entities: [MessageTextEntity], correlationId: Int64?, attribute: AgentDemoMessageAttribute, timestamp: Int32? = nil) -> Signal<EngineMessage.Id?, NoError> {
            let accountPeerId = self.account.peerId
            return self.account.postbox.transaction { transaction -> EngineMessage.Id? in
                var attributes: [MessageAttribute] = [attribute]
                if !entities.isEmpty {
                    attributes.append(TextEntitiesMessageAttribute(entities: entities))
                }
                attributes.append(OutgoingMessageInfoAttribute(uniqueId: Int64.random(in: Int64.min ... Int64.max), flags: [], acknowledged: true, correlationId: correlationId, bubbleUpEmojiOrStickersets: [], partialReference: nil))
                return addAgentDemoMessage(transaction: transaction, peerId: peerId, authorId: accountPeerId, flags: [], text: text, attributes: attributes, timestamp: timestamp)
            }
        }

        /// Marks the prompt as read by the agent, which turns its single tick into a double one.
        public func markPromptRead(id: EngineMessage.Id) -> Signal<Never, NoError> {
            return self.account.postbox.transaction { transaction -> Void in
                transaction.applyOutgoingReadMaxId(id)
            }
            |> ignoreValues
        }

        /// Stores a message from the agent, dated `timestamp` or now.
        public func addAgentMessage(peerId: EnginePeer.Id, text: String, entities: [MessageTextEntity], attribute: AgentDemoMessageAttribute, replyMarkup: ReplyMarkupMessageAttribute?, timestamp: Int32? = nil) -> Signal<EngineMessage.Id?, NoError> {
            return self.account.postbox.transaction { transaction -> EngineMessage.Id? in
                return addAgentDemoMessage(transaction: transaction, peerId: peerId, authorId: peerId, flags: [.Incoming], text: text, attributes: agentDemoAttributes(entities: entities, attribute: attribute, replyMarkup: replyMarkup), timestamp: timestamp)
            }
        }

        /// Replaces the text and the demo attribute of a message in place. The message keeps its id, its date and its
        /// stable id, so the chat updates the same row.
        public func updateAgentMessage(id: EngineMessage.Id, text: String, entities: [MessageTextEntity], attribute: AgentDemoMessageAttribute, replyMarkup: ReplyMarkupMessageAttribute?) -> Signal<Never, NoError> {
            return self.account.postbox.transaction { transaction -> Void in
                updateAgentDemoMessage(transaction: transaction, id: id, text: text, attributes: agentDemoAttributes(entities: entities, attribute: attribute, replyMarkup: replyMarkup))
            }
            |> ignoreValues
        }

        /// All demo messages of these chats, oldest first.
        public func messages(peerIds: [EnginePeer.Id]) -> Signal<[EngineMessage], NoError> {
            return self.account.postbox.transaction { transaction -> [EngineMessage] in
                var result: [EngineMessage] = []
                for peerId in peerIds {
                    result.append(contentsOf: agentDemoMessages(transaction: transaction, peerId: peerId).map(EngineMessage.init))
                }
                return result
            }
        }

        /// Removes every demo message from these chats.
        public func deleteMessages(peerIds: [EnginePeer.Id]) -> Signal<Never, NoError> {
            return self.account.postbox.transaction { transaction -> Void in
                for peerId in peerIds {
                    let ids = agentDemoMessages(transaction: transaction, peerId: peerId).map(\.id)
                    if !ids.isEmpty {
                        transaction.deleteMessages(ids, forEachMedia: nil)
                    }
                }
            }
            |> ignoreValues
        }
    }
}

private func agentDemoAttributes(entities: [MessageTextEntity], attribute: AgentDemoMessageAttribute, replyMarkup: ReplyMarkupMessageAttribute?) -> [MessageAttribute] {
    var attributes: [MessageAttribute] = [attribute]
    if !entities.isEmpty {
        attributes.append(TextEntitiesMessageAttribute(entities: entities))
    }
    if let replyMarkup {
        attributes.append(replyMarkup)
    }
    return attributes
}

private func addAgentDemoMessage(transaction: Transaction, peerId: PeerId, authorId: PeerId, flags: StoreMessageFlags, text: String, attributes: [MessageAttribute], timestamp: Int32?) -> MessageId? {
    let randomId = Int64.random(in: Int64.min ... Int64.max)
    let timestamp = timestamp ?? Int32(Date().timeIntervalSince1970)
    let message = StoreMessage(peerId: peerId, namespace: Namespaces.Message.Local, customStableId: nil, globallyUniqueId: randomId, groupingKey: nil, threadId: nil, timestamp: timestamp, flags: flags, tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: authorId, text: text, attributes: attributes, media: [])
    guard let id = transaction.addMessages([message], location: .Random)[randomId] else {
        return nil
    }
    updatePeerChatInclusionWithMinTimestamp(transaction: transaction, id: peerId, minTimestamp: timestamp, forceRootGroupIfNotExists: true)
    return id
}

private func updateAgentDemoMessage(transaction: Transaction, id: MessageId, text: String, attributes: [MessageAttribute]) {
    guard id.namespace == Namespaces.Message.Local, let message = transaction.getMessage(id), message.attributes.contains(where: { $0 is AgentDemoMessageAttribute }) else {
        return
    }
    // The prompt's send info stays, so its read state and send animation keep working.
    var updatedAttributes = attributes
    for attribute in message.attributes where attribute is OutgoingMessageInfoAttribute {
        updatedAttributes.append(attribute)
    }
    transaction.updateMessage(id, update: { _ in
        return .update(StoreMessage(id: message.id, customStableId: nil, globallyUniqueId: message.globallyUniqueId, groupingKey: message.groupingKey, threadId: message.threadId, timestamp: message.timestamp, flags: StoreMessageFlags(message.flags), tags: message.tags, globalTags: message.globalTags, localTags: message.localTags, forwardInfo: nil, authorId: message.author?.id, text: text, attributes: updatedAttributes, media: message.media))
    })
}

private func agentDemoMessages(transaction: Transaction, peerId: PeerId) -> [Message] {
    var result: [Message] = []
    var from = MessageIndex.upperBound(peerId: peerId, namespace: Namespaces.Message.Local)
    let to = MessageIndex.lowerBound(peerId: peerId, namespace: Namespaces.Message.Local)
    while true {
        let messages = transaction.getMessages(peerId: peerId, namespace: Namespaces.Message.Local, from: from, includeFrom: false, to: to, limit: 100)
        if messages.isEmpty {
            break
        }
        for message in messages where message.attributes.contains(where: { $0 is AgentDemoMessageAttribute }) {
            result.append(message)
        }
        guard let oldest = messages.min(by: { $0.index < $1.index }) else {
            break
        }
        from = oldest.index
    }
    return result.sorted(by: { $0.index < $1.index })
}
