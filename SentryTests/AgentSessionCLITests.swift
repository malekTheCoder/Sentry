import XCTest
@testable import SentryKit

/// Covers the pure logic behind `sentryctl sessions` / `sentryctl stop`
/// (`SentryKit/CLI/AgentSessionCLI.swift`) — the same split `CLIDurationTests`
/// and `StatuslineRendererTests` use for the rest of `sentryctl`'s testable
/// surface, since `SentryCLI/main.swift` itself is a script, not a library.
final class AgentSessionCLITests: XCTestCase {

    // MARK: - stopTargetClientName

    func testStopTargetClientNameReadsTheArgumentAfterTheCommand() {
        XCTAssertEqual(
            AgentSessionCLI.stopTargetClientName(from: ["stop", "Claude Desktop"]),
            "Claude Desktop"
        )
    }

    func testStopTargetClientNameIsNilWhenNoArgumentFollows() {
        XCTAssertNil(AgentSessionCLI.stopTargetClientName(from: ["stop"]))
    }

    func testStopTargetClientNameIsNilForAnEmptyString() {
        // `sentryctl stop ""` should read as "no name given," not as a
        // request to revoke a client literally named the empty string.
        XCTAssertNil(AgentSessionCLI.stopTargetClientName(from: ["stop", ""]))
    }

    func testStopTargetClientNameIgnoresArgumentsPastTheFirst() {
        // Only one positional argument is defined for `stop` — a client
        // name containing a space has to come through as one shell argument
        // (quoted), and anything after it is not this method's problem to
        // interpret.
        XCTAssertEqual(
            AgentSessionCLI.stopTargetClientName(from: ["stop", "Claude Desktop", "extra"]),
            "Claude Desktop"
        )
    }

    // MARK: - formatSessionLine

    func testFormatSessionLineIncludesElapsedTimeSinceLastCall() {
        let now = Date()
        let session = MCPPayloads.AgentSessionInfo(
            clientName: "Claude Desktop",
            connectedAt: now.addingTimeInterval(-120),
            lastCallAt: now.addingTimeInterval(-42),
            recentTools: [],
            holdsKeepAwake: false
        )

        let line = AgentSessionCLI.formatSessionLine(session, now: now)

        XCTAssertEqual(line, "Claude Desktop — last call 42s ago")
    }

    func testFormatSessionLineNotesKeepAwakeWhenHeld() {
        let now = Date()
        let session = MCPPayloads.AgentSessionInfo(
            clientName: "Claude Desktop",
            connectedAt: now,
            lastCallAt: now,
            recentTools: [],
            holdsKeepAwake: true
        )

        let line = AgentSessionCLI.formatSessionLine(session, now: now)

        XCTAssertTrue(line.contains("holds keep-awake"), "line was: \(line)")
    }

    func testFormatSessionLineListsAtMostThreeRecentTools() {
        let now = Date()
        let session = MCPPayloads.AgentSessionInfo(
            clientName: "Claude Desktop",
            connectedAt: now,
            lastCallAt: now,
            recentTools: ["get_system_snapshot", "keep_awake", "get_device_info", "get_thermal_status"],
            holdsKeepAwake: false
        )

        let line = AgentSessionCLI.formatSessionLine(session, now: now)

        XCTAssertTrue(line.contains("recent: get_system_snapshot, keep_awake, get_device_info"), "line was: \(line)")
        XCTAssertFalse(line.contains("get_thermal_status"), "line was: \(line)")
    }

    func testFormatSessionLineClampsNegativeElapsedTimeToZero() {
        // A clock edge case (system clock skew between the app and CLI
        // process) should never render a negative "seconds ago."
        let now = Date()
        let session = MCPPayloads.AgentSessionInfo(
            clientName: "Claude Desktop",
            connectedAt: now,
            lastCallAt: now.addingTimeInterval(5),
            recentTools: [],
            holdsKeepAwake: false
        )

        let line = AgentSessionCLI.formatSessionLine(session, now: now)

        XCTAssertEqual(line, "Claude Desktop — last call 0s ago")
    }
}
