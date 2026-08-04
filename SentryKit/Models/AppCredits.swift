import Foundation

/// Everything the About surfaces on both platforms need to say about who
/// made Sentry, what it is built on, and where to read the policies.
///
/// This exists as one shared type in SentryKit — rather than literals in
/// `Sentry/Settings/Panes/AboutPane.swift` and again in
/// `SentryMobile/Settings/AboutView.swift` — because the two screens are
/// required to agree. A Mac About panel crediting two people and an iPhone
/// About screen crediting one is not a cosmetic inconsistency: attribution
/// and license acknowledgement are the parts of an app that have to be
/// *correct*, and the cheapest way to keep them correct is to give them a
/// single definition that both platforms read.
///
/// Nothing here is read from the bundle except the version (see
/// `versionSummary(bundle:)`), and nothing here is user-configurable.
public enum AppCredits {

    // MARK: - People

    /// The people who wrote Sentry, spelled exactly as they appear in the
    /// repository's own commit history (`git shortlog -sne --all`) — that
    /// is the only record of authorship this project has, so it is the one
    /// the shipped credit is derived from rather than a hand-maintained
    /// list that can quietly disagree with it.
    ///
    /// Order is first-commit order, not seniority.
    public static let contributors: [String] = [
        "Malek Swilam",
        "Aniketh Bandlamudi",
    ]

    /// The two names joined the way a copyright line reads them. Kept as a
    /// derived value rather than a second literal so `contributors` stays
    /// the single place a name is ever edited.
    public static var copyrightHolders: String {
        contributors.joined(separator: " & ")
    }

    /// First commit in this repository is 2026-07-28, so the copyright term
    /// starts in 2026. A single year (not a range) is correct until the
    /// project has a second calendar year of published work.
    public static let copyrightYear = "2026"

    /// The shipping copyright string. Must stay byte-identical to
    /// `NSHumanReadableCopyright` in `project.yml` (which XcodeGen writes
    /// into `Sentry/Resources/Info.plist`) — the About screen and the
    /// Finder "Get Info" panel are two views of the same claim, and a user
    /// who sees them disagree has no way to tell which one is the truth.
    public static var copyright: String {
        "Copyright © \(copyrightYear) \(copyrightHolders). All rights reserved."
    }

    // MARK: - Policy links

    /// Where the privacy policy will live once it is published.
    ///
    /// ⚠️ **[PRIVACY POLICY URL — TO FILL IN]** ⚠️ The policy text itself is
    /// `docs/privacy-policy.md` in this repository; it is not yet served at
    /// any address. This constant is the *only* place either platform names
    /// that address, so publishing the policy is a one-line change here and
    /// nowhere else. The value below is the GitHub Pages site the app
    /// already points at for its Sparkle appcast (`SUFeedURL`), which is
    /// the intended home — it is a placeholder for the *path*, not a guess
    /// at some other host.
    public static let privacyPolicyURLString = "https://malekthecoder.github.io/Sentry/privacy-policy"

    /// Non-optional at the call site, because a malformed literal here is a
    /// programming error that should be caught by the About screen's own
    /// tests rather than degraded into a missing link at runtime.
    public static var privacyPolicyURL: URL? {
        URL(string: privacyPolicyURLString)
    }

    // MARK: - Version

    /// "Version 1.2.3 (45)" from a bundle's `CFBundleShortVersionString` and
    /// `CFBundleVersion`.
    ///
    /// Split from `versionSummary(bundle:)` so the formatting is testable
    /// without a bundle: under `xcodebuild test` `Bundle.main` is the test
    /// runner, not Sentry.app, so a test that went through the bundle would
    /// assert against XCTest's version number and prove nothing.
    ///
    /// The two degenerate cases are handled deliberately rather than
    /// rendered as empty parentheses or the literal string "nil": a build
    /// number equal to the marketing version is redundant noise, and a
    /// bundle with no version at all is a real (if broken) state that
    /// should say so in words.
    public static func versionSummary(shortVersion: String?, build: String?) -> String {
        let short = shortVersion?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = build?.trimmingCharacters(in: .whitespaces) ?? ""

        guard !short.isEmpty else {
            return build.isEmpty ? "Version unavailable" : "Build \(build)"
        }
        guard !build.isEmpty, build != short else {
            return "Version \(short)"
        }
        return "Version \(short) (\(build))"
    }

