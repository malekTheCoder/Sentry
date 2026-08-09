import XCTest
@testable import SentryKit

/// Unit tests for the two pure config splicers
/// (`SentryKit/AIClients/JSONConfigSurgeon.swift`,
/// `TOMLConfigSurgeon.swift`) — the primitives underneath every Connect
/// button that edits an AI tool's own configuration file.
///
/// **These are the tests that exist because the code edits other people's
/// files.** Everything else in this feature is recoverable by clicking a
/// different button; a bad splice destroys a config the user assembled by
/// hand and may not have a copy of. So the assertions here are mostly about
/// what *survives* a write rather than what it produces: sibling MCP servers,
/// unrelated top-level keys, comments, key order, and the exact bytes of every
/// line we did not come for.
///
/// Pure `String` → `String` throughout — no `FileManager`, no temp directory,
/// no path that could reach a real `~/.cursor/mcp.json`. Same posture as
/// `AgentGuardrailsTests` takes for the guardrail engine.
final class AIClientConfigSurgeryTests: XCTestCase {

    private let entry = """
    {
      "type": "stdio",
      "command": "/Volumes/Sentry/Sentry.app/Contents/MacOS/SentryMCP",
      "args": []
    }
    """

    // MARK: - JSON: inserting

    func testInsertsIntoAnExistingContainerWithoutTouchingSiblings() throws {
        let original = """
        {
          "mcpServers": {
            "github": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-github"]
            }
          }
        }
        """
        let updated = try JSONConfigSurgeon.upsert(
            member: "Sentry", value: entry, at: ["mcpServers"], in: original
        )
        XCTAssertTrue(updated.contains("\"github\""), "the sibling server must survive the merge")
        XCTAssertTrue(updated.contains("@modelcontextprotocol/server-github"), "the sibling's own arguments must survive verbatim")
        XCTAssertTrue(updated.contains("\"Sentry\""))
        XCTAssertNotNil(try JSONConfigSurgeon.value(ofMember: "github", at: ["mcpServers"], in: updated))
        XCTAssertNotNil(try JSONConfigSurgeon.value(ofMember: "Sentry", at: ["mcpServers"], in: updated))
    }

    func testPreservesUnrelatedTopLevelKeysAndTheirOrder() throws {
        let original = """
        {
          "globalShortcut": "Cmd+Shift+Space",
          "mcpServers": {},
          "theme": "dark"
        }
        """
        let updated = try JSONConfigSurgeon.upsert(
            member: "Sentry", value: entry, at: ["mcpServers"], in: original
        )
        let shortcut = updated.range(of: "globalShortcut")
        let theme = updated.range(of: "theme")
        XCTAssertNotNil(shortcut)
        XCTAssertNotNil(theme)
        XCTAssertTrue(shortcut!.lowerBound < theme!.lowerBound, "existing keys must stay in their original order")
    }

