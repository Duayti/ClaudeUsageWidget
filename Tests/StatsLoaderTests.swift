import XCTest

/// File choice: ~/.claude/usage-widget.json (written by tools/update_usage.py)
/// and, if it is missing or stale, ~/.claude/stats-cache.json (written by Claude Code when /stats is opened).
final class StatsLoaderTests: XCTestCase {
    var home: URL!
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Guatemala")!
        return c
    }()
    let now = Date(timeIntervalSince1970: 1_793_750_400) // 2026-11-03 18:00 in Guatemala (UTC-6)

    /// Exact shape of the output of tools/update_usage.py (stats-cache.json schema).
    static let scriptOutput = """
    {"version":5,"lastComputedDate":"2026-11-03",
     "dailyActivity":[{"date":"2026-11-03","messageCount":12,"sessionCount":1,"toolCallCount":3}],
     "dailyModelTokens":[{"date":"2026-11-02","tokensByModel":{"claude-opus-5-5":1000}},
                         {"date":"2026-11-03","tokensByModel":{"claude-opus-5-5":700,"claude-sonnet-5-5":300}}],
     "dailyModelTokensVersion":5,
     "modelUsage":{"claude-opus-5-5":{"inputTokens":10,"outputTokens":90,"cacheReadInputTokens":1500,"cacheCreationInputTokens":100,
                                      "webSearchRequests":0,"costUSD":0,"contextWindow":0,"maxOutputTokens":0},
                   "claude-sonnet-5-5":{"inputTokens":1,"outputTokens":9,"cacheReadInputTokens":250,"cacheCreationInputTokens":40,
                                        "webSearchRequests":2,"costUSD":0,"contextWindow":0,"maxOutputTokens":0}},
     "totalSessions":3,"totalMessages":40,"hourCounts":{"8":2,"14":1},"firstSessionDate":"2026-11-02T14:00:00.000Z"}
    """
    static let oldStats = """
    {"version":5,"lastComputedDate":"2026-11-01",
     "dailyModelTokens":[{"date":"2026-11-01","tokensByModel":{"claude-opus-5-5":5}}],
     "modelUsage":{"claude-opus-5-5":{"inputTokens":5,"outputTokens":0,"cacheReadInputTokens":0,"cacheCreationInputTokens":0}},
     "totalSessions":1,"totalMessages":2}
    """

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("cs-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    func write(_ name: String, _ json: String, modified: Date) throws -> URL {
        let url = home.appendingPathComponent(".claude/\(name)")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func load() throws -> StatsSummary {
        try StatsLoader.load(home: home, now: now, calendar: calendar)
    }

    func testPrefersUsageWidgetAndShowsItsTime() throws {
        let time = now.addingTimeInterval(-120)
        try write("usage-widget.json", Self.scriptOutput, modified: time)
        try write("stats-cache.json", Self.oldStats, modified: now.addingTimeInterval(-86_400))
        let s = try load()
        XCTAssertEqual(s.source, .usageWidget)
        XCTAssertEqual(s.fileModified.map { Int($0.timeIntervalSince1970) }, Int(time.timeIntervalSince1970),
                       "the time shown is that of THAT file")
        XCTAssertEqual(s.totalTokens, 1700 + 300)
        XCTAssertEqual(s.todayTokens, 1000, "the file has today")
        XCTAssertEqual(s.days.last?.key, "2026-11-03")
        XCTAssertEqual(s.totalSessions, 3)
    }

    func testWithoutUsageWidgetFallsBackToStatsCache() throws {
        let time = now.addingTimeInterval(-3600)
        try write("stats-cache.json", Self.oldStats, modified: time)
        let s = try load()
        XCTAssertEqual(s.source, .statsCache)
        XCTAssertEqual(s.totalTokens, 5)
        XCTAssertEqual(s.fileModified.map { Int($0.timeIntervalSince1970) }, Int(time.timeIntervalSince1970))
    }

    func testUsageWidgetOlderThanStatsCacheFallsBackToStatsCache() throws {
        // The updater stopped running and /stats was opened afterwards.
        try write("usage-widget.json", Self.scriptOutput, modified: now.addingTimeInterval(-3 * 3600))
        try write("stats-cache.json", Self.oldStats, modified: now.addingTimeInterval(-600))
        XCTAssertEqual(try load().source, .statsCache)
    }

    func testSlightlyOlderUsageWidgetStillWinsSoNumbersDoNotJump() throws {
        // Opening /stats between two runs must not switch files (the days do not match exactly).
        try write("usage-widget.json", Self.scriptOutput, modified: now.addingTimeInterval(-9 * 60))
        try write("stats-cache.json", Self.oldStats, modified: now.addingTimeInterval(-60))
        XCTAssertEqual(try load().source, .usageWidget)
    }

    func testCorruptUsageWidgetFallsBackToStatsCache() throws {
        try write("usage-widget.json", "{half written", modified: now)
        try write("stats-cache.json", Self.oldStats, modified: now.addingTimeInterval(-86_400))
        XCTAssertEqual(try load().source, .statsCache)
    }

    func testBrokenStatsCacheUsesUsageWidgetEvenIfOld() throws {
        try write("usage-widget.json", Self.scriptOutput, modified: now.addingTimeInterval(-86_400))
        try write("stats-cache.json", "roto", modified: now)
        XCTAssertEqual(try load().source, .usageWidget)
    }

    func testNoFilesThrows() {
        XCTAssertThrowsError(try load())
    }

    func testRefreshesEveryTenMinutes() {
        XCTAssertEqual(StatsLoader.refreshInterval, 10 * 60)
    }

    /// The widget sandbox must allow reading EXACTLY these two files.
    func testEntitlementsAllowOnlyTheTwoFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Widget/Widget.entitlements"] {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true, path)
            let paths = plist["com.apple.security.temporary-exception.files.home-relative-path.read-only"] as? [String]
            XCTAssertEqual(paths.map(Set.init), Set(["/.claude/stats-cache.json", "/.claude/usage-widget.json"]), path)
            XCTAssertEqual(paths?.count, 2, path)
            XCTAssertEqual(Set(plist.keys), ["com.apple.security.app-sandbox",
                                             "com.apple.security.temporary-exception.files.home-relative-path.read-only"],
                           "\(path): no extra permissions")
        }
    }
}
