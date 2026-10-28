import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ConceptFeatures
import LocalizedPeerData
import AIAgentModel

/// Which chats are AI agent chats.
public enum AIAgentIdentity {
    /// A bot whose username ends in `_ai`, the convention of Telegram's AI agent bots.
    public static func isAgentPeer(_ peer: EnginePeer?) -> Bool {
        return peer?.isAIAgentBot ?? false
    }

    /// The agent is drawn as an AI agent: named "Data AI" with its own picture for an avatar, "AI agent" in the header
    /// and the profile, its work in the chat list.
    public static func isStyled(_ peer: EnginePeer?) -> Bool {
        return peer?.isConceptAIAgent ?? false
    }

    /// What the user writes in this chat goes to the local demo agent instead of the bot.
    public static func isDemoActive(_ peer: EnginePeer?) -> Bool {
        return ConceptFeatures.isEnabled(.aiAgentDemo) && self.isAgentPeer(peer)
    }
}

/// What each agent is doing right now ("writing index.html"), for the chat list, whose rows are laid out off the main
/// queue. The demo engine keeps it in step with its live statuses.
public final class AIAgentLiveStatusTexts {
    public static let shared = AIAgentLiveStatusTexts()

    private var lock = os_unfair_lock()
    private var texts: [EnginePeer.Id: String] = [:]

    public func text(peerId: EnginePeer.Id) -> String? {
        os_unfair_lock_lock(&self.lock)
        defer {
            os_unfair_lock_unlock(&self.lock)
        }
        return self.texts[peerId]
    }

    func update(previous: [EnginePeer.Id: AIAgentLiveStatus], current: [EnginePeer.Id: AIAgentLiveStatus]) {
        os_unfair_lock_lock(&self.lock)
        for peerId in previous.keys where current[peerId] == nil {
            self.texts[peerId] = nil
        }
        for (peerId, status) in current {
            self.texts[peerId] = status.text
        }
        os_unfair_lock_unlock(&self.lock)
    }
}

/// The texts are not in the language packs, so they are given here in Russian and English and follow the app's
/// language. The demo agent itself speaks English.
public enum AIAgentStrings {
    public static func text(_ strings: PresentationStrings, _ russian: String, _ english: String) -> String {
        return self.isRussian(strings) ? russian : english
    }

    public static func isRussian(_ strings: PresentationStrings) -> Bool {
        return strings.baseLanguageCode == "ru"
    }
}

/// The demo agent's settings, kept in UserDefaults.
public enum AIAgentDemoSettings {
    private static let speedKey = "AIAgentDemo_speed"

    /// How fast the demo agent works: 1 is real time, 2 is twice as fast.
    public static var speed: Double {
        get {
            let value = UserDefaults.standard.object(forKey: self.speedKey) as? Double ?? 1.0
            return min(4.0, max(0.25, value))
        }
        set {
            UserDefaults.standard.set(min(4.0, max(0.25, newValue)), forKey: self.speedKey)
        }
    }
}

/// What a live agent is doing, for the chat header and the chat list: "thinking", "writing index.html".
public struct AIAgentLiveStatus: Equatable {
    public let text: String
    /// The agent waits for the user (a permission request).
    public let isWaitingForUser: Bool

    public init(text: String, isWaitingForUser: Bool) {
        self.text = text
        self.isWaitingForUser = isWaitingForUser
    }
}

/// What the user has opened on each run message, keyed by the message's stable id. In memory only, so it survives cell
/// reuse but not a relaunch.
public final class AgentRunUIStateStore {
    public static let shared = AgentRunUIStateStore()

    private var lock = os_unfair_lock()
    private var states: [UInt32: AgentRunUIState] = [:]

    public func state(stableId: UInt32) -> AgentRunUIState {
        os_unfair_lock_lock(&self.lock)
        defer {
            os_unfair_lock_unlock(&self.lock)
        }
        return self.states[stableId] ?? AgentRunUIState()
    }

    public func toggleStep(stableId: UInt32, stepId: String) {
        os_unfair_lock_lock(&self.lock)
        var state = self.states[stableId] ?? AgentRunUIState()
        if state.expandedStepIds.contains(stepId) {
            state.expandedStepIds.remove(stepId)
        } else {
            state.expandedStepIds.insert(stepId)
        }
        self.states[stableId] = state
        os_unfair_lock_unlock(&self.lock)
    }

    public func setPathExpanded(stableId: UInt32, _ value: Bool) {
        os_unfair_lock_lock(&self.lock)
        var state = self.states[stableId] ?? AgentRunUIState()
        state.isPathExpanded = value
        self.states[stableId] = state
        os_unfair_lock_unlock(&self.lock)
    }

    public func reset() {
        os_unfair_lock_lock(&self.lock)
        self.states.removeAll()
        os_unfair_lock_unlock(&self.lock)
    }
}

/// Decodes a message's payload once per revision instead of on every layout pass.
public final class AgentPayloadCache {
    public static let shared = AgentPayloadCache()

    private var lock = os_unfair_lock()
    private var entries: [UInt32: (revision: Int32, payload: AgentMessagePayload?)] = [:]

    public func payload(stableId: UInt32, attribute: AgentDemoMessageAttribute) -> AgentMessagePayload? {
        os_unfair_lock_lock(&self.lock)
        if let entry = self.entries[stableId], entry.revision == attribute.revision {
            os_unfair_lock_unlock(&self.lock)
            return entry.payload
        }
        os_unfair_lock_unlock(&self.lock)

        let payload = AgentMessagePayload.decode(attribute.payload)

        os_unfair_lock_lock(&self.lock)
        if self.entries.count > 256 {
            self.entries.removeAll()
        }
        self.entries[stableId] = (attribute.revision, payload)
        os_unfair_lock_unlock(&self.lock)
        return payload
    }
}

/// The services the user has connected to the demo agent.
public final class AgentConnectionsStore {
    public static let shared = AgentConnectionsStore()

    private let key = "AIAgentDemo_connections"

    public func isConnected(_ serviceId: String) -> Bool {
        return (UserDefaults.standard.stringArray(forKey: self.key) ?? []).contains(serviceId)
    }

    public func setConnected(_ serviceId: String, _ value: Bool) {
        var services = Set(UserDefaults.standard.stringArray(forKey: self.key) ?? [])
        if value {
            services.insert(serviceId)
        } else {
            services.remove(serviceId)
        }
        UserDefaults.standard.set(Array(services).sorted(), forKey: self.key)
    }

    public func reset() {
        UserDefaults.standard.removeObject(forKey: self.key)
    }
}

public extension EngineMessage {
    /// The demo attribute of an agent message, if this is one.
    var agentDemoAttribute: AgentDemoMessageAttribute? {
        for attribute in self.attributes {
            if let attribute = attribute as? AgentDemoMessageAttribute {
                return attribute
            }
        }
        return nil
    }
}
