#if os(macOS)
import Foundation

/// Connects and disconnects Sentry's MCP server in other applications'
/// configuration, and then checks whether it worked.
///
/// **The order of operations is the whole design, so it is stated here rather
/// than left to be reconstructed from the code.** Every write follows exactly
/// this sequence, and every step can abort the whole thing without having
/// changed anything:
///
/// 1. **Preflight the bridge.** If `SMAppService` hasn't registered Sentry's
///    command-line bridge, an MCP client can spawn `SentryMCP` perfectly and
///    still get nothing, because `SentryMCP` reaches the app through that Mach
///    service. Writing a config in that state produces a client that lists a
///    Sentry server which fails on every call — worse than no config at all,
///    because the user now has to work out that the broken thing is not the
///    thing they just clicked. So this refuses, and names the button one
///    section up that fixes it. On an unsigned or development build that
///    registration cannot succeed at all, and saying so here is the only place
///    a user would ever find out.
/// 2. **Prefer the vendor's CLI.** `claude mcp add-json`, `codex mcp add`,
///    `code --add-mcp`. They own their own schema, write atomically, and know
///    about scopes and profiles we would have to guess at.
/// 3. **Check writability before touching anything.** A file we cannot write
///    is reported as a refusal to start, not as a backup followed by a
///    failure.
/// 4. **Parse before backing up.** A malformed config is reported with the
///    parser's own complaint and the character offset, and nothing is written
///    or copied. This is not hypothetical: the machine this was developed on
///    had a `claude_desktop_config.json` containing a keyless object, left
///    behind by some other tool, that made the entire file unparseable. A
///    read-modify-write that "recovered" from that would have silently
///    discarded whatever else was in it.
/// 5. **Back up, then write.** The backup sits beside the original as
///    `<name>.sentry-backup-<timestamp>`, and its path is reported in the
///    outcome — a backup the user cannot find is not a backup.
/// 6. **Verify by re-reading.** The outcome's `connection` comes from reading
///    the file back off disk (or asking the tool), never from "the write
///    didn't throw". If the re-read disagrees, the outcome says so.
///
/// **Idempotency is structural, not a check.** Both writers replace the named
/// member/table if it is already there, so clicking Connect twice produces a
/// byte-identical file the second time; the connector notices that the text
/// didn't change and skips the backup rather than accumulating one per click.
///
/// **Never clobbering a sibling server is also structural.** Nothing here ever
/// constructs an `mcpServers` object — `JSONConfigSurgeon` splices one member
/// into whatever object is already there, and `TOMLConfigSurgeon` splices one
/// table. There is no code path that could replace the container, which is a
/// stronger guarantee than a test that it doesn't.
@MainActor
public final class AIClientConnector {

    private let environment: AIClientEnvironment
    private let config: MCPClientConfig

    public init(environment: AIClientEnvironment, config: MCPClientConfig) {
        self.environment = environment
        self.config = config
    }

    /// The convenience the app uses: real filesystem, real subprocesses, and
    /// the `SentryMCP` sitting next to this running executable.
    public static func live() -> AIClientConnector {
        AIClientConnector(
            environment: RealAIClientEnvironment(),
            config: .local(mcpBinaryPath: MCPClientConfig.mcpBinaryPath(
                appExecutablePath: MCPClientConfig.currentAppBinaryPath()
            ))
        )
    }

    /// The configuration this connector writes — exposed so the manual
    /// instructions render from the *same* value the Connect button uses, and
    /// a user who follows them by hand ends up with byte-identical content.
    public var snippetConfig: MCPClientConfig { config }

    // MARK: - Outcome

    /// What happened, in the words the pane shows.
    ///
    /// `headline` is one line; `detail` is the paragraph under it and is
    /// allowed to be long — this is a feature whose failures are all
    /// actionable, and truncating the action to fit a row would be the wrong
    /// trade. `connection` is the *re-verified* state, so the caller never has
    /// to infer "connected" from `succeeded`.
    public struct Outcome: Equatable {
        public let succeeded: Bool
        public let headline: String
        public let detail: String
        /// Where the backup went, when one was made. `nil` when nothing was
        /// backed up — because the file didn't exist, because nothing changed,
        /// or because the vendor's CLI did the writing.
        public let backupPath: String?
        /// True when the config file did not exist and was created. Surfaced
        /// separately because "we made a file in your home directory" is
        /// something a user is entitled to be told, not an implementation
        /// detail of "connected".
        public let createdFile: Bool
        public let connection: AIClientDetector.Connection

