import AppKit
import MacStatKit

/// Owns the `NSStatusItem` and the custom view inside it (plan §8.1).
///
/// Deliberately knows nothing about the dropdown: it exposes `onClick` and the
/// underlying button, and whoever wires the app decides what a click opens.
/// That keeps the popover (SwiftUI) and the bar item (AppKit) from having to
/// know about each other.
@MainActor
final class StatusItemController {

    /// Invoked on click. The integrator points this at the dropdown popover.
    var onClick: (() -> Void)?

    private let item: NSStatusItem
    private let contentView: StatusItemView

    /// Exposed so the caller can anchor an `NSPopover` to the bar item.
    var statusItem: NSStatusItem { item }
    var button: NSStatusBarButton? { item.button }

    init(layout: MenuBarLayout, theme: Theme) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        contentView = StatusItemView(layout: layout, theme: theme)

        if let button = item.button {
            // The button keeps its own highlight/click behavior; the custom
            // view only paints (it returns nil from `hitTest`).
            button.image = nil
            button.title = ""
            contentView.frame = button.bounds
            contentView.autoresizingMask = [.width, .height]
            button.addSubview(contentView)

            button.target = self
            button.action = #selector(buttonClicked)
            // Right-click should open the same dropdown rather than doing
            // nothing — there is no separate context menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(contentView.accessibilitySummary)
        }
        resize()
    }

    /// Removes the item from the menu bar. `NSStatusBar` retains its items, so
    /// dropping the controller alone leaves a dead slot behind — and this
    /// can't live in `deinit`, which is nonisolated and so can't touch
    /// main-actor AppKit state.
    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: - Input

    /// Push a new snapshot: appends history, re-lays out, and redraws.
    func update(_ snapshot: SystemSnapshot) {
        contentView.update(snapshot)
        resize()
    }

    func apply(layout: MenuBarLayout) {
        contentView.apply(layout: layout)
        resize()
    }

    func apply(theme: Theme) {
        contentView.apply(theme: theme)
        resize()
    }

    // MARK: - Private

    private func resize() {
        let width = contentView.intrinsicContentSize.width
        // Assigning `length` is not free (it re-lays out the whole menu bar),
        // so it's only touched when the width actually moved (P6).
        if abs(item.length - width) > 0.5 {
            item.length = width
        }
        item.button?.setAccessibilityLabel(contentView.accessibilitySummary)
    }

    @objc private func buttonClicked() {
        onClick?()
    }
}
