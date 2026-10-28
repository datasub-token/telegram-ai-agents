import Foundation

#if targetEnvironment(simulator) || os(macOS)

/// An earlier conversation with the agent, so that a recording opens on a chat in use rather than an empty one. It is
/// unlike what the tour sends (no games, no calendar): a list and a translation, answered in the agent's style.
public enum AgentDemoHistory {
    public enum Item: Equatable {
        case prompt(text: String, timestamp: Double)
        case answer(text: String, run: AgentRun)
    }

    /// The conversation, starting two hours before `now`.
    public static func conversation(now: Double) -> [Item] {
        let first = now - 2.0 * 60.0 * 60.0
        let second = first + 4.0 * 60.0
        return [
            .prompt(text: "Turn this into a to-do list: call the bank, send the invoice to Anna, book flights for Friday", timestamp: first),
            .answer(
                text: "Here's your list, most urgent first:\n\n**1.** Send the invoice to Anna\n**2.** Call the bank\n**3.** Book flights for Friday",
                run: AgentRun(id: 1, status: .finished, startedAt: first + 1.0, finishedAt: first + 4.0, steps: [
                    AgentStep(id: "think-1", kind: .thinking, status: .done, icon: .thinking, title: "Thinking…", doneTitle: AgentFormatting.thought(seconds: 2.0, isRussian: false), startedAt: first + 1.0, finishedAt: first + 3.0, thinkingText: "Three tasks. The invoice has someone waiting on it, so it goes first; the flights can wait until Friday."),
                    AgentStep(id: "sort", kind: .tool, status: .done, icon: .list, title: "Sorting by priority", doneTitle: "Sorted by priority", startedAt: first + 3.0, finishedAt: first + 4.0)
                ])
            ),
            .prompt(text: "Thanks! How do I say “See you at the meetup” in Spanish?", timestamp: second),
            .answer(
                text: "**¡Nos vemos en el meetup!** It's casual and friendly. For something more formal: **Nos vemos en la reunión.**",
                run: AgentRun(id: 2, status: .finished, startedAt: second + 1.0, finishedAt: second + 2.0, steps: [
                    AgentStep(id: "think-1", kind: .thinking, status: .done, icon: .thinking, title: "Thinking…", doneTitle: AgentFormatting.thought(seconds: 1.0, isRussian: false), startedAt: second + 1.0, finishedAt: second + 2.0, thinkingText: "A short, friendly phrase. Give the casual version and a formal one.")
                ])
            )
        ]
    }
}

#endif
