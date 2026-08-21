# Third-party licenses

Sentry bundles the open-source packages below. Their code ships inside the
distributed binaries, so their licenses travel with it and are acknowledged
here and on each app's About screen.

Everything in this file was read from the **resolved** package graph
(`SourcePackages/workspace-state.json` in a DerivedData directory produced by
`xcodebuild -resolvePackageDependencies`) and from each package's own
`LICENSE`/`NOTICE` file in its SwiftPM checkout. No license type is inferred
from the vendor or from a README badge.

The machine-readable copy of this list lives in
`SentryKit/Models/AppCredits.swift` (`AppCredits.thirdPartyComponents`) —
that is what the two About screens render. Keep the two in step: same
packages, same order, same versions.

## Where each package ships

`project.yml` declares four packages (`GRDB`, `Sparkle`, `MCP`, `SwiftNIO`);
the other five arrive transitively. Only **GRDB** is linked by
`SentryKit_iOS`, so it is the only third-party code inside the iPhone app.
Everything else is Mac-only.

| Package | Version | License | Copyright | Direct? | macOS | iOS |
| --- | --- | --- | --- | --- | --- | --- |
| [EventSource](https://github.com/mattt/eventsource) | 1.4.1 | MIT | Copyright 2025 Mattt | via MCP SDK | ✓ | — |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 6.29.3 | MIT | Copyright (C) 2015-2024 Gwendal Roué | direct | ✓ | ✓ |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 | Apache-2.0 (see note) | the Model Context Protocol project authors | direct | ✓ | — |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.5 | MIT (+ BSD-2-Clause, see note) | Copyright (c) 2006-2017 Andy Matuschak and the Sparkle contributors | direct | ✓ | — |
| [swift-atomics](https://github.com/apple/swift-atomics) | 1.3.1 | Apache-2.0 with Runtime Library Exception | Apple Inc. and the Swift project authors | via SwiftNIO | ✓ | — |
| [swift-collections](https://github.com/apple/swift-collections) | 1.6.0 | Apache-2.0 with Runtime Library Exception | Apple Inc. and the Swift project authors | via SwiftNIO | ✓ | — |
| [swift-log](https://github.com/apple/swift-log) | 1.14.0 | Apache-2.0 | Copyright 2018, 2019 The SwiftLog Project | via MCP SDK | ✓ | — |
| [SwiftNIO](https://github.com/apple/swift-nio) | 2.101.3 | Apache-2.0 | Copyright 2017, 2018 The SwiftNIO Project | direct | ✓ | — |
| [swift-system](https://github.com/apple/swift-system) | 1.7.5 | Apache-2.0 with Runtime Library Exception | Apple Inc. and the Swift project authors | transitive | ✓ | — |

## Per-package notes

### EventSource — MIT

`LICENSE.md` opens `Copyright 2025 Mattt (https://mat.tt)` followed by the
standard MIT grant. Pulled in by the MCP Swift SDK for its SSE transport.

### GRDB.swift — MIT

`LICENSE` opens `Copyright (C) 2015-2024 Gwendal Roué` followed by the
standard MIT grant. The only third-party package inside the iPhone app.

### MCP Swift SDK — Apache-2.0, with an MIT remainder

The package's `LICENSE` is the full Apache License 2.0 text, prefixed by a
transition notice that must not be paraphrased away: the project is moving
from MIT to Apache-2.0, all new contributions are Apache-2.0, and
contributions whose authors have not consented to relicensing **remain under
the MIT License**. Both licenses are therefore in play, and both are
permissive and satisfied by this acknowledgement.

### Sparkle — MIT, plus BSD-2-Clause for embedded bsdiff

`LICENSE` is MIT over a stack of copyright lines (Andy Matuschak 2006-2013;
Elgato Systems GmbH 2009-2013; Kornel Lesiński 2011-2014; Mayur Pawashe
2015-2017; C.W. Betts, Petroules Corporation and Big Nerd Ranch 2014),
followed by an `EXTERNAL LICENSES` section: `bspatch.c` and `bsdiff.c` from
bsdiff 4.3 are `Copyright 2003-2005 Colin Percival`, under BSD-2-Clause.
Sparkle's delta updates use that code, so the BSD-2-Clause terms apply to
shipped Sentry builds as well.

### swift-atomics, swift-collections, swift-system — Apache-2.0 with Runtime Library Exception

Each `LICENSE.txt` is the Apache-2.0 text plus the Swift project's Runtime
Library Exception, which waives the §4(a)/(b)/(d) attribution requirements
for code embedded into a compiled binary. The waiver is optional to use;
these packages are acknowledged here regardless.

### swift-log, SwiftNIO — Apache-2.0

Plain Apache-2.0 (`LICENSE.txt`) with a `NOTICE.txt` stating
`Copyright 2018, 2019 The SwiftLog Project` and
`Copyright 2017, 2018 The SwiftNIO Project` respectively. Apache-2.0 §4(d)
requires the NOTICE content to be carried in redistributions — those two
lines are reproduced in the table above and on the About screens.

## Not third-party

`SystemMetricsKit`, `SentryKit`, `SentryMCP`, `SentryCLI`, `SentryMCPBridge`
and the widget/watch targets are first-party code under this repository's
`LICENSE`. Apple's own SDK frameworks (Foundation, SwiftUI, IOKit, GRDB's
system SQLite, …) are covered by the Apple SDK agreement and are not
acknowledged here.

## Updating this file

After changing a `packages:` entry in `project.yml`:

```sh
xcodegen generate
xcodebuild -project Sentry.xcodeproj -scheme Sentry \
  -derivedDataPath <your-DD> -resolvePackageDependencies
```

then re-read `<your-DD>/SourcePackages/workspace-state.json` for the exact
resolved versions and the `LICENSE`/`NOTICE` file of any package that moved,
and update both this table and `AppCredits.thirdPartyComponents`.
