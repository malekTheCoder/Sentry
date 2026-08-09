#if os(macOS)
import Foundation

/// Every AI coding tool Sentry knows how to connect itself to, and the exact
/// facts needed to do it: where the tool lives, where its config lives, what
/// dialect that config speaks, and whether the vendor ships a CLI that should
/// be driven instead of writing the file by hand.
///
/// **Why a catalog of values rather than a protocol with seven conformers.**
/// The differences between these tools are entirely *data* — a path, a key
/// name, whether `"type"` is required — and none of them is behaviour. A
/// protocol would have produced seven near-identical types whose only content
/// was a handful of constants, and would have hidden the one thing a reader of
/// this file actually needs, which is the ability to see all seven side by
/// side and check them against the vendor docs. Every entry below carries the
/// URL its facts came from, because these move: three of the seven changed
/// documented location or ownership within the last year, and the next person
/// to check them should not have to re-derive where to look.
///
/// **Why "not detected" is a state and not an omission.** A pane that shows
/// only what it found tells a user nothing about what it *would* have found.
/// Somebody who has Cursor installed under a name we didn't probe, or who is
/// deciding whether installing Codex is worth it, needs to see the whole list.
/// So `AIClientDetector` returns a row for every case here, and the view
/// renders the undetected ones greyed with their manual path still visible.
public struct AIClientDefinition: Identifiable, Sendable, Equatable {

    public enum ID: String, CaseIterable, Sendable {
        case claudeCode
        case codex
        case cursor
        case claudeDesktop
        case vsCode
        case zed
        case windsurf
    }

    /// How the entry gets into the tool's configuration.
    ///
    /// Deliberately separate from `configFile` below. The two answer different
    /// questions — "how do we write it" and "where does it end up" — and for
    /// three of these seven tools the answers differ: Codex is written through
    /// its CLI but *verified* by re-reading its TOML, and VS Code is written
    /// through its CLI into a file whose path we can only guess at afterwards.
    /// Folding the location into the mechanism, which is what the first
    /// version of this type did, made those cases unrepresentable and pushed
    /// them into special-casing at the call site.
    public enum Mechanism: Sendable, Equatable {

        /// Drive the vendor's own CLI. Preferred wherever one exists: the CLI
        /// owns the file's schema, writes it atomically, knows about scopes
        /// and profiles we would have to guess at, and — most importantly —
        /// keeps working when the vendor changes the format underneath us.
        case vendorCLI(CLIPlan)

        /// Splice the entry into `configFile` ourselves.
        case configFile

        /// We know where it goes and can show it, but we will not write it.
        /// The reason is displayed verbatim next to the manual instructions —
        /// a refusal without a reason reads as a bug.
        case manualOnly(reason: String)
    }

    /// A config file's location and dialect: what gets spliced, what gets
    /// re-read to verify, and what the manual instructions name.
    ///
    /// `nil` on `claudeCode` alone, and that absence is the point — see that
    /// entry's comment. There is no path there we are willing to read *or*
    /// write, so there must be no way to express one.
    public struct ConfigFile: Sendable, Equatable {

        public enum Format: Sendable, Equatable {
            /// JSON or JSONC, with the entry nested under `containerPath`.
            case json(containerPath: [String], dialect: MCPClientConfig.EntryDialect)
            /// TOML, with the entry as the table named by `tablePath`.
            case toml(tablePath: [String])
        }

        public let location: ConfigLocation
        public let format: Format

        public init(location: ConfigLocation, format: Format) {
            self.location = location
            self.format = format
        }
    }

    /// Where a config file is, when we have to find it ourselves.
    public enum ConfigLocation: Sendable, Equatable {
        /// Exactly one path, relative to the user's home directory.
        case underHome(String)
        /// Several possible paths — the tool's own location depends on state
        /// we cannot see (VS Code's active profile). The first that exists is
        /// read; the first in the list is written if none exists.
        case candidatesUnderHome([String])

        public func resolved(home: String) -> [String] {
            switch self {
            case .underHome(let relative):
                return [(home as NSString).appendingPathComponent(relative)]
            case .candidatesUnderHome(let relatives):
                return relatives.map { (home as NSString).appendingPathComponent($0) }
            }
        }
    }

