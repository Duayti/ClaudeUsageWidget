import Foundation
import WidgetKit

/// Window state: loaded data, range, model and the updater.
@MainActor
final class PanelStore: ObservableObject {
    @Published var summary: StatsSummary?
    @Published var loadError: String?
    @Published var range: UsageRange = .week
    @Published var model: String?
    @Published private(set) var updating = false
    /// Last updater error (nil if the last run succeeded).
    @Published var updateError: String?

    private let load: () throws -> StatsSummary
    private let runUpdater: () async -> Result<String, UpdaterError>

    init(load: @escaping () throws -> StatsSummary = { try StatsLoader.load() },
         runUpdater: @escaping () async -> Result<String, UpdaterError> = { await Updater.run() }) {
        self.load = load
        self.runUpdater = runUpdater
        reload()
    }

    /// Models for the picker: those in modelUsage (largest first) and those that only appear per day.
    var models: [String] {
        guard let s = summary else { return [] }
        var names = s.models.map(\.name)
        for m in ModelStack.all(s.allDays).series where !names.contains(m) { names.append(m) }
        return names
    }

    var report: UsageReport? {
        summary.map { UsageReport.make($0, range: range, model: model, today: Date()) }
    }

    /// There is no data in the file (or it could not be read).
    var hasNoData: Bool {
        guard let s = summary else { return true }
        return s.models.isEmpty && !s.allDays.contains { $0.total > 0 }
    }

    func reload() {
        do {
            summary = try load()
            loadError = nil
        } catch {
            summary = nil
            loadError = error.localizedDescription
        }
        if let m = model, !models.contains(m) { model = nil }
    }

    /// What the widget link asks for. A model that is no longer in the file falls back to "All".
    func apply(_ request: PanelLink.Request) {
        model = request.model.flatMap { models.contains($0) ? $0 : nil }
    }

    /// Click on a table row: filters; clicking the same row again goes back to "All".
    func toggle(model m: String) {
        model = model == m ? nil : m
    }

    /// Runs the updater without blocking the UI, reloads and asks the widgets to redraw.
    func refresh() {
        guard !updating else { return }
        updating = true
        Task {
            let r = await runUpdater()
            switch r {
            case .success: updateError = nil
            case .failure(let e): updateError = e.message
            }
            reload()
            WidgetCenter.shared.reloadAllTimelines()
            updating = false
        }
    }
}
