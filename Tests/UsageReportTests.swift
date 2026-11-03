import XCTest

/// Window logic: ranges, comparison with the previous range, model filter and table.
final class UsageReportTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Guatemala")!
        return c
    }()

    func date(_ s: String, hour: Int = 10) -> Date {
        let p = s.split(separator: "-").map { Int($0)! }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour))!
    }

    /// Today = Nov 3. Data: Oct 1 to Nov 3 with gaps; activity and per-type breakdown on the recent days.
    static let json = """
    {"version": 5, "lastComputedDate": "2026-11-03",
     "dailyActivity": [
       {"date": "2026-10-27", "messageCount": 5, "sessionCount": 1, "toolCallCount": 0},
       {"date": "2026-11-02", "messageCount": 7, "sessionCount": 2, "toolCallCount": 0},
       {"date": "2026-11-03", "messageCount": 11, "sessionCount": 3, "toolCallCount": 0}
     ],
     "dailyModelTokens": [
       {"date": "2026-10-01", "tokensByModel": {"claude-opus-5": 1000}},
       {"date": "2026-10-20", "tokensByModel": {"claude-opus-5-5": 300}},
       {"date": "2026-10-27", "tokensByModel": {"claude-opus-5-5": 100, "claude-sonnet-5-5": 100}},
       {"date": "2026-11-02", "tokensByModel": {"claude-opus-5-5": 50}},
       {"date": "2026-11-03", "tokensByModel": {"claude-opus-5-5": 200, "claude-sonnet-5-5": 40}}
     ],
     "dailyModelUsage": [
       {"date": "2026-10-27", "usageByModel": {
          "claude-opus-5-5": {"inputTokens": 1, "outputTokens": 9, "cacheReadInputTokens": 80, "cacheCreationInputTokens": 10},
          "claude-sonnet-5-5": {"inputTokens": 0, "outputTokens": 10, "cacheReadInputTokens": 90, "cacheCreationInputTokens": 0}}},
       {"date": "2026-11-02", "usageByModel": {
          "claude-opus-5-5": {"inputTokens": 0, "outputTokens": 5, "cacheReadInputTokens": 40, "cacheCreationInputTokens": 5}}},
       {"date": "2026-11-03", "usageByModel": {
          "claude-opus-5-5": {"inputTokens": 2, "outputTokens": 18, "cacheReadInputTokens": 160, "cacheCreationInputTokens": 20},
          "claude-sonnet-5-5": {"inputTokens": 1, "outputTokens": 3, "cacheReadInputTokens": 30, "cacheCreationInputTokens": 6}}}
     ],
     "modelUsage": {
       "claude-opus-5": {"inputTokens": 100, "outputTokens": 100, "cacheReadInputTokens": 700, "cacheCreationInputTokens": 100},
       "claude-opus-5-5": {"inputTokens": 3, "outputTokens": 32, "cacheReadInputTokens": 580, "cacheCreationInputTokens": 35},
       "claude-sonnet-5-5": {"inputTokens": 1, "outputTokens": 13, "cacheReadInputTokens": 120, "cacheCreationInputTokens": 6}
     },
     "totalSessions": 9, "totalMessages": 40}
    """

    func summary(_ text: String = UsageReportTests.json) throws -> StatsSummary {
        try StatsSummary.parse(data: Data(text.utf8), today: date("2026-11-03"), calendar: cal)
    }

    func report(_ r: UsageRange, model: String? = nil, _ s: StatsSummary? = nil) throws -> UsageReport {
        UsageReport.make(try s ?? summary(), range: r, model: model, today: date("2026-11-03", hour: 15), calendar: cal)
    }

    // MARK: - Parser: new fields

    func testParserSeparatesCacheReadAndWrite() throws {
        let s = try summary()
        let opus = try XCTUnwrap(s.models.first { $0.name == "Opus 5" })
        XCTAssertEqual(opus.cacheRead, 700)
        XCTAssertEqual(opus.cacheWrite, 100)
        XCTAssertEqual(opus.cache, 800, "cache = read + write (used by the widget)")
        XCTAssertEqual(opus.total, 1000)
    }

    func testParserReadsActivityAndPerDayBreakdown() throws {
        let s = try summary()
        XCTAssertEqual(s.activity?["2026-11-03"], DayActivity(messages: 11, sessions: 3))
        XCTAssertEqual(s.dailyUsage?["2026-11-03"]?["Sonnet 5.5"],
                       ModelUsage(name: "Sonnet 5.5", input: 1, output: 3, cacheRead: 30, cacheWrite: 6))

        let withoutExtras = try summary(#"{"dailyModelTokens": [{"date": "2026-11-03", "tokensByModel": {"claude-opus-5-5": 1}}]}"#)
        XCTAssertNil(withoutExtras.activity, "old stats-cache without dailyActivity: nothing is made up")
        XCTAssertNil(withoutExtras.dailyUsage, "stats-cache.json has no per-day breakdown")
    }

    // MARK: - Ranges

    func testRanges() {
        XCTAssertEqual(UsageRange.allCases.map(\.title), ["Today", "7 days", "30 days", "All time"])
        XCTAssertEqual(UsageRange.allCases.map(\.length), [1, 7, 30, nil])
    }

    func testToday() throws {
        let r = try report(.today)
        XCTAssertEqual(r.days.map(\.key), ["2026-11-03"])
        XCTAssertEqual(r.total, 240)
        XCTAssertEqual(r.averagePerDay, 240)
        XCTAssertEqual(r.peakDay?.key, "2026-11-03")
        XCTAssertEqual(r.sessions, 3)
        XCTAssertEqual(r.messages, 11)
        XCTAssertEqual(r.previousTotal, 50, "yesterday")
        XCTAssertEqual(try XCTUnwrap(r.change), 3.8, accuracy: 1e-9, "+380 %")
    }

    func testSevenDaysWithZerosAndComparison() throws {
        let r = try report(.week)
        XCTAssertEqual(r.days.count, 7)
        XCTAssertEqual(r.days.first?.key, "2026-10-28")
        XCTAssertEqual(r.days.last?.key, "2026-11-03")
        XCTAssertEqual(r.days.first { $0.key == "2026-10-30" }?.total, 0, "days without usage count as zero")
        XCTAssertEqual(r.total, 290)
        XCTAssertEqual(r.averagePerDay, 41, "290 / 7, rounded")
        XCTAssertEqual(r.peakDay?.key, "2026-11-03")
        XCTAssertEqual(r.sessions, 5)
        XCTAssertEqual(r.messages, 18)
        XCTAssertEqual(r.previousTotal, 200, "Oct 21 to 27: only the 27th; Oct 20 is outside")
        XCTAssertEqual(try XCTUnwrap(r.change), 0.45, accuracy: 1e-9)
    }

    func testThirtyDays() throws {
        let r = try report(.month)
        XCTAssertEqual(r.days.count, 30)
        XCTAssertEqual(r.days.first?.key, "2026-10-05")
        XCTAssertEqual(r.total, 300 + 200 + 50 + 240)
        XCTAssertEqual(r.previousTotal, 1000, "Sep 5 to Oct 4: Oct 1")
        XCTAssertEqual(try XCTUnwrap(r.change), -0.21, accuracy: 1e-9)
        XCTAssertEqual(r.peakDay?.key, "2026-10-20")
    }

    func testAllTimeUsesModelUsageAndDoesNotCompare() throws {
        let r = try report(.all)
        XCTAssertEqual(r.days.first?.key, "2026-10-01", "since the first day with data")
        XCTAssertEqual(r.days.last?.key, "2026-11-03")
        XCTAssertEqual(r.days.count, 34)
        XCTAssertEqual(r.total, 1000 + 650 + 140, "sum of modelUsage, like the widget")
        XCTAssertEqual(r.averagePerDay, 53, "1790 / 34 = 52.6, rounded")
        XCTAssertNil(r.previousTotal)
        XCTAssertNil(r.change)
        XCTAssertEqual(r.sessions, 9)
        XCTAssertEqual(r.messages, 40)
        XCTAssertEqual(r.peakDay?.key, "2026-10-01")
    }

    func testNoPreviousRangeWithDataMeansNoComparison() throws {
        let r = try report(.today, try summary(#"{"dailyModelTokens": [{"date": "2026-11-03", "tokensByModel": {"claude-opus-5-5": 9}}]}"#))
        XCTAssertEqual(r.previousTotal, 0)
        XCTAssertNil(r.change, "no division by zero")
        XCTAssertNil(r.sessions, "without dailyActivity there are no sessions for the range")
        XCTAssertNil(r.messages)
    }

    func testNoData() throws {
        let r = try report(.week, try summary("{}"))
        XCTAssertEqual(r.total, 0)
        XCTAssertNil(r.peakDay)
        XCTAssertTrue(r.rows.isEmpty)
        XCTAssertTrue(r.isEmpty)
        XCTAssertTrue(try report(.all, try summary("{}")).isEmpty)
        XCTAssertFalse(try report(.week).isEmpty)
    }

    // MARK: - Model filter

    func testModelFilter() throws {
        let r = try report(.week, model: "Sonnet 5.5")
        XCTAssertEqual(r.model, "Sonnet 5.5")
        XCTAssertEqual(r.total, 40)
        XCTAssertEqual(r.previousTotal, 100)
        XCTAssertEqual(try XCTUnwrap(r.change), -0.6, accuracy: 1e-9)
        XCTAssertEqual(r.series, ["Sonnet 5.5"])
        XCTAssertTrue(r.days.allSatisfy { Set($0.byModel.keys).isSubset(of: ["Sonnet 5.5"]) })
        XCTAssertEqual(r.rows.map(\.name), ["Opus 5.5", "Sonnet 5.5"], "the table still shows every model so you can switch")

        let allTime = try report(.all, model: "Opus 5")
        XCTAssertEqual(allTime.total, 1000)
        XCTAssertEqual(allTime.peakDay?.key, "2026-10-01")
    }

    // MARK: - Per-model table

    func testTableWithBreakdownPerRange() throws {
        let r = try report(.week)
        XCTAssertTrue(r.breakdownAvailable)
        XCTAssertEqual(r.rows.map(\.name), ["Opus 5.5", "Sonnet 5.5"], "sorted by total, every present model")
        let opus = r.rows[0]
        XCTAssertEqual(opus.total, 250)
        XCTAssertEqual(opus.input, 2)
        XCTAssertEqual(opus.output, 23)
        XCTAssertEqual(opus.cacheRead, 200)
        XCTAssertEqual(opus.cacheWrite, 25)
        XCTAssertEqual(opus.share, 250.0 / 290.0, accuracy: 1e-9)
        XCTAssertEqual(r.rows.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(r.series, ["Opus 5.5", "Sonnet 5.5"], "stacking order: the largest at the bottom")
    }

    func testAllTimeTableComesFromModelUsage() throws {
        let r = try report(.all)
        XCTAssertTrue(r.breakdownAvailable)
        XCTAssertEqual(r.rows.map(\.name), ["Opus 5", "Opus 5.5", "Sonnet 5.5"])
        XCTAssertEqual(r.rows[0].cacheRead, 700)
        XCTAssertEqual(r.rows[0].cacheWrite, 100)
        XCTAssertEqual(r.rows[0].share, 1000.0 / 1790.0, accuracy: 1e-9)
    }

    func testWithoutPerDayBreakdownTheTypeColumnsStayEmpty() throws {
        let s = try summary(#"""
        {"dailyModelTokens": [{"date": "2026-11-03", "tokensByModel": {"claude-opus-5-5": 9, "claude-haiku-4-5-20251001": 1}}],
         "modelUsage": {"claude-opus-5-5": {"inputTokens": 9}}}
        """#)
        let r = try report(.today, s)
        XCTAssertFalse(r.breakdownAvailable)
        XCTAssertEqual(r.rows.map(\.name), ["Opus 5.5", "Haiku 4.5"])
        XCTAssertEqual(r.rows[0].total, 9)
        XCTAssertNil(r.rows[0].input, "the breakdown is not made up")
        XCTAssertNil(r.rows[0].cacheRead)
        XCTAssertTrue(try report(.all, s).breakdownAvailable)
    }

    // MARK: - Formatting

    private let english = Locale(identifier: "en_US")
    private let spanish = Locale(identifier: "es_ES")
    /// es_ES puts a no-break space before the percent sign.
    private let nbsp = "\u{00A0}"

    func testPercentAndAxisFormattingEnglish() {
        XCTAssertEqual(StatsFormat.change(0.123, locale: english), "+12%")
        XCTAssertEqual(StatsFormat.change(-0.08, locale: english), "−8%")
        XCTAssertEqual(StatsFormat.change(0.004, locale: english), "+0.4%")
        XCTAssertEqual(StatsFormat.change(0, locale: english), "0%")
        XCTAssertEqual(StatsFormat.change(3.8, locale: english), "+380%")
        XCTAssertEqual(StatsFormat.percent(0.4567, locale: english), "45.7%")
        XCTAssertEqual(StatsFormat.percent(1, locale: english), "100%")
        XCTAssertEqual(StatsFormat.percent(0.21, locale: english), "21.0%", "same format across the whole column")
        XCTAssertEqual(StatsFormat.percent(0, locale: english), "0%")
        XCTAssertEqual(StatsFormat.percent(0.0004, locale: english), "<0.1%")
        XCTAssertEqual(StatsFormat.axis(1_500_000_000, locale: english), "1.5 B")
        XCTAssertEqual(StatsFormat.axis(500_000_000, locale: english), "500 M")
        XCTAssertEqual(StatsFormat.axis(2_000_000_000, locale: english), "2 B")
        XCTAssertEqual(StatsFormat.axis(0, locale: english), "0")
    }

    func testPercentAndAxisFormattingSpanish() {
        XCTAssertEqual(StatsFormat.change(0.123, locale: spanish), "+12\(nbsp)%")
        XCTAssertEqual(StatsFormat.change(0.004, locale: spanish), "+0,4\(nbsp)%")
        XCTAssertEqual(StatsFormat.percent(0.4567, locale: spanish), "45,7\(nbsp)%")
        XCTAssertEqual(StatsFormat.percent(0.0004, locale: spanish), "<0,1\(nbsp)%")
        XCTAssertEqual(StatsFormat.axis(1_500_000_000, locale: spanish), "1,5 B")
        XCTAssertEqual(StatsFormat.axis(2_000_000_000, locale: spanish), "2 B")
    }

    func testRangeLabels() {
        // Without the string catalog (as in this test bundle) the English source strings are used.
        XCTAssertEqual(UsageRange.today.comparisonLabel, "vs. yesterday")
        XCTAssertEqual(UsageRange.week.comparisonLabel, "vs. previous 7 days")
        XCTAssertEqual(UsageRange.month.comparisonLabel, "vs. previous 30 days")
        XCTAssertNil(UsageRange.all.comparisonLabel)
        XCTAssertEqual(UsageRange.allCases.map(\.totalTitle), ["Total · today", "Total · 7 days", "Total · 30 days", "Total · all time"])
    }

    func testTimeAgo() {
        let now = date("2026-11-03", hour: 15)
        XCTAssertEqual(StatsFormat.relative(now.addingTimeInterval(-20), now: now, locale: english), "just now")
        XCTAssertEqual(StatsFormat.relative(now.addingTimeInterval(30), now: now, locale: english), "just now", "clock ahead")
        // Wording and abbreviations come from the system formatter (they differ slightly between macOS versions),
        // so check the number and the unit rather than the exact string.
        func check(_ seconds: TimeInterval, _ locale: Locale, number: String, unit: String, file: StaticString = #filePath, line: UInt = #line) {
            let text = StatsFormat.relative(now.addingTimeInterval(-seconds), now: now, locale: locale)
            XCTAssertTrue(text.contains(number) && text.lowercased().contains(unit), "\(text) should contain \(number) and \(unit)", file: file, line: line)
        }
        check(5 * 60 + 10, english, number: "5", unit: "min")
        check(3600, english, number: "1", unit: "hr")
        check(5 * 3600, english, number: "5", unit: "hr")
        check(86_400, english, number: "1", unit: "day")
        check(3 * 86_400, english, number: "3", unit: "day")
        check(5 * 60 + 10, spanish, number: "5", unit: "min")
        check(5 * 3600, spanish, number: "5", unit: "h")
        check(3 * 86_400, spanish, number: "3", unit: "d")
    }

    // MARK: - Widget link

    func testWidgetLink() throws {
        XCTAssertEqual(PanelLink.url(model: nil).absoluteString, "claudeusage://panel")
        XCTAssertEqual(PanelLink.url(model: "Opus 5.5").absoluteString, "claudeusage://panel?model=Opus%205.5")
        XCTAssertEqual(PanelLink.request(from: PanelLink.url(model: "Opus 5.5")), PanelLink.Request(model: "Opus 5.5"))
        XCTAssertEqual(PanelLink.request(from: PanelLink.url(model: nil)), PanelLink.Request(model: nil))
        XCTAssertEqual(PanelLink.request(from: URL(string: "claudeusage://panel?model=")!), PanelLink.Request(model: nil))
        XCTAssertEqual(PanelLink.request(from: URL(string: "CLAUDEUSAGE://panel")!), PanelLink.Request(model: nil))
        XCTAssertNil(PanelLink.request(from: URL(string: "https://panel?model=x")!))
        XCTAssertNil(PanelLink.request(from: URL(string: "claudeusage://otra")!))
    }
}
