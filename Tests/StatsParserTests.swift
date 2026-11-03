import XCTest

final class StatsParserTests: XCTestCase {
    // Sample JSON shaped like ~/.claude/stats-cache.json (version 5).
    static let sample = """
    {
      "version": 5,
      "lastComputedDate": "2026-11-01",
      "dailyActivity": [
        {"date": "2026-10-30", "messageCount": 769, "sessionCount": 6, "toolCallCount": 461}
      ],
      "dailyModelTokens": [
        {"date": "2026-10-20", "tokensByModel": {"claude-opus-4-7": 1000}},
        {"date": "2026-10-26", "tokensByModel": {"claude-opus-5-5": 100, "claude-sonnet-5-5": 50}},
        {"date": "2026-10-30", "tokensByModel": {"claude-opus-5-5": 116157836, "claude-sonnet-5-5": 6657187, "claude-fable-5-1": 10, "claude-haiku-4-5-20251001": 5}}
      ],
      "dailyModelTokensVersion": 5,
      "modelUsage": {
        "claude-opus-5-5": {"inputTokens": 100, "outputTokens": 200, "cacheReadInputTokens": 157000000000, "cacheCreationInputTokens": 341523652, "webSearchRequests": 0, "costUSD": 0},
        "claude-opus-4-7": {"inputTokens": 1, "outputTokens": 2, "cacheReadInputTokens": 3, "cacheCreationInputTokens": 4},
        "claude-sonnet-5-5": {"inputTokens": 10, "outputTokens": 20, "cacheReadInputTokens": 30, "cacheCreationInputTokens": 40},
        "claude-fable-5": {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0},
        "odd-model": {"inputTokens": 5}
      },
      "totalSessions": 1060,
      "totalMessages": 826195,
      "longestSession": {"sessionId": "x", "duration": 5014336793, "messageCount": 1270},
      "firstSessionDate": "2026-03-02T01:17:56.485Z",
      "hourCounts": {"0": 14, "13": 99}
    }
    """

    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Guatemala")!
        return c
    }()

    func date(_ s: String) -> Date {
        let p = s.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 10))!
    }

    func summary(today: String = "2026-11-02") throws -> StatsSummary {
        try StatsSummary.parse(data: Data(Self.sample.utf8), today: date(today), calendar: calendar)
    }

    func testReadableModelName() {
        XCTAssertEqual(ModelName.display("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelName.display("claude-opus-5"), "Opus 5")
        XCTAssertEqual(ModelName.display("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelName.display("claude-sonnet-5-5"), "Sonnet 5.5")
        XCTAssertEqual(ModelName.display("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelName.display("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ModelName.display("claude-haiku-5-5"), "Haiku 5.5")
        XCTAssertEqual(ModelName.display("claude-haiku-4-5-20251001"), "Haiku 4.5", "ignores the date suffix")
        XCTAssertEqual(ModelName.display("Claude-OPUS-4-7"), "Opus 4.7")
        XCTAssertEqual(ModelName.display("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(ModelName.display("odd-model"), "Odd Model")
    }

    func testModelPaletteIsStableAndByFamily() {
        func rgb(_ n: String) -> (r: Int, g: Int, b: Int) {
            let h = ModelPalette.hex(n)
            return (Int((h >> 16) & 0xFF), Int((h >> 8) & 0xFF), Int(h & 0xFF))
        }
        XCTAssertEqual(ModelPalette.hex("Opus 5.5"), ModelPalette.hex("Opus 5.5"))
        let opus = ["Opus 4.7", "Opus 4.8", "Opus 5", "Opus 5.5"].map(ModelPalette.hex)
        XCTAssertEqual(Set(opus).count, 4, "every Opus version has its own shade")
        let sonnet = ["Sonnet 4.6", "Sonnet 5", "Sonnet 5.5"].map(ModelPalette.hex)
        XCTAssertEqual(Set(sonnet).count, 3)
        XCTAssertEqual(Set(["Fable 5", "Fable 5.1"].map(ModelPalette.hex)).count, 2)
        XCTAssertEqual(Set(["Haiku 4.5", "Haiku 5.5"].map(ModelPalette.hex)).count, 2)
        for n in ["Opus 4.7", "Opus 5.5"] { XCTAssertGreaterThan(rgb(n).b, rgb(n).r, "\(n) is blue") }
        for n in ["Sonnet 5", "Sonnet 5.5"] { XCTAssertGreaterThan(rgb(n).r, rgb(n).b, "\(n) is orange") }
        for n in ["Fable 5", "Fable 5.1"] { XCTAssertGreaterThan(rgb(n).g, rgb(n).r, "\(n) is green") }
        for n in ["Haiku 4.5", "Haiku 5.5"] { XCTAssertGreaterThan(rgb(n).r, rgb(n).b, "\(n) is yellow") }
    }

    func testTotalsSinceTheStart() throws {
        let r = try summary()
        // Sum of input + output + cache of every model.
        XCTAssertEqual(r.totalTokens, 157_341_523_952 + 10 + 100 + 5)
        XCTAssertEqual(r.totalSessions, 1060)
        XCTAssertEqual(r.totalMessages, 826_195)
        XCTAssertEqual(r.version, 5)
    }

    func testBreakdownPerExactModelWithoutGroupingByFamily() throws {
        let r = try summary()
        let opus55 = try XCTUnwrap(r.models.first { $0.name == "Opus 5.5" })
        XCTAssertEqual(opus55.input, 100)
        XCTAssertEqual(opus55.output, 200)
        XCTAssertEqual(opus55.cache, 157_000_000_000 + 341_523_652)
        XCTAssertEqual(r.models.first?.name, "Opus 5.5", "sorted from largest to smallest")
        XCTAssertEqual(r.models.first { $0.name == "Opus 4.7" }?.total, 10, "Opus 4.7 is separate from Opus 5.5")
        XCTAssertNil(r.models.first { $0.name == "Fable 5" }, "models with zero usage are not shown")
        XCTAssertEqual(r.models.first { $0.name == "Odd Model" }?.input, 5)
        XCTAssertEqual(r.models.map(\.name), ["Opus 5.5", "Sonnet 5.5", "Opus 4.7", "Odd Model"],
                       "picker list: each model by tokens (\"All\" is added separately)")
    }

    func testModelFilter() throws {
        let r = try summary(today: "2026-10-30")
        let f = r.filtered(model: "Opus 5.5")
        XCTAssertEqual(f.totalTokens, 157_341_523_952)
        XCTAssertEqual(f.models.map(\.name), ["Opus 5.5"])
        XCTAssertEqual(f.todayTokens, 116_157_836)
        XCTAssertEqual(f.last7Days, 100 + 116_157_836)
        XCTAssertEqual(f.days.count, 30)
        XCTAssertTrue(f.days.allSatisfy { Set($0.byModel.keys).isSubset(of: ["Opus 5.5"]) })
        XCTAssertEqual(f.days.first { $0.key == "2026-10-30" }?.total, 116_157_836)
        XCTAssertEqual(f.days.first { $0.key == "2026-10-20" }?.total, 0, "only Opus 4.7 was used that day")
        XCTAssertEqual(f.latestDay?.key, "2026-10-30")

        let old = r.filtered(model: "Opus 4.7")
        XCTAssertEqual(old.totalTokens, 10)
        XCTAssertEqual(old.latestDay?.key, "2026-10-20", "latest day with data FOR THAT model")
        XCTAssertEqual(old.last7Days, 0)
        XCTAssertEqual(old.todayTokens, 0)

        XCTAssertEqual(r.filtered(model: nil).totalTokens, r.totalTokens, "no model = all")
        XCTAssertEqual(r.filtered(model: "Opus 9").totalTokens, 0, "model that is no longer in the file")
    }

    func testEveryPresentModelSortedByTokens() throws {
        let json = """
        {"lastComputedDate": "2026-11-01",
         "dailyModelTokens": [
          {"date": "2026-11-01", "tokensByModel": {"claude-opus-5-5": 700, "claude-opus-5": 600, "claude-sonnet-5-5": 500,
            "claude-sonnet-5": 400, "claude-fable-5-1": 300, "claude-haiku-5-5": 20, "claude-haiku-4-5-20251001": 10}},
          {"date": "2026-10-31", "tokensByModel": {"claude-haiku-5-5": 5, "claude-opus-4-7": 0}}
         ]}
        """
        let r = try StatsSummary.parse(data: Data(json.utf8), today: date("2026-11-02"), calendar: calendar)
        let g = ModelStack.all(r.lastDays(14))
        XCTAssertEqual(g.series, ["Opus 5.5", "Opus 5", "Sonnet 5.5", "Sonnet 5", "Fable 5.1", "Haiku 5.5", "Haiku 4.5"],
                       "every model with tokens, largest first, no \"Others\" bucket")
        let d = try XCTUnwrap(g.days.last)
        XCTAssertEqual(d.byModel["Haiku 5.5"], 20)
        XCTAssertEqual(d.byModel["Haiku 4.5"], 10)
        XCTAssertNil(d.byModel["Others"])
        XCTAssertEqual(d.total, 2530, "nothing is lost or duplicated")
        XCTAssertEqual(g.days.map(\.total), r.lastDays(14).map(\.total))

        // Same model = same color, and a model does not look like another of the same family.
        XCTAssertEqual(ModelPalette.hex("Opus 5.5"), ModelPalette.hex("Opus 5.5"))
        XCTAssertEqual(Set(g.series.map(ModelPalette.hex)).count, g.series.count, "a different color per model")
    }

    func testTableRowsHideModelsWithoutTokensOnlyWhenTheyDoNotFit() {
        let models = (1...11).map { ModelUsage(name: "Model \($0)", input: 1000 - $0) }
        let days = [DayTokens(key: "2026-11-01", date: Date(), byModel: ["Model 1": 5, "Model 2": 4])]
        XCTAssertEqual(ModelStack.tableRows(models, days: days, maxRows: 11).count, 11, "if they fit, all are shown")
        XCTAssertEqual(ModelStack.tableRows(models, days: days, maxRows: 8).map(\.name), ["Model 1", "Model 2"],
                       "if they do not fit, those with 0 tokens in the displayed range are hidden")
    }

    func testDayWindowAnchorsAtLastComputedDateAndFillsZeros() throws {
        let r = try summary()
        XCTAssertEqual(r.days.count, 30)
        XCTAssertEqual(r.days.last?.key, "2026-11-01")
        XCTAssertEqual(r.days.first?.key, "2026-10-03")
        let d30 = try XCTUnwrap(r.days.first { $0.key == "2026-10-30" })
        XCTAssertEqual(d30.byModel["Opus 5.5"], 116_157_836)
        XCTAssertEqual(d30.byModel["Sonnet 5.5"], 6_657_187)
        XCTAssertEqual(d30.byModel["Fable 5.1"], 10)
        XCTAssertEqual(d30.total, 116_157_836 + 6_657_187 + 15)
        XCTAssertEqual(r.days.first { $0.key == "2026-10-31" }?.total, 0)
        // Last 7 days = Oct 26 .. Nov 1.
        XCTAssertEqual(r.last7Days, 150 + d30.total)
        XCTAssertEqual(r.lastDays(14).count, 14)
        XCTAssertEqual(r.lastDays(14).first?.key, "2026-10-19")
    }

    func testTodayAndLatestDayWithData() throws {
        let withoutToday = try summary(today: "2026-11-02")
        XCTAssertNil(withoutToday.todayTokens)
        XCTAssertEqual(withoutToday.latestDay?.key, "2026-10-30")

        let withToday = try summary(today: "2026-10-30")
        XCTAssertEqual(withToday.todayTokens, 116_157_836 + 6_657_187 + 15)
    }

    private let english = Locale(identifier: "en_US")
    private let spanish = Locale(identifier: "es_ES")

    func testNumberFormattingFollowsTheLocale() {
        // English: decimal point, comma as the grouping separator.
        XCTAssertEqual(StatsFormat.tokens(157_341_523_952, locale: english), "157.3 B")
        XCTAssertEqual(StatsFormat.tokens(842_149_999, locale: english), "842.1 M", "truncated, not rounded")
        XCTAssertEqual(StatsFormat.tokens(12_300, locale: english), "12.3 K")
        XCTAssertEqual(StatsFormat.tokens(999_999_999, locale: english), "999.9 M", "never shows 1000.0 M")
        XCTAssertEqual(StatsFormat.tokens(999, locale: english), "999")
        XCTAssertEqual(StatsFormat.tokens(0, locale: english), "0")
        XCTAssertEqual(StatsFormat.integer(826_195, locale: english), "826,195")
        XCTAssertEqual(StatsFormat.integer(1060, locale: english), "1,060")
        XCTAssertEqual(StatsFormat.shortDate(date("2026-10-30"), calendar: calendar, locale: english), "Oct 30")
        // Spanish: decimal comma, dot as the grouping separator (es_ES groups from 5 digits, as CLDR says).
        XCTAssertEqual(StatsFormat.tokens(157_341_523_952, locale: spanish), "157,3 B")
        XCTAssertEqual(StatsFormat.tokens(12_300, locale: spanish), "12,3 K")
        XCTAssertEqual(StatsFormat.integer(826_195, locale: spanish), "826.195")
        XCTAssertEqual(StatsFormat.shortDate(date("2026-10-30"), calendar: calendar, locale: spanish), "30 oct")
    }

    func testDateTimeUsesTheCalendarTimeZoneAndLocale() {
        let moment = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 23, minute: 59))!
        let es = StatsFormat.dateTime(moment, calendar: calendar, locale: spanish)
        XCTAssertTrue(es.contains("30 oct") && es.contains("23:59"), es)
        let en = StatsFormat.dateTime(moment, calendar: calendar, locale: english)
        XCTAssertTrue(en.contains("Oct 30") && en.contains("11:59") && en.contains("PM"), en)
    }

    func testIncompleteJSONDoesNotBreakAndInvalidJSONFails() throws {
        let minimal = try StatsSummary.parse(data: Data("{\"version\": 6}".utf8), today: date("2026-11-02"), calendar: calendar)
        XCTAssertEqual(minimal.totalTokens, 0)
        XCTAssertEqual(minimal.days.count, 30)
        XCTAssertEqual(minimal.days.last?.key, "2026-11-02", "without lastComputedDate it anchors at today")
        XCTAssertThrowsError(try StatsSummary.parse(data: Data("not json".utf8), today: Date(), calendar: calendar))
    }
}
