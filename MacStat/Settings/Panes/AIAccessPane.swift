import SwiftUI
import AppKit
import Combine
import MacStatKit

/// Plan §13.4's Settings → AI Access pane: the one place a user actually sees
/// and controls what `MacStatMCP` — a process Claude Desktop/Code/Cursor
/// spawns, not this app — is allowed to do. Every toggle here binds straight
/// into `store.settings`; `MCPXPCService`/`MCPAccessController` are what
/// actually enforce it (see those types' doc comments) — this pane's whole
/// job is to make the *current* enforcement state legible, not to enforce
/// anything itself.
///
/// **"Zero network," said loudly and truthfully — and now conditionally
/// (plan §13.4).** `MacStatMCP` (`MacStatMCP/main.swift`) talks to Claude
/// over the stdio pipes its parent process already owns, and to
/// `MacStat.app` over a local `NSXPCConnection` to a Mach service — neither
/// is a socket that leaves this Mac, and that claim was originally
/// unconditional. It no longer can be: "Remote Access" below
/// (`MCPRemoteServer`) is a real, LAN-reachable HTTP transport, off by
/// default. The Privacy section's copy switches based on
/// `mcpRemoteAccessEnabled` rather than leaving the old absolute claim in
/// place once it would be false — the same "never overclaim" standard
/// `SyncPane`'s doc comment sets for the opposite situation (a feature that
/// doesn't work yet). Local/stdio MCP genuinely still makes zero network
/// connections regardless of this toggle; only Remote Access changes that.
struct AIAccessPane: View {

    @ObservedObject var store: SettingsStore

    /// `nil` when the settings window was constructed without a live
    /// `MCPActivityLog` (e.g. a preview, or a build predating this pane) —
    /// shown as an explicit "log unavailable" state, same convention as
    /// `AlertsPane.historyIsAvailable`, rather than a silently-empty list
    /// that would read as "nothing has ever been called."
    @ObservedObject var activityLogHolder: ActivityLogHolder

    /// Backs the Command-Line Access section. `nil` when this pane was built
    /// without one (a preview) — rendered as an explicit "unavailable" row,
    /// same convention as `activityLogHolder`, never as a missing section.
    @ObservedObject var endpointHolder: EndpointPublisherHolder

    init(
        store: SettingsStore,
        activityLog: MCPActivityLog?,
        endpointPublisher: MCPEndpointPublisher? = nil
    ) {
        self.store = store
        self._activityLogHolder = ObservedObject(wrappedValue: ActivityLogHolder(activityLog: activityLog))
        self._endpointHolder = ObservedObject(wrappedValue: EndpointPublisherHolder(publisher: endpointPublisher))
    }

    /// The outcome of the most recent explicit setup action, shown verbatim.
    /// Nil until the user does something — this pane never displays a result
    /// for an action nobody took. Same rule `FanControlPane` follows for the
    /// fan helper.
    @State private var lastSetupMessage: String?
    @State private var lastSetupWasFailure = false

    @Environment(\.themePalette) private var palette

    @State private var copiedConfig = false
    @State private var copiedRemoteConfig = false
    @State private var remoteAPIKey: String?
    @State private var showAPIKey = false

