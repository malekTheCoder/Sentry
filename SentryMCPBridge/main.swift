import Foundation
import os

// MARK: - SentryMCPBridge — the rendezvous desk for command-line access
//
// This process runs as **the logged-in user**, never as root — and with the
// fan daemon deleted it is the only launchd job Sentry can install at all.
// Launched on demand by launchd from
// `Sentry.app/Contents/Library/LaunchAgents/dev.malekswilam.sentry.xpc.plist`
// after the user explicitly sets it up in Settings ▸ AI Access.
//
// **Read `SentryKit/MCPBridge/MCPBridgeContract.swift` first.** It carries
// the experiment that forced this design, why this is a broker rather than a
// relay, and the full list of what has never been observed on a machine with
// no signing identities.
//
// What this file is responsible for, and nothing else:
//
//   1. Publish the Mach service — which, being the process launchd started as
//      this job, it is uniquely able to do. This is the entire reason the
//      binary exists.
//   2. Hand connections to `BridgeService`, which gates them.
//
// It probes no hardware, opens no database, reads no settings, and makes no
// network connection. Its compile surface is Foundation, Security, and five
// files (see `project.yml`); it links none of this project's frameworks. That
// is auditability rather than necessity — a process that brokers access to
// every metric Sentry can report should be small enough to read in full.
//
// **No `RunAtLoad`, no `KeepAlive`, and an idle exit.** Deliberate, and the
// same posture the fan daemon takes: this process should exist only while
// something is using it. See `BridgeService.armIdleTimerLocked`.

let log = Logger(subsystem: MCPBridgeNaming.label, category: "main")

let service = BridgeService(evaluator: MCPBridgeSecurityEvaluator())

let listener = NSXPCListener(machServiceName: MCPBridgeNaming.machService)
listener.delegate = service
listener.resume()

// Logged unconditionally, and worded carefully. `NSXPCListener.resume()`
// returns `Void` and reports a failed `bootstrap_check_in` **nowhere** — that
// silence is precisely what made the original bug take so long to find, so
// this line must not be read as proof the service was published. What it
// truthfully asserts is that this process reached the point of trying. If the
// check-in failed, launchd did not start us as this job, and nothing will ever
// connect; the honest place to notice that is the client, which now says so.
log.notice("Resumed the listener for \(MCPBridgeNaming.machService, privacy: .public). Note: NSXPCListener does not report check-in failure, so this is not a claim that the service is published.")

dispatchMain()
