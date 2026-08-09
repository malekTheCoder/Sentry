import XCTest
@testable import SentryKit

/// End-to-end tests for detection, connect, verify and disconnect
/// (`SentryKit/AIClients/AIClientDetector.swift`,
/// `AIClientConnector.swift`) against a fully in-memory environment.
///
/// **Nothing in this file can touch a real config file, by construction.**
/// `FakeAIClientEnvironment` implements the whole of `AIClientEnvironment`
/// over a dictionary; there is no `FileManager` and no `Process` anywhere in
/// the suite, so a path-construction bug cannot escape into
/// `~/.claude.json`, `~/.codex/config.toml`, `~/.cursor/mcp.json` or Claude
/// Desktop's configuration on the machine running the tests. That was a hard
/// requirement of the feature, not a preference — see
/// `AIClientEnvironment`'s doc comment for why a temp directory was rejected
/// as insufficient.
///
/// The fake also buys the states that matter and are otherwise unstageable: a
/// read-only file, a CLI that exits non-zero, a CLI that exits zero but writes
/// nothing (the "we wrote something" trap this whole feature exists to avoid),
/// and a config file that has become unparseable.
final class AIClientConnectorTests: XCTestCase {

    // MARK: - Fixtures

    private let home = "/Users/tester"
    private let mcpPath = "/Volumes/Sentry 1.0/Sentry.app/Contents/MacOS/SentryMCP"

    private func makeConfig() -> MCPClientConfig {
        .local(mcpBinaryPath: mcpPath)
    }

    @MainActor
    private func makeConnector(_ environment: FakeAIClientEnvironment) -> AIClientConnector {
        AIClientConnector(environment: environment, config: makeConfig())
    }

    private func makeEnvironment() -> FakeAIClientEnvironment {
        FakeAIClientEnvironment(homeDirectory: home)
    }

    // MARK: - Binary path resolution

    func testMCPBinaryPathIsDerivedFromWhereverTheAppActuallyIs() {
        XCTAssertEqual(
            MCPClientConfig.mcpBinaryPath(appExecutablePath: "/Volumes/Sentry 1.0/Sentry.app/Contents/MacOS/Sentry"),
            "/Volumes/Sentry 1.0/Sentry.app/Contents/MacOS/SentryMCP",
            "a DMG-mounted copy must produce a path on that volume, not /Applications"
        )
        XCTAssertEqual(
            MCPClientConfig.mcpBinaryPath(appExecutablePath: "/Users/tester/Applications/Sentry.app/Contents/MacOS/Sentry"),
            "/Users/tester/Applications/Sentry.app/Contents/MacOS/SentryMCP"
        )
    }

    func testTheCopyableSnippetAndTheWrittenEntryComeFromTheSameRenderer() throws {
        let config = makeConfig()
        let snippet = config.snippetJSON(containerPath: ["mcpServers"], dialect: .explicitType)
        let entry = try XCTUnwrap(
            try JSONConfigSurgeon.value(ofMember: "Sentry", at: ["mcpServers"], in: snippet)
        )
        // Whitespace differs by indentation depth; the content must not.
        XCTAssertTrue(entry.contains(mcpPath))
        XCTAssertTrue(entry.contains("\"type\": \"stdio\""))
    }

    // MARK: - Preflight (the SMAppService bridge)