        public init(
            succeeded: Bool,
            headline: String,
            detail: String,
            backupPath: String? = nil,
            createdFile: Bool = false,
            connection: AIClientDetector.Connection
        ) {
            self.succeeded = succeeded
            self.headline = headline
            self.detail = detail
            self.backupPath = backupPath
            self.createdFile = createdFile
            self.connection = connection
        }
    }

    // MARK: - Preflight

    /// Why connecting can't work yet, or `nil` if it can.
    ///
    /// Pure and static so the view can disable buttons with the same sentence
    /// the connector would have refused with, instead of the two drifting
    /// apart into a button that is enabled and an error that says it never
    /// could have worked.
    public static func blockingReason(bridge: MCPBridgeRegistration) -> String? {
        switch bridge {
        case .registered:
            return nil
        case .awaitingApproval:
            return "macOS hasn't allowed Sentry's command-line bridge to run yet, and an AI tool can't reach Sentry without it. Open System Settings ▸ General ▸ Login Items & Extensions and switch Sentry's background item on, then come back. Connecting now would write a configuration that can't work."
        case .notRegistered:
            return "Sentry's command-line bridge isn't set up, and an AI tool reaches Sentry through it — spawning the MCP server without it produces a client that lists Sentry and fails on every call. Use “Set Up Command-Line Access…” in the section above first."
        case .unavailable(let reason):
            return "macOS won't register Sentry's command-line bridge (\(reason)), so an AI tool has no way to reach this app. This is expected on a build that wasn't signed with a Developer ID certificate. Connecting would write a configuration that can't work; the manual snippet below is still correct for a signed copy."
        }
    }

    // MARK: - Status

    public func statuses() -> [AIClientDetector.Status] {
        AIClientDetector.statuses(environment: environment, config: config)
    }

    public func status(of definition: AIClientDefinition) -> AIClientDetector.Status {
        AIClientDetector.status(of: definition, environment: environment, config: config)
    }

    // MARK: - Connect

    public func connect(_ definition: AIClientDefinition, bridge: MCPBridgeRegistration) -> Outcome {
        if let blocked = Self.blockingReason(bridge: bridge) {
            return Outcome(
                succeeded: false,
                headline: "Sentry isn't reachable yet, so it didn't write anything",
                detail: blocked,
                connection: status(of: definition).connection
            )
        }

        switch definition.mechanism {
        case .manualOnly(let reason):
            return Outcome(
                succeeded: false,
                headline: "Sentry doesn't configure \(definition.displayName) automatically",
                detail: reason,
                connection: status(of: definition).connection
            )

        case .vendorCLI(let plan):
            if let executable = AIClientDetector.locateExecutable(definition, environment: environment) {
                return connectViaCLI(definition, plan: plan, executable: executable)
            }
            guard definition.configFile != nil else {
                return Outcome(
                    succeeded: false,
                    headline: "Sentry couldn't find \(definition.displayName)'s `\(plan.executableName)` command",
                    detail: "\(definition.displayName) is configured through its own command-line tool, and Sentry looked for `\(plan.executableName)` in \(environment.executableSearchPaths.count) directories without finding it. If it's installed somewhere unusual, run this yourself:\n\n\(commandLinePreview(definition, plan: plan))",
                    connection: status(of: definition).connection
                )
            }
            // Codex: the CLI is the preferred path but its config file is
            // documented as directly editable, so a missing binary is a
            // fallback rather than a dead end.
            return connectViaFile(definition)

        case .configFile:
            return connectViaFile(definition)
        }
    }