    /// The three vendor CLI invocations, as argv templates.
    ///
    /// Argv arrays, never a shell string: the `SentryMCP` path is
    /// user-controlled in the sense that it is wherever they dragged the app,
    /// and building `sh -c "claude mcp add … \(path)"` would make a directory
    /// named `Sentry;rm -rf ~` into a command injection. `Process` with
    /// `arguments:` never goes near a shell.
    public struct CLIPlan: Sendable, Equatable {
        /// The tool's executable, by name for a PATH lookup.
        public let executableName: String
        /// Absolute fallbacks probed when the name isn't on PATH — the Codex
        /// case, where the binary ships inside an app bundle and a
        /// PATH-only check produces a false "not installed".
        public let additionalExecutablePaths: [String]
        /// Argv after the executable, with `{{name}}`, `{{command}}` and
        /// `{{json}}` substituted.
        public let addArguments: [String]
        /// Empty when the vendor CLI has no removal subcommand, in which case
        /// `AIClientConnector` falls back to editing `configFile`. Only VS
        /// Code is in that position.
        public let removeArguments: [String]
        /// Asks the tool itself whether the server is registered. Exit zero is
        /// the signal; stdout is searched for the binary path so the pane can
        /// show *which* Sentry it found. Empty when the tool offers no such
        /// query and verification has to read `configFile` instead.
        public let verifyArguments: [String]
        /// The dialect for the `{{json}}` substitution — see
        /// `MCPClientConfig.EntryDialect`. Claude Code documents `type` as
        /// optional and infers stdio from `command`; VS Code requires it.
        public let jsonDialect: MCPClientConfig.EntryDialect
        /// VS Code alone: `code --add-mcp` takes the server's name as a
        /// `"name"` key *inside* the object rather than as the key the object
        /// hangs off, because there is no surrounding object. One boolean is a
        /// smaller price than a second renderer or an `if id == .vsCode` in
        /// the connector.
        public let jsonIncludesServerName: Bool

        public init(
            executableName: String,
            additionalExecutablePaths: [String] = [],
            addArguments: [String],
            removeArguments: [String],
            verifyArguments: [String],
            jsonDialect: MCPClientConfig.EntryDialect = .inferredType,
            jsonIncludesServerName: Bool = false
        ) {
            self.executableName = executableName
            self.additionalExecutablePaths = additionalExecutablePaths
            self.addArguments = addArguments
            self.removeArguments = removeArguments
            self.verifyArguments = verifyArguments
            self.jsonDialect = jsonDialect
            self.jsonIncludesServerName = jsonIncludesServerName
        }

        /// Substitutes the placeholders. Kept here rather than at the call
        /// site so the templates above stay readable as commands.
        public func arguments(_ template: [String], name: String, command: String, json: String) -> [String] {
            template.map {
                $0.replacingOccurrences(of: "{{name}}", with: name)
                    .replacingOccurrences(of: "{{command}}", with: command)
                    .replacingOccurrences(of: "{{json}}", with: json)
            }
        }
    }

    /// Evidence that the tool is on this Mac at all.
    public struct DetectionProbes: Sendable, Equatable {
        /// Executable names looked up on `PATH`.
        public let executableNames: [String]
        /// Absolute paths (app bundles, bundled binaries) tested directly.
        public let absolutePaths: [String]
        /// Paths relative to home whose existence implies the tool has run.
        public let homeRelativePaths: [String]

        public init(executableNames: [String] = [], absolutePaths: [String] = [], homeRelativePaths: [String] = []) {
            self.executableNames = executableNames
            self.absolutePaths = absolutePaths
            self.homeRelativePaths = homeRelativePaths
        }
    }

    public let id: ID
    public let displayName: String
    public let mechanism: Mechanism
    /// Where the entry lands. Read to verify and, for `.configFile`
    /// mechanisms, written directly. `nil` only for Claude Code.
    public let configFile: ConfigFile?
    public let probes: DetectionProbes
    /// Shown under the row whether connected or not — the vendor-specific
    /// thing that will otherwise make a correctly-written config look broken.
    public let afterConnectingNote: String?
    /// Where the manual instructions point, and the doc this row's facts came
    /// from.
    public let manualPathDescription: String
    public let documentationURL: String

    // MARK: - The catalog

    public static let all: [AIClientDefinition] = [
        claudeCode, codex, cursor, claudeDesktop, vsCode, zed, windsurf
    ]

