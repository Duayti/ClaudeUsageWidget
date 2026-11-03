import Foundation

/// Number, percentage, date and "time ago" formatting. Everything follows the locale (decimal and
/// grouping separators, month names, 12/24-hour clock), which defaults to the system's.
/// Tests pass an explicit `locale` so they do not depend on the machine's settings.
enum StatsFormat {
    /// 157_341_523_952 -> "157.3 B" (B = billions, 10^9), 842_100_000 -> "842.1 M", 12_300 -> "12.3 K".
    /// The value is truncated, not rounded, so it never shows "1000.0 M" right before "1.0 B".
    static func tokens(_ n: Int, locale: Locale = .current) -> String {
        compact(n, minimumFractionDigits: 1, locale: locale)
    }

    /// Axis label: like `tokens` but without a trailing ".0" ("500 M", "1.5 B", "2 B").
    static func axis(_ n: Int, locale: Locale = .current) -> String {
        compact(n, minimumFractionDigits: 0, locale: locale)
    }

    private static func compact(_ n: Int, minimumFractionDigits: Int, locale: Locale) -> String {
        let magnitude = abs(n)
        let (unit, suffix): (Int, String)
        switch magnitude {
        case 1_000_000_000...: (unit, suffix) = (1_000_000_000, " B")
        case 1_000_000...: (unit, suffix) = (1_000_000, " M")
        case 1_000...: (unit, suffix) = (1_000, " K")
        default: return integer(n, locale: locale)
        }
        // Integer arithmetic: whole tenths of the unit, so truncation has no floating-point surprises.
        let tenths = magnitude / (unit / 10)
        let f = decimalFormatter(locale: locale)
        f.minimumFractionDigits = minimumFractionDigits
        f.maximumFractionDigits = 1
        f.usesGroupingSeparator = false
        let text = f.string(from: NSNumber(value: Double(tenths) / 10)) ?? String(tenths / 10)
        return (n < 0 ? "-" : "") + text + suffix
    }

    /// 826195 -> "826,195" (en_US) or "826.195" (es_ES).
    static func integer(_ n: Int, locale: Locale = .current) -> String {
        let f = decimalFormatter(locale: locale)
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// "Oct 30" (en_US), "30 oct" (es_ES).
    static func shortDate(_ d: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        dateFormatter("MMMd", calendar: calendar, locale: locale).string(from: d)
    }

    /// "Oct 30, 11:59 PM" (en_US), "30 oct, 23:59" (es_ES).
    static func dateTime(_ d: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        dateFormatter("MMMd jm", calendar: calendar, locale: locale).string(from: d)
    }

    /// Signed relative change: 0.123 -> "+12%", -0.08 -> "−8%", 0.004 -> "+0.4%" (percent sign placement follows the locale).
    static func change(_ x: Double, locale: Locale = .current) -> String {
        let pct = x * 100
        if pct == 0 { return percentText(0, digits: 0, locale: locale) }
        let sign = pct > 0 ? "+" : "−"
        let value = abs(pct)
        let text = value < 1 ? percentText(value / 100, digits: 1, locale: locale)
                             : percentText(value.rounded() / 100, digits: 0, locale: locale)
        return sign + text
    }

    /// Share of a total, always with one decimal: 0.4567 -> "45.7%", 0.21 -> "21.0%", 1 -> "100%", 0.0004 -> "<0.1%".
    static func percent(_ x: Double, locale: Locale = .current) -> String {
        let pct = x * 100
        if pct <= 0 { return percentText(0, digits: 0, locale: locale) }
        if pct < 0.05 { return "<" + percentText(0.001, digits: 1, locale: locale) }
        if pct >= 99.95 { return percentText(1, digits: 0, locale: locale) }
        return percentText(x, digits: 1, locale: locale)
    }

    /// "just now", "5 min ago", "2 hr ago", "3 days ago" (wording and abbreviations follow the locale).
    static func relative(_ d: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(d)
        if seconds < 60 { return String(localized: "just now") }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .short
        f.dateTimeStyle = .numeric
        switch seconds {
        case ..<3600: return f.localizedString(from: DateComponents(minute: -Int(seconds / 60)))
        case ..<86_400: return f.localizedString(from: DateComponents(hour: -Int(seconds / 3600)))
        default: return f.localizedString(from: DateComponents(day: -Int(seconds / 86_400)))
        }
    }

    // MARK: - Helpers

    private static func percentText(_ fraction: Double, digits: Int, locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .percent
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: fraction)) ?? "\(fraction * 100)%"
    }

    private static func decimalFormatter(locale: Locale) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        return f
    }

    private static func dateFormatter(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
}
