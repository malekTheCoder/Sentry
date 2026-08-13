import Foundation

// MARK: - The two flows

/// The step lists themselves: what each platform's walkthrough teaches, in
/// order, and in words.
///
/// **The editorial rule every string below is written to, and which
/// `WalkthroughCopyTests` enforces where it can.** A walkthrough is the one
/// screen a user reads while they still have no way to check what it claims,
/// so nothing here may say anything the build does not do. In practice that
/// meant deleting three sentences during drafting, each worth recording so
/// they don't get re-added by somebody working from the marketing site:
///
/// 1. **"Right-click the icon for Settings."** The one-screen `WelcomeView`
///    this walkthrough replaced said exactly that, and it was not true.
///    `StatusItemController.init` sends the *same* action on
///    `.leftMouseUp` and `.rightMouseUp` with the comment "Right-click
///    should open the same dropdown rather than doing nothing — there is no
///    separate context menu." Settings is reached from the gear button in
///    the dropdown's bottom row (`DropdownView`'s `DropdownIconAction`).
///    The copy below says that instead.
///
/// 2. **"Turn on Local Access for same-Wi-Fi sync."** There is no such
///    toggle. `AppDelegate` starts `localSyncServer` unconditionally at
///    launch; `SyncPane`'s only sync switch is Remote Access ("Allow
///    connections from other networks"), which is what mints the pairing
///    code and draws the QR. The phone's existing three-screen onboarding
///    tells users to turn on a toggle that does not exist; the replacement
///    below does not.
///
/// 3. **"Ask Siri whether agent access is paused."** `GetAgentGuardrailsStatusIntent`
///    exists and its read path is real, but it reads
///    `SystemSnapshot.agentAccessPaused`, which `StatsCoordinator`'s own doc
///    comment says no composition root assigns yet — so on every real Mac
///    today it answers "your Mac hasn't reported whether agent access is
///    paused." Shipping a walkthrough that sends a brand-new user to a Siri
///    command that cannot work is worse than not mentioning it. The phone's
///    agent step points at the Mac, which is where the controls actually
///    are.
///
/// **Numbers are quoted only where they are constants of this build**, and
/// then only ones a reader could verify: the 20% default battery floor
/// (`AgentGuardrailSettings.batteryFloorPercent`), the score being out of
/// 100 (`ProtectionScore.maximum`), the two free findings
/// (`ProGate.freeInsightAllowance`). No step claims a reading from the
/// user's own Mac — the Mac walkthrough's one live element is the menu bar
/// preview, which carries the "sample values, not live readings" label
/// `MenuBarPreviewStrip` already draws for itself.

// MARK: - macOS

/// The Mac walkthrough, in order.
///
/// **What determined the order.** Not importance — sequence. The first two
/// steps answer "where is this app," which a user cannot use anything else
/// until they know. Then the three features they would otherwise never find
/// (Keep Awake lives only in the dropdown; Insights is a window behind a
/// settings tab; the MCP server is off by default). Permissions are asked
/// *inside* the step that explains why they're wanted — notifications on the
/// alerts step, location on the location-log step — rather than in an
/// up-front block, which is the pattern `AppSettings.locationLogEnabled`'s
/// doc comment already insists on for that permission specifically ("a
/// permission prompt a user didn't ask for, tied to a setting they didn't
/// know existed, is the opposite of the explicit, user-initiated permission
/// flow this feature requires").
///
/// **Why the optional permission is last of the substantive steps.**
/// `.locationLog` is the only step whose feature most users will not want.
/// Putting it ninth means someone who abandons the flow early has still been
/// taught everything that isn't optional; putting it third would mean the
/// most-declined prompt lands before the most interesting content.
public enum MacWalkthroughStep: String, WalkthroughStep {

    case menuBar
    case composeBar
    case keepAwake
    case alerts
    case insights
    case agents
    case companion
    case locationLog
    case done

