import Foundation

/// The one description of "how a client reaches Sentry's MCP server", and the
/// only place its JSON/TOML rendering is written.
///
/// **Why this type exists at all.** The config snippet used to be a string
/// literal inside `AIAccessPane.mcpConfigJSON()`, which was fine while the
/// only thing the app did with it was put it on the clipboard. The moment a
/// Connect button started *writing* the same content into somebody else's
/// file, a second copy of that literal would have been a second source of
/// truth — and the first symptom of them drifting apart would be a pane that
/// says "connected" because it wrote entry A and verified against entry B, or
/// a user whose clipboard snippet and whose actual file disagree about the
/// binary path. So the literal moved here, `AIAccessPane` now renders through
/// it, and both the writer and the verifier read the same value.
///
/// **Why the binary path is computed, never hardcoded.** `SentryMCP` is a
/// sibling executable inside `Sentry.app/Contents/MacOS/`, and the app is not
/// necessarily in `/Applications`: it can be running from `~/Downloads`, from
/// `~/Applications`, from a still-mounted DMG, or from a build products
/// directory during development. Writing `/Applications/Sentry.app/…` into a
/// user's config — which is what this repo's shipped
/// `integrations/claude-code/plugin/.mcp.json` still does, with a README
/// paragraph admitting it — produces a config that points at nothing and an
/// MCP client that reports a spawn failure the user has no way to connect
/// back to us. Deriving it from the running executable's own path is both
/// correct in every one of those locations and self-correcting if the user
/// later moves the app and clicks Connect again.
///
/// Pure and `Sendable`: no `Bundle`, no `FileManager`, no I/O. The caller
/// supplies the executable path (`MCPClientConfig.currentAppBinaryPath()` is
/// the convenience that reads `Bundle.main`), which is what lets the whole
/// write-and-verify pipeline be tested against fabricated paths.
public struct MCPClientConfig: Equatable, Sendable {

    /// How a client is told to reach Sentry.
    public enum Transport: Equatable, Sendable {
        /// The client spawns `SentryMCP` and talks stdio. This is the normal
        /// case and the only one a Connect button writes.
        case stdio(command: String, args: [String])
        /// The client connects to `MCPRemoteServer` over HTTP with a bearer
        /// token — the shape a web-based or containerised client needs, and
        /// the second literal `AIAccessPane` used to carry.
        case http(url: String, bearerToken: String)
    }

    /// The key the entry is filed under in the client's config.
    ///
    /// Capital-S `Sentry` for the local/stdio entry, matching what every
    /// previous build of this pane put on the clipboard and what any user who
    /// already pasted it by hand has in their file — so the first Connect
    /// click on such a machine *replaces* their manual entry instead of
    /// sitting next to it as a near-duplicate.
    public let serverName: String
    public let transport: Transport

    public init(serverName: String, transport: Transport) {
        self.serverName = serverName
        self.transport = transport
    }

    /// The local stdio configuration: the one Connect writes.
    public static func local(mcpBinaryPath: String, serverName: String = "Sentry") -> MCPClientConfig {
        MCPClientConfig(serverName: serverName, transport: .stdio(command: mcpBinaryPath, args: []))
    }

    /// The LAN/HTTP configuration, for a client that cannot spawn a local
    /// subprocess.
    public static func remote(url: String, apiKey: String, serverName: String = "Sentry-Remote") -> MCPClientConfig {
        MCPClientConfig(serverName: serverName, transport: .http(url: url, bearerToken: apiKey))
    }

    /// The command a stdio entry runs, or `nil` for an HTTP one — what
    /// verification compares a re-read config file against.
    public var command: String? {
        if case .stdio(let command, _) = transport { return command }
        return nil
    }

    // MARK: - Rendering

    /// Whether the rendered entry carries an explicit `"type"` discriminator.
    ///
    /// **This is not cosmetic and the answer is not the same for every
    /// client.** Cursor's reference table marks `type` *required* for a stdio
    /// server, and VS Code's schema requires it outright, so omitting it is
    /// writing something the vendor documents as invalid. Claude Desktop, Zed
    /// and Codex, meanwhile, have no `type` field at all in their schemas and
    /// infer the transport from the presence of `command` — and an unknown key
    /// in a config a strict validator reads is exactly the kind of thing that
    /// starts being rejected in a later release. So the renderer is told which
    /// dialect it is writing rather than picking one and hoping; the
    /// per-client answer lives in `AIClientCatalog`, next to the citation for
    /// it.
    public enum EntryDialect: Equatable, Sendable {
        /// Emit `"type": "stdio"` / `"type": "http"`. Cursor, VS Code.
        case explicitType
        /// Emit only the transport's own fields. Claude Desktop, Zed, Codex.
        case inferredType
    }

