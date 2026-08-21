import Foundation

// MARK: - KeepAwakeCommandSender: one connection per process, for surfaces that live outside the app

/// Sends a keep-awake `ControlCommand` and reports what actually happened,
/// for the control surfaces that do not run inside `SentryMobile`'s process
/// and therefore cannot reach `AppDataSource.shared`: the Control Center
/// toggle and the Live Activity's End button, both of which execute inside
/// `SentryWidgetExtension`.
///
/// **Why an app extension needs its own transport at all.** An extension is
/// a separate process from its containing app. There is no in-process
/// singleton to share even if the module boundary allowed referencing one
/// (it does not — an appex cannot import its host app's target), so every
/// invocation needs *a* `LocalSyncClient` the same way `AppDataSource` needs
/// one. What it must not need is a *new* one per tap: one Bonjour browser
/// and one socket per process, not one per button press, which is why this
/// is an actor with a shared instance holding a single client rather than a
/// free function that constructs one.
///
/// **Why this lives in `SentryKit` rather than in `SentryWidget/`.** Its
/// first caller was `WidgetControlTransport`, declared inside
/// `MacAwakeControlWidget.swift` and reachable only from that extension.
/// `EndKeepAwakeIntent` (`SentryWidget/Intents/EndKeepAwakeIntent.swift`) is
/// a `LiveActivityIntent`, which Apple documents as being performed in the
/// *app's* process, and which therefore has to be compiled into both the app
/// and the extension — so its transport has to be a symbol both targets can
/// see, and the framework both already link is the only such place. Rather
/// than leave two clients in one extension, the Control Center toggle was
/// moved onto this type too: one process, one connection, one place where
/// "what did the Mac say" is turned into a value.
///
/// **Deliberately never falls back to a mock.** `AppDataSource
/// .resolveIfNeeded()` falls back to `MockDataSource` so the app has
/// something to browse; a *control* surface that silently "succeeded"
/// against fabricated data would be the dishonest widget
/// `WidgetSnapshot.sourceIsDemoData`'s doc comment warns against. There is
/// no demo mode down here — either a real Mac confirmed the command, or the
/// caller gets a `KeepAwakeCommandOutcome` saying which way it failed.
public actor KeepAwakeCommandSender {

    public static let shared = KeepAwakeCommandSender()

    /// Mirrors `SentryIntents.statusTimeout` — long enough for a real
    /// Bonjour discovery plus TCP handshake on a healthy local network,
    /// short enough that a Lock Screen tap or a Control Center toggle does
    /// not hang the system UI waiting on a Mac that is not there at all.
    public static let timeout: TimeInterval = 5

    private let client = LocalSyncClient()

    public init() {}

    /// Sends `command`, waits for the Mac's `ControlStatus`, and reports the
    /// outcome. Never throws: every failure mode is one of
    /// `KeepAwakeCommandOutcome`'s cases, because the callers are buttons
    /// that must *show* something rather than propagate an error nobody
    /// catches.
    ///
    /// `waitForFirstConnection(timeout:)` returns immediately when already
    /// connected (see its doc comment), so calling this on every invocation
    /// costs nothing once a connection exists, and re-attempts discovery on
    /// every call while one does not — rather than latching a permanent
    /// "gave up" state that would keep failing for the rest of the process's
    /// lifetime after one transient miss.
    public func send(_ command: ControlCommand) async -> KeepAwakeCommandOutcome {
        guard await client.waitForFirstConnection(timeout: Self.timeout) else {
            return .noMacConnected
        }
        do {
            try await client.send(command: command)
        } catch {
            return .notSent(error.localizedDescription)
        }
        guard let status = await client.awaitStatus(forNonce: command.nonce, timeout: Self.timeout) else {
            return .unanswered
        }
        return Self.outcome(for: status)
    }

    /// Maps a `ControlStatus` onto the outcome vocabulary. Split out so the
    /// mapping is a pure function `SentryTests` can pin without a socket —
    /// the state strings are a wire contract with `LocalSyncServer`, and
    /// "which reply states count as success" is exactly the kind of thing
    /// that should not be discoverable only by running it against a Mac.
    ///
    /// Mirrors `SentryIntents.sendAndDescribe(_:whenCompleted:)`'s switch,
    /// including its treatment of an unrecognised state: the Mac's own
    /// message is surfaced rather than guessed at, and it is *not* treated
    /// as success.
    public static func outcome(for status: ControlStatus) -> KeepAwakeCommandOutcome {
        switch status.state {
        case "completed":
            return .completed
        case "rejected":
            return .declined(status.message)
        case "expired":
            return .declined(String(localized: "That request expired before your Mac could act on it."))
        default:
            return .declined(status.message)
        }
    }
}

// MARK: - Command construction

/// The `releaseAwake` command, in one place.
///
/// `KeepAwakeRequest` already owns the *keep-awake* encoding for every
/// surface that asks for one (see that type's doc comment for the drift it
/// was created to stop). Release has no parameters to get wrong, but it does
/// have three constants that four call sites were independently spelling —
/// the command type, the empty parameter object, and the five-minute expiry
/// window `LocalCommandExecutor` checks — and a Live Activity's End button
/// is a fourth surface that must send something byte-identical to what the
/// app's own "End Now" button sends, or the Mac would be answering two
/// different questions depending on where the user tapped.
///
/// `deviceID: "unknown"` matches `SentryIntents.targetDeviceID()`'s fallback
/// for the same reason it does there: this transport's wire protocol has no
/// device catalog, `LocalSyncServer` does not route or reject on the field
/// (the authenticated connection is itself the addressing), so it is
/// honestly a label rather than a routing key.
extension KeepAwakeRequest {

    /// How long a command stays valid — the same window every other surface
    /// in this app stamps onto a `ControlCommand`.
    public static let commandLifetime: TimeInterval = 5 * 60

    public static func releaseCommand(deviceID: String = "unknown", now: Date = Date()) -> ControlCommand {
        ControlCommand(
            deviceID: deviceID,
            issuedAt: now,
            commandType: "releaseAwake",
            parametersJSON: "{}",
            nonce: UUID().uuidString,
            expiresAt: now.addingTimeInterval(commandLifetime)
        )
    }
}