    /// The flow order — `allCases` *is* the sequence (`WalkthroughFlow`
    /// indexes into it), and this hand-written list exists to exclude
    /// `.locationLog` for 1.0: the Location Log pane is hidden this release,
    /// and a walkthrough step that requests location permission for a log
    /// the user then has no surface to view or manage would be exactly the
    /// permission-without-a-feature flow `AppSettings.locationLogEnabled`'s
    /// doc comment forbids. The case, its copy, `LocationLogControl`, and
    /// the pane all stay compiled — restoring the feature in 1.1 is
    /// reinserting `.locationLog` here (and updating the step count quoted
    /// in `GeneralPane`'s walkthrough copy, which
    /// `WalkthroughFlowTests.testStepCountsMatchTheCountsQuotedInSettingsCopy`
    /// will force).
    public static var allCases: [MacWalkthroughStep] {
        [.menuBar, .composeBar, .keepAwake, .alerts, .insights, .agents, .companion, .done]
    }

    public var role: WalkthroughStepRole {
        switch self {
        case .menuBar, .composeBar, .insights: return .teach
        case .keepAwake, .agents, .companion: return .setup
        case .alerts, .locationLog: return .permission
        case .done: return .finish
        }
    }

    public var symbolName: String {
        switch self {
        case .menuBar: return "menubar.rectangle"
        case .composeBar: return "slider.horizontal.3"
        case .keepAwake: return "cup.and.saucer"
        case .alerts: return "bell.badge"
        case .insights: return "checkmark.shield"
        case .agents: return "bolt.shield"
        case .companion: return "laptopcomputer.and.iphone"
        case .locationLog: return "location"
        case .done: return "checkmark.circle"
        }
    }

    public var title: String {
        switch self {
        case .menuBar:
            return String(localized: "Sentry lives in the menu bar")
        case .composeBar:
            return String(localized: "The bar is yours to compose")
        case .keepAwake:
            return String(localized: "Hold the Mac awake for a long job")
        case .alerts:
            return String(localized: "Be told when something is wrong")
        case .insights:
            return String(localized: "Insights scores how this Mac is looked after")
        case .agents:
            return String(localized: "Coding agents can ask this Mac how it's doing")
        case .companion:
            return String(localized: "Your phone and watch can see all of this")
        case .locationLog:
            return String(localized: "Optional: remember where this Mac was")
        case .done:
            return String(localized: "That's the tour")
        }
    }

    public var summary: String {
        switch self {
        case .menuBar:
            return String(localized: "There is no Dock icon and no main window waiting for you. The icon at the top of the screen is the app.")
        case .composeBar:
            return String(localized: "Which readings appear up there, in what order, and how each one is drawn is entirely up to you.")
        case .keepAwake:
            return String(localized: "A real power assertion with an end time — not a mouse jiggler, and not something you can leave on by accident.")
        case .alerts:
            return String(localized: "Threshold alerts arrive as ordinary macOS notifications. Sentry asks for permission now because this is the moment it would need it.")
        case .insights:
            return String(localized: "One number out of 100, split into a security half and a hardware half, with every point it deducts itemised.")
        case .agents:
            return String(localized: "Sentry speaks MCP, so a coding agent can check this machine is fit before starting a long build — and hold it awake while it runs.")
        case .companion:
            return String(localized: "On your own Wi-Fi the iPhone app finds this Mac by itself. Pairing is one QR code, and connecting from other networks is part of Sentry Pro.")
        case .locationLog:
            return String(localized: "A coarse location, recorded every half hour, readable from your iPhone over your own network. Off unless you turn it on.")
        case .done:
            return String(localized: "Nothing you have just seen is required — Sentry works with all of it switched off.")
        }
    }

