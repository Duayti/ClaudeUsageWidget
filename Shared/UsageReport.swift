import Foundation

/// Range of the panel window. It always ends TODAY (the app recomputes usage-widget.json when it opens).
enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .week: String(localized: "7 days")
        case .month: String(localized: "30 days")
        case .all: String(localized: "All time")
        }
    }

    /// Title of the "Total" card.
    var totalTitle: String {
        switch self {
        case .today: String(localized: "Total · today")
        case .week: String(localized: "Total · 7 days")
        case .month: String(localized: "Total · 30 days")
        case .all: String(localized: "Total · all time")
        }
    }

    /// Calendar days of the range (nil = since the first day with data).
    var length: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }

    /// Text that accompanies the comparison with the previous range of the same length.
    var comparisonLabel: String? {
        switch self {
        case .today: String(localized: "vs. yesterday")
        case .week: String(localized: "vs. previous 7 days")
        case .month: String(localized: "vs. previous 30 days")
        case .all: nil
        }
    }
}

/// Everything the window draws for a range and a model (nil = all).
struct UsageReport: Sendable {
    /// Row of the per-model table. The per-type columns are nil if the file has no breakdown for the range.
    struct Row: Sendable, Equatable, Identifiable {
        var name: String
        var total: Int
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheWrite: Int?
        /// Fraction of the range total (all models), 0...1.
        var share: Double
        var id: String { name }
    }

    var range: UsageRange
    var model: String?
    /// Every calendar day of the range (zeros included), already filtered by model.
    var days: [DayTokens] = []
    /// Models with tokens in the range (filtered), largest first: stacking and legend order.
    var series: [String] = []
    var total = 0
    var averagePerDay = 0
    var peakDay: DayTokens?
    /// nil if the file has no dailyActivity. They do not depend on the model (the file does not split them).
    var sessions: Int?
    var messages: Int?
    /// Total of the previous range of the same length (nil for "All time").
    var previousTotal: Int?
    /// (current - previous) / previous; nil if there is no previous range or it was zero.
    var change: Double?
    /// Every model of the range, NOT filtered (clicking a row = filter), sorted by total.
    var rows: [Row] = []
    var breakdownAvailable = false

    var isEmpty: Bool { total == 0 && rows.isEmpty }

    static func make(_ s: StatsSummary, range: UsageRange, model: String?, today: Date, calendar: Calendar = .current) -> UsageReport {
        var r = UsageReport(range: range, model: model)
        let byKey = Dictionary(s.allDays.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let end = calendar.startOfDay(for: today)

        // Start: N days back, or the first day with data for "All time".
        let start: Date
        if let n = range.length {
            start = calendar.date(byAdding: .day, value: -(n - 1), to: end) ?? end
        } else {
            let first = s.allDays.first { $0.total > 0 }?.date
            start = min(first.map { calendar.startOfDay(for: $0) } ?? end, end)
        }

        func daysBetween(from a: Date, to b: Date) -> [DayTokens] {
            var out: [DayTokens] = []
            var f = a
            while f <= b {
                let k = DayKey.string(f, calendar: calendar)
                out.append(byKey[k] ?? DayTokens(key: k, date: f, byModel: [:]))
                guard let next = calendar.date(byAdding: .day, value: 1, to: f) else { break }
                f = next
            }
            return out
        }
        func applyModelFilter(_ d: DayTokens) -> DayTokens { model.map { d.only($0) } ?? d }

        let rangeDays = daysBetween(from: start, to: end)
        r.days = rangeDays.map(applyModelFilter)
        r.series = ModelStack.all(r.days).series
        r.peakDay = r.days.filter { $0.total > 0 }.max { a, b in a.total != b.total ? a.total < b.total : a.key > b.key }

        // Table: every model of the range.
        if range == .all, !s.models.isEmpty {
            r.breakdownAvailable = true
            let total = max(s.totalTokens, 1)
            r.rows = s.models.map {
                Row(name: $0.name, total: $0.total, input: $0.input, output: $0.output,
                    cacheRead: $0.cacheRead, cacheWrite: $0.cacheWrite, share: Double($0.total) / Double(total))
            }
        } else {
            var totals: [String: Int] = [:]
            for d in rangeDays { for (m, t) in d.byModel where t > 0 { totals[m, default: 0] += t } }
            let sum = max(totals.values.reduce(0, +), 1)
            var breakdown: [String: ModelUsage] = [:]
            if let usages = s.dailyUsage {
                r.breakdownAvailable = true
                for d in rangeDays { for (m, u) in usages[d.key] ?? [:] { breakdown[m, default: ModelUsage(name: m)].add(u) } }
            }
            r.rows = totals
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { m, t in
                    let u = r.breakdownAvailable ? (breakdown[m] ?? ModelUsage(name: m)) : nil
                    return Row(name: m, total: t, input: u?.input, output: u?.output,
                               cacheRead: u?.cacheRead, cacheWrite: u?.cacheWrite, share: Double(t) / Double(sum))
                }
        }

        // Total: for "All time" it comes from modelUsage (like the widget and /stats); otherwise from the days.
        if range == .all, !s.models.isEmpty {
            r.total = model.map { m in s.models.first { $0.name == m }?.total ?? 0 } ?? s.totalTokens
        } else {
            r.total = r.days.reduce(0) { $0 + $1.total }
        }
        r.averagePerDay = Int((Double(r.total) / Double(max(r.days.count, 1))).rounded())

        // Sessions and messages.
        if range == .all {
            if s.activity != nil || s.totalSessions > 0 || s.totalMessages > 0 {
                r.sessions = s.totalSessions
                r.messages = s.totalMessages
            }
        } else if let act = s.activity {
            let inRange = rangeDays.compactMap { act[$0.key] }
            r.sessions = inRange.reduce(0) { $0 + $1.sessions }
            r.messages = inRange.reduce(0) { $0 + $1.messages }
        }

        // Comparison with the previous range of the same length.
        if let n = range.length,
           let previousEnd = calendar.date(byAdding: .day, value: -1, to: start),
           let previousStart = calendar.date(byAdding: .day, value: -(n - 1), to: previousEnd) {
            let previous = daysBetween(from: previousStart, to: previousEnd).map(applyModelFilter).reduce(0) { $0 + $1.total }
            r.previousTotal = previous
            r.change = previous > 0 ? Double(r.total - previous) / Double(previous) : nil
        }
        return r
    }
}