    /// Reads the running app's own version. Never hardcoded: `project.yml`
    /// substitutes `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` into the
    /// Info.plist precisely so there is one source of truth for the version,
    /// and Sparkle compares those same two keys to decide whether an update
    /// applies. An About screen with its own copy of the number would be a
    /// third source, and the first one to go stale.
    public static func versionSummary(bundle: Bundle = .main) -> String {
        versionSummary(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    // MARK: - Third-party components

    /// One bundled open-source dependency, as acknowledged on the About
    /// screens and in `docs/third-party-licenses.md`.
    public struct ThirdPartyComponent: Identifiable, Hashable, Sendable {
        /// The package's own name, as it appears in its repository.
        public let name: String
        /// The exact resolved version this app ships, from SwiftPM's
        /// resolved package graph.
        public let version: String
        /// SPDX-style short identifier, read from the package's own LICENSE
        /// file rather than assumed from the vendor.
        public let license: String
        /// The copyright line as the package states it.
        public let copyright: String
        /// Upstream repository, so the full license text is one click away.
        public let url: String
        /// Whether this package's code actually ships inside the iPhone app.
        ///
        /// Only GRDB does: `SentryKit_iOS` (`project.yml`) declares GRDB as
        /// its sole package dependency, while Sparkle, the MCP SDK and
        /// SwiftNIO — and everything the latter two pull in — are linked by
        /// the Mac app alone. Acknowledging a library on a device that
        /// doesn't contain it would be a false statement about the binary
        /// in the user's hand, so the iPhone About screen filters on this
        /// rather than showing the Mac's list.
        public let shipsOniOS: Bool

        public var id: String { name }

        public init(
            name: String,
            version: String,
            license: String,
            copyright: String,
            url: String,
            shipsOniOS: Bool
        ) {
            self.name = name
            self.version = version
            self.license = license
            self.copyright = copyright
            self.url = url
            self.shipsOniOS = shipsOniOS
        }
    }

    /// Every third-party package whose code ends up inside a shipped Sentry
    /// binary — direct dependencies *and* their transitive ones, because a
    /// license obligation follows the code, not the dependency declaration.
    ///
    /// Versions and license identifiers were read from the resolved package
    /// graph and each package's own LICENSE file, not inferred; see
    /// `docs/third-party-licenses.md` for the per-package detail (including
    /// Sparkle's embedded bsdiff, which carries a second license, and the
    /// MCP SDK's in-progress MIT→Apache-2.0 relicensing).
    ///
    /// Kept in the same order as that document, alphabetical by name, so the
    /// two can be diffed by eye when a dependency is added or bumped.
    public static let thirdPartyComponents: [ThirdPartyComponent] = [
        ThirdPartyComponent(
            name: "EventSource",
            version: "1.4.1",
            license: "MIT",
            copyright: "Copyright 2025 Mattt",
            url: "https://github.com/mattt/eventsource",
            shipsOniOS: false
        ),
        ThirdPartyComponent(
            name: "GRDB.swift",
            version: "6.29.3",
            license: "MIT",
            copyright: "Copyright (C) 2015-2024 Gwendal Roué",
            url: "https://github.com/groue/GRDB.swift",
            shipsOniOS: true
        ),
        ThirdPartyComponent(
            name: "MCP Swift SDK",
            version: "0.12.1",
            license: "Apache-2.0 (some contributions remain MIT)",
            copyright: "Copyright the Model Context Protocol project authors",
            url: "https://github.com/modelcontextprotocol/swift-sdk",
            shipsOniOS: false
        ),
        ThirdPartyComponent(
            name: "Sparkle",
            version: "2.9.5",
            license: "MIT (embeds bsdiff under BSD-2-Clause)",
            copyright: "Copyright (c) 2006-2017 Andy Matuschak and the Sparkle contributors",
            url: "https://github.com/sparkle-project/Sparkle",
            shipsOniOS: false
        ),
        ThirdPartyComponent(
            name: "swift-atomics",
            version: "1.3.1",
            license: "Apache-2.0 with Runtime Library Exception",
            copyright: "Copyright Apple Inc. and the Swift project authors",
            url: "https://github.com/apple/swift-atomics",
            shipsOniOS: false
        ),
        ThirdPartyComponent(
            name: "swift-collections",
            version: "1.6.0",
            license: "Apache-2.0 with Runtime Library Exception",
            copyright: "Copyright Apple Inc. and the Swift project authors",
            url: "https://github.com/apple/swift-collections",
            shipsOniOS: false
        ),
        ThirdPartyComponent(
            name: "swift-log",
            version: "1.14.0",
            license: "Apache-2.0",
            copyright: "Copyright 2018, 2019 The SwiftLog Project",
            url: "https://github.com/apple/swift-log",
            shipsOniOS: false
        ),
        ThirdPartyComponent(
            name: "SwiftNIO",
            version: "2.101.3",
            license: "Apache-2.0",
            copyright: "Copyright 2017, 2018 The SwiftNIO Project",
            url: "https://github.com/apple/swift-nio",
            shipsOniOS: false
        ),
        ThirdPartyComponent(
            name: "swift-system",
            version: "1.7.5",
            license: "Apache-2.0 with Runtime Library Exception",
            copyright: "Copyright Apple Inc. and the Swift project authors",
            url: "https://github.com/apple/swift-system",
            shipsOniOS: false
        ),
    ]

    /// The subset that actually ships inside SentryMobile — see
    /// `ThirdPartyComponent.shipsOniOS` for why the iPhone does not simply
    /// display the Mac's list.
    public static var iOSThirdPartyComponents: [ThirdPartyComponent] {
        thirdPartyComponents.filter(\.shipsOniOS)
    }
}
