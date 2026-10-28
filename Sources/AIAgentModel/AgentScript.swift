import Foundation

/// What the demo agent will do for one prompt: the steps of its path, then the answer and an optional result. The
/// engine walks it in real time and writes the run as it goes.
public struct AgentScript: Equatable {
    public enum Item: Equatable {
        case think(AgentScriptThink)
        case plan(AgentScriptPlan)
        case tool(AgentScriptTool)
        case note(AgentScriptNote)
        /// Waits for the user. If they decline, the rest of the items are skipped and `declinedAnswer` is used.
        case permission(AgentScriptPermission)

        public var id: String {
            switch self {
            case let .think(item):
                return item.id
            case let .plan(item):
                return item.id
            case let .tool(item):
                return item.id
            case let .note(item):
                return item.id
            case let .permission(item):
                return item.id
            }
        }
    }

    public var items: [Item]
    /// The answer below the path, with `**bold**` and `` `code` ``.
    public var answer: String
    public var declinedAnswer: String?
    public var artifact: AgentArtifactDraft?

    public init(items: [Item], answer: String, declinedAnswer: String? = nil, artifact: AgentArtifactDraft? = nil) {
        self.items = items
        self.answer = answer
        self.declinedAnswer = declinedAnswer
        self.artifact = artifact
    }

    /// How long the path takes when nothing waits for the user and nothing fails.
    public var pathDuration: Double {
        var total = 0.0
        for item in self.items {
            switch item {
            case let .think(think):
                total += think.seconds
            case let .plan(plan):
                total += plan.seconds
            case let .tool(tool):
                total += tool.seconds
                if let failure = tool.failure {
                    total += failure.seconds
                }
            case let .note(note):
                total += note.seconds
            case .permission:
                break
            }
        }
        return total
    }
}

public struct AgentScriptThink: Equatable {
    public var id: String
    public var seconds: Double
    public var text: String

    public init(id: String, seconds: Double, text: String) {
        self.id = id
        self.seconds = seconds
        self.text = text
    }
}

public struct AgentScriptPlan: Equatable {
    public var id: String
    public var items: [String]
    /// How long the plan stays active before the next step starts.
    public var seconds: Double

    public init(id: String, items: [String], seconds: Double = 0.8) {
        self.id = id
        self.items = items
        self.seconds = seconds
    }
}

public struct AgentScriptTool: Equatable {
    public var id: String
    public var icon: AgentStep.Icon
    public var title: String
    public var doneTitle: String
    public var detail: String?
    public var doneDetail: String?
    /// What the chat header says while the step is active: "searching the web".
    public var statusText: String
    public var input: AgentSnippet?
    public var output: AgentSnippet?
    public var liveCode: AgentLiveCode?
    public var seconds: Double
    /// The plan item this step completes.
    public var completesPlanItem: Int?
    /// The step fails first and is retried by a following step.
    public var failure: AgentScriptToolFailure?

    public init(id: String, icon: AgentStep.Icon, title: String, doneTitle: String, detail: String? = nil, doneDetail: String? = nil, statusText: String, input: AgentSnippet? = nil, output: AgentSnippet? = nil, liveCode: AgentLiveCode? = nil, seconds: Double, completesPlanItem: Int? = nil, failure: AgentScriptToolFailure? = nil) {
        self.id = id
        self.icon = icon
        self.title = title
        self.doneTitle = doneTitle
        self.detail = detail
        self.doneDetail = doneDetail
        self.statusText = statusText
        self.input = input
        self.output = output
        self.liveCode = liveCode
        self.seconds = seconds
        self.completesPlanItem = completesPlanItem
        self.failure = failure
    }
}

/// A tool step that fails before it succeeds: the first attempt fails after `seconds`, then a retry step runs for the
/// tool's own `seconds`.
public struct AgentScriptToolFailure: Equatable {
    public var seconds: Double
    /// e.g. "The site didn't respond".
    public var failedTitle: String
    public var failedDetail: String?
    /// e.g. "Retrying".
    public var retryTitle: String

    public init(seconds: Double, failedTitle: String, failedDetail: String?, retryTitle: String) {
        self.seconds = seconds
        self.failedTitle = failedTitle
        self.failedDetail = failedDetail
        self.retryTitle = retryTitle
    }
}

public struct AgentScriptNote: Equatable {
    public var id: String
    public var text: String
    public var seconds: Double

    public init(id: String, text: String, seconds: Double = 1.2) {
        self.id = id
        self.text = text
        self.seconds = seconds
    }
}

public struct AgentScriptPermission: Equatable {
    public var id: String
    public var permission: AgentPermission
    /// "Needs access to Google Calendar".
    public var title: String
    /// "Connected Google Calendar".
    public var grantedTitle: String
    /// "Calendar access not granted".
    public var declinedTitle: String

    public init(id: String, permission: AgentPermission, title: String, grantedTitle: String, declinedTitle: String) {
        self.id = id
        self.permission = permission
        self.title = title
        self.grantedTitle = grantedTitle
        self.declinedTitle = declinedTitle
    }
}

/// A result before the run has produced its stats.
public struct AgentArtifactDraft: Equatable {
    public var kind: AgentArtifact.Kind
    public var typeTitle: String
    public var title: String
    public var description: String
    public var files: [AgentArtifactFile]
    public var entryFileName: String?
    public var event: AgentEvent?
    public var previewScript: String?

    public init(kind: AgentArtifact.Kind, typeTitle: String, title: String, description: String, files: [AgentArtifactFile], entryFileName: String?, event: AgentEvent?, previewScript: String? = nil) {
        self.kind = kind
        self.typeTitle = typeTitle
        self.title = title
        self.description = description
        self.files = files
        self.entryFileName = entryFileName
        self.event = event
        self.previewScript = previewScript
    }

    /// The chat list line for the result message.
    public var preview: String {
        return "\(self.typeTitle) “\(self.title)”"
    }
}