    public var detail: String {
        switch self {
        case .menuBar:
            return String(localized: "Click the icon to open the dropdown. That is Sentry's main surface: live CPU, memory, GPU and battery, the heaviest processes, and the sleep controls. A right-click opens the same dropdown — there is no separate context menu. Settings, the Dashboard and Quit are the three buttons along the bottom of it.")
        case .composeBar:
            return String(localized: "Settings ▸ Menu Bar is a composer, not a checklist: add one module per metric, drag to reorder, and choose how each is drawn — icon, value, sparkline, bar or arc. You can cap the item's width so it never crowds the clock, and hide a module until its value actually matters.")
        case .keepAwake:
            return String(localized: "The Keep Awake card in the dropdown takes a duration — indefinitely, a preset, until a set time, until the battery runs low, or while a build or download is still running — and a mode: keep the display on, keep the system up but let the screen sleep, or prevent sleep only while plugged in. Closing the lid still sleeps the Mac; no assertion overrides that.")
        case .alerts:
            return String(localized: "Say no and the rest of Sentry is unaffected: rules still evaluate and everything that fires is still recorded in Settings ▸ Alerts. You just won't be interrupted. macOS only asks once, so if you decline here you'll need System Settings ▸ Notifications to change your mind.")
        case .insights:
            return String(localized: "The security half is read live from this Mac — FileVault, SIP, Gatekeeper, the firewall, screen lock, sharing services, update settings. The hardware half is earned from your own recorded history, so it stays quiet for the first few days rather than guessing. Everything is computed on this Mac; nothing is uploaded. Free copies show the score and the first two findings in full, and the rest by category and severity.")
        case .agents:
            return String(localized: "Read tools are on by default; the ones that change something are off until you enable them individually. Guardrails ship on: an agent's request to keep this Mac awake is refused below 20% battery, and an agent-held assertion is released automatically when the machine gets hot. And there is a kill switch — one toggle that declines every agent call, read and write, from every client, and it survives a relaunch.")
        case .companion:
            return String(localized: "Same network needs nothing turned on to watch this Mac. Pairing mints a code and draws a QR holding this Mac's address, port and code — point the iPhone's Camera app at it and the app fills the connection in, then asks you to confirm. Pairing is free, and is what lets the phone control this Mac on this Wi-Fi; reaching this Mac from other networks is part of Sentry Pro. The Apple Watch app rides along with the phone and pairs the ordinary way; there is nothing Sentry-specific to set up on the watch.")
        case .locationLog:
            return String(localized: "This is a location log, not Find My, and Sentry will not pretend otherwise: it records the last place this Mac reported, at reduced accuracy, keeps it on this Mac, and sends it only to a phone you have paired. macOS asks for permission the moment you switch it on. Skipping is a perfectly ordinary answer.")
        case .done:
            return String(localized: "Everything here lives in Settings, and so does this walkthrough — General ▸ Walkthrough runs it again whenever you want.")
        }
    }
}

// MARK: - iPhone

/// The iPhone walkthrough, in order.
///
/// **This replaces a three-screen flow, and the first screen is why.** The
/// old `OnboardingView` opened with what the app shows you; the actual
/// first-run confusion it was written to fix is that the app shows you
/// *demo data* until a Mac is connected. So this opens by naming the
/// relationship — this is a readout of a Mac — and only then explains how
/// the Mac gets found, which is the single step most likely to be the
/// difference between a working install and an uninstall.
///
/// **This flow asks for no system permission at all, and that is a finding,
/// not an omission.** The phone app has nothing to ask for: it delivers no
/// notifications of its own (`SettingsTabView`'s notifications section says
/// so in as many words — "Notifications need a live connection to your Mac,
/// so there's nothing here to turn on or off yet"); pairing uses the system
/// Camera app via a `sentry://pair` deep link specifically so that no camera
/// permission is needed (`RemotePairing`'s doc comment argues that choice);
/// and the location log is collected by the *Mac*, so the phone reads it
/// without any location authorisation of its own. A walkthrough that
/// prompted for something here would be prompting for nothing.
public enum PhoneWalkthroughStep: String, WalkthroughStep {

    case companionRole
    case pairing
    case tabs
    case controls
    case agents
    case watch
    case done

