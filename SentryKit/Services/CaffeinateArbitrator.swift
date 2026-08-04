import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - CaffeinateArbitrator: detecting and, when policy says so, ending
// an agent-spawned `caffeinate` process outside Sentry's control.
//
// **Why this exists.** Claude Code spawns `caffeinate -i -t 300` while a
// session is active and respawns it roughly every 300 seconds — documented
// on Anthropic's own issue tracker (open since January 2026, unanswered as
// of this writing) as "Restarting sleep inhibitor to maintain prevention."
// Killing the process by hand doesn't help; it comes back. One report in
// that thread measured 4,567 leaked `caffeinate` processes accumulated over
// time. None of that is visible to, or governed by, anything in this
// codebase: `AgentGuardrails` (battery floor, quiet hours, thermal
// auto-revoke — `SentryKit/Services/AgentGuardrails.swift`) only ever
// touches Sentry's *own* `keep_awake` MCP tool via `PowerControlService`.
// A `caffeinate` process an agent spawned directly, on its own, as a
// subprocess of its own CLI, is invisible to every one of those controls —
// the battery can hit 1% and quiet hours can be in full effect, and this
// Mac still won't sleep, because nothing here has ever looked for it.
//
// **What this file adds, precisely.** Three pieces, kept separate so each
// is testable on its own:
//   1. Detection — `matchExternalCaffeinates(in:)`, a pure function over a
//      fabricated process table, and `liveProcessTable()` /
//      `detectExternalCaffeinates()`, the real libproc/sysctl enumeration
//      that feeds it.
//   2. Policy — `shouldEnforce(settings:context:)`, a pure function
//      answering "would Sentry's own guardrails be revoking keep-awake
//      right now, and is the user OK with that verdict reaching an
//      external `caffeinate` too."
//   3. Enforcement — `enforce(settings:context:sessions:)`, the only
//      impure entry point: it detects, decides, and — only when policy
//      says so — calls `kill()` on the matched PIDs.
//
// **This is not, and cannot be, a guarantee.** See
// `matchExternalCaffeinates(in:)`'s doc comment for exactly what the
// detection heuristic can and cannot tell apart. When the signal is
// ambiguous, the policy here is to do nothing rather than guess — see that
// method's doc comment for the specific ambiguous cases it deliberately
// declines to match.
public enum CaffeinateArbitrator {

    // MARK: - Process table (the pure, testable shape)

    /// One row of a process table, exactly the facts the detection
    /// heuristic needs and nothing else — deliberately not `ProcessStats`
    /// (`SentryKit/Models/ProcessStats.swift`), which carries CPU/memory
    /// this heuristic never looks at and omits `parentPID`/`arguments`,
    /// which it does. Kept as a plain value type so
    /// `matchExternalCaffeinates(in:)` can be driven entirely by fabricated
    /// `ps`-style rows in tests, with no real process enumeration involved.
    public struct ProcessTableEntry: Equatable, Sendable {
        public let pid: Int32
        /// 0 or negative when the parent is unknown/already reaped — never
        /// treated as a match by itself (see `ancestry(of:in:)`).
        public let parentPID: Int32
        /// Executable/`comm` name, e.g. "caffeinate", "claude", "bash" —
        /// compared case-insensitively and exactly, never as a substring
        /// (the same discipline `PowerControlService.isProcessRunning`
        /// documents, and for the same reason: "claude" must not match
        /// "claude-relay-helper" or some unrelated tool that merely
        /// contains the string).
        public let name: String
        /// Full argv, index 0 first (conventionally the executable path or
        /// name) — the same shape `ps -eo command` or `/bin/ps`'s argv
        /// column exposes, and what `matchesClaudeInvocationShape(_:)`
        /// inspects.
        public let arguments: [String]

        public init(pid: Int32, parentPID: Int32, name: String, arguments: [String]) {
            self.pid = pid
            self.parentPID = parentPID
            self.name = name
            self.arguments = arguments
        }
    }

    /// One `caffeinate` process this heuristic believes was spawned by a
    /// Claude Code session, plus enough context to explain *why* — used
    /// both to decide whether to terminate it and to write an honest log
    /// line about what matched.
    public struct ExternalCaffeinateMatch: Equatable, Sendable {
        public let pid: Int32
        public let parentPID: Int32
        public let arguments: [String]
        /// Name of the ancestor process that matched (lowercased "claude"),
        /// when the ancestry signal is what fired. `nil` when only the
        /// argv-shape signal matched (see `matchExternalCaffeinates(in:)`).
        public let matchedViaAncestorNamed: String?
        /// Whether `arguments` matched the documented `-i -t 300` shape.
        public let matchedInvocationShape: Bool