    public static func definition(for id: ID) -> AIClientDefinition {
        all.first { $0.id == id }!
    }

    /// **Claude Code — driven through `claude mcp add-json`, and this one is
    /// not a close call.**
    ///
    /// Claude Code's user-scope MCP servers live in `~/.claude.json`, and that
    /// file is emphatically not ours to edit. On the machine this was written
    /// on it is 54 KB holding around fifty unrelated top-level keys —
    /// `oauthAccount`, the entire `projects` history, `machineID`, several
    /// caches, `tipsHistory` — and Claude Code rewrites it *while a session is
    /// running*. A read-modify-write from another process is a straightforward
    /// lost-update race against a file that contains the user's login state.
    /// The CLI does the same job, transactionally, and is the documented path.
    ///
    /// `add-json` rather than `add`: `claude mcp add` takes the command after
    /// a `--` separator and grows flags for each field, while `add-json` takes
    /// the entry as one JSON document — which is exactly what
    /// `MCPClientConfig.entryJSON()` already produces, so there is no second
    /// rendering to keep in step. Scope is pinned to `user` (the flag defaults
    /// to `local`, meaning "this project only", which is not what a Settings
    /// pane with no project context should be silently choosing).
    ///
    /// **What Connect deliberately does not do: install the plugin bundle in
    /// `integrations/claude-code/plugin`.** Registering the MCP server is the
    /// feature; the plugin is a convenience wrapper around that plus two hooks.
    /// Three things rule it out for a one-click button today, and all three are
    /// admitted in the plugin's own README: its `.mcp.json` hardcodes
    /// `/Applications/Sentry.app/...`, which is precisely the bug this whole
    /// change exists to stop shipping; it has never been installed against a
    /// live Claude Code build; and installing from a local path is not a
    /// confirmed capability of `claude plugin install`. Wiring a button to an
    /// unvalidated installer to deliver a config we already deliver correctly
    /// by another route would be adding risk to buy nothing. The plugin stays
    /// where it is, documented, for the user who wants the hooks too.
    ///
    /// Docs: https://code.claude.com/docs/en/mcp
    public static let claudeCode = AIClientDefinition(
        id: .claudeCode,
        displayName: "Claude Code",
        mechanism: .vendorCLI(CLIPlan(
            executableName: "claude",
            additionalExecutablePaths: [],
            addArguments: ["mcp", "add-json", "--scope", "user", "{{name}}", "{{json}}"],
            removeArguments: ["mcp", "remove", "--scope", "user", "{{name}}"],
            verifyArguments: ["mcp", "get", "{{name}}"]
        )),
        configFile: nil,
        probes: DetectionProbes(
            executableNames: ["claude"],
            absolutePaths: [],
            homeRelativePaths: [".claude"]
        ),
        afterConnectingNote: "Start a new Claude Code session to pick it up — an already-running session keeps the server list it launched with.",
        manualPathDescription: "~/.claude.json (top-level \"mcpServers\") — or run `claude mcp add-json` yourself",
        documentationURL: "https://code.claude.com/docs/en/mcp"
    )

    /// **Codex — CLI where possible, and note the bundled-binary probe.**
    ///
    /// `codex mcp add` writes `~/.codex/config.toml` itself, which is the right
    /// answer for the same reason as Claude Code: that file also holds
    /// `[features]`, `[desktop]` UI preferences, the model and sandbox
    /// settings, and servers the Codex desktop app injected — none of which we
    /// want to be responsible for round-tripping.
    ///
    /// The detection detail worth keeping: on a Mac with the Codex desktop app
    /// installed, `codex` is frequently **not on `PATH`** — the binary lives
    /// at `/Applications/Codex.app/Contents/Resources/codex`. A PATH-only
    /// check reports "not installed" to somebody looking at the app in their
    /// Dock, so the bundled path is probed too and used as the executable when
    /// it is the one that exists.
    ///
    /// `tomlFile` is still the declared config location because verification
    /// re-reads the file rather than trusting the CLI's exit code, and because
    /// the manual instructions need a path to name. `AIClientConnector`
    /// prefers the CLI and falls back to `TOMLConfigSurgeon` only if no Codex
    /// executable can be found.
    ///
    /// Docs: https://learn.chatgpt.com/docs/config-file/config-reference
    public static let codex = AIClientDefinition(
        id: .codex,
        displayName: "Codex CLI",
        mechanism: .vendorCLI(CLIPlan(
            executableName: "codex",
            additionalExecutablePaths: ["/Applications/Codex.app/Contents/Resources/codex"],
            addArguments: ["mcp", "add", "{{name}}", "--", "{{command}}"],
            removeArguments: ["mcp", "remove", "{{name}}"],
            // Empty on purpose: Codex does have `mcp get`, but re-reading
            // config.toml is stronger evidence — it is the artefact the CLI
            // was asked to produce, checked independently of the CLI's own
            // report of whether it produced it.
            verifyArguments: []
        )),
        configFile: ConfigFile(
            location: .underHome(".codex/config.toml"),
            format: .toml(tablePath: ["mcp_servers", "Sentry"])
        ),
        probes: DetectionProbes(
            executableNames: ["codex"],
            absolutePaths: ["/Applications/Codex.app", "/Applications/Codex.app/Contents/Resources/codex"],
            homeRelativePaths: [".codex"]
        ),
        afterConnectingNote: nil,
        manualPathDescription: "~/.codex/config.toml (a [mcp_servers.Sentry] table)",
        documentationURL: "https://learn.chatgpt.com/docs/extend/mcp?surface=cli"
    )

