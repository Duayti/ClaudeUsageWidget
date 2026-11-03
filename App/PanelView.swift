import Charts
import SwiftUI

/// Main window: usage panel by range and model.
struct PanelView: View {
    @ObservedObject var store: PanelStore
    /// Day whose tooltip starts open (only used to render screenshots).
    var initialHover: String?

    var body: some View {
        VStack(spacing: 0) {
            if store.hasNoData {
                EmptyState(store: store)
            } else if let r = store.report {
                Header(store: store)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SummaryCards(report: r)
                        Card {
                            if r.range == .today {
                                TodayChart(report: r)
                            } else {
                                DailyChart(report: r, hovered: initialHover)
                            }
                        }
                        Card { ModelTable(report: r, selected: store.model, onSelect: store.toggle(model:)) }
                    }
                    .padding(20)
                }
            }
            Divider()
            Footer(store: store)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.05) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.07), lineWidth: 1)
            )
    }
}

private struct Header: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        HStack(spacing: 16) {
            Picker("Range", selection: $store.range) {
                ForEach(UsageRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            Spacer()

            Picker("Model", selection: $store.model) {
                Text("All models").tag(String?.none)
                Divider()
                ForEach(store.models, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            .frame(width: 220)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct SummaryCards: View {
    let report: UsageReport

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Card {
                Metric(title: report.range.totalTitle, value: StatsFormat.tokens(report.total)) {
                    ChangeLine(report: report)
                }
            }
            Card {
                Metric(title: String(localized: "Average per day"), value: StatsFormat.tokens(report.averagePerDay)) {
                    Text("in \(report.days.count) days")
                }
            }
            Card {
                Metric(title: String(localized: "Peak day"), value: report.peakDay.map { StatsFormat.shortDate($0.date) } ?? "—") {
                    Text(report.peakDay.map { String(localized: "\(StatsFormat.tokens($0.total)) tokens") } ?? String(localized: "no usage"))
                }
            }
            if let sessions = report.sessions, let messages = report.messages {
                Card {
                    // The file does not split sessions or messages by model: with a filter the title says so.
                    Metric(title: report.model == nil ? String(localized: "Sessions") : String(localized: "Sessions · all models"),
                           value: StatsFormat.integer(sessions)) {
                        Text("\(StatsFormat.integer(messages)) messages")
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Metric<Detail: View>: View {
    let title: String
    let value: String
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            detail
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ChangeLine: View {
    let report: UsageReport

    var body: some View {
        if let label = report.range.comparisonLabel {
            if let c = report.change {
                HStack(spacing: 3) {
                    Image(systemName: c > 0 ? "arrow.up.right" : c < 0 ? "arrow.down.right" : "equal")
                        .imageScale(.small)
                    Text("\(StatsFormat.change(c)) \(label)")
                }
            } else {
                Text("No data to compare")
            }
        } else if let first = report.days.first {
            Text("since \(StatsFormat.shortDate(first.date))")
        }
    }
}

// MARK: - Charts

private struct ChartTitle: View {
    let title: String
    let series: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer(minLength: 16)
            if series.count > 1 { Legend(series: series) }
        }
    }
}

private struct Legend: View {
    let series: [String]

    var body: some View {
        FlowLayout(hSpacing: 12, vSpacing: 4) {
            ForEach(series, id: \.self) { n in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.model(n)).frame(width: 8, height: 8)
                    Text(n).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
        .frame(maxWidth: 520, alignment: .trailing)
    }
}

/// Stacked bars per day; the largest model at the bottom. Hover: highlights the day and shows its breakdown.
private struct DailyChart: View {
    let report: UsageReport
    @State private var hovered: String?

    init(report: UsageReport, hovered: String? = nil) {
        self.report = report
        _hovered = State(initialValue: hovered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChartTitle(title: String(localized: "Tokens per day"), series: report.series)
            if report.total == 0 {
                NoUsage().frame(height: 220)
            } else {
                chart.frame(height: 220)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(report.days, id: \.key) { d in
                ForEach(report.series.filter { (d.byModel[$0] ?? 0) > 0 }, id: \.self) { m in
                    BarMark(x: .value("Day", d.date, unit: .day),
                            y: .value("Tokens", Double(d.byModel[m] ?? 0)))
                        .foregroundStyle(by: .value("Model", m))
                        .opacity(hovered == nil || hovered == d.key ? 1 : 0.35)
                }
            }
        }
        .chartForegroundStyleScale(domain: report.series, range: report.series.map(Color.model))
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    Text(StatsFormat.axis(Int(v.as(Double.self) ?? 0))).monospacedDigit()
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { v in
                AxisValueLabel {
                    if let f = v.as(Date.self) { Text(StatsFormat.shortDate(f)) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            if let f: Date = proxy.value(atX: p.x - plot.minX) {
                                let k = DayKey.string(f, calendar: .current)
                                hovered = report.days.contains { $0.key == k } ? k : nil
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
                if let k = hovered, let d = report.days.first(where: { $0.key == k }),
                   let x = proxy.position(forX: d.date.addingTimeInterval(12 * 3600)) {
                    Tooltip(day: d, series: report.series)
                        .fixedSize()
                        .modifier(PlaceTooltip(anchorX: plot.minX + x, bounds: plot))
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Places the tooltip at the top, next to the day, without leaving the chart area.
private struct PlaceTooltip: ViewModifier {
    let anchorX: CGFloat
    let bounds: CGRect
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let margin: CGFloat = 12
        let fitsRight = anchorX + margin + size.width <= bounds.maxX
        let x = fitsRight ? anchorX + margin : max(bounds.minX, anchorX - margin - size.width)
        return content
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, n in size = n } })
            .offset(x: x, y: bounds.minY + 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct Tooltip: View {
    let day: DayTokens
    let series: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(StatsFormat.shortDate(day.date)).font(.caption.weight(.semibold))
                Spacer(minLength: 16)
                Text(StatsFormat.tokens(day.total)).font(.caption.weight(.semibold)).monospacedDigit()
            }
            if day.total == 0 {
                Text("No usage").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(series.filter { (day.byModel[$0] ?? 0) > 0 }, id: \.self) { m in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.model(m)).frame(width: 8, height: 8)
                        Text(m).foregroundStyle(.secondary)
                        Spacer(minLength: 16)
                        Text(StatsFormat.tokens(day.byModel[m] ?? 0)).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .frame(minWidth: 170)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// "Today": a single stacked bar says nothing; today is shown per model (one row each, no axis).
private struct TodayChart: View {
    let report: UsageReport

    var body: some View {
        let day = report.days.last
        let rows = report.series.map { ($0, day?.byModel[$0] ?? 0) }
        let maximum = max(rows.map(\.1).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 12) {
            Text("Today by model").font(.headline)
            if report.total == 0 {
                NoUsage().frame(height: 120)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    ForEach(rows, id: \.0) { m, t in
                        GridRow {
                            Text(m).foregroundStyle(.secondary).lineLimit(1)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.model(m))
                                    .frame(width: max(3, g.size.width * CGFloat(t) / CGFloat(maximum)))
                            }
                            .frame(height: 16)
                            Text(StatsFormat.tokens(t)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }
}

private struct NoUsage: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar").font(.title2).foregroundStyle(.tertiary)
            Text("No usage in this range").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Per-model table

private struct ModelTable: View {
    let report: UsageReport
    let selected: String?
    let onSelect: (String) -> Void

    private static let numberWidth: CGFloat = 92
    private static let shareWidth: CGFloat = 116

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("By model").font(.headline)
                Spacer()
                Text(selected == nil ? "Click a row to filter" : "Click again to show all")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Input").frame(width: Self.numberWidth, alignment: .trailing)
                    Text("Output").frame(width: Self.numberWidth, alignment: .trailing)
                    Text("Cache read").frame(width: Self.numberWidth, alignment: .trailing)
                    Text("Cache write").frame(width: Self.numberWidth, alignment: .trailing)
                    Text("Total").frame(width: Self.numberWidth, alignment: .trailing)
                    Text("Share").frame(width: Self.shareWidth, alignment: .trailing)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                Divider()
                if report.rows.isEmpty {
                    Text("No usage in this range").foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(report.rows) { r in
                    TableRow(row: r, selected: selected, numberWidth: Self.numberWidth, shareWidth: Self.shareWidth) { onSelect(r.name) }
                }
            }
            if !report.breakdownAvailable && !report.rows.isEmpty {
                Text("The file has no per-day breakdown: input, output and cache are only shown for “All time”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TableRow: View {
    let row: UsageReport.Row
    let selected: String?
    let numberWidth: CGFloat
    let shareWidth: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let isSelected = selected == row.name
        Button(action: action) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2.5).fill(Color.model(row.name)).frame(width: 10, height: 10)
                    Text(row.name).fontWeight(isSelected ? .semibold : .regular)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array([row.input, row.output, row.cacheRead, row.cacheWrite].enumerated()), id: \.offset) { _, v in
                    Text(v.map { StatsFormat.tokens($0) } ?? "—")
                        .foregroundStyle(v == nil ? .tertiary : .primary)
                        .frame(width: numberWidth, alignment: .trailing)
                }
                Text(StatsFormat.tokens(row.total)).fontWeight(.semibold).frame(width: numberWidth, alignment: .trailing)
                HStack(spacing: 8) {
                    ShareBar(share: row.share, color: .model(row.name))
                    Text(StatsFormat.percent(row.share)).frame(width: 52, alignment: .trailing)
                }
                .frame(width: shareWidth, alignment: .trailing)
            }
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : hover ? Color.primary.opacity(0.05) : .clear)
            )
            .opacity(selected == nil || isSelected ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(isSelected ? String(localized: "Show all models") : String(localized: "Filter \(row.name)"))
    }
}

private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08))
            Capsule().fill(color).frame(width: max(2, 44 * share))
        }
        .frame(width: 44, height: 5)
    }
}

// MARK: - Footer and empty state

private struct Footer: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Group {
                    if let s = store.summary, let f = s.fileModified {
                        // With an error next to it, the file name gives way (it stays in the help tooltip).
                        Text("Updated \(StatsFormat.relative(f, now: ctx.date))")
                            + Text(store.updateError == nil ? " · \(s.source?.rawValue ?? "")" : "").foregroundColor(.secondary.opacity(0.7))
                    } else {
                        Text("No data file")
                    }
                }
                .help(store.summary.flatMap { s in s.fileModified.map { "\(s.sourcePath ?? "") — \(StatsFormat.dateTime($0))" } } ?? "")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let e = store.updateError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(e)
            }
            Spacer(minLength: 8)
            if store.updating {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.callout).foregroundStyle(.secondary)
            }
            Button("Update Now") { store.refresh() }
                .disabled(store.updating)
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

private struct EmptyState: View {
    @ObservedObject var store: PanelStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No data yet").font(.title2.weight(.semibold))
                .help(store.loadError ?? "")
            Text(store.updating
                 ? String(localized: "Computing usage from the Claude Code transcripts…")
                 : String(localized: "No usage found in ~/.claude/usage-widget.json or stats-cache.json.\nClick “Update Now” to compute it."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Lays the children out in lines (legend).
private struct FlowLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = place(in: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: min(proposal.width ?? r.width, r.width), height: r.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = place(in: bounds.width, subviews: subviews)
        // Right-aligned: each line is shifted to the right edge.
        for (i, f) in r.frames.enumerated() {
            let shift = bounds.width - r.lineWidths[r.lines[i]]
            subviews[i].place(at: CGPoint(x: bounds.minX + shift + f.minX, y: bounds.minY + f.minY),
                              proposal: ProposedViewSize(f.size))
        }
    }

    private func place(in width: CGFloat, subviews: Subviews) -> (frames: [CGRect], lines: [Int], lineWidths: [CGFloat], width: CGFloat, height: CGFloat) {
        var frames: [CGRect] = [], lines: [Int] = [], lineWidths: [CGFloat] = [0]
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for v in subviews {
            let t = v.sizeThatFits(.unspecified)
            if x > 0 && x + t.width > width { x = 0; y += lineHeight + vSpacing; lineHeight = 0; lineWidths.append(0) }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: t))
            lines.append(lineWidths.count - 1)
            lineWidths[lineWidths.count - 1] = x + t.width
            x += t.width + hSpacing
            lineHeight = max(lineHeight, t.height)
        }
        return (frames, lines, lineWidths, lineWidths.max() ?? 0, y + lineHeight)
    }
}
