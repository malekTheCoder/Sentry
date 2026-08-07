import Foundation
import SentryKit
import SystemMetricsKit

/// Owns `ProcessCollector`'s own polling cadence — deliberately separate
/// from `StatsCoordinator`'s tiered loop (see `ProcessCollector`'s doc
/// comment for why: per-process enumeration is pricier than any existing
/// collector and its ranked-list result doesn't fit `SystemSnapshot`'s
/// shape). Only runs while something is actually observing it —
/// `start()`/`stop()` are each caller's own job to call on appear/disappear,
/// the same "don't pay for what nobody's looking at" posture
/// `DashboardViewModel.refresh()`'s doc comment already applies to history
/// queries.
///
/// Two independent instances exist today, each gated by its own surface's
/// visibility rather than sharing one: `AppDelegate` owns one for
/// `DashboardView`'s "Top Processes"/agent-activity cards (gated to the
/// Dashboard window being visible *and* its tab selected — see
/// `updateProcessMonitorState()`), and `DropdownViewModel` owns a second,
/// smaller one (`limit: 3`) for the dropdown's CPU-row process list (gated
/// by the popover's own SwiftUI appear/disappear — see that type's doc
/// comment for why this isn't the same instance). Neither instance knows
/// about the other; each simply stops paying `ProcessCollector`'s
/// enumeration cost the moment its own surface isn't visible.
@MainActor
public final class ProcessMonitor: ObservableObject {
    @Published public private(set) var topProcesses: [ProcessStats] = []
    /// Live agent/build-tool processes for the Dashboard's orchestration
    /// view, regardless of whether they'd make the top-N cut. Same
    /// enumeration pass as `topProcesses` (see `ProcessCollector.collect`).
    @Published public private(set) var agentProcesses: [ProcessStats] = []

    /// Executable names that count as "agent workload": the agent CLIs
    /// themselves plus the build/runtime tools they spend their lives
    /// driving. Lowercased, matched case-insensitively against `proc_name`
    /// output by `ProcessCollector.collect(limit:matching:)`.
    ///
    /// **Derived from `AgentProcessRole.namesByRole`, not written out twice.**
    /// Every name here now also has to answer "and what *is* it," because
    /// the Dashboard card labels each row with its role — and a match list
    /// and a label table maintained side by side is a drift bug waiting to
    /// happen (add `"pnpm"` to one, forget the other, and the card renders a
    /// row it has no words for). One table, two consumers; a test asserts
    /// the derivation covers every role.
    public static let agentProcessNames: Set<String> = AgentProcessRole.allMatchedNames

    private let collector = ProcessCollector()
    private let interval: TimeInterval
    private let limit: Int
    private var timer: Timer?

    public init(interval: TimeInterval = 5, limit: Int = 8) {
        self.interval = interval
        self.limit = limit
    }

    public func start() {
        guard timer == nil else { return }
        // First pass primes the per-PID CPU-time baselines and necessarily
        // reports 0% for everything; without a fast follow-up the card
        // opens on a column of zeros for a full interval. One extra pass a
        // second later turns the baselines into real percentages.
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.timer != nil else { return }
                self.refresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let collected = collector.collect(limit: limit, matching: Self.agentProcessNames)
        topProcesses = collected.top
        agentProcesses = collected.matched
    }
}

