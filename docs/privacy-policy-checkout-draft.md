# Privacy policy — DRAFT revision for the checkout release

> **DRAFT — NOT IN EFFECT.** This is the proposed revision of
> [`privacy-policy.md`](privacy-policy.md) for the release that ships Pro
> checkout. It must **not** replace the live policy, be published, or be
> linked from the app until that release actually ships — the live policy
> must always describe the build people are running. Until checkout ships,
> [`privacy-policy.md`](privacy-policy.md) remains the policy.
>
> What changed from the live policy, in full: the "In one paragraph"
> summary gained two sentences about buying Pro; a new "Buying Sentry Pro"
> section was added; the "Where it is stored" and "Deleting your data"
> sections now say what the licence file contains; and the "no server"
> wording was tightened to stay true (a checkout service now exists — the
> app still never talks to it). Nothing else was touched, deliberately:
> checkout adds no network path to the app, so nothing else needed to
> change. This draft describes a release with **paste-in activation only**
> — if that release also confirms licences with a server ("revalidation"),
> this draft is insufficient and must be revised again first.

---

# Sentry Privacy Policy

**Effective date:** [EFFECTIVE DATE — TO FILL IN]

This policy covers the Sentry app for Mac, iPhone, and Apple Watch.

A quick note on the name: this app has nothing to do with Sentry.io, the error-monitoring service. Same word, different product. Sentry does not use that service, or any service like it.

## In one paragraph

Sentry measures your own hardware — CPU, memory, disk, battery, temperature, network throughput — and shows it to you. There is no account to create, no server the app talks to, and no analytics, telemetry, or crash reporting of any kind. Your readings are stored in a database file on your own Mac. Three things can send data off the Mac, and you control all three: live stats stream over your local Wi-Fi so your iPhone and Watch can show them; an optional AI-agent feature can hand your stats to a local AI tool such as Claude Code; and the Mac version checks a static file on the web for app updates. If you buy Sentry Pro, the purchase happens on our payment provider's website in your browser — the app takes no part in it, and activating your licence happens entirely on your Mac, offline. Nothing is sold, shared, or sent anywhere else. If you delete the app's data folder, the data is gone.

---

## What Sentry measures

All of this is read from your own device using standard Apple system APIs.

**Hardware and performance**
- CPU usage, per core, plus load average and a count of running processes
- Memory used, cached, compressed, swap usage, memory pressure
- Disk free/total space and read/write throughput
- GPU and Neural Engine utilisation and power draw
- Temperature sensors, fan speeds, thermal pressure, whether the Mac is throttling
- Battery charge, charging state, voltage, wattage, cycle count, health, temperature, and the description of the attached power adapter
- Network throughput per interface, Wi-Fi signal strength, the active interface name, and this Mac's local (private) IP address

**Device facts**
- Mac model identifier (e.g. "Mac14,7"), chip name, installed memory, macOS version, uptime
- The Mac's name — the one you set in System Settings, which often contains your first name

Sentry does **not** read your Mac's serial number or hardware UUID, your username, your files or filenames, your browsing, your contacts, your camera, or your microphone.

**Running processes.** When you open the Dashboard window on the Mac, Sentry lists the top processes by CPU and memory. It reads process names and IDs only — never command lines, arguments, or document names. This list is never saved to disk, never synced to your phone or Watch, and never made available to AI agents. It exists only in memory while that window is open.

**Security posture.** Sentry can check how your Mac is protected: FileVault, System Integrity Protection, Gatekeeper, the firewall and stealth mode, automatic-update settings, screen-lock settings, whether the guest account is on, and which network ports are listening. It does this by running Apple's own read-only status commands (`fdesetup status`, `csrutil status`, `spctl --status`, `socketfilterfw`, `defaults read`, `netstat`). It never asks for your password, never elevates privileges, never changes a setting, and never contacts the network to do it. The results stay on your Mac and are used only to show you your own protection score.

