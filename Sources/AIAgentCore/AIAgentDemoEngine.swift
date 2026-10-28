import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import AIAgentModel

/// The local demo agent. It answers prompts in AI agent chats by walking a script from `AgentDemoPlanner` in real time
/// and writing the run into a local message at every checkpoint (a step starts or ends, a chunk of the answer). Views
/// derive everything per-frame from the run's timestamps, so nothing here ticks per frame.
///
/// Nothing reaches the network: all writes go through `TelegramEngine.AIAgentDemo`, which stores messages in the local
/// namespace of the bot chat. One engine per account, used on the main queue.
public final class AIAgentDemoEngine {
    private static var engines: [EnginePeer.Id: AIAgentDemoEngine] = [:]

    public static func shared(context: AccountContext) -> AIAgentDemoEngine {
        if let engine = self.engines[context.account.peerId] {
            engine.context = context
            return engine
        }
        let engine = AIAgentDemoEngine(context: context)
        self.engines[context.account.peerId] = engine
        return engine
    }

    private weak var context: AccountContext?
    private let accountPeerId: EnginePeer.Id
    private var runs: [EnginePeer.Id: Run] = [:]

    /// Chats whose earlier conversation was added (or found) in this session.
    private var seededPeerIds = Set<EnginePeer.Id>()

    /// Prompts sent while the agent was busy, answered in order.
    private var pendingPrompts: [EnginePeer.Id: [PendingPrompt]] = [:]

    private var statuses: [EnginePeer.Id: AIAgentLiveStatus] = [:] {
        didSet {
            AIAgentLiveStatusTexts.shared.update(previous: oldValue, current: self.statuses)
            self.statusesPromise.set(self.statuses)
        }
    }
    private let statusesPromise = ValuePromise<[EnginePeer.Id: AIAgentLiveStatus]>([:], ignoreRepeated: true)

    private init(context: AccountContext) {
        self.context = context
        self.accountPeerId = context.account.peerId
        self.repairInterruptedRuns()
    }

    // MARK: - Public

    /// Shows the prompt and starts a run for it. While the chat already has a live run the prompt is shown at once and
    /// answered when that run ends, as a queued message. Returns false only for an empty prompt.
    @discardableResult
    public func handleUserPrompt(peer: EnginePeer, text: String, entities: [MessageTextEntity], correlationId: Int64?) -> Bool {
        #if targetEnvironment(simulator)
        let peerId = peer.id
        guard let context = self.context else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        self.rememberPeer(peerId)

        let runId = Int64.random(in: 1 ... Int64.max)
        let promptAttribute = AgentDemoMessageAttribute(kind: .prompt, runId: runId, revision: 0, isLive: false, isStreamingText: false, preview: trimmed, payload: Data())
        if self.runs[peerId] != nil {
            let pending = PendingPrompt(text: trimmed, runId: runId)
            self.pendingPrompts[peerId, default: []].append(pending)
            let _ = (context.engine.aiAgentDemo.addPrompt(peerId: peerId, text: text, entities: entities, correlationId: correlationId, attribute: promptAttribute)
            |> deliverOnMainQueue).start(next: { promptId in
                pending.promptId = promptId
            })
            return true
        }

        let run = self.startRun(peerId: peerId, text: trimmed, runId: runId)
        let _ = (context.engine.aiAgentDemo.addPrompt(peerId: peerId, text: text, entities: entities, correlationId: correlationId, attribute: promptAttribute)
        |> deliverOnMainQueue).start(next: { [weak self, weak run] promptId in
            guard let self, let run, !run.isFinished else {
                return
            }
            run.promptId = promptId
            self.beginRun(run)
        })
        return true
        #else
        return false
        #endif
    }

