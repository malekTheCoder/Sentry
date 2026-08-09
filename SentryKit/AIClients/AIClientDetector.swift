#if os(macOS)
import Foundation

/// Works out which of `AIClientCatalog`'s tools are actually on this Mac, and
/// — for each one — whether Sentry is already registered with it.
///
/// **Both halves answer from evidence, never from memory.** There is no
/// "we clicked Connect once so it must be connected" flag anywhere in this
/// feature: `status(of:)` re-reads the tool's config file, or asks the tool
/// itself, every single time. That is the difference between a pane that
/// reports what it did and a pane that reports what is true, and only the
/// second one is worth putting a tick next to. It also means the pane gets the
/// interesting cases for free — an entry the user deleted by hand, an entry
/// pointing at a copy of Sentry.app they since moved to the Trash, a config
/// file that has become unparseable — all of which show up as themselves
/// rather than as a stale green tick.
///
/// **Why detection is deliberately generous and reports its reason.** Missing
/// a tool that is installed is the expensive failure (the user concludes the
/// feature doesn't support their setup and stops looking), while a false
/// positive is cheap and self-correcting (the Connect button runs, fails, and
/// says exactly why). So any one probe hitting is enough — the executable on a
/// generously-defined search path, an app bundle in either `/Applications` or
/// `~/Applications`, or a config directory implying the tool has run at least
/// once. The probe that fired is recorded and shown, so "detected" is a claim
/// the user can check rather than one they have to take on trust.
public enum AIClientDetector {

    /// One tool's full state, as the view renders it.
    public struct Status: Identifiable, Equatable {
        public let definition: AIClientDefinition
        public let detection: Detection
        public let connection: Connection

        public var id: AIClientDefinition.ID { definition.id }
        public var isDetected: Bool {
            if case .found = detection { return true }
            return false
        }

        public init(definition: AIClientDefinition, detection: Detection, connection: Connection) {
            self.definition = definition
            self.detection = detection
            self.connection = connection
        }
    }

    public enum Detection: Equatable {
        /// `evidence` is the literal thing found, e.g. an absolute path. Shown
        /// verbatim so "detected" is falsifiable.
        case found(evidence: String)
        case notFound
    }

    public enum Connection: Equatable {
        /// Sentry is registered and points at the binary we would write.
        case connected(command: String)

        /// Registered, but at a different path — the user moved or reinstalled
        /// the app, or pasted the old hardcoded `/Applications` snippet. Its
        /// own state because the fix (click Connect, which replaces it) is
        /// different from both "connected" and "not connected", and because
        /// silently reporting it as connected would leave an MCP client
        /// failing to spawn a binary with nothing on screen to explain it.
        case connectedToDifferentBinary(command: String)

        /// Nothing of ours in the config.
        case notConnected

        /// The config exists but we could not read it — malformed JSON,
        /// unreadable permissions. Carries the problem verbatim, and this
        /// state is what stops Connect: writing into a file we cannot parse is
        /// exactly how a user's configuration gets destroyed.
        case unreadable(problem: String, path: String)

        /// We wrote through a vendor CLI that gave us no way to check, or a
        /// tool's file location depends on state we can't see. Explicitly not
        /// a claim of success.
        case unverifiable(reason: String)
    }

    // MARK: - Detection

    /// Every tool in the catalog, detected and status-checked, in catalog
    /// order. Detected tools sort first in the view, not here — this stays a
    /// straight mapping so a test can assert on the whole list.
    public static func statuses(
        environment: AIClientEnvironment,
        config: MCPClientConfig
    ) -> [Status] {
        AIClientDefinition.all.map { status(of: $0, environment: environment, config: config) }
    }

    public static func status(
        of definition: AIClientDefinition,
        environment: AIClientEnvironment,
        config: MCPClientConfig
    ) -> Status {
        let detection = detect(definition, environment: environment)
        let connection = connection(of: definition, environment: environment, config: config)
        return Status(definition: definition, detection: detection, connection: connection)
    }

    /// Is the tool here at all?
    public static func detect(
        _ definition: AIClientDefinition,
        environment: AIClientEnvironment
    ) -> Detection {
        if let executable = locateExecutable(definition, environment: environment) {
            return .found(evidence: executable)
        }
        for path in definition.probes.absolutePaths where environment.fileExists(atPath: path) {
            return .found(evidence: path)
        }
        for relative in definition.probes.homeRelativePaths {
            let path = (environment.homeDirectory as NSString).appendingPathComponent(relative)
            if environment.fileExists(atPath: path) {
                return .found(evidence: path)
            }
        }
        return .notFound
    }

