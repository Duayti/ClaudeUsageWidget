import Foundation

/// Readable model name from its id: "claude-opus-5-5" -> "Opus 5.5".
enum ModelName {
    static func display(_ id: String) -> String {
        var family: [String] = []
        var version: [String] = []
        for (i, token) in id.lowercased().split(separator: "-").map(String.init).enumerated() {
            if i == 0 && token == "claude" { continue }
            if token == "latest" { continue }
            let isNumber = token.allSatisfy(\.isNumber)
            if isNumber && token.count == 8 { continue }          // date suffix: 20251001
            if isNumber { version.append(token) } else { family.append(token.prefix(1).uppercased() + token.dropFirst()) }
        }
        guard !family.isEmpty else { return id }
        return ([family.joined(separator: " ")] + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
    }
}

/// Color per model: the family sets the hue (blue Opus, orange Sonnet, green Fable, yellow Haiku)
/// and the version sets the lightness. It depends only on the name, so a model always gets the same color.
enum ModelPalette {
    /// Mix with white (+) or black (-) depending on the version slot.
    private static let lightness: [Double] = [-0.30, -0.12, 0, 0.16, 0.32, 0.46]

    static func hex(_ name: String) -> UInt32 {
        let words = name.split(separator: " ").map(String.init)
        let base: UInt32
        switch words.first?.lowercased() {
        case "opus": base = 0x2A78D6
        case "sonnet": base = 0xEB6834
        case "fable": base = 0x1BAF7A
        case "haiku": base = 0xEDA100
        default: base = 0x8E6BC2
        }
        // "5.5" -> 55, "4.8" -> 48, "5" -> 50. Slot = value mod 6: neighbouring versions do not collide.
        let parts = (words.last ?? "").split(separator: ".").compactMap { Int($0) }
        let value = parts.isEmpty ? 0 : (parts[0] * 10 + (parts.count > 1 ? parts[1] : 0))
        return mix(base, with: lightness[value % lightness.count])
    }

    private static func mix(_ hex: UInt32, with t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let c = Double((hex >> shift) & 0xFF)
            let r = t >= 0 ? c + (255 - c) * t : c * (1 + t)
            return UInt32(max(0, min(255, r.rounded())))
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }
}

/// Every model present in the period, never grouped.
enum ModelStack {
    struct Result {
        /// Bottom to top: the model with the most tokens first.
        var series: [String]
        var days: [DayTokens]
    }

    static func all(_ days: [DayTokens]) -> Result {
        var totals: [String: Int] = [:]
        for d in days { for (m, t) in d.byModel where t > 0 { totals[m, default: 0] += t } }
        let ranking = totals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        let cleaned = days.map { d in
            DayTokens(key: d.key, date: d.date, byModel: d.byModel.filter { $0.value > 0 })
        }
        return Result(series: ranking, days: cleaned)
    }

    /// Table rows: every model. Only when they do not fit (`maxRows`) are the models with no tokens
    /// in the displayed range hidden; they are never grouped.
    static func tableRows(_ models: [ModelUsage], days: [DayTokens], maxRows: Int) -> [ModelUsage] {
        guard models.count > maxRows else { return models }
        let present = Set(all(days).series)
        return models.filter { present.contains($0.name) }
    }
}
