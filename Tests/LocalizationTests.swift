import XCTest

/// The UI is written in English (the base language) and translated to Spanish through a String Catalog.
/// A key that does not match the code silently falls back to English, so these tests keep both in sync.
final class LocalizationTests: XCTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func catalog() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en")
        return try XCTUnwrap(json["strings"] as? [String: Any])
    }

    /// Every translated value of a language for a key (one value, or one per plural variant).
    private func values(_ entry: [String: Any], language: String) -> [String] {
        guard let loc = (entry["localizations"] as? [String: Any])?[language] as? [String: Any] else { return [] }
        if let unit = loc["stringUnit"] as? [String: Any], let v = unit["value"] as? String { return [v] }
        if let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: Any] {
            return plural.values.compactMap { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        }
        return []
    }

    private func placeholders(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|@)")
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }

    func testEveryKeyHasASpanishTranslationWithTheSamePlaceholders() throws {
        let strings = try catalog()
        XCTAssertGreaterThan(strings.count, 50)
        for (key, raw) in strings {
            let entry = try XCTUnwrap(raw as? [String: Any], key)
            let es = values(entry, language: "es")
            XCTAssertFalse(es.isEmpty, "missing Spanish translation for “\(key)”")
            for v in es {
                XCTAssertFalse(v.isEmpty, key)
                XCTAssertEqual(placeholders(v), placeholders(key), "placeholders differ in “\(key)” -> “\(v)”")
            }
            if let loc = (entry["localizations"] as? [String: Any])?["es"] as? [String: Any],
               let unit = loc["stringUnit"] as? [String: Any] {
                XCTAssertEqual(unit["state"] as? String, "translated", key)
            }
        }
    }

    func testPluralKeysHaveOneAndOtherInBothLanguages() throws {
        let entry = try XCTUnwrap(try catalog()["in %lld days"] as? [String: Any])
        for language in ["en", "es"] {
            let loc = try XCTUnwrap((entry["localizations"] as? [String: Any])?[language] as? [String: Any])
            let plural = try XCTUnwrap((loc["variations"] as? [String: Any])?["plural"] as? [String: Any])
            XCTAssertEqual(Set(plural.keys), ["one", "other"], language)
        }
    }

    /// Every literal shown to the user (`Text("…")`, `String(localized: "…")`, …) must exist as a catalog key.
    func testEverySourceStringIsInTheCatalog() throws {
        func normalize(_ key: String) -> String {
            key.replacingOccurrences(of: "%lld", with: "§").replacingOccurrences(of: "%@", with: "§")
        }
        let known = Set(try catalog().keys.map(normalize))

        let patterns = [
            "String\\(localized: \"((?:[^\"\\\\]|\\\\.)*)\"\\)",
            "\\bText\\(\"((?:[^\"\\\\]|\\\\.)*)\"\\)",
            "\\bLabel\\(\"((?:[^\"\\\\]|\\\\.)*)\"",
            "\\bButton\\(\"((?:[^\"\\\\]|\\\\.)*)\"",
            "\\bPicker\\(\"((?:[^\"\\\\]|\\\\.)*)\"",
            "\\.configurationDisplayName\\(\"((?:[^\"\\\\]|\\\\.)*)\"",
            "\\.description\\(\"((?:[^\"\\\\]|\\\\.)*)\"",
            "LocalizedStringResource = \"((?:[^\"\\\\]|\\\\.)*)\"",
            "IntentDescription\\(\"((?:[^\"\\\\]|\\\\.)*)\"",
            "@Parameter\\(title: \"((?:[^\"\\\\]|\\\\.)*)\"",
        ].map { try! NSRegularExpression(pattern: $0) }

        var checked = 0
        for folder in ["App", "Widget", "Shared"] {
            let dir = root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                for regex in patterns {
                    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                        let literal = String(text[Range(match.range(at: 1), in: text)!])
                        let key = normalize(Self.replacingInterpolations(literal)
                            .replacingOccurrences(of: "\\n", with: "\n")
                            .replacingOccurrences(of: "\\\"", with: "\""))
                        // Punctuation-only strings ("·", "—", "§ §") are not translatable text.
                        guard key.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { continue }
                        checked += 1
                        XCTAssertTrue(known.contains(key), "\(folder)/\(file): “\(literal)” is not in Localizable.xcstrings")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 50, "the scan should find the UI strings")
    }

    /// Replaces each `\( … )` (balanced parentheses) with the placeholder `§`.
    static func replacingInterpolations(_ s: String) -> String {
        var out = "", depth = 0
        var chars = Array(s), i = 0
        while i < chars.count {
            if depth == 0, chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                depth = 1; i += 2; out.append("§"); continue
            }
            if depth > 0 {
                if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1 }
                i += 1; continue
            }
            out.append(chars[i]); i += 1
        }
        chars.removeAll()
        return out
    }

    func testNumberFormattingHonorsTheLocaleInsteadOfAFixedComma() {
        XCTAssertNotEqual(StatsFormat.tokens(12_300, locale: Locale(identifier: "en_US")),
                          StatsFormat.tokens(12_300, locale: Locale(identifier: "es_ES")))
        XCTAssertEqual(StatsFormat.tokens(12_300, locale: Locale(identifier: "de_DE")), "12,3 K")
        XCTAssertEqual(StatsFormat.tokens(12_300, locale: Locale(identifier: "en_GB")), "12.3 K")
    }
}
