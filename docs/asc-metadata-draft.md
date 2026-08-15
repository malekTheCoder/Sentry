# App Store Connect metadata — draft for the iOS app

Every text field the human will paste into App Store Connect for
**`dev.malekswilam.sentry.mobile`** (the iOS app, which carries the widget,
the watch app, and the complication in one upload). Paste-ready values are in
fenced blocks; everything outside a block is drafting rationale, not copy.

Grounding: the App Privacy answers were originally transcribed from
`docs/appstore-review-readiness.md` §8; since the Location Log feature was
deleted (13 Aug 2026) this draft supersedes §8's location answer — that
document is a historical audit and carries an editor's note saying so. URLs were
verified against what the app actually compiles in: the Sparkle feed is
`https://malekthecoder.github.io/Sentry/appcast.xml` (`project.yml:609`, read
by `SentryKit/Updates/UpdateFeedConfiguration.swift` via `SUFeedURL`) and the
privacy policy constant is
`https://malekthecoder.github.io/Sentry/privacy-policy`
(`SentryKit/Models/AppCredits.swift:66`). Both live under the GitHub Pages
project path `/Sentry/`, which is the intended web home, fronted by a custom
domain. **Neither URL is live yet** — the readiness audit found the host
redirecting to `malekswilam.dev` and serving 404.

⚠️ **The name "Sentry" is provisional** pending a trademark decision. It
appears throughout the copy below because copy needs a name; if the name
changes, sweep this whole file — nothing else in the repo depends on the
strings here.

---

## App name

```
Sentry
```

30-character limit; 6 used. **Pending final decision** — "Sentry" collides
with an established developer-tools trademark, and the launch plan carries
the rename question. Do not create the App Store Connect app record until
the name is settled: the record's name can be changed before first release,
but the decision should come first, not after screenshots and copy exist.

## Subtitle

30-character limit. Three options, best first:

| Option | Characters |
|---|---|
| `Your Mac's vitals, on iPhone` | 28 |
| `See your Mac from your phone` | 28 |
| `Live Mac stats and keep-awake` | 29 |

The first states the relationship (companion, not standalone) in the same
breath as the value — the single fact the whole listing has to land.

## Categories

- **Primary: Utilities.** Where every Mac system monitor lives; matches the
  readiness doc's checklist.
- **Secondary suggestion: Productivity.** The keep-awake control and
  Siri/Shortcuts angle. *Developer Tools* was considered — the audience is
  right — but the iOS app itself contains no developer tooling (the MCP/agent
  features are Mac-side), and a category the reviewer can't find in the app
  invites questions. Productivity is defensible from the app alone.

## Description

4,000-character limit; this draft is well under. The first paragraph states
the Mac requirement plainly, per the readiness doc's checklist ("state the
Mac requirement in the first paragraph, above the fold").

```
Sentry for iPhone is a live readout of your Mac — the companion to Sentry
for macOS, a free menu bar system monitor. Live data requires the free Mac
app: install it on your Mac, keep both devices on the same Wi-Fi, and this
app finds the Mac by itself. Without a Mac connected, the app runs in a
clearly labelled demo mode, so every screen works standalone with sample
data.

WHAT YOU SEE

• Dashboard — the Mac's battery, CPU, memory, GPU, and temperatures, live,
with battery health and charging detail up top.
• History — a battery-health trend and every metric's latest reading, as
deep as the Mac's own records.
• Alerts — the alert rules the Mac ships with, grouped by what they watch.
Rules evaluate on the Mac and fire as normal Mac notifications.
• Settings — connection status, theme, and units.

CONTROL, NOT JUST A READOUT

The Dashboard's sleep card can hold the Mac awake, extend or shorten the
hold, or end it early. Each tap is a real command the Mac answers — the card
reports what actually happened, not what it hoped. "Keep my Mac awake for
60 minutes" also works through Siri and Shortcuts.

ON YOUR WRIST AND HOME SCREEN

The Apple Watch app installs alongside the iPhone app and mirrors the vitals
and keep-awake controls, relayed through the phone. A watch complication and
an iPhone home-screen widget keep the battery and CPU one glance away.

PRIVATE BY CONSTRUCTION

No account, no sign-in, no telemetry, no cloud. Your Mac's data travels over
your own Wi-Fi, from your Mac to your phone and your watch — never to a
server.

REQUIREMENTS

Live data needs the free Sentry app for macOS, running on a Mac with
macOS 14 or later. Demo mode needs nothing at all.
```