    @MainActor
    func testConnectRefusesWhenTheCommandLineBridgeIsNotRegistered() {
        let environment = makeEnvironment()
        environment.files["\(home)/.cursor/mcp.json"] = "{\"mcpServers\": {}}"
        let outcome = makeConnector(environment).connect(.cursor, bridge: .notRegistered)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.detail.contains("Set Up Command-Line Access"))
        XCTAssertEqual(
            environment.files["\(home)/.cursor/mcp.json"], "{\"mcpServers\": {}}",
            "a blocked connect must not have written anything at all"
        )
    }

    @MainActor
    func testConnectRefusesAndExplainsOnAnUnsignedBuildWhereRegistrationCannotSucceed() {
        let environment = makeEnvironment()
        let outcome = makeConnector(environment).connect(
            .cursor, bridge: .unavailable(reason: "code signature mismatch")
        )
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.detail.contains("code signature mismatch"))
        XCTAssertTrue(outcome.detail.contains("Developer ID"))
        XCTAssertTrue(environment.files.isEmpty, "nothing may be created when the bridge can never work")
    }

    @MainActor
    func testEveryBridgeStateOtherThanRegisteredBlocks() {
        XCTAssertNil(AIClientConnector.blockingReason(bridge: .registered))
        XCTAssertNotNil(AIClientConnector.blockingReason(bridge: .awaitingApproval))
        XCTAssertNotNil(AIClientConnector.blockingReason(bridge: .notRegistered))
        XCTAssertNotNil(AIClientConnector.blockingReason(bridge: .unavailable(reason: "x")))
    }

    // MARK: - Detection

    func testAToolIsDetectedFromItsAppBundleEvenWithNoCLIOnPath() {
        let environment = makeEnvironment()
        environment.files["/Applications/Cursor.app"] = ""
        let status = AIClientDetector.status(of: .cursor, environment: environment, config: makeConfig())
        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(status.detection, .found(evidence: "/Applications/Cursor.app"))
    }

    func testCodexIsDetectedFromItsBundledBinaryWhenItIsNotOnPath() {
        // The real-world case: the Codex desktop app is installed and `codex`
        // is not on $PATH, so a PATH-only probe reports "not installed" about
        // an app sitting in the Dock.
        let environment = makeEnvironment()
        environment.files["/Applications/Codex.app/Contents/Resources/codex"] = ""
        let status = AIClientDetector.status(of: .codex, environment: environment, config: makeConfig())
        XCTAssertTrue(status.isDetected)
        XCTAssertEqual(
            AIClientDetector.locateExecutable(.codex, environment: environment),
            "/Applications/Codex.app/Contents/Resources/codex"
        )
    }

    func testAToolThatIsNotInstalledIsStillReportedRatherThanHidden() {
        let environment = makeEnvironment()
        let statuses = AIClientDetector.statuses(environment: environment, config: makeConfig())
        XCTAssertEqual(statuses.count, AIClientDefinition.ID.allCases.count)
        XCTAssertTrue(statuses.allSatisfy { !$0.isDetected })
    }

    func testAToolInstalledInTheUsersOwnApplicationsFolderIsFound() {
        let environment = makeEnvironment()
        environment.files["\(home)/Applications/Claude.app"] = ""
        XCTAssertTrue(AIClientDetector.detect(.claudeDesktop, environment: environment) != .notFound)
    }

    // MARK: - Connect: file-writing clients

    @MainActor
    func testConnectingCreatesTheFileWhenTheToolHasNeverBeenRunAndSaysSo() {
        let environment = makeEnvironment()
        environment.files["/Applications/Cursor.app"] = ""
        let outcome = makeConnector(environment).connect(.cursor, bridge: .registered)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        XCTAssertTrue(outcome.createdFile)
        XCTAssertNil(outcome.backupPath, "there is nothing to back up when the file didn't exist")
        XCTAssertTrue(outcome.detail.contains("didn't exist yet"))
        XCTAssertEqual(outcome.connection, .connected(command: mcpPath))
        XCTAssertTrue(environment.createdDirectories.contains("\(home)/.cursor"))
    }

    @MainActor
    func testConnectingBacksUpTheExistingFileAndReportsWhereItWent() {
        let environment = makeEnvironment()
        let path = "\(home)/.cursor/mcp.json"
        environment.files[path] = "{\n  \"mcpServers\": {\n    \"github\": { \"command\": \"npx\" }\n  }\n}"
        let original = environment.files[path]!

        let outcome = makeConnector(environment).connect(.cursor, bridge: .registered)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        let backup = try? XCTUnwrap(outcome.backupPath)
        XCTAssertNotNil(backup)
        XCTAssertTrue(outcome.detail.contains(backup ?? "!"), "the outcome must name the backup, not merely make one")
        XCTAssertEqual(environment.files[backup ?? "!"], original, "the backup must be the pre-write bytes")
    }

    @MainActor
    func testConnectingDoesNotClobberASiblingServer() {
        let environment = makeEnvironment()
        let path = "\(home)/.cursor/mcp.json"
        environment.files[path] = """
        {
          "mcpServers": {
            "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] }
          }
        }
        """
        let outcome = makeConnector(environment).connect(.cursor, bridge: .registered)
        XCTAssertTrue(outcome.succeeded, outcome.detail)

        let written = environment.files[path]!
        XCTAssertTrue(written.contains("@modelcontextprotocol/server-github"))
        XCTAssertNotNil(try? JSONConfigSurgeon.value(ofMember: "github", at: ["mcpServers"], in: written))
        XCTAssertNotNil(try? JSONConfigSurgeon.value(ofMember: "Sentry", at: ["mcpServers"], in: written))
    }

    @MainActor
    func testConnectingTwiceChangesNothingTheSecondTime() {
        let environment = makeEnvironment()
        let path = "\(home)/.cursor/mcp.json"
        let connector = makeConnector(environment)

        XCTAssertTrue(connector.connect(.cursor, bridge: .registered).succeeded)
        let afterFirst = environment.files[path]!
        let writeCountAfterFirst = environment.writeCount

        let second = connector.connect(.cursor, bridge: .registered)
        XCTAssertTrue(second.succeeded)
        XCTAssertEqual(environment.files[path], afterFirst, "the file must be byte-identical after a second click")
        XCTAssertEqual(environment.writeCount, writeCountAfterFirst, "an unchanged file must not be rewritten")
        XCTAssertNil(second.backupPath, "an idempotent no-op must not litter a backup")
        XCTAssertTrue(second.detail.contains("already had exactly this entry"))
        XCTAssertEqual(
            afterFirst.components(separatedBy: "\"Sentry\"").count - 1, 1,
            "clicking twice must never produce a duplicate entry"
        )
    }

    @MainActor
    func testConnectingRefusesAMalformedFileAndWritesNothing() {
        let environment = makeEnvironment()
        let path = "\(home)/.cursor/mcp.json"
        let broken = "{\n  \"mcpServers\": {\n    \"github\": { \"command\": \"npx\" }\n  \n"
        environment.files[path] = broken

        let outcome = makeConnector(environment).connect(.cursor, bridge: .registered)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.headline.contains("isn't valid"))
        XCTAssertTrue(outcome.detail.contains(path), "the failure must name the file")
        XCTAssertTrue(outcome.detail.contains("other MCP servers"))
        XCTAssertEqual(environment.files[path], broken, "a file we can't parse must come out untouched")
        XCTAssertEqual(environment.writeCount, 0)
        XCTAssertEqual(environment.copyCount, 0, "not even a backup — nothing at all happens")
    }

    @MainActor
    func testConnectingRefusesAReadOnlyFileBeforeTouchingAnything() {
        let environment = makeEnvironment()
        let path = "\(home)/.cursor/mcp.json"
        environment.files[path] = "{\"mcpServers\": {}}"
        environment.unwritablePaths.insert(path)

        let outcome = makeConnector(environment).connect(.cursor, bridge: .registered)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.detail.contains(path))
        XCTAssertTrue(outcome.detail.contains("permissions"))
        XCTAssertEqual(environment.writeCount, 0)
        XCTAssertEqual(environment.copyCount, 0)
    }

    @MainActor
    func testAFailedBackupAbortsBeforeTheWriteRatherThanHalfWriting() {
        let environment = makeEnvironment()
        let path = "\(home)/.cursor/mcp.json"
        environment.files[path] = "{\"mcpServers\": {}}"
        environment.failCopies = true

        let outcome = makeConnector(environment).connect(.cursor, bridge: .registered)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.headline.contains("back up"))
        XCTAssertEqual(environment.files[path], "{\"mcpServers\": {}}")
        XCTAssertEqual(environment.writeCount, 0)
    }

    @MainActor
    func testZedsWholeSettingsFileSurvivesWithItsCommentsIntact() {
        let environment = makeEnvironment()
        let path = "\(home)/.config/zed/settings.json"
        environment.files[path] = """
        {
          // my carefully tuned editor
          "buffer_font_size": 15,
          "context_servers": {
            "github": { "command": "npx" }
          }
        }
        """
        let outcome = makeConnector(environment).connect(.zed, bridge: .registered)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        let written = environment.files[path]!
        XCTAssertTrue(written.contains("// my carefully tuned editor"))
        XCTAssertTrue(written.contains("\"buffer_font_size\": 15"))
        XCTAssertFalse(written.contains("\"type\""), "Zed's schema has no type field, so we must not invent one")
    }

    @MainActor
    func testClaudeDesktopEntryOmitsTheTypeKeyItsSchemaDoesNotHave() {
        let environment = makeEnvironment()
        environment.files["/Applications/Claude.app"] = ""
        let outcome = makeConnector(environment).connect(.claudeDesktop, bridge: .registered)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        let path = "\(home)/Library/Application Support/Claude/claude_desktop_config.json"
        XCTAssertFalse(environment.files[path]!.contains("\"type\""))
        XCTAssertTrue(outcome.detail.contains("Quit Claude Desktop"), "the relaunch requirement has to be said on the spot")
    }

    // MARK: - Connect: CLI-driven clients

    @MainActor
    func testClaudeCodeIsConnectedThroughItsOwnCLIAndNeverByEditingClaudeJSON() {
        let environment = makeEnvironment()
        environment.files["\(home)/.local/bin/claude"] = ""
        environment.files["\(home)/.claude.json"] = "{\"oauthAccount\": {\"x\": 1}, \"mcpServers\": {}}"
        environment.commandResults["mcp add-json"] = AIClientCommandResult(exitStatus: 0, standardOutput: "Added", standardError: "")
        environment.commandResults["mcp get"] = AIClientCommandResult(
            exitStatus: 0, standardOutput: "Sentry\n  Command: \(mcpPath)\n", standardError: ""
        )

        let outcome = makeConnector(environment).connect(.claudeCode, bridge: .registered)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        XCTAssertEqual(outcome.connection, .connected(command: mcpPath))
        XCTAssertEqual(environment.writeCount, 0, "~/.claude.json must never be written by us")
        XCTAssertEqual(environment.files["\(home)/.claude.json"], "{\"oauthAccount\": {\"x\": 1}, \"mcpServers\": {}}")
        let invocation = environment.invocations.first { $0.arguments.contains("add-json") }
        XCTAssertNotNil(invocation)
        XCTAssertTrue(invocation!.arguments.contains("--scope"))
        XCTAssertTrue(invocation!.arguments.contains("user"), "scope must be pinned — the CLI's default is project-local")
        XCTAssertTrue(invocation!.arguments.contains { $0.contains(mcpPath) })
    }

    @MainActor
    func testAVendorCLIThatExitsZeroButRegistersNothingIsNotReportedAsConnected() {
        // The exact failure this feature exists to prevent: reporting success
        // because a command returned 0 rather than because the entry is there.
        let environment = makeEnvironment()
        environment.files["\(home)/.local/bin/claude"] = ""
        environment.commandResults["mcp add-json"] = AIClientCommandResult(exitStatus: 0, standardOutput: "", standardError: "")
        environment.commandResults["mcp get"] = AIClientCommandResult(exitStatus: 1, standardOutput: "", standardError: "not found")

        let outcome = makeConnector(environment).connect(.claudeCode, bridge: .registered)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.connection, .notConnected)
        XCTAssertTrue(outcome.detail.contains("didn't take"))
    }

    @MainActor
    func testAVendorCLIFailureIsReportedVerbatimWithTheCommandToRunByHand() {
        let environment = makeEnvironment()
        environment.files["\(home)/.local/bin/claude"] = ""
        environment.commandResults["mcp add-json"] = AIClientCommandResult(
            exitStatus: 2, standardOutput: "", standardError: "Error: reserved server name"
        )

        let outcome = makeConnector(environment).connect(.claudeCode, bridge: .registered)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.detail.contains("reserved server name"))
        XCTAssertTrue(outcome.detail.contains("claude mcp add-json"))
        XCTAssertTrue(outcome.detail.contains("Nothing was changed"))
    }

    @MainActor
    func testAMissingVendorCLIIsReportedWithTheExactCommandTheUserCouldRun() {
        let environment = makeEnvironment()
        environment.files["\(home)/.claude"] = ""   // detected, but no binary
        let outcome = makeConnector(environment).connect(.claudeCode, bridge: .registered)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.detail.contains("claude mcp add-json"))
        XCTAssertTrue(outcome.detail.contains(mcpPath))
    }

    @MainActor
    func testCodexPrefersItsCLIButFallsBackToWritingConfigTOMLWhenTheBinaryIsAbsent() {
        let environment = makeEnvironment()
        let path = "\(home)/.codex/config.toml"
        environment.files[path] = "model = \"gpt-5\"\n\n[mcp_servers.node_repl]\ncommand = \"node\"\n"
        environment.files["\(home)/.codex"] = ""

        let outcome = makeConnector(environment).connect(.codex, bridge: .registered)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        XCTAssertTrue(environment.invocations.isEmpty, "no codex binary exists, so nothing should have been run")
        let written = environment.files[path]!
        XCTAssertTrue(written.contains("[mcp_servers.node_repl]"))
        XCTAssertTrue(written.contains("model = \"gpt-5\""))
        XCTAssertEqual(outcome.connection, .connected(command: mcpPath))
    }

    @MainActor
    func testCodexVerificationReadsTheTOMLBackRatherThanTrustingTheCLI() {
        let environment = makeEnvironment()
        environment.files["/opt/homebrew/bin/codex"] = ""
        environment.commandResults["mcp add"] = AIClientCommandResult(exitStatus: 0, standardOutput: "ok", standardError: "")
        // The CLI claimed success but wrote nothing.
        let outcome = makeConnector(environment).connect(.codex, bridge: .registered)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.connection, .notConnected)
    }

    @MainActor
    func testVSCodeReportsThatItCannotConfirmWhichProfileFileWasWritten() {
        let environment = makeEnvironment()
        environment.files["/opt/homebrew/bin/code"] = ""
        environment.commandResults["--add-mcp"] = AIClientCommandResult(exitStatus: 0, standardOutput: "", standardError: "")

        let outcome = makeConnector(environment).connect(.vsCode, bridge: .registered)

        XCTAssertTrue(outcome.succeeded, "the CLI accepted it, so this is not a failure")
        guard case .unverifiable = outcome.connection else {
            return XCTFail("expected an explicitly unverifiable state, got \(outcome.connection)")
        }
        XCTAssertTrue(outcome.detail.contains("MCP: Open User Configuration"))
        let invocation = environment.invocations.first { $0.arguments.contains("--add-mcp") }
        XCTAssertNotNil(invocation)
        XCTAssertTrue(
            invocation!.arguments.last!.contains("\"name\""),
            "code --add-mcp takes the server name inside the object, not as a key"
        )
    }

    @MainActor
    func testVSCodeIsConfirmedOnceItsEntryTurnsUpInACandidateFile() {
        let environment = makeEnvironment()
        environment.files["/opt/homebrew/bin/code"] = ""
        let path = "\(home)/Library/Application Support/Code/User/mcp.json"
        environment.commandResults["--add-mcp"] = AIClientCommandResult(exitStatus: 0, standardOutput: "", standardError: "")
        environment.onRun = { _, arguments in
            guard arguments.contains("--add-mcp") else { return }
            environment.files[path] = "{\n  \"servers\": {\n    \"Sentry\": { \"command\": \"\(self.mcpPath)\" }\n  }\n}"
        }
        let outcome = makeConnector(environment).connect(.vsCode, bridge: .registered)
        XCTAssertTrue(outcome.succeeded, outcome.detail)
        XCTAssertEqual(outcome.connection, .connected(command: mcpPath))
    }

    // MARK: - Connect: manual-only clients

    @MainActor
    func testWindsurfIsRefusedWithItsReasonRatherThanWrittenBlind() {
        let environment = makeEnvironment()
        environment.files["/Applications/Windsurf.app"] = ""
        let outcome = makeConnector(environment).connect(.windsurf, bridge: .registered)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.detail.contains("legacy Cascade agent"))
        XCTAssertTrue(environment.files["\(home)/.codeium/windsurf/mcp_config.json"] == nil)
        XCTAssertEqual(environment.writeCount, 0)
    }

    @MainActor
    func testWindsurfIsStillReportedAsConnectedIfTheUserWiredItByHand() {
        let environment = makeEnvironment()
        environment.files["\(home)/.codeium/windsurf/mcp_config.json"] =
            "{\"mcpServers\": {\"Sentry\": {\"command\": \"\(mcpPath)\"}}}"
        let status = makeConnectorStatus(environment, definition: .windsurf)
        XCTAssertEqual(status.connection, .connected(command: mcpPath))
    }

    // MARK: - Stale entries

    @MainActor
    func testAnEntryPointingAtADifferentSentryIsCalledOutRatherThanTickedOff() {
        let environment = makeEnvironment()
        environment.files["\(home)/.cursor/mcp.json"] =
            "{\"mcpServers\": {\"Sentry\": {\"command\": \"/Applications/Sentry.app/Contents/MacOS/SentryMCP\"}}}"
        let status = makeConnectorStatus(environment, definition: .cursor)
        XCTAssertEqual(
            status.connection,
            .connectedToDifferentBinary(command: "/Applications/Sentry.app/Contents/MacOS/SentryMCP")
        )
    }

    @MainActor
    func testConnectingOverAStaleEntryReplacesItAndThenVerifiesClean() {
        let environment = makeEnvironment()
        let path = "\(home)/.cursor/mcp.json"
        environment.files[path] =
            "{\n  \"mcpServers\": {\n    \"Sentry\": {\"command\": \"/Applications/Sentry.app/Contents/MacOS/SentryMCP\"}\n  }\n}"
        let outcome = makeConnector(environment).connect(.cursor, bridge: .registered)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        XCTAssertEqual(outcome.connection, .connected(command: mcpPath))
        XCTAssertFalse(environment.files[path]!.contains("/Applications/Sentry.app"))
    }

    @MainActor
    func testAMalformedConfigIsSurfacedAsUnreadableRatherThanAsNotConnected() {
        let environment = makeEnvironment()
        environment.files["\(home)/.cursor/mcp.json"] = "{\"mcpServers\": {oops}}"
        let status = makeConnectorStatus(environment, definition: .cursor)
        guard case .unreadable(_, let path) = status.connection else {
            return XCTFail("expected unreadable, got \(status.connection)")
        }
        XCTAssertEqual(path, "\(home)/.cursor/mcp.json")
    }

    // MARK: - Disconnect

    @MainActor
    func testDisconnectRemovesOnlyOurEntryAndBacksTheFileUpFirst() {
        let environment = makeEnvironment()
        let path = "\(home)/.cursor/mcp.json"
        environment.files[path] = """
        {
          "mcpServers": {
            "github": { "command": "npx" },
            "Sentry": { "command": "\(mcpPath)" },
            "filesystem": { "command": "uvx" }
          }
        }
        """
        let outcome = makeConnector(environment).disconnect(.cursor)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        XCTAssertEqual(outcome.connection, .notConnected)
        XCTAssertNotNil(outcome.backupPath)
        let written = environment.files[path]!
        XCTAssertNil(try? JSONConfigSurgeon.value(ofMember: "Sentry", at: ["mcpServers"], in: written) ?? nil)
        XCTAssertNotNil(try? JSONConfigSurgeon.value(ofMember: "github", at: ["mcpServers"], in: written) ?? nil)
        XCTAssertNotNil(try? JSONConfigSurgeon.value(ofMember: "filesystem", at: ["mcpServers"], in: written) ?? nil)
    }

    @MainActor
    func testConnectThenDisconnectRestoresTheFileExactly() {
        let environment = makeEnvironment()
        let path = "\(home)/.cursor/mcp.json"
        let original = """
        {
          "mcpServers": {
            "github": { "command": "npx" }
          }
        }
        """
        environment.files[path] = original
        let connector = makeConnector(environment)

        XCTAssertTrue(connector.connect(.cursor, bridge: .registered).succeeded)
        XCTAssertTrue(connector.disconnect(.cursor).succeeded)
        XCTAssertEqual(environment.files[path], original, "disconnect must be a clean undo of connect")
    }

    @MainActor
    func testDisconnectingWhenNothingIsConfiguredIsASuccessfulNoOp() {
        let environment = makeEnvironment()
        environment.files["\(home)/.cursor/mcp.json"] = "{\"mcpServers\": {\"github\": {\"command\": \"npx\"}}}"
        let outcome = makeConnector(environment).disconnect(.cursor)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.headline.contains("nothing to remove"))
        XCTAssertEqual(environment.writeCount, 0)
        XCTAssertEqual(environment.copyCount, 0)
    }

    @MainActor
    func testDisconnectingClaudeCodeUsesItsCLIWithTheSameScopeItConnectedWith() {
        let environment = makeEnvironment()
        environment.files["\(home)/.local/bin/claude"] = ""
        environment.commandResults["mcp remove"] = AIClientCommandResult(exitStatus: 0, standardOutput: "Removed", standardError: "")
        environment.commandResults["mcp get"] = AIClientCommandResult(exitStatus: 1, standardOutput: "", standardError: "no such server")

        let outcome = makeConnector(environment).disconnect(.claudeCode)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        let invocation = environment.invocations.first { $0.arguments.contains("remove") }
        XCTAssertNotNil(invocation)
        XCTAssertTrue(invocation!.arguments.contains("user"))
        XCTAssertEqual(environment.writeCount, 0)
    }

    @MainActor
    func testDisconnectingCodexRemovesOnlyItsTableFromConfigTOML() {
        let environment = makeEnvironment()
        let path = "\(home)/.codex/config.toml"
        environment.files[path] = """
        model = "gpt-5"

        [mcp_servers.node_repl]
        command = "node"

        [mcp_servers.Sentry]
        command = "\(mcpPath)"
        args = []
        """
        let outcome = makeConnector(environment).disconnect(.codex)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        let written = environment.files[path]!
        XCTAssertFalse(written.contains("[mcp_servers.Sentry]"))
        XCTAssertTrue(written.contains("[mcp_servers.node_repl]"))
        XCTAssertTrue(written.contains("model = \"gpt-5\""))
    }

    @MainActor
    func testDisconnectingVSCodeEditsWhicheverCandidateFileHoldsTheEntry() {
        let environment = makeEnvironment()
        let path = "\(home)/.copilot/mcp-config.json"
        environment.files[path] = "{\n  \"servers\": {\n    \"Sentry\": { \"command\": \"\(mcpPath)\" },\n    \"other\": { \"command\": \"x\" }\n  }\n}"
        let outcome = makeConnector(environment).disconnect(.vsCode)

        XCTAssertTrue(outcome.succeeded, outcome.detail)
        XCTAssertTrue(environment.files[path]!.contains("\"other\""))
        XCTAssertFalse(environment.files[path]!.contains("\"Sentry\""))
    }

    @MainActor
    func testDisconnectRefusesAMalformedFileRatherThanRewritingIt() {
        let environment = makeEnvironment()
        let path = "\(home)/.cursor/mcp.json"
        let broken = "{\"mcpServers\": {oops}}"
        environment.files[path] = broken
        let outcome = makeConnector(environment).disconnect(.cursor)

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(environment.files[path], broken)
        XCTAssertEqual(environment.writeCount, 0)
    }

    // MARK: - Catalog integrity

    func testEveryCatalogEntryCarriesAManualPathAndADocumentationLink() {
        XCTAssertEqual(AIClientDefinition.all.count, AIClientDefinition.ID.allCases.count)
        XCTAssertEqual(Set(AIClientDefinition.all.map(\.id)).count, AIClientDefinition.all.count)
        for definition in AIClientDefinition.all {
            XCTAssertFalse(definition.manualPathDescription.isEmpty, "\(definition.id) has no manual path to fall back on")
            XCTAssertNotNil(URL(string: definition.documentationURL), "\(definition.id) has no usable documentation link")
            XCTAssertFalse(definition.probes.executableNames.isEmpty && definition.probes.absolutePaths.isEmpty && definition.probes.homeRelativePaths.isEmpty,
                           "\(definition.id) can never be detected")
        }
    }

    func testEveryManualSnippetActuallyContainsTheResolvedBinaryPath() {
        let config = makeConfig()
        for definition in AIClientDefinition.all {
            let snippet: String
            if definition.manualSnippetIsTOML {
                snippet = config.tomlTableBody()
            } else {
                let shape = definition.manualSnippetShape
                snippet = config.snippetJSON(containerPath: shape.containerPath, dialect: shape.dialect)
            }
            XCTAssertTrue(
                snippet.contains(mcpPath),
                "\(definition.id)'s manual instructions must name the real binary, not a /Applications guess"
            )
        }
    }

    func testOnlyClaudeCodeHasNoConfigFileWeAreWillingToRead() {
        for definition in AIClientDefinition.all {
            if definition.id == .claudeCode {
                XCTAssertNil(definition.configFile, "~/.claude.json must not be reachable from this code at all")
            } else {
                XCTAssertNotNil(definition.configFile, "\(definition.id) needs a path for verification and manual setup")
            }
        }
    }

    func testShellQuotingSurvivesAPathWithSpacesAndAJSONBlob() {
        XCTAssertEqual(AIClientConnector.shellQuote("/Volumes/Sentry 1.0/x"), "'/Volumes/Sentry 1.0/x'")
        XCTAssertEqual(AIClientConnector.shellQuote("/usr/bin/claude"), "/usr/bin/claude")
        XCTAssertEqual(AIClientConnector.shellQuote("it's"), "'it'\\''s'")
        XCTAssertTrue(AIClientConnector.shellQuote("{\"a\": 1}").hasPrefix("'"))
    }

    @MainActor
    func testAPathWithShellMetacharactersIsPassedAsArgvAndNeverInterpreted() {
        // The app can live anywhere the user dragged it, including a folder
        // whose name contains shell syntax. Argv arrays make that inert.
        let hostile = "/Users/tester/Apps; rm -rf ~/Sentry.app/Contents/MacOS/SentryMCP"
        let environment = makeEnvironment()
        environment.files["\(home)/.local/bin/claude"] = ""
        environment.commandResults["mcp add-json"] = AIClientCommandResult(exitStatus: 0, standardOutput: "", standardError: "")
        let connector = AIClientConnector(environment: environment, config: .local(mcpBinaryPath: hostile))
        _ = connector.connect(.claudeCode, bridge: .registered)

        let invocation = environment.invocations.first { $0.arguments.contains("add-json") }
        XCTAssertNotNil(invocation)
        XCTAssertFalse(invocation!.executable.contains("sh"), "no shell may ever be involved")
        XCTAssertTrue(invocation!.arguments.contains { $0.contains(hostile) }, "the path travels as one argv element")
    }

    // MARK: - Helpers

    @MainActor
    private func makeConnectorStatus(
        _ environment: FakeAIClientEnvironment,
        definition: AIClientDefinition
    ) -> AIClientDetector.Status {
        makeConnector(environment).status(of: definition)
    }
}

