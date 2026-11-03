import Foundation

enum UpdaterError: Error, Equatable {
    /// ~/Library/Application Support/ClaudeUsageWidget/update_usage.py is missing.
    case missingScript
    /// The script exited with an error (code and last line of its output).
    case failed(code: Int32, output: String)
    case timedOut
    case launch(String)

    var message: String {
        switch self {
        case .missingScript:
            String(localized: "Updater script not found. Install it with tools/install_updater.sh.")
        case .failed(let code, let output):
            output.isEmpty ? String(localized: "The updater failed (code \(Int(code))).")
                           : String(localized: "The updater failed: \(output)")
        case .timedOut:
            String(localized: "The updater took too long and was stopped.")
        case .launch(let reason):
            String(localized: "Could not run the updater: \(reason)")
        }
    }
}

/// Runs tools/update_usage.py (the installed copy) off the main thread.
/// The app is not sandboxed precisely for this: the script reads ~/.claude/projects and writes to ~/.claude.
enum Updater {
    static let python = URL(fileURLWithPath: "/usr/bin/python3")
    /// The first run with ~10 GB of transcripts takes ~30 s.
    static let timeout: TimeInterval = 180

    static func scriptURL(home: URL = StatsLoader.realHomeDirectory()) -> URL {
        home.appendingPathComponent("Library/Application Support/ClaudeUsageWidget/update_usage.py")
    }

    /// `-I`: isolated mode, it does not load modules from the current folder or PYTHON* variables.
    static func arguments(script: URL) -> [String] { ["-I", script.path] }

    /// Returns the last line of the output (summary of the run) or the error.
    static func run(script: URL = scriptURL(), timeout: TimeInterval = timeout) async -> Result<String, UpdaterError> {
        guard FileManager.default.isReadableFile(atPath: script.path) else { return .failure(.missingScript) }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runBlocking(script: script, timeout: timeout))
            }
        }
    }

    private static func runBlocking(script: URL, timeout: TimeInterval) -> Result<String, UpdaterError> {
        let p = Process()
        p.executableURL = python
        p.arguments = arguments(script: script)
        p.currentDirectoryURL = script.deletingLastPathComponent()
        // A single pipe for stdout and stderr: reading it to the end cannot block on the other one.
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(.launch(error.localizedDescription)) }

        let started = Date()
        let watchdog = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        let lastLine = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if p.terminationReason == .uncaughtSignal, Date().timeIntervalSince(started) >= timeout { return .failure(.timedOut) }
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            return .failure(.failed(code: p.terminationStatus, output: lastLine))
        }
        return .success(lastLine)
    }
}