    #if targetEnvironment(simulator)
    private func startRun(peerId: EnginePeer.Id, text: String, runId: Int64) -> Run {
        let script = AgentDemoPlanner.script(for: text, now: Date(), calendarConnected: AgentConnectionsStore.shared.isConnected("googleCalendar"))
        let run = Run(peerId: peerId, script: script, run: AgentRun(id: runId, status: .running, startedAt: Date().timeIntervalSince1970, finishedAt: nil, steps: []), seed: UInt64(bitPattern: runId))
        self.runs[peerId] = run
        self.statuses[peerId] = AIAgentLiveStatus(text: "thinking", isWaitingForUser: false)
        return run
    }

    /// The prompt is read, then the run's message appears.
    private func beginRun(_ run: Run) {
        self.after(run, 0.35, scaled: false, {
            if let promptId = run.promptId, let context = self.context {
                let _ = context.engine.aiAgentDemo.markPromptRead(id: promptId).start()
            }
            self.after(run, 0.3, scaled: false, {
                self.addRunMessage(run)
            })
        })
    }

    /// Answers the next queued prompt once the previous result has had a moment on screen.
    private func startNextPendingPrompt(peerId: EnginePeer.Id) {
        guard var queue = self.pendingPrompts[peerId], !queue.isEmpty else {
            return
        }
        let pending = queue.removeFirst()
        self.pendingPrompts[peerId] = queue.isEmpty ? nil : queue
        Queue.mainQueue().after(1.0, { [weak self] in
            guard let self, self.runs[peerId] == nil else {
                return
            }
            let run = self.startRun(peerId: peerId, text: pending.text, runId: pending.runId)
            run.promptId = pending.promptId
            self.beginRun(run)
        })
    }
    #endif