    var body: some View {
        Form {
            Section {
                Label {
                    Text(
                        store.settings.mcpRemoteAccessEnabled
                            ? "Local MCP still makes zero network connections — Remote Access below is separate"
                            : "Sentry makes zero network connections for MCP"
                    )
                    .fontWeight(.semibold)
                } icon: {
                    Image(systemName: store.settings.mcpRemoteAccessEnabled ? "network" : "network.slash")
                        .foregroundStyle(.secondary)
                }
                Text(
                    store.settings.mcpRemoteAccessEnabled
                        ? "An MCP client spawned locally (Claude Desktop, Claude Code, Cursor, …) still talks to MacStatMCP over stdio only — that hop never leaves this Mac. Remote Access, enabled below, is a separate, LAN-reachable HTTP server gated by its own API key. It's the one thing on this pane that does leave this Mac, by design, only while you have it turned on."
                        : "An MCP client (Claude Desktop, Claude Code, Cursor, …) spawns MacStatMCP as a local subprocess and talks to it over stdio. MacStatMCP talks to this app over local XPC only. Neither hop ever leaves this Mac — there is no server, no account, and nothing to intercept."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Privacy")
            }

            commandLineSection

            Section {
                Toggle("Allow AI agents to connect", isOn: $store.settings.mcpServerEnabled)
                    .accessibilityLabel("Allow AI agents to connect")
                    .accessibilityValue(store.settings.mcpServerEnabled ? "On" : "Off")

                Toggle("Allow write tools (control actions)", isOn: $store.settings.mcpWriteToolsEnabled)
                    .disabled(!store.settings.mcpServerEnabled)
                    .accessibilityLabel("Allow write tools")
                    .accessibilityValue(store.settings.mcpWriteToolsEnabled ? "On" : "Off")

                Stepper(
                    value: $store.settings.mcpRateLimitPerMinute,
                    in: 1...120
                ) {
                    LabeledContent("Rate limit", value: "\(store.settings.mcpRateLimitPerMinute) calls / min")
                }
                .disabled(!store.settings.mcpServerEnabled)
                .accessibilityLabel("Maximum MCP tool calls per minute")
                .accessibilityValue("\(store.settings.mcpRateLimitPerMinute)")
            } header: {
                Text("Master Switches")
            } footer: {
                Text("Read tools are enabled by default and can only ever fetch data this app already has. Write tools — anything that changes power state, polling cadence, or alert rules — are off by default and gated by both this master switch and their own individual toggle below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(MCPToolID.readTools, id: \.self) { tool in
                    toolToggleRow(tool)
                }
            } header: {
                Text("Read Tools")
            }

            Section {
                ForEach(MCPToolID.writeTools, id: \.self) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        toolToggleRow(tool)
                        Toggle(
                            "Require confirmation",
                            isOn: confirmationBinding(for: tool)
                        )
                        .font(.caption)
                        .disabled(!isToolEnabled(tool) || !store.settings.mcpWriteToolsEnabled || !store.settings.mcpServerEnabled)
                        .accessibilityLabel("Require confirmation for \(tool.displayName)")
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Write Tools")
            } footer: {
                Text("\"Require confirmation\" shows a native dialog in Sentry before the action runs, every time — the agent's call is paused until you allow or deny it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button {
                    copyMCPConfig()
                } label: {
                    Label(copiedConfig ? "Copied!" : "Copy MCP Config", systemImage: copiedConfig ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel("Copy MCP configuration JSON")

                Text("Paste this into Claude Desktop's, Claude Code's, or Cursor's MCP server configuration to connect them to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(Self.mcpConfigJSON())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
            } header: {
                Text("Client Setup")
            }

            Section {
                Toggle("Allow remote access over your local network", isOn: remoteAccessToggleBinding)
                    .accessibilityLabel("Allow remote access over your local network")
                    .accessibilityValue(store.settings.mcpRemoteAccessEnabled ? "On" : "Off")

                if store.settings.mcpRemoteAccessEnabled {
                    LabeledContent("Address", value: remoteAddress)
                        .textSelection(.enabled)

                    Stepper(value: $store.settings.mcpRemotePort, in: 1024...65535) {
                        LabeledContent("Port", value: "\(store.settings.mcpRemotePort)")
                    }
                    .accessibilityLabel("Remote access port")
                    .accessibilityValue("\(store.settings.mcpRemotePort)")

                    HStack {
                        Text("API Key")
                        Spacer()
                        Text(showAPIKey ? (remoteAPIKey ?? "—") : maskedAPIKey)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Button(showAPIKey ? "Hide" : "Reveal") {
                            showAPIKey.toggle()
                        }
                        Button("Regenerate") {
                            remoteAPIKey = MCPRemoteAccessKey.regenerate()
                            copiedRemoteConfig = false
                        }
                    }

                    Button {
                        copyRemoteConfig()
                    } label: {
                        Label(copiedRemoteConfig ? "Copied!" : "Copy Remote Config", systemImage: copiedRemoteConfig ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("Copy remote MCP configuration JSON")

                    Text(remoteConfigJSON())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
                }
            } header: {
                Text("Remote Access")
            } footer: {
                Text("Reachable from other devices on your local Wi-Fi/network — not the public internet, assuming your router isn't forwarding this port. Anyone with the API key above can call Sentry's tools; regenerate it if it's ever shared by mistake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if let activityLog = activityLogHolder.activityLog {
                    if activityLog.entries.isEmpty {
                        Text("No MCP calls yet this session.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(activityLog.entries.prefix(50)) { entry in
                            activityRow(entry)
                        }
                        Button("Clear Log", role: .destructive) {
                            activityLog.clear()
                        }
                    }
                } else {
                    Text("Activity log unavailable in this window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Activity Log")
            } footer: {
                Text("Shows calls made since Sentry last launched — this is a live session view, not durable history, and clears on relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            remoteAPIKey = MCPRemoteAccessKey.current()
            // The registration can go from "waiting for approval" to
            // "registered" entirely outside this app — the user flips a switch
            // in System Settings, and nothing notifies us. Re-reading on
            // appearance is the cheap, prompt-free way to avoid showing a
            // stale "go approve it" message to somebody who just did.
            // `FanControlPane` refreshes its helper status for exactly the
            // same reason.
            endpointHolder.publisher?.refresh()
        }
    }

    // MARK: - Command-line access

    /// Where a user finds out that `macstat` and the stdio MCP server need one
    /// piece of setup, and does it.
    ///
    /// **Why this is a button and not something the app does at launch.**
    /// Registering the bridge adds an entry to the user's Login Items &
    /// Extensions. Doing that silently, on first run, for a feature most people
    /// will never use, would mean the first they hear of a background item
    /// installed on their behalf is finding it in System Settings.
    /// `FanControlPane`'s helper section sets the standard this follows:
    /// consequences before the button, one screen, and the result reported
    /// verbatim — including the failure, especially the failure.
    ///
    /// **Two facts, kept separate on purpose.** "Is the bridge registered" and
    /// "has Sentry connected to it" fail for different reasons and have
    /// different fixes, and collapsing them into one green tick would send a
    /// user whose build is unsigned to go looking at Login Items. The second
    /// row appears only once the first is satisfied, because until then it has
    /// nothing to add.
    @ViewBuilder
    private var commandLineSection: some View {
        Section {
            if let publisher = endpointHolder.publisher {
                Label {
                    Text(publisher.registration.shortLabel)
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: publisher.registration.isUsable ? "checkmark.shield" : "terminal")
                        .foregroundStyle(publisher.registration.isUsable ? palette.textSecondary : palette.warning)
                }

                Text(publisher.registration.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if publisher.registration.isUsable {
                    // Only meaningful once the bridge exists to be connected
                    // to. Shown even when it succeeded, because "set up" and
                    // "working right now" are different claims and this pane
                    // does not get to make the second one on the strength of
                    // the first.
                    Label {
                        Text(publisher.isPublished
                             ? "Sentry is connected to the bridge — `macstat` and the stdio MCP server can reach it now."
                             : (publisher.lastPublishFailure.map { "Sentry couldn't connect to the bridge: \($0)" }
                                ?? "Sentry hasn't connected to the bridge yet."))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: publisher.isPublished ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(publisher.isPublished ? palette.textSecondary : palette.warning)
                    }

                    Button("Turn off command-line access") { removeBridge(publisher) }
                } else {
                    Button("Set Up Command-Line Access…") { setUpBridge(publisher) }
                }

                if let lastSetupMessage {
                    Label {
                        Text(lastSetupMessage)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: lastSetupWasFailure ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(lastSetupWasFailure ? palette.warning : palette.textSecondary)
                    }
                }
            } else {
                // Explicit, not absent. See `SettingsView.endpointPublisher`.
                Text("This settings window was opened without a connection to Sentry's command-line bridge, so its state can't be shown or changed here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Command-Line Access")
        } footer: {
            Text("This covers the `macstat` command and the stdio MCP server that Claude Desktop, Claude Code and Cursor spawn. Both reach Sentry through a background item macOS starts on demand and stops again when it's idle; it holds no data, makes no network connection, and passes no tool call — it only tells the tools where Sentry is. Everything those tools are then allowed to do is governed by the switches below, unchanged.\n\nmacOS lists it under Login Items & Extensions, where you can switch it off at any time. Remote Access, further down, is a separate transport and doesn't use this.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setUpBridge(_ publisher: MCPEndpointPublisher) {
        do {
            try publisher.register()
            lastSetupWasFailure = false
            lastSetupMessage = publisher.registration.isUsable
                ? "Command-line access is set up."
                : "macOS accepted the request but hasn't enabled the background item yet. Check System Settings ▸ General ▸ Login Items & Extensions."
        } catch {
            // Printed, not swallowed. On a build signed with anything other
            // than a real Developer ID identity this is where the user finds
            // out — registration genuinely cannot succeed, and a setup button
            // that failed silently would leave `macstat` failing for a reason
            // nothing on screen explains.
            lastSetupWasFailure = true
            lastSetupMessage = "macOS wouldn't set up command-line access: \(error.localizedDescription)"
        }
    }

    private func removeBridge(_ publisher: MCPEndpointPublisher) {
        do {
            try publisher.unregister()
            lastSetupWasFailure = false
            lastSetupMessage = "Command-line access is turned off. `macstat` and the stdio MCP server can no longer reach Sentry."
        } catch {
            lastSetupWasFailure = true
            lastSetupMessage = "macOS wouldn't turn off command-line access: \(error.localizedDescription)"
        }
    }

    // MARK: - Remote Access

    /// Turning this on generates a key immediately if none exists yet — the
    /// URL/config below need a real key to display, and a toggle that's "on"
    /// with no key would mean `MCPRemoteServer` refuses to start at all (see
    /// its own `.noAdjustableAssertion`-style guard) with no visible
    /// explanation in this pane for why.
    private var remoteAccessToggleBinding: Binding<Bool> {
        Binding(
            get: { store.settings.mcpRemoteAccessEnabled },
            set: { newValue in
                if newValue, remoteAPIKey == nil {
                    remoteAPIKey = MCPRemoteAccessKey.regenerate()
                }
                store.settings.mcpRemoteAccessEnabled = newValue
            }
        )
    }

    private var remoteAddress: String {
        "http://\(ProcessInfo.processInfo.hostName):\(store.settings.mcpRemotePort)/mcp"
    }

    private var maskedAPIKey: String {
        guard let remoteAPIKey, !remoteAPIKey.isEmpty else { return "—" }
        return String(repeating: "•", count: min(remoteAPIKey.count, 24))
    }

    private func copyRemoteConfig() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(remoteConfigJSON(), forType: .string)
        copiedRemoteConfig = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedRemoteConfig = false
        }
    }

    /// Second variant of `mcpConfigJSON()` — `url`+bearer-token shaped
    /// rather than `command`-shaped, for a client that can only reach
    /// MacStat over the network (e.g. a web-based custom connector), not by
    /// spawning a local subprocess.
    private func remoteConfigJSON() -> String {
        let key = remoteAPIKey ?? "<no key generated yet>"
        return """
        {
          "mcpServers": {
            "MacStat-Remote": {
              "url": "\(remoteAddress)",
              "headers": {
                "Authorization": "Bearer \(key)"
              }
            }
          }
        }
        """
    }

    // MARK: - Rows

    private func toolToggleRow(_ tool: MCPToolID) -> some View {
        HStack {
            Toggle(tool.displayName, isOn: enabledBinding(for: tool))
                .disabled(!store.settings.mcpServerEnabled || (tool.isWrite && !store.settings.mcpWriteToolsEnabled))
                .accessibilityLabel(tool.displayName)
                .accessibilityValue(isToolEnabled(tool) ? "On" : "Off")
            Spacer()
            if let risk = tool.riskLabel {
                Text(risk)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(risk == "Medium" ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2)))
                    .foregroundStyle(.secondary)
            }
        }
        .help(tool.toolDescription)
    }

    private func activityRow(_ entry: MCPActivityLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.decision.isDenied ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(entry.decision.isDenied ? .red : .green)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.tool.displayName)
                        .fontWeight(.medium)
                    Text("· \(entry.clientName)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.timestamp, style: .time)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                Text(decisionLabel(entry.decision))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func decisionLabel(_ decision: MCPAccessController.Decision) -> String {
        switch decision {
        case .allow: return "Allowed"
        case .denyMasterDisabled: return "Denied — MCP disabled"
        case .denyToolDisabled: return "Denied — tool disabled"
        case .denyRateLimited: return "Denied — rate limited"
        case .requiresConfirmation: return "Denied — user declined"
        }
    }

    // MARK: - Bindings

    private func isToolEnabled(_ tool: MCPToolID) -> Bool {
        store.settings.mcpEnabledToolIDs.contains(tool.rawValue)
    }

    private func enabledBinding(for tool: MCPToolID) -> Binding<Bool> {
        Binding(
            get: { isToolEnabled(tool) },
            set: { newValue in
                var ids = store.settings.mcpEnabledToolIDs
                if newValue {
                    ids.insert(tool.rawValue)
                } else {
                    ids.remove(tool.rawValue)
                }
                store.settings.mcpEnabledToolIDs = ids
            }
        )
    }

    private func confirmationBinding(for tool: MCPToolID) -> Binding<Bool> {
        Binding(
            get: { store.settings.mcpConfirmationRequiredToolIDs.contains(tool.rawValue) },
            set: { newValue in
                var ids = store.settings.mcpConfirmationRequiredToolIDs
                if newValue {
                    ids.insert(tool.rawValue)
                } else {
                    ids.remove(tool.rawValue)
                }
                store.settings.mcpConfirmationRequiredToolIDs = ids
            }
        )
    }

    // MARK: - Copy MCP Config

    private func copyMCPConfig() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.mcpConfigJSON(), forType: .string)
        copiedConfig = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedConfig = false
        }
    }

    /// Plan §13.4's exact JSON snippet, with the command path resolved from
    /// this running app's own bundle rather than hardcoded to
    /// `/Applications/MacStat.app/...` — the plan's literal example assumes
    /// an installed, `/Applications`-located copy, but a user running from
    /// `~/Downloads` or a dev build would get a config that silently points
    /// at nothing. `MacStatMCP` is a sibling binary inside the same
    /// `Contents/MacOS/` directory this app's own executable lives in
    /// (`project.yml`'s `MacStatMCP` target, `type: tool`, builds into the
    /// same product directory as `MacStat.app`'s helper tools), so deriving
    /// it from `Bundle.main.executablePath` is both more honest and more
    /// useful than the plan's fixed path.
    static func mcpConfigJSON() -> String {
        let mcpPath = resolvedMCPBinaryPath()
        return """
        {
          "mcpServers": {
            "MacStat": {
              "command": "\(mcpPath)"
            }
          }
        }
        """
    }

    static func resolvedMCPBinaryPath() -> String {
        guard let executablePath = Bundle.main.executablePath else {
            return "/Applications/Sentry.app/Contents/MacOS/MacStatMCP"
        }
        let macOSDir = (executablePath as NSString).deletingLastPathComponent
        return (macOSDir as NSString).appendingPathComponent("MacStatMCP")
    }
}

/// Thin `ObservableObject` wrapper so `AIAccessPane` can hold an *optional*
/// `MCPActivityLog` (itself `@MainActor`-isolated `ObservableObject`) as an
/// `@ObservedObject` — SwiftUI's `@ObservedObject` property wrapper doesn't
/// support an `Optional<some ObservableObject>` directly, and this pane
/// needs to keep rendering (with an explicit "unavailable" state) rather
/// than force-unwrap when no activity log was passed in.
@MainActor
/// Republishes `MCPEndpointPublisher`'s changes to SwiftUI through an
/// optional.
///
/// The same trick — and the same reason — as `ActivityLogHolder` below:
/// `@ObservedObject` cannot wrap an optional, and the honest model here really
/// is "there may be no publisher" (see `SettingsView.endpointPublisher`). The
/// alternative, a non-optional publisher constructed on demand by the pane,
/// would mean a preview silently owning a second anonymous XPC listener.
///
/// No explicit `@MainActor`: `ObservableObject` already carries it here, and
/// stating it twice is an error rather than emphasis.
final class EndpointPublisherHolder: ObservableObject {
    let publisher: MCPEndpointPublisher?
    private var cancellable: Any?

    init(publisher: MCPEndpointPublisher?) {
        self.publisher = publisher
        if let publisher {
            cancellable = publisher.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
}

final class ActivityLogHolder: ObservableObject {
    let activityLog: MCPActivityLog?
    private var cancellable: Any?

    init(activityLog: MCPActivityLog?) {
        self.activityLog = activityLog
        if let activityLog {
            cancellable = activityLog.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
}