        public init(pid: Int32, parentPID: Int32, arguments: [String], matchedViaAncestorNamed: String?, matchedInvocationShape: Bool) {
            self.pid = pid
            self.parentPID = parentPID
            self.arguments = arguments
            self.matchedViaAncestorNamed = matchedViaAncestorNamed
            self.matchedInvocationShape = matchedInvocationShape
        }
    }

    /// How far up the parent chain to look for a `claude` ancestor before
    /// giving up. Six covers every real shell-nesting depth this heuristic
    /// is likely to see (`claude` → its own subprocess supervisor → a
    /// shell → `caffeinate`, with a couple of spare hops for `login`/`sh -c`
    /// wrappers) without risking an unbounded walk if `parentPID` chains
    /// ever formed a cycle from a stale/reused PID.
    public static let maxAncestryDepth = 6

    // MARK: - Detection (pure)

    /// The exact invocation Claude Code is documented to run: `caffeinate`
    /// with `-i` (prevent idle sleep) and `-t 300` (a 300-second timeout,
    /// respawned before it lapses — the "Restarting sleep inhibitor to
    /// maintain prevention" behavior). Matched precisely (`-t` must be
    /// followed by exactly `"300"`, not merely present) rather than "any
    /// `-t` value," because a looser match would also catch a user's own
    /// unrelated `caffeinate -i -t 3600` and misattribute it to an agent
    /// that never ran it. This is why this signal is treated as
    /// *supporting*, not sufficient on its own to be highly confident — see
    /// `matchExternalCaffeinates(in:)`.
    public static func matchesClaudeInvocationShape(_ arguments: [String]) -> Bool {
        guard arguments.contains("-i") else { return false }
        guard let flagIndex = arguments.firstIndex(of: "-t"), flagIndex + 1 < arguments.count else { return false }
        return arguments[flagIndex + 1] == "300"
    }

    /// Walks `parentPID` links from `entry` up to `maxAncestryDepth` hops,
    /// returning the chain (closest ancestor first, `entry` itself
    /// excluded). Stops early on a missing/self-referential/already-visited
    /// parent — the last of which is what keeps a corrupted or adversarial
    /// table (a fabricated cycle) from looping forever; real process tables
    /// never contain one, but a pure function fed arbitrary test input
    /// should not assume its input is well-formed.
    public static func ancestry(of entry: ProcessTableEntry, in table: [ProcessTableEntry]) -> [ProcessTableEntry] {
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [ProcessTableEntry] = []
        var visited: Set<Int32> = [entry.pid]
        var currentParentPID = entry.parentPID
        while chain.count < maxAncestryDepth,
              currentParentPID > 0,
              !visited.contains(currentParentPID),
              let parent = byPID[currentParentPID] {
            chain.append(parent)
            visited.insert(parent.pid)
            currentParentPID = parent.parentPID
        }
        return chain
    }

    /// The detection heuristic. A `caffeinate` process (name matched
    /// case-insensitively, exactly) is treated as Claude-spawned when
    /// *either*:
    ///
    ///   - an ancestor within `maxAncestryDepth` hops is named exactly
    ///     "claude" (case-insensitive) — the strong signal: Claude Code's
    ///     own binary is genuinely in this process's parent chain; or
    ///   - its argv matches the documented `-i -t 300` shape
    ///     (`matchesClaudeInvocationShape(_:)`) — a weaker, supporting
    ///     signal on its own (any tool could coincidentally invoke
    ///     `caffeinate` the same way), included because the brief this was
    ///     built from explicitly asks for it and because it costs nothing
    ///     extra to check.
    ///
    /// **What this does *not* claim.** This is a best-effort match on
    /// process ancestry and argv shape, not a verified identity — nothing
    /// about `libproc`'s process table is cryptographically tied to "this
    /// PID really is Claude Code." A determined process could rename
    /// itself `claude`, or a legitimate, unrelated tool could happen to run
    /// `caffeinate -i -t 300`. Neither is defended against; both would be
    /// treated as a match. What *is* defended against, deliberately: a
    /// `caffeinate` invocation with a different timeout, or no ancestor
    /// named "claude" within the depth bound, is left alone rather than
    /// guessed at — a false negative (an agent's `caffeinate` goes
    /// unnoticed) is the failure mode this function accepts in exchange for
    /// never terminating a process on a hunch. Only ever `caffeinate`
    /// processes are considered candidates at all; nothing else is ever
    /// touched by any function in this file.
    public static func matchExternalCaffeinates(in table: [ProcessTableEntry]) -> [ExternalCaffeinateMatch] {
        table.compactMap { entry -> ExternalCaffeinateMatch? in
            guard entry.name.lowercased() == "caffeinate" else { return nil }
            let claudeAncestor = ancestry(of: entry, in: table).first { $0.name.lowercased() == "claude" }
            let shapeMatch = matchesClaudeInvocationShape(entry.arguments)
            guard claudeAncestor != nil || shapeMatch else { return nil }
            return ExternalCaffeinateMatch(
                pid: entry.pid,
                parentPID: entry.parentPID,
                arguments: entry.arguments,
                matchedViaAncestorNamed: claudeAncestor?.name,
                matchedInvocationShape: shapeMatch
            )
        }
    }

