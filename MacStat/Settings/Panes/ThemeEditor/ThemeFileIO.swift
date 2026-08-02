import AppKit
import UniformTypeIdentifiers
import MacStatKit

/// The two file panels behind §9.3's "Import/Export as `.sentrytheme`".
///
/// **Why this is its own type.** `ThemeEditorView` and `ThemePane` both need
/// import (you can bring a theme in without an editor open) and both need
/// export, and an `NSSavePanel` invocation inline in a SwiftUI `body` is four
/// lines of AppKit configuration that would then exist twice and drift. All
/// the error paths live here too, so the views only ever see "a theme" or "a
/// sentence to show the user."
///
/// **Everything is presented as a sheet on a real window, never as a free
/// alert.** A modal panel with no parent lands wherever macOS feels like
/// putting it, which for a settings window buried behind a browser means the
/// user clicks Import and apparently nothing happens.
enum ThemeFileIO {

    /// The `.sentrytheme` content type.
    ///
    /// Derived from the filename extension rather than declared in
    /// `Info.plist` as an exported UTI. That's a deliberate limitation, not
    /// an oversight: declaring the type would also claim the extension
    /// system-wide — Finder icon, "Open With", double-click-to-import — and
    /// that is a real feature (a document-open handler the app doesn't have)
    /// rather than a plist entry. Until that exists, a dynamically derived
    /// type is enough to filter the open panel and stamp the save panel, and
    /// it doesn't make a promise the app can't keep. `.json` is the fallback
    /// if `UTType` declines to synthesize one; the file is JSON either way.
    static var contentType: UTType {
        UTType(filenameExtension: ThemeDocument.fileExtension) ?? .json
    }

    /// Ask for a `.sentrytheme` file and decode it.
    ///
    /// The completion receives `nil` when the user cancelled — a cancel is
    /// not an error and must not produce an error message. A file that fails
    /// to decode is reported through `onError` with
    /// `ThemeDocumentError`'s own sentence, which names the actual problem
    /// (see that type); the theme is *not* partially applied, because
    /// `ThemeDocument.decode` either returns a fully validated theme or
    /// throws.
    static func importTheme(
        in window: NSWindow?,
        onError: @escaping (String) -> Void,
        completion: @escaping (Theme) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [contentType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose a Sentry theme file.")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // Security-scoped access is not requested: this app ships
                // unsandboxed (see `MacStat.entitlements`), so an
                // `NSOpenPanel` URL is directly readable. If the app is ever
                // sandboxed, this is one of the call sites that needs
                // `startAccessingSecurityScopedResource`.
                let data = try Data(contentsOf: url)
                completion(try ThemeDocument.decode(data))
            } catch let error as ThemeDocumentError {
                onError(error.errorDescription ?? String(localized: "That file isn't a Sentry theme."))
            } catch {
                onError(String(localized: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"))
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Write a theme to a user-chosen location.
    ///
    /// Encoding is attempted *before* the panel appears, so a theme that
    /// can't be encoded produces an error instead of a save panel that
    /// fails after the user has already picked a folder and a name.
    static func exportTheme(
        _ theme: Theme,
        in window: NSWindow?,
        onError: @escaping (String) -> Void,
        onSuccess: @escaping (URL) -> Void
    ) {
        let data: Data
        do {
            data = try ThemeDocument.encode(theme)
        } catch {
            onError(String(localized: "Couldn't prepare “\(theme.name)” for export: \(error.localizedDescription)"))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = ThemeDocument.suggestedFilename(for: theme)
        panel.prompt = String(localized: "Export")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                onSuccess(url)
            } catch {
                onError(String(localized: "Couldn't write \(url.lastPathComponent): \(error.localizedDescription)"))
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }
}