    func testWritingTwiceIsIdempotent() throws {
        let original = """
        {
          "mcpServers": {
            "github": { "command": "npx" }
          }
        }
        """
        let once = try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: original)
        let twice = try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: once)
        XCTAssertEqual(once, twice, "a second Connect must produce a byte-identical file")
        XCTAssertEqual(
            once.components(separatedBy: "\"Sentry\"").count - 1, 1,
            "there must be exactly one Sentry member — a duplicate JSON key is a real bug, not a cosmetic one"
        )
    }

    func testReplacingAnEntryThatPointsSomewhereElse() throws {
        let stale = """
        {
          "mcpServers": {
            "Sentry": { "command": "/Applications/Sentry.app/Contents/MacOS/SentryMCP" },
            "github": { "command": "npx" }
          }
        }
        """
        let updated = try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: stale)
        XCTAssertFalse(updated.contains("/Applications/Sentry.app"), "the stale path must be gone")
        XCTAssertTrue(updated.contains("/Volumes/Sentry/Sentry.app"))
        XCTAssertTrue(updated.contains("\"github\""), "replacing our own entry must not disturb the one after it")
    }

    func testCreatesTheContainerWhenTheFileHasNoMCPSection() throws {
        let original = """
        {
          "theme": "dark"
        }
        """
        let updated = try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: original)
        XCTAssertTrue(updated.contains("\"theme\": \"dark\""))
        XCTAssertNotNil(try JSONConfigSurgeon.value(ofMember: "Sentry", at: ["mcpServers"], in: updated))
    }

    func testCreatesAWholeDocumentWhenThereIsNoFile() throws {
        let updated = try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: nil)
        XCTAssertNotNil(try JSONConfigSurgeon.value(ofMember: "Sentry", at: ["mcpServers"], in: updated))
        XCTAssertTrue(updated.hasPrefix("{\n"))
    }

    func testCreatesANestedContainerForVSCodeStyleTwoLevelPaths() throws {
        let updated = try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcp", "servers"], in: "{}")
        XCTAssertNotNil(try JSONConfigSurgeon.value(ofMember: "Sentry", at: ["mcp", "servers"], in: updated))
    }

    // MARK: - JSON with comments

    func testPreservesCommentsInAJSONCFileTheWayZedAndVSCodeWriteThem() throws {
        let original = """
        {
          // Everything about my editor lives in this file.
          "theme": "One Dark",
          /* MCP servers I actually use */
          "context_servers": {
            "github": { "command": "npx" } // the good one
          }
        }
        """
        let updated = try JSONConfigSurgeon.upsert(
            member: "Sentry", value: entry, at: ["context_servers"], in: original
        )
        XCTAssertTrue(updated.contains("// Everything about my editor lives in this file."))
        XCTAssertTrue(updated.contains("/* MCP servers I actually use */"))
        XCTAssertTrue(updated.contains("// the good one"))
        XCTAssertTrue(updated.contains("\"Sentry\""))
    }

    func testAKeyWhoseValueMentionsTheContainerNameIsNotMistakenForTheContainer() throws {
        // A regex-based implementation gets this wrong. The scanner must not.
        let original = """
        {
          "note": "put this under mcpServers by hand",
          "mcpServers": { "github": { "command": "npx" } }
        }
        """
        let updated = try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: original)
        XCTAssertTrue(updated.contains("\"note\": \"put this under mcpServers by hand\""))
        XCTAssertNotNil(try JSONConfigSurgeon.value(ofMember: "Sentry", at: ["mcpServers"], in: updated))
        XCTAssertNotNil(try JSONConfigSurgeon.value(ofMember: "github", at: ["mcpServers"], in: updated))
    }

    // MARK: - JSON: malformed input

    func testRefusesAFileWithAKeylessObject() {
        // Not hypothetical: this is the exact shape found in a real
        // claude_desktop_config.json on the machine this was written on.
        let broken = """
        {
          "preferences": {
            "x": 1,
            {
              "mcpServers": { "Sentry": { "command": "/Applications/Sentry.app/Contents/MacOS/SentryMCP" } }
            }
          }
        }
        """
        XCTAssertThrowsError(
            try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: broken)
        ) { error in
            guard case JSONConfigSurgeon.Failure.malformed(let reason, let offset) = error else {
                return XCTFail("expected a malformed failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("quoted key"))
            XCTAssertGreaterThan(offset, 0, "the offset has to point somewhere a human can look")
        }
    }

    func testRefusesAFileWhoseRootIsNotAnObject() {
        XCTAssertThrowsError(
            try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: "[1, 2, 3]")
        ) { error in
            XCTAssertEqual(error as? JSONConfigSurgeon.Failure, .rootIsNotAnObject)
        }
    }

    func testRefusesWhenTheContainerKeyHoldsSomethingOtherThanAnObject() {
        XCTAssertThrowsError(
            try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: "{\"mcpServers\": []}")
        ) { error in
            XCTAssertEqual(error as? JSONConfigSurgeon.Failure, .pathElementIsNotAnObject(key: "mcpServers"))
        }
    }

    func testRefusesAnUnterminatedString() {
        XCTAssertThrowsError(
            try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: "{\"mcpServers\": {\"a\": \"oops}")
        )
    }

    // MARK: - JSON: removing

    func testRemovingTakesOnlyOurEntry() throws {
        let original = """
        {
          "mcpServers": {
            "github": { "command": "npx" },
            "Sentry": { "command": "/Volumes/Sentry/Sentry.app/Contents/MacOS/SentryMCP" },
            "filesystem": { "command": "uvx" }
          }
        }
        """
        let updated = try XCTUnwrap(try JSONConfigSurgeon.remove(member: "Sentry", at: ["mcpServers"], in: original))
        XCTAssertNil(try JSONConfigSurgeon.value(ofMember: "Sentry", at: ["mcpServers"], in: updated))
        XCTAssertNotNil(try JSONConfigSurgeon.value(ofMember: "github", at: ["mcpServers"], in: updated))
        XCTAssertNotNil(try JSONConfigSurgeon.value(ofMember: "filesystem", at: ["mcpServers"], in: updated))
    }

    func testRemovingTheLastEntryLeavesTheContainerRatherThanDeletingIt() throws {
        let original = """
        {
          "globalShortcut": "Cmd+Space",
          "mcpServers": {
            "Sentry": { "command": "/Volumes/Sentry/Sentry.app/Contents/MacOS/SentryMCP" }
          }
        }
        """
        let updated = try XCTUnwrap(try JSONConfigSurgeon.remove(member: "Sentry", at: ["mcpServers"], in: original))
        XCTAssertTrue(updated.contains("\"mcpServers\""), "removing our entry must not remove the client's own section")
        XCTAssertTrue(updated.contains("\"globalShortcut\""))
        XCTAssertNil(try JSONConfigSurgeon.value(ofMember: "Sentry", at: ["mcpServers"], in: updated))
    }

    func testRemovingTheLastMemberOfAListDropsThePrecedingComma() throws {
        let original = """
        {
          "mcpServers": {
            "github": { "command": "npx" },
            "Sentry": { "command": "/x/SentryMCP" }
          }
        }
        """
        let updated = try XCTUnwrap(try JSONConfigSurgeon.remove(member: "Sentry", at: ["mcpServers"], in: original))
        XCTAssertFalse(updated.contains(",\n  }"), "a dangling comma would make the file invalid JSON for a strict reader")
        XCTAssertNotNil(try JSONConfigSurgeon.value(ofMember: "github", at: ["mcpServers"], in: updated))
    }

    func testRemovingWhatIsNotThereReportsNoChange() throws {
        XCTAssertNil(try JSONConfigSurgeon.remove(member: "Sentry", at: ["mcpServers"], in: "{\"mcpServers\": {}}"))
        XCTAssertNil(try JSONConfigSurgeon.remove(member: "Sentry", at: ["mcpServers"], in: "{}"))
    }

    func testRemoveThenInsertRoundTripsBackToTheSameSiblings() throws {
        let original = """
        {
          "mcpServers": {
            "github": { "command": "npx" }
          }
        }
        """
        let added = try JSONConfigSurgeon.upsert(member: "Sentry", value: entry, at: ["mcpServers"], in: original)
        let removed = try XCTUnwrap(try JSONConfigSurgeon.remove(member: "Sentry", at: ["mcpServers"], in: added))
        XCTAssertEqual(removed, original, "disconnect must put the file back exactly as connect found it")
    }

    // MARK: - TOML

    private let tomlBody = "command = \"/Volumes/Sentry/Sentry.app/Contents/MacOS/SentryMCP\"\nargs = []"

    func testTOMLInsertsWithoutTouchingOtherServersOrSettings() throws {
        let original = """
        model = "gpt-5"
        approval_policy = "on-request"

        # the node one, do not delete
        [mcp_servers.node_repl]
        command = "node"
        args = ["--experimental-repl"]

        [features]
        web_search = true
        """
        let updated = try TOMLConfigSurgeon.upsert(table: ["mcp_servers", "Sentry"], body: tomlBody, in: original)
        XCTAssertTrue(updated.contains("# the node one, do not delete"), "comments must survive")
        XCTAssertTrue(updated.contains("[mcp_servers.node_repl]"))
        XCTAssertTrue(updated.contains("[features]"))
        XCTAssertTrue(updated.contains("model = \"gpt-5\""))
        XCTAssertNotNil(try TOMLConfigSurgeon.table(at: ["mcp_servers", "Sentry"], in: updated))
        XCTAssertNotNil(try TOMLConfigSurgeon.table(at: ["mcp_servers", "node_repl"], in: updated))
    }

    func testTOMLWritingTwiceIsIdempotent() throws {
        let original = "model = \"gpt-5\"\n"
        let once = try TOMLConfigSurgeon.upsert(table: ["mcp_servers", "Sentry"], body: tomlBody, in: original)
        let twice = try TOMLConfigSurgeon.upsert(table: ["mcp_servers", "Sentry"], body: tomlBody, in: once)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(
            once.components(separatedBy: "[mcp_servers.Sentry]").count - 1, 1,
            "a duplicate table header is a hard TOML error — Codex would stop reading its own config entirely"
        )
    }

    func testTOMLReplacesAStaleEntryInPlaceAndKeepsTheTableAfterIt() throws {
        let original = """
        [mcp_servers.Sentry]
        command = "/Applications/Sentry.app/Contents/MacOS/SentryMCP"
        args = []

        [mcp_servers.other]
        command = "other"
        """
        let updated = try TOMLConfigSurgeon.upsert(table: ["mcp_servers", "Sentry"], body: tomlBody, in: original)
        XCTAssertFalse(updated.contains("/Applications/Sentry.app"))
        XCTAssertTrue(updated.contains("/Volumes/Sentry/Sentry.app"))
        XCTAssertTrue(updated.contains("[mcp_servers.other]"))
        XCTAssertTrue(updated.contains("command = \"other\""))
    }

    func testTOMLCreatesAWholeDocumentWhenThereIsNoFile() throws {
        let updated = try TOMLConfigSurgeon.upsert(table: ["mcp_servers", "Sentry"], body: tomlBody, in: nil)
        XCTAssertTrue(updated.hasPrefix("[mcp_servers.Sentry]"))
        XCTAssertNotNil(try TOMLConfigSurgeon.table(at: ["mcp_servers", "Sentry"], in: updated))
    }

    func testTOMLSubTablesBelongToTheEntryAndAreRemovedWithIt() throws {
        let original = """
        [mcp_servers.Sentry]
        command = "/x/SentryMCP"

        [mcp_servers.Sentry.env]
        SENTRY_DEBUG = "1"

        [mcp_servers.other]
        command = "other"
        """
        let updated = try XCTUnwrap(try TOMLConfigSurgeon.remove(table: ["mcp_servers", "Sentry"], in: original))
        XCTAssertFalse(updated.contains("SENTRY_DEBUG"), "our sub-table must go with us")
        XCTAssertFalse(updated.contains("[mcp_servers.Sentry"))
        XCTAssertTrue(updated.contains("[mcp_servers.other]"))
    }

    func testTOMLRemovalKeepsEverythingElseByteForByte() throws {
        // Trailing newline included deliberately: it is what every real
        // config.toml has, and it is the thing an off-by-one in the
        // blank-line trimming eats.
        let original = "model = \"gpt-5\"\n\n[mcp_servers.node_repl]\ncommand = \"node\"\n"
        let added = try TOMLConfigSurgeon.upsert(table: ["mcp_servers", "Sentry"], body: tomlBody, in: original)
        let removed = try XCTUnwrap(try TOMLConfigSurgeon.remove(table: ["mcp_servers", "Sentry"], in: added))
        XCTAssertEqual(removed, original)
    }

    func testTOMLRemovingWhatIsNotThereReportsNoChange() throws {
        XCTAssertNil(try TOMLConfigSurgeon.remove(table: ["mcp_servers", "Sentry"], in: "model = \"gpt-5\"\n"))
    }

    func testTOMLDoesNotMistakeABracketInsideAMultilineArrayForATableHeader() throws {
        let original = """
        [mcp_servers.weird]
        args = [
        ["nested"],
        ["more"],
        ]
        command = "weird"

        [mcp_servers.after]
        command = "after"
        """
        let updated = try TOMLConfigSurgeon.upsert(table: ["mcp_servers", "Sentry"], body: tomlBody, in: original)
        XCTAssertTrue(updated.contains("[\"nested\"],"), "array contents must be untouched")
        XCTAssertNotNil(try TOMLConfigSurgeon.table(at: ["mcp_servers", "after"], in: updated))
        XCTAssertNotNil(try TOMLConfigSurgeon.table(at: ["mcp_servers", "Sentry"], in: updated))
    }

    func testTOMLQuotedTableSegmentsAreMatched() throws {
        let original = "[mcp_servers.\"My Server\"]\ncommand = \"x\"\n"
        XCTAssertNotNil(try TOMLConfigSurgeon.table(at: ["mcp_servers", "My Server"], in: original))
        XCTAssertNil(try TOMLConfigSurgeon.table(at: ["mcp_servers", "Sentry"], in: original))
    }

    func testTOMLArrayOfTablesIsNeverTreatedAsAPlainTable() throws {
        // `[[mcp_servers.Sentry]]` is a different construct; overwriting it
        // would be a change in kind, so it must simply not match.
        let original = "[[mcp_servers.Sentry]]\ncommand = \"x\"\n"
        XCTAssertNil(try TOMLConfigSurgeon.table(at: ["mcp_servers", "Sentry"], in: original))
    }

    func testTOMLReportsAnUnterminatedHeaderRatherThanSplicingBlind() {
        XCTAssertThrowsError(
            try TOMLConfigSurgeon.upsert(table: ["mcp_servers", "Sentry"], body: tomlBody, in: "[oops\ncommand = \"x\"\n")
        ) { error in
            XCTAssertEqual(error as? TOMLConfigSurgeon.Failure, .malformedTableHeader(line: 1))
        }
    }
}