    private func connectViaCLI(
        _ definition: AIClientDefinition,
        plan: AIClientDefinition.CLIPlan,
        executable: String
    ) -> Outcome {
        let json = plan.jsonIncludesServerName
            ? config.entryJSONIncludingName(dialect: plan.jsonDialect)
            : config.entryJSON(dialect: plan.jsonDialect)
        let arguments = plan.arguments(
            plan.addArguments,
            name: config.serverName,
            command: config.command ?? "",
            json: compact(json)
        )

        let result: AIClientCommandResult
        do {
            result = try environment.run(executable: executable, arguments: arguments)
        } catch {
            return Outcome(
                succeeded: false,
                headline: "Sentry couldn't run \(definition.displayName)'s command-line tool",
                detail: "Running `\(executable)` failed: \(error.localizedDescription)\n\nYou can run this yourself instead:\n\n\(commandLinePreview(definition, plan: plan))",
                connection: status(of: definition).connection
            )
        }

        guard result.succeeded else {
            return Outcome(
                succeeded: false,
                headline: "\(definition.displayName) refused the change",
                detail: "`\(plan.executableName) \(plan.addArguments.first ?? "")` exited with status \(result.exitStatus): \(result.failureMessage)\n\nNothing was changed. You can run this yourself to see the full output:\n\n\(commandLinePreview(definition, plan: plan))",
                connection: status(of: definition).connection
            )
        }

        let connection = status(of: definition).connection
        return verifiedOutcome(
            definition,
            connection: connection,
            successDetailPrefix: "\(definition.displayName)'s own `\(plan.executableName)` command made the change, so Sentry didn't need to edit — or back up — any file itself.",
            backupPath: nil,
            createdFile: false
        )
    }

    private func connectViaFile(_ definition: AIClientDefinition) -> Outcome {
        guard let file = definition.configFile else {
            return Outcome(
                succeeded: false,
                headline: "Sentry doesn't know where \(definition.displayName) keeps its configuration",
                detail: "Use the manual instructions below.",
                connection: status(of: definition).connection
            )
        }

        let path = writeTargetPath(for: file)

        guard environment.isWritable(atPath: path) else {
            return Outcome(
                succeeded: false,
                headline: "Sentry can't write \(definition.displayName)'s configuration",
                detail: "`\(path)` isn't writable by this app, so nothing was changed. Check its permissions (in Finder: Get Info ▸ Sharing & Permissions), or paste the snippet below into it yourself.",
                connection: status(of: definition).connection
            )
        }

        let existing: String?
        do {
            existing = try environment.readText(atPath: path)
        } catch {
            return Outcome(
                succeeded: false,
                headline: "Sentry couldn't read \(definition.displayName)'s configuration",
                detail: "`\(path)` exists but couldn't be read: \(error.localizedDescription). Nothing was changed.",
                connection: status(of: definition).connection
            )
        }

        let updated: String
        do {
            updated = try render(entryInto: existing, file: file)
        } catch {
            return Outcome(
                succeeded: false,
                headline: "\(definition.displayName)'s configuration file isn't valid, so Sentry left it alone",
                detail: "`\(path)` couldn't be parsed — \(describe(error)). Sentry won't merge into a file it can't read, because doing so would mean guessing at what the rest of it was meant to say and could discard other MCP servers you have configured.\n\nFix the file (or move it aside so the tool writes a fresh one), then click Connect again. The exact text Sentry would have added is below.",
                connection: status(of: definition).connection
            )
        }

        let fileExisted = existing != nil
        if let existing, existing == updated {
            // Second click. Nothing to write, nothing to back up.
            return verifiedOutcome(
                definition,
                connection: status(of: definition).connection,
                successDetailPrefix: "`\(path)` already had exactly this entry, so Sentry left the file untouched.",
                backupPath: nil,
                createdFile: false
            )
        }

        var backupPath: String?
        if fileExisted {
            do {
                backupPath = try makeBackup(of: path)
            } catch {
                return Outcome(
                    succeeded: false,
                    headline: "Sentry couldn't back up \(definition.displayName)'s configuration",
                    detail: "Copying `\(path)` aside failed: \(error.localizedDescription). Nothing was changed — Sentry won't edit somebody else's config file it can't first make a copy of.",
                    connection: status(of: definition).connection
                )
            }
        }

        do {
            try environment.createDirectory(atPath: (path as NSString).deletingLastPathComponent)
            try environment.writeText(updated, atPath: path)
        } catch {
            return Outcome(
                succeeded: false,
                headline: "Sentry couldn't write \(definition.displayName)'s configuration",
                detail: "Writing `\(path)` failed: \(error.localizedDescription)."
                    + (backupPath.map { "\n\nThe file was backed up to `\($0)` beforehand and hasn't been modified." } ?? ""),
                backupPath: backupPath,
                connection: status(of: definition).connection
            )
        }

        var prefix = "Sentry added its entry to `\(path)`."
        if !fileExisted {
            prefix = "`\(path)` didn't exist yet — \(definition.displayName) hadn't been run, or hadn't been given any MCP servers — so Sentry created it. It contains only Sentry's entry."
        } else if let backupPath {
            prefix += " The previous version was copied to `\(backupPath)` first."
        }

        return verifiedOutcome(
            definition,
            connection: status(of: definition).connection,
            successDetailPrefix: prefix,
            backupPath: backupPath,
            createdFile: !fileExisted
        )
    }