    // MARK: - Attribution (pure) — correlating a match with an active MCP session

    /// One external `caffeinate` match, best-effort correlated with an
    /// active `AgentSessionRegistry` session (`SentryKit/Services
    /// /AgentSessionRegistry.swift`) so the keep-awake time it represents
    /// can be surfaced against the session that most plausibly caused it.
    public struct SessionAttributedMatch: Equatable, Sendable {
        public let match: ExternalCaffeinateMatch
        /// The `AgentSessionRegistry.Session.clientName` this match was
        /// attributed to, or `nil` when no active session looked like a
        /// plausible owner — see `attribute(matches:sessions:)`. Deliberately
        /// a client name, not a session UUID: `AgentSessionRegistry` (unlike
        /// `AgentSessionIdentity`/`AgentSessionReport`'s per-connection
        /// session IDs) keys its sessions by self-reported client name alone
        /// — see that type's doc comment — so a client name is the most
        /// precise identity actually available at this layer. A caller
        /// wiring this into `AgentSessionReport`'s per-session accounting
        /// matches this against `AgentSessionSummary.clientName`.
        public let clientName: String?

        public init(match: ExternalCaffeinateMatch, clientName: String?) {
            self.match = match
            self.clientName = clientName
        }
    }

    /// Correlates detected matches with `AgentSessionRegistry.activeSessions`
    /// rows. **This is a much weaker claim than the detection heuristic
    /// above.** There is no data anywhere on this Mac tying a specific
    /// `caffeinate` PID to a specific MCP client — `AgentSessionRegistry`
    /// only knows self-reported `clientName`s that called *this app's* MCP
    /// tools, and a `caffeinate` subprocess never does that. The
    /// correlation here is therefore purely a name heuristic: a match is
    /// attributed to the sole active session whose `clientName` contains
    /// "claude" (case-insensitive substring — unlike the process heuristic
    /// above, session names in practice look like "Claude Code",
    /// "claude-code", etc., not a bare exact "claude"), if exactly one such
    /// session exists. When zero or multiple such sessions are active,
    /// every match in that ambiguous group comes back with
    /// `clientName: nil` rather than a guessed owner — same "ambiguous
    /// means do nothing" posture as the process heuristic, applied to
    /// attribution instead of termination.
    public static func attribute(
        matches: [ExternalCaffeinateMatch],
        sessions: [AgentSessionRegistry.Session]
    ) -> [SessionAttributedMatch] {
        let claudeSessions = sessions
            .filter { $0.clientName.localizedCaseInsensitiveContains("claude") }
            .sorted { $0.lastCallAt > $1.lastCallAt }
        let owner = claudeSessions.count == 1 ? claudeSessions.first : nil
        return matches.map { SessionAttributedMatch(match: $0, clientName: owner?.clientName) }
    }

    // MARK: - Policy (pure)

    /// Whether Sentry should, right now, also terminate any detected
    /// Claude-spawned `caffeinate` process — not whether one exists, only
    /// whether policy allows acting on one if it does. True exactly when
    /// both:
    ///
    ///   - the user has this enforcement turned on
    ///     (`AgentGuardrailSettings.enforceAgainstExternalCaffeinate`,
    ///     default on — see that property's doc comment); and
    ///   - `AgentGuardrails.autoRevocationReason(settings:context:)` is
    ///     non-`nil`, i.e. Sentry's own guardrails would, right now, be
    ///     revoking an agent-held `keep_awake` assertion for the same
    ///     underlying reason (battery critical, quiet hours, thermal
    ///     serious+).
    ///
    /// Deliberately piggybacks on `autoRevocationReason` rather than
    /// re-deriving battery/quiet-hours/thermal logic here: this is the
    /// exact condition under which Sentry has already decided an agent
    /// should not be allowed to hold this Mac awake, and an external
    /// `caffeinate` doing the same thing by a different mechanism is the
    /// same problem wearing a different PID. One policy, two enforcement
    /// surfaces.
    public static func shouldEnforce(
        settings: AgentGuardrailSettings,
        context: AgentGuardrails.PowerContext
    ) -> Bool {
        guard settings.enforceAgainstExternalCaffeinate else { return false }
        return AgentGuardrails.autoRevocationReason(settings: settings, context: context) != nil
    }

