import Foundation
import SwiftSignalKit

/// One of the concept's additions to the app, each with its own switch in Settings ▸ Additions.
///
/// Every addition gets a case here and checks `ConceptFeatures.isEnabled` wherever it changes the app, so that with
/// the switches off the app is plain Telegram.
public enum ConceptFeature: String, CaseIterable {
    /// Bots whose username ends in `_ai` look like AI agents: in the chat list, the chat header and the profile.
    case aiAgentStyle
    /// A local demo agent answers in AI agent chats: it shows its path of work, sends result cards and asks to connect
    /// services. Nothing is sent to the bot. Simulator only.
    case aiAgentDemo
    /// ASCII reveal animations in AI agent chats.
    case aiAgentAscii

    /// Made-up content only ever exists in the simulator, so these have no switch on a device.
    public var isSimulatorOnly: Bool {
        switch self {
        case .aiAgentDemo:
            return true
        case .aiAgentStyle, .aiAgentAscii:
            return false
        }
    }

    /// Whether this build has the addition at all.
    public var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return !self.isSimulatorOnly
        #endif
    }
}

/// The switches of the concept's additions, kept in UserDefaults. Every addition starts switched on, and the switch for
/// all of them turns them off together while keeping each one's own position.
public enum ConceptFeatures {
    private static let allKey = "ConceptFeatures_all"
    private static let updatedPromise = ValuePromise<Int>(0, ignoreRepeated: true)
    private static var version = 0

    /// Fires whenever a switch changes.
    public static var updated: Signal<Void, NoError> {
        return self.updatedPromise.get()
        |> map { _ -> Void in
            return Void()
        }
    }

    public static var isAllEnabled: Bool {
        return UserDefaults.standard.object(forKey: self.allKey) as? Bool ?? true
    }

    public static func setAllEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: self.allKey)
        self.notify()
    }

    /// The feature's own switch, regardless of the switch for all of them.
    public static func isSwitchedOn(_ feature: ConceptFeature) -> Bool {
        return UserDefaults.standard.object(forKey: self.key(feature)) as? Bool ?? true
    }

    public static func setSwitchedOn(_ feature: ConceptFeature, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: self.key(feature))
        self.notify()
    }

    /// Whether the addition is in effect: available in this build, and switched on both on its own and for all.
    public static func isEnabled(_ feature: ConceptFeature) -> Bool {
        return feature.isAvailable && self.isAllEnabled && self.isSwitchedOn(feature)
    }

    private static func key(_ feature: ConceptFeature) -> String {
        return "ConceptFeatures_\(feature.rawValue)"
    }

    private static func notify() {
        Queue.mainQueue().async {
            self.version += 1
            self.updatedPromise.set(self.version)
        }
    }
}