    // MARK: - Disconnect

    /// Removes Sentry's entry and nothing else.
    ///
    /// Not gated on the bridge preflight: a user whose bridge is broken is
    /// exactly the user most likely to want the half-working entry gone, and
    /// refusing to clean up after ourselves because a *different* subsystem is
    /// unavailable would be indefensible.
    public func disconnect(_ definition: AIClientDefinition) -> Outcome {
        switch definition.mechanism {
        case .manualOnly(let reason):
            return Outcome(
                succeeded: false,
                headline: "Sentry doesn't edit \(definition.displayName)'s configuration",
                detail: reason,
                connection: status(of: definition).connection
            )

        case .vendorCLI(let plan) where !plan.removeArguments.isEmpty:
            guard let executable = AIClientDetector.locateExecutable(definition, environment: environment) else {
                if definition.configFile != nil { return disconnectViaFile(definition) }
                return Outcome(
                    succeeded: false,
                    headline: "Sentry couldn't find \(definition.displayName)'s `\(plan.executableName)` command",
                    detail: "Run `\(plan.executableName) \(plan.arguments(plan.removeArguments, name: config.serverName, command: "", json: "").joined(separator: " "))` yourself to remove it.",
                    connection: status(of: definition).connection
                )
            }
            let arguments = plan.arguments(
                plan.removeArguments,
                name: config.serverName,
                command: config.command ?? "",
                json: ""
            )
            guard let result = try? environment.run(executable: executable, arguments: arguments) else {
                return Outcome(
                    succeeded: false,
                    headline: "Sentry couldn't run \(definition.displayName)'s command-line tool",
                    detail: "Nothing was changed.",
                    connection: status(of: definition).connection
                )
            }
            guard result.succeeded else {
                return Outcome(
                    succeeded: false,
                    headline: "\(definition.displayName) refused to remove the entry",
                    detail: "`\(plan.executableName)` exited with status \(result.exitStatus): \(result.failureMessage)",
                    connection: status(of: definition).connection
                )
            }
            return removalOutcome(definition, backupPath: nil, target: "\(definition.displayName)'s own configuration")

        case .vendorCLI, .configFile:
            // VS Code lands here: `code` has no `--remove-mcp`, so the entry is
            // taken back out of whichever candidate file it is actually in.
            return disconnectViaFile(definition)
        }
    }

