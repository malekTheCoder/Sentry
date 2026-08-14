# App Store review readiness — iPhone, Watch, and widgets

**Scope.** The iOS app (`SentryMobile/`), its home-screen widget
(`SentryWidget/`), the watchOS app (`SentryWatch/`) and its complication
(`SentryWatchWidget/`) — the four bundles that go up to App Store Connect in a
single upload. The Mac app ships outside the App Store (Developer ID +
notarization) and is **not** in scope except where its behaviour is what the
iPhone displays.

**Audited against** the App Store Review Guidelines and Apple's technical
requirements as published in **August 2026**, fetched live rather than
recalled — several of these changed in 2026 and a stale answer here is worse
than none. Every finding names the file and line where it was verified.

**Audited at** commit `000cb66`, branch `feat/appstore-compliance`, with
Xcode 26.6 (iOS SDK 26.5, watchOS SDK 26.5).

---

## Verdict

**No — not as it stands. One blocker is certain, and it is not a judgement
call.**

> ### The single most likely rejection
>
> **The privacy policy URL does not exist.** The app ships a tappable
> "Privacy Policy" link pointing at
> `https://malekthecoder.github.io/Sentry/privacy-policy`
> (`SentryKit/Models/AppCredits.swift:66`). Verified live during this audit:
> it returns **HTTP 404** (it redirects to `malekswilam.dev`, which serves a
> 404 for that path — and for `/Sentry/appcast.xml` too, so the Sparkle feed
> the Mac app depends on is also not up).
>
> Worse than a dead link: the screen immediately underneath it *tells the
> reviewer* it is dead — `SentryMobile/Settings/AboutView.swift:126` reads
> "The full written policy isn't published yet; the link above isn't live."
>
> This fails **Guideline 5.1.1** (a working privacy policy link is required
> both in App Store Connect *and* in the app) and **Guideline 2.1(a)**
> ("fully functional URLs included; placeholder text, empty websites, and
> other temporary content should be scrubbed before submission"). App Review
> clicks the link. There is no version of this that gets through.

The good news, and it is genuinely unusual: **the parts that silently kill
uploads are already correct.** All four privacy manifests exist, are in the
right bundles, and every Required Reason declaration was independently
re-derived from the code in this audit and found accurate — including the
non-obvious calls about what the watch targets do *not* compile. Local
network permission and Bonjour service types match the transport. No
background modes are declared and none are used. Nothing is gated behind a
purchase on iOS. There is no sign-in. That is the boring, high-effort half of
compliance, and it was done properly.

What remains is: one dead URL, a handful of small metadata gaps (now fixed —
see "Fixed in this change"), and a real, unresolved product judgement about
what a reviewer with no Mac experiences.

### Second-most-likely rejection

**Guideline 2.1 / 4.2 — the reviewer will not have a Mac.** They will open
the app, see a randomly-fluctuating dashboard for a machine called *"Malek's
MacBook Pro"*, and have no way to reach a single real feature. Whether that
reads as an honest preview or a broken app is a coin-flip decided by review
notes you have not written yet. Section 6 covers this in detail; it is the
one area where the fix is *not* code.

---

## Findings by area

### 1. Privacy manifests (`PrivacyInfo.xcprivacy`) — **OK**

**Guideline / requirement:** [Privacy manifest
files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files);
required for upload since **1 May 2024** per [Apple's upcoming-requirements
page](https://developer.apple.com/news/upcoming-requirements/).

`project.yml`'s claim that all four iOS/watchOS bundles carry one is **true**,
and each lands at its bundle root via XcodeGen's extension auto-detection
from the target's `sources: path` (no `resources:` entry needed — documented
at `project.yml:648`, `:751`, `:838`, `:915`):

| Bundle | Manifest | Verified |
|---|---|---|
| `SentryMobile` | `SentryMobile/PrivacyInfo.xcprivacy` | ✅ |
| `SentryWidgetExtension` | `SentryWidget/PrivacyInfo.xcprivacy` | ✅ |
| `SentryWatch` | `SentryWatch/PrivacyInfo.xcprivacy` | ✅ |
| `SentryWatchWidgetExtension` | `SentryWatchWidget/PrivacyInfo.xcprivacy` | ✅ |

The macOS widget target correctly *excludes* the manifest
(`project.yml:806`) — it ships Developer ID, never passes the App Store
Connect check, and its `UserDefaults` suite is a plain named suite rather
than an App Group, so copying the iOS manifest would have been a false
declaration.

**Third-party SDKs.** Only one third-party binary reaches App Store Connect:
**GRDB 6.29.3**, linked by `SentryKit_iOS` (`project.yml:202`) and embedded
in both the app and the iOS widget. It ships its own
`GRDB/PrivacyInfo.xcprivacy` (bundled via its `Package.swift`
`resources: [.copy(...)]`) declaring no tracking, no collection and no
required-reason APIs — independently confirmed by grepping GRDB's sources for
every required-reason symbol (only doc comments and SQL column names match).
Sparkle, the MCP SDK and SwiftNIO are **macOS-only** (`project.yml:441`,
`:445`, `:449–464`) and reach no submitted bundle. `SentryKit_watchOS`
declares no package dependencies at all, so **zero third-party code ships on
the watch**.

**Minor, non-blocking:** the `SentryKit_iOS` framework has no manifest of its
own. The app- and appex-level manifests cover it for submission (Apple scans
the bundle, and first-party embedded frameworks are the app's responsibility,
not an SDK's), so this is not a defect — but a per-framework manifest is the
sturdier posture, since that framework binary is where the declared symbols
actually live.

### 2. Required Reason APIs — **OK** (every declaration re-derived and correct)

**Requirement:** [Describing use of required reason
API](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files).
This is the most common *silent* rejection (ITMS-91053 / ITMS-91055), so
every category was swept independently rather than trusted.

Compile-set facts this depends on: `SentryKit_iOS` takes `- path: SentryKit`
with **no `excludes:`** (`project.yml:196–207`), so every file under
`SentryKit/` compiles into the iOS framework unless a `#if` removes it.
`SentryKit_watchOS` instead enumerates seven path entries resolving to eleven
files (`project.yml:224–255`).

| Category | Found in a submitted bundle? | Evidence |
|---|---|---|
| **UserDefaults** | **Yes — all four bundles** | See below |
| **System boot time** | **Yes — iOS app + iOS widget only** | `SentryKit/Insights/DeviceFacts.swift:91` — `ProcessInfo.processInfo.systemUptime`, **unguarded** (the file's only `#if` is `canImport(Darwin)`, true on iOS). Not in the watchOS file list. |
| **Disk space** | No | Zero hits in `SentryKit/`, `SentryMobile/`, `SentryWidget/`, `SentryWatch/`, `SentryWatchWidget/`. The only capacity API is `SystemMetricsKit/Collectors/DiskCollector.swift:50,56`, and `SystemMetricsKit` is `platform: macOS` (`project.yml:121–146`), linked by no iOS/watchOS target. The disk numbers on screen arrive over the wire as plain `UInt64`s. |
| **File timestamp** | No | Only hits are `SentryKit/Services/PowerControlService.swift:666,670` (`.contentModificationDateKey`), and that file is wrapped in `#if os(macOS)` from line 4 to `#endif` at line 1062. |
| **Active keyboards** | No | No `activeInputModes` / `UITextInputMode` anywhere. |

**UserDefaults reason codes — checked one by one:**

- `SentryMobile` declares **`CA92.1` + `1C8F.1`** (`SentryMobile/PrivacyInfo.xcprivacy:134–135`). Correct on both counts. `CA92.1` (app's own defaults): `@AppStorage` in `SentryMobile/SentryMobileApp.swift:41,53`, `RootTabView.swift:44,64`, `SettingsTabView.swift:56,86,95,97–99`, plus `UserDefaults.standard` in `AppDataSource.swift:156–160,253–256,364–367` and `Watch/WatchRelayManager.swift:108,110,163,168`. `1C8F.1` (App Group): `WidgetSnapshotStore` (`SentryKit/Sync/WidgetSnapshot.swift:247`, the `#else`/non-macOS branch) and `WatchRelayStore` (`SentryKit/Watch/WatchRelayStore.swift:39`), both opening `group.dev.malekswilam.sentry` — matching `SentryMobile/SentryMobile.entitlements`.
- `SentryWidget` declares **`1C8F.1` + `CA92.1`** (`SentryWidget/PrivacyInfo.xcprivacy:85–86`). The `CA92.1` is the subtle one and it is **right**: this extension never constructs them, but `RollupJob` (`SentryKit/Persistence/RollupJob.swift:102`) and `PendingAlertPushStore` (`SentryKit/Sync/PendingAlertPushStore.swift:26`) default to `.standard` and are unguarded, so those symbols ship inside the embedded `SentryKit.framework`. Apple's check is a static scan of the binary, not of the call graph. Declaring what is present is the accurate answer.
- `SentryWatch` and `SentryWatchWidget` declare **`1C8F.1` only** (`:76` / `:63`). Also right: the `.standard` call sites live in files the watchOS framework does not compile.

**System boot time** is declared as **`35F9.1`** in exactly the two bundles
that contain it (`SentryMobile/PrivacyInfo.xcprivacy:169`,
`SentryWidget/PrivacyInfo.xcprivacy:106`) and correctly absent from both
watch manifests. `35F9.1` requires the value not leave the device;
`SentryKit/Models/SystemSnapshot+MetricValue.swift:97` explicitly returns
`nil` for `.systemUptimeSeconds` rather than putting it on the wire.

> **Standing hazard, worth naming.** `SentryKit_iOS` compiling the whole
> directory with no `excludes:` means any future unguarded required-reason
> call added anywhere under `SentryKit/` lands in two submitted bundles with
> no target-membership change to signal it. The watch side has structural
> protection (an explicit file list); the phone side has only `#if os(macOS)`
> discipline. Twenty-three files currently rely on that guard.

### 3. Local network (Bonjour + direct sockets) — **OK**

**Requirement:**
[`NSLocalNetworkUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription).
Since iOS 14, Bonjour/mDNS discovery and direct local connections require
both the purpose string and an `NSBonjourServices` allowlist; a service type
missing from that list means the browse silently returns nothing.

Both present in `project.yml`'s `SentryMobile` `info:` block (generated into
`SentryMobile/Info.plist:33–38,42–43`), and the service type **matches the
code exactly**:

- `SentryKit/LocalSync/LocalSyncServer.swift:84` — `public static let serviceType = "_sentry._tcp"`
- `SentryKit/LocalSync/LocalSyncClient.swift:78` — `public static let serviceType = "_sentry._tcp"`
- `SentryMobile/Info.plist:36–38` — `NSBonjourServices = ["_sentry._tcp"]`

One entry, one type, browsed and published identically. Correctly absent from
the widget and both watch bundles, none of which open a socket
(`SentryMobile/Watch/WatchRelayManager.swift` documents that the watch has no
Network.framework path at all — everything arrives over `WCSession`).

### 4. Purpose strings — **OK**, with one thing to *not* do

**Guideline:** 5.1.1; vague or boilerplate purpose strings are a documented
rejection reason.

**Local network** (`SentryMobile/Info.plist:43`) is specific, names the real
capability including the *control* direction, and states the privacy fact:

> "Sentry uses your local network to find your Mac and show its live stats
> when you're on the same Wi-Fi, and to send it the keep-awake and sleep
> commands you tap or ask Siri for. None of this data is sent to any server."

That is a good string. It survived a prior revision that added the control
half (`project.yml`'s comment records why), and it should not be shortened.

**Location — no purpose string is needed, and adding one would be wrong.**
> **SUPERSEDED (Aug 13, 2026):** the entire Location Log feature was
> deleted — `LocationService`, `LocationLogSection`, and every file named
> below no longer exist, and the App Privacy answer is now **Data Not
> Collected** across the board. `docs/asc-metadata-draft.md` is the
> current source of truth; the paragraph below is kept for the historical
> record only.

This is worth stating explicitly because the App Privacy label *does* declare
location (§8), which looks like a contradiction and is not. The iPhone never
opens a `CLLocationManager`: `SentryKit/Services/LocationService.swift` is
wrapped in `#if os(macOS)` (line 4 → `#endif` line 244), so the
permission-gated symbols are not in the iOS binary.
`SentryMobile/Settings/LocationLogSection.swift:1` imports CoreLocation only
for `CLLocationCoordinate2D`, a plain struct MapKit needs — not a gated API.
The *Mac* asks for location; the phone only receives and draws a coordinate.
Adding `NSLocationWhenInUseUsageDescription` would advertise a prompt this
app can never show.

**Notifications — no purpose string exists on iOS.** There is no
`NS*UsageDescription` key for `UNUserNotificationCenter.requestAuthorization`;
the system prompt is fixed. Nothing to add. (`AlertEngine` ships in the iOS
framework but its authorization request is driven from the Mac side.)

**Camera — correctly avoided.** QR pairing deliberately uses the *system*
Camera app via the `sentry://` URL scheme (`SentryMobile/Info.plist:22–32`,
handled at `SentryMobileApp.swift:123`) rather than an in-app scanner, so
there is no camera permission to justify. Good design, and one less prompt to
defend.

### 5. Encryption / export compliance — **was a BLOCKER-adjacent hold, now FIXED**

**Requirement:** [Complying with encryption export
regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).

`ITSAppUsesNonExemptEncryption` was **absent** from every iOS/watchOS
Info.plist. That is not a *rejection* — it is a hold: every uploaded build
sits in App Store Connect marked "Missing Compliance," invisible to external
TestFlight testers and un-submittable, until someone answers the
questionnaire by hand, **for every build**.

**Correct value: `false`.** The app uses encryption, but only the operating
system's:

- `SentryKit/LocalSync/SyncSecurity.swift:100` — `sec_protocol_options_add_pre_shared_key` on an `NWProtocolTLS.Options`; Apple's TLS stack, the same one under URLSession's HTTPS.
- `:108–109` — the standard published IANA ciphersuite `TLS_PSK_WITH_AES_128_GCM_SHA256`.
- `:111–112` — TLS 1.2, pinned min and max.
- `:95` — CryptoKit `SHA256.hash(data:)` derives key material from the pairing code. SHA-256 is a published standard hash, and CryptoKit is again the OS.
- The Bonjour/LAN path is deliberately plaintext (`LocalSyncServer`'s doc comment), contributing nothing.

No bundled crypto library, no proprietary or unpublished algorithm, and
nothing in GRDB that changes it. That is squarely Apple's stated exemption
for encryption built into the operating system.

**Fixed:** `ITSAppUsesNonExemptEncryption: false` added to `SentryMobile`'s
`info: properties:` in `project.yml`, with the evidence above recorded inline
so it can be re-checked rather than trusted. Declared in the plist rather
than answered by hand precisely so it cannot be forgotten on a later build.

> ⚠️ **This is a legal declaration by the app's owner, not a build setting.**
> The audit supports `false`, but read the reasoning above and satisfy
> yourself before the first upload. If anything later adds crypto of our own
> — a bundled library, a custom cipher, anything not reached through an Apple
> framework — this must be revisited, and annual self-classification
> obligations may attach.

### 6. Guideline 4.2 (minimum functionality) & 2.1 (completeness) — **RISK, and the real judgement call**

**Guidelines:** [2.1 App
Completeness](https://developer.apple.com/app-store/review/guidelines/#app-completeness)
and [4.2 Minimum
Functionality](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality).

#### What a reviewer with no Mac actually sees

Traced end to end. Mock data is not a fallback that engages after a failure —
it is the **default from the first frame**: `AppDataSource.transport` is
initialised to `MockDataSource()` (`SentryMobile/Data/AppDataSource.swift:88`)
before any discovery runs. The 5-second Bonjour timeout
(`AppDataSource.swift:80`, 8s if a remote endpoint is saved) only decides
whether it gets *replaced*. There is no spinner and no loading gate.

The data is **animated and randomised**, not static:
`MockDataSource.syntheticSnapshot(deviceID:)` (`:222`) re-rolls CPU 8–34%,
battery 60–78%, charge 25–45 W, GPU 2–18%, SoC 42–58 °C every 15 seconds
(`:64`). The device is named **`"Malek's MacBook Pro"`** (`:71`), a
`"MacBook Pro (14-inch, 2024)"` on `"Apple M3 Pro"` running
`"macOS 15.1"`, on `"Demo Network"` Wi-Fi.

- **Dashboard** — fully populated. 28pt headline reads *"Malek's MacBook Pro"*. Under it, one caption line: amber dot + **"Demo data — not from a real Mac"** + a tappable "Retry" (`SentryMobile/Dashboard/DashboardTabView.swift:153`). Battery hero card, vitals ledger, live sleep card that cycles state every 45s.
- **History** — the app's best disclosure: a **full-width `glassCard` banner**, "Showing demo data — not currently connected to a Mac on your local network" (`SentryMobile/History/HistoryTabView.swift:142`).
- **Alerts** — **no demo indicator at all.** Eleven hardcoded default rules with every `Toggle` `.disabled(true)` (`SentryMobile/Alerts/AlertsTabView.swift:49,173`), a note that switches "don't change anything yet" (`:92`), and a dashed box admitting "Alert history isn't synced to this iPhone yet" (`:192`).
- **Settings** — theme picker and units picker genuinely work. Everything else is honestly-labelled inert.

#### Assessment

**The disclosure is honest and, on two tabs, prominent.** Onboarding leads
with it — step 1 of 7 is titled *"This app reads a Mac"* and its detail says
demo readings "are not your Mac idling, it is placeholder data"
(`SentryKit/Onboarding/WalkthroughSteps.swift:271`). Seven distinct
disclosure sites exist. This is not a developer trying to pass fake data off
as real, and a reviewer who reads is unlikely to conclude fraud.

**But the demo mode is not the risk — the reviewer's inability to reach any
real feature is.** Guideline 2.1 lets you ship a built-in demo mode *in lieu
of a demo account*, and requires that it "exhibit your app's full features
and functionality" — it does not, on its own, satisfy a reviewer who cannot
evaluate the product. That gap closes with **review notes and a demo video**,
not with code. See the checklist.

**Recommendations — product judgement, deliberately not implemented here:**

1. **Change the demo device name.** "Malek's MacBook Pro" is a real person's machine name as the app's largest on-screen text. Something self-evidently synthetic — *"Demo MacBook Pro"* — removes any ambiguity about whether the reviewer is looking at live data, at zero cost. This is the highest value-per-effort change in this section.
2. **Put a demo indicator on the Alerts tab.** It is the one tab where a reviewer sees a screen full of controls, none of which do anything, with nothing saying why the data is fake. It is also the tab most exposed to a 4.2 objection on its own merits.
3. **Reconsider the word "build" in user-facing copy.** It appears three times ("this build", "This build" — e.g. `SettingsTabView.swift:640`, `HistoryTabView.swift:198`). Nine user-visible strings admit a feature is missing. Individually each is admirable honesty; read consecutively by a reviewer they compose into "this is pre-release software," which is exactly the impression 2.1 exists to catch.
4. **Fix one string that is not honest.** With no Mac, tapping keep-awake shows *"Sent, but no reply from your Mac yet."* (`SentryMobile/Dashboard/SleepStatusCard.swift:261–283`) — but `MockDataSource.send(command:)` (`:172–176`) is a silent no-op. Nothing was sent. Everything else in this app is scrupulous about this distinction; this one line implies a transmission that did not occur, and under 2.3.1 it is the wrong kind of inaccuracy to ship.
5. **Add a way to get the Mac app.** There is no download link, URL, or instruction anywhere in the iOS target. A reviewer who reads the onboarding learns they need a Mac app and is given no way to obtain it. A single link in About would help both the reviewer and every real user.

#### Guideline 4.2.3(i) — worth knowing about, probably not fatal

4.2.3(i) says "your app should work on its own without requiring installation
of another app to function." In practice Apple applies this to iOS apps
requiring a second *iOS* app; desktop-companion apps (display extenders, NAS
clients, system monitors) are an established category. Do not volunteer this
guideline in your review notes — but if it is cited, the answer is that the
required counterpart is a macOS application on a different platform, and the
app functions as a viewer with a documented demo mode.

### 7. Background modes / background execution — **OK**

Grepped `project.yml`, `SentryMobile/`, `SentryWatch/` and `SentryKit/` for
`UIBackgroundModes`, `BGTaskScheduler`, `BGAppRefreshTask` and
`beginBackgroundTask`: **zero hits**. No background mode is declared and none
is used, so there is nothing to justify. This is the correct answer — an
unjustified `UIBackgroundModes` entry is a routine rejection, and a live
socket held open in the background would have been very hard to defend for a
telemetry viewer.

The widget refreshes through WidgetKit timelines
(`SentryWidget/Provider.swift`) and the watch through `WCSession`, both of
which are system-scheduled and need no declaration.

### 8. App Privacy "nutrition label" — answers to enter in App Store Connect

> **Editor's note (13 Aug 2026):** the Location Log feature this section's
> location answer describes was removed from the product on this date; the
> current answers live in `docs/asc-metadata-draft.md`, which supersedes
> this section. The text below is kept as the audit's historical record.

**Requirement:** [App privacy details on the App
Store](https://developer.apple.com/app-store/app-privacy-details/). Apple's
definition of *collect* is "transmitting data off the device in a way that
allows you and/or your third-party partners to access it." Data that never
leaves the device is **not** collected — but note that the location
coordinate *does* leave the Mac (to the user's own phone, over the user's own
Wi-Fi, where no developer can ever reach it).

**Recommended answers — fill in exactly this:**

| App Store Connect question | Answer | Why |
|---|---|---|
| Do you or your third-party partners collect data from this app? | **Yes** | Only because of Precise Location, below. Answering "No" would be defensible on a strict reading; under-declaring is the failure mode with consequences. |
| **Contact Info** (name, email, phone, address, other) | **Not collected** | No account, no sign-in, no contact field anywhere in the app. |
| **Health & Fitness** | **Not collected** | — |
| **Financial Info** | **Not collected** | No IAP, no payment (§10). |
| **Location → Precise Location** | **Collected** · Linked to user: **No** · Used for tracking: **No** · Purpose: **App Functionality** | The Location Log. The *Mac* (`SentryKit/Services/LocationService.swift`, macOS-only) reads an approximate fix every 30 min when the user opts in, and puts it in the `SystemSnapshot` streamed over the LAN; the phone draws it on a map (`SentryMobile/Settings/LocationLogSection.swift`). Off by default. |
| **Location → Coarse Location** | **Not collected** | Declare Precise, not Coarse — see the note below. |
| **Sensitive Info** | **Not collected** | — |
| **Contacts** | **Not collected** | — |
| **User Content** | **Not collected** | — |
| **Browsing History** | **Not collected** | — |
| **Search History** | **Not collected** | — |
| **Identifiers** (User ID, Device ID) | **Not collected** | No account, no user ID, no IDFA/IDFV read anywhere. |
| **Purchases** | **Not collected** | — |
| **Usage Data** | **Not collected** | No analytics, no telemetry, no crash reporter, no third-party SDK that could collect on your behalf. GRDB is the only third-party code and it declares no collection. |
| **Diagnostics** | **Not collected** | Nothing is uploaded anywhere. There is no developer-controlled server. |
| **Other Data** | **Not collected** | Mac metrics (CPU, battery, disk, thermals, device name, SSID) travel only between the user's own devices and match none of Apple's categories. |
| Data Types Used to Track You | **None** | No ATT, no advertising, no data broker, no cross-app or cross-site linkage. Do not add `NSUserTrackingUsageDescription`. |

**Why Precise and not Coarse.** `LocationService` sets
`desiredAccuracy = kCLLocationAccuracyReduced`, but that is a *request*, not a
guarantee, and `MacLocation` (`SentryKit/Models/MacLocation.swift:35`) carries
the raw latitude/longitude doubles CoreLocation returned with no rounding
anywhere in the pipeline. Declaring the stronger category is the honest worst
case, and matches
`SentryMobile/PrivacyInfo.xcprivacy`'s `NSPrivacyCollectedDataTypePreciseLocation`.

**Keep the manifest and the label consistent.** App Store Connect cross-checks
them. The manifest declares exactly one collected type — Precise Location,
not linked, not tracking, App Functionality — so the table above must match
it. Change one and you must change the other.

**Expect a question about this.** Declaring location while the app shows no
location prompt is unusual and a reviewer may ask. Pre-empt it in the review
notes: *"Location is read by the user's Mac, not by this app. This app has no
CLLocationManager and requests no location permission; it receives a
coordinate over the local network and displays it. The feature is off by
default."*

### 9. Watch app and widgets — **OK**, one presentation RISK

**Watch app configuration is correct.**

- `WKApplication: true` (`SentryWatch/Info.plist`) — the modern watchOS 9+ single-target shape, matching the `watchOS: "10.0"` deployment target (`project.yml:10`).
- `WKCompanionAppBundleIdentifier: dev.malekswilam.sentry.mobile` (`project.yml`, `SentryWatch/Info.plist`) — correctly marks it a **dependent** watch app embedded in the iPhone app's upload, not standalone. `WKRunsIndependentlyOfCompanionApp` is correctly **absent**: the watch has no network path of its own and everything it shows arrives from the phone over `WCSession` (`SentryWatch/WatchSessionController.swift:37,204`), so claiming independence would be false and would fail on a reviewer's unpaired watch.
- Bundle-ID chain is correct and load-bearing: `…sentry.mobile` → `…sentry.mobile.watch` → `…sentry.mobile.watch.widget`. `project.yml`'s comment records that getting this wrong previously blocked *every* install of the phone app.
- App icons: both `SentryMobile` and `SentryWatch` carry a 1024×1024 PNG with **`hasAlpha: no`** (verified with `sips`). An alpha channel is an automatic upload rejection (ITMS-90717); this is clean.

**RISK — the widget's demo labelling is incomplete.** The demo caption
`"Demo data — no live Mac sync yet"` (`SentryWidget/Views/BatteryArcView.swift:105`)
is rendered **only in the `.systemLarge` family**
(`SentryWidget/Views/LargeWidgetView.swift:32–34`). Small and medium widgets
show fabricated battery and CPU numbers for "Malek's MacBook Pro" on the
user's home screen with **no indication they are not real**. On a reviewer's
device that is a widget confidently displaying invented data. The watch
complication does better — it appends `" · Demo"` to its freshness string
(`SentryWatchWidget/ComplicationView.swift:204`).

Recommend extending the label (even a single `theatermasks` glyph, as the
watch's Overview page uses at `SentryWatch/Pages/OverviewPage.swift:268`) to
the small and medium families. Not implemented here — it is a layout decision
in constrained space.

### 10. Everything else

#### Privacy policy URL — **BLOCKER** (the headline finding)

Covered in the verdict. Mechanically: the URL is a single constant,
`AppCredits.privacyPolicyURLString` (`SentryKit/Models/AppCredits.swift:66`),
whose own doc comment at `:57` still carries the literal marker
**`⚠️ [PRIVACY POLICY URL — TO FILL IN] ⚠️`**. Publishing the policy is a
one-line change there and nowhere else — `docs/privacy-policy-publishing.md`
already documents how.

**Deliberately not changed in this commit.** The correct URL is a decision
about where the policy will be hosted, not something to guess. Note that
`malekthecoder.github.io/Sentry/*` now **redirects to `malekswilam.dev`**,
which serves 404 for every path tried — so the intended host has moved and
the constant is stale in more than just its path. Whoever publishes must pick
the final URL, put the policy there, update this constant, **and delete the
"the link above isn't live" sentence** at `AboutView.swift:126`.

Two placeholders also remain inside the policy text itself
(`docs/privacy-policy.md:3,171`): `[EFFECTIVE DATE — TO FILL IN]` and
`[CONTACT EMAIL — TO FILL IN]`. Both must be real before publishing —
reviewers do write to the contact address.

#### Version strings — **was a BLOCKER, now FIXED**

All four submitted bundles shipped `CFBundleShortVersionString` **1.0** and
`CFBundleVersion` **1** — XcodeGen's defaults — while the repository is
tagged 1.0.0 (build 2). `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` were set
only on the macOS `Sentry` target (`project.yml:478–479`), and none of the
iOS/watchOS `info:` blocks substituted them.

This matters twice over. App Store Connect **requires an embedded watch app
and every app extension to carry the same `CFBundleShortVersionString` and
`CFBundleVersion` as the containing iOS app**, and rejects the upload when
they disagree — here they agreed only by accident, all four being wrong in
the same direction. And build "1" would have shipped as the tagged "build 2".

The macOS target's `info:` block carries a long comment about this exact bug
class, ending "there is no second place to forget." There were four.

**Fixed:** `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` promoted to the
project-wide `settings.base`, and `CFBundleShortVersionString: "$(MARKETING_VERSION)"` /
`CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"` added to all four
iOS/watchOS `info:` blocks. The `Sentry` target keeps its own identical
values, so the notarized/Sparkle path is untouched. Verified in the built
product: all four bundles now report `1.0.0` / `2` where they previously
reported `1.0` / `1`.

**Found in passing: the release commit shipped a red test suite.** Commit
`c88f796` ("Version 1.0.0 (build 2) for the first public release") bumped
`MARKETING_VERSION` from 0.1.0 to 1.0.0 in `project.yml` and changed nothing
else — but `SentryTests/UpdateFeedConfigurationTests.swift:211` asserted the
exact string `"0.1.0"`. The suite has been failing on that commit ever since,
before this branch touched anything. Fixed here: the test now asserts the
properties that actually matter and stay true across releases (the
substitution resolved, it is not XcodeGen's `"1.0"` default, and it has a
three-component numeric shape) rather than one literal version that turns the
suite red on every legitimate bump. Full suite: **1643 tests, 0 failures.**

#### Minimum SDK — **OK**

Since **28 April 2026**, [Apple
requires](https://developer.apple.com/news/upcoming-requirements/) that "apps
uploaded to App Store Connect must be built with Xcode 26 or later using an
SDK for iOS 26 … or watchOS 26." That deadline has passed. This machine has
**Xcode 26.6 (17F113), iOS SDK 26.5, watchOS SDK 26.5** — compliant. Note this
is about the *build* SDK, not the deployment target; `iOS: "17.0"` /
`watchOS: "10.0"` (`project.yml:6–10`) remain fine and are unaffected.

#### Third-party licensing — **OK**

`AboutView` lists only what ships in *this* bundle —
`AppCredits.iOSThirdPartyComponents`, which on iPhone is **GRDB alone**
(MIT), with name, version, licence, copyright and a working link to
`https://github.com/groue/GRDB.swift`
(`SentryKit/Models/AppCredits.swift:189`). Sparkle, SwiftNIO and the MCP SDK
are correctly excluded because they are not in the iOS binary. That is the
right level of care; nothing to fix.

#### In-app purchase / paid features — **OK, no obligations**

`SentryKit/Pro/ProGate.swift` gates **Protection Insights** — the free tier
sees the whole score plus the two highest-priority findings in full; the rest
show category and severity only. Two facts make it irrelevant here:

1. **It never reaches iOS.** Grepping `SentryMobile/`, `SentryWatch/`, `SentryWidget/`, `SentryWatchWidget/` for `ProGate`/`ProtectionInsight` finds no gating code — the only hit is a doc comment in `SentryMobile/Intents/SentryIntents.swift:344`. Protection Insights is a Mac-app feature.
2. **There is no StoreKit anywhere in the project.** `SentryKit/Pro/ProEntitlement.swift:56–60` records that the StoreKit implementation was deliberately deleted because the Mac app ships outside the Mac App Store; unlocking is via licence key (`LicenseProEntitlementStore`).

So Guideline 3.1.1 does not attach: nothing in the submitted iOS app is
gated, no purchase is offered, and no external purchase mechanism is
advertised. **Keep it that way** — if a future iOS build ever surfaces a
locked feature or links to a licence purchase, 3.1.1 requires it go through
in-app purchase, and that is a substantial piece of work, not a toggle.

#### Sign-in — **OK**

No account, no login, no social sign-in. Guideline 5.1.1(v) ("if your app
doesn't include significant account-based features, let people use it without
a login") is satisfied by construction, and no demo account is needed.

#### Dormant / non-functional feature — **RISK**

`GetProtectionScoreIntent` (`SentryMobile/Intents/SentryIntents.swift:373+`)
is exposed to Siri and Shortcuts as **"Get Mac Protection Score"**, but its
own doc comment states that `SystemSnapshot.protectionScore` is never
assigned by the Mac composition root — so *every real Mac reports `nil`* and
the intent can only ever answer "Your Mac hasn't reported a protection score
yet." The same gap is documented for `agentAccessPaused`.

Under **Guideline 2.3.1** ("don't include any hidden, dormant, or
undocumented features"), a Shortcuts action that can never succeed is exactly
the thing that clause names. It degrades honestly rather than lying, which
helps — but a reviewer who opens Shortcuts and tries it sees an advertised
action that does nothing. Either land the one-line Mac-side hook before
submitting, or withhold this intent from the 1.0 build. Not changed here:
both options are product decisions, and the Mac composition root is out of
scope for this branch.

#### Placeholder content — **OK**

Swept `SentryMobile/`, `SentryWatch/`, `SentryWidget/`, `SentryWatchWidget/`
and every `.xcstrings` catalog for `TODO`, `FIXME`, `Lorem`, `TBD`, `XXX`,
`example.com`, "coming soon", "not implemented", "placeholder". **No
user-visible placeholder string exists.** Every match is a code comment, the
em-dash no-value token `"—"` (`SentryMobile/Dashboard/MetricFormatting.swift:21`),
or WidgetKit's required `placeholder(in:)` method name.

Two cosmetic leftovers, neither user-visible nor blocking:

- `SentryMobile/Resources/Localizable.xcstrings` contains an orphaned key, `"Showing demo data — this build has no live iCloud sync yet"`, referenced by no Swift file (superseded by `HistoryTabView.swift:142`). Dead catalog entry.
- `StubTabContent` (`SentryMobile/RootTabView.swift:182–203`), documented as "this tab isn't built yet" scaffolding, has zero call sites.

All 123 keys in the iOS catalog are English source-only with no translations,
which is fine — ship a single-locale app and list only English in App Store
Connect.

---

## Pre-submission checklist — the things only a human can do

Code fixes are done. These are not.

### Blocking — the upload or the review will fail without them

- [ ] **Publish the privacy policy at a real, public HTTPS URL.** Fill the two placeholders in `docs/privacy-policy.md` (effective date, contact email), then follow `docs/privacy-policy-publishing.md`. Must be reachable with no login and no redirect-to-login. **Verify it in a private browser window before submitting.**
- [ ] **Update `AppCredits.privacyPolicyURLString`** (`SentryKit/Models/AppCredits.swift:66`) to that URL, and clear the `[PRIVACY POLICY URL — TO FILL IN]` marker at `:57`. Note the current value's host now redirects to `malekswilam.dev` and 404s.
- [ ] **Delete the "the link above isn't live" sentence** at `SentryMobile/Settings/AboutView.swift:126`. Shipping copy that tells the reviewer a required link is dead is a self-inflicted rejection.
- [ ] **Enter the same URL in App Store Connect** → App Privacy → Privacy Policy URL.
- [ ] **Write review notes explaining the Mac dependency.** This is the difference between a pass and a 2.1 rejection. Say plainly: the app is a companion to a macOS app distributed outside the App Store; a reviewer without a Mac will see clearly-labelled demo data; here is what it does with a real Mac. Be specific — Guideline 2.3.1 says generic descriptions will be rejected.
- [ ] **Attach a demo video** (screen recording of the app driving a real Mac) to the review notes, or host it and link it. For a hardware/desktop-companion app this is the single most effective thing you can provide.
- [ ] **Pre-empt the location question** in review notes, using the wording in §8.
- [ ] **Verify the build's Info.plist after archiving** — confirm `CFBundleShortVersionString` reads `1.0.0` and `CFBundleVersion` reads `2` in the app, the widget, the watch app and the complication. All four must match.

### Required App Store Connect fields

- [ ] **App Privacy questionnaire** — enter exactly the table in §8. Do not let App Store Connect's defaults stand.
- [ ] **Age rating** — Apple has required responses to the *updated* age-rating questions since **31 January 2026**; un-answered apps are blocked from submitting updates. Expect 4+.
- [ ] **Export compliance** — the plist now answers this (`ITSAppUsesNonExemptEncryption: false`), so App Store Connect should stop asking. If it does ask, the answer is: uses encryption → **yes**; exempt → **yes**, only encryption provided by the operating system. Read §5 first; this is your legal declaration.
- [ ] **EU Digital Services Act trader status.** Since **17 February 2025** apps without verified trader status are **removed from the EU App Store**. Verification takes time — start it now, not at submission.
- [ ] **Support URL** — required, must resolve. There is currently no support URL anywhere in the project. Decide what it is.
- [ ] **Marketing URL** — optional; leave blank rather than pointing at a 404.
- [ ] **Screenshots** — required for iPhone 6.9" *and* Apple Watch (a bundled watch app needs its own set). `docs/screenshots/` and the marketing repo have material to start from. They must show the real app; a screenshot of demo data is fine if it is not presented as a real Mac.
- [ ] **App description** — state the Mac requirement in the first paragraph, above the fold. This sets reviewer expectation before they open the app and protects against 2.1 and 4.2 simultaneously.
- [ ] **Category** — Utilities.
- [ ] **Confirm the bundle ID `dev.malekswilam.sentry.mobile`, the App Group `group.dev.malekswilam.sentry`, and provisioning profiles for all four bundles** exist under team `H7T2D2GL7U`.

### Recommended before 1.0 (each is a product decision — see §6 and §9)

- [ ] Rename the demo device from `"Malek's MacBook Pro"` to something obviously synthetic.
- [ ] Add a demo indicator to the Alerts tab.
- [ ] Add the demo label to the small and medium widget families.
- [ ] Fix `"Sent, but no reply from your Mac yet."` on the mock path — nothing was sent.
- [ ] Land the Mac-side `protectionScore` hook, or withhold `GetProtectionScoreIntent` from 1.0.
- [ ] Add a link to obtain the Mac app.
- [ ] Reduce the nine "not yet / this build" strings, or at least the three that say "build".

### Also worth doing (unrelated to iOS review, found in passing)

- [ ] `https://malekthecoder.github.io/Sentry/appcast.xml` returns **404**. That is the Sparkle feed URL compiled permanently into every shipped Mac binary. If the Mac app ships before that feed is live, those copies have no update path — and `project.yml`'s own warning says the address cannot be changed retroactively.

---

## Summary

| # | Area | Status |
|---|---|---|
| 1 | Privacy manifests | **OK** |
| 2 | Required Reason APIs | **OK** |
| 3 | Local network / Bonjour | **OK** |
| 4 | Purpose strings | **OK** |
| 5 | Encryption / export compliance | **FIXED** (was a per-build hold) |
| 6 | Guideline 4.2 / 2.1 — reviewer with no Mac | **RISK** — needs review notes + demo video |
| 7 | Background modes | **OK** |
| 8 | App Privacy label | **Answers supplied** — human must enter them |
| 9 | Watch app & widgets | **OK**; widget demo labelling is a **RISK** |
| 10 | Privacy policy URL | **BLOCKER** — 404, human-only fix |
| 10 | Version strings | **FIXED** (was upload-rejecting) |
| 10 | Minimum SDK | **OK** — Xcode 26.6 / SDK 26.5 |
| 10 | Licensing, IAP, sign-in, placeholders | **OK** |
| 10 | `GetProtectionScoreIntent` | **RISK** — dormant feature, 2.3.1 |