    /// **Cursor — a file write, because there is no CLI that can do it.**
    ///
    /// `cursor-agent mcp` offers `list`, `enable`, `disable` and `login` — no
    /// `add`. So `~/.cursor/mcp.json` gets spliced. It is a small, purpose-made
    /// file holding only MCP servers, which makes it a far safer write target
    /// than Claude Code's or Codex's catch-all state files.
    ///
    /// `"type": "stdio"` is written explicitly: Cursor's reference table marks
    /// the field **required** even though every example on the same page omits
    /// it. Following the table costs nothing and satisfies both readings.
    ///
    /// Docs: https://cursor.com/docs/context/mcp
    public static let cursor = AIClientDefinition(
        id: .cursor,
        displayName: "Cursor",
        mechanism: .configFile,
        configFile: ConfigFile(
            location: .underHome(".cursor/mcp.json"),
            format: .json(containerPath: ["mcpServers"], dialect: .explicitType)
        ),
        probes: DetectionProbes(
            executableNames: ["cursor", "cursor-agent"],
            absolutePaths: ["/Applications/Cursor.app"],
            homeRelativePaths: [".cursor", "Applications/Cursor.app"]
        ),
        afterConnectingNote: "Cursor picks new servers up on its own; if it doesn't appear, check Settings ▸ MCP — a server can be present in the file and switched off in the UI.",
        manualPathDescription: "~/.cursor/mcp.json (top-level \"mcpServers\")",
        documentationURL: "https://cursor.com/docs/context/mcp"
    )

    /// **Claude Desktop — a file write, plus the one caveat that makes a
    /// correct config look broken.**
    ///
    /// There is no CLI (`claude mcp add-from-claude-desktop` reads *out* of
    /// this file, not into it), so `~/Library/Application Support/Claude/
    /// claude_desktop_config.json` gets spliced.
    ///
    /// No `"type"` key: Claude Desktop's schema doesn't have one and infers
    /// stdio from `command`.
    ///
    /// The note matters more than usual here. Claude Desktop reads this file
    /// **once, at launch**, and closing its window does not quit it. A user who
    /// clicks Connect and then goes looking in Claude Desktop will find
    /// nothing, conclude the button lied, and be right to — unless we say so
    /// on the spot. Separately, and worth knowing when the pane says "not
    /// connected" about a machine that clearly is: Desktop Extensions
    /// (`.mcpb`) install into `Claude Extensions/` and never appear in this
    /// file, so this file is not a complete picture of what Claude Desktop has.
    ///
    /// Docs: https://claude.com/docs/third-party/claude-desktop/configuration
    public static let claudeDesktop = AIClientDefinition(
        id: .claudeDesktop,
        displayName: "Claude Desktop",
        mechanism: .configFile,
        configFile: ConfigFile(
            location: .underHome("Library/Application Support/Claude/claude_desktop_config.json"),
            format: .json(containerPath: ["mcpServers"], dialect: .inferredType)
        ),
        probes: DetectionProbes(
            executableNames: [],
            absolutePaths: ["/Applications/Claude.app"],
            homeRelativePaths: ["Applications/Claude.app", "Library/Application Support/Claude"]
        ),
        afterConnectingNote: "Quit Claude Desktop completely (⌘Q — closing the window isn't enough) and open it again. It reads this file only at launch.",
        manualPathDescription: "~/Library/Application Support/Claude/claude_desktop_config.json (top-level \"mcpServers\")",
        documentationURL: "https://claude.com/docs/third-party/claude-desktop/configuration"
    )

