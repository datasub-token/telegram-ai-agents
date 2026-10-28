import Foundation

/// One turn of an AI agent: the path of work it took to answer a prompt. Stored as the payload of the agent's message
/// (`AgentDemoMessageAttribute.payload`), so everything here is `Codable` and must stay backward compatible: add
/// optional fields only.
public struct AgentRun: Codable, Equatable {
    public enum Status: String, Codable {
        /// Working through its steps.
        case running
        /// Paused on a permission step until the user answers it.
        case waitingForPermission
        /// The path is done and the answer below it is being written.
        case answering
        case finished
        /// Stopped by the user.
        case stopped
        /// The app quit while the run was live.
        case interrupted
    }

    public var id: Int64
    public var status: Status
    /// Seconds since 1970.
    public var startedAt: Double
    public var finishedAt: Double?
    public var steps: [AgentStep]

    public init(id: Int64, status: Status, startedAt: Double, finishedAt: Double?, steps: [AgentStep]) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.steps = steps
    }

    /// The run still changes: its path or its answer.
    public var isLive: Bool {
        switch self.status {
        case .running, .waitingForPermission, .answering:
            return true
        case .finished, .stopped, .interrupted:
            return false
        }
    }

    /// The path is still being walked; once this is false the path collapses into its summary.
    public var isPathLive: Bool {
        switch self.status {
        case .running, .waitingForPermission:
            return true
        case .answering, .finished, .stopped, .interrupted:
            return false
        }
    }

    /// How long the agent has been working, up to `now` while the path is live.
    public func elapsed(at now: Double) -> Double {
        let end: Double
        if let finishedAt = self.finishedAt {
            end = finishedAt
        } else if let lastFinished = self.steps.compactMap(\.finishedAt).max(), !self.isPathLive {
            end = lastFinished
        } else {
            end = now
        }
        return max(0.0, end - self.startedAt)
    }

    /// The steps counted in the summary ("8 steps"): everything except the plan itself.
    public var countedStepCount: Int {
        return self.steps.filter { $0.kind != .plan }.count
    }
}

/// A node on the agent's path.
public struct AgentStep: Codable, Equatable {
    public enum Kind: String, Codable {
        /// Reasoning. "Thinking…" while active, "Thought for 4s" once done; expands to `thinkingText`.
        case thinking
        /// A tool call: search, opening a page, writing a file, checking. Expands to its input and output.
        case tool
        /// A short paragraph the agent says along the way.
        case note
        /// A checklist whose items get ticked as the run goes.
        case plan
        /// A request to connect a service, answered by the user inline.
        case permission
    }

    public enum Status: String, Codable {
        case active
        case done
        case failed
        /// A permission step waiting for the user.
        case waiting
        case stopped
    }

    public enum Icon: String, Codable {
        case thinking
        case search
        case globe
        case code
        case file
        case terminal
        case calendar
        case image
        case eye
        case plug
        case list
        case sparkles
        case retry
        case check
    }

    /// Stable within the run; views diff rows by it.
    public var id: String
    public var kind: Kind
    public var status: Status
    public var icon: Icon
    /// The title while the step is active, e.g. "Searching the web".
    public var title: String
    /// The title once the step is done, e.g. "Found 8 sources".
    public var doneTitle: String?
    /// A secondary line while active, e.g. the query or the file name.
    public var detail: String?
    /// A secondary line once done, e.g. "26 lines · 819 B".
    public var doneDetail: String?
    public var startedAt: Double
    public var finishedAt: Double?

    /// `.thinking`: the reasoning shown when the node is expanded.
    public var thinkingText: String?
    /// `.note`: the paragraph.
    public var noteText: String?
    /// `.tool`: what the tool was given.
    public var input: AgentSnippet?
    /// `.tool`: what the tool returned.
    public var output: AgentSnippet?
    /// `.tool` writing a file: the code typed out while the step is active.
    public var liveCode: AgentLiveCode?
    /// `.plan`: the checklist.
    public var planItems: [AgentPlanItem]?
    /// `.permission`: the request.
    public var permission: AgentPermission?

    public init(id: String, kind: Kind, status: Status, icon: Icon, title: String, doneTitle: String? = nil, detail: String? = nil, doneDetail: String? = nil, startedAt: Double, finishedAt: Double? = nil, thinkingText: String? = nil, noteText: String? = nil, input: AgentSnippet? = nil, output: AgentSnippet? = nil, liveCode: AgentLiveCode? = nil, planItems: [AgentPlanItem]? = nil, permission: AgentPermission? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.icon = icon
        self.title = title
        self.doneTitle = doneTitle
        self.detail = detail
        self.doneDetail = doneDetail
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.thinkingText = thinkingText
        self.noteText = noteText
        self.input = input
        self.output = output
        self.liveCode = liveCode
        self.planItems = planItems
        self.permission = permission
    }