**Deliberately omitted: away-from-home remote pairing.** The iOS app has the
remote-Mac fields, but minting a pairing code is gated behind the Mac app's
Pro upgrade, which is sold outside any App Store. Advertising it in the iOS
listing would either mislead free users or require mentioning an off-store
purchase — Guideline 3.1.1 hygiene says do neither. The listing describes the
free-tier experience only, and nothing in the iOS app links to a purchase.

## Keywords

100-character limit; 97 used. Comma-separated, no space after commas, app
name excluded (the name field already matches searches for it):

```
mac,monitor,system,cpu,gpu,battery,health,temperature,fan,stats,menu bar,keep awake,widget,remote
```

Notes: no competitor names (do not add "istat" — trademark, and a metadata
rejection risk). "remote" can be swapped for "watch" (same length ±1) if the
remote angle feels overpromising; Apple discourages device names as keywords,
so "remote" is the safer of the two.

## Promotional text

170-character limit; 152 used. Editable without a new build, so this can
carry the launch angle:

```
See your Mac's vitals from your pocket: live CPU, memory, and battery, keep-awake control, and alert rules — synced over your own Wi-Fi, never a server.
```

## URLs

| Field | Value | Status |
|---|---|---|
| **Support URL** | `https://github.com/malekTheCoder/Sentry/issues` | Live. Public, readable with no login (posting needs a GitHub account, which is acceptable — the page itself resolves). This is the project's only support channel; there is no support email yet. |
| **Marketing URL** (optional) | `https://malekswilam.dev/SentryWebsite/` | Live. The web home now exists — a static landing page maintained in the [SentryWebsite](https://github.com/malekTheCoder/SentryWebsite) repo, deployed from that repo's `main`. It supersedes the repo README as the marketing page. Never point this at a 404. |
| **Privacy Policy URL** | `https://malekthecoder.github.io/Sentry/privacy-policy` | **Live** (200, redirects to the custom domain at `malekswilam.dev/Sentry/privacy-policy/`). Re-verify before submitting. This is the URL the app compiles in (`SentryKit/Models/AppCredits.swift:66`); the ASC field and the in-app link must be the same working address. The host currently redirects to `malekswilam.dev` and 404s, so publishing the policy may also mean updating the constant to the final custom-domain address. Follow `docs/privacy-policy-publishing.md`, fill the policy's two placeholders (effective date, contact email — use TO-FILL(support-email) until one exists), verify in a private browser window, and delete the "the link above isn't live" sentence at `SentryMobile/Settings/AboutView.swift` (~line 126). |

## Copyright

ASC prepends the © symbol; enter:

```
2026 Malek Swilam & Aniketh Bandlamudi
```

Must stay consistent with `AppCredits.copyright` and `project.yml`'s
`NSHumanReadableCopyright` — the About screen, Finder, and the store listing
are three views of the same claim.

## App Review contact information

Required fields on the version page. The reviewer may actually call or write.

| Field | Value |
|---|---|
| First name / Last name | whoever will answer during review — decide at submission |
| Phone | that person's real number |
| Email | TO-FILL(support-email) — any monitored inbox works; it is not published |
| Sign-in required | **No** (no account exists anywhere in the app) |
| Demo account | Not applicable — built-in demo mode; see review notes |

## Age rating questionnaire

Apple has required responses to the **updated** questionnaire since
31 January 2026 (readiness doc, "Required App Store Connect fields");
unanswered apps cannot submit. Every answer for this app is the minimum —
there is no content of any listed kind. Expected result: **4+**.

Frequency questions — answer **None** to all:

| Question | Answer |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Prolonged Graphic or Sadistic Realistic Violence | None |
| Sexual Content or Nudity | None |
| Graphic Sexual Content and Nudity | None |
| Profanity or Crude Humor | None |
| Horror/Fear Themes | None |
| Mature/Suggestive Themes | None |
| Alcohol, Tobacco, or Drug Use or References | None |
| Simulated Gambling | None |
| Medical/Treatment Information | None |
| Contests | None |

Yes/No questions — answer **No** to all:

| Question | Answer |
|---|---|
| Gambling (real money) | No |
| Unrestricted Web Access | No |
| Messaging, chat, or user-to-user communication | No |
| User-generated or user-shared content | No |
| Advertising | No |
| In-app purchases | No |
| Parental controls / in-app content controls | No |
| Made for Kids / Kids Category | No |

If App Store Connect words a question differently from this table, the
answer for this app is still None/No: it renders system metrics from the
user's own Mac and contains no media content, no communication features, no
web view, no ads, and no purchases.

## App Privacy questionnaire

Originally transcribed from `docs/appstore-review-readiness.md` §8, then
updated on 13 Aug 2026 when the Location Log feature was deleted from the
product entirely — this draft now supersedes §8's location answer (see the
editor's note there). **Enter exactly this; do not let App Store Connect's
defaults stand.**

| App Store Connect question | Answer |
|---|---|
| Do you or your third-party partners collect data from this app? | **No** |

Answering **No** to the gate question is the whole questionnaire: ASC only
expands the per-category table when the answer is Yes. Nothing is collected
in any category — no contact info, no location (the Location Log feature
was removed; no CoreLocation call exists anywhere in the app or the Mac
app), no identifiers, no usage data, no diagnostics — and nothing is used
for tracking. The expected label is **"Data Not Collected."**

Two directives that travel with the answer:

- **Keep the manifest and the label consistent.** ASC cross-checks them.
  `SentryMobile/PrivacyInfo.xcprivacy` declares an empty
  `NSPrivacyCollectedDataTypes` array — no collected types — so this
  answer must match it. Change one and you must change the other.
- System metrics from the user's own Mac (battery, CPU, temperatures)
  travel only between the user's own devices over their own network, are
  never sent to any server, and are not accessible to the developer —
  which is not "collection" under Apple's definition.

## App Review notes

Paste into the version's "Notes" field (4,000-character limit; this draft is
under it). Attach the demo video (below) or add its hosted link where marked.

