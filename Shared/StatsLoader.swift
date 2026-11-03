import Foundation

/// Which file the data came from.
enum StatsSource: String, Sendable {
    /// ~/.claude/usage-widget.json: written by tools/update_usage.py from the session transcripts.
    case usageWidget = "usage-widget.json"
    /// ~/.claude/stats-cache.json: written by Claude Code only when /stats is opened.
    case statsCache = "stats-cache.json"
}

enum StatsLoader {
    /// How often WidgetKit is asked for a new timeline.
    static let refreshInterval: TimeInterval = 10 * 60
    /// usage-widget.json wins as long as it is not older than stats-cache.json by more than this.
    /// Without a margin, opening /stats between two updater runs would make the numbers jump:
    /// stats-cache freezes the days it already computed and does not match day by day what is
    /// in the transcripts today.
    static let fallbackTolerance: TimeInterval = 30 * 60

    /// The user's REAL home folder. Inside the sandbox NSHomeDirectory() returns the container
    /// (~/Library/Containers/<id>/Data), so it is read from the user database instead.
    static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static func url(_ source: StatsSource, home: URL = realHomeDirectory()) -> URL {
        home.appendingPathComponent(".claude/\(source.rawValue)")
    }

    static var statsURL: URL { url(.statsCache) }
    static var usageURL: URL { url(.usageWidget) }

    /// Reads usage-widget.json and falls back to stats-cache.json if it does not exist, cannot be
    /// read or is older than stats-cache.json. If the preferred file fails the other is tried; if
    /// both fail, the first error is thrown.
    static func load(home: URL = realHomeDirectory(), now: Date = Date(), calendar: Calendar = .current) throws -> StatsSummary {
        let usage = url(.usageWidget, home: home), stats = url(.statsCache, home: home)
        let order: [(StatsSource, URL)]
        if let usageModified = modified(usage), modified(stats).map({ usageModified.addingTimeInterval(fallbackTolerance) >= $0 }) ?? true {
            order = [(.usageWidget, usage), (.statsCache, stats)]
        } else {
            order = [(.statsCache, stats), (.usageWidget, usage)]
        }
        var firstError: Error?
        for (source, file) in order {
            do {
                let data = try Data(contentsOf: file)
                var s = try StatsSummary.parse(data: data, today: now, calendar: calendar)
                s.fileModified = modified(file)
                s.source = source
                s.sourcePath = file.path
                return s
            } catch {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? CocoaError(.fileNoSuchFile)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
