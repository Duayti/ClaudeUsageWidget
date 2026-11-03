import Foundation

// MARK: - Raw JSON shape (everything optional: the file belongs to Claude Code and may change)

private struct RawStats: Decodable {
    var version: Int?
    var lastComputedDate: String?
    var dailyModelTokens: [RawDay]?
    var dailyActivity: [RawActivity]?
    /// Only in usage-widget.json (tools/update_usage.py): token type per day and model.
    var dailyModelUsage: [RawDayUsage]?
    var modelUsage: [String: RawUsage]?
    var totalSessions: Int?
    var totalMessages: Int?
    var firstSessionDate: String?
}

private struct RawDay: Decodable {
    var date: String
    var tokensByModel: [String: Int]?
}

private struct RawActivity: Decodable {
    var date: String
    var messageCount: Int?
    var sessionCount: Int?
}

private struct RawDayUsage: Decodable {
    var date: String
    var usageByModel: [String: RawUsage]?
}

private struct RawUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadInputTokens: Int?
    var cacheCreationInputTokens: Int?
}

// MARK: - Summary ready to draw

/// Accumulated usage of ONE exact model (display name: "Opus 5.5").
struct ModelUsage: Sendable, Equatable {
    var name: String
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Cache read + cache write (the widget shows them together).
    var cache: Int { cacheRead + cacheWrite }
    var total: Int { input + output + cache }

    init(name: String, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.name = name
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    fileprivate mutating func add(_ u: RawUsage) {
        input += u.inputTokens ?? 0
        output += u.outputTokens ?? 0
        cacheRead += u.cacheReadInputTokens ?? 0
        cacheWrite += u.cacheCreationInputTokens ?? 0
    }

    mutating func add(_ u: ModelUsage) {
        input += u.input
        output += u.output
        cacheRead += u.cacheRead
        cacheWrite += u.cacheWrite
    }
}

/// Activity of one day (dailyActivity): messages and started sessions.
struct DayActivity: Sendable, Equatable {
    var messages = 0
    var sessions = 0
}

struct DayTokens: Sendable, Equatable {
    var key: String          // "YYYY-MM-DD"
    var date: Date
    var byModel: [String: Int]      // display name -> tokens
    var total: Int { byModel.values.reduce(0, +) }

    func only(_ model: String) -> DayTokens {
        let t = byModel[model] ?? 0
        return DayTokens(key: key, date: date, byModel: t > 0 ? [model: t] : [:])
    }
}

struct StatsSummary: Sendable {
    static let windowDays = 30

    var version = 0
    var totalTokens = 0
    var totalSessions = 0
    var totalMessages = 0
    var models: [ModelUsage] = []
    /// Every day with data (ascending), to recompute "today" and "latest day" when filtering.
    var allDays: [DayTokens] = []
    var todayKey = ""
    /// Last 30 calendar days, ending at `lastComputedDate` (or today), with zeros where there was no usage.
    var days: [DayTokens] = []
    var todayTokens: Int?
    var latestDay: DayTokens?
    var last7Days = 0
    var lastComputed: Date?
    var firstSession: Date?
    /// Modification date of the file the data came from (set by the loader).
    var fileModified: Date?
    /// File chosen by the loader (usage-widget.json or stats-cache.json).
    var source: StatsSource?
    var sourcePath: String?
    /// Model chosen in the widget (nil = all).
    var selectedModel: String?
    /// "YYYY-MM-DD" -> activity. nil if the file has no dailyActivity.
    var activity: [String: DayActivity]?
    /// "YYYY-MM-DD" -> display name -> usage by type. nil if the file lacks it (stats-cache.json).
    var dailyUsage: [String: [String: ModelUsage]]?

    func lastDays(_ n: Int) -> [DayTokens] { Array(days.suffix(n)) }