```
WHAT THIS APP IS

This app is the iPhone companion to Sentry for macOS, a free menu bar
system monitor distributed outside the Mac App Store (Developer ID-signed
and notarized; it reads low-level power interfaces that do not exist inside
the App Sandbox). The iPhone app is a readout and remote control for that
Mac app. There is no account and no sign-in anywhere, so no demo account is
provided; a full demo mode is built in instead.

If you have a Mac available: download the free Mac app from
https://github.com/malekTheCoder/Sentry/releases/latest/download/Sentry.dmg
(requires macOS 14 or later), open it, and keep the Mac and the review
iPhone on the same Wi-Fi. The iPhone app discovers the Mac over Bonjour
(_sentry._tcp) within about 5 seconds of launch and replaces the demo data
with live data. A video of exactly this is attached: [ATTACH OR LINK DEMO
VIDEO].

REVIEWING WITHOUT A MAC — DEMO MODE WALKTHROUGH

1. Launch the app. A walkthrough opens; its first step is titled "This app
   reads a Mac" and states that until a Mac is connected the app shows
   labelled placeholder data. The walkthrough can be completed or skipped.
2. With no Mac found, every tab sits under a pinned amber banner reading
   "Sample data — not from a real Mac", with Try again and How to connect
   actions. The banner cannot be scrolled away or dismissed: the Quiet
   action shrinks it to a persistent SAMPLE marker in the same position,
   and the full banner returns on next launch.
3. Dashboard tab: a demo Mac's battery card, vitals, and sleep card, with
   inline SAMPLE tags on the chart surfaces. Values re-roll periodically so
   layout and motion can be evaluated.
4. History tab: the range selector and battery-health trend, SAMPLE-tagged.
5. Alerts tab: the real default alert-rule set that ships in the Mac app —
   true documentation of the product, not fabricated telemetry. Alert
   history requires a connected Mac, and the tab says so.
6. Settings tab: theme and units genuinely work standalone; the connection
   section states plainly that the app is showing demo data.
7. Home-screen widget: add the large widget — it carries the caption "Demo
   data — no live Mac sync yet".
8. Apple Watch (relay path): the watch app is a dependent watch app that
   installs with the iPhone app. With a paired Watch (or paired watch
   simulator), open the iPhone app and leave it in the foreground; it
   relays its current snapshot — including demo data — to the watch over
   WCSession, typically within about 30 seconds. The watch Overview page
   then shows the same vitals with an explicit "Demo" chip, and the watch
   complication appends "· Demo" to its freshness line. The watch also has
   a Keep Awake page and an agent-activity page fed the same way.

PRIVACY, GENERALLY

No account, no analytics, no telemetry, no third-party services. Data moves
only between the user's own devices over their own network; there is no
developer server anywhere in the product.
```