    // MARK: - Live enumeration (impure — not meaningfully unit-testable)

    /// Real libproc/sysctl process-table enumeration feeding
    /// `matchExternalCaffeinates(in:)`. **Not unit-tested**, by design and
    /// necessity: it depends on the live system process table, which a
    /// test cannot fabricate or control (there is no libproc test double,
    /// and spawning real processes from a unit test to exercise this would
    /// be flaky and slow for no real coverage gain). What *is* tested is
    /// the pure matcher this feeds (`matchExternalCaffeinates(in:)`'s test
    /// cases) and the pure policy this results feed into
    /// (`shouldEnforce(settings:context:)`'s test cases) — this function is
    /// the thin, deliberately unverified seam between them and reality,
    /// matching `ProcessCollector`'s own posture (its libproc calls are
    /// likewise untested; only `ProcessCollector.percent(...)` is).
    #if os(macOS)
    public static func liveProcessTable() -> [ProcessTableEntry] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytesReturned = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard bytesReturned > 0 else { return [] }
        let count = min(Int(bytesReturned), pids.count)

        var table: [ProcessTableEntry] = []
        table.reserveCapacity(count)
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0, let bsdInfo = taskBSDInfo(for: pid) else { continue }
            let name = withUnsafeBytes(of: bsdInfo.pbi_comm) { rawBuffer -> String in
                let pointer = rawBuffer.bindMemory(to: CChar.self).baseAddress!
                return String(cString: pointer)
            }
            // argv is comparatively expensive (a `sysctl` copy-out per PID)
            // and only ever meaningful for a `caffeinate` candidate, so it's
            // only fetched for processes whose name already matches —
            // everything else gets an empty argv, which is fine because
            // `matchExternalCaffeinates(in:)` only reads `arguments` on
            // processes named "caffeinate" in the first place.
            let arguments = name.lowercased() == "caffeinate" ? processArguments(for: pid) : []
            table.append(ProcessTableEntry(
                pid: pid,
                parentPID: Int32(bitPattern: bsdInfo.pbi_ppid),
                name: name,
                arguments: arguments
            ))
        }
        return table
    }

    private static func taskBSDInfo(for pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard written == size else { return nil }
        return info
    }

    /// Reads `argv` for `pid` via `sysctl(CTL_KERN, KERN_PROCARGS2, pid)` —
    /// the same public, documented (if lightly) mechanism `ps` itself uses
    /// to show a process's command line, and the only way to get argv from
    /// outside the process on macOS (there is no libproc call for it).
    /// The buffer layout is: a leading `Int32` argc, then the executable
    /// path (NUL-terminated, historically argv[0] duplicated ahead of the
    /// real argv for exec-path purposes), then padding NUL bytes up to the
    /// next word boundary, then exactly `argc` NUL-terminated strings
    /// (argv), then the environment. Only the `argc` argv strings after the
    /// padding are parsed; the environment is never read. Returns `[]` on
    /// any failure (permission denied — cross-user/SIP-protected processes
    /// return `EPERM` here — a PID that raced past exit, or a malformed
    /// buffer) rather than throwing, since a missing argv should simply
    /// fall back to "no invocation-shape match," not abort enumeration.
    private static func processArguments(for pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { rawBuffer -> Int32 in
            var mutableMIB = mib
            var mutableSize = size
            return sysctl(&mutableMIB, 3, rawBuffer.baseAddress, &mutableSize, nil, 0)
        }
        guard result == 0, size >= MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return [] }

        var offset = MemoryLayout<Int32>.size
        // Skip the executable path string (NUL-terminated) that precedes argv.
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
        // Skip the NUL padding after it, up to the first argv string.
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        var index = offset
        while arguments.count < argc, index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            if index > start {
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            } else {
                arguments.append("")
            }
            index += 1 // skip the NUL terminator
        }
        return arguments
    }

    /// Live detection pass: `liveProcessTable()` fed straight through
    /// `matchExternalCaffeinates(in:)`. Split out from `enforce(...)` so a
    /// caller (a future Dashboard surface, a diagnostic command) can ask
    /// "is this happening right now" without also invoking the kill path.
    public static func detectExternalCaffeinates() -> [ExternalCaffeinateMatch] {
        matchExternalCaffeinates(in: liveProcessTable())
    }

    // MARK: - Enforcement (impure)

    /// Sends `SIGTERM` to `pid`, but only after re-confirming — right
    /// before the signal, not from a stale enumeration a tick ago — that
    /// the PID is still actually named `caffeinate`. This closes the PID-
    /// reuse race: `pid` was a `caffeinate` process when `liveProcessTable()`
    /// ran, but PIDs are recycled by the kernel, and an arbitrary amount of
    /// time (a policy check, an `Array.map`) can pass between detection and
    /// this call. Without the re-check, a `caffeinate` process that exited
    /// in that window and whose PID was immediately reassigned to an
    /// unrelated process would have this send a signal to *that* process
    /// instead — exactly the "never touch arbitrary other processes"
    /// guarantee this file exists to uphold, so it is re-verified here at
    /// the last possible moment rather than trusted from the earlier scan.
    /// `SIGTERM`, not `SIGKILL`: `caffeinate` has no state to corrupt and
    /// no cleanup to skip, so a plain, catchable terminate is enough and
    /// more conventional than forcing it. This is a `kill()` on a userspace
    /// process the user's own agent spawned — not a privileged operation,
    /// no daemon or elevated helper involved, same as
    /// `PowerControlService.isProcessRunning`'s plain libproc reads.
    @discardableResult
    public static func terminate(pid: Int32) -> Bool {
        guard currentProcessName(for: pid)?.lowercased() == "caffeinate" else { return false }
        return kill(pid, SIGTERM) == 0
    }

    private static func currentProcessName(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
    #endif

    /// One termination Sentry actually attempted, for the caller to log —
    /// see the `enforce(...)` doc comment and this file's header comment
    /// for why the actual `AlertEngine`/activity-log announcement is left
    /// to the caller rather than done here.
    public struct EnforcementOutcome: Equatable, Sendable {
        public let match: ExternalCaffeinateMatch
        public let clientName: String?
        public let terminated: Bool

        public init(match: ExternalCaffeinateMatch, clientName: String?, terminated: Bool) {
            self.match = match
            self.clientName = clientName
            self.terminated = terminated
        }
    }

    #if os(macOS)
    /// The single entry point a future integrator wires up (see this
    /// file's header comment and `AgentGuardrailSettings
    /// .enforceAgainstExternalCaffeinate`'s doc comment for the exact
    /// AppDelegate hookup this needs — deliberately not done in this file,
    /// see below). Detects, checks policy, and — only when
    /// `shouldEnforce(settings:context:)` is true and at least one match
    /// exists — terminates every matched PID, returning what happened for
    /// each so the caller can announce it.
    ///
    /// **Why this doesn't call `AlertEngine`/`MCPActivityLog` itself.**
    /// `AppDelegate.enforceAgentGuardrailRevocation` already owns the
    /// pattern this action should follow — `alertEngine.deliverGuardrailNotice`
    /// plus an `MCPActivityLogEntry` recorded under the "Sentry Guardrails"
    /// client name (see `AppDelegate.announceAgentRevocation`,
    /// `Sentry/App/AppDelegate.swift`) — but this file was written under
    /// explicit instruction not to edit `AppDelegate.swift` (owned by
    /// another workstream) or `AlertEngine.swift`. Wiring this in is
    /// therefore a **follow-up integration step**, not done here:
    /// `AppDelegate`'s snapshot loop should call
    /// `CaffeinateArbitrator.enforce(settings:context:sessions:)` alongside
    /// its existing `enforceAgentGuardrailRevocation(_:)` call, and for
    /// every `EnforcementOutcome` where `terminated == true`, call
    /// `announceAgentRevocation`-style logic — a notification via
    /// `alertEngine.deliverGuardrailNotice` and an `MCPActivityLogEntry`
    /// under "Sentry Guardrails" — so this action is exactly as visible as
    /// every other guardrail auto-revocation.
    public static func enforce(
        settings: AgentGuardrailSettings,
        context: AgentGuardrails.PowerContext,
        sessions: [AgentSessionRegistry.Session] = []
    ) -> [EnforcementOutcome] {
        guard shouldEnforce(settings: settings, context: context) else { return [] }
        let matches = detectExternalCaffeinates()
        guard !matches.isEmpty else { return [] }
        return attribute(matches: matches, sessions: sessions).map { attributed in
            EnforcementOutcome(
                match: attributed.match,
                clientName: attributed.clientName,
                terminated: terminate(pid: attributed.match.pid)
            )
        }
    }
    #endif
}