    /// Just the entry's value, as JSON: what gets spliced in as
    /// `"Sentry": <this>`.
    public func entryJSON(dialect: EntryDialect = .explicitType) -> String {
        switch transport {
        case .stdio(let command, let args):
            let argsJSON = args.isEmpty ? "[]" : "[" + args.map { "\"\(Self.escape($0))\"" }.joined(separator: ", ") + "]"
            let typeLine = dialect == .explicitType ? "  \"type\": \"stdio\",\n" : ""
            return """
            {
            \(typeLine)  "command": "\(Self.escape(command))",
              "args": \(argsJSON)
            }
            """
        case .http(let url, let token):
            let typeLine = dialect == .explicitType ? "  \"type\": \"http\",\n" : ""
            return """
            {
            \(typeLine)  "url": "\(Self.escape(url))",
              "headers": {
                "Authorization": "Bearer \(Self.escape(token))"
              }
            }
            """
        }
    }

    /// `entryJSON`, with the server's own name folded in as a `"name"` member
    /// — the shape `code --add-mcp` wants, where the object stands alone
    /// rather than hanging off a key.
    ///
    /// Built by splicing into the rendered entry rather than by a second
    /// literal, for the same one-source-of-truth reason this whole type
    /// exists: if the entry ever gains a field, this shape gains it too,
    /// without anybody remembering to.
    public func entryJSONIncludingName(dialect: EntryDialect = .explicitType) -> String {
        (try? JSONConfigSurgeon.upsert(
            member: "name",
            value: "\"\(Self.escape(serverName))\"",
            at: [],
            in: entryJSON(dialect: dialect)
        )) ?? entryJSON(dialect: dialect)
    }

    /// The whole snippet a user pastes by hand, wrapped in whatever container
    /// key the target client uses — `mcpServers` for Claude Desktop and
    /// Cursor, `servers` for VS Code, and so on. This is what the Copy button
    /// puts on the clipboard, so it is deliberately the *same* renderer the
    /// writer uses one level down: a user who pastes it by hand ends up with
    /// byte-identical content to a user who clicked Connect.
    public func snippetJSON(containerPath: [String], dialect: EntryDialect = .explicitType) -> String {
        var body = "\"\(serverName)\": " + JSONConfigSurgeon.reindent(
            entryJSON(dialect: dialect),
            to: String(repeating: "  ", count: containerPath.count + 1)
        )
        for (depth, key) in containerPath.enumerated().reversed() {
            let indent = String(repeating: "  ", count: depth + 2)
            let closing = String(repeating: "  ", count: depth + 1)
            body = "\"\(key)\": {\n" + indent + body + "\n" + closing + "}"
        }
        return "{\n  " + body + "\n}"
    }

    /// The body of a TOML table (no header line) — Codex's shape.
    ///
    /// `args` is written even when empty. Codex's own `mcp add` writes it, and
    /// a table that differs from the CLI's output only by an absent default
    /// makes the "did the CLI or did we write this?" question harder to answer
    /// than it needs to be.
    public func tomlTableBody() -> String {
        switch transport {
        case .stdio(let command, let args):
            let argsTOML = "[" + args.map { "\"\(Self.escape($0))\"" }.joined(separator: ", ") + "]"
            return "command = \"\(Self.escape(command))\"\nargs = \(argsTOML)"
        case .http(let url, let token):
            return "url = \"\(Self.escape(url))\"\nbearer_token = \"\(Self.escape(token))\""
        }
    }

    /// Backslash and quote escaping, shared by both renderers. Deliberately
    /// minimal: these values are filesystem paths and URLs, and a path
    /// containing a control character is not a case worth encoding badly for.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Locating SentryMCP

    /// `SentryMCP`'s absolute path, derived from `appExecutablePath` — the
    /// path of `Sentry.app/Contents/MacOS/Sentry`, whose directory `SentryMCP`
    /// shares (see `project.yml`'s `SentryMCP` target, `type: tool`, copied
    /// into the app's `MacOS` directory).
    ///
    /// Falls back to the `/Applications` guess only when there is no
    /// executable path at all, which in practice means a unit-test host or a
    /// SwiftUI preview. A wrong-but-plausible path is better there than a
    /// crash, and no Connect button is reachable from either.
    public static func mcpBinaryPath(appExecutablePath: String?) -> String {
        guard let appExecutablePath else {
            return "/Applications/Sentry.app/Contents/MacOS/SentryMCP"
        }
        let directory = (appExecutablePath as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent("SentryMCP")
    }

    /// The running process's own executable path. Split out so every caller
    /// above it can be handed a fabricated one in tests.
    public static func currentAppBinaryPath() -> String? {
        Bundle.main.executablePath
    }
}