---

## Demo video — shot list and narration script

One continuous story, ~80 seconds: the iPhone app under review driving a
real Mac. Record the Mac screen (QuickTime screen recording) and the iPhone
(QuickTime over USB) and cut between them; keep the iPhone's connected state
visible (no sample banner) so every phone shot is self-evidently live.
Narration can be a voice track or burned-in captions — captions survive
muted review.

| # | Time | Screen | Action | Narration |
|---|---|---|---|---|
| 1 | 0:00–0:08 | Mac | Desktop with the menu bar readout visible; click the icon; the dropdown opens with live vitals. | "This is Sentry, a free system monitor that lives in the Mac's menu bar." |
| 2 | 0:08–0:18 | iPhone | Launch the app on the same Wi-Fi. It connects; the Mac's real name appears; no sample banner anywhere. | "On the same Wi-Fi, the iPhone app finds the Mac by itself. No account, no server, no setup — this is the Mac, live." |
| 3 | 0:18–0:30 | Both | Start a heavy job on the Mac (a build or video export). Cut to the phone: CPU and temperature climb on the Dashboard in step. | "Everything on this screen comes from the Mac. Start a build, and you watch the load rise from the next room." |
| 4 | 0:30–0:48 | Both | On the phone, tap the sleep card: keep the Mac awake for 1 hour. The card reports "Done." Cut to the Mac's dropdown: the keep-awake assertion is active with its end time. Back on the phone, End Now; the Mac shows it released. | "The sleep card sends real commands. Hold the Mac awake for an hour — the Mac confirms it, and the phone reports what actually happened. Ending it works the same way, round trip." |
| 5 | 0:48–1:02 | Both | On the Mac, show an alert rule (e.g. CPU above a threshold) in Settings ▸ Alerts; the running load trips it and a macOS notification fires. Cut to the phone's Alerts tab showing the rule set. | "Alert rules run on the Mac and fire as ordinary notifications the moment a threshold is crossed. The phone shows the rules the Mac is enforcing." |
| 6 | 1:02–1:15 | Watch | Raise the wrist: the Overview page's dials show the same live vitals. Swipe to the Keep Awake page and hold the Mac awake from the wrist; cut to the Mac confirming. | "The Watch app rides along with the phone — the same vitals at a glance, and the same keep-awake control from the wrist." |
| 7 | 1:15–1:25 | iPhone | Home screen with the widget; end card. | "Your Mac's data goes to your phone and your watch — never to a server. Sentry: free on the Mac, with companions for iPhone and Apple Watch." |

Capture notes:

- Shot 4 is the load-bearing one for review — it proves the app is a
  functioning remote control, which is the 4.2 answer. Do not trim the
  Mac-side confirmation out of it.
- In shot 6, the watch updates by relay from the phone; keep the phone app
  foregrounded during recording so the relay is prompt.
- If the provisional name changes, re-record nothing — no shot should
  linger on the app name. Frame the menu bar and About screens accordingly.

---

## Open items this draft cannot settle

1. **App name** — provisional; trademark decision pending. Everything above
   is written so a rename is a find-and-replace in this file only.
2. **Privacy policy URL** — must be published live and must match the
   compiled-in `AppCredits.privacyPolicyURLString`, which itself may need
   updating to the final custom-domain address. Blocker per the readiness
   doc.
3. **Support email** — does not exist; TO-FILL(support-email) markers above.
   GitHub Issues is the stated support channel meanwhile.
4. **Demo device name** — still "Malek's MacBook Pro"
   (`SentryMobile/Data/MockDataSource.swift:73`). The readiness doc's
   highest value-per-effort recommendation is renaming it to something
   self-evidently synthetic before screenshots and review.
5. **Mock keep-awake feedback** — tapping keep-awake with no Mac still shows
   "Sent, but no reply from your Mac yet."
   (`SentryMobile/Dashboard/SleepStatusCard.swift:350`) although nothing is
   sent on the mock path. The readiness doc flags this under 2.3.1; the
   review notes above deliberately do not describe the demo sleep card's tap
   behaviour until it is fixed.
6. **No Mac-app download link in the iOS app** — the readiness doc
   recommends adding one to About; the review notes compensate by giving
   the reviewer the DMG URL directly.