    public var role: WalkthroughStepRole {
        switch self {
        case .companionRole, .tabs, .controls, .agents, .watch: return .teach
        case .pairing: return .setup
        case .done: return .finish
        }
    }

    public var symbolName: String {
        switch self {
        case .companionRole: return "gauge.with.dots.needle.67percent"
        case .pairing: return "qrcode.viewfinder"
        case .tabs: return "square.grid.2x2"
        case .controls: return "cup.and.saucer"
        case .agents: return "bolt.shield"
        case .watch: return "applewatch"
        case .done: return "checkmark.circle"
        }
    }

    public var title: String {
        switch self {
        case .companionRole:
            return String(localized: "This app reads a Mac")
        case .pairing:
            return String(localized: "Connect your Mac")
        case .tabs:
            return String(localized: "Four tabs")
        case .controls:
            return String(localized: "You can hold the Mac awake from here")
        case .agents:
            return String(localized: "Agents talk to your Mac, not to this app")
        case .watch:
            return String(localized: "And on your wrist")
        case .done:
            return String(localized: "That's it")
        }
    }

    public var summary: String {
        switch self {
        case .companionRole:
            return String(localized: "It is a companion to Sentry running on your Mac, not a second copy of it. Everything it shows comes from there.")
        case .pairing:
            return String(localized: "On your own Wi-Fi this app looks for your Mac by itself. Pairing once with a QR code adds control — and, with Sentry Pro on the Mac, reach from other networks.")
        case .tabs:
            return String(localized: "Dashboard for right now, History for over time, Alerts for what has fired, Settings for the connection and the theme.")
        case .controls:
            return String(localized: "The Dashboard's sleep card can extend, shorten or end the Mac's keep-awake, and Shortcuts can do the same by voice.")
        case .agents:
            return String(localized: "Sentry on the Mac can expose an MCP server so coding agents check the machine is fit before a heavy build — with guardrails and a kill switch.")
        case .watch:
            return String(localized: "The Watch app mirrors the vitals and the keep-awake controls, relayed through this phone.")
        case .done:
            return String(localized: "Settings ▸ Walkthrough runs this again any time.")
        }
    }

    public var detail: String {
        switch self {
        case .companionRole:
            return String(localized: "Until a Mac is connected the Dashboard shows demo readings and labels them as such — that is not your Mac idling, it is placeholder data. Nothing in this app measures this iPhone.")
        case .pairing:
            return String(localized: "Same network: there is nothing to switch on to see the Mac. Sentry on the Mac already answers, and this app finds it. To pair, open Sentry ▸ Settings ▸ Sync on the Mac: Remote Access mints a pairing code and shows a QR code. Point this iPhone's Camera app at it and tap the banner — the app reads the address, port and code out of it and asks you to confirm before saving. Typing those three fields into Settings by hand does the same job. Pairing on the Mac's own Wi-Fi is free; connecting from other networks is part of Sentry Pro on the Mac.")
        case .tabs:
            return String(localized: "History and Alerts are as deep as the Mac's own records: this app displays what the Mac has collected rather than keeping its own log, so a Mac you have only just paired with will have more to show tomorrow.")
        case .controls:
            return String(localized: "Every tap is a request sent to the Mac and answered by it — the card reports what actually happened rather than assuming it worked, and says plainly when there is no connection to send on. \"Keep my Mac awake for 60 minutes\" works as a Shortcut and through Siri.")
        case .agents:
            return String(localized: "All of those switches live on the Mac, in Settings ▸ AI Access: which tools agents may call, whether they may change anything, a battery floor, and a kill switch that declines every call until you resume it. This app is a readout of the machine agents are working on, not a console for them.")
        case .watch:
            return String(localized: "If your Watch is already paired to this iPhone there is nothing else to set up. The watch shows what this phone last received, so it is only ever as fresh as this app's own connection to the Mac.")
        case .done:
            return String(localized: "You can skip or re-run this at any point; it changes nothing about how the app works.")
        }
    }
}