**Location.** Sentry does not read your location. No app in the family — Mac, iPhone, or Watch — contains any location code. (An earlier opt-in "Location Log" feature was removed before release; nothing collects, stores, or transmits a coordinate.)

**Wi-Fi network name.** Sentry does not read your Wi-Fi network name. The capability exists in the code but is switched off in the shipping app.

## Where it is stored

Everything lives on your own device. Nothing is uploaded to any server. The one piece of server-side machinery involved with Sentry at all — the checkout that issues Pro licences, described in "Buying Sentry Pro" below — never hears from the app.

On the Mac:
- `~/Library/Application Support/Sentry/history.sqlite` — the measurement history database
- `~/Library/Application Support/Sentry/settings.json` — your settings, alert rules, custom themes, and (if you use them) the local-sync pairing code and Pro licence. The licence includes a one-way hash of the email address you bought with, not the address itself — see "Buying Sentry Pro".
- `~/Library/Caches/dev.malekswilam.sentry/statusline.json` — a short-lived cache of the most recent reading, used by the command-line status line
- One item in your macOS Keychain, only if you turn on AI Remote Access: the access token for that feature

On iPhone and Watch, a small snapshot of the latest readings is kept in the app's own storage so widgets and complications can draw without waking the app. It contains the Mac's name, battery, charge state, CPU, memory and thermal figures, keep-awake state, and — on the Watch — the names of recent AI tool calls. No IP address, no network name.

## How long it is kept

- Detailed second-by-second readings: **48 hours** by default, then deleted. You can change this in Settings.
- Hourly summaries (min/max/average): **90 days** by default, then deleted. You can change this too.
- Daily summaries: kept indefinitely, so long-range battery-health charts still work.
- Alert history and AI activity log: kept until you delete the database.

## What leaves your device, and when

There are exactly four paths. Nothing else in the app can open a network connection. (Buying a Pro licence does not add one — the purchase happens in your web browser, not in the app; see "Buying Sentry Pro".)

### 1. Local network sync to your iPhone and Watch

The Mac app advertises itself on your local network using Bonjour (service type `_sentry._tcp`) so your iPhone can find it. **The advertisement includes the Mac's name**, which is visible to anything else on the same Wi-Fi that is looking for it.

Please read this part carefully, because it is the one place Sentry is more open than you might assume:

- This local listener starts whenever the Mac app is running. It is not something you switch on.
- It streams live readings — about once a second — to **any device on the same network that connects to it**. There is no pairing step for reading. The traffic is not encrypted on the local network.
- That stream is the full snapshot: battery, CPU, memory, disk, thermals, network throughput, and **your Mac's local IP address**.
- Sending *commands* to the Mac (keep-awake, release, pause agent access) is different: that requires the paired connection described below.

In practice this means: on your own home or personal Wi-Fi, your stats are visible to your own devices. On a shared, public, or office network, treat those readings as visible to that network. If that is not what you want, quit the Mac app on untrusted networks.

**Remote Access pairing (off by default).** If you turn on Remote Sync, the Mac opens a second, encrypted listener (TLS with a pre-shared key derived from a pairing code you scan or type, port 8643 by default). Only devices that know the pairing code can connect to it, and only those devices may send commands. Sentry does not use any relay, rendezvous, or hole-punching service to reach your Mac from outside your network — reaching it from elsewhere is something you would have to arrange yourself, for example with your own VPN.

Nothing on this path touches the internet or any third party. Data goes directly from your Mac to your device.

### 2. iPhone to Apple Watch

The iPhone app hands a small snapshot to the Watch app using Apple's WatchConnectivity, which is a direct link between your own phone and your own watch. It carries the Mac's name, battery, charge state, CPU, thermal and memory pressure, and keep-awake state. It does not carry IP address or network name.

### 3. AI agent access (off by default)

Described in its own section below.

### 4. Update checks (Mac only)

