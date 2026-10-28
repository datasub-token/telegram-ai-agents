import Foundation
import Postbox

/// A message of the AI agent demo: the user's prompt, the agent's run (its path and the answer below it), or one of the
/// agent's results. These messages live only on this device, in `Namespaces.Message.Local`, and are never sent.
public final class AgentDemoMessageAttribute: MessageAttribute {
    public enum Kind: Int32 {
        case prompt = 0
        case run = 1
        case artifact = 2
    }

    public let kind: Kind
    public let runId: Int64
    /// Bumped on every update, so that a decoded payload can be cached per revision.
    public let revision: Int32
    /// The run is still in progress.
    public let isLive: Bool
    /// The answer below the run is still being written.
    public let isStreamingText: Bool
    /// The line shown for this message in the chat list.
    public let preview: String
    /// The run or the result, encoded by the app. TelegramCore does not look inside.
    public let payload: Data

    public init(kind: Kind, runId: Int64, revision: Int32, isLive: Bool, isStreamingText: Bool, preview: String, payload: Data) {
        self.kind = kind
        self.runId = runId
        self.revision = revision
        self.isLive = isLive
        self.isStreamingText = isStreamingText
        self.preview = preview
        self.payload = payload
    }

    public init(decoder: PostboxDecoder) {
        self.kind = Kind(rawValue: decoder.decodeInt32ForKey("k", orElse: 0)) ?? .prompt
        self.runId = decoder.decodeInt64ForKey("r", orElse: 0)
        self.revision = decoder.decodeInt32ForKey("v", orElse: 0)
        self.isLive = decoder.decodeBoolForKey("l", orElse: false)
        self.isStreamingText = decoder.decodeBoolForKey("s", orElse: false)
        self.preview = decoder.decodeStringForKey("pv", orElse: "")
        self.payload = decoder.decodeDataForKey("p") ?? Data()
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.kind.rawValue, forKey: "k")
        encoder.encodeInt64(self.runId, forKey: "r")
        encoder.encodeInt32(self.revision, forKey: "v")
        encoder.encodeBool(self.isLive, forKey: "l")
        encoder.encodeBool(self.isStreamingText, forKey: "s")
        encoder.encodeString(self.preview, forKey: "pv")
        encoder.encodeData(self.payload, forKey: "p")
    }
}
