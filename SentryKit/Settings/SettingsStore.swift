import Foundation
import Combine
import os

/// Owns the user's `AppSettings` and persists them as JSON at
/// `~/Library/Application Support/Sentry/settings.json` (plan §4.2, §14.3),
/// alongside `HistoryStore`'s `history.sqlite`.
///
/// **Debounced writes:** mutating `settings` schedules a save rather than
/// performing one. Dragging the §8.4 refresh-interval slider emits a value per
/// frame; without coalescing that would be a disk write per frame for a file
/// nothing reads until next launch. Callers that need a guaranteed write
/// (app quit, sleep) call `save()`.
///
/// **Failure handling (P5, "never crash"):** a missing, unreadable, or corrupt
/// settings file yields `AppSettings()` defaults and a log line — never a throw
/// and never a crash. A user whose disk hiccuped once should get a working app
/// with default settings, not an app that won't launch.
///
/// **Threading:** `settings` is a SwiftUI-facing `@Published` and is expected to
/// be read/written from the main thread, like any `ObservableObject`. All file
/// IO happens on a private serial queue.
public final class SettingsStore: ObservableObject {

    private static let logger = Logger(subsystem: "dev.malekswilam.sentry.kit", category: "SettingsStore")

    /// Mutating this schedules a debounced write. Replace the whole value or
    /// poke a single field — both go through `didSet`.
    @Published public var settings: AppSettings {
        didSet {
            // Mirrored *before* the no-op guard below, and unconditionally.
            // See `mirrorTemperatureUnit()` for why this store is the thing
            // that publishes it, and why re-asserting an unchanged value is
            // free (unlike the disk write the guard exists to skip).
            mirrorTemperatureUnit()
            // A settings pane can re-assign an identical value on every view
            // update; skipping the no-op write keeps the SSD quiet.
            guard settings != oldValue else { return }
            scheduleSave()
        }
    }

    public let fileURL: URL

    private let debounceInterval: TimeInterval
    private let ioQueue = DispatchQueue(label: "dev.malekswilam.sentry.settingsstore", qos: .utility)

    /// Touched from the main thread (`scheduleSave`) and from `save()`, hence
    /// the lock; the work item itself always runs on `ioQueue`.
    private let pendingLock = NSLock()
    private var pendingSave: DispatchWorkItem?

    /// - Parameters:
    ///   - fileURL: override for tests; defaults to the real on-disk location.
    ///   - debounceInterval: seconds of quiet before a mutation is written.
    public init(
        fileURL: URL = SettingsStore.defaultSettingsURL(),
        debounceInterval: TimeInterval = 0.75
    ) {
        self.fileURL = fileURL
        self.debounceInterval = debounceInterval
        self.settings = Self.load(from: fileURL)
        // `didSet` does not fire for an assignment made inside `init`, so the
        // initial mirror has to be explicit. Without this line the app would
        // render in whatever unit the *previous* store in this process had
        // set — which on a normal launch means "Celsius, always," and the
        // preference would appear to do nothing until the user next touched
        // any setting.
        mirrorTemperatureUnit()
    }

    deinit {
        // Whatever was pending is abandoned rather than run — the object is
        // going away, and callers that care about durability call `save()`.
        pendingLock.lock()
        pendingSave?.cancel()
        pendingLock.unlock()
    }

    /// `~/Library/Application Support/Sentry/settings.json` on macOS; the
    /// app's sandboxed Application Support directory on iOS (same API, a
    /// different real path under the hood — `.applicationSupportDirectory`
    /// resolves correctly on both). The same directory `HistoryStore` uses.
    /// Duplicated rather than shared because `HistoryStore` is owned by
    /// another module area and isn't ours to edit; if a third consumer
    /// appears, this belongs in one small shared helper.
    ///
    /// The fallback deliberately isn't `homeDirectoryForCurrentUser` —
    /// that API is unavailable on iOS at all (not just sandboxed away, an
    /// actual compile error), and `SentryKit` is a shared cross-platform
    /// module (plan §12, Phase 5's iOS app). `temporaryDirectory` is
    /// available on both and, in the extremely rare case the primary call
    /// actually throws, is no worse a place to lose settings than any other
    /// guess — the point of a fallback here is "never crash," not "pick
    /// the most durable possible location."
    public static func defaultSettingsURL() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory

