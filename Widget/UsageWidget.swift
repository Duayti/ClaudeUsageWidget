import WidgetKit
import SwiftUI
import AppIntents

enum StatsState {
    case ok(StatsSummary)
    case error(String)
}

struct StatsEntry: TimelineEntry {
    let date: Date
    let state: StatsState
}

struct StatsProvider: AppIntentTimelineProvider {
    static let refresh = StatsLoader.refreshInterval

    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: Date(), state: .ok(.sample))
    }

    func snapshot(for configuration: SelectModelIntent, in context: Context) async -> StatsEntry {
        // In the gallery we show real data if it can be read; otherwise the sample.
        let entry = load(configuration)
        if context.isPreview, case .error = entry.state {
            return StatsEntry(date: Date(), state: .ok(.sample))
        }
        return entry
    }

    func timeline(for configuration: SelectModelIntent, in context: Context) async -> Timeline<StatsEntry> {
        let entry = load(configuration)
        return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(Self.refresh)))
    }

    private func load(_ configuration: SelectModelIntent) -> StatsEntry {
        let now = Date()
        do {
            let s = try StatsLoader.load(now: now).filtered(model: configuration.model?.modelName)
            return StatsEntry(date: now, state: .ok(s))
        } catch {
            return StatsEntry(date: now, state: .error(error.localizedDescription))
        }
    }
}

@main
struct UsageWidget: Widget {
    let kind = "ClaudeUsageWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectModelIntent.self, provider: StatsProvider()) { entry in
            StatsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude Usage")
        .description("Claude Code tokens by model, read from ~/.claude/usage-widget.json (or stats-cache.json). Edit the widget to choose a model.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

extension StatsSummary {
    /// Sample data for the gallery and the placeholder.
    static var sample: StatsSummary {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var s = StatsSummary()
        s.totalTokens = 157_341_523_952
        s.totalSessions = 1060
        s.totalMessages = 826_195
        s.models = [
            ModelUsage(name: "Opus 5.5", input: 600_000, output: 120_000_000, cacheRead: 80_000_000_000),
            ModelUsage(name: "Sonnet 5.5", input: 500_000, output: 70_000_000, cacheRead: 50_000_000_000),
            ModelUsage(name: "Opus 5", input: 300_000, output: 40_000_000, cacheRead: 10_000_000_000),
            ModelUsage(name: "Sonnet 5", input: 200_000, output: 20_000_000, cacheRead: 10_000_000_000),
            ModelUsage(name: "Fable 5.1", input: 50_000, output: 8_000_000, cacheRead: 5_000_000_000),
            ModelUsage(name: "Haiku 5.5", input: 10_000, output: 1_000_000, cacheRead: 900_000_000),
        ]
        s.days = (0..<StatsSummary.windowDays).reversed().map { daysBack in
            let f = cal.date(byAdding: .day, value: -daysBack, to: today)!
            let base = 600_000_000 + (daysBack * 97_000_000) % 1_400_000_000
            return DayTokens(key: DayKey.string(f, calendar: cal), date: f,
                             byModel: ["Opus 5.5": base, "Sonnet 5.5": base / 2, "Opus 5": base / 4,
                                       "Sonnet 5": base / 6, "Fable 5.1": base / 9, "Haiku 5.5": base / 30])
        }
        s.latestDay = s.days.last
        s.todayTokens = s.days.last?.total
        s.last7Days = s.lastDays(7).reduce(0) { $0 + $1.total }
        s.lastComputed = today
        s.firstSession = cal.date(byAdding: .month, value: -8, to: today)
        return s
    }
}