The Mac version, which is distributed directly rather than through the Mac App Store, uses Sparkle to check for updates. Once a day, if the setting is on (it is on by default, and you can turn it off in Settings), it fetches a static file over HTTPS from a GitHub Pages address.

That request sends nothing about you. Sentry does not enable Sparkle's optional system-profile reporting, so no model, chip, memory, macOS version, or unique identifier is transmitted. As with any web request, the server that hosts the file — GitHub — can see your IP address and the standard request headers, which include the app version. If you would rather not make that request at all, turn off automatic update checks.

The iPhone and Watch versions are distributed through the App Store and do not include Sparkle or any update-check code.

## AI agents and the MCP interface

This is unusual enough to deserve its own section.

Sentry can act as an MCP (Model Context Protocol) server, which lets a local AI coding agent — Claude Code, Cursor, or similar — read your Mac's stats and answer questions like "is the machine thermally throttled right now?"

**It is off by default.** Nothing is exposed to any AI tool until you turn on the AI Access setting yourself.

**What an agent can read when you turn it on:** the same measurements described above — current snapshot, battery status and health history, metric history, thermal status, resource usage, alert history, device info (model, chip, macOS version, app version), sleep state, and agent-activity summaries. Because the snapshot is the same one used everywhere else, an agent can also see your Mac's local IP address.

**What an agent cannot read:** your running process list, your files, your keystrokes, your screen, or anything outside the measurements Sentry collects.

**Actions are a separate, stricter permission.** A small set of tools can change something — hold the Mac awake, release it, change the refresh interval, enable or disable an alert rule, propose a new alert rule. These are **all disabled by default**, even after you enable AI access. You must switch them on individually. You can also mark any of them as requiring a confirmation dialog, so a real macOS alert appears and you approve or refuse each call. There is a rate limit (20 calls a minute by default), a battery-level floor that blocks actions when the Mac is low, optional quiet hours, and a kill switch that denies everything from every agent and survives a restart.

**Tool calls are logged on your Mac.** Every attempted call — allowed, denied, rate-limited, or failed — is written to the `agent_activity_log` table in the local database, so you can see what an agent did. Each entry records the time, the name the AI client reported for itself, the tool, a session identifier generated locally, how long it took, the outcome, and a short human-readable summary of the request, truncated to 120 characters. **Raw arguments are never stored.** For read tools the summary is a dash. For the tool that proposes an alert rule, the rule's contents are deliberately excluded from the log. This log stays on your Mac and is never transmitted.

Note that the AI client's name is whatever the client says it is. It is a label for your benefit, not a verified identity.

**Remote Access for AI (off by default, and worth understanding).** There is an option to let an AI tool on another device reach Sentry over your network, protected by a random 64-character token stored in your macOS Keychain. If you turn it on, please know:

- It listens on **all network interfaces**, not just this Mac, on port 8642 by default.
- The connection is **plain HTTP, not HTTPS**. The access token is therefore sent in the clear on every request, and anyone able to observe traffic on that network could capture it and then read whatever tools you have enabled.
- Only turn this on for a network you trust. Turning it off deletes the token from the Keychain immediately, and regenerating the token revokes the old one instantly.

Every remote call goes through exactly the same permission checks, rate limits, confirmation dialogs, and logging as a local one.

## Buying Sentry Pro

Sentry's paid tier is a one-time licence, and the honest summary is: the purchase involves a payment company and an email; the app involves neither.

**The checkout is not part of the app.** You buy on the website of our payment provider — [MERCHANT OF RECORD — TO FILL IN], acting as the merchant of record — in your own web browser. During checkout that provider collects your email address and your payment details, under **its own privacy policy**, which is linked from its checkout page. Sentry the app plays no role in the purchase, and neither the app nor we ever see or store your card number or other payment details.