    /// The title for the step's current state.
    public var displayTitle: String {
        if self.status == .done, let doneTitle = self.doneTitle {
            return doneTitle
        }
        return self.title
    }

    /// The secondary line for the step's current state.
    public var displayDetail: String? {
        if self.status == .done, let doneDetail = self.doneDetail {
            return doneDetail
        }
        return self.detail
    }

    /// How long the step took, or has taken so far.
    public func duration(at now: Double) -> Double {
        return max(0.0, (self.finishedAt ?? now) - self.startedAt)
    }

    /// Whether tapping the node reveals more.
    public var isExpandable: Bool {
        switch self.kind {
        case .thinking:
            return !(self.thinkingText ?? "").isEmpty
        case .tool:
            return self.input != nil || self.output != nil
        case .note, .plan, .permission:
            return false
        }
    }
}

/// A piece of code or text shown in a tool's input/output card.
public struct AgentSnippet: Codable, Equatable {
    /// "json", "html", "javascript", "css", "text"… Used for syntax highlighting.
    public var language: String?
    public var text: String

    public init(language: String?, text: String) {
        self.language = language
        self.text = text
    }

    public var lineCount: Int {
        return self.text.isEmpty ? 0 : self.text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// Code typed out while a "write a file" step is active. The number of visible lines is derived from the time:
/// `min(lines, floor((now - step.startedAt) * linesPerSecond))`; scripts guarantee typing ends before the step does.
public struct AgentLiveCode: Codable, Equatable {
    public var fileName: String
    public var language: String
    public var text: String
    public var linesPerSecond: Double

    public init(fileName: String, language: String, text: String, linesPerSecond: Double) {
        self.fileName = fileName
        self.language = language
        self.text = text
        self.linesPerSecond = linesPerSecond
    }

    public var lines: [String] {
        return self.text.components(separatedBy: "\n")
    }

    public func visibleLineCount(elapsed: Double) -> Int {
        let total = self.lines.count
        guard self.linesPerSecond > 0.0 else {
            return total
        }
        return max(0, min(total, Int(floor(elapsed * self.linesPerSecond))))
    }
}

public struct AgentPlanItem: Codable, Equatable {
    public var title: String
    public var isDone: Bool

    public init(title: String, isDone: Bool) {
        self.title = title
        self.isDone = isDone
    }
}

/// A request to connect a service on the user's behalf.
public struct AgentPermission: Codable, Equatable {
    public enum State: String, Codable {
        case requested
        case connecting
        case granted
        case declined
    }

    /// e.g. "googleCalendar".
    public var serviceId: String
    /// e.g. "Google Calendar".
    public var serviceTitle: String
    /// Why the agent needs it, e.g. "To create the reminder".
    public var reason: String
    public var scopes: [String]
    /// The made-up account shown in the consent sheet.
    public var accountLabel: String
    public var state: State

    public init(serviceId: String, serviceTitle: String, reason: String, scopes: [String], accountLabel: String, state: State) {
        self.serviceId = serviceId
        self.serviceTitle = serviceTitle
        self.reason = reason
        self.scopes = scopes
        self.accountLabel = accountLabel
        self.state = state
    }
}

/// A result the agent sends after a run: a project with files, or a calendar event.
public struct AgentArtifact: Codable, Equatable {
    public enum Kind: String, Codable {
        case project
        case event
    }

    public var id: Int64
    public var runId: Int64
    public var kind: Kind
    /// The chip on the card, e.g. "Game", "Mini App", "Event".
    public var typeTitle: String
    public var title: String
    public var description: String
    public var createdAt: Double
    public var stats: AgentArtifactStats
    public var files: [AgentArtifactFile]
    /// The HTML file the preview opens.
    public var entryFileName: String?
    public var event: AgentEvent?
    /// The run's path in short, for the project's details.
    public var path: [AgentPathSummaryItem]
    /// Run only when the card's preview is rendered, after the project's own scripts: it shows the project in use
    /// (a game in play, a list with entries) rather than its start screen. Not one of the project's files.
    public var previewScript: String?

    public init(id: Int64, runId: Int64, kind: Kind, typeTitle: String, title: String, description: String, createdAt: Double, stats: AgentArtifactStats, files: [AgentArtifactFile], entryFileName: String?, event: AgentEvent?, path: [AgentPathSummaryItem], previewScript: String? = nil) {
        self.id = id
        self.runId = runId
        self.kind = kind
        self.typeTitle = typeTitle
        self.title = title
        self.description = description
        self.createdAt = createdAt
        self.stats = stats
        self.files = files
        self.entryFileName = entryFileName
        self.event = event
        self.path = path
        self.previewScript = previewScript
    }

    public var entryFile: AgentArtifactFile? {
        guard let entryFileName = self.entryFileName else {
            return nil
        }
        return self.files.first(where: { $0.name == entryFileName })
    }
}

public struct AgentArtifactStats: Codable, Equatable {
    /// How long the agent worked on it.
    public var seconds: Double
    public var steps: Int
    public var files: Int
    public var lines: Int
    public var bytes: Int

    public init(seconds: Double, steps: Int, files: Int, lines: Int, bytes: Int) {
        self.seconds = seconds
        self.steps = steps
        self.files = files
        self.lines = lines
        self.bytes = bytes
    }
}

public struct AgentArtifactFile: Codable, Equatable {
    public var name: String
    /// "html", "css", "javascript"…
    public var language: String
    public var text: String

    public init(name: String, language: String, text: String) {
        self.name = name
        self.language = language
        self.text = text
    }

    public var lineCount: Int {
        return self.text.isEmpty ? 0 : self.text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    public var byteCount: Int {
        return self.text.utf8.count
    }
}

/// A programming language, named and coloured as GitHub shows it.
public struct AgentCodeLanguage: Equatable {
    public let name: String
    /// 0xRRGGBB
    public let color: UInt32

    public init(name: String, color: UInt32) {
        self.name = name
        self.color = color
    }

    /// The language of a file's `language` ("html", "css", "javascript"…), or nil for plain text.
    public init?(fileLanguage: String) {
        switch fileLanguage.lowercased() {
        case "javascript", "js":
            self.init(name: "JavaScript", color: 0xF1E05A)
        case "typescript", "ts":
            self.init(name: "TypeScript", color: 0x3178C6)
        case "html", "markup":
            self.init(name: "HTML", color: 0xE34C26)
        case "css":
            self.init(name: "CSS", color: 0x663399)
        case "swift":
            self.init(name: "Swift", color: 0xF05138)
        case "python", "py":
            self.init(name: "Python", color: 0x3572A5)
        case "kotlin":
            self.init(name: "Kotlin", color: 0xA97BFF)
        case "go":
            self.init(name: "Go", color: 0x00ADD8)
        case "rust":
            self.init(name: "Rust", color: 0xDEA584)
        default:
            return nil
        }
    }
}

extension AgentArtifact {
    /// The language most of the project is written in, by size, as GitHub picks a repository's language.
    public var primaryLanguage: AgentCodeLanguage? {
        var sizes: [String: (language: AgentCodeLanguage, bytes: Int)] = [:]
        for file in self.files {
            guard let language = AgentCodeLanguage(fileLanguage: file.language) else {
                continue
            }
            sizes[language.name, default: (language, 0)].bytes += file.byteCount
        }
        return sizes.values.max(by: { $0.bytes < $1.bytes || ($0.bytes == $1.bytes && $0.language.name > $1.language.name) })?.language
    }
}

public struct AgentEvent: Codable, Equatable {
    public var title: String
    /// Seconds since 1970.
    public var startDate: Double
    public var durationMinutes: Int
    public var reminderMinutes: Int
    public var calendarTitle: String

    public init(title: String, startDate: Double, durationMinutes: Int, reminderMinutes: Int, calendarTitle: String) {
        self.title = title
        self.startDate = startDate
        self.durationMinutes = durationMinutes
        self.reminderMinutes = reminderMinutes
        self.calendarTitle = calendarTitle
    }
}

/// One line of a finished run's path, kept with the result for its details.
public struct AgentPathSummaryItem: Codable, Equatable {
    public var icon: AgentStep.Icon
    public var title: String
    public var seconds: Double

    public init(icon: AgentStep.Icon, title: String, seconds: Double) {
        self.icon = icon
        self.title = title
        self.seconds = seconds
    }
}

/// What the user has opened on one run message. Lives in memory only (keyed by the message's stable id), so it
/// survives cell reuse but not a relaunch.
public struct AgentRunUIState: Equatable {
    /// Steps whose details (reasoning, input and output) are open.
    public var expandedStepIds: Set<String>
    /// A finished run shows its whole path instead of the one-line summary.
    public var isPathExpanded: Bool

    public init(expandedStepIds: Set<String> = Set(), isPathExpanded: Bool = false) {
        self.expandedStepIds = expandedStepIds
        self.isPathExpanded = isPathExpanded
    }
}

/// What an agent message carries: a run (with the answer as the message text) or a result.
public struct AgentMessagePayload: Codable, Equatable {
    public var run: AgentRun?
    public var artifact: AgentArtifact?

    public init(run: AgentRun?, artifact: AgentArtifact?) {
        self.run = run
        self.artifact = artifact
    }

    public static func decode(_ data: Data) -> AgentMessagePayload? {
        guard !data.isEmpty else {
            return nil
        }
        return try? JSONDecoder().decode(AgentMessagePayload.self, from: data)
    }

    public func encoded() -> Data {
        return (try? JSONEncoder().encode(self)) ?? Data()
    }
}
