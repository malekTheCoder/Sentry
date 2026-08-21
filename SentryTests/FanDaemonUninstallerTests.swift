import XCTest
import ServiceManagement
@testable import Sentry

/// The one-time removal of the root fan daemon older builds could install.
///
/// **What these can and cannot prove, stated up front.** The machine this
/// was written on has no fan daemon registered (`/Library/LaunchDaemons`
/// holds no Sentry entry, `launchctl print system/dev.malekswilam.sentry
/// .fandaemon` reports it not found) and no code-signing identities, so
/// `SMAppService.daemon(...).register()` could never have succeeded here
/// and `.status` can only ever answer `.notRegistered`. **No test in this
/// file has ever seen a real removal.** That is exactly why the decision is
/// a pure function over `SMAppService.Status` and why both side-effecting
/// paths are injected: the branch that fires on a real user's Mac is the
/// one this hardware cannot produce, so it is made reachable by argument
/// instead. The same split `MCPBridgeTests` and the deleted
/// `PrivilegedFanControlBackendTests` both made, for the same reason.
///
/// What is genuinely verified here: the status→action table, that the
/// no-op branch calls nothing at all, that a throwing `unregister` is
/// swallowed rather than propagated, that success is *verified* rather than
/// assumed, and that the plist name matches the file actually shipped in
/// the app bundle.
final class FanDaemonUninstallerTests: XCTestCase {

    // MARK: - The decision table

    /// The whole safety argument in one assertion. `.notRegistered` is the
    /// state of every user who never turned fan control on, and it must not
    /// produce a privileged call — a removal prompt shown to someone who
    /// never installed anything is an app accusing itself of something it
    /// did not do.
    func testOnlyRegisteredStatusesTriggerARemoval() {
        XCTAssertEqual(FanDaemonUninstaller.decide(for: .enabled), .unregister)
        XCTAssertEqual(FanDaemonUninstaller.decide(for: .requiresApproval), .unregister)
        XCTAssertEqual(FanDaemonUninstaller.decide(for: .notRegistered), .doNothing)
        XCTAssertEqual(FanDaemonUninstaller.decide(for: .notFound), .doNothing)
    }

    /// `.requiresApproval` is a registration the user has not approved yet,
    /// not an absence. Treating it as "nothing to do" would leave a pending
    /// root daemon that could still be approved later — from System
    /// Settings, by a user who no longer has any Sentry UI explaining what
    /// they are approving.
    func testPendingApprovalCountsAsInstalled() {
        XCTAssertEqual(FanDaemonUninstaller.decide(for: .requiresApproval), .unregister)
    }

    // MARK: - Behaviour

    func testNothingIsCalledWhenNothingIsRegistered() {
        var unregisterCalls = 0
        let removed = FanDaemonUninstaller.removeIfInstalled(
            statusProbe: { .notRegistered },
            unregister: { unregisterCalls += 1 }
        )

        XCTAssertEqual(unregisterCalls, 0, "a user who never installed the helper must not be touched")
        XCTAssertFalse(removed)
    }

    func testAMissingPlistIsAlsoLeftAlone() {
        var unregisterCalls = 0
        _ = FanDaemonUninstaller.removeIfInstalled(
            statusProbe: { .notFound },
            unregister: { unregisterCalls += 1 }
        )

        XCTAssertEqual(unregisterCalls, 0)
    }

    func testARegisteredDaemonIsUnregistered() {
        var unregisterCalls = 0
        // The probe answers `.enabled` first (there is something to remove)
        // and `.notRegistered` afterwards (it is gone) — the sequence a
        // successful removal produces on a real Mac.
        var answers: [SMAppService.Status] = [.enabled, .notRegistered]
        let removed = FanDaemonUninstaller.removeIfInstalled(
            statusProbe: { answers.isEmpty ? .notRegistered : answers.removeFirst() },
            unregister: { unregisterCalls += 1 }
        )

        XCTAssertEqual(unregisterCalls, 1)
        XCTAssertTrue(removed)
    }