**What the licence file contains.** After the purchase, our licensing service creates your licence and emails it to you. The licence is a short signed text file containing: a licence ID, the number of Macs it covers, the date it was issued, and a **SHA-256 hash of the email address you bought with** — a one-way fingerprint, not the address itself. The hash exists so that support can confirm a licence belongs to you if you ask for help, and so the file itself never carries your address: the licence sits in `settings.json`, a file people routinely paste into bug reports, and someone reading it there learns nothing about who bought it.

**Activation happens on your Mac, offline.** You paste the licence into Settings, and the app checks its signature locally. Activating requires no network connection, creates no account, registers nothing anywhere, and sends nothing — not the licence, not the hash, not anything else. Once activated, the licence and the hash it contains are stored in `settings.json` on your Mac and stay there.

**Nothing new leaves your device.** Buying and activating a licence add no network path to the app. The four paths listed under "What leaves your device, and when" remain the complete list.

**Refunds and purchase questions** are handled by the payment provider, since it processed the payment. Questions about the app itself: see the Contact section.

If a future version of Sentry ever needs to contact the licensing service — for example, to periodically confirm a licence is still in good standing — that would be a new network path, and this policy will be revised to describe it exactly, before that version ships.

## Third-party code

Sentry includes four open-source libraries. None of them reports anything about you to anyone.

- **GRDB** — the SQLite database layer. Local files only; no networking. Ships in the Mac and iPhone apps.
- **Sparkle** — the Mac update framework, described above. Mac only.
- **SwiftNIO** — Apple's networking library. It provides the HTTP plumbing for the AI Remote Access option, and does nothing unless you turn that on. Mac only.
- **MCP Swift SDK** — the protocol implementation for the AI interface. Mac only.

There are no advertising SDKs, no analytics SDKs, no crash reporters, no attribution frameworks, and no tracking of any kind. Sentry does not track you across apps or websites, and there are no tracking domains to declare.

Sentry does not use iCloud, and the app has no iCloud entitlement, so it cannot sync your data through Apple's servers even in principle.

## Permissions Sentry asks for

- **Local network.** Needed so your iPhone and Watch can find your Mac and show its stats over Wi-Fi. On the Mac this prompt appears when the app starts, because the local listener starts with the app. On iPhone it appears when the app looks for your Mac.
- **Notifications.** Asked for only when you enable an alert rule, or the first time an alert would actually be delivered. Never at launch. Used only to show you your own alerts, on your own device.

Sentry never asks for camera, microphone, contacts, photos, calendar, or health access, and contains no code that could use them.

## Deleting your data

There is no account to close and no server-side copy to request, because neither exists.

To delete everything Sentry has stored on your Mac:

1. Quit Sentry.
2. Delete the folder `~/Library/Application Support/Sentry/` (this removes the history database and your settings — including your Pro licence, so keep the licence email if you plan to reinstall).
3. Delete `~/Library/Caches/dev.malekswilam.sentry/`.
4. If you ever turned on AI Remote Access, open Keychain Access and delete the item named `dev.malekswilam.sentry.mcp.remotekey`. Turning the feature off in Settings also removes it.
5. Delete the Sentry app itself.

To delete the iPhone or Watch data, delete the app from the device.

You can also reduce what is kept without deleting anything: lower the retention settings and turn off AI access.

The record of your *purchase* — the order the payment provider holds — belongs to the payment provider and is governed by its policy and its legal retention obligations; deleting the app does not affect it.

## Children

Sentry is a system-monitoring utility for general audiences. It is not directed at children, does not knowingly collect information from children, and has no accounts, profiles, messaging, or user-generated content of any kind.

## Changes to this policy

If Sentry changes what it collects or where data goes, this policy will be updated before or alongside that release, and the effective date at the top will change. Significant changes will be noted in the app's release notes. Because the app has no server and no account, we have no way to email you — please check this page if you want to know where things stand.

## Contact

Questions about privacy in Sentry: TO-FILL(support-email)
