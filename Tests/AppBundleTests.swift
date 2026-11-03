import XCTest
import ImageIO

/// The host app is a regular app (Dock + panel window), opens `claudeusage://` and ships its icon.
final class AppBundleTests: XCTestCase {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
    }

    func testAppInfoPlistHasDockAndTheWidgetScheme() throws {
        let p = try plist("App/Info.plist")
        XCTAssertNil(p["LSUIElement"], "not an agent: it has a Dock icon, a menu and a window")
        let types = try XCTUnwrap(p["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertEqual(schemes, [PanelLink.scheme], "clicking the widget opens claudeusage://panel")
        XCTAssertEqual(p["CFBundleDevelopmentRegion"] as? String, "en", "English is the base language")
    }

    /// The app runs the updater (reads ~/.claude/projects and writes ~/.claude): it is not sandboxed.
    /// The widget extension stays sandboxed (checked by StatsLoaderTests).
    func testAppIsNotSandboxed() throws {
        let p = try plist("App/App.entitlements")
        XCTAssertNotEqual(p["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertTrue(p.isEmpty, "no extra permissions")
    }

    func testUpdaterPaths() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        XCTAssertEqual(Updater.scriptURL(home: home).path, "/Users/x/Library/Application Support/ClaudeUsageWidget/update_usage.py")
        XCTAssertEqual(Updater.arguments(script: URL(fileURLWithPath: "/a b/s.py")), ["-I", "/a b/s.py"])
        XCTAssertEqual(Updater.python.path, "/usr/bin/python3")
    }

    func testUpdaterRunsTheScriptWithoutBlocking() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = dir.appendingPathComponent("ok.py"), fails = dir.appendingPathComponent("fails.py")
        try "print('3/3 files, 0.1 s')\n".write(to: ok, atomically: true, encoding: .utf8)
        try "import sys\nsys.stderr.write('could not read\\n')\nsys.exit(2)\n".write(to: fails, atomically: true, encoding: .utf8)

        let r1 = await Updater.run(script: ok)
        XCTAssertEqual(try r1.get(), "3/3 files, 0.1 s")

        let r2 = await Updater.run(script: fails)
        guard case .failure(.failed(let code, let output)) = r2 else { return XCTFail("\(r2)") }
        XCTAssertEqual(code, 2)
        XCTAssertEqual(output, "could not read")

        let r3 = await Updater.run(script: dir.appendingPathComponent("does-not-exist.py"))
        guard case .failure(.missingScript) = r3 else { return XCTFail("\(r3)") }
        XCTAssertTrue(UpdaterError.missingScript.message.contains("install_updater.sh"))
    }

    func testIconHasEverySizeMacOSNeeds() throws {
        let set = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: set.appendingPathComponent("Contents.json"))) as? [String: Any]
        let images = try XCTUnwrap(json?["images"] as? [[String: String]])
        var seen = Set<String>()
        for img in images {
            XCTAssertEqual(img["idiom"], "mac")
            let side = try XCTUnwrap(img["size"]?.split(separator: "x").first.flatMap { Double($0) })
            let scale = try XCTUnwrap(img["scale"]?.dropLast().description).flatMap { Double($0) } ?? 0
            let file = try XCTUnwrap(img["filename"], "every size has its PNG")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(set.appendingPathComponent(file) as CFURL, nil), file)
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, Int(side * scale), file)
            XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, Int(side * scale), file)
            seen.insert("\(Int(side))@\(Int(scale))x")
        }
        let expected = [16, 32, 128, 256, 512].flatMap { ["\($0)@1x", "\($0)@2x"] }
        XCTAssertEqual(seen, Set(expected))
    }

    func testProjectCompilesTheAppIconAndTheStringCatalogIntoBothTargets() throws {
        let pbx = try String(contentsOf: root.appendingPathComponent("ClaudeUsageWidget.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertTrue(pbx.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"))
        XCTAssertTrue(pbx.contains("path = Assets.xcassets;"))
        XCTAssertTrue(pbx.contains("path = Localizable.xcstrings;"))
        XCTAssertTrue(pbx.contains("developmentRegion = en;"))
        XCTAssertTrue(pbx.contains("knownRegions = (en, Base, es, );"))
        XCTAssertEqual(pbx.components(separatedBy: "isa = PBXResourcesBuildPhase").count - 1, 3, "app, widget, tests")
    }

    /// The tracked project must use the placeholder bundle id (a contributor's own id is set with BUNDLE_PREFIX).
    func testProjectUsesThePlaceholderBundleIdentifier() throws {
        let pbx = try String(contentsOf: root.appendingPathComponent("ClaudeUsageWidget.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertTrue(pbx.contains("PRODUCT_BUNDLE_IDENTIFIER = com.example.ClaudeUsageWidget;"))
        XCTAssertTrue(pbx.contains("PRODUCT_BUNDLE_IDENTIFIER = com.example.ClaudeUsageWidget.Widget;"))
    }
}
