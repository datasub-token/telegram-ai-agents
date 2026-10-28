import Foundation

#if targetEnvironment(simulator) || os(macOS)

/// The local demo agent's "brain": reads what the user wrote and builds a path of work that fits it. Made-up content,
/// so it only exists in the simulator (and on macOS for the host tests). The agent speaks English; it also understands
/// the same requests in Russian.
public enum AgentDemoPlanner {
    public enum Intent: Equatable {
        case build(AgentDemoProjectKind)
        case calendar
        case search
        case greeting
        case capabilities
        case other
    }

    public enum AgentDemoProjectKind: Equatable {
        case game
        case site
        case miniApp
    }

    /// Whether the Google Calendar connection is already granted; the calendar path skips its permission step then.
    public static func script(for prompt: String, now: Date, calendarConnected: Bool = false) -> AgentScript {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self.intent(for: text) {
        case let .build(kind):
            return self.buildScript(prompt: text, kind: kind)
        case .calendar:
            return self.calendarScript(prompt: text, now: now, calendarConnected: calendarConnected)
        case .search:
            return self.searchScript(prompt: text)
        case .greeting:
            return self.greetingScript(prompt: text)
        case .capabilities:
            return self.capabilitiesScript()
        case .other:
            return self.genericScript(prompt: text)
        }
    }

    public static func intent(for prompt: String) -> Intent {
        let text = prompt.lowercased()
        let words = Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        func contains(_ fragments: [String]) -> Bool {
            return fragments.contains(where: { text.contains($0) })
        }
        func hasWord(_ candidates: [String]) -> Bool {
            return candidates.contains(where: { words.contains($0) })
        }

        let isCalendar = contains(["напомни", "напомин", "календар", "встреч", "событи", "remind", "calendar", "meeting", "schedule", "appointment"])
        let buildVerb = contains(["сдела", "созда", "напиш", "собер", "разработ", "сверста", "запили"]) || hasWord(["make", "build", "create", "develop", "code"])
        let wantsTogether = contains(["можем", "можешь", "можно", "давай", "хочу", "can you", "could you", "let's", "lets", "i want", "i'd like"])

        if contains(["игр"]) || hasWord(["game", "games"]) {
            if buildVerb || wantsTogether {
                return .build(.game)
            }
        }
        if contains(["сайт", "лендинг", "landing", "website"]) || hasWord(["site"]) {
            if buildVerb || wantsTogether {
                return .build(.site)
            }
        }
        if buildVerb && !isCalendar {
            let isRussianRequest = contains(["сдела", "созда", "напиш", "собер", "разработ", "сверста", "запили"])
            if isRussianRequest || hasWord(["app", "apps", "miniapp", "tracker", "todo", "list", "notes", "store", "shop", "market", "tool", "dashboard"]) || contains(["mini app", "mini-app", "to-do"]) {
                return .build(.miniApp)
            }
        }
        if isCalendar {
            return .calendar
        }
        if contains(["найди", "найти", "поищи", "поиск", "билет", "рейс", "сравни", "look up", "flight"]) || hasWord(["find", "search", "tickets", "ticket", "flights", "compare"]) {
            return .search
        }
        if contains(["что ты умеешь", "что умеешь", "что можешь", "кто ты", "what can you", "who are you", "what do you do", "how can you help"]) {
            return .capabilities
        }
        if contains(["привет", "салам", "ассалам", "здравств", "добрый", "как дела", "как ты", "how are you", "good morning", "good evening"]) || hasWord(["hi", "hello", "hey", "yo"]) {
            return .greeting
        }
        return .other
    }

    // MARK: - Build

