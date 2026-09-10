import XCTest

// MARK: - ScreenshotHandshake: the file-based hand-off to the host script

/// Shared by the iPhone and Watch UI-test targets (the file is listed in
/// both so there is one definition of the protocol, the same way
/// `SentryWidget/Intents/EndKeepAwakeIntent.swift` is compiled into two
/// targets).
///
/// Protocol, from the test's side:
///
/// 1. Read `SENTRY_SHOT_HANDSHAKE_DIR` from the environment (the script
///    passes it through `xcodebuild` as `TEST_RUNNER_SENTRY_SHOT_HANDSHAKE_DIR`).
///    No directory means nobody is listening — fail immediately rather than
///    sit for the full timeout.
/// 2. Write `<state>.ready` containing `demo` or `live`, so the script can
///    label the capture truthfully.
/// 3. Poll for `<state>.done` for up to `timeout` seconds. The script writes
///    it after its last `simctl io screenshot` for that state.
/// 4. Refuse to be called with `isDemo == false` unless
///    `SENTRY_SHOT_ALLOW_LIVE` is set — a capture of a real Mac's readings
///    must be a deliberate choice, never a surprise.
enum ScreenshotHandshake {
    static func hold(state: String, isDemo: Bool, timeout: TimeInterval = 180, file: StaticString = #filePath, line: UInt = #line) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SENTRY_SHOT_HANDSHAKE_DIR"], !dir.isEmpty else {
            XCTFail("SENTRY_SHOT_HANDSHAKE_DIR is not set — run this through scripts/asc-screenshots.sh, not directly.", file: file, line: line)
            return
        }
        if !isDemo, env["SENTRY_SHOT_ALLOW_LIVE"] != "1" {
            XCTFail("State '\(state)' is showing LIVE data (no demo banner). Quit Sentry on the Mac, or set SENTRY_SHOT_ALLOW_LIVE=1 to capture real readings deliberately.", file: file, line: line)
            return
        }
        let ready = URL(fileURLWithPath: dir).appendingPathComponent("\(state).ready")
        let done = URL(fileURLWithPath: dir).appendingPathComponent("\(state).done")
        do {
            try (isDemo ? "demo" : "live").write(to: ready, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Could not write \(ready.path): \(error)", file: file, line: line)
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: done.path) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("Host never acknowledged state '\(state)' (no \(done.lastPathComponent) within \(Int(timeout))s).", file: file, line: line)
    }
}