    /// A chat the agent has not answered in yet gets an earlier conversation (`AgentDemoHistory`), so a recording opens
    /// on a chat in use. Made-up content: simulator only.
    public func seedHistoryIfNeeded(peerId: EnginePeer.Id) {
        #if targetEnvironment(simulator)
        guard let context = self.context, !self.seededPeerIds.contains(peerId) else {
            return
        }
        self.seededPeerIds.insert(peerId)
        self.rememberPeer(peerId)
        let _ = (context.engine.aiAgentDemo.messages(peerIds: [peerId])
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] messages in
            guard let self, let context = self.context, messages.isEmpty, self.runs[peerId] == nil else {
                return
            }
            var signals: [Signal<EngineMessage.Id?, NoError>] = []
            var lastPromptIndex: Int?
            for item in AgentDemoHistory.conversation(now: Date().timeIntervalSince1970) {
                switch item {
                case let .prompt(text, timestamp):
                    lastPromptIndex = signals.count
                    let attribute = AgentDemoMessageAttribute(kind: .prompt, runId: 0, revision: 0, isLive: false, isStreamingText: false, preview: text, payload: Data())
                    signals.append(context.engine.aiAgentDemo.addPrompt(peerId: peerId, text: text, entities: [], correlationId: nil, attribute: attribute, timestamp: Int32(timestamp)))
                case let .answer(source, run):
                    let parsed = AgentMarkdown.parse(source)
                    let entities = parsed.spans.map { span -> MessageTextEntity in
                        return MessageTextEntity(range: span.range.location ..< span.range.location + span.range.length, type: span.kind == .bold ? .Bold : .Code)
                    }
                    let preview = parsed.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? parsed.text
                    let attribute = AgentDemoMessageAttribute(kind: .run, runId: run.id, revision: 1, isLive: false, isStreamingText: false, preview: String(preview.prefix(120)), payload: AgentMessagePayload(run: run, artifact: nil).encoded())
                    signals.append(context.engine.aiAgentDemo.addAgentMessage(peerId: peerId, text: parsed.text, entities: entities, attribute: attribute, replyMarkup: nil, timestamp: Int32(run.finishedAt ?? run.startedAt)))
                }
            }
            // Postbox runs the transactions in the order they are subscribed to. The agent has read the prompts.
            let _ = (combineLatest(signals)
            |> take(1)
            |> deliverOnMainQueue).start(next: { ids in
                if let lastPromptIndex, let lastPromptId = ids[lastPromptIndex] {
                    let _ = context.engine.aiAgentDemo.markPromptRead(id: lastPromptId).start()
                }
            })
        })
        #endif
    }

    public func hasLiveRun(peerId: EnginePeer.Id) -> Bool {
        return self.runs[peerId] != nil
    }

    public func isRunLive(peerId: EnginePeer.Id) -> Signal<Bool, NoError> {
        return self.statusesPromise.get()
        |> map { statuses -> Bool in
            return statuses[peerId] != nil
        }
        |> distinctUntilChanged
    }

    public func liveStatus(peerId: EnginePeer.Id) -> Signal<AIAgentLiveStatus?, NoError> {
        return self.statusesPromise.get()
        |> map { statuses -> AIAgentLiveStatus? in
            return statuses[peerId]
        }
        |> distinctUntilChanged
    }

    public func currentStatus(peerId: EnginePeer.Id) -> AIAgentLiveStatus? {
        return self.statuses[peerId]
    }
    
    public func liveStatuses() -> Signal<[EnginePeer.Id: AIAgentLiveStatus], NoError> {
        return self.statusesPromise.get()
    }

    /// Stops the chat's live run: the active step becomes "stopped", an answer being written keeps what it has.
    @discardableResult
    public func stop(peerId: EnginePeer.Id) -> Bool {
        guard let run = self.runs[peerId] else {
            return false
        }
        // Stop means stop: prompts queued behind this run stay unanswered.
        self.pendingPrompts[peerId] = nil
        run.timer?.invalidate()
        run.timer = nil
        let now = Date().timeIntervalSince1970
        if run.run.isPathLive {
            for index in run.run.steps.indices where run.run.steps[index].status == .active || run.run.steps[index].status == .waiting {
                run.run.steps[index].status = .stopped
                run.run.steps[index].finishedAt = now
                run.run.steps[index].liveCode = nil
            }
            run.run.status = .stopped
            run.run.finishedAt = now
        } else {
            run.run.status = .finished
        }
        self.write(run, isStreamingText: false)
        self.end(run)
        return true
    }

    /// The user answered an inline permission request (directly or through the consent sheet).
    public func respondToPermission(messageId: EngineMessage.Id, granted: Bool) {
        guard let run = self.runs.values.first(where: { $0.messageId == messageId }), let stepId = run.permissionStepId, let index = run.run.steps.firstIndex(where: { $0.id == stepId }) else {
            return
        }
        guard run.itemIndex < run.script.items.count, case let .permission(item) = run.script.items[run.itemIndex] else {
            return
        }
        run.permissionStepId = nil
        let now = Date().timeIntervalSince1970
        run.run.steps[index].status = .done
        run.run.steps[index].finishedAt = now
        if granted {
            run.run.steps[index].doneTitle = item.grantedTitle
            run.run.steps[index].permission?.state = .granted
            AgentConnectionsStore.shared.setConnected(item.permission.serviceId, true)
            run.run.status = .running
            self.write(run)
            run.itemIndex += 1
            self.after(run, 0.5, scaled: false, {
                self.advance(run)
            })
        } else {
            run.run.steps[index].doneTitle = item.declinedTitle
            run.run.steps[index].permission?.state = .declined
            run.declined = true
            self.write(run)
            self.after(run, 0.4, scaled: false, {
                self.finishPath(run)
            })
        }
    }

    /// Deletes the demo messages from every chat the agent has answered in and forgets connections and opened state.
    public func reset() -> Signal<Never, NoError> {
        for run in self.runs.values {
            run.timer?.invalidate()
            run.isFinished = true
        }
        self.runs.removeAll()
        self.pendingPrompts.removeAll()
        self.seededPeerIds.removeAll()
        self.statuses.removeAll()
        AgentRunUIStateStore.shared.reset()
        AgentConnectionsStore.shared.reset()
        guard let context = self.context else {
            return .complete()
        }
        return context.engine.aiAgentDemo.deleteMessages(peerIds: self.rememberedPeers())
    }

    // MARK: - Walking the script

    private func addRunMessage(_ run: Run) {
        guard let context = self.context, !run.isFinished else {
            return
        }
        run.revision += 1
        let attribute = AgentDemoMessageAttribute(kind: .run, runId: run.run.id, revision: run.revision, isLive: true, isStreamingText: false, preview: run.preview(status: self.statuses[run.peerId]), payload: AgentMessagePayload(run: run.run, artifact: nil).encoded())
        let _ = (context.engine.aiAgentDemo.addAgentMessage(peerId: run.peerId, text: "", entities: [], attribute: attribute, replyMarkup: nil)
        |> deliverOnMainQueue).start(next: { [weak self, weak run] messageId in
            guard let self, let run, !run.isFinished else {
                return
            }
            guard let messageId else {
                self.end(run)
                return
            }
            run.messageId = messageId
            self.advance(run)
        })
    }

    private func advance(_ run: Run) {
        guard !run.isFinished else {
            return
        }
        guard run.itemIndex < run.script.items.count, !run.declined else {
            self.finishPath(run)
            return
        }
        let now = Date().timeIntervalSince1970
        switch run.script.items[run.itemIndex] {
        case let .think(think):
            run.run.steps.append(AgentStep(id: think.id, kind: .thinking, status: .active, icon: .thinking, title: "Thinking…", startedAt: now, thinkingText: think.text))
            self.setStatus(run, "thinking")
            self.write(run)
            self.after(run, think.seconds, scaled: true, {
                let finishedAt = Date().timeIntervalSince1970
                run.updateStep(think.id) { step in
                    step.status = .done
                    step.finishedAt = finishedAt
                    step.doneTitle = AgentFormatting.thought(seconds: finishedAt - step.startedAt, isRussian: false)
                }
                self.write(run)
                run.itemIndex += 1
                self.advance(run)
            })
        case let .plan(plan):
            run.run.steps.append(AgentStep(id: plan.id, kind: .plan, status: .done, icon: .list, title: "Plan", startedAt: now, finishedAt: now, planItems: plan.items.map { AgentPlanItem(title: $0, isDone: false) }))
            run.planStepId = plan.id
            self.write(run)
            self.after(run, plan.seconds, scaled: true, {
                run.itemIndex += 1
                self.advance(run)
            })
        case let .tool(tool):
            self.startTool(run, tool, now: now)
        case let .note(note):
            run.run.steps.append(AgentStep(id: note.id, kind: .note, status: .done, icon: .sparkles, title: "", startedAt: now, finishedAt: now, noteText: note.text))
            self.write(run)
            self.after(run, note.seconds, scaled: true, {
                run.itemIndex += 1
                self.advance(run)
            })
        case let .permission(item):
            run.run.steps.append(AgentStep(id: item.id, kind: .permission, status: .waiting, icon: .plug, title: item.title, startedAt: now, permission: item.permission))
            run.permissionStepId = item.id
            run.run.status = .waitingForPermission
            self.statuses[run.peerId] = AIAgentLiveStatus(text: "waiting for permission", isWaitingForUser: true)
            self.write(run)
        }
    }

    private func startTool(_ run: Run, _ tool: AgentScriptTool, now: Double) {
        let failure = tool.failure
        run.run.steps.append(AgentStep(id: tool.id, kind: .tool, status: .active, icon: tool.icon, title: tool.title, doneTitle: tool.doneTitle, detail: tool.detail, doneDetail: tool.doneDetail, startedAt: now, input: tool.input, liveCode: failure == nil ? self.scaled(tool.liveCode) : nil))
        self.setStatus(run, tool.statusText)
        self.write(run)

        if let failure {
            self.after(run, failure.seconds, scaled: true, {
                let failedAt = Date().timeIntervalSince1970
                run.updateStep(tool.id) { step in
                    step.status = .failed
                    step.finishedAt = failedAt
                    step.doneTitle = failure.failedTitle
                    step.doneDetail = failure.failedDetail
                    step.title = failure.failedTitle
                    step.detail = failure.failedDetail
                }
                let retryId = tool.id + "-retry"
                run.run.steps.append(AgentStep(id: retryId, kind: .tool, status: .active, icon: .retry, title: failure.retryTitle, doneTitle: tool.doneTitle, detail: tool.detail, doneDetail: tool.doneDetail, startedAt: failedAt, input: tool.input, liveCode: self.scaled(tool.liveCode)))
                self.write(run)
                self.after(run, tool.seconds, scaled: true, {
                    self.finishTool(run, tool, stepId: retryId)
                })
            })
        } else {
            self.after(run, tool.seconds, scaled: true, {
                self.finishTool(run, tool, stepId: tool.id)
            })
        }
    }

    /// Code types at the demo speed, so it still finishes within its step.
    private func scaled(_ liveCode: AgentLiveCode?) -> AgentLiveCode? {
        guard var liveCode else {
            return nil
        }
        liveCode.linesPerSecond *= AIAgentDemoSettings.speed
        return liveCode
    }
    
    private func finishTool(_ run: Run, _ tool: AgentScriptTool, stepId: String) {
        let finishedAt = Date().timeIntervalSince1970
        run.updateStep(stepId) { step in
            step.status = .done
            step.finishedAt = finishedAt
            step.output = tool.output
            step.liveCode = nil
        }
        if let planIndex = tool.completesPlanItem, let planStepId = run.planStepId {
            run.updateStep(planStepId) { step in
                if var items = step.planItems, planIndex < items.count {
                    items[planIndex].isDone = true
                    step.planItems = items
                }
            }
        }
        self.write(run)
        run.itemIndex += 1
        self.advance(run)
    }

    private func finishPath(_ run: Run) {
        guard !run.isFinished else {
            return
        }
        run.run.status = .answering
        run.run.finishedAt = Date().timeIntervalSince1970
        self.setStatus(run, "answering")
        self.write(run)

        let source = run.declined ? (run.script.declinedAnswer ?? run.script.answer) : run.script.answer
        let parsed = AgentMarkdown.parse(source)
        run.answerCharacters = Array(parsed.text)
        run.answerSpans = parsed.spans
        run.answerRevealed = 0
        // Let the path collapse before the answer starts.
        self.after(run, 0.55, scaled: false, {
            self.streamAnswer(run)
        })
    }

    private func streamAnswer(_ run: Run) {
        guard !run.isFinished else {
            return
        }
        let total = run.answerCharacters.count
        run.answerRevealed = min(total, run.answerRevealed + Int(run.random.next(in: 3 ... 12)))
        let text = String(run.answerCharacters[0 ..< run.answerRevealed])
        let length = (text as NSString).length
        run.text = text
        run.entities = run.answerSpans.compactMap { span -> MessageTextEntity? in
            let lower = span.range.location
            let upper = min(length, span.range.location + span.range.length)
            guard upper > lower else {
                return nil
            }
            return MessageTextEntity(range: lower ..< upper, type: span.kind == .bold ? .Bold : .Code)
        }
        if run.answerRevealed < total {
            self.write(run, isStreamingText: true)
            self.after(run, 0.09 + run.random.nextUnit() * 0.05, scaled: true, {
                self.streamAnswer(run)
            })
        } else {
            run.run.status = .finished
            self.write(run, isStreamingText: false)
            let artifact = run.declined ? nil : run.script.artifact
            let finishedRun = run.run
            let peerId = run.peerId
            self.end(run)
            if let artifact {
                Queue.mainQueue().after(0.6, { [weak self] in
                    self?.addArtifactMessage(peerId: peerId, run: finishedRun, draft: artifact)
                })
            }
        }
    }

    private func addArtifactMessage(peerId: EnginePeer.Id, run: AgentRun, draft: AgentArtifactDraft) {
        guard let context = self.context else {
            return
        }
        let seconds = max(1.0, run.elapsed(at: Date().timeIntervalSince1970))
        let stats = AgentArtifactStats(
            seconds: seconds,
            steps: run.countedStepCount,
            files: draft.files.count,
            lines: draft.files.reduce(0, { $0 + $1.lineCount }),
            bytes: draft.files.reduce(0, { $0 + $1.byteCount })
        )
        let path = run.steps.filter { $0.kind != .plan && $0.kind != .note }.map { step in
            return AgentPathSummaryItem(icon: step.icon, title: step.displayTitle, seconds: step.duration(at: run.finishedAt ?? step.startedAt))
        }
        let artifact = AgentArtifact(id: Int64.random(in: 1 ... Int64.max), runId: run.id, kind: draft.kind, typeTitle: draft.typeTitle, title: draft.title, description: draft.description, createdAt: Date().timeIntervalSince1970, stats: stats, files: draft.files, entryFileName: draft.entryFileName, event: draft.event, path: path, previewScript: draft.previewScript)
        let attribute = AgentDemoMessageAttribute(kind: .artifact, runId: run.id, revision: 1, isLive: false, isStreamingText: false, preview: draft.preview, payload: AgentMessagePayload(run: nil, artifact: artifact).encoded())
        let _ = context.engine.aiAgentDemo.addAgentMessage(peerId: peerId, text: "", entities: [], attribute: attribute, replyMarkup: nil).start()
    }

    // MARK: - Helpers

    private func write(_ run: Run, isStreamingText: Bool = false) {
        guard let context = self.context, let messageId = run.messageId else {
            return
        }
        run.revision += 1
        let attribute = AgentDemoMessageAttribute(kind: .run, runId: run.run.id, revision: run.revision, isLive: run.run.isLive, isStreamingText: isStreamingText, preview: run.preview(status: self.statuses[run.peerId]), payload: AgentMessagePayload(run: run.run, artifact: nil).encoded())
        let _ = context.engine.aiAgentDemo.updateAgentMessage(id: messageId, text: run.text, entities: run.entities, attribute: attribute, replyMarkup: nil).start()
    }

    private func setStatus(_ run: Run, _ text: String) {
        self.statuses[run.peerId] = AIAgentLiveStatus(text: text, isWaitingForUser: false)
    }

    private func end(_ run: Run) {
        run.isFinished = true
        run.timer?.invalidate()
        run.timer = nil
        if self.runs[run.peerId] === run {
            self.runs[run.peerId] = nil
        }
        self.statuses[run.peerId] = nil
        #if targetEnvironment(simulator)
        self.startNextPendingPrompt(peerId: run.peerId)
        #endif
    }

    /// Runs `f` after `seconds` unless the run has ended. Script durations are `scaled` by the demo speed.
    private func after(_ run: Run, _ seconds: Double, scaled: Bool, _ f: @escaping () -> Void) {
        run.timer?.invalidate()
        let delay = scaled ? seconds / AIAgentDemoSettings.speed : seconds
        let timer = SwiftSignalKit.Timer(timeout: max(0.01, delay), repeat: false, completion: { [weak run] in
            guard let run, !run.isFinished else {
                return
            }
            run.timer = nil
            f()
        }, queue: Queue.mainQueue())
        run.timer = timer
        timer.start()
    }

    /// Runs left live by a previous launch can't continue: they are marked interrupted.
    private func repairInterruptedRuns() {
        guard let context = self.context else {
            return
        }
        let peerIds = self.rememberedPeers()
        guard !peerIds.isEmpty else {
            return
        }
        let _ = (context.engine.aiAgentDemo.messages(peerIds: peerIds)
        |> deliverOnMainQueue).start(next: { [weak self] messages in
            guard let self, let context = self.context else {
                return
            }
            for message in messages {
                guard let attribute = message.agentDemoAttribute, attribute.kind == .run, attribute.isLive || attribute.isStreamingText, self.runs[message.id.peerId] == nil else {
                    continue
                }
                guard var run = AgentMessagePayload.decode(attribute.payload)?.run else {
                    continue
                }
                let lastFinished = run.steps.compactMap(\.finishedAt).max() ?? run.startedAt
                for index in run.steps.indices where run.steps[index].status == .active || run.steps[index].status == .waiting {
                    run.steps[index].status = .stopped
                    run.steps[index].finishedAt = lastFinished
                    run.steps[index].liveCode = nil
                }
                if run.isPathLive {
                    run.status = .interrupted
                    run.finishedAt = lastFinished
                } else {
                    run.status = .finished
                }
                let entities = message.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities ?? []
                let updated = AgentDemoMessageAttribute(kind: .run, runId: attribute.runId, revision: attribute.revision + 1, isLive: false, isStreamingText: false, preview: message.text.isEmpty ? "Interrupted" : String(message.text.prefix(120)), payload: AgentMessagePayload(run: run, artifact: nil).encoded())
                let _ = context.engine.aiAgentDemo.updateAgentMessage(id: message.id, text: message.text, entities: entities, attribute: updated, replyMarkup: nil).start()
            }
        })
    }

    private var peersKey: String {
        return "AIAgentDemo_peers_\(self.accountPeerId.toInt64())"
    }

    private func rememberedPeers() -> [EnginePeer.Id] {
        let values = UserDefaults.standard.array(forKey: self.peersKey) as? [NSNumber] ?? []
        return values.map { EnginePeer.Id($0.int64Value) }
    }

    private func rememberPeer(_ peerId: EnginePeer.Id) {
        var values = UserDefaults.standard.array(forKey: self.peersKey) as? [NSNumber] ?? []
        if !values.contains(where: { $0.int64Value == peerId.toInt64() }) {
            values.append(NSNumber(value: peerId.toInt64()))
            UserDefaults.standard.set(values, forKey: self.peersKey)
        }
    }
}