    private func disconnectViaFile(_ definition: AIClientDefinition) -> Outcome {
        guard let file = definition.configFile else {
            return Outcome(
                succeeded: false,
                headline: "Sentry doesn't know where \(definition.displayName) keeps its configuration",
                detail: "Remove the entry by hand — see the path below.",
                connection: status(of: definition).connection
            )
        }

        for path in file.location.resolved(home: environment.homeDirectory) {
            guard let text = (try? environment.readText(atPath: path)) ?? nil else { continue }

            let updated: String?
            do {
                updated = try renderRemoval(from: text, file: file)
            } catch {
                return Outcome(
                    succeeded: false,
                    headline: "\(definition.displayName)'s configuration file isn't valid, so Sentry left it alone",
                    detail: "`\(path)` couldn't be parsed — \(describe(error)). Remove Sentry's entry by hand.",
                    connection: status(of: definition).connection
                )
            }
            guard let updated else { continue }

            guard environment.isWritable(atPath: path) else {
                return Outcome(
                    succeeded: false,
                    headline: "Sentry can't write \(definition.displayName)'s configuration",
                    detail: "Sentry's entry is in `\(path)`, but that file isn't writable by this app. Nothing was changed.",
                    connection: status(of: definition).connection
                )
            }

            let backupPath: String?
            do {
                backupPath = try makeBackup(of: path)
            } catch {
                return Outcome(
                    succeeded: false,
                    headline: "Sentry couldn't back up \(definition.displayName)'s configuration",
                    detail: "Copying `\(path)` aside failed: \(error.localizedDescription). Nothing was changed.",
                    connection: status(of: definition).connection
                )
            }

            do {
                try environment.writeText(updated, atPath: path)
            } catch {
                return Outcome(
                    succeeded: false,
                    headline: "Sentry couldn't write \(definition.displayName)'s configuration",
                    detail: "Writing `\(path)` failed: \(error.localizedDescription). The previous version is at `\(backupPath ?? path)`.",
                    backupPath: backupPath,
                    connection: status(of: definition).connection
                )
            }
            return removalOutcome(definition, backupPath: backupPath, target: "`\(path)`")
        }

        return Outcome(
            succeeded: true,
            headline: "There was nothing to remove",
            detail: "Sentry has no entry in \(definition.displayName)'s configuration.",
            connection: status(of: definition).connection
        )
    }

    private func removalOutcome(_ definition: AIClientDefinition, backupPath: String?, target: String) -> Outcome {
        let connection = status(of: definition).connection
        let backupNote = backupPath.map { " The previous version was copied to `\($0)` first." } ?? ""
        switch connection {
        case .notConnected, .unverifiable:
            return Outcome(
                succeeded: true,
                headline: "Disconnected from \(definition.displayName)",
                detail: "Sentry's entry was removed from \(target); every other MCP server there was left exactly as it was.\(backupNote)",
                backupPath: backupPath,
                connection: connection
            )
        default:
            return Outcome(
                succeeded: false,
                headline: "Sentry removed its entry, but \(definition.displayName) still reports it",
                detail: "The change was written to \(target), but reading it back still finds a Sentry entry. There may be a second one — a project-level config, or a copy in another profile.\(backupNote)",
                backupPath: backupPath,
                connection: connection
            )
        }
    }

    // MARK: - Verification

    /// Turns a re-read connection state into the outcome the pane shows.
    ///
    /// The `succeeded` flag comes from what was read back, never from whether
    /// the write threw. A write that lands in a file the tool doesn't read
    /// (VS Code and its profiles) reports `unverifiable` and says so, which is
    /// the honest answer and is deliberately not dressed up as a tick.
    private func verifiedOutcome(
        _ definition: AIClientDefinition,
        connection: AIClientDetector.Connection,
        successDetailPrefix: String,
        backupPath: String?,
        createdFile: Bool
    ) -> Outcome {
        let note = definition.afterConnectingNote.map { "\n\n\($0)" } ?? ""
        switch connection {
        case .connected(let command):
            return Outcome(
                succeeded: true,
                headline: "Connected to \(definition.displayName)",
                detail: "\(successDetailPrefix) Reading it back confirms \(definition.displayName) is now pointed at `\(command)`.\(note)",
                backupPath: backupPath,
                createdFile: createdFile,
                connection: connection
            )
        case .connectedToDifferentBinary(let command):
            return Outcome(
                succeeded: false,
                headline: "\(definition.displayName) is pointed at a different Sentry",
                detail: "\(successDetailPrefix) But reading it back finds `\(command)`, not this copy of Sentry. Something else is also writing this configuration, or there's a second entry taking precedence.",
                backupPath: backupPath,
                createdFile: createdFile,
                connection: connection
            )
        case .notConnected:
            return Outcome(
                succeeded: false,
                headline: "\(definition.displayName) doesn't show the entry",
                detail: "\(successDetailPrefix) But reading it back finds no Sentry entry, so the change didn't take. Use the manual instructions below.",
                backupPath: backupPath,
                createdFile: createdFile,
                connection: connection
            )
        case .unreadable(let problem, let path):
            return Outcome(
                succeeded: false,
                headline: "Sentry can't confirm the change",
                detail: "\(successDetailPrefix) But `\(path)` can't be read back: \(problem).",
                backupPath: backupPath,
                createdFile: createdFile,
                connection: connection
            )
        case .unverifiable(let reason):
            return Outcome(
                succeeded: true,
                headline: "\(definition.displayName) accepted the change — Sentry couldn't confirm it",
                detail: "\(successDetailPrefix) \(reason)\(note)",
                backupPath: backupPath,
                createdFile: createdFile,
                connection: connection
            )
        }
    }

