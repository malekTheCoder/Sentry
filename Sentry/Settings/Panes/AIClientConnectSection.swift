import SwiftUI
import AppKit
import SentryKit

/// `AIAccessPane`'s "Connect Your AI Tools" section: one row per AI coding
/// tool, a Connect button that does the whole job, a Disconnect that cleanly
/// undoes it, and — for anything Sentry won't or can't write — the exact file
/// and snippet to do it by hand.
///
/// **Why this section exists.** The previous setup path was a single "Copy MCP
/// Config" button that put JSON on the clipboard and stopped. Every client
/// wants a different file, in a different place, in a different shape, and two
/// of them want a CLI command instead of a file at all — none of which the
/// clipboard can tell you. The person who wrote this app could not complete
/// that flow for their own product, which is about as clear a verdict as a
/// feature can get. An MCP server nobody manages to configure is a feature
/// that never runs, and MCP *is* what this product is sold on.
///
/// **The view stays thin on purpose.** Detection, merging, backups,
/// verification and removal all live in `SentryKit/AIClients/` as pure or
/// injectable types with their own test suite, because that is code which
/// edits other people's files and it needs to be testable without one. What is
/// left here is genuinely presentational: which rows to show, in what order,
/// and which sentence goes under each. The one piece of judgement this file
/// does own is the ordering — detected tools first — and that is here rather
/// than in the catalog so a test can still assert on the catalog's own order.
///
/// **Nothing here caches a verdict.** `refresh()` re-derives every row's state
/// from the filesystem (or the tool's own CLI), and it runs on appearance and
/// after every action. A user who edits their config by hand between two
/// glances at this pane sees the truth, not what Sentry last did.
@MainActor
final class AIClientSectionModel: ObservableObject {

    @Published private(set) var statuses: [AIClientDetector.Status] = []
    /// Keyed by client, because two clients' outcomes are independent and
    /// collapsing them into one "last message" would have a Cursor failure
    /// wiped by a subsequent Claude Desktop success.
    @Published private(set) var outcomes: [AIClientDefinition.ID: AIClientConnector.Outcome] = [:]
    @Published private(set) var isWorking: AIClientDefinition.ID?

    private let connector: AIClientConnector

    /// The live composition. Injectable for previews, and for the same reason
    /// `AIAccessPane` takes optional holders rather than building its own
    /// services: a preview must not be able to reach a real config file.
    ///
    /// Built inside the initialiser body rather than as a default-argument
    /// expression — a default argument is evaluated in the *caller's*
    /// isolation context, which need not be `@MainActor`, and
    /// `AIClientConnector.live()` is. Same reason `LocalCommandExecutor`
    /// constructs its `NonceTracker` in its body.
    init(connector: AIClientConnector? = nil) {
        self.connector = connector ?? .live()
    }

    /// Detected tools first, then the rest, each group in catalog order.
    ///
    /// Undetected tools are listed rather than hidden — a list that shows only
    /// what it found tells the user nothing about what it looked for, and
    /// somebody whose Cursor lives somewhere unusual needs to see the row in
    /// order to reach its manual instructions.
    var orderedStatuses: [AIClientDetector.Status] {
        statuses.filter(\.isDetected) + statuses.filter { !$0.isDetected }
    }

    var detectedCount: Int { statuses.filter(\.isDetected).count }

    func refresh() {
        statuses = connector.statuses()
    }

    func connect(_ definition: AIClientDefinition, bridge: MCPBridgeRegistration) {
        isWorking = definition.id
        let outcome = connector.connect(definition, bridge: bridge)
        outcomes[definition.id] = outcome
        isWorking = nil
        refresh()
    }

    func disconnect(_ definition: AIClientDefinition) {
        isWorking = definition.id
        let outcome = connector.disconnect(definition)
        outcomes[definition.id] = outcome
        isWorking = nil
        refresh()
    }

    /// The command line a user can run themselves for a CLI-driven client —
    /// the manual fallback that is *not* a file path.
    func manualCommandLine(for definition: AIClientDefinition) -> String? {
        guard case .vendorCLI(let plan) = definition.mechanism else { return nil }
        return connector.commandLinePreview(definition, plan: plan)
    }

    func manualSnippet(for definition: AIClientDefinition) -> String {
        let config = connector.snippetConfig
        if definition.manualSnippetIsTOML {
            return "[mcp_servers.\(config.serverName)]\n" + config.tomlTableBody()
        }
        let shape = definition.manualSnippetShape
        return config.snippetJSON(containerPath: shape.containerPath, dialect: shape.dialect)
    }
}

/// The section itself.
struct AIClientConnectSection: View {

    @ObservedObject var model: AIClientSectionModel

    /// The bridge's registration state, straight from the same publisher the
    /// Command-Line Access section above uses. Passed in rather than re-read
    /// so the two sections cannot disagree about it on the same screen.
    let bridge: MCPBridgeRegistration?

    @Environment(\.themePalette) private var palette
    @State private var expanded: Set<AIClientDefinition.ID> = []
    @State private var copied: AIClientDefinition.ID?