    static func parse(data: Data, today: Date, calendar: Calendar = .current) throws -> StatsSummary {
        let raw = try JSONDecoder().decode(RawStats.self, from: data)
        var s = StatsSummary()
        s.version = raw.version ?? 0
        s.totalSessions = raw.totalSessions ?? 0
        s.totalMessages = raw.totalMessages ?? 0

        // Totals and breakdown per exact model from modelUsage (two ids with the same display name are summed).
        var perModel: [String: ModelUsage] = [:]
        for (id, u) in raw.modelUsage ?? [:] {
            let name = ModelName.display(id)
            var acc = perModel[name] ?? ModelUsage(name: name)
            acc.add(u)
            perModel[name] = acc
        }
        s.models = perModel.values
            .filter { $0.total > 0 }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        s.totalTokens = s.models.reduce(0) { $0 + $1.total }

        // Tokens per day and model.
        var byDay: [String: [String: Int]] = [:]
        for d in raw.dailyModelTokens ?? [] {
            var models = byDay[d.date] ?? [:]
            for (id, t) in d.tokensByModel ?? [:] {
                models[ModelName.display(id), default: 0] += t
            }
            byDay[d.date] = models
        }

        if let act = raw.dailyActivity {
            var activityByDay: [String: DayActivity] = [:]
            for a in act {
                activityByDay[a.date, default: DayActivity()].messages += a.messageCount ?? 0
                activityByDay[a.date, default: DayActivity()].sessions += a.sessionCount ?? 0
            }
            s.activity = activityByDay
        }
        if let usages = raw.dailyModelUsage {
            var breakdown: [String: [String: ModelUsage]] = [:]
            for d in usages {
                for (id, u) in d.usageByModel ?? [:] {
                    let name = ModelName.display(id)
                    breakdown[d.date, default: [:]][name, default: ModelUsage(name: name)].add(u)
                }
            }
            s.dailyUsage = breakdown
        }

        let todayKeyValue = DayKey.string(today, calendar: calendar)
        s.todayKey = todayKeyValue
        s.lastComputed = raw.lastComputedDate.flatMap { DayKey.date($0, calendar: calendar) }
        s.firstSession = raw.firstSessionDate.flatMap(parseISO)
        s.allDays = byDay.keys.sorted().compactMap { k in
            DayKey.date(k, calendar: calendar).map { DayTokens(key: k, date: $0, byModel: byDay[k]!) }
        }
        if let todayModels = byDay[todayKeyValue] { s.todayTokens = todayModels.values.reduce(0, +) }
        s.latestDay = s.allDays.last { $0.total > 0 }

        // Window anchored at the last computed day: the file is written when the day closes,
        // so anchoring at "today" would always leave the last bar empty.
        let anchor = calendar.startOfDay(for: s.lastComputed ?? today)
        s.days = (0..<windowDays).reversed().compactMap { daysBack in
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: anchor) else { return nil }
            let k = DayKey.string(day, calendar: calendar)
            return DayTokens(key: k, date: day, byModel: byDay[k] ?? [:])
        }
        s.last7Days = s.lastDays(7).reduce(0) { $0 + $1.total }
        return s
    }

    /// Only one model (nil = all). Recomputes total, window, "today", "latest day" and last 7 days.
    func filtered(model: String?) -> StatsSummary {
        guard let model else { return self }
        var s = self
        s.models = models.filter { $0.name == model }
        s.totalTokens = s.models.reduce(0) { $0 + $1.total }
        s.days = days.map { $0.only(model) }
        s.allDays = allDays.map { $0.only(model) }
        s.todayTokens = allDays.contains { $0.key == todayKey } ? s.allDays.first { $0.key == todayKey }?.total : nil
        s.latestDay = s.allDays.last { $0.total > 0 }
        s.last7Days = s.lastDays(7).reduce(0) { $0 + $1.total }
        s.selectedModel = model
        return s
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Day keys "YYYY-MM-DD" in the time zone of the given calendar.
enum DayKey {
    static func string(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ s: String, calendar: Calendar) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}
