import AppKit
import SwiftUI
import MacStatKit

/// The Phase 1 exit-criterion debug window itself: every field of the
/// current `SystemSnapshot`, shown raw. This view is intentionally plain —
/// monospaced key/value rows, no charts, no theme colors, no rounding — the
/// entire point is that what's on screen here is directly diffable against
/// Activity Monitor / System Settings / `powermetrics` output, and any
/// styling that reformats a number is exactly the kind of thing that could
/// paper over the discrepancy a developer opened this window to find.
struct DebugDumpView: View {

    @ObservedObject var viewModel: DebugDumpViewModel
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if viewModel.sections.isEmpty {
                        Text("Waiting for the first snapshot…")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(viewModel.sections) { section in
                            sectionView(section)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Debug Snapshot Dump")
                    .font(.headline)
                if let lastUpdated = viewModel.lastUpdated {
                    // Raw `Date` description, not a relative/"2s ago" string —
                    // the same "no formatting that could mislead" rule this
                    // whole window follows.
                    Text("Last updated: \(String(describing: lastUpdated))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No snapshot yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(didCopy ? "Copied" : "Copy") {
                copyToPasteboard()
            }
            .disabled(viewModel.lastUpdated == nil)
        }
        .padding()
    }

    private func sectionView(_ section: SnapshotDebugFormatter.Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.name)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)

            if section.fields.isEmpty {
                Text("(no fields)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(section.fields) { field in
                    fieldRow(field)
                }
            }
        }
    }

    private func fieldRow(_ field: SnapshotDebugFormatter.Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(field.name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)

            Text(field.value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

            Spacer()

            Text(field.type)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    /// `NSPasteboard`, not `UIPasteboard` — this window is macOS-only, same
    /// as the rest of `MacStat` (the app target, as opposed to `MacStatKit`
    /// which is shared with the iOS companion).
    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.plainTextDump, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }
}