    // MARK: - Rendering

    private func render(entryInto existing: String?, file: AIClientDefinition.ConfigFile) throws -> String {
        switch file.format {
        case .json(let containerPath, let dialect):
            return try JSONConfigSurgeon.upsert(
                member: config.serverName,
                value: config.entryJSON(dialect: dialect),
                at: containerPath,
                in: existing
            )
        case .toml(let tablePath):
            return try TOMLConfigSurgeon.upsert(
                table: tablePath,
                body: config.tomlTableBody(),
                in: existing
            )
        }
    }

    private func renderRemoval(from text: String, file: AIClientDefinition.ConfigFile) throws -> String? {
        switch file.format {
        case .json(let containerPath, _):
            return try JSONConfigSurgeon.remove(member: config.serverName, at: containerPath, in: text)
        case .toml(let tablePath):
            return try TOMLConfigSurgeon.remove(table: tablePath, in: text)
        }
    }

    /// The path a write targets: the first candidate that exists, else the
    /// first candidate outright. For a single-location tool the two are the
    /// same; for VS Code this is what stops a second profile's file being
    /// created next to the one already in use.
    private func writeTargetPath(for file: AIClientDefinition.ConfigFile) -> String {
        let candidates = file.location.resolved(home: environment.homeDirectory)
        return candidates.first { environment.fileExists(atPath: $0) } ?? candidates[0]
    }

    // MARK: - Backups

    /// Copies `path` aside, returning where it went.
    ///
    /// Beside the original rather than in a Sentry-owned folder: same volume
    /// (so the copy can't fail for space on a different disk), same
    /// permissions, and — the real reason — a user who wants to undo this will
    /// look in the directory they know, not in a container path they'd have to
    /// be told about.
    ///
    /// The timestamp means repeated connects don't overwrite each other's
    /// backups, which matters because the interesting backup is usually the
    /// *first* one, not the most recent.
    private func makeBackup(of path: String) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let destination = path + ".sentry-backup-" + formatter.string(from: environment.now)
        try environment.copyItem(atPath: path, toPath: destination)
        return destination
    }

    // MARK: - Text helpers

    /// Collapses rendered JSON to one line for passing as a single argv
    /// element. Purely cosmetic for the receiving CLI, but it keeps the
    /// command preview below copy-pasteable into a terminal.
    private func compact(_ json: String) -> String {
        json.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .replacingOccurrences(of: "{ ", with: "{")
            .replacingOccurrences(of: " }", with: "}")
    }

    /// The exact command the user could run themselves — the manual fallback
    /// for a CLI-driven client, quoted so it survives a paste into a shell.
    public func commandLinePreview(_ definition: AIClientDefinition, plan: AIClientDefinition.CLIPlan) -> String {
        let json = plan.jsonIncludesServerName
            ? config.entryJSONIncludingName(dialect: plan.jsonDialect)
            : config.entryJSON(dialect: plan.jsonDialect)
        let arguments = plan.arguments(
            plan.addArguments,
            name: config.serverName,
            command: config.command ?? "",
            json: compact(json)
        )
        return ([plan.executableName] + arguments.map(Self.shellQuote)).joined(separator: " ")
    }

    /// Single-quote for `sh`, the only quoting that needs no knowledge of what
    /// is inside — a JSON blob full of double quotes and braces would need
    /// escaping under any other scheme.
    /// `nonisolated` because it is a pure string transform with no business
    /// borrowing this class's main-actor isolation — and because a test that
    /// has to hop to the main actor to check quoting is testing the wrong
    /// thing.
    nonisolated static func shellQuote(_ argument: String) -> String {
        if !argument.isEmpty,
           argument.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_./:=".unicodeScalars.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func describe(_ error: Error) -> String {
        if let failure = error as? JSONConfigSurgeon.Failure { return failure.description }
        if let failure = error as? TOMLConfigSurgeon.Failure { return failure.description }
        return error.localizedDescription
    }
}
#endif