    private static func buildScript(prompt: String, kind: AgentDemoProjectKind) -> AgentScript {
        let title = self.projectTitle(prompt: prompt, kind: kind)
        let projectKind: AgentDemoProjects.Kind
        let typeTitle: String
        let object: String
        let description: String
        switch kind {
        case .game:
            projectKind = .game
            typeTitle = "Game"
            object = "a game"
            description = "Catch falling stars with a tap and rack up points. Miss three and it's game over."
        case .site:
            projectKind = .site
            typeTitle = "Website"
            object = "a website"
            description = "A one-page site: a cover, three highlights and a way to get in touch."
        case .miniApp:
            projectKind = .miniApp
            typeTitle = "Mini App"
            object = "a mini app"
            description = "A list you can add to and check off. Everything is saved on the device."
        }
        let files = AgentDemoProjects.files(kind: projectKind, title: title)

        var items: [AgentScript.Item] = []
        items.append(.think(AgentScriptThink(
            id: "think-1",
            seconds: 3.6,
            text: "The ask is \(object) called “\(title)”. I'll build it as a Telegram Mini App: one screen, thumb-sized controls and colors taken from the Telegram theme, so it feels native in both light and dark mode. No external libraries, so it opens instantly."
        )))
        items.append(.plan(AgentScriptPlan(id: "plan", items: [
            "Design the structure",
            "Lay out the interface",
            "Write the logic",
            "Test on iPhone"
        ])))
        items.append(.tool(AgentScriptTool(
            id: "docs",
            icon: .globe,
            title: "Reading the Mini Apps docs",
            doneTitle: "Read the Mini Apps docs",
            detail: "core.telegram.org/bots/webapps",
            doneDetail: "Theme, buttons and haptics",
            statusText: "reading the docs",
            input: AgentSnippet(language: "text", text: "core.telegram.org/bots/webapps\nsections: themeParams, MainButton, HapticFeedback"),
            output: AgentSnippet(language: "text", text: "themeParams → --tg-theme-* CSS variables\nMainButton → the main button at the bottom\nHapticFeedback.impactOccurred('light')"),
            seconds: 2.4,
            completesPlanItem: 0
        )))
        for (index, file) in files.enumerated() {
            let lineCount = file.lineCount
            let linesPerSecond: Double = 18.0
            let seconds = max(2.0, Double(lineCount) / linesPerSecond / 0.85)
            let isLast = index == files.count - 1
            items.append(.tool(AgentScriptTool(
                id: "write-\(file.name)",
                icon: .code,
                title: "Writing \(file.name)",
                doneTitle: "Wrote \(file.name)",
                detail: nil,
                doneDetail: AgentFormatting.lines(lineCount, isRussian: false) + " · " + AgentFormatting.bytes(file.byteCount, isRussian: false),
                statusText: "writing \(file.name)",
                input: nil,
                output: AgentSnippet(language: file.language, text: file.text),
                liveCode: AgentLiveCode(fileName: file.name, language: file.language, text: file.text, linesPerSecond: linesPerSecond),
                seconds: seconds,
                completesPlanItem: index == 0 ? 1 : (isLast ? 2 : nil)
            )))
        }
        items.append(.think(AgentScriptThink(
            id: "think-2",
            seconds: 2.2,
            text: "Let me make sure everything fits a 390 pt screen, is easy to hit with a thumb, and keeps its contrast in dark mode."
        )))
        items.append(.tool(AgentScriptTool(
            id: "check",
            icon: .eye,
            title: "Testing on iPhone",
            doneTitle: "Tested on iPhone",
            detail: "Light and dark mode",
            doneDetail: "0 errors · 60 fps",
            statusText: "testing on iPhone",
            input: AgentSnippet(language: "text", text: "iPhone 17 Pro · 390 × 844 pt\nlight and dark mode"),
            output: AgentSnippet(language: "text", text: "load time: 120 ms\nconsole errors: 0\nframes per second: 60"),
            seconds: 3.0,
            completesPlanItem: 3
        )))

        let answer: String
        switch kind {
        case .game:
            answer = "Done! I made **\(title)**, a game where you catch falling stars with a tap: every star is a point, and three misses end the round. Open the card below to play it right here."
        case .site:
            answer = "Done! I built the **\(title)** website: a cover, three highlights and a contact block, all in your Telegram theme. Open the card below to take a look."
        case .miniApp:
            answer = "Done! I made **\(title)**, a mini app where you add entries and check them off, and everything is saved. Open the card below to try it."
        }
        return AgentScript(
            items: items,
            answer: answer,
            artifact: AgentArtifactDraft(kind: .project, typeTitle: typeTitle, title: title, description: description, files: files, entryFileName: "index.html", event: nil, previewScript: AgentDemoProjects.previewScript(kind: projectKind))
        )
    }