    /// **VS Code — `code --add-mcp`, because the file's location is genuinely
    /// not knowable from outside.**
    ///
    /// Microsoft's docs deliberately publish no filesystem path for the
    /// user-scope MCP config; they tell you to run the *MCP: Open User
    /// Configuration* command. The reason is that the file lives inside the
    /// **active profile**, so it is `…/Code/User/mcp.json` for the default
    /// profile and `…/Code/User/profiles/<opaque id>/mcp.json` for any other —
    /// and current docs additionally name `~/.copilot/mcp-config.json` as a
    /// portable location the agent host reads natively. Hardcoding any one of
    /// those would be wrong for a real share of users, silently.
    ///
    /// `code --add-mcp '<json>'` writes to whichever profile is active, which
    /// is exactly the knowledge we lack. Note its argument shape differs from
    /// everyone else's: the server's name goes **inside** the object as a
    /// `name` key rather than being the key the object hangs off, which is why
    /// `AIClientConnector` renders a separate document for this one call
    /// instead of reusing `entryJSON` verbatim.
    ///
    /// Verification then has to hunt: we scan the candidate paths for our
    /// entry, and if we cannot find it we say we could not confirm it rather
    /// than claiming success from an exit code. `servers`, not `mcpServers`,
    /// is the container key here.
    ///
    /// Docs: https://code.visualstudio.com/docs/agents/reference/mcp-configuration
    public static let vsCode = AIClientDefinition(
        id: .vsCode,
        displayName: "VS Code",
        mechanism: .vendorCLI(CLIPlan(
            executableName: "code",
            additionalExecutablePaths: [
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
            ],
            addArguments: ["--add-mcp", "{{json}}"],
            // `code` has no --remove-mcp. Disconnect falls back to editing
            // whichever candidate file the entry actually turns up in; see
            // `AIClientConnector.disconnect`.
            removeArguments: [],
            verifyArguments: [],
            jsonDialect: .explicitType,
            jsonIncludesServerName: true
        )),
        configFile: ConfigFile(
            location: .candidatesUnderHome([
                "Library/Application Support/Code/User/mcp.json",
                ".copilot/mcp-config.json"
            ]),
            format: .json(containerPath: ["servers"], dialect: .explicitType)
        ),
        probes: DetectionProbes(
            executableNames: ["code"],
            absolutePaths: ["/Applications/Visual Studio Code.app"],
            homeRelativePaths: ["Applications/Visual Studio Code.app", "Library/Application Support/Code"]
        ),
        afterConnectingNote: "VS Code writes this into whichever profile is active. If it doesn't appear, run “MCP: Open User Configuration” from the Command Palette to see the file it chose.",
        manualPathDescription: "Command Palette ▸ “MCP: Open User Configuration” (a \"servers\" object; the file's path depends on your active profile)",
        documentationURL: "https://code.visualstudio.com/docs/agents/reference/mcp-configuration"
    )