    /// Removal is verified, not assumed. `unregister()` returning without
    /// throwing is not the same claim as "it's gone", and the honest
    /// outcome when the daemon is still there is to report failure so the
    /// next launch tries again — not to declare victory and never look
    /// back.
    func testStillBeingRegisteredAfterwardsIsNotReportedAsSuccess() {
        let removed = FanDaemonUninstaller.removeIfInstalled(
            statusProbe: { .enabled },
            unregister: { }
        )

        XCTAssertFalse(removed, "the daemon still reports .enabled; that is not a removal")
    }

    /// A failed removal must not be able to stop the app from launching.
    /// This runs on every launch, on machines this code has never been
    /// tried on, for a user who did not ask for it and has no fan UI left
    /// to be sent to — so the error is logged and swallowed.
    func testAThrowingUnregisterIsSwallowed() {
        struct Denied: Error {}
        var removed = true
        XCTAssertNoThrow(
            removed = FanDaemonUninstaller.removeIfInstalled(
                statusProbe: { .enabled },
                unregister: { throw Denied() }
            )
        )
        XCTAssertFalse(removed)
    }

    /// Idempotence, which is what lets this run unconditionally on every
    /// launch with nothing persisted to remember that it already ran: the
    /// status read *is* the memory.
    func testRunningTwiceUnregistersOnce() {
        var unregisterCalls = 0
        var status: SMAppService.Status = .enabled
        let probe: () -> SMAppService.Status = { status }
        let doUnregister = { unregisterCalls += 1; status = .notRegistered }

        _ = FanDaemonUninstaller.removeIfInstalled(statusProbe: probe, unregister: doUnregister)
        _ = FanDaemonUninstaller.removeIfInstalled(statusProbe: probe, unregister: doUnregister)

        XCTAssertEqual(unregisterCalls, 1)
    }

    // MARK: - The name, which is frozen

    /// `plistName` is not a string this project is free to change: it names
    /// a launchd job already registered on other people's Macs, and a typo
    /// is not a build error but a daemon that never gets removed. It used
    /// to be derived from `FanDaemonNaming.label`, which was deleted with
    /// the rest of the feature, so this test is what replaces the compiler
    /// as the thing holding the two halves together.
    func testPlistNameMatchesTheShippedJobDescription() throws {
        XCTAssertEqual(FanDaemonUninstaller.plistName, "dev.malekswilam.sentry.fandaemon.plist")

        // launchd requires the plist's `Label` to equal its file name minus
        // ".plist", and `SMAppService.daemon(plistName:)` looks the file up
        // by that name — so the two must agree or the service resolves to
        // nothing.
        let label = FanDaemonUninstaller.plistName.replacingOccurrences(of: ".plist", with: "")
        XCTAssertEqual(label, "dev.malekswilam.sentry.fandaemon")
    }

    /// The plist has to actually be *in the bundle*, or the uninstaller is
    /// talking to nothing: `SMAppService.daemon(plistName:)` resolves by
    /// looking this file up in `Contents/Library/LaunchDaemons/`, and with
    /// it absent every Mac reports `.notFound` and an orphaned root daemon
    /// becomes permanent. It is the one piece of the removed feature that
    /// still ships, and it ships because of this. Deleting it means
    /// deleting the uninstaller in the same commit.
    func testTheJobDescriptionStillShipsInsideTheAppBundle() throws {
        // The test bundle is loaded into the app under test (`TEST_HOST`),
        // so the host bundle is Sentry.app itself.
        let appBundle = Bundle(for: AppDelegate.self)
        let plist = try XCTUnwrap(appBundle.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(FanDaemonUninstaller.plistName) as URL?)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plist.path),
            "\(plist.path) is missing — FanDaemonUninstaller cannot remove a daemon it cannot resolve"
        )

        let contents = try Data(contentsOf: plist)
        let parsed = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: contents, format: nil) as? [String: Any]
        )
        XCTAssertEqual(parsed["Label"] as? String, "dev.malekswilam.sentry.fandaemon")
    }
}