/// What a name-matched process in `ProcessMonitor.agentProcesses` actually
/// *is*, in words a person can act on.
///
/// **Why a row needs this at all.** `ProcessMonitor` matches on executable
/// name and nothing else, which is the only cheap signal `libproc` gives
/// (see `ProcessCollector`'s doc comment on why there is no per-process
/// "who spawned you" or "are you an MCP client" to read). That match is
/// broad on purpose — an agent's cost to this Mac is mostly the compilers
/// and runtimes it drives, not the CLI itself — but it means the list mixes
/// three genuinely different things: the agent, the build it started, and a
/// runtime that may have nothing to do with any agent at all. Rendering all
/// three as an undifferentiated column of names invites the exact
/// misreading the card exists to prevent: that `node` at pid 79408 is "an
/// AI agent session." Naming the role makes each row say why it is there.
///
/// **Deliberately not a claim about MCP.** No role here means "connected to
/// Sentry" — nothing in a process name can establish that, and the card's
/// own copy says so next to the list. The MCP side of the card is fed by
/// `agent_activity_log`, which is the only source that actually knows.
///
/// Non-isolated (a plain top-level `enum`, not a member of the `@MainActor`
/// `ProcessMonitor`) so the classification is callable from tests and from
/// view code without an actor hop for what is a dictionary lookup.
public enum AgentProcessRole: String, CaseIterable, Sendable {
    /// A coding agent's own process — the thing that talks to Sentry over
    /// MCP, if anything here does.
    case codingAgent
    /// A compiler, linker, or build driver. Usually the *expensive* half of
    /// an agent's footprint, which is why these are matched at all.
    case buildTool
    /// A general-purpose language runtime. The loosest match in the set:
    /// plenty of `node` processes on a developer's Mac are a dev server or
    /// a language server that no agent started.
    case runtime

    /// The one table. Keys are lowercased `proc_name` output; the match in
    /// `ProcessCollector.collect` lowercases the observed name before
    /// testing membership, so entries here must stay lowercase.
    static let namesByRole: [AgentProcessRole: Set<String>] = [
        .codingAgent: ["claude", "codex", "gemini", "aider"],
        .buildTool: ["xcodebuild", "swift-frontend", "swiftc", "sourcekit-lsp", "cargo", "rustc", "ninja", "make"],
        .runtime: ["node", "bun"],
    ]

    static let allMatchedNames: Set<String> = namesByRole.values.reduce(into: Set<String>()) { $0.formUnion($1) }

    /// Reverse lookup, built once. `nil` for a name that isn't matched at
    /// all — which callers should treat as "this row should not exist,"
    /// never as a fourth, unlabelled role.
    private static let roleByName: [String: AgentProcessRole] = {
        var table: [String: AgentProcessRole] = [:]
        for (role, names) in namesByRole {
            for name in names { table[name] = role }
        }
        return table
    }()

    /// Classifies an observed `proc_name`. Case-insensitive for the same
    /// reason the match itself is: macOS ships both `/Applications/Claude
    /// .app/Contents/MacOS/Claude` (capital C, the desktop app) and the
    /// lowercase `claude` CLI, and both are legitimately coding agents.
    public static func role(forProcessNamed name: String) -> AgentProcessRole? {
        roleByName[name.lowercased()]
    }

    /// Short, lowercase, and sits inline after the process name — this is a
    /// caption on a dense row, not a heading.
    public var label: String {
        switch self {
        case .codingAgent: return String(localized: "coding agent")
        case .buildTool: return String(localized: "build tool")
        case .runtime: return String(localized: "runtime")
        }
    }

    /// Whether a process in this role is an AI agent, as opposed to
    /// something an agent (or Xcode, or the user, or Homebrew) happens to be
    /// driving.
    ///
    /// **This distinction is the whole reason the roles exist.** Before it,
    /// a card headed "AI Agent Activity" listed `xcodebuild` at 29% CPU as
    /// one of its rows, which is not a mislabel so much as a false claim:
    /// `xcodebuild` is a compile. It is exactly as likely to have been
    /// started by the user pressing ⌘B as by any agent, and Sentry has no
    /// way to tell which. An app whose pitch is "I can tell you what AI
    /// agents are doing to your machine" cannot inflate that number with
    /// `make` and still be worth believing.
    ///
    /// Note the asymmetry this does *not* fix: even `.codingAgent` is an
    /// inference from an executable name. It says "a program called `claude`
    /// is running," never "an agent is connected to Sentry." Only
    /// `agent_activity_log` knows the latter, which is why the card renders
    /// MCP sessions as a separate, differently-headed group rather than
    /// merging the two lists.
    public var isAIAgent: Bool { self == .codingAgent }
}
