import Foundation
import Combine
import os

/// Owns the user's `AppSettings` and persists them as JSON at
/// `~/Library/Application Support/MacStat/settings.json` (plan §4.2, §14.3),
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

    private static let logger = Logger(subsystem: "dev.malekswilam.macstat.kit", category: "SettingsStore")

    /// Mutating this schedules a debounced write. Replace the whole value or
    /// poke a single field — both go through `didSet`.
    @Published public var settings: AppSettings {
        didSet {
            // A settings pane can re-assign an identical value on every view
            // update; skipping the no-op write keeps the SSD quiet.
            guard settings != oldValue else { return }
            scheduleSave()
        }
    }

    public let fileURL: URL

    private let debounceInterval: TimeInterval
    private let ioQueue = DispatchQueue(label: "dev.malekswilam.macstat.settingsstore", qos: .utility)

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
    }

    deinit {
        // Whatever was pending is abandoned rather than run — the object is
        // going away, and callers that care about durability call `save()`.
        pendingLock.lock()
        pendingSave?.cancel()
        pendingLock.unlock()
    }

    /// `~/Library/Application Support/MacStat/settings.json` — the same
    /// directory `HistoryStore` uses. Duplicated rather than shared because
    /// `HistoryStore` is owned by another module area and isn't ours to edit;
    /// if a third consumer appears, this belongs in one small shared helper.
    public static func defaultSettingsURL() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")

        return appSupport
            .appendingPathComponent("MacStat", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    // MARK: - Theme resolution

    /// Resolves `settings.themeID` against the built-in presets, falling back to
    /// Terminal (Appendix B's default) when the id is unknown — e.g. a settings
    /// file that references a custom theme the user has since deleted, or one
    /// written by a build that shipped a preset this one doesn't have.
    public func resolvedTheme() -> Theme {
        Theme.builtInPresets.first { $0.id == settings.themeID } ?? .terminal
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
    public func resetToDefaults() {
        settings = AppSettings()
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
