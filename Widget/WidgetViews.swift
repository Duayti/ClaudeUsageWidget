import SwiftUI
import WidgetKit

private func modelColor(_ name: String) -> Color { .model(name) }

struct StatsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatsEntry

    var body: some View {
        // Click on the widget: opens the app window, with the chosen model if there is one.
        switch entry.state {
        case .error(let message):
            ErrorView(message: message)
                .widgetURL(PanelLink.url(model: nil))
        case .ok(let s):
            Group {
                switch family {
                case .systemSmall: SmallView(s: s)
                case .systemMedium: MediumView(s: s)
                default: LargeView(s: s)
                }
            }
            .widgetURL(PanelLink.url(model: s.selectedModel))
        }
    }
}

// MARK: - Common pieces

private struct Title: View {
    var model: String?
    var body: some View {
        Label(model.map { String(localized: "Claude · \($0)") } ?? String(localized: "Claude Usage"), systemImage: "sparkle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }
}

private struct UpdatedText: View {
    let s: StatsSummary
    var body: some View {
        Group {
            if let f = s.fileModified {
                Text("Updated \(StatsFormat.dateTime(f))")
            } else if let f = s.lastComputed {
                Text("Data as of \(StatsFormat.shortDate(f))")
            } else {
                Text("No update date")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// "Today" if the file already has today; otherwise the latest day with data (stats-cache.json is
/// written when a day closes, so it is normal for today to be missing).
private struct DayFigure {
    let label: String
    let value: Int

    init(_ s: StatsSummary) {
        if let today = s.todayTokens {
            label = String(localized: "Today"); value = today
        } else if let d = s.latestDay {
            label = String(localized: "Latest day · \(StatsFormat.shortDate(d.date))"); value = d.total
        } else {
            label = String(localized: "Today"); value = 0
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// Lays the children out in lines, wrapping to the next one when they do not fit (compact legend).
private struct FlowLayout: Layout {
    var hSpacing: CGFloat = 7
    var vSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = place(in: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? r.width, height: r.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = place(in: bounds.width, subviews: subviews)
        for (i, f) in r.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                              proposal: ProposedViewSize(f.size))
        }
    }

    private func place(in width: CGFloat, subviews: Subviews) -> (frames: [CGRect], width: CGFloat, height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let t = v.sizeThatFits(.unspecified)
            if x > 0 && x + t.width > width { x = 0; y += lineHeight + vSpacing; lineHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: t))
            x += t.width + hSpacing
            lineHeight = max(lineHeight, t.height)
            maxX = max(maxX, x - hSpacing)
        }
        return (frames, maxX, y + lineHeight)
    }
}

private struct Legend: View {
    let series: [String]
    var size: CGFloat = 9
    var body: some View {
        FlowLayout {
            ForEach(series, id: \.self) { n in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(modelColor(n)).frame(width: 6, height: 6)
                    Text(n).font(.system(size: size)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
            }
        }
    }
}

/// Day chart: with a chosen model, a single color; with "all", every model present.
private struct UsageChart: View {
    let s: StatsSummary
    let days: [DayTokens]
    var spacing: CGFloat = 3

    var body: some View {
        let g = ModelStack.all(days)
        VStack(alignment: .leading, spacing: 4) {
            ChartBlock(days: g.days, series: g.series, spacing: spacing)
            if s.selectedModel == nil { Legend(series: g.series) }
        }
    }
}

// MARK: - Stacked bars

private struct StackedBars: View {
    let days: [DayTokens]
    let series: [String]        // bottom to top
    var spacing: CGFloat = 3

    var body: some View {
        let maximum = max(days.map(\.total).max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(days, id: \.key) { d in
                    bar(d, maxTotal: maximum, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }

    @ViewBuilder
    private func bar(_ d: DayTokens, maxTotal: Int, height: CGFloat) -> some View {
        if d.total == 0 {
            // Day with no usage: a minimal mark so the axis reads correctly.
            Rectangle().fill(.quaternary).frame(height: 1).frame(maxWidth: .infinity)
        } else {
            let barHeight = max(2, height * CGFloat(d.total) / CGFloat(maxTotal))
            let segments = series.reversed().filter { (d.byModel[$0] ?? 0) > 0 }
            VStack(spacing: segments.count > 1 ? 1 : 0) {
                ForEach(segments, id: \.self) { m in
                    modelColor(m).frame(height: max(1, barHeight * CGFloat(d.byModel[m] ?? 0) / CGFloat(d.total)))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: barHeight, alignment: .bottom)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5))
        }
    }
}

private struct ChartBlock: View {
    let days: [DayTokens]
    let series: [String]
    var spacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            StackedBars(days: days, series: series, spacing: spacing)
            HStack {
                if let a = days.first { Text(StatsFormat.shortDate(a.date)) }
                Spacer()
                if let b = days.last { Text(StatsFormat.shortDate(b.date)) }
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Sizes

struct SmallView: View {
    let s: StatsSummary
    var body: some View {
        let day = DayFigure(s)
        VStack(alignment: .leading, spacing: 0) {
            Title(model: s.selectedModel)
            Spacer(minLength: 4)
            Text(StatsFormat.tokens(s.totalTokens))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(s.firstSession.map { String(localized: "tokens since \(StatsFormat.shortDate($0))") } ?? String(localized: "tokens in total"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Stat(label: day.label, value: StatsFormat.tokens(day.value))
            Spacer(minLength: 4)
            UpdatedText(s: s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct MediumView: View {
    let s: StatsSummary
    var body: some View {
        let days = s.lastDays(14)
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Title(model: s.selectedModel)
                Stat(label: String(localized: "Total"), value: StatsFormat.tokens(s.totalTokens))
                Stat(label: String(localized: "Last 7 days"), value: StatsFormat.tokens(s.last7Days))
                Spacer(minLength: 0)
                UpdatedText(s: s)
            }
            .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text("14 days").font(.caption2).foregroundStyle(.secondary)
                UsageChart(s: s, days: days)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct LargeView: View {
    let s: StatsSummary
    var body: some View {
        let day = DayFigure(s)
        let days = s.lastDays(30)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Title(model: s.selectedModel)
                Spacer()
                UpdatedText(s: s)
            }
            HStack(alignment: .top) {
                Stat(label: String(localized: "Total"), value: StatsFormat.tokens(s.totalTokens))
                Spacer()
                Stat(label: String(localized: "Last 7 days"), value: StatsFormat.tokens(s.last7Days))
                Spacer()
                Stat(label: day.label, value: StatsFormat.tokens(day.value))
            }
            UsageChart(s: s, days: days, spacing: 2)
                .frame(maxHeight: .infinity)
            if let m = s.selectedModel {
                ModelDetail(name: m, usage: s.models.first)
            } else {
                ModelTable(rows: ModelStack.tableRows(s.models, days: days, maxRows: 8))
                Divider()
                HStack {
                    Text("\(StatsFormat.integer(s.totalSessions)) sessions")
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(StatsFormat.integer(s.totalMessages)) messages")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Input / output / cache of a single model.
private struct ModelDetail: View {
    let name: String
    let usage: ModelUsage?
    var body: some View {
        HStack(alignment: .top) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(modelColor(name)).frame(width: 7, height: 7)
                Text(name).font(.caption.weight(.semibold))
            }
            Spacer()
            Stat(label: String(localized: "Input"), value: StatsFormat.tokens(usage?.input ?? 0))
            Spacer()
            Stat(label: String(localized: "Output"), value: StatsFormat.tokens(usage?.output ?? 0))
            Spacer()
            Stat(label: String(localized: "Cache"), value: StatsFormat.tokens(usage?.cache ?? 0))
        }
    }
}

private struct ModelTable: View {
    let rows: [ModelUsage]
    var body: some View {
        // 10 pt (smallest legible size) and little space between rows so ~11 models fit.
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 1) {
            GridRow {
                Text("Model").gridColumnAlignment(.leading)
                Text("Input")
                Text("Output")
                Text("Cache")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            ForEach(rows, id: \.name) { r in
                GridRow {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(modelColor(r.name)).frame(width: 7, height: 7)
                        Text(r.name)
                    }
                    Text(StatsFormat.tokens(r.input))
                    Text(StatsFormat.tokens(r.output))
                    Text(StatsFormat.tokens(r.cache))
                }
                .font(.system(size: 10))
                .monospacedDigit()
                .lineLimit(1)
            }
        }
    }
}

private struct ErrorView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Title()
            Label("Could not read the usage data", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview(as: .systemLarge) {
    UsageWidget()
} timeline: {
    StatsEntry(date: Date(), state: .ok(.sample))
}