    /// The vendor CLI's absolute path, or `nil`.
    ///
    /// Checks `additionalExecutablePaths` too, which is what stops a Mac with
    /// the Codex desktop app — where the binary lives inside the bundle and is
    /// routinely absent from `$PATH` — from being told Codex isn't installed
    /// while its icon sits in the Dock.
    public static func locateExecutable(
        _ definition: AIClientDefinition,
        environment: AIClientEnvironment
    ) -> String? {
        guard case .vendorCLI(let plan) = definition.mechanism else {
            // Non-CLI tools still get their names probed for detection —
            // `cursor-agent` proves Cursor is installed even though we never
            // run it.
            for name in definition.probes.executableNames {
                if let found = search(name, environment: environment) { return found }
            }
            return nil
        }
        if let found = search(plan.executableName, environment: environment) { return found }
        for path in plan.additionalExecutablePaths where environment.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    private static func search(_ name: String, environment: AIClientEnvironment) -> String? {
        for directory in environment.executableSearchPaths {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if environment.fileExists(atPath: candidate), !environment.directoryExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Connection

    /// Reads the tool's own configuration (or asks the tool) and reports what
    /// it actually says about Sentry.
    public static func connection(
        of definition: AIClientDefinition,
        environment: AIClientEnvironment,
        config: MCPClientConfig
    ) -> Connection {
        if case .manualOnly = definition.mechanism {
            // Windsurf. We still *read* its file — refusing to write is not a
            // reason to refuse to tell the user what's there, and somebody who
            // pasted the snippet by hand should see a tick.
            if let file = definition.configFile {
                return connectionFromConfigFile(file, environment: environment, config: config)
            }
            return .unverifiable(reason: "Sentry doesn't write this tool's configuration, so it can't check it either.")
        }

        if let file = definition.configFile {
            let result = connectionFromConfigFile(file, environment: environment, config: config)
            // For VS Code the candidate list is a guess at where its active
            // profile keeps the file, so "not in any of them" is genuinely
            // "we don't know", not "not connected".
            if case .notConnected = result, case .candidatesUnderHome = file.location {
                return .unverifiable(
                    reason: "VS Code stores this inside whichever profile is active, and Sentry's entry isn't in either of the two locations it can check. Run “MCP: Open User Configuration” to see the file VS Code is really using."
                )
            }
            return result
        }

        guard case .vendorCLI(let plan) = definition.mechanism, !plan.verifyArguments.isEmpty else {
            return .unverifiable(reason: "This tool offers no way to check what it's configured with.")
        }
        guard let executable = locateExecutable(definition, environment: environment) else {
            return .notConnected
        }
        let arguments = plan.arguments(
            plan.verifyArguments,
            name: config.serverName,
            command: config.command ?? "",
            json: ""
        )
        guard let result = try? environment.run(executable: executable, arguments: arguments) else {
            return .unverifiable(reason: "Sentry couldn't run `\(plan.executableName)` to check.")
        }
        guard result.succeeded else { return .notConnected }
        let combined = result.standardOutput + result.standardError
        if let expected = config.command, combined.contains(expected) {
            return .connected(command: expected)
        }
        if let found = firstPathLikeToken(in: combined, endingWith: "SentryMCP") {
            return .connectedToDifferentBinary(command: found)
        }
        // Registered under our name, but its output didn't include a path we
        // recognise. Registered is registered; say so without inventing a
        // command we didn't see.
        return .connected(command: config.command ?? config.serverName)
    }

    private static func connectionFromConfigFile(
        _ file: AIClientDefinition.ConfigFile,
        environment: AIClientEnvironment,
        config: MCPClientConfig
    ) -> Connection {
        for path in file.location.resolved(home: environment.homeDirectory) {
            let text: String?
            do {
                text = try environment.readText(atPath: path)
            } catch {
                return .unreadable(problem: error.localizedDescription, path: path)
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            do {
                let found: String?
                switch file.format {
                case .json(let containerPath, _):
                    found = try JSONConfigSurgeon.value(
                        ofMember: config.serverName,
                        at: containerPath,
                        in: text
                    )
                case .toml(let tablePath):
                    found = try TOMLConfigSurgeon.table(at: tablePath, in: text)
                }
                guard let found else { continue }
                if let expected = config.command, found.contains(expected) {
                    return .connected(command: expected)
                }
                if let other = firstPathLikeToken(in: found, endingWith: "SentryMCP") {
                    return .connectedToDifferentBinary(command: other)
                }
                return .connectedToDifferentBinary(command: "an entry Sentry doesn't recognise")
            } catch let failure as JSONConfigSurgeon.Failure {
                return .unreadable(problem: failure.description, path: path)
            } catch let failure as TOMLConfigSurgeon.Failure {
                return .unreadable(problem: failure.description, path: path)
            } catch {
                return .unreadable(problem: error.localizedDescription, path: path)
            }
        }
        return .notConnected
    }

    /// Pulls a `…/SentryMCP` path out of arbitrary CLI output or a config
    /// fragment, so "connected, but to a Sentry somewhere else" can name the
    /// somewhere else.
    ///
    /// Character scanning rather than `NSRegularExpression`: the input is a
    /// few hundred bytes, the pattern is "a run of non-quote non-space
    /// characters ending in this suffix", and a regex here would be harder to
    /// read than the loop and no more correct.
    static func firstPathLikeToken(in text: String, endingWith suffix: String) -> String? {
        let separators = CharacterSet(charactersIn: " \t\n\r\"',()[]{}")
        for token in text.components(separatedBy: separators).filter({ !$0.isEmpty })
        where token.hasSuffix(suffix) && token.contains("/") {
            return token
        }
        return nil
    }
}
#endif