/// One live run and its progress through the script.
private final class PendingPrompt {
    let text: String
    let runId: Int64
    var promptId: EngineMessage.Id?

    init(text: String, runId: Int64) {
        self.text = text
        self.runId = runId
    }
}

private final class Run {
    let peerId: EnginePeer.Id
    let script: AgentScript
    var run: AgentRun
    var promptId: EngineMessage.Id?
    var messageId: EngineMessage.Id?
    var itemIndex = 0
    var revision: Int32 = 0
    var timer: SwiftSignalKit.Timer?
    var isFinished = false
    var declined = false
    var planStepId: String?
    var permissionStepId: String?
    /// The answer written so far: the message text.
    var text = ""
    var entities: [MessageTextEntity] = []
    var answerCharacters: [Character] = []
    var answerSpans: [AgentTextSpan] = []
    var answerRevealed = 0
    var random: SplitMix64

    init(peerId: EnginePeer.Id, script: AgentScript, run: AgentRun, seed: UInt64) {
        self.peerId = peerId
        self.script = script
        self.run = run
        self.random = SplitMix64(seed: seed)
    }

    func updateStep(_ id: String, _ f: (inout AgentStep) -> Void) {
        if let index = self.run.steps.firstIndex(where: { $0.id == id }) {
            f(&self.run.steps[index])
        }
    }

    /// The chat list line: what the agent is doing while live, the start of the answer afterwards.
    func preview(status: AIAgentLiveStatus?) -> String {
        switch self.run.status {
        case .running, .waitingForPermission:
            if let status {
                return status.text.prefix(1).uppercased() + status.text.dropFirst() + "…"
            }
            return "Thinking…"
        case .answering, .finished:
            if self.text.isEmpty {
                return "Answering…"
            }
            let firstLine = self.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? self.text
            return String(firstLine.prefix(120))
        case .stopped:
            return "Stopped"
        case .interrupted:
            return "Interrupted"
        }
    }
}

/// A small seeded generator, so the same run always streams its answer the same way.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E3779B97F4A7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(self.next() % width)
    }

    mutating func nextUnit() -> Double {
        return Double(self.next() >> 11) / Double(1 << 53)
    }
}