    /// A name in quotes wins; otherwise what follows the object word ("a game called Space Run"), or a default.
    static func projectTitle(prompt: String, kind: AgentDemoProjectKind) -> String {
        if let quoted = self.quoted(prompt) {
            return quoted
        }
        let lowercased = prompt.lowercased()
        let separators = CharacterSet(charactersIn: " ,.!?-—:")
        let fillers: Set<String> = ["called", "named", "titled", "a", "an", "the", "for", "me", "us", "please", "мне", "нам", "пожалуйста"]
        func cleaned(_ tail: Substring) -> String? {
            let words = tail.trimmingCharacters(in: separators).split(separator: " ").map(String.init)
            var start = 0
            while start < words.count, fillers.contains(words[start].lowercased()) {
                start += 1
            }
            let value = words[start...].joined(separator: " ").trimmingCharacters(in: separators)
            return !value.isEmpty && value.count <= 32 ? value : nil
        }
        let objectWords: [String]
        switch kind {
        case .game:
            objectWords = ["игру", "игра", "игры", "game"]
        case .site:
            objectWords = ["сайт", "лендинг", "страницу", "website", "landing page", "site"]
        case .miniApp:
            objectWords = ["мини-приложение", "приложение", "мини апп", "мини-апп", "mini app", "app"]
        }
        for word in objectWords {
            if let range = lowercased.range(of: word) {
                if let value = cleaned(prompt[range.upperBound...]) {
                    return self.capitalizedTitle(value)
                }
            }
        }
        if case .miniApp = kind {
            // "build a habit tracker" → "Habit Tracker", "создай тг маркет" → "ТГ Маркет".
            let verbs = ["сделай", "создай", "напиши", "собери", "разработай", "сверстай", "make", "build", "create", "develop"]
            for verb in verbs {
                if let range = lowercased.range(of: verb) {
                    var tail = String(prompt[range.upperBound...])
                    for suffix in [" mini app", " app"] where tail.lowercased().hasSuffix(suffix) && tail.count > suffix.count + 1 {
                        tail = String(tail.dropLast(suffix.count))
                    }
                    if let value = cleaned(Substring(tail)) {
                        return self.capitalizedTitle(value)
                    }
                }
            }
        }
        switch kind {
        case .game:
            return "Starfall"
        case .site:
            return "Showcase"
        case .miniApp:
            return "Notes"
        }
    }

