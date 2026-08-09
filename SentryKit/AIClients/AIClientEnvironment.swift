#if os(macOS)
import Foundation

/// Everything `AIClientDetector` and `AIClientConnector` are allowed to do to
/// the outside world, behind one seam.
///
/// **This protocol exists so the test suite physically cannot touch a real
/// config file.** That is not a stylistic preference. The code underneath it
/// edits `~/.cursor/mcp.json`, `~/.codex/config.toml` and Claude Desktop's
/// configuration — files that belong to the developer running the tests, on
/// the machine they use to work. A suite that reached the real `FileManager`
/// would corrupt a colleague's editor setup the first time an assertion was
/// written slightly wrong, and the failure would look like a flaky test rather
/// than like the data loss it was. With the seam, `SentryKitAIClientTests`
/// passes an in-memory fake and there is no code path from a test to a real
/// path at all.
///
/// It also buys the thing that makes the suite worth having: every awkward
/// state can be *set up*. A malformed JSON file, a directory that doesn't
/// exist, a read-only file, a CLI that exits non-zero with a message on
/// stderr, a CLI that exits zero but writes nothing — all of those are one
/// line of test fixture through this protocol and are effectively unstageable
/// against the real filesystem.
///
/// Rejected: injecting a root directory and using the real `FileManager`
/// under a temp dir. It tests less (no read-only, no malformed-permission, no
/// subprocess), leaves litter when a test crashes mid-run, and still lets a
/// path-construction bug escape the sandbox — an absolute path assembled from
/// `NSHomeDirectory()` by mistake would sail straight past a root prefix.
public protocol AIClientEnvironment: AnyObject {

    /// The user's home directory. Every config path in `AIClientCatalog` is
    /// expressed relative to this, so a fake can relocate the whole world.
    var homeDirectory: String { get }

    /// Directories searched for a vendor CLI, in order.
    ///
    /// This is not simply `$PATH`, and it must not be. A GUI app launched from
    /// the Finder inherits `launchd`'s minimal path — typically
    /// `/usr/bin:/bin:/usr/sbin:/sbin` — not the shell's. `claude` installs to
    /// `~/.local/bin` by default and would be invisible; so would anything
    /// from Homebrew. `RealAIClientEnvironment` therefore unions `$PATH` with
    /// the locations these tools actually install to.
    var executableSearchPaths: [String] { get }

    func fileExists(atPath path: String) -> Bool

    /// Directory existence, kept separate from `fileExists` because an `.app`
    /// bundle is a directory and "the file is really a folder" is a distinction
    /// the detector needs to not care about while the writer very much does.
    func directoryExists(atPath path: String) -> Bool

    /// `nil` when the file does not exist — a distinct, expected, non-error
    /// outcome (the tool has never been run) that the caller reports in its own
    /// words rather than as a failure.
    func readText(atPath path: String) throws -> String?

    func writeText(_ text: String, atPath path: String) throws

    /// Creates a directory and any missing parents. Needed for the
    /// never-been-run case: `~/.cursor/` may not exist yet.
    func createDirectory(atPath path: String) throws

    func copyItem(atPath source: String, toPath destination: String) throws

    /// Whether a write to `path` would be permitted — checked *before*
    /// touching anything, so a permission problem is reported as a refusal to
    /// start rather than as a backup with no write after it.
    func isWritable(atPath path: String) -> Bool

    func run(executable: String, arguments: [String]) throws -> AIClientCommandResult

    /// Injected so backup filenames are deterministic under test.
    var now: Date { get }
}

/// A finished subprocess: everything needed to explain what happened, and
/// nothing that requires the caller to have kept the `Process` alive.
public struct AIClientCommandResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitStatus: Int32, standardOutput: String, standardError: String) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitStatus == 0 }

    /// The most useful line to show a user when it failed — stderr if the tool
    /// wrote any, else stdout, else a bare exit code. Trimmed and truncated,
    /// because some of these CLIs print a usage screen on error and a settings
    /// pane is not a terminal.
    public var failureMessage: String {
        let candidates = [standardError, standardOutput]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let firstLines = trimmed.split(separator: "\n").prefix(4).joined(separator: " ")
                return String(firstLines.prefix(400))
            }
        }
        return "it exited with status \(exitStatus) and said nothing"
    }
}

/// The real one: `FileManager` and `Process`.
public final class RealAIClientEnvironment: AIClientEnvironment {

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public var homeDirectory: String { NSHomeDirectory() }

    /// `$PATH`, plus the places these tools install to that a
    /// Finder-launched app would otherwise never see.
    ///
    /// The list is deliberately explicit rather than "run the user's login
    /// shell and read its `$PATH`". Spawning `zsh -lic 'echo $PATH'` executes
    /// the user's entire shell profile — arbitrary code, on a background
    /// thread, from a Settings pane, potentially slowly and potentially
    /// interactively. Probing eight known directories is cheaper, has no side
    /// effects, and fails in an obvious way (the tool shows as not detected,
    /// with the manual path still offered) rather than a surprising one.
    public var executableSearchPaths: [String] {
        let home = homeDirectory
        let fromEnvironment = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let wellKnown = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "\(home)/node_modules/.bin",
            "/usr/bin",
            "/bin"
        ]
        var seen = Set<String>()
        return (fromEnvironment + wellKnown).filter { seen.insert($0).inserted }
    }

    public func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    public func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public func readText(atPath path: String) throws -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    public func writeText(_ text: String, atPath path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func createDirectory(atPath path: String) throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func copyItem(atPath source: String, toPath destination: String) throws {
        if fileManager.fileExists(atPath: destination) {
            try fileManager.removeItem(atPath: destination)
        }
        try fileManager.copyItem(atPath: source, toPath: destination)
    }

    public func isWritable(atPath path: String) -> Bool {
        if fileManager.fileExists(atPath: path) {
            return fileManager.isWritableFile(atPath: path)
        }
        // The file doesn't exist yet, so the question is really about its
        // directory — and about the deepest ancestor that does exist, since
        // we create intermediates.
        var directory = (path as NSString).deletingLastPathComponent
        while !directory.isEmpty, directory != "/" {
            if fileManager.fileExists(atPath: directory) {
                return fileManager.isWritableFile(atPath: directory)
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return false
    }

    public func run(executable: String, arguments: [String]) throws -> AIClientCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // No shell, ever. See `AIClientDefinition.CLIPlan`.
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Some of these CLIs prompt when they think they have a terminal.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting: a CLI that fills a 64 KB pipe buffer while we
        // block in `waitUntilExit()` deadlocks, and `claude mcp get` on a
        // machine with many servers is well capable of it.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return AIClientCommandResult(
            exitStatus: process.terminationStatus,
            standardOutput: String(data: outData, encoding: .utf8) ?? "",
            standardError: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    public var now: Date { Date() }
}
#endif