    var body: some View {
        Section {
            if let blocked = blockingReason {
                Label {
                    Text(blocked)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(palette.warning)
                }
            }

            ForEach(model.orderedStatuses) { status in
                row(status)
            }
        } header: {
            Text("Connect Your AI Tools")
        } footer: {
            Text("Connect writes the entry into that tool's own configuration, then reads it back to confirm — “Connected” below means Sentry found its entry in the file, not that it wrote one. Your existing MCP servers are merged around, never replaced, and the previous version of every file Sentry edits is copied aside first. Disconnect removes Sentry's entry and nothing else.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refresh() }
    }

    private var blockingReason: String? {
        guard let bridge else { return nil }
        return AIClientConnector.blockingReason(bridge: bridge)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ status: AIClientDetector.Status) -> some View {
        let definition = status.definition
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: iconName(for: status))
                    .foregroundStyle(iconColor(for: status))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.displayName)
                        .fontWeight(.medium)
                        .foregroundStyle(status.isDetected ? .primary : .secondary)
                    Text(stateLine(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                buttons(for: status)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(definition.displayName)
            .accessibilityValue(stateLine(status))

            if let outcome = model.outcomes[definition.id] {
                Label {
                    Text(outcome.detail)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: outcome.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(outcome.succeeded ? palette.textSecondary : palette.warning)
                }
                .padding(.leading, 22)
            }

            DisclosureGroup(isExpanded: expandedBinding(definition.id)) {
                manualInstructions(definition)
            } label: {
                Text("Set it up by hand")
                    .font(.caption)
            }
            .padding(.leading, 22)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func buttons(for status: AIClientDetector.Status) -> some View {
        let definition = status.definition
        if case .manualOnly = definition.mechanism {
            // No button at all. A disabled Connect would read as "not
            // supported yet"; the absence plus the stated reason in the
            // manual section is the honest presentation.
            Text("Manual only")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                if isConnected(status) {
                    Button("Disconnect") { model.disconnect(definition) }
                        .accessibilityLabel("Disconnect Sentry from \(definition.displayName)")
                }
                Button(isConnected(status) ? "Reconnect" : "Connect") {
                    model.connect(definition, bridge: bridge ?? .notRegistered)
                }
                .buttonStyle(.borderedProminent)
                .disabled(blockingReason != nil || model.isWorking != nil)
                .accessibilityLabel("Connect Sentry to \(definition.displayName)")
            }
        }
    }

    @ViewBuilder
    private func manualInstructions(_ definition: AIClientDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .manualOnly(let reason) = definition.mechanism {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("File") {
                Text(definition.manualPathDescription)
                    .font(.caption)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            .font(.caption)

            if let command = model.manualCommandLine(for: definition) {
                Text("Or run this in a terminal:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                snippet(command)
            }

            snippet(model.manualSnippet(for: definition))

            HStack {
                Button {
                    copy(model.manualSnippet(for: definition), from: definition.id)
                } label: {
                    Label(
                        copied == definition.id ? "Copied!" : "Copy",
                        systemImage: copied == definition.id ? "checkmark" : "doc.on.doc"
                    )
                    .font(.caption)
                }
                .accessibilityLabel("Copy the \(definition.displayName) configuration snippet")
                Link("Documentation", destination: URL(string: definition.documentationURL)!)
                    .font(.caption)
            }
        }
        .padding(.top, 4)
    }

    private func snippet(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.12)))
    }

    // MARK: - Presentation

    private func isConnected(_ status: AIClientDetector.Status) -> Bool {
        switch status.connection {
        case .connected, .connectedToDifferentBinary: return true
        case .notConnected, .unreadable, .unverifiable: return false
        }
    }

    private func iconName(for status: AIClientDetector.Status) -> String {
        switch status.connection {
        case .connected: return "checkmark.circle.fill"
        case .connectedToDifferentBinary: return "exclamationmark.triangle.fill"
        case .unreadable: return "exclamationmark.octagon.fill"
        case .unverifiable: return "questionmark.circle"
        case .notConnected: return status.isDetected ? "circle.dashed" : "circle.dotted"
        }
    }

    private func iconColor(for status: AIClientDetector.Status) -> Color {
        switch status.connection {
        case .connected: return palette.success
        case .connectedToDifferentBinary, .unreadable: return palette.warning
        case .unverifiable, .notConnected: return palette.textSecondary
        }
    }

    /// The one line under the tool's name. Every branch says what was actually
    /// observed — a path, a parse error, a reason — rather than a bare
    /// adjective, because that is what makes the claim checkable.
    private func stateLine(_ status: AIClientDetector.Status) -> String {
        switch status.connection {
        case .connected(let command):
            return String(localized: "Connected — its config points at \(command)")
        case .connectedToDifferentBinary(let command):
            return String(localized: "Configured, but pointing at \(command). Click Connect to repoint it at this copy of Sentry.")
        case .unreadable(let problem, let path):
            return String(localized: "Its configuration can't be read: \(problem) (\(path)). Sentry won't write into a file it can't parse.")
        case .unverifiable(let reason):
            return reason
        case .notConnected:
            switch status.detection {
            case .found(let evidence):
                return String(localized: "Installed (\(evidence)) — not connected yet")
            case .notFound:
                return String(localized: "Not detected on this Mac")
            }
        }
    }

    private func expandedBinding(_ id: AIClientDefinition.ID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private func copy(_ text: String, from id: AIClientDefinition.ID) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copied == id { copied = nil }
        }
    }
}