    private static func quoted(_ text: String) -> String? {
        let pairs: [(Character, Character)] = [("«", "»"), ("\"", "\""), ("“", "”")]
        for (open, close) in pairs {
            if let start = text.firstIndex(of: open) {
                let rest = text[text.index(after: start)...]
                if let end = rest.firstIndex(of: close) {
                    let value = rest[..<end].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        return String(value)
                    }
                }
            }
        }
        return nil
    }

    /// Capitalises each word; short abbreviations ("tg") become upper case.
    private static func capitalizedTitle(_ text: String) -> String {
        return text.split(separator: " ").map { word -> String in
            let string = String(word)
            if string.count <= 2 {
                return string.uppercased()
            }
            return string.prefix(1).uppercased() + string.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: - Calendar

    private static func calendarScript(prompt: String, now: Date, calendarConnected: Bool) -> AgentScript {
        let event = self.event(from: prompt, now: now)
        let when = self.formatEventDate(event.startDate, now: now)

        var items: [AgentScript.Item] = []
        items.append(.think(AgentScriptThink(
            id: "think-1",
            seconds: 2.4,
            text: "I need to create “\(event.title)” for \(when) with a reminder ahead of time. That takes calendar access, so let me check the connections first."
        )))
        items.append(.tool(AgentScriptTool(
            id: "connections",
            icon: .plug,
            title: "Checking connections",
            doneTitle: calendarConnected ? "Google Calendar is connected" : "No calendar connected",
            statusText: "checking connections",
            input: AgentSnippet(language: "json", text: "{ \"service\": \"google_calendar\" }"),
            output: AgentSnippet(language: "json", text: calendarConnected ? "{ \"connected\": true }" : "{ \"connected\": false }"),
            seconds: 1.4
        )))
        if !calendarConnected {
            items.append(.permission(AgentScriptPermission(
                id: "permission",
                permission: AgentPermission(
                    serviceId: "googleCalendar",
                    serviceTitle: "Google Calendar",
                    reason: "To create the reminder",
                    scopes: ["View events", "Create and edit events"],
                    accountLabel: "you@gmail.com",
                    state: .requested
                ),
                title: "Needs access to Google Calendar",
                grantedTitle: "Connected Google Calendar",
                declinedTitle: "Calendar access not granted"
            )))
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let start = isoFormatter.string(from: Date(timeIntervalSince1970: event.startDate))
        items.append(.tool(AgentScriptTool(
            id: "create-event",
            icon: .calendar,
            title: "Creating the event",
            doneTitle: "Created the event",
            detail: "Google Calendar",
            doneDetail: "Reminder \(event.reminderMinutes) min before",
            statusText: "creating the event",
            input: AgentSnippet(language: "json", text: "{\n  \"title\": \"\(event.title)\",\n  \"start\": \"\(start)\",\n  \"duration\": \(event.durationMinutes),\n  \"reminder\": \(event.reminderMinutes)\n}"),
            output: AgentSnippet(language: "json", text: "{\n  \"status\": \"confirmed\",\n  \"calendar\": \"\(event.calendarTitle)\"\n}"),
            seconds: 2.2
        )))

        return AgentScript(
            items: items,
            answer: "Done! **\(event.title)** is set for \(when). I'll remind you \(event.reminderMinutes) minutes before.",
            declinedAnswer: "No problem. Without calendar access I can't create the event, but just ask again if you change your mind.",
            artifact: AgentArtifactDraft(kind: .event, typeTitle: "Event", title: event.title, description: "Reminder \(event.reminderMinutes) minutes before", files: [], entryFileName: nil, event: event)
        )
    }

    static func event(from prompt: String, now: Date) -> AgentEvent {
        let lowercased = prompt.lowercased()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        var dayOffset = 1
        if lowercased.contains("послезавтра") || lowercased.contains("day after tomorrow") {
            dayOffset = 2
        } else if lowercased.contains("сегодня") || lowercased.contains("today") || lowercased.contains("tonight") {
            dayOffset = 0
        } else if lowercased.contains("завтра") || lowercased.contains("tomorrow") {
            dayOffset = 1
        }

        var hour = 10
        var minute = 0
        if let match = lowercased.range(of: #"\bat\s?(\d{1,2})(?::(\d{2}))?\s?(am|pm)?"#, options: .regularExpression) ?? lowercased.range(of: #"в\s?(\d{1,2})(?::|\.)?(\d{2})?"#, options: .regularExpression) {
            let matched = lowercased[match]
            let digits = matched.filter { $0.isNumber || $0 == ":" || $0 == "." }
            let parts = digits.split(whereSeparator: { $0 == ":" || $0 == "." })
            if let first = parts.first, let value = Int(first), value >= 0, value < 24 {
                hour = value
                if parts.count > 1, let minuteValue = Int(parts[1]), minuteValue < 60 {
                    minute = minuteValue
                }
                if matched.hasSuffix("pm") && hour < 12 {
                    hour += 12
                } else if matched.hasSuffix("am") && hour == 12 {
                    hour = 0
                }
            }
        }

        let startOfDay = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) ?? now
        var start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        if start < now {
            start = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        }

        return AgentEvent(title: self.eventTitle(prompt: prompt), startDate: start.timeIntervalSince1970, durationMinutes: 60, reminderMinutes: 15, calendarTitle: "Personal")
    }

    /// "remind me about the meeting with Sasha tomorrow at 10" → "Meeting with Sasha".
    static func eventTitle(prompt: String) -> String {
        let lowercased = prompt.lowercased()
        var subject: Substring?
        for marker in [" about ", " of ", " to ", " о ", " об ", " про "] {
            if let range = lowercased.range(of: marker) {
                subject = prompt[range.upperBound...]
                break
            }
        }
        guard var text = subject.map(String.init) else {
            return "Reminder"
        }
        for stop in [" tomorrow", " today", " tonight", " at ", " on ", " завтра", " сегодня", " послезавтра", " в ", ",", "."] {
            if let range = text.lowercased().range(of: stop) {
                text = String(text[..<range.lowerBound])
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        for article in ["the ", "a ", "an ", "my ", "our "] where text.lowercased().hasPrefix(article) {
            text = String(text.dropFirst(article.count))
            break
        }
        guard !text.isEmpty else {
            return "Reminder"
        }
        // "встрече с Сашей" → "Встреча с Сашей".
        let replacements: [(String, String)] = [("встрече", "встреча"), ("звонке", "звонок"), ("созвоне", "созвон"), ("тренировке", "тренировка"), ("дне рождения", "день рождения")]
        for (from, to) in replacements where text.lowercased().hasPrefix(from) {
            text = to + text.dropFirst(from.count)
            break
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func formatEventDate(_ timestamp: Double, now: Date) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "today at \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US")
        dayFormatter.dateFormat = "MMMM d"
        return "\(dayFormatter.string(from: date)) at \(time)"
    }

    // MARK: - Search

    private static func searchScript(prompt: String) -> AgentScript {
        let lowercased = prompt.lowercased()
        let isTickets = ["билет", "рейс", "перелёт", "перелет", "flight", "ticket", "airfare", "авиа"].contains(where: { lowercased.contains($0) })
        if isTickets {
            return self.ticketsScript(prompt: prompt)
        }
        let query = prompt.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        return AgentScript(
            items: [
                .think(AgentScriptThink(id: "think-1", seconds: 2.0, text: "Looking for “\(query)”. I'll check a few sources and see where they agree.")),
                .tool(AgentScriptTool(
                    id: "search",
                    icon: .search,
                    title: "Searching the web",
                    doneTitle: "Found 6 sources",
                    detail: query,
                    doneDetail: query,
                    statusText: "searching the web",
                    input: AgentSnippet(language: "text", text: query),
                    output: AgentSnippet(language: "text", text: "6 results"),
                    seconds: 3.0
                )),
                .tool(AgentScriptTool(
                    id: "read",
                    icon: .globe,
                    title: "Reading sources",
                    doneTitle: "Read 3 sources",
                    statusText: "reading sources",
                    seconds: 3.2
                ))
            ],
            answer: "I found six sources for “\(query)”. In demo mode I only show how the work goes; a real agent would give you a short summary with links right here."
        )
    }

    private static func ticketsScript(prompt: String) -> AgentScript {
        let destination = self.destination(prompt: prompt) ?? "Istanbul"
        let query = "cheap flights to \(destination)"
        return AgentScript(
            items: [
                .think(AgentScriptThink(id: "think-1", seconds: 2.6, text: "Cheap flights to \(destination). I'll compare aggregators with the airlines' own sites and factor in bags and layovers. The cheapest fare isn't always the best deal.")),
                .plan(AgentScriptPlan(id: "plan", items: ["Find sources", "Collect prices", "Compare options"])),
                .tool(AgentScriptTool(
                    id: "search",
                    icon: .search,
                    title: "Searching the web",
                    doneTitle: "Found 8 sources",
                    detail: query,
                    doneDetail: query,
                    statusText: "searching the web",
                    input: AgentSnippet(language: "text", text: query),
                    output: AgentSnippet(language: "text", text: "kayak.com\nskyscanner.com\ngoogle.com/travel/flights\nexpedia.com\nmomondo.com\nflypgs.com\nturkishairlines.com\najet.com"),
                    seconds: 2.8,
                    completesPlanItem: 0
                )),
                .tool(AgentScriptTool(
                    id: "open-kayak",
                    icon: .globe,
                    title: "Opening kayak.com",
                    doneTitle: "Collected prices from kayak.com",
                    detail: "Flights to \(destination)",
                    doneDetail: "24 flights",
                    statusText: "opening kayak.com",
                    seconds: 3.0
                )),
                .tool(AgentScriptTool(
                    id: "open-skyscanner",
                    icon: .globe,
                    title: "Opening skyscanner.com",
                    doneTitle: "Collected prices from skyscanner.com",
                    detail: "Flights to \(destination)",
                    doneDetail: "17 flights",
                    statusText: "opening skyscanner.com",
                    seconds: 2.6,
                    completesPlanItem: 1,
                    failure: AgentScriptToolFailure(seconds: 2.0, failedTitle: "skyscanner.com didn't respond", failedDetail: "The request timed out", retryTitle: "Retrying")
                )),
                .tool(AgentScriptTool(
                    id: "compare",
                    icon: .list,
                    title: "Comparing prices",
                    doneTitle: "Compared 41 options",
                    statusText: "comparing prices",
                    output: AgentSnippet(language: "text", text: "Pegasus      $96    nonstop   no checked bag\nAJet        $104    1 stop\nTurkish     $158    nonstop   23 kg bag"),
                    seconds: 2.4,
                    completesPlanItem: 2
                ))
            ],
            answer: "Here are the three best options to \(destination):\n\n**Pegasus — $96**, nonstop, 3 h 55 min, no checked bag\n**AJet — $104**, one 1 h 10 min layover\n**Turkish Airlines — $158**, nonstop, 23 kg bag\n\nTuesday is the cheapest day to fly. Want me to ping you when prices drop?"
        )
    }

    private static func destination(prompt: String) -> String? {
        let lowercased = prompt.lowercased()
        for marker in [" to ", " в ", " во ", " до "] {
            if let range = lowercased.range(of: marker, options: .backwards) {
                let tail = prompt[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
                if !tail.isEmpty && tail.count <= 24 && !tail.contains(" ") {
                    return tail.prefix(1).uppercased() + tail.dropFirst()
                }
            }
        }
        return nil
    }

    // MARK: - Conversation

    private static func greetingScript(prompt: String) -> AgentScript {
        let lowercased = prompt.lowercased()
        let asksHowAreYou = lowercased.contains("how are you") || lowercased.contains("как ты") || lowercased.contains("как дела")
        let opening: String
        if lowercased.contains("салам") || lowercased.contains("ассалам") || lowercased.contains("salam") {
            opening = "Wa alaykum assalam!"
        } else if lowercased.contains("hello") {
            opening = "Hello!"
        } else if lowercased.contains("hey") {
            opening = "Hey!"
        } else {
            opening = "Hi!"
        }
        let middle = asksHowAreYou ? " All good, and ready to work." : " Good to see you."
        return AgentScript(
            items: [
                .think(AgentScriptThink(id: "think-1", seconds: 1.3, text: "A hello. I'll keep it warm and short and suggest where to start."))
            ],
            answer: opening + middle + " I can build a game or a mini app, look things up online or set a reminder. Where should we start?"
        )
    }

    private static func capabilitiesScript() -> AgentScript {
        return AgentScript(
            items: [
                .think(AgentScriptThink(id: "think-1", seconds: 1.8, text: "I'll say briefly what I can do and give a couple of easy examples to start with."))
            ],
            answer: "I don't just answer, I get things done:\n\n**Build** mini apps, games and websites that open right in Telegram\n**Search** the web and compare options\n**Manage** your calendar: meetings and reminders\n\nTry “Make a game” or “Remind me about the meeting tomorrow at 10”."
        )
    }

    private static func genericScript(prompt: String) -> AgentScript {
        return AgentScript(
            items: [
                .think(AgentScriptThink(id: "think-1", seconds: 2.4, text: "Let me work out what exactly is needed and answer to the point."))
            ],
            answer: "Got it. In demo mode I can **build** mini apps and games, **search** the web and **work with your calendar**. Try, for example, “Make a game” or “Find cheap flights to Istanbul”."
        )
    }
}

#endif