    /// **Zed — a JSONC write into the user's entire editor configuration,
    /// which is only acceptable because the splice preserves everything else.**
    ///
    /// `~/.config/zed/settings.json`, key `context_servers`. Two facts drove
    /// the decision to support it rather than list it manual-only:
    ///
    /// 1. The file is **JSONC** — Zed documents `//` comments as supported,
    ///    and real users' settings are full of them. Any implementation built
    ///    on `JSONSerialization` would either fail to parse the file or, worse,
    ///    parse a comment-free one and hand back a rewritten document with the
    ///    user's whole editor configuration reordered and their comments gone.
    ///    `JSONConfigSurgeon` splices, so a Zed user's settings come back with
    ///    one object added and every other byte identical. Without that, this
    ///    entry would say `manualOnly`.
    /// 2. The location is stable and in-repo documented. (The
    ///    `~/.zed/settings.json` path that circulates in search results is
    ///    stale; Zed's own `configuring-zed.md` says `~/.config/zed/`.)
    ///
    /// One honest caveat kept in the note: `context_servers` does not appear in
    /// Zed's generated all-settings reference, so the entry schema is
    /// documented by example only, and it has changed shape before (older Zed
    /// wanted `{"source": "custom", "command": {"path": …}}`). No `"type"` key.
    ///
    /// Docs: https://zed.dev/docs/ai/mcp
    public static let zed = AIClientDefinition(
        id: .zed,
        displayName: "Zed",
        mechanism: .configFile,
        configFile: ConfigFile(
            location: .underHome(".config/zed/settings.json"),
            format: .json(containerPath: ["context_servers"], dialect: .inferredType)
        ),
        probes: DetectionProbes(
            executableNames: ["zed"],
            absolutePaths: ["/Applications/Zed.app"],
            homeRelativePaths: ["Applications/Zed.app", ".config/zed"]
        ),
        afterConnectingNote: "This is your whole Zed settings file — Sentry adds one entry to \"context_servers\" and leaves every other line, including your comments, exactly as it found them.",
        manualPathDescription: "~/.config/zed/settings.json (top-level \"context_servers\")",
        documentationURL: "https://zed.dev/docs/ai/mcp"
    )

    /// **Windsurf — listed, not written. This is the one deliberate skip.**
    ///
    /// The product changed hands and the documentation is mid-migration:
    /// `docs.windsurf.com/windsurf/cascade/mcp` now redirects to
    /// `docs.devin.ai/desktop/cascade/mcp`, and that page labels the MCP
    /// configuration it describes as belonging to the **legacy Cascade agent**
    /// rather than the current Devin Local agent. So the only documented
    /// location — `~/.codeium/windsurf/mcp_config.json` — is documented as
    /// legacy, by a doc site under a different brand, for an agent
    /// architecture that is being replaced.
    ///
    /// Writing there is not dangerous, it is *unreliable*: it may configure
    /// something the user's Windsurf no longer consults, in which case the
    /// pane would report "connected" about a connection that does not exist.
    /// That is the specific failure this entire change exists to eliminate, so
    /// Windsurf gets the path, the snippet, and a plain statement of why the
    /// button is absent — which is strictly more useful than a button that
    /// might lie. Revisit when the Devin docs describe a current, non-legacy
    /// location.
    ///
    /// Docs: https://docs.devin.ai/desktop/cascade/mcp
    public static let windsurf = AIClientDefinition(
        id: .windsurf,
        displayName: "Windsurf",
        mechanism: .manualOnly(
            reason: "Windsurf's MCP setup moved to Devin's documentation, where it's marked as belonging to the legacy Cascade agent. Sentry won't write a file it can't be sure your build still reads — that would let this pane claim a connection you don't have. The snippet and path are below if you want to add it yourself."
        ),
        configFile: ConfigFile(
            location: .underHome(".codeium/windsurf/mcp_config.json"),
            format: .json(containerPath: ["mcpServers"], dialect: .inferredType)
        ),
        probes: DetectionProbes(
            executableNames: ["windsurf"],
            absolutePaths: ["/Applications/Windsurf.app"],
            homeRelativePaths: ["Applications/Windsurf.app", ".codeium/windsurf"]
        ),
        afterConnectingNote: nil,
        manualPathDescription: "~/.codeium/windsurf/mcp_config.json (top-level \"mcpServers\")",
        documentationURL: "https://docs.devin.ai/desktop/cascade/mcp"
    )

    /// The container key and dialect used when showing a manual snippet — the
    /// CLI-driven clients have no file of ours to describe, so they borrow the
    /// shape their file would have if the user edits it by hand anyway.
    public var manualSnippetShape: (containerPath: [String], dialect: MCPClientConfig.EntryDialect) {
        switch configFile?.format {
        case .json(let containerPath, let dialect):
            return (containerPath, dialect)
        case .toml, .none:
            // Codex's manual snippet is TOML, rendered by the caller from
            // `MCPClientConfig.tomlTableBody()`; Claude Code has no file we
            // describe, so its manual instructions are the `claude mcp add-json`
            // command line and the JSON below it in its documented shape.
            return (["mcpServers"], .inferredType)
        }
    }

    /// True when the manual instructions should show TOML rather than JSON.
    public var manualSnippetIsTOML: Bool {
        if case .toml = configFile?.format { return true }
        return false
    }
}
#endif
