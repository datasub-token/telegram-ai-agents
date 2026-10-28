import Foundation

/// Durations, counts and sizes as the agent's path shows them ("1 мин 12 с", "8 шагов", "27 КБ").
public enum AgentFormatting {
    /// "4 с", "1 мин 12 с", "2 мин", "1 ч 5 мин"; in English "4s", "1m 12s".
    public static func duration(_ seconds: Double, isRussian: Bool) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if isRussian {
            if hours > 0 {
                return minutes > 0 ? "\(hours) ч \(minutes) мин" : "\(hours) ч"
            } else if minutes > 0 {
                return secs > 0 ? "\(minutes) мин \(secs) с" : "\(minutes) мин"
            } else {
                return "\(secs) с"
            }
        } else {
            if hours > 0 {
                return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
            } else if minutes > 0 {
                return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m"
            } else {
                return "\(secs)s"
            }
        }
    }

    /// The running counter of an active step: "0:07", "1:12".
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Picks the Russian plural form for `n`: one (1, 21), few (2–4, 22–24), many (5–20, 11–14, 25…).
    public static func russianPlural(_ n: Int, one: String, few: String, many: String) -> String {
        let n = abs(n)
        let mod100 = n % 100
        let mod10 = n % 10
        if mod100 >= 11 && mod100 <= 14 {
            return many
        } else if mod10 == 1 {
            return one
        } else if mod10 >= 2 && mod10 <= 4 {
            return few
        } else {
            return many
        }
    }

    public static func steps(_ n: Int, isRussian: Bool) -> String {
        if isRussian {
            return "\(n) \(self.russianPlural(n, one: "шаг", few: "шага", many: "шагов"))"
        } else {
            return n == 1 ? "1 step" : "\(n) steps"
        }
    }

    public static func files(_ n: Int, isRussian: Bool) -> String {
        if isRussian {
            return "\(n) \(self.russianPlural(n, one: "файл", few: "файла", many: "файлов"))"
        } else {
            return n == 1 ? "1 file" : "\(n) files"
        }
    }

    public static func lines(_ n: Int, isRussian: Bool) -> String {
        if isRussian {
            return "\(n) \(self.russianPlural(n, one: "строка", few: "строки", many: "строк"))"
        } else {
            return n == 1 ? "1 line" : "\(n) lines"
        }
    }

    public static func sources(_ n: Int, isRussian: Bool) -> String {
        if isRussian {
            return "\(n) \(self.russianPlural(n, one: "источник", few: "источника", many: "источников"))"
        } else {
            return n == 1 ? "1 source" : "\(n) sources"
        }
    }

    public static func options(_ n: Int, isRussian: Bool) -> String {
        if isRussian {
            return "\(n) \(self.russianPlural(n, one: "вариант", few: "варианта", many: "вариантов"))"
        } else {
            return n == 1 ? "1 option" : "\(n) options"
        }
    }

    /// "820 Б", "27 КБ", "1,2 МБ".
    public static func bytes(_ n: Int, isRussian: Bool) -> String {
        let value = Double(max(0, n))
        if value < 1024.0 {
            return isRussian ? "\(Int(value)) Б" : "\(Int(value)) B"
        } else if value < 1024.0 * 1024.0 {
            let kb = Int((value / 1024.0).rounded())
            return isRussian ? "\(max(1, kb)) КБ" : "\(max(1, kb)) KB"
        } else {
            let mb = value / (1024.0 * 1024.0)
            var string = String(format: "%.1f", mb)
            if isRussian {
                string = string.replacingOccurrences(of: ".", with: ",")
                return "\(string) МБ"
            } else {
                return "\(string) MB"
            }
        }
    }

    /// "Думал 4 с" / "Thought for 4s".
    public static func thought(seconds: Double, isRussian: Bool) -> String {
        let duration = self.duration(max(1.0, seconds), isRussian: isRussian)
        return isRussian ? "Думал \(duration)" : "Thought for \(duration)"
    }

    /// The one line a finished path collapses into.
    public static func summary(run: AgentRun, now: Double, isRussian: Bool) -> String {
        let duration = self.duration(max(1.0, run.elapsed(at: now)), isRussian: isRussian)
        let steps = self.steps(run.countedStepCount, isRussian: isRussian)
        switch run.status {
        case .stopped:
            return isRussian ? "Остановлено через \(duration) · \(steps)" : "Stopped after \(duration) · \(steps)"
        case .interrupted:
            return isRussian ? "Прервано · \(steps)" : "Interrupted · \(steps)"
        case .running, .waitingForPermission, .answering, .finished:
            return isRussian ? "Работал \(duration) · \(steps)" : "Worked for \(duration) · \(steps)"
        }
    }
}

/// A span of formatting in an answer.
public struct AgentTextSpan: Equatable {
    public enum Kind: Equatable {
        case bold
        case code
    }

    /// UTF-16 range in the plain text.
    public var range: NSRange
    public var kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// The answers are written with `**bold**` and `` `code` ``; this turns them into plain text and spans.
public enum AgentMarkdown {
    public static func parse(_ source: String) -> (text: String, spans: [AgentTextSpan]) {
        var text = ""
        var spans: [AgentTextSpan] = []
        var boldStart: Int?
        var codeStart: Int?
        let characters = Array(source)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*", index + 1 < characters.count, characters[index + 1] == "*", codeStart == nil {
                let hasClosing: Bool
                if boldStart != nil {
                    hasClosing = true
                } else {
                    hasClosing = self.find("**", in: characters, from: index + 2) != nil
                }
                if hasClosing {
                    let location = (text as NSString).length
                    if let start = boldStart {
                        if location > start {
                            spans.append(AgentTextSpan(range: NSRange(location: start, length: location - start), kind: .bold))
                        }
                        boldStart = nil
                    } else {
                        boldStart = location
                    }
                    index += 2
                    continue
                }
            } else if character == "`" {
                let hasClosing = codeStart != nil || self.find("`", in: characters, from: index + 1) != nil
                if hasClosing {
                    let location = (text as NSString).length
                    if let start = codeStart {
                        if location > start {
                            spans.append(AgentTextSpan(range: NSRange(location: start, length: location - start), kind: .code))
                        }
                        codeStart = nil
                    } else {
                        codeStart = location
                    }
                    index += 1
                    continue
                }
            }
            text.append(character)
            index += 1
        }
        return (text, spans)
    }

    private static func find(_ marker: String, in characters: [Character], from start: Int) -> Int? {
        let markerCharacters = Array(marker)
        guard start < characters.count else {
            return nil
        }
        var index = start
        while index + markerCharacters.count <= characters.count {
            if Array(characters[index ..< index + markerCharacters.count]) == markerCharacters {
                return index
            }
            index += 1
        }
        return nil
    }
}