        return appSupport
            .appendingPathComponent("Sentry", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    // MARK: - Temperature unit mirroring

    /// Pushes `settings.temperatureUnit` into `TemperatureUnit.display`, the
    /// process-wide ambient preference every formatting site reads.
    ///
    /// **Why a store publishes into a global at all.** `TemperatureUnit
    /// .display`'s own doc comment covers why the value has to be ambient
    /// (nineteen display surfaces, most of them pure `Sendable` value types
    /// or free functions with no injection path, and the composition root
    /// that would otherwise own the wiring is a file this change is not
    /// permitted to touch). Given that it must be ambient, *this* is the
    /// right place to set it: `SettingsStore` is the single owner of the
    /// user's preferences on macOS, it already sits on both the load path
    /// and every mutation path, and putting the mirror anywhere else would
    /// mean some third party remembering to call it.
    ///
    /// **Why unconditionally, rather than only when the unit changed.** The
    /// write is an uncontended `NSLock` acquire and a one-byte store; the
    /// `settings != oldValue` guard next to it exists to skip a *disk*
    /// write, which is six orders of magnitude more expensive. Making this
    /// conditional would buy nothing and would introduce a way for the
    /// mirror to drift out of sync if the guard's semantics ever changed.
    ///
    /// **The honest caveat: this is process-wide, and more than one
    /// `SettingsStore` can exist.** In the app exactly one does. In the test
    /// suite each case constructs its own against a temporary file, so the
    /// last one built wins — which is why every temperature test passes its
    /// unit explicitly through `TemperatureFormatter`'s `in:` parameter
    /// instead of relying on the ambient value, and why the two tests that
    /// *do* exercise the ambient path save and restore it.
    private func mirrorTemperatureUnit() {
        TemperatureUnit.display = settings.temperatureUnit
    }

    // MARK: - Theme resolution

    /// Resolves `settings.themeID` against the user's custom themes and then
    /// the built-in presets, falling back to `Theme.defaultTheme` when the id
    /// is unknown — e.g. a settings file that references a custom theme the
    /// user has since deleted, or one written by a build that shipped a preset
    /// this one doesn't have.
    ///
    /// Delegates to `Theme.resolve(id:in:)` rather than repeating the lookup,
    /// because the same question is asked from `AppDelegate` (twice) and the
    /// dropdown's quick switcher, and three copies of a two-line lookup is
    /// exactly how a custom theme ends up applying to the Dashboard but not to
    /// the status item.
    public func resolvedTheme() -> Theme {
        Theme.resolve(id: settings.themeID, in: settings.customThemes)
    }

    // MARK: - Persistence

    /// Writes immediately and synchronously, cancelling any pending debounced
    /// write. Intended for app quit / sleep, where "eventually" isn't good
    /// enough. Safe to call from any thread except `ioQueue` itself.
    public func save() {
        cancelPending()
        let snapshot = settings
        ioQueue.sync { [fileURL] in
            Self.write(snapshot, to: fileURL)
        }
    }

    /// Discards any in-memory edits and re-reads from disk. Useful when the
    /// file was replaced out from under us (sync, manual edit, restore).
    public func reload() {
        cancelPending()
        settings = Self.load(from: fileURL)
    }

    /// Restores Appendix B defaults and persists them immediately, so "Reset"
    /// survives a crash that beats the debounce timer.
    ///
    /// The deviceID survives the reset: it is this Mac's identity, not a
    /// preference — rotating it would silently break the phone's
    /// reconnect-to-the-last-Mac matching for a user who only wanted their
    /// sliders back.
    public func resetToDefaults() {
        var defaults = AppSettings()
        defaults.deviceID = settings.deviceID
        settings = defaults
        save()
    }

    private func scheduleSave() {
        cancelPending()

        let snapshot = settings
        let url = fileURL
        let work = DispatchWorkItem {
            Self.write(snapshot, to: url)
        }

        pendingLock.lock()
        pendingSave = work
        pendingLock.unlock()

        ioQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func cancelPending() {
        pendingLock.lock()
        pendingSave?.cancel()
        pendingSave = nil
        pendingLock.unlock()
    }

    // MARK: - File IO

    private static func load(from url: URL) -> AppSettings {
        var settings = loadRaw(from: url)
        // The one place a device identity is minted. `AppSettings()`'s own
        // default is the empty string — a random default would make two
        // freshly-constructed values unequal, which breaks value semantics
        // (and the tests that pin them) — so the store, which owns the
        // file, owns the mint: fresh install, corrupt-file fallback, and a
        // pre-deviceID settings.json all arrive here empty and leave with
        // a stable ID. The composition root saves once at startup so the
        // mint survives the first relaunch.
        if settings.deviceID.isEmpty {
            settings.deviceID = UUID().uuidString
        }
        return settings
    }

    private static func loadRaw(from url: URL) -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // First launch is the common case, not an error worth logging as one.
            logger.info("No settings file at \(url.path, privacy: .public); using defaults")
            return AppSettings()
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // Deliberately not rethrown and not deleted: the user may want to
            // hand-repair the file, and a bad settings file must never block
            // launch (P5).
            logger.error("Failed to load settings from \(url.path, privacy: .public), falling back to defaults: \(error.localizedDescription, privacy: .public)")
            return AppSettings()
        }
    }

    private static func write(_ settings: AppSettings, to url: URL) {
        let encoder = JSONEncoder()
        // Stable, readable output: this file is small, users do open it, and
        // sorted keys keep diffs (and any future sync) from churning.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(settings)
            // Atomic so a crash mid-write leaves the previous good file rather
            // than a truncated one that would decode-fail on next launch.
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save settings to \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