// MARK: - Fake environment

/// An `AIClientEnvironment` backed entirely by dictionaries.
///
/// Every path in `files` is absolute and made up; `homeDirectory` is
/// `/Users/tester`, which does not exist on any machine this runs on, so even
/// a bug that bypassed the fake would fail loudly rather than write somewhere
/// real. Directories are modelled as entries whose value is empty — crude, but
/// exactly enough for `directoryExists` to distinguish an `.app` bundle from a
/// binary, which is the only distinction the code under test makes.
final class FakeAIClientEnvironment: AIClientEnvironment {

    var files: [String: String] = [:]
    var directories: Set<String> = []
    var unwritablePaths: Set<String> = []
    var failCopies = false
    var commandResults: [String: AIClientCommandResult] = [:]
    /// Lets a test simulate a CLI that has a side effect on the filesystem —
    /// which is how `code --add-mcp` is made to look real.
    var onRun: ((String, [String]) -> Void)?

    private(set) var writeCount = 0
    private(set) var copyCount = 0
    private(set) var createdDirectories: [String] = []
    private(set) var invocations: [(executable: String, arguments: [String])] = []

    let homeDirectory: String
    let now = Date(timeIntervalSince1970: 1_770_000_000)

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    var executableSearchPaths: [String] {
        ["\(homeDirectory)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }

    func fileExists(atPath path: String) -> Bool {
        files[path] != nil || directories.contains(path)
    }

    func directoryExists(atPath path: String) -> Bool {
        directories.contains(path)
    }

    func readText(atPath path: String) throws -> String? {
        files[path]
    }

    func writeText(_ text: String, atPath path: String) throws {
        guard !unwritablePaths.contains(path) else {
            throw NSError(domain: "FakeAIClientEnvironment", code: 13, userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        }
        files[path] = text
        writeCount += 1
    }

    func createDirectory(atPath path: String) throws {
        directories.insert(path)
        createdDirectories.append(path)
    }

    func copyItem(atPath source: String, toPath destination: String) throws {
        guard !failCopies else {
            throw NSError(domain: "FakeAIClientEnvironment", code: 28, userInfo: [NSLocalizedDescriptionKey: "no space left on device"])
        }
        guard let contents = files[source] else {
            throw NSError(domain: "FakeAIClientEnvironment", code: 2, userInfo: [NSLocalizedDescriptionKey: "no such file"])
        }
        files[destination] = contents
        copyCount += 1
    }

    func isWritable(atPath path: String) -> Bool {
        !unwritablePaths.contains(path)
    }

    /// Matched on a substring of the joined argv, so a test can stub
    /// `"mcp add-json"` without restating the whole command line.
    func run(executable: String, arguments: [String]) throws -> AIClientCommandResult {
        invocations.append((executable, arguments))
        onRun?(executable, arguments)
        let joined = arguments.joined(separator: " ")
        for (needle, result) in commandResults where joined.contains(needle) {
            return result
        }
        return AIClientCommandResult(exitStatus: 127, standardOutput: "", standardError: "command not stubbed: \(joined)")
    }
}
